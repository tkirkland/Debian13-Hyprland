#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: repo discovery + offline-default mode selection"

# --- CACHE_REPO_DIR default -------------------------------------------------
# Issue 3: the install repo is now decoupled from CACHE_DIR. It defaults to the
# on-ISO store (ISO_LIVE_REPO), so an offline install never depends on a second
# install-time cache. (preflight still redirects it to the present store root.)
out="$(bash -c 'source lib/00-config.sh; echo "${CACHE_REPO_DIR}"')"
assert_eq "/opt/hypr-deb/repo" "${out}" \
  "CACHE_REPO_DIR defaults to the on-ISO store (ISO_LIVE_REPO), not CACHE_DIR/repo"

# A CACHE_DIR override must NO LONGER move the install repo (decoupled).
out="$(CACHE_DIR=/srv/x bash -c 'source lib/00-config.sh; echo "${CACHE_REPO_DIR}"')"
assert_eq "/opt/hypr-deb/repo" "${out}" \
  "CACHE_REPO_DIR is independent of CACHE_DIR (no second cache)"

# The install-time embedded-cache var is gone (no TARGET_CACHE_DIR under set -u).
out="$(bash -c 'source lib/00-config.sh; echo "${TARGET_CACHE_DIR:-UNSET}"')"
assert_eq "UNSET" "${out}" "TARGET_CACHE_DIR removed (no embedded install cache)"

out="$(bash -c 'source lib/00-config.sh; echo "${ISO_MEDIUM_REPO}"')"
assert_eq "/run/live/medium/hypr-repo" "${out}" "ISO_MEDIUM_REPO default"

out="$(bash -c 'source lib/00-config.sh; echo "${ISO_LIVE_REPO}"')"
assert_eq "/opt/hypr-deb/repo" "${out}" "ISO_LIVE_REPO default (embedded store)"

# --- --online flag parses ---------------------------------------------------
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args --online
  echo "${ONLINE}|${OFFLINE}"')"
assert_eq "1|0" "${out}" "--online sets ONLINE (mirror of --offline)"

# --offline and --online are independent toggles.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  parse_args
  echo "${ONLINE}|${OFFLINE}"')"
assert_eq "0|0" "${out}" "neither online nor offline forced by default"

# --- Discovery with a faked on-ISO store ------------------------------------
# A repo dir carrying a Packages index under dists/ (no network/root/disk).
repo="$(mktemp -d)"
mkdir -p "${repo}/dists/trixie/main/binary-amd64"
: >"${repo}/dists/trixie/main/binary-amd64/Packages"
empty="$(mktemp -d)"
# Fake curl so the online-probe path never touches the network.
fakedir="$(mktemp -d)"
make_fake "${fakedir}" curl 'exit 0'
trap 'rm -rf "${repo}" "${empty}" "${fakedir}"' EXIT

# Present store, no flags -> CACHE_REPO_DIR flips to the store, offline default.
# (ISO_LIVE_REPO -> an empty dir, so this exercises the medium fallback path.)
out="$(ISO_LIVE_REPO="${empty}" ISO_MEDIUM_REPO="${repo}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  discover_iso_repo
  check_network
  echo "${ISO_STORE_PRESENT}|${CACHE_REPO_DIR}|${NETWORK_AVAILABLE}"' 2>/dev/null \
  | tail -n1)"
assert_eq "1|${repo}|0" "${out}" \
  "on-ISO store flips CACHE_REPO_DIR and makes offline the default"

# Present store, --online -> overrides to online (network probed via fake curl).
out="$(PATH="${fakedir}:${PATH}" ISO_LIVE_REPO="${empty}" ISO_MEDIUM_REPO="${repo}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  source scripts/00-preflight.sh
  parse_args --online
  discover_iso_repo
  check_network
  echo "${ISO_STORE_PRESENT}|${CACHE_REPO_DIR}|${NETWORK_AVAILABLE}"' 2>/dev/null \
  | tail -n1)"
assert_eq "1|${repo}|1" "${out}" \
  "--online overrides the store offline-default to online"

# Present store, --offline -> still forced offline, still uses the store.
out="$(ISO_LIVE_REPO="${empty}" ISO_MEDIUM_REPO="${repo}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  source scripts/00-preflight.sh
  parse_args --offline
  discover_iso_repo
  check_network
  echo "${NETWORK_AVAILABLE}|${CACHE_REPO_DIR}"' 2>/dev/null \
  | tail -n1)"
assert_eq "0|${repo}" "${out}" \
  "--offline stays offline and installs from the discovered store"

# Absent store -> no flip, online probe decides (fake curl => reachable).
out="$(PATH="${fakedir}:${PATH}" ISO_LIVE_REPO="${empty}" ISO_MEDIUM_REPO="${empty}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  discover_iso_repo
  check_network
  echo "${ISO_STORE_PRESENT}|${CACHE_REPO_DIR}|${NETWORK_AVAILABLE}"' 2>/dev/null \
  | tail -n1)"
# CACHE_REPO_DIR defaults to ISO_LIVE_REPO (here overridden to ${empty}); with no
# valid store discovered it stays at that default, and the online probe decides.
assert_eq "0|${empty}|1" "${out}" \
  "no store: CACHE_REPO_DIR unchanged (its on-ISO-store default), online by probe"

# The medium store takes precedence over an embedded in-root store when BOTH
# exist (issue #111: golden ISOs ship the install store on the medium and
# embed nothing; the in-root probe is the legacy fallback).
medrepo="$(mktemp -d)"
mkdir -p "${medrepo}/dists/trixie/main/binary-amd64"
: >"${medrepo}/dists/trixie/main/binary-amd64/Packages"
out="$(ISO_LIVE_REPO="${repo}" ISO_MEDIUM_REPO="${medrepo}" bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/00-preflight.sh
  discover_iso_repo
  echo "${ISO_STORE_PRESENT}|${CACHE_REPO_DIR}"' 2>/dev/null | tail -n1)"
assert_eq "1|${medrepo}" "${out}" \
  "medium store wins over the embedded in-root store"
rm -rf "${medrepo}"

finish_test
