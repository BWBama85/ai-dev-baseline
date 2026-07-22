# Roles and agents

The framework separates **what a job is** (a role) from **which AI does it** (an
agent). A project declares the mapping in an `agents.toml` at its repo root; every
workflow reads that mapping and delegates each step to the configured agent.

This is what makes the framework agent-neutral: the same `implement-issue`
workflow runs with Claude as primary and Codex reviewing, or Codex as primary and
Claude + Gemini reviewing, with **no change to the workflow itself** — only the
manifest changes.

## Roles

| Role | Job | Cardinality | Default if unset |
|---|---|---|---|
| `primary` | Drives implementation end-to-end (`implement-issue`) | exactly 1 | required |
| `gap_analysis` | Adversarial pre-implementation read of the issue | 0 or 1 | skip the pass |
| `review` | Independent code review of the diff before merge | 1+ | primary's own self-review only |
| `debug` | Owns root-cause investigations | 1 | primary |
| `issue_author` | Drafts and files issues (`create-issue`) | 1 | primary |
| `release` | Cuts releases | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice.

## Agent tokens

`claude` · `codex` · `gemini` (Antigravity). Adding another AI is one new
`agents/<token>/` adapter — see `docs/adding-an-agent.md`.

## Cross-agent invocation

When a workflow reaches a step owned by a *different* agent than the one driving,
it shells out to that agent's non-interactive entrypoint:

| Agent | Non-interactive invocation | Root config it reads |
|---|---|---|
| `claude` | `claude -p "<prompt>"` (or a native skill when Claude is driving) | `~/.claude/CLAUDE.md` |
| `codex` | `codex exec --cd <repo> -` (prompt on stdin) | `~/.codex/` + `AGENTS.md` |
| `gemini` | `agy -p "<prompt>"` (Antigravity CLI) | `~/.gemini/GEMINI.md` |

> **Note (codex timeout):** `codex exec` reads and reasons over the whole repo —
> it routinely takes **3–7 minutes**, well past a default 2-minute command
> timeout. Always give a cross-agent `codex exec` call a timeout of at least
> 7 minutes; a SIGTERM at 2 minutes wastes the pass, it is not a failure.

## Resolution order

For any role, a workflow resolves the responsible agent as:

1. The value in the repo's `agents.toml` `[roles]`.
2. Else the **global default manifest** installed at
   `~/.config/ai-dev-baseline/agents.toml` (written by `install.sh`).
3. Else the built-in default in the table above.

So a repo with no `agents.toml` still works — it inherits your global defaults.

## The default global manifest

`install.sh` writes a global default you can edit once and inherit everywhere:

```toml
[roles]
primary      = "claude"
gap_analysis = "codex"
review       = ["claude"]
debug        = "claude"
```

A repo overrides any subset by dropping its own `agents.toml`
(copy `templates/agents.toml`) and running `agent-init`.
