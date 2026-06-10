#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: apt sources generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target/etc/apt"

gen() { # $1=NETWORK_AVAILABLE
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    TARGET='${tmp}/target'
    NETWORK_AVAILABLE=$1
    write_target_apt_sources
    cat '${tmp}/target/etc/apt/sources.list'
  "
}

out="$(gen 1)"
assert_contains "${out}" \
  "deb http://deb.debian.org/debian trixie main contrib non-free-firmware" \
  "network sources include contrib (ZFS) and firmware"
assert_contains "${out}" "trixie-security" "security suite present online"

out="$(gen 0)"
assert_contains "${out}" \
  "deb [trusted=yes] file:///var/cache/hypr-deb/repo trixie main" \
  "offline sources point at the embedded cache repo"

finish_test
