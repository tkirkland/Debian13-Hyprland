#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: config defaults and derivation"

out="$(bash -c 'source lib/00-config.sh; echo "${ROOT_DATASET}"')"
assert_eq "PRECISION/ROOT/debian13" "${out}" "derived root dataset"

out="$(bash -c 'source lib/00-config.sh; echo "${DISK1}"')"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" "fixed DISK1"

out="$(bash -c 'source lib/00-config.sh; echo "${EFI_SIZE} ${SWAP_SIZE}"')"
assert_eq "2G 4G" "${out}" "amended partition sizes (no BOOT_SIZE)"

out="$(bash -c 'source lib/00-config.sh; echo "${BOOT_SIZE:-unset}"')"
assert_eq "unset" "${out}" "BOOT_SIZE removed from layout"

out="$(POOL_NAME=TEST ROOT_DISTRO=d13 bash -c \
  'source lib/00-config.sh; echo "${ROOT_DATASET}"')"
assert_eq "TEST/ROOT/d13" "${out}" "env overrides flow into derivation"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_BUILD_ORDER[*]}"')"
assert_eq "wayland wayland-protocols xkbcommon lua hyprwayland-scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols hyprwire aquamarine hyprland hyprtoolkit hyprland-guiutils hyprlauncher uwsm" \
  "${out}" "build order (too-old Debian libs first, hyprwm stack, then uwsm)"

# Every build-order entry must map to a repo URL. Guards against assoc-array
# key mangling (a formatter once rewrote [hyprland-protocols] with spaces).
out="$(bash -c 'source lib/00-config.sh
  for n in "${HYPR_BUILD_ORDER[@]}"; do
    [[ -n "${HYPR_REPO_URL[${n}]:-}" ]] || { echo "missing ${n}"; exit 1; }
  done
  echo all-mapped')"
assert_eq "all-mapped" "${out}" "every build-order entry has a repo URL"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_CC} ${HYPR_CXX}"')"
assert_eq "gcc-15 g++-15" "${out}" \
  "stack builds with GCC 15 (trixie's GCC 14 libstdc++ lacks append_range)"

out="$(bash -c 'source lib/00-config.sh
  echo "${HYPR_TOOLCHAIN_PACKAGES[*]}"
  printf "%s\n" "${HYPR_BUILD_PACKAGES[@]}" | grep -cx "gcc-15\|g\+\+-15"' \
  || true)"
assert_contains "${out}" "gcc-15 g++-15" "toolchain packages split out"
assert_contains "${out}" "0" \
  "toolchain absent from general build packages (no sid leakage)"

out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"')"
assert_contains "${out}" "linux-headers-amd64" \
  "target gets kernel headers so dkms can build the zfs module"
assert_contains "${out}" "pipewire-audio" "PipeWire audio in base set"
assert_contains "${out}" "wireplumber"    "WirePlumber (wpctl) in base set"
assert_contains "${out}" "brightnessctl"  "brightness key binary in base set"
# Debian's brightnessctl is built without logind and writes the backlight via
# sysfs; the udev rule that makes it group-writable ships separately as
# brightness-udev (only Recommended), so it must be installed explicitly or the
# brightness keys are dead (issue #48).
assert_contains "${out}" "brightness-udev" "brightness udev-rule package in base set (issue #48)"
assert_contains "${out}" "playerctl"      "media key binary in base set"

# addons/*.list files are appended to the target package set (comments
# and whitespace stripped); the .sample template must NOT load.
addon_file="addons/zz-config-test.list"
printf '%s\n' "# comment line" "" "zz-fake-addon-pkg  # trailing" \
  >"${addon_file}"
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"')"
rm -f "${addon_file}"
assert_contains "${out}" "zz-fake-addon-pkg" "addon package loaded"
if printf '%s\n' "${out}" | grep -q "example"; then
  echo "  FAIL: .sample template must not load" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: .list.sample template stays inert"
fi

# uwsm is not in the Debian archive; it must never be in the apt lists.
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${TARGET_BASE_PACKAGES[@]}" "${HYPR_BUILD_PACKAGES[@]}"')"
if printf '%s\n' "${out}" | grep -qx 'uwsm\|libhwdata-dev'; then
  echo "  FAIL: uwsm/libhwdata-dev must not be apt packages" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: uwsm and libhwdata-dev absent from apt package lists"
fi

# openzfs debian/control Build-Depends on lsb-release; debootstrap's
# minimal base omits it, so the source build's dpkg-checkbuilddeps aborts
# ("Unmet build dependencies: lsb-release") unless it is in the build set.
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${ZFS_BUILD_PACKAGES[@]}"')"
assert_contains "${out}" "lsb-release" \
  "zfs build deps include lsb-release (openzfs Build-Depends)"

finish_test
