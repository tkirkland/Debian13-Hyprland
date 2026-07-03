#!/usr/bin/env bash
# tests/system.sh — unit tests for scripts/40-system.sh:
#   vendor-conditional microcode (install only the matching deb; both stay in
#   TARGET_BASE_PACKAGES so the offline pool keeps either CPU's blob).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=scripts/40-system.sh
source "${HERE}/../scripts/40-system.sh"

# --- collaborators stubbed for both fixes (invoked indirectly under test) -----
# shellcheck disable=SC2317  # called indirectly by the functions under test
info() { :; }
# shellcheck disable=SC2317  # captures the chroot command string for assertions
in_target() { printf '%s\n' "$*" >>"${CAPTURE}"; }
# FIX 4 drives the offline ZFS path (NETWORK_AVAILABLE=0), so stub only that;
# the real install_zfs_from_source is exercised intact by the FIX 5a case below.
# shellcheck disable=SC2317  # install_base_packages dispatches to this on the offline path
install_zfs_offline() { :; }

# --- FIX 4: only the vendor-matching microcode installs; both stay pooled -----
# shellcheck disable=SC2034  # consumed by the sourced install_base_packages
ZFS_DEBIAN_PACKAGES=(zfs-initramfs zfs-dkms zfsutils-linux zfs-zed)
# shellcheck disable=SC2034  # consumed by the sourced install_base_packages
TARGET_BASE_PACKAGES=(base-files intel-microcode amd64-microcode hwdata)
VIRT_TYPE=none
NETWORK_AVAILABLE=0

run_microcode_case() {
  local vendor="$1"
  CAPTURE="$(mktemp)"
  detect_cpu_vendor() { printf '%s\n' "${vendor}"; }
  install_base_packages
  local cap; cap="$(cat "${CAPTURE}")"
  rm -f "${CAPTURE}"
  printf '%s' "${cap}"
}

intel_cap="$(run_microcode_case GenuineIntel)"
assert_contains "${intel_cap}" "intel-microcode" "Intel CPU installs intel-microcode"
if [[ "${intel_cap}" == *"amd64-microcode"* ]]; then
  echo "  FAIL: amd64-microcode installed on an Intel CPU" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: amd64-microcode NOT installed on an Intel CPU"
fi

amd_cap="$(run_microcode_case AuthenticAMD)"
assert_contains "${amd_cap}" "amd64-microcode" "AMD CPU installs amd64-microcode"
if [[ "${amd_cap}" == *"intel-microcode"* ]]; then
  echo "  FAIL: intel-microcode installed on an AMD CPU" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: intel-microcode NOT installed on an AMD CPU"
fi

unknown_cap="$(run_microcode_case SomethingElse)"
assert_contains "${unknown_cap}" "intel-microcode" "unknown vendor keeps intel-microcode (no regression)"
assert_contains "${unknown_cap}" "amd64-microcode" "unknown vendor keeps amd64-microcode (no regression)"

# Offline-completeness: the config array still carries BOTH debs after filtering,
# so the pool/closure (cache_populate_debs, step_depsim) keeps either CPU's blob.
case " ${TARGET_BASE_PACKAGES[*]} " in
  *" intel-microcode "*) : ;;
  *) echo "  FAIL: intel-microcode dropped from TARGET_BASE_PACKAGES (breaks pool)" >&2
     TEST_FAILURES=$((TEST_FAILURES + 1)) ;;
esac
case " ${TARGET_BASE_PACKAGES[*]} " in
  *" amd64-microcode "*) echo "  ok: BOTH microcode debs remain in TARGET_BASE_PACKAGES (pool unchanged)" ;;
  *) echo "  FAIL: amd64-microcode dropped from TARGET_BASE_PACKAGES (breaks pool)" >&2
     TEST_FAILURES=$((TEST_FAILURES + 1)) ;;
esac

finish_test
