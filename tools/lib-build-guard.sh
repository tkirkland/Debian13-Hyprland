# shellcheck shell=bash
# Host-safety guards for the offline-ISO build. Sourced by tools/build-iso.sh.
# These are the PRIMARY protection for the build host (the operator's working
# Debian machine): every guard is fatal-on-violation (returns nonzero so the
# caller aborts) and must verify the build only ever touches a throwaway
# WORKSPACE, never "/", "/usr", "/etc", "/var", and only via a real chroot.

# Standalone-sourceable for tests: provide minimal info/fatal if the real
# logging lib (lib/01-log.sh) is not in effect. Same guard idiom as
# scripts/60-hyprland.sh uses for in_target.
if ! declare -f info >/dev/null 2>&1; then
  info() { printf '%s\n' "$*" >&2; }
fi
if ! declare -f fatal >/dev/null 2>&1; then
  fatal() {
    printf '[FATAL] %s\n' "$*" >&2
    exit 1
  }
fi

# _path_strictly_under PATH BASE...
# Return 0 iff (canonical) PATH is a strict descendant of one of the given
# absolute bases. Equality with a base does not count (we never operate on the
# scratch root itself). Bases are canonicalized with realpath -m.
_path_strictly_under() {
  local p="${1}"
  shift
  local b breal
  for b in "$@"; do
    [[ "${b}" == /* ]] || continue
    breal="$(realpath -m -- "${b}")"
    if [[ "${p}" != "${breal}" && "${p}/" == "${breal}/"* ]]; then
      return 0
    fi
  done
  return 1
}

# assert_build_sandbox WORKSPACE TARGET
# Fatal (return 1) unless TARGET is a non-empty absolute path strictly inside a
# non-empty absolute WORKSPACE, AND WORKSPACE resolves strictly under an
# allowlisted throwaway scratch base (default: /var/tmp /tmp; override via
# HYPR_BUILD_ALLOWED_BASES). A positive allowlist is used deliberately: a
# blacklist of exact system roots (/usr, /var, ...) still accepts subdirectories
# like /usr/local/x or /var/lib/x, under which a --confirm build would
# debootstrap / bind-mount / rm -rf inside the host tree. Uses realpath -m so it
# works before the directories exist.
assert_build_sandbox() {
  local workspace="${1:-}" target="${2:-}"
  local wreal treal

  if [[ -z "${workspace}" ]]; then
    info "build-guard: WORKSPACE is empty"
    return 1
  fi
  if [[ "${workspace}" != /* ]]; then
    info "build-guard: WORKSPACE must be absolute: '${workspace}'"
    return 1
  fi
  if [[ -z "${target}" ]]; then
    info "build-guard: TARGET is empty"
    return 1
  fi
  if [[ "${target}" != /* ]]; then
    info "build-guard: TARGET must be absolute: '${target}'"
    return 1
  fi

  wreal="$(realpath -m -- "${workspace}")"
  treal="$(realpath -m -- "${target}")"

  local -a allowed_bases
  read -r -a allowed_bases <<<"${HYPR_BUILD_ALLOWED_BASES:-/var/tmp /tmp}"
  if ! _path_strictly_under "${wreal}" "${allowed_bases[@]}"; then
    info "build-guard: WORKSPACE '${wreal}' must be strictly under an allowed scratch base (${allowed_bases[*]})"
    return 1
  fi

  if [[ "${treal}" == "${wreal}" ]]; then
    info "build-guard: TARGET must not equal WORKSPACE: '${treal}'"
    return 1
  fi
  if [[ "${treal}/" != "${wreal}/"* ]]; then
    info "build-guard: TARGET '${treal}' is not strictly inside WORKSPACE '${wreal}'"
    return 1
  fi

  return 0
}

# assert_stage_under_target TARGET STAGE_REL
# Fatal (return 1) unless the host-side staging path ${TARGET}${STAGE_REL}
# resolves strictly inside TARGET. STAGE_REL (e.g. BUILD_STAGE_REL) is a
# chroot-internal absolute path that is concatenated RAW onto TARGET for the
# host-side rm -rf/mkdir in step_build_stack; an operator-overridable traversal
# value such as '/../../../etc' would otherwise escape the buildroot and let a
# host rm -rf/mkdir hit /etc, /usr or /var. realpath -m collapses any '..' so
# the containment check holds before the directories exist.
assert_stage_under_target() {
  local target="${1:-}" stagerel="${2:-}"
  local treal sreal

  if [[ -z "${target}" ]]; then
    info "build-guard: TARGET is empty"
    return 1
  fi
  if [[ "${target}" != /* ]]; then
    info "build-guard: TARGET must be absolute: '${target}'"
    return 1
  fi
  if [[ -z "${stagerel}" ]]; then
    info "build-guard: STAGE_REL is empty"
    return 1
  fi
  if [[ "${stagerel}" != /* ]]; then
    info "build-guard: STAGE_REL must be a chroot-internal absolute path: '${stagerel}'"
    return 1
  fi

  treal="$(realpath -m -- "${target}")"
  sreal="$(realpath -m -- "${target}${stagerel}")"

  if [[ "${sreal}" == "${treal}" ]]; then
    info "build-guard: stage path must not equal TARGET: '${treal}'"
    return 1
  fi
  if [[ "${sreal}/" != "${treal}/"* ]]; then
    info "build-guard: stage path '${sreal}' escapes TARGET '${treal}'"
    return 1
  fi

  return 0
}

# assert_chrooted_in_target
# Fatal (return 1) unless the in-effect in_target function is the
# chroot-backed variant (its body contains the token 'chroot'), NOT the
# no-chroot fallback that would run build commands directly on the host.
assert_chrooted_in_target() {
  if declare -f in_target >/dev/null 2>&1 &&
    declare -f in_target | grep -q 'chroot'; then
    return 0
  fi
  info "build-guard: in_target is not the chroot-backed variant; refusing to run build on host"
  return 1
}

# require_root
# Fatal (return 1) unless running as root; debootstrap/chroot need it.
require_root() {
  if ((EUID == 0)); then
    return 0
  fi
  info "build-guard: must run as root (EUID=${EUID})"
  return 1
}
