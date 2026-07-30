---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/resolve-pr-threads.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: resolve-pr-threads
description: Resolve unresolved bot-authored review threads on an open PR. Switches the working tree to the PR's head branch, addresses findings (commit + push if needed), replies, then marks each thread Resolved via GraphQL so branch protection unblocks merge. With --watch it first waits for the async reviewer to finish, spending no model tokens while it waits.
---

# /resolve-pr-threads

Address and resolve every unresolved **bot-authored** review thread on the PR named by `$ARGUMENTS` so the repo's "all comments must be resolved" branch protection releases. The PR number is the **first bare integer** in those arguments — the rest may carry flags such as `--watch` (step 0).

> **Side effect:** this skill `git switch`-es your working tree to the PR's head branch. If you're mid-task on an unrelated branch, finish or stash that work first. The skill aborts on a dirty tree to protect uncommitted changes, but it will not warn before changing branches on a clean tree.

## When to invoke

- **After `/implement-issue` exits** with bot reviews not yet posted. The skill is the documented resume path for the bot-wait window expiring before the configured bot reviewer arrives.
- **Any time** Codex, Copilot, or another configured bot reviewer posts findings on an existing PR. Idempotent — safe to re-run if more threads appear later.

## Scope

**In scope:** unresolved review threads whose first comment was authored by a **known
automated-reviewer login**. That login set is single-sourced in `agents.toml` `[reviewers] bots`
(see `base/roles.md`) and read via `bash "$HOME/.codex/scripts/lib/role-dispatch.sh" bots`: a repo lists/extends it there, leaves
it unset for the built-in default set, or sets `[]` to disable auto-resolution. The built-in
default set covers the common GitHub review bots:

- `chatgpt-codex-connector` (OpenAI Codex code-review connector — no `[bot]` suffix; matched by explicit login)
- `gemini-code-assist[bot]`, `gemini-code-assist`
- `copilot-pull-request-reviewer[bot]`, `copilot[bot]`
- `github-actions[bot]`
- `claude[bot]`, `claude-code[bot]`

> **Note:** matching is an **exact, anchored, case-insensitive allowlist** built from those logins
> (`(?i)^(login1|login2|…)$`, with `[`/`]` regex-escaped) — **not** a `[bot]`-suffix heuristic. So
> it resolves *only* threads whose author login is listed, never an unlisted `[bot]` account, and
> never a login that merely resembles one. Add a reviewer by listing it in `[reviewers] bots`, not
> by editing this skill — and the same allowlist drives both classification (step 3) and the
> remaining-count sanity check (step 6), so the two can't diverge.
>
> **Stated exactly, because the stronger claim was wrong:** an exact allowlist matches *whatever
> account bears that login*, which for a **bare** entry may be a human rather than an App. Two of
> the built-in defaults are bare (`gemini-code-assist`, and `chatgpt-codex-connector`, whose App
> genuinely has no suffix), and `gh api users/gemini-code-assist` returns a real **User** account —
> so "can never match a human login" was false as written. The exposure is bounded (an unwanted
> *thread resolution*, not a merge) and it is not this workflow's to fix: whether the bare defaults
> should be dropped is tracked in #208. The arming guards are separate and stricter — see
> `base/roles.md` on `foo` vs `foo[bot]` (#173).

**Out of scope:** threads authored by humans (the repo owner or any other user). Never auto-resolve those — they require human-to-human discussion. If the only unresolved threads are human-authored, this skill reports them and exits without action.

**Also out of scope:** opening new PRs, merging PRs, requesting re-review, or any action beyond addressing + resolving the listed threads.

## Steps

### 0. Optional: wait for the reviewer first (`--watch`)

**Skip this step entirely unless `--watch` appears in the arguments.** Without it every step below
behaves exactly as it always has.

`/implement-issue` opens a PR and ends; the async reviewer arrives minutes later, usually after the
session is gone. `--watch` closes that gap without paying for it: the waiting happens in a **shell
poll loop**, so the bound can be half an hour and **no model tokens are spent while merely
waiting** — the model is not in the loop at all, and only re-enters if there is something to do.

```bash
# Self-contained, like every other fenced block here: these steps may run as separate shell
# invocations that share no variables, so this block resolves the PR number itself rather than
# borrowing step 1's. Both parsers take the first BARE INTEGER, so "--watch 42" and "42 --watch"
# behave identically — taking the first TOKEN would read "--watch" as the PR number.
WATCH=0
PR_NUM=""
for a in $ARGUMENTS; do
  case "$a" in
    --watch) WATCH=1 ;;
    ''|*[!0-9]*) ;;
    *) [ -z "$PR_NUM" ] && PR_NUM="$a" ;;
  esac
done
[ -z "$PR_NUM" ] && { echo "ERROR: no PR number"; exit 1; }

if [ "$WATCH" = "1" ]; then
  # --max-secs is passed EXPLICITLY and is deliberately far below the library's own 30-minute
  # default, because this call runs inside an agent's shell-tool invocation and that tool has its
  # own ceiling (commonly ~2 minutes by default, ~10 minutes maximum). A wait longer than the
  # harness allows does not "wait longer" — it gets KILLED mid-wait, which loses the verdict
  # entirely. 540s sits under a 600s ceiling with margin, and the connector has been taking ~3
  # minutes on this repo, so it converges well inside that.
  #
  # RAISE YOUR SHELL TOOL'S TIMEOUT to at least 600000ms for this one call. If your harness cannot,
  # lower --max-secs to fit it rather than letting the call be killed.
  #
  # For a genuinely long watch, run the library directly in a terminal you keep — it is a plain
  # command with no agent in the loop:
  #     bash "$HOME/.codex/scripts/lib/pr-watch.sh" wait --pr N --interval 30 --max-secs 1800
  # then run this skill without --watch once it reports findings.
  #
  # The call is the LAST command in this block ON PURPOSE: its exit status becomes the block's, so
  # the verdict reaches you as an exit code. Assigning it to a variable would make the block exit 0
  # for every verdict and the table below unusable.
  bash "$HOME/.codex/scripts/lib/pr-watch.sh" wait --pr "$PR_NUM" --max-secs 540
else
  exit 10   # not watching: behave exactly as an ordinary invocation, i.e. "there is work to do"
fi
```

**Branch on that block's EXIT CODE** (not on its stdout — codes `2`, `17`, `18` and `20` print no
verdict line at all). Only `10` continues into the resolve flow; every other code is a terminal
answer this skill reports and exits on, because there is nothing to resolve:

| Code | Meaning | What to do |
| ---- | ------- | ---------- |
| `10` | a declared reviewer reviewed **this head** and is **not satisfied** — a `CHANGES_REQUESTED` or `COMMENTED` review, or a fresh issue comment | **continue to step 1** (but note there may be **no threads**: a task-mode comment creates none, so read the comment) |
| `0`  | **every** declared reviewer signalled a clean pass — an `APPROVED` review at this head, or a `+1` on the PR post newer than the moment the head ref became this SHA — **or** the repo declares `bots = []` | report "reviewed clean — nothing to resolve" and **exit 0** |
| `11` | the bound expired with **at least one** declared reviewer still silent — see the note below on a second way to reach it | report that the wait timed out and hand back to the operator; **exit** |
| `12` | the PR is no longer OPEN (merged or closed) | report it and **exit** |
| `17` | the repo declares no `[reviewers] bots` | it cannot be known whether a reviewer is coming — tell the operator to declare them (or `bots = []`); **exit** |
| `18` | `[reviewers] bots` is malformed | tell the operator to fix `agents.toml`; **exit** |
| `20` | live state was unreadable | say so and **exit** — never assume a clean pass |
| `2`  | bad arguments (e.g. a PR number of `0`, or a URL naming another repository) | report the message and **exit** |

**A killed call is not a verdict.** If the shell tool times out mid-wait, you get no code and no
answer — do not treat that as "clean" or as "no findings". Report that the wait was cut short and
either re-run with a smaller `--max-secs` or run the library directly in a terminal.

**`11` has a second cause worth reading the stderr for (#175).** A `+1` and a task-mode comment carry
no commit, so their freshness is proved against GitHub's own record of *when the head ref became this
SHA* — the head commit's own date is client-supplied and was a live fail-open. When that record
cannot be established (nothing in the ref's recent activity puts this SHA there; the head repository
was deleted), the verdict is `11` rather than `clean`. It reads the same as a timeout in the table
above, but the diagnostic line says which, and the remedy differs: a timeout means *wait longer*,
an unestablished anchor means *this signal will never be provable* — merge by hand, or push a commit
so the head arrives with a record.

**Why a clean pass is a distinct answer, not "no threads found".** A clean Codex pass produces **no
review object at all** — only a `+1` reaction. Running the ordinary flow against such a PR would
fetch zero threads and report "nothing to do", which is the right action for the wrong reason and
is indistinguishable from *the reviewer has not started yet*. `--watch` tells those two apart.

### ⚠ `10` does not guarantee there are threads to resolve

The reviewer has **two output shapes**, and the repo does not choose which it gets:

| Codex Cloud environment | findings arrive as | clean pass |
| --- | --- | --- |
| **not** configured | a review object **+ inline threads** | a `+1` reaction |
| configured | **one issue comment** — no review, no threads, no reaction | (not yet observed) |

Both were seen on this repo *the same day* (PR #166 → review + 3 threads; PR #178 → one comment,
zero threads). So on a `10` verdict:

1. **Read the reviewer's most recent issue comment on the PR first** — under the second shape that
   comment *is* the review, and steps 2–6 will find zero threads:
   ```bash
   gh api "repos/{owner}/{repo}/issues/$PR_NUM/comments" \
     --jq 'map(select(.user.login | test("^chatgpt-codex-connector"; "i"))) | last // empty | .body'
   ```
   (Substitute the logins your repo declares in `[reviewers] bots`.)
2. Then continue into the thread flow below. If there are **no** threads, do **not** report
   "nothing to do" — address what the comment raised, and say that the feedback arrived as a
   comment rather than as resolvable threads.

**A task-mode comment may claim it committed a fix.** Verify that before believing it: unless the
reviewer has push access to this repo, the commit exists only in its sandbox and is **not** on the
branch. `git cat-file -t <sha>` and `gh pr view <PR#> --json headRefOid` settle it in one step.

**This step never mutates anything.** It observes and it waits. Every branch switch, commit, push,
and resolution still happens in steps 1–7, under exactly the rules they already state.

> **Run `--watch` in the foreground, in a session you are keeping.** The wait is cheap but it is
> not detached: it lives as long as the invoking process does, and steps 1–7 switch your working
> tree to the PR's head branch. Do not start a watch in a tree another session is working in. A
> genuinely session-surviving watcher is #171, and isolating its working tree is #172.

### 1. Preflight

Require only `gh` and `jq` — the gate runner (Step 4) auto-detects the project's stack, so this skill does not hard-require any particular package manager.

```bash
# The first BARE INTEGER, not the first token: the argument list may lead with `--watch` (step 0),
# and `awk '{print $1}'` would then hand every read below a PR number of "--watch".
PR_NUM=""
for a in $ARGUMENTS; do
  case "$a" in ''|*[!0-9]*) ;; *) [ -z "$PR_NUM" ] && PR_NUM="$a" ;; esac
done
[ -z "$PR_NUM" ] && { echo "ERROR: no PR number"; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
command -v gh || { echo "MISSING:gh"; exit 1; }
command -v jq || { echo "MISSING:jq"; exit 1; }

# Derive the resolvable-bot login allowlist from the manifest (single source — base/roles.md),
# BEFORE any branch switch so an early exit strands nothing. Check the helper's EXIT STATUS: a
# non-zero status means the helper failed (broken install / malformed `[reviewers] bots`), which
# must fail loud — NOT be mistaken for the empty-output `bots = []` disable, or a runtime failure
# would silently leave every bot thread unresolved.
if ! KNOWN_BOTS="$(bash "$HOME/.codex/scripts/lib/role-dispatch.sh" bots)"; then
  echo "ERROR: could not read the bot allowlist (broken install or malformed [reviewers] bots) — aborting rather than silently skipping every thread." >&2
  exit 1
fi
if [ -z "$KNOWN_BOTS" ]; then
  echo "Bot-thread auto-resolution is disabled ([reviewers] bots = []). Nothing to do."; exit 0
fi
# Build an anchored, case-insensitive exact-match alternation. Regex-escape the [ and ] that
# appear in `foo[bot]` logins so they match literally, then join the logins with `|`.
BOT_RE="(?i)^($(printf '%s\n' "$KNOWN_BOTS" | sed 's/[][]/\\&/g' | paste -sd'|' -))$"
```

Confirm the PR exists and is open. Capture the head branch so we can check out and push if fixes are needed.

```bash
PR_META=$(gh pr view "$PR_NUM" --json state,headRefName,baseRefName,url 2>/dev/null) || {
  echo "ERROR: PR #$PR_NUM not found or no access"; exit 1;
}
PR_STATE=$(echo "$PR_META" | jq -r .state)
PR_BRANCH=$(echo "$PR_META" | jq -r .headRefName)
PR_BASE=$(echo "$PR_META" | jq -r .baseRefName)   # restore fallback if the start branch is gone
[ "$PR_STATE" = "OPEN" ] || { echo "ERROR: PR #$PR_NUM is $PR_STATE"; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree dirty; commit or stash before invoking"
  exit 1
fi

# Capture the branch to RESTORE to on exit (issue #17: never strand the tree on the
# PR head). This runs before any switch, so on the dirty-abort above nothing moved.
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$ORIG_BRANCH" != "$PR_BRANCH" ]; then
  echo "Switching working tree from '$ORIG_BRANCH' to '$PR_BRANCH' (PR #$PR_NUM's head); will restore '$ORIG_BRANCH' on exit."
fi

# Check out the head branch only if it actually exists locally; otherwise
# fetch it. Never force-checkout — preserve any uncommitted work.
git fetch origin "$PR_BRANCH" --quiet || true
git switch "$PR_BRANCH" 2>/dev/null || git switch -c "$PR_BRANCH" "origin/$PR_BRANCH"
```

### 2. Fetch unresolved threads

```bash
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)

gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:50){
        nodes{
          id isResolved isOutdated
          comments(first:5){
            nodes{ id author{login} path line body createdAt }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F num="$PR_NUM" > .codex/state/threads-$PR_NUM.json
```

50-thread cap is a hard ceiling. If the response indicates ≥50 unresolved threads (anomaly), abort and ask the user — paginating would risk dropping context across calls.

```bash
TOTAL=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length' .codex/state/threads-$PR_NUM.json)
# Default-if-empty guard: jq failure or malformed response would otherwise
# yield a shell syntax error on the integer comparison below.
if [ "${TOTAL:-0}" -ge 50 ]; then
  echo "ERROR: $TOTAL unresolved threads on PR #$PR_NUM — pagination not implemented. Triage manually."
  exit 1
fi
```

This abort happens **after** the step-1 branch switch, so run **step 7 (restore the
starting branch)** before exiting — do not leave the tree stranded on the PR head.

### 3. Classify each thread

For every unresolved thread, read it with the Read tool (load `.codex/state/threads-$PR_NUM.json`) and decide one of:

| Disposition                     | Criteria                                                                                       | Action                                                                                                               |
| ------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Legitimate code change**      | The bot found a real bug or correctness issue you agree with.                                  | Edit the relevant file, run gates, commit, push, then reply + resolve.                                               |
| **Already addressed**           | A prior commit in this PR (yours or `/code-review`'s) already fixed the underlying issue.      | Reply with `Addressed in <sha>: <one-line summary>`. Then resolve.                                                   |
| **Disagree with reason**        | The bot's claim is wrong, doesn't apply to the codebase, or is a style preference you decline. | Reply with `Declined: <one-sentence reason>`. Then resolve. Branch protection cares about resolution, not agreement. |
| **Human-authored**              | Author login is NOT in the `[reviewers] bots` allowlist (test with `$BOT_RE`).                  | Skip. Log it in the summary and let the human handle.                                                                |
| **Login not in the allowlist**  | Author login is not in `[reviewers] bots` — including an unlisted `[bot]` account.             | Skip + log (treat as human-authored). List it in `[reviewers] bots` to resolve it.                                  |

Use Read to inspect each thread; use Edit/Write for fixes; use the Bash commands below for replies and resolution.

### 4. Address legitimate findings

For each legitimate finding:

1. Make the code change with Edit or Write.
2. Run the project's gates with the auto-detected runner:
   ```bash
   bash "$HOME/.codex/scripts/lib/project-gates.sh" run
   ```
   This detects the stack and runs its typecheck/lint/test/format equivalents. A repo may override the commands via its `agents.toml` `[gates]` block or its own `.claude/scripts/precommit-gate.sh`. If anything fails, fix it before continuing — never push red.
3. Commit:
   ```bash
   git add <specific files>
   git commit -m "address bot review on PR #$PR_NUM: <one-line summary>"
   ```

Bundle multiple fixes from the same review into one commit if they're tightly related; otherwise keep them separate so the audit trail per-thread is clean.

After all fixes are committed, push once:

```bash
git push origin "$PR_BRANCH"
LAST_SHA=$(git rev-parse --short HEAD)
```

### 5. Reply + resolve each thread

**Re-check the PR state first.** Addressing findings (step 4) can take substantial
time — edits, gates, a push — during which the PR may have merged or closed. Replying
and resolving are outward-facing mutations, so re-verify at the moment of action
rather than trusting the preflight check (`base/practices/verify-before-asserting.md`):

```bash
NOW_STATE=$(gh pr view "$PR_NUM" --json state --jq .state 2>/dev/null) || {
  echo "ERROR: could not re-check PR #$PR_NUM state before resolving"; exit 1
}
[ "$NOW_STATE" = "OPEN" ] || { echo "PR #$PR_NUM is now $NOW_STATE — skipping reply/resolve (state changed since preflight)"; exit 0; }
```

For each thread you classified:

```bash
THREAD_ID="<id from .codex/state/threads-$PR_NUM.json>"
REPLY="Addressed in $LAST_SHA: <summary>."   # OR "Declined: <reason>." OR "Addressed in <earlier-sha>."

gh api graphql -f query='
mutation($threadId:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}){
    comment{ id }
  }
}' -f threadId="$THREAD_ID" -f body="$REPLY"

gh api graphql -f query='
mutation($id:ID!){
  resolveReviewThread(input:{threadId:$id}){ thread{ id isResolved } }
}' -f id="$THREAD_ID"
```

Both calls must succeed for a thread to count as resolved. If the reply mutation fails (e.g. a permissions issue), still attempt the resolve — branch protection only checks `isResolved`, not whether you left a reply.

### 6. Verify + summary

After processing every thread:

```bash
# Reuse $BOT_RE from step 1; re-derive it here if this block runs in a fresh shell. Without this,
# an empty $BOT_RE would make jq's test("") match EVERY login, over-counting human threads.
: "${BOT_RE:=(?i)^($(bash "$HOME/.codex/scripts/lib/role-dispatch.sh" bots | sed 's/[][]/\\&/g' | paste -sd'|' -))$}"
# Sanity check: re-fetch and count remaining unresolved bot threads.
REMAINING=$(gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:50){ nodes{ isResolved comments(first:1){ nodes{ author{login} } } } }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F num="$PR_NUM" \
| jq --arg re "$BOT_RE" '[.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login | test($re))]
       | length')
echo "Remaining unresolved bot threads on PR #$PR_NUM: $REMAINING"
```

`$REMAINING` above is the whole point of the re-fetch: it is counted **now**, not carried from
step 1. Any PR status the summary states follows the same rule via
`bash "$HOME/.codex/scripts/lib/state-assert.sh" observe pr "$PR_NUM"` (`base/practices/verify-before-asserting.md`).

Emit a concise summary to the user:

> Resolved N bot threads on PR #X.
>
> - Fixed + committed: <count> (sha: `<LAST_SHA>`)
> - Already addressed: <count>
> - Declined: <count>
> - Skipped (human-authored): <count>
>
> Remaining unresolved bot threads: <REMAINING>. <If >0, name them.>

### 7. Restore the starting branch (never strand the tree)

This skill switched your working tree to the PR head in step 1. Before exiting —
on success **and** on every post-switch abort (the ≥50-thread guard, a gate failure,
an API failure) — return the tree to where it started. Leaving it on the PR head is
exactly what put a later run on a now-merged branch (issue #17). Prefer the branch you
started on; fall back to the PR's **base** branch, then the repo default — never a
hardcoded `main`.

```bash
# Guard on a clean tree — never switch away over uncommitted work.
if [ -n "$(git status --porcelain)" ]; then
  echo "NOTE: tree not clean — staying on '$(git rev-parse --abbrev-ref HEAD)'; restore manually."
else
  DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  [ -z "$DEFAULT" ] && DEFAULT=main
  for b in "$ORIG_BRANCH" "$PR_BASE" "$DEFAULT"; do
    [ -n "$b" ] || continue
    git show-ref --verify --quiet "refs/heads/$b" || continue
    [ "$b" = "$(git rev-parse --abbrev-ref HEAD)" ] || git switch "$b" --quiet
    echo "Restored working tree to '$b'."
    break
  done
fi
```

## Important rules

- **Never resolve a human-authored thread.** Even if it looks trivial. Human discussions require human resolution.
- **Never push to the default branch.** This skill only ever pushes to the PR's head branch.
- **Never force-push.** If your local branch has diverged from the remote head, fetch + rebase or ask the user — do not `push --force`.
- **Never `--no-verify`** on commits. Pre-commit gates exist for a reason.
- **Never amend already-pushed commits.** Always make a new commit per bot-review batch.
- **Idempotent:** running this skill twice in a row should be a no-op the second time. If you're about to resolve a thread that's already `isResolved`, skip it silently.
- **Always restore the starting branch on exit** (step 7), on success or any post-switch abort — never leave the working tree stranded on the PR head (issue #17).

## Failure modes

- **PR is not OPEN** (closed, merged, draft) → abort with a clear message. This skill only addresses live review traffic.
- **Working tree dirty** → abort. The user must commit or stash before invoking; otherwise we'd risk losing their in-progress work when we check out the PR branch.
- **Bot finding is ambiguous** (vague comment, can't tell what change is asked for) → reply `Need clarification: <what you don't understand>`, do **not** resolve. Let the human pick it up.
- **All gates red after a fix attempt** → revert the fix in a new commit, leave the thread unresolved with a reply explaining the conflict, ask the user — then run step 7 to restore the starting branch so the tree isn't stranded on the PR head.
- **≥50 unresolved threads** → abort; pagination is intentionally not implemented.
