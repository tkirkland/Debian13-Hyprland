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
