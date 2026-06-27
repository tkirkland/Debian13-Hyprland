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
