#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: extra userland installs (chezmoi, LythMono fonts)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

info() { :; }
fatal() {
  printf 'fatal: %s\n' "$*" >&2
  return 1
}

source scripts/40-system.sh

# install_chezmoi / install_lythmono_fonts fetch from GitHub only on the online
# path and skip when offline; preflight sets NETWORK_AVAILABLE at runtime. This
# test exercises the online fetch, so establish that precondition explicitly
# (without it, the bare ((NETWORK_AVAILABLE)) guard is an unbound var under set -u).
# shellcheck disable=SC2034  # consumed by the sourced scripts/40-system.sh
NETWORK_AVAILABLE=1

# A fake curl: log every invocation; answer the GitHub "releases/latest" API
# with a tag_name, and for a download (-o FILE) create the file so the caller
# proceeds. Lets us assert the exact URLs the installer would fetch without a
# network.
make_curl() { # $1 = log file, $2 = tag to report
  local log="$1" tag="$2"
  eval "curl() {
    printf '%s\n' \"\$*\" >>'${log}'
    local out='' prev=''
    for a in \"\$@\"; do [[ \"\${prev}\" == '-o' ]] && out=\"\${a}\"; prev=\"\${a}\"; done
    if [[ \"\$*\" == *'/releases/latest'* ]]; then
      printf '  \"tag_name\": \"%s\",\n' '${tag}'
    elif [[ -n \"\${out}\" ]]; then
      : >\"\${out}\"
    fi
  }"
}

# --- chezmoi: installed OFFLINE by name from the on-ISO store ---------------
# The .deb is harvested into the pool at build time, so the installer apt-installs
# it by name from the file:// store the bootstrap phase set up — NO GitHub fetch.
# Force offline to prove the install no longer depends on the network at all.
# shellcheck disable=SC2034  # consumed by the sourced scripts/40-system.sh
NETWORK_AVAILABLE=0
CHEZMOI_REPO_URL="https://github.com/twpayne/chezmoi"
TARGET="${tmp}/cz"
mkdir -p "${TARGET}/var/tmp"
curl_log="${tmp}/cz-curl.log"
intgt_log="${tmp}/cz-intgt.log"
: >"${curl_log}"
: >"${intgt_log}"
# Any curl invocation at install time is a regression: log it so we can assert
# none reaches the network (GitHub).
# shellcheck disable=SC2317  # invoked indirectly by install_chezmoi
curl() { printf '%s\n' "$*" >>"${curl_log}"; }
in_target() { printf '%s\n' "$*" >>"${intgt_log}"; }

install_chezmoi

assert_contains "$(<"${intgt_log}")" "apt-get install -y chezmoi" \
  "chezmoi installed by name from the offline store (no .deb path, no fetch)"
curl_txt="$(<"${curl_log}")"
if [[ "${curl_txt}" != *github* ]]; then
  echo "  ok: offline chezmoi install makes NO curl-to-GitHub call"
else
  echo "  FAIL: offline chezmoi install fetched from GitHub: ${curl_txt}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
unset -f curl

# --- chezmoi build harvest: the .deb is pulled into the POOL at build time --
# cache_populate_chezmoi resolves/uses CHEZMOI_VERSION and curls the official
# .deb straight into the pool so the offline install above can resolve it.
# shellcheck disable=SC1091  # repo-relative, validated by tools/check.sh
source scripts/10-cache.sh
CACHE_DIR="${tmp}/cache"
CHEZMOI_VERSION="2.62.0"
mkdir -p "${CACHE_DIR}/repo/pool"
hcurl_log="${tmp}/cz-harvest-curl.log"
: >"${hcurl_log}"
# Fake curl: log the URL and create the -o destination so the harvest "succeeds".
curl() {
  printf '%s\n' "$*" >>"${hcurl_log}"
  local out="" prev=""
  for a in "$@"; do [[ "${prev}" == "-o" ]] && out="${a}"; prev="${a}"; done
  [[ -n "${out}" ]] && : >"${out}"
}
cache_populate_chezmoi
unset -f curl
hcurl_txt="$(<"${hcurl_log}")"
assert_contains "${hcurl_txt}" \
  "https://github.com/twpayne/chezmoi/releases/download/v2.62.0/chezmoi_2.62.0_linux_amd64.deb" \
  "build harvest pulls the pinned chezmoi .deb into the pool"
if compgen -G "${CACHE_DIR}/repo/pool/chezmoi_2.62.0_amd64.deb" >/dev/null; then
  echo "  ok: harvested chezmoi .deb lands in the pool"
else
  echo "  FAIL: chezmoi .deb not staged into the pool" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- LythMono: installed OFFLINE from the on-ISO store ----------------------
# The TTFs are harvested + extracted into the store at build time, so the
# installer copies them from ${CACHE_REPO_DIR}/lythmono — NO GitHub fetch offline.
# A representative 3-variant subset (incl. a NerdFont) seeds the store.
# shellcheck disable=SC2034  # consumed by the sourced scripts/40-system.sh
NETWORK_AVAILABLE=0
LYTHMONO_REPO_URL="https://github.com/tkirkland/LythMono"
LYTHMONO_STORE_SUBDIR="lythmono"
LYTHMONO_VARIANTS=(LythMono LythMonoNerdFont LythMonoTermSquareNerdFont)
TARGET="${tmp}/lyth"
mkdir -p "${TARGET}"
# Pre-seed the offline store with the extracted TTFs the build harvest leaves.
CACHE_REPO_DIR="${tmp}/store"
mkdir -p "${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR}"
: >"${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR}/LythMono.ttf"
: >"${CACHE_REPO_DIR}/${LYTHMONO_STORE_SUBDIR}/LythMonoNerdFont.ttf"
lcurl_log="${tmp}/lyth-curl.log"
lintgt_log="${tmp}/lyth-intgt.log"
: >"${lcurl_log}"
: >"${lintgt_log}"
# Any curl at install time is a regression: log it so we can assert there is none.
# shellcheck disable=SC2317  # invoked indirectly by install_lythmono_fonts
curl() { printf '%s\n' "$*" >>"${lcurl_log}"; }
in_target() { printf '%s\n' "$*" >>"${lintgt_log}"; }

install_lythmono_fonts
unset -f curl

if compgen -G "${TARGET}/usr/share/fonts/LythMono/*.ttf" >/dev/null; then
  echo "  ok: LythMono TTFs copied from the offline store into the font path"
else
  echo "  FAIL: LythMono TTFs not installed from the offline store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_contains "$(<"${lintgt_log}")" "fc-cache -f /usr/share/fonts/LythMono" \
  "font cache refreshed after the offline install"
lcurl_txt="$(<"${lcurl_log}")"
if [[ -z "${lcurl_txt}" ]]; then
  echo "  ok: offline LythMono install makes NO curl-to-GitHub call"
else
  echo "  FAIL: offline LythMono install fetched from the network: ${lcurl_txt}" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

# --- LythMono build harvest: zips fetched + TTFs extracted into the store ----
# harvest_lythmono_fonts uses the pinned LYTHMONO_VERSION (no latest-resolve),
# curls each variant zip and extracts its TTFs into the store dir.
LYTHMONO_VERSION="1.0.0"
fdest="${tmp}/harvest/lythmono"
hl_log="${tmp}/lyth-harvest-curl.log"
: >"${hl_log}"
# Fake curl: log the URL and create the -o zip. Fake unzip: drop a .ttf into -d.
# shellcheck disable=SC2317  # invoked indirectly by harvest_lythmono_fonts
curl() {
  printf '%s\n' "$*" >>"${hl_log}"
  local out="" prev=""
  for a in "$@"; do [[ "${prev}" == "-o" ]] && out="${a}"; prev="${a}"; done
  [[ -n "${out}" ]] && : >"${out}"
}
# shellcheck disable=SC2317  # invoked indirectly by harvest_lythmono_fonts
unzip() {
  local d="" prev=""
  for a in "$@"; do [[ "${prev}" == "-d" ]] && d="${a}"; prev="${a}"; done
  [[ -n "${d}" ]] && : >"${d}/extracted.ttf"
}
harvest_lythmono_fonts "${fdest}"
unset -f curl unzip
hl_txt="$(<"${hl_log}")"
for variant in "${LYTHMONO_VARIANTS[@]}"; do
  assert_contains "${hl_txt}" \
    "https://github.com/tkirkland/LythMono/releases/download/1.0.0/${variant}.zip" \
    "build harvest fetches the ${variant} variant zip (pinned version)"
done
if compgen -G "${fdest}/*.ttf" >/dev/null; then
  echo "  ok: harvested LythMono TTFs extracted into the store"
else
  echo "  FAIL: harvested LythMono TTFs not staged into the store" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi

finish_test
