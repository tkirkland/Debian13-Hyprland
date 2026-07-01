#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: swaync notification daemon (config + keybinds)"

# --- package ----------------------------------------------------------------
config="$(<lib/00-config.sh)"
assert_contains "${config}" "sway-notification-center" \
  "TARGET_BASE_PACKAGES includes sway-notification-center"

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

stage_swaync_config

sw_dir="${TARGET}/home/${TARGET_USERNAME}/.config/swaync"
cfg="${sw_dir}/config.json"
css="${sw_dir}/style.css"

[[ -f "${cfg}" ]] || { echo "  FAIL: config.json not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -f "${css}" ]] || { echo "  FAIL: style.css not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

cfg_txt="$(<"${cfg}")"
css_txt="$(<"${css}")"

# config.json is valid JSON and carries the load-bearing settings.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${cfg}" \
    || { echo "  FAIL: config.json is not valid JSON" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
fi
assert_contains "${cfg_txt}" '"positionX": "right"' "toasts anchored right"
assert_contains "${cfg_txt}" '"positionY": "bottom"' "toasts anchored bottom"
assert_contains "${cfg_txt}" '"timeout": 5' "5s default timeout"
assert_contains "${cfg_txt}" '"timeout-critical": 0' "criticals persist"
assert_contains "${cfg_txt}" '"notification-window-width": 400' "400px toast width"
assert_contains "${cfg_txt}" '"mpris"' "mpris widget present"

# style.css matches the installer window accent (gradient) + palette.
assert_contains "${css_txt}" '#1e1e2e' "dark card background"
assert_contains "${css_txt}" '#f5f5f5' "light text"
assert_contains "${css_txt}" '#33ccff' "installer accent gradient start"
assert_contains "${css_txt}" '#00ff99' "installer accent gradient end"
assert_contains "${css_txt}" 'background-clip: padding-box, border-box' \
  "gradient-border via background-clip double background"

finish_test
