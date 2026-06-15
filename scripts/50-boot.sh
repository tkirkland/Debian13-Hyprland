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
# bootloaders (grub, systemd-boot) can read them. Installed by installer.sh.
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
# Keep the MOK-signed systemd-boot copy fresh: package updates rewrite the
# canonical binary; shim chain-loads our signed copy on the ESP. Debian's
# signed package omits the unsigned path, so prefer its .signed binary.
sd_src="/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed"
[[ -f "${sd_src}" ]] || sd_src="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
sd_dst="/boot/efi/EFI/systemd/grubx64.efi"
if [[ -f "${sd_src}" && -f "${sd_dst}" && "${sd_src}" -nt "${sd_dst}" ]]; then
  sbsign --key /var/lib/dkms/mok.key --cert /var/lib/dkms/mok.pem \
    --output "${sd_dst}" "${sd_src}"
fi
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

# --- Secure boot ---------------------------------------------------------------
# Model: shim (Microsoft-signed) is the NVRAM entry and chain-loads the
# real loader from the 'grubx64.efi' name in its own directory. Debian
# signs grub; zbm and systemd-boot are self-shipped binaries, so they are
# MOK-signed like every other self-built artifact. The same dkms key signs
# kernel modules — one MokManager enrollment covers the whole system.

# sbsign/sbverify need the certificate in PEM; dkms keeps it in DER.
ensure_mok_pem() {
  in_target "
    set -e
    test -f '${MOK_PEM}' ||
      openssl x509 -inform DER -in '${MOK_CRT}' -out '${MOK_PEM}'
  "
}

install_shim() { # $1=ESP subdirectory under EFI/
  local dir="${TARGET}${ESP_MOUNT}/EFI/$1"
  mkdir -p "${dir}"
  cp "${TARGET}/usr/lib/shim/shimx64.efi.signed" "${dir}/shimx64.efi"
  cp "${TARGET}/usr/lib/shim/mmx64.efi.signed" "${dir}/mmx64.efi"
}

sign_loader() { # $1=source path (target-side), $2=ESP subdirectory under EFI/
  local src="$1" dir="$2"
  ensure_mok_pem
  in_target "
    set -e
    sbsign --key '${MOK_KEY}' --cert '${MOK_PEM}' \
      --output '${ESP_MOUNT}/EFI/${dir}/grubx64.efi' '${src}'
  "
}

# Stage MOK enrollment: MokManager processes it at the next boot through
# shim; the user confirms with the account password. Never fatal: without
# efivars (some VMs, plain chroots) the request cannot be written — the
# system still boots with secure boot off and the command can be run on
# the real machine later.
stage_mok_enrollment() {
  local rc=0
  # mokutil --import hard-rejects passwords outside PASSWORD_MIN/MAX
  # (8-16 chars); don't even attempt the import with one.
  if [[ -n "${USER_PASSWORD}" ]] &&
    ((${#USER_PASSWORD} < 8 || ${#USER_PASSWORD} > 16)); then
    warn "user password is ${#USER_PASSWORD} chars; mokutil needs 8-16 —" \
      "MOK enrollment not staged; run 'mokutil --import ${MOK_CRT}' on the" \
      "installed system with a 8-16 char password."
    return 0
  fi
  if [[ -n "${USER_PASSWORD}" ]]; then
    printf '%s\n%s\n' "${USER_PASSWORD}" "${USER_PASSWORD}" |
      chroot "${TARGET}" mokutil --import "${MOK_CRT}" || rc=$?
  elif ((IS_INTERACTIVE)); then
    info "Choose a MOK password (you will re-enter it at first boot):"
    with_console chroot "${TARGET}" mokutil --import "${MOK_CRT}" || rc=$?
  else
    warn "No USER_PASSWORD and non-interactive: MOK enrollment not" \
      "staged. Run 'mokutil --import ${MOK_CRT}' on the installed system."
    return 0
  fi
  if ((rc != 0)); then
    warn "mokutil --import failed — usually no efivars in this" \
      "environment, or a password outside mokutil's 8-16 character" \
      "range. Run 'mokutil --import ${MOK_CRT}' on the installed system," \
      "then reboot and enroll at the MokManager screen."
  fi
}

# --- ZFSBootMenu -------------------------------------------------------------

# Download the ZFSBootMenu release EFI to $1. Asset filenames vary between
# releases, so the GitHub API supplies the real URL of the x86_64 release
# EFI (the 'recovery' variant is excluded by the 'release' match); the
# get.zfsbootmenu.org redirector is the fallback. Retries cover its
# intermittent 5xx responses. Also used by the cache phase.
fetch_zbm_efi() {
  local dest="$1" api="" url=""
  api="${ZBM_REPO_URL/github.com/api.github.com\/repos}/releases/latest"
  # The 'release' match must be confined to the filename: every asset URL
  # contains '/releases/download/', which would also match the recovery
  # variant.
  url="$(curl -fsSL --retry 3 "${api}" 2>/dev/null |
    grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 |
    grep -E '/[^/]*release[^/]*x86_64[^/]*\.EFI$' | head -n1 || true)"
  if [[ -n "${url}" ]]; then
    info "Fetching ZFSBootMenu asset: ${url##*/}"
    if curl -fsSL --retry 5 --retry-all-errors -o "${dest}" "${url}"; then
      return 0
    fi
    warn "Asset download failed (${url}); trying ${ZBM_EFI_URL}."
  else
    warn "Could not resolve a ZBM asset via the GitHub API; trying ${ZBM_EFI_URL}."
  fi
  curl -fsSL --retry 5 --retry-all-errors -o "${dest}" "${ZBM_EFI_URL}" ||
    fatal "Could not download ZFSBootMenu (API asset and redirector both failed)."
}

install_zbm() {
  local efi_src="${CACHE_DIR}/zfsbootmenu.EFI"
  if [[ ! -f "${efi_src}" ]]; then
    ((NETWORK_AVAILABLE)) || fatal "No cached ZBM binary and no network."
    mkdir -p "${CACHE_DIR}"
    fetch_zbm_efi "${efi_src}"
  fi
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/zbm"
  cp "${efi_src}" "${TARGET}${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi"
  # ZBM reads the kernel cmdline from this dataset property.
  zfs set org.zfsbootmenu:commandline="rw ${KERNEL_CMDLINE_EXTRA}" \
    "${ROOT_DATASET}"
  install_shim zbm
  sign_loader "${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi" zbm
  create_nvram_entry "ZFSBootMenu" '\EFI\zbm\shimx64.efi'
}

# --- GRUB --------------------------------------------------------------------

# Append GRUB chainloader menuentries for other OSes os-prober detects
# (Windows, etc.) to $1 (a grub.cfg path). The installer writes a STATIC
# grub.cfg (no grub-mkconfig), so os-prober is run here and its EFI-type
# entries become chainloader stanzas. Best-effort: no detection, a missing
# UUID, or an os-prober failure leaves just the Debian entry. Only EFI
# entries (the UEFI case) are added; linux/BIOS entries are noted and
# skipped. Logs go to the console, never into $1.
append_os_prober_entries() {
  local cfg="$1" probed="" line="" field1="" part="" efipath="" name="" uuid=""
  probed="$(in_target "os-prober" 2>/dev/null || true)"
  if [[ -z "${probed}" ]]; then
    info "os-prober: no other operating systems detected."
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    field1="${line%%:*}"
    name="$(printf '%s' "${line}" | cut -d: -f2)"
    if [[ "${line##*:}" != "efi" ]]; then
      info "os-prober: skipping non-EFI entry: ${name:-${field1}}"
      continue
    fi
    part="${field1%%@*}"
    efipath="${field1#*@}"
    uuid="$(in_target "blkid -s UUID -o value '${part}'" 2>/dev/null || true)"
    if [[ -z "${uuid}" ]]; then
      warn "os-prober: no UUID for ${part}; skipping '${name}'."
      continue
    fi
    info "os-prober: adding chainloader entry '${name}' (${part} ${uuid})."
    cat >>"${cfg}" <<EOF
menuentry "${name} (on ${part})" {
  insmod part_gpt
  insmod fat
  insmod chain
  search --no-floppy --fs-uuid --set=root ${uuid}
  chainloader ${efipath}
}
EOF
  done <<<"${probed}"
}

write_grub_cfg() {
  # grub-install --boot-directory=${ESP_MOUNT}/EFI/debian embeds the prefix
  # (ESP)/EFI/debian/grub/, so the cfg must live in that grub/ subdirectory.
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/debian/grub"
  cat >"${TARGET}${ESP_MOUNT}/EFI/debian/grub/grub.cfg" <<EOF
# Static config written by installer.sh; kernel copies are refreshed by
# hypr-deb-sync-esp.
# GRUB reads kernel copies from the ESP and never reads the ZFS pool.
set timeout=3
search --no-floppy --fs-uuid --set=root ${ESP_UUID}
menuentry "Debian ${SUITE} (ZFS root)" {
  linux /EFI/debian/vmlinuz $(kernel_cmdline)
  initrd /EFI/debian/initrd.img
}
EOF
  # Other-OS detection (Windows, ...). Static cfg means there is no
  # grub-mkconfig to honor GRUB_DISABLE_OS_PROBER, so run os-prober now and
  # append chainloader entries directly (before the copy below, so both cfg
  # paths carry them).
  if ((GRUB_OS_PROBER)); then
    append_os_prober_entries "${TARGET}${ESP_MOUNT}/EFI/debian/grub/grub.cfg"
  fi
  # The Debian-signed grubx64.efi reads (esp)/EFI/debian/grub.cfg (baked-in
  # prefix); the locally-built image reads EFI/debian/grub/grub.cfg. Same
  # content at both paths covers whichever image shim chain-loads.
  cp "${TARGET}${ESP_MOUNT}/EFI/debian/grub/grub.cfg" \
    "${TARGET}${ESP_MOUNT}/EFI/debian/grub.cfg"
}

install_grub() {
  local osprober_pkg=""
  ((GRUB_OS_PROBER)) && osprober_pkg="os-prober"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed ${osprober_pkg}
    grub-install --target=x86_64-efi --efi-directory=${ESP_MOUNT} \
      --boot-directory=${ESP_MOUNT}/EFI/debian --bootloader-id=debian \
      --no-nvram --uefi-secure-boot
  "
  write_esp_sync_hook
  run_esp_sync
  write_grub_cfg
  create_nvram_entry "debian" '\EFI\debian\shimx64.efi'
}

# --- systemd-boot --------------------------------------------------------------

find_systemd_boot_efi() {
  local src="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
  if [[ -f "${TARGET}${src}.signed" ]]; then
    printf '%s\n' "${src}.signed"
  elif [[ -f "${TARGET}${src}" ]]; then
    printf '%s\n' "${src}"
  else
    fatal "systemd-boot EFI binary not found after package installation."
  fi
}

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
  local sd_src=""
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
  install_shim systemd
  sd_src="$(find_systemd_boot_efi)" ||
    fatal "Could not locate the installed systemd-boot EFI binary."
  sign_loader "${sd_src}" systemd
  # --no-variables skips bootctl's NVRAM write (unreliable on a RAID1 ESP);
  # create the entry ourselves on both member disks.
  create_nvram_entry "Linux Boot Manager" '\EFI\systemd\shimx64.efi'
}

phase_boot() {
  detect_kernel
  case "${BOOTLOADER}" in
    zbm) install_zbm ;;
    grub) install_grub ;;
    systemd-boot) install_sdboot ;;
    *) fatal "BOOTLOADER not set (preflight should have ensured this)." ;;
  esac
  stage_mok_enrollment
}
