#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: mount_target_tree idempotency (resume after ensure_target_ready)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Stub harness: record every storage command; MOUNTED toggles whether the
# tree (and ESP) look mounted already.
run_mount() { # $1 = 1 if everything is already mounted, 0 if nothing is
  bash -c '
    set -euo pipefail
    MOUNTED='"$1"'
    calls="'"${tmp}"'/calls"
    : >"${calls}"
    info() { :; }
    fatal() { echo "FATAL: $*" >&2; exit 1; }
    zpool() { return 0; } # pool already imported
    zfs() { echo "zfs $*" >>"${calls}"; }
    mount() { echo "mount $*" >>"${calls}"; }
    mountpoint() { ((MOUNTED)); }
    source scripts/30-bootstrap.sh
    TARGET="'"${tmp}"'/target"
    POOL_NAME=TESTPOOL
    ROOT_DATASET=TESTPOOL/ROOT/test
    ESP_MOUNT=/boot/efi
    mount_target_tree
    cat "${calls}"
  '
}

out="$(run_mount 1)"
if printf '%s\n' "${out}" | grep -q "zfs mount TESTPOOL/ROOT/test"; then
  echo "  FAIL: root dataset re-mounted although already mounted" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: already-mounted root dataset is not re-mounted"
fi
if printf '%s\n' "${out}" | grep -q "mount /dev/md/efi"; then
  echo "  FAIL: ESP re-mounted although already mounted" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: already-mounted ESP is not re-mounted"
fi
assert_contains "${out}" "zfs mount -a" \
  "zfs mount -a still runs (natively idempotent)"

out="$(run_mount 0)"
assert_contains "${out}" "zfs mount TESTPOOL/ROOT/test" \
  "unmounted root dataset gets mounted"
assert_contains "${out}" "mount /dev/md/efi" \
  "unmounted ESP gets mounted"

finish_test
