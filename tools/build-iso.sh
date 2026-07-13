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

# readlink -f resolves any symlink (e.g. the convenience link in the ISO output
# dir) to the real script, so TOOLS_DIR/REPO_ROOT point at the repo, not the
# symlink's directory.
TOOLS_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "${TOOLS_DIR}/.." && pwd)"
# lib/00-config.sh reads addons/*.list relative to the cwd, so anchor there.
cd "${REPO_ROOT}"

# Optional, gitignored per-operator overrides sourced here if present (e.g. a
# throwaway-VM autoinstall password). The file is UNTRACKED, so anything it sets
# is structurally incapable of riding a develop->master merge — that is the point:
# values that must never reach the shared branch live here, not in committed source.
if [[ -f "${TOOLS_DIR}/build-iso.local" ]]; then
  # shellcheck source=/dev/null
  source "${TOOLS_DIR}/build-iso.local"
fi

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
# CACHE_REPO_DIR no longer derives from CACHE_DIR (it defaults to the on-ISO
# store ISO_LIVE_REPO now), so the build MUST repoint it at the workspace pool
# explicitly — otherwise cache_repo_exists/cache_validate would check the wrong
# path and the build's populate/index/resume-skip logic would misfire.
CACHE_REPO_DIR="${CACHE_DIR}/repo"
POOL="${CACHE_DIR}/repo/pool"
# Shared debootstrap .deb cache. The buildroot debootstrap (step_bootstrap_chroot)
# fills it on the SINGLE base download; the closure debootstrap (10-cache.sh,
# sourced in-process) reuses it via --cache-dir, so the trixie base is fetched
# once and reused instead of being re-downloaded. EXPORTED so the in-process
# 10-cache.sh sees it; when unset (any other caller) 10-cache.sh references it
# defensively, so that path passes no --cache-dir.
DEBOOTSTRAP_CACHE="${CACHE_DIR}/debs-cache"
export DEBOOTSTRAP_CACHE
# Chroot-internal staging root for DESTDIR installs (host-visible at
# ${TARGET}${BUILD_STAGE_REL}; chroot-visible at ${BUILD_STAGE_REL}).
BUILD_STAGE_REL="${BUILD_STAGE_REL:-/var/tmp/hypr-stage}"
# Golden mode (issue #111, HYPR_ISO_GOLDEN=1): the second, clean chroot that
# becomes the one shipped squashfs (live session == install image), and the
# small install store that rides the ISO9660 medium at /hypr-repo (NVIDIA +
# bootloader debs, ZBM EFI, KERNEL stamp).
GOLDEN="${ISO_WORKSPACE}/golden"
INSTALL_STORE="${ISO_WORKSPACE}/install-store"

# The build host is online by definition (we are populating the offline cache
# FROM the network). The installer sets this in its preflight phase; build-iso
# has no preflight, so declare it here. stage_source/install_build_deps branch
# on it to clone sources and add the sid/backports toolchain over the network.
export NETWORK_AVAILABLE=1

# xdph (xdg-desktop-portal-hyprland) — OPTIONAL source-built screencast backend
# (Option B). Its component name (XDPH_COMPONENT), repo-URL entry in HYPR_REPO_URL,
# and Qt6/PipeWire build-deps (qt6-base-dev, libpipewire-0.3-dev, libspa-0.2-dev)
# are all defined in lib/00-config.sh, sourced above — deliberately OUT of
# HYPR_BUILD_ORDER so an xdph failure can never strand uwsm (the #64 regression).
# This file only adds the guarded step_build_portal (below) that compiles it into
# a pooled .deb, and the step_depsim gate; nothing to redefine here.

# --- Testable seam: print the resolved plan, mutate nothing ------------------
plan_summary() {
  local mode="legacy (stock-squashfs repack + on-ISO pool)"
  if ((HYPR_ISO_GOLDEN)); then
    mode="golden rootfs (issue #111: one self-built squashfs + medium install store)"
  fi
  cat <<EOF
Debian13-Hyprland offline-ISO build plan
  mode      : ${mode}
  workspace : ${ISO_WORKSPACE}
  target    : ${TARGET}
  cache dir : ${CACHE_DIR}
  pool      : ${POOL}
  golden    : ${GOLDEN}
  store     : ${INSTALL_STORE}
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
  # Resume support: a populated buildroot from a prior run is reused so retries
  # skip the ~minutes-long debootstrap. /etc/os-release exists only after a
  # successful bootstrap. (rm -rf the workspace for a clean rebuild.)
  if [[ -e "${TARGET}/etc/os-release" ]]; then
    info "[build] reusing existing buildroot ${TARGET} (skip debootstrap)"
  else
    info "[build] debootstrap ${SUITE} -> ${TARGET}"
    mkdir -p "${TARGET}"
    # --cache-dir seeds the shared deb cache on this SINGLE base download; the
    # closure debootstrap in 10-cache.sh reuses it instead of re-fetching base.
    debootstrap --cache-dir="${DEBOOTSTRAP_CACHE}" "${SUITE}" "${TARGET}" "${MIRROR}" \
      || fatal "debootstrap failed for ${SUITE} -> ${TARGET}"
  fi
  # Harvest the base .debs from the buildroot's apt archives into the pool. This
  # is THE single base download/harvest for the build-iso path (the dedicated
  # --download-only bootstrap pass in 10-cache.sh is dropped). Placed after the
  # resume/else block so it also runs on resume; cp -n is idempotent. At step 1
  # the buildroot archives hold the freshly debootstrapped base set (no in_target
  # apt has run yet this invocation). POOL is created by main() before
  # run_heavy_build; mkdir -p here keeps the harvest self-contained. Empty-glob
  # safe via the compgen guard.
  mkdir -p "${POOL}"
  if compgen -G "${TARGET}/var/cache/apt/archives/*.deb" >/dev/null; then
    cp -n "${TARGET}/var/cache/apt/archives/"*.deb "${POOL}/"
  fi
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
  # Resume support: skip the ~minutes-long closure download only when the cache
  # repo's Packages index exists AND was stamped with the current package sets
  # (cache_pkgset_fresh, from 10-cache.sh). A stale pool — one populated before a
  # package was added to TARGET_BASE_PACKAGES et al., or a pre-stamp cache with no
  # stamp — is repopulated instead of silently reused, which is what caused
  # step_depsim to fail with "Unable to locate package" for the newly-added names.
  if cache_repo_exists && cache_pkgset_fresh; then
    info "[build] reusing existing .deb closure in ${CACHE_DIR} (skip download)"
  else
    info "[build] populating offline .deb cache in ${CACHE_DIR}"
    cache_populate_debs
  fi
  # chezmoi is a GitHub-only .deb (not in the Debian closure above): harvest it
  # into the pool so the target installs it offline by name. Own reuse guard, so
  # it runs even on the cache_repo_exists resume path.
  cache_populate_chezmoi
  # brave-browser: same out-of-archive pattern (Brave's apt repo, own reuse
  # guard); also harvests the archive keyring for the target's sources entry.
  cache_populate_brave
  cache_index_repo
}

# probe_stock_kernel_version STOCK_ISO WORKDIR
# Echo the stock ISO's live kernel version (e.g. 6.12.38+deb13-amd64), read
# from /live/vmlinuz via xorriso osirrox (same mechanism iso-assemble.sh's
# extract_stock_squashfs uses) and file(1)'s "version X" field. Nonzero when
# the version cannot be determined. Pure seam so tests can stub xorriso/file.
probe_stock_kernel_version() {
  local stock="$1" work="$2" ver=""
  rm -f "${work}/vmlinuz-probe"
  xorriso -osirrox on -indev "${stock}" \
    -extract /live/vmlinuz "${work}/vmlinuz-probe" >/dev/null 2>&1 || return 1
  ver="$(file -b "${work}/vmlinuz-probe" 2>/dev/null |
    grep -oE 'version [^ ]+' | awk '{print $2}')"
  rm -f "${work}/vmlinuz-probe"
  [[ -n "${ver}" ]] || return 1
  printf '%s\n' "${ver}"
}

# 2b) Pin the live kernel (issue #110). Every prebuilt ZFS artifact — the
#     openzfs kmod deb (step_zfs), the module baked into the live squashfs
#     (iso-assemble) and the target's kernel from the pool — must be built for
#     ONE kernel: the stock ISO's live kernel. Probe it, assert the pool
#     carries that exact linux-image (live kernel == pool/target kernel is an
#     enforced build-time invariant), and write it into the store as
#     KERNEL_PINNED so it rides at /opt/hypr-deb/repo/KERNEL_PINNED (same
#     graft as step_stage_zbm's zfsbootmenu.EFI) for install_zfs_offline,
#     cache_validate and preflight. Exported: step_zfs and iso-assemble.sh
#     (a separate bash process) both consume it.
step_pin_kernel() {
  KERNEL_PINNED="$(probe_stock_kernel_version "${STOCK_ISO}" "${ISO_WORKSPACE}")" ||
    fatal "cannot determine the stock ISO's live kernel version (${STOCK_ISO})"
  export KERNEL_PINNED
  info "[build] live kernel pinned: ${KERNEL_PINNED}"
  compgen -G "${POOL}/linux-image-${KERNEL_PINNED}_*.deb" >/dev/null ||
    fatal "pool carries no linux-image-${KERNEL_PINNED} — the stock ISO's" \
      "kernel differs from the archive kernel the pool carries; fetch the" \
      "current point-release stock ISO."
  printf '%s\n' "${KERNEL_PINNED}" >"${CACHE_DIR}/repo/KERNEL_PINNED"
  # The TARGET boots whatever the pool's linux-image-amd64 metapackage
  # resolves to — trixie-security routinely carries a NEWER kernel than the
  # stock ISO's live kernel (live images are only respun at point releases),
  # so the pin alone cannot describe the installed system. Read the pooled
  # metapackage's Depends, record the resolved version as KERNEL_TARGET, and
  # let step_zfs build a prebuilt zfs kmod deb for BOTH kernels (deduped when
  # equal). install_zfs_offline installs the KERNEL_TARGET one.
  # Explicit capture + check: fatal inside the substitution only exits the
  # subshell, so the caller must not rely on errexit (AGENTS.md rule).
  KERNEL_TARGET="$(resolve_pool_kernel)" ||
    fatal "cannot resolve the target kernel from the pool metapackages"
  [[ -n "${KERNEL_TARGET}" ]] ||
    fatal "cannot resolve the target kernel from the pool metapackages"
  export KERNEL_TARGET
  info "[build] target kernel (pool metapackage): ${KERNEL_TARGET}"
  printf '%s\n' "${KERNEL_TARGET}" >"${CACHE_DIR}/repo/KERNEL_TARGET"
}

# Echo the kernel the pool's linux-image-amd64 metapackage resolves to, after
# asserting the pool carries its image deb and that the headers metapackage
# resolves to the SAME kernel. Shared by step_pin_kernel (legacy) and
# step_resolve_kernel (golden mode, where this IS the one build kernel).
# Metapackage picks use sort -V | tail -1: the pool can accrete SEVERAL
# versions of a metapackage across populate epochs (cp -n never prunes),
# and apt installs the highest — the parse must match apt's choice.
resolve_pool_kernel() {
  local meta_deb="" hdr_deb="" dep="" hdr_kernel="" kernel=""
  meta_deb="$(compgen -G "${POOL}/linux-image-${ARCH}_*.deb" | sort -V | tail -n1 || true)"
  [[ -n "${meta_deb}" ]] ||
    fatal "pool carries no linux-image-${ARCH} metapackage — cannot resolve" \
      "the target kernel (cache_populate_debs pools the TARGET_BASE closure)."
  dep="$(dpkg-deb -f "${meta_deb}" Depends |
    grep -oE "linux-image-[0-9][^, ]*-${ARCH}" | head -n1 || true)"
  [[ -n "${dep}" ]] ||
    fatal "cannot parse the target kernel from ${meta_deb##*/} Depends"
  kernel="${dep#linux-image-}"
  compgen -G "${POOL}/linux-image-${kernel}_*.deb" >/dev/null ||
    fatal "pool metapackage resolves to linux-image-${kernel} but the" \
      "pool does not carry that image deb (closure incomplete)."
  # The image and headers metapackages MUST resolve to the same kernel. The
  # pool accretes across populate epochs, so they can skew (seen live:
  # image-amd64 -> 6.12.86, headers-amd64 -> 6.12.94) — and Debian's
  # linux-headers-<v>-<arch> Recommends its matching image, so a skewed
  # headers metapackage drags a SECOND kernel into the target that boots
  # first (grub picks the highest) with no prebuilt zfs module. Headers must
  # also match the boot kernel for dkms (NVIDIA, firstboot zfs) to build.
  hdr_deb="$(compgen -G "${POOL}/linux-headers-${ARCH}_*.deb" | sort -V | tail -n1 || true)"
  [[ -n "${hdr_deb}" ]] ||
    fatal "pool carries no linux-headers-${ARCH} metapackage (TARGET_BASE closure incomplete)."
  hdr_kernel="$(dpkg-deb -f "${hdr_deb}" Depends |
    grep -oE "linux-headers-[0-9][^, ]*-${ARCH}" | head -n1 || true)"
  hdr_kernel="${hdr_kernel#linux-headers-}"
  [[ -n "${hdr_kernel}" ]] ||
    fatal "cannot parse the headers kernel from ${hdr_deb##*/} Depends"
  [[ "${hdr_kernel}" == "${kernel}" ]] ||
    fatal "pool kernel metapackages skew: ${meta_deb##*/} -> ${kernel}" \
      "but ${hdr_deb##*/} -> ${hdr_kernel}. The pool mixes populate epochs;" \
      "refresh it: rm ${CACHE_DIR}/.pkgset.sha256 and re-run (repopulate" \
      "pulls the current, matching metapackage pair)."
  printf '%s\n' "${kernel}"
}

# 2b-golden (issue #111): ONE kernel, chosen by the pool — no stock ISO probe.
# KERNEL_PINNED existed only because the stock image dictated the live kernel;
# the golden rootfs IS the live image, so pin == target by construction.
# Setting both keeps step_zfs's two-kernel machinery working unchanged (its
# kmod loop dedupes equal kernels to a single build). The stamp rides the
# install store as KERNEL for the install-time contract.
step_resolve_kernel() {
  # Explicit capture + check — see step_pin_kernel's note on substitutions.
  KERNEL_TARGET="$(resolve_pool_kernel)" ||
    fatal "cannot resolve the build kernel from the pool metapackages"
  [[ -n "${KERNEL_TARGET}" ]] ||
    fatal "cannot resolve the build kernel from the pool metapackages"
  KERNEL_PINNED="${KERNEL_TARGET}"
  export KERNEL_TARGET KERNEL_PINNED
  info "[build] build kernel (pool metapackage): ${KERNEL_TARGET}"
  mkdir -p "${INSTALL_STORE}"
  printf '%s\n' "${KERNEL_TARGET}" >"${INSTALL_STORE}/KERNEL"
}

# 3) Build the source stack to pooled .debs, freshness-gated and chroot-correct.
#    HYPR_DESTDIR is a CHROOT-INTERNAL path; build_one installs to
#    ${TARGET}${stagerel} via the chroot, and package_to_deb reads that
#    host-visible tree. Low-level primitives are used on purpose (NOT
#    build_component_to_deb) so DESTDIR lands inside the buildroot.
step_build_stack() {
  local name tag debver stagerel
  # The build-dep set (HYPR_BUILD_PACKAGES) is identical for every component, so
  # install it ONCE before the loop instead of re-running install_build_deps per
  # rebuilt component (up to 21x). Pure build-time speedup; same packages land.
  # Mirrors the already-hoisted installer path (scripts/60-hyprland.sh build_stack).
  install_build_deps
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
      HYPR_DESTDIR="${stagerel}" build_one "${name}"
      package_to_deb "${TARGET}${stagerel}" "${name}" "${debver}" \
        "${ARCH}" "${HYPR_DEB_DEPENDS[${name}]:-}" "${POOL}"
      # Install the just-built component INTO the buildroot so later stack
      # components compile/link against it (e.g. wayland-protocols needs the
      # freshly-built wayland-scanner >= 1.25, not trixie's 1.23). The original
      # installer installs each build into the real prefix; here we stage to a
      # DESTDIR for the .deb, so we must also populate the buildroot /usr. Copy
      # only the staged /usr (the DESTDIR also carries a DEBIAN/ control dir).
      cp -a "${TARGET}${stagerel}/usr/." "${TARGET}/usr/"
      in_target "ldconfig"
    else
      info "reuse cached ${name}"
      # Even on reuse the buildroot needs the files for later components to
      # build against (dpkg-deb -x unpacks the data tree only, no maint scripts).
      dpkg-deb -x "${POOL}/${name}_${debver}_${ARCH}.deb" "${TARGET}"
      in_target "ldconfig"
    fi
  done
}

# 3b) Build the OPTIONAL xdg-desktop-portal-hyprland (xdph) screencast backend
#    into a pooled .deb. Mirrors ONE iteration of step_build_stack's body (resolve
#    tag -> stage source -> build_one with a chroot-internal HYPR_DESTDIR ->
#    package_to_deb into the pool), but the ENTIRE body runs in a guarded subshell
#    so any failure is NON-FATAL and cannot abort the ISO build: on failure we warn
#    and return 0, leaving the always-installed packaged wlr backend + static
#    routing conf as the guarantee. Runs AFTER step_build_stack so xdph links the
#    freshly source-built hypr* libs already copied into the buildroot /usr (no ABI
#    mismatch), and BEFORE step_runtime_closure so that pass scans the xdph deb and
#    pools its declared Qt6/PipeWire/sdbus-c++ runtime closure. xdph is NOT copied
#    into the buildroot /usr afterward (nothing else builds against it) and is NOT
#    verified — it is best-effort by design.
step_build_portal() {
  local name="${XDPH_COMPONENT}" tag debver stagerel
  (
    set -e
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
      HYPR_DESTDIR="${stagerel}" build_one "${name}"
      package_to_deb "${TARGET}${stagerel}" "${name}" "${debver}" \
        "${ARCH}" "${HYPR_DEB_DEPENDS[${name}]:-}" "${POOL}"
    else
      info "reuse cached ${name}"
    fi
  ) || warn "xdph build failed; packaged wlr fallback stands"
  return 0
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
  # Resume support: skip the (slow) OpenZFS source build if its debs are already
  # pooled. rm the openzfs-*.deb from the pool to force a rebuild. The prebuilt
  # kmod debs for the PINNED (live) and TARGET (pool metapackage) kernels must
  # both be pooled too (issue #110) — a pool from before the kmod debs existed,
  # or built for other kernels, is rebuilt.
  if compgen -G "${POOL}/openzfs-zfs-dkms_*.deb" >/dev/null &&
    compgen -G "${POOL}/openzfs-zfs-modules-${KERNEL_PINNED}_*.deb" >/dev/null &&
    compgen -G "${POOL}/openzfs-zfs-modules-${KERNEL_TARGET}_*.deb" >/dev/null; then
    info "[build] reusing pooled OpenZFS debs (skip ZFS source build)"
    return 0
  fi
  # OpenZFS ./configure (even for native-deb-utils, which does NOT compile the
  # module) probes for a kernel build dir at /lib/modules/<ver>/build. The
  # original installer builds ZFS in the target, which already carries
  # linux-headers-amd64 via TARGET_BASE_PACKAGES; the buildroot does not, so
  # install headers here — explicitly for BOTH kmod-build kernels (the pinned
  # live kernel from the release suite, the target kernel from security).
  info "[build] installing kernel headers for the OpenZFS configure probe"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y linux-headers-${KERNEL_PINNED} linux-headers-${KERNEL_TARGET}
  "
  info "[build] building OpenZFS into the pool ${POOL}"
  ZFS_DEB_POOL="${POOL}" install_zfs_from_source
}

# 4.5) Pool the runtime closure the built debs now DECLARE. Part A (dpkg-shlibdeps
#    in package_to_deb) makes the source/ZFS debs declare real shared-lib deps
#    (e.g. Hyprland -> libre2-11; issue #82) that the step-2 name-list closure
#    (cache_populate_debs, resolved BEFORE the source debs existed) never pulled.
#    Without this, those debs are absent from the pool and step_depsim would abort
#    the build. The buildroot is still networked with full apt, so fetch each
#    declared dep's .deb and harvest it. Names our own debs supersede via Provides
#    (Debian's libwayland-*/libxkbcommon*) are dropped — they are kept out of the
#    pool on purpose and satisfied by our debs' versioned Provides.
step_runtime_closure() {
  local d names provided n
  provided="$(_self_provided_names)"
  names="$(
    for d in "${POOL}"/*.deb; do
      [[ -e "${d}" ]] || continue
      dpkg-deb -f "${d}" Depends 2>/dev/null
    done | tr ',|' '\n' | sed 's/(.*)//; s/[[:space:]]//g' | sort -u
  )"
  local -a want=()
  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    [[ "${provided}" == *" ${n} "* ]] && continue
    # Skip a dep whose .deb is ALREADY in the pool (named ${name}_${ver}_${arch}.deb)
    # — cache_populate_debs pooled most of these at step 1, so re-fetching them is
    # pure wasted apt-get download. Conservative: step_depsim remains the hard
    # offline-completeness gate, so any genuinely-missing dep is still caught.
    compgen -G "${POOL}/${n}_*.deb" >/dev/null && continue
    want+=("${n}")
  done <<<"${names}"
  ((${#want[@]})) || return 0
  info "[build] pooling runtime closure of ${#want[@]} declared dep(s)"
  # apt-get download fetches each named .deb regardless of install state (so an
  # already-installed runtime lib like libre2-11 is still captured even though
  # apt considers it satisfied). Best-effort per name; step_depsim is the gate.
  in_target "
    cd /var/cache/apt/archives 2>/dev/null || exit 0
    export DEBIAN_FRONTEND=noninteractive
    for p in ${want[*]}; do apt-get download \"\${p}\" >/dev/null 2>&1 || true; done
  "
  if compgen -G "${TARGET}/var/cache/apt/archives/*.deb" >/dev/null; then
    cp -n "${TARGET}/var/cache/apt/archives/"*.deb "${POOL}/"
  fi
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
  # xdph is OPTIONAL and may not have built, so only add it to the simulated
  # install set when its .deb is actually pooled — otherwise apt-get --simulate
  # would fail on an unknown package and abort an otherwise-complete build. When
  # present, including it proves its Qt6/PipeWire/sdbus-c++ runtime closure also
  # resolves fully offline. NOT added to HYPR_BUILD_ORDER (the must-succeed set).
  local xdph_sim=""
  if compgen -G "${POOL}/${XDPH_COMPONENT}_*.deb" >/dev/null; then
    xdph_sim="${XDPH_COMPONENT}"
  fi
  # Out-of-archive pooled debs (chezmoi, brave-browser) are installed by name at
  # install time, so their closures must prove out offline too. Guarded like
  # xdph so a resumed pre-brave cache doesn't abort on an unknown package name
  # (chezmoi was never simulated before — pre-existing gap, closed here).
  local extra_sim=""
  compgen -G "${POOL}/chezmoi_*.deb" >/dev/null && extra_sim+=" chezmoi"
  compgen -G "${POOL}/brave-browser_*.deb" >/dev/null && extra_sim+=" brave-browser"
  # Bootstrap the throwaway base DIRECTLY from the offline pool — ZERO network.
  # step_reindex (step 5) already wrote ${CACHE_DIR}/repo/dists/${SUITE}/{Release,
  # main/binary-${ARCH}/Packages}, and the base debs were pooled at step 1, so the
  # pool can bootstrap a full base system offline. This drops the 4th base download
  # AND strengthens the test (proves the pool is self-sufficient for base bootstrap).
  # --no-check-gpg: the pool's apt-ftparchive Release is unsigned (no Release.gpg/
  # InRelease), so signature verification must be disabled — verified empirically
  # against this exact pool layout with debootstrap 1.0.141 (file:// + --no-check-gpg
  # installs the base successfully; a file:// debootstrap WITHOUT it fails on the
  # missing Release.gpg).
  debootstrap --no-check-gpg "${SUITE}" "${simroot}" "file://${CACHE_DIR}/repo" \
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
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_ORDER[*]} ${xdph_sim} ${extra_sim}
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

# =============================================================================
# Golden-rootfs pipeline (issue #111, HYPR_ISO_GOLDEN=1). A second, clean
# chroot is debootstrapped FROM THE FILE:// POOL and receives the complete
# target system in one apt transaction — a REAL offline install, strictly
# stronger than step_depsim's --simulate, and its result ships as the one
# squashfs (live session == install image). The buildroot (gcc-15/sid, dpkg-
# unowned /usr drops from step_build_stack) can never be that image.
# =============================================================================

# 6g-1) Debootstrap + populate the golden rootfs from the pool ONLY.
step_golden_rootfs() {
  # Hand the buildroot's binds back before switching chroots: from here on
  # every in_target call must land in the golden root, and the TARGET-keyed
  # guard machinery re-asserts against the new path.
  kill_target_processes
  teardown_chroot_binds
  TARGET="${GOLDEN}"
  export TARGET
  assert_build_sandbox "${ISO_WORKSPACE}" "${TARGET}" \
    || fatal "unsafe golden sandbox config."

  # Resume support: a fully-populated golden root from a prior run is reused
  # only while the pool's package sets are unchanged; anything else (partial
  # transaction, stale stamp) is rebuilt from scratch — a half-installed
  # golden image must never ship.
  local stamp="${ISO_WORKSPACE}/.golden-rootfs-done"
  if [[ -f "${stamp}" ]] && cache_pkgset_fresh && [[ -e "${GOLDEN}/etc/os-release" ]]; then
    info "[build] reusing existing golden rootfs ${GOLDEN}"
    install_policy_rc_d
    export HYPR_PRIVATE_RUN=1
    mount_chroot_binds
    assert_chrooted_in_target \
      || fatal "in_target is not chroot-backed; refusing to touch the golden root."
    return 0
  fi
  rm -f "${stamp}"
  rm -rf "${GOLDEN}"
  mkdir -p "${GOLDEN}"
  info "[build] debootstrap ${SUITE} -> ${GOLDEN} (from the file:// pool)"
  # --no-check-gpg: the pool's apt-ftparchive Release is unsigned (same
  # empirically-verified idiom as step_depsim's bootstrap).
  debootstrap --no-check-gpg "${SUITE}" "${GOLDEN}" "file://${CACHE_DIR}/repo" \
    || fatal "golden debootstrap failed"
  install_policy_rc_d
  export HYPR_PRIVATE_RUN=1
  mount_chroot_binds
  assert_chrooted_in_target \
    || fatal "in_target is not chroot-backed; refusing to build the golden root on the host."
  # Point apt at the pool ONLY (bind-mounted so file:// resolves inside the
  # chroot), exactly like step_depsim — the transaction below IS the offline-
  # completeness gate: anything missing from the pool fails it loudly.
  printf 'deb [trusted=yes] file://%s/repo %s main\n' "${CACHE_DIR}" "${SUITE}" \
    >"${GOLDEN}/etc/apt/sources.list"
  mkdir -p "${GOLDEN}${CACHE_DIR}"
  if mount --bind "${CACHE_DIR}" "${GOLDEN}${CACHE_DIR}"; then
    track_mount "${GOLDEN}${CACHE_DIR}"
  fi
  # The one transaction: full target base (both microcodes — the image is
  # CPU-agnostic), golden extras, the source-built stack, upstream OpenZFS
  # (prebuilt kmod for the ONE kernel; dkms deb stays dormant for firstboot),
  # chezmoi + brave, and the dkms-dep tail that must be resident before
  # firstboot (file/lsb-release/libc6-dev — the store is gone by then).
  local -a pkgs=() p=""
  mapfile -t pkgs < <(filter_zfs_debian_packages "${TARGET_BASE_PACKAGES[@]}")
  pkgs+=("${GOLDEN_EXTRA_PACKAGES[@]}" "${HYPR_BUILD_ORDER[@]}")
  pkgs+=(chezmoi brave-browser)
  pkgs+=("openzfs-zfs-modules-${KERNEL_TARGET}")
  for p in "${ZFS_UPSTREAM_PACKAGES[@]}"; do
    [[ "${p}" == "openzfs-zfs-dkms" ]] || pkgs+=("${p}")
  done
  pkgs+=(file lsb-release libc6-dev)
  info "[build] installing the golden system (${#pkgs[@]} package names, pool only)"
  # man-db's per-transaction reindex is minutes of dead CPU; same debconf
  # trick as install_base_packages, persisted into the image (the daily
  # timer indexes on the running system).
  in_target "echo 'man-db man-db/auto-update boolean false' | debconf-set-selections"
  # shim-signed's postinst (update-secureboot-policy) inspects the HOST's
  # Secure Boot state: mdadm's initramfs hook (Debian #962844) mounts the
  # host's efivarfs into the chroot mid-transaction, so on an SB-enabled
  # build host the policy script sees SecureBoot=1 + a DKMS dir (ddcci),
  # takes the disable-SB prompt path (template default: true) and exits 1
  # noninteractively, failing the whole transaction. Preseed "keep Secure
  # Boot as-is" — it bakes into the image and equally protects the firstboot
  # zfs-dkms install on SB machines (MOK signing is our own machinery).
  in_target "echo 'shim-signed-common shim/disable_secureboot boolean false' | debconf-set-selections"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ${pkgs[*]}
  "
  # Drop the efivarfs mount the mdadm initramfs hook left behind (see the
  # shim preseed above): it is the host's WRITABLE EFI NVRAM exposed inside
  # the build chroot — exactly what HYPR_PRIVATE_RUN exists to prevent — and
  # as an untracked child of ${TARGET}/sys it makes the teardown umount busy.
  if mountpoint -q "${TARGET}/sys/firmware/efi/efivars"; then
    umount "${TARGET}/sys/firmware/efi/efivars" ||
      warn "could not unmount stray efivars in the golden chroot"
  fi
  # Optional Qt6 ScreenCast backend — best-effort AFTER the must-succeed set,
  # exactly like the installer path (never strands the build).
  install_xdph_best_effort
  # Addon vendor debs bake into the image (addons/*.list already rode
  # TARGET_BASE_PACKAGES); the per-install addon hooks (*.sh) and staged
  # runfiles (*.run) stay install-time concerns.
  if compgen -G "addons/*.deb" >/dev/null; then
    info "[build] baking addon .deb packages into the golden image"
    rm -rf "${GOLDEN}/var/tmp/addon-debs"
    install -d "${GOLDEN}/var/tmp/addon-debs"
    cp addons/*.deb "${GOLDEN}/var/tmp/addon-debs/"
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y /var/tmp/addon-debs/*.deb
    "
    rm -rf "${GOLDEN}/var/tmp/addon-debs"
  fi
  # Upstream-OpenZFS install tail, mirrored from install_zfs_offline MINUS the
  # MOK signing (the key is per-machine; customize signs the .ko in place) —
  # assert the prebuilt module landed, keep the pam module out, pin the
  # metapackages manual, and depmod so the module resolves in the live boot.
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs*pam*'
    fi
    rm -f /usr/share/pam-configs/*zfs*
    pam-auth-update --package
    apt-mark manual openzfs-zfs-modules-${KERNEL_TARGET} openzfs-zfsutils \
      openzfs-zfs-initramfs openzfs-zfs-zed file lsb-release libc6-dev >/dev/null
    kos=\"\$(dpkg-query -L 'openzfs-zfs-modules-${KERNEL_TARGET}' | grep '\\.ko\$' || true)\"
    [[ -n \"\${kos}\" ]] ||
      { echo 'openzfs-zfs-modules-${KERNEL_TARGET} installed no .ko files' >&2; exit 1; }
    depmod '${KERNEL_TARGET}'
    modinfo -k '${KERNEL_TARGET}' zfs >/dev/null
  "
  : >"${stamp}"
}

# 6g-2) Session + identity staging inside the golden root: the machine-
# independent session files (user configs into /etc/skel — the live-config
# live user AND the installed create_user account both inherit them via
# adduser), the harvested vendor artifacts, the dormant firstboot machinery,
# the live-only autologin hook, and the image manifest.
step_golden_session() {
  # install_lythmono_fonts/stage_brave_apt_source/stage_zfs_dkms_job/... live
  # in scripts/40-system.sh, outside the critical top-level source order —
  # lazy-source + re-assert, exactly like step_zfs.
  if ! declare -f install_lythmono_fonts >/dev/null 2>&1; then
    # shellcheck disable=SC1091  # validated repo-relative path
    source "${REPO_ROOT}/scripts/40-system.sh"
  fi
  assert_chrooted_in_target \
    || fatal "in_target is not chroot-backed after sourcing 40-system.sh; refusing to stage on host."
  info "[build] staging session configs + vendor artifacts into the golden root"
  SESSION_CONFIG_HOME=/etc/skel stage_session_configs
  # A working default Hyprland config ships in skel too (us layout — the
  # installer re-generates it per keymap at customize; the live demo uses
  # this copy as-is). Reads the example the hyprland deb just installed.
  SESSION_CONFIG_HOME=/etc/skel write_hypr_lua_config
  # Vendor artifacts harvested into the workspace store bake straight into
  # the image (they no longer ship on the ISO).
  install_lythmono_fonts
  install_adw_gtk3_theme
  stage_brave_apt_source
  # Dormant firstboot: runner + unit + the zfs-dkms handover job bake in
  # DISABLED — the live session must never run firstboot jobs; customize
  # enables the unit on the installed system.
  write_firstboot_runner
  stage_zfs_dkms_job
  stage_live_autologin_hook
  # ssh-over-vsock generator noise fix (was a live-extras bake).
  neuter_ssh_vsock_generator
  # sshd serves the live session (and the installed system); host keys are
  # scrubbed from the image, so a conditional oneshot regenerates them on
  # any boot that finds none (live boots; customize regenerates for the
  # installed system, leaving the unit inert there).
  cat >"${GOLDEN}/etc/systemd/system/hypr-sshd-keygen.service" <<'EOF'
[Unit]
Description=Generate missing ssh host keys (the golden image ships none)
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
  # live-config's openssh-server component force-disables password auth at
  # live boot by editing sshd_config in place. The sshd_config.d include is
  # read FIRST and first-obtained-value wins, so this drop-in keeps the live
  # session reachable with the live user's password (the test lane drives
  # installs over SSH; a keyless live medium is otherwise unreachable).
  # prune_live_artifacts removes it — installed systems keep stock policy.
  install -d "${GOLDEN}/etc/ssh/sshd_config.d"
  cat >"${GOLDEN}/etc/ssh/sshd_config.d/20-hypr-live.conf" <<'EOF'
# Live session only (removed by the installer's customize phase).
PasswordAuthentication yes
EOF
  in_target "
    set -e
    systemctl enable ssh.service
    systemctl enable hypr-sshd-keygen.service
  "
  write_build_manifest
}

# Live-only greetd autologin (issue #111 decision): a live-config hook
# rewrites config.toml at LIVE BOOT, in the tmpfs overlay — the squashfs
# keeps the tuigreet default, so the tree the installer copies is untouched.
# The hook file is NOT owned by live-config's package; customize removes it
# explicitly on the installed system.
stage_live_autologin_hook() {
  install -d "${GOLDEN}/usr/lib/live/config"
  cat >"${GOLDEN}/usr/lib/live/config/2999-hypr-autologin" <<'EOF'
#!/bin/sh
# hypr-deb golden image: autologin the live user straight into Hyprland.
# Runs only under live-config (live boots); the rewrite lands in the
# overlay, never in the squashfs the installer copies to disk.
user="${LIVE_USERNAME:-user}"
cat > /etc/greetd/config.toml <<CFG
[terminal]
vt = 1

[default_session]
command = "/usr/bin/hypr-session"
user = "${user}"
CFG
EOF
  chmod 755 "${GOLDEN}/usr/lib/live/config/2999-hypr-autologin"
}

# /etc/hypr-deb/build-manifest: what this image was built from — consumed by
# the end-of-install upstream advisory (issue #94) and by humans debugging an
# installed system. Component versions come from the pooled debs (survives
# cached-rebuild resumes where HYPR_RESOLVED_TAG is unpopulated).
write_build_manifest() {
  local manifest="${GOLDEN}/etc/hypr-deb/build-manifest" name="" deb=""
  mkdir -p "${GOLDEN}/etc/hypr-deb"
  {
    printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'kernel=%s\n' "${KERNEL_TARGET}"
    for name in "${HYPR_BUILD_ORDER[@]}" "${XDPH_COMPONENT}" openzfs-zfsutils; do
      deb="$(compgen -G "${POOL}/${name}_*.deb" | sort -V | tail -n1 || true)"
      [[ -n "${deb}" ]] || continue
      printf '%s=%s\n' "${name}" "$(dpkg-deb -f "${deb}" Version)"
    done
  } >"${manifest}"
}

# 6g-3) The install store: everything install time still needs from the
# medium — the four NVIDIA variants, the bootloader trio, the ZBM EFI and the
# KERNEL stamp — indexed as its own apt repo. The bootloader closure resolves
# INSIDE the golden chroot against its real installed set (a temporary online
# source scoped by -o, downloads only), so the store carries exactly what an
# install of any of the three loaders would still need.
step_install_store() {
  mkdir -p "${INSTALL_STORE}/pool"
  info "[build] downloading the bootloader closure into the install store"
  local list="/etc/apt/sources.list.d/zz-bootloader-store-build.list"
  local resolv="${GOLDEN}/etc/resolv.conf" had_resolv=0
  # The golden root was bootstrapped offline; give its apt a resolver for
  # this one online download (same idiom as the legacy live-extras bake).
  if [[ -e "${resolv}" || -L "${resolv}" ]]; then
    had_resolv=1
    mv "${resolv}" "${resolv}.store-build.bak"
  fi
  cp -L /etc/resolv.conf "${resolv}" 2>/dev/null || true
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    printf '%s\n' 'deb ${MIRROR} ${SUITE} main contrib non-free-firmware' >${list}
    aopt='-o Dir::Etc::SourceList=${list} -o Dir::Etc::SourceParts=/dev/null'
    apt-get update -qq \${aopt}
    apt-get install -y --download-only \${aopt} \
      grub-efi-amd64 grub-efi-amd64-signed systemd-boot os-prober
    rm -f ${list}
  "
  rm -f "${resolv}"
  if ((had_resolv)); then
    mv "${resolv}.store-build.bak" "${resolv}"
  fi
  if compgen -G "${GOLDEN}/var/cache/apt/archives/*.deb" >/dev/null; then
    cp -n "${GOLDEN}/var/cache/apt/archives/"*.deb "${INSTALL_STORE}/pool/"
  fi
  in_target "apt-get clean"
  # The NVIDIA closures (both flavors x both branches + cuda-keyring) are the
  # bulk of the store; cache_populate_nvidia builds them in its own scratch
  # chroot so nothing NVIDIA ever touches the golden root.
  cache_populate_nvidia "${INSTALL_STORE}/pool"
  cache_index_repo "${INSTALL_STORE}"
  # Non-apt store artifacts: the ZBM EFI for --bootloader=zbm and the KERNEL
  # stamp (written by step_resolve_kernel; re-asserted here).
  [[ -f "${INSTALL_STORE}/KERNEL" ]] ||
    fatal "install store lacks the KERNEL stamp (step_resolve_kernel writes it)"
  if [[ ! -f "${INSTALL_STORE}/zfsbootmenu.EFI" ]]; then
    if ! declare -f fetch_zbm_efi >/dev/null 2>&1; then
      # shellcheck disable=SC1091  # validated repo-relative path
      source "${REPO_ROOT}/scripts/50-boot.sh"
    fi
    info "[build] staging ZFSBootMenu EFI into the install store"
    fetch_zbm_efi "${INSTALL_STORE}/zfsbootmenu.EFI"
  fi
}

# 6g-4) NVIDIA depsim: prove every variant resolves offline against the
# GOLDEN image's real dpkg status + the install store, per branch and flavor.
# The branch pin works through apt preferences installed by the pin package;
# a pure simulation never installs it, so the preferences file is extracted
# from the pooled pin deb and passed via -o — the simulation then resolves
# exactly the branch an install would.
step_nvidia_depsim() {
  info "[build] simulating the NVIDIA variants against the install store only"
  local simtmp="" branch="" flavor="" pin_deb="" prefs="" out="" rc=0
  local -a flavor_pkgs=()
  simtmp="$(mktemp -d "${ISO_WORKSPACE}/nvidia-depsim.XXXXXX")"
  printf 'deb [trusted=yes] file://%s %s main\n' "${INSTALL_STORE}" "${SUITE}" \
    >"${simtmp}/sources.list"
  mkdir -p "${simtmp}/state/lists/partial" "${simtmp}/cache"
  local -a aopt=(
    -o "Dir::Etc::SourceList=${simtmp}/sources.list"
    -o "Dir::Etc::SourceParts=/dev/null"
    -o "Dir::Etc::PreferencesParts=/dev/null"
    -o "Dir::State=${simtmp}/state"
    -o "Dir::State::status=${GOLDEN}/var/lib/dpkg/status"
    -o "Dir::Cache=${simtmp}/cache"
  )
  for branch in 595 610; do
    pin_deb="$(compgen -G "${INSTALL_STORE}/pool/nvidia-driver-pinning-${branch}_*.deb" |
      sort -V | tail -n1 || true)"
    [[ -n "${pin_deb}" ]] ||
      { rm -rf "${simtmp}"; fatal "install store lacks the ${branch} pin deb"; }
    rm -rf "${simtmp}/pin"
    dpkg-deb -x "${pin_deb}" "${simtmp}/pin"
    prefs="$(compgen -G "${simtmp}/pin/etc/apt/preferences.d/*" | head -n1 || true)"
    [[ -n "${prefs}" ]] ||
      { rm -rf "${simtmp}"; fatal "${pin_deb##*/} carries no apt preferences file"; }
    apt-get "${aopt[@]}" -o "Dir::Etc::Preferences=${prefs}" update -qq ||
      { rm -rf "${simtmp}"; fatal "nvidia depsim: apt update against the store failed"; }
    for flavor in open proprietary; do
      if [[ "${flavor}" == open ]]; then
        flavor_pkgs=("${NVIDIA_OPEN_PACKAGES[@]}")
      else
        flavor_pkgs=("${NVIDIA_PROP_PACKAGES[@]}")
      fi
      out="$(DEBIAN_FRONTEND=noninteractive apt-get "${aopt[@]}" \
        -o "Dir::Etc::Preferences=${prefs}" \
        install --simulate -y \
        "${flavor_pkgs[@]}" "${NVIDIA_FIRMWARE_PACKAGES[@]}" cuda-keyring)" && rc=0 || rc=$?
      ((rc == 0)) ||
        { rm -rf "${simtmp}"; fatal "nvidia depsim failed: branch ${branch} ${flavor}"; }
      if grep -Eq 'https?://' <<<"${out}"; then
        grep -E 'https?://' <<<"${out}" | warn_lines
        rm -rf "${simtmp}"
        fatal "nvidia depsim: branch ${branch} ${flavor} would resolve outside the store."
      fi
      info "[build] nvidia depsim ok: branch ${branch}, ${flavor}"
    done
  done
  rm -rf "${simtmp}"
}

# 6g-5) Finalize the golden image for shipping: permanent Debian sources
# replace the temporary file:// pool source, the chroot service guard comes
# OUT (it must never ship), identity is scrubbed (machine-id, ssh host keys
# — regenerated per boot/install), apt caches drop, and the binds are torn
# down so mksquashfs captures a quiescent tree.
step_finalize_golden() {
  info "[build] finalizing the golden image (sources, guard, identity scrub)"
  write_debian_sources "${GOLDEN}"
  rm -f "${GOLDEN}/etc/apt/sources.list"
  rm -f "${GOLDEN}/usr/sbin/policy-rc.d"
  golden_hygiene_scrub
  kill_target_processes
  teardown_chroot_binds
}

# Identity + cache scrub. machine-id is TRUNCATED (not removed): an empty
# file means "uninitialized" to systemd, which then generates a fresh id on
# boot (live) or via systemd-machine-id-setup (customize). ssh host keys are
# removed outright (hypr-sshd-keygen / customize regenerate). apt lists and
# the binary caches are regenerable dead weight in a squashfs.
golden_hygiene_scrub() {
  : >"${GOLDEN}/etc/machine-id"
  rm -f "${GOLDEN}/var/lib/dbus/machine-id"
  rm -f "${GOLDEN}/etc/ssh/ssh_host_"*
  in_target "apt-get clean"
  rm -rf "${GOLDEN}/var/lib/apt/lists"/* "${GOLDEN}/var/cache/apt"/*.bin
}

# ensure_wallpapers_checked_out [REPO_ROOT_OVERRIDE]
# Check out the assets/wallpapers shallow submodule so step_assemble bakes the
# actual images onto the ISO. The offline install copies wallpapers from this
# bundled tree (never the network), so an empty submodule would silently ship a
# wallpaper-less offline system. Idempotent (no-op once populated); fatal on
# failure. The build host is online, so fetching here is correct. Takes the repo
# root as an argument so tests can point it at a fixture.
ensure_wallpapers_checked_out() {
  local root="$1"
  [[ -f "${root}/.gitmodules" ]] || return 0
  [[ -z "$(ls -A "${root}/assets/wallpapers" 2>/dev/null || true)" ]] || return 0
  info "[build] checking out the wallpaper submodule for the offline ISO"
  git -C "${root}" submodule update --init --depth 1 -- assets/wallpapers ||
    fatal "could not check out assets/wallpapers; the offline ISO would ship no wallpapers"
}

# 7) Assemble the final ISO (xorriso, runs in tools/iso-assemble.sh): inject the
#    offline repo AND a filtered copy of the installer tree, so the booted live
#    ISO can run the installer fully offline (no git clone).
step_assemble() {
  info "[build] staging installer payload for the ISO"
  local payload="${ISO_WORKSPACE}/installer-payload"
  rm -rf "${payload}"
  mkdir -p "${payload}"
  # Wallpapers ride the ISO as plain files: make sure the shallow submodule is
  # checked out before copying assets/, so the offline install has them locally.
  ensure_wallpapers_checked_out "${REPO_ROOT}"
  # Ship only what the target install needs; exclude host-only build tooling
  # (tools/), docs/, tests/, and VCS. Missing optional items are ignored.
  local item
  for item in installer.sh lib scripts addons assets README.md STRUCTURE.md; do
    [[ -e "${REPO_ROOT}/${item}" ]] && cp -a "${REPO_ROOT}/${item}" "${payload}/"
  done
  # Recreation fails if the target ISO already exists, so clear any prior build
  # first. Only reached under --confirm; STOCK_ISO is a different path, never touched.
  if [[ -e "${OUT_ISO}" ]]; then
    info "[build] removing existing ${OUT_ISO}"
    rm -f "${OUT_ISO}"
  fi
  info "[build] assembling ${OUT_ISO}"
  # Invoke via bash so it works regardless of the script's execute bit.
  # iso-assemble runs as its OWN bash process, so it sees only env that is
  # exported or inline-prefixed here. Forward the unattended-autoinstall knobs;
  # LIVE_AUTOINSTALL_PASSWORD is the security-critical one — it is supplied at
  # build time and defaults EMPTY (never hardcoded/committed). iso-assemble.sh
  # defaults the rest itself, so these prefixes only pass through operator values.
  # Golden mode: GOLDEN_ROOT selects iso-assemble's golden path (mksquashfs the
  # golden tree, map our kernel/initrd over the stock /live names, store +
  # installer to the ISO9660 medium) and the repo argument becomes the small
  # install store instead of the full pool.
  local repo_arg="${CACHE_DIR}/repo" golden_root=""
  if ((HYPR_ISO_GOLDEN)); then
    repo_arg="${INSTALL_STORE}"
    golden_root="${GOLDEN}"
  fi
  GOLDEN_ROOT="${golden_root}" \
    HYPR_INSTALLER_DIR="${payload}" \
    LIVE_AUTOINSTALL_PASSWORD="${LIVE_AUTOINSTALL_PASSWORD:-}" \
    LIVE_AUTOINSTALL_BOOTLOADER="${LIVE_AUTOINSTALL_BOOTLOADER:-grub}" \
    LIVE_AUTOINSTALL_RTC="${LIVE_AUTOINSTALL_RTC:-utc}" \
    LIVE_AUTOINSTALL_USERNAME="${LIVE_AUTOINSTALL_USERNAME:-me}" \
    bash "${TOOLS_DIR}/iso-assemble.sh" "${STOCK_ISO}" "${repo_arg}" "${OUT_ISO}" \
    || fatal "iso-assemble failed"
}

# 6b) Stage the ZFSBootMenu EFI INSIDE the offline store so iso-assemble grafts
#     it onto the ISO at /hypr-repo/zfsbootmenu.EFI. install_zbm reads it from
#     there on an offline install (preflight redirects CACHE_REPO_DIR to the
#     on-ISO store). fetch_zbm_efi lives in scripts/50-boot.sh, outside the
#     critical top-level source order, so source it lazily like step_zfs does
#     for 40-system.sh.
step_stage_zbm() {
  local dest="${CACHE_DIR}/repo/zfsbootmenu.EFI"
  if [[ -f "${dest}" ]]; then
    info "[build] reusing staged ZFSBootMenu EFI (${dest})"
    return 0
  fi
  if ! declare -f fetch_zbm_efi >/dev/null 2>&1; then
    source "${REPO_ROOT}/scripts/50-boot.sh"
  fi
  info "[build] staging ZFSBootMenu EFI into the offline store (${dest})"
  fetch_zbm_efi "${dest}"
}

# 6c) Stage the LythMono TTFs INSIDE the offline store so iso-assemble grafts
#     them onto the ISO at ${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR}.
#     install_lythmono_fonts (scripts/40-system.sh) copies them from there on an
#     OFFLINE install — NO GitHub fetch. harvest_lythmono_fonts lives in
#     40-system.sh, outside the critical top-level source order, so source it
#     lazily exactly like step_zfs does (preserving the chroot-backed in_target).
step_stage_fonts() {
  local dest="${CACHE_DIR}/repo/${LYTHMONO_STORE_SUBDIR}"
  if compgen -G "${dest}/*.ttf" >/dev/null 2>&1; then
    info "[build] reusing staged LythMono fonts (${dest})"
    return 0
  fi
  if ! declare -f harvest_lythmono_fonts >/dev/null 2>&1; then
    # shellcheck disable=SC1091  # validated repo-relative path
    source "${REPO_ROOT}/scripts/40-system.sh"
  fi
  info "[build] staging LythMono fonts into the offline store (${dest})"
  harvest_lythmono_fonts "${dest}"
}

# 6d) Stage the walker launcher stack (walker + elephant + providers) INSIDE
#     the offline store so iso-assemble grafts it onto the ISO at
#     ${CACHE_REPO_DIR}/${WALKER_STORE_SUBDIR}. stage_walker_launcher
#     (scripts/60-hyprland.sh) installs from there on an OFFLINE install — NO
#     GitHub fetch. Same lazy-source pattern as step_stage_fonts.
step_stage_walker() {
  local dest="${CACHE_DIR}/repo/${WALKER_STORE_SUBDIR}" p=""
  # Reuse only if the binaries AND every configured provider .so are present —
  # a store staged before ELEPHANT_PROVIDERS grew must be re-harvested, or the
  # ISO silently ships without the new providers (dead walker prefixes on the
  # installed system; hit live 2026-07-04 after websearch/runner/windows).
  local complete=1
  [[ -x "${dest}/walker" && -x "${dest}/elephant" ]] || complete=0
  for p in "${ELEPHANT_PROVIDERS[@]}"; do
    [[ -f "${dest}/${p}.so" ]] || { complete=0; break; }
  done
  if [[ "${complete}" -eq 1 ]]; then
    info "[build] reusing staged walker launcher stack (${dest})"
    return 0
  fi
  if ! declare -f harvest_walker_launcher >/dev/null 2>&1; then
    # shellcheck disable=SC1091  # validated repo-relative path
    source "${REPO_ROOT}/scripts/40-system.sh"
  fi
  info "[build] staging walker launcher stack into the offline store (${dest})"
  harvest_walker_launcher "${dest}"
}

# 6e) Stage the adw-gtk3 theme dirs INSIDE the offline store so iso-assemble
#     grafts them onto the ISO at ${CACHE_REPO_DIR}/${ADW_GTK3_STORE_SUBDIR}.
#     install_adw_gtk3_theme (scripts/40-system.sh) copies them from there on an
#     OFFLINE install — NO GitHub fetch. Same lazy-source pattern as
#     step_stage_fonts.
step_stage_adw_gtk3() {
  local dest="${CACHE_DIR}/repo/${ADW_GTK3_STORE_SUBDIR}" f="" complete=1
  # Reuse only if BOTH themes carry their leaf payload files (verified against
  # the v6.5 release layout) — bare dirs appear early in the archive, so a
  # partial extract must be re-harvested, not silently shipped.
  for f in adw-gtk3/index.theme adw-gtk3/gtk-3.0/gtk.css \
    adw-gtk3-dark/index.theme adw-gtk3-dark/gtk-3.0/gtk.css; do
    [[ -f "${dest}/${f}" ]] || { complete=0; break; }
  done
  if [[ "${complete}" -eq 1 ]]; then
    info "[build] reusing staged adw-gtk3 theme (${dest})"
    return 0
  fi
  if ! declare -f harvest_adw_gtk3 >/dev/null 2>&1; then
    # shellcheck disable=SC1091  # validated repo-relative path
    source "${REPO_ROOT}/scripts/40-system.sh"
  fi
  info "[build] staging adw-gtk3 theme into the offline store (${dest})"
  harvest_adw_gtk3 "${dest}"
}

# restore_build_ownership
# The build runs as root (sudo), so everything it writes under the workspace and
# the output ISO is left root-owned — stranding the operator and re-tripping the
# dry-run test. Hand it back to the user who invoked sudo (SUDO_UID/SUDO_GID).
# No-op when not run under sudo (real root login: nothing to hand back).
restore_build_ownership() {
  [[ -n "${SUDO_UID:-}" ]] || return 0
  if ((HYPR_ISO_GOLDEN)); then
    # The golden rootfs IS the shipped filesystem: its internal ownership
    # (root, _greetd, man, ...) must survive into mksquashfs and across
    # resumed builds, so it is exempt from the handback — everything else
    # in the workspace still goes back to the operator.
    local entry=""
    for entry in "${ISO_WORKSPACE}"/* "${ISO_WORKSPACE}"/.[!.]*; do
      [[ -e "${entry}" ]] || continue
      [[ "${entry}" == "${GOLDEN}" ]] && continue
      chown -R "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${entry}" 2>/dev/null || true
    done
    chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" \
      "${ISO_WORKSPACE}" "${OUT_ISO}" 2>/dev/null || true
    return 0
  fi
  chown -R "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" \
    "${ISO_WORKSPACE}" "${OUT_ISO}" 2>/dev/null || true
}

run_heavy_build() {
  step_bootstrap_chroot     # 1
  step_cache                # 2
  if ((HYPR_ISO_GOLDEN)); then
    step_resolve_kernel     # 2b-golden: ONE kernel, chosen by the pool
  else
    step_pin_kernel         # 2b: live kernel == pool/target kernel, enforced
  fi
  step_build_stack          # 3
  step_build_portal         # 3b: OPTIONAL xdph screencast backend (non-fatal)
  step_zfs                  # 4 (golden: pin == target, so ONE kmod builds)
  step_runtime_closure      # 4.5: pool the runtime deps the built debs declare
  step_reindex              # 5
  if ((HYPR_ISO_GOLDEN)); then
    step_stage_fonts        # harvests feed the golden image, not the medium
    step_stage_walker
    step_stage_adw_gtk3
    step_golden_rootfs      # 6g-1: the REAL offline install (replaces depsim)
    step_golden_session     # 6g-2: skel configs, vendor bakes, dormant firstboot
    step_install_store      # 6g-3: NVIDIA + bootloader store, ZBM, KERNEL
    step_nvidia_depsim      # 6g-4: every variant resolves against the store
    step_finalize_golden    # 6g-5: sources/guard/identity scrub, binds down
  else
    step_depsim             # 6
    step_stage_zbm          # 6b: ship ZFSBootMenu EFI inside /hypr-repo
    step_stage_fonts        # 6c: ship LythMono TTFs inside the offline store
    step_stage_walker       # 6d: ship walker+elephant inside the offline store
    step_stage_adw_gtk3     # 6e: ship the adw-gtk3 theme inside the offline store
  fi
  step_assemble             # 7
  kill_target_processes     # 8: reap any stray chroot daemon holding a mount
  teardown_chroot_binds     # 9 (also via trap)
  info "[build] done: ${OUT_ISO}"
}

main() {
  local confirm=0 clear_cache=0
  while (($#)); do
    case "$1" in
      --confirm) confirm=1 ;;
      --clear-cache) clear_cache=1 ;;
      -h | --help)
        plan_summary
        printf '\nRun with --confirm to execute the build (root required).\n'
        printf 'Add --clear-cache to wipe %s first (full re-download/rebuild).\n' "${CACHE_DIR}"
        return 0
        ;;
      *) fatal "unknown argument: $1 (use --confirm to build, --clear-cache to wipe the cache first, or no args for a dry-run plan)" ;;
    esac
    shift
  done

  # SAFE BY DEFAULT: without --confirm, print the plan and exit 0. No root, no
  # sandbox check, no mutation — this path is what the unit test exercises.
  if ((confirm == 0)); then
    info "DRY-RUN (no --confirm): printing plan, mutating nothing."
    ((clear_cache)) && info "(--clear-cache noted: ${CACHE_DIR} would be removed first)"
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

  # --clear-cache: wipe BEFORE any mounts exist (never rm -rf CACHE_DIR once
  # the buildroot binds are live — see teardown_chroot_binds). Sandbox assert
  # above already proved the workspace path is safe.
  if ((clear_cache)); then
    info "[build] --clear-cache: removing ${CACHE_DIR}"
    rm -rf "${CACHE_DIR}"
  fi

  # Mounts must never leak, even on failure; and the root build must not leave
  # root-owned droppings in the operator's workspace/output (which strand the
  # user and re-trip the dry-run test on the next run). restore_build_ownership
  # runs last on EXIT, after the binds are torn down.
  trap 'teardown_chroot_binds; restore_build_ownership' EXIT
  trap 'teardown_chroot_binds' ERR

  mkdir -p "${ISO_WORKSPACE}" "${POOL}" "${DEBOOTSTRAP_CACHE}"
  run_heavy_build
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
