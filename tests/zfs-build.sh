#!/usr/bin/env bash
# tests/zfs-build.sh — unit tests for scripts/40-system.sh's ZFS paths:
#   install_zfs_from_source — noautodbgsym build env; native-deb-kmod built and
#   pooled ONLY on the ZFS_DEB_POOL (ISO-build) path, pinned to KERNEL_PINNED
#   (issue #110); install-time path unchanged (no kmod).
#   install_zfs_offline — installs the dkms deb IN THE CHROOT (build for the
#   target kernel, before configure_zfs_boot_support's update-initramfs);
#   never a prebuilt kmod handover, never a firstboot job (issue #111).
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
KTGT="6.12.44+deb13-amd64"
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
    "${TARGET}/var/tmp/openzfs-zfs-modules-${KTGT}_2.3.0-1_amd64.deb" \
    "${TARGET}/var/tmp/openzfs-zfs-test_2.3.0-1_amd64.deb" \
    "${TARGET}/var/tmp/openzfs-pam-zfs-key_2.3.0-1_amd64.deb"
}
KERNEL_PINNED="${KPIN}" KERNEL_TARGET="${KTGT}" ZFS_DEB_POOL="${zpool_dir}" \
  install_zfs_from_source
zcap="$(cat "${CAPTURE}")"
assert_contains "${zcap}" "native-deb-kmod" "pool path builds the kmod deb"
# Debian split headers: configure src must be the -common dir (linux/objtool.h
# lives there — arch-dir src silently drops HAVE_STACK_FRAME_NON_STANDARD_ASM
# and the icp .S assembly dies on a duplicate macro), obj the arch dir.
KPIN_COMMON="${KPIN%-*}-common"
KTGT_COMMON="${KTGT%-*}-common"
assert_contains "${zcap}" "--with-linux=/usr/src/linux-headers-${KPIN_COMMON}" \
  "kmod build configures src against the PINNED kernel's COMMON headers"
assert_contains "${zcap}" "--with-linux-obj=/usr/src/linux-headers-${KPIN}" \
  "kmod build configures obj against the PINNED kernel's arch headers"
assert_contains "${zcap}" "openzfs-zfs-modules-${KPIN}" \
  "pool path asserts the pinned kmod deb was produced"
# Upstream debian/rules defaults KVERS to the BUILD HOST's uname -r and its
# module build re-configures with --with-linux=$(KSRC) --with-linux-obj=$(KOBJ),
# overriding the cfg_flags pin — all three must ride the make invocation.
assert_contains "${zcap}" "native-deb-kmod KVERS='${KPIN}' KSRC='/usr/src/linux-headers-${KPIN_COMMON}' KOBJ='/usr/src/linux-headers-${KPIN}'" \
  "kmod make passes KVERS + KSRC(common) + KOBJ(arch) so the deb targets the PINNED kernel"
# Kernel skew (security suite past the stock ISO): a SECOND kmod deb must be
# built for the TARGET kernel the pool metapackage resolves to — that is the
# kernel the installed system boots.
assert_contains "${zcap}" "native-deb-kmod KVERS='${KTGT}' KSRC='/usr/src/linux-headers-${KTGT_COMMON}' KOBJ='/usr/src/linux-headers-${KTGT}'" \
  "skewed pool also builds the kmod deb for the TARGET kernel"
assert_contains "${zcap}" "modinfo -F vermagic" \
  "each kmod deb's packaged .ko is vermagic-checked against its KVERS"
# Without a clean AND a configure-stamp removal between builds, the second
# kmod build ships the first kernel's modules (both seen live: stale objects
# packaged under the new name; then fresh objects compiled against the old
# kernel config because override_dh_configure_modules is stamped).
n_clean="$(grep -c "make -s clean" <<<"${zcap}")"
n_stamp="$(grep -c "rm -f override_dh_configure_modules_stamp" <<<"${zcap}")"
n_kmod="$(grep -c "native-deb-kmod" <<<"${zcap}")"
if [[ "${n_clean}" == "${n_kmod}" && "${n_stamp}" == "${n_kmod}" && "${n_kmod}" == "2" ]]; then
  echo "  ok: every kmod build is preceded by make clean + configure-stamp removal"
else
  echo "  FAIL: ${n_kmod} kmod builds, ${n_clean} cleans, ${n_stamp} stamp removals" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -e "${zpool_dir}/openzfs-zfs-modules-${KPIN}_2.3.0-1_amd64.deb" &&
  -e "${zpool_dir}/openzfs-zfs-modules-${KTGT}_2.3.0-1_amd64.deb" ]]; then
  echo "  ok: both kmod debs copied into the pool (filter admits zfs-modules)"
else
  echo "  FAIL: kmod deb(s) not pooled (filter still excludes zfs-modules)" >&2
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

# No skew (target kernel == pin): exactly ONE kmod build, not a duplicate.
CAPTURE="$(mktemp)"
ztarget="$(mktemp -d)"; mkdir -p "${ztarget}/var/tmp"
zpool_dir="$(mktemp -d)"
TARGET="${ztarget}"
KERNEL_PINNED="${KPIN}" KERNEL_TARGET="${KPIN}" ZFS_DEB_POOL="${zpool_dir}" \
  install_zfs_from_source
n="$(grep -c "native-deb-kmod" "${CAPTURE}")"
if [[ "${n}" == "1" ]]; then
  echo "  ok: pin == target dedupes to a single kmod build"
else
  echo "  FAIL: pin == target ran ${n} kmod builds (want 1)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
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

# ...and without KERNEL_TARGET (pin set) equally fatal.
rc=0
(TARGET="$(mktemp -d)" ZFS_DEB_POOL="$(mktemp -d)" KERNEL_PINNED="${KPIN}" \
  install_zfs_from_source) >/dev/null 2>&1 || rc=$?
if ((rc != 0)); then
  echo "  ok: ZFS_DEB_POOL without KERNEL_TARGET is fatal"
else
  echo "  FAIL: pool build ran without a target kernel" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- install_zfs_offline: dkms builds IN THE CHROOT, nothing deferred --------
# shellcheck disable=SC2034  # consumed by the sourced install_zfs_offline
ZFS_UPSTREAM_PACKAGES=(openzfs-zfsutils openzfs-zfs-dkms openzfs-zfs-initramfs openzfs-zfs-zed)
store="$(mktemp -d)"
mkdir -p "${store}/pool"
echo "${KPIN}" >"${store}/KERNEL_PINNED"
echo "${KTGT}" >"${store}/KERNEL_TARGET"
CACHE_REPO_DIR="${store}"
otarget="$(mktemp -d)"
TARGET="${otarget}"
CAPTURE="$(mktemp)"
# shellcheck disable=SC2317  # invoked indirectly by install_zfs_offline
in_target() { printf '%s\n' "$*" >>"${CAPTURE}"; }
install_zfs_offline
ocap="$(cat "${CAPTURE}")"
# The install must be COMPLETE at reboot: the dkms deb installs and builds in
# the chroot — no prebuilt kmod handover, no firstboot job (issue #111).
assert_contains "${ocap}" "openzfs-zfs-dkms" \
  "offline install installs the dkms deb in the chroot"
if [[ "${ocap}" == *openzfs-zfs-modules-* ]]; then
  echo "  FAIL: offline install must not pull a prebuilt kmod deb (dkms owns the module)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no prebuilt kmod deb in the transaction (dkms owns the module)"
fi
# The installed system boots the pool metapackage's kernel (KERNEL_TARGET),
# not the live pin — the module must be built for the TARGET kernel, and the
# explicit autoinstall covers a postinst that configured before the headers.
assert_contains "${ocap}" "dkms autoinstall -k '${KTGT}'" \
  "dkms module built for the TARGET kernel (explicit autoinstall)"
assert_contains "${ocap}" "modinfo -k '${KTGT}' zfs" \
  "module resolution asserted for the target kernel"
assert_contains "${ocap}" "depmod '${KTGT}'" "depmod runs for the target kernel"
# kmodsign is Ubuntu-only (their sbsigntool addition) — it does not exist on
# Debian, so the script must never call it (dkms itself signs via sign-file).
if [[ "${ocap}" == *kmodsign* ]]; then
  echo "  FAIL: kmodsign does not exist on Debian; dkms signs via sign-file" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no kmodsign call (binary absent on Debian)"
fi
# Build/assert ride the SAME in_target script as the install, so they finish
# before install_zfs_offline returns — i.e. before configure_zfs_boot_support's
# update-initramfs later in the phase.
if [[ "${ocap%%zfs version*}" == *"dkms autoinstall"* ]]; then
  echo "  ok: dkms build completes before the closing smoke test (pre-initramfs)"
else
  echo "  FAIL: dkms autoinstall not ordered before the zfs-version smoke test" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if compgen -G "${otarget}/usr/lib/hypr-deb/firstboot.d/*.sh" >/dev/null; then
  echo "  FAIL: no firstboot job may be staged (install work after reboot)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no firstboot job staged (install complete at reboot)"
fi
rm -rf "${otarget}" "${store}"; rm -f "${CAPTURE}"

# A store without KERNEL_TARGET is broken -> fatal (no silent dkms fallback).
badstore="$(mktemp -d)"; mkdir -p "${badstore}/pool"
rc=0
(CACHE_REPO_DIR="${badstore}" TARGET="$(mktemp -d)" install_zfs_offline) \
  >/dev/null 2>&1 || rc=$?
if ((rc != 0)); then
  echo "  ok: offline install without KERNEL_TARGET is fatal"
else
  echo "  FAIL: offline install proceeded without a target kernel" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
rm -rf "${badstore}"

finish_test
