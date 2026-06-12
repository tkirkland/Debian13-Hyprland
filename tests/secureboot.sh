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

finish_test
