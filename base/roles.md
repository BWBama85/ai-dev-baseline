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
| `release` | Cuts releases — **project-owned**, see below | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice. The `primary`'s own
mandatory self-review (`base/practices/self-review.md`) is the *floor* and is always
run; the `review` role is the **independent** pass layered on top. Left unset (or
empty), `review` defaults to the primary running that independent pass with its own
model-invokable tools — so an unconfigured repo still gets a completed review step,
never a bare self-review.

### `release` is a project-owned role — the baseline ships no `/release`

The baseline **names** `release` and resolves it like any other role, but deliberately
ships **no `/release` workflow**, and will not (issue #3): release schemes vary too much
for a generic skeleton to be right (SemVer vs CalVer, changelog vs none, tag vs image vs
zip), and a release is the one workflow whose mistakes are published under a permanent
tag. Write your own project-scoped `/release` — the `handling-the-unknown` prescribed home
for a workflow that genuinely diverges.

The one part that belongs in the law rather than the guide: **`[roles].release` names the
executor, not an implementation.** Setting `release = "codex"` installs nothing and
changes no behavior on its own — it is a declaration your release skill must actively
honor, by calling `role-dispatch.sh resolve release` and shelling out with
`role-dispatch.sh invoke release` when the token is not the agent already driving. A
project skill that skips that lookup silently ignores the manifest: a role is only as real
as its consumer.

The evidence for the decision, the verified skill paths per agent, and a worked dispatch
example are in `docs/roles-and-agents.md`; the decision record is `.ai-dev-baseline/decisions.md`
(D7).

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
- **A step is complete once its call returns a result.** A reviewer that runs to the
  end and reports **no findings** is a clean pass — proceed to triage. Only a call
  that **never returned a result** (crashed, hung, or was killed) is incomplete; if
  nothing completes, the step **failed** → block the run (write the workflow's blocked
  marker) or surface to the owner. Never mark a step done on an *absent* result — but
  do not mistake an empty *finding list* for an absent result.
- **"Advisory" applies to *completed* findings, not to the step.** The implementer
  may disagree with a finding a delegated agent actually produced, documenting why —
  and "no findings" from a completed reviewer is itself a valid, completed result. A
  call that *never returned a result* (missing, hung, crashed) is an **incomplete
  step**, not an advisory one.

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

## Runtime dispatch helper

`scripts/lib/role-dispatch.sh` is the programmatic embodiment of the resolution order below and
the invocation table above — installed beside `project-gates.sh` under every agent's
`scripts/lib/`, so a workflow calls it instead of re-deriving the same lookup + CLI incantation
by hand in each skill:

- `role-dispatch.sh resolve <role>` prints the resolved agent token(s), one per line (empty
  output = a legitimate skip — only `gap_analysis` resolves that way). It **validates** the
  manifest as it resolves: an unknown agent token, or an explicit empty `review = []`, is a hard
  error — never a silent fall-through to the next resolution layer or a degraded default.
- `role-dispatch.sh invoke <role|agent>` (prompt on stdin) runs one agent's CLI with the
  documented flags and the ≥7-min codex bound, returning only that agent's **clean final
  message** on stdout. For `codex` it uses `--output-last-message`, so the exploration stream
  never contaminates the captured findings. A multi-agent `review` role is refused on purpose:
  use `resolve` then a per-slot `invoke <token>` loop, so a same-agent slot stays in-process and
  each slot keeps its own retry/fallback (the completion contract above).

## Resolution order

For any role, a workflow resolves the responsible agent as:

1. The value in the repo's `agents.toml` `[roles]`.
2. Else the **global default manifest** installed at
   `~/.config/ai-dev-baseline/agents.toml` (written by `install.sh`).
3. Else the built-in default in the table above.

So a repo with no `agents.toml` still works — it inherits your global defaults. An invalid
value at any layer (an unknown token, an empty `review = []`) is surfaced as an error, not
silently skipped down to the next layer.

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

## Review: in-session agents vs. async external bots

The `review` role lists **in-session** reviewers — agent tokens invoked via their CLI while the
run is live. A repo may *also* be reviewed by an **async external bot**: a GitHub App that posts
review threads *after* the PR opens (e.g. the Codex connector `chatgpt-codex-connector`, or a
`…[bot]` reviewer). That is a different kind of reviewer — no CLI to invoke, it arrives later and
is cleared by `/resolve-pr-threads` — so it has its own manifest home, `[reviewers]`:

```toml
[reviewers]
# Async external-bot reviewer logins (GitHub App logins that post threads after the PR opens).
# /resolve-pr-threads auto-resolves ONLY threads whose author login is in this allowlist.
#   unset → the built-in default set of common review bots
#   []    → disable bot-thread auto-resolution entirely
bots = ["chatgpt-codex-connector", "gemini-code-assist[bot]", "copilot[bot]"]
```

`role-dispatch.sh bots` reads this (repo → global → the built-in default allowlist) and
`/resolve-pr-threads` derives the logins it may resolve from that **one** source. It is an
**exact** login allowlist (never a `[bot]`-suffix heuristic), so it can never match — and never
auto-resolve — a human-authored thread.

## Scope: bespoke orchestration stays project-scoped

The role model is a **static declaration** (which agent fills each role) plus the async-bot
allowlist above — deliberately *not* a dynamic orchestration engine. Bespoke per-project patterns
— dynamic mid-task consult agents, worktree-parallel implement swarms, a hardened per-repo
agent-CLI wrapper — are **out of scope for the baseline**. They live as **project-scoped skills**
(the `handling-the-unknown` prescribed home for "a workflow that genuinely diverges"), not as new
`agents.toml` vocabulary. The baseline gives every project the same resolvable roles and the same
dispatch helper; it does not try to replace a project's own orchestrator.
