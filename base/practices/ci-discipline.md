# CI discipline

**A failing CI job is a signal to diagnose, not a button to re-press.**

Never re-run a failed or "flaky" CI job as a first resort. Re-running burns CI
minutes, hides the root cause, and — if it happens to go green — ships a latent
bug.

## Protocol when CI fails

1. **Establish that the job actually RAN.** Before reading anything, ask whether
   any step executed. A run can conclude `failure` having executed **zero steps**,
   and then there is no log to read and nothing in the diff to find — see
   *"the job never ran"* below for how to tell, in one command.
2. **Read the failure log.** Get the actual error, not the summary status.
3. **Classify: real, flaky, or never-ran.** A **real** failure reproduces; a
   **flaky** one is a timing/order/shared-fixture artifact of a job that *did*
   execute; a **never-ran** one executed nothing at all. Say which, with evidence.
4. **If real → fix the root cause.** Then push the fix. Do not re-run against the
   old commit.
5. **If genuinely flaky →** file an issue to de-flake it (name the suspected
   cause: ordering, a fixed date aging out, a timeout, a shared fixture), *then*
   re-run. A flaky test you re-ran past is technical debt you now owe an issue.
6. **If never-ran →** do **not** debug the diff and do **not** file a de-flake
   issue. Re-run once capacity returns. Details below.
7. **Never merge on a flaky re-run alone** — **of a result that exists.**
   Green-by-retry is not green when an earlier run produced a verdict you are
   overriding. It does not apply to a job that executed zero steps: there was
   never a result, so the re-run is the *first* run, not a second opinion. Say
   which case you are in rather than invoking the rule by reflex.

## The third class: the job never ran

**A platform outage, an unacquired runner, a cancelled queue.** Zero steps
executed, no code was touched, and the red carries no information about the diff.
This is not flaky and it is not real — it is a fact about the *provider*, and both
of the other two boxes give actively wrong advice for it.

### Detection

The machine-checkable signal is **step execution**, and it is one command:

```
ci-health.sh classify --run <id>
```

It prints a verdict word and a one-line reason, and its exit code is the
classification: `0` green · `22` **failed** (a non-passing job executed steps —
there is a log, diagnose the diff) · `23` **never-ran** · `24` **queued** past the
threshold · `25` still pending · `20` **unreadable** · `2` usage. It **fails
closed**: an unreadable run resolves to `20`, never to "probably the platform",
because that is the flattering answer and the one that ships a real failure past a
reader who stopped reading.

The run id comes from whatever surfaced the red — `gh run list`, or the URL in
`gh pr checks`. Each agent's workflow carries the path for its own install; this
document states the rule, not the path.

Corroborating signals, for a human reading the same event:

- **Zero executed steps** on every job that did not pass (this is what the command
  above decides on).
- **A runner-acquisition or cancellation annotation** — e.g. *"The job was not
  acquired by Runner of type hosted even after multiple attempts"*. It appears on
  the job's annotations, **not** in any log, which is why step 2 finds nothing.
- **Provider status not `operational`** (`githubstatus.com`). Check this yourself:
  it describes *now*, so no tool can use it to classify a run that concluded
  hours ago without letting a current incident relabel an unrelated old failure.
- **A run stuck `queued`** long past what this repo's CI normally takes. Note that
  a concurrency group can legitimately hold a run for hours, so a long queue is a
  reason to look, not a verdict on its own.

### Response

- **Do not debug the diff.** Nothing in it executed. Reading `ci: failure` as a
  code failure and bisecting your own change against a run that touched no code is
  the expensive mistake this class exists to prevent.
- **Do not file a de-flake issue.** Step 5 mandates one for a flaky test; it does
  **not** apply here, and `issues-and-scope.md` returns *don't file* on both of its
  questions — *who does this?* nobody, the cause is the provider's; *what breaks if
  nobody ever does?* nothing in the repo. There is no test to de-flake. Filing
  anyway puts noise into the tracker whose documented problem is having been
  flooded with issues nobody would do.
- **Re-run once capacity returns**, and say plainly that this is **not**
  green-by-retry: no earlier result is being overridden, because there was never a
  result.
- **Say which class it was**, in the PR or the report. "CI was red and I re-ran it"
  and "CI never executed and I ran it" are different claims, and only the second
  one is honest here.

### What this class does NOT license

- It is **not** an excuse to merge without a passing check. The required check is
  still required; it simply has not answered yet.
- It is **not** grounds for routing around CI — no self-hosted fallback, no second
  provider mirroring the gates, and above all **nothing that posts a commit status
  from a local gate run**. That converts "CI is down" into a general-purpose
  branch-protection bypass, and a bypass that exists becomes the default path.
- It is **not** the same as a repo that has **no** CI. That is a permanent state
  the owner declares; this is a transient one that clears on its own. The two
  prescribe opposite actions — "stop asserting CI exists" versus "it does exist, it
  is coming back, don't route around it."

## Common "flaky" causes that are actually real

- Fixed seed dates that age past a now-relative filter (freeze the clock instead).
- Test-order dependence / shared mutable fixtures.
- Cross-platform assumptions (path separators, line endings, locale, timezone).
- A deployed environment lagging the default branch behind a release gate —
  see `debugging.md`.

## Why

Re-running flaky CI instead of fixing the cause is the classic lazy shortcut. The
cost is real (wasted minutes) and the risk is worse (a hidden bug shipped by a
lucky green). Diagnose first, always.

The third class is here because the two-box model was **measurably wrong** during
the GitHub Actions `major_outage` of 2026-08-06. A run concluded `failure` after
1h46m having executed zero steps, with the runner-acquisition annotation above and
an empty step list; a sibling workflow on the same commit succeeded. Step 2 was
unexecutable — there was no log — and step 3 offered two boxes, neither of which
fit. "Resource artifact" is the closest of the two and routes to step 5, so the
letter of this practice mandated filing a de-flake issue that `issues-and-scope.md`
forbids. Two practices, opposite instructions, for one event. The override had to
be made by hand and said out loud, and every agent meeting the next outage would
have had to re-derive it — or follow the letter and file the noise.
