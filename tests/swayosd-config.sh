#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: swayosd on-screen display (package + unit + binds + OSD)"

# --- package ----------------------------------------------------------------
config="$(<lib/00-config.sh)"
assert_contains "${config}" " swayosd " "TARGET_BASE_PACKAGES includes swayosd"

# --- staged output ----------------------------------------------------------
info() { :; }
warn() { :; }
in_target() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"
TARGET_USERNAME="tester"
HYPR_AUTOLOGIN=1

# Fake upstream example: a KEYBINDS section carrying the verbatim upstream
# wpctl audio binds (the text the installer's sed must match) plus the
# playerctl media binds that must survive untouched.
mkdir -p "${TARGET}${HYPR_SRC_DIR}/hyprland/example"
cat >"${TARGET}${HYPR_SRC_DIR}/hyprland/example/hyprland.lua" <<'EOF'
-- fake upstream example for tests

------------------
---- KEYBINDS ----
------------------
local mainMod = "SUPER"
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
EOF
mkdir -p "${TARGET}/etc/default"
printf 'XKBLAYOUT="us"\nXKBVARIANT=""\nXKBOPTIONS=""\n' \
  >"${TARGET}/etc/default/keyboard"

configure_session

# --- volume/mic keybinds rebound to swayosd-client --------------------------
binds="$(<"${TARGET}/home/${TARGET_USERNAME}/.config/hypr/keybinds.lua")"
assert_contains "${binds}" 'swayosd-client --output-volume raise' \
  "XF86AudioRaiseVolume drives swayosd-client"
assert_contains "${binds}" 'swayosd-client --output-volume lower' \
  "XF86AudioLowerVolume drives swayosd-client"
assert_contains "${binds}" 'swayosd-client --output-volume mute-toggle' \
  "XF86AudioMute drives swayosd-client"
assert_contains "${binds}" 'swayosd-client --input-volume mute-toggle' \
  "XF86AudioMicMute drives swayosd-client"
if printf '%s\n' "${binds}" | grep -qE 'XF86Audio(Raise|Lower)?(Volume|Mute|MicMute).*wpctl'; then
  echo "  FAIL: upstream wpctl audio binds survived (double-fire with swayosd)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no upstream wpctl audio bind remains"
fi
# Volume keys repeat while held; mute toggles must not.
raise_line="$(printf '%s\n' "${binds}" | grep 'XF86AudioRaiseVolume')"
mute_line="$(printf '%s\n' "${binds}" | grep 'XF86AudioMute')"
assert_contains "${raise_line}" 'repeating = true' "volume keys stay repeating"
assert_contains "${mute_line}" 'locked = true' "mute toggle stays locked"
if [[ "${mute_line}" == *"repeating"* ]]; then
  echo "  FAIL: mute toggle must not repeat while held" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: mute toggle does not repeat"
fi
assert_contains "${binds}" 'playerctl next' "playerctl media binds untouched"

# --- swayosd-server user unit (deb ships none — installer glue) -------------
unit="${TARGET}/usr/lib/systemd/user/swayosd.service"
if [[ -f "${unit}" ]]; then
  echo "  ok: swayosd.service staged at /usr/lib/systemd/user (installer glue)"
  unit_txt="$(<"${unit}")"
  assert_contains "${unit_txt}" "ExecStart=/usr/bin/swayosd-server" \
    "unit execs swayosd-server"
  assert_contains "${unit_txt}" "WantedBy=graphical-session.target" \
    "unit is wanted by graphical-session.target"
else
  echo "  FAIL: swayosd.service unit missing" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
wants="${TARGET}/etc/systemd/user/graphical-session.target.wants/swayosd.service"
if [[ -L "${wants}" && "$(readlink "${wants}")" == "/usr/lib/systemd/user/swayosd.service" ]]; then
  echo "  ok: swayosd.service linked into graphical-session.target.wants"
else
  echo "  FAIL: swayosd.service wants-link missing or wrong target" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- brightness OSD: display-only, best-effort ------------------------------
bs="$(<"${TARGET}/usr/bin/brightness-sync")"
assert_contains "${bs}" 'swayosd-client --custom-message' \
  "brightness up/down fires a swayosd OSD popup"
assert_contains "${bs}" 'display-brightness-symbolic' \
  "OSD uses the brightness icon"
# swayosd is DISPLAY-ONLY: the control arms (_nudge_conn/_apply_conn) that
# actually set brightness must carry NO swayosd reference.
for fn in _nudge_conn _apply_conn; do
  body="$(printf '%s\n' "${bs}" | awk -v f="${fn}" '
    index($0, f "()") == 1 {p=1} p {print} p && /^}/ {exit}')"
  if [[ -z "${body}" ]]; then
    echo "  FAIL: could not extract ${fn} from brightness-sync" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  elif [[ "${body}" == *swayosd* ]]; then
    echo "  FAIL: ${fn} references swayosd (must stay display-only)" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    echo "  ok: ${fn} is clean of swayosd (control path untouched)"
  fi
done

# --- style.css on the installer palette -------------------------------------
grep -q 'stage_swayosd_config$' scripts/60-hyprland.sh \
  || { echo "  FAIL: configure_session does not call stage_swayosd_config" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
css="${TARGET}/home/${TARGET_USERNAME}/.config/swayosd/style.css"
if [[ -f "${css}" ]]; then
  css_txt="$(<"${css}")"
  assert_contains "${css_txt}" '#1e1e2e' "dark OSD background"
  assert_contains "${css_txt}" '#f5f5f5' "light text"
  assert_contains "${css_txt}" '#4a6f9a' "theme accent on the progress bar"
else
  echo "  FAIL: swayosd style.css not staged" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
