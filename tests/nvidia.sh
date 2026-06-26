#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: NVIDIA detection, choice gating, and offline/online install (Phase 5)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Fake sysfs trees: detection must key on vendor 0x10de AND display class.
make_pci_dev() { # $1=dir $2=vendor $3=class [$4=device]
  mkdir -p "${tmp}/sys/$1"
  echo "$2" >"${tmp}/sys/$1/vendor"
  echo "$3" >"${tmp}/sys/$1/class"
  if [[ -n "${4:-}" ]]; then
    echo "$4" >"${tmp}/sys/$1/device"
  fi
}

run_detect() { # echoes "HAS_NVIDIA_GPU PRETURING"
  bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_nvidia_gpu
    echo "${HAS_NVIDIA_GPU} ${NVIDIA_GPU_PRETURING}"
  ' 2>/dev/null | tail -n1 # info() logs to stdout; only the flags matter
}

make_pci_dev "0000:01:00.0" "0x10de" "0x030000" "0x2204" # RTX 3090 (Ampere)
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "1 0" "${out}" "Turing+ NVIDIA display controller: detected, not pre-Turing"

rm -rf "${tmp}/sys"
make_pci_dev "0000:01:00.0" "0x10de" "0x030000" "0x1b06" # GTX 1080 Ti (Pascal)
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "1 1" "${out}" "pre-Turing (Pascal) GPU detected and flagged pre-Turing"

rm -rf "${tmp}/sys"
make_pci_dev "0000:01:00.0" "0x10de" "0x030000" "0x1e07" # RTX 2080 Ti (Turing)
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "1 0" "${out}" "first Turing id (0x1E00 boundary) is open-capable"

rm -rf "${tmp}/sys"
make_pci_dev "0000:01:00.0" "0x10de" "0x030000" # no device file
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "1 0" "${out}" "missing device id treated as open-capable"

rm -rf "${tmp}/sys"
make_pci_dev "0000:00:1f.3" "0x8086" "0x040300"
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "0 0" "${out}" "non-NVIDIA hardware is not detected"

rm -rf "${tmp}/sys"
make_pci_dev "0000:02:00.0" "0x10de" "0x0c0330"
out="$(SYS_PCI_PATH="${tmp}/sys" run_detect)"
assert_eq "0 0" "${out}" "NVIDIA non-display function (e.g. USB-C) ignored"

# --- Choice matrix: gate helper, flag values, unattended defaults ------------
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  HAS_NVIDIA_GPU=1; IS_INTERACTIVE=0
  require_nvidia_choice 2>/dev/null
  echo "${NVIDIA_DRIVER}"' | tail -n1)"
assert_eq "open" "${out}" \
  "unattended runs default to the open kernel modules on a Turing+ GPU"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  HAS_NVIDIA_GPU=1; NVIDIA_GPU_PRETURING=1; IS_INTERACTIVE=0
  require_nvidia_choice 2>/dev/null
  echo "${NVIDIA_DRIVER}"' | tail -n1)"
assert_eq "proprietary" "${out}" \
  "unattended runs default to proprietary on a pre-Turing GPU"

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
  parse_args --nvidia=proprietary
  HAS_NVIDIA_GPU=1
  nvidia_install_requested && echo "${NVIDIA_DRIVER}"')"
assert_eq "proprietary" "${out}" "--nvidia=proprietary requests the proprietary flavor"

assert_fails "--nvidia= (empty) rejected" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia='

assert_fails "--nvidia=<arbitrary package> rejected (non-free path dropped)" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=nvidia-tesla-driver'

assert_fails "--nvidia=debian rejected (retired option)" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=debian'

# --- Branch flag --------------------------------------------------------------
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia-branch=610
  echo "${NVIDIA_BRANCH}"')"
assert_eq "610" "${out}" "--nvidia-branch=610 selects the feature branch"

assert_fails "--nvidia-branch rejects unknown branches" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia-branch=590'

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia=open --nvidia-version=610.43.02-1
  echo "${NVIDIA_DRIVER}|${NVIDIA_DRIVER_VERSION}"')"
assert_eq "open|610.43.02-1" "${out}" "--nvidia-version pins an exact release"

assert_fails "--nvidia-version rejects non-version values" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --nvidia-version=latest'

# --- install_nvidia_driver: capture the in-chroot script + side effects -------
# Helper: run install_nvidia_driver with stubbed in_target/curl and echo the
# captured chroot script. Args are env assignments evaluated before the call.
run_install() { # $1=target-subdir, rest=env setup
  local sub="$1"
  shift
  bash -c '
    source lib/00-config.sh; source lib/01-log.sh
    curl() { : >"${TARGET}/tmp/cuda-keyring.deb"; echo "curl-ran" >>"${TARGET}/curl.log"; }
    in_target() { printf "%s\n" "$1" >>"${TARGET}/in_target.log"; }
    source scripts/40-system.sh
    TARGET="'"${tmp}/${sub}"'"
    mkdir -p "${TARGET}/etc/modprobe.d" "${TARGET}/tmp"
    HAS_NVIDIA_GPU=1
    '"$*"'
    install_nvidia_driver >/dev/null 2>&1
    cat "${TARGET}/in_target.log"'
}

# Offline open install: pinning package + open trio from /hypr-repo, held,
# no keyring fetch, no apt update.
out="$(run_install offline-open 'NVIDIA_DRIVER=open; NETWORK_AVAILABLE=0')"
assert_contains "${out}" "apt-get install -y 'nvidia-driver-pinning-595'" \
  "offline open install activates the 595 branch pin"
assert_contains "${out}" "apt-get install -y nvidia-open nvidia-kernel-open-dkms" \
  "offline open install pulls the open kernel-module packages"
assert_contains "${out}" "apt-mark hold nvidia-open nvidia-kernel-open-dkms" \
  "offline open install holds the open metapackages"
if printf '%s' "${out}" | grep -qE 'cuda-keyring|apt-get update'; then
  echo "  FAIL: offline install must not fetch a keyring or apt update" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: offline install does no keyring fetch / apt update"
fi
if [[ -e "${tmp}/offline-open/curl.log" ]]; then
  echo "  FAIL: offline install must not run curl" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: offline install runs no curl"
fi
assert_contains "$(cat "${tmp}/offline-open/etc/modprobe.d/nvidia-options.conf")" \
  "options nvidia-drm modeset=1 fbdev=1" "offline install writes the nvidia-drm modprobe drop-in"

# Offline proprietary install: nvidia-driver + nvidia-kernel-dkms.
out="$(run_install offline-prop 'NVIDIA_DRIVER=proprietary; NETWORK_AVAILABLE=0')"
assert_contains "${out}" "apt-get install -y nvidia-driver nvidia-kernel-dkms" \
  "offline proprietary install pulls the proprietary kernel-module packages"

# Card gating: open requested on a pre-Turing GPU falls back to proprietary.
out="$(run_install gate 'NVIDIA_DRIVER=open; NVIDIA_GPU_PRETURING=1; NETWORK_AVAILABLE=0')"
assert_contains "${out}" "apt-get install -y nvidia-driver nvidia-kernel-dkms" \
  "pre-Turing GPU forces the proprietary flavor even when open was chosen"
if printf '%s' "${out}" | grep -q "nvidia-open"; then
  echo "  FAIL: pre-Turing fallback must not install nvidia-open" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: pre-Turing fallback installs no open packages"
fi

# Branch 610 via the pinning package.
out="$(run_install branch610 'NVIDIA_DRIVER=open; NVIDIA_BRANCH=610; NETWORK_AVAILABLE=0')"
assert_contains "${out}" "apt-get install -y 'nvidia-driver-pinning-610'" \
  "branch 610 activates the 610 pinning package"

# Exact version: each package pinned, the branch pinning package is skipped.
out="$(run_install exact \
  'NVIDIA_DRIVER=open; NVIDIA_DRIVER_VERSION=610.43.02-1; NETWORK_AVAILABLE=0')"
assert_contains "${out}" "nvidia-open=610.43.02-1" \
  "exact-version install pins nvidia-open"
assert_contains "${out}" "nvidia-kernel-open-dkms=610.43.02-1" \
  "exact-version install pins the open dkms package"
if printf '%s' "${out}" | grep -q "apt-get install -y nvidia-driver-pinning"; then
  echo "  FAIL: exact-version install must not install a branch pinning package" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: exact-version install skips the branch pinning package"
fi

# Online install: keyring fetched + apt update against NVIDIA's network repo.
out="$(run_install online 'NVIDIA_DRIVER=open; NETWORK_AVAILABLE=1')"
assert_contains "${out}" "dpkg -i /tmp/cuda-keyring.deb" \
  "online install installs the NVIDIA repo keyring in the target"
assert_contains "${out}" "apt-get update" "online install refreshes apt"
if [[ -e "${tmp}/online/curl.log" ]]; then
  echo "  ok: online install fetches the keyring via curl"
else
  echo "  FAIL: online install must fetch the keyring" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
