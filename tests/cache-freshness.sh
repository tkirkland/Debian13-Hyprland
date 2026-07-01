#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

# Regression: step_cache reused a stale offline pool because its gate
# (cache_repo_exists) only checked that a Packages index EXISTED, never whether
# the pool matched the current package sets. A build that added packages to
# TARGET_BASE_PACKAGES then reused an older pool, and step_depsim failed with
# "Unable to locate package ..." for exactly the newly-added names. The fix
# stamps the pool with a hash of the package sets; a missing or mismatched stamp
# means "stale -> repopulate" (missing also auto-recovers pre-stamp caches).
echo "test: offline cache package-set freshness stamp"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Run a snippet with the cache modules sourced and a scratch CACHE_DIR.
run() {
  CACHE_DIR="${tmp}/cache" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/10-cache.sh
    mkdir -p "${CACHE_DIR}"
    '"$1"'
  '
}

# 1. Hash is deterministic for identical package sets.
h1="$(run 'cache_pkgset_hash')"
h2="$(run 'cache_pkgset_hash')"
assert_eq "${h1}" "${h2}" "cache_pkgset_hash is deterministic"

# 2. Hash is content-sensitive: adding a package changes it.
h3="$(run 'TARGET_BASE_PACKAGES+=(zzz-freshness-probe); cache_pkgset_hash')"
if [[ "${h1}" == "${h3}" ]]; then
  echo "  FAIL: hash unchanged after adding a package" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: hash changes when the package set changes"
fi

# 3. Hash is order-independent (reordering must not invalidate the pool).
h4="$(run 'TARGET_BASE_PACKAGES=($(printf "%s\n" "${TARGET_BASE_PACKAGES[@]}" | tac)); cache_pkgset_hash')"
assert_eq "${h1}" "${h4}" "cache_pkgset_hash is order-independent"

# 4. cache_pkgset_fresh honors the stamp file.
fresh_state() {
  run "$1"'
    if cache_pkgset_fresh; then echo fresh; else echo stale; fi
  '
}
assert_eq "stale" "$(fresh_state '')" \
  "missing stamp reads as stale (auto-recovers pre-stamp caches)"
assert_eq "fresh" \
  "$(fresh_state 'cache_pkgset_hash > "${CACHE_DIR}/.pkgset.sha256";')" \
  "stamp matching the current package set reads as fresh"
assert_eq "stale" \
  "$(fresh_state 'echo deadbeef > "${CACHE_DIR}/.pkgset.sha256";')" \
  "stamp not matching the current package set reads as stale"

finish_test
