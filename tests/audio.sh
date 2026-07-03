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

echo "test: UCM phantom-jack fix (speaker/internal mic availability)"
# configure_ucm_phantom_jacks patches the stock alsa-ucm-conf files to bind the
# always-present phantom jacks, parking the stock copy at *.distrib behind a
# dpkg diversion (in_target stubbed: the diversion registration is chroot-only).
ucm_dir="${tmp}/ucm/usr/share/alsa/ucm2/HDA"
mkdir -p "${ucm_dir}" "${tmp}/ucm/etc/modprobe.d"
printf '\t\t\tPlaybackMixerElem "Speaker"\n' >"${ucm_dir}/HiFi-analog.conf"
printf '\t\t\t\tDeviceMicComment "Internal Stereo Microphone"\n' \
  >"${ucm_dir}/HiFi-mic.conf"
out="$(bash -c '
  set -euo pipefail
  info() { :; }
  in_target() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}/ucm"'"
  printf "%s\n" "Precision 7780" >"'"${tmp}/pn-ucm"'"
  DMI_PRODUCT_PATH="'"${tmp}/pn-ucm"'"
  configure_audio_quirks
  configure_audio_quirks  # rerun: must stay single-insertion (idempotent)
  cd "'"${ucm_dir}"'"
  echo "analog:$(grep -c "JackControl \"Speaker Phantom Jack\"" HiFi-analog.conf)"
  echo "mic:$(grep -c "DeviceMicJack \"Internal Mic Phantom Jack\"" HiFi-mic.conf)"
  echo "stock-analog:$(grep -c "Phantom" HiFi-analog.conf.distrib || true)"
  echo "stock-mic:$(grep -c "Phantom" HiFi-mic.conf.distrib || true)"
')"
assert_contains "${out}" "analog:1" "speaker phantom jack bound exactly once"
assert_contains "${out}" "mic:1" "internal mic phantom jack bound exactly once"
assert_contains "${out}" "stock-analog:0" "stock analog copy parked unpatched at .distrib"
assert_contains "${out}" "stock-mic:0" "stock mic copy parked unpatched at .distrib"

# An upstream reshape of the UCM files (marker lines gone) must be a strict
# no-op: no patch, no diversion, no error under set -e.
ucm2_dir="${tmp}/ucm2/usr/share/alsa/ucm2/HDA"
mkdir -p "${ucm2_dir}" "${tmp}/ucm2/etc/modprobe.d"
printf 'SomethingElse "Speaker"\n' >"${ucm2_dir}/HiFi-analog.conf"
printf 'SomethingElse "Mic"\n' >"${ucm2_dir}/HiFi-mic.conf"
out="$(bash -c '
  set -euo pipefail
  info() { :; }
  in_target() { :; }
  source scripts/40-system.sh
  TARGET="'"${tmp}/ucm2"'"
  printf "%s\n" "Precision 7780" >"'"${tmp}/pn-ucm2"'"
  DMI_PRODUCT_PATH="'"${tmp}/pn-ucm2"'"
  configure_audio_quirks
  find "'"${ucm2_dir}"'" -name "*.distrib" | wc -l
  grep -c "Phantom" "'"${ucm2_dir}"'"/*.conf || true')"
assert_contains "${out}" "0" "reshaped UCM layout is a strict no-op"

finish_test
