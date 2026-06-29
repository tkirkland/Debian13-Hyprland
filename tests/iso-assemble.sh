#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../tools/iso-assemble.sh"     # main is guarded, so sourcing is inert

echo "test: iso-assemble repo layout validation"
good="$(mktemp -d)"; mkdir -p "${good}/dists/trixie" "${good}/pool"
bad="$(mktemp -d)"
validate_repo_layout "${good}" && echo "  ok: valid repo layout accepted" \
  || { echo "  FAIL: valid layout rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
assert_fails "missing pool/dists rejected" validate_repo_layout "${bad}"
rm -rf "${good}" "${bad}"

echo "test: stage_live_payload embeds repo (+ installer) under the live root"
repo="$(mktemp -d)"; mkdir -p "${repo}/dists/trixie" "${repo}/pool"; echo x >"${repo}/pool/a.deb"
inst="$(mktemp -d)"; printf '#!/bin/sh\n' >"${inst}/installer.sh"; chmod +x "${inst}/installer.sh"
stage="$(mktemp -d)"
stage_live_payload "${stage}" "${repo}" "${inst}"
base="${stage}${LIVE_STORE_ROOT}"
if [[ -f "${base}/${LIVE_REPO_SUBDIR}/pool/a.deb" && -d "${base}/${LIVE_REPO_SUBDIR}/dists" ]]; then
  echo "  ok: repo embedded at ${LIVE_STORE_ROOT}/${LIVE_REPO_SUBDIR}"
else
  echo "  FAIL: repo not embedded under the live root" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
if [[ -x "${base}/${LIVE_INSTALLER_SUBDIR}/installer.sh" ]]; then
  echo "  ok: installer embedded with exec bit preserved"
else
  echo "  FAIL: installer not embedded (or exec bit lost)" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
# Convenience symlink in the live home points at the embedded entry (absolute,
# so it resolves against the live root at runtime — not the stage dir).
link="${stage}${LIVE_USER_HOME}/${LIVE_INSTALLER_ENTRY}"
want="${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/${LIVE_INSTALLER_ENTRY}"
if [[ -L "${link}" && "$(readlink "${link}")" == "${want}" ]]; then
  echo "  ok: ~/${LIVE_INSTALLER_ENTRY} symlink -> ${want}"
else
  echo "  FAIL: live-home installer symlink missing or wrong target" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
# A REAL (non-symlink) unattended launcher sits alongside the installer symlink.
# It must carry the unattended flags a symlink cannot, run the embedded installer
# as root, and (with the default EMPTY password) still be valid bash.
auto="${stage}${LIVE_USER_HOME}/${LIVE_AUTOINSTALL_ENTRY}"
if [[ -f "${auto}" && ! -L "${auto}" && -x "${auto}" ]]; then
  echo "  ok: ~/${LIVE_AUTOINSTALL_ENTRY} is a real executable script (not a symlink)"
else
  echo "  FAIL: autoinstall launcher missing or not a real exec script" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
autobody="$(cat "${auto}")"
assert_contains "${autobody}" "--yes" "launcher passes --yes"
assert_contains "${autobody}" "--bootloader=grub" "launcher passes --bootloader=grub"
assert_contains "${autobody}" "--rtc=local" "launcher passes --rtc=local"
assert_contains "${autobody}" "TARGET_USERNAME=me" "launcher exports TARGET_USERNAME=me"
assert_contains "${autobody}" "sudo env" "launcher acquires root via sudo env"
assert_contains "${autobody}" "USER_PASSWORD=''" "empty-default password embeds as valid quoted token"
assert_contains "${autobody}" \
  "${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/${LIVE_INSTALLER_ENTRY}" \
  "launcher invokes the embedded installer entry"
if bash -n "${auto}"; then
  echo "  ok: generated launcher is valid bash (empty-password default)"
else
  echo "  FAIL: generated launcher is not valid bash" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
# installer is optional: repo-only staging must not create the installer subdir,
# the convenience symlink, OR the autoinstall launcher.
stage2="$(mktemp -d)"; stage_live_payload "${stage2}" "${repo}"
if [[ -d "${stage2}${LIVE_STORE_ROOT}/${LIVE_REPO_SUBDIR}/dists" \
   && ! -e "${stage2}${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}" \
   && ! -e "${stage2}${LIVE_USER_HOME}/${LIVE_AUTOINSTALL_ENTRY}" ]]; then
  echo "  ok: installer + autoinstall staging is optional"
else
  echo "  FAIL: repo-only staging mishandled" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
rm -rf "${repo}" "${inst}" "${stage}" "${stage2}"

echo "test: stage_autoinstall_launcher embeds an arbitrary password safely (no injection)"
repo3="$(mktemp -d)"; mkdir -p "${repo3}/dists" "${repo3}/pool"
inst3="$(mktemp -d)"; printf '#!/bin/sh\n' >"${inst3}/installer.sh"
stage3="$(mktemp -d)"
# A password loaded with shell metacharacters: spaces, both quote types, a $, a
# semicolon and an `rm -rf` payload. Safe %q quoting must neutralise all of it.
pw="p@ss 'w\"o\$rd;rm -rf /"
LIVE_AUTOINSTALL_PASSWORD="${pw}" stage_live_payload "${stage3}" "${repo3}" "${inst3}"
auto3="${stage3}${LIVE_USER_HOME}/${LIVE_AUTOINSTALL_ENTRY}"
autobody3="$(cat "${auto3}")"
# The embedded form must be exactly what printf %q produces, so the value round-
# trips back to the original and cannot escape its token.
assert_contains "${autobody3}" "$(printf 'USER_PASSWORD=%q' "${pw}")" \
  "password embedded exactly as the printf %q-quoted token"
if bash -n "${auto3}"; then
  echo "  ok: launcher with a metacharacter-laden password is valid bash (no injection)"
else
  echo "  FAIL: special-character password broke launcher syntax" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
rm -rf "${repo3}" "${inst3}" "${stage3}"

echo "test: live_extras_chroot_script enables sshd on boot only when openssh-server is baked in"
with_ssh="$(live_extras_chroot_script "git openssh-client openssh-server")"
assert_contains "${with_ssh}" "apt-get install -y --no-install-recommends git openssh-client openssh-server" \
  "installs the requested live extras"
assert_contains "${with_ssh}" "SYSTEMD_OFFLINE=1 systemctl enable ssh.service" \
  "explicitly enables sshd on boot (offline) when openssh-server is present"
no_ssh="$(live_extras_chroot_script "git")"
if [[ "${no_ssh}" != *"systemctl enable"* ]]; then
  echo "  ok: no ssh enable emitted when openssh-server is absent"
else
  echo "  FAIL: enabled sshd without openssh-server in the set" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
if bash -n <(printf '%s\n' "${with_ssh}"); then
  echo "  ok: emitted chroot payload is valid shell"
else
  echo "  FAIL: chroot payload is not valid shell" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi

echo "test: build_write_iso_args replaces the live squashfs and strips d-i"
args="$(build_write_iso_args /s.iso /tmp/new.squashfs /o.iso)"
assert_contains "${args}" "-map" "maps a file into the ISO"
assert_contains "${args}" "/tmp/new.squashfs" "maps the rebuilt squashfs"
assert_contains "${args}" "/live/filesystem.squashfs" "targets the live root squashfs"
assert_contains "${args}" "replay" "replays the stock boot images (stays bootable)"
assert_contains "${args}" "-rm_r" "strips the unused d-i paths"
# The new squashfs must map ONTO the live squashfs path (argv: -map SOURCE TARGET),
# i.e. it replaces the root squashfs, not added as a top-level data dir.
maptarget="$(printf '%s\n' "${args}" | grep -A2 -- '^-map$' | tail -n1)"
if [[ "${maptarget}" == "/live/filesystem.squashfs" ]]; then
  echo "  ok: -map source maps onto /live/filesystem.squashfs"
else
  echo "  FAIL: -map does not target the live squashfs (got '${maptarget}')" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
# Boot replay MUST be ordered AFTER the -map/-rm tree edits (Debian
# RepackBootableISO rule), else BIOS/UEFI bootability can be lost.
map_idx="$(printf '%s\n' "${args}" | grep -n -- '^-map$' | head -n1 | cut -d: -f1)"
replay_idx="$(printf '%s\n' "${args}" | grep -n -- '^replay$' | head -n1 | cut -d: -f1)"
if [[ -n "${map_idx}" && -n "${replay_idx}" && "${replay_idx}" -gt "${map_idx}" ]]; then
  echo "  ok: boot replay is ordered after the tree edits"
else
  echo "  FAIL: replay must come after -map (got map=${map_idx} replay=${replay_idx})" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi

echo "test: detect_squashfs_params reads the stock compressor + block size"
unsquashfs() { printf 'Found a valid SQUASHFS superblock\nCompression zstd\nBlock size 1048576\nFilesystem size 12345 Kbytes\n'; }
params="$(detect_squashfs_params /any.squashfs)"
unset -f unsquashfs
assert_eq "zstd 1048576" "${params}" "parses Compression + Block size from unsquashfs -s"

finish_test
