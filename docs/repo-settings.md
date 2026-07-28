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

Known limitation: discovery reads two-space-indented YAML (what `actions/*` templates and every
real workflow in the wild use). A workflow this parser cannot read contributes no contexts and
says so loudly on stderr — it never silently under-requires.

Discovery is scoped to the `jobs:` block, which is not a nicety: `on:` puts `push:` and
`pull_request:` at the *same* two-space indent as job keys, so a whole-file indent scan harvests
those two as jobs and requires contexts that can never report. This repo's own `ci.yml` is exactly
that shape.

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
command, on the PR that introduces the job:

| Code | Meaning |
|---|---|
| `0` | in sync — every discovered job is required (or the repo has no discoverable CI, per #24) |
| `14` | a **discovered job is not required** — names each one and the remedy |
| `20` | live state unreadable — **fail closed** |

It reuses `automerge-ok`'s numbers because it is the same question, so a code never means two
things — and it calls the same `ungated_contexts` comparison `status` and `automerge-ok` use, so
the lint can never be shallower than the guard it front-runs.

It is deliberately **narrow**. It does *not* fail on `allow_auto_merge` being off, on phantom
contexts, or on an external provider's context — those are different problems with different
remedies, and `status` already reports all of them.

### Why it reads a different endpoint

Its home is a CI step, which runs as `GITHUB_TOKEN` — and `administration` is not a grantable
workflow permission, so the admin-only `/branches/{branch}/protection` endpoint the other
subcommands use would `403` on every run. The ordinary `repos/{slug}/branches/{branch}` endpoint
needs only `contents: read` and carries the same `required_status_checks.contexts` (verified equal
against the admin endpoint over this repo's 25 contexts). Its error model is also cleaner here: a
`404` means "no such branch", with none of the "no protection *or* no permission" ambiguity that
forces `read_protection` to probe `.permissions.admin`.

**One shape must never be misread.** A branch that is protected but whose context list is not
readable is classified `opaque` and fails closed at `20`. Read as "zero contexts required" it
would report *every* discovered job as drifted — a repo-wide false positive that fails every PR
and teaches the operator to ignore the lint. A genuinely **unprotected** branch (`protected:
false`) is different: that is an authoritative "nothing gates this", and it is real drift.

### Where it runs, and why not its own job

It is a **step inside the already-required `repo-settings` job**, not a job of its own. A new job
would itself be a newly added, non-required context: the fix would commit the very defect it
detects, and would gate nothing until someone ran `apply`. Riding an already-required job means it
enforces from the first merge.

This is the one place where `scripts/selfcheck.sh` does **not** mirror CI: the local gate runs the
offline stub coverage in `scripts/check-repo-settings.sh`, and the *live* assertion is CI-only.
Making selfcheck perform it would either fail on every offline run or pass when it could not read
— and treating an unreadable live check as a local success is precisely the fail-open this
codebase refuses. Recorded as D13 in `.ai-dev-baseline/decisions.md`.

### When it fails

`baseline repo apply` adds the missing context, then **re-run the check** — it reads live state, so
it only clears once the setting actually changed. That is revalidation after a real state change,
not a flaky retry (`base/practices/ci-discipline.md`). If the job was *renamed* rather than added,
the old context is now also required-but-never-reported; `status` shows that direction and
`apply --prune` clears it.

Note the consequence of applying from a PR branch: the new context becomes required immediately,
so any **other** open PR that predates the job will not report it and will wait. Merge the default
branch into those PRs once this one lands.

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
| `0` | every **declared** reviewer has reviewed the current head SHA — or `bots = []` (no async reviewer). STDOUT is the head SHA |
| `16` | a declared reviewer has **not** reviewed this head SHA — do not arm; the operator merges after review |
| `17` | the repo declares no `[reviewers] bots` — unknowable, **fail closed**. Declare them, or `bots = []` |
| `18` | `[reviewers] bots` is present but malformed — fix `agents.toml` |
| `19` | a declared reviewer left **`CHANGES_REQUESTED`** on this head SHA — address it and push |
| `20` | live state unreadable — **fail closed**, never assume reviewed |

Three properties are doing the real work:

- **"Submitted" is not "satisfied."** `APPROVED` and `COMMENTED` count — `COMMENTED` is what the
  Codex connector posts even on a clean pass, and holding out for an `APPROVED` a comment-only bot
  never sends would deadlock the gate. **`CHANGES_REQUESTED` does not count** (`19`). Nothing else
  catches it: with `required_approving_review_count: 0` GitHub will merge a PR whose only review
  says *do not merge*, and `required_conversation_resolution` gates on threads rather than on the
  verdict. It is not a deadlock either — addressing the feedback pushes a commit, which moves the
  head SHA and gets re-reviewed.

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

**On a bot-reviewed repo this guard skips arming, every time, by design.** Step 10 runs seconds
after `gh pr create`, so a reviewer that takes minutes has not reviewed yet. Unattended *arming*
is therefore suspended on such repos until **#49** adds the PR watch that waits for the review,
resolves its threads, and arms afterwards. A repo with no async reviewer sets `bots = []` and is
unaffected.

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
