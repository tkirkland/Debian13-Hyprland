#!/usr/bin/env bash
# tests/xkb-autodetect.sh — unit tests for autodetect_keymap
# (scripts/40-system.sh): keyboard layout detection from the live session's
# /etc/default/keyboard, with explicit env/CLI values always winning and
# every candidate validated against the TARGET's xkb rules (evdev.lst) and
# re-checked against the injection-surface regexes before it can replace the
# config fallback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=scripts/40-system.sh
source "${HERE}/../scripts/40-system.sh"

# --- collaborators stubbed (invoked indirectly under test) --------------------
# shellcheck disable=SC2317  # called indirectly by autodetect_keymap
info() { :; }

# Fake TARGET tree: an evdev.lst carrying two layouts and one de variant.
TARGET="$(mktemp -d)"
trap 'rm -rf "${TARGET}"' EXIT
mkdir -p "${TARGET}/usr/share/X11/xkb/rules"
cat >"${TARGET}/usr/share/X11/xkb/rules/evdev.lst" <<'EOF'
! model
  pc105           Generic 105-key PC

! layout
  us              English (US)
  de              German

! variant
  nodeadkeys      de: German (no dead keys)
  intl            us: English (US, intl., with dead keys)

! option
EOF

# Fake live /etc/default/keyboard, pointed at via XKB_DETECT_SRC.
LIVE_KBD="$(mktemp)"
trap 'rm -rf "${TARGET}" "${LIVE_KBD}"' EXIT
write_live() { # layout variant options
  {
    printf 'XKBMODEL="pc105"\n'
    printf 'XKBLAYOUT="%s"\n' "$1"
    printf 'XKBVARIANT="%s"\n' "$2"
    printf 'XKBOPTIONS="%s"\n' "$3"
  } >"${LIVE_KBD}"
}

run_case() { # LAYOUT_EXPLICIT VARIANT_EXPLICIT OPTIONS_EXPLICIT
  XKB_LAYOUT_EXPLICIT="$1" XKB_VARIANT_EXPLICIT="$2" XKB_OPTIONS_EXPLICIT="$3"
  XKB_LAYOUT="us" XKB_VARIANT="" XKB_MODEL="pc105" XKB_OPTIONS=""
  XKB_DETECT_SRC="${LIVE_KBD}"
  autodetect_keymap
}

echo "test: keyboard autodetection (live file, validated against target evdev.lst)"
write_live "de" "nodeadkeys" "grp:alt_shift_toggle"
run_case "" "" ""
assert_eq "de" "${XKB_LAYOUT}" "valid live layout replaces the fallback"
assert_eq "nodeadkeys" "${XKB_VARIANT}" "valid live variant accepted for the layout"
assert_eq "grp:alt_shift_toggle" "${XKB_OPTIONS}" "well-formed live options accepted"

write_live "xx" "" ""
run_case "" "" ""
assert_eq "us" "${XKB_LAYOUT}" "layout absent from target evdev.lst keeps the fallback"

write_live "de" "bogusvariant" ""
run_case "" "" ""
assert_eq "de" "${XKB_LAYOUT}" "valid layout accepted even with a bogus variant"
assert_eq "" "${XKB_VARIANT}" "variant unknown for the layout is dropped, not guessed"

rm -f "${LIVE_KBD}"
run_case "" "" ""
assert_eq "us" "${XKB_LAYOUT}" "missing live file keeps the fallback"

write_live "de" "nodeadkeys" ""
run_case "1" "" ""
assert_eq "us" "${XKB_LAYOUT}" "explicit XKB_LAYOUT wins over detection"
assert_eq "" "${XKB_VARIANT}" "variant not autodetected under an explicit layout"

# An operator-chosen variant must survive a layout-only autodetect.
write_live "de" "nodeadkeys" ""
XKB_LAYOUT_EXPLICIT="" XKB_VARIANT_EXPLICIT="1" XKB_OPTIONS_EXPLICIT=""
XKB_LAYOUT="us" XKB_VARIANT="intl" XKB_MODEL="pc105" XKB_OPTIONS=""
XKB_DETECT_SRC="${LIVE_KBD}"
autodetect_keymap
assert_eq "de" "${XKB_LAYOUT}" "layout still autodetected alongside an explicit variant"
assert_eq "intl" "${XKB_VARIANT}" "explicit XKB_VARIANT wins over detection"

echo "test: injection-shaped live values can never reach the chroot"
printf 'XKBLAYOUT="de'"'"'; rm -rf /"\n' >"${LIVE_KBD}"
run_case "" "" ""
assert_eq "us" "${XKB_LAYOUT}" "injection-shaped live layout keeps the fallback"

write_live "de" 'x"; rm -rf /' 'o; rm -rf /'
run_case "" "" ""
assert_eq "de" "${XKB_LAYOUT}" "layout accepted while hostile fields are dropped"
assert_eq "" "${XKB_VARIANT}" "injection-shaped variant is dropped"
assert_eq "" "${XKB_OPTIONS}" "injection-shaped options are dropped"

finish_test
