#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: ZFS hostid continuity (live -> pool -> target)"

# The installed system MUST carry the same hostid the pool was created with
# (the live environment's), or zfs-initramfs refuses the import at first boot
# ("pool was previously in use from another system" / hostid mismatch). Two
# halves must hold:
#   1. the live env has a stable /etc/hostid BEFORE the pool is created, so the
#      pool is stamped with a real, reproducible hostid;
#   2. 40-system copies that very /etc/hostid into the target instead of minting
#      a fresh one in the chroot (which can never match the pool).
source lib/00-config.sh
source lib/01-log.sh
source scripts/20-storage.sh
source scripts/40-system.sh

create_fn="$(declare -f create_pool_and_datasets)"
assert_contains "${create_fn}" "zgenhostid" \
  "live env ensures a stable /etc/hostid before the pool is created"
if [[ "${create_fn}" == *"zgenhostid"*"zpool create"* ]]; then
  echo "  ok: hostid is ensured before zpool create"
else
  echo "  FAIL: zgenhostid must run before zpool create (pool must record it)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
# The live env runs the same upstream OpenZFS 2.4.x as the target (prebuilt
# bake), so the pool's enabled feature set must be capped EXPLICITLY — the
# boot chain (ZFSBootMenu's embedded zfs) has to import this pool.
assert_contains "${create_fn}" "compatibility=openzfs-2.3-linux" \
  "zpool create caps enabled features explicitly (boot-chain importable)"

boot_fn="$(declare -f configure_zfs_boot_support)"
assert_contains "${boot_fn}" "/etc/hostid" \
  "target inherits the live hostid"
assert_contains "${boot_fn}" "TARGET" \
  "the hostid is copied into the target tree"
if [[ "${boot_fn}" == *"zgenhostid"* ]]; then
  echo "  FAIL: target must NOT regenerate its hostid (guarantees a pool mismatch)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: target does not regenerate its hostid"
fi

finish_test
