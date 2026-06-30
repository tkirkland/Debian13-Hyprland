# Offline-ISO `.deb` Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Debian13-Hyprland so every package — debootstrap closure debs AND the source-compiled hyprwm/swww/hypr-dim stack — is built into `.deb`s at **ISO-creation time**, gathered into one offline apt repo placed as a **separate data directory on a duplicate DVD ISO**, so the installer resolves 100% offline with no compiler, no git, and no network.

**Architecture:** Add a build-time pipeline that (1) populates the deb closure (reuse `cache_populate_debs`), (2) for each source component runs an upstream-vs-cached freshness check and, only when newer, compiles into a `DESTDIR` and packages a `.deb`, (3) indexes the pooled debs with `apt-ftparchive`, (4) lays the repo as a plain directory onto a copy of the stock Debian-live ISO via `xorriso`. The installer is reworked to consume that on-ISO directory as its only apt source and to stop compiling and stop copying the store onto the target.

**Tech Stack:** bash, debootstrap, apt-ftparchive, `dpkg-deb`, `dpkg --compare-versions`, cmake/meson/cargo (DESTDIR installs), xorriso. Tests use the repo's `tests/*.sh` harness (`tests/test-helpers.sh`).

**Locked decisions (from the user, 2026-06-25):**
- ISO inject = **separate data dir** on the ISO (NOT inside squashfs). debootstrap debs + compiled debs land in the **same** dir; the installer treats that dir as its apt source.
- hypr-dim = **compiled from source into a `.deb`** (uniform with the rest of the stack).
- Store is **ISO-only**: remove `embed_cache_in_target` + the permanent target `file://` apt source. The installed system keeps no offline-rebuild copy.
- Land on a **new feature branch cut from `develop`** (e.g. `feat/offline-iso-deb-store`).

**Scope note:** This is four subsystems. Phase 1 is fully detailed and unit-testable in this repo with no ISO host. Phases 2–4 are specified with concrete interfaces; **Phase 3 (ISO assembly) must not start until the build-host question in "Open Questions" is answered** — it needs a trixie/amd64 build environment that this plan cannot assume.

---

## Versioning convention (used throughout)

- Release tag `vX.Y.Z` or `X.Y.Z` → Debian version `X.Y.Z-1`.
- Untagged HEAD → `0.0.0+git<UTCDATE>.<shortsha>` (e.g. `0.0.0+git20260625.1a2b3c4`), monotonic across rebuilds.
- Comparisons always via `dpkg --compare-versions "$a" gt "$b"` — never string compare.

---

## File Structure

**New files**
- `scripts/lib-deb-package.sh` — build-time library: version helpers, freshness gate, compile→DESTDIR→`dpkg-deb` wrapper, per-package control metadata. Sourced by the ISO builder. **One responsibility:** turn a source component into a pooled `.deb`.
- `tools/build-iso.sh` — top-level ISO-build entry point, run on a networked trixie/amd64 build host. Orchestrates: deb-closure population → per-component freshness+build→deb → index → ISO assembly. **One responsibility:** produce the offline ISO.
- `tools/iso-assemble.sh` — copy the stock live ISO, drop `repo/` in as a data dir, re-`xorriso` preserving El-Torito/EFI. **One responsibility:** ISO in/out.
- `tests/deb-package.sh` — unit tests for `lib-deb-package.sh`.
- `tests/iso-assemble.sh` — unit tests for the ISO data-dir layout logic (mockable parts only).

**Modified files**
- `lib/00-config.sh` — add `ISO_REPO_DIR`, per-package `Depends` metadata map, build-host paths; retire `TARGET_CACHE_DIR` usage.
- `scripts/60-hyprland.sh` — factor each build body to accept a `DESTDIR`/prefix so it is reusable from build time; keep `resolve_*`/`check_compat`.
- `scripts/10-cache.sh` — reuse `cache_populate_debs`/`cache_index_repo` at build time; drop source-tarball staging from the offline contract; extend `cache_validate` to require the stack `.deb`s in `Packages`.
- `scripts/30-bootstrap.sh` — remove `embed_cache_in_target` + permanent target `file://` source; offline `run_debootstrap` and target apt point at `ISO_REPO_DIR`.
- `scripts/00-preflight.sh` — make offline (on-ISO repo) the primary install path.
- `tests/bootstrap-sources.sh`, `tests/cache-validate.sh` — update asserted paths/contract.

---

## Phase 0: Branch setup

### Task 0: Cut the feature branch

**Files:** none (git only)

- [ ] **Step 1: Stash or commit the current dirty tree.** The working tree has uncommitted changes on `feat/hyprdim-prebuilt` (`lib/00-config.sh`, `scripts/60-hyprland.sh`). Confirm with the user what to do with them first (they are out of scope for this plan). Assuming they are committed/stashed:

Run:
```bash
cd /home/me/src/Debian13-Hyprland
git fetch origin
git switch develop
git switch -c feat/offline-iso-deb-store
```
Expected: on a new branch off `develop`.

- [ ] **Step 2: Verify clean baseline tests pass.**

Run: `bash tests/run-all.sh`
Expected: PASS (record any pre-existing failures as baseline before changing anything).

---

## Phase 1: Deb-packaging foundation + freshness gate (`scripts/lib-deb-package.sh`)

Unit-testable here with no ISO host. Each helper is small and pure where possible.

### Task 1: Version helpers

**Files:**
- Create: `scripts/lib-deb-package.sh`
- Test: `tests/deb-package.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# tests/deb-package.sh — unit tests for scripts/lib-deb-package.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/test-helpers.sh"
source "${HERE}/../scripts/lib-deb-package.sh"

# tag_to_debver
assert_eq "0.49.0-1" "$(tag_to_debver v0.49.0)" "tag_to_debver strips v, adds -1"
assert_eq "1.2.3-1"  "$(tag_to_debver 1.2.3)"   "tag_to_debver bare version"

finish_test
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deb-package.sh`
Expected: FAIL — `tag_to_debver: command not found` (or source error: file missing).

- [ ] **Step 3: Write minimal implementation**

```bash
# shellcheck shell=bash
# Build-time only: turn a source component into a pooled .deb, gated by an
# upstream-vs-cached freshness check. Sourced by tools/build-iso.sh on a
# networked trixie/amd64 build host. NOT used at install time.

# Release tag (vX.Y.Z | X.Y.Z) -> Debian version X.Y.Z-1.
tag_to_debver() {
  local tag="${1#v}"
  printf '%s-1\n' "${tag}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/deb-package.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-deb-package.sh tests/deb-package.sh
git commit -m "feat(deb): tag_to_debver version helper"
```

### Task 2: Cached-version lookup from the pool

**Files:**
- Modify: `scripts/lib-deb-package.sh`
- Test: `tests/deb-package.sh`

- [ ] **Step 1: Write the failing test** (append before `finish_test`)

```bash
# cached_deb_version: highest version of <name>_*_amd64.deb in a pool, or empty.
tmp="$(mktemp -d)"
: >"${tmp}/swww_0.10.0-1_amd64.deb"
: >"${tmp}/swww_0.11.0-1_amd64.deb"
: >"${tmp}/hyprland_0.49.0-1_amd64.deb"
assert_eq "0.11.0-1" "$(cached_deb_version "${tmp}" swww)" "cached_deb_version picks highest"
assert_eq ""         "$(cached_deb_version "${tmp}" nope)" "cached_deb_version empty when absent"
rm -rf "${tmp}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deb-package.sh`
Expected: FAIL — `cached_deb_version: command not found`.

- [ ] **Step 3: Write minimal implementation** (append to `lib-deb-package.sh`)

```bash
# Highest Debian version of <name>_<ver>_<arch>.deb present in pool dir $1
# for package $2. Empty string if none. Uses dpkg --compare-versions so the
# ordering is correct (not lexical).
cached_deb_version() {
  local pool="$1" name="$2" best="" ver=""
  local f base
  for f in "${pool}/${name}"_*.deb; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    # strip "<name>_" prefix and "_<arch>.deb" suffix
    ver="${base#"${name}"_}"
    ver="${ver%_*.deb}"
    if [[ -z "${best}" ]] || dpkg --compare-versions "${ver}" gt "${best}"; then
      best="${ver}"
    fi
  done
  printf '%s\n' "${best}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/deb-package.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-deb-package.sh tests/deb-package.sh
git commit -m "feat(deb): cached_deb_version pool lookup"
```

### Task 3: Freshness gate

**Files:**
- Modify: `scripts/lib-deb-package.sh`
- Test: `tests/deb-package.sh`

- [ ] **Step 1: Write the failing test** (append)

```bash
# deb_needs_rebuild POOL NAME UPSTREAM_DEBVER -> exit 0 if rebuild needed.
tmp="$(mktemp -d)"
: >"${tmp}/swww_0.11.0-1_amd64.deb"
assert_fails "no rebuild when upstream == cached" deb_needs_rebuild "${tmp}" swww 0.11.0-1
deb_needs_rebuild "${tmp}" swww 0.12.0-1 && echo "  ok: rebuild when upstream newer" \
  || { echo "  FAIL: should rebuild when newer" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
deb_needs_rebuild "${tmp}" newpkg 1.0.0-1 && echo "  ok: rebuild when absent" \
  || { echo "  FAIL: should rebuild when absent" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
rm -rf "${tmp}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deb-package.sh`
Expected: FAIL — `deb_needs_rebuild: command not found`.

- [ ] **Step 3: Write minimal implementation** (append)

```bash
# Exit 0 (rebuild) when no cached .deb exists or upstream ($3) is strictly
# greater than the cached version; exit 1 (reuse cached) otherwise.
deb_needs_rebuild() {
  local pool="$1" name="$2" upstream="$3" cached
  cached="$(cached_deb_version "${pool}" "${name}")"
  [[ -n "${cached}" ]] || return 0
  dpkg --compare-versions "${upstream}" gt "${cached}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/deb-package.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-deb-package.sh tests/deb-package.sh
git commit -m "feat(deb): deb_needs_rebuild freshness gate"
```

### Task 4: Control-file generation

**Files:**
- Modify: `scripts/lib-deb-package.sh`
- Test: `tests/deb-package.sh`

- [ ] **Step 1: Write the failing test** (append)

```bash
# write_control DESTDIR NAME VERSION ARCH DEPENDS
tmp="$(mktemp -d)"
write_control "${tmp}" swww 0.11.0-1 amd64 "libc6, libwayland-client0"
ctrl="$(cat "${tmp}/DEBIAN/control")"
assert_contains "${ctrl}" "Package: swww" "control has Package"
assert_contains "${ctrl}" "Version: 0.11.0-1" "control has Version"
assert_contains "${ctrl}" "Architecture: amd64" "control has Architecture"
assert_contains "${ctrl}" "Depends: libc6, libwayland-client0" "control has Depends"
rm -rf "${tmp}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deb-package.sh`
Expected: FAIL — `write_control: command not found`.

- [ ] **Step 3: Write minimal implementation** (append)

```bash
# Write a minimal DEBIAN/control under DESTDIR ($1). Depends ($5) may be empty.
write_control() {
  local destdir="$1" name="$2" version="$3" arch="$4" depends="$5"
  mkdir -p "${destdir}/DEBIAN"
  {
    printf 'Package: %s\n' "${name}"
    printf 'Version: %s\n' "${version}"
    printf 'Architecture: %s\n' "${arch}"
    printf 'Maintainer: Debian13-Hyprland build <build@localhost>\n'
    [[ -n "${depends}" ]] && printf 'Depends: %s\n' "${depends}"
    printf 'Section: x11\n'
    printf 'Priority: optional\n'
    printf 'Description: %s (built from source by the offline-ISO pipeline)\n' "${name}"
  } >"${destdir}/DEBIAN/control"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/deb-package.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-deb-package.sh tests/deb-package.sh
git commit -m "feat(deb): write_control minimal control file"
```

### Task 5: `package_to_deb` — build the .deb from a staged DESTDIR

**Files:**
- Modify: `scripts/lib-deb-package.sh`
- Test: `tests/deb-package.sh`

- [ ] **Step 1: Write the failing test** (append). Guarded so it skips where `dpkg-deb` is absent.

```bash
if command -v dpkg-deb >/dev/null; then
  tmp="$(mktemp -d)"; pool="${tmp}/pool"; dest="${tmp}/stage"; mkdir -p "${pool}" "${dest}/usr/local/bin"
  printf '#!/bin/sh\n' >"${dest}/usr/local/bin/swww"; chmod +x "${dest}/usr/local/bin/swww"
  out="$(package_to_deb "${dest}" swww 0.11.0-1 amd64 "libc6" "${pool}")"
  assert_eq "${pool}/swww_0.11.0-1_amd64.deb" "${out}" "package_to_deb returns deb path"
  [[ -f "${pool}/swww_0.11.0-1_amd64.deb" ]] && echo "  ok: deb created" \
    || { echo "  FAIL: deb not created" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
  assert_eq "swww" "$(dpkg-deb -f "${pool}/swww_0.11.0-1_amd64.deb" Package)" "deb Package field"
  rm -rf "${tmp}"
else
  echo "  skip: dpkg-deb not installed"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deb-package.sh`
Expected: FAIL — `package_to_deb: command not found`.

- [ ] **Step 3: Write minimal implementation** (append)

```bash
# Stage a control file into DESTDIR and build pool/<name>_<ver>_<arch>.deb.
# Echoes the resulting .deb path. DESTDIR must already contain the installed
# tree (e.g. usr/local/bin/...).
package_to_deb() {
  local destdir="$1" name="$2" version="$3" arch="$4" depends="$5" pool="$6"
  write_control "${destdir}" "${name}" "${version}" "${arch}" "${depends}"
  mkdir -p "${pool}"
  local out="${pool}/${name}_${version}_${arch}.deb"
  dpkg-deb --root-owner-group --build "${destdir}" "${out}" >/dev/null
  printf '%s\n' "${out}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/deb-package.sh`
Expected: PASS (or "skip" line if dpkg-deb missing — install `dpkg-dev` on the build host).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib-deb-package.sh tests/deb-package.sh
git commit -m "feat(deb): package_to_deb builds pooled .deb from DESTDIR"
```

### Task 6: Per-package Depends metadata map

**Files:**
- Modify: `lib/00-config.sh`
- Test: `tests/config.sh` (existing config test file — add a case)

- [ ] **Step 1: Write the failing test** — add to `tests/config.sh` after it sources config:

```bash
assert_eq "amd64" "${ARCH}" "ARCH is amd64"
[[ -n "${HYPR_DEB_DEPENDS[swww]+x}" ]] && echo "  ok: swww Depends declared" \
  || { echo "  FAIL: HYPR_DEB_DEPENDS[swww] missing" >&2; TEST_FAILURES=$((TEST_FAILURES+1)); }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/config.sh`
Expected: FAIL — `HYPR_DEB_DEPENDS[swww] missing`.

- [ ] **Step 3: Write minimal implementation** — add to `lib/00-config.sh` near `HYPR_REPO_URL`:

```bash
# Runtime Depends per source-built package, used to generate .deb control
# files at ISO-build time. Keep conservative: list runtime libs that live in
# the closure pool so `apt-get install --simulate` resolves fully offline.
# Entries with empty value rely purely on shlibs the package links (filled in
# during Task 11 dependency-completeness verification).
declare -gA HYPR_DEB_DEPENDS=(
  [swww]="libc6, libwayland-client0, libgcc-s1"
  [hypr-dim]="libc6, libgcc-s1"
  # remaining components populated in Phase 2 Task 11 from `apt-get install
  # --simulate` against the file:// repo; start empty and tighten.
)
ISO_REPO_DIR="/run/hypr-iso/repo"   # mount path of the on-ISO repo at install
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/config.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/00-config.sh tests/config.sh
git commit -m "feat(config): HYPR_DEB_DEPENDS map and ISO_REPO_DIR"
```

---

## Phase 2: Build-time compile→deb path (`scripts/60-hyprland.sh` refactor)

**Verification:** the DESTDIR build itself needs the toolchain + a trixie chroot, so full verification is integration-level on the build host (Phase 3). The refactor below keeps the existing install-time path working and adds a `*_to_destdir` seam; unit-test the seam selection logic, integration-test the actual compile on the build host.

### Task 7: Add a DESTDIR seam to `build_one`

**Files:**
- Modify: `scripts/60-hyprland.sh` (`build_one`, lines ~243–273)

- [ ] **Step 1:** Introduce `HYPR_DESTDIR` (default empty = current `/usr/local` behavior). When set, cmake/meson install with `DESTDIR="${HYPR_DESTDIR}"` and prefix `/usr` (so the deb lays files under `/usr`, not `/usr/local`); cargo/custom builds `install` into `${HYPR_DESTDIR}/usr/bin`. Exact edit: wrap the install commands so the install root is `${HYPR_DESTDIR:-}` and prefix is `/usr` when packaging, `/usr/local` otherwise. (Full edited function written during execution — keep both code paths; do not delete the install-time path.)

- [ ] **Step 2:** Add `build_component_to_deb name` in `scripts/lib-deb-package.sh` that: resolves the upstream debver via `tag_to_debver "$(resolve_latest_release_tag ...)"`; calls `deb_needs_rebuild "${POOL}" "${name}" "${ver}"` and returns early (log "reuse cached") when not needed; else stages source, sets `HYPR_DESTDIR="$(mktemp -d)"`, runs `build_one "${name}"`, then `package_to_deb "${HYPR_DESTDIR}" "${name}" "${ver}" "${ARCH}" "${HYPR_DEB_DEPENDS[${name}]:-}" "${POOL}"`.

- [ ] **Step 3:** Unit test (in `tests/deb-package.sh`) the *gate* path with `build_one` stubbed via `make_fake`/function override: assert that when a cached deb of equal version exists, `build_component_to_deb` does NOT invoke the build stub (reuse), and DOES when version is higher. (Compile body itself verified on the build host.)

- [ ] **Step 4:** Run: `bash tests/deb-package.sh` → PASS.

- [ ] **Step 5:** Commit: `feat(deb): build_component_to_deb with freshness short-circuit`.

### Task 8: hypr-dim source→deb (uniform with stack)

**Files:**
- Modify: `lib/00-config.sh` (ensure `hypr-dim` is in `HYPR_BUILD_ORDER` + `HYPR_REPO_URL[hypr-dim]=https://github.com/tkirkland/hypr-dim`), `scripts/60-hyprland.sh` (`build_custom_hypr_dim` writes into `${HYPR_DESTDIR}/usr/bin`).

- [ ] **Step 1:** Re-add `hypr-dim` to the source-built stack (it was dropped on `feat/hyprdim-prebuilt`); remove the prebuilt `install_hypr_dim` download path from `40-system.sh`. Build via cargo into `${HYPR_DESTDIR}`.
- [ ] **Step 2–4:** Covered by Task 7's gate test (hypr-dim freshness uses git tags via `resolve_latest_release_tag`); compile verified on build host.
- [ ] **Step 5:** Commit: `feat(deb): hypr-dim built from source into a .deb`.

### Task 9: ZFS debs into the pool

**Files:**
- Modify: `scripts/40-system.sh` (`install_zfs_from_source`, line ~157)

- [ ] **Step 1:** At build time, run its existing `make native-deb-utils`, then copy the filtered `.deb`s into `${POOL}` instead of in-target `apt-get install`. (It already produces debs — this is a placement change.)
- [ ] **Step 5:** Commit: `feat(deb): stage openzfs .debs into the offline pool`.

---

## Phase 3: ISO-build orchestrator + data-dir injection

**BLOCKED until the build-host question is answered (see Open Questions).** Needs a networked trixie/amd64 environment with debootstrap, dpkg-dev, xorriso, and the stock `debian-live-13-amd64.iso` available.

### Task 10: `tools/build-iso.sh` orchestrator

**Files:** Create `tools/build-iso.sh`.

- [ ] **Step 1:** Source `lib/00-config.sh`, `scripts/10-cache.sh`, `scripts/60-hyprland.sh`, `scripts/lib-deb-package.sh`. Set `CACHE_DIR` to a build workspace and `POOL="${CACHE_DIR}/repo/pool"`.
- [ ] **Step 2:** Run `cache_populate_debs` (closure) → for each `name` in `HYPR_BUILD_ORDER` call `build_component_to_deb "${name}"` → stage ZFS debs (Task 9) → `cache_index_repo`.
- [ ] **Step 3:** Call `tools/iso-assemble.sh "${STOCK_ISO}" "${CACHE_DIR}/repo" "${OUT_ISO}"`.
- [ ] **Step 5:** Commit: `feat(iso): build-iso orchestrator`.

### Task 11: Dependency-completeness verification (no silent gaps)

**Files:** part of `tools/build-iso.sh`.

- [ ] **Step 1:** After indexing, run `apt-get install --simulate -o Dir::Etc::sourcelist=<file://repo list> <all target packages + stack>` in a throwaway chroot; fail the build if anything is unresolved offline. Backfill `HYPR_DEB_DEPENDS` until clean. `log()` any package pulled from outside the pool.
- [ ] **Step 5:** Commit: `feat(iso): assert offline dependency closure before assembly`.

### Task 12: `tools/iso-assemble.sh` — data-dir injection

**Files:** Create `tools/iso-assemble.sh`; Test `tests/iso-assemble.sh` (layout-only assertions).

- [ ] **Step 1:** Extract the stock ISO (`xorriso -osirrox on -indev ... -extract / workdir`), copy `repo/` to `workdir/hypr-repo/`, repack with `xorriso -as mkisofs` preserving El-Torito BIOS + EFI boot images from the source ISO, output `OUT_ISO`.
- [ ] **Step 2:** Unit-test the path-layout helper (where `repo/` lands, that `dists/`+`pool/` are present) against a fake workdir — no real ISO needed.
- [ ] **Step 5:** Commit: `feat(iso): assemble offline ISO with repo as data dir`.

---

## Phase 4: Installer rework + tests/docs

### Task 13: Consume the on-ISO repo; stop embedding into target

**Files:** Modify `scripts/30-bootstrap.sh`, `scripts/00-preflight.sh`, `scripts/10-cache.sh`.

- [ ] **Step 1:** Remove `embed_cache_in_target()` and the call to it; remove `write_target_apt_sources()`'s permanent `file://${TARGET_CACHE_DIR}` stanza. Point offline `run_debootstrap` and the live/target apt source at `file://${ISO_REPO_DIR}`.
- [ ] **Step 2:** In `00-preflight.sh`, make the on-ISO repo the primary apt source (offline-first); network becomes optional augmentation, not required.
- [ ] **Step 3:** In `phase_hyprland`, replace `build_stack` with `apt-get install` of the now-packaged stack from `ISO_REPO_DIR`; drop `stage_firstboot` compile-on-target.
- [ ] **Step 3b (deferred /usr migration — Phase 2 moved compiled binaries to `/usr` but left these):** sweep remaining `/usr/local` references to *compiled* binaries and point them at `/usr`, keeping the hand-written glue scripts (`swww-cycle`, `drm-reprobe`, `brightness-sync`, `hyprland-welcome`, `hypr-session`) in `/usr/local`. Known item: `60-hyprland.sh:1130` `ExecStart=/usr/local/bin/hypr-dim` → `/usr/bin/hypr-dim` (binary moved in commit `b0ae471`; service currently misses it). Also re-check Hyprland keybinds / `.desktop Exec=` / sudoers for any compiled-binary `/usr/local` paths. Remove `purge_build_deps`' `/usr/local` ldd-scan along with the now-dead on-target compile path.
- [ ] **Step 4:** Update `tests/bootstrap-sources.sh` (asserted URI → `file://${ISO_REPO_DIR}`) and `tests/cache-validate.sh` (require stack `.deb`s in `Packages`, drop source-tarball requirement). Run both → PASS.
- [ ] **Step 5:** Commit: `feat(install): resolve from on-ISO repo; stop target embed and on-target compile`.

### Task 14: Docs

**Files:** Modify `README.md`, `STRUCTURE.md`, `AGENTS.md`; add `docs/superpowers/specs/2026-06-25-offline-iso-deb-store-design.md` (this design).

- [ ] **Step 1:** Document the two-stage model: build the ISO with `tools/build-iso.sh` (networked), then install fully offline from the DVD. Note the store is ISO-only.
- [ ] **Step 5:** Commit: `docs: offline-ISO build + install model`.

---

## Open Questions (resolve before the marked phases)

1. **Build host (blocks Phase 3).** Where does `tools/build-iso.sh` run? Options: (a) local trixie box, (b) GitHub Actions building inside a `debian:trixie` container, (c) a podman/chroot on the dev machine. The compiled `.deb`s must be ABI-correct for trixie/amd64, so the compile must happen in a trixie environment, not on an Ubuntu runner directly.
2. **Stock ISO source.** Confirm the exact `debian-live-13-amd64.iso` URL/path the assembler starts from, and whether it should be fetched by the build script or supplied.
3. **Signed vs trusted repo.** Plan keeps `[trusted=yes]`/unsigned `Release` (offline-acceptable). Sign + ship a key later? (Phase 4 nice-to-have, Task in backlog.)
4. **Toolchain runtime libs in the pool.** gcc-15 (sid) and cargo (backports) are build-only, but the compiled debs' runtime deps (e.g. `libgcc-s1`, `libstdc++6 >= 15`) must ship in the pool. Task 11 enforces this; confirm sid `libstdc++6` is acceptable on a trixie target or pin accordingly.

---

## Self-Review

- **Spec coverage:** build-at-ISO-time → Phase 2+3; same-dir for closure+compiled debs → Tasks 10/12 (`POOL` shared, indexed together); separate data dir on ISO → Task 12; installer treats dir as source → Task 13; hypr-dim source→deb → Task 8; ISO-only store → Task 13; freshness compile-only-if-newer → Tasks 3/7; new branch → Task 0. Covered.
- **Placeholder scan:** Phase 1 steps carry full code. Phases 2–4 steps that defer exact code (edited `build_one`, ISO xorriso flags) are framed as integration tasks gated on the build host, with concrete commands/interfaces named — not vague "handle X". Acceptable given they cannot be unit-verified in this repo.
- **Type consistency:** `cached_deb_version`/`deb_needs_rebuild`/`package_to_deb`/`write_control`/`build_component_to_deb`/`tag_to_debver`/`HYPR_DEB_DEPENDS`/`ISO_REPO_DIR`/`POOL`/`HYPR_DESTDIR` used consistently across tasks.
