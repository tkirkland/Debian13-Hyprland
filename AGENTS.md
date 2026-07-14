# Agent / Contributor Guide

Rules for editing this repository — written for AI agents and humans alike.
`STRUCTURE.md` explains *where* things live; this file explains *how* to
change them safely.

## Hard gates (non-negotiable)

Run both before every commit; both must pass clean:

```bash
bash tools/check.sh      # bash -n + shellcheck over every shell file
bash tests/run-all.sh    # the full fake-driven test suite
```

- shellcheck findings are fixed in code, not suppressed. A `# shellcheck
  disable=` directive is allowed only with an inline justification comment
  (see existing usages for the accepted patterns: SC2034/SC2154 for
  cross-module globals, SC2016 for intentionally-literal fake bodies or
  strings that must expand inside the chroot).
- Google Shell Style: two-space indent, `local` for every function
  variable, `[[ ]]`, quote all expansions, lowercase_underscore names.

## Architecture invariants

- **Offline completeness (non-negotiable).** Network is IRRELEVANT to install
  success. ANYTHING the installer puts into the target OS MUST be bundled on the
  ISO at build time (harvested into the offline store/pool by `tools/build-iso.sh`,
  the same way the `.debs` are) and installed from that LOCAL copy. The offline
  default must install everything; an `--online` path may exist ONLY as an
  optional accelerator — never gate, skip, or fail an installed artifact on
  connectivity. When you find a runtime fetch (`curl`/`git clone`/online apt/a
  GitHub release) or a `((NETWORK_AVAILABLE))` skip around something installed,
  the fix is: harvest it at build time + consume locally (never add a network
  branch). Settled offenders now bundled: chezmoi `.deb`, LythMono fonts,
  upstream OpenZFS debs, the `assets/wallpapers` submodule.
- `installer.sh` is a thin orchestrator. All real work lives in `lib/`
  (shared helpers) and `scripts/` (one module per phase). Modules are
  **sourced, never executed**: they start with `# shellcheck shell=bash`,
  contain only functions, and have no shebang.
- Cross-module globals are defined exactly once, in `lib/00-config.sh`,
  env-overridable (`VAR="${VAR:-default}"`). Never introduce a global in a
  phase module.
- Phase functions (`phase_*`) run under the orchestrator's `set -e` and
  are NEVER called from a condition context (`if`, `||`, `&&`) — that
  would suppress errexit inside the entire phase. Inside modules:
  `|| fatal "..."` for must-succeed steps, `|| true` ONLY for best-effort
  teardown. Never rely on errexit inside command substitutions; capture
  with an explicit `|| fatal` and empty-check instead.
- `in_target` takes exactly ONE string argument (it chroots into the
  target). Anything interpolated into that string from config must be
  validated (see `validate_identity_settings`) — these run as root.
- Associative-array keys are quoted (`["hyprland-protocols"]=`): an IDE
  formatter once mangled unquoted hyphenated keys into invalid subscripts.
- Heredocs: quote the delimiter (`<<'EOF'`) unless interpolation is
  intended; for generated files that need both, write them from the parent
  side (see `lua.pc` generation in `scripts/60-hyprland.sh`).

## Console output (quiet mode)

`setup_logging` (the default) routes the command stream to the install log
and keeps the operator console on fds 3/4; `--verbose` streams everything via
`tee`. Choose the output verb by intent (`lib/01-log.sh`):

- **Status** → `info` / `warn` / `verbose` / `fatal` — the established levels;
  always logged, shown on the console when no activity spinner is running.
- **Must-see text** the operator needs even in quiet mode → `console`.
- **Interactive prompt** → `prompt` (reads the reply into `$REPLY`).
- **Interactive child** (e.g. `passwd`, `mokutil`) → `with_console`; its output
  is deliberately NOT copied to the log (secrets).
- **Phase boundaries** → `activity_start` / `activity_success` (the spinner).

Bare `echo` / `printf` are for **data only**: a function's stdout return, a
redirect to a file, or a pipe — never operator-facing chatter. The lone
exception is code running where these helpers are undefined: inside
`in_target` command strings (the chroot), generated standalone scripts (the
firstboot runner), and `installer.sh` before `lib/01-log.sh` is sourced —
there, plain `echo ... >&2` is correct.

## Hard-won facts (do not relearn these the expensive way)

- GitHub tag tarballs omit submodules — sources are fetched as
  `git clone --recurse-submodules` (Hyprland vendors udis86 that way).
- "Latest release tag" needs per-repo care: xkbcommon tags
  `xkbcommon-X.Y.Z`, wayland-protocols tags `X.YY`, OpenZFS tags include
  dev-cycle markers (`zfs-X.Y.99`) that outrank real releases — zfs and
  ZFSBootMenu therefore resolve through the GitHub API, not tag sorting.
- Upstream OpenZFS deb recipes mask `dpkg-buildpackage` failures (make
  exits 0 anyway) — required artifacts are asserted by name after
  building. Only `native-deb-utils` is built; the kmod target compiles for
  the RUNNING kernel and drags that kernel image into the target.
- `pam_zfs_key` (shipped by upstream OpenZFS) breaks `chpasswd` on systems
  without encrypted homes; it is excluded and purged.
- The chroot has a `policy-rc.d` guard (exit 101) so maintainer scripts
  cannot start daemons that would hold mounts at teardown. It is removed
  by `phase_cleanup` only.
- greetd spawns its greeter with NO PATH (PAM env only): every command in
  `/etc/greetd/config.toml` must use absolute paths. Debian's greetd
  package ships no greeter binary; tuigreet is installed separately.
- Resume state (`/run/hypr-deb/state`) does not survive live-session
  reboots; anything resume-critical must key off reality (is the pool
  importable?) rather than stamps — see `ensure_target_ready`.

## Testing pattern

Tests are standalone bash scripts in `tests/`, run from the repo root,
using `tests/test-helpers.sh` (`assert_eq`, `assert_contains`,
`assert_fails`, `make_fake`). Dangerous logic (partitioning, disk
selection, tag resolution) is tested by putting fake commands on PATH and
asserting the exact command lines the module would execute. New behavior
gets a test in the same commit; regressions found in VM testing get a
pinning test with the fix.

## Commits

Conventional Commits, lowercase after the prefix:
`feat:` / `fix:` / `test:` / `docs:` / `chore:` / `refactor:`.
One concern per commit, and commits grouped by **fix type**: all work on one
topic (e.g. "the audio card") lives on one short-lived branch
(`feat/...` / `fix/...` / etc.) cut from `develop` — as many commits as the
topic needs, never a second topic. Never commit directly to `develop` (loose
commits there are untrackable) and never to `master` (protected: PR-only).
History on GitHub is append-only — no rewrites.

## Pull requests

Two long-lived branches: `develop` (where fix-group PRs land) and `master`
(the reviewed line), plus one short-lived branch per fix group. The loop:

1. Work is committed to a per-fix-group branch, pushed, and the agent opens
   a PR into `develop`. The user reviews; on his explicit go-ahead the agent
   merges it with a **merge commit** (squash/rebase are disabled repo-wide).
   One PR = one fix type, so each fix stays trackable as a unit. Once
   merged into `develop`, the fix-group branch is **deleted** (local and
   remote) — the merge commit is the record; never push a branch after its
   merge.
2. For a release, the agent opens a PR `develop` → `master`.
3. The user reviews and gives the verdict in-session:
   - **Approved** ("gtg" / "all good" / similar) — the agent merges with a
     **merge commit** (never squash/rebase: only the merge-commit method
     leaves `master` a fast-forward of `develop`).
   - **Changes requested** — the agent pushes fixes to `develop` for
     re-review.
4. The push to `master` triggers `sync-develop.yml`, which fast-forwards
   `develop` back up to `master` — the two re-sync automatically after
   every merge. Squash/rebase are disabled repo-wide and `master` is
   PR-protected precisely so that fast-forward always succeeds.

The agent merges only on the user's explicit in-session go-ahead — it does
not self-approve, enable auto-merge, or merge on its own initiative — and
never commits straight to `master`.
