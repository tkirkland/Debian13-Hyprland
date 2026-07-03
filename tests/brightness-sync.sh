#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: brightness-sync daemon wiring (issue #66, the script the installer ships)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Extract the brightness-sync the installer stages from its literal heredoc, so
# this tests exactly what lands at /usr/local/bin/brightness-sync (not a copy
# that could drift from the installer).
BS="${tmp}/brightness-sync"
awk "/<<'BRIGHTNESS_SYNC'\$/{f=1;next} /^BRIGHTNESS_SYNC\$/{f=0} f" \
  scripts/60-hyprland.sh >"${BS}"
chmod +x "${BS}"
[[ -s "${BS}" ]] || { echo "  FAIL: could not extract brightness-sync heredoc" >&2; exit 1; }

# Fake busctl/brightnessctl/hyprctl on PATH; log every call.
BIN="${tmp}/bin"; mkdir -p "${BIN}"
LOG="${tmp}/calls.log"; : >"${LOG}"
for cmd in busctl brightnessctl hyprctl hyprlock pidof; do
  cat >"${BIN}/${cmd}" <<EOF
#!/bin/sh
echo "${cmd} \$*" >> "${LOG}"
exit 0
EOF
  chmod +x "${BIN}/${cmd}"
done
# pidof must report "not running" so the lock path does not block on hyprlock.
cat >"${BIN}/pidof" <<EOF
#!/bin/sh
echo "pidof \$*" >> "${LOG}"
exit 1
EOF
chmod +x "${BIN}/pidof"
PATH="${BIN}:${PATH}"; export PATH

# Fake DRM: one connected external (DP-3), no internal backlight -> gamma path.
DRM="${tmp}/drm"; mkdir -p "${DRM}/card1-DP-3"; echo connected >"${DRM}/card1-DP-3/status"
BL="${tmp}/backlight"; mkdir -p "${BL}"
export BS_DRM="${DRM}" BS_BL="${BL}" BS_LEVEL="${tmp}/level" BS_DIMSAVE="${tmp}/dimsave"

# dim must snapshot via the daemon (once, before dimming externals).
rm -f "${BS_DIMSAVE}"
"${BS}" dim
assert_contains "$(cat "${LOG}")" \
  "busctl --user call dev.hyprdim / dev.hyprdim Snapshot" \
  "dim snapshots external levels via the hyprdim daemon"

# restore must re-apply via the daemon's Restore.
: >"${LOG}"; "${BS}" restore
assert_contains "$(cat "${LOG}")" \
  "busctl --user call dev.hyprdim / dev.hyprdim Restore" \
  "restore re-applies external levels via the hyprdim daemon"

# up nudges the external over D-Bus (gamma path -> busctl set-property Brightness).
: >"${LOG}"; "${BS}" up
assert_contains "$(cat "${LOG}")" \
  "set-property dev.hyprdim /outputs/DP_3 dev.hyprdim Brightness" \
  "brightness up nudges the external display's gamma via the daemon"

# An unknown verb is a usage error (exit 2), not a silent no-op.
rc=0; "${BS}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "2" "${rc}" "unknown verb exits with usage error"

finish_test
