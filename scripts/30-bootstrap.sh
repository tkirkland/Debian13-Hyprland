# shellcheck shell=bash
# Bootstrap: mount the target tree, debootstrap Debian (network or the on-ISO
# repo), write the permanent Debian apt sources, and — offline — bind-mount
# the on-ISO package store into the target with a temporary file:// apt source
# so in-chroot apt resolves the offline packages during the install.

# In-target path where the on-ISO package store is bind-mounted so apt's
# file:// source resolves inside the chroot. Fixed (not derived from
# CACHE_REPO_DIR) so the temporary deb822 source URI is stable, and so
# teardown can find the mount without extra state.
TARGET_ISO_REPO_MNT="/run/hypr-repo"
# Target-relative path of the temporary offline apt source (removed at cleanup).
ISO_TEMP_SOURCE_REL="etc/apt/sources.list.d/hypr-iso-temp.sources"

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
  # Resumed runs reach here with the tree already mounted by
  # ensure_target_ready (zfs mount refuses a second mount, killing the
  # run under set -e), so every mount is guarded. zfs mount -a is
  # natively idempotent.
  if ! mountpoint -q "${TARGET}"; then
    zfs mount "${ROOT_DATASET}"
  fi
  zfs mount -a
  mkdir -p "${TARGET}${ESP_MOUNT}"
  mountpoint -q "${TARGET}${ESP_MOUNT}" ||
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
    info "debootstrap ${SUITE} from the on-ISO repo (${CACHE_REPO_DIR})..."
    debootstrap --no-check-gpg --arch="${ARCH}" "${SUITE}" "${TARGET}" \
      "file://${CACHE_REPO_DIR}"
  fi
}

# The PERMANENT apt sources of the installed system are always the real Debian
# mirror (via write_debian_sources, shared with the live environment) so future
# online `apt update`s work. The on-ISO package store is ISO-ONLY and is never
# embedded in the target; offline installs resolve their packages through the
# TEMPORARY file:// source set up by setup_target_iso_repo. /etc/apt/sources.list
# is reduced to a pointer comment by write_debian_sources so debootstrap's
# one-line entries never linger.
write_target_apt_sources() {
  local apt_dir="${TARGET}/etc/apt"
  mkdir -p "${apt_dir}/sources.list.d"
  rm -f "${apt_dir}/sources.list.d/debian.sources" \
    "${apt_dir}/sources.list.d/hypr-deb-cache.sources"
  write_debian_sources "${TARGET}"
}

# Offline only: bind-mount the on-ISO package store into the target (at the
# fixed TARGET_ISO_REPO_MNT, under the already-bound /run) and write a TEMPORARY
# trusted file:// apt source so in-chroot apt resolves the offline packages
# during the install. Both are removed by teardown_target_iso_repo at cleanup.
# Requires mount_chroot_binds to have run first (the store is bound under /run).
setup_target_iso_repo() {
  local mnt="${TARGET}${TARGET_ISO_REPO_MNT}"
  mkdir -p "${mnt}"
  if ! mountpoint -q "${mnt}"; then
    mount --bind "${CACHE_REPO_DIR}" "${mnt}" ||
      fatal "Failed to bind-mount ${CACHE_REPO_DIR} into ${mnt}"
  fi
  write_iso_temp_source
}

# Write the temporary trusted file:// apt source pointing at the in-target
# bind path. Split out so it is testable without the (root-only) bind mount.
write_iso_temp_source() {
  local src="${TARGET}/${ISO_TEMP_SOURCE_REL}"
  mkdir -p "$(dirname "${src}")"
  cat >"${src}" <<EOF
Types: deb
URIs: file://${TARGET_ISO_REPO_MNT}
Suites: ${SUITE}
Components: main
Trusted: yes
EOF
}

# Idempotent teardown of the offline install repo: remove the temporary source
# file and unmount the bind. Safe on the normal path and on failure — it checks
# the mountpoint before unmounting and rm -f tolerates an absent file.
teardown_target_iso_repo() {
  rm -f "${TARGET}/${ISO_TEMP_SOURCE_REL}"
  local mnt="${TARGET}${TARGET_ISO_REPO_MNT}"
  if mountpoint -q "${mnt}" 2>/dev/null; then
    umount "${mnt}" || umount -l "${mnt}" || warn "Could not unmount ${mnt}"
  fi
}

# Forbid every service start inside the install chroot: maintainer
# scripts otherwise launch daemons (zfs-zed, dbus, ...) whose processes
# hold the target mounts and break unmount/export at teardown. The
# canonical mechanism is /usr/sbin/policy-rc.d exiting 101, honored by
# invoke-rc.d and deb-systemd-invoke. Removed by phase_cleanup; it stays
# in place across resumes on purpose so every apt run is covered.
install_policy_rc_d() {
  install -d "${TARGET}/usr/sbin"
  cat >"${TARGET}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
# Managed by hypr-deb: forbid service starts inside the install chroot.
# Removed by the installer's cleanup phase.
exit 101
EOF
  chmod 755 "${TARGET}/usr/sbin/policy-rc.d"
}

phase_bootstrap() {
  mount_target_tree
  run_debootstrap
  install_policy_rc_d
  mount_chroot_binds
  # Offline: stand up the temporary file:// store source (+ bind) BEFORE writing
  # the permanent Debian sources, so the in-chroot apt-get update below indexes
  # the on-ISO packages. The unreachable Debian mirror is only warned about by
  # apt (exit 0); the installed system keeps it as its permanent source.
  if ((NETWORK_AVAILABLE == 0)); then
    setup_target_iso_repo
  fi
  write_target_apt_sources
  in_target "apt-get update"
}
