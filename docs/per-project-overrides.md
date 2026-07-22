# Per-project overrides

The global install (see [installation.md](installation.md)) gives every
project the same floor: practices, skills, and Stop-hook gates. A project
layers its own needs **on top** of that floor without forking or editing the
baseline itself. This doc covers the three override surfaces and the
precedence between them.

## Precedence

From `base/practices/00-index.md`, in order:

1. **Explicit instructions in the current task** win over everything.
2. **Project-specific rules** — the repo's own `CLAUDE.md` / `AGENTS.md` /
   `GEMINI.md`, and its `agents.toml` — override the baseline where they
   conflict. A project is free to be stricter, or to opt out of a rule
   entirely.
3. **The baseline** (`base/practices/*.md`, rendered into the global root
   doc) is the default everywhere else.

A project should only restate a baseline rule when it *changes* it. If the
repo's own doc is silent on a topic, the baseline applies as-is — there's no
need to copy baseline text into a project doc just to reaffirm it.

## Override 1: the repo's own root doc

Claude, Codex, and Gemini all read a project-local root doc first
(`CLAUDE.md`, `AGENTS.md`, `GEMINI.md` respectively) in addition to the
global one symlinked at the user level. A repo adds project-specific rules —
stack conventions, module boundaries, naming, a release-goal/milestone
system, whatever's unique to that codebase — in its own copy, and those rules
sit **alongside**, not instead of, the global baseline.

Example: a project might ship a `CLAUDE.md` full of codebase-specific
conventions (ORM/schema rules, ID formats, a milestone/release-goal system, a
cost-safety policy for a particular cloud) that have nothing to do with — and
never restate — the baseline's shell-portability or CI-discipline rules. Both
apply at once: the project doc adds, the baseline remains in force underneath.

## Override 2: a project-scoped skill with the same name

Claude Code resolves a project-scoped skill (one living in the repo's own
`.claude/skills/<name>/`) ahead of a same-named skill installed globally at
`~/.claude/skills/<name>/` — "most specific wins." This isn't something
`ai-dev-baseline`'s scripts implement; it's the underlying Claude Code
harness behavior that the global-install design deliberately relies on: a
project that needs `/debug` or `/implement-issue` to behave differently for
its own stack can drop its own `.claude/skills/debug/SKILL.md` (or
`implement-issue`, `cleanup`, …) and it silently shadows the global one for
that repo only — no edit to the global copy, no fork.

Use this when a project's workflow genuinely diverges (e.g. a different
branch-naming scheme, an extra required step before a PR can open) rather
than when the baseline skill would already do the right thing — the point of
the global skill existing is that most projects *don't* need to override it.

## Override 3: quality gates

Two independent ways to override how quality gates run for a repo, and they
compose:

### 3a. `agents.toml [gates]`

`scripts/lib/project-gates.sh` auto-detects gates for the
common ecosystems (Node via `package.json` + lockfile → `pnpm`/`npm`/`yarn`/
`bun`; Rust via `Cargo.toml`; Go via `go.mod`; Python via `pyproject.toml`/
`setup.py`/`setup.cfg`/`requirements.txt`). A project's `agents.toml` can
override any of the four labels — `typecheck`, `lint`, `test`, `format` —
individually:

```toml
[gates]
typecheck = "pnpm typecheck"     # overrides an auto-detected command
lint      = ""                   # explicit empty string disables this gate
# test and format left unset → auto-detection still applies to them
```

An unset key falls through to auto-detection; an explicit empty string
(`""`) disables that gate outright, even if auto-detection would otherwise
have found a command for it. This is also how a repo adds a gate detection
missed entirely — e.g. a Makefile-based project with no recognized
ecosystem can set all four keys explicitly and get full gate coverage
`project-gates.sh` would never have found on its own.

### 3b. Shipping the repo's own gate script

Both Stop-hook gates check, before doing anything else, whether the repo
ships its **own** copy of that exact script at
`.claude/scripts/precommit-gate.sh` or
`.claude/scripts/implement-issue-gate.sh`. If that file exists and is not
literally the same file as the one currently running (compared with the
`-ef` test, i.e. same inode — this is what lets the *global* copy detect that
it's running as itself vs. as a project's copy without an infinite-defer
loop), the global gate exits `0` immediately and the project's version runs
instead:

```bash
# precommit-gate.sh, abbreviated
proj_gate="$repo_root/.claude/scripts/precommit-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  exit 0
fi
```

This is the escape hatch for a project whose gating needs are too custom for
`agents.toml [gates]` alone — e.g. gates that must run in a specific order,
gates gated on which files changed, or a project that wants a completely
different Stop-hook policy. Ship a full replacement script at that exact path
and the global one steps aside entirely; nothing double-runs.

Use `[gates]` when the commands are simply different; ship a repo-local gate
script when the *policy* (not just the commands) needs to differ.

## Concrete examples

**A pnpm monorepo where lint is intentionally not a merge gate:**

```toml
[gates]
lint = ""   # lint runs in CI as informational only, not a Stop-hook blocker
```

**A repo using a task runner instead of raw npm scripts:**

```toml
[gates]
typecheck = "just typecheck"
lint      = "just lint"
test      = "just test"
format    = "just fmt-check"
```

**A repo that needs to run a database migration check before its normal
gates, in an order `project-gates.sh` doesn't support:** ship
`.claude/scripts/precommit-gate.sh` in the repo that runs the migration
check and then re-uses (or reimplements) the standard gate list — the global
Stop hook detects it and steps aside.

**A repo whose `/implement-issue` needs an extra sign-off step before it's
considered "done":** drop a project-local
`.claude/skills/implement-issue/SKILL.md` that layers the extra step onto (or
replaces) the global playbook; Claude Code resolves the project-scoped
version for that repo.

## See also

- [installation.md](installation.md) — how the global baseline gets onto
  disk in the first place.
- [roles-and-agents.md](roles-and-agents.md) — `agents.toml [roles]`, the
  sibling table to `[gates]` in the same manifest.
- [philosophy.md](philosophy.md) — why the baseline is law by default and
  only yields to an explicit, deliberate override.
