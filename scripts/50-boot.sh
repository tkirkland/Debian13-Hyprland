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
  mkdir -p "${TARGET}/usr/sbin" \
    "${TARGET}/etc/kernel/postinst.d" "${TARGET}/etc/initramfs/post-update.d"
  cat >"${TARGET}/usr/sbin/hypr-deb-sync-esp" <<'EOF'
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
  chmod +x "${TARGET}/usr/sbin/hypr-deb-sync-esp"
  local hook=""
  for hook in "${TARGET}/etc/kernel/postinst.d/zz-hypr-deb-esp" \
    "${TARGET}/etc/initramfs/post-update.d/zz-hypr-deb-esp"; do
    cat >"${hook}" <<'EOF'
#!/bin/sh
exec /usr/sbin/hypr-deb-sync-esp
EOF
    chmod +x "${hook}"
  done
}

run_esp_sync() {
  in_target "/usr/sbin/hypr-deb-sync-esp"
}

# PARTUUIDs of this install's ESP member partitions (partition 1 on DISK1 and
# DISK2), as a lowercase ERE alternation for matching efibootmgr device paths.
# Empty when blkid cannot identify them.
esp_partuuid_regex() {
  local disk="" uuid="" re=""
  for disk in "${DISK1}" "${DISK2}"; do
    uuid="$(blkid -s PARTUUID -o value "$(part_dev "${disk}" 1)" 2>/dev/null || true)"
    [[ -n "${uuid}" ]] && re+="${re:+|}${uuid,,}"
  done
  printf '%s' "${re}"
}

# NVRAM label per loader — the single source for entry creation, retirement,
# and BootOrder enforcement. "debian" and "Linux Boot Manager" deliberately
# match the stock GRUB/systemd-boot labels; the ESP filter in
# nvram_nums_for_label keeps a foreign OS's same-label entries safe.
declare -A LOADER_LABELS=(
  [zbm]="ZFSBootMenu"
  [grub]="debian"
  [systemd-boot]="Linux Boot Manager"
)

# PARTUUIDs of every partition currently present on the machine, as a
# lowercase ERE alternation. Empty when blkid cannot enumerate them.
all_partuuid_regex() {
  blkid -s PARTUUID -o value 2>/dev/null |
    tr '[:upper:]' '[:lower:]' | paste -sd'|'
}

# Print the Boot numbers whose label matches $1 exactly AND whose device path
# is on this install's ESP, one per line. Exact-label match: the label is
# everything between "BootXXXX* " and the tab-separated device path. The ESP
# filter keeps a co-installed foreign OS's entry (stock GRUB is also labeled
# "debian", stock systemd-boot "Linux Boot Manager") off another disk safe.
# When the ESP PARTUUIDs cannot be read, FAIL CLOSED: matching by label alone
# would hand a foreign OS's entry to the delete paths.
# $2=1 additionally matches DANGLING entries — same label but a GPT PARTUUID
# that no longer exists on any disk (our own entry from before a repartition;
# label-scoped, so only labels we manage are ever considered). Delete paths
# want these gone; BootOrder must never be rebuilt around them.
nvram_nums_for_label() { # $1=exact label  [$2=1: include dangling entries]
  local uuids="" all="" dangling="${2:-0}"
  uuids="$(esp_partuuid_regex)"
  if [[ -z "${uuids}" ]]; then
    warn "Cannot identify the ESP partitions; leaving NVRAM entries for '$1' alone."
    return 0
  fi
  ((dangling)) && all="$(all_partuuid_regex)"
  # No partition listing -> cannot prove anything dangling; fail closed.
  [[ -z "${all}" ]] && dangling=0
  efibootmgr | awk -F'\t' -v lbl="$1" -v uuids="${uuids}" \
    -v all="${all}" -v dangling="${dangling}" '
    $1 ~ /^Boot[0-9A-F]{4}[* ] / {
      entry = $1; num = substr(entry, 5, 4)
      sub(/^Boot[0-9A-F]{4}[* ] /, "", entry)
      if (entry != lbl) next
      dev = tolower($2)
      if (dev ~ uuids) { print num; next }
      if (dangling && match(dev, /gpt,[0-9a-f-]+/)) {
        pu = substr(dev, RSTART + 4, RLENGTH - 4)
        if (index("|" all "|", "|" pu "|") == 0) print num
      }
    }'
}

delete_nvram_entries() { # $1=exact label
  local bootnum=""
  while read -r bootnum; do
    efibootmgr -b "${bootnum}" -B >/dev/null ||
      warn "Could not delete stale NVRAM entry Boot${bootnum} ($1)"
  done < <(nvram_nums_for_label "$1" 1)
}

create_nvram_entry() { # $1=label $2=loader-path (backslash form)
  local label="$1" loader="$2" disk="" pnum=1
  # Delete stale entries with the same label so re-runs don't accumulate
  # duplicates.
  delete_nvram_entries "${label}"
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
  local out=""
  if [[ -n "${USER_PASSWORD}" ]]; then
    out="$(printf '%s\n%s\n' "${USER_PASSWORD}" "${USER_PASSWORD}" |
      chroot "${TARGET}" mokutil --import "${MOK_CRT}" 2>&1)" || rc=$?
  elif ((IS_INTERACTIVE)); then
    info "Choose a MOK password (you will re-enter it at first boot):"
    with_console chroot "${TARGET}" mokutil --import "${MOK_CRT}" || rc=$?
  else
    warn "No USER_PASSWORD and non-interactive: MOK enrollment not" \
      "staged. Run 'mokutil --import ${MOK_CRT}' on the installed system."
    return 0
  fi
  if ((rc != 0)); then
    # Surface mokutil's own words: "This system doesn't support Secure Boot"
    # means SB-incapable firmware (e.g. plain OVMF in a VM — testbed needs the
    # secboot build, see tools/recreate-hypr-test.sh); other causes include no
    # efivars in the environment or a password outside mokutil's 8-16 chars.
    warn "mokutil --import failed${out:+: ${out}}. Run 'mokutil --import" \
      "${MOK_CRT}' on the installed system (SB-capable firmware required)," \
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
  # Resolve the ZFSBootMenu EFI. The build ships it inside the on-ISO store
  # (${CACHE_REPO_DIR}/zfsbootmenu.EFI, e.g. /opt/hypr-deb/repo or
  # /run/live/medium/hypr-repo, which preflight points CACHE_REPO_DIR at) -- so
  # an offline install finds it there with no second cache. With no store and a
  # network, fall back to a live download into a temp file.
  local efi_src=""
  if [[ -f "${CACHE_REPO_DIR}/zfsbootmenu.EFI" ]]; then
    efi_src="${CACHE_REPO_DIR}/zfsbootmenu.EFI"
  else
    ((NETWORK_AVAILABLE)) || fatal "ZFSBootMenu EFI not found offline (looked in" \
      "${CACHE_REPO_DIR}). The ISO is missing it; rebuild the ISO" \
      "or install with --bootloader=grub."
    efi_src="$(mktemp)"
    fetch_zbm_efi "${efi_src}"
  fi
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/zbm"
  cp "${efi_src}" "${TARGET}${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi"
  # ZBM reads the kernel cmdline from this dataset property.
  zfs set org.zfsbootmenu:commandline="rw ${KERNEL_CMDLINE_EXTRA}" \
    "${ROOT_DATASET}"
  install_shim zbm
  sign_loader "${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi" zbm
  create_nvram_entry "${LOADER_LABELS[zbm]}" '\EFI\zbm\shimx64.efi'
}

# --- Offline package wiring ----------------------------------------------------
# grub/systemd-boot apt-install their packages inside the target. On a
# standalone --phase=boot (bootloader switch on an existing install) nothing
# has wired the on-ISO package store into the target — that is done by
# phase_bootstrap / online_install_prebuilt only — so an offline switch would
# abort at apt. Stand the store up with the existing bootstrap machinery and
# tear down ONLY what this phase set up: on a full offline run the store is
# already bind-mounted (phase_bootstrap) and phase_cleanup owns its teardown.
BOOT_REPO_WIRED=0

wire_offline_repo() {
  BOOT_REPO_WIRED=0
  ((NETWORK_AVAILABLE)) && return 0
  # Gate on the bind MOUNT, not the temp source file: a stale source left by
  # an aborted run (no trap removes it) would otherwise skip wiring and leave
  # apt resolving an unmounted file:// URI on every retry. Re-wiring over
  # stale debris is safe — setup_target_iso_repo is idempotent.
  mountpoint -q "${TARGET}${TARGET_ISO_REPO_MNT}" && return 0
  setup_target_iso_repo
  BOOT_REPO_WIRED=1
  in_target "apt-get update" || {
    unwire_offline_repo
    fatal "apt index refresh from the on-ISO package store failed."
  }
}

unwire_offline_repo() {
  if ((BOOT_REPO_WIRED)); then
    teardown_target_iso_repo
    BOOT_REPO_WIRED=0
  fi
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
  wire_offline_repo
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed ${osprober_pkg}
    grub-install --target=x86_64-efi --efi-directory=${ESP_MOUNT} \
      --boot-directory=${ESP_MOUNT}/EFI/debian --bootloader-id=debian \
      --no-nvram --uefi-secure-boot
  " || {
    unwire_offline_repo
    fatal "GRUB package install / grub-install failed inside the target."
  }
  unwire_offline_repo
  write_esp_sync_hook
  run_esp_sync
  write_grub_cfg
  create_nvram_entry "${LOADER_LABELS[grub]}" '\EFI\debian\shimx64.efi'
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
  wire_offline_repo
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y systemd-boot
    SYSTEMD_RELAX_ESP_CHECKS=1 bootctl install --no-variables \
      --esp-path=${ESP_MOUNT}
  " || {
    unwire_offline_repo
    fatal "systemd-boot package install / bootctl install failed inside the target."
  }
  unwire_offline_repo
  write_esp_sync_hook
  run_esp_sync
  write_sdboot_entries
  install_shim systemd
  sd_src="$(find_systemd_boot_efi)" ||
    fatal "Could not locate the installed systemd-boot EFI binary."
  sign_loader "${sd_src}" systemd
  # --no-variables skips bootctl's NVRAM write (unreliable on a RAID1 ESP);
  # create the entry ourselves on both member disks.
  create_nvram_entry "${LOADER_LABELS[systemd-boot]}" '\EFI\systemd\shimx64.efi'
}

# After a bootloader switch (--phase=boot with a different --bootloader) the
# previous loader's NVRAM entries would keep winning the boot; delete the
# OTHER two loaders' entries by exact label.
# ponytail: the retired loaders' ESP files are deliberately left in place —
# they are the recovery path if the new loader fails to boot.
retire_other_loaders() { # $1=label of the just-installed loader
  local label=""
  for label in "${LOADER_LABELS[@]}"; do
    [[ "${label}" == "$1" ]] || delete_nvram_entries "${label}"
  done
}

# Firmware (Dell especially) reorders BootOrder behind our back, so a
# successful install can still boot the old loader. Verify the new loader's
# entries head BootOrder and rewrite it if not.
ensure_boot_order_head() { # $1=label of the just-installed loader
  local nums="" order="" head="" rest="" n=""
  nums="$(nvram_nums_for_label "$1" | paste -sd,)"
  if [[ -z "${nums}" ]]; then
    warn "No NVRAM entry labeled '$1'; cannot verify BootOrder."
    return 0
  fi
  order="$(efibootmgr | awk '$1 == "BootOrder:" { print $2 }')"
  head="${order%%,*}"
  if [[ ",${nums}," == *",${head},"* ]]; then
    return 0
  fi
  # Our entries first, the rest of the existing order preserved behind them.
  for n in ${order//,/ }; do
    [[ ",${nums}," == *",${n},"* ]] || rest+=",${n}"
  done
  info "BootOrder does not lead with '$1'; setting ${nums}${rest}."
  efibootmgr -o "${nums}${rest}" >/dev/null ||
    warn "Could not set BootOrder; put '$1' first in the firmware setup."
}

phase_boot() {
  local label=""
  detect_kernel
  case "${BOOTLOADER}" in
    zbm) install_zbm ;;
    grub) install_grub ;;
    systemd-boot) install_sdboot ;;
    *) fatal "BOOTLOADER not set (preflight should have ensured this)." ;;
  esac
  label="${LOADER_LABELS[${BOOTLOADER}]}"
  retire_other_loaders "${label}"
  ensure_boot_order_head "${label}"
  stage_mok_enrollment
}
