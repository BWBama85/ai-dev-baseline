#!/usr/bin/env bash
# ai-dev-baseline — behavioral tests for the /adopt decision predicates (#20, consolidating
# #21 and #29), plus a source-drift guard on the workflow that consumes them.  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work / #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
#
# WHY THIS EXISTS. /adopt is prose an agent executes against somebody else's repository, and its
# output is a recommendation a human then acts on. That is a different failure mode from
# /cleanup's — nothing here deletes anything — and it is not a milder one: an inventory that says
# `remove` about a file carrying behavior the project still needs gets that behavior deleted by
# the operator, with the plan as justification. So every classifier arm is tested from the side
# that costs something:
#
#   - a PRESCRIBED HOME that collides with a baseline artifact must be `keep`, never `remove`
#     (`.claude/scripts/precommit-gate.sh` is the real case: it collides by name AND is
#     handling-the-unknown.md's one legal home for custom gate policy);
#   - a colliding artifact that DIFFERS must be `move`, never `remove` — that is what the issue
#     means by a parity caveat, and the difference between the two verdicts is the project's
#     forked skill;
#   - anything whose delta cannot be established must be `escalate`, never a guess;
#   - every bad argument must exit 2, never 0-with-a-plausible-word.
#
# AND EVERY GUARD IS OBSERVED FAILING. base/practices/self-review.md's rule is that a check is not
# done until it has been seen going red on an input it is supposed to reject, because a guard's
# failure mode is SILENCE. That rule earned its place here twice while this file was being
# written: `hygiene`'s broad-ignore axis could not fire at all (it matched the pathname column of
# `git check-ignore -v`, which always contains the path being asked about), and the first
# credential probe embedded a tab and made its own finding unreadable. Neither was visible by
# reading; both showed up the moment a fixture was run. So the ignore axis below asserts the
# BROAD case fires, the EXPLICIT case stays silent, and the ABSENT case fires differently — three
# distinguishable answers, because two of them would let a stuck predicate pass.
#
# OFFLINE and HERMETIC. The library never calls gh; the only git it runs is `check-ignore`, which
# needs a repo but no remote. Every fixture is a `mktemp -d` tree. THE TRACKED WORKING TREE IS
# NEVER MUTATED — not to build a fixture, not to negative-test a lint (self-review.md's copy
# rule: editing a tracked file to watch a check reject it is what ends in `git checkout --` and
# ~40 minutes of lost work).
#
# WHAT THIS SUITE CANNOT PROVE, stated plainly rather than implied away:
#   - that the four surveyed repositories (getrich, unraid-cache-cleaner, support-workstation,
#     bama-politics) still have the shapes these fixtures model. They are not in this repository
#     and CI cannot see them. The fixtures reproduce the shapes those repos were DOCUMENTED to
#     have in #20/#29; the live acceptance run is manual and is recorded in the PR, not here.  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
#   - semantic parity between two differing files. `differs` is byte-inequality, deliberately, and
#     no assertion here claims more.
#   - that the credential axis catches an unfamiliar secret format. Its prefix list is closed.
#
# Usage: bash scripts/check-adopt.sh              (exit 0 = all pass, 1 = a failure)
#        bash scripts/check-adopt.sh --mutation  (…and inject each defect, requiring RED)

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
# happened to be and says nothing about whether the file loaded.
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
AD="$ROOT/scripts/lib/adopt-lib.sh"
WF="$ROOT/base/workflows/adopt.md"
PRACTICE="$ROOT/base/practices/handling-the-unknown.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary
check_init "check-adopt"

# ARGUMENTS ARE VALIDATED HERE, BEFORE the exit guard is armed. Exiting later — after
# `check_exit_guard` is installed but before `check_summary` runs — makes the guard fire and report
# "reported as passing (exit status was 2)", which is a true statement about a bad invocation
# dressed up as a suite failure. A usage error should look like a usage error.
MUTATE=0
case "${1:-}" in
  --mutation) MUTATE=1 ;;
  "") : ;;
  *) printf 'check-adopt: unknown argument: %s (expected --mutation, or no argument)\n' "$1" >&2; exit 2 ;;
esac

TAB="$(printf '\t')"
WORK="$(mktemp -d)" || { echo "check-adopt: FATAL — cannot create a scratch dir" >&2; exit 1; }
# check_exit_guard, NOT a bare `trap … EXIT`. A suite's exit status is its last command's, and
# only check_summary consults the failure counter — so losing that final line prints the FAIL
# diagnostics and still exits 0, reported as PASSING by selfcheck and CI. The guard fails closed
# on that, and it takes the cleanup as an argument precisely so a suite's own trap cannot silently
# replace it.
check_exit_guard "check-adopt" "rm -rf \"$WORK\""

# --- 1. classify: the four verdicts, and the order of the arms ----------------------------------
# The verdict is the first TSV field; the reason is prose and is not asserted on (asserting the
# sentence would make every wording improvement a test failure, which trains people to stop
# improving wording).
verdict() { bash "$AD" classify "$@" | cut -f1; }

eq "$(verdict skill  no  same    no)"  keep     "no baseline artifact of this identity -> keep"
eq "$(verdict skill  no  differs no)"  keep     "no collision -> keep regardless of delta"
eq "$(verdict skill  yes same    no)"  remove   "byte-identical duplicate -> remove"
eq "$(verdict skill  yes differs no)"  move     "collides but DIFFERS -> move, never remove"
eq "$(verdict skill  yes unknown no)"  escalate "delta unknown -> escalate, never a guess"

# THE ORDER OF THE ARMS, pinned as its own case. `prescribed` is tested BEFORE collision, and
# reversing them is not a stylistic difference: `.claude/scripts/precommit-gate.sh` collides with
# a shipped script by name and IS the practice's home for gate policy, so a collision-first
# classifier tells every adopting project to delete its own gate policy. Both delta values are
# asserted, because a rule that only held for `same` would still ship the bug for `differs`.
eq "$(verdict script yes same    yes)" keep "a PRESCRIBED HOME that collides is keep (identical)"
eq "$(verdict script yes differs yes)" keep "a PRESCRIBED HOME that collides is keep (differing)"

# An unmodelled kind is escalate, not an error and not a guess.
eq "$(verdict frobnicator yes same no)" escalate "an unmodelled kind -> escalate"

# A `move` MUST NAME A DESTINATION THAT EXISTS FOR THAT KIND. The first live run against a real
# adopted project returned `move` for a 294-line forked Stop hook and told the operator to re-home
# it "to overrides.md" — a mechanism that exists for skills and does NOT exist for scripts. An
# instruction naming a home that is not there is worse than none: it reads as authoritative and
# leaves the operator improvising, which is the drift handling-the-unknown.md exists to stop.
reason() { bash "$AD" classify "$1" yes differs no | cut -f2; }
has   "$(reason skill)"   "overrides.md"      "a forked SKILL is pointed at the compose-override mechanism"
hasnt "$(reason script)"  "overrides.md"      "a forked SCRIPT must NOT be pointed at a mechanism that does not exist for it"
has   "$(reason script)"  "agents.toml"       "a forked SCRIPT is pointed at the config surface that does exist"
has   "$(reason rootdoc)" "per-project-overrides" "a duplicating ROOT DOC is pointed at the precedence rule"
has   "$(reason other)"   "handling-the-unknown"  "an unmodelled kind's move says to classify it, not to improvise a home"

# --- 1b. classify: every rejectable argument is observed being REJECTED --------------------------
# The enum is closed, so the harness injects each invalid form rather than spot-checking one. A
# predicate that accepted a typo'd enum would answer a question nobody asked: `delta=diffres`
# silently taking the `unknown` arm reads as caution and is actually a parse bug.
# NOT named `bad`: that is check-lib.sh's own failure-assertion FUNCTION. Bash keeps variables and
# functions in separate namespaces so a loop variable of that name happens to work, but a name that
# reads as a call to the suite's own reporter is one edit away from becoming one.
for badargs in "skill maybe same no" "skill yes sometimes no" "skill yes same perhaps" \
               "skill yes same" "skill yes same no extra"; do
  # shellcheck disable=SC2086  # deliberate word splitting: each case is an argv, not one string
  out="$(bash "$AD" classify $badargs 2>&1)"; rc=$?
  eq "$rc" 2 "classify [$badargs] must exit 2"
  has "$out" "adopt-lib:" "classify [$badargs] must say which argument was wrong"
done

# --- 2. prescribed: the table matches the practice it transcribes --------------------------------
# The table in adopt-lib.sh is a TRANSCRIPTION of handling-the-unknown.md's prescribed-home list,
# and a transcription drifts. This is the guard against the drift that would matter: a home
# deleted from the practice while the classifier still calls it one. It is a PRESENCE check on the
# practice, which is all a text check can honestly be — it catches a removal or a rename, not a
# change of meaning.
yes "$(bash "$AD" prescribed script  precommit-gate.sh; echo $?)" "precommit-gate.sh IS a prescribed home"
yes "$(bash "$AD" prescribed rootdoc CLAUDE.md;         echo $?)" "the repo root doc IS a prescribed home"
yes "$(bash "$AD" prescribed manifest agents.toml;      echo $?)" "agents.toml IS a prescribed home"
yes "$(bash "$AD" prescribed override overrides.md;     echo $?)" "a compose-override IS a prescribed home"
no  "$(bash "$AD" prescribed script  statusline.sh;     echo $?)" "statusline.sh is NOT a prescribed home"
no  "$(bash "$AD" prescribed skill   implement-issue;   echo $?)" "a whole forked skill is NOT a prescribed home"
eq  "$(bash "$AD" prescribed nonsense x >/dev/null 2>&1; echo $?)" 2 "an unknown kind exits 2"

if [ -f "$PRACTICE" ]; then
  for token in 'agents.toml [gates]' 'agents.toml [roles]' 'precommit-gate.sh' \
               'project-scoped skill' '.ai-dev-baseline/decisions.md'; do
    if grep -Fq -- "$token" "$PRACTICE"; then ok
    else bad "handling-the-unknown.md no longer names the prescribed home '$token' that adopt-lib.sh transcribes"; fi
  done
else
  bad "base/practices/handling-the-unknown.md is missing — adopt-lib.sh's prescribed-home table has no source"
fi

# A FOREIGN FRAMEWORK'S PIN IS `move`, NOT `keep`. It has no baseline counterpart, so the
# no-collision arm classified it `keep` — while the workflow's step 7 told the operator to RETIRE
# it. The plan therefore preserved the one artifact the prose said must go, and the two halves of
# the feature contradicted each other in writing. Review caught it.
eq "$(verdict foreign-pin no unknown no)" move "a foreign framework pin is MOVE (reconcile then retire), never keep"
eq "$(verdict foreign-pin no same    no)" move "...whatever its delta, since it has no baseline counterpart"

# --- 2b. delta: the skill-is-a-directory trap, and unknown as a reachable answer ----------------
# `delta` exists because the obvious inline `cmp -s` is WRONG for the commonest case. A skill's
# shipped source is a directory; `cmp` on a directory returns non-zero, a workflow reads that as
# "differs", and every project's every skill is then reported as a fork carrying a delta. So the
# directory case is asserted first and against the REAL shipped tree, not a fixture — a fixture
# could accidentally be a file and prove nothing.
S1="$ROOT/agents/claude/skills/cleanup"
S2="$ROOT/agents/claude/skills/debug"
eq "$(bash "$AD" delta skill "$S1" "$S1")" same    "a skill compared with itself is same (via SKILL.md, not cmp on a dir)"
eq "$(bash "$AD" delta skill "$S1" "$S2")" differs "two different skills are differs"

# `unknown` must be REACHABLE on every way of failing to establish equality — a missing project
# copy, a missing baseline copy, and a path that is not a file at all. If any of these collapsed
# into `differs`, an unreadable install would produce a confident `move` recommendation.
eq "$(bash "$AD" delta skill "$S1" "$WORK/nope")"      unknown "a missing baseline copy is unknown, NOT differs"
eq "$(bash "$AD" delta skill "$WORK/nope" "$S1")"      unknown "a missing project copy is unknown"
eq "$(bash "$AD" delta script "$WORK" "$ROOT/install.sh")" unknown "a directory where a file is expected is unknown"
eq "$(bash "$AD" delta script "$ROOT/install.sh" "$ROOT/install.sh")" same "a plain file compares byte-wise"
eq "$(bash "$AD" delta script "$ROOT/install.sh" "$ROOT/uninstall.sh")" differs "two different files are differs"
eq "$(bash "$AD" delta skill "$S1" >/dev/null 2>&1; echo $?)" 2 "delta with too few arguments exits 2"

# THE SKILL COMPARISON IS THE WHOLE DIRECTORY. Comparing `SKILL.md` alone meant a project skill
# with an identical SKILL.md plus its own helper answered `same`, which classify turns into
# `remove`, which deletes the helper. Review reproduced it; this is the regression.
SD="$WORK/skilldir"; mkdir -p "$SD/proj" "$SD/base"
printf 'body\n' > "$SD/proj/SKILL.md"; printf 'body\n' > "$SD/base/SKILL.md"
eq "$(bash "$AD" delta skill "$SD/proj" "$SD/base")" same "identical skill directories are same"
printf '#!/bin/sh\n' > "$SD/proj/helper.sh"
eq "$(bash "$AD" delta skill "$SD/proj" "$SD/base")" differs \
   "an extra project-only file makes a skill differ (it must NOT be recommended for removal)"
rm -f "$SD/proj/helper.sh"
printf '#!/bin/sh\n' > "$SD/base/extra.sh"
eq "$(bash "$AD" delta skill "$SD/proj" "$SD/base")" differs "an extra BASELINE file also differs"
rm -f "$SD/base/extra.sh"
printf 'other\n' > "$SD/proj/SKILL.md"
eq "$(bash "$AD" delta skill "$SD/proj" "$SD/base")" differs "same file set, different contents -> differs"

# `cmp` IS THREE-VALUED: 0 identical, 1 different, >1 the comparison FAILED. Reading >1 as
# "differs" turns an I/O error into a confident `move`. An unreadable file is the reachable case.
# ORDINARY INPUT CANNOT REACH THIS ARM, because the `-r` readability guard runs first — so the
# branch is driven by SHADOWING `cmp` with a stub that exits 2. Same technique D59 records for
# reaching `adb_tsv_field_display`'s fallback seam: a defensive branch no input can reach is still a
# branch, and one that silently answered `differs` would turn an I/O failure into a confident
# `move`. An unreadable file is NOT a substitute — it exits at the `-r` guard and never reaches
# `cmp` at all, which is why the first version of this assertion could not fail.
CMPDIR="$WORK/cmpstub"; mkdir -p "$CMPDIR"
printf '#!/bin/sh\nexit 2\n' > "$CMPDIR/cmp"; chmod +x "$CMPDIR/cmp"
eq "$(PATH="$CMPDIR:$PATH" bash "$AD" delta script "$ROOT/install.sh" "$ROOT/install.sh")" unknown \
   "a cmp FAILURE (rc>1) is unknown, never differs"
# ...and the stub is proven to be in effect, so a PATH that failed to shadow cmp cannot leave the
# assertion above passing for the wrong reason.
eq "$(PATH="$CMPDIR:$PATH" cmp -s /dev/null /dev/null; echo $?)" 2 "the cmp stub is actually on PATH"

# AND THE PAIRING WITH classify, which is what actually ships the bug if it breaks: an `unknown`
# delta must reach `escalate`, never a verdict.
eq "$(verdict skill yes "$(bash "$AD" delta skill "$S1" "$WORK/nope")" no)" escalate \
   "an unreadable baseline copy escalates rather than recommending anything"

# --- 2c. review findings: symlinks, the vendored lib, filename safety, escaping, pin reads -------
# Six defects an independent review found after the suite above was green. Each is asserted from the
# side that costs something, and each carries a mutation row.

# A SYMLINK IS PART OF A SKILL. `find -type f` omitted them, so a project skill holding the
# baseline's regular files PLUS its own symlink compared `same` → `remove` → the symlink is deleted.
# Identical class to the `helper.sh` bug this comparison was widened for, one step further out.
SL="$WORK/skill-symlink"; mkdir -p "$SL/proj" "$SL/base" "$SL/target"
printf 'body\n' > "$SL/proj/SKILL.md"; printf 'body\n' > "$SL/base/SKILL.md"
printf 'data\n' > "$SL/target/real.txt"
if ln -s "$SL/target/real.txt" "$SL/proj/extra" 2>/dev/null; then
  eq "$(bash "$AD" delta skill "$SL/proj" "$SL/base")" differs \
     "a project-only SYMLINK makes a skill differ (it must not be recommended for removal)"
  ln -s "$SL/target/real.txt" "$SL/base/extra"
  eq "$(bash "$AD" delta skill "$SL/proj" "$SL/base")" same "...and matching symlinks are same"
  rm -f "$SL/base/extra"; ln -s "$SL/target/other.txt" "$SL/base/extra"
  eq "$(bash "$AD" delta skill "$SL/proj" "$SL/base")" differs \
     "...while the same NAME pointing somewhere else differs — the target is part of the identity"
else
  check_note "SKIP: symlinks unavailable here"; ok; ok; ok
fi

# A VENDORED `scripts/lib` IS ONE ARTIFACT, matching the single `lib` identity `shipped` emits.
# Without this, the flat file loop skipped the directory and the catch-all emitted its ~14 members
# as `other` — so a byte-identical vendored baseline library, the clearest possible `remove`, came
# out as fourteen escalations that could never join against anything.
VL="$WORK/vendored"; mkdir -p "$VL/.claude/scripts/lib"
for f in common.sh cleanup-lib.sh roadmap-lib.sh; do printf 'x\n' > "$VL/.claude/scripts/lib/$f"; done
vl_scan="$(bash "$AD" scan "$VL" --agents claude)"
has   "$vl_scan" "lib${TAB}.claude/scripts/lib${TAB}lib${TAB}claude" "a vendored scripts/lib is emitted as ONE lib artifact"
hasnt "$vl_scan" "other${TAB}.claude/scripts/lib/common.sh"          "...and its members are NOT re-emitted as individual escalations"

# A NEWLINE-BEARING FILENAME must reach `_ad_emit` WHOLE. Split on newlines it became two or more
# INVENTED paths, emitted as confident `other` records — so the record format's safety check, which
# exists for exactly this input, never saw the real name and could not fire.
NL="$WORK/newline-name"; mkdir -p "$NL/.claude"
if printf 'x\n' > "$NL/.claude/$(printf 'we\nird').md" 2>/dev/null; then
  nl_scan="$(bash "$AD" scan "$NL" --agents claude)"
  has   "$nl_scan" "warning${TAB}" "a newline-bearing filename yields the promised warning"
  hasnt "$nl_scan" "other${TAB}.claude/ird.md" "...not an INVENTED path that does not exist"
else
  check_note "SKIP: this filesystem refuses a newline in a filename"; ok; ok
fi

# THE PLAN RENDERS UNTRUSTED PATHS. `_ad_emit` accepts every byte but the two delimiters, so a legal
# filename may carry a carriage return or an ANSI escape — and the plan goes straight to a terminal.
cr_plan="$(printf 'keep\trootdoc\t%s\treason\n' "$(printf 'a\rEVIL')" | bash "$AD" plan)"
hasnt "$cr_plan" "$(printf 'a\rEVIL')" "the plan must not print a raw control byte from a scanned path"
has   "$cr_plan" 'a\rEVIL'             "...it renders the path instead"

# `pin-drift` REVALIDATES A COMMIT IT READ. pin-render's validation governs what this tool WRITES
# and says nothing about a pin that already existed or was hand-edited. `HEAD` produced
# `git log HEAD..HEAD` — an empty range reporting no drift at all, the most reassuring wrong answer.
PD="$WORK/pin-handedited"; mkdir -p "$PD"
printf '[upstream]\nversion = "v1"\ncommit  = "HEAD"\nadopted = "2026-08-12"\nstack   = "shell"\nagents  = []\n' > "$PD/pin.toml"
eq "$(bash "$AD" pin-drift "$PD/pin.toml" "$ROOT" >/dev/null 2>&1; echo $?)" 2 "pin-drift refuses a pin whose commit is HEAD"
printf '[upstream]\nversion = "v1"\ncommit  = "abcdef1"\nadopted = "2026-08-12"\nstack   = "shell"\nagents  = []\n' > "$PD/pin.toml"
eq "$(bash "$AD" pin-drift "$PD/pin.toml" "$ROOT" >/dev/null 2>&1; echo $?)" 2 "pin-drift refuses an ABBREVIATED commit read from a pin"

# THE IGNORE AXIS RUNS WHEN THE AGENT DIR DOES NOT EXIST YET — the run that most needs the warning.
# Its probes use `--no-index` precisely so they answer for a path that does not exist.
NOD="$WORK/no-agent-dir"; git init -q "$NOD" >/dev/null 2>&1
has "$(bash "$AD" hygiene "$NOD" --agents claude | grep '^ignore-risk' || true)" "is NOT gitignored" \
    "the ignore axis runs even when .<agent>/ does not exist yet"

# THE DEFAULT AGENT SET IS DERIVED from the installed baseline, not a third hardcoded literal.
# Asserted structurally: every agent the baseline ships must be scannable by default.
def_agents="$(bash "$AD" scan "$WORK" 2>&1; echo rc=$?)"
has "$def_agents" "rc=0" "a default (no --agents) scan resolves its agent set without error"
for a_dir in "$ROOT"/agents/*/; do
  a_tok="${a_dir%/}"; a_tok="${a_tok##*/}"
  yes "$(bash "$AD" scan "$WORK" --agents "$a_tok" >/dev/null 2>&1; echo $?)" \
      "the baseline-shipped agent '$a_tok' is a valid scan target"
done

# --- 3. shipped: derived from the real manifest, never a second list -----------------------------
# The value of `shipped` is that it cannot disagree with install.sh about what the baseline
# installs. Asserting a hardcoded expected list here would recreate exactly the second list the
# subcommand exists to avoid, so the assertions are STRUCTURAL: every skill directory that exists
# in the tree is reported, and the kinds are the ones the classifier consumes.
shipped="$(bash "$AD" shipped "$ROOT" claude)"
for d in "$ROOT"/agents/claude/skills/*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##*/}"
  has "$shipped" "skill${TAB}${n}${TAB}claude" "shipped must report the real skill '$n'"
done
has "$shipped" "script${TAB}precommit-gate.sh${TAB}claude" "shipped must report the hook scripts"
has "$shipped" "rootdoc${TAB}CLAUDE.md${TAB}claude"        "shipped must report the root doc"
hasnt "$shipped" "gemini" "shipped <agent> must filter to that agent"
eq "$(bash "$AD" shipped "$WORK" >/dev/null 2>&1; echo $?)" 2 "shipped on a non-baseline dir exits 2"

# A baseline root the install manifest cannot represent DIES; it does not report an empty set
# (#324, D64). This consumer was missed by #324's own inventory and had the installers' swallow:
# `adb_agent_manifest` ran inside the `done <<EOF … EOF` substitution, so its refusal arrived as
# zero records and exit 0. That is the worst possible reading here — an empty shipped set does not
# look like an error to `classify`, it looks like "the baseline ships nothing", which makes every
# artifact in the scanned project read as project-specific and recommends keeping a fork of each.
nl_root="$WORK/nlbase"$'\n'"shadow"
mkdir -p "$nl_root/agents/claude/skills/demo" "$nl_root/agents/claude/scripts" "$nl_root/scripts/lib"
nl_err="$WORK/nl-shipped.err"
nl_out="$(bash "$AD" shipped "$nl_root" claude 2>"$nl_err")"; nl_rc=$?
# EXIT 2 AND A DIAGNOSTIC, not merely "non-zero". A witness that accepts any non-zero status is
# satisfied by an incidental 126/127 — a bad interpreter path, a missing fixture — and would report
# the guard observed while the rule it covers was never reached (the D63 rule). `die`'s contract in
# this library is exit 2 plus a message, so both halves are asserted.
eq "$nl_rc" 2 "shipped refuses an unrepresentable baseline root with die's exit 2"
eq "$nl_out" "" "shipped emits no records when it refuses"
if [ -s "$nl_err" ]; then ok; else bad "shipped must say WHY it refused"; fi
has "$(cat "$nl_err")" "cannot enumerate" "shipped names the enumeration failure"

# ATOMIC ACROSS AGENTS, which is a different claim from the single-agent case above — and the one
# that was actually broken. With `claude` alone the refusal happens before the first record, so a
# claude-only fixture cannot distinguish "refuses" from "refuses after writing". Here the FIRST
# agent is representable and a LATER one is not: an independent review measured 25 records emitted
# and then exit 2, a partial write whose non-empty output the /adopt workflow's count guard accepts.
multi_root="$WORK/multibase"
mkdir -p "$multi_root/agents/claude/skills/fine" "$multi_root/agents/claude/scripts" "$multi_root/scripts/lib"
mkdir -p "$multi_root/agents/gemini/skills/bad"$'\n'"name"
printf 'x\n' > "$multi_root/agents/claude/CLAUDE.md"
printf 'x\n' > "$multi_root/agents/gemini/GEMINI.md"
multi_out="$(bash "$AD" shipped "$multi_root" 2>/dev/null)"; multi_rc=$?
eq "$multi_rc" 2 "shipped refuses when a LATER agent's manifest is unrepresentable"
eq "$multi_out" "" "shipped emits NOTHING for the earlier good agents — the refusal is atomic"
# And the same fixture minus the poisoned agent still enumerates, so the assertions above are not
# satisfied by a shipped that has simply stopped working.
rm -rf "$multi_root/agents/gemini"
multi_ok="$(bash "$AD" shipped "$multi_root" 2>/dev/null)"; multi_ok_rc=$?
yes "$multi_ok_rc" "shipped succeeds on the same fixture once the unrepresentable agent is gone"
has "$multi_ok" "skill${TAB}fine${TAB}claude" "shipped still enumerates the representable agent"

# Non-emptiness on the good path, so 'refuse everything' cannot satisfy the assertions above.
if [ -n "$shipped" ]; then ok; else bad "shipped must still enumerate a representable baseline root"; fi

# --- 4. scan: the surface, the boundary, and the record format ----------------------------------
# A fixture modelling getrich's documented shape: forked skills (one colliding with a baseline
# skill, one not), duplicate hook scripts, a project statusLine, a stack root doc, no agents.toml,
# and a prior framework's pin. Plus a `src/` tree that references an agent CLI — which the scan
# must NOT descend into (#29 axis 1).  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
FX="$WORK/getrich-shape"
mkdir -p "$FX"/.claude/{skills/{implement-issue,release},scripts,state} "$FX/src/lib/cli"
printf 'gap analysis is run by codex exec\n' > "$FX/.claude/skills/implement-issue/SKILL.md"
printf 'project release skill\n'             > "$FX/.claude/skills/release/SKILL.md"
printf '#!/bin/sh\n# apps/ packages/ scope\n' > "$FX/.claude/scripts/precommit-gate.sh"
printf '#!/bin/sh\n'                          > "$FX/.claude/scripts/statusline.sh"
printf '{"statusLine":{"type":"command","command":".claude/scripts/statusline.sh"}}\n' > "$FX/.claude/settings.json"
printf '# Cloudflare + stack conventions\n'   > "$FX/CLAUDE.md"
printf 'v1.2.3\n'                             > "$FX/.claude/UPSTREAM_VERSION"
printf 'const x = "codex exec"\n'             > "$FX/src/lib/cli/run.ts"
scan="$(bash "$AD" scan "$FX" --agents claude)"

has "$scan" "rootdoc${TAB}CLAUDE.md"                          "scan finds the root doc"
has "$scan" "skill${TAB}.claude/skills/implement-issue"       "scan finds a colliding forked skill"
has "$scan" "skill${TAB}.claude/skills/release"               "scan finds a project-only skill"
has "$scan" "script${TAB}.claude/scripts/precommit-gate.sh"   "scan finds the gate script"
has "$scan" "settings${TAB}.claude/settings.json"             "scan finds settings.json"
has "$scan" "foreign-pin${TAB}.claude/UPSTREAM_VERSION"       "scan finds a prior framework's pin"
# The harness-vs-product axis. (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED
# (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance,
# not tracked work)
hasnt "$scan" "src/"        "scan must NOT descend into product code (the harness-vs-product axis)"
hasnt "$scan" "agents.toml" "scan must not invent a manifest that does not exist"

# THE HARNESS-VS-PRODUCT BOUNDARY, asserted as its own case rather than inferred from the `hasnt`
# above: a scan that found nothing at all would satisfy that assertion too.
n_skills="$(printf '%s\n' "$scan" | grep -c "^skill${TAB}")"
eq "$n_skills" 2 "scan reports exactly the two skills in the fixture"

# The record format refuses a field it cannot represent (D41/D59's rule, applied here). A file
# whose NAME carries a newline forges a record whose leading field is attacker-chosen text.
# Guarded, because some filesystems refuse the name outright — a skipped case is honest, a
# silently-passing one is not.
ODD="$FX/.claude/scripts/$(printf 'a\nb')"
if printf '#!/bin/sh\n' > "$ODD" 2>/dev/null && [ -f "$ODD" ]; then
  odd_scan="$(bash "$AD" scan "$FX" --agents claude)"
  has "$odd_scan" "warning${TAB}" "a name carrying a newline yields a warning, not a forged record"
  # And the REST of the inventory survives — refusing per field, not per scan.
  has "$odd_scan" "rootdoc${TAB}CLAUDE.md" "one unrepresentable name must not drop the other facts"
  rm -f "$ODD"
else
  check_note "SKIP: this filesystem refuses a newline in a filename; the record-format refusal is unexercised"
fi

# AN UNMODELLED FILE UNDER THE AGENT DIR IS EMITTED AS `other`, which classifies to `escalate`.
# Omitting it silently — the original behaviour — meant the artifact never reached `classify`, so it
# never became `escalate`, so handling-the-unknown.md's protocol never ran on the one category it
# exists for. Silence looked exactly like a project with nothing unusual in it. Review caught it.
printf '{}\n'    > "$FX/.claude/settings.local.json"
printf '# r\n'   > "$FX/.claude/rules.md"
mkdir -p "$FX/.claude/state"; printf 'scratch\n' > "$FX/.claude/state/marker.json"
oth="$(bash "$AD" scan "$FX" --agents claude)"
has   "$oth" "other${TAB}.claude/rules.md"            "an unmodelled file under the agent dir is emitted as \`other\`"
has   "$oth" "other${TAB}.claude/settings.local.json" "...including one the modelled arms nearly match"
hasnt "$oth" ".claude/state/marker.json"              "but run-state scratch is NOT inventoried (it carries no adoption decision)"
# OS file-manager artifacts are excluded, and ONLY those — a real scan reported `.DS_Store` as an
# artifact to keep, which is a question with no answer. The exclusion stays narrow on purpose:
# anything broader reintroduces the silent omission the `other` kind exists to fix.
printf '\0\0' > "$FX/.claude/.DS_Store"
printf 'lock\n'  > "$FX/.claude/scheduled_tasks.lock"
oth2="$(bash "$AD" scan "$FX" --agents claude)"
hasnt "$oth2" ".DS_Store"            "an OS file-manager artifact is not inventoried"
has   "$oth2" "scheduled_tasks.lock" "...but a lock file still is — the exclusion is narrow, not a tidiness filter"
# `other` ESCALATES ON THE INPUT IT ACTUALLY GETS, which is collision=NO — the baseline ships
# nothing of an unmodelled identity, so `yes` is unreachable for this kind. The first version of
# this assertion passed `yes` and therefore proved nothing about the real path: in production every
# `other` record fell through to the no-collision `keep` arm and was reported as "project-specific,
# adoption does not touch it". Found by re-running the live acceptance scan, not by this suite.
eq    "$(verdict other no  unknown no)" escalate      "\`other\` escalates on collision=no — the input it actually receives"
eq    "$(verdict other no  same    no)" escalate      "...regardless of delta"
eq    "$(verdict other yes unknown no)" escalate      "...and on the unreachable collision=yes too"

# THE AGENT IS ON EVERY RECORD, so the collision join can match on it. Without it the lookup took
# the first row — Claude's — and compared a Codex artifact against Claude's copy.
has "$oth" "skill${TAB}.claude/skills/implement-issue${TAB}implement-issue${TAB}claude" \
    "every scan record carries the agent it belongs to"

eq "$(bash "$AD" scan "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "scan of a missing dir exits 2"
eq "$(bash "$AD" scan "$FX" --agents >/dev/null 2>&1; echo $?)" 2 "scan --agents with no value exits 2"

# --- 4b. --agents is a PATH COMPONENT, so its tokens are validated ------------------------------
# `--agents` is interpolated into `$root/.$a`, so an unvalidated token walks out of the project:
# `--agents '../..'` made the scan read a sibling directory and report the result as the project's
# own inventory. Read-only, so nothing was destroyed — but an operator acting on an inventory of
# the WRONG directory is the failure this refusal exists to prevent, and it is the same class of
# confidently-wrong answer D59 refused for a truncated repo root. Caught by self-review.
#
# Both subcommands that take the flag are asserted, because the validation was originally present
# in `pin-render` alone and that asymmetry is exactly how it was missed.
# `claude/../../sibling` IS THE REAL WITNESS and leads the list. The code prepends a `.`, so a
# bare `../..` builds `$root/...././..` — a component named `...` — which normalizes back to
# `$root` and escapes nothing. Only a token that begins with a valid agent name and then climbs
# actually leaves the project: `$root/.claude/../../sibling`. Review caught the earlier account
# naming the wrong one.
for badtok in 'claude/../../sibling' '../..' 'a/b' '/etc' 'UPPER' '-lead' 'a b'; do
  eq "$(bash "$AD" scan "$FX" --agents "$badtok" >/dev/null 2>&1; echo $?)" 2 \
     "scan --agents rejects the traversal/invalid token [$badtok]"
  eq "$(bash "$AD" hygiene "$FX" --agents "$badtok" >/dev/null 2>&1; echo $?)" 2 \
     "hygiene --agents rejects the traversal/invalid token [$badtok]"
done
# An EXPLICIT empty value must not silently widen to "every agent" — it reads as "none".
eq "$(bash "$AD" scan "$FX" --agents '' >/dev/null 2>&1; echo $?)" 2 "scan --agents '' is refused, not read as 'all'"
eq "$(bash "$AD" hygiene "$FX" --agents '' >/dev/null 2>&1; echo $?)" 2 "hygiene --agents '' is refused"
# ...and a legitimate token still works, so the guard is not simply rejecting everything.
yes "$(bash "$AD" scan "$FX" --agents claude >/dev/null 2>&1; echo $?)" "a valid agent token is still accepted"

# --- 5. the getrich inventory, end to end --------------------------------------------------------
# #20's acceptance criterion, discharged against the SHAPE rather than the live repo (see the
# header): remove the duplicate statusline/gate hook, keep the stack CLAUDE.md, keep the
# path-scoped precommit-gate, and propose gap_analysis = codex.
#
# The `same`/`differs` inputs are computed by comparing against the real shipped artifact, so this
# exercises the pipeline the workflow actually runs rather than a hand-written verdict.
cp "$ROOT/agents/claude/scripts/statusline.sh" "$FX/.claude/scripts/statusline.sh"   # a true duplicate
# THE REAL `delta`, not a second implementation. A local `delta_of` here would be testing a copy
# of the decision rather than the decision — and the two could disagree without any assertion
# noticing, which is the whole failure this library/prose split exists to prevent. Review caught it.
delta_of() { bash "$AD" delta "$1" "$2" "$3"; }
eq "$(delta_of script "$FX/.claude/scripts/statusline.sh" "$ROOT/agents/claude/scripts/statusline.sh")" same \
   "the copied statusline is byte-identical (via the real delta)"
eq "$(verdict script yes "$(delta_of script "$FX/.claude/scripts/statusline.sh" "$ROOT/agents/claude/scripts/statusline.sh")" \
        "$(bash "$AD" prescribed script statusline.sh >/dev/null 2>&1 && echo yes || echo no)")" remove \
   "getrich: the duplicated statusline script is REMOVE"
eq "$(verdict script yes "$(delta_of script "$FX/.claude/scripts/precommit-gate.sh" "$ROOT/agents/claude/scripts/precommit-gate.sh")" \
        "$(bash "$AD" prescribed script precommit-gate.sh >/dev/null 2>&1 && echo yes || echo no)")" keep \
   "getrich: the path-scoped precommit-gate is KEEP (removing it would lose apps/packages scoping)"
eq "$(verdict rootdoc no unknown \
        "$(bash "$AD" prescribed rootdoc CLAUDE.md >/dev/null 2>&1 && echo yes || echo no)")" keep \
   "getrich: the stack CLAUDE.md is KEEP"
eq "$(bash "$AD" roles-infer "$FX" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" codex \
   "getrich: gap_analysis = codex is inferred from the inline codex exec"

# --- 6. roles-infer: no signal means NO PROPOSAL, and two signals mean AMBIGUOUS -----------------
# The dangerous direction here is inventing intent. A project that says nothing must produce
# `none` — never the baseline's own default wearing the project's name.
EMPTY="$WORK/empty"; mkdir -p "$EMPTY/.claude"
eq "$(bash "$AD" roles-infer "$EMPTY" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" none \
   "a project with no signal proposes NOTHING for gap_analysis"
eq "$(bash "$AD" roles-infer "$EMPTY" | awk -F"$TAB" '$1=="review"{print $2}')" none \
   "...and nothing for review either"

# THE AGENT TOKEN IS MATCHED ON WORD BOUNDARIES, not as a substring. `grep -qE codex` also matches
# `codexpert`, so "gap analysis uses codexpert tooling" inferred `gap_analysis = codex` — flatly
# contradicting this subcommand's claim to refuse to guess. Review reproduced it.
#
# THIS ASSERTION IS HERE BECAUSE THE MUTATION HARNESS FOUND IT MISSING. The defect was fixed and
# verified by hand during development, and the verification never became a test — so reverting the
# fix left the suite GREEN. A hand-check that does not land in the suite protects exactly one run.
SUBSTR="$WORK/substring"; mkdir -p "$SUBSTR/.claude/skills/x"
printf 'gap analysis uses codexpert tooling\n' > "$SUBSTR/.claude/skills/x/SKILL.md"
eq "$(bash "$AD" roles-infer "$SUBSTR" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" none \
   "a substring of a longer word must NOT infer that agent (codexpert is not codex)"
printf 'gap analysis is run by codex exec\n' > "$SUBSTR/.claude/skills/x/SKILL.md"
eq "$(bash "$AD" roles-infer "$SUBSTR" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" codex \
   "...while the real token, delimited, still infers"
printf 'gap analysis is run by codex-exec\n' > "$SUBSTR/.claude/skills/x/SKILL.md"
eq "$(bash "$AD" roles-infer "$SUBSTR" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" none \
   "...and a dash-joined identifier is NOT the bare token either"

AMB="$WORK/ambiguous"; mkdir -p "$AMB/.claude/skills/x"
printf 'the code-review pass runs codex exec\nthe code-review pass also runs gemini\n' > "$AMB/.claude/skills/x/SKILL.md"
eq "$(bash "$AD" roles-infer "$AMB" | awk -F"$TAB" '$1=="review"{print $2}')" ambiguous \
   "two agents named for one role -> ambiguous, not a coin flip"

# --- 7. propose: an uninferred role is COMMENTED, and the output is a real manifest --------------
prop="$(bash "$AD" roles-infer "$FX" | bash "$AD" propose)"
printf '%s\n' "$prop" > "$WORK/proposed.toml"
has "$prop" 'gap_analysis' "the inferred role is present"
# The load-bearing assertion: read it back through the REAL reader, not by grepping the text this
# suite just produced. A proposal that renders prettily and parses to nothing is the failure that
# matters, and only the consumer can see it.
eq "$(adb_toml_get "$WORK/proposed.toml" roles gap_analysis)" '"codex"' \
   "the proposed manifest parses through adb_toml_get"
eq "$(adb_toml_get "$WORK/proposed.toml" roles review >/dev/null 2>&1; echo $?)" 1 \
   "an UNINFERRED role must be absent to the reader (commented), not set to a guess"
eq "$(adb_toml_get "$WORK/proposed.toml" roles primary >/dev/null 2>&1; echo $?)" 1 \
   "primary is never inferred — it is a fact about the operator, not the repo"

# A NON-ROLE RECORD MUST NEVER BECOME A TOML KEY. `roles-infer` shares `_ad_emit`, which on an
# unrepresentable field emits a `warning` record — and `propose` rendered that as
# `warning = "a gap_analysis field…"`, malformed TOML, while silently dropping the role it
# replaced. Review reproduced it.
warnprop="$(printf 'warning\ta gap_analysis field contains a tab\n' | bash "$AD" propose)"
# ASSERT ON THE PARSED KEY SET, not on a guessed spacing. The first version tested for
# `warning  =` — two spaces — while `printf %-13s` emits seven, so the assertion could not fire on
# the very output it was written for. The mutation harness caught it: injecting the defect went red
# on a SIBLING assertion, which is "caught by accident" and is what the witness check rejects.
warnkeys="$(printf '%s\n' "$warnprop" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p')"
hasnt "$warnkeys" "warning" "propose must never render a non-role record as a TOML key"
has   "$warnprop" '# NOTE'  "...it surfaces the unusable record as a comment instead"

# --- 8. stack: every label the pin accepts is reachable, and unknown is a real answer ------------
mk() { mkdir -p "$WORK/stack-$1" && printf '%s' "${2:-}" > "$WORK/stack-$1/${3:-x}"; printf '%s' "$WORK/stack-$1"; }
eq "$(bash "$AD" stack "$(mk node '{}' package.json)")"        node   "package.json -> node"
mkdir -p "$WORK/stack-mono"; printf '{}' > "$WORK/stack-mono/package.json"; printf '' > "$WORK/stack-mono/pnpm-workspace.yaml"
eq "$(bash "$AD" stack "$WORK/stack-mono")"                    node-monorepo "a workspace file -> node-monorepo"
eq "$(bash "$AD" stack "$(mk rust '' Cargo.toml)")"            rust   "Cargo.toml -> rust"
eq "$(bash "$AD" stack "$(mk go 'module x' go.mod)")"          go     "go.mod -> go"
eq "$(bash "$AD" stack "$(mk py '' pyproject.toml)")"          python "pyproject.toml -> python"
eq "$(bash "$AD" stack "$(mk sh '#!/bin/sh' a.sh)")"           shell  "a bare shell repo -> shell"
mkdir -p "$WORK/stack-none"
eq "$(bash "$AD" stack "$WORK/stack-none")"                    unknown "an unrecognised project -> unknown, which is an ANSWER"
# THE MOST SPECIFIC EVIDENCE WINS. A WordPress plugin routinely carries a package.json for its
# asset build, and a node-first order recorded every one of them as `node` — the wrong ecosystem
# in the pin. Review caught it.
WP="$WORK/stack-wp"; mkdir -p "$WP"
printf '{}\n' > "$WP/package.json"; printf '{}\n' > "$WP/composer.json"
printf '<?php add_action("init", "x");\n' > "$WP/plugin.php"
eq "$(bash "$AD" stack "$WP")" php-wordpress "a WordPress plugin carrying a package.json is php-wordpress, not node"
rm -f "$WP/plugin.php"
eq "$(bash "$AD" stack "$WP")" node "...and without the WP evidence it is node again (the WP test is the narrow one)"

eq "$(bash "$AD" stack "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "stack of a missing dir exits 2"

# EVERY label `stack` can print must be a label `pin-render` accepts. These are two enums in two
# functions, and a stack the pin rejects would fail the run at the last step with a value the
# scan itself produced.
# A FULL object name, because `pin-render` now requires one — the pin's claim is that it recovers
# the inherited tree exactly, and an abbreviated name can become ambiguous in a growing repo.
FULLSHA="0123456789abcdef0123456789abcdef01234567"
for s in node node-monorepo rust go python php php-wordpress shell unknown; do
  yes "$(bash "$AD" pin-render v1 "$FULLSHA" 2026-08-12 "$s" >/dev/null 2>&1; echo $?)" \
      "pin-render accepts the stack label '$s' that stack can emit"
done

# --- 9. the pin: validation, round-trip, and the drift command ----------------------------------
bash "$AD" pin-render "v0.5.0" "b6158eff2604875e1e522a57df71d7dfced7ace5" "2026-08-12" shell "claude,codex" \
  > "$WORK/upstream.toml"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" commit)"  "b6158eff2604875e1e522a57df71d7dfced7ace5" "pin round-trips the commit"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" stack)"   shell    "pin round-trips the stack"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" version)" "v0.5.0" "pin round-trips the version"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" agents | tr '\n' ',')" "claude,codex," "pin round-trips the agent list"

# The commit is the load-bearing field — `pin-drift` feeds it to git — so every unusable form is
# observed being refused. A pin that accepted "HEAD" or an empty string would produce a drift
# command that silently compares the wrong thing.
for badpin in "v1 zzzz 2026-08-12 shell" "v1 HEAD 2026-08-12 shell" "v1 '' 2026-08-12 shell" \
              "v1 abc 2026-08-12 shell" "v1 abcdef1234 2026-08-12 shell" \
              "v1 $FULLSHA 12-08-2026 shell" "v1 $FULLSHA 2026-8-12 shell" \
              "v1 $FULLSHA 2026-99-99 shell" "v1 $FULLSHA 2026-13-01 shell" \
              "v1 $FULLSHA 2026-08-12 cobol" "v1 $FULLSHA 2026-08-12 shell claude,claude" \
              "v1 $FULLSHA 2026-08-12 shell -lead"; do
  # shellcheck disable=SC2086  # deliberate word splitting: each case is an argv
  eq "$(eval bash \"\$AD\" pin-render $badpin >/dev/null 2>&1; echo $?)" 2 "pin-render rejects [$badpin]"
done
# THE VERSION IS INTERPOLATED INTO TOML, and it comes from a git TAG — so it is validated too. A
# quote or a newline produces malformed TOML at best and an injected extra key at worst, in a file
# `adb_toml_get` is later trusted to read. Passed as real argv (not through `eval`) so the quote
# reaches the validator rather than the test's own shell.
eq "$(bash "$AD" pin-render 'v"x' "$FULLSHA" 2026-08-12 shell >/dev/null 2>&1; echo $?)" 2 \
   "pin-render rejects a version containing a quote"
eq "$(bash "$AD" pin-render "$(printf 'v1\nevil = 1')" "$FULLSHA" 2026-08-12 shell >/dev/null 2>&1; echo $?)" 2 \
   "pin-render rejects a version containing a newline (a TOML key-injection shape)"
yes "$(bash "$AD" pin-render 'v1.2.3-rc1+build.7' "$FULLSHA" 2026-08-12 shell >/dev/null 2>&1; echo $?)" \
   "...but an ordinary semver-ish tag is still accepted"

# `pin-drift` OUTPUT IS A COMMAND, so the path it names must be shell-quoted. Unquoted, a path with
# a space silently targets the wrong directory and one with a `;` becomes executable syntax in a
# line the operator is told to paste into a shell.
QD="$WORK/qu ote;dir"; mkdir -p "$QD"
bash "$AD" pin-render v1 "$FULLSHA" 2026-08-12 shell > "$QD/pin.toml"
qdrift="$(bash "$AD" pin-drift "$QD/pin.toml" "$QD")"
hasnt "$qdrift" "$QD log"  "pin-drift must not emit the raw unquoted path"
has   "$qdrift" 'qu\ ote\;dir' "pin-drift shell-quotes the baseline path"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" nope >/dev/null 2>&1; echo $?)" 2 "pin-read rejects an unknown key"
eq "$(bash "$AD" pin-read "$WORK/missing.toml" commit >/dev/null 2>&1; echo $?)" 2 "pin-read on a missing file exits 2"

drift="$(bash "$AD" pin-drift "$WORK/upstream.toml" "$ROOT")"
has "$drift" "b6158eff2604875e1e522a57df71d7dfced7ace5..HEAD" "pin-drift names the pinned commit"
has "$drift" "git -C $ROOT" "pin-drift targets the baseline clone"
eq "$(bash "$AD" pin-drift "$WORK/upstream.toml" "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "pin-drift on a missing baseline exits 2"

# --- 10. hygiene: each axis fires, and the ignore axis is proven able to STAY SILENT ------------
HY="$WORK/hygiene"; mkdir -p "$HY/.claude/state" "$HY/src"
git -C "$HY" init -q >/dev/null 2>&1
printf 'const x = "codex exec"\n' > "$HY/src/run.ts"
printf '{"statusLine":{"type":"command","command":"x"},"hooks":{}}\n' > "$HY/.claude/settings.json"
printf 'home is /Users/someone/Code/thing\n' > "$HY/.claude/machine.md"
printf 'token: ghp_abcdefghijklmnopqrstuvwxyz\n' > "$HY/.claude/leak.md"
printf '.claude/state/\n' > "$HY/.gitignore"
git -C "$HY" add -A >/dev/null 2>&1
hy="$(bash "$AD" hygiene "$HY" --agents claude)"
has "$hy" "product-code${TAB}note${TAB}src/"   "axis 1: product code is reported, not classified"
has "$hy" "distributable${TAB}warn"            "axis 2: the distributable axis reports a machine-local path in a TRACKED file"
has "$hy" "precedence${TAB}note"               "axis 3: a layered statusLine is reported"

# axis 1 fires ONCE for a three-agent scan, not once per agent.
eq "$(bash "$AD" hygiene "$HY" | grep -c "^product-code${TAB}")" 1 \
   "axis 1 reports the product-code boundary once, not once per agent"

# A NON-ASCII TRACKED FILENAME IS STILL SCANNED. `git ls-files` applies `core.quotePath` by
# default, so such a file comes back C-quoted (`".claude/caf\303\251.md"`), the unquoted form does
# not exist on disk, and the loop SILENTLY SKIPPED it. On this axis that is the worst failure
# available: it is the one looking for credentials in files that ship to end users, and a skipped
# file produces exactly the output a clean file produces. Reproduced during self-review; `-z` and a
# NUL-delimited read are the fix. Both a path finding and a credential finding are asserted,
# because the two probes read the file separately and either could regress alone.
printf 'home is /Users/someone/Code/thing\n'      > "$HY/.claude/café.md"
printf 'token: ghp_zyxwvutsrqponmlkjihgfedcba\n'  > "$HY/.claude/naïve.md"
git -C "$HY" add -A >/dev/null 2>&1
hy_utf="$(bash "$AD" hygiene "$HY" --agents claude)"
has "$hy_utf" "café.md"  "a non-ASCII tracked filename is scanned, not silently skipped"
has "$hy_utf" "naïve.md" "...and its credential probe runs too"
hasnt "$hy_utf" 'caf\303\251' "the finding names the real path, not git's C-quoted form"

# THE SECRET IS NEVER ECHOED. This is the assertion that matters most in this block:
# base/practices/logging-and-secrets.md forbids emitting a credential, and a diagnostic pasted
# into a PR body is exactly the durable, indexed place it must not land.
has  "$hy" "prefix 'ghp_'"                       "axis 2 names the credential PREFIX so it can be found"
hasnt "$hy" "ghp_abcdefghijklmnopqrstuvwxyz"     "axis 2 must NEVER echo the credential itself"

# The ignore axis: three inputs, three DISTINGUISHABLE answers. Two would let a stuck predicate
# pass, and a stuck predicate is exactly what shipped here first (it matched the pathname column
# of `git check-ignore -v`, so every input looked explicit and the axis was a permanent no-op).
ig() { printf '%s\n' "$1" > "$HY/.gitignore"; bash "$AD" hygiene "$HY" --agents claude | grep "^ignore-risk" || true; }
has   "$(ig '*.json')"        "does NOT cover the directory" "a blanket *.json IS reported (the unraid shape)"
eq    "$(ig '.claude/state/')" ""                              "an explicit state rule is SILENT"
eq    "$(ig '.claude/')"       ""                              "a rule covering the whole agent dir is also SILENT"
has   "$(ig '')"              "is NOT gitignored"              "no rule at all is reported, and differently"

# THE COLON-BEARING EXCLUDES PATH. `core.excludesFile` is an arbitrary user path, so a version that
# recovered the ignore PATTERN by stripping two colons out of `<source>:<line>:<pattern>` could be
# fed a source path containing both colons and `/.claude/state` — and the mis-sliced "pattern" then
# matched the explicit-rule arm, suppressing a real finding. Review reproduced exactly this. The
# axis no longer parses any pattern text: it asks git about TWO paths and compares the answers.
EXD="$HY/we:ird:/.claude/state"; mkdir -p "$EXD"
printf '*.json\n' > "$EXD/ex"
git -C "$HY" config core.excludesFile "$EXD/ex"
: > "$HY/.gitignore"
has "$(bash "$AD" hygiene "$HY" --agents claude | grep '^ignore-risk' || true)" "does NOT cover the directory" \
    "a colon-bearing excludesFile cannot suppress the finding"
git -C "$HY" config --unset core.excludesFile

# A FAILED TRACKED-FILE READ MUST SAY SO, not report a clean scan. The credential axis can only
# look at files `git ls-files` names, so when that read fails it inspects ZERO files — and piping it
# straight into the loop made the pipeline's status the LOOP's, so a failure produced exactly the
# output of a clean project. A NON-GIT directory is the reachable case: git has nothing to list.
#
# This assertion exists because the mutation harness found nothing covering it: removing the status
# check left the suite GREEN. That is the harness earning its place — a coverage hole is invisible
# to every passing assertion by construction.
NOGIT="$WORK/not-a-repo"; mkdir -p "$NOGIT/.claude"
printf 'home is /Users/someone/x/\n' > "$NOGIT/.claude/f.md"
nogit_out="$(bash "$AD" hygiene "$NOGIT" --agents claude)"
has "$nogit_out" "the distributable-config axis did NOT run" \
    "a failed tracked-file read is REPORTED, never rendered as a clean scan"
hasnt "$nogit_out" "distributable${TAB}warn" \
    "...and it does not also claim a finding it could not have made"

eq "$(bash "$AD" hygiene "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "hygiene of a missing dir exits 2"

# A git ERROR is not a finding about the project. `check-ignore` exits 0 for ignored, 1 for not
# ignored, and 128 for a failure — and the first draft collapsed everything non-zero into "is NOT
# gitignored", turning a broken git into a confident claim that the project's state dir was
# exposed. A bare repo reproduces it: there is no worktree, so check-ignore cannot answer.
BARE="$WORK/bare"; git init -q --bare "$BARE" >/dev/null 2>&1
mkdir -p "$BARE/.claude/state"
bare_out="$(bash "$AD" hygiene "$BARE" --agents claude | grep '^ignore-risk' || true)"
has   "$bare_out" "COULD NOT BE DETERMINED" "a git ERROR is reported as undetermined, not as a fact"
hasnt "$bare_out" "is NOT gitignored"       "a git ERROR must NOT be reported as 'not gitignored'"

# --- 11. plan: the ORDERING is the decision ------------------------------------------------------
# move strictly before remove is the assertion with teeth. Reversed, the plan has the operator
# delete a forked skill before its delta has been re-homed, and a run that stops in between has
# silently cost the project a capability.
plan="$(printf 'keep\trootdoc\tCLAUDE.md\tr\nremove\tscript\tdup.sh\tr\nmove\tskill\tfork\tr\nescalate\tother\t?\tr\n' \
        | bash "$AD" plan)"
i_esc="$(printf '%s\n' "$plan" | grep -n '^## escalate' | cut -d: -f1)"
i_mov="$(printf '%s\n' "$plan" | grep -n '^## move'     | cut -d: -f1)"
i_rem="$(printf '%s\n' "$plan" | grep -n '^## remove'   | cut -d: -f1)"
i_kep="$(printf '%s\n' "$plan" | grep -n '^## keep'     | cut -d: -f1)"
if [ "$i_esc" -lt "$i_mov" ] && [ "$i_mov" -lt "$i_rem" ] && [ "$i_rem" -lt "$i_kep" ]; then ok
else bad "plan ordering must be escalate < move < remove < keep (got $i_esc/$i_mov/$i_rem/$i_kep)"; fi

# A verdict with no members prints no heading (rather than an empty section the reader must parse).
hasnt "$(printf 'keep\trootdoc\tCLAUDE.md\tr\n' | bash "$AD" plan)" "## remove" \
      "an empty verdict prints no heading"
eq "$(printf '' | bash "$AD" plan)" "" "an empty inventory yields an empty plan, not an error"
eq "$(bash "$AD" plan extra </dev/null >/dev/null 2>&1; echo $?)" 2 "plan takes no arguments"

# A MALFORMED record is NAMED rather than rendered as blanks. A short record used to print
# `1.  (skill) — `, formatted exactly like a real entry with an empty path and an empty reason —
# a broken producer wearing the output of a working one.
# AN UNRECOGNISED VERDICT IS REPORTED, NOT DROPPED. The four-verdict loop only prints records
# matching one of its own words, so a truncated or typo'd verdict produced NO output and NO error —
# the artifact vanished from the plan. The malformed-record check could not catch it: that runs
# only after a record has already matched a verdict. Review caught it.
unk="$(printf 'mov\tskill\tforked\tr\nkeep\trootdoc\tCLAUDE.md\tr\n' | bash "$AD" plan)"
has "$unk" "UNRECOGNISED"  "an UNRECOGNISED verdict is reported rather than silently dropped"
has "$unk" "mov"           "...naming the record that carried it"
has "$unk" "## keep"       "...without suppressing the sections that are valid"

short="$(printf 'move\tskill\n' | bash "$AD" plan)"
has   "$short" "MALFORMED RECORD" "a short record is named as malformed"
hasnt "$short" "1.  (skill) — "   "a short record must not render as a blank-path entry"

# --- 12. no subcommand mutates the project it is given ------------------------------------------
# THE BOUNDARY, asserted mechanically rather than trusted to review. /adopt v1 never deletes,
# moves or edits a file in the scanned project — so every read-only subcommand is run against a
# fixture whose complete state is hashed before and after. This is the assertion that would catch
# a future `remove` arm growing an actual `rm`.
snapshot() { ( cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do
                 printf '%s ' "$f"; cksum < "$f"; done ); }
before="$(snapshot "$FX")"
bash "$AD" scan "$FX" >/dev/null 2>&1
bash "$AD" hygiene "$FX" >/dev/null 2>&1
bash "$AD" roles-infer "$FX" >/dev/null 2>&1
bash "$AD" stack "$FX" >/dev/null 2>&1
after="$(snapshot "$FX")"
eq "$after" "$before" "no read-only subcommand may alter one byte of the scanned project"

# --- 13. the workflow still delegates to this library -------------------------------------------
# The drift guard the sibling suites carry: a workflow that quietly stopped calling a predicate
# and started restating it inline would pass every assertion above while shipping the untested
# copy this whole split exists to prevent.
if [ -f "$WF" ]; then
  # SEARCH THE FENCED BLOCKS ONLY, not the whole file. The prose around each step NAMES the
  # subcommand it is about — "`{{ADOPT_LIB}} prescribed <kind> <name>` (exit 0 = yes)" sits in a
  # bullet — so a whole-file `grep` stayed green after the real invocation was deleted from the
  # code block. A guard satisfied by the documentation OF a call rather than by the call is exactly
  # the can't-fail shape this suite exists to reject; review caught it.
  wf_code="$(awk '/^```bash$/ { inb = 1; next } /^```/ { inb = 0; next } inb { print }' "$WF")"
  for sub in scan classify prescribed delta roles-infer propose hygiene pin-render plan resolve baseline; do
    case "$wf_code" in
      *"adopt-lib.sh\" $sub"*|*"ADOPT_LIB}} $sub"*) ok ;;
      *) bad "base/workflows/adopt.md no longer INVOKES '$sub' in a fenced block (prose mentioning it does not count)" ;;
    esac
  done
  # ...and the guard above is itself a guard, so prove it can fail: with the fenced blocks removed,
  # the prose alone must NOT satisfy it. Without this, a future edit that widened the search back
  # to the whole file would go unnoticed.
  wf_prose="$(awk '/^```bash$/ { inb = 1; next } /^```/ { inb = 0; next } !inb { print }' "$WF")"
  case "$wf_prose" in
    *"ADOPT_LIB}} prescribed"*) ok ;;   # the prose really does mention it...
    *) bad "the delegation guard's own premise is gone: adopt.md's PROSE no longer names a subcommand, so this check can no longer prove it ignores prose" ;;
  esac
  case "$wf_prose" in
    *"ADOPT_LIB}} scan \"\$PROJECT\""*) bad "the delegation guard is reading prose as code" ;;
    *) ok ;;
  esac
  # The v1 boundary is a PROMISE THE WORKFLOW MAKES, so it is pinned in the workflow text too.
  grep -Fq 'never deletes, moves, or edits a file in the project' "$WF" \
    || bad "adopt.md must state the v1 boundary, scoped to the SCANNED PROJECT (an unscoped 'never edits any file' is false — the state dir is rewritten every run)"
else
  bad "base/workflows/adopt.md is missing"
fi

# --- 14. the workflow's OWN write paths refuse rather than overwrite -----------------------------
# The non-mutation assertion above covers the LIBRARY. It says nothing about the workflow, which is
# where the only writes live — so the `apply` snippet is EXECUTED here, against fixtures, exactly as
# base/workflows/roadmap.md's snippets are executed by check-roadmap-e2e.sh. A fenced block that
# stopped refusing would otherwise be caught by nobody.
APPLY="$(check_wf_snippet "$WF" apply)"
if [ -z "$APPLY" ]; then
  bad "adopt.md has no ADB-SNIPPET: apply block — the write path is undocumented and untestable"
else
  # Case 1: both targets ABSENT -> both created.
  A1="$WORK/apply-fresh"; mkdir -p "$A1/state"
  printf 'PROPOSED_MANIFEST\n' > "$A1/state/adopt-agents.toml"
  printf 'PROPOSED_PIN\n'      > "$A1/state/adopt-upstream.toml"
  mkdir -p "$A1/proj"
  ( cd "$A1" && PROJECT="$A1/proj" bash -c "$(printf '%s' "$APPLY" | sed "s#{{STATE_DIR}}#$A1/state#g")" ) >/dev/null 2>&1
  eq "$(cat "$A1/proj/agents.toml" 2>/dev/null)" "PROPOSED_MANIFEST" "apply CREATES agents.toml when absent"
  eq "$(cat "$A1/proj/.ai-dev-baseline/upstream.toml" 2>/dev/null)" "PROPOSED_PIN" "apply CREATES the pin when absent"

  # Case 2: both targets PRESENT -> both left byte-identical. This is the promise.
  A2="$WORK/apply-existing"; mkdir -p "$A2/state" "$A2/proj/.ai-dev-baseline"
  printf 'PROPOSED_MANIFEST\n' > "$A2/state/adopt-agents.toml"
  printf 'PROPOSED_PIN\n'      > "$A2/state/adopt-upstream.toml"
  printf 'THE OPERATORS OWN MANIFEST\n' > "$A2/proj/agents.toml"
  printf 'THE OPERATORS OWN PIN\n'      > "$A2/proj/.ai-dev-baseline/upstream.toml"
  ( cd "$A2" && PROJECT="$A2/proj" bash -c "$(printf '%s' "$APPLY" | sed "s#{{STATE_DIR}}#$A2/state#g")" ) >/dev/null 2>&1
  eq "$(cat "$A2/proj/agents.toml")" "THE OPERATORS OWN MANIFEST" "apply REFUSES to overwrite an existing agents.toml"
  eq "$(cat "$A2/proj/.ai-dev-baseline/upstream.toml")" "THE OPERATORS OWN PIN" "apply REFUSES to overwrite an existing pin"

  # Case 3b: a SYMLINKED PARENT. `mkdir -p` accepts an existing symlink as the directory, so a
  # repository shipping `.ai-dev-baseline` as a symlink makes an approved --apply write the pin
  # through it to anywhere on the filesystem — no race required, and `-L` on the final component
  # cannot see it. Review found this one; it was the only P1 in the set.
  A3b="$WORK/apply-symlink-parent"; mkdir -p "$A3b/state" "$A3b/proj" "$A3b/elsewhere"
  printf 'PROPOSED_MANIFEST\n' > "$A3b/state/adopt-agents.toml"
  printf 'PROPOSED_PIN\n'      > "$A3b/state/adopt-upstream.toml"
  ln -s "$A3b/elsewhere" "$A3b/proj/.ai-dev-baseline"
  ( cd "$A3b" && PROJECT="$A3b/proj" bash -c "$(printf '%s' "$APPLY" | sed "s#{{STATE_DIR}}#$A3b/state#g")" ) >/dev/null 2>&1
  if [ -e "$A3b/elsewhere/upstream.toml" ]; then
    bad "apply wrote the pin THROUGH a symlinked parent to $A3b/elsewhere — outside the project"
  else ok; fi

  # Case 4: the CONTENT write must happen under noclobber, not into a placeholder that is then
  # reopened. Asserted on the SOURCE rather than by racing it: a race is not reproducible in a
  # test, and the property is structural — one redirect, not two.
  case "$APPLY" in
    *'set -o noclobber; cat '*) ok ;;
    *) bad "the apply block creates a placeholder under noclobber and reopens it — between the two commands the path can be replaced, and the second redirect is unprotected" ;;
  esac

  # Case 3: a DANGLING SYMLINK at the target. `[ -e ]` reports it ABSENT (it follows the link and
  # finds nothing), so a `[ -e ] && … || cp` would write THROUGH it to an arbitrary path outside
  # the project. `-L` is what sees a symlink whether or not it resolves. Review caught this one.
  A3="$WORK/apply-symlink"; mkdir -p "$A3/state" "$A3/proj" "$A3/outside"
  printf 'PROPOSED_MANIFEST\n' > "$A3/state/adopt-agents.toml"
  printf 'PROPOSED_PIN\n'      > "$A3/state/adopt-upstream.toml"
  ln -s "$A3/outside/victim.toml" "$A3/proj/agents.toml"
  ( cd "$A3" && PROJECT="$A3/proj" bash -c "$(printf '%s' "$APPLY" | sed "s#{{STATE_DIR}}#$A3/state#g")" ) >/dev/null 2>&1
  if [ -e "$A3/outside/victim.toml" ]; then
    bad "apply wrote THROUGH a dangling symlink to $A3/outside/victim.toml — outside the project entirely"
  else ok; fi
fi

# --- the mutation harness (`--mutation`) --------------------------------------------------------
# EVERY LOAD-BEARING DECISION IN adopt-lib.sh IS INJECTED WITH ITS OWN DEFECT, AND THE SUITE ABOVE
# MUST COME BACK RED FOR EACH.
#
# WHY THIS EXISTS RATHER THAN A SENTENCE IN A COMMIT MESSAGE. The first commit here claimed "six
# mutations were observed going red". That was true when it was written and completely
# unverifiable afterwards: the mutations were ad-hoc shell run once by hand, so nothing in the
# repository could reproduce them and no later edit could be caught weakening a guard back into
# silence. Review flagged it, correctly, as a claim the diff does not support. This is the same
# move `check-fact-drift.sh --mutation` and `check-fact-guard.sh` already make: turn "I checked
# once" into a standing test.
#
# Each row names the defect and the ASSERTION that must catch it. A mutation that goes red for the
# WRONG reason is not evidence, so the witness is matched against the failure text — that is the
# `fires:<witness>` contract #213 established, applied here.
#
# Every mutation is applied to a COPY of the tree (self-review.md's copy rule). The working tree is
# never touched, so this cannot be the thing that eats an uncommitted edit.
# The table. `mut <name> <old-literal> <new-literal> <witness>` — FIXED STRINGS, not regexes.
#
# The first version of this table used `sed` expressions, and EIGHT OF TWENTY silently matched
# nothing: every one of them contained a character that is special to sed, to the shell, or to the
# heredoc it was written in, and a pattern that matches nothing is a mutation that tests nothing.
# The harness's own "did the injection apply?" check is what caught that — which is the same
# proof-by-observation this file demands of everything else, applied to itself. Literal strings and
# an index/substr replacement remove the entire class: there is no escaping to get wrong.
MUT_NAMES=(); MUT_OLD=(); MUT_NEW=(); MUT_WIT=()
mut() { MUT_NAMES+=("$1"); MUT_OLD+=("$2"); MUT_NEW+=("$3"); MUT_WIT+=("$4"); }

# Replace the FIRST occurrence of a literal, by index — never a regex.
#
# THE STRINGS ARRIVE THROUGH `ENVIRON`, NOT `-v`, and that is the whole reason two rows kept
# reporting "did not apply" after their literals had been generated byte-exactly FROM THE SOURCE
# FILE. `awk -v x=…` processes backslash escape sequences in the assignment: a literal containing
# `\$` reached the program as `$`, and one containing `\n` arrived as a REAL NEWLINE that can never
# match inside a single line. So the two rows whose source text happens to contain a backslash —
# the role-boundary regex and the `pin-drift` printf — were the exact two that silently matched
# nothing. `ENVIRON` performs no such processing, so the bytes arrive as written.
#
# Found by the harness's own did-it-apply check, three times in a row, on literals that were
# provably correct. A "mutation" that matches nothing is a test that proves nothing, which is the
# same silence this file exists to reject.
_mut_apply() {  # <file> <old> <new>
  MUT_OLD_S="$2" MUT_NEW_S="$3" awk '
    BEGIN { old = ENVIRON["MUT_OLD_S"]; new = ENVIRON["MUT_NEW_S"] }
    !hit { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); hit = 1 } }
    { print }
  ' "$1"
}

mut prescribed-arm-order \
    'if [ "$prescribed" = yes ]; then' \
    'if [ "$prescribed" = SWAPPED ]; then' \
    'a PRESCRIBED HOME that collides is keep'
mut differs-becomes-remove \
    "printf 'move%scollides with a baseline skill" \
    "printf 'remove%scollides with a baseline skill" \
    'collides but DIFFERS -> move, never remove'
mut skill-compares-only-SKILL.md \
    'pl="$(_ad_dir_manifest "$proj")"; bl="$(_ad_dir_manifest "$base")"' \
    'pl=x; bl=x' \
    'an extra project-only file makes a skill differ'
mut cmp-error-becomes-differs \
    "    *) printf 'unknown" \
    "    *) printf 'differs" \
    'a cmp FAILURE (rc>1) is unknown'
mut role-token-substring \
    'local bounded="(^|[^A-Za-z0-9_-])${agent}([^A-Za-z0-9_-]|\$)"' \
    'local bounded="$agent"' \
    'must NOT infer that agent'
mut roles-default-instead-of-none \
    '_ad_emit "$role" none "no signal' \
    '_ad_emit "$role" codex "no signal' \
    'a project with no signal proposes NOTHING'
mut propose-renders-any-key \
    'gap_analysis|review|debug|primary|release|issue_author) ;;' \
    '*) ;;' \
    'propose must never render a non-role record as a TOML key'
mut plan-order-remove-before-move \
    'for verdict in escalate move remove keep; do' \
    'for verdict in escalate remove move keep; do' \
    'plan ordering must be escalate < move < remove < keep'
mut plan-drops-unknown-verdict \
    '    bad_n=$((bad_n + 1))' \
    '    continue' \
    'an UNRECOGNISED verdict is reported'
mut agent-token-unvalidated \
    '*[!a-z0-9-]*|-*) die "$who: invalid agent token' \
    'NEVERMATCHES) die "$who: invalid agent token' \
    'rejects the traversal/invalid token'
mut ignore-error-is-not-ignored \
    'elif [ "$igrc" -eq 1 ]; then' \
    'elif [ "$igrc" -ge 1 ]; then' \
    'a git ERROR is reported as undetermined'
mut ignore-second-probe-dropped \
    'git -C "$root" check-ignore -q --no-index ".$a/state/adb-adopt-probe" 2>/dev/null' \
    'true' \
    'a blanket *.json IS reported'
mut credential-value-echoed \
    "| grep -oE '^(ghp_|gho_|ghu_|ghs_|github_pat_|sk-|xox[baprs]-|AKIA)' | head -n 1)\"" \
    '| head -n 1)"' \
    'must NEVER echo the credential itself'
mut tracked-list-status-ignored \
    'if ! git -C "$root" ls-files -z ".$a" >/dev/null 2>&1; then' \
    'if false; then' \
    'the distributable-config axis did NOT run'
mut pin-accepts-short-commit \
    '    40|64) ;;' \
    '    40|64|10) ;;' \
    'pin-render rejects'
mut pin-version-unvalidated \
    '*[!A-Za-z0-9._+-]*) die "pin-render: <version>' \
    'NEVERMATCHES) die "pin-render: <version>' \
    'rejects a version containing a quote'
mut pin-drift-unquoted \
    'printf '"'"'git -C %s log --oneline %s..HEAD\n'"'"' "$(adb_display_value "$root")" "$(adb_display_value "$commit")"' \
    'printf '"'"'git -C %s log --oneline %s..HEAD\n'"'"' "$root" "$(adb_display_value "$commit")"' \
    'pin-drift must not emit the raw unquoted path'
mut foreign-pin-kept \
    'if [ "$kind" = foreign-pin ]; then' \
    'if false; then' \
    'a foreign framework pin is MOVE'
mut other-classified-as-keep \
    'if [ "$kind" = other ]; then' \
    'if false; then' \
    'escalates on collision=no'
mut scan-drops-other \
    '_ad_emit other "$rel" "${rel##*/}" "$a"' \
    ':' \
    'an unmodelled file under the agent dir is emitted as'
mut stack-node-before-wordpress \
    "if grep -rqIl --include='*.php' -e 'add_action' -e 'wp_enqueue' \"\$r\" 2>/dev/null; then" \
    'if false; then' \
    'is php-wordpress, not node'

# One mutation, start to verdict. Writes a single line to `$copy/verdict`: `ok`, or `bad <reason>`.
#
# IT RETURNS ITS VERDICT THROUGH A FILE, not through `ok`/`bad`, because it runs in a BACKGROUND
# SUBSHELL and a counter incremented there dies with it. That is the same fiction #259 records
# (`scan_tree` reporting "0 labelled read sites" beside 45 passing assertions), and the fix is the
# same: the parent does the counting, over results the child could not have discarded.
_mut_one() {  # <index>
  local i="$1" name copy out
  name="${MUT_NAMES[$i]}"; copy="$WORK/mut-$i"
  if ! check_copy_subtrees "$ROOT" "$copy" scripts base agents >/dev/null 2>&1; then
    printf 'bad|could not copy the tree\n' > "$copy/verdict" 2>/dev/null; return
  fi
  cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$copy/" 2>/dev/null
  if ! _mut_apply "$copy/scripts/lib/adopt-lib.sh" "${MUT_OLD[$i]}" "${MUT_NEW[$i]}" > "$copy/mutated"; then
    printf 'bad|the rewrite failed\n' > "$copy/verdict"; return
  fi
  # VERIFY THE EDIT APPLIED. A literal that matches nothing produces an unchanged copy, the suite
  # passes, and the harness would blame the guard for a mutation that never happened — the same
  # silence it exists to detect, one level up. Ten of the first twenty rows failed exactly here,
  # across three separate causes (sed metacharacters, then shell quoting, then `awk -v`'s escape
  # processing). Without this check every one of them would have been reported as a passing test.
  if cmp -s "$copy/mutated" "$copy/scripts/lib/adopt-lib.sh"; then
    printf 'bad|the injection did not apply — this row tests NOTHING\n' > "$copy/verdict"; return
  fi
  mv "$copy/mutated" "$copy/scripts/lib/adopt-lib.sh"
  out="$( cd "$copy" && bash scripts/check-adopt.sh 2>&1 )"
  # MATCHED WITH `case`, NOT `printf | grep -q`, AND THAT IS A CORRECTNESS FIX (#324).
  #
  # This file sets `pipefail`. `grep -q` exits the instant it matches, which closes the pipe while
  # `printf` still has the rest of a large `$out` queued — `printf` then dies of SIGPIPE, and
  # pipefail promotes that to the PIPELINE's status. So the witness check returned NON-ZERO for
  # exactly the outputs where the witness WAS found early, and the harness reported
  # "went red, but NOT on its witness" about a mutation whose witness was sitting in `$out`.
  #
  # A guard that answers wrong under load is worse than no guard, and this one answered wrong in the
  # flattering-looking direction: it accuses the suite instead of itself. Measured: a 348906-byte
  # buffer with the witness on line 1 gives `rc=141` under pipefail and `rc=0` without it.
  # It is latent rather than new — it fires only once `$out` outgrows the pipe buffer (64 KiB) with
  # an early match, which is why every earlier run was green and why growing the adopt suite's
  # output surfaced it on CI's Linux runner and not on macOS.
  #
  # `case` does the same substring test inside the shell: no second process, no pipe, no signal, and
  # nothing for pipefail to promote. The witness is a literal, so a glob-special byte in it would be
  # the one hazard — the strings are prose fragments written in this file, and `-F` was already
  # asserting they are literals.
  case "$out" in
    *' 0 failed'*)
    printf 'bad|the suite stayed GREEN — nothing here can detect this defect\n' > "$copy/verdict" ;;
    *"${MUT_WIT[$i]}"*)
    printf 'ok|applied\n' > "$copy/verdict" ;;
    *)
    printf 'bad|went red, but NOT on its witness (%s) — caught by accident, not by the assertion that claims to cover it\n' \
      "${MUT_WIT[$i]}" > "$copy/verdict" ;;
  esac
}

mut skill-ignores-symlinks \
    'find . \( -type f -o -type l \) -print 2>/dev/null' \
    'find . -type f -print 2>/dev/null' \
    'a project-only SYMLINK makes a skill differ'
mut scan-drops-vendored-lib \
    '[ -d "$root/.$a/scripts/lib" ] && _ad_emit lib ".$a/scripts/lib" lib "$a"' \
    ':' \
    'a vendored scripts/lib is emitted as ONE lib artifact'
mut plan-prints-raw-path \
    'printf '"'"'%s. %s (%s) — %s\n'"'"' "$n" "$(adb_display_value "$adoptpath")" "$kind" "$reason"' \
    'printf '"'"'%s. %s (%s) — %s\n'"'"' "$n" "$adoptpath" "$kind" "$reason"' \
    'must not print a raw control byte'
mut pin-drift-trusts-the-file \
    '  _ad_check_commit "$commit" pin-drift' \
    '  :' \
    'pin-drift refuses a pin whose commit is HEAD'
mut ignore-axis-needs-agent-dir \
    '    _ad_ignore_axis "$root" "$a"' \
    '    [ -d "$root/.$a" ] && _ad_ignore_axis "$root" "$a"' \
    'runs even when .<agent>/ does not exist yet'

run_mutations() {
  local i n name verdict why applied=0 red=0 running=0 jobs
  n="${#MUT_NAMES[@]}"
  [ "$n" -gt 0 ] || { bad "the mutation table is empty — this harness proves nothing"; return; }

  # A BOUNDED POOL, for the same reason `scripts/selfcheck.sh` runs its registry through one: each
  # mutation costs a FULL suite run (~23s, dominated by ~200 subprocess invocations that each load
  # common.sh), so twenty of them serially was measured at 658s — on its own more than double what
  # the entire rest of the mirror costs, and a ten-fold regression against the ~70s #260 worked to
  # reach. The work is embarrassingly parallel and each mutation owns its own tree copy, so nothing
  # is shared but the CPU.
  #
  # Same bound as selfcheck's: min(cpu, 8). `wait -n` needs bash 4.3+; the floor here is 5.3.
  jobs="$( { getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu || echo 4; } 2>/dev/null | head -n1 )"
  case "$jobs" in ''|*[!0-9]*) jobs=4 ;; esac
  [ "$jobs" -gt 8 ] && jobs=8
  [ "$jobs" -lt 1 ] && jobs=1

  for ((i = 0; i < n; i++)); do
    mkdir -p "$WORK/mut-$i"
    _mut_one "$i" &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then wait -n; running=$((running - 1)); fi
  done
  wait

  # THE PARENT SCORES, over every index — so a worker that died without writing a verdict is a
  # FAILURE rather than a silently missing row. A pool that loses a result and reports the rest is
  # exactly the dispatcher defect `check-selfcheck.sh` exists to catch.
  for ((i = 0; i < n; i++)); do
    name="${MUT_NAMES[$i]}"
    if [ ! -f "$WORK/mut-$i/verdict" ]; then
      bad "mutation '$name': produced NO verdict — its worker died without reporting"
      continue
    fi
    IFS='|' read -r verdict why < "$WORK/mut-$i/verdict"
    if [ "$verdict" = ok ]; then
      ok; red=$((red + 1)); applied=$((applied + 1))
    else
      bad "mutation '$name': $why"
      case "$why" in *"did not apply"*|*"could not copy"*|*"rewrite failed"*) : ;; *) applied=$((applied + 1)) ;; esac
    fi
  done
  printf '\ncheck-adopt --mutation: %d/%d mutation(s) applied, %d observed RED on their own witness (pool=%d)\n' \
    "$applied" "$n" "$red" "$jobs"
  [ "$applied" -eq "$n" ] || bad "only $applied of $n mutations actually applied — the rest tested nothing"
}

# `--mutation`, matching `check-fact-drift.sh --mutation` — the established idiom here, and the
# form `scripts/selfcheck.sh` can register as a step (its `add` takes a command's words, so an
# env-var prefix would be executed as a command name).
[ "$MUTATE" = "1" ] && run_mutations

check_summary "check-adopt"
