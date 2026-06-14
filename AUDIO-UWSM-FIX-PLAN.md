# Fix plan: base-OS audio + UWSM session finalize

Implementation guide for two in-tree fixes to `installer.sh`. These are
**base-OS defects**, not desktop polish — the installer currently produces a
system with no audio stack and a UWSM session that never finalizes. Scope is
deliberately limited to those two things (plus the hardware-specific mic quirk
for the Precision 7780). Everything else from the post-install work log
(`~/chats/linux-fixes/fixes.md`) is the *desktop layer* and stays out of scope
here.

Honor the repo rules in `AGENTS.md`: two-space indent, `local` everywhere,
quoted expansions, `<<'EOF'` unless interpolation is intended, and **both hard
gates must pass**:

```bash
bash tools/check.sh      # bash -n + shellcheck
bash tests/run-all.sh    # full fake-driven suite
```

Every code change below names the test to update in the **same commit**.

---

## Background — why these are bugs

1. **UWSM never finalizes.** `write_hypr_lua_config` (`scripts/60-hyprland.sh`)
   writes `hypr-deb.lua` whose `hl.on("hyprland.start", …)` hook only launches
   the welcome app. The compositor never calls `uwsm finalize`, so
   `graphical-session.target` never activates, the session environment is never
   imported, and XDG autostart never runs. The session technically comes up but
   is **unmanaged** — verified live: `graphical-session.target` inactive, no
   `UWSM_*` env markers, compositor running outside any `wayland-wm@` unit.
   `uwsm finalize` is the documented bridge that fixes all of that.

2. **No audio at all.** `TARGET_BASE_PACKAGES` (`lib/00-config.sh`) contains no
   PipeWire/WirePlumber/ALSA. A fresh install has ALSA kernel devices but no
   userspace sound server. As a side effect the inherited multimedia keybinds
   are dead on arrival: the upstream-example keybinds module binds
   `XF86AudioRaiseVolume`→`wpctl`, `XF86MonBrightness*`→`brightnessctl`,
   `XF86Audio{Next,Play,…}`→`playerctl`, and **none of those binaries are
   installed**.

3. **Precision 7780 mic (hardware-specific).** On the Dell Precision 7780 the
   kernel auto-selects legacy HDA for the SoundWire dual-array mics and returns
   near full-scale samples. The fix is `snd_intel_dspcfg dsp_driver=3` via a
   modprobe.d drop-in + initramfs rebuild, plus `firmware-sof-signed`.

All package and config values below are taken from the verified end-state in
`fixes.md` (entries: *PipeWire audio stack installed and enabled*, *Laptop
firmware packages installed*, *Precision 7780 microphone switched to the SOF
SoundWire driver*, and the UWSM finalize entry). **Port the end state, not a
replay** — the work log is append-only and contains superseded steps.

---

## Change 1 — UWSM finalize in the generated config

**File:** `scripts/60-hyprland.sh`, function `write_hypr_lua_config`, the
`hypr-deb.lua` heredoc (`cat >"${cfg_dir}/hypr-deb.lua" <<'EOF'`).

Add `uwsm finalize` as the first action in the existing `hyprland.start` hook.
The heredoc is `<<'EOF'` (no interpolation) — the new line is literal.

**Before:**
```lua
hl.on("hyprland.start", function()
  hl.exec_cmd([[sh -c 'marker="$HOME/.config/hypr/.welcome-shown"; [ -e "$marker" ] || { /usr/local/bin/hyprland-welcome && touch "$marker"; }']])
end)
```

**After:**
```lua
hl.on("hyprland.start", function()
  -- Finalize the UWSM session: activates graphical-session.target, imports
  -- the session environment, and runs XDG autostart. Without this the
  -- session is launched by uwsm but never actually managed by it. Harmless
  -- no-op if the session was not started through uwsm.
  hl.exec_cmd("uwsm finalize")
  hl.exec_cmd([[sh -c 'marker="$HOME/.config/hypr/.welcome-shown"; [ -e "$marker" ] || { /usr/local/bin/hyprland-welcome && touch "$marker"; }']])
end)
```

Notes:
- Bare `uwsm finalize` is correct — uwsm knows the Hyprland var set
  (`HYPRLAND_INSTANCE_SIGNATURE`, cursor vars, …) and finalizes them. Verified
  live with exactly this call.
- Keep it inside the `hyprland.start` hook, not top-level (same reason the
  welcome exec is there — top-level fires before the compositor is up).

**Test:** `tests/hyprland-config.sh`, in the `hypr-deb.lua` assertion block
(next to the existing `hl.on("hyprland.start"` / welcome assertions), add:
```bash
assert_contains "${deb}" "uwsm finalize" \
  "compositor finalizes the UWSM session on start"
```

**Optional verify hardening:** `scripts/90-verify.sh` already has
`vcheck "user hyprland.lua exists" …`. You may add a `vcheck` that
`hypr-deb.lua` contains `uwsm finalize`.

---

## Change 2 — PipeWire audio stack in the base system

**File:** `lib/00-config.sh`.

Add a dedicated `AUDIO_PACKAGES` array (self-documenting, mirrors the existing
`UWSM_RUNTIME_PACKAGES` pattern) just above `TARGET_BASE_PACKAGES`, then splice
it into the base array.

```bash
# Userspace audio: PipeWire + WirePlumber replace the absent sound server.
# wpctl (wireplumber) and brightnessctl/playerctl also back the multimedia
# keybinds inherited from upstream's example config, which are otherwise dead.
# All are in main except firmware-sof-signed (non-free-firmware, already
# enabled via DEBIAN_COMPONENTS) — no apt-source change required.
AUDIO_PACKAGES=(
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth
  alsa-utils pulseaudio-utils pavucontrol
  brightnessctl playerctl
  firmware-sof-signed
)
```

Then add `"${AUDIO_PACKAGES[@]}"` to `TARGET_BASE_PACKAGES` (alongside the
existing `"${UWSM_RUNTIME_PACKAGES[@]}"` splice):

```bash
TARGET_BASE_PACKAGES=(
  linux-image-amd64 linux-headers-amd64 zfs-initramfs zfs-dkms zfsutils-linux
  zfs-zed
  mdadm dosfstools efibootmgr network-manager sudo locales
  console-setup ca-certificates curl greetd tuigreet kitty openssh-server
  psmisc
  shim-signed mokutil sbsigntool
  "${UWSM_RUNTIME_PACKAGES[@]}"
  "${AUDIO_PACKAGES[@]}"
  intel-microcode amd64-microcode hwdata xwayland xkb-data
)
```

Notes:
- **No `non-free` needed.** `DEBIAN_COMPONENTS` is
  `main contrib non-free-firmware`; every audio package is in `main` except
  `firmware-sof-signed`, which is in the already-enabled `non-free-firmware`.
- **Services.** Debian's PipeWire user units are enabled via the user preset
  and socket-activate inside the graphical session. With Change 1 in place
  (`graphical-session.target` actually active), they come up automatically — no
  explicit enable needed. If a target ever comes up without sound, the manual
  fallback is `systemctl --global enable pipewire.socket pipewire-pulse.socket
  wireplumber.service`; treat that as a verification fallback, not a default.
- **Offline cache.** Adding packages to the base set means the offline cache
  must carry them. Re-run `--phase=cache` when building an offline image; the
  cache validator will flag them as missing otherwise.

**Test:** `tests/config.sh` already asserts base-package membership over
`printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"` (e.g. the `linux-headers-amd64`
check around line 50). Add assertions in the same block:
```bash
assert_contains "${out}" "pipewire-audio" "PipeWire audio in base set"
assert_contains "${out}" "wireplumber"    "WirePlumber (wpctl) in base set"
assert_contains "${out}" "brightnessctl"  "brightness key binary in base set"
assert_contains "${out}" "playerctl"      "media key binary in base set"
```

---

## Change 3 — Precision 7780 SOF mic override

Hardware-specific, implemented in core as a **DMI-guarded modprobe.d drop-in**
(decision locked). Mirrors the existing `nvidia-options.conf` precedent
(`scripts/40-system.sh:244`, `cat >"${TARGET}/etc/modprobe.d/…" <<'EOF'`).
Guard on DMI so it is a strict no-op on the VM target and any non-7780 machine
(the installer runs on the target in a live session, so `/sys/class/dmi/id`
reflects the real hardware).

Add to `scripts/40-system.sh`:
```bash
# Dell Precision 7780: the kernel auto-selects legacy HDA for the SoundWire
# dual digital-array mics (near full-scale samples). Force Linux's SOF driver.
# DMI-guarded: a strict no-op on any other machine (VM, workstation).
configure_audio_quirks() {
  local product=""
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  [[ "${product}" == *"Precision 7780"* ]] || return 0
  info "Dell Precision 7780 detected: forcing SOF SoundWire audio driver."
  cat >"${TARGET}/etc/modprobe.d/dell-precision-7780-audio.conf" <<'EOF'
# Managed by installer.sh: force Linux's SOF driver for the Precision 7780
# SoundWire internal audio interface and dual digital-array microphones.
options snd_intel_dspcfg dsp_driver=3
EOF
}
```

Wire it into `phase_system()` (`scripts/40-system.sh:353`) **after**
`install_base_packages` (so `firmware-sof-signed` is present) and **before**
`configure_zfs_boot_support` (whose `update-initramfs -u -k all` at line ~350
then captures the drop-in — no extra rebuild needed):
```bash
phase_system() {
  …
  install_base_packages
  configure_locale_tz
  configure_audio_quirks      # <-- new, before initramfs is rebuilt
  create_user
  configure_zfs_boot_support  # ends with update-initramfs -u -k all
  …
}
```
Confirm the ordering: `configure_audio_quirks` must run before the final
`update-initramfs` in `configure_zfs_boot_support`. If you prefer isolation,
give the function its own `in_target "update-initramfs -u"` like the NVIDIA
path does — but the shared rebuild is cheaper.

**Test:** add `tests/audio.sh` modeled on `tests/nvidia.sh` (which already
tests a modprobe.d drop-in landing in `${TARGET}/etc/modprobe.d/`). Cover both
branches: with `product_name` matching → file written containing
`dsp_driver=3`; non-matching → file absent. Stub the DMI read (e.g. point the
function at a fake `product_name` source, or factor the read into a variable
the test can preset). Register nothing extra — `tests/run-all.sh` auto-includes
`tests/*.sh`.

**Alternative considered and rejected:** shipping the existing
`precision-7780-audio-fix_1.0.0-1_all.deb`
(`github.com/tkirkland/precision-7780-audio-fix`) as an `addons/*.deb`. Kept out
of core because it is not DMI-guarded (applies on whatever machine installs it)
and couples the build to an external artifact; its dependency closure would also
overlap Change 2. The DMI-guarded in-core drop-in above matches the installer's
"one specific machine, self-contained" ethos and is a strict no-op on VM/other
hardware.

---

## Out of scope (do NOT do here)

- **tuigreet session menu** (`--remember-session --sessions …`). The current
  `--cmd /usr/local/bin/hypr-session` works for a single session; the menu is
  optional recovery polish, a separate change.
- **Wi-Fi/Ethernet firmware** (`firmware-iwlwifi`, `firmware-realtek`). Adjacent
  to the audio firmware but a networking concern; add separately if wanted (both
  in `non-free-firmware`).
- **The rest of the desktop layer** (portals, swaync, polkit, keyring, capture,
  fonts, power services). That belongs in `addons/`, not the bare core.

---

## Verification

Automated (must pass before commit):
```bash
bash tools/check.sh
bash tests/run-all.sh
```

Manual, on a real Precision 7780 after install + reboot + login via the UWSM
session:
```bash
systemctl --user is-active graphical-session.target   # expect: active
systemctl --user is-active wayland-wm@hyprland.desktop.service  # active
busctl --user list | grep -i Notifications            # (desktop layer; n/a here)
wpctl status                                           # sinks + sources present
pactl info | grep 'Server Name'                        # PipeWire (PulseAudio)
# mic sanity: record and confirm it is NOT near full-scale
arecord -d 3 -f S16_LE /tmp/m.wav && aplay /tmp/m.wav
cat /sys/class/dmi/id/product_name                     # confirms the guard hit
```
The first two lines failing on `inactive` means Change 1 didn't take (finalize
missing or not on the start hook). No `wpctl` / no sinks means Change 2's
packages didn't land.

---

## Commit checklist

- [ ] Change 1: `scripts/60-hyprland.sh` finalize line + `tests/hyprland-config.sh`
      assertion.
- [ ] Change 2: `lib/00-config.sh` `AUDIO_PACKAGES` + splice + `tests/config.sh`
      assertions.
- [ ] Change 3 (Option A): `scripts/40-system.sh` `configure_audio_quirks` +
      `phase_system` wiring + `tests/audio.sh`.
- [ ] `bash tools/check.sh` clean.
- [ ] `bash tests/run-all.sh` clean.
- [ ] Offline image: re-run `--phase=cache` so the new packages are cached.
- [ ] Commit messages follow this repo's convention (see `git log`: `fix:` /
      `feat:` with issue refs where relevant).
