# shellcheck shell=bash
# Offline cache: a local apt repo (pool/ + apt-ftparchive indexes), source
# tag archives for the hyprwm stack, and the ZFSBootMenu EFI binary.
# Layout:
#   ${CACHE_DIR}/repo/pool/*.deb
#   ${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages[.gz]
#   ${CACHE_DIR}/repo/dists/${SUITE}/Release
#   ${CACHE_DIR}/sources/<name>-<tag>.tar.gz + MANIFEST ("name tag" lines)
#   ${CACHE_DIR}/zfsbootmenu.EFI
# Depends on resolve_latest_release_tag from scripts/60-hyprland.sh; the
# orchestrator sources all modules before dispatching any phase.

# Install-time consumers (live env, offline). CACHE_REPO_DIR defaults to
# ${CACHE_DIR}/repo but preflight redirects it to the on-ISO store
# (ISO_MEDIUM_REPO) when booted from our offline ISO, so these resolve the
# repo wherever it actually lives.
cache_repo_exists() {
  [[ -f "${CACHE_REPO_DIR}/dists/${SUITE}/main/binary-${ARCH}/Packages" ]]
}

# Stable hash of the package sets that determine the pool's contents (the exact
# arrays cache_populate_debs feeds to the closure apt-get). Sorted so reordering
# does not invalidate the pool. Used to detect when the pool is stale because a
# package was added/removed since it was last populated.
cache_pkgset_hash() {
  printf '%s\n' \
    "${TARGET_BASE_PACKAGES[@]}" \
    "${HYPR_BUILD_PACKAGES[@]}" \
    "${LIVE_TOOL_PACKAGES[@]}" \
    "${HYPR_TOOLCHAIN_PACKAGES[@]}" \
    "${HYPR_BACKPORTS_PACKAGES[@]}" |
    sort | sha256sum | awk '{print $1}'
}

# True only when the pool was stamped with the CURRENT package-set hash. A
# missing stamp (a pre-stamp cache, or one populated before this guard existed)
# reads as stale, so it is repopulated rather than silently reused — that reuse
# was the "Unable to locate package" depsim failure this guard prevents.
cache_pkgset_fresh() {
  local stamp="${CACHE_DIR}/.pkgset.sha256"
  [[ -f "${stamp}" ]] || return 1
  [[ "$(cat "${stamp}")" == "$(cache_pkgset_hash)" ]]
}

# Configure apt (live env) to install from the cache repo only.
install_from_cache_repo() {
  local list="/etc/apt/sources.list.d/hypr-deb-cache.list"
  echo "deb [trusted=yes] file://${CACHE_REPO_DIR} ${SUITE} main" >"${list}"
  apt-get update -o Dir::Etc::sourcelist="${list}" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dir::Etc::sourcelist="${list}" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" "$@"
}

# Resolve the full .deb closure for all package sets using a throwaway
# bootstrap, then index the pool with apt-ftparchive. Network required.
cache_populate_debs() {
  local work="${CACHE_DIR}/.work" pool="${CACHE_DIR}/repo/pool"
  rm -rf "${work}"
  mkdir -p "${pool}" "${work}"

  # Shared debootstrap deb cache, set+exported by build-iso.sh. Referenced
  # DEFENSIVELY: when unset (any caller other than build-iso.sh) this expands to
  # empty and NO --cache-dir is passed.
  # For the build-iso path it points at the cache the buildroot debootstrap
  # already filled, so the closure debootstrap reuses the base instead of
  # re-downloading it. (The dedicated --download-only bootstrap pass that used
  # to run here is dropped: the buildroot debootstrap is now THE single base
  # download, and its base .debs are harvested into the pool by build-iso.sh.
  # The closure debootstrap below ALSO leaves the base in its archives, which
  # the cp -n harvest at the end of this function copies into the pool — so the
  # full base set still reaches the pool for the installer path too.)
  local -a cache_args=()
  if [[ -n "${DEBOOTSTRAP_CACHE:-}" ]]; then
    cache_args=(--cache-dir="${DEBOOTSTRAP_CACHE}")
  fi

  info "Resolving full package closure in a scratch chroot..."
  debootstrap "${cache_args[@]}" --arch="${ARCH}" "${SUITE}" "${work}/closure" "${MIRROR}"
  # The pinned sid source supplies gcc-15 (absent from trixie) and
  # trixie-backports supplies the Rust toolchain (cargo/rustc) for swww, so the
  # offline cache carries both toolchain sets too. The scoped allow-pins these
  # writers install let the toolchain resolve by NAME (no `-t`), so the closure
  # downloads exactly the versions the build will install (see install_build_deps
  # in 60-hyprland.sh): `-t` would override the pins and pull collateral sid/
  # backports upgrades (libmpfr6/libnghttp3-9/libngtcp2-16) the build never uses.
  write_sid_toolchain_sources "${work}/closure"
  write_backports_sources "${work}/closure"
  chroot "${work}/closure" /usr/bin/env bash -c "
    set -e
    echo 'deb ${MIRROR} ${SUITE} main contrib non-free-firmware' \
      > /etc/apt/sources.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only \
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_PACKAGES[*]} \
      ${LIVE_TOOL_PACKAGES[*]} grub-efi-amd64 grub-efi-amd64-signed \
      systemd-boot os-prober
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only \
      ${HYPR_TOOLCHAIN_PACKAGES[*]}
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only \
      ${HYPR_BACKPORTS_PACKAGES[*]}
  "
  cp -n "${work}/closure/var/cache/apt/archives/"*.deb "${pool}/"

  # NVIDIA drivers (Phase 5): resolve the full offline closure for BOTH flavors
  # (open + proprietary) and BOTH branches (595 + 610) into the same pool, so
  # the on-ISO /hypr-repo can install NVIDIA with no network. Runs only inside
  # this throwaway closure chroot (never touches the host). Trust comes from the
  # cuda-keyring deb; the deb822 source matches the flat (Suites: /) NVIDIA repo.
  # The two nvidia-driver-pinning-<branch> packages select the branch and share
  # /etc/apt/preferences.d/nvidia-driver-pin (they Conflict), so each branch is
  # installed, downloaded, then purged before switching. open and proprietary
  # are downloaded separately because nvidia-open Conflicts the proprietary
  # nvidia-kernel-dkms; the shared userspace overlaps and is deduped by cp -n.
  # CRITICAL: each --download-only resolution must be internally conflict-free.
  # We list ONLY the flavor metapackages + firmware + dkms build-deps and let
  # apt resolve the shared userspace itself. Force-listing the shared set
  # (nvidia-suspend-common, nvidia-kernel-common, ...) made apt refuse the
  # transaction: nvidia-driver Conflicts nvidia-suspend-common, and
  # nvidia-kernel-support (which nvidia-driver pulls) Conflicts nvidia-kernel-common.
  info "Resolving NVIDIA driver closure (open+proprietary, branches 595+610)..."
  chroot "${work}/closure" /usr/bin/env bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # Tools to fetch the keyring deb over HTTPS (minbase has neither).
    apt-get install -y --no-install-recommends ca-certificates curl
    # Establish trust: fetch + install cuda-keyring (drops the trusted key at
    # /usr/share/keyrings/cuda-archive-keyring.gpg). Stage the deb for the pool
    # so the target can dpkg -i it from /hypr-repo for offline trust.
    curl -fsSL --retry 3 '${NVIDIA_REPO_KEYRING_URL}' \
      -o /var/cache/apt/archives/cuda-keyring_1.1-1_all.deb
    dpkg -i /var/cache/apt/archives/cuda-keyring_1.1-1_all.deb
    # cuda-keyring also drops a flat-repo .list pointing at the HTTPS URL;
    # replace it with the signed deb822 source so there is a single NVIDIA
    # source (matches the install-time keyringSetup).
    rm -f /etc/apt/sources.list.d/cuda-debian13-x86_64.list
    cat > /etc/apt/sources.list.d/cuda-debian13.sources <<'SRC'
Types: deb
URIs: ${NVIDIA_REPO_URL}
Suites: /
Signed-By: /usr/share/keyrings/cuda-archive-keyring.gpg
SRC
    apt-get update
    for branch in 595 610; do
      pin=\"nvidia-driver-pinning-\${branch}\"
      # Activate the branch pin (installs preferences.d/nvidia-driver-pin) so
      # the branch-agnostic metapackages resolve to this branch; this also
      # downloads the pin deb itself into the pool.
      apt-get install -y \"\${pin}\"
      # Open flavor: nvidia-open drags in its open-flavor shared userspace.
      apt-get install -y --download-only \
        ${NVIDIA_OPEN_PACKAGES[*]} \
        ${NVIDIA_FIRMWARE_PACKAGES[*]} \
        ${NVIDIA_DKMS_BUILD_PACKAGES[*]} \
        linux-headers-amd64
      # Proprietary flavor: nvidia-driver pulls its own shared userspace
      # (nvidia-driver-libs/-cuda, nvidia-kernel-support, nvidia-powerd, ...).
      # Listing only the metapackages keeps this resolution conflict-free.
      apt-get install -y --download-only \
        ${NVIDIA_PROP_PACKAGES[*]} \
        ${NVIDIA_FIRMWARE_PACKAGES[*]} \
        ${NVIDIA_DKMS_BUILD_PACKAGES[*]} \
        linux-headers-amd64
      # Purge the pin before switching branches (the two pins Conflict).
      apt-get purge -y \"\${pin}\"
    done
  "
  cp -n "${work}/closure/var/cache/apt/archives/"*.deb "${pool}/"
  rm -rf "${work}"
  # Stamp the pool with the package-set hash so a later build reuses it only
  # while the sets are unchanged (cache_pkgset_fresh); adding/removing a package
  # now invalidates it and forces a repopulate instead of a stale reuse.
  cache_pkgset_hash >"${CACHE_DIR}/.pkgset.sha256"
  info "Pool populated: $(find "${pool}" -name '*.deb' | wc -l) packages"
}

# chezmoi (dotfile manager) is GitHub-only, not in Debian. Harvest its official
# .deb into the pool at BUILD time so the target apt-installs it OFFLINE by name
# (install_chezmoi, scripts/40-system.sh) — no GitHub fetch at install time. The
# build host is online. CHEZMOI_VERSION pins the release deterministically; empty
# resolves the latest tag (build-time only). resolve_latest_release_tag lives in
# scripts/60-hyprland.sh (sourced before any phase, and by tools/build-iso.sh).
# Idempotent: reuses an already-pooled deb so resumed builds skip the fetch.
cache_populate_chezmoi() {
  local pool="${CACHE_DIR}/repo/pool" ver="${CHEZMOI_VERSION:-}" tag="" url="" dest=""
  if [[ -z "${ver}" ]]; then
    tag="$(resolve_latest_release_tag "${CHEZMOI_REPO_URL}")"
    ver="${tag#v}"
  fi
  dest="${pool}/chezmoi_${ver}_amd64.deb"
  if [[ -f "${dest}" ]]; then
    info "reuse pooled chezmoi ${ver}"
    return 0
  fi
  url="${CHEZMOI_REPO_URL}/releases/download/v${ver}/chezmoi_${ver}_linux_amd64.deb"
  mkdir -p "${pool}"
  info "Harvesting chezmoi ${ver} into the pool (${url##*/})..."
  curl -fsSL --retry 3 -o "${dest}" "${url}" ||
    fatal "Failed to harvest chezmoi ${ver} into the pool (${url})."
}

# Brave (default browser) lives in Brave's own apt repo, not Debian's. Harvest
# the .deb + the archive keyring into the offline store at BUILD time so the
# target apt-installs it OFFLINE by name (install_brave, scripts/40-system.sh)
# and the installed system can track Brave's repo for updates. The repo's
# Packages index is the source of truth for the current stable version/path —
# parsed with awk over the deb822 stanzas (amd64 only; ARCH is amd64 through
# the whole build). BRAVE_VERSION pins deterministically; empty takes the
# index's newest. Idempotent: reuses an already-pooled deb of that version.
cache_populate_brave() {
  local pool="${CACHE_DIR}/repo/pool" ver="${BRAVE_VERSION:-}"
  local index="" filename="" dest="" keyring_dest="${CACHE_DIR}/repo/${BRAVE_KEYRING_NAME}"
  local kpkg_file="" kpkg_dest=""
  mkdir -p "${pool}"
  index="$(curl -fsSL --retry 3 \
    "${BRAVE_APT_BASE_URL}/dists/stable/main/binary-amd64/Packages")" ||
    fatal "Failed to fetch Brave's Packages index (${BRAVE_APT_BASE_URL})."
  # Pick the brave-browser stanza: pinned version if given, else highest.
  # sort -V, NOT string compare in awk — lexicographic breaks at 1.92 -> 1.100.
  filename="$(printf '%s\n' "${index}" | awk -v want="${ver}" '
    $1 == "Package:"  { pkg = $2 }
    $1 == "Version:"  { v = $2 }
    $1 == "Filename:" {
      if (pkg == "brave-browser" && (want == "" || v == want)) print v, $2
    }' | sort -V | tail -1 | cut -d' ' -f2)"
  [[ -n "${filename}" ]] ||
    fatal "brave-browser ${ver:-<latest>} not found in Brave's Packages index."
  # brave-browser Depends: brave-keyring (a real package, not just the .gpg
  # file) since 1.92 — without it in the pool, depsim's offline closure is
  # unsatisfiable. Always take the index's newest; it is versioned
  # independently of the browser.
  kpkg_file="$(printf '%s\n' "${index}" | awk '
    $1 == "Package:"  { pkg = $2 }
    $1 == "Version:"  { v = $2 }
    $1 == "Filename:" { if (pkg == "brave-keyring") print v, $2 }
    ' | sort -V | tail -1 | cut -d' ' -f2)"
  [[ -n "${kpkg_file}" ]] ||
    fatal "brave-keyring not found in Brave's Packages index."
  dest="${pool}/${filename##*/}"
  kpkg_dest="${pool}/${kpkg_file##*/}"
  if [[ -f "${dest}" && -f "${kpkg_dest}" && -f "${keyring_dest}" ]]; then
    info "reuse pooled ${dest##*/}"
    return 0
  fi
  info "Harvesting ${filename##*/} + ${kpkg_file##*/} into the pool..."
  curl -fsSL --retry 3 -o "${dest}" "${BRAVE_APT_BASE_URL}/${filename}" ||
    fatal "Failed to harvest brave-browser (${BRAVE_APT_BASE_URL}/${filename})."
  curl -fsSL --retry 3 -o "${kpkg_dest}" "${BRAVE_APT_BASE_URL}/${kpkg_file}" ||
    fatal "Failed to harvest brave-keyring (${BRAVE_APT_BASE_URL}/${kpkg_file})."
  curl -fsSL --retry 3 -o "${keyring_dest}" "${BRAVE_APT_BASE_URL}/${BRAVE_KEYRING_NAME}" ||
    fatal "Failed to harvest the Brave archive keyring."
}

cache_index_repo() {
  local repo="${CACHE_DIR}/repo"
  local bindir="dists/${SUITE}/main/binary-${ARCH}"
  mkdir -p "${repo}/${bindir}"
  (
    cd "${repo}" || fatal "Cannot cd to ${repo}"
    apt-ftparchive packages pool >"${bindir}/Packages"
    gzip -kf "${bindir}/Packages"
    apt-ftparchive \
      -o "APT::FTPArchive::Release::Suite=${SUITE}" \
      -o "APT::FTPArchive::Release::Components=main" \
      -o "APT::FTPArchive::Release::Architectures=${ARCH}" \
      release "dists/${SUITE}" >"dists/${SUITE}/Release"
  )
}

# Validate the offline apt repo that debootstrap and in-chroot apt consume.
# Checks CACHE_REPO_DIR — which defaults to ${CACHE_DIR}/repo but preflight
# redirects to the on-ISO store (ISO_MEDIUM_REPO) when booted from our offline
# ISO — so the SAME gate covers both the install-from-ISO path and the legacy
# install-populated-cache path. The repo IS the offline contract: it carries
# the debootstrap base, the prebuilt custom stack debs (HYPR_BUILD_ORDER), and
# the OpenZFS debs — the full closure apt resolves against. Source tarballs are
# BUILD-TIME artifacts (produced under CACHE_DIR at ISO creation, never shipped)
# so they are not validated here. The ZFSBootMenu EFI IS shipped inside the repo
# (zfsbootmenu.EFI, grafted to /hypr-repo) for offline --bootloader=zbm, but it
# is not an apt artifact, so install_zbm validates it, not this apt-repo gate.
cache_validate() {
  local problems=() pkg_index="" fname=""
  pkg_index="${CACHE_REPO_DIR}/dists/${SUITE}/main/binary-${ARCH}/Packages"

  [[ -f "${pkg_index}" ]] || problems+=("repo index missing: ${pkg_index}")
  [[ -f "${CACHE_REPO_DIR}/dists/${SUITE}/Release" ]] ||
    problems+=("repo Release file missing")
  if [[ -f "${pkg_index}" ]]; then
    while IFS= read -r fname; do
      [[ -f "${CACHE_REPO_DIR}/${fname}" ]] ||
        problems+=("deb missing from pool: ${fname}")
    done < <(awk '/^Filename: /{print $2}' "${pkg_index}")

    # Offline contract (Phase 5): the store MUST carry the NVIDIA driver debs
    # for both flavors and both branches plus the trust keyring — without them
    # the target cannot install NVIDIA offline. Assert the key packages are
    # indexed (their files are covered by the Filename check above).
    local want=""
    for want in cuda-keyring \
      "${NVIDIA_OPEN_PACKAGES[@]}" "${NVIDIA_PROP_PACKAGES[@]}" \
      "${NVIDIA_PINNING_PACKAGE[595]}" "${NVIDIA_PINNING_PACKAGE[610]}"; do
      grep -qx "Package: ${want}" "${pkg_index}" ||
        problems+=("NVIDIA driver deb missing from pool index: ${want}")
    done

    # chezmoi (GitHub-only dotfile manager) is harvested into the pool at build
    # time (cache_populate_chezmoi) on every populate path and installed offline
    # by name (install_chezmoi), so it must be indexed — assert it.
    grep -qx "Package: chezmoi" "${pkg_index}" ||
      problems+=("chezmoi deb missing from pool index")

    # Offline path installs the UPSTREAM OpenZFS debs by name from the pool
    # (install_zfs_offline); those are built into the pool ONLY by build-iso
    # (step_zfs). The online path builds zfs from source and the installer's own
    # self-populate cache never pools zfs, so assert the upstream debs ONLY when
    # this install will actually consume them from the store (offline).
    if ! ((NETWORK_AVAILABLE)); then
      for want in "${ZFS_UPSTREAM_PACKAGES[@]}"; do
        grep -qx "Package: ${want}" "${pkg_index}" ||
          problems+=("upstream OpenZFS deb missing from pool index: ${want}")
      done
    fi
  fi

  if ((${#problems[@]} > 0)); then
    local p=""
    for p in "${problems[@]}"; do warn "cache: ${p}"; done
    fatal "Cache validation failed (${#problems[@]} problem(s))."
  fi
  info "Cache repo valid: ${CACHE_REPO_DIR}"
}
