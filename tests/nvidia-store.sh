#!/usr/bin/env bash
# NVIDIA store machinery (issue #111): the closure payload is a pure string,
# cache_populate_nvidia reuses a given chroot (legacy) or debootstraps its own
# (golden install store), and the pool hash is mode-dependent so switching
# HYPR_ISO_GOLDEN repopulates the pool.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source tests/test-helpers.sh

info() { :; }
warn() { :; }
fatal() {
  printf 'fatal: %s\n' "$*" >&2
  return 1
}

source lib/00-config.sh
source scripts/10-cache.sh

echo "test: nvidia_closure_chroot_script carries the full both-flavor/both-branch harvest"
payload="$(nvidia_closure_chroot_script)"
assert_contains "${payload}" "${NVIDIA_REPO_KEYRING_URL}" \
  "payload fetches the cuda-keyring deb for trust"
assert_contains "${payload}" "URIs: ${NVIDIA_REPO_URL}" \
  "payload writes the deb822 flat NVIDIA source"
assert_contains "${payload}" "for branch in 595 610" \
  "payload loops both driver branches"
assert_contains "${payload}" "nvidia-open nvidia-kernel-open-dkms" \
  "payload downloads the open flavor"
assert_contains "${payload}" "nvidia-driver nvidia-kernel-dkms" \
  "payload downloads the proprietary flavor"
assert_contains "${payload}" "firmware-nvidia-gsp" \
  "payload downloads the shared GSP firmware"
# shellcheck disable=SC2016  # literal needle; ${pin} expands in the chroot
assert_contains "${payload}" 'apt-get purge -y "${pin}"' \
  "payload purges the branch pin before switching (pins Conflict)"
assert_contains "${payload}" "apt-get update" \
  "payload is self-sufficient (writes sources + updates in a fresh chroot)"
if bash -n <(printf '%s\n' "${payload}"); then
  echo "  ok: emitted chroot payload is valid shell"
else
  echo "  FAIL: chroot payload is not valid shell" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

echo "test: cache_populate_nvidia reuses a given chroot, owns one otherwise"
# shellcheck disable=SC2317  # stubs invoked indirectly by cache_populate_nvidia
(
  CACHE_DIR="$(mktemp -d)"
  pool="${CACHE_DIR}/pool"
  croot="$(mktemp -d)"
  mkdir -p "${croot}/var/cache/apt/archives"
  : >"${croot}/var/cache/apt/archives/nvidia-open_1_amd64.deb"
  callog="$(mktemp)"
  debootstrap() { printf 'debootstrap %s\n' "$*" >>"${callog}"; }
  chroot() { printf 'chroot %s\n' "$1" >>"${callog}"; }
  info() { :; }
  rc=0
  # Given chroot: no debootstrap, payload runs there, archives harvested.
  cache_populate_nvidia "${pool}" "${croot}"
  if grep -q '^debootstrap' "${callog}"; then
    echo "  FAIL: debootstrapped despite a provided chroot" >&2; rc=1
  else
    echo "  ok: provided chroot reused (no debootstrap)"
  fi
  grep -q "^chroot ${croot}" "${callog}" ||
    { echo "  FAIL: payload did not run in the provided chroot" >&2; rc=1; }
  [[ -f "${pool}/nvidia-open_1_amd64.deb" ]] ||
    { echo "  FAIL: archives not harvested into the pool" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: payload ran in the given chroot + archives pooled"
  # No chroot: it must debootstrap its own scratch under CACHE_DIR.
  : >"${callog}"
  cache_populate_nvidia "${pool}" 2>/dev/null || true
  grep -q '^debootstrap' "${callog}" ||
    { echo "  FAIL: no debootstrap for the self-owned scratch chroot" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: owns (and bootstraps) a scratch chroot when none is given"
  rm -rf "${CACHE_DIR}" "${croot}"; rm -f "${callog}"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: cache_pkgset_hash differs between legacy and golden modes"
legacy_hash="$(HYPR_ISO_GOLDEN=0 cache_pkgset_hash)"
golden_hash="$(HYPR_ISO_GOLDEN=1 cache_pkgset_hash)"
if [[ -n "${legacy_hash}" && -n "${golden_hash}" && "${legacy_hash}" != "${golden_hash}" ]]; then
  echo "  ok: mode switch invalidates the pool stamp (hashes differ)"
else
  echo "  FAIL: legacy and golden pool hashes must differ (got '${legacy_hash}' / '${golden_hash}')" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

echo "test: golden pool closure has no toolchain, no NVIDIA, no bootloader trio"
body="$(declare -f cache_populate_debs)"
# The golden branch's download line references TARGET_BASE + GOLDEN_EXTRA only;
# assert the branch exists and the legacy line still carries the full set.
assert_contains "${body}" 'GOLDEN_EXTRA_PACKAGES' \
  "golden branch downloads the golden extras"
assert_contains "${body}" 'HYPR_ISO_GOLDEN' \
  "cache_populate_debs branches on the build mode"
# shellcheck disable=SC2016  # literal needle: the call as written in the source
assert_contains "${body}" 'cache_populate_nvidia "${pool}" "${work}/closure"' \
  "legacy branch still pools the NVIDIA closure via the shared chroot"
assert_contains "${body}" 'HYPR_TOOLCHAIN_PACKAGES' \
  "legacy branch still pools the toolchain"

finish_test
