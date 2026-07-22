# Working on ai-dev-baseline

This repo **is** the framework — the agent-neutral single source of truth that gets
installed into *other* projects. Here, you are developing the framework itself.

If you installed the baseline globally, your `~/.<agent>` root doc still governs *how
you work* (feature branches, self-review, root-cause, out-of-scope → issue) — dogfood
those. The rules below are specific to this repo's code.

## Golden rules

1. **Never edit a generated root doc.** `agents/claude/CLAUDE.md`,
   `agents/codex/AGENTS.md`, and `agents/gemini/GEMINI.md` are **generated** from
   `base/practices/*.md` by `scripts/build.sh`. Edit the practices, then rebuild.
   CI's `build-drift` job fails if you forget. (This file — the repo-root `CLAUDE.md`
   — is hand-written and is *not* generated; don't confuse it with the one under
   `agents/claude/`.)
2. **`base/` is the source of truth.** `base/practices/` is the shared law, one
   concern per file. `base/roles.md` is the multi-agent role model.
3. **Run `scripts/selfcheck.sh` before every push.** It mirrors CI exactly
   (shellcheck · build-drift · skill-frontmatter · gate-detector · install dry-run).
   Fix red at the root — never push and hope (the CI-discipline practice applies to
   this repo too).
4. **Shell code must be portable and shellcheck-clean.** `bash`/POSIX, safe on macOS
   bash 3.2 (no `mapfile`, no `readlink -f`), passing
   `shellcheck --severity=warning -e SC1091`. The install runs on a stock Mac and on
   Linux CI.
5. **Skills are self-contained.** A Claude `SKILL.md` loads whole — keep it complete.
   Keep shared content agent-neutral so adapters can render it.
6. **Feature branch + PR + green CI.** No direct pushes to `main`. File a tracked
   GitHub issue for anything deferred (this repo lives by its own rules).

## Where things live

| Path | What |
|---|---|
| `base/practices/*.md` | The shared law — **edit here** |
| `base/roles.md`, `templates/agents.toml` | Role model + per-project manifest |
| `agents/<agent>/` | Per-agent: generated root doc, `adapter.sh`, (Claude:) `skills/` + `scripts/` |
| `scripts/build.sh` | Renders `base/practices` → each agent's root doc |
| `scripts/selfcheck.sh` | Local CI mirror |
| `install.sh` / `uninstall.sh` / `bin/agent-init` | Install contract |
| `docs/` | philosophy · installation · roles · overrides · adding-an-agent |

## Build / test loop

```bash
# edit base/practices/*.md (or a skill / script / adapter)
bash scripts/build.sh       # only if you touched base/practices
bash scripts/selfcheck.sh   # must pass before you push
```

## Adding an agent
See `docs/adding-an-agent.md`: `agents/<token>/adapter.sh` (install/uninstall), a
`render()` call in `scripts/build.sh`, and a row in `base/roles.md`.

## Status / roadmap
Claude is fully wired. Codex/Gemini install the shared practices; deeper per-agent
workflow parity and other deferrals are tracked in the repo's GitHub Issues.
`base/workflows/` is reserved for agent-neutral workflow specs (tracked issue); today
the canonical workflow implementations are the Claude skills under
`agents/claude/skills/`. Full contributor guide: `CONTRIBUTING.md`.
