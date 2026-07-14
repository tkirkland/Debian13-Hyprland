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

# --- staged helper scripts --------------------------------------------------
info() { :; }
warn() { :; }
fatal() {
  printf 'fatal: %s\n' "$*" >&2
  return 1
}
in_target() { :; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"

stage_capture_helpers

shot="${TARGET}/usr/bin/linux-screenshot"
rec="${TARGET}/usr/bin/linux-screen-record"

[[ -x "${shot}" ]] || { echo "  FAIL: linux-screenshot not staged executable" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -x "${rec}"  ]] || { echo "  FAIL: linux-screen-record not staged executable" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

shot_txt="$(<"${shot}")"
rec_txt="$(<"${rec}")"

# Screenshot: saves a timestamped PNG under Pictures/Screenshots, holds an
# atomic lock so key-mashing can't stack selectors, copies to clipboard.
assert_contains "${shot_txt}" 'Pictures"}/Screenshots' \
  "linux-screenshot saves under Pictures/Screenshots"
assert_contains "${shot_txt}" 'linux-screenshot.lock' \
  "linux-screenshot uses the atomic selector lock"
assert_contains "${shot_txt}" 'wl-copy --type image/png' \
  "linux-screenshot copies the capture to the clipboard"

# Recording: timestamped .mkv, software codec default (portable), NVENC opt-in.
assert_contains "${rec_txt}" 'Screen Recordings' \
  "linux-screen-record saves under Videos/Screen Recordings"
# shellcheck disable=SC2016  # the needle is a literal source-code snippet
assert_contains "${rec_txt}" 'screen_recording_$timestamp.mkv' \
  "linux-screen-record writes a crash-safe .mkv"
assert_contains "${rec_txt}" 'SCREEN_RECORD_CODEC:-libx264' \
  "linux-screen-record defaults to the portable libx264 codec (no NVIDIA)"

# NVIDIA path: when a driver is selected at install time, the staged helper's
# default codec flips to h264_nvenc (nvidia_install_requested true). Same
# SCREEN_RECORD_CODEC override still applies.
nv_tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}" "${nv_tmp}"' EXIT
(
  TARGET="${nv_tmp}/target"
  HAS_NVIDIA_GPU=1
  NVIDIA_DRIVER="nvidia-open"
  stage_capture_helpers
)
nv_rec_txt="$(<"${nv_tmp}/target/usr/bin/linux-screen-record")"
assert_contains "${nv_rec_txt}" 'SCREEN_RECORD_CODEC:-h264_nvenc' \
  "linux-screen-record defaults to h264_nvenc when NVIDIA driver selected"
if printf '%s' "${nv_rec_txt}" | grep -q 'SCREEN_RECORD_CODEC:-libx264'; then
  echo "  FAIL: NVIDIA helper still carries the libx264 default" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
