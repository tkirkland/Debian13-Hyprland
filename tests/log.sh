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

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Quiet mode keeps the command stream in the log while status lines still
# reach the operator. The test runs without a TTY, so activity falls back to
# stable newline-delimited phase messages instead of terminal control codes.
console_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  echo "raw package-manager output"
  info "visible status"
  activity_start "Phase: system"
  activity_success
' _ "${tmp}" 2>&1 || true)"
assert_contains "${console_out}" "[INFO] visible status" \
  "quiet mode keeps explicit status visible"
assert_contains "${console_out}" "Phase: system" \
  "non-TTY activity uses stable phase lines"
if [[ "${console_out}" == *"raw package-manager output"* ]]; then
  echo "  FAIL: quiet mode leaked raw command output to the console" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: quiet mode hides raw command output"
fi
log_file="$(find "${tmp}" -maxdepth 1 -name 'hypr-deb-*.log' -print -quit)"
log_body="$(<"${log_file}")"
assert_contains "${log_body}" "raw package-manager output" \
  "quiet mode preserves raw command output in the log"
assert_contains "${log_body}" "[INFO] visible status" \
  "quiet mode preserves status lines in the log"

# A TTY renderer continuously overwrites one row. Two distinct frames prove
# that the indicator rotates; CR + erase-line proves it redraws in place.
spinner_console="${tmp}/spinner.console"
spinner_log="${tmp}/spinner.log"
if bash -c '
  VERBOSE=0
  LOG_FILE="$2"
  source lib/01-log.sh
  exec 3>"$1" 4>&3
  exec >>"$2" 2>&1
  CONSOLE_READY=1
  CONSOLE_MODE="tty"
  activity_start "Phase 5/6: hyprland"
  sleep 0.6
  renderer_pid="${ACTIVITY_PID}"
  kill -0 "${renderer_pid}"
  activity_success
  if kill -0 "${renderer_pid}" 2>/dev/null; then
    exit 9
  fi
' _ "${spinner_console}" "${spinner_log}"; then
  echo "  ok: TTY renderer stops after phase completion"
else
  echo "  FAIL: TTY renderer survived phase completion" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
spinner_body="$(<"${spinner_console}")"
assert_contains "${spinner_body}" $'\r\033[K[|] Phase 5/6: hyprland' \
  "TTY spinner clears and redraws the same row with the positioned label"
assert_contains "${spinner_body}" $'\r\033[K[/] Phase 5/6: hyprland' \
  "TTY spinner advances through animation frames"
assert_contains "${spinner_body}" "[INFO] Completed: Phase 5/6: hyprland" \
  "successful phase replaces the spinner with a stable result"

# A silent log past ACTIVITY_STALL_SECS flags a probable hang; growth clears
# the flag. The tail is prefixed "last:" so a tool's own completion banner
# ("Installation finished. No error reported.") reads as context, never as
# the installer finishing.
stall_console="${tmp}/stall.console"
stall_log="${tmp}/stall.log"
bash -c '
  VERBOSE=0
  LOG_FILE="$2"
  ACTIVITY_STALL_SECS=1
  source lib/01-log.sh
  exec 3>"$1" 4>&3
  exec >>"$2" 2>&1
  CONSOLE_READY=1
  CONSOLE_MODE="tty"
  activity_start "Phase 3/6: system"
  sleep 2.6
  cp "$1" "$1.stalled"
  echo "Installation finished. No error reported."
  sleep 1.6
  activity_success
' _ "${stall_console}" "${stall_log}"
stalled_body="$(<"${stall_console}.stalled")"
assert_contains "${stalled_body}" "(no output for " \
  "silent log past the threshold renders a stall marker"
whole_body="$(<"${stall_console}")"
after_growth="${whole_body:${#stalled_body}}"
recovered="$(printf '%s' "${after_growth}" | tr '\r' '\n' |
  grep -F 'last: Installation finished. No error reported.' |
  grep -cv 'no output for')" || recovered=0
if ((recovered > 0)); then
  echo "  ok: log growth clears the stall marker; tail stays 'last:'-prefixed"
else
  echo "  FAIL: stall marker persisted or 'last:' prefix missing after log growth" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# Pausing for a prompt or warning is also valid in non-TTY mode. Resuming
# must be a successful no-op rather than an errexit-triggering false result.
if bash -c '
  set -euo pipefail
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  exec 3>/dev/null 4>/dev/null
  CONSOLE_READY=1
  CONSOLE_MODE="plain"
  activity_start "Phase: preflight"
  activity_pause
  activity_resume
  activity_success
' >/dev/null 2>&1; then
  echo "  ok: non-TTY activity resumes successfully"
else
  echo "  FAIL: non-TTY activity resume triggered errexit" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# Verbose mode streams through tee and therefore needs exactly one phase
# start record, not a direct line plus a second mode-specific copy.
verbose_dir="${tmp}/verbose"
mkdir -p "${verbose_dir}"
verbose_out="$(bash -c '
  VERBOSE=1
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  activity_start "Phase: verify"
  activity_success
' _ "${verbose_dir}" 2>&1)"
phase_start_count="$(printf '%s\n' "${verbose_out}" |
  grep -c '^\[INFO\] === Phase: verify ===$' || true)"
assert_eq "1" "${phase_start_count}" \
  "verbose mode prints one phase start line"
phase_record_count="$(printf '%s\n' "${verbose_out}" |
  grep -c 'Phase: verify' || true)"
assert_eq "2" "${phase_record_count}" \
  "verbose mode prints one start and one completion record"

# The phase itself remains a normal foreground command under errexit. A
# failure must skip the following statement and EXIT cleanup must erase the
# live spinner rather than leave a background renderer behind.
failure_out="$(bash -c '
  set -Eeuo pipefail
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  exec 3>&1 4>&2
  CONSOLE_READY=1
  CONSOLE_MODE="plain"
  trap activity_abort EXIT
  activity_start "Phase: storage"
  false
  echo "UNREACHABLE"
' 2>&1 || true)"
if [[ "${failure_out}" == *"UNREACHABLE"* ]]; then
  echo "  FAIL: phase failure did not preserve foreground errexit" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: phase failure preserves foreground errexit"
fi

# Interactive programs bypass quiet logging so their prompts remain usable.
dialog_out="$(bash -c '
  VERBOSE=0
  LOG_FILE=""
  source lib/01-log.sh
  setup_logging "$1"
  with_console echo "interactive dialog"
' _ "${tmp}" 2>&1 || true)"
assert_contains "${dialog_out}" "interactive dialog" \
  "interactive commands remain attached to the console"

finish_test
