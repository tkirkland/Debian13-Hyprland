#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: apt sources generation (deb822)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target/etc/apt"

gen() { # $1=NETWORK_AVAILABLE; prints the generated .sources stanzas
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    TARGET='${tmp}/target'
    NETWORK_AVAILABLE=$1
    write_target_apt_sources
    cat '${tmp}/target/etc/apt/sources.list.d/'*.sources
  "
}

out="$(gen 1)"
assert_contains "${out}" "URIs: http://deb.debian.org/debian" \
  "deb822 mirror URI online"
assert_contains "${out}" "Suites: trixie trixie-updates" \
  "base and updates suites enabled"
assert_contains "${out}" "Components: main contrib non-free-firmware" \
  "DEBIAN_COMPONENTS default enabled (contrib carries zfs-dkms)"
assert_contains "${out}" "Suites: trixie-security" "security suite online"
assert_contains "${out}" \
  "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
  "stanzas pinned to the Debian archive keyring"

# Legacy sources.list must carry no active one-line entries.
assert_fails "no legacy deb lines in sources.list" \
  grep -q '^deb ' "${tmp}/target/etc/apt/sources.list"

# The PERMANENT installed-system source is always the Debian mirror — even
# offline — so future online apt updates work. The on-ISO store is ISO-only and
# never becomes a permanent file:// source in the target.
out="$(gen 0)"
assert_contains "${out}" "URIs: http://deb.debian.org/debian" \
  "offline permanent target source is the Debian mirror"
if [[ "${out}" == *"file://"* ]]; then
  echo "  FAIL: permanent target source must not carry a file:// cache repo" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: permanent target source carries no file:// cache repo"
fi

# Offline install resolves packages through a TEMPORARY trusted file:// source
# pointing at the in-target bind path (/run/hypr-repo).
bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/30-bootstrap.sh
  TARGET='${tmp}/target'
  write_iso_temp_source
"
temp_out="$(cat "${tmp}/target/etc/apt/sources.list.d/hypr-iso-temp.sources")"
assert_contains "${temp_out}" "URIs: file:///run/hypr-repo" \
  "offline temp source points at the in-target bind path"
assert_contains "${temp_out}" "Trusted: yes" "offline temp source trusted"

# Pinned sid toolchain source: suite sid, priority 100 (only used where
# trixie has no candidate, e.g. gcc-15).
mkdir -p "${tmp}/sidroot"
bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  write_sid_toolchain_sources '${tmp}/sidroot'
"
sid_out="$(cat "${tmp}/sidroot/etc/apt/sources.list.d/sid-toolchain.sources" \
  "${tmp}/sidroot/etc/apt/preferences.d/sid-toolchain")"
assert_contains "${sid_out}" "Suites: sid" "sid suite present"
assert_contains "${sid_out}" "Pin: release a=unstable" "pin targets unstable"
assert_contains "${sid_out}" "Pin-Priority: 100" \
  "pin priority 100 (no auto-upgrades)"

# Chroot service guard: maintainer scripts must not start daemons inside
# the chroot — surviving processes hold the mounts and break teardown.
bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/30-bootstrap.sh
  TARGET='${tmp}/target'
  install_policy_rc_d
"
prcd="${tmp}/target/usr/sbin/policy-rc.d"
assert_eq "1" "$([[ -x "${prcd}" ]] && echo 1)" \
  "policy-rc.d installed and executable"
rc=0
"${prcd}" || rc=$?
assert_eq "101" "${rc}" "policy-rc.d forbids service starts (exit 101)"

# phase_cleanup delegates the tree/pool teardown to teardown_target_tree
# (shared with the standalone --phase success path), so inspect both bodies.
cleanup_body="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/99-cleanup.sh
  declare -f phase_cleanup teardown_target_tree')"
assert_contains "${cleanup_body}" "policy-rc.d" \
  "cleanup removes the chroot service guard"
assert_contains "${cleanup_body}" \
  "etc/apt/sources.list.d/sid-toolchain.sources" \
  "cleanup removes the sid toolchain source"
assert_contains "${cleanup_body}" \
  "etc/apt/preferences.d/sid-toolchain" \
  "cleanup removes the sid toolchain pin"
assert_contains "${cleanup_body}" "kill_target_processes" \
  "cleanup kills chroot-holding processes before teardown"
assert_contains "${cleanup_body}" "teardown_target_iso_repo" \
  "cleanup removes the offline temp source and repo bind"

finish_test
