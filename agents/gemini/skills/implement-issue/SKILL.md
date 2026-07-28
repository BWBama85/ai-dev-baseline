---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/implement-issue.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: implement-issue
description: Implement a GitHub issue end-to-end — repo-scope check, role-assigned gap-analysis, auto-detected gates, self-review + assigned code review, then open a PR. Agent-neutral via agents.toml; stack-agnostic via gate auto-detection.
---

# /implement-issue

Implement GitHub issue(s) **#$ARGUMENTS** end-to-end. Run autonomously — only stop
if genuinely blocked. This skill is part of [ai-dev-baseline]; it is stack-agnostic
(gates are auto-detected) and agent-neutral (who does gap-analysis and review is
read from the repo's `agents.toml`; see `base/roles.md`).

**Multi-issue runs.** If `$ARGUMENTS` begins with more than one issue number
(whitespace/comma-separated), implement **all of them on one shared branch and one
PR**. Everything below operates over the whole set; the PR `Closes` each issue it
fully resolves and `Refs` any it only slices. A single number is the classic flow.

## Continuation invariant

**A turn that ends with an `issue-NN-*` branch checked out and no open PR is a bug.**

Enforced by `implement-issue-gate.sh` (a Stop hook) — it keeps the turn going until
the run opens a PR or declares itself blocked. Sub-step outputs (gap-analysis,
review findings) are **inputs to the next step, not deliverables**. If you feel
tempted to end the turn after a sub-step returns, you have hit the exact failure
mode this invariant prevents — keep going.

## State protocol

Two gitignored files under `.gemini/state/`:

- **`implement-issue-active.json`** — in-flight marker:
  ```json
  { "branch": "issue-NN-slug", "issue": "NN",
    "phase": "branched|implemented|gates_green|committed|code_reviewed|triaged|pushed|pr_opened|complete",
    "startedAt": "ISO-8601 UTC", "prUrl": "https://…/pull/N" }
  ```
  Written in step 5 (after the real branch exists — never before, or the gate's
  branch-mismatch guard silently disables the invariant). Each step updates
  `phase`. Step 10 writes `prUrl`. Multi-issue: `.issue` is the comma-joined list;
  `.branch` carries every number.
- **`implement-issue-blocked.json`** — written by *you* ONLY on a documented
  legitimate **post-branch** stop (gate escape clause; a **required review step that
  cannot complete** after retry + fallback, step 8; branch already exists on remote).
  Shape: `{"reason","phase","branch","issue"}` — `branch`/`issue` REQUIRED and must
  match the active marker (the Stop-hook gate no-ops unless a matching active marker
  exists). A gap-analysis stop is *pre-branch* — no marker exists yet to pair with,
  so surface it to the owner and stop cleanly (step 4); do **not** write this file.

Always stage marker writes inside `.gemini/state/` (`.marker.tmp` → `mv`) so the
rename is atomic. Preflight unconditionally clears stale state files.

## Roles (who does what)

Read the repo's `agents.toml` `[roles]` at preflight (fall back to the global
default at `~/.config/ai-dev-baseline/agents.toml`, then to built-in defaults):

- **`gap_analysis`** (default `codex`, or `""` to skip) — the pre-implementation
  adversarial pass in step 3.
- **`review`** (default `["claude"]`) — the code-review agents in step 8. Always
  ALSO do your own self-review (`base/practices/self-review.md`).

Resolve tokens to invocations via `base/roles.md`. The runtime helper
`bash "$HOME/.gemini/scripts/lib/role-dispatch.sh"` (`scripts/lib/role-dispatch.sh`) does the resolution + cross-agent
shelling for you — `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" resolve <role>` prints the token(s);
`bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke <role|agent>` (prompt on stdin) runs one agent's CLI and
returns its **clean final message** on stdout:

- `claude` — when Claude is the driving agent, review runs **in-process** with
  **model-invokable** tools only: `/simplify` (quality / reuse / simplification —
  it explicitly does **not** hunt bugs) **plus** an independent adversarial **bug**
  review by a Claude subagent (Agent tool, `general-purpose`). **Never model-invoke
  `/code-review`** — it carries `disable-model-invocation` (it can launch a billed
  cloud review, so the harness reserves it for humans) and the Skill tool rejects
  it. Treat `/code-review` only as an *optional* step the owner runs after the PR
  (like `/resolve-pr-threads` for bot threads).
- `codex` → `codex exec --cd <repo> -`; `gemini` → `agy -p`. `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke`
  wraps both, applies the **45-minute hang backstop**, and captures codex's
  `--output-last-message` so the reply is only the final message, never the
  exploration stream.

**Completion contract (delegated steps must terminate).** `gap_analysis`, `review`,
and any cross-agent / subagent dispatch MUST reach a terminal, *completed* state —
"advisory" is the standing of **completed** findings, never a license to skip the
**step**. Run each as a **single bounded call and wait for it to return** (process
exit for `codex exec`/`agy -p`/`claude -p`; the tool result for an Agent subagent).
**Never poll a background agent's output to infer whether it is "hung"** — the
outcome is the call returning, not the byte count growing. On timeout / error /
hang: kill it, **retry once**, then **fall back** to another agent the role lists or
a `general-purpose` Claude subagent running the same prompt — **except for
`gap_analysis`, which never substitutes another agent** (retry once, then report the
classified incompleteness and stop; see step 3). If nothing completes, the step
**failed** → block or surface (step 4 / step 8), never proceed on partial or empty
output. **Report any fallback that does fire prominently**, not as one ⚠️ line among
many. Full contract: `base/roles.md`.

## Important rules (from base/practices)

- **Verify repo scope first** (`repo-scope.md`) — confirm every issue belongs to
  THIS repo before touching code.
- **Out-of-scope work always becomes a tracked issue** (`issues-and-scope.md`),
  filed before close-out — never just a PR-body note, never ask first.
- **Self-review is mandatory** (`self-review.md`) before the PR.
- **Handle the unknown deterministically** (`handling-the-unknown.md`) — when the repo
  needs something the baseline doesn't model (a gate, convention, role setup, or a
  general gap), classify → place it in its one prescribed home → record it → or escalate;
  never improvise a one-off.
- **Never push to the default branch; feature branch + PR only** (`git-and-prs.md`).
- **Never `--no-verify`; never destructive git** without an explicit ask.
- **Advisory findings, required steps** — gap-analysis / review *findings* are
  advisory: you are the implementer and may disagree with a **completed** finding,
  documenting why in the PR. The *step* is **not** optional — a delegated agent that
  hangs, times out, or errors must be driven to completion (retry → fallback →
  block/surface per the completion contract above), never silently skipped or
  finished on partial output.
- **PATH:** brew tools (`gh`, `codex`) may be off PATH in non-interactive shells —
  export `/opt/homebrew/bin` once in preflight if `gh` is missing.

---

## Step-by-step playbook

### 1. Preflight

Parse the leading issue number(s) from `$ARGUMENTS` (bare integers, whitespace/
comma-separated; the first non-integer token starts prose hints). Never interpolate
`$ARGUMENTS` raw into a shell command.

```bash
read -r -a _toks <<< "$(printf '%s' "$ARGUMENTS" | tr ',' ' ')"
ISSUE_NUMS=()
for t in "${_toks[@]}"; do
  case "$t" in ''|*[!0-9]*) break ;; *) ISSUE_NUMS+=("$t") ;; esac
done
[ "${#ISSUE_NUMS[@]}" -eq 0 ] && { echo "ERROR: no issue number"; exit 1; }
ISSUE_NUM="${ISSUE_NUMS[0]}"
ISSUE_CSV="$(IFS=,; printf '%s' "${ISSUE_NUMS[*]}")"
ISSUE_DASH="$(IFS=-; printf '%s' "${ISSUE_NUMS[*]}")"
```

Ensure tooling on PATH for the whole session, then get to a **clean, current default
branch** — auto-syncing when that is *provably safe*, else erroring as before. Clear
stale state. Do **not** write the marker yet (step 5 owns it).

**Post-merge auto-sync (issue #17).** After a PR merges, the local clone is often left
on the now-merged branch with the default branch behind `origin` — which used to hard-
error here ("not on main") and force a manual `switch`/`pull`/`branch -d`. Instead,
when it is **provably safe**, this preflight brings you to a clean current default
branch automatically. "Provably safe" is strict — it **NEVER discards unmerged or
uncommitted work**:

- **Dirty tree → always a hard error** (as before). Uncommitted work is never
  provably safe; commit or stash it yourself.
- **On the default branch, merely behind `origin` → fast-forward** (`git pull
  --ff-only`). Local commits on the default branch (ahead/diverged) → hard error.
- **On another branch that is provably merged → switch to the default branch,
  fast-forward, and delete merged local branches whose upstream is gone.** "Provably
  merged" = the branch tip is an ancestor of `origin/<default>` **or** `gh` reports its
  PR merged (so squash/rebase merges count too). A branch that is **not** provably
  merged → hard error (that protects genuine in-progress work — auto-sync must never
  silently leave a branch you are still working).

Branch deletion uses `git branch -d` (safe/merged-only) and skips protected names; a
squash/rebase-merged branch that `-d` refuses is **left and reported**, never force-
deleted. Getting onto a clean current default is the goal; tidy deletion is a bonus.

```bash
command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v gh || { echo "MISSING:gh"; exit 1; }
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=main
# Dirty tree is never provably safe — hard error, as before (protects uncommitted work).
[ -z "$(git status --porcelain)" ] || { echo "ERROR: tree not clean — commit or stash first"; exit 1; }
git fetch --prune origin --quiet
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
PROTECTED='^(HEAD|'"$DEFAULT_BRANCH"'|main|master|develop|release/.*|hotfix/.*)$'

sync_default() {   # on the default branch: fast-forward if behind; error if ahead/diverged
  local counts ahead behind
  counts="$(git rev-list --left-right --count "$DEFAULT_BRANCH...origin/$DEFAULT_BRANCH" 2>/dev/null)" \
    || { echo "ERROR: cannot compare $DEFAULT_BRANCH with origin/$DEFAULT_BRANCH"; return 1; }
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"; behind="$(printf '%s' "$counts" | awk '{print $2}')"
  [ -n "$ahead" ] && [ -n "$behind" ] || { echo "ERROR: could not determine $DEFAULT_BRANCH sync state"; return 1; }
  if [ "$ahead" -ne 0 ]; then echo "ERROR: local $DEFAULT_BRANCH has unpushed commits — reconcile manually"; return 1; fi
  [ "$behind" -eq 0 ] || git pull --ff-only origin "$DEFAULT_BRANCH" --quiet
}

if [ "$CURRENT" = "$DEFAULT_BRANCH" ]; then
  sync_default || exit 1
else
  # Provably merged? ancestor of origin/<default> (merge-commit / rebase-ff), OR gh reports a
  # merged PR whose head SHA is EXACTLY this tip (covers squash/rebase). Requiring the SHA to
  # match means a *reused* branch name carrying new, unmerged commits is NOT treated as merged,
  # so auto-sync never switches away from genuine in-progress work.
  merged=0
  git merge-base --is-ancestor HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null && merged=1
  if [ "$merged" -eq 0 ]; then
    merged_sha="$(gh pr list --head "$CURRENT" --state merged --json headRefOid --jq '.[0].headRefOid' 2>/dev/null || echo '')"
    [ -n "$merged_sha" ] && [ "$merged_sha" = "$(git rev-parse HEAD)" ] && merged=1
  fi
  [ "$merged" -eq 1 ] || { echo "ERROR: not on $DEFAULT_BRANCH and '$CURRENT' is not provably merged — switch/stash manually"; exit 1; }
  git switch "$DEFAULT_BRANCH" --quiet
  sync_default || exit 1
  # Delete merged local branches whose upstream is gone (never protected, safe -d only).
  git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2=="[gone]"{print $1}' | grep -Ev "$PROTECTED" | while IFS= read -r b; do
        git branch -d "$b" 2>/dev/null || echo "NOTE: left '$b' (git branch -d refused — squash-merged? use /cleanup)"
      done
fi
mkdir -p .gemini/state
rm -f .gemini/state/implement-issue-active.json .gemini/state/implement-issue-blocked.json
# Gap-analysis artifacts from a PREVIOUS run, cleared for two reasons. They are per-run data that
# nothing consumes afterwards, and they are the most sensitive files this workflow writes: the
# prompt carries issue and private-repo context, and gaps.err is the agent's full exploration
# stream (inspected source, command output). Left in place they also outlive their run — a later
# pass with gap_analysis unassigned never overwrites them, so stale findings sit there looking
# current. Bounding gaps.err's growth WITHIN a run is separate, and tracked in #123.
# The lock goes too: a lock left behind by a killed run would make /cleanup treat this repo's gap
# artifacts as permanently in-flight, so the one place that can prove no dispatch is running —
# the start of the next run — is the place that clears it.
rm -f .gemini/state/gap-prompt.txt .gemini/state/gaps.md .gemini/state/gaps.err \
      .gemini/state/gap-analysis.lock
```

### 2. Verify repo scope + fetch the issue(s)

For **each** number, `gh issue view "$n"`. If any 404s or clearly describes a
different codebase, **stop** and tell the user which repo it maps to
(`repo-scope.md`) — do not implement against the wrong repo.

```bash
for n in "${ISSUE_NUMS[@]}"; do
  gh issue view "$n" --json number,title,body,labels,author,comments,milestone,state > "/tmp/issue-$n.json" \
    || { echo "ERROR: issue #$n not found in this repo — verify repo scope"; exit 1; }
done
```

Fetch `state` too, and check it from this fresh view — never from memory or a stale
ref (`base/practices/verify-before-asserting.md`). A **CLOSED** issue in the batch is
almost always a mistake (already shipped, or the wrong number), so **stop** rather than
silently reopening resolved work: the check below exits non-zero, surfacing the closed
issue so the owner can confirm (drop it, or re-open it intentionally) before you branch.

```bash
for n in "${ISSUE_NUMS[@]}"; do
  st="$(jq -r .state "/tmp/issue-$n.json")"
  [ "$st" = "OPEN" ] || { echo "ERROR: issue #$n is $st — stop and confirm with the owner before implementing (do not silently reopen already-shipped work)"; exit 1; }
done
```

Read each. Note title, body, acceptance criteria, labels, the parent milestone (you
need it in step 12), and — multi-issue — how the issues relate and whether any part
already shipped on the default branch.

### 3. Gap analysis (role: `gap_analysis`)

Resolve the agent with `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" resolve gap_analysis`. **Empty output means
unassigned** — skip this step and note "gap-analysis skipped (unassigned)" for the PR;
that is the *only* legitimate skip. An **assigned** agent that hangs / times out /
errors is a step to complete, not to skip. Otherwise run **one** pass over the whole
set with that agent, asking it to flag: blocking ambiguities, hidden constraints (this
repo's conventions/neighboring patterns), out-of-scope-creep risk, and test gaps.

**Output contract (so any `gap_analysis` agent is parseable — #8).** Ask for the
findings back as exactly three headings — `BLOCKING`, `SHOULD-CLARIFY`,
`NICE-TO-HAVE`, each listing `- <finding>` bullets or `- none` — followed by a
one-line `VERDICT:`. Tag each finding by its heading.

Dispatch through the helper, which returns only the agent's **clean final message** on
stdout — for `codex` it captures `--output-last-message`, so the repo-exploration
stream never contaminates the findings (no `tail`/grep recovery, the old #8 pain):

**Dispatch it in the BACKGROUND** — this is not a preference. A gap-analysis pass at
high reasoning effort routinely runs **longer than 10 minutes**, and agent harnesses
commonly cap a *foreground* command well below that. Run in the foreground, that outer
cap — not the helper's own 45-minute backstop — is what fires, and no amount of raising
the backstop can help. That mismatch cost three consecutive runs before it was
diagnosed (#93).

"Background" means **your own harness's detached-execution facility** — whichever
mechanism runs a command off the foreground path and reports its terminal status back to
you. Look it up for the agent driving this run rather than assuming; the details differ
per harness. A shell `&` is **not** it, on any harness: `&` inside one foreground call is
still inside that call's cap, and a later shell cannot `wait` on an earlier shell's child.

**Write the prompt to a file first.** A detached call cannot be fed from a shell
variable in your current foreground call, so materialize it, *then* dispatch:

```bash
# 1. Take the lock FIRST — before the prompt file exists, not after. A concurrent /cleanup
#    classifies gap-prompt.txt as a gap artifact, and at this point no branch or run marker
#    exists yet (step 5 owns those), so with LOCK=0 it reads as a finished run's leftovers and
#    is deleted. Writing the prompt with a file-write tool makes that window a whole agent turn,
#    not microseconds — and the dispatch below would then fail its redirection, which by the
#    rules further down reads as "a real agent error": a swept local file blamed on codex.
: > .gemini/state/gap-analysis.lock

# 2. Write the gap-analysis prompt (heredoc, or your file-write tool).
cat > .gemini/state/gap-prompt.txt <<'PROMPT'
…the adversarial gap-analysis prompt, including the three-heading output contract…
PROMPT

# 3. Dispatch via the harness's background facility, NOT a shell `&`.
bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke gap_analysis \
  < .gemini/state/gap-prompt.txt > .gemini/state/gaps.md 2> .gemini/state/gaps.err
```

**Keep holding the lock after the dispatch returns.** Do NOT append a release to the block above:
the dispatch is *detached*, so everything after it in that block runs while the pass is still
going, and the lock would be dropped immediately — unheld for the only window it exists for.

But the window it must cover is **longer than the dispatch**. You still have to read `gaps.md`
and `gaps.err` (step 4), and the run marker that takes over as the liveness signal does not exist
until step 5. A release the moment the call returns leaves a gap in which a concurrent `/cleanup`
sees no lock and no marker, classifies the artifacts as a finished run's leftovers, and deletes
the findings — or the failure classification — this run is about to act on.

**The lock is therefore released at exactly two places, and nowhere else:**

- **Step 5**, immediately after `implement-issue-active.json` is written — the marker now covers
  liveness, so the lock has nothing left to protect.
- **Step 4**, on the paths that stop the run (a BLOCKING finding you surface to the owner; a
  gap-analysis incompleteness that survives its retry). Those runs never reach step 5, so nothing
  else would ever clear it.

A run killed between the take and either release leaves the lock behind. That is deliberately
fail-safe — a stray lock only ever *preserves* artifacts — and preflight clears it on the next
run. A retry of the dispatch re-runs the block above and re-takes the lock at step 1, so there is
no separate re-take to remember.

Skipping step 1 fails the *redirection*, so the helper never runs and prints no
classified line — and a bare non-zero with no classification reads, by the rules
below, as "a real agent error", i.e. a missing local file misreported as a codex
failure. Check the file exists before dispatching.

Under the hood the helper runs the resolved agent's CLI — `codex exec --cd <repo> -`
for codex — under a **45-minute (2700 s)** hang backstop. That bound is a backstop, not
a work budget: it stops a wedged process and otherwise stays out of the way, and it
escalates TERM → grace → KILL so it always terminates. `ADB_DISPATCH_TIMEOUT_SECS`
overrides it; a stock clone needs no environment set. Do **not** re-derive a
millisecond ceiling for the surrounding call — capping it is the bug this step exists
to prevent.

**Completion contract (per the Roles section).** This is a single bounded call:
**wait for the harness to report it finished** — do not poll its output stream to guess
whether it is "hung" (`gaps.err` grows steadily during healthy exploration, so its size
tells you nothing). On failure, **read the classified line at the tail of `gaps.err`** —
it is the last thing written there, behind the whole exploration stream, and it is the
one line that tells you *which* failure this was. rc **124** is
our backstop firing, rc **143** is an *outer* bound killing it first (re-dispatch in the
background, or raise that outer bound — not ours), rc **137** is an external SIGKILL —
an OOM killer or the harness, i.e. a memory/environment problem, **not** the agent — and
any other non-zero is a real agent error. Each warrants a different response, so read the
classification rather than treating every non-zero as "the agent failed".

An incomplete invocation is **retried exactly once**. If the retry also fails,
**report the classified incompleteness and stop cleanly** — gap-analysis runs *before*
the branch/marker exists, so there is no blocked marker to write (step 4).
**Do NOT substitute a different agent.** `gap_analysis` is the one role that never falls
back: quietly running Claude while `agents.toml` says `codex` is what made the role
assignment fiction for three runs (#93). A bound that is too small must surface as a
bound problem, not as a silent agent swap.

### 4. Decide

- Any **BLOCKING** finding you can't resolve from the repo + practices → surface it
  to the owner and stop cleanly. No branch/marker exists yet (that is step 5), so
  there is nothing to pair a blocked file with — do **not** write one.
- Otherwise record SHOULD-CLARIFY items as assumptions for the PR body and proceed.
- **On any path that STOPS the run here** — a BLOCKING finding you surface, or a gap-analysis
  incompleteness that survived its retry — **release the gap lock.** This run never reaches step
  5, so nothing else will clear it, and a lock left behind pins its artifacts against `/cleanup`
  indefinitely (until the next run's preflight). Read the findings first, then release:
  ```bash
  rm -f .gemini/state/gap-analysis.lock
  ```
- **Epic/slice or anything declared out of scope** becomes a tracked issue in step
  12 — including the parent's own "Out of scope" list. Not a PR-body note.

### 5. Branch + write the active marker

Slug from the first issue's title (lowercase, ASCII, non-alnum → `-`, ≤40 chars).

```bash
BRANCH="issue-${ISSUE_DASH}-${SLUG}"
git switch -c "$BRANCH"
jq -n --arg branch "$BRANCH" --arg issue "$ISSUE_CSV" \
      --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{branch:$branch, issue:$issue, phase:"branched", startedAt:$startedAt}' \
   > .gemini/state/.marker.tmp && mv .gemini/state/.marker.tmp .gemini/state/implement-issue-active.json

# The marker now exists, so IT is this run's liveness signal — /cleanup keeps its state while the
# branch survives. Release the gap lock here and only here (the other release is step 4's
# stop path). Releasing any earlier — e.g. the moment the dispatch returned — leaves a window in
# which no lock and no marker exist, and a concurrent /cleanup deletes the gap findings this run
# is still acting on.
rm -f .gemini/state/gap-analysis.lock
```

If the branch already exists locally or on the remote, write the blocked marker
(`reason:"branch already exists"`, with `branch`+`issue`) and stop. Never force-push.

### 6. Implement

- `Create` 3–8 tracked sub-tasks. Read code before editing; honor the project's
  own conventions and module boundaries.
- Follow `base/practices` (validate external input at boundaries, structured logs,
  no secrets in logs, idempotent consumers/migrations/scripts).
- **Update documentation in the same PR** for any user/operator-facing change.
- Add/extend tests in the same package.
- Run the project's gates until green. The auto-detected runner:
  ```bash
  bash "$HOME/.gemini/scripts/lib/project-gates.sh" run   # typecheck/lint/test/format
  ```
  (or the repo's own commands / `agents.toml [gates]`). The Stop hook enforces this
  again on turn-end. Update `phase`: `implemented` → `gates_green`.

**Post-commit / pre-push mirror gates.** If a project's gate is a *pre-push mirror* that
compares generated/committed artifacts against `HEAD` (e.g. a codegen repo whose gate
rebuilds and diffs generated files, like this framework's own `selfcheck.sh`), then
correctly-rebuilt-but-uncommitted output reads as "stale" until it is committed. For such a
gate, do step 7 first — **commit source and regenerated output together** — and run the gate
on the clean, committed tree (the Stop hook already runs at turn-end, post-commit). The
phase order is a guideline, not a lock: `gates_green` and `committed` may interleave when the
gate only makes sense post-commit. This never means skipping the gate — it still must pass.

**Escape clause:** if the *same* gate fails three consecutive times after fixes,
write the blocked marker (`reason`, `branch`, `issue`) and stop.

### 7. First commit

Reference every issue. Single: `(#$ISSUE_NUM)` + `Refs #$ISSUE_NUM`. Multi: primary
in the subject, all in the trailer. Semantic message; `git add <specific files>`,
not `-A`. Update `phase=committed`.

### 8. Review (role: `review`) + your own self-review

**Always** do your own self-review pass first (`base/practices/self-review.md`):
edge cases, escaping/encoding, binary/NUL corruption, cascade/cancel effects,
off-by-one, idempotency. List each finding. Self-review is the mandatory floor; the
`review` role adds *independent* perspective on top of it.

Then run each configured `review` agent. Resolve the slots with
`bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" resolve review` — it prints one token per slot. **Do not**
`invoke review` as one call (a multi-agent role is refused on purpose); **loop the
tokens**, because each slot has its own retry/fallback and a same-agent slot must stay
native. For each resolved token: if it equals `gemini` (the agent driving
this run) run that agent's review **in-process** (below); otherwise shell it out with
`bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke <token>` over the diff. **Every configured reviewer is a
slot** — each must reach a terminal state (completed, or explicitly replaced by a
documented fallback) before you set `phase=code_reviewed`. A fallback stands in for the
*one* slot it replaced; it does not silently satisfy a different reviewer's slot.

- `claude` (Claude driving) → an **in-process, two-part** pass, both model-invokable:
  1. **`/simplify` first** — the quality / reuse / simplification pass. It may edit
     code; if it does, **re-run gates and refresh the diff** before step 2, or the
     bug review inspects stale code. **Never let it hand-edit a generated file** —
     anything carrying a `GENERATED FILE` marker (a rendered root doc, a `SKILL.md`):
     if `/simplify` touches one, revert that edit, make the change in the `base/`
     source instead, and rebuild (`scripts/build.sh`). `/simplify` **does not hunt
     bugs**, so it does not by itself satisfy the slot.
  2. **Adversarial bug review** — dispatch a Claude subagent (Agent tool,
     `general-purpose`) over the *fresh* diff, prompted to find real bugs (edge
     cases, escaping, boundaries, idempotency, security). Run it **synchronously**
     and consume its returned findings; do not poll a background stream.

  **Never model-invoke `/code-review`** (user-only, `disable-model-invocation`) — it
  is an optional step the owner runs after the PR, not part of this slot.
- `codex` → `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke codex` over a review prompt on the diff (it runs
  `codex exec` with the 45-min hang backstop and the clean `--output-last-message`
  capture — dispatch it in the background too, for the same reason as step 3).
- `gemini` → `bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" invoke gemini` over the diff (it runs `agy -p`).

**Completion contract (per the Roles section).** Run each cross-agent reviewer
(`codex` / `gemini`) and the subagent bug review as a single bounded call and **wait
for it to return** — never poll output to guess liveness. On timeout / error, abandon
the call (a Bash timeout kills a `codex exec` / `agy -p` process; an Agent subagent
just returns its error), **retry once**, then **fall back** to a `general-purpose`
Claude subagent bug review (model-invokable whenever Claude drives) standing in for
that slot; document the substitution. A slot is **terminal** the moment its reviewer
(or its fallback) **returns a result** — a completed review that finds *nothing* is a
clean pass, not a failure; only a hung / errored / crashed-empty call is incomplete.
If **any** required slot still cannot reach a terminal state after retry + fallback,
the review step **failed** for that slot → write `implement-issue-blocked.json`
(`reason` names the failed reviewer, `branch`/`issue` matching the marker) and leave
`phase=committed`. Never reach step 10 (PR opened) with a required review incomplete.

Once every slot is terminal, update `phase=code_reviewed`. **Completed findings are
input to step 9, not a stopping point.**

### 9. Triage + fix

Per finding (from self-review AND each reviewer): CRITICAL/HIGH → fix always;
MEDIUM → fix unless clearly out of scope (then defer + file in step 12); LOW → fix
if cheap else document; disagree → document the reasoning. Re-run gates. Commit
again if anything changed. Update `phase=triaged`.

### 10. Push + open PR

```bash
BRANCH="$(jq -r .branch .gemini/state/implement-issue-active.json)"
git push -u origin "$BRANCH"
jq '.phase="pushed"' .gemini/state/implement-issue-active.json > .gemini/state/.marker.tmp \
  && mv .gemini/state/.marker.tmp .gemini/state/implement-issue-active.json
```

PR body: summary; gap-analysis gaps + how addressed; self-review + reviewer findings
+ dispositions (table); test plan. One `Closes #N` per fully-resolved issue (each on
its own line), `Refs #N` for any sliced. After `gh pr create`, write `prUrl` and
`phase=pr_opened` into the marker.

**Then hand the merge to GitHub — but never arm it blind.** Ask **two** guards, in
order; both re-read live state and both **fail closed**, so a repo that is not in the
safe state gets a reported skip instead of an ungated merge:

1. **`automerge-ok`** — *will the checks gate this?* (repo settings)
2. **`pr-review.sh gate`** — *has review happened on this exact commit?* (#134)

The second exists because the first cannot answer it. GitHub merges the instant the
**required status checks** pass; an async bot reviewer is not a required check, and
`required_conversation_resolution` only blocks on threads that **already exist** —
at arming time there are none. That is not a narrow race: PR #133 merged **29 seconds**
after opening and **six minutes before** its reviewer posted five real bugs. So the
wait has to happen **here, before the arm**.

```bash
PR="$(jq -r .prUrl .gemini/state/implement-issue-active.json)"   # written just above
bash "$HOME/.gemini/scripts/lib/repo-settings.sh" automerge-ok; AM=$?
case "$AM" in
  0)
    # On 0 the guard prints the head SHA it witnessed — pass it to --match-head-commit so a
    # commit pushed between the check and the arm cannot slip in unreviewed (GitHub rejects
    # the arm instead of merging the new tip).
    HEAD_SHA="$(bash "$HOME/.gemini/scripts/lib/pr-review.sh" gate --pr "$PR")"; RV=$?
    case "$RV" in
      0)  # Merge methods are per-repo settings; a hardcoded --squash is rejected wherever
          # squash is disabled, so ask which flag this repo allows. Asked HERE, not earlier:
          # on a bot-reviewed repo the arm is skipped almost every run, and `merge-flag` is
          # its own pair of API calls — no point paying for them to discard the answer.
          FLAG="$(bash "$HOME/.gemini/scripts/lib/repo-settings.sh" merge-flag)" || FLAG=""
          [ -n "$FLAG" ] && gh pr merge "$PR" --auto "$FLAG" --match-head-commit "$HEAD_SHA" ;;
      16) : ;;  # a DECLARED reviewer has not reviewed this head SHA -> do NOT arm; owner merges
      17) : ;;  # repo declares no `[reviewers] bots` -> unknowable; declare it (or `bots = []`)
      18) : ;;  # `[reviewers] bots` is malformed     -> fix agents.toml
      19) : ;;  # a reviewer requested CHANGES on this head SHA -> address them, push, re-run
      *)  : ;;  # 20/unknown -> review state unreadable, merge by hand
    esac ;;
  10) : ;;  # allow_auto_merge off       -> report: run 'baseline repo apply'
  11) : ;;  # CI but no required checks  -> report: arming would gate NOTHING
  12) : ;;  # no CI at all               -> report: --auto would merge immediately
  13) : ;;  # a required context nothing reports -> an armed PR would WAIT FOREVER
  14) : ;;  # a discovered job is NOT required     -> auto-merge could land a RED build
  *)  : ;;  # 20/unknown                 -> report: live state unreadable, merge by hand
esac
```

**Never arm auto-merge when** a `implement-issue-blocked.json` marker exists, or the
PR is a draft (GitHub refuses it anyway). A non-zero guard code is **not** a failure
of this step — it is the guard doing its job: report the code and its meaning in
step 11, leave the PR open, and let the owner merge.

**Expect code 16 on a bot-reviewed repo, and say so plainly.** This step runs seconds
after the PR is created, so a reviewer that takes minutes has definitionally not
reviewed yet. On such a repo auto-merge is therefore **not armed by this workflow** —
that is the intended trade (#134): unattended *arming* is suspended until the review
lands, and **#49** restores it by watching the PR and arming afterwards. A repo with
no async reviewer keeps unattended arming today by declaring `bots = []`.

Two things to say out loud in the close-out, because the operator no longer sees the
merge dialog:

- `--squash` takes its subject from the **PR title**, so the title must satisfy the
  repo's commit convention.
- **What held the arm was this step's review guard, not GitHub.**
  `required_conversation_resolution` holds an armed PR only on threads that exist at
  that moment; it never waits for a future review. If threads land later,
  `/resolve-pr-threads` clears them.

### 11. Close-out

**Run step 12 first** (file every deferred item). Then write `phase=complete` and
emit a self-attested completion checklist rendering each required step's real status
(✅ / ⚠️ / ❌ — never silently drop a skipped item), grouped Setup → Implementation →
Review → Ship → Close-out, plus a **Needs attention** block for anything not ✅ and a
**Follow-up issues filed** block (each with its milestone + one-line rationale).

State the **auto-merge disposition explicitly** — armed, or skipped naming **which**
guard skipped it and its code (`automerge-ok` 10–14/20, or the review gate
16/17/18/19/20).
An armed PR that is silently waiting on something is the one outcome the operator
cannot see: say what it is waiting on and what clears it. On code 16 the PR is **not
armed at all** and is waiting on a *reviewer* — not the same as an armed PR waiting on
threads. End with the `/resolve-pr-threads <PR#>` resume hint. Do **not** poll for bot
reviews — this step reports the state and ends; waiting is #49's job.

### 12. File issues for ALL deferred / out-of-scope work (mandatory)

Always runs; gated by step 11. For every item not shipped in this PR that someone
might need later — slices you cut, the parent's own "Out of scope" list, gap-analysis
/ review items you deferred, knowingly-skipped test/infra gaps — create a tracked
issue if one doesn't already exist. **File by default; never ask.** A PR body is not
a tracker. `gh issue list --search …` first to avoid dupes.

Placement: if the repo uses a release-goal/milestone convention — detected the same opt-in
way `/roadmap` activates (the `roadmap` artifact's `release-milestone` marker, **not**
coincidental milestone names) — **default a discovery to `Backlog`** — work you
surface *while implementing* is exactly what must not expand the frozen release set, or
readiness never converges (`docs/release-goal-convention.md`). Only an issue that is a
genuine dependency of the *current* release goal goes into `Next release`; tangential /
post-deploy work stays in `Backlog`. Otherwise use the repo's default; never leave a new
issue milestone-less if the project uses milestones. Link the new issue from **both** the
parent (a comment that survives the parent closing) and the PR.

---

## Failure modes

- **Delegated step (gap-analysis / review) hangs, times out, or errors** → it is
  **incomplete**, not skippable. Run it as one bounded call and wait for it to
  return; never poll its output to guess "hung." Then kill → **retry once** →
  **fall back** (another listed agent, or a `general-purpose` Claude subagent running
  the same prompt) → if still nothing completes, block/surface. Never mark the step
  done on partial or empty output. **`gap_analysis` is the exception: retry once, then
  surface — never substitute another agent** (see step 3).
- **Gap-analysis returns rc 143 (SIGTERM)** → an **outer** bound killed the call before
  the helper's own 45-min backstop could. The fix is *where* it runs, not a bigger
  number: dispatch it through the harness's background facility. Re-deriving a
  millisecond ceiling for the foreground call is the bug, not the remedy.
- **Gap-analysis returns rc 124** → the helper's own hang backstop fired. That is a
  genuinely stuck or extraordinary run: retry once, then surface it as a **codex
  incompleteness** (never a silent swap to another agent). Raise
  `ADB_DISPATCH_TIMEOUT_SECS` only if a legitimate pass really needs more than 45 min.
- **Gap-analysis returns rc 137 (SIGKILL)** → killed from *outside* the helper — an OOM
  killer or the harness. Investigate memory/environment, **not** the agent: re-running
  the same pass in the same conditions will be killed again.
- **Gap-analysis output is empty while `gaps.err` is huge** → not a diagnostic signal.
  `codex exec` returns its result as a **final message**, not a stream, so a
  bound-killed run yields empty stdout whether or not it was progressing; the large
  `gaps.err` is just the exploration stream, i.e. evidence of *active work*. Read the
  helper's classified rc instead of inferring from output sizes.
- **Gap-analysis `""` (unassigned)** → the only legitimate skip; note it in the PR
  and continue. An *assigned* gap-analysis agent that cannot run is a failure to
  retry → surface — not a silent skip and not a substitution.
- **`/code-review` errors with `disable-model-invocation`** → expected: it is
  **user-only** by design (it can launch a billed cloud review), *not* a version or
  toolchain problem. The Claude `review` slot never invokes it — use `/simplify` + a
  Claude subagent bug review (step 8). Reference `/code-review` only as an optional
  post-PR human step. Do **not** file a toolchain issue.
- **`gh pr merge --auto` errors with "Pull request is in clean status"** → expected,
  not a bug: GitHub refuses to *queue* a PR that could merge right now, which is the
  no-required-checks case. The guard returns 11/12 precisely so this is never reached.
  Do **not** retry it as a plain `gh pr merge --squash` — that merges unreviewed code
  immediately, which nobody asked for. Report and leave the PR open.
- **Gates won't go green after the escape clause** → write the blocked marker, stop,
  report what's failing. Never push red.
- **Branch already exists on remote** → blocked marker; ask the user; never force-push.
- **Stop hook keeps blocking** → you're trying to end before the PR is open; open it
  or write the blocked marker. Don't fight the hook.
