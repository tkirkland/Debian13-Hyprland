#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: fstab generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/target/etc"

make_fake "${tmp}/bin" blkid '
case "$*" in
  *md/efi*) echo "AAAA-1111" ;;
  *md/swap*) echo "bbbbbbbb-2222" ;;
esac'

out="$(PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  TARGET='${tmp}/target'
  write_fstab
  cat '${tmp}/target/etc/fstab'
")"
assert_contains "${out}" "UUID=AAAA-1111 /boot/efi vfat" "ESP by UUID"
assert_contains "${out}" "UUID=bbbbbbbb-2222 none swap sw 0 0" "swap by UUID"
if [[ "${out}" == *" / "* ]]; then
  echo "  FAIL: root must NOT be in fstab (ZFS mounts it)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no root line (ZFS-managed)"
fi

# configure_locale_tz needs /etc/locale.gen from the locales package, so
# install_base_packages must come first in phase_system.
first_step="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  declare -f phase_system' |
  grep -oE 'install_base_packages|configure_locale_tz' | head -n1)"
assert_eq "install_base_packages" "${first_step}" \
  "base packages install before locale configuration"

finish_test
