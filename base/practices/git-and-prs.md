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
- **`git restore <path>`** — worktree by default. `--staged` rewrites the *index*
  instead (leaving your working file alone); `--staged --worktree` / `-SW` does
  **both**. All three destroy something you can't get back.

  These overwrite the target **in place**. An edit you never staged was never
  turned into a git object at all, so there is no reflog entry, no dangling blob,
  and nothing for `git fsck` to find — that work is simply gone. (Content you had
  `git add`ed does exist as a blob, so a staged snapshot is *sometimes*
  recoverable via `git fsck --unreachable`; don't rely on it.) One of these
  discarded ~40 minutes of unsaved work during a routine test.

- **`git stash drop`** / **`git stash clear`**

  Weaker but still bad: a stash entry *is* commit objects, so the dropped SHA is
  recoverable from the command's own output or `git fsck --unreachable`
  **until gc prunes it**. Recovery is possible, not guaranteed — treat it as loss.

**Prefer the non-destructive move.** `git stash push -- <path>` parks the change
instead of deleting it, and `git diff HEAD > /tmp/x.patch` keeps a copy —
`HEAD`, because a bare `git diff` captures only *unstaged* differences and would
silently omit the staged snapshot you are about to overwrite. And when the goal is
to test something rather than to discard it, don't touch the tracked file at all —
see the negative-testing method in `self-review.md`.

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
