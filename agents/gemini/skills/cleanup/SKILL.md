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
# brew-installed tools are routinely off PATH in a non-interactive shell. Without this the `gh`
# probe below silently fails, no PR evidence is ever fetched, and every squash-merged branch
# classifies `unmerged` — reinstating #106 inside the fix for #106, with no note to show for it.
command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
# The local fallback matters: on a `master`-default repo with no origin/HEAD symref, defaulting
# straight to `main` names a branch that does not exist, so BASE resolves to nothing and EVERY
# branch reports UNVERIFIED. (Mirrors adb_default_branch, which a skill's markdown cannot source.)
if [ -z "$DEFAULT" ]; then
  for b in main master; do
    git show-ref --verify --quiet "refs/heads/$b" && DEFAULT="$b" && break
  done
fi
[ -z "$DEFAULT" ] && DEFAULT=main
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
# Every accumulator is initialized HERE, not at the step that fills it: a scope that skips a step
# (`local` never runs step 4) must still leave step 6 a defined, empty variable to report from.
NOTES=""; DELETED_LOCAL=""; DELETED_REMOTE=""; CLEARED=""
git fetch --prune origin --quiet 2>/dev/null \
  || NOTES="${NOTES}NOTE: could not fetch origin — classifying against possibly-stale refs.
"
```

Return to a clean, current default branch — **guarded on the clone's own safety state**, so we
never switch or pull over work in progress. A clean `git status` is *not* that guard: a rebase
between steps, a `git bisect`, or an interrupted cherry-pick all leave the tree clean, and
switching away from one corrupts it. On anything unsafe, skip the return and sweep in place:

```bash
CSTATE="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" clone-state "$ROOT" "$DEFAULT")" || CSTATE=dirty
if [ "$CSTATE" != local-ok ] && [ "$CSTATE" != not-default ]; then
  NOTES="${NOTES}NOTE: clone is '$CSTATE' — staying on '$CURRENT'; not returning to $DEFAULT.
"
else
  # The switch MUST be guarded. `git switch` fails if $DEFAULT is checked out in another worktree,
  # and an unguarded failure would leave HEAD on the feature branch while the next line
  # fast-forwards — silently repointing the USER'S BRANCH onto origin/<default>.
  SWITCHED=1
  if [ "$CURRENT" != "$DEFAULT" ]; then
    git switch "$DEFAULT" --quiet 2>/dev/null || SWITCHED=0
  fi
  if [ "$SWITCHED" -eq 0 ]; then
    NOTES="${NOTES}NOTE: could not switch to $DEFAULT (checked out elsewhere?) — staying on '$CURRENT'.
"
  else
    # `merge --ff-only` against the ref the fetch above already retrieved, NOT `pull` — a pull is a
    # second network round trip for refs we hold, and it can move origin/$DEFAULT *after* the fetch
    # that BASE below is reasoned about.
    git merge --ff-only "origin/$DEFAULT" --quiet 2>/dev/null \
      || NOTES="${NOTES}NOTE: could not fast-forward $DEFAULT (diverged?) — sweeping against local $DEFAULT.
"
  fi
  CURRENT="$(git rev-parse --abbrev-ref HEAD)"
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

# One live PR read, in one place. Prints open|closed|merged|unknown; anything unreadable is
# `unknown`, which every state-verdict arm fails closed on. `ascii_downcase` inside --jq uses the
# jq already running in gh rather than piping through a second process.
pr_state() {
  local s=""
  [ "$HAVE_GH" -eq 1 ] && s="$(gh pr view "$1" --json state --jq '.state | ascii_downcase' 2>/dev/null)"
  printf '%s\n' "${s:-unknown}"
}
```

### 3. Classify and delete local branches (scope `local` or `all`)

One fresh query per candidate, then the library decides. `--limit` is not decoration: without it
`gh pr list` returns only its default page, so a long-lived branch's merged PR can fall off the
end and read as unmerged.

```bash
while IFS= read -r b; do
  [ -n "$b" ] || continue
  # WHOLE-LINE match, via grep. The builtin newline-delimited `case` form looks cheaper and is a
  # trap: a newline held in a variable from command substitution is the EMPTY STRING (the strip
  # applies to trailing newlines), which degrades the test to a SUBSTRING match — so a deletable
  # `issue-121` is skipped forever because a worktree holds `issue-121-currency`. Two processes
  # per candidate is the right price for a guard that stands between `git update-ref -d` and a
  # branch checked out somewhere else (update-ref, unlike `git branch -d`, will happily delete it).
  if printf '%s\n' "$WORKTREES" | grep -Fxq "$b"; then
    NOTES="${NOTES}SKIPPED $b — checked out in another worktree
"; continue
  fi

  # Spend a network round trip ONLY on a branch whose answer needs one. A branch already
  # contained in the base is settled by local ancestry, and this is the common case right after
  # a merge — querying it would cost one API call per branch to learn nothing. This is a COST
  # guard, never a decision: the library re-runs the same ancestry test and remains the only
  # thing that produces a verdict, so a wrong guess here can only waste a call, never delete.
  PRJSON=""
  if [ "$HAVE_GH" -eq 1 ] && ! git merge-base --is-ancestor "$b" "$BASE" 2>/dev/null; then
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
  # Three `read`s off a heredoc: no subshell, no process. Three `printf | sed -n Np` pipelines
  # would spend six processes per candidate to slice a string already in hand.
  { IFS= read -r VERDICT; IFS= read -r TIP; IFS= read -r DETAIL || DETAIL=""; } <<EOF2
$V
EOF2

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

The remote half still enumerates with `--merged` alone. That rests on an **assumption, not a
fact**: GitHub's `delete_branch_on_merge` removes squash-merged remote branches server-side, so
what survives on the remote really is ancestor-merged. On a repo with that setting **off**, this
half stays as blind to a squash merge as the local half was before #106 — so say so rather than
report a clean sweep. Enumerate, **show the list and get one confirmation**, then delete by name.

```bash
if [ "$HAVE_GH" -eq 1 ] \
   && [ "$(gh api 'repos/{owner}/{repo}' --jq '.delete_branch_on_merge' 2>/dev/null)" = "false" ]; then
  NOTES="${NOTES}NOTE: delete_branch_on_merge is OFF — squash-merged remote branches are not
  detected here (only ancestor-merged ones are). See baseline issue #56.
"
fi
```

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
TABC="$(printf '\t')"
SCAN="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-scan "$STATE")"

# The gap-analysis lock, if present, means a gap dispatch is writing artifacts RIGHT NOW. Read it
# from the SCAN, not from a second hardcoded path: the library already recognises the filename,
# and a rename that updated only one of the two spellings would silently set LOCK=0 and delete a
# live dispatch's findings — the exact failure the lock exists to prevent.
# An `if`, not `… && LOCK=1`: an AND-list whose test fails leaves the whole fenced block on exit
# status 1, and "no lock present" is the overwhelmingly common case — so the agent would read a
# perfectly healthy sweep as a failed step and could abandon it before any state is swept.
LOCK=0
if printf '%s\n' "$SCAN" | grep -q "^lock${TABC}"; then LOCK=1; fi
```

**Markers first** — the gap artifacts' verdict depends on whether a run is live, and an
`/implement-issue` run is exactly what a marker describes.

```bash
RUN=none
while IFS="$TABC" read -r kind path key; do
  [ "$kind" = marker ] || continue
  # Seed on FIRST sight: a marker exists, so this is a finished run until some marker says keep.
  # (A separate "did we see one" flag plus a trailing fixup is one fact tracked twice — and the
  # fixup is a compound test that leaves the whole block on a non-zero status.)
  [ "$RUN" = none ] && RUN=stale

  # Cheap LOCAL facts first. `state-verdict marker` returns keep whenever either ref survives, so
  # for a live branch — and always for an unreadable marker — the PR read below cannot change the
  # answer. Ordering it after the refs makes that round trip conditional instead of unconditional.
  if [ "$key" = "-" ]; then
    LREF=unknown; RREF=unknown          # unreadable marker -> fails closed to keep
  else
    LREF=0; git show-ref --verify --quiet "refs/heads/$key" && LREF=1
    RREF=0; git show-ref --verify --quiet "refs/remotes/origin/$key" && RREF=1
  fi

  # An OPEN PR outranks branch absence: the branch may have been tidied while the run is live.
  PRSTATE=none
  if [ "$LREF" = 0 ] && [ "$RREF" = 0 ]; then
    URL="$(jq -r '.prUrl // empty' "$path" 2>/dev/null || true)"
    [ -n "$URL" ] && PRSTATE="$(pr_state "$URL")"
  fi

  if ! MV="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict marker "$PRSTATE" "$LREF" "$RREF")"; then
    NOTES="${NOTES}SKIPPED ${path##*/} — could not be classified; kept
"; RUN=keep; continue
  fi
  [ "$MV" = keep ] && RUN=keep
  if [ "$MV" = stale ]; then
    # Re-read at the moment of deletion: a marker atomically replaced since the scan belongs to
    # a DIFFERENT run, and removing it would disarm that run's continuation gate. Through the
    # library, so this read and the one that produced "$key" can never be two different reads.
    NOW="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" marker-branch "$path")"
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
      TV="$(bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict threads "$(pr_state "$key")")" || continue
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
emit() { printf '%s\n' "$2" | while IFS= read -r x; do [ -n "$x" ] && printf '%s\t%s\n' "$1" "$x"; done; }

[ -n "$NOTES" ] && printf '%s' "$NOTES"
{
  emit 'Deleted (local)'  "$DELETED_LOCAL"
  emit 'Deleted (remote)' "$DELETED_REMOTE"
  emit 'Cleared state'    "$CLEARED"
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
