#!/usr/bin/env bash
# ai-dev-baseline — behavioral tests for the adoption completion contract and its verifier (#81).
#
# WHY THIS EXISTS, AND WHY IT IS SHAPED LIKE THIS. A verifier's failure mode is SILENCE. Ordinary
# code that breaks throws, returns the wrong value, fails a test; a verifier that breaks PASSES —
# it evaluates zero rungs, matches zero facts, and prints exactly what a clean run prints. So a
# positive-only suite here would be worse than none: it would report that adoption is verified
# while verifying nothing (base/practices/self-review.md, "a new guard is not done until it has
# been observed failing").
#
# The two rules every assertion below is built on:
#
#   1. EVERY RUNG IS DRIVEN TO EVERY RESULT CLASS — met, outstanding, undetermined, N/A — and each
#      asserts a NAMED verdict and exit code, never merely "non-zero". `red` and `indeterminate`
#      are both non-green and mean different things; a test that accepted either would let the
#      two collapse into one without noticing.
#   2. THE FAIL-CLOSED DIRECTION IS ASSERTED EXPLICITLY, because it is the only direction that
#      can ship a broken project. A missing fact, an unreadable one, a malformed record and an
#      empty stdin must each be non-green. Two real defects were caught by exactly these
#      assertions while this was being written, and both were fail-OPEN:
#        - the gate count grepped `status` for `run:`, which that table prints without a colon,
#          so a repo with a real gate counted ZERO and the whole axis reported N/A;
#        - the disposition filter dereferenced `.title` inside `$d | index(…)`, where jq has
#          rebound `.` to the dispositions array; jq aborted, a `2>/dev/null` swallowed it, and
#          the empty output read as "every milestone is dispositioned" for a project with 44
#          issues parked in an undispositioned one.
#      Neither was visible by reading. Both are pinned below.
#
# OFFLINE and HERMETIC. The library never calls gh: `probe` reads the filesystem, `tracker` reads
# a JSON object the caller assembled. That is the whole reason the split exists, and it is what
# lets this suite run on both CI runners with no auth. Every fixture is a `mktemp -d` tree.
# THE TRACKED WORKING TREE IS NEVER MUTATED — not to build a fixture, not to negative-test
# (self-review.md's copy rule).
#
# WHAT THIS SUITE CANNOT PROVE, said plainly rather than implied away:
#   - that a real adoption of one of #81's four surveyed repositories comes out green. Those
#     repos are not here and CI cannot see them; the live acceptance run is manual.
#   - that the tracker FACTS are gathered correctly. This proves what the library does with the
#     facts it is handed; the gh reads that produce them live in the workflow, and their
#     correctness rides on the readers that already own them (roadmap-lib, release-convention,
#     repo-settings), each with its own suite.
#   - that a green contract means the project is GOOD. It means every rung the contract names
#     was met. The contract is a floor.
#
# Usage: bash scripts/check-adopt-readiness.sh             (exit 0 = all pass, 1 = a failure)
#        bash scripts/check-adopt-readiness.sh --mutation  (…and inject each defect, requiring RED)

# bash 5.3 runtime floor (#256) — FIRST, before BOTH `set -u` and the cd, for the reasons
# scripts/check-adopt.sh spells out: $0 is frozen at invocation, and an unbound expansion during
# sourcing is fatal under `set -u` before this script has run a line of its own.
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
AR="$ROOT/scripts/lib/adopt-readiness.sh"
WF="$ROOT/base/workflows/adopt.md"

# Arguments are validated BEFORE the exit guard is armed, so a bad invocation looks like a usage
# error rather than a suite failure.
MUTATE=0
case "${1:-}" in
  --mutation) MUTATE=1 ;;
  "") : ;;
  *) printf 'check-adopt-readiness: unknown argument: %s (expected --mutation, or no argument)\n' "$1" >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary
check_init "check-adopt-readiness"

TAB="$(printf '\t')"
WORK="$(mktemp -d)" || { echo "check-adopt-readiness: FATAL — cannot create a scratch dir" >&2; exit 1; }
check_exit_guard "check-adopt-readiness" "rm -rf \"$WORK\""

# Every probe/receipt call writes its receipt here rather than into a fixture, so no assertion
# depends on a fixture's own .claude/ and the tracked tree is never a candidate.
export ADB_STATE_DIR="$WORK/state"
mkdir -p "$ADB_STATE_DIR"

ar() { bash "$AR" "$@"; }

# A throwaway git repo with a commit, so HEAD resolves (the receipt is keyed by it).
mkrepo() {  # <dir>
  mkdir -p "$1"; git -C "$1" init -q
  printf 'seed\n' > "$1/README.md"; git -C "$1" add README.md
  check_git "$1" commit -qm init
}

# --- 1. the contract is DATA, and it is the single source the verdict reads ----------------------
out="$(ar contract)"
n="$(printf '%s\n' "$out" | grep -c .)"
eq "$n" "12" "contract: 12 rungs"
# Every row must be three tab fields with a legal owner. A malformed row would make `verdict`
# read a rung name of "" and silently accept anything.
bad_rows="$(printf '%s\n' "$out" | awk -F"$TAB" 'NF!=3 || ($2!="agent" && $2!="owner") || $1=="" || $3=="" {print}' | wc -l | tr -d ' ')"
eq "$bad_rows" "0" "contract: every row is <rung>TAB<agent|owner>TAB<title>"
# The rung names must be unique — a duplicate would make `verdict`'s dedup fire against the
# contract itself and die on a perfectly correct caller.
dupes="$(printf '%s\n' "$out" | cut -f1 | sort | uniq -d | wc -l | tr -d ' ')"
eq "$dupes" "0" "contract: rung names are unique"
# The knowledge-map checklist item must NOT be a rung: its issue #33 was closed NOT_PLANNED, and  (adb-claim-ok: #33 was closed NOT_PLANNED — this asserts the ABSENCE of a rung for it; it tracks nothing)
# a rung nothing can ever satisfy is a permanently red contract.
hasnt "$out" "knowledge" "contract: no rung for the NOT_PLANNED knowledge map"
ar contract extra >/dev/null 2>&1; eq $? 2 "contract: rejects arguments"

# --- 2. verdict: the truth table ------------------------------------------------------------------
# One helper, so every row below asserts the SAME two things — the verdict word and the exit code.
# Asserting only the code would let the report drift from the decision; asserting only the word
# would let a caller that branches on `$?` be wrong while the text is right.
all_rungs() { ar contract | cut -f1; }
records() {  # <status> — every rung at one status
  local r; while IFS= read -r r; do printf '%s\t%s\t\n' "$r" "$1"; done < <(all_rungs)
}
verdict_is() {  # <records> <want-word> <want-rc> <label>
  local got rc
  got="$(printf '%s' "$1" | ar verdict)"; rc=$?
  case "$got" in
    *"VERDICT: $2"*) ok ;;
    *) bad "$4: wanted verdict '$2', got: $(printf '%s' "$got" | grep VERDICT || echo '(no VERDICT line)')" ;;
  esac
  eq "$rc" "$3" "$4 (exit code)"
}

verdict_is "$(records ok)"      green         0  "verdict: every rung ok"
verdict_is "$(records na)"      green         0  "verdict: every rung N/A is still green"
verdict_is "$(records todo)"    red          10  "verdict: any todo is red"
verdict_is "$(records unknown)" indeterminate 11 "verdict: unknown-only is indeterminate"

# Mixed: one todo among otherwise-green rungs must be RED, not green. This is the assertion that
# a verdict which ignored its inputs would fail.
mixed="$(records ok | sed "1s/${TAB}ok${TAB}/${TAB}todo${TAB}/")"
verdict_is "$mixed" red 10 "verdict: a single todo among 11 ok rungs is red"

# PRECEDENCE: red outranks indeterminate when both are present. Both withhold ready; only red
# has a deterministic next move.
both="$(records ok | sed "1s/${TAB}ok${TAB}/${TAB}todo${TAB}/;2s/${TAB}ok${TAB}/${TAB}unknown${TAB}/")"
verdict_is "$both" red 10 "verdict: red outranks indeterminate"

# THE FAIL-CLOSED CORE. Empty stdin means nothing was reported, and the answer must not be green.
verdict_is "" indeterminate 11 "verdict: EMPTY stdin is indeterminate, never green"

# A rung MISSING from stdin is unknown, not skipped. This is what stops a caller that forgot a
# read from shrinking the contract to whatever it remembered — a shrunken contract is trivially
# green, which is the single most dangerous way this file could be wrong.
short="$(records ok | grep -v '^gates')"
verdict_is "$short" indeterminate 11 "verdict: a rung nobody reported is unknown, not absent"
out="$(printf '%s' "$short" | ar verdict)"
has "$out" "11 of 12 rungs evaluated" "verdict: the evaluated count exposes the missing rung"
has "$out" "not reported" "verdict: the missing rung is named as unreported"

# THE COUNT IS THE ANTI-SILENCE DEVICE. "0 of 12" must be visible; a verifier that checked
# nothing must not read like one that found nothing wrong.
out="$(printf '' | ar verdict)"
has "$out" "0 of 12 rungs evaluated" "verdict: zero-examined is stated, not implied"

# --- 2b. verdict: every rejectable input is observed being REJECTED -------------------------------
# Each of these would otherwise degrade toward a pass, so each must be a usage error (2).
printf 'notarung\tok\t\n'      | ar verdict >/dev/null 2>&1; eq $? 2 "verdict: an unknown rung name is rejected"
printf 'gates\tmaybe\t\n'      | ar verdict >/dev/null 2>&1; eq $? 2 "verdict: an unknown STATUS is rejected (never a pass)"
printf 'gates\tok\t\ngates\ttodo\t\n' | ar verdict >/dev/null 2>&1; eq $? 2 "verdict: a duplicated rung is rejected (no silent last-wins)"
printf 'gates\tOK\t\n'         | ar verdict >/dev/null 2>&1; eq $? 2 "verdict: status matching is case-exact"
ar verdict extra >/dev/null 2>&1; eq $? 2 "verdict: rejects arguments"
# A record with NO detail column is legal — detail is optional — and must not shift the status.
out="$(printf 'gates\tok\n' | ar verdict)"
has "$out" "1 of 12 rungs evaluated" "verdict: a two-field record parses (detail is optional)"

# The report must name the OWNER of each outstanding rung — that is the issue's "who must
# decide it", and it is the half a bare pass/fail cannot carry.
out="$(printf 'slate\ttodo\tthe milestone is empty\ndispositions\ttodo\tno row\n' | ar verdict)"
has "$out" "[owner]" "verdict: an owner-decided rung is labelled [owner]"
out="$(printf 'gates\ttodo\tnone detected\n' | ar verdict)"
has "$out" "[agent]" "verdict: an agent-actionable rung is labelled [agent]"
has "$out" "none detected" "verdict: the evidence detail reaches the report"

# --- 3. probe: the offline rungs, each driven both ways -------------------------------------------
# --- manifest
d="$WORK/p-nomanifest"; mkrepo "$d"
out="$(ar probe "$d")"
has "$out" "manifest${TAB}todo" "probe: no agents.toml is todo"
printf 'x = 1\n' > "$d/agents.toml"
out="$(ar probe "$d")"
has "$out" "manifest${TAB}todo" "probe: an agents.toml with no [roles] is still todo"
printf '[roles]\nprimary = "claude"\n' > "$d/agents.toml"
out="$(ar probe "$d")"
has "$out" "manifest${TAB}ok" "probe: [roles] primary makes the manifest rung ok"

# --- decisions
has "$out" "decisions${TAB}todo" "probe: no decision log is todo"
mkdir -p "$d/.ai-dev-baseline"; printf '# decisions\n' > "$d/.ai-dev-baseline/decisions.md"
out="$(ar probe "$d")"
has "$out" "decisions${TAB}ok" "probe: a decision log makes the rung ok"

# --- shape
has "$out" "shape${TAB}ok" "probe: a resolvable git root makes the shape rung ok"

# --- gates: THE LOUD CASE. A project with no detectable gate must be RED, not silent. This is
# the deliberate inversion of project-gates.sh's own "emit nothing on an unknown ecosystem"
# contract — right for a gate runner, wrong for an adoption — and it is the assertion that goes
# red if someone later "simplifies" the two into one policy.
d="$WORK/p-nogates"; mkrepo "$d"
out="$(ar probe "$d")"
has "$out" "gates${TAB}todo" "probe: NO detectable gate is todo (loud), not a silent pass"
has "$out" "NO GATE" "probe: the no-gate case says so in words"

# --- gates: explicitly disabled/N/A is a RECORDED DECISION, distinct from a detection miss.
d="$WORK/p-nagates"; mkrepo "$d"
printf '[gates.state]\ntypecheck = "na"\nlint = "na"\ntest = "na"\nformat = "na"\n' > "$d/agents.toml"
out="$(ar probe "$d")"
has "$out" "gates${TAB}na" "probe: every gate declared N/A is na, not todo"

# --- gates: detected-but-never-executed is the "detection is not working" rung.
d="$WORK/p-gates"; mkrepo "$d"
printf '[gates]\nbuild = "exit 0"\n' > "$d/agents.toml"
out="$(ar probe "$d")"
has "$out" "gates${TAB}todo" "probe: a detected gate with no receipt is todo"
has "$out" "NEVER EXECUTED" "probe: the never-executed case says so in words"

# --- receipt: the full lifecycle, and each state is DISTINGUISHABLE ------------------------------
ar receipt check "$d" >/dev/null 2>&1; eq $? 11 "receipt: absent is 11 (none)"
ar receipt run "$d" >/dev/null 2>&1;   eq $? 0  "receipt: a passing gate run exits 0"
ar receipt check "$d" >/dev/null 2>&1; eq $? 0  "receipt: a fresh passing receipt is 0 (ok)"
out="$(ar probe "$d")"
has "$out" "gates${TAB}ok" "probe: a fresh passing receipt makes the gates rung ok"

# HEAD moves -> stale. Yesterday's green says nothing about today's commit.
printf 'more\n' >> "$d/README.md"; git -C "$d" add README.md; check_git "$d" commit -qm second
ar receipt check "$d" >/dev/null 2>&1; eq $? 10 "receipt: a new HEAD makes the receipt stale"
out="$(ar receipt check "$d")"; has "$out" "HEAD is now" "receipt: the stale reason names the commit"

# The gate CONFIGURATION moves -> stale, even at the same HEAD. The receipt is a receipt for a
# specific set of commands; changing them leaves the new set unverified.
ar receipt run "$d" >/dev/null 2>&1
printf '[gates]\nbuild = "exit 0"\nextra = "exit 0"\n' > "$d/agents.toml"
ar receipt check "$d" >/dev/null 2>&1; eq $? 10 "receipt: an edited [gates] makes the receipt stale"
out="$(ar receipt check "$d")"; has "$out" "configuration changed" "receipt: the stale reason names the config"

# A FAILING gate run still writes a receipt, and `check` reports it as failed (12) — NOT as
# "never run". Those are different facts with different remedies, and collapsing them would make
# a broken project look merely unverified.
d="$WORK/p-redgate"; mkrepo "$d"
printf '[gates]\nbuild = "exit 7"\n' > "$d/agents.toml"
ar receipt run "$d" >/dev/null 2>&1;   eq $? 1  "receipt: a failing gate run exits non-zero"
ar receipt check "$d" >/dev/null 2>&1; eq $? 12 "receipt: a recorded failure is 12, not 11"
out="$(ar probe "$d")"
has "$out" "gates${TAB}todo" "probe: a failed gate run keeps the rung todo"
has "$out" "WENT RED" "probe: a failed gate run says the gates ran and failed"

# A TRUNCATED receipt (an older format, or a partial write) is unreadable — `none`, never `ok`.
printf '%s\t%s\t%s\n' "$d" "$(git -C "$d" rev-parse HEAD)" "deadbeef" > "$ADB_STATE_DIR/adopt-gate-receipt.tsv"
ar receipt check "$d" >/dev/null 2>&1; eq $? 11 "receipt: a receipt with no outcome column is none, not ok"

ar receipt >/dev/null 2>&1;                eq $? 2 "receipt: rejects a missing action"
ar receipt bogus "$d" >/dev/null 2>&1;     eq $? 2 "receipt: rejects an unknown action"
ar receipt check "$WORK/nope" >/dev/null 2>&1; eq $? 2 "receipt: rejects a non-directory"

# --- probe: argument validation -------------------------------------------------------------------
ar probe >/dev/null 2>&1;                        eq $? 2 "probe: rejects a missing root"
ar probe "$WORK/nope" >/dev/null 2>&1;           eq $? 2 "probe: rejects a non-directory"
ar probe "$d" --agents "" >/dev/null 2>&1;       eq $? 2 "probe: rejects an empty --agents"
ar probe "$d" --agents "../x" >/dev/null 2>&1;   eq $? 2 "probe: rejects a traversal agent token"
ar probe "$d" "$d" >/dev/null 2>&1;              eq $? 2 "probe: rejects two roots"

# --- 4. tracker: every rung, both ways, plus the fail-closed absences ------------------------------
tr_out() { printf '%s' "$1" | ar tracker; }

# EVERY tracker rung is unknown when its fact is absent. This single assertion is the one that
# makes "a caller that forgot a read" safe, and it is asserted per-rung rather than in aggregate
# so a single rung regressing to a default cannot hide behind the others.
out="$(tr_out '{}')"
for r in milestones slate unmilestoned dispositions roadmap settings release; do
  case "$out" in
    *"$r${TAB}unknown"*) ok ;;
    # `release` is the one deliberate exception and is asserted separately below.
    *) if [ "$r" = release ]; then ok; else bad "tracker: '$r' must be unknown when its fact is absent"; fi ;;
  esac
done

# --- milestones
out="$(tr_out '{"release_milestone":"Next release","backlog_milestone":"Backlog","blocker_label":false}')"
has "$out" "milestones${TAB}todo" "tracker: a missing blocker label is todo"
out="$(tr_out '{"release_milestone":"Next release","backlog_milestone":"Backlog","blocker_label":true}')"
has "$out" "milestones${TAB}ok" "tracker: both milestones + the label is ok"

# --- slate: the ZERO-ISSUE MILESTONE is #81's concrete dead-flow case.
out="$(tr_out '{"armed":0}')"
has "$out" "slate${TAB}todo" "tracker: an empty release milestone is todo"
has "$out" "ZERO issues" "tracker: the empty-milestone case says so in words"
out="$(tr_out '{"armed":3}')"
has "$out" "slate${TAB}ok" "tracker: a non-empty release milestone is ok"
# A non-numeric count is unknown, not zero. Coercing garbage to 0 would report a healthy repo's
# milestone as empty and send the owner to re-slate a release that is already fine.
out="$(tr_out '{"armed":"lots"}')"
has "$out" "slate${TAB}unknown" "tracker: a non-numeric armed count is unknown, not zero"

# --- unmilestoned
out="$(tr_out '{"unmilestoned":7}')"
has "$out" "unmilestoned${TAB}todo" "tracker: open issues in limbo are todo"
out="$(tr_out '{"unmilestoned":0}')"
has "$out" "unmilestoned${TAB}ok" "tracker: zero in limbo is ok"

# --- dispositions: THE FALSE-GREEN REGRESSION. A pre-existing thematic milestone with no
# `milestone:<title>` row must be RED. The first implementation reported this exact input as ok.
facts='{"release_milestone":"Next release","backlog_milestone":"Backlog",
        "milestones":[{"title":"Next release","open_issues":2},{"title":"Backlog","open_issues":9},
                      {"title":"Audit Results","open_issues":44}],"dispositions":[]}'
out="$(tr_out "$facts")"
has "$out" "dispositions${TAB}todo" "tracker: an undispositioned thematic milestone is todo"
has "$out" "Audit Results (44 open)" "tracker: the undispositioned milestone is named WITH its issue count"
# The convention's own two milestones are dispositioned BY the convention — demanding a row for
# `Next release` would ask the owner to justify what they just created.
hasnt "$out" "Next release (" "tracker: the release milestone needs no disposition row"
hasnt "$out" "Backlog (" "tracker: the backlog milestone needs no disposition row"
# ...and a recorded row retires it.
facts='{"release_milestone":"Next release","backlog_milestone":"Backlog",
        "milestones":[{"title":"Audit Results","open_issues":44}],
        "dispositions":["milestone:Audit Results"]}'
out="$(tr_out "$facts")"
has "$out" "dispositions${TAB}ok" "tracker: a recorded milestone:<title> row retires the question"
# A row for a DIFFERENT milestone must not retire this one.
facts='{"release_milestone":"Next release","backlog_milestone":"Backlog",
        "milestones":[{"title":"Audit Results","open_issues":44}],
        "dispositions":["milestone:Scoring Audit"]}'
out="$(tr_out "$facts")"
has "$out" "dispositions${TAB}todo" "tracker: a row for another milestone does not retire this one"
# A MALFORMED milestone list must be UNDETERMINED, never "all dispositioned". This is the shape
# of the original defect: the filter fails, and if its stderr is swallowed the empty output reads
# as an empty undecided-set — a false green. The `.title`-rebinding bug is fixed, so the only way
# to reach that path now is a genuinely unreadable input, which is exactly what this supplies.
# Without this row the "swallow stderr" mutation has no witness and the guard cannot be observed
# failing at all.
out="$(tr_out '{"release_milestone":"Next release","backlog_milestone":"Backlog","milestones":"not-an-array"}' 2>/dev/null)"
has "$out" "dispositions${TAB}unknown" "tracker: an unreadable milestone list is unknown, NOT all-dispositioned"
hasnt "$out" "dispositions${TAB}ok" "tracker: an unreadable milestone list never reports ok"

# A version-named milestone (`v2026.08`, real in one surveyed repo) is a pre-existing milestone
# like any other and must be dispositioned rather than silently accepted for looking release-ish.
facts='{"release_milestone":"Next release","backlog_milestone":"Backlog",
        "milestones":[{"title":"v2026.08","open_issues":1}],"dispositions":[]}'
out="$(tr_out "$facts")"
has "$out" "dispositions${TAB}todo" "tracker: a version-named milestone still needs a disposition"

# --- roadmap: zero / one / split brain are three distinguishable answers.
out="$(tr_out '{"roadmap_count":0}')"; has "$out" "roadmap${TAB}todo" "tracker: no roadmap artifact is todo"
out="$(tr_out '{"roadmap_count":1}')"; has "$out" "roadmap${TAB}ok"   "tracker: exactly one roadmap artifact is ok"
out="$(tr_out '{"roadmap_count":2}')"
has "$out" "roadmap${TAB}todo" "tracker: two roadmap artifacts is todo"
has "$out" "split brain" "tracker: the duplicate case is named as a split brain"

# --- settings: PASSED THROUGH from repo-settings.sh, never re-derived here.
out="$(tr_out '{"settings":"ok","settings_detail":"required checks then auto-merge"}')"
has "$out" "settings${TAB}ok" "tracker: a settings verdict passes through"
has "$out" "required checks then auto-merge" "tracker: the settings detail passes through"
out="$(tr_out '{"settings":"na","settings_detail":"no CI in this repo (#24)"}')"
has "$out" "settings${TAB}na" "tracker: a no-CI repo can declare settings N/A"
# An unrecognized settings word is an ERROR, never a pass — the same rule release-ready applies.
printf '%s' '{"settings":"probably-fine"}' | ar tracker >/dev/null 2>&1
eq $? 2 "tracker: an unrecognized settings verdict is rejected, not accepted"

# --- release
out="$(tr_out '{"release_command":"/release"}')"
has "$out" "release${TAB}ok" "tracker: a resolved release command is ok"
out="$(tr_out '{}')"
has "$out" "release${TAB}todo" "tracker: no release-command marker is todo"

# --- tracker input validation
printf 'not json' | ar tracker >/dev/null 2>&1; eq $? 2 "tracker: invalid JSON is rejected"
ar tracker extra </dev/null >/dev/null 2>&1;    eq $? 2 "tracker: rejects arguments"
out="$(printf '' | ar tracker)"
has "$out" "milestones${TAB}unknown" "tracker: empty stdin is every rung unknown, not a pass"

# --- 5. end to end: probe + tracker -> verdict ----------------------------------------------------
# The composition is the product, so it is asserted as one: a half-adopted project must come out
# red WITH its reasons, and a fully adopted one green — through the real subcommands, not a
# hand-written record set.
d="$WORK/e2e"; mkrepo "$d"
printf '[roles]\nprimary = "claude"\n[gates]\nbuild = "exit 0"\n' > "$d/agents.toml"
mkdir -p "$d/.ai-dev-baseline"; printf '# decisions\n' > "$d/.ai-dev-baseline/decisions.md"
ar receipt run "$d" >/dev/null 2>&1
facts='{"release_milestone":"Next release","backlog_milestone":"Backlog","blocker_label":true,
        "armed":4,"unmilestoned":0,"roadmap_count":1,
        "milestones":[{"title":"Next release","open_issues":4}],"dispositions":[],
        "settings":"ok","settings_detail":"applied","release_command":"/release"}'
combined="$( { ar probe "$d"; printf '%s' "$facts" | ar tracker; } )"
out="$(printf '%s' "$combined" | ar verdict)"; rc=$?
has "$out" "12 of 12 rungs evaluated" "e2e: probe+tracker cover the whole contract"
has "$out" "VERDICT: green" "e2e: a fully adopted fixture is green"
eq "$rc" "0" "e2e: green exits 0"

# ...and the same fixture with ONE thing undone must be red and must NAME it.
facts_bad='{"release_milestone":"Next release","backlog_milestone":"Backlog","blocker_label":true,
        "armed":0,"unmilestoned":0,"roadmap_count":1,
        "milestones":[{"title":"Next release","open_issues":0}],"dispositions":[],
        "settings":"ok","settings_detail":"applied","release_command":"/release"}'
combined="$( { ar probe "$d"; printf '%s' "$facts_bad" | ar tracker; } )"
out="$(printf '%s' "$combined" | ar verdict)"; rc=$?
has "$out" "VERDICT: red" "e2e: an empty release milestone makes the whole contract red"
has "$out" "[owner] slate" "e2e: the red rung is named with its owner"
eq "$rc" "10" "e2e: red exits 10"

# IDEMPOTENT: #81 requires that re-running adoption changes nothing. Two consecutive runs over an
# unchanged fixture must produce byte-identical reports — a verifier whose output drifts run to
# run cannot be used to decide anything.
a="$( { ar probe "$d"; printf '%s' "$facts" | ar tracker; } | ar verdict)"
b="$( { ar probe "$d"; printf '%s' "$facts" | ar tracker; } | ar verdict)"
eq "$a" "$b" "e2e: two consecutive runs produce identical reports (idempotent)"

# --- 6. the library never mutates the project it is given -----------------------------------------
# `probe`, `tracker` and `verdict` are READS. D60 bounds /adopt to a scan, and a verifier that
# repaired what it found would be the migration executor (#326) by another name.
d="$WORK/readonly"; mkrepo "$d"
printf '[roles]\nprimary = "claude"\n[gates]\nbuild = "exit 0"\n' > "$d/agents.toml"
before="$(cd "$d" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum 2>/dev/null | shasum)"
ar probe "$d" >/dev/null 2>&1
printf '%s' '{"armed":1}' | ar tracker >/dev/null 2>&1
after="$(cd "$d" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum 2>/dev/null | shasum)"
eq "$after" "$before" "read-only: probe/tracker do not alter the scanned project"
# The receipt lands in the agent's state dir, NOT in the project — writing into a project this
# workflow promises not to modify, in order to record that the promise was kept, would be absurd.
ar receipt run "$d" >/dev/null 2>&1
after="$(cd "$d" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum 2>/dev/null | shasum)"
eq "$after" "$before" "read-only: the receipt is written outside the project"
if [ -f "$ADB_STATE_DIR/adopt-gate-receipt.tsv" ]; then ok
else bad "read-only: the receipt lands in the state dir"; fi

# --- 7. the workflow still delegates to this library ----------------------------------------------
# A source-drift guard, matching check-adopt.sh's: the predicates are only reachable if the
# workflow actually calls them, and a rename that left the prose behind would ship a verifier
# nothing invokes.
# Matched through the PLACEHOLDER, which is how the workflow actually spells the invocation —
# `{{ADOPT_READINESS}} probe`, rendered per agent by scripts/build.sh. Grepping for a bare
# `readiness probe` would pass on prose that merely mentions the step and fail on the real call.
for sub in contract probe facts tracker verdict "receipt run" status; do
  if grep -q "ADOPT_READINESS}} $sub" "$WF"; then ok
  else bad "workflow: adopt.md must call '{{ADOPT_READINESS}} $sub'"; fi
done

# `bin/baseline adopt` is the re-runnable entry point #81 asks for, and a dispatch that silently
# stopped resolving would leave the documented command erroring with "unknown subcommand".
if grep -q 'scripts/lib/adopt-readiness.sh' "$ROOT/bin/baseline"; then ok
else bad "bin/baseline must dispatch 'adopt' to adopt-readiness.sh"; fi
# It must dispatch BEFORE the wrong-clone guard, like release/repo/skill-compose: `status` reads
# the PROJECT's tracker from the current directory, so dispatching later would answer about the
# install-source clone instead of the repo the operator is standing in.
adopt_at="$(grep -n '"${1:-}" = "adopt"' "$ROOT/bin/baseline" | head -n1 | cut -d: -f1)"
guard_at="$(grep -n -- '--- discovery' "$ROOT/bin/baseline" | head -n1 | cut -d: -f1)"
if [ -n "$adopt_at" ] && [ -n "$guard_at" ] && [ "$adopt_at" -lt "$guard_at" ]; then ok
else bad "bin/baseline: the 'adopt' dispatch must precede the wrong-clone guard"; fi

# --- the mutation harness (`--mutation`) -----------------------------------------------------------
# Same contract as check-adopt.sh's and check-fact-drift.sh's: every load-bearing decision is
# injected with its own defect, and the suite above must come back RED on that defect's OWN named
# witness. Red for the wrong reason is not evidence.
#
# Every mutation is applied to a COPY (self-review.md's copy rule). The working tree is never
# touched, so this cannot be the thing that eats an uncommitted edit.
MUT_NAMES=(); MUT_OLD=(); MUT_NEW=(); MUT_WIT=()
mut() { MUT_NAMES+=("$1"); MUT_OLD+=("$2"); MUT_NEW+=("$3"); MUT_WIT+=("$4"); }

# Literal strings and an index/substr replacement, never a regex — check-adopt.sh records how
# eight of twenty sed-based rows silently matched nothing, and a mutation that matches nothing is
# a test that proves nothing. `ENVIRON`, not `awk -v`, because -v processes escape sequences.
_mut_apply() {  # <file> <old> <new>
  MUT_OLD_S="$2" MUT_NEW_S="$3" awk '
    BEGIN { old = ENVIRON["MUT_OLD_S"]; new = ENVIRON["MUT_NEW_S"] }
    !hit { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); hit = 1 } }
    { print }
  ' "$1"
}

# THE FAIL-CLOSED MUTATIONS. Each turns one guard toward the flattering answer.
#
# THE WITNESS IS THE ASSERTION'S FULL LABEL, prefix included. The first version of this table
# wrote the witness as the bare sentence ("a new HEAD makes the receipt stale") while the suite
# prints "FAIL: receipt: a new HEAD makes the receipt stale" — so every one of the sixteen rows
# reported "went red, but NOT on its witness" while the guards were in fact working perfectly.
# A harness that cannot recognize its own success is the same silence it exists to detect.
#
# AND EVERY LITERAL IS ONE LINE. `_mut_apply` matches with awk's `index()`, which sees a single
# record at a time, so a literal spanning two source lines can never match — and a mutation that
# matches nothing is a test that proves nothing. Two rows started that way; the did-it-apply
# check below is what caught them.
mut missing-rung-is-skipped \
    'unknowns+=("$rung${TAB}$owner${TAB}$title${TAB}not reported' \
    'continue; unknowns+=("$rung${TAB}$owner${TAB}$title${TAB}not reported' \
    'verdict: a rung nobody reported is unknown, not absent'
mut unknown-status-accepted \
    '*) die "verdict: rung '"'"'$rung'"'"' has status' \
    '*) st=ok ;; esac; case x in y) die "verdict: rung '"'"'$rung'"'"' has status' \
    'verdict: an unknown STATUS is rejected (never a pass)'
mut duplicate-rung-last-wins \
    '[ -n "${seen[$rung]:-}" ] && die "verdict: rung' \
    '[ -n "${seen[$rung]:-}" ] && : "verdict: rung' \
    'verdict: a duplicated rung is rejected (no silent last-wins)'
mut indeterminate-becomes-green \
    "printf 'VERDICT: indeterminate" \
    "return 0; printf 'VERDICT: indeterminate" \
    'verdict: unknown-only is indeterminate'
mut red-becomes-green \
    "printf 'VERDICT: red" \
    "return 0; printf 'VERDICT: red" \
    'verdict: any todo is red'
mut no-gate-is-silent \
    '_ar_emit gates todo "NO GATE was detected' \
    '_ar_emit gates na "NO GATE was detected' \
    'probe: NO detectable gate is todo (loud), not a silent pass'
mut gate-count-greps-status \
    'detect "$root" 2>/dev/null | grep -c . || true)' \
    'status "$root" 2>/dev/null | grep -c "run:" || true)' \
    'probe: a detected gate with no receipt is todo'
mut receipt-ignores-head \
    'if [ "$r_sha" != "$sha" ];' \
    'if false;' \
    'receipt: a new HEAD makes the receipt stale'
mut receipt-ignores-gate-config \
    'if [ "$r_digest" != "$digest" ];' \
    'if false;' \
    'receipt: an edited [gates] makes the receipt stale'
mut receipt-failure-reads-as-ok \
    'if [ "$r_outcome" = fail ];' \
    'if false;' \
    'receipt: a recorded failure is 12, not 11'
mut receipt-truncated-reads-as-ok \
    'case "$r_outcome" in pass|fail) ;; *) printf' \
    'case "$r_outcome" in pass|fail|"") ;; *) printf' \
    'receipt: a receipt with no outcome column is none, not ok'
mut disposition-jq-rebinding-returns \
    'select( ($d | index("milestone:" + $m.title)) == null )' \
    'select( ($d | index("milestone:" + .title)) == null )' \
    'tracker: an undispositioned thematic milestone is todo'
mut disposition-jq-failure-unchecked \
    'if ! undecided="$(printf' \
    'if undecided="$(printf' \
    'tracker: an unreadable milestone list is unknown, NOT all-dispositioned'
mut disposition-convention-filter-drops-all \
    'select($m.title != $rel and $m.title != $bak)' \
    'select(false)' \
    'tracker: an undispositioned thematic milestone is todo'
mut armed-garbage-coerced-to-ok \
    'elif [ "$armed" -eq 0 ]; then' \
    'elif false; then' \
    'tracker: an empty release milestone is todo'
mut settings-typo-accepted \
    '*)  die "tracker: .settings must be' \
    '*)  _ar_emit settings ok "x" ;; esac; case x in y) die "tracker: .settings must be' \
    'tracker: an unrecognized settings verdict is rejected, not accepted'
mut roadmap-split-brain-ok \
    'elif [ "$rc_n" -gt 1 ]; then' \
    'elif false; then' \
    'tracker: two roadmap artifacts is todo'
mut unterminated-final-record-dropped \
    'while IFS= read -r line || [ -n "$line" ]; do' \
    'while IFS= read -r line; do' \
    'e2e: probe+tracker cover the whole contract'

# One mutation, start to verdict. The verdict travels through a FILE because this runs in a
# background subshell and a counter incremented there dies with it.
_mut_one() {  # <index>
  local i="$1" copy out
  copy="$WORK/mut-$i"
  mkdir -p "$copy"
  if ! check_copy_subtrees "$ROOT" "$copy" scripts base >/dev/null 2>&1; then
    printf 'bad|could not copy the tree\n' > "$copy/verdict" 2>/dev/null; return
  fi
  if ! _mut_apply "$copy/scripts/lib/adopt-readiness.sh" "${MUT_OLD[$i]}" "${MUT_NEW[$i]}" > "$copy/mutated"; then
    printf 'bad|the rewrite failed\n' > "$copy/verdict"; return
  fi
  # VERIFY THE EDIT APPLIED. A literal that matches nothing produces an unchanged copy, the suite
  # passes, and the harness would blame the guard for a mutation that never happened — the same
  # silence it exists to detect, one level up.
  if cmp -s "$copy/mutated" "$copy/scripts/lib/adopt-readiness.sh"; then
    printf 'bad|the mutation matched nothing (literal is stale)\n' > "$copy/verdict"; return
  fi
  mv "$copy/mutated" "$copy/scripts/lib/adopt-readiness.sh"
  out="$( cd "$copy" && ADB_STATE_DIR="$copy/state" bash scripts/check-adopt-readiness.sh 2>&1 )"
  case "$out" in
    *"FAIL: ${MUT_WIT[$i]}"*) printf 'ok|\n' > "$copy/verdict" ;;
    *)
      case "$out" in
        *FAIL:*) printf 'bad|went red, but NOT on its witness [%s]\n' "${MUT_WIT[$i]}" > "$copy/verdict" ;;
        *)       printf 'bad|stayed GREEN — the guard cannot fail\n' > "$copy/verdict" ;;
      esac ;;
  esac
}

if [ "$MUTATE" -eq 1 ]; then
  # The mutated copies run the suite recursively, so the child must NOT recurse again.
  pool=4; i=0; running=0
  while [ "$i" -lt "${#MUT_NAMES[@]}" ]; do
    _mut_one "$i" &
    running=$((running + 1)); i=$((i + 1))
    if [ "$running" -ge "$pool" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
  done
  wait
  applied=0; red=0
  for i in "${!MUT_NAMES[@]}"; do
    v="$(cat "$WORK/mut-$i/verdict" 2>/dev/null || echo 'bad|no verdict file')"
    applied=$((applied + 1))
    case "$v" in
      ok\|*) red=$((red + 1)); ok ;;
      *) bad "mutation '${MUT_NAMES[$i]}': ${v#*|}" ;;
    esac
  done
  printf '\ncheck-adopt-readiness --mutation: %d mutation(s) applied, %d observed RED on their own witness\n' \
    "$applied" "$red" >&2
fi

check_summary "check-adopt-readiness"
