#!/usr/bin/env bash
# tests/zfs-build.sh — unit tests for scripts/40-system.sh's ZFS paths:
#   install_zfs_from_source — noautodbgsym build env; native-deb-kmod built and
#   pooled ONLY on the ZFS_DEB_POOL (ISO-build) path, pinned to KERNEL_PINNED
#   (issue #110); install-time path unchanged (no kmod).
#   install_zfs_offline — installs the PREBUILT kmod deb (never the dkms deb),
#   signs + depmods before returning (so before configure_zfs_boot_support's
#   update-initramfs), and stages the dkms deb + firstboot job.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=scripts/40-system.sh
source "${HERE}/../scripts/40-system.sh"

# Collaborators stubbed so the build assembles its chroot script with no network
# or real chroot; in_target captures that script string for assertions.
# shellcheck disable=SC2317  # called indirectly by install_zfs_from_source
info() { :; }
# shellcheck disable=SC2317  # captures the assembled build script
in_target() { printf '%s\n' "$*" >>"${CAPTURE}"; }
# shellcheck disable=SC2317  # forces the resolve_latest_release_tag fallback
curl() { return 1; }
# shellcheck disable=SC2317  # the source clone is a no-op under test
git() { :; }
# shellcheck disable=SC2317  # tag-resolver fallback
resolve_latest_release_tag() { echo "zfs-2.3.0"; }
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_from_source
ZFS_REPO_URL="https://example/zfs"
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_from_source
ZFS_TAG_PATTERN="zfs-*"
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_from_source
ZFS_BUILD_PACKAGES=(build-essential)
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_from_source
HYPR_BUILD_JOBS=2

ztarget="$(mktemp -d)"; mkdir -p "${ztarget}/var/tmp"
TARGET="${ztarget}"
CAPTURE="$(mktemp)"
unset ZFS_DEB_POOL
install_zfs_from_source
zcap="$(cat "${CAPTURE}")"
rm -rf "${ztarget}"; rm -f "${CAPTURE}"

assert_contains "${zcap}" "DEB_BUILD_OPTIONS=noautodbgsym" \
  "ZFS build env sets noautodbgsym (suppresses auto -dbgsym debs)"
assert_contains "${zcap}" "native-deb-utils" "still builds the native-deb-utils target"
assert_contains "${zcap}" "openzfs-zfs-dkms" "still asserts the required openzfs debs"
assert_contains "${zcap}" "required package not built" "keeps the required-package assertion"
if [[ "${zcap}" == *native-deb-kmod* ]]; then
  echo "  FAIL: install-time zfs build must not run native-deb-kmod" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: install-time path builds no kmod deb (dkms covers the target)"
fi

# --- ZFS_DEB_POOL (ISO build): kmod deb built for the pin and pooled ----------
# shellcheck disable=SC2317  # stubs invoked indirectly by install_zfs_from_source
fatal() { echo "FATAL: $*" >&2; exit 1; }
KPIN="6.12.38+deb13-amd64"
ztarget="$(mktemp -d)"; mkdir -p "${ztarget}/var/tmp"
zpool_dir="$(mktemp -d)"
TARGET="${ztarget}"
CAPTURE="$(mktemp)"
# The in_target stub stands in for the chroot build: capture the script AND
# drop the .debs the real build would leave in /var/tmp, so the host-side
# pool-copy filter below has real files to act on.
# shellcheck disable=SC2317  # invoked indirectly by install_zfs_from_source
in_target() {
  printf '%s\n' "$*" >>"${CAPTURE}"
  touch "${TARGET}/var/tmp/openzfs-zfsutils_2.3.0-1_amd64.deb" \
    "${TARGET}/var/tmp/openzfs-zfs-modules-${KPIN}_2.3.0-1_amd64.deb" \
    "${TARGET}/var/tmp/openzfs-zfs-test_2.3.0-1_amd64.deb" \
    "${TARGET}/var/tmp/openzfs-pam-zfs-key_2.3.0-1_amd64.deb"
}
KERNEL_PINNED="${KPIN}" ZFS_DEB_POOL="${zpool_dir}" install_zfs_from_source
zcap="$(cat "${CAPTURE}")"
assert_contains "${zcap}" "native-deb-kmod" "pool path builds the kmod deb"
assert_contains "${zcap}" "--with-linux=/usr/src/linux-headers-${KPIN}" \
  "kmod build configures against the PINNED kernel's headers"
assert_contains "${zcap}" "openzfs-zfs-modules-${KPIN}" \
  "pool path asserts the pinned kmod deb was produced"
# Upstream debian/rules defaults KVERS to the BUILD HOST's uname -r and its
# module build re-configures with --with-linux=$(KSRC), overriding the
# cfg_flags pin — both must ride the make invocation explicitly.
assert_contains "${zcap}" "native-deb-kmod KVERS='${KPIN}' KSRC='/usr/src/linux-headers-${KPIN}'" \
  "kmod make passes KVERS + KSRC so the deb targets the PINNED kernel, not uname -r"
if [[ -e "${zpool_dir}/openzfs-zfs-modules-${KPIN}_2.3.0-1_amd64.deb" ]]; then
  echo "  ok: kmod deb copied into the pool (filter admits zfs-modules)"
else
  echo "  FAIL: kmod deb not pooled (filter still excludes zfs-modules)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -e "${zpool_dir}/openzfs-zfs-test_2.3.0-1_amd64.deb" ||
  -e "${zpool_dir}/openzfs-pam-zfs-key_2.3.0-1_amd64.deb" ]]; then
  echo "  FAIL: test/pam debs leaked into the pool" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: test/pam debs still filtered out of the pool"
fi
rm -rf "${ztarget}" "${zpool_dir}"; rm -f "${CAPTURE}"

# ZFS_DEB_POOL without KERNEL_PINNED is a build wiring error -> fatal.
rc=0
(TARGET="$(mktemp -d)" ZFS_DEB_POOL="$(mktemp -d)" install_zfs_from_source) \
  >/dev/null 2>&1 || rc=$?
if ((rc != 0)); then
  echo "  ok: ZFS_DEB_POOL without KERNEL_PINNED is fatal"
else
  echo "  FAIL: pool build ran without a kernel pin" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- install_zfs_offline: prebuilt kmod in, dkms deferred to firstboot --------
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_offline
ZFS_UPSTREAM_PACKAGES=(openzfs-zfsutils openzfs-zfs-dkms openzfs-zfs-initramfs openzfs-zfs-zed)
MOK_KEY="/var/lib/dkms/mok.key"
MOK_CRT="/var/lib/dkms/mok.pub"
store="$(mktemp -d)"
mkdir -p "${store}/pool"
echo "${KPIN}" >"${store}/KERNEL_PINNED"
: >"${store}/pool/openzfs-zfs-dkms_2.3.0-1_amd64.deb"
CACHE_REPO_DIR="${store}"
otarget="$(mktemp -d)"
TARGET="${otarget}"
CAPTURE="$(mktemp)"
# shellcheck disable=SC2317  # invoked indirectly by install_zfs_offline
in_target() { printf '%s\n' "$*" >>"${CAPTURE}"; }
# Real stage_firstboot_runner lives in 60-hyprland.sh (not sourced here); it
# guarantees the firstboot.d dir + unit, which is all this path relies on.
# shellcheck disable=SC2317  # invoked indirectly by stage_zfs_dkms_firstboot
stage_firstboot_runner() { mkdir -p "${TARGET}/usr/lib/hypr-deb/firstboot.d"; }
install_zfs_offline
ocap="$(cat "${CAPTURE}")"
assert_contains "${ocap}" "openzfs-zfs-modules-${KPIN}" \
  "offline install pulls the PREBUILT kmod deb for the pinned kernel"
if [[ "${ocap}" == *openzfs-zfs-dkms* ]]; then
  echo "  FAIL: offline install must not install openzfs-zfs-dkms (postinst compiles)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: openzfs-zfs-dkms kept out of the offline install transaction"
fi
assert_contains "${ocap}" "sha512 '${MOK_KEY}' '${MOK_CRT}'" \
  "prebuilt modules are MOK-signed in the target"
assert_contains "${ocap}" "/usr/lib/linux-kbuild-*/scripts/sign-file" \
  "signing uses linux-kbuild's sign-file (dkms's own tool)"
# kmodsign is Ubuntu-only (their sbsigntool addition) — it does not exist on
# Debian, so the script must never call it.
if [[ "${ocap}" == *kmodsign* ]]; then
  echo "  FAIL: kmodsign does not exist on Debian; sign with sign-file" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no kmodsign call (binary absent on Debian)"
fi
assert_contains "${ocap}" "depmod '${KPIN}'" "depmod runs for the pinned kernel"
# Signing/depmod ride the SAME in_target script as the install, so they finish
# before install_zfs_offline returns — i.e. before configure_zfs_boot_support's
# update-initramfs later in phase_system.
if [[ "${ocap%%zfs version*}" == *sign-file* ]]; then
  echo "  ok: signing completes before the closing smoke test (pre-initramfs)"
else
  echo "  FAIL: sign-file not ordered before the zfs-version smoke test" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -e "${otarget}/var/cache/hypr-deb/openzfs-zfs-dkms_2.3.0-1_amd64.deb" ]]; then
  echo "  ok: dkms deb staged in the target for firstboot"
else
  echo "  FAIL: dkms deb not staged under /var/cache/hypr-deb" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
job="${otarget}/usr/lib/hypr-deb/firstboot.d/40-zfs-dkms.sh"
if [[ -x "${job}" ]]; then
  echo "  ok: firstboot dkms job staged and executable"
else
  echo "  FAIL: firstboot dkms job missing or not executable" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_contains "$(cat "${job}" 2>/dev/null)" \
  "apt-get install -y /var/cache/hypr-deb/openzfs-zfs-dkms_*.deb" \
  "firstboot job installs the staged dkms deb"
rm -rf "${otarget}" "${store}"; rm -f "${CAPTURE}"

# A store without KERNEL_PINNED is broken -> fatal (no silent dkms fallback).
badstore="$(mktemp -d)"; mkdir -p "${badstore}/pool"
rc=0
(CACHE_REPO_DIR="${badstore}" TARGET="$(mktemp -d)" install_zfs_offline) \
  >/dev/null 2>&1 || rc=$?
if ((rc != 0)); then
  echo "  ok: offline install without KERNEL_PINNED is fatal"
else
  echo "  FAIL: offline install proceeded without a kernel pin" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
rm -rf "${badstore}"

finish_test
