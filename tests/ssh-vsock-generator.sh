#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: systemd-ssh-generator neutering (live bake + installed target)"

# systemd-ssh-generator (systemd >=256) is shipped by systemd, fires on every
# boot/daemon-reload, and exits 1 with "Failed to query local AF_VSOCK CID" in a
# VM with no vhost-vsock device. We mask it (symlink -> /dev/null under /etc) in
# both the live squashfs bake and the installed target, WITHOUT touching the
# real sshd (openssh-server's ssh.service).

# --- Live squashfs bake (tools/iso-assemble.sh) -----------------------------
source tools/iso-assemble.sh 2>/dev/null || true

with_ssh="$(live_extras_chroot_script "git openssh-client openssh-server")"
assert_contains "${with_ssh}" \
  "ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator" \
  "live bake masks systemd-ssh-generator -> /dev/null"
assert_contains "${with_ssh}" "mkdir -p /etc/systemd/system-generators" \
  "live bake creates the /etc generator override dir first"
# The real sshd must stay enabled: masking the generator must not touch it.
assert_contains "${with_ssh}" "SYSTEMD_OFFLINE=1 systemctl enable ssh.service" \
  "live bake still enables the real sshd (ssh.service) -- generator mask is unrelated"

# The generator ships with systemd, not openssh-server, so the mask must be
# emitted even for a package set WITHOUT openssh-server (unconditional).
no_ssh="$(live_extras_chroot_script "git")"
assert_contains "${no_ssh}" \
  "ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator" \
  "live bake masks the generator even without openssh-server (unconditional)"
if [[ "${no_ssh}" == *"systemctl enable ssh.service"* ]]; then
  echo "  FAIL: enabled sshd without openssh-server in the set" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no ssh.service enable emitted when openssh-server is absent"
fi

# --- Installed target (scripts/40-system.sh) --------------------------------
source lib/00-config.sh
source lib/01-log.sh
source scripts/20-storage.sh
source scripts/40-system.sh

# phase_system must actually call the neutering, and after configure_time_sync.
ps_fn="$(declare -f phase_system)"
assert_contains "${ps_fn}" "neuter_ssh_vsock_generator" \
  "neuter_ssh_vsock_generator wired into the system phase"

# Behavioral: fake in_target to record the chroot command, then run that exact
# command into a temp prefix and prove the resulting symlink points to /dev/null
# (the actual neutering), all without a real chroot.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
recorded=""
in_target() { recorded="$1"; }
neuter_ssh_vsock_generator
assert_contains "${recorded}" "mkdir -p /etc/systemd/system-generators" \
  "target neuter creates the /etc generator override dir"
assert_contains "${recorded}" \
  "ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator" \
  "target neuter masks systemd-ssh-generator -> /dev/null"

# Execute the recorded body against a temp root prefix; readlink must be /dev/null.
( cd "${tmp}" && eval "${recorded//\/etc/etc}" )
link="${tmp}/etc/systemd/system-generators/systemd-ssh-generator"
assert_eq "/dev/null" "$(readlink "${link}" 2>/dev/null)" \
  "the created override is a symlink to /dev/null (generator neutered)"

finish_test
