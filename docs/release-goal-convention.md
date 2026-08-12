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
project repo from your `gh` remote (not the install-source clone). It then **prints** the
one activation step — the `release-milestone` marker (below) to add to your roadmap
artifact — but never edits the artifact itself: `/roadmap` is its sole writer, so seeding
it here would risk clobbering the one issue the whole loop depends on. It prints **two** markers,
and both are required: `release-milestone` arms readiness, and `release-command` is what a met
verdict emits — the latter has **no default** (see *You must declare the release command*), so a
repo that adds only the first enters release-readiness mode with no way to cut and discovers it at
`Next: none` when the release is finally ready. Adding those marker lines is the last step of
opting in. `baseline release status` reports which pieces
are present and whether the convention is active, changing nothing.

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
  itself, and requiring the milestone to be **armed**. A brand-new milestone with zero issues is
  **composed** rather than reported (decision D15): `/roadmap` fills it from the backlog — every
  implementable bug plus the prerequisites they need, labelled `release-blocker` — and continues
  the same run into the ordinary unmet advance. It still never emits a cut for an empty milestone.
  See *Composition* below.
- **Emits accordingly:**
  - **Requirements unmet** (open `release-blocker`s remain) → the next unblocked
    `/implement-issue` bundle *from the release set*.
  - **Requirements met, the default branch is green, and the declared release command RESOLVES**
    (0 open `release-blocker`s in an armed milestone) → `Next: <your declared release-command>`,
    with `✅ Release requirements met (<milestone>: 0 open blockers, <branch> green) — cutting.`
    (If non-blocker issues remain open in the milestone, the banner names them: they do not hold
    the release, and `baseline release roll` sends them to `Backlog` on the cut — re-slate
    them deliberately, like any other work.)
  - **Requirements met but the release command is undeclared or does not resolve** → `Next: none —
    …` naming what to add. The `— cutting.` banner and the rollover reminder are **withheld**: both
    assert a cut is happening, and printing them above `Next: none` can lead an operator to roll
    the milestone for a release that was never made. See *You must declare the release command*.
  - **Requirements met but the branch is not green** → **no cut.** `⛔ Requirements met, but
    <branch> is not green` naming the failing check. A drained checklist says the *requirements*
    are done; it says nothing about whether the code is **shippable**, and on a repo that deploys
    on cut that difference is a broken production deploy. The action is `/debug`, not
    `/implement-issue`.
  - **Requirements met but health cannot be established** (a check still running, or CI that has
    never reported on this commit) → **no cut, fail closed.** An unverifiable build is treated as
    unshippable, never optimistically as green.
  - **A repo with no CI at all**, where the owner has declared that with
    `<!-- release-health: no-ci -->` → the health condition is **skipped** and the cut is emitted,
    **naming the declaration**. A project that never adopted CI must not be deadlocked out of ever
    releasing — but since #293 that is something the owner **says**, not something the probes
    infer. Undeclared, the same repo is `indeterminate` (see *Nothing found is not nothing there*).
  - **A repo whose CI never reports on the default branch**, where the owner has declared that with
    `<!-- release-health: skip-unreported -->` → the condition is **skipped** and the cut is
    emitted, **naming the declaration**. Never reported as green (#115).

**How "green" is decided.** Health is evaluated against the **default branch's HEAD commit**, not
against a run list: `gh run list --branch <default> --limit 1` lists runs newest-first across all
workflows, so it can answer with an unrelated scheduled workflow, with a run for an *older* commit,
or with one workflow's success while a sibling job is red. `/roadmap` resolves the default branch
and its HEAD live, then reads **both** the Checks API (GitHub Actions and check-run apps) **and**
the legacy commit-status API (CircleCI, Vercel, Cloudflare, …) for that commit — reading only one
would silently ignore whole CI providers. The reduction to `green` / `not-green` / `indeterminate` /
`no-ci` is the shared `roadmap-lib.sh branch-health` predicate, regression-tested offline, so it
cannot drift run to run. A `skipped` or `neutral` conclusion is *not* a failure — that is how GitHub
itself scores a required check.

**How "does this repo have CI at all?" is decided — two probes, and `no-ci` needs both to say no
(#115).** This is the question that decides whether the health condition is *skipped* or the cut is
*withheld*, so getting it wrong is expensive in both directions. Until #115 the only evidence was
`gh api repos/OWNER/REPO/actions/workflows` — the count of active workflow **definitions** — which
enumerates **GitHub Actions and nothing else**. So a repo whose CI is CircleCI, Buildkite, Jenkins
or Vercel had zero Actions workflows, read as *"this repo has no CI"*, had the health condition
skipped, and **the cut was emitted against a branch nobody had checked.** The second probe is the
default branch's **required status contexts**, read through the ordinary (contents-read) branch
endpoint: GitHub does not care *who* reports a required context, so a declared one is a declaration
that CI exists here whoever supplies it. `no-ci` now requires **both** — zero active Actions
workflows **and** an authoritative empty required-context set.

A declared context that has **not** reported on the commit is `indeterminate`, for the same reason
an unreported Actions workflow is: **an unrelated provider's green result must never stand in for
the declared one.** A branch protected by a repository **ruleset** reports a real empty `contexts`
array through this endpoint, so that shape is classified *unreadable* and fails closed rather than
being taken as "requires nothing".

### Nothing found is not nothing there — so `no-ci` is declared (#293)

Both probes finding nothing is the **absence of a declaration, not a declaration of absence**, and
until #293 the model called it "positive evidence" and cut releases on it. An **unprotected** branch
has nowhere to declare a required context, so a repo with external CI and no branch protection
produced the *identical* empty answer as a repo with no CI at all — and the cut went out either way,
reported as `no CI configured`, which is a statement about the repo that is false. Reproduced
against the shipped predicate:

```console
$ printf '{"check_runs":[],"statuses":[],"required_contexts":[]}' \
    | roadmap-lib.sh branch-health <sha> 0 0
no-ci
$ roadmap-lib.sh release-ready 1 1 0 0 0 no-ci
met
```

No non-admin read can close that. There is nothing to protect on an unprotected branch, so the
admin protection endpoint would not help either; a check-suites probe sees Checks API apps but is
blind to the legacy status providers, which is exactly the population in question. **"This repo has
no CI" is simply not derivable.**

So the default **inverts**: nothing found and nothing declared is `indeterminate`, and the refusal
names the marker that settles it. The population this touches is exactly the ambiguous one — a repo
with Actions, with a required context, or with any result on the commit never reaches that arm, and
behaves byte-identically. **#24 still holds**: a repo that never adopted CI is not deadlocked, it
adds one line, and the run tells it which line.

**What this still cannot see**, stated plainly. Required checks are matched by **context name** —
GitHub's newer `checks` array can bind a context to an expected `app_id`, which this discards, so a
same-named result from another provider satisfies the requirement. That is the model `read_branch`,
`live_contexts` and `required-drift` already use, so changing it is a repo-wide decision rather than
a `branch-health` one.

### The escape hatches: `release-health` (#115 absorbing #113, extended by #293)  <!-- adb-claim-ok: #113 was consolidated INTO #115 and closed NOT_PLANNED as superseded; the reference is the history of this change, not tracked work -->

Each correction to the existence model **increases** the population that deadlocks, so each ships
with the declaration that keeps its population reachable. There are **two values**, they are
contrary claims about the same repo, and an artifact declares **at most one**:

```markdown
<!-- release-health: skip-unreported -->
```

A repo whose workflows are `pull_request`-only has a non-empty required-context set and nothing on
default-branch HEAD, so it lands on an unreported arm **every run, forever** — requirements met, cut
never emitted, no way to say so. This declares that its CI legitimately never reports on the default
branch. Health resolves to **`unreported-ok`**, which reaches `met` and emits the cut with a banner
naming the declaration rather than claiming green.

```markdown
<!-- release-health: no-ci -->
```

A repo that genuinely has **no CI** now finds no evidence anywhere, which is `indeterminate` by
default (above). This declares that there is nothing to verify. Health resolves to **`no-ci`**,
which reaches `met` — the same #24 degradation as before, with the difference that the banner now
says something true.

`no-ci` is narrower still: it excuses **only** the no-evidence arm. It cannot excuse an unreported
Actions workflow or an unreported required context, because those are **positive evidence that CI
exists**, which contradicts the declaration outright — a declaration must never overrule the
evidence it stands in for the absence of. So a stale `no-ci` marker stops applying **by itself** once
the repo declares an **Actions** workflow or a required context, or once anything reports on the
commit. Stated exactly, because the general form overclaims: the existence probes count Actions
workflows and required contexts, so adding an external provider that is **neither required nor
reporting here** leaves the repo in the same ambiguous state the declaration exists to answer, and
the marker keeps applying.

Both are deliberately narrow, and every one of these boundaries is regression-tested:

- each is consulted **only** on the arms it was written for: `skip-unreported` on the two "CI is
  declared but has not reported" arms and the no-evidence arm; `no-ci` on the no-evidence arm alone;
- neither is consulted **before `green`** — a branch that reported clean is green on its evidence,
  never relabelled by a declaration;
- both are evaluated **after** failing, still-running and wrong-commit checks, so neither can excuse
  a **red** branch, a **mid-CI** run, or **stale** evidence — those arms match first and win;
- neither can **ever** excuse a branch whose required checks could not be **read**. An owner
  declaration about *unreported* or *absent* CI is not evidence about *unreadable* CI. Note this
  holds for **both** unreported arms: with an unreadable list *and* active Actions workflows the
  Actions arm matches first, so gating only the unreadable arm would leave the hatch open through
  the earlier door;
- `skip-unreported` and `no-ci` are the only valid values. Anything else — a near-miss like `skip`,
  a case variant like `NO-CI`, or **both valid values at once** — is **reported and ignored**, never
  silently treated as "off", because an owner who wrote it wrong would otherwise face a permanent
  `indeterminate` with nothing anywhere explaining it. Both together are the ambiguous case that
  matters most: they are contrary claims, and resolving them either way invents an assertion nobody
  made;
- the two are resolved into what the predicate takes by `roadmap-lib.sh health-decl`, which owns the
  authority rule below. It is a predicate rather than prose at each call site because there are now
  **two** drivers — `/roadmap` and this repo's `/release` — and two hand-written copies of a rule
  standing between an editable issue body and a release cut is exactly the drift the framework's
  one-home law forbids;
- both are honoured **only from an artifact whose author has write access.** An issue's author can keep
  editing its body forever regardless of repo permissions, and this marker bypasses a release-safety
  refusal, so `/roadmap` checks the author's access at the moment it acts on the marker rather than
  trusting the check made when the artifact was adopted. It reads
  `collaborators/{user}/permission` and honours only `admin` or `write` — deliberately **not**
  `author_association`, which artifact *adoption* uses and which does not mean what it looks like:
  an organization `MEMBER` can hold read-only access, and `COLLABORATOR` covers read and triage. An
  unreadable permission fails **closed**.

`skip-unreported` produces its own verdict word, `unreported-ok`, rather than reusing `skipped`.
`skipped` is the **caller's** opt-out for a decision that is not about shippable code (`baseline
release roll`, which runs *after* the cut); this is the **owner's**, about a decision that very much
is. One word for both would leave a reader unable to tell which authority let a release through.
`no-ci` keeps the word it already had: its authority moved (inferred → declared) but its meaning did
not, and a third word would have propagated through `release-ready`'s accepted set, its precedence
table and every emission to record a change in provenance the banner already states in words.

**This repo's own `/release` honours `no-ci` and refuses `skip-unreported`**, and the asymmetry is
deliberate. `/roadmap` decides whether to *emit* a cut; the release driver decides whether to *tag*
one, having just watched the merge commit's checks settle — and `skip-unreported` describes a repo
that cannot give it that evidence, so such a repo needs its own release skill rather than a hatch
that lets this one tag an unverified commit. `no-ci` asserts there is no evidence to withhold, so
refusing it would not be strictness but a deadlock: before #293 that verdict was inferred, and a
driver that ignored the marker would now refuse to ever tag a CI-less repo.

**`baseline release roll` deliberately does not gate on health.** It re-verifies the *requirements*
live (fail-closed, as always) but passes `skipped` for the health input, explicitly at the call
site. Roll is post-cut bookkeeping: it archives the milestone the operator already released, and it
ships nothing. Gating it on live CI would strand the repo in the failure the rollover contract
exists to prevent — a branch that goes red *after* the tag would block the roll, leaving the
milestone open with zero open blockers, so `/roadmap` re-emits the same cut on every subsequent run
and the loop stops terminating. The green-branch gate belongs where the cut is **decided**.

**An open `release-blocker` in no milestone is warned about, not swept — in this mode only.**
`/roadmap`'s tracker autofix moves an unmilestoned open issue to `Backlog` — but while
release-readiness mode is **active** it **excludes** one carrying
`release-blocker`. In classic mode the carve-out is inert and the sweep is byte-identical to a repo
that never adopted the convention, so a repo that has run `baseline release init` (which creates
the label) but has not yet added the marker keeps the plain "nothing in limbo" behavior. That label is only meaningful inside the active release milestone, so sweeping it
to `Backlog` would drop a declared must-have out of the set readiness counts, and the very next run
would compute "met" and emit a cut with an abandoned blocker parked in the backlog. It is reported
as a `WARN:` line every run until the tracker actually changes: assign it to the release milestone,
or remove the label. Note it **warns rather than gates** — nothing feeds it into the readiness
predicate, so a run can print it and still emit the cut.
- **Composes with the destination report.** Point the artifact's optional
  `<!-- destination-label: release-blocker -->` marker (issue #68) at `release-blocker`; in
  release-readiness mode the count is **milestone-scoped** so the gauge (`release-blocker: N
  open`) is exactly the live distance to the cut. The destination-label is the *gauge*; the
  readiness predicate is the *trigger*.

**You must declare the release command, and it must resolve.** `/roadmap` never runs a command —
it prints one — but it will only print one that **exists**. Name it on the artifact:

```markdown
<!-- release-command: release -->
```

The value is **agent-neutral**: any invocation prefix you write is stripped, and each agent's
rendered workflow re-attaches its own (`/release` on Claude and Antigravity, `$release` on Codex).
So one artifact is correct on every agent.

There is **no default**, and that is deliberate (#188). An unresolvable slash command does not
fail loudly: Claude Code fuzzy-matches the nearest built-in, so a bare `/release` on a repo that
has no such skill silently opens the CLI's `release-notes` viewer — succeeding at something
unrelated at the exact moment the roadmap says *cutting*. Verified against Claude Code 2.1.220:
there is no `/release` built-in (`release-notes` is the only release-named command), so the hazard
is the **miss**, not a name collision, and renaming the default would not fix it.

So `/roadmap` resolves the declared command against the project and user skill directories before
emitting it, and reports a terminal state instead of guessing when it cannot:

| Artifact | Emission |
|---|---|
| marker present, skill exists | `Next: <cmd>` |
| marker present, skill missing | `Next: none — release-command "<cmd>" is declared but no such skill exists` |
| no marker | `Next: none — this repo declares no release command` |

The last two are not failures — the release *is* ready; the missing piece is a declaration the
owner owns. Write your own release skill (it is the
[project-owned release role](roles-and-agents.md#release-is-project-owned--the-baseline-ships-no-release);
the baseline ships none by decision) and point the marker at it. This repo's own copy lives at
`.claude/skills/release/`, and its procedure is an executable driver rather than prose — see D14.

**Configurable last mile (auto-cut).** By default the operator runs the emitted release command,
exactly like running an emitted `/implement-issue` — the *determination* is fully automated,
zero readiness-watching. A repo that never deploys on release (tag-only) may opt into a
zero-touch driver that runs it automatically when readiness flips true. Auto-cut is
**off by default and gated behind explicit repo opt-in** (generality + charge-safety); keep
the confirm for repos that **deploy** on release. Its prescribed home is a project-scoped
Stop-hook / driver-loop config (the enforcement-hooks layer, issues #14/#25), not `/roadmap`
itself — the executor mechanism is tracked as a follow-up. Until it lands, the safe
emit-only default is the whole last mile.

### Rolling over on the cut — `baseline release roll`

A cut that does not roll the milestone **strands the loop.** Once the release set's blockers
are all closed, the milestone sits open and empty of open work, so the readiness predicate
keeps returning `met` and `/roadmap` re-emits the same cut on every run, forever. Rolling is
what makes the next cycle exist.

```bash
baseline release roll --version v1.2.0            # after your /release has cut v1.2.0
baseline release roll --version v1.2.0 --dry-run  # print the plan, change nothing
```

It performs exactly four mutations, **in this order**:

1. **rename** the release milestone to `--version` (leaving it open) — this frees the rolling
   title, which GitHub requires before step 2, since milestone titles are unique repo-wide;
2. **create** a fresh, empty milestone under the rolling title;
3. **move** the leftover open non-blocker issues to `Backlog`;
4. **close** the renamed milestone — last, so an interruption always leaves a resumable state.

**Why `Backlog` and not "roll forward into the new milestone".** A milestone is *armed* when it
holds ≥1 issue, open or closed. Seeding the fresh milestone with rolled-forward non-blockers
would arm it with zero open blockers — which is the definition of `met` — so the very next
`/roadmap` run would emit a cut for a release containing nothing. Sending them to `Backlog`
leaves the new milestone genuinely empty, which is precisely the state `/roadmap`'s composition
step recognises and fills (D15). Note the asymmetry, because it is the whole safety argument:
`roll` moves leftovers **without** the `release-blocker` label, while composition **always**
applies it. Seeding here would arm a phantom cut; composing there cannot.

**It re-verifies readiness itself and fails closed.** `roll` does not trust the `/roadmap` run
that emitted the cut — it re-reads the tracker and recomputes the verdict through the same
shared predicate (`roadmap-lib.sh release-ready`), refusing on anything but `met`. `--force`
waives that verdict (the documented override for a `held` release), but it does **not** waive
the separate refusal to move an **open** `release-blocker` to `Backlog`: silently demoting a
must-have is an owner decision, so close it, unlabel it, or move it out yourself.

**If it is interrupted, re-run it.** Between the rename and the create there is one API call
during which no open milestone carries the rolling title and `/roadmap` hard-stops, so `roll`
detects a partially-executed roll and finishes it:

- **Interrupted after the rename** (the rolling title is missing) — unambiguous, so re-running
  resumes automatically. Restoring that title is *repair*, not rollover, so it happens even if a
  blocker was reopened in the meantime: `roll` recreates the milestone, then stops before the
  move/close and tells you what is left. A resume never re-runs the readiness gate — the roll was
  already authorized, and re-deciding it against a tracker that changed since is what would leave
  a half-rolled repo unfinishable.
- **Interrupted after the create** (both milestones open) — indistinguishable from a pre-existing
  milestone that happens to carry the version name, so `roll` refuses and asks. Re-run with
  **`--resume`** if that milestone really is your archive. (`roll` deliberately does *not* guess
  from "is the new milestone empty?" — it tells you to slate the next release into it, so a real
  interrupted roll stops looking empty almost at once.)

**The `release-milestone` marker never needs editing.** Because the rolling *title* is
recreated, the marker keeps naming a live milestone across the roll. `roll` reads that marker
to learn which milestone to roll (`--release-name` overrides it) and never writes to the
artifact — `/roadmap` remains its sole writer.

**Boundary.** `roll` is milestone bookkeeping only: no version bump, no changelog, no tag, no
package, no publish, no deploy. Those are the project-owned half (#3) and
`scripts/check-release-role.sh` pins the line. Your `/release` should call `roll` as its last
step; running it by hand afterwards is equally valid.

### Issue filing — new work defaults to `Backlog`

When the convention is detected, `/create-issue` and `/implement-issue`'s deferred-work
filing default a **newly discovered** issue to `Backlog` — never the active release
milestone — so the frozen requirement set converges. `Backlog` is the safe default home and
needs no extra confirmation; placing an issue *into* the active release milestone is the
deliberate decision that it is a requirement of *this* release — deliberate by a person, or by
`/roadmap`'s composition step against an **empty** milestone (D15), never by accretion into a set
that already holds work. An unfinished release
requirement keeps its own `release-blocker` issue open — you never silently transfer its
acceptance into `Backlog`. A repo without the convention is unchanged: it files to its own
backlog, or milestone-less if it uses no milestones.

## Relationship to other issues

- **#3** — release *execution* (`/release`), resolved: it stays **project-owned** (see
  [roles-and-agents.md](roles-and-agents.md#release-is-project-owned--the-baseline-ships-no-release)).
  This convention *defines* requirements and *detects* readiness; your `/release` cuts the
  tag/version. They compose.
- **#74** — the *rollover* half, resolved the other way: milestone rollover moved **out** of
  the project-owned `/release` and into `baseline release roll` (below). Cutting has four
  incompatible shapes; rolling has exactly one, on primitives `init` already creates.
- **#68** — the destination-report capability (the readiness *gauge*).
- **#71** — the keystone that wires `/roadmap` to the predicate and the release emission.

## See also

- [per-project-overrides.md](per-project-overrides.md) — the override surfaces this composes
  with.
- [roles-and-agents.md](roles-and-agents.md) — the `release` role that owns cutting a
  release.
- [roadmap-acceptance.md](roadmap-acceptance.md) — the `/roadmap` acceptance script; §9
  exercises every scenario of this module (activation, the readiness predicate, projection,
  emission, and determinism).


## Composition — filling an empty release milestone (D15)

`baseline release roll` archives the release milestone and opens a fresh **empty** one. Without a
step to fill it, the next `/roadmap` run computes `unarmed`, reports "no requirements yet" and
stops — so every cycle needs an owner to hand-slate the next set before the loop can advance again.
That is a person wired into a loop whose entire purpose is to terminate on its own.

So `/roadmap` composes an empty release milestone and continues the same run into the unmet advance.

**What goes in.** Every implementable **bug** in the backlog is promoted — bugs are the floor, not a
budget line — together with the transitive closure of the prerequisites they need. Enhancement
riders are selected by judgement, capped by `<!-- release-budget: N -->` (default 3), and each one's
reasoning is recorded in the artifact's `## Release composition` section.

**What is deliberately kept out**, because each of these would compose a release that can never
drain:

| Excluded | Why |
|---|---|
| Issues reconcile classified `tracker-only` / `owner-review` | The advance logic never emits them, so as a `release-blocker` they can never close. |
| Issues in **any other milestone** | That is an owner's existing scope decision; reassigning it silently is what step 4b calls an escalation. |
| A bug whose prerequisite was closed **`NOT_PLANNED`** | Cancellation is abandonment, not delivery — the `dep-canceled` rule. The bug is dropped and the drop is reported. |
| A bug whose prerequisite is itself excluded | Same reason, one hop out. Pruning cascades. |

**The frozen-set rule is intact.** Composition fires **only** when the milestone holds zero issues,
open or closed — asserted in the workflow's own shell, not in prose around it. A set that already
holds work is never added to, so the convergence argument this convention rests on is unchanged: a
release set is composed once and then frozen. A partial composition (one promotion succeeds, a later
one fails) is **rolled back** rather than left behind, precisely so the milestone returns to empty
and the next run can compose the whole set instead of freezing around the prefix that happened to
land.

**Turning it off.** There is no separate switch: composition is part of release-readiness mode. A
repo that wants to slate every release by hand keeps `<!-- release-milestone: -->` unset (classic
mode), or runs `/roadmap --no-autofix`, which prints the slate it *would* have promoted and writes
nothing.