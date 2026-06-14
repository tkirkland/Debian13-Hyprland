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

# os-prober (GRUB path): EFI entries (e.g. Windows) become chainloader
# stanzas appended to the static grub.cfg. Stub in_target to fake the
# os-prober + blkid output; logs must NOT leak into the cfg file.
op_file="${tmp}/op-grub.cfg"
: >"${op_file}"
bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  in_target() {
    case \"\$1\" in
      os-prober) echo '/dev/nvme9n1p1@/EFI/Microsoft/Boot/bootmgfw.efi:Windows Boot Manager:Windows:efi' ;;
      *blkid*) echo 'DEAD-BEEF' ;;
    esac
  }
  source scripts/50-boot.sh
  append_os_prober_entries '${op_file}'
" >/dev/null 2>&1
out="$(cat "${op_file}")"
assert_contains "${out}" 'menuentry "Windows Boot Manager (on /dev/nvme9n1p1)"' \
  "os-prober: detected EFI OS becomes a menuentry"
assert_contains "${out}" "chainloader /EFI/Microsoft/Boot/bootmgfw.efi" \
  "os-prober: chainloads the detected EFI binary"
assert_contains "${out}" "search --no-floppy --fs-uuid --set=root DEAD-BEEF" \
  "os-prober: targets the detected OS partition by UUID"
if printf '%s' "${out}" | grep -q '\[INFO\]'; then
  echo "  FAIL: log output leaked into grub.cfg" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: os-prober logs stay out of grub.cfg"
fi

# No other OS detected -> nothing appended (best-effort no-op).
op_none="${tmp}/op-none.cfg"
: >"${op_none}"
bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  in_target() { :; }
  source scripts/50-boot.sh
  append_os_prober_entries '${op_none}'
" >/dev/null 2>&1
if [[ -s "${op_none}" ]]; then
  echo "  FAIL: no-detection must append nothing" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: os-prober no-op when nothing detected"
fi

gen_cfg write_sdboot_entries
out="$(cat "${tmp}/target/boot/efi/loader/entries/debian.conf")"
assert_contains "${out}" "linux /EFI/debian/vmlinuz" "sd-boot: kernel"
assert_contains "${out}" "initrd /EFI/debian/initrd.img" "sd-boot: initrd"
assert_contains "${out}" "root=ZFS=PRECISION/ROOT/debian13" "sd-boot: ZFS root"

gen_cfg write_esp_sync_hook
out="$(cat "${tmp}/target/usr/local/sbin/hypr-deb-sync-esp")"
assert_contains "${out}" "vmlinuz" "hook copies kernel"
assert_contains "${out}" "initrd.img" "hook copies initrd"
assert_contains "${out}" "systemd-bootx64.efi.signed" \
  "hook prefers Debian's signed systemd-boot binary"

mkdir -p "${tmp}/target/usr/lib/systemd/boot/efi"
touch "${tmp}/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed"
out="$(gen_cfg find_systemd_boot_efi)"
assert_eq "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" "${out}" \
  "sd-boot selects Debian's signed-only package path"

rm "${tmp}/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed"
touch "${tmp}/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
out="$(gen_cfg find_systemd_boot_efi)"
assert_eq "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "${out}" \
  "sd-boot falls back to the unsigned package path"

# ZBM fetch resolves the real asset URL via the GitHub API and must pick
# the release variant, not recovery (whose URL also contains '/releases/').
mkdir -p "${tmp}/bin"
export FAKE_LOG="${tmp}/curl.log"
# shellcheck disable=SC2016  # fake body must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" curl 'echo "curl $*" >> "${FAKE_LOG}"
case "$*" in
  *api.github.com*)
    echo "      \"browser_download_url\": \"https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zfsbootmenu-recovery-x86_64-v3.1.0.EFI\""
    echo "      \"browser_download_url\": \"https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zfsbootmenu-release-x86_64-v3.1.0.EFI\""
    ;;
esac
exit 0'
PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/50-boot.sh
  fetch_zbm_efi '${tmp}/zbm.EFI'
" >/dev/null
assert_contains "$(cat "${FAKE_LOG}")" \
  "-o ${tmp}/zbm.EFI https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.1.0/zfsbootmenu-release-x86_64-v3.1.0.EFI" \
  "zbm fetch downloads the API-resolved release asset"
if grep -- "-o ${tmp}/zbm.EFI.*recovery" "${FAKE_LOG}" >/dev/null; then
  echo "  FAIL: recovery asset must not be selected" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: recovery asset not selected"
fi
assert_contains "$(cat "${FAKE_LOG}")" "--retry 5" \
  "zbm fetch retries transient errors"

finish_test
