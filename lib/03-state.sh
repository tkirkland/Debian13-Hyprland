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

# Run a phase function unless already stamped. Usage: run_phase NAME FUNC IDX TOTAL
# IDX/TOTAL are the phase's fixed position in the full-run list, not an
# execution counter: resumed runs skip stamped phases and a counter would
# renumber the survivors.
#
# The phase call is deliberately NOT wrapped in `|| fatal`: a condition
# context would suppress errexit inside the entire phase function, letting
# intermediate failures slide. run_phase must only be called under `set -e`
# (never in a condition context); a failing phase then aborts via the
# caller's ERR trap before the stamp line is reached.
run_phase() {
  local name="$1" func="$2" idx="$3" total="$4"
  if phase_done "${name}"; then
    info "Skipping ${name} (already complete; --fresh to redo)"
    return 0
  fi
  activity_start "Phase ${idx}/${total}: ${name}"
  "${func}"
  mark_phase_done "${name}"
  activity_success
}
