# Screenshot + Screen-Recording Capture Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the linux-fixes `linux-screenshot` / `linux-screen-record` helper scripts into the installer so a fresh install matches the verified live-box capture behavior (saved timestamped files, atomic selector lock, annotate, audio recording), bound to the installer's own conventional **Print** cluster — closing item 1 of epic #67.

**Architecture:** The installer already ships the capture *packages* and a set of throwaway inline `grim | wl-copy` binds (commit `44b5d34`). This plan replaces those inline binds with the proven helper scripts: a new `stage_capture_helpers()` in `scripts/60-hyprland.sh` writes `/usr/local/bin/linux-screenshot` and `/usr/local/bin/linux-screen-record` (verbatim from the live box, one codec-default change), the `hypr-deb.lua` keybind heredoc routes the Print cluster through them, three runtime dependencies are added to the package set, and a verify check + unit test cover the result.

**Tech Stack:** POSIX sh helper scripts, Hyprland Lua keybinds (`hl.bind` / `hl.dsp.exec_cmd`), bash installer (`scripts/60-hyprland.sh`), bash unit tests (`tests/*.sh`, auto-discovered by `tests/run-all.sh`), in-target `vcheck` verify (`scripts/90-verify.sh`).

---

## Scope & Decisions

**In scope (epic #67, item 1 only):** screenshot + recording capture. The other three epic items — swaync (#67 item 2), xdg-desktop-portal (#57), lxpolkit (#67 item 4) — are **out of scope** and tracked separately.

**Bind layout — Print cluster, NOT the live F10 layout.** The live box binds `CTRL/ALT/SHIFT + F10` because the maintainer's laptop labels F10 as "prt sc"; that is a personal-hardware choice. The installer ships conventional defaults for arbitrary keyboards, so it keeps the epic's Print mapping (per `docs/superpowers/specs/2026-06-21-desktop-defaults-design.md` — "installer ships conventional defaults, NOT the maintainer's personal helper scripts/dotfiles"):

| Bind | Action |
|------|--------|
| `Print` | `linux-screenshot region` |
| `SHIFT + Print` | `linux-screenshot monitor` |
| `CTRL + Print` | `linux-screenshot full` |
| `SUPER + Print` | `linux-screenshot annotate` |
| `SUPER + SHIFT + R` | `linux-screen-record desktop` |
| `SUPER + CTRL + R` | `linux-screen-record mic` |

**Codec default — `libx264`, NOT `h264_nvenc`.** The live `linux-screen-record` defaults to `h264_nvenc` because that box is NVIDIA. The installer targets generic hardware (Intel/AMD/NVIDIA); `h264_nvenc` makes `wf-recorder` exit at startup on non-NVIDIA GPUs, which the helper reports as "Screen recording failed". The staged copy therefore defaults to the universal software encoder `libx264`, keeping the `SCREEN_RECORD_CODEC` override so NVIDIA users can opt into NVENC. **This is the one deliberate deviation from the live script.**

**Notification UX depends on epic item 2.** Both helpers call `notify-send`; with no notification daemon installed yet (swaync = #67 item 2, not done), the toast won't display — the capture still succeeds and the file is still saved (`notify-send` runs last). Full toast UX arrives when swaync lands. `libnotify-bin` (the `notify-send` binary) is still required so the call resolves.

**Output directories are self-created.** Both helpers `mkdir -p` their own output dirs (`~/Pictures/Screenshots`, `~/Videos/Screen Recordings`), so the installer does not pre-create them — no `xdg-user-dirs` dependency needed (the helpers fall back to `~/Pictures` / `~/Videos` when `$XDG_*_DIR` is unset).

**New runtime dependencies:** `jq` (used by `linux-screenshot` monitor-mode `cursor_monitor_box`), `libnotify-bin` (`notify-send`), `ffmpeg` (codecs, per the epic). `grim slurp wf-recorder swappy wl-clipboard` are already in `TARGET_BASE_PACKAGES`; `pactl` is already provided by `pulseaudio-utils` in `AUDIO_PACKAGES`.

---

## File Structure

- `scripts/60-hyprland.sh` — add `stage_capture_helpers()` (stages both scripts), call it next to `stage_wallpapers`, and rewrite the screenshot/record keybind block in the `hypr-deb.lua` heredoc.
- `lib/00-config.sh` — add `ffmpeg jq libnotify-bin` to `TARGET_BASE_PACKAGES`.
- `scripts/90-verify.sh` — add `vcheck`s that both helpers are staged and executable.
- `tests/capture-tools.sh` — **new** unit test: packages present; both helpers staged, executable, with their load-bearing content; codec default is `libx264`.
- `tests/hyprland-config.sh` — update the two existing screenshot/record bind assertions (currently match `grim -g` / `wf-recorder`) to match the new helper-based binds.

---

### Task 1: Add capture runtime dependencies to the package set

**Files:**
- Modify: `lib/00-config.sh` (the `grim slurp wf-recorder swappy wl-clipboard` line inside `TARGET_BASE_PACKAGES`, ~`642`)
- Test: `tests/capture-tools.sh` (new)

- [ ] **Step 1: Write the failing test**

Create `tests/capture-tools.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: screenshot/recording capture helpers"

# --- packages ---------------------------------------------------------------
# The capture helpers need jq (monitor-mode geometry), notify-send (libnotify-bin),
# and ffmpeg (codecs) on top of the already-present grim/slurp/wf-recorder/swappy.
config="$(<lib/00-config.sh)"
for pkg in grim slurp wf-recorder swappy wl-clipboard jq libnotify-bin ffmpeg; do
  assert_contains "${config}" "${pkg}" \
    "TARGET_BASE_PACKAGES includes ${pkg}"
done

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/capture-tools.sh`
Expected: FAIL on `jq` / `libnotify-bin` / `ffmpeg` (`grim`…`wl-clipboard` already pass).

- [ ] **Step 3: Add the packages**

In `lib/00-config.sh`, change the capture line inside `TARGET_BASE_PACKAGES` from:

```bash
  grim slurp wf-recorder swappy wl-clipboard
```

to:

```bash
  grim slurp wf-recorder swappy wl-clipboard ffmpeg jq libnotify-bin
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/capture-tools.sh`
Expected: PASS (package assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/00-config.sh tests/capture-tools.sh
git commit -m "feat(capture): add jq/libnotify-bin/ffmpeg deps for capture helpers"
```

---

### Task 2: Stage the `linux-screenshot` and `linux-screen-record` helpers

**Files:**
- Modify: `scripts/60-hyprland.sh` (add `stage_capture_helpers()` immediately after `stage_wallpapers()` ends at ~`709`)
- Test: `tests/capture-tools.sh`

- [ ] **Step 1: Extend the failing test**

Append to `tests/capture-tools.sh`, **before** the final `finish_test` line:

```bash
# --- staged helper scripts --------------------------------------------------
info() { :; }
warn() { :; }
in_target() { :; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"

stage_capture_helpers

shot="${TARGET}/usr/local/bin/linux-screenshot"
rec="${TARGET}/usr/local/bin/linux-screen-record"

[[ -x "${shot}" ]] || { echo "  FAIL: linux-screenshot not staged executable" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -x "${rec}"  ]] || { echo "  FAIL: linux-screen-record not staged executable" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

shot_txt="$(<"${shot}")"
rec_txt="$(<"${rec}")"

# Screenshot: saves a timestamped PNG under Pictures/Screenshots, holds an
# atomic lock so key-mashing can't stack selectors, copies to clipboard.
assert_contains "${shot_txt}" 'Pictures}"/Screenshots' \
  "linux-screenshot saves under Pictures/Screenshots"
assert_contains "${shot_txt}" 'linux-screenshot.lock' \
  "linux-screenshot uses the atomic selector lock"
assert_contains "${shot_txt}" 'wl-copy --type image/png' \
  "linux-screenshot copies the capture to the clipboard"

# Recording: timestamped .mkv, software codec default (portable), NVENC opt-in.
assert_contains "${rec_txt}" 'Screen Recordings' \
  "linux-screen-record saves under Videos/Screen Recordings"
assert_contains "${rec_txt}" 'screen_recording_$timestamp.mkv' \
  "linux-screen-record writes a crash-safe .mkv"
assert_contains "${rec_txt}" 'SCREEN_RECORD_CODEC:-libx264' \
  "linux-screen-record defaults to the portable libx264 codec (NVENC opt-in)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/capture-tools.sh`
Expected: FAIL with `stage_capture_helpers: command not found`.

- [ ] **Step 3: Add `stage_capture_helpers()`**

In `scripts/60-hyprland.sh`, immediately **after** the closing `}` of `stage_wallpapers()` (the line after `chmod +x "${TARGET}/usr/local/bin/swww-cycle"`), insert:

```bash

# Stage the screenshot/recording capture helpers (epic #67, item 1; verified on
# the live box, recorded in linux-fixes/fixes.md). Bound to the Print cluster in
# hypr-deb.lua. Both helpers self-create their output dirs and hold an atomic
# selector lock so repeated key presses can't stack concurrent slurp overlays.
# Deviations from the live copy: the record codec defaults to libx264 (software,
# universal) instead of the live box's NVIDIA-only h264_nvenc — overridable via
# SCREEN_RECORD_CODEC. Notifications need a daemon (swaync, #67 item 2); the
# capture still saves the file without one.
stage_capture_helpers() {
  install -d "${TARGET}/usr/local/bin"
  cat >"${TARGET}/usr/local/bin/linux-screenshot" <<'EOF'
#!/bin/sh
set -eu

mode=${1:-region}
directory=${XDG_PICTURES_DIR:-"$HOME/Pictures"}/Screenshots
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
output="$directory/screenshot_$timestamp.png"
lock_directory=${XDG_RUNTIME_DIR:-/tmp}/linux-screenshot.lock
raw=

mkdir -p "$directory"

if ! mkdir "$lock_directory" 2>/dev/null; then
    exit 0
fi

cleanup() {
    [ -z "$raw" ] || rm -f "$raw"
    rmdir "$lock_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cursor_monitor_box() {
    # Logical box "X,Y WxH" (slurp coords) of the monitor under the pointer.
    set -- $(hyprctl cursorpos 2>/dev/null | tr -d ',')
    hyprctl monitors -j 2>/dev/null | jq -r --argjson x "${1:-0}" --argjson y "${2:-0}" '
        .[] | select(.x <= $x and $x < (.x + .width / .scale)
                 and .y <= $y and $y < (.y + .height / .scale))
        | "\(.x),\(.y) \((.width / .scale)|floor)x\((.height / .scale)|floor)"' | head -n1
}

select_geometry() {
    if [ -n "${SCREEN_CAPTURE_GEOMETRY:-}" ]; then
        printf '%s\n' "$SCREEN_CAPTURE_GEOMETRY"
        return
    fi

    box=$(cursor_monitor_box)
    case $mode in
        region|annotate)
            # Free click-drag selection. slurp's overlay spans all outputs;
            # it cannot confine a drawn region to one monitor.
            slurp
            ;;
        monitor)
            # Whole monitor under the pointer; no click needed.
            printf '%s\n' "$box"
            ;;
        full)
            printf '%s\n' ""
            ;;
        *)
            printf 'Usage: %s {region|monitor|full|annotate}\n' "$0" >&2
            exit 2
            ;;
    esac
}

geometry=$(select_geometry) || exit 0

if [ "$mode" = annotate ]; then
    raw=$(mktemp --suffix=.png)
    grim -g "$geometry" "$raw"
    swappy -f "$raw" -o "$output"
    [ -s "$output" ] || exit 0
else
    if [ -n "$geometry" ]; then
        grim -g "$geometry" "$output"
    else
        grim "$output"
    fi
fi

wl-copy --type image/png < "$output"
notify-send "Screenshot saved" "$output"
EOF
  chmod +x "${TARGET}/usr/local/bin/linux-screenshot"

  cat >"${TARGET}/usr/local/bin/linux-screen-record" <<'EOF'
#!/bin/sh
set -eu

mode=${1:-desktop}
runtime=${XDG_RUNTIME_DIR:-/tmp}/linux-screen-record
pid_file=$runtime/pid
output_file=$runtime/output
selection_lock=$runtime/selection.lock
directory="${XDG_VIDEOS_DIR:-"$HOME/Videos"}/Screen Recordings"

mkdir -p "$runtime" "$directory"

stop_recording() {
    pid=$(cat "$pid_file" 2>/dev/null || true)
    output=$(cat "$output_file" 2>/dev/null || true)
    command_line=

    if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
        command_line=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
        printf '%s\n' "$command_line" | grep -q 'wf-recorder'; then
        kill -INT "$pid"
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.1
        done
        notify-send "Screen recording saved" "$output"
    else
        notify-send "Screen recording" "Removed stale recorder state."
    fi

    rm -f "$pid_file" "$output_file"
}

if [ -f "$pid_file" ]; then
    stop_recording
    exit 0
fi

if ! mkdir "$selection_lock" 2>/dev/null; then
    exit 0
fi

cleanup_selection() {
    rmdir "$selection_lock" 2>/dev/null || true
}
trap cleanup_selection EXIT HUP INT TERM

case $mode in
    desktop)
        sink=$(pactl get-default-sink)
        audio_source=$sink.monitor
        label="desktop audio"
        ;;
    mic)
        audio_source=$(pactl get-default-source)
        label="microphone"
        ;;
    *)
        printf 'Usage: %s {desktop|mic}\n' "$0" >&2
        exit 2
        ;;
esac

if [ -n "${SCREEN_CAPTURE_GEOMETRY:-}" ]; then
    geometry=$SCREEN_CAPTURE_GEOMETRY
else
    geometry=$(slurp) || exit 0
fi
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
output="$directory/screen_recording_$timestamp.mkv"
codec=${SCREEN_RECORD_CODEC:-libx264}

wf-recorder \
    -g "$geometry" \
    --audio="$audio_source" \
    -c "$codec" \
    -f "$output" \
    -y \
    >/dev/null 2>&1 &
pid=$!

printf '%s\n' "$pid" > "$pid_file"
printf '%s\n' "$output" > "$output_file"

sleep 0.5
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file" "$output_file"
    notify-send "Screen recording failed" "wf-recorder exited during startup."
    exit 1
fi

cleanup_selection
trap - EXIT HUP INT TERM
notify-send "Screen recording started" "Region capture with $label. Press the same shortcut to stop."
EOF
  chmod +x "${TARGET}/usr/local/bin/linux-screen-record"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/capture-tools.sh`
Expected: PASS (packages + both helpers staged, executable, with the load-bearing content).

- [ ] **Step 5: Commit**

```bash
git add scripts/60-hyprland.sh tests/capture-tools.sh
git commit -m "feat(capture): stage linux-screenshot/linux-screen-record helpers"
```

---

### Task 3: Call `stage_capture_helpers` from the Hyprland phase

**Files:**
- Modify: `scripts/60-hyprland.sh` (the `stage_wallpapers` call site, ~`1183`)
- Test: `tests/capture-tools.sh` (already exercises `stage_capture_helpers` directly; this task wires it into the real run path)

- [ ] **Step 1: Add the call**

In `scripts/60-hyprland.sh`, find the line that calls `stage_wallpapers` (≈ line 1183) and add the new call directly after it:

```bash
  stage_wallpapers
  stage_capture_helpers
```

- [ ] **Step 2: Verify wiring by static check**

Run: `grep -n 'stage_capture_helpers' scripts/60-hyprland.sh`
Expected: two hits — the function definition (~`710`) and the new call site (~`1184`).

- [ ] **Step 3: Run the full test suite**

Run: `bash tests/run-all.sh`
Expected: PASS, including the new `tests/capture-tools.sh`.

- [ ] **Step 4: Commit**

```bash
git add scripts/60-hyprland.sh
git commit -m "feat(capture): stage capture helpers during the Hyprland phase"
```

---

### Task 4: Route the Print keybind cluster through the helpers

**Files:**
- Modify: `scripts/60-hyprland.sh` (the screenshot/record bind block in the `hypr-deb.lua` heredoc, `516-522`)
- Test: `tests/hyprland-config.sh` (the two screenshot/record bind assertions, `143-146`)

- [ ] **Step 1: Update the failing test assertions**

In `tests/hyprland-config.sh`, replace the existing two assertions:

```bash
  assert_contains "${deb}" "grim -g" \
    "screenshot region bind present (grim/slurp)"
  assert_contains "${deb}" "wf-recorder" \
    "screen-record toggle bind present (wf-recorder)"
```

with helper-based checks covering the full Print cluster:

```bash
  assert_contains "${deb}" 'hl.bind("Print", hl.dsp.exec_cmd("linux-screenshot region"))' \
    "Print captures a region via linux-screenshot"
  assert_contains "${deb}" 'hl.bind("SUPER + Print", hl.dsp.exec_cmd("linux-screenshot annotate"))' \
    "SUPER+Print annotates via linux-screenshot/swappy"
  assert_contains "${deb}" 'hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("linux-screen-record desktop"))' \
    "SUPER+SHIFT+R records desktop audio via linux-screen-record"
  assert_contains "${deb}" 'hl.bind("SUPER + CTRL + R", hl.dsp.exec_cmd("linux-screen-record mic"))' \
    "SUPER+CTRL+R records the microphone via linux-screen-record"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hyprland-config.sh`
Expected: FAIL — the new `linux-screenshot` / `linux-screen-record` bind strings are not in the staged module yet.

- [ ] **Step 3: Rewrite the bind block**

In `scripts/60-hyprland.sh`, replace lines `516-522` (the comment plus the four inline binds) with:

```lua
-- Screenshots + screen recording (epic #67, item 1): the staged helper scripts
-- linux-screenshot / linux-screen-record (in /usr/local/bin). They save
-- timestamped files (~/Pictures/Screenshots, ~/Videos/Screen Recordings), copy
-- to the clipboard, and hold an atomic lock so repeated presses don't stack
-- selectors. Conventional Print cluster; the user's dotfiles override these.
hl.bind("Print", hl.dsp.exec_cmd("linux-screenshot region"))               -- region -> file + clipboard
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("linux-screenshot monitor"))      -- monitor under pointer
hl.bind("CTRL + Print", hl.dsp.exec_cmd("linux-screenshot full"))          -- all outputs
hl.bind("SUPER + Print", hl.dsp.exec_cmd("linux-screenshot annotate"))     -- region -> swappy annotate
hl.bind("SUPER + SHIFT + R", hl.dsp.exec_cmd("linux-screen-record desktop")) -- toggle record (desktop audio)
hl.bind("SUPER + CTRL + R", hl.dsp.exec_cmd("linux-screen-record mic"))     -- toggle record (microphone)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/hyprland-config.sh && bash tests/capture-tools.sh`
Expected: PASS both.

- [ ] **Step 5: Commit**

```bash
git add scripts/60-hyprland.sh tests/hyprland-config.sh
git commit -m "feat(capture): route Print keybind cluster through capture helpers"
```

---

### Task 5: Add verify checks for the staged helpers

**Files:**
- Modify: `scripts/90-verify.sh` (in `phase_verify`, near the existing desktop/session checks — after the `welcome app installed` vcheck, ~`65`)

- [ ] **Step 1: Add the verify checks**

In `scripts/90-verify.sh`, inside `phase_verify`, add alongside the other staged-binary checks:

```bash
  vcheck "screenshot helper staged" test -x \
    "${TARGET}/usr/local/bin/linux-screenshot"
  vcheck "screen-record helper staged" test -x \
    "${TARGET}/usr/local/bin/linux-screen-record"
  vcheck "screenshot deps present (grim/slurp/jq)" in_target \
    "command -v grim && command -v slurp && command -v jq"
  vcheck "recording deps present (wf-recorder/notify-send)" in_target \
    "command -v wf-recorder && command -v notify-send"
```

- [ ] **Step 2: Static syntax check**

Run: `bash -n scripts/90-verify.sh`
Expected: no output (syntax OK).

- [ ] **Step 3: Confirm the checks are wired**

Run: `grep -n 'linux-screenshot\|linux-screen-record' scripts/90-verify.sh`
Expected: the two new `vcheck` lines.

- [ ] **Step 4: Commit**

```bash
git add scripts/90-verify.sh
git commit -m "feat(capture): verify capture helpers + deps are installed"
```

---

### Task 6: Full suite + epic bookkeeping

**Files:**
- None (verification + issue update)

- [ ] **Step 1: Run the whole test suite**

Run: `bash tests/run-all.sh`
Expected: exit 0; `tests/capture-tools.sh` and `tests/hyprland-config.sh` both pass.

- [ ] **Step 2: ShellCheck the touched scripts (if available)**

Run: `command -v shellcheck >/dev/null && shellcheck scripts/60-hyprland.sh scripts/90-verify.sh lib/00-config.sh tests/capture-tools.sh || echo "shellcheck not installed — skipped"`
Expected: no new warnings on the changed lines (or a clean skip).

- [ ] **Step 3: Tick epic #67 item 1 and credit the work**

Check the "Screenshots + recording" box in issue #67 and add a comment crediting the implementing commits, explicitly noting the two deliberate deviations from the live box (Print cluster instead of F10; `libx264` default instead of `h264_nvenc`). Leave #67 **open** — items 2 (swaync), 3 (#57 portal), and 4 (lxpolkit) remain.

```bash
gh issue comment 67 --body "Item 1 (screenshots + recording) folded into the installer: linux-screenshot / linux-screen-record helpers staged to /usr/local/bin, bound to the conventional Print cluster, deps (jq/libnotify-bin/ffmpeg) added, verify check + tests/capture-tools.sh added. Two deliberate deviations from the live box: Print cluster instead of the maintainer's F10 layout, and libx264 default codec instead of NVIDIA-only h264_nvenc (SCREEN_RECORD_CODEC overrides). Items 2 (swaync), 3 (#57), 4 (lxpolkit) still open."
```

(Editing the checkbox itself is a manual `gh issue edit 67 --body` or a web edit — the body markdown `- [ ]` → `- [x]` for the screenshots line.)

---

## Self-Review

**Spec coverage (epic #67 item 1 — "add the packages, stage both helper scripts + the keybindings, create the output dirs"):**
- Packages → Task 1 (jq/libnotify-bin/ffmpeg added; grim/slurp/wf-recorder/swappy/wl-clipboard already present). ✔
- Stage both helper scripts → Task 2 (`stage_capture_helpers`) + Task 3 (wired into phase). ✔
- Keybindings → Task 4 (Print cluster routed through helpers). ✔
- Output dirs → self-created by the helpers (`mkdir -p`), documented under Decisions; no separate installer step needed. ✔
- "a verify check + test each" → Task 5 (verify) + Tasks 1/2/4 (tests). ✔

**Placeholder scan:** No TBD/TODO; every code step shows full content (both helper bodies are verbatim with only the `codec` default changed). ✔

**Type/name consistency:** Function `stage_capture_helpers` defined in Task 2, called in Task 3, exercised in Task 2's test. Staged paths `/usr/local/bin/linux-screenshot` and `/usr/local/bin/linux-screen-record` are identical across Tasks 2, 4, 5. Bind action strings (`linux-screenshot region|monitor|full|annotate`, `linux-screen-record desktop|mic`) match the helpers' `mode` cases (`region|monitor|full|annotate`, `desktop|mic`). ✔
