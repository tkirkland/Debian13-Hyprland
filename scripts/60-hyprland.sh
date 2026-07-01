# shellcheck shell=bash
# Hyprland stack: release-tag resolution, compatibility gate, source builds
# in the target, greetd/uwsm session, build-dep purge, firstboot staging.

# When staged standalone on the target (firstboot), there is no chroot:
# provide an in-place in_target if lib/04-chroot-mounts.sh wasn't sourced.
if ! declare -f in_target >/dev/null; then
  in_target() {
    (($# == 1)) || fatal "in_target expects exactly one command string"
    /usr/bin/env bash -c "$1"
  }
fi
# Same standalone-staging concern: the helper lives in lib/00-config.sh.
if ! declare -f nvidia_install_requested >/dev/null; then
  nvidia_install_requested() {
    ((${HAS_NVIDIA_GPU:-0})) &&
      [[ -n "${NVIDIA_DRIVER:-}" && "${NVIDIA_DRIVER}" != "none" ]]
  }
fi

HYPR_SRC_DIR="/var/tmp/hypr-deb-build"

# Custom-stack components already satisfied by a prebuilt deb (populated by
# online_install_prebuilt on the --online path). build_stack consults it to
# source-build only the components NOT covered by the ISO's prebuilt debs.
declare -gA HYPR_PREBUILT_INSTALLED=()

# Latest stable release tag. Default pattern: vX.Y.Z or X.Y.Z
# (rc/alpha/nightly excluded). $2 overrides the pattern for repos with
# other schemes (see HYPR_TAG_PATTERN).
resolve_latest_release_tag() {
  local repo_url="$1" pattern="${2:-}" raw="" tag=""
  [[ -n "${pattern}" ]] || pattern='^v?[0-9]+\.[0-9]+\.[0-9]+$'
  raw="$(git ls-remote --tags --refs "${repo_url}")" ||
    fatal "git ls-remote failed for ${repo_url} (network/URL problem)."
  tag="$(printf '%s\n' "${raw}" |
    awk -F/ '{print $NF}' |
    grep -E "${pattern}" |
    sort -V | tail -n1 || true)"
  [[ -n "${tag}" ]] || fatal "No release tag found for ${repo_url}"
  printf '%s\n' "${tag}"
}

# Minimum version of dep $2 declared in CMake file $1 (empty if absent).
# Matches both "dep>=X.Y.Z" (pkg_check_modules) and
# "find_package(dep X.Y.Z" forms.
extract_min_version() {
  local cmake_file="$1" dep="$2" ver=""
  ver="$(grep -hoE "(^|[^A-Za-z0-9_-])${dep} *>= *[0-9.]+" "${cmake_file}" \
    2>/dev/null | grep -oE '[0-9.]+$' | sort -V | tail -n1 || true)"
  if [[ -z "${ver}" ]]; then
    ver="$(grep -hoE "find_package\(${dep} +[0-9.]+" "${cmake_file}" \
      2>/dev/null | grep -oE '[0-9.]+$' | sort -V | tail -n1 || true)"
  fi
  printf '%s' "${ver}"
}

version_ge() { # $1 >= $2 ?
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# Assert every resolved dep tag satisfies Hyprland's declared minimums.
# Prints a requirement matrix; aborts on any mismatch (spec: no silent
# downgrades).
check_compat() {
  local cmake_file="$1" name="" required="" resolved="" bad=0
  info "Compatibility gate (Hyprland requirements vs resolved tags):"
  printf '  %-22s %-12s %-12s %s\n' "dependency" "required>=" "resolved" "status"
  for name in "${!HYPR_RESOLVED_TAG[@]}"; do
    required="$(extract_min_version "${cmake_file}" "${name}")"
    # Strip any non-numeric tag prefix ('v', 'xkbcommon-', ...) so the
    # comparison sees a plain version.
    resolved="${HYPR_RESOLVED_TAG[${name}]}"
    resolved="${resolved#"${resolved%%[0-9]*}"}"
    if [[ -z "${required}" ]]; then
      printf '  %-22s %-12s %-12s %s\n' "${name}" "-" "${resolved}" "n/a"
      continue
    fi
    if version_ge "${resolved}" "${required}"; then
      printf '  %-22s %-12s %-12s %s\n' "${name}" "${required}" "${resolved}" "OK"
    else
      printf '  %-22s %-12s %-12s %s\n' "${name}" "${required}" "${resolved}" "TOO OLD"
      bad=1
    fi
  done
  ((bad == 0)) ||
    fatal "Dependency tag(s) do not satisfy Hyprland's requirements (matrix above)."
}

# Resolve all tags: from the network, or from the cache MANIFEST offline.
resolve_all_tags() {
  local name="" tag=""
  if ((NETWORK_AVAILABLE)); then
    for name in "${HYPR_BUILD_ORDER[@]}"; do
      tag="$(resolve_latest_release_tag "${HYPR_REPO_URL[${name}]}" \
        "${HYPR_TAG_PATTERN[${name}]:-}")"
      HYPR_RESOLVED_TAG["${name}"]="${tag}"
      info "Resolved ${name} -> ${tag}"
    done
  else
    [[ -f "${CACHE_DIR}/sources/MANIFEST" ]] ||
      fatal "Offline and no cached source manifest."
    while read -r name tag; do
      HYPR_RESOLVED_TAG["${name}"]="${tag}"
      info "Cached ${name} -> ${tag}"
    done <"${CACHE_DIR}/sources/MANIFEST"
  fi
}

# Place source tree for $1 at ${TARGET}${HYPR_SRC_DIR}/$1. Cache-first.
stage_source() {
  local name="$1"
  [[ -n "${HYPR_RESOLVED_TAG[${name}]:-}" ]] ||
    fatal "No resolved tag for '${name}' (resolve_all_tags not run or manifest incomplete)."
  local tag="${HYPR_RESOLVED_TAG[${name}]}" dest="" tarball=""
  dest="${TARGET}${HYPR_SRC_DIR}/${name}"
  tarball="${CACHE_DIR}/sources/${name}-${tag}.tar.gz"
  rm -rf "${dest}"
  if [[ -f "${tarball}" ]]; then
    mkdir -p "${dest}"
    tar -xzf "${tarball}" -C "${dest}" --strip-components=1
  elif ((NETWORK_AVAILABLE)); then
    # Clone, not a codeload tarball: tag tarballs omit git submodules
    # (Hyprland needs subprojects/udis86).
    git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
      --recurse-submodules --shallow-submodules \
      "${HYPR_REPO_URL[${name}]}" "${dest}"
  else
    fatal "No cached source for ${name} ${tag} and no network."
  fi
}

install_build_deps() {
  # gcc-15 lives only in sid, the Rust toolchain only in trixie-backports.
  # write_sid_toolchain_sources / write_backports_sources add those suites at
  # a blanket priority 100 PLUS a scoped allow-pin (priority 500) for exactly
  # the gcc-15 closure and the Rust toolchain. That lets us install by NAME
  # with no `-t`: `-t` sets the target release for the whole transaction
  # (priority 990), overriding the 100-pin and dragging unrelated upgrades
  # (libmpfr6 off sid; libnghttp3-9/libngtcp2-16/libcurl4t64 off backports via
  # cargo) that then conflict with the trixie -dev packages. By name, the
  # 100-pin keeps everything on trixie except the allow-pinned toolchain.
  # Offline, the cache repo serves both versions and the resolver picks what
  # gcc-15/cargo require.
  if ((NETWORK_AVAILABLE)); then
    write_sid_toolchain_sources "${TARGET}"
    write_backports_sources "${TARGET}"
    in_target "apt-get update"
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y ${HYPR_TOOLCHAIN_PACKAGES[*]}
      apt-get install -y ${HYPR_BACKPORTS_PACKAGES[*]}
    "
  else
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y ${HYPR_TOOLCHAIN_PACKAGES[*]} ${HYPR_BACKPORTS_PACKAGES[*]}
    "
  fi
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${HYPR_BUILD_PACKAGES[*]}
  "
  # uwsm's meson probes its Python runtime deps at configure time; the
  # system phase that installs them may be stamped done on a resume, so
  # re-ensure them here (idempotent, and NOT part of the purge set).
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${UWSM_RUNTIME_PACKAGES[*]}
  "
  # Record exactly what we may purge later (toolchain included; the
  # upgraded runtime libs are upgrades, not purge candidates).
  printf '%s\n' "${HYPR_BUILD_PACKAGES[@]}" "${HYPR_TOOLCHAIN_PACKAGES[@]}" \
    "${HYPR_BACKPORTS_PACKAGES[@]}" \
    >"${TARGET}${HYPR_SRC_DIR}/.build-deps"
}

# Lua ships a plain Makefile, no pkg-config file, and (post-5.3) no
# lua.hpp. Compile a static PIC library directly (it links into the PIE
# Hyprland executable), install headers, and generate the lua.pc that
# pkg_search_module('lua>=5.5') needs. The interpreter/compiler mains and
# the amalgamation unit are excluded; readline is not needed for the
# library. Handles both the github mirror layout (sources at the repo
# root) and tarball layout (src/).
build_custom_lua() {
  local ver="${HYPR_RESOLVED_TAG[lua]#v}"
  info "Building lua ${ver} (static PIC lib + pkg-config file)..."
  in_target "
    set -e
    cd '${HYPR_SRC_DIR}/lua'
    [[ -d src ]] && cd src
    rm -f ./*.o
    for f in *.c; do
      case \"\${f}\" in lua.c | luac.c | onelua.c) continue ;; esac
      '${HYPR_CC}' -O2 -fPIC -DLUA_USE_LINUX -c \"\${f}\"
    done
    ar rcs liblua.a ./*.o
    install -d \"${HYPR_DESTDIR:-}/usr/include\" \"${HYPR_DESTDIR:-}/usr/lib/pkgconfig\"
    install -m644 lua.h luaconf.h lualib.h lauxlib.h \"${HYPR_DESTDIR:-}/usr/include/\"
    install -m644 liblua.a \"${HYPR_DESTDIR:-}/usr/lib/\"
  "
  cat >"${TARGET:-}${HYPR_DESTDIR:-}/usr/lib/pkgconfig/lua.pc" <<EOF
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua language engine
Version: ${ver}
Libs: -L\${libdir} -llua -lm -ldl
Cflags: -I\${includedir}
EOF
  if [[ ! -f "${TARGET:-}${HYPR_DESTDIR:-}/usr/include/lua.hpp" ]]; then
    cat >"${TARGET:-}${HYPR_DESTDIR:-}/usr/include/lua.hpp" <<'EOF'
// lua.hpp shim: upstream stopped shipping it after Lua 5.3.
extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}
EOF
  fi
}

build_custom_swww() {
  info "Building swww ${HYPR_RESOLVED_TAG[swww]} (cargo)..."
  in_target "
    set -e
    cd '${HYPR_SRC_DIR}/swww'
    # swww v0.11.x pins waybackend-scanner 0.6.2, whose code generator panics
    # on the informational frozen=\"true\" interface attribute present in
    # wayland >= 1.24 (we build wayland from release tags). The attribute has
    # no codegen meaning, so strip it from the core wayland.xml the scanner
    # reads — simpler than vendoring a patched scanner crate, and it leaves the
    # committed Cargo.lock usable with --locked. This patches the INSTALLED
    # wayland.xml in the build environment (from our compiled wayland), NOT
    # swww's DESTDIR output — so it is intentionally not HYPR_DESTDIR-prefixed.
    if [[ -f /usr/share/wayland/wayland.xml ]]; then
      sed -i 's/ frozen=\"true\"//g' /usr/share/wayland/wayland.xml
    fi
    export CARGO_HOME=/tmp/swww-cargo
    cargo build --release --locked
    install -Dm755 target/release/swww target/release/swww-daemon \
      -t \"${HYPR_DESTDIR:-}/usr/bin/\"
    rm -rf /tmp/swww-cargo
  "
}

# hypr-dim: per-display gamma brightness daemon for external outputs (issue #66).
# Cargo build, mirroring build_custom_swww (its own CARGO_HOME, --release
# --locked, install to /usr/bin, then drop the cargo home). The
# hypr-dim.service user unit (staged in configure_session) starts the installed
# binary; the brightness-sync wrapper drives it over D-Bus dev.hyprdim.
build_custom_hypr_dim() {
  info "Building hypr-dim ${HYPR_RESOLVED_TAG[hypr-dim]} (cargo)..."
  in_target "
    set -e
    cd '${HYPR_SRC_DIR}/hypr-dim'
    export CARGO_HOME=/tmp/hypr-dim-cargo
    cargo build --release --locked
    install -Dm755 target/release/hypr-dim -t \"${HYPR_DESTDIR:-}/usr/bin/\"
    rm -rf /tmp/hypr-dim-cargo
  "
}

# Builds CMake projects (the hyprwm stack), meson projects (xkbcommon,
# wayland-protocols, uwsm), and components with a build_custom_<name>
# override (lua's static lib, swww's cargo build).
build_one() {
  local name="$1" custom_fn="build_custom_${1//-/_}"
  if declare -f "${custom_fn}" >/dev/null; then
    "${custom_fn}"
    return 0
  fi
  local meson_args="${HYPR_MESON_ARGS[${name}]:-}"
  # Empty --jobs means one job per CPU (expanded inside the target).
  local jobs="${HYPR_BUILD_JOBS:-}"
  [[ -n "${jobs}" ]] || jobs="\$(nproc)"
  info "Building ${name} ${HYPR_RESOLVED_TAG[${name}]}..."
  in_target "
    set -e
    export CC='${HYPR_CC}' CXX='${HYPR_CXX}'
    cd '${HYPR_SRC_DIR}/${name}'
    if [[ -f CMakeLists.txt ]]; then
      cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr
      cmake --build build -j\"${jobs}\"
      DESTDIR=\"${HYPR_DESTDIR:-}\" cmake --install build
    elif [[ -f meson.build ]]; then
      meson setup build --prefix=/usr --buildtype=release ${meson_args}
      meson compile -C build -j \"${jobs}\"
      DESTDIR=\"${HYPR_DESTDIR:-}\" meson install -C build
    else
      echo 'No CMakeLists.txt or meson.build in ${name}' >&2
      exit 1
    fi
    ldconfig
  "
}

build_stack() {
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}"
  install_build_deps
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    # --online: a component already installed from the ISO's prebuilt deb
    # (online_install_prebuilt) needs no source build.
    if [[ -n "${HYPR_PREBUILT_INSTALLED[${name}]:-}" ]]; then
      info "Skipping source build of ${name} (installed from prebuilt deb)."
      continue
    fi
    stage_source "${name}"
    build_one "${name}"
  done
  in_target "test -x /usr/bin/Hyprland" ||
    fatal "Hyprland binary missing after build."
  # uwsm builds LAST and is the session entrypoint (greetd -> hypr-session ->
  # uwsm). If any earlier component fails, the loop aborts and uwsm never
  # builds, leaving a system that boots to greetd with no session manager — a
  # dead greeter ("failed to execute process: .../uwsm"). Verify it so a
  # half-finished build fails the install instead of shipping broken.
  in_target "test -x /usr/bin/uwsm" ||
    fatal "uwsm binary missing after build (the session would not launch)."
}

purge_build_deps() {
  if ((KEEP_BUILD_DEPS)); then
    info "--keep-build-deps: leaving toolchain installed."
    return 0
  fi
  info "Pinning runtime libraries of built binaries..."
  # Phase 2 moved the COMPILED stack to /usr (CMAKE_INSTALL_PREFIX=/usr,
  # meson --prefix=/usr), so the built binaries and their libs now live in
  # /usr/bin and /usr/lib, not /usr/local. Scan every installed binary, not
  # just Hyprland: the protocol code generators hyprwayland-scanner and
  # hyprwire-scanner link libpugixml.so.1 (package libpugixml1v5), whose
  # only -dev provider (libpugixml-dev) is a purged build dep. Pinning
  # solely off Hyprland + libs leaves those scanners' runtime libs
  # unprotected, so the purge strips libpugixml1v5 and they break for every
  # later source build (hyprlock/hypridle/hyprlauncher/swww add-ons).
  # Pinning the runtime-lib packages of all /usr binaries is harmless to the
  # purge goal — build deps are -dev/toolchain packages that no binary links
  # against, so ldd never lists them. ldd on a non-ELF entry (the hand-written
  # glue scripts kept in /usr/local) just warns to stderr (suppressed).
  in_target "
    set -e
    ldd /usr/bin/* /usr/lib/lib*.so* 2>/dev/null |
      grep -oE '/[^ ]+\.so[^ ]*' | sort -u |
      xargs -r -n1 -- realpath 2>/dev/null | sort -u |
      xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u |
      xargs -r apt-mark manual
  "
  info "Purging build dependencies..."
  # dkms rebuilds (and re-signs) the zfs module on every kernel update, so
  # ZFS_BUILD_PACKAGES must stay installed for the system's lifetime.
  # Several of them overlap the Hyprland build deps (build-essential,
  # libffi-dev, libudev-dev, ...), so spare the whole ZFS set here —
  # install_zfs_from_source apt-marked them manual against the autoremove.
  local dep="" purge_list=()
  while IFS= read -r dep; do
    [[ -n "${dep}" ]] || continue
    case " ${ZFS_BUILD_PACKAGES[*]} " in
    *" ${dep} "*) continue ;;
    esac
    purge_list+=("${dep}")
  done <"${TARGET}${HYPR_SRC_DIR}/.build-deps"
  if ((${#purge_list[@]} > 0)); then
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get purge -y ${purge_list[*]}
      apt-get autoremove --purge -y
    "
  fi
  in_target "! ldd /usr/bin/* 2>/dev/null | grep -q 'not found'" ||
    fatal "Purge removed libraries a /usr/bin binary needs (ldd reports 'not found')."
  rm -rf "${TARGET}${HYPR_SRC_DIR:?}"
}

# The user's starter config is Hyprland's own example/hyprland.lua at the
# resolved tag — full upstream keybind set, rules, docs — SPLIT into one
# module per upstream section header (---- MONITORS ----, ----
# KEYBINDS ----, ...) and loaded via require() by a small entry file.
# Hyprland sets package.path to the config dir and hot-reload-tracks every
# require()'d file, and the example itself says to split this way. Two
# transformations only:
#   - top-level `local ` is stripped: locals are chunk-scoped and
#     require()'d files are separate chunks, so cross-section variables
#     (mainMod, terminal, ...) must become globals to keep resolving;
#   - the installer's own additions live in hypr-deb.lua, required last.
# No autogenerated marker: the acknowledgment-gated welcome app IS the
# first-run notice. The upstream example is read either from the staged
# Hyprland source tree (online/firstboot source builds — phase_hyprland stages
# it before calling this, and the build-dep purge that deletes the tree runs
# after) or, in the offline prebuilt-deb install, from the installed hyprland
# package at /usr/share/hypr/hyprland.lua.
write_hypr_lua_config() {
  local example="" candidate=""
  for candidate in \
    "${TARGET}${HYPR_SRC_DIR}/hyprland/example/hyprland.lua" \
    "${TARGET}/usr/share/hypr/hyprland.lua"; do
    [[ -f "${candidate}" ]] && { example="${candidate}"; break; }
  done
  [[ -n "${example}" ]] ||
    fatal "Upstream example config not found (neither the staged Hyprland" \
      "source nor the installed /usr/share/hypr/hyprland.lua is present)."
  local cfg_dir="${TARGET}/home/${TARGET_USERNAME}/.config/hypr"
  local entry="${cfg_dir}/hyprland.lua"
  local hdr_re='^-{2,}[[:space:]]+([A-Za-z][A-Za-z[:space:]]*[A-Za-z])[[:space:]]+-{2,}$'
  local line="" section="" slug="" modules=()
  mkdir -p "${cfg_dir}"
  {
    echo "-- Hypr-Deb entry config: upstream example/hyprland.lua split into"
    echo "-- one module per section. Edit the module files in this directory;"
    echo "-- this file only sets the load order."
  } >"${entry}"
  while IFS= read -r line; do
    if [[ "${line}" =~ ${hdr_re} ]]; then
      section="${BASH_REMATCH[1]}"
      slug="$(printf '%s' "${section,,}" | tr -s ' ' '-')"
      modules+=("${slug}")
      printf -- '-- %s (split from upstream example/hyprland.lua)\n' \
        "${section}" >"${cfg_dir}/${slug}.lua"
      continue
    fi
    if [[ -z "${slug}" ]]; then
      # Preamble (before the first section header) stays in the entry file.
      printf '%s\n' "${line}" >>"${entry}"
    else
      # Strip top-level `local ` only; indented locals never crossed files.
      printf '%s\n' "${line#local }" >>"${cfg_dir}/${slug}.lua"
    fi
  done <"${example}"
  ((${#modules[@]} > 0)) ||
    fatal "No section headers found in ${example} — upstream changed the" \
      "example format; the section splitter needs updating."
  # Default app launcher: repoint the upstream example's `$menu` (bound to
  # SUPER+R) at the hyprlauncher we build, instead of the example's default.
  # Done by rewriting the assignment in whichever split module defines it,
  # since the bind captures `menu`'s value at require() time (a later
  # reassignment in hypr-deb.lua would not affect the already-registered bind).
  local menu_mod=""
  for menu_mod in "${cfg_dir}"/*.lua; do
    if grep -qE '^menu[[:space:]]*=' "${menu_mod}"; then
      sed -i 's/^menu\([[:space:]]*=[[:space:]]*\).*/menu\1"hyprlauncher"/' \
        "${menu_mod}"
      break
    fi
  done
  # swww manages the wallpaper, so disable Hyprland's built-in default wallpaper
  # and logo (else the mascot flashes before swww draws). Patch the values in
  # whichever upstream-split module sets them inside its misc config table.
  for menu_mod in "${cfg_dir}"/*.lua; do
    sed -i -E \
      -e 's/(force_default_wallpaper[[:space:]]*=[[:space:]]*)-?[0-9]+/\10/' \
      -e 's/(disable_hyprland_logo[[:space:]]*=[[:space:]]*)(false|true)/\1true/' \
      "${menu_mod}"
  done
  for slug in "${modules[@]}"; do
    printf 'require("%s")\n' "${slug}" >>"${entry}"
  done
  printf 'require("hypr-deb")\n' >>"${entry}"
  cat >"${cfg_dir}/hypr-deb.lua" <<'EOF'
-- Hypr-Deb additions (installer.sh) — kept apart from upstream content.
-- First-run welcome, replacing upstream's autogenerated-config notice.
-- Registered on the hyprland.start event: that is the documented autostart
-- hook (see upstream example/hyprland.lua). A bare top-level hl.exec_cmd
-- fires at config-parse time, before the compositor is up, so the GUI
-- client would have no Wayland display to connect to. The marker lands
-- only when the app exits cleanly (the user closed it), so the welcome
-- keeps appearing until actually acknowledged. Lua long brackets keep the
-- sh quoting sane.
hl.on("hyprland.start", function()
  -- Recover external displays the greeter left HPD-dark. The greetd wrapper
  -- disables non-primary outputs with `wlr-randr --off`; on NVIDIA that drops
  -- the connector's hot-plug detect (kernel marks it `disconnected`), so
  -- Hyprland skips it at start. Forcing a sysfs re-probe makes the kernel
  -- re-detect the sink and the compositor applies the monitor config live.
  -- Needs root (sysfs status write) -> fixed-command NOPASSWD helper, staged by
  -- the installer at /usr/local/bin/drm-reprobe. Fired first so the external
  -- comes up as early as possible.
  hl.exec_cmd("sudo /usr/local/bin/drm-reprobe")
  -- Finalize the UWSM session: activates graphical-session.target, imports
  -- the session environment, and runs XDG autostart. Without this the
  -- session is launched by uwsm but never actually managed by it. Harmless
  -- no-op if the session was not started through uwsm.
  hl.exec_cmd("uwsm finalize")
  -- Wallpaper daemon (swww). Needs the compositor's Wayland session as parent
  -- and ships no unit/.desktop, so it starts from this hook. It restores the
  -- last-set wallpaper from its per-output cache on launch.
  hl.exec_cmd("swww-daemon")
  -- First login only: set an initial wallpaper (swww has no cache yet). After
  -- this, swww-daemon restores the cached selection on every later login.
  hl.exec_cmd([[sh -c 'm="$HOME/.config/hypr/.wallpaper-set"; [ -e "$m" ] || { /usr/local/bin/swww-cycle && touch "$m"; }']])
  hl.exec_cmd([[sh -c 'marker="$HOME/.config/hypr/.welcome-shown"; [ -e "$marker" ] || { /usr/local/bin/hyprland-welcome && touch "$marker"; }']])
end)

-- Default keybinds (installer baseline; the user's chezmoi dotfiles override
-- these). Primary actions are dual chords (SUPER+key), secondary actions are
-- triple chords (SUPER+SHIFT+key).
-- Lock the session on demand; routes through hypridle's lock_cmd -> hyprlock.
hl.bind("SUPER + L", hl.dsp.exec_cmd("loginctl lock-session"))
-- Cycle wallpapers (swww): a different random image per output (secondary
-- action, triple chord).
hl.bind("SUPER + SHIFT + W", hl.dsp.exec_cmd("/usr/local/bin/swww-cycle"))
-- Brightness keys drive brightness-sync: every connected display as one level —
-- real backlight where present (brightnessctl, internal panel and ddcci-exposed
-- externals) else gamma via hypr-dim. locked+repeating so they work on the lock
-- screen and while held. Issue #66.
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightness-sync up"),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightness-sync down"), { locked = true, repeating = true })
-- Screenshots + screen recording (epic #67, item 1): the staged helper scripts
-- linux-screenshot / linux-screen-record (in /usr/local/bin). They save
-- timestamped files (~/Pictures/Screenshots, ~/Videos/Screen Recordings), copy
-- to the clipboard, and hold an atomic lock so repeated presses don't stack
-- selectors. Conventional Print cluster; the user's dotfiles override these.
hl.bind("Print", hl.dsp.exec_cmd("linux-screenshot region"))               -- region -> file + clipboard
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("linux-screenshot monitor"))      -- monitor under pointer
hl.bind("CTRL + Print", hl.dsp.exec_cmd("linux-screenshot full"))          -- all outputs
hl.bind("SUPER + Print", hl.dsp.exec_cmd("linux-screenshot annotate"))     -- region -> swappy annotate
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("linux-screen-record desktop")) -- toggle record (desktop audio)
hl.bind("SUPER + CTRL + R", hl.dsp.exec_cmd("linux-screen-record mic"))     -- toggle record (microphone)
-- Notifications (swaync, epic #67 item 2): toggle the notification-center panel
-- and Do-Not-Disturb. -sw skips waiting for the daemon.
hl.bind("SUPER + N", hl.dsp.exec_cmd("swaync-client -t -sw"))         -- toggle panel
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("swaync-client -d -sw")) -- toggle DND
EOF

  # hyprlock + hypridle default configs (installer baseline). hyprlock auths via
  # PAM (/etc/pam.d/hyprlock, staged in configure_session); hypridle drives the
  # dim -> DPMS-off -> lock idle chain and locks before suspend. Quoted heredocs
  # keep hyprlock's $TIME/$FAIL/$font variables literal.
  cat >"${cfg_dir}/hyprlock.conf" <<'HYPRLOCK_CONF'
# hyprlock — screen locker (issue #71)
# Auth uses PAM via /etc/pam.d/hyprlock (auth include common-auth).

$font = Monospace

general {
    hide_cursor = true
}

# Animations disabled: the fadeIn keeps presenting frames after lock, and each
# frame re-powers the display against hypridle's post-lock `dpms off`, causing a
# visible on/off/on flicker before it settles. Painting once keeps it clean.
animations {
    enabled = false
}

background {
    monitor =
    color = rgb(20, 24, 32)
}

# Clock.
label {
    monitor =
    text = $TIME
    font_size = 64
    font_family = $font
    color = rgba(216, 222, 233, 0.95)
    position = 0, 120
    halign = center
    valign = center
}

input-field {
    monitor =
    size = 280, 50
    outline_thickness = 3
    dots_size = 0.25
    dots_spacing = 0.3
    inner_color = rgba(0, 0, 0, 0.35)
    outer_color = rgba(33ccffee) rgba(00ff99ee) 45deg
    check_color = rgba(00ff99ee) rgba(ff6633ee) 120deg
    fail_color = rgba(ff6633ee) rgba(ff0066ee) 40deg
    font_color = rgb(200, 200, 200)
    fade_on_empty = false
    rounding = 12
    font_family = $font
    placeholder_text = <i>Password…</i>
    fail_text = <i>$FAIL ($ATTEMPTS)</i>
    position = 0, -40
    halign = center
    valign = center
}
HYPRLOCK_CONF
  cat >"${cfg_dir}/hypridle.conf" <<'HYPRIDLE_CONF'
# hypridle — idle management (issue #72)
# Chain: dim 5m -> lock 7m -> DPMS off 8m. Suspend disabled (see below).
#
# Ordering is load-bearing and evidence-backed (hyprlock display-wedge
# investigation, 2026-06-21). LOCK must come BEFORE DPMS-off. If DPMS powers the
# output off while/before hyprlock owns it, the compositor cannot reconcile the
# unlock repaint against a powered-down output: the session authenticates but
# never repaints, leaving a black "frozen" screen recoverable only by a VT
# switch (input and PAM work the whole time — proven; it is purely a display/
# present wedge). Locking while the panel is lit lets hyprlock composite cleanly;
# the DPMS-off then carries a balanced on-resume to re-power on wake. No DPMS-off
# before the lock, and no `&& sleep 1 && dpms off` re-assert against live hyprlock.

general {
    lock_cmd = brightness-sync lock             # internal-only lock (externals off after lock surface is up)
    before_sleep_cmd = loginctl lock-session     # lock before any suspend
    after_sleep_cmd = sleep 2 && hyprctl dispatch 'hl.dsp.dpms("on")'
}

# 5 min — dim ALL connected displays as one level: real backlight where present
# (brightnessctl) else gamma via hypr-dim, saving/restoring levels. Issue #66.
# on-resume actively re-asserts (DPMS/lock can drop the gamma LUT).
listener {
    timeout = 300
    on-timeout = brightness-sync dim
    on-resume = brightness-sync restore
}

# 7 min — lock the session while the panel is still lit, so hyprlock composites
# its surface before anything goes dark.
listener {
    timeout = 420
    on-timeout = loginctl lock-session
}

# 8 min (timeout path) — power the INTERNAL off via per-monitor DPMS, after the lock is
# up. NOT global dpms: the external is held off per-monitor by lock_cmd, and a global
# command on top of that inverts it on this box. The external stays off until unlock
# (lock_cmd re-enables it). on-resume powers the internal back ON, then brightness-sync
# restore reasserts external gamma once DP-3 reports DPMS on (gated; a power-on wipes a
# LUT set while the output is down on this NVIDIA box).
listener {
    timeout = 480
    on-timeout = brightness-sync internal-off
    on-resume = brightness-sync internal-on; brightness-sync restore
}

# When LOCKED, power the screen off after only 60s idle — so a MANUAL lock (you walked
# away) doesn't sit lit for the full 8-min idle path. Gated on hyprlock running, so it
# NEVER fires during normal unlocked idle (that keeps dim 5m / dpms 8m), which preserves
# the load-bearing lock-before-DPMS ordering. Global DPMS (same proven mechanism as the
# 480s listener); on-resume re-powers so you can type your password. The external is
# already off via lock_cmd; this powers off the internal.
listener {
    timeout = 60
    on-timeout = pidof hyprlock >/dev/null 2>&1 && brightness-sync internal-off
    on-resume = brightness-sync internal-on
}

# 30 min — suspend to RAM. DISABLED: this machine only offers s2idle (no deep
# S3), and a live test failed to resume (forced power-off). Re-enable only once
# s2idle resume is verified reliable.
# listener {
#     timeout = 1800
#     on-timeout = systemctl suspend
# }
HYPRIDLE_CONF
  info "User config: ${#modules[@]} upstream modules + hypr-deb.lua" \
    "(${modules[*]})"
}

# Install the distro wallpaper set (the assets/wallpapers shallow submodule) to
# /usr/share/backgrounds/hypr-deb and stage the swww-cycle helper. swww's
# default config sets one on first login and SUPER+SHIFT+W cycles them.
stage_wallpapers() {
  local src="assets/wallpapers"
  local dest="${TARGET}/usr/share/backgrounds/hypr-deb"
  # The set is a shallow submodule. The ISO build checks it out before baking
  # assets onto the medium (build-iso.sh ensure_wallpapers_checked_out), so the
  # offline install always copies it from the local tree below. The git init
  # here is only a convenience for running the installer from a bare clone with
  # a network; success never depends on it.
  if [[ -z "$(ls -A "${src}" 2>/dev/null || true)" ]]; then
    if ((${NETWORK_AVAILABLE:-0})); then
      info "Initializing wallpaper submodule..."
      git submodule update --init --depth 1 "${src}" 2>/dev/null ||
        warn "Wallpaper submodule init failed; skipping default wallpapers."
    else
      warn "Wallpaper submodule absent and offline; skipping default wallpapers."
    fi
  fi
  if [[ -n "$(ls -A "${src}" 2>/dev/null || true)" ]]; then
    info "Installing wallpaper set to /usr/share/backgrounds/hypr-deb..."
    mkdir -p "${dest}"
    # Copy images (preserve subdirs, exclude the submodule's .git pointer file).
    (cd "${src}" && tar -cf - --exclude=.git .) | (cd "${dest}" && tar -xf -)
  fi
  # Wallpaper cycle helper: a different random image per connected output.
  install -d "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/swww-cycle" <<'EOF'
#!/usr/bin/env bash
# swww-cycle (installer.sh): assign a different random wallpaper to each
# connected output from the system wallpaper set. Bound to SUPER+SHIFT+W and
# run once on first login to set an initial wallpaper. Overridable via
# SWWW_WALLPAPER_DIR / SWWW_TRANSITION.
set -euo pipefail
dir="${SWWW_WALLPAPER_DIR:-/usr/share/backgrounds/hypr-deb}"
transition="${SWWW_TRANSITION:-any}"
if ! swww query >/dev/null 2>&1; then
  swww-daemon >/dev/null 2>&1 &
  for _ in $(seq 1 20); do swww query >/dev/null 2>&1 && break; sleep 0.2; done
fi
mapfile -t outputs < <(swww query | awk -F: 'NF>1 { gsub(/ /, "", $2); print $2 }')
[ "${#outputs[@]}" -gt 0 ] || exit 0
mapfile -t imgs < <(find "$dir" -type f \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | shuf)
[ "${#imgs[@]}" -gt 0 ] || exit 0
i=0
for out in "${outputs[@]}"; do
  swww img -o "$out" "${imgs[$(( i % ${#imgs[@]} ))]}" --transition-type "$transition"
  i=$(( i + 1 ))
done
EOF
  chmod +x "${TARGET}/usr/local/bin/swww-cycle"
}

# Stage the screenshot/recording capture helpers (epic #67, item 1; verified on
# the live box, recorded in linux-fixes/fixes.md). Bound to the Print cluster in
# hypr-deb.lua. Both helpers self-create their output dirs and hold an atomic
# selector lock so repeated key presses can't stack concurrent slurp overlays.
# Deviations from the live copy: the record codec defaults to libx264 (software,
# universal) instead of the live box's NVIDIA-only h264_nvenc — overridable via
# SCREEN_RECORD_CODEC. Notifications need a daemon (swaync, #67 item 2); the
# capture still saves the file without one.
stage_capture_helpers() {
  install -d "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/linux-screenshot" <<'EOF'
#!/bin/sh
set -eu

mode=${1:-region}
directory=${XDG_PICTURES_DIR:-"$HOME/Pictures"}/Screenshots
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
output="$directory/screenshot_$timestamp.png"
lock_directory=${XDG_RUNTIME_DIR:-/tmp}/linux-screenshot.lock
raw=

mkdir -p "$directory"

if ! mkdir "$lock_directory" 2>/dev/null; then
    exit 0
fi

cleanup() {
    [ -z "$raw" ] || rm -f "$raw"
    rmdir "$lock_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cursor_monitor_box() {
    # Logical box "X,Y WxH" (slurp coords) of the monitor under the pointer.
    set -- $(hyprctl cursorpos 2>/dev/null | tr -d ',')
    hyprctl monitors -j 2>/dev/null | jq -r --argjson x "${1:-0}" --argjson y "${2:-0}" '
        .[] | select(.x <= $x and $x < (.x + .width / .scale)
                 and .y <= $y and $y < (.y + .height / .scale))
        | "\(.x),\(.y) \((.width / .scale)|floor)x\((.height / .scale)|floor)"' | head -n1
}

select_geometry() {
    if [ -n "${SCREEN_CAPTURE_GEOMETRY:-}" ]; then
        printf '%s\n' "$SCREEN_CAPTURE_GEOMETRY"
        return
    fi

    box=$(cursor_monitor_box)
    case $mode in
        region|annotate)
            # Free click-drag selection. slurp's overlay spans all outputs;
            # it cannot confine a drawn region to one monitor.
            slurp
            ;;
        monitor)
            # Whole monitor under the pointer; no click needed.
            printf '%s\n' "$box"
            ;;
        full)
            printf '%s\n' ""
            ;;
        *)
            printf 'Usage: %s {region|monitor|full|annotate}\n' "$0" >&2
            exit 2
            ;;
    esac
}

geometry=$(select_geometry) || exit 0

if [ "$mode" = annotate ]; then
    raw=$(mktemp --suffix=.png)
    grim -g "$geometry" "$raw"
    swappy -f "$raw" -o "$output"
    [ -s "$output" ] || exit 0
else
    if [ -n "$geometry" ]; then
        grim -g "$geometry" "$output"
    else
        grim "$output"
    fi
fi

wl-copy --type image/png < "$output"
notify-send "Screenshot saved" "$output"
EOF
  chmod +x "${TARGET}/usr/local/bin/linux-screenshot"

  cat >"${TARGET}/usr/local/bin/linux-screen-record" <<'EOF'
#!/bin/sh
set -eu

mode=${1:-desktop}
runtime=${XDG_RUNTIME_DIR:-/tmp}/linux-screen-record
pid_file=$runtime/pid
output_file=$runtime/output
selection_lock=$runtime/selection.lock
directory="${XDG_VIDEOS_DIR:-"$HOME/Videos"}/Screen Recordings"

mkdir -p "$runtime" "$directory"

stop_recording() {
    pid=$(cat "$pid_file" 2>/dev/null || true)
    output=$(cat "$output_file" 2>/dev/null || true)
    command_line=

    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
        command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
        printf '%s\n' "$command_line" | grep -q 'wf-recorder'; then
        kill -INT "$pid"
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.1
        done
        notify-send "Screen recording saved" "$output"
    else
        notify-send "Screen recording" "Removed stale recorder state."
    fi

    rm -f "$pid_file" "$output_file"
}

if [ -f "$pid_file" ]; then
    stop_recording
    exit 0
fi

if ! mkdir "$selection_lock" 2>/dev/null; then
    exit 0
fi

cleanup_selection() {
    rmdir "$selection_lock" 2>/dev/null || true
}
trap cleanup_selection EXIT HUP INT TERM

case $mode in
    desktop)
        sink=$(pactl get-default-sink)
        audio_source=$sink.monitor
        label="desktop audio"
        ;;
    mic)
        audio_source=$(pactl get-default-source)
        label="microphone"
        ;;
    *)
        printf 'Usage: %s {desktop|mic}\n' "$0" >&2
        exit 2
        ;;
esac

if [ -n "${SCREEN_CAPTURE_GEOMETRY:-}" ]; then
    geometry=$SCREEN_CAPTURE_GEOMETRY
else
    geometry=$(slurp) || exit 0
fi
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
output="$directory/screen_recording_$timestamp.mkv"
codec=${SCREEN_RECORD_CODEC:-libx264}

wf-recorder \
    -g "$geometry" \
    --audio="$audio_source" \
    -c "$codec" \
    -f "$output" \
    -y \
    >/dev/null 2>&1 &
pid=$!

printf '%s\n' "$pid" > "$pid_file"
printf '%s\n' "$output" > "$output_file"

sleep 0.5
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file" "$output_file"
    notify-send "Screen recording failed" "wf-recorder exited during startup."
    exit 1
fi

cleanup_selection
trap - EXIT HUP INT TERM
notify-send "Screen recording started" "Region capture with $label. Press the same shortcut to stop."
EOF
  chmod +x "${TARGET}/usr/local/bin/linux-screen-record"
}

# Stage the swaync (sway-notification-center) config (epic #67, item 2). The
# Debian package ships + auto-enables swaync.service via graphical-session.target
# .wants, so this only writes the user config. Authored from linux-fixes/fixes.md
# (no tracked original existed). style.css matches the installer's window accent
# (#33ccff->#00ff99 45deg gradient, as in hyprlock); the chown -R in the Hyprland
# phase gives the user ownership. Mako is intentionally never installed.
stage_swaync_config() {
  local sw_dir="${TARGET}/home/${TARGET_USERNAME}/.config/swaync"
  install -d "${sw_dir}"
  cat >"${sw_dir}/config.json" <<'EOF'
{
  "$schema": "/etc/xdg/swaync/configSchema.json",
  "positionX": "right",
  "positionY": "bottom",
  "layer": "overlay",
  "control-center-layer": "top",
  "layer-shell": true,
  "cssPriority": "application",
  "timeout": 5,
  "timeout-low": 5,
  "timeout-critical": 0,
  "fit-to-screen": true,
  "control-center-width": 400,
  "control-center-height": 600,
  "notification-window-width": 400,
  "keyboard-shortcuts": true,
  "image-visibility": "when-available",
  "transition-time": 200,
  "hide-on-clear": false,
  "hide-on-action": true,
  "text-empty": "No Notifications",
  "widgets": [
    "title",
    "dnd",
    "mpris",
    "notifications"
  ],
  "widget-config": {
    "title": {
      "text": "Notifications",
      "clear-all-button": true,
      "button-text": "Clear All"
    },
    "dnd": {
      "text": "Do Not Disturb"
    },
    "mpris": {
      "image-size": 96,
      "image-radius": 8
    }
  }
}
EOF
  cat >"${sw_dir}/style.css" <<'EOF'
/* swaync style — installer baseline (epic #67, item 2).
 * Matches the installer's window accent: 45deg #33ccff->#00ff99 gradient border
 * (as in hyprlock), dark card #1e1e2e / text #f5f5f5. GTK3 CSS (swaync links
 * libgtk-3) cannot gradient a rounded border-color, so the frame is a gradient
 * background clipped to
 * border-box behind a transparent 2px border, with the dark fill clipped to
 * padding-box. Card rounding 8px = window rounding + 2px border. */

@keyframes swaync-fadein {
  from { opacity: 0; }
  to   { opacity: 1; }
}

.notification-row {
  background: transparent;
}

.notification {
  margin: 6px;
  border-radius: 8px;
  border: 2px solid transparent;
  background-image:
    linear-gradient(#1e1e2e, #1e1e2e),
    linear-gradient(45deg, #33ccff, #00ff99);
  background-origin: border-box;
  background-clip: padding-box, border-box;
  animation: swaync-fadein 200ms ease-in;
}

.notification.critical {
  box-shadow: inset 0 0 0 1px #ff3355;
}

.notification-content {
  padding: 8px;
  border-radius: 6px;
}

.notification .summary {
  color: #f5f5f5;
  font-weight: bold;
}

.notification .body,
.notification .time {
  color: #f5f5f5;
}

.control-center {
  border-radius: 8px;
  border: 2px solid transparent;
  background-image:
    linear-gradient(#1e1e2e, #1e1e2e),
    linear-gradient(45deg, #33ccff, #00ff99);
  background-origin: border-box;
  background-clip: padding-box, border-box;
}

.control-center .notification {
  margin: 6px;
}
EOF
}

configure_session() {
  info "Configuring greetd + uwsm session..."
  # greetd leaves the session's stdout/stderr attached to VT1, so uwsm and
  # Hyprland startup chatter paints over the console during the greeter →
  # desktop handoff (issue #12). Both session paths route through this
  # wrapper: systemd-cat keeps the output in the journal (read it with
  # `journalctl -t hypr-session`) instead of the VT, and
  # UWSM_SILENT_START=2 suppresses uwsm's own startup text.
  mkdir -p "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/hypr-session" <<'EOF'
#!/usr/bin/env bash
# Staged by installer.sh: greetd session entry. Session output goes to
# the journal (journalctl -t hypr-session), never to the VT.
UWSM_SILENT_START=2 exec /usr/bin/systemd-cat -t hypr-session \
  /usr/bin/uwsm start -- hyprland.desktop
EOF
  chmod +x "${TARGET}/usr/local/bin/hypr-session"
  mkdir -p "${TARGET}/etc/greetd" "${TARGET}/etc/greetd/sessions"
  local session_command="" session_user=""
  if ((HYPR_AUTOLOGIN)); then
    # No greeter: greetd starts the session directly as the target user.
    session_command="/usr/local/bin/hypr-session"
    session_user="${TARGET_USERNAME}"
  else
    # Debian ships the greetd daemon WITHOUT any greeter binary (agreety
    # is not packaged despite its manpage); tuigreet provides the login
    # prompt. Resolve its real path at install time — greetd spawns the
    # greeter with no PATH (PAM env only), so absolute paths are required.
    local greeter=""
    greeter="$(in_target "command -v tuigreet")" ||
      fatal "tuigreet not found in target (TARGET_BASE_PACKAGES should install it)."
    # The greeter runs inside cage (a single-client kiosk Wayland compositor)
    # rather than straight on VT1, so a wrapper can do two things the bare
    # tuigreet-on-VT1 setup cannot:
    #
    #   1. Restrict the login to one display. tuigreet is a TUI, not a
    #      Wayland client, so it is hosted inside kitty; cage gives kitty a
    #      compositor + DRM and brings every connected output up. The wrapper
    #      then disables (via wlr-randr) every output except the one cage
    #      anchored at 0,0, so the prompt appears on a single screen. The rest
    #      light up after login under Hyprland's own monitor config.
    #   2. Keep the console clean at handoff. cage hands its child tty1 as
    #      stdio, AND kitty writes its glfw/xkb/sRGB/portal warnings to that
    #      controlling terminal (not fd 1/2) — so they buffer on VT1 and flash
    #      the instant cage exits and the VT returns to text mode (issue #12's
    #      cousin). The wrapper routes its own stdout/stderr to the journal
    #      (journalctl -t greeter), keeping the VT text buffer empty.
    #      Redirecting ABOVE cage does not work: cage re-establishes tty1 as
    #      the child's controlling terminal, so the redirect must live here,
    #      inside the wrapper.
    #
    # The static body (redirect + output selection) is written under a quoted
    # heredoc so its bash stays literal; the launch line is appended under an
    # interpolating heredoc to inject the resolved tuigreet path.
    cat >"${TARGET}/etc/greetd/greeter-displays.sh" <<'EOF'
#!/usr/bin/env bash
# Staged by installer.sh: greetd greeter wrapper, run as cage's Wayland
# client. Keeps the login on the primary display and the greeter's console
# chatter in the journal (journalctl -t greeter), never on VT1.
set -u

# cage gives this process tty1 as stdio and kitty writes diagnostics to that
# controlling terminal; route everything to the journal so the VT text buffer
# stays empty and nothing flashes when cage exits at the greeter → desktop
# handoff.
exec > >(/usr/bin/systemd-cat -t greeter) 2>&1

# Keep only the output cage anchored at 0,0; switch the rest off so the prompt
# shows on a single display.
current=""
declare -a others=()
while IFS= read -r line; do
  if [[ "$line" =~ ^([A-Za-z0-9._-]+)[[:space:]] ]]; then
    current="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ Position:[[:space:]]([0-9]+),([0-9]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != 0 || "${BASH_REMATCH[2]}" != 0 ]]; then
      others+=("$current")
    fi
  fi
done < <(/usr/bin/wlr-randr)
for o in "${others[@]}"; do
  /usr/bin/wlr-randr --output "$o" --off
done

EOF
    # tuigreet flags (mirrors the bare-VT setup, now inside the wrapper):
    # --asterisks (its default echoes nothing, reads as broken input on a
    # console with redraw jitter); --sessions points at our curated one-entry
    # dir so tuigreet does not scan ${XDG_DATA_DIRS}/wayland-sessions, where
    # the uwsm/Hyprland source builds drop hyprland*.desktop entries that
    # bypass the silencing wrapper (issue #12); --cmd is omitted so the lone
    # curated session is the default. The power menu uses absolute systemctl
    # paths + --power-no-setsid so it works without a PATH (issue #49).
    cat >>"${TARGET}/etc/greetd/greeter-displays.sh" <<EOF
exec /usr/bin/kitty --class greeter \\
  -o background=#000000 -o foreground=#cccccc \\
  -o cursor_blink_interval=0 -o confirm_os_window_close=0 \\
  -- ${greeter} --remember --asterisks --sessions /etc/greetd/sessions \\
     --power-no-setsid \\
     --power-shutdown '/usr/bin/systemctl poweroff' \\
     --power-reboot '/usr/bin/systemctl reboot'
EOF
    chmod +x "${TARGET}/etc/greetd/greeter-displays.sh"
    # greetd launches the greeter through cage; -s allows VT switching.
    # Absolute paths only (greetd provides no PATH to its children).
    session_command="/usr/bin/cage -s -- /etc/greetd/greeter-displays.sh"
    session_user="_greetd"
  fi
  # The sole greeter session: launches the silent, uwsm-managed wrapper.
  cat >"${TARGET}/etc/greetd/sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland (uwsm-managed, silenced)
Exec=/usr/local/bin/hypr-session
Type=Application
DesktopNames=Hyprland
EOF
  cat >"${TARGET}/etc/greetd/config.toml" <<EOF
[terminal]
vt = 1

[default_session]
# Absolute paths are required: greetd builds the session environment from
# PAM, and Debian's default stack provides no PATH for it.
command = "${session_command}"
user = "${session_user}"
EOF
  # NVIDIA session environment (issue #4): uwsm sources ~/.config/uwsm/env
  # into the systemd user session before Hyprland starts. These are the
  # Hyprland-wiki variables for NVIDIA GPUs; the chown -R below covers the
  # file's ownership.
  if nvidia_install_requested; then
    mkdir -p "${TARGET}/home/${TARGET_USERNAME}/.config/uwsm"
    cat >"${TARGET}/home/${TARGET_USERNAME}/.config/uwsm/env" <<'EOF'
# Managed by hypr-deb (issue #4): NVIDIA environment for the Hyprland
# session. Sourced by uwsm into the systemd user environment.
export LIBVA_DRIVER_NAME=nvidia
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export GBM_BACKEND=nvidia-drm
EOF
  fi
  # External-display recovery (DP-3 HPD-dark after login). The greeter wrapper
  # disables every non-primary output with `wlr-randr --output <conn> --off`.
  # On NVIDIA that disable leaves the connector hot-plug-detect dark: the kernel
  # reports it `disconnected`, so Hyprland enumerates nothing on it at session
  # start and the external stays off (the wrapper's "Hyprland re-enables them"
  # assumption is false here). Force a sysfs re-probe at hyprland.start (wired in
  # write_hypr_lua_config); the running compositor consumes the resulting uevent
  # live. Proven on the live box: a single `echo detect` recovered the LG
  # ultrawide on DP-3 in ~2s with no restart. The status write needs root, so
  # ship a fixed-command NOPASSWD helper.
  install -d "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/drm-reprobe" <<'EOF'
#!/usr/bin/env bash
# Staged by installer.sh: force a DRM hot-plug re-probe of external connectors
# the greeter left HPD-dark, so Hyprland re-detects them at login. eDP (the
# built-in panel) is skipped — it is never disabled. No-op on a connector that
# already reads `connected`, so it never disturbs a healthy display.
set -u
for path in /sys/class/drm/card*-*/status; do
  name=${path%/status}; name=${name##*/}
  case "$name" in *eDP*) continue ;; esac
  if [[ "$(cat "$path" 2>/dev/null)" == disconnected ]]; then
    echo detect > "$path" 2>/dev/null || true
  fi
done
EOF
  chmod 755 "${TARGET}/usr/local/bin/drm-reprobe"
  # NOPASSWD for the single fixed command (no args) -> minimal privilege; the
  # hyprland.start hook runs it as ${TARGET_USERNAME} via sudo (user is in the
  # sudo group, and Debian's /etc/sudoers @includedir's /etc/sudoers.d).
  install -d -m 755 "${TARGET}/etc/sudoers.d"
  cat >"${TARGET}/etc/sudoers.d/drm-reprobe" <<EOF
# Managed by installer.sh: let the desktop user force a DRM connector re-probe
# at Hyprland start, recovering an external display the greeter disabled.
${TARGET_USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/drm-reprobe
EOF
  chmod 440 "${TARGET}/etc/sudoers.d/drm-reprobe"
  # hyprlock PAM service (issue #71): authenticate the lock screen against the
  # system stack. hypridle (issue #72) is enabled for the user by linking its
  # unit into graphical-session.target.wants — a plain symlink (not `systemctl
  # --global enable`) so it works even when the stack is built at first boot:
  # the link dangles until the unit lands and resolves at session start.
  mkdir -p "${TARGET}/etc/pam.d"
  cat >"${TARGET}/etc/pam.d/hyprlock" <<'EOF'
# PAM config for hyprlock (installer.sh, issue #71).
auth     include common-auth
account  include common-account
password include common-password
session  include common-session
EOF
  # External-display brightness subsystem (issue #66). brightness-sync drives
  # ONE logical level across every connected display: a real hardware backlight
  # where present (brightnessctl — internal panel, and external monitors exposed
  # as /sys/class/backlight by ddcci-dkms over DDC/CI) else GAMMA via the resident
  # hypr-dim daemon (D-Bus dev.hyprdim). The brightness keys, hypridle's idle
  # dim/restore, and the lock_cmd all route through it. Staged like drm-reprobe
  # (literal heredoc + chmod). The hypr-dim binary is built by build_custom_hypr_dim.
  install -d "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/brightness-sync" <<'BRIGHTNESS_SYNC'
#!/bin/sh
# brightness-sync — ONE logical brightness level (0-100) across every connected
# display. The level is PERSISTED and applied ABSOLUTELY, so all displays stay
# locked together (no rail-drift) and a hotplugged display can be snapped to the
# current level. Issue #66.
#
# Per display, the control method is detected, not assumed:
#   - a real hardware backlight (/sys/class/backlight) mapped to the connector
#     (ddcci reverse-symlink, embedded-panel heuristic, or ddcci<bus> on the
#     connector's i2c bus) -> brightnessctl -d <node>
#   - else GAMMA via the resident hypr-dim daemon (D-Bus dev.hyprdim).
# Internal backlight keeps the perceptual -e4 curve; gamma 0..1 ~ that curve, so
# level N reads about the same on both (e.g. 85 ~ perceptual 0.85 ~ gamma 0.85).
#
#   up | down [no arg]   adjust level by STEP and apply to all
#   set <pct>            set level and apply to all
#   reconcile            re-apply current level to all (boot / hotplug)
#   dim                  save level, drop to DIM, apply
#   restore              re-apply the saved pre-dim level
set -eu

SVC=dev.hyprdim
IFACE=dev.hyprdim
DRM="${BS_DRM:-/sys/class/drm}"
BL="${BS_BL:-/sys/class/backlight}"
RUN="${XDG_RUNTIME_DIR:-/tmp}"
LEVEL_FILE="${BS_LEVEL:-$RUN/brightness-sync.level}"
DIM_SAVE="${BS_DIMSAVE:-$RUN/brightness-sync.dimsave}"
STEP=5; MIN=5; DIM=10

daemon_up() { busctl --user status "$SVC" >/dev/null 2>&1; }

connected_connectors() {
    for _d in "$DRM"/card*-*; do
        [ -r "$_d/status" ] || continue
        [ "$(cat "$_d/status" 2>/dev/null)" = connected ] || continue
        basename "$_d" | sed 's/^card[0-9]*-//'
    done
}
_is_internal() { case "$1" in eDP*|LVDS*|DSI*) return 0 ;; *) return 1 ;; esac; }

_i2c_bus_via_ddc() {
    for _d in "$DRM"/card*-"$1"; do
        [ -e "$_d/ddc" ] || continue
        _t=$(readlink -f "$_d/ddc" 2>/dev/null) || continue
        _n=$(printf '%s\n' "$_t" | grep -oE 'i2c-[0-9]+' | tail -n1)
        [ -n "$_n" ] && { printf '%s\n' "${_n#i2c-}"; return 0; }
    done
    return 1
}
_ddcci_backlight_on_bus() {
    _bus=$1
    for _b in "$BL"/ddcci*; do
        [ -e "$_b/type" ] || continue
        _dev=$(readlink -f "$_b/device" 2>/dev/null) || continue
        _bn=$(printf '%s\n' "$_dev" | grep -oE 'i2c-[0-9]+' | tail -n1)
        [ "${_bn#i2c-}" = "$_bus" ] && { basename "$_b"; return 0; }
    done
    for _b in "$BL"/ddcci"$_bus" "$BL"/ddcci"$_bus"[ie]*; do
        [ -e "$_b/type" ] && { basename "$_b"; return 0; }
    done
    return 1
}
backlight_for_connector() {
    _conn=$1; [ -n "$_conn" ] || return 1
    for _d in "$DRM"/card*-"$_conn"; do
        [ -e "$_d/ddcci_backlight" ] && {
            basename "$(readlink -f "$_d/ddcci_backlight")"; return 0; }
    done
    if ! _is_internal "$_conn"; then
        if _bus=$(_i2c_bus_via_ddc "$_conn"); then
            _bl=$(_ddcci_backlight_on_bus "$_bus") && { printf '%s\n' "$_bl"; return 0; }
        fi
    fi
    if _is_internal "$_conn"; then
        _best=""; _rank=99
        for _b in "$BL"/*; do
            [ -e "$_b/type" ] || continue
            _name=$(basename "$_b"); case "$_name" in ddcci*) continue ;; esac
            case "$(cat "$_b/type" 2>/dev/null)" in
                firmware) _r=0 ;; platform) _r=1 ;; raw) _r=2 ;; *) _r=3 ;;
            esac
            [ "$_r" -lt "$_rank" ] && { _rank=$_r; _best=$_name; }
        done
        [ -n "$_best" ] && { printf '%s\n' "$_best"; return 0; }
    fi
    return 1
}
method_for() {
    if _node=$(backlight_for_connector "$1"); then printf 'backlight:%s\n' "$_node"
    else printf 'gamma\n'; fi
}
_gamma_obj() { printf '/outputs/%s\n' "$(printf '%s' "$1" | tr '-' '_')"; }
g_set() { busctl --user set-property "$SVC" "$1" "$IFACE" Brightness d "$2"; }


clamp() {
    _v=$1; case "$_v" in ''|*[!0-9-]*) _v=100 ;; esac
    [ "$_v" -lt "$MIN" ] && _v=$MIN; [ "$_v" -gt 100 ] && _v=100; printf '%s' "$_v"
}

# Seed the logical level from the internal backlight's real value (perceptual,
# matching -e4: perceptual = (raw/max)^(1/4)) so the first keypress doesn't jump.
_seed_level() {
    for _c in $(connected_connectors); do
        _is_internal "$_c" || continue
        _n=$(backlight_for_connector "$_c") || _n=""
        [ -n "$_n" ] && [ -r "$BL/$_n/brightness" ] && [ -r "$BL/$_n/max_brightness" ] || continue
        _cur=$(cat "$BL/$_n/brightness" 2>/dev/null); _max=$(cat "$BL/$_n/max_brightness" 2>/dev/null)
        case "$_cur:$_max" in *[!0-9:]*|:*|*:) continue ;; esac
        [ "$_max" -gt 0 ] || continue
        awk -v c="$_cur" -v m="$_max" 'BEGIN{ p=((c/m)^0.25)*100; p=(p<5?5:(p>100?100:p)); printf "%d", p+0.5 }'
        return 0
    done
    printf '100'
}
get_level() {
    _v=""; [ -r "$LEVEL_FILE" ] && _v=$(cat "$LEVEL_FILE" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) _v=$(_seed_level) ;; esac
    printf '%s' "$_v"
}
set_level() { printf '%s' "$1" > "$LEVEL_FILE"; }

_apply_conn() {  # CONN LEVEL
    _conn=$1; _lvl=$2; _m=$(method_for "$_conn"); _kind=${_m%%:*}; _ref=${_m#*:}
    case "$_kind" in
        backlight) brightnessctl -d "$_ref" -e4 -n2 set "${_lvl}%" >/dev/null 2>&1 || true ;;
        gamma)
            daemon_up || return 0
            _f=$(awk -v l="$_lvl" 'BEGIN{printf "%.2f", l/100}')
            # epsilon force-write: a re-apply equal to the daemon's cached value
            # is a no-op, but DPMS/lock can reset the LUT under it.
            _eps=$(awk -v f="$_f" 'BEGIN{ if (f>0.001) printf "%.3f", f-0.001; else printf "%.3f", f+0.001 }')
            _o=$(_gamma_obj "$_conn"); g_set "$_o" "$_eps"; g_set "$_o" "$_f" ;;
    esac
}
apply_level() {  # LEVEL -> every connected display
    _l=$1
    connected_connectors | while IFS= read -r _c; do _apply_conn "$_c" "$_l"; done
}
apply_level_internal() {  # LEVEL -> internal/backlight displays only; externals via daemon Restore
    _l=$1
    connected_connectors | while IFS= read -r _c; do
        case "$(method_for "$_c")" in backlight:*) _apply_conn "$_c" "$_l" ;; esac
    done
}
_nudge_conn() {  # CONN SIGN(+|-) — move ONE display by STEP relative to its own value
    _conn=$1; _sign=$2; _m=$(method_for "$_conn"); _kind=${_m%%:*}; _ref=${_m#*:}
    case "$_kind" in
        backlight) brightnessctl -d "$_ref" -e4 -n2 set "${STEP}%${_sign}" >/dev/null 2>&1 || true ;;
        gamma)
            daemon_up || return 0
            _o=$(_gamma_obj "$_conn")
            _cur=$(busctl --user get-property "$SVC" "$_o" "$IFACE" Brightness 2>/dev/null | awk '{print $2}')
            case "$_cur" in ''|*[!0-9.]*) _cur=1 ;; esac
            # relative step with a floor of MIN% and ceiling 1.0 — never drive the
            # external to absolute black via the keys (mirrors the internal's -n2 floor).
            _new=$(awk -v c="$_cur" -v s="$STEP" -v g="$_sign" -v m="$MIN" \
                'BEGIN{ n=c+(g=="-"?-s/100:s/100); lo=m/100; if(n<lo)n=lo; if(n>1)n=1; printf "%.2f", n }')
            busctl --user set-property "$SVC" "$_o" "$IFACE" Brightness d "$_new" >/dev/null 2>&1 || true ;;
    esac
}
nudge() {  # SIGN(+|-) -> move every connected display by STEP (synced CHANGE; each keeps its own value)
    connected_connectors | while IFS= read -r _c; do _nudge_conn "$_c" "$1"; done
}
_dim_conn() {  # CONN — lower toward DIM%, but NEVER raise (idle dim only darkens)
    _conn=$1; _m=$(method_for "$_conn"); _kind=${_m%%:*}; _ref=${_m#*:}
    case "$_kind" in
        # internal: DIM% maps to the -n2 floor, so a plain set can only darken it.
        backlight) brightnessctl -d "$_ref" -e4 -n2 set "${DIM}%" >/dev/null 2>&1 || true ;;
        gamma)
            daemon_up || return 0
            _o=$(_gamma_obj "$_conn")
            _cur=$(busctl --user get-property "$SVC" "$_o" "$IFACE" Brightness 2>/dev/null | awk '{print $2}')
            case "$_cur" in ''|*[!0-9.]*) _cur=1 ;; esac
            _dimf=$(awk -v d="$DIM" 'BEGIN{printf "%.2f", d/100}')
            # only dim if already brighter than the dim level (don't brighten a darker display)
            if [ "$(awk -v c="$_cur" -v df="$_dimf" 'BEGIN{print (c>df)?1:0}')" = 1 ]; then
                g_set "$_o" "$_dimf"
            fi ;;
    esac
}
dim_all() {  # lower every connected display toward DIM, never raising one already darker
    connected_connectors | while IFS= read -r _c; do _dim_conn "$_c"; done
}

_dpms_set() {  # ACTION(disable|enable) WHICH(internal|external) -> DPMS matching connected displays.
    # Per-monitor only — NEVER global dpms: a global command on top of a per-monitor-disabled
    # output comes out INVERTED on this box (global-off flips the held-off external back on).
    _act=$1; _which=$2
    connected_connectors | while IFS= read -r _c; do
        if [ "$_which" = internal ]; then _is_internal "$_c" || continue
        else _is_internal "$_c" && continue; fi
        hyprctl dispatch "hl.dsp.dpms({ action = \"$_act\", monitor = \"$_c\" })" >/dev/null 2>&1 || true
    done
}

cmd="${1:-}"
case "$cmd" in
    up)        nudge + ;;
    down)      nudge - ;;
    set)       _L=$(clamp "${2:-$(get_level)}");        set_level "$_L"; apply_level "$_L" ;;
    reconcile) apply_level "$(get_level)" ;;
    dim)       if [ ! -e "$DIM_SAVE" ]; then
                   _seed_level > "$DIM_SAVE"   # internal's ACTUAL pre-dim level, not the (key-stale) shared file
                   daemon_up && busctl --user call "$SVC" / "$IFACE" Snapshot >/dev/null 2>&1 || true
               fi
               set_level "$DIM"; dim_all ;;
    restore)   # externals: the daemon re-applies each display's remembered value, and
               # again on the DPMS-on reconnect, so no DPMS gating is needed here.
               daemon_up && busctl --user call "$SVC" / "$IFACE" Restore >/dev/null 2>&1 || true
               if [ -r "$DIM_SAVE" ]; then
                   _L=$(cat "$DIM_SAVE"); set_level "$_L"; apply_level_internal "$_L"; rm -f "$DIM_SAVE"
               fi ;;
    lock)      # lock the session with only the internal lit: start hyprlock, wait for its
               # lock surface to come up (else powering the external off races startup and
               # leaves it on-black), then power off non-internal displays. On unlock
               # (hyprlock exits) power them back on. Used as hypridle's lock_cmd.
               pidof hyprlock >/dev/null 2>&1 && exit 0
               hyprlock & _h=$!
               _i=0; while [ "$_i" -lt 40 ] && ! pidof hyprlock >/dev/null 2>&1; do _i=$((_i+1)); sleep 0.05; done
               sleep 0.5
               _dpms_set disable external
               wait "$_h" || true
               _dpms_set enable external ;;
    externals-off) _dpms_set disable external ;;   # power off non-internal displays
    externals-on)  _dpms_set enable external ;;    # power them back on
    internal-off)  _dpms_set disable internal ;;   # power off internal display(s)
    internal-on)   _dpms_set enable internal ;;    # power them back on
    *) echo "usage: brightness-sync {up|down|set <pct>|dim|restore|reconcile|lock|externals-off|externals-on|internal-off|internal-on}" >&2; exit 2 ;;
esac
BRIGHTNESS_SYNC
  chmod 755 "${TARGET}/usr/local/bin/brightness-sync"
  # hypr-dim user unit. The ExecStart points at the compiled binary in /usr/bin
  # (upstream's unit uses %h/.local/bin/hypr-dim). Resident, supervised,
  # respawning; brightness-sync re-asserts external gamma after a restart. Enabled
  # for the user the same way hypridle is: a plain symlink into
  # graphical-session.target.wants (works even when the stack builds at first boot —
  # the link dangles until the unit lands and resolves at session start).
  mkdir -p "${TARGET}/usr/local/lib/systemd/user"
  cat >"${TARGET}/usr/local/lib/systemd/user/hypr-dim.service" <<'HYPR_DIM_SERVICE'
[Unit]
Description=hypr-dim — per-display gamma brightness daemon (external outputs)
# Locally-built daemon (binary hypr-dim, D-Bus dev.hyprdim). Source, upstream
# provenance and rebuild script (build-install.sh) live in ~/src/gamma-fix.
# Driven by the `brightness-sync` wrapper to dim external displays. Issue #66.
PartOf=graphical-session.target
After=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=/usr/bin/hypr-dim
# Resident, supervised: always respawn. State (per-output gamma) is in memory
# only, and a gamma_control Failed permanently drops an output — restart is the
# recovery path; `brightness-sync restore` re-asserts levels afterward.
Restart=always
RestartSec=1

[Install]
WantedBy=graphical-session.target
HYPR_DIM_SERVICE
  mkdir -p "${TARGET}/etc/systemd/user/graphical-session.target.wants"
  # hypridle is part of the source-compiled stack, now shipped as a .deb with
  # prefix /usr, so its user unit lands at /usr/lib/systemd/user (FHS). The
  # hand-written hypr-dim.service below stays in /usr/local (installer glue,
  # not owned by any .deb).
  ln -sf /usr/lib/systemd/user/hypridle.service \
    "${TARGET}/etc/systemd/user/graphical-session.target.wants/hypridle.service"
  ln -sf /usr/local/lib/systemd/user/hypr-dim.service \
    "${TARGET}/etc/systemd/user/graphical-session.target.wants/hypr-dim.service"
  write_hypr_lua_config
  stage_wallpapers
  stage_capture_helpers
  stage_swaync_config
  in_target "
    set -e
    # Fail the build if the drm-reprobe sudoers drop-in is malformed rather than
    # shipping a broken (or privilege-widening) rule into the target.
    /usr/sbin/visudo -c -f /etc/sudoers.d/drm-reprobe >/dev/null
    chown -R '${TARGET_USERNAME}:${TARGET_USERNAME}' '/home/${TARGET_USERNAME}'
    # tuigreet --remember writes its cache as _greetd; the Debian package
    # does not create the directory, and a greeter that cannot write it
    # can crash-loop (repaint storm, swallowed keystrokes on VT1).
    install -d -o _greetd -g _greetd /var/cache/tuigreet
    systemctl enable greetd
    # greetd owns VT1; an unmasked getty@tty1 (or logind's autovt@tty1)
    # attaches to the same terminal and fights the greeter for keystrokes.
    systemctl mask getty@tty1.service
    systemctl set-default graphical.target
  "
}

# --- First-boot deferral (--build-on-firstboot) ------------------------------

# Shared firstboot machinery: a per-job directory so independent features
# (Hyprland build, ZFS upgrade, future NVIDIA detect — issue #4) each
# stage one script instead of growing a monolith. Jobs run lexically,
# pre-login (Before=greetd). Success renames the job .done; failure
# renames it .failed and the boot CONTINUES — jobs must leave the system
# usable when they fail. The unit disables itself once no runnable jobs
# remain; a job requests a reboot by touching /run/hypr-deb-reboot-required.
stage_firstboot_runner() {
  # The enable runs UNCONDITIONALLY (it is idempotent): a resumed run that
  # died between writing the files and enabling the unit must still enable
  # it, so only the file-writing is skipped when the runner exists.
  if [[ ! -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot" ]]; then
    mkdir -p "${TARGET}/usr/local/sbin" \
      "${TARGET}/usr/local/lib/hypr-deb/firstboot.d" \
      "${TARGET}/etc/systemd/system"
    cat >"${TARGET}/usr/local/sbin/hypr-deb-firstboot" <<'EOF'
#!/usr/bin/env bash
# Hypr-Deb firstboot job runner (staged by installer.sh). Runs every
# /usr/local/lib/hypr-deb/firstboot.d/*.sh in lexical order.
set -uo pipefail
dir=/usr/local/lib/hypr-deb/firstboot.d
shopt -s nullglob
for job in "${dir}"/*.sh; do
  echo "hypr-deb-firstboot: running ${job##*/}" >&2
  if bash "${job}"; then
    mv "${job}" "${job%.sh}.done"
  else
    mv "${job}" "${job%.sh}.failed"
    echo "hypr-deb-firstboot: JOB FAILED: ${job##*/} — system left as-is;" \
      "inspect the journal, then re-run with: bash ${job%.sh}.failed" >&2
  fi
done
remaining=("${dir}"/*.sh)
if ((${#remaining[@]} == 0)); then
  systemctl disable hypr-deb-firstboot.service
fi
if [[ -f /run/hypr-deb-reboot-required ]]; then
  rm -f /run/hypr-deb-reboot-required
  systemctl reboot
fi
EOF
    chmod +x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"

    cat >"${TARGET}/etc/systemd/system/hypr-deb-firstboot.service" <<'EOF'
[Unit]
Description=Hypr-Deb first-boot jobs
Before=greetd.service
ConditionPathExists=/usr/local/sbin/hypr-deb-firstboot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hypr-deb-firstboot
StandardOutput=journal+console
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  fi
  in_target "systemctl enable hypr-deb-firstboot.service"
}

stage_firstboot() {
  info "Staging first-boot build..."
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}" "${TARGET}/usr/local/lib/hypr-deb"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    stage_source "${name}"
  done
  install_build_deps # toolchain present so firstboot works offline

  # Authoritative manifest so the staged resolve_all_tags works offline. Lives
  # next to the staged source trees (${HYPR_SRC_DIR}/sources), a target-internal
  # path — NOT the removed install-time cache. The firstboot runner sets
  # CACHE_DIR=${HYPR_SRC_DIR} so resolve_all_tags reads it from here.
  local manifest="${TARGET}${HYPR_SRC_DIR}/sources/MANIFEST"
  mkdir -p "${TARGET}${HYPR_SRC_DIR}/sources"
  : >"${manifest}"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    echo "${name} ${HYPR_RESOLVED_TAG["${name}"]}" >>"${manifest}"
  done

  cp lib/00-config.sh lib/01-log.sh scripts/60-hyprland.sh \
    "${TARGET}/usr/local/lib/hypr-deb/"

  stage_firstboot_runner
  cat >"${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh" <<EOF
#!/usr/bin/env bash
# Firstboot job: one-shot Hyprland build (staged by installer.sh).
set -euo pipefail
source /usr/local/lib/hypr-deb/00-config.sh
source /usr/local/lib/hypr-deb/01-log.sh
source /usr/local/lib/hypr-deb/60-hyprland.sh
TARGET=""           # build on the running system
NETWORK_AVAILABLE=0 # sources are pre-staged; no network needed
CACHE_DIR="${HYPR_SRC_DIR}"
KEEP_BUILD_DEPS=${KEEP_BUILD_DEPS}
resolve_all_tags
check_compat "\${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
for name in "\${HYPR_BUILD_ORDER[@]}"; do
  build_one "\${name}"
done
test -x /usr/bin/Hyprland
purge_build_deps
info "First-boot Hyprland build complete."
EOF
  chmod +x "${TARGET}/usr/local/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
}

# OFFLINE (default when the on-ISO store is present): install the ENTIRE custom
# stack from the temporary trusted file:// source that phase_bootstrap stood up
# (setup_target_iso_repo). No toolchain, no source compile, no firstboot — the
# shipped debs are already the newest (freshness is a build-time concern). The
# deb data trees (binaries in /usr/bin, the example config in /usr/share/hypr)
# land here, so configure_session reads the installed example afterwards.
install_prebuilt_stack() {
  info "Installing prebuilt Hyprland stack from the on-ISO repo" \
    "(${#HYPR_BUILD_ORDER[@]} packages)..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${HYPR_BUILD_ORDER[*]}
  "
  in_target "test -x /usr/bin/Hyprland" ||
    fatal "Hyprland binary missing after prebuilt-stack install."
  # uwsm is the session entrypoint (greetd -> hypr-session -> uwsm); without it
  # greetd boots to a dead greeter. Verify it landed, same as build_stack does.
  in_target "test -x /usr/bin/uwsm" ||
    fatal "uwsm binary missing after prebuilt-stack install (the session would not launch)."
}

# --online: when the on-ISO/cache repo is present, install whatever custom-stack
# debs it provides (the same temporary trusted file:// source + bind machinery as
# the offline path) and record them in HYPR_PREBUILT_INSTALLED so build_stack
# source-builds only the components the repo did NOT provide. No repo, or nothing
# available, leaves the full gcc-15 source build to handle everything.
online_install_prebuilt() {
  HYPR_PREBUILT_INSTALLED=()
  if ! cache_repo_exists; then
    info "No on-ISO/cache repo present; source-building the whole stack."
    return 0
  fi
  info "On-ISO repo present (${CACHE_REPO_DIR}); installing available prebuilt" \
    "stack debs (source build covers any the repo lacks)..."
  setup_target_iso_repo
  in_target "apt-get update"
  local name="" avail=()
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    if in_target "apt-cache show '${name}' >/dev/null 2>&1"; then
      avail+=("${name}")
      HYPR_PREBUILT_INSTALLED["${name}"]=1
    fi
  done
  if ((${#avail[@]} > 0)); then
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y ${avail[*]}
    "
    info "Installed prebuilt debs: ${avail[*]}"
  fi
}

phase_hyprland() {
  # DEFAULT / --offline: install the prebuilt stack from the on-ISO store and
  # skip the entire source-build machinery. The compatibility gate (check_compat)
  # is a SOURCE-build guard needing Hyprland's CMakeLists, which offline mode does
  # not stage — so it is skipped here. configure_session still runs (it writes the
  # user config, reading the example from the just-installed hyprland deb).
  if ((NETWORK_AVAILABLE == 0)); then
    install_prebuilt_stack
    configure_session
    return 0
  fi
  # --online (network present): keep the source-build path. Resolve tags, stage
  # Hyprland for the gate + example config, then build/defer as before — but first
  # install any prebuilt custom debs the ISO repo offers so only the missing ones
  # are compiled.
  resolve_all_tags
  # The gate needs Hyprland's CMakeLists; stage hyprland's source first.
  stage_source hyprland
  check_compat "${TARGET}${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
  # Session config before the build: it copies the upstream example
  # config out of the staged source tree, which purge_build_deps deletes.
  configure_session
  if ((BUILD_ON_FIRSTBOOT)); then
    stage_firstboot
  else
    online_install_prebuilt
    if ((${#HYPR_PREBUILT_INSTALLED[@]} >= ${#HYPR_BUILD_ORDER[@]})); then
      # Every component came from a prebuilt deb: no toolchain, no compile.
      info "All custom stack components installed from prebuilt debs;" \
        "skipping the source build."
      in_target "test -x /usr/bin/Hyprland" ||
        fatal "Hyprland binary missing after prebuilt-stack install."
      in_target "test -x /usr/bin/uwsm" ||
        fatal "uwsm binary missing after prebuilt-stack install (the session would not launch)."
    else
      build_stack
      purge_build_deps
    fi
  fi
}
