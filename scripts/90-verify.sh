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
  local esp="${TARGET}${ESP_MOUNT}"

  if ((BUILD_ON_FIRSTBOOT)); then
    vcheck "firstboot unit enabled" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
    vcheck "firstboot runner staged" \
      test -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"
    vcheck "sources staged" \
      test -d "${TARGET}/var/tmp/hypr-deb-build/hyprland"
    vcheck "toolchain staged for firstboot" in_target "command -v cmake"
  else
    vcheck "Hyprland binary runs" in_target "/usr/local/bin/Hyprland --version"
    vcheck "Hyprland links resolve" in_target \
      "! ldd /usr/local/bin/Hyprland | grep -q 'not found'"
  fi

  vcheck "greetd enabled" in_target "systemctl is-enabled greetd"
  vcheck "uwsm present" in_target "command -v uwsm"
  vcheck "user hyprland.conf exists" \
    test -f "${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.conf"

  vcheck "kernel on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/vmlinuz-* >/dev/null 2>&1"
  vcheck "initramfs on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/initrd.img-* >/dev/null 2>&1"

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

  vcheck "fstab ESP UUID valid" bash -c \
    "uuid=\$(grep -oP 'UUID=\K[^ ]+(?= /boot/efi)' '${TARGET}/etc/fstab');
     [[ -n \"\${uuid}\" ]] && blkid -U \"\${uuid}\""
  vcheck "mdadm.conf present" test -s "${TARGET}/etc/mdadm/mdadm.conf"
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
}
