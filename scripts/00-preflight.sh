# shellcheck shell=bash
# Preflight: root check, virt detection, disk selection/validation, host
# detection, tool bootstrap, network probe, clock sync.

require_root() {
  [[ "$(id -u)" == "0" ]] || fatal "Must run as root."
}

# Secure boot must be OFF while installing: the storage phase loads the
# live session's own ZFS dkms module, which is locally built and not
# enrolled in this firmware — a secure-boot (lockdown) kernel refuses it
# and the install would die at pool creation. The INSTALLED system is
# fully secure-boot ready; only the live session cannot be.
check_secureboot_disabled() {
  local var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  local enabled=0 sb_out=""
  if command -v mokutil >/dev/null 2>&1; then
    sb_out="$(mokutil --sb-state 2>/dev/null || true)"
  fi
  if [[ -n "${sb_out}" ]]; then
    if grep -qi 'SecureBoot enabled' <<<"${sb_out}"; then
      enabled=1
    fi
  elif [[ -r "${var}" ]]; then
    # mokutil missing or unresponsive: read the efivar directly. Payload
    # byte 5 (after the 4-byte attribute header): 1 = enforcing. An empty
    # od read compares unequal and passes — the safe direction.
    if [[ "$(od -An -tu1 -j4 -N1 "${var}" 2>/dev/null |
      tr -d '[:space:]')" == "1" ]]; then
      enabled=1
    fi
  fi
  ((enabled)) || return 0
  fatal "Secure boot is ENABLED in this live environment — the installer" \
    "cannot proceed. The live session must load its own locally-built ZFS" \
    "module, which this firmware does not trust, so pool creation would" \
    "fail. Do this instead:" \
    "(1) reboot into firmware setup and DISABLE secure boot;" \
    "(2) run the installer (everything gets pre-signed);" \
    "(3) boot the installed system — at the blue MokManager screen choose" \
    "'Enroll MOK' and enter your user password;" \
    "(4) re-enable secure boot in firmware. It will boot."
}

# Identity settings are interpolated into root chroot command strings;
# restrict them to safe character sets (injection surface).
validate_identity_settings() {
  [[ "${TARGET_USERNAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    fatal "Invalid TARGET_USERNAME '${TARGET_USERNAME}'."
  [[ "${TIMEZONE}" =~ ^[A-Za-z0-9_+/-]+$ ]] ||
    fatal "Invalid TIMEZONE '${TIMEZONE}'."
  [[ "${LOCALE}" =~ ^[A-Za-z0-9_.@-]+$ ]] ||
    fatal "Invalid LOCALE '${LOCALE}'."
  [[ "${TARGET_HOSTNAME}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] ||
    fatal "Invalid TARGET_HOSTNAME '${TARGET_HOSTNAME}'."
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  [[ -n "${VIRT_TYPE}" ]] || VIRT_TYPE="none"
  info "Virtualization: ${VIRT_TYPE}"
}

# Internal whole disk check shared by both modes (reference project logic).
is_internal_whole_disk() {
  local disk="$1" type="" rm="" tran=""
  type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | tr -d '[:space:]')"
  rm="$(lsblk -dn -o RM "${disk}" 2>/dev/null | tr -d '[:space:]')"
  tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${type}" == "disk" ]] || return 1
  [[ "${rm}" == "0" ]] || return 1
  [[ "${tran}" != "usb" ]]
}

validate_by_id_disk() {
  local disk="$1" real_path=""
  [[ "${disk}" == /dev/disk/by-id/* ]] ||
    fatal "Disk must be a /dev/disk/by-id path: ${disk}"
  [[ -b "${disk}" ]] || fatal "Not a block device: ${disk}"
  real_path="$(readlink -f "${disk}")"
  [[ "${real_path}" =~ ^/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)$ ]] ||
    fatal "'${disk}' resolves to '${real_path}' — expected nvmeXnY, sdX, or vdX."
}

# True if any partition (or the disk) has a mountpoint — excludes the live
# medium and any in-use disk from VM candidacy.
disk_has_mounts() {
  local disk="$1"
  [[ -n "$(lsblk -n -o MOUNTPOINTS "${disk}" 2>/dev/null | tr -d '[:space:]')" ]]
}

vm_detect_disks() {
  local name="" type="" rm="" tran="" candidates=() rejected=()
  while read -r name type rm tran; do
    [[ "${type}" == "disk" ]] || continue
    if [[ "${rm}" != "0" ]]; then
      rejected+=("/dev/${name}[removable]")
      continue
    fi
    if [[ "${tran}" == "usb" ]]; then
      rejected+=("/dev/${name}[usb]")
      continue
    fi
    if [[ ! "${name}" =~ ^(vd[a-z]+|sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]]; then
      rejected+=("/dev/${name}[name]")
      continue
    fi
    if disk_has_mounts "/dev/${name}"; then
      rejected+=("/dev/${name}[mounted]")
      continue
    fi
    candidates+=("/dev/${name}")
  done < <(lsblk -dn -o NAME,TYPE,RM,TRAN)

  ((${#candidates[@]} == 3)) || fatal \
    "VM mode needs exactly 3 eligible disks, found ${#candidates[@]}:" \
    "${candidates[*]:-none}. Rejected: ${rejected[*]:-none}." \
    "If a previous run left mounts behind, run --phase=cleanup first."

  DISK1="${candidates[0]}"
  DISK2="${candidates[1]}"
  DISK3="${candidates[2]}"
}

# A resumed run must not re-detect VM disks: the targets carry the
# in-progress installation (possibly mounted), so detection would exclude
# them. The first successful selection is persisted and reused; --fresh
# discards it along with the phase stamps.
load_saved_disks() {
  [[ -f "${STATE_DIR}/disks" ]] || return 1
  local d1="" d2="" d3=""
  {
    read -r d1
    read -r d2
    read -r d3
  } <"${STATE_DIR}/disks"
  if [[ ! -b "${d1}" || ! -b "${d2}" || ! -b "${d3}" ]]; then
    warn "Saved disk selection is stale (${STATE_DIR}/disks); re-detecting."
    rm -f "${STATE_DIR}/disks"
    return 1
  fi
  DISK1="${d1}"
  DISK2="${d2}"
  DISK3="${d3}"
}

save_disks() {
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "${DISK1}" "${DISK2}" "${DISK3}" >"${STATE_DIR}/disks"
}

select_disks() {
  local d=""
  if [[ "${VIRT_TYPE}" == "none" ]]; then
    info "BARE METAL mode: fixed target disks only."
    validate_by_id_disk "${DISK1}"
    validate_by_id_disk "${DISK2}"
    validate_by_id_disk "${DISK3}"
    is_internal_whole_disk "$(readlink -f "${DISK1}")" ||
      fatal "${DISK1} is not an internal whole disk"
    is_internal_whole_disk "$(readlink -f "${DISK2}")" ||
      fatal "${DISK2} is not an internal whole disk"
    is_internal_whole_disk "$(readlink -f "${DISK3}")" ||
      fatal "${DISK3} is not an internal whole disk"
  else
    info "VM TEST mode (${VIRT_TYPE}): auto-detecting target disks."
    # Explicit VM_DISK overrides win over a saved selection; a saved
    # selection wins over re-detection (resume safety).
    if [[ -n "${VM_DISK1:-}" || -n "${VM_DISK2:-}" || -n "${VM_DISK3:-}" ]]; then
      [[ -n "${VM_DISK1:-}" && -n "${VM_DISK2:-}" && -n "${VM_DISK3:-}" ]] ||
        fatal "Set all of VM_DISK1/VM_DISK2/VM_DISK3 or none."
      DISK1="${VM_DISK1}"
      DISK2="${VM_DISK2}"
      DISK3="${VM_DISK3}"
      for d in "${DISK1}" "${DISK2}" "${DISK3}"; do
        [[ -b "${d}" ]] || fatal "VM_DISK override is not a block device: ${d}"
        is_internal_whole_disk "${d}" ||
          fatal "VM_DISK override is not an internal whole disk: ${d}"
        disk_has_mounts "${d}" &&
          fatal "VM_DISK override has mounted filesystems: ${d}"
      done
    elif load_saved_disks; then
      info "Reusing disk selection from previous run (${STATE_DIR}/disks)."
    else
      vm_detect_disks
    fi
    # Warn if the smallest disk landed in an EFI-carrying role.
    local s1 s2 s3
    s1="$(blockdev --getsize64 "${DISK1}" 2>/dev/null || echo 0)"
    s2="$(blockdev --getsize64 "${DISK2}" 2>/dev/null || echo 0)"
    s3="$(blockdev --getsize64 "${DISK3}" 2>/dev/null || echo 0)"
    if ((s3 > s1 || s3 > s2)); then
      warn "DISK3 (${DISK3}) is larger than an EFI-carrying disk; check ordering."
    fi
  fi
  [[ "${DISK1}" != "${DISK2}" && "${DISK1}" != "${DISK3}" &&
    "${DISK2}" != "${DISK3}" ]] || fatal "Target disks must be distinct."
  save_disks
  info "Targets: DISK1=${DISK1} DISK2=${DISK2} DISK3=${DISK3}"
}

check_network() {
  if ((OFFLINE)); then
    NETWORK_AVAILABLE=0
    info "Offline mode forced (--offline)."
    return 0
  fi
  if curl -fsI --max-time 10 "${MIRROR}/dists/${SUITE}/Release" >/dev/null 2>&1; then
    NETWORK_AVAILABLE=1
    info "Network: mirror reachable (${MIRROR})"
  else
    NETWORK_AVAILABLE=0
    warn "Network: mirror unreachable — falling back to offline cache."
  fi
}

detect_live_environment() {
  if grep -qE '(^| )boot=live( |$)' /proc/cmdline 2>/dev/null ||
    mountpoint -q /run/live/medium 2>/dev/null; then
    info "Host: live environment"
    # Live overlays are RAM-backed; warn if the cache would land on tmpfs.
    local fstype=""
    fstype="$(stat -f -c %T "$(dirname "${CACHE_DIR}")" 2>/dev/null || true)"
    if [[ "${fstype}" == "tmpfs" || "${fstype}" == "overlayfs" ]]; then
      warn "CACHE_DIR=${CACHE_DIR} is RAM-backed; use --cache-dir on real storage."
    fi
  else
    info "Host: installed system"
  fi
}

bootstrap_live_tools() {
  local missing=() pkg="" need_zfs_build=0 running_kernel=""
  running_kernel="$(uname -r)"
  local -A pkg_probe=(
    [debootstrap]=debootstrap [gdisk]=sgdisk [parted]=partprobe [mdadm]=mdadm
    [dosfstools]=mkfs.vfat [zfsutils-linux]=zpool [apt-utils]=apt-ftparchive
    [git]=git [curl]=curl [efibootmgr]=efibootmgr [rsync]=rsync
    [psmisc]=fuser [openssl]=openssl
  )
  for pkg in "${!pkg_probe[@]}"; do
    command -v "${pkg_probe[${pkg}]}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  # zfs-dkms has no binary probe of its own: a loadable module for the
  # RUNNING kernel is the requirement. Headers must match the running
  # kernel, not the archive's newest (see LIVE_KERNEL_HEADERS).
  if ! modinfo zfs >/dev/null 2>&1; then
    need_zfs_build=1
    missing+=(zfs-dkms "${LIVE_KERNEL_HEADERS}")
  fi
  ((${#missing[@]} == 0)) && {
    info "All live tools present."
    return 0
  }

  info "Missing live tools: ${missing[*]}"
  if ((NETWORK_AVAILABLE)); then
    apt-get update || warn "apt-get update failed; trying install with existing lists."
    if ((need_zfs_build)) &&
      ! apt-cache show "${LIVE_KERNEL_HEADERS}" >/dev/null 2>&1; then
      fatal "Mirror has no ${LIVE_KERNEL_HEADERS} — the live ISO's kernel" \
        "(${running_kernel}) is older than the archive carries. Boot a live" \
        "ISO matching the current Debian point release, or use an offline" \
        "cache built for this kernel."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  elif cache_repo_exists; then
    install_from_cache_repo "${missing[@]}"
  else
    fatal "No network and no cache; cannot install: ${missing[*]}"
  fi

  if ! modprobe zfs 2>/dev/null; then
    # zfs-dkms's postinst builds for kernels whose headers were present at
    # install time; force a build for the running kernel if it was missed.
    info "Building ZFS module for ${running_kernel} via dkms..."
    dkms autoinstall -k "${running_kernel}" || true
    modprobe zfs || fatal "ZFS module unavailable for the running kernel" \
      "(${running_kernel}). zfs-dkms must build against this kernel's" \
      "headers (${LIVE_KERNEL_HEADERS})."
  fi
}

sync_clock() {
  ((NETWORK_AVAILABLE)) || return 0
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
  fi
}

phase_preflight() {
  require_root
  check_secureboot_disabled
  validate_identity_settings
  ((${#ADDON_PACKAGES[@]} == 0)) ||
    info "Addons: ${#ADDON_PACKAGES[@]} extra package(s) from addons/*.list"
  local deb_count=0 run_count=0 sh_count=0
  deb_count="$(compgen -G 'addons/*.deb' 2>/dev/null | wc -l)" || deb_count=0
  run_count="$(compgen -G 'addons/*.run' 2>/dev/null | wc -l)" || run_count=0
  sh_count="$(compgen -G 'addons/*.sh' 2>/dev/null | wc -l)" || sh_count=0
  ((deb_count + run_count + sh_count == 0)) ||
    info "Addons: ${deb_count} .deb to install, ${sh_count} script(s)" \
      "to run in target, ${run_count} .run to stage"
  detect_virt
  detect_live_environment
  check_network
  select_disks
  bootstrap_live_tools
  sync_clock
}
