#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: virt-gated disk selection"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

setup_env() { # $1 = systemd-detect-virt output, $2 = lsblk disk table
  make_fake "${tmp}/bin" systemd-detect-virt "echo '$1'"
  make_fake "${tmp}/bin" lsblk "
case \"\$*\" in
  *-o\ NAME,TYPE,RM,TRAN*) cat <<'TABLE'
$2
TABLE
    ;;
  *-o\ TYPE\ *) echo disk ;;   # per-disk queries from is_internal_whole_disk
  *-o\ RM\ *) echo 0 ;;
  *-o\ TRAN\ *) exit 0 ;;      # empty TRAN (virtio) must stay eligible
  *MOUNTPOINTS*) exit 0 ;;   # nothing mounted on candidates
esac"
}

run_select() {
  PATH="${tmp}/bin:${PATH}" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_virt
    select_disks
    echo "${VIRT_TYPE}|${DISK1}|${DISK2}|${DISK3}"
  '
}

# info() logs to stdout; only the final echo line is under test.
last_line() { tail -n 1; }

# VM with exactly three virtio disks -> auto-detected in name order.
setup_env "kvm" "vda disk 0
vdb disk 0
vdc disk 0"
out="$(run_select | last_line)"
assert_eq "kvm|/dev/vda|/dev/vdb|/dev/vdc" "${out}" "VM auto-detect, 3 disks"

# VM with two disks -> hard failure.
setup_env "kvm" "vda disk 0
vdb disk 0"
assert_fails "VM with 2 disks fails" run_select

# VM with four disks -> hard failure (never guess).
setup_env "kvm" "vda disk 0
vdb disk 0
vdc disk 0
vdd disk 0"
assert_fails "VM with 4 disks fails" run_select

# VM mode honors VM_DISK overrides. Overrides now pass real validation
# ([[ -b ]] cannot be stubbed), so use host block devices /dev/sd{a,b,c};
# the fake lsblk answers the per-disk TYPE/RM/TRAN/MOUNTPOINTS queries.
setup_env "qemu" "vda disk 0
vdb disk 0
vdc disk 0"
out="$(VM_DISK1=/dev/sdc VM_DISK2=/dev/sdb VM_DISK3=/dev/sda \
  PATH="${tmp}/bin:${PATH}" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_virt; select_disks
    echo "${DISK1}|${DISK2}|${DISK3}"' | last_line)"
assert_eq "/dev/sdc|/dev/sdb|/dev/sda" "${out}" "VM_DISK overrides honored"

# Bare metal: fixed ids retained, no detection (lsblk table ignored).
# The fixed by-id devices do not exist on the test host, so device
# validation is stubbed; this exercises selection logic only.
setup_env "none" "sda disk 0"
out="$(PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/00-preflight.sh
  validate_by_id_disk() { :; }
  is_internal_whole_disk() { :; }
  detect_virt; select_disks
  echo "${DISK1}"' | last_line)"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" \
  "bare metal keeps fixed by-id paths"

# Bare metal must IGNORE VM_DISK overrides.
out="$(VM_DISK1=/dev/sdz PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/00-preflight.sh
  validate_by_id_disk() { :; }
  is_internal_whole_disk() { :; }
  detect_virt; select_disks
  echo "${DISK1}"' | last_line)"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" \
  "VM_DISK overrides ignored on bare metal"

finish_test
