#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: ddcci/i2c-dev module loading for external-display brightness (#66)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# configure_ddcci writes /etc/modules-load.d/ddcci.conf containing exactly the
# two modules backing external-display brightness over DDC/CI. Unconditional
# (unlike the DMI-guarded audio quirk): harmless where no DDC/CI display exists.
out="$(bash -c '
  set -euo pipefail
  info() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}/t"'"
  configure_ddcci
  conf="${TARGET}/etc/modules-load.d/ddcci.conf"
  if [[ -f "${conf}" ]]; then echo "WROTE"; cat "${conf}"; else echo "ABSENT"; fi')"
assert_contains "${out}" "WROTE" "modules-load.d drop-in written"
assert_contains "${out}" "ddcci"   "loads the ddcci backlight driver"
assert_contains "${out}" "i2c-dev" "loads i2c-dev for the DDC/CI buses"

# The two modules must each be on their own line (modules-load.d format).
lines="$(bash -c '
  set -euo pipefail
  info() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}/t2"'"
  configure_ddcci
  grep -E "^(ddcci|i2c-dev)$" "${TARGET}/etc/modules-load.d/ddcci.conf" | wc -l')"
assert_eq "2" "${lines}" "both modules listed one per line"

finish_test
