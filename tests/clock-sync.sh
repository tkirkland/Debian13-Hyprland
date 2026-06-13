#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: preflight clock sync (sqv signature time windows)"

# Debian 13 apt verifies signatures with sqv, which hard-fails when the
# clock is outside the signature's validity window ("Not live until ...").
# sync_clock must not be fire-and-forget: when NTP is unavailable or has
# not converged, the clock is set from the mirror's HTTP Date header.
body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  declare -f sync_clock' 2>/dev/null || true)"

assert_contains "${body}" "timedatectl set-ntp" \
  "NTP enablement still attempted first"
assert_contains "${body}" "[Dd]ate:" \
  "falls back to the mirror HTTP Date header"
assert_contains "${body}" "300" \
  "tolerates skew up to 5 minutes before touching the clock"
assert_contains "${body}" 'date -u -s' \
  "sets the system clock from the mirror time"
assert_contains "${body}" "hwclock" \
  "persists the corrected time to the hardware clock"
assert_contains "${body}" "NETWORK_AVAILABLE" \
  "offline installs skip clock sync entirely"

# Behavioral: skew below the threshold must leave the clock alone, large
# skew must trigger the set path. Run sync_clock with curl/date/hwclock
# fakes that log invocations.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

run_sync() { # $1=remote epoch offset from now; prints the fake-date log
  local offset="$1"
  : >"${tmp}/calls"
  make_fake "${tmp}" curl \
    "echo \"Date: \$(date -u -R -d @\$(( \$(date +%s) + ${offset} )))\""
  make_fake "${tmp}" timedatectl "exit 0"
  make_fake "${tmp}" hwclock "echo hwclock >> '${tmp}/calls'"
  # Wrap date: log -s invocations, delegate everything else to real date.
  cat >"${tmp}/date" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-u" && "\$2" == "-s" ]]; then
  echo "set \$3" >> '${tmp}/calls'
  exit 0
fi
exec /usr/bin/date "\$@"
EOF
  chmod +x "${tmp}/date"
  bash -c "
    PATH='${tmp}':\${PATH}
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/00-preflight.sh
    NETWORK_AVAILABLE=1
    sync_clock >/dev/null 2>&1 || true
  "
  cat "${tmp}/calls"
}

out="$(run_sync 10)"
if [[ "${out}" == *"set"* ]]; then
  echo "  FAIL: 10s skew must not touch the clock" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: small skew leaves the clock alone"
fi

out="$(run_sync 14400)"
assert_contains "${out}" "set" "4h skew sets the clock"
assert_contains "${out}" "hwclock" "4h skew persists to the hardware clock"

finish_test
