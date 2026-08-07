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

check_summary "precommit-gate"
