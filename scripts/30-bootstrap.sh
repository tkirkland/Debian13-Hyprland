# shellcheck shell=bash
# Deploy (issue #111): mount the target tree, unpack the golden rootfs — the
# SAME squashfs the live session booted — onto the pool, and bind-mount the
# medium's NVIDIA install store into the target with a temporary file:// apt
# source so the customize phase's driver transaction resolves offline.

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
# dataset-mount guards below ask ZFS itself whether the ROOT dataset is
# mounted, NOT bare `mountpoint -q` (which the self-bind would satisfy
# spuriously) and NOT findmnt FSTYPE (with the self-bind under the dataset,
# findmnt returns BOTH stacked mounts — multi-line — so the ==zfs test failed
# on every second maintenance run in one live session, issue #50).
# release_target_propagation removes the self-bind at cleanup and on the
# failure path.
root_dataset_mounted() {
  [[ "$(zfs get -H -o value mounted "${ROOT_DATASET}" 2>/dev/null)" == yes ]]
}

isolate_target_propagation() {
  # Root dataset already mounted -> isolation happened on its original mount; a
  # late make-private cannot retract copies, so this is correctly a no-op.
  root_dataset_mounted && return 0
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
  root_dataset_mounted && return 0
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
  if ! root_dataset_mounted; then
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
    if ! zpool import -N -R "${TARGET}" "${POOL_NAME}" 2>/dev/null; then
      # Pool nowhere to be found -> fresh install before storage; a no-op.
      zpool import 2>/dev/null | grep -qE "^\s*pool: ${POOL_NAME}\$" || return 0
      # The pool exists but refused a plain import. Routine on maintenance
      # runs (issue #50): a root pool is never exported at shutdown, so once
      # the installed system has booted, the live env's hostid no longer
      # matches and import demands -f. The disks are this machine's own
      # (preflight validated them), so force it; failing silently here used
      # to surface as a misleading "No kernel found in ${TARGET}/boot".
      info "Pool ${POOL_NAME} was last active on another hostid; importing with -f."
      zpool import -f -N -R "${TARGET}" "${POOL_NAME}" ||
        fatal "Pool ${POOL_NAME} exists but cannot be imported (see error above)."
    fi
  fi
  isolate_target_propagation
  if ! root_dataset_mounted; then
    zfs mount "${ROOT_DATASET}"
    zfs mount -a
  fi
  if [[ -b /dev/md/efi ]]; then
    mountpoint -q "${TARGET}${ESP_MOUNT}" ||
      mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
  else
    warn "/dev/md/efi absent; ESP not mounted (assemble the array first if a phase needs it)."
  fi
  # Always (re)ensure the chroot binds — mount_chroot_binds is idempotent
  # (each mount is mountpoint-guarded). The old `mountpoint -q ${TARGET}/proc ||`
  # gate skipped ALL binds whenever /proc happened to be mounted, which on a
  # standalone `--phase=boot` or a resumed run left the efivars bind absent and
  # made `chroot mokutil --import` fail even though the live host had efivars.
  mount_chroot_binds
}

# Echo the path of the golden squashfs on the live medium. LIVE_SQUASHFS
# overrides for tests / exotic media. The stock boot layout ships it at
# /live/filesystem.squashfs; tolerate a renamed single squashfs (Debian point
# releases have moved names before), but refuse ambiguity — two squashfs on
# one medium means the layout drifted and guessing installs the wrong root.
locate_live_squashfs() {
  if [[ -n "${LIVE_SQUASHFS:-}" ]]; then
    [[ -f "${LIVE_SQUASHFS}" ]] ||
      { warn "LIVE_SQUASHFS set but missing: ${LIVE_SQUASHFS}"; return 1; }
    printf '%s\n' "${LIVE_SQUASHFS}"
    return 0
  fi
  # set-u-safe: test contexts may source this file without lib/00-config.sh.
  local live_dir="${LIVE_MEDIUM_DIR:-/run/live/medium}/live" found=()
  if [[ -f "${live_dir}/filesystem.squashfs" ]]; then
    printf '%s\n' "${live_dir}/filesystem.squashfs"
    return 0
  fi
  mapfile -t found < <(compgen -G "${live_dir}/*.squashfs" || true)
  if ((${#found[@]} == 1)); then
    printf '%s\n' "${found[0]}"
    return 0
  fi
  warn "No unambiguous squashfs under ${live_dir} (found ${#found[@]})."
  return 1
}

# Unpack the PRISTINE golden image (from the medium, not the running live
# overlay — the overlay carries live-boot's mutations) onto the mounted
# target tree. unsquashfs writes through the mounted dataset mountpoints and
# preserves ownership/xattrs (running as root); -f makes a resumed deploy
# overwrite a half-unpacked tree instead of aborting on existing files. The
# golden /boot/efi is asserted empty at build time, so the mounted ESP is
# never written.
unpack_golden_rootfs() {
  local sqfs=""
  sqfs="$(locate_live_squashfs)" ||
    fatal "Golden rootfs squashfs not found on the live medium" \
      "(${LIVE_MEDIUM_DIR:-/run/live/medium}/live). Booted from something other" \
      "than the hypr-deb ISO? Set LIVE_SQUASHFS=/path/to/filesystem.squashfs to override."
  info "Unpacking golden rootfs ${sqfs##*/} onto ${TARGET}..."
  unsquashfs -f -no-progress -d "${TARGET}" "${sqfs}" >/dev/null ||
    fatal "unsquashfs of ${sqfs} onto ${TARGET} failed."
  # Sanity: the tree must be the complete baked system, not a partial write.
  [[ -f "${TARGET}/etc/debian_version" && -x "${TARGET}/usr/bin/Hyprland" ]] ||
    fatal "Unpacked tree at ${TARGET} is not the golden image" \
      "(missing /etc/debian_version or /usr/bin/Hyprland)."
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
  # The store must actually exist before we bind it: /run/live/medium can
  # vanish between preflight and here (medium unmounted mid-install). Without
  # this guard, `mount --bind` of a missing source dies with a cryptic kernel
  # "special device ... does not exist".
  if [[ ! -d "${CACHE_REPO_DIR}" ||
    ! -f "${CACHE_REPO_DIR}/dists/${SUITE}/main/binary-${ARCH}/Packages" ]]; then
    fatal "Install store missing or incomplete at ${CACHE_REPO_DIR}" \
      "(no dists/${SUITE}/main/binary-${ARCH}/Packages). The live medium" \
      "(${LIVE_MEDIUM_DIR:-/run/live/medium}) may have been unmounted since" \
      "preflight; re-mount it and re-run."
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

phase_deploy() {
  mount_target_tree
  # The medium NVIDIA store is the customize phase's only package source;
  # gate on it BEFORE the (long) unpack so a yanked/failed medium dies fast.
  cache_validate
  unpack_golden_rootfs
  # The image ships the permanent Debian mirror sources baked in
  # (step_finalize_golden). The install itself runs STORE-ONLY: on a
  # networked machine the reachable mirror would outbid the store's NVIDIA
  # candidates in the customize transaction (the issue #110 failure mode).
  # phase_cleanup rewrites the permanent sources after the last transaction.
  rm -f "${TARGET}/etc/apt/sources.list.d/debian.sources"
  install_policy_rc_d
  mount_chroot_binds
  setup_target_iso_repo
  in_target "apt-get update"
}
