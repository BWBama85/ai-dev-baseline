#!/usr/bin/env bash
# ai-dev-baseline — the bash-floor guard, driven to RED on every rule it owns (#257).
#
# check-bash-floor.sh is a GUARD, and a guard's failure mode is SILENCE: a scanner that stops
# recognizing job keys, a `case` arm that stops matching, an allowlist that accidentally accepts
# everything — each reports exactly what a clean repo reports. No other test in this suite would
# notice, because every assertion elsewhere still passes.
#
# base/practices/self-review.md: "a new guard is not done until it has been observed failing", and
# "automate the observation where the set is closed". The rule set here IS closed — TWELVE static
# rules (approved label · guard wired via `run:` · no `shell` key · no ADB_BASH_FLOOR in a workflow ·
# per-file zero jobs · no workflow files · Linux present · macOS present · first step logs
# `bash --version` · and the three WSL-class rules #2 added: the guard reached through
# `wsl -d <distro>` · a WSL bash version logged at all · that log preceding the guard) and THREE
# runtime ones ($BASH below floor · PATH bash below floor or absent · a malformed floor override) —
# so each gets a fixture that must make the real lint come back red, plus a clean fixture proving
# the lint is not simply red-always.
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
d="$work/clean"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "clean fixture passes"
has "$OUT" "2 job(s)" "clean fixture reports how many jobs it checked"
has "$OUT" "1 Linux, 1 macOS" "clean fixture names the per-platform counts it checked"

# --- rule 1: a runner label outside the proven allowlist ----------------------------------------
d="$work/badrunner"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-latest 1      # the exact trap: today's ubuntu-latest is bash 5.2.21
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 1: ubuntu-latest is rejected"
has "$OUT" "runs on 'ubuntu-latest'" "rule 1 names the offending label"
has "$OUT" "linux-job" "rule 1 names the offending job"

# A label nobody has thought about must be rejected too — the allowlist is what makes that true,
# and a denylist of known-old labels is what this asserts we did NOT write.
d="$work/unknownrunner"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-30.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 1: an unheard-of label is rejected, not waved through"

# --- rule 2: a job that never wires the runtime guard --------------------------------------------
d="$work/noguard"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 0
run_lint "$d"
eq "$RC" "1" "rule 2: a job with no --runtime step is rejected"
has "$OUT" "macos-job" "rule 2 names the unguarded job"
has "$OUT" "nothing proves the bash it actually got" "rule 2 says what is unproven"

# A COMMENT mentioning the invocation must not satisfy rule 2. Caught in self-review: the scanner
# matched the string anywhere in the job, so a `# TODO: add check-bash-floor.sh --runtime` would
# have registered as wiring it — a lint reading a note about doing the thing as the thing.
d="$work/commentonly"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 0
printf '      # TODO: add bash scripts/check-bash-floor.sh --runtime here\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "rule 2: a COMMENT naming the guard does not count as wiring it"
has "$OUT" "macos-job" "rule 2 still names the job whose only mention was a comment"

# --- rule 3: a shell: override, which routes around the guard -------------------------------------
d="$work/shellover"; f="${ new_wf "$d"; }"
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
d="$work/onegood-oneblind"; f="${ new_wf "$d"; }"
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
d="$work/inlinejob"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '  hidden: {runs-on: ubuntu-latest, steps: [{run: "echo unguarded"}]}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (a): an inline flow-mapping job is seen, not skipped"
has "$OUT" "hidden" "fail-open (a) names the inline job"

# (b) A quoted label carrying `#` was reduced to an approved label. GitHub reads the whole quoted
#     string as the label, so this job would never run — while the lint called it approved.
d="$work/quotedhash"; f="${ new_wf "$d"; }"
emit_job "$f" macos-job macos-latest 1
printf '  linux-job:\n    runs-on: "ubuntu-26.04 # not-the-label"\n    steps:\n' >> "$f"
printf '      - name: Log this runner'"'"'s bash\n        run: bash --version\n' >> "$f"
printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (b): a quoted label containing '#' is not silently truncated to an approved one"

# (c) `defaults: {run: {shell: sh}}` routes EVERY step in the workflow around bash, and a
#     line-anchored `^[[:space:]]*shell:` grep never saw it.
d="$work/inlineshell"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf 'defaults: {run: {shell: sh}}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (c): an INLINE defaults shell override is caught"

# (d) The guard invocation in an `env:` value satisfied a bare substring test while executing
#     nothing. A step name or an `echo` would have done the same.
d="$work/envmention"; f="${ new_wf "$d"; }"
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
d="$work/floorenv"; f="${ new_wf "$d"; }"
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
d="$work/echoedguard"; f="${ new_wf "$d"; }"
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
d="$work/quotedjob"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '  "hidden":\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        run: echo hi\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (g): a QUOTED job id is seen, not skipped"
has "$OUT" "hidden" "fail-open (g) names the quoted job"

# (h) `defaults: {run: {"shell": sh}}` — the quoted spelling of (c), same effect, previously unseen.
d="$work/quotedshell"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf 'defaults: {run: {"shell": sh}}\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (h): a QUOTED shell key is caught too"

# --- rule 9: the first step must log bash --version (#257 acceptance criterion 2) --------------------
d="$work/nofirstlog"; f="${ new_wf "$d"; }"
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
d="$work/nomacos"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
run_lint "$d"
eq "$RC" "1" "rule 6: a Linux-only workflow is rejected"
has "$OUT" "unproven on the platform where it is hardest to reach" "rule 6 names the missing macOS coverage"

d="$work/nolinux"; f="${ new_wf "$d"; }"
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "rule 6: a macOS-only workflow is rejected"
has "$OUT" "unproven on Linux" "rule 6 names the missing Linux coverage"

# --- the WSL-HOST CLASS (#2) -------------------------------------------------------------------------
#
# This class exists because `windows-latest` CLEARS the floor on its own — Windows Server 2025 ships
# Git-Bash 5.3.15 — so the ordinary rule cannot distinguish "proved the floor inside Ubuntu 26.04"
# from "proved the floor for native MSYS2", a userland #2 ruled unsupported. A widening that merely
# added the label to the allowlist would therefore have manufactured a green, and NOTHING else in
# this suite would have noticed: every other assertion still passes. Each rule below was observed
# red before it was written down here.
WSL_LOG='wsl -d Ubuntu-26.04 -- bash --version'
WSL_GUARD='wsl -d Ubuntu-26.04 --cd /root/adb -- bash scripts/check-bash-floor.sh --runtime'

# emit_wsl_job <file> <job> <guard-run-value> [log-run-value] [after]
#   an EMPTY log value omits the `bash --version` step entirely; "after" emits it AFTER the guard.
emit_wsl_job() {
  {
    printf '  %s:\n' "$2"
    printf '    runs-on: windows-latest\n'
    printf '    steps:\n'
    printf '      - name: Log this runner'"'"'s bash\n'
    printf '        run: bash --version\n'
    [ -n "${4:-}" ] && [ "${5:-}" != after ] && printf '      - name: wsl log\n        run: %s\n' "$4"
    printf '      - name: floor\n        run: %s\n' "$3"
    [ -n "${4:-}" ] && [ "${5:-}" = after ] && printf '      - name: wsl log\n        run: %s\n' "$4"
    :
  } >> "$1"
}

# The clean WSL fixture FIRST — without it every assertion below is satisfied by a lint that simply
# rejects every Windows job, which would be a different bug wearing the same green.
d="$work/wsl-clean"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job "$WSL_GUARD" "$WSL_LOG"
run_lint "$d"
eq "$RC" "0" "wsl: a compliant WSL-host job passes"
has "$OUT" "1 WSL-host" "wsl: and the count is REPORTED, so a zero is visible rather than inferred"

# THE rule. The bare invocation is the false proof: it passes on this runner while proving the floor
# for an unsupported userland, which is strictly worse than no Windows job at all.
d="$work/wsl-bare"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job 'bash scripts/check-bash-floor.sh --runtime' "$WSL_LOG"
run_lint "$d"
eq "$RC" "1" "wsl: the BARE host invocation does not satisfy a WSL-host job"
has "$OUT" "NOT a supported runtime" "wsl: and the diagnostic says why the host's own bash is not the answer"

# `-d` is required, not cosmetic: a bare `wsl --` runs in whatever distro is DEFAULT on the image,
# which is not the one the job installed.
d="$work/wsl-nodistro"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job 'wsl -- bash scripts/check-bash-floor.sh --runtime' "$WSL_LOG"
run_lint "$d"
eq "$RC" "1" "wsl: an unnamed distro (no -d) is rejected"

# The same two spellings the bare form already had to survive, transplanted: a guard that is merely
# QUOTED or MENTIONED runs zero times, and one behind a separator is a different command.
d="$work/wsl-echoed"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job 'wsl -d Ubuntu-26.04 -- echo bash scripts/check-bash-floor.sh --runtime' "$WSL_LOG"
run_lint "$d"
eq "$RC" "1" "wsl: an ECHOED guard inside the wsl invocation does not count as running it"

d="$work/wsl-chained"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job 'wsl -d Ubuntu-26.04 -- true; bash scripts/check-bash-floor.sh --runtime' "$WSL_LOG"
run_lint "$d"
eq "$RC" "1" "wsl: a guard behind a command separator is not the wsl invocation"

# No WSL bash logged at all — the log then never says which interpreter the distro supplied.
d="$work/wsl-nolog"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job "$WSL_GUARD" ""
run_lint "$d"
eq "$RC" "1" "wsl: a WSL-host job that never logs the distro's bash is rejected"

# ...and logging it AFTER the proof is the same defect wearing a compliant-looking step: the version
# printed then describes a run that has already been asserted about.
d="$work/wsl-lateorder"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job "$WSL_GUARD" "$WSL_LOG" after
run_lint "$d"
eq "$RC" "1" "wsl: the distro's bash logged AFTER the guard is rejected"
has "$OUT" "at or AFTER the guard step" "wsl: and the diagnostic names the ordering"

# THE CONVERSE, and it is the half a one-directional widening would have dropped: admitting the wsl
# form must not let a LINUX or macOS job satisfy its own guard through it. Without this the widening
# would have handed every existing job a second, unproven way to look compliant.
d="$work/wsl-linuxform"; f="${ new_wf "$d"; }"
emit_job "$f" macos-job macos-latest 1
{
  printf '  linux-job:\n    runs-on: ubuntu-26.04\n    steps:\n'
  printf '      - name: Log this runner'"'"'s bash\n        run: bash --version\n'
  printf '      - name: floor\n        run: %s\n' "$WSL_GUARD"
} >> "$f"
run_lint "$d"
eq "$RC" "1" "wsl: a LINUX job may not satisfy its guard through the wsl form"
has "$OUT" "linux-job" "wsl: and the converse names the job that tried it"

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

# --- THE OBSERVER MUST STAY EVALUABLE BELOW THE FLOOR (#259) ----------------------------------
# The third carve-out, alongside common.sh (D30) and the gate exemption itself (D31) — and the one
# a modernization sweep is most likely to erase, because nothing in either file says it exists.
#
# The case immediately above executes the observer under /bin/bash precisely because that is the
# situation it is built to diagnose. So the observer may not contain a construct that interpreter
# cannot EXPAND. bash 5.3's `${ command; }` is the live example, and it is a nastier one than a
# syntax error: 3.2 PARSES it happily — `bash -n` is clean — and then dies at expansion, replacing
# the whole diagnostic with a single `bad substitution` line while still exiting 1. An rc-only
# assertion would not notice.
#
# check-lib.sh is in scope transitively: the observer sources it before running any check. And
# common.sh is in scope because D30 says so — it is the FIRST of the three, and leaving it out
# would be the worst omission of the three, since every entry point sources it before it can
# report anything at all.
#
# A SOURCE scan rather than an execution, deliberately. The case above only runs where /bin/bash is
# genuinely 3.2, so it skips on every Linux runner; this must hold everywhere.
#
# ONLY WHOLE-LINE COMMENTS ARE DROPPED, not everything after the first `#`. `sed 's/#.*//'` — the
# idiom the `sort -V` ban uses — does not understand quoting, so a line like
# `printf '#'; x=${ printf hi; }` is truncated at the QUOTED hash and the funsub after it becomes
# invisible. That is a guard that can be made blind by ordinary code, so this drops only lines that
# are entirely a comment, and a funsub sharing a line with a trailing comment is still seen. The
# cost is that a `${ …; }` written inside a trailing comment would false-positive — loudly, which
# is the safe direction, and the two files are checked below to confirm none does today.
bf_above_floor() {   # <file> -> 0 if it contains a construct bash 3.2 cannot expand
  grep -v '^[[:space:]]*#' "$1" | grep -q '\${[[:space:]|]'
}
for _bf_f in "$LINT" scripts/check-lib.sh scripts/lib/common.sh; do
  if bf_above_floor "$_bf_f"; then
    bad "below-floor: $_bf_f uses \${ …; } / \${| …; }, which bash 3.2 cannot expand — and it runs there"
  else
    ok
  fi
done
# ...and the predicate is watched going RED, on a COPY, because a check that cannot answer wrong is
# worse than no check (self-review.md). Injected into a throwaway copy, never the tracked file.
mkdir -p "$work/belowfloor"
cp "$LINT" "$work/belowfloor/probe.sh"
printf 'x=${ printf hi; }\n' >> "$work/belowfloor/probe.sh"
if bf_above_floor "$work/belowfloor/probe.sh"; then ok; else
  bad "below-floor: the scan did NOT fire on an injected \${ …; } — it is checking nothing"
fi
# THE QUOTED-HASH CASE, which is the one a naive `sed 's/#.*//'` cannot see. Review found this:
# the stripper has no idea the `#` is inside quotes, deletes the rest of the line, and the funsub
# after it goes unreported — a guard blinded by ordinary code rather than by a hostile input.
printf "printf '#'; x=\${ printf hi; }\n" > "$work/belowfloor/quotedhash.sh"
if bf_above_floor "$work/belowfloor/quotedhash.sh"; then ok; else
  bad "below-floor: a funsub after a QUOTED '#' is invisible to the scan — comment stripping is too greedy"
fi
# And it must not fire on ordinary parameter expansion, or it would be deleted within a week.
printf 'y="${HOME}${x:-d}${#z}"\n' > "$work/belowfloor/ordinary.sh"
if bf_above_floor "$work/belowfloor/ordinary.sh"; then
  bad "below-floor: the scan fires on ordinary \${VAR} expansion — it would be unusable"
else ok; fi
# ...nor on a whole-line comment that DOCUMENTS the hazard, which all three files legitimately do.
printf '# never write x=${ printf hi; } in this file\n' > "$work/belowfloor/prose.sh"
if bf_above_floor "$work/belowfloor/prose.sh"; then
  bad "below-floor: the scan fires on a whole-line comment explaining the rule"
else ok; fi

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

# =====================================================================================================
# #256 — the RUNTIME GATE (adb_require_bash) and the ENTRY-POINT LINT
#
# Everything above proves #257's OBSERVER: CI records which interpreter each job got. Everything
# below proves #256's ENFORCEMENT: an entry point that got the wrong one repairs itself or stops.
# Same discipline, and for the same reason — a gate's failure mode is silence, so each branch gets
# a fixture that must make the real code come back red.
#
# EVERY FIXTURE IS A THROWAWAY SCRIPT IN $work. Nothing here edits a tracked file: the code under
# test reads tracked files, and testing it by mutating one ends in the `git checkout --` that
# base/practices/self-review.md and git-and-prs.md exist to forbid.
# =====================================================================================================

COMMON="$PWD/scripts/lib/common.sh"
SYS_BASH=/bin/bash

# A throwaway entry point that gates itself, then reports what it is running on.
# $1 = path, $2 = the function to call (adb_require_bash | adb_require_bash_advisory), $3 = extra
# lines injected before the call (used to stub adb_bash_candidates).
make_entry() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '. "%s"\n' "$COMMON"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf '%s "$@"\n' "$2"
    # Report the VERSION, not just the path. The first cut printed "$BASH" — a path like
    # /bin/bash — and the negative assertion then searched the output for "3.2.57", a string the
    # fixture never emitted. It would have passed even if the old interpreter had run the body,
    # which is precisely the regression it was named for. Review caught it; this prints
    # BASH_VERSINFO so the assertions can compare against the real floor.
    printf 'printf "RAN under %%s version %%s.%%s.%%s\\n" "$BASH" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"\n'
    printf 'printf "ARG[%%s]\\n" "$@"\n'
  } > "$1"
  chmod +x "$1"
}

# The version the fixture reported, or empty. Parsed from its own output so an assertion can say
# "at or above the floor" instead of pattern-matching a string nobody printed.
fixture_version() {
  printf '%s\n' "$1" | sed -n 's/^RAN under .* version \([0-9][0-9.]*\)$/\1/p' | head -n 1
}

# A stub interpreter that CLAIMS version $2 when probed. $3 controls what it does when actually
# run: "lie" execs the real system bash (so it reports >= floor but delivers 3.2 — the exec-loop
# scenario), anything else is inert.
make_stub_bash() {
  mkdir -p "$(dirname "$1")"
  { printf '#!/bin/sh\n'
    printf 'if [ "$1" = "-c" ]; then printf "%s"; exit 0; fi\n' "$2"
    if [ "${3:-}" = "lie" ]; then printf 'exec %s "$@"\n' "$SYS_BASH"; else printf 'exit 0\n'; fi
  } > "$1"
  chmod +x "$1"
}

# --- the gate's happy path --------------------------------------------------------------------------
d="$work/rb"; mkdir -p "$d"
make_entry "$d/ok.sh" adb_require_bash ""
out="$(bash "$d/ok.sh" alpha 2>&1)"; rc=$?
eq "$rc" "0" "gate: an interpreter at or above the floor passes straight through"
has "$out" "RAN under" "gate: the script actually ran"
hasnt "$out" "FATAL" "gate: a passing run says nothing at all"

# --- THE acceptance fixture (#256): a real 3.2 with Homebrew hidden from PATH ------------------------
# This is the reported failure, reproduced rather than described: `brew install bash` succeeded, and
# a defensive ~/.zshrc line ordering /usr/bin:/bin ahead of /opt/homebrew/bin meant `env bash` still
# resolved 3.2.57. PATH is where the wrong answer comes from, so the fixed candidate list is the only
# thing that can find the right one. Guarded on a genuinely old /bin/bash so this asserts nothing
# false on Linux, where /bin/bash IS 5.3.
sysv="$("$SYS_BASH" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || echo 99)"
if [ -x "$SYS_BASH" ] && [ "$sysv" = "3.2" ]; then
  out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$SYS_BASH" "$d/ok.sh" alpha 2>&1)"; rc=$?
  eq "$rc" "0" "re-exec: a real 3.2 with PATH shadowing Homebrew still reaches a >= floor interpreter"
  # ASSERT THE VERSION IT LANDED ON, not the absence of a string. `hasnt "$out" "3.2.57"` was the
  # first cut and it proved nothing: the fixture printed only a PATH, so the assertion passed
  # whether or not the re-exec happened. This reads the version the fixture reported and compares
  # it against the real floor through the real comparator.
  got="${ fixture_version "$out"; }"
  if [ -n "$got" ]; then
    adb_version_ge "$got" "$ADB_BASH_FLOOR_DEFAULT"
    yes $? "re-exec: the interpreter it LANDED on ($got) is at or above the $ADB_BASH_FLOOR_DEFAULT floor"
  else
    bad "re-exec: the fixture reported no version at all — the assertion cannot be made"
  fi

  # ARGUMENT BYTES, not just argument count. exec is the one place a quoted empty string, an
  # embedded space or a glob character can be silently reshaped, and every entry point that gates
  # itself passes "$@" through this.
  out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$SYS_BASH" "$d/ok.sh" alpha "b c" '' 'x*y' 2>&1)"
  has "$out" "ARG[alpha]" "re-exec: a plain argument survives"
  has "$out" "ARG[b c]"   "re-exec: an argument containing a space survives as ONE argument"
  has "$out" "ARG[]"      "re-exec: an EMPTY argument survives as an argument"
  has "$out" "ARG[x*y]"   "re-exec: a glob character survives unexpanded"

  # THE NEGATIVE JOB docs/ci-runners.md said #256 owed: the suite proven to FAIL below the floor,
  # against a real old interpreter rather than a lowered constant. Runs on the macOS CI job, which
  # is the only place a real 3.2 exists.
  out="$(_ADB_BASH_REEXEC=1 "$SYS_BASH" "$d/ok.sh" 2>&1)"; rc=$?
  eq "$rc" "1" "negative: a REAL 3.2 that cannot re-exec fails the entry point outright"
  hasnt "$out" "RAN under" "negative: the script body never executed on the old interpreter"
fi

# --- fail closed when no candidate qualifies --------------------------------------------------------
make_entry "$d/nocand.sh" adb_require_bash 'adb_bash_candidates() { printf "%s\n" "'"$SYS_BASH"'"; }'
if [ "$sysv" = "3.2" ]; then
  out="$("$SYS_BASH" "$d/nocand.sh" 2>&1)"; rc=$?
  eq "$rc" "1" "no candidate: the gate exits non-zero rather than continuing"
  hasnt "$out" "RAN under" "no candidate: the script body never ran"
  has "$out" "bash >= 5.3 is required" "no candidate: the message names the floor"
  has "$out" "3.2.57" "no candidate: the message names the version actually running"
fi

# A stub reporting a real-shaped 5.2.21 — the OTHER interpreter #256's acceptance names. It is a
# STUB, not a real 5.2 binary: no hosted runner or workstation here has one, and hermetically
# obtaining one is out of reach. Said plainly rather than implied, because claiming a real-5.2
# observation this suite never made is exactly the overstatement these guards exist to prevent.
make_stub_bash "$work/b52/bash" "5.2.21"
make_entry "$d/only52.sh" adb_require_bash 'adb_bash_candidates() { printf "%s\n" "'"$work"'/b52/bash"; }'
if [ "$sysv" = "3.2" ]; then
  out="$("$SYS_BASH" "$d/only52.sh" 2>&1)"; rc=$?
  eq "$rc" "1" "5.2 stub: a 5.2.21 candidate is rejected, not accepted as close enough"
fi
# Platform-independent half of the same claim, so this assertion holds on the Linux runner too.
out="$(bash -c '. "'"$COMMON"'"; adb_version_ge 5.2.21 "$ADB_BASH_FLOOR_DEFAULT"' 2>&1)"; rc=$?
no "$rc" "5.2.21 compares BELOW the floor constant the gate enforces"

# --- the exec-loop sentinel -------------------------------------------------------------------------
# A candidate that probes >= floor but does not deliver it: a wrapper, a shim, a stale symlink. Without
# the sentinel this forks forever; with it, exactly one re-exec then a clean failure.
make_stub_bash "$work/liar/bash" "5.3.99" lie
make_entry "$d/liar.sh" adb_require_bash 'adb_bash_candidates() { printf "%s\n" "'"$work"'/liar/bash"; }'
if [ "$sysv" = "3.2" ]; then
  out="$(bash -c 'exec 2>&1; "$0" "$1"' "$SYS_BASH" "$d/liar.sh" 2>&1)"; rc=$?
  eq "$rc" "1" "sentinel: a LYING candidate produces one re-exec and then a clean failure, not a loop"
  has "$out" "already attempted" "sentinel: the message says a re-exec was tried and did not deliver"
fi

# --- the sentinel must not LEAK to children ---------------------------------------------------------
# The bug this pins was found by this very harness and was live: _ADB_BASH_REEXEC is exported, so a
# re-exec'd parent handed it to every child, and a child starting on the old interpreter then read
# "already attempted" and failed closed instead of repairing itself. selfcheck.sh is exactly that
# shape — it re-execs, then spawns ~30 `bash scripts/check-*.sh`, each resolving `bash` through the
# same wrong PATH — so every one of them would have died.
#
# The fixture is the real shape: a gated parent that re-execs, then runs a gated child the same way
# selfcheck does. Both must end up on a >= floor interpreter.
if [ "$sysv" = "3.2" ]; then
  make_entry "$d/child.sh" adb_require_bash ""
  { printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '. "%s"\n' "$COMMON"
    printf 'adb_require_bash "$@"\n'
    printf 'printf "PARENT on %%s\\n" "$BASH"\n'
    printf 'bash "%s" from-parent || printf "CHILD FAILED rc=%%s\\n" "$?"\n' "$d/child.sh"
  } > "$d/parent.sh"
  chmod +x "$d/parent.sh"
  out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$SYS_BASH" "$d/parent.sh" 2>&1)"; rc=$?
  eq "$rc" "0" "sentinel: a re-exec'd parent's gated CHILD still repairs itself (the leak regression)"
  has "$out" "ARG[from-parent]" "sentinel: the child actually ran, with its arguments"
  hasnt "$out" "CHILD FAILED" "sentinel: the child did not inherit 'already attempted' from its parent"
fi

# --- exec itself fails after a successful probe -----------------------------------------------------
# A candidate can pass the version probe and still be unexecutable a moment later: it vanished, lost
# its exec bit, or was never a binary. bash's rule is that a failed `exec` EXITS a non-interactive
# shell rather than resuming it, so the gate's own diagnostic is never reached — the failure is
# closed one frame earlier, at 126, with bash naming the path. Pinned because the first version of
# the comment beside that `exec` claimed the opposite, and a comment describing control flow that
# does not exist is the kind of thing the next reader builds on.
if [ "$sysv" = "3.2" ]; then
  mkdir -p "$work/notabin"
  { printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '. "%s"\n' "$COMMON"
    printf 'adb_bash_candidates() { printf "%%s\\n" "%s/notabin"; }\n' "$work"
    printf 'adb_bash_version_at() { printf "5.3.9"; }\n'
    printf 'adb_require_bash "$@"\n'
    printf 'printf "RAN\\n"\n'
  } > "$d/execfail.sh"
  out="$("$SYS_BASH" "$d/execfail.sh" 2>&1)"; rc=$?
  eq "$rc" "126" "exec failure: a probe-passing but unexecutable candidate exits 126, fail-closed"
  hasnt "$out" "RAN" "exec failure: the script body never runs"
fi

# --- $0 is not a re-runnable script: sourced, piped, `bash -c` --------------------------------------
# Found in self-review, and it was a live bug rather than a hypothetical: for `… | bash -s` and for
# `bash -c`, bash sets $0 to the INTERPRETER — a perfectly readable file — so a `[ -r "$0" ]` test
# passed and the gate exec'd the bash BINARY as a script (`cannot execute binary file`, rc 126).
if [ "$sysv" = "3.2" ]; then
  out="${ printf '. "%s"\nadb_require_bash "$@"\nprintf "RAN\\n"\n' "$COMMON" | "$SYS_BASH" -s 2>&1; }"; rc=$?
  eq "$rc" "1" "piped script: fails closed instead of exec'ing the bash binary as a script"
  hasnt "$out" "cannot execute binary file" "piped script: never tries to run the interpreter as a script"
  has "$out" "not a re-runnable script file" "piped script: says WHY it could not re-exec"

  out="$("$SYS_BASH" -c ". \"$COMMON\"; adb_require_bash; printf 'RAN\n'" 2>&1)"; rc=$?
  eq "$rc" "1" "bash -c: fails closed for the same reason"
  hasnt "$out" "RAN" "bash -c: the body never ran"
fi

# --- the ADVISORY form returns; it never exits ------------------------------------------------------
make_entry "$d/adv.sh" adb_require_bash_advisory 'adb_bash_candidates() { printf "%s\n" "'"$SYS_BASH"'"; }'
if [ "$sysv" = "3.2" ]; then
  out="$("$SYS_BASH" "$d/adv.sh" 2>/dev/null)"; rc=$?
  eq "$rc" "0" "advisory: a sub-floor interpreter does NOT kill an entry point whose contract forbids it"
  has "$out" "RAN under" "advisory: the body still runs, degraded rather than dead"
fi

# --- the floor constant is NOT overridable from the environment -------------------------------------
# ADB_BASH_FLOOR is #257's test seam for the LINT. A production gate honoring it would be a
# user-settable bypass of the thing it enforces — `ADB_BASH_FLOOR=0` waving 3.2 through every entry
# point in the repo. The seam stays with the lint; the gate has none.
if [ "$sysv" = "3.2" ]; then
  out="$(ADB_BASH_FLOOR=0.0 _ADB_BASH_REEXEC=1 "$SYS_BASH" "$d/ok.sh" 2>&1)"; rc=$?
  eq "$rc" "1" "gate: ADB_BASH_FLOOR=0.0 does NOT lower the runtime gate (it is the lint's seam only)"
fi

# --- the candidate list must cover every install route the docs claim ------------------------------
# Review found the docs promising MacPorts/Nix/source builds while the list knew only Homebrew and
# the system paths — so a MacPorts user whose hook shell carries the usual bare /usr/bin:/bin would
# be told no bash 5.3 exists on a machine where it is installed. The list and the claim have to move
# together, which is what this asserts.
cands="$(bash -c '. "'"$COMMON"'"; adb_bash_candidates')"
has "$cands" "/opt/homebrew/bin/bash" "candidates: Homebrew on Apple Silicon"
has "$cands" "/usr/local/bin/bash"    "candidates: Homebrew on Intel, and the default source-build prefix"
has "$cands" "/opt/local/bin/bash"    "candidates: MacPorts — named in docs/installation.md"
has "$cands" "nix"                    "candidates: a Nix profile — also named in docs/installation.md"
has "$cands" "/bin/bash"              "candidates: the system path"
# HOME is routinely absent in the stripped environments this function exists for; it must not die.
out="$(env -i "$BASH" -c '. "'"$COMMON"'"; adb_bash_candidates >/dev/null; echo SURVIVED' 2>&1)"
has "$out" "SURVIVED" "candidates: an unset HOME does not break the list"

# --- the floor comparison is FORK-FREE, and must stay that way --------------------------------------
# The gate answers "is this shell usable" at the top of every entry point. It must not need a second
# program to decide that: when `awk` is the broken thing, a forking comparison reports `bash >= 5.3
# is required` and sends the operator after the wrong fault. Driven with a stub `awk` on PATH, the
# same way check-roadmap.sh proves its own filter fails closed.
awk_stub="$work/awkstub"; mkdir -p "$awk_stub"
printf '#!/bin/sh\nexit 7\n' > "$awk_stub/awk"; chmod +x "$awk_stub/awk"
# "$BASH", not `bash`: this must run on a KNOWN >= floor interpreter, and `bash` is resolved from a
# PATH that on a stock Mac points at 3.2.57 — which would make this assert the opposite of what it
# is named for. This script gated its own interpreter at the top, so $BASH is >= the floor by
# construction.
out="$(PATH="$awk_stub:$PATH" "$BASH" -c '. "'"$COMMON"'"; adb_bash_self_ok; printf "%s" "$?"' 2>/dev/null)"
eq "$out" "0" "floor compare: a BROKEN awk does not make a good interpreter look sub-floor"
if [ "$sysv" = "3.2" ]; then
  out="$(PATH="$awk_stub:$PATH" "$SYS_BASH" "$d/ok.sh" alpha 2>&1)"; rc=$?
  eq "$rc" "0" "floor compare: the re-exec still finds a candidate with awk broken"
  has "$out" "ARG[alpha]" "floor compare: and the script runs"
fi
# The floor question itself, against the ONE comparator. An earlier cut answered it in a separate
# `adb_bash_ge_floor` helper; review correctly called that a second implementation, since for the
# real floor and a normal BASH_VERSINFO it returned the final answer and `adb_version_ge` was never
# reached on the operational path. The shortcut moved INSIDE adb_version_ge, and the two paths are
# differentially tested against each other in check-common-lib.sh.
out="$("$BASH" -c '. "'"$COMMON"'"
                   for v in 5.3 5.3.15 5.2.21 3.2.57 6.0; do
                     adb_version_ge "$v" "$ADB_BASH_FLOOR_DEFAULT"; printf "%s " "$?"
                   done' 2>/dev/null)"
out="${out% }"
eq "$out" "0 0 1 1 0" "floor compare: 5.3/5.3.15/6.0 clear it; 5.2.21 and 3.2.57 do not"

# --- the ADVISORY files keep their contracts even when the library is broken -------------------------
# statusline.sh runs under `set -euo pipefail`, so a source that returns non-zero — an unreadable or
# corrupt common.sh — aborted it before the documented `claude-code` fallback could print, handing
# the harness a failed statusLine command instead of a harmless cosmetic line. Review found it.
# Fixtures are copies; the live tree is never touched.
sl_src="agents/claude/scripts/statusline.sh"
if [ -f "$sl_src" ]; then
  sl="$work/sl"; mkdir -p "$sl/scripts/lib"
  cp "$sl_src" "$sl/scripts/statusline.sh"
  printf 'this is not valid shell ((((\n' > "$sl/scripts/lib/common.sh"
  out="${ printf '{"model":{"display_name":"x"}}' | "$BASH" "$sl/scripts/statusline.sh" 2>/dev/null; }"; rc=$?
  eq "$rc" "0" "statusline: a CORRUPT common.sh still exits 0 (errexit must not beat the fallback)"
  eq "$out" "claude-code" "statusline: and prints the documented fallback line"

  # ...and the ordinary path is unaffected, or the assertion above is satisfied by a broken script.
  rm -rf "$sl/scripts/lib"; mkdir -p "$sl/scripts/lib"
  cp scripts/lib/common.sh "$sl/scripts/lib/common.sh"
  out="${ printf '{"model":{"display_name":"opus"}}' | "$BASH" "$sl/scripts/statusline.sh" 2>/dev/null; }"; rc=$?
  eq "$rc" "0" "statusline: a healthy library still renders"
  has "$out" "opus" "statusline: and renders the real field, not the fallback"
fi

# --- the ENTRY-POINT LINT, rule by rule -------------------------------------------------------------
# Its failure mode is the usual one: a classifier that stops recognizing files reports the same clean
# verdict as a compliant tree. Each rule gets a fixture tree it must reject, plus a clean tree proving
# the lint is not simply red-always.
ep_lint() { EPOUT="$(bash "$LINT" --entrypoints "$1" 2>&1)"; EPRC=$?; }

# ep_tree <dir> <body-lines…> — a tree with one compliant entry point plus whatever the caller adds.
ep_tree() {
  mkdir -p "$1/scripts"
  printf '#!/usr/bin/env bash\nset -u\nadb_require_bash "$@"\ncd /tmp\n' > "$1/scripts/compliant.sh"
}

d="$work/ep-clean"; ep_tree "$d"; ep_lint "$d"
eq "$EPRC" "0" "entrypoints: a compliant tree passes"
has "$EPOUT" "1 entry point(s)" "entrypoints: the lint reports how many it classified"
has "$EPOUT" "1 gate, 0 advisory, 0 exempt" "entrypoints: and the per-class counts, so a blind scan is visible"

d="$work/ep-missing"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\ncd /tmp\n' > "$d/scripts/ungated.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a shebang-bearing file that never calls the gate is rejected"
has "$EPOUT" "ungated.sh" "entrypoints: the offending file is named"

d="$work/ep-comment"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\n# adb_require_bash "$@"\ncd /tmp\n' > "$d/scripts/commented.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a COMMENTED call does not count as calling it"
has "$EPOUT" "commented.sh" "entrypoints: the commented file is named"

# A TRAILING comment must not count either, and this one is not hypothetical: the first cut of this
# lint stripped only whole-line comments, so `x=1  # TODO: adb_require_bash "$@"` reported an
# entirely ungated entry point as compliant. Same species as the `env:`-mention and echoed-guard
# fail-opens above — a note about doing the thing read as the thing.
d="$work/ep-trailing"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\nx=1   # TODO: adb_require_bash "$@"\ncd /tmp\n' > "$d/scripts/trailing.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a TRAILING comment mentioning the gate does not count as calling it"
has "$EPOUT" "trailing.sh" "entrypoints: the trailing-comment file is named"

d="$work/ep-late"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\ncd /tmp\nadb_require_bash "$@"\n' > "$d/scripts/late.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a call AFTER a cd is rejected — \$0 may no longer resolve"
has "$EPOUT" "AFTER a cd" "entrypoints: the message says what came first"

d="$work/ep-stdin"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\ninput="$(cat)"\nadb_require_bash "$@"\n' > "$d/scripts/stdin.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a call after a stdin read is rejected — the re-exec cannot restore a drained payload"

d="$work/ep-variant"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash_advisory "$@"\n' > "$d/scripts/soft.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: an unclassified file may not quietly pick the ADVISORY form"
has "$EPOUT" "is not a gate" "entrypoints: the message says why the soft form is wrong there"

# The classification is bidirectional, which is the half that keeps `advisory` from becoming a dial.
d="$work/ep-adv-hard"; ep_tree "$d"; mkdir -p "$d/agents/claude/scripts"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash "$@"\n' > "$d/agents/claude/scripts/statusline.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a declared-ADVISORY file using the hard-failing form is rejected too"
has "$EPOUT" "classified ADVISORY" "entrypoints: the message names the classification it violated"

d="$work/ep-adv-ok"; ep_tree "$d"; mkdir -p "$d/agents/claude/scripts"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash_advisory "$@"\n' > "$d/agents/claude/scripts/statusline.sh"
ep_lint "$d"
eq "$EPRC" "0" "entrypoints: a declared-ADVISORY file using the advisory form passes"
has "$EPOUT" "1 advisory" "entrypoints: and is counted as advisory, not as a gate"

# The exemption has to be VISIBLE, or it is indistinguishable from an oversight.
d="$work/ep-exempt"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\n' > "$d/scripts/check-bash-floor.sh"
ep_lint "$d"
eq "$EPRC" "0" "entrypoints: the exempt observer is allowed NOT to call the gate"
has "$EPOUT" "1 exempt" "entrypoints: and is reported as exempt rather than silently skipped"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash "$@"\n' > "$d/scripts/check-bash-floor.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: the exempt observer calling the gate is itself an error"
has "$EPOUT" "stop testing" "entrypoints: the message says what wiring it in would break"

# A call inside an UNINVOKED FUNCTION is not a call. The entry point defines it, never runs it, and
# executes its real body on the sub-floor interpreter — while a command-position match anywhere in
# the file reported PASS. Found in review; the scan now stops at the first function definition,
# which is also the invariant the release scripts had to satisfy by hand (bash parses a function
# body when it reaches it, so 5.3-only grammar in one fails to PARSE before the gate can help).
d="$work/ep-infunc"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\nnever_called() {\n  adb_require_bash "$@"\n}\necho real body\n' > "$d/scripts/infunc.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a gate call inside an UNINVOKED function does not count"
has "$EPOUT" "infunc.sh" "entrypoints: the file with the buried call is named"

d="$work/ep-funcfirst"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\nhelper() { echo hi; }\nadb_require_bash "$@"\n' > "$d/scripts/funcfirst.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a gate call AFTER the first function definition is too late"

# ...and the ordinary shape must still pass, or the rule above is just "always red".
d="$work/ep-funcafter"; ep_tree "$d"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash "$@"\nhelper() { echo hi; }\nhelper\n' > "$d/scripts/ok.sh"
ep_lint "$d"
eq "$EPRC" "0" "entrypoints: the gate BEFORE the definitions is the compliant shape"

# SCANNING A SUBDIRECTORY must classify on the repository-relative path. The classification lists
# are repo-relative while the scanner yields paths relative to the scanned dir, so `--entrypoints
# agents/claude` saw `scripts/statusline.sh` and called all three advisory hooks hard gates — a
# valid tree exiting 1. Asserted against the REAL repo, read-only, because the bug is precisely
# about this repo's own layout.
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  EPOUT="$(bash "$LINT" --entrypoints agents/claude 2>&1)"; EPRC=$?
  eq "$EPRC" "0" "entrypoints: scanning a SUBDIRECTORY does not misclassify the advisory hooks"
  has "$EPOUT" "3 advisory" "entrypoints: and it still sees them as advisory, not as gates"
  EPOUT="$(bash "$LINT" --entrypoints scripts 2>&1)"; EPRC=$?
  eq "$EPRC" "0" "entrypoints: scanning scripts/ keeps the observer exemption"
  has "$EPOUT" "1 exempt" "entrypoints: and still counts it as exempt"
fi

d="$work/ep-empty"; mkdir -p "$d"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a tree with no entry points is a failure, not a clean run"
has "$EPOUT" "scanned nothing" "entrypoints: it says it scanned nothing"

# TRACKED files in a real repo, so selfcheck predicts CI. CI checks out tracked files only, so a
# scan that also swept untracked ones could go RED locally on a contributor's scratch script while
# CI stayed green — a local failure CI cannot reproduce, which is how a check gets ignored.
# Asserted against the REAL repo (read-only: it creates one untracked file and removes it).
scratch="scratch-bash-floor-guard-probe.sh"
if [ ! -e "$scratch" ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\necho untracked\n' > "$scratch"
  EPOUT="$(bash "$LINT" --entrypoints . 2>&1)"; EPRC=$?
  rm -f "$scratch"
  eq "$EPRC" "0" "entrypoints: an UNTRACKED scratch script does not fail the repo lint (selfcheck must predict CI)"
  hasnt "$EPOUT" "$scratch" "entrypoints: and it is not even reported"
fi

# --- CRLF and DrvFs (#2) ----------------------------------------------------------------------------
crlf_scan() { CLOUT="$(bash -c '. "'"$COMMON"'"; adb_crlf_scan "$1"' _ "$1" 2>&1)"; CLRC=$?; }

d="$work/crlf"; mkdir -p "$d/bin" "$d/scripts"
printf '#!/usr/bin/env bash\necho ok\n' > "$d/scripts/fine.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$d/bin/agent-init"
# WITH a shebang, deliberately. Without one the scanner skips this file before it ever looks at its
# bytes, so the assertion below proved only that shebang filtering works — not the thing it is
# named for. Review caught it: a fixture excluded from the scan cannot demonstrate how the scan
# treats its contents.
printf '#!/usr/bin/env bash\necho "an escaped \\r is two characters, not a CR byte"\n' > "$d/scripts/escaped.sh"
crlf_scan "$d"
eq "$CLRC" "0" "crlf: a clean tree passes"
hasnt "$CLOUT" "escaped.sh" "crlf: a \\r ESCAPE in source is not mistaken for a CR byte"

printf '#!/usr/bin/env bash\r\necho ok\r\n' > "$d/scripts/fine.sh"
crlf_scan "$d"
eq "$CLRC" "1" "crlf: a CRLF .sh file is caught"
has "$CLOUT" "fine.sh" "crlf: the offending file is named"

printf '#!/usr/bin/env bash\necho ok\n' > "$d/scripts/fine.sh"
printf '#!/usr/bin/env bash\r\necho ok\r\n' > "$d/bin/agent-init"
crlf_scan "$d"
eq "$CLRC" "1" "crlf: an EXTENSIONLESS entry point is caught too — a *.sh-only scan would miss bin/"
has "$CLOUT" "agent-init" "crlf: the extensionless file is named"

# END TO END, against the REAL installer, because the pieces passing individually is not the claim
# being made — the claim is that a CRLF clone cannot be installed. A throwaway tree COPY with one
# corrupted file, per base/practices/self-review.md: the live tree is never touched, and the file
# chosen is an extensionless one so this also proves the *.sh-only blind spot stays closed.
crlf_repo="$work/crlf-install"; mkdir -p "$crlf_repo"
if check_copy_worktree "$PWD" "$crlf_repo/repo"; then
  printf '#!/usr/bin/env bash\r\necho x\r\n' > "$crlf_repo/repo/bin/agent-init"
  mkdir -p "$crlf_repo/home"
  out="$(HOME="$crlf_repo/home" bash "$crlf_repo/repo/install.sh" --agent claude --no-hooks 2>&1)"; rc=$?
  eq "$rc" "1" "install: a CRLF-corrupted clone is REFUSED, not installed"
  has "$out" "agent-init" "install: the refusal names the corrupted file"
  has "$out" "Re-clone INSIDE the WSL filesystem" "install: and hands over the non-destructive remedy"
  # Nothing was linked: a preflight that fails after doing half the install is worse than none.
  [ -e "$crlf_repo/home/.claude/CLAUDE.md" ] && bad "install: the refused install still created links" || ok
fi

# A SOURCED LIBRARY has no shebang, and common.sh is the one every entry point loads. A
# shebang-only scan called such a tree clean while the load-bearing file was corrupt — review
# reproduced it, and it is why the scanner now selects on `*.sh` OR a shebang.
d2="$work/crlf-lib"; mkdir -p "$d2/scripts/lib"
printf '#!/usr/bin/env bash\necho ok\n' > "$d2/scripts/entry.sh"
printf 'adb_thing() { :; }\n' > "$d2/scripts/lib/common.sh"          # no shebang: a sourced library
crlf_scan "$d2"
eq "$CLRC" "0" "crlf: a clean tree with a sourced library passes"
printf 'adb_thing() { :; }\r\n' > "$d2/scripts/lib/common.sh"
crlf_scan "$d2"
eq "$CLRC" "1" "crlf: a CRLF SOURCED LIBRARY is caught — it has no shebang to select it by"
has "$CLOUT" "common.sh" "crlf: the corrupted library is named"

# ...and install.sh must refuse BEFORE it sources that library, or the diagnostic never arrives.
# Its own scanner cannot cover this step: the source is what breaks.
crlf_boot="$work/crlf-boot"; mkdir -p "$crlf_boot"
if check_copy_worktree "$PWD" "$crlf_boot/repo"; then
  perl -pi -e 's/\n/\r\n/' "$crlf_boot/repo/scripts/lib/common.sh" 2>/dev/null \
    || python3 -c 'import sys;p=sys.argv[1];d=open(p,"rb").read();open(p,"wb").write(d.replace(b"\n",b"\r\n"))' "$crlf_boot/repo/scripts/lib/common.sh"
  mkdir -p "$crlf_boot/home"
  out="$(HOME="$crlf_boot/home" bash "$crlf_boot/repo/install.sh" --agent claude --no-hooks 2>&1)"; rc=$?
  eq "$rc" "1" "install: a CRLF common.sh is refused BEFORE it is sourced"
  has "$out" "has CRLF line endings" "install: with a diagnostic naming the cause"
  # The diagnostic must LEAD. Asserting the absence of "command not found" would be wrong — the
  # message itself quotes that string to explain the symptom — so assert the ordering instead:
  # the first line is ours, which is only true if the refusal came before the source.
  # `$(printf '\n')` is NOT usable as the pattern here — command substitution strips trailing
  # newlines, so it expands to empty and `${out%%*}` eats the whole string. head(1) is the honest
  # way to take a first line.
  eq "${ printf '%s\n' "$out" | head -n 1; }" \
     "install.sh: FATAL — scripts/lib/common.sh has CRLF line endings, so nothing here can load." \
     "install: and it is the FIRST line, i.e. the refusal preceded the source"
fi

# The remedy must not hand the user a command that destroys uncommitted work. `git checkout .` is
# named in base/practices/git-and-prs.md as unrecoverable, and #2's own body suggested it.
rem="$(bash -c '. "'"$COMMON"'"; adb_crlf_remedy' 2>&1)"
hasnt "$rem" "git checkout ." "crlf remedy: never suggests the bare git checkout that discards uncommitted work"
has "$rem" "Re-clone INSIDE the WSL filesystem" "crlf remedy: leads with the non-destructive fix"

# DrvFs: a WARNING, never a failure, and only for the Windows DRIVE shape. `/mnt/data` is an
# ordinary Linux mountpoint on every non-WSL machine, and firing on it would be noise for people
# who have never touched Windows.
drv() { DRVOUT="$(WSL_DISTRO_NAME="${2:-}" bash -c '. "'"$COMMON"'"; adb_drvfs_warn "$1"' _ "$1" 2>&1)"; DRVRC=$?; }
drv /mnt/c/Users/x/repo Ubuntu-26.04
eq "$DRVRC" "0" "drvfs: a /mnt/c path WARNS and returns success — it never blocks the install"
has "$DRVOUT" "WARNING" "drvfs: and it does warn"
drv /mnt/data/repo Ubuntu-26.04
eq "$DRVRC" "0" "drvfs: /mnt/data is an ordinary mountpoint, not a Windows drive"
hasnt "$DRVOUT" "WARNING" "drvfs: so it says nothing"
drv /home/me/repo Ubuntu-26.04
hasnt "$DRVOUT" "WARNING" "drvfs: a normal Linux path says nothing"
drv /mnt/c/Users/x/repo ""
if [ -z "${WSL_INTEROP:-}" ] && ! grep -qi microsoft /proc/version 2>/dev/null; then
  hasnt "$DRVOUT" "WARNING" "drvfs: outside WSL entirely, even /mnt/c says nothing"
fi

# --- usage ------------------------------------------------------------------------------------------
bash "$LINT" --bogus >/dev/null 2>&1; no $? "an unknown flag exits non-zero"
bash "$LINT" --workflow-dir >/dev/null 2>&1; no $? "--workflow-dir with no argument exits non-zero"

check_summary "check-bash-floor-guard"
