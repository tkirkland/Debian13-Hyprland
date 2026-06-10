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

HYPR_SRC_DIR="/var/tmp/hypr-deb-build"

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
    git clone --depth 1 --branch "${tag}" --recurse-submodules \
      --shallow-submodules "${HYPR_REPO_URL[${name}]}" "${dest}"
  else
    fatal "No cached source for ${name} ${tag} and no network."
  fi
}

install_build_deps() {
  # gcc-15 lives only in sid; add the pinned source when networked.
  # Offline, the cache repo already carries the toolchain debs.
  if ((NETWORK_AVAILABLE)); then
    write_sid_toolchain_sources "${TARGET}"
    in_target "apt-get update"
  fi
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${HYPR_BUILD_PACKAGES[*]}
  "
  # Record exactly what we may purge later.
  printf '%s\n' "${HYPR_BUILD_PACKAGES[@]}" \
    >"${TARGET}${HYPR_SRC_DIR}/.build-deps"
}

# Builds CMake projects (the hyprwm stack) and meson projects (xkbcommon,
# wayland-protocols, uwsm).
build_one() {
  local name="$1"
  local meson_args="${HYPR_MESON_ARGS[${name}]:-}"
  info "Building ${name} ${HYPR_RESOLVED_TAG[${name}]}..."
  in_target "
    set -e
    export CC='${HYPR_CC}' CXX='${HYPR_CXX}'
    cd '${HYPR_SRC_DIR}/${name}'
    if [[ -f CMakeLists.txt ]]; then
      cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local
      cmake --build build -j\"\$(nproc)\"
      cmake --install build
    elif [[ -f meson.build ]]; then
      meson setup build --prefix=/usr/local --buildtype=release ${meson_args}
      meson install -C build
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
    stage_source "${name}"
    build_one "${name}"
  done
  in_target "test -x /usr/local/bin/Hyprland" ||
    fatal "Hyprland binary missing after build."
}

purge_build_deps() {
  if ((KEEP_BUILD_DEPS)); then
    info "--keep-build-deps: leaving toolchain installed."
    return 0
  fi
  info "Pinning runtime libraries of built binaries..."
  in_target "
    set -e
    ldd /usr/local/bin/Hyprland /usr/local/lib/lib*.so* 2>/dev/null |
      grep -oE '/[^ ]+\.so[^ ]*' | sort -u |
      xargs -r -n1 -- realpath 2>/dev/null | sort -u |
      xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u |
      xargs -r apt-mark manual
  "
  info "Purging build dependencies (cached debs remain in ${TARGET_CACHE_DIR})..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    xargs -a '${HYPR_SRC_DIR}/.build-deps' apt-get purge -y
    apt-get autoremove --purge -y
  "
  in_target "! ldd /usr/local/bin/Hyprland | grep -q 'not found'" ||
    fatal "Purge removed libraries Hyprland needs (ldd reports 'not found')."
  rm -rf "${TARGET}${HYPR_SRC_DIR:?}"
}

configure_session() {
  info "Configuring greetd + uwsm session..."
  mkdir -p "${TARGET}/etc/greetd"
  cat >"${TARGET}/etc/greetd/config.toml" <<'EOF'
[terminal]
vt = 1

[default_session]
command = "agreety --cmd 'uwsm start -- hyprland.desktop'"
user = "_greetd"
EOF
  # Minimal valid Hyprland config for the user.
  mkdir -p "${TARGET}/home/${TARGET_USERNAME}/.config/hypr"
  cat >"${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.conf" <<'EOF'
# Minimal Hypr-Deb starter config.
monitor = ,preferred,auto,1
$mod = SUPER
bind = $mod, Return, exec, kitty
bind = $mod, Q, killactive,
bind = $mod SHIFT, E, exit,
EOF
  in_target "
    set -e
    chown -R '${TARGET_USERNAME}:${TARGET_USERNAME}' '/home/${TARGET_USERNAME}'
    systemctl enable greetd
    systemctl set-default graphical.target
  "
}

# --- First-boot deferral (--build-on-firstboot) ------------------------------

stage_firstboot() {
  info "Staging first-boot build..."
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}" "${TARGET}/usr/local/lib/hypr-deb"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    stage_source "${name}"
  done
  install_build_deps  # toolchain present so firstboot works offline

  # Authoritative manifest so the staged resolve_all_tags works offline.
  local manifest="${TARGET}${TARGET_CACHE_DIR}/sources/MANIFEST"
  mkdir -p "${TARGET}${TARGET_CACHE_DIR}/sources"
  : >"${manifest}"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    echo "${name} ${HYPR_RESOLVED_TAG["${name}"]}" >>"${manifest}"
  done

  cp lib/00-config.sh lib/01-log.sh scripts/60-hyprland.sh \
    "${TARGET}/usr/local/lib/hypr-deb/"

  cat >"${TARGET}/usr/local/sbin/hypr-deb-firstboot" <<EOF
#!/usr/bin/env bash
# One-shot first-boot Hyprland build (staged by hypr-deb.sh).
set -euo pipefail
source /usr/local/lib/hypr-deb/00-config.sh
source /usr/local/lib/hypr-deb/01-log.sh
source /usr/local/lib/hypr-deb/60-hyprland.sh
TARGET=""           # build on the running system
NETWORK_AVAILABLE=0 # sources are pre-staged; no network needed
CACHE_DIR="${TARGET_CACHE_DIR}"
KEEP_BUILD_DEPS=${KEEP_BUILD_DEPS}
resolve_all_tags
check_compat "\${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
for name in "\${HYPR_BUILD_ORDER[@]}"; do
  build_one "\${name}"
done
test -x /usr/local/bin/Hyprland
purge_build_deps
systemctl disable hypr-deb-firstboot.service
info "First-boot Hyprland build complete."
EOF
  chmod +x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"

  cat >"${TARGET}/etc/systemd/system/hypr-deb-firstboot.service" <<'EOF'
[Unit]
Description=Hypr-Deb first-boot Hyprland build
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
  in_target "systemctl enable hypr-deb-firstboot.service"
}

phase_hyprland() {
  resolve_all_tags
  # The gate needs Hyprland's CMakeLists; stage hyprland's source first.
  stage_source hyprland
  check_compat "${TARGET}${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
  if ((BUILD_ON_FIRSTBOOT)); then
    stage_firstboot
  else
    build_stack
    purge_build_deps
  fi
  configure_session
}
