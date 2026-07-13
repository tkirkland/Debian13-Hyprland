#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: customize hygiene (identity regen + module signing, issue #111)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Shared runner: source 40-system.sh with in_target captured to a log.
run_fn() { # $1=target subdir, $2=pre-setup body, $3=function call
  local tgt="${tmp}/$1"
  mkdir -p "${tgt}"
  bash -c '
    source lib/00-config.sh; source lib/01-log.sh
    source scripts/40-system.sh
    info() { :; }
    fatal() { echo "FATAL: $*" >&2; exit 1; }
    in_target() { printf "%s\n" "$1" >>"${TARGET}/in_target.log"; }
    TARGET="'"${tgt}"'"
    '"$2"'
    '"$3"'
  '
}

# --- regen_machine_id -----------------------------------------------------------
mkdir -p "${tmp}/mid/etc" "${tmp}/mid/var/lib/dbus"
echo live-id >"${tmp}/mid/etc/machine-id"
echo live-id >"${tmp}/mid/var/lib/dbus/machine-id"
run_fn mid '' regen_machine_id
if [[ ! -e "${tmp}/mid/etc/machine-id" && ! -e "${tmp}/mid/var/lib/dbus/machine-id" ]]; then
  echo "  ok: stale machine-ids removed before regen"
else
  echo "  FAIL: regen_machine_id must remove the stale ids" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
fi
assert_contains "$(cat "${tmp}/mid/in_target.log")" "systemd-machine-id-setup" \
  "machine-id regenerated in the chroot"

# --- regen_ssh_host_keys --------------------------------------------------------
mkdir -p "${tmp}/ssh/etc/ssh"
: >"${tmp}/ssh/etc/ssh/ssh_host_ed25519_key"
: >"${tmp}/ssh/etc/ssh/ssh_host_rsa_key.pub"
run_fn ssh '' regen_ssh_host_keys
if compgen -G "${tmp}/ssh/etc/ssh/ssh_host_*" >/dev/null; then
  echo "  FAIL: regen_ssh_host_keys must remove any existing keys first" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: pre-existing host keys removed before regen"
fi
assert_contains "$(cat "${tmp}/ssh/in_target.log")" "ssh-keygen -A" \
  "host keys regenerated in the chroot"

# --- sign_dkms_modules ----------------------------------------------------------
mkdir -p "${tmp}/sign/lib/modules/6.12.90-amd64"
run_fn sign '' sign_dkms_modules
sig_log="$(cat "${tmp}/sign/in_target.log")"
assert_contains "${sig_log}" "/lib/modules/6.12.90-amd64/updates/dkms" \
  "signs the dkms-built modules of the image kernel"
assert_contains "${sig_log}" "sign-file" "signs via the kernel's sign-file"
assert_contains "${sig_log}" "sha512" "sha512 signature (dkms parity)"
assert_contains "${sig_log}" "unxz" \
  "xz-compressed modules are unpacked around signing (dkms 3.x ships .ko.xz)"
assert_contains "${sig_log}" "xz --check=crc32" \
  "repack uses CRC32 (kernel xz decoder rejects xz's default CRC64)"
assert_contains "${sig_log}" "depmod '6.12.90-amd64'" \
  "depmod refreshes the module index after signing"

# Two kernels: the newest is picked (sort -V).
mkdir -p "${tmp}/sign2/lib/modules/6.12.9-amd64" \
  "${tmp}/sign2/lib/modules/6.12.10-amd64"
run_fn sign2 '' sign_dkms_modules
assert_contains "$(cat "${tmp}/sign2/in_target.log")" \
  "/lib/modules/6.12.10-amd64/updates/dkms" \
  "version sort picks 6.12.10 over 6.12.9 (not lexicographic)"

# No kernel in the tree -> fatal (deploy did not unpack a golden tree).
if out="$(run_fn signempty '' sign_dkms_modules 2>&1)"; then
  echo "  FAIL: sign_dkms_modules must fail with no kernel in the tree" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  assert_contains "${out}" "No kernel under" "missing kernel is fatal"
fi

# --- enable_firstboot -----------------------------------------------------------
# A staged job arms the baked-dormant runner.
mkdir -p "${tmp}/fb/usr/sbin" "${tmp}/fb/usr/lib/hypr-deb/firstboot.d"
install -m755 /dev/null "${tmp}/fb/usr/sbin/hypr-deb-firstboot"
: >"${tmp}/fb/usr/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
run_fn fb '' enable_firstboot
assert_contains "$(cat "${tmp}/fb/in_target.log")" \
  "systemctl enable hypr-deb-firstboot.service" \
  "customize arms the runner when a job is staged"

# No jobs staged (the standard golden install) -> runner stays dormant.
mkdir -p "${tmp}/fb3/usr/sbin"
install -m755 /dev/null "${tmp}/fb3/usr/sbin/hypr-deb-firstboot"
run_fn fb3 '' enable_firstboot
if [[ -e "${tmp}/fb3/in_target.log" ]]; then
  echo "  FAIL: enable_firstboot must not enable the runner with no jobs" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no jobs -> runner left dormant (install complete at reboot)"
fi

# Jobs staged but runner missing from the image -> fatal (build regression).
mkdir -p "${tmp}/fb2/usr/lib/hypr-deb/firstboot.d"
: >"${tmp}/fb2/usr/lib/hypr-deb/firstboot.d/50-hyprland-build.sh"
if run_fn fb2 '' enable_firstboot >/dev/null 2>&1; then
  echo "  FAIL: enable_firstboot must fail when jobs exist but the runner is not baked" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: staged jobs without a baked runner is fatal"
fi

finish_test
