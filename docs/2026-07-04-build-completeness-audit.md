# Build-completeness audit — 2026-07-04

## Why this exists

On 2026-07-03 the reference machine's launcher was swapped from hyprlauncher to
walker/elephant. App launching silently broke: elephant launches every app via
`uwsm-app`, and `uwsm-app` had never been installed. uwsm was compiled from
source on day one with meson defaults, and upstream's `uwsm-app` option
**defaults to disabled** — the omission sat invisible for three weeks because
nothing called the missing script until the launcher swap.

That is a *class* of bug: a component builds and installs successfully, its
optional-but-expected pieces don't, and nothing complains until first use.
This audit swept every source-built component in the stack for the same class:
compare the flags we actually build with against upstream's full option set,
find everything default-disabled, and check whether anything on the system
references the omitted artifact.

## Method

For each component in `HYPR_BUILD_ORDER` (plus walker/elephant, installed
manually on the reference machine):

1. Determine actual configure flags (`build_one` in `scripts/60-hyprland.sh`:
   plain `cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr` or
   `meson setup build --prefix=/usr`, plus `HYPR_MESON_ARGS`/`HYPR_CMAKE_ARGS`
   entries — both nearly empty, so effectively upstream defaults).
2. Fetch upstream's `meson.options` / CMake `option()` declarations.
3. List every option defaulting OFF and the artifact it omits.
4. Grep the live machine and this repo for consumers of each omitted artifact.
5. Verdict: LATENT BUG (something references it), RISK (plausible consumer),
   SAFE (nothing plausibly uses it).

## Findings

### Latent bugs (6)

| # | Component | Bug | Scope | Status |
|---|-----------|-----|-------|--------|
| 1 | uwsm | `uwsm-app` meson option defaults disabled; script never installed; elephant hard-depends on it | reference machine + any default-flag build | **Fixed live** (`~/.local/bin/uwsm-app` shim). Installer fix below. |
| 2 | xdg-desktop-portal-hyprland | `SYSTEMD_SERVICES` CMake option defaults OFF: systemd user unit not installed, but the unconditionally-installed D-Bus service file declares `SystemdService=` → activation has no fallback → xdph never starts, broker silently falls to wlr, share-picker lost | **future #57 re-land** (xdph currently reverted, PR #64) | Documented for #57 (comment text below) |
| 3 | portal stack | Reference machine had zero `xdg-desktop-portal*` packages while `~/.config/xdg-desktop-portal/hyprland-portals.conf` routed to gtk/wlr backends that didn't exist — screenshare, sandboxed file dialogs, Settings portal all silently dead | reference machine (predates #57 work) | **Fixed live**: `apt install xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr`; all three services verified answering on D-Bus |
| 4 | elephant calc provider | Provider .so present but self-disables: libqalculate missing. Walker's default `=` prefix silently returns nothing | reference machine | **Fixed live**: `apt install qalc`; provider loads |
| 5 | elephant clipboard provider | Self-disables: imagemagick missing (image clip support). Walker's `:` prefix silently empty | reference machine | **Fixed live**: `apt install imagemagick`; provider loads |
| 6 | elephant websearch provider | In walker's embedded default provider set (`@` prefix) but `websearch.so` never installed | reference machine | **Fixed live**: installed from elephant v2.21.0 release (version-matched); loads |

Also installed while at it: `runner.so` (`>` prefix) and `windows.so` (`$`
prefix) — previously bound-but-absent (the RISK finding).

### Clean components (audited, no findings)

- **Hyprland core** (Hyprland, aquamarine, hyprwire, hyprland-protocols):
  Hyprland uses opt-out `NO_*` flags, so defaults install everything —
  session desktop entries, uwsm session file, systemd support, hyprctl/hyprpm
  + completions. Login chain (greetd → hypr-session → `uwsm start` →
  `hyprland.desktop`) verified end to end on the live machine.
- **Support libs** (hyprwayland-scanner, hyprutils, hyprlang, hyprcursor,
  hyprgraphics, hyprtoolkit, hyprland-guiutils): no runtime artifact is
  gated behind a default-off option. All binaries Hyprland shells out to
  (hyprland-dialog, -run, -welcome, -update-screen, -donate-screen) verified
  present.
- **Session-critical** (hyprlock, hypridle, greetd wiring): zero build
  options upstream; PAM file, systemd user unit, greetd chain all verified.
- **Base** (wayland, wayland-protocols, xkbcommon, lua, swww): only docs/tests
  omitted. xkbcommon's x11/wayland/tools all enabled by default and verified
  built (`libxkbcommon-x11` present — xwayland OK).

## Installer changes required (repo work, validate in VM)

1. **uwsm** — `lib/00-config.sh`:
   ```bash
   HYPR_MESON_ARGS["uwsm"]="-Duwsm-app=enabled -Duuctl=enabled"
   ```
   Then rebuild the single uwsm deb in the pool (uwsm is outside the hyprwm
   dependency graph; nothing else invalidates) and reassemble the ISO.
2. **xdph, when #57 re-lands** — `lib/00-config.sh`:
   ```bash
   HYPR_CMAKE_ARGS["xdg-desktop-portal-hyprland"]="-DSYSTEMD_SERVICES=ON"
   ```
   Plus the Qt6 build-dep fix that killed PR #60/#62.
3. **Launcher migration (separate workstream)** — the installer still builds
   hyprlauncher and binds the launcher key to it; the reference machine now runs
   walker/elephant. Folding that in touches `HYPR_BUILD_ORDER`, config
   staging, keybinds, ISO pool, and tests. Include elephant provider deps
   (`qalc`, `imagemagick`) and provider .so installation when it happens.

### Draft comment for issue #57 (not yet posted)

> **Build-flag trap found for the Option-B (xdph) re-land — will silently
> break even a successful build.** xdph's CMake option `SYSTEMD_SERVICES`
> defaults to OFF, so with the installer's default flags the systemd user
> unit is not installed — but the D-Bus service file installs unconditionally
> and declares `SystemdService=xdg-desktop-portal-hyprland.service`. On a
> systemd user bus that activation path has no Exec fallback: unit missing →
> xdph never activates → broker silently falls through to wlr → the Hyprland
> share-picker (the point of building xdph) never appears, with no error
> anywhere. Re-land checklist must include
> `HYPR_CMAKE_ARGS["xdg-desktop-portal-hyprland"]="-DSYSTEMD_SERVICES=ON"`
> in addition to the Qt6 build-dep fix from PR #60/#62/#64.
> VM verification: `systemctl --user list-unit-files
> xdg-desktop-portal-hyprland.service` exists AND screenshare pops the
> Hyprland picker, not the generic wlr flow.
> Related, same audit: uwsm's `uwsm-app`/`uuctl` meson options also default
> disabled; launcher stacks (elephant/walker) hard-depend on `uwsm-app`.
> Fix alongside: `HYPR_MESON_ARGS["uwsm"]="-Duwsm-app=enabled -Duuctl=enabled"`.

## User acceptance tests (live machine, all patched today)

| Fix | Test | Expected |
|-----|------|----------|
| uwsm-app shim | tap SUPER → `vmm` → enter | Virtual Machine Manager opens |
| portal / screenshare | brave → any WebRTC screenshare (e.g. Meet) | picker dialog appears, preview shows screen |
| portal / file dialog | Ctrl+O in brave | GTK portal file dialog |
| calc | tap SUPER → `=2+2*10` | `22` |
| clipboard | copy 2 snippets → tap SUPER → `:` | both listed, enter pastes |
| websearch | tap SUPER → `@hyprland wiki` → enter | browser opens search |
| runner | tap SUPER → `>` → type a binary name | runs it |
| windows | tap SUPER → `$` | lists open windows, enter focuses |

## Process change

Every future source build: read the configure summary, and for every
disabled/omitted feature resolve what it provides and who could consume it,
then make a deliberate enable/skip decision reported with reasoning. Enforced
by a PostToolUse hook on `meson setup`/`cmake`/`./configure` commands in the
operator's Claude Code settings (added 2026-07-04).

Rollback (live machine): `apt remove xdg-desktop-portal xdg-desktop-portal-gtk
xdg-desktop-portal-wlr qalc imagemagick`; delete `~/.local/bin/uwsm-app` and
the three new `.so` files in `~/.config/elephant/providers/`. No existing
configs were modified.
