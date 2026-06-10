# shellcheck shell=bash
# Cleanup: tear down chroot binds, unmount the target tree, export the pool.
# Also used by the orchestrator's failure trap.

phase_cleanup() {
  info "Cleaning up..."
  # The installed system must start services normally; drop the chroot
  # service guard before handing the disk over.
  if mountpoint -q "${TARGET}" 2>/dev/null; then
    rm -f "${TARGET}/usr/sbin/policy-rc.d"
  fi
  kill_target_processes
  teardown_chroot_binds
  if mountpoint -q "${TARGET}${ESP_MOUNT}" 2>/dev/null; then
    umount "${TARGET}${ESP_MOUNT}" || warn "ESP unmount failed"
  fi
  zfs unmount -a 2>/dev/null || true
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    if ! zpool export "${POOL_NAME}"; then
      warn "Pool export failed; export manually before reboot."
      report_disk_holders "${DISK1}" "${DISK2}" "${DISK3}" || true
    fi
  fi
  info "Cleanup done. Remove the live medium and reboot."
}
