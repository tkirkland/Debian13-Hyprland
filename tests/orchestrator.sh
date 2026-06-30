#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: orchestrator wiring"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

out="$(bash installer.sh --help)"
assert_contains "${out}" "Usage: installer.sh" "--help prints usage"
assert_contains "${out}" "--bootloader" "--help lists bootloader flag"

assert_fails "unknown flag fails" bash installer.sh --bogus

assert_contains "$(cat installer.sh)" "Re-run installer.sh to resume" \
  "failure message names the installer"

# Modules must be sourced at top level: `declare -A` inside a helper function
# creates function-local arrays that vanish before main runs.
sed -e "s|^BASEDIR=.*|BASEDIR=\"${PWD}\"|" \
  -e '/^main "\$@"$/d' installer.sh >"${tmp}/installer-no-main.sh"
out="$(bash -c '
  source "$1"
  declare -p HYPR_REPO_URL HYPR_TAG_PATTERN HYPR_MESON_ARGS \
    HYPR_RESOLVED_TAG >/dev/null
  echo arrays-global' _ "${tmp}/installer-no-main.sh")"
assert_eq "arrays-global" "${out}" \
  "config associative arrays survive installer initialization"

# Non-root full run must fail in preflight, not crash on sourcing.
# STATE_DIR/LOG_DIR point into tmp so the dev machine stays clean.
out="$(STATE_DIR="${tmp}/state" LOG_DIR="${tmp}/logs" \
  bash installer.sh --yes --bootloader=grub 2>&1 || true)"
assert_contains "${out}" "Must run as root" "root check reached"

# Every phase function referenced by the dispatcher must exist.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  source lib/03-state.sh; source lib/04-chroot-mounts.sh
  for f in scripts/*.sh; do source "$f"; done
  for fn in phase_preflight phase_storage phase_bootstrap \
            phase_system phase_boot phase_hyprland phase_verify \
            phase_cleanup ensure_target_ready; do
    declare -f "$fn" >/dev/null || { echo "MISSING $fn"; exit 1; }
  done
  echo all-present')"
assert_eq "all-present" "${out}" "all phase functions defined"

# ensure_target_ready is a no-op when bootstrap is not stamped: it must
# return 0 and print nothing (resume helper only acts after bootstrap).
out="$(STATE_DIR="$(mktemp -d)" bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source lib/03-state.sh; source lib/04-chroot-mounts.sh
  source scripts/30-bootstrap.sh
  ensure_target_ready')"
assert_eq "" "${out}" "ensure_target_ready no-op when no pool exists"

# Non-interactive full runs must fail fast (pre-preflight) when the
# installed console would be unloginable.
assert_contains "$(cat installer.sh)" "no USER_PASSWORD and no --autologin" \
  "non-interactive password guard present"

# --yes promises unattended: it must fail fast when USER_PASSWORD is
# unset rather than block at the password prompt mid-install.
assert_contains "$(cat installer.sh)" "requires USER_PASSWORD" \
  "--yes fails fast without USER_PASSWORD"

# Success must clear resume state so an immediate re-run is a fresh
# install (behind the destroy gate), not an all-phases-skipped no-op.
# shellcheck disable=SC2016  # the needle is a literal source-code snippet
assert_contains "$(cat installer.sh)" 'rm -rf "${STATE_DIR}"' \
  "completed install clears phase state"

finish_test
