# base/workflows

**The single source of truth for each workflow's procedure + metadata.** Mirrors how
`base/practices/*.md` is the source for the agent root docs: one agent-neutral source,
rendered per agent by `scripts/build.sh`. A workflow added here appears on every agent
whose renderer is wired — no per-agent porting.

All three agents are wired: `scripts/build.sh` regenerates
`agents/<agent>/skills/<name>/SKILL.md` from `base/workflows/<name>.md` for **Claude,
Codex, and Antigravity/Gemini**. The three converge on the agent-skills `SKILL.md`
folder standard (`<name>/SKILL.md` with `name` + `description` frontmatter), so one
generic renderer serves them all — each agent supplies only its placeholder map, its
frontmatter policy, and its install location (see below and `docs/adding-an-agent.md`).
Per-agent enforcement hooks (a Stop-hook equivalent) render from these **same** sources
and remain tracked follow-ups (#14/#25).

## The rendered files are generated — edit here

`agents/<agent>/skills/<name>/SKILL.md` (for each of `claude`, `codex`, `gemini`) carries a
`GENERATED FILE — do not edit by hand` marker and is overwritten on the next build. **Edit
`base/workflows/<name>.md`, then run `bash scripts/build.sh`** and commit the source plus all
three regenerated skills. CI's `build-drift` job fails a PR whose rendered skills (in any
agent's tree) are stale, missing, untracked, or orphaned — the same guarantee the root docs
already have.

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
- **Required frontmatter keys:** `name`, `description`, `user-invocable`. `description`
  must be a **single, non-empty line** — the Codex/Gemini render synthesises a minimal
  `name` + `description` frontmatter and captures only that one line, so a folded/block
  scalar (`>`/`|`) or a multi-line value would drop content. `scripts/build.sh` rejects a
  non-single-line description loud, for every agent.
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

Use these in workflow **bodies** (never in frontmatter — Claude's render emits frontmatter
verbatim so its passthrough keys keep their real tokens, and the Codex/Gemini renders synth a
minimal `name` + `description` frontmatter; neither substitutes placeholders in frontmatter).
The renderer substitutes literally (index/substr, not regex) so a token containing `$`, `"`,
or `/` maps cleanly. All three columns are implemented (`scripts/build.sh`'s
`render_agent_skill`).

| Placeholder             | Meaning                                             | Claude                                              | Codex                                              | Gemini / Antigravity                               |
| ----------------------- | --------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------- | -------------------------------------------------- |
| `{{ARGS}}`              | the arguments the command was invoked with          | `$ARGUMENTS`                                         | `$ARGUMENTS`                                        | `$ARGUMENTS`                                        |
| `{{STATE_DIR}}`         | per-workflow scratch/state dir (no trailing slash)  | `.claude/state`                                     | `.codex/state`                                     | `.gemini/state`                                    |
| `{{GATE_RUNNER}}`       | quality-gate runner command **prefix**              | `bash "$HOME/.claude/scripts/lib/project-gates.sh"` | `bash "$HOME/.codex/scripts/lib/project-gates.sh"` | `bash "$HOME/.gemini/scripts/lib/project-gates.sh"` |
| `{{ROLE_DISPATCH}}`     | role-resolver/dispatcher command **prefix**         | `bash "$HOME/.claude/scripts/lib/role-dispatch.sh"` | `bash "$HOME/.codex/scripts/lib/role-dispatch.sh"` | `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh"` |
| `{{CURRENT_AGENT}}`     | the agent token this skill is rendered for          | `claude`                                            | `codex`                                            | `gemini`                                           |
| `{{SUBTASK_PRIMITIVE}}` | the tool/verb for creating tracked sub-tasks        | `TaskCreate`                                        | `update_plan`                                      | `Create`                                           |

Examples: `{{STATE_DIR}}/foo.json` and `{{STATE_DIR}}/` both render cleanly, and a subcommand
goes after the prefix, e.g. `{{GATE_RUNNER}} run` or `{{ROLE_DISPATCH}} resolve review`. The
shared runners (`scripts/lib/project-gates.sh`, `scripts/lib/role-dispatch.sh`) install under
each agent's `scripts/lib/`, so `{{GATE_RUNNER}} run` and `{{ROLE_DISPATCH}} invoke gap_analysis`
resolve on all three. `{{CURRENT_AGENT}}` renders to the driving agent's own token, so a workflow
can ask "is this review slot me?" (`{{CURRENT_AGENT}}` == the resolved token → run in-process,
else shell out via `{{ROLE_DISPATCH}}`). `{{SUBTASK_PRIMITIVE}}` maps to each agent's real
task primitive where it has one (Claude `TaskCreate`, Codex `update_plan`); Antigravity has no
distinct primitive, so it maps to the plain verb `Create` (reads as "Create N tracked sub-tasks").

**Not yet neutralized (deliberately).** Some Claude-flavored references stay literal because
their agent-neutral form can only be designed alongside the machinery that resolves them —
per issue #16's own scope note. They render verbatim into the Codex/Gemini skills too (each
carries a generated caveat comment saying so), and full cross-agent neutralization rides the
renderer/enforcement follow-ups, not this pass:

- `/code-review` and its `disable-model-invocation` semantics — a Claude command model; the
  step-8 invocation bug was fixed in #9, the remaining references are explanatory.
- Stop-hook / enforcement references (`implement-issue-gate.sh`, `precommit-gate.sh`, "Stop
  hook") — the per-agent enforcement mapping is unknown until the portable hooks layer (#25)
  and per-agent equivalents (#14) exist.
- Any agent's product config surface an audited-project skill inspects (e.g.
  `.claude/settings.json`, `.claude/hooks/` in `/new-release`), which is domain content about
  the tool under review, not the workflow's own mechanics. *(The "run the configured review
  agent" primitive is now neutral — workflows resolve + shell out via `{{ROLE_DISPATCH}}`, the
  runtime role-dispatch helper, #15.)*

### Step headings are project-override anchors

A skill's `### ` step headings are a stable contract: a project can carry a small
delta on one step (without forking the whole skill) by targeting its heading as an
**anchor** in a `.claude/skills/<name>/overrides.md`, which `scripts/lib/skill-compose.sh`
merges onto the installed base skill (issue #22 — see `docs/per-project-overrides.md`).
The anchor is the heading slugified with the leading `N.` step number stripped, so a step
can be **renumbered** freely; **renaming** a step heading changes its anchor and makes any
project override that targeted it fail loud on the next recompose (the intended "your fork
has diverged" signal). Keep step-heading wording stable across edits when you can, and
treat a rename as a breaking change to that anchor.

## Adding a workflow

1. Write `base/workflows/<name>.md` following the contract above.
2. `bash scripts/build.sh` — renders `agents/<agent>/skills/<name>/SKILL.md` for every agent.
3. `bash scripts/selfcheck.sh` — the `build-drift` + `workflow-map` steps confirm the
   renders are committed and 1:1 with their source, across all agents.
4. Commit `base/workflows/<name>.md` **and** all the generated skills together.
