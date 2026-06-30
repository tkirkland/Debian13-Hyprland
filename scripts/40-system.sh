# shellcheck shell=bash
# Base system: identity, locale/tz, fstab, mdadm.conf, base packages,
# user account, ZFS boot prerequisites (hostid, cachefile, initramfs).

write_identity() {
  echo "${TARGET_HOSTNAME}" >"${TARGET}/etc/hostname"
  cat >"${TARGET}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}
::1       localhost ip6-localhost ip6-loopback
EOF
}

write_fstab() {
  local efi_uuid="" swap_uuid=""
  efi_uuid="$(blkid -s UUID -o value /dev/md/efi)"
  swap_uuid="$(blkid -s UUID -o value /dev/md/swap)"
  cat >"${TARGET}/etc/fstab" <<EOF
# ZFS datasets mount via the zfs mount generator; root comes from initramfs.
UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1
UUID=${swap_uuid} none swap sw 0 0
EOF
}

write_mdadm_conf() {
  mkdir -p "${TARGET}/etc/mdadm"
  {
    echo "HOMEHOST <ignore>"
    mdadm --detail --scan
  } >"${TARGET}/etc/mdadm/mdadm.conf"
}

# Requires the locales package (/etc/locale.gen, locale-gen), so this must
# run after install_base_packages — a minimal debootstrap does not ship it.
configure_locale_tz() {
  in_target "
    set -e
    test -f /etc/locale.gen ||
      { echo 'locales package missing (/etc/locale.gen)' >&2; exit 1; }
    echo '${TIMEZONE}' > /etc/timezone
    ln -sf '/usr/share/zoneinfo/${TIMEZONE}' /etc/localtime
    sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
    locale-gen
    update-locale LANG='${LOCALE}'
  "
  # RTC interpretation is a required user choice (--rtc / prompt); neither
  # utc nor local is assumed. timedatectl set-local-rtc needs a running
  # systemd/dbus which a chroot lacks, so write /etc/adjtime directly — the
  # third line tells hwclock and systemd how to read the RTC.
  case "${RTC_MODE}" in
    local)
      printf '0.0 0 0.0\n0\nLOCAL\n' >"${TARGET}/etc/adjtime"
      info "Hardware clock configured for LOCAL time (dual boot)."
      ;;
    utc)
      printf '0.0 0 0.0\n0\nUTC\n' >"${TARGET}/etc/adjtime"
      info "Hardware clock configured for UTC."
      ;;
    *) fatal "RTC_MODE not set (preflight require_rtc_choice should have ensured this)." ;;
  esac
}

# systemd-timesyncd (in TARGET_BASE_PACKAGES) keeps the installed system's
# clock disciplined after boot — without an NTP client nothing corrects drift.
# Debian's preset enables it on install, but enable it explicitly here for the
# same reason greetd/NetworkManager are: the chroot's apt run cannot rely on a
# live systemd to apply presets. timesyncd is a CLIENT only; it never serves a
# LAN. NTP_SERVERS (--ntp) optionally pins specific servers via a drop-in;
# empty leaves it on Debian's stock pool/DHCP behaviour.
configure_time_sync() {
  in_target "
    set -e
    systemctl enable systemd-timesyncd
  "
  [[ -n "${NTP_SERVERS}" ]] || return 0
  mkdir -p "${TARGET}/etc/systemd/timesyncd.conf.d"
  cat >"${TARGET}/etc/systemd/timesyncd.conf.d/10-installer.conf" <<EOF
[Time]
NTP=${NTP_SERVERS}
EOF
  info "timesyncd pinned to NTP servers: ${NTP_SERVERS}"
}

# Neuter systemd-ssh-generator (systemd >=256) in the installed target. The
# generator sets up ssh-over-vsock socket activation by querying the local
# AF_VSOCK CID; on hardware/VMs with no vhost-vsock device that query fails and
# the generator exits 1 on every boot/daemon-reload, spamming the journal with
# "Failed to query local AF_VSOCK CID: Cannot assign requested address". It is
# shipped by systemd itself and is entirely independent of the real sshd
# (openssh-server's ssh.service), so masking it has ZERO impact on ssh. Mask =
# symlink to /dev/null under /etc/systemd/system-generators, which outranks
# /usr/lib/systemd/system-generators, so a systemd dpkg upgrade never undoes it.
neuter_ssh_vsock_generator() {
  in_target "
    set -e
    mkdir -p /etc/systemd/system-generators
    ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator
  "
}

# dkms signs every module it builds with this keypair and the boot phase
# signs loader EFI binaries with it. Debian's dkms would generate it on
# demand, but the zfs-dkms postinst (during install_base_packages) is the
# first consumer, so it must exist before packages land. Generated with
# the LIVE environment's openssl (the chroot has none yet). Parameters
# mirror Debian dkms defaults: passphrase-less RSA 2048, DER certificate.
ensure_mok_key() {
  if [[ -f "${TARGET}${MOK_KEY}" && -f "${TARGET}${MOK_CRT}" ]]; then
    return 0
  fi
  mkdir -p "${TARGET}/var/lib/dkms"
  openssl req -new -x509 -nodes -days 36500 -newkey rsa:2048 \
    -subj "/CN=hypr-deb DKMS module signing key/" \
    -keyout "${TARGET}${MOK_KEY}" -outform DER \
    -out "${TARGET}${MOK_CRT}" 2>/dev/null ||
    fatal "MOK keypair generation failed (openssl)."
  chmod 600 "${TARGET}${MOK_KEY}"
  info "Generated MOK signing keypair at ${MOK_KEY}."
}

# Echo this machine's CPU vendor_id from /proc/cpuinfo (GenuineIntel /
# AuthenticAMD), or empty if unknown. The installer runs on the real target
# hardware, so this reflects the CPU the microcode is being chosen for. Split
# out so the microcode selection in install_base_packages is unit-testable.
detect_cpu_vendor() {
  grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $NF}'
}

install_base_packages() {
  local pkgs=("${TARGET_BASE_PACKAGES[@]}") p="" filtered=()
  # VMware guest integration (display resize, clipboard, time sync,
  # clean shutdown). open-vm-tools-desktop layers desktop features on the
  # base daemon; both are pointless on bare metal, so VIRT_TYPE gates them.
  if [[ "${VIRT_TYPE}" == "vmware" ]]; then
    pkgs+=(open-vm-tools open-vm-tools-desktop)
  fi
  # Upstream OpenZFS replaces Debian's zfs-* on BOTH paths: online builds it from
  # source (install_zfs_from_source), offline installs the prebuilt upstream debs
  # from the on-ISO pool (install_zfs_offline). Either way, installing Debian's
  # zfs-* first would only churn (and dkms-build) packages we immediately replace,
  # so filter them out of the base set unconditionally.
  for p in "${pkgs[@]}"; do
    case " ${ZFS_DEBIAN_PACKAGES[*]} " in
      *" ${p} "*) continue ;;
    esac
    filtered+=("${p}")
  done
  pkgs=("${filtered[@]}")
  # Microcode is CPU-vendor-specific: the other vendor's blob is dead weight on
  # the installed system. Install ONLY the microcode matching this CPU. BOTH debs
  # stay in the offline pool (TARGET_BASE_PACKAGES is unchanged, so the ISO still
  # supports either CPU) — only the INSTALL set is filtered here. Unknown vendor
  # keeps both (no regression: every CPU still gets its microcode offline).
  local drop=""
  case "$(detect_cpu_vendor)" in
    GenuineIntel) drop="amd64-microcode" ;;
    AuthenticAMD) drop="intel-microcode" ;;
  esac
  if [[ -n "${drop}" ]]; then
    filtered=()
    for p in "${pkgs[@]}"; do
      [[ "${p}" == "${drop}" ]] && continue
      filtered+=("${p}")
    done
    pkgs=("${filtered[@]}")
  fi
  # man-db re-indexes every installed man page on each apt transaction's
  # trigger phase — there are ~10 transactions across the install, minutes
  # of CPU on bare metal. Disable its auto-update for the chroot's lifetime
  # BEFORE the first transaction configures man-db, so neither the initial
  # build nor any later trigger fires. Man pages are still installed;
  # man-db's daily timer builds the index on the running system. The
  # debconf value persists in the target, so it also covers the boot and
  # hyprland phases' apt calls and any resumed run.
  in_target "echo 'man-db man-db/auto-update boolean false' | debconf-set-selections"
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${pkgs[*]}
  "
  if ((NETWORK_AVAILABLE)); then
    install_zfs_from_source
  else
    install_zfs_offline
  fi
}

# Offline counterpart to install_zfs_from_source: the upstream OpenZFS debs were
# already built into the on-ISO pool at build time (tools/build-iso.sh step_zfs),
# so install them BY NAME from the file:// store the bootstrap phase set up,
# replacing Debian's 2.3.x — NO network, NO source build. Mirrors the source
# path's install tail: keep the pam module out (the build filter never pools it,
# but purge defensively if a prior attempt pulled it, then regenerate the PAM
# stack from clean profiles), and apt-mark the metapackages manual so the later
# Hyprland build-dep autoremove cannot reap them.
install_zfs_offline() {
  info "Installing upstream OpenZFS from the offline store (replaces Debian's zfs-*)..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${ZFS_UPSTREAM_PACKAGES[*]}
    if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs*pam*'
    fi
    rm -f /usr/share/pam-configs/*zfs*
    pam-auth-update --package
    apt-mark manual ${ZFS_UPSTREAM_PACKAGES[*]} >/dev/null
  "
  in_target "zfs version" || true
}

# ZFS_DEB_POOL (optional): when non-empty, the produced .debs that pass the
# install filter are also copied (not moved) into this host-side directory to
# seed an offline pool; unset leaves install-time behavior unchanged.
# Upstream OpenZFS, forced on networked installs: build the latest release
# as native Debian packages inside the chroot and install them in place of
# Debian's 2.3.x. dkms signs the modules with the MOK key generated by
# ensure_mok_key — enrollment at the first-boot MokManager screen only
# matters once secure boot is switched on, so nothing is deferred. ONLY
# native-deb-utils is built: that set includes openzfs-zfs-dkms (whose
# postinst builds for the TARGET's kernels — headers are already
# installed). native-deb-kmod is deliberately avoided: it compiles modules
# for the RUNNING (live) kernel and its package dependency drags that
# kernel image into the target. Upstream's deb recipes swallow
# dpkg-buildpackage failures (the lock-file rm masks the exit code), so
# the required packages are asserted by name.
install_zfs_from_source() {
  local tag="" jobs="${HYPR_BUILD_JOBS:-}"
  [[ -n "${jobs}" ]] || jobs="\$(nproc)"
  # Tags include dev-cycle markers (zfs-X.Y.99) that outrank real releases
  # in a version sort; the GitHub API names the actual latest release.
  tag="$(curl -fsSL --retry 3 \
    "https://api.github.com/repos/openzfs/zfs/releases/latest" 2>/dev/null |
    grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 || true)"
  [[ -n "${tag}" ]] ||
    tag="$(resolve_latest_release_tag "${ZFS_REPO_URL}" "${ZFS_TAG_PATTERN}")"
  info "Building OpenZFS ${tag} from source (replaces Debian's zfs-*)..."
  rm -rf "${TARGET}/var/tmp/openzfs"
  rm -f "${TARGET}"/var/tmp/*.deb "${TARGET}"/var/tmp/*.changes \
    "${TARGET}"/var/tmp/*.buildinfo
  git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
    "${ZFS_REPO_URL}" "${TARGET}/var/tmp/openzfs"
  # The build step (autogen → configure → make native-deb-utils → assert the
  # required packages were built) is shared. The in-target install tail below
  # it (filter+install the .debs, purge pam, regenerate the PAM stack) only
  # matters when zfs is going into a real target. When seeding an offline pool
  # (ZFS_DEB_POOL set) the buildroot is thrown away, so skip the tail and stop
  # after the build + copy-to-pool. With ZFS_DEB_POOL unset the concatenated
  # script is byte-for-byte identical to the original installer in_target call.
  local zfs_script="
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # native-deb-utils drives dpkg-buildpackage/debhelper, which generates and
    # then discards -dbgsym debs. noautodbgsym tells dh_strip not to produce them
    # at all (build-time waste). It only suppresses auto -dbgsym packages, so the
    # required openzfs-* debs asserted below are unaffected.
    export DEB_BUILD_OPTIONS=noautodbgsym
    # Drop any live-kernel modules package from an earlier failed attempt.
    if dpkg-query -W 'openzfs-zfs-modules-*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs-zfs-modules-*'
    fi
    apt-get install -y ${ZFS_BUILD_PACKAGES[*]}
    cd /var/tmp/openzfs
    ./autogen.sh
    ./configure
    make -j\"${jobs}\" native-deb-utils
    for p in openzfs-zfs-dkms openzfs-zfsutils openzfs-zfs-initramfs \
      openzfs-zfs-zed; do
      ls /var/tmp/\${p}_*.deb >/dev/null 2>&1 ||
        { echo \"required package not built: \${p}\" >&2; exit 1; }
    done"
  if [[ -z "${ZFS_DEB_POOL:-}" ]]; then
    zfs_script+="
    debs=\"\$(ls /var/tmp/*.deb |
      grep -Ev 'zfs-modules|test|dracut|dbg|-dev|pam' || true)\"
    [[ -n \"\${debs}\" ]] ||
      { echo 'native-deb-utils produced no installable packages' >&2; exit 1; }
    echo \"\${debs}\" | xargs apt-get install -y
    # pam_zfs_key (encrypted-home key sync) registers itself in
    # common-password and makes chpasswd fail with 'Authentication token
    # manipulation error' on systems without encrypted homes. Keep it out:
    # never install it (deb filter above), purge it if a previous attempt
    # installed it, and regenerate the PAM stack from clean profiles.
    if dpkg-query -W 'openzfs*pam*' >/dev/null 2>&1; then
      apt-get purge -y 'openzfs*pam*'
    fi
    rm -f /usr/share/pam-configs/*zfs*
    pam-auth-update --package
  "
  fi
  in_target "${zfs_script}"
  # Optionally seed an offline pool with the same filtered .debs (copy, so
  # the in-target install above is unaffected). Resolved host-side.
  if [[ -n "${ZFS_DEB_POOL:-}" ]]; then
    mkdir -p "${ZFS_DEB_POOL}"
    local deb
    for deb in "${TARGET}"/var/tmp/*.deb; do
      [[ -e "${deb}" ]] || continue
      [[ "${deb##*/}" =~ zfs-modules|test|dracut|dbg|-dev|pam ]] && continue
      cp "${deb}" "${ZFS_DEB_POOL}/"
    done
  fi
  # dkms rebuilds (and re-signs) the zfs module on every kernel update;
  # the toolchain must survive the Hyprland build-dep purge and its
  # `apt-get autoremove --purge`. Only meaningful for a real target: when
  # seeding the offline pool (ZFS_DEB_POOL set) nothing was installed in this
  # throwaway buildroot, so apt-mark and the zfs-version smoke test are skipped.
  if [[ -z "${ZFS_DEB_POOL:-}" ]]; then
    in_target "apt-mark manual ${ZFS_BUILD_PACKAGES[*]} >/dev/null"
    in_target "zfs version" || true
  fi
  rm -rf "${TARGET}/var/tmp/openzfs"
}

# NVIDIA driver install (issue #4; Phase 5: fully offline), gated on detection
# + user choice. Both flavors come from NVIDIA's CUDA debian13 repo:
#   - OFFLINE (default): install from the on-ISO store /hypr-repo via the
#     temporary trusted file:// source the bootstrap phase set up — NO network
#     keyring fetch, NO apt update against NVIDIA's network repo.
#   - ONLINE (--online): install the cuda-keyring, apt update, then install from
#     NVIDIA's network repo.
# The dkms modules build on the target via each package's postinst (headers +
# toolchain are already in the closure) and are MOK-signed exactly like zfs, so
# secure boot works once the key is enrolled. nouveau blacklisting is handled by
# the driver packages themselves.
#
# Flavor: "open" = nvidia-open + nvidia-kernel-open-dkms (Turing/RTX, GTX 16xx
# and newer); "proprietary" = nvidia-driver + nvidia-kernel-dkms (every GPU).
# A pre-Turing GPU (NVIDIA_GPU_PRETURING) forces proprietary. Branch
# (NVIDIA_BRANCH, 595 default / 610) is selected by the
# nvidia-driver-pinning-<branch> package; an exact NVIDIA_DRIVER_VERSION instead
# pins each metapackage and skips the pinning package (its priority-1000 pin
# would outrank the request). The driver metapackages are apt-mark held so
# unattended upgrades cannot mix branches.
install_nvidia_driver() {
  nvidia_install_requested || return 0
  local flavor="${NVIDIA_DRIVER}"
  # Card gating: the open kernel modules require Turing (RTX/GTX 16xx) or newer.
  if [[ "${flavor}" == "open" ]] && ((${NVIDIA_GPU_PRETURING:-0})); then
    warn "Pre-Turing NVIDIA GPU: the open kernel modules are unsupported on" \
      "this card — installing the proprietary driver instead."
    flavor="proprietary"
  fi
  local pin_pkg="${NVIDIA_PINNING_PACKAGE[${NVIDIA_BRANCH}]:-}"
  [[ -n "${pin_pkg}" ]] ||
    fatal "No NVIDIA branch-pinning package for branch '${NVIDIA_BRANCH}'" \
      "(expected 595 or 610)."
  local ver="${NVIDIA_DRIVER_VERSION}"
  local -a base=()
  if [[ "${flavor}" == "open" ]]; then
    base=("${NVIDIA_OPEN_PACKAGES[@]}")
  else
    base=("${NVIDIA_PROP_PACKAGES[@]}")
  fi
  # Append the exact version to each metapackage when pinned.
  local -a pkgs=() p=""
  for p in "${base[@]}"; do
    pkgs+=("${p}${ver:+=${ver}}")
  done
  # Branch selection: install the pinning package, OR (exact version) skip it so
  # the =VERSION requests drive apt without the priority-1000 pin overriding.
  local branch_select="apt-get install -y '${pin_pkg}'"
  [[ -n "${ver}" ]] && branch_select=":  # exact version pinned: no branch pin"
  # Online only: install the cuda-keyring and refresh against NVIDIA's repo.
  # Offline resolves everything from the /hypr-repo file:// source already set
  # up in the bootstrap phase (Trusted: yes), so neither step runs.
  local online_prep=":"
  if ((NETWORK_AVAILABLE)); then
    curl -fsSL --retry 3 -o "${TARGET}/tmp/cuda-keyring.deb" \
      "${NVIDIA_REPO_KEYRING_URL}" ||
      fatal "Could not fetch NVIDIA repo keyring (${NVIDIA_REPO_KEYRING_URL})."
    online_prep="dpkg -i /tmp/cuda-keyring.deb
      rm -f /tmp/cuda-keyring.deb
      apt-get update"
  fi
  local src="the on-ISO store (/hypr-repo)"
  ((NETWORK_AVAILABLE)) && src="NVIDIA's CUDA repo"
  local desc="branch ${NVIDIA_BRANCH}"
  [[ -n "${ver}" ]] && desc="${desc}, version ${ver}"
  info "Installing NVIDIA ${flavor} driver (${desc}) from ${src}..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    ${online_prep}
    # The two nvidia-driver-pinning-<branch> packages Conflict on one file;
    # purge any installed one before (re)selecting the branch.
    if dpkg-query -W 'nvidia-driver-pinning-*' >/dev/null 2>&1; then
      apt-get purge -y 'nvidia-driver-pinning-*'
    fi
    ${branch_select}
    apt-get install -y ${pkgs[*]}
    apt-mark hold ${base[*]}
  "
  # Hyprland (any wlroots/aquamarine compositor) requires the DRM KMS
  # interface; fbdev replaces efifb with a native high-res console on the
  # same driver. Set via modprobe.d + initramfs so it applies regardless
  # of which of the three bootloaders writes the kernel cmdline.
  cat >"${TARGET}/etc/modprobe.d/nvidia-options.conf" <<'EOF'
# Managed by hypr-deb (issue #4): Hyprland requires nvidia-drm KMS.
options nvidia-drm modeset=1 fbdev=1
EOF
  in_target "update-initramfs -u"
}

# Addon artifacts: things apt cannot provide, dropped into addons/.
#   *.deb  installed via apt from the local file (dependencies resolved
#          from the enabled sources; the chroot policy-rc.d guard blocks
#          service starts like for every other package).
#   *.sh   user-authored customization hooks, EXECUTED inside the target
#          chroot as root, in lexical order, after packages and addon
#          debs (live-build hook semantics). A failing script fails the
#          phase by name.
#   *.run  staged executable at /opt/addons in the target and NOT
#          executed: vendor runfiles (VMware etc.) compile kernel modules
#          and start services against the RUNNING system, so they must be
#          run manually after first boot.
install_addon_artifacts() {
  local f="" staged=0
  if compgen -G "addons/*.deb" >/dev/null; then
    info "Installing addon .deb packages..."
    rm -rf "${TARGET}/var/tmp/addon-debs"
    install -d "${TARGET}/var/tmp/addon-debs"
    cp addons/*.deb "${TARGET}/var/tmp/addon-debs/"
    in_target "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y /var/tmp/addon-debs/*.deb
    "
    rm -rf "${TARGET}/var/tmp/addon-debs"
  fi
  if compgen -G "addons/*.sh" >/dev/null; then
    rm -rf "${TARGET}/var/tmp/addon-scripts"
    install -d "${TARGET}/var/tmp/addon-scripts"
    cp addons/*.sh "${TARGET}/var/tmp/addon-scripts/"
    for f in addons/*.sh; do
      info "Running addon script ${f##*/} in the target..."
      in_target "bash '/var/tmp/addon-scripts/${f##*/}'" ||
        fatal "Addon script failed: ${f##*/}"
    done
    rm -rf "${TARGET}/var/tmp/addon-scripts"
  fi
  if compgen -G "addons/*.run" >/dev/null; then
    install -d "${TARGET}/opt/addons"
    for f in addons/*.run; do
      install -m755 "${f}" "${TARGET}/opt/addons/"
      staged=$((staged + 1))
    done
    info "Staged ${staged} vendor runfile(s) at /opt/addons — run them" \
      "manually after first boot (they need the running system)."
  fi
}

# chezmoi is not packaged for Debian. Its official .deb is harvested into the
# offline pool at build time (cache_populate_chezmoi, scripts/10-cache.sh), so it
# installs by NAME from the on-ISO file:// store the bootstrap phase set up —
# fully OFFLINE, NO GitHub fetch, no network branch. apt resolves the (minimal)
# dependencies from the same store.
install_chezmoi() {
  info "Installing chezmoi from the offline store..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y chezmoi
  "
}

# Build-time harvester (the build host is online): download every LythMono
# variant zip and EXTRACT its TTFs into DEST, so the ISO ships the fonts in the
# offline store (DEST = ${CACHE_DIR}/repo/${LYTHMONO_STORE_SUBDIR}, grafted to
# ${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR} on the ISO). install_lythmono_fonts
# copies them from there at install time — NO network. Pairs with build-iso's
# step_stage_fonts (run only at build). LYTHMONO_VERSION pins the release; empty
# resolves the latest tag (build-time only). unzip comes from LIVE_TOOL_PACKAGES
# on the build host.
harvest_lythmono_fonts() {
  local dest="${1:?dest dir}" v="" tag="${LYTHMONO_VERSION:-}" tmp=""
  [[ -n "${tag}" ]] ||
    tag="$(resolve_latest_release_tag "${LYTHMONO_REPO_URL}" "${LYTHMONO_TAG_PATTERN}")"
  info "Harvesting LythMono ${tag} fonts (${#LYTHMONO_VARIANTS[@]} variants) into ${dest}..."
  install -d "${dest}"
  tmp="$(mktemp -d)"
  for v in "${LYTHMONO_VARIANTS[@]}"; do
    curl -fsSL --retry 3 -o "${tmp}/${v}.zip" \
      "${LYTHMONO_REPO_URL}/releases/download/${tag}/${v}.zip" ||
      { rm -rf "${tmp}"; fatal "Failed to harvest LythMono variant ${v} (${tag})."; }
    unzip -o -j -q "${tmp}/${v}.zip" '*.ttf' -d "${dest}"
  done
  rm -rf "${tmp}"
}

# LythMono is not packaged. Its TTFs are harvested into the offline store at
# build time (harvest_lythmono_fonts); install them from that LOCAL store path
# into the system font path so all users get them, fully OFFLINE — NO GitHub
# fetch, no network branch. fontconfig (fc-cache) comes from TARGET_BASE_PACKAGES.
install_lythmono_fonts() {
  local src="${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR}"
  if ! compgen -G "${src}/*.ttf" >/dev/null 2>&1; then
    warn "LythMono fonts absent from the offline store (${src}); skipping."
    return 0
  fi
  info "Installing LythMono fonts from the offline store (${src})..."
  install -d "${TARGET}/usr/local/share/fonts/LythMono"
  cp "${src}"/*.ttf "${TARGET}/usr/local/share/fonts/LythMono/"
  in_target "fc-cache -f /usr/local/share/fonts/LythMono"
}

create_user() {
  # The Downloads dataset is created canmount=noauto (20-storage.sh) so no
  # zfs mount -a can pre-create a root-owned /home/<user>: adduser runs
  # against a clean /home and builds the home directory properly.
  in_target "
    set -e
    id '${TARGET_USERNAME}' >/dev/null 2>&1 ||
      adduser --disabled-password --gecos '' '${TARGET_USERNAME}'
    # adm + systemd-journal: the workstation owner reads logs without sudo.
    # video: brightnessctl writes the backlight through sysfs (Debian builds it
    # without logind); the brightness-udev rule makes that file group-writable
    # by 'video', so the brightness keys are dead without this membership (#48).
    # i2c: external-display brightness over DDC/CI talks to /dev/i2c-* (the i2c-dev
    # nodes are group i2c via udev); membership lets brightness-sync/ddcutil drive
    # external monitors without root (#66). groupadd it first — i2c-tools' postinst
    # usually creates it, but on a resumed run the package may already be stamped.
    getent group i2c >/dev/null || groupadd i2c
    usermod -aG sudo,adm,systemd-journal,video,i2c '${TARGET_USERNAME}'
    # Persistent journal (journald Storage=auto): without this directory,
    # per-user journals are volatile and unreadable by their own user.
    install -d -m 2755 -g systemd-journal /var/log/journal
  "
  # Now that the user owns its parent, enable and mount the dataset; from
  # here on (resumes and the booted system) it auto-mounts normally.
  zfs set canmount=on "${POOL_NAME}/home/Downloads"
  mountpoint -q "${TARGET}/home/${TARGET_USERNAME}/Downloads" ||
    zfs mount "${POOL_NAME}/home/Downloads"
  # Defense in depth for targets installed before the noauto ordering (or
  # any other pre-created home): skel without clobber, then own the whole
  # tree including the Downloads mountpoint.
  in_target "
    set -e
    cp -rnT /etc/skel '/home/${TARGET_USERNAME}'
    chown -R '${TARGET_USERNAME}:${TARGET_USERNAME}' '/home/${TARGET_USERNAME}'
  "
  if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${TARGET_USERNAME}:${USER_PASSWORD}" | chroot "${TARGET}" chpasswd
  elif ((IS_INTERACTIVE)); then
    info "Set a password for ${TARGET_USERNAME}:"
    with_console chroot "${TARGET}" passwd "${TARGET_USERNAME}"
  else
    warn "No USER_PASSWORD and non-interactive: ${TARGET_USERNAME} has no password."
  fi
  if [[ -n "${ROOT_PASSWORD}" ]]; then
    echo "root:${ROOT_PASSWORD}" | chroot "${TARGET}" chpasswd
  fi
}

configure_zfs_boot_support() {
  # Carry the live environment's hostid into the target: the pool was created
  # under it (see create_pool_and_datasets), so the installed system must match
  # or zfs-initramfs refuses the import at first boot. Generating a fresh hostid
  # in the chroot (zgenhostid) guarantees a mismatch — copy the live file in.
  cp /etc/hostid "${TARGET}/etc/hostid"
  in_target "
    set -e
    systemctl enable NetworkManager
  "
  # Give the target the pool cachefile so it imports cleanly at boot.
  # The property must hold the post-boot path, not the /target-prefixed one.
  zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}"
  mkdir -p "${TARGET}/etc/zfs"
  cp /etc/zfs/zpool.cache "${TARGET}/etc/zfs/zpool.cache"
  in_target "update-initramfs -u -k all"
}

# Dell Precision 7780: the kernel auto-selects legacy HDA for the SoundWire
# dual digital-array mics, which then return near full-scale samples. Force
# Linux's SOF driver via a modprobe.d drop-in (firmware-sof-signed is in the
# base set). DMI-guarded: a strict no-op on the VM target and any non-7780
# machine. DMI_PRODUCT_PATH is overridable so tests can fake the DMI read.
configure_audio_quirks() {
  local product=""
  product="$(cat "${DMI_PRODUCT_PATH:-/sys/class/dmi/id/product_name}" \
    2>/dev/null || true)"
  [[ "${product}" == *"Precision 7780"* ]] || return 0
  info "Dell Precision 7780 detected: forcing SOF SoundWire audio driver."
  cat >"${TARGET}/etc/modprobe.d/dell-precision-7780-audio.conf" <<'EOF'
# Managed by installer.sh: force Linux's SOF driver for the Precision 7780
# SoundWire internal audio interface and dual digital-array microphones.
options snd_intel_dspcfg dsp_driver=3
EOF
}

# External-display brightness over DDC/CI (issue #66). ddcci-dkms builds the
# `ddcci` backlight driver (exposing external monitors as /sys/class/backlight
# nodes that brightnessctl can set), and `i2c-dev` exposes the /dev/i2c-* buses
# DDC/CI rides on. Neither is auto-loaded at boot, so drop a modules-load.d file
# to load both early. Unconditional: harmless on a machine with no DDC/CI-capable
# external display (the modules just find nothing to attach to).
configure_ddcci() {
  info "Enabling ddcci + i2c-dev kernel modules for external-display brightness."
  install -d "${TARGET}/etc/modules-load.d"
  cat >"${TARGET}/etc/modules-load.d/ddcci.conf" <<'EOF'
# Managed by installer.sh (issue #66): load the modules backing external-display
# brightness over DDC/CI. ddcci exposes external monitors as /sys/class/backlight
# nodes (brightnessctl-settable); i2c-dev exposes the /dev/i2c-* buses DDC/CI uses.
ddcci
i2c-dev
EOF
}

phase_system() {
  write_identity
  write_fstab
  write_mdadm_conf
  ensure_mok_key
  install_base_packages
  install_nvidia_driver
  install_addon_artifacts
  install_chezmoi
  install_lythmono_fonts
  configure_locale_tz
  configure_time_sync
  neuter_ssh_vsock_generator
  create_user
  # Before configure_zfs_boot_support: its update-initramfs -u -k all then
  # captures the modprobe.d/modules-load.d drop-ins without a second rebuild.
  configure_audio_quirks
  configure_ddcci
  configure_zfs_boot_support
}
