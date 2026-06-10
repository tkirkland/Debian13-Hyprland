#!/usr/bin/env bash
# Hypr-Deb: Debian 13 + Hyprland (release tags) installer for the fixed
# three-disk ZFS/mdadm layout. See README.md and docs/superpowers/specs/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source lib/00-config.sh
source lib/01-log.sh
source lib/02-args.sh
source lib/03-state.sh
source lib/04-chroot-mounts.sh
source scripts/00-preflight.sh
source scripts/10-cache.sh
source scripts/20-storage.sh
source scripts/30-bootstrap.sh
source scripts/40-system.sh
source scripts/50-boot.sh
source scripts/60-hyprland.sh
source scripts/90-verify.sh
source scripts/99-cleanup.sh

on_error() {
  local exit_code=$?
  warn "FAILED in phase '${CURRENT_PHASE:-startup}' (exit ${exit_code})."
  [[ -n "${LOG_FILE}" ]] && warn "Full log: ${LOG_FILE}"
  teardown_chroot_binds
  exit "${exit_code}"
}

main() {
  parse_args "$@"
  state_init "${FRESH}"
  setup_logging "${LOG_DIR}"
  trap on_error ERR

  CURRENT_PHASE="preflight"
  run_phase preflight phase_preflight
  require_bootloader_choice

  if [[ "${RUN_PHASE}" != "full" ]]; then
    CURRENT_PHASE="${RUN_PHASE}"
    "phase_${RUN_PHASE//-/_}"
    return 0
  fi

  local name=""
  for name in cache storage bootstrap system boot hyprland verify; do
    CURRENT_PHASE="${name}"
    run_phase "${name}" "phase_${name}"
  done
  CURRENT_PHASE="cleanup"
  phase_cleanup
  info "Installation complete. Reboot into '${BOOTLOADER}'."
}

main "$@"
