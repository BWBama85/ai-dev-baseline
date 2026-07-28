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

- **PR status** → `gh pr view <N> --json state,mergedAt` (not memory, not a stale
  local ref).
- **Issue status** → `gh issue view <N> --json state`.
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
claim it never supported. So the read and the assertion are **one operation**, not two:

```bash
state-assert.sh observe pr 137     # -> PR #137 was observed MERGED at 2026-07-28T05:22:27Z
state-assert.sh observe issue 138  # -> issue #138 was observed OPEN at 2026-07-28T05:22:28Z
```

**Pass the printed line through unchanged.** Empty stdout means *say nothing about that
entity* — never fall back on a remembered value, which is exactly the trust this practice
removes. The command fails closed: an unverifiable read prints nothing and exits non-zero.

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

Honesty about the boundary is part of the practice. These are the **executable** paths: a status
line a workflow *defines* is rendered atomically from a live read. **Free-form prose is not
mechanically enforced** — no hook can un-say a sentence that has already streamed, and a shell
classifier over arbitrary natural language (negation, quotation, prediction) would be theatre.
Portable per-agent enforcement is tracked separately as the enforcement-hooks layer.

So the rule for prose is a discipline, stated plainly: **do not volunteer a status you did not
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
