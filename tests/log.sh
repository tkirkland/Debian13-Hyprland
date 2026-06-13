#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh
source lib/01-log.sh

echo "test: logging helpers"

VERBOSE=0
out="$(info "hello")"
assert_eq "[INFO] hello" "${out}" "info format"

out="$(verbose "quiet" || true)"
assert_eq "" "${out}" "verbose suppressed when VERBOSE=0"

VERBOSE=1
out="$(verbose "loud")"
assert_eq "[VERB] loud" "${out}" "verbose emits when VERBOSE=1"

out="$( (warn "careful") 2>&1 )"
assert_eq "[WARN] careful" "${out}" "warn goes to stderr"

assert_fails "fatal exits nonzero" bash -c '
  source lib/01-log.sh; fatal "boom"'

out="$( (bash -c 'source lib/01-log.sh; fatal "boom"') 2>&1 || true )"
assert_contains "${out}" "[FATAL] boom" "fatal message"

finish_test
