#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../tools/iso-assemble.sh"     # main is guarded, so sourcing is inert

echo "test: iso-assemble repo layout validation"

good="$(mktemp -d)"; mkdir -p "${good}/dists/trixie" "${good}/pool"
bad="$(mktemp -d)"
validate_repo_layout "${good}" && echo "  ok: valid repo layout accepted" \
  || { echo "  FAIL: valid layout rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
assert_fails "missing pool/dists rejected" validate_repo_layout "${bad}"
rm -rf "${good}" "${bad}"
finish_test
