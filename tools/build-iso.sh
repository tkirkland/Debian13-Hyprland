#!/usr/bin/env bash
# shellcheck shell=bash
# build-iso.sh — offline-ISO build-host entry point (Phase 3a scaffolding).
#
# SAFE BY DEFAULT. With no flags this prints the resolved build plan and EXITS
# 0 WITHOUT MUTATING ANYTHING (dry-run). The heavy build (debootstrap, source
# compiles, OpenZFS build, xorriso repack) runs ONLY when --confirm is given,
# and only after the host-safety guards in tools/lib-build-guard.sh have proven
# the build is confined to a throwaway WORKSPACE reached through a real chroot.
#
# HOST SAFETY (paramount: the build host is the operator's working machine):
#   * require_root + assert_build_sandbox + assert_chrooted_in_target gate every
#     mutating step; none run in dry-run.
#   * TARGET is forced to ${ISO_WORKSPACE}/buildroot and exported so the
#     chroot-backed in_target (lib/04-chroot-mounts.sh, sourced BEFORE
#     scripts/60-hyprland.sh so its no-chroot fallback never wins) runs compiles
#     and apt INSIDE the buildroot, never on the host.
#
# This file is Phase 3a: scaffolding + unit-tested seams. The real build is 3b.

set -euo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TOOLS_DIR}/.." && pwd)"
# lib/00-config.sh reads addons/*.list relative to the cwd, so anchor there.
cd "${REPO_ROOT}"

# This builder runs on the operator's own machine, whose running kernel
# (uname -r) is NOT in the Debian archive. Pin the kernel-headers metapackage
# (which IS, and matches linux-image-amd64 in TARGET_BASE_PACKAGES) BEFORE
# sourcing config — LIVE_TOOL_PACKAGES captures LIVE_KERNEL_HEADERS at source
# time, so this must be exported first.
export LIVE_KERNEL_HEADERS="${LIVE_KERNEL_HEADERS:-linux-headers-amd64}"

# Source order is CRITICAL: lib/04-chroot-mounts.sh must precede
# scripts/60-hyprland.sh so the chroot-backed in_target is in effect (60's
# fallback only defines in_target when one is not already declared).
for _src in \
  lib/00-config.sh \
  lib/01-log.sh \
  lib/04-chroot-mounts.sh \
  scripts/10-cache.sh \
  scripts/30-bootstrap.sh \
  scripts/60-hyprland.sh \
  scripts/lib-deb-package.sh \
  tools/lib-build-guard.sh; do
  if [[ ! -f "${REPO_ROOT}/${_src}" ]]; then
    printf 'ERROR: missing source file: %s\n' "${REPO_ROOT}/${_src}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090  # validated repo-relative path
  source "${REPO_ROOT}/${_src}"
done
unset _src

# --- Resolved build configuration (env-overridable) --------------------------
STOCK_ISO="${STOCK_ISO:-/home/me/isos/debian-live-13.5.0-amd64-standard.iso}"
OUT_ISO="${OUT_ISO:-/home/me/isos/Debian13-Hyprland-offline.iso}"
ISO_WORKSPACE="${ISO_WORKSPACE:-/var/tmp/hypr-iso-build}"
# The build chroot. Forced under the workspace and EXPORTED so the
# chroot-backed in_target and any ldd/${TARGET} path resolution use it.
TARGET="${ISO_WORKSPACE}/buildroot"
export TARGET
# Cache/pool live inside the workspace (override lib/00-config.sh's defaults).
CACHE_DIR="${ISO_WORKSPACE}/cache"
POOL="${CACHE_DIR}/repo/pool"
# Chroot-internal staging root for DESTDIR installs (host-visible at
# ${TARGET}${BUILD_STAGE_REL}; chroot-visible at ${BUILD_STAGE_REL}).
BUILD_STAGE_REL="${BUILD_STAGE_REL:-/var/tmp/hypr-stage}"

# --- Testable seam: print the resolved plan, mutate nothing ------------------
plan_summary() {
  cat <<EOF
Debian13-Hyprland offline-ISO build plan
  workspace : ${ISO_WORKSPACE}
  target    : ${TARGET}
  cache dir : ${CACHE_DIR}
  pool      : ${POOL}
  stage rel : ${BUILD_STAGE_REL}
  stock iso : ${STOCK_ISO}
  out iso   : ${OUT_ISO}
  suite     : ${SUITE}
  arch      : ${ARCH}
  mirror    : ${MIRROR}
  build order: ${HYPR_BUILD_ORDER[*]}
EOF
}

# =============================================================================
# Heavy flow — each step a function. NONE run without --confirm AND the guards.
# =============================================================================

# 1) Bootstrap the build chroot, bind the kernel filesystems, and PROVE the
#    in-effect in_target is chroot-backed (not the host fallback).
step_bootstrap_chroot() {
  info "[build] debootstrap ${SUITE} -> ${TARGET}"
  mkdir -p "${TARGET}"
  debootstrap "${SUITE}" "${TARGET}" "${MIRROR}" \
    || fatal "debootstrap failed for ${SUITE} -> ${TARGET}"
  # CRITICAL host-safety: mount_chroot_binds binds the host's live /run (systemd
  # + dbus sockets) into the buildroot. Without policy-rc.d exit 101, a package
  # postinst's deb-systemd-invoke/invoke-rc.d would start/restart/reload services
  # on the HOST's PID 1 (this box is itself a ZFS workstation). Install the guard
  # BEFORE the binds and before any in_target apt run, exactly as phase_bootstrap.
  install_policy_rc_d
  # Defense in depth beyond policy-rc.d: give the buildroot a private tmpfs /run
  # so NO maintainer script (even one calling systemctl/dbus-send directly) can
  # reach the host's systemd/D-Bus sockets.
  export HYPR_PRIVATE_RUN=1
  mount_chroot_binds
  assert_chrooted_in_target \
    || fatal "in_target is not chroot-backed; refusing to build on the host."
}

# 2) Populate the offline .deb closure and index the file:// repo.
step_cache() {
  info "[build] populating offline .deb cache in ${CACHE_DIR}"
  cache_populate_debs
  cache_index_repo
}

# 3) Build the source stack to pooled .debs, freshness-gated and chroot-correct.
#    HYPR_DESTDIR is a CHROOT-INTERNAL path; build_one installs to
#    ${TARGET}${stagerel} via the chroot, and package_to_deb reads that
#    host-visible tree. Low-level primitives are used on purpose (NOT
#    build_component_to_deb) so DESTDIR lands inside the buildroot.
step_build_stack() {
  local name tag debver stagerel
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    tag="$(resolve_latest_release_tag \
      "${HYPR_REPO_URL[${name}]}" "${HYPR_TAG_PATTERN[${name}]:-}")"
    debver="$(tag_to_debver "${tag}")"
    if deb_needs_rebuild "${POOL}" "${name}" "${debver}"; then
      stagerel="${BUILD_STAGE_REL}/${name}"
      rm -rf "${TARGET}${stagerel}"
      mkdir -p "${TARGET}${stagerel}"
      # shellcheck disable=SC2034  # consumed by stage_source/build_one via 60-hyprland.sh
      HYPR_RESOLVED_TAG["${name}"]="${tag}"
      stage_source "${name}"
      install_build_deps
      HYPR_DESTDIR="${stagerel}" build_one "${name}"
      package_to_deb "${TARGET}${stagerel}" "${name}" "${debver}" \
        "${ARCH}" "${HYPR_DEB_DEPENDS[${name}]:-}" "${POOL}"
    else
      info "reuse cached ${name}"
    fi
  done
}

# 4) Build upstream OpenZFS as native debs into the pool. install_zfs_from_source
#    lives in scripts/40-system.sh (not in the critical top-level source order);
#    source it lazily so the chroot-backed in_target order is undisturbed.
step_zfs() {
  if ! declare -f install_zfs_from_source >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/scripts/40-system.sh"
  fi
  # Re-assert after the lazy source: a future module that redefined in_target
  # to the no-chroot host fallback must not slip ZFS compiles onto the host.
  assert_chrooted_in_target \
    || fatal "in_target is not chroot-backed after sourcing 40-system.sh; refusing to build on host."
  info "[build] building OpenZFS into the pool ${POOL}"
  ZFS_DEB_POOL="${POOL}" install_zfs_from_source
}

# 5) Re-index after the source stack + ZFS landed new .debs.
step_reindex() {
  cache_index_repo
}

# 6) Dependency-completeness simulation: in a throwaway chroot, point apt at the
#    file:// pool ONLY and `apt-get install --simulate` the full target+stack
#    set. Fatal if anything would resolve from outside the pool.
step_depsim() {
  info "[build] simulating full install against the offline pool only"
  local simroot
  simroot="$(mktemp -d "${ISO_WORKSPACE}/depsim.XXXXXX")"
  debootstrap "${SUITE}" "${simroot}" "${MIRROR}" \
    || { rm -rf "${simroot}"; fatal "depsim: debootstrap failed"; }
  printf 'deb [trusted=yes] file://%s/repo %s main\n' "${CACHE_DIR}" "${SUITE}" \
    >"${simroot}/etc/apt/sources.list"
  # Track the bind mount so the EXIT/ERR trap (teardown_chroot_binds) unmounts
  # it even on a failure path — it must never leak under /var/tmp.
  mkdir -p "${simroot}${CACHE_DIR}"
  if mount --bind "${CACHE_DIR}" "${simroot}${CACHE_DIR}"; then
    track_mount "${simroot}${CACHE_DIR}"
  fi
  local out rc
  out="$(chroot "${simroot}" /usr/bin/env bash -c "
    set -e
    apt-get update -o APT::Get::List-Cleanup=0 >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install --simulate -y \
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_ORDER[*]}
  ")" && rc=0 || rc=$?
  # Unmount + remove the throwaway simroot now. The bind is also trap-tracked;
  # teardown_chroot_binds re-checks mountpoint, so this is not a double-unmount.
  if mountpoint -q "${simroot}${CACHE_DIR}" 2>/dev/null; then
    umount "${simroot}${CACHE_DIR}" || umount -l "${simroot}${CACHE_DIR}" || true
  fi
  # Never rm -rf while the CACHE_DIR bind is still live: a stuck mount would let
  # rm traverse the bind and delete the real pool. Refuse rather than risk it.
  if mountpoint -q "${simroot}${CACHE_DIR}" 2>/dev/null; then
    fatal "depsim: ${simroot}${CACHE_DIR} still mounted; refusing rm -rf (unmount manually)"
  fi
  rm -rf "${simroot}"
  ((rc == 0)) || fatal "depsim: apt-get --simulate failed (unsatisfied offline closure)"
  info "${out}"
  # Anything fetched would be logged as an http(s):// URI by apt; the file://
  # repo never is. A remote URI here means the pool is incomplete.
  if grep -Eq 'https?://' <<<"${out}"; then
    grep -E 'https?://' <<<"${out}" | warn_lines
    fatal "depsim: packages would resolve from outside the offline pool."
  fi
}

# 7) Assemble the final ISO (xorriso, runs in tools/iso-assemble.sh).
step_assemble() {
  info "[build] assembling ${OUT_ISO}"
  "${TOOLS_DIR}/iso-assemble.sh" "${STOCK_ISO}" "${CACHE_DIR}/repo" "${OUT_ISO}" \
    || fatal "iso-assemble failed"
}

run_heavy_build() {
  step_bootstrap_chroot     # 1
  step_cache                # 2
  step_build_stack          # 3
  step_zfs                  # 4
  step_reindex              # 5
  step_depsim               # 6
  step_assemble             # 7
  kill_target_processes     # 8: reap any stray buildroot daemon holding a mount
  teardown_chroot_binds     # 9 (also via trap)
  info "[build] done: ${OUT_ISO}"
}

main() {
  local confirm=0
  while (($#)); do
    case "$1" in
      --confirm) confirm=1 ;;
      -h | --help)
        plan_summary
        printf '\nRun with --confirm to execute the build (root required).\n'
        return 0
        ;;
      *) fatal "unknown argument: $1 (use --confirm to build, or no args for a dry-run plan)" ;;
    esac
    shift
  done

  # SAFE BY DEFAULT: without --confirm, print the plan and exit 0. No root, no
  # sandbox check, no mutation — this path is what the unit test exercises.
  if ((confirm == 0)); then
    info "DRY-RUN (no --confirm): printing plan, mutating nothing."
    plan_summary
    return 0
  fi

  # Heavy path only past here. Guards BEFORE any mutating work.
  require_root || fatal "build-iso must run as root (debootstrap/chroot)."
  assert_build_sandbox "${ISO_WORKSPACE}" "${TARGET}" || fatal "unsafe sandbox config."
  # BUILD_STAGE_REL is operator-overridable and gets concatenated RAW onto
  # TARGET for host-side rm -rf/mkdir in step_build_stack; prove it cannot
  # escape the buildroot before any mutating step runs.
  assert_stage_under_target "${TARGET}" "${BUILD_STAGE_REL}" \
    || fatal "unsafe BUILD_STAGE_REL (escapes buildroot): ${BUILD_STAGE_REL}"

  # Mounts must never leak, even on failure.
  trap 'teardown_chroot_binds' EXIT
  trap 'teardown_chroot_binds' ERR

  mkdir -p "${ISO_WORKSPACE}" "${POOL}"
  run_heavy_build
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
