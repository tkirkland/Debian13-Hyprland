# swaync Notifications Implementation Plan (epic #67, item 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fold `sway-notification-center` (swaync) into the installer as the sole notification daemon — package + authored `config.json`/`style.css` staged into the user's `~/.config/swaync/`, `Super+N`/`Super+Shift+N` keybinds — and separately fix THIS live machine (swaync running with no config) by tracking the config in chezmoi and applying it. Completes epic #67 item 2 and makes the item-1 capture-helper `notify-send` toasts actually display on a fresh install.

**Architecture:** swaync is an apt package (unlike swww/hyprlock which are source-built), so it joins `TARGET_BASE_PACKAGES`. The Debian package ships `swaync.service` and auto-enables it via `graphical-session.target.wants` — no manual enablement. Mako is already absent from the installer (zero references), so there is nothing to purge. The installer stages an authored `config.json` + `style.css` into `${TARGET}/home/${TARGET_USERNAME}/.config/swaync/` (covered by the existing `chown -R` at 60-hyprland.sh:1384). No tracked original config exists — both files are AUTHORED from the fixes.md prose spec.

**Two style.css variants (deliberate):** swaync should match the *window* decoration of its environment.
- **Installer variant** — matches the installer's accent (`#33ccff→#00ff99` 45° gradient, as in its hyprlock), dark card `#1e1e2e`/text `#f5f5f5`, gradient border via the GTK `background-clip: padding-box, border-box` double-background trick.
- **Live/chezmoi variant** — matches THIS box's current window border: solid `#4a6f9a`, `border_size 1`, `rounding 6`. Same palette/layout, simpler solid border.

**Tech Stack:** apt package set (`lib/00-config.sh`), bash installer (`scripts/60-hyprland.sh`, `scripts/90-verify.sh`), Hyprland Lua keybinds, swaync 0.11 (GTK4) JSON+CSS, bash tests (`tests/*.sh`), chezmoi (`~/.local/share/chezmoi/dot_config/swaync/`).

---

## Decisions / constraints locked

- **config.json (shared, both variants identical):** `positionX: right`, `positionY: bottom`, `timeout: 5`, `timeout-critical: 0`, `control-center-width: 400`, `notification-window-width: 400`, widgets `["title","dnd","mpris","notifications"]`. Schema-correct against swaync 0.11 (`/etc/xdg/swaync/config.json` is the schema base).
- **No Mako anywhere** — the installer never referenced it; do not add or purge it.
- **swaync installed via apt** → add `sway-notification-center` to `TARGET_BASE_PACKAGES` (next to the capture line).
- **Keybinds** in `hypr-deb.lua`: `Super+N` → `swaync-client -t -sw` (toggle panel), `Super+Shift+N` → `swaync-client -d -sw` (DND).
- **Live fix method:** chezmoi (author into `dot_config/swaync/`, `chezmoi apply`, restart swaync, verify no CSS parse errors in the journal).

---

## File Structure

- `lib/00-config.sh` — add `sway-notification-center` to `TARGET_BASE_PACKAGES`.
- `scripts/60-hyprland.sh` — new `stage_swaync_config()` (writes config.json + installer style.css); call it in the Hyprland phase before the `chown -R`; add the two keybinds to the `hypr-deb.lua` heredoc.
- `scripts/90-verify.sh` — vchecks: swaync present, config staged, binds present.
- `tests/swaync-config.sh` — **new**: package present; staged config.json has the position/timeout/width/widgets; style.css has palette + gradient border; keybinds present in hypr-deb.lua.
- `tests/hyprland-config.sh` — add assertions for the two swaync binds.
- `~/.local/share/chezmoi/dot_config/swaync/{config.json,style.css}` — **new** (live variant), applied via `chezmoi apply`.

---

### Task 1: Add sway-notification-center to the package set

**Files:** Modify `lib/00-config.sh`; Create `tests/swaync-config.sh`.

- [ ] **Step 1: Write the failing test** — Create `tests/swaync-config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/test-helpers.sh

echo "test: swaync notification daemon (config + keybinds)"

# --- package ----------------------------------------------------------------
config="$(<lib/00-config.sh)"
assert_contains "${config}" "sway-notification-center" \
  "TARGET_BASE_PACKAGES includes sway-notification-center"

finish_test
```

- [ ] **Step 2: Run, verify it FAILS**: `bash tests/swaync-config.sh` → FAIL on sway-notification-center.

- [ ] **Step 3: Add the package** — in `lib/00-config.sh`, on the line `  grim slurp wf-recorder swappy wl-clipboard ffmpeg jq libnotify-bin`, append ` sway-notification-center`:

```bash
  grim slurp wf-recorder swappy wl-clipboard ffmpeg jq libnotify-bin sway-notification-center
```

- [ ] **Step 4: Run, verify it PASSES**: `bash tests/swaync-config.sh` → PASS.

- [ ] **Step 5: Commit**:
```bash
git add lib/00-config.sh tests/swaync-config.sh
git commit -m "feat(swaync): add sway-notification-center to the package set"
```

---

### Task 2: Stage the authored config.json + installer style.css

**Files:** Modify `scripts/60-hyprland.sh` (add `stage_swaync_config()` after `stage_capture_helpers()`); extend `tests/swaync-config.sh`.

- [ ] **Step 1: Extend the failing test** — append to `tests/swaync-config.sh` before `finish_test`:

```bash
# --- staged config ----------------------------------------------------------
info() { :; }
warn() { :; }
in_target() { :; }
fatal() { printf 'fatal: %s\n' "$*" >&2; return 1; }
source scripts/60-hyprland.sh

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
TARGET="${tmp}/target"
TARGET_USERNAME="tester"

stage_swaync_config

sw_dir="${TARGET}/home/${TARGET_USERNAME}/.config/swaync"
cfg="${sw_dir}/config.json"
css="${sw_dir}/style.css"

[[ -f "${cfg}" ]] || { echo "  FAIL: config.json not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
[[ -f "${css}" ]] || { echo "  FAIL: style.css not staged" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }

cfg_txt="$(<"${cfg}")"
css_txt="$(<"${css}")"

# config.json is valid JSON and carries the load-bearing settings.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${cfg}" \
    || { echo "  FAIL: config.json is not valid JSON" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
fi
assert_contains "${cfg_txt}" '"positionX": "right"' "toasts anchored right"
assert_contains "${cfg_txt}" '"positionY": "bottom"' "toasts anchored bottom"
assert_contains "${cfg_txt}" '"timeout": 5' "5s default timeout"
assert_contains "${cfg_txt}" '"timeout-critical": 0' "criticals persist"
assert_contains "${cfg_txt}" '"notification-window-width": 400' "400px toast width"
assert_contains "${cfg_txt}" '"mpris"' "mpris widget present"

# style.css matches the installer window accent (gradient) + palette.
assert_contains "${css_txt}" '#1e1e2e' "dark card background"
assert_contains "${css_txt}" '#f5f5f5' "light text"
assert_contains "${css_txt}" '#33ccff' "installer accent gradient start"
assert_contains "${css_txt}" '#00ff99' "installer accent gradient end"
assert_contains "${css_txt}" 'background-clip: padding-box, border-box' \
  "gradient-border via background-clip double background"
```

- [ ] **Step 2: Run, verify it FAILS**: `bash tests/swaync-config.sh` → `stage_swaync_config: command not found`.

- [ ] **Step 3: Add `stage_swaync_config()`** — in `scripts/60-hyprland.sh`, immediately after the closing `}` of `stage_capture_helpers()`, insert:

```bash

# Stage the swaync (sway-notification-center) config (epic #67, item 2). The
# Debian package ships + auto-enables swaync.service via graphical-session.target
# .wants, so this only writes the user config. Authored from linux-fixes/fixes.md
# (no tracked original existed). style.css matches the installer's window accent
# (#33ccff->#00ff99 45deg gradient, as in hyprlock); the chown -R in the Hyprland
# phase gives the user ownership. Mako is intentionally never installed.
stage_swaync_config() {
  local sw_dir="${TARGET}/home/${TARGET_USERNAME}/.config/swaync"
  install -d "${sw_dir}"
  cat >"${sw_dir}/config.json" <<'EOF'
{
  "$schema": "/etc/xdg/swaync/configSchema.json",
  "positionX": "right",
  "positionY": "bottom",
  "layer": "overlay",
  "control-center-layer": "top",
  "layer-shell": true,
  "cssPriority": "application",
  "timeout": 5,
  "timeout-low": 5,
  "timeout-critical": 0,
  "fit-to-screen": true,
  "control-center-width": 400,
  "control-center-height": 600,
  "notification-window-width": 400,
  "keyboard-shortcuts": true,
  "image-visibility": "when-available",
  "transition-time": 200,
  "hide-on-clear": false,
  "hide-on-action": true,
  "text-empty": "No Notifications",
  "widgets": [
    "title",
    "dnd",
    "mpris",
    "notifications"
  ],
  "widget-config": {
    "title": {
      "text": "Notifications",
      "clear-all-button": true,
      "button-text": "Clear All"
    },
    "dnd": {
      "text": "Do Not Disturb"
    },
    "mpris": {
      "image-size": 96,
      "image-radius": 8
    }
  }
}
EOF
  cat >"${sw_dir}/style.css" <<'EOF'
/* swaync style — installer baseline (epic #67, item 2).
 * Matches the installer's window accent: 45deg #33ccff->#00ff99 gradient border
 * (as in hyprlock), dark card #1e1e2e / text #f5f5f5. GTK4 CSS cannot gradient a
 * rounded border-color, so the frame is a gradient background clipped to
 * border-box behind a transparent 2px border, with the dark fill clipped to
 * padding-box. Card rounding 8px = window rounding + 2px border. */

@keyframes swaync-fadein {
  from { opacity: 0; }
  to   { opacity: 1; }
}

.notification-row {
  background: transparent;
}

.notification {
  margin: 6px;
  border-radius: 8px;
  border: 2px solid transparent;
  background-image:
    linear-gradient(#1e1e2e, #1e1e2e),
    linear-gradient(45deg, #33ccff, #00ff99);
  background-origin: border-box;
  background-clip: padding-box, border-box;
  animation: swaync-fadein 200ms ease-in;
}

.notification.critical {
  box-shadow: inset 0 0 0 1px #ff3355;
}

.notification-content {
  padding: 8px;
  border-radius: 6px;
}

.notification .summary {
  color: #f5f5f5;
  font-weight: bold;
}

.notification .body,
.notification .time {
  color: #f5f5f5;
}

.control-center {
  border-radius: 8px;
  border: 2px solid transparent;
  background-image:
    linear-gradient(#1e1e2e, #1e1e2e),
    linear-gradient(45deg, #33ccff, #00ff99);
  background-origin: border-box;
  background-clip: padding-box, border-box;
}

.control-center .notification {
  margin: 6px;
}
EOF
}
```

- [ ] **Step 4: Run, verify it PASSES**: `bash tests/swaync-config.sh` (exit 0) and `bash -n scripts/60-hyprland.sh` (syntax OK).

- [ ] **Step 5: Commit**:
```bash
git add scripts/60-hyprland.sh tests/swaync-config.sh
git commit -m "feat(swaync): stage authored config.json + installer style.css"
```

---

### Task 3: Wire stage_swaync_config into the Hyprland phase

**Files:** Modify `scripts/60-hyprland.sh` (call site next to `stage_capture_helpers`).

- [ ] **Step 1: Find the call site** — `grep -n 'stage_capture_helpers$' scripts/60-hyprland.sh` shows the bare invocation (the call, not the definition). It sits after `stage_wallpapers`.

- [ ] **Step 2: Add the call** — directly after the `stage_capture_helpers` invocation line, add `stage_swaync_config` at identical indentation:
```bash
  stage_wallpapers
  stage_capture_helpers
  stage_swaync_config
```

- [ ] **Step 3: Verify wiring**: `grep -n 'stage_swaync_config' scripts/60-hyprland.sh` → two hits (definition + call). Confirm the call precedes the `chown -R '${TARGET_USERNAME}...` at ~1384 so the staged files get owned by the user (`grep -n 'chown -R' scripts/60-hyprland.sh`; the call's enclosing function must run before it — same path as stage_capture_helpers, already verified reachable).

- [ ] **Step 4: Run suite**: `bash tests/run-all.sh` → same as baseline (all pass except pre-existing root-only `tests/orchestrator.sh`). `bash -n scripts/60-hyprland.sh` OK.

- [ ] **Step 5: Commit**:
```bash
git add scripts/60-hyprland.sh
git commit -m "feat(swaync): stage swaync config during the Hyprland phase"
```

---

### Task 4: Add the swaync keybinds to hypr-deb.lua

**Files:** Modify `scripts/60-hyprland.sh` (the `hypr-deb.lua` heredoc, after the capture binds); Modify `tests/hyprland-config.sh`.

- [ ] **Step 1: Add test assertions** — in `tests/hyprland-config.sh`, in the `hypr-deb.lua` assertion block (near the capture-bind assertions), add:
```bash
  assert_contains "${deb}" 'hl.bind("SUPER + N", hl.dsp.exec_cmd("swaync-client -t -sw"))' \
    "SUPER+N toggles the swaync panel"
  assert_contains "${deb}" 'hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("swaync-client -d -sw"))' \
    "SUPER+SHIFT+N toggles swaync Do-Not-Disturb"
```

- [ ] **Step 2: Run, verify it FAILS**: `bash tests/hyprland-config.sh` → FAIL (needles absent).

- [ ] **Step 3: Add the binds** — in `scripts/60-hyprland.sh`, inside the `hypr-deb.lua` heredoc, immediately after the capture/record bind block (after the `SUPER + CTRL + R` line), add:
```lua
-- Notifications (swaync, epic #67 item 2): toggle the notification-center panel
-- and Do-Not-Disturb. -sw skips waiting for the daemon.
hl.bind("SUPER + N", hl.dsp.exec_cmd("swaync-client -t -sw"))         -- toggle panel
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("swaync-client -d -sw")) -- toggle DND
```

- [ ] **Step 4: Run, verify PASS**: `bash tests/hyprland-config.sh` and `bash tests/swaync-config.sh` (exit 0); `bash -n scripts/60-hyprland.sh` OK.

- [ ] **Step 5: Commit**:
```bash
git add scripts/60-hyprland.sh tests/hyprland-config.sh
git commit -m "feat(swaync): bind SUPER+N panel and SUPER+SHIFT+N DND"
```

---

### Task 5: Add verify checks

**Files:** Modify `scripts/90-verify.sh` (unconditional block, next to the capture-helper vchecks after the `fi`).

- [ ] **Step 1: Add vchecks** — after the capture-helper vchecks (before `vcheck "greetd enabled"`), at the same 2-space indentation:
```bash
  # swaync notification daemon + user config (epic #67, item 2). Package
  # auto-enables swaync.service; config staged by stage_swaync_config.
  vcheck "swaync installed" in_target "command -v swaync && command -v swaync-client"
  vcheck "swaync config staged" test -f \
    "${TARGET}/home/${TARGET_USERNAME}/.config/swaync/config.json"
  vcheck "swaync style staged" test -f \
    "${TARGET}/home/${TARGET_USERNAME}/.config/swaync/style.css"
```

- [ ] **Step 2: Static checks**: `bash -n scripts/90-verify.sh` OK; `grep -n 'swaync' scripts/90-verify.sh` shows the three checks.

- [ ] **Step 3: Suite**: `bash tests/run-all.sh` → baseline result.

- [ ] **Step 4: Commit**:
```bash
git add scripts/90-verify.sh
git commit -m "feat(swaync): verify daemon + staged config"
```

---

### Task 6: Live-box fix via chezmoi + final review + bookkeeping

**Files:** Create `~/.local/share/chezmoi/dot_config/swaync/{config.json,style.css}` (live variant). No installer files.

- [ ] **Step 1: Author the chezmoi config.json** — identical to the installer's config.json (Task 2). Write to `~/.local/share/chezmoi/dot_config/swaync/config.json`.

- [ ] **Step 2: Author the chezmoi style.css (LIVE variant)** — same as the installer style.css BUT the border matches THIS box's window decoration (solid `#4a6f9a`, `border_size 1`, `rounding 6`). Replace both gradient-border blocks (`.notification` and `.control-center`) with:
```css
.notification {
  margin: 6px;
  border-radius: 7px;              /* window rounding 6 + 1px border */
  border: 1px solid #4a6f9a;       /* live active-border colour (rgba 4a6f9aee) */
  background-color: #1e1e2e;
  animation: swaync-fadein 200ms ease-in;
}
.control-center {
  border-radius: 7px;
  border: 1px solid #4a6f9a;
  background-color: #1e1e2e;
}
```
Keep the `@keyframes`, `.critical`, `.summary`/`.body`/`.time` colour rules, and `.notification-content` from the installer variant.

- [ ] **Step 3: Apply and restart** —
```bash
chezmoi diff              # review what will change (should be the two new files only)
chezmoi apply
systemctl --user restart swaync.service || swaync &   # re-read config
```

- [ ] **Step 4: Verify live, no CSS parse errors** —
```bash
# swaync logs CSS parse errors to the journal; a clean reload is the real check.
journalctl --user -u swaync.service --since "1 min ago" --no-pager | grep -iE 'css|error|parse' || echo "no swaync CSS/parse errors"
swaync-client -d -sw; swaync-client -d -sw    # DND off->on->off, exit 0
notify-send "swaync test" "bottom-right, gradient/solid border matches window"   # visually confirm placement
ls -la ~/.config/swaync/                       # config now present (chezmoi-applied)
```
Report the journal result and whether the test toast appeared bottom-right. If swaync logs a CSS parse error, fix the offending rule and re-apply (this is the visual/functional verification loop the installer side can't run).

- [ ] **Step 5: Dispatch final holistic review** of the installer branch (whole diff vs develop): coherence (package ⊇ swaync-client usage; binds valid; staged paths == verify paths == chezmoi intent), config.json valid JSON, no Mako references anywhere, tests green except pre-existing orchestrator, shellcheck clean. Address any real issue.

- [ ] **Step 6: Merge + push + bookkeeping** —
```bash
git checkout develop && git merge --no-ff feat/swaync-notifications -m "Merge feat/swaync-notifications: swaync as default notifier (#67 item 2)"
git push origin develop      # updates PR #95 (develop->master)
```
Then tick `#67` item 2's checkbox (`- [ ] **Notifications (swaync)**` → `- [x]`) via `gh issue edit 67 --body-file`, and comment crediting the commits + noting: authored config (no tracked original), two CSS variants (installer gradient vs live solid-blue), live box fixed via chezmoi. Leave epic open (items 3/#57, 4/lxpolkit remain).

- [ ] **Step 7: Cross-check issues** — re-run the `master..develop` vs open-issues audit (as after item 1): confirm no OTHER open issue is now resolved, update PR #95 body to note item 2 is also complete, and confirm no “fixed-but-open” strays.

---

## Self-Review

- **Spec coverage (fixes.md item 2):** package + auto-enable (Task 1; package auto-enables) ✓; author config.json position/timeout/width/widgets (Task 2) ✓; style.css palette + gradient border matched to window (Task 2 installer / Task 6 live) ✓; no Mako (locked constraint; installer never had it) ✓; keybinds Super+N / Super+Shift+N (Task 4) ✓; link/stage into ~/.config/swaync (Task 2 stage + Task 3 wire + Task 6 chezmoi) ✓; verify (Task 5) ✓.
- **Placeholder scan:** all config/CSS/JSON content is inline and complete; no TBD.
- **Consistency:** `stage_swaync_config` defined (T2), called (T3), tested (T2); staged paths `home/${TARGET_USERNAME}/.config/swaync/{config.json,style.css}` identical across T2/T3/T5; bind action strings `swaync-client -t -sw` / `-d -sw` identical across T4 test + heredoc + T6 live verify.
- **Known unverifiable:** installer-variant GTK4 CSS rendering can't be verified in-installer; the live chezmoi deploy (T6) exercises the same selectors and surfaces CSS parse errors, de-risking the technique.
