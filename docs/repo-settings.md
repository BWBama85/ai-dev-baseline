# Repo settings — handing PR merges to GitHub

`baseline repo` sets the two GitHub settings that let a PR merge itself once it is genuinely
ready, so the operator stops clicking Merge on every green PR (issue #87).

It is a small, sharply-bounded command: it reads `.github/workflows` and writes exactly two
settings. It never merges, reviews, tags, releases, or deploys — those stay project-owned (#3).

```bash
baseline repo checks        # the check contexts it would require, one per line
baseline repo status        # desired vs live, with drift named (nonzero = drift)
baseline repo apply         # required checks FIRST, then allow_auto_merge
baseline repo automerge-ok  # the guard /implement-issue asks before arming auto-merge
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
- a job whose `name:` interpolates `${{ … }}` — not statically knowable.

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
| `20` | live state unreadable — **fail closed**, never assume safe |

Code `12` matters more than it looks: GitHub refuses to *queue* a PR that could merge right now,
so `gh pr merge --auto` on a check-less repo is a plain merge wearing an auto-merge label. The
guard refuses and lets the operator decide.

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
