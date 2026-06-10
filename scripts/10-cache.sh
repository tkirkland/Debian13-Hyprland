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

cache_repo_exists() {
  [[ -f "${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages" ]]
}

# Configure apt (live env) to install from the cache repo only.
install_from_cache_repo() {
  local list="/etc/apt/sources.list.d/hypr-deb-cache.list"
  echo "deb [trusted=yes] file://${CACHE_DIR}/repo ${SUITE} main" >"${list}"
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

  info "Downloading debootstrap base packages..."
  debootstrap --download-only --arch="${ARCH}" "${SUITE}" \
    "${work}/bootstrap" "${MIRROR}"
  if compgen -G "${work}/bootstrap/var/cache/apt/archives/*.deb" >/dev/null; then
    cp -n "${work}/bootstrap/var/cache/apt/archives/"*.deb "${pool}/"
  fi

  info "Resolving full package closure in a scratch chroot..."
  debootstrap --arch="${ARCH}" "${SUITE}" "${work}/closure" "${MIRROR}"
  chroot "${work}/closure" /usr/bin/env bash -c "
    set -e
    echo 'deb ${MIRROR} ${SUITE} main contrib non-free-firmware' \
      > /etc/apt/sources.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only \
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_PACKAGES[*]} \
      ${LIVE_TOOL_PACKAGES[*]} grub-efi-amd64 systemd-boot
  "
  cp -n "${work}/closure/var/cache/apt/archives/"*.deb "${pool}/"
  rm -rf "${work}"
  info "Pool populated: $(find "${pool}" -name '*.deb' | wc -l) packages"
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

cache_populate_sources() {
  local name="" repo="" tag="" manifest="${CACHE_DIR}/sources/MANIFEST"
  mkdir -p "${CACHE_DIR}/sources"
  : >"${manifest}"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    repo="${HYPR_REPO_URL[${name}]}"
    tag="$(resolve_latest_release_tag "${repo}")"
    info "Caching ${name} ${tag}"
    curl -fsSL -o "${CACHE_DIR}/sources/${name}-${tag}.tar.gz" \
      "${repo}/archive/refs/tags/${tag}.tar.gz"
    echo "${name} ${tag}" >>"${manifest}"
  done
}

cache_populate_zbm() {
  info "Caching ZFSBootMenu EFI binary..."
  curl -fsSL -o "${CACHE_DIR}/zfsbootmenu.EFI" "${ZBM_EFI_URL}"
}

cache_validate() {
  local problems=() pkg_index="" fname="" name="" tag=""
  pkg_index="${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages"

  [[ -f "${pkg_index}" ]] || problems+=("repo index missing: ${pkg_index}")
  [[ -f "${CACHE_DIR}/repo/dists/${SUITE}/Release" ]] ||
    problems+=("repo Release file missing")
  if [[ -f "${pkg_index}" ]]; then
    while IFS= read -r fname; do
      [[ -f "${CACHE_DIR}/repo/${fname}" ]] ||
        problems+=("deb missing from pool: ${fname}")
    done < <(awk '/^Filename: /{print $2}' "${pkg_index}")
  fi

  if [[ -f "${CACHE_DIR}/sources/MANIFEST" ]]; then
    while read -r name tag; do
      [[ -f "${CACHE_DIR}/sources/${name}-${tag}.tar.gz" ]] ||
        problems+=("source tarball missing: ${name}-${tag}.tar.gz")
    done <"${CACHE_DIR}/sources/MANIFEST"
  else
    problems+=("sources manifest missing: ${CACHE_DIR}/sources/MANIFEST")
  fi

  [[ -f "${CACHE_DIR}/zfsbootmenu.EFI" ]] ||
    problems+=("zfsbootmenu.EFI missing")

  if ((${#problems[@]} > 0)); then
    local p=""
    for p in "${problems[@]}"; do warn "cache: ${p}"; done
    fatal "Cache validation failed (${#problems[@]} problem(s))."
  fi
  info "Cache valid: ${CACHE_DIR}"
}

phase_cache() {
  if ((NETWORK_AVAILABLE)); then
    cache_populate_debs
    cache_index_repo
    cache_populate_sources
    cache_populate_zbm
  else
    info "No network: validating existing cache instead of populating."
  fi
  cache_validate
}
