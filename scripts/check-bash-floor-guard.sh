#!/usr/bin/env bash
# ai-dev-baseline — the bash-floor guard, driven to RED on every rule it owns (#257).
#
# check-bash-floor.sh is a GUARD, and a guard's failure mode is SILENCE: a scanner that stops
# recognizing job keys, a `case` arm that stops matching, an allowlist that accidentally accepts
# everything — each reports exactly what a clean repo reports. No other test in this suite would
# notice, because every assertion elsewhere still passes.
#
# base/practices/self-review.md: "a new guard is not done until it has been observed failing", and
# "automate the observation where the set is closed". The rule set here IS closed — five static
# rules and two runtime ones — so each gets a fixture that must make the real lint come back red,
# plus a clean fixture proving the lint is not simply red-always.
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
emit_job() {   # emit_job <file> <job> <runs-on> <wire-guard 0|1>
  {
    printf '  %s:\n' "$2"
    printf '    name: %s\n' "$2"
    printf '    runs-on: %s\n' "$3"
    printf '    steps:\n'
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

# --- rule 3: a shell: override, which routes around the guard -------------------------------------
d="$work/shellover"; f="$(new_wf "$d")"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '      - name: sneaky\n        shell: sh\n        run: echo hi\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "rule 3: a shell: override is rejected"
has "$OUT" "escapes the floor guard" "rule 3 says why a shell: override matters"

# --- rule 4: a scanner that finds no jobs is not a pass --------------------------------------------
d="$work/nojobs"; mkdir -p "$d"
printf 'name: CI\non:\n  pull_request:\n' > "$d/ci.yml"
run_lint "$d"
eq "$RC" "1" "rule 4: zero jobs is a failure, not a clean run"
has "$OUT" "gone blind" "rule 4 names the silent-scanner failure mode"

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

# The macOS trap, asserted directly where a system bash exists: $BASH and `command -v bash` can
# disagree, and only $BASH says what is actually executing. Skipped on hosts with no /bin/bash
# (some Linux images), where there is no second interpreter to prove the divergence with.
if [ -x /bin/bash ]; then
  out="$(ADB_BASH_FLOOR=99.0 /bin/bash "$LINT" --runtime 2>&1)"; rc=$?
  eq "$rc" "1" "runtime: judged under /bin/bash, the guard still fires"
  has "$out" "/bin/bash" "runtime names /bin/bash as the interpreter in use when it is"
  has "$out" "IN USE" "runtime says outright that the system bash is the one running"
fi

# --- usage ------------------------------------------------------------------------------------------
bash "$LINT" --bogus >/dev/null 2>&1; no $? "an unknown flag exits non-zero"
bash "$LINT" --workflow-dir >/dev/null 2>&1; no $? "--workflow-dir with no argument exits non-zero"

check_summary "check-bash-floor-guard"
