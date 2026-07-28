# Verify mutable state before asserting it

**Never state or act on volatile external status from memory, context, or a stale
local ref. Re-check the authoritative source at the moment you assert or act.**

Mutable external state — a PR's open/merged/closed status, whether a branch is
merged, an issue's open/closed, CI green/red — **changes out from under you.**
Narrating or acting on it from an earlier turn's memory, or from an unsynced local
git ref, is a correctness bug: it produces flatly-wrong claims ("PR #N is still
open" when it merged an hour ago) and destroys trust.

## Immutable vs mutable

Distinguish the two, and treat them differently:

- **Immutable facts** — code structure, file locations, function names, project
  conventions. Safe to recall from context; they don't change between the moment
  you read them and the moment you use them.
- **Mutable state** — PR/branch/issue/CI status, remote refs, deploy versions.
  **Always re-check**, however confident memory feels. Re-checking costs one `gh`
  or `git` call; a wrong assertion costs the whole session's trust.

## Re-check at the point of assertion

Query the authoritative source *immediately before* you assert or act on it — not
a `git branch --merged` against an unsynced local default, not a value you
remember from earlier in the session:

- **PR / issue status** → see *"Render the sentence from the read, in one step"* below. Do **not**
  reach for a bare `gh issue view <N> --json state`: it flattens a `NOT_PLANNED` close into a plain
  "closed", which reads an *abandoned* issue as a *delivered* one.
- **Branch merged?** → a **freshly-fetched** `git fetch --prune` then
  `git branch --merged origin/<default>` (classify against the remote tip, not a
  lagging local branch).
- **CI status** → `gh run` / `gh pr checks <N>`.

If you are about to perform an **outward-facing mutation** (delete a branch, reply
on a thread, merge, comment "done"), re-check the state that gates it right before
the mutation — a status captured at the start of a long task may have changed by
the time you act on it.

## Automated hooks and gates are in scope too

This is not only about an agent's prose. **Any automated actor that gates a decision on
mutable external state must re-verify it live — a Stop hook, a CI gate, a script — not
just the agent narrating.** Mutable state is mutable regardless of who reads it. A hook
that concludes "the run is complete because a `prUrl` is recorded in a marker file" is
asserting a PR's open/merged/closed status from stored context, exactly what this practice
forbids: the PR may have been closed without merging since the value was written. Such a
hook must re-check the authoritative source (`gh pr view … --json state,mergedAt`) at the
moment it acts, and **fail closed** — when the live state can't be verified, it must NOT
fall back to trusting the stored value (that is the stale-state trust this practice exists
to remove); it holds the gate and surfaces the uncertainty.

## Render the sentence from the read, in one step

Re-reading is necessary but **not sufficient**: a value fetched into a variable can still go
stale before the sentence that quotes it, and a correct read can still be paraphrased into a
claim it never supported. So the read and the assertion are **one operation**, not two — the
`state-assert.sh` module's `observe` subcommand performs the read *and* renders the finished
sentence, e.g. `PR #137 was observed MERGED at 2026-07-28T05:22:27Z`. Each workflow carries the
invocation for its own agent; this document states the rule, not the path.

**Pass the printed line through unchanged.** Empty stdout means *say nothing about that
entity* — never fall back on a remembered value, which is exactly the trust this practice
removes. It fails closed: an unverifiable read prints nothing and exits non-zero.

**Observations are past-tense by construction, and that is not a style rule.** A read can only
support a claim about the moment it happened. "PR #137 **is still** open" and "the gate **will**
hold" are claims about the future that no read can support — the second one shipped, and the PR
merged 29 seconds later. State what was observed and when; if you need to claim a future effect,
name the *observed* fact that implies it (an exit code, an action taken) instead.

**One home per entity kind** — never re-derive another's model:

| Question | The one command that answers it |
|---|---|
| PR / issue state | `state-assert.sh observe pr\|issue <n>` |
| Is this branch merged? | `cleanup-lib.sh branch-verdict` (models squash/rebase, exact-head, containment) |
| Is the branch green? | `roadmap-lib.sh branch-health` (Checks API + commit-status API, fail-closed) |

## What this does *not* claim to enforce

Honesty about the boundary is part of the practice, so state it exactly rather than flatteringly.

**`observe` makes a stated status correct; it cannot make anyone state one.** Nothing couples its
exit code to an action. Compare the two nearest siblings: the pre-arm review guard's exit code
gates an actual `gh pr merge --auto`, and `/cleanup`'s branch verdict decides whether a branch
survives — those are *structural*, because a wrong answer stops the machine. This renders optional
narration. So the honest line is not "defined status lines are enforced, free-form prose is not";
it is that **both** depend on someone choosing to make the call. What the command removes is the
*stale or paraphrased* sentence, not the *unsourced* one.

Mechanical enforcement of free-form prose is a separate problem and is **not** solved here: a Stop
hook fires only after the text has already streamed, so it could force a correction but never
prevent the claim, and a deterministic shell classifier over arbitrary English — negation,
quotation, hypotheticals, predictions — would be theatre beyond a small documented grammar. That
work belongs to the portable enforcement-hooks layer, which should treat *nothing* below as
already covered.

So the rule for prose remains a discipline, stated plainly: **do not volunteer a status you did not
just read.** If it is worth saying, it is worth one `observe` call — and if that call fails, the
honest output is silence.

## Why

Repeated stale-state assertions — narrating a merged PR as "still open" from a
stale local `main` or from earlier-in-session memory — are a recurring correctness
bug. A wrong claim about volatile state is worse than a slow one: it looks
authoritative and gets acted on. Re-checking the source of truth at the moment of
use makes the claim correct by construction.

Prose alone had already failed twice in one session with this practice loaded in context, which
is why the read-and-render step is a command rather than another paragraph — the same move that
turned the dependency-edge rule, the release-readiness ladder and `/cleanup`'s predicates from
remembered rules into tested code.
