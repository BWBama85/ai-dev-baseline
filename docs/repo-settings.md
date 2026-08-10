# Repo settings — handing PR merges to GitHub

`baseline repo` sets the two GitHub settings that let a PR merge itself once it is genuinely
ready, so the operator stops clicking Merge on every green PR (issue #87).

It is a small, sharply-bounded command: it reads `.github/workflows` and writes exactly two
settings. It never merges, reviews, tags, releases, or deploys — those stay project-owned (#3).

```bash
baseline repo checks        # the check contexts it would require, one per line
                            # (any subcommand takes --workflow-dir DIR to discover from another
                            #  tree — e.g. the merged default branch rather than a feature branch)
baseline repo status        # desired vs live, with drift named (nonzero = drift)
baseline repo apply         # required checks FIRST, then allow_auto_merge
baseline repo apply --prune # ...and drop required contexts no discovered job reports
baseline repo automerge-ok  # the guard /implement-issue asks before arming auto-merge
baseline repo required-drift # CI lint: has a discovered job silently stayed non-required? (#122)
baseline repo merge-flag    # the gh pr merge flag this repo allows (--squash / --merge / --rebase)
```

## The order is the safety property

1. **Required status checks** — set from the CI job names discovered in the workflow files.
2. **`allow_auto_merge`** — enabled *only after* step 1 succeeded.

Reversed, auto-merge lands PRs with nothing gating them: strictly worse than merging by hand,
because no human is left to notice the red. `apply` enforces this — a failed checks write aborts
before auto-merge is touched, and the offline test pins that ordering.

## Why the contexts are discovered, never hardcoded

GitHub matches required checks by **context name**: a job's `name:` when it has one, else the job
key. Nothing validates the strings you require — GitHub accepts any text, reports no error, and
simply waits for a check that will never arrive. That makes both failure directions expensive:

| Failure | Symptom |
|---|---|
| requiring a name that never reports | **every PR blocks forever** |
| missing a name that does report | that job **silently stops gating** |

So discovery reads the workflow files and emits only jobs it can *prove* report on every pull
request to the target branch. Anything it cannot prove is **skipped loudly** (on stderr) rather
than guessed at — a skipped job is visible and fixable; a phantom required context is a repo-wide
deadlock.

Skipped on purpose:

- a workflow with no `pull_request` trigger — it never reports on a PR;
- `pull_request:` carrying `paths:`/`paths-ignore:` — it does not run for every PR;
- `pull_request:` whose `branches:` filter does not provably include the target branch;
- a job with an `if:` condition — it may be skipped;
- a job with a `strategy.matrix` — its check-run names carry a matrix suffix;
- a job calling a reusable workflow (`uses:`) — its check names come from the callee;
- a job whose `name:` interpolates `${{ … }}` — not statically knowable;
- `pull_request:` narrowing `types:` to anything that lacks **both** `opened` and `synchronize` —
  the merge-cleanup workflow (`types: [closed]`) is the classic trap: it only runs *after* a PR
  closes, so as a required context it would sit "waiting" on every open PR forever.

Discovery also refuses a `pull_request:` written as an inline flow mapping carrying a filter
(`pull_request: {types: [closed]}`) and one whose `branches:` list uses **negative** patterns
(`["*", "!main"]` — GitHub evaluates those in order, so the `*` is not the last word).

Indentation is **not** the grammar (#102). Discovery reads workflow YAML by *relative depth* — a
key opens a block, and that block's children sit at whatever column the first content line inside
it happens to use — so two-space, four-space, and files that **mix** the two all read correctly.
No indent unit is detected or assumed, which matters because a file can legitimately carry more
than one (a two-space `on:` block above a four-space `jobs:` block is valid YAML that GitHub runs).
Block sequences are read at both spellings — indented under their key, and at the key's own column
(`branches:` followed by `- main` at the same indent is valid YAML, and GitHub runs it).

The reader is **not** a YAML parser, and the boundary is stated rather than left to be discovered:
a flow collection spanning several physical lines is read only from its opening line, merge keys
(`<<:`) are not resolved, and a block/folded scalar (`name: >-`) is reported as *unreadable* rather
than approximated. Every one of those under-reports — the job is skipped, never required under a
name that cannot report.

This replaced a real fail-open. The parser used to pin job keys to exactly two spaces and job
properties to four, so a uniform four-space workflow was reported as
`skipping ci.yml — no pull_request trigger`, contributed **zero** contexts, and exited **0**. The
`required-drift` backstop could not catch the under-requirement, because it derives its desired set
from this same discovery — so `apply` reported success while gating nothing.

Discovery now **fails loud** rather than reporting a clean empty scan. Every GitHub workflow has an
`on:` key and a `jobs:` block containing at least one job — those facts are what make the file a
workflow — so a file violating any of them is never a legitimate shape, only a read that failed:

| Situation | Result |
|---|---|
| no `.github/workflows`, or no workflow files | exit **0** — "this repo has no CI" is legitimate (#24) |
| every file legitimately skipped (no PR trigger, a `paths:` filter, …) | exit **0**, contexts empty |
| a file with no `on:` block, no `jobs:` block, or a `jobs:` block yielding zero jobs | exit **non-zero**, naming the file |

The structural check runs on **every** workflow file, including ones the trigger verdict skipped —
checking only the files that passed would leave #102's own shape unexamined, since a blind trigger
parse looks exactly like a file with no `pull_request` trigger.

Downstream, a failed discovery is mapped fail-closed rather than being allowed to masquerade as an
empty repo: `apply` refuses to write (and, under `--prune`, refuses to *delete* the contexts still
gating the branch), while `automerge-ok` and `required-drift` return **20**, never `12` ("no CI at
all") or `0` ("in sync").

Discovery is scoped to the `jobs:` block, which is not a nicety: `on:` puts `push:` and
`pull_request:` at the *same* indent as job keys, so a whole-file indent scan harvests those two as
jobs and requires contexts that can never report. This repo's own `ci.yml` is exactly that shape.

The YAML reading itself lives in **one** place — `adb_wf_on` / `adb_wf_jobs` in
`scripts/lib/common.sh` — shared with `scripts/check-bash-floor.sh`, which asks the *opposite*
question of the same records (#262). See `docs/ci-runners.md`.

## Endpoint choice — the wide one is destructive

A full `PUT …/branches/{b}/protection` **replaces** the whole protection object: every key you
omit is reset. Omitting `required_pull_request_reviews` removes "require a pull request before
merging" — the no-direct-push-to-`main` guardrail the whole baseline rests on. Omitting
`required_conversation_resolution` turns thread resolution off. So `apply` picks the narrowest
endpoint that works:

| Live state | Endpoint | Why |
|---|---|---|
| protection **with** required checks | `PATCH …/protection/required_status_checks` | touches only the sub-resource; nothing else can be lost |
| protection **without** required checks | `PUT …/protection`, body **rebuilt from the live object** | no sub-resource exists to PATCH, so the full PUT is the only path — read-modify-write, never a fresh literal |
| unprotected | `PUT …/protection` with conservative defaults | stands protection up: PR required, zero required approvals, thread resolution on |

The read-modify-write body carries **every** sub-object the live GET returns — including
`dismissal_restrictions` and `bypass_pull_request_allowances`. Dropping the first would turn off
"restrict who can dismiss pull request reviews"; dropping the second would revoke a bot or team's
bypass permission. Both are remapped from their GET shape (`{users:[{login}]}`) to their PUT shape
(`{users:[login]}`).

### `--branch` takes a raw git branch name (#103)

Pass `release/v1`, never `release%2Fv1`. Every endpoint above builds its path through one helper,
`_adb_rs_ref_path`, which percent-encodes the ref into a single path segment — so the encoding is
this library's job and doing it yourself asks about a *different*, nonexistent branch (a literal
`%2F` is itself a legal git ref name, so the encoder is deliberately not idempotent).

Measured against real slashed branches on 2026-08-09 with `gh` 2.95.0: GitHub accepts **both**
`branches/release/v1/protection` and `branches/release%2Fv1/protection`, and both address the same
branch. The encoded form is used anyway, because `/` is only the most common of the characters git
permits in a ref and a URI path does not. `#` is the one that makes this non-optional — git allows
it, and interpolated raw it opens a URI fragment that silently truncates the request. Full evidence
and the reasoning are in `.ai-dev-baseline/decisions.md` (D53).

## External CI providers

Discovery only reads `.github/workflows`, so a required context from Codecov, CircleCI, Vercel, or
a DCO app is not something it can find. `apply` therefore **keeps** any required context it did not
discover and says so, rather than writing the discovered set absolutely — which would silently
delete those checks and report success. `--prune` writes the exact discovered set, and is the
remedy when a context really is stale (a renamed or deleted job).

The same asymmetry is why `automerge-ok` returns `13` on such a repo until you run `apply`: it
cannot tell an external provider's context from a phantom one, so it fails closed and names them.

## Defaults, and why

- **`strict` (require branches up to date) is OFF.** With it on, any commit landing on the default
  branch makes an already-armed PR not-up-to-date, and GitHub's auto-update behavior for
  auto-merge PRs is not a documented guarantee (merge queue is the supported answer). The
  realistic outcome is an auto-merge that silently never fires — reintroducing exactly the manual
  touchpoint this exists to remove. `--strict` opts in.
- **`enforce_admins` is OFF.** Turning it on removes the owner's break-glass. With it off the
  *automated* path is still fully gated — `gh pr merge --auto` cannot fire on red — while a human
  keeps an explicit override. `--enforce-admins` opts in.
- **Required approving reviews stays at 0** when standing protection up. Requiring a PR enforces
  the feature-branch rule; inventing an approval requirement a repo never had would block the
  solo-maintainer loop entirely.

## The runtime guard

`/implement-issue` step 10 asks `automerge-ok` **before** arming, because arming blind is how a
repo ends up merging on nothing. The exit codes are a stable machine contract:

| Code | Meaning |
|---|---|
| `0` | safe — auto-merge enabled **and** required checks configured |
| `10` | `allow_auto_merge` is off — nothing to arm |
| `11` | CI exists but **no** required checks — arming would gate nothing |
| `12` | no PR-triggered CI at all — `--auto` would merge *immediately* |
| `13` | a required context **no workflow reports** — an armed PR would wait forever |
| `14` | a **discovered job is not required** — auto-merge could land a red build |
| `20` | live state unreadable — **fail closed**, never assume safe |

Codes `13` and `14` are the two drift directions, and the guard checks **both** — it runs the same
comparison `status` does, so it can never be shallower than the report. `13` is the renamed-job
case (arming a PR that can never merge is worse than not arming it); `14` is a job that exists but
gates nothing, which would let auto-merge land a red build — the exact hole this all exists to
close.

`baseline repo merge-flag` prints the `gh pr merge` flag the repo actually allows. Squash, merge,
and rebase are three independently-configurable settings, so a hardcoded `--squash` is simply
rejected wherever squash merging is disabled — the guard would say "safe" and the merge would
still fail. It exits `15` when no method is enabled at all.

Code `12` matters more than it looks: GitHub refuses to *queue* a PR that could merge right now,
so `gh pr merge --auto` on a check-less repo is a plain merge wearing an auto-merge label. The
guard refuses and lets the operator decide.

## Catching the drift early: `required-drift` (#122)

The guard above is correct but **late**. It runs at merge time, so the first anyone hears of a
newly added job staying non-required is a refused arm and a manual detour — and until someone
notices, auto-merge is simply unavailable. `roadmap-e2e` (added by PR #111) and `session-currency`
(PR #121) each sat ungated for several PRs that way.

`baseline repo required-drift` asks the **same** question early enough for the fix to be one
command — on the **default branch**, the moment the job lands there, rather than at the next
attempted merge. (It used to hard-fail on the *pull request* that introduced the job. That was
earlier still, and it is what created the phantom-context trap described in *"Which event asks the
question"* below: the only way to green that PR was to require a context before the job existed.
The PR now gets the same finding as **advice**.)

| Code | Meaning |
|---|---|
| `0` | in sync — every discovered job is required (or the repo has no discoverable CI, per #24) |
| `14` | a **discovered job is not required** — names each one and the remedy |
| `20` | live state unreadable, **or** discovery contradicts it — **fail closed** |

It reuses `automerge-ok`'s numbers because it is the same question, so a code never means two
things — and it calls the same `ungated_contexts` comparison `status` and `automerge-ok` use, so
the lint can never be shallower than the guard it front-runs.

It is deliberately **narrow**. It does *not* fail on `allow_auto_merge` being off, on phantom
contexts, or on an external provider's context — those are different problems with different
remedies, and `status` already reports all of them.

`required-drift --porcelain` returns the **same exit codes** and prints only the drifted context
names, one per line, on stdout — no prose and, deliberately, no remedy. It exists so a caller can
name the drifted jobs without parsing the human text, and specifically so the PR arm below does not
repeat a remedy that is wrong for its branch (see *"Which event asks the question"*). It is the one
subcommand that accepts the flag; the others reject it rather than accept it inert.

### Why it reads a different endpoint

Its home is a CI step, which runs as `GITHUB_TOKEN` — and `administration` is not a grantable
workflow permission, so the admin-only `/branches/{branch}/protection` endpoint the other
subcommands use would `403` on every run. The ordinary `repos/{slug}/branches/{branch}` endpoint
needs only `contents: read` and carries the same `required_status_checks.contexts` (verified equal
against the admin endpoint over this repo's full context set). Its error model is also cleaner here: a
`404` means "no such branch", with none of the "no protection *or* no permission" ambiguity that
forces `read_protection` to probe `.permissions.admin`.

**One shape must never be misread.** A branch that is protected but whose context list is not
readable is classified `opaque` and fails closed at `20`. Read as "zero contexts required" it
would report *every* discovered job as drifted — a repo-wide false positive that fails every PR
and teaches the operator to ignore the lint. A genuinely **unprotected** branch (`protected:
false`) is different: that is an authoritative "nothing gates this", and it is real drift.

### The same classification, for a second consumer: `branch-required-contexts` (#115)

`/roadmap`'s release-health gate needs the same three-way answer for a different question — *does
CI exist on this branch at all?* Its previous evidence was the **Actions-only** workflow inventory,
so a CircleCI/Buildkite/Jenkins repo read as "no CI", the health condition was skipped, and the
release cut went out against a branch nobody had checked. Required status contexts are the
provider-agnostic evidence: GitHub does not care who reports one, so a declared context is a
declaration that CI exists here.

So the 200-body model above is now a **pure classifier with two consumers** — `read_branch`, which
owns the HTTP read, and the `branch-required-contexts` subcommand, which serves `/roadmap` from a
body the workflow already fetched:

```console
$ printf '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["ci"]}}}' \
    | repo-settings.sh branch-required-contexts
["ci"]
```

| Branch shape | Prints | Means |
|---|---|---|
| protected, contexts readable | `["…"]` | these contexts are declared |
| `protected: false`, or classic protection with checks off | `[]` | **authoritatively** nothing declared |
| ruleset-protected, unreadable list, or an unparseable body | `null` | **unknown** — fail closed |

The `[]` / `null` distinction is the whole safety property, and it is the same one that makes
`opaque` fail closed above. `[]` combined with zero Actions workflows is what lets a genuinely
CI-less repo release (#24). `null` must never reach that arm — a ruleset-protected branch reports a
*real* empty `contexts` array, so a classifier that answered `[]` there would let `/roadmap` cut on
a branch whose protection it could not read.

It is **pure** (jq only — no `gh`, no auth, no network): the caller owns the read, exactly like
every other `/roadmap` predicate, which is also what lets the offline suite drive it with the same
fixtures `read_branch` uses. Splitting the classifier out rather than restating those three arms in
a second place is Golden Rule 4 — and the arm that would have rotted first is the ruleset one,
whose entire point is that it is not obvious.

**Rulesets are the sharp edge here.** This endpoint's `protection` object is the *legacy*
classic-protection view. A branch protected by a repository **ruleset** reports `protected: true`
with `protection.enabled: false` and `contexts: []` — a real, empty array. Accepting that as an
authoritative empty set would name every discovered job as ungated, on a repo where the job
printing the message is itself required: an unbreakable deadlock, since the fix cannot merge past
the check it broke. So `enabled: true` is required before the context list is believed; anything
else is `opaque`. (Classic protection with required checks merely switched *off* keeps
`enabled: true`, so it stays an actionable `14` rather than an unhelpful `20`.)

**A repo protected by BOTH classic protection and a ruleset is a known blind spot**: only the
classic contexts are visible here, so a job required solely by the ruleset could be reported as
ungated. Filed as a follow-up rather than guessed at — reading it needs the rules API.

**An empty discovery result is ambiguous, and is resolved by provenance.** "No discoverable CI"
and "there are workflow files and the parser saw none of them" produce the same empty set. Passing
both green is a fail-open; failing both is worse and wrong on this command's own terms, since a
repo may legitimately hold a schedule-only workflow while CircleCI supplies the required PR
context — and this command disclaims external-provider contexts.

So the tiebreak is **who reported the context**, read from the check runs on the branch and
attributed by `app.slug` — the same discriminator `roadmap-lib.sh branch-health` uses, and the same
*value*, which both read from `adb_actions_app_slug` in `common.sh`. GitHub Actions stamps
**`github-actions`**; the app's *owner* is `github`, and attributing against that near-miss is what
made this check silently find no Actions contexts at all (#179).

Provenance is **tri-state**, because `app` is required-but-nullable in GitHub's REST schema:

| `app.slug` | Meaning |
|---|---|
| `github-actions` | GitHub Actions — came from a workflow in this tree |
| any other non-empty value | an external provider (CircleCI, Vercel, a linter bot) |
| null / absent | **unknown** — not provably either, so the verdict fails closed |

| Discovery empty, and… | Verdict |
|---|---|
| no `.github/workflows` at all | `0` — no claim to contradict (#24, and external-only CI) |
| the required contexts were **reported by GitHub Actions** on this branch | `20` — they must have come from a workflow in this tree, so the parser has gone blind |
| a required context's producing app **cannot be identified** | `20` — an unattributable context is not evidence of external CI |
| the required contexts were **not** Actions-reported (CircleCI, Vercel, …) | `0` — someone else's contexts, out of scope by contract |
| provenance itself could not be read | `20` — refuse to pick a side |

The middle row is the fail-open this closes; the third is the false positive that closing it
naively would have created.

### Where it runs, and why not its own job

It is a **step inside the already-required `repo-settings` job**, not a job of its own. A new job
would itself be a newly added, non-required context: the fix would commit the very defect it
detects, and would gate nothing until someone ran `apply`. Riding an already-required job means it
enforces from the first merge.

This is one of the places where `scripts/selfcheck.sh` does **not** mirror CI: the local gate runs
the offline stub coverage in `scripts/check-repo-settings.sh`, and the *live* assertion is CI-only.
`selfcheck` is kept hermetic — its value is being a deterministic predictor of CI's *offline* half,
and a step whose verdict depends on network, auth and settings someone else can change would break
that. Recorded as D13 in `.ai-dev-baseline/decisions.md`, which also records what that reasoning
does *not* claim: a local `20 → SKIP` arm is possible and would catch drift before the push. It is a
preference for a hermetic gate, not an impossibility.

Since #257 there is a second, different reason a local green cannot stand in for CI, and it is not
about hermeticity at all: CI runs the offline suite on **two** hosted platforms per PR
(`ubuntu-26.04` and `macos-latest`) and a workstation is one of them. A **third**, `windows-latest`
under WSL2, runs on a weekly schedule rather than per-PR (#2) — and because its workflow has no
`pull_request` trigger, discovery below skips it, so it never becomes a required context. See
`docs/ci-runners.md` (D29, D38).

### When it fails

`baseline repo apply` adds the missing context, then **re-run the check** — it reads live state, so
it only clears once the setting actually changed. That is revalidation after a real state change,
not a flaky retry (`base/practices/ci-discipline.md`). If the job was *renamed* rather than added,
the old context is now also required-but-never-reported; `status` shows that direction and
`apply --prune` clears it.

**Applying from a PR branch makes the context required before the job exists on the default
branch.** Two consequences, and the second is the one to watch:

1. Any **other** open PR that predates the job will not report the new context and will wait —
   merge the default branch into those PRs once this one lands.
2. If this PR is then **abandoned unmerged**, the default branch is left requiring a context that
   nothing will ever report, which blocks *every* merge. That is the phantom deadlock
   `automerge-ok` code `13` exists to name, and clearing it needs `apply --prune` with an admin
   token — which CI does not have.

### Which event asks the question decides what the answer means (#165)

The window above is why this lint is wired as **two steps, not one**. `required-drift` discovers
jobs from the **checked-out tree** and reads required contexts from the **default branch**, so the
same command means two different things depending on which event ran it:

| Event | The two sides | So the verdict is | And the step |
|---|---|---|---|
| `push` to the default branch | same tree | a **fact** about the default branch | **hard-fails** (code `14`) |
| `pull_request` | different trees | a **prediction** about a merge that has not happened | **advises** (never fails on `14`) |

#122 hard-failed on the prediction, and the only way to make that PR green was `baseline repo apply`
from the PR branch — which is precisely how consequence 2 above gets created. **A guard whose only
remedy manufactures a deadlock is the wrong guard**, so the hard failure moved to the event where
the comparison is a fact.

**What this gives up, stated plainly:** a PR can now add a job that is red and non-required and
still merge. The backstop is the push arm — the default branch goes red the moment the job lands —
so the exposure is *"merged but not yet applied"* rather than *"never caught"*. That is a deliberate
trade (D48), not an oversight: the previous behaviour caught it earlier and, in catching it, created
a deadlock that needed an admin token to clear.

**`--porcelain` is what keeps the advisory honest.** The human code-`14` text ends in `baseline repo
apply`; an advisory that echoed it would hand a PR author the exact hazard this design removes. So
the PR arm asks for `required-drift --porcelain`, which prints **only the drifted context names on
stdout** — no prose, no remedy, same exit codes — and the workflow step writes the remedy that is
right for a PR: *wait for the merge*. The library stays read-only; the advisory surface
(`$GITHUB_STEP_SUMMARY`, a `::warning` annotation) is written by the step, and neither needs any
permission beyond the `contents: read` the workflow already declares.

Two properties of the advisory arm are load-bearing and easy to erode:

- **Only a proven `14` is softened.** A `20` — live state unreadable, discovery contradicting it, or
  a workflow file the parser could not read at all (#102) — still fails the PR. "Your PR predicts
  drift" and "the comparison could not be made" are different answers, and only the first is advice.
- **It cannot tell pre-existing drift from drift this PR introduces.** It compares the PR branch's
  whole tree against the live required set, so a name already drifted on the default branch appears
  here too. The advisory says so rather than implying the PR caused it.

`scripts/check-repo-settings.sh` pins this wiring structurally — two call sites, which event governs
each, and that the retired `github.ref` disjunct is gone — because swapping the two `if:` conditions
leaves every literal in place and inverts the whole design silently.

## The second guard: has review happened? (#134)

> Documented here because it is the other half of the same hand-off, but it is a **separate
> module** with no `baseline repo` surface — `repo-settings.sh` is repo *settings* bookkeeping and
> review state is per-PR. Reviewer *declaration* lives in `docs/roles-and-agents.md`.

`automerge-ok` answers *"will the checks gate this?"* — and that is **not** the same question as
*"has anyone reviewed it?"*. Auto-merge fires the instant the required status checks pass. An
async bot reviewer is not a check, and `required_conversation_resolution` only blocks on threads
that **already exist**; at arming time there are none. On PR #133 the gap was six minutes: opened
20:55:32, merged 20:56:01, five real bugs posted at 21:02:19.

So step 10 asks a **second**, PR-scoped guard before arming — `scripts/lib/pr-review.sh`, a
separate module because `repo-settings.sh` is repo *settings* bookkeeping and review state is
per-PR:

```bash
pr-review.sh gate --pr <number|url>    # prints the witnessed head SHA on 0
```

| Code | Meaning |
|---|---|
| `0` | every **declared** reviewer signalled a **clean pass** for the current head SHA — an `APPROVED` review at this SHA, or a `+1` proved newer than the moment this head arrived — or `bots = []` (no async reviewer). STDOUT is the head SHA |
| `16` | a declared reviewer has **not spoken** about this head SHA yet — do not arm; the operator merges after review. Note this is *silence*, not *dissatisfaction*: a reviewer that reviewed and was unhappy is `19` or `21` |
| `17` | the repo declares no `[reviewers] bots` — unknowable, **fail closed**. Declare them, or `bots = []` |
| `18` | `[reviewers] bots` is present but malformed — fix `agents.toml` |
| `19` | a declared reviewer left **`CHANGES_REQUESTED`** on this head SHA — address it and push |
| `21` | **review complete, attention required** — a declared reviewer left a `COMMENTED` review at this head, or a fresh issue comment. It has reviewed and is **not satisfied**; read what it said. There may be **no inline threads at all** |
| `20` | live state unreadable — **fail closed**, never assume reviewed |

Three properties are doing the real work:

- **"Submitted" is not "satisfied."** Only `APPROVED` — or a `+1` reaction proved newer than the
  moment this head arrived — counts as satisfied. **`CHANGES_REQUESTED` is `19`** and **`COMMENTED`
  is `21`**: both mean the reviewer spoke without being satisfied, and neither may arm. Nothing else
  catches this: with `required_approving_review_count: 0` GitHub will merge a PR whose only review
  says *do not merge*, and `required_conversation_resolution` gates on threads rather than on the
  verdict — so a reviewer that puts its findings in a review **body**, creating no inline threads,
  is invisible to every other guard. It is not a deadlock either: addressing the feedback pushes a
  commit, which moves the head SHA and gets re-reviewed.

  > **`COMMENTED` used to count, on a premise that was simply false (#167 §2).** The argument was
  > that the connector posts `COMMENTED` even on a clean pass, so waiting for `APPROVED` would
  > deadlock. It does not — on a clean pass it posts **no review object at all**, only a `+1`
  > (PRs #53/#54/#66/#83/#88, live). The deadlock never existed, and the branch it justified let
  > body-only findings authorize an auto-merge.

- **It reads every surface a reviewer can speak on, not just reviews.** Reviews are matched by head
  SHA; issue comments and `+1` reactions are matched by timestamp against the **server's** record of
  when the head ref became this SHA (the repository activity API — never the head commit's
  committer date, which is client-supplied). An unprovable signal is `16`, never `0`.

- **It is anchored to a commit, not to the PR.** A review of an earlier push is not a review of
  what is about to merge. On a 0 the caller passes the witnessed SHA to `gh pr merge
  --match-head-commit`, so a commit landing between the check and the arm makes GitHub reject the
  arm rather than merge an unreviewed tip.
- **`17`/`18` are not `20`.** All three refuse to arm, but the operator action differs — *declare
  your reviewers*, *fix the malformed value*, *retry / fix permissions* — and one code for three
  fixes sends people to the wrong one. That is the same one-code-per-remedy rule `automerge-ok`
  already follows (10 enable auto-merge, 11 add required checks, 12 add CI, …). Which reviewers a
  repo has is configuration, and its home is `[reviewers] bots` (see `docs/roles-and-agents.md`),
  not a guess from PR history.

**On a bot-reviewed repo this guard skips arming when `/implement-issue` asks it, by design.**
Step 10 runs seconds after `gh pr create`, so a reviewer that takes minutes has not spoken yet and
the answer is `16`. A repo with no async reviewer sets `bots = []` and is unaffected.

That is a statement about **when the question is asked**, not about the guard's ceiling — and the
distinction became load-bearing with #167. Asked *later*, on a head the reviewer has since passed
cleanly, the same guard returns `0` and the arm is safe. Three of its answers now mean the reviewer
**did** review: `0` clean, `19` changes requested, `21` reviewed-and-not-satisfied. Only `16` means
nobody has spoken.

What has **not** changed is that nothing re-asks: `/implement-issue` calls the guard exactly once
and no path re-arms afterwards (#168). So on a bot-reviewed repo an unattended run still ends with
the PR unarmed — the operator merges, or re-runs the guard once the review has landed.

**The waiting half shipped with #49; the arming half did not.** `/resolve-pr-threads <PR#> --watch`
(`scripts/lib/pr-watch.sh`) waits for the reviewer in a shell poll loop and resolves any findings,
but does not arm auto-merge afterwards — so unattended arming remains suspended on such repos.

> **This guard used to read one surface of three, and wedged at `16` forever on two of them —
> fixed by #167.** The connector signals "reviewed, nothing found" with a `+1` reaction and posts
> **no review object at all**, so a clean pass never satisfied a guard that read only
> `pulls/N/reviews`: auto-merge stayed unarmed on precisely the PRs that were cleanest.
>
> **The wider shape was worse than "clean passes only".** With a Codex Cloud environment the
> connector runs as a *task* and posts a **single issue comment** — no review, no threads, no
> reaction — so on a repo configured that way the guard returned `16` on **every** PR, and #87/#134's
> unattended arming was silently dead, disabled by a vendor-side setting nobody in the repo changed.
> Both shapes were observed live on this repo within one day (PR #166 at 08:01 vs PR #178 at 19:30).
>
> `gate` now reads reviews, issue comments **and** reactions, and shares one per-reviewer evidence
> classifier with `pr-watch.sh` so the two can no longer disagree about what a signal means (#167)
> or about how many reviewers must have produced one (#185).
>
> **This did not restore unattended arming, and nothing here claims it did.** `/implement-issue`
> asks the gate exactly **once**, seconds after `gh pr create`, when an async reviewer has
> definitionally not responded — and no path re-arms afterwards. What changed is that the gate now
> returns the **right answer when asked**: a re-run, or a manual invocation, after the reviewer has
> finished can arm. Automatic re-arming is **#168**, an open owner decision.

## Operating notes

- **Re-run `apply` after any change to a CI job name.** A renamed job leaves the old context
  required (blocking every PR) and the new one ungated. `status` is the only place that becomes
  visible — it reports drift in both directions and exits nonzero.
- **A newly added context does not apply retroactively.** An already-open PR predating it will
  never report that check; merge the default branch in so the new job runs.
- **No admin permission?** `apply` changes nothing and prints the exact commands for someone who
  has it. It never blocks the run.
- **No CI?** The checks write is skipped and `apply` still succeeds (#24); `automerge-ok` then
  returns `12` so nothing is armed.
- **Auto-merge still waits on `required_conversation_resolution`.** An unresolved bot thread holds
  an armed PR indefinitely — `/resolve-pr-threads` clears it (#49 automates that leg).

See `.ai-dev-baseline/decisions.md` (D9) for the recorded defaults, and
`base/workflows/implement-issue.md` step 10 for the calling contract.
