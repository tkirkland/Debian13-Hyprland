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
# installer is optional: repo-only staging must not create the installer subdir.
stage2="$(mktemp -d)"; stage_live_payload "${stage2}" "${repo}"
if [[ -d "${stage2}${LIVE_STORE_ROOT}/${LIVE_REPO_SUBDIR}/dists" \
   && ! -e "${stage2}${LIVE_STORE_ROOT}/${LIVE_INSTALLER_SUBDIR}" ]]; then
  echo "  ok: installer staging is optional"
else
  echo "  FAIL: repo-only staging mishandled" >&2; TEST_FAILURES=$((TEST_FAILURES+1))
fi
rm -rf "${repo}" "${inst}" "${stage}" "${stage2}"

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
