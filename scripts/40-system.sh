# shellcheck shell=bash
# Base system: identity, locale/tz, fstab, mdadm.conf, base packages,
# user account, ZFS boot prerequisites (hostid, cachefile, initramfs).

write_identity() {
  echo "${TARGET_HOSTNAME}" >"${TARGET}/etc/hostname"
  cat >"${TARGET}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}
::1       localhost ip6-localhost ip6-loopback
EOF
}

write_fstab() {
  local efi_uuid="" swap_uuid=""
  efi_uuid="$(blkid -s UUID -o value /dev/md/efi)"
  swap_uuid="$(blkid -s UUID -o value /dev/md/swap)"
  cat >"${TARGET}/etc/fstab" <<EOF
# ZFS datasets mount via the zfs mount generator; root comes from initramfs.
UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1
UUID=${swap_uuid} none swap sw 0 0
EOF
}

write_mdadm_conf() {
  mkdir -p "${TARGET}/etc/mdadm"
  {
    echo "HOMEHOST <ignore>"
    mdadm --detail --scan
  } >"${TARGET}/etc/mdadm/mdadm.conf"
}

# Requires the locales package (/etc/locale.gen, locale-gen), so this must
# run after install_base_packages — a minimal debootstrap does not ship it.
configure_locale_tz() {
  in_target "
    set -e
    test -f /etc/locale.gen ||
      { echo 'locales package missing (/etc/locale.gen)' >&2; exit 1; }
    echo '${TIMEZONE}' > /etc/timezone
    ln -sf '/usr/share/zoneinfo/${TIMEZONE}' /etc/localtime
    sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
    locale-gen
    update-locale LANG='${LOCALE}'
  "
}

install_base_packages() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${TARGET_BASE_PACKAGES[*]}
  "
}

create_user() {
  # The Downloads dataset is created canmount=noauto (20-storage.sh) so no
  # zfs mount -a can pre-create a root-owned /home/<user>: adduser runs
  # against a clean /home and builds the home directory properly.
  in_target "
    set -e
    id '${TARGET_USERNAME}' >/dev/null 2>&1 ||
      adduser --disabled-password --gecos '' '${TARGET_USERNAME}'
    usermod -aG sudo '${TARGET_USERNAME}'
  "
  # Now that the user owns its parent, enable and mount the dataset; from
  # here on (resumes and the booted system) it auto-mounts normally.
  zfs set canmount=on "${POOL_NAME}/home/Downloads"
  mountpoint -q "${TARGET}/home/${TARGET_USERNAME}/Downloads" ||
    zfs mount "${POOL_NAME}/home/Downloads"
  # Defense in depth for targets installed before the noauto ordering (or
  # any other pre-created home): skel without clobber, then own the whole
  # tree including the Downloads mountpoint.
  in_target "
    set -e
    cp -rnT /etc/skel '/home/${TARGET_USERNAME}'
    chown -R '${TARGET_USERNAME}:${TARGET_USERNAME}' '/home/${TARGET_USERNAME}'
  "
  if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${TARGET_USERNAME}:${USER_PASSWORD}" | chroot "${TARGET}" chpasswd
  elif ((IS_INTERACTIVE)); then
    info "Set a password for ${TARGET_USERNAME}:"
    chroot "${TARGET}" passwd "${TARGET_USERNAME}"
  else
    warn "No USER_PASSWORD and non-interactive: ${TARGET_USERNAME} has no password."
  fi
  if [[ -n "${ROOT_PASSWORD}" ]]; then
    echo "root:${ROOT_PASSWORD}" | chroot "${TARGET}" chpasswd
  fi
}

configure_zfs_boot_support() {
  in_target "
    set -e
    zgenhostid -f
    systemctl enable NetworkManager
  "
  # Give the target the pool cachefile so it imports cleanly at boot.
  # The property must hold the post-boot path, not the /target-prefixed one.
  zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}"
  mkdir -p "${TARGET}/etc/zfs"
  cp /etc/zfs/zpool.cache "${TARGET}/etc/zfs/zpool.cache"
  in_target "update-initramfs -u -k all"
}

phase_system() {
  write_identity
  write_fstab
  write_mdadm_conf
  install_base_packages
  configure_locale_tz
  create_user
  configure_zfs_boot_support
}
