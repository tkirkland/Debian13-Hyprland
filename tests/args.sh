#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: argument parsing"

run_parse() {
  bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source lib/02-args.sh
    parse_args "$@"
    echo "${BOOTLOADER}|${OFFLINE}|${BUILD_ON_FIRSTBOOT}|${ASSUME_YES}|${RUN_PHASE}|${KEEP_BUILD_DEPS}"
  ' _ "$@"
}

out="$(run_parse --bootloader=grub --offline --yes)"
assert_eq "grub|1|0|1|full|0" "${out}" "flags set expected globals"

out="$(run_parse --bootloader=zbm --build-on-firstboot --keep-build-deps \
  --phase=storage)"
assert_eq "zbm|0|1|0|storage|1" "${out}" "phase + firstboot + keep-build-deps"

assert_fails "rejects unknown bootloader" run_parse --bootloader=lilo
assert_fails "rejects unknown flag" run_parse --bogus
assert_fails "rejects unknown phase" run_parse --phase=nonsense

# Non-interactive + --yes + no bootloader must fail fast (spec).
assert_fails "bootloader required when non-interactive" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/02-args.sh
  IS_INTERACTIVE=0
  parse_args --yes
  require_bootloader_choice'

out="$(run_parse --bootloader=systemd-boot)"
assert_eq "systemd-boot|0|0|0|full|0" "${out}" "systemd-boot accepted"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --jobs=4 --autologin
  echo "${HYPR_BUILD_JOBS}|${HYPR_AUTOLOGIN}"')"
assert_eq "4|1" "${out}" \
  "--jobs, --autologin parsed"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --rtc=local
  echo "${RTC_MODE}"')"
assert_eq "local" "${out}" "--rtc=local sets RTC_MODE"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --rtc=utc
  echo "${RTC_MODE}"')"
assert_eq "utc" "${out}" "--rtc=utc sets RTC_MODE"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args
  echo "[${RTC_MODE}]"')"
assert_eq "[]" "${out}" "RTC is unset by default — neither utc nor local assumed"

assert_fails "--rtc rejects values other than utc|local" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --rtc=eastern'

# The old opt-in flag is gone; it must now be an unknown-option error.
assert_fails "--local-rtc flag removed" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --local-rtc'

# The upstream OpenZFS build is forced on networked installs; the old
# opt-in flag must be gone (unknown flags are usage errors).
assert_fails "--zfs-from-source flag removed" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --zfs-from-source'

assert_fails "--jobs rejects non-numeric values" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --jobs=many'

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --ntp="0.pool.ntp.org time.cloudflare.com"
  echo "${NTP_SERVERS}"')"
assert_eq "0.pool.ntp.org time.cloudflare.com" "${out}" \
  "--ntp sets NTP_SERVERS (space-separated, optional value-flag)"

out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args
  echo "[${NTP_SERVERS}]"')"
assert_eq "[]" "${out}" "NTP_SERVERS is empty by default (Debian-stock timesyncd)"

finish_test
