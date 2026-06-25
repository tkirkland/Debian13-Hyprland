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

if command -v dpkg-deb >/dev/null; then
  tmp="$(mktemp -d)"; pool="${tmp}/pool"; dest="${tmp}/stage"; mkdir -p "${pool}" "${dest}/usr/local/bin"
  printf '#!/bin/sh\n' >"${dest}/usr/local/bin/swww"; chmod +x "${dest}/usr/local/bin/swww"
  out="$(package_to_deb "${dest}" swww 0.11.0-1 amd64 "libc6" "${pool}")"
  assert_eq "${pool}/swww_0.11.0-1_amd64.deb" "${out}" "package_to_deb returns deb path"
  [[ -f "${pool}/swww_0.11.0-1_amd64.deb" ]] && echo "  ok: deb created" \
    || { echo "  FAIL: deb not created" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  assert_eq "swww" "$(dpkg-deb -f "${pool}/swww_0.11.0-1_amd64.deb" Package)" "deb Package field"
  rm -rf "${tmp}"
else
  echo "  skip: dpkg-deb not installed"
fi

if command -v dpkg-deb >/dev/null; then
  gtmp="$(mktemp -d)"; gpool="${gtmp}/pool"; mkdir -p "${gpool}"
  : >"${gpool}/foo_1.2.0-1_amd64.deb"
  declare -gA HYPR_REPO_URL=([foo]="https://example/foo") HYPR_TAG_PATTERN=() HYPR_DEB_DEPENDS=([foo]="libc6") HYPR_RESOLVED_TAG=()
  ARCH=amd64
  resolve_latest_release_tag() { echo "v1.2.0"; }     # upstream == cached -> skip
  stage_source() { :; }
  build_one() { echo called >>"${gtmp}/calls"; }
  build_component_to_deb foo "${gpool}" >/dev/null 2>&1
  [[ ! -f "${gtmp}/calls" ]] && echo "  ok: gate skips build when upstream not newer" \
    || { echo "  FAIL: built despite not newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  resolve_latest_release_tag() { echo "v1.3.0"; }      # upstream newer -> build
  build_one() { mkdir -p "${HYPR_DESTDIR}/usr/bin"; : >"${HYPR_DESTDIR}/usr/bin/foo"; }
  build_component_to_deb foo "${gpool}" >/dev/null 2>&1
  [[ -f "${gpool}/foo_1.3.0-1_amd64.deb" ]] && echo "  ok: gate builds+packages when newer" \
    || { echo "  FAIL: no new deb when upstream newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  rm -rf "${gtmp}"
else
  echo "  skip: dpkg-deb not installed (gate test)"
fi

finish_test
