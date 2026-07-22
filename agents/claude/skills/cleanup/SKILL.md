---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/cleanup.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
name: cleanup
description: Sweep ALL merged branches (local and, on confirmation, remote), not just the current one. Names each branch explicitly so command-safety gating never blocks the delete. Never touches unmerged or protected branches.
argument-hint: [local | remote | all]  (default: local)
allowed-tools: Bash, Read
user-invocable: true
---

# /cleanup

Sweep merged branches after work lands. The default failure mode this skill exists
to prevent: deleting only the *current* task's branch and leaving dozens of stale
merged branches behind, and getting **blocked** by command-safety gating because a
"clean up"-style instruction never named a branch. This skill sweeps **everything
already merged** and **names each branch explicitly**.

Argument selects scope: `local` (default), `remote`, or `all`.

## Guardrails (never violated)

- **Only ever delete branches already merged into the default branch.** Never
  delete unmerged work.
- **Never delete a protected branch:** the default branch itself, plus `main`,
  `master`, `develop`, and anything matching `release/*` / `hotfix/*`.
- **Never delete the currently checked-out branch.**
- **Local deletes** use `git branch -d` (the safe, merged-only delete — it refuses
  to drop an unmerged branch), never `-D`.
- **Remote deletes are outward-facing** — list them and get one confirmation before
  deleting (`base/practices/git-and-prs.md`). Local deletes are safe + reflog-
  recoverable, so they proceed autonomously.
- **Never narrate a PR's open/closed/merged status.** A branch's eligibility for
  deletion is decided *purely* from freshly-fetched merged-detection (`git branch
  --merged origin/<default>`) plus `git branch -d`'s own merged-only refusal — never
  from whether some PR "is still open," which may be stale in context or a lagging
  local ref (`base/practices/verify-before-asserting.md`). An unmerged branch is
  preserved because `-d` refuses it, not because a PR is open.

## Steps

### 1. Resolve, then return to a clean, current default branch

Resolve the branches and refresh remote state, then — so one command fully resets
local state (issue #17) — **land back on an up-to-date default branch before
sweeping.** This is what lets the sweep delete the *just-merged* branch you were on:
once you switch away from it onto a fresh default, it is no longer the current branch
and becomes eligible for deletion. Sweeping first (the old order) could never delete
the branch you were standing on.

```bash
DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$DEFAULT" ] && DEFAULT=main
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
git fetch --prune origin --quiet    # refresh merged status + drop deleted remote refs
```

Return to a clean, current default branch — **guarded on a clean tree** so we never
switch or pull over uncommitted work. On a dirty tree, skip the return (surface it)
and still sweep against the current default:

```bash
if [ -n "$(git status --porcelain)" ]; then
  echo "NOTE: working tree dirty — staying on '$CURRENT'; sweeping without returning to $DEFAULT."
else
  [ "$CURRENT" = "$DEFAULT" ] || git switch "$DEFAULT" --quiet
  git pull --ff-only origin "$DEFAULT" --quiet \
    || echo "NOTE: could not fast-forward $DEFAULT (diverged?) — sweeping against local $DEFAULT."
  CURRENT="$(git rev-parse --abbrev-ref HEAD)"   # now the default branch
fi
```

### 2. Enumerate merged branches (never protected, never current)

```bash
PROTECTED='^(HEAD|'"$DEFAULT"'|main|master|develop|release/.*|hotfix/.*)$'

# Classify both lists against the freshly-fetched remote tip, so a stale or diverged local
# default branch can't hide a merged branch (or resurrect a just-deleted one). Fall back to
# the local default only when there is no origin/<default> (no remote). This is the
# is-it-merged basis — never a PR's assumed open/closed status (verify-before-asserting.md).
BASE="origin/$DEFAULT"
git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || BASE="$DEFAULT"

# Local, merged into the fresh base:
LOCAL_MERGED="$(git branch --merged "$BASE" --format='%(refname:short)' \
  | grep -Ev "$PROTECTED" | grep -Fxv "$CURRENT" || true)"

# Remote, merged into the fresh base. `grep '^origin/'` drops the bare `origin` short form
# of the origin/HEAD symref (which --format renders as plain `origin`, not a real branch, so
# `sed 's@^origin/@@'` — no trailing slash to strip — would otherwise leak it into the list
# and offer a bogus `git push origin --delete origin`); `grep -v '^origin/HEAD$'` is
# belt-and-suspenders for a fully-qualified form.
REMOTE_MERGED="$(git branch -r --merged "$BASE" --format='%(refname:short)' \
  | grep '^origin/' | grep -v '^origin/HEAD$' | sed 's@^origin/@@' \
  | grep -Ev "$PROTECTED" | grep -Fxv "$CURRENT" | sort -u || true)"
```

Present both lists to the user with counts. If both are empty, report "nothing to
sweep" and stop.

### 3. Delete — naming each branch explicitly

**Local** (scope `local` or `all`) — proceed autonomously, one explicit name per call:

```bash
echo "$LOCAL_MERGED" | while IFS= read -r b; do
  [ -n "$b" ] && git branch -d "$b"    # explicit name; -d refuses unmerged
done
```

**Remote** (scope `remote` or `all`) — show `REMOTE_MERGED` and get one confirmation
first, then delete each by explicit name:

```bash
echo "$REMOTE_MERGED" | while IFS= read -r b; do
  [ -n "$b" ] && git push origin --delete "$b"
done
```

Naming each branch in its own `git branch -d "$b"` / `git push origin --delete "$b"`
call is what keeps command-safety gating from blocking the sweep — there is never a
vague, branch-less "clean up" for it to reject.

### 4. Report

Summarize: N local deleted (named), M remote deleted (named), K skipped (protected/
unmerged/current, with reason). If any delete failed (e.g. `-d` refused an unmerged
branch), name it and leave it — do **not** escalate to `-D`; surface it for the user.

## Notes

- This never runs `git branch -D`, `push --force`, or `clean -fd`. It is a
  merged-only sweep; unmerged branches are always preserved.
- Run it after a merge, or periodically. It is idempotent — a second run finds
  nothing new.
