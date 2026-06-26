#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../tools/lib-build-guard.sh"
ws="$(mktemp -d)"
assert_fails "empty TARGET rejected"        assert_build_sandbox "${ws}" ""
assert_fails "root TARGET rejected"          assert_build_sandbox "${ws}" "/"
assert_fails "/usr TARGET rejected"          assert_build_sandbox "${ws}" "/usr"
assert_fails "TARGET outside workspace"      assert_build_sandbox "${ws}" "/tmp/elsewhere"
assert_fails "TARGET equal to workspace"     assert_build_sandbox "${ws}" "${ws}"
assert_fails "relative WORKSPACE rejected"   assert_build_sandbox "relpath" "${ws}/buildroot"
assert_build_sandbox "${ws}" "${ws}/buildroot" && echo "  ok: valid sandbox accepted" \
  || { echo "  FAIL: valid sandbox rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
# assert_chrooted_in_target
in_target(){ /usr/bin/env bash -c "$1"; }      # no-chroot fallback
assert_fails "no-chroot in_target rejected" assert_chrooted_in_target
in_target(){ chroot "${TARGET}" /usr/bin/env bash -c "$1"; }  # chroot variant
assert_chrooted_in_target && echo "  ok: chroot in_target accepted" \
  || { echo "  FAIL: chroot in_target rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
rm -rf "${ws}"
finish_test
