# Secure Boot Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every install is secure-boot ready: shim fronts all three bootloaders, the dkms MOK key signs everything self-built (loader binaries + kernel modules), enrollment is staged via mokutil, and the OpenZFS source build moves to a per-job firstboot runner.

**Architecture:** shim (Microsoft-signed) becomes the NVRAM entry for every loader and chain-loads the real loader from the `grubx64.efi` name beside it. GRUB uses Debian's signed packages; ZBM/systemd-boot binaries are sbsign-ed with the dkms MOK key (`/var/lib/dkms/mok.key`), the same key dkms uses for modules — one enrollment covers both. `--zfs-from-source` changes semantics: repo zfs 2.3.x installs normally; upstream's release builds at first boot (post-enrollment) via a generalized per-job firstboot runner.

**Tech Stack:** bash, shim-signed, mokutil, sbsigntool, openssl, dkms, systemd oneshot units. Tests: repo's source-and-assert-on-function-body pattern (`tests/test-helpers.sh`).

**Spec:** `docs/superpowers/specs/2026-06-12-secureboot-design.md`. Branch: `feat/secureboot` (already created).

**Key file facts (verified against current code):**
- `lib/00-config.sh:271` `TARGET_BASE_PACKAGES`; `:304` `LIVE_TOOL_PACKAGES`; `:239` `ZFS_FROM_SOURCE`; `:243` `ZFS_DEBIAN_PACKAGES`; `:245` `ZFS_BUILD_PACKAGES`.
- `scripts/00-preflight.sh:257` `phase_preflight`; `:198` `bootstrap_live_tools` with `pkg_probe` map at `:201`.
- `scripts/40-system.sh:48` `install_base_packages` (filters ZFS pkgs when `ZFS_FROM_SOURCE`, then calls `install_zfs_from_source:85`); `:243` `phase_system`.
- `scripts/50-boot.sh:27` `write_esp_sync_hook`; `:62` `create_nvram_entry`; `:113` `install_zbm`; `:147` `install_grub`; `:178` `install_sdboot`; `:194` `phase_boot`.
- `scripts/60-hyprland.sh:348` `stage_firstboot` (monolithic runner + unit); `:410` `phase_hyprland`.
- `scripts/90-verify.sh:32` `phase_verify`; `vcheck` helper at `:8`; `ZFS_FROM_SOURCE` check at `:125`.
- Debian facts the code relies on: `shim-signed` ships `/usr/lib/shim/shimx64.efi.signed`; its dependency `shim-helpers-amd64-signed` ships `/usr/lib/shim/mmx64.efi.signed`. Debian dkms signs modules with `/var/lib/dkms/mok.key` (PEM, passphrase-less) + `/var/lib/dkms/mok.pub` (DER cert), generating them on demand. `mokutil --import` wants DER; `sbsign`/`sbverify` want PEM. systemd-boot's canonical binary: `/usr/lib/systemd/boot/efi/systemd-bootx64.efi`.

---

### Task 1: Config — secure boot globals and packages

**Files:**
- Modify: `lib/00-config.sh`
- Create: `tests/secureboot.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/secureboot.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: secure boot support"

cfg="$(bash -c 'source lib/00-config.sh
  echo "${TARGET_BASE_PACKAGES[*]}"
  echo "${MOK_KEY}|${MOK_CRT}|${MOK_PEM}"')"
assert_contains "${cfg}" "shim-signed" "shim-signed in target base packages"
assert_contains "${cfg}" "mokutil" "mokutil in target base packages"
assert_contains "${cfg}" "sbsigntool" "sbsigntool in target base packages"
assert_contains "${cfg}" \
  "/var/lib/dkms/mok.key|/var/lib/dkms/mok.pub|/var/lib/dkms/mok.pem" \
  "MOK key/cert paths match Debian dkms defaults"

live="$(bash -c 'source lib/00-config.sh; echo "${LIVE_TOOL_PACKAGES[*]}"')"
assert_contains "${live}" "openssl" "openssl available in the live env (key gen)"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `MOK_KEY: unbound variable` (or empty), `shim-signed not found`.

- [ ] **Step 3: Implement config changes**

In `lib/00-config.sh`, change the `TARGET_BASE_PACKAGES` array (line ~271) — add one line after `psmisc`:

```bash
  psmisc
  shim-signed mokutil sbsigntool
```

Add `openssl` to `LIVE_TOOL_PACKAGES` (line ~304), after `psmisc`:

```bash
LIVE_TOOL_PACKAGES=(
  debootstrap gdisk parted mdadm dosfstools zfsutils-linux zfs-dkms
  "${LIVE_KERNEL_HEADERS}" apt-utils git curl efibootmgr rsync psmisc
  openssl
)
```

Add a new section after the `# --- Bootloader ---` block (after `KERNEL_CMDLINE_EXTRA`, line ~105):

```bash
# --- Secure boot ---------------------------------------------------------------
# Always on. The dkms MOK keypair signs everything self-built: dkms signs
# kernel modules with it automatically; the boot phase signs loader EFI
# binaries (zbm / systemd-boot) with the same key. GRUB needs no self-
# signing (Debian ships signed shim + GRUB). Paths are target-side and
# fixed: they are what Debian's dkms uses.
MOK_KEY="/var/lib/dkms/mok.key" # PEM private key, passphrase-less
MOK_CRT="/var/lib/dkms/mok.pub" # DER certificate (dkms + mokutil format)
MOK_PEM="/var/lib/dkms/mok.pem" # PEM certificate (sbsign/sbverify format)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/secureboot.sh`
Expected: PASS (5 ok lines).

- [ ] **Step 5: Run the existing suite to catch regressions**

Run: `bash tests/run-all.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/00-config.sh tests/secureboot.sh
git commit -m "feat: add secure boot packages and MOK key config"
```

---

### Task 2: Preflight — fatal when secure boot is enforcing in the live env

**Files:**
- Modify: `scripts/00-preflight.sh`
- Modify: `tests/secureboot.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
pre_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  declare -f check_secureboot_disabled phase_preflight')"
assert_contains "${pre_body}" "mokutil --sb-state" \
  "preflight probes secure boot state via mokutil"
assert_contains "${pre_body}" "SecureBoot-8be4df61" \
  "preflight falls back to the SecureBoot efivar"
assert_contains "${pre_body}" "DISABLE secure boot" \
  "preflight failure explains the remedy"
assert_contains "${pre_body}" "check_secureboot_disabled" \
  "phase_preflight calls the secure boot check"
assert_contains "${pre_body}" "Enroll MOK" \
  "remedy explains MokManager enrollment"

# openssl probe so bootstrap_live_tools installs it when missing.
assert_contains "${pre_body}" "[openssl]=openssl" \
  "live tool bootstrap probes for openssl" || true
boot_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  declare -f bootstrap_live_tools')"
assert_contains "${boot_body}" "openssl" "openssl probed by live bootstrap"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `declare -f check_secureboot_disabled` finds nothing (bash -c exits nonzero, captured string empty → assertions fail).

- [ ] **Step 3: Implement the preflight check**

In `scripts/00-preflight.sh`, add after `require_root()` (line ~7):

```bash
# Secure boot must be OFF while installing: the storage phase loads the
# live session's own ZFS dkms module, which is locally built and not
# enrolled in this firmware — a secure-boot (lockdown) kernel refuses it
# and the install would die at pool creation. The INSTALLED system is
# fully secure-boot ready; only the live session cannot be.
check_secureboot_disabled() {
  local var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  local enabled=0
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
      enabled=1
    fi
  elif [[ -r "${var}" ]]; then
    # Payload byte 5 (after the 4-byte attribute header): 1 = enforcing.
    if [[ "$(od -An -tu1 -j4 -N1 "${var}" 2>/dev/null |
      tr -d '[:space:]')" == "1" ]]; then
      enabled=1
    fi
  fi
  ((enabled)) || return 0
  fatal "Secure boot is ENABLED in this live environment — the installer" \
    "cannot proceed. The live session must load its own locally-built ZFS" \
    "module, which this firmware does not trust, so pool creation would" \
    "fail. Do this instead:" \
    "(1) reboot into firmware setup and DISABLE secure boot;" \
    "(2) run the installer (everything gets pre-signed);" \
    "(3) boot the installed system — at the blue MokManager screen choose" \
    "'Enroll MOK' and enter your user password;" \
    "(4) re-enable secure boot in firmware. It will boot."
}
```

In `phase_preflight()` (line ~257), add the call directly after `require_root`:

```bash
phase_preflight() {
  require_root
  check_secureboot_disabled
  validate_identity_settings
```

In `bootstrap_live_tools()` `pkg_probe` map (line ~201), add the openssl entry:

```bash
    [psmisc]=fuser [openssl]=openssl
```

- [ ] **Step 4: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/00-preflight.sh tests/secureboot.sh
git commit -m "feat: refuse to install while secure boot is enforcing"
```

---

### Task 3: MOK keypair creation before package installs

**Files:**
- Modify: `scripts/40-system.sh`
- Modify: `tests/secureboot.sh`

The keypair must exist before `apt-get install zfs-dkms` runs (its postinst builds and signs the module). Generate host-side with the live env's openssl, writing into the target — the chroot has no openssl until base packages land (chicken-and-egg).

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
sys_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh
  declare -f ensure_mok_key phase_system')"
assert_contains "${sys_body}" "openssl req -new -x509" \
  "MOK keypair generated with openssl"
assert_contains "${sys_body}" "outform DER" \
  "MOK certificate is DER (dkms/mokutil format)"
assert_contains "${sys_body}" "chmod 600" "private key is chmod 600"

# Generation must precede package install (dkms postinst signs with it).
order="$(printf '%s' "${sys_body}" | grep -n \
  -e ensure_mok_key -e install_base_packages |
  grep -A2 'phase_system' || true)"
phase_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh; declare -f phase_system')"
mok_line="$(printf '%s\n' "${phase_body}" | grep -n 'ensure_mok_key' | cut -d: -f1 | head -n1)"
pkg_line="$(printf '%s\n' "${phase_body}" | grep -n 'install_base_packages' | cut -d: -f1 | head -n1)"
if [[ -n "${mok_line}" && -n "${pkg_line}" ]] && ((mok_line < pkg_line)); then
  echo "  ok: ensure_mok_key runs before install_base_packages"
else
  echo "  FAIL: ensure_mok_key must run before install_base_packages" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
```

(The `order=` line is scaffolding-free: only the `mok_line`/`pkg_line` comparison asserts. Remove the `order=` line entirely when writing — assert with the two-line comparison only.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `ensure_mok_key` not defined.

- [ ] **Step 3: Implement**

In `scripts/40-system.sh`, add before `install_base_packages()` (line ~48):

```bash
# dkms signs every module it builds with this keypair and the boot phase
# signs loader EFI binaries with it. Debian's dkms would generate it on
# demand, but the zfs-dkms postinst (during install_base_packages) is the
# first consumer, so it must exist before packages land. Generated with
# the LIVE environment's openssl (the chroot has none yet). Parameters
# mirror Debian dkms defaults: passphrase-less RSA 2048, DER certificate.
ensure_mok_key() {
  if [[ -f "${TARGET}${MOK_KEY}" && -f "${TARGET}${MOK_CRT}" ]]; then
    return 0
  fi
  mkdir -p "${TARGET}/var/lib/dkms"
  openssl req -new -x509 -nodes -days 36500 -newkey rsa:2048 \
    -subj "/CN=hypr-deb DKMS module signing key/" \
    -keyout "${TARGET}${MOK_KEY}" -outform DER \
    -out "${TARGET}${MOK_CRT}" 2>/dev/null ||
    fatal "MOK keypair generation failed (openssl)."
  chmod 600 "${TARGET}${MOK_KEY}"
  info "Generated MOK signing keypair at ${MOK_KEY}."
}
```

In `phase_system()` (line ~243), add the call before `install_base_packages`:

```bash
phase_system() {
  write_identity
  write_fstab
  write_mdadm_conf
  ensure_mok_key
  install_base_packages
```

- [ ] **Step 4: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/40-system.sh tests/secureboot.sh
git commit -m "feat: generate dkms MOK keypair before target packages install"
```

---

### Task 4: Generalize the firstboot runner to per-job scripts

**Files:**
- Modify: `scripts/60-hyprland.sh:346-408` (`stage_firstboot`)
- Modify: `scripts/90-verify.sh:40-47` (firstboot vchecks)
- Modify: `tests/secureboot.sh`

Currently `stage_firstboot` writes a monolithic `/usr/local/sbin/hypr-deb-firstboot` that builds Hyprland. Split: a generic runner executes `/usr/local/lib/hypr-deb/firstboot.d/*.sh` lexically; the Hyprland build becomes job `50-hyprland-build.sh`. This is the extension point for the ZFS upgrade job (Task 5) and later NVIDIA (issue #4).

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
hypr_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/60-hyprland.sh
  declare -f stage_firstboot_runner stage_firstboot' 2>/dev/null || true)"
assert_contains "${hypr_body}" "firstboot.d" \
  "runner executes a per-job directory"
assert_contains "${hypr_body}" '${job%.sh}.done' \
  "successful jobs renamed .done"
assert_contains "${hypr_body}" '${job%.sh}.failed' \
  "failed jobs renamed .failed (boot continues)"
assert_contains "${hypr_body}" "hypr-deb-reboot-required" \
  "jobs can request a reboot via flag file"
assert_contains "${hypr_body}" "50-hyprland-build.sh" \
  "hyprland build staged as a firstboot job"
assert_contains "${hypr_body}" "Before=greetd.service" \
  "firstboot unit runs pre-login"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `stage_firstboot_runner` not defined.

- [ ] **Step 3: Implement the runner split**

In `scripts/60-hyprland.sh`, replace the whole `stage_firstboot()` function (lines 348–408) with:

```bash
# Shared firstboot machinery: a per-job directory so independent features
# (Hyprland build, ZFS upgrade, future NVIDIA detect — issue #4) each
# stage one script instead of growing a monolith. Jobs run lexically,
# pre-login (Before=greetd). Success renames the job .done; failure
# renames it .failed and the boot CONTINUES — jobs must leave the system
# usable when they fail. The unit disables itself once no runnable jobs
# remain; a job requests a reboot by touching /run/hypr-deb-reboot-required.
stage_firstboot_runner() {
  if [[ -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot" ]]; then
    return 0
  fi
  mkdir -p "${TARGET}/usr/local/sbin" \
    "${TARGET}/usr/local/lib/hypr-deb/firstboot.d" \
    "${TARGET}/etc/systemd/system"
  cat >"${TARGET}/usr/local/sbin/hypr-deb-firstboot" <<'EOF'
#!/usr/bin/env bash
# Hypr-Deb firstboot job runner (staged by installer.sh). Runs every
# /usr/local/lib/hypr-deb/firstboot.d/*.sh in lexical order.
set -uo pipefail
dir=/usr/local/lib/hypr-deb/firstboot.d
shopt -s nullglob
for job in "${dir}"/*.sh; do
  echo "hypr-deb-firstboot: running ${job##*/}" >&2
  if bash "${job}"; then
    mv "${job}" "${job%.sh}.done"
  else
    mv "${job}" "${job%.sh}.failed"
    echo "hypr-deb-firstboot: JOB FAILED: ${job##*/} — system left as-is;" \
      "inspect the journal, then re-run with: bash ${job%.sh}.failed" >&2
  fi
done
remaining=("${dir}"/*.sh)
if ((${#remaining[@]} == 0)); then
  systemctl disable hypr-deb-firstboot.service
fi
if [[ -f /run/hypr-deb-reboot-required ]]; then
  rm -f /run/hypr-deb-reboot-required
  systemctl reboot
fi
EOF
  chmod +x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"

  cat >"${TARGET}/etc/systemd/system/hypr-deb-firstboot.service" <<'EOF'
[Unit]
Description=Hypr-Deb first-boot jobs
Before=greetd.service
ConditionPathExists=/usr/local/sbin/hypr-deb-firstboot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hypr-deb-firstboot
StandardOutput=journal+console
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  in_target "systemctl enable hypr-deb-firstboot.service"
}

stage_firstboot() {
  info "Staging first-boot build..."
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}" "${TARGET}/usr/local/lib/hypr-deb"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    stage_source "${name}"
  done
  install_build_deps # toolchain present so firstboot works offline

  # Authoritative manifest so the staged resolve_all_tags works offline.
  local manifest="${TARGET}${TARGET_CACHE_DIR}/sources/MANIFEST"
  mkdir -p "${TARGET}${TARGET_CACHE_DIR}/sources"
  : >"${manifest}"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    echo "${name} ${HYPR_RESOLVED_TAG["${name}"]}" >>"${manifest}"
  done

  cp lib/00-config.sh lib/01-log.sh scripts/60-hyprland.sh \
    "${TARGET}/usr/local/lib/hypr-deb/"

  stage_firstboot_runner
  cat >"${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh" <<EOF
#!/usr/bin/env bash
# Firstboot job: one-shot Hyprland build (staged by installer.sh).
set -euo pipefail
source /usr/local/lib/hypr-deb/00-config.sh
source /usr/local/lib/hypr-deb/01-log.sh
source /usr/local/lib/hypr-deb/60-hyprland.sh
TARGET=""           # build on the running system
NETWORK_AVAILABLE=0 # sources are pre-staged; no network needed
CACHE_DIR="${TARGET_CACHE_DIR}"
KEEP_BUILD_DEPS=${KEEP_BUILD_DEPS}
resolve_all_tags
check_compat "\${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
for name in "\${HYPR_BUILD_ORDER[@]}"; do
  build_one "\${name}"
done
test -x /usr/local/bin/Hyprland
purge_build_deps
info "First-boot Hyprland build complete."
EOF
  chmod +x "${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
}
```

Note the job script no longer runs `systemctl disable` — the runner owns unit lifecycle now.

- [ ] **Step 4: Update the firstboot vchecks in `scripts/90-verify.sh`**

Replace lines 40–47 (the `if ((BUILD_ON_FIRSTBOOT))` block's first four vchecks):

```bash
  if ((BUILD_ON_FIRSTBOOT)); then
    vcheck "firstboot unit enabled" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
    vcheck "firstboot runner staged" \
      test -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"
    vcheck "hyprland firstboot job staged" test -x \
      "${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
    vcheck "sources staged" \
      test -d "${TARGET}/var/tmp/hypr-deb-build/hyprland"
    vcheck "toolchain staged for firstboot" in_target "command -v cmake"
  else
```

- [ ] **Step 5: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS (note `tests/orchestrator.sh` and `tests/verify-report.sh` source these files — if they assert on the old runner path `/usr/local/sbin/hypr-deb-firstboot`, that path is unchanged and still staged).

- [ ] **Step 6: Commit**

```bash
git add scripts/60-hyprland.sh scripts/90-verify.sh tests/secureboot.sh
git commit -m "refactor: per-job firstboot runner (extension point for zfs/nvidia jobs)"
```

---

### Task 5: Hybrid ZFS — repo zfs at install, source build as firstboot job

**Files:**
- Modify: `scripts/40-system.sh:48-139`
- Modify: `scripts/90-verify.sh:125-128`
- Modify: `lib/02-args.sh` (usage text for `--zfs-from-source`)
- Modify: `tests/secureboot.sh`

`--zfs-from-source` keeps its name but changes mechanics: Debian's zfs 2.3.x always installs (it must mount the ZFS root on boot #1, signed by the now-enrollable MOK key); the upstream build is staged as firstboot job `30-zfs-upgrade.sh` (runs before the Hyprland job's `50-`).

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
zfs_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh
  declare -f install_base_packages stage_zfs_upgrade_job write_zfs_upgrade_job' \
  2>/dev/null || true)"
assert_contains "${zfs_body}" "30-zfs-upgrade.sh" \
  "zfs upgrade staged as firstboot job"
assert_contains "${zfs_body}" "stage_firstboot_runner" \
  "zfs staging installs the shared runner"
assert_contains "${zfs_body}" "native-deb-utils" \
  "job builds upstream native debs"
assert_contains "${zfs_body}" "update-initramfs" \
  "job rebuilds the initramfs after the swap"
assert_contains "${zfs_body}" "hypr-deb-reboot-required" \
  "job requests a reboot"
if printf '%s' "${zfs_body}" | grep -q 'ZFS_DEBIAN_PACKAGES'; then
  echo "  FAIL: install_base_packages must no longer filter zfs packages" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: repo zfs always installs (no install-time replacement)"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `stage_zfs_upgrade_job` not defined, `ZFS_DEBIAN_PACKAGES` still referenced.

- [ ] **Step 3: Implement**

In `scripts/40-system.sh`:

(a) Simplify `install_base_packages()` (lines 48–75) — repo zfs always installs; the upgrade is staged, not substituted:

```bash
install_base_packages() {
  local pkgs=("${TARGET_BASE_PACKAGES[@]}")
  # VMware guest integration (display resize, clipboard, time sync,
  # clean shutdown). open-vm-tools-desktop layers desktop features on the
  # base daemon; both are pointless on bare metal, so VIRT_TYPE gates them.
  if [[ "${VIRT_TYPE}" == "vmware" ]]; then
    pkgs+=(open-vm-tools open-vm-tools-desktop)
  fi
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${pkgs[*]}
  "
  if ((ZFS_FROM_SOURCE)); then
    stage_zfs_upgrade_job
  fi
}
```

(b) Replace `install_zfs_from_source()` (lines 85–139) entirely with:

```bash
# --zfs-from-source (hybrid): the install keeps Debian's zfs 2.3.x — fast,
# dkms-signed in the chroot, and it mounts the ZFS root on boot #1. The
# upstream release builds at FIRST BOOT, after the MokManager screen has
# enrolled the MOK key, as firstboot job 30-zfs-upgrade.sh. Sources and
# build deps are staged now so the job needs no network. A failed build
# keeps the running 2.3.x: the system stays bootable and the job is
# re-runnable from its .failed file.
stage_zfs_upgrade_job() {
  ((NETWORK_AVAILABLE)) ||
    fatal "--zfs-from-source requires network to stage the source tree."
  local tag=""
  # Tags include dev-cycle markers (zfs-X.Y.99) that outrank real releases
  # in a version sort; the GitHub API names the actual latest release.
  tag="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/openzfs/zfs/releases/latest" 2>/dev/null |
    grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 || true)"
  [[ -n "${tag}" ]] ||
    tag="$(resolve_latest_release_tag "${ZFS_REPO_URL}" "${ZFS_TAG_PATTERN}")"
  info "Staging OpenZFS ${tag} for the first-boot upgrade build..."
  rm -rf "${TARGET}/var/tmp/openzfs"
  git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
    "${ZFS_REPO_URL}" "${TARGET}/var/tmp/openzfs"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${ZFS_BUILD_PACKAGES[*]}
  "
  stage_firstboot_runner
  write_zfs_upgrade_job
}

write_zfs_upgrade_job() {
  local jobs="${TARGET}/usr/local/lib/hypr-deb/firstboot.d"
  mkdir -p "${jobs}"
  cat >"${jobs}/30-zfs-upgrade.sh" <<'EOF'
#!/usr/bin/env bash
# Firstboot job: build upstream OpenZFS (staged at install) as native
# Debian packages and replace the repo 2.3.x. dkms signs the module with
# the MOK key the user enrolled at the MokManager screen. ONLY
# native-deb-utils is built: it includes openzfs-zfs-dkms, whose postinst
# builds for the installed kernels. Upstream's deb recipes swallow
# dpkg-buildpackage failures, so required packages are asserted by name.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /var/tmp/openzfs
if dpkg-query -W 'openzfs-zfs-modules-*' >/dev/null 2>&1; then
  apt-get purge -y 'openzfs-zfs-modules-*'
fi
./autogen.sh
./configure
make -j"$(nproc)" native-deb-utils
for p in openzfs-zfs-dkms openzfs-zfsutils openzfs-zfs-initramfs \
  openzfs-zfs-zed; do
  ls /var/tmp/${p}_*.deb >/dev/null 2>&1 ||
    { echo "required package not built: ${p}" >&2; exit 1; }
done
debs="$(ls /var/tmp/*.deb |
  grep -Ev 'zfs-modules|test|dracut|dbg|-dev|pam' || true)"
[[ -n "${debs}" ]] ||
  { echo 'native-deb-utils produced no installable packages' >&2; exit 1; }
echo "${debs}" | xargs apt-get install -y
# pam_zfs_key registers itself in common-password and breaks chpasswd on
# systems without encrypted homes; keep it out and regenerate PAM.
if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
  apt-get purge -y 'openzfs*pam*'
fi
rm -f /usr/share/pam-configs/*zfs*
pam-auth-update --package
update-initramfs -u -k all
rm -rf /var/tmp/openzfs
rm -f /var/tmp/*.deb /var/tmp/*.changes /var/tmp/*.buildinfo
touch /run/hypr-deb-reboot-required
echo "OpenZFS upgrade complete; reboot pending." >&2
EOF
  chmod +x "${jobs}/30-zfs-upgrade.sh"
}
```

(c) In `lib/02-args.sh`, update the `--zfs-from-source` usage line (search for `zfs-from-source` in the usage text) to:

```
  --zfs-from-source     Stage upstream OpenZFS to build at first boot
                        (install keeps repo zfs; one extra reboot)
```

(d) In `scripts/90-verify.sh`, replace the `ZFS_FROM_SOURCE` block (lines 125–128):

```bash
  if ((ZFS_FROM_SOURCE)); then
    vcheck "zfs upgrade firstboot job staged" test -x \
      "${TARGET}/usr/local/lib/hypr-deb/firstboot.d/30-zfs-upgrade.sh"
    vcheck "zfs source tree staged" test -d "${TARGET}/var/tmp/openzfs"
    vcheck "firstboot unit enabled (zfs upgrade)" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
  fi
```

- [ ] **Step 4: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS. If `tests/args.sh` asserts on the old usage wording, update that assertion to the new text.

- [ ] **Step 5: Commit**

```bash
git add scripts/40-system.sh scripts/90-verify.sh lib/02-args.sh tests/secureboot.sh
git commit -m "feat: hybrid zfs - repo 2.3.x at install, upstream build as firstboot job"
```

---

### Task 6: Boot phase — shim, loader signing, MOK enrollment

**Files:**
- Modify: `scripts/50-boot.sh`
- Modify: `tests/secureboot.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
boot_sb="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh
  declare -f install_shim sign_loader stage_mok_enrollment ensure_mok_pem \
    install_zbm install_grub install_sdboot phase_boot write_esp_sync_hook \
    write_grub_cfg' 2>/dev/null || true)"
assert_contains "${boot_sb}" "shimx64.efi.signed" "shim copied from shim-signed"
assert_contains "${boot_sb}" "mmx64.efi.signed" "MokManager copied to ESP"
assert_contains "${boot_sb}" "sbsign --key" "self-built loaders MOK-signed"
assert_contains "${boot_sb}" "mokutil --import" "MOK enrollment staged"
assert_contains "${boot_sb}" 'EFI\\zbm\\shimx64.efi' \
  "zbm NVRAM entry points at shim"
assert_contains "${boot_sb}" 'EFI\\debian\\shimx64.efi' \
  "grub NVRAM entry points at shim"
assert_contains "${boot_sb}" 'EFI\\systemd\\shimx64.efi' \
  "systemd-boot NVRAM entry points at shim"
assert_contains "${boot_sb}" "grub-efi-amd64-signed" \
  "grub uses Debian's signed packages"
assert_contains "${boot_sb}" "--uefi-secure-boot" \
  "grub-install installs the signed chain"
assert_contains "${boot_sb}" "stage_mok_enrollment" \
  "phase_boot stages enrollment for every loader"
# Enrollment failure must warn, not abort (VMs without efivars).
enroll_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh; declare -f stage_mok_enrollment')"
if printf '%s' "${enroll_body}" | grep -q 'fatal'; then
  echo "  FAIL: stage_mok_enrollment must never be fatal" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: enrollment failure is warn-only"
fi
# sync hook re-signs systemd-boot when the package updates the binary.
hook_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh; declare -f write_esp_sync_hook')"
assert_contains "${hook_body}" "systemd-bootx64.efi" \
  "sync hook re-signs updated systemd-boot"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — `install_shim`, `sign_loader`, `stage_mok_enrollment` not defined.

- [ ] **Step 3: Implement secure boot helpers**

In `scripts/50-boot.sh`, add after `create_nvram_entry()` (line ~82):

```bash
# --- Secure boot ---------------------------------------------------------------
# Model: shim (Microsoft-signed) is the NVRAM entry and chain-loads the
# real loader from the 'grubx64.efi' name in its own directory. Debian
# signs grub; zbm and systemd-boot are self-shipped binaries, so they are
# MOK-signed like every other self-built artifact. The same dkms key signs
# kernel modules — one MokManager enrollment covers the whole system.

# sbsign/sbverify need the certificate in PEM; dkms keeps it in DER.
ensure_mok_pem() {
  in_target "
    set -e
    test -f '${MOK_PEM}' ||
      openssl x509 -inform DER -in '${MOK_CRT}' -out '${MOK_PEM}'
  "
}

install_shim() { # $1=ESP subdirectory under EFI/
  local dir="${TARGET}${ESP_MOUNT}/EFI/$1"
  mkdir -p "${dir}"
  cp "${TARGET}/usr/lib/shim/shimx64.efi.signed" "${dir}/shimx64.efi"
  cp "${TARGET}/usr/lib/shim/mmx64.efi.signed" "${dir}/mmx64.efi"
}

sign_loader() { # $1=source path (target-side), $2=ESP subdirectory under EFI/
  local src="$1" dir="$2"
  ensure_mok_pem
  in_target "
    set -e
    sbsign --key '${MOK_KEY}' --cert '${MOK_PEM}' \
      --output '${ESP_MOUNT}/EFI/${dir}/grubx64.efi' '${src}'
  "
}

# Stage MOK enrollment: MokManager processes it at the next boot through
# shim; the user confirms with the account password. Never fatal: without
# efivars (some VMs, plain chroots) the request cannot be written — the
# system still boots with secure boot off and the command can be run on
# the real machine later.
stage_mok_enrollment() {
  local rc=0
  if [[ -n "${USER_PASSWORD}" ]]; then
    printf '%s\n%s\n' "${USER_PASSWORD}" "${USER_PASSWORD}" |
      chroot "${TARGET}" mokutil --import "${MOK_CRT}" || rc=$?
  elif ((IS_INTERACTIVE)); then
    info "Choose a MOK password (you will re-enter it at first boot):"
    chroot "${TARGET}" mokutil --import "${MOK_CRT}" || rc=$?
  else
    warn "No USER_PASSWORD and non-interactive: MOK enrollment not" \
      "staged. Run 'mokutil --import ${MOK_CRT}' on the installed system."
    return 0
  fi
  if ((rc != 0)); then
    warn "mokutil --import failed (no efivars in this environment?)." \
      "Run 'mokutil --import ${MOK_CRT}' on the installed system, then" \
      "reboot and enroll at the MokManager screen."
  fi
}
```

- [ ] **Step 4: Wire shim into each loader**

(a) `install_zbm()` — after the `cp` of the EFI and before `zfs set`, add shim + signing, and change the NVRAM target:

```bash
install_zbm() {
  local efi_src="${CACHE_DIR}/zfsbootmenu.EFI"
  if [[ ! -f "${efi_src}" ]]; then
    ((NETWORK_AVAILABLE)) || fatal "No cached ZBM binary and no network."
    mkdir -p "${CACHE_DIR}"
    fetch_zbm_efi "${efi_src}"
  fi
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/zbm"
  cp "${efi_src}" "${TARGET}${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi"
  install_shim zbm
  sign_loader "${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi" zbm
  # ZBM reads the kernel cmdline from this dataset property.
  zfs set org.zfsbootmenu:commandline="rw ${KERNEL_CMDLINE_EXTRA}" \
    "${ROOT_DATASET}"
  create_nvram_entry "ZFSBootMenu" '\EFI\zbm\shimx64.efi'
}
```

(b) `install_grub()` — signed packages, `--uefi-secure-boot` (grub-install then places shim + signed grubx64.efi in EFI/debian itself), NVRAM at shim:

```bash
install_grub() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed
    grub-install --target=x86_64-efi --efi-directory=${ESP_MOUNT} \
      --boot-directory=${ESP_MOUNT}/EFI/debian --bootloader-id=debian \
      --uefi-secure-boot --no-nvram
  "
  write_esp_sync_hook
  run_esp_sync
  write_grub_cfg
  create_nvram_entry "debian" '\EFI\debian\shimx64.efi'
}
```

(c) `write_grub_cfg()` — Debian's *signed* GRUB image has its prefix baked in and reads `(esp)/EFI/debian/grub.cfg`, while a locally built image uses the `--boot-directory` prefix `EFI/debian/grub/grub.cfg`. Write the same cfg to both so either image finds it. Append to the end of `write_grub_cfg()`:

```bash
  # The Debian-signed grubx64.efi reads (esp)/EFI/debian/grub.cfg (baked-in
  # prefix); the locally-built image reads EFI/debian/grub/grub.cfg. Same
  # content at both paths covers whichever image shim chain-loads.
  cp "${TARGET}${ESP_MOUNT}/EFI/debian/grub/grub.cfg" \
    "${TARGET}${ESP_MOUNT}/EFI/debian/grub.cfg"
```

(d) `install_sdboot()` — shim + sign the canonical systemd-boot binary into the chain-load slot, NVRAM at shim:

```bash
install_sdboot() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y systemd-boot
    SYSTEMD_RELAX_ESP_CHECKS=1 bootctl install --no-variables \
      --esp-path=${ESP_MOUNT}
  "
  install_shim systemd
  sign_loader "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" systemd
  write_esp_sync_hook
  run_esp_sync
  write_sdboot_entries
  # --no-variables skips bootctl's NVRAM write (unreliable on a RAID1 ESP);
  # create the entry ourselves on both member disks.
  create_nvram_entry "Linux Boot Manager" '\EFI\systemd\shimx64.efi'
}
```

(e) `phase_boot()` — stage enrollment for every loader:

```bash
phase_boot() {
  detect_kernel
  case "${BOOTLOADER}" in
    zbm) install_zbm ;;
    grub) install_grub ;;
    systemd-boot) install_sdboot ;;
    *) fatal "BOOTLOADER not set (preflight should have ensured this)." ;;
  esac
  stage_mok_enrollment
}
```

(f) `write_esp_sync_hook()` — extend the embedded `hypr-deb-sync-esp` script so a package-updated systemd-boot binary gets re-signed into the chain-load slot (paths are hardcoded: the heredoc is quoted and these are the fixed dkms locations). Add before the final `sync` line inside the heredoc:

```bash
# Keep the MOK-signed systemd-boot copy fresh: package updates rewrite the
# canonical binary; shim chain-loads our signed copy on the ESP.
sd_src="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
sd_dst="/boot/efi/EFI/systemd/grubx64.efi"
if [[ -f "${sd_src}" && -f "${sd_dst}" && "${sd_src}" -nt "${sd_dst}" ]]; then
  sbsign --key /var/lib/dkms/mok.key --cert /var/lib/dkms/mok.pem \
    --output "${sd_dst}" "${sd_src}"
fi
```

(ZBM is not package-managed; a manual ZBM update needs a manual re-sign — documented in Task 7's README text. GRUB's ESP binaries are Debian-signed; nothing to re-sign.)

- [ ] **Step 5: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS. `tests/boot-config.sh` exercises these functions — if it asserts the old NVRAM loader paths (`\EFI\zbm\zfsbootmenu.efi` etc.), update those assertions to the shim paths.

- [ ] **Step 6: Commit**

```bash
git add scripts/50-boot.sh tests/secureboot.sh
git commit -m "feat: shim chain-load, MOK loader signing, and enrollment staging (#3)"
```

---

### Task 7: Verify checks, end-of-install notice, docs

**Files:**
- Modify: `scripts/90-verify.sh`
- Modify: `README.md` (bootloader/secure boot section), `STRUCTURE.md` if phase descriptions changed
- Modify: `tests/secureboot.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/secureboot.sh` before `finish_test`:

```bash
ver_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/90-verify.sh
  declare -f phase_verify')"
assert_contains "${ver_body}" "shim on ESP" "verify checks shim presence"
assert_contains "${ver_body}" "MokManager on ESP" "verify checks MokManager"
assert_contains "${ver_body}" "sbverify" "verify validates loader signature"
assert_contains "${ver_body}" "mokutil --list-new" \
  "verify reports enrollment staging (warn-only)"
assert_contains "${ver_body}" "Enroll MOK" "success notice explains first boot"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/secureboot.sh`
Expected: FAIL — none of the strings exist in `phase_verify`.

- [ ] **Step 3: Implement verify additions**

In `scripts/90-verify.sh` `phase_verify()`, add `sb_dir=""` to the `local` declaration on line 33, then insert after the bootloader `case` block (after line 117):

```bash
  # Secure boot chain: shim + MokManager beside the loader; self-shipped
  # loaders (zbm, systemd-boot) verify against the MOK cert. GRUB's
  # grubx64.efi is Debian-signed, so presence (checked above) suffices.
  case "${BOOTLOADER}" in
    zbm) sb_dir="zbm" ;;
    grub) sb_dir="debian" ;;
    systemd-boot) sb_dir="systemd" ;;
  esac
  vcheck "shim on ESP" test -f "${esp}/EFI/${sb_dir}/shimx64.efi"
  vcheck "MokManager on ESP" test -f "${esp}/EFI/${sb_dir}/mmx64.efi"
  vcheck "chain-loaded loader on ESP" \
    test -f "${esp}/EFI/${sb_dir}/grubx64.efi"
  if [[ "${BOOTLOADER}" != "grub" ]]; then
    vcheck "loader MOK signature valid" in_target \
      "sbverify --cert '${MOK_PEM}' '${ESP_MOUNT}/EFI/${sb_dir}/grubx64.efi'"
  fi
  # Warn-only: VMs without efivars cannot stage the import.
  if ! in_target "mokutil --list-new 2>/dev/null | grep -q ."; then
    warn "MOK enrollment not staged (no efivars?). On the installed" \
      "system run: mokutil --import ${MOK_CRT}"
  fi
```

And extend the success message at the end of `phase_verify()` (after the existing `info "SUCCESS: ..."` line):

```bash
  info "Secure boot: ready. First boot shows the blue MokManager screen —"
  info "choose 'Enroll MOK' and enter your user password. After that you"
  info "may enable secure boot in firmware at any time."
  if ((ZFS_FROM_SOURCE)); then
    info "First boot also builds the staged OpenZFS upgrade pre-login and"
    info "reboots once when it finishes."
  fi
```

- [ ] **Step 4: Update docs**

In `README.md`: update the `--zfs-from-source` flag description to the firstboot semantics; add a short "Secure boot" section stating: always-on shim + MOK model, enrollment password = user password, the live-environment SB-off requirement and remedy, and that a manually updated ZBM binary must be re-signed (`sbsign --key /var/lib/dkms/mok.key --cert /var/lib/dkms/mok.pem --output /boot/efi/EFI/zbm/grubx64.efi <new>.EFI`). In `STRUCTURE.md`, mention `firstboot.d` jobs under the hyprland/system phase lines if those lines exist.

- [ ] **Step 5: Run tests**

Run: `bash tests/secureboot.sh && bash tests/run-all.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/90-verify.sh README.md STRUCTURE.md tests/secureboot.sh
git commit -m "feat: secure boot verification checks and docs"
```

---

### Task 8: Full-suite pass, shellcheck, PR

- [ ] **Step 1: Run everything**

Run: `bash tests/run-all.sh`
Expected: every test file PASS.

- [ ] **Step 2: Shellcheck the touched files** (matches repo convention — files carry shellcheck directives)

Run: `shellcheck -x lib/00-config.sh scripts/00-preflight.sh scripts/40-system.sh scripts/50-boot.sh scripts/60-hyprland.sh scripts/90-verify.sh tests/secureboot.sh`
Expected: no new warnings (SC2034 is already suppressed in 00-config.sh).
If shellcheck is unavailable on the dev machine, note it in the PR body.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/secureboot
gh pr create --head feat/secureboot \
  --title "feat: secure boot support for all bootloaders (#3)" \
  --body "Implements docs/superpowers/specs/2026-06-12-secureboot-design.md: shim chain-load for zbm/grub/systemd-boot, MOK signing of self-built loaders, dkms key enrollment via mokutil (user password), fatal preflight when SB is enforcing in the live env, per-job firstboot runner, and hybrid ZFS delivery (repo 2.3.x at install, upstream build at first boot). Closes #3."
```

---

## Verification limits (be honest in the PR)

The test suite asserts on function bodies and generated files — it cannot prove the secure boot chain boots. Real validation needs a VM install run (`zbm`, `grub`, `systemd-boot` each) followed by enabling secure boot in OVMF with enrolled defaults. List this as follow-up validation in the PR body; do not claim boot-tested.
