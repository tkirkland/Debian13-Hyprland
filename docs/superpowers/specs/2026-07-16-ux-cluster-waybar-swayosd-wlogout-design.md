# UX cluster — waybar (#68), swayosd (#75), wlogout (#77) — Design

**Date:** 2026-07-16
**Issues:** [#68](https://github.com/tkirkland/Debian13-Hyprland/issues/68),
[#75](https://github.com/tkirkland/Debian13-Hyprland/issues/75),
[#77](https://github.com/tkirkland/Debian13-Hyprland/issues/77)
**Status:** Draft for review

## Goal

Give installed systems a status bar with tray (#68), on-screen display for
volume/brightness keys (#75), and a graphical power/logout menu (#77) — all
generic upstream-flavored defaults, baked into the deploy image, following
the existing staging patterns (swaync precedent).

## Process

Three branches, three merges, in order: `feat/68-waybar`, `feat/75-swayosd`,
`feat/77-wlogout`. Each branch: pilot on the live Dell first → port generic
config to the installer → ISO build → VM gate ending in a user-witnessed
graphical login showing the feature working → merge to develop. Nothing
personal from the Dell ports verbatim; only the wiring pattern does.

## Verified facts the design rests on

- All three tools are in trixie: waybar 0.12.0-1, swayosd 0.1.0-5,
  wlogout 1.2.2-1.
- **waybar is uninstallable as-is** next to the stack: waybar Depends
  `libxkbregistry0 (>= 1.0.0)`; Debian's libxkbregistry0 pins
  `libxkbcommon0 (= 1.7.0-2)`, which Conflicts the stack `xkbcommon 1.13.2`.
  The stack deb already **ships** `libxkbregistry.so.0.13.2` + headers +
  pkgconfig — it just doesn't declare it.
- `swayosd + wlogout` resolve cleanly on the Dell (2 new packages, 0
  removed, no held package touched; verified via `apt-get install -s`).
- waybar's deb ships a user unit `/usr/lib/systemd/user/waybar.service`
  (`WantedBy=graphical-session.target`, `Restart=on-failure`, SIGUSR2
  reload). swayosd's deb ships **no user unit** for `swayosd-server` (only
  the system-side libinput backend: D-Bus-activated service + polkit +
  udev). wlogout ships no units (run-on-demand).
- waybar's bluetooth module does **not** self-hide without an adapter (it
  renders `format-no-controller`); an empty format hides it. Battery is
  believed to self-hide without `BAT*` (medium confidence — verify in the
  VM gate).
- wlogout layout = newline-separated bare JSON objects
  (`label/action/text/keybind`); user `~/.config/wlogout/` fully shadows
  `/etc/wlogout/` (no merging); the default style.css references icons by
  absolute path, so a custom style.css must re-declare the
  `background-image` rule per `#label`.
- Repo keybind reality: brightness binds are repo-owned
  (`hypr-deb.lua` heredoc, `scripts/60-hyprland.sh:612-613` →
  `brightness-sync up/down`). Volume/mic binds pass through **verbatim from
  the upstream example** into split modules (wpctl commands). There is no
  repo-owned Super+M line: upstream binds it to
  `hyprshutdown || hl.dsp.exit()`, and `hyprshutdown` does not exist in the
  guiutils deb — so Super+M today is an instant compositor exit.
- `brightness-sync` (repo wrapper, `60-hyprland.sh:1526-1767`) does not
  branch internal/external in the key path; `_nudge_conn` (line 1676)
  branches on control **method**: `backlight:` (internal panel AND ddcci
  externals) vs `gamma` (hyprdim D-Bus). `_is_internal()` exists at
  line 1566. `_apply_conn` (line 1653) is shared by set/reconcile/restore —
  the key-path swap must not touch it, nor the hypridle dim/lock paths.
- Package adds to `TARGET_BASE_PACKAGES` invalidate both the pool stamp
  (name hash, `scripts/10-cache.sh:30-36`) and the golden reuse stamp
  (pool-filename hash + pkgset check, `tools/build-iso.sh:625-631`)
  automatically — no `recipe_rev` bump needed. A version-bumped xkbcommon
  deb changes the poolhash too.

## #68 waybar

**Prerequisite — xkbcommon packaging fix (same branch):** add
`libxkbregistry0, libxkbregistry-dev` to the `[xkbcommon]` entries of
`HYPR_DEB_PROVIDES` / `HYPR_DEB_CONFLICTS` / `HYPR_DEB_REPLACES`
(`lib/00-config.sh:394-405`). The pipeline already emits versioned Provides
(`libxkbcommon0 (= 1.13.2)` on the live box), so waybar's versioned dep
resolves against ours and Debian's libxkbregistry0/libxkbcommon0 never
enter the transaction. Bump the deb revision so the pool picks up the new
control fields. Dell pilot installs the rebuilt deb with `dpkg -i`
(hold only gates apt), then `apt install waybar`.

*No-breakage gate for the packaging change:* the edit is purely additive
(declaring a library the deb already ships). Verify on the Dell after
`dpkg -i`: `apt-get check` clean, `apt-get -s upgrade` proposes no changes
to the stack, `apt-mark showhold` still lists all 20, ldd of a stack binary
unchanged, and Hyprland session survives a relogin. The ISO VM gate then
proves the install path end to end.

- **Package:** `waybar` → `TARGET_BASE_PACKAGES`.
- **Unit:** the deb's `waybar.service`, enabled via the dangling
  `ln -sf` pattern into
  `${TARGET}/etc/systemd/user/graphical-session.target.wants/`
  (`60-hyprland.sh:1797-1806` precedent) — not `systemctl --global enable`.
- **Config:** `stage_waybar_config()` modeled on `stage_swaync_config()`
  (`60-hyprland.sh:1036-1136`): dirs via `${TARGET}$(user_config_home)`
  (skel-aware for the golden bake), two heredocs →
  `~/.config/waybar/config.jsonc` + `style.css`, called from
  `stage_session_configs()` alongside the swaync call; phase `chown -R`
  covers ownership.
- **Modules:** left `hyprland/workspaces` + `hyprland/window`; center
  `clock`; right `tray`, `wireplumber`, `network`, `bluetooth`, `battery`.
  `bluetooth.format-no-controller: ""` (explicit hide). Battery self-hide
  verified at the VM gate; if it renders junk on the desktop profile, set
  its no-battery formats empty likewise.
- **Style:** swaync palette — `#1e1e2e` bar, `#f5f5f5` text,
  `#33ccff→#00ff99` gradient accent on the focused workspace.
- **Test:** `tests/waybar-config.sh` (auto-discovered by
  `tests/run-all.sh`; stub `info/warn/in_target/fatal` before sourcing
  `scripts/60-hyprland.sh`, per the swaync test): asserts package listed,
  config valid JSON(C) via python3 when present, load-bearing module keys,
  palette strings, and the wants-symlink staging.

## #75 swayosd

- **Package:** `swayosd` → `TARGET_BASE_PACKAGES`.
- **Server unit:** deb ships none → stage a `swayosd.service` user unit
  (glue, `/usr/lib/systemd/user` in the target, matching hyprdim.service
  staging) + `ln -sf` into `graphical-session.target.wants`. The libinput
  backend needs nothing (D-Bus-activated system service in the deb); it
  provides caps/num-lock OSD for free.
- **Volume/mic keybinds:** the upstream wpctl binds pass through from the
  example config — replace by `sed` matching **text, not line numbers** (the
  brightnessctl-bind deletion at `60-hyprland.sh:505-507` is the precedent):
  `XF86AudioRaiseVolume/LowerVolume/Mute` → `swayosd-client
  --output-volume raise|lower|mute-toggle`, `XF86AudioMicMute` →
  `swayosd-client --input-volume mute-toggle` (all `locked`, volume keys
  `repeating`). `--max-volume` left default. playerctl media binds
  untouched.
- **Brightness (display-only OSD — swayosd adheres to the implemented
  workflow):** `brightness-sync` remains the **sole** brightness change
  path on all three methods (internal backlight, ddcci externals, hyprdim
  gamma) — swayosd never sets brightness. Keys stay bound to
  `brightness-sync up/down`; at the end of the wrapper's `up`/`down`
  handling it fires
  `swayosd-client --custom-message "Brightness N%" --custom-icon
  display-brightness-symbolic` with the wrapper's computed level
  (best-effort, `|| true` — OSD absence must never break the nudge). No
  changes to `_nudge_conn`'s control arms, `_apply_conn`,
  dim/restore/lock, or hypridle wiring.
  - **Pilot check (Dell):** OSD renders on brightness keys for both an
    internal-panel step and an external (ddcci/gamma) step, and the levels
    shown track the wrapper's state.
- **Style:** small user-level `style.css` on the installer palette
  (`/etc/xdg/swayosd/style.css` is the deb default; ours goes to the user
  config dir, not the conffile).
- **Test:** `tests/swayosd-config.sh`: package listed, unit staged +
  wants-linked, seds produced swayosd-client volume binds in the split
  module, wrapper's up/down path fires the `--custom-message` OSD call and
  the control arms (`_nudge_conn`/`_apply_conn`) contain no swayosd calls.

## #77 wlogout

- **Package:** `wlogout` → `TARGET_BASE_PACKAGES`.
- **Config:** `stage_wlogout_config()` staging
  `~/.config/wlogout/layout` + `style.css` (skel-aware; `/etc/wlogout`
  conffiles never touched). Layout, five buttons, no hibernate
  (root-on-zfs installs have no resume-capable swap):
  - lock → `loginctl lock-session` (hypridle handles the logind Lock
    signal; `lock_cmd` confirmed at `60-hyprland.sh:709`)
  - logout → `uwsm stop` (the session runs under uwsm)
  - suspend → `systemctl suspend`
  - reboot → `systemctl reboot`
  - shutdown → `systemctl poweroff`
- **Style:** re-declare the absolute-path
  `background-image: image(url("/usr/share/wlogout/icons/<label>.png"))`
  rule per button (required — user style fully shadows the default), on the
  installer palette; 2×3-ish grid comes from wlogout defaults.
- **Keybind:** `sed`-replace the upstream Super+M line
  (`hyprshutdown || hl.dsp.exit()` — dead fallback today) in the split
  module with a wlogout launch. Net effect: Super+M opens the menu; logout
  is one of its buttons.
- **Test:** `tests/wlogout-config.sh`: package listed, layout is valid
  newline-JSON with the five actions (no hibernate), style re-declares all
  five icon rules, Super+M sed applied.

## Error handling / edge cases

- Bar/OSD absence must never break login: units are `graphical-session`
  -bound with `Restart=on-failure` (waybar) — a crashing bar restarts, a
  missing one leaves the session usable (same posture as swaync).
- VM/desktop profile: no battery, no bluetooth adapter, no backlight —
  battery/bluetooth hide (verified at gate), brightness keys no-op exactly
  as today (gamma path with no hyprdim targets).
- wlogout on a machine without logind lock handler: lock button no-ops
  visibly; acceptable (hypridle is always staged by this installer).

## Out of scope

- nm-applet/blueman applets (waybar built-ins chosen instead).
- swayosd `--custom-progress` bar for gamma externals (0.1.0 lacks it).
- README/#94 work; theming (#76/#51 closed separately).

## Constraints

- Unscoped conventional commits (`feat: ...`).
- Merges into develop free-form; master PR-only; **no new PRs/issues
  without asking** (moratorium stands).
- `tools/check.sh` (shellcheck) + `tests/run-all.sh` green per branch.
