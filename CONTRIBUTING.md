# Contributing to ai-dev-baseline

Thanks for hacking on the framework. This is the human-facing dev guide; the
agent-facing quick rules live in [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md).

## Prerequisites

- `git`, `gh` (for issues/PRs), `jq` (install hook-wiring + gate state), and **`bash` >= 5.3**
  (a hard floor — every entry point re-execs into one or exits; see `docs/installation.md` §7).
- `shellcheck` recommended (CI runs it; `scripts/selfcheck.sh` skips it if absent).
- macOS, Linux, or **Windows via WSL2** on a bash-5.3 distro (Ubuntu 26.04). WSL2 *is* Linux, so
  there is no separate port; Git Bash/MSYS2 and Cygwin are not supported. Clone inside the WSL
  filesystem, not under `/mnt/c` — see [`docs/installation.md`](docs/installation.md) §7.

## The one thing to internalize

`base/` is the **single source of truth**, and `scripts/build.sh` renders it into the
per-agent files:

- `base/practices/*.md` → each agent's root doc (`agents/claude/CLAUDE.md`,
  `agents/codex/AGENTS.md`, `agents/gemini/GEMINI.md`).
- `base/workflows/*.md` → the Claude skills (`agents/claude/skills/<name>/SKILL.md`).
  Each rendered skill carries a `GENERATED FILE` marker in its frontmatter.

**Never hand-edit a generated file** — a root doc *or* a skill. Edit the source under
`base/`, rebuild, commit both. CI's `build-drift` job fails a PR whose generated docs or
skills are stale, missing, untracked, or orphaned.

Before adding an adapter, gate detector, renderer, or hook, read
[`docs/design-principles.md`](docs/design-principles.md) — the tenets a contribution
must satisfy (single-source/no-drift, general-over-specific, config-over-hardcode,
graceful degradation, never-relocate-an-installed-path) and the CI check that enforces
each. New shell logic **sources** `scripts/lib/common.sh`; it never copies
`link()`/`unlink_if_ours()`/TOML-read.

## Develop from a *second* clone (reflexivity footgun)

The install symlinks point into a **clone**, so if you develop the framework from the
same clone your global install points at, **merging a PR mutates your own live
environment mid-session** — a moved installed path can dangle your gates, and a hook
change takes effect the instant it lands. This is exactly the friction that produced
issue #35.

Keep **two clones**: an *install-source* clone the global install points into (kept
current with `baseline update`) and a separate *dev* clone where you edit and open PRs
(kept current by `/implement-issue`'s preflight auto-sync). The full topology — including
why `baseline update` refuses to run from the dev clone — is documented once in
[`docs/installation.md`](docs/installation.md#the-two-clone-topology); don't restate it
here. And never relocate an installed path without a compat shim (design principle 6) —
`scripts/check-install-migration.sh` fails a PR that does.

## Dev loop

```bash
# 1. change something
$EDITOR base/practices/self-review.md      # or base/workflows/*.md / script / adapter / doc

# 2. if you touched base/practices or base/workflows, regenerate
bash scripts/build.sh

# 3. run the full local check suite (mirrors CI) before pushing
bash scripts/selfcheck.sh
```

`scripts/selfcheck.sh` runs, in order: **shellcheck** (tracked `*.sh` + `bin/agent-init`),
**build-drift** (rebuild + assert generated root docs **and** skills are current — not
stale, untracked, or missing), **workflow-map** (each `base/workflows/<name>.md` maps 1:1
to a rendered skill, no orphans), **skill-frontmatter** (each `SKILL.md` has
`name`/`description`/`user-invocable`), **gate-detector** + **gates** (`detect` no-ops
cleanly, `badcmd` errors, full gate-model behavior), **common-lib** (unit-test the shared
`scripts/lib/common.sh` primitives), **cleanup-enum**, **cleanup** and **baseline** (the
`/cleanup` symref fix, the `/cleanup` decision predicates — squash-merge detection, the
destructive refusals, the terse output contract — and `bin/baseline` currency
classification), **precommit-gate** (the Stop-hook
gate fails loud, never silently no-ops, when its library is missing), **implement-gate**
(the implement-issue Stop hook re-verifies PR state live and fails closed),
**install-migration** (a plain `git pull` never dangles an installed symlink),
**fact-drift** (canonical facts consistent across their consumer docs), **fact-mutation**
(every `absent:` pin injected into a tree copy and observed going red — a negative pin that
matches nothing passes forever while checking nothing), **fact-guard** (the witness contract and
the mutation harness themselves driven against broken rules and observed failing), **practice-index**
(every practice listed once in `00-index.md`), **release-role** (release stays project-owned
— no `/release` skill may ship, and `/new-release` still says it is not the release cutter),
**release-skill** (this project's OWN release predicates — version validation, the changelog
stamp, and the check-set settled test — plus the boundary invariants that keep them out of the
installed `scripts/lib` and keep the skill delegating rather than re-deriving), **bash-floor** +
**bash-floor-guard** (every CI job sits on a runner proven to carry bash ≥ 5.3 and wires the
runtime guard that says which interpreter it got — and that lint is itself observed going red on
every rule it owns), and an **install→uninstall dry-run** (all three agents) into a throwaway
`HOME`.

Green locally ≈ green in CI, with two honest qualifications since #257. CI runs this offline suite
on **two** hosted platforms — `ubuntu-26.04` and `macos-latest` — and your workstation is one of
them, so a local green speaks for the OS you are sitting at, not for the other runner's image or
its Homebrew bootstrap. And `check-bash-floor.sh --runtime` — offline, and running in all 27 CI
jobs — is still omitted locally, but since #256 the reason is different: what it adds beyond the
entry gate is an assertion about the machine and about `command -v bash`, which is a CI-image
question. (A contributor below the floor no longer gets a pass here — `selfcheck.sh` gates its own
interpreter on line 1.) Its **static** half and #256's **entry-point** half both run here. See [`docs/ci-runners.md`](docs/ci-runners.md).

## Repository map

| Path | Purpose |
|---|---|
| `base/practices/*.md` | The shared law (edit here) |
| `base/workflows/*.md` | Single source for each workflow — procedure + metadata (edit here) |
| `base/roles.md` · `templates/agents.toml` | Role model + per-project manifest |
| `agents/<agent>/` | Per-agent adapter, generated root doc, (Claude:) generated `skills/` + `scripts/` |
| `scripts/lib/common.sh` · `project-gates.sh` | Shared shell primitives + gate detector (the ONE home; installs to `~/.<agent>/scripts/lib`) |
| `scripts/build.sh` · `scripts/selfcheck.sh` | Render root docs + skills · local CI |
| `scripts/check-*.sh` | Standalone checks CI + selfcheck both call (common-lib · gates · cleanup-enum · cleanup · baseline · precommit-gate · implement-gate · install-migration · bash-floor · bash-floor-guard · fact-drift · fact-mutation · fact-guard · claims · claims-guard · practice-index · release-role · release-skill) |
| `install.sh` · `uninstall.sh` · `bin/agent-init` | Global install + per-project init |
| `docs/` | design-principles · philosophy · installation · roles-and-agents · per-project-overrides · adding-an-agent · ci-runners |
| `.github/workflows/ci.yml` | 26 Linux jobs on `ubuntu-26.04` + one aggregate `selfcheck-macos` job (shellcheck · build-drift · frontmatter · gate-detector · common-lib · cleanup-enum · cleanup · baseline · precommit-gate · implement-gate · install-migration · bash-floor · bash-floor-guard · fact-drift · fact-mutation · fact-guard · claims · claims-guard · claims-live (CI-only) · practice-index · release-role · release-skill · install dry-run). Every job proves its own bash ≥ 5.3 — [`docs/ci-runners.md`](docs/ci-runners.md) |

## Adding a new agent

See [`docs/adding-an-agent.md`](docs/adding-an-agent.md). Summary: add
`agents/<token>/adapter.sh` implementing `install <repo> <backup_dir>` /
`uninstall <repo>` (idempotent symlink + backup, mirroring `install.sh`), add a
`render()` call to `scripts/build.sh`, and register the token + invocation in
`base/roles.md`. Deep per-agent workflow parity is the harder, optional part.

## Style

- **Shell:** `bash` **>= 5.3** — the runtime floor (epic #255), so `mapfile`,
  associative arrays, namerefs and `${ command; }` are encouraged rather than avoided.
  Quote expansions, single-purpose commands. Must pass
  `shellcheck --severity=warning -e SC1091`. Justify any `# shellcheck disable=` with
  a one-line reason.
  - Every entry point gates its own interpreter as its first statement, in one of **three**
    classifications that `check-bash-floor.sh --entrypoints` enforces (it fails the build on a
    file that is unclassified or uses the wrong form):
    - **gate** (55 files) — `adb_require_bash`: re-exec, else exit non-zero with your
      platform's install command.
    - **advisory** (3) — `adb_require_bash_advisory`: same re-exec, but when it cannot, the
      file takes its own documented no-op and exits **0**. For `statusline.sh`,
      `session-currency.sh` and `state-claim-gate.sh`, whose contracts forbid a non-zero exit.
      It never runs its body under a sub-floor interpreter (D31).
    - **exempt** (1) — `check-bash-floor.sh` calls neither: it is the observer, and an observer
      that upgrades its own interpreter has destroyed the observation (D31).
  - **`scripts/lib/common.sh` must stay parseable below the floor** — it holds the gate, and a
    caller cannot reach a function until sourcing finishes, so a 5.3-only construct there makes
    the gate unreachable on exactly the hosts it exists for (D30).
- **Markdown practices/skills:** concise, imperative, agent-neutral where the content
  is shared; include a short "Why" only where it earns its place.
- **Commits/PRs:** semantic subject, feature branch + PR, green CI. Never push to
  `main`. File a tracked issue for deferred work **that clears the bar** — name who does
  it and what breaks if nobody ever does; either unanswerable, file nothing (the
  framework's own `issues-and-scope` practice).

## Releases

Versioning is by git tag; user-visible changes go in [`CHANGELOG.md`](CHANGELOG.md)
under **Unreleased** as you land them, then get stamped into a version on tag. Because
installs are symlinks, `git pull` in a user's clone picks up `main` immediately — so
keep `main` releasable.

**Run `/release` to cut one.** The procedure below used to be hand-executed every time;
it now has a code home at [`.claude/skills/release/SKILL.md`](.claude/skills/release/SKILL.md)
— this project's own release skill, since the baseline ships none by decision #3 (D7/D14).
It re-verifies release readiness and branch health live, refuses to cut on a red or
unverifiable `main`, stamps the changelog through an ordinary PR, tags the *merge commit it
just watched go green*, and finishes with `baseline release roll` so the release milestone
does not stay open and re-trigger the next `/roadmap` run.

The manual equivalent, if you ever need it: stamp `[Unreleased]` into `## [X.Y.Z] - DATE`
(leaving `[Unreleased]` in place and empty), repoint the link refs, ship it as a PR, then
`git tag -a vX.Y.Z` on a green `main` and push the tag.
