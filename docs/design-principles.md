# Design principles

The tenets a contribution must satisfy to belong in `ai-dev-baseline`. They exist so
the framework keeps obeying its own thesis as it grows: **the tool that removes
duplication and drift from other projects must not accumulate them itself.** Each
principle below names the concrete mechanism in this repo that enforces it, so "did I
follow it?" has a checkable answer, not a vibe.

If you are adding an adapter, a gate detector, a renderer, or a hook, read
[the governance note](#governance-new-adapters--gates--hooks-build-on-the-primitives)
at the end first — it is the one that most often gets skipped.

## 1. Single-source + CI-enforced no-drift

**A fact, a rule, or a piece of logic lives in exactly one place; everything else
renders from it or references it; and CI fails when a copy drifts.** This is the whole
product thesis turned inward.

- **Practices** are authored once under `base/practices/*.md` and rendered into every
  agent's root doc by `scripts/build.sh`. Never hand-edit a generated root doc — the
  `build-drift` CI job fails on a stale, missing, untracked, or orphaned generated file.
- **Workflows** are authored once under `base/workflows/*.md` and rendered into the
  Claude skills the same way, drift-checked identically.
- **Shell logic** lives once in `scripts/lib/common.sh` — `adb_link` /
  `adb_unlink_if_ours` (backup-then-symlink and ownership-scoped unlink),
  `adb_default_branch`, `adb_toml_get` / `adb_toml_unquote`, `adb_version_ge`. The
  installer, uninstaller, both agent adapters, `agent-init`, and the runtime gates all
  **source** it. `scripts/check-common-lib.sh` unit-tests the primitives; a regression
  breaks one job, not eight silently-diverging copies.
- **Repeated prose facts** — the cross-agent invocation commands, the codex ≥7-minute
  timeout, the role-resolution order, the gate-axis list — are pinned by
  `scripts/check-fact-drift.sh`, an allowlisted lint that fails when a canonical token
  diverges across the docs that restate it.
- **The practice index** (`base/practices/00-index.md`) is kept honest by
  `scripts/check-practice-index.sh`: every practice is listed exactly once, no stale rows.

The test for a new duplication: *if this value changed, how many files would I have to
edit by hand, and what stops me forgetting one?* If the answer is "more than one" and
"nothing," you have found drift — give it a source and a check.

**Where a restatement is legitimate.** "One implementation" governs *executable* logic.
A skill's Markdown is loaded whole by the agent and cannot `source` a library, so a
workflow may restate a rule in prose (e.g. the default-branch snippet in `cleanup`) —
but that restatement is then subject to the fact-drift lint, not exempt from it. Prose
that an agent executes and code that a shell sources are different consumers of the same
single source; both trace back to it.

## 2. General over specific

**Prefer the mechanism that works for an unknown project over the one hardcoded to a
known one.** The baseline installs into projects it has never seen.

- `scripts/lib/project-gates.sh` *detects* gates for whole ecosystems (Node, Rust, Go,
  Python) rather than naming individual repos, and **emits nothing** on an ecosystem it
  doesn't recognize — a safe no-op, never a wrong guess.
- The practices are written in terms of what *an agent* should do, not what a particular
  agent does. Agent-specific wiring lives in `agents/<token>/`, never in `base/`.

## 3. Extensible / pluggable

**Adding a capability is adding a small, uniform unit — not editing a growing central
switch.** New practice? Drop a `base/practices/*.md`; `build.sh` picks it up from the
glob. New workflow? Drop a `base/workflows/*.md`. New agent? Add
`agents/<token>/adapter.sh` + one `render()` call + a `base/roles.md` row (see
[adding-an-agent.md](adding-an-agent.md)). The role-resolution logic reads whatever
token is configured; it does not enumerate a fixed list of agents.

## 4. Config over hardcode (with a universal escape hatch)

**A project's specifics belong in a declared config surface with a known schema, not
scattered through code or forked into the baseline.**

- Who does what is `agents.toml [roles]`; how gates run is `agents.toml [gates]`; both
  read through the one `adb_toml_get`.
- Every override surface has an **escape hatch** so a project is never stuck: a repo can
  set an explicit gate command (or `""` to disable), ship its own
  `.claude/scripts/precommit-gate.sh` that the global gate defers to, or shadow a global
  skill with a project-scoped one (see [per-project-overrides.md](per-project-overrides.md)).

Handling a project-specific unknown deterministically — which config surface it lands in,
and how the decision is recorded — is its own practice:
[`base/practices/handling-the-unknown.md`](../base/practices/handling-the-unknown.md).

## 5. Graceful degradation — but a missing *required* dependency fails loud

**A missing OPTIONAL dependency degrades to a safe no-op; it never crashes or corrupts.
A missing REQUIRED dependency — one the mechanism cannot function without — FAILS LOUD,
never silently no-ops.** The distinction is the difference between "this repo has nothing
for me to do" (degrade) and "my own install is broken" (fail loud). Conflating them is how
enforcement gets secretly turned off.

- The gate detector emits nothing (exit 0) on an unfamiliar repo — a legitimate no-op. The
  Stop-hook gates no-op when not in a git repo, on the default branch, or with no changes.
  `selfcheck.sh` SKIPs shellcheck when it isn't installed. `install.sh` warns and continues
  if `jq` is absent instead of dying. These are missing *optional* inputs.
- But a gate whose OWN shared library (`common.sh` / `project-gates.sh`) is missing is a
  broken install, not an unfamiliar repo — so `precommit-gate.sh` **fails loud (exit 2,
  blocking)** rather than exit 0, because a silent no-op there is enforcement secretly OFF,
  which is worse than a hard error (issue #35). `project-gates.sh` likewise fails loud when
  it can't load `common.sh`, instead of emitting an empty (no-gates) result. "No gates
  detected" and "the gate library is gone" must never look the same to a caller.
- A sourced library must not mutate its caller: `common.sh` sets no shell options and
  depends on no caller globals — every input is a function argument.

## 6. Never relocate an installed path without a self-healing migration

**Installs are symlinks into this clone, so a path the installer links to is a public API.
Moving one dangles every existing install's symlink until a re-install — and a plain
`git pull` does not re-install.** So: **either keep installed paths stable and reorganize
*behind* them, or move a path only with a self-healing, `git pull`-only migration** — leave
a compatibility symlink at the OLD path pointing to the new one, so a pull alone keeps a
stale install working (`baseline update` then self-heals it to the canonical link on its
next run, loudly verifying every link resolves).

- The concrete precedent: PR #34 moved `project-gates.sh` from `agents/claude/scripts/lib/`
  to `scripts/lib/`. The compat symlink `agents/claude/scripts/lib → ../../../scripts/lib`
  is what keeps pre-move installs working on a bare `git pull`; **deleting it would silently
  break them**, so it is load-bearing, not cruft.
- **The check:** `scripts/check-install-migration.sh` (run by `selfcheck.sh` and CI)
  installs the merge-base revision into a throwaway `HOME`, checks the same clone out to
  `HEAD` (simulating a pull with no re-install), and fails if any installed symlink no
  longer resolves — plus an explicit assertion that the historical compat shims still exist.
  A PR that moves an installed path without a shim fails this gate.
- **Reflexivity footgun:** developing the framework *from the clone that is your live
  install* means merging such a move mutates your own running environment mid-session. Use
  the two-clone topology (a separate dev clone) — see
  [installation.md](installation.md#the-two-clone-topology) and `CONTRIBUTING.md`.

## Governance: new adapters / gates / hooks build on the primitives

The framework's growth is where drift multiplies fastest — every new adapter, detector,
renderer, or hook is a chance to copy logic instead of sourcing it. So the standing rule
for the adapter/gate/hook work (issues #5, #12, #13, #14, #19, #25 and their kin):

> **Build on the shared primitives; do not copy logic.** A new adapter sources
> `scripts/lib/common.sh` for symlink/backup/unlink (it never re-implements `link()`).
> A new gate detector or richer gate schema reuses `adb_toml_get` for config reads. A new
> renderer plugs into `scripts/build.sh` and reads the same `base/` sources. If you find
> yourself pasting a function that already exists, stop and source it instead — and if the
> primitive doesn't quite fit, generalize the primitive rather than forking a copy.

Reviewers should treat copied logic in these areas as a blocking finding, not a nit.

## See also

- [philosophy.md](philosophy.md) — *why* the baseline is agent-neutral and law-by-default.
- [adding-an-agent.md](adding-an-agent.md) — the extensibility contract in practice.
- [per-project-overrides.md](per-project-overrides.md) — the config surfaces and escape hatches.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — the dev loop that runs these checks.
