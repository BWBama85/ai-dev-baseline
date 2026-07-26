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
  (the 45-min hang backstop `role-dispatch.sh` applies) and **wait for the process to
  exit** (`codex exec` / `agy -p` / `claude -p`) or the tool to return (an Agent-tool
  subagent). **Never poll a background agent's output to infer whether it is "hung"** —
  the outcome is the call returning, not the byte count growing; that guess-and-recheck
  loop is itself the wasted time and is unreliable in both directions.
- **Dispatch in the background when the harness caps foreground calls.** "Background"
  means the harness's *own* detached-execution facility, which reports the call's
  terminal status back to you — not a shell `&`. A backgrounded `&` inside one
  foreground call is still inside that call's cap, and a *later* shell cannot `wait` on
  an earlier shell's child, so `&` buys nothing. Backgrounding changes **where** the
  call runs, never the wait-for-terminal-state rule above.
- **On timeout / error / hang:** abandon the call — a Bash timeout kills a
  `codex exec` / `agy -p` / `claude -p` process; an Agent-tool subagent has no PID to
  kill, so its error or timeout return *is* the terminal signal — then **retry once**
  and, *except for `gap_analysis`* (below), **fall back**: to another agent the role
  lists, or to a `general-purpose` Claude subagent running the same prompt
  (model-invokable whenever Claude drives; but it too can error, so it is a fallback,
  not a guarantee). **Report every fallback prominently** — a step running on its
  backup is a fact the operator must not have to dig for.
- **`gap_analysis` never falls back to another agent.** Retry the assigned agent
  **exactly once**; if the second attempt also fails, **report the classified
  incompleteness and stop** (pre-branch, so no blocked marker — see the workflow's
  step 4). Substituting a different agent here would make `agents.toml` say one thing
  while another agent does the work — which is exactly how a too-small bound spent
  three runs pretending to be a codex problem (#93). A too-small bound must never
  silently demote the owner's chosen agent. This arm is finite and the backstop is
  hard (it escalates TERM → grace → KILL), so removing the fallback cannot deadlock a
  run. The `review` role keeps its fallback: its slots are independent, and a
  documented substitution there loses no configuration meaning.
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

> **Note (dispatch bound):** `codex exec` reads and reasons over the whole repo. At high
> reasoning effort a non-trivial diff **routinely exceeds 10 minutes**, so
> `role-dispatch.sh` gives every invocation a **45-minute (2700 s)** bound, overridable
> via `ADB_DISPATCH_TIMEOUT_SECS` — though a stock clone should never need to set it.
>
> Treat that bound as a **hang backstop, not a work budget**: it exists to stop a wedged
> process, so it sits far above the longest legitimate run rather than near the typical
> one. Setting it near typical runtime is what made ordinary passes look like failures
> (#93). The backstop escalates **TERM → grace → KILL**, so it always terminates.
>
> The bound applies to **every** agent and role this helper dispatches, not just codex.
> Because a harness may cap a *foreground* call well below it, dispatch long passes in
> the background (see the completion contract above) — otherwise the outer cap, not this
> bound, is what actually fires. A kill by an outer bound reports as SIGTERM (rc 143);
> our own backstop reports as rc 124; anything else is a real agent error. Those are
> different failures with different fixes, so `role-dispatch.sh` names which one
> happened instead of collapsing them into "the agent failed".

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
  documented flags and the 45-min hang backstop, returning only that agent's **clean final
  message** on stdout. For `codex` it uses `--output-last-message`, so the exploration stream
  never contaminates the captured findings. On a non-zero exit it prints one **classified**
  diagnostic to stderr — our backstop (124) vs an outer bound's SIGTERM (143) vs a real agent
  error — so a bound problem is never mistaken for an agent problem. A multi-agent `review` role
  is refused on purpose: use `resolve` then a per-slot `invoke <token>` loop, so a same-agent slot
  stays in-process and each slot keeps its own retry/fallback (the completion contract above).

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
