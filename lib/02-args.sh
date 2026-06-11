# shellcheck shell=bash
# shellcheck disable=SC2034  # parse_args assigns cross-module globals owned
# by lib/00-config.sh and consumed by the orchestrator and phase modules.
# Usage text, argument parsing, and interactive prompts.

VALID_PHASES="full preflight cache storage bootstrap system boot hyprland verify cleanup"
RUN_PHASE="full"

usage() {
  cat <<'EOF'
Usage: hypr-deb.sh [options]

Installs Debian 13 (trixie) onto the fixed three-disk ZFS/mdadm layout and
builds Hyprland from latest release tags. DESTROYS the target disks.

Options:
  --bootloader=<zbm|grub|systemd-boot>
                        Bootloader to install (prompted interactively if
                        omitted; required with --yes / non-interactive runs)
  --build-on-firstboot  Defer the Hyprland build to first boot of the target
  --offline             Force offline mode (install only from the cache)
  --phase=<name>        Run a single phase:
                        preflight cache storage bootstrap system boot
                        hyprland verify cleanup
  --keep-build-deps     Do not purge build dependencies after success
  --skip-cache          Do not populate or embed the offline cache (saves
                        several GB; the installed system loses offline
                        rebuild capability)
  --zfs-from-source     Build OpenZFS from its latest release tag as native
                        Debian packages instead of trixie's zfs-* (network
                        required; live env still creates the pool with the
                        distro version's feature set)
  --autologin           Boot straight into the Hyprland session as the
                        target user (no tuigreet console login)
  --jobs=<n>            Cap build parallelism (default: one per CPU);
                        lower it if compiles exhaust RAM
  --mirror=<url>        Debian mirror (default http://deb.debian.org/debian)
  --cache-dir=<path>    Cache location (default /var/cache/hypr-deb)
  --fresh               Discard phase state and start over
  --yes                 Unattended mode: skips the destructive confirmation
                        and refuses to reach any later prompt — requires
                        --bootloader and the USER_PASSWORD env var
  --verbose             Detailed logging
  --help                This text
EOF
}

parse_args() {
  local arg=""
  for arg in "$@"; do
    case "${arg}" in
      --bootloader=*)
        BOOTLOADER="${arg#*=}"
        case "${BOOTLOADER}" in
          zbm | grub | systemd-boot) ;;
          *) fatal "Invalid --bootloader '${BOOTLOADER}' (zbm|grub|systemd-boot)" ;;
        esac
        ;;
      --build-on-firstboot) BUILD_ON_FIRSTBOOT=1 ;;
      --offline) OFFLINE=1 ;;
      --phase=*)
        RUN_PHASE="${arg#*=}"
        [[ " ${VALID_PHASES} " == *" ${RUN_PHASE} "* ]] ||
          fatal "Unknown phase '${RUN_PHASE}'. Valid: ${VALID_PHASES}"
        ;;
      --keep-build-deps) KEEP_BUILD_DEPS=1 ;;
      --skip-cache) SKIP_CACHE=1 ;;
      --zfs-from-source) ZFS_FROM_SOURCE=1 ;;
      --autologin) HYPR_AUTOLOGIN=1 ;;
      --jobs=*)
        HYPR_BUILD_JOBS="${arg#*=}"
        [[ "${HYPR_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
          fatal "--jobs expects a positive integer, got '${HYPR_BUILD_JOBS}'"
        ;;
      --mirror=*) MIRROR="${arg#*=}" ;;
      --cache-dir=*) CACHE_DIR="${arg#*=}" ;;
      --fresh) FRESH=1 ;;
      --yes) ASSUME_YES=1 ;;
      --verbose) VERBOSE=1 ;;
      --help)
        usage
        exit 0
        ;;
      *) fatal "Unknown option '${arg}' (see --help)" ;;
    esac
  done
}

# Ensure BOOTLOADER is set: prompt when interactive, fail fast otherwise.
require_bootloader_choice() {
  [[ -n "${BOOTLOADER}" ]] && return 0
  if ((!IS_INTERACTIVE)) || ((ASSUME_YES)); then
    fatal "--bootloader=<zbm|grub|systemd-boot> is required in non-interactive runs"
  fi
  local choice=""
  echo "Select a bootloader:"
  echo "  1) zbm           ZFSBootMenu — boots snapshots/datasets directly"
  echo "  2) grub          GRUB (reads kernel copies from the ESP)"
  echo "  3) systemd-boot  systemd-boot (reads kernel copies from the ESP)"
  while true; do
    read -r -p "Choice [1-3]: " choice || fatal "No input (EOF) while selecting bootloader."
    case "${choice}" in
      1) BOOTLOADER="zbm" ;;
      2) BOOTLOADER="grub" ;;
      3) BOOTLOADER="systemd-boot" ;;
      *) continue ;;
    esac
    break
  done
  info "Bootloader: ${BOOTLOADER}"
}

# Destructive gate. Lists the disks about to be destroyed.
confirm_destruction() {
  ((ASSUME_YES)) && return 0
  ((IS_INTERACTIVE)) ||
    fatal "Refusing destructive run without --yes in a non-interactive session"
  echo ""
  echo "  *** ALL DATA on these disks will be DESTROYED ***"
  echo "      DISK1=${DISK1}"
  echo "      DISK2=${DISK2}"
  echo "      DISK3=${DISK3}"
  echo "      Mode: $([[ "${VIRT_TYPE}" == "none" ]] && echo "BARE METAL" ||
    echo "VM (${VIRT_TYPE})")"
  echo ""
  local answer=""
  read -r -p "Type 'destroy' to continue: " answer || fatal "No input (EOF) at confirmation."
  [[ "${answer}" == "destroy" ]] || fatal "Aborted by user."
}
