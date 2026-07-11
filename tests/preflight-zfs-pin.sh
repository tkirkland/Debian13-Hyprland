#!/usr/bin/env bash
# tests/preflight-zfs-pin.sh — bootstrap_live_tools vs the store's KERNEL_PINNED
# (issue #110): a pin/running-kernel mismatch WARNS (never fatal — the module
# baked into the live squashfs keeps the session working), and when the module
# probe fails the PREBUILT openzfs kmod deb is preferred over the dkms path
# only when the pin matches the running kernel.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source tests/test-helpers.sh

repo="$(mktemp -d)"
trap 'rm -rf "${repo}"' EXIT
mkdir -p "${repo}/dists/trixie/main/binary-amd64"
: >"${repo}/dists/trixie/main/binary-amd64/Packages"
echo "6.12.38+deb13-amd64" >"${repo}/KERNEL_PINNED"

# Every tool probe is satisfied by a stub function (command -v resolves shell
# functions), so bootstrap_live_tools exercises ONLY the zfs/pin logic: uname
# fakes the running kernel, modinfo fakes module presence, and the offline
# install sink (install_from_cache_repo) echoes what it would install.
run_bootstrap() { # $1=running kernel  $2=module present (0/1)
  CACHE_REPO_DIR="${repo}" RUNNING="$1" MODPRESENT="$2" bash -c '
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/10-cache.sh; source scripts/00-preflight.sh
    uname() { echo "${RUNNING}"; }
    modinfo() { ((MODPRESENT)); }
    modprobe() { return 0; }
    for t in debootstrap sgdisk partprobe mdadm mkfs.vfat zpool \
      apt-ftparchive git curl efibootmgr rsync fuser openssl; do
      eval "${t}() { :; }"
    done
    install_from_cache_repo() { echo "CACHE-INSTALL: $*"; }
    NETWORK_AVAILABLE=0
    bootstrap_live_tools
  ' 2>&1
}

echo "test: kernel-pin mismatch warns loudly but never aborts"
out="$(run_bootstrap 6.99.0-other 1)"
rc=$?
assert_eq "0" "${rc}" "mismatch is non-fatal (baked live module still works)"
assert_contains "${out}" "built for kernel 6.12.38+deb13-amd64" \
  "warning names the kernel the medium was built for"
assert_contains "${out}" "6.99.0-other" "warning names the running kernel"

echo "test: matching pin stays silent"
out="$(run_bootstrap 6.12.38+deb13-amd64 1)"
if [[ "${out}" != *"built for kernel"* ]]; then
  echo "  ok: no mismatch warning when pin == running kernel"
else
  echo "  FAIL: warned despite a matching pin" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

echo "test: module missing + matching pin -> PREBUILT kmod deb from the store"
out="$(run_bootstrap 6.12.38+deb13-amd64 0)"
assert_contains "${out}" "CACHE-INSTALL:" "offline install goes through the store"
assert_contains "${out}" "openzfs-zfs-modules-6.12.38+deb13-amd64" \
  "prebuilt kmod deb preferred over the dkms path"
if [[ "${out}" != *zfs-dkms* ]]; then
  echo "  ok: dkms path skipped when the prebuilt kmod fits"
else
  echo "  FAIL: dkms still requested despite a matching prebuilt kmod" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

echo "test: module missing + pin mismatch -> dkms fallback unchanged"
out="$(run_bootstrap 6.99.0-other 0)"
assert_contains "${out}" "zfs-dkms" "pin mismatch falls back to the dkms path"
if [[ "${out}" != *openzfs-zfs-modules-* ]]; then
  echo "  ok: mismatched prebuilt kmod is never installed"
else
  echo "  FAIL: prebuilt kmod installed for the wrong kernel" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
