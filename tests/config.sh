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
assert_eq "wayland wayland-protocols xkbcommon lua hyprwayland-scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols hyprwire aquamarine hyprland hyprtoolkit hyprland-guiutils hyprlock hypridle swww hyprdim uwsm" \
  "${out}" "build order (too-old Debian libs first, hyprwm stack, then uwsm)"

# hyprdim (external-display gamma brightness daemon, issue #66) builds from
# source like swww, after it and before uwsm.
out="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${HYPR_BUILD_ORDER[@]}"')"
assert_contains "${out}" "hyprdim" "hyprdim in the build order (issue #66)"

# Its source URL defaults to the tkirkland repo and is overridable.
out="$(bash -c 'source lib/00-config.sh; echo "${HYPRDIM_REPO_URL}"')"
assert_eq "https://github.com/tkirkland/hyprdim" "${out}" \
  "HYPRDIM_REPO_URL default (tkirkland/hyprdim)"
out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_REPO_URL[hyprdim]}"')"
assert_eq "https://github.com/tkirkland/hyprdim" "${out}" \
  "hyprdim build-order entry maps to its repo URL"
out="$(HYPRDIM_REPO_URL=https://example.invalid/fork bash -c \
  'source lib/00-config.sh; echo "${HYPR_REPO_URL[hyprdim]}"')"
assert_eq "https://example.invalid/fork" "${out}" \
  "HYPRDIM_REPO_URL env override flows into the repo map"

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

# xdph (xdg-desktop-portal-hyprland) is source-built as its own optional
# component, so its build-deps ride in HYPR_BUILD_PACKAGES (NOT the source-built
# hypr stack, which xdph builds against afterward). qt6-base-dev powers the Qt6
# share-picker; the pipewire/spa/sdbus-c++ headers are the screencast backend.
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${HYPR_BUILD_PACKAGES[@]}"')"
assert_contains "${out}" "qt6-base-dev" \
  "Qt6 build-dep for the xdph share-picker (issue #57/#67)"
assert_contains "${out}" "libpipewire-0.3-dev" \
  "PipeWire headers for the xdph screencast backend (issue #57/#67)"
assert_contains "${out}" "libspa-0.2-dev" \
  "SPA headers for the xdph screencast backend (issue #57/#67)"
assert_contains "${out}" "libsdbus-c++-dev" \
  "sdbus-c++ headers for xdph (issue #57/#67)"
# xdph is its OWN optional component and MUST NEVER be a HYPR_BUILD_ORDER member
# (the #64 dead-greeter revert): the order is a must-succeed set whose failure
# would strand uwsm / abort the offline apt transaction.
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${HYPR_BUILD_ORDER[@]}"')"
if printf '%s\n' "${out}" | grep -qx 'xdph\|xdg-desktop-portal-hyprland'; then
  echo "  FAIL: xdph must not be a HYPR_BUILD_ORDER member (issue #64)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: xdph stays out of the must-succeed HYPR_BUILD_ORDER (issue #64)"
fi

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
# External-display brightness over DDC/CI (issue #66): ddcci-dkms builds the
# ddcci backlight driver (contrib DKMS, like zfs-dkms, against the headers
# already in the base set); ddcutil/i2c-tools provide the DDC/CI userspace.
assert_contains "${out}" "ddcci-dkms" "ddcci DKMS driver in base set (issue #66)"
assert_contains "${out}" "ddcutil"    "ddcutil DDC/CI tool in base set (issue #66)"
assert_contains "${out}" "i2c-tools"  "i2c-tools in base set (issue #66)"
# ddcci-dkms is a DKMS build (like zfs-dkms), NOT a source-replaced package, so
# it must never appear in ZFS_DEBIAN_PACKAGES (the set the upstream zfs build
# purges) — otherwise it would be wrongly removed.
out_zfs="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${ZFS_DEBIAN_PACKAGES[@]}"')"
if printf '%s\n' "${out_zfs}" | grep -qx 'ddcci-dkms'; then
  echo "  FAIL: ddcci-dkms must not be in ZFS_DEBIAN_PACKAGES" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: ddcci-dkms stays out of the zfs source-replace purge set"
fi
assert_contains "${out}" "systemd-timesyncd" \
  "NTP client in base set so the installed clock stays disciplined"
# Portal stack (issue #57/#67 item 3): the xdg-desktop-portal broker plus the
# gtk backend (routing default=gtk) and the packaged wlr backend, which is the
# ALWAYS-installed screencast fallback when the source-built hyprland impl is
# absent — so the portal chain works on every path regardless of xdph.
assert_contains "${out}" "xdg-desktop-portal" \
  "xdg-desktop-portal broker in base set (issue #57/#67)"
assert_contains "${out}" "xdg-desktop-portal-gtk" \
  "gtk portal backend in base set (routing default=gtk) (issue #57/#67)"
assert_contains "${out}" "xdg-desktop-portal-wlr" \
  "wlr portal backend in base set (guaranteed screencast fallback) (issue #57/#67)"
# lxpolkit polkit agent (issue #67 item 4): ships /etc/xdg/autostart and starts
# via 'uwsm finalize' — no extra autostart wiring needed.
assert_contains "${out}" "lxpolkit" \
  "lxpolkit polkit agent in base set (issue #67 item 4)"
# Dolphin file manager (issue #70); also anchors the KDE/Qt6 runtime closure the
# source-built xdph share-picker relies on at package time.
assert_contains "${out}" "dolphin" \
  "Dolphin file manager in base set (issue #70)"

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

source lib/00-config.sh
assert_eq "amd64" "${ARCH}" "ARCH is amd64"
[[ -n "${HYPR_DEB_DEPENDS[swww]+x}" ]] && echo "  ok: swww Depends declared" \
  || { echo "  FAIL: HYPR_DEB_DEPENDS[swww] missing" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }

# Source-compiled wayland/xkbcommon own /usr with Debian's soname paths, so they
# must Provides/Conflicts/Replaces the Debian library packages.
[[ -n "${HYPR_DEB_PROVIDES[wayland]+x}" ]] && echo "  ok: wayland Provides declared" \
  || { echo "  FAIL: HYPR_DEB_PROVIDES[wayland] missing" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
[[ -n "${HYPR_DEB_CONFLICTS[xkbcommon]+x}" ]] && echo "  ok: xkbcommon Conflicts declared" \
  || { echo "  FAIL: HYPR_DEB_CONFLICTS[xkbcommon] missing" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }

# --- NVIDIA driver: both flavors from the NVIDIA CUDA repo (Phase 5) ----------
# Branch defaults to the production/certified 595; overridable via env.
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_BRANCH}"')"
assert_eq "595" "${out}" "NVIDIA_BRANCH defaults to 595 (production/certified)"
out="$(NVIDIA_BRANCH=610 bash -c 'source lib/00-config.sh; echo "${NVIDIA_BRANCH}"')"
assert_eq "610" "${out}" "NVIDIA_BRANCH overridable to 610 (newer branch)"

# Flat CUDA repo URL + keyring deb derived from it; both overridable.
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_REPO_URL}"')"
assert_eq "https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/" \
  "${out}" "NVIDIA_REPO_URL default (flat CUDA debian13 repo)"
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_REPO_KEYRING_URL}"')"
assert_eq "https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb" \
  "${out}" "NVIDIA_REPO_KEYRING_URL derives from the repo URL"
out="$(NVIDIA_REPO_URL=file:///hypr-repo/ bash -c \
  'source lib/00-config.sh; echo "${NVIDIA_REPO_KEYRING_URL}"')"
assert_eq "file:///hypr-repo/cuda-keyring_1.1-1_all.deb" "${out}" \
  "keyring URL follows an overridden NVIDIA_REPO_URL"

# Branch-pinning package per branch (exact research names).
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_PINNING_PACKAGE[595]}"')"
assert_eq "nvidia-driver-pinning-595" "${out}" "595 branch-pinning package"
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_PINNING_PACKAGE[610]}"')"
assert_eq "nvidia-driver-pinning-610" "${out}" "610 branch-pinning package"

# Flavor package sets.
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_OPEN_PACKAGES[*]}"')"
assert_eq "nvidia-open nvidia-kernel-open-dkms" "${out}" \
  "open flavor = nvidia-open + nvidia-kernel-open-dkms"
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_PROP_PACKAGES[*]}"')"
assert_eq "nvidia-driver nvidia-kernel-dkms" "${out}" \
  "proprietary flavor = nvidia-driver + nvidia-kernel-dkms (NVIDIA repo, not Debian non-free)"

# Shared userspace is resolved by apt per-flavor, NOT force-listed (force-listing
# nvidia-suspend-common / nvidia-kernel-common broke the download resolution
# because nvidia-driver / nvidia-kernel-support Conflict them). Only the
# conflict-free firmware hard dep is listed explicitly for the offline pool.
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_FIRMWARE_PACKAGES[*]}"')"
assert_eq "firmware-nvidia-gsp" "${out}" \
  "explicit pool firmware = firmware-nvidia-gsp (dkms hard dep, conflict-free)"
# The retired over-broad shared array must be gone (it Conflicted the driver).
out="$(bash -c 'source lib/00-config.sh; echo "${NVIDIA_SHARED_PACKAGES[*]:-UNSET}"')"
assert_eq "UNSET" "${out}" \
  "over-broad NVIDIA_SHARED_PACKAGES removed (conflicted nvidia-driver)"

# The retired Debian non-free "debian" flavor must be gone from the docs/config.
if grep -qE '^\s*#.*\bdebian\b.*non-free nvidia-driver' lib/00-config.sh; then
  echo "  FAIL: retired 'debian' non-free NVIDIA option still documented" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: Debian non-free 'debian' NVIDIA flavor retired"
fi

finish_test
