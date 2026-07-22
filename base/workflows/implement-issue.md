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
  legitimate stop (BLOCKING gap-analysis finding you can't resolve; gate escape
  clause; branch already exists on remote). Shape:
  `{"reason","phase","branch","issue"}` — `branch`/`issue` REQUIRED and must match
  the active marker.

Always stage marker writes inside `.claude/state/` (`.marker.tmp` → `mv`) so the
rename is atomic. Preflight unconditionally clears stale state files.

## Roles (who does what)

Read the repo's `agents.toml` `[roles]` at preflight (fall back to the global
default at `~/.config/ai-dev-baseline/agents.toml`, then to built-in defaults):

- **`gap_analysis`** (default `codex`, or `""` to skip) — the pre-implementation
  adversarial pass in step 3.
- **`review`** (default `["claude"]`) — the code-review agents in step 8. Always
  ALSO do your own self-review (`base/practices/self-review.md`).

Resolve tokens to invocations via `base/roles.md`: `claude` → native `/code-review`
skill (or `/simplify` if unavailable); `codex` → `codex exec --cd <repo> -`;
`gemini` → `agy -p`. A cross-agent `codex exec` needs a **≥7-minute** timeout.

## Important rules (from base/practices)

- **Verify repo scope first** (`repo-scope.md`) — confirm every issue belongs to
  THIS repo before touching code.
- **Out-of-scope work always becomes a tracked issue** (`issues-and-scope.md`),
  filed before close-out — never just a PR-body note, never ask first.
- **Self-review is mandatory** (`self-review.md`) before the PR.
- **Never push to the default branch; feature branch + PR only** (`git-and-prs.md`).
- **Never `--no-verify`; never destructive git** without an explicit ask.
- **Gap-analysis / review output is advisory** — you are the implementer; disagree
  when wrong, but document why in the PR.
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

Ensure tooling on PATH for the whole session; verify a clean tree on an up-to-date
default branch; clear stale state. Do **not** write the marker yet (step 5 owns it).

```bash
command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v gh || { echo "MISSING:gh"; exit 1; }
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=main
[ -z "$(git status --porcelain)" ] || { echo "ERROR: tree not clean"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "$DEFAULT_BRANCH" ] || { echo "ERROR: not on $DEFAULT_BRANCH"; exit 1; }
git fetch origin "$DEFAULT_BRANCH" --quiet
[ "$(git rev-list --left-right --count HEAD...origin/$DEFAULT_BRANCH)" = "$(printf '0\t0')" ] || { echo "ERROR: local $DEFAULT_BRANCH diverges"; exit 1; }
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

Resolve the `gap_analysis` agent from `agents.toml`. If `""`, skip this step and
note "gap-analysis skipped (unassigned)" for the PR. Otherwise run **one** pass over
the whole set with that agent, asking it to flag: blocking ambiguities, hidden
constraints (this repo's conventions/neighboring patterns), out-of-scope-creep risk,
and test gaps. Tag each finding BLOCKING / SHOULD-CLARIFY / NICE-TO-HAVE.

Default (`codex`): build one payload (prompt + all issues) and pipe it to
`codex exec --cd "$(git rev-parse --show-toplevel)" -`. **Give the Bash call a
≥7-minute timeout** (`420000`–`600000` ms) — `codex exec` routinely runs 3–7 min;
a 2-min SIGTERM (exit 143) is a timeout, not a failure, so re-run longer.

### 4. Decide

- Any **BLOCKING** finding you can't resolve from the repo + practices → write
  `implement-issue-blocked.json` and stop (no marker exists yet; just stop cleanly).
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
off-by-one, idempotency. List each finding.

Then run the configured `review` agent(s):

- `claude` → invoke the native `/code-review` skill (effort `high` for
  security/schema/scoring/`.claude` changes, else `medium`). Fall back to
  `/simplify` if `/code-review` is unavailable.
- `codex` → `codex exec` a review prompt over the diff (≥7-min timeout).
- `gemini` → `agy -p` a review prompt over the diff.

Multiple reviewers → run each; independent perspectives are the point. Update
`phase=code_reviewed`. **Review output is input to step 9, not a stopping point.**

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

- **Gap-analysis agent times out** (codex exit 143) → the Bash timeout fired, not a
  failure. Re-run with `420000`–`600000` ms.
- **Gap-analysis agent unavailable** → skip the pass, note it in the PR, continue.
- **`/code-review` unavailable** → fall back to `/simplify`; file a toolchain issue.
- **Gates won't go green after the escape clause** → write the blocked marker, stop,
  report what's failing. Never push red.
- **Branch already exists on remote** → blocked marker; ask the user; never force-push.
- **Stop hook keeps blocking** → you're trying to end before the PR is open; open it
  or write the blocked marker. Don't fight the hook.
