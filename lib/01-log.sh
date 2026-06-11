# bashsupport disable=BP5007
# shellcheck shell=bash
# Logging helpers. Sourced by hypr_deb.sh; VERBOSE comes from lib/00-config.sh.

info() { printf '[INFO] %s\n' "$*"; }

warn() { printf '[WARN] %s\n' "$*" >&2; }

verbose() {
  ((VERBOSE)) || return 0
  printf '[VERB] %s\n' "$*"
}

fatal() {
  printf '[FATAL] %s\n' "$*" >&2
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

# Tee all further output into a timestamped log file under $1.
setup_logging() {
  local dir="$1" ts=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dir}"
  LOG_FILE="${dir}/hypr-deb-${ts}.log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  info "Logging to ${LOG_FILE}"
}
