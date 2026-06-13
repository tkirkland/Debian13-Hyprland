#!/usr/bin/env bash
# bashsupport disable=BP5007
# Hypr-Deb: Debian 13 + Hyprland (release tags) installer for the fixed
# three-disk ZFS/mdadm layout. See README.md and docs/superpowers/specs/.

set -euo pipefail

BASEDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_file() {
    local file="${BASEDIR}/$1"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing file: $file" >&2
        exit 1
    fi

    source "$file"
}

source_file "lib/00-config.sh"
source_file "lib/01-log.sh"
source_file "lib/02-args.sh"
source_file "lib/03-state.sh"
source_file "lib/04-chroot-mounts.sh"

source_file "scripts/00-preflight.sh"
source_file "scripts/10-cache.sh"
source_file "scripts/20-storage.sh"
source_file "scripts/30-bootstrap.sh"
source_file "scripts/40-system.sh"
source_file "scripts/50-boot.sh"
source_file "scripts/60-hyprland.sh"
source_file "scripts/90-verify.sh"
source_file "scripts/99-cleanup.sh"

# Triggers when error fires
on_error() {
  local exit_code=$?
  warn "FAILED in phase '${current_phase:-startup}' (exit ${exit_code})."
  [[ -n "${LOG_FILE}" ]] && warn "Full log: ${LOG_FILE}"
  warn "Re-run installer.sh to resume; completed phases are skipped."
  # Storage failures are "something almost always holds the disk" — trace
  # the holders into the log before the teardown hides the evidence.
  if [[ "${current_phase:-}" == "storage" ]]; then
    report_disk_holders "${DISK1}" "${DISK2}" "${DISK3}" || true
  fi
  # policy-rc.d is intentionally NOT removed here: it must keep guarding
  # apt runs on resumed installations. Only phase_cleanup removes it.
  kill_target_processes
  teardown_chroot_binds
  if mountpoint -q "${TARGET}${ESP_MOUNT}" 2>/dev/null; then
    umount "${TARGET}${ESP_MOUNT}" 2>/dev/null || true
  fi
  zfs unmount -a 2>/dev/null || true
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    if ! zpool export "${POOL_NAME}" 2>/dev/null; then
      warn "Could not export ${POOL_NAME}; export manually before reboot."
      report_disk_holders "${DISK1}" "${DISK2}" "${DISK3}" || true
    fi
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

# Main loop
main() {
  cd "${BASEDIR}"
  parse_args "$@"
  state_init "${FRESH}"
  setup_logging "${LOG_DIR}"
  trap on_error ERR
  trap on_exit EXIT

  # --phase=cleanup must work on a half-torn-down system: skip preflight
  # entirely (its VM disk detection would refuse disks that still carry
  # mounts — clearing this is exactly cleanup's job).
  if [[ "${RUN_PHASE}" == "cleanup" ]]; then
    current_phase="cleanup"
    require_root
    phase_cleanup
    return 0
  fi

  # Collect every decision a prompt would gather BEFORE preflight spends
  # minutes installing tools — non-interactive runs fail fast here instead
  # of mid-run.
  require_root
  write_debian_sources
  case "${RUN_PHASE}" in
    full | boot | verify) require_bootloader_choice ;;
  esac

  # --yes promises an unattended run, but create_user would still block on
  # an interactive password prompt deep in the system phase (and skipping
  # the password is no fallback: a passwordless user cannot sudo). Fail
  # fast while it is still inexpensive — unless the system is already
  # stamped done.
  if ((ASSUME_YES)) && [[ -z "${USER_PASSWORD}" ]]; then
    case "${RUN_PHASE}" in
      full | system)
        phase_done system ||
          fatal "--yes requires USER_PASSWORD to be set (the password" \
            "prompt would block an unattended run, and sudo needs one)."
        ;;
    esac
  fi
  if ((!IS_INTERACTIVE)) && ((!HYPR_AUTOLOGIN)) &&
    [[ -z "${USER_PASSWORD}" ]] &&
    [[ "${RUN_PHASE}" == "full" || "${RUN_PHASE}" == "system" ]]; then
    fatal "Non-interactive run with no USER_PASSWORD and no --autologin:" \
      "the installed console would not support a login. Set USER_PASSWORD=... " \
      "or pass --autologin."
  fi

  # Preflight is never stamped/skipped: it sets a per-run state
  # (NETWORK_AVAILABLE, VIRT_TYPE, disk selection) that resumed runs need.
  # It is idempotent by design.
  current_phase="preflight"
  info "=== Phase: preflight ==="
  phase_preflight

  if [[ "${RUN_PHASE}" != "full" ]]; then
    current_phase="${RUN_PHASE}"
    case "${RUN_PHASE}" in
      system | boot | hyprland | verify) ensure_target_ready ;;
    esac
    "phase_${RUN_PHASE//-/_}"
    return 0
  fi

  ensure_target_ready
  local name=""
  for name in cache storage bootstrap system boot hyprland verify; do
    if [[ "${name}" == "cache" ]] && ((SKIP_CACHE)); then
      info "Skipping cache phase (--skip-cache); no offline cache."
      continue
    fi
    current_phase="${name}"
    run_phase "${name}" "phase_${name}"
  done
  current_phase="cleanup"
  phase_cleanup
  # A completed installation has no resume state worth keeping: clearing the
  # stamps (and saved disk selection) makes an immediate re-run a genuine
  # fresh installation — still behind the destructive confirmation gate —
  # instead of a confusing all-phases-skipped no-op.
  rm -rf "${STATE_DIR}"
  info "Installation complete. Reboot into '${BOOTLOADER}'."
  info "Phase state cleared; a re-run starts a fresh install."
}

main "$@"
