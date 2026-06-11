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
  local pkgs=("${TARGET_BASE_PACKAGES[@]}") p="" filtered=()
  # VMware guest integration (display resize, clipboard, time sync,
  # clean shutdown). open-vm-tools-desktop layers desktop features on the
  # base daemon; both are pointless on bare metal, so VIRT_TYPE gates them.
  if [[ "${VIRT_TYPE}" == "vmware" ]]; then
    pkgs+=(open-vm-tools open-vm-tools-desktop)
  fi
  if ((ZFS_FROM_SOURCE)); then
    # The upstream openzfs-* packages replace these; installing Debian's
    # first would only churn (and dkms-build) packages we remove again.
    for p in "${pkgs[@]}"; do
      case " ${ZFS_DEBIAN_PACKAGES[*]} " in
        *" ${p} "*) continue ;;
      esac
      filtered+=("${p}")
    done
    pkgs=("${filtered[@]}")
  fi
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${pkgs[*]}
  "
  if ((ZFS_FROM_SOURCE)); then
    install_zfs_from_source
  fi
}

# Build upstream OpenZFS at its latest release as native Debian packages
# inside the target and install them. ONLY native-deb-utils is built: that
# set includes openzfs-zfs-dkms (whose postinst builds the module for the
# TARGET's kernels — headers are already installed). native-deb-kmod is
# deliberately avoided: it compiles modules for the RUNNING (live) kernel
# and its package dependency drags that kernel image into the target.
# Upstream's deb recipes swallow dpkg-buildpackage failures (the lock-file
# rm masks the exit code), so the required packages are asserted by name.
install_zfs_from_source() {
  ((NETWORK_AVAILABLE)) ||
    fatal "--zfs-from-source requires network (zfs is not in the offline cache yet)."
  local tag="" jobs="${HYPR_BUILD_JOBS:-}"
  [[ -n "${jobs}" ]] || jobs="\$(nproc)"
  # Tags include dev-cycle markers (zfs-X.Y.99) that outrank real releases
  # in a version sort; the GitHub API names the actual latest release.
  # ls-remote with the tag pattern remains the fallback.
  tag="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/openzfs/zfs/releases/latest" 2>/dev/null |
    grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 || true)"
  [[ -n "${tag}" ]] ||
    tag="$(resolve_latest_release_tag "${ZFS_REPO_URL}" "${ZFS_TAG_PATTERN}")"
  info "Building OpenZFS ${tag} from source (replaces Debian's zfs-*)..."
  rm -rf "${TARGET}/var/tmp/openzfs"
  rm -f "${TARGET}"/var/tmp/*.deb "${TARGET}"/var/tmp/*.changes \
    "${TARGET}"/var/tmp/*.buildinfo
  git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
    "${ZFS_REPO_URL}" "${TARGET}/var/tmp/openzfs"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # Drop any live-kernel modules package from an earlier failed attempt.
    if dpkg-query -W 'openzfs-zfs-modules-*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs-zfs-modules-*'
    fi
    apt-get install -y ${ZFS_BUILD_PACKAGES[*]}
    cd /var/tmp/openzfs
    ./autogen.sh
    ./configure
    make -j\"${jobs}\" native-deb-utils
    for p in openzfs-zfs-dkms openzfs-zfsutils openzfs-zfs-initramfs \
      openzfs-zfs-zed; do
      ls /var/tmp/\${p}_*.deb >/dev/null 2>&1 ||
        { echo \"required package not built: \${p}\" >&2; exit 1; }
    done
    debs=\"\$(ls /var/tmp/*.deb |
      grep -Ev 'zfs-modules|test|dracut|dbg|-dev|pam' || true)\"
    [[ -n \"\${debs}\" ]] ||
      { echo 'native-deb-utils produced no installable packages' >&2; exit 1; }
    echo \"\${debs}\" | xargs apt-get install -y
    # pam_zfs_key (encrypted-home key sync) registers itself in
    # common-password and makes chpasswd fail with 'Authentication token
    # manipulation error' on systems without encrypted homes. Keep it out:
    # never install it (deb filter above), purge it if a previous attempt
    # installed it, and regenerate the PAM stack from clean profiles.
    if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs*pam*'
    fi
    rm -f /usr/share/pam-configs/*zfs*
    pam-auth-update --package
  "
  in_target "zfs version" || true
  rm -rf "${TARGET}/var/tmp/openzfs"
}

create_user() {
  # The Downloads dataset is created canmount=noauto (20-storage.sh) so no
  # zfs mount -a can pre-create a root-owned /home/<user>: adduser runs
  # against a clean /home and builds the home directory properly.
  in_target "
    set -e
    id '${TARGET_USERNAME}' >/dev/null 2>&1 ||
      adduser --disabled-password --gecos '' '${TARGET_USERNAME}'
    # adm + systemd-journal: the workstation owner reads logs without sudo.
    usermod -aG sudo,adm,systemd-journal '${TARGET_USERNAME}'
    # Persistent journal (journald Storage=auto): without this directory,
    # per-user journals are volatile and unreadable by their own user.
    install -d -m 2755 -g systemd-journal /var/log/journal
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
