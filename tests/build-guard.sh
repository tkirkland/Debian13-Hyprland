#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../tools/lib-build-guard.sh"
ws="$(mktemp -d --tmpdir=/var/tmp)"   # guarantee WORKSPACE under an allowed base
assert_fails "empty TARGET rejected"        assert_build_sandbox "${ws}" ""
assert_fails "root TARGET rejected"          assert_build_sandbox "${ws}" "/"
assert_fails "/usr TARGET rejected"          assert_build_sandbox "${ws}" "/usr"
assert_fails "TARGET outside workspace"      assert_build_sandbox "${ws}" "/var/tmp/elsewhere"
assert_fails "TARGET equal to workspace"     assert_build_sandbox "${ws}" "${ws}"
assert_fails "relative WORKSPACE rejected"   assert_build_sandbox "relpath" "${ws}/buildroot"
assert_build_sandbox "${ws}" "${ws}/buildroot" && echo "  ok: valid sandbox accepted" \
  || { echo "  FAIL: valid sandbox rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
# Allowlist: WORKSPACE must be STRICTLY UNDER a scratch base, not just != a
# system root. System SUBDIRECTORIES (the audit finding) must be rejected.
assert_fails "WORKSPACE under /usr rejected"     assert_build_sandbox "/usr/local/hypr" "/usr/local/hypr/buildroot"
assert_fails "WORKSPACE under /var/lib rejected" assert_build_sandbox "/var/lib/hypr" "/var/lib/hypr/buildroot"
assert_fails "WORKSPACE under /etc rejected"     assert_build_sandbox "/etc/hypr" "/etc/hypr/buildroot"
assert_fails "WORKSPACE == /var/tmp (not strict) rejected" assert_build_sandbox "/var/tmp" "/var/tmp/buildroot"
assert_build_sandbox "/var/tmp/hypr-iso-build" "/var/tmp/hypr-iso-build/buildroot" \
  && echo "  ok: /var/tmp workspace accepted" \
  || { echo "  FAIL: /var/tmp workspace rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
assert_build_sandbox "/tmp/hypr-build" "/tmp/hypr-build/buildroot" \
  && echo "  ok: /tmp workspace accepted" \
  || { echo "  FAIL: /tmp workspace rejected" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
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
# --- Portal (#57/#67) structural regression guards (source-level, no build).
# These protect the HARD INVARIANT behind the #64 dead-greeter revert: xdph must
# NEVER join the MUST-SUCCEED HYPR_BUILD_ORDER set, and its build step must stay a
# non-fatal, correctly-ordered optional component. Pure text inspection of the
# source; nothing here debootstraps, chroots, or builds.
config_src="${HERE}/../lib/00-config.sh"
hypr_src="${HERE}/../scripts/60-hyprland.sh"
iso_src="${HERE}/../tools/build-iso.sh"

# 1. xdph is NOT a member of HYPR_BUILD_ORDER (the array build_stack,
#    install_prebuilt_stack, online_install_prebuilt, step_depsim, and the
#    firstboot loop all treat as must-succeed). Inspect the literal array block.
build_order_block="$(awk '/^HYPR_BUILD_ORDER=\(/{f=1} f{print} f&&/^\)/{exit}' "${config_src}")"
if [[ "${build_order_block}" == *xdph* ]]; then
  echo "  FAIL: xdph must never be a member of HYPR_BUILD_ORDER (see #64 dead-greeter revert)" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
else
  echo "  ok: xdph absent from HYPR_BUILD_ORDER (must-succeed set stays xdph-free)"
fi

# 2. install_prebuilt_stack's mandatory apt-get line installs EXACTLY
#    ${HYPR_BUILD_ORDER[*]} with no xdph appended (an xdph failure must never be
#    able to abort the offline apt transaction).
ips_install="$(awk '/^install_prebuilt_stack\(\)/{f=1} f&&/apt-get install/{print; exit}' "${hypr_src}")"
ips_install="${ips_install#"${ips_install%%[![:space:]]*}"}"   # strip leading indent
assert_eq 'apt-get install -y ${HYPR_BUILD_ORDER[*]}' "${ips_install}" \
  "install_prebuilt_stack installs exactly HYPR_BUILD_ORDER (no xdph appended)"

# 3. In tools/build-iso.sh's orchestration, step_build_portal is called AFTER
#    step_build_stack (needs the source-built hypr* libs) and BEFORE
#    step_runtime_closure (which must pool the xdph deb's shlib deps).
rhb="$(awk '/^run_heavy_build\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${iso_src}")"
n_stack="$(printf '%s\n' "${rhb}" | grep -n 'step_build_stack' | head -1 | cut -d: -f1)"
n_portal="$(printf '%s\n' "${rhb}" | grep -n 'step_build_portal' | head -1 | cut -d: -f1)"
n_closure="$(printf '%s\n' "${rhb}" | grep -n 'step_runtime_closure' | head -1 | cut -d: -f1)"
if [[ -n "${n_stack}" && -n "${n_portal}" && -n "${n_closure}" \
      && "${n_stack}" -lt "${n_portal}" && "${n_portal}" -lt "${n_closure}" ]]; then
  echo "  ok: step_build_portal runs after step_build_stack, before step_runtime_closure"
else
  echo "  FAIL: step_build_portal must run after step_build_stack and before step_runtime_closure" >&2
  TEST_FAILURES=$((TEST_FAILURES+1))
fi

# 4. step_build_portal's body is subshell-guarded and non-fatal: any failure is
#    swallowed by '|| warn' and the function still 'return 0's, so the ISO build
#    continues on the packaged wlr fallback + static routing.
portal_body="$(awk '/^step_build_portal\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "${iso_src}")"
assert_contains "${portal_body}" "(" "step_build_portal opens a subshell guard"
assert_contains "${portal_body}" "|| warn" "step_build_portal degrades via || warn (non-fatal)"
assert_contains "${portal_body}" "return 0" "step_build_portal returns 0 (never aborts the build)"

rm -rf "${ws}"
finish_test
