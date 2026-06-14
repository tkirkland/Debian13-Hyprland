#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: Precision 7780 SOF audio mic quirk (DMI-guarded)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# configure_audio_quirks reads DMI_PRODUCT_PATH (overridable) and only writes
# the modprobe.d drop-in when the product is a Precision 7780.
run_quirk() { # $1 = product_name string, $2 = target subdir
  bash -c '
    set -euo pipefail
    info() { :; }
    source scripts/40-system.sh
    TARGET="'"${tmp}/$2"'"
    mkdir -p "${TARGET}/etc/modprobe.d"
    printf "%s\n" "'"$1"'" >"'"${tmp}/pn-$2"'"
    DMI_PRODUCT_PATH="'"${tmp}/pn-$2"'"
    configure_audio_quirks
    conf="${TARGET}/etc/modprobe.d/dell-precision-7780-audio.conf"
    if [[ -f "${conf}" ]]; then echo "WROTE"; cat "${conf}"; else echo "ABSENT"; fi
  '
}

out="$(run_quirk "Precision 7780" match)"
assert_contains "${out}" "WROTE" "drop-in written on the Precision 7780"
assert_contains "${out}" "dsp_driver=3" "drop-in forces the SOF SoundWire driver"

out="$(run_quirk "OptiPlex 7090" nomatch)"
assert_eq "ABSENT" "${out}" "no drop-in on non-7780 hardware (strict no-op)"

# A missing DMI source (e.g. a VM with no product_name) is a no-op, not an
# error — the function must survive set -e with the file absent.
out="$(bash -c '
  set -euo pipefail
  info() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}/vm"'"
  mkdir -p "${TARGET}/etc/modprobe.d"
  DMI_PRODUCT_PATH="'"${tmp}/does-not-exist"'"
  configure_audio_quirks
  find "${TARGET}/etc/modprobe.d" -type f | wc -l')"
assert_eq "0" "${out}" "missing DMI product_name is a safe no-op"

finish_test
