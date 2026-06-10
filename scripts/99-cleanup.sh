# shellcheck shell=bash
# Cleanup: tear down chroot binds, unmount the target tree, export the pool.
# Also used by the orchestrator's failure trap.

phase_cleanup() {
  info "Cleaning up..."
  teardown_chroot_binds
  if mountpoint -q "${TARGET}${ESP_MOUNT}" 2>/dev/null; then
    umount "${TARGET}${ESP_MOUNT}" || warn "ESP unmount failed"
  fi
  zfs unmount -a 2>/dev/null || true
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool export "${POOL_NAME}" ||
      warn "Pool export failed; export manually before reboot."
  fi
  info "Cleanup done. Remove the live medium and reboot."
}
