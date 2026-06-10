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

# Ready the target whenever its pool exists (already imported, or
# importable). Resumed runs AND post-reboot --phase=X maintenance both
# depend on this; phase stamps do not survive live-session reboots, so the
# pool itself — not a stamp — is the signal. No-op when the pool is absent
# (fresh install before the storage phase).
ensure_target_ready() {
  if ! zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    # -N: never automount on import — canmount=on children mounting before
    # the noauto root dataset would be shadowed by the root overlay-mount.
    zpool import -N -R "${TARGET}" "${POOL_NAME}" 2>/dev/null || return 0
  fi
  if ! mountpoint -q "${TARGET}"; then
    zfs mount "${ROOT_DATASET}"
    zfs mount -a
  fi
  if [[ -b /dev/md/efi ]]; then
    mountpoint -q "${TARGET}${ESP_MOUNT}" ||
      mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
  else
    warn "/dev/md/efi absent; ESP not mounted (assemble the array first if a phase needs it)."
  fi
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
  if ((SKIP_CACHE)); then
    info "--skip-cache: not embedding an offline cache in the target."
    return 0
  fi
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
# /etc/apt/sources.list.d/ (components from DEBIAN_COMPONENTS, shared with
# the live environment via write_debian_sources); /etc/apt/sources.list is
# reduced to a pointer comment so debootstrap's one-line entries never
# linger.
write_target_apt_sources() {
  local apt_dir="${TARGET}/etc/apt"
  mkdir -p "${apt_dir}/sources.list.d"
  rm -f "${apt_dir}/sources.list.d/debian.sources" \
    "${apt_dir}/sources.list.d/hypr-deb-cache.sources"
  if ((NETWORK_AVAILABLE)); then
    write_debian_sources "${TARGET}"
  else
    cat >"${apt_dir}/sources.list" <<'EOF'
# Managed by hypr-deb: APT sources are defined in
# /etc/apt/sources.list.d/.
EOF
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
