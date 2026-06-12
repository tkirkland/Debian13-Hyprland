# Forced Install-Time OpenZFS Build — Design

**Date:** 2026-06-12
**Supersedes:** the "Hybrid ZFS delivery" section of
`2026-06-12-secureboot-design.md`
**Status:** Approved

## Problem

The hybrid design deferred the upstream OpenZFS build to a firstboot job on
the belief that dkms signing required the MOK key to be enrolled first. That
is wrong: signing and enrollment are independent. The key exists at install
time (phase 40 generates it before packages), dkms signs modules in the
chroot, and MokManager enrollment at first boot merely makes the firmware
trust the already-signed modules — and only matters when secure boot is
actually on. Meanwhile the hybrid flow was gated behind `--zfs-from-source`,
which contradicted the intent that the upgrade be forced; real installs
booted straight to the greeter with repo 2.3.x and no staged job.

## Decisions

- **Forced**: every networked install builds upstream's latest OpenZFS
  release in the chroot and installs it — no flag. (`--zfs-from-source`
  is removed.)
- **Offline installs keep repo 2.3.x** with a warning (the cache does not
  carry the zfs source tree; unchanged limitation).
- **No firstboot ZFS job.** The per-job firstboot runner stays (used by
  `--build-on-firstboot` and future NVIDIA work); the `30-zfs-upgrade.sh`
  job and its staging are removed.
- **Boot flow**: SB off → no MokManager, signed modules load unverified;
  SB on → shim shows MokManager at first boot, user enrolls once,
  already-signed modules verify. No path requires a build after install.

## Components

1. **lib/00-config.sh** — restore `ZFS_DEBIAN_PACKAGES` (the repo packages
   the upstream build replaces); drop `ZFS_FROM_SOURCE`; refresh the
   comment block to the forced semantics.
2. **scripts/40-system.sh** — `install_base_packages` filters
   `ZFS_DEBIAN_PACKAGES` out when the network is available (upstream
   replaces them; installing first is churn) and calls
   `install_zfs_from_source` after; offline, repo zfs installs and a
   warning explains 2.3.x is kept. `install_zfs_from_source` is the
   pre-hybrid in-chroot build (GitHub-API tag resolve with ls-remote
   fallback, shallow clone, `make native-deb-utils`, per-package deb
   assertions, deb filter, pam_zfs_key purge) plus
   `apt-mark manual ${ZFS_BUILD_PACKAGES[*]}` — dkms rebuilds the module
   on every kernel update, so the toolchain must survive autoremove.
   `stage_zfs_upgrade_job`/`write_zfs_upgrade_job` are deleted.
3. **scripts/60-hyprland.sh** — `purge_build_deps` keeps filtering
   `ZFS_BUILD_PACKAGES` (now unconditional); the staged hyprland firstboot
   job drops its `ZFS_FROM_SOURCE=` line.
4. **lib/02-args.sh** — remove the `--zfs-from-source` flag and usage text.
5. **scripts/90-verify.sh** — replace the three job-staging vchecks with
   `dpkg -s openzfs-zfsutils` when the install was networked; drop the
   ZFS_FROM_SOURCE first-boot notice.
6. **Tests** — `tests/secureboot.sh` zfs section, `tests/system-fstab.sh`,
   and `tests/args.sh` updated to the forced semantics.
7. **README** — flag removed from docs; behavior described under the
   install flow.

## Out of scope

- Hosting prebuilt openzfs debs (dkms compiles per-kernel by design).
- The hyprland.lua upstream-example rework (separate effort).
