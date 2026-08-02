#!/usr/bin/env bash
# ai-dev-baseline — negative tests for the fact-drift lint's own guard rails (#213).
#
# WHY THIS EXISTS. #213 shipped two things whose entire job is to stop a check from passing while
# checking nothing: the `fires:` witness contract inside `fact()`, and `--mutation`, which injects
# each witness into a copy of every pinned file and requires the real lint to come back red. Both
# are guards. A guard's failure mode is SILENCE — it reports exactly what a clean run reports —
# so shipping them without watching them fail would reproduce, one level up, the defect they were
# written to remove. `base/practices/self-review.md` states the rule: a new guard is not done
# until it has been observed failing.
#
# HOW IT TESTS. Every case runs against a THROWAWAY COPY of the working tree; the live tree is
# never touched. That is the other half of #213 — negative-testing the last pin by editing
# `scripts/lib/pr-review.sh` in place and "restoring" it with `git checkout` destroyed ~40 minutes
# of uncommitted work, which no reflog could recover. The method is in the same practice file.
#
# Most cases replace the real 68-rule set with ONE synthetic rule (between the file's own
# `# --- FACT:` and `# --- what was actually evaluated` markers). That keeps each case readable —
# the rule under test is right there in the case — and keeps `--mutation` cases to a single
# sub-lint instead of 22. The real rule set is exercised for real by `check-fact-drift.sh` and
# `check-fact-drift.sh --mutation` in selfcheck; this suite is about the machinery around it.
#
# The headline case is `historic-bot-pin`: the EXACT pattern that shipped unable to fire
# (`absent:\[bot\]\$`) against the EXACT idiom it was meant to catch. It must be reported
# UNFIRABLE, and its corrected form must be accepted — the regression test for #213 itself.
#
# Usage: bash scripts/check-fact-guard.sh   (exit 0 = all pass, 1 = a failure)

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
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)" || { echo "check-fact-guard: cannot create a temp dir" >&2; exit 1; }
# ONE exit trap, doing both jobs: fail closed if this suite ends without running its summary, then
# clean up. Without the first half the suite fails OPEN — its exit status is its last command's,
# and only check_summary ever consults the `fail` counter, so a truncating edit or a stray early
# `exit` prints FAIL lines and still exits 0, and selfcheck and CI report the step as passing.
# A suite whose entire job is proving guards can fail must not be able to skip its own verdict.
check_exit_guard "check-fact-guard" "rm -rf \"$work\""

# ONE copy of the working tree, cloned per case, through check-lib.sh's shared copier. It copies
# UNCOMMITTED sources — so this suite tests the lint you just edited, not the one at HEAD.
PRISTINE="$work/pristine"
check_copy_worktree "$ROOT" "$PRISTINE" || { echo "check-fact-guard: could not copy the tree" >&2; exit 1; }

# fresh — print the path of a brand-new copy of the pristine tree.
#
# The unique name comes from `mktemp -d`, NOT from a counter: every call site is `d="$(fresh)"`,
# which runs this in a SUBSHELL, so an incremented counter never reaches the parent. Every case
# would then reuse one directory and inherit the previous case's sabotage — which is a silent
# corruption, since a case that fails for the wrong reason still fails.
fresh() {
  local d
  # Drop earlier case dirs first. Each case is self-contained and never revisits a previous one,
  # and the tree is ~4 MB — without this, ~24 cases peak at ~100 MB of temp. Statelessly, by glob,
  # because a counter could not survive the subshell either.
  rm -rf "$work"/case.*
  d="$(mktemp -d "$work/case.XXXXXX")" || return 1
  check_copy_worktree "$PRISTINE" "$d" || return 1
  printf '%s' "$d"
}

# minimal <dir>  (synthetic rule text on stdin) — swap the copy's whole rule set for the text
# given. Sliced by the file's own section markers with head/tail rather than sed or `awk -v`:
# every rule under test is dense with backslashes and single quotes, and both of those tools
# would eat them on the way in.
minimal() {
  local d="$1" f synth start end
  if [ -z "$d" ]; then
    bad "minimal(): empty fixture dir — 'fresh' failed; refusing to slice a path outside the fixture"
    return 1
  fi
  f="$d/scripts/check-fact-drift.sh"
  synth="$(cat)"
  start="$(grep -n '^# --- FACT: ' "$f" | head -n1 | cut -d: -f1)"
  end="$(grep -n '^# --- what was actually evaluated' "$f" | head -n1 | cut -d: -f1)"
  if [ -z "$start" ] || [ -z "$end" ]; then
    bad "minimal(): section markers not found in check-fact-drift.sh — this suite's slicing is stale"
    return 1
  fi
  { head -n "$((start - 1))" "$f"; printf '%s\n' "$synth"; tail -n "+$end" "$f"; } > "$f.tmp" \
    && mv "$f.tmp" "$f"
}

# run <dir> [args…] — run the copy's lint, capturing merged output in OUT and status in RC.
# Set RUN_PATH to override PATH for one case (used to stub out `find`).
#
# An EMPTY <dir> is fatal rather than ignored: `fresh` can fail, its callers assign in a command
# substitution that cannot propagate a status, and `cd "" && …` succeeds — which would silently
# aim the whole case at the REAL repo root instead of the fixture.
OUT=""; RC=0; RUN_PATH=""
run() {
  local d="$1"; shift
  if [ -z "$d" ]; then
    bad "run(): empty fixture dir — 'fresh' failed and the case would have run against the real repo"
    OUT=""; RC=-1; return
  fi
  OUT="$( cd "$d" && PATH="${RUN_PATH:-$PATH}" bash scripts/check-fact-drift.sh "$@" 2>&1 )"; RC=$?
}

# =============================== the control ===================================
# An untouched copy must pass NORMAL mode. Without this, every "it failed" below could be the copy
# being broken rather than the case under test. (`--mutation` gets its own control further down,
# on a one-rule fixture; running it here would re-do all 22 sub-lints selfcheck already runs.)
d="$(fresh)"
run "$d"
eq "$RC" 0 "control: a pristine copy passes the lint"
has "$OUT" "absent rules" "control: the run reports what it evaluated"

# =================== #213's actual defect, both directions ====================
# The pattern as originally shipped, against the real shell idiom. `\[bot\]\$` asks for a
# contiguous `[bot]$`; the idiom always backslash-escapes the bracket, so it matched nothing at
# all and the check was green forever.
d="$(fresh)"
minimal "$d" <<'RULE'
fact historic-bot-pin 'absent:\[bot\]\$' 'fires:s/\[bot\]$//' -- README.md
RULE
run "$d"
eq "$RC" 1 "historic-bot-pin: the pattern that shipped unfirable is rejected"
has "$OUT" "UNFIRABLE PIN" "historic-bot-pin: named as unfirable, not as generic drift"

# ...and its correction accepted, against BOTH real spellings — the shell form (one backslash)
# and the jq form (two). A pin witnessed by only one of them would have re-created the defect one
# spelling narrower.
d="$(fresh)"
minimal "$d" <<'RULE'
fact fixed-bot-pin 'absent:bot\\*\]\$' 'fires:s/\[bot\]$//' 'fires:sub("\\[bot\\]$"; "")' -- README.md
RULE
run "$d"
eq "$RC" 0 "fixed-bot-pin: the corrected pattern matches both real idioms"

# =========================== the witness contract =============================
d="$(fresh)"
minimal "$d" <<'RULE'
fact no-witness 'absent:ZZQQ-superseded' -- README.md
RULE
run "$d"
eq "$RC" 1 "an absent: rule with no fires: witness is refused"
has "$OUT" "declares no fires: witness" "no-witness: says which contract was broken"

d="$(fresh)"
minimal "$d" <<'RULE'
fact witness-on-positive 'fixed:ai-dev-baseline' 'fires:ai-dev-baseline' -- README.md
RULE
run "$d"
eq "$RC" 1 "fires: on a positive rule is a usage error, not silently ignored"
has "$OUT" "only meaningful on an absent: rule" "witness-on-positive: names the misuse"

d="$(fresh)"
minimal "$d" <<'RULE'
fact empty-witness 'absent:ZZQQ' 'fires:' -- README.md
RULE
run "$d"
eq "$RC" 1 "an empty fires: value is refused (it would witness nothing)"
has "$OUT" "empty fires: witness" "empty-witness: names the shape"

d="$(fresh)"
minimal "$d" <<'RULE'
fact multiline-witness 'absent:ZZQQ' 'fires:one
two' -- README.md
RULE
run "$d"
eq "$RC" 1 "a witness spanning lines is refused (grep is line-oriented)"
has "$OUT" "witness spans lines" "multiline-witness: names the reason"

# ======================== the degenerate-rule shapes ==========================
# Each of these is a way a rule asserts NOTHING while looking like a rule.
d="$(fresh)"
minimal "$d" <<'RULE'
fact empty-needle 'absent:' 'fires:anything' -- README.md
RULE
run "$d"
eq "$RC" 1 "an empty pattern is refused (it matches every line of every file)"
has "$OUT" "empty absent pattern" "empty-needle: names the shape"

d="$(fresh)"
minimal "$d" <<'RULE'
fact empty-fixed-needle 'fixed:' -- README.md
RULE
run "$d"
eq "$RC" 1 "an empty fixed: token is refused too"

d="$(fresh)"
minimal "$d" <<'RULE'
fact no-separator 'fixed:ai-dev-baseline'
RULE
run "$d"
eq "$RC" 1 "a rule with no '--' is refused"
has "$OUT" "missing '--'" "no-separator: names the missing separator"

d="$(fresh)"
minimal "$d" <<'RULE'
fact no-files 'fixed:ai-dev-baseline' --
RULE
run "$d"
eq "$RC" 1 "a rule with no files is refused (it can never fail)"
has "$OUT" "no files" "no-files: names the shape"

d="$(fresh)"
minimal "$d" <<'RULE'
fact bad-kind 'bogus:ai-dev-baseline' -- README.md
RULE
run "$d"
eq "$RC" 1 "an unknown spec kind is refused"
has "$OUT" "unknown spec kind" "bad-kind: names the kind"

d="$(fresh)"
minimal "$d" <<'RULE'
fact no-colon 'ai-dev-baseline' -- README.md
RULE
run "$d"
eq "$RC" 1 "a spec with no kind prefix is refused"
has "$OUT" "malformed spec" "no-colon: names the shape"

d="$(fresh)"
minimal "$d" <<'RULE'
fact stray-arg 'fixed:ai-dev-baseline' README.md -- README.md
RULE
run "$d"
eq "$RC" 1 "an argument that is neither fires: nor '--' is refused"

# A file listed twice asserts nothing new — and under --mutation the second injection would
# overwrite the first's backup, so the restore would put back an already-mutated file and one
# witness would leak into the next.
d="$(fresh)"
minimal "$d" <<'RULE'
fact duplicate-file 'absent:ZZQQ' 'fires:ZZQQ' -- README.md README.md
RULE
run "$d"
eq "$RC" 1 "a file listed twice in one rule is refused"
has "$OUT" "listed more than once" "duplicate-file: names the shape"

# ======================== the empty rule set ==================================
# The quietest possible green: a truncated file, a sourcing accident, an early exit. Every
# individual assertion still passes, because there are none.
d="$(fresh)"
minimal "$d" </dev/null
run "$d"
eq "$RC" 1 "a lint that evaluated no rules at all fails instead of passing"
has "$OUT" "no rules were evaluated" "empty rule set: says so in as many words"

# Positive rules only — the negative half of the lint silently deleted.
d="$(fresh)"
minimal "$d" <<'RULE'
fact positives-only 'fixed:ai-dev-baseline' -- README.md
RULE
run "$d"
eq "$RC" 1 "a lint with no absent: rules left fails"
has "$OUT" "superseded-value half of this lint is gone" "positives-only: names what vanished"

# ============================ the mutation mode ===============================
# Its control: one synthetic rule, injected and observed going red end to end.
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-control 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
run "$d" --mutation
eq "$RC" 0 "mutation control: a firable pin is observed going red"
has "$OUT" "witnesses injected" "mutation control: reports what it injected"
# The live tree is never the thing mutated. If it were, README.md would now carry the witness.
hasnt "$(cat "$ROOT/README.md")" "ZZQQ-superseded token" "mutation ran against a COPY, not the working tree"

# A rule whose predicate cannot fire: `req_absent` neutered in the copy. Normal mode still passes
# (nothing asserts), which is precisely the silence this mode exists to break.
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-dead-predicate 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nreq_absent() { :; }\n' >> "$d/scripts/check-lib.sh"   # adb-allow: req_absent
run "$d"
eq "$RC" 0 "dead predicate: normal mode cannot see it (this is the silence)"
run "$d" --mutation
eq "$RC" 1 "dead predicate: --mutation catches a pin that cannot fire"
has "$OUT" "cannot fire" "dead predicate: names it as an unfirable pin, not as a crash"
hasnt "$OUT" "a crash or broken copy" "dead predicate: a green lint is NOT reported as a crash"

# A lint that goes non-zero for a reason that is NOT a drift verdict (a crash, a missing
# dependency, a corrupt copy). "Any non-zero" would accept it and prove nothing.
# The sabotage edits the copy's lint, so the OUTER --mutation run inherits the same `exit 3`;
# what is under test is the message, and that the run does not come back green.
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-wrong-rc 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\n_guard_rc=$?\n[ "$_guard_rc" -eq 0 ] || exit 3\nexit 0\n' >> "$d/scripts/check-fact-drift.sh"
run "$d" --mutation
no "$RC" "--mutation requires exactly rc 1, not merely non-zero"
has "$OUT" "not a drift verdict" "wrong rc: distinguishes a crash from a verdict"

# A file pinned ONLY by an absent: rule and missing from the tree. `req_absent` is vacuously true
# on a missing path, so this used to be a SILENT pass that the totals then reported as "scanned".
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-missing-file 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- docs/does-not-exist.md
RULE
run "$d"
eq "$RC" 1 "a pinned file that does not exist fails — the rule asserts nothing about it"
has "$OUT" "pinned file does not exist" "missing file: names the path"
has "$OUT" "0 files scanned" "missing file: is NOT counted as scanned"
run "$d" --mutation
eq "$RC" 1 "missing pinned file: --mutation stops at the pristine baseline"
has "$OUT" "PRISTINE tree copy does not pass" "missing file under mutation: names why it stopped"

# The per-file diagnostic match. An UNRELATED failure returns rc 1 too, and accepting that would
# let a neighbouring rule's red satisfy this rule's proof while the pin stayed unfirable. Here
# `req_absent` fires — so the lint goes red — but reports someone else's label.
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-wrong-diagnostic 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
cat >> "$d/scripts/check-lib.sh" <<'STUB'
req_absent() {   # adb-allow: req_absent
  if grep -Eq -- "$2" "$1"; then
    check_note "[some-other-rule] superseded pattern /decoy/ still present in nowhere.md:"
    check_fail
  fi
}
STUB
run "$d"
eq "$RC" 0 "wrong diagnostic: the pristine baseline is still clean"
run "$d" --mutation
eq "$RC" 1 "an unrelated rule going red does NOT satisfy this rule's proof"
has "$OUT" "did NOT trip the rule" "wrong diagnostic: names the per-file miss"

# A tree that is ALREADY red must not be mutated: every injection would "fail the lint" for a
# reason having nothing to do with the witness, and the mode would report success.
d="$(fresh)"
minimal "$d" <<'RULE'
fact mutation-dirty-baseline 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nZZQQ-superseded token\n' >> "$d/README.md"
run "$d" --mutation
eq "$RC" 1 "--mutation refuses to run against a tree that is already drifting"
has "$OUT" "PRISTINE tree copy does not pass" "dirty baseline: names why it stopped"

# ===================== the req_absent call-site invariant =====================
# The witness contract lives in fact(); a direct caller bypasses it entirely.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-invariant 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nreq_absent scripts/check-lib.sh "ZZQQ" stray-caller\n' >> "$d/scripts/check-cleanup.sh"   # adb-allow: req_absent
run "$d" --mutation
eq "$RC" 1 "an unmarked caller outside fact() is refused"
has "$OUT" "called outside fact()" "call-site invariant: names the bypass"

# A MENTION in a comment is not a call — suites legitimately discuss the helper in prose.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-comment 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\n# req_absent is deliberately not used here\n' >> "$d/scripts/check-cleanup.sh"   # adb-allow: req_absent
run "$d" --mutation
eq "$RC" 0 "a commented mention of the helper is not a call site"

# THE EXEMPTION IS PER LINE, NOT PER FILE. A whole-file exclusion made this invariant false: a real
# direct call added to one of the three files that legitimately name the helper would pass
# undetected. A sanctioned line carries a marker; an unmarked one is caught wherever it lives.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-in-exempt-file 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nreq_absent scripts/check-lib.sh "ZZQQ" sneaky\n' >> "$d/scripts/check-fact-guard.sh"   # adb-allow: req_absent
run "$d" --mutation
eq "$RC" 1 "an unmarked call inside a file that legitimately names the helper is still caught"
has "$OUT" "check-fact-guard.sh" "exempt-file call: names the file it found it in"

# ...and the marker is what makes a line sanctioned, so a marked line is accepted anywhere.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-marked 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nreq_absent a b c   # adb-allow: req_absent\n' >> "$d/scripts/check-cleanup.sh"
run "$d" --mutation
eq "$RC" 0 "a line carrying the sanctioned marker is accepted"

# EXTENSIONLESS shell programs are scanned too. `bin/agent-init` and `bin/baseline` have no `.sh`,
# and a `*.sh`-only enumeration left them — and any future extensionless script — invisible.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-extensionless 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
printf '\nreq_absent scripts/check-lib.sh "ZZQQ" from-bin\n' >> "$d/bin/agent-init"   # adb-allow: req_absent
run "$d" --mutation
eq "$RC" 1 "a call in an extensionless shell program (bin/agent-init) is caught"
has "$OUT" "bin/agent-init" "extensionless: names the file"

# The enumeration's own zero-file branch. A scan that returns nothing is a BROKEN scan, not a clean
# tree — the silent-inert shape this whole commit is about. Driven with a `find` that finds nothing.
d="$(fresh)"
minimal "$d" <<'RULE'
fact callsite-zero-files 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
mkdir -p "$d/stubbin"
printf '#!/bin/sh\nexit 0\n' > "$d/stubbin/find"
chmod +x "$d/stubbin/find"
RUN_PATH="$d/stubbin:$PATH"
run "$d" --mutation
RUN_PATH=""
eq "$RC" 1 "an enumeration that finds no shell files fails instead of passing"
has "$OUT" "enumeration is broken" "zero files: names the broken scan"

# ================= an ACTIVE invocation, not the raw token ====================
# A `fixed:` pin on a command is satisfied by a COMMENTED-OUT command, so commenting out the
# selfcheck line and the workflow step would leave both tokens present and both guards un-run.
# The wiring rules therefore anchor on `^[^#]*`; prove it both ways on a fixture file.
d="$(fresh)"
minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
printf '\n# bash scripts/check-fact-drift.sh --mutation\n' >> "$d/README.md"
run "$d"
eq "$RC" 1 "a COMMENTED-OUT invocation does not satisfy the wiring pin"
has "$OUT" "canonical pattern" "commented invocation: reported as a missing pattern"

d="$(fresh)"
minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
printf '\nif bash scripts/check-fact-drift.sh --mutation; then :; fi\n' >> "$d/README.md"
run "$d"
eq "$RC" 0 "an ACTIVE invocation satisfies it"

# ...and it must not depend on something preceding the token, which is the trap the earlier
# `[^#[:space:]]`-consuming anchor fell into twice.
d="$(fresh)"
minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
printf '\nbash scripts/check-fact-drift.sh --mutation\n' >> "$d/README.md"
run "$d"
eq "$RC" 0 "an invocation at the START of a line satisfies it too"

# ================== the suite's own verdict cannot be skipped =================
# A suite's exit status is its LAST COMMAND's, and only check_summary consults the `fail` counter.
# Lose that final line and the suite prints FAIL diagnostics, exits 0, and is reported as passing.
# Exercised against a COPY of this very file — the one suite for which failing open is worst.
guard_self="$work/selftest"
mkdir -p "$guard_self/scripts"
cp scripts/check-lib.sh "$guard_self/scripts/"
# A tiny suite that records a FAILING assertion and then ends without its summary.
cat > "$guard_self/scripts/truncated.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "truncated-suite"
bad "a deliberate failure that nothing will ever count"
SUITE
( cd "$guard_self" && bash scripts/truncated.sh ) >/dev/null 2>&1
eq "$?" 1 "a suite that ends without check_summary fails closed"

# ...and the guard does not fire when the summary DID run.
cat > "$guard_self/scripts/complete.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "complete-suite"
ok
check_summary "complete-suite"
SUITE
( cd "$guard_self" && bash scripts/complete.sh ) >/dev/null 2>&1
eq "$?" 0 "a suite that runs its summary is unaffected by the guard"

# ...and a real failure still exits 1 through the guard rather than being masked by it.
cat > "$guard_self/scripts/failing.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "failing-suite"
bad "a real, counted failure"
check_summary "failing-suite"
SUITE
( cd "$guard_self" && bash scripts/failing.sh ) >/dev/null 2>&1
eq "$?" 1 "a counted failure still exits 1"

# ...and the cleanup argument still runs.
cleanup_probe="$work/cleanup-probe"
: > "$cleanup_probe"
cat > "$guard_self/scripts/cleanup.sh" <<SUITE
set -u
cd "\$(dirname "\$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "cleanup-suite" "rm -f '$cleanup_probe'"
ok
check_summary "cleanup-suite"
SUITE
( cd "$guard_self" && bash scripts/cleanup.sh ) >/dev/null 2>&1
if [ -e "$cleanup_probe" ]; then bad "check_exit_guard did not run its cleanup command"; else ok; fi

# ============================== argument handling =============================
d="$(fresh)"
run "$d" --bogus
eq "$RC" 2 "an unknown mode argument exits 2 rather than silently running normally"
d="$(fresh)"
run "$d" --mutation extra
eq "$RC" 2 "a surplus argument exits 2"

check_summary "check-fact-guard"
