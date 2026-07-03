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
  cache_index_repo
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
  # pooled. rm the openzfs-*.deb from the pool to force a rebuild.
  if compgen -G "${POOL}/openzfs-zfs-dkms_*.deb" >/dev/null; then
    info "[build] reusing pooled OpenZFS debs (skip ZFS source build)"
    return 0
  fi
  # OpenZFS ./configure (even for native-deb-utils, which does NOT compile the
  # module) probes for a kernel build dir at /lib/modules/<ver>/build. The
  # original installer builds ZFS in the target, which already carries
  # linux-headers-amd64 via TARGET_BASE_PACKAGES; the buildroot does not, so
  # install it here. The metapackage matches linux-image-amd64 in the pool.
  info "[build] installing kernel headers for the OpenZFS configure probe"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y linux-headers-amd64
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
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_ORDER[*]} ${xdph_sim}
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
  HYPR_INSTALLER_DIR="${payload}" \
    LIVE_AUTOINSTALL_PASSWORD="${LIVE_AUTOINSTALL_PASSWORD:-}" \
    LIVE_AUTOINSTALL_BOOTLOADER="${LIVE_AUTOINSTALL_BOOTLOADER:-grub}" \
    LIVE_AUTOINSTALL_RTC="${LIVE_AUTOINSTALL_RTC:-local}" \
    LIVE_AUTOINSTALL_USERNAME="${LIVE_AUTOINSTALL_USERNAME:-me}" \
    bash "${TOOLS_DIR}/iso-assemble.sh" "${STOCK_ISO}" "${CACHE_DIR}/repo" "${OUT_ISO}" \
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

# restore_build_ownership
# The build runs as root (sudo), so everything it writes under the workspace and
# the output ISO is left root-owned — stranding the operator and re-tripping the
# dry-run test. Hand it back to the user who invoked sudo (SUDO_UID/SUDO_GID).
# No-op when not run under sudo (real root login: nothing to hand back).
restore_build_ownership() {
  [[ -n "${SUDO_UID:-}" ]] || return 0
  chown -R "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" \
    "${ISO_WORKSPACE}" "${OUT_ISO}" 2>/dev/null || true
}

run_heavy_build() {
  step_bootstrap_chroot     # 1
  step_cache                # 2
  step_build_stack          # 3
  step_build_portal         # 3b: OPTIONAL xdph screencast backend (non-fatal)
  step_zfs                  # 4
  step_runtime_closure      # 4.5: pool the runtime deps the built debs declare
  step_reindex              # 5
  step_depsim               # 6
  step_stage_zbm            # 6b: ship ZFSBootMenu EFI inside /hypr-repo
  step_stage_fonts          # 6c: ship LythMono TTFs inside the offline store
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
