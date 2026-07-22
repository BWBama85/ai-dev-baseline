# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is by git tag. Because
installs are symlinks, changes on `main` reach a user's clone on their next
`git pull` — keep `main` releasable.

## [Unreleased]

### Added

- **Hardened gate detection + a richer gate model** (`scripts/lib/project-gates.sh`,
  #5 · #19):
  - **Exact npm-script detection** — `_adb_pkg_has` now reads `package.json`'s `.scripts`
    with `jq` (falling back to a `"scripts"`-block-scoped heuristic only when `jq` is
    absent), so a *dependency* named `test` no longer produces a phantom `test` gate.
  - **Single-primary-ecosystem detection, made intentional** — the first ecosystem
    (Node → Rust → Go → Python) that yields a command wins, fixing the case where a
    `package.json` with no installed package manager silently suppressed Python detection.
  - **Gates are an open set** — any extra key in `agents.toml [gates]` (e.g. `build`,
    `guards`) is a first-class gate that runs and blocks like the built-in four.
  - **Per-gate N/A** — `[gates.state] <label> = "na"` declares a gate Not-Applicable
    (reported, never a failure or a detection miss), distinct from `""` (disabled).
  - **Per-gate path scope** — `[gates.scope] <label> = "apps/**,packages/**"` runs a gate
    only when the change set (supplied by the Stop-hook `precommit-gate.sh`, now passing
    the branch's changed files) touches a matching path — so a repo expresses docs-only
    skipping without forking the gate script.
  - New `project-gates.sh status` command reports each gate's state (run / N/A / disabled);
    `detect` keeps its two-column `<label>\t<command>` contract. New shared primitive
    `adb_toml_keys`, and a literal-table fix to `adb_toml_get` so a dotted sub-table like
    `[gates.scope]` can't be matched via the `.` regex metacharacter. Behavior is covered
    by `scripts/check-gates.sh` (wired into CI + `selfcheck.sh`).

- **`baseline update` — keep the installed baseline current** (`bin/baseline`, #36):
  one idempotent entrypoint that fast-forwards the install-source clone and self-heals a
  moved installed path, replacing the remembered `git pull` (+ maybe re-`install.sh`)
  ritual. It fast-forwards **only** when the clone is clean, on its default branch, and
  merely behind `origin` — a dirty/detached/non-default/ahead/diverged clone is surfaced
  and left untouched — then re-runs the installer **only when a symlink stopped
  resolving**, preserving the installed agent set + hook preference, and loudly verifies
  every canonical link. `baseline update --check` reports currency (stable exit-code
  contract for a future `SessionStart` hook, #25) and changes nothing; it **refuses**
  (exit 4) when invoked from a clone other than the one the install points into, so a dev
  clone is never mistaken for the install-source. New primitive `adb_branch_sync_state`
  in `scripts/lib/common.sh`; end-to-end tested by `scripts/check-baseline.sh` (wired into
  CI + `selfcheck.sh`).
- **Post-merge currency sync for the working clone** (#17): `/implement-issue`'s preflight
  now **auto-syncs** to a clean, current default branch when it is *provably safe* —
  clean tree, and the current branch is an ancestor of `origin/<default>` or `gh` reports
  its PR merged (so squash/rebase merges count) — switching to the default, fast-forwarding,
  and deleting merged local branches whose upstream is gone (safe `-d`, protected names
  skipped). It never discards unmerged or uncommitted work: a dirty tree or a
  not-provably-merged branch still hard-errors as before. `/cleanup` now returns to a clean,
  current default **before** sweeping (so the just-merged branch is deletable), and
  `/resolve-pr-threads` restores the branch it started on (or the PR's base) on every exit
  instead of stranding the tree on the PR head.
- **Shared shell library — the ONE home** (`scripts/lib/common.sh`, #30): a single
  implementation of `adb_link` / `adb_unlink_if_ours` (backup-then-symlink and
  ownership-scoped unlink), `adb_default_branch`, `adb_toml_get` / `adb_toml_unquote`
  (used for both `[gates]` and `[roles]`), and `adb_version_ge`. The installer,
  uninstaller, both agent adapters, `agent-init`, and the runtime gates now **source**
  it instead of carrying four-plus copies. `scripts/lib/project-gates.sh` moved here to
  sit beside it (it installs to `~/.<agent>/scripts/lib`). Existing installs keep working
  across the move via a compatibility symlink (`agents/claude/scripts/lib` → `scripts/lib`),
  so a plain `git pull` never silently drops gate enforcement. Unit-tested by
  `scripts/check-common-lib.sh`.
- **CI-enforced no-drift for restated facts** (#30): `scripts/check-fact-drift.sh` pins
  the gate-axis list, cross-agent invocation commands, the codex ≥7-minute timeout, and
  the role-resolution order to their canonical source and fails when a consumer doc
  diverges. `scripts/check-practice-index.sh` keeps `base/practices/00-index.md` in sync
  with the practice files. Both run in CI **and** `selfcheck.sh`; the install dry-run now
  covers all three agents.
- **`docs/design-principles.md`** (#30): the tenets a contribution must satisfy
  (single-source/no-drift, general-over-specific, extensible, config-over-hardcode,
  graceful degradation) with the concrete CI check enforcing each; referenced from
  `CONTRIBUTING.md`. Includes the governance rule that new adapters/gates/hooks build on
  the shared primitives rather than copying logic.
- **`base/practices/handling-the-unknown.md`** (#32): a deterministic
  classify → place → record → escalate protocol for when a project hits something the
  baseline doesn't model, rendered into every agent root doc. Enumerates the prescribed
  home per category (gate → `[gates]`, role → `[roles]`, project rule → the repo's root
  doc, deviation → a `DEVIATION` record, general gap → a baseline issue) and defines the
  per-project decision-log format at `.ai-dev-baseline/decisions.md`. The
  `implement-issue`, `debug`, and `create-issue` workflows reference it.

### Added — initial framework

- **Agent-neutral practices** (`base/practices/`): shell hygiene, git/PR discipline,
  CI diagnose-before-rerun, out-of-scope → tracked issue, repo-scope verification,
  evidence-first debugging, mandatory self-review, logging/secrets.
- **Role model** (`base/roles.md`, `templates/agents.toml`): per-project `primary` /
  `gap_analysis` / `review` / `debug` assignment; swap `primary` with no workflow
  change. Resolution order repo → global default → built-in.
- **Claude agent** (fully wired): six skills — `implement-issue` (role-aware,
  auto-detecting gates, repo-scope + self-review baked in), `create-issue`,
  `resolve-pr-threads`, `new-release`, and the new `cleanup` (sweep all merged
  branches, named explicitly) and `debug` (evidence-first root cause). Two Stop-hook
  gates + statusline.
- **Gate auto-detection** (`scripts/lib/project-gates.sh`): pnpm/npm/yarn/bun, cargo,
  go, python; honors `agents.toml [gates]`; the global gate **defers to any repo that
  ships its own** so nothing double-runs.
- **Codex + Gemini adapters**: install the shared practices into `~/.codex/AGENTS.md`
  / `~/.gemini/GEMINI.md`; deeper workflow parity tracked in Issues.
- **Install contract**: `install.sh --agent …` (symlink + jq-merged Stop hooks,
  backed up, idempotent), `uninstall.sh`, `bin/agent-init`.
- **Tooling**: `scripts/build.sh` (render practices → root docs), `scripts/selfcheck.sh`
  (local CI mirror), CI (shellcheck · build-drift · frontmatter · gate-detector ·
  install dry-run), contributor guide (`CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md`).

### Fixed

- **`implement-issue` step 8 no longer prescribes an unusable reviewer** (#9): the
  Claude `review` slot now runs an in-process, model-invokable pass — `/simplify`
  (quality) plus a `general-purpose` Claude subagent for the adversarial bug review —
  instead of the user-only `/code-review` (`disable-model-invocation`), which the
  Skill tool rejects. `/code-review` is documented as an optional post-PR human step,
  and the failure-mode note now names the correct cause (user-only by design, not a
  version/toolchain problem).
- **Delegated steps must complete deterministically** (#10): `base/roles.md` and the
  `implement-issue` workflow now carry a **completion contract** — gap-analysis,
  review, and any cross-agent/subagent dispatch run as a single bounded call whose
  outcome is decided by the call *returning* (no output-polling to guess "hung"); on
  timeout/error they abandon → retry once → fall back → block/surface, and never
  finish on partial or empty output. Clarifies that "advisory" is the standing of a
  **completed** finding, not license to skip the step.

[Unreleased]: https://github.com/BWBama85/ai-dev-baseline/commits/main
