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

echo "test: setup_target_iso_repo refuses to bind a missing/incomplete offline store"
# On a resumed run (target already bootstrapped) run_debootstrap returns early
# and never calls cache_validate, so setup_target_iso_repo is the only guard
# against a vanished offline store (e.g. /run/live/medium unmounted after
# preflight). It must fail with an actionable message, not a raw bind-mount.
run_iso_repo() { # $1 = CACHE_REPO_DIR
  bash -c '
    set -euo pipefail
    calls="'"${tmp}"'/iso_calls"
    : >"${calls}"
    source scripts/30-bootstrap.sh
    # Stubs AFTER the source so they override functions defined in the script.
    info() { :; }
    warn() { :; }
    fatal() { echo "FATAL: $*"; exit 1; }
    mount() { echo "mount $*" >>"${calls}"; }   # stub: always "succeeds"
    mountpoint() { return 1; }                   # target mnt not yet mounted
    write_iso_temp_source() { echo "wrote_temp_source" >>"${calls}"; }
    TARGET="'"${tmp}"'/target"
    SUITE=trixie
    ARCH=amd64
    CACHE_REPO_DIR="'"$1"'"
    setup_target_iso_repo
    cat "${calls}"
  '
}

missing="${tmp}/nope-repo"
if out="$(run_iso_repo "${missing}" 2>&1)"; then
  echo "  FAIL: setup_target_iso_repo succeeded with a missing store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  assert_contains "${out}" "FATAL:" "missing store is fatal"
  assert_contains "${out}" "${missing}" "fatal names the missing store path"
  if printf '%s\n' "${out}" | grep -q "^mount "; then
    echo "  FAIL: attempted bind-mount despite missing store" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    echo "  ok: no bind-mount attempted when store is missing"
  fi
fi

good="${tmp}/good-repo"
mkdir -p "${good}/dists/trixie/main/binary-amd64"
: >"${good}/dists/trixie/main/binary-amd64/Packages"
out="$(run_iso_repo "${good}")"
assert_contains "${out}" "mount --bind ${good}" "valid store gets bind-mounted"
assert_contains "${out}" "wrote_temp_source" "valid store writes the temp source"

finish_test
