<!-- GENERATED FILE — do not edit by hand.
     Source: base/workflows/implement-issue/examples.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->
# /implement-issue — worked examples

Read on demand. One real-shaped example per artifact, so a first run knows what "good" looks
like without any of these loading into every run.

## A gap-analysis reply (the three-heading contract)

```text
BLOCKING
- none

SHOULD-CLARIFY
- The issue's test plan asserts "ten consecutive green CI runs" but this repo's CI only runs on
  push/PR — clarify whether the soak accrues from PR runs or needs a schedule (ci.yml:3-9).
- scripts/lib/foo.sh:141 already validates the slug charset; the issue's plan re-validates in the
  caller, which this repo's reuse law forbids — reuse adb_slug_ok or say why not.

NICE-TO-HAVE
- The issue body's line anchors have drifted (step 3 now starts at :485, not :467).

VERDICT: proceed-with-clarifications
```

Disposition: BLOCKING → surface and stop (pre-branch). SHOULD-CLARIFY → recorded as assumptions
in the PR body, or resolved in the diff. NICE-TO-HAVE → noted; filed only if it clears the
issue bar.

## A review finding and its disposition row (step 9 → the PR body)

```text
REQUIRED — scripts/lib/foo.sh:88 — `rm -f "$dir"/$name` is unquoted on $name; a name with a
glob char sweeps siblings. Quote it.
```

| # | Finding (file:line) | Severity | Disposition |
|---|---|---|---|
| 1 | `foo.sh:88` unquoted expansion sweeps siblings | REQUIRED | fixed in `a1b2c3d` |
| 2 | `foo.sh:120` helper could live in common.sh | OPTIONAL | declined — single caller today; a shape, not a defect (issues-and-scope.md) |

## A PR body skeleton

```markdown
## Summary
<what changed and why, 3–6 lines>

## Gap analysis
<agent> — VERDICT: <verdict>. BLOCKING: none. SHOULD-CLARIFY taken as assumptions: <list or none>.

## Survey
<ran (agent, N words) | skipped (unassigned) | failed rc=N — continued without it>

## Review
Rung: <independent <agent> | same-model (not independent) | deferred to <logins> | none>.
| # | Finding | Severity | Disposition |
|---|---|---|---|
| … | … | … | … |

## Docs consulted
<the rendered block from bash "$HOME/.gemini/scripts/lib/docs-lib.sh" report --state .gemini/state>

## Test plan
- [ ] <gate runner green>
- [ ] <the new guard observed failing on its witness>

Closes #NN
Refs #MM
```

The closing keywords are bare prose — never in a code span or fence (the skeleton above is
quoted documentation, which is exactly why a real body must not copy it wholesale).

## A blocked marker

```json
{ "reason": "gates: check-foo.sh failed 3x after fixes (unreproducible locally red assertion)",
  "phase": "implemented",
  "branch": "issue-99-frob-the-widget",
  "issue": "99",
  "owner": "b3f2…" }
```

`branch`/`issue` must match the active marker; `owner` is copied from it, never recomputed.
