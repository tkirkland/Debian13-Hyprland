#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: tag resolution and compatibility gate"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

# Fake git: serves a tag list including noise that must be filtered.
make_fake "${tmp}/bin" git 'cat <<EOF
sha	refs/tags/v0.9.0
sha	refs/tags/v0.10.2
sha	refs/tags/v0.10.0
sha	refs/tags/v0.10.3-rc1
sha	refs/tags/nightly
sha	refs/tags/v0.2.1
EOF'

out="$(PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/60-hyprland.sh
  resolve_latest_release_tag https://example.invalid/repo')"
assert_eq "v0.10.2" "${out}" \
  "picks semver-highest stable tag, skips rc and nightly"

# Fake git serving only non-release tags: resolution must be fatal.
mkdir -p "${tmp}/bin-nostable"
make_fake "${tmp}/bin-nostable" git 'cat <<EOF
sha	refs/tags/nightly
EOF'
resolve_nostable() {
  PATH="${tmp}/bin-nostable:${PATH}" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/60-hyprland.sh
    resolve_latest_release_tag https://example.invalid/repo'
}
assert_fails "no stable tags is fatal" resolve_nostable

# CMake minimum-version extraction.
cat >"${tmp}/CMakeLists.txt" <<'EOF'
pkg_check_modules(deps REQUIRED IMPORTED_TARGET
  hyprlang>=0.3.2
  hyprutils>=0.11.0
  aquamarine>=0.9.5)
find_package(hyprwayland-scanner 0.3.10 REQUIRED)
EOF
run_extract() {
  PATH="${tmp}/bin:${PATH}" bash -c "
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/60-hyprland.sh
    extract_min_version '${tmp}/CMakeLists.txt' '$1'"
}
assert_eq "0.3.2" "$(run_extract hyprlang)" "pkg_check_modules minimum"
assert_eq "0.3.10" "$(run_extract hyprwayland-scanner)" "find_package minimum"
assert_eq "" "$(run_extract hyprcursor)" "absent dep yields empty"

# Second fixture: spaced ">=" must match; prefix-similar names must not.
cat >"${tmp}/CMakeLists2.txt" <<'EOF'
pkg_check_modules(deps REQUIRED IMPORTED_TARGET
  hyprutils >= 0.11.0
  hyprlan>=9.9.9)
EOF
run_extract2() {
  PATH="${tmp}/bin:${PATH}" bash -c "
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/60-hyprland.sh
    extract_min_version '${tmp}/CMakeLists2.txt' '$1'"
}
assert_eq "0.11.0" "$(run_extract2 hyprutils)" "spaced >= form matches"
assert_eq "" "$(run_extract2 hyprlang)" "hyprlang does not match hyprlan>= line"

# version_ge comparisons (no dpkg dependence in tests).
vge() {
  bash -c "
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/60-hyprland.sh
    version_ge '$1' '$2' && echo yes || echo no"
}
assert_eq "yes" "$(vge 0.11.0 0.11.0)" "equal versions pass"
assert_eq "yes" "$(vge 0.12.1 0.11.9)" "higher passes"
assert_eq "no" "$(vge 0.9.9 0.11.0)" "lower fails"

# Compat gate: failing dep produces the matrix and nonzero exit.
gate() {
  bash -c "
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/60-hyprland.sh
    HYPR_RESOLVED_TAG=([hyprutils]=v0.10.0 [hyprlang]=v0.4.0)
    check_compat '${tmp}/CMakeLists.txt'"
}
out="$(gate 2>&1 || true)"
assert_contains "${out}" "hyprutils" "matrix names failing dep"
assert_contains "${out}" "0.11.0" "matrix shows required minimum"
assert_fails "compat gate aborts on mismatch" gate

finish_test
