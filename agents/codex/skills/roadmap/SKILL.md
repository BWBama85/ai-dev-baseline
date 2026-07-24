---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/roadmap.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: roadmap
description: Maintain the build roadmap and emit the next /implement-issue batch. Locates one canonical roadmap artifact (a `roadmap`-labeled issue), reconciles it against the live tracker, and outputs the next unblocked, one-branch bundle of issue IDs. Bootstraps the artifact if none exists. Works in any repo with a GitHub issue tracker.
---

# /roadmap

Close the development loop. After a batch merges — `/implement-issue … → PR → merge →
/cleanup → /clear` — run `/roadmap` and it tells you the **next batch to implement**,
grouped so the batch fits one branch, so you immediately run `/implement-issue x y z`.

It maintains a single, always-current roadmap artifact, turning the backlog into a
self-draining queue: as long as **implementable** open work remains, every run yields a next
batch; when work is only blocked, in-flight, or already-satisfied-but-open it says so (naming
the blocker or the flag) instead of fabricating one; and when no open issue remains it reports
"roadmap complete."

This automates, deterministically, the roadmap maintenance done by hand today (a pinned
roadmap issue). It is `gh`-based and works in any repo with an issue tracker.

## What this skill does NOT do

- **It never implements.** It only reads the tracker and updates the roadmap artifact,
  then prints a `Next:` command for *you* to run. No branches, no code edits, no PRs.
- **It never duplicates milestone membership.** Which milestone an issue belongs to lives
  in the milestones and is read live from `gh` every run. The artifact holds only what the
  tracker cannot express: **ordering, branch-bundles, and dependency edges** (the DRY split
  — see the schema).
- **It never asserts stale state.** Every PR / issue / label read is a fresh `gh` call at
  the moment of use (`base/practices/verify-before-asserting.md`), and the selected bundle
  is re-checked immediately before it is emitted.
- **It never trusts a stored residual as truth.** An issue's done-ness is re-derived from
  ground truth every run (the step-4 evidence ladder), never read off the artifact's own
  stored note — so a still-open issue whose work already shipped elsewhere is caught and
  surfaced, not emitted (`base/practices/verify-before-asserting.md`).

## The roadmap artifact (one prescribed home)

**The canonical home is the single open GitHub issue bearing the `roadmap` label.** There
is exactly one; the skill reads and writes it exclusively. (A file such as `ROADMAP.md` is
deliberately *not* used — maintaining a tracked file would require a branch + PR every run,
which conflicts with the post-`/cleanup`, post-`/clear` loop this skill serves.)

The issue body carries a machine marker on its first content line so the skill can locate,
parse, and rewrite it deterministically:

```markdown
<!-- ai-dev-baseline:roadmap:v1 -->
<!-- destination-label: v1 -->
<!-- ^ optional: when present AND the repo has that label, each run reports "v1: N blocker(s)
     open" (step 6, "Destination report"). Delete the line to disable. -->
# Build roadmap

Order + branch-bundles + dependency edges. Milestone membership is **not** duplicated here
(it lives in the milestones, read live from `gh`). This artifact holds only what the tracker
can't: the order to build in, which issues share a branch, and the blocking edges between them.

## Phases (ordered)

1. M1: Foundation
2. M2: …
   <!-- phase order = milestone build order; foundational/cross-cutting before polish -->

## Bundles

<!-- One row per branch-bundle: issues that share a subsystem/files → one branch, so a branch
     never edits the same file twice. `Issues` lists the members (this is the roadmap's own
     grouping data, NOT milestone membership).
     `Status` ∈ ready | blocked | in-flight | tracker-only | done. -->

| Bundle | Issues      | Subsystem      | Depends on | Status  |
| ------ | ----------- | -------------- | ---------- | ------- |
| B1     | #5, #19     | gates          | —          | ready   |
| B2     | #7          | dogfood        | —          | ready   |
| B3     | #39         | workflows      | B-home     | blocked |

## Dependencies

<!-- Explicit edges only. An edge exists when an issue body says "Depends on #N" /
     "Blocked by #N", or when declared here. `Refs #N` is NOT a dependency. -->

- #39 depends on #32

## Reconcile flags

<!-- Open issues that reconcile (step 4) proved must NOT be emitted as ready, plus canceled
     dependency edges. One row per issue, ordered by ascending issue number and deduped, so
     identical runs render identically. `Kind` ∈ tracker-only | owner-review | dep-canceled
     (a dep-canceled row's `Issue` is the canceled prerequisite; its `Action` names the
     dependent bundle to review). `Evidence` is concise ground-truth proof — the satisfying PR /
     owning issue, or "closed NOT_PLANNED" — with NO volatile timestamps. `Action` is the owner
     step. Rows here are never bundled or emitted. -->

| Issue | Kind         | Evidence                                       | Action                     |
| ----- | ------------ | ---------------------------------------------- | -------------------------- |
| #35   | tracker-only | acceptance shipped in PR #47; residual → open #48 | close #35 (superseded)  |

## Done (recent)

- ~~#34~~ — merged (Wave-1 foundation)
```

`Status` values, evaluated **in this order** (first match wins, so every bundle gets exactly one
— no gaps, no ambiguity): `done` (every member closed) → `in-flight` (a member has an open PR;
frozen — never emitted or re-scoped) → `tracker-only` (**no member is still implementable** —
every still-open member classified `tracker-only`/`owner-review` in step 4, so nothing is left to
build; surfaced to the Reconcile flags, never emitted) → `blocked` (a dependency is still open) →
`ready` (≥1 implementable member, all deps done, no in-flight member).

## Steps

### 1. Preflight

Ensure `gh` is authenticated and you are inside the target repo. `gh` list commands have
finite default page sizes — always pass an explicit `--limit` large enough to cover the
backlog (e.g. `--limit 200`) and treat any `gh` error as a **hard stop**, never a silent
empty result (a truncated or failed list must not look like "no open issues").

```bash
command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated"; exit 1; }
# Scratch for the roadmap body goes to a TEMP file, never the repo. /roadmap runs in arbitrary
# repos, many of which don't gitignore .codex/state/ — writing there would leave untracked
# files and dirty the worktree before the next implementation batch.
ROADMAP_BODY="$(mktemp -t roadmap-body.XXXXXX)"
```

### 2. Locate the canonical roadmap artifact (deterministic)

```bash
ROADMAP_NUM="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number')"
COUNT="$(printf '%s\n' "$ROADMAP_NUM" | sed '/^$/d' | wc -l | tr -d ' ')"
```

The "hard-stop on any `gh` error" rule from step 1 has one exception here: a repo that has
never created the `roadmap` label. Treat a *label-not-found* error on this specific query as
**zero results** (the bootstrap path), not a failure — it is distinct from a genuine
auth/API error, which is still a hard stop.

Branch on the count — this is the whole split-brain contract:

- **Exactly one** → that issue is the home. Go to step 4 (reconcile + advance).
- **More than one** → **ambiguous; STOP.** Two `roadmap`-labeled issues is a split brain
  the skill must never guess through. List them and ask the owner to retire one.
- **Zero** → go to step 3 (adopt-or-bootstrap). Do **not** create a second artifact if a
  pre-existing one is merely unlabeled — adopt it first.

### 3. Adopt-or-bootstrap (only when zero labeled roadmaps exist)

Before creating anything, look for a **pre-existing** roadmap the repo maintained by hand —
so a repo already running a pinned roadmap issue (that predates this skill) is *adopted*, not
duplicated:

```bash
# Pre-existing hand-maintained roadmaps: an issue whose body carries the marker, or whose title
# begins with "Roadmap". Collect ALL matches — never `head -n1` an arbitrary one.
CANDS="$(gh issue list --state open --limit 200 \
  --json number,title,body \
  --jq '.[] | select((.body|test("ai-dev-baseline:roadmap")) or (.title|test("^Roadmap"))) | .number')"
NCAND="$(printf '%s\n' "$CANDS" | sed '/^$/d' | wc -l | tr -d ' ')"
```

- **Exactly one candidate** → **adopt it:** add the `roadmap` label (creating the label if the
  repo lacks it), ensure the marker is present in its body, and pin it if unpinned. It is now
  the canonical home. Then reconcile it (step 4).
- **More than one candidate** → **ambiguous; STOP.** This is the same split-brain condition as
  multiple *labeled* roadmaps (step 2) — never pick arbitrarily. List the matches and ask the
  owner to retire all but one (or label the real one `roadmap`), then re-run.
- **No candidate** → **bootstrap a fresh one:**
  1. Read **all** open issues + milestones live (`gh issue list --state open --limit 200
     --json number,title,labels,milestone,body`; `gh api` for milestones), **excluding the
     roadmap issue itself** once it exists.
  2. Group into phases by milestone build order (foundational/cross-cutting before polish),
     order by dependency, and bundle by shared subsystem/files (see step 5's rules).
  3. Write the artifact body (schema above) to a scratch file and create the issue:
     ```bash
     gh label create roadmap --description "The build roadmap (ai-dev-baseline /roadmap)" --color 0e8a16 2>/dev/null || true
     gh issue create --title "Roadmap & execution order" --label roadmap --body-file "$ROADMAP_BODY"
     # then pin it (GraphQL pinIssue) so it's easy to find
     ```

### 4. Reconcile against the live tracker (no drift)

Read the artifact body and the **fresh** tracker state, then bring the artifact into sync.
Reconciliation is deterministic — the same tracker state always produces the same artifact:

- **Mark done.** An issue is *done* only when its **issue** is CLOSED as completed
  (`state == CLOSED` and `stateReason` is not `NOT_PLANNED`). A merged PR alone is **not**
  proof — a PR may `Refs #N` and partially implement an issue that correctly stays open. Move
  a bundle whose every member is done to the `Done (recent)` list; drop closed members from a
  partially-done bundle.
- **Verify implementable residual — from ground truth, never the stored note.** A still-OPEN
  issue is **not** automatically implementable: its work may already have shipped even though
  the issue is open (core landed under another PR, residual handed to a follow-up — the exact
  case that made this skill recommend an already-satisfied issue). Run this classification on
  **every** open non-roadmap issue, not only the members of `ready` bundles — a candidate that
  skips the check is the whole bug. It reduces each to one of three states:
  - **implementable** — its acceptance criteria are **not** yet satisfied on the default
    branch and nothing proves they shipped elsewhere. The ordinary case: it stays in its
    bundle and is eligible to emit, no matter what a stale note claims.
  - **tracker-only** — **positive proof** its implementable acceptance is already met: either
    every acceptance criterion is satisfied on the default branch, **or** the residual was
    explicitly handed to another issue that independently owns it and that issue is **open**
    (residual still tracked there) **or closed as completed** (residual shipped). Move it to the
    **Reconcile flags** as `tracker-only` (record the satisfying PR / owning issue) and recommend
    closing it — **never emit it as ready.**
  - **owner-review** — prior delivery is *suggested but not proven* by one of these enumerated
    inconclusive cases: the acceptance can't be settled from the default-branch read (not
    machine-checkable), the residual is only **partially** transferred, or the hand-off target is
    **missing / closed `NOT_PLANNED` / circular**. Flag it as `owner-review` — **never emit it as
    ready, and never guess** a no-op into a batch.

  **Evidence precedence (ground truth, strongest first).** The artifact's own stored residual
  is a *hint to re-verify, not proof*; a bare `Refs #N` or a stale comment can never by itself
  establish done-ness — require positive proof:
  1. the issue's acceptance checklist vs the default branch **at its freshly-fetched tip** —
     run `git fetch --prune origin` once at the start of reconcile, then inspect **read-only**
     (`git show origin/<default-branch>:<path>`, or `gh api` for the same live content — never a
     checkout, which the skill must not do; it may only write the scratch body file). The fetch
     is **mandatory**: this skill runs right after `merge → /cleanup → /clear`, so an unfetched
     local `origin/<default>` still lags the just-merged batch — reading it would re-introduce
     the exact miss this fix prevents (an issue the batch just satisfied still looks unshipped);
  2. **merged/closing** PRs that actually satisfy that acceptance (`Closes #N`, "landed in
     PR #M") — a merged PR is proof only when it *meets the criteria*, not when it merely
     mentions the issue;
  3. the issue's comments and linked follow-up issues (an explicit deferral, e.g. "residual
     tracked in #48").

  When the evidence at (1)–(3) is **inconclusive** (an owner-review case above), classify
  **owner-review**, never implementable — an unverifiable candidate is surfaced, not silently
  emitted. A `tracker-only` or `owner-review` classification removes the member from emission but
  **does not block** the bundles behind it: other genuinely-ready bundles still advance (step 6).
- **Slot new issues.** Any open issue not already in a bundle is placed into the right
  phase/bundle (by milestone + subsystem), never left orphaned. An unmilestoned issue is
  flagged and placed by inference — surfaced, never silently dropped.
- **Reconcile refs by *close reason*.** Drop a closed issue from its bundle. For **dependency
  edges**, the reason matters: a prerequisite closed **as completed** satisfies the edge (drop
  it — the dependent is now unblocked), but a prerequisite closed **as `NOT_PLANNED`** was
  *canceled*, which does **not** satisfy the dependent. Never silently drop a `NOT_PLANNED`
  edge — that would make the dependent bundle look unblocked when its prerequisite was
  abandoned. Keep the edge and record it in the **Reconcile flags** section as `dep-canceled`
  ("dependency #N canceled — bundle B needs review") until the roadmap is explicitly adjusted.
- **Persist the grouping.** Bundles are written back to the artifact so the grouping is
  stable and reproducible across runs — not re-inferred (and re-shuffled) every time.

Rewrite the issue body via `gh issue edit "$ROADMAP_NUM" --body-file "$ROADMAP_BODY"`.

### 5. Grouping & ordering rules (deterministic)

Apply these in order; every tie has a stable break so two runs agree:

1. **Dependencies first.** Never place a bundle before a bundle it depends on. An edge is
   **explicit only**: an issue body that says `Depends on #N` / `Blocked by #N`, or an edge
   declared in the artifact's Dependencies section. `Refs #N` is a cross-reference, **not** a
   dependency. If edges form a cycle, surface it and break the cycle at the lowest issue
   number, noting the break.
2. **Bundle by shared subsystem/files.** Group issues that touch the same subsystem so a
   branch never edits the same file twice. Infer from issue bodies, cross-refs, and
   touched-path hints — but **ignore generated fan-out** (the rendered root docs and skills
   that *every* practice/workflow change regenerates), or every issue looks like it touches
   the same three files and the whole backlog collapses into one mega-bundle. Keep bundles
   small (soft cap ~4 issues; note when a subsystem legitimately exceeds it).
3. **Importance.** Order phases by milestone build order and any priority labels;
   foundational / cross-cutting / high-leverage before polish.
4. **Stable tie-break.** When ordering is otherwise equal, order by ascending issue number,
   so the output is identical on repeated runs with no tracker change.

### 6. Advance — emit the next batch

Pick the next bundle whose `Status` is `ready`: all its dependency bundles/issues are done,
and **no member has an open PR** (an in-flight bundle is frozen and skipped whole — a running
PR must never have its scope expanded by a newly-filed issue). **Re-check the selected
bundle's members against a fresh `gh` read immediately before emitting** (`verify-before-
asserting.md`) — an issue may have closed or gained a PR since step 4. Fetch the fresh
open-issue and open-PR sets **once** and filter locally, rather than spending two network
round-trips per member:

```bash
OPEN_ISSUES="$(gh issue list --state open --limit 200 --json number --jq '.[].number')"
OPEN_PRS="$(gh pr list --state open --limit 200 --json number,body)"
# A member #N is still emittable iff it is in $OPEN_ISSUES AND no open PR references it:
#   printf '%s\n' "$OPEN_ISSUES" | grep -qx "$N"                       # must be open
#   printf '%s' "$OPEN_PRS" | jq -e --arg n "$N" 'any(.body|test("#"+$n+"\\b"))'  # must be empty
```

The freshness re-check is **not only** open/closed + open-PR status — **re-run the
implementable-residual classification (step 4) on each selected member too**, because acceptance
can land between reconcile and emit. Drop any member that is now `tracker-only` or `owner-review`
to the Reconcile flags and emit only the members still classified `implementable`. If that empties
the bundle, skip to the next `ready` bundle — **never emit a bundle with zero implementable
members** (a flagged candidate never blocks a genuinely-ready bundle behind it).

Then output the batch and a one-line rationale, prefixed by the destination line (below):

```
v1: 1 blocker open
Next: /implement-issue 5 19
Why:  B1 (gates) — unblocked, no in-flight PR, foundational for M2.
```

**Destination report (finish line) — configured, never hardcoded.** If the artifact carries a
`<!-- destination-label: LABEL -->` marker, prefix **every** run's output — the `Next:` batch
above and the completion / all-blocked reports of step 7 alike — with the finish line:

```
LABEL: N blocker(s) open      # N = open issues carrying LABEL, excluding the roadmap issue itself
```

Derive `N` live and **exactly** each run — no page-cap truncation — and exclude the roadmap issue
(which itself may carry LABEL) **in the query**, not by post-filtering:

```bash
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
# Omit the line unless the label actually exists — exact match, 404 => absent (NOT an error).
if gh api "repos/$REPO/labels/$LABEL" >/dev/null 2>&1; then
  # Search API total_count is exact at any size; `-label:roadmap` drops the roadmap artifact.
  N="$(gh api -X GET search/issues -f q="repo:$REPO is:issue is:open label:\"$LABEL\" -label:roadmap" --jq '.total_count')"
  # emit "LABEL: N blocker(s) open" — singular "blocker" when N==1; when N==0 emit
  # "LABEL: 0 blockers open — destination reached"
fi
```

**The marker is optional and this line never fails the run.** If the marker is absent, or the
repo has no such label (the `gh api …/labels/$LABEL` 404 above — the one non-fatal exception to
step 1's hard-stop-on-error rule, exactly like the missing-`roadmap`-label carve-out in step 2),
**omit the line entirely.** Which label a repo counts toward is project-specific configuration
that belongs in the artifact, not baked into this agent-neutral skill.

### 7. Completion & edge cases

- **No open issues** (other than the roadmap issue itself) → report **"roadmap complete"**;
  this is success, not an error.
- **Open issues remain but every ready bundle is blocked or in-flight** → do **not** fabricate
  a batch. Report the state explicitly: name the blocking dependency or the in-flight PR, and
  point at the next bundle that will unblock when it clears.
- **Open issues remain but none is implementable** — every remaining candidate classified
  `tracker-only` or `owner-review` (step 4) → do **not** fabricate a batch and do **not** report
  "roadmap complete." Report the Reconcile flags: which issues are satisfied-but-open (recommend
  closing them) and which need owner review, then stop. "roadmap complete" means no open
  *non-roadmap* issues remain — a `tracker-only` issue is still open, so the loop isn't done
  until the owner closes it.
- **The roadmap issue excludes itself.** It is identified by the `roadmap` label and is never
  a backlog item, never bundled, and never counted toward completion — otherwise it could
  suggest itself and "roadmap complete" would be unreachable.
- **Determinism.** Running `/roadmap` twice with no tracker change rewrites the artifact
  identically and emits the same `Next:` batch.

## Agent-neutral (scope note)

Authored as `base/workflows/roadmap.md` and rendered into the Claude skill by
`scripts/build.sh`, exactly like every other workflow. Rendering this workflow into the
Codex and Gemini command surfaces rides the **same** tracked follow-up epic as all the other
workflows (the repo's skill-parity issues) — it is not re-solved here. The source is
agent-neutral; only the per-agent renderers differ.
