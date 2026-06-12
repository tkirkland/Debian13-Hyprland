# Hypr-Deb Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the modular bash installer described in
`docs/superpowers/specs/2026-06-09-hypr-deb-installer-design.md`: Debian 13
onto the fixed three-disk ZFS/mdadm layout (VM auto-detect for testing), one
user-chosen bootloader (zbm/grub/systemd-boot), network-preferred with a
complete offline cache, and Hyprland + hyprwm deps built from latest release
tags with a compatibility gate.

**Architecture:** `hypr-deb.sh` is a thin orchestrator that sources `lib/`
(config, logging, args, phase state, chroot mounts) and `scripts/` (one
module per phase, functions only, never executed directly). Phases are
resumable via stamp files. Tests are standalone bash scripts that source
modules with fake commands on `PATH` (the reference project's pattern).

**Tech Stack:** bash (Google Shell Style Guide), shellcheck, sgdisk, mdadm,
ZFS, debootstrap, apt-ftparchive, git, cmake, efibootmgr/bootctl.

**Read the spec first.** Every task implements a spec section; the spec is
the authority on behavior.

**Conventions (apply to every task):**

- Modules in `lib/` and `scripts/` start with `# shellcheck shell=bash`, no
  shebang, functions only — they are sourced by the orchestrator. Only
  `hypr-deb.sh`, `tools/check.sh`, and `tests/*.sh` have
  `#!/usr/bin/env bash` and strict mode.
- Two-space indent, `local` for all function variables, quote everything,
  `[[ ]]` over `[ ]`, lowercase_underscore function names.
- shellcheck directives only with an inline justification comment.
- LF endings (enforced by `.gitattributes` already committed).
- After every task: `bash tools/check.sh` must pass before committing.
- Cross-module globals (e.g. `VERBOSE`, `TARGET`) are all defined in
  `lib/00-config.sh`; modules may reference them freely because the
  orchestrator sources config first. Tests must source
  `lib/00-config.sh` before the module under test.

---

### Task 0: Scaffolding — check script and test helpers

**Files:**
- Create: `tools/check.sh`
- Create: `tests/test-helpers.sh`
- Create: `.gitignore`

- [ ] **Step 1: Verify dev tooling exists**

Run: `bash --version && shellcheck --version`

If shellcheck is missing on this dev machine: Windows
`winget install koalaman.shellcheck`, Debian/Ubuntu
`apt-get install shellcheck`. Do not proceed without it — the spec makes
shellcheck a hard quality gate.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
*.log
.idea/
```

- [ ] **Step 3: Write `tools/check.sh`**

```bash
#!/usr/bin/env bash
# Development quality gate: bash -n and shellcheck over every shell file.
set -euo pipefail

cd "$(dirname "$0")/.."

declare -a files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find . -path ./.git -prune -o -name '*.sh' -print | sort)

status=0
for f in "${files[@]}"; do
  if ! bash -n "$f"; then
    echo "SYNTAX FAIL: $f" >&2
    status=1
  fi
done

if ! shellcheck --severity=style --external-sources "${files[@]}"; then
  status=1
fi

if ((status == 0)); then
  echo "OK: ${#files[@]} files pass bash -n and shellcheck"
fi
exit "$status"
```

- [ ] **Step 4: Write `tests/test-helpers.sh`**

```bash
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
```

- [ ] **Step 5: Run the gate and commit**

Run: `bash tools/check.sh`
Expected: `OK: 2 files pass bash -n and shellcheck`

```bash
git add tools/check.sh tests/test-helpers.sh .gitignore
git commit -m "Add quality-gate check script and test helpers"
```

---

### Task 1: `lib/01-log.sh` — logging

**Files:**
- Create: `lib/01-log.sh`
- Test: `tests/log.sh`

- [ ] **Step 1: Write the failing test `tests/log.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh
source lib/01-log.sh

echo "test: logging helpers"

VERBOSE=0
out="$(info "hello")"
assert_eq "[INFO] hello" "${out}" "info format"

out="$(verbose "quiet" || true)"
assert_eq "" "${out}" "verbose suppressed when VERBOSE=0"

VERBOSE=1
out="$(verbose "loud")"
assert_eq "[VERB] loud" "${out}" "verbose emits when VERBOSE=1"

out="$( (warn "careful") 2>&1 )"
assert_eq "[WARN] careful" "${out}" "warn goes to stderr"

assert_fails "fatal exits nonzero" bash -c '
  source lib/01-log.sh; fatal "boom"'

out="$( (bash -c 'source lib/01-log.sh; fatal "boom"') 2>&1 || true )"
assert_contains "${out}" "[FATAL] boom" "fatal message"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/log.sh`
Expected: FAIL (`lib/01-log.sh: No such file or directory`)

- [ ] **Step 3: Write `lib/01-log.sh`**

```bash
# shellcheck shell=bash
# Logging helpers. Sourced by installer.sh; VERBOSE comes from lib/00-config.sh.

info() { printf '[INFO] %s\n' "$*"; }

warn() { printf '[WARN] %s\n' "$*" >&2; }

verbose() {
  ((VERBOSE)) || return 0
  printf '[VERB] %s\n' "$*"
}

fatal() {
  printf '[FATAL] %s\n' "$*" >&2
  exit 1
}

# Tee all further output into a timestamped log file under $1.
setup_logging() {
  local dir="$1" ts=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dir}"
  LOG_FILE="${dir}/hypr-deb-${ts}.log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  info "Logging to ${LOG_FILE}"
}
```

Note: `VERBOSE` is assigned in `lib/00-config.sh` (Task 2). Until then the
test assigns it directly; shellcheck does not flag it because the test
assigns before use. If shellcheck flags SC2154 for `VERBOSE` inside the
module, add at the top of the function file (with this justification):

```bash
# shellcheck disable=SC2154  # VERBOSE/LOG_FILE are owned by lib/00-config.sh
```

- [ ] **Step 4: Run a test to verify it passes**

Run: `bash tests/log.sh`
Expected: `PASS`

- [ ] **Step 5: Gate and commit**

Run: `bash tools/check.sh`

```bash
git add lib/01-log.sh tests/log.sh
git commit -m "Add logging module"
```

---

### Task 2: `lib/00-config.sh` — defaults and fixed disks

**Files:**
- Create: `lib/00-config.sh`
- Test: `tests/config.sh`

- [ ] **Step 1: Write the failing test `tests/config.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: config defaults and derivation"

out="$(bash -c 'source lib/00-config.sh; echo "${ROOT_DATASET}"')"
assert_eq "PRECISION/ROOT/debian13" "${out}" "derived root dataset"

out="$(bash -c 'source lib/00-config.sh; echo "${DISK1}"')"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" "fixed DISK1"

out="$(bash -c 'source lib/00-config.sh; echo "${EFI_SIZE} ${SWAP_SIZE}"')"
assert_eq "2G 4G" "${out}" "amended partition sizes (no BOOT_SIZE)"

out="$(bash -c 'source lib/00-config.sh; echo "${BOOT_SIZE:-unset}"')"
assert_eq "unset" "${out}" "BOOT_SIZE removed from layout"

out="$(POOL_NAME=TEST ROOT_DISTRO=d13 bash -c \
  'source lib/00-config.sh; echo "${ROOT_DATASET}"')"
assert_eq "TEST/ROOT/d13" "${out}" "env overrides flow into derivation"

out="$(bash -c 'source lib/00-config.sh; echo "${HYPR_BUILD_ORDER[*]}"')"
assert_eq "hyprwayland-scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols aquamarine hyprland" \
  "${out}" "hyprwm build order"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/config.sh`
Expected: FAIL (a file missing)

- [ ] **Step 3: Write `lib/00-config.sh`**

```bash
# shellcheck shell=bash
# Hypr-Deb installer configuration: defaults, fixed disk ids, derived values.
# Every value can be overridden via environment before launch; flags in
# lib/02-args.sh override both.

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# --- Target disks (bare metal: fixed, no exceptions) ------------------------
DISK1="/dev/disk/by-id/nvme-eui.0025384331408197"
DISK2="/dev/disk/by-id/nvme-eui.002538433140818a"
DISK3="/dev/disk/by-id/nvme-eui.002538433140819d"

# Set by preflight: "none" on bare metal, hypervisor id otherwise.
VIRT_TYPE=""

# --- Partition sizes (amended layout: no separate /boot) --------------------
EFI_SIZE="${EFI_SIZE:-2G}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

# --- ZFS ---------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-PRECISION}"
ROOT_DISTRO="${ROOT_DISTRO:-debian13}"
ROOT_DATASET="${POOL_NAME}/ROOT/${ROOT_DISTRO}"

# --- Debian ------------------------------------------------------------------
SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
TARGET="${TARGET:-/target}"

# --- System identity ---------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-precision}"
TARGET_USERNAME="${TARGET_USERNAME:-me}"
USER_PASSWORD="${USER_PASSWORD:-}" # empty = interactive adduser prompt
ROOT_PASSWORD="${ROOT_PASSWORD:-}" # empty = root stays locked
TIMEZONE="${TIMEZONE:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# --- Cache (network-preferred, offline-complete) -----------------------------
CACHE_DIR="${CACHE_DIR:-/var/cache/hypr-deb}"
# Inside the installed target the embedded copy always lives here:
TARGET_CACHE_DIR="/var/cache/hypr-deb"

# --- Bootloader ---------------------------------------------------------------
# Chosen via --bootloader or interactive prompt: zbm | grub | systemd-boot
BOOTLOADER="${BOOTLOADER:-}"
ZBM_EFI_URL="${ZBM_EFI_URL:-https://get.zfsbootmenu.org/efi}"
ESP_MOUNT="/boot/efi"
KERNEL_CMDLINE_EXTRA="${KERNEL_CMDLINE_EXTRA:-quiet}"

# --- Hyprland source builds ----------------------------------------------------
HYPR_GIT_BASE="${HYPR_GIT_BASE:-https://github.com/hyprwm}"
# Build order satisfies the dependency graph; hyprland always last.
HYPR_BUILD_ORDER=(
  hyprwayland-scanner
  hyprutils
  hyprlang
  hyprcursor
  hyprgraphics
  hyprland-protocols
  aquamarine
  hyprland
)
# Repo name on github (differs in case for Hyprland itself).
declare -A HYPR_REPO_NAME=(
  [hyprwayland - scanner]="hyprwayland-scanner"
  [hyprutils]="hyprutils"
  [hyprlang]="hyprlang"
  [hyprcursor]="hyprcursor"
  [hyprgraphics]="hyprgraphics"
  [hyprland - protocols]="hyprland-protocols"
  [aquamarine]="aquamarine"
  [hyprland]="Hyprland"
)
# Filled by the hyprland phase: name -> resolved tag.
declare -A HYPR_RESOLVED_TAG=()

# Debian build dependencies for the hyprwm stack (purged after success
# unless --keep-build-deps). Runtime libs are pulled automatically as
# dependencies and are NOT in this list.
HYPR_BUILD_PACKAGES=(
  build-essential
  cmake
  meson
  ninja-build
  pkg-config
  git
  wayland-protocols
  libwayland-dev
  libxkbcommon-dev
  libinput-dev
  libdrm-dev
  libgbm-dev
  libegl-dev
  libgles2-mesa-dev
  libvulkan-dev
  glslang-tools
  libudev-dev
  libseat-dev
  libdisplay-info-dev
  libliftoff-dev
  libcairo2-dev
  libpango1.0-dev
  librsvg2-dev
  libmagic-dev
  libhwdata-dev
  libzip-dev
  libtomlplusplus-dev
  libpugixml-dev
  libre2-dev
  hwdata
  libxcb-composite0-dev
  libxcb-errors-dev
  libxcb-ewmh-dev
  libxcb-icccm4-dev
  libxcb-render-util0-dev
  libxcb-res0-dev
  libxcb-xinput-dev
  xwayland
)

# Target base packages beyond debootstrap's minimal set.
TARGET_BASE_PACKAGES=(
  linux-image-amd64
  zfs-initramfs
  zfs-dkms
  zfsutils-linux
  mdadm
  dosfstools
  efibootmgr
  network-manager
  sudo
  locales
  console-setup
  ca-certificates
  curl
  greetd
  uwsm
  kitty
  intel-microcode
  amd64-microcode
  wget
)

# Live-environment tools the preflight must be able to install offline.
LIVE_TOOL_PACKAGES=(
  debootstrap
  gdisk
  mdadm
  dosfstools
  zfsutils-linux
  zfs-dkms
  linux-headers-amd64
  apt-utils
  git
  curl
  efibootmgr
  rsync
)

# --- Behaviour ------------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"
VERBOSE="${VERBOSE:-0}"
OFFLINE="${OFFLINE:-0}"
BUILD_ON_FIRSTBOOT="${BUILD_ON_FIRSTBOOT:-0}"
KEEP_BUILD_DEPS="${KEEP_BUILD_DEPS:-0}"
NETWORK_AVAILABLE="" # set by preflight: 1 or 0
STATE_DIR="${STATE_DIR:-/run/hypr-deb/state}"
LOG_DIR="${LOG_DIR:-/tmp/hypr-deb-logs}"
LOG_FILE=""
IS_INTERACTIVE=0
[[ -t 0 && -t 1 ]]
        && IS_INTERACTIVE=1
```

- [ ] **Step 4: Run test, then gate, then commit**

Run: `bash tests/config.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add lib/00-config.sh tests/config.sh
git commit -m "Add configuration module with fixed disks and amended layout"
```

---

### Task 3: `lib/02-args.sh` — usage, parsing, prompts

**Files:**
- Create: `lib/02-args.sh`
- Test: `tests/args.sh`

- [ ] **Step 1: Write the failing test `tests/args.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: argument parsing"

run_parse() {
  bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source lib/02-args.sh
    parse_args "$@"
    echo "${BOOTLOADER}|${OFFLINE}|${BUILD_ON_FIRSTBOOT}|${ASSUME_YES}|${RUN_PHASE}|${KEEP_BUILD_DEPS}"
  ' _ "$@"
}

out="$(run_parse --bootloader=grub --offline --yes)"
assert_eq "grub|1|0|1|full|0" "${out}" "flags set expected globals"

out="$(run_parse --bootloader=zbm --build-on-firstboot --keep-build-deps \
  --phase=storage)"
assert_eq "zbm|0|1|0|storage|1" "${out}" "phase + firstboot + keep-build-deps"

assert_fails "rejects unknown bootloader" run_parse --bootloader=lilo
assert_fails "rejects unknown flag" run_parse --bogus
assert_fails "rejects unknown phase" run_parse --phase=nonsense

# Non-interactive + --yes + no bootloader must fail fast (spec).
assert_fails "bootloader required when non-interactive" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/02-args.sh
  IS_INTERACTIVE=0
  parse_args --yes
  require_bootloader_choice'

out="$(run_parse --bootloader=systemd-boot)"
assert_eq "systemd-boot|0|0|0|full|0" "${out}" "systemd-boot accepted"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/args.sh` — Expected: FAIL (a file missing)

- [ ] **Step 3: Write `lib/02-args.sh`**

```bash
# shellcheck shell=bash
# Usage text, argument parsing, and interactive prompts.

VALID_PHASES="full preflight cache storage bootstrap system boot hyprland verify cleanup"
RUN_PHASE="full"

usage() {
  cat << 'EOF'
Usage: hypr-deb.sh [options]

Installs Debian 13 (trixie) onto the fixed three-disk ZFS/mdadm layout and
builds Hyprland from latest release tags. DESTROYS the target disks.

Options:
  --bootloader=<zbm|grub|systemd-boot>
                        Bootloader to install (prompted interactively if
                        omitted; required with --yes / non-interactive runs)
  --build-on-firstboot  Defer the Hyprland build to first boot of the target
  --offline             Force offline mode (install only from the cache)
  --phase=<name>        Run a single phase:
                        preflight cache storage bootstrap system boot
                        hyprland verify cleanup
  --keep-build-deps     Do not purge build dependencies after success
  --mirror=<url>        Debian mirror (default https://deb.debian.org/debian)
  --cache-dir=<path>    Cache location (default /var/cache/hypr-deb)
  --fresh               Discard phase state and start over
  --yes                 Skip the destructive confirmation prompt
  --verbose             Detailed logging
  --help                This text
EOF
}

parse_args() {
  local arg=""
  FRESH=0
  for arg in "$@"; do
    case "${arg}" in
      --bootloader=*)
        BOOTLOADER="${arg#*=}"
        case "${BOOTLOADER}" in
          zbm | grub | systemd-boot) ;;
          *) fatal "Invalid --bootloader '${BOOTLOADER}' (zbm|grub|systemd-boot)" ;;
        esac
        ;;
      --build-on-firstboot) BUILD_ON_FIRSTBOOT=1 ;;
      --offline) OFFLINE=1 ;;
      --phase=*)
        RUN_PHASE="${arg#*=}"
        [[ " ${VALID_PHASES} " == *" ${RUN_PHASE} "* ]]
                ||
                fatal "Unknown phase '${RUN_PHASE}'. Valid: ${VALID_PHASES}"
        ;;
      --keep-build-deps) KEEP_BUILD_DEPS=1 ;;
      --mirror=*) MIRROR="${arg#*=}" ;;
      --cache-dir=*) CACHE_DIR="${arg#*=}" ;;
      --fresh) FRESH=1 ;;
      --yes) ASSUME_YES=1 ;;
      --verbose) VERBOSE=1 ;;
      --help)
        usage
        exit 0
        ;;
      *) fatal "Unknown option '${arg}' (see --help)" ;;
    esac
  done
}

# Ensure BOOTLOADER is set: prompt when interactive, fail fast otherwise.
require_bootloader_choice() {
  [[ -n "${BOOTLOADER}" ]]
          && return 0
  if ((!IS_INTERACTIVE))
          || ((ASSUME_YES)); then
    fatal "--bootloader=<zbm|grub|systemd-boot> is required in non-interactive runs"
  fi
  local choice=""
  echo "Select a bootloader:"
  echo "  1) zbm           ZFSBootMenu — boots snapshots/datasets directly"
  echo "  2) grub          GRUB (reads kernel copies from the ESP)"
  echo "  3) systemd-boot  systemd-boot (reads kernel copies from the ESP)"
  while true; do
    read -r -p "Choice [1-3]: " choice
    case "${choice}" in
      1) BOOTLOADER="zbm" ;;
      2) BOOTLOADER="grub" ;;
      3) BOOTLOADER="systemd-boot" ;;
      *) continue ;;
    esac
    break
  done
  info "Bootloader: ${BOOTLOADER}"
}

# Destructive gate. Lists the disks about to be destroyed.
confirm_destruction() {
  ((ASSUME_YES))
          && return 0
  ((IS_INTERACTIVE))
          ||
          fatal "Refusing destructive run without --yes in a non-interactive session"
  echo ""
  echo "  *** ALL DATA on these disks will be DESTROYED ***"
  echo "      DISK1=${DISK1}"
  echo "      DISK2=${DISK2}"
  echo "      DISK3=${DISK3}"
  echo "      Mode: $(
    [[ "${VIRT_TYPE}" == "none" ]] && echo "BARE METAL" ||
            echo "VM (${VIRT_TYPE})"
  )"
  echo ""
  local answer=""
  read -r -p "Type 'destroy' to continue: " answer
  [[ "${answer}" == "destroy" ]]
          || fatal "Aborted by user."
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/args.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add lib/02-args.sh tests/args.sh
git commit -m "Add argument parsing, bootloader prompt, destructive gate"
```

---

### Task 4: `lib/03-state.sh` — phase stamps and resume

**Files:**
- Create: `lib/03-state.sh`
- Test: `tests/state.sh`

- [ ] **Step 1: Write the failing test `tests/state.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: phase state stamps"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

run_state() {
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source lib/03-state.sh
    STATE_DIR='${tmp}/state'
    $1
  "
}

out="$(run_state 'state_init 0; phase_done storage && echo yes || echo no')"
assert_contains "${out}" "no" "phase not done initially"

out="$(run_state 'state_init 0; mark_phase_done storage
  phase_done storage && echo yes || echo no')"
assert_contains "${out}" "yes" "phase done after mark"

out="$(run_state 'state_init 0; mark_phase_done storage; state_init 1
  phase_done storage && echo yes || echo no')"
assert_contains "${out}" "no" "--fresh wipes stamps"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/state.sh` — Expected: FAIL

- [ ] **Step 3: Write `lib/03-state.sh`**

```bash
# shellcheck shell=bash
# Phase completion stamps under STATE_DIR enable resumable runs.
# Stamps live on tmpfs (/run) by default: resume works within a live
# session and resets naturally on reboot.

state_init() {
  local fresh="$1"
  if ((fresh)) && [[ -d "${STATE_DIR}" ]]; then
    info "--fresh: discarding phase state in ${STATE_DIR}"
    rm -rf "${STATE_DIR}"
  fi
  mkdir -p "${STATE_DIR}"
}

phase_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}

mark_phase_done() {
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/$1.done"
  info "Phase complete: $1"
}

# Run a phase function unless already stamped. Usage: run_phase NAME FUNC
run_phase() {
  local name="$1" func="$2"
  if phase_done "${name}"; then
    info "Skipping ${name} (already complete; --fresh to redo)"
    return 0
  fi
  info "=== Phase: ${name} ==="
  "${func}"
  mark_phase_done "${name}"
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/state.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add lib/03-state.sh tests/state.sh
git commit -m "Add resumable phase state stamps"
```

---

### Task 5: `lib/04-chroot-mounts.sh` — bind mounts and teardown

**Files:**
- Create: `lib/04-chroot-mounts.sh`
- Test: `tests/chroot-mounts.sh`

- [ ] **Step 1: Write the failing test `tests/chroot-mounts.sh`**

Uses fake `mount`/`umount`/`mountpoint` to verify ordering (reverse
teardown) without privileges.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: chroot mount tracking"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/target"

make_fake "${tmp}/bin" mount 'echo "mount $*" >> "${FAKE_LOG}"'
make_fake "${tmp}/bin" umount 'echo "umount $*" >> "${FAKE_LOG}"'
make_fake "${tmp}/bin" mountpoint 'exit 0'

export FAKE_LOG="${tmp}/calls.log"
out="$(PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source lib/04-chroot-mounts.sh
  TARGET='${tmp}/target'
  mount_chroot_binds
  teardown_chroot_binds
")"

calls="$(cat "${FAKE_LOG}")"
assert_contains "${calls}" "mount --bind /dev ${tmp}/target/dev" "binds /dev"
assert_contains "${calls}" "mount -t proc proc ${tmp}/target/proc" "mounts proc"

# Teardown must be reverse of setup: last umount is /dev (first mounted).
last_umount="$(grep '^umount' "${FAKE_LOG}" | tail -n1)"
assert_contains "${last_umount}" "${tmp}/target/dev" "reverse-order teardown"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/chroot-mounts.sh` — Expected: FAIL

- [ ] **Step 3: Write `lib/04-chroot-mounts.sh`**

```bash
# shellcheck shell=bash
# Chroot bind mount tracking and teardown. Mount order is recorded so
# teardown can run strictly in reverse, including on failure paths.

CHROOT_MOUNTS=()

track_mount() {
  CHROOT_MOUNTS+=("$1")
}

mount_chroot_binds() {
  local t="${TARGET}"
  mkdir -p "${t}/dev" "${t}/dev/pts" "${t}/proc" "${t}/sys" "${t}/run"

  mount --bind /dev "${t}/dev" && track_mount "${t}/dev"
  mount --bind /dev/pts "${t}/dev/pts" && track_mount "${t}/dev/pts"
  mount -t proc proc "${t}/proc" && track_mount "${t}/proc"
  mount -t sysfs sysfs "${t}/sys" && track_mount "${t}/sys"
  mount --bind /run "${t}/run" && track_mount "${t}/run"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mount --bind /sys/firmware/efi/efivars "${t}/sys/firmware/efi/efivars" &&
      track_mount "${t}/sys/firmware/efi/efivars"
  fi
}

teardown_chroot_binds() {
  local i=0
  for ((i = ${#CHROOT_MOUNTS[@]} - 1; i >= 0; i--)); do
    if mountpoint -q "${CHROOT_MOUNTS[i]}"; then
      umount "${CHROOT_MOUNTS[i]}" ||
        umount -l "${CHROOT_MOUNTS[i]}" ||
        warn "Could not unmount ${CHROOT_MOUNTS[i]}"
    fi
  done
  CHROOT_MOUNTS=()
}

in_target() {
  chroot "${TARGET}" /usr/bin/env bash -c "$*"
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/chroot-mounts.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add lib/04-chroot-mounts.sh tests/chroot-mounts.sh
git commit -m "Add chroot bind mount tracking with reverse teardown"
```

---

### Task 6: `scripts/00-preflight.sh` — virt gate, disk selection, bootstrap

**Files:**
- Create: `scripts/00-preflight.sh`
- Test: `tests/preflight-disks.sh`

- [ ] **Step 1: Write the failing test `tests/preflight-disks.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: virt-gated disk selection"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

setup_env() { # $1 = systemd-detect-virt output, $2 = lsblk disk table
  make_fake "${tmp}/bin" systemd-detect-virt "echo '$1'"
  make_fake "${tmp}/bin" lsblk "
case \"\$*\" in
  *-o\ NAME,TYPE,RM,TRAN*) cat <<'TABLE'
$2
TABLE
    ;;
  *MOUNTPOINTS*) exit 0 ;;   # nothing mounted on candidates
esac"
}

run_select() {
  PATH="${tmp}/bin:${PATH}" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_virt
    select_disks
    echo "${VIRT_TYPE}|${DISK1}|${DISK2}|${DISK3}"
  '
}

# VM with exactly three virtio disks -> auto-detected in name order.
setup_env "kvm" "vda disk 0
vdb disk 0
vdc disk 0"
out="$(run_select)"
assert_eq "kvm|/dev/vda|/dev/vdb|/dev/vdc" "${out}" "VM auto-detect, 3 disks"

# VM with two disks -> hard failure.
setup_env "kvm" "vda disk 0
vdb disk 0"
assert_fails "VM with 2 disks fails" run_select

# VM with four disks -> hard failure (never guess).
setup_env "kvm" "vda disk 0
vdb disk 0
vdc disk 0
vdd disk 0"
assert_fails "VM with 4 disks fails" run_select

# VM mode honors VM_DISK overrides.
setup_env "qemu" "vda disk 0
vdb disk 0
vdc disk 0"
out="$(VM_DISK1=/dev/vdc VM_DISK2=/dev/vdb VM_DISK3=/dev/vda \
  PATH="${tmp}/bin:${PATH}" bash -c '
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/00-preflight.sh
    detect_virt; select_disks
    echo "${DISK1}|${DISK2}|${DISK3}"')"
assert_eq "/dev/vdc|/dev/vdb|/dev/vda" "${out}" "VM_DISK overrides honored"

# Bare metal: fixed ids retained, no detection (lsblk table ignored).
setup_env "none" "sda disk 0"
out="$(PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/00-preflight.sh
  detect_virt; select_disks
  echo "${DISK1}"')"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" \
  "bare metal keeps fixed by-id paths"

# Bare metal must IGNORE VM_DISK overrides.
out="$(VM_DISK1=/dev/sdz PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/00-preflight.sh
  detect_virt; select_disks
  echo "${DISK1}"')"
assert_eq "/dev/disk/by-id/nvme-eui.0025384331408197" "${out}" \
  "VM_DISK overrides ignored on bare metal"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/preflight-disks.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/00-preflight.sh`**

```bash
# shellcheck shell=bash
# Preflight: root check, virt detection, disk selection/validation, host
# detection, tool bootstrap, network probe, clock sync.

require_root() {
  [[ "$(id -u)" == "0" ]] || fatal "Must run as root."
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  [[ -n "${VIRT_TYPE}" ]] || VIRT_TYPE="none"
  info "Virtualization: ${VIRT_TYPE}"
}

# Internal whole disk check shared by both modes (reference project logic).
is_internal_whole_disk() {
  local disk="$1" type="" rm="" tran=""
  type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | tr -d '[:space:]')"
  rm="$(lsblk -dn -o RM "${disk}" 2>/dev/null | tr -d '[:space:]')"
  tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${type}" == "disk" ]] || return 1
  [[ "${rm}" == "0" ]] || return 1
  [[ "${tran}" != "usb" ]]
}

validate_by_id_disk() {
  local disk="$1" real_path=""
  [[ "${disk}" == /dev/disk/by-id/* ]] ||
    fatal "Disk must be a /dev/disk/by-id path: ${disk}"
  [[ -b "${disk}" ]] || fatal "Not a block device: ${disk}"
  real_path="$(readlink -f "${disk}")"
  [[ "${real_path}" =~ ^/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)$ ]] ||
    fatal "'${disk}' resolves to '${real_path}' — expected nvmeXnY, sdX, or vdX."
}

# True if any partition (or the disk) has a mountpoint — excludes the live
# medium and any in-use disk from VM candidacy.
disk_has_mounts() {
  local disk="$1"
  [[ -n "$(lsblk -n -o MOUNTPOINTS "${disk}" 2>/dev/null | tr -d '[:space:]')" ]]
}

vm_detect_disks() {
  local name="" type="" rm="" candidates=()
  while read -r name type rm _; do
    [[ "${type}" == "disk" && "${rm}" == "0" ]] || continue
    [[ "${name}" =~ ^(vd[a-z]+|sd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] || continue
    disk_has_mounts "/dev/${name}" && continue
    candidates+=("/dev/${name}")
  done < <(lsblk -dn -o NAME,TYPE,RM,TRAN)

  ((${#candidates[@]} == 3)) || fatal \
    "VM mode needs exactly 3 eligible disks, found ${#candidates[@]}: ${candidates[*]:-none}"

  DISK1="${candidates[0]}"
  DISK2="${candidates[1]}"
  DISK3="${candidates[2]}"
}

select_disks() {
  if [[ "${VIRT_TYPE}" == "none" ]]; then
    info "BARE METAL mode: fixed target disks only."
    validate_by_id_disk "${DISK1}"
    validate_by_id_disk "${DISK2}"
    validate_by_id_disk "${DISK3}"
    is_internal_whole_disk "$(readlink -f "${DISK1}")" ||
      fatal "${DISK1} is not an internal whole disk"
    is_internal_whole_disk "$(readlink -f "${DISK2}")" ||
      fatal "${DISK2} is not an internal whole disk"
    is_internal_whole_disk "$(readlink -f "${DISK3}")" ||
      fatal "${DISK3} is not an internal whole disk"
  else
    info "VM TEST mode (${VIRT_TYPE}): auto-detecting target disks."
    if [[ -n "${VM_DISK1:-}" || -n "${VM_DISK2:-}" || -n "${VM_DISK3:-}" ]]; then
      [[ -n "${VM_DISK1:-}" && -n "${VM_DISK2:-}" && -n "${VM_DISK3:-}" ]] ||
        fatal "Set all of VM_DISK1/VM_DISK2/VM_DISK3 or none."
      DISK1="${VM_DISK1}"
      DISK2="${VM_DISK2}"
      DISK3="${VM_DISK3}"
    else
      vm_detect_disks
    fi
    # Warn if the smallest disk landed in an EFI-carrying role.
    local s1 s2 s3
    s1="$(blockdev --getsize64 "${DISK1}" 2>/dev/null || echo 0)"
    s2="$(blockdev --getsize64 "${DISK2}" 2>/dev/null || echo 0)"
    s3="$(blockdev --getsize64 "${DISK3}" 2>/dev/null || echo 0)"
    if ((s3 > s1 || s3 > s2)); then
      warn "DISK3 (${DISK3}) is larger than an EFI-carrying disk; check ordering."
    fi
  fi
  [[ "${DISK1}" != "${DISK2}" && "${DISK1}" != "${DISK3}" &&
    "${DISK2}" != "${DISK3}" ]] || fatal "Target disks must be distinct."
  info "Targets: DISK1=${DISK1} DISK2=${DISK2} DISK3=${DISK3}"
}

check_network() {
  if ((OFFLINE)); then
    NETWORK_AVAILABLE=0
    info "Offline mode forced (--offline)."
    return 0
  fi
  if curl -fsI --max-time 10 "${MIRROR}/dists/${SUITE}/Release" >/dev/null 2>&1; then
    NETWORK_AVAILABLE=1
    info "Network: mirror reachable (${MIRROR})"
  else
    NETWORK_AVAILABLE=0
    warn "Network: mirror unreachable — falling back to offline cache."
  fi
}

detect_live_environment() {
  if grep -qE '(^| )boot=live( |$)' /proc/cmdline 2>/dev/null ||
    mountpoint -q /run/live/medium 2>/dev/null; then
    info "Host: live environment"
    # Live overlays are RAM-backed; warn if the cache would land on tmpfs.
    local fstype=""
    fstype="$(stat -f -c %T "$(dirname "${CACHE_DIR}")" 2>/dev/null || true)"
    if [[ "${fstype}" == "tmpfs" || "${fstype}" == "overlayfs" ]]; then
      warn "CACHE_DIR=${CACHE_DIR} is RAM-backed; use --cache-dir on real storage."
    fi
  else
    info "Host: installed system"
  fi
}

bootstrap_live_tools() {
  local missing=() pkg=""
  local -A pkg_probe=(
    [debootstrap]=debootstrap [gdisk]=sgdisk [mdadm]=mdadm
    [dosfstools]=mkfs.vfat [zfsutils-linux]=zpool [apt-utils]=apt-ftparchive
    [git]=git [curl]=curl [efibootmgr]=efibootmgr [rsync]=rsync
  )
  for pkg in "${!pkg_probe[@]}"; do
    command -v "${pkg_probe[${pkg}]}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  # zfs-dkms has no binary probe of its own: presence of the module suffices.
  if ! modinfo zfs >/dev/null 2>&1; then
    missing+=(zfs-dkms linux-headers-amd64)
  fi
  ((${#missing[@]} == 0)) && {
    info "All live tools present."
    return 0
  }

  info "Missing live tools: ${missing[*]}"
  if ((NETWORK_AVAILABLE)); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  elif cache_repo_exists; then
    install_from_cache_repo "${missing[@]}"
  else
    fatal "No network and no cache; cannot install: ${missing[*]}"
  fi
  modprobe zfs || fatal "ZFS kernel module unavailable after bootstrap."
}

sync_clock() {
  ((NETWORK_AVAILABLE)) || return 0
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
  fi
}

phase_preflight() {
  require_root
  detect_virt
  detect_live_environment
  check_network
  select_disks
  bootstrap_live_tools
  sync_clock
}
```

Note: `cache_repo_exists` and `install_from_cache_repo` are defined in
`scripts/10-cache.sh` (Task 7); the orchestrator sources all modules before
any phase runs, so the reference is safe. The test only exercises
`detect_virt`/`select_disks`, which have no such dependency.

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/preflight-disks.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/00-preflight.sh tests/preflight-disks.sh
git commit -m "Add preflight: virt-gated disk selection and tool bootstrap"
```

---

### Task 7: `scripts/10-cache.sh` — offline cache populate/validate

**Files:**
- Create: `scripts/10-cache.sh`
- Test: `tests/cache-validate.sh`

- [ ] **Step 1: Write the failing test `tests/cache-validate.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: cache validation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

run_validate() {
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/10-cache.sh
    CACHE_DIR='${tmp}/cache'
    cache_validate
  "
}

# Empty cache -> fails listing what's missing.
out="$(run_validate 2>&1 || true)"
assert_contains "${out}" "repo index" "missing repo reported"
assert_contains "${out}" "sources manifest" "missing manifest reported"
assert_fails "empty cache fails validation" run_validate

# Minimal complete cache -> passes.
mkdir -p "${tmp}/cache/repo/dists/trixie/main/binary-amd64" \
  "${tmp}/cache/repo/pool" "${tmp}/cache/sources"
touch "${tmp}/cache/repo/dists/trixie/Release"
printf 'Filename: pool/fake_1.0_amd64.deb\n' \
  >"${tmp}/cache/repo/dists/trixie/main/binary-amd64/Packages"
touch "${tmp}/cache/repo/pool/fake_1.0_amd64.deb"
printf 'hyprland v0.50.1\n' >"${tmp}/cache/sources/MANIFEST"
touch "${tmp}/cache/sources/hyprland-v0.50.1.tar.gz"
touch "${tmp}/cache/zfsbootmenu.EFI"
out="$(run_validate)"
assert_contains "${out}" "Cache valid" "complete cache passes"

# Manifest references a missing tarball -> fails.
printf 'hyprutils v0.8.2\n' >>"${tmp}/cache/sources/MANIFEST"
assert_fails "missing source tarball fails validation" run_validate

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/cache-validate.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/10-cache.sh`**

```bash
# shellcheck shell=bash
# Offline cache: a local apt repo (pool/ + apt-ftparchive indexes), source
# tag archives for the hyprwm stack, and the ZFSBootMenu EFI binary.
# Layout:
#   ${CACHE_DIR}/repo/pool/*.deb
#   ${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages[.gz]
#   ${CACHE_DIR}/repo/dists/${SUITE}/Release
#   ${CACHE_DIR}/sources/<name>-<tag>.tar.gz + MANIFEST ("name tag" lines)
#   ${CACHE_DIR}/zfsbootmenu.EFI

cache_repo_exists() {
  [[ -f "${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages" ]]
}

# Configure apt (live env) to install from the cache repo only.
install_from_cache_repo() {
  local list="/etc/apt/sources.list.d/hypr-deb-cache.list"
  echo "deb [trusted=yes] file://${CACHE_DIR}/repo ${SUITE} main" >"${list}"
  apt-get update -o Dir::Etc::sourcelist="${list}" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Resolve the full .deb closure for all package sets using a throwaway
# bootstrap, then index the pool with apt-ftparchive. Network required.
cache_populate_debs() {
  local work="${CACHE_DIR}/.work" pool="${CACHE_DIR}/repo/pool"
  mkdir -p "${pool}" "${work}"

  info "Downloading debootstrap base packages..."
  debootstrap --download-only --arch="${ARCH}" "${SUITE}" \
    "${work}/bootstrap" "${MIRROR}"
  cp -n "${work}/bootstrap/var/cache/apt/archives/"*.deb "${pool}/" 2>/dev/null || true

  info "Resolving full package closure in a scratch chroot..."
  debootstrap --arch="${ARCH}" "${SUITE}" "${work}/closure" "${MIRROR}"
  chroot "${work}/closure" /usr/bin/env bash -c "
    set -e
    echo 'deb ${MIRROR} ${SUITE} main contrib non-free-firmware' \
      > /etc/apt/sources.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only \
      ${TARGET_BASE_PACKAGES[*]} ${HYPR_BUILD_PACKAGES[*]} \
      ${LIVE_TOOL_PACKAGES[*]} grub-efi-amd64 systemd-boot
  "
  cp -n "${work}/closure/var/cache/apt/archives/"*.deb "${pool}/"
  rm -rf "${work}"
  info "Pool populated: $(find "${pool}" -name '*.deb' | wc -l) packages"
}

cache_index_repo() {
  local repo="${CACHE_DIR}/repo"
  local bindir="dists/${SUITE}/main/binary-${ARCH}"
  mkdir -p "${repo}/${bindir}"
  (
    cd "${repo}"
    apt-ftparchive packages pool >"${bindir}/Packages"
    gzip -kf "${bindir}/Packages"
    apt-ftparchive \
      -o "APT::FTPArchive::Release::Suite=${SUITE}" \
      -o "APT::FTPArchive::Release::Components=main" \
      -o "APT::FTPArchive::Release::Architectures=${ARCH}" \
      release "dists/${SUITE}" >"dists/${SUITE}/Release"
  )
}

cache_populate_sources() {
  local name="" repo="" tag="" manifest="${CACHE_DIR}/sources/MANIFEST"
  mkdir -p "${CACHE_DIR}/sources"
  : >"${manifest}"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    repo="${HYPR_REPO_NAME[${name}]}"
    tag="$(resolve_latest_release_tag "${HYPR_GIT_BASE}/${repo}")"
    info "Caching ${name} ${tag}"
    curl -fsSL -o "${CACHE_DIR}/sources/${name}-${tag}.tar.gz" \
      "${HYPR_GIT_BASE}/${repo}/archive/refs/tags/${tag}.tar.gz"
    echo "${name} ${tag}" >>"${manifest}"
  done
}

cache_populate_zbm() {
  info "Caching ZFSBootMenu EFI binary..."
  curl -fsSL -o "${CACHE_DIR}/zfsbootmenu.EFI" "${ZBM_EFI_URL}"
}

cache_validate() {
  local problems=() pkg_index="" fname="" name="" tag=""
  pkg_index="${CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages"

  [[ -f "${pkg_index}" ]] || problems+=("repo index missing: ${pkg_index}")
  [[ -f "${CACHE_DIR}/repo/dists/${SUITE}/Release" ]] ||
    problems+=("repo Release file missing")
  if [[ -f "${pkg_index}" ]]; then
    while IFS= read -r fname; do
      [[ -f "${CACHE_DIR}/repo/${fname}" ]] ||
        problems+=("deb missing from pool: ${fname}")
    done < <(awk '/^Filename: /{print $2}' "${pkg_index}")
  fi

  if [[ -f "${CACHE_DIR}/sources/MANIFEST" ]]; then
    while read -r name tag; do
      [[ -f "${CACHE_DIR}/sources/${name}-${tag}.tar.gz" ]] ||
        problems+=("source tarball missing: ${name}-${tag}.tar.gz")
    done <"${CACHE_DIR}/sources/MANIFEST"
  else
    problems+=("sources manifest missing: ${CACHE_DIR}/sources/MANIFEST")
  fi

  [[ -f "${CACHE_DIR}/zfsbootmenu.EFI" ]] ||
    problems+=("zfsbootmenu.EFI missing")

  if ((${#problems[@]} > 0)); then
    local p=""
    for p in "${problems[@]}"; do warn "cache: ${p}"; done
    fatal "Cache validation failed (${#problems[@]} problem(s))."
  fi
  info "Cache valid: ${CACHE_DIR}"
}

phase_cache() {
  if ((NETWORK_AVAILABLE)); then
    cache_populate_debs
    cache_index_repo
    cache_populate_sources
    cache_populate_zbm
  else
    info "No network: validating existing cache instead of populating."
  fi
  cache_validate
}
```

Note: `resolve_latest_release_tag` is defined in `scripts/60-hyprland.sh`
(Task 11); all modules are sourced before any phase executes.

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/cache-validate.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/10-cache.sh tests/cache-validate.sh
git commit -m "Add offline cache populate/validate with local apt repo"
```

---

### Task 8: `scripts/20-storage.sh` — wipe, partition, mdadm, ZFS

**Files:**
- Create: `scripts/20-storage.sh`
- Test: `tests/storage-plan.sh`

This ports the reference project's storage module to the amended layout:
DISK1/2 = part1 EFI(2G) / part2 swap(4G) / part3 ZFS; DISK3 = part1 swap /
part2 ZFS. No `md/boot`.

- [ ] **Step 1: Write the failing test `tests/storage-plan.sh`**

Verifies the sgdisk/mdadm/zpool command construction with fakes — the
partition numbers are where regressions would be catastrophic.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: storage command plan"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
export FAKE_LOG="${tmp}/calls.log"

for cmd in sgdisk mdadm zpool zfs wipefs blkdiscard partprobe udevadm \
  mkfs.vfat mkfs.ext4 mkswap swapoff umount; do
  make_fake "${tmp}/bin" "${cmd}" \
    "echo \"${cmd} \$*\" >> \"\${FAKE_LOG}\"; exit 0"
done
# zpool list must fail (no pool) so destroy path is a no-op.
make_fake "${tmp}/bin" zpool '
echo "zpool $*" >> "${FAKE_LOG}"
[[ "$1" == "list" || "$1" == "import" ]] && exit 1
exit 0'

PATH="${tmp}/bin:${PATH}" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/20-storage.sh
  DISK1=/dev/vda; DISK2=/dev/vdb; DISK3=/dev/vdc
  destroy_existing_layout
  wipe_target_disks
  partition_target_disks
  create_arrays
  format_arrays
  create_pool_and_datasets
' >/dev/null

calls="$(cat "${FAKE_LOG}")"
assert_contains "${calls}" \
  "sgdisk -n1:1M:+2G -t1:EF00 -c1:EFI1 -n2:0:+4G -t2:FD00 -c2:SWAP1 -n3:0:0 -t3:BF00 -c3:ZFS1 /dev/vda" \
  "DISK1 three-partition plan"
assert_contains "${calls}" \
  "sgdisk -n1:1M:+4G -t1:FD00 -c1:SWAP3 -n2:0:0 -t2:BF00 -c2:ZFS3 /dev/vdc" \
  "DISK3 two-partition plan"
assert_contains "${calls}" \
  "mdadm --create /dev/md/efi --level=1 --raid-devices=2 --metadata=1.0" \
  "EFI RAID1 metadata 1.0"
assert_contains "${calls}" \
  "/dev/vda-part2 /dev/vdb-part2 /dev/vdc-part1" "swap RAID0 members"
assert_contains "${calls}" \
  "raidz1 /dev/vda-part3 /dev/vdb-part3 /dev/vdc-part2" "raidz1 members"
if grep -q "md/boot" "${FAKE_LOG}"; then
  echo "  FAIL: md/boot must not exist in amended layout" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no md/boot in amended layout"
fi

finish_test
```

Note: partition suffixes — `by-id` paths use `-partN`; bare `/dev/vdX`
uses `N` directly. The module uses a `part_dev` helper so both work; the
fake-based test passes `/dev/vdX` and expects the helper's by-id form is
covered by the helper unit assertions below (the test adds them).

Append to the same test file before `finish_test`:

```bash
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh
  source scripts/20-storage.sh
  part_dev /dev/disk/by-id/nvme-eui.abc 3; echo
  part_dev /dev/vda 3; echo
  part_dev /dev/nvme0n1 3')"
assert_eq "/dev/disk/by-id/nvme-eui.abc-part3
/dev/vda3
/dev/nvme0n1p3" "${out}" "part_dev naming for by-id, vdX, nvme"
```

(Adjust the storage-plan assertions above to use `part_dev` outputs —
with `/dev/vdX` inputs the expected members are `/dev/vda2 /dev/vdb2
/dev/vdc1` and `raidz1 /dev/vda3 /dev/vdb3 /dev/vdc2`. Use those exact
strings in the assertions.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/storage-plan.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/20-storage.sh`**

```bash
# shellcheck shell=bash
# Storage: destroy stale layout, wipe, partition, mdadm arrays, ZFS pool.
# Amended layout (no md/boot; kernels live on the ZFS root dataset):
#   DISK1/DISK2: part1 EFI(${EFI_SIZE}) part2 SWAP(${SWAP_SIZE}) part3 ZFS
#   DISK3:       part1 SWAP(${SWAP_SIZE}) part2 ZFS
#   /dev/md/efi:  FAT32 RAID1 (metadata 1.0) DISK1p1+DISK2p1
#   /dev/md/swap: RAID0 DISK1p2+DISK2p2+DISK3p1
#   ZFS raidz1:   DISK1p3+DISK2p3+DISK3p2

# Partition device name for disk $1, partition number $2.
part_dev() {
  local disk="$1" num="$2"
  if [[ "${disk}" == /dev/disk/by-id/* ]]; then
    printf '%s-part%s' "${disk}" "${num}"
  elif [[ "${disk}" =~ [0-9]$ ]]; then
    printf '%sp%s' "${disk}" "${num}"
  else
    printf '%s%s' "${disk}" "${num}"
  fi
}

wait_for_block_devices() {
  local device="" remaining=50 missing=0
  udevadm settle
  while ((remaining > 0)); do
    missing=0
    for device in "$@"; do
      [[ -b "${device}" ]] || {
        missing=1
        break
      }
    done
    ((missing == 0)) && return 0
    sleep 0.2
    remaining=$((remaining - 1))
  done
  fatal "Timed out waiting for block devices: $*"
}

destroy_existing_layout() {
  info "Destroying any existing pool ${POOL_NAME} and arrays..."
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zfs unmount -af 2>/dev/null || true
    umount -R "${TARGET}" 2>/dev/null || true
    zpool export -f "${POOL_NAME}" 2>/dev/null ||
      zpool destroy -f "${POOL_NAME}" 2>/dev/null ||
      fatal "Cannot export or destroy pool ${POOL_NAME}."
  elif zpool import -N -f -d /dev/disk/by-id "${POOL_NAME}" 2>/dev/null; then
    info "Stale pool ${POOL_NAME} imported; destroying..."
    zpool destroy -f "${POOL_NAME}" 2>/dev/null || true
  fi

  swapoff /dev/md/swap 2>/dev/null || true
  local arr=""
  for arr in /dev/md/efi /dev/md/swap; do
    mdadm --stop "${arr}" 2>/dev/null || true
    mdadm --remove "${arr}" 2>/dev/null || true
  done
  local md_device=""
  for md_device in /dev/md[0-9]*; do
    [[ -b "${md_device}" ]] || continue
    mdadm --stop "${md_device}" 2>/dev/null || true
  done

  local member=""
  for member in \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK1}" 2)" \
    "$(part_dev "${DISK2}" 1)" "$(part_dev "${DISK2}" 2)" \
    "$(part_dev "${DISK3}" 1)"; do
    mdadm --zero-superblock "${member}" 2>/dev/null || true
  done
}

wipe_target_disks() {
  local disk=""
  for disk in "${DISK1}" "${DISK2}" "${DISK3}"; do
    info "Wiping ${disk}..."
    wipefs -af "${disk}" 2>/dev/null || true
    sgdisk --zap-all "${disk}"
    blkdiscard -f "${disk}" 2>/dev/null || true
  done
}

partition_target_disks() {
  local disk="" n=1
  for disk in "${DISK1}" "${DISK2}"; do
    info "Partitioning ${disk}: EFI${n}(${EFI_SIZE}) SWAP${n}(${SWAP_SIZE}) ZFS${n}(rest)..."
    sgdisk \
      -n1:1M:+"${EFI_SIZE}" -t1:EF00 -c1:"EFI${n}" \
      -n2:0:+"${SWAP_SIZE}" -t2:FD00 -c2:"SWAP${n}" \
      -n3:0:0 -t3:BF00 -c3:"ZFS${n}" \
      "${disk}"
    n=$((n + 1))
  done

  info "Partitioning ${DISK3}: SWAP3(${SWAP_SIZE}) ZFS3(rest)..."
  sgdisk \
    -n1:1M:+"${SWAP_SIZE}" -t1:FD00 -c1:SWAP3 \
    -n2:0:0 -t2:BF00 -c2:ZFS3 \
    "${DISK3}"

  partprobe "${DISK1}" "${DISK2}" "${DISK3}"
  wait_for_block_devices \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK1}" 2)" "$(part_dev "${DISK1}" 3)" \
    "$(part_dev "${DISK2}" 1)" "$(part_dev "${DISK2}" 2)" "$(part_dev "${DISK2}" 3)" \
    "$(part_dev "${DISK3}" 1)" "$(part_dev "${DISK3}" 2)"
}

create_arrays() {
  info "Creating RAID1 /dev/md/efi..."
  mdadm --create /dev/md/efi \
    --level=1 --raid-devices=2 --metadata=1.0 \
    --bitmap=internal --homehost=any --name=efi --run \
    "$(part_dev "${DISK1}" 1)" "$(part_dev "${DISK2}" 1)"

  info "Creating RAID0 /dev/md/swap..."
  mdadm --create /dev/md/swap \
    --level=0 --raid-devices=3 --metadata=1.2 \
    --chunk=512 --homehost=any --name=swap --run \
    "$(part_dev "${DISK1}" 2)" "$(part_dev "${DISK2}" 2)" \
    "$(part_dev "${DISK3}" 1)"

  wait_for_block_devices /dev/md/efi /dev/md/swap
}

format_arrays() {
  info "Formatting /dev/md/efi (FAT32, label=EFI)..."
  mkfs.vfat -F 32 -n EFI /dev/md/efi
  info "Formatting /dev/md/swap..."
  mkswap -L swap /dev/md/swap
}

create_pool_and_datasets() {
  info "Creating ZFS pool ${POOL_NAME} (raidz1)..."
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posix \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=zstd \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -R "${TARGET}" \
    "${POOL_NAME}" \
    raidz1 \
    "$(part_dev "${DISK1}" 3)" "$(part_dev "${DISK2}" 3)" \
    "$(part_dev "${DISK3}" 2)"

  info "Creating dataset hierarchy..."
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"
  zfs create -o canmount=noauto -o mountpoint=/ "${ROOT_DATASET}"
  zfs create -u -o mountpoint=/home "${POOL_NAME}/home"
  zfs create -u -o mountpoint="/home/${TARGET_USERNAME}/Downloads" \
    -o compression=off "${POOL_NAME}/home/Downloads"
  zfs create -u -o mountpoint=/srv "${POOL_NAME}/srv"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var"
  zfs create -u -o mountpoint=/var/cache \
    -o com.sun:auto-snapshot=false "${POOL_NAME}/var/cache"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var/lib"
  zfs create -o mountpoint=none "${POOL_NAME}/var/lib/docker"
  zfs create -u -o mountpoint=/var/log "${POOL_NAME}/var/log"
  zfs create -u -o mountpoint=/var/tmp \
    -o com.sun:auto-snapshot=false "${POOL_NAME}/var/tmp"

  zpool set bootfs="${ROOT_DATASET}" "${POOL_NAME}"
}

phase_storage() {
  confirm_destruction
  destroy_existing_layout
  wipe_target_disks
  partition_target_disks
  create_arrays
  format_arrays
  create_pool_and_datasets
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/storage-plan.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/20-storage.sh tests/storage-plan.sh
git commit -m "Add storage phase: amended 3-partition layout, mdadm, raidz1"
```

---

### Task 9: `scripts/30-bootstrap.sh` — mount target, debootstrap, sources

**Files:**
- Create: `scripts/30-bootstrap.sh`
- Test: `tests/bootstrap-sources.sh`

- [ ] **Step 1: Write the failing test `tests/bootstrap-sources.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: apt sources generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target/etc/apt"

gen() { # $1=NETWORK_AVAILABLE
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/30-bootstrap.sh
    TARGET='${tmp}/target'
    NETWORK_AVAILABLE=$1
    write_target_apt_sources
    cat '${tmp}/target/etc/apt/sources.list'
  "
}

out="$(gen 1)"
assert_contains "${out}" \
        "deb https://deb.debian.org/debian trixie main contrib non-free-firmware" \
        "network sources include contrib (ZFS) and firmware"
assert_contains "${out}" "trixie-security" "security suite present online"

out="$(gen 0)"
assert_contains "${out}" \
        "deb [trusted=yes] file:///var/cache/hypr-deb/repo trixie main" \
        "offline sources point at the embedded cache repo"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bootstrap-sources.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/30-bootstrap.sh`**

```bash
# shellcheck shell=bash
# Bootstrap: mount the target tree, debootstrap Debian (network or cache),
# embed the cache, write apt sources, establish chroot binds.

mount_target_tree() {
  info "Mounting target tree at ${TARGET}..."
  mkdir -p "${TARGET}"
  zfs mount "${ROOT_DATASET}"
  zfs mount -a
  mkdir -p "${TARGET}${ESP_MOUNT}"
  mount /dev/md/efi "${TARGET}${ESP_MOUNT}"
}

run_debootstrap() {
  if [[ -f "${TARGET}/etc/debian_version" ]]; then
    info "Target already bootstrapped; skipping debootstrap."
    return 0
  fi
  if ((NETWORK_AVAILABLE)); then
    info "debootstrap ${SUITE} from ${MIRROR}..."
    debootstrap --arch="${ARCH}" "${SUITE}" "${TARGET}" "${MIRROR}"
  else
    cache_validate
    info "debootstrap ${SUITE} from offline cache..."
    debootstrap --no-check-gpg --arch="${ARCH}" "${SUITE}" "${TARGET}" \
            "file://${CACHE_DIR}/repo"
  fi
}

# The complete cache is always embedded so the installed system can rebuild
# or reinstall fully offline (spec: Cache section).
embed_cache_in_target() {
  [[ -d "${CACHE_DIR}/repo" ]]
          || {
    warn "No cache at ${CACHE_DIR}; target will not carry an offline cache."
    return 0
  }
  info "Embedding cache into ${TARGET}${TARGET_CACHE_DIR}..."
  mkdir -p "${TARGET}${TARGET_CACHE_DIR}"
  rsync -a "${CACHE_DIR}/" "${TARGET}${TARGET_CACHE_DIR}/"
  cat > "${TARGET}${TARGET_CACHE_DIR}/README" << EOF
Hypr-Deb offline cache.
repo/     local apt repository (deb [trusted=yes] file://${TARGET_CACHE_DIR}/repo ${SUITE} main)
sources/  hyprwm source tag archives + MANIFEST of resolved release tags
zfsbootmenu.EFI  cached ZFSBootMenu release binary
EOF
}

write_target_apt_sources() {
  if ((NETWORK_AVAILABLE)); then
    cat > "${TARGET}/etc/apt/sources.list" << EOF
deb ${MIRROR} ${SUITE} main contrib non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF
  else
    cat > "${TARGET}/etc/apt/sources.list" << EOF
deb [trusted=yes] file://${TARGET_CACHE_DIR}/repo ${SUITE} main
EOF
  fi
}

phase_bootstrap() {
  mount_target_tree
  run_debootstrap
  embed_cache_in_target
  write_target_apt_sources
  mount_chroot_binds
  in_target "apt-get update"
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/bootstrap-sources.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/30-bootstrap.sh tests/bootstrap-sources.sh
git commit -m "Add bootstrap phase: target mounts, debootstrap, cache embed"
```

---

### Task 10: `scripts/40-system.sh` — base system configuration

**Files:**
- Create: `scripts/40-system.sh`
- Test: `tests/system-fstab.sh`

- [ ] **Step 1: Write the failing test `tests/system-fstab.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: fstab generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/target/etc"

make_fake "${tmp}/bin" blkid '
case "$*" in
  *md/efi*) echo "AAAA-1111" ;;
  *md/swap*) echo "bbbbbbbb-2222" ;;
esac'

out="$(PATH="${tmp}/bin:${PATH}" bash -c "
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/40-system.sh
  TARGET='${tmp}/target'
  write_fstab
  cat '${tmp}/target/etc/fstab'
")"
assert_contains "${out}" "UUID=AAAA-1111 /boot/efi vfat" "ESP by UUID"
assert_contains "${out}" "UUID=bbbbbbbb-2222 none swap sw 0 0" "swap by UUID"
if [[ "${out}" == *" / "* ]]; then
  echo "  FAIL: root must NOT be in fstab (ZFS mounts it)" >&2
  TEST_FAILURES=$((TEST_FAILURES + 1))
else
  echo "  ok: no root line (ZFS-managed)"
fi

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/system-fstab.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/40-system.sh`**

```bash
# shellcheck shell=bash
# Base system: identity, locale/tz, fstab, mdadm.conf, base packages,
# user account, ZFS boot prerequisites (hostid, cachefile, initramfs).

write_identity() {
  echo "${TARGET_HOSTNAME}" >"${TARGET}/etc/hostname"
  cat >"${TARGET}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}
::1       localhost ip6-localhost ip6-loopback
EOF
}

write_fstab() {
  local efi_uuid="" swap_uuid=""
  efi_uuid="$(blkid -s UUID -o value /dev/md/efi)"
  swap_uuid="$(blkid -s UUID -o value /dev/md/swap)"
  cat >"${TARGET}/etc/fstab" <<EOF
# ZFS datasets mount via the zfs mount generator; root comes from initramfs.
UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1
UUID=${swap_uuid} none swap sw 0 0
EOF
}

write_mdadm_conf() {
  mkdir -p "${TARGET}/etc/mdadm"
  {
    echo "HOMEHOST <ignore>"
    mdadm --detail --scan
  } >"${TARGET}/etc/mdadm/mdadm.conf"
}

configure_locale_tz() {
  in_target "
    set -e
    echo '${TIMEZONE}' > /etc/timezone
    ln -sf '/usr/share/zoneinfo/${TIMEZONE}' /etc/localtime
    sed -i 's/^# *${LOCALE}/${LOCALE}/' /etc/locale.gen
    locale-gen
    update-locale LANG='${LOCALE}'
  "
}

install_base_packages() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${TARGET_BASE_PACKAGES[*]}
  "
}

create_user() {
  in_target "
    set -e
    id '${TARGET_USERNAME}' >/dev/null 2>&1 ||
      adduser --disabled-password --gecos '' '${TARGET_USERNAME}'
    usermod -aG sudo '${TARGET_USERNAME}'
  "
  if [[ -n "${USER_PASSWORD}" ]]; then
    echo "${TARGET_USERNAME}:${USER_PASSWORD}" | chroot "${TARGET}" chpasswd
  elif ((IS_INTERACTIVE)); then
    info "Set a password for ${TARGET_USERNAME}:"
    chroot "${TARGET}" passwd "${TARGET_USERNAME}"
  else
    warn "No USER_PASSWORD and non-interactive: ${TARGET_USERNAME} has no password."
  fi
  if [[ -n "${ROOT_PASSWORD}" ]]; then
    echo "root:${ROOT_PASSWORD}" | chroot "${TARGET}" chpasswd
  fi
}

configure_zfs_boot_support() {
  in_target "
    set -e
    zgenhostid -f
    systemctl enable NetworkManager
  "
  # Give the target the pool cachefile so it imports cleanly at boot.
  zpool set cachefile="${TARGET}/etc/zfs/zpool.cache" "${POOL_NAME}"
  in_target "update-initramfs -u -k all"
}

phase_system() {
  write_identity
  write_fstab
  write_mdadm_conf
  configure_locale_tz
  install_base_packages
  create_user
  configure_zfs_boot_support
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/system-fstab.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/40-system.sh tests/system-fstab.sh
git commit -m "Add system phase: identity, fstab, mdadm, base packages, user"
```

---

### Task 11: `scripts/60-hyprland.sh` — tags, compat gate, builds, greetd/uwsm

**Files:**
- Create: `scripts/60-hyprland.sh`
- Test: `tests/hyprland-tags.sh`

- [ ] **Step 1: Write the failing test `tests/hyprland-tags.sh`**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hyprland-tags.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/60-hyprland.sh`**

```bash
# shellcheck shell=bash
# Hyprland stack: release-tag resolution, compatibility gate, source builds
# in the target, greetd/uwsm session, build-dep purge, firstboot staging.

HYPR_SRC_DIR="/var/tmp/hypr-deb-build"

# Latest stable release tag (vX.Y.Z or X.Y.Z; rc/alpha/nightly excluded).
resolve_latest_release_tag() {
  local repo_url="$1" tag=""
  tag="$(git ls-remote --tags --refs "${repo_url}" |
    awk -F/ '{print $NF}' |
    grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -V | tail -n1)"
  [[ -n "${tag}" ]] || fatal "No release tag found for ${repo_url}"
  printf '%s\n' "${tag}"
}

# Minimum version of dep $2 declared in CMake file $1 (empty if absent).
# Matches both "dep>=X.Y.Z" (pkg_check_modules) and
# "find_package(dep X.Y.Z" forms.
extract_min_version() {
  local cmake_file="$1" dep="$2" ver=""
  ver="$(grep -hoE "${dep}*>= *[0-9.]+" "${cmake_file}" 2>/dev/null |
    grep -oE '[0-9.]+$' | sort -V | tail -n1 || true)"
  if [[ -z "${ver}" ]]; then
    ver="$(grep -hoE "find_package\(${dep} +[0-9.]+" "${cmake_file}" \
      2>/dev/null | grep -oE '[0-9.]+$' | sort -V | tail -n1 || true)"
  fi
  printf '%s' "${ver}"
}

version_ge() { # $1 >= $2 ?
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# Assert every resolved dep tag satisfies Hyprland's declared minimums.
# Prints a requirement matrix; aborts on any mismatch (spec: no silent
# downgrades).
check_compat() {
  local cmake_file="$1" name="" required="" resolved="" bad=0
  info "Compatibility gate (Hyprland requirements vs resolved tags):"
  printf '  %-22s %-12s %-12s %s\n' "dependency" "required>=" "resolved" "status"
  for name in "${!HYPR_RESOLVED_TAG[@]}"; do
    required="$(extract_min_version "${cmake_file}" "${name}")"
    resolved="${HYPR_RESOLVED_TAG[${name}]#v}"
    if [[ -z "${required}" ]]; then
      printf '  %-22s %-12s %-12s %s\n' "${name}" "-" "${resolved}" "n/a"
      continue
    fi
    if version_ge "${resolved}" "${required}"; then
      printf '  %-22s %-12s %-12s %s\n' "${name}" "${required}" "${resolved}" "OK"
    else
      printf '  %-22s %-12s %-12s %s\n' "${name}" "${required}" "${resolved}" "TOO OLD"
      bad=1
    fi
  done
  ((bad == 0)) ||
    fatal "Dependency tag(s) do not satisfy Hyprland's requirements (matrix above)."
}

# Resolve all tags: from the network, or from the cache MANIFEST offline.
resolve_all_tags() {
  local name="" tag=""
  if ((NETWORK_AVAILABLE)); then
    for name in "${HYPR_BUILD_ORDER[@]}"; do
      tag="$(resolve_latest_release_tag "${HYPR_GIT_BASE}/${HYPR_REPO_NAME[${name}]}")"
      HYPR_RESOLVED_TAG[${name}]="${tag}"
      info "Resolved ${name} -> ${tag}"
    done
  else
    [[ -f "${CACHE_DIR}/sources/MANIFEST" ]] ||
      fatal "Offline and no cached source manifest."
    while read -r name tag; do
      HYPR_RESOLVED_TAG[${name}]="${tag}"
      info "Cached ${name} -> ${tag}"
    done <"${CACHE_DIR}/sources/MANIFEST"
  fi
}

# Place source tree for $1 at ${TARGET}${HYPR_SRC_DIR}/$1. Cache-first.
stage_source() {
  local name="$1" tag="${HYPR_RESOLVED_TAG[$1]}" dest="" tarball=""
  dest="${TARGET}${HYPR_SRC_DIR}/${name}"
  tarball="${CACHE_DIR}/sources/${name}-${tag}.tar.gz"
  mkdir -p "${dest}"
  if [[ -f "${tarball}" ]]; then
    tar -xzf "${tarball}" -C "${dest}" --strip-components=1
  elif ((NETWORK_AVAILABLE)); then
    curl -fsSL "${HYPR_GIT_BASE}/${HYPR_REPO_NAME[${name}]}/archive/refs/tags/${tag}.tar.gz" |
      tar -xz -C "${dest}" --strip-components=1
  else
    fatal "No cached source for ${name} ${tag} and no network."
  fi
}

install_build_deps() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${HYPR_BUILD_PACKAGES[*]}
  "
  # Record exactly what we may purge later.
  printf '%s\n' "${HYPR_BUILD_PACKAGES[@]}" \
    >"${TARGET}${HYPR_SRC_DIR}/.build-deps"
}

build_one() {
  local name="$1"
  info "Building ${name} ${HYPR_RESOLVED_TAG[${name}]}..."
  in_target "
    set -e
    cd '${HYPR_SRC_DIR}/${name}'
    cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local
    cmake --build build -j\"\$(nproc)\"
    cmake --install build
    ldconfig
  "
}

build_stack() {
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}"
  install_build_deps
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    stage_source "${name}"
    build_one "${name}"
  done
  in_target "test -x /usr/local/bin/Hyprland" ||
    fatal "Hyprland binary missing after build."
}

purge_build_deps() {
  if ((KEEP_BUILD_DEPS)); then
    info "--keep-build-deps: leaving toolchain installed."
    return 0
  fi
  info "Purging build dependencies (cached debs remain in ${TARGET_CACHE_DIR})..."
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    xargs -a '${HYPR_SRC_DIR}/.build-deps' apt-get purge -y
    apt-get autoremove --purge -y
  "
  rm -rf "${TARGET:?}${HYPR_SRC_DIR}"
}

configure_session() {
  info "Configuring greetd + uwsm session..."
  mkdir -p "${TARGET}/etc/greetd"
  cat >"${TARGET}/etc/greetd/config.toml" <<'EOF'
[terminal]
vt = 1

[default_session]
command = "agreety --cmd 'uwsm start -- hyprland.desktop'"
user = "_greetd"
EOF
  # Minimal valid Hyprland config for the user.
  mkdir -p "${TARGET}/home/${TARGET_USERNAME}/.config/hypr"
  cat >"${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.conf" <<'EOF'
# Minimal Hypr-Deb starter config.
monitor = ,preferred,auto,1
$mod = SUPER
bind = $mod, Return, exec, kitty
bind = $mod, Q, killactive,
bind = $mod SHIFT, E, exit,
EOF
  in_target "
    set -e
    chown -R '${TARGET_USERNAME}:${TARGET_USERNAME}' '/home/${TARGET_USERNAME}'
    systemctl enable greetd
    systemctl set-default graphical.target
  "
}

# --- First-boot deferral (--build-on-firstboot) ------------------------------

stage_firstboot() {
  info "Staging first-boot build..."
  local name=""
  mkdir -p "${TARGET}${HYPR_SRC_DIR}" "${TARGET}/usr/local/lib/hypr-deb"
  for name in "${HYPR_BUILD_ORDER[@]}"; do
    stage_source "${name}"
  done
  install_build_deps  # toolchain present so firstboot works offline

  cp lib/00-config.sh lib/01-log.sh scripts/60-hyprland.sh \
    "${TARGET}/usr/local/lib/hypr-deb/"

  cat >"${TARGET}/usr/local/sbin/hypr-deb-firstboot" <<EOF
#!/usr/bin/env bash
# One-shot first-boot Hyprland build (staged by hypr-deb.sh).
set -euo pipefail
source /usr/local/lib/hypr-deb/00-config.sh
source /usr/local/lib/hypr-deb/01-log.sh
source /usr/local/lib/hypr-deb/60-hyprland.sh
TARGET=""           # build on the running system
NETWORK_AVAILABLE=0 # sources are pre-staged; no network needed
CACHE_DIR="${TARGET_CACHE_DIR}"
KEEP_BUILD_DEPS=${KEEP_BUILD_DEPS}
resolve_all_tags
check_compat "\${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
for name in "\${HYPR_BUILD_ORDER[@]}"; do
  build_one "\${name}"
done
test -x /usr/local/bin/Hyprland
purge_build_deps
systemctl disable hypr-deb-firstboot.service
info "First-boot Hyprland build complete."
EOF
  chmod +x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"

  cat >"${TARGET}/etc/systemd/system/hypr-deb-firstboot.service" <<'EOF'
[Unit]
Description=Hypr-Deb first-boot Hyprland build
Before=greetd.service
ConditionPathExists=/usr/local/sbin/hypr-deb-firstboot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hypr-deb-firstboot
StandardOutput=journal+console
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  in_target "systemctl enable hypr-deb-firstboot.service"
}

phase_hyprland() {
  resolve_all_tags
  # The gate needs Hyprland's CMakeLists; stage hyprland's source first.
  stage_source hyprland
  check_compat "${TARGET}${HYPR_SRC_DIR}/hyprland/CMakeLists.txt"
  if ((BUILD_ON_FIRSTBOOT)); then
    stage_firstboot
  else
    build_stack
    purge_build_deps
  fi
  configure_session
}
```

Note on `build_one` inside the first boot script: with `TARGET=""`,
`in_target` (which the staged copy does not have) is not used — `build_one`
uses `in_target`, so the staged module needs it. Add this guard at the top
of `scripts/60-hyprland.sh` so the module is self-sufficient when staged:

```bash
# When staged standalone on the target (firstboot), there is no chroot:
# provide an in-place in_target if lib/04-chroot-mounts.sh wasn't sourced.
if ! declare -f in_target >/dev/null; then
  in_target() { /usr/bin/env bash -c "$*"; }
fi
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/hyprland-tags.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/60-hyprland.sh tests/hyprland-tags.sh
git commit -m "Add hyprland phase: tag resolution, compat gate, builds, session"
```

---

### Task 12: `scripts/50-boot.sh` — bootloader install and kernel sync hook

**Files:**
- Create: `scripts/50-boot.sh`
- Test: `tests/boot-config.sh`

- [ ] **Step 1: Write the failing test `tests/boot-config.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: bootloader config generation"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/target/boot/efi"

gen_cfg() { # $1 = function to call
  bash -c "
    source lib/00-config.sh
    source lib/01-log.sh
    source scripts/50-boot.sh
    TARGET='${tmp}/target'
    KVER=6.12.0-amd64
    ESP_UUID=AAAA-1111
    $1
  "
}

gen_cfg write_grub_cfg
out="$(cat "${tmp}/target/boot/efi/EFI/debian/grub.cfg")"
assert_contains "${out}" "root=ZFS=PRECISION/ROOT/debian13" "grub: ZFS root"
assert_contains "${out}" "/EFI/debian/vmlinuz" "grub: ESP kernel copy path"
assert_contains "${out}" "search --no-floppy --fs-uuid --set=root AAAA-1111" \
  "grub: finds ESP by UUID"

gen_cfg write_sdboot_entries
out="$(cat "${tmp}/target/boot/efi/loader/entries/debian.conf")"
assert_contains "${out}" "linux /EFI/debian/vmlinuz" "sd-boot: kernel"
assert_contains "${out}" "initrd /EFI/debian/initrd.img" "sd-boot: initrd"
assert_contains "${out}" "root=ZFS=PRECISION/ROOT/debian13" "sd-boot: ZFS root"

gen_cfg write_esp_sync_hook
out="$(cat "${tmp}/target/usr/local/sbin/hypr-deb-sync-esp")"
assert_contains "${out}" "vmlinuz" "hook copies kernel"
assert_contains "${out}" "initrd.img" "hook copies initrd"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/boot-config.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/50-boot.sh`**

```bash
# shellcheck shell=bash
# Bootloader phase: install exactly one of zbm | grub | systemd-boot on the
# RAID1 ESP, create its NVRAM entry (required to succeed), and for the
# FAT-bound loaders install a kernel-sync hook. Kernels live canonically in
# /boot on the ZFS root dataset.

KVER=""      # newest installed kernel version, set by detect_kernel
ESP_UUID=""  # filesystem UUID of /dev/md/efi

detect_kernel() {
  KVER="$(ls -1 "${TARGET}/boot" | grep -oP 'vmlinuz-\K.+' | sort -V | tail -n1)"
  [[ -n "${KVER}" ]] || fatal "No kernel found in ${TARGET}/boot"
  ESP_UUID="$(blkid -s UUID -o value /dev/md/efi)"
  info "Kernel: ${KVER}; ESP UUID: ${ESP_UUID}"
}

kernel_cmdline() {
  printf 'root=ZFS=%s rw %s' "${ROOT_DATASET}" "${KERNEL_CMDLINE_EXTRA}"
}

# Sync the newest kernel+initrd from ZFS /boot to the ESP (grub/sd-boot).
write_esp_sync_hook() {
  mkdir -p "${TARGET}/usr/local/sbin" \
    "${TARGET}/etc/kernel/postinst.d" "${TARGET}/etc/initramfs/post-update.d"
  cat >"${TARGET}/usr/local/sbin/hypr-deb-sync-esp" <<'EOF'
#!/usr/bin/env bash
# Copy the newest kernel + initrd from /boot (ZFS) to the ESP so FAT-bound
# bootloaders (grub, systemd-boot) can read them. Installed by hypr-deb.sh.
set -euo pipefail
esp="/boot/efi/EFI/debian"
kver="$(ls -1 /boot | grep -oP 'vmlinuz-\K.+' | sort -V | tail -n1)"
mkdir -p "${esp}"
cp "/boot/vmlinuz-${kver}" "${esp}/vmlinuz"
cp "/boot/initrd.img-${kver}" "${esp}/initrd.img"
sync
EOF
  chmod +x "${TARGET}/usr/local/sbin/hypr-deb-sync-esp"
  for hook in "${TARGET}/etc/kernel/postinst.d/zz-hypr-deb-esp" \
    "${TARGET}/etc/initramfs/post-update.d/zz-hypr-deb-esp"; do
    cat >"${hook}" <<'EOF'
#!/bin/sh
exec /usr/local/sbin/hypr-deb-sync-esp
EOF
    chmod +x "${hook}"
  done
}

run_esp_sync() {
  in_target "/usr/local/sbin/hypr-deb-sync-esp"
}

create_nvram_entry() { # $1=label $2=loader-path (backslash form)
  local disk="" pnum=1
  # Entry on both ESP member disks for redundancy; DISK1 first (primary).
  for disk in "${DISK2}" "${DISK1}"; do
    efibootmgr --create --disk "$(readlink -f "${disk}")" --part "${pnum}" \
      --label "$1" --loader "$2" ||
      fatal "efibootmgr entry creation failed (spec: NVRAM entry required)."
  done
}

# --- ZFSBootMenu ---------------------------------------------------------------

install_zbm() {
  local efi_src="${CACHE_DIR}/zfsbootmenu.EFI"
  if [[ ! -f "${efi_src}" ]]; then
    ((NETWORK_AVAILABLE)) || fatal "No cached ZBM binary and no network."
    mkdir -p "${CACHE_DIR}"
    curl -fsSL -o "${efi_src}" "${ZBM_EFI_URL}"
  fi
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/zbm"
  cp "${efi_src}" "${TARGET}${ESP_MOUNT}/EFI/zbm/zfsbootmenu.efi"
  # ZBM reads the kernel cmdline from this dataset property.
  zfs set org.zfsbootmenu:commandline="rw ${KERNEL_CMDLINE_EXTRA}" \
    "${ROOT_DATASET}"
  create_nvram_entry "ZFSBootMenu" '\EFI\zbm\zfsbootmenu.efi'
}

# --- GRUB ------------------------------------------------------------------------

write_grub_cfg() {
  mkdir -p "${TARGET}${ESP_MOUNT}/EFI/debian"
  cat >"${TARGET}${ESP_MOUNT}/EFI/debian/grub.cfg" <<EOF
# Static config written by hypr-deb.sh; regenerated by hypr-deb-sync-esp.
# GRUB reads kernel copies from the ESP and never reads the ZFS pool.
set timeout=3
search --no-floppy --fs-uuid --set=root ${ESP_UUID}
menuentry "Debian ${SUITE} (ZFS root)" {
  linux /EFI/debian/vmlinuz $(kernel_cmdline)
  initrd /EFI/debian/initrd.img
}
EOF
}

install_grub() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y grub-efi-amd64
    grub-install --target=x86_64-efi --efi-directory=${ESP_MOUNT} \
      --boot-directory=${ESP_MOUNT}/EFI/debian --bootloader-id=debian \
      --no-nvram
  "
  write_esp_sync_hook
  run_esp_sync
  write_grub_cfg
  create_nvram_entry "debian" '\EFI\debian\grubx64.efi'
}

# --- systemd-boot -----------------------------------------------------------------

write_sdboot_entries() {
  mkdir -p "${TARGET}${ESP_MOUNT}/loader/entries"
  cat >"${TARGET}${ESP_MOUNT}/loader/loader.conf" <<'EOF'
default debian.conf
timeout 3
EOF
  cat >"${TARGET}${ESP_MOUNT}/loader/entries/debian.conf" <<EOF
title   Debian ${SUITE} (ZFS root)
linux   /EFI/debian/vmlinuz
initrd  /EFI/debian/initrd.img
options $(kernel_cmdline)
EOF
}

install_sdboot() {
  in_target "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y systemd-boot
    bootctl install --esp-path=${ESP_MOUNT}
  "
  write_esp_sync_hook
  run_esp_sync
  write_sdboot_entries
  # bootctl install creates its own NVRAM entry; verify it exists.
  efibootmgr | grep -qi "Linux Boot Manager" ||
    create_nvram_entry "Linux Boot Manager" '\EFI\systemd\systemd-bootx64.efi'
}

phase_boot() {
  detect_kernel
  case "${BOOTLOADER}" in
    zbm) install_zbm ;;
    grub) install_grub ;;
    systemd-boot) install_sdboot ;;
    *) fatal "BOOTLOADER not set (preflight should have ensured this)." ;;
  esac
}
```

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/boot-config.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/50-boot.sh tests/boot-config.sh
git commit -m "Add boot phase: zbm/grub/systemd-boot with ESP kernel sync"
```

---

### Task 13: `scripts/90-verify.sh` and `scripts/99-cleanup.sh`

**Files:**
- Create: `scripts/90-verify.sh`
- Create: `scripts/99-cleanup.sh`
- Test: `tests/verify-report.sh`

- [ ] **Step 1: Write the failing test `tests/verify-report.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: verify check runner"
out="$(bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/90-verify.sh
  vcheck "always passes" true
  vcheck "always fails" false
  verify_report || true')"
assert_contains "${out}" "PASS: always passes" "pass line"
assert_contains "${out}" "FAIL: always fails" "fail line"
assert_contains "${out}" "1 of 2 checks failed" "summary"

assert_fails "verify_report exits nonzero on failure" bash -c '
  source lib/00-config.sh
  source lib/01-log.sh
  source scripts/90-verify.sh
  vcheck "f" false
  verify_report'

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/verify-report.sh` — Expected: FAIL

- [ ] **Step 3: Write `scripts/90-verify.sh`**

```bash
# shellcheck shell=bash
# Verification suite: every spec-mandated success condition, reported
# together; nonzero exit if anything fails.

VERIFY_TOTAL=0
VERIFY_FAILED=0

vcheck() { # $1=label, rest=command
  local label="$1"
  shift
  VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    info "PASS: ${label}"
  else
    warn "FAIL: ${label}"
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
  fi
}

verify_report() {
  if ((VERIFY_FAILED > 0)); then
    warn "${VERIFY_FAILED} of ${VERIFY_TOTAL} checks failed."
    return 1
  fi
  info "All ${VERIFY_TOTAL} checks passed."
}

phase_verify() {
  local esp="${TARGET}${ESP_MOUNT}"

  if ((BUILD_ON_FIRSTBOOT)); then
    vcheck "firstboot unit enabled" in_target \
      "systemctl is-enabled hypr-deb-firstboot.service"
    vcheck "firstboot runner staged" \
      test -x "${TARGET}/usr/local/sbin/hypr-deb-firstboot"
    vcheck "sources staged" \
      test -d "${TARGET}/var/tmp/hypr-deb-build/hyprland"
  else
    vcheck "Hyprland binary runs" in_target "/usr/local/bin/Hyprland --version"
    vcheck "Hyprland links resolve" in_target \
      "ldd /usr/local/bin/Hyprland | grep -v 'not found' >/dev/null &&
       ! ldd /usr/local/bin/Hyprland | grep -q 'not found'"
  fi

  vcheck "greetd enabled" in_target "systemctl is-enabled greetd"
  vcheck "uwsm present" in_target "command -v uwsm"
  vcheck "user hyprland.conf exists" \
    test -f "${TARGET}/home/${TARGET_USERNAME}/.config/hypr/hyprland.conf"

  vcheck "kernel on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/vmlinuz-* >/dev/null 2>&1"
  vcheck "initramfs on ZFS /boot" \
    bash -c "ls ${TARGET}/boot/initrd.img-* >/dev/null 2>&1"

  case "${BOOTLOADER}" in
    zbm)
      vcheck "ZBM EFI on ESP" test -f "${esp}/EFI/zbm/zfsbootmenu.efi"
      vcheck "ZBM cmdline property" bash -c \
        "zfs get -H -o value org.zfsbootmenu:commandline '${ROOT_DATASET}' |
         grep -q rw"
      ;;
    grub)
      vcheck "GRUB EFI on ESP" test -f "${esp}/EFI/debian/grubx64.efi"
      vcheck "grub.cfg on ESP" test -f "${esp}/EFI/debian/grub.cfg"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      ;;
    systemd-boot)
      vcheck "sd-boot EFI on ESP" \
        test -f "${esp}/EFI/systemd/systemd-bootx64.efi"
      vcheck "loader entry on ESP" \
        test -f "${esp}/loader/entries/debian.conf"
      vcheck "kernel copy on ESP" test -f "${esp}/EFI/debian/vmlinuz"
      ;;
  esac
  vcheck "NVRAM entry exists" bash -c "efibootmgr | grep -qiE 'ZFSBootMenu|debian|Linux Boot Manager'"

  vcheck "fstab ESP UUID valid" bash -c \
    "grep -oP 'UUID=\K[^ ]+(?= /boot/efi)' '${TARGET}/etc/fstab' |
     xargs -I{} blkid -U {}"
  vcheck "mdadm.conf present" test -s "${TARGET}/etc/mdadm/mdadm.conf"
  vcheck "pool bootfs set" bash -c \
    "zpool get -H -o value bootfs '${POOL_NAME}' |
     grep -qx '${ROOT_DATASET}'"
  vcheck "embedded cache repo valid" \
    test -f "${TARGET}${TARGET_CACHE_DIR}/repo/dists/${SUITE}/main/binary-${ARCH}/Packages"

  verify_report || fatal "Verification failed — installation is NOT complete."
  info "SUCCESS: bootable Debian + Hyprland conditions both met."
}
```

- [ ] **Step 4: Write `scripts/99-cleanup.sh`**

```bash
# shellcheck shell=bash
# Cleanup: tear down chroot binds, unmount the target tree, export the pool.
# Also used by the orchestrator's failure trap.

phase_cleanup() {
  info "Cleaning up..."
  teardown_chroot_binds
  if mountpoint -q "${TARGET}${ESP_MOUNT}" 2>/dev/null; then
    umount "${TARGET}${ESP_MOUNT}" || warn "ESP unmount failed"
  fi
  zfs unmount -a 2>/dev/null || true
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool export "${POOL_NAME}" ||
      warn "Pool export failed; export manually before reboot."
  fi
  info "Cleanup done. Remove the live medium and reboot."
}
```

- [ ] **Step 5: Run test, gate, commit**

Run: `bash tests/verify-report.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add scripts/90-verify.sh scripts/99-cleanup.sh tests/verify-report.sh
git commit -m "Add verify suite and cleanup phase"
```

---

### Task 14: `hypr-deb.sh` — orchestrator

**Files:**
- Create: `hypr-deb.sh`
- Test: `tests/orchestrator.sh`

- [ ] **Step 1: Write the failing test `tests/orchestrator.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: orchestrator wiring"

out="$(bash hypr-deb.sh --help)"
assert_contains "${out}" "Usage: hypr-deb.sh" "--help prints usage"
assert_contains "${out}" "--bootloader" "--help lists bootloader flag"

assert_fails "unknown flag fails" bash hypr-deb.sh --bogus

# Non-root full run must fail in preflight, not crash on sourcing.
out="$(bash hypr-deb.sh --yes --bootloader=grub 2>&1 || true)"
assert_contains "${out}" "Must run as root" "root check reached"

# Every phase function referenced by the dispatcher must exist.
out="$(bash -c '
  source lib/00-config.sh; source lib/01-log.sh; source lib/02-args.sh
  source lib/03-state.sh; source lib/04-chroot-mounts.sh
  for f in scripts/*.sh; do source "$f"; done
  for fn in phase_preflight phase_cache phase_storage phase_bootstrap \
            phase_system phase_boot phase_hyprland phase_verify \
            phase_cleanup; do
    declare -f "$fn" >/dev/null || { echo "MISSING $fn"; exit 1; }
  done
  echo all-present')"
assert_eq "all-present" "${out}" "all phase functions defined"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/orchestrator.sh` — Expected: FAIL

- [ ] **Step 3: Write `hypr-deb.sh`**

```bash
#!/usr/bin/env bash
# Hypr-Deb: Debian 13 + Hyprland (release tags) installer for the fixed
# three-disk ZFS/mdadm layout. See README.md and docs/superpowers/specs/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source lib/00-config.sh
source lib/01-log.sh
source lib/02-args.sh
source lib/03-state.sh
source lib/04-chroot-mounts.sh
source scripts/00-preflight.sh
source scripts/10-cache.sh
source scripts/20-storage.sh
source scripts/30-bootstrap.sh
source scripts/40-system.sh
source scripts/50-boot.sh
source scripts/60-hyprland.sh
source scripts/90-verify.sh
source scripts/99-cleanup.sh

on_error() {
  local exit_code=$?
  warn "FAILED in phase '${CURRENT_PHASE:-startup}' (exit ${exit_code})."
  [[ -n "${LOG_FILE}" ]] && warn "Full log: ${LOG_FILE}"
  teardown_chroot_binds
  exit "${exit_code}"
}

main() {
  parse_args "$@"
  state_init "${FRESH}"
  setup_logging "${LOG_DIR}"
  trap on_error ERR

  CURRENT_PHASE="preflight"
  run_phase preflight phase_preflight
  require_bootloader_choice

  if [[ "${RUN_PHASE}" != "full" ]]; then
    CURRENT_PHASE="${RUN_PHASE}"
    "phase_${RUN_PHASE//-/_}"
    return 0
  fi

  local name=""
  for name in cache storage bootstrap system boot hyprland verify; do
    CURRENT_PHASE="${name}"
    run_phase "${name}" "phase_${name}"
  done
  CURRENT_PHASE="cleanup"
  phase_cleanup
  info "Installation complete. Reboot into '${BOOTLOADER}'."
}

main "$@"
```

Note: phase order — `hyprland` runs after `boot` so the build-dep purge
can't remove anything the bootloader step needs; `verify` checks both.
Single-phase runs (`--phase=X`) intentionally skip stamps so a phase can
be re-run explicitly; preflight always runs first for safety.

- [ ] **Step 4: Run test, gate, commit**

Run: `bash tests/orchestrator.sh` → `PASS`; `bash tools/check.sh` → OK.

```bash
git add hypr-deb.sh tests/orchestrator.sh
git commit -m "Add orchestrator: module sourcing, dispatch, failure trap"
```

---

### Task 15: README, full test sweep, final review

**Files:**
- Create: `README.md`
- Create: `tests/run-all.sh`

- [ ] **Step 1: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
for t in tests/*.sh; do
  [[ "${t}" == *test-helpers* || "${t}" == *run-all* ]] && continue
  echo "== ${t}"
  bash "${t}" || status=1
done
exit "${status}"
```

- [ ] **Step 2: Write `README.md`**

Cover (in this order, plain prose and code blocks):
- What it is: Debian 13 + Hyprland-from-release-tags installer for the fixed
  three-disk layout; **destroys the listed disks**; the exact three by-id
  paths in a code block.
- VM test mode: `systemd-detect-virt` gate, exactly-three-disks rule,
  `VM_DISK1/2/3` overrides, QEMU/OVMF smoke-test recipe:

```bash
qemu-img create -f qcow2 d1.qcow2 32G
qemu-img create -f qcow2 d2.qcow2 32G
qemu-img create -f qcow2 d3.qcow2 32G
qemu-system-x86_64 -enable-kvm -m 8G -smp 4 \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=d1.qcow2,if=virtio -drive file=d2.qcow2,if=virtio \
  -drive file=d3.qcow2,if=virtio \
  -cdrom debian-live-13-amd64.iso -boot d
```

- Storage layout block (the amended one) + note on intentional divergence
  from `precision-zfs-dr.sh` parity (no md/boot; EFI grown to 2G).
- Usage: `sudo ./hypr-deb.sh` (prompts for bootloader and destruction),
  common flags, phase list, offline workflow (run `--phase=cache` on a
  networked machine with `--cache-dir` on real storage, carry it, run
  installer `--offline`).
- Bootloader choice semantics and the rollback warning for grub/systemd-boot
  ESP kernel copies; ZBM boots snapshots directly.
- Hyprland: bare scope, greetd+uwsm, release-tag policy, compat gate,
  build-dep purge, `--keep-build-deps`, `--build-on-firstboot`.
- Development checks: `bash tools/check.sh`, `bash tests/run-all.sh`.

- [ ] **Step 3: Full sweep**

Run: `bash tools/check.sh && bash tests/run-all.sh`
Expected: OK + every test `PASS`.

- [ ] **Step 4: Spec conformance read-through**

Open the spec and confirm each section maps to shipped code: run
environment (preflight), target disks (preflight), storage (20-storage),
Debian install (30/40), cache (10-cache and embed), bootloader (50-boot and
args prompt), Hyprland + hygiene (60-hyprland), structure (orchestrator and
modules), verification (90-verify), quality gates (tools/check.sh). Fix any
gap found before the final commit.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/run-all.sh
git commit -m "Add README and test runner; complete installer"
```

---

## Self-Review Notes (resolved during planning)

- **Spec coverage:** every spec section has a task (see Task 15 Step 4 map).
- **Type consistency:** globals are defined once in `lib/00-config.sh`;
  phase functions are uniformly `phase_<name>`; `part_dev` is the single
  partition-naming authority; `in_target` is the single chroot entrypoint
  (with the firstboot fallback guard in Task 11).
- **Known judgment calls an executor must NOT "fix" silently:**
  - `HYPR_BUILD_PACKAGES` is a best-effort trixie list; if a build fails on
    a missing `-dev` package, add it to the list in `lib/00-config.sh` and
    note it in the commit message — do not inline `apt-get install` calls.
  - greetd's default greeter binary in Debian is `agreety`; if the trixie
    package ships a different default user or path, adjust
    `configure_session` to match the package's `/etc/greetd/config.toml`
    conventions.
  - `systemd-boot` on a 2G ESP: `bootctl install` requires the ESP mounted
    at `/boot/efi` inside the chroot — `mount_target_tree` guarantees this.
```
