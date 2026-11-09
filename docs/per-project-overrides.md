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
   `GEMINI.md`, its nested root docs and `.claude/rules/` files for the paths
   they scope, and its `agents.toml` — override the baseline where they
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

### 1a. Where project content lives

A project keeps its **facts** and gives up its own **workflows** (`policy:one-baseline`). A fact
says what is true of this code; a workflow says what steps to run or which skill to invoke. The
rule and its test are in `base/practices/handling-the-unknown.md` ("Facts and workflows"). Each
kind of fact has one home:

| Fact | Home |
|---|---|
| Holds repo-wide | the root doc (`CLAUDE.md` / `AGENTS.md` / `GEMINI.md`) |
| One package's own conventions (a subtree with its own manifest) | a nested root doc inside that package, e.g. `apps/api/CLAUDE.md` |
| Paths that span the tree, or a subtree that is not a package | `.claude/rules/<name>.md` with `paths:` frontmatter |
| One package's gate command | a custom gate in `agents.toml [gates]`, scoped by `[gates.scope]` (3a) |

`agents.toml` holds configuration only: commands, scopes, roles. A sentence of project
knowledge goes in a root doc or a rules file.

```markdown
---
paths:
  - "src/db/**"
---
Migrations under src/db are append-only.
```

`paths:` is the only frontmatter key Claude Code reads from a rule, as a YAML list or a
comma-separated string ([code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory)).
A rule scoped with `globs:` is not scoped at all: it loads at every session start (witnessed with
an `InstructionsLoaded` hook on Claude Code 2.1.319). `/adopt`
reports it with the `paths:` spelling and never rewrites it.

**Which agent loads what.** Claude loads a `paths:` rule when it touches a matching file, and a
nested `CLAUDE.md` once it touches a file in that directory. Codex reads `AGENTS.md` only from
the project root down to its working directory, so `apps/api/AGENTS.md` reaches a Codex session
started in `apps/api/`, not one started at the root; an `AGENTS.override.md` beside it is read
instead. Gemini CLI (0.35 and later) loads a nested `GEMINI.md` when a tool touches that directory.
Only Claude reads `.claude/rules/`.

`/adopt` inventories all of it (`adopt-lib.sh specialized`): every rules file, every tracked
nested root doc, and any `.codex/rules*` or `.gemini/rules*` hand mirror. It reports where each
belongs, and a mixed file is split by an owner-approved judgment. To keep a surface where it is,
record a `project-delta` entry with a `keeps:` line naming the path in
`.ai-dev-baseline/decisions.md`.

## Override 2: a project-scoped skill with the same name — retired

**Retired by owner policy (2026-10-14, `policy:one-baseline`, D148): a project carries no skills of
its own.** A project skill — a same-name fork, a composed override, a legacy workflow the baseline
supersedes, or a project-specific skill — is reported by `/adopt`'s `workflows` rung
(`adopt-lib.sh workflows`, #535) and retired to `.ai-dev-baseline/retired/<date>/` in a normal PR.
What it did that the baseline does not becomes a baseline issue or project config (the root doc,
`agents.toml`). The one exception is `release`, while the baseline ships no `release` skill (D7). A
`DEVIATION` entry may explain a finding; it never clears one.

A same-named project skill does not behave the same on every agent:

- **Claude Code** runs a *personal* skill over a same-named *project* one ("personal over
  project", [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills)). While the
  baseline's `~/.claude/skills/<name>` link is installed, the project copy never runs at all; the
  rung calls it `duplicates`.
- **Codex** loads `.codex/skills` and `.agents/skills` from the repository and lists both
  same-named copies (#540); the rung calls that `shadows`.

The two forms below are documented for the projects that still carry one until they migrate.

### 2a. Full shadow fork (whole-file replacement)

A complete project `SKILL.md` — `.claude/skills/<name>/` for Claude, or
`.codex/skills/<name>/` / `.agents/skills/<name>/` for Codex. Codex lists it
beside the global skill; on Claude, where a personal skill runs over a project
one, it runs only on a machine without the global install (#540).

The cost is real: **a forked skill is a skill frozen in time.** It stops
inheriting every later baseline improvement to *every* step, even the 90% the
fork never meant to change. A fork that carried ~25 novel lines on top of a
500-line skill silently falls behind on the other 475.

### 2b. Partial compose-override — retired, and the composer refuses

`skill-compose` used to merge a project's `.claude/skills/<name>/overrides.md` onto the installed
baseline skill (#22). Composing needs the global base skill, and on any machine where that
personal skill is installed Claude runs it instead of the composed project copy (#540); the
composed copy ran only where the global install was absent.
So the composer is retired: `baseline skill-compose compose`, `check` and `list-anchors` each exit
`3` and name the retirement, and write nothing.

If a project still carries one:

- run `/adopt` — its `workflows` rung reports the `overrides.md` and the composed `SKILL.md`;
- turn each directive into a baseline issue or project config (the root doc, `agents.toml`);
- remove a `skill-compose check` gate from `agents.toml [gates]`, which now fails with exit `3`;
- move the files to `.ai-dev-baseline/retired/<date>/` in a normal PR.

## Override 3: quality gates

Two independent ways to override how quality gates run for a repo, and they
compose:

### 3a. `agents.toml [gates]`

`scripts/lib/project-gates.sh` auto-detects gates for the
common ecosystems (Node via `package.json` + lockfile → `pnpm`/`npm`/`yarn`/
`bun`; Rust via `Cargo.toml`; Go via `go.mod`; Python via `pyproject.toml`,
`setup.py`, `setup.cfg`, a requirements file, `Pipfile`, `tox.ini`, a pytest,
mypy or ruff config file, or `conftest.py`; PHP via `composer.json`). A
project's `agents.toml` can override any of the four built-in labels —
`typecheck`, `lint`, `test`, `format` — individually:

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
→ Go → Python → PHP) that yields at least one command wins; the rest are
skipped. A polyglot repo (e.g. `package.json` **and** `pyproject.toml`) gets
the primary ecosystem's gates automatically and layers the second
ecosystem's in via the open set below. Running every detected ecosystem's
gates automatically is deliberately out of scope — the open set is the
supported answer for a polyglot repo, not a placeholder for one.

**PHP is last, and a WordPress-shaped repo is why that matters to you.** A
plugin or theme routinely carries a `composer.json` **and** a `package.json`
for its asset build. Such a repo keeps its **Node** gates — those are
commands the project itself declared — and its PHP gates are the polyglot
case above: add them through the open set. A repo with only `composer.json`
is detected as PHP directly. (`/adopt`'s `stack` classifier answers
`php-wordpress` for the same tree, and the difference is deliberate: that
one labels the project for the upstream pin, while this one decides which
commands gate a commit.)

The PHP adapter prefers a **declared `composer.json` script** (`test`,
`lint`) over an inferred binary, and prefers a Composer-pinned
`vendor/bin/<tool>` over the same tool on `PATH`. It resolves `typecheck` to
PHPStan or Psalm, `test` to PHPUnit, `lint` to PHP_CodeSniffer, and `format`
to `php-cs-fixer --dry-run` — never an in-place fixer, because a gate that
rewrites the tree is a mutation wearing a verification's clothes.

The Python adapter takes every gate from what the **project** configures,
never from what happens to be installed on the machine (#568):

- **`test`** is `pytest -q` (or `python3 -m pytest -q` when `pytest` is not
  on `PATH`) when the project shows pytest: a `pytest.toml`, `.pytest.toml`,
  `pytest.ini` or `.pytest.ini`; a `conftest.py` at the root, in `tests/` or
  in `test/`; a `[tool.pytest…]` table in `pyproject.toml`, `[tool:pytest]`
  in `setup.cfg` or `[pytest]` in `tox.ini`; or `pytest` (plugins such as
  `pytest-cov` included) as a dependency or command in `pyproject.toml`,
  `Pipfile`, `setup.py`, `setup.cfg`, `tox.ini`, a root `*requirements*.txt`
  or `requirements/*.txt`. What counts: in a requirements file, a line
  that starts with the name; in a TOML file or `setup.py`, a quoted string
  that starts with it or contains `-m pytest`, or a key that is it; in
  `setup.cfg` or `tox.ini`, a value or continuation line that starts with
  it, or `-m pytest`. The field is not checked, so prose in one of those
  shapes counts too: `description = "pytest …"`, or
  `description = "do not run python -m pytest"`. Otherwise,
  when `tests/` (else `test/`) directly holds a `test*.py`, it is unittest
  discovery over that directory (`unittest discover -s <dir>`, run through
  a one-line `python3 -c` wrapper). The wrapper also fails when unittest
  finds **nothing to run or skip**, so a folder of only pytest-style tests is
  never reported green; plain `python -m unittest` exits 0 in that case
  before Python 3.12. A folder mixing the two styles runs only its unittest
  tests: declare `[gates]` for that project. Otherwise there is no `test`
  gate. A pytest project without pytest installed gets a red gate on
  purpose: the environment is incomplete.
- **`typecheck`** is `mypy .` only with `mypy.ini`, `.mypy.ini`, a
  `[tool.mypy]` table in `pyproject.toml` or `[mypy]` in `setup.cfg`.
- **`lint`** and **`format`** are `ruff check --no-fix --no-fix-only .` and
  `ruff format --check .` only with `ruff.toml`, `.ruff.toml` or a
  `[tool.ruff]` table in `pyproject.toml`. The two `--no-fix` flags override
  a project's `fix = true` or `fix-only = true`, under either of which a
  bare `ruff check` rewrites the source (and `fix-only` also exits 0 on the
  violations it leaves).

The detector reads those files line by line, not as TOML or INI: a table
header must start its line (spaces and quoted parts inside the brackets are
fine, and names are case-sensitive), a header-shaped line inside a
multi-line string is read as a header, and a table defined only by dotted
keys (`tool.ruff.line-length = 100`, with no `[tool.ruff]` header) is not
seen. If a file whose contents would decide a gate cannot be read, or a
directory evidence is read from (`requirements/`, `tests/`, `test/`) cannot
be searched, and nothing else decided it, detection stops with an error
naming the file and the gate: `detect`, `status` and `run` exit 2, so the turn-end gate blocks
rather than run a set of gates nobody chose. A gate `agents.toml` declares
(a command, `""`, or `[gates.state]` `na`) needs no guess, so it never
causes that error.

A configured tool that is not on `PATH` is dropped, never emitted as a gate
that cannot run, and with neither `pytest` nor `python3` on `PATH` no test
evidence is read at all. A Python project with nothing runnable is not claimed, so
a later ecosystem (PHP) can still detect the repo. If your project tests
some other way (`make test`, `tox`, `nox`), declare it in `[gates]`.

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

#### Per-package commands (a monorepo)

A package that runs its own command is a **custom gate** named for it, scoped to its path. Every
key in `[gates]` that is not one of the four built-ins is its own gate, with its own scope, cadence
and log, so two packages run two commands and neither hides the other:

```toml
[gates]
test     = ""                              # no repo-wide test run
test-api = "pnpm --filter api test"
test-web = "pnpm --filter web test"

[gates.scope]
test-api = "apps/api/**"
test-web = "apps/web/**"
```

A turn that touches only `apps/api/` runs `test-api` and skips `test-web`, and says so. Keep a
repo-wide `test` beside them when a change outside every package also needs a test run. This is
the supported home for a per-package command; a project needs no gate script of its own to say
it.

#### Per-gate cadence (which caller a gate runs for)

**Don't point a per-turn gate at a full CI suite.** The Stop hook fires at the
end of *every* turn, including turns that edit nothing. A `test` gate wired to a
repo-wide CI mirror therefore re-runs CI after every message — this framework's
own `test` gate is `scripts/selfcheck.sh`, which costs **minutes** a run and
grows as its registry does. `[gates.scope]` cannot
express the difference, because a repo-wide suite legitimately matches almost any
changed path. Cadence can:

```toml
[gates]
test = "bash scripts/selfcheck.sh"   # the whole CI mirror

[gates.cadence]
test = "full"                        # not at every turn-end
```

There are two calling contexts, and a gate declares which it participates in:

| value | behaviour |
|---|---|
| `always` *(default)* | runs in both contexts — **exactly** the pre-cadence behaviour |
| `full` | skipped at turn-end; runs in a full `project-gates.sh run` |
| `turn-end` | runs at turn-end; skipped in a full run |

A gate runs iff `cadence == "always"` or `cadence == <the caller's context>`.
Values are case-insensitive.

**`full` does not mean "guaranteed before every push", and it is deliberately not
spelled `pre-push`.** Nothing in this baseline wires an automatic pre-push hook.
What it means is precisely *"excluded from the per-turn Stop hook, included in a
full run"*. The `/implement-issue`, `/debug` and `/resolve-pr-threads` workflows
each call the full runner before they push, so in practice a `full` gate does run
before a workflow-driven push — but that is those workflows' doing, not a
guarantee the gate model can make. A `git push` you type yourself runs nothing.

**Gate selection and exit status are unchanged on upgrade.** A repo with no
`[gates.cadence]` table has every gate at `always`, so the same gates run in both
contexts and the run's exit status is what it always was. The *output* does
change: a gate that passes now prints an elapsed line to stderr where it
previously printed nothing, so anything parsing this runner's stderr should
expect it. An *unrecognized*
value warns and **runs** the gate rather than skipping it: a typo must never
quietly disable enforcement, because a gate that stops running looks exactly like
a gate that passed (see §5 of `design-principles.md`).

**Every cadence and scope skip is reported**, with its reason:

```
adb: gate "test": skipped (cadence "full", this is a "turn-end" run)
```

(A gate *disabled* with `= ""` stays silently skipped, as it always has — that is
an explicit "never run this", not a conditional skip anyone needs telling about.
A declared-N/A gate is reported.)

Each gate that *does* run reports its elapsed time (`adb: gate "test": ok (12s)`),
so a slow gate is attributable without a stopwatch.

**What bounds a gate's runtime is the harness, not this file.** The Claude Stop
hook carries a `timeout` (240s as shipped) and the harness enforces it by
cancelling the hook; a process killed that way cannot report its own status, so
there is deliberately **no** per-gate kill here — a gate is never terminated
mid-run and silently reported as anything. Cadence is the supported answer to
"this gate is too expensive for every turn"; elapsed reporting is the supported
answer to "which gate is slow".

#### A failing gate's full log is kept

A failing gate prints the last 4000 bytes of its output, then the path of all of
it:

```
adb: gate "test" failed after 84s (bash scripts/selfcheck.sh)
adb: gate "test": full log kept at $TMPDIR/adb-gates.Xa81Qz/adb-gate-test.log
```

(The real line carries the absolute path that `$TMPDIR` stands for here.)

The tail is there for immediate context; the file is the evidence. When a
failing step prints early in a long run, its output survives only in the file.
Each run writes its logs into its own owner-only directory, `adb-gates.XXXXXX`
under `$TMPDIR` (`/tmp` when unset), and the closing `failing gates:` line names
that directory. A passing gate's log is deleted as soon as the gate passes. So a
kept directory holds only failing logs, and a run where every gate passes leaves
nothing behind. The exception is a deletion that fails: it leaves the file and
prints a `NOTE` naming it. A failing gate whose log is not found reports
`no log found at …`. A log already reported as kept that is not found when the
run ends is reported as `its log is no longer found at …`, and the closing line
names the directory only while a kept log is still found in it. These lines say
what was found, never why: a gate that changes the log directory (removes,
locks or replaces it) is out of scope, and under one, which logs survive is not
promised.

**Nothing deletes a kept directory**: remove it once you have read it. Retention
is unbounded by design. Every run that ends with a failing gate's log still in
place keeps its own directory, however large that output was, until you remove
it. The path is printed shell-quoted (`printf %q`), so a `$TMPDIR` with a space
in it can still be pasted straight into a shell, and a newline in it cannot
forge a line.

`$TMPDIR` is used as given. If it points inside the checkout at a path that is
not gitignored, kept logs land there as untracked files: the Stop hook counts
them in the change set it scopes gates by, and `baseline adopt status` digests
them into its receipt. Point `$TMPDIR` outside the checkout.

A gate with no log is **not run**, and counts as failed. If no private
directory can be created (`mktemp -d` failed, for example because `$TMPDIR`
does not exist or is not writable), no gate runs, and each one says so:

```
adb: gate "test" failed: no private log directory could be created under …, so it was NOT run (bash scripts/selfcheck.sh)
```

There is no fallback to the shared temp directory: there, a concurrent run
could overwrite a log and any local account could claim its name first. If the
directory exists but a log cannot be opened in it, for example because an
earlier gate removed the directory, that gate is not run either:

```
adb: gate "test" failed: its log could not be created at …, so it was NOT run (bash scripts/selfcheck.sh)
```

Enforcement fails closed rather than going quietly off. One limit: a full
filesystem can allow a log to be created and then refuse the gate's output.
The gate still runs, but its log is cut short, and the runner does not detect
that.

Exit status is the gates' own on every path. A cleanup that fails prints a
`NOTE` and never fails the run.

### 3b. Shipping the repo's own gate script

Every Stop-hook gate checks, before doing anything else, whether the repo
ships its **own** copy of that exact script at `.claude/scripts/<name>.sh`.
If that file exists and is not literally the same file as the one currently
running (compared with the `-ef` test, i.e. same inode — this is what lets
the *global* copy detect that it's running as itself vs. as a project's copy
without an infinite-defer loop), the global gate **`exec`s the project's
copy**, which becomes the gate:

```bash
# precommit-gate.sh, abbreviated
proj_gate="$repo_root/.claude/scripts/precommit-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  [ -x "$proj_gate" ] && exec "$proj_gate" "$@"
  exec bash "$proj_gate" "$@"
fi
```

`exec` — not `exit 0` — is load-bearing (#240). Until this was fixed the
global gate merely stepped aside, and **nothing else invokes a project
gate**: `install.sh`, the adapter and `bin/baseline` wire only the global
paths, so no project-level Stop hook exists to pick it up. A repo that
followed this section therefore ended up with a gate script nothing ran *and*
the global gate standing down — enforcement silently **off**, which is worse
than the gate it replaced. Because the project's copy is `exec`ed it inherits
stdin (the hook payload) and its exit status becomes the hook's, so a project
gate can still block a stop with `2`. A copy that isn't executable is run via
`bash` rather than failing the hook.

This is the escape hatch for a project whose gating needs are too custom for
`agents.toml [gates]` alone — e.g. gates that must run in a specific order,
or a project that wants a completely different Stop-hook policy. Ship a full
replacement script at that exact path and the global one steps aside
entirely; nothing double-runs. (Note: **path-scoping no longer needs a
fork** — express it with `[gates.scope]` in 3a instead.)

Use `[gates]` when the commands, the gate set, N/A axes, path-scoping **or
cadence** are what differ; ship a repo-local gate script only when the *policy*
itself (e.g. strict ordering between gates) needs to differ. In particular,
"this gate is too expensive to run every turn" is **no longer** a reason to fork
— that is what `[gates.cadence]` in 3a is for.

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

**A repo whose CI mirror is its `test` gate** (this framework itself):

```toml
[gates]
test = "bash scripts/selfcheck.sh"

[gates.cadence]
test = "full"   # before a full run, not after every turn
```

**A repo that needs to run a database migration check before its normal
gates, in an order `project-gates.sh` doesn't support:** ship
`.claude/scripts/precommit-gate.sh` in the repo that runs the migration
check and then **sources `project-gates.sh` and calls `adb_run_gates`** for
the standard list — the global Stop hook detects the project copy and `exec`s
it. Re-use the shared runner rather than reimplementing the gate list: a
second copy of that logic drifts from the real one and silently stops
matching the repo's own `agents.toml` (golden rule 4, and
`design-principles.md`).

**Pass `turn-end` as the third argument — a project Stop hook that omits it
gets the cadence backwards.** `adb_run_gates` defaults to the `full` context,
so a bare call from a Stop hook runs exactly the gates a repo declared *too
expensive for a turn* and skips the ones it declared `turn-end`:

```bash
# in .claude/scripts/precommit-gate.sh, after building "$changed"
. "$HOME/.claude/scripts/lib/project-gates.sh"
adb_run_gates "$repo_root" "$changed" turn-end   # <- the context, not optional here
```

The changeset matters for the same reason: without it `[gates.scope]` cannot
be evaluated and every scoped gate runs unconditionally.

**A repo whose `/implement-issue` needs one extra sign-off line, nothing
else:** that is baseline work, not a project skill (`policy:one-baseline`):
put a project fact in the repo's root doc or a `.claude/rules/` file, put configuration in
`agents.toml`, or file a baseline issue for the missing behaviour. Neither an `overrides.md` nor a
shadow fork is the answer any more; `/adopt`'s `workflows` rung reports both.

## See also

- [installation.md](installation.md) — how the global baseline gets onto
  disk in the first place.
- [roles-and-agents.md](roles-and-agents.md) — `agents.toml [roles]`, the
  sibling table to `[gates]` in the same manifest.
- [philosophy.md](philosophy.md) — why the baseline is law by default and
  only yields to an explicit, deliberate override.
