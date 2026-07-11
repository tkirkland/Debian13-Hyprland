#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"

# Sourcing the orchestrator must be inert: main is guarded by the
# BASH_SOURCE==0 check, so no debootstrap/chroot/xorriso runs here.
# shellcheck source=tools/build-iso.sh
source "${HERE}/../tools/build-iso.sh"
set +e   # the orchestrator enables `set -e`; tests do their own rc capture

echo "test: build-iso plan_summary names the load-bearing paths"
summary="$(plan_summary)"
assert_contains "${summary}" "${ISO_WORKSPACE}" "summary names the workspace"
assert_contains "${summary}" "${TARGET}"        "summary names the target"
assert_contains "${summary}" "${OUT_ISO}"       "summary names the out iso"
assert_contains "${summary}" "${STOCK_ISO}"     "summary names the stock iso"
assert_contains "${summary}" "buildroot"        "target is the buildroot"

# TARGET is forced strictly under the workspace (host-safety invariant).
assert_eq "${ISO_WORKSPACE}/buildroot" "${TARGET}" "TARGET confined under workspace"
# The sandbox guard accepts this resolved config.
{ assert_build_sandbox "${ISO_WORKSPACE}" "${TARGET}" \
  && echo "  ok: resolved sandbox passes assert_build_sandbox"; } \
  || { echo "  FAIL: resolved sandbox rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }

echo "test: no-args dry-run needs no root, mutates nothing, exits 0"
# Point the dry-run at a unique, nonexistent workspace so this "created nothing"
# check is immune to leftovers a real build may have left under the default
# /var/tmp/hypr-iso-build path (which previously false-failed this assertion).
dryws="$(mktemp -u)"
if out="$(ISO_WORKSPACE="${dryws}" bash "${HERE}/../tools/build-iso.sh" 2>&1)"; then rc=0; else rc=$?; fi
assert_eq "0" "${rc}" "dry-run exits 0 without --confirm (no root required)"
assert_contains "${out}" "DRY-RUN"   "dry-run announces itself"
assert_contains "${out}" "${dryws}"  "dry-run prints the plan (its workspace path)"
# No workspace should be created by a dry-run.
if [[ -e "${dryws}" ]]; then
  echo "  FAIL: dry-run created ${dryws}" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
else
  echo "  ok: dry-run created no workspace"
fi

echo "test: an unknown argument is rejected (does not silently build)"
assert_fails "unknown arg rejected" bash "${HERE}/../tools/build-iso.sh" --frobnicate

echo "test: ensure_wallpapers_checked_out bundles the submodule for the offline ISO"
wroot="$(mktemp -d)"
printf '[submodule "assets/wallpapers"]\n' >"${wroot}/.gitmodules"
mkdir -p "${wroot}/assets/wallpapers"
gitlog="${wroot}/git.log"; : >"${gitlog}"
# shellcheck disable=SC2317  # called indirectly by ensure_wallpapers_checked_out
git() { printf '%s\n' "$*" >>"${gitlog}"; }
ensure_wallpapers_checked_out "${wroot}"          # empty submodule -> must check out
assert_contains "$(<"${gitlog}")" "submodule update --init --depth 1 -- assets/wallpapers" \
  "empty wallpaper submodule is checked out at build time (offline ISO needs it bundled)"
echo img >"${wroot}/assets/wallpapers/a.jpg"; : >"${gitlog}"
ensure_wallpapers_checked_out "${wroot}"          # already populated -> no network
if [[ ! -s "${gitlog}" ]]; then
  echo "  ok: a populated submodule triggers no checkout (idempotent, no network)"
else
  echo "  FAIL: re-checked-out an already populated wallpaper submodule" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi
unset -f git
rm -rf "${wroot}"

echo "test: probe_stock_kernel_version reads the live kernel from the stock ISO"
# shellcheck disable=SC2317  # stubs invoked indirectly by probe_stock_kernel_version
(
  work="$(mktemp -d)"
  xorriso() { : >"${@: -1}"; }   # emulate -extract: last arg is the out path
  file() {
    printf 'Linux kernel x86 boot executable bzImage, version 6.12.38+deb13-amd64 (debian-kernel@lists.debian.org) #1 SMP\n'
  }
  ver="$(probe_stock_kernel_version /stock.iso "${work}")" || exit 1
  rm -rf "${work}"
  [[ "${ver}" == "6.12.38+deb13-amd64" ]] || {
    echo "  FAIL: parsed '${ver}' (want 6.12.38+deb13-amd64)" >&2; exit 1; }
  echo "  ok: version parsed from file(1) output"
  # Unparseable file output must fail, never echo an empty/garbage pin.
  file() { printf 'data\n'; }
  if probe_stock_kernel_version /stock.iso "${work}" >/dev/null 2>&1; then
    echo "  FAIL: garbage file(1) output produced a pin" >&2; exit 1
  fi
  echo "  ok: undeterminable version is a probe failure"
  # A failed extraction must fail too.
  xorriso() { return 1; }
  if probe_stock_kernel_version /stock.iso "${work}" >/dev/null 2>&1; then
    echo "  FAIL: failed xorriso extraction produced a pin" >&2; exit 1
  fi
  echo "  ok: failed vmlinuz extraction is a probe failure"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: step_pin_kernel enforces live kernel == pool kernel and stores the pin"
# shellcheck disable=SC2317,SC2030,SC2031  # stubs invoked indirectly by step_pin_kernel
(
  ISO_WORKSPACE="$(mktemp -d)"; CACHE_DIR="${ISO_WORKSPACE}/cache"
  POOL="${CACHE_DIR}/repo/pool"; STOCK_ISO=/stock.iso
  mkdir -p "${POOL}"
  xorriso() { : >"${@: -1}"; }
  file() { printf 'bzImage, version 6.12.38+deb13-amd64 (x) #1 SMP\n'; }
  info() { :; }
  rc=0
  # Pool carries a DIFFERENT kernel image -> fatal (stale stock ISO).
  : >"${POOL}/linux-image-6.12.99+deb13-amd64_6.12.99-1_amd64.deb"
  (step_pin_kernel) >/dev/null 2>&1 && rc=1
  if ((rc == 0)); then
    echo "  ok: pool/pin kernel mismatch is fatal"
  else
    echo "  FAIL: mismatched pool kernel accepted" >&2
  fi
  # Matching image present -> pin exported to the store, one line.
  : >"${POOL}/linux-image-6.12.38+deb13-amd64_6.12.38-1_amd64.deb"
  step_pin_kernel >/dev/null 2>&1 || { echo "  FAIL: step_pin_kernel failed on a matching pool" >&2; exit 1; }
  got="$(cat "${CACHE_DIR}/repo/KERNEL_PINNED")"
  rm -rf "${ISO_WORKSPACE}"
  [[ "${got}" == "6.12.38+deb13-amd64" ]] || {
    echo "  FAIL: KERNEL_PINNED store file holds '${got}'" >&2; exit 1; }
  echo "  ok: pin written to the store as KERNEL_PINNED"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: step_build_stack hoists install_build_deps (runs once for N components)"
# Run in a subshell so the collaborator stubs/globals don't leak into later tests.
# SC2317: the stubs are invoked indirectly by step_build_stack; SC2034: the maps
# are consumed by the function under test, not this scope.
# shellcheck disable=SC2317,SC2034
(
  HYPR_BUILD_ORDER=(aaa bbb ccc)
  declare -A HYPR_REPO_URL=([aaa]=u [bbb]=u [ccc]=u)
  declare -A HYPR_TAG_PATTERN=() HYPR_DEB_DEPENDS=() HYPR_RESOLVED_TAG=()
  TARGET="$(mktemp -d)"; POOL="$(mktemp -d)"; ARCH=amd64; BUILD_STAGE_REL=/bs
  resolve_latest_release_tag() { echo v1.0.0; }
  tag_to_debver() { echo 1.0.0-1; }
  deb_needs_rebuild() { return 0; }          # always rebuild -> loop body runs each iter
  stage_source() { :; }
  build_one() { :; }
  package_to_deb() { :; }
  in_target() { :; }
  cp() { :; }                                # shadow the buildroot /usr copy
  bdcount=0
  install_build_deps() { bdcount=$((bdcount + 1)); }
  step_build_stack
  rm -rf "${TARGET}" "${POOL}"
  if [[ "${bdcount}" == "1" ]]; then
    echo "  ok: install_build_deps invoked once for 3 rebuilt components"
    exit 0
  fi
  echo "  FAIL: install_build_deps ran ${bdcount}x (expected 1, must be hoisted)" >&2
  exit 1
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: step_runtime_closure skips deps already in the pool"
# shellcheck disable=SC2317,SC2030,SC2031  # stubs invoked indirectly by step_runtime_closure
(
  POOL="$(mktemp -d)"; TARGET="$(mktemp -d)"
  : >"${POOL}/main_1.0-1_amd64.deb"          # the deb whose Depends we read
  : >"${POOL}/libpooled1_1.0-1_amd64.deb"    # an already-pooled dep -> must be skipped
  _self_provided_names() { printf ' '; }
  # Every pooled deb reports the same Depends: one already pooled, one missing.
  dpkg-deb() { [[ "$1" == "-f" ]] && echo "libpooled1 (>= 1.0), libmissing1"; }
  info() { :; }
  RC_CAP="$(mktemp)"
  in_target() { printf '%s\n' "$*" >>"${RC_CAP}"; }
  step_runtime_closure
  rccap="$(cat "${RC_CAP}")"
  rm -rf "${POOL}" "${TARGET}"; rm -f "${RC_CAP}"
  rc=0
  [[ "${rccap}" == *libmissing1* ]] || { echo "  FAIL: un-pooled dep libmissing1 not queued for download" >&2; rc=1; }
  if [[ "${rccap}" == *libpooled1* ]]; then
    echo "  FAIL: already-pooled dep libpooled1 was re-downloaded" >&2; rc=1
  fi
  ((rc == 0)) && echo "  ok: already-pooled dep skipped, only the missing dep is fetched"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: step_zfs resume guard rebuilds a stale pool missing the pinned kmod deb (issue #110)"
# shellcheck disable=SC2317,SC2030,SC2031  # stubs invoked indirectly by step_zfs
(
  POOL="$(mktemp -d)"
  KERNEL_PINNED="6.12.38+deb13-amd64"
  calls="$(mktemp)"
  # Predefining install_zfs_from_source skips step_zfs's lazy source of
  # 40-system.sh; the stub just records that the rebuild path was taken.
  install_zfs_from_source() { echo run >>"${calls}"; }
  assert_chrooted_in_target() { :; }
  in_target() { :; }
  info() { :; }
  : >"${POOL}/openzfs-zfs-dkms_2.3.0-1_all.deb"
  step_zfs   # dkms deb pooled but NO kmod deb for the pin -> must rebuild
  : >"${POOL}/openzfs-zfs-modules-${KERNEL_PINNED}_2.3.0-1_amd64.deb"
  step_zfs   # complete pool -> resume skip, no second build
  n="$(wc -l <"${calls}")"
  rm -rf "${POOL}"; rm -f "${calls}"
  if [[ "${n}" == "1" ]]; then
    echo "  ok: stale pool (no pinned kmod deb) rebuilds once; complete pool skips"
    exit 0
  fi
  echo "  FAIL: install_zfs_from_source ran ${n}x (want 1: rebuild stale, skip complete)" >&2
  exit 1
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: restore_build_ownership hands the workspace back to the sudo user (not left root-owned)"
# shellcheck disable=SC2317  # chown stub invoked indirectly by restore_build_ownership
(
  ISO_WORKSPACE="$(mktemp -d)"; OUT_ISO="${ISO_WORKSPACE}/out.iso"; : >"${OUT_ISO}"
  chlog="${ISO_WORKSPACE}/chown.log"; : >"${chlog}"
  chown() { printf '%s\n' "$*" >>"${chlog}"; }
  SUDO_UID=1000 SUDO_GID=1000 restore_build_ownership
  got="$(<"${chlog}")"
  : >"${chlog}"
  unset SUDO_UID SUDO_GID
  restore_build_ownership                       # no sudo -> must be a no-op
  noop="$(<"${chlog}")"
  rm -rf "${ISO_WORKSPACE}"
  rc=0
  [[ "${got}" == *"-R 1000:1000"* && "${got}" == *out.iso* ]] \
    || { echo "  FAIL: did not chown workspace+iso to the sudo user (got: ${got})" >&2; rc=1; }
  [[ -z "${noop}" ]] || { echo "  FAIL: chowned even without SUDO_UID set" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: chowns to SUDO_UID:SUDO_GID under sudo, no-op otherwise"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

finish_test
