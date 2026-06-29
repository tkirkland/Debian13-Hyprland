# Repository Structure

What lives where, and — more importantly — where to go to change things.

## Layout

```
installer.sh                Orchestrator: sources modules, parses args,
                            dispatches phases, owns the failure traps.
lib/00-config.sh            ALL cross-module globals and defaults (env-
                            overridable), package arrays, repo/tag maps,
                            deb822 apt-source writers.
lib/01-log.sh               info/warn/verbose/fatal, tee'd logging.
lib/02-args.sh              usage text, flag parsing, interactive prompts.
lib/03-state.sh             resumable phase stamps (/run/hypr-deb/state).
lib/04-chroot-mounts.sh     bind-mount tracking, in_target, holder kills.
scripts/00-preflight.sh     virt detection, disk selection, tool
                            bootstrap, identity validation, network probe.
scripts/10-cache.sh         offline apt repo: build-host populate/index
                            (incl. the both-flavor NVIDIA driver closure,
                            branches 595+610) + install-time validate
                            (cache_validate gates the on-ISO repo at
                            CACHE_REPO_DIR, incl. the NVIDIA debs).
scripts/20-storage.sh       wipe, partitioning, mdadm arrays, ZFS pool +
                            datasets, failure diagnostics.
scripts/30-bootstrap.sh     pool/ESP mounts, debootstrap (mirror, or file://
                            the on-ISO repo when offline), policy-rc.d guard,
                            permanent Debian apt sources, and the TEMPORARY
                            file:// bind+source for the offline stack install.
scripts/40-system.sh        base packages, locale/tz, fstab/mdadm.conf,
                            user creation, OpenZFS-from-source build,
                            ZFS boot support (hostid, cachefile,
                            initramfs); MOK keypair generation;
                            conditional offline NVIDIA driver install
                            (open|proprietary, branch-pinned, dkms-built);
                            ZFS firstboot upgrade staging (firstboot.d/).
scripts/50-boot.sh          one bootloader (zbm|grub|systemd-boot) on the
                            RAID1 ESP, NVRAM entries, kernel-sync hook;
                            shim/MOK signing and enrollment staging.
scripts/60-hyprland.sh      release-tag resolution, compatibility gate,
                            source builds, build-dep purge, greetd/uwsm
                            session, firstboot staging.
scripts/90-verify.sh        the success-condition checklist (vcheck).
scripts/99-cleanup.sh       teardown: binds, ESP, pool export.
addons/                     drop-in vendor .deb/.run artifacts and
                            package lists (see below).
tests/                      fake-driven test suites + run-all.sh.
tools/build-iso.sh          build-host entry point: compile the stack to
                            .debs, build OpenZFS, index the offline repo, and
                            repack a self-sufficient ISO (installer + store
                            under /opt/hypr-deb). Dry-run by default; --confirm
                            builds. Set LIVE_AUTOINSTALL_PASSWORD to emit the
                            unattended ~/autoinstall.sh launcher in the ISO.
tools/iso-assemble.sh       graft the offline store + installer into the live
                            squashfs under /opt/hypr-deb, bake live extras
                            (git + ssh, sshd enabled on boot), drop
                            ~/installer.sh (interactive) and ~/autoinstall.sh
                            (unattended) in the live home, then xorriso-repack.
tools/check.sh              bash -n + shellcheck gate.
docs/superpowers/           original design spec and implementation plan.
```

## Where do I…

**Add a package to the installed system**
: `TARGET_BASE_PACKAGES` in `lib/00-config.sh` — or, without touching the
  repo at all, an `addons/*.list` file (see below).

**Install a vendor .deb or runfile (Brave, VMware, …)**
: drop the file into `addons/`. `.deb` files install during the system
  phase with apt resolving their dependencies; `.run` files are staged
  executable at `/opt/addons/` in the target for manual post-boot
  installation (runfiles need the running system, not a chroot).

**Add a build-only dependency** (purged after the stack builds)
: `HYPR_BUILD_PACKAGES` in `lib/00-config.sh`.

**Add a runtime dep the purge must never remove**
: `UWSM_RUNTIME_PACKAGES` (or a new array wired into `install_build_deps`).
  Runtime Python/plugin-style deps are invisible to the post-purge `ldd`
  gate, so they cannot ride in `HYPR_BUILD_PACKAGES`.

**Add a tool the live ISO session needs**
: `LIVE_TOOL_PACKAGES` in `lib/00-config.sh` **and** the `pkg_probe` map
  in `scripts/00-preflight.sh`.

**Add a source-built component**
: `HYPR_BUILD_ORDER` (dependency position matters) plus `HYPR_REPO_URL`,
  both in `lib/00-config.sh`. Add `HYPR_TAG_PATTERN[name]` if its tags
  are not `vX.Y.Z`, `HYPR_MESON_ARGS[name]` for meson options, or a
  `build_custom_<name>()` function in `scripts/60-hyprland.sh` for exotic
  build systems (see lua).

**Add an OpenZFS build dependency**
: `ZFS_BUILD_PACKAGES` in `lib/00-config.sh`.

**Change partition sizes or datasets**
: `EFI_SIZE`/`SWAP_SIZE` in `lib/00-config.sh`; dataset hierarchy in
  `create_pool_and_datasets` (`scripts/20-storage.sh`). Update
  `tests/storage-plan.sh` in the same commit.

**Change the greeter or session command**
: `configure_session` in `scripts/60-hyprland.sh`. Absolute paths only —
  greetd provides no PATH to its children.

**Add a CLI flag**
: parse + usage in `lib/02-args.sh`, default in `lib/00-config.sh`,
  assertion in `tests/args.sh`.

**Add a success check**
: a `vcheck` line in `phase_verify` (`scripts/90-verify.sh`).

**Change bootloader behavior**
: `scripts/50-boot.sh`, with `tests/boot-config.sh` updated alongside.

## addons/ — drop-in artifacts, no fork required

The addons directory is for things apt cannot provide:

- `addons/*.deb` — vendor packages (Brave, 1Password, VS Code, …):
  installed into the target during the system phase, with apt resolving
  their dependencies from the enabled sources.
- `addons/*.sh` — user-authored hooks, executed as root inside the
  target chroot in lexical order, after packages and addon debs
  (live-build hook semantics; a failing script fails the install).
- `addons/*.run` — vendor runfiles (VMware, …): staged executable at
  `/opt/addons/` in the installed system for manual post-boot install.
  Never executed in the chroot — runfiles compile kernel modules and
  start services against the running system.
- `addons/*.list` — convenience lists of archive packages (one per line,
  `#` comments; live-build convention), appended to the base set.

All paths go through the same noninteractive apt machinery and the
chroot service-start guard. Preflight logs counts of everything picked
up. See `addons/README.md` for details and the offline caveats.
