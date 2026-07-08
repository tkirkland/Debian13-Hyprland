#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: installer failure traps release the target (incl. on-ISO repo)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# installer.sh without the final `main "$@"` call, so trap handlers can be
# invoked directly (same pattern as tests/orchestrator.sh).
sed -e "s|^BASEDIR=.*|BASEDIR=\"${PWD}\"|" -e '/^main "\$@"$/d' \
  installer.sh >"${tmp}/installer-no-main.sh"

# on_error (ERR trap) must release the target through the SAME teardown as
# cleanup/standalone runs — teardown_target_tree includes the on-ISO repo
# teardown a failed offline phase would otherwise leak (stale
# hypr-iso-temp.sources on the installed system).
log="${tmp}/on-error.log"
# shellcheck disable=SC2016  # inner script expands in the child bash, not here
assert_fails "on_error exits nonzero" bash -c '
  source "$1"
  LOG="$2"
  activity_abort() { :; }
  report_disk_holders() { :; }
  teardown_target_tree() { echo teardown_target_tree >>"${LOG}"; }
  set +e
  false
  on_error
' _ "${tmp}/installer-no-main.sh" "${log}"
assert_contains "$(cat "${log}" 2>/dev/null || true)" "teardown_target_tree" \
  "on_error releases the target via teardown_target_tree"

# on_exit (EXIT trap — the fatal() path, which never trips ERR) must remove
# the temporary on-ISO repo wiring, and must do so BEFORE unmounting the
# chroot binds the repo is bound under.
log="${tmp}/on-exit.log"
bash -c '
  source "$1"
  LOG="$2"
  activity_abort() { :; }
  teardown_target_iso_repo() { echo teardown_target_iso_repo >>"${LOG}"; }
  teardown_chroot_binds() { echo teardown_chroot_binds >>"${LOG}"; }
  set +e
  false
  on_exit
' _ "${tmp}/installer-no-main.sh" "${log}" >/dev/null 2>&1 || true
assert_eq "teardown_target_iso_repo
teardown_chroot_binds" "$(cat "${log}" 2>/dev/null || true)" \
  "on_exit tears the iso repo down before the binds (nonzero exit)"

finish_test
