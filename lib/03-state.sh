# shellcheck shell=bash
# Phase completion stamps under STATE_DIR enable resumable runs.
# Stamps live on tmpfs (/run) by default: resume works within a live
# session and resets naturally on reboot.

state_init() {
  local fresh="$1"
  if ((fresh)) && [[ -d "${STATE_DIR}" ]]; then
    info "--fresh: discarding phase state in ${STATE_DIR}"
    rm -rf "${STATE_DIR}"
  fi
  mkdir -p "${STATE_DIR}"
}

phase_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}

mark_phase_done() {
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/$1.done"
  info "Phase complete: $1"
}

# Run a phase function unless already stamped. Usage: run_phase NAME FUNC
run_phase() {
  local name="$1" func="$2"
  if phase_done "${name}"; then
    info "Skipping ${name} (already complete; --fresh to redo)"
    return 0
  fi
  info "=== Phase: ${name} ==="
  "${func}" || fatal "Phase ${name} failed."
  mark_phase_done "${name}"
}
