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

# Stage a control file into DESTDIR and build pool/<name>_<ver>_<arch>.deb.
# Echoes the resulting .deb path. DESTDIR must already contain the installed tree.
package_to_deb() {
  local destdir="$1" name="$2" version="$3" arch="$4" depends="$5" pool="$6"
  write_control "${destdir}" "${name}" "${version}" "${arch}" "${depends}" \
    "${HYPR_DEB_CONFLICTS[${name}]:-}" "${HYPR_DEB_REPLACES[${name}]:-}" \
    "${HYPR_DEB_PROVIDES[${name}]:-}"
  mkdir -p "${pool}"
  local out="${pool}/${name}_${version}_${arch}.deb"
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
