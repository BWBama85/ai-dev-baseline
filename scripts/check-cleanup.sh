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

# --- 2c1. the issue snapshot: the SAME predicate as gaps, under its own name (#250) ------------
# Step 2 writes the snapshot before any marker exists, under the claim admit took in preflight,
# and step 8 is still reading it long after the marker took over — exactly the gap artifacts'
# lifetime, so exactly their verdict. `cleanup-lib.sh` implements the two names with ONE arm on
# purpose (two bodies that must agree are two bodies that will stop agreeing), and this block is
# what proves the aliasing is real rather than asserted: every gaps case restated for `issue`, so
# a future edit that splits the arm and changes one side fails here.
eq "${ sv issue 1 none; }"  "keep"  "2c1 the claim keeps the snapshot with no marker at all"
eq "${ sv issue 1 stale; }" "keep"  "2c1 …and outranks even a finished run's marker"
eq "${ sv issue 0 keep; }"  "keep"  "2c1 a live run keeps its snapshot"
eq "${ sv issue 0 stale; }" "stale" "2c1 a finished run's snapshot is swept"
eq "${ sv issue 0 none; }"  "stale" "2c1 no claim and no marker means nothing owns it"
sv issue 2 none >/dev/null 2>&1;  no $? "2c1 a non-boolean lock is an error"
sv issue 0 bogus >/dev/null 2>&1; no $? "2c1 an unrecognised run word is an error"
sv issue 1 bogus >/dev/null 2>&1; no $? "2c1 …even when the lock would short-circuit the decision"
sv issue 0 >/dev/null 2>&1;       no $? "2c1 the review ARITY is refused, never silently re-read"
# The diagnostic names the kind the CALLER asked for. A shared arm that reported `gaps` for an
# `issue` typo sends the reader to the wrong line of base/workflows/cleanup.md. Called directly
# rather than through `sv`, which discards stderr — and stderr is the whole assertion here.
has "${ bash "$CL" state-verdict issue 0 bogus 2>&1 || true; }" "state-verdict issue:" \
   "2c1 an error names the kind that was ASKED, not the arm it shares"

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

# --- 2d2. file-identity: the ARTIFACT guard, which a content digest cannot be (#305) -----------
# The two subcommands answer different questions and the difference is the whole bug. An artifact's
# replacement is routinely BYTE-IDENTICAL — `gh issue view` returns the same JSON for an unchanged
# issue, an `.assoc` holds one word — so a digest compares equal and the live run's file is deleted.
#
# The seeded file is dated into the past first, and that is the fixture being HONEST rather than
# convenient: in the real race the judged file was written by a run that has already finished, so
# its mtime really is older than its replacement's. Without it this pair would rest on inode
# allocation alone, and a filesystem that reuses a just-freed inode within the same second would
# make the assertion flap rather than fail.
printf 'identical bytes\n' > "$work/fi.json"
touch -t 202601010000 "$work/fi.json"
FI1="$(bash "$CL" file-identity "$work/fi.json")"
MI1="$(bash "$CL" marker-identity "$work/fi.json")"
[ -n "$FI1" ] && ok || bad "2d2 file-identity produces an identity for a readable file"
eq "$(bash "$CL" file-identity "$work/fi.json")" "$FI1" "2d2 file-identity is stable for an unchanged file"
rm -f "$work/fi.json"; printf 'identical bytes\n' > "$work/fi.json"   # a fresh run, same bytes
eq "$(bash "$CL" marker-identity "$work/fi.json")" "$MI1" \
   "2d2 THE REASON THIS EXISTS: a content digest is UNCHANGED by an identical-bytes recreation"
hasnt "$(bash "$CL" file-identity "$work/fi.json")" "$FI1" \
   "2d2 …while file-identity changes, because it asks whether this is the same FILE"
# An in-place `>` rewrite keeps the INODE and, when the bytes are unchanged, the digest too — so
# mtime is the only component left to carry it. That is exactly how /implement-issue writes its
# snapshot, and an earlier version of this test only `touch`ed the file while claiming to rewrite it.
touch -t 202601010000 "$work/fi.json"
FI2="$(bash "$CL" file-identity "$work/fi.json")"
FI2_INO="${FI2%%-*}"
printf 'identical bytes\n' > "$work/fi.json"        # `>` truncates in place: same inode, same bytes
FI3="$(bash "$CL" file-identity "$work/fi.json")"
eq "${FI3%%-*}" "$FI2_INO" "2d2 an in-place rewrite really does keep the inode (else this proves nothing)"
hasnt "$FI3" "$FI2" "2d2 …and file-identity changes anyway, on mtime alone"
# Every unreadable shape yields NOTHING, which is the value that can never match — i.e. keep.
eq "$(bash "$CL" file-identity "$work/nope.json")" "" "2d2 a missing file yields no identity (never matches)"
ln -sfn "$work/nope.json" "$work/fi-dangling"
eq "$(bash "$CL" file-identity "$work/fi-dangling")" "" "2d2 a dangling symlink yields no identity"
eq "$(bash "$CL" file-identity "$work")" "" "2d2 a directory yields no identity"
bash "$CL" file-identity >/dev/null 2>&1;                no $? "2d2 file-identity requires a path"
bash "$CL" file-identity a b >/dev/null 2>&1;            no $? "2d2 …and refuses a second argument"

# A name carrying a NEWLINE spills `ls -i` onto a second line, and taking the inode off line 1 then
# returns a perfectly usable identity — failing OPEN while the code around it says it fails closed.
# Such a name cannot reach here through the sweep (`state-scan` calls it `unsafe`, #273), but this is
# a public subcommand. Caught by self-review, against an earlier version that answered non-empty.
printf 'x\n' > "$work/$(printf 'nl\nname.json')"
eq "$(bash "$CL" file-identity "$work/$(printf 'nl\nname.json')" 2>/dev/null)" "" \
   "2d2 a name containing a newline yields no identity, rather than one read off its first line"

# NEITHER identity subcommand may leak the SHELL's own redirection diagnostic. `cksum … 2>/dev/null`
# silences cksum, but a failed `< "$1"` is reported by the shell before cksum runs — so an
# unreadable-but-present file printed `…: Permission denied` into a sweep whose output contract is
# terse (#84), from inside a command substitution where it reads as a failed step. Both spellings now
# redirect the whole pipeline, matching `implement-lib.sh`'s `_il_file_identity`.
#
# ROOT READS EVERYTHING, so the trigger does not exist for uid 0 and the assertion is announced as
# skipped rather than quietly passing — a check that cannot fire must never look like one that did.
printf 'x\n' > "$work/fi-noread.json"
if [ "${ id -u; }" -ne 0 ] && chmod 000 "$work/fi-noread.json" 2>/dev/null \
   && ! { : < "$work/fi-noread.json"; } 2>/dev/null; then
  # `{ cmd >/dev/null; } 2>&1` and not the terser `2>&1 >/dev/null`: both capture stderr ALONE, but
  # the terse form is SC2069, because it is far more often a typo for "capture both" than a
  # deliberate swap. The braced form says which was meant.
  eq "${ { bash "$CL" file-identity "$work/fi-noread.json" >/dev/null; } 2>&1; }" "" \
     "2d2 file-identity emits nothing on stderr for an unreadable file"
  eq "${ { bash "$CL" marker-identity "$work/fi-noread.json" >/dev/null; } 2>&1; }" "" \
     "2d2 …and neither does marker-identity, which had the same leak"
  eq "${ bash "$CL" file-identity "$work/fi-noread.json" 2>/dev/null; }" "" \
     "2d2 …and an unreadable file still yields no identity"
else
  check_note "2d2 SKIPPED the unreadable-file stderr assertions: running as uid ${ id -u; }, which can read mode-000 files"
fi
chmod 644 "$work/fi-noread.json" 2>/dev/null || true

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
: > "$S/issue-250.json"
: > "$S/issue-250.assoc"
: > "$S/issue-7.json"
: > "$S/issue-.json"
: > "$S/issue-abc.assoc"
: > "$S/issue-250.json.bak"
: > "$S/issue-250.txt"
: > "$S/issues-250.json"
: > "$S/issue-250.assoc.json"
: > "$S/issue-250.json.assoc"
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
# #250: the issue SNAPSHOT — step 2's untrusted body plus the `author_association` trust label —
# which used to live at a fixed, host-shared temp path and so had no lifecycle here at all.
eq "${ kindof issue-250.json; }"               "issue"   "3 the issue snapshot is classified (#250)"
eq "${ kindof issue-250.assoc; }"              "issue"   "3 …and its provenance label, on the other suffix"
eq "${ kindof issue-7.json; }"                 "issue"   "3 …including a single-digit issue number"
# The same allowlist discipline the `threads` arm applies: a name that cannot supply the issue
# number it claims to carry is not ours to delete. Each near-miss is its own case, because the
# cheap way to widen an allowlist by accident is one glob that swallows a neighbour.
eq "${ kindof issue-.json; }"                  "other"   "3 an issue-shaped name with NO number is NOT ours to delete"
eq "${ kindof issue-abc.assoc; }"              "other"   "3 …nor one whose number is not a number"
eq "${ kindof issue-250.json.bak; }"           "other"   "3 …nor a backup of one"
# A DOUBLE SUFFIX, found in self-review. Stripping `.json` and then `.assoc` in sequence walks
# `issue-250.assoc.json` all the way down to a bare `250` and classifies a name nothing writes as
# SWEEPABLE. Both orderings are pinned, because only one of them was broken and a fix that swapped
# the sequence would move the hole rather than close it.
eq "${ kindof issue-250.assoc.json; }"         "other"   "3 …nor a double suffix (.assoc.json)"
eq "${ kindof issue-250.json.assoc; }"         "other"   "3 …nor the other double suffix (.json.assoc)"
eq "${ kindof issue-250.txt; }"                "other"   "3 …nor the family prefix with the wrong suffix"
eq "${ kindof issues-250.json; }"              "other"   "3 …nor a longer word that merely starts with 'issue'"
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

# --- 3a2. --with-identity: the fourth field, bound to the same enumeration pass (#305) ----------
# The delete path needs to know whether the file it is about to remove is still the one that was
# classified, and only this loop can bind those two facts to one observation of the file.
WI="$work/wistate"; mkdir -p "$WI"
printf 'g\n' > "$WI/gaps.md"
printf 'i\n' > "$WI/issue-9.json"
printf 'o\n' > "$WI/whatever.txt"
wi_plain="${ bash "$CL" state-scan "$WI"; }"
wi_ident="${ bash "$CL" state-scan --with-identity "$WI"; }"
# THE DEFAULT IS UNCHANGED. Three other loops in the sweep parse this with three variables, and
# `read` folds every surplus field into the last one — so an unconditional fourth column would
# arrive silently inside a marker's branch name and a thread cache's PR number.
eq "${ printf '%s\n' "$wi_plain" | awk -F'\t' 'NF != 3 { n++ } END { print n + 0 }'; }" "0" \
   "3a2 the default record is still exactly three fields"
eq "${ printf '%s\n' "$wi_ident" | awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }'; }" "0" \
   "3a2 --with-identity makes every record exactly four"
eq "${ printf '%s\n' "$wi_ident" | wc -l | tr -d ' '; }" "${ printf '%s\n' "$wi_plain" | wc -l | tr -d ' '; }" \
   "3a2 …and classifies exactly the same files"
eq "${ printf '%s\n' "$wi_ident" | cut -f1-3; }" "$wi_plain" \
   "3a2 …with the first three fields byte-identical to the default"
# The fourth field must be the SAME answer `file-identity` gives, or the delete-time re-capture is
# comparing against a value nothing else can reproduce.
wi_row="${ printf '%s\n' "$wi_ident" | awk -F'\t' '$1 == "gaps" { print $4; exit }'; }"
eq "$wi_row" "${ bash "$CL" file-identity "$WI/gaps.md"; }" \
   "3a2 the identity field is file-identity's own answer for that path"
[ -n "$wi_row" ] && ok || bad "3a2 …and is non-empty for a readable file"
# `unsafe` carries a `%q`-ENCODED rendering rather than a usable path, so it is the one kind that
# must never be fingerprinted — handing that string to a filesystem call is the #273 hole reopened.
# Its own name rather than section 3b's $HOSTILE_NAME, which is defined below this point — a
# forward reference would abort the suite under `set -u` before a single assertion ran.
WI_UNSAFE=$'gaps.md\ngaps\tCHANGELOG.md\t-'
: > "$WI/$WI_UNSAFE"
eq "${ bash "$CL" state-scan --with-identity "$WI" | awk -F'\t' '$1 == "unsafe" { print $4; exit }'; }" "-" \
   "3a2 an unsafe record's identity is the '-' sentinel, never a filesystem read of its encoded path"
rm -f "$WI/$WI_UNSAFE"
# `-` and not an empty column: a trailing empty field is the one that goes missing, and since
# file-identity can never PRINT `-`, the sentinel is a value no re-capture will ever equal — the
# caller's ordinary comparison fails closed on it with no special case to remember.
hasnt "${ bash "$CL" file-identity "$WI/gaps.md"; }" "-
" "3a2 file-identity never emits the bare sentinel itself"
bash "$CL" state-scan --bogus "$WI" >/dev/null 2>&1; no $? "3a2 an unknown state-scan option is an error, not a silent default"
bash "$CL" state-scan --with-identity >/dev/null 2>&1; no $? "3a2 --with-identity still requires the directory"

# ================= 3b. the RECORD FORMAT itself cannot be forged (#273) =======================
# The allowlist in section 3 is only a safety property if a record's FIELDS mean what they say.
# `state-scan` serializes `<kind>TAB<path>TAB<key>NL` and the sweep parses it with
# `IFS=<tab> read -r kind sfile key`, so a field carrying a raw tab or newline does not corrupt a
# record — it FORGES one, whose `kind` is attacker-chosen text. The forged record then walks past
# `other` (the carrier below is classified `other`, the harmless kind) and reaches `rm -f`.
#
# TESTED FROM BOTH CARRIERS, because they are not the same bug and a fix for one leaves the other
# live. A FILENAME cannot contain `/`, so it reaches only names in the directory the sweep is
# anchored at; a MARKER's `.branch` is a JSON string that CAN contain `/`, so it reaches an
# ABSOLUTE path. A pathname-only fixture goes red then green while the worse half still works.
#
# `$'…'` is load-bearing in the fixtures: an ordinary quoted "\n" makes two literal characters and
# would test nothing at all. Each fixture asserts its own hostile file exists before drawing any
# conclusion from a green result.
TAB=$'\t'
FS_DIR="$work/forge"; mkdir -p "$FS_DIR"
HOSTILE_NAME=$'notes.json\ngaps\tCHANGELOG.md\t-'
: > "$FS_DIR/$HOSTILE_NAME"
: > "$FS_DIR/gaps.md"
: > "$FS_DIR/plain.json"
if [ -f "$FS_DIR/$HOSTILE_NAME" ]; then ok; else
  bad "3b the newline-in-filename fixture was not created — everything below asserts NOTHING"
fi

fscan="$(bash "$CL" state-scan "$FS_DIR")"
# THE bug, stated as the property that failed: parse the scan the way the sweep does, and collect
# every path any SWEEPABLE kind would hand to `rm -f`. Before the fix this list contained
# `CHANGELOG.md`; it must now contain only real files inside the state dir.
sweepable="$(printf '%s\n' "$fscan" | while IFS="$TAB" read -r k sf _; do
  case "$k" in gaps|review|threads) printf '%s\n' "$sf" ;; esac
done)"
hasnt "$sweepable" "CHANGELOG.md" "3b a newline in a filename cannot forge a sweepable record"
eq "$sweepable" "$FS_DIR/gaps.md" "3b …and the only sweepable path is the real gap artifact beside it"
# The carrier is REPORTED, not silently dropped: `other` is emitted rather than dropped for the
# same reason, and an operator who cannot see the skip cannot go rename the file.
eq "${ printf '%s\n' "$fscan" | awk -F'\t' '$1=="unsafe"{n++} END{print n+0}'; }" "1" \
   "3b the unserializable name is reported as exactly one 'unsafe' record"
# …and its rendering is itself safe. The whole point is that the raw name never reaches stdout, so
# a diagnostic that pasted it back would reopen the hole one line below the fix.
# Three files in the fixture (the hostile carrier, gaps.md, plain.json) must yield three physical
# lines. This is the count that WAS wrong: before the fix the carrier produced two.
eq "${ printf '%s\n' "$fscan" | grep -c .; }" "3" \
   "3b every file yields exactly one physical line — the hostile name forged no extra record"
hasnt "$fscan" "$HOSTILE_NAME" "3b the raw hostile name never reaches stdout in any form"
# EVERY record, not just the interesting ones: a three-field contract that holds for the arms
# someone remembered is not a contract.
eq "${ printf '%s\n' "$fscan" | awk -F'\t' 'NF!=3{n++} END{print n+0}'; }" "0" \
   "3b every emitted record has exactly three fields"
# A tab alone forges just as well as a newline — it ends the path field early, so the REST of the
# name becomes the key and the next record's fields shift.
: > "$FS_DIR/"$'a\tb.json'
eq "${ bash "$CL" state-scan "$FS_DIR" | awk -F'\t' '$1=="unsafe"{n++} END{print n+0}'; }" "2" \
   "3b a tab-only filename is refused too, not just a newline"

# --- the marker key: the same forge, through JSON, and it reaches absolute paths ---------------
MK_DIR="$work/forge-marker"; mkdir -p "$MK_DIR"
VICTIM_ABS="$work/victim-absolute.txt"
: > "$VICTIM_ABS"
# `\\n` / `\\t`, so the FILE holds JSON ESCAPES that jq decodes into real control characters.
# Writing raw control bytes instead would make the file invalid JSON — jq would fail to parse it,
# the key would fall to `-` because the marker is UNREADABLE, and every assertion below would pass
# without the refusal ever being exercised. That is the silent-guard shape, so the fixture asserts
# its own JSON is valid AND that the decoded value really does carry the delimiter.
printf '{"branch":"issue-9-x\\ngaps\\t%s\\t-","phase":"pushed"}' "$VICTIM_ABS" \
  > "$MK_DIR/implement-issue-active.json"
: > "$MK_DIR/gaps.md"
jq -e . "$MK_DIR/implement-issue-active.json" >/dev/null 2>&1
yes $? "3b the marker fixture is VALID json — otherwise the refusal below is never reached"
eq "${ jq -r '.branch' "$MK_DIR/implement-issue-active.json" | grep -c .; }" "2" \
   "3b …and its .branch really decodes to a value carrying a newline"
# …AND the tabs, which are what put the absolute victim in the forged record's PATH field. Without
# this the fixture still forges a record, but a single-field one that names nothing — so the whole
# absolute-path carrier could be tested by a fixture that cannot express it. Deleting both `\\t`
# escapes above was observed leaving the suite green before this assertion existed.
eq "${ jq -r '.branch' "$MK_DIR/implement-issue-active.json" | grep -c "$TAB"; }" "1" \
   "3b …and the TABs that place the victim in the forged record's path field"
has "${ jq -r '.branch' "$MK_DIR/implement-issue-active.json"; }" "$VICTIM_ABS" \
   "3b …naming an ABSOLUTE path, which is the half a filename carrier cannot reach"
mscan="$(bash "$CL" state-scan "$MK_DIR")"
msweepable="$(printf '%s\n' "$mscan" | while IFS="$TAB" read -r k sf _; do
  case "$k" in gaps|review|threads) printf '%s\n' "$sf" ;; esac
done)"
hasnt "$msweepable" "$VICTIM_ABS" "3b a newline in a marker's .branch cannot forge a sweepable record"
eq "${ printf '%s\n' "$mscan" | awk -F'\t' '$1=="marker"{print $3}'; }" "-" \
   "3b …the unusable branch yields the '-' key, which the caller maps to unknown -> keep"
# THE second half of that decision, and the one a "just drop the record" fix gets wrong. The
# workflow reads run liveness from the PRESENCE of a marker record (`RUN_NOW=keep`), so dropping
# the marker would report "no run in flight" — the verdict that lets a LIVE run's gap and review
# artifacts be swept out from under it. Refusing the key must not cost the record.
eq "${ printf '%s\n' "$mscan" | awk -F'\t' '$1=="marker"{n++} END{print n+0}'; }" "1" \
   "3b …and the marker record SURVIVES, so run liveness still fails closed"
# `git check-ref-format` rejects control characters, so this value was never a branch name — the
# key is unreadable in the honest sense, exactly like malformed JSON.
eq "$(bash "$CL" marker-branch "$MK_DIR/implement-issue-active.json")" "" \
   "3b marker-branch — the one reader both the scan and the delete-time re-read use — refuses it too"

# --- the two values the SHELL would have normalized into well-formed ones ----------------------
# Both were live defects found by the independent review: the rejection has to happen inside jq,
# because `$(…)` MUTATES the value on the way out and a mutated value passes a check the original
# would have failed. Neither is a forgery — they are the opposite failure, a malformed marker
# quietly becoming a valid-looking one, which then classifies STALE and gets DELETED.
mb() { printf '%s' "$1" > "$work/mb.json"; bash "$CL" marker-branch "$work/mb.json" 2>"$work/mb.err"; }
# A TRAILING newline: command substitution strips every one of them, so `dead-branch\n` — not a
# branch name — arrived as the perfectly ordinary `dead-branch`.
eq "$(mb '{"branch":"dead-branch\n"}')" "" \
   "3b a .branch ending in a newline is unreadable, not silently trimmed into a valid branch name"
# A NUL: JSON permits \u0000, and bash drops the byte from a substitution — turning `dead\0branch`
# into `deadbranch` — AND warns on stderr, breaking this reader's quiet-on-every-failure contract.
eq "$(mb '{"branch":"dead\u0000branch"}')" "" \
   "3b a .branch containing a NUL is unreadable, not silently spliced into a valid branch name"
eq "$(cat "$work/mb.err")" "" \
   "3b …and reading it stays SILENT — no shell warning leaks past the quiet contract"
# DEL (0x7f) is a control character too, and it is the one that sits ABOVE the printable range —
# so a `< 32` test misses it while `git check-ref-format` rejects it. It does not forge a record
# (DEL is a fine TSV byte), which is exactly why it needs its own case: the damage is the OTHER
# failure this reader guards, a value that cannot name a ref being emitted as an ordinary key, so
# no ref matches, no PR is recorded, and `state-verdict marker` says STALE — deleting the marker
# and the run's artifacts with it. Shipped in the first review round and caught by the second.
eq "$(mb '{"branch":"dead\u007fbranch"}')" "" \
   "3b a .branch containing DEL is unreadable — the control character a '< 32' test misses"
# …and the boundary either side of it, so the class is pinned rather than the one example.
eq "$(mb '{"branch":"dead\u001fbranch"}')" "" "3b …as is 0x1f, the last codepoint below the printable range"
eq "$(mb '{"branch":"dead~branch"}')" "dead~branch" \
   "3b …while 0x7e stays readable: this is the CONTROL class, not a reimplementation of git's ref grammar"
# The other direction, so the rejection cannot be "refuse everything": an ordinary name still reads.
eq "$(mb '{"branch":"issue-42-ok"}')" "issue-42-ok" "3b …while an ordinary branch name still reads normally"
eq "$(mb '{"branch":123}')" "" "3b …and a non-string .branch is unreadable rather than coerced"

# --- the state directory's OWN path, which poisons every record at once ------------------------
# Fatal rather than skipped: refusing file-by-file would leave an empty scan indistinguishable
# from a clean, already-empty state dir, and a sweep that reports success while doing nothing is
# the #106 class this library exists to remove.
BAD_DIR="$work/"$'st\nate'; mkdir -p "$BAD_DIR"; : > "$BAD_DIR/gaps.md"
bad_out="$(bash "$CL" state-scan "$BAD_DIR" 2>/dev/null)"; bad_rc=$?
# EXIT 2 EXACTLY, not merely non-zero. This library has no status 1 on purpose — its header says
# so — because a caller that read 1 as a benign negative would delete on a tooling failure. `no
# $rc` accepts anything non-zero, so swapping `die` for `return 1` was observed leaving the suite
# green while D41, the CHANGELOG and the library contract all still claimed 2.
eq "$bad_rc" "2" "3b an unserializable state-dir path exits 2 — the fail-closed status, not just non-zero"
eq "$bad_out" "" "3b …and it emits no partial records to act on"

# --- END TO END: the forged record must not survive the sweep's own parse loop -----------------
# Section 3b above proves the producer is safe; this proves the thing the issue is actually about,
# through the loop shape base/workflows/cleanup.md step 5 runs (mirrored here, as
# check-cleanup-enum.sh mirrors the enumeration pipeline — a fenced block full of `{{…}}`
# placeholders cannot be sourced, and section 6 pins that the real one still has these parts).
#
# THE FIXTURE IS ITS OWN ROOT. `check-cleanup.sh` runs anchored at the REAL repo root, so a victim
# named `CHANGELOG.md` parsed from here would resolve to this repo's own changelog: the test would
# be destructive when it failed and green for the wrong reason when it passed.
#
# AND IT CARRIES A SENTINEL THAT MUST DIE. A sweep that deletes nothing at all satisfies "the
# victim survived" perfectly, so the fixture demands a real gap artifact be removed in the same
# pass — the test then fails both when the guard leaks and when it over-corrects into a no-op.
SW_ROOT="$work/sweeproot"; SW_STATE="$SW_ROOT/state"; mkdir -p "$SW_STATE"
: > "$SW_ROOT/CHANGELOG.md"
: > "$SW_STATE/$HOSTILE_NAME"
: > "$SW_STATE/gaps.md"
(
  cd "$SW_ROOT" || exit 1
  GV=stale
  sweep_file() { rm -f "$1" 2>/dev/null; }
  bash "$CL" state-scan "$SW_STATE" | while IFS="$TAB" read -r kind sfile _; do
    case "$kind" in
      gaps) [ "$GV" = stale ] || continue; sweep_file "$sfile" ;;
    esac
  done
)
if [ -f "$SW_ROOT/CHANGELOG.md" ]; then ok; else
  bad "3b THE BUG: the sweep deleted a repo-root file the forged record named"
fi
if [ -f "$SW_STATE/gaps.md" ]; then
  bad "3b the sweep left a genuinely stale gap artifact — the fixture proved nothing"
else ok; fi

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
  has "$wfcode" 'SCAN="$({{CLEANUP_LIB}} state-scan --with-identity "$STATE")"' \
     "6 the scan is re-taken before any destructive state delete"
  eq "${ printf '%s\n' "$wfcode" | grep -c '{{CLEANUP_LIB}} state-scan'; }" "2" \
     "6 …i.e. the lock governing a delete is the one true AT the delete, not at classification"
  # …and it is the SECOND one that carries --with-identity. Only the delete path needs the fourth
  # field, and putting it on the first scan would feed a 4-column record to three `read`s that bind
  # three variables — folding the identity into `$key`, which is a marker's branch name.
  eq "${ printf '%s\n' "$wfcode" | grep -c 'state-scan --with-identity'; }" "1" \
     "6 …and exactly one of the two asks for identities"
  has "$wfcode" 'sweep_file' "6 state deletions report their failures instead of silently continuing"
  # --- #264: the review family is swept, and on ITS OWN liveness signal --------------------
  has "$wfcode" '{{CLEANUP_LIB}} state-verdict review' "6 review artifacts are decided through the library, not inline"
  # The label BOUND TO ITS BODY, which needs both halves in one needle. A bare `review)` stays
  # matched by the LARGE arm below even when the deletion arm is gone entirely; and a bare
  # `[ "$RV" = stale ]` stays matched when the LABEL is renamed to `reviews)`, which no longer
  # matches any record `state-scan` emits — a sweep arm that is present, correct and unreachable.
  # Both were observed passing before this needle spanned the two lines.
  has "$wfcode" 'review)
      [ "$RV" = stale ] || continue' "6 …and the sweep loop's review arm acts on that verdict"
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
  # --- #250: the issue snapshot is swept, on gaps' PREDICATE and review's FRESHNESS ------------
  # The snapshot spans both windows — written under the claim before any marker exists, read again
  # in step 8 — so it needs the lock argument `review` does not have AND the fresh <run> `gaps`
  # does not use. The negative is what has teeth: `state-verdict issue "$LOCK" "$RUN"` runs, prints
  # a verdict, and passes every other assertion here while being able to sweep a live run's issue
  # text out from under its own review dispatch.
  has "$wfexec" 'state-verdict issue "$LOCK" "$RUN_NOW"' \
     "6 the snapshot is decided from the claim AND the FRESH marker scan (#250)"
  hasnt "$wfexec" 'state-verdict issue "$LOCK" "$RUN"' \
     "6 …never from the pre-pass \$RUN, which is stale by the time the delete runs"
  has "$wfcode" 'issue)
      [ "$IV" = stale ] || continue' "6 …and the sweep loop's issue arm acts on that verdict"
  # The LARGE arm must gate on the review verdict, not the gap one — otherwise a kept review.err
  # is reported under a live GAP dispatch's liveness, naming the wrong run.
  has "$wfcode" 'review) [ "$RV" = keep ]' "6 a kept review stream is reported under its own verdict, not \$GV"
  # …and it must read its paths from the scan. A `"$STATE"/review-*.err` glob here is left literal
  # by POSIX shells but ABORTS the command under zsh's default `nomatch` — macOS's shell — so the
  # whole size report would silently not happen. Same class as the #125 zsh bug this file guards.
  hasnt "$wfcode" '"$STATE"/review-*.err' "6 …and enumerates streams from the scan, not a glob zsh's nomatch would abort"
  hasnt "$wfcode" '"$STATE"/gaps-*.err'   "6 …which applies to the gap streams it already reported"
  # --- #273: the scan's refusals are surfaced, and the fatal one is not swallowed -----------
  # A `SCAN="$(… state-scan …)"` that ignores its status turns the state-dir refusal (exit 2, no
  # stdout) into an empty scan — which sweeps nothing and reads exactly like a clean state dir.
  # Pin the captured form, which is the only spelling that can tell those two apart.
  # `wfexec`, NOT `wfcode`: wfcode keeps shell comments, so commenting the real capture OUT while
  # leaving its text on the line satisfied this pin exactly — observed green with no executable
  # status check at all. Same class as the `-type l` pin that was satisfied by the comment saying
  # `-type f` is wrong.
  has "$wfexec" 'if ! SCAN="$({{CLEANUP_LIB}} state-scan "$STATE")"; then' \
     "6 the first scan's exit status is captured, so a refusal cannot read as an empty state dir"
  # …and the pre-delete RE-SCAN gets the same treatment. Its failure paths emit nothing today, so
  # an unchecked capture is safe *by implementation* rather than by contract — and this is the
  # snapshot that drives `rm`. Command substitution keeps partial stdout on a non-zero exit, so a
  # future mid-enumeration error would otherwise hand actionable records to the delete loop.
  has "$wfexec" 'if ! SCAN="$({{CLEANUP_LIB}} state-scan "$STATE")"; then' \
     "6 …and so is the pre-delete re-scan, structurally rather than by implementation detail"
  eq "${ printf '%s\n' "$wfexec" | grep -c 'if ! SCAN="\$({{CLEANUP_LIB}} state-scan'; }" "2" \
     "6 …i.e. BOTH scans, not just the one that happens to be reported"
  # The refusal message must not paste the state-dir path back in: that path is the thing carrying
  # a newline, so interpolating it moves the injection from the delete protocol into the report.
  # Pinned by asserting the line names NO path variable at all, rather than by forbidding the one
  # spelling `$STATE` — rewriting it as `${STATE}` was observed leaving that narrower pin green.
  # BOTH refusal messages, matched on the shared prefix — the re-scan grew one too, and a pin that
  # only ever looked at the first would let the second reintroduce the interpolation.
  refline="${ printf '%s\n' "$wfexec" | grep -F 'REFUSED the state'; }"
  if [ -n "$refline" ]; then
    hasnt "$refline" 'STATE' "6 …and that message interpolates no path variable, in any spelling"
  else
    bad "6 could not find the REFUSED lines in the workflow — the interpolation check asserted NOTHING"
  fi
  eq "${ printf '%s\n' "$refline" | grep -c .; }" "2" \
     "6 …for BOTH refusals, so neither scan can quietly stop reporting one"
  # The label BOUND TO ITS BODY, the same way the review arm is pinned above: a bare `unsafe)`
  # survives a deleted body, and a bare NOTES line survives a renamed kind that matches no record
  # state-scan emits — a report arm that is present, correct and unreachable.
  has "$wfcode" '[ "$kind" = unsafe ] || continue
  NOTES="${NOTES}SKIPPED' \
     "6 files state-scan refused to serialize are reported through NOTES, not dropped silently"
  # Reported from the FIRST snapshot only. The scan is re-taken before the destructive deletes, so
  # a second reporting loop would name every skipped file twice for one sweep.
  eq "${ printf '%s\n' "$wfcode" | grep -c '\[ "$kind" = unsafe \]'; }" "1" \
     "6 …exactly once, not once per snapshot"
  # `unsafe` must never reach a delete: its path field is a %q-ENCODED rendering, not a real path.
  # ASSERTED AS THE WHOLE ARM SET, not as the absence of an `unsafe)` label. Those are not the same
  # claim, and the difference is the entire finding: a default `*) sweep_file "$sfile" ;;` deletes
  # every unhandled kind — `unsafe`, `other`, `marker` — while containing no `unsafe)` anywhere, so
  # adding one was observed leaving a `hasnt … 'unsafe)'` pin perfectly green. The delete set is an
  # allowlist, so the test has to read it as one.
  sweeparms="${ printf '%s\n' "$wfexec" | awk '
    /case "\$kind" in/           { inb = 1; body = ""; arms = ""; next }
    inb && /^[[:space:]]*esac/   { if (body ~ /sweep_file/) print arms; inb = 0; next }
    inb {
      body = body $0 "\n"
      if ($0 ~ /^[[:space:]]*[A-Za-z*|_-]+\)[[:space:]]*$/) {
        a = $0; gsub(/[[:space:]]/, "", a); sub(/\)$/, "", a); arms = arms a " "
      }
    }' ; }"
  if [ -n "$sweeparms" ]; then
    eq "$sweeparms" "gaps issue review threads " \
       "6 the sweep loop's delete arms are EXACTLY gaps/issue/review/threads — no default arm, so 'unsafe' cannot be deleted"
  else
    bad "6 could not read the sweep loop's case arms from the workflow — the allowlist check asserted NOTHING"
  fi
  has "$wf" '{{CLEANUP_LIB}} clone-state' \
     "6 the switch/pull guard uses the clone classifier, not a porcelain-only test (rebase/bisect leave it clean)"
  hasnt "$wfcode" 'git pull --ff-only' \
     "6 the fast-forward consumes the fetch already done, rather than a second network round trip"
fi

# The lock is only a contract if BOTH sides implement it: /implement-issue must take and release
# it around the pre-marker window, or /cleanup's `keep` arm can never fire. Since #202 the take is
# no longer a bare `: >` in step 3 — `implement-lib.sh admit` acquires it in PREFLIGHT, with
# O_EXCL, as the run's claim — so what this section pins moved with it.
II="$ROOT/base/workflows/implement-issue.md"
IL="$ROOT/scripts/lib/implement-lib.sh"
if [ ! -f "$II" ] || [ ! -f "$IL" ]; then
  bad "6 base/workflows/implement-issue.md or scripts/lib/implement-lib.sh not found"
else
  ii="$(cat "$II")"
  # The EXECUTABLE half with shell comments dropped, for the same reason section 6 above builds
  # one: the blocks explain which spellings they deliberately avoid, so a whole-file `hasnt` would
  # fail on the very comment documenting the avoidance.
  iiexec="${ awk '/^```bash$/ { inb = 1; next } /^```$/ { inb = 0; next } inb' "$II" \
             | sed 's/[[:space:]]*#.*$//'; }"

  # --- #202: admission replaces the unconditional clear ----------------------------------------
  has "$iiexec" '{{IMPLEMENT_LIB}} admit {{STATE_DIR}}' \
     "6 /implement-issue asks admission before it touches state"
  # `release --token "$RUN_CLAIM_TOKEN"`, not a bare release: a token the workflow never threads is
  # a token that protects nothing, which is exactly what the independent review found. The COUNT
  # equality (every release site passes it) is pinned in check-implement-lib.sh section 13; this
  # asserts the form is present at all, so a revert cannot pass by deleting every release.
  has "$iiexec" '{{IMPLEMENT_LIB}} release --token "$RUN_CLAIM_TOKEN" {{STATE_DIR}}' \
     "6 …and releases the claim it holds until the marker supersedes it, by token"
  # THE BUG, pinned as a negative. An unconditional `rm -f` of either marker path is exactly what
  # let session B delete session A's live marker; `admit` clears them only after proving the run is
  # stale AND taking the claim. Both spellings, because the two files were cleared on one line.
  hasnt "$iiexec" 'rm -f {{STATE_DIR}}/implement-issue-active.json' \
     "6 …and preflight no longer unconditionally deletes the active marker (#202)"
  hasnt "$iiexec" 'rm -f {{STATE_DIR}}/implement-issue-blocked.json' \
     "6 …nor the blocked marker"
  # The claim is taken ONCE, by admit. A second `: >` take in step 3 would now FAIL against its own
  # O_EXCL acquire and read to an agent as a broken step.
  hasnt "$iiexec" ': > {{STATE_DIR}}/gap-analysis.lock' \
     "6 …and step 3 no longer re-takes the claim admit already holds"
  # ORDER is still the contract, one step earlier: the claim must exist BEFORE gap-prompt.txt does,
  # or a /cleanup landing in between classifies that prompt as a gap artifact, sees no lock and no
  # marker (step 5 owns markers), and deletes it — after which the dispatch's redirection fails and
  # reads as a codex error. Writing the prompt with a file-write tool makes that window a whole
  # agent turn.
  iitake="${ printf '%s\n' "$ii" | grep -n '{{IMPLEMENT_LIB}} admit {{STATE_DIR}}' | head -n1 | cut -d: -f1; }"
  iiprompt="${ printf '%s\n' "$ii" | grep -n 'cat > {{STATE_DIR}}/gap-prompt.txt' | head -n1 | cut -d: -f1; }"
  if [ -n "$iitake" ] && [ -n "$iiprompt" ] && [ "$iitake" -lt "$iiprompt" ]; then ok; else
    bad "6 the claim must be taken BEFORE gap-prompt.txt is written (admit@${iitake:-?} prompt@${iiprompt:-?})"
  fi
  # The release must NOT sit in the same fenced block as the dispatch: that block is dispatched
  # to the harness's DETACHED facility, so a release appended to it drops the claim immediately
  # and leaves it unheld for the whole pass — the only window it exists for.
  iidisp="${ printf '%s\n' "$ii" | grep -n '{{ROLE_DISPATCH}} invoke gap_analysis' | head -n1 | cut -d: -f1; }"
  iirel="${ printf '%s\n' "$ii" | grep -n '{{IMPLEMENT_LIB}} release --token' | tail -n1 | cut -d: -f1; }"
  iifence="${ printf '%s\n' "$ii" | awk -v d="${iidisp:-0}" 'NR > d && /^```$/ { print NR; exit }'; }"
  if [ -n "$iirel" ] && [ -n "$iifence" ] && [ "$iirel" -gt "$iifence" ]; then ok; else
    bad "6 the claim release must be in a separate fenced block after the detached dispatch (release@${iirel:-?} block-end@${iifence:-?})"
  fi
  # THE HAND-OFF ORDER. Step 5 must write the marker BEFORE releasing the claim: for the instant
  # between them both signals are live, which over-preserves, whereas releasing first leaves
  # exactly the uncovered window — no claim, no marker — that /cleanup reads as a finished run.
  #
  # SCOPED TO STEP 5, and that scoping is the whole assertion. Anchoring on the first
  # `mv …/.marker.tmp …` in the file matches the PHASE-UPDATE example in the state-protocol section
  # near the top, after which step 2's and step 4's releases satisfy "a release comes later" — so
  # deleting step 5's release entirely left this green (observed). Cut the section out first, then
  # require both events inside it.
  ii5="${ awk '/^### 5\. /{ inb = 1; next } inb && /^### /{ exit } inb' "$II"; }"
  if [ -z "$ii5" ]; then
    bad "6 could not locate step 5 in implement-issue.md — the hand-off order asserted NOTHING"
  else
    ii5marker="${ printf '%s\n' "$ii5" | grep -n 'mv {{STATE_DIR}}/.marker.tmp {{STATE_DIR}}/implement-issue-active.json' | head -n1 | cut -d: -f1; }"
    # The HAND-OFF release specifically — the first one AFTER the marker write, not the first one in
    # the step. Step 5 legitimately releases EARLIER too, on the `git switch -c` failure path: that
    # invocation started nothing, so holding the claim would refuse every later run for the rest of
    # the lease. A `head -n1` over the whole step finds that one and reports the hand-off missing.
    ii5rel="${ printf '%s\n' "$ii5" | awk -v m="${ii5marker:-0}" 'NR > m && /\{\{IMPLEMENT_LIB\}\} release --token/ { print NR; exit }'; }"
    if [ -n "$ii5marker" ] && [ -n "$ii5rel" ]; then ok; else
      bad "6 step 5 must write the marker and THEN release the claim (marker@${ii5marker:-absent} hand-off release@${ii5rel:-absent})"
    fi
  fi

  # --- #264/#202: everything /cleanup can sweep, admit can clear — EXECUTED --------------------
  # This used to grep the preflight prose for each pattern. The clear is a real script now, so the
  # containment is checked by RUNNING it: materialize one concrete file per pattern the `gaps` and
  # `review` arms of `state-scan` recognise, admit into that directory, and require every one of
  # them to be gone. A text pin can only ever assert that someone wrote the pattern down; this
  # asserts the file is actually deleted, which is the property #264 needs.
  #
  # The patterns are DERIVED FROM THE LIBRARY, not a second hardcoded list. Two hardcoded lists
  # cannot detect that they disagree: adding `review-extra.json` to `state-scan`'s arm and nothing
  # to the clear left this suite green, because no fixture ever named that file.
  # `issue` joins `gaps` and `review` here for #250. Its family is the issue SNAPSHOT — the
  # untrusted body and the `author_association` trust label — which moved out of a fixed, host-
  # shared temp path into the state directory and therefore inherited the same obligation both
  # older families carry: whatever /cleanup can sweep, admit must be able to clear.
  ilw="$work/il"; mkdir -p "$ilw"
  ilarms=0
  for armname in gaps issue review; do
    # Anchored on the arm's BODY (`printf 'gaps\t…`), not on its label: the gaps arm's label starts
    # with `gap-prompt.txt` and the review arm's with `review-prompt.txt`, so neither begins with
    # the kind it emits. Matching the emit line and reporting the label above it reads the pairing
    # the classifier actually implements.
    arm="${ awk -v k="$armname" '
        /^      [a-z*][^)]*\)$/ { label = $0; sub(/^      /, "", label); sub(/\)$/, "", label); next }
        /_adb_cl_emit/ { for (i = 1; i <= NF; i++) if ($i == k) { print label; exit } }' "$CL"; }"
    if [ -z "$arm" ]; then
      bad "6 could not read state-scan's $armname arm from cleanup-lib.sh — the containment check asserted NOTHING"
      continue
    fi
    ilarms=$((ilarms + 1))
    IFS='|' read -r -a armpats <<< "$arm"
    check_enumerated "state-scan $armname family" "${armpats[@]}"
    d="$ilw/$armname"; rm -rf "$d"; mkdir -p "$d"
    made=()
    for pat in "${armpats[@]}"; do
      # A glob member becomes a concrete name by substituting a token for `*`; an exact member is
      # itself. Both must survive the round trip through state-scan's own classifier below.
      #
      # THE TOKEN IS NUMERIC, and that is a requirement of this loop rather than a taste: an arm
      # may impose a KEY DISCIPLINE on the text its `*` stands for, and `issue-*.json` does — a
      # digits-only number, so `issue-<word>.json` is deliberately `other` (#250, the same
      # allowlist rule the `threads` arm has always applied). A word token made this loop generate
      # a name that arm rejects, and the fixture-is-real assertion below caught it. A digit is a
      # legal substitution for EVERY arm's `*`, so it is the one token that keeps this generic.
      f="${pat//\*/1}"
      : > "$d/$f"; made+=( "$f" )
    done
    # PROVE THE FIXTURE IS REAL before asserting anything about the clear. A name that state-scan
    # does NOT classify as this kind makes the deletion assertion vacuous — it would pass for a
    # file /cleanup was never going to sweep, which is the opposite of the property under test.
    for f in "${made[@]}"; do
      kind="${ bash "$CL" state-scan "$d" | awk -F'\t' -v p="$d/$f" '$2 == p { print $1 }'; }"
      eq "$kind" "$armname" "6 fixture $f really is classified $armname by state-scan"
    done
    out="${ bash "$IL" admit "$d" 2>&1; }" || true
    for f in "${made[@]}"; do
      if [ -e "$d/$f" ] || [ -L "$d/$f" ]; then
        bad "6 admit left $f behind — /cleanup would sweep it but preflight cannot clear it ($out)"
      else
        ok
      fi
    done
    # …including a SYMLINK, which the two selectors disagree on unless both follow it. `state-scan`
    # picks with `[ -f ]`, which follows a link to a regular file and classifies it; a clear that
    # tested only `-f` would not match the link itself, leaving it sweepable and unclearable
    # (observed on `review-slot.md` before the `-type l` arm existed).
    lnpat=""
    for pat in "${armpats[@]}"; do case "$pat" in *'*'*) lnpat="$pat"; break ;; esac; done
    if [ -n "$lnpat" ]; then
      rm -rf "$d"; mkdir -p "$d"
      : > "$d/link-target"
      # Numeric, for the reason the fixture loop above gives — an arm may constrain what its `*`
      # may stand for, and a link named outside that set would test a file /cleanup never sweeps.
      ln -s "$d/link-target" "$d/${lnpat//\*/2}"
      bash "$IL" admit "$d" >/dev/null 2>&1 || true
      if [ -e "$d/${lnpat//\*/2}" ] || [ -L "$d/${lnpat//\*/2}" ]; then
        bad "6 admit left the ${lnpat} SYMLINK behind, which state-scan's [ -f ] test follows"
      else
        ok
      fi
    else
      bad "6 the $armname arm exposes no family glob — the symlink agreement check asserted NOTHING"
    fi
  done
  eq "$ilarms" "3" "6 all three artifact families (gaps, issue, review) were actually read from state-scan"

  # A failure to clear must REFUSE and release, never report success over artifacts it did not
  # remove. A read-only state dir (mode 500) is the reproducible form of that.
  #
  # The OTHER permission shape — write-and-execute but NOT readable (mode 300), where fixed names
  # unlink fine while globs enumerate nothing, so a clear silently misses the family — lives in
  # check-implement-lib.sh section 15, beside the readability check that answers it. Named here
  # because this is the block an auditor of the containment rule reads first, and its absence would
  # otherwise look like an oversight.
  rod="$ilw/readonly"; rm -rf "$rod"; mkdir -p "$rod"
  : > "$rod/review.md"
  chmod 500 "$rod"
  bash "$IL" admit "$rod" >/dev/null 2>&1; rorc=$?
  chmod 700 "$rod"
  eq "$rorc" "14" "6 a clear that cannot remove a file REFUSES (14) instead of reporting a clean start"
  if [ -e "$rod/gap-analysis.lock" ]; then
    bad "6 …and releases the claim it took, so the checkout is not left blocked"
  else
    ok
  fi
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

# ============ 8. the state sweep deletes by IDENTITY, not by pathname (#305) ==================
# THE BUG: `/cleanup` reached a verdict for a RECORD and then handed that record's PATH to `rm`. A
# fresh `/implement-issue` preflight clears the previous run's artifacts and writes its own at the
# same fixed names, so a path judged stale can be occupied by a LIVE run's file by the time the
# delete loop reaches it — and it deletes it. The `marker` arm never had this; it re-captures the
# file's identity immediately before `rm`. The four deleting arms did not.
#
# THIS SECTION RUNS THE REAL WORKFLOW BLOCK, extracted by its ADB-SNIPPET marker, exactly as
# section 7 runs the currency step. That is deliberate and it is the difference between this and
# section 3b's mirrored loop: a copied comparison passes forever after the prose it copies has
# been rewritten, and the acceptance criteria for this issue are about what the SWEEP does.
#
# THE RACE IS MADE DETERMINISTIC, not raced. `{{CLEANUP_LIB}}` resolves to a wrapper that forwards
# every call to the real library and, on the last PRE-LOOP family verdict (`review`), runs the
# replacement — a point that is after the scan has captured its identities and before the delete loop
# starts. Not "the last verdict call": each `threads` record asks `state-verdict threads` later, from
# inside that loop. No scheduler,
# no sleep, no flake. If a future edit moved the identity capture to AFTER the verdicts, the wrapper
# would fingerprint the successor and this section would go red, which is the correct direction.
#
# AND THE FIXTURE PROVES ITSELF. Before asserting that the guarded sweep keeps the replacement, the
# same fixture is driven through the pre-#305 loop — judge from a scan, delete by pathname — which
# MUST delete it. A guard is not done until it has been observed failing (base/practices/
# self-review.md), and an in-tree control is how that observation stops being a one-off.
SW="$work/sweep305"
mkdir -p "$SW"
SW_SNIPPET="${ check_wf_snippet "$WF" state-sweep; }"
[ -n "$SW_SNIPPET" ] || bad "8 snippet 'state-sweep' not found in base/workflows/cleanup.md (marker removed or renamed?)"

# One file of every deletable kind, all belonging to a FINISHED run: no lock and no marker, so every
# arm's verdict is `stale` and every one of them would delete.
#
# `touch -t` for the same reason section 2d2 uses it: the judged file was written by a run that has
# already finished, so its mtime is genuinely older than the replacement's. Seeding it removes the
# one way this fixture could flap — a filesystem reusing a just-freed inode inside one second.
sw_fixture() {   # <state-dir>
  rm -rf "${1:?}"; mkdir -p "$1"
  printf 'the same issue json\n' > "$1/issue-7.json"     # replaced, IDENTICAL bytes
  printf 'OWNER'                 > "$1/issue-7.assoc"    # replaced, IDENTICAL bytes
  printf 'old prompt\n'          > "$1/gap-prompt.txt"   # replaced, IDENTICAL bytes
  printf '{"n":1}\n'             > "$1/threads-7.json"   # rewritten IN PLACE (same inode)
  printf 'old review\n'          > "$1/review.md"        # replaced by a DANGLING SYMLINK
  printf 'sentinel\n'            > "$1/gaps.md"          # NEVER touched: this one must still die
  touch -t 202601010000 "$1"/issue-7.json "$1"/issue-7.assoc "$1"/gap-prompt.txt \
                        "$1"/threads-7.json "$1"/review.md "$1"/gaps.md
}
# The fresh /implement-issue run, in one script because the wrapper is a separate process. Every
# shape a replacement can take, so no arm passes for a reason the others do not share.
cat > "$SW/replace" <<'SWREP'
d="$1"
rm -f "$d/issue-7.json";   printf 'the same issue json\n' > "$d/issue-7.json"
rm -f "$d/issue-7.assoc";  printf 'OWNER'                 > "$d/issue-7.assoc"
rm -f "$d/gap-prompt.txt"; printf 'old prompt\n'          > "$d/gap-prompt.txt"
printf '{"n":1}\n' > "$d/threads-7.json"        # `>` truncates IN PLACE: same inode, same bytes
rm -f "$d/review.md"; ln -s "$d/nothing-here" "$d/review.md"   # identity becomes UNREADABLE
SWREP
cat > "$SW/cl" <<SWWRAP
#!/usr/bin/env bash
# \$STATE reaches here through the environment the snippet runs under.
if [ "\$1" = state-verdict ] && [ "\$2" = review ]; then
  bash "$SW/replace" "\$STATE" || exit 2
fi
exec bash "$CL" "\$@"
SWWRAP

# --- 8a. the CONTROL: the pre-#305 loop loses the live run's files ----------------------------
sw_fixture "$SW/before"
sw_scan="${ bash "$CL" state-scan "$SW/before"; }"
# Each victim's identity AS JUDGED — captured here, while the scan is still the truth.
declare -A sw_judged=()
for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json review.md; do
  sw_judged["$f"]="${ bash "$CL" file-identity "$SW/before/$f"; }"
done
bash "$SW/replace" "$SW/before"
# THE FIXTURE MUST ACTUALLY SUBSTITUTE, and this is asserted rather than assumed. "The unguarded
# loop deleted it" is satisfied just as well by a loop deleting the ORIGINAL file — which is simply
# /cleanup working correctly — so without this pair the control would pass while reproducing nothing
# and 8b would be guarding a race the suite never creates. Observed: neutering the replacement left
# the old control green.
# `review.md` is included, and its replacement is a DANGLING SYMLINK — so its judged identity must
# become UNREADABLE rather than merely different. Omitting it left the one arm whose replacement has
# a different shape unproven on both sides of this section.
for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json review.md; do
  hasnt "${ bash "$CL" file-identity "$SW/before/$f"; }" "${sw_judged[$f]}" \
     "8a the fixture really does replace $f with a different file"
done
eq "${ bash "$CL" file-identity "$SW/before/review.md"; }" "" \
   "8a …and review.md's replacement has no readable identity at all" 
while IFS="$TAB" read -r sw_kind sw_file _; do
  case "$sw_kind" in gaps|issue|review|threads) rm -f "$sw_file" ;; esac
done <<SWEOF
$sw_scan
SWEOF
# `-e` FOLLOWS a symlink, so a dangling one reads as absent whether or not `rm` ran — for review.md
# the question is whether the LINK survives, which is `-L`.
for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json; do
  if [ -e "$SW/before/$f" ]; then
    bad "8a the control loop did not reproduce the race for $f — the fixture proves nothing"
  else ok; fi
done
if [ -L "$SW/before/review.md" ]; then
  bad "8a the control loop did not reproduce the race for review.md — the fixture proves nothing"
else ok; fi

# --- 8b. the REAL sweep keeps every replacement, and still removes the untouched one -----------
sw_fixture "$SW/after"
sw_code="${SW_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$SW/cl\"}"
# `"$BASH"`, NEVER a bare `bash`. The suite re-execs itself into a 5.3 interpreter, but a nested
# `bash -c` re-resolves from PATH — and on macOS that is /bin/bash 3.2, where this block once
# silently produced NOTHING and the section failed for a reason that had nothing to do with the
# guard. Section 8e below deliberately runs the same fixture under the OLD interpreter, which is
# where a portability regression belongs; here the interpreter must be pinned or 8b is measuring
# the host.
sw_out="$(env STATE="$SW/after" RUN=none NOTES="" CLEARED="" "$BASH" -c '
TABC="$(printf "\t")"
pr_state() { printf "merged\n"; }   # a merged PR is what makes the threads cache sweepable
'"$sw_code"'
printf "CLEARED<%s>\n" "$(printf "%s" "$CLEARED" | tr "\n" ";")"
printf "NOTES<%s>\n"   "$(printf "%s" "$NOTES"   | tr "\n" ";")"' 2>&1)"
sw_cleared="${ printf '%s\n' "$sw_out" | sed -n 's/^CLEARED<\(.*\)>$/\1/p' | head -n1; }"
sw_notes="${ printf '%s\n' "$sw_out" | sed -n 's/^NOTES<\(.*\)>$/\1/p' | head -n1; }"

for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json; do
  if [ -e "$SW/after/$f" ]; then ok; else
    bad "8b THE BUG: the sweep deleted $f, which a live run had just written at that path"
  fi
done
# A replacement whose identity cannot be READ is the other half of failing closed: empty never
# equals the judged value, so it keeps — it must not be mistaken for "unchanged".
if [ -L "$SW/after/review.md" ]; then ok; else
  bad "8b a replacement with an unreadable identity (a dangling symlink) was deleted"
fi
# …and the sweep must not have over-corrected into a no-op. `gaps.md` was never touched, so it is
# exactly what /cleanup exists to remove.
if [ -e "$SW/after/gaps.md" ]; then
  bad "8b the sweep left an untouched stale artifact — the guard turned the sweep into a no-op"
else ok; fi
has "$sw_cleared" 'gaps.md' "8b …and the removal it DID make is reported as cleared"

# --- 8c. a kept file is REPORTED, never silently retained --------------------------------------
# The two outcomes are different facts and the output contract keeps them apart: `SKIPPED … kept`
# means the file is not ours any more, `REFUSED … left in place` means it IS ours and `rm` failed.
# Collapsing them would tell an operator to go fix directory permissions that are perfectly fine.
for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json review.md; do
  has "$sw_notes" "SKIPPED $f" "8c the kept $f is reported, not silently retained"
done
has "$sw_notes"   'no longer the file that was judged; kept' "8c …in the SKIPPED … kept note shape"
hasnt "$sw_notes" 'REFUSED' "8c …and never as REFUSED, which means an rm that actually failed"

# --- 8d. source-drift: the identity really is captured WITH the scan --------------------------
# Late capture is the defect that looks identical to the fix. Fingerprinting a path after the
# verdict calls describes whatever arrived in the meantime, so the comparison compares a replacement
# against itself and always matches — a guard that runs, prints nothing, and protects nothing. 8b
# catches a capture moved AFTER the wrapper's hook (observed red); it cannot catch one moved between
# the scan and the hook, which is what the structural pins here are for.
sw_at() { printf '%s\n' "$SW_SNIPPET" | grep -n -- "$1" | head -n1 | cut -d: -f1; }
sw_ident="${ sw_at 'state-scan --with-identity'; }"
sw_verdict="${ sw_at 'state-verdict gaps'; }"
sw_loop="${ sw_at 'sweep_file "$sfile" "$ident"'; }"
if [ -n "$sw_ident" ] && [ -n "$sw_verdict" ] && [ "$sw_ident" -lt "$sw_verdict" ]; then ok; else
  bad "8d the identity-bearing scan must precede the verdict calls (scan@${sw_ident:-?} verdict@${sw_verdict:-?})"
fi
# THE IDENTITY MUST COME FROM THE SCAN, not from a pass over its records. A derived set built here
# fingerprints whatever occupies each path AFTERWARDS, which is the defect this issue is about,
# reintroduced one layer up — and it passes 8b, because the wrapper fires later than either. Only a
# structural pin can see the difference.
# NARROW, and deliberately so: `sweep_file`'s delete-time re-capture (`file-identity "$1"`) is the
# other half of the guard and must stay. What must never come back is fingerprinting a SCAN RECORD's
# path — `file-identity "$sfile"` — which is the derived-set shape the review rejected.
hasnt "${ printf '%s\n' "$SW_SNIPPET" | sed 's/[[:space:]]*#.*$//'; }" 'file-identity "$sfile"' \
   "8d the workflow never fingerprints a scan record's path — the scan binds identity to classification"
has "${ printf '%s\n' "$SW_SNIPPET" | sed 's/[[:space:]]*#.*$//'; }" 'file-identity "$1"' \
   "8d …while the delete-time re-capture, the other half of the guard, is still there"
if [ -n "$sw_loop" ] && [ -n "$sw_ident" ] && [ "$sw_loop" -gt "$sw_ident" ]; then ok; else
  bad "8d …and the delete loop must consume it (capture@${sw_ident:-?} sweep@${sw_loop:-?})"
fi
# The delete loop must read the identity-bearing scan. A plain `state-scan` here would leave
# `$ident` empty for every record — `sweep_file` would then keep everything, and the sweep would be a
# silent no-op that passes 8b's survival assertions for entirely the wrong reason.
eq "${ printf '%s\n' "$SW_SNIPPET" | grep -c 'state-scan --with-identity'; }" "1" \
   "8d the pre-delete scan asks for identities"
# Four variables, or the identity lands in `$key` and the threads arm queries a PR number that is
# really a checksum.
has "$SW_SNIPPET" 'read -r kind sfile key ident' "8d …and parses all four fields"
# EVERY deleting arm, not just the one this issue was reported against.
for arm in gaps issue review threads; do
  has "$SW_SNIPPET" "    $arm)" "8d the $arm arm is present in the sweep"
done
eq "${ printf '%s\n' "$SW_SNIPPET" | grep -c 'sweep_file "\$sfile" "\$ident"'; }" "4" \
   "8d …and all four pass the judged identity to the delete"
hasnt "${ printf '%s\n' "$SW_SNIPPET" | sed 's/[[:space:]]*#.*$//'; }" 'sweep_file "$sfile"
' "8d no arm still deletes by pathname alone"

# --- 8e. the block must also run on the interpreter an AGENT will use --------------------------
# The fenced blocks in a workflow are executed by the AGENT's shell, not by one of this repo's
# floor-gated entry points — and on macOS a shell that has not picked up Homebrew's prefix is
# /bin/bash 3.2.57. `base/practices/shell.md` holds inline contexts to portable semantics for
# exactly this reason.
#
# THIS IS NOT THEORETICAL. The first version of this fix built its identity set with a here-document
# inside `$( … )`. Bash 5.3 runs it; 3.2 mis-parses it and assigns the loop's literal TEXT, so the
# whole sweep silently did nothing — and every survival assertion in 8b passed, because a sweep that
# deletes nothing keeps everything. Only the untouched-sentinel assertion caught it. 8b now pins its
# interpreter so it measures the guard rather than the host; this section is where the other
# interpreter is exercised on purpose.
#
# `/bin/bash` and not a re-derivation of `adb_bash_candidates`' oldest entry: that selection already
# has one home (`check-bash-floor.sh --sub-floor`) and a second copy of it here would be the drift
# this repo bans. The question here is narrower anyway — "does it also work on the other interpreter
# this host actually has?" — and when /bin/bash IS the suite's own interpreter there is nothing new
# to learn, so the case announces a SKIP rather than passing silently.
if [ -x /bin/bash ] && [ "${ /bin/bash -c 'printf %s "$BASH_VERSION"'; }" != "${BASH_VERSION}" ]; then
  sw_fixture "$SW/old"
  env STATE="$SW/old" RUN=none NOTES="" CLEARED="" /bin/bash -c '
TABC="$(printf "\t")"
pr_state() { printf "merged\n"; }
'"${SW_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$SW/cl\"}" >/dev/null 2>&1
  for f in issue-7.json issue-7.assoc gap-prompt.txt threads-7.json; do
    if [ -e "$SW/old/$f" ]; then ok; else
      bad "8e under /bin/bash the sweep deleted $f, which a live run had just written"
    fi
  done
  # The sentinel is what makes this section able to fail at all: a block that does not run deletes
  # nothing, which satisfies every survival assertion above it.
  if [ -e "$SW/old/gaps.md" ]; then
    bad "8e under /bin/bash the block did not run — an untouched stale artifact survived (parse or portability failure)"
  else ok; fi
else
  check_note "8e SKIPPED the old-interpreter pass: /bin/bash is absent, or is this suite's own interpreter (${BASH_VERSION})"
fi

# --- 8f. the two fail-closed inputs that are not a mismatch -----------------------------------
# `sweep_file` keeps on THREE distinct inputs and only one of them is "the identity differs". The
# other two are absences, and an implementation that tested only inequality would pass 8b while
# deleting a file whose identity it never managed to read.
sw_fixture "$SW/gone"
# A file that VANISHES between the scan and the delete: `rm -f` would succeed and `[ ! -e ]` would
# be true, so the pre-#305 code reported it CLEARED — a sweep claiming credit for a removal it did
# not perform, on a path a live run may be about to write.
cat > "$SW/gone-replace" <<'SWGONE'
rm -f "$1/issue-7.json"
SWGONE
cat > "$SW/cl-gone" <<SWGW
#!/usr/bin/env bash
if [ "\$1" = state-verdict ] && [ "\$2" = review ]; then bash "$SW/gone-replace" "\$STATE" || exit 2; fi
exec bash "$CL" "\$@"
SWGW
sw_gone_out="$(env STATE="$SW/gone" RUN=none NOTES="" CLEARED="" "$BASH" -c '
TABC="$(printf "\t")"
pr_state() { printf "merged\n"; }
'"${SW_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$SW/cl-gone\"}"'
printf "CLEARED<%s>\n" "$(printf "%s" "$CLEARED" | tr "\n" ";")"
printf "NOTES<%s>\n"   "$(printf "%s" "$NOTES"   | tr "\n" ";")"' 2>&1)"
sw_gone_cleared="${ printf '%s\n' "$sw_gone_out" | sed -n 's/^CLEARED<\(.*\)>$/\1/p' | head -n1; }"
sw_gone_notes="${ printf '%s\n' "$sw_gone_out" | sed -n 's/^NOTES<\(.*\)>$/\1/p' | head -n1; }"
hasnt "$sw_gone_cleared" 'issue-7.json' "8f a file that vanished mid-sweep is not reported as cleared by this run"
has   "$sw_gone_notes"   'SKIPPED issue-7.json' "8f …it is reported as skipped, because its identity could not be re-read"
# The other absence: the SCAN could not fingerprint it, so the judged identity is the `-` sentinel.
# file-identity can never print `-`, so this can only ever compare unequal — keep.
eq "${ bash "$CL" file-identity "$SW/gone/gaps.md"; }" "${ bash "$CL" state-scan --with-identity "$SW/gone" | awk -F'\t' '$1 == "gaps" && $2 ~ /gaps.md$/ { print $4; exit }'; }" \
   "8f a judged identity and a re-captured one agree for an untouched file (the delete path is reachable at all)"

check_summary "check-cleanup"
