# shellcheck shell=bash
# Storage: destroy stale layout, wipe, partition, mdadm arrays, ZFS pool.
# Amended layout (no md/boot; kernels live on the ZFS root dataset):
#   DISK1/DISK2: part1 EFI(${EFI_SIZE}) part2 SWAP(${SWAP_SIZE}) part3 ZFS
#   DISK3:       part1 SWAP(${SWAP_SIZE}) part2 ZFS
#   /dev/md/efi:  FAT32 RAID1 (metadata 1.0) DISK1p1+DISK2p1
#   /dev/md/swap: RAID0 DISK1p2+DISK2p2+DISK3p1
#   ZFS raidz1:   DISK1p3+DISK2p3+DISK3p2

# Partition device name for disk $1, partition number $2.
part_dev() {
  local disk="$1" num="$2"
  if [[ "${disk}" == /dev/disk/by-id/* ]]; then
    printf '%s-part%s' "${disk}" "${num}"
  elif [[ "${disk}" =~ [0-9]$ ]]; then
    printf '%sp%s' "${disk}" "${num}"
  else
    printf '%s%s' "${disk}" "${num}"
  fi
}

wait_for_block_devices() {
  local device="" remaining=50 missing=0
  udevadm settle
  while ((remaining > 0)); do
    missing=0
    for device in "$@"; do
      [[ -b "${device}" ]] || {
        missing=1
        break
      }
    done
    ((missing == 0)) && return 0
    sleep 0.2
    remaining=$((remaining - 1))
  done
  fatal "Timed out waiting for block devices: $*"
}

destroy_existing_layout() {
  info "Destroying any existing pool ${POOL_NAME} and arrays..."
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zfs unmount -af 2>/dev/null || true
    umount -R "${TARGET}" 2>/dev/null || true
    zpool export -f "${POOL_NAME}" 2>/dev/null ||
      zpool destroy -f "${POOL_NAME}" 2>/dev/null ||
      fatal "Cannot export or destroy pool ${POOL_NAME}."
  elif zpool import -N -f -d /dev/disk/by-id "${POOL_NAME}" 2>/dev/null; then
    info "Stale pool ${POOL_NAME} imported; destroying..."
    zpool destroy -f "${POOL_NAME}" ||
      fatal "Imported stale pool ${POOL_NAME} but could not destroy it."
  fi

  swapoff -a 2>/dev/null || true
  local arr=""
  for arr in /dev/md/efi /dev/md/swap; do
    mdadm --stop "${arr}" 2>/dev/null || true
    mdadm --remove "${arr}" 2>/dev/null || true
  done
  local md_device=""
  for md_device in /dev/md[0-9]*; do
    [[ -b "${md_device}" ]] || continue
    mdadm --stop "${md_device}" 2>/dev/null || true
  done

  local member=""
  for member in \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK1}" 2)" \
    "$(part_dev "${DISK2}" 1)" "$(part_dev "${DISK2}" 2)" \
    "$(part_dev "${DISK3}" 1)"; do
    mdadm --zero-superblock "${member}" 2>/dev/null || true
  done
}

wipe_target_disks() {
  local disk=""
  for disk in "${DISK1}" "${DISK2}" "${DISK3}"; do
    info "Wiping ${disk}..."
    wipefs -af "${disk}" 2>/dev/null || true
    sgdisk --zap-all "${disk}"
    blkdiscard -f "${disk}" 2>/dev/null || true
  done
}

partition_target_disks() {
  local disk="" n=1
  for disk in "${DISK1}" "${DISK2}"; do
    info "Partitioning ${disk}: EFI${n}(${EFI_SIZE}) SWAP${n}(${SWAP_SIZE}) ZFS${n}(rest)..."
    sgdisk \
      -n1:1M:+"${EFI_SIZE}" -t1:EF00 -c1:"EFI${n}" \
      -n2:0:+"${SWAP_SIZE}" -t2:FD00 -c2:"SWAP${n}" \
      -n3:0:0 -t3:BF00 -c3:"ZFS${n}" \
      "${disk}"
    n=$((n + 1))
  done

  info "Partitioning ${DISK3}: SWAP3(${SWAP_SIZE}) ZFS3(rest)..."
  sgdisk \
    -n1:1M:+"${SWAP_SIZE}" -t1:FD00 -c1:SWAP3 \
    -n2:0:0 -t2:BF00 -c2:ZFS3 \
    "${DISK3}"

  partprobe "${DISK1}" "${DISK2}" "${DISK3}"
  wait_for_block_devices \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK1}" 2)" "$(part_dev "${DISK1}" 3)" \
    "$(part_dev "${DISK2}" 1)" "$(part_dev "${DISK2}" 2)" "$(part_dev "${DISK2}" 3)" \
    "$(part_dev "${DISK3}" 1)" "$(part_dev "${DISK3}" 2)"
}

create_arrays() {
  info "Creating RAID1 /dev/md/efi..."
  mdadm --create /dev/md/efi \
    --level=1 --raid-devices=2 --metadata=1.0 \
    --bitmap=internal --homehost=any --name=efi --run \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK2}" 1)"

  info "Creating RAID0 /dev/md/swap..."
  mdadm --create /dev/md/swap \
    --level=0 --raid-devices=3 --metadata=1.2 \
    --chunk=512 --homehost=any --name=swap --run \
    "$(part_dev "${DISK1}" 2)" "$(part_dev "${DISK2}" 2)" \
    "$(part_dev "${DISK3}" 1)"

  wait_for_block_devices /dev/md/efi /dev/md/swap
}

format_arrays() {
  info "Formatting /dev/md/efi (FAT32, label=EFI)..."
  mkfs.vfat -F 32 -n EFI /dev/md/efi
  info "Formatting /dev/md/swap..."
  mkswap -L swap /dev/md/swap
}

create_pool_and_datasets() {
  info "Creating ZFS pool ${POOL_NAME} (raidz1)..."
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posix \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=zstd \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -R "${TARGET}" \
    "${POOL_NAME}" \
    raidz1 \
    "$(part_dev "${DISK1}" 3)" "$(part_dev "${DISK2}" 3)" \
    "$(part_dev "${DISK3}" 2)"

  info "Creating dataset hierarchy..."
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"
  zfs create -o canmount=noauto -o mountpoint=/ "${ROOT_DATASET}"
  zfs create -u -o mountpoint=/home "${POOL_NAME}/home"
  # canmount=noauto until create_user (40-system) flips it: mounting this
  # dataset earlier would pre-create a root-owned /home/<user>, and adduser
  # would then refuse to populate it (no skel files, wrong ownership).
  zfs create -u -o canmount=noauto \
    -o mountpoint="/home/${TARGET_USERNAME}/Downloads" \
    -o compression=off "${POOL_NAME}/home/Downloads"
  zfs create -u -o mountpoint=/srv "${POOL_NAME}/srv"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var"
  zfs create -u -o mountpoint=/var/cache \
    -o com.sun:auto-snapshot=false "${POOL_NAME}/var/cache"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var/lib"
  # mountpoint=none is deliberate: Docker's ZFS storage driver manages its
  # own child datasets here; set a mountpoint manually for a plain directory.
  zfs create -o mountpoint=none "${POOL_NAME}/var/lib/docker"
  zfs create -u -o mountpoint=/var/log "${POOL_NAME}/var/log"
  zfs create -u -o mountpoint=/var/tmp \
    -o com.sun:auto-snapshot=false "${POOL_NAME}/var/tmp"

  zpool set bootfs="${ROOT_DATASET}" "${POOL_NAME}"
}

phase_storage() {
  confirm_destruction
  destroy_existing_layout
  wipe_target_disks
  partition_target_disks
  create_arrays
  format_arrays
  create_pool_and_datasets
}
