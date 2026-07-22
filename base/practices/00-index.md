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
| `issues-and-scope.md` | Out-of-scope work always becomes a tracked issue |
| `handling-the-unknown.md` | Classify → place → record → escalate the unknown; no improvised one-offs |
| `repo-scope.md` | Confirm work belongs to *this* repo before starting |
| `debugging.md` | Evidence-backed root cause, not guesses |
| `self-review.md` | Mandatory pre-PR self-review pass |
| `verify-before-asserting.md` | Re-check mutable PR/branch/issue/CI state; never assert it from memory |
| `logging-and-secrets.md` | Structured logs; never log secrets |

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
doc into the agent's user-level config directory, so these practices load on
every session in every project — regardless of which repo you are in or which
agent is driving. See `docs/installation.md`.
