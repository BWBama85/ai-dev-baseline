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
- **Body.** Markdown procedure. Agent-specific mechanics are written as agent-neutral
  `{{PLACEHOLDER}}` tokens (see the vocabulary below) that each agent's renderer maps to
  that agent's real token. Claude's map reproduces today's skills byte-for-byte; a second
  agent supplies its own map for the same placeholders. `{{…}}` is **reserved** for this
  vocabulary — any `{{…}}` that survives rendering (a typo, or a token with no map entry)
  is a fail-loud build error, never emitted into a skill.
- **Encoding.** UTF-8, LF line endings, a single trailing newline. The renderer
  normalizes the trailing newline (so the generated skill always ends with exactly one);
  keep sources newline-terminated so the render stays a clean marker + placeholder diff.
- **`README.md` is not a workflow** — the renderer skips it.

### Neutral placeholder vocabulary

Use these in workflow **bodies** (never in frontmatter — frontmatter is emitted verbatim, so
Claude-specific passthrough keys like `allowed-tools` keep their real tokens). The renderer
substitutes literally (index/substr, not regex) so a token containing `$`, `"`, or `/`
maps cleanly. Only the **Claude** column is implemented today; the Codex/Gemini renderers
(and their columns) land with those agents' workflow-render work — this table is the contract
they fill in, not a promise those mappings exist yet.

| Placeholder             | Meaning                                             | Claude mapping (implemented)                        |
| ----------------------- | --------------------------------------------------- | --------------------------------------------------- |
| `{{ARGS}}`              | the arguments the command was invoked with          | `$ARGUMENTS`                                         |
| `{{STATE_DIR}}`         | per-workflow scratch/state dir (no trailing slash)  | `.claude/state`                                     |
| `{{GATE_RUNNER}}`       | quality-gate runner command **prefix**              | `bash "$HOME/.claude/scripts/lib/project-gates.sh"` |
| `{{SUBTASK_PRIMITIVE}}` | the tool/verb for creating tracked sub-tasks        | `TaskCreate`                                        |

`{{STATE_DIR}}` is a bare path with **no trailing slash**, so both `{{STATE_DIR}}/foo.json`
and `{{STATE_DIR}}/` render correctly. `{{GATE_RUNNER}}` is a command **prefix** — write the
subcommand after it (e.g. `{{GATE_RUNNER}} run`).

**Not yet neutralized (deliberately).** Some Claude-flavored references stay literal because
their agent-neutral form can only be designed alongside the machinery that resolves them —
per issue #16's own scope note. These ride the renderer/enforcement follow-ups, not this pass:

- `/code-review` and its `disable-model-invocation` semantics — a Claude command model; the
  step-8 invocation bug was fixed in #9, the remaining references are explanatory.
- Stop-hook / enforcement references (`implement-issue-gate.sh`, `precommit-gate.sh`, "Stop
  hook") — the per-agent enforcement mapping is unknown until the portable hooks layer (#25)
  and per-agent equivalents (#14) exist.
- A "run the configured review agent" primitive resolving via the role-dispatch helper (#15,
  not yet built) and any agent's product config surface an audited-project skill inspects
  (e.g. `.claude/settings.json`, `.claude/hooks/` in `/new-release`), which is domain content
  about the tool under review, not the workflow's own mechanics.

## Adding a workflow

1. Write `base/workflows/<name>.md` following the contract above.
2. `bash scripts/build.sh` — renders `agents/claude/skills/<name>/SKILL.md`.
3. `bash scripts/selfcheck.sh` — the `build-drift` + `workflow-map` steps confirm the
   render is committed and 1:1 with its source.
4. Commit `base/workflows/<name>.md` **and** the generated skill together.
