#!/usr/bin/env bash
# Golden-image session staging (issue #111): stage_session_configs must put
# the default user configs into /etc/skel when SESSION_CONFIG_HOME says so,
# stage the machine-independent system files, and leave every per-install
# piece (sudoers rule, user home, keymap-patched config) to configure_session.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source tests/test-helpers.sh

info() { :; }
warn() { :; }
fatal() {
  printf 'fatal: %s\n' "$*" >&2
  return 1
}
# The greetd branch resolves tuigreet through the chroot helper; the systemd
# tail is a no-op here.
in_target() { if [[ "$*" == *"command -v tuigreet"* ]]; then echo /usr/bin/tuigreet; fi; }

source lib/00-config.sh
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "test: stage_session_configs stages user defaults into /etc/skel (golden mode)"
TARGET="${tmp}/golden"
TARGET_USERNAME="tester"
HYPR_AUTOLOGIN=0
CACHE_REPO_DIR="${tmp}/no-store" # walker/kitty sources absent -> warn + skip
mkdir -p "${TARGET}"
SESSION_CONFIG_HOME=/etc/skel stage_session_configs

skel="${TARGET}/etc/skel/.config"
for f in uwsm/env swaync/config.json swaync/style.css \
  xdg-desktop-portal/hyprland-portals.conf; do
  if [[ -f "${skel}/${f}" ]]; then
    echo "  ok: skel carries .config/${f}"
  else
    echo "  FAIL: skel is missing .config/${f}" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
done
assert_contains "$(<"${skel}/uwsm/env")" "QT_QPA_PLATFORMTHEME=gtk3" \
  "skel uwsm env carries the theming defaults"
if [[ "$(<"${skel}/uwsm/env")" == *nvidia* ]]; then
  echo "  FAIL: golden skel uwsm env must not carry NVIDIA lines (per-install)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no NVIDIA lines in the golden skel uwsm env"
fi

# The image default greeter is tuigreet (autologin is a live-boot overlay
# rewrite / a per-install choice, never baked).
greetd_cfg="$(<"${TARGET}/etc/greetd/config.toml")"
assert_contains "${greetd_cfg}" '/usr/bin/cage -s -- /etc/greetd/greeter-displays.sh' \
  "baked greetd default is the cage+tuigreet greeter"
assert_contains "${greetd_cfg}" '_greetd' "baked greeter runs as _greetd"

# Machine-independent system files are staged...
for f in usr/bin/hypr-session usr/bin/brightness-sync usr/bin/drm-reprobe \
  etc/pam.d/hyprlock usr/lib/systemd/user/hyprdim.service \
  etc/greetd/sessions/hyprland.desktop; do
  if [[ -e "${TARGET}/${f}" ]]; then
    echo "  ok: golden staging writes ${f}"
  else
    echo "  FAIL: golden staging missing ${f}" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
done
# ...but the per-install pieces are NOT.
if [[ -e "${TARGET}/etc/sudoers.d/drm-reprobe" ]]; then
  echo "  FAIL: sudoers rule (names the install user) must not bake into the image" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no drm-reprobe sudoers rule in the golden staging"
fi
if [[ -e "${TARGET}/home" ]]; then
  echo "  FAIL: golden staging must not create /home (skel only)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: golden staging writes no user home"
fi

echo "test: write_hypr_lua_config honors SESSION_CONFIG_HOME (skel copy for the live demo)"
mkdir -p "${TARGET}/usr/share/hypr"
cat >"${TARGET}/usr/share/hypr/hyprland.lua" <<'EOF'
-- fake example
------------------
---- KEYBINDS ----
------------------
hl.bind("SUPER + Q", hl.dsp.exit())
EOF
SESSION_CONFIG_HOME=/etc/skel write_hypr_lua_config
if [[ -f "${TARGET}/etc/skel/.config/hypr/hyprland.lua" ]]; then
  echo "  ok: hypr config generated into skel"
else
  echo "  FAIL: hypr config not generated into skel" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

echo "test: configure_session still writes the per-install pieces (installer path)"
TARGET="${tmp}/install-target"
mkdir -p "${TARGET}/usr/share/hypr"
cp "${tmp}/golden/usr/share/hypr/hyprland.lua" "${TARGET}/usr/share/hypr/hyprland.lua"
HYPR_AUTOLOGIN=1
configure_session
if [[ -f "${TARGET}/etc/sudoers.d/drm-reprobe" ]]; then
  echo "  ok: installer path stages the sudoers rule"
  assert_contains "$(<"${TARGET}/etc/sudoers.d/drm-reprobe")" \
    "tester ALL=(root) NOPASSWD: /usr/bin/drm-reprobe" \
    "sudoers rule names the install user"
else
  echo "  FAIL: installer path lost the sudoers rule" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -f "${TARGET}/home/tester/.config/uwsm/env" ]]; then
  echo "  ok: installer path stages user configs into the real home"
else
  echo "  FAIL: installer path did not stage into /home/tester" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
