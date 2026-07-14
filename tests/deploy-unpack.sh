#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: deploy phase (golden rootfs location + unpack, issue #111)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- locate_live_squashfs -----------------------------------------------------
run_locate() { # $1=LIVE_MEDIUM_DIR, $2=LIVE_SQUASHFS override (may be empty)
  bash -c '
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    warn() { :; }
    LIVE_MEDIUM_DIR="$1" LIVE_SQUASHFS="$2" locate_live_squashfs
  ' _ "$1" "${2:-}"
}

med="${tmp}/medium"
mkdir -p "${med}/live"

# Standard stock name wins.
: >"${med}/live/filesystem.squashfs"
out="$(run_locate "${med}")"
assert_eq "${med}/live/filesystem.squashfs" "${out}" \
  "standard /live/filesystem.squashfs is found"

# A single renamed squashfs is tolerated (layout drift across point releases).
rm "${med}/live/filesystem.squashfs"
: >"${med}/live/rootfs-13.5.squashfs"
out="$(run_locate "${med}")"
assert_eq "${med}/live/rootfs-13.5.squashfs" "${out}" \
  "a single renamed squashfs is accepted"

# Two squashfs with no standard name = ambiguous -> refuse to guess.
: >"${med}/live/other.squashfs"
assert_fails "two non-standard squashfs are ambiguous" run_locate "${med}"

# Nothing there -> failure.
assert_fails "empty live dir fails" run_locate "${tmp}/nowhere"

# Explicit LIVE_SQUASHFS override wins over the medium.
ovr="${tmp}/custom.squashfs"
: >"${ovr}"
out="$(run_locate "${med}" "${ovr}")"
assert_eq "${ovr}" "${out}" "LIVE_SQUASHFS override wins"
assert_fails "missing LIVE_SQUASHFS override fails loudly" \
  run_locate "${med}" "${tmp}/gone.squashfs"

# --- unpack_golden_rootfs -------------------------------------------------------
# Fake unsquashfs; assert the sanity gate on the unpacked tree.
run_unpack() { # $1=target dir, $2=unsquashfs body
  bash -c '
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    info() { :; }
    fatal() { echo "FATAL: $*" >&2; exit 1; }
    unsquashfs() { '"$2"'; }
    LIVE_SQUASHFS="'"${ovr}"'"
    TARGET="$1"
    unpack_golden_rootfs
  ' _ "$1"
}

good_tgt="${tmp}/target-good"
mkdir -p "${good_tgt}"
# shellcheck disable=SC2016  # the fake-unsquashfs bodies expand inside run_unpack
if run_unpack "${good_tgt}" '
  mkdir -p "${TARGET}/etc" "${TARGET}/usr/bin"
  echo 13.1 >"${TARGET}/etc/debian_version"
  install -m755 /dev/null "${TARGET}/usr/bin/Hyprland"' >/dev/null; then
  echo "  ok: unpack succeeds when the tree is a golden image"
else
  echo "  FAIL: unpack of a complete golden tree must succeed" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

bad_tgt="${tmp}/target-bad"
mkdir -p "${bad_tgt}"
# shellcheck disable=SC2016  # the fake-unsquashfs body expands inside run_unpack
if out="$(run_unpack "${bad_tgt}" 'mkdir -p "${TARGET}/etc"' 2>&1)"; then
  echo "  FAIL: unpack must fail when the tree lacks the golden markers" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  assert_contains "${out}" "not the golden image" \
    "incomplete unpack fails the sanity gate"
fi

# --- phase_deploy wiring --------------------------------------------------------
# The install runs STORE-ONLY: the image's baked mirror sources must be
# removed after unpack (issue #110 lesson), the store validated BEFORE the
# unpack, and the temporary file:// store source wired afterwards.
body="$(bash -c 'source lib/01-log.sh; source scripts/30-bootstrap.sh
  declare -f phase_deploy')"
assert_contains "${body}" "cache_validate" "deploy gates on the install store"
assert_contains "${body}" "unpack_golden_rootfs" "deploy unpacks the golden rootfs"
# shellcheck disable=SC2016  # the needle is a literal source-code snippet
assert_contains "${body}" 'rm -f "${TARGET}/etc/apt/sources.list.d/debian.sources"' \
  "deploy removes the baked mirror sources (store-only until cleanup)"
assert_contains "${body}" "setup_target_iso_repo" "deploy wires the medium store"
val_line="$(printf '%s\n' "${body}" | grep -n 'cache_validate' | cut -d: -f1 | head -n1)"
unp_line="$(printf '%s\n' "${body}" | grep -n 'unpack_golden_rootfs' | cut -d: -f1 | head -n1)"
if ((val_line < unp_line)); then
  echo "  ok: store validated before the (long) unpack"
else
  echo "  FAIL: cache_validate must run before unpack_golden_rootfs" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
