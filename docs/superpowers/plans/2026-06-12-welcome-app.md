# Hyprland Welcome App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch `hyprland-welcome` on the user's first Hyprland login (marker-guarded, never again) and verify the binary exists after the guiutils build.

**Architecture:** The binary is already built/installed by the existing `hyprland-guiutils` source build (`utils/welcome` in the pinned tag → `/usr/local/bin/hyprland-welcome`). This plan only adds (1) a launch-time `hl.exec_cmd` entry to the generated `hyprland.lua` using a Lua long-bracket string wrapping a marker-guarded `sh -c`, and (2) a verify-phase vcheck in the in-chroot-build branch.

**Tech Stack:** bash, Hyprland Lua config (`hl.exec_cmd` top-level API, verified against hyprwm/Hyprland `example/hyprland.lua`), repo test pattern (`tests/test-helpers.sh`).

**Spec:** `docs/superpowers/specs/2026-06-12-welcome-app-design.md`. Branch: `feat/welcome-app` (already created).

**Key file facts:**
- `scripts/60-hyprland.sh:330-348`: `configure_session()` writes the `hyprland.lua` heredoc (`<<'EOF'`, no expansion) ending with the three `hl.bind` lines before `EOF`.
- `scripts/90-verify.sh:55-70` (approx): the `else` branch of `if ((BUILD_ON_FIRSTBOOT))` contains vchecks "Hyprland binary runs" and "Hyprland links resolve" — the new vcheck goes there (binary absent at verify time in firstboot mode).
- `tests/hyprland-config.sh`: stubs `info`/`fatal`/`in_target`, sources `scripts/60-hyprland.sh`, runs `configure_session` against a tmp TARGET, asserts on the generated lua content; `finish_test` at the end.

---

### Task 1: First-login welcome launch in the generated config

**Files:**
- Modify: `scripts/60-hyprland.sh` (hyprland.lua heredoc, lines ~332-348)
- Test: `tests/hyprland-config.sh`

- [ ] **Step 1: Write the failing test**

In `tests/hyprland-config.sh`, inside the `if [[ -f "${lua_config}" ]]` block after the existing `hl.bind` assertions (after the "Lua config exits Hyprland" assertion), add:

```bash
  assert_contains "${config}" "hyprland-welcome" \
    "Lua config launches the welcome app"
  assert_contains "${config}" ".welcome-shown" \
    "welcome launch is gated by the first-login marker"
  assert_contains "${config}" "/usr/local/bin/hyprland-welcome" \
    "welcome app referenced by absolute path"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hyprland-config.sh`
Expected: FAIL — 3 new assertions, "not found in output".

- [ ] **Step 3: Implement**

In `scripts/60-hyprland.sh`, inside the `hyprland.lua` heredoc, add after the last `hl.bind` line (`hl.bind(main_mod .. " + SHIFT + E", hl.dsp.exit())`) and before `EOF`:

```lua

-- First login only: show the welcome app once, marker-guarded. The marker
-- is touched BEFORE the app runs so a crashing welcome can never nag every
-- session. Lua long brackets keep the sh quoting sane.
hl.exec_cmd([[sh -c 'marker="$HOME/.config/hypr/.welcome-shown"; [ -e "$marker" ] || { touch "$marker"; /usr/local/bin/hyprland-welcome; }']])
```

(The heredoc is `<<'EOF'`-quoted: nothing expands at install time; `$HOME` and `$marker` are evaluated by the user's session shell at login.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/hyprland-config.sh`
Expected: PASS (all assertions ok).

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/60-hyprland.sh tests/hyprland-config.sh
git commit -m "feat: launch welcome app on first login (#11)"
```

---

### Task 2: Verify the welcome binary after in-chroot builds

**Files:**
- Modify: `scripts/90-verify.sh` (the `else` branch of `if ((BUILD_ON_FIRSTBOOT))`)
- Test: `tests/hyprland-config.sh`

- [ ] **Step 1: Write the failing test**

Append to `tests/hyprland-config.sh` before `finish_test`:

```bash
ver_body="$(bash -c 'source lib/00-config.sh; source lib/01-log.sh
  source scripts/90-verify.sh
  declare -f phase_verify' 2>/dev/null || true)"
assert_contains "${ver_body}" "welcome app installed" \
  "verify checks the welcome binary exists"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hyprland-config.sh`
Expected: FAIL — "welcome app installed" not found.

- [ ] **Step 3: Implement**

In `scripts/90-verify.sh`, in the `else` branch of `if ((BUILD_ON_FIRSTBOOT))` (after the existing `vcheck "Hyprland links resolve" ...` line), add:

```bash
    # guiutils builds every util from its root CMakeLists; if a future tag
    # drops or renames the welcome util, fail loudly here (issue #11).
    vcheck "welcome app installed" \
      test -x "${TARGET}/usr/local/bin/hyprland-welcome"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/hyprland-config.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite and shellcheck**

Run: `bash tests/run-all.sh`
Expected: all PASS.
Run: `shellcheck -x scripts/60-hyprland.sh scripts/90-verify.sh tests/hyprland-config.sh`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/90-verify.sh tests/hyprland-config.sh
git commit -m "feat: verify welcome binary after guiutils build (#11)"
```

---

### Task 3: Push and PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/welcome-app
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --head feat/welcome-app \
  --title "feat: first-login welcome app launch (#11)" \
  --body "hyprland-welcome is already built and installed by the hyprland-guiutils source build; what was missing was the launch. Adds a marker-guarded hl.exec_cmd to the generated hyprland.lua (first login only, marker touched before launch so a crashing app can't nag) and a verify vcheck that the binary exists after in-chroot builds. Spec: docs/superpowers/specs/2026-06-12-welcome-app-design.md. Closes #11."
```

---

## Verification limits

Tests assert generated-file content; they cannot prove the welcome window renders. Real validation: first login on an installed system shows the welcome app once, and `~/.config/hypr/.welcome-shown` exists afterward.
