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
mkdir -p "${tmp}/repo/dists/trixie/main/binary-amd64" "${tmp}/repo/pool"
touch "${tmp}/repo/dists/trixie/Release"
printf 'Filename: pool/fake_1.0_amd64.deb\n' \
  >"${tmp}/repo/dists/trixie/main/binary-amd64/Packages"
touch "${tmp}/repo/pool/fake_1.0_amd64.deb"
out="$(run_validate)"
assert_contains "${out}" "Cache repo valid" "complete repo passes"

# Packages references a deb missing from the pool -> fails.
printf 'Filename: pool/gone_2.0_amd64.deb\n' \
  >>"${tmp}/repo/dists/trixie/main/binary-amd64/Packages"
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "deb missing from pool" "missing pooled deb reported"
assert_fails "missing pooled deb fails validation" run_validate

finish_test
