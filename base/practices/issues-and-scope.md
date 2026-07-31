# Track deferred work that matters — and nothing else

Deferred work that lives only in prose gets lost. Deferred work filed
indiscriminately gets lost too, in a backlog nobody can read. Both failures are
real; only the first one used to be written down here.

**A tracked issue is a claim that someone will do this.** Filing something nobody
will do is not tracking — it is a to-do list pretending to be a plan, and it costs
every future reader the time to re-triage it.

## The bar

**File only if both questions have concrete answers:**

1. **Who does this?** A person, a role, or a release it belongs to. "Someone,
   eventually" is not an answer.
2. **What breaks if nobody ever does?** A behavior that stays wrong, a promise the
   project stops keeping, a defect that reaches users.

If either answer is *"unclear"* or *"nothing concrete"* — **don't file.** The work
was not real enough to track, and writing it down does not make it real.

### Specifically not filing reasons

None of these is a defect. Each describes a *shape* you dislike, not a behavior
that is wrong:

- the same rule is stated in two places;
- a helper would live better in another home;
- a check could be more thorough, or cover one more case;
- a sibling *might* have the same bug (go look — if it does, that is one filable
  bug with two sites; if it doesn't, there is nothing to file);
- a feature could be extended, generalized, or made pluggable;
- an edge case exists that nothing has ever hit.

**Only a defect *caused by* one of those is filable**, and then you file the
defect, not the shape.

### Check the tracker first

Search open issues before filing. A duplicate is worse than a gap: it splits
context and doubles triage.

If the tracker is too large to check, that is itself the bug — fix it by closing,
not by filing around it.

## What is still owed an issue

The bar is a filter, not an excuse. When both questions *do* have answers, file —
and file it in the same run, before you call the work done:

- Slices you deliberately cut because the work was too large for one PR. (Who: you.
  What breaks: the feature ships half-built.)
- A parent issue's own **"Out of scope"** list, *where those items meet the bar*.
  The list evaporates into a closed issue on merge, so anything real in it must be
  re-homed. Anything not real in it should never have been listed.
- A defect a reviewer found that you resolved by **deferring rather than fixing** —
  the behavior is still wrong, so the second question is already answered.
- A test gap that leaves a *specific* known-reachable path unguarded.

## Rules for the ones you do file

- **A PR-body note is not tracking.** It falls out of view the moment the issue
  closes on merge. Only an open issue tracks deferred work.
- **Link both ways.** Comment the new issue on the parent (the link survives after
  the parent closes) and reference it from the PR.
- **Place it correctly.** If the project has a release-goal / milestone convention,
  follow it: newly *discovered* work defaults to the **backlog** — never the active
  release milestone; only a deliberate current-release requirement enters it.
  Freezing the release set that way is what keeps "done" reachable: an ever-growing
  set never converges. Detect the convention live rather than assuming it.
  Otherwise default to the project's backlog. Never leave a new issue
  milestone-less if the project uses milestones.

## Why

This practice used to read **"File by default; do not ask."** That rule was written
to stop silent scope loss, and it did — but it is a generator with no sink, and
nothing else in the baseline pushes the other way.

Measured on this project on 2026-07-31: **191 issues filed in 14 days, 98 closed —
and 35 of those 98 closed `NOT_PLANNED`.** More than a third of everything ever
tracked turned out, on inspection, not to be worth doing. Filing ran ahead of
completion roughly 3:1, so the backlog did not grow slowly, it *diverged* — no
amount of work reached zero. A triage the same day closed 59 of 93 open issues in
one pass, almost all of them shapes rather than defects.

That is the cost of a filing bar set at zero: not a tidy record of good intentions,
but a tracker nobody can read, a roadmap that cannot be trusted, and real defects
sitting alongside sixty things nobody was ever going to do.

The bar above is the sink. That `NOT_PLANNED` closures were happening at all proves
the judgment was always available — it was just being applied after the issue
existed instead of before.
