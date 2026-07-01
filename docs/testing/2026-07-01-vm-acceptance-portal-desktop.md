# VM Acceptance Checklist — Portal / lxpolkit / Dolphin desktop baseline

**Scope:** epic **#67** (all 4 items), **#57** (xdg-desktop-portal), **#70** (Dolphin file manager),
and the partial slice of **#51** (prefer-dark).
**Why this exists:** these land on `develop` (PR #95) as code, but their acceptance can only be
proven on a real ISO build + VM. Merge alone does **not** close #67/#57/#70 — this checklist is the gate.

Tick each box on a fresh VM install. If **#1 (greeter)** fails, stop and capture the build log — that
is the #64 dead-greeter regression the design engineers against.

---

## 0. Build the ISO (build host, as root)

```bash
sudo tools/build-iso.sh --confirm
# out: /home/me/isos/Debian13-Hyprland-offline.iso   (paths env-overridable, see build-iso.sh header)
```

**Watch the build log to learn which portal path you got:**
- `xdph build failed; packaged wlr fallback stands` → Option **A** (packaged wlr; no native picker). Still a pass.
- No such warning **and** a pooled `xdg-desktop-portal-hyprland_*.deb` → Option **B** (source xdph, native picker).

- [ ] ISO built without a fatal error.
- [ ] Noted which backend the log indicates (A or B): ____________

---

## 1. Greeter + session (the #64 invariant)

- [ ] Boots to greetd, log in, land in Hyprland.
      *(uwsm was not stranded by the optional xdph build — the whole point of keeping xdph out of `HYPR_BUILD_ORDER`.)*
- [ ] `systemctl --user is-active graphical-session.target` → `active`.

## 2. Portal broker + backend

- [ ] `systemctl --user status xdg-desktop-portal` → active (running).
- [ ] `ls ~/.config/xdg-desktop-portal/hyprland-portals.conf` exists and contains
      `default=gtk` and `org.freedesktop.impl.portal.ScreenCast=hyprland;wlr`.
- [ ] `systemctl --user status xdg-desktop-portal-hyprland xdg-desktop-portal-wlr`
      → at least one active. Record which: ____________
      *(hyprland = Option B; only wlr = Option A fallback. Either is a pass.)*
- [ ] ScreenCast interface is exposed:
      ```bash
      busctl --user introspect org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop | grep -i ScreenCast
      ```
      → shows `org.freedesktop.portal.ScreenCast`.

## 3. Screen share end-to-end (#57 acceptance task)

Pick one:
- **Browser:** open `https://mozilla.github.io/webrtc-landing/gum_test.html` (or Google Meet / Jitsi
  "Share screen") and start a share.
- **OBS Studio:** add a **"Screen Capture (PipeWire)"** source.

- [ ] A chooser appears — the Qt6 **`hyprland-share-picker`** (Option B) or the **wlr selector** (Option A).
- [ ] Selecting a monitor/window shows **live video of the desktop** in the preview.
- [ ] (On failure) captured `journalctl --user -u 'xdg-desktop-portal*' -b` for triage.

## 4. lxpolkit (#67 item 4)

- [ ] Trigger a privileged action, e.g. `pkexec true` (or plug/mount, network auth).
- [ ] A **graphical password dialog** appears (lxpolkit), not a silent failure / terminal prompt.
- [ ] `ls /etc/xdg/autostart/lxpolkit.desktop` present (installer verify already asserts this).

## 5. Dolphin (#70)

- [ ] `Super+E` opens a file manager window, **or** `dolphin` from a terminal launches.
- [ ] It browses `~` without crashing.

## 6. Dark mode (#51 partial)

- [ ] A GTK app (e.g. the file dialog from a GTK program, or `gnome-text-editor` if present) renders **dark**.
      *(Ships the gtk portal + `color-scheme='prefer-dark'`. Full #51 — theme install + light/dark toggle — is NOT in scope here.)*

---

## Closing the issues

When the boxes above pass on a real VM:
- **#67** — close the epic (all 4 items validated).
- **#57** — close (its "verify screenshare end-to-end on a real VM build" task is §3).
- **#70** — close (§5).
- **#51** — leave OPEN; only partially addressed (no theme, no toggle).

If Option A (wlr) was the path (xdph didn't build), the epic/#57 still pass — the native
`hyprland-share-picker` is the only thing you don't get; screen sharing itself still works via wlr.
