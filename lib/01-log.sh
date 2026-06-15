# bashsupport disable=BP5007
# shellcheck shell=bash
# Logging helpers. Sourced by installer.sh; VERBOSE comes from lib/00-config.sh.

# Quiet mode sends the raw command stream to LOG_FILE while fds 3/4 remain
# attached to the operator's console. Installation commands stay in the
# foreground; only the renderer below is a background process.
CONSOLE_READY="${CONSOLE_READY:-0}"
CONSOLE_MODE="${CONSOLE_MODE:-direct}"
ACTIVITY_ACTIVE="${ACTIVITY_ACTIVE:-0}"
ACTIVITY_PAUSED="${ACTIVITY_PAUSED:-0}"
ACTIVITY_LABEL="${ACTIVITY_LABEL:-}"
ACTIVITY_PID="${ACTIVITY_PID:-}"

info() {
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]] &&
    ((!ACTIVITY_ACTIVE)); then
    printf '[INFO] %s\n' "$*" >&3 || true
  fi
  printf '[INFO] %s\n' "$*" || true
}

warn() {
  local resume=0
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]] &&
    ((ACTIVITY_ACTIVE)) && ((!ACTIVITY_PAUSED)); then
    activity_pause
    resume=1
  fi
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    printf '[WARN] %s\n' "$*" >&4 || true
  fi
  printf '[WARN] %s\n' "$*" >&2 || true
  ((resume)) && activity_resume
  return 0
}

verbose() {
  ((VERBOSE)) || return 0
  printf '[VERB] %s\n' "$*" || true
}

fatal() {
  activity_abort
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    printf '[FATAL] %s\n' "$*" >&4 || true
    [[ -n "${LOG_FILE}" ]] && printf 'Full log: %s\n' "${LOG_FILE}" >&4 || true
  fi
  printf '[FATAL] %s\n' "$*" >&2 || true
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

# Text that must reach the operator as well as the log.
console() {
  local resume=0
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]] &&
    ((ACTIVITY_ACTIVE)) && ((!ACTIVITY_PAUSED)); then
    activity_pause
    resume=1
  fi
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    printf '%s\n' "$*" >&3 || true
  fi
  printf '%s\n' "$*" || true
  ((resume)) && activity_resume
  return 0
}

# Inline non-secret prompt. stdin remains attached to the terminal in quiet
# mode; only stdout/stderr are redirected to the log.
prompt() {
  local resume=0
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]] &&
    ((ACTIVITY_ACTIVE)) && ((!ACTIVITY_PAUSED)); then
    activity_pause
    resume=1
  fi
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    printf '%s' "$1" >&3 || true
  fi
  printf '%s' "$1" || true
  if ! IFS= read -r REPLY; then
    ((resume)) && activity_resume
    return 1
  fi
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    printf '%s\n' "${REPLY}" || true
  fi
  ((resume)) && activity_resume
  return 0
}

# Password dialogs and similar interactive programs must use the real
# console. Their output is intentionally not copied into the install log.
with_console() {
  local rc=0 resume=0
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]] &&
    ((ACTIVITY_ACTIVE)) && ((!ACTIVITY_PAUSED)); then
    activity_pause
    resume=1
  fi
  if ((CONSOLE_READY)) && [[ "${CONSOLE_MODE}" != "verbose" ]]; then
    "$@" >&3 2>&4 || rc=$?
  else
    "$@" || rc=$?
  fi
  ((resume)) && activity_resume
  return "${rc}"
}

_activity_spawn_renderer() {
  (
    local frames=$'|/-\\' frame=0
    trap 'exit 0' HUP INT TERM
    while true; do
      printf '\r\033[K[%s] %s' "${frames:frame:1}" "${ACTIVITY_LABEL}" >&3
      frame=$(((frame + 1) % 4))
      sleep 0.1
    done
  ) &
  ACTIVITY_PID=$!
}

activity_start() {
  local label="$1"
  activity_abort
  ACTIVITY_ACTIVE=1
  ACTIVITY_PAUSED=0
  ACTIVITY_LABEL="${label}"
  printf '[INFO] %s\n' "${label}" || true
  case "${CONSOLE_MODE}" in
    tty) _activity_spawn_renderer ;;
    plain) printf '[INFO] %s\n' "${label}" >&3 || true ;;
  esac
}

activity_pause() {
  ((ACTIVITY_ACTIVE)) || return 0
  if [[ -n "${ACTIVITY_PID}" ]]; then
    kill "${ACTIVITY_PID}" 2>/dev/null || true
    wait "${ACTIVITY_PID}" 2>/dev/null || true
    ACTIVITY_PID=""
  fi
  if [[ "${CONSOLE_MODE}" == "tty" ]]; then
    printf '\r\033[K' >&3 || true
  fi
  ACTIVITY_PAUSED=1
}

activity_resume() {
  ((ACTIVITY_ACTIVE)) || return 0
  ((ACTIVITY_PAUSED)) || return 0
  ACTIVITY_PAUSED=0
  if [[ "${CONSOLE_MODE}" == "tty" ]]; then
    _activity_spawn_renderer
  fi
  return 0
}

activity_success() {
  ((ACTIVITY_ACTIVE)) || return 0
  activity_pause
  case "${CONSOLE_MODE}" in
    tty)
      printf '\r\033[K[OK] %s\n' "${ACTIVITY_LABEL}" >&3 || true
      printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" || true
      ;;
    plain)
      printf '[OK] %s\n' "${ACTIVITY_LABEL}" >&3 || true
      printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" || true
      ;;
    verbose | direct) printf '[OK] %s\n' "${ACTIVITY_LABEL}" || true ;;
  esac
  ACTIVITY_ACTIVE=0
  ACTIVITY_PAUSED=0
  ACTIVITY_LABEL=""
}

activity_abort() {
  ((ACTIVITY_ACTIVE)) || return 0
  activity_pause
  ACTIVITY_ACTIVE=0
  ACTIVITY_PAUSED=0
  ACTIVITY_LABEL=""
}

# Route all further output into a timestamped log file under $1. Quiet mode
# keeps the original console on fds 3/4; --verbose retains tee behavior.
setup_logging() {
  local dir="$1" ts=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dir}"
  LOG_FILE="${dir}/hypr-deb-${ts}.log"
  : >>"${LOG_FILE}" ||
    fatal "Cannot create install log at ${LOG_FILE}."
  exec 3>&1 4>&2
  CONSOLE_READY=1
  if ((VERBOSE)); then
    CONSOLE_MODE="verbose"
    exec > >(tee -a "${LOG_FILE}") 2>&1
  else
    if [[ -t 3 && "${TERM:-dumb}" != "dumb" ]]; then
      CONSOLE_MODE="tty"
    else
      CONSOLE_MODE="plain"
    fi
    exec >>"${LOG_FILE}" 2>&1
  fi
  info "Logging to ${LOG_FILE}"
}
