#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: screenshot/recording capture helpers"

# --- packages ---------------------------------------------------------------
# The capture helpers need jq (monitor-mode geometry), notify-send (libnotify-bin),
# and ffmpeg (codecs) on top of the already-present grim/slurp/wf-recorder/swappy.
config="$(<lib/00-config.sh)"
for pkg in grim slurp wf-recorder swappy wl-clipboard jq libnotify-bin ffmpeg; do
  assert_contains "${config}" "${pkg}" \
    "TARGET_BASE_PACKAGES includes ${pkg}"
done

finish_test
