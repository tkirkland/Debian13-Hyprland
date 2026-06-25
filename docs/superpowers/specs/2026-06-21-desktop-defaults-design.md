# Default Desktop Apps (hyprlock, hypridle, hyprlauncher, swww) + Wallpaper Set — Design

**Date:** 2026-06-21
**Status:** Draft (spec from live-box work in `linux-fixes`; VM verification pending)
**Related:** Debian13-Hyprland issues `#71`/`#72` (hyprlock/hypridle); supersedes the
"not an installer concern" note about `libpugixml` (fixed on `develop` `826926e`).

## Problem

The installer builds the Hyprland compositor stack but ships no lock screen,
idle manager, application launcher, or wallpaper — and provides no default
keybinds to invoke desktop functionality. These were all added and verified on
the live box (documented in the `linux-fixes` repo) and must now be folded into
the installer so a fresh install is functionally complete with NO post-install
manual steps and NO dependency on the user's personal dotfiles.

## Decisions

- **Baseline usability is the installer's job; personalization is the user's.**
  Every tool the installer builds ships a working DEFAULT keybind/config in the
  installer's own `hypr-deb.lua` module. The installer does NOT run chezmoi;
  restoring personal dotfiles is a user choice made after install.
- **Default keybinds are conventional, not the maintainer's one-handed scheme.**
  Chord paradigm: primary actions are dual chords (`SUPER`+key), secondary
  actions are triple chords (`SUPER+SHIFT`+key).
  - `SUPER+R` → hyprlauncher (this is upstream Hyprland's own example menu slot)
  - `SUPER+L` → `loginctl lock-session` (routes through hypridle's `lock_cmd`)
  - `SUPER+SHIFT+W` → wallpaper cycle (secondary action)
- **Wallpapers ship as a distro set**, included as a **shallow git submodule**
  at `assets/wallpapers/` (the `tkirkland/Wallpaper-Bank` repo, ~1 GB current
  images, no history), installed to `/usr/share/backgrounds/hypr-deb/`. Submodule
  (not runtime asset-clone) because the installer always runs from its clone, so
  clone-resident assets are present in all modes (live-clone, ISO, offline-cache)
  without the cache phase fetching them.
- **swww uses a cargo custom-build hook**, since `build_one` only handles
  CMake/meson. hyprlock/hypridle/hyprlauncher are ordinary CMake builds.
- **Versions track the installer's latest-release-tag model** (no pins; the
  `vX.Y.Z` tags named below are the current latest). All build with the stack's
  `gcc-15` (`HYPR_CC`), not trixie's `gcc-14`.
- **Screenshots/recording (Task 5)** bind to standard standalones — `grimblast`
  + `wf-recorder` — with traditional Print-based defaults, not the maintainer's
  personal `F10` wrappers (those stay in chezmoi).

## Components

### 1. hyprlauncher (CMake) — `lib/00-config.sh`, `scripts/60-hyprland.sh`

- Add `hyprlauncher` to `HYPR_BUILD_ORDER` after `hyprtoolkit`;
  `HYPR_REPO_URL["hyprlauncher"]="https://github.com/hyprwm/hyprlauncher"`,
  tag `v0.1.6` (default `^v?[0-9]+\.[0-9]+\.[0-9]+$` resolver matches).
- Package delta into `HYPR_BUILD_PACKAGES`: `libicu-dev`, `libqalculate-dev`
  (pixman + fontconfig already arrive transitively via `libcairo2-dev`/
  `libpango1.0-dev`; drm and pugixml are in the set).
- Default config: point the launcher slot at hyprlauncher (set the staged
  config's `menu` to `hyprlauncher`, or bind `SUPER+R` → `hyprlauncher` in
  `hypr-deb.lua`).

### 2. hyprlock + hypridle (CMake) — `lib/00-config.sh`, `scripts/60-hyprland.sh`

- Add `hyprlock` (`v0.9.5`) and `hypridle` (`v0.1.7`) to `HYPR_BUILD_ORDER`
  after `hyprgraphics`/`hyprlang`/`hyprutils`; add their `HYPR_REPO_URL`.
- Package delta: `libsdbus-c++-dev` (both) and `libpam0g-dev` (hyprlock PAM).
  Build needs `PKG_CONFIG_PATH` to include `/usr/local/share/pkgconfig` for
  `hyprland-protocols` (build_one already exports this for the stack). Builds
  with the stack `gcc-15` like everything else.
- Stage `/etc/pam.d/hyprlock` (Debian `common-*` includes).
- Ship `hyprlock.conf` and `hypridle.conf` to the target `~/.config/hypr` with
  Lua-form `hl.dsp.dpms(...)` commands, a post-lock DPMS re-assert, and
  hyprlock's disabled animations.
- Enable `hypridle.service` as a `graphical-session.target` user unit (as with
  `swaync`/`mako`).
- Default keybind: `SUPER+L` → `loginctl lock-session` in `hypr-deb.lua`.
- Runtime libs (`libsdbus-c++2`; PAM runtime is base-system) are now protected
  automatically by the `826926e` purge fix that scans all `/usr/local/bin/*`.

### 3. swww (cargo custom build) — `scripts/60-hyprland.sh`, `lib/00-config.sh`

- `build_custom_swww()` modeled on `build_custom_lua()`: `cargo build --release`
  in `${HYPR_SRC_DIR}/swww` with a writable `CARGO_HOME` (default
  `/usr/local/cargo` is root-owned), installing `swww`/`swww-daemon` to
  `/usr/local/bin`.
- Add `swww` to `HYPR_BUILD_ORDER` (tag `v0.11.2`),
  `HYPR_REPO_URL["swww"]="https://github.com/LGFae/swww"`.
- Toolchain: add `cargo` from **trixie-backports** (cargo/rustc 1.90 >= swww's
  rust-version 1.89; trixie main ships 1.85, too old). Deliberately NOT sid:
  sid is reserved for `gcc-15` (never backported), and backports packages are
  rebuilt against trixie so they add no unstable surface. Wired via a pinned,
  opt-in `write_backports_sources` mirroring the sid mechanism; `HYPR_BACKPORTS_PACKAGES`.
  Package delta: `liblz4-dev` (swww links system lz4 via pkg-config).
- **frozen-attribute scanner patch (REQUIRED):** the installer builds `wayland`
  from release tags (>= 1.24 ships the `frozen="true"` interface attribute),
  and swww `v0.11.2` pins `waybackend-scanner 0.6.2`, which panics on it. Stage
  a vendored, one-line-patched `waybackend-scanner` (ignore unknown interface
  attributes) and add `[patch.crates-io]` to swww's workspace `Cargo.toml`
  before `cargo build`. No `0.6.3+` exists to bump to.
- Default config in `hypr-deb.lua`: `hl.exec_cmd("swww-daemon")` on
  `hyprland.start`; set `misc.force_default_wallpaper = 0` and
  `misc.disable_hyprland_logo = true`; set an initial wallpaper from
  `/usr/share/backgrounds/hypr-deb/` (marker-guarded `swww img`, since a fresh
  install has no swww cache to restore).

### 4. Wallpapers (submodule + install) — `.gitmodules`, `scripts/60-hyprland.sh`

- Add `assets/wallpapers/` as a shallow submodule of `tkirkland/Wallpaper-Bank`
  (`.gitmodules` with `shallow = true`).
- Install step copies the images to `/usr/share/backgrounds/hypr-deb/` on the
  target (files only, not `.git`).
- A small `swww` cycle helper (staged to `/usr/local/bin`) assigns a different
  random image per connected output from that dir; default `SUPER+SHIFT+W` bind.
- `--recurse-submodules` handling: README clone instruction; a runtime
  `git submodule update --init --depth 1` guard (online); the ISO bakes the
  checked-out tree.

### 5. Screenshots + screen recording (Task 5) — `lib/00-config.sh`, `scripts/60-hyprland.sh`

- Add tool packages to `TARGET_BASE_PACKAGES` (distro packages, no source build):
  `grimblast` (or `grim` + `slurp` if grimblast is unpackaged — verify in trixie),
  `wf-recorder`, an annotator (`satty` or `swappy`), and `wl-clipboard`.
- Default binds in `hypr-deb.lua`, traditional Print-key cluster:
  `Print` full, `Shift+Print` region, `Ctrl+Print` window, `Super+Print`
  annotate, `Super+Shift+R` toggle screen recording (wf-recorder).
- The maintainer's `linux-screenshot`/`linux-screen-record` wrappers and their
  `F10` binds are NOT shipped — they remain chezmoi personalization.

### 6. Documentation + tests

- `README.md`: `git clone --recurse-submodules` instruction; name the default
  desktop tools and keybinds.
- Keep `tests/config.sh` (asserts `HYPR_BUILD_ORDER`) and
  `tests/hyprland-config.sh` (asserts staged config + `hypr-deb.lua`) green;
  extend the latter to assert the new default binds exist.

## Open risks / notes

- **Offline cargo build:** swww's `cargo build` fetches crates from crates.io;
  `--offline` installs will fail unless the crate set is vendored/cached (e.g.
  `cargo vendor` into the cache, or a pre-populated `CARGO_HOME`). This is the
  main offline gap to resolve for swww and is called out for the VM/offline pass.
- **Verification is the VM run.** No unit test proves the desktop renders;
  real validation is a clean-VM install per the maintainer's workflow. Existing
  shell tests are kept green but are not the gate.
