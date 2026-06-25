#!/usr/bin/env bash
# tests/deb-package.sh — unit tests for scripts/lib-deb-package.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../scripts/lib-deb-package.sh"

assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0)" "tag_to_debver strips v, adds -1"
assert_eq "1.2.3-1"  "$(tag_to_debver 1.2.3)"   "tag_to_debver bare version"

tmp="$(mktemp -d)"
# 0.9.0 vs 0.10.0 discriminates dpkg ordering from bash lexical '>':
# lexical wrongly prefers 0.9.0, dpkg correctly picks 0.10.0.
: >"${tmp}/swww_0.9.0-1_amd64.deb"
: >"${tmp}/swww_0.10.0-1_amd64.deb"
: >"${tmp}/hyprland_0.49.0-1_amd64.deb"
assert_eq "0.10.0-1" "$(cached_deb_version "${tmp}" swww)" "cached_deb_version picks highest"
assert_eq ""         "$(cached_deb_version "${tmp}" nope)" "cached_deb_version empty when absent"
rm -rf "${tmp}"

tmp="$(mktemp -d)"
: >"${tmp}/swww_0.11.0-1_amd64.deb"
assert_fails "no rebuild when upstream == cached" deb_needs_rebuild "${tmp}" swww 0.11.0-1
deb_needs_rebuild "${tmp}" swww 0.12.0-1 && echo "  ok: rebuild when upstream newer" \
  || { echo "  FAIL: should rebuild when newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
deb_needs_rebuild "${tmp}" newpkg 1.0.0-1 && echo "  ok: rebuild when absent" \
  || { echo "  FAIL: should rebuild when absent" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
rm -rf "${tmp}"

tmp="$(mktemp -d)"
write_control "${tmp}" swww 0.11.0-1 amd64 "libc6, libwayland-client0"
ctrl="$(cat "${tmp}/DEBIAN/control")"
assert_contains "${ctrl}" "Package: swww" "control has Package"
assert_contains "${ctrl}" "Version: 0.11.0-1" "control has Version"
assert_contains "${ctrl}" "Architecture: amd64" "control has Architecture"
assert_contains "${ctrl}" "Depends: libc6, libwayland-client0" "control has Depends"
rm -rf "${tmp}"

finish_test
