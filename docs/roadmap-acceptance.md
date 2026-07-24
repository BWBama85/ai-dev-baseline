# `/roadmap` acceptance script

Manual, end-to-end acceptance for the `/roadmap` workflow (issue #45).

**Why manual.** `/roadmap` is prose an agent executes against a **live** tracker: it reads
issues, milestones, labels and PRs through `gh`, and it reads *and rewrites* a GitHub issue as
its artifact. The parts that can be pinned in a pure unit test are the two load-bearing
decisions — in-flight targeting and release readiness — and those are extracted into
`scripts/lib/roadmap-lib.sh` and tested offline by `scripts/check-roadmap.sh`, wired into
`selfcheck` + CI. Everything **else** in the list below is behavior over live
tracker state; this document is its acceptance script.

Run it in a **scratch repo**, never a real one — several scenarios require closing issues,
canceling milestones, and rewriting the roadmap artifact.

> **Scope note.** A fully-mocked `gh` harness that automates this file is deliberately *not*
> built here: it would have to simulate issue/PR/milestone/label/search endpoints plus artifact
> mutation, which is a larger surface than the workflow it guards. If that harness is built
> later, this file is its specification — each numbered case is one test.

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

## 1. Bootstrap — no `roadmap`-labeled issue exists

Run `/roadmap`.

- [ ] It creates **one** issue titled `Roadmap & execution order`, labeled `roadmap`, and pins it.
- [ ] The body's **first content line** is `<!-- ai-dev-baseline:roadmap:v1 -->`.
- [ ] Bundles group `#1` + `#2` (same "gates" subsystem) onto one row; `#3` is `blocked` (its
      body declares `Depends on #1`); `#4` is **not** treated as depending on `#1` (`Refs` is a
      cross-reference, not an edge).
- [ ] The body carries **no** `destination-label` marker and **no** `release-milestone` marker —
      bootstrap never enables either opt-in.
- [ ] It emits `Next: /implement-issue 1 2` (the gates bundle), not a single issue.

## 2. Adopt-not-duplicate — a pre-existing hand-maintained roadmap

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

## 5. Advance — in-flight skipping (the #69 regression)

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

## 6. Determinism

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

## 8. Destination report (finish-line gauge)

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

### 9b. The readiness predicate

Set `<!-- release-milestone: Next release -->` on the artifact.

- [ ] **Unarmed:** `Next release` holds **no** issues → reports "release milestone `Next release`
      has no requirements yet". Emits **neither** a cut nor "roadmap complete".
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
- [ ] **Met** → emits `✅ Release requirements met (Next release: 0 open blockers) — cutting.`
      followed by `Next: /release`. `/roadmap` only **prints** it; it never runs it.
- [ ] A `<!-- release-command: /ship -->` marker overrides the emitted command.
- [ ] With non-blocker issues still open in the milestone, the banner appends
      `(K non-blocker issue(s) still open — they roll to the next cycle)`.
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

## Related

- `base/workflows/roadmap.md` — the workflow this script accepts.
- `scripts/lib/roadmap-lib.sh` — the two extracted predicates (in-flight targeting, readiness).
- `scripts/check-roadmap.sh` — their offline regression tests (run by `selfcheck` + CI).
- `docs/release-goal-convention.md` — the opt-in module §9 exercises.
