# shellcheck shell=bash
# Preflight: root check, virt detection, disk selection/validation, host
# detection, tool bootstrap, network probe, clock sync.

require_root() {
  [[ "$(id -u)" == "0" ]] || fatal "Must run as root."
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
  local name="" type="" rm="" candidates=()
  while read -r name type rm _; do
    [[ "${type}" == "disk" && "${rm}" == "0" ]] || continue
    [[ "${name}" =~ ^(vd[a-z]+|sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
    disk_has_mounts "/dev/${name}" && continue
    candidates+=("/dev/${name}")
  done < <(lsblk -dn -o NAME,TYPE,RM,TRAN)

  ((${#candidates[@]} == 3)) || fatal \
    "VM mode needs exactly 3 eligible disks, found ${#candidates[@]}: ${candidates[*]:-none}"

  DISK1="${candidates[0]}"
  DISK2="${candidates[1]}"
  DISK3="${candidates[2]}"
}

select_disks() {
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
    if [[ -n "${VM_DISK1:-}" || -n "${VM_DISK2:-}" || -n "${VM_DISK3:-}" ]]; then
      [[ -n "${VM_DISK1:-}" && -n "${VM_DISK2:-}" && -n "${VM_DISK3:-}" ]] ||
        fatal "Set all of VM_DISK1/VM_DISK2/VM_DISK3 or none."
      DISK1="${VM_DISK1}"
      DISK2="${VM_DISK2}"
      DISK3="${VM_DISK3}"
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
  local missing=() pkg=""
  local -A pkg_probe=(
    [debootstrap]=debootstrap [gdisk]=sgdisk [mdadm]=mdadm
    [dosfstools]=mkfs.vfat [zfsutils-linux]=zpool [apt-utils]=apt-ftparchive
    [git]=git [curl]=curl [efibootmgr]=efibootmgr [rsync]=rsync
  )
  for pkg in "${!pkg_probe[@]}"; do
    command -v "${pkg_probe[${pkg}]}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  # zfs-dkms has no binary probe of its own: presence of the module suffices.
  if ! modinfo zfs >/dev/null 2>&1; then
    missing+=(zfs-dkms linux-headers-amd64)
  fi
  ((${#missing[@]} == 0)) && {
    info "All live tools present."
    return 0
  }

  info "Missing live tools: ${missing[*]}"
  if ((NETWORK_AVAILABLE)); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  elif cache_repo_exists; then
    install_from_cache_repo "${missing[@]}"
  else
    fatal "No network and no cache; cannot install: ${missing[*]}"
  fi
  modprobe zfs || fatal "ZFS kernel module unavailable after bootstrap."
}

sync_clock() {
  ((NETWORK_AVAILABLE)) || return 0
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
  fi
}

phase_preflight() {
  require_root
  detect_virt
  detect_live_environment
  check_network
  select_disks
  bootstrap_live_tools
  sync_clock
}
