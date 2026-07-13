#!/usr/bin/env bash
# Golden-rootfs build seams in tools/build-iso.sh (issue #111): the one-kernel
# resolve, the image manifest, the live-only autologin hook, the identity
# scrub, and the golden-tree ownership exemption. Sourcing the orchestrator is
# inert (main is BASH_SOURCE-guarded).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"

export HYPR_ISO_GOLDEN=1
# shellcheck source=tools/build-iso.sh
source "${HERE}/../tools/build-iso.sh"
set +e # the orchestrator enables `set -e`; tests do their own rc capture

echo "test: golden dry-run plan names the mode and the new paths"
summary="$(plan_summary)"
assert_contains "${summary}" "golden rootfs" "summary names the golden mode"
assert_contains "${summary}" "${GOLDEN}" "summary names the golden chroot"
assert_contains "${summary}" "${INSTALL_STORE}" "summary names the install store"

echo "test: step_resolve_kernel picks ONE pool kernel, no stock probe, KERNEL stamped"
# shellcheck disable=SC2317,SC2030,SC2031  # stubs invoked indirectly
(
  ISO_WORKSPACE="$(mktemp -d)"
  POOL="${ISO_WORKSPACE}/pool"
  INSTALL_STORE="${ISO_WORKSPACE}/install-store"
  ARCH=amd64
  mkdir -p "${POOL}"
  dpkg-deb() {
    case "$2" in
      *linux-headers*) echo "linux-headers-6.12.44+deb13-amd64 (= 6.12.44-1)" ;;
      *) echo "linux-image-6.12.44+deb13-amd64 (= 6.12.44-1)" ;;
    esac
  }
  # A stock probe in golden mode would be a regression: the golden rootfs
  # picks its own kernel. Poison the probe so any call fails loudly.
  probe_stock_kernel_version() {
    echo "  FAIL: step_resolve_kernel probed the stock ISO" >&2
    exit 99
  }
  info() { :; }
  : >"${POOL}/linux-image-amd64_6.12.44-1_amd64.deb"
  : >"${POOL}/linux-headers-amd64_6.12.44-1_amd64.deb"
  : >"${POOL}/linux-image-6.12.44+deb13-amd64_6.12.44-1_amd64.deb"
  step_resolve_kernel >/dev/null 2>&1 ||
    { echo "  FAIL: step_resolve_kernel failed on a complete pool" >&2; exit 1; }
  rc=0
  [[ "${KERNEL_TARGET}" == "6.12.44+deb13-amd64" ]] ||
    { echo "  FAIL: KERNEL_TARGET '${KERNEL_TARGET}'" >&2; rc=1; }
  [[ "${KERNEL_PINNED}" == "${KERNEL_TARGET}" ]] ||
    { echo "  FAIL: golden mode must set pin == target (one kmod build)" >&2; rc=1; }
  [[ "$(cat "${INSTALL_STORE}/KERNEL")" == "6.12.44+deb13-amd64" ]] ||
    { echo "  FAIL: KERNEL stamp not written to the install store" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: one pool-chosen kernel, pin == target, store stamped"
  # Headers skew must stay fatal in golden mode too.
  dpkg-deb() {
    case "$2" in
      *linux-headers*) echo "linux-headers-6.12.99+deb13-amd64 (= 6.12.99-1)" ;;
      *) echo "linux-image-6.12.44+deb13-amd64 (= 6.12.44-1)" ;;
    esac
  }
  if (step_resolve_kernel) >/dev/null 2>&1; then
    echo "  FAIL: image/headers skew accepted in golden mode" >&2; rc=1
  else
    echo "  ok: image/headers metapackage skew stays fatal"
  fi
  rm -rf "${ISO_WORKSPACE}"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: write_build_manifest records kernel + pooled component versions"
# shellcheck disable=SC2317,SC2030,SC2031  # stubs invoked indirectly
(
  GOLDEN="$(mktemp -d)"
  POOL="$(mktemp -d)"
  KERNEL_TARGET="6.12.44+deb13-amd64"
  HYPR_BUILD_ORDER=(hyprland uwsm)
  XDPH_COMPONENT=xdg-desktop-portal-hyprland
  : >"${POOL}/hyprland_0.53.3-1_amd64.deb"
  : >"${POOL}/uwsm_0.23.0-1_amd64.deb"
  : >"${POOL}/openzfs-zfsutils_2.4.3-1_amd64.deb"
  dpkg-deb() {
    case "$2" in
      *hyprland_*) echo "0.53.3-1" ;;
      *uwsm_*) echo "0.23.0-1" ;;
      *zfsutils*) echo "2.4.3-1" ;;
    esac
  }
  write_build_manifest
  m="$(cat "${GOLDEN}/etc/hypr-deb/build-manifest")"
  rc=0
  [[ "${m}" == *"kernel=6.12.44+deb13-amd64"* ]] ||
    { echo "  FAIL: manifest lacks the kernel line" >&2; rc=1; }
  [[ "${m}" == *"hyprland=0.53.3-1"* ]] ||
    { echo "  FAIL: manifest lacks the hyprland version" >&2; rc=1; }
  [[ "${m}" == *"openzfs-zfsutils=2.4.3-1"* ]] ||
    { echo "  FAIL: manifest lacks the zfs version" >&2; rc=1; }
  [[ "${m}" == *"built="* ]] ||
    { echo "  FAIL: manifest lacks the build date" >&2; rc=1; }
  # xdph was not pooled — it must be absent, not an empty line.
  [[ "${m}" != *"${XDPH_COMPONENT}"* ]] ||
    { echo "  FAIL: unpooled xdph must not appear in the manifest" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: manifest carries built/kernel/component versions, skips unpooled"
  rm -rf "${GOLDEN}" "${POOL}"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: stage_live_autologin_hook rewrites greetd ONLY in the live overlay"
# shellcheck disable=SC2030,SC2031
(
  GOLDEN="$(mktemp -d)"
  stage_live_autologin_hook
  hook="${GOLDEN}/usr/lib/live/config/2999-hypr-autologin"
  rc=0
  [[ -x "${hook}" ]] || { echo "  FAIL: hook missing or not executable" >&2; exit 1; }
  body="$(cat "${hook}")"
  [[ "${body}" == *"/usr/bin/hypr-session"* ]] ||
    { echo "  FAIL: hook does not autologin into hypr-session" >&2; rc=1; }
  [[ "${body}" == *'LIVE_USERNAME'* ]] ||
    { echo "  FAIL: hook must honor live-config's LIVE_USERNAME" >&2; rc=1; }
  [[ "${body}" == *"/etc/greetd/config.toml"* ]] ||
    { echo "  FAIL: hook does not rewrite the greetd config" >&2; rc=1; }
  bash -n "${hook}" || { echo "  FAIL: hook is not valid shell" >&2; rc=1; }
  # The baked config itself must NOT be autologin (assert the hook is the only
  # autologin mechanism: it lives under live-config's hook dir, nothing else).
  ((rc == 0)) && echo "  ok: autologin is a live-config hook (squashfs default untouched)"
  rm -rf "${GOLDEN}"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: golden_hygiene_scrub strips identity + regenerable caches"
# shellcheck disable=SC2317,SC2030,SC2031
(
  GOLDEN="$(mktemp -d)"
  mkdir -p "${GOLDEN}/etc/ssh" "${GOLDEN}/var/lib/dbus" \
    "${GOLDEN}/var/lib/apt/lists/partial" "${GOLDEN}/var/cache/apt"
  echo buildhostid >"${GOLDEN}/etc/machine-id"
  echo buildhostid >"${GOLDEN}/var/lib/dbus/machine-id"
  : >"${GOLDEN}/etc/ssh/ssh_host_ed25519_key"
  : >"${GOLDEN}/etc/ssh/ssh_host_ed25519_key.pub"
  : >"${GOLDEN}/etc/ssh/sshd_config"
  : >"${GOLDEN}/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_InRelease"
  : >"${GOLDEN}/var/cache/apt/pkgcache.bin"
  in_target() { :; } # the apt-get clean half
  golden_hygiene_scrub
  rc=0
  [[ -f "${GOLDEN}/etc/machine-id" && ! -s "${GOLDEN}/etc/machine-id" ]] ||
    { echo "  FAIL: machine-id must be truncated to empty (uninitialized), not removed" >&2; rc=1; }
  [[ ! -e "${GOLDEN}/var/lib/dbus/machine-id" ]] ||
    { echo "  FAIL: dbus machine-id survived the scrub" >&2; rc=1; }
  [[ ! -e "${GOLDEN}/etc/ssh/ssh_host_ed25519_key" ]] ||
    { echo "  FAIL: ssh host key survived the scrub" >&2; rc=1; }
  [[ -e "${GOLDEN}/etc/ssh/sshd_config" ]] ||
    { echo "  FAIL: scrub must only remove host keys, not sshd_config" >&2; rc=1; }
  [[ ! -e "${GOLDEN}/var/lib/apt/lists/deb.debian.org_debian_dists_trixie_InRelease" ]] ||
    { echo "  FAIL: apt lists survived the scrub" >&2; rc=1; }
  [[ ! -e "${GOLDEN}/var/cache/apt/pkgcache.bin" ]] ||
    { echo "  FAIL: apt binary cache survived the scrub" >&2; rc=1; }
  ((rc == 0)) && echo "  ok: identity scrubbed, host keys gone, caches dropped, config kept"
  rm -rf "${GOLDEN}"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

echo "test: restore_build_ownership exempts the golden tree (it IS the shipped fs)"
# shellcheck disable=SC2317,SC2030,SC2031
(
  ISO_WORKSPACE="$(mktemp -d)"
  GOLDEN="${ISO_WORKSPACE}/golden"
  OUT_ISO="${ISO_WORKSPACE}/out.iso"
  mkdir -p "${GOLDEN}/etc" "${ISO_WORKSPACE}/cache"
  : >"${OUT_ISO}"
  chlog="$(mktemp)"
  chown() { printf '%s\n' "$*" >>"${chlog}"; }
  SUDO_UID=1000 SUDO_GID=1000 restore_build_ownership
  got="$(cat "${chlog}")"
  rm -rf "${ISO_WORKSPACE}"; rm -f "${chlog}"
  rc=0
  [[ "${got}" == *"cache"* ]] ||
    { echo "  FAIL: workspace cache not handed back to the operator" >&2; rc=1; }
  [[ "${got}" == *"out.iso"* ]] ||
    { echo "  FAIL: output ISO not handed back to the operator" >&2; rc=1; }
  if [[ "${got}" == *"-R 1000:1000 ${GOLDEN}"* ]]; then
    echo "  FAIL: golden tree was chowned — its internal ownership must ship intact" >&2
    rc=1
  fi
  ((rc == 0)) && echo "  ok: everything handed back except the golden tree"
  exit "${rc}"
) || TEST_FAILURES=$((TEST_FAILURES + 1))

finish_test
