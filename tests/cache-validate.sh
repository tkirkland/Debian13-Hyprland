#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: cache validation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# cache_validate gates on CACHE_REPO_DIR — the on-ISO store path when booted
# from our offline ISO (preflight points it at ISO_MEDIUM_REPO). Pre-seed the
# env so config's ${CACHE_REPO_DIR:-...} default picks it up, exactly as
# preflight does at install time.
run_validate() {
  CACHE_REPO_DIR="${tmp}/repo" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/10-cache.sh
    cache_validate
  '
}

# Empty repo -> fails, naming the missing index (no source/ZBM contract now).
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "repo index" "missing repo index reported"
assert_fails "empty repo fails validation" run_validate

# Minimal complete repo (dists + Release + every pooled deb present) -> passes.
# The offline contract also requires the NVIDIA driver debs (both flavors and
# branches) plus cuda-keyring, so seed a stanza + pooled file for each.
pkgindex="${tmp}/repo/dists/trixie/main/binary-amd64/Packages"
mkdir -p "${tmp}/repo/dists/trixie/main/binary-amd64" "${tmp}/repo/pool"
touch "${tmp}/repo/dists/trixie/Release"
seed_pkg() {
  printf 'Package: %s\nFilename: pool/%s.deb\n\n' "$1" "$1" >>"${pkgindex}"
  touch "${tmp}/repo/pool/$1.deb"
}
: >"${pkgindex}"
seed_pkg fake
# chezmoi is harvested into the pool on every populate path and installed offline
# by name, so the offline contract requires it indexed.
seed_pkg chezmoi
for nv in cuda-keyring \
  nvidia-open nvidia-kernel-open-dkms \
  nvidia-driver nvidia-kernel-dkms \
  nvidia-driver-pinning-595 nvidia-driver-pinning-610; do
  seed_pkg "${nv}"
done
# The offline path also installs the upstream OpenZFS debs by name from the pool
# (install_zfs_offline), so the offline contract requires them indexed too.
# run_validate leaves NETWORK_AVAILABLE empty (= offline), so they are asserted.
for z in openzfs-zfsutils openzfs-zfs-dkms openzfs-zfs-initramfs openzfs-zfs-zed; do
  seed_pkg "${z}"
done
# Prebuilt-kmod contract (issue #110): offline also requires the store's
# KERNEL_PINNED + KERNEL_TARGET files and a prebuilt openzfs-zfs-modules-<kver>
# deb indexed for EACH named kernel (live pin and pool-metapackage target).
seed_pkg "openzfs-zfs-modules-6.12.38+deb13-amd64"
seed_pkg "openzfs-zfs-modules-6.12.44+deb13-amd64"
echo "6.12.38+deb13-amd64" >"${tmp}/repo/KERNEL_PINNED"
echo "6.12.44+deb13-amd64" >"${tmp}/repo/KERNEL_TARGET"
out="$(run_validate)"
assert_contains "${out}" "Cache repo valid" "complete repo passes (offline contract)"

# Offline, KERNEL_PINNED removed -> fails naming it.
mv "${tmp}/repo/KERNEL_PINNED" "${tmp}/repo/KERNEL_PINNED.gone"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "KERNEL_PINNED missing" "offline requires the store's kernel pin"
mv "${tmp}/repo/KERNEL_PINNED.gone" "${tmp}/repo/KERNEL_PINNED"

# Offline, KERNEL_TARGET removed -> fails naming it.
mv "${tmp}/repo/KERNEL_TARGET" "${tmp}/repo/KERNEL_TARGET.gone"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "KERNEL_TARGET missing" "offline requires the store's target kernel"
mv "${tmp}/repo/KERNEL_TARGET.gone" "${tmp}/repo/KERNEL_TARGET"

# Offline, the TARGET kernel's kmod deb dropped from the index -> fails naming
# that specific kernel (a pin-only store from before the skew fix is rejected).
sed -i '/openzfs-zfs-modules-6.12.44/,+2d' "${pkgindex}"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "openzfs-zfs-modules-6.12.44+deb13-amd64 deb missing" \
  "offline requires a prebuilt kmod deb for the TARGET kernel, not just the pin"
seed_pkg "openzfs-zfs-modules-6.12.44+deb13-amd64"

# Gating: the upstream OpenZFS assertion fires ONLY offline. With the openzfs
# debs removed from the index, the OFFLINE validate must fail naming them, but
# the ONLINE validate (which builds zfs from source, never from the pool) passes.
zfsless="${tmp}/zfsless"
mkdir -p "${zfsless}/dists/trixie/main/binary-amd64" "${zfsless}/pool"
touch "${zfsless}/dists/trixie/Release"
zi="${zfsless}/dists/trixie/main/binary-amd64/Packages"
: >"${zi}"
for pk in fake chezmoi cuda-keyring \
  nvidia-open nvidia-kernel-open-dkms nvidia-driver nvidia-kernel-dkms \
  nvidia-driver-pinning-595 nvidia-driver-pinning-610; do
  printf 'Package: %s\nFilename: pool/%s.deb\n\n' "${pk}" "${pk}" >>"${zi}"
  touch "${zfsless}/pool/${pk}.deb"
done
out="$(CACHE_REPO_DIR="${zfsless}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source scripts/10-cache.sh
  NETWORK_AVAILABLE=0; cache_validate' 2>&1 || true)"
assert_contains "${out}" "upstream OpenZFS deb missing" "offline requires upstream OpenZFS debs"
# With the kernel files present but no kmod debs indexed, BOTH named kernels
# must be flagged (the per-kver check needs the store's kernel names to run).
echo "6.12.38+deb13-amd64" >"${zfsless}/KERNEL_PINNED"
echo "6.12.44+deb13-amd64" >"${zfsless}/KERNEL_TARGET"
out="$(CACHE_REPO_DIR="${zfsless}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source scripts/10-cache.sh
  NETWORK_AVAILABLE=0; cache_validate' 2>&1 || true)"
assert_contains "${out}" "openzfs-zfs-modules-6.12.38+deb13-amd64 deb missing" \
  "offline requires the prebuilt kmod deb for the pinned kernel indexed"
assert_contains "${out}" "openzfs-zfs-modules-6.12.44+deb13-amd64 deb missing" \
  "offline requires the prebuilt kmod deb for the target kernel indexed"
out="$(CACHE_REPO_DIR="${zfsless}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source scripts/10-cache.sh
  NETWORK_AVAILABLE=1; cache_validate' 2>&1 || true)"
assert_contains "${out}" "Cache repo valid" "online validate does not require pooled OpenZFS"

# Missing NVIDIA debs -> fails the offline contract.
nv_only="${tmp}/nvonly"
mkdir -p "${nv_only}/dists/trixie/main/binary-amd64" "${nv_only}/pool"
touch "${nv_only}/dists/trixie/Release"
printf 'Package: fake\nFilename: pool/fake.deb\n\n' \
  >"${nv_only}/dists/trixie/main/binary-amd64/Packages"
touch "${nv_only}/pool/fake.deb"
out="$(CACHE_REPO_DIR="${nv_only}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source scripts/10-cache.sh
  cache_validate' 2>&1 || true)"
assert_contains "${out}" "NVIDIA driver deb missing" "missing NVIDIA debs reported"

# Packages references a deb missing from the pool -> fails.
printf 'Filename: pool/gone_2.0_amd64.deb\n' >>"${pkgindex}"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "deb missing from pool" "missing pooled deb reported"
assert_fails "missing pooled deb fails validation" run_validate

finish_test
