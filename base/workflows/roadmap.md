---
name: roadmap
description: Maintain the build roadmap and emit the next /implement-issue batch. Locates one canonical roadmap artifact (a `roadmap`-labeled issue), reconciles it against the live tracker, and outputs the next unblocked, one-branch bundle of issue IDs. Bootstraps the artifact if none exists. Works in any repo with a GitHub issue tracker.
argument-hint: (no argument)
user-invocable: true
effort: high
# Roadmap-maintenance skill: it reads the tracker and reads/writes ONE roadmap artifact (a
# GitHub issue, edited via `gh issue edit --body-file`). It must never edit repository code —
# Write is allowed only for the /tmp/.claude-state roadmap-body scratch consumed by gh.
disallowed-tools: Edit, NotebookEdit
---

# /roadmap

Close the development loop. After a batch merges — `/implement-issue … → PR → merge →
/cleanup → /clear` — run `/roadmap` and it tells you the **next batch to implement**,
grouped so the batch fits one branch, so you immediately run `/implement-issue x y z`.

It maintains a single, always-current roadmap artifact, turning the backlog into a
self-draining queue: as long as open issues remain, every run yields a next batch; when
none remain, it reports "roadmap complete."

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

## The roadmap artifact (one prescribed home)

**The canonical home is the single open GitHub issue bearing the `roadmap` label.** There
is exactly one; the skill reads and writes it exclusively. (A file such as `ROADMAP.md` is
deliberately *not* used — maintaining a tracked file would require a branch + PR every run,
which conflicts with the post-`/cleanup`, post-`/clear` loop this skill serves.)

The issue body carries a machine marker on its first content line so the skill can locate,
parse, and rewrite it deterministically:

```markdown
<!-- ai-dev-baseline:roadmap:v1 -->
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
     grouping data, NOT milestone membership). `Status` ∈ ready | blocked | in-flight | done. -->

| Bundle | Issues      | Subsystem      | Depends on | Status  |
| ------ | ----------- | -------------- | ---------- | ------- |
| B1     | #5, #19     | gates          | —          | ready   |
| B2     | #7          | dogfood        | —          | ready   |
| B3     | #39         | workflows      | B-home     | blocked |

## Dependencies

<!-- Explicit edges only. An edge exists when an issue body says "Depends on #N" /
     "Blocked by #N", or when declared here. `Refs #N` is NOT a dependency. -->

- #39 depends on #32

## Done (recent)

- ~~#34~~ — merged (Wave-1 foundation)
```

`Status` values: `ready` (all deps closed, no in-flight member), `blocked` (a dep is still
open), `in-flight` (a member has an open PR), `done` (all members closed).

## Steps

### 1. Preflight

Ensure `gh` is authenticated and you are inside the target repo. `gh` list commands have
finite default page sizes — always pass an explicit `--limit` large enough to cover the
backlog (e.g. `--limit 200`) and treat any `gh` error as a **hard stop**, never a silent
empty result (a truncated or failed list must not look like "no open issues").

```bash
command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated"; exit 1; }
mkdir -p .claude/state   # gitignored scratch for the roadmap body
```

### 2. Locate the canonical roadmap artifact (deterministic)

```bash
ROADMAP_NUM="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number')"
COUNT="$(printf '%s\n' "$ROADMAP_NUM" | sed '/^$/d' | wc -l | tr -d ' ')"
```

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
# A pinned issue whose body carries the marker, or whose title begins with "Roadmap".
CAND="$(gh issue list --state open --limit 200 \
  --json number,title,body \
  --jq '.[] | select((.body|test("ai-dev-baseline:roadmap")) or (.title|test("^Roadmap"))) | .number' \
  | head -n1)"
```

- **Candidate found** → **adopt it:** add the `roadmap` label (creating the label if the repo
  lacks it), ensure the marker is present in its body, and pin it if unpinned. It is now the
  canonical home. Then reconcile it (step 4).
- **No candidate** → **bootstrap a fresh one:**
  1. Read **all** open issues + milestones live (`gh issue list --state open --limit 200
     --json number,title,labels,milestone,body`; `gh api` for milestones), **excluding the
     roadmap issue itself** once it exists.
  2. Group into phases by milestone build order (foundational/cross-cutting before polish),
     order by dependency, and bundle by shared subsystem/files (see step 5's rules).
  3. Write the artifact body (schema above) to a scratch file and create the issue:
     ```bash
     gh label create roadmap --description "The build roadmap (ai-dev-baseline /roadmap)" --color 0e8a16 2>/dev/null || true
     gh issue create --title "Roadmap & execution order" --label roadmap --body-file .claude/state/roadmap-body.md
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
- **Slot new issues.** Any open issue not already in a bundle is placed into the right
  phase/bundle (by milestone + subsystem), never left orphaned. An unmilestoned issue is
  flagged and placed by inference — surfaced, never silently dropped.
- **Drop stale refs.** Remove closed issue numbers from bundles and dependency edges.
- **Persist the grouping.** Bundles are written back to the artifact so the grouping is
  stable and reproducible across runs — not re-inferred (and re-shuffled) every time.

Rewrite the issue body via `gh issue edit "$ROADMAP_NUM" --body-file .claude/state/roadmap-body.md`.

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
bundle's members with a fresh `gh` call immediately before emitting** (`verify-before-
asserting.md`) — an issue may have closed or gained a PR since step 4:

```bash
# For each candidate member #N: confirm still OPEN and has no open PR.
gh issue view "$N" --json state --jq .state          # must be OPEN
gh pr list --state open --search "$N in:body" --json number --jq '.[].number'   # must be empty
```

Then output the batch and a one-line rationale:

```
Next: /implement-issue 5 19
Why:  B1 (gates) — unblocked, no in-flight PR, foundational for M2.
```

### 7. Completion & edge cases

- **No open issues** (other than the roadmap issue itself) → report **"roadmap complete"**;
  this is success, not an error.
- **Open issues remain but every ready bundle is blocked or in-flight** → do **not** fabricate
  a batch. Report the state explicitly: name the blocking dependency or the in-flight PR, and
  point at the next bundle that will unblock when it clears.
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
