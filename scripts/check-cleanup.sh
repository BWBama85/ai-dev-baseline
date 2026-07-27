#!/usr/bin/env bash
# ai-dev-baseline — behavioral tests for the /cleanup decision predicates (#106 + #84), plus a
# source-drift guard on the workflow that consumes them.
#
# WHY THIS EXISTS. /cleanup is prose an agent executes against a live repo, and #106 is what that
# costs when the decisions are unexecutable: the skill decided local-branch eligibility from
# `git branch --merged` plus `git branch -d`'s refusal, BOTH of which are structurally blind to a
# squash merge, and nothing could prove the blindness. It reported "nothing to sweep" on every run
# of a squash-merging repo — a permanent no-op wearing a success message. The decisions now live
# in scripts/lib/cleanup-lib.sh; this pins them.
#
# Every destructive direction is tested from the DANGEROUS side, because that is the side that
# costs something:
#   - a branch that gained commits after its squash merge must NOT be deletable (lost work);
#   - state for an OPEN PR or an in-flight run must NOT be sweepable (a disarmed continuation
#     gate, which fails silently — the /implement-issue Stop hook reads exactly these markers);
#   - anything unclassifiable must fail CLOSED, never "probably fine".
#
# OFFLINE by construction: the library never calls gh, so this needs only bash, git and jq. The
# squash-merge fixture is a real local repo pair — the merge topology has to be real, since the
# whole bug is about what git's ancestry queries can and cannot see.
#
# scripts/check-cleanup-enum.sh stays the home of the #38 remote-enumeration regression and its
# fact-drift token; this file owns the library and the destructive-path behavior.
#
# Usage: bash scripts/check-cleanup.sh   (exit 0 = all pass, 1 = a failure)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
CL="$ROOT/scripts/lib/cleanup-lib.sh"
WF="$ROOT/base/workflows/cleanup.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary + check_make_repo_pair

# jq is the library's dependency for PR evidence and marker reads. Without it every evidence case
# would return `unverified` and the suite would report a wall of misleading passes.
if ! command -v jq >/dev/null 2>&1; then
  echo "check-cleanup: FATAL — jq is required to run these tests" >&2
  exit 1
fi

work="$(mktemp -d)" || { echo "check-cleanup: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# ============================ 1. branch-verdict, against a real repo ==========================
# The fixture reproduces all three merge shapes in one repo, because the verdict is defined by
# what git ancestry can see and only a real topology exercises that.
R="$work/repo"
check_make_repo_pair "$R" "$work/remote.git" || { bad "fixture init failed"; check_summary "check-cleanup"; }
(
  cd "$R" || exit 1
  git checkout -q -b main
  git commit -q --allow-empty -m init
  git push -q -u origin main

  # (a) fast-forward-mergeable: tip becomes an ancestor of main.
  git checkout -q -b feat/ff
  git commit -q --allow-empty -m ff-work
  git checkout -q main
  git merge -q --no-ff feat/ff -m "merge feat/ff"

  # (b) SQUASH-merged: the content lands as a NEW commit, so the branch tip is never an ancestor.
  #     This is #106's whole subject — `git branch --merged` cannot see it.
  git checkout -q -b feat/squash
  git commit -q --allow-empty -m squash-work
  git checkout -q main
  git commit -q --allow-empty -m "squashed feat/squash (#7)"

  # (c) genuinely unmerged.
  git checkout -q -b feat/open
  git commit -q --allow-empty -m open-work
  git checkout -q main
  git push -q origin main
) || { bad "fixture build failed"; check_summary "check-cleanup"; }

rg() { git -C "$R" "$@"; }
SQ_TIP="$(rg rev-parse feat/squash)"
SQ_MERGE="$(rg rev-parse main)"
OPEN_TIP="$(rg rev-parse feat/open)"

# verdict <branch> <json> — run branch-verdict in the fixture, echo "<line1>|<line3>".
verdict() {
  local out
  out="$(printf '%s' "$2" | ( cd "$R" && bash "$CL" branch-verdict "$1" origin/main ) 2>/dev/null)"
  printf '%s|%s' "$(printf '%s\n' "$out" | sed -n 1p)" "$(printf '%s\n' "$out" | sed -n 3p)"
}
# vtip <branch> <json> — line 2, the OID the verdict was computed from (drives the atomic delete).
vtip() {
  printf '%s' "$2" | ( cd "$R" && bash "$CL" branch-verdict "$1" origin/main ) 2>/dev/null | sed -n 2p
}
prjson() { printf '[{"number":%s,"headRefOid":"%s","mergeCommit":{"oid":"%s"}}]' "$1" "$2" "$3"; }

# --- 1a. the three merge shapes -------------------------------------------------------------
eq "$(verdict feat/ff '[]')" "merged-ff|" "1a fast-forward merge is merged-ff without any PR evidence"
eq "$(vtip feat/ff '[]')" "$(rg rev-parse feat/ff)" "1a line 2 is the tip the verdict was computed from"

# THE #106 REGRESSION: before the fix this branch was invisible to every detector the skill had.
out="$(verdict feat/squash "$(prjson 7 "$SQ_TIP" "$SQ_MERGE")")"
eq "${out%%|*}" "merged-pr" "1a squash merge is detected via fresh PR evidence + local ancestry (#106)"
has "${out#*|}" "#7" "1a the detail names the PR that proves it"

eq "$(verdict feat/open '[]')" "unmerged|" "1a a genuinely unmerged branch is unmerged"

# --- 1b. THE DESTRUCTIVE CASE: new commits after the squash merge ---------------------------
# #106 asks only that mergeCommit.oid be contained in the default branch. That alone still
# matches a branch which was squash-merged and THEN had new work added — deleting it would
# destroy commits that never landed. `headRefOid == tip` is what refuses it.
rg checkout -q feat/squash
rg commit -q --allow-empty -m "new local work after the merge"
rg checkout -q main
eq "$(verdict feat/squash "$(prjson 7 "$SQ_TIP" "$SQ_MERGE")")" "unmerged|" \
   "1b a branch that gained commits AFTER its squash merge is NOT deletable (headRefOid guard)"
# Restore the fixture for the remaining cases, and prove the refusal was about the extra commit
# and nothing else — otherwise a verdict that always said `unmerged` would pass the case above.
rg update-ref refs/heads/feat/squash "$SQ_TIP"
eq "$(verdict feat/squash "$(prjson 7 "$SQ_TIP" "$SQ_MERGE")" | cut -d'|' -f1)" "merged-pr" \
   "1b …and is deletable again once the extra commit is gone"

# --- 1c. evidence that does not prove anything ----------------------------------------------
# A merged PR whose merge commit is NOT on this default branch (merged into another base, or a
# fork's). Contained-in-base is what makes the evidence local and current.
STRAY="$(rg rev-parse feat/open)"
eq "$(verdict feat/squash "$(prjson 7 "$SQ_TIP" "$STRAY")")" "unmerged|" \
   "1c a merge commit NOT contained in the default branch proves nothing"
# A PR for a DIFFERENT head (the [gone]-without-merge shape: someone deleted the remote branch).
eq "$(verdict feat/squash "$(prjson 7 "$OPEN_TIP" "$SQ_MERGE")")" "unmerged|" \
   "1c a merged PR whose headRefOid is another branch's tip proves nothing"
# mergeCommit: null — GitHub reports this for some merged PRs; it must not crash or delete.
eq "$(verdict feat/squash "$(printf '[{"number":7,"headRefOid":"%s","mergeCommit":null}]' "$SQ_TIP")")" \
   "unmerged|" "1c mergeCommit: null is tolerated and proves nothing"
# A merge commit the local object store has never seen cannot be tested -> preserve.
eq "$(verdict feat/squash "$(prjson 7 "$SQ_TIP" "0000000000000000000000000000000000000001")")" \
   "unmerged|" "1c an unfetched merge commit degrades to unmerged, not an error"

# --- 1d. degradation and fail-closed --------------------------------------------------------
# The no-gh / no-remote path #106 requires: byte-identical to pre-#106 behavior.
eq "$(verdict feat/ff '')"     "merged-ff|" "1d empty evidence still resolves a fast-forward (no-gh degradation)"
eq "$(verdict feat/open '')"   "unmerged|"  "1d empty evidence preserves everything else (no-gh degradation)"
eq "$(verdict feat/open '[]')" "unmerged|"  "1d an empty array is a clean negative, not an error"

# Malformed evidence must be an ERROR (2), never a quiet verdict a caller would act on.
printf '{"not":"an array"}' | ( cd "$R" && bash "$CL" branch-verdict feat/open origin/main ) >/dev/null 2>&1
no $? "1d a non-array JSON payload exits non-zero"
printf 'not json at all' | ( cd "$R" && bash "$CL" branch-verdict feat/open origin/main ) >/dev/null 2>&1
no $? "1d unparseable JSON exits non-zero"
( cd "$R" && bash "$CL" branch-verdict no/such/branch origin/main </dev/null ) >/dev/null 2>&1
no $? "1d an unknown branch is an error, never a verdict"
( cd "$R" && bash "$CL" branch-verdict feat/ff origin/nope </dev/null ) >/dev/null 2>&1
no $? "1d an unknown base ref is an error, never a verdict"
( cd "$R" && bash "$CL" branch-verdict --evil origin/main </dev/null ) >/dev/null 2>&1
no $? "1d an option-shaped branch name is refused before it reaches git"

# A ref name using the punctuation git DOES allow (git forbids spaces, so the awkward-but-legal
# set is `.` `-` `_` `+` and multiple slashes) must survive quoting intact.
ODD='feat/odd.name-with_chars+v2/deep'
rg checkout -q -b "$ODD"
rg commit -q --allow-empty -m odd
rg checkout -q main
rg merge -q --no-ff "$ODD" -m "merge odd"
rg push -q origin main   # the verdict classifies against origin/main, not the local tip
eq "$(verdict "$ODD" '[]')" "merged-ff|" "1d an unusual but valid ref name is handled verbatim"

# ============================ 2. state-verdict: liveness precedence ===========================
sv() { bash "$CL" state-verdict "$@" 2>/dev/null; }

# --- 2a. thread caches ----------------------------------------------------------------------
eq "$(sv threads open)"    "keep"  "2a a cache for an OPEN PR is never swept"
eq "$(sv threads merged)"  "stale" "2a a cache for a merged PR is swept"
eq "$(sv threads closed)"  "stale" "2a a cache for a closed PR is swept"
eq "$(sv threads unknown)" "keep"  "2a an unreadable PR state fails CLOSED to keep"
sv threads bogus >/dev/null 2>&1; no $? "2a an unrecognised PR state is an error, not a sweep"

# --- 2b. run markers: an OPEN PR outranks branch absence ------------------------------------
# The precedence that matters: after `gh pr create` the branch may be tidied while the run is
# still live. Deciding on branch absence alone would disarm the continuation gate mid-run.
eq "$(sv marker open 0 0)"    "keep"  "2b an OPEN PR keeps the marker even with both refs gone"
eq "$(sv marker merged 0 0)"  "stale" "2b a merged PR with both refs gone is a finished run"
eq "$(sv marker none 1 0)"    "keep"  "2b a surviving LOCAL ref keeps the marker"
eq "$(sv marker none 0 1)"    "keep"  "2b a surviving REMOTE ref keeps the marker"
eq "$(sv marker none 0 0)"    "stale" "2b no PR and both refs gone is a finished run"
eq "$(sv marker unknown 0 0)" "keep"  "2b an unreadable PR state fails CLOSED to keep"
eq "$(sv marker none unknown 0)" "keep" "2b an unreadable local ref fails CLOSED to keep"
eq "$(sv marker none 0 unknown)" "keep" "2b an unreadable remote ref fails CLOSED to keep"
sv marker open 0 >/dev/null 2>&1;      no $? "2b a marker verdict with too few facts is an error"
sv marker open 0 2 >/dev/null 2>&1;    no $? "2b a non-boolean ref fact is an error"

# --- 2c. gap artifacts: the in-flight lock outranks everything -------------------------------
# Gap analysis runs BEFORE the branch and marker exist, so during a live pass there is no marker
# to consult; without the lock the artifacts read as a finished run's leftovers and /cleanup
# would delete findings a dispatch is still writing.
eq "$(sv gaps 1 none)"  "keep"  "2c the in-flight lock keeps gap artifacts with no marker at all"
eq "$(sv gaps 1 stale)" "keep"  "2c the lock outranks even a finished run's marker"
eq "$(sv gaps 0 keep)"  "keep"  "2c a live run keeps its gap artifacts"
eq "$(sv gaps 0 stale)" "stale" "2c a finished run's gap artifacts are swept"
eq "$(sv gaps 0 none)"  "stale" "2c no lock and no marker means nothing owns them"
sv gaps 2 none >/dev/null 2>&1;  no $? "2c a non-boolean lock is an error"
sv gaps 0 bogus >/dev/null 2>&1; no $? "2c an unrecognised run word is an error"
sv nosuchkind 0 >/dev/null 2>&1; no $? "2c an unknown kind is an error"

# ============================ 3. state-scan: the delete ALLOWLIST =============================
# The safety property is the asymmetry: everything recognised is classified, everything else is
# `other` and the workflow never sweeps it.
S="$work/state"; mkdir -p "$S"
: > "$S/threads-41.json"
: > "$S/threads-9.json"
: > "$S/threads-notanumber.json"
: > "$S/gap-prompt.txt"
: > "$S/gaps.md"
: > "$S/gaps.err"
: > "$S/gaps-retry.err"
: > "$S/gap-analysis.lock"
: > "$S/some-other-skill.json"
: > "$S/.marker.tmp"
printf '{"branch":"issue-9-thing","issue":"9","phase":"pushed"}' > "$S/implement-issue-active.json"
scan="$(bash "$CL" state-scan "$S")"
kindof() { printf '%s\n' "$scan" | awk -F'\t' -v b="$1" '{n=split($2,p,"/"); if (p[n]==b) print $1}'; }

eq "$(kindof threads-41.json)"              "threads" "3 a numbered thread cache is classified"
eq "$(kindof threads-9.json)"               "threads" "3 …including a single-digit PR number"
eq "$(kindof threads-notanumber.json)"      "other"   "3 a thread-shaped name with no PR number is NOT ours to delete"
eq "$(kindof implement-issue-active.json)"  "marker"  "3 the active run marker is classified"
eq "$(kindof gap-analysis.lock)"            "lock"    "3 the in-flight lock is classified"
eq "$(kindof gaps.err)"                     "gaps"    "3 gap artifacts are classified"
eq "$(kindof gaps-retry.err)"               "gaps"    "3 …including the gaps-retry.* debris #84 names"
eq "$(kindof gap-prompt.txt)"               "gaps"    "3 …and the prompt, which carries private repo context"
eq "$(kindof some-other-skill.json)"        "other"   "3 an unrecognised file is 'other' — never swept"
eq "$(kindof .marker.tmp)"                  "other"   "3 a staged temp file is seen, and is 'other'"
# The marker's key is its recorded branch — that is what the liveness read is done against.
eq "$(printf '%s\n' "$scan" | awk -F'\t' '$1=="marker"{print $3}')" "issue-9-thing" \
   "3 a marker carries its recorded branch as the scan key"
# An unreadable marker must yield the '-' key, which the caller maps to `unknown` -> keep.
printf 'not json' > "$S/implement-issue-blocked.json"
eq "$(bash "$CL" state-scan "$S" | awk -F'\t' '/implement-issue-blocked/{print $3}')" "-" \
   "3 an unreadable marker yields the '-' key, so it fails closed"
eq "$(bash "$CL" state-scan "$work/does-not-exist")" "" "3 a missing state dir is an empty result, not an error"

# ============================ 4. report: the terse output contract ============================
rep() { bash "$CL" report "$@" 2>/dev/null; }

# #84's acceptance: one branch + a pile of state files, no zero-sections, <=3 lines.
typical="$(printf 'Deleted (local)\tissue-3-generic-release\n%s\nCleared state\tgaps.md\nCleared state\tgaps.err\n' \
  "$(for n in 41 47 51 57 59 65 68 72 76; do printf 'Cleared state\tthreads-%s.json\n' "$n"; done)" \
  | rep --tail "main: clean, in sync with origin/main")"
eq "$(printf '%s\n' "$typical" | grep -c .)" "3" "4 a typical sweep emits exactly 3 lines (#84 acceptance)"
has "$typical" "threads-{41,47,51,57,59,65,68,72,76}.json" "4 a run of numbered files compresses to one brace group"
has "$typical" "main: clean, in sync with origin/main"     "4 the --tail state line is always last"
hasnt "$typical" "(0)" "4 no zero-count section appears"
hasnt "$typical" "Deleted (remote)" "4 a category with no records cannot appear at all"

# Empty input is a sweep that changed nothing: the state line alone, never a "nothing to do" essay.
eq "$(printf '' | rep --tail 'main: clean, in sync with origin/main')" "main: clean, in sync with origin/main" \
   "4 a no-op sweep emits only the state line"

# Ordering is the caller's, never sorted — the report must match what scrolled past.
eq "$(printf 'C\tz-9.txt\nC\tz-2.txt\nC\tz-40.txt\n' | rep)" "C: z-{9,2,40}.txt" \
   "4 grouping preserves first-seen order and never sorts (numerically or otherwise)"
# Distinct prefixes are distinct families even inside one category, and keep their own order.
eq "$(printf 'C\tz-1.txt\nC\ta-2.txt\n' | rep)" "C: z-1.txt, a-2.txt" \
   "4 different prefixes do not get merged into one brace group"
# Items that do not fit the numeric pattern pass through verbatim, in place.
eq "$(printf 'C\tgaps.md\nC\tgaps.err\n' | rep)" "C: gaps.md, gaps.err" \
   "4 non-numeric items pass through verbatim"
# Two distinct families in one category stay distinct.
eq "$(printf 'C\tthreads-1.json\nC\tthreads-2.json\nC\tgaps.md\n' | rep)" "C: threads-{1,2}.json, gaps.md" \
   "4 separate families group separately"
# A lone member of a family must NOT gain braces.
eq "$(printf 'C\tthreads-1.json\n' | rep)" "C: threads-1.json" "4 a single item never gains a brace group"
rep --tail >/dev/null 2>&1; no $? "4 --tail without a value is an error"
rep --bogus >/dev/null 2>&1; no $? "4 an unknown report option is an error"

# ============================ 5. state-line: it must never lie ================================
# The terse contract makes this the ONLY state the operator is shown, so a hardcoded
# "clean, in sync" would be actively misleading in every non-clean case.
sl() { bash "$CL" state-line "$R" main 2>/dev/null; }
# Section 1 merged into main without pushing, so bring the fixture to the clean/in-sync state
# this first case is actually about.
rg push -q origin main
has "$(sl)" "clean, in sync" "5 a clean, synced default branch says so"
( cd "$R" && git checkout -q feat/open )
has "$(sl)" "still on feat/open" "5 a run that never returned to the default branch says which branch it is on"
( cd "$R" && git checkout -q main )
: > "$R/dirty.txt"
has "$(sl)" "DIRTY" "5 a dirty tree is reported, not papered over"
rm -f "$R/dirty.txt"
( cd "$R" && git commit -q --allow-empty -m unpushed )
has "$(sl)" "unpushed" "5 unpushed commits on the default branch are reported"
bash "$CL" state-line "$R" >/dev/null 2>&1; no $? "5 state-line requires both arguments"

# ============================ 6. source-drift guard on the workflow ===========================
# The deletion itself stays workflow prose (the agent must run the destructive command visibly,
# so command-safety gating can see the branch named). A predicate test therefore cannot prove the
# workflow still USES the predicates — pin the load-bearing tokens so a rewrite that drops them
# fails here rather than at sweep time.
if [ ! -f "$WF" ]; then
  bad "6 base/workflows/cleanup.md not found"
else
  wf="$(cat "$WF")"
  has "$wf" '{{CLEANUP_LIB}} branch-verdict' "6 the workflow classifies branches through the library"
  has "$wf" '{{CLEANUP_LIB}} state-scan'     "6 the workflow enumerates state through the library"
  has "$wf" '{{CLEANUP_LIB}} state-verdict'  "6 the workflow decides state through the library"
  has "$wf" '{{CLEANUP_LIB}} report'         "6 the workflow renders through the report contract"
  has "$wf" 'git update-ref -d "refs/heads/$b" "$TIP"' \
     "6 a rewritten-merge branch is deleted by expected-OID compare-and-delete"
  has "$wf" 'git branch -d "$b"' "6 a fast-forward branch still uses the self-validating -d"
  # THE guardrail: `-D` deletes whatever is there now, on a decision made earlier. Scoped to the
  # EXECUTABLE blocks — the guardrail prose says the words "never `git branch -D`", and a
  # whole-file match would flag the rule for stating what it forbids.
  wfcode="$(awk '/^```bash$/ { inb = 1; next } /^```$/ { inb = 0; next } inb' "$WF")"
  hasnt "$wfcode" 'git branch -D' "6 no fenced command in the workflow escalates to git branch -D"
  has "$wfcode" 'git update-ref -d' "6 …and the expected-OID delete really is in an executable block"
  has "$wf" '--limit 20' "6 the merged-PR query is paginated explicitly, so evidence cannot fall off page 1"
  has "$wf" 'gap-analysis.lock' "6 the workflow honors the gap-analysis in-flight lock"
  has "$wf" 'worktree list' "6 branches checked out in another worktree are excluded during enumeration"
fi

# The lock is only a contract if BOTH sides implement it: /implement-issue must take and release
# it around the dispatch, or /cleanup's `keep` arm can never fire.
II="$ROOT/base/workflows/implement-issue.md"
if [ ! -f "$II" ]; then
  bad "6 base/workflows/implement-issue.md not found"
else
  ii="$(cat "$II")"
  has "$ii" ': > {{STATE_DIR}}/gap-analysis.lock' "6 /implement-issue takes the lock before dispatching"
  has "$ii" 'rm -f {{STATE_DIR}}/gap-analysis.lock' "6 /implement-issue releases the lock when the call terminates"
fi

check_summary "check-cleanup"
