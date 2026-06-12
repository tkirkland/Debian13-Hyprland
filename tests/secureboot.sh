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

pre_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  declare -f check_secureboot_disabled phase_preflight || true')"
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

boot_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  declare -f bootstrap_live_tools || true')"
assert_contains "${boot_body}" "openssl" "openssl probed by live bootstrap"

sys_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh
  declare -f ensure_mok_key phase_system' 2>/dev/null || true)"
assert_contains "${sys_body}" "openssl req -new -x509" \
  "MOK keypair generated with openssl"
assert_contains "${sys_body}" "outform DER" \
  "MOK certificate is DER (dkms/mokutil format)"
assert_contains "${sys_body}" "chmod 600" "private key is chmod 600"

phase_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh; declare -f phase_system' 2>/dev/null || true)"
mok_line="$(printf '%s\n' "${phase_body}" | grep -n 'ensure_mok_key' | cut -d: -f1 | head -n1 || true)"
pkg_line="$(printf '%s\n' "${phase_body}" | grep -n 'install_base_packages' | cut -d: -f1 | head -n1 || true)"
if [[ -n "${mok_line}" && -n "${pkg_line}" ]] && ((mok_line < pkg_line)); then
  echo "  ok: ensure_mok_key runs before install_base_packages"
else
  echo "  FAIL: ensure_mok_key must run before install_base_packages" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

hypr_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/60-hyprland.sh
  declare -f stage_firstboot_runner stage_firstboot' 2>/dev/null || true)"
assert_contains "${hypr_body}" "firstboot.d" \
  "runner executes a per-job directory"
# shellcheck disable=SC2016  # literal needles: the runner expands these at boot
assert_contains "${hypr_body}" '${job%.sh}.done' \
  "successful jobs renamed .done"
# shellcheck disable=SC2016
assert_contains "${hypr_body}" '${job%.sh}.failed' \
  "failed jobs renamed .failed (boot continues)"
assert_contains "${hypr_body}" "hypr-deb-reboot-required" \
  "jobs can request a reboot via flag file"
assert_contains "${hypr_body}" "50-hyprland-build.sh" \
  "hyprland build staged as a firstboot job"
assert_contains "${hypr_body}" "Before=greetd.service" \
  "firstboot unit runs pre-login"

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

boot_sb="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh
  declare -f install_shim sign_loader stage_mok_enrollment ensure_mok_pem \
    install_zbm install_grub install_sdboot phase_boot write_esp_sync_hook \
    write_grub_cfg' 2>/dev/null || true)"
assert_contains "${boot_sb}" "shimx64.efi.signed" "shim copied from shim-signed"
assert_contains "${boot_sb}" "mmx64.efi.signed" "MokManager copied to ESP"
assert_contains "${boot_sb}" "sbsign --key" "self-built loaders MOK-signed"
assert_contains "${boot_sb}" "mokutil --import" "MOK enrollment staged"
assert_contains "${boot_sb}" 'EFI\zbm\shimx64.efi' \
  "zbm NVRAM entry points at shim"
assert_contains "${boot_sb}" 'EFI\debian\shimx64.efi' \
  "grub NVRAM entry points at shim"
assert_contains "${boot_sb}" 'EFI\systemd\shimx64.efi' \
  "systemd-boot NVRAM entry points at shim"
assert_contains "${boot_sb}" "grub-efi-amd64-signed" \
  "grub uses Debian's signed packages"
assert_contains "${boot_sb}" "--uefi-secure-boot" \
  "grub-install installs the signed chain"
assert_contains "${boot_sb}" "stage_mok_enrollment" \
  "phase_boot stages enrollment for every loader"
enroll_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh; declare -f stage_mok_enrollment' 2>/dev/null || true)"
if printf '%s' "${enroll_body}" | grep -q 'fatal'; then
  echo "  FAIL: stage_mok_enrollment must never be fatal" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: enrollment failure is warn-only"
fi
hook_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/50-boot.sh; declare -f write_esp_sync_hook' 2>/dev/null || true)"
assert_contains "${hook_body}" "systemd-bootx64.efi" \
  "sync hook re-signs updated systemd-boot"

ver_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/90-verify.sh
  declare -f phase_verify' 2>/dev/null || true)"
assert_contains "${ver_body}" "shim on ESP" "verify checks shim presence"
assert_contains "${ver_body}" "MokManager on ESP" "verify checks MokManager"
assert_contains "${ver_body}" "sbverify" "verify validates loader signature"
assert_contains "${ver_body}" "mokutil --list-new" \
  "verify reports enrollment staging (warn-only)"
assert_contains "${ver_body}" "Enroll MOK" "success notice explains first boot"

# --- Final integration review fixes -----------------------------------------

# Fix 1: the in-chroot Hyprland build-dep purge must spare the toolchain
# the staged firstboot ZFS build needs.
purge_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/60-hyprland.sh; declare -f purge_build_deps' 2>/dev/null || true)"
assert_contains "${purge_body}" "ZFS_BUILD_PACKAGES" \
  "purge_build_deps spares the staged ZFS toolchain"
zfs_stage_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh
  declare -f stage_zfs_upgrade_job' 2>/dev/null || true)"
assert_contains "${zfs_stage_body}" "apt-mark manual" \
  "ZFS build deps marked manual (autoremove-proof)"
stagefb_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/60-hyprland.sh; declare -f stage_firstboot' 2>/dev/null || true)"
# shellcheck disable=SC2016 # the unexpanded text is exactly what we assert
assert_contains "${stagefb_body}" 'ZFS_FROM_SOURCE=${ZFS_FROM_SOURCE}' \
  "50-hyprland-build job preserves ZFS_FROM_SOURCE at firstboot"

# Fix 2: phase 50 installs grub-efi-amd64-signed; the offline cache must
# carry it (shim-signed already rides in via TARGET_BASE_PACKAGES).
cache_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/10-cache.sh
  declare -f cache_populate_debs' 2>/dev/null || true)"
assert_contains "${cache_body}" "grub-efi-amd64-signed" \
  "offline cache carries the signed grub image"

# Fix 3: mokutil rejects passwords outside 8-16 chars; validate the length
# before piping USER_PASSWORD instead of letting the import fail.
assert_contains "${enroll_body}" '#USER_PASSWORD' \
  "stage_mok_enrollment checks the password length"
assert_contains "${enroll_body}" "8-16" \
  "stage_mok_enrollment explains mokutil's 8-16 char bounds"

# Fix 4: the firstboot runner enable must run even when a resumed run
# finds the runner binary already written (enable is idempotent).
runner_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/60-hyprland.sh
  declare -f stage_firstboot_runner' 2>/dev/null || true)"
if printf '%s\n' "${runner_body}" | grep -q 'return 0'; then
  echo "  FAIL: stage_firstboot_runner must not early-return before enable" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: stage_firstboot_runner always reaches systemctl enable"
fi
assert_contains "${runner_body}" "systemctl enable hypr-deb-firstboot.service" \
  "runner staging enables the unit"

finish_test
