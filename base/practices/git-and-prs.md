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
