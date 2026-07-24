# The release-goal convention (optional module)

Most of `ai-dev-baseline` is unconditional law. This is a **module you opt into** — a
small, shareable convention for projects that cut rolling releases and want the workflow,
not the operator, to decide when a release is ready.

Without it, `base/practices/issues-and-scope.md` only gestured at "if the project has a
release-goal convention, follow it" and defined none, so every project reinvented one and
at least two independently hand-ported the *same* scheme (issue #27). This packages that
scheme once, as an opt-in that a repo without it never feels.

## What it is

Tracker primitives:

| Primitive | Kind | Role |
|---|---|---|
| **`Next release`** | milestone (rolling) | The **active release milestone** — its open issues are this release's scope. |
| **`Backlog`** | milestone (standing) | Everything not slated for the current release. New discoveries land here. |
| **`release-blocker`** | label | Marks the **must-haves** inside the active release milestone — the readiness gate. |
| **`post-deploy`** | label | Optional — tags work that can only happen *after* a release ships. |

The whole point is a **terminating loop**. A dev loop generates issues (self-review,
`/roadmap` reconcile, deferrals) faster than it closes them; nothing computes "are we
done?", so either the operator judges it by hand every run or the loop never ends. This
convention makes "done" a live, computable predicate (issue #71):

> **A release is ready when there are 0 open `release-blocker` issues in the active
> release milestone.** If the `release-blocker` label does not exist in the repo at all,
> the predicate falls back to "0 open issues in the active release milestone."

Two rules keep readiness *reachable*:

1. **Requirements are defined once** — drop the issues that are this release's scope into
   the active release milestone; label the must-haves `release-blocker`.
2. **The set is frozen** — work discovered *while implementing* defaults to `Backlog`,
   never the active release milestone. Without this the requirement set grows as you work
   and never converges.

**`release-blocker` is only meaningful inside the active release milestone.** Never apply
it to a `Backlog` issue: the readiness gate is milestone-scoped, so a blocker parked in
`Backlog` would make the finish-line gauge and the cut decision disagree.

## Opting in (one command)

```bash
baseline release init
```

This creates the `Next release` + `Backlog` milestones and the `release-blocker` +
`post-deploy` labels in the current repo, **idempotently** — it creates only what is
absent and never deletes or renames anything, so it is safe to re-run. It resolves the
project repo from your `gh` remote (not the install-source clone). If a single
`roadmap`-labelled issue exists, it also seeds the activation marker (below) into that
artifact so `/roadmap` picks the convention up on its next run; otherwise it prints the
marker for you to add. `baseline release status` reports which pieces are present and
whether the convention is active, changing nothing.

Use a different release-milestone name with
`baseline release init --release-name "v2.0"`.

## How the workflow uses it

The convention is **detected live, never assumed**. Every skill checks for it at run time
and adapts; a repo without it keeps its classic behavior, byte-for-byte.

### `/roadmap` — computes readiness and emits the release command

Activation is **explicit**: `/roadmap` runs in release-readiness mode only when the roadmap
artifact carries the marker

```markdown
<!-- release-milestone: Next release -->
```

naming the active release milestone. This mirrors the existing `destination-label` opt-in:
bootstrap never writes it, so merely *having* a `Next release` milestone (which some repos
do for unrelated reasons) never silently changes `/roadmap`'s output. The marker's value is
the milestone title; set it empty (`<!-- release-milestone: -->`) or delete it to force
classic mode. If the marker names a milestone that does not resolve to exactly one open
milestone, `/roadmap` stops and surfaces the mismatch rather than guessing.

In release-readiness mode, every run `/roadmap`:

- **Scopes advancement to the active release milestone.** It emits `/implement-issue`
  bundles projected onto the release set — only members that are *in* the active milestone —
  so it never pulls `Backlog` work forward. (Reconciliation still runs backlog-wide; only
  the *selection* is scoped.)
- **Computes the readiness predicate live** (the rule above), excluding the roadmap issue
  itself, and requiring the milestone to be **armed** — a brand-new milestone with zero
  issues reports "no requirements defined yet," it does not emit a cut.
- **Emits accordingly:**
  - **Requirements unmet** (open `release-blocker`s remain) → the next unblocked
    `/implement-issue` bundle *from the release set*.
  - **Requirements met** (0 open `release-blocker`s in an armed milestone) → `Next: /release`
    with `✅ Release requirements met (<milestone>: 0 open blockers) — cutting.` (If
    non-blocker issues remain open in the milestone, the banner names them: they roll to the
    next cycle, they do not hold the release.)
- **Composes with the destination report.** Point the artifact's optional
  `<!-- destination-label: release-blocker -->` marker (issue #68) at `release-blocker`; in
  release-readiness mode the count is **milestone-scoped** so the gauge (`release-blocker: N
  open`) is exactly the live distance to the cut. The destination-label is the *gauge*; the
  readiness predicate is the *trigger*.

**The emitted command is advisory and configurable.** `/roadmap` never runs a command — it
prints one. The default is `/release` (this baseline ships no `/release` skill; it is the
project-owned release role, issue #3 — a repo without one simply gets an unrunnable
suggestion, not an error). Override the command with `<!-- release-command: <cmd> -->` on the
artifact.

**Configurable last mile (auto-cut).** By default the operator runs the emitted `/release`,
exactly like running an emitted `/implement-issue` — the *determination* is fully automated,
zero readiness-watching. A repo that never deploys on release (tag-only) may opt into a
zero-touch driver that runs `/release` automatically when readiness flips true. Auto-cut is
**off by default and gated behind explicit repo opt-in** (generality + charge-safety); keep
the confirm for repos that **deploy** on release. Its prescribed home is a project-scoped
Stop-hook / driver-loop config (the enforcement-hooks layer, issues #14/#25), not `/roadmap`
itself — the executor mechanism is tracked as a follow-up. Until it lands, the safe
emit-only default is the whole last mile.

### Issue filing — new work defaults to `Backlog`

When the convention is detected, `/create-issue` and `/implement-issue`'s deferred-work
filing default a **newly discovered** issue to `Backlog` — never the active release
milestone — so the frozen requirement set converges. `Backlog` is the safe default home and
needs no extra confirmation; placing an issue *into* the active release milestone is the
deliberate decision that it is a requirement of *this* release. An unfinished release
requirement keeps its own `release-blocker` issue open — you never silently transfer its
acceptance into `Backlog`. A repo without the convention is unchanged: it files to its own
backlog, or milestone-less if it uses no milestones.

## Relationship to other issues

- **#3** — release *execution* (`/release`). This convention *defines* requirements and
  *detects* readiness; `/release` cuts the tag/version and rolls the milestone. They compose.
- **#68** — the destination-report capability (the readiness *gauge*).
- **#71** — the keystone that wires `/roadmap` to the predicate and the release emission.

## See also

- [per-project-overrides.md](per-project-overrides.md) — the override surfaces this composes
  with.
- [roles-and-agents.md](roles-and-agents.md) — the `release` role that owns cutting a
  release.
