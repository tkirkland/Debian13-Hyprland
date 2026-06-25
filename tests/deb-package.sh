#!/usr/bin/env bash
# tests/deb-package.sh — unit tests for scripts/lib-deb-package.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../scripts/lib-deb-package.sh"

assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0)" "tag_to_debver strips v, adds -1"
assert_eq "1.2.3-1"  "$(tag_to_debver 1.2.3)"   "tag_to_debver bare version"

finish_test
