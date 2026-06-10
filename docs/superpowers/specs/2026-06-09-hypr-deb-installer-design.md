# Hypr-Deb Installer — Design

Date: 2026-06-09
Status: Approved pending user review

## Goal

A bash installer — a thin orchestrator `hypr-deb.sh` plus compartmentalized
function-specific modules — that installs Debian 13 (trixie) onto a
fixed three-disk workstation, makes it bootable (UEFI), and builds Hyprland
and its hyprwm dependencies from their latest release tags with verified
version compatibility. The result is complete only when both the bootable
Debian install and the Hyprland source build succeed and verify.

## Run Environment

- Runs on Linux as root. Primary host: a Debian live-ISO session. Secondary:
  an installed Debian system. The script detects which and self-bootstraps
  its own tool prerequisites (debootstrap, gdisk, mdadm, zfs-dkms/zfsutils,
  dosfstools, apt-ftparchive/apt-utils, git, build toolchain).
- Network is preferred but optional. With network: debootstrap from
  `MIRROR`, apt from network, git tags fetched live. Without network: all
  installation comes from a static local cache (see Cache). Offline
  live-preflight requires the cache to have been built against the same
  live-ISO kernel (zfs-dkms needs matching headers); this constraint is
  documented and checked.

## Target Disks

Preflight gates disk selection on `systemd-detect-virt`:

**Bare metal (`systemd-detect-virt` = `none`) — fixed, no exceptions:**

```
DISK1=/dev/disk/by-id/nvme-eui.0025384331408197
DISK2=/dev/disk/by-id/nvme-eui.002538433140818a
DISK3=/dev/disk/by-id/nvme-eui.002538433140819d
```

No auto-detection, no fallback list, no override path. Each path must exist,
be a `/dev/disk/by-id/` path, and resolve to an internal whole disk
(`lsblk` TYPE=disk, RM=0, HOTPLUG=0, TRAN!=usb), mirroring the validation in
the reference project `Hyprland-on-Debian13/scripts/10-storage-prep.sh`.

**VM test mode (any other `systemd-detect-virt` result) — auto-detected:**

VM disks (virtio etc.) carry no stable `nvme-eui` identity and change across
VM rebuilds, so the fixed paths can never match. In a VM the script instead
auto-detects targets: it enumerates internal whole disks (`vd*`/`sd*`/
`nvme*`, RM=0, TRAN!=usb), excludes the live/boot medium and any disk with
mounted filesystems, and requires **exactly three** candidates — fewer or
more is a hard `fatal` listing what was found, never a guess. Candidates are
assigned DISK1..3 in name order; a warning fires if the smallest disk lands
in a DISK1/DISK2 (EFI-carrying) role. `VM_DISK1/2/3` environment overrides
are honored in VM mode only. A loud banner states the active mode and the
disks to be destroyed; the destructive confirmation gate applies in both
modes.

## Storage Layout

Amended from the reference layout: `md/boot` is removed and the ESP grows to
2G so any of the three supported bootloaders fits with kernel copies.

```
DISK1/DISK2: EFI(2G) SWAP(4G) ZFS(rest)
DISK3:               SWAP(4G) ZFS(rest)

/dev/md/efi:  FAT32 RAID1 (metadata 1.0) — DISK1-part1 + DISK2-part1
/dev/md/swap: swap  RAID0 (metadata 1.2) — DISK1-part2 + DISK2-part2 + DISK3-part1
ZFS pool PRECISION: raidz1 — DISK1-part3 + DISK2-part3 + DISK3-part2
```

Partition type codes: EF00 (EFI), FD00 (RAID), BF00 (ZFS). Wipe sequence per
reference: destroy stale pool/arrays, zero md superblocks, `wipefs`,
`sgdisk --zap-all`, `blkdiscard`, partition, `partprobe`, wait for nodes.

ZFS pool `PRECISION` (ashift=12, autotrim, zstd, posixacl, xattr=sa,
normalization=formD, relatime, canmount=off/mountpoint=none at pool root)
with the reference dataset hierarchy: `ROOT/debian13` (bootfs), `home`,
`home/Downloads` (compression=off), `srv`, `var/cache`, `var/lib/docker`,
`var/log`, `var/tmp`. Kernels live in `/boot` **on the root dataset** (no
separate boot filesystem), so snapshots capture kernel + modules atomically.

This intentionally diverges from `precision-zfs-dr.sh` layout parity
(4 partitions -> 3 on DISK1/2); the divergence is called out in the README.

## Debian Install

- `debootstrap` of trixie/amd64, tracking the current 13.x point release
  (no hard pin to 13.5; mirrors only serve the current point release).
- Source: network `MIRROR` (default `http://deb.debian.org/debian`) when
  reachable, else the local `file://` cache repo. Decided automatically;
  `--offline` forces cache.
- Base configuration: fstab (md/efi on /boot/efi, md/swap), mdadm.conf,
  hostname, locale, timezone, NTP-synced clock in live env, sudo user
  (interactive password if not provided), NetworkManager, CPU microcode,
  zfs initramfs, `zpool set cachefile` + hostid handling.

## Cache (network-preferred, offline-complete)

- A `cache` phase (networked) populates `CACHE_DIR` with:
  - the full .deb closure for: live-preflight tools, debootstrap base,
    target base system, bootloader packages, Hyprland build dependencies,
    greetd + uwsm — indexed with `apt-ftparchive` into a valid local repo
    usable by both debootstrap and chroot apt via `file://`;
  - source archives of Hyprland and each hyprwm dependency at their
    resolved release tags;
  - the ZFSBootMenu release EFI binary.
- Offline runs validate the cache and fail with a precise list of anything
  missing.
- The complete cache is always copied into the target at
  `/var/cache/hypr-deb/` (with a README) so the installed system can
  rebuild or reinstall fully offline.

## Bootloader — one, user-chosen

`--bootloader=zbm|grub|systemd-boot`. Exactly one loader is installed, gets
the single NVRAM entry (`efibootmgr`, creation required to succeed), and is
verified. If the flag is omitted: interactive runs prompt with the three
choices; non-interactive/`--yes` runs fail fast requiring the flag.

- **zbm**: upstream ZFSBootMenu release EFI binary on the ESP; boots kernels
  directly from the pool; no kernel-sync hook.
- **grub**: `grub-efi-amd64` on the ESP, reading kernel copies from the ESP
  (never the pool — no ZFS feature restrictions).
- **systemd-boot**: `systemd-boot` package, loader entries pointing at ESP
  kernel copies.
- For grub/systemd-boot, a kernel postinst/initramfs hook syncs the current
  kernel + initramfs from `/boot` (ZFS) to the ESP. Documented caveat: after
  a root-dataset rollback the ESP copy is newer until the next hook run;
  only ZBM boots true point-in-time snapshots.

The storage layout is identical regardless of loader choice.

## Hyprland Stack — bare scope, source-built at release tags

Scope: Debian base + compiled Hyprland + greetd + uwsm. No waybar, no
NVIDIA, no extras. greetd config execs `uwsm start hyprland`; a minimal
valid `hyprland.conf` is installed for the user; greetd service enabled,
graphical target default.

Source policy:

- Resolve the **latest release tag** (semver-highest, not latest commit) of
  Hyprland via `git ls-remote --tags`, excluding pre-releases.
- Dependencies built from source, each at its own latest release tag:
  `hyprwayland-scanner`, `hyprutils`, `hyprlang`, `hyprcursor`,
  `hyprgraphics`, `hyprland-protocols`, `aquamarine`.
- **Compatibility gate:** parse Hyprland's CMake version requirements
  (`find_package`/`pkg_check_modules` minimums) at the resolved tag and
  assert each dependency's latest tag satisfies them. On any mismatch,
  abort with a full requirement-vs-resolved matrix. No silent downgrades.
- Build order: hyprwayland-scanner, hyprutils -> hyprlang, hyprcursor,
  hyprgraphics, hyprland-protocols, aquamarine -> Hyprland. CMake Release
  builds, install to `/usr/local`, `ldconfig`. Remaining build deps
  (wayland, libinput, libdrm, mesa, etc.) come from Debian 13 packages.

Build hygiene (clean install, lean target):

- Builds run inside the target environment (chroot or firstboot) so binaries
  link against exactly the userland that runs them; never in the live
  overlay (tmpfs/RAM) and never copied in from a foreign userland.
- Build trees and `DESTDIR` staging live under `/var/tmp` (own dataset,
  snapshot-excluded) and are deleted after install.
- The script records the exact build-dependency package set it installs;
  after a successful build + verify it purges that set
  (`apt-get purge` + `--autoremove`), leaving only Hyprland artifacts and
  their runtime libraries. `--keep-build-deps` skips the purge for users
  who intend to hack on Hyprland immediately.
- The cached build-dep .debs remain in `/var/cache/hypr-deb`, so the
  toolchain can be reinstalled offline whenever a rebuild is wanted.

Build timing (`--build-on-firstboot`):

- Default: build inside the target chroot during install; image boots ready.
- With the flag: stage sources + cached debs in the target and install a
  one-shot systemd unit that runs the identical build logic on first boot,
  disabling itself on success and leaving a clear failure log otherwise.

## Script Structure

`hypr-deb.sh` is a thin orchestrator: it sources the lib and phase modules,
parses arguments, and dispatches phases. All real work lives in
compartmentalized, function-specific modules, mirroring the reference
project's layout:

```
hypr-deb.sh                  orchestrator: source modules, parse args,
                             dispatch phases, top-level traps
lib/00-config.sh             defaults, fixed disk ids, derived values
lib/01-log.sh                info/verbose/fatal logging, tee'd log setup
lib/02-args.sh               usage, argument parsing, confirmation prompts
lib/03-state.sh              phase stamps, resume/--fresh handling
lib/04-chroot-mounts.sh      bind mount tracking and teardown
scripts/00-preflight.sh      host + virt detection, tool bootstrap,
                             disk selection/validation, clock sync
scripts/10-cache.sh          offline cache populate/validate, local repo
scripts/20-storage.sh        destroy/wipe/partition/mdadm/ZFS
scripts/30-bootstrap.sh      mount target, debootstrap, apt sources
scripts/40-system.sh         base Debian configuration
scripts/50-boot.sh           bootloader install (zbm/grub/systemd-boot),
                             NVRAM entry, kernel-sync hook
scripts/60-hyprland.sh       tag resolution, compatibility gate, builds,
                             firstboot staging, greetd/uwsm
scripts/90-verify.sh         verification suite
scripts/99-cleanup.sh        unmount binds, export pool
```

Modules are sourced (not executed); each contains functions for exactly one
concern. Bash strict mode in the orchestrator, Google Shell Style Guide
throughout. Conventions follow the reference project: `info`/`verbose`/
`fatal` logging, env-var-overridable config block, tee'd timestamped log,
destructive-action confirmation (`--yes` to skip).

Phases (resumable via state stamps; `--phase X` runs one; default runs all):

```
preflight   host + virt detection, tool bootstrap, disk selection/validation,
            clock sync
cache       populate/validate the offline cache (network required to populate)
storage     destroy/wipe/partition/mdadm/ZFS (destructive gate here)
bootstrap   mount target, debootstrap, bind mounts, apt sources
system      base Debian config (fstab, locale, user, network, initramfs)
boot        chosen bootloader install + NVRAM entry + kernel hook
hyprland    tag resolution, compatibility gate, builds (or firstboot staging)
verify      full verification suite
cleanup     unmount binds, export pool
```

Flags: `--bootloader=`, `--build-on-firstboot`, `--offline`, `--phase=`,
`--yes`, `--verbose`, `--fresh`, `--keep-build-deps`, `--mirror=`,
`--cache-dir=`, plus the
reference env overrides (`POOL_NAME`, `TARGET_HOSTNAME`, `USERNAME`,
`TIMEZONE`, `LOCALE`, sizes, ...).

Error handling: ERR trap reporting phase + failing command; EXIT trap always
tears down chroot binds, stops nothing it didn't start, and exports the pool
on failure paths; phases idempotent.

## Verification

In-chroot/target checks, all must pass for success:

- `Hyprland --version` executes; `ldd` on Hyprland and built libs resolves.
- greetd enabled; uwsm present; hyprland.conf parses (`hyprland --verify-config`
  if available at the built version, else presence + ownership checks).
- Chosen bootloader EFI binary present on ESP; NVRAM entry exists; kernel +
  initramfs present (pool `/boot`, plus ESP copies for grub/systemd-boot).
- fstab/mdadm.conf reference existing UUIDs; pool bootfs set; cache repo
  index in `/var/cache/hypr-deb` validates.
- First-boot mode: unit enabled, sources + debs staged and complete.

Final report printed; nonzero exit on any failure.

## Code Quality Gates (development-time)

- `bash -n` clean on every shell file (orchestrator, lib, scripts, tests).
- `shellcheck` clean (no suppressed findings without an inline justified
  directive) on every shell file.
- Google Shell Style Guide adherence unless technically impossible, without
  compromising targeted execution.

## Testing

- The `verify` phase is the runtime test.
- Recommended smoke test: QEMU/OVMF VM with three blank virtio disks
  (>=16G each) booted from a Debian live ISO; VM test mode auto-detects the
  disks, the full install runs end to end, then reboot into the chosen
  bootloader and confirm greetd login. Bare-metal validation is the
  post-install reboot on the real machine.
- Development: shellcheck + bash -n as above; optional focused unit checks
  in `tests/` following the reference project's fake-chroot pattern where
  practical (tag resolution, compatibility gate, cache validation are pure
  functions amenable to this).
