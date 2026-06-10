# shellcheck shell=bash
# Bootstrap: mount the target tree, debootstrap Debian (network or cache),
# embed the cache, write apt sources, establish chroot binds.

mount_target_tree() {
  info "Mounting target tree at ${TARGET}..."
  mkdir -p "${TARGET}"
  # The pool may have been exported by the failure trap (or never imported
  # in a standalone --phase=bootstrap re-run); import without mounting so
  # the root dataset mounts first, below.
  if ! zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool import -N -R "${TARGET}" "${POOL_NAME}" ||
      fatal "Pool ${POOL_NAME} not imported and import failed."
  fi
  zfs mount "${ROOT_DATASET}"
  zfs mount -a
  mkdir -p "${TARGET}${ESP_MOUNT}"
  mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
}

# After a failure trap (which unmounts and exports) a resumed run skips the
# stamped bootstrap phase, so the target tree and chroot binds must be
# re-established before any later phase touches the target.
ensure_target_ready() {
  phase_done bootstrap || return 0
  # -N: never automount on import — canmount=on children mounting before
  # the noauto root dataset would be shadowed by the root overlay-mount.
  if ! zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool import -N -R "${TARGET}" "${POOL_NAME}" ||
      fatal "Cannot import pool ${POOL_NAME} to resume."
  fi
  if ! mountpoint -q "${TARGET}"; then
    zfs mount "${ROOT_DATASET}"
    zfs mount -a
  fi
  mountpoint -q "${TARGET}${ESP_MOUNT}" ||
    mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
  mountpoint -q "${TARGET}/proc" || mount_chroot_binds
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
repo/     local apt repository; deb822 stanza to use it:
            Types: deb
            URIs: file://${TARGET_CACHE_DIR}/repo
            Suites: ${SUITE}
            Components: main
            Trusted: yes
sources/  hyprwm source tag archives + MANIFEST of resolved release tags
zfsbootmenu.EFI  cached ZFSBootMenu release binary
EOF
}

# Target apt sources are written in deb822 format under
# /etc/apt/sources.list.d/ with every component enabled;
# /etc/apt/sources.list is reduced to a pointer comment so the
# debootstrap-generated one-line entries never linger.
write_target_apt_sources() {
  local apt_dir="${TARGET}/etc/apt"
  local components="main contrib non-free non-free-firmware"
  mkdir -p "${apt_dir}/sources.list.d"
  rm -f "${apt_dir}/sources.list.d/debian.sources" \
    "${apt_dir}/sources.list.d/hypr-deb-cache.sources"
  cat >"${apt_dir}/sources.list" <<'EOF'
# Managed by hypr-deb.sh: apt sources live in deb822 format under
# /etc/apt/sources.list.d/.
EOF
  if ((NETWORK_AVAILABLE)); then
    cat >"${apt_dir}/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: ${MIRROR}
Suites: ${SUITE} ${SUITE}-updates
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${SUITE}-security
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  else
    cat >"${apt_dir}/sources.list.d/hypr-deb-cache.sources" <<EOF
Types: deb
URIs: file://${TARGET_CACHE_DIR}/repo
Suites: ${SUITE}
Components: main
Trusted: yes
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
