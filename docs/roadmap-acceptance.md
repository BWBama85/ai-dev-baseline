# `/roadmap` acceptance script

End-to-end acceptance for the `/roadmap` workflow (issue #45). **Part of this file is now
automated** (issue #75); the rest is a manual script.

**What is automated, and how.** `scripts/check-roadmap-e2e.sh` **extracts the workflow's own
fenced snippets** — by their `# ADB-SNIPPET: <name>` markers — and **executes them** against a
stub `gh` driven by fixtures, offline, in `selfcheck` + CI. That makes doc↔behavior drift a test
failure: a fenced command edited into something that no longer runs goes red instead of surprising
whoever next runs `/roadmap`. The two load-bearing decisions (in-flight targeting, release
readiness) are separately pinned as pure predicates in `scripts/lib/roadmap-lib.sh` by
`scripts/check-roadmap.sh`.

**What stays manual.** The half no stub can decide: bundling by subsystem, `tracker-only` vs
`owner-review` classification from ground truth, the artifact's prose, and anything requiring a
real repo's history. Run those in a **scratch repo**, never a real one — several scenarios close
issues, cancel milestones, and rewrite the roadmap artifact.

Each case below is marked:

| Mark | Meaning |
|---|---|
| **[auto]** | covered by `scripts/check-roadmap-e2e.sh` (or `check-roadmap.sh`) — run in CI |
| **[auto-partial]** | the mechanical half is automated; the judgment half is manual |
| *(unmarked)* | manual |

---

## 0. Set up a scratch repo

```bash
gh repo create adb-roadmap-acceptance --private --clone
cd adb-roadmap-acceptance
git commit --allow-empty -m "init" && git push -u origin HEAD
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
```

Seed a handful of issues (numbers below assume a fresh repo, so `#1`…`#6`):

```bash
gh issue create --title "Gate detection hardening"   --body "Acceptance: gates detect pnpm."          # #1
gh issue create --title "Gate model v2"              --body "Acceptance: richer gate model."          # #2
gh issue create --title "Docs composition"           --body "Depends on #1"                           # #3
gh issue create --title "Unrelated polish"           --body "Refs #1 — cross-reference only, NOT a dep."  # #4
gh issue create --title "Adoption scan"              --body "Acceptance: scan existing config."       # #5
gh issue create --title "Canceled experiment"        --body "May be abandoned."                       # #6
```

**Cleanup (run at the end of any session):**

```bash
gh repo delete "$REPO" --yes
```

---

## 1. Bootstrap — no `roadmap`-labeled issue exists **[auto-partial]**

Run `/roadmap`.

- [ ] It creates **one** issue titled `Roadmap & execution order`, labeled `roadmap`, and pins it.
- [ ] The body's **first content line** is `<!-- ai-dev-baseline:roadmap:v1 -->`.
- [ ] Bundles group `#1` + `#2` (same "gates" subsystem) onto one row; `#3` is `blocked` (its
      body declares `Depends on #1`); `#4` is **not** treated as depending on `#1` (`Refs` is a
      cross-reference, not an edge).
- [ ] The body carries **no** `destination-label` marker and **no** `release-milestone` marker —
      bootstrap never enables either opt-in.
- [ ] It emits `Next: /implement-issue 1 2` (the gates bundle), not a single issue.

## 2. Adopt-not-duplicate — a pre-existing hand-maintained roadmap **[auto-partial]**

Delete the artifact's label, then re-run:

```bash
gh issue edit <roadmap#> --remove-label roadmap
```

- [ ] `/roadmap` **adopts** the existing issue (adds `roadmap` back, ensures the marker, pins it)
      rather than creating a second artifact.
- [ ] Only **one** `roadmap`-labeled issue exists afterward.

Then test the split-brain guard — create a second marked issue and re-run:

- [ ] With **two** `roadmap`-labeled issues, `/roadmap` **STOPS**, lists both, and asks the owner
      to retire one. It never guesses. (Remove the duplicate before continuing.)

## 3. Reconcile — done, new, and stale refs

```bash
gh issue close 2 --reason completed
gh issue create --title "Newly filed work" --body "Acceptance: something new."   # #7
gh issue close 6 --reason "not planned"
```

Run `/roadmap`.

- [ ] `#2` moves to `Done (recent)`; the gates bundle keeps `#1` only (a partially-done bundle
      drops its closed member).
- [ ] `#7` is **slotted** into a bundle, never left orphaned.
- [ ] `#6` (closed `NOT_PLANNED`) is dropped from its bundle; if anything **depended** on it, the
      edge is **kept** and recorded in `Reconcile flags` as `dep-canceled` — never silently dropped.
- [ ] Re-running does not re-shuffle the grouping (bundles persist; they are not re-inferred).

## 4. Tracker-only / owner-review — done-ness re-derived from ground truth

Add a comment to `#5` claiming delivery, without shipping anything:

```bash
gh issue comment 5 --body "Superseded — this shipped in PR #999."
```

- [ ] `/roadmap` does **not** take the claim at face value. Because the branch read cannot confirm
      it, `#5` is classified **`owner-review`**, moved to `Reconcile flags`, and **never emitted**.
- [ ] An issue whose acceptance genuinely *is* satisfied on the default branch is classified
      **`tracker-only`** with the satisfying PR/issue recorded, and closing it is recommended.
- [ ] A plain open issue with **no** prior-delivery signal stays **`implementable`** even when its
      acceptance is prose — ordinary unfinished work is never quarantined.
- [ ] A `tracker-only`/`owner-review` member does **not** block other ready bundles behind it.

## 5. Advance — in-flight skipping (the #69 regression) **[auto]**

This is the case `scripts/check-roadmap.sh` pins at the predicate level; verify it end-to-end.

```bash
git switch -c ref-only-pr && git commit --allow-empty -m "wip" && git push -u origin HEAD
gh pr create --title "Unrelated work" --body "Refs #1 — just a cross-reference."
```

- [ ] `/roadmap` **still emits `#1`**. A bare `Refs #1` is a cross-reference and must **not**
      freeze it. *(Before #69 was fixed, this froze `#1` indefinitely.)*

Now make a PR that actually targets it:

```bash
gh pr edit <pr#> --body "Closes #1"
```

- [ ] `/roadmap` now **skips the whole bundle** containing `#1` as `in-flight` and emits the next
      ready bundle instead. An in-flight bundle is frozen whole — never re-scoped.
- [ ] A PR whose body says `Closes #10` does **not** freeze `#1` (word-boundary: `#1` ≠ `#10`).
- [ ] A **cross-repo** link (`other/repo#1`) does not freeze this repo's `#1`.

## 6. Determinism **[auto-partial]**

With no tracker change between runs, run `/roadmap` twice and capture the artifact each time:

```bash
gh issue view <roadmap#> --json body --jq .body > /tmp/r1.md
# …run /roadmap again…
gh issue view <roadmap#> --json body --jq .body > /tmp/r2.md
diff /tmp/r1.md /tmp/r2.md && echo "IDENTICAL"
```

- [ ] The artifact bodies are **byte-identical** and the emitted `Next:` batch is the same.
- [ ] `Reconcile flags` rows are ordered by ascending issue number and deduped.
- [ ] No volatile timestamps appear in the artifact.

## 7. Completion & all-blocked reporting

- [ ] **All issues closed** (except the artifact) → reports **"roadmap complete"** — a success,
      not an error. The roadmap issue never counts itself.
- [ ] **Open issues remain but every bundle is blocked/in-flight** → does **not** fabricate a
      batch; names the blocking dependency or the in-flight PR and points at what unblocks next.
- [ ] **Open issues remain but none is implementable** (all `tracker-only`/`owner-review`) →
      reports the flags and stops; does **not** report "roadmap complete".

## 8. Destination report (finish-line gauge) **[auto-partial]**

```bash
gh label create release-blocker --color b60205
gh issue edit 1 --add-label release-blocker
```

Add `<!-- destination-label: release-blocker -->` to the artifact header, then run `/roadmap`.

- [ ] Every run's output is prefixed `release-blocker: N blocker(s) open`, singular at `N == 1`.
- [ ] At `N == 0` it reads `release-blocker: 0 blockers open — destination reached`.
- [ ] The count **excludes the roadmap issue itself** (label it `release-blocker` to confirm the
      exclusion happens in the query, not by post-filtering).
- [ ] With the marker **absent**, or the label nonexistent, the line is **omitted entirely** and
      the run still succeeds (a 404 on the label probe is not an error).

---

## 9. Release-readiness mode (the release-goal convention — #27/#71)

Stand the convention up, then exercise activation, the predicate, projection, and emission.

```bash
bash scripts/lib/release-convention.sh init      # or: baseline release init
```

### 9a. Activation — the marker, and only the marker

- [ ] **No `release-milestone` marker** → **classic mode**. Output is byte-identical to a repo
      that never adopted the convention, *even though* a milestone named `Next release` now
      exists — coincidental names never activate it.
- [ ] Marker present but **empty** (`<!-- release-milestone: -->`) → classic mode.
- [ ] Marker set to the literal placeholder `NAME` → classic mode (the schema's own example
      token, copied verbatim, must degrade gracefully — never hard-stop).
- [ ] Marker naming a milestone that matches **exactly one open** milestone → mode is **active**.
- [ ] Marker naming a milestone matching **zero** open milestones → **STOP**, surfacing
      "matches 0 open milestones". Never a silent fall back to classic.
- [ ] Marker matching **more than one** open milestone → **STOP** the same way.

### 9b. The readiness predicate **[auto]**

Set `<!-- release-milestone: Next release -->` on the artifact.

- [ ] **Unarmed:** `Next release` holds **no** issues → the milestone is **composed** (§9d), and the
      run continues into the unmet advance. It emits **neither** a cut nor "roadmap complete". Only a
      composition that is refused or finds no promotable candidate reports "release milestone
      `Next release` has no requirements yet".
- [ ] **Blocker-mode** (the `release-blocker` label **exists**): with ≥1 open `release-blocker` in
      the milestone → **unmet**; with **0** → **met**. Non-blocker open issues do not block a cut.
- [ ] **Fallback** (label **absent**, 404): readiness is `0 open issues in the milestone`.
- [ ] Mode is keyed off label **existence**, never the live count — closing the last blocker must
      not flip the repo from blocker-mode to fallback. *(The predicate half of this is automated:
      `check-roadmap.sh` asserts the same counts yield opposite verdicts on `label_exists` alone.
      What is verified here is that the workflow reports label existence faithfully.)*
- [ ] **Canceled requirement:** close a `release-blocker` in the milestone as `not planned` →
      the cut is **withheld** (`held`), the row is recorded in `Reconcile flags` as
      `owner-review`, and the same state yields the same result on every run.
- [ ] The hold **clears** only on a real tracker edit — reopen it, remove the `release-blocker`
      label, or drop it from the milestone. Re-running `/roadmap` alone never clears it.

### 9b-bis. Branch health — a drained checklist is not a shippable build (#78) **[auto]**

Health is reduced by the shared `roadmap-lib.sh branch-health` predicate, evaluated against the
default branch's **HEAD commit** (never `gh run list --limit 1`, which can answer with an unrelated
workflow or an older commit), across **both** the Checks API and the legacy commit-status API. It is
consulted **only** at the would-be-`met` boundary.

- [ ] **Green + 0 open blockers** → emits the release command, banner naming the branch as green.
- [ ] **Red + 0 open blockers** → **no cut.** `⛔ Requirements met, but <branch> is not green`,
      **naming the failing check**. The action is `/debug`, not `/implement-issue`.
- [ ] **A check still running** → `indeterminate`, **fail closed** — and reported as *unknown*,
      never as red (a mid-CI run must not read as a failure).
- [ ] **A check attached to a different commit** → `indeterminate`. Stale evidence is never this
      branch's green.
- [ ] **No CI at all** (no checks *and* no active workflows) → the condition is **skipped** and the
      cut is emitted, saying so. A repo without CI is never deadlocked (#24).
- [ ] **Active workflows that have not reported on this commit** → `indeterminate`, **not**
      `no-ci`. (An empty run list means both; the active-workflow inventory is the discriminator.)
- [ ] **A non-Actions provider** (Vercel/CircleCI/Cloudflare) reporting failure through the legacy
      status API still withholds the cut.
- [ ] With **open blockers**, the verdict is `unmet` and health is **not read at all** — a repo
      mid-build never blocks on a CI read it cannot act on.
- [ ] Any failing health read (repo, HEAD, check-runs, status, workflow inventory) **hard-stops**;
      none of them may fall through to a cut on unknown health.
- [ ] A canceled (`NOT_PLANNED`) blocker **and** a red branch → `held` wins. Both withhold the cut;
      `held` is reported first because it has a deterministic owner remedy.
- [ ] **Live-only:** change the default branch's HEAD *between* the first readiness calculation and
      the final emission re-check — the second read must win and suppress the cut.

### 9b-ter. An unmilestoned `release-blocker` is never swept to `Backlog` (#78) **[auto]**

- [ ] File an open issue labeled `release-blocker` with **no** milestone. With release-readiness
      mode **active**, the step-4b autofix must **not** sweep it to `Backlog` — it prints a `WARN:`
      line instead, and issues no `issue edit` for it. An unlabeled unmilestoned issue in the same
      run **is** still swept.
- [ ] **Classic mode is byte-identical.** With the `release-milestone` marker absent, the *same*
      fixture takes the plain sweep: the labeled issue is repaired like any other unmilestoned
      issue and **no** `WARN:` line is printed. (A repo that ran `baseline release init` — which
      creates the label — but has not yet added the marker sits in exactly this state.)
- [ ] That warning is **not** retirable by a `## Decisions` row (a row must never hide a release
      risk); it clears only by assigning the issue to the release milestone or removing the label.
- [ ] It **warns, it does not gate.** Nothing feeds it into the readiness predicate, so the same
      run may print the warning *and* emit the cut. That is deliberate — #78 required only that
      such an issue is never silently ignored, and the wording says `WARN`, not `HOLD`, so the
      output does not claim a gate that is not wired.
- [ ] Confirm the failure it prevents: were it swept, readiness would count 0 blockers in the
      milestone and emit a cut with a declared must-have parked in `Backlog`.

### 9c. Projection — advancement is scoped, reconcile is not

Put one issue in `Next release` and leave others in `Backlog`, bundled together.

- [ ] Reconcile still runs **backlog-wide** (a `Backlog` issue that already shipped is still
      caught and flagged).
- [ ] Emission is **projected onto the milestone**: a mixed bundle emits only its `Next release`
      members and never pulls `Backlog` work forward.
- [ ] A ready bundle with **zero** milestone members is **skipped** while requirements are unmet.
- [ ] A milestone member blocked only by a `Backlog` prerequisite is **surfaced** (pull the dep in
      or resolve it), not silently emitted and not hidden.

### 9d. Emission and the gauge

- [ ] **Unmet** → emits the next ready bundle projected onto the milestone, exactly like classic
      mode but scoped.
- [ ] **Met, and the declared release command RESOLVES** → emits `✅ Release requirements met
      (Next release: 0 open blockers, main green) — cutting.` followed by `Next: <the declared
      command>`. `/roadmap` only **prints** it; it never runs it. When health was `no-ci` the banner
      says the check was **skipped** instead of claiming green — a branch that was never checked is
      never reported as green.
- [ ] A `<!-- release-command: /ship -->` marker sets the emitted command, and `/ship` resolves to
      an installed skill in **this agent's** skill roots (Claude, Codex and Antigravity each have
      their own — Antigravity's sit under a `config/` root).
- [ ] A marker carrying **arguments** (`<!-- release-command: /ship --channel production -->`)
      resolves on the command *name* and emits the **full** value.
- [ ] **Met, but the declared command does NOT resolve** → `Next: none — release-command "<cmd>" is
      declared but no such skill exists`. The `— cutting.` banner and the rollover reminder are
      **withheld** (#188): printing them above `Next: none` is self-contradicting and can lead an
      operator to roll a milestone for a release that was never cut.
- [ ] **Met, but NO marker** → `Next: none — this repo declares no release command`, again without
      the cutting banner or the reminder. There is deliberately **no `/release` default**: an
      unresolvable slash command fuzzy-matches an unrelated built-in rather than failing.
- [ ] With non-blocker issues still open in the milestone, the banner appends
      `(K non-blocker issue(s) still open — not holding the release; the roll sends them to Backlog)`.
- [ ] A **met** emission also prints the rollover reminder
      `Then: baseline release roll --version <version>` — **immediately above** the `Next:` line,
      never below it (the output contract in §10 reserves the last line for the action). Without
      the roll the milestone stays open with zero open blockers, so the predicate returns `met` on
      every later run and the same cut is re-emitted forever — verify a second run after an actual
      roll does **not** report `met`. Since D15 that run composes the freshly-emptied milestone
      (§9d) and advances; before D15 it reported `unarmed`.
### 9d. Composition of an empty release milestone (D15) **[auto]**

Covered end-to-end by `scripts/check-roadmap-e2e.sh` §9 against the stub `gh`; the ranking and
selection predicates are unit-tested in `scripts/check-roadmap.sh` §2j/§2k.

- [ ] An **empty** release milestone is filled rather than reported: every implementable backlog
      **bug** is promoted, plus the transitive closure of the prerequisites it needs.
- [ ] **Every promotion carries `release-blocker`.** Without the label the milestone reads `met` on
      the next run and emits a cut for a release nothing has built. This is the single most
      important assertion in the section.
- [ ] A **non-empty** milestone — holding open *or* closed issues — is never added to. The artifact
      issue itself does not count as a member.
- [ ] **Not composed, and reported rather than silently skipped:** an issue reconcile classified
      `tracker-only` / `owner-review`; an issue in any milestone other than the backlog; a bug whose
      prerequisite was closed `NOT_PLANNED`; a bug whose prerequisite is itself excluded (pruning
      cascades).
- [ ] Those same out-of-scope issues still **block** a dependent — they are open and undelivered, so
      treating them as satisfied would compose a release that cannot drain.
- [ ] A dependency declared only in the artifact's `## Decisions` table is honoured, attributed
      **per row** (the Question id names the dependent), never cross-multiplied across rows.
- [ ] `--no-autofix` performs **no** tracker write and still prints the slate it would have
      promoted.
- [ ] A promotion that fails mid-loop **rolls back** the ones that succeeded, so the milestone
      returns to empty and the next run retries the whole selection instead of freezing around the
      prefix that landed.
- [ ] Classic mode (no `release-milestone` marker) composes nothing.

- [ ] With `destination-label: release-blocker`, the gauge is **milestone-scoped** in this mode,
      so it always equals the readiness trigger (a blocker parked in `Backlog` must not inflate it).
- [ ] **Met** is a valid terminal emission and is **not** "roadmap complete" — open `Backlog` work
      may remain, and the next cycle continues from it.

### 9e. Determinism in release-readiness mode

- [ ] Two consecutive runs with no tracker change produce a byte-identical artifact and the same
      emission — including the `held` case.
- [ ] An emit-time reconcile change (a member dropped to the flags, a canceled blocker recorded)
      is **persisted before** the emission, so the next run does not re-process stale state — this
      applies to the **met → release-command** early exit too.

---

## 10. Output contract — the last line is the next action (#107) **[auto-partial]**

The terminal is the instruction; the artifact is the record. *(The workflow-side half of this is
automated: `check-roadmap.sh` asserts every fenced output example in `base/workflows/roadmap.md`
ends with its `Next:` line. What is verified here is that a **run** obeys it.)*

- [ ] A normal advance prints **≤5 lines**, and its **last line is the command to run**
      (`Next: /implement-issue <ids>`). Nothing prints after it.
- [ ] A cut-ready run whose release command **resolves** ends with that command, with the
      `Then: baseline release roll …` reminder **above** it. A cut-ready run whose command is
      missing or undeclared ends with `Next: none — …` and prints **neither** the reminder nor the
      `— cutting.` banner.
- [ ] An all-blocked run, a "roadmap complete" run, an unarmed-milestone run, and a STOP condition
      each end with `Next: none — <state>` and no trailing prose.
- [ ] **No** bundle table, "what changed since last run", per-issue reconcile narration, or
      look-ahead appears in the default output.
- [ ] **Zero-count sections are omitted entirely** — no "Reconcile flags: none".
- [ ] No self-narration about verification performed (fresh fetches, live re-checks). It is
      reported only where it changed the outcome.
- [ ] Anything genuinely needing an owner decision appears **above** the final line.

## 11. Decision durability — a question asked once (#108) **[auto-partial]**

```bash
gh issue create --title "Driver work" --body "Depends on #1 and #2"    # #8
```

- [ ] The edge set comes from the **body**: `#8` depends on `#1` and `#2`. A `Refs #N` elsewhere in
      the same body creates **no** edge.
- [ ] Edit the body to `Depends on #1. No longer depends on #2.` → on the next run the `#2` edge is
      **gone**. An edge whose source text was removed does not survive in the artifact's
      `## Dependencies` section (it is a derived view, regenerated every run).
- [ ] A **negated** mention creates no edge: a body reading only `No longer depends on #2` yields
      none.
- [ ] **Only prose declares (#117).** File an issue whose body *documents* the vocabulary rather
      than asserting it — a `Depends on #2` inside a fenced ```` ```console ```` block, inside an
      `<!-- … -->` comment, inside a `> ` blockquote, and inside a `` `Depends on #2` `` span.
      **None** of the four creates an edge, while a plain `Depends on #1` in the same body still
      does. This was live: #112's repro blocks fabricated a `#112 → #52` edge that marked a ready
      bundle `blocked`. A 4-space-**indented** block is stripped at **top level only** (D27): it
      must be indented four or more spaces with no paragraph and no list container open, because
      under a `- ` bullet content starts at column 2 and code needs six — so stripping four
      blindly would delete continuation prose and silently drop a real blocker.
- [ ] **Formatting is not content (#112).** File an issue whose body declares the edge in ordinary
      markdown — `Depends on **#1**`, `**Depends on:** #1`, `` Depends on `#1` ``, and
      `- **Blocked by** #1`. **Each** creates the edge; before this, all four were silently
      dropped, which is the direction that marks a genuinely blocked bundle `ready`. The tolerance
      stops at formatting: `Depends on * #1` and `` Depends on `ignore #1` `` still create none,
      and neither does `Depends on **acme/repo#1**`.
- [ ] **An edge the grammar refused is REPORTED, not dropped (#132, D28).** **[auto-partial]** File an issue
      whose body reads `Depends on #1 (the gate) and #2` → the edge set is `#1` alone (unchanged),
      **and** the run surfaces `dep-ambiguous:#N` naming the dropped `#2`. Same for
      `Depends on issue 1`, which declares no edge and previously looked identical to `Refs #1`.
      Then verify the SILENT half, which is the false-positive budget: `Depends on acme/repo#1`
      (a confident non-edge), `Depends on #1 and blocked by #2` (the next keyword claims it),
      `Depends on #1; it is not blocked by #2` (negation is an answer) and
      `- #5 depends on #6 — satisfied, #6 closed (PR #7)` (past a clause boundary) report
      **nothing**. Measured on this repo at the time it shipped: zero reports across 37 open bodies.
      The **library** half of this is automated in `check-roadmap.sh` § 6k; the rendering half below
      — the Reconcile-flags row, the owner question, its retirement — is manual, which is why this
      is `[auto-partial]` and not `[auto]`.
- [ ] The ambiguity row **does not hold the issue out of emission** — it warns, exactly as an
      unmilestoned `release-blocker` warns (#78). A bundle whose member reported one is still
      emitted, and the question retires from a `## Decisions` row like any other `dep-*` id.
- [ ] Surface an owner question (e.g. put an `M` member's only prerequisite in `Backlog`). The
      printed line carries a **stable id** and names **where to record the answer**:
      `? dep-outside-release:#8 — … Record: #8 body or artifact ## Decisions.`
- [ ] Record the answer in the artifact's `## Decisions` table under that exact id → **the question
      does not appear on the next run**, or any run after it.
- [ ] Record the answer as an issue **comment** instead → the question is (correctly) **not**
      retired, because a comment is not a prescribed home. This is the original bug: verify the
      skill points at a home it actually reads.
- [ ] `/roadmap` **never rewrites or removes** a `## Decisions` row: the section survives a
      reconcile byte-for-byte, while every other section is regenerated.
- [ ] A `## Decisions` row whose `Decision` cell says `Depends on #N` **declares** that edge; one
      that says `no longer depends on #N` **retires** it — the same vocabulary an issue body uses.

---

## 12. Autofix — repair the unambiguous, escalate the rest (#109) **[auto]**

```bash
gh issue create --title "In limbo" --body "no milestone"        # #9, deliberately unmilestoned
```

- [ ] A repo with unmilestoned open issues ends the run with **zero in limbo**, each reported in
      **one line**: `fixed: #9 → milestone Backlog (was unmilestoned)`.
- [ ] **Re-running changes nothing** — no autofix lines, no tracker writes. Idempotency comes from
      re-deriving the limbo set (`milestone == null`) each run, not from remembering anything.
- [ ] An unlabeled or unpinned canonical artifact is **repaired**, not reported.
- [ ] The roadmap artifact itself is never moved into the backlog.
- [ ] With **no** backlog milestone in the repo, it **escalates** (`? unmilestoned:#9 … Record: …`)
      and **does not create one** — inventing a milestone would impose a convention the repo never
      opted into.
- [ ] A `<!-- backlog-milestone: Icebox -->` marker retargets the repair.
- [ ] `--no-autofix` reports every defect as an owner question and performs **no** tracker write.
- [ ] A failing milestone or issue read **hard-stops** rather than "finding nothing to fix".
- [ ] **No repository code is modified** — no branch, no commit, no PR, ever.

## 13. Completeness of the backlog read (#79) **[auto]**

- [ ] A repo with **more than 200** open issues reconciles **every** open issue, verified against
      the Search API's exact `total_count`.
- [ ] An artificially **truncated** read fails loudly (`read N of M open issues`) instead of
      persisting a partial roadmap. No open issue is ever reconciled to `Done` because it fell
      outside a page.
- [ ] Reading **more** than the index reports is *not* an error — the Search index lags REST, and
      more data can never delete work from the plan.
- [ ] A pre-existing roadmap sitting **past** the old cap is found by the adopt scan, so a second
      artifact is never created (which would manufacture the split-brain §2 hard-stops on).
- [ ] An open-PR read that exactly **saturates** its cap is treated as possibly truncated.
- [ ] A **failed** `gh` read reports as a failed read — never as an empty tracker. (Regression:
      `gh api … | release-counts` returned 0 on a failed read because a pipeline reports only its
      last status, so a milestone full of open blockers read as "no requirements yet".)

---

## Related

- `base/workflows/roadmap.md` — the workflow this script accepts.
- `scripts/check-roadmap-e2e.sh` — the mocked-`gh` harness that automates the cases marked
  **[auto]** above by executing the workflow's own `# ADB-SNIPPET:` blocks.
- `scripts/lib/roadmap-lib.sh` — the two extracted predicates (in-flight targeting, readiness).
- `scripts/check-roadmap.sh` — their offline regression tests (run by `selfcheck` + CI).
- `docs/release-goal-convention.md` — the opt-in module §9 exercises.
