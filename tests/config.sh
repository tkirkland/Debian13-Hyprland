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
assert_eq "hyprwayland-scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols aquamarine hyprland uwsm" \
  "${out}" "build order (hyprwm stack, then uwsm)"

# Every build-order entry must map to a repo URL. Guards against assoc-array
# key mangling (a formatter once rewrote [hyprland-protocols] with spaces).
out="$(bash -c 'source lib/00-config.sh
  for n in "${HYPR_BUILD_ORDER[@]}"; do
    [[ -n "${HYPR_REPO_URL[${n}]:-}" ]] || { echo "missing ${n}"; exit 1; }
  done
  echo all-mapped')"
assert_eq "all-mapped" "${out}" "every build-order entry has a repo URL"

# uwsm is not in the Debian archive; it must never be in the apt lists.
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${TARGET_BASE_PACKAGES[@]}" "${HYPR_BUILD_PACKAGES[@]}"')"
if printf '%s\n' "${out}" | grep -qx 'uwsm\|libhwdata-dev'; then
  echo "  FAIL: uwsm/libhwdata-dev must not be apt packages" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: uwsm and libhwdata-dev absent from apt package lists"
fi

finish_test
