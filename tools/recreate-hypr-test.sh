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
# UEFI firmware (OVMF). Secure Boot must be SUPPORTED but not ENFORCING:
#  - plain OVMF_CODE_4M.fd has no SecureBoot variable at all, so mokutil
#    --import fails ("This system doesn't support Secure Boot") and MOK
#    enrollment never gets staged — the exact VM-only failure seen 2026-07-03;
#  - the .ms pair enrolls Microsoft keys -> SB ENFORCING -> the installer
#    preflight aborts (the live session must load its self-built, unsigned
#    ZFS module).
# OVMF_CODE_4M.secboot.fd with the BLANK vars template is the middle ground:
# SB-capable firmware, no keys enrolled (setup mode, SB off) — preflight
# passes AND mokutil can stage. Per /usr/share/qemu/firmware/50-edk2-*.json
# this build requires SMM (q35 machine type), enabled in step 4.
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
NVRAM=$POOL/hypr-test_VARS.fd

# Quick media toggle — no recreate. --eject pulls the ISO out of the DVD so a
# reboot lands on the installed disk instead of relaunching the installer;
# --insert seats it back for the next install run.
case "${1:-}" in
  --eject | --insert)
    flags=(--config)
    [ "$(sudo virsh -c "$URI" domstate "$VM" 2>/dev/null)" = "running" ] && flags+=(--live)
    if [ "$1" = "--eject" ]; then
      sudo virsh -c "$URI" change-media "$VM" sda --eject "${flags[@]}"
    else
      [ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
      sudo virsh -c "$URI" change-media "$VM" sda "$ISO" --insert "${flags[@]}"
    fi
    exit 0
    ;;
  "") ;;
  *)
    echo "usage: ${0##*/} [--eject|--insert]  (no args = full recreate)"
    exit 1
    ;;
esac

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

# 4. Make the VM UEFI (OVMF, SB-capable + setup mode, see firmware comment).
#    Forced explicitly every run so it is correct regardless of the domain's
#    prior firmware. Reset the per-domain NVRAM so EFI boot variables start
#    blank, matching the clean-disk intent — libvirt recreates it from the
#    template on next start. loader.secure=yes + smm are what the secboot
#    OVMF build requires to run (they do NOT enforce SB — no keys enrolled).
sudo rm -f "$NVRAM"
sudo virt-xml -c "$URI" "$VM" --edit --features smm.state=on
sudo virt-xml -c "$URI" "$VM" --edit \
  --boot loader="$OVMF_CODE",loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram="$NVRAM",nvram.template="$OVMF_VARS_TEMPLATE"

# 5. Re-seat the ISO in the CD-ROM and set boot order to CD then disk.
sudo virsh -c "$URI" change-media "$VM" sda --eject --config 2>/dev/null || true
sudo virsh -c "$URI" change-media "$VM" sda "$ISO" --insert --config
sudo virt-xml -c "$URI" "$VM" --edit --boot cdrom,hd

# 6. Boot it and open the console.
sudo virsh -c "$URI" start "$VM"
echo ">> '$VM' started — launching virt-viewer..."
# Detached launch. --attach: the domain's spice graphics has listen=none (no
# socket), so the display is only reachable by attaching through the libvirt
# connection. Opens on the focused monitor; for deterministic display-1
# pinning add a persistent hl.window_rule for class virt-viewer in
# hyprland.lua — exec_cmd can't pin workspace inline on 0.55.
setsid virt-viewer --connect "$URI" --attach "$VM" >/dev/null 2>&1 </dev/null &
