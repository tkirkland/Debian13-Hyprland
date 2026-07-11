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
  [[ "${XKB_LAYOUT}" =~ ^[a-z][a-z0-9]*(,[a-z][a-z0-9]*)*$ ]] ||
    fatal "Invalid XKB_LAYOUT '${XKB_LAYOUT}'."
  [[ "${XKB_VARIANT}" =~ ^[A-Za-z0-9_,:-]*$ ]] ||
    fatal "Invalid XKB_VARIANT '${XKB_VARIANT}'."
  [[ "${XKB_MODEL}" =~ ^[a-zA-Z0-9_-]+$ ]] ||
    fatal "Invalid XKB_MODEL '${XKB_MODEL}'."
  [[ "${XKB_OPTIONS}" =~ ^[A-Za-z0-9_:,-]*$ ]] ||
    fatal "Invalid XKB_OPTIONS '${XKB_OPTIONS}'."
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

# Whether the on-ISO package store was found (set by discover_iso_repo).
ISO_STORE_PRESENT=0

# Discover the on-ISO package store. When booted from our offline ISO the store
# is an apt-ftparchive repo (dists/ + pool/) shipped either embedded in the live
# root (ISO_LIVE_REPO, current ISOs) or as a top-level directory on the medium
# (ISO_MEDIUM_REPO, older ISOs). Probe the in-root path first. Its presence — a
# Packages index under dists/ — points the offline machinery at it (CACHE_REPO_DIR)
# and makes offline-from-store the DEFAULT mode (see check_network). This runs
# regardless of the --offline/--online flags so a forced-offline install also
# installs from the store.
discover_iso_repo() {
  ISO_STORE_PRESENT=0
  local root="" idx=""
  for root in "${ISO_LIVE_REPO}" "${ISO_MEDIUM_REPO}"; do
    [[ -n "${root}" ]] || continue
    idx="$(find "${root}/dists" -type f -name Packages -print -quit \
      2>/dev/null || true)"
    [[ -n "${idx}" ]] || continue
    ISO_STORE_PRESENT=1
    CACHE_REPO_DIR="${root}"
    info "On-ISO package store found: ${CACHE_REPO_DIR}"
    return 0
  done
}

# Decide the install mode. Precedence:
#   --offline  -> forced offline (no network), install from CACHE_REPO_DIR
#   --online   -> forced online, probe the mirror even if the store is present
#   otherwise  -> offline when the on-ISO store is present, online (probe)
#                 when it is absent
check_network() {
  if ((OFFLINE)); then
    NETWORK_AVAILABLE=0
    info "Mode: offline forced (--offline); repo ${CACHE_REPO_DIR}"
    return 0
  fi
  if ((ONLINE)); then
    probe_network
    info "Mode: online forced (--online); network ${NETWORK_AVAILABLE}"
    return 0
  fi
  if ((ISO_STORE_PRESENT)); then
    NETWORK_AVAILABLE=0
    info "Mode: offline by default (on-ISO store present; --online to override);" \
      "repo ${CACHE_REPO_DIR}"
    return 0
  fi
  probe_network
}

# Probe the configured mirror; sets NETWORK_AVAILABLE.
probe_network() {
  if curl -fsI --max-time 10 "${MIRROR}/dists/${SUITE}/Release" >/dev/null 2>&1; then
    NETWORK_AVAILABLE=1
    info "Network: mirror reachable (${MIRROR})"
  else
    NETWORK_AVAILABLE=0
    warn "Network: mirror unreachable — falling back to offline cache."
  fi
}

# NVIDIA GPU detection (issue #4). Runs BEFORE preflight installs tools,
# so it reads sysfs directly instead of lspci: vendor 0x10de with a
# display-controller class (0x03xxxx) means an NVIDIA GPU is present.
detect_nvidia_gpu() {
  HAS_NVIDIA_GPU=0
  # shellcheck disable=SC2034  # Cross-module global consumed after sourcing.
  NVIDIA_GPU_PRETURING=0
  local dev="" vendor="" class="" device=""
  for dev in "${SYS_PCI_PATH}"/*; do
    [[ -r "${dev}/vendor" && -r "${dev}/class" ]] || continue
    read -r vendor <"${dev}/vendor"
    read -r class <"${dev}/class"
    if [[ "${vendor}" == "0x10de" && "${class}" == 0x03* ]]; then
      # shellcheck disable=SC2034  # Cross-module global consumed after sourcing.
      HAS_NVIDIA_GPU=1
      # The open kernel modules need Turing (TU1xx) or newer: those carry PCI
      # device ids >= 0x1E00, while Pascal/Maxwell and older sit below and need
      # the proprietary driver. An unreadable/odd id is treated as open-capable.
      if [[ -r "${dev}/device" ]]; then
        read -r device <"${dev}/device"
        if [[ "${device}" =~ ^0x[0-9a-fA-F]+$ ]] && ((device < 0x1E00)); then
          # shellcheck disable=SC2034  # Cross-module global consumed after sourcing.
          NVIDIA_GPU_PRETURING=1
          info "NVIDIA GPU detected (PCI ${dev##*/}, device ${device}):" \
            "pre-Turing — open kernel modules unsupported, will use proprietary."
          return 0
        fi
      fi
      info "NVIDIA GPU detected (PCI ${dev##*/})."
      return 0
    fi
  done
  return 0
}

detect_live_environment() {
  if grep -qE '(^| )boot=live( |$)' /proc/cmdline 2>/dev/null ||
    mountpoint -q /run/live/medium 2>/dev/null; then
    info "Host: live environment"
  else
    info "Host: installed system"
  fi
}

bootstrap_live_tools() {
  local missing=() pkg="" need_zfs_build=0 running_kernel="" kernel_pin=""
  running_kernel="$(uname -r)"
  # KERNEL_PINNED (written by build-iso step_pin_kernel) names the kernel the
  # store's prebuilt zfs artifacts were built for. A mismatch is loud but NOT
  # fatal: the module baked into the live squashfs keeps this session working;
  # only the offline zfs fallback below is degraded.
  if cache_repo_exists && [[ -f "${CACHE_REPO_DIR}/KERNEL_PINNED" ]]; then
    kernel_pin="$(<"${CACHE_REPO_DIR}/KERNEL_PINNED")"
    [[ "${kernel_pin}" == "${running_kernel}" ]] ||
      warn "This medium was built for kernel ${kernel_pin} but" \
        "${running_kernel} is running — the offline zfs path may be degraded."
  fi
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
  # RUNNING kernel is the requirement (normally short-circuited: our ISOs
  # bake the module into the live squashfs at build time). Headers must match
  # the running kernel, not the archive's newest (see LIVE_KERNEL_HEADERS).
  if ! modinfo zfs >/dev/null 2>&1; then
    need_zfs_build=1
    # Offline store whose pin matches the running kernel: install the PREBUILT
    # upstream kmod deb from the pool — no compile. Any other case (no store,
    # pin mismatch, online) keeps the dkms path.
    if [[ -n "${kernel_pin}" && "${kernel_pin}" == "${running_kernel}" ]] &&
      ! ((NETWORK_AVAILABLE)); then
      missing+=("openzfs-zfs-modules-${running_kernel}")
    else
      missing+=(zfs-dkms "${LIVE_KERNEL_HEADERS}")
    fi
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

# Debian 13 apt verifies archive signatures with sqv, which HARD-FAILS
# outside the signature's validity window ("Not live until ..."), so a
# skewed clock (VM RTC drift, hardware clock on local time) kills
# debootstrap/apt mid-install. NTP enablement alone is fire-and-forget —
# timesyncd may be absent or still converging — so when the clock
# disagrees with the mirror's HTTP Date header by more than 5 minutes,
# set it from that header directly and persist to the hardware clock.
sync_clock() {
  ((NETWORK_AVAILABLE)) || return 0
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
  fi
  local header="" remote_epoch=0 local_epoch=0 skew=0
  header="$(curl -fsI --max-time 10 "${MIRROR}/dists/${SUITE}/Release" \
    2>/dev/null | grep -i '^[Dd]ate:' | head -n1 | sed 's/^[Dd]ate: *//' |
    tr -d '\r' || true)"
  [[ -n "${header}" ]] || return 0
  remote_epoch="$(date -d "${header}" +%s 2>/dev/null || echo 0)"
  ((remote_epoch > 0)) || return 0
  local_epoch="$(date +%s)"
  skew=$((remote_epoch - local_epoch))
  ((skew < 0)) && skew=$((-skew))
  ((skew <= 300)) && return 0
  warn "System clock is off by ${skew}s vs the mirror — setting it from" \
    "the mirror's Date header (sqv rejects skewed signatures)."
  if date -u -s "@${remote_epoch}" >/dev/null 2>&1; then
    if command -v hwclock >/dev/null 2>&1; then
      hwclock --systohc 2>/dev/null || true
    fi
  else
    warn "Could not set the clock; apt signature verification may fail" \
      "('Not live until ...'). Set it manually and re-run."
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
  discover_iso_repo
  check_network
  select_disks
  bootstrap_live_tools
  sync_clock
}
