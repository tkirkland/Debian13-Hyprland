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

# dkms signs every module it builds with this keypair and the boot phase
# signs loader EFI binaries with it. Debian's dkms would generate it on
# demand, but the zfs-dkms postinst (during install_base_packages) is the
# first consumer, so it must exist before packages land. Generated with
# the LIVE environment's openssl (the chroot has none yet). Parameters
# mirror Debian dkms defaults: passphrase-less RSA 2048, DER certificate.
ensure_mok_key() {
  if [[ -f "${TARGET}${MOK_KEY}" && -f "${TARGET}${MOK_CRT}" ]]; then
    return 0
  fi
  mkdir -p "${TARGET}/var/lib/dkms"
  openssl req -new -x509 -nodes -days 36500 -newkey rsa:2048 \
    -subj "/CN=hypr-deb DKMS module signing key/" \
    -keyout "${TARGET}${MOK_KEY}" -outform DER \
    -out "${TARGET}${MOK_CRT}" 2>/dev/null ||
    fatal "MOK keypair generation failed (openssl)."
  chmod 600 "${TARGET}${MOK_KEY}"
  info "Generated MOK signing keypair at ${MOK_KEY}."
}

install_base_packages() {
  local pkgs=("${TARGET_BASE_PACKAGES[@]}")
  # VMware guest integration (display resize, clipboard, time sync,
  # clean shutdown). open-vm-tools-desktop layers desktop features on the
  # base daemon; both are pointless on bare metal, so VIRT_TYPE gates them.
  if [[ "${VIRT_TYPE}" == "vmware" ]]; then
    pkgs+=(open-vm-tools open-vm-tools-desktop)
  fi
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${pkgs[*]}
  "
  if ((ZFS_FROM_SOURCE)); then
    stage_zfs_upgrade_job
  fi
}

# --zfs-from-source (hybrid): the install keeps Debian's zfs 2.3.x — fast,
# dkms-signed in the chroot, and it mounts the ZFS root on boot #1. The
# upstream release builds at FIRST BOOT, after the MokManager screen has
# enrolled the MOK key, as firstboot job 30-zfs-upgrade.sh. Sources and
# build deps are staged now so the job needs no network. A failed build
# keeps the running 2.3.x: the system stays bootable and the job is
# re-runnable from its .failed file.
stage_zfs_upgrade_job() {
  ((NETWORK_AVAILABLE)) ||
    fatal "--zfs-from-source requires network to stage the source tree."
  local tag=""
  # Tags include dev-cycle markers (zfs-X.Y.99) that outrank real releases
  # in a version sort; the GitHub API names the actual latest release.
  tag="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/openzfs/zfs/releases/latest" 2>/dev/null |
    grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 || true)"
  [[ -n "${tag}" ]] ||
    tag="$(resolve_latest_release_tag "${ZFS_REPO_URL}" "${ZFS_TAG_PATTERN}")"
  info "Staging OpenZFS ${tag} for the first-boot upgrade build..."
  rm -rf "${TARGET}/var/tmp/openzfs"
  git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
    "${ZFS_REPO_URL}" "${TARGET}/var/tmp/openzfs"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${ZFS_BUILD_PACKAGES[*]}
  "
  # The firstboot job builds offline; mark its toolchain manual so the
  # `apt-get autoremove --purge` in purge_build_deps (in-chroot Hyprland
  # build) cannot sweep it away as orphaned.
  in_target "apt-mark manual ${ZFS_BUILD_PACKAGES[*]} >/dev/null"
  stage_firstboot_runner
  write_zfs_upgrade_job
}

write_zfs_upgrade_job() {
  local jobs="${TARGET}/usr/local/lib/hypr-deb/firstboot.d"
  mkdir -p "${jobs}"
  cat >"${jobs}/30-zfs-upgrade.sh" <<'EOF'
#!/usr/bin/env bash
# Firstboot job: build upstream OpenZFS (staged at install) as native
# Debian packages and replace the repo 2.3.x. dkms signs the module with
# the MOK key the user enrolled at the MokManager screen. ONLY
# native-deb-utils is built: it includes openzfs-zfs-dkms, whose postinst
# builds for the installed kernels. Upstream's deb recipes swallow
# dpkg-buildpackage failures, so required packages are asserted by name.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd /var/tmp/openzfs
if dpkg-query -W 'openzfs-zfs-modules-*' >/dev/null 2>&1; then
  apt-get purge -y 'openzfs-zfs-modules-*'
fi
./autogen.sh
./configure
make -j"$(nproc)" native-deb-utils
for p in openzfs-zfs-dkms openzfs-zfsutils openzfs-zfs-initramfs \
  openzfs-zfs-zed; do
  ls /var/tmp/${p}_*.deb >/dev/null 2>&1 ||
    { echo "required package not built: ${p}" >&2; exit 1; }
done
debs="$(ls /var/tmp/*.deb |
  grep -Ev 'zfs-modules|test|dracut|dbg|-dev|pam' || true)"
[[ -n "${debs}" ]] ||
  { echo 'native-deb-utils produced no installable packages' >&2; exit 1; }
echo "${debs}" | xargs apt-get install -y
# pam_zfs_key registers itself in common-password and breaks chpasswd on
# systems without encrypted homes; keep it out and regenerate PAM.
if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
  apt-get purge -y 'openzfs*pam*'
fi
rm -f /usr/share/pam-configs/*zfs*
pam-auth-update --package
update-initramfs -u -k all
rm -rf /var/tmp/openzfs
rm -f /var/tmp/*.deb /var/tmp/*.changes /var/tmp/*.buildinfo
touch /run/hypr-deb-reboot-required
echo "OpenZFS upgrade complete; reboot pending." >&2
EOF
  chmod +x "${jobs}/30-zfs-upgrade.sh"
}

# Addon artifacts: things apt cannot provide, dropped into addons/.
#   *.deb  installed via apt from the local file (dependencies resolved
#          from the enabled sources; the chroot policy-rc.d guard blocks
#          service starts like for every other package).
#   *.sh   user-authored customization hooks, EXECUTED inside the target
#          chroot as root, in lexical order, after packages and addon
#          debs (live-build hook semantics). A failing script fails the
#          phase by name.
#   *.run  staged executable at /opt/addons in the target and NOT
#          executed: vendor runfiles (VMware etc.) compile kernel modules
#          and start services against the RUNNING system, so they must be
#          run manually after first boot.
install_addon_artifacts() {
  local f="" staged=0
  if compgen -G "addons/*.deb" >/dev/null; then
    info "Installing addon .deb packages..."
    rm -rf "${TARGET}/var/tmp/addon-debs"
    install -d "${TARGET}/var/tmp/addon-debs"
    cp addons/*.deb "${TARGET}/var/tmp/addon-debs/"
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y /var/tmp/addon-debs/*.deb
    "
    rm -rf "${TARGET}/var/tmp/addon-debs"
  fi
  if compgen -G "addons/*.sh" >/dev/null; then
    rm -rf "${TARGET}/var/tmp/addon-scripts"
    install -d "${TARGET}/var/tmp/addon-scripts"
    cp addons/*.sh "${TARGET}/var/tmp/addon-scripts/"
    for f in addons/*.sh; do
      info "Running addon script ${f##*/} in the target..."
      in_target "bash '/var/tmp/addon-scripts/${f##*/}'" ||
        fatal "Addon script failed: ${f##*/}"
    done
    rm -rf "${TARGET}/var/tmp/addon-scripts"
  fi
  if compgen -G "addons/*.run" >/dev/null; then
    install -d "${TARGET}/opt/addons"
    for f in addons/*.run; do
      install -m755 "${f}" "${TARGET}/opt/addons/"
      staged=$((staged + 1))
    done
    info "Staged ${staged} vendor runfile(s) at /opt/addons — run them" \
      "manually after first boot (they need the running system)."
  fi
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
  ensure_mok_key
  install_base_packages
  install_addon_artifacts
  configure_locale_tz
  create_user
  configure_zfs_boot_support
}
