#!/usr/bin/env bash
# Recreate the hypr-test KVM testbed: wipe its 3 disks, recreate them blank,
# and boot it from the offline installer ISO. The domain definition itself
# (CPU/RAM/devices) is left intact — only the disks and boot media are reset.
set -euo pipefail

VM=hypr-test
URI=qemu:///system
POOL=/var/lib/libvirt/images
ISO=${HOME}/isos/Debian13-Hyprland-offline.iso
DISK_SIZE=40G
DISKS=("$POOL/hypr-test-disk1.qcow2" "$POOL/hypr-test-disk2.qcow2" "$POOL/hypr-test-disk3.qcow2")
# UEFI firmware (OVMF). Secure Boot stays OFF: the installer preflight aborts
# under a Secure-Boot firmware ("live session must load its self-built ZFS
# module"), so use the plain *_4M.fd pair, never the .secboot variants.
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
NVRAM=$POOL/hypr-test_VARS.fd

echo ">> Recreating '$VM': wiping 3 disks, rebuilding blank, booting from ISO."

# 1. Force the VM off if it's running (ignore error if already stopped).
sudo virsh -c "$URI" destroy "$VM" 2>/dev/null || true

# 2. Wipe and recreate the three blank virtio disks.
for d in "${DISKS[@]}"; do
  sudo rm -f "$d"
  sudo qemu-img create -f qcow2 "$d" "$DISK_SIZE"
  sudo chown libvirt-qemu:libvirt-qemu "$d"
done

# 3. Make sure the installer ISO is in the pool and qemu can read it.
[ -f "$ISO" ] || {
  echo "ISO not found: $ISO"
  exit 1
}

# 4. Make the VM UEFI (OVMF, Secure Boot OFF). Forced explicitly every run so it
#    is correct regardless of the domain's prior firmware. Reset the per-domain
#    NVRAM so EFI boot variables start blank, matching the clean-disk intent —
#    libvirt recreates it from the template on next start.
sudo rm -f "$NVRAM"
sudo virt-xml -c "$URI" "$VM" --edit \
  --boot loader="$OVMF_CODE",loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram="$NVRAM",nvram.template="$OVMF_VARS_TEMPLATE"

# 5. Re-seat the ISO in the CD-ROM and set boot order to CD then disk.
sudo virsh -c "$URI" change-media "$VM" sda --eject --config 2>/dev/null || true
sudo virsh -c "$URI" change-media "$VM" sda "$ISO" --insert --config
sudo virt-xml -c "$URI" "$VM" --edit --boot cdrom,hd

# 6. Boot it and open the console.
sudo virsh -c "$URI" start "$VM"
echo ">> '$VM' started — launching virt-viewer..."
# Plain detached launch (verified working). Opens on the focused monitor; for
# deterministic display-1 pinning add a persistent hl.window_rule for class
# virt-viewer in hyprland.lua — exec_cmd can't pin workspace inline on 0.55.
setsid virt-viewer --connect "$URI" "$VM" >/dev/null 2>&1 </dev/null &
