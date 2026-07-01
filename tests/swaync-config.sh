#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: swaync notification daemon (config + keybinds)"

# --- package ----------------------------------------------------------------
config="$(<lib/00-config.sh)"
assert_contains "${config}" "sway-notification-center" \
  "TARGET_BASE_PACKAGES includes sway-notification-center"

finish_test
