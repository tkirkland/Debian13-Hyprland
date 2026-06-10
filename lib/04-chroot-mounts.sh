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
  mount --bind /run "${t}/run" || fatal "Failed to bind-mount ${t}/run"
  track_mount "${t}/run"
  if [[ -d /sys/firmware/efi/efivars ]]; then
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
  chroot "${TARGET}" /usr/bin/env bash -c "$1"
}
