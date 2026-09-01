# /implement-issue — the state protocol, in full

Read on demand from the skill's step 1/5 pointers. `SKILL.md` carries the operative summary;
this file carries the contracts and the reasoning. Nothing here changes what the commands do —
`{{IMPLEMENT_LIB}}` (`admit` / `release` / the step subcommands) is the mechanism, and
`scripts/check-implement-lib.sh` is what proves it.

## One run per checkout per agent — what is actually enforced

Two runs share one HEAD and fight over the checked-out branch, so a second run is refused rather
than accommodated. Preflight asks `{{IMPLEMENT_LIB}} admit {{STATE_DIR}}` before anything is
deleted; the run then holds a **run claim** (`gap-analysis.lock`, published create-or-fail) until
step 5 writes the marker that supersedes it. That boundary is what lets every later step read
"the marker exists" as "this run is live" (D40, D46).

**Scope is this agent's `{{STATE_DIR}}`**, so what is enforced is a second run of the *same*
agent. A Claude run and a Codex run never collide on these paths; they collide on HEAD, and only
partially — the branch check hard-errors once one of them has left the default branch, but two
agents starting concurrently while both are still on it both pass, and whichever branches first
moves the other's HEAD underneath it. This is not checkout-wide exclusion.

## The two marker files

- **`implement-issue-active.json`** — the in-flight marker, written in step 5 *after* the real
  branch exists (never before, or the gate's branch-mismatch guard silently disables the
  invariant). Each step updates `phase`; step 10's `open-pr` writes `prUrl`. Multi-issue: `.issue`
  is the comma-joined list and `.branch` carries every number.
- **`implement-issue-blocked.json`** — written by *you* only on a documented legitimate
  **post-branch** stop: the gate escape clause, a required review slot that cannot complete after
  retry + fallback, or a branch that already exists on remote. `branch`/`issue` are required and
  must match the active marker (the Stop-hook gate no-ops without a matching active marker), and
  `owner` is **copied from the active marker**, never recomputed. A gap-analysis stop is
  *pre-branch* — no marker exists to pair with, so surface it and stop cleanly without this file.

Stage every marker write inside `{{STATE_DIR}}/` (`.marker.tmp` → `mv`) so the rename is atomic.
Since #431 the marker has a reader beyond the Stop gate: after the harness compacts or resumes a
session, the `SessionStart` run-state hook reads it — and the artifact PATHS beside it — back
into context, so a run that lost its summary still knows its phase, branch, issues and where its
findings live.

## `owner` — which SESSION this run belongs to

`owner` names the session driving the run, not the checkout: every session in one clone sees the
same current branch, so a marker matched on branch name alone matches every session in that clone
(D46).

- **Write it when your harness exposes a session id; omit it when it does not.** Claude Code
  publishes one as `$CLAUDE_CODE_SESSION_ID` and repeats the same value as `session_id` in every
  hook's stdin payload, which is what lets the Stop hook tell its own run's marker from a
  sibling's.
- **Never substitute a pid.** The marker's writer is a tool-call shell and the hook is a separate
  process, so a pid manufactures mismatches instead of resolving them. No id available → no
  `owner` key.
- **An absent `owner` means "unowned"**, and is enforced by branch-name matching. Failing toward
  enforcement is deliberate: a marker that goes inert silently switches the no-stop-until-PR
  invariant off.
- **Ownership transfers to whoever is driving.** If you pick up an existing run — a resumed
  session, or a new one continuing this branch — and the marker's `owner` is not yours, re-stamp
  it to yours on your next phase update.
- **`owner` governs enforcement; staleness governs deletion.** Admission deliberately does not
  consult `owner`: a session is an actor, not a run, ownership is transferable, one session may
  legitimately invoke this workflow twice, and an absent `owner` reads as compatible — right for
  a hook deciding whether to speak, wrong for a starter deciding whether to delete (D46).

## `phaseHistory` (#243)

Every phase update re-stamps `owner` and **appends** to `phaseHistory`, in one command (the
`phase-update` snippet in SKILL.md). `.phase` stays the latest phase, so every existing reader
behaves identically; the history is what lets a later reader — the compaction summary (#431), or
a human asking where a slow run's time went — say what has happened rather than only where it is.
The append is **idempotent**: re-running the same phase write appends nothing when the last entry
already carries that phase, so the history records transitions, never repetitions. A marker
written before this field existed reads without error; its first update creates it.

## The claim: lifecycle, lease, and the release sites

From `admit` until step 5 the run holds the claim, and every stop in that window releases it
**inline** with the literal token (`{{IMPLEMENT_LIB}} release --token <token> {{STATE_DIR}}`) —
never via a helper function, because a fenced block may run as its own shell and a function
defined in one block does not exist in the next. The token is printed by the admission block
(`RUN_CLAIM_TOKEN=…`) precisely so *you* can carry it between blocks; if you cannot see that
line, the claim carries it: `jq -r .token {{STATE_DIR}}/gap-analysis.lock`.

**The claim is released at exactly three places:**

- **step 5**, immediately after the marker is written — the marker now covers liveness. Marker
  before release, never the reverse: for the instant between them both signals are live, which
  over-preserves, whereas releasing first leaves an uncovered window a concurrent `/cleanup`
  reads as a finished run.
- **step 4**, on the paths that stop the run (a BLOCKING finding you surface; a gap-analysis
  incompleteness that survives its retry).
- **step 2**, on a repo-scope or issue-state stop (`snapshot-issues` does this itself when passed
  `--token`).

**Do not release after the survey or gap dispatch returns.** The window the claim must cover is
longer than the dispatch — the findings still have to be read, and the marker does not exist
until step 5. Release early and a concurrent `/cleanup` sees no lock and no marker, classifies
the artifacts as a finished run's leftovers, and deletes the findings this run is about to act on.

**The lease (9000s / 2h30m) is a real trade.** A run killed between the take and a release
leaves the claim behind — fail-safe in the direction that matters (a stray claim only ever
*preserves* artifacts) and bounded: the next run breaks an expired claim with a NOTE. The
pre-marker window it covers is the survey dispatch (bounded at `ADB_SURVEY_TIMEOUT_SECS`, default
1200s and clamped at 1500s, one retry) plus the gap dispatch (2700s, one retry) plus reading the
findings — and every pre-marker subcommand (`snapshot-issues`, `dispatch-survey`,
`dispatch-gaps`) **renews the lease from its own start** — token-verified: a claim whose token
is not this run's refuses the subcommand (13), because after a reap-and-readmit it belongs to a
successor — so the 9000s bounds each step and the
gap to the next rather than the whole window: snapshot's `gh` reads and the triage between
dispatches are unbounded, and a fixed lease from `admit` let a live run outlive its claim. A **retry** of a dispatch re-runs only the dispatch subcommand;
it never re-takes the claim (the acquire is create-or-fail, and a second take is how `admit`
detects a concurrent run).

## What `admit` clears, and the containment rule

The marker, the blocked marker, the gap family (`gap-prompt.txt`, `gaps.md`, `gaps.err`,
`gaps-*.{md,err}`), the review family (`review-prompt.txt`, `review-prompt-stage.*` — the
mktemp before the rename publish, `review.md`, `review.err`,
`review-*.{md,err}`), the survey family (`survey-prompt.txt`, `survey.md`, `survey-trace.md`,
`survey.err`, `survey-*.{md,err}` — #435), the issue snapshots (`issue-<digits>.json/.assoc`)
and the documentation-duty records (`docs-consulted.tsv`, `docs-consulted-*.tsv`). They are
per-run data with one later reader — the compaction summary, which names their PATHS and never
their contents — and the most sensitive files this workflow writes: the prompts and snapshots
carry issue and private-repo context, and the `.err` files are an agent's whole exploration
stream. Left in place they outlive their run and a later pass reads them as its own.

That set must **contain** the `gaps`, `survey`, `review` and `issue` arms of `cleanup-lib.sh
state-scan`: a name `/cleanup` can sweep but preflight cannot clear is a stale artifact that a
fresh run's marker makes read as live. Containment, not equality — `state-scan` refuses names
holding a tab or newline, so `/cleanup` may sweep strictly fewer names, which is harmless.

(Growth *within* a run is bounded at the source: `role-dispatch.sh` caps a dispatched agent's
log at `ADB_DISPATCH_LOG_MAX_BYTES`, 256 KiB by default, `0` to disable. The cap covers the
agent's stream; the classified `role-dispatch:` line you read at the tail is emitted outside it
and always survives. The survey trace is that capped stream's sibling — call it "the dispatch
log", never "the full trace".)

## Why the snapshots are flat, repo-relative, and gitignore-checked

The issue snapshot and its provenance label are read back minutes later by three dispatches, and
they decide whether a dispatched agent is told the task came from a maintainer or a stranger.
`{{STATE_DIR}}` is repo-relative and per-agent, which is the boundary `admit` already enforces; a
shared host path (`/tmp`) is guessable from a public issue number and shared by every checkout on
the host. **Flat**, because `state-scan` enumerates regular files directly under the state
directory — a tidy-looking subdirectory is invisible to `/cleanup` and `admit` alike. And the
gitignore probe requires the **directory itself** to be ignored (the `…/state/` rule
`bin/agent-init` writes): the run's write-set includes generated names — `review-<slot>.{md,err}`,
a random `review-prompt-stage.*` — that no per-file rule set can cover, and a directory rule
covers every one of them by construction, so nothing this run writes can land in the working
tree one `git add -A` from being committed. Per-file rules, however complete, are refused (22).
