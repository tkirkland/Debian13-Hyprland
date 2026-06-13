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

# Quiet-mode console split (issue: install noise). setup_logging routes
# the raw stream to the log only; info/console/warn mirror to the real
# console via fds 3/4.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
console_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  echo "raw firehose line"
  info "visible status"
  console "visible banner"
  warn "visible warning"
' _ "${tmp}" 2>&1)"
assert_contains "${console_out}" "[INFO] visible status" \
  "info mirrors to the console in quiet mode"
assert_contains "${console_out}" "visible banner" \
  "console() lines reach the console in quiet mode"
assert_contains "${console_out}" "[WARN] visible warning" \
  "warn mirrors to the console in quiet mode"
if printf '%s' "${console_out}" | grep -q "raw firehose line"; then
  echo "  FAIL: raw command output must not reach the console" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: raw command output stays off the console"
fi
log_file="$(ls "${tmp}"/hypr-deb-*.log)"
log_body="$(<"${log_file}")"
assert_contains "${log_body}" "raw firehose line" \
  "raw command output captured in the log"
assert_contains "${log_body}" "[INFO] visible status" \
  "status lines captured in the log too"

# prompt(): text on the console, answer into REPLY, both in the log.
prompt_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  prompt "Pick: " <<<"42"
  info "answer=${REPLY}"
' _ "${tmp}" 2>&1)"
assert_contains "${prompt_out}" "Pick: " "prompt text reaches the console"
assert_contains "${prompt_out}" "answer=42" "prompt fills REPLY"

# with_console(): command output reattached to the console, not the log.
wc_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  with_console echo "interactive dialog"
' _ "${tmp}" 2>&1)"
assert_contains "${wc_out}" "interactive dialog" \
  "with_console reattaches the real console"

# run_step: spinner wrapper for long commands.
out="$(bash -c '
  VERBOSE=0; CONSOLE_READY=0; LOG_FILE=""
  source lib/01-log.sh
  run_step "plain" echo "ran-directly"')"
assert_contains "${out}" "ran-directly" \
  "run_step executes directly without a console"

assert_fails "run_step propagates the exit code (no console)" bash -c '
  VERBOSE=0; LOG_FILE=""
  source lib/01-log.sh
  run_step "boom" bash -c "exit 3"'

step_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  run_step "quick step" bash -c "echo step-output; exit 0"
' _ "${tmp}" 2>&1)"
assert_contains "${step_out}" "quick step — done" \
  "run_step reports completion with elapsed time"

fail_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  run_step "bad step" bash -c "echo failing; exit 7" || console "rc=$?"
' _ "${tmp}" 2>&1)"
assert_contains "${fail_out}" "bad step — FAILED" "run_step reports failure"
assert_contains "${fail_out}" "rc=7" "run_step propagates the exit code"

# Best-effort percentage: ninja-style [n/m] markers in the log tail are
# rendered as a percent while the step runs.
pct_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  run_step "compile" bash -c "echo \"[5/10] Compiling thing.cpp\"; sleep 1.3"
' _ "${tmp}" 2>&1)"
assert_contains "${pct_out}" "50%" \
  "run_step parses [n/m] progress into a percentage"

finish_test
