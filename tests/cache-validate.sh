#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: cache validation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

run_validate() {
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/10-cache.sh
    CACHE_DIR='${tmp}/cache'
    cache_validate
  "
}

# Empty cache -> fails listing what's missing.
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "repo index" "missing repo reported"
assert_contains "${out}" "sources manifest" "missing manifest reported"
assert_fails "empty cache fails validation" run_validate

# Minimal complete cache -> passes.
mkdir -p "${tmp}/cache/repo/dists/trixie/main/binary-amd64" \
  "${tmp}/cache/repo/pool" "${tmp}/cache/sources"
touch "${tmp}/cache/repo/dists/trixie/Release"
printf 'Filename: pool/fake_1.0_amd64.deb\n' \
  >"${tmp}/cache/repo/dists/trixie/main/binary-amd64/Packages"
touch "${tmp}/cache/repo/pool/fake_1.0_amd64.deb"
printf 'hyprland v0.50.1\n' >"${tmp}/cache/sources/MANIFEST"
touch "${tmp}/cache/sources/hyprland-v0.50.1.tar.gz"
touch "${tmp}/cache/zfsbootmenu.EFI"
out="$(run_validate)"
assert_contains "${out}" "Cache valid" "complete cache passes"

# Manifest references a missing tarball -> fails.
printf 'hyprutils v0.8.2\n' >>"${tmp}/cache/sources/MANIFEST"
assert_fails "missing source tarball fails validation" run_validate

finish_test
