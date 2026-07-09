# shellcheck shell=bash
# shellcheck disable=SC2034  # parse_args assigns cross-module globals owned
# by lib/00-config.sh and consumed by the orchestrator and phase modules.
# Usage text, argument parsing, and interactive prompts.

VALID_PHASES="full preflight storage bootstrap system boot hyprland verify cleanup"
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
  --online              Force online mode (use the network mirror even when
                        the on-ISO package store is present; the default is
                        offline-from-store when that store is found)
  --phase=<name>        Run a single phase:
                        preflight storage bootstrap system boot
                        hyprland verify cleanup
  --keep-build-deps     Do not purge build dependencies after success
  --autologin           Boot straight into the Hyprland session as the
                        target user (no tuigreet console login)
  --rtc=<utc|local>     Hardware clock interpretation. Required: neither is
                        assumed. Prompted interactively if omitted; required
                        with --yes / non-interactive runs. utc = clock keeps
                        UTC; local = clock keeps local time, for dual boot
                        with Windows (which assumes a local-time RTC)
  --jobs=<n>            Cap build parallelism (default: one per CPU);
                        lower it if compiles exhaust RAM
  --keymap=<layout[:variant]>
                        XKB keyboard layout for the installed system (console,
                        greeter, and Hyprland), e.g. --keymap=de or
                        --keymap=de:nodeadkeys. Also settable via the
                        XKB_LAYOUT / XKB_VARIANT / XKB_MODEL / XKB_OPTIONS
                        env vars. Omitted: autodetected from the live
                        session's /etc/default/keyboard, falling back to us
  --nvidia=<open|proprietary|none>
                        NVIDIA driver flavor when a GPU is detected — both
                        come from NVIDIA's CUDA repo and install offline from
                        the on-ISO store: "open" = open kernel modules (Turing
                        / RTX, GTX 16xx and newer); "proprietary" = proprietary
                        modules (every GPU; forced on pre-Turing cards);
                        "none" = skip. Prompted interactively if omitted;
                        unattended runs default to "open" (or "proprietary"
                        on a pre-Turing GPU)
  --nvidia-branch=<595|610>
                        NVIDIA driver branch (default 595, the
                        production/certified branch; 610 = newer feature
                        branch). Selected via the nvidia-driver-pinning package
  --nvidia-version=<ver>
                        Exact driver version (both flavors), e.g. 610.43.02-1
                        — pins each package and apt-mark holds them. Default:
                        the branch's newest release, tracked across NVIDIA's
                        branch promotions
  --mirror=<url>        Debian mirror (default http://deb.debian.org/debian)
  --ntp="<servers>"     Space-separated NTP servers for the installed system's
                        systemd-timesyncd (e.g. "0.pool.ntp.org
                        time.cloudflare.com"). Optional: empty (default) keeps
                        timesyncd on Debian's stock pool/DHCP servers. Time sync
                        is installed and enabled regardless.
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
      --online) ONLINE=1 ;;
      --phase=*)
        RUN_PHASE="${arg#*=}"
        [[ " ${VALID_PHASES} " == *" ${RUN_PHASE} "* ]] ||
          fatal "Unknown phase '${RUN_PHASE}'. Valid: ${VALID_PHASES}"
        ;;
      --keep-build-deps) KEEP_BUILD_DEPS=1 ;;
      --autologin) HYPR_AUTOLOGIN=1 ;;
      --rtc=*)
        RTC_MODE="${arg#*=}"
        case "${RTC_MODE}" in
          utc | local) ;;
          *) fatal "Invalid --rtc '${RTC_MODE}' (utc|local)" ;;
        esac
        ;;
      --jobs=*)
        HYPR_BUILD_JOBS="${arg#*=}"
        [[ "${HYPR_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
          fatal "--jobs expects a positive integer, got '${HYPR_BUILD_JOBS}'"
        ;;
      --keymap=*)
        XKB_LAYOUT="${arg#*=}"
        XKB_VARIANT="${XKB_LAYOUT#*:}"
        [[ "${XKB_VARIANT}" == "${XKB_LAYOUT}" ]] && XKB_VARIANT=""
        XKB_LAYOUT="${XKB_LAYOUT%%:*}"
        # 00-config.sh's :+1 captures already ran, so a CLI choice must mark
        # itself explicit or autodetect would overwrite it.
        [[ "${XKB_LAYOUT}" =~ ^[a-z][a-z0-9]*(,[a-z][a-z0-9]*)*$ ]] ||
          fatal "Invalid --keymap layout '${XKB_LAYOUT}' (e.g. us, de, us,de)"
        XKB_LAYOUT_EXPLICIT=1
        if [[ -n "${XKB_VARIANT}" ]]; then
          [[ "${XKB_VARIANT}" =~ ^[A-Za-z0-9_,:-]*$ ]] ||
            fatal "Invalid --keymap variant '${XKB_VARIANT}'"
          XKB_VARIANT_EXPLICIT=1
        fi
        ;;
      --nvidia=*)
        NVIDIA_DRIVER="${arg#*=}"
        case "${NVIDIA_DRIVER}" in
          open | proprietary | none) ;;
          *) fatal "--nvidia expects open|proprietary|none, got '${NVIDIA_DRIVER}'" ;;
        esac
        ;;
      --nvidia-branch=*)
        NVIDIA_BRANCH="${arg#*=}"
        case "${NVIDIA_BRANCH}" in
          595 | 610) ;;
          *) fatal "--nvidia-branch expects 595 or 610, got '${NVIDIA_BRANCH}'" ;;
        esac
        ;;
      --nvidia-version=*)
        NVIDIA_DRIVER_VERSION="${arg#*=}"
        [[ "${NVIDIA_DRIVER_VERSION}" =~ ^[0-9]+\.[0-9]+ ]] ||
          fatal "--nvidia-version expects a version like 610.43.02-1," \
            "got '${NVIDIA_DRIVER_VERSION}'"
        ;;
      --mirror=*) MIRROR="${arg#*=}" ;;
      --ntp=*) NTP_SERVERS="${arg#*=}" ;;
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

# Ensure RTC_MODE is set: prompt when interactive, fail fast otherwise.
# Neither UTC nor local time is assumed — the user must pick one.
require_rtc_choice() {
  [[ -n "${RTC_MODE}" ]] && return 0
  if ((!IS_INTERACTIVE)) || ((ASSUME_YES)); then
    fatal "--rtc=<utc|local> is required in non-interactive runs"
  fi
  local choice=""
  console "Hardware clock (RTC) interpretation:"
  console "  1) utc    Clock keeps UTC — Linux-only, or Windows set to UTC."
  console "  2) local  Clock keeps local time — dual boot with Windows."
  while true; do
    prompt "Choice [1-2]: " || fatal "No input (EOF) while selecting the RTC mode."
    choice="${REPLY}"
    case "${choice}" in
      1) RTC_MODE="utc" ;;
      2) RTC_MODE="local" ;;
      *) continue ;;
    esac
    break
  done
  info "Hardware clock: ${RTC_MODE}"
}

# Decide the NVIDIA driver source when a GPU is present (issue #4):
# prompt when interactive, default to "open" otherwise. No GPU or an
# explicit --nvidia=... means there is nothing to ask.
require_nvidia_choice() {
  ((HAS_NVIDIA_GPU)) || return 0
  [[ -n "${NVIDIA_DRIVER}" ]] && return 0
  if ((!IS_INTERACTIVE)) || ((ASSUME_YES)); then
    if ((${NVIDIA_GPU_PRETURING:-0})); then
      NVIDIA_DRIVER="proprietary"
      info "Pre-Turing NVIDIA GPU detected: defaulting to the proprietary" \
        "driver (the open kernel modules need Turing or newer)."
    else
      NVIDIA_DRIVER="open"
      info "NVIDIA GPU detected: defaulting to the open kernel modules from" \
        "NVIDIA's repo (override with --nvidia=<open|proprietary|none>)."
    fi
    return 0
  fi
  local choice=""
  console "NVIDIA GPU detected. Driver to install:"
  console "  1) open         NVIDIA's open kernel modules — suggested."
  console "                  Requires a Turing (RTX/GTX 16xx) or newer GPU."
  console "  2) proprietary  NVIDIA's proprietary kernel modules — every GPU,"
  console "                  required for pre-Turing cards."
  console "  3) none         skip — keep the kernel's nouveau driver."
  while true; do
    prompt "Choice [1-3, default 1]: " ||
      fatal "No input (EOF) while selecting the NVIDIA driver."
    choice="${REPLY}"
    case "${choice}" in
      1 | "") NVIDIA_DRIVER="open" ;;
      2) NVIDIA_DRIVER="proprietary" ;;
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
