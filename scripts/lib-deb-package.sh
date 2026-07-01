# shellcheck shell=bash
# Build-time only: turn a source component into a pooled .deb, gated by an
# upstream-vs-cached freshness check. Sourced by tools/build-iso.sh on a
# networked trixie/amd64 build host. NOT used at install time.

if ! declare -f info >/dev/null; then info(){ printf '%s\n' "$*" >&2; }; fi

# Optional per-package control metadata, looked up by package_to_deb. Declared
# here (no-op if 00-config.sh already populated them) so referencing a missing
# key is safe under `set -u` even when this lib is used standalone.
declare -gA HYPR_DEB_CONFLICTS HYPR_DEB_REPLACES HYPR_DEB_PROVIDES

# Release tag -> Debian version X.Y.Z-1. Strips any leading non-digit prefix so
# the version starts with a digit (dpkg requirement). Tags seen: v0.49.0,
# 1.2.3, xkbcommon-1.13.2 (prefixed). Same prefix-strip idiom as check_compat.
tag_to_debver() {
  local tag="$1"
  tag="${tag#"${tag%%[0-9]*}"}"
  printf '%s-1\n' "${tag}"
}

# Highest Debian version of <name>_<ver>_<arch>.deb present in pool dir $1
# for package $2. Empty string if none. Uses dpkg --compare-versions so the
# ordering is correct (not lexical).
cached_deb_version() {
  command -v dpkg >/dev/null 2>&1 || {
    echo "cached_deb_version: dpkg not found (build-time/trixie-host only)" >&2
    return 1
  }
  local pool="$1" name="$2" best="" ver=""
  local f base
  for f in "${pool}/${name}"_*.deb; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    ver="${base#"${name}"_}"
    ver="${ver%_*.deb}"
    if [[ -z "${best}" ]] || dpkg --compare-versions "${ver}" gt "${best}"; then
      best="${ver}"
    fi
  done
  printf '%s\n' "${best}"
}

# Exit 0 (rebuild) when no cached .deb exists or upstream ($3) is strictly
# greater than the cached version; exit 1 (reuse cached) otherwise.
deb_needs_rebuild() {
  local pool="$1" name="$2" upstream="$3" cached
  cached="$(cached_deb_version "${pool}" "${name}")"
  [[ -n "${cached}" ]] || return 0
  dpkg --compare-versions "${upstream}" gt "${cached}"
}

# Write a minimal DEBIAN/control under DESTDIR ($1). Depends ($5) may be empty.
# conflicts ($6), replaces ($7), provides ($8) are optional; each emits its line
# only when non-empty. Used so source-compiled wayland/xkbcommon can own /usr
# with the same soname paths as (and supersede) the Debian library packages.
write_control() {
  local destdir="$1" name="$2" version="$3" arch="$4" depends="$5"
  local conflicts="${6:-}" replaces="${7:-}" provides="${8:-}"
  mkdir -p "${destdir}/DEBIAN"
  {
    printf 'Package: %s\n' "${name}"
    printf 'Version: %s\n' "${version}"
    printf 'Architecture: %s\n' "${arch}"
    printf 'Maintainer: Debian13-Hyprland build <build@localhost>\n'
    [[ -n "${depends}" ]] && printf 'Depends: %s\n' "${depends}"
    [[ -n "${conflicts}" ]] && printf 'Conflicts: %s\n' "${conflicts}"
    [[ -n "${replaces}" ]] && printf 'Replaces: %s\n' "${replaces}"
    [[ -n "${provides}" ]] && printf 'Provides: %s\n' "${provides}"
    printf 'Section: x11\n'
    printf 'Priority: optional\n'
    printf 'Description: %s (built from source by the offline-ISO pipeline)\n' "${name}"
  } >"${destdir}/DEBIAN/control"
}

# Turn a comma-separated Provides list into a VERSIONED one ("a, b" -> "a (= V),
# b (= V)"). Debian only satisfies a VERSIONED dependency (e.g. slurp Depends
# "libwayland-client0 (>= 1.20.0)") from a VERSIONED Provides; an unversioned
# Provides does not count. V is the upstream version (Debian revision stripped).
_versioned_provides() {
  local list="$1" ver="$2" out="" p
  local IFS=','
  for p in ${list}; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -n "${p}" ]] || continue
    out="${out:+${out}, }${p} (= ${ver})"
  done
  printf '%s' "${out}"
}

# Union of package names our OWN debs satisfy via Provides (the source-compiled
# wayland/xkbcommon supersede Debian's libwayland-*/libxkbcommon*). Auto-derived
# deps naming these must be dropped: Debian's superseded libs are deliberately
# kept out of the offline pool, and our debs satisfy the reverse-deps via a
# versioned Provides. Derived from HYPR_DEB_PROVIDES so adding a Provides
# automatically extends the filter. Emits a space-delimited, space-bounded set
# (" a b c ") for `[[ "${set}" == *" ${name} "* ]]` membership tests.
_self_provided_names() {
  local key tok out=" "
  local IFS=','
  for key in "${!HYPR_DEB_PROVIDES[@]}"; do
    for tok in ${HYPR_DEB_PROVIDES[${key}]}; do
      tok="${tok#"${tok%%[![:space:]]*}"}"
      tok="${tok%"${tok##*[![:space:]]}"}"
      [[ -n "${tok}" ]] && out+="${tok} "
    done
  done
  printf '%s' "${out}"
}

# Build-host only. Derive the real shared-library Depends of the staged ELF tree
# under DESTDIR ($1) via dpkg-shlibdeps. Echoes a bare "pkg (>= ver), ..." string
# (empty on failure). No-op (rc 0, no output) when dpkg-shlibdeps is absent, so
# the Windows dev host and the fake-driven suite fall back to HYPR_DEB_DEPENDS.
# -l <staged libdirs>: resolve the package's OWN bundled sonames (libhyprutils,
#   our compiled wayland/xkbcommon) internally -> no spurious external dep.
# --ignore-missing-info: a still-unresolved internal soname warns, never aborts.
# --admindir: dpkg-shlibdeps maps soname->package via this dpkg db; the -dev/
#   runtime soname packages live in the BUILDROOT (${TARGET}), not the host, so
#   point there when TARGET is set (override with HYPR_SHLIBDEPS_ADMINDIR).
shlibdeps_scan() {
  local destdir="$1" arch="${2:-${ARCH:-amd64}}"
  command -v dpkg-shlibdeps >/dev/null 2>&1 || return 0
  [[ -d "${destdir}/usr" ]] || return 0
  local -a elves=() f
  while IFS= read -r -d '' f; do
    LC_ALL=C head -c4 "${f}" 2>/dev/null | grep -qa $'\x7fELF' && elves+=("${f}")
  done < <(find "${destdir}/usr" -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)
  ((${#elves[@]})) || return 0
  # dpkg-shlibdeps wants the private-lib dir ATTACHED to -l (-l<dir>, NOT -l <dir>);
  # a separate token is parsed as a binary to analyze ("Is a directory" error).
  local -a libdirs=("-l${destdir}/usr/lib") d
  for d in "${destdir}"/usr/lib/*-linux-gnu; do
    [[ -d "${d}" ]] && libdirs+=("-l${d}")
  done
  local admindir="${HYPR_SHLIBDEPS_ADMINDIR:-${TARGET:+${TARGET}/var/lib/dpkg}}"
  local -a admin=()
  [[ -n "${admindir}" ]] && admin=(--admindir="${admindir}")
  local work out
  work="$(mktemp -d)"
  mkdir -p "${work}/debian"
  # dpkg-shlibdeps reads ./debian/control (CWD) for the package name+arch; the
  # 3-line stub is the minimum. It lives in a throwaway dir, never in the .deb.
  printf 'Source: hypr-deb\nPackage: hypr-deb\nArchitecture: %s\n' "${arch}" \
    >"${work}/debian/control"
  out="$(cd "${work}" && dpkg-shlibdeps -O --ignore-missing-info \
    "${admin[@]}" "${libdirs[@]}" "${elves[@]}" 2>/dev/null \
    | sed -n 's/^shlibs:Depends=//p')"
  rm -rf "${work}"
  printf '%s' "${out}"
}

# Drop tokens whose package name is one our own debs Provide (see
# _self_provided_names). Input/output are "pkg (>= v), pkg2, ..." Depends strings.
_strip_self_provided() {
  local deps="$1" tok name out="" provided
  provided="$(_self_provided_names)"
  local IFS=','
  for tok in ${deps}; do
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [[ -n "${tok}" ]] || continue
    name="${tok%% *}"
    [[ "${provided}" == *" ${name} "* ]] && continue
    out="${out:+${out}, }${tok}"
  done
  printf '%s' "${out}"
}

# Merge a manual Depends string ($1) with an auto-derived one ($2), de-duped by
# package NAME with the MANUAL token winning (keeps the curated swww/hyprdim
# entries, which our wayland Provides satisfies, over an auto duplicate).
_merge_depends() {
  local auto="$2" tok name seen=" " out="" combined="$1"
  [[ -n "${auto}" ]] && combined="${combined:+${combined}, }${auto}"
  local IFS=','
  for tok in ${combined}; do
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [[ -n "${tok}" ]] || continue
    name="${tok%% *}"
    [[ "${seen}" == *" ${name} "* ]] && continue
    seen+="${name} "
    out="${out:+${out}, }${tok}"
  done
  printf '%s' "${out}"
}

# Stage a control file into DESTDIR and build pool/<name>_<ver>_<arch>.deb.
# Echoes the resulting .deb path. DESTDIR must already contain the installed tree.
package_to_deb() {
  local destdir="$1" name="$2" version="$3" arch="$4" depends="$5" pool="$6"
  local provides="${HYPR_DEB_PROVIDES[${name}]:-}"
  [[ -n "${provides}" ]] && provides="$(_versioned_provides "${provides}" "${version%-*}")"
  # Auto-derive real shared-lib deps from the staged ELF tree (build host only;
  # no-op without dpkg-shlibdeps). Strip libs our debs supersede, then merge with
  # the hand-curated HYPR_DEB_DEPENDS entry (manual wins). Fixes silent runtime
  # failures from undeclared deps (e.g. Hyprland needing libre2-11; issue #82).
  local auto
  auto="$(_strip_self_provided "$(shlibdeps_scan "${destdir}" "${arch}")")"
  [[ -n "${auto}" ]] && depends="$(_merge_depends "${depends}" "${auto}")"
  write_control "${destdir}" "${name}" "${version}" "${arch}" "${depends}" \
    "${HYPR_DEB_CONFLICTS[${name}]:-}" "${HYPR_DEB_REPLACES[${name}]:-}" \
    "${provides}"
  mkdir -p "${pool}"
  local out="${pool}/${name}_${version}_${arch}.deb"
  # Strip debug symbols from the staged ELF tree before packaging: shrinks all
  # ~21 hyprwm C/C++ components (and the Rust release binaries, harmlessly) in
  # one pass. --strip-unneeded (NOT --strip-all) preserves .dynsym so the copy
  # of this tree into the buildroot /usr (tools/build-iso.sh) still links for
  # later stack components. Confined to executables and shared objects so static
  # archives (liblua.a) and non-ELF files are never touched; strip no-ops on any
  # non-ELF match via the redirect/|| true.
  find "${destdir}/usr" -type f \( -perm -u+x -o -name '*.so*' \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true
  dpkg-deb --root-owner-group --build "${destdir}" "${out}" >/dev/null
  printf '%s\n' "${out}"
}

# Build-time: compile component $1 into a .deb in pool $2, skipping the compile
# when a cached .deb is already at/above upstream. Relies on
# resolve_latest_release_tag/stage_source/build_one (scripts/60-hyprland.sh) and
# config maps HYPR_REPO_URL/HYPR_TAG_PATTERN/HYPR_DEB_DEPENDS/ARCH. Chroot/DESTDIR
# wiring for the build root is completed in Phase 3.
build_component_to_deb() {
  local name="$1" pool="$2" tag debver destdir out
  tag="$(resolve_latest_release_tag "${HYPR_REPO_URL[${name}]}" "${HYPR_TAG_PATTERN[${name}]:-}")"
  debver="$(tag_to_debver "${tag}")"
  if ! deb_needs_rebuild "${pool}" "${name}" "${debver}"; then
    info "reuse cached ${name} ${debver} (upstream not newer)"
    return 0
  fi
  HYPR_RESOLVED_TAG["${name}"]="${tag}"
  stage_source "${name}"
  destdir="$(mktemp -d)"
  HYPR_DESTDIR="${destdir}" build_one "${name}"
  out="$(package_to_deb "${destdir}" "${name}" "${debver}" "${ARCH}" "${HYPR_DEB_DEPENDS[${name}]:-}" "${pool}")"
  rm -rf "${destdir}"
  info "packaged ${out}"
}
