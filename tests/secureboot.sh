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

finish_test
