# shellcheck shell=bash
# Cleanup: tear down chroot binds, unmount the target tree, export the pool.
# Also used by the orchestrator's failure trap.

# Unmount the target tree and export the pool. Called by phase_cleanup at
# the end of full runs AND after every successful standalone --phase run
# (issue #50): a pool left imported stays stamped with the LIVE env's
# hostid, and the installed system's initramfs then refuses the import and
# drops to an emergency shell on the very next boot. Everything here is
# guarded/idempotent. Deliberately does NOT remove the policy-rc.d service
# guard — mid-install resume flows need it to survive until the final
# cleanup phase hands the disk over.
teardown_target_tree() {
  # Remove the temporary offline file:// source and unmount the on-ISO repo
  # bind (no-op online / when already torn down). Must run before
  # teardown_chroot_binds unmounts /run, under which the repo is bound.
  teardown_target_iso_repo
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
  # Remove the mount-propagation self-bind now that the datasets are unmounted
  # and the pool exported (no-op when isolation was never set up).
  release_target_propagation
}

phase_cleanup() {
  info "Cleaning up..."
  # The installed system must start services normally; drop the chroot
  # service guard before handing the disk over.
  if mountpoint -q "${TARGET}" 2>/dev/null; then
    rm -f "${TARGET}/usr/sbin/policy-rc.d" \
      "${TARGET}/etc/apt/sources.list.d/sid-toolchain.sources" \
      "${TARGET}/etc/apt/preferences.d/sid-toolchain"
  fi
  teardown_target_tree
  info "Cleanup done. Remove the live medium and reboot."
}
