#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: phase state stamps"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

run_state() {
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source lib/03-state.sh
    STATE_DIR='${tmp}/state'
    $1
  "
}

out="$(run_state 'state_init 0; phase_done storage && echo yes || echo no')"
assert_contains "${out}" "no" "phase not done initially"

out="$(run_state 'state_init 0; mark_phase_done storage
  phase_done storage && echo yes || echo no')"
assert_contains "${out}" "yes" "phase done after mark"

out="$(run_state 'state_init 0; mark_phase_done storage; state_init 1
  phase_done storage && echo yes || echo no')"
assert_contains "${out}" "no" "--fresh wipes stamps"

# The label carries the phase's fixed-list position so a resumed run still
# reads "Phase 2/6" even when earlier phases were skipped.
out="$(run_state 'state_init 0; fake_phase() { :; }
  run_phase bootstrap fake_phase 2 6')"
assert_contains "${out}" "=== Phase 2/6: bootstrap ===" \
  "run_phase labels with position/total"
assert_contains "${out}" "Completed: Phase 2/6: bootstrap" \
  "completion line carries the positioned label"

finish_test
