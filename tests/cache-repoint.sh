#!/usr/bin/env bash
# set -e is intentionally OFF: the tests capture exit codes from subshells
# (install_zbm fatal paths) and must not abort the runner on a nonzero rc.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source tests/test-helpers.sh

echo "test: Issue 3 -- install consumers read the on-ISO store, not a 2nd cache"

# --- install_zbm resolves the ZBM EFI from the on-ISO store (CACHE_REPO_DIR) ---
# offline, with NO install-time CACHE_DIR copy involved.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
store="${tmp}/store"
mkdir -p "${store}"
printf 'EFI\n' >"${store}/zfsbootmenu.EFI"

if (
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/50-boot.sh
  CACHE_REPO_DIR="${store}"
  TARGET="${tmp}/target"
  ESP_MOUNT="/boot/efi"
  ROOT_DATASET="rpool/ROOT/debian"
  NETWORK_AVAILABLE=0
  # Stub the bootloader plumbing install_zbm calls after resolving the source.
  zfs() { :; }
  install_shim() { :; }
  sign_loader() { :; }
  create_nvram_entry() { :; }
  install_zbm
); then
  echo "  ok: install_zbm succeeds offline from the on-ISO store"
else
  echo "  FAIL: install_zbm failed offline from the on-ISO store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_eq "EFI" "$(cat "${tmp}/target/boot/efi/EFI/zbm/zfsbootmenu.efi" 2>/dev/null)" \
  "install_zbm copies the EFI from CACHE_REPO_DIR (on-ISO store), not CACHE_DIR"

# Negative: empty store + no network must FATAL (proves the dropped CACHE_DIR
# candidate was unnecessary, and the offline error names the store path).
neg_out="${tmp}/neg.out"
if (
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/50-boot.sh
  CACHE_REPO_DIR="${tmp}/empty"
  TARGET="${tmp}/target"
  ESP_MOUNT="/boot/efi"
  ROOT_DATASET="rpool/ROOT/debian"
  NETWORK_AVAILABLE=0
  install_zbm
) >"${neg_out}" 2>&1; then
  echo "  FAIL: install_zbm did not fatal on an empty offline store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: install_zbm fatals offline when the store lacks the EFI"
fi
assert_contains "$(cat "${neg_out}")" "${tmp}/empty" \
  "the offline fatal names the store path (CACHE_REPO_DIR)"

# --- build-iso override keeps the BUILD-TIME pool working ---------------------
# CACHE_REPO_DIR no longer derives from CACHE_DIR, so build-iso repoints it to
# its workspace pool. Replicate that and assert cache_repo_exists checks the
# workspace path (regression for the latent resume-skip bug).
ws="${tmp}/ws"
mkdir -p "${ws}/cache/repo/dists/trixie/main/binary-amd64"
: >"${ws}/cache/repo/dists/trixie/main/binary-amd64/Packages"
if (
  source lib/00-config.sh
  source scripts/10-cache.sh
  # build-iso's overrides (tools/build-iso.sh:68,73):
  CACHE_DIR="${ws}/cache"
  CACHE_REPO_DIR="${CACHE_DIR}/repo"
  SUITE="trixie"
  ARCH="amd64"
  cache_repo_exists
); then
  echo "  ok: cache_repo_exists checks the build workspace pool (build-time path intact)"
else
  echo "  FAIL: cache_repo_exists did not see the build workspace pool" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- firstboot manifest lands in the target-internal sources dir --------------
# stage_firstboot writes MANIFEST under ${TARGET}${HYPR_SRC_DIR}/sources and the
# generated runner sets CACHE_DIR=${HYPR_SRC_DIR} -- NOT the removed cache.
src_fn="$(
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/60-hyprland.sh
  declare -f stage_firstboot
)"
# shellcheck disable=SC2016  # asserting the literal unexpanded source text
assert_contains "${src_fn}" '${TARGET}${HYPR_SRC_DIR}/sources/MANIFEST' \
  "firstboot MANIFEST is written under the staged sources dir (HYPR_SRC_DIR)"
# shellcheck disable=SC2016  # asserting the literal unexpanded source text
assert_contains "${src_fn}" 'CACHE_DIR="${HYPR_SRC_DIR}"' \
  "firstboot runner points CACHE_DIR at HYPR_SRC_DIR (not the removed cache)"

# --- removal grep gate: the install-time cache layer is gone ------------------
if grep -rqn 'TARGET_CACHE_DIR' lib/ scripts/ tools/ installer.sh; then
  echo "  FAIL: TARGET_CACHE_DIR still referenced in active code" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: TARGET_CACHE_DIR removed from active code"
fi
if grep -qn -- '--cache-dir' lib/02-args.sh; then
  echo "  FAIL: --cache-dir flag still in lib/02-args.sh" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: --cache-dir flag removed from lib/02-args.sh"
fi
if grep -qn -- '--cache-dir' README.md; then
  echo "  FAIL: --cache-dir still documented in README.md" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: --cache-dir removed from README.md"
fi
if grep -qn 'is RAM-backed; use --cache-dir' scripts/00-preflight.sh; then
  echo "  FAIL: RAM-backed CACHE_DIR warning still in preflight" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: RAM-backed CACHE_DIR warning removed from preflight"
fi

finish_test
