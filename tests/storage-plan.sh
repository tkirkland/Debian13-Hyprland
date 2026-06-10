#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: storage command plan"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
export FAKE_LOG="${tmp}/calls.log"

for cmd in sgdisk mdadm zpool zfs wipefs blkdiscard partprobe udevadm \
  mkfs.vfat mkfs.ext4 mkswap swapoff umount; do
  make_fake "${tmp}/bin" "${cmd}" \
    "echo \"${cmd} \$*\" >> \"\${FAKE_LOG}\"; exit 0"
done
# zpool list must fail (no pool) so destroy path is a no-op.
# shellcheck disable=SC2016  # fake body must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" zpool '
echo "zpool $*" >> "${FAKE_LOG}"
[[ "$1" == "list" || "$1" == "import" ]] && exit 1
exit 0'

# wait_for_block_devices is stubbed: the fake partitions are never real
# block devices, and the command plan is what is under test here.
PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/20-storage.sh
  wait_for_block_devices() { :; }
  DISK1=/dev/vda; DISK2=/dev/vdb; DISK3=/dev/vdc
  destroy_existing_layout
  wipe_target_disks
  partition_target_disks
  create_arrays
  format_arrays
  create_pool_and_datasets
' >/dev/null

calls="$(cat "${FAKE_LOG}")"
assert_contains "${calls}" \
  "sgdisk -n1:1M:+2G -t1:EF00 -c1:EFI1 -n2:0:+4G -t2:FD00 -c2:SWAP1 -n3:0:0 -t3:BF00 -c3:ZFS1 /dev/vda" \
  "DISK1 three-partition plan"
assert_contains "${calls}" \
  "sgdisk -n1:1M:+4G -t1:FD00 -c1:SWAP3 -n2:0:0 -t2:BF00 -c2:ZFS3 /dev/vdc" \
  "DISK3 two-partition plan"
assert_contains "${calls}" \
  "mdadm --create /dev/md/efi --level=1 --raid-devices=2 --metadata=1.0" \
  "EFI RAID1 metadata 1.0"
assert_contains "${calls}" \
  "/dev/vda2 /dev/vdb2 /dev/vdc1" "swap RAID0 members"
assert_contains "${calls}" \
  "raidz1 /dev/vda3 /dev/vdb3 /dev/vdc2" "raidz1 members"
if grep -q "md/boot" "${FAKE_LOG}"; then
  echo "  FAIL: md/boot must not exist in amended layout" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no md/boot in amended layout"
fi

# Downloads must be canmount=noauto at creation: mounting it before
# adduser would pre-create a root-owned /home/<user>.
assert_contains "${calls}" \
  "zfs create -u -o canmount=noauto -o mountpoint=/home/me/Downloads -o compression=off PRECISION/home/Downloads" \
  "Downloads dataset created canmount=noauto"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/20-storage.sh
  part_dev /dev/disk/by-id/nvme-eui.abc 3; echo
  part_dev /dev/vda 3; echo
  part_dev /dev/nvme0n1 3')"
assert_eq "/dev/disk/by-id/nvme-eui.abc-part3
/dev/vda3
/dev/nvme0n1p3" "${out}" "part_dev naming for by-id, vdX, nvme"

finish_test
