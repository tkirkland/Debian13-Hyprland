#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: wdisplays display arranger (fork build + keybinds + window rule)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- stack membership --------------------------------------------------------
# Debian's wdisplays 1.1.1 renders broken (clipped) on Hyprland 0.55; the
# maintained artizirk fork (1.1.3) is fixed. It must be BUILT as a stack deb
# (version 1.1.3-1 naturally supersedes Debian's 1.1.1-1+b2, same package
# name), so it belongs in HYPR_BUILD_ORDER — and must NOT ride
# TARGET_BASE_PACKAGES (that would pull Debian's broken build).
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${HYPR_BUILD_ORDER[@]}"')"
if printf '%s\n' "${out}" | grep -qx 'wdisplays'; then
  echo "  ok: wdisplays is a HYPR_BUILD_ORDER member (source-built stack deb)"
else
  echo "  FAIL: wdisplays missing from HYPR_BUILD_ORDER" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
# The order must still end with uwsm (the #64 session-manager invariant).
assert_eq "uwsm" "$(printf '%s\n' "${out}" | tail -n1)" \
  "HYPR_BUILD_ORDER still ends with uwsm"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_REPO_URL[wdisplays]:-}"')"
assert_eq "https://github.com/artizirk/wdisplays" "${out}" \
  "wdisplays builds from the maintained artizirk fork"

out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${TARGET_BASE_PACKAGES[@]}"')"
if printf '%s\n' "${out}" | grep -qx 'wdisplays'; then
  echo "  FAIL: wdisplays must NOT be in TARGET_BASE_PACKAGES (Debian's is broken)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: wdisplays absent from TARGET_BASE_PACKAGES"
fi

# Build deps: GTK3 + epoxy (verified on the live machine: installing these
# does not touch the held stack — the stack debs' Provides satisfy the
# wayland/xkb dev chain).
out="$(bash -c 'source lib/00-config.sh
  printf "%s\n" "${HYPR_BUILD_PACKAGES[@]}"')"
assert_contains "${out}" "libgtk-3-dev" "GTK3 build-dep for wdisplays"
assert_contains "${out}" "libepoxy-dev" "epoxy build-dep for wdisplays"

# --- tag resolution ----------------------------------------------------------
# The fork tags UNPREFIXED ("1.1.3"); the default v?X.Y.Z pattern matches it,
# and wdisplays floats pin-free (no HYPR_TAG_PIN entry).
mkdir -p "${tmp}/bin"
make_fake "${tmp}/bin" git 'cat <<EOF
sha	refs/tags/1.1
sha	refs/tags/1.1.1
sha	refs/tags/1.1.2
sha	refs/tags/1.1.3
sha	refs/tags/nightly
EOF'
out="$(PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/60-hyprland.sh
  source scripts/lib-deb-package.sh
  resolve_component_tag wdisplays')"
assert_eq "1.1.3" "${out}" \
  "resolve_component_tag picks the fork's newest unprefixed release tag"
out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_TAG_PIN[wdisplays]:-unpinned}"')"
assert_eq "unpinned" "${out}" "wdisplays floats pin-free"

# --- keybinds + window rule --------------------------------------------------
info() { :; }
warn() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
in_target() { :; }
source scripts/60-hyprland.sh

TARGET="${tmp}/target"
TARGET_USERNAME="tester"
mkdir -p "${TARGET}${HYPR_SRC_DIR}/hyprland/example"
cat >"${TARGET}${HYPR_SRC_DIR}/hyprland/example/hyprland.lua" <<'EOF'
-- fake upstream example for tests

---------------------
---- MY PROGRAMS ----
---------------------
local mainMod = "SUPER"

------------------
---- KEYBINDS ----
------------------
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("kitty"))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))
EOF

write_hypr_lua_config

hypr_dir="${TARGET}/home/${TARGET_USERNAME}/.config/hypr"
binds="$(<"${hypr_dir}/keybinds.lua")"
assert_contains "${binds}" \
  'hl.bind(mainMod .. " + P", hl.dsp.exec_cmd("wdisplays"))' \
  "SUPER+P launches wdisplays"
assert_contains "${binds}" \
  'hl.bind(mainMod .. " + SHIFT + P", hl.dsp.window.pseudo())' \
  "pseudo rebind survives on SUPER+SHIFT+P"
if [[ "${binds}" == *'" + P", hl.dsp.window.pseudo())'* ]]; then
  echo "  FAIL: upstream pseudo bind still on bare SUPER+P" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: bare SUPER+P no longer binds pseudo"
fi
# Neighbouring binds must survive the sed untouched.
assert_contains "${binds}" 'hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))' \
  "adjacent keybinds untouched"

# Window rule: float + center (tiled/oversized wdisplays looks bad), and NO
# forced size — GTK3 min-size clipping (hard-learned on the reference machine).
deb="$(<"${hypr_dir}/hypr-deb.lua")"
assert_contains "${deb}" \
  'hl.window_rule({ name = "float-wdisplays", match = { class = "wdisplays" }, float = true, center = true })' \
  "wdisplays window rule floats + centers"
rule_line="$(grep 'float-wdisplays' "${hypr_dir}/hypr-deb.lua" || true)"
if [[ "${rule_line}" == *"size"* ]]; then
  echo "  FAIL: wdisplays rule must not force a size (GTK3 min-size clipping)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: wdisplays rule forces no size"
fi

finish_test
