#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: xdg-desktop-portal stack + lxpolkit + Dolphin (#57/#67/#70)"

# --- package sets (lib/00-config.sh) ----------------------------------------
# Every base-set assertion sources the config in a subshell so array-member and
# assoc-array-key checks see the real declarations (not file text).
base="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"')"
assert_contains "${base}" "xdg-desktop-portal"     "base set: generic portal service (#57/#67)"
assert_contains "${base}" "xdg-desktop-portal-gtk" "base set: gtk portal backend"
assert_contains "${base}" "xdg-desktop-portal-wlr" "base set: wlr screencast backend (guaranteed fallback)"
assert_contains "${base}" "lxpolkit"               "base set: lxpolkit polkit agent (#67 item 4)"
assert_contains "${base}" "dolphin"                "base set: Dolphin file manager (#70)"
assert_contains "${base}" "libglib2.0-bin"         "base set: glib-compile-schemas for the dark-mode override"

portal="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${PORTAL_PACKAGES[@]}"')"
assert_contains "${portal}" "xdg-desktop-portal"     "PORTAL_PACKAGES: generic portal service"
assert_contains "${portal}" "xdg-desktop-portal-gtk" "PORTAL_PACKAGES: gtk backend"
assert_contains "${portal}" "xdg-desktop-portal-wlr" "PORTAL_PACKAGES: wlr backend"
assert_contains "${portal}" "libglib2.0-bin"         "PORTAL_PACKAGES: libglib2.0-bin"

polkit="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${POLKIT_PACKAGES[@]}"')"
assert_eq "lxpolkit" "${polkit}" "POLKIT_PACKAGES is exactly lxpolkit"

filemgr="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${FILEMANAGER_PACKAGES[@]}"')"
assert_eq "dolphin" "${filemgr}" "FILEMANAGER_PACKAGES is exactly dolphin"

# --- xdph is its own optional component, NOT in the must-succeed build set ----
# xdph must NEVER be a HYPR_BUILD_ORDER member (the #64 dead-greeter invariant):
# that array is a must-succeed set whose failure would strand uwsm / abort the
# offline apt transaction. It is an EXTRA HYPR_REPO_URL key resolved by its own
# guarded, best-effort build step.
out="$(bash -c 'source lib/00-config.sh
  for n in "${HYPR_BUILD_ORDER[@]}"; do
    [[ "${n}" == "${XDPH_COMPONENT}" ]] && { echo FOUND; exit 0; }
  done
  echo NOTFOUND')"
assert_eq "NOTFOUND" "${out}" "xdph is NOT a member of HYPR_BUILD_ORDER (#64 invariant)"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_BUILD_ORDER[-1]}"')"
assert_eq "uwsm" "${out}" "HYPR_BUILD_ORDER still ends with uwsm"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_REPO_URL[${XDPH_COMPONENT}]:-}"')"
[[ -n "${out}" ]] \
  && echo "  ok: HYPR_REPO_URL[\${XDPH_COMPONENT}] is set (${out})" \
  || { echo "  FAIL: HYPR_REPO_URL[\${XDPH_COMPONENT}] is empty" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

# --- xdph runtime Depends: conservative, shlibdeps-derived --------------------
# The .deb's real Qt6/PipeWire/sdbus-c++ runtime libs are derived by
# dpkg-shlibdeps in package_to_deb. Hardcoding them here would be a phantom-name
# regression: the trixie t64 rename makes those literal names unsatisfiable.
out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_DEB_DEPENDS[${XDPH_COMPONENT}]:-UNSET}"')"
assert_eq "xdg-desktop-portal" "${out}" "HYPR_DEB_DEPENDS[xdph] is exactly xdg-desktop-portal"
case "${out}" in
  *libpipewire*|*libqt6*)
    echo "  FAIL: HYPR_DEB_DEPENDS[xdph] hardcodes shlibdeps-derived libs (phantom-name regression)" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1)) ;;
  *)
    echo "  ok: no hardcoded libpipewire/libqt6 in HYPR_DEB_DEPENDS[xdph] (shlibdeps derives those)" ;;
esac

# --- xdph source build-deps present in the general build set ------------------
bpkgs="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${HYPR_BUILD_PACKAGES[@]}"')"
assert_contains "${bpkgs}" "qt6-base-dev"         "HYPR_BUILD_PACKAGES: qt6-base-dev (share-picker)"
assert_contains "${bpkgs}" "libpipewire-0.3-dev"  "HYPR_BUILD_PACKAGES: libpipewire-0.3-dev"
assert_contains "${bpkgs}" "libspa-0.2-dev"       "HYPR_BUILD_PACKAGES: libspa-0.2-dev"
assert_contains "${bpkgs}" "libsdbus-c++-dev"     "HYPR_BUILD_PACKAGES: libsdbus-c++-dev"

# --- write_portal_config golden output (scripts/60-hyprland.sh) --------------
# Stub the installer logging/target helpers, source the phase script, stage the
# portal routing + dark-mode override into a throwaway TARGET, and assert the
# generated files carry the static, unconditional routing.
info() { :; }
warn() { :; }
in_target() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"
TARGET_USERNAME="tester"

write_portal_config

portals_conf="${TARGET}/home/${TARGET_USERNAME}/.config/xdg-desktop-portal/hyprland-portals.conf"
gschema="${TARGET}/usr/share/glib-2.0/schemas/90-hypr-deb.gschema.override"

[[ -f "${portals_conf}" ]] \
  || { echo "  FAIL: hyprland-portals.conf not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -f "${gschema}" ]] \
  || { echo "  FAIL: gschema override not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

conf_txt="$(<"${portals_conf}")"
gschema_txt="$(<"${gschema}")"

assert_contains "${conf_txt}" "default=gtk" \
  "portals.conf: gtk is the default portal impl"
assert_contains "${conf_txt}" "org.freedesktop.impl.portal.ScreenCast=hyprland;wlr" \
  "portals.conf: ScreenCast routes hyprland then wlr fallback"
assert_contains "${gschema_txt}" "color-scheme='prefer-dark'" \
  "gschema override selects the dark colour scheme"

finish_test
