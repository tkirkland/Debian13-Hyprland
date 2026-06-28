#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: mount_target_tree propagation isolation + idempotency"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Stub harness: record every storage command. FSTYPE is what `findmnt -no FSTYPE
# ${TARGET}` reports (empty = nothing mounted yet, "zfs" = root dataset already
# mounted on a resume). MOUNTED toggles whether `mountpoint` says paths are
# mounted (drives the self-bind guard and the ESP guard).
run_mount() { # $1 = FSTYPE of ${TARGET}; $2 = 1 if mountpoint says "mounted"
  bash -c '
    set -euo pipefail
    FSTYPE='"'$1'"'
    MOUNTED='"$2"'
    calls="'"${tmp}"'/calls"
    : >"${calls}"
    info() { :; }
    warn() { :; }
    fatal() { echo "FATAL: $*" >&2; exit 1; }
    zpool() { return 0; } # pool already imported
    zfs() { echo "zfs $*" >>"${calls}"; }
    mount() { echo "mount $*" >>"${calls}"; }
    mountpoint() { ((MOUNTED)); }
    findmnt() { printf "%s\n" "${FSTYPE}"; }
    source scripts/30-bootstrap.sh
    TARGET="'"${tmp}"'/target"
    POOL_NAME=TESTPOOL
    ROOT_DATASET=TESTPOOL/ROOT/test
    ESP_MOUNT=/boot/efi
    mount_target_tree
    cat "${calls}"
  '
}

# --- Fresh run: nothing mounted yet (FSTYPE empty, mountpoint says no) --------
out="$(run_mount "" 0)"
assert_contains "${out}" "mount --bind ${tmp}/target ${tmp}/target" \
  "self-binds the target for propagation isolation"
assert_contains "${out}" "mount --make-private ${tmp}/target" \
  "makes the target a private mount subtree"
assert_contains "${out}" "zfs mount TESTPOOL/ROOT/test" \
  "unmounted root dataset gets mounted"
assert_contains "${out}" "zfs mount -a" "child datasets mounted"
assert_contains "${out}" "mount /dev/md/efi" "unmounted ESP gets mounted"
# make-private MUST precede the root-dataset mount, or the dataset propagates
# into systemd service namespaces before isolation takes effect.
priv_line="$(printf '%s\n' "${out}" | grep -n 'make-private' | head -n1 | cut -d: -f1)"
root_line="$(printf '%s\n' "${out}" | grep -n 'zfs mount TESTPOOL/ROOT/test' | head -n1 | cut -d: -f1)"
if [[ -n "${priv_line}" && -n "${root_line}" && "${priv_line}" -lt "${root_line}" ]]; then
  echo "  ok: make-private runs before the root dataset mounts"
else
  echo "  FAIL: make-private must run before the root dataset mounts" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- Resume: root dataset already a ZFS mount (FSTYPE=zfs, mountpoint says yes)
out="$(run_mount "zfs" 1)"
if printf '%s\n' "${out}" | grep -q "zfs mount TESTPOOL/ROOT/test"; then
  echo "  FAIL: root dataset re-mounted although already a zfs mount" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: already-mounted root dataset is not re-mounted"
fi
if printf '%s\n' "${out}" | grep -qE 'make-private|--bind'; then
  echo "  FAIL: re-isolated an already-mounted target" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no re-isolation when the target is already a zfs mount"
fi
if printf '%s\n' "${out}" | grep -q "mount /dev/md/efi"; then
  echo "  FAIL: ESP re-mounted although already mounted" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: already-mounted ESP is not re-mounted"
fi
assert_contains "${out}" "zfs mount -a" \
  "zfs mount -a still runs (natively idempotent)"

finish_test
