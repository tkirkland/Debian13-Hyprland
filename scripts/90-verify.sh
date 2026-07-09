# shellcheck shell=bash
# Verification suite: every spec-mandated success condition, reported
# together; nonzero exit if anything fails.

VERIFY_TOTAL=0
VERIFY_FAILED=0

vcheck() { # $1=label, rest=command
  local label="$1" out="" rc=0
  shift
  VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  if out="$("$@" 2>&1)"; then
    info "PASS: ${label}"
  else
    rc=$?
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
    warn "FAIL: ${label} (exit ${rc})"
    # Surface the failing command's tail so failures are diagnosable
    # from the report alone.
    [[ -z "${out}" ]] || warn "      $(printf '%s' "${out}" | tail -n 3)"
  fi
}

verify_report() {
  if ((VERIFY_FAILED > 0)); then
    warn "${VERIFY_FAILED} of ${VERIFY_TOTAL} checks failed."
    return 1
  fi
  info "All ${VERIFY_TOTAL} checks passed."
}

phase_verify() {
  local esp="${TARGET}${ESP_MOUNT}" kver="" vers="" f="" greeter_bin="" sb_dir=""
  for f in "${TARGET}"/boot/vmlinuz-*; do
    [[ -e "${f}" ]] || continue
    vers+="${f##*/vmlinuz-}"$'\n'
  done
  kver="$(printf '%s' "${vers}" | sort -V | tail -n1)"

  if ((BUILD_ON_FIRSTBOOT)); then
    vcheck "firstboot unit enabled" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
    vcheck "firstboot runner staged" \
      test -x "${TARGET}/usr/sbin/hypr-deb-firstboot"
    vcheck "hyprland firstboot job staged" test -x \
      "${TARGET}/usr/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
    vcheck "sources staged" \
      test -d "${TARGET}/var/tmp/hypr-deb-build/hyprland"
    vcheck "toolchain staged for firstboot" in_target "command -v cmake"
  else
    # Hyprland refuses to run as root and aborts without XDG_RUNTIME_DIR
    # (set by pam_systemd in real logins); provide both for the check.
    vcheck "Hyprland binary runs" in_target "
      set -e
      install -d -m 700 -o '${TARGET_USERNAME}' /tmp/hypr-verify-rt
      runuser -u '${TARGET_USERNAME}' -- \
        env XDG_RUNTIME_DIR=/tmp/hypr-verify-rt \
        /usr/bin/Hyprland --version
      rm -rf /tmp/hypr-verify-rt
    "
    vcheck "Hyprland links resolve" in_target \
      "! ldd /usr/bin/Hyprland | grep -q 'not found'"
    # guiutils builds every util from its root CMakeLists; if a future tag
    # drops or renames the welcome util, fail loudly here (issue #11).
    vcheck "welcome app installed" \
      test -x "${TARGET}/usr/bin/hyprland-welcome"
  fi

  # Screenshot/recording capture helpers + deps (epic #67, item 1). Staged
  # unconditionally by configure_session, so verified on both install paths.
  vcheck "screenshot helper staged" test -x \
    "${TARGET}/usr/bin/linux-screenshot"
  vcheck "screen-record helper staged" test -x \
    "${TARGET}/usr/bin/linux-screen-record"
  vcheck "screenshot deps present (grim/slurp/jq)" in_target \
    "command -v grim && command -v slurp && command -v jq"
  vcheck "recording deps present (wf-recorder/notify-send/pactl)" in_target \
    "command -v wf-recorder && command -v notify-send && command -v pactl"

  # swaync notification daemon + user config (epic #67, item 2). Package
  # auto-enables swaync.service; config staged by stage_swaync_config.
  vcheck "swaync installed" in_target "command -v swaync && command -v swaync-client"
  vcheck "swaync config staged" test -f \
    "${TARGET}/home/${TARGET_USERNAME}/.config/swaync/config.json"
  vcheck "swaync style staged" test -f \
    "${TARGET}/home/${TARGET_USERNAME}/.config/swaync/style.css"

  # Portal stack + polkit agent + file manager (issues #57, #67 items 3/4, #70).
  # Staged unconditionally, so verified on both install paths. xdph is deliberately
  # NOT asserted here — it is a best-effort optional backend; the packaged wlr
  # backend (always installed) plus the static routing conf are the guarantee.
  vcheck "xdg-desktop-portal + gtk + wlr installed" in_target \
    "dpkg -s xdg-desktop-portal && dpkg -s xdg-desktop-portal-gtk && dpkg -s xdg-desktop-portal-wlr"
  vcheck "wlr portal impl file present" test -f \
    "${TARGET}/usr/share/xdg-desktop-portal/portals/wlr.portal"
  vcheck "portal routing conf staged" test -f \
    "${TARGET}/home/${TARGET_USERNAME}/.config/xdg-desktop-portal/hyprland-portals.conf"
  vcheck "portal routing prefers hyprland;wlr ScreenCast" \
    grep -q 'ScreenCast=hyprland;wlr' \
    "${TARGET}/home/${TARGET_USERNAME}/.config/xdg-desktop-portal/hyprland-portals.conf"
  vcheck "portal routing default is gtk" \
    grep -q '^default=gtk' \
    "${TARGET}/home/${TARGET_USERNAME}/.config/xdg-desktop-portal/hyprland-portals.conf"
  vcheck "dark-mode gschema override staged" test -f \
    "${TARGET}/usr/share/glib-2.0/schemas/90-hypr-deb.gschema.override"
  # Dark theming defaults (#51/#76): packages, gschema keys, theme dirs, uwsm env.
  vcheck "theming packages installed (gnome-themes-extra/qt6-gtk-platformtheme/papirus/adwaita)" \
    in_target "dpkg -s gnome-themes-extra && dpkg -s qt6-gtk-platformtheme &&
      dpkg -s papirus-icon-theme && dpkg -s adwaita-icon-theme"
  vcheck "gschema override selects adw-gtk3-dark GTK theme" \
    grep -q "gtk-theme='adw-gtk3-dark'" \
    "${TARGET}/usr/share/glib-2.0/schemas/90-hypr-deb.gschema.override"
  vcheck "gschema override selects Papirus-Dark icons" \
    grep -q "icon-theme='Papirus-Dark'" \
    "${TARGET}/usr/share/glib-2.0/schemas/90-hypr-deb.gschema.override"
  vcheck "gschema override pins the Adwaita cursor" \
    grep -q "cursor-theme='Adwaita'" \
    "${TARGET}/usr/share/glib-2.0/schemas/90-hypr-deb.gschema.override"
  vcheck "adw-gtk3-dark theme installed" test -d \
    "${TARGET}/usr/share/themes/adw-gtk3-dark"
  vcheck "uwsm env routes Qt through the gtk3 platform theme" \
    grep -q "QT_QPA_PLATFORMTHEME" \
    "${TARGET}/home/${TARGET_USERNAME}/.config/uwsm/env"
  vcheck "lxpolkit installed" in_target "command -v lxpolkit"
  vcheck "lxpolkit autostart present" test -f \
    "${TARGET}/etc/xdg/autostart/lxpolkit.desktop"
  vcheck "dolphin file manager installed" in_target "command -v dolphin"

  vcheck "greetd enabled" in_target "systemctl is-enabled greetd"
  vcheck "systemd-timesyncd enabled" in_target "systemctl is-enabled systemd-timesyncd"
  vcheck "uwsm present" in_target "command -v uwsm"
  # greetd spawns the greeter with no PATH (PAM env only): the binary the
  # config names must exist at exactly that absolute path.
  greeter_bin="$(grep -oP '^command = "\K[^ "]+' \
    "${TARGET}/etc/greetd/config.toml" 2>/dev/null || true)"
  vcheck "greetd session command binary exists (${greeter_bin:-none})" bash -c \
    "[[ -n '${greeter_bin}' && -x '${TARGET}${greeter_bin}' ]]"
  vcheck "session launcher at /usr/bin/uwsm" \
    test -x "${TARGET}/usr/bin/uwsm"
  # The quiet-VT wrapper both session modes launch through (issue #12).
  vcheck "session wrapper at /usr/bin/hypr-session" \
    test -x "${TARGET}/usr/bin/hypr-session"
  # shellcheck disable=SC2016  # the $() must expand inside the chroot, not here
  vcheck "getty@tty1 masked (no VT1 contention with greetd)" in_target \
    '[[ "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" == masked ]]'
  vcheck "user hyprland.lua exists" \
    test -f "${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.lua"

  # Keyboard layout (console + greeter + Hyprland). Dynamic read-back like
  # greeter_bin above, so standalone --phase=verify runs check the target's
  # actual configuration, not this shell's re-sourced default.
  vcheck "keyboard config written" \
    grep -q '^XKBLAYOUT="[a-z]' "${TARGET}/etc/default/keyboard"
  vcheck "keyboard-configuration installed" \
    in_target "dpkg -s keyboard-configuration >/dev/null"
  kb="$(sed -n 's/^XKBLAYOUT="\?\([^"]*\)"\?$/\1/p' \
    "${TARGET}/etc/default/keyboard" 2>/dev/null || true)"
  vcheck "greeter XKB env staged (${kb:-none})" \
    grep -q "^XKB_DEFAULT_LAYOUT=${kb}$" "${TARGET}/etc/environment"
  # Only when a module carries kb_layout at all: a kb_layout-less upstream
  # example is legal (libxkbcommon falls back to the XKB_DEFAULT_* env), so
  # its absence must not fail a plain-us install.
  if grep -rqE 'kb_layout[[:space:]]*=' \
    "${TARGET}/home/${TARGET_USERNAME}/.config/hypr" 2>/dev/null; then
    vcheck "hyprland kb_layout matches console (${kb:-none})" \
      grep -rq "kb_layout.*\"${kb}\"" \
      "${TARGET}/home/${TARGET_USERNAME}/.config/hypr"
  fi

  # NVIDIA (issue #4): only when a GPU was detected and a driver chosen.
  # Both flavors install offline from /hypr-repo now (Phase 5), so this is
  # checked regardless of network. nvidia-driver (the shared userspace) is
  # present for BOTH flavors — nvidia-open Depends on it — so it is a flavor-
  # agnostic probe that also holds under the pre-Turing proprietary fallback.
  if nvidia_install_requested; then
    vcheck "NVIDIA driver userspace installed (nvidia-driver)" \
      in_target "dpkg -s nvidia-driver >/dev/null"
    vcheck "nvidia-drm modeset configured" \
      grep -q "nvidia-drm" "${TARGET}/etc/modprobe.d/nvidia-options.conf"
    vcheck "uwsm env carries NVIDIA variables" \
      grep -q "__GLX_VENDOR_LIBRARY_NAME" \
      "${TARGET}/home/${TARGET_USERNAME}/.config/uwsm/env"
  fi

  vcheck "kernel on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/vmlinuz-* >/dev/null 2>&1"
  vcheck "initramfs on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/initrd.img-* >/dev/null 2>&1"
  # A root-on-ZFS system is unbootable without these two; dkms skips the
  # module build silently when target kernel headers are missing.
  vcheck "zfs module built for target kernel" in_target \
    "modinfo -k '${kver}' zfs >/dev/null"
  vcheck "initramfs contains zfs module" in_target \
    "lsinitramfs '/boot/initrd.img-${kver}' | grep -q '/zfs.ko'"

  case "${BOOTLOADER}" in
    zbm)
      vcheck "ZBM EFI on ESP" test -f "${esp}/EFI/zbm/zfsbootmenu.efi"
      vcheck "ZBM cmdline property" bash -c \
        "zfs get -H -o value org.zfsbootmenu:commandline '${ROOT_DATASET}' |
         grep -q rw"
      vcheck "NVRAM entry (ZFSBootMenu)" bash -c \
        "efibootmgr | grep -q 'ZFSBootMenu'"
      ;;
    grub)
      vcheck "GRUB EFI on ESP" test -f "${esp}/EFI/debian/grubx64.efi"
      vcheck "grub.cfg on ESP" test -f "${esp}/EFI/debian/grub/grub.cfg"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      vcheck "initrd copy on ESP" test -f "${esp}/EFI/debian/initrd.img"
      vcheck "NVRAM entry (debian)" bash -c \
        "efibootmgr | grep -qE '^Boot[0-9A-F]{4}.* debian'"
      ;;
    systemd-boot)
      vcheck "sd-boot EFI on ESP" \
        test -f "${esp}/EFI/systemd/systemd-bootx64.efi"
      vcheck "loader entry on ESP" \
        test -f "${esp}/loader/entries/debian.conf"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      vcheck "initrd copy on ESP" test -f "${esp}/EFI/debian/initrd.img"
      vcheck "NVRAM entry (Linux Boot Manager)" bash -c \
        "efibootmgr | grep -q 'Linux Boot Manager'"
      ;;
  esac

  # Secure boot chain: shim + MokManager beside the loader; self-shipped
  # loaders (zbm, systemd-boot) verify against the MOK cert. GRUB's
  # grubx64.efi is Debian-signed, so presence (checked above) suffices.
  case "${BOOTLOADER}" in
    zbm) sb_dir="zbm" ;;
    grub) sb_dir="debian" ;;
    systemd-boot) sb_dir="systemd" ;;
  esac
  vcheck "shim on ESP" test -f "${esp}/EFI/${sb_dir}/shimx64.efi"
  vcheck "MokManager on ESP" test -f "${esp}/EFI/${sb_dir}/mmx64.efi"
  vcheck "chain-loaded loader on ESP" \
    test -f "${esp}/EFI/${sb_dir}/grubx64.efi"
  if [[ "${BOOTLOADER}" != "grub" ]]; then
    vcheck "loader MOK signature valid" in_target \
      "sbverify --cert '${MOK_PEM}' '${ESP_MOUNT}/EFI/${sb_dir}/grubx64.efi'"
  fi
  # Warn-only: SB-incapable firmware / no efivars cannot stage the import.
  # MOK_STAGED also gates the closing "Secure boot: ready" message — do not
  # promise the MokManager first-boot screen when nothing was staged.
  MOK_STAGED=1
  if ! in_target "mokutil --list-new 2>/dev/null | grep -q ."; then
    MOK_STAGED=0
    warn "MOK enrollment not staged — the boot-phase warning above has" \
      "mokutil's reason. On the installed system run:" \
      "mokutil --import ${MOK_CRT}"
  fi

  vcheck "fstab ESP UUID valid" bash -c \
    "uuid=\$(grep -oP 'UUID=\K[^ ]+(?= /boot/efi)' '${TARGET}/etc/fstab');
     [[ -n \"\${uuid}\" ]] && blkid -U \"\${uuid}\""
  vcheck "mdadm.conf present" test -s "${TARGET}/etc/mdadm/mdadm.conf"
  vcheck "zfs-zed enabled (pool fault reporting)" in_target \
    "systemctl is-enabled zfs-zed"
  # BOTH paths replace Debian's zfs with the upstream build (online from source,
  # offline from the on-ISO pool via install_zfs_offline), so the upstream package
  # must be present regardless of network — verify it unconditionally.
  vcheck "upstream openzfs installed" in_target \
    "dpkg -s openzfs-zfsutils >/dev/null"
  vcheck "pool bootfs set" bash -c \
    "zpool get -H -o value bootfs '${POOL_NAME}' |
     grep -qx '${ROOT_DATASET}'"
  # The package store is ISO-only: the installed system's permanent apt
  # sources are the real Debian mirror, and no repo is embedded in the target
  # (embed_cache_in_target was removed). Nothing to verify in the target here.

  verify_report || fatal "Verification failed — installation is NOT complete."
  info "SUCCESS: bootable Debian + Hyprland conditions both met."
  if ((${MOK_STAGED:-0})); then
    info "Secure boot: ready. First boot shows the blue MokManager screen —"
    info "choose 'Enroll MOK' and enter your user password. After that you"
    info "may enable secure boot in firmware at any time."
  else
    info "Secure boot: NOT staged (see MOK warnings above). The system boots"
    info "with secure boot off; stage later with 'mokutil --import ${MOK_CRT}'"
    info "on the installed system, then reboot and enroll at MokManager."
  fi
}
