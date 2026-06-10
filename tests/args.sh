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

finish_test
