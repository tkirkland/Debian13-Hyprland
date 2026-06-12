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

# The Downloads dataset mounts under /home/<user> before adduser runs, so
# create_user must copy skel itself and chown the pre-existing home tree.
user_body="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  declare -f create_user')"
assert_contains "${user_body}" "cp -rnT /etc/skel" \
  "create_user copies skeleton files into the pre-existing home"
assert_contains "${user_body}" "chown -R" \
  "create_user fixes ownership of the pre-existing home"
assert_contains "${user_body}" "canmount=on" \
  "create_user enables the Downloads dataset only after adduser"

# The zfs firstboot job must produce ONLY the utils/dkms package set:
# native-deb-kmod compiles modules for the RUNNING (live) kernel and drags
# that kernel image into the target as a dependency.
zfs_body="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  declare -f write_zfs_upgrade_job')"
assert_contains "${zfs_body}" "native-deb-utils" \
  "zfs firstboot job uses native-deb-utils"
if printf '%s\n' "${zfs_body}" | grep -qE 'native-deb(-kmod)?[" ]*$'; then
  echo "  FAIL: zfs firstboot job must not invoke native-deb or native-deb-kmod" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: zfs firstboot job avoids native-deb-kmod"
fi
assert_contains "${zfs_body}" "openzfs-zfs-dkms" \
  "zfs firstboot job asserts the dkms package was produced"
# pam_zfs_key in common-password breaks chpasswd without encrypted homes.
assert_contains "${zfs_body}" "pam-auth-update" \
  "zfs firstboot job purges pam_zfs_key and regenerates the PAM stack"

# Addon artifacts: debs install via apt (dependency resolution); runfiles
# are staged at /opt/addons, never executed in the chroot.
addon_body="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  declare -f install_addon_artifacts phase_system')"
assert_contains "${addon_body}" "apt-get install -y /var/tmp/addon-debs" \
  "addon debs installed through apt"
assert_contains "${addon_body}" "/opt/addons" \
  "runfiles staged into the target"
assert_contains "${addon_body}" "install_addon_artifacts" \
  "phase_system runs the addon artifact step"
assert_contains "${addon_body}" "addon-scripts" \
  "addon shell hooks execute inside the target"
assert_contains "${addon_body}" "Addon script failed" \
  "failing addon script fails the phase by name"

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
