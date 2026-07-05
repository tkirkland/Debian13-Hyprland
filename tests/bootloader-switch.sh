#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: bootloader switch (offline repo wiring, NVRAM retirement, BootOrder)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target"

# Run install_grub/install_sdboot with every side effect stubbed except the
# offline-repo wiring calls, which are logged so their presence and order can
# be asserted. Stubs come AFTER the source so they win at call time.
# $4: mountpoint exit status (0 = store already bind-mounted by bootstrap).
# $5: 1 = make the in-target apt-get install fail (failure-path teardown).
run_install() { # $1=install fn  $2=NETWORK_AVAILABLE  $3=log  [$4=mounted] [$5=fail]
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/50-boot.sh
    TARGET='${tmp}/target'
    ISO_TEMP_SOURCE_REL='etc/apt/sources.list.d/hypr-iso-temp.sources'
    NETWORK_AVAILABLE=$2
    LOG='$3'
    mountpoint() { return ${4:-1}; }
    in_target() { echo \"in_target: \$1\" >>\"\${LOG}\"; }
    if ((${5:-0})); then
      in_target() {
        echo \"in_target: \$1\" >>\"\${LOG}\"
        [[ \$1 != *'apt-get install'* ]]
      }
    fi
    setup_target_iso_repo() { echo 'setup_target_iso_repo' >>\"\${LOG}\"; }
    teardown_target_iso_repo() { echo 'teardown_target_iso_repo' >>\"\${LOG}\"; }
    write_esp_sync_hook() { :; }
    run_esp_sync() { :; }
    write_grub_cfg() { :; }
    write_sdboot_entries() { :; }
    install_shim() { :; }
    sign_loader() { :; }
    find_systemd_boot_efi() { echo x.efi.signed; }
    create_nvram_entry() { :; }
    $1
  " >/dev/null 2>&1
}

# Offline (NETWORK_AVAILABLE=0), no temp source in the target (standalone
# --phase=boot): both loaders must wire the on-ISO store around their apt run.
log="${tmp}/grub-offline.log"
run_install install_grub 0 "${log}"
out="$(cat "${log}")"
assert_contains "${out}" "setup_target_iso_repo" "grub offline: wires the on-ISO repo"
assert_contains "${out}" "apt-get update" "grub offline: refreshes apt indexes"
assert_contains "${out}" "apt-get install -y grub-efi-amd64" "grub offline: installs packages"
assert_eq "setup_target_iso_repo" "$(head -n1 "${log}")" "grub offline: wiring precedes apt"
assert_eq "teardown_target_iso_repo" "$(tail -n1 "${log}")" "grub offline: tears its wiring down"

log="${tmp}/sdboot-offline.log"
run_install install_sdboot 0 "${log}"
out="$(cat "${log}")"
assert_contains "${out}" "setup_target_iso_repo" "sd-boot offline: wires the on-ISO repo"
assert_contains "${out}" "apt-get install -y systemd-boot" "sd-boot offline: installs packages"
assert_eq "teardown_target_iso_repo" "$(tail -n1 "${log}")" "sd-boot offline: tears its wiring down"

# Full offline run: phase_bootstrap already bind-mounted the store; the boot
# phase must NOT re-wire and must NOT tear down what it does not own.
log="${tmp}/grub-prewired.log"
run_install install_grub 0 "${log}" 0
out="$(cat "${log}")"
if [[ "${out}" == *setup_target_iso_repo* || "${out}" == *teardown_target_iso_repo* ]]; then
  echo "  FAIL: pre-wired run must not touch the repo wiring" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: pre-wired offline run leaves bootstrap's wiring alone"
fi

# Stale temp source with NO bind mount (debris from an aborted run): the file
# alone must not suppress wiring, or every retry fails at apt.
mkdir -p "${tmp}/target/etc/apt/sources.list.d"
touch "${tmp}/target/etc/apt/sources.list.d/hypr-iso-temp.sources"
log="${tmp}/grub-stale.log"
run_install install_grub 0 "${log}"
assert_contains "$(cat "${log}")" "setup_target_iso_repo" \
  "stale temp source without a mount: re-wires the repo"
rm "${tmp}/target/etc/apt/sources.list.d/hypr-iso-temp.sources"

# Failure path: an apt/loader failure inside the target must still tear the
# wiring down (fatal exits, but never with a stale hypr-iso-temp.sources
# left on the installed system).
log="${tmp}/grub-fail.log"
run_install install_grub 0 "${log}" 1 1 && {
  echo "  FAIL: failed install must exit nonzero" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
}
assert_contains "$(cat "${log}")" "teardown_target_iso_repo" \
  "failed install: wiring is torn down before the fatal"

# Online: apt resolves from the network; no repo wiring at all.
log="${tmp}/grub-online.log"
run_install install_grub 1 "${log}"
out="$(cat "${log}")"
if [[ "${out}" == *setup_target_iso_repo* ]]; then
  echo "  FAIL: online run must not wire the on-ISO repo" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: online run skips the repo wiring"
fi

# --- NVRAM retirement + BootOrder against a fake efibootmgr -------------------
mkdir -p "${tmp}/bin"
export FAKE_LOG="${tmp}/efi.log"
# shellcheck disable=SC2016  # fake body must keep $*/${FAKE_LOG} literal until run
make_fake "${tmp}/bin" efibootmgr 'echo "efibootmgr $*" >> "${FAKE_LOG}"
if [[ $# -eq 0 ]]; then
  printf "BootCurrent: 0001\nTimeout: 1 seconds\nBootOrder: 0001,0002,0003,0004\n"
  printf "Boot0001* ZFSBootMenu\tHD(1,GPT,aa)/File(\\\\EFI\\\\zbm\\\\shimx64.efi)\n"
  printf "Boot0002* debian\tHD(1,GPT,aa)/File(\\\\EFI\\\\debian\\\\shimx64.efi)\n"
  printf "Boot0003* Linux Boot Manager\tHD(1,GPT,aa)/File(\\\\EFI\\\\systemd\\\\shimx64.efi)\n"
  printf "Boot0004* Windows Boot Manager\tHD(2,GPT,bb)/File(\\\\EFI\\\\Microsoft\\\\bootmgfw.efi)\n"
  printf "Boot0005* debian\tHD(1,GPT,bb)/File(\\\\EFI\\\\debian\\\\shimx64.efi)\n"
fi
exit 0'

# Our ESP member partitions carry PARTUUID "aa"; Boot0005 is a co-installed
# foreign Debian's GRUB entry on another disk ("bb") that must never be touched.
run_efi() { # $1=function call
  : >"${FAKE_LOG}"
  PATH="${tmp}/bin:${PATH}" bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/50-boot.sh
    esp_partuuid_regex() { echo aa; }
    $1
  " >/dev/null 2>&1
}

# Switching to grub retires ZBM and sd-boot entries — and ONLY those: the
# new loader's own entry and foreign entries (Windows) must survive.
run_efi 'retire_other_loaders debian'
out="$(cat "${FAKE_LOG}")"
assert_contains "${out}" "efibootmgr -b 0001 -B" "retire: deletes ZFSBootMenu entry"
assert_contains "${out}" "efibootmgr -b 0003 -B" "retire: deletes Linux Boot Manager entry"
for kept in 0002 0004 0005; do
  if [[ "${out}" == *"-b ${kept} -B"* ]]; then
    echo "  FAIL: retire must not delete Boot${kept}" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    echo "  ok: retire keeps Boot${kept}"
  fi
done

# Switching to zbm retires OUR "debian" entry (0002, on our ESP) but not the
# foreign OS's identically-labeled entry on another disk (0005).
run_efi 'retire_other_loaders ZFSBootMenu'
out="$(cat "${FAKE_LOG}")"
assert_contains "${out}" "efibootmgr -b 0002 -B" "retire: deletes our debian entry"
if [[ "${out}" == *"-b 0005 -B"* ]]; then
  echo "  FAIL: retire must not delete a foreign OS's debian entry" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: retire keeps the foreign debian entry (other disk)"
fi

# BootOrder heads with ZBM (0001) after a switch to grub (0002): the new
# loader's entries must be moved to the front, the rest kept in order.
run_efi 'ensure_boot_order_head debian'
assert_contains "$(cat "${FAKE_LOG}")" "efibootmgr -o 0002,0001,0003,0004" \
  "boot order: new loader moved to the head, rest preserved"

# Already first -> no rewrite.
run_efi 'ensure_boot_order_head ZFSBootMenu'
if grep -q -- " -o " "${FAKE_LOG}"; then
  echo "  FAIL: BootOrder already correct must not be rewritten" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: boot order untouched when already first"
fi

# Integration: phase_boot itself must retire the other loaders and enforce
# BootOrder after the install, with the loader mapped to the right label
# (grub -> "debian"). A regression dropping those calls reproduces issue #50.
run_efi 'BOOTLOADER=grub
  detect_kernel() { :; }
  install_grub() { :; }
  stage_mok_enrollment() { :; }
  phase_boot'
out="$(cat "${FAKE_LOG}")"
assert_contains "${out}" "efibootmgr -b 0001 -B" "phase_boot: retires ZFSBootMenu"
assert_contains "${out}" "efibootmgr -b 0003 -B" "phase_boot: retires Linux Boot Manager"
assert_contains "${out}" "efibootmgr -o 0002,0001,0003,0004" \
  "phase_boot: puts the new loader at the head of BootOrder"

finish_test
