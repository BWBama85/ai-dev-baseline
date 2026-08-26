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
- **Encoding.** UTF-8, LF line endings, a single trailing newline. A source that is **not**
  newline-terminated is **rejected** — the build fails rather than repairing it, because the
  per-agent block filter reads sources through `awk`, whose `print` always appends a newline, and
  silently adding a byte is the wrong way to differ from the `cat` it replaced (#304). The
  rendered *output* still ends with exactly one trailing newline.
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
| `{{ROADMAP_LIB}}`       | `/roadmap` decision-predicate command **prefix**    | `bash "$HOME/.claude/scripts/lib/roadmap-lib.sh"`   | `bash "$HOME/.codex/scripts/lib/roadmap-lib.sh"`   | `bash "$HOME/.gemini/scripts/lib/roadmap-lib.sh"`   |
| `{{REPO_SETTINGS_LIB}}` | repo-settings / auto-merge-guard command **prefix** | `bash "$HOME/.claude/scripts/lib/repo-settings.sh"` | `bash "$HOME/.codex/scripts/lib/repo-settings.sh"` | `bash "$HOME/.gemini/scripts/lib/repo-settings.sh"` |
| `{{CLEANUP_LIB}}`       | `/cleanup` decision-predicate command **prefix**    | `bash "$HOME/.claude/scripts/lib/cleanup-lib.sh"`   | `bash "$HOME/.codex/scripts/lib/cleanup-lib.sh"`   | `bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh"`   |
| `{{IMPLEMENT_LIB}}`     | run-admission command **prefix** (#202)             | `bash "$HOME/.claude/scripts/lib/implement-lib.sh"` | `bash "$HOME/.codex/scripts/lib/implement-lib.sh"` | `bash "$HOME/.gemini/scripts/lib/implement-lib.sh"` |
| `{{ADOPT_LIB}}`         | `/adopt` decision-predicate command **prefix** (#20) | `bash "$HOME/.claude/scripts/lib/adopt-lib.sh"` | `bash "$HOME/.codex/scripts/lib/adopt-lib.sh"` | `bash "$HOME/.gemini/scripts/lib/adopt-lib.sh"` |
| `{{CURRENCY_LIB}}`      | install-currency trigger-policy command **prefix**  | `bash "$HOME/.claude/scripts/lib/currency-lib.sh"`  | `bash "$HOME/.codex/scripts/lib/currency-lib.sh"`  | `bash "$HOME/.gemini/scripts/lib/currency-lib.sh"`  |
| `{{PR_REVIEW_LIB}}`     | pre-arm review-guard command **prefix**             | `bash "$HOME/.claude/scripts/lib/pr-review.sh"`     | `bash "$HOME/.codex/scripts/lib/pr-review.sh"`     | `bash "$HOME/.gemini/scripts/lib/pr-review.sh"`     |
| `{{STATE_ASSERT_LIB}}`  | observe-and-render state command **prefix**         | `bash "$HOME/.claude/scripts/lib/state-assert.sh"`  | `bash "$HOME/.codex/scripts/lib/state-assert.sh"`  | `bash "$HOME/.gemini/scripts/lib/state-assert.sh"`  |
| `{{PR_WATCH_LIB}}`      | async-reviewer status-detector command **prefix**   | `bash "$HOME/.claude/scripts/lib/pr-watch.sh"`      | `bash "$HOME/.codex/scripts/lib/pr-watch.sh"`      | `bash "$HOME/.gemini/scripts/lib/pr-watch.sh"`      |
| `{{PR_THREADS_LIB}}`    | review-thread enumeration command **prefix**        | `bash "$HOME/.claude/scripts/lib/pr-threads.sh"`    | `bash "$HOME/.codex/scripts/lib/pr-threads.sh"`    | `bash "$HOME/.gemini/scripts/lib/pr-threads.sh"`    |
| `{{PATTERN_LEDGER_LIB}}` | pattern-ledger command **prefix** (#421)           | `bash "$HOME/.claude/scripts/lib/pattern-ledger.sh"` | `bash "$HOME/.codex/scripts/lib/pattern-ledger.sh"` | `bash "$HOME/.gemini/scripts/lib/pattern-ledger.sh"` |
| `{{DOCS_LIB}}`          | documentation-duty command **prefix** (#422)        | `bash "$HOME/.claude/scripts/lib/docs-lib.sh"`      | `bash "$HOME/.codex/scripts/lib/docs-lib.sh"`      | `bash "$HOME/.gemini/scripts/lib/docs-lib.sh"`      |
| `{{CURRENT_AGENT}}`     | the agent token this skill is rendered for          | `claude`                                            | `codex`                                            | `gemini`                                           |
| `{{SUBTASK_PRIMITIVE}}` | the tool/verb for creating tracked sub-tasks        | `TaskCreate`                                        | `update_plan`                                      | `Create`                                           |

**A workflow that writes into `{{STATE_DIR}}` owes `/cleanup` a classification.** `/cleanup`
sweeps run-state whose PR or run has resolved, and it decides what a file *is* from an allowlist
in `scripts/lib/cleanup-lib.sh`'s `state-scan`. Anything unrecognised is `other` and is **never**
deleted — safe, but permanent: a new ephemeral state file that nobody registers becomes exactly
the accumulating debris #84 was filed about. So when you add one, add an arm for it: give it a
kind and the key its liveness is read from (a PR number, a branch), or leave it unclassified
*deliberately* if it is durable history rather than run debris (`new-release.json` is the latter).

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
- A Claude-specific **environment variable read inside a bash block every agent runs** — today
  just `$CLAUDE_CODE_SESSION_ID`, which `/implement-issue` stamps into its run marker as `owner`
  so the Claude Stop hook can tell its own run's marker from a sibling session's (#180). This is
  a different kind from the entries above (they are prose an agent *reads* or a path it
  *inspects*; this one *executes*), and it is only tolerable because it degrades correctly: an
  agent whose harness does not set it writes no `owner` key, and the field has no reader outside
  Claude until #14/#25 gives the other agents a hook. **`scripts/check-fact-drift.sh` pins the
  literal name in all three rendered skills**, so neutralizing this is expected to change that
  rule — the lint failing at that point is the tripwire working, not a regression.

### Per-agent blocks (`<!-- adb:except … -->`) — instruction density only

**One source, one procedure, different amounts of scaffolding.** A block wrapped in these
markers renders for every known agent **except** the ones it names:

```markdown
Do your own self-review pass first and list each finding.
<!-- adb:except claude -->

**Always** run it — self-review is the mandatory floor: edge cases, escaping/encoding,
off-by-one, idempotency.
<!-- adb:end -->
```

The mechanism is `block_filter` in `scripts/build.sh`, and **both** renderers call it — the
root-doc `render()` and the skill `render_agent_skill()` — so the same markers work in
`base/practices/*.md` and `base/workflows/*.md` alike. It runs **before** the `{{TOKEN}}` MAP,
so a placeholder inside an excluded block is never substituted for an agent the author excluded.

**What may go in one, and this is the whole constraint:** verification and scope **instruction
density**. The procedure, the gates and the state protocol are shared content and must render
identically to every agent. A rendered doc may differ in *how much it is told to double-check*;
it must never differ in *what it does*. Nothing in `build.sh` can enforce that — it is a rule for
the author and the reviewer, and `scripts/check-agent-blocks.sh` pins the concrete consequences
rather than the principle. Why it exists: the two vendors' published guidance asks for opposite
densities (Anthropic's Opus 5 guidance asks that explicit verification scaffolding be *removed*;
OpenAI's asks Codex for exactly the named-checklist pass), and one instruction set cannot be right
for both. See decision **D67**.

**There is deliberately no `only` form.** `except` is what every shipped source needs, and a
second spelling with no consumer is a silently dead knob. It also picks the safe default for an
agent nobody has considered yet: a fourth agent **inherits** every block — today's density,
unchanged — instead of silently receiving the most stripped-down render.
`docs/adding-an-agent.md` asks that adder to choose deliberately.

**Authoring idiom.** Put the opening marker on the line immediately after the preceding content,
the block's own blank line *inside* the block, and the closing marker immediately after the
block's last content line. Marker lines are removed, so this is what makes both the included and
the excluded render come out with correct markdown spacing.

**Rules, all fail-loud at build time.** An unknown agent token · an empty list · a list naming
every known agent (the block would render nowhere) · the same agent twice · a nested opener · a
close with nothing open · EOF inside a block · a marker inside a skill's **frontmatter** (markers
are body-only, the same rule `{{TOKEN}}` lives by, and it is rejected rather than merely asked
for) · a **target agent** the renderer does not know, which is what turns a typo in a `render`
call into a failure instead of a silent full-density render.

Two further rules are the filter's, and they are here because they differ from the `cat` it
replaced:

- **A source must end with a newline.** `cat` reproduced a missing final newline exactly; awk's
  `print` always appends one. Rather than silently add a byte, the build refuses.
- **The substring `<!-- adb:` is reserved *everywhere* in a file that renders** — inside a fence,
  inside a code span, inside running prose. The *recognizer* matches only whole lines, so a quoted
  marker is not treated as a directive; but each renderer then scans its finished output and
  refuses to publish anything still carrying the substring, which is the only net that catches a
  *misspelled keyword* (`adb:excpt` matches no rule at all). The consequence is that you cannot
  quote the syntax in a file that renders — which is why the two files documenting it, this one
  and `base/practices/00-index.md`, are both files their renderer skips.

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
