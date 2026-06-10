#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: orchestrator wiring"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

out="$(bash hypr-deb.sh --help)"
assert_contains "${out}" "Usage: hypr-deb.sh" "--help prints usage"
assert_contains "${out}" "--bootloader" "--help lists bootloader flag"

assert_fails "unknown flag fails" bash hypr-deb.sh --bogus

# Non-root full run must fail in preflight, not crash on sourcing.
# STATE_DIR/LOG_DIR point into tmp so the dev machine stays clean.
out="$(STATE_DIR="${tmp}/state" LOG_DIR="${tmp}/logs" \
  bash hypr-deb.sh --yes --bootloader=grub 2>&1 || true)"
assert_contains "${out}" "Must run as root" "root check reached"

# Every phase function referenced by the dispatcher must exist.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  source lib/03-state.sh; source lib/04-chroot-mounts.sh
  for f in scripts/*.sh; do source "$f"; done
  for fn in phase_preflight phase_cache phase_storage phase_bootstrap \
            phase_system phase_boot phase_hyprland phase_verify \
            phase_cleanup ensure_target_ready; do
    declare -f "$fn" >/dev/null || { echo "MISSING $fn"; exit 1; }
  done
  echo all-present')"
assert_eq "all-present" "${out}" "all phase functions defined"

# ensure_target_ready is a no-op when bootstrap is not stamped: it must
# return 0 and print nothing (resume helper only acts after bootstrap).
out="$(STATE_DIR="$(mktemp -d)" bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source lib/03-state.sh; source lib/04-chroot-mounts.sh
  source scripts/30-bootstrap.sh
  ensure_target_ready')"
assert_eq "" "${out}" "ensure_target_ready no-op without bootstrap stamp"

finish_test
