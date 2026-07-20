#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/test-helpers.sh
source tests/test-helpers.sh

echo "test: dark theming defaults (#51/#76)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- package sets (lib/00-config.sh) ----------------------------------------
# Sourced in a subshell so array-member checks see the real declarations.
base="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"')"
theme="$(bash -c 'source lib/00-config.sh; printf "%s\n" "${THEME_PACKAGES[@]}"')"
for p in gnome-themes-extra qt6-gtk-platformtheme papirus-icon-theme \
  adwaita-icon-theme; do
  assert_contains "${theme}" "${p}" "THEME_PACKAGES: ${p}"
  assert_contains "${base}" "${p}" "base set spliced: ${p}"
done

# --- gschema override heredoc carries the four theming keys -------------------
# Source-level structural check (like tests/build-guard.sh): the literal keys
# must sit in write_portal_config's override heredoc.
hypr_src="scripts/60-hyprland.sh"
for key in "color-scheme='prefer-dark'" "gtk-theme='adw-gtk3-dark'" \
  "icon-theme='Papirus-Dark'" "cursor-theme='Adwaita'"; do
  { grep -qF "${key}" "${hypr_src}" \
    && echo "  ok: gschema override sets ${key}"; } \
    || { echo "  FAIL: gschema override missing ${key}" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
done

# --- GTK3 CSD shadow-margin zeroing (Hyprland 0.55 clip workaround) -----------
# Same structural check: write_portal_config must stage a gtk.css that zeroes
# decoration box-shadow/margin (GTK3 CSD windows, tiled or floating, clip by the shadow
# margin on Hyprland 0.55 — reference-machine A/B 2026-07-19).
for frag in "box-shadow: none" "margin: 0"; do
  { grep -qF "${frag}" "${hypr_src}" \
    && echo "  ok: gtk.css zeroes CSD ${frag%%:*}"; } \
    || { echo "  FAIL: gtk.css missing ${frag}" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
done

# --- write_uwsm_env (scripts/60-hyprland.sh) ----------------------------------
# Stub the installer logging/target helpers, source the phase script, and run
# the env writer against a throwaway TARGET on both the no-NVIDIA and NVIDIA
# paths.
info() { :; }
warn() { :; }
in_target() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
# shellcheck source=scripts/60-hyprland.sh
source scripts/60-hyprland.sh

TARGET="${tmp}/target"
TARGET_USERNAME="tester"
envf="${TARGET}/home/${TARGET_USERNAME}/.config/uwsm/env"

# No NVIDIA: the file is STILL written (theming is unconditional, #51/#76)...
nvidia_install_requested() { return 1; }
write_uwsm_env
{ [[ -f "${envf}" ]] && echo "  ok: uwsm env written on the no-NVIDIA path"; } \
  || { echo "  FAIL: uwsm env not written without NVIDIA" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
env_txt="$(<"${envf}")"
assert_contains "${env_txt}" "export QT_QPA_PLATFORMTHEME=gtk3" \
  "uwsm env: Qt6 follows the GTK theme"
assert_contains "${env_txt}" "export XCURSOR_THEME=Adwaita" \
  "uwsm env: Adwaita cursor pinned"
# ...and carries NO NVIDIA variables.
if [[ "${env_txt}" != *nvidia* ]]; then
  echo "  ok: no NVIDIA lines on the no-NVIDIA path"
else
  echo "  FAIL: NVIDIA lines leaked into the no-NVIDIA uwsm env" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# NVIDIA requested: same theming block PLUS the appended wiki variables.
nvidia_install_requested() { return 0; }
write_uwsm_env
env_txt="$(<"${envf}")"
assert_contains "${env_txt}" "export QT_QPA_PLATFORMTHEME=gtk3" \
  "uwsm env (NVIDIA): theming block still present"
assert_contains "${env_txt}" "export GBM_BACKEND=nvidia-drm" \
  "uwsm env (NVIDIA): GBM backend appended"
assert_contains "${env_txt}" "export __GLX_VENDOR_LIBRARY_NAME=nvidia" \
  "uwsm env (NVIDIA): GLX vendor appended"

# --- install_adw_gtk3_theme: OFFLINE copy from the on-ISO store ---------------
# shellcheck source=scripts/40-system.sh
source scripts/40-system.sh

ADW_GTK3_REPO_URL="https://github.com/lassekongo83/adw-gtk3"
ADW_GTK3_STORE_SUBDIR="adw-gtk3"
CACHE_REPO_DIR="${tmp}/store"
TARGET="${tmp}/adw-target"
mkdir -p "${TARGET}"

# Store absent: warn + return 0 (degrade, don't abort the install).
{ install_adw_gtk3_theme \
  && echo "  ok: missing adw-gtk3 store degrades (returns 0)"; } \
  || { echo "  FAIL: install_adw_gtk3_theme aborted on a missing store" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
if [[ ! -d "${TARGET}/usr/share/themes/adw-gtk3-dark" ]]; then
  echo "  ok: nothing installed from an empty store"
else
  echo "  FAIL: theme dir appeared despite an empty store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# Seeded store: both theme dirs copied into the system theme path.
mkdir -p "${CACHE_REPO_DIR}/${ADW_GTK3_STORE_SUBDIR}/adw-gtk3/gtk-3.0" \
  "${CACHE_REPO_DIR}/${ADW_GTK3_STORE_SUBDIR}/adw-gtk3-dark/gtk-3.0"
: >"${CACHE_REPO_DIR}/${ADW_GTK3_STORE_SUBDIR}/adw-gtk3/gtk-3.0/gtk.css"
: >"${CACHE_REPO_DIR}/${ADW_GTK3_STORE_SUBDIR}/adw-gtk3-dark/gtk-3.0/gtk.css"
adw_curl_log="${tmp}/adw-curl.log"
: >"${adw_curl_log}"
# Any curl at install time is a regression: log it so we can assert none.
# shellcheck disable=SC2317  # invoked indirectly by install_adw_gtk3_theme
curl() { printf '%s\n' "$*" >>"${adw_curl_log}"; }
install_adw_gtk3_theme
unset -f curl
for d in adw-gtk3 adw-gtk3-dark; do
  if [[ -f "${TARGET}/usr/share/themes/${d}/gtk-3.0/gtk.css" ]]; then
    echo "  ok: ${d} copied from the offline store into /usr/share/themes"
  else
    echo "  FAIL: ${d} not installed from the offline store" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
done
adw_curl_txt="$(<"${adw_curl_log}")"
if [[ -z "${adw_curl_txt}" ]]; then
  echo "  ok: offline adw-gtk3 install makes NO curl call"
else
  echo "  FAIL: offline adw-gtk3 install fetched from the network: ${adw_curl_txt}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- adw-gtk3 build harvest: tarball fetched + theme dirs extracted -----------
# harvest_adw_gtk3 uses the pinned ADW_GTK3_VERSION (no latest-resolve), curls
# the release tarball (asset name adw-gtk3${tag}.tar.xz) and extracts the two
# theme dirs into the store dir.
ADW_GTK3_VERSION="v6.5"
adest="${tmp}/harvest/adw-gtk3"
ah_log="${tmp}/adw-harvest-curl.log"
: >"${ah_log}"
# Fake curl: log the URL and create the -o tarball. Fake tar: create the two
# theme dirs under -C, as the real extraction would.
# shellcheck disable=SC2317  # invoked indirectly by harvest_adw_gtk3
curl() {
  printf '%s\n' "$*" >>"${ah_log}"
  local out="" prev=""
  for a in "$@"; do [[ "${prev}" == "-o" ]] && out="${a}"; prev="${a}"; done
  [[ -n "${out}" ]] && : >"${out}"
}
# shellcheck disable=SC2317  # invoked indirectly by harvest_adw_gtk3
tar() {
  local d="" prev=""
  for a in "$@"; do [[ "${prev}" == "-C" ]] && d="${a}"; prev="${a}"; done
  [[ -n "${d}" ]] && mkdir -p "${d}/adw-gtk3/gtk-3.0" "${d}/adw-gtk3-dark/gtk-3.0"
}
harvest_adw_gtk3 "${adest}"
unset -f curl tar
assert_contains "$(<"${ah_log}")" \
  "https://github.com/lassekongo83/adw-gtk3/releases/download/v6.5/adw-gtk3v6.5.tar.xz" \
  "build harvest fetches the pinned release tarball (adw-gtk3\${tag}.tar.xz)"
for d in adw-gtk3 adw-gtk3-dark; do
  if [[ -d "${adest}/${d}" ]]; then
    echo "  ok: harvested ${d}/ staged into the store"
  else
    echo "  FAIL: harvested ${d}/ not staged into the store" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
done

finish_test
