# bashsupport disable=BP5007
# shellcheck shell=bash
# Logging helpers. Sourced by installer.sh; VERBOSE comes from lib/00-config.sh.
#
# Quiet-by-default console: setup_logging sends the full command stream
# (apt, debootstrap, compiles) to the log file ONLY, keeping fds 3/4
# attached to the real console. The helpers below mirror status lines and
# prompts there, so the user sees questions and [INFO]/[WARN]/[FATAL]
# updates while the log captures everything. --verbose tees the whole
# stream to the console like before.

# 1 once setup_logging has split console (fds 3/4) from the log. Until
# then — and in --verbose mode, where the console gets the full stream
# anyway — the helpers write only to stdout/stderr.
CONSOLE_READY=0

info() {
  printf '[INFO] %s\n' "$*"
  ((CONSOLE_READY)) && printf '[INFO] %s\n' "$*" >&3
  return 0
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
  ((CONSOLE_READY)) && printf '[WARN] %s\n' "$*" >&4
  return 0
}

verbose() {
  ((VERBOSE)) || return 0
  printf '[VERB] %s\n' "$*"
}

fatal() {
  printf '[FATAL] %s\n' "$*" >&2
  if ((CONSOLE_READY)); then
    printf '[FATAL] %s\n' "$*" >&4
    [[ -n "${LOG_FILE}" ]] && printf 'Full log: %s\n' "${LOG_FILE}" >&4
  fi
  exit 1
}

# Prefix each stdin line as an indented warn-level detail line (for
# embedding multi-line tool output in failure diagnostics).
warn_lines() {
  local line=""
  while IFS= read -r line; do
    warn "    ${line}"
  done
}

# Text the user must always see (menus, banners). Console and log both.
console() {
  printf '%s\n' "$*"
  ((CONSOLE_READY)) && printf '%s\n' "$*" >&3
  return 0
}

# Inline prompt: prints $1 (no newline) on the console, reads the answer
# into REPLY. Returns nonzero on EOF. The typed answer is recorded in the
# log (quiet mode only — never use this for passwords).
prompt() {
  printf '%s' "$1"
  ((CONSOLE_READY)) && printf '%s' "$1" >&3
  IFS= read -r REPLY || return 1
  ((CONSOLE_READY)) && printf '%s\n' "${REPLY}"
  return 0
}

# Run a command with the real console attached: interactive tools
# (passwd, mokutil) hold their dialog on stdout/stderr, which quiet
# logging would otherwise swallow. The dialog is intentionally NOT
# logged (it is where passwords are typed).
with_console() {
  if ((CONSOLE_READY)); then
    "$@" >&3 2>&4
  else
    "$@"
  fi
}

# Route all further output into a timestamped log file under $1; see the
# header comment for the console split. fds 3/4 stay aimed at the real
# console for the helpers above.
setup_logging() {
  local dir="$1" ts=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dir}"
  LOG_FILE="${dir}/hypr-deb-${ts}.log"
  if ((VERBOSE)); then
    exec > >(tee -a "${LOG_FILE}") 2>&1
  else
    exec 3>&1 4>&2 >>"${LOG_FILE}" 2>&1
    CONSOLE_READY=1
  fi
  info "Logging to ${LOG_FILE}"
}
