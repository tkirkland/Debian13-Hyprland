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
assert_eq "hyprwayland-scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols aquamarine hyprland" \
  "${out}" "hyprwm build order"

finish_test
