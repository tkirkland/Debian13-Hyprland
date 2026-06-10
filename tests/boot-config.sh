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
# grub-install's embedded prefix is (ESP)/EFI/debian/grub/, so the cfg must
# live in that subdirectory or GRUB drops to a rescue prompt.
assert_eq "1" "$(test -f "${tmp}/target/boot/efi/EFI/debian/grub/grub.cfg" &&
  echo 1)" "grub: cfg under EFI/debian/grub/"
out="$(cat "${tmp}/target/boot/efi/EFI/debian/grub/grub.cfg")"
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

# ZBM fetch prefers the direct GitHub release asset for the latest tag.
mkdir -p "${tmp}/bin"
export FAKE_LOG="${tmp}/curl.log"
make_fake "${tmp}/bin" git 'cat <<EOF
sha	refs/tags/v2.9.0
sha	refs/tags/v3.0.1
EOF'
# shellcheck disable=SC2016  # fake body must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" curl 'echo "curl $*" >> "${FAKE_LOG}"; exit 0'
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/60-hyprland.sh
  source scripts/50-boot.sh
  fetch_zbm_efi '${tmp}/zbm.EFI'
" >/dev/null
assert_contains "$(cat "${FAKE_LOG}")" \
  "https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1.EFI" \
  "zbm fetch uses direct release asset for latest tag"
assert_contains "$(cat "${FAKE_LOG}")" "--retry 5" \
  "zbm fetch retries transient errors"

finish_test
