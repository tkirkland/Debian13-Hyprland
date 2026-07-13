#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: customize prune + phase wiring (issue #111)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- prune_live_artifacts -------------------------------------------------------
tgt="${tmp}/target"
mkdir -p "${tgt}/usr/lib/live/config" "${tgt}/home/user" \
  "${tgt}/etc/ssh/sshd_config.d"
: >"${tgt}/usr/lib/live/config/2999-hypr-autologin"
: >"${tgt}/home/user/autoinstall.sh"
: >"${tgt}/etc/ssh/sshd_config.d/20-hypr-live.conf"
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh
  info() { :; }
  in_target() { printf "%s\n" "$1"; }
  TARGET="'"${tgt}"'"
  prune_live_artifacts
')"
assert_contains "${out}" "apt-get purge -y live-boot live-config live-config-systemd" \
  "purges exactly the live-only package set"
assert_contains "${out}" "apt-get autoremove --purge -y" \
  "autoremoves the orphaned live deps"
if [[ ! -e "${tgt}/usr/lib/live/config/2999-hypr-autologin" ]]; then
  echo "  ok: unowned autologin hook removed explicitly"
else
  echo "  FAIL: the live autologin hook must be removed (no package owns it)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ ! -e "${tgt}/home/user" ]]; then
  echo "  ok: live user home removed defensively"
else
  echo "  FAIL: /home/user must not survive into the installed system" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ ! -e "${tgt}/etc/ssh/sshd_config.d/20-hypr-live.conf" ]]; then
  echo "  ok: live sshd password-auth drop-in removed"
else
  echo "  FAIL: the live sshd drop-in must not reach installed systems" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- phase_customize ordering ---------------------------------------------------
body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/40-system.sh; declare -f phase_customize')"
lineof() { printf '%s\n' "${body}" | grep -n "$1" | cut -d: -f1 | head -n1; }
for fn in prune_live_artifacts regen_machine_id regen_ssh_host_keys \
  sign_dkms_modules install_nvidia_driver create_user configure_session_local \
  enable_firstboot configure_zfs_boot_support; do
  assert_contains "${body}" "${fn}" "phase_customize calls ${fn}"
done
if (($(lineof prune_live_artifacts) < $(lineof configure_zfs_boot_support))); then
  echo "  ok: live prune runs before the initramfs rebuild (no live hooks baked in)"
else
  echo "  FAIL: prune must precede configure_zfs_boot_support's update-initramfs" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if (($(lineof create_user) < $(lineof configure_session_local))); then
  echo "  ok: create_user precedes configure_session_local (writes into the real home)"
else
  echo "  FAIL: configure_session_local needs the created user's home" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- orchestrator phase list ------------------------------------------------------
assert_contains "$(grep 'phases=' installer.sh)" \
  "(storage deploy customize boot verify)" \
  "full-run phase list is the golden pipeline"
assert_contains "$(cat lib/02-args.sh)" \
  'VALID_PHASES="full preflight storage deploy customize boot verify cleanup"' \
  "standalone phase names match the golden pipeline"

# Dead phase names die with a pointer to their successor (pre-1.0 CLI break).
run_phase_arg() {
  bash -c '
    source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
    parse_args "$@"' _ "$1" 2>&1
}
for dead in bootstrap system hyprland; do
  if out="$(run_phase_arg "--phase=${dead}")"; then
    echo "  FAIL: --phase=${dead} must be rejected" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    case "${dead}" in
      bootstrap) assert_contains "${out}" "deploy" \
        "--phase=bootstrap names deploy as its successor" ;;
      *) assert_contains "${out}" "customize" \
        "--phase=${dead} names customize as its successor" ;;
    esac
  fi
done

finish_test
