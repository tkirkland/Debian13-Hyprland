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
# Stateful mountpoint fake: the target ROOT is always "mounted" (so make-rslave
# fires), every submount is "mounted" iff the FAKE_LOG records a still-live mount
# for that exact path (mounts minus umounts). This faithfully models the new
# mountpoint-guarded, idempotent mount_chroot_binds without any real mounts.
# shellcheck disable=SC2016  # fake body stays literal until run under PATH
make_fake "${tmp}/bin" mountpoint '
  p="${@: -1}"
  [[ "${p}" == "${FAKE_TARGET}" ]] && exit 0
  c="$(awk -v p="${p}" '\''$NF==p && $1=="mount"{c++} $NF==p && $1=="umount"{c--} END{print c+0}'\'' "${FAKE_LOG}" 2>/dev/null)"
  (( c > 0 )) && exit 0 || exit 1
'

export FAKE_LOG="${tmp}/calls.log"
export FAKE_TARGET="${tmp}/target"
: >"${FAKE_LOG}"
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

# --- Issue 1 (MOK): the installer path binds host efivars into the chroot so
# `chroot mokutil --import` can write the enrollment request to NVRAM. Point
# EFIVARS_DIR at a temp dir that EXISTS so the `-d` test passes host-independently.
efivars_src="${tmp}/efivars"
mkdir -p "${efivars_src}"
: >"${FAKE_LOG}"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  EFIVARS_DIR='${efivars_src}'
  TARGET='${tmp}/target'
  mount_chroot_binds
" >/dev/null
ecalls="$(cat "${FAKE_LOG}")"
assert_contains "${ecalls}" "mount --bind ${efivars_src} ${tmp}/target${efivars_src}" \
  "installer binds host efivars into the chroot (so mokutil --import sees NVRAM)"

# --- Idempotency / no stacking: a SECOND mount_chroot_binds call in the same
# process must emit NO duplicate mounts (the mountpoint guards see them live in
# the log). A duplicate `mount -t sysfs` would shadow the efivars bind and break
# mokutil --import — the exact failure mode the guards prevent.
: >"${FAKE_LOG}"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  EFIVARS_DIR='${efivars_src}'
  TARGET='${tmp}/target'
  mount_chroot_binds   # populates the log (all mounts live)
  mount_chroot_binds   # idempotent re-run: must add nothing
" >/dev/null
sysfs_n="$(grep -c -- 'mount -t sysfs sysfs' "${FAKE_LOG}" || true)"
efivars_n="$(grep -c -- "mount --bind ${efivars_src} " "${FAKE_LOG}" || true)"
assert_eq "1" "${sysfs_n}" "re-run does not stack a second sysfs over /sys"
assert_eq "1" "${efivars_n}" "re-run does not re-bind efivars (no shadowing)"

# --- Regression for the TRUE root cause: ensure_target_ready must ensure the
# binds (esp. efivars) EVEN WHEN ${TARGET}/proc is already mounted. The old
# `mountpoint -q ${TARGET}/proc || mount_chroot_binds` gate skipped them, leaving
# the chroot without efivars on standalone --phase=boot and resumed runs.
: >"${FAKE_LOG}"
# Pre-seed the log so the fake reports ${TARGET}/proc already mounted.
echo "mount -t proc proc ${tmp}/target/proc" >>"${FAKE_LOG}"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  source scripts/30-bootstrap.sh
  EFIVARS_DIR='${efivars_src}'
  TARGET='${tmp}/target'
  # Stub the zfs/ESP machinery ensure_target_ready runs before the binds.
  zpool() { return 0; }
  zfs() { return 0; }
  findmnt() { echo zfs; }
  ensure_target_ready
" >/dev/null 2>&1
gcalls="$(cat "${FAKE_LOG}")"
assert_contains "${gcalls}" "mount --bind ${efivars_src} ${tmp}/target${efivars_src}" \
  "ensure_target_ready binds efivars even when /proc is already mounted"

# HYPR_PRIVATE_RUN=1 (ISO builder) must use a fresh tmpfs /run, never the host
# bind, and must NOT bind host efivars. Guards against a future silent revert.
: >"${FAKE_LOG}"
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  export HYPR_PRIVATE_RUN=1
  EFIVARS_DIR='${efivars_src}'
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
