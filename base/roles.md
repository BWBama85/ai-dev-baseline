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
| `review` | Independent code review of the diff before merge | 1+ | the primary's own review pass |
| `debug` | Owns root-cause investigations | 1 | primary |
| `issue_author` | Drafts and files issues (`create-issue`) | 1 | primary |
| `release` | Cuts releases | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice. The `primary`'s own
mandatory self-review (`base/practices/self-review.md`) is the *floor* and is always
run; the `review` role is the **independent** pass layered on top. Left unset (or
empty), `review` defaults to the primary running that independent pass with its own
model-invokable tools — so an unconfigured repo still gets a completed review step,
never a bare self-review.

### Completion contract for delegated steps

A role delegated to another agent (or to a subagent) is a **step that must
complete**, not an optional extra. This binds `gap_analysis`, `review`, and any
cross-agent dispatch:

- **One bounded call; wait for it to return.** Give each dispatch a real timeout
  (≥7 min for `codex exec`) and **wait for the process to exit** (`codex exec` /
  `agy -p` / `claude -p`) or the tool to return (an Agent-tool subagent). **Never
  poll a background agent's output to infer whether it is "hung"** — the outcome is
  the call returning, not the byte count growing; that guess-and-recheck loop is
  itself the wasted time and is unreliable in both directions.
- **On timeout / error / hang:** abandon the call — a Bash timeout kills a
  `codex exec` / `agy -p` / `claude -p` process; an Agent-tool subagent has no PID to
  kill, so its error or timeout return *is* the terminal signal — then **retry once**
  and **fall back**: to another agent the role lists, or to a `general-purpose` Claude
  subagent running the same prompt (model-invokable whenever Claude drives; but it too
  can error, so it is a fallback, not a guarantee).
- **If nothing completes:** the step **failed** → block the run (write the workflow's
  blocked marker) or surface to the owner. Never mark a delegated step done on
  partial or empty output.
- **"Advisory" applies to *completed* findings, not to the step.** The implementer
  may disagree with a finding a delegated agent actually produced, documenting why. A
  missing, hung, or empty result is an **incomplete step**, not an advisory one.

## Agent tokens

`claude` · `codex` · `gemini` (Antigravity). Adding another AI is one new
`agents/<token>/` adapter — see `docs/adding-an-agent.md`.

## Cross-agent invocation

When a workflow reaches a step owned by a *different* agent than the one driving,
it shells out to that agent's non-interactive entrypoint:

| Agent | Non-interactive invocation | Root config it reads |
|---|---|---|
| `claude` | `claude -p "<prompt>"` (when Claude is the driving agent, the step runs in-process via **model-invokable** tools — an Agent-tool subagent and/or a model-invokable skill like `/simplify`; never a user-only skill such as `/code-review`) | `~/.claude/CLAUDE.md` |
| `codex` | `codex exec --cd <repo> -` (prompt on stdin) | `~/.codex/` + `AGENTS.md` |
| `gemini` | `agy -p "<prompt>"` (Antigravity CLI) | `~/.gemini/GEMINI.md` |

> **Note (codex timeout):** `codex exec` reads and reasons over the whole repo —
> it routinely takes **3–7 minutes**, well past a default 2-minute command
> timeout. Always give a cross-agent `codex exec` call a timeout of at least
> 7 minutes; a SIGTERM at 2 minutes is just too-tight a bound (re-run longer), not a
> failure. A genuine timeout at the *full* ≥7-min bound, though, is an **incomplete**
> invocation — retry → fall back per the completion contract above.

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
