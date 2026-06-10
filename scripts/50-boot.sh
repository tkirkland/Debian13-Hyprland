# shellcheck shell=bash
# Bootloader phase: install exactly one of zbm | grub | systemd-boot on the
# RAID1 ESP, create its NVRAM entry (required to succeed), and for the
# FAT-bound loaders install a kernel-sync hook. Kernels live canonically in
# /boot on the ZFS root dataset.

KVER=""      # newest installed kernel version, set by detect_kernel
ESP_UUID=""  # filesystem UUID of /dev/md/efi

detect_kernel() {
  local k="" versions=""
  for k in "${TARGET}/boot"/vmlinuz-*; do
    [[ -e "${k}" ]] || continue
    versions+="${k##*/vmlinuz-}"$'\n'
  done
  KVER="$(printf '%s' "${versions}" | sort -V | tail -n1)"
  [[ -n "${KVER}" ]] || fatal "No kernel found in ${TARGET}/boot"
  ESP_UUID="$(blkid -s UUID -o value /dev/md/efi)"
  info "Kernel: ${KVER}; ESP UUID: ${ESP_UUID}"
}

kernel_cmdline() {
  printf 'root=ZFS=%s rw %s' "${ROOT_DATASET}" "${KERNEL_CMDLINE_EXTRA}"
}

# Sync the newest kernel+initrd from ZFS /boot to the ESP (grub/sd-boot).
write_esp_sync_hook() {
  mkdir -p "${TARGET}/usr/local/sbin" \
    "${TARGET}/etc/kernel/postinst.d" "${TARGET}/etc/initramfs/post-update.d"
  cat >"${TARGET}/usr/local/sbin/hypr-deb-sync-esp" <<'EOF'
#!/usr/bin/env bash
# Copy the newest kernel + initrd from /boot (ZFS) to the ESP so FAT-bound
# bootloaders (grub, systemd-boot) can read them. Installed by hypr-deb.sh.
set -euo pipefail
mountpoint -q /boot/efi || { echo "ESP not mounted at /boot/efi" >&2; exit 1; }
esp="/boot/efi/EFI/debian"
kver="$(for k in /boot/vmlinuz-*; do
  [[ -e "${k}" ]] && printf '%s\n' "${k#/boot/vmlinuz-}"
done | sort -V | tail -n1)"
[[ -n "${kver}" ]] || { echo "hypr-deb-sync-esp: no kernel in /boot" >&2; exit 1; }
mkdir -p "${esp}"
cp "/boot/vmlinuz-${kver}" "${esp}/vmlinuz"
cp "/boot/initrd.img-${kver}" "${esp}/initrd.img"
sync
EOF
  chmod +x "${TARGET}/usr/local/sbin/hypr-deb-sync-esp"
  local hook=""
  for hook in "${TARGET}/etc/kernel/postinst.d/zz-hypr-deb-esp" \
    "${TARGET}/etc/initramfs/post-update.d/zz-hypr-deb-esp"; do
    cat >"${hook}" <<'EOF'
#!/bin/sh
exec /usr/local/sbin/hypr-deb-sync-esp
EOF
    chmod +x "${hook}"
  done
}

run_esp_sync() {
  in_target "/usr/local/sbin/hypr-deb-sync-esp"
}

create_nvram_entry() { # $1=label $2=loader-path (backslash form)
  local label="$1" loader="$2" disk="" pnum=1 bootnum=""
  # Delete stale entries with the same label so re-runs don't accumulate
  # duplicates. Exact-label match: the label is everything between
  # "BootXXXX* " and the tab-separated device path (or end of line).
  while read -r bootnum; do
    efibootmgr -b "${bootnum}" -B >/dev/null ||
      warn "Could not delete stale NVRAM entry Boot${bootnum} (${label})"
  done < <(efibootmgr | awk -F'\t' -v lbl="${label}" '
    $1 ~ /^Boot[0-9A-F]{4}[* ] / {
      entry = $1; num = substr(entry, 5, 4)
      sub(/^Boot[0-9A-F]{4}[* ] /, "", entry)
      if (entry == lbl) print num
    }')
  # Entry on both ESP member disks for redundancy; DISK1 first (primary).
  for disk in "${DISK2}" "${DISK1}"; do
    efibootmgr --create --disk "$(readlink -f "${disk}")" --part "${pnum}" \
      --label "${label}" --loader "${loader}" ||
      fatal "efibootmgr entry creation failed (spec: NVRAM entry required)."
  done
}

# --- ZFSBootMenu -------------------------------------------------------------

install_zbm() {
  local efi_src="${CACHE_DIR}/zfsbootmenu.EFI"
  if [[ ! -f "${efi_src}" ]]; then
    ((NETWORK_AVAILABLE)) || fatal "No cached ZBM binary and no network."
    mkdir -p "${CACHE_DIR}"
    curl -fsSL -o "${efi_src}" "${ZBM_EFI_URL}"
  fi
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/zbm"
  cp "${efi_src}" "${TARGET}${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi"
  # ZBM reads the kernel cmdline from this dataset property.
  zfs set org.zfsbootmenu:commandline="rw ${KERNEL_CMDLINE_EXTRA}" \
    "${ROOT_DATASET}"
  create_nvram_entry "ZFSBootMenu" '\EFI\zbm\zfsbootmenu.efi'
}

# --- GRUB --------------------------------------------------------------------

write_grub_cfg() {
  # grub-install --boot-directory=${ESP_MOUNT}/EFI/debian embeds the prefix
  # (ESP)/EFI/debian/grub/, so the cfg must live in that grub/ subdirectory.
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/debian/grub"
  cat >"${TARGET}${ESP_MOUNT}/EFI/debian/grub/grub.cfg" <<EOF
# Static config written by hypr-deb.sh; kernel copies are refreshed by
# hypr-deb-sync-esp.
# GRUB reads kernel copies from the ESP and never reads the ZFS pool.
set timeout=3
search --no-floppy --fs-uuid --set=root ${ESP_UUID}
menuentry "Debian ${SUITE} (ZFS root)" {
  linux /EFI/debian/vmlinuz $(kernel_cmdline)
  initrd /EFI/debian/initrd.img
}
EOF
}

install_grub() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y grub-efi-amd64
    grub-install --target=x86_64-efi --efi-directory=${ESP_MOUNT} \
      --boot-directory=${ESP_MOUNT}/EFI/debian --bootloader-id=debian \
      --no-nvram
  "
  write_esp_sync_hook
  run_esp_sync
  write_grub_cfg
  create_nvram_entry "debian" '\EFI\debian\grubx64.efi'
}

# --- systemd-boot --------------------------------------------------------------

write_sdboot_entries() {
  mkdir -p "${TARGET}${ESP_MOUNT}/loader/entries"
  cat >"${TARGET}${ESP_MOUNT}/loader/loader.conf" <<'EOF'
default debian.conf
timeout 3
EOF
  cat >"${TARGET}${ESP_MOUNT}/loader/entries/debian.conf" <<EOF
title Debian ${SUITE} (ZFS root)
linux /EFI/debian/vmlinuz
initrd /EFI/debian/initrd.img
options $(kernel_cmdline)
EOF
}

install_sdboot() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y systemd-boot
    SYSTEMD_RELAX_ESP_CHECKS=1 bootctl install --no-variables \
      --esp-path=${ESP_MOUNT}
  "
  write_esp_sync_hook
  run_esp_sync
  write_sdboot_entries
  # --no-variables skips bootctl's NVRAM write (unreliable on a RAID1 ESP);
  # create the entry ourselves on both member disks.
  create_nvram_entry "Linux Boot Manager" '\EFI\systemd\systemd-bootx64.efi'
}

phase_boot() {
  detect_kernel
  case "${BOOTLOADER}" in
    zbm) install_zbm ;;
    grub) install_grub ;;
    systemd-boot) install_sdboot ;;
    *) fatal "BOOTLOADER not set (preflight should have ensured this)." ;;
  esac
}
