# shellcheck shell=bash
# Chroot bind mount tracking and teardown. Mount order is recorded so
# teardown can run strictly in reverse, including on failure paths.

CHROOT_MOUNTS=()

track_mount() {
  CHROOT_MOUNTS+=("$1")
}

mount_chroot_binds() {
  local t="${TARGET}"
  mkdir -p "${t}/dev" "${t}/dev/pts" "${t}/proc" "${t}/sys" "${t}/run"

  mount --bind /dev "${t}/dev" || fatal "Failed to bind-mount ${t}/dev"
  track_mount "${t}/dev"
  mount --bind /dev/pts "${t}/dev/pts" || fatal "Failed to bind-mount ${t}/dev/pts"
  track_mount "${t}/dev/pts"
  mount -t proc proc "${t}/proc" || fatal "Failed to mount ${t}/proc"
  track_mount "${t}/proc"
  mount -t sysfs sysfs "${t}/sys" || fatal "Failed to mount ${t}/sys"
  track_mount "${t}/sys"
  # HYPR_PRIVATE_RUN=1 (set by the ISO builder) mounts a fresh tmpfs at /run
  # instead of bind-mounting the host's live /run. Host /run carries the real
  # systemd (/run/systemd/private) and D-Bus sockets; a package maintainer
  # script that calls systemctl/dbus-send DIRECTLY would otherwise reach the
  # host's PID 1 even with policy-rc.d in place (policy-rc.d only covers
  # invoke-rc.d/deb-systemd-invoke). A private tmpfs has no host sockets, so no
  # in-chroot process can touch host services. The installer leaves this unset
  # and keeps the bind (it runs inside the disposable live ISO, not the user OS).
  if ((${HYPR_PRIVATE_RUN:-0})); then
    mount -t tmpfs tmpfs "${t}/run" || fatal "Failed to mount tmpfs ${t}/run"
  else
    mount --bind /run "${t}/run" || fatal "Failed to bind-mount ${t}/run"
  fi
  track_mount "${t}/run"
  # The ISO builder (HYPR_PRIVATE_RUN=1) never installs a bootloader into the
  # buildroot, so it must NOT expose host EFI NVRAM (a writable host-mutation
  # surface). Only the installer (flag unset) binds efivars, where it is needed.
  if ((${HYPR_PRIVATE_RUN:-0} == 0)) && [[ -d /sys/firmware/efi/efivars ]]; then
    mount --bind /sys/firmware/efi/efivars "${t}/sys/firmware/efi/efivars" ||
      fatal "Failed to bind-mount ${t}/sys/firmware/efi/efivars"
    track_mount "${t}/sys/firmware/efi/efivars"
  fi
}

teardown_chroot_binds() {
  local i=0
  for ((i = ${#CHROOT_MOUNTS[@]} - 1; i >= 0; i--)); do
    if mountpoint -q "${CHROOT_MOUNTS[i]}"; then
      umount "${CHROOT_MOUNTS[i]}" ||
        umount -l "${CHROOT_MOUNTS[i]}" ||
        warn "Could not unmount ${CHROOT_MOUNTS[i]}"
    fi
  done
  CHROOT_MOUNTS=()
}

in_target() {
  (($# == 1)) || fatal "in_target expects exactly one command string"
  # Close fds 3/4 (the operator console opened by setup_logging in quiet mode)
  # across the chroot boundary: chrooted processes write to the log via
  # stdout/stderr and have no business holding the host console. No-op before
  # logging is set up, when 3/4 are not open.
  chroot "${TARGET}" /usr/bin/env bash -c "$1" 3>&- 4>&-
}

# Kill anything still running out of the target tree (daemons started by
# maintainer scripts, stray shells): a single surviving process holds the
# mounts and breaks unmount/export at teardown. Best effort.
kill_target_processes() {
  command -v fuser >/dev/null 2>&1 || return 0
  mountpoint -q "${TARGET}" 2>/dev/null || return 0
  if fuser -k -M -m "${TARGET}" 2>/dev/null; then
    warn "Killed processes still using ${TARGET} before teardown."
    sleep 1
  fi
}
