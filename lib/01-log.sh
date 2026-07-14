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
ACTIVITY_START="${ACTIVITY_START:-0}"
# Seconds of log silence before the spinner flags a probable hang.
ACTIVITY_STALL_SECS="${ACTIVITY_STALL_SECS:-30}"

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
    if [[ -n "${LOG_FILE}" ]]; then printf 'Full log: %s\n' "${LOG_FILE}" >&4 || true; fi
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

# Background spinner for tty mode. Beyond proving liveness it surfaces a
# progress signal so a long compile is distinguishable from a hang: elapsed
# seconds plus the most recent install-log line (the command stream lands
# there in quiet mode), clipped to the terminal width.
activity_spawn_renderer() {
  (
    local frames=$'|/-\\' frame=0 tick=0 elapsed cols last="" line
    local size="" grown="" fresh=${SECONDS} stall=0
    cols="$(stty size <&3 2>/dev/null | cut -d' ' -f2)" || cols=""
    [[ "${cols}" =~ ^[0-9]+$ ]] || cols=100
    trap 'exit 0' HUP INT TERM
    while true; do
      # The frame spins every tick (fork-free); the log tail — the part that
      # needs a subprocess — refreshes only ~once a second, so the animation
      # stays cheap even across a long build.
      if ((tick % 5 == 0)) && [[ -n "${LOG_FILE:-}" && -r "${LOG_FILE}" ]]; then
        last="$(tail -n1 "${LOG_FILE}" 2>/dev/null | tr -d '\r')" || last=""
        # Log growth is the liveness signal: a size static past the
        # threshold flags a probable hang until output resumes.
        grown="$(stat -c %s "${LOG_FILE}" 2>/dev/null)" || grown="${size}"
        if [[ "${grown}" != "${size}" ]]; then
          size="${grown}"
          fresh=${SECONDS}
        fi
      fi
      elapsed=$((SECONDS - ACTIVITY_START))
      stall=$((SECONDS - fresh))
      line="[${frames:frame:1}] ${ACTIVITY_LABEL} (${elapsed}s)"
      ((stall > ACTIVITY_STALL_SECS)) && line="${line} (no output for ${stall}s)"
      # "last:" keeps a tool's own completion banner reading as context,
      # never as the installer finishing.
      [[ -n "${last}" ]] && line="${line}  last: ${last}"
      printf '\r\033[K%s' "${line:0:cols}" >&3 || true
      frame=$(((frame + 1) % 4))
      tick=$((tick + 1))
      sleep 0.2
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
  ACTIVITY_START=${SECONDS}
  printf '[INFO] === %s ===\n' "${label}" || true
  case "${CONSOLE_MODE}" in
    tty) activity_spawn_renderer ;;
    plain) printf '[INFO] === %s ===\n' "${label}" >&3 || true ;;
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
    activity_spawn_renderer
  fi
  return 0
}

activity_success() {
  ((ACTIVITY_ACTIVE)) || return 0
  activity_pause
  case "${CONSOLE_MODE}" in
    tty)
      printf '\r\033[K[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" >&3 || true
      printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" || true
      ;;
    plain)
      printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" >&3 || true
      printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" || true
      ;;
    verbose | direct) printf '[INFO] Completed: %s\n' "${ACTIVITY_LABEL}" || true ;;
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
