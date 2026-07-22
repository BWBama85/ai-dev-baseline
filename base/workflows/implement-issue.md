---
name: implement-issue
description: Implement a GitHub issue end-to-end — repo-scope check, role-assigned gap-analysis, auto-detected gates, self-review + assigned code review, then open a PR. Agent-neutral via agents.toml; stack-agnostic via gate auto-detection.
argument-hint: <issue-number> [more-issue-numbers…] [extra hints]
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, TaskCreate, TaskUpdate, TaskList, Agent, Skill
user-invocable: true
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

Two gitignored files under `.claude/state/`:

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

Always stage marker writes inside `.claude/state/` (`.marker.tmp` → `mv`) so the
rename is atomic. Preflight unconditionally clears stale state files.

## Roles (who does what)

Read the repo's `agents.toml` `[roles]` at preflight (fall back to the global
default at `~/.config/ai-dev-baseline/agents.toml`, then to built-in defaults):

- **`gap_analysis`** (default `codex`, or `""` to skip) — the pre-implementation
  adversarial pass in step 3.
- **`review`** (default `["claude"]`) — the code-review agents in step 8. Always
  ALSO do your own self-review (`base/practices/self-review.md`).

Resolve tokens to invocations via `base/roles.md`:

- `claude` — when Claude is the driving agent, review runs **in-process** with
  **model-invokable** tools only: `/simplify` (quality / reuse / simplification —
  it explicitly does **not** hunt bugs) **plus** an independent adversarial **bug**
  review by a Claude subagent (Agent tool, `general-purpose`). **Never model-invoke
  `/code-review`** — it carries `disable-model-invocation` (it can launch a billed
  cloud review, so the harness reserves it for humans) and the Skill tool rejects
  it. Treat `/code-review` only as an *optional* step the owner runs after the PR
  (like `/resolve-pr-threads` for bot threads).
- `codex` → `codex exec --cd <repo> -`; `gemini` → `agy -p`. A cross-agent
  `codex exec` needs a **≥7-minute** timeout.

**Completion contract (delegated steps must terminate).** `gap_analysis`, `review`,
and any cross-agent / subagent dispatch MUST reach a terminal, *completed* state —
"advisory" is the standing of **completed** findings, never a license to skip the
**step**. Run each as a **single bounded call and wait for it to return** (process
exit for `codex exec`/`agy -p`/`claude -p`; the tool result for an Agent subagent).
**Never poll a background agent's output to infer whether it is "hung"** — the
outcome is the call returning, not the byte count growing. On timeout / error /
hang: kill it, **retry once**, then **fall back** to another agent the role lists or
a `general-purpose` Claude subagent running the same prompt. If nothing completes,
the step **failed** → block or surface (step 4 / step 8), never proceed on partial
or empty output. Full contract: `base/roles.md`.

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
mkdir -p .claude/state
rm -f .claude/state/implement-issue-active.json .claude/state/implement-issue-blocked.json
```

### 2. Verify repo scope + fetch the issue(s)

For **each** number, `gh issue view "$n"`. If any 404s or clearly describes a
different codebase, **stop** and tell the user which repo it maps to
(`repo-scope.md`) — do not implement against the wrong repo.

```bash
for n in "${ISSUE_NUMS[@]}"; do
  gh issue view "$n" --json number,title,body,labels,author,comments,milestone > "/tmp/issue-$n.json" \
    || { echo "ERROR: issue #$n not found in this repo — verify repo scope"; exit 1; }
done
```

Read each. Note title, body, acceptance criteria, labels, the parent milestone (you
need it in step 12), and — multi-issue — how the issues relate and whether any part
already shipped on the default branch.

### 3. Gap analysis (role: `gap_analysis`)

Resolve the `gap_analysis` agent from `agents.toml`. If it is `""` (**unassigned**),
skip this step and note "gap-analysis skipped (unassigned)" for the PR — that is the
*only* legitimate skip. An **assigned** agent that hangs / times out / errors is a
step to complete, not to skip. Otherwise run **one** pass over the whole set with
that agent, asking it to flag: blocking ambiguities, hidden constraints (this repo's
conventions/neighboring patterns), out-of-scope-creep risk, and test gaps. Tag each
finding BLOCKING / SHOULD-CLARIFY / NICE-TO-HAVE.

Default (`codex`): build one payload (prompt + all issues) and pipe it to
`codex exec --cd "$(git rev-parse --show-toplevel)" -`. **Give the Bash call a
≥7-minute timeout** (`420000`–`600000` ms) — `codex exec` routinely runs 3–7 min.

**Completion contract (per the Roles section).** This is a single bounded call:
**wait for the process to exit** — do not poll its output stream to guess whether it
is "hung." A short SIGTERM (exit 143) at a *2-minute* default is just too-tight a
bound, not a failure — re-run at the ≥7-min bound. A genuine timeout / non-zero exit
at the full bound is an **incomplete** invocation: kill it, **retry once**, then
**fall back** to a `general-purpose` Claude subagent (Agent tool) running the same
adversarial read. If even the fallback cannot complete, **surface to the owner and
stop cleanly** — gap-analysis runs *before* the branch/marker exists, so there is no
blocked marker to write (step 4); do not proceed as if the pass had run.

### 4. Decide

- Any **BLOCKING** finding you can't resolve from the repo + practices → surface it
  to the owner and stop cleanly. No branch/marker exists yet (that is step 5), so
  there is nothing to pair a blocked file with — do **not** write one.
- Otherwise record SHOULD-CLARIFY items as assumptions for the PR body and proceed.
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
   > .claude/state/.marker.tmp && mv .claude/state/.marker.tmp .claude/state/implement-issue-active.json
```

If the branch already exists locally or on the remote, write the blocked marker
(`reason:"branch already exists"`, with `branch`+`issue`) and stop. Never force-push.

### 6. Implement

- `TaskCreate` 3–8 tracked sub-tasks. Read code before editing; honor the project's
  own conventions and module boundaries.
- Follow `base/practices` (validate external input at boundaries, structured logs,
  no secrets in logs, idempotent consumers/migrations/scripts).
- **Update documentation in the same PR** for any user/operator-facing change.
- Add/extend tests in the same package.
- Run the project's gates until green. The auto-detected runner:
  ```bash
  bash "$HOME/.claude/scripts/lib/project-gates.sh" run   # typecheck/lint/test/format
  ```
  (or the repo's own commands / `agents.toml [gates]`). The Stop hook enforces this
  again on turn-end. Update `phase`: `implemented` → `gates_green`.

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

Then run each configured `review` agent. **Every configured reviewer is a slot** —
each must reach a terminal state (completed, or explicitly replaced by a documented
fallback) before you set `phase=code_reviewed`. A fallback stands in for the *one*
slot it replaced; it does not silently satisfy a different reviewer's slot.

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
- `codex` → `codex exec` a review prompt over the diff (≥7-min timeout).
- `gemini` → `agy -p` a review prompt over the diff.

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
BRANCH="$(jq -r .branch .claude/state/implement-issue-active.json)"
git push -u origin "$BRANCH"
jq '.phase="pushed"' .claude/state/implement-issue-active.json > .claude/state/.marker.tmp \
  && mv .claude/state/.marker.tmp .claude/state/implement-issue-active.json
```

PR body: summary; gap-analysis gaps + how addressed; self-review + reviewer findings
+ dispositions (table); test plan. One `Closes #N` per fully-resolved issue (each on
its own line), `Refs #N` for any sliced. After `gh pr create`, write `prUrl` and
`phase=pr_opened` into the marker.

### 11. Close-out

**Run step 12 first** (file every deferred item). Then write `phase=complete` and
emit a self-attested completion checklist rendering each required step's real status
(✅ / ⚠️ / ❌ — never silently drop a skipped item), grouped Setup → Implementation →
Review → Ship → Close-out, plus a **Needs attention** block for anything not ✅ and a
**Follow-up issues filed** block (each with its milestone + one-line rationale). End
with the `/resolve-pr-threads <PR#>` resume hint. Do **not** poll for bot reviews.

### 12. File issues for ALL deferred / out-of-scope work (mandatory)

Always runs; gated by step 11. For every item not shipped in this PR that someone
might need later — slices you cut, the parent's own "Out of scope" list, gap-analysis
/ review items you deferred, knowingly-skipped test/infra gaps — create a tracked
issue if one doesn't already exist. **File by default; never ask.** A PR body is not
a tracker. `gh issue list --search …` first to avoid dupes.

Placement: if the repo uses a release-goal/milestone convention (e.g. a rolling
`Next release` + standing `Backlog`), place a direct dependency of the current
release goal in `Next release` and tangential/post-deploy work in `Backlog`;
otherwise use the repo's default. Link the new issue from **both** the parent
(a comment that survives the parent closing) and the PR.

---

## Failure modes

- **Delegated step (gap-analysis / review) hangs, times out, or errors** → it is
  **incomplete**, not skippable. Run it as one bounded call and wait for it to
  return; never poll its output to guess "hung." Then kill → **retry once** →
  **fall back** (another listed agent, or a `general-purpose` Claude subagent running
  the same prompt) → if still nothing completes, block/surface. Never mark the step
  done on partial or empty output.
- **Gap-analysis `codex exit 143` at a ~2-min bound** → the Bash timeout was too
  tight, not a failure. Re-run at `420000`–`600000` ms. A real timeout at the full
  ≥7-min bound is an incomplete invocation → retry → fallback (line above).
- **Gap-analysis `""` (unassigned)** → the only legitimate skip; note it in the PR
  and continue. An *assigned* gap-analysis agent that cannot run is a failure to
  retry → fall back to a Claude subagent → surface — not a silent skip.
- **`/code-review` errors with `disable-model-invocation`** → expected: it is
  **user-only** by design (it can launch a billed cloud review), *not* a version or
  toolchain problem. The Claude `review` slot never invokes it — use `/simplify` + a
  Claude subagent bug review (step 8). Reference `/code-review` only as an optional
  post-PR human step. Do **not** file a toolchain issue.
- **Gates won't go green after the escape clause** → write the blocked marker, stop,
  report what's failing. Never push red.
- **Branch already exists on remote** → blocked marker; ask the user; never force-push.
- **Stop hook keeps blocking** → you're trying to end before the PR is open; open it
  or write the blocked marker. Don't fight the hook.
