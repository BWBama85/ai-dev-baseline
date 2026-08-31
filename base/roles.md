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
| `survey` | Bounded pre-implementation repo survey (`implement-issue` step 2b, #435) | 0 or 1 | primary (`""` skips) |
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
never a bare self-review. **Be precise about what that fallback is worth, though:** when
`review` is unset the reviewer resolves to the primary, so the pass is *same-model* — the
implementer's own model, running its independent-review tooling over its own diff. It is
better than nothing and it is not independent, and the rung report says so.

**Point `review` at an agent that is not `primary` (#211).** The role's job is the word
in its own row — *independent* — and a reviewer that is the same model as the implementer
cannot supply it: that is the model checking its own work, which is the weakest review a
manifest can express. The two vendors' published guidance happens to agree on the split
from opposite directions: Anthropic's Opus 5 guidance asks that Claude **not** be given
explicit verification scaffolding (it self-corrects natively and over-verifies when told
to), while OpenAI's asks Codex for exactly the named-checklist, required-vs-optional pass
`implement-issue` step 8 sends a reviewer. So `templates/agents.toml` ships
`review = ["codex"]` beside `primary = "claude"`.

A same-agent slot is still **run**, not refused — a manifest may legitimately name one,
and a Codex-primary repo reviewing with Claude is the same split pointing the other way.
It is **labelled** *same-model (not independent)* in the close-out instead, so the
operator is never misled about what looked at the diff. Note this changes the shipped
**manifest** default only; the **resolver's** built-in fallback for an unset `review` is
unchanged (still the primary's own pass), so a repo with no manifest behaves as before.

**A reviewer that is not installed is not a reviewer that failed.** `review` names an
agent; it cannot make that agent's CLI exist. `role-dispatch.sh available <agent>` answers
that separately (0 = on PATH, 1 = known agent whose CLI is absent, 2 = not a token), and
`implement-issue` step 8 asks it **before** dispatching, so an absent CLI surfaces as the
configuration fact it is rather than as a 127 that arrives after the branch, the commits
and the gates. The step then reports which **rung** the project is on — independent
in-session review · deferred to the PR layer (an async reviewer in `[reviewers] bots`
gates the auto-arm) · none — and proceeds. It never fabricates a reviewer to fill the gap:
a second opinion from the model that wrote the diff is not a second opinion. `agent-init`
prints the same rung at setup time, from the same two readers.

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
complete**, not an optional extra. This binds `gap_analysis`, `survey`, `review`, and
any cross-agent dispatch:

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
  and, *except for `gap_analysis`* (below), **fall back** to another agent the role
  lists (it too can error, so it is a fallback, not a guarantee). **Report every
  fallback prominently** — a step running on its backup is a fact the operator must
  not have to dig for.
- **The fallback set is CROSS-MODEL only (#304).** A `general-purpose` subagent of the
  driving agent used to close that list; it is gone. The fallback is reachable only while
  that agent drives, so such a stand-in is the model that wrote the diff reviewing its own
  work — the arrangement `review`'s own row exists to avoid, arriving through the back
  door. It is also the same reasoning that already refuses to fabricate a reviewer for an
  **empty** slot, and a slot that *broke* is not a weaker case for it. When no cross-model
  stand-in is usable the step has **failed**; block or surface, and never fill it with a
  pass that reads as coverage in the close-out while supplying none.
- **`survey` completes or is dropped — it never blocks and never substitutes (#435).**
  The same bounded call and wait apply; on failure retry the assigned agent exactly once,
  then **continue without the survey** and say so. It is an accelerator, and blocking on
  it would make the loop slower than before it existed — the asymmetry with
  `gap_analysis` below is deliberate and stated in the workflow's failure policy.
- **`gap_analysis` never falls back to another agent.** Retry the assigned agent
  **exactly once**; if the second attempt also fails, **report the classified
  incompleteness and stop** (pre-branch, so no blocked marker — see the workflow's
  step 4). It **never substitutes** a different agent: doing so makes `agents.toml` say
  one thing while another agent does the work — which is exactly how a too-small bound
  spent three runs pretending to be a codex problem (#93). A too-small bound must never
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
  output = a legitimate skip — `gap_analysis` unset or `""`, and `survey = ""`; an UNSET
  `survey` resolves to the primary, #435). It **validates** the
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
review       = ["codex"]
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
bots = ["chatgpt-codex-connector", "gemini-code-assist", "copilot"]

# How many re-review rounds /resolve-pr-threads may request. Optional.
#   unset → the built-in 6;  0 → uncapped;  `--max-rounds <n>` overrides both
max_rounds = 6
```

`role-dispatch.sh bots` reads this (repo → global → the built-in default allowlist) and
`/resolve-pr-threads` derives the logins it may resolve from that **one** source. It is an
**exact** login allowlist, never a `[bot]`-suffix heuristic, so an unlisted account is never
auto-resolved.

**Login spelling — prefer the bare form.** GitHub reports the same App as `foo` (GraphQL) or
`foo[bot]` (REST). The merge guards normalize that suffix **one way only**, the API login toward
your declaration: a bare `foo` matches either spelling (portable, recommended), while `foo[bot]`
matches only `foo[bot]` — so a human account named `foo` can never satisfy a declared App. Both
directions matter, and normalizing the *declaration* too was a real fail-open (#173, superseding
#176). See `docs/roles-and-agents.md`.

**The same key also gates auto-merge (#134).** `role-dispatch.sh bots --comparable` reads it — through the
`--declared` tri-state reader it wraps — as **declared logins / explicit `[]` / undeclared, with no
default** — declared logins / explicit `[]` / undeclared — and
`/implement-issue` step 10 refuses to arm `gh pr merge --auto` until every declared reviewer has
reviewed the PR's **current head commit**. The two readers differ only on *unset*, deliberately:
a permissive default is harmless when deciding which threads to resolve and is exactly wrong as a
merge gate, so the gate fails closed on an undeclared repo. A repo with no async reviewer declares
`bots = []` and keeps unattended arming. See `docs/roles-and-agents.md`.

### `max_rounds` — the re-review round bound (#416)

`/resolve-pr-threads` does not merely resolve what is there; it asks the reviewer to look again and
goes round until the reviewer passes. `max_rounds` is that loop's bound, and it lives here because
it is a fact about how **this repo's declared reviewer** is driven.

A **round** is one trigger comment this mechanism posts to wake the reviewer after a fix is pushed.
The cap counts **every** trigger comment on the pull request, at any head — derived from the PR
rather than from local state, which is what makes it survive a restarted or resumed session with no
counter to reset.

**A human's own `@codex review` comments spend the same budget**, and that is by design: the
mechanism and a person post the same text from the same login, so no read can tell them apart, and a
cap that tried would need an authorship signal GitHub does not provide. Say it plainly rather than
letting an operator discover it as a surprise cap.

Precedence is `--max-rounds <n>` > `[reviewers] max_rounds` > the built-in **6**, and a malformed
value is a **hard error** rather than a silent fall-back to that built-in — an operator who wrote a
bound and got the default has a cap they did not choose and no way to notice. It layers repo →
global like every other manifest key.

**`0` means uncapped, at both surfaces (#420).** It is the `[gates] "" disables` precedent applied
here — a zero-value sentinel disabling a mechanism, spelled in the config surface's own vocabulary —
so a project can declare *"run until clean, no round ceiling"* explicitly rather than by picking a
number and hoping it is big enough. **It is the only sentinel:** `-1`, `1.5`, `00`, an empty value
and any non-integer stay hard errors, in both directions, never a silent fallback.

**The trade is deliberate and is recorded as a deviation** (`.ai-dev-baseline/decisions.md`, D88),
because the round cap is the loop's only *overall* bound and uncapping it means a reviewer that
never comes back clean keeps the loop going. What still holds: **per-head idempotency** — at most
one request per (reviewer, head), so every round costs an intervening head-moving push plus a review
arrival or a watch timeout, and the loop cannot tight-spin — and **every per-round deadline**.
Uncapped rounds, never unbounded waits.

**The default is 6 because the field measured 3 wrong.** The first productive multi-round resolve on
an adopting repo — every round pushing fixes, round 5's fixes breeding three of round 6's findings —
hit the cap at 3, because four requests already existed and all four were the operator's own manual
kick-starts. `role-dispatch.sh max-rounds` reads it; `pr-watch.sh request-review` owns the built-in.

## Scope: bespoke orchestration stays project-scoped

The role model is a **static declaration** (which agent fills each role) plus the async-bot
allowlist above — deliberately *not* a dynamic orchestration engine. Bespoke per-project patterns
— dynamic mid-task consult agents, worktree-parallel implement swarms, a hardened per-repo
agent-CLI wrapper — are **out of scope for the baseline**. They live as **project-scoped skills**
(the `handling-the-unknown` prescribed home for "a workflow that genuinely diverges"), not as new
`agents.toml` vocabulary. The baseline gives every project the same resolvable roles and the same
dispatch helper; it does not try to replace a project's own orchestrator.
