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

# Offline means store-ONLY, not store-preferred: on a NETWORKED machine the
# permanent mirror sources, if present during the install, win the candidate
# race against the store (apt installs trixie-security's newer kernel instead
# of the store's KERNEL_TARGET, stranding the prebuilt zfs kmod — issue #110
# VM validation failure). So phase_bootstrap must write the permanent sources
# ONLY online; offline they are deferred to phase_cleanup, after the last
# package transaction.
echo "test: offline install is store-only until cleanup (no mirror mid-install)"
run_bootstrap() { # $1=NETWORK_AVAILABLE; runs phase_bootstrap with stubs
  bash -c "
    set -u
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    TARGET='${tmp}/btarget'
    NETWORK_AVAILABLE=$1
    mount_target_tree() { :; }
    run_debootstrap() { :; }
    install_policy_rc_d() { :; }
    mount_chroot_binds() { :; }
    setup_target_iso_repo() { write_iso_temp_source; }
    in_target() { :; }
    info() { :; }
    phase_bootstrap
  "
}
rm -rf "${tmp}/btarget"; mkdir -p "${tmp}/btarget/etc/apt"
run_bootstrap 0
if [[ -e "${tmp}/btarget/etc/apt/sources.list.d/debian.sources" ]]; then
  echo "  FAIL: offline bootstrap wrote the permanent mirror sources (mirror would outbid the store mid-install)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: offline bootstrap leaves the store as the ONLY apt source"
fi
if [[ -e "${tmp}/btarget/etc/apt/sources.list.d/hypr-iso-temp.sources" ]]; then
  echo "  ok: offline bootstrap wires the temporary store source"
else
  echo "  FAIL: offline bootstrap did not wire the store source" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
rm -rf "${tmp}/btarget"; mkdir -p "${tmp}/btarget/etc/apt"
run_bootstrap 1
if [[ -e "${tmp}/btarget/etc/apt/sources.list.d/debian.sources" ]]; then
  echo "  ok: online bootstrap writes the permanent mirror sources up front"
else
  echo "  FAIL: online bootstrap must write the mirror sources" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# ...and cleanup writes the permanent sources (idempotent online) so the
# installed system always ends up with the real mirror, plus drops the
# store-derived apt indexes.
assert_contains "${cleanup_body}" "write_target_apt_sources" \
  "cleanup writes the permanent mirror sources after the last transaction"
assert_contains "${cleanup_body}" "var/lib/apt/lists/" \
  "cleanup drops the store-derived apt indexes"

finish_test
