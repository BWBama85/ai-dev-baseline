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

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
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

fx() { check_git "$R" "$@"; }
SQ_TIP="${ fx rev-parse feat/squash; }"
SQ_MERGE="${ fx rev-parse main; }"
OPEN_TIP="${ fx rev-parse feat/open; }"

# verdict <branch> <json> — run branch-verdict in the fixture, echo "<line1>|<line3>".
verdict() {
  local out
  out="${ printf '%s' "$2" | ( cd "$R" && bash "$CL" branch-verdict "$1" origin/main ) 2>/dev/null; }"
  printf '%s|%s' "${ printf '%s\n' "$out" | sed -n 1p; }" "${ printf '%s\n' "$out" | sed -n 3p; }"
}
# vtip <branch> <json> — line 2, the OID the verdict was computed from (drives the atomic delete).
vtip() {
  printf '%s' "$2" | ( cd "$R" && bash "$CL" branch-verdict "$1" origin/main ) 2>/dev/null | sed -n 2p
}
prjson() { printf '[{"number":%s,"headRefOid":"%s","mergeCommit":{"oid":"%s"}}]' "$1" "$2" "$3"; }

# --- 1a. the three merge shapes -------------------------------------------------------------
eq "${ verdict feat/ff '[]'; }" "merged-ff|" "1a fast-forward merge is merged-ff without any PR evidence"
eq "${ vtip feat/ff '[]'; }" "${ fx rev-parse feat/ff; }" "1a line 2 is the tip the verdict was computed from"

# THE #106 REGRESSION: before the fix this branch was invisible to every detector the skill had.
out="${ verdict feat/squash "${ prjson 7 "$SQ_TIP" "$SQ_MERGE"; }"; }"
eq "${out%%|*}" "merged-pr" "1a squash merge is detected via fresh PR evidence + local ancestry (#106)"
has "${out#*|}" "#7" "1a the detail names the PR that proves it"

eq "${ verdict feat/open '[]'; }" "unmerged|" "1a a genuinely unmerged branch is unmerged"

# --- 1b. THE DESTRUCTIVE CASE: new commits after the squash merge ---------------------------
# #106 asks only that mergeCommit.oid be contained in the default branch. That alone still
# matches a branch which was squash-merged and THEN had new work added — deleting it would
# destroy commits that never landed. `headRefOid == tip` is what refuses it.
fx checkout -q feat/squash
fx commit -q --allow-empty -m "new local work after the merge"
fx checkout -q main
eq "${ verdict feat/squash "${ prjson 7 "$SQ_TIP" "$SQ_MERGE"; }"; }" "unmerged|" \
   "1b a branch that gained commits AFTER its squash merge is NOT deletable (headRefOid guard)"
# Restore the fixture for the remaining cases, and prove the refusal was about the extra commit
# and nothing else — otherwise a verdict that always said `unmerged` would pass the case above.
fx update-ref refs/heads/feat/squash "$SQ_TIP"
eq "${ verdict feat/squash "${ prjson 7 "$SQ_TIP" "$SQ_MERGE"; }" | cut -d'|' -f1; }" "merged-pr" \
   "1b …and is deletable again once the extra commit is gone"

# --- 1c. evidence that does not prove anything ----------------------------------------------
# A merged PR whose merge commit is NOT on this default branch (merged into another base, or a
# fork's). Contained-in-base is what makes the evidence local and current.
STRAY="${ fx rev-parse feat/open; }"
eq "${ verdict feat/squash "${ prjson 7 "$SQ_TIP" "$STRAY"; }"; }" "unmerged|" \
   "1c a merge commit NOT contained in the default branch proves nothing"
# A PR for a DIFFERENT head (the [gone]-without-merge shape: someone deleted the remote branch).
eq "${ verdict feat/squash "${ prjson 7 "$OPEN_TIP" "$SQ_MERGE"; }"; }" "unmerged|" \
   "1c a merged PR whose headRefOid is another branch's tip proves nothing"
# mergeCommit: null — GitHub reports this for some merged PRs; it must not crash or delete.
eq "${ verdict feat/squash "${ printf '[{"number":7,"headRefOid":"%s","mergeCommit":null}]' "$SQ_TIP"; }"; }" \
   "unmerged|" "1c mergeCommit: null is tolerated and proves nothing"
# A merge commit the local object store has never seen cannot be tested -> preserve.
eq "${ verdict feat/squash "${ prjson 7 "$SQ_TIP" "0000000000000000000000000000000000000001"; }"; }" \
   "unmerged|" "1c an unfetched merge commit degrades to unmerged, not an error"

# --- 1d. degradation and fail-closed --------------------------------------------------------
# The no-gh / no-remote path #106 requires: byte-identical to pre-#106 behavior.
eq "${ verdict feat/ff ''; }"     "merged-ff|" "1d empty evidence still resolves a fast-forward (no-gh degradation)"
eq "${ verdict feat/open ''; }"   "unmerged|"  "1d empty evidence preserves everything else (no-gh degradation)"
eq "${ verdict feat/open '[]'; }" "unmerged|"  "1d an empty array is a clean negative, not an error"

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
fx checkout -q -b "$ODD"
fx commit -q --allow-empty -m odd
fx checkout -q main
fx merge -q --no-ff "$ODD" -m "merge odd"
fx push -q origin main   # the verdict classifies against origin/main, not the local tip
eq "${ verdict "$ODD" '[]'; }" "merged-ff|" "1d an unusual but valid ref name is handled verbatim"

# ============================ 2. state-verdict: liveness precedence ===========================
sv() { bash "$CL" state-verdict "$@" 2>/dev/null; }

# --- 2a. thread caches ----------------------------------------------------------------------
eq "${ sv threads open; }"    "keep"  "2a a cache for an OPEN PR is never swept"
eq "${ sv threads merged; }"  "stale" "2a a cache for a merged PR is swept"
eq "${ sv threads closed; }"  "stale" "2a a cache for a closed PR is swept"
eq "${ sv threads unknown; }" "keep"  "2a an unreadable PR state fails CLOSED to keep"
sv threads bogus >/dev/null 2>&1; no $? "2a an unrecognised PR state is an error, not a sweep"

# --- 2b. run markers: an OPEN PR outranks branch absence ------------------------------------
# The precedence that matters: after `gh pr create` the branch may be tidied while the run is
# still live. Deciding on branch absence alone would disarm the continuation gate mid-run.
eq "${ sv marker open 0 0; }"    "keep"  "2b an OPEN PR keeps the marker even with both refs gone"
eq "${ sv marker merged 0 0; }"  "stale" "2b a merged PR with both refs gone is a finished run"
eq "${ sv marker none 1 0; }"    "keep"  "2b a surviving LOCAL ref keeps the marker"
eq "${ sv marker none 0 1; }"    "keep"  "2b a surviving REMOTE ref keeps the marker"
eq "${ sv marker none 0 0; }"    "stale" "2b no PR and both refs gone is a finished run"
eq "${ sv marker unknown 0 0; }" "keep"  "2b an unreadable PR state fails CLOSED to keep"
eq "${ sv marker none unknown 0; }" "keep" "2b an unreadable local ref fails CLOSED to keep"
eq "${ sv marker none 0 unknown; }" "keep" "2b an unreadable remote ref fails CLOSED to keep"
sv marker open 0 >/dev/null 2>&1;      no $? "2b a marker verdict with too few facts is an error"
sv marker open 0 2 >/dev/null 2>&1;    no $? "2b a non-boolean ref fact is an error"

# --- 2c. gap artifacts: the in-flight lock outranks everything -------------------------------
# Gap analysis runs BEFORE the branch and marker exist, so during a live pass there is no marker
# to consult; without the lock the artifacts read as a finished run's leftovers and /cleanup
# would delete findings a dispatch is still writing.
eq "${ sv gaps 1 none; }"  "keep"  "2c the in-flight lock keeps gap artifacts with no marker at all"
eq "${ sv gaps 1 stale; }" "keep"  "2c the lock outranks even a finished run's marker"
eq "${ sv gaps 0 keep; }"  "keep"  "2c a live run keeps its gap artifacts"
eq "${ sv gaps 0 stale; }" "stale" "2c a finished run's gap artifacts are swept"
eq "${ sv gaps 0 none; }"  "stale" "2c no lock and no marker means nothing owns them"
sv gaps 2 none >/dev/null 2>&1;  no $? "2c a non-boolean lock is an error"
sv gaps 0 bogus >/dev/null 2>&1; no $? "2c an unrecognised run word is an error"
# Every argument is validated BEFORE any short-circuit. Without that, the lock arm returns `keep`
# and exits 0 for `gaps 1 <typo>` — a workflow typo reading as a considered verdict.
sv gaps 1 bogus >/dev/null 2>&1; no $? "2c …even when the lock would short-circuit the decision"
sv nosuchkind 0 >/dev/null 2>&1; no $? "2c an unknown kind is an error"

# --- 2c2. review artifacts: the run marker alone, and NO lock argument (#264) -----------------
# The deliberate asymmetry with `gaps`. Review is written in /implement-issue step 8, AFTER step 5
# has written the marker and while the run's branch still exists, so the window the gap lock exists
# for has no counterpart — the marker IS the in-flight signal for every reachable write. What the
# caller owes in exchange is that the <run> word is read at the moment of the delete; the source
# pins in section 6 are what hold that end up.
eq "${ sv review keep; }"  "keep"  "2c2 a live run keeps its review artifacts"
eq "${ sv review stale; }" "stale" "2c2 a finished run's review artifacts are swept"
eq "${ sv review none; }"  "stale" "2c2 no marker at all means nothing owns them (#264's own case)"
# ARITY IS THE CONTRACT, and it is what stops the two arms being confused for each other. A
# `review` that tolerated a stray extra argument would silently accept `review "$LOCK" "$RUN"` —
# the gaps call shape — and decide on the LOCK, which for review is always 0: every artifact swept
# on every run, including mid-review.
sv review >/dev/null 2>&1;            no $? "2c2 review with no run word is an error"
sv review 0 none >/dev/null 2>&1;     no $? "2c2 …and the gaps ARITY is refused, never silently re-read"
sv review keep keep >/dev/null 2>&1;  no $? "2c2 …as is any extra argument"
sv review bogus >/dev/null 2>&1;      no $? "2c2 an unrecognised run word is an error"
sv review 1 >/dev/null 2>&1;          no $? "2c2 a lock-shaped argument is not a run word"

# --- 2d. marker-branch: one reader, used by both the scan and the delete-time re-read ---------
printf '{"branch":"issue-5-x","phase":"pushed"}' > "$work/m-ok.json"
printf 'not json'                                > "$work/m-bad.json"
printf '{"phase":"pushed"}'                      > "$work/m-nobranch.json"
eq "$(bash "$CL" marker-branch "$work/m-ok.json")"       "issue-5-x" "2d marker-branch reads the recorded branch"
eq "$(bash "$CL" marker-branch "$work/m-bad.json")"      ""          "2d an unreadable marker yields empty, not an error"
eq "$(bash "$CL" marker-branch "$work/m-nobranch.json")" ""          "2d a marker with no branch key yields empty"
eq "$(bash "$CL" marker-branch "$work/nope.json")"       ""          "2d a missing marker yields empty"
bash "$CL" marker-branch >/dev/null 2>&1; no $? "2d marker-branch requires a path"

# marker-identity — the delete-time race guard. It must change when the FILE changes, even when
# the recorded branch does not: retrying an issue whose branch was already swept writes the same
# deterministic `issue-NN-slug`, so a branch-only comparison would delete a live run's marker.
ID1="$(bash "$CL" marker-identity "$work/m-ok.json")"
[ -n "$ID1" ] && ok || bad "2d marker-identity produces an identity for a readable marker"
eq "$(bash "$CL" marker-identity "$work/m-ok.json")" "$ID1" "2d marker-identity is stable for an unchanged file"
printf '{"branch":"issue-5-x","phase":"branched"}' > "$work/m-ok.json"   # SAME branch, new run
hasnt "$(bash "$CL" marker-identity "$work/m-ok.json")" "$ID1" \
   "2d …and CHANGES when the file is replaced, even with an identical branch name"
eq "$(bash "$CL" marker-identity "$work/nope.json")" "" "2d a missing marker yields no identity (never matches)"
bash "$CL" marker-identity >/dev/null 2>&1; no $? "2d marker-identity requires a path"

# --- 2e. clone-state: the switch/pull guard ---------------------------------------------------
# A clean `git status` is NOT proof it is safe to switch — this is what step 1 branches on.
eq "$(bash "$CL" clone-state "$R" main)" "local-ok" "2e a clean clone on the default branch is safe to switch/pull"
bash "$CL" clone-state "$R" >/dev/null 2>&1;         no $? "2e clone-state requires both arguments"
eq "$(bash "$CL" clone-state "$work" main)" "not-a-repo" "2e a non-repo is classified, not crashed on"

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
: > "$S/review-prompt.txt"
: > "$S/review.md"
: > "$S/review.err"
: > "$S/review-codex.md"
: > "$S/review-gemini.err"
: > "$S/review.txt"
: > "$S/review-foo.txt"
: > "$S/review.md.bak"
: > "$S/reviewer.md"
: > "$S/pr-body.md"
: > "$S/some-other-skill.json"
: > "$S/.marker.tmp"
printf '{"branch":"issue-9-thing","issue":"9","phase":"pushed"}' > "$S/implement-issue-active.json"
scan="$(bash "$CL" state-scan "$S")"
kindof() { printf '%s\n' "$scan" | awk -F'\t' -v b="$1" '{n=split($2,p,"/"); if (p[n]==b) print $1}'; }

eq "${ kindof threads-41.json; }"              "threads" "3 a numbered thread cache is classified"
eq "${ kindof threads-9.json; }"               "threads" "3 …including a single-digit PR number"
eq "${ kindof threads-notanumber.json; }"      "other"   "3 a thread-shaped name with no PR number is NOT ours to delete"
eq "${ kindof implement-issue-active.json; }"  "marker"  "3 the active run marker is classified"
eq "${ kindof gap-analysis.lock; }"            "lock"    "3 the in-flight lock is classified"
eq "${ kindof gaps.err; }"                     "gaps"    "3 gap artifacts are classified"
eq "${ kindof gaps-retry.err; }"               "gaps"    "3 …including the gaps-retry.* debris #84 names"
eq "${ kindof gap-prompt.txt; }"               "gaps"    "3 …and the prompt, which carries private repo context"
# #264: the three names /implement-issue step 8 actually writes, all of which used to fall through
# to `other` and therefore lived forever.
eq "${ kindof review-prompt.txt; }"            "review"  "3 the review prompt is classified (#264)"
eq "${ kindof review.md; }"                    "review"  "3 …the reviewer's findings"
eq "${ kindof review.err; }"                   "review"  "3 …and the captured exploration stream"
eq "${ kindof review-codex.md; }"              "review"  "3 …plus the per-slot family the glob anticipates"
eq "${ kindof review-gemini.err; }"            "review"  "3 …on both suffixes"
# The ALLOWLIST property, tested from the side that costs something: a near-miss must NOT become
# sweepable. `state-scan` widening by accident is how a sweep starts eating files it never owned,
# and the failure would look like corruption rather than a cleanup.
eq "${ kindof review.txt; }"                   "other"   "3 a review-shaped name outside the family is NOT swept"
eq "${ kindof review-foo.txt; }"               "other"   "3 …nor is a family prefix with the wrong suffix"
eq "${ kindof review.md.bak; }"                "other"   "3 …nor a backup of one"
eq "${ kindof reviewer.md; }"                  "other"   "3 …nor a longer word that merely starts with 'review'"
# Named explicitly because #264 puts it out of scope: pr-body.md is the AGENT's filename, not one
# the shipped workflow writes, so the fix must not have quietly made it sweepable.
eq "${ kindof pr-body.md; }"                   "other"   "3 pr-body.md stays 'other' — #264 scopes it out"
eq "${ kindof some-other-skill.json; }"        "other"   "3 an unrecognised file is 'other' — never swept"
eq "${ kindof .marker.tmp; }"                  "other"   "3 a staged temp file is seen, and is 'other'"
# The marker's key is its recorded branch — that is what the liveness read is done against.
eq "${ printf '%s\n' "$scan" | awk -F'\t' '$1=="marker"{print $3}'; }" "issue-9-thing" \
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
eq "${ printf '%s\n' "$typical" | grep -c .; }" "3" "4 a typical sweep emits exactly 3 lines (#84 acceptance)"
has "$typical" "threads-{41,47,51,57,59,65,68,72,76}.json" "4 a run of numbered files compresses to one brace group"
has "$typical" "main: clean, in sync with origin/main"     "4 the --tail state line is always last"
hasnt "$typical" "(0)" "4 no zero-count section appears"
hasnt "$typical" "Deleted (remote)" "4 a category with no records cannot appear at all"

# Empty input is a sweep that changed nothing: the state line alone, never a "nothing to do" essay.
eq "${ printf '' | rep --tail 'main: clean, in sync with origin/main'; }" "main: clean, in sync with origin/main" \
   "4 a no-op sweep emits only the state line"

# Ordering is the caller's, never sorted — the report must match what scrolled past.
eq "${ printf 'C\tz-9.txt\nC\tz-2.txt\nC\tz-40.txt\n' | rep; }" "C: z-{9,2,40}.txt" \
   "4 grouping preserves first-seen order and never sorts (numerically or otherwise)"
# Distinct prefixes are distinct families even inside one category, and keep their own order.
eq "${ printf 'C\tz-1.txt\nC\ta-2.txt\n' | rep; }" "C: z-1.txt, a-2.txt" \
   "4 different prefixes do not get merged into one brace group"
# Items that do not fit the numeric pattern pass through verbatim, in place.
eq "${ printf 'C\tgaps.md\nC\tgaps.err\n' | rep; }" "C: gaps.md, gaps.err" \
   "4 non-numeric items pass through verbatim"
# Two distinct families in one category stay distinct.
eq "${ printf 'C\tthreads-1.json\nC\tthreads-2.json\nC\tgaps.md\n' | rep; }" "C: threads-{1,2}.json, gaps.md" \
   "4 separate families group separately"
# A lone member of a family must NOT gain braces.
eq "${ printf 'C\tthreads-1.json\n' | rep; }" "C: threads-1.json" "4 a single item never gains a brace group"
# The group/verbatim discriminator must be the FACT that split3 matched, not the shape of the
# key. A sentinel-prefix test misfires on an item whose own prefix starts with the sentinel —
# and `git check-ref-format` accepts a branch name beginning with `@`.
eq "${ printf 'C\t@foo-1.txt\nC\t@foo-2.txt\n' | rep; }" "C: @foo-{1,2}.txt" \
   "4 an item whose prefix starts with the sentinel character still groups correctly"
eq "${ printf 'C\t@a.txt\nC\t@b.txt\n' | rep; }" "C: @a.txt, @b.txt" \
   "4 …and ungroupable sentinel-prefixed items still render verbatim"
rep --tail >/dev/null 2>&1; no $? "4 --tail without a value is an error"
rep --bogus >/dev/null 2>&1; no $? "4 an unknown report option is an error"

# ============================ 5. state-line: it must never lie ================================
# The terse contract makes this the ONLY state the operator is shown, so a hardcoded
# "clean, in sync" would be actively misleading in every non-clean case.
sl() { bash "$CL" state-line "$R" main 2>/dev/null; }
# Section 1 merged into main without pushing, so bring the fixture to the clean/in-sync state
# this first case is actually about.
fx push -q origin main
has "${ sl; }" "clean, in sync" "5 a clean, synced default branch says so"
( cd "$R" && git checkout -q feat/open )
has "${ sl; }" "still on feat/open" "5 a run that never returned to the default branch says which branch it is on"
( cd "$R" && git checkout -q main )
: > "$R/dirty.txt"
has "${ sl; }" "DIRTY" "5 a dirty tree is reported, not papered over"
rm -f "$R/dirty.txt"
( cd "$R" && git commit -q --allow-empty -m unpushed )
has "${ sl; }" "unpushed" "5 unpushed commits on the default branch are reported"
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
  # The EXECUTABLE half only. Several assertions below must not match the guardrail prose, which
  # legitimately names the commands it forbids ("never `git branch -D`") — a whole-file match
  # would flag the rule for stating what it rules out.
  wfcode="$(awk '/^```bash$/ { inb = 1; next } /^```$/ { inb = 0; next } inb' "$WF")"
  # …and, for "this command is never RUN" assertions, the same text with shell comments dropped.
  # The fenced blocks explain which commands they deliberately avoid and why, so a plain wfcode
  # match would fail on the very comment documenting the avoidance.
  wfexec="${ printf '%s\n' "$wfcode" | sed 's/[[:space:]]*#.*$//'; }"
  has "$wf" '{{CLEANUP_LIB}} branch-verdict' "6 the workflow classifies branches through the library"
  has "$wf" '{{CLEANUP_LIB}} state-scan'     "6 the workflow enumerates state through the library"
  has "$wf" '{{CLEANUP_LIB}} state-verdict'  "6 the workflow decides state through the library"
  has "$wf" '{{CLEANUP_LIB}} report'         "6 the workflow renders through the report contract"
  has "$wf" 'git update-ref -d "refs/heads/$b" "$TIP"' \
     "6 every local delete is an expected-OID compare-and-delete"
  # `git branch -d`'s refusal tests merged-into-UPSTREAM, not merged-into-$BASE, so a branch that
  # gained a pushed commit after being classified still satisfies it. Not used, even for the
  # fast-forward case — the expected-OID delete is the stronger check.
  hasnt "$wfexec" 'git branch -d' "6 …including the fast-forward case, which never falls back to git branch -d"
  has "$wfcode" 'git config --remove-section "branch.$b"' \
     "6 the ref delete also drops branch.<name>.* so a later branch cannot inherit a stale upstream"
  # THE guardrail: `-D` deletes whatever is there now, on a decision made earlier.
  hasnt "$wfcode" 'git branch -D' "6 no fenced command in the workflow escalates to git branch -D"
  has "$wfcode" 'git update-ref -d' "6 …and the expected-OID delete really is in an executable block"
  has "$wf" '--limit 20' "6 the merged-PR query is paginated explicitly, so evidence cannot fall off page 1"
  # The lock's FILENAME is spelled in the library (state-scan) and in /implement-issue, never a
  # third time here: the workflow reads the `lock` kind out of the scan. A second hardcoded path
  # would set LOCK=0 after a rename and delete a live dispatch's findings.
  has "$wf" 'grep -q "^lock' "6 the workflow reads the in-flight lock from the scan, not a second hardcoded path"
  hasnt "$wfcode" '-f "$STATE/gap-analysis.lock"' "6 …and does not re-spell the lock filename"
  has "$wf" 'worktree list' "6 branches checked out in another worktree are excluded during enumeration"
  # WHOLE-LINE membership, and it must stay that way. `git update-ref -d` (unlike `git branch -d`)
  # WILL delete a branch checked out in another worktree, so this test is the only thing standing
  # between the new delete path and that outcome — and the "cheaper" builtin form silently
  # degrades to a substring match, because `NL="$(printf '\n')"` is the empty string.
  has "$wfcode" 'grep -Fxq "$b"' "6 the worktree exclusion matches whole lines, not substrings"
  # An AND-list as the last command leaves the whole fenced block on exit status 1 whenever its
  # test fails — and "no lock present" is the common case, so a healthy sweep would read as a
  # failed step and could be abandoned before any state is swept.
  hasnt "$wfcode" 'grep -q "^lock${TABC}" && LOCK=1' "6 the lock probe does not leave its block on a non-zero status"
  # An unguarded `git switch` fails when the default branch is checked out in another worktree,
  # and the fast-forward on the next line would then repoint the USER'S feature branch.
  has "$wfcode" 'SWITCHED=0' "6 the switch to the default branch is guarded before any fast-forward"
  # Identity, not `.branch`: retrying an issue whose branch was already swept writes the SAME
  # deterministic `issue-NN-slug`, so a branch-only comparison reports "unchanged" for a
  # different, live run's marker and deletes it.
  has "$wf" '{{CLEANUP_LIB}} marker-identity' "6 the delete-time marker guard compares file identity, not just the branch"
  has "$wfcode" 'STATE="$ROOT/' "6 the state dir is anchored at the repo root, not the current directory"
  # $SCAN/$LOCK are captured before a marker pass that makes live PR round trips; a new run can
  # take the lock in that window and start writing the same gap filenames.
  has "$wfcode" 'SCAN="$({{CLEANUP_LIB}} state-scan "$STATE")"' "6 the scan is re-taken before any destructive state delete"
  eq "${ printf '%s\n' "$wfcode" | grep -c 'state-scan "\$STATE"'; }" "2" \
     "6 …i.e. the lock governing a delete is the one true AT the delete, not at classification"
  has "$wfcode" 'sweep_file' "6 state deletions report their failures instead of silently continuing"
  # --- #264: the review family is swept, and on ITS OWN liveness signal --------------------
  has "$wfcode" '{{CLEANUP_LIB}} state-verdict review' "6 review artifacts are decided through the library, not inline"
  # The SWEEP arm's own body, not a bare `review)` — the LARGE arm below it opens a `review)` case
  # too, so the bare token stays matched even when the deletion arm is gone entirely (observed).
  has "$wfcode" '[ "$RV" = stale ] || continue' "6 …and the sweep loop has an arm that acts on the verdict"
  # THE decision this issue asked for, pinned as a NEGATIVE. `state-verdict review "$RUN"` is the
  # obvious-looking call and the wrong one: $RUN is decided before a marker pass that makes live PR
  # round trips, so it is exactly the stale signal the re-scan exists to replace. Nothing else in
  # the suite can see that substitution — both spellings run, both print a verdict.
  hasnt "$wfexec" 'state-verdict review "$RUN"' "6 …decided from the FRESH scan, never the pre-pass \$RUN"
  has "$wfcode" 'RUN_NOW=none' "6 the fresh-scan marker probe fails closed to 'no run' before it reads"
  has "$wfcode" 'grep -q "^marker' "6 …and reads liveness from the scan, not a second hardcoded marker path"
  # Same AND-list hazard the lock probe already carries a pin for: "no marker present" is the
  # common case right after a merge, so the compound form would leave a healthy sweep on status 1.
  hasnt "$wfcode" 'grep -q "^marker${TABC}" && RUN_NOW=keep' "6 the marker probe does not leave its block on a non-zero status"
  # The LARGE arm must gate on the review verdict, not the gap one — otherwise a kept review.err
  # is reported under a live GAP dispatch's liveness, naming the wrong run.
  has "$wfcode" 'review) [ "$RV" = keep ]' "6 a kept review stream is reported under its own verdict, not \$GV"
  # …and it must read its paths from the scan. A `"$STATE"/review-*.err` glob here is left literal
  # by POSIX shells but ABORTS the command under zsh's default `nomatch` — macOS's shell — so the
  # whole size report would silently not happen. Same class as the #125 zsh bug this file guards.
  hasnt "$wfcode" '"$STATE"/review-*.err' "6 …and enumerates streams from the scan, not a glob zsh's nomatch would abort"
  hasnt "$wfcode" '"$STATE"/gaps-*.err'   "6 …which applies to the gap streams it already reported"
  has "$wf" '{{CLEANUP_LIB}} clone-state' \
     "6 the switch/pull guard uses the clone classifier, not a porcelain-only test (rebase/bisect leave it clean)"
  hasnt "$wfcode" 'git pull --ff-only' \
     "6 the fast-forward consumes the fetch already done, rather than a second network round trip"
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
  # ORDER is the contract. The lock must be taken BEFORE gap-prompt.txt exists: a /cleanup landing
  # in between classifies that prompt as a gap artifact, sees no lock and no marker (step 5 owns
  # markers), and deletes it — after which the dispatch's redirection fails and reads as a codex
  # error. Writing the prompt with a file-write tool makes that window a whole agent turn.
  iitake="${ printf '%s\n' "$ii" | grep -n ': > {{STATE_DIR}}/gap-analysis.lock' | head -n1 | cut -d: -f1; }"
  iiprompt="${ printf '%s\n' "$ii" | grep -n 'cat > {{STATE_DIR}}/gap-prompt.txt' | head -n1 | cut -d: -f1; }"
  if [ -n "$iitake" ] && [ -n "$iiprompt" ] && [ "$iitake" -lt "$iiprompt" ]; then ok; else
    bad "6 the lock must be taken BEFORE gap-prompt.txt is written (take@${iitake:-?} prompt@${iiprompt:-?})"
  fi
  # The release must NOT sit in the same fenced block as the dispatch: that block is dispatched
  # to the harness's DETACHED facility, so a release appended to it drops the lock immediately
  # and leaves it unheld for the whole pass — the only window it exists for.
  iidisp="${ printf '%s\n' "$ii" | grep -n '{{ROLE_DISPATCH}} invoke gap_analysis' | head -n1 | cut -d: -f1; }"
  iirel="${ printf '%s\n' "$ii" | grep -n 'rm -f {{STATE_DIR}}/gap-analysis.lock' | tail -n1 | cut -d: -f1; }"
  iifence="${ printf '%s\n' "$ii" | awk -v d="${iidisp:-0}" 'NR > d && /^```$/ { print NR; exit }'; }"
  if [ -n "$iirel" ] && [ -n "$iifence" ] && [ "$iirel" -gt "$iifence" ]; then ok; else
    bad "6 the lock release must be in a separate fenced block after the detached dispatch (release@${iirel:-?} block-end@${iifence:-?})"
  fi

  # --- #264: preflight clears the review family, in PREFLIGHT ---------------------------------
  # A filename-presence pin would be worthless here: all three names already appear in this file at
  # their step-8 WRITE sites, so `has "$ii" 'review.err'` passed before the fix existed and would
  # keep passing after a revert. What is pinned is the `rm -f` LINE, and where it sits.
  iiclear="${ printf '%s\n' "$ii" | grep -n 'rm -f {{STATE_DIR}}/review-prompt.txt' | head -n1 | cut -d: -f1; }"
  iirevwrite="${ printf '%s\n' "$ii" | grep -n 'cat > {{STATE_DIR}}/review-prompt.txt' | head -n1 | cut -d: -f1; }"
  if [ -n "$iiclear" ] && [ -n "$iirevwrite" ] && [ "$iiclear" -lt "$iirevwrite" ]; then ok; else
    bad "6 preflight must clear review-prompt.txt BEFORE step 8 writes it (clear@${iiclear:-?} write@${iirevwrite:-?})"
  fi
  # …and it must be in PREFLIGHT, which is a stronger claim than "earlier than the write" and has
  # to be asserted separately: a clear sitting one line ABOVE the step-8 write satisfies the test
  # above while clearing nothing stale and truncating nothing useful. Anchoring on step 3's lock
  # take puts it in step 1 — beside the marker and gap clears — without pinning a line number.
  # Observed: without this, moving the clear down to step 8 left the suite green.
  if [ -n "$iiclear" ] && [ -n "$iitake" ] && [ "$iiclear" -lt "$iitake" ]; then ok; else
    bad "6 …and that clear belongs in PREFLIGHT, before step 3 dispatches (clear@${iiclear:-?} step3@${iitake:-?})"
  fi
  # Every name the `review` arm of state-scan can sweep must also be a name preflight clears. The
  # two halves drifting apart is not cosmetic: a file /cleanup will delete but preflight will not
  # refresh is a stale artifact that a NEW run's marker makes read as live — the exact
  # stale-findings-look-current trap #264 is about, reintroduced through the back door.
  iiclearline="${ printf '%s\n' "$ii" | sed -n "${iiclear:-0},$((${iiclear:-0} + 1))p"; }"
  for rname in 'review-prompt.txt' 'review.md' 'review.err' 'review-*.md' 'review-*.err'; do
    has "$iiclearline" "{{STATE_DIR}}/$rname" "6 …and clears $rname, matching state-scan's review family"
  done
fi

# ==================== 7. the currency step, EXECUTED (#139) ==================================
# The point of this section is that it RUNS the documented snippet rather than grepping for a
# token. #139's whole failure mode was a currency mechanism that looked wired and never fired, so
# a test asserting "the workflow mentions currency-lib" would reproduce the bug it is guarding.
# The snippet is extracted from base/workflows/cleanup.md by its ADB-SNIPPET marker and executed
# with {{CURRENCY_LIB}} resolved exactly as scripts/build.sh resolves it for a real agent.

cuw="$work/cu"
mkdir -p "$cuw"
CU="$ROOT/scripts/lib/currency-lib.sh"
# adb_agent_manifest builds the fixture's stub set; re-read the workflow here rather than reuse
# $wf, which is only set inside section 6's `else` branch.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/common.sh"
cuwf="$(<"$WF")"

# --- fixture: an install-source clone, pre-linked into a fake HOME ---------------------------
# Deliberately close to check-session-currency.sh's fixture; #118 tracks sharing them.
cuseed="$cuw/seed"
mkdir -p "$cuseed/bin" "$cuseed/scripts/lib" "$cuseed/agents/claude/skills/demo" "$cuseed/agents/claude/scripts"
cp "$ROOT/bin/baseline" "$cuseed/bin/baseline"; chmod +x "$cuseed/bin/baseline"
for lib in common.sh currency-lib.sh cleanup-lib.sh; do
  cp "$ROOT/scripts/lib/$lib" "$cuseed/scripts/lib/$lib"
done
cat > "$cuseed/install.sh" <<CUSTUB
#!/usr/bin/env bash
_r="\$(cd "\$(dirname "\$0")" && pwd)"
. "\$_r/scripts/lib/common.sh"
adb_agent_manifest claude "\$_r" "\$HOME" | while IFS="\$(printf '\\t')" read -r s d; do
  [ -n "\$s" ] && [ -n "\$d" ] || continue
  [ -e "\$d" ] && continue
  mkdir -p "\$(dirname "\$d")"
  ln -sfn "\$s" "\$d"
done
CUSTUB
chmod +x "$cuseed/install.sh"
printf 'root doc\n' > "$cuseed/agents/claude/CLAUDE.md"
printf 'demo skill\n' > "$cuseed/agents/claude/skills/demo/SKILL.md"
# Stub every OTHER script the manifest expects, enumerated from the manifest itself: `baseline
# update` verifies the full manifest, so a script added there but missing here would fail this
# fixture in a way that looks like a bin/baseline bug.
mapfile -t cunames < <(adb_agent_manifest claude "$cuseed" "$cuw/unused" | cut -f1 \
  | sed -n "s|^$cuseed/agents/claude/scripts/||p")
check_enumerated "claude script manifest (cleanup fixture)" "${cunames[@]}"
for sname in "${cunames[@]}"; do
  [ -e "$cuseed/agents/claude/scripts/$sname" ] || printf '#stub\n' > "$cuseed/agents/claude/scripts/$sname"
done

cuorigin="$cuw/origin.git"
# check_make_repo_pair + check_git rather than a fourth hand-rolled identity wrapper: check_git
# also sets commit.gpgsign=false, which is exactly the gap check-lib.sh:120-126 exists to close.
check_make_repo_pair "$cuseed" "$cuorigin" || bad "7 currency fixture: init failed"
check_git "$cuseed" checkout -q -b main
check_git "$cuseed" add -A
check_git "$cuseed" commit -q -m seed
check_git "$cuseed" push -q -u origin main
# Point the SEED's and the BARE origin's HEAD at main explicitly, exactly as
# check-session-currency.sh:76,80 does. Both are created by `git init`, which takes its branch name
# from `init.defaultBranch` — so on a host configured for `master` (CI's shape, and git's own
# built-in default on older versions) the bare repo's HEAD names a ref that was never pushed. Every
# clone below then comes up with NO local `main`, and the first `push origin main` fails with
# "src refspec main does not match any" — which is exactly how this passed locally, where the
# default happens to be `main`, and failed in CI.
git -C "$cuseed" symbolic-ref HEAD refs/heads/main
git -C "$cuorigin" symbolic-ref HEAD refs/heads/main

cusrc="$cuw/src"; git clone -q "$cuorigin" "$cusrc"
cufh="$cuw/home"; mkdir -p "$cufh"
HOME="$cufh" bash "$cusrc/install.sh" >/dev/null 2>&1
cusrcgit="$(git -C "$cusrc" rev-parse --absolute-git-dir)"
# A second clone drives origin forward, so $cusrc can be made genuinely behind.
cuc2="$cuw/c2"; git clone -q "$cuorigin" "$cuc2"

cu_advance() {
  check_git "$cuc2" commit -q --allow-empty -m "$1"
  check_git "$cuc2" push -q origin main
}
cu_head() { git -C "$cusrc" rev-parse --short HEAD; }
cu_reset() {
  git -C "$cusrc" checkout -q main 2>/dev/null || git -C "$cusrc" checkout -q -B main
  git -C "$cusrc" fetch -q origin
  git -C "$cusrc" reset -q --hard origin/main
  git -C "$cusrc" clean -qfd
  rm -rf "${cuw:?}/cache"
  rm -rf "${cusrcgit:?}/adb-update.lock"
}

# --- the extractor: run the DOCUMENTED snippet ------------------------------------------------
# Extracted ONCE: the snippet cannot change mid-suite, and re-awking a 600-line file on each of the
# 13 runs below bought nothing. A missing marker also fails once here instead of thirteen times.
CU_SNIPPET="${ check_wf_snippet "$WF" currency; }"
[ -n "$CU_SNIPPET" ] || bad "7 snippet 'currency' not found in base/workflows/cleanup.md (marker removed or renamed?)"
# run_currency [cwd] — execute the snippet; sets CU_RC, CU_OUT_OUTCOME, CU_OUT_LINE.
# CU_MODE / CU_INTERVAL are the knobs, mirroring check-session-currency.sh's MODE_ENV.
CU_MODE=""
run_currency() {
  local cwd="${1:-$cuw/elsewhere}" code out
  mkdir -p "$cwd"
  code="${CU_SNIPPET//\{\{CURRENCY_LIB\}\}/bash \"$CU\"}"
  # The snippet must be self-contained: nothing is pre-set except a cwd, exactly as the workflow
  # claims (it re-resolves ROOT itself). Trailing echoes expose what the workflow computed.
  # No ADB_SESSION_UPDATE_INTERVAL_SECS: the `cleanup` trigger ignores the interval by design, so
  # threading a knob for it would only suggest the value matters here. Test (b) proves the bypass by
  # writing a real, fresh stamp instead.
  out="$(cd "$cwd" && env HOME="$cufh" XDG_CACHE_HOME="$cuw/cache" \
        ADB_SESSION_UPDATE="$CU_MODE" \
        bash -c "$code
printf 'OUTCOME=%s\n' \"\$CU_OUTCOME\"
printf 'LINE=%s\n' \"\$CU_LINE\"" 2>/dev/null)"
  CU_RC=$?
  CU_OUT_OUTCOME="${ printf '%s\n' "$out" | sed -n 's/^OUTCOME=//p' | head -n1; }"
  CU_OUT_LINE="${ printf '%s\n' "$out" | sed -n 's/^LINE=//p' | head -n1; }"
}

# --- the PURE predicates, offline ---------------------------------------------------------------
# `check` is an executor and every case below drives it end-to-end against a real clone. These three
# subcommands are the decisions inside it that need no network, and they are public precisely so they
# can be pinned without one — the library header says so, so it owes these tests.
eq "$(ADB_SESSION_UPDATE=off     bash "$CU" mode)" "off"    "7 mode: the env override wins"
eq "$(ADB_SESSION_UPDATE=notify  bash "$CU" mode)" "notify" "7 mode: notify is honored"
eq "$(ADB_SESSION_UPDATE=auto    bash "$CU" mode)" "auto"   "7 mode: auto is honored"
# A misspelled mode must degrade to the documented default, never disable the updater by accident.
eq "$(ADB_SESSION_UPDATE=nonsense bash "$CU" mode)" "auto"  "7 mode: an unrecognized value degrades to auto"
eq "$(HOME="$cuw/nohome" ADB_SESSION_UPDATE="" bash "$CU" mode)" "auto" "7 mode: no manifest at all degrades to auto"

# stamp-fresh: exit 0 means SUPPRESSED. Interval 0 disables the limit; a missing stamp means "not
# suppressed", because a redundant fetch is the safe direction and an indefinitely suppressed check
# is the failure #139 is about.
cu_stamp="$cuw/probe.stamp"; : > "$cu_stamp"
if bash "$CU" stamp-fresh "$cu_stamp" 600; then ok; else bad "7 stamp-fresh: a fresh stamp suppresses"; fi
if bash "$CU" stamp-fresh "$cu_stamp" 0; then bad "7 stamp-fresh: interval 0 must never suppress"; else ok; fi
if bash "$CU" stamp-fresh "$cuw/absent.stamp" 600; then bad "7 stamp-fresh: a missing stamp must not suppress"; else ok; fi
bash "$CU" stamp-fresh "$cu_stamp" x >/dev/null 2>&1; eq "$?" "2" "7 stamp-fresh: a non-numeric interval fails closed (2)"

# same-clone compares git COMMON dirs, so a subdirectory and a linked worktree of one repo match
# while two unrelated repos do not. This is the guard that stops an update under active work.
if bash "$CU" same-clone "$cusrc" "$cusrc"; then ok; else bad "7 same-clone: a clone matches itself"; fi
if bash "$CU" same-clone "$cusrc/scripts" "$cusrc"; then ok; else bad "7 same-clone: a subdirectory matches its repo"; fi
if bash "$CU" same-clone "$cusrc" "$cuc2"; then bad "7 same-clone: two clones of one origin must NOT match"; else ok; fi
if bash "$CU" same-clone "$cuw" "$cusrc"; then bad "7 same-clone: a non-repo must not match"; else ok; fi
if git -C "$cusrc" worktree add -q "$cuw/src-wt" -b cu-wt 2>/dev/null; then
  if bash "$CU" same-clone "$cuw/src-wt" "$cusrc"; then ok; else bad "7 same-clone: a linked WORKTREE matches its repo"; fi
  git -C "$cusrc" worktree remove --force "$cuw/src-wt" 2>/dev/null
  git -C "$cusrc" branch -D cu-wt >/dev/null 2>&1
fi

# (a) the core acceptance: a behind clone is updated, and the step reports one line.
cu_reset; cu_advance "cu-behind"
cu_before="${ cu_head; }"
run_currency
eq "$CU_RC" "0" "7 currency: the snippet exits 0"
eq "$CU_OUT_OUTCOME" "updated" "7 currency: a behind install-source is updated"
has "$CU_OUT_LINE" "updated" "7 currency: the reported line names the update"
if [ "${ cu_head; }" != "$cu_before" ]; then ok; else bad "7 currency: the clone did not advance"; fi

# (b) THE #139 PROPERTY: a fresh stamp must NOT suppress the deliberate check. This is the whole
# reason the cleanup trigger reads the interval differently — /cleanup runs right after a merge,
# which is exactly when the stamp is freshest and the clone is most likely stale.
cu_reset
mkdir -p "$cuw/cache/ai-dev-baseline"; : > "$cuw/cache/ai-dev-baseline/session-currency.stamp"
cu_advance "cu-stamp-bypass"
cu_before="${ cu_head; }"
run_currency
eq "$CU_OUT_OUTCOME" "updated" "7 currency: a FRESH stamp does not suppress the /cleanup check (#139)"
if [ "${ cu_head; }" != "$cu_before" ]; then ok; else bad "7 currency: a fresh stamp wrongly suppressed the update"; fi

# ...and it still WRITES the stamp, so the next session start is suppressed by it.
if [ -f "$cuw/cache/ai-dev-baseline/session-currency.stamp" ]; then ok; else
  bad "7 currency: the shared stamp was not refreshed"
fi

# (c) already current -> silent. The terse contract means no line at all.
cu_reset
run_currency
eq "$CU_OUT_OUTCOME" "silent" "7 currency: an already-current install is silent"
eq "$CU_OUT_LINE" "" "7 currency: silence means no line"

# (d) mode=off disables THIS trigger too, not just the hook.
cu_reset; cu_advance "cu-off"
cu_before="${ cu_head; }"
CU_MODE=off; run_currency; CU_MODE=""
eq "$CU_OUT_OUTCOME" "skipped" "7 currency: mode=off skips"
eq "$CU_OUT_LINE" "" "7 currency: mode=off prints nothing"
eq "${ cu_head; }" "$cu_before" "7 currency: mode=off never touches the clone"

# (e) notify reports 'behind' and changes nothing on disk.
cu_reset; cu_advance "cu-notify"
cu_before="${ cu_head; }"
CU_MODE=notify; run_currency; CU_MODE=""
eq "$CU_OUT_OUTCOME" "behind" "7 currency: notify reports behind"
has "$CU_OUT_LINE" "behind" "7 currency: the notify line says behind"
eq "${ cu_head; }" "$cu_before" "7 currency: notify never pulls"

# (e2) notify + an UNREACHABLE remote must still report offline. Bot review, PR #145: notify
# branched on the prose word with a catch-all, so `--check`'s `fetch-failed` (exit 30) fell through
# to `silent` — /cleanup printed nothing, indistinguishable from a verified-current install, while
# its contract explicitly says an unreachable remote is reported because the operator asked.
cu_reset
git -C "$cusrc" remote set-url origin "$cuw/does-not-exist.git"
CU_MODE=notify; run_currency; CU_MODE=""
eq "$CU_RC" "0" "7 currency: notify + unreachable remote still exits 0"
eq "$CU_OUT_OUTCOME" "offline" "7 currency: notify + unreachable remote reports offline, NOT silent"
has "$CU_OUT_LINE" "unreachable" "7 currency: the notify offline line says so"
git -C "$cusrc" remote set-url origin "$cuorigin"
cu_reset

# ...while a DELIBERATE clone state stays quiet in notify, which is the distinction: notify is
# silent about states its owner created on purpose, never about a failure to verify.
cu_reset; cu_advance "cu-notify-dirty"
printf 'local edit\n' >> "$cusrc/agents/claude/CLAUDE.md"
CU_MODE=notify; run_currency; CU_MODE=""
eq "$CU_OUT_OUTCOME" "silent" "7 currency: notify stays silent for a deliberate clone state (dirty)"
eq "$CU_OUT_LINE" "" "7 currency: …and prints nothing for it"
cu_reset

# (f) never update the clone being swept. Sweeping the install-source itself must skip — including
# from a SUBDIRECTORY of it, which is the shape a repo-root-relative guard would miss.
cu_reset; cu_advance "cu-selfclone"
cu_before="${ cu_head; }"
run_currency "$cusrc"
eq "$CU_OUT_OUTCOME" "skipped" "7 currency: sweeping the install-source clone itself skips"
eq "${ cu_head; }" "$cu_before" "7 currency: the self-clone guard left it untouched"
run_currency "$cusrc/scripts"
eq "$CU_OUT_OUTCOME" "skipped" "7 currency: a SUBDIRECTORY of the install-source also skips"

# (g) a refused clone is reported, and named. Dirty is the case a porcelain-only check would see;
# what matters here is that the step surfaces WHICH state instead of claiming success.
cu_reset; cu_advance "cu-dirty"
printf 'local edit\n' >> "$cusrc/agents/claude/CLAUDE.md"
cu_before="${ cu_head; }"
run_currency
eq "$CU_RC" "0" "7 currency: a refused update still exits 0"
eq "$CU_OUT_OUTCOME" "refused" "7 currency: an unsafe clone state is refused"
has "$CU_OUT_LINE" "dirty" "7 currency: the refusal names the state"
eq "${ cu_head; }" "$cu_before" "7 currency: a refused update never fast-forwards"
cu_reset

# (h) offline is reported here (unlike the unattended hook, which stays silent) and never fails.
cu_reset
git -C "$cusrc" remote set-url origin "$cuw/does-not-exist.git"
run_currency
eq "$CU_RC" "0" "7 currency: an unreachable remote still exits 0"
eq "$CU_OUT_OUTCOME" "offline" "7 currency: an unreachable remote is reported as offline"
has "$CU_OUT_LINE" "unreachable" "7 currency: the offline line says so"
git -C "$cusrc" remote set-url origin "$cuorigin"
cu_reset

# (i) a peer update holding the lock is reported here too, and is not sticky.
cu_reset; cu_advance "cu-busy"
mkdir -p "$cusrcgit/adb-update.lock"
run_currency
eq "$CU_RC" "0" "7 currency: lock contention still exits 0"
eq "$CU_OUT_OUTCOME" "busy" "7 currency: a peer update is reported as busy"
rmdir "$cusrcgit/adb-update.lock"
run_currency
eq "$CU_OUT_OUTCOME" "updated" "7 currency: a released lock lets the next run proceed"

# (j) no install at all -> silent skip, never an error. The ordinary state of a machine that never
# ran install.sh, and of a CI checkout.
cu_reset
CU_HOME_SAVE="$cufh"; cufh="$cuw/emptyhome"; mkdir -p "$cufh"
run_currency
eq "$CU_RC" "0" "7 currency: no installed baseline still exits 0"
eq "$CU_OUT_OUTCOME" "skipped" "7 currency: no installed baseline skips silently"
eq "$CU_OUT_LINE" "" "7 currency: no installed baseline prints nothing"
cufh="$CU_HOME_SAVE"

# (k) a BROKEN install is loud, not silent. A resolved install-source whose `baseline` cannot be
# executed is not "nothing installed" — reporting it as a silent skip would be the very
# silent-staleness this feature exists to catch.
cu_reset
chmod -x "$cusrc/bin/baseline"
run_currency
eq "$CU_RC" "0" "7 currency: a broken install-source still exits 0"
eq "$CU_OUT_OUTCOME" "failed" "7 currency: a non-executable bin/baseline is reported, not skipped"
has "$CU_OUT_LINE" "reinstall" "7 currency: the broken-install line says what to do"
chmod +x "$cusrc/bin/baseline"
cu_reset

# --- ordering: the report must be composed BEFORE the update swaps the libraries -------------
# Version skew, and the reason step 6 buffers instead of printing: `baseline update` re-runs the
# installer, whose symlinks are what {{CLEANUP_LIB}} resolves through, so a report composed AFTER
# the update would be built by a library the sweep never used. Pin the order in the source.
wf_compose="${ printf '%s\n' "$cuwf" | grep -n 'REPORT_OUT="\$(' | head -n1 | cut -d: -f1; }"
wf_curr="${ printf '%s\n' "$cuwf" | grep -n '# ADB-SNIPPET: currency' | head -n1 | cut -d: -f1; }"
wf_emit="${ printf '%s\n' "$cuwf" | grep -n 'printf .%s\\n. "\$REPORT_OUT"' | head -n1 | cut -d: -f1; }"
if [ -n "$wf_compose" ] && [ -n "$wf_curr" ] && [ "$wf_compose" -lt "$wf_curr" ]; then ok; else
  bad "7 the report must be COMPOSED before the currency step (compose@${wf_compose:-?} currency@${wf_curr:-?})"
fi
if [ -n "$wf_emit" ] && [ -n "$wf_curr" ] && [ "$wf_emit" -gt "$wf_curr" ]; then ok; else
  bad "7 the buffered report must be EMITTED after the currency step (currency@${wf_curr:-?} emit@${wf_emit:-?})"
fi
# The state line stays last: currency is emitted above the buffered report, not after it.
wf_cuemit="${ printf '%s\n' "$cuwf" | grep -n 'printf .%s\\n. "\$CU_LINE"' | head -n1 | cut -d: -f1; }"
if [ -n "$wf_cuemit" ] && [ -n "$wf_emit" ] && [ "$wf_cuemit" -lt "$wf_emit" ]; then ok; else
  bad "7 the currency line must print BEFORE the buffered report so the state line stays last"
fi
# Currency must never gate the sweep. Anchor this to the SNIPPET, not the whole workflow: the file
# already contains five unrelated `|| true`s, so a whole-file match would stay green even if both
# currency ones were deleted — a check that proves nothing is worse than no check.
has "$CU_SNIPPET" '|| true' "7 the currency capture absorbs a non-zero status (never gates the sweep)"

check_summary "check-cleanup"
