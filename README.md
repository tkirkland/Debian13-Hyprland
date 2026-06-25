# Debian13-Hyprland

A bash installer that puts Debian 13 (Trixie) onto one specific three-disk
workstation — ZFS root on a raidz1 pool, mdadm RAID for the ESP and swap —
makes it bootable (UEFI, one user-chosen bootloader), and builds Hyprland
and its hyprwm dependencies from their **latest release tags** with a check
for version compatibility. The installation is complete only when both the
bootable Debian system and the Hyprland build pass the verification suite.

**This installer DESTROYS the target disks.** It was written for one
specific machine — a Dell Precision workstation with three internal NVMe
drives (hence the `PRECISION` pool name and `precision` hostname defaults).
It is published as a reference and a starting point, not as a
general-purpose installer: the storage layout, disk count, and the disk
identities below are deliberately hard-coded to that hardware so the
destructive path cannot aim at the wrong disks. On bare metal the
targets are fixed — these exact three disks, no detection, no fallback,
no override:

```
DISK1=/dev/disk/by-id/nvme-eui.0025384331408197
DISK2=/dev/disk/by-id/nvme-eui.002538433140818a
DISK3=/dev/disk/by-id/nvme-eui.002538433140819d
```

Each path must exist and resolve to an internal whole disk (not removable,
not USB). The by-id paths are derived from each drive's NVMe EUI, so they
identify **those exact three drives** — on hardware that doesn't contain
them the paths don't exist and the installer refuses to run; that is the
intended behavior, not a bug. (Note the guard follows the drives, not the
computer: if those drives were physically moved to another machine, the
paths would exist there and the installer would happily erase them.) To
adapt the installer to different hardware, change `DISK1`–`DISK3` in
`lib/00-config.sh` to your own `/dev/disk/by-id/` paths and review the
partition sizes next to them. If you are not installing onto that
machine, run it on a VM.

## VM test mode

Preflight gates disk selection on `systemd-detect-virt`:

- **Bare metal** (`systemd-detect-virt` returns `none`): the three fixed
  by-id paths above, validated, no exceptions.
- **Any VM**: virtio/SCSI disks have no stable `nvme-eui` identity, so the
  installer auto-detects instead. It enumerates internal whole disks
  (`vd*`/`sd*`/`nvme*`, non-removable, non-USB), excludes the live/boot
  medium and anything with mounted filesystems, and requires **exactly
  three** candidates — fewer or more is a hard failure listing what was
  found, never a guess. Candidates are assigned DISK1..3 in name order.

In VM mode only, `VM_DISK1`/`VM_DISK2`/`VM_DISK3` environment variables
override auto-detection (set all three or none; each is validated as a real
internal whole disk). A banner states the active mode and the disks about
to be destroyed; the `destroy` confirmation gate applies in both modes
unless `--yes` is given.

QEMU/OVMF smoke-test recipe:

```bash
qemu-img create -f qcow2 d1.qcow2 32G
qemu-img create -f qcow2 d2.qcow2 32G
qemu-img create -f qcow2 d3.qcow2 32G
qemu-system-x86_64 -enable-kvm -m 8G -smp 4 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=d1.qcow2,if=virtio -drive file=d2.qcow2,if=virtio \
  -drive file=d3.qcow2,if=virtio \
  -cdrom debian-live-13-amd64.iso -boot d
```

Boot the live ISO, get root, run the installer; VM mode picks up the three
blank virtio disks. After the installation, reboot into the chosen bootloader
and confirm the greetd login.

### VMware setup (Workstation/Player)

The installer is battle-tested under VMware (`systemd-detect-virt` reports
`vmware`; the open-vm-tools guest packages are installed automatically in
this mode). Configure the VM as follows:

- **Firmware:** UEFI (VM Settings → Options → Advanced → Firmware type
  → UEFI). Legacy BIOS will not boot the result.
- **Disks:** exactly THREE blank virtual disks, 32 GB+ each (NVMe or SCSI
  controller — names like `nvme0n1..` or `sda..` are both detected). Do
  not attach extra data disks; the exactly-three rule is a hard gate. A
  disk that is mounted (e.g., a fourth disk you formatted for caching) is
  excluded from candidacy and therefore safe.
- **Memory/CPU:** 8 GB+ RAM and 4+ vCPUs recommended. The live overlay is
  RAM-backed — use `--skip-cache` and `--jobs=2` on small VMs.
- **Display:** enable "Accelerate 3D graphics" with 1 GB+ graphics memory
  BEFORE the first boot of the installed system. Without it, vmwgfx
  reports shader model "Legacy" and Hyprland's renderer cannot start.
- **Boot medium:** attach the current Debian 13 live ISO as a CD/DVD
  drive. Use the latest point-release ISO: zfs-dkms in the live session
  needs kernel headers matching the RUNNING live kernel, and mirrors drop
  superseded kernel packages (preflight fails early with a clear message
  if the ISO is stale).
- After installation completes, disconnect the ISO and reboot; the NVRAM
  entry created by the installer boots the chosen loader directly.

tuigreet note: the password field shows asterisks as you type (installer
passes `--asterisks`); without that flag tuigreet echoes nothing, which is
easy to mistake for broken input on a console.

## Storage layout

```
DISK1/DISK2: EFI(2G) SWAP(4G) ZFS(rest)
DISK3:               SWAP(4G) ZFS(rest)

/dev/md/efi:  FAT32 RAID1 (metadata 1.0) — DISK1-part1 + DISK2-part1
/dev/md/swap: swap  RAID0 (metadata 1.2) — DISK1-part2 + DISK2-part2 + DISK3-part1
ZFS pool PRECISION: raidz1 — DISK1-part3 + DISK2-part3 + DISK3-part2
```

Datasets follow the reference hierarchy: `PRECISION/ROOT/debian13`
(bootfs), `home`, `home/Downloads`, `srv`, `var/cache`, `var/lib/docker`,
`var/log`, `var/tmp`. Kernels live in `/boot` **on the root dataset** —
there is no separate boot filesystem, so a snapshot captures kernel and
modules atomically. The `PRECISION/var/lib/docker` dataset is created with
`mountpoint=none` deliberately (for Docker's ZFS storage driver, which
manages its own datasets); set a mountpoint manually if you want it as a
plain directory.

This **intentionally diverges** from `precision-zfs-dr.sh` layout parity:
the separate `md/boot` array is removed (4 partitions become 3 on
DISK1/DISK2) and the ESP grows to 2G so that any of the three supported
bootloaders fit, including kernel/initramfs copies for grub and
systemd-boot.

## Usage

From a Debian 13 live session (or an installed Debian system), as root:

```bash
# --recurse-submodules pulls the bundled wallpaper set (assets/wallpapers).
git clone --recurse-submodules https://github.com/tkirkland/Debian13-Hyprland.git
cd Debian13-Hyprland
sudo ./installer.sh
```

If you cloned without `--recurse-submodules`, run
`git submodule update --init --depth 1` before installing (the installer also
attempts this automatically when a network is available); otherwise the default
wallpapers are skipped.

With no flags it prompts for the bootloader and then for the destructive
confirmation (type `destroy`). Preflight self-bootstraps its own tool
prerequisites (debootstrap, gdisk, mdadm, zfs-dkms, ...) from the network
or the cache.

Common flags (see `--help` for the full list):

```
--bootloader=<zbm|grub|systemd-boot>   bootloader (required with --yes)
--build-on-firstboot                   defer the Hyprland build to first boot
--offline                              install only from the local cache
--phase=<name>                         run a single phase
--keep-build-deps                      do not purge build deps after success
--skip-cache                           omit the embedded offline cache
--autologin                            start Hyprland without the login prompt
--rtc=<utc|local>                      hardware clock interpretation, required
                                       (utc, or local for Windows dual boot;
                                       prompted if omitted)
--nvidia=<open|debian|none|package>    NVIDIA driver source when a GPU is
                                       detected (default: prompt; unattended
                                       uses "open" — NVIDIA's repo, open
                                       kernel modules, production branch)
--nvidia-version=<ver>                 pin an exact NVIDIA version for
                                       --nvidia=open (e.g. 610.43.02-1);
                                       pinned installs are apt-mark held
--jobs=<n>                             cap build parallelism
--mirror=<url>                         Debian mirror (default deb.debian.org)
--ntp="<servers>"                      space-separated NTP servers for the
                                       installed system's systemd-timesyncd
                                       (optional; empty keeps Debian's stock
                                       pool/DHCP servers). Time sync is
                                       installed and enabled either way
--cache-dir=<path>                     cache location (default /var/cache/hypr-deb)
--fresh                                discard phase state and start over
--yes                                  unattended mode; requires USER_PASSWORD
--verbose                              stream full command output to the console
                                       (default: one in-place phase indicator;
                                       full output always stays in the log)
```

Identity and layout knobs are environment overrides (set before launch):
`TARGET_HOSTNAME`, `TARGET_USERNAME`, `USER_PASSWORD`, `ROOT_PASSWORD`,
`TIMEZONE`, `LOCALE`, `NTP_SERVERS`, `POOL_NAME`, `EFI_SIZE`, `SWAP_SIZE`,
`HYPRDIM_REPO_URL` (source for the hypr-dim brightness daemon), and
more — see `lib/00-config.sh`.

The installed system has time synchronization enabled by default: `systemd-timesyncd`
is installed and enabled in the target, so the clock stays disciplined after
boot (Debian's stock NTP pool unless `--ntp`/`NTP_SERVERS` pins specific
servers). timesyncd is a client only and never serves time to a LAN.

With `--bootloader=grub`, the installer runs `os-prober` and adds chainloader
menu entries for other detected OSes (e.g. Windows) — GRUB writes a static
config here, so this happens at install time, not via `grub-mkconfig`. Set
`GRUB_OS_PROBER=0` to skip. The `zbm` and `systemd-boot` loaders don't scan
for other OSes; use the UEFI firmware boot menu (or rEFInd) to pick between
them and Windows.

### Add-ons

Drop optional installation inputs into `addons/` before starting:

- `addons/*.list` appends Debian package names to the target package set.
  Use one package per line; blank lines and `#` comments are allowed.
- `addons/*.deb` installs vendor packages during the system phase with
  `apt`, so dependencies resolve from the configured Debian sources.
- `addons/*.sh` runs as root inside the target chroot, in lexical order,
  after the base packages and add-on `.deb` files. Any failure stops the
  phase.
- `addons/*.run` is copied executable to `/opt/addons/` for manual use
  after the first boot. The installer does not run vendor installers in
  the chroot.

For offline installations, dependencies required by add-on `.deb` files must
already exist in the cache. See `addons/README.md` for examples and the
execution environment available to add-on scripts.

### Phases

A full run executes the phases in order; each phase stamps its completion
under `/run/hypr-deb/state`, so a failed run resumes where it stopped
(`--fresh` discards the stamps). `--phase=<name>` runs exactly one phase —
preflight always runs first for safety, and single-phase runs skip stamps
so a phase can be re-run explicitly. Because single-phase `--phase=<name>`
runs do not write completion stamps, a later full run will re-execute
those phases — for `storage` that is destructive (it re-wipes the disks).
When resuming after a failure, the
installer re-imports the ZFS pool and re-establishes the target mounts, and
chroot binds automatically.

```
preflight   root/virt/live detection, tool bootstrap, disk selection, clock sync
cache       populate or validate the offline cache (network needed to populate)
storage     destroy/wipe/partition/mdadm/ZFS (the destructive gate lives here)
bootstrap   mount target, debootstrap, bind mounts, apt sources, embed cache
system      identity, packages, add-ons, user, ZFS boot support, initramfs
boot        chosen bootloader install + NVRAM entry + ESP kernel-sync hook
hyprland    tag resolution, compatibility gate, builds (or firstboot staging)
verify      full verification suite (nonzero exit on any failure)
cleanup     unmount binds and target tree, export the pool
```

### Offline workflow

The installer prefers the network but can run fully offline:

1. On a networked machine, run:

   ```bash
   sudo ./installer.sh --phase=cache \
     --cache-dir=/path/on/real/storage
   ```

   This downloads the complete .deb
   closure (live tools, debootstrap base, target base, bootloaders,
   Hyprland build deps, greetd, and uwsm's runtime deps) indexed with
   `apt-ftparchive` as a `file://` repo, source archives for every
   source-built component at its resolved release tag, and the
   ZFSBootMenu EFI binary.
2. Carry the cache directory to the target machine (it must be on real
   storage, not the live overlay).
3. Run `sudo ./installer.sh --offline --cache-dir=/path/to/cache ...`.
   Offline runs validate the cache first and fail with a precise list of
   anything missing.

Warning: offline live-session preflight installs zfs-dkms against the
running live kernel, so the cache must have been built against the same
live-ISO kernel version (matching `linux-headers`). This is checked.

Online runs install `linux-headers-$(uname -r)` (the running kernel), not
`linux-headers-amd64` (the archive's newest), because zfs-dkms must build
for the kernel the live session is actually running. If the mirror no
longer carries headers for the live ISO's kernel — typically because a
newer point release shipped — preflight fails early with instructions to
boot a current live ISO.

Either way, the complete cache is copied into the installed system at
`/var/cache/hypr-deb/` (with a README) so the target can rebuild Hyprland
or reinstall packages fully offline later.

## Bootloader choice

Exactly one bootloader is installed — `--bootloader=zbm|grub|systemd-boot`,
or an interactive prompt when the flag is omitted (non-interactive/`--yes`
runs require the flag). The chosen loader gets a single NVRAM boot entry
via `efibootmgr` (deduplicated by label; creation must succeed), and the
storage layout is identical regardless of choice.

- **zbm** — the upstream ZFSBootMenu release EFI binary on the ESP
  (`EFI/zbm/zfsbootmenu.efi`). It reads kernels directly from the ZFS pool
  and can boot snapshots and alternate boot environments directly. No
  kernel-sync hook is needed.
- **grub** — `grub-efi-amd64` with a static `grub.cfg` on the ESP
  (`EFI/debian/grub/grub.cfg`) that loads kernel copies **from the ESP**,
  never from the pool, so no ZFS pool-feature restrictions apply.
- **systemd-boot** — `bootctl install` with loader entries pointing at ESP
  kernel copies.

For grub and systemd-boot, a kernel postinst/initramfs hook syncs the
current kernel + initramfs from `/boot` (on ZFS) to the ESP on every kernel
or initramfs update.

**Rollback caveat:** with grub or systemd-boot, after rolling back the root
 dataset, the ESP still carries the newer kernel copy until the hook next
runs — the system boots the new kernel on the old root. Only ZBM boots true
point-in-time snapshots (kernel and userland together). If snapshot boot is
why you run ZFS, choose `zbm`.

## Secure boot

Secure boot support is always on — there is no flag to disable it.

Every bootloader path uses shim (Microsoft-signed) as the EFI entry point.
GRUB's chain (`EFI/debian/shimx64.efi → grubx64.efi`) is fully Debian-signed,
so no additional key enrollment is required for that path. ZFSBootMenu and
systemd-boot binaries (`grubx64.efi` in their respective ESP directories) are
signed at installation time with the machine's dkms MOK key — the same key dkms
uses to sign ZFS (and any future) kernel modules.

**Enrollment:** the installer stages `mokutil --import` so the key is queued
for enrollment. On the first boot the blue MokManager screen appears — choose
**Enroll MOK** and enter your user account password. After enrollment, you can
enable secure boot in firmware settings at any time.

**Installing requires secure boot DISABLED** in firmware. The live session
must load its own unsigned ZFS kernel module; preflight aborts if the secure
boot is active. Enable it after the first-boot MOK enrollment.

**Manual ZBM updates** need re-signing after replacing the binary:

```bash
sbsign --key /var/lib/dkms/mok.key --cert /var/lib/dkms/mok.pem \
  --output /boot/efi/EFI/zbm/grubx64.efi <new>.EFI
```

systemd-boot re-signs automatically via the kernel-sync hook installed by the
installer. GRUB needs nothing — its binary is Debian-signed.

## Hyprland stack

Scope is deliberately lean: a Debian base, compiled Hyprland, greetd +
UWSM, a terminal (kitty), and a PipeWire/WirePlumber audio stack — no
waybar or other desktop extras. NVIDIA support is opt-in (`--nvidia`, and
only when a GPU is detected); on the Dell Precision 7780 a `modprobe.d`
drop-in forces the SOF SoundWire audio driver. UWSM is not packaged in
Debian, so it is built from source (meson) at its latest release tag, like
the hyprwm stack; its runtime dependencies (python3, python3-xdg,
whiptail, dbus-user-session) come from Debian.

greetd launches a single Hyprland session through a wrapper at
`/usr/local/bin/hypr-session` (`uwsm start -- hyprland.desktop`). The
wrapper keeps the greeter→desktop handoff quiet (issue #12): it runs uwsm
under `systemd-cat` with `UWSM_SILENT_START=2`, so startup chatter lands in
the journal (`journalctl -t hypr-session`) instead of painting over VT1.
With a greeter, greetd runs `tuigreet --remember --asterisks --sessions
/etc/greetd/sessions` — a directory holding exactly one curated "Hyprland"
entry that points at the wrapper, so the upstream session files (which
would bypass the silencing) are never offered. `--autologin` runs the
wrapper directly as the target user, with no greeter. The installer also
writes a minimal `hyprland.lua`, launches a first-login welcome app,
enables greetd, masks the competing VT1 getty, and sets `graphical.target`
as the default.

Default desktop apps and keybinds make a fresh install usable without any
dotfiles (personal config via chezmoi remains a separate user choice that
overrides these). The installer builds **hyprlock** (lock screen, PAM via
`/etc/pam.d/hyprlock`), **hypridle** (idle dim → DPMS-off → lock, enabled as
a `graphical-session.target` user unit), **hyprlauncher** (application
launcher), and **swww** (wallpaper daemon, autostarted), and adds default
binds in `hypr-deb.lua`: `SUPER+R` launcher, `SUPER+L` lock, `SUPER+SHIFT+W`
wallpaper cycle, and the traditional `Print` screenshot cluster
(`Print`/`Shift+Print`/`Super+Print` via grim/slurp/swappy) plus
`Super+Shift+R` screen recording (wf-recorder). A distro wallpaper set ships
as the `assets/wallpapers` submodule, installed to
`/usr/share/backgrounds/hypr-deb`.

**External-display brightness** (issue #66): the `XF86MonBrightness` keys, the
idle dim, and the lock screen all drive one logical brightness level across
*every* connected display via the `brightness-sync` wrapper
(`/usr/local/bin/brightness-sync`). Where a real hardware backlight exists it is
set directly with `brightnessctl` — the internal panel, and external monitors
exposed as `/sys/class/backlight` nodes by the `ddcci-dkms` driver over DDC/CI
(`ddcutil`/`i2c-tools` provide the DDC/CI tooling; the `ddcci` and `i2c-dev`
kernel modules are auto-loaded via `/etc/modules-load.d/ddcci.conf`, and the
owner joins the `i2c` group). Displays with no controllable backlight fall back
to **gamma** dimming via **hypr-dim**, a small Rust daemon (D-Bus `dev.hyprdim`)
built from source like swww and run as a `graphical-session.target` user unit
(`HYPRDIM_REPO_URL` overrides its source). There is no separate brightness flag:
the subsystem is always installed and is a no-op on hardware with nothing to
control.

Source policy:

- The **latest release tag** (semver-highest, pre-releases excluded — not
  the latest commit) of Hyprland is resolved via `git ls-remote --tags`.
- Components are built from source in dependency order, each at its own
  latest stable tag: Wayland, wayland-protocols, xkbcommon, Lua,
  hyprwayland-scanner, hyprutils, hyprlang, hyprcursor, hyprgraphics,
  hyprland-protocols, hyprwire, aquamarine, Hyprland, hyprtoolkit,
  hyprland-guiutils, hyprlock, hypridle, hyprlauncher, swww, hypr-dim, then
  UWSM. (swww and hypr-dim are Rust/cargo builds via custom hooks; the rest are
  CMake/meson.)
- **Compatibility gate:** Hyprland's CMake version requirements at the
  resolved tag are parsed, and every dependency's resolved tag must satisfy
  them. On any mismatch the run aborts with a requirement-vs.-resolved
  matrix. No silent downgrades.
- Builds run **inside the target** (chroot, or on first boot), so binaries
  link against exactly the userland that runs them. The build uses GCC 15
  from a pinned sid source where required. Artifacts install to
  `/usr/local`; build trees under `/var/tmp` are deleted after installation.
- **OpenZFS comes from upstream, not trixie**, on every networked installation:
  the latest release builds in the chroot as native `openzfs-*` packages
  replacing Debian's 2.3.x, with modules dkms-signed by the machine's MOK
  key. Offline installs keep repo 2.3.x (the cache carries no zfs source).
  The pool itself is created by the live session's 2.3.x, so its feature
  set stays conservative until you `zpool upgrade` deliberately.

Build hygiene: the exact build-dependency package set is recorded and, after
a successful build and verify, purged (`apt-get purge --autoremove`), leaving
only the Hyprland artifacts and their runtime libraries. Use
`--keep-build-deps` to keep the toolchain installed; either way the cached
build-dep .debs stay in `/var/cache/hypr-deb` for offline reinstallation.

`--build-on-firstboot` stages the sources and cached DEBs in the target and
installs a one-shot systemd unit (`hypr-deb-firstboot.service`) that runs
the identical build logic on first boot, disables itself on success, and
leaves a clear failure log otherwise.

## Development checks

```bash
bash tools/check.sh     # bash -n + shellcheck over every shell file
bash tests/run-all.sh   # all unit tests (fake-command pattern, no root)
```

Design spec and implementation plan live under `docs/superpowers/`.
