#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: NVIDIA detection and driver decision (issue #4)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Fake sysfs trees: detection must key on vendor 0x10de AND display class.
make_pci_dev() { # $1=dir $2=vendor $3=class
  mkdir -p "${tmp}/sys/$1"
  echo "$2" >"${tmp}/sys/$1/vendor"
  echo "$3" >"${tmp}/sys/$1/class"
}

run_detect() {
  bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_nvidia_gpu
    echo "${HAS_NVIDIA_GPU}"
  ' 2>/dev/null | tail -n1 # info() logs to stdout; only the flag matters
}

make_pci_dev "0000:01:00.0" "0x10de" "0x030000"
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "1" "${out}" "NVIDIA display controller detected"

rm -rf "${tmp}/sys"
make_pci_dev "0000:00:1f.3" "0x8086" "0x040300"
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "0" "${out}" "non-NVIDIA hardware is not detected"

rm -rf "${tmp}/sys"
make_pci_dev "0000:02:00.0" "0x10de" "0x0c0330"
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "0" "${out}" "NVIDIA non-display function (e.g. USB-C) ignored"

# Decision matrix: gate helper and the unattended default.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  HAS_NVIDIA_GPU=1; IS_INTERACTIVE=0
  require_nvidia_choice 2>/dev/null
  echo "${NVIDIA_DRIVER}"' | tail -n1)"
assert_eq "open" "${out}" \
  "unattended runs default to the open kernel modules when a GPU is present"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  HAS_NVIDIA_GPU=0; IS_INTERACTIVE=0
  require_nvidia_choice 2>/dev/null
  echo "${NVIDIA_DRIVER:-unset}"')"
assert_eq "unset" "${out}" "no GPU means no driver decision"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=none
  HAS_NVIDIA_GPU=1
  nvidia_install_requested && echo yes || echo no')"
assert_eq "no" "${out}" "--nvidia=none disables the install"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=nvidia-tesla-driver
  HAS_NVIDIA_GPU=1
  nvidia_install_requested && echo "${NVIDIA_DRIVER}"')"
assert_eq "nvidia-tesla-driver" "${out}" "--nvidia=<package> honored verbatim"

assert_fails "--nvidia= (empty) rejected" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia='

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=open --nvidia-version=610.43.02-1
  echo "${NVIDIA_DRIVER}|${NVIDIA_DRIVER_VERSION}"')"
assert_eq "open|610.43.02-1" "${out}" "--nvidia-version pins an exact release"

assert_fails "--nvidia-version rejects non-version values" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia-version=latest'

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=debian
  HAS_NVIDIA_GPU=1
  nvidia_install_requested && echo yes || echo no')"
assert_eq "yes" "${out}" "--nvidia=debian requests the Debian driver"

# Open mode: keyring fetched, pinned trio installed, hold applied.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  curl() { : >"${TARGET}/tmp/cuda-keyring.deb"; } # fetch stub
  in_target() { printf "%s\n" "$1" >>"${TARGET}/in_target.log"; }
  source scripts/40-system.sh
  TARGET="'"${tmp}"'/open-target"; mkdir -p "${TARGET}/etc/modprobe.d" "${TARGET}/tmp"
  HAS_NVIDIA_GPU=1; NVIDIA_DRIVER=open; NVIDIA_DRIVER_VERSION=610.43.02-1
  NETWORK_AVAILABLE=1
  install_nvidia_driver >/dev/null 2>&1
  cat "${TARGET}/in_target.log"')"
assert_contains "${out}" "nvidia-open=610.43.02-1" \
  "open mode installs the pinned nvidia-open"
assert_contains "${out}" "nvidia-kernel-open-dkms=610.43.02-1" \
  "open mode installs the pinned open dkms modules"
assert_contains "${out}" "apt-mark hold" "pinned versions are held"
assert_contains "${out}" "dpkg -i /tmp/cuda-keyring.deb" \
  "NVIDIA repo keyring installed in the target"

# Open mode without a version: no pin, no hold (repo's production branch).
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  curl() { : >"${TARGET}/tmp/cuda-keyring.deb"; }
  in_target() { printf "%s\n" "$1" >>"${TARGET}/in_target.log"; }
  source scripts/40-system.sh
  TARGET="'"${tmp}"'/open-default-target"
  mkdir -p "${TARGET}/etc/modprobe.d" "${TARGET}/tmp"
  HAS_NVIDIA_GPU=1; NVIDIA_DRIVER=open; NVIDIA_DRIVER_VERSION=""
  NETWORK_AVAILABLE=1
  install_nvidia_driver >/dev/null 2>&1
  cat "${TARGET}/in_target.log"')"
assert_contains "${out}" "apt-get install -y nvidia-open nvidia-driver" \
  "unpinned open mode follows the repo production branch"
if printf '%s' "${out}" | grep -q "nvidia-open="; then
  echo "  FAIL: unpinned open mode must not pin a version" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: unpinned open mode carries no version pin"
fi

# install_nvidia_driver: modprobe options land in the target; offline skips.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  in_target() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}"'/target"; mkdir -p "${TARGET}/etc/modprobe.d"
  HAS_NVIDIA_GPU=1; NVIDIA_DRIVER=nvidia-driver; NETWORK_AVAILABLE=1
  install_nvidia_driver >/dev/null 2>&1
  cat "${TARGET}/etc/modprobe.d/nvidia-options.conf"')"
assert_contains "${out}" "options nvidia-drm modeset=1 fbdev=1" \
  "modprobe.d enables nvidia-drm KMS + fbdev"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  in_target() { echo "in_target-ran"; }
  source scripts/40-system.sh
  TARGET="'"${tmp}"'/offline-target"; mkdir -p "${TARGET}/etc/modprobe.d"
  HAS_NVIDIA_GPU=1; NVIDIA_DRIVER=nvidia-driver; NETWORK_AVAILABLE=0
  install_nvidia_driver 2>/dev/null
  [[ -e "${TARGET}/etc/modprobe.d/nvidia-options.conf" ]] && echo wrote || echo skipped')"
assert_eq "skipped" "${out}" "offline install skips the driver with a warning"

finish_test
