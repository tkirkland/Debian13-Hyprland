# shellcheck shell=bash
# shellcheck disable=SC2034  # globals defined here are consumed by the other
# lib/ and scripts/ modules, which the orchestrator sources after this file.
# Hypr-Deb installer configuration: defaults, fixed disk ids, derived values.
# Most values can be overridden via environment variables before launching;
# flags in lib/02-args.sh override both. Disk ids and target-side paths are
# intentionally fixed.

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# --- Target disks (bare metal: fixed, no exceptions) ------------------------
DISK1="/dev/disk/by-id/nvme-eui.0025384331408197"
DISK2="/dev/disk/by-id/nvme-eui.002538433140818a"
DISK3="/dev/disk/by-id/nvme-eui.002538433140819d"

# Set by preflight: "none" on bare metal, hypervisor id otherwise.
VIRT_TYPE=""

# --- Partition sizes (amended layout: no separate /boot) --------------------
EFI_SIZE="${EFI_SIZE:-2G}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

# --- ZFS ---------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-PRECISION}"
ROOT_DISTRO="${ROOT_DISTRO:-debian13}"
ROOT_DATASET="${POOL_NAME}/ROOT/${ROOT_DISTRO}"

# --- Debian ------------------------------------------------------------------
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
TARGET="${TARGET:-/target}"

# --- System identity ---------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-precision}"
TARGET_USERNAME="${TARGET_USERNAME:-me}"
USER_PASSWORD="${USER_PASSWORD:-}"   # empty = interactive adduser prompt
ROOT_PASSWORD="${ROOT_PASSWORD:-}"   # empty = root stays locked
TIMEZONE="${TIMEZONE:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# --- Cache (network-preferred, offline-complete) -----------------------------
CACHE_DIR="${CACHE_DIR:-/var/cache/hypr-deb}"
# Inside the installed target the embedded copy always lives here:
TARGET_CACHE_DIR="/var/cache/hypr-deb"

# --- Bootloader ---------------------------------------------------------------
# Chosen via --bootloader or interactive prompt: zbm | grub | systemd-boot
BOOTLOADER="${BOOTLOADER:-}"
ZBM_EFI_URL="${ZBM_EFI_URL:-https://get.zfsbootmenu.org/efi}"
ESP_MOUNT="/boot/efi"
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA:-quiet}"

# --- Hyprland source builds ----------------------------------------------------
HYPR_GIT_BASE="${HYPR_GIT_BASE:-https://github.com/hyprwm}"
# Build order satisfies the dependency graph; hyprland always last.
HYPR_BUILD_ORDER=(
  hyprwayland-scanner
  hyprutils
  hyprlang
  hyprcursor
  hyprgraphics
  hyprland-protocols
  aquamarine
  hyprland
)
# Repo name on github (differs in case for Hyprland itself).
declare -A HYPR_REPO_NAME=(
  [hyprwayland-scanner]="hyprwayland-scanner"
  [hyprutils]="hyprutils"
  [hyprlang]="hyprlang"
  [hyprcursor]="hyprcursor"
  [hyprgraphics]="hyprgraphics"
  [hyprland-protocols]="hyprland-protocols"
  [aquamarine]="aquamarine"
  [hyprland]="Hyprland"
)
# Filled by the hyprland phase: name -> resolved tag.
declare -A HYPR_RESOLVED_TAG=()

# Debian build dependencies for the hyprwm stack (purged after success
# unless --keep-build-deps). Runtime libs are pulled automatically as
# dependencies and are NOT in this list.
HYPR_BUILD_PACKAGES=(
  build-essential cmake meson ninja-build pkg-config git
  wayland-protocols libwayland-dev libxkbcommon-dev libinput-dev
  libdrm-dev libgbm-dev libegl-dev libgles2-mesa-dev libvulkan-dev
  glslang-tools libudev-dev libseat-dev libdisplay-info-dev
  libliftoff-dev libcairo2-dev libpango1.0-dev librsvg2-dev
  libmagic-dev libhwdata-dev libzip-dev libtomlplusplus-dev
  libpugixml-dev libre2-dev hwdata
  libxcb-composite0-dev libxcb-errors-dev libxcb-ewmh-dev
  libxcb-icccm4-dev libxcb-render-util0-dev libxcb-res0-dev
  libxcb-xinput-dev xwayland
)

# Target base packages beyond debootstrap's minimal set.
TARGET_BASE_PACKAGES=(
  linux-image-amd64 zfs-initramfs zfs-dkms zfsutils-linux
  mdadm dosfstools efibootmgr network-manager sudo locales
  console-setup ca-certificates curl greetd uwsm kitty
  intel-microcode amd64-microcode
)

# Live-environment tools the preflight must be able to install offline.
LIVE_TOOL_PACKAGES=(
  debootstrap gdisk mdadm dosfstools zfsutils-linux zfs-dkms
  linux-headers-amd64 apt-utils git curl efibootmgr rsync
)

# --- Behaviour ------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
FRESH="${FRESH:-0}"
VERBOSE="${VERBOSE:-0}"
OFFLINE="${OFFLINE:-0}"
BUILD_ON_FIRSTBOOT="${BUILD_ON_FIRSTBOOT:-0}"
KEEP_BUILD_DEPS="${KEEP_BUILD_DEPS:-0}"
NETWORK_AVAILABLE=""   # set by preflight: 1 or 0
STATE_DIR="${STATE_DIR:-/run/hypr-deb/state}"
LOG_DIR="${LOG_DIR:-/tmp/hypr-deb-logs}"
LOG_FILE=""
IS_INTERACTIVE=0
[[ -t 0 && -t 1 ]] && IS_INTERACTIVE=1
