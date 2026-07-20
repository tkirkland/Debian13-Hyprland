#!/usr/bin/env bash
# tests/deb-package.sh — unit tests for scripts/lib-deb-package.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=scripts/lib-deb-package.sh
source "${HERE}/../scripts/lib-deb-package.sh"

assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0)" "tag_to_debver strips v, adds -1"
assert_eq "1.2.3-1"  "$(tag_to_debver 1.2.3)"   "tag_to_debver bare version"
assert_eq "1.13.2-1" "$(tag_to_debver xkbcommon-1.13.2)" "tag_to_debver strips name- prefix"

# The revision map lives in lib/00-config.sh (not sourced here) — set the
# entry locally to unit-test the mechanism, grep-assert the config value.
HYPR_DEB_REVISION[xkbcommon]=2
assert_eq "1.13.2-2" "$(tag_to_debver xkbcommon-1.13.2 xkbcommon)" \
  "tag_to_debver applies HYPR_DEB_REVISION for xkbcommon"
assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0 hyprland)" \
  "tag_to_debver defaults unmapped components to -1"

# xkbcommon must declare the libxkbregistry it ships, in all three fields,
# and carry the r2 revision bump so the pool re-pools the control change.
assert_eq "3" "$(grep -c 'libxkbregistry0, libxkbregistry-dev' lib/00-config.sh)" \
  "libxkbregistry declared in Provides+Conflicts+Replaces"
assert_eq "1" "$(grep -c '\[xkbcommon\]=2' lib/00-config.sh)" \
  "HYPR_DEB_REVISION carries xkbcommon r2"

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
{ deb_needs_rebuild "${tmp}" swww 0.12.0-1 && echo "  ok: rebuild when upstream newer"; } \
  || { echo "  FAIL: should rebuild when newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
{ deb_needs_rebuild "${tmp}" newpkg 1.0.0-1 && echo "  ok: rebuild when absent"; } \
  || { echo "  FAIL: should rebuild when absent" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
rm -rf "${tmp}"

tmp="$(mktemp -d)"
write_control "${tmp}" swww 0.11.0-1 amd64 "libc6, libwayland-client0" \
  "libwayland-client0" "libwayland-client0" "libwayland-client0"
ctrl="$(cat "${tmp}/DEBIAN/control")"
assert_contains "${ctrl}" "Package: swww" "control has Package"
assert_contains "${ctrl}" "Version: 0.11.0-1" "control has Version"
assert_contains "${ctrl}" "Architecture: amd64" "control has Architecture"
assert_contains "${ctrl}" "Depends: libc6, libwayland-client0" "control has Depends"
assert_contains "${ctrl}" "Conflicts: libwayland-client0" "control has Conflicts"
assert_contains "${ctrl}" "Replaces: libwayland-client0" "control has Replaces"
assert_contains "${ctrl}" "Provides: libwayland-client0" "control has Provides"
rm -rf "${tmp}"

# When conflicts/replaces/provides are empty, the lines must be absent.
tmp="$(mktemp -d)"
write_control "${tmp}" swww 0.11.0-1 amd64 "libc6"
ctrl="$(cat "${tmp}/DEBIAN/control")"
if [[ "${ctrl}" == *"Conflicts:"* || "${ctrl}" == *"Replaces:"* || "${ctrl}" == *"Provides:"* ]]; then
  echo "  FAIL: empty conflicts/replaces/provides should not emit lines" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
else
  echo "  ok: empty conflicts/replaces/provides omit lines"
fi
rm -rf "${tmp}"

if command -v dpkg-deb >/dev/null; then
  tmp="$(mktemp -d)"; pool="${tmp}/pool"; dest="${tmp}/stage"; mkdir -p "${pool}" "${dest}/usr/local/bin"
  printf '#!/bin/sh\n' >"${dest}/usr/local/bin/swww"; chmod +x "${dest}/usr/local/bin/swww"
  out="$(package_to_deb "${dest}" swww 0.11.0-1 amd64 "libc6" "${pool}")"
  assert_eq "${pool}/swww_0.11.0-1_amd64.deb" "${out}" "package_to_deb returns deb path"
  { [[ -f "${pool}/swww_0.11.0-1_amd64.deb" ]] && echo "  ok: deb created"; } \
    || { echo "  FAIL: deb not created" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  assert_eq "swww" "$(dpkg-deb -f "${pool}/swww_0.11.0-1_amd64.deb" Package)" "deb Package field"
  rm -rf "${tmp}"
else
  echo "  skip: dpkg-deb not installed"
fi

# package_to_deb looks up the optional global maps by name and threads them to
# write_control without changing its argument list.
if command -v dpkg-deb >/dev/null; then
  tmp="$(mktemp -d)"; pool="${tmp}/pool"; dest="${tmp}/stage"; mkdir -p "${pool}" "${dest}/usr/lib"
  : >"${dest}/usr/lib/libfoo.so.0"
  declare -gA HYPR_DEB_PROVIDES=([foo]="libfoo0") HYPR_DEB_CONFLICTS=([foo]="libfoo0") HYPR_DEB_REPLACES=([foo]="libfoo0")
  out="$(package_to_deb "${dest}" foo 1.0.0-1 amd64 "libc6" "${pool}")"
  assert_eq "libfoo0 (= 1.0.0)" "$(dpkg-deb -f "${out}" Provides)" "package_to_deb emits VERSIONED Provides"
  assert_eq "libfoo0" "$(dpkg-deb -f "${out}" Conflicts)" "package_to_deb threads Conflicts from map"
  assert_eq "libfoo0" "$(dpkg-deb -f "${out}" Replaces)" "package_to_deb threads Replaces from map"
  # shellcheck disable=SC2034  # consumed by the sourced package_to_deb
  HYPR_DEB_PROVIDES=() HYPR_DEB_CONFLICTS=() HYPR_DEB_REPLACES=()
  rm -rf "${tmp}"
else
  echo "  skip: dpkg-deb not installed (maps test)"
fi

if command -v dpkg-deb >/dev/null; then
  gtmp="$(mktemp -d)"; gpool="${gtmp}/pool"; mkdir -p "${gpool}"
  : >"${gpool}/foo_1.2.0-1_amd64.deb"
  # shellcheck disable=SC2034  # consumed by the sourced build_component_to_deb
  declare -gA HYPR_REPO_URL=([foo]="https://example/foo") HYPR_TAG_PATTERN=() HYPR_DEB_DEPENDS=([foo]="libc6") HYPR_RESOLVED_TAG=()
  # shellcheck disable=SC2034  # consumed by the sourced build_component_to_deb
  ARCH=amd64
  # shellcheck disable=SC2317  # called indirectly by build_component_to_deb
  resolve_latest_release_tag() { echo "v1.2.0"; }     # upstream == cached -> skip
  stage_source() { :; }
  # shellcheck disable=SC2317  # called indirectly by build_component_to_deb
  build_one() { echo called >>"${gtmp}/calls"; }
  build_component_to_deb foo "${gpool}" >/dev/null 2>&1
  { [[ ! -f "${gtmp}/calls" ]] && echo "  ok: gate skips build when upstream not newer"; } \
    || { echo "  FAIL: built despite not newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  resolve_latest_release_tag() { echo "v1.3.0"; }      # upstream newer -> build
  build_one() { mkdir -p "${HYPR_DESTDIR}/usr/bin"; : >"${HYPR_DESTDIR}/usr/bin/foo"; }
  build_component_to_deb foo "${gpool}" >/dev/null 2>&1
  { [[ -f "${gpool}/foo_1.3.0-1_amd64.deb" ]] && echo "  ok: gate builds+packages when newer"; } \
    || { echo "  FAIL: no new deb when upstream newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  # Pin resolution: a pinned component must yield the pin WITHOUT any network
  # tag lookup; unpinned components fall through to resolve_latest_release_tag.
  declare -gA HYPR_TAG_PIN=([foo]="v1.1.0")
  # shellcheck disable=SC2317  # must not be reached for a pinned component
  resolve_latest_release_tag() { echo "FAIL-network-hit"; }
  ptag="$(resolve_component_tag foo)"
  { [[ "${ptag}" == "v1.1.0" ]] && echo "  ok: pinned component resolves to the pin, no network"; } \
    || { echo "  FAIL: pin ignored (got ${ptag})" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  resolve_latest_release_tag() { echo "v9.9.9"; }
  HYPR_REPO_URL[foo2]="https://example/foo2"
  utag="$(resolve_component_tag foo2)"
  { [[ "${utag}" == "v9.9.9" ]] && echo "  ok: unpinned component floats to latest"; } \
    || { echo "  FAIL: unpinned float broken (got ${utag})" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  unset 'HYPR_TAG_PIN[foo]'
  npins="$(grep -c '^\s*\[\(hyprutils\|aquamarine\)\]="v' lib/00-config.sh || true)"
  { [[ "${npins}" == "2" ]] && echo "  ok: config pins hyprutils + aquamarine (drop when Hyprland advances)"; } \
    || { echo "  FAIL: expected exactly 2 stack pins in lib/00-config.sh, got ${npins}" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  rm -rf "${gtmp}"
else
  echo "  skip: dpkg-deb not installed (gate test)"
fi

# --- Auto shared-lib dependency derivation (dpkg-shlibdeps), issue #82 --------
# Our source-built debs supersede Debian's wayland/xkbcommon via Provides, so
# auto-derived deps naming those must be stripped; real deps (libre2-11) kept;
# manual HYPR_DEB_DEPENDS entries merged with manual winning.
declare -gA HYPR_DEB_PROVIDES=(
  [wayland]="libwayland-client0, libwayland-server0"
  [xkbcommon]="libxkbcommon0"
)

prov="$(_self_provided_names)"
assert_contains "${prov}" " libwayland-client0 " "_self_provided_names is space-bounded"
assert_contains "${prov}" " libxkbcommon0 " "_self_provided_names spans multiple Provides keys"

stripped="$(_strip_self_provided "libc6 (>= 2.34), libwayland-client0 (>= 1.20), libre2-11, libxkbcommon0")"
assert_contains "${stripped}" "libre2-11" "_strip keeps a real external dep"
assert_contains "${stripped}" "libc6 (>= 2.34)" "_strip keeps libc6 with its version"
case "${stripped}" in
  *libwayland-client0*|*libxkbcommon0*)
    echo "  FAIL: superseded libs not stripped" >&2; TEST_FAILURES=$((TEST_FAILURES+1)) ;;
  *) echo "  ok: superseded wayland/xkbcommon deps stripped" ;;
esac

merged="$(_merge_depends "libc6, libwayland-client0, libgcc-s1" "libc6 (>= 2.34), libre2-11")"
assert_contains "${merged}" "libwayland-client0" "_merge keeps a manual-only dep"
assert_contains "${merged}" "libre2-11" "_merge adds an auto-only dep"
assert_contains "${merged}" "libc6," "_merge: unversioned manual libc6 wins"
case "${merged}" in
  *"libc6 (>= 2.34)"*)
    echo "  FAIL: auto libc6 duplicated despite manual" >&2; TEST_FAILURES=$((TEST_FAILURES+1)) ;;
  *) echo "  ok: _merge dedups by package name" ;;
esac

# shlibdeps_scan is a no-op (empty) without dpkg-shlibdeps -> manual-map fallback.
if ! command -v dpkg-shlibdeps >/dev/null 2>&1; then
  assert_eq "" "$(shlibdeps_scan "$(mktemp -d)" amd64)" "shlibdeps_scan no-op without dpkg-shlibdeps"
fi

# With a fake dpkg-shlibdeps + an ELF-magic file, shlibdeps_scan parses output.
# Use a .so fixture (matched by find -name '*.so*'): the exec-bit branch is not
# detectable on the Windows dev host, but the name branch is portable.
fbin="$(mktemp -d)"
make_fake "${fbin}" dpkg-shlibdeps 'echo "shlibs:Depends=libc6 (>= 2.34), libre2-11, libwayland-client0 (>= 1.20)"'
fdest="$(mktemp -d)"; mkdir -p "${fdest}/usr/lib"
printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000' >"${fdest}/usr/lib/libhyprland.so.0"
scanned="$(PATH="${fbin}:${PATH}" shlibdeps_scan "${fdest}" amd64)"
assert_contains "${scanned}" "libre2-11" "shlibdeps_scan parses shlibs:Depends"
assert_contains "${scanned}" "libwayland-client0" "shlibdeps_scan returns raw (unstripped) deps"
rm -rf "${fbin}" "${fdest}"

# End-to-end: package_to_deb auto-derives, strips superseded, and writes Depends.
if command -v dpkg-deb >/dev/null; then
  ptmp="$(mktemp -d)"; ppool="${ptmp}/pool"; pdest="${ptmp}/stage"
  mkdir -p "${ppool}" "${pdest}/usr/lib"
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000' >"${pdest}/usr/lib/libhyprland.so.0"
  fb2="$(mktemp -d)"
  make_fake "${fb2}" dpkg-shlibdeps 'echo "shlibs:Depends=libre2-11, libwayland-server0 (>= 1.20), libgcc-s1"'
  out="$(PATH="${fb2}:${PATH}" package_to_deb "${pdest}" hyprland 0.55.4-1 amd64 "" "${ppool}")"
  dep="$(dpkg-deb -f "${out}" Depends)"
  assert_contains "${dep}" "libre2-11" "package_to_deb declares auto-derived libre2-11 (#82)"
  case "${dep}" in
    *libwayland-server0*)
      echo "  FAIL: superseded libwayland-server0 leaked into Depends" >&2; TEST_FAILURES=$((TEST_FAILURES+1)) ;;
    *) echo "  ok: superseded wayland dep kept out of the deb Depends" ;;
  esac
  rm -rf "${ptmp}" "${fb2}"
else
  echo "  skip: dpkg-deb not installed (shlibdeps integration)"
fi

HYPR_DEB_PROVIDES=()

# --- FIX 1: package_to_deb strips ELF debug symbols before building the deb ----
# A fake `strip` on PATH records its argv; assert it ran with --strip-unneeded
# over the staged ELF executable and *.so* but NOT over the static archive (.a),
# which strip would corrupt.
if command -v dpkg-deb >/dev/null; then
  stmp="$(mktemp -d)"; spool="${stmp}/pool"; sdest="${stmp}/stage"
  mkdir -p "${spool}" "${sdest}/usr/bin" "${sdest}/usr/lib"
  printf '\177ELF\002\001\001\000' >"${sdest}/usr/bin/hyprctl"
  chmod +x "${sdest}/usr/bin/hyprctl"
  printf '\177ELF\002\001\001\000' >"${sdest}/usr/lib/libhyprutils.so.5"
  printf '!<arch>\n'              >"${sdest}/usr/lib/liblua.a"   # static: MUST NOT strip
  fstrip="$(mktemp -d)"
  export STRIP_LOG="${stmp}/strip.log"; : >"${STRIP_LOG}"
  # shellcheck disable=SC2016  # fake body must keep $@/${STRIP_LOG} literal until run
  make_fake "${fstrip}" strip 'for a in "$@"; do printf "%s\n" "$a" >>"${STRIP_LOG}"; done'
  PATH="${fstrip}:${PATH}" package_to_deb "${sdest}" hyprutils 1.0.0-1 amd64 "" "${spool}" >/dev/null
  slog="$(cat "${STRIP_LOG}")"
  assert_contains "${slog}" "--strip-unneeded" "strip uses --strip-unneeded (keeps .dynsym for buildroot relink)"
  assert_contains "${slog}" "/usr/bin/hyprctl" "strip covers the staged ELF executable"
  assert_contains "${slog}" "/usr/lib/libhyprutils.so.5" "strip covers the staged shared object"
  if [[ "${slog}" == *"liblua.a"* ]]; then
    echo "  FAIL: static archive liblua.a was stripped (would corrupt it)" >&2
    TEST_FAILURES=$((TEST_FAILURES+1))
  else
    echo "  ok: static archive liblua.a left untouched"
  fi
  if [[ -f "${spool}/hyprutils_1.0.0-1_amd64.deb" ]]; then
    echo "  ok: deb still built after the strip pass"
  else
    echo "  FAIL: deb not built after strip pass" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
  fi
  unset STRIP_LOG
  rm -rf "${stmp}" "${fstrip}"
else
  echo "  skip: dpkg-deb not installed (strip test)"
fi

finish_test
