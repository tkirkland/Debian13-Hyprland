#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=tools/iso-assemble.sh
source "${HERE}/../tools/iso-assemble.sh"     # main is guarded, so sourcing is inert

echo "test: iso-assemble repo layout validation"
good="$(mktemp -d)"; mkdir -p "${good}/dists/trixie" "${good}/pool"
bad="$(mktemp -d)"
{ validate_repo_layout "${good}" && echo "  ok: valid repo layout accepted"; } \
  || { echo "  FAIL: valid layout rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
assert_fails "missing pool/dists rejected" validate_repo_layout "${bad}"
rm -rf "${good}" "${bad}"

echo "test: stage_live_payload embeds repo (+ installer) under the live root"
repo="$(mktemp -d)"; mkdir -p "${repo}/dists/trixie" "${repo}/pool"; echo x >"${repo}/pool/a.deb"
# LythMono TTFs are staged into the store at build time (build-iso step_stage_fonts)
# under repo/lythmono; the whole store is grafted by cp -a, so they must ride along.
mkdir -p "${repo}/lythmono"; echo ttf >"${repo}/lythmono/LythMono.ttf"
inst="$(mktemp -d)"; printf '#!/bin/sh\n' >"${inst}/installer.sh"; chmod +x "${inst}/installer.sh"
stage="$(mktemp -d)"
stage_live_payload "${stage}" "${repo}" "${inst}"
base="${stage}${LIVE_STORE_ROOT}"
if [[ -f "${base}/${LIVE_REPO_SUBDIR}/pool/a.deb" && -d "${base}/${LIVE_REPO_SUBDIR}/dists" ]]; then
  echo "  ok: repo embedded at ${LIVE_STORE_ROOT}/${LIVE_REPO_SUBDIR}"
else
  echo "  FAIL: repo not embedded under the live root" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
if [[ -f "${base}/${LIVE_REPO_SUBDIR}/lythmono/LythMono.ttf" ]]; then
  echo "  ok: LythMono TTFs ride the embedded store (offline font install source)"
else
  echo "  FAIL: LythMono TTFs not embedded under the live store" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
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
assert_contains "${with_ssh}" "Dir::Etc::SourceList=/etc/apt/sources.list.d/zz-live-extras-build.list" \
  "live-extras apt uses an explicit online source list, not the build-absent live medium"
assert_contains "${with_ssh}" "deb http://deb.debian.org/debian trixie main" \
  "live-extras source uses main (zfs comes from the staged store, not contrib)"
if [[ "${with_ssh}" != *"/run/live/medium"* ]]; then
  echo "  ok: live-extras install does not reference the build-absent live medium"
else
  echo "  FAIL: live-extras install still references /run/live/medium" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
assert_contains "${with_ssh}" "SYSTEMD_OFFLINE=1 systemctl enable ssh.service" \
  "explicitly enables sshd on boot (offline) when openssh-server is present"
assert_contains "${with_ssh}" "rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin" \
  "cleanup tail removes the regenerable apt binary caches (pkgcache/srcpkgcache.bin) from the squashfs"
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

echo "test: live_extras_chroot_script bakes the PREBUILT upstream zfs debs (issue #110)"
kv="6.12.38+deb13-amd64"
zfs_bake="$(live_extras_chroot_script "git" "${kv}")"
# The live env runs the same upstream OpenZFS as the target: the kmod deb for
# the live kernel plus the userland debs come from the staged store — no dkms,
# no headers, no compile in the chroot.
assert_contains "${zfs_bake}" "/opt/hypr-deb/repo/pool/openzfs-zfs-modules-${kv}_*.deb" \
  "installs the prebuilt kmod deb for the live kernel from the staged store"
assert_contains "${zfs_bake}" "/opt/hypr-deb/repo/pool/openzfs-zfsutils_*.deb" \
  "installs the upstream userland from the staged store"
assert_contains "${zfs_bake}" "/opt/hypr-deb/repo/pool/openzfs-libzfs7_*.deb" \
  "installs the upstream zfs libs from the staged store"
for gone in zfs-dkms "linux-headers-${kv}" "apt-get purge"; do
  if [[ "${zfs_bake}" == *"${gone}"* ]]; then
    echo "  FAIL: bake still carries '${gone}' (dkms compile path must be gone)" >&2
    TEST_FAILURES=$((TEST_FAILURES+1))
  else
    echo "  ok: no '${gone}' in the bake (no compile machinery)"
  fi
done
assert_contains "${zfs_bake}" "depmod ${kv}" "runs depmod for the baked module"
assert_contains "${zfs_bake}" "modinfo -k ${kv} zfs" \
  "asserts the prebuilt module is resolvable after depmod"
if bash -n <(printf '%s\n' "${zfs_bake}"); then
  echo "  ok: zfs-bake chroot payload is valid shell"
else
  echo "  FAIL: zfs-bake chroot payload is not valid shell" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
# Without a kernel version the payload must not grow any zfs machinery.
no_kv="$(live_extras_chroot_script "git")"
if [[ "${no_kv}" != *openzfs* && "${no_kv}" != *depmod* ]]; then
  echo "  ok: no kver -> no zfs bake in the payload"
else
  echo "  FAIL: zfs bake emitted without a kernel version" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi

echo "test: install_live_extras wires the detected kernel into the payload call (issue #110)"
# Wiring-level: the payload builder is stubbed to capture its argv, so this
# fails if install_live_extras ever stops passing the detected kver (which
# would silently drop the whole zfs bake while every payload test stays green).
# shellcheck disable=SC2317  # stubs invoked indirectly by install_live_extras
(
  root="$(mktemp -d)"
  mkdir -p "${root}/etc" "${root}/lib/modules/${kv}"
  cap="$(mktemp)"
  mount() { :; }
  umount() { :; }
  chroot() { :; }
  info() { :; }
  live_extras_chroot_script() { printf '%s:%s\n' "$#" "${2:-}" >"${cap}"; echo :; }
  install_live_extras "${root}"
  got="$(cat "${cap}")"
  rm -rf "${root}"; rm -f "${cap}"
  [[ "${got}" == "2:${kv}" ]] || {
    echo "  FAIL: payload called with '${got}' (want packages + kver '${kv}')" >&2
    exit 1
  }
  echo "  ok: detected kernel passed as the payload's kver argument"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: detect_live_root_kernel expects exactly one kernel in the live root"
kroot="$(mktemp -d)"
mkdir -p "${kroot}/lib/modules/${kv}"
got_kv="$(detect_live_root_kernel "${kroot}")"
assert_eq "${kv}" "${got_kv}" "single /lib/modules entry echoed"
mkdir -p "${kroot}/lib/modules/6.13.0-amd64"
assert_fails "two kernels rejected" detect_live_root_kernel "${kroot}"
assert_fails "kernel-less root rejected" detect_live_root_kernel "$(mktemp -d)"
rm -rf "${kroot}"

echo "test: build_write_iso_args replaces the live squashfs and strips d-i"
iso_args="$(build_write_iso_args /s.iso /tmp/new.squashfs /o.iso)"
assert_contains "${iso_args}" "-map" "maps a file into the ISO"
assert_contains "${iso_args}" "/tmp/new.squashfs" "maps the rebuilt squashfs"
assert_contains "${iso_args}" "/live/filesystem.squashfs" "targets the live root squashfs"
assert_contains "${iso_args}" "replay" "replays the stock boot images (stays bootable)"
assert_contains "${iso_args}" "-rm_r" "strips the unused d-i paths"
# The new squashfs must map ONTO the live squashfs path (argv: -map SOURCE TARGET),
# i.e. it replaces the root squashfs, not added as a top-level data dir.
maptarget="$(printf '%s\n' "${iso_args}" | grep -A2 -- '^-map$' | tail -n1)"
if [[ "${maptarget}" == "/live/filesystem.squashfs" ]]; then
  echo "  ok: -map source maps onto /live/filesystem.squashfs"
else
  echo "  FAIL: -map does not target the live squashfs (got '${maptarget}')" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
# Boot replay MUST be ordered AFTER the -map/-rm tree edits (Debian
# RepackBootableISO rule), else BIOS/UEFI bootability can be lost.
map_idx="$(printf '%s\n' "${iso_args}" | grep -n -- '^-map$' | head -n1 | cut -d: -f1)"
replay_idx="$(printf '%s\n' "${iso_args}" | grep -n -- '^replay$' | head -n1 | cut -d: -f1)"
if [[ -n "${map_idx}" && -n "${replay_idx}" && "${replay_idx}" -gt "${map_idx}" ]]; then
  echo "  ok: boot replay is ordered after the tree edits"
else
  echo "  FAIL: replay must come after -map (got map=${map_idx} replay=${replay_idx})" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi

echo "test: detect_squashfs_params reads the stock compressor + block size"
# shellcheck disable=SC2317  # called indirectly by detect_squashfs_params
unsquashfs() { printf 'Found a valid SQUASHFS superblock\nCompression zstd\nBlock size 1048576\nFilesystem size 12345 Kbytes\n'; }
params="$(detect_squashfs_params /any.squashfs)"
unset -f unsquashfs
assert_eq "zstd 1048576" "${params}" "parses Compression + Block size from unsquashfs -s"

echo "test: parse_live_boot_paths extracts ALL /live kernel/initrd names (issue #111 U1)"
cfg_versioned='
label live
  kernel /live/vmlinuz-6.12.41+deb13-amd64
  append initrd=/live/initrd.img-6.12.41+deb13-amd64 boot=live
menuentry "Live" {
  linux  /live/vmlinuz-6.12.41+deb13-amd64 boot=live
  initrd /live/initrd.img-6.12.41+deb13-amd64
}'
pair="$(parse_live_boot_paths "${cfg_versioned}")"
assert_eq $'/live/vmlinuz-6.12.41+deb13-amd64\n/live/initrd.img-6.12.41+deb13-amd64' \
  "${pair}" "versioned /live names parsed from isolinux + grub text"
cfg_generic='kernel /live/vmlinuz
append initrd=/live/initrd.img boot=live'
pair="$(parse_live_boot_paths "${cfg_generic}")"
assert_eq $'/live/vmlinuz\n/live/initrd.img' "${pair}" "generic /live names parsed"
# The real 13.5 medium: grub.cfg uses versioned names, isolinux/live.cfg the
# generic ones — BOTH must come back so the golden pair maps over every name.
cfg_mixed=$'linux /live/vmlinuz-6.12.86+deb13-amd64\ninitrd /live/initrd.img-6.12.86+deb13-amd64\nkernel /live/vmlinuz\nappend initrd=/live/initrd.img boot=live'
pair="$(parse_live_boot_paths "${cfg_mixed}")"
assert_eq $'/live/vmlinuz /live/vmlinuz-6.12.86+deb13-amd64\n/live/initrd.img /live/initrd.img-6.12.86+deb13-amd64' \
  "${pair}" "mixed generic + versioned names both returned (stock 13.5 layout)"
assert_fails "initrd-less cfg rejected" parse_live_boot_paths 'kernel /live/vmlinuz'
assert_fails "empty cfg rejected" parse_live_boot_paths ''

echo "test: build_write_iso_args extra map pairs ride between the tree edits and the replay"
g_args="$(build_write_iso_args /s.iso /tmp/new.squashfs /o.iso \
  /ws/golden/boot/vmlinuz-6.12.41 /live/vmlinuz \
  /ws/golden/boot/initrd.img-6.12.41 /live/initrd.img \
  /ws/install-store /hypr-repo \
  /ws/installer-payload /hypr-installer)"
for tgt in /live/vmlinuz /live/initrd.img /hypr-repo /hypr-installer; do
  assert_contains "${g_args}" "${tgt}" "extra map targets ${tgt}"
done
kmap_idx="$(printf '%s\n' "${g_args}" | grep -n -- '^/live/vmlinuz$' | head -n1 | cut -d: -f1)"
sqfs_idx="$(printf '%s\n' "${g_args}" | grep -n -- '^/live/filesystem.squashfs$' | head -n1 | cut -d: -f1)"
greplay_idx="$(printf '%s\n' "${g_args}" | grep -n -- '^replay$' | head -n1 | cut -d: -f1)"
if [[ -n "${kmap_idx}" && -n "${sqfs_idx}" && -n "${greplay_idx}" ]] &&
  ((sqfs_idx < kmap_idx && kmap_idx < greplay_idx)); then
  echo "  ok: extra maps ordered after the squashfs map, before the boot replay"
else
  echo "  FAIL: extra-map ordering wrong (sqfs=${sqfs_idx} kmap=${kmap_idx} replay=${greplay_idx})" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
assert_fails "odd extra map arguments rejected (must be SRC TARGET pairs)" \
  bash -c 'source tools/iso-assemble.sh; build_write_iso_args /s /q /o /lonely'

echo "test: stage_golden_home seeds the live home pointing at the MEDIUM installer"
groot="$(mktemp -d)"
# Golden root ships skel configs; the live home must inherit them (user-setup
# adopts a pre-seeded /home/user, so adduser never copies skel into it).
mkdir -p "${groot}/etc/skel/.config/hypr"
printf -- '-- skel autostart\n' >"${groot}/etc/skel/.config/hypr/autostart.lua"
(
  LIVE_STORE_ROOT="/run/live/medium"
  LIVE_INSTALLER_SUBDIR="hypr-installer"
  chown() { :; }   # ownership needs root; the guard is exercised, not the kernel
  stage_golden_home "${groot}"
)
ghome="${groot}${LIVE_USER_HOME}"
gauto_lua="${ghome}/.config/hypr/autostart.lua"
assert_contains "$(cat "${gauto_lua}")" "-- skel autostart" \
  "skel configs are copied into the live home"
assert_contains "$(cat "${gauto_lua}")" "live-welcome" \
  "live-only autostart hook appended AFTER the skel copy"
if [[ -x "${ghome}/.local/bin/live-welcome" ]]; then
  echo "  ok: live-welcome terminal script staged executable"
else
  echo "  FAIL: live-welcome script missing or not executable" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
assert_contains "$(cat "${ghome}/.local/bin/live-welcome")" "WIPES ALL DISKS" \
  "welcome text warns before the unattended launcher"
if ! grep -q "live-welcome" "${groot}/etc/skel/.config/hypr/autostart.lua"; then
  echo "  ok: skel autostart.lua untouched (hook is live-home-only)"
else
  echo "  FAIL: live hook leaked into /etc/skel (would reach installed users)" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
glink="${groot}${LIVE_USER_HOME}/${LIVE_INSTALLER_ENTRY}"
gwant="/run/live/medium/hypr-installer/${LIVE_INSTALLER_ENTRY}"
if [[ -L "${glink}" && "$(readlink "${glink}")" == "${gwant}" ]]; then
  echo "  ok: golden home installer symlink -> ${gwant}"
else
  echo "  FAIL: golden home installer symlink missing or wrong target" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
gauto="${groot}${LIVE_USER_HOME}/${LIVE_AUTOINSTALL_ENTRY}"
if [[ -f "${gauto}" && -x "${gauto}" ]]; then
  echo "  ok: golden home carries the autoinstall launcher"
  assert_contains "$(cat "${gauto}")" "/run/live/medium/hypr-installer" \
    "launcher invokes the medium-side installer"
else
  echo "  FAIL: golden home autoinstall launcher missing" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
rm -rf "${groot}"

finish_test
