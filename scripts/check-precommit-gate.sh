#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for precommit-gate.sh's fail-loud dependency loading (#35).
#
# The core guarantee: a Stop-hook quality gate that cannot load its OWN shared library is a
# broken install, so it FAILS LOUD (exit 2, blocking) — it never silently exit-0s (that was
# the fail-silent bug: enforcement secretly off). Distinct from "no gates detected" in an
# unfamiliar repo, which stays a legitimate no-op.
#
# The gate resolves its library as `$(dirname "$0")/lib`, so a COPY of the script with a
# lib/ dir we populate or empty lets us exercise present / missing-common / missing-gates.
#
# Usage: bash scripts/check-precommit-gate.sh   (exit 0 = all pass, 1 = a failure)

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
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq + check_summary + check_git

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- a copy of the gate with a controllable lib/ -----------------------------
gate="$work/gate"; mkdir -p "$gate"
cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"
set_libs() {  # both | nocommon | noproject | none
  rm -rf "${gate:?}/lib"; mkdir -p "$gate/lib"
  case "$1" in
    both)      cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/project-gates.sh" "$gate/lib/" ;;
    nocommon)  cp "$ROOT/scripts/lib/project-gates.sh" "$gate/lib/" ;;
    noproject) cp "$ROOT/scripts/lib/common.sh" "$gate/lib/" ;;
    none)      : ;;
  esac
}

# --- a fixture repo whose default branch is deterministically 'main' ---------
repo="$work/repo"; mkdir -p "$repo"
git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main
printf 'seed\n' > "$repo/README.md"
check_git "$repo" add -A; check_git "$repo" commit -q -m seed

on_main()            { git -C "$repo" checkout -q main; git -C "$repo" clean -qfd; }
on_feature_clean()   { git -C "$repo" checkout -q -B feat main; git -C "$repo" clean -qfd; }
on_feature_change()  { on_feature_clean; printf 'x\n' > "$repo/change.txt"; }   # untracked change

# Run the copied gate with CWD in the fixture; sets RC and OUT.
#
# Both the identity and stdin are EXPLICIT, for the reasons check-implement-gate.sh learned
# first. CLAUDE_CODE_SESSION_ID is the gate's only identity source (#241), so a suite that let
# the developer's own Claude session leak in would pass or fail depending on who ran it — and
# would do so silently, since a non-matching id simply reads as "not foreign". stdin is pinned
# to /dev/null so a case can prove the gate does NOT consume the hook payload.
GATE_SESSION=""
GATE_STDIN="/dev/null"
run_gate() {
  OUT="$(cd "$repo" \
        && if [ -n "$GATE_SESSION" ]; then export CLAUDE_CODE_SESSION_ID="$GATE_SESSION"; \
           else unset CLAUDE_CODE_SESSION_ID; fi \
        && bash "$gate/precommit-gate.sh" < "$GATE_STDIN" 2>&1)"; RC=$?
}
is_fatal() { case "$OUT" in *FATAL*) return 0 ;; *) return 1 ;; esac; }

SID_MINE="11111111-aaaa-4aaa-8aaa-111111111111"
SID_OTHER="22222222-bbbb-4bbb-8bbb-222222222222"
marker_file="$repo/.claude/state/implement-issue-active.json"
write_marker() {  # <branch> <owner-or-empty>   ("" owner writes NO owner key)
  mkdir -p "$repo/.claude/state"
  jq -n --arg b "$1" --arg o "${2:-}" \
    '{branch:$b, issue:"240", phase:"implemented"}
     + (if $o=="" then {} else {owner:$o} end)' > "$marker_file"
}
clear_marker() { rm -rf "$repo/.claude/state"; }

# --- cases -------------------------------------------------------------------

# 1. libs present, on the default branch → no-op (nothing to gate).
set_libs both; on_main; run_gate
eq "$RC" "0" "libs present + default branch → exit 0"

# 2. libs present, feature branch, no changes → no-op.
set_libs both; on_feature_clean; run_gate
eq "$RC" "0" "libs present + feature branch + no changes → exit 0"

# 3. libs present, feature branch, changes, NO gates detected (no toolchain/agents.toml) → no-op.
set_libs both; on_feature_change; rm -f "$repo/agents.toml"; run_gate
eq "$RC" "0" "libs present + changes + no gates detected → exit 0 (unfamiliar-repo no-op)"

# 4. libs present, feature branch, changes, a FAILING configured gate → block (exit 2).
set_libs both; on_feature_change
printf '[gates]\ntest = "false"\n' > "$repo/agents.toml"
run_gate
eq "$RC" "2" "libs present + a failing gate → exit 2 (block)"
rm -f "$repo/agents.toml"

# 5. common.sh MISSING, feature branch, changes → FAIL LOUD (exit 2), not silent pass. [#35 core]
set_libs nocommon; on_feature_change; run_gate
eq "$RC" "2" "common.sh missing + would-gate → exit 2 (fail loud)"
if is_fatal; then ok; else bad "common.sh missing → message must be FATAL (loud), got: $OUT"; fi

# 6. common.sh MISSING, on the default branch → still FAIL LOUD: a broken install is loud
#    everywhere, because default-branch resolution itself needs common.sh (single-source).
set_libs nocommon; on_main; run_gate
eq "$RC" "2" "common.sh missing + default branch → exit 2 (broken install is loud everywhere)"

# 7. project-gates.sh MISSING (common.sh present), feature branch, changes → FAIL LOUD (exit 2).
set_libs noproject; on_feature_change; run_gate
eq "$RC" "2" "project-gates.sh missing + would-gate → exit 2 (fail loud)"
if is_fatal; then ok; else bad "project-gates.sh missing → message must be FATAL (loud), got: $OUT"; fi

# --- 7a-7g. THE GLOBAL GATE'S OWN LIBRARY LOAD UNDER `set -u` (#317) ---------
#
# Cases 5-7 cover a library that is ABSENT. These cover one that is PRESENT and broken, which is
# the shape `fail_loud` cannot reach on its own: an unbound expansion at a library's top level is
# fatal under `set -u` and kills the shell OUTRIGHT, so the gate exited 1 — a Stop hook's
# NON-BLOCKING error notice — with `fail_loud` never reached and no `||` able to catch it.
#
# EVERY CASE HERE NEEDS AN OBSERVABLE GATE, and that is the whole design. The exit code alone
# cannot carry these claims: 2 is both "the gate ran and blocked" and "the library was refused",
# and 0 is both "everything passed" and "the gate no-opped in an unfamiliar repo". So the fixture
# configures ONE gate that touches a marker and then fails — the marker separates ran from
# did-not-run, and the 2 it produces is the same blocking 2 the issue title contrasts with 1.
set_libs both; on_feature_change
printf '#!/usr/bin/env bash\ntouch RAN\nexit 1\n' > "$repo/redgate.sh"; chmod +x "$repo/redgate.sh"
printf '[gates]\nlint = "./redgate.sh"\n' > "$repo/agents.toml"
gate_ran() { [ -f "$repo/RAN" ]; }
run_gate_lib() {  # <mutate-common.sh-command>; clears the marker first
  set_libs both; eval "$1"; rm -f "$repo/RAN"; run_gate
}
UNBOUND='printf "\n: \"\${ADB_CHECK_DEFINITELY_UNSET_XYZ}\"\n" >> "$gate/lib/common.sh"'
TAILCUT='printf "\nadb_truncated_tail() {\n" >> "$gate/lib/common.sh"'
STUB='printf "# truncated by a partial write\n" > "$gate/lib/common.sh"'

# 7a. The precondition every case below rests on: with a healthy library the configured gate RUNS
# and its red status is what produces the 2. Asserted rather than assumed — if the fixture's gate
# were never detected, 7b would "pass" on a no-op that proves nothing.
run_gate_lib ':'
eq "$RC" "2" "global gate: healthy library + a red configured gate → exit 2"
if gate_ran; then ok "global gate: …and the gate was OBSERVED running"; else
  bad "global gate: the configured gate never ran — every case below would prove nothing"; fi

# 7b. [#317 CORE] An unbound expansion while the library loads must not DECIDE anything. The
# library still defines everything, so the honest answer is the ordinary verdict — identical to 7a.
run_gate_lib "$UNBOUND"
eq "$RC" "2" "global gate: an unbound expansion at load time does not decide the verdict (2, not 1)"
if gate_ran; then ok "global gate: …and the gate still ran to its own conclusion"; else
  bad "global gate: an unbound expansion at load time stopped the gate before it ran anything"; fi

# 7c. A library truncated AFTER the double-source guard → FAIL LOUD. `common.sh` opens with
# `_ADB_COMMON_SH_LOADED`, so once the floor bootstrap has loaded it `require_lib`'s `.` returns 0
# THROUGH the guard without reading the file — and the bootstrap runs on every ordinary
# invocation, so that is the normal path. Both of `require_lib`'s checks then passed on functions
# the partial load had already defined, and the gate ran the whole suite on it reporting success.
run_gate_lib "$TAILCUT"
eq "$RC" "2" "global gate: common.sh truncated after the double-source guard → exit 2"
has "$OUT" "failed to source" "global gate: …reported as a load failure, not incidentally by a red check"
if gate_ran; then bad "global gate: the gate RAN on a partially-loaded library"; else
  ok "global gate: …and no check runs on a partially-loaded library"; fi

# 7d. A fully truncated library keeps its existing verdict — and the floor bootstrap stays QUIET.
# The exit code cannot see that second half: `require_lib` supplies the 2 either way. Before the
# probe, the bootstrap called `adb_require_bash` as an undefined command, printing a misleading
# cause ahead of the real one and leaving the floor unenforced.
run_gate_lib "$STUB"
eq "$RC" "2" "global gate: truncated common.sh → exit 2 (the source succeeded; the library is gone)"
hasnt "$OUT" "command not found" "global gate: …without the floor bootstrap calling a missing function"

# --- 7e-7g. Each assertion above is a guard, so each is OBSERVED FAILING ------
# One mutation per repaired line, never a blanket edit: the three fixes are independent and a
# single revert could not show which assertion depends on which. `  set +u` is deliberately NOT
# the anchor — it now appears TWICE, so `check_mutate_line`'s exactly-one precondition would
# refuse, and a mutation that refuses proves nothing. Each anchors on a line unique to its site.

# 7e. Nounset re-enabled immediately before the bootstrap source → the shell dies again at rc 1.
# That source runs FIRST, so it is the one that fires; mutating `require_lib` could not, because
# the double-source guard means its `.` never reads the file.
# `.*` STANDS IN FOR `$(dirname "$0")/`, deliberately. A `$` in the MIDDLE of a BRE is literal in
# both dialects, but "literal in both" is a claim about two implementations this suite cannot run
# side by side — and the one time this repo trusted a dialect claim (`\+`), the mutation silently
# stopped mutating on the other runner. The needle is matched exactly by `check_mutate_line`, so
# looseness here is bounded by that, and the pattern carries no `$` except its own anchor.
if check_mutate_line "$gate/precommit-gate.sh" '  . "$(dirname "$0")/lib/common.sh"' \
     's#^  \. ".*lib/common\.sh"$#  set -u; . "$(dirname "$0")/lib/common.sh"#' \
     "mut-gsetu"; then
  run_gate_lib "$UNBOUND"
  eq "$RC" "1" "mut-gsetu: without the relaxation an unbound expansion kills the gate at rc 1 (so 7b can fail)"
  if gate_ran; then bad "mut-gsetu: the gate somehow still ran"; else
    ok "mut-gsetu: …having run nothing at all"; fi
fi
cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"

# 7f. The bootstrap-status override removed → the double-source guard hides the failure, and the
# gate runs on a partially-loaded library. Pins 7c, which nothing else covers: every other broken
# library here fails `require_lib`'s own checks too, so all of them stay green with this line gone.
if check_mutate_line "$gate/precommit-gate.sh" '  [ "${3:-0}" -eq 0 ] || rc="$3"' \
     's#^  \[ "\${3:-0}" -eq 0 \] || rc="\$3"$#  :#' "mut-gbootrc"; then
  run_gate_lib "$TAILCUT"
  hasnt "$OUT" "failed to source" "mut-gbootrc: without the override the guarded re-source hides the failure (so 7c can fail)"
  if gate_ran; then ok "mut-gbootrc: …and the gate DOES run on a partially-loaded library"; else
    bad "mut-gbootrc: the gate did not run, so 7c's did-not-run assertion is not what this pins"; fi
fi
cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"

# 7g. The bootstrap's function probe reverted to the unconditional call → `command not found`
# returns. This is what makes 7d's quiet-bootstrap assertion mean something: the gate exits 2
# either way, so nothing else in this suite would notice the regression.
if check_mutate_line "$gate/precommit-gate.sh" '  command -v adb_require_bash >/dev/null 2>&1 && adb_require_bash "$@"' \
     's#^  command -v adb_require_bash .*$#  adb_require_bash "$@"#' "mut-gfloorprobe"; then
  run_gate_lib "$STUB"
  has "$OUT" "command not found" "mut-gfloorprobe: without the probe the bootstrap DOES call a missing function (so 7d can fail)"
fi
# RESTORED, AND CONFIRMED. Every case from 8 on runs against this copy, so a failed restore would
# leave them measuring a mutated gate and reporting whatever that produced under their own names.
cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"
if cmp -s "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"; then ok; else
  bad "global gate: the mutated gate copy was not restored — every case after this one is unreliable"; fi
rm -f "$repo/agents.toml" "$repo/redgate.sh" "$repo/RAN"

# 8. project-local gate present → the global gate RUNS it, never touching its own libs.
#
# The old version of this case shipped a project gate that just `exit 0`d, so it passed whether the
# global gate EXECUTED that script or merely stepped aside — the two outcomes are identical at the
# exit code, and stepping aside means enforcement silently off (#240). Every case below is
# therefore written so that "it ran" is observable.
set_libs none; on_feature_change
mkdir -p "$repo/.claude/scripts"
marker="$repo/.claude/ran"

# 8a. it actually runs — proven by a side effect, not by an exit code it shares with not-running.
rm -f "$marker"
printf '#!/usr/bin/env bash\n: > "%s"\nexit 0\n' "$marker" > "$repo/.claude/scripts/precommit-gate.sh"
chmod +x "$repo/.claude/scripts/precommit-gate.sh"
run_gate
eq "$RC" "0" "project-local gate → global gate exits with the project gate's status (0)"
if [ -f "$marker" ]; then ok "project-local gate is EXECUTED, not merely deferred to"; else
  bad "project-local gate was never run — the global gate stepped aside and nothing gated"; fi

# 8b. a project gate that BLOCKS must still block. If the global gate only stepped aside, a repo
# whose own gate says "do not stop" would end its turn anyway — enforcement inverted.
printf '#!/usr/bin/env bash\nexit 2\n' > "$repo/.claude/scripts/precommit-gate.sh"
chmod +x "$repo/.claude/scripts/precommit-gate.sh"
run_gate
eq "$RC" "2" "a blocking project gate still blocks the stop (status propagates)"

# 8c. a project gate that is not executable is still run (chmod +x is easy to forget).
rm -f "$marker"
printf '#!/usr/bin/env bash\n: > "%s"\nexit 0\n' "$marker" > "$repo/.claude/scripts/precommit-gate.sh"
chmod -x "$repo/.claude/scripts/precommit-gate.sh"
run_gate
eq "$RC" "0" "a non-executable project gate does not fail the hook"
if [ -f "$marker" ]; then ok "a non-executable project gate is still run (via bash)"; else
  bad "a non-executable project gate was skipped — gating silently off"; fi

rm -rf "$repo/.claude"

# --- session ownership: one checkout, two sessions (#241) --------------------
# git state carries no session identity, so this gate used to run the full suite over ANOTHER
# session's mid-edit tree at every turn-end — and, because a red gate exits 2, could block a
# bystander's turn on work it did not write. The suppression is narrow ON PURPOSE: it fires only
# on positive proof (a run marker for THIS branch owned by a DIFFERENT session), because a gate
# that stops running is indistinguishable from one that passed (#35).
#
# Every case uses a gate that BOTH marks and FAILS, so "did it run?" is observable twice over —
# once by the marker file, once by the exit status. A gate that merely `exit 0`d would look
# identical whether it ran or was skipped, which is precisely the blind spot case 8 was rewritten
# to remove.
set_libs both
gate_ran="$repo/gate-ran"
arm_failing_gate() {
  rm -f "$gate_ran"
  printf '[gates]\ntest = "touch gate-ran; exit 1"\n' > "$repo/agents.toml"
}
gate_executed() { [ -f "$gate_ran" ]; }

# 9. The OWNING session is gated exactly as before — ownership narrows WHO is spared, it never
#    disarms the gate for the session actually doing the work.
on_feature_change; arm_failing_gate; write_marker feat "$SID_MINE"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "own-owner marker → still blocks (ownership must not disarm the writer's own gate)"
if gate_executed; then ok; else bad "own-owner marker → the gate must still RUN"; fi

# 10. A FOREIGN owner on this branch → not blocked, and the gate never runs. [#241 core]
on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "0" "foreign-owner marker → the bystander's turn is NOT blocked"
if gate_executed; then bad "foreign-owner marker → the gate must not RUN at all"; else ok; fi
has "$OUT" "another session" "foreign-owner skip is REPORTED, never silent"

# 11. A foreign marker on a DIFFERENT branch must not suppress this one. Otherwise one unrelated
#     parked run becomes a checkout-wide bypass of every future gate.
on_feature_change; arm_failing_gate; write_marker some-other-branch "$SID_OTHER"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "foreign marker on ANOTHER branch → this branch is still gated"
if gate_executed; then ok; else bad "foreign marker on another branch → the gate must still RUN"; fi

# 12. Every unknown keeps today's behavior. These are the cases where suppressing would quietly
#     turn the gate into an advisory for nearly every ordinary dirty tree.
on_feature_change; arm_failing_gate; clear_marker; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "no marker → unchanged (runs and blocks)"
if gate_executed; then ok; else bad "no marker → the gate must actually RUN, not just return 2"; fi

on_feature_change; arm_failing_gate; write_marker feat ""; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "ownerless marker → unchanged (runs and blocks)"
if gate_executed; then ok; else bad "ownerless marker → the gate must actually RUN, not just return 2"; fi

on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"; GATE_SESSION=""; run_gate
eq "$RC" "2" "no CLAUDE_CODE_SESSION_ID → cannot identify myself → runs and blocks"
if gate_executed; then ok; else bad "no session id → the gate must actually RUN, not just return 2"; fi

on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
printf '{not valid json' > "$marker_file"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "malformed marker → runs and blocks (never a universal bypass)"
if gate_executed; then ok; else bad "malformed marker → the gate must actually RUN, not just return 2"; fi
hasnt "$OUT" "another session" "malformed marker → no bogus foreign-owner claim"

on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
printf '' > "$marker_file"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "empty marker file → runs and blocks"
if gate_executed; then ok; else bad "empty marker file → the gate must actually RUN, not just return 2"; fi

# 12b. A NEWLINE INSIDE A FIELD must not re-aim the ownership decode. Both directions were live
#      bugs in the first cut of this gate, and both failed toward SUPPRESSION — the gate turning
#      itself off, which is the one direction that must never happen by accident:
#        owner  = "AAAA\nBBBB" → decoded owner "AAAA", a truncation that is not my id
#        branch = "<branch>\nevil" → the branch still MATCHED and the real owner was replaced by
#                 "evil", the second line of the branch
#      Same class implement-issue-gate.sh pins for its own decode (#180).
on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
jq -n --arg o "$SID_MINE" '{branch:"feat", issue:"240", phase:"x", owner:($o + "\nBBBB")}' > "$marker_file"
GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "newline in .owner → decode must not truncate my own id into a foreign one"
if gate_executed; then ok; else bad "newline in .owner → the gate must actually RUN, not just return 2"; fi

on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
jq -n --arg b "feat" '{branch:($b + "\n" + $b), issue:"240", phase:"x", owner:"someone-else"}' > "$marker_file"
GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "newline in .branch → must not match the current branch on its first line"
if gate_executed; then ok; else bad "newline in .branch → the gate must actually RUN, not just return 2"; fi

# 12c. A NON-STRING owner is corruption, not a second session. `@tsv` renders a JSON number
#      happily, so `"owner": 123` decoded to the well-formed value "123", differed from this
#      session's id, and SUPPRESSED the gate. A charset test cannot catch it — a real session id
#      contains digits — so the type is checked in jq instead.
for bad_owner in '123' 'true' '["a"]' '{"a":1}' 'null'; do
  on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
  jq -n --argjson o "$bad_owner" '{branch:"feat", issue:"240", phase:"x", owner:$o}' > "$marker_file"
  GATE_SESSION="$SID_MINE"; run_gate
  eq "$RC" "2" "non-string owner ($bad_owner) → corruption is not proof of another session"
  if gate_executed; then ok; else bad "non-string owner ($bad_owner) → the gate must actually RUN"; fi
done
# …and a non-string BRANCH likewise cannot be trusted to match.
on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
jq -n '{branch:42, issue:"240", phase:"x", owner:"someone-else"}' > "$marker_file"
GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "non-string branch → enforce"
if gate_executed; then ok; else bad "non-string branch → the gate must actually RUN, not just return 2"; fi

# 12f. A MALFORMED CURRENT identity must not be accepted as "me". The grammar was applied only to
#      the marker's owner, so a contaminated CLAUDE_CODE_SESSION_ID was taken as this session's id,
#      compared unequal against a perfectly valid marker owner, and read as PROOF OF ANOTHER
#      SESSION — suppressing every gate at the moment our own identity was in fact unknown. Both
#      sides of the comparison now go through the same check.
for bad_sid in 'not a session id' 'MINE;rm -rf /' 'MINE
BBBB' 'sid$(touch x)'; do
  on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"
  GATE_SESSION="$bad_sid"; run_gate
  eq "$RC" "2" "malformed CLAUDE_CODE_SESSION_ID → identity unknown → runs and blocks"
  if gate_executed; then ok; else bad "malformed session id → the gate must actually RUN"; fi
done
GATE_SESSION=""

# 12g. A COMPLETED run is not a live run. The workflow writes `phase=complete` at close-out, and
#      the marker can outlive it — the owning session may exit before its Stop hook removes it, and
#      that hook fail-closes on unverifiable PR state and KEEPS the marker. Nothing else can clear
#      it (implement-issue-gate.sh leaves a foreign marker byte-identical, #180), so without this
#      every other session on the branch would skip every gate until the age bound expired.
on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
jq -n --arg o "$SID_OTHER" '{branch:"feat", issue:"240", phase:"complete", owner:$o}' > "$marker_file"
GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "phase=complete foreign marker → a finished run is not a live one → runs and blocks"
if gate_executed; then ok; else bad "phase=complete marker → the gate must actually RUN"; fi
hasnt "$OUT" "another session" "phase=complete → no claim that a run holds the branch"

# …while a marker still IN FLIGHT continues to spare the bystander.
for live_phase in branched implemented committed code_reviewed pushed pr_opened; do
  on_feature_change; arm_failing_gate; mkdir -p "$repo/.claude/state"
  jq -n --arg o "$SID_OTHER" --arg p "$live_phase" \
    '{branch:"feat", issue:"240", phase:$p, owner:$o}' > "$marker_file"
  GATE_SESSION="$SID_MINE"; run_gate
  eq "$RC" "0" "phase=$live_phase foreign marker → still a live run → spared"
done

# 12e. A STALE marker is not evidence of a live run. Without a bound, a crashed /implement-issue
#      run leaves its marker behind and every later session on that branch is un-gated forever —
#      and in a repo that also declares its gates `full`, turn-end enforcement would be gone
#      entirely. The bound is `ADB_MARKER_STALE_SECS` (default 9000, matching #202's run-claim
#      lease); the fixture sets it to 1 and ages the marker rather than waiting.
on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"
OUT="$(cd "$repo" && ADB_MARKER_STALE_SECS=99999 CLAUDE_CODE_SESSION_ID="$SID_MINE" \
      bash "$gate/precommit-gate.sh" </dev/null 2>&1)"; RC=$?
eq "$RC" "0" "fresh foreign marker → still spared (the bound has not fired)"

on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"
touch -t 202001010000 "$marker_file"          # backdate well past any bound
OUT="$(cd "$repo" && CLAUDE_CODE_SESSION_ID="$SID_MINE" \
      bash "$gate/precommit-gate.sh" </dev/null 2>&1)"; RC=$?
eq "$RC" "2" "STALE foreign marker → no longer proof of a live run → runs and blocks"
if gate_executed; then ok; else bad "stale foreign marker → the gate must actually RUN"; fi
hasnt "$OUT" "another session" "stale foreign marker → no claim that a run holds the branch"

# 12d. NO `jq` → ownership is unknowable → enforce. Every other ownership fixture REQUIRES jq to
#      build its marker, and CI now installs it explicitly, so nothing here exercised the
#      `command -v jq` branch: a mutation that SUPPRESSED on a missing jq would have passed the
#      whole suite. Proving it needs a PATH that genuinely lacks jq — shadowing does not work,
#      because `command -v` falls straight through a directory, a non-executable file or a broken
#      symlink to the real binary further along PATH. Hence a symlink farm of exactly the tools
#      the gate and the gate-runner need, with jq deliberately absent.
nojq="$work/nojq"; mkdir -p "$nojq"
for _t in git sh bash sed awk sort date mktemp rm tail cat dirname touch true false uname grep tr head env; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$nojq/$_t"
done
if [ -e "$nojq/jq" ]; then bad "12d fixture is broken: jq leaked into the no-jq farm"; else
  on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"
  OUT="$(cd "$repo" && PATH="$nojq" CLAUDE_CODE_SESSION_ID="$SID_MINE" \
        bash "$gate/precommit-gate.sh" </dev/null 2>&1)"; RC=$?
  eq "$RC" "2" "no jq → cannot read the marker → runs and blocks (never spared)"
  if gate_executed; then ok; else bad "no jq → the gate must actually RUN, not just return 2"; fi
fi

# 13. A BROKEN INSTALL must not be silently spared by a planted marker. With common.sh absent the
#     shared comparator does not exist, so ownership is unknowable — and the gate must fall
#     through to its fail-loud path (#35) rather than treat "I cannot tell" as "not mine".
#     Without this, breaking the install and leaving any foreign marker would turn the gate off.
#
#     (There is deliberately no "clean tree" case here: `arm_failing_gate` writes an UNTRACKED
#     agents.toml, so a tree carrying a configured gate is by construction not clean. An earlier
#     draft asserted exactly that and passed only because the foreign marker suppressed the run —
#     it was measuring the ownership path while claiming to measure the no-changes path. Cases 1-2
#     already cover the genuine clean-tree and default-branch no-ops.)
set_libs nocommon
on_feature_change; arm_failing_gate; write_marker feat "$SID_OTHER"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "foreign marker + missing common.sh → still FAILS LOUD (a broken install is not a bypass)"
if is_fatal; then ok; else bad "foreign marker + missing common.sh → message must be FATAL, got: $OUT"; fi
set_libs both

# 14. THE CHECK MUST PRECEDE THE PROJECT-GATE HAND-OFF. The second observed incident reported
#     `build-drift FAIL` — a check name in THIS repo's own project gate — so an ownership test
#     placed after the `exec` would miss the exact case #241 documents, in every repo that uses
#     the documented escape hatch.
proj_ran="$repo/.claude/proj-ran"
stdin_seen="$repo/.claude/stdin-seen"
# Armed AFTER every on_feature_change, never before: that helper runs `git clean -qfd`, which
# deletes the untracked .claude/ tree along with everything in it. A project gate written
# earlier is simply gone by the time the gate looks for it — and the case would then "pass"
# for the wrong reason, proving only that a missing script does not run.
arm_project_gate() {  # <exit-code>
  mkdir -p "$repo/.claude/scripts"
  printf '#!/usr/bin/env bash\n: > "%s"\nexit %s\n' "$proj_ran" "$1" > "$repo/.claude/scripts/precommit-gate.sh"
  chmod +x "$repo/.claude/scripts/precommit-gate.sh"
  rm -f "$proj_ran"
}

on_feature_change; arm_failing_gate; arm_project_gate 2
write_marker feat "$SID_OTHER"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "0" "foreign owner → not blocked even when the repo ships its OWN gate"
if [ -f "$proj_ran" ]; then bad "foreign owner → the PROJECT gate must not run either (check must precede the exec)"; else ok; fi

# …and the owning session still reaches its project gate, so the ownership check narrows the
# hand-off rather than replacing it.
on_feature_change; arm_failing_gate; arm_project_gate 2
write_marker feat "$SID_MINE"; GATE_SESSION="$SID_MINE"; run_gate
eq "$RC" "2" "own owner → the project gate still runs and can still block"
if [ -f "$proj_ran" ]; then ok; else bad "own owner → the project gate must still be EXECUTED"; fi

# 15. The gate must not consume the hook payload on stdin. It `exec`s the project gate, which
#     inherits that fd, and docs/per-project-overrides.md documents the inherited payload as part
#     of the contract — so identity is read from the environment ONLY. This project gate reads
#     stdin and records what arrived.
#     A MARKER MUST BE PRESENT for this case to bite. The ownership check short-circuits on a
#     missing marker before it ever looks for an identity, so with no marker even a
#     stdin-consuming implementation would leave the payload untouched and this case would pass
#     while proving nothing. An OWN-owner marker drives the check all the way through identity
#     resolution and still lets the run proceed to the hand-off.
printf '{"session_id":"%s","hook_event_name":"Stop"}\n' "$SID_MINE" > "$work/payload.json"
on_feature_change; arm_failing_gate; write_marker feat "$SID_MINE"
mkdir -p "$repo/.claude/scripts"
printf '#!/usr/bin/env bash\nIFS= read -r line || true\nprintf "%%s" "$line" > "%s"\nexit 0\n' "$stdin_seen" \
  > "$repo/.claude/scripts/precommit-gate.sh"
chmod +x "$repo/.claude/scripts/precommit-gate.sh"
rm -f "$stdin_seen"
GATE_SESSION="$SID_MINE"; GATE_STDIN="$work/payload.json"; run_gate
GATE_STDIN="/dev/null"
has "$(cat "$stdin_seen" 2>/dev/null || printf '')" "hook_event_name" \
    "the hook payload reaches the project gate intact (ownership must not eat stdin)"

rm -rf "$repo/.claude" "$repo/agents.toml" "$gate_ran"

# 16. STRUCTURAL: exactly one ownership comparison in the tree (#241's own acceptance criterion).
# Every case above is behavioural, so re-introducing a private hand-rolled comparator in a second
# gate would pass all of them while recreating precisely the drift the promotion removed. Only a
# structural assertion can see that, so it is made here rather than assumed.
defs="$(grep -rlE '^adb_owners_compatible\(\)' "$ROOT/scripts" "$ROOT/agents" 2>/dev/null | sort)"
eq "$defs" "$ROOT/scripts/lib/common.sh" "ownership comparator is defined in exactly one file"

# The three-way comparison itself must not be re-spelled anywhere else. `owners_compatible` may
# exist as a thin alias, but its body has to DELEGATE — a copy of the logic is what this pins.
alias_body="$(grep -cE '^[[:space:]]*owners_compatible\(\)[[:space:]]*\{[[:space:]]*adb_owners_compatible' \
              "$ROOT/agents/claude/scripts/implement-issue-gate.sh")"
eq "$alias_body" "1" "implement-issue-gate.sh DELEGATES to adb_owners_compatible (no second comparison)"

# The comparison's own shape must appear nowhere else. Anchoring on the two `-n` guards that make
# it a THREE-WAY answer — the part a re-implementation would have to reproduce and the part most
# likely to be got subtly wrong — rather than on the final equality, which is ordinary shell.
copies="$(grep -rlE '\[ -n "\$a" \] \|\| return 0' "$ROOT/scripts" "$ROOT/agents" 2>/dev/null | sort)"
eq "$copies" "$ROOT/scripts/lib/common.sh" "the three-way ownership comparison is spelled in exactly one file"

# --- 17. THIS REPOSITORY'S OWN PROJECT GATE (#299) ---------------------------
# Everything above drives the GLOBAL gate, and every project-gate case there substitutes a
# purpose-built stub — a marker-and-exit-0, an exit-2, a parameterized exit code, a stdin recorder.
# Each is the right instrument for what it measures (the HAND-OFF), and none of them is this
# repository's gate. So the fast subset D25 actually ships — changed-file shellcheck, build-drift,
# workflow-render, practice-index, fact-drift — had no fixture at all: the gate that runs at the end
# of EVERY turn in this repo could regress and nothing here would notice.
#
# THE REAL SCRIPT, NOT A STUB, AND REAL CHECKS, NOT STUBBED ONES. The fixture is a throwaway COPY
# of this worktree re-`git init`ed as `main`, so `.claude/scripts/precommit-gate.sh` resolves its
# library at `$(dirname "$0")/../../scripts/lib/common.sh` and shells out to `scripts/build.sh` and
# the three `check-*.sh` exactly as it does in production. A stubbed subset would test this suite's
# idea of the gate rather than the gate.
#
# NOTHING HERE TOUCHES THE TRACKED TREE. Every mutation — a deleted library, an edited practice
# file, a gate reverted to its pre-#299 shape — lands inside `$work`, and the fixture's own git is
# what restores it between cases (the negative-testing rule in base/practices/self-review.md).
fx="$work/projrepo"

# The clean baseline every case starts from. `git checkout -- .` is the destructive form the
# practices warn about, and it is correct HERE and only here: `$fx` is a throwaway `mktemp -d`
# fixture whose every byte came from a copy, so there is no unstaged work in it to lose.
# DELEGATES to check-lib.sh's shared fixture-identity wrapper rather than re-spelling its `-c`
# flags; this suite already sources it, and a private copy of the same identity is how a signing
# default silently starts applying to one suite's fixtures and not another's.
fx_git()   { check_git "$fx" "$@"; }
# A FAILED RESET IS REPORTED, never swallowed. Every case below deliberately breaks the fixture and
# relies on this to put it back; a reset that quietly failed would leave the NEXT case running
# against a library it thinks it restored, and that case would then pass or fail for a reason
# unrelated to its name — a suite silently measuring the wrong thing, which is the exact failure
# shape everything here exists to catch.
fx_reset() {
  fx_git checkout -q -- . && fx_git clean -qfd >/dev/null 2>&1 && return 0
  bad "project gate: could not restore the fixture — every case after this one is now unreliable"
  return 1
}

# Run the REAL project gate with CWD inside the fixture; sets PRC and POUT.
# stdin is pinned to /dev/null for the reason run_gate above pins it: the gate must not depend on
# a hook payload, and a case that let the terminal's stdin through would hide it if it did.
fx_gate() { POUT="$(cd "$fx" && bash .claude/scripts/precommit-gate.sh </dev/null 2>&1)"; PRC=$?; }

# fx_mutate <exact-line> <sed-script> <label> — revert one line of the FIXTURE's gate to a
# superseded shape, through check-lib.sh's shared harness. Only the file is bound here; the
# before/after discipline that makes a mutation a proof rather than a decoration lives in one home.
fx_mutate() { check_mutate_line "$fx/.claude/scripts/precommit-gate.sh" "$@"; }

fx_setup() {
  check_copy_worktree "$ROOT" "$fx" || return 1
  # The run-state directory is per-run data, and carrying it in would let a LIVE /implement-issue
  # marker reach case 17h's global gate and suppress the very hand-off that case exists to observe.
  # CONFIRMED GONE, not merely asked to go: an `rm -rf` that failed would leave 17h silently
  # measuring a suppression instead of a hand-off, and reporting a pass for it.
  rm -rf "$fx/.claude/state"
  [ ! -e "$fx/.claude/state" ] || return 1
  git init -q "$fx" || return 1
  fx_git symbolic-ref HEAD refs/heads/main || return 1
  # Render before the baseline commit, so the fixture is self-consistent no matter what state the
  # developer's own worktree is in. Without this, running this suite with an un-rebuilt `base/`
  # would fail case 17a — reporting a gate defect for a stale checkout.
  ( cd "$fx" && bash scripts/build.sh ) >/dev/null 2>&1 || return 1
  fx_git add -A || return 1
  fx_git commit -q -m seed || return 1
  # A feature branch carrying a COMMITTED delta. Both halves are load-bearing: on the default
  # branch the gate no-ops at the branch test, and with no delta at all it no-ops at the empty
  # change set — either way it would exit 0 having run nothing, and a "clean tree → 0" case built
  # that way passes while proving the gate never executed a single check.
  fx_git checkout -q -b feat || return 1
  printf 'a committed delta, so the gate has something to look at\n' > "$fx/fixture-delta.txt"
  fx_git add fixture-delta.txt || return 1
  fx_git commit -q -m delta || return 1
}

if fx_setup; then
  # 17a. The precondition the next case rests on, asserted rather than assumed.
  #
  # THE COMMAND'S STATUS IS CHECKED SEPARATELY FROM ITS OUTPUT. `eq "$(fx_git status --porcelain)"
  # ""` discards the status, and a git that FAILED prints nothing on stdout — indistinguishable
  # from a clean tree. The precondition would then be satisfied precisely when it could not be
  # evaluated.
  fx_status="$(fx_git status --porcelain)"; fx_status_rc=$?
  eq "$fx_status_rc" "0" "project gate: the fixture's status is readable at all"
  eq "$fx_status" ""     "project gate: the fixture's working tree is clean"
  # Named, not merely non-empty: `hasnt "$x" ""` can never pass (every string contains the empty
  # string), and an emptiness test written that way is a precondition that always reports failure.
  has "$(fx_git diff --name-only main...HEAD)" "fixture-delta.txt" \
      "project gate: the fixture branch carries a committed delta"

  # 17b. Clean tree + feature branch + a delta → exit 0, with all four checks OBSERVED running.
  # The exit code alone cannot tell "every check passed" from "the gate no-opped and ran nothing",
  # which is the blind spot case 8 was rewritten to remove. The per-check PASS lines can.
  # ONE assertion carrying the whole diagnostic, rather than an `eq` plus a `bad`: those would
  # count the same defect twice, and the count is what check_summary reports.
  fx_gate
  if [ "$PRC" -eq 0 ]; then ok; else
    bad "project gate: clean tree on a feature branch → want exit 0, got $PRC — the gate reported: $POUT"
  fi
  has "$POUT" "build-drift      PASS"    "project gate: build-drift actually RAN and passed"
  has "$POUT" "workflow-render  PASS"    "project gate: workflow-render actually RAN and passed"
  has "$POUT" "practice-index   PASS"    "project gate: practice-index actually RAN and passed"
  has "$POUT" "fact-drift       PASS"    "project gate: fact-drift actually RAN and passed"

  # 17c. A REAL red check → exit 2, attributed by name. Editing a practice file makes `build.sh`
  # regenerate the three root docs, which is what the gate's own build-drift check compares — so
  # this reddens the production check rather than a stand-in for it, and reddens exactly one.
  printf '\nA sentence that exists only inside the throwaway fixture.\n' >> "$fx/base/practices/self-review.md"
  fx_gate
  eq "$PRC" "2" "project gate: a red check → exit 2 (blocks the stop)"
  has "$POUT" "build-drift      FAIL" "project gate: the failing check is named, not just counted"
  has "$POUT" "blocking stop"         "project gate: the block is explained on the way out"
  # THE LAST CHECK, not a middle one. `build-drift` is first and `fact-drift` is last, so a gate
  # that aborted straight after `practice-index` would satisfy an assertion naming that check while
  # flatly contradicting the claim being made. Only the final line proves the subset ran to the end.
  has "$POUT" "fact-drift       PASS" "project gate: one red check does not abort the rest of the subset"
  fx_reset

  # 17d. common.sh MISSING → FAIL LOUD (exit 2), not the silent exit 0 this shipped with. [#299 core]
  rm -f "$fx/scripts/lib/common.sh"
  fx_gate
  eq "$PRC" "2" "project gate: common.sh missing → exit 2 (fail loud, never a silent pass)"
  has "$POUT" "FATAL" "project gate: common.sh missing → the message is FATAL (loud)"
  hasnt "$POUT" "build-drift" "project gate: a broken library stops the run BEFORE any check pretends to have run"

  # 17e. …and loud on the DEFAULT branch too. A broken install is not an unfamiliar repo, so the
  # library check has to precede the branch no-op — exactly as case 6 requires of the global gate.
  #
  # THE CHECKOUT IS ASSERTED, because this case is the one whose fixture failure is invisible: the
  # missing-library gate returns 2 on EITHER branch, so a checkout that silently failed would leave
  # the fixture on `feat` and this case would report that the default-branch path passed without
  # ever having exercised it.
  fx_git checkout -q main; eq "$?" "0" "project gate: the fixture reached the default branch"
  eq "$(fx_git rev-parse --abbrev-ref HEAD)" "main" "project gate: …and is demonstrably on it"
  fx_gate
  eq "$PRC" "2" "project gate: common.sh missing + default branch → exit 2 (loud everywhere)"
  fx_git checkout -q feat; eq "$?" "0" "project gate: the fixture returned to the feature branch"
  fx_reset

  # 17f. common.sh PRESENT but TRUNCATED → still exit 2. This is the case the function probe exists
  # for and the one a `. lib || …` test cannot see: the file sources cleanly, exits 0, and defines
  # nothing at all.
  printf '# truncated by a partial write\n' > "$fx/scripts/lib/common.sh"
  fx_gate
  eq "$PRC" "2" "project gate: truncated common.sh → exit 2 (the source succeeded; the library is still gone)"
  has "$POUT" "adb_default_branch" "project gate: the truncated-library message names the helper that is missing"
  hasnt "$POUT" "build-drift" "project gate: a truncated library also stops before any check runs"
  # …AND THE FLOOR BLOCK STAYS QUIET. This is the assertion that makes the second-site fix real: the
  # bootstrap tested only that common.sh existed, so against this same input it called
  # `adb_require_bash` as an undefined command. The exit code cannot see that — the load below
  # supplies the 2 either way — so without this line the probe could be reverted and all of case
  # 17f would stay green.
  hasnt "$POUT" "command not found" "project gate: a truncated library does not make the floor bootstrap call a missing function"
  fx_reset

  # 17f2. common.sh present and NON-EMPTY but UNSOURCEABLE — a syntax error from a partial write.
  # A third distinct failure, and the only one that exercises the source-STATUS branch: the file
  # test passes, the source returns non-zero, and no function probe is ever reached. Without it that
  # branch has never been observed blocking anything.
  printf 'adb_default_branch() {\n' > "$fx/scripts/lib/common.sh"
  fx_gate
  eq "$PRC" "2" "project gate: unsourceable common.sh → exit 2"
  has "$POUT" "failed to source" "project gate: …and the message distinguishes it from a missing or truncated file"
  hasnt "$POUT" "build-drift" "project gate: an unsourceable library also stops before any check runs"
  fx_reset

  # 17f3. TRUNCATED AFTER THE DOUBLE-SOURCE GUARD — the case the other three cannot reach, and the
  # one that made the source-status check vestigial in production. `common.sh` opens with
  # `_ADB_COMMON_SH_LOADED` (:35-38), so a file that loads far enough to set the guard and define
  # what the gate needs, and only THEN hits a syntax error, fails the bootstrap and makes the
  # gate's own `.` a no-op returning 0. Both probes then pass on functions the partial load
  # defined, and the gate ran the entire subset with the promised FATAL never firing.
  #
  # Appending an unterminated function body is exactly that shape: everything before it executes.
  printf '\nadb_truncated_tail() {\n' >> "$fx/scripts/lib/common.sh"
  fx_gate
  eq "$PRC" "2" "project gate: common.sh truncated after the double-source guard → exit 2"
  has "$POUT" "failed to source" "project gate: …reported as a load failure, not incidentally by some other check"
  hasnt "$POUT" "build-drift" "project gate: …and the subset never runs on a partially-loaded library"
  fx_reset

  # 17g. An unbound expansion while the library loads must not DECIDE anything. Under `set -u` it
  # killed the shell outright at rc 1 — neither this gate's blocking 2 nor a pass, and catchable by
  # no `||`, because the shell is gone before the next word is read. With the load relaxed, the
  # library still defines everything, so the honest answer is the ordinary green one.
  printf '\n: "${ADB_CHECK_DEFINITELY_UNSET_XYZ}"\n' >> "$fx/scripts/lib/common.sh"
  fx_gate
  eq "$PRC" "0" "project gate: an unbound expansion at load time does not decide the gate's verdict"
  # The LAST check again, for the same reason 17c names it: exit 0 plus the FIRST check's PASS is
  # equally consistent with a gate that stopped right after it.
  has "$POUT" "fact-drift       PASS" "project gate: …and the subset still runs to completion"
  fx_reset

  # 17h. THE PRODUCTION PATH. In real life nothing invokes the project gate directly — the global
  # gate `exec`s it (#240). Asserting an exit code here would prove nothing, because "handed off"
  # and "stepped aside" share it; the project gate's OWN check names are a string the global gate
  # cannot produce, so they are what distinguishes the two.
  handoff="$work/handoff"; mkdir -p "$handoff/lib"
  cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$handoff/precommit-gate.sh"
  cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/project-gates.sh" "$handoff/lib/"
  HOUT="$(cd "$fx" && bash "$handoff/precommit-gate.sh" </dev/null 2>&1)"; HRC=$?
  eq "$HRC" "0" "project gate: the global gate exits with the project gate's status"
  has "$HOUT" "build-drift      PASS" "project gate: the global gate reaches THIS repo's real gate, not a stub"

  # --- 17i-17k. The three assertions above are guards, so each is OBSERVED FAILING -------------
  # A guard over a hazard nothing triggers reports a clean run either way. Each mutation returns
  # ONE line of the fixture's gate to its pre-#299 shape and requires the case above it to come
  # back with the old, wrong answer — which is what proves the case can answer wrong at all.

  # 17i. The missing-library bypass restored → the silent exit 0 that shipped.
  if fx_mutate '[ -f "$lib_common" ] || gate_fail_loud "shared library not found: scripts/lib/common.sh"' \
       's#^\[ -f "\$lib_common" \] || gate_fail_loud .*$#[ -f "$lib_common" ] || exit 0#' \
       "mut-missing"; then
    rm -f "$fx/scripts/lib/common.sh"
    fx_gate
    eq "$PRC" "0" "mut-missing: the pre-#299 gate DOES silently pass on a missing library (so 17d can fail)"
  fi
  fx_reset

  # 17j. The corrupt-library bypass restored → a truncated library silently passes too. Mutated
  # separately from 17i because they are two different bypasses on two different lines, and one
  # blanket edit could not tell which of them 17d and 17f each depend on.
  if fx_mutate '  || gate_fail_loud "scripts/lib/common.sh loaded but did not define adb_default_branch (corrupt or truncated)"' \
       's#^  || gate_fail_loud "scripts/lib/common.sh loaded.*$#  || exit 0#' \
       "mut-corrupt"; then
    printf '# truncated by a partial write\n' > "$fx/scripts/lib/common.sh"
    fx_gate
    eq "$PRC" "0" "mut-corrupt: the pre-#299 gate DOES silently pass on a truncated library (so 17f can fail)"
  fi
  fx_reset

  # 17k. The floor block's `set +u` removed → the unbound expansion kills the gate again. The
  # INDENTED spelling is the floor block's, and it is the one that fires: that source runs first,
  # so the shell is already gone before the load below it is reached.
  # `[+]`, NOT `\+`. The two BREs disagree about the escape and only one of them is a no-op: BSD
  # reads `\+` as a literal plus, GNU reads it as the one-or-more QUANTIFIER on the preceding space,
  # so on Linux this pattern meant "set, one-or-more spaces, u" and matched nothing at all. The
  # mutation silently stopped mutating, which is precisely the state `check_mutate_line`'s
  # post-condition exists to refuse — it caught this on CI after a local green. A bracket expression
  # holding one ordinary character is the same in both, so it needs no escape and carries no dialect.
  if fx_mutate '  set +u' 's#^  set [+]u$#  :#' "mut-setu"; then
    printf '\n: "${ADB_CHECK_DEFINITELY_UNSET_XYZ}"\n' >> "$fx/scripts/lib/common.sh"
    fx_gate
    eq "$PRC" "1" "mut-setu: without the relaxation an unbound expansion kills the gate at rc 1 (so 17g can fail)"
    hasnt "$POUT" "build-drift" "mut-setu: …having run nothing at all"
  fi
  fx_reset

  # 17l. The source-STATUS guard removed → an unsourceable library falls through to the function
  # probe, which reports the wrong cause. Distinct from 17i/17j because it is a third bypass on a
  # third line, and 17f2 is the only case that depends on it.
  if fx_mutate '[ "$lib_rc" -eq 0 ] || gate_fail_loud "shared library failed to source: scripts/lib/common.sh"' \
       's#^\[ "\$lib_rc" -eq 0 \] || gate_fail_loud .*$#:#' "mut-srcstatus"; then
    printf 'adb_default_branch() {\n' > "$fx/scripts/lib/common.sh"
    fx_gate
    hasnt "$POUT" "failed to source" "mut-srcstatus: without the status guard the source failure is mis-reported (so 17f2 can fail)"
  fi
  fx_reset

  # 17n. The bootstrap-status override removed → the double-source guard hides the failure again,
  # and the gate runs the whole subset on a partially-loaded library. Pins 17f3, which no other
  # assertion here covers: every other broken-library case fails the FIRST load too, so all of them
  # stay green with this line gone.
  if fx_mutate '[ "${boot_rc:-0}" -eq 0 ] || lib_rc="$boot_rc"' \
       's#^\[ "\${boot_rc:-0}" -eq 0 \] || lib_rc="\$boot_rc"$#:#' "mut-bootrc"; then
    printf '\nadb_truncated_tail() {\n' >> "$fx/scripts/lib/common.sh"
    fx_gate
    hasnt "$POUT" "failed to source" "mut-bootrc: without the override the guarded re-source hides the failure (so 17f3 can fail)"
    has "$POUT" "build-drift" "mut-bootrc: …and the subset runs on a partially-loaded library"
  fi
  fx_reset

  # 17m. The floor block's function probe reverted to the unconditional call → `command not found`
  # returns. This is the mutation that makes 17f's quiet-bootstrap assertion mean something: the
  # gate still exits 2 either way, so nothing else in this suite would notice the regression.
  if fx_mutate '  command -v adb_require_bash >/dev/null 2>&1 && adb_require_bash "$@"' \
       's#^  command -v adb_require_bash .*$#  adb_require_bash "$@"#' "mut-floorprobe"; then
    printf '# truncated by a partial write\n' > "$fx/scripts/lib/common.sh"
    fx_gate
    has "$POUT" "command not found" "mut-floorprobe: without the probe the bootstrap DOES call a missing function (so 17f can fail)"
  fi
  fx_reset
else
  bad "project-gate fixture setup failed — none of the #299 cases ran, which is not a pass"
fi

check_summary "precommit-gate"
