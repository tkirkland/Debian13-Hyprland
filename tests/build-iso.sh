#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"

# Sourcing the orchestrator must be inert: main is guarded by the
# BASH_SOURCE==0 check, so no debootstrap/chroot/xorriso runs here.
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
assert_build_sandbox "${ISO_WORKSPACE}" "${TARGET}" \
  && echo "  ok: resolved sandbox passes assert_build_sandbox" \
  || { echo "  FAIL: resolved sandbox rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }

echo "test: no-args dry-run needs no root, mutates nothing, exits 0"
if out="$(bash "${HERE}/../tools/build-iso.sh" 2>&1)"; then rc=0; else rc=$?; fi
assert_eq "0" "${rc}" "dry-run exits 0 without --confirm (no root required)"
assert_contains "${out}" "DRY-RUN"          "dry-run announces itself"
assert_contains "${out}" "${ISO_WORKSPACE}" "dry-run prints the plan"
# No workspace should be created by a dry-run.
if [[ -e "${ISO_WORKSPACE}" ]]; then
  echo "  FAIL: dry-run created ${ISO_WORKSPACE}" >&2
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

finish_test
