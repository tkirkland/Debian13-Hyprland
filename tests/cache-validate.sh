#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: install-store validation (NVIDIA + KERNEL contract, issue #111)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# cache_validate gates on CACHE_REPO_DIR — the medium install store when
# booted from our ISO (preflight points it at ISO_MEDIUM_REPO). Pre-seed the
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

# Empty repo -> fails, naming the missing index.
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "repo index" "missing repo index reported"
assert_fails "empty repo fails validation" run_validate

# Minimal complete store (dists + Release + every pooled deb present + the
# NVIDIA closure for both flavors and branches + cuda-keyring + the KERNEL
# stamp) -> passes. Everything else ships baked in the golden squashfs, so
# the store contract asserts nothing else.
pkgindex="${tmp}/repo/dists/trixie/main/binary-amd64/Packages"
mkdir -p "${tmp}/repo/dists/trixie/main/binary-amd64" "${tmp}/repo/pool"
touch "${tmp}/repo/dists/trixie/Release"
seed_pkg() {
  printf 'Package: %s\nFilename: pool/%s.deb\n\n' "$1" "$1" >>"${pkgindex}"
  touch "${tmp}/repo/pool/$1.deb"
}
: >"${pkgindex}"
seed_pkg fake
for nv in cuda-keyring \
  nvidia-open nvidia-kernel-open-dkms \
  nvidia-driver nvidia-kernel-dkms \
  nvidia-driver-pinning-595 nvidia-driver-pinning-610; do
  seed_pkg "${nv}"
done
echo "6.12.44+deb13-amd64" >"${tmp}/repo/KERNEL"
out="$(run_validate)"
assert_contains "${out}" "Install store valid" "complete store passes"

# KERNEL stamp removed -> fails naming it (sign_zfs_modules and the preflight
# pin warning read it).
mv "${tmp}/repo/KERNEL" "${tmp}/repo/KERNEL.gone"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "KERNEL stamp missing" "store requires the KERNEL stamp"
mv "${tmp}/repo/KERNEL.gone" "${tmp}/repo/KERNEL"

# The store must NOT be required to carry the golden image's baked content:
# no chezmoi / openzfs / legacy kernel-pair assertions survive from the old
# pool contract (they would fail every golden store).
body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/10-cache.sh; declare -f cache_validate')"
for legacy in chezmoi openzfs KERNEL_PINNED KERNEL_TARGET; do
  if [[ "${body}" == *"${legacy}"* ]]; then
    echo "  FAIL: cache_validate still asserts legacy pool content: ${legacy}" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    echo "  ok: no legacy ${legacy} assertion in the store contract"
  fi
done

# Missing NVIDIA debs -> fails the store contract.
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
