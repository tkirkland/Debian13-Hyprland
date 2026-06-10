#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: bootloader config generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target/boot/efi"

gen_cfg() { # $1 = function to call
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/50-boot.sh
    TARGET='${tmp}/target'
    KVER=6.12.0-amd64
    ESP_UUID=AAAA-1111
    $1
  "
}

gen_cfg write_grub_cfg
out="$(cat "${tmp}/target/boot/efi/EFI/debian/grub.cfg")"
assert_contains "${out}" "root=ZFS=PRECISION/ROOT/debian13" "grub: ZFS root"
assert_contains "${out}" "/EFI/debian/vmlinuz" "grub: ESP kernel copy path"
assert_contains "${out}" "search --no-floppy --fs-uuid --set=root AAAA-1111" \
  "grub: finds ESP by UUID"

gen_cfg write_sdboot_entries
out="$(cat "${tmp}/target/boot/efi/loader/entries/debian.conf")"
assert_contains "${out}" "linux /EFI/debian/vmlinuz" "sd-boot: kernel"
assert_contains "${out}" "initrd /EFI/debian/initrd.img" "sd-boot: initrd"
assert_contains "${out}" "root=ZFS=PRECISION/ROOT/debian13" "sd-boot: ZFS root"

gen_cfg write_esp_sync_hook
out="$(cat "${tmp}/target/usr/local/sbin/hypr-deb-sync-esp")"
assert_contains "${out}" "vmlinuz" "hook copies kernel"
assert_contains "${out}" "initrd.img" "hook copies initrd"

finish_test
