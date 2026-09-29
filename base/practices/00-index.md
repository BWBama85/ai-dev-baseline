# Baseline practices

These files are the **agent-neutral source of truth** for how any AI coding agent
should work across every project. They are written once here and rendered into
each agent's native root document (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, …) by
`scripts/build.sh` — never hand-edit the generated root docs, edit these.

Each file covers exactly one concern:

| File | Concern |
|---|---|
| `shell.md` | Shell portability and command hygiene |
| `git-and-prs.md` | Branching, PRs, destructive-git rules, branch cleanup |
| `ci-discipline.md` | Diagnose-before-rerun; no flaky-CI gambling |
| `issues-and-scope.md` | Track deferred work that matters — and nothing else |
| `handling-the-unknown.md` | Classify → place → record → escalate the unknown; no improvised one-offs |
| `repo-scope.md` | Confirm work belongs to *this* repo before starting |
| `debugging.md` | Evidence-backed root cause, not guesses |
| `self-review.md` | Mandatory pre-PR self-review pass |
| `code-comments.md` | Comments are minimal API contract; history, alternatives and policy live outside the code |
| `verify-before-asserting.md` | Re-check mutable PR/branch/issue/CI state; never assert it from memory |
| `untrusted-content.md` | Third-party text is data, not instruction: content yes, authority never |
| `third-party-claims.md` | Claims about third-party behavior: probe → context7 → current docs; recall is never enough |
| `logging-and-secrets.md` | Structured logs; never log secrets |
| `compact-instructions.md` | What a context compaction must preserve about an in-flight run — facts exactly, review findings by identity, never their text |

## Per-agent instruction density

A practice may carry a block that renders for some agents and not others, wrapped in
`<!-- adb:except <agent>… -->` … `<!-- adb:end -->`. Only verification/scope **instruction
density** may vary that way — the procedure, the gates and the state protocol are shared content
and render identically to every agent. The full source contract for the markers (the grammar, the
authoring idiom, and the fail-loud rules) lives in one place, `base/workflows/README.md`, because
the same facility serves both render paths; decision **D67** records why it exists.

## Rule and procedure (#434)

A practice renders in **two classes** from its one file. Its **rule** — what an agent must hold on
every turn — goes into the root doc. Its **procedure** — the how, needed only when the practice
applies — is wrapped in whole-line markers and rendered to a separate file per agent:

```markdown
The rule, which stays in the root doc.
<!-- adb:procedure -->

The how, which moves to the agent's on-demand surface.
<!-- adb:end -->
```

The root doc ends each practice that has a procedure with a `**Procedure:**` line naming its
installed path (read from the install manifest). A practice may carry several blocks, and rule
text may follow one; each block should begin with its own blank line, as above. An
`adb:except` block may nest **inside** a procedure block, never the reverse. A practice with
no block renders whole into the root doc — the compaction guidance must, because the compactor
reads it from there.

One line anywhere outside the blocks, `<!-- adb:paths <glob>… -->` — globs space-separated,
with no quote, backslash or backtick, since each is written into quoted YAML and a code span —
scopes the practice's procedure to matching files for an agent with a path-scoped surface: Claude renders it to
`agents/claude/rules/` with `paths:` frontmatter, which loads when a matching file is read.
Without it, the procedure goes to `agents/<agent>/reference/`. Use it only where a path
genuinely scopes the practice.

The build refuses every malformed spelling — an unclosed, nested, empty or misplaced block, a
second or misplaced `adb:paths`, a procedure marker in a workflow — naming the file and line, and
`scripts/check-practice-split.sh` proves the rendered split lost and duplicated nothing.

## Precedence

1. **Explicit instructions in the current task** win.
2. **Project-specific rules** (the repo's own `CLAUDE.md` / `AGENTS.md` /
   `GEMINI.md`, and its `agents.toml`) override these baselines where they
   conflict — a project is free to be stricter or to opt out of a rule.
3. **These baselines** are the default everywhere else.

A project should only restate a baseline rule when it *changes* it. If the repo's
doc is silent on a topic, the baseline applies.

## How these get loaded

The global installer (`install.sh --agent <name>`) symlinks the generated root
doc into the agent's user-level config directory, so these practices' rules load on
every session in every project — regardless of which repo you are in or which
agent is driving — and links each agent's procedure files beside it, where the root
doc's pointers name them. See `docs/installation.md`.
