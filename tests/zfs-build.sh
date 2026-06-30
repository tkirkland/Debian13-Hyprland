#!/usr/bin/env bash
# tests/zfs-build.sh — unit test for scripts/40-system.sh install_zfs_from_source:
#   the OpenZFS native-deb build env carries DEB_BUILD_OPTIONS=noautodbgsym (so
#   the auto -dbgsym debs are never generated) while still asserting the required
#   openzfs-* debs were produced.
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

finish_test
