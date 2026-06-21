# Default Desktop Apps + Wallpaper Set — Implementation Plan

> **For agentic workers:** implement task-by-task. Verification for this batch is
> a clean-VM install run by the maintainer, NOT unit tests. Keep the existing
> `tests/` suite green; do not add the TDD failing-test ritual.

**Goal:** Fold hyprlock, hypridle, hyprlauncher, and swww into the installer with
conventional default keybinds and a system wallpaper set, so a fresh install is
functionally complete without chezmoi.

**Spec:** `docs/superpowers/specs/2026-06-21-desktop-defaults-design.md`.
**Branch:** land on `develop` (maintainer pulls `develop` into a clean VM, tests,
then `main` is updated post-verification).

**Key file facts:**
- `lib/00-config.sh`: `HYPR_BUILD_ORDER` (array), `HYPR_REPO_URL` (map),
  `HYPR_BUILD_PACKAGES`, `HYPR_TOOLCHAIN_PACKAGES`, `HYPR_TAG_PATTERN`.
- `scripts/60-hyprland.sh`: `build_one()` (CMake/meson only), `build_custom_lua()`
  (precedent for non-CMake), `write_hypr_lua_config()` (splits upstream example,
  writes `hypr-deb.lua`), `purge_build_deps()` (already scans `/usr/local/bin/*`,
  `826926e`), `configure_session()`.
- `scripts/10-cache.sh`: `cache_populate_debs` (installs `HYPR_BUILD_PACKAGES` +
  `-t sid HYPR_TOOLCHAIN_PACKAGES`), `cache_populate_sources` (iterates
  `HYPR_BUILD_ORDER`, shallow recursive clone → tarball).
- `tests/config.sh`, `tests/hyprland-config.sh`.

---

### Task 1: hyprlauncher (lowest risk, establishes pattern)
- [ ] `HYPR_BUILD_ORDER`: add `hyprlauncher` after `hyprtoolkit`; add
      `HYPR_REPO_URL["hyprlauncher"]` and tag pin `v0.1.6`.
- [ ] `HYPR_BUILD_PACKAGES`: add `libicu-dev`, `libqalculate-dev`.
- [ ] Default launcher: set staged `menu = "hyprlauncher"` (or `SUPER+R` bind in
      `hypr-deb.lua`).
- [ ] Update `tests/config.sh` expectations for the new build-order member.

### Task 2: hyprlock + hypridle (#71/#72)
- [ ] `HYPR_BUILD_ORDER`: add `hyprlock` (`v0.9.5`), `hypridle` (`v0.1.7`) after
      `hyprgraphics`/`hyprlang`/`hyprutils`; add their `HYPR_REPO_URL`.
- [ ] `HYPR_BUILD_PACKAGES`: add `libsdbus-c++-dev`, `libpam0g-dev`.
- [ ] Stage `/etc/pam.d/hyprlock` (common-* includes).
- [ ] Ship `hyprlock.conf` + `hypridle.conf` to the target `~/.config/hypr`.
- [ ] Enable `hypridle.service` as a `graphical-session.target` user unit.
- [ ] `hypr-deb.lua`: `SUPER+L` → `loginctl lock-session`.

### Task 3: swww (cargo custom build)
- [ ] `build_custom_swww()` in `scripts/60-hyprland.sh` (model on
      `build_custom_lua`): `cargo build --release` with writable `CARGO_HOME`,
      install `swww`/`swww-daemon` to `/usr/local/bin`.
- [ ] `HYPR_BUILD_ORDER` + `HYPR_REPO_URL["swww"]`, tag `v0.11.2`.
- [ ] Add Rust toolchain (verify trixie `rustc` ≥ swww `rust-version`, else `sid`);
      add `liblz4-dev` to `HYPR_BUILD_PACKAGES`.
- [ ] Stage the vendored, patched `waybackend-scanner` + `[patch.crates-io]` in
      the swww source before building (frozen-attribute fix).
- [ ] `hypr-deb.lua`: `swww-daemon` on `hyprland.start`;
      `misc.force_default_wallpaper = 0`, `misc.disable_hyprland_logo = true`;
      marker-guarded initial `swww img` from `/usr/share/backgrounds/hypr-deb/`.
- [ ] Offline: vendor/cache swww's crates (`cargo vendor` into cache or a
      pre-populated `CARGO_HOME`) so `--offline` builds. (Flagged risk.)

### Task 4: Wallpaper set
- [ ] Add `assets/wallpapers/` as a shallow submodule of `tkirkland/Wallpaper-Bank`
      (`.gitmodules` `shallow = true`).
- [ ] Install step: copy images → `/usr/share/backgrounds/hypr-deb/` (files only).
- [ ] Stage the swww cycle helper to `/usr/local/bin`; `hypr-deb.lua`
      `SUPER+SHIFT+W` → cycle over that dir.
- [ ] Runtime `git submodule update --init --depth 1` guard (online).

### Task 5: Screenshots + screen recording (grimblast + wf-recorder)
- [ ] `TARGET_BASE_PACKAGES`: add `grimblast` (or `grim`+`slurp` if unpackaged in
      trixie — verify), `wf-recorder`, `satty` (or `swappy`), `wl-clipboard`.
- [ ] `hypr-deb.lua` traditional binds: `Print` full, `Shift+Print` region,
      `Ctrl+Print` window, `Super+Print` annotate, `Super+Shift+R` record toggle.
- [ ] Do NOT ship the maintainer's `linux-screenshot`/`linux-screen-record`
      wrappers (chezmoi-only).

### Task 6: Docs + test sync
- [ ] `README.md`: `--recurse-submodules` clone instruction; list default tools +
      keybinds.
- [ ] Extend `tests/hyprland-config.sh` to assert the new default binds; confirm
      `tests/config.sh` passes with the expanded build order.

### Acceptance (maintainer, VM)
- [ ] Clean-VM online install: login shows a wallpaper; `SUPER+R` launches
      hyprlauncher; `SUPER+L` locks; idle locks/DPMS-offs; `SUPER+SHIFT+W` cycles.
- [ ] Offline install (`--phase=cache` then `--offline`) reaches the same state
      (gated on the swww cargo-vendor item).
