#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: waybar status bar (package + config)"

# --- package ----------------------------------------------------------------
config="$(<lib/00-config.sh)"
assert_contains "${config}" " waybar " "TARGET_BASE_PACKAGES includes waybar"
assert_contains "${config}" "fonts-font-awesome" \
  "icon font rides along (waybar only Suggests it)"

# --- staged config ----------------------------------------------------------
info() { :; }
warn() { :; }
in_target() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"
TARGET_USERNAME="tester"

stage_waybar_config

grep -q 'stage_waybar_config$' scripts/60-hyprland.sh \
  || { echo "  FAIL: stage_session_configs does not call stage_waybar_config" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

wb_dir="${TARGET}/home/${TARGET_USERNAME}/.config/waybar"
cfg="${wb_dir}/config.jsonc"
css="${wb_dir}/style.css"

[[ -f "${cfg}" ]] || { echo "  FAIL: config.jsonc not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -f "${css}" ]] || { echo "  FAIL: style.css not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

cfg_txt="$(<"${cfg}")"
css_txt="$(<"${css}")"

# The staged config is comment-free JSON so it stays machine-checkable.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${cfg}" \
    || { echo "  FAIL: config.jsonc is not valid JSON" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
fi
assert_contains "${cfg_txt}" '"hyprland/workspaces"' "workspaces module"
assert_contains "${cfg_txt}" '"hyprland/window"' "window title module"
assert_contains "${cfg_txt}" '"clock"' "clock module"
assert_contains "${cfg_txt}" '"tray"' "system tray module"
assert_contains "${cfg_txt}" '"wireplumber"' "volume module"
assert_contains "${cfg_txt}" '"network"' "network module"
assert_contains "${cfg_txt}" '"bluetooth"' "bluetooth module"
assert_contains "${cfg_txt}" '"battery"' "battery module"
assert_contains "${cfg_txt}" '"format-no-controller": ""' \
  "bluetooth hides without an adapter (does NOT self-hide by default)"

# style.css matches the installer palette (swaync precedent).
assert_contains "${css_txt}" '#1e1e2e' "dark bar background"
assert_contains "${css_txt}" '#f5f5f5' "light text"
assert_contains "${css_txt}" '#4a6f9a' "theme accent"
assert_contains "${css_txt}" 'Font Awesome 6 Free' "icon font in font stack"

finish_test
