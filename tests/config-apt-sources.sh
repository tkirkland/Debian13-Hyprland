#!/usr/bin/env bash
# Defense-in-depth: the apt-source writers must HARD-REFUSE an empty root so
# they can never land sources.list.d/preferences.d on the HOST /etc.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
cd "${HERE}/.." || exit 1

source lib/00-config.sh
source lib/01-log.sh

assert_fails "sid: empty root rejected"       write_sid_toolchain_sources ""
assert_fails "sid: missing root rejected"     write_sid_toolchain_sources
assert_fails "backports: empty root rejected" write_backports_sources ""
assert_fails "backports: missing root rejected" write_backports_sources

# With a real root they still produce their files under that root only.
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
SID_MIRROR="http://deb.example.invalid/debian" \
  write_sid_toolchain_sources "${root}"
BACKPORTS_MIRROR="http://deb.example.invalid/debian" \
  write_backports_sources "${root}"

if [[ -f "${root}/etc/apt/sources.list.d/sid-toolchain.sources" ]]; then
  echo "  ok: sid source written under the given root"
else
  echo "  FAIL: sid source not written under root" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -f "${root}/etc/apt/sources.list.d/backports.sources" ]]; then
  echo "  ok: backports source written under the given root"
else
  echo "  FAIL: backports source not written under root" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
