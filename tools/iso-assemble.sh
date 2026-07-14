#!/usr/bin/env bash
# shellcheck shell=bash
# iso-assemble.sh — build an offline live ISO by EMBEDDING the apt repo and the
# installer tree INSIDE the live root filesystem (the squashfs), at
# ${LIVE_STORE_ROOT} (default /opt/hypr-deb), then repacking the ISO.
#
# This supersedes the earlier "plain top-level data directory on the ISO9660
# medium" layout (/hypr-repo + /hypr-installer, visible at /run/live/medium/...).
# Embedding in the squashfs puts the store in the LIVE ROOT (/opt/hypr-deb/repo)
# instead of under /run/live/medium, which:
#   * makes the store impossible to shadow via a /run bind mount (the
#     mount-propagation class of bug), and
#   * removes the dependency on the medium staying mounted/visible mid-install.
#
# Usage: iso-assemble.sh STOCK_ISO REPO_DIR OUT_ISO
#   HYPR_INSTALLER_DIR=<dir>   optional filtered installer tree to embed too
#
# HOST SAFETY: reads STOCK_ISO / REPO_DIR / HYPR_INSTALLER_DIR; writes only into
# a fresh mktemp workdir and the (non-existent) OUT_ISO. It runs no apt/dpkg/
# chroot and never writes under system paths. It DOES require root + xorriso +
# squashfs-tools: the live squashfs is unsquashed and remade as root so the
# stock tree's and the staged store's ownership/perms/xattrs are preserved.

set -euo pipefail

# In-squashfs (live-root) parent for the embedded store + installer.
LIVE_STORE_ROOT="${LIVE_STORE_ROOT:-/opt/hypr-deb}"
LIVE_REPO_SUBDIR="${LIVE_REPO_SUBDIR:-repo}"
LIVE_INSTALLER_SUBDIR="${LIVE_INSTALLER_SUBDIR:-installer}"
# Live user's home and the installer entry script. A convenience symlink is
# dropped at ${LIVE_USER_HOME}/${LIVE_INSTALLER_ENTRY} -> the embedded entry so
# the installer is runnable straight from ~ on boot. /home/user is the Debian
# live default; override LIVE_USER_HOME if the live account differs.
LIVE_USER_HOME="${LIVE_USER_HOME:-/home/user}"
LIVE_INSTALLER_ENTRY="${LIVE_INSTALLER_ENTRY:-installer.sh}"
# Extra packages baked into the live squashfs so they're present the instant the
# live CLI lands — the stock Debian 'standard' image ships none of these.
# Installed from the normal mirror during assembly (the build host is online).
# Set to empty to skip the chroot install entirely.
LIVE_EXTRA_PACKAGES="${LIVE_EXTRA_PACKAGES:-git openssh-client openssh-server}"
# Online apt source for the build-time live-extras install. The stock Debian-live
# root's own sources point at the install medium (file:/run/live/medium/...),
# which does NOT exist at build time — so we install from this mirror instead
# (the build host is online; this provisions the LIVE env, not the offline target).
# main suffices: the zfs bake installs the ISO's own prebuilt upstream debs
# from the staged store (no Debian zfs-dkms from contrib anymore); the mirror
# only backfills ordinary dependencies.
LIVE_EXTRA_APT_SOURCE="${LIVE_EXTRA_APT_SOURCE:-deb http://deb.debian.org/debian trixie main}"
# Unattended autoinstall launcher dropped in the live user's home as a REAL
# generated script (NOT a symlink — a symlink cannot carry flags). It runs the
# embedded installer fully hands-off via `sudo env ...`. The password is embedded
# plaintext in the ISO by explicit design; it MUST come from the build-time env
# LIVE_AUTOINSTALL_PASSWORD and is NEVER committed (the empty default still emits
# a syntactically valid launcher — the installer just fatals at runtime until a
# password is baked in). bootloader/rtc/username follow the same knob idiom.
LIVE_AUTOINSTALL_ENTRY="${LIVE_AUTOINSTALL_ENTRY:-autoinstall.sh}"
LIVE_AUTOINSTALL_BOOTLOADER="${LIVE_AUTOINSTALL_BOOTLOADER:-grub}"
LIVE_AUTOINSTALL_RTC="${LIVE_AUTOINSTALL_RTC:-local}"
LIVE_AUTOINSTALL_USERNAME="${LIVE_AUTOINSTALL_USERNAME:-me}"
LIVE_AUTOINSTALL_PASSWORD="${LIVE_AUTOINSTALL_PASSWORD:-}"
# Path of the live root squashfs inside the ISO (Debian live default).
ISO_LIVE_SQUASHFS="${ISO_LIVE_SQUASHFS:-/live/filesystem.squashfs}"
# Golden mode (issue #111): GOLDEN_ROOT (env, set by build-iso) selects the
# golden path — mksquashfs GOLDEN_ROOT as the ONE live/install image, map its
# kernel/initrd over the stock /live names, and put the install store + the
# installer tree on the ISO9660 MEDIUM (visible at /run/live/medium/...)
# instead of inside the squashfs. The medium store location matches the
# installer's ISO_MEDIUM_REPO probe (lib/00-config.sh).
GOLDEN_ROOT="${GOLDEN_ROOT:-}"
ISO_MEDIUM_STORE_DIR="${ISO_MEDIUM_STORE_DIR:-/hypr-repo}"
ISO_MEDIUM_INSTALLER_DIR="${ISO_MEDIUM_INSTALLER_DIR:-/hypr-installer}"
# Stock paths to drop from the output ISO: Debian's own live-installer (d-i)
# pool + metadata, which this distro never uses (it installs via our own
# installer + the embedded store). Removing them reclaims the ~200 base .debs.
# The live session (booted from /live/filesystem.squashfs) is untouched; only
# d-i boot-menu entries break. Space-separated; HYPR_ISO_STRIP overrides, empty
# keeps everything.
ISO_STRIP_PATHS="${HYPR_ISO_STRIP-/pool /pool-udeb /install /dists}"

# Minimal logging shims so the lib can be sourced standalone in tests without
# the project logging lib (same idiom as tools/lib-build-guard.sh).
if ! declare -f info >/dev/null 2>&1; then
  info() { printf '%s\n' "$*" >&2; }
fi
if ! declare -f fatal >/dev/null 2>&1; then
  fatal() {
    printf '[FATAL] %s\n' "$*" >&2
    exit 1
  }
fi

# validate_repo_layout REPO_DIR
# Returns 0 if REPO_DIR exists and contains both dists/ and pool/, else 1.
validate_repo_layout() {
  local repo="${1:-}"
  [[ -n "${repo}" && -d "${repo}" ]] || return 1
  [[ -d "${repo}/dists" ]] || return 1
  [[ -d "${repo}/pool" ]] || return 1
  return 0
}

# stage_live_payload STAGE_DIR REPO_DIR [INSTALLER_DIR]
# Build the directory tree that gets grafted onto the live root, mirroring the
# in-root layout exactly:
#   STAGE_DIR/${LIVE_STORE_ROOT}/${LIVE_REPO_SUBDIR}/       <- the apt repo
#   STAGE_DIR/${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/  <- the installer tree
# Pure filesystem staging (no squashfs/xorriso) so it is unit-testable. cp -a
# preserves ownership, timestamps and exec bits.
stage_live_payload() {
  local stage="${1:?stage dir}" repo="${2:?repo dir}" installer="${3:-}"
  local base="${stage%/}${LIVE_STORE_ROOT}"
  mkdir -p "${base}/${LIVE_REPO_SUBDIR}"
  cp -a "${repo%/}/." "${base}/${LIVE_REPO_SUBDIR}/"
  if [[ -n "${installer}" ]]; then
    [[ -d "${installer}" ]] || fatal "installer dir not found: ${installer}"
    mkdir -p "${base}/${LIVE_INSTALLER_SUBDIR}"
    cp -a "${installer%/}/." "${base}/${LIVE_INSTALLER_SUBDIR}/"
    # Convenience symlink in the live user's home so the installer is runnable
    # from ~ on boot without relocating the embedded tree. Absolute target so it
    # resolves against the live root at runtime, not the stage dir.
    local home="${stage%/}${LIVE_USER_HOME}"
    mkdir -p "${home}"
    ln -sfn "${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/${LIVE_INSTALLER_ENTRY}" \
      "${home}/${LIVE_INSTALLER_ENTRY}"
    # Real (not symlink) unattended launcher alongside it, so it can carry flags.
    stage_autoinstall_launcher "${home}"
  fi
}

# stage_autoinstall_launcher HOME_DIR
# Write a REAL unattended-install launcher (~/${LIVE_AUTOINSTALL_ENTRY}) into the
# live user's HOME_DIR. Unlike the installer.sh symlink it carries the unattended
# flags, so it must be a generated script. The installer requires uid 0 and never
# self-sudoes, so the launcher runs it under sudo; the live user has passwordless
# sudo on tty1, so this is hands-off. `sudo env VAR=...` re-injects
# USER_PASSWORD/TARGET_USERNAME that sudo's default env scrub would otherwise drop.
# "$@" is forwarded so the operator can append or override flags. Every embedded
# value is run through printf %q, so an arbitrary (or empty) password can neither
# break the script's syntax nor inject extra arguments. Pure: writes only the one
# file under HOME_DIR (no squashfs/chroot side effects), so it stays unit-testable.
stage_autoinstall_launcher() {
  local home="${1:?home dir}"
  local entry="${home%/}/${LIVE_AUTOINSTALL_ENTRY}"
  local installer="${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/${LIVE_INSTALLER_ENTRY}"
  local pw_q user_q boot_q rtc_q inst_q
  pw_q="$(printf '%q' "${LIVE_AUTOINSTALL_PASSWORD}")"
  user_q="$(printf '%q' "${LIVE_AUTOINSTALL_USERNAME}")"
  boot_q="$(printf '%q' "${LIVE_AUTOINSTALL_BOOTLOADER}")"
  rtc_q="$(printf '%q' "${LIVE_AUTOINSTALL_RTC}")"
  inst_q="$(printf '%q' "${installer}")"
  cat >"${entry}" <<EOF
#!/usr/bin/env bash
# Generated by iso-assemble.sh — UNATTENDED installer launcher. Do not edit.
# Runs the embedded installer as root with the answers baked in at build time.
# The installer requires uid 0 and never self-sudoes; the live user has
# passwordless sudo on tty1, so this runs hands-off. \`sudo env VAR=...\` re-injects
# USER_PASSWORD/TARGET_USERNAME that sudo's env scrub would otherwise drop.
# Append or override flags by passing them through, e.g. ./${LIVE_AUTOINSTALL_ENTRY} --bootloader=zbm
set -euo pipefail

exec sudo env \\
  USER_PASSWORD=${pw_q} \\
  TARGET_USERNAME=${user_q} \\
  ${inst_q} \\
  --yes \\
  --bootloader=${boot_q} \\
  --rtc=${rtc_q} \\
  "\$@"
EOF
  chmod +x "${entry}"
}

# extract_stock_squashfs STOCK_ISO OUT_FILE
# Copy the live root squashfs out of the (read-only) stock ISO so it can be
# unsquashed and rebuilt. Native xorriso osirrox extraction; no full ISO unpack.
# Heavy; exercised for real only in the build integration path.
extract_stock_squashfs() {
  local stock="$1" out="$2"
  xorriso -osirrox on -indev "${stock}" \
    -extract "${ISO_LIVE_SQUASHFS}" "${out}"
}

# detect_squashfs_params SQUASHFS  ->  echoes "COMPRESSOR BLOCKSIZE"
# Read the stock squashfs's compressor and block size so the rebuilt image
# matches it. mksquashfs otherwise defaults to gzip / 128K, which would both
# bloat the image and mismatch Debian's live squashfs (zstd, larger blocks).
# Seam kept separate so it is unit-testable with a stubbed unsquashfs.
detect_squashfs_params() {
  local sqfs="$1" out="" comp="" bsize=""
  out="$(unsquashfs -s "${sqfs}" 2>/dev/null)" || return 1
  comp="$(printf '%s\n' "${out}" | awk '/^Compression/ {print $2; exit}')"
  bsize="$(printf '%s\n' "${out}" | awk '/^Block size/ {print $3; exit}')"
  [[ -n "${comp}" && -n "${bsize}" ]] || return 1
  printf '%s %s\n' "${comp}" "${bsize}"
}

# rebuild_live_squashfs STOCK_SQUASHFS STAGE_DIR OUT_SQUASHFS
# Produce OUT_SQUASHFS = STOCK_SQUASHFS with STAGE_DIR's tree merged into the
# live root. mksquashfs "append" must NOT be used here: appending a source whose
# top-level entry (opt) collides with an existing directory renames it to opt_1
# instead of merging — the store would land at /opt_1/hypr-deb. Instead unsquash
# the stock tree, graft the staged store under the existing /opt with `cp -a` (a
# true recursive directory union), and remake the squashfs with the stock's own
# compressor and block size. Run as root so unsquashfs/mksquashfs preserve
# ownership, permissions and xattrs. Heavy; build-integration only.
rebuild_live_squashfs() {
  local stock_sqfs="$1" stage="$2" out_sqfs="$3"
  local comp="" bsize="" root=""
  read -r comp bsize < <(detect_squashfs_params "${stock_sqfs}") \
    || fatal "could not read compressor/block size from ${stock_sqfs}"
  # Keep the unsquashed tree under out_sqfs's dir (the caller's mktemp workdir),
  # so assemble()'s EXIT trap reclaims it even if a step below fails under set -e.
  root="${out_sqfs%/*}/unsquash-root"
  unsquashfs -f -d "${root}" "${stock_sqfs}"
  cp -a "${stage}/." "${root}/"
  install_live_extras "${root}"
  mksquashfs "${root}" "${out_sqfs}" -noappend -no-progress -no-recovery \
    -comp "${comp}" -b "${bsize}"
  rm -rf "${root}"
}

# detect_live_root_kernel LIVE_ROOT
# Echo the single kernel version under LIVE_ROOT/lib/modules. A stock Debian
# live root carries exactly one; anything else means the image layout changed
# and the zfs bake would target the wrong kernel — nonzero then.
detect_live_root_kernel() {
  local root="$1" entries=()
  entries=("${root}"/lib/modules/*/)
  [[ -d "${entries[0]}" ]] || return 1
  ((${#entries[@]} == 1)) || return 1
  local k="${entries[0]%/}"
  printf '%s\n' "${k##*/}"
}

# live_extras_chroot_script PACKAGES [KVER]
# Emit (stdout) the `sh -c` payload run inside the live-root chroot to install the
# extras. When openssh-server is in the set, append an explicit offline
# `systemctl enable ssh.service` so sshd is enabled to start on live boot:
# Debian's postinst normally enables it, but doing it explicitly makes the
# behaviour guaranteed (and unit-testable) instead of an implicit maintainer-
# script side effect. SYSTEMD_OFFLINE=1 forces systemctl to act purely on the
# filesystem (there is no running manager / D-Bus in the build chroot). Pure
# (string only), so tests can assert the payload without a real chroot.
#
# KVER (issue #110): when non-empty, additionally bake a loadable zfs module
# for that kernel into the squashfs — install the ISO's OWN prebuilt upstream
# OpenZFS debs (kmod for KVER + userland + libs) straight from the staged
# store, which stage_live_payload already grafted under LIVE_STORE_ROOT
# before this runs. No dkms, no headers, no compile: the module was built
# once by step_zfs. Every live boot then has zfs loadable — preflight's
# modinfo probe short-circuits. Live and target now run the SAME upstream
# ZFS; pool feature-set safety for the boot chain is enforced explicitly by
# zpool create's -o compatibility= (scripts/20-storage.sh), not by shipping
# an older userland.
live_extras_chroot_script() {
  local pkgs="$1" kver="${2:-}" script=""
  local zfs_debs="" d=""
  if [[ -n "${kver}" ]]; then
    for d in "openzfs-zfs-modules-${kver}" openzfs-zfsutils \
      openzfs-libnvpair3 openzfs-libuutil3 openzfs-libzfs7 openzfs-libzpool7; do
      zfs_debs+=" ${LIVE_STORE_ROOT}/repo/pool/${d}_*.deb"
    done
  fi
  # Use ONLY our online mirror for this install: -o SourceList points at a temp
  # list and an empty SourceParts ignores the live root's medium-based sources
  # (file:/run/live/medium/...) that are absent at build time. See
  # LIVE_EXTRA_APT_SOURCE. Options after the package names so a plain
  # `apt-get install ... ${pkgs}` substring stays intact.
  local list="/etc/apt/sources.list.d/zz-live-extras-build.list"
  local aopt="-o Dir::Etc::SourceList=${list} -o Dir::Etc::SourceParts=/dev/null"
  script="printf '%s\\n' '${LIVE_EXTRA_APT_SOURCE}' >${list} &&"
  script+=" apt-get update -qq ${aopt} &&"
  script+=" apt-get install -y --no-install-recommends ${pkgs}${zfs_debs} ${aopt} &&"
  case " ${pkgs} " in
    *" openssh-server "*)
      script+=" SYSTEMD_OFFLINE=1 systemctl enable ssh.service &&" ;;
  esac
  if [[ -n "${kver}" ]]; then
    # Prebuilt kmod deb just landed its module under /lib/modules/KVER —
    # depmod, then assert it is resolvable (path-agnostic via modinfo).
    script+=" depmod ${kver} &&"
    script+=" modinfo -k ${kver} zfs >/dev/null &&"
  fi
  # Neuter systemd-ssh-generator (systemd >=256): it queries the local AF_VSOCK
  # CID to set up ssh-over-vsock and, in a VM with no vhost-vsock device, exits 1
  # on every boot/daemon-reload, spamming "Failed to query local AF_VSOCK CID".
  # Mask it by symlinking to /dev/null in /etc (which outranks /usr/lib in the
  # generator search order, so a systemd upgrade never clobbers it). Done
  # UNCONDITIONALLY (the generator ships with systemd, not openssh-server) and
  # touches ONLY the generator -- the real sshd (ssh.service) is untouched.
  script+=" mkdir -p /etc/systemd/system-generators &&"
  script+=" ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator &&"
  script+=" rm -f ${list} && apt-get clean &&"
  # apt-get clean empties the archive cache but leaves the binary package
  # indexes (/var/cache/apt/{pkgcache,srcpkgcache}.bin); drop them too so the
  # rebuilt live squashfs does not carry stale, regenerable caches.
  script+=" rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin"
  printf '%s' "${script}"
}

# install_live_extras LIVE_ROOT
# apt-install LIVE_EXTRA_PACKAGES into the unsquashed live root so they ride in
# the rebuilt squashfs. Runs on the online build host, against the live image's
# own apt sources. Bind-mounts /dev,/proc,/sys (openssh-server's postinst needs
# /dev for host-key generation) and supplies a working resolv.conf for the
# chroot, restoring the image's original afterward. No-op if the list is empty.
install_live_extras() {
  local root="$1"
  [[ -n "${LIVE_EXTRA_PACKAGES// /}" ]] || return 0
  # The zfs bake (issue #110) targets the live root's own kernel; the pin
  # exported by build-iso (step_pin_kernel) must agree or the whole prebuilt
  # chain (pool kernel, kmod deb, baked module) is inconsistent. Standalone
  # invocations without KERNEL_PINNED skip only the cross-check.
  local kver=""
  kver="$(detect_live_root_kernel "${root}")" ||
    fatal "live root does not carry exactly one kernel under /lib/modules"
  if [[ -n "${KERNEL_PINNED:-}" && "${KERNEL_PINNED}" != "${kver}" ]]; then
    fatal "live squashfs kernel ${kver} != pinned kernel ${KERNEL_PINNED}"
  fi
  local resolv="${root}/etc/resolv.conf" resolv_bak=""
  if [[ -e "${resolv}" || -L "${resolv}" ]]; then
    resolv_bak="${resolv}.iso-assemble.bak"; mv "${resolv}" "${resolv_bak}"
  fi
  cp -L /etc/resolv.conf "${resolv}" 2>/dev/null || true
  local m mounted=()
  for m in dev dev/pts proc sys; do
    mount --bind "/${m}" "${root}/${m}" && mounted=("${root}/${m}" "${mounted[@]}")
  done
  info "iso-assemble: baking live extras + zfs module (${kver}) into the squashfs:" \
    "${LIVE_EXTRA_PACKAGES}"
  local rc=0
  chroot "${root}" env DEBIAN_FRONTEND=noninteractive sh -c \
    "$(live_extras_chroot_script "${LIVE_EXTRA_PACKAGES}" "${kver}")" || rc=$?
  for m in "${mounted[@]}"; do umount -l "${m}" 2>/dev/null || true; done
  rm -f "${resolv}"
  [[ -n "${resolv_bak}" ]] && mv "${resolv_bak}" "${resolv}"
  ((rc == 0)) || fatal "live-extras install failed (rc=${rc})"
}

# rebuild_efi_img_with_mokmanager STOCK_ISO GOLDEN_ROOT WORK
# The stock ISO's EFI boot image carries shim+grub but NO MokManager, and is
# packed full (22K free). A boot with a PENDING MOK request — the installer
# stages one, then the user reboots with the medium still inserted — makes the
# ISO's shim invoke MokManager, find nothing, and die ("import_mok_state()
# failed"; the #50 gap, hit again live 2026-07-13). Rebuild the FAT image
# slightly larger with mmx64.efi grafted in (sourced from the golden root's
# shim-signed) and echo its path; echoes nothing if the stock image already
# carries MokManager (fixed upstream). The caller feeds it to
# build_write_iso_args via ISO_EFI_APPEND_IMG — NOT as a -map over the tree
# file: the EFI El-Torito image is a HIDDEN appended partition (the tree's
# /boot/grub/efi.img is only the APM/GPT reference copy), and a size-changed
# map over that file breaks APM replay outright (SORRY, seen live
# 2026-07-13). Overriding appended partition 2 + pointing El-Torito at it is
# how the stock ISO is built, and covers CD and USB boots alike.
rebuild_efi_img_with_mokmanager() {
  local stock="$1" groot="$2" work="$3"
  local img="${work}/efi-stock.img" newimg="${work}/efi-mok.img"
  local mnt="${work}/efi-stock-mnt" newmnt="${work}/efi-mok-mnt"
  local mm="${groot}/usr/lib/shim/mmx64.efi.signed"
  [[ -f "${mm}" ]] || fatal "mmx64.efi.signed not in the golden root (shim-signed not baked?)"
  command -v mkfs.vfat >/dev/null 2>&1 ||
    DEBIAN_FRONTEND=noninteractive apt-get install -y dosfstools >&2 ||
    fatal "mkfs.vfat unavailable and dosfstools install failed"
  rm -f "${img}" "${newimg}"
  xorriso -osirrox on -indev "${stock}" -extract /boot/grub/efi.img "${img}" \
    >/dev/null 2>&1 || fatal "cannot extract /boot/grub/efi.img from ${stock}"
  mkdir -p "${mnt}" "${newmnt}"
  mount -o loop,ro "${img}" "${mnt}" || fatal "cannot loop-mount the stock efi.img"
  if [[ -f "${mnt}/EFI/boot/mmx64.efi" ]]; then
    umount "${mnt}"
    return 0
  fi
  # Size: stock image + MokManager + 1 MiB FAT slack, rounded up to a MiB.
  local bytes=0
  bytes=$(($(stat -c%s "${img}") + $(stat -c%s "${mm}") + 1048576))
  bytes=$(((bytes + 1048575) / 1048576 * 1048576))
  truncate -s "${bytes}" "${newimg}"
  mkfs.vfat "${newimg}" >/dev/null 2>&1 || { umount "${mnt}"; fatal "mkfs.vfat failed"; }
  mount -o loop "${newimg}" "${newmnt}" || { umount "${mnt}"; fatal "cannot mount the rebuilt efi.img"; }
  if ! { cp -a "${mnt}/." "${newmnt}/" && cp "${mm}" "${newmnt}/EFI/boot/mmx64.efi"; }; then
    umount "${newmnt}" "${mnt}"
    fatal "populating the rebuilt efi.img failed"
  fi
  umount "${newmnt}" "${mnt}"
  printf '%s\n' "${newimg}"
}

# build_write_iso_args STOCK_ISO NEW_SQUASHFS OUT_ISO [SRC TARGET]...
# Emit (one per line) the native-xorriso argv that writes OUT_ISO = STOCK_ISO
# with the live squashfs replaced by NEW_SQUASHFS and the d-i pool stripped,
# replaying the stock El-Torito BIOS + EFI boot images so OUT_ISO stays bootable.
# Extra SRC/TARGET pairs become additional -map edits (golden mode: the golden
# kernel/initrd mapped OVER the stock /live names so the boot cfgs keep working,
# and the install store + installer onto the medium top level) — still emitted
# BEFORE the boot replay, preserving the load-bearing ordering. Split out as a
# pure seam so the argv is unit-testable without xorriso.
build_write_iso_args() {
  local stock="$1" sqfs="$2" out="$3"
  shift 3
  (($# % 2 == 0)) ||
    fatal "build_write_iso_args: extra map arguments must be SRC TARGET pairs"
  # Ordering is load-bearing (Debian RepackBootableISO): acquire input/output,
  # THEN manipulate the tree (-rm_r / -map), THEN replay the boot equipment, THEN
  # commit. Running `-boot_image any replay` BEFORE the edits can lose the
  # BIOS/UEFI boot setup. -compliance/-padding keep the hybrid image robust.
  printf '%s\n' -indev "${stock}" -outdev "${out}" -volid HYPR_OFFLINE
  if [[ -n "${ISO_STRIP_PATHS}" ]]; then
    local -a strip
    read -r -a strip <<<"${ISO_STRIP_PATHS}"
    printf '%s\n' -abort_on NEVER -rm_r "${strip[@]}" -- -abort_on FAILURE
  fi
  printf '%s\n' -map "${sqfs}" "${ISO_LIVE_SQUASHFS}"
  while (($#)); do
    printf '%s\n' -map "$1" "$2"
    shift 2
  done
  printf '%s\n' -boot_image any replay -compliance no_emul_toc -padding included
  # ISO_EFI_APPEND_IMG (optional): replace the EFI boot equipment AFTER the
  # replay — override appended partition 2 (replay re-established the stock
  # one; a later spec for the same slot wins) and re-point the El-Torito EFI
  # entry into it, exactly how the stock image wires its own EFI boot. The
  # tree's /boot/grub/efi.img is deliberately untouched (APM replay breaks on
  # a size change).
  if [[ -n "${ISO_EFI_APPEND_IMG:-}" ]]; then
    printf '%s\n' -append_partition 2 0xef "${ISO_EFI_APPEND_IMG}"
    printf '%s\n' -boot_image any efi_path=--interval:appended_partition_2:all::
  fi
  printf '%s\n' -commit
}

# write_iso_with_squashfs STOCK_ISO NEW_SQUASHFS OUT_ISO [SRC TARGET]...
write_iso_with_squashfs() {
  local -a args=()
  mapfile -t args < <(build_write_iso_args "$@")
  xorriso "${args[@]}"
}

# parse_live_boot_paths CFG_TEXT
# Pure: extract the kernel and initrd ISO paths the stock boot configs
# reference under /live/ (isolinux for BIOS, grub for EFI). The golden ISO
# maps OUR kernel/initrd over ALL of these names: the stock 13.5 medium
# legitimately uses TWO name styles for the same files — grub loads the
# versioned pair (/live/vmlinuz-<ver>), isolinux the generic one
# (/live/vmlinuz) — so every referenced name must resolve to our kernel
# (issue #111 U1). Echoes two lines, kernel paths then initrd paths, each
# space-separated; nonzero when either set is empty (a cfg with no /live
# references means the stock layout truly changed — fail loudly).
parse_live_boot_paths() {
  local text="$1" kpaths="" ipaths=""
  kpaths="$(grep -oE '/live/vmlinuz[^ "]*' <<<"${text}" | sort -u)"
  ipaths="$(grep -oE '/live/initrd[^ "]*' <<<"${text}" | sort -u)"
  [[ -n "${kpaths}" && -n "${ipaths}" ]] || return 1
  printf '%s\n%s\n' "${kpaths//$'\n'/ }" "${ipaths//$'\n'/ }"
}

# probe_stock_live_boot_paths STOCK_ISO WORKDIR
# Extract the stock ISO's boot configs (best-effort per file: layouts vary
# across releases) and parse the /live/ kernel/initrd path pair from their
# combined text. Heavy half of the seam; the parsing is pure above.
probe_stock_live_boot_paths() {
  local stock="$1" work="$2" cfg="" text=""
  local -a candidates=(
    /isolinux/live.cfg /isolinux/menu.cfg /isolinux/isolinux.cfg
    /boot/grub/grub.cfg /boot/grub/loopback.cfg
  )
  rm -rf "${work}/bootcfg"
  mkdir -p "${work}/bootcfg"
  for cfg in "${candidates[@]}"; do
    xorriso -osirrox on -indev "${stock}" \
      -extract "${cfg}" "${work}/bootcfg/${cfg//\//_}" >/dev/null 2>&1 || true
  done
  text="$(cat "${work}/bootcfg"/* 2>/dev/null || true)"
  rm -rf "${work}/bootcfg"
  [[ -n "${text}" ]] || return 1
  parse_live_boot_paths "${text}"
}

# stage_golden_home GOLDEN_ROOT
# Seed the live user's home inside the golden root: the installer symlink and
# the generated autoinstall launcher, both pointing at the MEDIUM-side
# installer (golden mode moves the store + installer out of the squashfs).
# live-config creates the live user as uid 1000 (Debian live default) and
# adopts an existing /home/user, so ownership is set to match. These two
# files are live-only; customize removes them from the copied tree.
stage_golden_home() {
  local root="${1:?golden root}"
  local home="${root%/}${LIVE_USER_HOME}"
  mkdir -p "${home}"
  # user-setup ADOPTS a pre-existing /home/user, and adduser copies /etc/skel
  # only into homes it creates itself — so seeding files here means the live
  # user would otherwise get NO skel configs at all (bare-default Hyprland,
  # no keybinds/launcher/session hooks; seen live 2026-07-13). Copy skel in
  # ourselves before adding the live-only files.
  if [[ -d "${root%/}/etc/skel" ]]; then
    cp -a "${root%/}/etc/skel/." "${home}/"
  fi
  ln -sfn "${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}/${LIVE_INSTALLER_ENTRY}" \
    "${home}/${LIVE_INSTALLER_ENTRY}"
  stage_autoinstall_launcher "${home}"
  stage_live_welcome "${home}"
  # The live session's entry point is the kitty banner terminal above — the
  # graphical first-login welcome dialog is redundant noise there (seen live
  # 2026-07-13). Pre-seed its done-marker; installed users still get it
  # (create_user copies skel, which never carries the marker).
  install -d "${home}/.config/hypr"
  : >"${home}/.config/hypr/.welcome-shown"
  chown -R 1000:1000 "${home}" 2>/dev/null || true
}

# stage_live_welcome HOME_DIR
# Live-only desktop entry point: an autostart hook (appended to the live
# user's own copy of autostart.lua, never to /etc/skel) opens a kitty window
# running a welcome script with the install instructions. Informational only —
# the unattended launcher wipes disks and must never self-execute; the user
# runs it (or the interactive installer) from this terminal. customize deletes
# /home/user wholesale, so none of this reaches installed systems.
stage_live_welcome() {
  local home="${1:?home dir}"
  install -d "${home}/.local/bin" "${home}/.config/hypr"
  cat >"${home}/.local/bin/live-welcome" <<EOF
#!/bin/sh
# Generated by iso-assemble.sh — live-session installer terminal.
cat <<'BANNER'
Debian13-Hyprland live session
==============================
This is a full demo of the installed desktop. To install:

  ./${LIVE_AUTOINSTALL_ENTRY}     unattended install (WIPES ALL DISKS)
  sudo ./${LIVE_INSTALLER_ENTRY}  interactive install

Both run from the ISO medium; no network needed.
BANNER
cd "\${HOME}"
exec bash -i
EOF
  chmod 0755 "${home}/.local/bin/live-welcome"
  cat >>"${home}/.config/hypr/autostart.lua" <<'EOF'

-- LIVE SESSION ONLY (appended by iso-assemble.sh to the live user's copy;
-- customize removes /home/user): open the installer terminal on the desktop
-- so the medium is actionable without hunting for a shell.
hl.on("hyprland.start", function()
  hl.exec_cmd("kitty --title live-installer -e /home/user/.local/bin/live-welcome")
end)
EOF
}

# assemble STOCK_ISO REPO_DIR OUT_ISO
# Validate, embed the repo (+ optional installer) into the live squashfs, and
# write OUT_ISO. Echoes OUT_ISO.
assemble() {
  local stock_iso="${1:-}" repo_dir="${2:-}" out_iso="${3:-}"

  [[ -n "${stock_iso}" && -n "${repo_dir}" && -n "${out_iso}" ]] \
    || fatal "usage: iso-assemble.sh STOCK_ISO REPO_DIR OUT_ISO"
  [[ -f "${stock_iso}" ]] || fatal "stock ISO not found: ${stock_iso}"
  [[ -d "${repo_dir}" ]] || fatal "repo dir not found: ${repo_dir}"
  validate_repo_layout "${repo_dir}" \
    || fatal "repo dir lacks dists/ and pool/: ${repo_dir}"
  [[ -e "${out_iso}" ]] && fatal "refusing to clobber existing OUT_ISO: ${out_iso}"
  local installer_dir="${HYPR_INSTALLER_DIR:-}"
  [[ -n "${installer_dir}" && ! -d "${installer_dir}" ]] \
    && fatal "HYPR_INSTALLER_DIR not a directory: ${installer_dir}"
  # The path args become positional xorriso tokens; a newline would split one
  # token into two and corrupt the invocation. Reject it outright.
  case "${stock_iso}${repo_dir}${out_iso}${installer_dir}" in
    *$'\n'*) fatal "path arguments must not contain newlines" ;;
  esac

  local work
  work="$(mktemp -d)"
  # iso-assemble runs as its own bash process (build-iso invokes it via `bash
  # iso-assemble.sh`), so this EXIT trap does not clobber the caller's traps.
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" EXIT
  local stock_sqfs="${work}/stock.squashfs" new_sqfs="${work}/filesystem.squashfs"
  local stage="${work}/stage"

  if [[ -n "${GOLDEN_ROOT}" ]]; then
    assemble_golden "${stock_iso}" "${repo_dir}" "${out_iso}" \
      "${installer_dir}" "${work}"
    printf '%s\n' "${out_iso}"
    return 0
  fi

  info "iso-assemble: extracting ${ISO_LIVE_SQUASHFS} from the stock ISO"
  extract_stock_squashfs "${stock_iso}" "${stock_sqfs}"
  info "iso-assemble: staging repo${installer_dir:+ + installer} under ${LIVE_STORE_ROOT}"
  stage_live_payload "${stage}" "${repo_dir}" "${installer_dir}"
  info "iso-assemble: rebuilding the live squashfs with the embedded store"
  rebuild_live_squashfs "${stock_sqfs}" "${stage}" "${new_sqfs}"
  info "iso-assemble: writing ${out_iso} (stock ISO + embedded store in the root)"
  write_iso_with_squashfs "${stock_iso}" "${new_sqfs}" "${out_iso}"

  printf '%s\n' "${out_iso}"
}

# assemble_golden STOCK_ISO STORE_DIR OUT_ISO INSTALLER_DIR WORK
# Golden-mode assembly (issue #111): the golden rootfs becomes the ONE
# squashfs (live session == install image); its kernel/initrd are mapped over
# the stock /live names so the replayed stock boot equipment (BIOS isolinux +
# EFI grub) keeps loading a matching pair; the install store and the
# installer tree ride the ISO9660 medium, NOT the squashfs — the squashfs is
# exactly the tree the installer copies to disk.
assemble_golden() {
  local stock_iso="$1" store_dir="$2" out_iso="$3" installer_dir="$4" work="$5"
  local stock_sqfs="${work}/stock.squashfs" new_sqfs="${work}/filesystem.squashfs"

  [[ -d "${GOLDEN_ROOT}" ]] || fatal "golden root not found: ${GOLDEN_ROOT}"
  # Exactly one kernel, with its live-capable initrd next to it (live-boot is
  # baked into the golden image, so update-initramfs produced a live initrd).
  local kver="" kfile="" ifile=""
  kver="$(detect_live_root_kernel "${GOLDEN_ROOT}")" ||
    fatal "golden root must carry exactly one kernel under /lib/modules"
  kfile="${GOLDEN_ROOT}/boot/vmlinuz-${kver}"
  ifile="${GOLDEN_ROOT}/boot/initrd.img-${kver}"
  [[ -f "${kfile}" ]] || fatal "golden kernel missing: ${kfile}"
  [[ -f "${ifile}" ]] || fatal "golden initrd missing: ${ifile}"
  # The installer unpacks THROUGH the mounted ESP at /target/boot/efi; the
  # image must not carry anything there (issue #111 D3 invariant).
  if [[ -n "$(ls -A "${GOLDEN_ROOT}/boot/efi" 2>/dev/null || true)" ]]; then
    fatal "golden /boot/efi is not empty — the image would write into the mounted ESP"
  fi
  # No chroot guard and no build-time file:// source may ship (step_finalize_golden
  # removes them; assert, because a squashfs with either is broken subtly).
  [[ -e "${GOLDEN_ROOT}/usr/sbin/policy-rc.d" ]] &&
    fatal "golden root still carries policy-rc.d (run step_finalize_golden)"
  if grep -qs 'file://' "${GOLDEN_ROOT}/etc/apt/sources.list" 2>/dev/null; then
    fatal "golden root still carries the build-time file:// apt source"
  fi

  # The stock /live names the boot cfgs reference — our kernel/initrd map
  # over ALL of them (grub uses versioned names, isolinux generic ones; both
  # must load the golden pair). Plan B on layout drift: edit the cfg text.
  local kpaths="" ipaths=""
  { read -r kpaths && read -r ipaths; } \
    < <(probe_stock_live_boot_paths "${stock_iso}" "${work}") ||
    fatal "cannot determine the stock ISO's /live kernel/initrd paths (boot cfg layout changed?)"
  [[ -n "${kpaths}" && -n "${ipaths}" ]] ||
    fatal "cannot determine the stock ISO's /live kernel/initrd paths (boot cfg layout changed?)"
  info "iso-assemble: golden kernel ${kver} maps over ${kpaths} + ${ipaths}"

  # Medium-side paths: the live home seed must point at the medium installer.
  LIVE_STORE_ROOT="/run/live/medium"
  LIVE_REPO_SUBDIR="${ISO_MEDIUM_STORE_DIR#/}"
  LIVE_INSTALLER_SUBDIR="${ISO_MEDIUM_INSTALLER_DIR#/}"
  if [[ -n "${installer_dir}" ]]; then
    stage_golden_home "${GOLDEN_ROOT}"
  fi

  # Compressor/blocksize parity with the stock image (zstd + large blocks;
  # mksquashfs defaults would bloat the image).
  info "iso-assemble: extracting ${ISO_LIVE_SQUASHFS} from the stock ISO (compression params)"
  extract_stock_squashfs "${stock_iso}" "${stock_sqfs}"
  local comp="" bsize=""
  read -r comp bsize < <(detect_squashfs_params "${stock_sqfs}") ||
    fatal "could not read compressor/block size from ${stock_sqfs}"
  rm -f "${stock_sqfs}"
  info "iso-assemble: squashing the golden rootfs (${comp}, block ${bsize})"
  mksquashfs "${GOLDEN_ROOT}" "${new_sqfs}" -noappend -no-progress -no-recovery \
    -comp "${comp}" -b "${bsize}"

  # MokManager onto the ISO's EFI boot image (see the helper's rationale).
  ISO_EFI_APPEND_IMG="$(rebuild_efi_img_with_mokmanager "${stock_iso}" "${GOLDEN_ROOT}" "${work}")"
  export ISO_EFI_APPEND_IMG

  info "iso-assemble: writing ${out_iso} (golden squashfs + medium store)"
  local -a extra_maps=() p=""
  for p in ${kpaths}; do extra_maps+=("${kfile}" "${p}"); done
  for p in ${ipaths}; do extra_maps+=("${ifile}" "${p}"); done
  extra_maps+=("${store_dir}" "${ISO_MEDIUM_STORE_DIR}")
  if [[ -n "${installer_dir}" ]]; then
    extra_maps+=("${installer_dir}" "${ISO_MEDIUM_INSTALLER_DIR}")
  fi
  write_iso_with_squashfs "${stock_iso}" "${new_sqfs}" "${out_iso}" "${extra_maps[@]}"
}

main() {
  assemble "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
