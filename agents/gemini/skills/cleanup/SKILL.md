---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/cleanup.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: cleanup
description: Sweep ALL merged branches (local and, on confirmation, remote) plus resolved run-state, not just the current task's branch. Detects squash/rebase merges, which `--merged` alone can never see. Names each branch explicitly so command-safety gating never blocks the delete. Never touches unmerged or protected branches, or state for a live run.
---

# /cleanup

Sweep what a finished task leaves behind. Two kinds of debris, one command:

- **Merged branches** — local and, on confirmation, remote. The failure mode this exists to
  prevent is deleting only the *current* task's branch and leaving dozens of stale merged
  branches behind, and being **blocked** by command-safety gating because a "clean up"-style
  instruction never named a branch. This sweeps **everything already merged** and **names each
  branch explicitly**.
- **Resolved run-state** — the gitignored scratch a skill run leaves in `.gemini/state`: thread
  caches for PRs that have since closed, run markers whose branch is gone, gap-analysis
  artifacts from a finished run. These accumulate unboundedly and are exactly the kind of dead
  state a sweep exists to remove.

Argument selects branch scope: `local` (default), `remote`, or `all`. Run-state is swept in
every scope — it is local debris, not a remote-facing action. Add `verbose` to surface the
process detail the default output deliberately omits.

## Guardrails (never violated)

- **Only ever delete a branch PROVEN merged into the default branch.** Never delete unmerged
  work. "Proven" has exactly two forms, and each re-validates itself at the moment of deletion:
  - **fast-forward** — the branch tip is an ancestor of `origin/<default>`. Deleted with
    `git branch -d`, whose own merged-only refusal is the re-check.
  - **rewritten merge (squash or rebase)** — a **freshly-queried** merged PR whose
    `mergeCommit.oid` is contained in `origin/<default>` **and** whose `headRefOid` equals the
    local tip. Deleted with `git update-ref -d refs/heads/<b> <tip>`, an atomic
    compare-and-delete that fails if the branch moved since it was classified.
- **Never `git branch -D`.** It deletes whatever is there *now*, on the strength of a decision
  made earlier — the one shape that can destroy a commit added mid-sweep. The expected-OID
  delete above does the same job and cannot.
- **Never delete a protected branch:** the default branch itself, plus `main`, `master`,
  `develop`, and anything matching `release/*` / `hotfix/*`.
- **Never delete the currently checked-out branch, or one checked out in another worktree.**
  `git branch -d` refuses both; `git update-ref -d` does **not**, so they are excluded during
  enumeration rather than left to a downstream refusal.
- **Remote deletes are outward-facing** — list them and get one confirmation before deleting
  (`base/practices/git-and-prs.md`). Local deletes are safe + reflog-recoverable, so they
  proceed autonomously.
- **PR status is admissible only when FRESH and CORROBORATED.** Deciding from a *remembered*
  PR status — "the PR was open earlier in this session", a lagging local ref — is forbidden
  (`base/practices/verify-before-asserting.md`). A status **queried live in this run** and then
  **proved locally** (`git merge-base --is-ancestor <mergeCommit> origin/<default>`) is not that:
  it is a live read plus a local ancestry proof. The distinction matters because a blanket ban
  on PR status left the skill with **no** working detector for squash merges, and a squash
  merge is what most repos do — so the sweep silently did nothing at all (#106).
- **A `[gone]` upstream is corroborating evidence, never sufficient.** A branch deleted on the
  remote *without* merging looks identical to one deleted after merging.
- **Never delete run-state for an OPEN PR or an in-flight run.** Those markers arm
  `/implement-issue`'s continuation gate; removing one mid-run disables it silently.
- **Liveness is never file age.** Every keep/delete decision reads a freshly-fetched ref or a
  live PR state, never an mtime — a slow run's state is not stale and a fast one's is not fresh.

## Output contract

The report is **terse by default** and its brevity is structural, not stylistic: a sweep that
narrates itself buries the one or two lines that matter.

- **One line per category that actually changed**, plus a final repository-state line. Target
  ≤3 lines for a typical sweep.
- **Omit empty categories entirely.** No `(0)` sections, no explanation of absent work.
- **No process narration.** Re-fetch discipline and step ordering are *behavior*, not prose.
  Mention them only when they changed the outcome, or under `verbose`.
- **Brevity applies to success only.** A guardrail firing, a refused delete, a branch that could
  not be verified, anything skipped or left behind — all report in full, every run.

```
Deleted (local): issue-3-generic-release-workflow-or-document
Cleared state: threads-{41,47,51,57,59,65,68,72,76}.json, gaps.md, gaps.err
main: clean, in sync with origin/main
```

The decisions behind all of this live in `scripts/lib/cleanup-lib.sh`, so they are executable and
regression-tested (`scripts/check-cleanup.sh`) rather than re-derived from prose each run.

## Steps

### 1. Resolve, then return to a clean, current default branch

Refresh remote state, then — so one command fully resets local state (issue #17) — **land back on
an up-to-date default branch before sweeping.** This is what lets the sweep delete the
*just-merged* branch you were on: once you switch away from it, it is no longer the current
branch and becomes eligible. Sweeping first could never delete the branch you were standing on.

`NOTES` accumulates the loud half of the output contract. Append to it anywhere below; it is
printed in full in step 6 regardless of how terse the rest of the report is.

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$DEFAULT" ] && DEFAULT=main
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
# Every accumulator is initialized HERE, not at the step that fills it: a scope that skips a step
# (`local` never runs step 4) must still leave step 6 a defined, empty variable to report from.
NOTES=""; DELETED_LOCAL=""; DELETED_REMOTE=""; CLEARED=""
git fetch --prune origin --quiet 2>/dev/null \
  || NOTES="${NOTES}NOTE: could not fetch origin — classifying against possibly-stale refs.
"
```

Return to a clean, current default branch — **guarded on a clean tree** so we never switch or
pull over uncommitted work. On a dirty tree, skip the return and still sweep against the current
default:

```bash
if [ -n "$(git status --porcelain)" ]; then
  NOTES="${NOTES}NOTE: working tree dirty — staying on '$CURRENT'; not returning to $DEFAULT.
"
else
  [ "$CURRENT" = "$DEFAULT" ] || git switch "$DEFAULT" --quiet
  git pull --ff-only origin "$DEFAULT" --quiet 2>/dev/null \
    || NOTES="${NOTES}NOTE: could not fast-forward $DEFAULT (diverged?) — sweeping against local $DEFAULT.
"
  CURRENT="$(git rev-parse --abbrev-ref HEAD)"   # now the default branch
fi
```

### 2. Enumerate candidate local branches

```bash
PROTECTED='^(HEAD|'"$DEFAULT"'|main|master|develop|release/.*|hotfix/.*)$'

# Classify against the freshly-fetched remote tip, so a stale or diverged local default can't
# hide a merged branch (or resurrect a just-deleted one). Fall back to the local default only
# when there is no origin/<default> (no remote).
BASE="origin/$DEFAULT"
git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || BASE="$DEFAULT"

# Branches checked out in ANOTHER worktree. `git branch -d` refuses these, but the expected-OID
# delete does not — so they are excluded here rather than relying on a downstream refusal.
WORKTREES="$(git worktree list --porcelain 2>/dev/null | sed -n 's@^branch refs/heads/@@p')"

CANDIDATES="$(git for-each-ref --format='%(refname:short)' refs/heads \
  | grep -Ev "$PROTECTED" | grep -Fxv "$CURRENT" || true)"
```

Is a live PR read even available? Decide **once**, so a repo with no `gh` degrades quietly to
fast-forward-only detection (exactly its behavior before #106) while a repo that *has* `gh` and
whose query *fails* is reported, never silently downgraded to "not merged".

```bash
HAVE_GH=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
   && git remote get-url origin >/dev/null 2>&1; then HAVE_GH=1; fi
```

### 3. Classify and delete local branches (scope `local` or `all`)

One fresh query per candidate, then the library decides. `--limit` is not decoration: without it
`gh pr list` returns only its default page, so a long-lived branch's merged PR can fall off the
end and read as unmerged.

```bash
DELETED_LOCAL=""
while IFS= read -r b; do
  [ -n "$b" ] || continue
  if printf '%s\n' "$WORKTREES" | grep -Fxq "$b"; then
    NOTES="${NOTES}SKIPPED $b — checked out in another worktree
"; continue
  fi

  PRJSON=""
  if [ "$HAVE_GH" -eq 1 ]; then
    if ! PRJSON="$(gh pr list --head "$b" --state merged --limit 20 \
                     --json number,headRefOid,mergeCommit 2>/dev/null)"; then
      NOTES="${NOTES}UNVERIFIED $b — the merged-PR query failed; preserved
"; continue
    fi
  fi

  # Line 1 = verdict, line 2 = the tip the verdict was computed from, line 3 = detail.
  if ! V="$(printf '%s' "$PRJSON" | bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" branch-verdict "$b" "$BASE")"; then
    NOTES="${NOTES}UNVERIFIED $b — could not be classified; preserved
"; continue
  fi
  VERDICT="$(printf '%s\n' "$V" | sed -n 1p)"
  TIP="$(printf '%s\n' "$V" | sed -n 2p)"
  DETAIL="$(printf '%s\n' "$V" | sed -n 3p)"

  case "$VERDICT" in
    merged-ff)
      if git branch -d "$b" >/dev/null 2>&1; then
        DELETED_LOCAL="${DELETED_LOCAL}$b
"
      else
        NOTES="${NOTES}REFUSED $b — git branch -d declined it; left in place
"
      fi
      ;;
    merged-pr)
      # Atomic compare-and-delete: removes the ref ONLY if it still points at the exact commit
      # the verdict was computed from. A commit landing on the branch mid-sweep fails this.
      if git update-ref -d "refs/heads/$b" "$TIP" 2>/dev/null; then
        DELETED_LOCAL="${DELETED_LOCAL}$b
"
      else
        NOTES="${NOTES}REFUSED $b — it moved during the sweep (was $DETAIL); left in place
"
      fi
      ;;
    unverified)
      NOTES="${NOTES}UNVERIFIED $b — $DETAIL; preserved
"
      ;;
    unmerged) : ;;   # the common case: preserve, silently
  esac
done <<EOF
$CANDIDATES
EOF
```

Naming each branch in its own `git branch -d "$b"` / `git update-ref -d "refs/heads/$b"` call is
what keeps command-safety gating from blocking the sweep — there is never a vague, branch-less
"clean up" for it to reject.

### 4. Remote branches (scope `remote` or `all`)

The remote half needs no PR evidence: GitHub's `delete_branch_on_merge` already removes
squash-merged remote branches server-side, so what is left here really is
ancestor-merged. Enumerate, **show the list and get one confirmation**, then delete by name.

```bash
# `grep '^origin/'` drops the bare `origin` short form of the origin/HEAD symref (which --format
# renders as plain `origin`, not a real branch, so `sed 's@^origin/@@'` — no trailing slash to
# strip — would otherwise leak it into the list and offer a bogus `git push origin --delete
# origin`); `grep -v '^origin/HEAD$'` is belt-and-suspenders for a fully-qualified form.
REMOTE_MERGED="$(git branch -r --merged "$BASE" --format='%(refname:short)' \
  | grep '^origin/' | grep -v '^origin/HEAD$' | sed 's@^origin/@@' \
  | grep -Ev "$PROTECTED" | grep -Fxv "$CURRENT" | sort -u || true)"
```

Fed by a heredoc, not a pipe: a piped `while` runs in a subshell, so every `DELETED_REMOTE`
append would be discarded and step 6 would report an empty category for work it really did.

```bash
while IFS= read -r b; do
  [ -n "$b" ] || continue
  if git push origin --delete "$b"; then
    DELETED_REMOTE="${DELETED_REMOTE}$b
"
  else
    NOTES="${NOTES}REFUSED origin/$b — the remote delete failed; left in place
"
  fi
done <<EOF
$REMOTE_MERGED
EOF
```

### 5. Sweep resolved run-state

Runs in every scope. `state-scan` enumerates; the library decides; **anything it classifies
`other` is never touched** — a sweep that deleted what it could not classify would eventually
eat a file some future skill depends on.

```bash
STATE=".gemini/state"
CLEARED=""
TABC="$(printf '\t')"
SCAN="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-scan "$STATE")"

# The gap-analysis lock, if present, means a gap dispatch is writing artifacts RIGHT NOW.
LOCK=0
[ -f "$STATE/gap-analysis.lock" ] && LOCK=1
```

**Markers first** — the gap artifacts' verdict depends on whether a run is live, and an
`/implement-issue` run is exactly what a marker describes.

```bash
RUN=none; SAW_MARKER=0
while IFS="$TABC" read -r kind path key; do
  [ "$kind" = marker ] || continue
  SAW_MARKER=1

  # An OPEN PR outranks branch absence: the branch may have been tidied while the run is live.
  PRSTATE=none
  URL="$(jq -r '.prUrl // empty' "$path" 2>/dev/null || true)"
  if [ -n "$URL" ]; then
    PRSTATE=unknown
    if [ "$HAVE_GH" -eq 1 ]; then
      S="$(gh pr view "$URL" --json state --jq '.state' 2>/dev/null | tr 'A-Z' 'a-z')"
      [ -n "$S" ] && PRSTATE="$S"
    fi
  fi

  if [ "$key" = "-" ]; then
    LREF=unknown; RREF=unknown          # unreadable marker -> fails closed to keep
  else
    LREF=0; git show-ref --verify --quiet "refs/heads/$key" && LREF=1
    RREF=0; git show-ref --verify --quiet "refs/remotes/origin/$key" && RREF=1
  fi

  if ! MV="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict marker "$PRSTATE" "$LREF" "$RREF")"; then
    NOTES="${NOTES}SKIPPED ${path##*/} — could not be classified; kept
"; RUN=keep; continue
  fi
  [ "$MV" = keep ] && RUN=keep
  if [ "$MV" = stale ]; then
    # Re-read at the moment of deletion: a marker atomically replaced since the scan belongs to
    # a DIFFERENT run, and removing it would disarm that run's continuation gate.
    NOW="$(jq -r '.branch // empty' "$path" 2>/dev/null || true)"
    if [ "${NOW:--}" = "$key" ] && rm -f "$path"; then
      CLEARED="${CLEARED}${path##*/}
"
    else
      NOTES="${NOTES}SKIPPED ${path##*/} — it changed during the sweep; kept
"; RUN=keep
    fi
  fi
done <<EOF
$SCAN
EOF
[ "$RUN" = none ] && [ "$SAW_MARKER" -eq 1 ] && RUN=stale
```

**Then gap artifacts and thread caches.**

```bash
GV="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict gaps "$LOCK" "$RUN")" || GV=keep

while IFS="$TABC" read -r kind path key; do
  case "$kind" in
    gaps)
      [ "$GV" = stale ] || continue
      rm -f "$path" && CLEARED="${CLEARED}${path##*/}
"
      ;;
    threads)
      PRSTATE=unknown
      if [ "$HAVE_GH" -eq 1 ]; then
        S="$(gh pr view "$key" --json state --jq '.state' 2>/dev/null | tr 'A-Z' 'a-z')"
        [ -n "$S" ] && PRSTATE="$S"
      fi
      TV="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict threads "$PRSTATE")" || continue
      [ "$TV" = stale ] || continue
      rm -f "$path" && CLEARED="${CLEARED}${path##*/}
"
      ;;
  esac
done <<EOF
$SCAN
EOF
```

A kept gap artifact that has grown large is **reported, not truncated** — truncating a live run's
captured stream destroys the evidence its operator is about to read.

```bash
if [ "$GV" = keep ]; then
  for f in "$STATE"/gaps.err "$STATE"/gaps-*.err; do
    [ -f "$f" ] || continue
    sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
    [ -n "$sz" ] && [ "$sz" -gt 262144 ] \
      && NOTES="${NOTES}LARGE ${f##*/} is $((sz / 1024)) KB and belongs to a live run — kept
"
  done
fi
```

### 6. Report

Loud lines first (they are the exception), then one line per category that changed, then the
state line. Categories with nothing in them cannot appear — `report` builds lines from records,
so there is no empty section to suppress.

```bash
[ -n "$NOTES" ] && printf '%s' "$NOTES"
{
  printf '%s\n' "$DELETED_LOCAL"  | while IFS= read -r x; do [ -n "$x" ] && printf 'Deleted (local)\t%s\n'  "$x"; done
  printf '%s\n' "$DELETED_REMOTE" | while IFS= read -r x; do [ -n "$x" ] && printf 'Deleted (remote)\t%s\n' "$x"; done
  printf '%s\n' "$CLEARED"        | while IFS= read -r x; do [ -n "$x" ] && printf 'Cleared state\t%s\n'    "$x"; done
} | bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" report --tail "$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-line "$ROOT" "$DEFAULT")"
```

Under `verbose`, additionally state what was examined and preserved: the candidate count, how
many were classified `unmerged`, and whether the fetch changed any verdict. Never by default.

## Notes

- This never runs `git branch -D`, `push --force`, or `clean -fd`. Unmerged branches are always
  preserved; unclassifiable run-state is always kept.
- Run it after a merge, or periodically. It is idempotent — a second run finds nothing new and
  prints only the state line.
- The remote half is enumerated with `--merged` alone on purpose (see step 4). Only the **local**
  half needs PR evidence, because only local refs survive a squash merge.
