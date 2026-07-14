#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: standalone offline --phase=hyprland wires the on-ISO repo"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
log="${tmp}/hypr.log"

# Standalone offline --phase=hyprland: bootstrap's wiring was torn down at the
# end of that run, so the phase must wire the on-ISO store around its apt
# install — the same treatment phase_system/install_grub/install_sdboot got.
bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/50-boot.sh
  source scripts/60-hyprland.sh
  NETWORK_AVAILABLE=0
  LOG="$1"
  TARGET="/nonexistent"
  mountpoint() { return 1; }
  in_target() { echo "in_target: $1" >>"${LOG}"; }
  setup_target_iso_repo() { echo setup_target_iso_repo >>"${LOG}"; }
  teardown_target_iso_repo() { echo teardown_target_iso_repo >>"${LOG}"; }
  install_xdph_best_effort() { :; }
  configure_session() { :; }
  phase_hyprland
' _ "${log}" >/dev/null 2>&1 || true

out="$(cat "${log}" 2>/dev/null || true)"
assert_contains "${out}" "setup_target_iso_repo" \
  "offline hyprland: wires the on-ISO repo"
assert_contains "${out}" "apt-get install -y" \
  "offline hyprland: installs the prebuilt stack"
assert_eq "setup_target_iso_repo" "$(head -n1 "${log}" 2>/dev/null || true)" \
  "offline hyprland: wiring precedes apt"
assert_eq "teardown_target_iso_repo" "$(tail -n1 "${log}" 2>/dev/null || true)" \
  "offline hyprland: tears its wiring down"

finish_test
