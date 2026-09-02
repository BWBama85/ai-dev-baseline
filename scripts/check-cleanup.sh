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
# This file also owns the #38 remote-enumeration regression (#372): section 11 extracts the
# workflow's `remote-enum` block by marker and executes it against a real remote carrying an
# origin/HEAD symref. The standalone check-cleanup-enum.sh it retired pipelined a hardcoded COPY
# of that enumeration — green whatever the workflow actually said.
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
: > "$S/review-prompt-stage.k2Xb9Q"
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
eq "${ kindof review-prompt-stage.k2Xb9Q; }"   "review"  "3 …and its mktemp stage, which holds the diff before publication"
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
# through the loop shape base/workflows/cleanup.md step 5 runs (mirrored here — a fenced block
# full of `{{…}}` placeholders cannot be sourced — and section 6 pins that the real one still has
# these parts).
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

# --- 4a2. field integrity: a FOURTH field is refused, never truncated -------------------------
# The only way to produce one is a tab inside an item or a proof — a value that forged a field
# boundary. Rendering the head and dropping the tail is the silent direction, and silence is what
# makes a forged record dangerous. This is the whole of what a CONSUMER can enforce: a newline in a
# value has already become a record boundary by the time stdin is read, and no reader can tell it
# from a real one, which is why that half is a producer obligation (`adb_tsv_field_safe`).
printf 'C\tf.md\tproof\tSURPLUS\n' | rep >/dev/null 2>&1
eq "$?" "2" "4a2 a record with a fourth field is refused (2), not silently truncated"
eq "${ printf 'C\tf.md\tproof\tSURPLUS\n' | rep 2>/dev/null; }" "" \
   "4a2 …and renders nothing at all, rather than a plausible line built from half a record"
# The tail line must not survive the refusal: a lone state line is exactly what a clean sweep looks
# like, so printing it under a rejected report would report success for a sweep that was refused.
eq "${ printf 'C\tf.md\tp\tX\n' | rep --tail 'main: clean, in sync with origin/main' 2>/dev/null; }" "" \
   "4a2 …and the --tail state line is withheld too, so a refusal cannot read as a clean sweep"
# Three fields remain the contract, and the refusal must not have swallowed the legal case.
eq "${ printf 'C\tf.md\tproof\n' | rep --tail 'main: clean'; }" "C: f.md [proof]
main: clean" "4a2 a three-field record still renders, with its tail"

# --- 4b. the third field: every delete states its proof (#332) ---------------------------------
# The renderer half. `Deleted (local): fix/371` read identically whether the sweep was correct or
# catastrophic, so the record grew an optional proof column. Every case here is about the ONE thing
# that made this non-trivial: the proof must not destroy the brace collapse the category line
# depends on.
eq "${ printf 'C\tgaps.md\tno run in flight\n' | rep; }" "C: gaps.md [no run in flight]" \
   "4b a third field renders as a trailing bracket"
# BACKWARD COMPATIBILITY, asserted rather than assumed: every caller that predates #332 emits two
# fields, and an empty third must produce the pre-#332 string byte for byte — not "almost", since
# a trailing " []" would appear on every line of every sweep in every adopting repo.
eq "${ printf 'C\tgaps.md\n' | rep; }" "C: gaps.md" \
   "4b …and a record with NO third field renders exactly as it did before"
eq "${ printf 'C\tgaps.md\t\n' | rep; }" "C: gaps.md" \
   "4b …as does one with an EMPTY third field (no bare brackets)"
# THE COLLAPSE MUST SURVIVE. A per-item proof appended to the item string would put nine caches
# back on nine pieces, which is the thing `report` exists to prevent.
eq "${ printf 'C\tthreads-41.json\tPR merged\nC\tthreads-47.json\tPR merged\nC\tthreads-51.json\tPR merged\n' | rep; }" \
   "C: threads-{41,47,51}.json [PR merged]" \
   "4b items sharing a proof still collapse into one brace group"
# …AND MUST NOT OVER-COLLAPSE. A key that ignored the proof would merge these and print the FIRST
# member's proof over the whole group — attributing "merged" to a PR that was closed unmerged,
# which is a false statement about why a file was deleted, not a formatting nit.
eq "${ printf 'C\tthreads-41.json\tPR merged\nC\tthreads-47.json\tPR closed\nC\tthreads-51.json\tPR merged\n' | rep; }" \
   "C: threads-{41,51}.json [PR merged], threads-47.json [PR closed]" \
   "4b items with DIFFERENT proofs split into their own groups, each keeping its own"
eq "${ printf 'C\tthreads-41.json\tPR merged\nC\tthreads-47.json\n' | rep; }" \
   "C: threads-41.json [PR merged], threads-47.json" \
   "4b a proof and a bare item in one family do not merge"
# FIXTURE DATA, DEFINED ONCE — and the numbers in it are NOT citations.
#
# The number below is the illustrative one from #332's own report example, which quotes a
# transcript from a DIFFERENT repository; it resolves to nothing here, and `check-claims` was right
# to say so (it went red on this PR for exactly that — twice, the second time on an earlier draft
# of THIS comment, which explained the problem by spelling the number again). The digits cannot be
# dropped from the definition itself: the two controls below test
# `state-assert.sh lint`, whose grammar only fires on `#[0-9]+`, so a placeholder like `#N` would
# make them pass against a linter that checks nothing. Hence the audited escape rather than a
# rewrite — and hence one definition, so there is one line to audit instead of four.
#
# `#41` gets the same treatment even though it happens to RESOLVE in this repo: it is fixture data
# either way, and a reference that passes the lint by coincidence is exactly the inapt citation the
# claim-integrity lens is about.
CL_PR_PROOF='#379 (merge commit 3f9e9e5abcde)'   # adb-claim-ok: fixture data, not a citation
CL_BAD_NUMBERED='PR #41 merged'                  # adb-claim-ok: fixture data, the rejected spelling under test
# Ungrouped items are one group each already, so a distinct proof per branch costs no compaction.
eq "${ printf 'D\tfix/371\t%s\nD\tfeat/x\tcontained in origin/main\n' "$CL_PR_PROOF" | rep; }" \
   "D: fix/371 [$CL_PR_PROOF], feat/x [contained in origin/main]" \
   "4b ungroupable items each carry their own proof on one category line"
# THE PER-CATEGORY GROUP-KEY RESET, which is load-bearing in a way its four siblings are not.
# `gseen` is keyed by CONTENT (prefix, suffix and — since #332 — the proof); its five siblings
# (`gpre`, `gsuf`, `gmid`, `gnum`, `gdet`) are indexed by group number and overwritten at creation,
# so only this one can carry a stale entry across a category boundary and send an item into a group
# belonging to the previous one. Measured while writing this: deleting `split("", gseen)` fails
# exactly this assertion and nothing else in the suite, while deleting the gdet/gnum/gpre resets
# leaves every other case green. So this is the assertion that stands there, and the direction is
# real — `Deleted (local)` is always emitted before `Cleared state`.
eq "${ printf 'A\tx.md\tPROOF-A\nA\ty.md\tPROOF-A2\nB\tz.md\n' | rep; }" \
   "A: x.md [PROOF-A], y.md [PROOF-A2]
B: z.md" \
   "4b a later category never inherits an earlier one's proofs"
# #84's acceptance, RE-ASSERTED with proofs present: the line budget is what the bracket form was
# chosen to protect, so it is checked rather than argued.
typical332="$(printf 'Deleted (local)\tissue-3-generic-release\tcontained in origin/main\n%s\nCleared state\tgaps.md\tno run in flight\nCleared state\tgaps.err\tno run in flight\n' \
  "$(for n in 41 47 51 57 59 65 68 72 76; do printf 'Cleared state\tthreads-%s.json\tPR merged\n' "$n"; done)" \
  | rep --tail "main: clean, in sync with origin/main")"
eq "${ printf '%s\n' "$typical332" | grep -c .; }" "3" \
   "4b a typical sweep WITH proofs still emits exactly 3 lines (#84 budget preserved)"
has "$typical332" "threads-{41,47,51,57,59,65,68,72,76}.json [PR merged]" \
   "4b …with the nine caches still on one brace group, proof and all"

# THE CLAIM GRAMMAR (base/practices/verify-before-asserting.md). A report line routinely carries a
# `#N` (a squash-merge proof) and a status word (a cache's) AT THE SAME TIME, and `state-assert.sh
# lint` rejects that pairing unless it is introduced by `was observed`. The wording is therefore
# not a style choice, and the NEGATIVE control below is what proves this test can fail: the natural
# spellings — `merged into origin/main`, `PR #41 merged` — are exactly what a future edit would
# reach for, and they only violate when both verdicts land in one sweep.
SA="$ROOT/scripts/lib/state-assert.sh"
lintok() { printf '%s\n' "$1" | bash "$SA" lint >/dev/null 2>&1; }
if lintok "${ printf 'Deleted (local)\tfix/371\t%s\nDeleted (local)\tfeat/x\tcontained in origin/main\nCleared state\tthreads-41.json\tPR merged\n' "$CL_PR_PROOF" | rep; }"; then ok; else
  bad "4b the composed report violates the claim grammar — a proof word collides with a numbered reference"
fi
# The two rejected spellings, each shown to REALLY be rejected. Without these the assertion above
# would pass just as well against a linter that accepts everything.
if lintok "Deleted (local): fix/371 [$CL_PR_PROOF], feat/x [merged into origin/main]"; then
  bad "4b the claim lint did not reject 'merged into' beside a numbered reference — this guard cannot fire"
else ok; fi
if lintok "Cleared state: threads-41.json [$CL_BAD_NUMBERED]"; then
  bad "4b the claim lint did not reject a numbered PR status — this guard cannot fire"
else ok; fi

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
  # --- #332: the proof is CARRIED, and its transport cannot quietly become invisible ----------
  # `$TABC`, never a literal tab. A raw tab in a fenced block is load-bearing punctuation that is
  # invisible in the source, in all three renders and in review — and an editor that turned it into
  # spaces would fold each delete's proof into the item's NAME with no error anywhere. This is the
  # one assertion that can see that happen, since a spaces version still parses and still runs.
  # NO CARVE-OUT. `emit`'s `printf '%s\t%s\n'` is a backslash and a `t`, not a tab, so nothing in
  # these blocks legitimately holds one — and a filter that exempted that line would be exactly
  # what hides the next real one.
  hasnt "${ printf '%s\n' "$wfcode" | sed 's/[[:space:]]*#.*$//'; }" "$TAB" \
     "6 no fenced block carries a literal tab — the record separator is \$TABC"
  eq "${ printf '%s\n' "$wfcode" | grep -c 'TABC="\$(printf'; }" "1" \
     "6 …defined exactly once, in step 1, for the whole run"
  # The three accumulators each pair an item with the proof its own verdict produced. A bare
  # append is the pre-#332 line and is what this issue exists to remove.
  has "$wfcode" 'DELETED_LOCAL="${DELETED_LOCAL}${b}${TABC}${PROOF}' \
     "6 a local delete records the proof its verdict returned"
  has "$wfcode" 'DELETED_REMOTE="${DELETED_REMOTE}${b}${TABC}contained in $BASE' \
     "6 a remote delete records the ancestry its enumeration proved"
  # --- #346(a): the remote delete carries a LEASE, and the by-name form never comes back --------
  # The executed cases in section 11 prove the behaviour against a real remote. These pin the two
  # spellings a revert would reach for, because a by-name delete that happens not to race is
  # indistinguishable from a leased one in every fixture that does not stage a concurrent push.
  has "$wfexec" 'git push origin --force-with-lease="refs/heads/$b:$oid" --delete "refs/heads/$b"' \
     "6 the remote delete is an expected-OID compare-and-delete, like the local one"
  hasnt "$wfexec" 'git push origin --delete "$b"' \
     "6 …and never the by-name delete it replaced, which removes the ref whatever it points at now"
  # THE OID COMES FROM THE ENUMERATION, not from a second read at delete time. A re-read is the bug
  # wearing the fix`s clothes (#305): it is a different moment, so it would lease the delete to a
  # tip that arrived AFTER the containment was proved. Nothing else here can see that substitution —
  # both spellings run, both lease, both usually succeed.
  has "$wfexec" '%(objectname)' \
     "6 the tip is captured BY the --merged enumeration that proves containment"
  hasnt "$wfexec" 'oid="$(git rev-parse' \
     "6 …never re-read at delete time, which would lease against a tip nothing proved"
  # A record with no tip must be KEPT, not deleted on the weaker evidence. Pinned as the label bound
  # to its body: a bare `[ -z "$oid" ]` survives a body rewritten to fall through to a by-name push.
  has "$wfcode" 'if [ -z "$oid" ]; then
    NOTES="${NOTES}SKIPPED origin/$b' \
     "6 an unleasable remote record is reported and kept, never deleted by name"
  # --- #346(b): the PR close is GATED, follows a successful delete, and reads nothing else -------
  # The OID gate is the entire safety property: without it this closes a PR describing content the
  # sweep never proved. `hasnt` on the ungated shapes has no teeth (there are too many), so pin the
  # comparison itself, bound to the refusal it guards.
  has "$wfcode" 'if [ "$PRHEAD" != "$TIP" ]; then' \
     "6 a PR is closed only when its head is still the tip the verdict was computed from"
  has "$wfexec" 'NOTES="${NOTES}REFUSED closing PR $PRNUM for $b' \
     "6 …and a head that moved is a loud refusal naming the PR, never a close"
  # ONLY GitHub-assigned fields. The PR body is third-party text (base/practices/untrusted-content.md)
  # and must never reach a decision or the report; `--json number,headRefOid` is what enforces that,
  # so a widened field list is the regression to catch.
  has "$wfexec" '--json number,headRefOid --jq' \
     "6 the open-PR read takes only GitHub-assigned fields — never the untrusted PR body"
  # ALL FOUR gh CALLS TAKE </dev/null (list, close, view, reopen). This arm runs inside the
  # candidate loop, whose stdin is the `$CANDIDATES` heredoc; a child that read stdin would swallow
  # the rest of the list and the sweep would process ONE branch and stop, reporting success. Nothing
  # else here can see that — every fixture that happens to feed one candidate passes either way, and
  # section 12's does not exercise it because the stub reads no stdin. Counted, so losing one fails.
  eq "${ printf '%s\n' "$wfexec" | grep -c '</dev/null'; }" "4" \
     "6 all four gh calls in the PR-close arm are stdin-protected against swallowing the candidate list"
  # --- PR #393 review: the four close-arm hardenings, pinned as text. The executed cases live in
  # section 12 (12k-12n); these pin the spellings a quiet revert would remove.
  has "$wfexec" 'unset GH_REPO' \
     "6 the sweep neutralizes GH_REPO before its first gh call, so every read and mutation is anchored to the checkout the proof used"
  has "$wfexec" '--base "$DEFAULT" --state open' \
     "6 the open-PR query is scoped to the base the containment proof speaks for"
  has "$wfcode" 'if [ "$OPENPR_N" -ge "$OPENPR_LIMIT" ]; then' \
     "6 a list at the hard cap is treated as a possible subset — refused, never closed from"
  has "$wfexec" 'POSTHEAD="$(gh pr view "$PRNUM" --json headRefOid' \
     "6 the head is re-read AFTER the close, because gh pr close cannot be leased"
  has "$wfexec" 'gh pr reopen "$PRNUM"' \
     "6 …and a post-close head that is not the proved tip is compensated by a reopen"
  has "$wfcode" 'present; liveness could not be verified — kept fail-closed' \
     "6 an unverifiable marker is reported without claiming a live run"
  # THE CLOSE FOLLOWS A DELETE THAT SUCCEEDED. cleanup.md`s guardrail has no PR-shaped exception:
  # an unmerged branch`s PR is live work. Structurally: the close must sit between the successful
  # `update-ref` and the `else` arm that reports a refusal, so a close hoisted out of that arm —
  # which would run for a branch still sitting there — fails here.
  wf_del="${ printf '%s\n' "$wfcode" | grep -n 'if git update-ref -d "refs/heads/\$b" "\$TIP"' | head -n1 | cut -d: -f1; }"
  wf_close="${ printf '%s\n' "$wfcode" | grep -n 'gh pr close "\$PRNUM"' | head -n1 | cut -d: -f1; }"
  wf_else="${ printf '%s\n' "$wfcode" | awk -v d="${wf_del:-0}" 'NR > d && /^      else$/ { print NR; exit }'; }"
  if [ -n "$wf_del" ] && [ -n "$wf_close" ] && [ -n "$wf_else" ] \
     && [ "$wf_close" -gt "$wf_del" ] && [ "$wf_close" -lt "$wf_else" ]; then ok; else
    bad "6 the PR close must sit inside the SUCCESSFUL-delete arm (delete@${wf_del:-?} close@${wf_close:-?} else@${wf_else:-?})"
  fi
  # The proof written to the PR is the one already in hand. A `branch-verdict` call inside the
  # comment would be a second read — and for a deleted branch it is not even answerable.
  hasnt "$wfexec" '--comment "Closed by /cleanup: the branch $b was deleted after its content was proved $({{CLEANUP_LIB}}' \
     "6 the closing comment carries the carried proof, never a re-query"
  # --- #350: the marker report reads the DELETE scan, and decides nothing ------------------------
  # It must render `state-verdict`s answers, not grow a verdict of its own — `other` is still never
  # touched. The one thing it may not do is call `rm`.
  has "$wfcode" '{{CLEANUP_LIB}} marker-shape' \
     "6 the marker report asks the library the family question, not a second copy of the allowlist"
  mrblock="${ printf '%s\n' "$wfcode" | awk '/# ADB-SNIPPET: marker-report/ { inb = 1 } inb { print } inb && /^EOF$/ { exit }'; }"
  # COMMENT-STRIPPED for the negatives, exactly as `wfexec` is built above and for the same reason:
  # this block explains at length what it does NOT do, and `arm that stopped matching` contains the
  # substring `rm ` — observed failing on its own prose before the strip was added.
  mrexec="${ printf '%s\n' "$mrblock" | sed 's/[[:space:]]*#.*$//'; }"
  if [ -n "$mrblock" ]; then
    hasnt "$mrexec" 'rm -f'          "6 …and the marker report never deletes anything"
    hasnt "$mrexec" 'state-verdict'  "6 …nor re-decides what state-verdict already decided"
    has   "$mrblock" 'read -r kind sfile key ident' \
       "6 …and reads FOUR fields, so the --with-identity scan cannot fold an identity into \$key"
  else
    bad "6 could not read the marker-report block from the workflow — its pins asserted NOTHING"
  fi
  # --- both issues: the composer is wired. Nothing else executes this line ----------------------
  # Every harness in this suite renders its own category label, so an accumulator that never reached
  # `emit` would leave all of them green while the operator saw nothing at all.
  has "$wfcode" "emit 'PR closed'        \"\$PR_CLOSED\"" \
     "6 the PR-closed accumulator reaches the report composer"
  has "$wfcode" "emit 'Run marker'       \"\$RUNMARK\"" \
     "6 …as does the run-marker accumulator"
  # …and both are INITIALIZED in step 1, with every other accumulator. A scope that skips the step
  # that fills one must still leave the report a defined, empty variable to work from.
  has "$wfcode" 'PR_CLOSED=""; RUNMARK=""' \
     "6 both new accumulators are initialized in step 1, beside the ones they join"
  has "$wfcode" 'CLEARED="${CLEARED}${1##*/}${TABC}${3:-}' \
     "6 a swept state file records the proof its caller passed in"
  # Both verdicts named explicitly. A `*)` standing in for merged-ff would hand its proof to any
  # third word that later joined that label — asserting containment nothing proved.
  has "$wfexec" 'merged-ff) PROOF="contained in $BASE"' \
     "6 the fast-forward proof is bound to its own verdict word, not to a catch-all"
  # THE PROOF MUST BE THE VALUE ALREADY IN HAND. `pr_state` inside the sweep_file argument would be
  # a SECOND live read — a different moment, and a second round trip per cache — which is the
  # staleness that makes the report untrustworthy. Nothing else here can see that substitution:
  # both spellings run and both print a plausible proof.
  has "$wfexec" 'PRST="$(pr_state "$key")"' "6 the thread arm captures the PR state once"
  hasnt "$wfexec" 'sweep_file "$sfile" "$ident" "PR $(pr_state' \
     "6 …and the proof reuses it rather than re-reading at report time"
  # `merged into` is the natural fast-forward wording and it is a claim-grammar violation whenever a
  # squash-merged sibling puts a #N on the same line — i.e. only in mixed sweeps, which is exactly
  # when nobody is looking. Pinned as a negative because the correct spelling is not self-evident.
  has "$wfexec" 'PROOF="contained in $BASE"' "6 the fast-forward proof avoids a status word (claim grammar)"
  hasnt "$wfexec" 'PROOF="merged into' "6 …and never reaches for the spelling that collides with a #N"
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
    eq "$sweeparms" "gaps survey issue review docs threads " \
       "6 the sweep loop's delete arms are EXACTLY gaps/issue/review/docs/threads — no default arm, so 'unsafe' cannot be deleted"
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
  iiprompt="${ printf '%s\n' "$ii" | grep -n '{{IMPLEMENT_LIB}} dispatch-gaps' | head -n1 | cut -d: -f1; }"
  if [ -n "$iitake" ] && [ -n "$iiprompt" ] && [ "$iitake" -lt "$iiprompt" ]; then ok; else
    bad "6 the claim must be taken BEFORE the gap prompt is built (admit@${iitake:-?} dispatch-gaps@${iiprompt:-?})"
  fi
  # The release must NOT sit in the same fenced block as the dispatch: that block is dispatched
  # to the harness's DETACHED facility, so a release appended to it drops the claim immediately
  # and leaves it unheld for the whole pass — the only window it exists for.
  iidisp="${ printf '%s\n' "$ii" | grep -n '{{IMPLEMENT_LIB}} dispatch-gaps --token' | head -n1 | cut -d: -f1; }"
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
  # `docs` joins them for #422 — the documentation-duty record, which carries what this run says
  # it consulted. Same obligation as the three older families: whatever /cleanup can sweep, `admit`
  # must be able to clear, or a previous run's stated disposition survives into a fresh run whose
  # marker makes it read as current.
  for armname in gaps issue review docs; do
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
  eq "$ilarms" "4" "6 all four artifact families (gaps, issue, review, docs) were actually read from state-scan"

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
for arm in gaps survey issue review docs threads; do
  has "$SW_SNIPPET" "    $arm)" "8d the $arm arm is present in the sweep"
done
eq "${ printf '%s\n' "$SW_SNIPPET" | grep -c 'sweep_file "\$sfile" "\$ident"'; }" "6" \
   "8d …and all six pass the judged identity to the delete"
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

# ============ 9. the branch sweep REPORTS the proof it computed (#332) ========================
# THE BUG: `branch-verdict` returns three lines — verdict, tip, evidence — and the sweep read all
# three, deleted using the tip, and appended only the branch NAME. `Deleted (local): fix/371` was
# therefore identical whether the sweep was correct or catastrophic, and the only remaining defence
# was an agent choosing, unprompted, to go re-derive by hand what the sweep already knew. That
# happened twice in one session, in two repos.
#
# THIS SECTION RUNS THE REAL WORKFLOW BLOCK, extracted by its ADB-SNIPPET marker, exactly as
# sections 7 and 8 do. A mirrored copy of the loop would pass forever after the prose it copies had
# been rewritten, and what this issue is about is what the SWEEP reports.
#
# `{{CLEANUP_LIB}}` resolves to a wrapper that returns a SCRIPTED verdict per branch. That is the
# point, not a shortcut: how a verdict is computed is section 1's subject, and what the workflow
# DOES with one is this section's. Scripting the verdict is also the only way to ask the question
# that matters — does the report carry the string this call returned? — because the wrapper can
# hand back a different string on a second call and the assertion can then tell the two apart.
BR="$work/branch332"
BRC="$BR/calls"
BR_SNIPPET="${ check_wf_snippet "$WF" branch-sweep; }"
[ -n "$BR_SNIPPET" ] || bad "9 snippet 'branch-sweep' not found in base/workflows/cleanup.md (marker removed or renamed?)"

check_make_repo_pair "$BR" "$work/remote332.git" || bad "9 fixture init failed"
(
  cd "$BR" || exit 1
  git checkout -q -b main
  git commit -q --allow-empty -m init
  git push -q -u origin main
) || bad "9 fixture build failed"
BR_MAIN="${ check_git "$BR" rev-parse refs/heads/main; }"

# REBUILT BEFORE EVERY RUN. The sweep DELETES br/pr and br/ff, so a second `br_run` over the same
# fixture would classify branches that no longer exist — the wrapper would hand back an empty tip,
# which the real library can never return, and the later cases would be asserting against an
# impossible verdict. Bot review, PR for #332, caught exactly that in 9g/9h.
br_fixture() {
  ( cd "$BR" || exit 1
    git checkout -q main
    for b in br/pr br/ff br/open br/unver br/refuse; do
      git rev-parse --verify --quiet "refs/heads/$b" >/dev/null || {
        git checkout -q -b "$b"
        git commit -q --allow-empty -m "$b work"
        git checkout -q main
      }
    done ) || bad "9 fixture rebuild failed"
}

# The wrapper. `br/pr` is the carry probe, and its answer is derived from LIVE STATE rather than a
# call counter: while the ref exists the verdict is the SENTINEL, and once the sweep has deleted it
# any later read is a different moment and gets the POISON. That is the issue's acceptance criterion
# literally — "a fixture whose live state changes after classification" — and it is deterministic,
# because the state that changes is the delete this very block performs.
#
# The counter is kept, but only to assert HOW MANY times the question was asked.
#
# `br/refuse` returns main's OID as the tip, so the real `git update-ref -d refs/heads/br/refuse
# <main>` fails the compare-and-delete and takes the REFUSED arm with no race to stage.
cat > "$BR/cl" <<BRWRAP
#!/usr/bin/env bash
if [ "\$1" = branch-verdict ]; then
  b="\$2"
  safe="\$(printf '%s' "\$b" | tr '/' '_')"
  mkdir -p "$BRC"
  n=\$(( \$(cat "$BRC/\$safe" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\$n" > "$BRC/\$safe"
  tip="\$(git rev-parse --verify --quiet "refs/heads/\$b")"
  case "\$b" in
    br/pr)
      # The ref is GONE -> this read happens after the delete -> a different answer. A stub that
      # returned a merged verdict with an empty tip would be describing something the real library
      # cannot produce, so say so loudly instead.
      if [ -n "\$tip" ]; then printf 'merged-pr\n%s\n#7 (merge commit SENTINELCAFE)\n' "\$tip"
      else                    printf 'merged-pr\n%s\n#999 (merge commit POISONBEEF01)\n' "$BR_MAIN"; fi ;;
    br/ff)     [ -n "\$tip" ] || { printf 'stub: br/ff read after deletion\n' >&2; exit 3; }
               printf 'merged-ff\n%s\n' "\$tip" ;;
    br/open)   printf 'unmerged\n%s\n' "\$tip" ;;
    br/unver)  printf 'unverified\n%s\nSENTINEL-UNVERIFIED-DETAIL\n' "\$tip" ;;
    br/refuse) printf 'merged-pr\n%s\n#8 (merge commit CAFEBABE1234)\n' "$BR_MAIN" ;;
    *) exit 2 ;;
  esac
  exit 0
fi
exec bash "$CL" "\$@"
BRWRAP

# br_run <extra-shell-code> — execute the extracted block in the fixture and leave DELETED_LOCAL and
# NOTES in files. FILES, not a captured string: DELETED_LOCAL is TAB-separated by design and a
# round trip through `$( )` plus `tr` is exactly where a separator quietly becomes something else.
# `"$BASH"` and never a bare `bash`, for the reason 8b states — a nested `bash -c` re-resolves from
# PATH, which on macOS is 3.2.
br_run() {   # [snippet-body] — defaults to the real extracted block
  rm -rf "$BRC"
  br_fixture
  local body="${1:-$BR_SNIPPET}"
  ( cd "$BR" && env "$BASH" -c '
BASE=origin/main
TABC="$(printf "\t")"
WORKTREES=""
HAVE_GH=0
NOTES=""; DELETED_LOCAL=""
CANDIDATES="br/pr
br/ff
br/open
br/unver
br/refuse"
'"${body//\{\{CLEANUP_LIB\}\}/bash \"$BR/cl\"}"'
printf "%s" "$DELETED_LOCAL" > '"$BR"'/deleted_local
printf "%s" "$NOTES"         > '"$BR"'/notes' ) >/dev/null 2>&1
}
# The category line the operator actually sees, rendered through the real emit + report path rather
# than eyeballed from the accumulator.
br_line() {
  printf '%s\n' "$(cat "$BR/deleted_local")" \
    | while IFS= read -r x; do [ -n "$x" ] && printf 'Deleted (local)\t%s\n' "$x"; done \
    | bash "$CL" report
}

br_run ""
br_deleted="${ cat "$BR/deleted_local"; }"
br_notes="${ cat "$BR/notes"; }"
br_report="${ br_line; }"

# --- 9a. merged-pr: the library's own line 3, verbatim ----------------------------------------
has "$br_report" 'br/pr [#7 (merge commit SENTINELCAFE)]' \
   "9a a squash-merged branch reports the PR and merge commit that authorised its delete"
if [ -n "${ check_git "$BR" rev-parse --verify --quiet refs/heads/br/pr; }" ]; then
  bad "9a the sweep did not actually delete br/pr — the fixture proves nothing"
else ok; fi

# --- 9b. merged-ff: proof rendered from the VERDICT WORD, and no empty parenthetical -----------
# `merged-ff` emits no line 3 at all, so a fix that assumed one would print `br/ff []` on every
# fast-forward delete — the case the issue explicitly warns about.
has "$br_report" 'br/ff [contained in origin/main]' \
   "9b a fast-forward delete states its proof, rendered from the verdict word"
hasnt "$br_report" 'br/ff []' "9b …and never an empty parenthetical"
hasnt "$br_report" '[]'       "9b …nor anywhere else on the line"

# --- 9c. unmerged: still silent ---------------------------------------------------------------
hasnt "$br_deleted" 'br/open' "9c an unmerged branch produces no deleted record"
hasnt "$br_notes"   'br/open' "9c …and no note either — the terse contract for the common case is unchanged"
if [ -n "${ check_git "$BR" rev-parse --verify --quiet refs/heads/br/open; }" ]; then ok; else
  bad "9c the sweep deleted an unmerged branch"
fi

# --- 9d. unverified: the pre-existing $DETAIL note is UNCHANGED --------------------------------
# This arm was the ONE place $DETAIL was already used. The regression to guard against is a rewrite
# that reroutes the detail into the new proof channel and silently empties this note.
has "$br_notes" 'UNVERIFIED br/unver — SENTINEL-UNVERIFIED-DETAIL; preserved' \
   "9d an unverified branch keeps its existing loud note, detail intact"
hasnt "$br_deleted" 'br/unver' "9d …and is never recorded as deleted"

# --- 9e. REFUSED: a branch that moved is reported in full, with no proof attached ---------------
has "$br_notes" 'REFUSED br/refuse — it moved during the sweep; left in place' \
   "9e a failed compare-and-delete still reports in full"
hasnt "$br_deleted" 'br/refuse' \
   "9e …and a branch that was NOT deleted never gains a deleted record (its proof would assert a delete that did not happen)"
if [ -n "${ check_git "$BR" rev-parse --verify --quiet refs/heads/br/refuse; }" ]; then ok; else
  bad "9e the refused branch was deleted anyway"
fi

# --- 9f. THE CARRY PROPERTY: the reported proof is the one THIS call returned ------------------
# The issue's sharpest requirement. Re-deriving the evidence at report time would reintroduce the
# staleness that makes the output untrustworthy — and for the local half it is not even answerable,
# since the branch is gone by then.
has   "$br_report" 'SENTINELCAFE'  "9f the report carries the evidence the authorising call returned"
hasnt "$br_report" 'POISONBEEF01'  "9f …and never a value from a later re-query"
eq "${ cat "$BRC/br_pr" 2>/dev/null; }" "1" \
   "9f …because branch-verdict is asked exactly once per branch"

# --- 9g. THE CONTROL: 9f must be able to fail, and the witness is the REAL block, MUTATED ------
# A guard is not done until it has been observed failing (base/practices/self-review.md), and the
# observation has to be of the IMPLEMENTATION going wrong — not of the harness. An earlier version
# of this case ran the real block and then overwrote `DELETED_LOCAL` with a separately-queried
# poison value; that proves a test-authored assignment contains what the test just put in it, and
# nothing whatever about 9f. Bot review caught it.
#
# So the witness is the actual snippet with ONE substitution: the carried `$DETAIL` becomes a
# re-query, which is precisely the implementation the issue rules out ("never re-derived
# afterwards"). Everything else — the loop, the guards, the delete, the accumulator — is the
# shipped text.
#
# AND THE RE-QUERY READS GENUINELY DIFFERENT LIVE STATE. The delete happens on the line above, so
# by the time the mutated arm asks again the ref is gone and the wrapper answers as any real reader
# would after a deletion. That is the issue's "fixture whose live state changes after
# classification", with the change being the sweep's own mutation rather than a staged race.
BR_NEEDLE='merged-pr) PROOF="$DETAIL" ;;'
BR_REQUERY='          merged-pr) PROOF="$(printf %s "" | {{CLEANUP_LIB}} branch-verdict "$b" "$BASE" | sed -n 3p)" ;;'
BR_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | awk -v needle="$BR_NEEDLE" -v repl="$BR_REQUERY" 'index($0, needle) { print repl; next } { print }'; }"
# The mutation must actually have applied — a needle that silently stopped matching would leave
# this control running the CORRECT code and passing for the wrong reason, which is the same class
# of defect it exists to catch.
if [ "$BR_BROKEN" = "$BR_SNIPPET" ]; then
  bad "9g the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
br_run "$BR_BROKEN"
has "${ br_line; }" 'POISONBEEF01' \
   "9g the control (the real block, re-querying at record time) reports the post-delete value"
hasnt "${ br_line; }" 'SENTINELCAFE' \
   "9g …and loses the authorising evidence entirely, which is the defect 9f pins"

# --- 9h. the composed line satisfies the claim grammar -----------------------------------------
# Section 4b proves the wording is lint-clean; this proves the wording the WORKFLOW actually emits
# is. The two verdicts co-occurring is what makes it non-obvious: br/pr contributes a `#N` and any
# status word from br/ff's proof would then violate.
br_run ""
if printf '%s\n' "${ br_line; }" | bash "$ROOT/scripts/lib/state-assert.sh" lint >/dev/null 2>&1; then ok; else
  bad "9h the sweep's own report line violates the claim grammar"
fi

# ============ 10. the state sweep reports its proofs too (#332) ===============================
# `Cleared state: …, threads-379.json` was equally bare, and the issue asks for one answer across
# both halves rather than two. Every deleting arm now carries the facts ITS verdict consumed.
ST="$work/state332"
st_fixture() {   # a FINISHED run: no lock, no marker, nothing replaced -> every arm deletes
  rm -rf "${ST:?}"; mkdir -p "$ST"
  printf '{"n":1}\n'    > "$ST/threads-41.json"
  printf '{"n":2}\n'    > "$ST/threads-47.json"
  printf 'prompt\n'     > "$ST/gap-prompt.txt"
  printf 'findings\n'   > "$ST/gaps.md"
  printf 'review\n'     > "$ST/review.md"
  printf '{"i":7}\n'    > "$ST/issue-7.json"
}
# st_run <pr-state> — drive the real state-sweep block with pr_state stubbed to one answer, and
# count how many times it was asked. The count is the point as much as the proof: reporting the PR
# state must reuse the value the VERDICT consumed, not spend a second round trip per cache.
st_run() {
  st_fixture
  rm -f "$ST.prcalls"
  ( cd "$BR" && env STATE="$ST" RUN=none NOTES="" CLEARED="" PRWANT="$1" PRLOG="$ST.prcalls" "$BASH" -c '
TABC="$(printf "\t")"
pr_state() { printf "x" >> "$PRLOG"; printf "%s\n" "$PRWANT"; }
'"${SW_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$CLEARED" > '"$ST"'.cleared
printf "%s" "$NOTES"   > '"$ST"'.notes' ) >/dev/null 2>&1
}
st_line() {
  printf '%s\n' "$(cat "$ST.cleared")" \
    | while IFS= read -r x; do [ -n "$x" ] && printf 'Cleared state\t%s\n' "$x"; done \
    | bash "$CL" report
}

st_run merged
st_report="${ st_line; }"
has "$st_report" 'threads-{41,47}.json [PR merged]' \
   "10a a swept thread cache names the PR state that authorised it, and two of them still collapse"
has "$st_report" 'gaps.md [no run in flight]'       "10a a gap artifact states the liveness fact that authorised it"
has "$st_report" 'gap-prompt.txt [no run in flight]' "10a …as does the gap prompt"
has "$st_report" 'review.md [no run in flight]'      "10a …and a review artifact"
has "$st_report" 'issue-7.json [no run in flight]'   "10a …and the issue snapshot"
hasnt "$st_report" '[]' "10a no swept file carries an empty parenthetical"
# ONE read per cache, reused for both the verdict and the report. Two caches -> two calls; a report
# that re-asked would log four, which is both a second round trip and a DIFFERENT moment.
eq "${ wc -c < "$ST.prcalls" | tr -d ' '; }" "2" \
   "10a pr_state is asked once per cache — the report reuses the value the verdict consumed"

# CLOSED is not MERGED, and the report must not flatten them: a cache swept because its PR was
# abandoned is a different fact from one swept because the work landed.
st_run closed
has "${ st_line; }" 'threads-{41,47}.json [PR closed]' "10b a cache swept for a CLOSED PR says closed, not merged"

# The preserved directions, end to end rather than only at the predicate: an open or unreadable PR
# state keeps the cache, so it can never acquire a proof for a delete that did not happen.
st_run open
hasnt "${ cat "$ST.cleared"; }" 'threads-41.json' "10c a cache for an OPEN PR is not swept, and gains no proof"
if [ -e "$ST/threads-41.json" ]; then ok; else bad "10c an OPEN PR's cache was deleted"; fi
st_run unknown
hasnt "${ cat "$ST.cleared"; }" 'threads-41.json' "10c an unreadable PR state keeps the cache too"

# --- 10d. the marker arm, which has its own delete and its own facts ---------------------------
MK_SNIPPET="${ check_wf_snippet "$WF" marker-sweep; }"
[ -n "$MK_SNIPPET" ] || bad "10d snippet 'marker-sweep' not found in base/workflows/cleanup.md"
# <pr-state> <prUrl-present 0|1> — a marker whose branch is provably gone from both refs.
mk_run() {
  rm -rf "${ST:?}"; mkdir -p "$ST"
  if [ "$2" = 1 ]; then printf '{"branch":"gone/branch","prUrl":"https://x/pull/9"}\n' > "$ST/implement-issue-active.json"
  else                  printf '{"branch":"gone/branch"}\n' > "$ST/implement-issue-active.json"; fi
  ( cd "$BR" && env RUN=none NOTES="" CLEARED="" PRWANT="$1" "$BASH" -c '
TABC="$(printf "\t")"
pr_state() { printf "%s\n" "$PRWANT"; }
SCAN="$(bash '"$CL"' state-scan '"$ST"')"
'"${MK_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$CLEARED" > '"$ST"'.cleared' ) >/dev/null 2>&1
}
# RENDERED, not substring-matched on the accumulator. `CLEARED="…json branch gone"` — a SPACE where
# the tab belongs — satisfies any `has … 'branch gone'` check while rendering the proof as part of
# the FILENAME, with no bracket anywhere. That is a realistic slip (the separator is invisible) and
# the accumulator cannot see it; only the report can. Bot review caught this gap.
mk_run none 0
eq "${ st_line; }" "Cleared state: implement-issue-active.json [branch gone]" \
   "10d a swept run marker states that both refs were provably gone, through the real report path"
mk_run merged 1
eq "${ st_line; }" "Cleared state: implement-issue-active.json [branch gone, PR merged]" \
   "10d …and appends the PR state when one was actually read"
if [ -e "$ST/implement-issue-active.json" ]; then
  bad "10d the marker arm did not delete — the fixture proves nothing"
else ok; fi

# --- 10e. the state line, composed, must also satisfy the claim grammar ------------------------
st_run merged
if printf '%s\n' "${ st_line; }" | bash "$ROOT/scripts/lib/state-assert.sh" lint >/dev/null 2>&1; then ok; else
  bad "10e the state sweep's report line violates the claim grammar"
fi

# ============ 11. the REMOTE half states what it actually proved (#332) =======================
# The remote delete has no expected-OID compare-and-delete: `git push origin --delete` removes the
# ref BY NAME, whatever it points at now. So its evidence is strictly weaker than the local half's,
# and the wording has to say WHEN it was established rather than borrow the local half's certainty.
# Bot review raised this: a bare "contained in origin/main" would be the report asserting something
# the sweep never proved about the tip it actually removed.
#
# A textual pin cannot see any of that, so this drives the real block against a real remote.
RM="$work/remote-sweep"
RM_SNIPPET="${ check_wf_snippet "$WF" remote-sweep; }"
[ -n "$RM_SNIPPET" ] || bad "11 snippet 'remote-sweep' not found in base/workflows/cleanup.md"
check_make_repo_pair "$RM" "$work/remote-sweep-origin.git" || bad "11 fixture init failed"
(
  cd "$RM" || exit 1
  git checkout -q -b main
  git commit -q --allow-empty -m init
  git push -q -u origin main
  git checkout -q -b rm/merged
  git commit -q --allow-empty -m work
  git push -q -u origin rm/merged
  git checkout -q main
  git merge -q --no-ff rm/merged -m "merge rm/merged"
  git push -q origin main
  # The origin/HEAD symref, which `git branch -r --format='%(refname:short)'` renders as a BARE
  # `origin` — the #38 shape the enumeration below must filter out.
  git remote set-head origin main >/dev/null 2>&1
) || bad "11 fixture build failed"

# --- the ENUMERATION is the documented block too (#372/#38), and it now carries the TIP ---------
# The retired check-cleanup-enum.sh guarded this pipeline by testing a hardcoded copy of it, so
# deleting the symref filters from the workflow left both suites green. This extracts the
# `remote-enum` block from the workflow itself and runs it against the fixture's real remote:
# unfiltered, the bare `origin` symref reaches the merged list and step 4 offers
# `git push origin --delete origin`.
#
# #346 gives the block a SECOND job — emit `<name>TAB<oid>`, the tip the `--merged` enumeration
# actually proved — because the delete below leases against it. So this now asserts both the old
# filtering and the new field, and the two are inseparable: the filters had to become field-aware
# (`$PROTECTED` and `$CURRENT` are anchored patterns that a two-field line matches neither of), and
# a pipeline that kept the old whole-line greps would silently stop excluding a protected branch.
RE_SNIPPET="${ check_wf_snippet "$WF" remote-enum; }"
[ -n "$RE_SNIPPET" ] || bad "11 snippet 'remote-enum' not found in base/workflows/cleanup.md"
# Repro guard first: the RAW enumeration must surface the symref (bare `origin` on current git;
# a few builds render it `origin/HEAD`), or the fixture stopped exercising #38 and a green
# filter assertion below would mean nothing.
raw_enum="${ check_git "$RM" branch -r --merged origin/main --format='%(refname:short)'; }"
# A here-string, never `printf | grep -q`: under pipefail grep's early exit can hand printf an
# EPIPE, and the probe then reads as "not surfaced" over output that did surface it (observed
# under a loaded selfcheck; check-lib.sh states the rule).
if grep -Eqx 'origin|origin/HEAD' <<< "$raw_enum"; then ok; else
  bad "11 enum: fixture did not surface the origin/HEAD symref (raw: ${ printf '%s' "$raw_enum" | tr '\n' ' '; })"
fi
# The variables the workflow sets in its own earlier steps, mirrored for a fixture whose default
# branch is `main` and whose sweep runs from that branch — nothing else is pre-set, exactly as
# the snippet expects. `TABC` joins them because step 1 defines it for the whole run and the
# enumeration is now one of its consumers.
re_enum() {   # execute the DOCUMENTED enumeration in $RM; the produced list lands in $RM.enum
  ( cd "$RM" && env "$BASH" -c '
BASE=origin/main
CURRENT=main
TABC="$(printf "\t")"
PROTECTED="^(HEAD|main|master|develop|release/.*|hotfix/.*)$"
'"$RE_SNIPPET"'
printf "%s" "$REMOTE_MERGED" > '"$RM"'.enum' ) >/dev/null 2>&1
}
re_enum
hasnt "${ cat "$RM.enum"; }" 'origin' \
   "11 enum: the origin/HEAD symref is filtered out of the documented enumeration"
eq "${ cut -f1 < "$RM.enum"; }" "rm/merged" \
   "11 enum: the genuinely-merged branch survives every filter — and is the list's only entry"
# THE TIP, captured BY the enumeration that proved containment (#346). Asserted against the real
# remote-tracking ref rather than against a shape (`[0-9a-f]{40}`): a block that emitted the right
# NUMBER of fields with the wrong commit in the second one would satisfy any shape test, and would
# then lease every delete to a value nothing proved.
eq "${ cut -f2 < "$RM.enum"; }" "${ check_git "$RM" rev-parse refs/remotes/origin/rm/merged; }" \
   "11 enum: …carrying the remote tip the --merged enumeration proved, as a second field"
# The FILTERS still hold with a second field present. This is the regression the rewrite could most
# easily have introduced and nothing else here would see: `grep -Ev "$PROTECTED"` and
# `grep -Fxv "$CURRENT"` are whole-line tests, so `main<TAB><oid>` matches NEITHER and a protected
# branch sails through into `git push --delete`. Both are merged into themselves by definition, so
# an unfiltered enumeration lists them.
hasnt "${ cut -f1 < "$RM.enum"; }" 'main' \
   "11 enum: …and the protected/current filters still exclude the default branch, now field-aware"

rm_run() {   # <remote-branch-list> [snippet-body] — defaults to the real extracted block
  local body="${2:-$RM_SNIPPET}"
  ( cd "$RM" && env "$BASH" -c '
BASE=origin/main
TABC="$(printf "\t")"
NOTES=""; DELETED_REMOTE=""
REMOTE_MERGED="'"$1"'"
'"${body//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$DELETED_REMOTE" > '"$RM"'.deleted
printf "%s" "$NOTES"          > '"$RM"'.notes' ) >/dev/null 2>&1
}
rm_line() {
  printf '%s\n' "$(cat "$RM.deleted")" \
    | while IFS= read -r x; do [ -n "$x" ] && printf 'Deleted (remote)\t%s\n' "$x"; done \
    | bash "$CL" report
}

# The sweep consumes the list the DOCUMENTED enumeration just produced against the real remote —
# not a supplied one, so the two blocks are exercised end-to-end in the order the workflow runs them.
rm_run "${ cat "$RM.enum"; }"
rm_line_11a="${ rm_line; }"
eq "$rm_line_11a" "Deleted (remote): rm/merged [contained in origin/main]" \
   "11a a deleted remote branch reports the evidence its enumeration proved"
# `when enumerated` was the honest qualifier while the delete was BY NAME: the tip actually removed
# was not necessarily the tip that had been proved. The lease closes that gap, so the plain claim
# is now true of the ref that was really deleted — and the qualifier must go, or the report
# understates what the sweep now guarantees. Pinned as a NEGATIVE because nothing else can see a
# revert that reinstates the weaker wording alongside a still-leased delete.
hasnt "$rm_line_11a" 'when enumerated' \
   "11a …stated plainly, because the lease makes it true of the tip that was actually removed"
if [ -n "${ check_git "$RM" ls-remote --heads origin rm/merged; }" ]; then
  bad "11a the remote branch was not actually deleted — the fixture proves nothing"
else ok; fi
# With the merged branch swept, the remote is symref-and-default only — the enumeration must come
# back EMPTY. A list that resurrects the bare `origin` here is the #38 shape with nothing left to
# hide it behind, and an empty remote list is the everyday no-op /cleanup must survive.
re_enum
eq "${ cat "$RM.enum"; }" "" \
   "11a a symref-only remote enumerates to an empty list, never to the bare origin"

# A FAILED remote delete is reported loudly and gains NO record — the same asymmetry the local half
# keeps. A branch that does not exist on the remote makes the leased push fail for real (git
# rejects it as `stale info`: the lease expected a commit and the ref is absent).
#
# THE LEASED OID MUST BE A REAL COMMIT, and the all-zero OID is the trap — it is git`s own sentinel
# for "expect this ref to be ABSENT", so `--force-with-lease=<ref>:0{40}` MATCHES a missing ref and
# the delete of a nonexistent branch SUCCEEDS as a no-op. Observed while writing this case. It is
# not a hole in the workflow (`%(objectname)` on a real ref never yields it, and a null lease can
# only ever succeed where there is nothing to destroy), but a fixture built on it would assert the
# opposite of the intended behaviour. Use a commit that genuinely exists.
rm_run "rm/never-existed${TAB}${ check_git "$RM" rev-parse refs/heads/main; }"
hasnt "${ cat "$RM.deleted"; }" 'rm/never-existed' \
   "11b a remote delete that FAILED gains no record, so no proof asserts a deletion that did not happen"
has "${ cat "$RM.notes"; }" 'REFUSED origin/rm/never-existed' \
   "11b …and is reported in full instead"

# A record with NO tip cannot be leased, and the by-name fallback is exactly what #346 removes. It
# must be KEPT and reported, never deleted on the weaker evidence. This is reachable from a real
# `--format` that stopped emitting the second field — the same silent shape as a dropped filter.
rm_run "rm/no-oid"
hasnt "${ cat "$RM.deleted"; }" 'rm/no-oid' \
   "11b a record carrying no tip is never deleted — an unleasable delete is not attempted"
has "${ cat "$RM.notes"; }" 'SKIPPED origin/rm/no-oid — the enumeration carried no tip' \
   "11b …and the gap is reported rather than quietly downgraded to a by-name delete"

# The composed remote line must satisfy the claim grammar too. `contained` is not a status word,
# but this is the line where a future edit would most naturally reach for `merged`. The line is
# the one CAPTURED at 11a — re-running the sweep here (the previous shape) deleted nothing, since
# 11a already removed the branch, so an EMPTY line was what reached the lint and the case could
# never fail. The non-empty guard is what keeps this from regressing into that vacuity.
if [ -n "$rm_line_11a" ] \
   && printf '%s\n' "$rm_line_11a" | bash "$ROOT/scripts/lib/state-assert.sh" lint >/dev/null 2>&1; then ok; else
  bad "11c the remote sweep's report line violates the claim grammar (or was empty)"
fi

# --- 11e. THE LEASE: a remote that moved after the proof must REFUSE ---------------------------
# #346(a), and the whole point of the section. The old delete was `git push origin --delete "$b"`,
# which removes the ref BY NAME whatever it points at now: a push landing between this run's fetch
# and that line destroyed a tip nothing had proved contained — the one outcome /cleanup promises
# never to produce.
#
# THE FIXTURE IS THE REAL RACE, not a staged one. A SECOND clone pushes to the shared bare remote,
# so `$RM`'s remote-tracking ref — the thing the enumeration read — is genuinely stale, exactly as
# it is when a colleague pushes mid-sweep. The enumeration runs BEFORE that push, so the OID it
# carries is the tip that was proved, and the delete is attempted after.
rm_moved_fixture() {
  ( cd "$RM" || exit 1
    git checkout -q main
    git rev-parse --verify --quiet refs/heads/rm/moved >/dev/null || {
      git checkout -q -b rm/moved
      git commit -q --allow-empty -m "rm/moved work"
      git push -q -u origin rm/moved
      git checkout -q main
      git merge -q --no-ff rm/moved -m "merge rm/moved"
      git push -q origin main
    } ) || bad "11e fixture build failed"
  re_enum
  RM_MOVED_ENUM="${ grep '^rm/moved' < "$RM.enum" || true; }"
  [ -n "$RM_MOVED_ENUM" ] || bad "11e the enumeration did not surface rm/moved — the fixture proves nothing"
  # The third party. A separate clone, so nothing in $RM learns that the branch advanced.
  rm -rf "$work/remote-sweep-other"
  git clone -q "$work/remote-sweep-origin.git" "$work/remote-sweep-other" 2>/dev/null \
    || bad "11e could not clone the shared remote"
  ( cd "$work/remote-sweep-other" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    git checkout -q -B rm/moved origin/rm/moved
    git commit -q --allow-empty -m "a concurrent push"
    git push -q origin rm/moved ) || bad "11e the concurrent push failed"
  RM_MOVED_NOW="${ check_git "$RM" ls-remote --heads origin rm/moved | cut -f1; }"
  # The race must be REAL: the tip the enumeration proved and the tip the remote holds now must
  # differ, or a passing refusal below would prove nothing about leasing.
  if [ -n "$RM_MOVED_NOW" ] && [ "$RM_MOVED_NOW" != "${ printf '%s' "$RM_MOVED_ENUM" | cut -f2; }" ]; then ok; else
    bad "11e the fixture did not actually advance the remote branch — the lease assertion would be vacuous"
  fi
}
rm_moved_fixture
rm_run "$RM_MOVED_ENUM"
hasnt "${ cat "$RM.deleted"; }" 'rm/moved' \
   "11e a remote branch that moved after the proof is NOT recorded as deleted"
has "${ cat "$RM.notes"; }" 'REFUSED origin/rm/moved' \
   "11e …the refusal names the branch in full, through NOTES"
eq "${ check_git "$RM" ls-remote --heads origin rm/moved | cut -f1; }" "$RM_MOVED_NOW" \
   "11e …and the branch SURVIVES on the remote, still at the commit the concurrent push left"

# --- 11f. THE CONTROL: 11e must be able to fail, and the witness is the REAL block, MUTATED -----
# A guard is not done until it has been observed failing (base/practices/self-review.md), and the
# observation has to be of the IMPLEMENTATION going wrong rather than of the harness. So the
# witness is the shipped snippet with ONE substitution — the leased push becomes the by-name push
# it replaced, i.e. literally the pre-#346 line — run against the SAME fixture. Everything else
# (the loop, the two-field read, the no-tip guard, the accumulators) is the shipped text.
RM_NEEDLE='if git push origin --force-with-lease="refs/heads/$b:$oid" --delete "refs/heads/$b"; then'
RM_BYNAME='  if git push origin --delete "$b"; then'
RM_BROKEN="${ printf '%s\n' "$RM_SNIPPET" \
  | awk -v needle="$RM_NEEDLE" -v repl="$RM_BYNAME" 'index($0, needle) { print repl; next } { print }'; }"
# The mutation must actually have applied — a needle that silently stopped matching would leave
# this control running the CORRECT code and passing for the wrong reason, which is the same class
# of defect it exists to catch.
if [ "$RM_BROKEN" = "$RM_SNIPPET" ]; then
  bad "11f the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
rm_run "$RM_MOVED_ENUM" "$RM_BROKEN"
if [ -z "${ check_git "$RM" ls-remote --heads origin rm/moved; }" ]; then ok; else
  bad "11f the control (the pre-#346 by-name delete) did NOT destroy the moved branch — 11e proves nothing"
fi
has "${ cat "$RM.deleted"; }" 'rm/moved' \
   "11f …and reports it as a clean delete, which is the false claim the lease removes"

# --- 11d. the new blocks must also run on the interpreter an AGENT will use --------------------
# Section 8e makes this point for the state block: these fences are executed by the AGENT's shell,
# and on macOS a shell that has not picked up Homebrew's prefix is /bin/bash 3.2.57. The branch and
# marker blocks are new surface with the same exposure, and `check-workflow-shell.sh` checks
# reserved-variable assignment, not general syntax. The sentinel is what makes this able to fail at
# all — a block that does not run deletes nothing, which satisfies any survival assertion.
if [ -x /bin/bash ] && [ "${ /bin/bash -c 'printf %s "$BASH_VERSION"'; }" != "${BASH_VERSION}" ]; then
  br_fixture
  rm -rf "$BRC"
  ( cd "$BR" && env /bin/bash -c '
BASE=origin/main
TABC="$(printf "\t")"
WORKTREES=""
HAVE_GH=0
NOTES=""; DELETED_LOCAL=""
CANDIDATES="br/pr
br/ff
br/open
br/unver
br/refuse"
'"${BR_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$BR/cl\"}"'
printf "%s" "$DELETED_LOCAL" > '"$BR"'/deleted_local' ) >/dev/null 2>&1
  has "${ br_line; }" 'br/pr [#7 (merge commit SENTINELCAFE)]' \
     "11d the branch-sweep block carries its proof under /bin/bash 3.2 too"
  if [ -n "${ check_git "$BR" rev-parse --verify --quiet refs/heads/br/pr; }" ]; then
    bad "11d under /bin/bash the branch block did not run — nothing was deleted (parse or portability failure)"
  else ok; fi

  mk_run none 0   # rebuilds the marker fixture; re-run it under the old interpreter below
  rm -rf "${ST:?}"; mkdir -p "$ST"
  printf '{"branch":"gone/branch"}\n' > "$ST/implement-issue-active.json"
  ( cd "$BR" && env RUN=none NOTES="" CLEARED="" PRWANT=none /bin/bash -c '
TABC="$(printf "\t")"
pr_state() { printf "%s\n" "$PRWANT"; }
SCAN="$(bash '"$CL"' state-scan '"$ST"')"
'"${MK_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$CLEARED" > '"$ST"'.cleared' ) >/dev/null 2>&1
  eq "${ st_line; }" "Cleared state: implement-issue-active.json [branch gone]" \
     "11d …as does the marker-sweep block"
else
  check_note "11d SKIPPED the old-interpreter pass: /bin/bash is absent, or is this suite's own interpreter (${BASH_VERSION})"
fi

# ============ 12. a proved-merged branch does not leave its PR open (#346b, absorbed #348) =====
# THE BUG: `branch-verdict` proves containment from LOCAL ANCESTRY and never reads PR state, so a
# branch can be provably merged with its own PR still open — folded into another PR that merged,
# rebased onto the default branch, or pushed there directly. The delete arm then removed the
# dangling branch that would have prompted a human, and the PR stayed open forever.
#
# THIS SECTION RUNS THE REAL WORKFLOW BLOCK, extracted by its ADB-SNIPPET marker, exactly as
# sections 9-11 do. It is the SAME `branch-sweep` snippet section 9 drives, with the one variable
# that arm keys on flipped: `HAVE_GH=1`, plus a `gh` on PATH. Section 9's HAVE_GH=0 pass is
# therefore also the "no gh / unauthenticated" case this issue requires, and it already asserts the
# sweep behaves exactly as before — re-asserted explicitly at 12f below rather than left implied.
PC="$work/prclose"
PCB="$PC/bin"
mkdir -p "$PCB" "$PC/fix"
check_make_repo_pair "$PC/repo" "$work/prclose-origin.git" || bad "12 fixture init failed"
PCR="$PC/repo"
(
  cd "$PCR" || exit 1
  git checkout -q -b main
  git commit -q --allow-empty -m init
  git push -q -u origin main
) || bad "12 fixture build failed"
PC_MAIN="${ check_git "$PCR" rev-parse refs/heads/main; }"

# The `gh` the workflow will actually invoke. It answers every read the block makes and logs
# every call, so "was a close even attempted?" is answerable rather than inferred from an absence.
# Each log line is prefixed with `GH_REPO=<slug> ` when that variable reached the process, so
# "did the documented redirect reach gh?" (PR #393's P1) is answerable the same way.
#
# ROUTED BY `--state`, because the block makes two DIFFERENT `pr list` calls: the merged-PR
# evidence query (whose output feeds branch-verdict, stubbed here, so `[]` is right) and the
# open-PR query this section is about. A stub that answered both the same way would feed open-PR
# records into the verdict path and prove nothing about either.
#
# `--base` ROUTES TOO, the way gh behaves: with no `--base`, same-head PRs targeting OTHER bases
# (the `open-<head>+other` fixture) are served as well; with one, only the base's own fixture is.
# `--limit` is honored as the HARD CAP the real flag documents — rows beyond it are dropped.
check_write_stub "$PCB/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "${GH_REPO:+GH_REPO=$GH_REPO }$*" >> "$PC_LOG"
sub="$1 $2"
head=""; state=""; base=""; limit=""; prev=""
for a in "$@"; do
  case "$prev" in
    --head|-H)  head="$a" ;;
    --state|-s) state="$a" ;;
    --base|-B)  base="$a" ;;
    --limit|-L) limit="$a" ;;
  esac
  prev="$a"
done
case "$sub" in
  "pr list")
    if [ "$state" = open ]; then
      [ "${PC_LIST_RC:-0}" -eq 0 ] || exit "$PC_LIST_RC"
      f="$PC_FIX/open-$(printf '%s' "$head" | tr '/' '_')"
      { [ -f "$f" ] && cat "$f"
        [ -z "$base" ] && [ -f "$f+other" ] && cat "$f+other"
        :
      } | head -n "${limit:-30}"
      exit 0
    fi
    printf '[]\n'
    exit 0
    ;;
  "pr close")  exit "${PC_CLOSE_RC:-0}" ;;
  "pr view")
    # The post-close head read: a `post-<number>` fixture overrides; the default answer is the
    # head the open-PR fixture advertised, i.e. "nothing moved after the close".
    if [ -f "$PC_FIX/post-$3" ]; then cat "$PC_FIX/post-$3"
    else grep -h "^$3 " "$PC_FIX"/open-* 2>/dev/null | head -n1 | cut -d' ' -f2; fi
    exit 0
    ;;
  "pr reopen") exit "${PC_REOPEN_RC:-0}" ;;
esac
exit 0
GHSTUB
[ -x "$PCB/gh" ] || bad "12 the gh stub was not written executable — the real gh would be used"

# Eight branches, one per direction the issue (and the PR #393 review findings) names. Every one
# of them is a REAL ancestor of main (so `branch-verdict` is asked about a genuinely merged
# branch) except `pc/open`.
#
# BUILT ONCE, THEN RESTORED BY OID — never re-created with a fresh commit. The sweep DELETES these
# branches and this section runs it five times, so a rebuild that made a new empty commit would
# give each run a different tip while the open-PR fixtures still named the first one: every case
# would then take the head-moved arm, and 12a/12d/12f would be asserting the OPPOSITE of what they
# claim to test. Observed exactly that before the refs were pinned. `update-ref` restores the same
# commit, so every run classifies the identical tree.
pc_build() {
  ( cd "$PCR" || exit 1
    git checkout -q main
    for b in pc/match pc/moved pc/gone pc/two pc/carry pc/full pc/swap; do
      git checkout -q -b "$b"
      git commit -q --allow-empty -m "$b work"
      git checkout -q main
      git merge -q --no-ff "$b" -m "merge $b"
    done
    git checkout -q -b pc/open
    git commit -q --allow-empty -m "pc/open work"
    git checkout -q main ) || bad "12 fixture build failed"
}
pc_build
PC_REFS=""
for b in pc/match pc/moved pc/gone pc/two pc/carry pc/full pc/swap pc/open; do
  PC_REFS="${PC_REFS}${b} ${ check_git "$PCR" rev-parse "refs/heads/$b"; }
"
done
pc_fixture() {
  local n o
  while read -r n o; do
    [ -n "$n" ] || continue
    check_git "$PCR" update-ref "refs/heads/$n" "$o" || bad "12 fixture restore failed for $n"
  done <<PCREFS
$PC_REFS
PCREFS
}

# The verdict wrapper. `pc/carry` is the carry probe and works exactly as section 9's does: while
# the ref exists the evidence is the SENTINEL; once the sweep has deleted it any later read is a
# different moment and gets the POISON. The close happens AFTER the delete, so an implementation
# that re-queried its proof for the PR comment would write POISON — which is the whole question
# "is the durable record on the PR the evidence that authorised the delete?"
cat > "$PC/cl" <<PCWRAP
#!/usr/bin/env bash
if [ "\$1" = branch-verdict ]; then
  b="\$2"
  tip="\$(git rev-parse --verify --quiet "refs/heads/\$b")"
  case "\$b" in
    pc/open) printf 'unmerged\n%s\n' "\$tip" ;;
    pc/carry)
      if [ -n "\$tip" ]; then printf 'merged-pr\n%s\n#7 (merge commit SENTINELCAFE)\n' "\$tip"
      else                    printf 'merged-pr\n%s\n#999 (merge commit POISONBEEF01)\n' "$PC_MAIN"; fi ;;
    *) [ -n "\$tip" ] || { printf 'stub: %s read after deletion\n' "\$b" >&2; exit 3; }
       printf 'merged-ff\n%s\n' "\$tip" ;;
  esac
  exit 0
fi
exec bash "$CL" "\$@"
PCWRAP

# pc_openprs <branch> <lines…> — write the open-PR fixture the stub serves for that head, in the
# `<number> <headRefOid>` shape the block's own --jq produces. Absent file = an empty list, which
# is the "the PR merged between the verdict and the close" case.
pc_openprs() {
  local b="$1"; shift
  printf '%s\n' "$@" > "$PC/fix/open-$(printf '%s' "$b" | tr '/' '_')"
}

# pc_run [snippet-body] — execute the extracted block with gh AVAILABLE. Files, not captured
# strings, for the reason br_run states: these accumulators are TAB-separated by design.
#
# GH_REPO IS FOISTED ON EVERY RUN, deliberately. The P1 in the PR #393 review is that a live
# GH_REPO redirects every gh call to a repository the $TIP proof knows nothing about; exporting a
# foreign slug here makes each standard run double as that hostile environment, and 12k asserts
# no gh call ever saw it.
pc_run() {
  local body="${1:-$BR_SNIPPET}"
  rm -f "$PC/gh.log"
  pc_fixture
  ( cd "$PCR" && env PATH="$PCB:$PATH" PC_LOG="$PC/gh.log" PC_FIX="$PC/fix" \
        PC_LIST_RC="${PC_LIST_RC:-0}" PC_CLOSE_RC="${PC_CLOSE_RC:-0}" \
        PC_REOPEN_RC="${PC_REOPEN_RC:-0}" GH_REPO=evil/elsewhere "$BASH" -c '
BASE=origin/main
DEFAULT=main
TABC="$(printf "\t")"
WORKTREES=""
HAVE_GH=1
NOTES=""; DELETED_LOCAL=""; PR_CLOSED=""
CANDIDATES="pc/match
pc/moved
pc/gone
pc/two
pc/carry
pc/full
pc/swap
pc/open"
'"${body//\{\{CLEANUP_LIB\}\}/bash \"$PC/cl\"}"'
printf "%s" "$DELETED_LOCAL" > '"$PC"'/deleted_local
printf "%s" "$PR_CLOSED"     > '"$PC"'/pr_closed
printf "%s" "$NOTES"         > '"$PC"'/notes' ) >/dev/null 2>&1
}
# The category line the operator actually sees, rendered through the real report path. RENDERED and
# not substring-matched on the accumulator, for the reason 10d states: a SPACE where the tab belongs
# satisfies any `has` on the raw string while rendering the proof as part of the item's name.
pc_line() {
  printf '%s\n' "$(cat "$PC/pr_closed")" \
    | while IFS= read -r x; do [ -n "$x" ] && printf 'PR closed\t%s\n' "$x"; done \
    | bash "$CL" report
}

# The tips are read AFTER the fixture exists, because the fixture files must name the commit the
# verdict will be computed from. A hardcoded OID here would make every match case vacuous. These
# are the same values `pc_fixture` restores, so they stay true across every run in this section.
PC_TIP_MATCH="${ check_git "$PCR" rev-parse refs/heads/pc/match; }"
PC_TIP_TWO="${   check_git "$PCR" rev-parse refs/heads/pc/two; }"
PC_TIP_CARRY="${ check_git "$PCR" rev-parse refs/heads/pc/carry; }"
PC_TIP_FULL="${  check_git "$PCR" rev-parse refs/heads/pc/full; }"
PC_TIP_SWAP="${  check_git "$PCR" rev-parse refs/heads/pc/swap; }"
pc_openprs pc/match "101 $PC_TIP_MATCH"
pc_openprs pc/moved "102 $PC_MAIN"
pc_openprs pc/gone  ""
pc_openprs pc/two   "103 $PC_TIP_TWO" "104 $PC_MAIN"
pc_openprs pc/carry "105 $PC_TIP_CARRY"
pc_openprs pc/open  "106 $PC_MAIN"
# A same-head PR targeting ANOTHER base, at the proved tip — the one PR #393's base-filter
# finding is about. The stub serves it only to an UNFILTERED query, the way gh would.
printf '107 %s\n' "$PC_TIP_MATCH" > "$PC/fix/open-pc_match+other"
# A SATURATED head: exactly the shipped cap's worth of open PRs, every one at the proved tip, so
# an implementation that trusts the truncated list would close all of them. The cap is extracted
# from the shipped block, so the fixture tracks it instead of silently falling below it.
pc_limit="${ printf '%s\n' "$BR_SNIPPET" | sed -n 's/^ *OPENPR_LIMIT=\([0-9][0-9]*\)$/\1/p' | head -n1; }"
if [ -n "$pc_limit" ]; then ok; else
  bad "12 could not extract OPENPR_LIMIT from the shipped block — the saturation fixture cannot track the cap"
  pc_limit=100
fi
: > "$PC/fix/open-pc_full"
pc_i=0
while [ "$pc_i" -lt "$pc_limit" ]; do
  printf '%s %s\n' "$((200 + pc_i))" "$PC_TIP_FULL" >> "$PC/fix/open-pc_full"
  pc_i=$((pc_i + 1))
done
# A head whose PR moves BETWEEN the close and the post-close read: the open fixture advertises
# the proved tip (so the close is attempted), and the `post-` fixture answers the re-read with a
# different head — the race `gh pr close` cannot lease against.
pc_openprs pc/swap "110 $PC_TIP_SWAP"
printf '%s\n' "$PC_MAIN" > "$PC/fix/post-110"

pc_run
pc_notes="${ cat "$PC/notes"; }"
pc_log="${ cat "$PC/gh.log"; }"
pc_report="${ pc_line; }"

# --- 12a. the match: branch deleted AND its PR closed, with the proof on both -------------------
if [ -z "${ check_git "$PCR" rev-parse --verify --quiet refs/heads/pc/match; }" ]; then ok; else
  bad "12a the sweep did not delete pc/match — the fixture proves nothing about what follows a delete"
fi
has "$pc_report" "101 [head matched the proved tip $PC_TIP_MATCH]" \
   "12a a PR at the proved tip is closed, and the report names the OID gate that authorised it"
has "$pc_log" 'pr close 101' "12a …by an actual close call"
has "$pc_log" 'was deleted after its content was proved contained in origin/main' \
   "12a …carrying the proof as a durable comment on the PR itself"
# THE ENTITY REFERENCE IS BARE. `state-assert.sh lint` rejects a status word sharing a sentence with
# a `#N`, and `PR closed:` is a status word. Pinned on the rendered line, which is the thing the
# operator sees and the thing the linter would read.
hasnt "$pc_report" '#101' "12a …and the rendered line names the PR without a # (claim grammar)"
if printf '%s\n' "$pc_report" | bash "$ROOT/scripts/lib/state-assert.sh" lint >/dev/null 2>&1; then ok; else
  bad "12a the PR-closed line violates the claim grammar"
fi

# --- 12b. the OID GATE: a PR whose head moved is refused, loudly, and never closed --------------
# The safety property of the whole arm. Without it this closes a PR describing content the sweep
# never proved, which is a wrong outward mutation on somebody else's work.
# ANCHORED TO THE RECORD'S ID FIELD, not a substring of the whole file. `pr_closed` holds
# `<id>TAB<reason>` records whose reasons carry commit SHAs, and a bare `102` matches inside one:
# observed red on a correct tree when PR 105's fixture head hashed to
# …d075**102**1ebfdbf. The later cases in this section (12l/12m/12n) already
# anchor this way; these three did not.
hasnt "${ cat "$PC/pr_closed"; }" "102$TAB" "12b a PR whose head is not the proved tip is NOT closed"
hasnt "$pc_log" 'pr close 102'          "12b …and no close is even attempted"
has "$pc_notes" 'REFUSED closing PR 102 for pc/moved' \
   "12b …the refusal names the PR and the branch, in full, through NOTES"

# --- 12c. the PR merged (or closed) between the verdict and the close ---------------------------
# The `--state open` query simply returns nothing. Nothing to do is not an error, and reporting one
# would make the common post-merge sweep noisy about work that resolved itself correctly.
if [ -z "${ check_git "$PCR" rev-parse --verify --quiet refs/heads/pc/gone; }" ]; then ok; else
  bad "12c pc/gone was not deleted — the fixture proves nothing"
fi
# SCOPED BY ENUMERATING THE CLOSES, not by `hasnt … 'pr close'`: this one run legitimately closes
# four other PRs, so a bare absence test could only ever pass by accident of ordering. The set is
# the assertion — 101 (pc/match), 103 (pc/two), 105 (pc/carry) and 110 (pc/swap, reopened later by
# 12n's compensation), and nothing for pc/gone, nothing from pc/full's saturated list, and never
# the other-base 107.
eq "${ printf '%s\n' "$pc_log" | awk '$1 == "pr" && $2 == "close" { print $3 }' | sort | tr '\n' ' '; }" \
   "101 103 105 110 " \
   "12c the closes attempted are exactly the PRs at a proved tip — none for a head with no open PR"
hasnt "$pc_notes" 'pc/gone'  "12c …and nothing is reported about it"

# --- 12d. two open PRs on one head: each judged independently -----------------------------------
has  "$pc_log" 'pr close 103' "12d the PR at the proved tip is closed"
hasnt "$pc_log" 'pr close 104' "12d …and the one whose head moved is not"
has "$pc_notes" 'REFUSED closing PR 104 for pc/two' "12d …which is reported rather than skipped silently"

# --- 12e. the unmerged branch is untouched, and its PR is never even looked at ------------------
# `cleanup.md`'s guardrail has no PR-shaped exception: an unmerged branch's PR is live work.
if [ -n "${ check_git "$PCR" rev-parse --verify --quiet refs/heads/pc/open; }" ]; then ok; else
  bad "12e the sweep deleted an unmerged branch"
fi
hasnt "$pc_log" '--head pc/open --state open' "12e an unmerged branch's open PRs are never queried"
hasnt "$pc_log" 'pr close 106'                "12e …and its PR is never closed"
hasnt "${ cat "$PC/pr_closed"; }" "106$TAB"   "12e …nor reported as closed"

# --- 12f. THE CARRY PROPERTY: the comment holds the evidence THIS verdict returned --------------
# #332's discipline applied to an outward mutation. Re-deriving the proof when the comment is
# composed reads a different moment — and for a deleted branch it is not even answerable, which is
# why the wrapper answers POISON once the ref is gone.
has   "$pc_log" 'SENTINELCAFE' "12f the PR comment carries the evidence the authorising call returned"
hasnt "$pc_log" 'POISONBEEF01' "12f …and never a value from a re-query after the delete"

# --- 12g. gh pr close FAILS: reported in full, and the sweep still succeeds ---------------------
# A failed outward mutation must never take the sweep down with it — the branch is already gone and
# the report has to be printed.
PC_CLOSE_RC=1 pc_run
has "${ cat "$PC/notes"; }" 'REFUSED closing PR 101 for pc/match — gh pr close failed' \
   "12g a failed close is reported in full through NOTES"
hasnt "${ cat "$PC/pr_closed"; }" "101$TAB" \
   "12g …and gains no record, so nothing claims a close that did not happen"
has "${ cat "$PC/deleted_local"; }" 'pc/match' \
   "12g …while the delete it followed still stands and is still reported"
PC_CLOSE_RC=0

# --- 12h. the open-PR QUERY fails: never silently downgraded to 'no PR' -------------------------
# The #106 lesson, in miniature: a query that FAILED must not read as "there is nothing there".
PC_LIST_RC=1 pc_run
has "${ cat "$PC/notes"; }" 'UNVERIFIED pc/match — the open-PR query failed' \
   "12h a failed open-PR query is reported, never read as 'no PR to close'"
hasnt "${ cat "$PC/gh.log"; }" 'pr close' "12h …and no close is attempted on an unread list"
PC_LIST_RC=0

# --- 12i. no gh: the branch sweep behaves EXACTLY as it did before this arm existed -------------
# Section 9 is that run in full (HAVE_GH=0, every proof and note asserted). This pins the one thing
# section 9 cannot: that with gh absent the new arm makes no call at all.
rm -f "$PC/gh.log"
pc_fixture
( cd "$PCR" && env PATH="$PCB:$PATH" PC_LOG="$PC/gh.log" PC_FIX="$PC/fix" "$BASH" -c '
BASE=origin/main
TABC="$(printf "\t")"
WORKTREES=""
HAVE_GH=0
NOTES=""; DELETED_LOCAL=""; PR_CLOSED=""
CANDIDATES="pc/match"
'"${BR_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$PC/cl\"}"'
printf "%s" "$DELETED_LOCAL" > '"$PC"'/deleted_local
printf "%s" "$PR_CLOSED"     > '"$PC"'/pr_closed' ) >/dev/null 2>&1
eq "${ cat "$PC/gh.log" 2>/dev/null; }" "" "12i with HAVE_GH=0 the arm makes no gh call whatsoever"
eq "${ cat "$PC/pr_closed"; }" ""        "12i …and closes nothing"
has "${ cat "$PC/deleted_local"; }" 'pc/match' "12i …while the delete itself is unchanged"

# --- 12j. THE CONTROL: 12b must be able to fail, and the witness is the REAL block, MUTATED -----
# A guard is not done until it has been observed failing (base/practices/self-review.md). The
# witness is the shipped snippet with ONE substitution — the OID gate inverted to the ungated close
# any first draft would write — run against the SAME fixture. Everything else is the shipped text.
PC_NEEDLE='if [ "$PRHEAD" != "$TIP" ]; then'
PC_UNGATED='              if false; then'
PC_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | awk -v needle="$PC_NEEDLE" -v repl="$PC_UNGATED" 'index($0, needle) { print repl; next } { print }'; }"
if [ "$PC_BROKEN" = "$BR_SNIPPET" ]; then
  bad "12j the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
pc_run "$PC_BROKEN"
has "${ cat "$PC/gh.log"; }" 'pr close 102' \
   "12j the control (the same block with the OID gate removed) closes the PR whose head had moved"
has "${ cat "$PC/gh.log"; }" 'pr close 104' \
   "12j …and the second PR on the two-PR head as well, which is the defect 12b and 12d pin"

# --- 12k. GH_REPO cannot redirect the arm: the proof's repository is the gh calls' repository ---
# The P1 in the PR #393 review. $TIP containment was proved against THIS checkout's origin, and a
# live GH_REPO redirects every gh call to whatever repository it names (`gh help environment`) —
# a fork sharing the commit and branch name would have ITS PR closed on this checkout's proof.
# The hazard record lives on `adb_git_repo_slugs` in common.sh. Every pc_run exports
# GH_REPO=evil/elsewhere, and the stub prefixes any call that saw it, so the log answers directly.
pc_run
has   "${ cat "$PC/gh.log"; }" 'pr close 101' \
   "12k the run made real gh calls, so the absence asserted next cannot pass vacuously"
hasnt "${ cat "$PC/gh.log"; }" 'GH_REPO=' \
   "12k no gh call in the sweep ever saw the foisted GH_REPO — the redirect dies before the first read"
# THE CONTROL: the shipped block with the one `unset GH_REPO` line removed, in the same hostile
# environment. Every call then reaches gh with the foreign slug in force — the pre-fix defect.
PCK_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | N='unset GH_REPO' awk 'index($0, ENVIRON["N"]) == 1 { print ":"; next } { print }'; }"
if [ "$PCK_BROKEN" = "$BR_SNIPPET" ]; then
  bad "12k the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
pc_run "$PCK_BROKEN"
has "${ cat "$PC/gh.log"; }" 'GH_REPO=evil/elsewhere pr list' \
   "12k the control (the unset removed) hands every gh call to the foreign repository — the P1 defect"

# --- 12l. the base filter: containment in origin/main says NOTHING about another base -----------
# A same-head PR targeting a release or maintenance branch is live backport work: $TIP's proof
# speaks only for origin/$DEFAULT. The stub serves the other-base PR (107, head AT the proved
# tip) only to an unfiltered query, the way gh would, so the shipped `--base` keeps it out of
# reach entirely. The other direction rides 12a: 101 — same head, base main — IS still closed.
pc_run
has   "${ cat "$PC/gh.log"; }" 'pr list --head pc/match --base main --state open' \
   "12l the open-PR query is scoped to the base the proof speaks for"
hasnt "${ cat "$PC/gh.log"; }" 'pr close 107' \
   "12l a same-head PR targeting another base is never closed, even at the proved tip"
hasnt "${ cat "$PC/pr_closed"; }" "107$TAB" "12l …and never reported as closed"
# THE CONTROL: the shipped query with only `--base "$DEFAULT"` dropped. The stub then serves the
# other-base PR, its head matches the proved tip, and the OID gate happily closes it.
PCL_NEEDLE='gh pr list --head "$b" --base "$DEFAULT" --state open'
PCL_UNFILTERED='          if OPENPRS="$(gh pr list --head "$b" --state open \'
PCL_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | N="$PCL_NEEDLE" R="$PCL_UNFILTERED" awk 'index($0, ENVIRON["N"]) { print ENVIRON["R"]; next } { print }'; }"
if [ "$PCL_BROKEN" = "$BR_SNIPPET" ]; then
  bad "12l the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
pc_run "$PCL_BROKEN"
has "${ cat "$PC/gh.log"; }" 'pr close 107' \
   "12l the control (the filter dropped) closes the other-base PR on a proof about origin/main — the defect"

# --- 12m. the hard cap: a list AT the cap is a possible subset, and a subset is never closed ----
# `gh pr list --limit` is a hard truncation, not a page size. When the stub returns exactly the
# cap's worth of rows the shipped block refuses the whole head — naming the count and the cap —
# and closes NOTHING: closing the visible subset would leave every invisible PR dangling in
# silence, which is the #106 failure class on PRs.
pc_run
has "${ cat "$PC/notes"; }" \
   "REFUSED closing any PR for pc/full — the open-PR list returned $pc_limit results at its cap of $pc_limit" \
   "12m a saturated open-PR list is refused loudly, naming the head, the count and the cap"
hasnt "${ cat "$PC/gh.log"; }" 'pr close 200' \
   "12m …and no PR from the saturated list is closed (12c's exact close set is the full assertion)"
# THE CONTROL: the saturation check blinded — the pre-fix shape, which trusted the cap as the
# whole answer and closed the subset it could see, with no refusal anywhere.
PCM_NEEDLE='if [ "$OPENPR_N" -ge "$OPENPR_LIMIT" ]; then'
PCM_BLIND='            if false; then'
PCM_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | N="$PCM_NEEDLE" R="$PCM_BLIND" awk 'index($0, ENVIRON["N"]) { print ENVIRON["R"]; next } { print }'; }"
if [ "$PCM_BROKEN" = "$BR_SNIPPET" ]; then
  bad "12m the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
pc_run "$PCM_BROKEN"
has "${ cat "$PC/gh.log"; }" 'pr close 200' \
   "12m the control (the saturation check blinded) closes the visible subset — the silent-truncation defect"
hasnt "${ cat "$PC/notes"; }" 'REFUSED closing any PR for pc/full' \
   "12m …with no refusal anywhere, which is what made it silent"

# --- 12n. the compensated close: the post-close head is re-read, and a mismatch is undone -------
# `gh pr close` takes no expected-head option, so unlike the delete it cannot be leased on $TIP.
# The compensation is the guarantee instead: re-read the head AFTER the close; a head that is no
# longer the proved tip means the close judged content the sweep never proved, so it is REOPENED
# and reported with both OIDs. A verified close is reported under PR closed; a reopened one never.
pc_run
has "${ cat "$PC/gh.log"; }" 'pr view 110' "12n the post-close head is re-read after the close"
has "${ cat "$PC/gh.log"; }" 'pr reopen 110' \
   "12n a post-close head that moved is compensated by an actual reopen call"
has "${ cat "$PC/notes"; }" \
   "REOPENED PR 110 for pc/swap — after the close its head read back as $PC_MAIN, not the proved tip $PC_TIP_SWAP" \
   "12n …reported loudly, naming the PR and BOTH OIDs"
hasnt "${ cat "$PC/pr_closed"; }" "110$TAB" \
   "12n …and a reopened close is never reported under PR closed"
has   "${ cat "$PC/gh.log"; }" 'pr view 101' "12n a clean close is verified the same way"
hasnt "${ cat "$PC/gh.log"; }" 'pr reopen 101' "12n …and never reopened"
has "${ cat "$PC/pr_closed"; }" "101$TAB" "12n …and is the one that IS reported closed"
# The reopen itself failing must escalate, never pass silently: the PR is closed on unproved
# content and nothing compensated it.
PC_REOPEN_RC=1 pc_run
has "${ cat "$PC/notes"; }" 'ATTENTION PR 110 for pc/swap' \
   "12n a failed reopen escalates to the operator by name — a mismatched close never stands silently"
PC_REOPEN_RC=0
# THE CONTROL: the post-close verification blinded — the pre-fix shape, where no read followed the
# close, so a mismatched close stood, silently, reported as a clean close.
PCN_NEEDLE='if [ "$POSTHEAD" = "$TIP" ]; then'
PCN_BLIND='                if true; then'
PCN_BROKEN="${ printf '%s\n' "$BR_SNIPPET" \
  | N="$PCN_NEEDLE" R="$PCN_BLIND" awk 'index($0, ENVIRON["N"]) { print ENVIRON["R"]; next } { print }'; }"
if [ "$PCN_BROKEN" = "$BR_SNIPPET" ]; then
  bad "12n the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
pc_run "$PCN_BROKEN"
hasnt "${ cat "$PC/gh.log"; }" 'pr reopen 110' \
   "12n the control (the verification blinded) leaves the mismatched close standing"
has "${ cat "$PC/pr_closed"; }" "110$TAB" \
   "12n …and reports it as a clean close — the silent wrong mutation the compensation exists to prevent"

# ============ 13. the run marker is never silently invisible (#350) ============================
# THE BUG: three distinct states of one record rendered byte-identically as SILENCE — the gate
# cleared the marker at end of run (normal); no run ever existed here; or a marker is sitting in
# the state directory under a filename the classifier no longer matches. The third is classified
# `other`, correctly never swept, and never reported — and `RUN_NOW` then reads `none`, which is
# precisely the verdict that lets a LIVE run's gap and review artifacts be swept out from under it.
# `base/practices/self-review.md`: a guard must say what it CHECKED, not only whether it passed.
MR_SNIPPET="${ check_wf_snippet "$WF" marker-report; }"
[ -n "$MR_SNIPPET" ] || bad "13 snippet 'marker-report' not found in base/workflows/cleanup.md"
MR="$work/marker350"

# --- 13pre. the library predicate, on its own -------------------------------------------------
# `marker-shape` answers the REPORTING question the delete allowlist deliberately cannot. It must
# be WIDER than that allowlist and must never restate it: a second copy of the exact names would
# have drifted along with the arm that stopped matching, which is the very case this exists for.
eq "${ bash "$CL" marker-shape implement-issue-active.json; }"  "marker-shaped" "13pre the canonical marker name is in the family"
eq "${ bash "$CL" marker-shape implement-issue-blocked.json; }" "marker-shaped" "13pre …as is the blocked marker"
eq "${ bash "$CL" marker-shape implement-issue-paused.json; }"  "marker-shaped" "13pre …and a marker name the allowlist does NOT know, which is the whole point"
eq "${ bash "$CL" marker-shape /a/b/implement-issue-active.json; }" "marker-shaped" "13pre a full path is judged by its basename"
eq "${ bash "$CL" marker-shape .marker.tmp; }" "marker-shaped" "13pre a staged marker whose rename never happened is in the family too"
eq "${ bash "$CL" marker-shape threads-41.json; }" "-" "13pre a thread cache is not a marker"
eq "${ bash "$CL" marker-shape gaps.md; }"        "-" "13pre nor a gap artifact"
eq "${ bash "$CL" marker-shape review.md; }"      "-" "13pre nor a review artifact"
bash "$CL" marker-shape >/dev/null 2>&1; eq "$?" "2" "13pre a missing argument is a hard error, never a quiet '-'"

# mr_run <state-dir> [lib] [snippet-body] — execute the DOCUMENTED marker-report block against a
# real state dir. `--with-identity`, because that is the scan the workflow reads it from: the
# pre-delete re-scan, the one pass that binds a file's classification and its identity to a single
# observation. A three-variable read here would fold the identity into `$key` (see the workflow).
mr_run() {
  local dir="$1" lib="${2:-$CL}" body="${3:-$MR_SNIPPET}"
  rm -f "$dir.runmark"
  ( cd "$BR" && env "$BASH" -c '
TABC="$(printf "\t")"
RUNMARK=""
SCAN="$(bash '"$lib"' state-scan --with-identity '"$dir"')"
'"${body//\{\{CLEANUP_LIB\}\}/bash \"$lib\"}"'
printf "%s" "$RUNMARK" > '"$dir"'.runmark' ) >/dev/null 2>&1
}
# RENDERED through the real report path, never substring-matched on the accumulator — 10d's lesson:
# a SPACE where the tab belongs satisfies any `has` on the raw string while rendering the proof as
# part of the filename, with no bracket anywhere, and only the report can see that.
mr_line() {   # <state-dir> — render THAT dir's accumulator, never a fixed one
  printf '%s\n' "$(cat "${1:-$MR}.runmark")" \
    | while IFS= read -r x; do [ -n "$x" ] && printf 'Run marker\t%s\n' "$x"; done \
    | bash "$CL" report
}

# --- 13a. ABSENT: the common path stays silent -------------------------------------------------
# The terse contract (#84) forbids a `Run marker: none` on every sweep, and in the documented
# `merge → /cleanup → /clear` loop the marker is ALWAYS already gone by sweep time — so this is the
# state that must not grow a line. It is also the state a careless fix breaks first.
rm -rf "${MR:?}"; mkdir -p "$MR"
printf '{"n":1}\n' > "$MR/threads-41.json"
printf 'findings\n' > "$MR/gaps.md"
mr_run "$MR"
eq "${ cat "$MR.runmark"; }" "" "13a a state dir with no marker produces no record"
eq "${ mr_line; }" ""           "13a …so the category does not appear at all — absence is silent"

# --- 13b. KEPT-LIVE: a marker in the delete scan is reported ------------------------------------
# This is the record that set `RUN_NOW=keep` and preserved every gap, issue and review artifact.
# It used to be invisible: the sweep knew a run was in flight and said nothing.
rm -rf "${MR:?}"; mkdir -p "$MR"
printf '{"branch":"live/branch"}\n' > "$MR/implement-issue-active.json"
mr_run "$MR"
eq "${ mr_line; }" \
   "Run marker: implement-issue-active.json [present at the delete scan — artifacts kept for a run in flight]" \
   "13b a marker present at the delete scan is reported, through the real report path"

# --- 13c. KEPT-OTHER: the defect — a marker nothing recognised ----------------------------------
# A filename the classifier's arm does not match. `state-scan` calls it `other`, the sweep never
# touches it (correct, and unchanged by this issue), and before #350 nothing said so.
rm -rf "${MR:?}"; mkdir -p "$MR"
printf '{"branch":"live/branch"}\n' > "$MR/implement-issue-paused.json"
eq "${ bash "$CL" state-scan "$MR" | cut -f1; }" "other" \
   "13c the fixture really is classified 'other' — otherwise this case tests nothing"
mr_run "$MR"
eq "${ mr_line; }" \
   "Run marker: implement-issue-paused.json [UNRECOGNISED — scanned as 'other', so this sweep detected no run in flight]" \
   "13c a marker-shaped file nothing recognised is surfaced, and named"
if [ -e "$MR/implement-issue-paused.json" ]; then ok; else
  bad "13c the file was DELETED — 'other' is never touched, and reporting must not have changed that"
fi

# --- 13d. the same defect arrived at the OTHER way: the classifier's arm drifted ----------------
# 13c is producer drift (/implement-issue writes a name the arm never learned). This is consumer
# drift — the arm itself stops matching the canonical name — and it is the shape #350 describes.
# Reproduced against a COPY of the library in a temp dir (base/practices/self-review.md: never
# mutate the live tree to watch a check fire), with ONLY `state-scan`'s allowlist edited. A second
# copy of that allowlist inside `marker-shape` would have been edited by the same sed and detected
# nothing, which is exactly why the predicate is a family instead.
# The copy needs its NEIGHBOUR: cleanup-lib.sh sources common.sh from its own directory and dies
# without it, so a lone copy in $work would produce no output at all and 13d would "pass" by
# emptiness on the wrong side. Copy both into one throwaway dir.
MRLIBD="$work/drifted-lib"; mkdir -p "$MRLIBD"
cp "$ROOT/scripts/lib/common.sh" "$MRLIBD/common.sh" || bad "13d could not stage common.sh"
MRLIB="$MRLIBD/cleanup-lib.sh"
sed 's/implement-issue-active\.json|implement-issue-blocked\.json)/implement-issue-run.json)/' "$CL" > "$MRLIB"
if cmp -s "$MRLIB" "$CL"; then
  bad "13d the library mutation did not apply — the marker allowlist no longer matches the needle"
else ok; fi
rm -rf "${MR:?}"; mkdir -p "$MR"
printf '{"branch":"live/branch"}\n' > "$MR/implement-issue-active.json"
eq "${ bash "$MRLIB" state-scan "$MR" | cut -f1; }" "other" \
   "13d with the arm drifted, the CANONICAL marker name falls to 'other' — the regression, reproduced"
mr_run "$MR" "$MRLIB"
has "${ mr_line "$MR"; }" "implement-issue-active.json [UNRECOGNISED" \
   "13d …and the report says so, which is the whole of this issue"

# --- 13e. THE CONTROL: 13c/13d must be able to fail, and the witness is the REAL block, MUTATED --
# A guard is not done until it has been observed failing. The witness is the shipped snippet with
# its `other` arm's predicate inverted — i.e. the pre-#350 behaviour, where a marker-shaped `other`
# record produced nothing at all. Everything else (the loop, the marker arm, the accumulator) is
# the shipped text.
MR_NEEDLE='[ "$({{CLEANUP_LIB}} marker-shape "$sfile")" = marker-shaped ] || continue'
MR_BLIND='      continue'
MR_BROKEN="${ printf '%s\n' "$MR_SNIPPET" \
  | awk -v needle="$MR_NEEDLE" -v repl="$MR_BLIND" 'index($0, needle) { print repl; next } { print }'; }"
if [ "$MR_BROKEN" = "$MR_SNIPPET" ]; then
  bad "13e the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
mr_run "$MR" "$MRLIB" "$MR_BROKEN"
eq "${ cat "$MR.runmark"; }" "" \
   "13e the control (the block blind to a marker-shaped 'other') reports NOTHING — the silence #350 removes"
# …and the marker arm must still work in the control, or 13e would be passing because the whole
# block stopped running rather than because the one arm was removed.
rm -rf "${MR:?}"; mkdir -p "$MR"
printf '{"branch":"live/branch"}\n' > "$MR/implement-issue-active.json"
mr_run "$MR" "$CL" "$MR_BROKEN"
has "${ cat "$MR.runmark"; }" 'implement-issue-active.json' \
   "13e …while its marker arm still fires, so 13e failed for the reason it claims"

# --- 13f. CLEARED: swept by the marker pass, so it is reported by THAT category and not this one -
# The third state, end to end. `Cleared state` already carries it (#332); the point here is that
# the new category does not DOUBLE-report a record the sweep removed — the delete scan no longer
# holds it. Every observed marker therefore produces exactly one line-item, in exactly one category.
mk_run none 0
eq "${ st_line; }" "Cleared state: implement-issue-active.json [branch gone]" \
   "13f a swept marker is reported by the category that swept it"
mr_run "$ST"
eq "${ cat "$ST.runmark"; }" "" \
   "13f …and NOT a second time under Run marker — the delete scan no longer holds the record"

# --- 13g. an unreadable state dir is never conflated with 'no marker' ---------------------------
# `state-scan` exits 2 with NO stdout when the state directory's own path cannot be serialized, and
# the workflow turns that into a REFUSED note. The marker report must produce nothing there rather
# than a reassuring silence that reads like case (a).
MRBAD="$work/marker350-$(printf 'bad\tdir')"
mkdir -p "$MRBAD" 2>/dev/null || true
if [ -d "$MRBAD" ]; then
  bash "$CL" state-scan "$MRBAD" >/dev/null 2>&1; eq "$?" "2" \
     "13g a state dir whose own path cannot be serialized is REFUSED by the scan, not enumerated"
  mr_run "$MRBAD"
  eq "${ cat "$MRBAD.runmark" 2>/dev/null; }" "" \
     "13g …and the marker report adds nothing to it, so the REFUSED note stands alone"
else
  check_note "13g SKIPPED: this filesystem would not create a directory with a tab in its name"
fi

# --- 13h. REPORTING ONLY: what the sweep DOES is unchanged, including the dangerous part --------
# #350's "Out" scope is explicit — `other` is still never swept, and the `RUN_NOW=none` a
# misclassified marker produces is still what it was. That is exactly why the report matters, so
# pin it rather than leaving a reader to assume the fix also repaired the liveness signal. It did
# not, and claiming otherwise would be worse than the silence.
rm -rf "${ST:?}"; mkdir -p "$ST"
printf '{"branch":"live/branch"}\n' > "$ST/implement-issue-paused.json"
printf 'findings\n' > "$ST/gaps.md"
( cd "$BR" && env STATE="$ST" RUN=none NOTES="" CLEARED="" PRWANT=merged PRLOG="$ST.prcalls" "$BASH" -c '
TABC="$(printf "\t")"
pr_state() { printf "%s\n" "$PRWANT"; }
'"${SW_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$RUN_NOW" > '"$ST"'.runnow' ) >/dev/null 2>&1
eq "${ cat "$ST.runnow"; }" "none" \
   "13h a misclassified marker still yields RUN_NOW=none — the danger this issue reports, not repairs"
if [ -e "$ST/gaps.md" ]; then
  bad "13h …and the fixture must show why that matters: the gap artifact was NOT swept"
else ok; fi
if [ -e "$ST/implement-issue-paused.json" ]; then ok; else
  bad "13h the 'other' record was deleted — the never-touch rule must be unchanged"
fi
mr_run "$ST"
has "${ mr_line "$ST"; }" 'UNRECOGNISED' \
   "13h …so the ONE thing that changed is that the operator is now told"

# --- 13i. the new blocks must run on the interpreter an AGENT will use too ---------------------
# 11d makes this point for the branch and marker sweeps: these fences are executed by the AGENT's
# shell, and on macOS a shell that has not picked up Homebrew's prefix is /bin/bash 3.2.57.
# `marker-report` (#350) and `remote-enum` (#346) are new surface with the same exposure, and
# `check-workflow-shell.sh` checks reserved-variable assignment, not general syntax. The sentinel
# in each case is what makes this able to fail at all — a block that does not run produces an empty
# accumulator, which satisfies any absence assertion.
if [ -x /bin/bash ] && [ "${ /bin/bash -c 'printf %s "$BASH_VERSION"'; }" != "${BASH_VERSION}" ]; then
  rm -rf "${MR:?}"; mkdir -p "$MR"
  printf '{"branch":"live/branch"}\n' > "$MR/implement-issue-paused.json"
  rm -f "$MR.runmark"
  ( cd "$BR" && env /bin/bash -c '
TABC="$(printf "\t")"
RUNMARK=""
SCAN="$(bash '"$CL"' state-scan --with-identity '"$MR"')"
'"${MR_SNIPPET//\{\{CLEANUP_LIB\}\}/bash \"$CL\"}"'
printf "%s" "$RUNMARK" > '"$MR"'.runmark' ) >/dev/null 2>&1
  has "${ mr_line "$MR"; }" 'implement-issue-paused.json [UNRECOGNISED' \
     "13i the marker-report block reports a misclassified marker under /bin/bash 3.2 too"
  # The ENUMERATION, whose awk is the piece most likely to differ across shells and awks. Run in
  # the section-11 fixture, whose remote still holds only main after 11a swept rm/merged — so a
  # branch is staged for it here rather than relying on one an earlier case left behind.
  ( cd "$RM" || exit 1
    git rev-parse --verify --quiet refs/heads/rm/oldsh >/dev/null || {
      git checkout -q -b rm/oldsh
      git commit -q --allow-empty -m "rm/oldsh work"
      git checkout -q main
      git merge -q --no-ff rm/oldsh -m "merge rm/oldsh"
      git push -q origin main
      git push -q -u origin rm/oldsh
    } ) >/dev/null 2>&1
  ( cd "$RM" && env /bin/bash -c '
BASE=origin/main
CURRENT=main
TABC="$(printf "\t")"
PROTECTED="^(HEAD|main|master|develop|release/.*|hotfix/.*)$"
'"$RE_SNIPPET"'
printf "%s" "$REMOTE_MERGED" > '"$RM"'.enum' ) >/dev/null 2>&1
  eq "${ cut -f1 < "$RM.enum"; }" "rm/oldsh" \
     "13i the remote enumeration filters correctly under /bin/bash 3.2 too"
  eq "${ cut -f2 < "$RM.enum"; }" "${ check_git "$RM" rev-parse refs/remotes/origin/rm/oldsh; }" \
     "13i …and still carries the tip the delete will be leased to"
else
  check_note "13i SKIPPED the old-interpreter pass: /bin/bash is absent, or is this suite's own interpreter (${BASH_VERSION})"
fi

# --- 13j. UNKNOWN liveness is never reported as a LIVE RUN (PR #393 review on #350) ------------
# A malformed or unreadable canonical marker scans as `marker` with key `-`; `state-verdict
# marker` keeps it, fail closed — but that establishes only UNKNOWN liveness. The report must not
# convert the conservative refusal into a confirmed "run in flight" claim, or corrupt stale state
# gets trusted indefinitely on the report's word.
rm -rf "${MR:?}"; mkdir -p "$MR"
printf 'not json at all' > "$MR/implement-issue-active.json"
eq "${ bash "$CL" state-scan "$MR" | cut -f3; }" "-" \
   "13j the fixture's marker really scans with key '-' — otherwise this case tests nothing"
mr_run "$MR"
eq "${ mr_line; }" \
   "Run marker: implement-issue-active.json [present; liveness could not be verified — kept fail-closed]" \
   "13j an unverifiable marker is reported as exactly that — never as a run in flight"

# --- 13k. THE CONTROL: 13j must be able to fail, and the witness is the REAL block, MUTATED ----
# The shipped snippet with the key test blinded — the pre-fix shape, where every kept marker got
# the confirmed-liveness wording regardless of whether liveness was ever established.
MRJ_NEEDLE='if [ "$key" = "-" ]; then'
MRJ_BLIND='      if false; then'
MRJ_BROKEN="${ printf '%s\n' "$MR_SNIPPET" \
  | N="$MRJ_NEEDLE" R="$MRJ_BLIND" awk 'index($0, ENVIRON["N"]) { print ENVIRON["R"]; next } { print }'; }"
if [ "$MRJ_BROKEN" = "$MR_SNIPPET" ]; then
  bad "13k the control mutation did not apply — the needle no longer matches the shipped block"
else ok; fi
mr_run "$MR" "$CL" "$MRJ_BROKEN"
has "${ mr_line; }" 'artifacts kept for a run in flight' \
   "13k the control (the key test blinded) reports unknown liveness as a run in flight — the overclaim the review names"

# ================= 14. run-live: the post-scan liveness re-probe (#435) =========================
# The sweep's verdicts rest on LOCK/RUN_NOW as ONE scan captured them, and the scan fingerprints
# artifacts as it walks — so an admission landing mid-walk yields "no run" verdicts beside a live
# run's identities. The workflow re-asks THIS question after every identity is captured, so the
# answer must be a live read of the directory, fail-closed toward "live".
RL_D="$(mktemp -d "${TMPDIR:-/tmp}/adb-runlive.XXXXXX")"
bash "$CL" run-live "$RL_D" >/dev/null 2>&1
eq "$?" "10" "14 an empty state dir is not a live run (10)"
: > "$RL_D/gap-analysis.lock"
bash "$CL" run-live "$RL_D" >/dev/null 2>&1
eq "$?" "0" "14 a claim present NOW is a live run (0)"
rm -f "$RL_D/gap-analysis.lock"
: > "$RL_D/implement-issue-active.json"
bash "$CL" run-live "$RL_D" >/dev/null 2>&1
eq "$?" "0" "14 an active marker present NOW is a live run (0)"
rm -f "$RL_D/implement-issue-active.json"
: > "$RL_D/implement-issue-blocked.json"
bash "$CL" run-live "$RL_D" >/dev/null 2>&1
eq "$?" "0" "14 a blocked marker keeps its run's artifacts too (0)"
rm -f "$RL_D/implement-issue-blocked.json"
ln -s /nonexistent "$RL_D/gap-analysis.lock"
bash "$CL" run-live "$RL_D" >/dev/null 2>&1
eq "$?" "0" "14 even a planted link at the claim name reads live — fail closed toward keeping"
rm -f "$RL_D/gap-analysis.lock"
bash "$CL" run-live "$RL_D/absent" >/dev/null 2>&1
eq "$?" "10" "14 a missing state dir is no run (10)"
bash "$CL" run-live >/dev/null 2>&1
eq "$?" "2" "14 no argument is a usage error"
rm -rf "$RL_D"
# …and the workflow consults it between the identity snapshot and the delete loop, branching on
# the STATUS: only rc 10 means "no run", and any other nonzero (a damaged helper) keeps
# everything rather than reading as staleness.
if grep -q 'run-live "\$STATE"' "$ROOT/base/workflows/cleanup.md"; then ok; else
  bad "14 cleanup.md never re-asks liveness after the identity snapshot"; fi
if grep -q 'liveness re-probe failed' "$ROOT/base/workflows/cleanup.md" \
   && grep -q '"\$RL_RC" -ne 10' "$ROOT/base/workflows/cleanup.md"; then ok; else
  bad "14 cleanup.md treats a run-live ERROR like rc 10 — a damaged helper would read as staleness"; fi

# ================= 15. file-size: the sweep's bounded size read (#435) ==========================
# The report loop reads agent-written error files; a parent-shell `wc -c <` redirect could be
# blocked forever by a FIFO swapped in after the scan.
FS_D="$(mktemp -d "${TMPDIR:-/tmp}/adb-fsize.XXXXXX")"
printf 'hello\n' > "$FS_D/f"
eq "$(bash "$CL" file-size "$FS_D/f" 2>/dev/null)" "6" "15 a regular file sizes to its bytes"
bash "$CL" file-size "$FS_D/absent" >/dev/null 2>&1
no "$?" "15 a missing path is loud, never a silent zero"
mkdir "$FS_D/d"
bash "$CL" file-size "$FS_D/d" >/dev/null 2>&1
no "$?" "15 a directory is loud too"
# GNU wc prints a `0` count line for a directory BEFORE exiting 1 (probed: coreutils 9.11), and a
# `… | awk` pipeline returned awk's 0 over it — so the assertion above was red only on ubuntu. The
# stub reproduces that exact shape, so the guard goes red on every platform.
mkdir "$FS_D/bin"
printf '#!/bin/sh\nprintf "0 %%s\\n" "$2"\nexit 1\n' > "$FS_D/bin/wc"
chmod +x "$FS_D/bin/wc"
PATH="$FS_D/bin:$PATH" bash "$CL" file-size "$FS_D/d" >/dev/null 2>&1
no "$?" "15 a directory is loud under GNU wc too, whose 0 count line must not read as a size"
bash "$CL" file-size >/dev/null 2>&1
eq "$?" "2" "15 no argument is a usage error"
rm -rf "$FS_D"
# …and the sweep's fence uses it instead of the redirect.
if grep -q 'file-size "\$sfile"' "$ROOT/base/workflows/cleanup.md"; then ok; else
  bad "15 cleanup.md still sizes report files through a parent-shell redirect"; fi
if grep -q 'wc -c < "\$sfile"' "$ROOT/base/workflows/cleanup.md"; then
  bad "15 …the unbounded redirect open is back in the fence"; else ok; fi

check_summary "check-cleanup"
