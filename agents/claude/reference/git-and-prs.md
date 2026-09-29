<!-- GENERATED FILE — do not edit by hand.
     Source: base/practices/git-and-prs.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->

# Git and pull requests — procedure

**Prefer the non-destructive move.** `git stash push -- <path>` parks the change
instead of deleting it, and

```sh
P="$(mktemp "${TMPDIR:-/tmp}/wip.XXXXXX")" && git diff HEAD > "$P" && echo "patch: $P"
```

keeps a copy. `HEAD`, because a bare `git diff` captures only *unstaged*
differences and would silently omit the staged snapshot you are about to
overwrite. `mktemp`, because a fixed name is the wrong shape for the one file
here whose contents git cannot get back: a second shell doing the same thing
truncates it, and the copy you reach for is the copy that is gone. **And the
path is printed**, because a backup you cannot name is a backup you do not have —
redirecting straight into `$(mktemp …)` throws away the only handle on it at the
exact moment you are about to need it. And when the goal is
to test something rather than to discard it, don't touch the tracked file at all —
see the negative-testing method in `self-review.md`.

  **A code span or a fenced block SUPPRESSES it, silently.** This is the same
  "only prose declares" rule the roadmap markers already live by, and it bites in
  the opposite direction: there, quoting an example protects you; here, quoting
  the keyword *loses the close* and nothing says so. Writing

  ```markdown
  `Closes #115`
  ```

  merges a PR that closes nothing. Measured on this repo: PR #294's body spelled
  both keywords in code spans, GitHub's own `closingIssuesReferences` came back
  **empty**, and two delivered `release-blocker` issues stayed open — which on a
  repo using the release-goal convention means readiness reports unmet blockers
  for work already on the default branch, and never converges.

  **So verify the link set instead of trusting the text** (`verify-before-asserting.md`
  — the body is a claim about what will happen, and GitHub publishes the answer):

  ```bash
  gh pr view <N> --json closingIssuesReferences --jq '[.closingIssuesReferences[].number]'
  ```

  Empty, or missing an issue you meant to close, means the keyword did not
  register — fix the body **before** the merge, or the close never happens at all.

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
