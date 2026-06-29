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

# --- chezmoi: official .deb from the latest GitHub release ------------------
CHEZMOI_REPO_URL="https://github.com/twpayne/chezmoi"
TARGET="${tmp}/cz"
mkdir -p "${TARGET}/var/tmp"
curl_log="${tmp}/cz-curl.log"
intgt_log="${tmp}/cz-intgt.log"
: >"${curl_log}"
: >"${intgt_log}"
make_curl "${curl_log}" "v2.70.5"
in_target() { printf '%s\n' "$*" >>"${intgt_log}"; }

install_chezmoi

curl_txt="$(<"${curl_log}")"
assert_contains "${curl_txt}" \
  "api.github.com/repos/twpayne/chezmoi/releases/latest" \
  "chezmoi version resolved via the GitHub releases API"
assert_contains "${curl_txt}" \
  "/releases/download/v2.70.5/chezmoi_2.70.5_linux_amd64.deb" \
  "chezmoi .deb URL drops the leading v from the version"
assert_contains "$(<"${intgt_log}")" "apt-get install -y /var/tmp/chezmoi.deb" \
  "chezmoi .deb installed via apt inside the target"

# --- LythMono: every variant zip from the latest GitHub release ------------
# A representative 3-variant subset (incl. a NerdFont) exercises the per-variant
# URL build, the unzip target, and fc-cache without fetching all twelve.
LYTHMONO_REPO_URL="https://github.com/tkirkland/LythMono"
LYTHMONO_VARIANTS=(LythMono LythMonoNerdFont LythMonoTermSquareNerdFont)
TARGET="${tmp}/lyth"
mkdir -p "${TARGET}/var/tmp"
lcurl_log="${tmp}/lyth-curl.log"
lintgt_log="${tmp}/lyth-intgt.log"
: >"${lcurl_log}"
: >"${lintgt_log}"
make_curl "${lcurl_log}" "v0.10.1"
in_target() { printf '%s\n' "$*" >>"${lintgt_log}"; }

install_lythmono_fonts

lcurl_txt="$(<"${lcurl_log}")"
assert_contains "${lcurl_txt}" \
  "api.github.com/repos/tkirkland/LythMono/releases/latest" \
  "LythMono version resolved via the GitHub releases API"
for variant in "${LYTHMONO_VARIANTS[@]}"; do
  assert_contains "${lcurl_txt}" "/releases/download/v0.10.1/${variant}.zip" \
    "LythMono fetches the ${variant} variant zip"
done
lintgt_txt="$(<"${lintgt_log}")"
assert_contains "${lintgt_txt}" "/usr/local/share/fonts/LythMono" \
  "LythMono TTFs unzip into the system font path"
assert_contains "${lintgt_txt}" "fc-cache" \
  "font cache refreshed after install"

finish_test
