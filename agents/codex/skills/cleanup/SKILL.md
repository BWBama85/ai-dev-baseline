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

Sweep what a finished task leaves behind, then leave the tooling current. Two kinds of debris and
one currency check, one command:

- **Merged branches** — local and, on confirmation, remote. The failure mode this exists to
  prevent is deleting only the *current* task's branch and leaving dozens of stale merged
  branches behind, and being **blocked** by command-safety gating because a "clean up"-style
  instruction never named a branch. This sweeps **everything already merged** and **names each
  branch explicitly**.
- **Resolved run-state** — the gitignored scratch a skill run leaves in `.codex/state`: thread
  caches for PRs that have since closed, run markers whose branch is gone, gap-analysis
  artifacts from a finished run. These accumulate unboundedly and are exactly the kind of dead
  state a sweep exists to remove.
- **The installed baseline's currency** (step 7) — `/cleanup` runs right after a merge, which is
  when the install goes stale, and right before `/clear`, which is the step that cannot re-check.
  So this is where `baseline update` belongs (#139). It is housekeeping, never a gate: it can
  never fail the sweep, and it says nothing when the install is already current.

Argument selects branch scope: `local` (default), `remote`, or `all`. Run-state is swept in
every scope — it is local debris, not a remote-facing action. Add `verbose` to surface the
process detail the default output deliberately omits.

## Guardrails (never violated)

- **Only ever delete a branch PROVEN merged into the default branch.** Never delete unmerged
  work. "Proven" has exactly two forms:
  - **fast-forward** — the branch tip is an ancestor of `origin/<default>`.
  - **rewritten merge (squash or rebase)** — a **freshly-queried** merged PR whose
    `mergeCommit.oid` is contained in `origin/<default>` **and** whose `headRefOid` equals the
    local tip.
- **Every local delete is the same atomic compare-and-delete:**
  `git update-ref -d refs/heads/<b> <the tip the verdict was computed from>`. It removes the ref
  only if the branch still points exactly there, so a commit landing mid-sweep makes the delete
  fail loudly instead of destroying it.
- **Never `git branch -d` either — not even for the fast-forward case.** Its refusal tests
  whether the branch is merged into its **upstream** (or HEAD), *not* into `origin/<default>`.
  A branch that gained a pushed commit after being classified still satisfies that test, so `-d`
  would delete work that was never merged into the default branch — the exact guarantee this
  skill claims. The expected-OID delete is the stronger check, and it is the only one used.
- **Never `git branch -D`.** It deletes whatever is there *now*, on the strength of a decision
  made earlier.
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
- **The currency check never gates the sweep, and never updates the clone you are standing in.**
  It runs last, after the report is already composed; it is bounded by a wall-clock backstop; every
  failure resolves to at most one line; and it refuses to touch the install-source clone when that
  is the repo being swept (including through a linked worktree). `off` in the global `agents.toml`
  disables it entirely.

## Output contract

The report is **terse by default** and its brevity is structural, not stylistic: a sweep that
narrates itself buries the one or two lines that matter.

- **One line per category that actually changed**, plus a final repository-state line. Target
  ≤3 lines for a typical sweep.
- **Omit empty categories entirely.** No `(0)` sections, no explanation of absent work.
- **No process narration.** Re-fetch discipline and step ordering are *behavior*, not prose.
  Mention them only when they changed the outcome, or under `verbose`.
- **The preamble is part of the report.** Every branch/state line below is already rendered from a
  live read by the library; the gap that bit was the *framing sentence before the work*, which no
  executable path covers. A PR or issue status stated anywhere in this run — preamble included —
  comes from `bash "$HOME/.codex/scripts/lib/state-assert.sh" observe pr|issue <n>`, per
  `base/practices/verify-before-asserting.md`.
- **Brevity applies to success only.** A guardrail firing, a refused delete, a branch that could
  not be verified, anything skipped or left behind — all report in full, every run.

```
Deleted (local): issue-3-generic-release-workflow-or-document
Cleared state: threads-{41,47,51,57,59,65,68,72,76}.json, gaps.md, gaps.err, review.md, review.err
baseline: updated 3818548 → ebca0f3 (2 commits).
main: clean, in sync with origin/main
```

The `baseline:` line follows the same rule as every category above it — it appears only when
something actually happened. An install that was already current, a disabled updater, or a sweep of
the install-source clone itself all print nothing.

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
# (`local` never runs step 4) must still leave the report a defined, empty variable to work from.
#
# THIS WORKFLOW IS ONE SHELL. Every step below shares these accumulators across fenced blocks, so
# run them in a single shell session — a step executed in a fresh shell loses them and the final
# report silently degrades to blank lines rather than failing. (`/roadmap` is the opposite: its
# blocks are deliberately self-contained and re-resolve everything they need. Do not carry that
# habit here, or the reverse habit there.)
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
CSTATE="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" clone-state "$ROOT" "$DEFAULT")" || CSTATE=dirty
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
  if ! V="$(printf '%s' "$PRJSON" | bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" branch-verdict "$b" "$BASE")"; then
    NOTES="${NOTES}UNVERIFIED $b — could not be classified; preserved
"; continue
  fi
  # Three `read`s off a heredoc: no subshell, no process. Three `printf | sed -n Np` pipelines
  # would spend six processes per candidate to slice a string already in hand.
  { IFS= read -r VERDICT; IFS= read -r TIP; IFS= read -r DETAIL || DETAIL=""; } <<EOF2
$V
EOF2

  case "$VERDICT" in
    merged-ff|merged-pr)
      # ONE delete path for both proofs: an atomic compare-and-delete against the exact commit the
      # verdict was computed from. A commit landing on the branch mid-sweep makes this fail.
      #
      # `git branch -d` is deliberately NOT used for the fast-forward case: its refusal tests
      # merged-into-UPSTREAM (or HEAD), not merged-into-$BASE, so a branch that gained a pushed
      # commit after classification still passes it and is deleted carrying work that never
      # reached the default branch.
      if git update-ref -d "refs/heads/$b" "$TIP" 2>/dev/null; then
        # `update-ref -d` removes the ref and NOTHING else, where `git branch -d` also drops
        # branch.<name>.*. Left behind, a later branch of the same name silently inherits the old
        # upstream and pushes to it. `|| true` because a branch that never had config has no
        # section to remove, which is not an error.
        git config --remove-section "branch.$b" >/dev/null 2>&1 || true
        DELETED_LOCAL="${DELETED_LOCAL}$b
"
      else
        NOTES="${NOTES}REFUSED $b — it moved during the sweep; left in place
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

**A record's fields are the library's problem, not this loop's (#273).** The record format is
`<kind>TAB<path>TAB<key>`, parsed below with `read`, and a field carrying a raw tab or newline
would not corrupt a record — it would **forge** one, with an attacker-chosen `kind` that walks
straight past the `other` allowlist and reaches `rm -f`. `state-scan` now refuses to serialize
such a name and reports it as `unsafe` instead, so this step does **not** re-validate the paths it
reads: both snapshots come from that one producer, and a second copy of the rule here would be
duplicated logic that can drift out of agreement with it.

```bash
# ANCHORED AT $ROOT, never relative to the current directory. `/cleanup` is a repo-wide sweep and
# may be invoked from a subdirectory (base/practices/repo-scope.md: working dir != git root is a
# real, common shape). A relative path would miss the repo's actual state dir and, in a monorepo,
# could inspect a same-named directory under some package instead.
STATE="$ROOT/.codex/state"
TABC="$(printf '\t')"

# state-scan exits 2 — with NO stdout — when the state directory's OWN path cannot be serialized.
# Captured with an `if` rather than left to fall through, because the fallthrough is the silent
# one: an empty $SCAN sweeps nothing and looks exactly like a clean, already-empty state dir, and
# "reported success while doing nothing" is the #106 class this whole library exists to remove.
# The message deliberately does NOT interpolate $STATE — that path is the thing containing a
# newline, and pasting it into the report would move the injection into the operator's output.
if ! SCAN="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-scan "$STATE")"; then
  NOTES="${NOTES}REFUSED the state sweep — state-scan could not enumerate the state directory safely; no state was swept
"
  SCAN=""
fi

# Files state-scan declined to serialize. Reported HERE, in the first pass, and deliberately not
# in the second: the scan is re-taken before the destructive deletes below, so a record rendered
# from both snapshots would be reported twice for one file. The path field of an `unsafe` record
# is a `%q`-ENCODED rendering, not a usable path — it is safe to interpolate, and it must never be
# handed to `rm`, which is why no sweep arm below names this kind.
while IFS="$TABC" read -r kind sfile key; do
  [ "$kind" = unsafe ] || continue
  NOTES="${NOTES}SKIPPED $sfile — its name contains a tab or newline, so it cannot be classified safely; kept
"
done <<EOF
$SCAN
EOF

# The gap-analysis lock, if present, means an /implement-issue run is live and has NOT yet written
# its marker — it is that run's claim, taken in preflight (#202) and held until step 5, and a gap
# dispatch may be writing artifacts under it RIGHT NOW. Read it from the SCAN, not from a second
# hardcoded path: the library already recognises the filename, and a rename that updated only one
# of the two spellings would silently set LOCK=0 and delete a live dispatch's findings — the exact
# failure the lock exists to prevent.
# An `if`, not `… && LOCK=1`: an AND-list whose test fails leaves the whole fenced block on exit
# status 1, and "no lock present" is the overwhelmingly common case — so the agent would read a
# perfectly healthy sweep as a failed step and could abandon it before any state is swept.
LOCK=0
if printf '%s\n' "$SCAN" | grep -q "^lock${TABC}"; then LOCK=1; fi
```

**Markers first** — the gap artifacts' verdict depends on whether a run is live, and an
`/implement-issue` run is exactly what a marker describes.

The record field is read into `sfile`, **never `path`.** `path` is a zsh special variable bound to
`$PATH`: assigning a string to it empties the search path on the first iteration, and every
external command for the rest of the sweep — `bash`, `rm`, `git`, `gh` — is then not found. macOS
runs zsh by default (`base/practices/shell.md`), so that is the common case, and the symptom is
this skill's own worst failure mode: a sweep that deletes nothing and reports success. The same
applies to `fpath`, `cdpath`, `manpath`, `module_path`, `argv` and `status`;
`scripts/check-workflow-shell.sh` fails the build if any fenced block assigns one.

```bash
RUN=none
while IFS="$TABC" read -r kind sfile key; do
  [ "$kind" = marker ] || continue
  # Seed on FIRST sight: a marker exists, so this is a finished run until some marker says keep.
  # (A separate "did we see one" flag plus a trailing fixup is one fact tracked twice — and the
  # fixup is a compound test that leaves the whole block on a non-zero status.)
  [ "$RUN" = none ] && RUN=stale

  # The identity of the FILE as judged. Re-captured immediately before deletion below.
  IDENT="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" marker-identity "$sfile")"

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
    URL="$(jq -r '.prUrl // empty' "$sfile" 2>/dev/null || true)"
    [ -n "$URL" ] && PRSTATE="$(pr_state "$URL")"
  fi

  if ! MV="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict marker "$PRSTATE" "$LREF" "$RREF")"; then
    NOTES="${NOTES}SKIPPED ${sfile##*/} — could not be classified; kept
"; RUN=keep; continue
  fi
  [ "$MV" = keep ] && RUN=keep
  if [ "$MV" = stale ]; then
    # Re-capture the FILE IDENTITY at the moment of deletion. Comparing `.branch` alone is not
    # enough: a new /implement-issue run retrying the same issue writes the same deterministic
    # `issue-NN-slug`, so a replaced marker would compare equal and be deleted — disarming a live
    # run's continuation gate. An empty identity (unreadable) never matches, so it also keeps.
    NOW="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" marker-identity "$sfile")"
    if [ -n "$IDENT" ] && [ "$NOW" = "$IDENT" ] && rm -f "$sfile" 2>/dev/null; then
      CLEARED="${CLEARED}${sfile##*/}
"
    else
      NOTES="${NOTES}SKIPPED ${sfile##*/} — it changed during the sweep, or could not be removed; kept
"; RUN=keep
    fi
  fi
done <<EOF
$SCAN
EOF
```

**Then gap artifacts, the issue snapshot, review artifacts and thread caches.**

**Re-scan before deleting anything.** `$SCAN` and `$LOCK` were captured at the top of this step,
before a marker pass that makes live PR round trips — seconds, sometimes longer. A new
`/implement-issue` can take the lock and start writing the *same* gap filenames in that window,
and deleting from the old snapshot would remove files a locked dispatch is actively writing. The
lock that governs a destructive delete must be the one that is true *at the delete*.

**Review artifacts have no lock, and need none (#264).** `/implement-issue` writes them in its
step 8 — *after* step 5 has written the run marker, and while the run's branch still exists — so
the window the gap lock exists for (step 3, before any marker) has no counterpart here. Within the
**one-active-run-per-checkout** boundary `/implement-issue` already declares, the marker is the
in-flight signal for every review write.

**That boundary is now ENFORCED rather than merely declared (#202).** It used to be a promise the
code did not keep: a second run's preflight cleared the fixed marker paths unconditionally, so it
could delete a live run's marker, after which the still-running first run reached step 8 with no
marker and this sweep classified its live artifacts `stale`. `/implement-issue`'s preflight now
asks `implement-lib.sh admit` first, and a second run in the same checkout is **refused** — it
deletes nothing. So the marker really is the in-flight signal for every review write this arm can
see, and a review lock would still buy nothing: the gap lock is held from preflight to step 5 as
the run's *claim*, covering the one window a marker cannot, and a second lock beside it could only
leak and disagree.

**But it is read from THIS scan, never from `$RUN`.** The rule above is not about locks
specifically; it is that the signal governing a destructive delete must be true *at the delete*,
and `$RUN` was decided before the marker pass. Any `marker` record still present in the fresh scan
is one this sweep just kept — or one a run created since it started; both mean a run owns these
files. In every non-race case that is the same answer `$RUN` gives (the pass deletes exactly the
markers it proved stale, and a delete that fails or finds a changed file forces `RUN=keep`), and in
a race it is the safe one.

**And a pathname is not an identity, so every arm that deletes carries the discipline the `marker`
arm already has (#305).** A verdict is reached for a *record*, and the record holds a path — but a
fresh `/implement-issue` preflight clears the previous run's artifacts and writes its own at those
same fixed names, so a path judged stale can be occupied by a live run's file by the time `rm`
reaches it. That window is not instantaneous: the delete loop makes a **live `pr_state` round trip
per `threads` record**, so a later record's deletion can be seconds behind the scan that judged it.
Reproduced against this very block before the fix: a swept `issue-<n>.json` was the one a live run
had just written.

**A content digest cannot see it, which is why this is `file-identity` and not `marker-identity`.**
The replacement here is routinely *byte-identical* — `gh issue view` returns the same JSON for an
unchanged issue, an `.assoc` holds one word, and `gap-prompt.txt` is rebuilt deterministically from
both — so a digest compares equal and the file is deleted anyway. `file-identity` asks whether this
is the same **file**, not the same bytes. The marker arm keeps its digest deliberately: a replaced
marker always differs in content, and `implement-lib.sh` derives the very same value from a *single*
read of the claim's bytes for a race of its own.

**Captured with the re-scan, before anything else runs.** The identity of a file judged at the scan
has to be fingerprinted while the scan is still the truth — capturing it later fingerprints whatever
arrived in the meantime, so the delete-time comparison compares a replacement against itself and
always matches. So it is taken immediately after the re-scan, ahead of the three verdict calls and
the whole delete loop, and the records that carry it are a *derived* set: `state-scan`'s record
format is unchanged, because three other loops in this step read it with three variables and a
fourth field would silently land in `$key`.

**What this does NOT claim.** Two syscalls still separate the re-capture from the `rm`, exactly as
in the marker arm above. Closing that would mean moving the file aside and verifying the operand —
what `implement-lib.sh` does to break a *claim* — and that trade is wrong here: it unlinks, however
briefly, a file we have just decided belongs to somebody else and may be reading, and a crash mid-way
strands a sidecar `state-scan` classifies `other` and therefore never sweeps. Nor is `state-scan` an
atomic snapshot: its glob expands before its per-file loop, so a run that arrives *entirely* between
that expansion and the identity capture is outside what this closes. That case needs a network round
trip to fit inside a filesystem walk, and if the run had started any earlier its claim would be in
this same scan — where `LOCK=1` keeps every artifact regardless.

```bash
# ADB-SNIPPET: state-sweep
# Status-checked exactly like the first scan, and this is the snapshot that actually drives `rm`.
# The library's deliberate failure path emits nothing before it dies, so an unchecked capture is
# safe *by implementation* rather than *by contract* — but command substitution KEEPS partial
# stdout on a non-zero exit, so a future mid-enumeration error would hand half a snapshot straight
# to the delete loop. Fail closed structurally instead of relying on that staying true.
if ! SCAN="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-scan "$STATE")"; then
  NOTES="${NOTES}REFUSED the state deletes — the pre-delete re-scan could not enumerate the state directory safely; nothing was swept
"
  SCAN=""
fi

# THE IDENTITY OF EVERY DELETABLE FILE, AS JUDGED — captured HERE, immediately after the re-scan and
# before anything else in this step runs (#305). Not inside the delete loop: by then the three
# verdict calls and every earlier record's `pr_state` round trip have already happened, and a
# fingerprint taken after a replacement lands describes the replacement, so the comparison below
# would compare it against itself and match. This is the same "capture FIRST, before the reads that
# take time" ordering the marker pass and `implement-lib.sh admit` both use, and both learned the
# hard way.
#
# A DERIVED record set, so `state-scan`'s own `<kind>TAB<path>TAB<key>` format is untouched. Three
# other loops in this step parse it with three variables, and `read` puts every surplus field in the
# LAST one — a fourth field emitted by the scan would arrive silently inside `$key`, which is a
# marker's branch name and a thread cache's PR number.
#
# Only the kinds this step deletes are carried. `marker` is absent because the marker pass above has
# already run its own identity guard, `lock` and `other` because nothing here removes them, and
# `unsafe` because its path field is an ENCODED rendering that must never reach a filesystem call.
DELSET="$(while IFS="$TABC" read -r kind sfile key; do
  case "$kind" in
    gaps|issue|review|threads) : ;;
    *) continue ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$kind" "$sfile" "$key" "$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" file-identity "$sfile")"
done <<EOF
$SCAN
EOF
)"

LOCK=0
if printf '%s\n' "$SCAN" | grep -q "^lock${TABC}"; then LOCK=1; fi
# An `if`, not `… && RUN_NOW=keep`, for the reason given above the lock probe: an AND-list whose
# test fails leaves the whole fenced block on exit status 1, and "no marker present" is the
# common case after a merge — the sweep would read as a failed step.
RUN_NOW=none
if printf '%s\n' "$SCAN" | grep -q "^marker${TABC}"; then RUN_NOW=keep; fi

GV="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict gaps "$LOCK" "$RUN")" || GV=keep
# The issue snapshot (#250) takes the SAME two facts as the gap artifacts, and the library answers
# both from one predicate — /implement-issue step 2 writes it before any marker exists, under the
# claim, and step 8 still reads it after the marker has taken over. Asked under its own kind name
# so this loop never appears to be consulting a gap verdict about a file that is not a gap artifact.
#
# BUT IT IS ASKED WITH `$RUN_NOW`, NOT `$RUN` — gaps' predicate, review's freshness, and the split
# is the point. `$RUN` was decided during the marker pass, before live PR round trips; `$RUN_NOW`
# comes from the re-scan two lines up. For gap artifacts the difference cannot bite: nothing reads
# them after step 4, so the claim covers their whole live window. The snapshot is read again in
# step 8, exactly like the review artifacts — so a run that reached step 5 between the marker pass
# and this delete has a marker in the FRESH scan and a stale answer in `$RUN`, and passing the
# stale one would sweep a live run's issue text out from under its own review dispatch.
IV="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict issue "$LOCK" "$RUN_NOW")" || IV=keep
RV="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict review "$RUN_NOW")" || RV=keep

# sweep_file <path> <identity-as-judged> — delete ONE file, but only if it is still the file the
# verdict was about (#305).
#
# TWO OUTCOMES THAT ARE NOT THE SAME THING, and collapsing them would hide the one that matters:
#   SKIPPED … kept              the file changed, vanished, or has no readable identity. Nothing was
#                               attempted; it belongs to somebody else now.
#   REFUSED … left in place     the file IS the judged one and `rm` failed anyway — a read-only
#                               state dir. rm failures are REPORTED, never swallowed, or a sweep
#                               that removed nothing would show a clean, successful no-op.
#
# EVERY unknown keeps, exactly as `state-verdict` does. An empty judged identity (the scan could not
# fingerprint it) and an empty current one (it is gone, or unreadable now) both fail the comparison,
# so neither can be mistaken for a match — an identity that cannot be established is not an identity
# that agrees.
sweep_file() {
  local now
  now="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" file-identity "$1")"
  if [ -z "$2" ] || [ -z "$now" ] || [ "$now" != "$2" ]; then
    NOTES="${NOTES}SKIPPED ${1##*/} — it is no longer the file that was judged; kept
"
    return 0
  fi
  if rm -f "$1" 2>/dev/null && [ ! -e "$1" ]; then
    CLEARED="${CLEARED}${1##*/}
"
  else
    NOTES="${NOTES}REFUSED ${1##*/} — could not be removed (state dir not writable?); left in place
"
  fi
}

# `$DELSET`, not `$SCAN`: the fourth field is the identity captured with the re-scan, and it is the
# only thing standing between a stale verdict and a live run's file.
while IFS="$TABC" read -r kind sfile key ident; do
  case "$kind" in
    gaps)
      [ "$GV" = stale ] || continue
      sweep_file "$sfile" "$ident"
      ;;
    issue)
      [ "$IV" = stale ] || continue
      sweep_file "$sfile" "$ident"
      ;;
    review)
      [ "$RV" = stale ] || continue
      sweep_file "$sfile" "$ident"
      ;;
    threads)
      TV="$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict threads "$(pr_state "$key")")" || continue
      [ "$TV" = stale ] || continue
      sweep_file "$sfile" "$ident"
      ;;
  esac
done <<EOF
$DELSET
EOF
```

A kept captured stream that has grown large is **reported, not truncated** — truncating a live
run's stream destroys the evidence its operator is about to read. This covers the **review**
stream too (#264): `review.err` captures a reviewer's whole exploration, and the run #264 recorded
left one of 389 KB, so a threshold that never looked at it was a warning the operator could not
get for a file that had already crossed it.

Each family is gated on **its own** verdict. `$RV` is not `$GV` — a live gap dispatch and a live
review dispatch are different runs at different steps, and reporting one family under the other's
liveness would name the wrong file as belonging to a live run.

```bash
# The paths come from the SCAN, never from a second set of globs spelled here. That is the rule
# the lock probe already follows — one home per filename, so a rename cannot update only one
# spelling — and it removes a portability trap in the same move: an unmatched `gaps-*.err` is left
# literal by POSIX shells, but under zsh's default `nomatch` it ABORTS the command, and macOS runs
# zsh (base/practices/shell.md). The whole report would then silently not happen.
#
# An `if`, not a trailing AND-list, so a healthy run — every stream under the threshold — does not
# leave this block, the LAST of the step, on exit status 1.
while IFS="$TABC" read -r kind sfile key; do
  case "$kind" in
    gaps)   [ "$GV" = keep ] || continue ;;
    review) [ "$RV" = keep ] || continue ;;
    *)      continue ;;
  esac
  case "$sfile" in *.err) : ;; *) continue ;; esac
  sz="$(wc -c < "$sfile" 2>/dev/null | tr -d ' ')"
  if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
    NOTES="${NOTES}LARGE ${sfile##*/} is $((sz / 1024)) KB and belongs to a live run — kept
"
  fi
done <<EOF
$SCAN
EOF
```

### 6. Compose the report — but do not print it yet

Loud lines first (they are the exception), then one line per category that changed, then the
state line. Categories with nothing in them cannot appear — `report` builds lines from records,
so there is no empty section to suppress.

**Buffer it into a variable instead of printing.** This is the LAST step that calls
`bash "$HOME/.codex/scripts/lib/cleanup-lib.sh"`, and step 7 may replace that very library on disk (it re-runs the installer,
whose symlinks are what `bash "$HOME/.codex/scripts/lib/cleanup-lib.sh"` resolves through). Composing the report first means the
whole sweep is reported by the library version that decided it — an old workflow calling a
freshly-swapped library is a version skew with no upside.

```bash
emit() { printf '%s\n' "$2" | while IFS= read -r x; do [ -n "$x" ] && printf '%s\t%s\n' "$1" "$x"; done; }

REPORT_OUT="$({
  emit 'Deleted (local)'  "$DELETED_LOCAL"
  emit 'Deleted (remote)' "$DELETED_REMOTE"
  emit 'Cleared state'    "$CLEARED"
} | bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" report --tail "$(bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-line "$ROOT" "$DEFAULT")")"
```

### 7. Keep the installed baseline current (issue #139)

The sweep is done, so this is the last action of the run — and the right place for it. `/cleanup`
runs **immediately after a merge**, which is the moment the installed baseline goes stale, and it
sits **immediately before `/clear`**, which is the step that cannot re-check: currency's other
trigger is a `SessionStart` hook matched on `startup` only, so the loop
`merge → /cleanup → /clear → /roadmap` never re-checked before this existed. Staleness began at
the merge and nothing in the loop noticed. That is not hypothetical — a `/roadmap` run computed a
release verdict with pre-fix logic one commit after the fix shipped, and a later one derived
dependency edges from a two-commit-stale predicate.

Every decision is `bash "$HOME/.codex/scripts/lib/currency-lib.sh"`'s: the mode (`[updates] session_start` in the global
`agents.toml`, or `ADB_SESSION_UPDATE`; `off` disables this too), the install-source, the
self-clone guard, the rate limit, git's network bounds, and a wall-clock backstop on the update
itself. This step only decides what to SHOW — which differs from the `SessionStart` hook's choice
on purpose: the hook stays silent about a peer update or a missing network because it fires
unattended, whereas here the operator just asked, so `busy` and `offline` are reported.

```bash
# ADB-SNIPPET: currency
# This block needs NO input from the steps above — but it does export `CU_LINE` to step 8, exactly
# as step 1 exports `NOTES` and step 3 exports `DELETED_LOCAL`. Run this whole workflow as ONE
# shell: its accumulators have been shared across fenced blocks since step 1, and a step run in a
# fresh shell would silently lose them (`/roadmap` is the skill whose blocks are separable — this
# one is not, and the difference is deliberate).
#
# It does not resolve the repo root: the library defaults its own `--cwd` to $PWD and compares git
# COMMON DIRS, so it recognises the install-source clone from any subdirectory of it. Resolving a
# toplevel here would just normalize that case away before the guard ever saw it.
# `|| true` is load-bearing, twice over. Currency is housekeeping, never a gate: an unreachable
# remote, a refused update, or a missing install must leave the sweep successful. And these fenced
# blocks are executed by an AGENT — a block whose LAST command exits non-zero reads as a failed
# step and can abandon the run before the report is ever printed (the same trap the `LOCK=0`
# comment in step 5 names). The library already exits 0 for every policy outcome; this is the
# belt-and-braces that keeps a broken install from ending the sweep.
CU_RECORD="$(bash "$HOME/.codex/scripts/lib/currency-lib.sh" check --trigger cleanup 2>/dev/null || true)"
# Split on the FIRST whitespace run, never on a literal TAB. The outcome is a single word by
# contract, so `read` gives it to $CU_OUTCOME and every remaining byte to $CU_MESSAGE. That keeps
# no invisible character load-bearing inside a fenced block — a tab silently converted to spaces
# by an editor would otherwise break the parse with no error anywhere.
{ read -r CU_OUTCOME CU_MESSAGE || true; } <<CU_EOF
$CU_RECORD
CU_EOF

# One line, and only when there is something to say. Every outcome that is worth reporting carries
# a message and every outcome that is not (`silent`, `skipped` — already current, mode=off,
# sweeping the install-source clone itself, nothing installed) carries an EMPTY one, by contract.
# So this keys on the message, not on a per-outcome list: nine arms that mostly said the same thing
# were nine chances to forget one when the vocabulary grows.
#
# `case`, not `[ -n … ]`: a fenced block whose LAST command exits non-zero reads to an agent as a
# failed step and would abandon the sweep right before the report. `esac` always exits 0.
CU_LINE=""
case "$CU_MESSAGE" in ?*) CU_LINE="baseline: $CU_MESSAGE" ;; esac
```

An `updated` line means the tooling under `~/.<agent>/` changed **during this run**. That is safe
here precisely because step 6 already composed the report, and it is worth the operator seeing:
the next skill they invoke is the new one. Note that a project's *composed* skills (a partial
override merged onto a base skill) are not recomposed by an update — that is tracked separately
in #64.

### 8. Emit

```bash
[ -n "$NOTES" ] && printf '%s' "$NOTES"
[ -n "$CU_LINE" ] && printf '%s\n' "$CU_LINE"
printf '%s\n' "$REPORT_OUT"
```

The repository-state line stays **last**, where the terse contract puts it: currency is reported
above it, in the same slot as the swept categories.

Under `verbose`, additionally state what was examined and preserved: the candidate count, how
many were classified `unmerged`, and whether the fetch changed any verdict. Never by default.

## Notes

- This never runs `git branch -D`, `push --force`, or `clean -fd`. Unmerged branches are always
  preserved; unclassifiable run-state is always kept.
- Run it after a merge, or periodically. It is idempotent — a second run finds nothing new and
  prints only the state line. The currency check is idempotent in the same sense: once the install
  is current it reports nothing, though a second sweep *does* re-check (an explicitly requested
  check is never suppressed by the rate limit — see `bash "$HOME/.codex/scripts/lib/currency-lib.sh"`).
- **First deployment cannot bootstrap itself.** The installed `/cleanup` is a symlink into the
  install-source clone, so the sweep you run immediately after this change lands is still the OLD
  one, without a currency step. Run `baseline update` by hand once; every sweep after that carries
  it.
- The remote half is enumerated with `--merged` alone on purpose (see step 4). Only the **local**
  half needs PR evidence, because only local refs survive a squash merge.
