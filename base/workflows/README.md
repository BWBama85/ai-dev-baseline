# base/workflows

**The single source of truth for each workflow's procedure + metadata.** Mirrors how
`base/practices/*.md` is the source for the agent root docs: one agent-neutral source,
rendered per agent by `scripts/build.sh`. A workflow added here appears on every agent
whose renderer is wired — no per-agent porting.

Today the wired renderer is **Claude**: `scripts/build.sh` regenerates
`agents/claude/skills/<name>/SKILL.md` from `base/workflows/<name>.md`. Codex custom
prompts (`~/.codex/prompts/<name>.md`), the Gemini/Antigravity command surface, and
per-agent enforcement hooks render from these **same** sources and are tracked as
follow-up issues (see the repo's GitHub Issues, and `docs/adding-an-agent.md`).

## The rendered files are generated — edit here

`agents/claude/skills/<name>/SKILL.md` carries a `GENERATED FILE — do not edit by hand`
marker and is overwritten on the next build. **Edit `base/workflows/<name>.md`, then run
`bash scripts/build.sh`** and commit both. CI's `build-drift` job fails a PR whose
rendered skills are stale, missing, untracked, or orphaned — the same guarantee the root
docs already have.

## Source contract

Each `base/workflows/<name>.md` is a complete skill-shaped document — the richest agent
form (Claude's) is the canonical shape; other agents' renderers adapt or drop what their
CLI can't express (the issue's "honest scope note": same steps and invocation, behavior
bounded by each CLI).

- **Filename ↔ name.** The file stem `<name>` is the workflow id: it becomes the skill
  directory (`agents/claude/skills/<name>/`) and should match the frontmatter `name:`.
- **Frontmatter first.** Line 1 is `---`; the block closes with a matching `---`. The
  renderer injects the generated-file marker as YAML `#` comment lines right after the
  opening `---`, so the rendered file still starts with `---` (required by Claude's skill
  loader and CI's `skill-frontmatter` check — an HTML banner like the root docs use would
  break that).
- **Required frontmatter keys:** `name`, `description`, `user-invocable`.
- **Optional (Claude-specific) keys, passed through verbatim:** `argument-hint`,
  `allowed-tools`, `disallowed-tools`, `effort`. A future non-Claude renderer maps or
  ignores these per its CLI.
- **Body.** Markdown procedure. Claude-specific tokens (`$ARGUMENTS`, `.claude/state/`,
  `/code-review`, `TaskCreate`, …) currently live in the body as-is; abstracting them into
  agent-neutral templates is a tracked follow-up, not part of the source relocation.
- **Encoding.** UTF-8, LF line endings, a single trailing newline.
- **`README.md` is not a workflow** — the renderer skips it.

## Adding a workflow

1. Write `base/workflows/<name>.md` following the contract above.
2. `bash scripts/build.sh` — renders `agents/claude/skills/<name>/SKILL.md`.
3. `bash scripts/selfcheck.sh` — the `build-drift` + `workflow-map` steps confirm the
   render is committed and 1:1 with its source.
4. Commit `base/workflows/<name>.md` **and** the generated skill together.
