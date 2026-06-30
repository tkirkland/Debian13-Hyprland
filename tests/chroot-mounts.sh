#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: chroot mount tracking"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/target"

# shellcheck disable=SC2016  # fake bodies must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" mount 'echo "mount $*" >> "${FAKE_LOG}"'
# shellcheck disable=SC2016  # fake bodies must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" umount 'echo "umount $*" >> "${FAKE_LOG}"'
make_fake "${tmp}/bin" mountpoint 'exit 0'

export FAKE_LOG="${tmp}/calls.log"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  TARGET='${tmp}/target'
  mount_chroot_binds
  teardown_chroot_binds
" >/dev/null

calls="$(cat "${FAKE_LOG}")"
assert_contains "${calls}" "mount --bind /dev ${tmp}/target/dev" "binds /dev"
assert_contains "${calls}" "mount -t proc proc ${tmp}/target/proc" "mounts proc"

# Teardown must be reverse of setup: last umount is /dev (first mounted).
last_umount="$(grep '^umount' "${FAKE_LOG}" | tail -n1)"
assert_contains "${last_umount}" "${tmp}/target/dev" "reverse-order teardown"

# Default (installer) path binds the host /run.
assert_contains "${calls}" "mount --bind /run ${tmp}/target/run" "default binds host /run"

# Propagation must be isolated (target subtree made rslave) BEFORE any bind, or
# binding the shared host /run propagates back and shadows the live medium /
# offline store mounted under /run/live/medium. Guards against a silent revert.
assert_contains "${calls}" "mount --make-rslave ${tmp}/target" "isolates propagation before binds"
rslave_line="$(grep -n 'make-rslave' "${FAKE_LOG}" | head -n1 | cut -d: -f1)"
firstbind_line="$(grep -n -- '--bind' "${FAKE_LOG}" | head -n1 | cut -d: -f1)"
if [[ -n "${rslave_line}" && -n "${firstbind_line}" && "${rslave_line}" -lt "${firstbind_line}" ]]; then
  echo "  ok: make-rslave runs before the first bind"
else
  echo "  FAIL: make-rslave must run before the first bind-mount" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# HYPR_PRIVATE_RUN=1 (ISO builder) must use a fresh tmpfs /run, never the host
# bind, and must NOT bind host efivars. Guards against a future silent revert.
: >"${FAKE_LOG}"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  export HYPR_PRIVATE_RUN=1
  TARGET='${tmp}/target'
  mount_chroot_binds
" >/dev/null
pcalls="$(cat "${FAKE_LOG}")"
assert_contains "${pcalls}" "mount -t tmpfs tmpfs ${tmp}/target/run" "private /run is a tmpfs"
if [[ "${pcalls}" == *"mount --bind /run ${tmp}/target/run"* ]]; then
  echo "  FAIL: HYPR_PRIVATE_RUN still bind-mounts host /run" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: HYPR_PRIVATE_RUN does not bind host /run"
fi
if [[ "${pcalls}" == *efivars* ]]; then
  echo "  FAIL: HYPR_PRIVATE_RUN still binds host efivars" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: HYPR_PRIVATE_RUN does not bind host efivars"
fi

finish_test
