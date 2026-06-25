# shellcheck shell=bash
# Build-time only: turn a source component into a pooled .deb, gated by an
# upstream-vs-cached freshness check. Sourced by tools/build-iso.sh on a
# networked trixie/amd64 build host. NOT used at install time.

# Release tag (vX.Y.Z | X.Y.Z) -> Debian version X.Y.Z-1.
tag_to_debver() {
  local tag="${1#v}"
  printf '%s-1\n' "${tag}"
}
