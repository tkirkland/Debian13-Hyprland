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

# live_extras_chroot_script PACKAGES
# Emit (stdout) the `sh -c` payload run inside the live-root chroot to install the
# extras. When openssh-server is in the set, append an explicit offline
# `systemctl enable ssh.service` so sshd is enabled to start on live boot:
# Debian's postinst normally enables it, but doing it explicitly makes the
# behaviour guaranteed (and unit-testable) instead of an implicit maintainer-
# script side effect. SYSTEMD_OFFLINE=1 forces systemctl to act purely on the
# filesystem (there is no running manager / D-Bus in the build chroot). Pure
# (string only), so tests can assert the payload without a real chroot.
live_extras_chroot_script() {
  local pkgs="$1" script=""
  # Use ONLY our online mirror for this install: -o SourceList points at a temp
  # list and an empty SourceParts ignores the live root's medium-based sources
  # (file:/run/live/medium/...) that are absent at build time. See
  # LIVE_EXTRA_APT_SOURCE. Options after the package names so a plain
  # `apt-get install ... ${pkgs}` substring stays intact.
  local list="/etc/apt/sources.list.d/zz-live-extras-build.list"
  local aopt="-o Dir::Etc::SourceList=${list} -o Dir::Etc::SourceParts=/dev/null"
  script="printf '%s\\n' '${LIVE_EXTRA_APT_SOURCE}' >${list} &&"
  script+=" apt-get update -qq ${aopt} &&"
  script+=" apt-get install -y --no-install-recommends ${pkgs} ${aopt} &&"
  case " ${pkgs} " in
    *" openssh-server "*)
      script+=" SYSTEMD_OFFLINE=1 systemctl enable ssh.service &&" ;;
  esac
  script+=" rm -f ${list} && apt-get clean && rm -rf /var/lib/apt/lists/*"
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
  local resolv="${root}/etc/resolv.conf" resolv_bak=""
  if [[ -e "${resolv}" || -L "${resolv}" ]]; then
    resolv_bak="${resolv}.iso-assemble.bak"; mv "${resolv}" "${resolv_bak}"
  fi
  cp -L /etc/resolv.conf "${resolv}" 2>/dev/null || true
  local m mounted=()
  for m in dev dev/pts proc sys; do
    mount --bind "/${m}" "${root}/${m}" && mounted=("${root}/${m}" "${mounted[@]}")
  done
  info "iso-assemble: baking live extras into the squashfs: ${LIVE_EXTRA_PACKAGES}"
  local rc=0
  chroot "${root}" env DEBIAN_FRONTEND=noninteractive sh -c \
    "$(live_extras_chroot_script "${LIVE_EXTRA_PACKAGES}")" || rc=$?
  for m in "${mounted[@]}"; do umount -l "${m}" 2>/dev/null || true; done
  rm -f "${resolv}"
  [[ -n "${resolv_bak}" ]] && mv "${resolv_bak}" "${resolv}"
  ((rc == 0)) || fatal "live-extras install failed (rc=${rc})"
}

# build_write_iso_args STOCK_ISO NEW_SQUASHFS OUT_ISO
# Emit (one per line) the native-xorriso argv that writes OUT_ISO = STOCK_ISO
# with the live squashfs replaced by NEW_SQUASHFS and the d-i pool stripped,
# replaying the stock El-Torito BIOS + EFI boot images so OUT_ISO stays bootable.
# Split out as a pure seam so the argv is unit-testable without xorriso.
build_write_iso_args() {
  local stock="$1" sqfs="$2" out="$3"
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
  printf '%s\n' -boot_image any replay -compliance no_emul_toc -padding included
  printf '%s\n' -commit
}

# write_iso_with_squashfs STOCK_ISO NEW_SQUASHFS OUT_ISO — run the xorriso write.
write_iso_with_squashfs() {
  local -a args=()
  mapfile -t args < <(build_write_iso_args "$1" "$2" "$3")
  xorriso "${args[@]}"
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

main() {
  assemble "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
