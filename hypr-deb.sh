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
  warn "Re-run hypr-deb.sh to resume; completed phases are skipped."
  teardown_chroot_binds
  if mountpoint -q "${TARGET}${ESP_MOUNT}" 2>/dev/null; then
    umount "${TARGET}${ESP_MOUNT}" 2>/dev/null || true
  fi
  zfs unmount -a 2>/dev/null || true
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool export "${POOL_NAME}" 2>/dev/null ||
      warn "Could not export ${POOL_NAME}; export manually before reboot."
  fi
  exit "${exit_code}"
}

# EXIT trap: fatal() exits without tripping the ERR trap, so binds must
# also be torn down here on any nonzero exit (spec: every failure path).
on_exit() {
  local exit_code=$?
  if ((exit_code != 0)); then
    teardown_chroot_binds
  fi
}

main() {
  parse_args "$@"
  state_init "${FRESH}"
  setup_logging "${LOG_DIR}"
  write_debian_sources
  trap on_error ERR
  trap on_exit EXIT

  # Preflight is never stamped/skipped: it sets per-run state
  # (NETWORK_AVAILABLE, VIRT_TYPE, disk selection) that resumed runs need.
  # It is idempotent by design.
  CURRENT_PHASE="preflight"
  info "=== Phase: preflight ==="
  phase_preflight
  case "${RUN_PHASE}" in
    full | boot | verify) require_bootloader_choice ;;
  esac

  if [[ "${RUN_PHASE}" != "full" ]]; then
    CURRENT_PHASE="${RUN_PHASE}"
    case "${RUN_PHASE}" in
      system | boot | hyprland | verify) ensure_target_ready ;;
    esac
    "phase_${RUN_PHASE//-/_}"
    return 0
  fi

  ensure_target_ready
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
