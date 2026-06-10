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

# --- APT sources (deb822) -----------------------------------------------------
# Debian 13 defaults are "main non-free-firmware"; contrib is added because the
# zfs* DKMS packages (in both LIVE_TOOL_PACKAGES and TARGET_BASE_PACKAGES) live
# there. non-free is intentionally NOT enabled.
DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS:-main contrib non-free-firmware}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"

# write_debian_sources [root]
#   root: "" or "/" for the live environment, "$TARGET" for the installed
#   system. Completely rewrites apt's source configuration under <root>:
#     - writes a deb822 debian.sources (release, -updates, -security suites)
#     - neutralises debootstrap's legacy one-line /etc/apt/sources.list so it
#       can't re-introduce duplicate or narrower entries
#   Each file is backed up to <file>.orig once (first write only) so re-runs
#   don't clobber the real original. Run `apt update` afterwards.
write_debian_sources() {
  local root="${1:-}"
  local dir="${root%/}/etc/apt/sources.list.d"
  local file="${dir}/debian.sources"

  mkdir -p "$dir"
  if [[ -e "$file" && ! -e "${file}.orig" ]]; then
    cp -a "$file" "${file}.orig"
  fi

  cat >"$file" <<EOF
Types: deb
URIs: ${MIRROR}
Suites: ${SUITE} ${SUITE}-updates
Components: ${DEBIAN_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${SECURITY_MIRROR}
Suites: ${SUITE}-security
Components: ${DEBIAN_COMPONENTS}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  # debootstrap writes a legacy one-line sources.list; empty it so the deb822
  # file above is the sole authority and apt can't see duplicate suites.
  local legacy="${root%/}/etc/apt/sources.list"
  if [[ -e "$legacy" && ! -e "${legacy}.orig" ]]; then
    cp -a "$legacy" "${legacy}.orig"
  fi
  printf '# Managed by hypr-deb: APT sources are defined in\n# /etc/apt/sources.list.d/debian.sources\n' >"$legacy"
}

# --- System identity ---------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-precision}"
TARGET_USERNAME="${TARGET_USERNAME:-me}"
USER_PASSWORD="${USER_PASSWORD:-}" # empty = interactive adduser prompt
ROOT_PASSWORD="${ROOT_PASSWORD:-}" # empty = root stays locked
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
# Build order satisfies the dependency graph; hyprland after its deps.
# uwsm is independent of the hyprwm graph (and not packaged in Debian),
# so it builds last.
HYPR_BUILD_ORDER=(
  hyprwayland-scanner
  hyprutils
  hyprlang
  hyprcursor
  hyprgraphics
  hyprland-protocols
  aquamarine
  hyprland
  uwsm
)
# Source repository per component. Keys are quoted so formatters cannot
# mangle the hyphenated names into invalid subscripts.
declare -A HYPR_REPO_URL=(
  ["hyprwayland-scanner"]="${HYPR_GIT_BASE}/hyprwayland-scanner"
  ["hyprutils"]="${HYPR_GIT_BASE}/hyprutils"
  ["hyprlang"]="${HYPR_GIT_BASE}/hyprlang"
  ["hyprcursor"]="${HYPR_GIT_BASE}/hyprcursor"
  ["hyprgraphics"]="${HYPR_GIT_BASE}/hyprgraphics"
  ["hyprland-protocols"]="${HYPR_GIT_BASE}/hyprland-protocols"
  ["aquamarine"]="${HYPR_GIT_BASE}/aquamarine"
  ["hyprland"]="${HYPR_GIT_BASE}/Hyprland"
  ["uwsm"]="${UWSM_REPO_URL:-https://github.com/Vladimir-csp/uwsm}"
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
  glslang-tools glslang-dev libudev-dev libseat-dev libdisplay-info-dev
  libliftoff-dev libcairo2-dev libpango1.0-dev librsvg2-dev
  libmagic-dev libzip-dev libtomlplusplus-dev scdoc
  libpugixml-dev libre2-dev
  libxcb-composite0-dev libxcb-errors-dev libxcb-ewmh-dev
  libxcb-icccm4-dev libxcb-render-util0-dev libxcb-res0-dev
  libxcb-xinput-dev
)

# Target base packages beyond debootstrap's minimal set. uwsm is not in
# the Debian archive — it is built from source with the hyprwm stack; its
# runtime dependencies (python3/pyxdg/whiptail/dbus) are listed here.
TARGET_BASE_PACKAGES=(
  linux-image-amd64 zfs-initramfs zfs-dkms zfsutils-linux
  mdadm dosfstools efibootmgr network-manager sudo locales
  console-setup ca-certificates curl greetd kitty
  python3 python3-xdg whiptail dbus-user-session
  intel-microcode amd64-microcode hwdata xwayland
)

# zfs-dkms must build against the RUNNING kernel's headers. The
# linux-headers-amd64 metapackage tracks the archive's NEWEST kernel, which
# is often newer than a live ISO's running kernel — DKMS would then build
# modules only for a kernel that isn't running and modprobe would fail.
LIVE_KERNEL_HEADERS="linux-headers-$(uname -r)"

# Live-environment tools the preflight must be able to install offline.
LIVE_TOOL_PACKAGES=(
  debootstrap gdisk parted mdadm dosfstools zfsutils-linux zfs-dkms
  "${LIVE_KERNEL_HEADERS}" apt-utils git curl efibootmgr rsync
)

# --- Behaviour ------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
FRESH="${FRESH:-0}"
VERBOSE="${VERBOSE:-0}"
OFFLINE="${OFFLINE:-0}"
BUILD_ON_FIRSTBOOT="${BUILD_ON_FIRSTBOOT:-0}"
KEEP_BUILD_DEPS="${KEEP_BUILD_DEPS:-0}"
NETWORK_AVAILABLE="" # set by preflight: 1 or 0
STATE_DIR="${STATE_DIR:-/run/hypr-deb/state}"
LOG_DIR="${LOG_DIR:-/tmp/hypr-deb-logs}"
LOG_FILE=""
IS_INTERACTIVE=0
# `if` (not `&&`) so sourcing this file returns 0 in non-tty contexts.
if [[ -t 0 && -t 1 ]]; then
  IS_INTERACTIVE=1
fi
