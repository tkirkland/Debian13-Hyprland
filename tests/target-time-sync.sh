#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: target time synchronization (systemd-timesyncd)"

# The installed system must run an NTP client so its clock stays disciplined
# after boot (nothing else corrects drift). timesyncd is enabled via the same
# in_target "systemctl enable ..." mechanism greetd/NetworkManager use, never a
# live-systemd preset the chroot cannot apply.
source lib/00-config.sh
source lib/01-log.sh
source scripts/20-storage.sh
source scripts/40-system.sh

ts_fn="$(declare -f configure_time_sync)"
assert_contains "${ts_fn}" "systemctl enable systemd-timesyncd" \
  "timesyncd enabled with the proven in_target enable mechanism"
assert_contains "${ts_fn}" "in_target" \
  "enablement runs inside the chroot, not on a running host systemd"
assert_contains "${ts_fn}" "NTP=" \
  "drop-in uses the NTP= directive (not Servers=)"

# phase_system must actually call it.
assert_contains "$(declare -f phase_system)" "configure_time_sync" \
  "configure_time_sync wired into the system phase"

# Behavioral: the drop-in is written ONLY when NTP_SERVERS is non-empty, and
# carries exactly the [Time] / NTP=<servers> stanza. Fake in_target so the test
# never touches a real chroot; point TARGET at a temp tree.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
conf="${tmp}/etc/systemd/timesyncd.conf.d/10-installer.conf"

in_target() { :; }  # stub the chroot enable call

# Empty NTP_SERVERS: timesyncd stays on Debian's stock pool/DHCP — no drop-in.
TARGET="${tmp}" NTP_SERVERS="" configure_time_sync >/dev/null 2>&1
if [[ -e "${conf}" ]]; then
  echo "  FAIL: empty NTP_SERVERS must not write a drop-in" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: empty NTP_SERVERS leaves timesyncd on its defaults"
fi

# Non-empty NTP_SERVERS: drop-in written with the exact [Time]/NTP= stanza.
TARGET="${tmp}" NTP_SERVERS="0.pool.ntp.org time.cloudflare.com" \
  configure_time_sync >/dev/null 2>&1
assert_eq "$(cat "${conf}" 2>/dev/null)" \
  "$(printf '[Time]\nNTP=0.pool.ntp.org time.cloudflare.com')" \
  "drop-in written with [Time] and NTP=<servers> when NTP_SERVERS is set"

finish_test
