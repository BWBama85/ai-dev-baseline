# Contributing to ai-dev-baseline

Thanks for hacking on the framework. This is the human-facing dev guide; the
agent-facing quick rules live in [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md).

## Prerequisites

- `git`, `gh` (for issues/PRs), `jq` (install hook-wiring + gate state), `bash`.
- `shellcheck` recommended (CI runs it; `scripts/selfcheck.sh` skips it if absent).
- macOS or Linux. Windows is not yet supported — see the open issue.

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
graceful degradation) and the CI check that enforces each. New shell logic **sources**
`scripts/lib/common.sh`; it never copies `link()`/`unlink_if_ours()`/TOML-read.

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
`name`/`description`/`user-invocable`), **gate-detector** (`detect` no-ops cleanly,
`badcmd` errors), **common-lib** (unit-test the shared `scripts/lib/common.sh`
primitives), **fact-drift** (canonical facts consistent across their consumer docs),
**practice-index** (every practice listed once in `00-index.md`), and an
**install→uninstall dry-run** (all three agents) into a throwaway `HOME`. Green locally
≈ green in CI.

## Repository map

| Path | Purpose |
|---|---|
| `base/practices/*.md` | The shared law (edit here) |
| `base/workflows/*.md` | Single source for each workflow — procedure + metadata (edit here) |
| `base/roles.md` · `templates/agents.toml` | Role model + per-project manifest |
| `agents/<agent>/` | Per-agent adapter, generated root doc, (Claude:) generated `skills/` + `scripts/` |
| `scripts/lib/common.sh` · `project-gates.sh` | Shared shell primitives + gate detector (the ONE home; installs to `~/.<agent>/scripts/lib`) |
| `scripts/build.sh` · `scripts/selfcheck.sh` | Render root docs + skills · local CI |
| `scripts/check-*.sh` | Standalone checks CI + selfcheck both call (common-lib · fact-drift · practice-index) |
| `install.sh` · `uninstall.sh` · `bin/agent-init` | Global install + per-project init |
| `docs/` | design-principles · philosophy · installation · roles-and-agents · per-project-overrides · adding-an-agent |
| `.github/workflows/ci.yml` | shellcheck · build-drift · frontmatter · gate-detector · common-lib · fact-drift · practice-index · install dry-run |

## Adding a new agent

See [`docs/adding-an-agent.md`](docs/adding-an-agent.md). Summary: add
`agents/<token>/adapter.sh` implementing `install <repo> <backup_dir>` /
`uninstall <repo>` (idempotent symlink + backup, mirroring `install.sh`), add a
`render()` call to `scripts/build.sh`, and register the token + invocation in
`base/roles.md`. Deep per-agent workflow parity is the harder, optional part.

## Style

- **Shell:** `bash`/POSIX, macOS bash 3.2 safe (no `mapfile`, no `readlink -f`),
  quote expansions, single-purpose commands. Must pass
  `shellcheck --severity=warning -e SC1091`. Justify any `# shellcheck disable=` with
  a one-line reason.
- **Markdown practices/skills:** concise, imperative, agent-neutral where the content
  is shared; include a short "Why" only where it earns its place.
- **Commits/PRs:** semantic subject, feature branch + PR, green CI. Never push to
  `main`. File a tracked issue for anything deferred or out of scope (the framework's
  own `issues-and-scope` practice).

## Releases

Versioning is by git tag; user-visible changes go in [`CHANGELOG.md`](CHANGELOG.md)
under **Unreleased** as you land them, then get stamped into a version on tag. Because
installs are symlinks, `git pull` in a user's clone picks up `main` immediately — so
keep `main` releasable.
