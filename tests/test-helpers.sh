# shellcheck shell=bash
# Shared assertions for Hypr-Deb tests. Source from tests/*.sh.

TEST_FAILURES=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok: ${label}"
  else
    echo "  FAIL: ${label}: expected '${expected}' got '${actual}'" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "  ok: ${label}"
  else
    echo "  FAIL: ${label}: '${needle}' not found in output" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

assert_fails() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: ${label}: expected nonzero exit" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  else
    echo "  ok: ${label}"
  fi
}

# Create a fake executable on PATH. Usage: make_fake DIR NAME 'script body'
make_fake() {
  local dir="$1" name="$2" body="$3"
  printf '#!/usr/bin/env bash\n%s\n' "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

finish_test() {
  if ((TEST_FAILURES > 0)); then
    echo "FAILED: ${TEST_FAILURES} assertion(s)" >&2
    exit 1
  fi
  echo "PASS"
}
