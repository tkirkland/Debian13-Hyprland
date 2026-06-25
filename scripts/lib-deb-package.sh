# shellcheck shell=bash
# Build-time only: turn a source component into a pooled .deb, gated by an
# upstream-vs-cached freshness check. Sourced by tools/build-iso.sh on a
# networked trixie/amd64 build host. NOT used at install time.

# Release tag (vX.Y.Z | X.Y.Z) -> Debian version X.Y.Z-1.
tag_to_debver() {
  local tag="${1#v}"
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
