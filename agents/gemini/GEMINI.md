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

### The ones that destroy work that was never committed

The commands above mostly move committed history, and the reflog usually gets it
back. These do not, and they are the ones most likely to be typed casually — as
"cleanup" after a test, or to undo an edit:

- **`git checkout -- <path>`** and **`git checkout <tree-ish> -- <path>`**
- **`git restore <path>`** (and `--staged` / `--worktree` / `-SW`, which widen it
  to the index as well)

  These overwrite the file **in place** from the index or a commit. Uncommitted
  edits were never turned into git objects, so there is no reflog entry, no
  dangling blob, and nothing for `git fsck` to find — the work is simply gone.
  One of these discarded ~40 minutes of unsaved work during a routine test.

- **`git stash drop`** / **`git stash clear`**

  Weaker but still bad: a stash entry *is* committed objects, so the dropped SHA
  is recoverable from the command's own output or `git fsck --unreachable`
  **until gc prunes it**. Recovery is possible, not guaranteed — treat it as loss.

**Prefer the non-destructive move.** `git stash push -- <path>` parks the change
instead of deleting it, and `git diff > /tmp/x.patch` keeps a copy. And when the
goal is to test something rather than to discard it, don't touch the tracked file
at all — see the negative-testing method in `self-review.md`.

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
  convention, follow it: newly *discovered* work defaults to the **backlog** — never
  the active release milestone; only a deliberate current-release requirement enters
  it. Freezing the release set that way is what keeps "done" reachable: an
  ever-growing set never converges. Detect the convention live rather than assuming
  it. Otherwise default to the project's backlog. Never leave a new issue
  milestone-less if the project uses milestones.

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

## The project may be larger or smaller than the git root

Do not assume the working directory **is** the git root, or that there is exactly
**one** root doc. Real repos break both, and tooling that assumes a tidy single-root
state either fails or silently operates on the wrong root. Watch for:

- **Working dir ≠ git root.** You may be several directories below the top level.
  Resolve the git root explicitly before acting on repo-wide state.
- **Nested repos.** A repo can be checked out *inside* another repo (a plugin under
  a site, a vendored checkout). Git operations from inside the inner repo act on the
  **inner** one — confirm that's the one you mean.
- **Untracked parent trees.** The git root can sit deep inside a larger project that
  is **entirely untracked** (e.g. a plugin at `.../wp-content/plugins/<repo>` inside
  a WordPress install). Git-aware tools see only the inner repo; the surrounding
  project is invisible to them.
- **Out-of-repo root docs.** A `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` referenced by
  relative path may live **above** the git root, outside any repo — real context that
  no git-aware command will surface. Layered/monorepo layouts also carry **multiple**
  in-tree root docs (one per package).

**When the shape is non-tidy, surface it — don't hard-fail and don't operate on the
wrong root.** State what you resolved, note what's outside your reach (the untracked
parent, the out-of-repo doc), and confirm the intended boundary before proceeding.
The shared `adb_repo_shape` primitive (`scripts/lib/common.sh`) reports these facts
(git-root vs working dir, nested-in, out-of-repo `foreign_doc`s, in-tree `extra_doc`s)
so tooling can tolerate the shape from one home rather than each re-deriving it;
`bin/agent-init` consumes it.

## Why

A whole session was once lost because the requested issues lived in a different
repository than the one that was checked out. A three-second `gh issue view`
up front fails fast instead. The same class of mistake — assuming a tidy single-root
layout — surfaced in a 4-project sweep (a plugin nested in an untracked WordPress
install with a second root doc outside the repo; a pnpm monorepo whose "project" is
several packages), which is why repo-shape awareness is part of scoping.


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

## A new guard is not done until it has been observed failing

This is not "test your code." It is the narrower claim that a **check** — a lint,
a gate, an assertion, a CI step — must be **seen going red** before you call it
done, on an input it is supposed to reject.

A guard's failure mode is **silence**. Ordinary code that breaks throws, returns
the wrong value, fails a test. A guard that breaks *passes*: it scans zero files,
matches zero lines, evaluates zero rules, and reports exactly what a clean run
reports. No existing test catches it, because every assertion still passes. So a
guard that cannot answer wrong is strictly worse than no guard — it costs CI time
and reports safety it never checked.

- **Prove it on the real superseded input**, not on a convenient one. A pattern
  that catches three of four spellings is green on the fourth. A negative pin
  written for a contiguous `[bot]$` matched neither of the two real idioms
  (`sed 's/\[bot\]$//'` and `sub("\\[bot\\]$"; "")`, where the bracket is always
  backslash-escaped) and shipped green while checking nothing.
- **Make the guard say what it checked**, not only whether it passed — the count
  of rules evaluated, files scanned, cases run. A zero is then visible in the log
  instead of indistinguishable from success.
- **Automate the observation where the set is closed.** If the guard's rules are
  enumerable, a harness that injects each rejectable input and asserts the guard
  goes red turns "I checked once" into a standing test. Where the set is open —
  an arbitrary future gate — this stays a discipline, not a mechanism, and saying
  so plainly is better than implying coverage that does not exist.

### Negative-test against a copy, never the live tree

To watch a check reject something, it needs a rejectable input — and the
temptation is to edit the real file, run the check, then put it back.

**Don't.** Copy the target into a temp dir and run the check against the copy.

Editing a tracked file to test a check that reads tracked files ends in `git
checkout -- <path>` or `git restore <path>` to "put it back", and if that file
also held uncommitted work, the work is gone with no reflog to recover it (see
`git-and-prs.md`). That exact sequence cost ~40 minutes of unsaved work. It is
also unnecessary: build the fixture — a temp dir, a throwaway git repo under
`mktemp -d`, a copy of the tree — and mutate that.

## Why

An explicit self-review pass has repeatedly caught real bugs — a cascade-cancel
guard bug, a JS-escaping bug, NUL-byte-corrupted generated files — that a casual
read missed. Making it a fixed step means it never gets skipped when a task runs
long or gets interrupted.

The guard rules are here for the same reason. Two guards shipped in one run
unable to fire — one negative pin that matched neither real spelling, one
identity predicate that normalized its two sides differently — and both were
caught only because the agent *chose* to negative-test. Nothing required it, and
nothing else would have noticed: a check that matches nothing is
indistinguishable from a check that found nothing wrong. The way that pin was
tested is why the copy rule sits beside it.


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
- **Quote every expansion.** `"$file"`, `"${arr[@]}"`. An unquoted variable
  containing a space or a glob char (`* ? [`) will word-split or glob-expand and
  silently do the wrong thing.
- **Never assign to a zsh-special name.** `path`, `fpath`, `cdpath`, `manpath`,
  `module_path` and `argv` are **bound to shell state** in zsh — `path` *is*
  `$PATH`. A loop like `read -r kind path key` therefore empties the search path
  on its first iteration, and every external command after it fails with
  "command not found". Under bash the same line is harmless, so this survives
  review and every bash-based test, then breaks on the default macOS shell. Pick
  a neutral name (`file`, `sfile`, `entry`) — and remember the rule applies to
  any snippet an agent executes, not just to `.sh` files.
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

- **PR / issue status** → see *"Render the sentence from the read, in one step"* below. Do **not**
  reach for a bare `gh issue view <N> --json state`: it flattens a `NOT_PLANNED` close into a plain
  "closed", which reads an *abandoned* issue as a *delivered* one.
- **Branch merged?** → a **freshly-fetched** `git fetch --prune` then
  `git branch --merged origin/<default>` (classify against the remote tip, not a
  lagging local branch).
- **CI status** → `gh run` / `gh pr checks <N>`.

If you are about to perform an **outward-facing mutation** (delete a branch, reply
on a thread, merge, comment "done"), re-check the state that gates it right before
the mutation — a status captured at the start of a long task may have changed by
the time you act on it.

## Automated hooks and gates are in scope too

This is not only about an agent's prose. **Any automated actor that gates a decision on
mutable external state must re-verify it live — a Stop hook, a CI gate, a script — not
just the agent narrating.** Mutable state is mutable regardless of who reads it. A hook
that concludes "the run is complete because a `prUrl` is recorded in a marker file" is
asserting a PR's open/merged/closed status from stored context, exactly what this practice
forbids: the PR may have been closed without merging since the value was written. Such a
hook must re-check the authoritative source (`gh pr view … --json state,mergedAt`) at the
moment it acts, and **fail closed** — when the live state can't be verified, it must NOT
fall back to trusting the stored value (that is the stale-state trust this practice exists
to remove); it holds the gate and surfaces the uncertainty.

## Render the sentence from the read, in one step

Re-reading is necessary but **not sufficient**: a value fetched into a variable can still go
stale before the sentence that quotes it, and a correct read can still be paraphrased into a
claim it never supported. So the read and the assertion are **one operation**, not two — the
`state-assert.sh` module's `observe` subcommand performs the read *and* renders the finished
sentence, e.g. `PR #137 was observed MERGED at 2026-07-28T05:22:27Z`. Each workflow carries the
invocation for its own agent; this document states the rule, not the path.

**Pass the printed line through unchanged.** Empty stdout means *say nothing about that
entity* — never fall back on a remembered value, which is exactly the trust this practice
removes. It fails closed: an unverifiable read prints nothing and exits non-zero.

**Observations are past-tense by construction, and that is not a style rule.** A read can only
support a claim about the moment it happened. "PR #137 **is still** open" and "the gate **will**
hold" are claims about the future that no read can support — the second one shipped, and the PR
merged 29 seconds later. State what was observed and when; if you need to claim a future effect,
name the *observed* fact that implies it (an exit code, an action taken) instead.

**One home per entity kind** — never re-derive another's model:

| Question | The one command that answers it |
|---|---|
| PR / issue state | `state-assert.sh observe pr\|issue <n>` |
| Is this branch merged? | `cleanup-lib.sh branch-verdict` (models squash/rebase, exact-head, containment) |
| Is the branch green? | `roadmap-lib.sh branch-health` (Checks API + commit-status API, fail-closed) |

## What is enforced, and what is not

Honesty about the boundary is part of the practice, so state it exactly rather than flatteringly.

**`observe` makes a stated status correct; it cannot make anyone state one.** Nothing couples its
exit code to an action, so on its own it renders optional narration. That gap was not theoretical:
it was exercised on 2026-07-29, with this practice loaded in context and a correct reading already
in hand — a cleanup report volunteered `(OPEN at 14:55:26Z)` for a PR that had merged fourteen
minutes earlier. The read happened. Quoting a stale one as narrative was the defect, and no
additional paragraph addresses an agent that read correctly and then wrote carelessly.

So the rule is enforced by a **third structural guard**, alongside the two that already work
because a wrong answer stops the machine:

| Guard | What its exit code gates |
|---|---|
| `pr-review.sh gate` | an actual `gh pr merge --auto` |
| `cleanup-lib.sh branch-verdict` | whether a branch is deleted |
| **`state-claim-gate.sh`** (Stop hook) | **the end of the turn** |

**The grammar it applies is small, and deliberately so** — a classifier over arbitrary English
would be theatre. `state-assert.sh lint` enforces exactly one rule:

> In prose, a STATUS word appearing in the same sentence as an issue/PR reference must itself be
> introduced by `was observed`.

The check is per **occurrence**, not per sentence, because the 2026-07-29 line carried a compliant
`was observed MERGED` clause *and* a stale `(OPEN at …)` clause — a sentence-level test finds the
template and passes the whole line. **Only prose declares** (the #117 rule, applied here): fenced
blocks, HTML comments, blockquotes and inline code spans are stripped before scanning, so quoting a
status or documenting this grammar never fires it. Ordinary English is carved out: `open a PR`,
`merged the branch` and `closed #195` are verbs, not claims, and words that collide too often with
ordinary prose (`draft`) are simply not in the token set. Straight quotes are **not** markup — only
a fence, a code span, a blockquote or an HTML comment declares nothing — because scare quotes and
genuine quotation are indistinguishable, and stripping them would let a real claim through.

**What is still NOT enforced, stated plainly:**

- **A Stop hook fires after the text has streamed.** It forces a correction; it can never prevent
  the claim. The reader may see the wrong sentence before the gate replaces it.
- **The grammar is small.** An unusual phrasing, a claim split across sentences, or a status
  asserted without any `#N` nearby all pass. Missing a claim is the accepted cost of not crying
  wolf — a gate that fires on ordinary prose gets worked around, and this one ships to every
  adopting repo.
- **It is Claude-side today.** The linter is agent-neutral shell; only the hook wiring is
  Claude-specific. Codex/Gemini equivalents ride the enforcement-hooks epic.

So the discipline still carries the rest, and it is the same sentence it always was: **do not
volunteer a status you did not just read.** Most status narration is unrequested — deleting it is
always correct and costs the reader nothing. If it is worth saying, it is worth one `observe` call,
and if that call fails, the honest output is silence.

## Why

Repeated stale-state assertions — narrating a merged PR as "still open" from a
stale local `main` or from earlier-in-session memory — are a recurring correctness
bug. A wrong claim about volatile state is worse than a slow one: it looks
authoritative and gets acted on. Re-checking the source of truth at the moment of
use makes the claim correct by construction.

Prose alone had already failed twice in one session with this practice loaded in context, which
is why the read-and-render step is a command rather than another paragraph — the same move that
turned the dependency-edge rule, the release-readiness ladder and `/cleanup`'s predicates from
remembered rules into tested code.


---

_Generated from base/practices. The multi-agent role model lives in base/roles.md._
