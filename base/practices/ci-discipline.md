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

**Zero steps executed, no code was touched, and the red carries no information
about the diff.** This is not flaky and it is not real, and both of the other two
boxes give actively wrong advice for it.

**What the class asserts is the EXECUTION FACT, and nothing about the cause.** A
platform outage produces it; so does an unacquired runner, a concurrency group
cancelling the run, a newer run superseding it, a self-hosted runner nobody
started, and a human clicking Cancel. Those are not interchangeable: if *your own
change* altered a concurrency key or a workflow trigger such that the job is
cancelled before startup, re-running repeats it forever, and "don't inspect the
diff" is then exactly the wrong advice. So *"it did not run"* is what you may
conclude from the evidence below; *"the provider did it"* needs its own evidence,
and the response section says which parts depend on which.

### Detection

The machine-checkable signal is **step execution**, and it is one command —
`ci-health.sh`, shipped in this baseline's shared library:

```sh
# The library installs beside the other shared primitives, at ~/.<agent>/scripts/lib/.
# It is NOT on PATH: invoke it by path, the same way every workflow here does.
bash "$HOME/.claude/scripts/lib/ci-health.sh" classify --run <id>   # …/.codex/… or …/.gemini/… for those agents
```

It prints a verdict word and a one-line reason, and its exit code is the
classification: `0` green · `22` **failed** (a non-passing job executed steps —
there is a log, diagnose the diff) · `23` **never-ran** · `24` **queued** past the
threshold · `25` still pending · `20` **unreadable** · `2` usage. It **fails
closed**: an unreadable run resolves to `20`, never to "probably the platform",
because that is the flattering answer and the one that ships a real failure past a
reader who stopped reading.

The run id comes from whatever surfaced the red — `gh run list`, or the URL in
`gh pr checks`.

Corroborating signals, for a human reading the same event. **The first is what the
command decides on; the rest are what distinguish a provider cause from the others,
and none of them is implied by the first:**

- **Zero executed steps** on every job that did not pass.
- **A runner-acquisition or cancellation annotation** — e.g. *"The job was not
  acquired by Runner of type hosted even after multiple attempts"*. It appears on
  the job's annotations, **not** in any log, which is why the log step finds
  nothing. This one names a cause; read it before assuming one.
- **Provider status not `operational`** (`githubstatus.com`). Check this yourself:
  it describes *now*, so no tool can use it to classify a run that concluded hours
  ago without letting a current incident relabel an unrelated old failure.
- **A run stuck `queued`** long past what this repo's CI normally takes. A
  concurrency group can legitimately hold a run for hours, so a long queue is a
  reason to look, not a verdict on its own.
- **Whether your own diff touched CI configuration** — a `concurrency:` key, a
  trigger, a `cancel-in-progress`. If it did, the cancellation may be yours, and
  this is the one branch of this class where the diff *is* in scope.

### Response

- **Do not debug the diff for the failure itself.** Nothing in it executed, so
  bisecting your change against a run that touched no code is the expensive
  mistake this class exists to prevent. The exception is the last signal above: if
  the diff changed CI configuration, read *that* change — not the application code.
- **Do not file a de-flake issue.** The flaky step mandates one for a test that
  ran and flapped; it does **not** apply here, and `issues-and-scope.md` returns
  *don't file* on both of its questions — *who does this?* nobody, unless the cause
  turns out to be yours; *what breaks if nobody ever does?* nothing in the repo,
  because there is no test to de-flake. Filing anyway puts noise into the tracker
  whose documented problem is having been flooded with issues nobody would do.
- **Re-run**, and say plainly that this is **not** green-by-retry: no earlier
  result is being overridden, because there was never a result. If the *same* run
  never executes twice in a row and the status page is clean, stop re-running and
  look for a cause you own — a repeat is evidence against the outage reading.
- **Say which class it was, and how confident you are about the cause.** "CI was
  red and I re-ran it", "CI never executed and I ran it", and "CI never executed,
  the annotation says the runner was never acquired" are three different claims.
  Make the one the evidence supports.

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
an empty step list; a sibling workflow on the same commit succeeded. "Read the
failure log" was unexecutable — there was no log — and "classify" offered two
boxes, neither of which fit. "Resource artifact" is the closer of the two, and it
routes to the de-flake issue, so the letter of this practice mandated filing
something `issues-and-scope.md` forbids. Two practices, opposite instructions, for
one event. The override had to be made by hand and said out loud, and every agent
meeting the next outage would have had to re-derive it — or follow the letter and
file the noise.

(Step numbers are deliberately absent from that account: it describes the protocol
as it stood *before* the third class was added, and the steps have renumbered since.
Naming them survives the next edit; a number silently stops meaning what it meant.)
