#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for implement-issue-gate.sh's LIVE PR re-verification (#44).
#
# The Stop hook must not trust a stored prUrl/phase=complete to decide a run is done — it
# re-checks GitHub at the moment it acts, confirms the PR is THIS run's (this repo + branch)
# and still OPEN or MERGED, and FAILS CLOSED: a closed-without-merge or unverifiable PR keeps
# the turn going rather than letting it stop on stale state.
#
# `gh` is stubbed by a shim on PATH driven by SHIM_* env vars, and CLAUDE_CODE_EXECPATH is
# unset so the deterministic legacy signal (keep-going = exit 2) is used regardless of where
# the suite runs. Observables per case: exit code AND whether the active marker survives
# (a pass removes it; keep-going retains it).
#
# Usage: bash scripts/check-implement-gate.sh   (exit 0 = all pass, 1 = a failure)

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
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
GATE="$ROOT/agents/claude/scripts/implement-issue-gate.sh"

command -v jq >/dev/null 2>&1 || { echo "check-implement-gate: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/has + check_summary + check_git

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- gh shim -----------------------------------------------------------------
shimbin="$work/bin"; mkdir -p "$shimbin"
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
# Every invocation is traced when SHIM_TRACE names a file, so a case can assert the gate made NO
# GitHub calls at all — which is the observable difference between "decided not to act" and
# "acted and happened to find nothing".
[ -n "${SHIM_TRACE:-}" ] && printf '%s\n' "$*" >> "$SHIM_TRACE"
# Simulate ANOTHER process finishing its run while this hook is mid-lookup: the marker is deleted
# or replaced underneath us, exactly in the window between the gate's read and its verdict.
if [ -n "${SHIM_MUTATE:-}" ] && [ "$1 $2" = "pr ${SHIM_MUTATE_ON:-list}" ]; then
  case "$SHIM_MUTATE" in
    delete)  rm -f "$SHIM_MARKER_PATH" ;;
    replace) printf '%s' "${SHIM_MARKER_REPLACEMENT:-}" > "$SHIM_MARKER_PATH" ;;
  esac
fi
case "$1 $2" in
  "repo view") printf '%s\n' "${SHIM_REPO_URL:-}" ;;
  "pr view")
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_JSON:-}" ;;
  "pr list")
    # 1 = fail loudly (stderr carries a reason); 2 = fail SILENTLY, which is the case that proved
    # keying `live_pr` on stderr instead of on the exit status was wrong.
    if [ "${SHIM_PR_LIST_FAIL:-0}" = "1" ]; then echo "gh: API rate limit exceeded" >&2; exit 1; fi
    if [ "${SHIM_PR_LIST_FAIL:-0}" = "2" ]; then exit 1; fi
    # When SHIM_PR_LIST_JSON is set, emulate real `gh pr list --json ... --jq EXPR` by applying
    # EXPR to the canned array (so the gate's own isCrossRepository filter is exercised); else
    # fall back to echoing the pre-filtered SHIM_OPEN_PR_URL.
    if [ -n "${SHIM_PR_LIST_JSON:-}" ]; then
      _jq='.'; while [ $# -gt 0 ]; do if [ "$1" = "--jq" ]; then _jq="$2"; break; fi; shift; done
      printf '%s' "$SHIM_PR_LIST_JSON" | jq -r "$_jq"
    else
      printf '%s\n' "${SHIM_OPEN_PR_URL:-}"
    fi ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"

# --- fixture repo (.claude/state gitignored so the marker never dirties the tree) --
repo="$work/repo"; mkdir -p "$repo/.claude/state"
git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main
printf '.claude/state/\n' > "$repo/.gitignore"
printf 'seed\n' > "$repo/README.md"
check_git "$repo" add .gitignore README.md; check_git "$repo" commit -q -m seed
git -C "$repo" checkout -q -b feat
marker_file="$repo/.claude/state/implement-issue-active.json"
blocked_file="$repo/.claude/state/implement-issue-blocked.json"

REPO_URL="https://github.com/acme/repo"
# Two distinct session ids, so "is this marker mine?" has a real answer either way (#180).
SID_A="11111111-aaaa-4aaa-8aaa-111111111111"
SID_B="22222222-bbbb-4bbb-8bbb-222222222222"

# Export the shim knobs ONCE (empty), so each case plain-reassigns them (keeping them exported
# for the shim subprocess) without `export VAR="$(...)"` masking a command-substitution status.
export SHIM_REPO_URL="" SHIM_PR_JSON="" SHIM_OPEN_PR_URL="" SHIM_PR_VIEW_FAIL="" SHIM_PR_LIST_JSON=""
export SHIM_PR_LIST_FAIL="" SHIM_TRACE="" SHIM_MUTATE="" SHIM_MUTATE_ON="" SHIM_MARKER_REPLACEMENT=""
export SHIM_MARKER_PATH="$marker_file"
# Resets the whole CASE, not just the shim: stub knobs, the gate's stdin/identity, and any blocked
# file a previous case left behind.
reset_case() {
  SHIM_REPO_URL=""; SHIM_PR_JSON=""; SHIM_OPEN_PR_URL=""; SHIM_PR_VIEW_FAIL=""; SHIM_PR_LIST_JSON=""
  SHIM_PR_LIST_FAIL=""; SHIM_TRACE=""; SHIM_MUTATE=""; SHIM_MUTATE_ON=""; SHIM_MARKER_REPLACEMENT=""
  GATE_STDIN="/dev/null"; GATE_SESSION=""
  rm -f "$blocked_file"
}

pr_json() {  # <state> <mergedAt-or-empty> <url> <headRefName>
  jq -cn --arg s "$1" --arg m "$2" --arg u "$3" --arg h "$4" \
    '{state:$s, mergedAt:(if $m=="" then null else $m end), url:$u, headRefName:$h}'
}
write_marker() {  # <phase> <prUrl-or-empty> [owner]
  jq -n --arg b feat --arg i 35 --arg p "$1" --arg u "$2" --arg o "${3:-}" \
    '{branch:$b, issue:$i, phase:$p}
     + (if $u=="" then {} else {prUrl:$u} end)
     + (if $o=="" then {} else {owner:$o} end)' > "$marker_file"
}
write_blocked() {  # <branch> <issue> [owner]
  jq -n --arg b "$1" --arg i "$2" --arg o "${3:-}" \
    '{reason:"test", branch:$b, issue:$i} + (if $o=="" then {} else {owner:$o} end)' > "$blocked_file"
}
# A Stop-hook stdin payload, as Claude Code pipes it. Usage: payload_file <session-id>
payload_file() {
  jq -n --arg s "$1" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false}' \
    > "$work/payload.json"
  printf '%s' "$work/payload.json"
}
# Every invocation gets an EXPLICIT stdin and an EXPLICIT session identity.
#
# stdin, because the gate may read its hook payload from there: a suite that let the hook inherit
# the caller's stdin would block on that read whenever the suite is run from a terminal, and a
# hung test reads exactly like a wedged gate. /dev/null is the default — "this host sent no
# payload" — and payload_file supplies one where the case is about the payload.
#
# CLAUDE_CODE_SESSION_ID, because it is the gate's FIRST identity source, and a suite that let it
# leak in from the developer's own Claude session would pass or fail depending on who ran it.
GATE_STDIN="/dev/null"
GATE_SESSION=""
run_gate() {  # sets RC, OUT ; SHIM_*/GATE_* read from the (exported) env
  OUT="$(cd "$repo" && unset CLAUDE_CODE_EXECPATH \
        && if [ -n "$GATE_SESSION" ]; then export CLAUDE_CODE_SESSION_ID="$GATE_SESSION"; \
           else unset CLAUDE_CODE_SESSION_ID; fi \
        && PATH="$shimbin:$PATH" bash "$GATE" < "$GATE_STDIN" 2>&1)"; RC=$?
}
gone() { [ ! -f "$marker_file" ]; }

# --- cases -------------------------------------------------------------------

# A. stored PR OPEN and this-run's → satisfied: marker removed, exit 0.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json OPEN '' "$REPO_URL/pull/1" feat; }"
run_gate
eq "$RC" 0 "A: open stored PR → exit 0"
if gone; then ok; else bad "A: open stored PR removes the marker"; fi

# B. stored PR MERGED → satisfied, even though phase=complete is not trusted on its own.
reset_case; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json MERGED 2026-01-01T00:00:00Z "$REPO_URL/pull/1" feat; }"
run_gate
eq "$RC" 0 "B: merged stored PR → exit 0"
if gone; then ok; else bad "B: merged stored PR removes the marker"; fi

# C. stored PR CLOSED-unmerged, no replacement → keep going, marker retained, closed message.
reset_case; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "C: closed-unmerged → keep going (exit 2)"
if gone; then bad "C: closed-unmerged must RETAIN the marker"; else ok; fi
has "$OUT" "CLOSED without merging" "C: message names the closed PR"

# D. stored PR belongs to a DIFFERENT repo → unverified → keep going.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json OPEN '' "https://github.com/other/repo/pull/1" feat; }"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "D: wrong-repo PR is unverified → keep going"
if gone; then bad "D: wrong-repo unverified must RETAIN the marker"; else ok; fi

# E. stored PR CLOSED but a replacement OPEN PR exists for the branch → satisfied.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"; SHIM_OPEN_PR_URL="$REPO_URL/pull/2"
run_gate
eq "$RC" 0 "E: closed stored + replacement open PR → exit 0"
if gone; then ok; else bad "E: replacement open PR removes the marker"; fi

# F. gh pr view errors → unverified (fail closed, NOT trust-the-marker) → keep going.
reset_case; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_VIEW_FAIL=1; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "F: gh error → unverified → keep going (fail closed)"
if gone; then bad "F: gh error must RETAIN the marker"; else ok; fi
has "$OUT" "could not be verified" "F: message flags the unverified state"

# G. no prUrl but an OPEN PR exists for the branch (marker not yet updated) → satisfied.
reset_case; write_marker committed ""
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL="$REPO_URL/pull/1"
run_gate
eq "$RC" 0 "G: no prUrl + live open PR → exit 0"
if gone; then ok; else bad "G: live open PR removes the marker"; fi

# H. no prUrl, no open PR, clean tree → keep going with the has-not-opened message.
reset_case; write_marker committed ""
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "H: no prUrl + no open PR → keep going"
if gone; then bad "H: no-PR must RETAIN the marker"; else ok; fi
has "$OUT" "has not opened a PR yet" "H: message is the not-yet-opened hint"

# I. stored PR is for a DIFFERENT branch → unverified → keep going.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json OPEN '' "$REPO_URL/pull/1" some-other-branch; }"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "I: PR on a different branch is unverified → keep going"

# J. branch-lookup fallback must EXCLUDE a fork PR (isCrossRepository=true) with the same branch
#    name — a closed stored PR + only-a-fork-PR must keep going, not falsely satisfy.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"
SHIM_PR_LIST_JSON='[{"url":"https://github.com/fork/repo/pull/9","isCrossRepository":true}]'
run_gate
eq "$RC" 2 "J: a same-name fork PR does NOT satisfy → keep going"
if gone; then bad "J: fork-only lookup must RETAIN the marker"; else ok; fi
# J2. a SAME-repo replacement in the list (isCrossRepository=false) DOES satisfy.
reset_case; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"
SHIM_PR_LIST_JSON='[{"url":"https://github.com/fork/repo/pull/9","isCrossRepository":true},{"url":"'"$REPO_URL"'/pull/2","isCrossRepository":false}]'
run_gate
eq "$RC" 0 "J2: a same-repo replacement PR (past a fork) satisfies → exit 0"
if gone; then ok; else bad "J2: same-repo replacement removes the marker"; fi

# K. DIRTY tree + closed stored PR + no replacement → must KEEP GOING (fail closed), not defer to
#    precommit (completion gating sits ahead of the uncommitted-changes deferral).
reset_case; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"; SHIM_OPEN_PR_URL=""
printf 'dirty\n' >> "$repo/README.md"   # make the worktree dirty (tracked file)
run_gate
eq "$RC" 2 "K: dirty tree + closed PR → keep going (not deferred to precommit)"
if gone; then bad "K: dirty+closed must RETAIN the marker"; else ok; fi
git -C "$repo" checkout -q -- README.md   # restore clean tree

# K2. control: dirty tree + NO recorded PR + no open PR → DEFERS to precommit (exit 0), unchanged.
reset_case; write_marker committed ""
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
printf 'dirty\n' >> "$repo/README.md"
run_gate
eq "$RC" 0 "K2: dirty tree + no recorded PR → defers to precommit (exit 0)"
git -C "$repo" checkout -q -- README.md

# --- ownership: two sessions, one checkout (#180) -----------------------------
# Branch name is a WORKING-TREE property, so before the `owner` field every session in a clone
# matched the same marker. These cases pin the fix in both directions — the foreign marker is
# inert AND untouched, while the owning session is still enforced exactly as before.

# Read through `eq` rather than a bare boolean, so a race regression prints the two byte strings
# instead of just a label — which is exactly where you want them.
marker_now() { cat "$marker_file" 2>/dev/null; }
REPLACEMENT='{"branch":"feat","issue":"36","phase":"branched","owner":"'"$SID_B"'"}'

# L. A marker owned by ANOTHER session: silence, byte-identical marker, and NOT ONE gh call.
#    The no-call assertion is the point — "left it alone" must mean untouched, not "looked and
#    happened to find nothing".
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_B"
SNAP="$(cat "$marker_file")"
SHIM_TRACE="$work/trace"; rm -f "$SHIM_TRACE"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "L: foreign-owner marker → exit 0 (silence)"
eq "$OUT" "" "L: foreign-owner marker produces NO output"
eq "${ marker_now; }" "$SNAP" "L: foreign-owner marker must be left byte-identical"
if [ -s "$SHIM_TRACE" ]; then bad "L: foreign-owner marker must not trigger any gh call"; else ok; fi

# M. The OWNING session is still enforced — ownership narrows who acts, it never disarms the run.
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "M: own-owner marker → keep going"
has "$OUT" "has not opened a PR yet" "M: own-owner marker still emits the resume hint"

# N. An OWNERLESS marker (written before this field existed) keeps the legacy branch behavior,
#    even though this session has an id. Failing toward enforcement is the documented choice:
#    going inert would silently switch the invariant off for every pre-upgrade run.
reset_case; write_marker committed ""; GATE_SESSION="$SID_B"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "N: ownerless marker → legacy branch behavior (still enforced)"

# O. Owned marker, but the host offers NO identity (no env var, no payload) → same fallback.
reset_case; write_marker committed "" "$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "O: unidentifiable session → legacy branch behavior (still enforced)"

# P. Identity from the stdin PAYLOAD when the env var is absent — foreign → silence.
reset_case; write_marker committed "" "$SID_A"; GATE_STDIN="${ payload_file "$SID_B"; }"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "P: payload session_id (foreign) → exit 0"
# P2. …and the same source proves ownership the other way.
reset_case; write_marker committed "" "$SID_A"; GATE_STDIN="${ payload_file "$SID_A"; }"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "P2: payload session_id (mine) → keep going"

# --- blocked-file ownership ---------------------------------------------------
# The escape hatch was keyed to branch/issue alone, so one session's give-up granted every
# session a free pass.

# Q. A blocked file written by ANOTHER session does not end this session's run.
reset_case; write_marker committed "" "$SID_A"; write_blocked feat 35 "$SID_B"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "Q: foreign blocked file does NOT grant a stop"
has "$OUT" "written by another session" "Q: the ignored blocked file is named as another session's"

# Q2. The owning session's own blocked file still does.
reset_case; write_marker committed "" "$SID_A"; write_blocked feat 35 "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "Q2: matching blocked file grants a stop"

# Q3. Mixed vintage (owned marker, ownerless blocked file) falls back to branch/issue and GRANTS
#     the stop. Deliberately permissive: refusing it would make the turn unstoppable, which is a
#     worse failure than an over-granted escape.
reset_case; write_marker committed "" "$SID_A"; write_blocked feat 35; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "Q3: ownerless blocked file still grants a stop (permissive migration)"

# --- the marker moving underneath the hook ------------------------------------
# The gate's verdict is built from a read taken before two gh round-trips. In a shared checkout
# the owning session can finish inside that window — which is how a session was once told to
# `gh pr create` against a branch that already had an open PR.

# R. Marker DELETED mid-lookup → silence, not a nag.
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""; SHIM_MUTATE="delete"; SHIM_MUTATE_ON="list"
run_gate
eq "$RC" 0 "R: marker deleted mid-hook → exit 0"
hasnt "$OUT" "has not opened a PR yet" "R: a vanished marker must not produce a resume hint"

# R2. Marker REPLACED mid-lookup by the next run → silence, and the replacement survives intact.
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
SHIM_MUTATE="replace"; SHIM_MUTATE_ON="list"; SHIM_MARKER_REPLACEMENT="$REPLACEMENT"
run_gate
eq "$RC" 0 "R2: marker replaced mid-hook → exit 0"
eq "${ marker_now; }" "$REPLACEMENT" "R2: the replacement marker must survive"

# R3. Same race on the SATISFIED path: the stored PR verifies, but the marker we would clear is no
#     longer the one we read — deleting it would disarm a run that had not even started.
reset_case; write_marker committed "$REPO_URL/pull/1" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json OPEN '' "$REPO_URL/pull/1" feat; }"
SHIM_MUTATE="replace"; SHIM_MUTATE_ON="view"; SHIM_MARKER_REPLACEMENT="$REPLACEMENT"
run_gate
eq "$RC" 0 "R3: satisfied PR + replaced marker → exit 0"
eq "${ marker_now; }" "$REPLACEMENT" "R3: a replacement marker must not be deleted"

# --- 'could not check' is not 'there is no PR' --------------------------------
# S. A failed branch lookup must surface the uncertainty, never assert the absence
#    (verify-before-asserting.md). The gh-not-on-PATH arm sets the same `live_pr=unchecked`
#    state and renders the same lead.
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_LIST_FAIL=1
run_gate
eq "$RC" 2 "S: failed PR lookup → keep going"
has "$OUT" "could not be checked for an open PR" "S: the hint reports the lookup failure"
hasnt "$OUT" "has not opened a PR yet" "S: an unchecked lookup must not claim there is no PR"

# --- identity SOURCE precedence -----------------------------------------------
# The env var must WIN over the stdin payload. Documented in three places and, until this case,
# asserted in none: inverting the precedence in the gate left the whole suite green, because no
# case ever supplied an env id AND a conflicting payload id at the same time.

# T. env says A (matches the marker), payload says B. Env-first → mine → enforced.
#    If the payload won, this session would read as B, the marker as foreign, and the gate exit 0.
reset_case; write_marker committed "" "$SID_A"
GATE_SESSION="$SID_A"; GATE_STDIN="${ payload_file "$SID_B"; }"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "T: env id wins over a conflicting payload id (marker is mine → keep going)"

# T2. The mirror: env says B, payload says A, marker owned by A. Env-first → foreign → silence.
#     If the payload won, the marker would read as mine and the gate would nag.
reset_case; write_marker committed "" "$SID_A"
GATE_SESSION="$SID_B"; GATE_STDIN="${ payload_file "$SID_A"; }"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "T2: env id wins over a conflicting payload id (marker is foreign → exit 0)"

# --- the payload read must be BOUNDED -----------------------------------------
# U. stdin is a pipe that is never closed. A hook that blocks here burns its whole 30s budget and
#    gets killed — and a killed Stop hook enforces NOTHING, which is the fail-open the bound exists
#    to prevent. Deleting `-t 5` from the gate left the suite green before this case existed.
#    The gate discards what a timed-out read collected, so identity ends up unknown and it falls
#    back to branch matching (enforced) — the assertion is that it TERMINATES and still enforces.
#    NOTE this case writes NO bytes, so it cannot tell a discard from a retention; U2 does that.
reset_case; write_marker committed "" "$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
fifo="$work/stdin.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# Hold the write end open with no EOF for longer than the gate's bound.
sleep 25 > "$fifo" &
holder=$!
t0="$(date +%s)"
OUT="$(cd "$repo" && unset CLAUDE_CODE_EXECPATH && unset CLAUDE_CODE_SESSION_ID \
      && PATH="$shimbin:$PATH" bash "$GATE" < "$fifo" 2>&1)"; RC=$?
t1="$(date +%s)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
rm -f "$fifo"
if [ "$((t1 - t0))" -lt 20 ]; then ok; else bad "U: unclosed stdin must not block the hook (took $((t1 - t0))s)"; fi
eq "$RC" 2 "U: unclosed stdin → identity unknown → legacy enforcement, not a hang"

# U2. THE SAME BOUND, WITH BYTES ON THE WIRE — the case U cannot see (#258).
#
# `read -t` behaves differently either side of this repo's floor, and the gate's design depends on
# which: bash 3.2 DISCARDED what it had collected when the bound fired, bash >= 4.2 KEEPS it
# (measured: 3.2 returns status 1 with an empty variable, 5.3 returns 142 with the bytes). This
# file's identity rule was written against the discard and said so, so under the 5.3 floor the
# discard became the gate's own job rather than the interpreter's.
#
# The payload here is a COMPLETE, VALID object naming a FOREIGN session, on a pipe that never
# closes. That combination is what discriminates, and both halves are load-bearing: a TRUNCATED
# object would be rejected by jq on either interpreter, so a fixture built on one proves nothing.
#   retained -> jq parses it -> identity is SID_B -> foreign marker -> silence (0)
#   discarded -> identity unknown -> branch matching -> still enforced (2)
# The gate must not take an identity off a stream it could not finish reading: unknown falls
# TOWARD enforcement, which is the direction every other ownership decision in this file picks.
reset_case; write_marker committed "" "$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
fifo2="$work/stdin2.fifo"; rm -f "$fifo2"; mkfifo "$fifo2"
# Write a whole object, then hold the write end open past the gate's 5s bound WITHOUT sending EOF.
( exec 3>"$fifo2"
  jq -cn --arg s "$SID_B" '{session_id:$s, hook_event_name:"Stop", stop_hook_active:false}' >&3
  sleep 25 ) &
holder2=$!
OUT="$(cd "$repo" && unset CLAUDE_CODE_EXECPATH && unset CLAUDE_CODE_SESSION_ID \
      && PATH="$shimbin:$PATH" bash "$GATE" < "$fifo2" 2>&1)"; RC=$?
kill "$holder2" 2>/dev/null; wait "$holder2" 2>/dev/null
rm -f "$fifo2"
eq "$RC" 2 "U2: a timed-out read discards what arrived — no identity from an unfinished stream"

# --- malformed markers must be inert, never a hint ----------------------------
# Folding the `jq -e .` validation into the extract dropped these: `jq -r '.branch // ""'` exits 0
# on a top-level null and on whitespace-only input, yielding five EMPTY fields — which skip both the
# owner check and the branch guard, so the gate nagged about issue `#` on branch `` in every session
# in the checkout. No prior case wrote a marker that was not a well-formed object.
for bad_marker in 'null' '   ' '[]' '"a string"' '123' '{'; do
  reset_case; printf '%s' "$bad_marker" > "$marker_file"
  GATE_SESSION="$SID_B"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
  run_gate
  eq "$RC" 0 "V: non-object marker [$bad_marker] → exit 0"
  hasnt "$OUT" "has not opened a PR" "V: non-object marker [$bad_marker] emits no resume hint"
done

# --- an oversized marker is refused UNREAD (PR #443 review) ------------------
# A well-formed, owned marker that WOULD nag, padded past the bound: the gate must not load it —
# it says so, and passes, exactly as it does for a malformed one.
reset_case
{ jq -n --arg o "$SID_A" '{branch:"feat", issue:"35", phase:"pushed", owner:$o}'; head -c 70000 /dev/zero | tr '\0' ' '; } > "$marker_file"
GATE_SESSION="$SID_A"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "V2: an oversized marker → exit 0"
has "$OUT" "larger than any marker the workflow writes" "V2: ...and the gate says it was not read"
hasnt "$OUT" "has not opened a PR" "V2: ...and emits no resume hint from bytes it never loaded"

# --- a newline in a field must not shift the ownership decode -----------------
# The five fields are decoded BY POSITION from newline-separated jq output, and `owner` is last, so
# one embedded newline silently re-aims the ownership test. Both directions were live bugs.

# W. A newline in `prUrl` used to push the URL into `owner`, making the run's OWN marker look
#    foreign — the invariant silently off. prUrl gates no comparison, so it is dropped to empty and
#    the run stays enforced.
reset_case
jq -n --arg o "$SID_A" '{branch:"feat", issue:"35", phase:"pushed",
   prUrl:"Warning: gh said something\nhttps://github.com/acme/repo/pull/7", owner:$o}' > "$marker_file"
GATE_SESSION="$SID_A"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "W: newline in prUrl must not make my own marker read as foreign"
has "$OUT" "has not opened a PR yet" "W: a multi-line prUrl is ignored, not parsed as the owner"

# W2. A newline in `branch` used to shift `owner` off the end entirely, so a FOREIGN marker read as
#     unowned and got acted on — the #180 defect returning. branch gates the match, so the whole
#     marker is refused.
reset_case
jq -n --arg o "$SID_A" '{branch:"feat\nINJECTED", issue:"35", phase:"committed", owner:$o}' > "$marker_file"
GATE_SESSION="$SID_B"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 0 "W2: newline in branch → marker refused, not acted on by a foreign session"
hasnt "$OUT" "INJECTED" "W2: a shifted field never reaches the resume hint"

# --- a failed lookup must not be reported as 'no PR' on ANY arm ---------------
# X. gh EXITS NON-ZERO WITH EMPTY STDERR. `live_pr` used to be keyed on whether stderr had bytes,
#    so a silent failure read as "there is no PR" and the gate told the agent to open one.
reset_case; write_marker committed "" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_LIST_FAIL=2   # exit 1, print nothing
run_gate
eq "$RC" 2 "X: gh failing silently → keep going"
hasnt "$OUT" "has not opened a PR yet" "X: a silent lookup failure must not claim there is no PR"
has "$OUT" "could not be checked for an open PR" "X: it reports the unchecked lookup instead"

# X2. The closed-stored-PR arm also has to carry the warning: it tells the agent to open a
#     REPLACEMENT PR, and a failed lookup means we never checked whether one exists.
reset_case; write_marker complete "$REPO_URL/pull/1" "$SID_A"; GATE_SESSION="$SID_A"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="${ pr_json CLOSED '' "$REPO_URL/pull/1" feat; }"; SHIM_PR_LIST_FAIL=1
run_gate
eq "$RC" 2 "X2: closed stored PR + failed replacement lookup → keep going"
has "$OUT" "could not be run" "X2: the closed arm warns that no replacement lookup succeeded"

# --- #202: two live runs, one tree — the gate still enforces for A after B tries to start -------
# The acceptance criterion this file owes #202. Everything above tests the hook in isolation; what
# broke run A was a SECOND session's preflight, and the damage was only visible HERE — A's marker
# gone, so the hook exits 0 and A's no-stop-until-PR invariant is silently off.
#
# So the case is end-to-end across the two components: run A's marker is live, session B runs the
# real `implement-lib.sh admit`, and then the hook is asked whether A must keep going. Asserting
# `admit`'s exit code alone would not catch it — that is check-implement-lib.sh's job — because the
# failure mode is what the NEXT actor concludes from the state that survived.
#
# Under a refusal design there are never two markers, so "neither run loses its marker" is
# necessarily "the one live marker survives, and still enforces".
IL="$ROOT/scripts/lib/implement-lib.sh"
if [ ! -f "$IL" ]; then
  bad "Y: scripts/lib/implement-lib.sh not found — the two-live-runs case asserted NOTHING"
else
  reset_case
  write_marker committed "" "$SID_A"
  # A FULL pre-state, not just the marker: run A owns gap findings, review findings and a blocked
  # marker too, and an implementation that protected the marker while clearing the rest would still
  # have destroyed the run. Checking only `gaps.md` existence was the narrower assertion this
  # replaces.
  printf 'A findings\n'  > "$repo/.claude/state/gaps.md"
  printf 'A stream\n'    > "$repo/.claude/state/gaps.err"
  printf 'A prompt\n'    > "$repo/.claude/state/gap-prompt.txt"
  printf 'A review\n'    > "$repo/.claude/state/review.md"
  printf 'A slot\n'      > "$repo/.claude/state/review-codex.md"
  # A NON-MATCHING blocked marker on purpose: one that matched branch/issue would be a legitimate
  # stop and the hook would (correctly) exit 0, testing the escape hatch instead of the invariant.
  # This is still a file run A owns and whose bytes must survive B's attempt.
  write_blocked other-branch 99 "$SID_A"
  state_digest_a() {
    ( cd "$repo/.claude/state" || exit 0
      find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s:%s\n' "$f" "${ cksum < "$f" 2>/dev/null | awk '{print $1"-"$2}'; }"
      done )
  }
  digest_before="${ state_digest_a; }"
  ident_before="${ cksum < "$marker_file" | awk '{print $1"-"$2}'; }"

  admit_out="$( cd "$repo" && env CLAUDE_CODE_SESSION_ID="$SID_B" PATH="$shimbin:$PATH" \
                SHIM_REPO_URL="$REPO_URL" bash "$IL" admit .claude/state 2>&1 )"; admit_rc=$?
  eq "$admit_rc" 10 "Y: session B is refused while A's marker is live"
  has "$admit_out" "already in flight" "Y: …and told why"

  # THE POINT OF THE CASE. Byte identity, not mere existence: a rewritten marker would still be a
  # marker, and the hook's own delete-time guard compares content.
  eq "${ cksum < "$marker_file" | awk '{print $1"-"$2}'; }" "$ident_before" \
     "Y: A's marker survives B's attempt, byte for byte"
  eq "${ state_digest_a; }" "$digest_before" \
     "Y: …and so does EVERY other file A owns — gap findings, review findings, blocked marker"

  # And the invariant it exists to arm is still armed FOR A — which is the thing that was silently
  # switched off. A `0` here is the bug: the turn would be allowed to end with no PR.
  GATE_SESSION="$SID_A"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
  run_gate
  eq "$RC" 2 "Y: …and A's continuation gate still fires, rather than exiting 0 on a deleted marker"
  has "$OUT" "has not opened a PR yet" "Y: …with A's own resume hint, naming A's run"

  # B, meanwhile, must not have been handed A's run: the hook stays silent for the session that was
  # refused. That is #180's rule still holding on top of #202's — the two guards compose.
  reset_case; GATE_SESSION="$SID_B"; SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
  run_gate
  eq "$RC" 0 "Y: the refused session is not told to continue A's run"
  rm -f "$repo/.claude/state/gaps.md" "$repo/.claude/state/gaps.err" \
        "$repo/.claude/state/gap-prompt.txt" "$repo/.claude/state/review.md" \
        "$repo/.claude/state/review-codex.md" "$repo/.claude/state/gap-analysis.lock"
fi

check_summary "implement-gate"
