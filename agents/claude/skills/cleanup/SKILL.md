---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/cleanup.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
name: cleanup
description: Sweep ALL merged branches (local and, on confirmation, remote) plus resolved run-state, not just the current task's branch. Detects squash/rebase merges, which `--merged` alone can never see. Names each branch explicitly so command-safety gating never blocks the delete. Never touches unmerged or protected branches, or state for a live run.
argument-hint: [local | remote | all] [verbose]  (default: local)
allowed-tools: Bash, Read
user-invocable: true
---

# /cleanup

Sweep what a finished task leaves behind, then leave the tooling current. Two kinds of debris and
one currency check, one command:

- **Merged branches** — local and, on confirmation, remote. The failure mode this exists to
  prevent is deleting only the *current* task's branch and leaving dozens of stale merged
  branches behind, and being **blocked** by command-safety gating because a "clean up"-style
  instruction never named a branch. This sweeps **everything already merged** and **names each
  branch explicitly**.
- **Resolved run-state** — the gitignored scratch a skill run leaves in `.claude/state`: thread
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
- **Every delete is a compare-and-delete against the tip its own proof was computed from.**
  Locally that is `git update-ref -d refs/heads/<b> <the tip the verdict was computed from>`; on
  the remote it is `git push origin --force-with-lease=refs/heads/<b>:<the tip the enumeration
  proved> --delete refs/heads/<b>` (#346). Both remove the ref only if it still points exactly
  there, so a commit landing mid-sweep makes the delete fail loudly instead of destroying it.
  **`--force-with-lease` here is the lease, not a force-push**: it rewrites no history and moves
  no ref forward — it is the only way `git push` will refuse a delete whose target has moved, and
  it makes this half strictly safer than the by-name delete it replaces. The confirmation
  `base/practices/git-and-prs.md` requires before a remote delete is unchanged and still comes
  first.
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
- **An OPEN PR is closed only for a branch this sweep DELETED, and only at the proved tip** (#346).
  Local ancestry can prove a branch merged while its own PR stays open — folded into another PR,
  rebased on, or pushed straight to the default branch — and deleting the branch removes the
  dangling ref that would have prompted a human. So the delete carries the close. It is gated on
  the PR's `headRefOid` still equalling the tip the verdict was computed from: anything else is a
  refusal reported in full, never a close. An unmerged branch's PR is live work and is never
  touched. Only GitHub-assigned fields are read — the PR body is third-party text
  (`base/practices/untrusted-content.md`) and never reaches a decision. **Autonomous, with no
  confirmation**, and the asymmetry with the remote-delete rule above is deliberate: what earns a
  confirmation there is that a by-name delete could destroy something nobody proved. The OID gate
  removes exactly that possibility here, so this sits in the same safety class as the local delete —
  which is also autonomous — and it is reversible besides, where a delete is not.
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
  comes from `bash "$HOME/.claude/scripts/lib/state-assert.sh" observe pr|issue <n>`, per
  `base/practices/verify-before-asserting.md`.
- **Brevity applies to success only.** A guardrail firing, a refused delete, a branch that could
  not be verified, anything skipped or left behind — all report in full, every run.
- **Every delete states the evidence it was computed from** (#332). A successful delete is the
  loudest, least reversible thing this skill does, and it used to be the one outcome with no
  evidence attached — `Deleted (local): fix/371` read identically whether the sweep was correct or
  catastrophic. The proof rides *inside* the category line as a trailing `[…]`, so the line budget
  above is unchanged.
- **Every outward mutation the sweep causes is a category of its own** (#346). Closing a PR is not
  a delete, and burying it inside `Deleted (local)` would hide the one action here that touches
  something other people can see. It carries the same proof the delete did.
- **A run marker the sweep OBSERVED is never silent** (#350). It appears under `Cleared state` if
  this sweep removed it, and under `Run marker` if it is still there — kept because a run is in
  flight, or kept because nothing recognised it as a marker at all. The third state is the one that
  used to render identically to "no marker exists", and it is the dangerous one: `RUN_NOW` reads
  `none`, so a **live** run's artifacts become sweepable. **Absence is still silent** — the terse
  contract forbids a `Run marker: none` on every sweep, and absence is the common case in the
  documented loop, where the Stop-hook gate has already cleared the marker before `/cleanup` runs.

```
Deleted (local): fix/371-contact-bundle [#379 (merge commit 3f9e9e5abcde)], feat/x [contained in origin/main]
PR closed: 380 [head matched the proved tip 3f9e9e5abcde]
Cleared state: threads-{41,47,51,57,59,65,68,72,76}.json [PR merged], gaps.md [no run in flight], gaps.err [no run in flight]
baseline: updated 3818548 → ebca0f3 (2 commits).
main: clean, in sync with origin/main
```

A sweep that found a marker nothing recognised adds the one line that used to be missing:

```
Run marker: implement-issue-active.json [UNRECOGNISED — scanned as 'other', so this sweep detected no run in flight]
```

The `baseline:` line follows the same rule as every category above it — it appears only when
something actually happened. An install that was already current, a disabled updater, or a sweep of
the install-source clone itself all print nothing.

### Where the evidence goes, and why not the other two places

#332 named three candidate channels and deliberately did not choose. The choice is **the default
per-category line**, and the other two are ruled out by rules already stated above rather than by
taste:

- **Not `NOTES`.** That is the *exception* channel — `SKIPPED`, `REFUSED`, `UNVERIFIED`, `LARGE` —
  and it prints in full precisely because everything in it is unusual. Routing a routine success
  through it costs one line per deleted branch (past the ≤3-line target on any real sweep) and,
  worse, trains the reader to skim the one channel whose value is that it is rare.
- **Not `verbose` only.** That leaves the default sweep exactly as unauditable as the run #332
  reported, which is the thing being fixed. `verbose` keeps its own separate subject — what was
  *examined and preserved* — and is unchanged by this.
- **So: a third field on the report record**, `<category>TAB<item>TAB<proof>`, rendered by
  `bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" report`. A record with no third field renders exactly as it did before, so
  every other caller and every existing assertion is untouched.

**The proof joins the brace-group key**, which is what stops the state line exploding: files swept
for the same reason still collapse under one bracket, and files swept for *different* reasons split
into their own groups instead of having the first one's proof printed over all of them.

**Two wording constraints, both load-bearing and both verified against the linter before they were
written:**

- **Never a `#N` beside a status word.** `bash "$HOME/.claude/scripts/lib/state-assert.sh" lint` rejects that shape unless it is
  introduced by `was observed`, and **one `Deleted (local)` line legitimately carries both halves at
  once**: a squash-merged branch contributes the `#N`, and a fast-forward branch sharing that line
  would contribute the status word. So a fast-forward's proof is *contained in*, never *merged
  into* — a wording that only violates when both verdicts appear in the same sweep, which is
  exactly when nobody is looking for it.

  A thread cache's proof avoids the number for the same rule read the other way round: `PR merged`
  is clean on its own, `PR #41 merged` is a violation by itself. (Report categories are one
  physical line each, so a `Cleared state` proof and a `Deleted (local)` proof can never collide
  with each other — an earlier draft of this paragraph claimed they could, and that was wrong. The
  constraint is real; it just lives *within* a category, not across two.)
- **The proof is the value the verdict returned or consumed**, carried from that call — never
  re-read when the report is composed. A second read is a different moment, and for the local half
  it is not even answerable: the branch is gone by then. Re-introducing that gap would reinstate
  exactly the staleness that makes a report untrustworthy.

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
NOTES=""; DELETED_LOCAL=""; DELETED_REMOTE=""; CLEARED=""; PR_CLOSED=""; RUNMARK=""
# The report record's field separator, defined ONCE and here — the delete accumulators above
# now carry `<item><TAB><proof>` pairs (#332) and step 5 parses `state-scan` records with the same
# character, so a second spelling later in the file would be one constant with two homes. Never a
# literal tab in a fenced block: it is invisible in the source, in the render and in review, and an
# editor that turned it into spaces would silently fold each delete's proof into the item's name.
#
# `$TABC` reaches one more place since #346: the remote enumeration now carries `<name><TAB><oid>`
# per line, because the tip that authorises a remote delete has to be captured BY the enumeration
# that proves it. Same constant, same reason — a second spelling would be a second home.
TABC="$(printf '\t')"
git fetch --prune origin --quiet 2>/dev/null \
  || NOTES="${NOTES}NOTE: could not fetch origin — classifying against possibly-stale refs.
"
```

Return to a clean, current default branch — **guarded on the clone's own safety state**, so we
never switch or pull over work in progress. A clean `git status` is *not* that guard: a rebase
between steps, a `git bisect`, or an interrupted cherry-pick all leave the tree clean, and
switching away from one corrupts it. On anything unsafe, skip the return and sweep in place:

```bash
CSTATE="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" clone-state "$ROOT" "$DEFAULT")" || CSTATE=dirty
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
# ADB-SNIPPET: branch-sweep
# THE PROOF THIS LOOP COMPUTES IS THE PROOF IT REPORTS (#332). `branch-verdict` returns the
# evidence that authorised each delete; before this it was read into `$DETAIL` and used in exactly
# one place — the `unverified` arm — so every successful delete threw it away. `Deleted (local):
# fix/371` then read identically whether the sweep was correct or catastrophic, and the only
# defence left was an agent choosing to re-derive by hand what this loop already knew (twice in one
# session, in two repos, both times confirming the sweep was right).
#
# CARRIED, NEVER RE-QUERIED. The value appended below is the string THIS `branch-verdict` call
# returned. Asking again at report time would read a different moment — and by then the branch is
# deleted, so the question is no longer answerable at all.
#
# GH_REPO IS NEUTRALIZED UP FRONT, because every proof this loop computes — ancestry, $TIP
# containment in origin/$DEFAULT — is anchored to THIS checkout, so every gh read and mutation
# below must be anchored to the same repository. A live GH_REPO redirects them all to whatever
# repository it names (`gh help environment`): a fork sharing this commit and branch name could
# have ITS open PR closed on this checkout's proof. The hazard and its git-anchored resolution
# are recorded on `adb_git_repo_slugs` in scripts/lib/common.sh; here the redirect is simply
# removed — unset, gh resolves the repository from this checkout's own git remotes, the same
# anchor the proofs already stand on.
unset GH_REPO
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
  if ! V="$(printf '%s' "$PRJSON" | bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" branch-verdict "$b" "$BASE")"; then
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
        # THE PROOF, recorded ONLY after the delete actually succeeded — the `else` arm below is a
        # branch that still exists, and attaching evidence to it would assert a deletion that did
        # not happen.
        #
        # THE TWO VERDICTS ARE NOT SYMMETRIC. `merged-pr` carries its evidence in line 3, so that
        # string is passed through verbatim; `merged-ff` emits NO line 3 at all, because there its
        # proof IS the verdict word — the tip is contained in $BASE. Rendering it here, rather than
        # teaching the library to emit a detail line, is what #332 asks for and keeps
        # `branch-verdict`'s contract untouched.
        #
        # "contained in", NEVER "merged into", and that is a HARD constraint rather than a
        # preference. `state-assert.sh lint` flags a status word (`merged` is one) sharing a
        # sentence with a `#N` — and this category's line routinely holds both, because a
        # squash-merged sibling's proof is `#379 (merge commit …)`. The natural wording makes the
        # whole report line a claim-grammar violation that only fires when BOTH verdicts appear in
        # one sweep. Verified against the linter, both spellings, before it was written.
        # BOTH verdicts named EXPLICITLY, with the catch-all printing the bare verdict word. The
        # outer `case` admits only these two today, so `*)` is unreachable — but a third word
        # joining that label later would silently inherit whichever proof the fallback spelled,
        # and "contained in origin/main" asserted about a verdict that never proved containment is
        # a false statement about why a branch was deleted. Printing the unrecognised word is the
        # same move `state-line` makes for a clone state it has not learned: say what you have,
        # never invent a reassuring sentence for a condition nobody has classified.
        case "$VERDICT" in
          merged-pr) PROOF="$DETAIL" ;;
          merged-ff) PROOF="contained in $BASE" ;;
          *)         PROOF="$VERDICT" ;;
        esac
        # `$TABC`, never a literal tab. The report record's field separator has to survive an
        # editor, a copy-paste and three skill renders; a raw tab pasted into a fenced block is
        # load-bearing punctuation that is invisible in every one of them, and a silent conversion
        # to spaces would fold the proof into the branch NAME with no error anywhere. The currency
        # step already refuses to depend on one for the same reason.
        DELETED_LOCAL="${DELETED_LOCAL}${b}${TABC}${PROOF}
"
        # --- #346(b): the branch is gone; its OPEN PR must not outlive it ---------------------
        # `branch-verdict` proves containment from LOCAL ANCESTRY and never reads PR state, so a
        # branch can be provably merged with its own PR still open: folded into another PR that
        # merged, rebased or fast-forwarded onto the default branch, or pushed there directly. The
        # PR then never closes on its own, and the dangling branch that would have prompted a human
        # is exactly what the line above just removed.
        #
        # GATED ON THE PROVED TIP, which is what puts this in the same safety class as the delete
        # and is why it needs no confirmation. `$TIP` is the commit `branch-verdict` computed its
        # verdict from; a PR whose head is anything else describes work this sweep did not prove,
        # so it is a REFUSAL reported in full, never a close. Multiple open PRs on one head (a
        # reopen, a duplicate) are each judged independently under the same test.
        #
        # ONLY `number` AND `headRefOid` ARE READ — both GitHub-assigned. The PR body, title and
        # comments are third-party text (`base/practices/untrusted-content.md`): they are never
        # read here, so nothing a stranger can write reaches a decision or the report.
        #
        # THE COMMENT CARRIES THE PROOF ALREADY IN HAND — `$PROOF` and `$TIP`, from the verdict
        # above — never a second query. That is #332's discipline applied to an outward mutation:
        # the durable record on the PR must be the evidence that actually authorised the delete.
        if [ "$HAVE_GH" -eq 1 ]; then
          # A FRESH read at the moment of the mutation (`base/practices/verify-before-asserting.md`).
          # Nothing earlier in this sweep looked at open PRs, and a status captured at the top of a
          # long run is not the status that gates a close.
          # `</dev/null` ON EVERY gh CALL IN THIS ARM, and it is load-bearing rather than tidy.
          # This arm runs INSIDE the candidate loop, whose stdin is the `$CANDIDATES` heredoc at
          # the bottom of this block. A child that read stdin would swallow the rest of that list
          # and the sweep would quietly process one branch and stop — a silent partial sweep,
          # which is the #106 failure class this whole library exists to remove. None of these
          # calls reads stdin today; the redirect is what keeps that from being a fact this loop
          # depends on without saying so. It also stops any auth prompt from hanging the sweep.
          #
          # `--base "$DEFAULT"`, because the proof is SCOPED TO THE BASE. $TIP's containment was
          # proved against origin/$DEFAULT and says nothing about any other base — a same-head PR
          # targeting a release or maintenance branch is live backport work this sweep never
          # judged, so the filter keeps it out of reach entirely.
          #
          # THE LIMIT IS A HARD CAP, not a page size: `gh pr list` silently drops whatever lies
          # beyond it. Checked for saturation below — a list AT the cap may be a subset, and
          # closing from a subset leaves the invisible remainder dangling in silence, which is
          # the defect this arm exists to remove.
          OPENPR_LIMIT=100
          if OPENPRS="$(gh pr list --head "$b" --base "$DEFAULT" --state open \
                          --limit "$OPENPR_LIMIT" \
                          --json number,headRefOid --jq '.[] | "\(.number) \(.headRefOid)"' \
                          2>/dev/null </dev/null)"; then
            OPENPR_N="$(printf '%s' "$OPENPRS" | grep -c .)"
            if [ "$OPENPR_N" -ge "$OPENPR_LIMIT" ]; then
              # Loud, and it stands the whole head down: blanking the list is what makes the loop
              # below close NOTHING for this head. Naming the count and the cap is what lets the
              # operator see the saturation instead of a confident subset.
              NOTES="${NOTES}REFUSED closing any PR for $b — the open-PR list returned $OPENPR_N results at its cap of $OPENPR_LIMIT and may be truncated; every PR left for the operator
"
              OPENPRS=""
            fi
            # Fed by a heredoc for the reason the remote loop states: a piped `while` runs in a
            # subshell and every PR_CLOSED append would be discarded.
            while IFS=' ' read -r PRNUM PRHEAD; do
              [ -n "$PRNUM" ] || continue
              if [ "$PRHEAD" != "$TIP" ]; then
                # Loud, and it names the PR. Its head moved after the verdict, so the content this
                # sweep proved is not the content the PR now carries.
                NOTES="${NOTES}REFUSED closing PR $PRNUM for $b — its head is not the tip this sweep proved; left alone
"
                continue
              fi
              # `--comment`, so the proof is durable on the PR itself rather than only in a report
              # that scrolls away. Written WITHOUT a `#<n>` and with NO BACKTICK: the first is the
              # claim grammar (`state-assert.sh lint` rejects a status word sharing a sentence with
              # an entity reference, and this sentence is about a PR being closed); the second is
              # this fence — a backtick inside a double-quoted string is command substitution, and
              # an escape that survives three skill renders intact is not a thing worth betting a
              # remote mutation on.
              if gh pr close "$PRNUM" \
                   --comment "Closed by /cleanup: branch $b was deleted after its content was proved $PROOF (tip $TIP)." \
                   >/dev/null 2>&1 </dev/null; then
                # THE PROOF IS THE GATE THIS CLOSE PASSED, not the delete's evidence — and that
                # is a claim-grammar constraint, discovered by the executed case rather than
                # reasoned about. `PR closed` is a category name containing a STATUS WORD, and a
                # `merged-pr` verdict's evidence is `#<n> (merge commit <oid>)`: rendering it here
                # puts a status word and an entity reference in one sentence, which
                # `state-assert.sh lint` rejects — and only on sweeps where a squash-merged branch
                # also had an open PR, i.e. exactly when nobody is looking. It costs the report
                # nothing: the delete's own evidence is on the `Deleted (local)` line directly
                # above, and the full proof (`$PROOF`, `#<n>` and all) is on the PR comment, which
                # is durable and is not a report line. What belongs HERE is why THIS PR was closed,
                # which is the OID test. Carried, never re-read: `$TIP` is line 2 of the verdict.
                #
                # THE CLOSE IS COMPENSATED, BECAUSE IT CANNOT BE LEASED. `gh pr close` takes no
                # expected-head option (unlike the delete above, which leases on $TIP), so a push
                # landing between the fresh read and the close wins that race undetected. The
                # window cannot be removed, so it is made explicit and compensated: re-read the
                # head AFTER the close, and if it is no longer the proved $TIP, reopen and say so
                # loudly. An unreadable post-close head takes the same arm — fail closed, never
                # "probably fine". A mismatched close is NEVER left standing silently, and never
                # recorded under PR closed.
                POSTHEAD="$(gh pr view "$PRNUM" --json headRefOid --jq .headRefOid \
                              2>/dev/null </dev/null)"
                if [ "$POSTHEAD" = "$TIP" ]; then
                  PR_CLOSED="${PR_CLOSED}${PRNUM}${TABC}head matched the proved tip ${TIP}
"
                else
                  # No backtick and no # before a number, for the same two fences the close
                  # comment states.
                  if gh pr reopen "$PRNUM" \
                       --comment "Reopened by /cleanup: after the close, this PR's head read back as ${POSTHEAD:-unreadable}, not the proved tip $TIP. The close judged content the sweep never proved." \
                       >/dev/null 2>&1 </dev/null; then
                    NOTES="${NOTES}REOPENED PR $PRNUM for $b — after the close its head read back as ${POSTHEAD:-unreadable}, not the proved tip $TIP
"
                  else
                    NOTES="${NOTES}ATTENTION PR $PRNUM for $b — closed with head ${POSTHEAD:-unreadable} instead of the proved tip $TIP, and the reopen FAILED; reopen it by hand
"
                  fi
                fi
              else
                NOTES="${NOTES}REFUSED closing PR $PRNUM for $b — gh pr close failed; left alone
"
              fi
            done <<EOF3
$OPENPRS
EOF3
          else
            # The query failed — say so. Silently skipping is what leaves a PR dangling with no
            # trace, which is the defect this arm exists to remove.
            NOTES="${NOTES}UNVERIFIED $b — the open-PR query failed, so no PR was closed for it
"
          fi
        fi
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
report a clean sweep. Enumerate, **show the list and get one confirmation**, then delete each
branch by name **under a lease on the tip that enumeration proved** (#346): the enumeration is this
half's only evidence, and an unleased `git push origin --delete` removes the ref whatever it points
at now, so a push landing mid-sweep would destroy a tip nothing ever proved contained.

```bash
if [ "$HAVE_GH" -eq 1 ] \
   && [ "$(gh api 'repos/{owner}/{repo}' --jq '.delete_branch_on_merge' 2>/dev/null)" = "false" ]; then
  NOTES="${NOTES}NOTE: delete_branch_on_merge is OFF — squash-merged remote branches are not
  detected here (only ancestor-merged ones are). See baseline issue #56.
"
fi
```

```bash
# ADB-SNIPPET: remote-enum
# THE TIP IS CAPTURED HERE, WITH THE PROOF (#346). `--merged` is this half's ONLY evidence, and the
# delete below leases against exactly the OID this line read. Re-reading the tip at delete time
# would look equivalent and is the bug wearing the fix's clothes (#305's discipline): a second read
# is a second moment, so it would happily "confirm" a tip that arrived after the containment was
# established and lease the delete to the very commit nobody proved.
#
# `%(objectname)` is the REMOTE-TRACKING tip as of this run's `git fetch --prune`, not a live read
# of the remote — and that is the point rather than a limitation. The lease compares it against
# what the remote holds at push time, so a branch that moved in between (by anyone, in any clone)
# refuses instead of deleting by name.
#
# ONE awk, not the four-process grep/sed pipeline this replaces, because every filter that used to
# be whole-line is now field-aware: `$PROTECTED` and `$CURRENT` are anchored patterns and a
# `<name><TAB><oid>` line would match neither, so a protected or current branch would sail straight
# through a pipeline that still looked correct. Same three exclusions, applied to the NAME field:
#   - the bare `origin` short form of the origin/HEAD symref, which `%(refname:short)` renders with
#     no trailing slash — unfiltered it leaks into the list and offers `git push origin --delete
#     origin`. `$1 ~ /^origin\//` drops it; `origin/HEAD` is excluded by name as
#     belt-and-suspenders for a build that renders the fully-qualified form.
#   - the protected set, matched as the ERE it already is.
#   - the branch this sweep is standing on.
REMOTE_MERGED="$(git branch -r --merged "$BASE" --format="%(refname:short)${TABC}%(objectname)" \
  | awk -F"$TABC" -v OFS="$TABC" -v prot="$PROTECTED" -v cur="$CURRENT" '
      $1 !~ /^origin\// { next }
      $1 == "origin/HEAD" { next }
      { n = substr($1, 8) }
      n ~ prot { next }
      n == cur { next }
      { print n, $2 }' \
  | sort -u || true)"
```

Fed by a heredoc, not a pipe: a piped `while` runs in a subshell, so every `DELETED_REMOTE`
append would be discarded and step 6 would report an empty category for work it really did.

```bash
# ADB-SNIPPET: remote-sweep
# TWO FIELDS: the branch name and the tip the enumeration proved contained. Reading one variable
# here would fold the OID into `$b` and hand `git push` a branch name that does not exist — loudly,
# which is the only reason a single-variable slip is not the dangerous direction. The dangerous one
# is the opposite and it is what this loop now closes.
while IFS="$TABC" read -r b oid; do
  [ -n "$b" ] || continue
  # NO OID, NO DELETE. An enumeration that produced a name without a tip cannot be leased, and an
  # unleased `git push origin --delete` is exactly the by-name delete #346 exists to remove — so
  # the branch is kept and the gap is reported, never quietly deleted on weaker evidence.
  if [ -z "$oid" ]; then
    NOTES="${NOTES}SKIPPED origin/$b — the enumeration carried no tip, so the delete could not be leased; left in place
"
    continue
  fi
  # THE LEASE (#346). `git push origin --delete` removes the ref BY NAME, whatever it points at
  # now: a push landing between this run's `git fetch --prune` and this line deleted a tip that was
  # never proved contained — the one outcome this skill promises never to produce. The explicit
  # `--force-with-lease=<ref>:<oid>` form makes the delete a compare-and-delete against the tip the
  # enumeration above actually proved, so that race REFUSES instead of destroying work.
  #
  # The EXPLICIT expected value, never the bare `--force-with-lease`. The bare form leases against
  # the local remote-tracking ref, which this very sweep is reasoning about and which a concurrent
  # `git fetch` in another process can advance — it would lease against whatever arrived, i.e.
  # against nothing. The `<ref>:<oid>` form pins the one commit the proof is about.
  #
  # Fully-qualified `refs/heads/$b` on BOTH halves, so a branch whose name collides with a tag
  # cannot make git resolve one thing for the lease and another for the delete.
  if git push origin --force-with-lease="refs/heads/$b:$oid" --delete "refs/heads/$b"; then
    # The same proof discipline as the local half (#332), and now the SAME STRENGTH of claim. This
    # line used to read `contained in $BASE when enumerated`, and the qualifier was load-bearing:
    # without a lease the tip actually removed was not necessarily the tip that was proved. With
    # the lease it is — the push refuses unless the remote still holds exactly `$oid` — so the
    # containment may be stated plainly of the ref that was really deleted.
    DELETED_REMOTE="${DELETED_REMOTE}${b}${TABC}contained in $BASE
"
  else
    # ONE arm for two causes, and the wording names both rather than picking the flattering one.
    # A rejected lease and a failed push are indistinguishable from an exit status, and asserting
    # "it moved" for what may have been a network error would be this report claiming something it
    # did not observe (`base/practices/verify-before-asserting.md`). What IS observed is that the
    # branch was not deleted, and that is what the line says.
    NOTES="${NOTES}REFUSED origin/$b — it moved during the sweep, or the push failed; left in place
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
STATE="$ROOT/.claude/state"
# `$TABC` comes from step 1, where it is defined once for the whole run — see the note there.

# state-scan exits 2 — with NO stdout — when the state directory's OWN path cannot be serialized.
# Captured with an `if` rather than left to fall through, because the fallthrough is the silent
# one: an empty $SCAN sweeps nothing and looks exactly like a clean, already-empty state dir, and
# "reported success while doing nothing" is the #106 class this whole library exists to remove.
# The message deliberately does NOT interpolate $STATE — that path is the thing containing a
# newline, and pasting it into the report would move the injection into the operator's output.
if ! SCAN="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-scan "$STATE")"; then
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
# ADB-SNIPPET: marker-sweep
RUN=none
while IFS="$TABC" read -r kind sfile key; do
  [ "$kind" = marker ] || continue
  # Seed on FIRST sight: a marker exists, so this is a finished run until some marker says keep.
  # (A separate "did we see one" flag plus a trailing fixup is one fact tracked twice — and the
  # fixup is a compound test that leaves the whole block on a non-zero status.)
  [ "$RUN" = none ] && RUN=stale

  # The identity of the FILE as judged. Re-captured immediately before deletion below.
  IDENT="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" marker-identity "$sfile")"

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

  if ! MV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict marker "$PRSTATE" "$LREF" "$RREF")"; then
    NOTES="${NOTES}SKIPPED ${sfile##*/} — could not be classified; kept
"; RUN=keep; continue
  fi
  [ "$MV" = keep ] && RUN=keep
  if [ "$MV" = stale ]; then
    # Re-capture the FILE IDENTITY at the moment of deletion. Comparing `.branch` alone is not
    # enough: a new /implement-issue run retrying the same issue writes the same deterministic
    # `issue-NN-slug`, so a replaced marker would compare equal and be deleted — disarming a live
    # run's continuation gate. An empty identity (unreadable) never matches, so it also keeps.
    NOW="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" marker-identity "$sfile")"
    if [ -n "$IDENT" ] && [ "$NOW" = "$IDENT" ] && rm -f "$sfile" 2>/dev/null; then
      # THE PROOF (#332), built from the FACTS THIS VERDICT CONSUMED — `$LREF`/`$RREF`/`$PRSTATE`,
      # already in hand — never from a second read. `state-verdict` returns only `keep`/`stale` by
      # design and must not grow an evidence string, so the rendering belongs here, at the one site
      # that holds the inputs.
      #
      # A marker reaches `stale` only with BOTH refs provably gone, so "branch gone" is true on
      # every path through here; the PR clause is appended only when a PR was actually read.
      # `PR merged`/`PR closed` and never `PR #<n> …`: this is a status word, and `state-assert.sh
      # lint` flags one sharing a sentence with a `#N`. The number is absent from the wording for
      # that reason, and its absence costs nothing — `.prUrl` is not in the report's vocabulary
      # anyway, and the marker's own filename is what the line already names.
      case "$PRSTATE" in
        none) MPROOF="branch gone" ;;
        *)    MPROOF="branch gone, PR $PRSTATE" ;;
      esac
      CLEARED="${CLEARED}${sfile##*/}${TABC}${MPROOF}
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

**The identity comes FROM the scan, not from a pass over its output.** `state-scan --with-identity`
appends it as a fourth field, computed in the same loop iteration that classified the file, because
only that loop can bind the two facts to one observation. Deriving it here — walk the finished
records, fingerprint each path — looks equivalent and is the bug wearing the fix's clothes: by then
the path may already hold a successor, so the fingerprint describes *it*, and the delete-time
comparison compares a replacement against itself and matches. That was the first implementation of
this fix, and an independent review was right to reject it. The flag is opt-in so the three-variable
readers above are untouched — `read` folds every surplus field into the last variable, which here is
a marker's branch name and a thread cache's PR number.

**What this does NOT claim.** Two syscalls still separate the re-capture from the `rm`, exactly as in
the marker arm above. Closing that would mean moving the file aside and verifying the operand — what
`implement-lib.sh` does to break a *claim* — and that trade is wrong here: it unlinks, however
briefly, a file we have just decided belongs to somebody else and may be reading, and a crash mid-way
strands a sidecar `state-scan` classifies `other` and therefore never sweeps. Nor is `state-scan` an
atomic snapshot: its glob expands before its per-file loop, so a file replaced between that expansion
and its own iteration is outside what this closes. Both residuals are microseconds wide, and neither
is what keeps the sweep safe on its own — the `lock` and `marker` records in this same scan are.

```bash
# ADB-SNIPPET: state-sweep
# Status-checked exactly like the first scan, and this is the snapshot that actually drives `rm`.
# The library's deliberate failure path emits nothing before it dies, so an unchecked capture is
# safe *by implementation* rather than *by contract* — but command substitution KEEPS partial
# stdout on a non-zero exit, so a future mid-enumeration error would hand half a snapshot straight
# to the delete loop. Fail closed structurally instead of relying on that staying true.
# `--with-identity` (#305): the scan appends each file's identity as a FOURTH field, computed inside
# the same enumeration pass that classified it. This is the snapshot that drives `rm`, and the delete
# below refuses unless the file is still the one this record describes. Deriving that fourth field
# HERE instead — walk the finished records, fingerprint each path — was the first implementation and
# it is the bug wearing the fix's clothes: by then the path may already hold a successor, so the
# fingerprint describes IT and the delete-time comparison matches. Only the scan can bind the
# classification and the identity to one observation.
if ! SCAN="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-scan --with-identity "$STATE")"; then
  NOTES="${NOTES}REFUSED the state deletes — the pre-delete re-scan could not enumerate the state directory safely; nothing was swept
"
  SCAN=""
fi
LOCK=0
if printf '%s\n' "$SCAN" | grep -q "^lock${TABC}"; then LOCK=1; fi
# An `if`, not `… && RUN_NOW=keep`, for the reason given above the lock probe: an AND-list whose
# test fails leaves the whole fenced block on exit status 1, and "no marker present" is the
# common case after a merge — the sweep would read as a failed step.
RUN_NOW=none
if printf '%s\n' "$SCAN" | grep -q "^marker${TABC}"; then RUN_NOW=keep; fi

GV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict gaps "$LOCK" "$RUN")" || GV=keep
# The survey artifacts (#435) are written between steps 2 and 3 — BEFORE any marker exists,
# under the claim `admit` took in preflight — and READ AGAIN at step 6 ("Read survey.md first"),
# after the marker has taken over. So the lock is their pre-marker signal and the DELETE takes
# `$RUN_NOW`, the fresh re-scan's answer, exactly as the issue snapshots do: a run that reached
# step 5 mid-sweep must show up as live at the moment of the delete (reviewer find).
SV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict survey "$LOCK" "$RUN_NOW")" || SV=keep
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
IV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict issue "$LOCK" "$RUN_NOW")" || IV=keep
RV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict review "$RUN_NOW")" || RV=keep
# The documentation-duty record (#422). Same shape and same freshness argument as `review`:
# /implement-issue step 5b writes it after the marker exists, and step 10 and step 11 both read it
# back, so `$RUN_NOW` is what governs the delete.
DV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict docs "$RUN_NOW")" || DV=keep

# The five verdicts above rest on LOCK and RUN_NOW as ONE scan captured them, and the scan
# fingerprints artifacts as it walks — the claim's row can be probed BEFORE a survey row is
# fingerprinted, so an admission landing mid-walk yields "no run" verdicts beside a LIVE run's
# identities, and the delete-time identity check then MATCHES the live file (reviewer find,
# PR #452). Re-ask liveness NOW, after every identity is captured: presence at this instant
# keeps every run artifact, and the remaining tail — an admission after this probe — is covered
# by the identity check, because its clear-and-recreate gives the file a new identity.
if bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" run-live "$STATE"; then
  GV=keep; SV=keep; IV=keep; RV=keep; DV=keep
  NOTES="${NOTES}KEPT the run artifacts — a run claim or marker was present after the identity snapshot; none were judged this pass
"
fi

# sweep_file <path> <identity-as-judged> <proof> — delete ONE file, but only if it is still the
# file the verdict was about (#305), and record WHY it was removed (#332).
#
# THE PROOF IS AN ARGUMENT, NOT A RETURN VALUE, and it is appended inside the successful `rm` arm
# only. This function returns 0 on a SKIP as well (a file that is no longer the judged one is a
# normal outcome, not an error), so a caller appending evidence on the strength of the exit status
# would attribute a deletion to a file that is still sitting there. Passing it in is what binds the
# proof to the one arm that actually removed something.
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
  now="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" file-identity "$1")"
  if [ -z "$2" ] || [ -z "$now" ] || [ "$now" != "$2" ]; then
    NOTES="${NOTES}SKIPPED ${1##*/} — it is no longer the file that was judged; kept
"
    return 0
  fi
  if rm -f "$1" 2>/dev/null && [ ! -e "$1" ]; then
    # `${3:-}`, not `${3}`: these blocks normally run without `set -u`, but a caller that DOES set
    # it would abort the whole sweep mid-delete on an arm that forgot its proof. An empty proof
    # renders as the pre-#332 line, which is the right direction — a missing annotation must never
    # be able to stop a sweep that has already started removing files.
    CLEARED="${CLEARED}${1##*/}${TABC}${3:-}
"
  else
    NOTES="${NOTES}REFUSED ${1##*/} — could not be removed (state dir not writable?); left in place
"
  fi
}

# FOUR fields: this scan was taken `--with-identity`, and that fourth column is the only thing
# standing between a stale verdict and a live run's file. Reading three here would silently fold the
# identity into `$key` — which the `threads` arm passes to `pr_state` as a PR number.
while IFS="$TABC" read -r kind sfile key ident; do
  case "$kind" in
    gaps)
      [ "$GV" = stale ] || continue
      sweep_file "$sfile" "$ident" "no run in flight"
      ;;
    survey)
      [ "$SV" = stale ] || continue
      sweep_file "$sfile" "$ident" "no run in flight"
      ;;
    issue)
      [ "$IV" = stale ] || continue
      sweep_file "$sfile" "$ident" "no run in flight"
      ;;
    review)
      [ "$RV" = stale ] || continue
      sweep_file "$sfile" "$ident" "no run in flight"
      ;;
    docs)
      [ "$DV" = stale ] || continue
      sweep_file "$sfile" "$ident" "no run in flight"
      ;;
    threads)
      # THE PR STATE IS CAPTURED, THEN USED TWICE (#332) — decided the verdict, then reported as
      # its proof. `state-verdict threads "$(pr_state "$key")"` spent the value inline and threw it
      # away, which is the defect this issue is about, in miniature: the sweep knew exactly why the
      # cache was sweepable and printed a bare filename. Asking `pr_state` a second time for the
      # report would be a DIFFERENT read of mutable state, i.e. the staleness that makes the output
      # untrustworthy in the first place, plus a second round trip per cache.
      PRST="$(pr_state "$key")"
      TV="$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict threads "$PRST")" || continue
      [ "$TV" = stale ] || continue
      # `PR $PRST`, deliberately WITHOUT the number. Two reasons, and they point the same way: the
      # number is already in the filename this line prints, and repeating it would put a `#N` in a
      # sentence with a status word, which `state-assert.sh lint` rejects. Omitting it also keeps
      # the proof IDENTICAL across every cache swept for the same reason, so `report`'s brace
      # collapse survives — `threads-{41,47,51}.json [PR merged]` rather than three separate pieces.
      sweep_file "$sfile" "$ident" "PR $PRST"
      ;;
  esac
done <<EOF
$SCAN
EOF
```

**Then say what the scan saw about the run marker (#350).** Three states of one record used to
render byte-identically as silence: the Stop-hook gate cleared it at end of run (the normal case,
and in the documented `merge → /cleanup → /clear` loop the marker is *always already gone* by
sweep time); no run ever existed here; or **a marker is sitting in the state directory under a
filename the classifier no longer matches** — classified `other`, correctly never swept, and
*never reported*. That third one is the failure the library names in its own words: `RUN_NOW` reads
`none`, so a **live** run's gap and review artifacts become sweepable. A guard must say what it
checked, not only whether it passed (`base/practices/self-review.md`).

**It reports an observation, never an inferred cause.** `/cleanup` never watched the gate clear
anything, so it must not say so (`base/practices/verify-before-asserting.md`). What it did observe
is which records the delete scan held, and that is exactly what the line states. **Nothing here
decides anything**: `state-verdict marker` remains the only thing that decides a marker's fate, in
the marker pass above, and `other` is still never touched (the rule at the top of this step stands).
This renders what those decisions produced.

**Absence stays silent**, because the terse contract forbids a `Run marker: none` on every sweep
(#84) — and absence is the overwhelmingly common case. A marker record that *was* observed is never
silent: it appears under `Cleared state` if this sweep removed it, and under `Run marker` if it is
still there.

```bash
# ADB-SNIPPET: marker-report
# THE SAME SNAPSHOT the deletes ran from — the pre-delete re-scan, which binds a file's
# classification and its identity to one observation. Reporting from the FIRST scan instead would
# describe a state the sweep no longer acted on, which is the staleness this whole step is built to
# avoid; and re-scanning a third time here would be a different moment again.
while IFS="$TABC" read -r kind sfile key ident; do
  case "$kind" in
    marker)
      # Present at the scan that governed the deletes, i.e. exactly the fact that set `RUN_NOW=keep`
      # and preserved every gap, issue and review artifact above. Stated as the observation, not as
      # "a run is running" — this sweep saw a file, not a process.
      #
      # KEY `-` IS UNKNOWN LIVENESS, NOT A LIVE RUN. `state-scan` emits `-` when the marker is
      # malformed or unreadable, and `state-verdict marker` KEEPS it — a conservative refusal.
      # Reporting that as "a run in flight" would convert the refusal into a confirmed claim and
      # teach the operator to trust corrupt state indefinitely. Say only what was verified.
      if [ "$key" = "-" ]; then
        RUNMARK="${RUNMARK}${sfile##*/}${TABC}present; liveness could not be verified — kept fail-closed
"
      else
        RUNMARK="${RUNMARK}${sfile##*/}${TABC}present at the delete scan — artifacts kept for a run in flight
"
      fi
      ;;
    other)
      # THE DEFECT CASE. `marker-shape` asks the FAMILY question the delete allowlist deliberately
      # cannot: does this look like a run marker? A second copy of the allowlist here would have
      # drifted along with the arm that stopped matching and detected nothing, which is why the
      # library answers it with a wider predicate instead (see its header).
      [ "$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" marker-shape "$sfile")" = marker-shaped ] || continue
      RUNMARK="${RUNMARK}${sfile##*/}${TABC}UNRECOGNISED — scanned as 'other', so this sweep detected no run in flight
"
      ;;
  esac
done <<EOF
$SCAN
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
# Four fields again — this loop reads the SAME `--with-identity` scan. It ignores the identity, but
# a three-variable `read` would leave `$key` holding `<key>TAB<identity>`, which is a trap for the
# next person who adds an arm that uses it.
while IFS="$TABC" read -r kind sfile key ident; do
  case "$kind" in
    gaps)   [ "$GV" = keep ] || continue ;;
    survey) [ "$SV" = keep ] || continue ;;
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
`bash "$HOME/.claude/scripts/lib/cleanup-lib.sh"`, and step 7 may replace that very library on disk (it re-runs the installer,
whose symlinks are what `bash "$HOME/.claude/scripts/lib/cleanup-lib.sh"` resolves through). Composing the report first means the
whole sweep is reported by the library version that decided it — an old workflow calling a
freshly-swapped library is a version skew with no upside.

`emit` is unchanged by #332, #346 and #350, and deliberately so: each accumulator line is already
`<item>TAB<proof>`, so prefixing the category yields the three-field record `report` now reads, and
a line carrying no proof yields the two-field record it has always read. The `\t` below is a
`printf` escape, not a raw tab — the accumulators use `$TABC` from step 1 for the same reason.
**Two categories join the list rather than two renderers**, which is why neither issue needed a
change here beyond a line each: a category exists only because a record created it, so both stay
absent on a sweep that has nothing to say about them.

**The order is the causal order**, and it is the one thing about this block that is a decision.
`PR closed` sits directly under the deletes because a close is a *consequence* of the local delete
above it and is meaningless without it; `Run marker` sits last, under `Cleared state`, because it
is the only category that reports something the sweep did **not** change — what it saw and left
alone. A reader scanning top-to-bottom then gets destructive actions, their follow-on mutations,
and finally the observation, before the repository-state tail.

**`PR closed` carries a bare number, never `#<n>` — and that rule reaches its PROOF too.**
`bash "$HOME/.claude/scripts/lib/state-assert.sh" lint` rejects a status word sharing a sentence with an entity reference,
`closed` is a status word, and the category name is the sentence. This is the same rule the
`Cleared state` proofs already live by (`PR merged`, not `PR #41 merged`) — read from the other
end, and the number is not lost: it is the item. The sharper half is the proof: a `merged-pr`
delete's evidence *is* `#<n> (merge commit <oid>)`, so rendering the delete's proof on this line
would violate the grammar on any sweep where a squash-merged branch also had an open PR. The proof
here is the **OID gate this close passed** instead, which is both grammar-safe and the more precise
answer to why *this* PR was closed; the delete's own evidence is one line above, and the full
string reaches the PR itself as the closing comment.

```bash
emit() { printf '%s\n' "$2" | while IFS= read -r x; do [ -n "$x" ] && printf '%s\t%s\n' "$1" "$x"; done; }

REPORT_OUT="$({
  emit 'Deleted (local)'  "$DELETED_LOCAL"
  emit 'Deleted (remote)' "$DELETED_REMOTE"
  emit 'PR closed'        "$PR_CLOSED"
  emit 'Cleared state'    "$CLEARED"
  emit 'Run marker'       "$RUNMARK"
} | bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" report --tail "$(bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-line "$ROOT" "$DEFAULT")")"
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

Every decision is `bash "$HOME/.claude/scripts/lib/currency-lib.sh"`'s: the mode (`[updates] session_start` in the global
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
CU_RECORD="$(bash "$HOME/.claude/scripts/lib/currency-lib.sh" check --trigger cleanup 2>/dev/null || true)"
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

`verbose` is about what was **preserved**; the evidence for what was **deleted** is not gated on it
and never was (#332). Those are opposite questions, and putting the second behind a flag is what
left a default sweep unable to justify its own least-reversible action.

## Notes

- This never runs `git branch -D`, `push --force`, or `clean -fd`. Unmerged branches are always
  preserved; unclassifiable run-state is always kept. The remote delete does pass
  `--force-with-lease`, and that is the opposite of a force-push: it adds a compare-and-delete
  where there was none, so the only outcome it can produce that the old command could not is a
  **refusal** (#346).
- Run it after a merge, or periodically. It is idempotent — a second run finds nothing new and
  prints only the state line. The currency check is idempotent in the same sense: once the install
  is current it reports nothing, though a second sweep *does* re-check (an explicitly requested
  check is never suppressed by the rate limit — see `bash "$HOME/.claude/scripts/lib/currency-lib.sh"`).
- **First deployment cannot bootstrap itself.** The installed `/cleanup` is a symlink into the
  install-source clone, so the sweep you run immediately after this change lands is still the OLD
  one, without a currency step. Run `baseline update` by hand once; every sweep after that carries
  it.
- The remote half is enumerated with `--merged` alone on purpose (see step 4). Only the **local**
  half needs PR evidence, because only local refs survive a squash merge.
