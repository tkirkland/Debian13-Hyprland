# shellcheck shell=bash
# Verification suite: every spec-mandated success condition, reported
# together; nonzero exit if anything fails.

VERIFY_TOTAL=0
VERIFY_FAILED=0

vcheck() { # $1=label, rest=command
  local label="$1" out="" rc=0
  shift
  VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  if out="$("$@" 2>&1)"; then
    info "PASS: ${label}"
  else
    rc=$?
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
    warn "FAIL: ${label} (exit ${rc})"
    # Surface the failing command's tail so failures are diagnosable
    # from the report alone.
    [[ -z "${out}" ]] || warn "      $(printf '%s' "${out}" | tail -n 3)"
  fi
}

verify_report() {
  if ((VERIFY_FAILED > 0)); then
    warn "${VERIFY_FAILED} of ${VERIFY_TOTAL} checks failed."
    return 1
  fi
  info "All ${VERIFY_TOTAL} checks passed."
}

phase_verify() {
  local esp="${TARGET}${ESP_MOUNT}" kver="" vers="" f="" greeter_bin="" sb_dir=""
  for f in "${TARGET}"/boot/vmlinuz-*; do
    [[ -e "${f}" ]] || continue
    vers+="${f##*/vmlinuz-}"$'\n'
  done
  kver="$(printf '%s' "${vers}" | sort -V | tail -n1)"

  if ((BUILD_ON_FIRSTBOOT)); then
    vcheck "firstboot unit enabled" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
    vcheck "firstboot runner staged" \
      test -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"
    vcheck "hyprland firstboot job staged" test -x \
      "${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
    vcheck "sources staged" \
      test -d "${TARGET}/var/tmp/hypr-deb-build/hyprland"
    vcheck "toolchain staged for firstboot" in_target "command -v cmake"
  else
    # Hyprland refuses to run as root and aborts without XDG_RUNTIME_DIR
    # (set by pam_systemd in real logins); provide both for the check.
    vcheck "Hyprland binary runs" in_target "
      set -e
      install -d -m 700 -o '${TARGET_USERNAME}' /tmp/hypr-verify-rt
      runuser -u '${TARGET_USERNAME}' -- \
        env XDG_RUNTIME_DIR=/tmp/hypr-verify-rt \
        /usr/local/bin/Hyprland --version
      rm -rf /tmp/hypr-verify-rt
    "
    vcheck "Hyprland links resolve" in_target \
      "! ldd /usr/local/bin/Hyprland | grep -q 'not found'"
    # guiutils builds every util from its root CMakeLists; if a future tag
    # drops or renames the welcome util, fail loudly here (issue #11).
    vcheck "welcome app installed" \
      test -x "${TARGET}/usr/local/bin/hyprland-welcome"
  fi

  vcheck "greetd enabled" in_target "systemctl is-enabled greetd"
  vcheck "systemd-timesyncd enabled" in_target "systemctl is-enabled systemd-timesyncd"
  vcheck "uwsm present" in_target "command -v uwsm"
  # greetd spawns the greeter with no PATH (PAM env only): the binary the
  # config names must exist at exactly that absolute path.
  greeter_bin="$(grep -oP '^command = "\K[^ "]+' \
    "${TARGET}/etc/greetd/config.toml" 2>/dev/null || true)"
  vcheck "greetd session command binary exists (${greeter_bin:-none})" bash -c \
    "[[ -n '${greeter_bin}' && -x '${TARGET}${greeter_bin}' ]]"
  vcheck "session launcher at /usr/local/bin/uwsm" \
    test -x "${TARGET}/usr/local/bin/uwsm"
  # The quiet-VT wrapper both session modes launch through (issue #12).
  vcheck "session wrapper at /usr/local/bin/hypr-session" \
    test -x "${TARGET}/usr/local/bin/hypr-session"
  # shellcheck disable=SC2016  # the $() must expand inside the chroot, not here
  vcheck "getty@tty1 masked (no VT1 contention with greetd)" in_target \
    '[[ "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" == masked ]]'
  vcheck "user hyprland.lua exists" \
    test -f "${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.lua"

  # NVIDIA (issue #4): only when a GPU was detected and a driver chosen.
  # Offline installs legitimately skip the package (warned at install).
  if nvidia_install_requested; then
    local nv_pkg="${NVIDIA_DRIVER}"
    case "${nv_pkg}" in
      open) nv_pkg="nvidia-open" ;;
      debian) nv_pkg="nvidia-driver" ;;
    esac
    if ((NETWORK_AVAILABLE)); then
      vcheck "NVIDIA driver package installed (${nv_pkg})" \
        in_target "dpkg -s '${nv_pkg}' >/dev/null"
      vcheck "nvidia-drm modeset configured" \
        grep -q "nvidia-drm" "${TARGET}/etc/modprobe.d/nvidia-options.conf"
    fi
    vcheck "uwsm env carries NVIDIA variables" \
      grep -q "__GLX_VENDOR_LIBRARY_NAME" \
      "${TARGET}/home/${TARGET_USERNAME}/.config/uwsm/env"
  fi

  vcheck "kernel on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/vmlinuz-* >/dev/null 2>&1"
  vcheck "initramfs on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/initrd.img-* >/dev/null 2>&1"
  # A root-on-ZFS system is unbootable without these two; dkms skips the
  # module build silently when target kernel headers are missing.
  vcheck "zfs module built for target kernel" in_target \
    "modinfo -k '${kver}' zfs >/dev/null"
  vcheck "initramfs contains zfs module" in_target \
    "lsinitramfs '/boot/initrd.img-${kver}' | grep -q '/zfs.ko'"

  case "${BOOTLOADER}" in
    zbm)
      vcheck "ZBM EFI on ESP" test -f "${esp}/EFI/zbm/zfsbootmenu.efi"
      vcheck "ZBM cmdline property" bash -c \
        "zfs get -H -o value org.zfsbootmenu:commandline '${ROOT_DATASET}' |
         grep -q rw"
      vcheck "NVRAM entry (ZFSBootMenu)" bash -c \
        "efibootmgr | grep -q 'ZFSBootMenu'"
      ;;
    grub)
      vcheck "GRUB EFI on ESP" test -f "${esp}/EFI/debian/grubx64.efi"
      vcheck "grub.cfg on ESP" test -f "${esp}/EFI/debian/grub/grub.cfg"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      vcheck "initrd copy on ESP" test -f "${esp}/EFI/debian/initrd.img"
      vcheck "NVRAM entry (debian)" bash -c \
        "efibootmgr | grep -qE '^Boot[0-9A-F]{4}.* debian'"
      ;;
    systemd-boot)
      vcheck "sd-boot EFI on ESP" \
        test -f "${esp}/EFI/systemd/systemd-bootx64.efi"
      vcheck "loader entry on ESP" \
        test -f "${esp}/loader/entries/debian.conf"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      vcheck "initrd copy on ESP" test -f "${esp}/EFI/debian/initrd.img"
      vcheck "NVRAM entry (Linux Boot Manager)" bash -c \
        "efibootmgr | grep -q 'Linux Boot Manager'"
      ;;
  esac

  # Secure boot chain: shim + MokManager beside the loader; self-shipped
  # loaders (zbm, systemd-boot) verify against the MOK cert. GRUB's
  # grubx64.efi is Debian-signed, so presence (checked above) suffices.
  case "${BOOTLOADER}" in
    zbm) sb_dir="zbm" ;;
    grub) sb_dir="debian" ;;
    systemd-boot) sb_dir="systemd" ;;
  esac
  vcheck "shim on ESP" test -f "${esp}/EFI/${sb_dir}/shimx64.efi"
  vcheck "MokManager on ESP" test -f "${esp}/EFI/${sb_dir}/mmx64.efi"
  vcheck "chain-loaded loader on ESP" \
    test -f "${esp}/EFI/${sb_dir}/grubx64.efi"
  if [[ "${BOOTLOADER}" != "grub" ]]; then
    vcheck "loader MOK signature valid" in_target \
      "sbverify --cert '${MOK_PEM}' '${ESP_MOUNT}/EFI/${sb_dir}/grubx64.efi'"
  fi
  # Warn-only: VMs without efivars cannot stage the import.
  if ! in_target "mokutil --list-new 2>/dev/null | grep -q ."; then
    warn "MOK enrollment not staged (no efivars?). On the installed" \
      "system run: mokutil --import ${MOK_CRT}"
  fi

  vcheck "fstab ESP UUID valid" bash -c \
    "uuid=\$(grep -oP 'UUID=\K[^ ]+(?= /boot/efi)' '${TARGET}/etc/fstab');
     [[ -n \"\${uuid}\" ]] && blkid -U \"\${uuid}\""
  vcheck "mdadm.conf present" test -s "${TARGET}/etc/mdadm/mdadm.conf"
  vcheck "zfs-zed enabled (pool fault reporting)" in_target \
    "systemctl is-enabled zfs-zed"
  # Networked installs replace Debian's zfs with the upstream build;
  # offline installs legitimately keep the repo 2.3.x packages.
  if ((NETWORK_AVAILABLE)); then
    vcheck "upstream openzfs installed" in_target \
      "dpkg -s openzfs-zfsutils >/dev/null"
  fi
  vcheck "pool bootfs set" bash -c \
    "zpool get -H -o value bootfs '${POOL_NAME}' |
     grep -qx '${ROOT_DATASET}'"
  if ((SKIP_CACHE)); then
    info "skip: embedded cache check (--skip-cache)"
  else
    vcheck "embedded cache repo valid" \
      test -f "${TARGET}${TARGET_CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages"
  fi

  verify_report || fatal "Verification failed — installation is NOT complete."
  info "SUCCESS: bootable Debian + Hyprland conditions both met."
  info "Secure boot: ready. First boot shows the blue MokManager screen —"
  info "choose 'Enroll MOK' and enter your user password. After that you"
  info "may enable secure boot in firmware at any time."
}
