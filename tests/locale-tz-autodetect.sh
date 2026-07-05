#!/usr/bin/env bash
# tests/locale-tz-autodetect.sh — unit tests for autodetect_locale_tz
# (scripts/40-system.sh): GeoIP timezone + live-LANG locale detection, with
# explicit env overrides always winning and every candidate validated against
# the TARGET's zoneinfo/locale.gen before it can replace the config fallback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
# shellcheck source=scripts/40-system.sh
source "${HERE}/../scripts/40-system.sh"

# --- collaborators stubbed (invoked indirectly under test) --------------------
# shellcheck disable=SC2317  # called indirectly by autodetect_locale_tz
info() { :; }

# Fake TARGET tree: one valid zone, one locale.gen with a commented candidate.
TARGET="$(mktemp -d)"
trap 'rm -rf "${TARGET}"' EXIT
mkdir -p "${TARGET}/usr/share/zoneinfo/Europe"
: >"${TARGET}/usr/share/zoneinfo/Europe/Berlin"
mkdir -p "${TARGET}/etc"
printf '# de_DE.UTF-8 UTF-8\n# en_US.UTF-8 UTF-8\n' >"${TARGET}/etc/locale.gen"

# curl fake: emits ${GEOIP_ANSWER} or fails when it is empty (offline case).
CURL_CALLS=0
# shellcheck disable=SC2317  # called indirectly by autodetect_locale_tz
curl() {
  CURL_CALLS=$((CURL_CALLS + 1))
  [[ -n "${GEOIP_ANSWER}" ]] || return 22
  printf '%s' "${GEOIP_ANSWER}"
}

run_case() { # GEOIP_ANSWER TZ_EXPLICIT LOCALE_EXPLICIT LANG_VALUE
  GEOIP_ANSWER="$1" TIMEZONE_EXPLICIT="$2" LOCALE_EXPLICIT="$3" LANG="$4"
  TIMEZONE="America/New_York" LOCALE="en_US.UTF-8" CURL_CALLS=0
  autodetect_locale_tz
}

echo "test: timezone autodetection (GeoIP, validated against target zoneinfo)"
run_case "Europe/Berlin" "" "" ""
assert_eq "Europe/Berlin" "${TIMEZONE}" "valid GeoIP zone replaces the fallback"

run_case "Mars/Olympus" "" "" ""
assert_eq "America/New_York" "${TIMEZONE}" "zone missing from target zoneinfo keeps the fallback"

run_case "utter garbage no slash" "" "" ""
assert_eq "America/New_York" "${TIMEZONE}" "non-Area/City GeoIP answer keeps the fallback"

run_case "" "" "" ""
assert_eq "America/New_York" "${TIMEZONE}" "offline (curl fails fast) keeps the fallback"

run_case "Europe/Berlin" "1" "" ""
assert_eq "America/New_York" "${TIMEZONE}" "explicit TIMEZONE env wins over detection"
assert_eq "0" "${CURL_CALLS}" "explicit TIMEZONE skips the GeoIP lookup entirely"

echo "test: locale autodetection (live LANG, validated against target locale.gen)"
run_case "" "1" "" "de_DE.UTF-8"
assert_eq "de_DE.UTF-8" "${LOCALE}" "live LANG present in target locale.gen replaces the fallback"

run_case "" "1" "" "xx_XX.UTF-8"
assert_eq "en_US.UTF-8" "${LOCALE}" "LANG absent from target locale.gen keeps the fallback"

run_case "" "1" "" "C.UTF-8"
assert_eq "en_US.UTF-8" "${LOCALE}" "C.* live LANG keeps the fallback"

run_case "" "1" "" "POSIX"
assert_eq "en_US.UTF-8" "${LOCALE}" "POSIX live LANG keeps the fallback"

run_case "" "1" "" ""
assert_eq "en_US.UTF-8" "${LOCALE}" "empty live LANG keeps the fallback"

run_case "" "1" "1" "de_DE.UTF-8"
assert_eq "en_US.UTF-8" "${LOCALE}" "explicit LOCALE env wins over detection"

finish_test
