---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/resolve-pr-threads.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
name: resolve-pr-threads
description: Resolve unresolved bot-authored review threads on an open PR. Switches the working tree to the PR's head branch, addresses findings (commit + push if needed), replies, then marks each thread Resolved via GraphQL so branch protection unblocks merge.
argument-hint: <pr-number>
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, TaskCreate, TaskUpdate, TaskList
user-invocable: true
---

# /resolve-pr-threads

Address and resolve every unresolved **bot-authored** review thread on PR **#$ARGUMENTS** so the repo's "all comments must be resolved" branch protection releases.

> **Side effect:** this skill `git switch`-es your working tree to the PR's head branch. If you're mid-task on an unrelated branch, finish or stash that work first. The skill aborts on a dirty tree to protect uncommitted changes, but it will not warn before changing branches on a clean tree.

## When to invoke

- **After `/implement-issue` exits** with bot reviews not yet posted. The skill is the documented resume path for the bot-wait window expiring before the configured bot reviewer arrives.
- **Any time** Codex, Copilot, or another configured bot reviewer posts findings on an existing PR. Idempotent — safe to re-run if more threads appear later.

## Scope

**In scope:** unresolved review threads where the first comment was authored by a known automated reviewer login. The set of known automated-reviewer logins is **configurable** — a repo can extend or override it (e.g. via `agents.toml`, or by passing an explicit login) — and the defaults below cover the common GitHub review bots:

- `chatgpt-codex-connector` (OpenAI Codex code-review connector — note it has **no** `[bot]` suffix, so the `[bot]`-suffix heuristic never catches it; it must be matched by explicit login)
- `gemini-code-assist[bot]`, `gemini-code-assist`
- `copilot-pull-request-reviewer[bot]`, `copilot[bot]`
- `github-actions[bot]`
- `claude[bot]`, `claude-code[bot]`

> **Note:** the login match is anchored — `(?i)\[bot\]$|^gemini-code-assist$|^chatgpt-codex-connector$` — so it catches any `[bot]`-suffixed reviewer plus the two suffixless connectors by explicit login, and **never** matches a human login. It degrades gracefully if the configured reviewers change, so nothing breaks when a repo swaps one bot for another; extend the anchored alternation to add a new suffixless connector.

**Out of scope:** threads authored by humans (the repo owner or any other user). Never auto-resolve those — they require human-to-human discussion. If the only unresolved threads are human-authored, this skill reports them and exits without action.

**Also out of scope:** opening new PRs, merging PRs, requesting re-review, or any action beyond addressing + resolving the listed threads.

## Steps

### 1. Preflight

Require only `gh` and `jq` — the gate runner (Step 4) auto-detects the project's stack, so this skill does not hard-require any particular package manager.

```bash
PR_NUM="$(printf -- '%s' "$ARGUMENTS" | awk '{print $1}')"
[ -z "$PR_NUM" ] && { echo "ERROR: no PR number"; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
command -v gh || { echo "MISSING:gh"; exit 1; }
command -v jq || { echo "MISSING:jq"; exit 1; }
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
}' -f owner="$OWNER" -f repo="$REPO" -F num="$PR_NUM" > .claude/state/threads-$PR_NUM.json
```

50-thread cap is a hard ceiling. If the response indicates ≥50 unresolved threads (anomaly), abort and ask the user — paginating would risk dropping context across calls.

```bash
TOTAL=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length' .claude/state/threads-$PR_NUM.json)
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

For every unresolved thread, read it with the Read tool (load `.claude/state/threads-$PR_NUM.json`) and decide one of:

| Disposition                     | Criteria                                                                                       | Action                                                                                                               |
| ------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Legitimate code change**      | The bot found a real bug or correctness issue you agree with.                                  | Edit the relevant file, run gates, commit, push, then reply + resolve.                                               |
| **Already addressed**           | A prior commit in this PR (yours or `/code-review`'s) already fixed the underlying issue.      | Reply with `Addressed in <sha>: <one-line summary>`. Then resolve.                                                   |
| **Disagree with reason**        | The bot's claim is wrong, doesn't apply to the codebase, or is a style preference you decline. | Reply with `Declined: <one-sentence reason>`. Then resolve. Branch protection cares about resolution, not agreement. |
| **Human-authored**              | Author login is NOT in the known-bot list.                                                     | Skip. Log it in the summary and let the human handle.                                                                |
| **Bot login not in known list** | Author login looks bot-like (ends in `[bot]`) but isn't in the default known set.              | Treat as human-authored (skip + log) unless the user explicitly added it.                                            |

Use Read to inspect each thread; use Edit/Write for fixes; use the Bash commands below for replies and resolution.

### 4. Address legitimate findings

For each legitimate finding:

1. Make the code change with Edit or Write.
2. Run the project's gates with the auto-detected runner:
   ```bash
   bash "$HOME/.claude/scripts/lib/project-gates.sh" run
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
THREAD_ID="<id from .claude/state/threads-$PR_NUM.json>"
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
# Sanity check: re-fetch and count remaining unresolved bot threads.
REMAINING=$(gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:50){ nodes{ isResolved comments(first:1){ nodes{ author{login} } } } }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F num="$PR_NUM" \
| jq '[.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | select(.comments.nodes[0].author.login | test("(?i)\\[bot\\]$|^gemini-code-assist$|^chatgpt-codex-connector$"))]
       | length')
echo "Remaining unresolved bot threads on PR #$PR_NUM: $REMAINING"
```

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
