# bashsupport disable=BP5007
# shellcheck shell=bash
# shellcheck disable=SC2034
# globals defined here are consumed by the other
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
# --local-rtc: the hardware clock keeps LOCAL time instead of UTC. Only
# useful when dual booting Windows (which assumes a local-time RTC and
# would otherwise skew the clock on every reboot); leave at UTC otherwise.
RTC_LOCAL_TIME="${RTC_LOCAL_TIME:-0}"

# --- Cache (network-preferred, offline-complete) -----------------------------
CACHE_DIR="${CACHE_DIR:-/var/cache/hypr-deb}"
# Inside the installed target the embedded copy always lives here:
TARGET_CACHE_DIR="/var/cache/hypr-deb"

# --- Bootloader ---------------------------------------------------------------
# Chosen via --bootloader or interactive prompt: zbm | grub | systemd-boot
BOOTLOADER="${BOOTLOADER:-}"
ZBM_REPO_URL="${ZBM_REPO_URL:-https://github.com/zbm-dev/zfsbootmenu}"
# Fallback redirector, used only if the direct release-asset fetch fails.
ZBM_EFI_URL="${ZBM_EFI_URL:-https://get.zfsbootmenu.org/efi}"
ESP_MOUNT="/boot/efi"
# quiet alone still lets kernel errors and systemd unit chatter paint the
# console during boot and shutdown (issue #12): loglevel=3 keeps printk at
# err-and-worse, systemd.show_status=auto shows unit lines only when boot
# is slow or failing. Everything still lands in the journal.
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA:-quiet loglevel=3 systemd.show_status=auto}"
# GRUB only: detect other installed OSes (e.g. Windows) and add chainloader
# menu entries. The installer writes a STATIC grub.cfg (no grub-mkconfig),
# so GRUB_DISABLE_OS_PROBER has nothing to act on — instead os-prober is run
# at install time and its EFI entries are appended to grub.cfg. Set to 0 to
# skip. No effect with the zbm or systemd-boot bootloaders.
GRUB_OS_PROBER="${GRUB_OS_PROBER:-1}"

# --- Secure boot ---------------------------------------------------------------
# Always on. The dkms MOK keypair signs everything self-built: dkms signs
# kernel modules with it automatically; the boot phase signs loader EFI
# binaries (zbm / systemd-boot) with the same key. GRUB needs no self-
# signing (Debian ships signed shim + GRUB). Paths are target-side and
# fixed: they are what Debian's dkms uses.
MOK_KEY="/var/lib/dkms/mok.key" # PEM private key, passphrase-less
MOK_CRT="/var/lib/dkms/mok.pub" # DER certificate (dkms + mokutil format)
MOK_PEM="/var/lib/dkms/mok.pem" # PEM certificate (sbsign/sbverify format)

# --- NVIDIA driver (issue #4) --------------------------------------------------
# Detection happens BEFORE preflight (sysfs only, no tools), so prompts can
# fail fast. NVIDIA_DRIVER selects the source:
#   ""       decide interactively (unattended runs default to "open")
#   open     NVIDIA's Debian 13 CUDA repo: open kernel modules
#            (nvidia-open + nvidia-driver + nvidia-kernel-open-dkms),
#            pinned to NVIDIA_DRIVER_VERSION and apt-mark held. Open
#            modules support Turing and newer GPUs only — older cards
#            must use "debian".
#   debian   Debian 13's non-free nvidia-driver (550-series proprietary)
#   none     skip — keep the kernel's nouveau driver
#   <pkg>    any other value: a literal package name from Debian non-free
HAS_NVIDIA_GPU=0
NVIDIA_DRIVER="${NVIDIA_DRIVER:-}"
NVIDIA_REPO_KEYRING_URL="${NVIDIA_REPO_KEYRING_URL:-https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb}"
# Exact version for "open" mode, e.g. 610.43.02-1 (--nvidia-version=...).
# Empty = repo default: NVIDIA pins its production branch (R595 at the
# time of writing) via a nvidia-driver-pinning-* package, and the install
# tracks branch promotions automatically. A pinned version purges that
# pinning package (it would outrank the request) and apt-mark holds the
# driver packages so unattended upgrades cannot mix branches. 610.43.02-1
# (the R610 feature branch: HDR, DRM color pipeline) is validated with
# Hyprland on this machine.
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"
# Overridable for tests (fake sysfs trees).
SYS_PCI_PATH="${SYS_PCI_PATH:-/sys/bus/pci/devices}"

# True when a detected GPU plus a chosen package mean the driver will be
# (or was) installed — gates the non-free component, the install itself,
# the verify checks, and the session environment variables.
nvidia_install_requested() {
  ((${HAS_NVIDIA_GPU:-0})) &&
    [[ -n "${NVIDIA_DRIVER:-}" && "${NVIDIA_DRIVER}" != "none" ]]
}

# --- Hyprland source builds ----------------------------------------------------
HYPR_GIT_BASE="${HYPR_GIT_BASE:-https://github.com/hyprwm}"
# Build order satisfies the dependency graph; hyprland after its deps.
# wayland, wayland-protocols, and xkbcommon are built first because
# Debian 13's packages are too old for current Hyprland (wayland-protocols
# needs wayland-scanner>=1.25 vs trixie's 1.23; Hyprland needs
# xkbcommon>=1.11 vs 1.7 and wayland-protocols>=1.47 vs 1.44). uwsm is
# independent of the hyprwm graph (and not packaged in Debian), so it
# builds last.
HYPR_BUILD_ORDER=(
  wayland
  wayland-protocols
  xkbcommon
  lua
  hyprwayland-scanner
  hyprutils
  hyprlang
  hyprcursor
  hyprgraphics
  hyprland-protocols
  hyprwire
  aquamarine
  hyprland
  hyprtoolkit
  hyprland-guiutils
  uwsm
)
# Source repository per component. Keys are quoted so formatters cannot
# mangle the hyphenated names into invalid subscripts.
declare -A HYPR_REPO_URL=(
  ["wayland"]="https://gitlab.freedesktop.org/wayland/wayland"
  ["xkbcommon"]="https://github.com/xkbcommon/libxkbcommon"
  # Hyprland needs lua>=5.5 (<5.6); trixie tops out at lua5.4. Built by
  # build_custom_lua (plain-Makefile project, no cmake/meson, no .pc).
  ["lua"]="https://github.com/lua/lua"
  ["wayland-protocols"]="https://gitlab.freedesktop.org/wayland/wayland-protocols"
  ["hyprwayland-scanner"]="${HYPR_GIT_BASE}/hyprwayland-scanner"
  ["hyprutils"]="${HYPR_GIT_BASE}/hyprutils"
  ["hyprlang"]="${HYPR_GIT_BASE}/hyprlang"
  ["hyprcursor"]="${HYPR_GIT_BASE}/hyprcursor"
  ["hyprgraphics"]="${HYPR_GIT_BASE}/hyprgraphics"
  ["hyprland-protocols"]="${HYPR_GIT_BASE}/hyprland-protocols"
  ["hyprwire"]="${HYPR_GIT_BASE}/hyprwire"
  ["aquamarine"]="${HYPR_GIT_BASE}/aquamarine"
  ["hyprland"]="${HYPR_GIT_BASE}/Hyprland"
  # hyprland-guiutils (dialogs/update screens Hyprland expects at runtime)
  # is the qtutils successor, built on hyprwm's native hyprtoolkit.
  ["hyprtoolkit"]="${HYPR_GIT_BASE}/hyprtoolkit"
  ["hyprland-guiutils"]="${HYPR_GIT_BASE}/hyprland-guiutils"
  ["uwsm"]="${UWSM_REPO_URL:-https://github.com/Vladimir-csp/uwsm}"
)
# Release-tag pattern per component when it differs from the default
# v-prefixed semver (xkbcommon tags 'xkbcommon-X.Y.Z'; wayland-protocols
# tags plain 'X.YY').
declare -A HYPR_TAG_PATTERN=(
  ["xkbcommon"]='^xkbcommon-[0-9]+\.[0-9]+\.[0-9]+$'
  ["wayland-protocols"]='^[0-9]+\.[0-9]+$'
)
# Extra meson options per meson-built component.
declare -A HYPR_MESON_ARGS=(
  ["wayland"]="-Ddocumentation=false -Dtests=false"
  ["xkbcommon"]="-Denable-docs=false"
)

# Compiler for the source-built stack. Trixie's default GCC 14 libstdc++
# lacks C++23 container-ranges members (std::vector::append_range) that
# current hyprwire/Hyprland use. GCC 15 is NOT in trixie; it is pulled
# from sid via a pinned source (see write_sid_toolchain_sources).
HYPR_CC="${HYPR_CC:-gcc-15}"
HYPR_CXX="${HYPR_CXX:-g++-15}"
SID_MIRROR="${SID_MIRROR:-http://deb.debian.org/debian}"
# Installed in their own `apt-get -t sid` transaction so their versioned
# runtime deps (libstdc++6/libgcc-s1 >= 15, binutils chain) may follow
# from sid; the 100-pin alone would refuse those upgrades and everything
# else stays on trixie. Kept out of HYPR_BUILD_PACKAGES so the general
# build-deps install never resolves against sid.
HYPR_TOOLCHAIN_PACKAGES=(gcc-15 g++-15)

# write_sid_toolchain_sources <root>
#   Adds a sid source pinned to priority 100 under <root>: apt only takes
#   packages from sid when trixie has no candidate at all (gcc-15/g++-15
#   and their toolchain dependencies), and never upgrades anything else
#   to unstable. Only used when the network is available; offline installs
#   get the toolchain debs from the cache repo instead.
write_sid_toolchain_sources() {
  local root="${1:-}"
  mkdir -p "${root%/}/etc/apt/sources.list.d" \
    "${root%/}/etc/apt/preferences.d"
  cat >"${root%/}/etc/apt/sources.list.d/sid-toolchain.sources" <<EOF
Types: deb
URIs: ${SID_MIRROR}
Suites: sid
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  cat >"${root%/}/etc/apt/preferences.d/sid-toolchain" <<'EOF'
# Managed by hypr-deb: sid exists ONLY to supply gcc-15 (absent from
# trixie). Priority 100 = never auto-upgrade installed packages to sid;
# sid candidates are used only where trixie offers none.
Package: *
Pin: release a=unstable
Pin-Priority: 100
EOF
}
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
  libxcursor-dev libmuparser-dev liblcms2-dev bison libxcb-xkb-dev
  libffi-dev libexpat1-dev libiniparser-dev
  libpugixml-dev libre2-dev
  libxcb-composite0-dev libxcb-errors-dev libxcb-ewmh-dev
  libxcb-icccm4-dev libxcb-render-util0-dev libxcb-res0-dev
  libxcb-xinput-dev
)

# Upstream OpenZFS, FORCED on networked installs: trixie's 2.3.x is
# replaced by upstream's latest release tag, built as upstream's native
# Debian packages (openzfs-*) inside the chroot during the system phase.
# dkms signs the modules with the MOK keypair (generated before packages
# land), so secure boot works the moment the key is enrolled at the
# first-boot MokManager screen — no build is ever deferred. Offline
# installs keep distro 2.3.x with a warning (the cache does not carry the
# zfs source tree). The live environment uses distro 2.3.x either way, so
# the pool is created with the conservative feature set; enable newer
# features deliberately with `zpool upgrade` from the booted system.
ZFS_REPO_URL="${ZFS_REPO_URL:-https://github.com/openzfs/zfs}"
ZFS_TAG_PATTERN='^zfs-[0-9]+\.[0-9]+\.[0-9]+$'
# Debian packages the upstream build replaces (skipped on networked
# installs so we never dkms-build modules we immediately remove).
ZFS_DEBIAN_PACKAGES=(zfs-initramfs zfs-dkms zfsutils-linux zfs-zed)
# Upstream's documented Debian build dependencies (native-deb targets).
ZFS_BUILD_PACKAGES=(
  build-essential autoconf automake libtool gawk alien fakeroot dkms
  debhelper dh-python dh-dkms po-debconf lsb-release
  uuid-dev libblkid-dev libelf-dev libudev-dev libssl-dev zlib1g-dev
  libaio-dev libattr1-dev libffi-dev libcurl4-openssl-dev libpam0g-dev
  libtirpc-dev python3-dev python3-setuptools python3-cffi python3-packaging
  python3-all-dev python3-sphinx
)

# uwsm is not in the Debian archive — it is built from source with the
# hyprwm stack. Its Python runtime deps double as meson configure-time
# probes, so the hyprland phase re-ensures them (the system phase that
# normally installs them may already be stamped done on a resumed run).
# They are runtime deps: never in HYPR_BUILD_PACKAGES, never purged.
UWSM_RUNTIME_PACKAGES=(
  python3 python3-xdg python3-dbus whiptail dbus-user-session
)

# Userspace audio: PipeWire + WirePlumber replace the absent sound server
# (a fresh install has ALSA kernel devices but no userspace server). wpctl
# (wireplumber) and brightnessctl/playerctl also back the multimedia keybinds
# inherited from upstream's example config, which are otherwise dead.
# brightness-udev ships the udev rule that makes /sys/class/backlight/*/brightness
# writable by the video group: Debian's brightnessctl is built WITHOUT logind and
# writes sysfs directly, and that rule is only Recommended (not pulled in by
# default), so without it the screen-brightness keys do nothing (issue #48; the
# owner is added to the video group in create_user). All are in main except
# firmware-sof-signed (non-free-firmware, already enabled via DEBIAN_COMPONENTS)
# — no apt-source change required.
AUDIO_PACKAGES=(
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth
  alsa-utils pulseaudio-utils pavucontrol
  brightnessctl brightness-udev playerctl
  firmware-sof-signed
)

# Target base packages beyond debootstrap's minimal set.
# linux-headers-amd64 is REQUIRED alongside zfs-dkms: without headers for
# the target kernel, dkms silently skips the zfs module build and the
# system drops to the initramfs shell at first boot. Image and headers
# metapackages come from the same archive snapshot, so they match.
# zfs-zed is pinned explicitly (normally only a Recommends of
# zfsutils-linux): it is the daemon that reports device faults and scrub
# results on the raidz1 pool.
TARGET_BASE_PACKAGES=(
  linux-image-amd64 linux-headers-amd64 zfs-initramfs zfs-dkms zfsutils-linux
  zfs-zed
  mdadm dosfstools efibootmgr network-manager sudo locales
  console-setup ca-certificates curl greetd tuigreet kitty openssh-server
  psmisc
  shim-signed mokutil sbsigntool
  "${UWSM_RUNTIME_PACKAGES[@]}"
  "${AUDIO_PACKAGES[@]}"
  intel-microcode amd64-microcode hwdata xwayland xkb-data
)

# --- Addons -------------------------------------------------------------------
# User drop-in package lists: every addons/*.list file is read (one Debian
# package per line; blank lines and # comments ignored) and appended to
# TARGET_BASE_PACKAGES, so users add packages without editing the repo.
# Paths are relative to the repo root (the orchestrator cd's there).
ADDON_PACKAGES=()
if compgen -G "addons/*.list" >/dev/null; then
  while IFS= read -r _addon_line; do
    _addon_line="${_addon_line%%#*}"
    _addon_line="${_addon_line//[[:space:]]/}"
    [[ -n "${_addon_line}" ]] && ADDON_PACKAGES+=("${_addon_line}")
  done < <(cat addons/*.list)
  TARGET_BASE_PACKAGES+=("${ADDON_PACKAGES[@]}")
fi
unset _addon_line

# zfs-dkms must build against the RUNNING kernel's headers. The
# linux-headers-amd64 metapackage tracks the archive's NEWEST kernel, which
# is often newer than a live ISO's running kernel — DKMS would then build
# modules only for a kernel that isn't running and modprobe would fail.
LIVE_KERNEL_HEADERS="linux-headers-$(uname -r)"

# Live-environment tools the preflight must be able to install offline.
LIVE_TOOL_PACKAGES=(
  debootstrap gdisk parted mdadm dosfstools zfsutils-linux zfs-dkms
  "${LIVE_KERNEL_HEADERS}" apt-utils git curl efibootmgr rsync psmisc
  openssl
)

# --- Behaviour ------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
# --skip-cache: no offline cache is populated or embedded (saves several
# GB — important in live sessions where CACHE_DIR is RAM-backed).
SKIP_CACHE="${SKIP_CACHE:-0}"
# --autologin: greetd starts the Hyprland session directly as
# TARGET_USERNAME on VT1 (no greeter, no console password). Default is the
# tuigreet login prompt; ssh/sudo remain the authenticated paths either way.
HYPR_AUTOLOGIN="${HYPR_AUTOLOGIN:-0}"
# --jobs=N caps build parallelism (empty = one job per CPU). Lower this
# when compiles exhaust RAM in small VMs.
HYPR_BUILD_JOBS="${HYPR_BUILD_JOBS:-}"
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
