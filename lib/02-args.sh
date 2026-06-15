# shellcheck shell=bash
# shellcheck disable=SC2034  # parse_args assigns cross-module globals owned
# by lib/00-config.sh and consumed by the orchestrator and phase modules.
# Usage text, argument parsing, and interactive prompts.

VALID_PHASES="full preflight cache storage bootstrap system boot hyprland verify cleanup"
RUN_PHASE="full"

usage() {
  cat <<'EOF'
Usage: installer.sh [options]

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
  --autologin           Boot straight into the Hyprland session as the
                        target user (no tuigreet console login)
  --local-rtc           Keep the hardware clock in LOCAL time instead of
                        UTC (for dual boot with Windows, which assumes a
                        local-time RTC)
  --jobs=<n>            Cap build parallelism (default: one per CPU);
                        lower it if compiles exhaust RAM
  --nvidia=<open|debian|none|package>
                        NVIDIA driver source when a GPU is detected:
                        "open" = NVIDIA's Debian 13 repo, open kernel
                        modules pinned to NVIDIA_DRIVER_VERSION (default
                        610.43.02-1); "debian" = Debian's non-free
                        nvidia-driver (550); "none" = skip; any other
                        value = a literal non-free package name.
                        Prompted interactively if omitted; unattended
                        runs default to "open"
  --nvidia-version=<ver>
                        Exact driver version for --nvidia=open, e.g.
                        610.43.02-1 (pinned and apt-mark held). Default:
                        the repo's production branch, tracked across
                        NVIDIA's branch promotions
  --mirror=<url>        Debian mirror (default http://deb.debian.org/debian)
  --cache-dir=<path>    Cache location (default /var/cache/hypr-deb)
  --fresh               Discard phase state and start over
  --yes                 Unattended mode: skips the destructive confirmation
                        and refuses to reach any later prompt — requires
                        --bootloader and the USER_PASSWORD env var
  --verbose             Stream full command output to the console. Default:
                        phase activity only; full output stays in the log
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
      --autologin) HYPR_AUTOLOGIN=1 ;;
      --local-rtc) RTC_LOCAL_TIME=1 ;;
      --jobs=*)
        HYPR_BUILD_JOBS="${arg#*=}"
        [[ "${HYPR_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
          fatal "--jobs expects a positive integer, got '${HYPR_BUILD_JOBS}'"
        ;;
      --nvidia=*)
        NVIDIA_DRIVER="${arg#*=}"
        [[ -n "${NVIDIA_DRIVER}" ]] ||
          fatal "--nvidia expects open|debian|none or a package name"
        ;;
      --nvidia-version=*)
        NVIDIA_DRIVER_VERSION="${arg#*=}"
        [[ "${NVIDIA_DRIVER_VERSION}" =~ ^[0-9]+\.[0-9]+ ]] ||
          fatal "--nvidia-version expects a version like 610.43.02-1," \
            "got '${NVIDIA_DRIVER_VERSION}'"
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
  console "Select a bootloader:"
  console "  1) zbm           ZFSBootMenu — boots snapshots/datasets directly"
  console "  2) grub          GRUB (reads kernel copies from the ESP)"
  console "  3) systemd-boot  systemd-boot (reads kernel copies from the ESP)"
  while true; do
    prompt "Choice [1-3]: " || fatal "No input (EOF) while selecting bootloader."
    choice="${REPLY}"
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

# Decide the NVIDIA driver source when a GPU is present (issue #4):
# prompt when interactive, default to "open" otherwise. No GPU or an
# explicit --nvidia=... means there is nothing to ask.
require_nvidia_choice() {
  ((HAS_NVIDIA_GPU)) || return 0
  [[ -n "${NVIDIA_DRIVER}" ]] && return 0
  if ((!IS_INTERACTIVE)) || ((ASSUME_YES)); then
    NVIDIA_DRIVER="open"
    info "NVIDIA GPU detected: defaulting to the open kernel modules from" \
      "NVIDIA's repo (override with --nvidia=<open|debian|none>)."
    return 0
  fi
  local choice=""
  console "NVIDIA GPU detected. Driver to install:"
  console "  1) open    NVIDIA's Debian 13 repo, open kernel modules — suggested."
  console "             Production branch by default; --nvidia-version=<ver> pins"
  console "             an exact release (e.g. 610.43.02-1, the feature branch)."
  console "             Requires a Turing (RTX/GTX 16xx) or newer GPU."
  console "  2) debian  Debian 13's non-free nvidia-driver (550 series, proprietary"
  console "             kernel modules) — for pre-Turing GPUs."
  console "  3) none    skip — keep the kernel's nouveau driver."
  while true; do
    prompt "Choice [1-3, default 1]: " ||
      fatal "No input (EOF) while selecting the NVIDIA driver."
    choice="${REPLY}"
    case "${choice}" in
      1 | "") NVIDIA_DRIVER="open" ;;
      2) NVIDIA_DRIVER="debian" ;;
      3) NVIDIA_DRIVER="none" ;;
      *) continue ;;
    esac
    break
  done
  info "NVIDIA driver: ${NVIDIA_DRIVER}" \
    "${NVIDIA_DRIVER_VERSION:+(version ${NVIDIA_DRIVER_VERSION})}"
}

# Destructive gate. Lists the disks about to be destroyed.
confirm_destruction() {
  ((ASSUME_YES)) && return 0
  ((IS_INTERACTIVE)) ||
    fatal "Refusing destructive run without --yes in a non-interactive session"
  activity_pause
  console ""
  console "  *** ALL DATA on these disks will be DESTROYED ***"
  console "      DISK1=${DISK1}"
  console "      DISK2=${DISK2}"
  console "      DISK3=${DISK3}"
  console "      Mode: $([[ "${VIRT_TYPE}" == "none" ]] && echo "BARE METAL" ||
    echo "VM (${VIRT_TYPE})")"
  console ""
  local answer=""
  prompt "Type 'destroy' to continue: " || fatal "No input (EOF) at confirmation."
  answer="${REPLY}"
  [[ "${answer}" == "destroy" ]] || fatal "Aborted by user."
  activity_resume
}
