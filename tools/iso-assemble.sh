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

# extract_stock_iso STOCK_ISO WORKDIR
# Extract the entire stock ISO tree into WORKDIR via xorriso osirrox.
extract_stock_iso() {
  local stock_iso="$1" workdir="$2"
  xorriso -osirrox on -indev "${stock_iso}" -extract / "${workdir}"
}

# inject_repo REPO_DIR WORKDIR
# Copy REPO_DIR into WORKDIR as a top-level dir named by ISO_DATA_SUBDIR.
inject_repo() {
  local repo_dir="$1" workdir="$2"
  local dest="${workdir%/}/${ISO_DATA_SUBDIR}"
  rm -rf "${dest}"
  cp -a "${repo_dir%/}/." "${dest}/"
}

# repack_iso STOCK_ISO WORKDIR OUT_ISO
# Repack WORKDIR into OUT_ISO, replaying the stock ISO's boot images so the
# resulting ISO keeps the original BIOS El-Torito + EFI boot configuration.
repack_iso() {
  local stock_iso="$1" workdir="$2" out_iso="$3"
  xorriso -as mkisofs \
    -indev "${stock_iso}" \
    -outdev "${out_iso}" \
    -boot_image any replay \
    -volid "HYPR_OFFLINE" \
    "${workdir}"
}

# assemble STOCK_ISO REPO_DIR OUT_ISO
# Orchestrates validation, extract, inject, repack. Echoes OUT_ISO on success.
assemble() {
  local stock_iso="${1:-}" repo_dir="${2:-}" out_iso="${3:-}"

  [[ -n "${stock_iso}" && -n "${repo_dir}" && -n "${out_iso}" ]] \
    || fatal "usage: iso-assemble.sh STOCK_ISO REPO_DIR OUT_ISO"
  [[ -f "${stock_iso}" ]] || fatal "stock ISO not found: ${stock_iso}"
  [[ -d "${repo_dir}" ]] || fatal "repo dir not found: ${repo_dir}"
  validate_repo_layout "${repo_dir}" \
    || fatal "repo dir lacks dists/ and pool/: ${repo_dir}"
  [[ -e "${out_iso}" ]] && fatal "refusing to clobber existing OUT_ISO: ${out_iso}"

  local workdir
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${workdir}'" RETURN

  info "iso-assemble: extracting ${stock_iso} -> ${workdir}"
  extract_stock_iso "${stock_iso}" "${workdir}"
  info "iso-assemble: injecting ${repo_dir} as /${ISO_DATA_SUBDIR}"
  inject_repo "${repo_dir}" "${workdir}"
  info "iso-assemble: repacking -> ${out_iso}"
  repack_iso "${stock_iso}" "${workdir}" "${out_iso}"

  printf '%s\n' "${out_iso}"
}

main() {
  assemble "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
