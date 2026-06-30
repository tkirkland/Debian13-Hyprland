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

# --- Mount-propagation isolation (so `zpool export` does not fail "pool busy") -
# ${TARGET}'s parent (/) is a `shared` mount, so when ZFS mounts the pool's
# datasets under altroot=${TARGET} each mount(2) propagates into the private
# mount namespaces systemd clones for sandboxed services (systemd-udevd has
# PrivateMounts=yes, systemd-logind has ProtectSystem=strict). Those service-ns
# copies independently pin the datasets, so the global `zfs unmount -a` +
# `zpool export -f` at cleanup leave the pool busy and the export fails.
#
# Pin ${TARGET} into a PRIVATE mount subtree BEFORE any dataset mounts onto it:
# a self-bind makes ${TARGET} its own mount, make-private severs it from /'s
# shared peer group, and the root dataset (plus its children, via zfs mount -a)
# then stacks INSIDE the private subtree and never propagates out. This is the
# dataset->service-ns counterpart of the host->target make-rslave in
# mount_chroot_binds (lib/04-chroot-mounts.sh): opposite propagation directions,
# and they nest correctly.
#
# Because the self-bind makes ${TARGET} a mountpoint before any ZFS mount, the
# dataset-mount guards below test FSTYPE==zfs (is the ROOT dataset mounted?),
# NOT bare `mountpoint -q` (which the self-bind would satisfy spuriously and so
# wrongly skip the dataset mount). release_target_propagation removes the
# self-bind at cleanup and on the failure path.
isolate_target_propagation() {
  # Root dataset already mounted -> isolation happened on its original mount; a
  # late make-private cannot retract copies, so this is correctly a no-op.
  [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" == zfs ]] && return 0
  # ${TARGET} must exist before the self-bind: ensure_target_ready imports the
  # pool with -N (no mount) and never mkdir's it (the dataset mount used to
  # create it), so create it here to be self-sufficient regardless of caller.
  mkdir -p "${TARGET}"
  mountpoint -q "${TARGET}" || mount --bind "${TARGET}" "${TARGET}" ||
    fatal "Failed to self-bind ${TARGET} for mount-propagation isolation."
  mount --make-private "${TARGET}" ||
    fatal "Failed to make ${TARGET} a private mount subtree."
}

# Remove the propagation-isolation self-bind. Run after the datasets are
# zfs-unmounted and the pool exported. No-op unless only the bare self-bind
# remains: it never unmounts a live ZFS ${TARGET}.
release_target_propagation() {
  [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" == zfs ]] && return 0
  mountpoint -q "${TARGET}" 2>/dev/null || return 0
  umount "${TARGET}" 2>/dev/null || umount -l "${TARGET}" 2>/dev/null ||
    warn "Could not remove ${TARGET} propagation self-bind."
}

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
  # natively idempotent. Isolate propagation BEFORE the root dataset mounts.
  isolate_target_propagation
  if [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" != zfs ]]; then
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
  isolate_target_propagation
  if [[ "$(findmnt -no FSTYPE "${TARGET}" 2>/dev/null)" != zfs ]]; then
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
  # The offline store must actually exist before we bind it. On a resumed run
  # the "already bootstrapped" short-circuit in run_debootstrap returns early
  # and never reaches cache_validate, so this is the ONLY guard against a
  # vanished store -- e.g. /run/live/medium got unmounted after preflight set
  # CACHE_REPO_DIR to the on-ISO repo. Without it, `mount --bind` of a missing
  # source dies with a cryptic kernel "special device ... does not exist".
  if [[ ! -d "${CACHE_REPO_DIR}" ||
    ! -f "${CACHE_REPO_DIR}/dists/${SUITE}/main/binary-${ARCH}/Packages" ]]; then
    fatal "Offline package store missing or incomplete at ${CACHE_REPO_DIR}" \
      "(no dists/${SUITE}/main/binary-${ARCH}/Packages). The live medium" \
      "(/run/live/medium) may have been unmounted since preflight; re-mount it" \
      "and re-run, or pass --online to install from the network."
  fi
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
