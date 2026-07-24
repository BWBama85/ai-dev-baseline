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
project's `.claude/skills/<name>/SKILL.md` silently shadows the global one for
that repo only — no edit to the global copy.

There are **two ways** to produce that project-scoped skill, and the second is
almost always the right one:

### 2a. Full shadow fork (whole-file replacement)

Drop a complete `.claude/skills/<name>/SKILL.md`. It replaces the global skill
outright for this repo. Use this only when a project's workflow genuinely
diverges *wholesale* — a fundamentally different procedure, not a couple of
extra lines.

The cost is real: **a forked skill is a skill frozen in time.** It stops
inheriting every later baseline improvement to *every* step, even the 90% the
fork never meant to change. A fork that carried ~25 novel lines on top of a
500-line skill silently falls behind on the other 475.

### 2b. Partial compose-override (carry only your deltas) — preferred

Carry *only* your deltas in a tiny `.claude/skills/<name>/overrides.md`, and
let `skill-compose` **merge them onto the current installed baseline skill**.
Every step you don't touch keeps inheriting upstream. This is the fix for the
"frozen fork" problem (issue #22).

The model mirrors `scripts/build.sh`: the installed base skill is the source,
your `overrides.md` is the delta, and the composed
`.claude/skills/<name>/SKILL.md` is a **generated artifact** (it carries an
`# adb:composed-skill` ownership marker). After the baseline updates, you
recompose and your deltas re-merge onto the *new* base.

**Anchors.** An override targets a step by its **anchor** — the base skill's
`### ` step heading, slugified with the leading `N.` step number stripped
(lowercased, each run of non-alphanumerics collapsed to `-`). Stripping the
number means *renumbering* a step doesn't break your override; *renaming* the
heading does — and it fails loud on the next recompose (see below), which is
exactly the signal that your fork has diverged from its source. Discover the
valid anchors with:

```bash
baseline skill-compose list-anchors implement-issue
```

**Overrides file.** `.claude/skills/<name>/overrides.md` is a set of
HTML-comment directive blocks:

```markdown
<!-- adb:override anchor="implement" op="append" -->
- [ ] Docs-zone sign-off: every changed doc zone re-read and initialed.
<!-- adb:end -->

<!-- adb:override anchor="file-issues-for-all-deferred-out-of-scope-work-mandatory" op="replace" -->
### 12. File issues (this project's milestone placement)

Default a discovery to `Backlog` so the frozen release set converges; only a
genuine dependency of the current release goal goes into `Next release`.
Never leave a new issue milestone-less.
<!-- adb:end -->
```

`op` ∈ `append` (insert at the end of the step) · `prepend` (right after the
heading) · `replace` (swap the step body, heading kept). One directive per
anchor. Inserting whole *new* steps (before/after) and Codex/Gemini support
are tracked follow-ups; today's composer is Claude with these three ops.

**Compose, then commit the output.** The composed `SKILL.md` is what the
harness loads, so it lives in the repo alongside `overrides.md`:

```bash
baseline skill-compose compose        # composes every .claude/skills/*/overrides.md in the repo
baseline skill-compose compose implement-issue   # or one skill by name
```

`skill-compose` refuses to overwrite a pre-existing `SKILL.md` that isn't one
of its own outputs — so it can never silently clobber a hand-authored full
fork (2a). Remove or rename that file first if you're migrating it to 2b.

**Keeping it current is enforced, not remembered.** `baseline skill-compose
check` recomposes to a temporary file and byte-compares it against the
committed output, so it catches a changed base, changed overrides, *or* a
hand-edit — and exits nonzero when stale. Wire it as a project gate so a stale
composed skill fails CI / the Stop hook rather than drifting silently:

```toml
[gates]
skillcompose = "baseline skill-compose check"
```

(Fully automatic recompose on `baseline update` is a tracked follow-up; until
then the gate above is the enforcement point.)

Use **2a** only for a wholesale divergence; reach for **2b** for anything
smaller — the point of the global skill existing is that most projects should
inherit it, deltas and all.

## Override 3: quality gates

Two independent ways to override how quality gates run for a repo, and they
compose:

### 3a. `agents.toml [gates]`

`scripts/lib/project-gates.sh` auto-detects gates for the
common ecosystems (Node via `package.json` + lockfile → `pnpm`/`npm`/`yarn`/
`bun`; Rust via `Cargo.toml`; Go via `go.mod`; Python via `pyproject.toml`/
`setup.py`/`setup.cfg`/`requirements.txt`). A project's `agents.toml` can
override any of the four built-in labels — `typecheck`, `lint`, `test`,
`format` — individually:

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

**Detection is single-primary-ecosystem.** The first ecosystem (Node → Rust
→ Go → Python) that yields at least one command wins; the rest are skipped.
A polyglot repo (e.g. `package.json` **and** `pyproject.toml`) gets the
primary ecosystem's gates automatically and layers the second ecosystem's in
via the open set below. Running every detected ecosystem's gates
automatically is a tracked follow-up.

#### Gates are an open set (`build`, `guards`, …)

`[gates]` is not limited to the built-in four. **Any key you add becomes a
first-class gate** that runs and blocks exactly like `test` — for a
build-as-a-gate, an architecture-guard suite, whatever the repo needs:

```toml
[gates]
build  = "npm run build"         # a custom gate, blocks like the built-in four
guards = "composer guards"       # arbitrary project-specific gate
```

#### Per-gate N/A (declared not-applicable)

A gate an override sets to `""` is *disabled* (silently skipped). That is
different from a project that has **no such gate by design** — a stdlib-only
tool with no linter or type-checker. Declaring it **N/A** makes the absence
intentional and *reported*, so it never looks like a detection miss:

```toml
[gates.state]
lint      = "na"                 # this project has no lint, by design (reported N/A)
typecheck = "na"                 # ditto — N/A, not a failure and not a miss
```

`bash project-gates.sh status` shows each gate's state (`run` / `N/A` /
`disabled`), so a declared-N/A axis is visible rather than silent.

#### Per-gate path scope (a changed-files condition)

A gate can be scoped to only run when the change set touches a matching path
— e.g. a `build` gate that need only run when app/route code changes:

```toml
[gates.scope]
build = "apps/**,packages/**"    # run 'build' only when these paths change
```

Scope patterns are comma-separated shell-`case` globs where `*` matches
across `/` (so `apps/**` and `apps/*` both mean "anything under `apps/`").
Scope is evaluated only when a change set is available — the Stop-hook
`precommit-gate.sh` supplies the branch's changed files, so a docs-only turn
skips a gate scoped to `apps/**` **without forking the gate script**.
Standalone `project-gates.sh run` has no change set and runs scoped gates
unconditionally (fail-safe).

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
or a project that wants a completely different Stop-hook policy. Ship a full
replacement script at that exact path and the global one steps aside
entirely; nothing double-runs. (Note: **path-scoping no longer needs a
fork** — express it with `[gates.scope]` in 3a instead.)

Use `[gates]` when the commands, the gate set, N/A axes, or path-scoping are
what differ; ship a repo-local gate script only when the *policy* itself
(e.g. strict ordering between gates) needs to differ.

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

**A monorepo whose gates should skip on docs-only turns** (path-scoping in
config instead of a forked gate script):

```toml
[gates]
build = "npm run build"

[gates.scope]
typecheck = "apps/**,packages/**"
lint      = "apps/**,packages/**"
test      = "apps/**,packages/**"
build     = "apps/**,packages/**"
```

**A stdlib-only tool with no linter or type-checker** (declare the absence as
N/A so it reports, rather than looking like a detection miss):

```toml
[gates.state]
lint      = "na"
typecheck = "na"
```

**A repo that needs to run a database migration check before its normal
gates, in an order `project-gates.sh` doesn't support:** ship
`.claude/scripts/precommit-gate.sh` in the repo that runs the migration
check and then re-uses (or reimplements) the standard gate list — the global
Stop hook detects it and steps aside.

**A repo whose `/implement-issue` needs one extra sign-off line, nothing
else:** carry just that line in
`.claude/skills/implement-issue/overrides.md` (Override 2b) and
`baseline skill-compose compose` — the other steps keep inheriting the
baseline. Only reach for a full
`.claude/skills/implement-issue/SKILL.md` shadow fork (Override 2a) when the
whole procedure diverges.

## See also

- [installation.md](installation.md) — how the global baseline gets onto
  disk in the first place.
- [roles-and-agents.md](roles-and-agents.md) — `agents.toml [roles]`, the
  sibling table to `[gates]` in the same manifest.
- [philosophy.md](philosophy.md) — why the baseline is law by default and
  only yields to an explicit, deliberate override.
