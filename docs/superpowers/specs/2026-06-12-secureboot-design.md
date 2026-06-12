# Secure Boot Support — Design

**Date:** 2026-06-12
**Issue:** [#3](https://github.com/tkirkland/Debian13-Hyprland/issues/3) — Add mokutil into the installer so user can enable secure boot
**Status:** Approved

## Problem

The installer builds ZFS modules via DKMS (signed automatically with the dkms MOK
key on Debian) but never enrolls that key in firmware, and two of the three
supported bootloaders (ZFSBootMenu, systemd-boot) install unsigned EFI binaries.
Enabling secure boot after install therefore produces an unbootable system.

## Goal

Every install is secure-boot ready out of the box, for all three bootloaders.
The model mirrors stock Debian: Debian signs what Debian ships (shim, GRUB,
kernel); the installer MOK-signs what it builds (ZBM/systemd-boot binaries,
DKMS modules) and stages MOK enrollment so the user confirms it once at first
boot. Always on — no opt-in flag. Secure boot disabled in firmware costs
nothing; everything still boots normally.

## Decisions

- **Scope:** all three loaders (zbm, grub, systemd-boot).
- **Always on**, no `--secureboot` flag.
- **MOK password = the user account password** (already collected; works
  unattended via `USER_PASSWORD`).
- **One key for everything:** reuse the Debian dkms MOK keypair
  (`/var/lib/dkms/mok.key` / `mok.pub`) for both module signing (dkms does this
  automatically) and EFI binary signing (sbsign).
- **Preflight is fatal if secure boot is already enforcing in the live
  environment** — the live session must load its own unsigned ZFS dkms module
  to build the pool, which a lockdown kernel refuses. Fail loudly with an
  explanation telling the user to disable secure boot, install, then re-enable
  it after first boot (MokManager enrollment makes it safe to do so).
- **Hybrid ZFS delivery:** the install itself uses Debian repo `zfs-dkms`
  (2.3.x — fast, no source build, dkms-signed in chroot); the newer OpenZFS
  release (e.g. 2.4.2) is compiled, signed, and activated at **first boot**
  via the existing firstboot runner, after MOK enrollment has already
  happened at the MokManager screen. The slow build leaves the install path,
  and signing works because the key is enrolled by build time.

## Components

### 1. Preflight (scripts/00-preflight.sh)

- New check: if `mokutil --sb-state` (or `/sys/firmware/efi/efivars`
  SecureBoot var as fallback) reports enabled, `fatal` with a multi-line
  explanation: why the install cannot proceed (live ZFS module is unsigned),
  and the exact remedy (disable SB in firmware → install → reboot → enroll MOK
  at the blue MokManager screen → re-enable SB).
- Non-EFI / no efivars: skip silently (existing behavior decides EFI
  requirements).

### 2. Config & packages (lib/00-config.sh)

- Add `shim-signed`, `mokutil`, `sbsigntool` to `TARGET_BASE_PACKAGES`.
- GRUB installs additionally get `grub-efi-amd64-signed`.
- New globals: `MOK_KEY=/var/lib/dkms/mok.key`, `MOK_CRT=/var/lib/dkms/mok.pub`
  (paths inside the target).
- Phase-10 offline cache picks these packages up like any others.

### 3. Key creation + hybrid ZFS (scripts/40-system.sh)

- Ensure the dkms MOK keypair exists in the target **before** ZFS module
  builds, so dkms signs modules with it. Debian's dkms generates the pair on
  demand; if absent, generate explicitly (openssl, same parameters dkms uses)
  so EFI signing in phase 50 can rely on it.
- **Replace the install-time OpenZFS source build with repo `zfs-dkms`**
  (Debian 13 ships 2.3.x). dkms builds and signs it in the chroot; it mounts
  the ZFS root on first boot. Pool features stay 2.3-compatible (the live
  environment created the pool with 2.3.x), so the later 2.4.x module imports
  it cleanly.
- Stage a **firstboot OpenZFS upgrade job** through the existing firstboot
  runner: pre-login, no GUI, it fetches/uses the cached OpenZFS source tag
  (phase 10 already caches source archives for offline installs), builds the
  target release (e.g. 2.4.2) via dkms — which signs it with the
  already-enrolled MOK key — rebuilds the initramfs, and reboots. Boot #2
  runs the self-built release. On build failure: log loudly, keep running
  repo 2.3.x (system stays bootable), leave the job re-runnable.

### 4. Boot phase (scripts/50-boot.sh)

New `setup_secureboot()` runs after the chosen loader lands on the ESP:

- Copy `shimx64.efi` and `mmx64.efi` (MokManager) from the target's
  shim-signed package onto each RAID1 ESP member.
- Shim chain-loads a binary named `grubx64.efi` next to it:
  - **grub:** the signed GRUB package provides a Debian-signed `grubx64.efi`
    — place as-is, no self-signing.
  - **zbm / systemd-boot:** `sbsign --key MOK_KEY --cert MOK_CRT` the loader
    EFI binary into the `grubx64.efi` slot.
- `create_nvram_entry()` now points NVRAM entries at shim instead of the bare
  loader (both ESP disks, as today).
- Stage enrollment in the chroot: derive DER cert from the MOK key, then
  `mokutil --import mok.der` with the user's password supplied on stdin
  (mokutil reads it twice).
- If `mokutil --import` fails (no efivars in VM/chroot edge cases): `warn`,
  do not abort — system still boots with SB off and enrollment can be done
  manually later. Print the manual command in the warning.
- Extend the `hypr-deb-sync-esp` hook: after syncing kernel/initrd, re-sign
  the loader binary (zbm/systemd-boot) if its hash changed, so loader updates
  never break the chain. Kernels/initrds are Debian-signed already; the hook
  does not sign them.

### 5. Kernel / module chain (no new work, documented behavior)

- Debian kernels are Debian-signed → trusted by shim/GRUB; ZBM's
  `kexec_file_load` path accepts them under lockdown.
- dkms signs ZFS (and any future NVIDIA) modules with the MOK key
  automatically; enrollment from component 4 makes the kernel trust them.

### 6. Verify phase (scripts/90-verify.sh)

New vchecks:

- shim + MokManager present on each ESP.
- Loader binary signature validates (`sbverify --cert`) for zbm/systemd-boot;
  Debian-signed grub binary present for grub.
- MOK enrollment staged (`mokutil --list-new` non-empty) — warn-level only,
  since import may have been skipped in VMs.

### 7. End-of-install UX

Print a short notice: secure boot is ready; on next boot MokManager (blue
screen) will prompt — choose **Enroll MOK**, enter the user account password;
after that, secure boot may be enabled in firmware at any time. Mention that
the first boot also compiles the newer OpenZFS release in the background
(pre-login) and reboots once when done.

## Testing (tests/secureboot.sh)

Follow the existing pattern (source `test-helpers.sh`, assert on declared
function bodies):

- preflight body contains the SB-state fatal check and remedy text.
- `setup_secureboot` body: shim/mm copy, sbsign for zbm and systemd-boot
  paths, no sbsign on grub path, NVRAM pointed at shim, mokutil import with
  stdin password, warn-not-fatal on import failure.
- sync-hook body contains the re-sign step.
- verify body contains the new vcheck labels.
- config: packages present in `TARGET_BASE_PACKAGES`; `MOK_KEY`/`MOK_CRT`
  defined.
- phase 40: repo `zfs-dkms` install replaces the source build; firstboot
  upgrade job staged with build, initramfs rebuild, reboot, and
  fail-safe-keep-2.3.x behavior.

## Out of scope

- Custom platform-key ownership (sbctl-style PK/KEK replacement).
- Signing kernels/initrds ourselves (Debian's signatures suffice).
- Secure-boot-capable live/installer media.
