#!/usr/bin/env bash
# shellcheck shell=bash
# iso-assemble.sh — inject the offline apt repo into a copy of the stock live
# ISO as a PLAIN top-level DATA DIRECTORY (decided: NOT inside the squashfs),
# preserving the original El-Torito BIOS + EFI boot setup.
#
# Usage: iso-assemble.sh STOCK_ISO REPO_DIR OUT_ISO
#
# HOST SAFETY: this tool only reads STOCK_ISO/REPO_DIR and writes into a fresh
# mktemp workdir and the (non-existent) OUT_ISO. It runs no apt/dpkg/chroot and
# never writes under system paths. The heavy xorriso extract/repack is kept in
# functions and is exercised for real only in Phase 3b integration.

set -euo pipefail

# Top-level directory name under which the repo is injected on the ISO.
ISO_DATA_SUBDIR="${ISO_DATA_SUBDIR:-hypr-repo}"
# Top-level directory for the installer tree (when HYPR_INSTALLER_DIR is set).
ISO_INSTALLER_SUBDIR="${ISO_INSTALLER_SUBDIR:-hypr-installer}"
# Stock paths to drop from the output ISO: Debian's own live-installer (d-i)
# pool + metadata, which this distro never uses (it installs via our own
# installer + /hypr-repo). Removing them reclaims the ~200 base .debs that would
# otherwise be duplicated in /hypr-repo/pool. The live session (booted from
# /live/filesystem.squashfs) is untouched; only d-i boot-menu entries break.
# Space-separated; override via HYPR_ISO_STRIP, empty to keep everything.
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

# add_repo_to_iso STOCK_ISO REPO_DIR OUT_ISO
# Copy STOCK_ISO to OUT_ISO with REPO_DIR added as the top-level /ISO_DATA_SUBDIR,
# replaying the stock ISO's El-Torito BIOS + EFI boot images so OUT_ISO stays
# bootable. Uses NATIVE xorriso (NOT `-as mkisofs`, which rejects -indev): -indev
# loads the stock image, -outdev targets a NEW file, -boot_image any replay
# preserves the original boot setup, -map grafts the repo tree, -commit writes it.
# No full extraction needed.
add_repo_to_iso() {
  local stock_iso="$1" repo_dir="$2" out_iso="$3"
  local -a args=(
    -indev "${stock_iso}"
    -outdev "${out_iso}"
    -boot_image any replay
    -volid 'HYPR_OFFLINE'
  )
  # Strip the unused Debian d-i pool/metadata. -abort_on NEVER makes a missing
  # path non-fatal (a different stock layout just strips less); restore strict
  # aborting immediately after.
  if [[ -n "${ISO_STRIP_PATHS}" ]]; then
    local -a strip
    read -r -a strip <<<"${ISO_STRIP_PATHS}"
    args+=(-abort_on NEVER -rm_r "${strip[@]}" -- -abort_on FAILURE)
  fi
  args+=(-map "${repo_dir%/}" "/${ISO_DATA_SUBDIR}")
  # Optionally graft the installer tree so the booted live ISO can run the
  # installer fully offline (no git clone). HYPR_INSTALLER_DIR is a prepared,
  # filtered copy (no tools/docs/tests/.git) staged by build-iso.
  if [[ -n "${HYPR_INSTALLER_DIR:-}" ]]; then
    [[ -d "${HYPR_INSTALLER_DIR}" ]] \
      || fatal "HYPR_INSTALLER_DIR not a directory: ${HYPR_INSTALLER_DIR}"
    args+=(-map "${HYPR_INSTALLER_DIR%/}" "/${ISO_INSTALLER_SUBDIR}")
  fi
  args+=(-commit)
  xorriso "${args[@]}"
}

# assemble STOCK_ISO REPO_DIR OUT_ISO
# Validate, then write OUT_ISO = STOCK_ISO + /ISO_DATA_SUBDIR. Echoes OUT_ISO.
assemble() {
  local stock_iso="${1:-}" repo_dir="${2:-}" out_iso="${3:-}"

  [[ -n "${stock_iso}" && -n "${repo_dir}" && -n "${out_iso}" ]] \
    || fatal "usage: iso-assemble.sh STOCK_ISO REPO_DIR OUT_ISO"
  [[ -f "${stock_iso}" ]] || fatal "stock ISO not found: ${stock_iso}"
  [[ -d "${repo_dir}" ]] || fatal "repo dir not found: ${repo_dir}"
  validate_repo_layout "${repo_dir}" \
    || fatal "repo dir lacks dists/ and pool/: ${repo_dir}"
  [[ -e "${out_iso}" ]] && fatal "refusing to clobber existing OUT_ISO: ${out_iso}"

  info "iso-assemble: writing ${out_iso} = stock ISO + /${ISO_DATA_SUBDIR}"
  add_repo_to_iso "${stock_iso}" "${repo_dir}" "${out_iso}"

  printf '%s\n' "${out_iso}"
}

main() {
  assemble "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
