#!/usr/bin/env bash
# tests/deb-package.sh — unit tests for scripts/lib-deb-package.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../scripts/lib-deb-package.sh"

assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0)" "tag_to_debver strips v, adds -1"
assert_eq "1.2.3-1"  "$(tag_to_debver 1.2.3)"   "tag_to_debver bare version"

tmp="$(mktemp -d)"
# 0.9.0 vs 0.10.0 discriminates dpkg ordering from bash lexical '>':
# lexical wrongly prefers 0.9.0, dpkg correctly picks 0.10.0.
: >"${tmp}/swww_0.9.0-1_amd64.deb"
: >"${tmp}/swww_0.10.0-1_amd64.deb"
: >"${tmp}/hyprland_0.49.0-1_amd64.deb"
assert_eq "0.10.0-1" "$(cached_deb_version "${tmp}" swww)" "cached_deb_version picks highest"
assert_eq ""         "$(cached_deb_version "${tmp}" nope)" "cached_deb_version empty when absent"
rm -rf "${tmp}"

finish_test
