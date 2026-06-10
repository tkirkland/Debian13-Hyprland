# shellcheck shell=bash
# Bootstrap: mount the target tree, debootstrap Debian (network or cache),
# embed the cache, write apt sources, establish chroot binds.

mount_target_tree() {
  info "Mounting target tree at ${TARGET}..."
  mkdir -p "${TARGET}"
  zfs mount "${ROOT_DATASET}"
  zfs mount -a
  mkdir -p "${TARGET}${ESP_MOUNT}"
  mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
}

run_debootstrap() {
  if [[ -f "${TARGET}/etc/debian_version" ]]; then
    info "Target already bootstrapped; skipping debootstrap."
    return 0
  fi
  if ((NETWORK_AVAILABLE)); then
    info "debootstrap ${SUITE} from ${MIRROR}..."
    debootstrap --arch="${ARCH}" "${SUITE}" "${TARGET}" "${MIRROR}"
  else
    cache_validate
    info "debootstrap ${SUITE} from offline cache..."
    debootstrap --no-check-gpg --arch="${ARCH}" "${SUITE}" "${TARGET}" \
      "file://${CACHE_DIR}/repo"
  fi
}

# The complete cache is always embedded so the installed system can rebuild
# or reinstall fully offline (spec: Cache section).
embed_cache_in_target() {
  [[ -d "${CACHE_DIR}/repo" ]] || {
    warn "No cache at ${CACHE_DIR}; target will not carry an offline cache."
    return 0
  }
  info "Embedding cache into ${TARGET}${TARGET_CACHE_DIR}..."
  mkdir -p "${TARGET}${TARGET_CACHE_DIR}"
  rsync -a "${CACHE_DIR}/" "${TARGET}${TARGET_CACHE_DIR}/"
  cat >"${TARGET}${TARGET_CACHE_DIR}/README" <<EOF
Hypr-Deb offline cache.
repo/     local apt repository (deb [trusted=yes] file://${TARGET_CACHE_DIR}/repo ${SUITE} main)
sources/  hyprwm source tag archives + MANIFEST of resolved release tags
zfsbootmenu.EFI  cached ZFSBootMenu release binary
EOF
}

write_target_apt_sources() {
  if ((NETWORK_AVAILABLE)); then
    cat >"${TARGET}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF
  else
    cat >"${TARGET}/etc/apt/sources.list" <<EOF
deb [trusted=yes] file://${TARGET_CACHE_DIR}/repo ${SUITE} main
EOF
  fi
}

phase_bootstrap() {
  mount_target_tree
  run_debootstrap
  embed_cache_in_target
  write_target_apt_sources
  mount_chroot_binds
  in_target "apt-get update"
}
