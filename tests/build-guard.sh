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
# assert_stage_under_target: the host-side stage path must stay inside TARGET.
tgt="${ws}/buildroot"
assert_fails "empty STAGE_REL rejected"        assert_stage_under_target "${tgt}" ""
assert_fails "relative STAGE_REL rejected"     assert_stage_under_target "${tgt}" "relstage"
assert_fails "STAGE_REL traversal escapes TARGET" \
  assert_stage_under_target "${tgt}" "/../../../../etc"
assert_fails "STAGE_REL equal to TARGET rejected" assert_stage_under_target "${tgt}" "/"
assert_fails "empty TARGET rejected (stage)"   assert_stage_under_target "" "/var/tmp/hypr-stage"
assert_stage_under_target "${tgt}" "/var/tmp/hypr-stage" \
  && echo "  ok: stage path inside TARGET accepted" \
  || { echo "  FAIL: valid stage path rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }

# assert_chrooted_in_target
in_target(){ /usr/bin/env bash -c "$1"; }      # no-chroot fallback
assert_fails "no-chroot in_target rejected" assert_chrooted_in_target
in_target(){ chroot "${TARGET}" /usr/bin/env bash -c "$1"; }  # chroot variant
assert_chrooted_in_target && echo "  ok: chroot in_target accepted" \
  || { echo "  FAIL: chroot in_target rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
rm -rf "${ws}"
finish_test
