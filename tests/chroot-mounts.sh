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

finish_test
