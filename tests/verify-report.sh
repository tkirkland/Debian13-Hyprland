#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: verify check runner"
# 2>&1: warn() writes FAIL/summary lines to stderr; merge so we can assert.
out="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/90-verify.sh
  vcheck "always passes" true
  vcheck "always fails" false
  verify_report || true' 2>&1)"
assert_contains "${out}" "PASS: always passes" "pass line"
assert_contains "${out}" "FAIL: always fails" "fail line"
assert_contains "${out}" "1 of 2 checks failed" "summary"

assert_fails "verify_report exits nonzero on failure" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/90-verify.sh
  vcheck "f" false
  verify_report'

finish_test
