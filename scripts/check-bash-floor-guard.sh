#!/usr/bin/env bash
# ai-dev-baseline — the bash-floor guard, driven to RED on every rule it owns (#257).
#
# check-bash-floor.sh is a GUARD, and a guard's failure mode is SILENCE: a scanner that stops
# recognizing job keys, a `case` arm that stops matching, an allowlist that accidentally accepts
# everything — each reports exactly what a clean repo reports. No other test in this suite would
# notice, because every assertion elsewhere still passes.
#
# base/practices/self-review.md: "a new guard is not done until it has been observed failing", and
# "automate the observation where the set is closed". The rule set here IS closed — NINE static
# rules (approved label · guard wired via `run:` · no `shell` key · no ADB_BASH_FLOOR in a workflow ·
# per-file zero jobs · no workflow files · Linux present · macOS present · first step logs
# `bash --version`) and THREE runtime ones ($BASH below floor · PATH bash below floor or absent ·
# a malformed floor override) — so each gets a fixture that must make the real lint come back red,
# plus a clean fixture proving the lint is not simply red-always.
#
# Where a rule can be ISOLATED it is: a fixture that only fails through some OTHER rule proves
# nothing about the rule it is named for. Review caught two of those here and they are fixed rather
# than documented.
#
# Every fixture lives under a throwaway mktemp dir. The working tree is NEVER mutated: the lint
# reads .github/workflows, so testing it by editing the real ci.yml would end in a
# `git checkout -- ` that also discards any uncommitted work in that file
# (base/practices/self-review.md, and git-and-prs.md on why that is unrecoverable).
#
# Usage: bash scripts/check-bash-floor-guard.sh   (exit 0 = every rule observed failing)

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh

work="$(mktemp -d)" || { echo "check-bash-floor-guard: FATAL — mktemp failed" >&2; exit 1; }
check_exit_guard "check-bash-floor-guard" "rm -rf \"$work\""

LINT="scripts/check-bash-floor.sh"

# run_lint <dir> — run the real lint against a fixture dir, setting RC and OUT.
#
# Deliberately NOT `rc="$(run_lint "$d")"`: a command substitution runs the function in a SUBSHELL,
# so the OUT it assigns dies with that subshell and every `has "$OUT" …` below would read a stale
# value from the previous fixture — assertions that pass while checking the wrong run.
run_lint() {
  OUT="$(bash "$LINT" --workflow-dir "$1" 2>&1)"
  RC=$?
}

# A job stanza that satisfies every rule. Callers vary one thing at a time so a red result is
# attributable to the rule under test rather than to a fixture that was broken three ways.
emit_job() {   # emit_job <file> <job> <runs-on> <wire-guard 0|1> [skip-version-log]
  {
    printf '  %s:\n' "$2"
    printf '    name: %s\n' "$2"
    printf '    runs-on: %s\n' "$3"
    printf '    steps:\n'
    [ "${5:-}" = "skip-version-log" ] || {
      printf '      - name: Log this runner'"'"'s bash\n'
      printf '        run: bash --version\n'
    }
    printf '      - name: Checkout\n'
    printf '        uses: actions/checkout@v4\n'
    if [ "$4" = "1" ]; then
      printf '      - name: bash floor\n'
      printf '        run: bash scripts/check-bash-floor.sh --runtime\n'
    else
      printf '      - name: work\n'
      printf '        run: echo hi\n'
    fi
  } >> "$1"
}

new_wf() {   # new_wf <dir> — create <dir> with a workflow header, echo the workflow path
  mkdir -p "$1"
  printf 'name: CI\non:\n  pull_request:\n\njobs:\n' > "$1/ci.yml"
  printf '%s/ci.yml' "$1"
}

# --- the clean fixture: the lint must be able to PASS -------------------------------------------
# Without this, every assertion below is satisfied by a lint that returns 1 unconditionally.
d="$work/clean"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "clean fixture passes"
has "$OUT" "2 job(s)" "clean fixture reports how many jobs it checked"
has "$OUT" "1 Linux, 1 macOS" "clean fixture names the per-platform counts it checked"

# --- rule 1: a runner label outside the proven allowlist ----------------------------------------
d="$work/badrunner"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-latest 1      # the exact trap: today's ubuntu-latest is bash 5.2.21
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 1: ubuntu-latest is rejected"
has "$OUT" "runs on 'ubuntu-latest'" "rule 1 names the offending label"
has "$OUT" "linux-job" "rule 1 names the offending job"

# A label nobody has thought about must be rejected too — the allowlist is what makes that true,
# and a denylist of known-old labels is what this asserts we did NOT write.
d="$work/unknownrunner"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-30.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 1: an unheard-of label is rejected, not waved through"

# --- rule 2: a job that never wires the runtime guard --------------------------------------------
d="$work/noguard"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 0
run_lint "$d"
eq "$RC" "1" "rule 2: a job with no --runtime step is rejected"
has "$OUT" "macos-job" "rule 2 names the unguarded job"
has "$OUT" "nothing proves the bash it actually got" "rule 2 says what is unproven"

# A COMMENT mentioning the invocation must not satisfy rule 2. Caught in self-review: the scanner
# matched the string anywhere in the job, so a `# TODO: add check-bash-floor.sh --runtime` would
# have registered as wiring it — a lint reading a note about doing the thing as the thing.
d="$work/commentonly"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 0
printf '      # TODO: add bash scripts/check-bash-floor.sh --runtime here\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "rule 2: a COMMENT naming the guard does not count as wiring it"
has "$OUT" "macos-job" "rule 2 still names the job whose only mention was a comment"

# --- rule 3: a shell: override, which routes around the guard -------------------------------------
d="$work/shellover"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '      - name: sneaky\n        shell: sh\n        run: echo hi\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "rule 3: a shell: override is rejected"
has "$OUT" "route steps around the floor guard" "rule 3 says why a shell key matters"

# --- rule 4: a scanner that finds no jobs is not a pass --------------------------------------------
d="$work/nojobs"; mkdir -p "$d"
printf 'name: CI\non:\n  pull_request:\n' > "$d/ci.yml"
run_lint "$d"
eq "$RC" "1" "rule 4: zero jobs is a failure, not a clean run"
has "$OUT" "gone blind" "rule 4 names the silent-scanner failure mode"

# PER FILE, not just in total. Caught in self-review: a grand-total check lets a second workflow
# file go blind for free the moment a first one still parses, which is the fail-open this whole
# family of checks exists to close.
d="$work/onegood-oneblind"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf 'name: Other\non:\n  pull_request:\n' > "$d/other.yml"     # parses, declares nothing
run_lint "$d"
eq "$RC" "1" "rule 4: a jobless SECOND file is caught even though the first file parsed fine"
has "$OUT" "other.yml" "rule 4 names WHICH file declared no jobs"

# --- the five fail-opens independent review reproduced ---------------------------------------------
# Each of these PASSED the lint before the fix. They are fixtures now so they cannot come back.

# (a) An inline flow-mapping job was INVISIBLE — the job-key rule required `job:` alone on the line,
#     so this one was not counted at all, and the per-file zero-jobs rule cannot see partial
#     blindness. Invisible is the one verdict a floor lint may never reach.
d="$work/inlinejob"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '  hidden: {runs-on: ubuntu-latest, steps: [{run: "echo unguarded"}]}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (a): an inline flow-mapping job is seen, not skipped"
has "$OUT" "hidden" "fail-open (a) names the inline job"

# (b) A quoted label carrying `#` was reduced to an approved label. GitHub reads the whole quoted
#     string as the label, so this job would never run — while the lint called it approved.
d="$work/quotedhash"; f="$(new_wf "$d")"
emit_job "$f" macos-job macos-latest 1
printf '  linux-job:\n    runs-on: "ubuntu-26.04 # not-the-label"\n    steps:\n' >> "$f"
printf '      - name: Log this runner'"'"'s bash\n        run: bash --version\n' >> "$f"
printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (b): a quoted label containing '#' is not silently truncated to an approved one"

# (c) `defaults: {run: {shell: sh}}` routes EVERY step in the workflow around bash, and a
#     line-anchored `^[[:space:]]*shell:` grep never saw it.
d="$work/inlineshell"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf 'defaults: {run: {shell: sh}}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (c): an INLINE defaults shell override is caught"

# (d) The guard invocation in an `env:` value satisfied a bare substring test while executing
#     nothing. A step name or an `echo` would have done the same.
d="$work/envmention"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
{
  printf '  macos-job:\n    runs-on: macos-latest\n'
  printf '    env:\n      NOTE: bash scripts/check-bash-floor.sh --runtime\n'
  printf '    steps:\n      - name: Log this runner'"'"'s bash\n        run: bash --version\n'
} >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (d): mentioning the guard outside a run: does not count as wiring it"
has "$OUT" "macos-job" "fail-open (d) names the job that only mentioned the guard"

# (e) A workflow setting ADB_BASH_FLOOR turns every runtime assertion in scope into a formality
#     while this lint stays green — the one bypass the guard cannot see from inside itself.
d="$work/floorenv"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '    env:\n      ADB_BASH_FLOOR: 0.0\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (e): a workflow may not set ADB_BASH_FLOOR"
has "$OUT" "ADB_BASH_FLOOR" "fail-open (e) names the override it found"

# --- three more the async PR reviewer reproduced, all "equivalent YAML spelling" bypasses ----------
# Each PASSED after the first round of fixes. The lesson they share: a rule written against ONE
# spelling of a construct is a rule that holds until someone writes the other one.

# (f) `run: echo '…check-bash-floor.sh --runtime'` runs the guard exactly zero times, and satisfied
#     a `run:`-anchored substring test. The invocation must now be the WHOLE run value.
d="$work/echoedguard"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
{
  printf '  macos-job:\n    runs-on: macos-latest\n    steps:\n'
  printf '      - name: Log this runner'"'"'s bash\n        run: bash --version\n'
  printf '      - name: g\n        run: echo '"'"'bash scripts/check-bash-floor.sh --runtime'"'"'\n'
} >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (f): an ECHOED guard invocation does not count as running it"

# (g) A QUOTED job id was skipped entirely — and worse than unchecked: every line of that job read
#     as belonging to the previous one, so it did not exist at all.
d="$work/quotedjob"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '  "hidden":\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        run: echo hi\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (g): a QUOTED job id is seen, not skipped"
has "$OUT" "hidden" "fail-open (g) names the quoted job"

# (h) `defaults: {run: {"shell": sh}}` — the quoted spelling of (c), same effect, previously unseen.
d="$work/quotedshell"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf 'defaults: {run: {"shell": sh}}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (h): a QUOTED shell key is caught too"

# --- rule 9: the first step must log bash --version (#257 acceptance criterion 2) --------------------
d="$work/nofirstlog"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1 skip-version-log
run_lint "$d"
eq "$RC" "1" "rule 9: a job whose first step is not the version log is rejected"
has "$OUT" "FIRST step" "rule 9 says which step it wanted"

# --- rule 5: no workflow files at all --------------------------------------------------------------
d="$work/empty"; mkdir -p "$d"
run_lint "$d"
eq "$RC" "1" "rule 5: an empty workflow dir is a failure, not a clean run"
has "$OUT" "scanned nothing" "rule 5 says it scanned nothing"

# --- rule 6: both platforms must actually be represented -------------------------------------------
# #257's first acceptance criterion. Without this the macOS job can be deleted and every other rule
# still passes — the floor would be "proven" only on the platform where it was never in doubt.
d="$work/nomacos"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
run_lint "$d"
eq "$RC" "1" "rule 6: a Linux-only workflow is rejected"
has "$OUT" "unproven on the platform where it is hardest to reach" "rule 6 names the missing macOS coverage"

d="$work/nolinux"; f="$(new_wf "$d")"
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 6: a macOS-only workflow is rejected"
has "$OUT" "unproven on Linux" "rule 6 names the missing Linux coverage"

# --- the runtime half ------------------------------------------------------------------------------
# Driven through ADB_BASH_FLOOR rather than through a second interpreter, so the assertion holds
# identically on bash 3.2 and 5.3. That is not just convenience: pinning this to the REAL floor would
# make selfcheck fail on a contributor still at 5.2 — which is #256's enforcement, not #257's, and
# shipping it early here would be exactly the scope creep the gap-analysis pass flagged.
out="$(ADB_BASH_FLOOR=0.0 bash "$LINT" --runtime 2>&1)"; rc=$?
eq "$rc" "0" "runtime: any interpreter clears a 0.0 floor"
has "$out" "floor enforced      0.0" "runtime PRINTS the floor it enforced, so a lowered floor is visible"

out="$(ADB_BASH_FLOOR=99.0 bash "$LINT" --runtime 2>&1)"; rc=$?
eq "$rc" "1" "runtime: no interpreter clears a 99.0 floor — the assertion really fires"
has "$out" "below the 99.0 floor" "runtime names the floor it failed against"
has "$out" "running interpreter" "runtime reports which interpreter it judged"
has "$out" "PATH-resolved bash" "runtime reports the PATH-resolved bash the suite would use"

# ISOLATE the $BASH rule from the PATH rule. Review's point: at floor 99.0 BOTH comparisons fail, so
# that fixture survives deleting either one and proves neither. The isolating case is the REAL floor
# on a host whose /bin/bash is below it and whose PATH bash is above — i.e. exactly macOS, where the
# divergence this rule exists for actually lives. Guarded on the system bash genuinely being old, so
# on a Linux runner (where /bin/bash IS 5.3) this skips instead of asserting something false.
sysv="$(/bin/bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || echo 99)"
pathv="$(bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || echo 0)"
if [ -x /bin/bash ] && [ "$sysv" = "3.2" ] && [ "$pathv" != "3.2" ]; then
  out="$(/bin/bash "$LINT" --runtime 2>&1)"; rc=$?
  eq "$rc" "1" "runtime: the \$BASH rule fires ALONE — old /bin/bash, current PATH bash, real floor"
  has "$out" "IN USE" "runtime says outright that the system bash is the one running"
  has "$out" "at /bin/bash" "runtime blames the interpreter that is executing, not the PATH one"
fi

# ISOLATE the PATH rule the same way, and in the direction that actually bites: a CURRENT
# interpreter executing the guard (so the $BASH rule is satisfied and cannot be what fails) while
# PATH resolves `bash` to an OLD one. That is the live macOS hazard in mirror image — every
# '#!/usr/bin/env bash' entry point in this repo, selfcheck included, runs on the PATH one.
#
# A stub rather than emptying PATH: blanking it breaks the guard's own `dirname` bootstrap, so the
# script would die before reaching the rule and the assertion would pass for the wrong reason.
mkdir -p "$work/fakebin"
{ printf '#!/bin/sh\n'
  printf 'case "$1" in\n'
  printf '  --version) echo "GNU bash, version 3.2.57(1)-release"; exit 0 ;;\n'
  printf '  -c) exec /bin/sh -c '"'"'printf "3.2.57"'"'"' ;;\n'
  printf 'esac\nexit 0\n'
} > "$work/fakebin/bash"
chmod +x "$work/fakebin/bash"
self_bash="$(command -v bash 2>/dev/null || echo /bin/bash)"
out="$(PATH="$work/fakebin:$PATH" "$self_bash" "$LINT" --runtime 2>&1)"; rc=$?
eq "$rc" "1" "runtime: the PATH rule fires ALONE — current interpreter, stale bash on PATH"
has "$out" "the suite runs on THAT one" "runtime blames the PATH-resolved bash, not the running one"

# The floor override must be a SEAM, not a bypass. adb_version_ge reads a non-numeric component as
# 0, so an unvalidated override lets bash 3.2.57 through: review reproduced it with `x`, `-1` and
# the Arabic-Indic `٥.٣`. All three must now be hard errors rather than floors.
#
# An EMPTY value is deliberately absent from this list: `${ADB_BASH_FLOOR:-5.3}` treats empty as
# unset, so it yields the real floor. That is the safe direction, and asserting otherwise would be
# asserting a bug.
for bogus in x -1 ٥.٣ 5.3.x " " 5..3; do
  ADB_BASH_FLOOR="$bogus" bash "$LINT" --runtime >/dev/null 2>&1
  no $? "runtime: a malformed floor '$bogus' is rejected, never treated as 0"
done

# --- usage ------------------------------------------------------------------------------------------
bash "$LINT" --bogus >/dev/null 2>&1; no $? "an unknown flag exits non-zero"
bash "$LINT" --workflow-dir >/dev/null 2>&1; no $? "--workflow-dir with no argument exits non-zero"

check_summary "check-bash-floor-guard"
