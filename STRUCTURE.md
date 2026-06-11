# Repository Structure

What lives where, and — more importantly — where to go to change things.

## Layout

```
hypr_deb.sh                 Orchestrator: sources modules, parses args,
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
scripts/10-cache.sh         offline apt repo + source/ZBM caching.
scripts/20-storage.sh       wipe, partitioning, mdadm arrays, ZFS pool +
                            datasets, failure diagnostics.
scripts/30-bootstrap.sh     pool/ESP mounts, debootstrap, policy-rc.d
                            guard, cache embed, target apt sources.
scripts/40-system.sh        base packages, locale/tz, fstab/mdadm.conf,
                            user creation, OpenZFS-from-source build,
                            ZFS boot support (hostid, cachefile,
                            initramfs).
scripts/50-boot.sh          one bootloader (zbm|grub|systemd-boot) on the
                            RAID1 ESP, NVRAM entries, kernel-sync hook.
scripts/60-hyprland.sh      release-tag resolution, compatibility gate,
                            source builds, build-dep purge, greetd/uwsm
                            session, firstboot staging.
scripts/90-verify.sh        the success-condition checklist (vcheck).
scripts/99-cleanup.sh       teardown: binds, ESP, pool export.
addons/                     drop-in user package lists (see below).
tests/                      fake-driven test suites + run-all.sh.
tools/check.sh              bash -n + shellcheck gate.
docs/superpowers/           original design spec and implementation plan.
```

## Where do I…

**Add a package to the installed system**
: `TARGET_BASE_PACKAGES` in `lib/00-config.sh` — or, without touching the
  repo at all, an `addons/*.list` file (see below).

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

## addons/ — user packages without forking

Any file matching `addons/*.list` is read at startup: one Debian package
name per line, blank lines and `#` comments ignored. Everything found is
appended to `TARGET_BASE_PACKAGES` and installed during the system phase,
subject to the same `DEBIAN_FRONTEND=noninteractive` apt run and the
chroot service-start guard as everything else.

```bash
# addons/my-tools.list
htop
ncdu
firefox-esr   # comes from the same trixie sources the installer enables
```

Notes:
- Packages must exist in the enabled apt sources (trixie main/contrib/
  non-free-firmware by default). Typos fail the system phase loudly.
- Preflight logs how many addon packages were picked up.
- `addons/example.list.sample` ships as a template; only the `.list`
  suffix is loaded, so the sample is inert until renamed.
