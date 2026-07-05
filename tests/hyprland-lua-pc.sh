#!/usr/bin/env bash
# Regression: build_custom_lua's host-side writes must land INSIDE the
# buildroot at ${TARGET}${HYPR_DESTDIR}/usr/..., not at the reversed
# ${HYPR_DESTDIR}${TARGET}/usr/... which (with build-iso values) is an
# unsandboxed host path under /var.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test-helpers.sh
source "${HERE}/test-helpers.sh"
cd "${HERE}/.." || exit 1

ws="$(mktemp -d)"
trap 'rm -rf "${ws}"' EXIT

export TARGET="${ws}/buildroot"
export HYPR_DESTDIR="/var/tmp/hypr-stage/lua"   # chroot-internal absolute path

# The chroot-backed install step is stubbed; it would create the staging dirs
# inside the buildroot (host-visible at ${TARGET}${HYPR_DESTDIR}). Pre-create
# them so the host-side cat has its parent, mirroring a real run.
in_target() { :; }
mkdir -p "${TARGET}${HYPR_DESTDIR}/usr/lib/pkgconfig" \
  "${TARGET}${HYPR_DESTDIR}/usr/include"

# in_target is already declared, so 60-hyprland.sh keeps our stub.
source lib/00-config.sh
source lib/01-log.sh
source scripts/60-hyprland.sh

# Set after sourcing: lib/00-config.sh declares HYPR_RESOLVED_TAG empty.
HYPR_RESOLVED_TAG[lua]="v5.5.0"

build_custom_lua

correct_pc="${TARGET}${HYPR_DESTDIR}/usr/lib/pkgconfig/lua.pc"
correct_hpp="${TARGET}${HYPR_DESTDIR}/usr/include/lua.hpp"
reversed_root="${HYPR_DESTDIR}${TARGET}"   # the buggy escape-the-buildroot path

if [[ -f "${correct_pc}" ]]; then
  echo "  ok: lua.pc written inside the buildroot"
else
  echo "  FAIL: lua.pc not at ${correct_pc}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -f "${correct_hpp}" ]]; then
  echo "  ok: lua.hpp written inside the buildroot"
else
  echo "  FAIL: lua.hpp not at ${correct_hpp}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
if [[ -e "${reversed_root}" ]]; then
  echo "  FAIL: reversed host path created: ${reversed_root}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no write to reversed ${HYPR_DESTDIR}\${TARGET} host path"
fi

assert_contains "$(cat "${correct_pc}")" "Version: 5.5.0" "lua.pc carries resolved version"

finish_test
