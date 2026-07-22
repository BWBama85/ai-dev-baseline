<!-- GENERATED FILE — do not edit by hand.
     Source: base/practices/*.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->

# Global engineering practices

Your global engineering practices, shared across every project via
[ai-dev-baseline](https://github.com/BWBama85/ai-dev-baseline).
A project-specific doc in the current repo overrides anything here
(see base/practices/00-index.md for precedence).

---

# CI discipline

**A failing CI job is a signal to diagnose, not a button to re-press.**

Never re-run a failed or "flaky" CI job as a first resort. Re-running burns CI
minutes, hides the root cause, and — if it happens to go green — ships a latent
bug.

## Protocol when CI fails

1. **Read the failure log.** Get the actual error, not the summary status.
2. **Classify: flaky or real.** A real failure reproduces; a flaky one is a
   timing/order/resource/network artifact. Say which, with evidence.
3. **If real → fix the root cause.** Then push the fix. Do not re-run against the
   old commit.
4. **If genuinely flaky →** file an issue to de-flake it (name the suspected
   cause: ordering, a fixed date aging out, a timeout, a shared fixture), *then*
   re-run. A flaky test you re-ran past is technical debt you now owe an issue.
5. **Never merge on a flaky re-run alone.** Green-by-retry is not green.

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


---

# Root-cause debugging

**Trace to a definitive root cause with evidence — never ship a guess.**

"Probably X" is a hypothesis, not a diagnosis. A fix built on an unproven cause
is a coin flip.

## Protocol

1. **Reproduce.** Get the failure to happen on demand — a failing test, a query,
   a log slice, a repro script. If you can't reproduce it, you can't prove you
   fixed it.
2. **Prove the cause.** Use logs, DB/state queries, diffs, timestamps, and where
   possible a **failing regression test written before the fix.** Cite concrete
   evidence (`file:line`, a log line, a row, a hash) — not a narrative.
3. **Symptom location ≠ cause location.** The line that throws is often not the
   line that's wrong. Grep for the *class* of the bug, not just the one instance —
   if one helper has it, its siblings may too.
4. **Rule out your own state first.** Before blaming a platform or library:
   - Is the running/deployed build behind the source? A deployed environment can
     lag the default branch behind a release gate — check the deployed version vs.
     the latest tag before filing a "platform bug."
   - Is a stale fixture, cache, or local migration masking the real behavior?
5. **Fix the cause, add the regression test, ship via the normal PR + gates path.**
   The test that reproduced the bug in step 2 is now the test that guards it.
6. **File follow-ups.** If the investigation surfaces a broader class or a
   systemic gap, file a tracked issue (see `issues-and-scope.md`).

## Why

The strongest debugging sessions trace incidents to a provable root cause —
dead-letter queues to an overload source, a poisoned value to the exact commit
that leaked it. The weak ones guess and patch. Make evidence the default and the
fix follows cleanly.


---

# Git and pull requests

## Branching and shipping

- **Never push directly to the default branch.** All work lands via a feature
  branch and a PR with CI green. Branch off the **default branch**, not off the
  current feature branch.
- **One branch per task.** Don't open a second PR for a tangential fix discovered
  mid-task — fold it into the same branch. To refresh an out-of-date PR, merge the
  default branch **in**; do not force-push a rebase over review history.
- **Never `--no-verify`.** Fix hook/gate failures at the root; don't bypass them.

## Destructive git

Never run destructive git without an **explicit** ask from the owner:

- `git reset --hard`, `git push --force` / `--force-with-lease`
- `git clean -fd`
- deleting branches or tags (except the merged-branch cleanup sweep below, which
  only ever deletes branches already merged into the default branch)

## PR body hygiene

- **Closing keywords auto-close on merge.** `Closes #N` / `Fixes #N` / `Resolves
  #N` **anywhere** in a PR body (prose, checklist, table) closes that issue when
  the PR merges. Use them only for issues this PR fully resolves. For partial work
  use **`Refs #N`** — and never write a closing keyword "illustratively," it will
  still fire.
- Follow the project's commit/PR conventions (semantic subject, co-author
  trailer, milestone/labels) when it has them.

## Branch cleanup — sweep, don't dribble

When asked to clean up after a merge, **sweep every merged branch, not just the
one from the current task.** A cleanup that deletes only the current branch and
leaves dozens of stale merged branches behind is a failed cleanup.

- Enumerate merged branches: `git branch --merged <default> | grep -v '^\*\|<default>$'`
  for local, and the equivalent for `origin` when remote cleanup is wanted.
- **Name each branch explicitly** in the delete command. Vague phrasing like
  "clean up" or "get rid of it" can be blocked by command-safety gating because no
  branch is named — passing the explicit branch list avoids that.
- Only ever delete branches **already merged** into the default branch. Never
  delete unmerged work.

## Why

These rules encode two recurring frictions: cleanup skills that scoped too
narrowly and left 30+ merged branches behind, and safety gating that blocked
branch deletion when the branch wasn't named. Sweeping all merged branches and
naming each one fixes both.


---

# Handling the unknown

**When you meet something the baseline doesn't model, do not improvise a one-off.**
Classify it, put it in that bucket's one prescribed home, and record the decision.

The baseline defines the *known* — practices, workflows, gates for known stacks. The
moment an agent hits something it *doesn't* cover (an unfamiliar toolchain, gate, config,
convention, role setup, doc shape, or tool), improvisation is where drift is born: two
agents, two runs, or two similar projects organize the *same* unknown two *different*
ways. A deterministic protocol makes the same unknown land the same way every time,
regardless of which agent is driving.

## Protocol: classify → place → record → (when unsure) escalate

Classify the unknown into **exactly one** bucket, then act as that bucket prescribes:

1. **General** — many projects would hit or want this. → **File a baseline issue** so it
   becomes a shared capability, and as a *stopgap* use the relevant supported config
   surface if one fits (e.g. a missing gate command → `agents.toml [gates]`). Never a
   bespoke local fix others can't inherit. If no supported surface fits the gap, escalate
   (bucket 4) rather than inventing a new home.
2. **Project-specific delta** — legitimately unique to this repo. → Record it in the
   **prescribed home for its category** (table below), never scattered or ad-hoc.
3. **Deviation** — the project deliberately contradicts a baseline rule. → Allowed, but
   **recorded explicitly** as a `DEVIATION` with `{baseline-rule, reason}`. Never a silent
   fork.
4. **Ambiguous / can't classify confidently** — → **STOP and ask the owner** a concrete
   question. Improvisation is how two projects diverge; escalation is the release valve
   that keeps the set honest (the completion-contract discipline, applied to *organization*).

## Prescribed homes (one legal home per category)

Placement is **forced, not the agent's choice.** These are the homes for the categories
the baseline supports *today*; anything outside them is drift. A category with no home
yet is itself an escalation (bucket 4) — say so and ask, don't invent a home.

| Category of project-specific content | One prescribed home |
|---|---|
| Quality-gate command (different/extra/disabled) | `agents.toml [gates]` (`""` disables) |
| Role assignment (who is primary / reviews / …) | `agents.toml [roles]` |
| Project rule / convention / stack boundary | the repo's own root doc (`CLAUDE.md` / `AGENTS.md` / `GEMINI.md`) |
| Custom gate *policy* (order, conditional) | the repo's own `.claude/scripts/precommit-gate.sh` |
| Workflow that genuinely diverges | a project-scoped skill shadowing the global one |
| Deviation from a baseline rule | a `DEVIATION` entry in the decision log |
| General gap (would help many projects) | a **baseline issue** + supported stopgap surface |

See `docs/per-project-overrides.md` for the override surfaces and
`docs/roles-and-agents.md` for `agents.toml`.

## Record every decision

Keep a per-project decision log at **`.ai-dev-baseline/decisions.md`** — one tracked,
agent-neutral file (not under `.claude/`, because the protocol is cross-agent). It makes
any residual divergence visible, auditable, and reviewable: if two projects handled the
same unknown differently, the records make it findable. Append one entry per unknown:

```
## <id> — <short title>
- date:      YYYY-MM-DD
- category:  general | project-delta | deviation
- unknown:   what the baseline didn't cover
- decision:  what you did
- placement: the prescribed home it landed in (path / table / issue #)
- reason:    why this classification and placement
- baseline-issue: #N   (for a "general" gap; else "n/a")
```

A **deviation** adds the fields that make it a deliberate, reviewable fork — never silent:

```
## <id> — DEVIATION: <short title>
- date:          YYYY-MM-DD
- category:      deviation
- baseline-rule: the exact baseline rule being contradicted
- conflict:      the project requirement that forces the deviation
- scope:         where it applies (paths / workflows)
- reason:        why the deviation is justified
```

## Rules

- **The only legitimate homes for project-specific content are the prescribed ones.**
  Anything living elsewhere is drift.
- **Never invent a new home to avoid asking.** A category with no prescribed home is
  bucket 4 (escalate), not license to improvise.
- **A general gap always earns a filed issue** (`issues-and-scope.md`), not just a local
  stopgap — the stopgap is temporary; the issue is how everyone eventually inherits the fix.
- **Record before you move on.** An unrecorded decision is an invisible divergence.

## Why

The baseline removes drift by giving every known thing one home. Its blind spot is the
*unknown* — and an unhandled unknown is handled by improvisation, which is drift by
another name. A deterministic classify → place → record → escalate protocol closes that
blind spot: the same unknown lands the same way every time, and the few genuinely
ambiguous cases surface to the owner instead of silently forking two projects apart.


---

# Out-of-scope work always becomes a tracked issue

The moment **anything** is deferred, declared out of scope, or punted "for later"
during a task, it is owed a tracked issue in the same run — filed **before** you
call the work done.

This includes, without exception:

- Slices you cut because the work was too large for one PR.
- A parent issue's own **"Out of scope" / "Future" / "Deferred"** list. That list
  evaporates into a *closed* issue when the PR merges, so it must be re-homed into
  open issues. The parent listing its non-goals is **not** tracking.
- Anything a reviewer (human or bot) or a gap-analysis pass flagged and you
  resolved by **deferring** rather than fixing.
- Test/infra gaps you knowingly left.

## Rules

- **A PR-body note is not tracking.** It falls out of view the moment the issue
  closes on merge. Only an open issue tracks deferred work.
- **File by default; do not ask.** Filing is the default action, then inform the
  owner what you filed. (If the owner explicitly says "don't file X," honor that.)
- **Link both ways.** Comment the new issue on the parent (the link survives after
  the parent closes) and reference it from the PR.
- **Place it correctly.** If the project has a release-goal / milestone
  convention, follow it (a direct dependency of the current release goal is
  release-slated; tangential or post-deploy work goes to the backlog). Otherwise
  default to the project's backlog. Never leave a new issue milestone-less if the
  project uses milestones.

## Why

Deferred work that lives only in prose is deferred work that gets lost. Filing it
as a tracked issue — automatically, every time — is the single most-missed
discipline and the one that most reliably prevents silent scope loss.


---

# Logging and secrets

## Structured, correlated logs

- Prefer structured logging over ad-hoc prints in production code paths. Include
  a correlation id (a run id / request id) where the project has one, so a single
  operation's lines can be reconstructed after the fact.
- Every owner-visible mutation in an admin/privileged path emits **one** audit
  line with the actor and the key fields, so "who changed what" is answerable
  without re-running the code.

## Never log secrets

Never emit, in logs or error output:

- API keys, tokens, full JWTs, session cookies, passwords.
- Authorization headers or full request headers that may carry credentials.
- Full request/response bodies that may contain any of the above.

When logging an error that may wrap a fetch `Response` or a credential-bearing
object, log `{ err: err.message }` — not the whole object. Redact before you
print, not after someone finds it in a log.

## Why

Secrets in logs are a durable leak: logs get shipped, cached, and indexed. A
redaction-by-default posture and one clean audit line per mutation are the
portable minimum; a given project may tighten them further.


---

# Verify repo scope before starting

Before implementing an issue, fixing a bug from a ticket, or acting on any
reference, **confirm it belongs to _this_ repository.**

## Check

- `gh issue view <n>` in the current repo. If it 404s, or the body clearly
  describes a different codebase (wrong file paths, wrong stack, wrong product),
  it probably lives in another repo.
- When given several issue numbers, verify each — a batch can span repos.

## If there's a mismatch

**Stop and say which repo the work maps to.** Do not guess, and do not start
implementing against the wrong codebase. One misrouted issue can waste an entire
session of exploration before the mismatch surfaces.

## Why

A whole session was once lost because the requested issues lived in a different
repository than the one that was checked out. A three-second `gh issue view`
up front fails fast instead.


---

# Self-review before shipping

Before opening a PR, run a **dedicated self-review pass focused on real bugs** —
separate from writing the code, and separate from any independent reviewer.

This is a **mandatory gate**, not a victory lap. It repeatedly catches genuine
landmines in freshly generated code before they reach a reviewer or production.

## What to look for

- **Edge cases:** empty input, single element, zero, negative, max, unicode.
- **Escaping / encoding:** shell, SQL, JSON, HTML, regex — anywhere a value
  crosses a syntax boundary. JS string-escaping bugs are common.
- **Binary / encoding corruption:** generated files with stray NUL bytes, wrong
  line endings, missing final newline, or a dropped pragma/shebang.
- **Cascade / cancellation effects:** does one change trigger a chain (a cancel
  guard, a cascading delete, a retry storm)? Trace it.
- **Off-by-one and boundary conditions** in loops, slices, ranges, pagination.
- **Idempotency:** can this run twice without corrupting state? (Queue consumers,
  migrations, cron, scripts especially.)
- **Resource leaks:** unclosed handles, unbounded growth, missing timeouts.

## How

List each finding explicitly and either fix it or consciously disposition it with
a reason — before proceeding to push. "I read it over and it looks fine" is not a
self-review; naming what you checked is.

## Why

An explicit self-review pass has repeatedly caught real bugs — a cascade-cancel
guard bug, a JS-escaping bug, NUL-byte-corrupted generated files — that a casual
read missed. Making it a fixed step means it never gets skipped when a task runs
long or gets interrupted.


---

# Shell discipline

The interactive shell is commonly **zsh** (macOS default) and **bash** on Linux
CI. Write commands that work in both, and default to POSIX `sh` semantics unless
you are running a script with an explicit `#!/usr/bin/env bash` shebang.

## Rules

- **One command, one purpose.** Prefer several simple calls over a long
  `A && B && C && D` chain. Compound chains are harder to permission-approve,
  harder to attribute when one link fails, and more likely to be denied outright
  by command-safety gating. Run steps separately unless they are genuinely one
  atomic operation.
- **No bashisms in `sh`/inline contexts.** Bash arrays, `[[ … ]]` where `[ … ]`
  works, `<(…)` process substitution, `${var^^}` case tricks, and `source`-ing
  interactive rc idioms all break or behave differently under zsh/sh. If you need
  bash features, put them in a real `bash` script, not a one-liner.
- **Quote every expansion.** `"$path"`, `"${arr[@]}"`. An unquoted variable
  containing a space or a glob char (`* ? [`) will word-split or glob-expand and
  silently do the wrong thing.
- **Don't assume PATH.** Non-interactive shells may not have your rc's PATH. If a
  brew/user-installed tool might be missing, export the prefix explicitly once
  (e.g. `export PATH="/opt/homebrew/bin:$PATH"`) rather than relying on login
  shell setup.
- **Globs and `find`:** when a glob may match nothing, guard it (`shopt -s
  nullglob` in bash, or iterate `find … -print0 | while IFS= read -r -d ''`).
  Don't let an unmatched glob leak through as a literal argument.

## Why

Shell-environment friction — bash array expansions and globs failing under zsh,
exit-127 sourcing errors, and blocked compound commands — is a recurring source
of wasted retries. Defaulting to portable, single-purpose commands eliminates it
before it starts.


---

# Verify mutable state before asserting it

**Never state or act on volatile external status from memory, context, or a stale
local ref. Re-check the authoritative source at the moment you assert or act.**

Mutable external state — a PR's open/merged/closed status, whether a branch is
merged, an issue's open/closed, CI green/red — **changes out from under you.**
Narrating or acting on it from an earlier turn's memory, or from an unsynced local
git ref, is a correctness bug: it produces flatly-wrong claims ("PR #N is still
open" when it merged an hour ago) and destroys trust.

## Immutable vs mutable

Distinguish the two, and treat them differently:

- **Immutable facts** — code structure, file locations, function names, project
  conventions. Safe to recall from context; they don't change between the moment
  you read them and the moment you use them.
- **Mutable state** — PR/branch/issue/CI status, remote refs, deploy versions.
  **Always re-check**, however confident memory feels. Re-checking costs one `gh`
  or `git` call; a wrong assertion costs the whole session's trust.

## Re-check at the point of assertion

Query the authoritative source *immediately before* you assert or act on it — not
a `git branch --merged` against an unsynced local default, not a value you
remember from earlier in the session:

- **PR status** → `gh pr view <N> --json state,mergedAt` (not memory, not a stale
  local ref).
- **Issue status** → `gh issue view <N> --json state`.
- **Branch merged?** → a **freshly-fetched** `git fetch --prune` then
  `git branch --merged origin/<default>` (classify against the remote tip, not a
  lagging local branch).
- **CI status** → `gh run` / `gh pr checks <N>`.

If you are about to perform an **outward-facing mutation** (delete a branch, reply
on a thread, merge, comment "done"), re-check the state that gates it right before
the mutation — a status captured at the start of a long task may have changed by
the time you act on it.

## Why

Repeated stale-state assertions — narrating a merged PR as "still open" from a
stale local `main` or from earlier-in-session memory — are a recurring correctness
bug. A wrong claim about volatile state is worse than a slow one: it looks
authoritative and gets acted on. Re-checking the source of truth at the moment of
use makes the claim correct by construction.


---

_Generated from base/practices. The multi-agent role model lives in base/roles.md._
