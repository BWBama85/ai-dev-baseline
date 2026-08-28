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
# rules (approved label · guard wired via `run:` · no `shell` key · no bash-floor TEST SEAM in a
# workflow, meaning EITHER of the two — ADB_BASH_FLOOR or, since #310, ADB_SUB_FLOOR_CANDIDATES ·
# per-file zero jobs · no workflow files · Linux present · macOS present · first step logs
# `bash --version` · and the three WSL-class rules #2 added: the guard reached through
# `wsl -d <distro>` · a WSL bash version logged at all · that log preceding the guard), THREE
# runtime ones ($BASH below floor · PATH bash below floor or absent · a malformed floor override),
# and — since #310, extended by #315 — TEN sub-floor ones (a 5.3 command substitution in any of the
# three carve-out files · a file that will not parse under a sub-floor interpreter · a common.sh
# that sources noisily · one that leaves adb_require_bash unreachable · a stale entry in the
# carve-out list · a candidate that probes but cannot run · the selection itself picking the
# numerically oldest rather than the first-listed or the lexically smallest · and #315's three:
# any of D30's OTHER FOUR named constructs anywhere in a carve-out file, function bodies included ·
# a per-line exemption marker that does not name the class it is claimed for, or does not sit in
# trailing-comment position · an EMPTY construct table) — so each gets a fixture that must make the
# real lint come back red, plus a clean fixture proving the lint is not simply red-always.
#
# #315 also changed HOW both source scans read their input rather than adding a rule: they splice
# backslash-newlines, so a construct split across a line continuation no longer escapes either of
# them. That is not a fourth category — it is a property of the two scans above — but it carries its
# own fixtures, because getting it wrong is a fail-open in BOTH directions: too little splicing
# misses a split construct, too much merges independent statements and lets a marker on one sanction
# a construct on another.
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
#
# THIS SUITE CAN PASS ON YOUR MACHINE AND FAIL ON THE OTHER RUNNER, and the sub-floor half is where
# that bites: macOS carries a real sub-floor bash (/bin/bash 3.2.57) and runs the probes, while
# ubuntu-26.04 has none and states a SKIP — two different summary branches from one unseamed call.
# An assertion pinned to a phrase only one branch prints passes locally and fails in CI on a claim
# that was never about the platform. That shipped once (#310).
#
# So before pushing a change to the sub-floor assertions, run the OTHER platform's shape too. On a
# copy, never the tracked tree — stub `sysv` so the genuinely-3.2 blocks skip as they do on Linux,
# and hand it a candidate list with nothing below the floor:
#
#   T="$(mktemp -d)"; cp -R scripts install.sh uninstall.sh .github agents bin "$T/"
#   sed -i.bak 's/^sysv=.*/sysv="5.3"/' "$T/scripts/check-bash-floor-guard.sh"
#   ADB_SUB_FLOOR_CANDIDATES="$(command -v bash)" bash "$T/scripts/check-bash-floor-guard.sh"
#
# The assertion count legitimately differs between the two (the 3.2-gated block); the FAIL count
# must be zero in both.

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

# (e2) THE SECOND SEAM, added with the sub-floor half (#310). Pointing ADB_SUB_FLOOR_CANDIDATES at a
#      path that does not exist leaves nothing below the floor, so that half reports a SKIP and the
#      job goes green with rule B disabled on every job in scope. It is not a substring of
#      ADB_BASH_FLOOR, so the single-token grep this rule used to be would never have matched it —
#      which is why this fixture exists rather than being assumed covered by (e).
d="$work/candenv"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
printf '    env:\n      ADB_SUB_FLOOR_CANDIDATES: /nonexistent/bash\n' >> "$f"
run_lint "$d"
eq "$RC" "1" "fail-open (e2): a workflow may not set ADB_SUB_FLOOR_CANDIDATES either"
has "$OUT" "ADB_SUB_FLOOR_CANDIDATES" "fail-open (e2) names the seam it found"

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

# --- INDENTATION IS NOT THE GRAMMAR (#102, #262) ---------------------------------------------------
# This lint used to pin job keys to two spaces, job properties to four, and STEPS to six. A uniform
# 4-space workflow is valid YAML that GitHub runs, and every rule above went blind on it at once:
# zero jobs seen, so rule 4 fired for the wrong reason and no runner label, guard wiring, or step
# ordering was ever evaluated. Rule 4 firing is what made that survivable here — the sibling
# consumer (repo-settings.sh discovery) had no such backstop and simply reported success.
#
# `emit_job` writes 2-space YAML, so these fixtures are hand-written at 4 spaces.
emit_job4() {   # emit_job4 <file> <job> <runs-on> <wire-guard 0|1>
  {
    printf '    %s:\n' "$2"
    printf '        name: %s\n' "$2"
    printf '        runs-on: %s\n' "$3"
    printf '        steps:\n'
    printf '            - name: Log this runner'"'"'s bash\n'
    printf '              run: bash --version\n'
    if [ "$4" = "1" ]; then
      printf '            - name: bash floor\n'
      printf '              run: bash scripts/check-bash-floor.sh --runtime\n'
    else
      printf '            - name: work\n'
      printf '              run: echo hi\n'
    fi
  } >> "$1"
}
new_wf4() { mkdir -p "$1"; printf 'name: CI\non:\n    pull_request:\n\njobs:\n' > "$1/ci.yml"; printf '%s/ci.yml' "$1"; }

d="$work/four-clean"; f="${ new_wf4 "$d"; }"
emit_job4 "$f" linux-job ubuntu-26.04 1
emit_job4 "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "4-space: a compliant workflow PASSES (it used to report zero jobs)"
has "$OUT" "2 job(s)" "4-space: both jobs are counted"
has "$OUT" "1 Linux, 1 macOS" "4-space: both platforms are recognized"

# READING THE FILE IS ONLY HALF OF IT. A rule that silently stopped firing at the new indent would
# report a clean run over a job that violates it — so each rule is driven to red at 4 spaces too,
# not merely shown to parse.
d="$work/four-badrunner"; f="${ new_wf4 "$d"; }"
emit_job4 "$f" linux-job ubuntu-latest 1
emit_job4 "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "4-space: the runner allowlist still rejects ubuntu-latest"
has "$OUT" "runs on 'ubuntu-latest'" "4-space: ...and names the label"

d="$work/four-noguard"; f="${ new_wf4 "$d"; }"
emit_job4 "$f" linux-job ubuntu-26.04 1
emit_job4 "$f" macos-job macos-latest 0
run_lint "$d"
eq "$RC" "1" "4-space: an unguarded job is still rejected"
has "$OUT" "nothing proves the bash it actually got" "4-space: ...for the right reason"

# THE STEP-ORDER RULE is the one that most depended on the pinned indent: `step == 1` is
# meaningless if no step boundary is ever found. At 4 spaces steps sit at 12.
d="$work/four-nolog"; mkdir -p "$d"
{ printf 'name: CI\non:\n    pull_request:\n\njobs:\n'
  printf '    linux-job:\n        name: linux-job\n        runs-on: ubuntu-26.04\n        steps:\n'
  printf '            - name: Checkout\n              uses: actions/checkout@v4\n'
  printf '            - name: bash floor\n              run: bash scripts/check-bash-floor.sh --runtime\n'
} > "$d/ci.yml"
emit_job4 "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "4-space: the FIRST-step 'bash --version' rule still fires"
has "$OUT" "does not log 'bash --version' in its FIRST step" "4-space: ...and names the ordering it wanted"

# A MIXED FILE — 2-space `on:`, 4-space `jobs:` — is valid YAML and defeats any per-file
# "detect the indent unit" heuristic, because the file has two.
d="$work/mixed"; mkdir -p "$d"
printf 'name: CI\non:\n  pull_request:\n\njobs:\n' > "$d/ci.yml"
emit_job4 "$d/ci.yml" linux-job ubuntu-26.04 1
emit_job4 "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "a file mixing a 2-space on: block with a 4-space jobs: block passes"
has "$OUT" "2 job(s)" "...with both jobs visible"

# TWO FILES AT DIFFERENT UNITS, since the scan is per file and a unit detected from one must never
# be applied to another.
d="$work/mixedfiles"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
printf 'name: CI\non:\n    pull_request:\n\njobs:\n' > "$d/four.yml"
emit_job4 "$d/four.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "a repo whose two workflow files use different indent units passes"
has "$OUT" "2 job(s) across 2 file(s)" "...counting both files' jobs"

# --- THE OPPOSITE FILTER, which is the whole reason there are two consumers (#262) ------------------
# repo-settings.sh discovery SKIPS matrix / `if:` / reusable / dynamic-name jobs, because none of
# them reports a provable check context. This lint must see every one of them anyway: a matrix job
# left on ubuntu-latest is still a job running below the floor. Sharing one enumerator is only safe
# if that asymmetry survives it — a shared reader that quietly adopted discovery's skips would take
# exactly the jobs nothing else is watching and stop watching them too.
d="$work/opposite"; mkdir -p "$d"
{ printf 'name: CI\non:\n  pull_request:\n\njobs:\n'
  printf '  matrixed:\n    name: mat\n    strategy:\n      matrix:\n        os: [a, b]\n'
  printf '    runs-on: ubuntu-latest\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
  printf '  conditional:\n    name: cond\n    if: github.event_name == '"'"'push'"'"'\n'
  printf '    runs-on: ubuntu-latest\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
  printf '  dyn:\n    name: d-${{ github.event_name }}\n'
  printf '    runs-on: ubuntu-latest\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
} > "$d/ci.yml"
emit_job "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "opposite filter: a matrix/if/dynamic job on a bad runner is still caught"
has "$OUT" "'matrixed'" "opposite filter: the MATRIX job is checked (discovery skips it)"
has "$OUT" "'conditional'" "opposite filter: the if: job is checked (discovery skips it)"
has "$OUT" "'dyn'" "opposite filter: the dynamic-name job is checked (discovery skips it)"
has "$OUT" "4 job(s)" "opposite filter: all four jobs are enumerated, none skipped"

# A REUSABLE-WORKFLOW job has no `runs-on` at all — discovery skips it as unnameable, and this lint
# must report it rather than pass it: a `uses:` job's runner is the callee's business, which is
# exactly a runner this repo has not proven.
d="$work/reusable"; f="${ new_wf "$d"; }"
printf '  called:\n    uses: ./.github/workflows/other.yml\n' >> "$f"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "opposite filter: a reusable-workflow job is enumerated and reported, not skipped"
has "$OUT" "'called'" "...and named"

# --- MERGE KEYS AND WRAPPED FLOW COLLECTIONS, from THIS consumer's side (#291) ----------------------
# The sibling consumer SKIPS a job it cannot prove a check name for. This lint must do the opposite
# and REPORT it: a job whose runner is unreadable is precisely a job running on an unproven runner,
# and invisible is the one outcome a floor lint may never produce.
d="$work/mergekey"; f="${ new_wf "$d"; }"
{ printf '  base: &base\n    runs-on: ubuntu-26.04\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
  printf '  alt:\n    <<: *base\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
} >> "$f"
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "a job whose runner arrives through a <<: merge key is reported, not silently absent"
has "$OUT" "'alt'" "...and named"
has "$OUT" "runs on '<merge key>'" "...with the CAUSE named, rather than an uninformative '<none>'"
has "$OUT" "3 job(s)" "...and it is enumerated alongside the others, not skipped"

# A job that merges AND declares its own runs-on has a runner this lint CAN read, so it is judged on
# that label. Whether GitHub accepts the file's syntax is the sibling consumer's verdict; failing a
# proven runner here would be this lint answering a question that is not its own.
d="$work/mergeown"; f="${ new_wf "$d"; }"
{ printf '  base: &base\n    runs-on: ubuntu-26.04\n'
  printf '  alt:\n    <<: *base\n    runs-on: ubuntu-latest\n    steps:\n      - name: v\n        run: bash --version\n'
  printf '      - name: g\n        run: bash scripts/check-bash-floor.sh --runtime\n'
} >> "$f"
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "a merging job that declares its OWN runner is judged on that runner"
has "$OUT" "runs on 'ubuntu-latest'" "...by its real label, not by '<merge key>'"

# A WRAPPED INLINE JOB MAPPING is still one job to this lint, and still fails loudly — the reader
# does not decompose it, so its runner is unverifiable. Before the fix its BODY was read as block
# properties, which handed this lint `ubuntu-26.04,` — a flow-syntax fragment as a runner label.
# THE BODY SITS AT THE JOB COLUMN, which is what makes the job-count assertion mean something.
# Review found the four-space version vacuous: indented past the job column, the body was never a
# candidate for enumeration and the pre-fix scanner also reported three jobs. At the job column it
# is exactly what the enumeration join prevents becoming a phantom fourth job.
d="$work/mljobfloor"; f="${ new_wf "$d"; }"
printf '  wrapped: {\n  runs-on: ubuntu-26.04,\n  steps: [x]\n  }\n' >> "$f"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "a wrapped inline job mapping is reported rather than passed"
has "$OUT" "runs on '<inline mapping>'" "...under the unmatchable label, never a flow-syntax fragment"
has "$OUT" "3 job(s)" "...and a body at the JOB COLUMN is not enumerated as a phantom fourth job"
hasnt "$OUT" "'runs-on'" "...specifically, no job is invented from its first continuation line"

# --- the scanner's own failure must PROPAGATE, not read as 'this file has no jobs' ------------------
# The shared reader is fail-closed (a nonce completion trailer), and this asserts the lint honours
# that rather than treating a crashed read as an empty one. A stub `awk` that exits non-zero stands
# in for a reader that died mid-file; without propagation this is indistinguishable from a clean scan.
d="$work/scanfail"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
mkdir -p "$work/awkstub"
printf '#!/bin/sh\nexit 9\n' > "$work/awkstub/awk"; chmod +x "$work/awkstub/awk"
OUT="$(PATH="$work/awkstub:$PATH" bash "$LINT" --workflow-dir "$d" 2>&1)"; RC=$?
eq "$RC" "1" "a crashed job scanner fails the lint (never a silent clean scan)"
has "$OUT" "refusing to report a clean scan" "...and says it is refusing rather than passing"
rm -rf "$work/awkstub"

# --- a block scalar ends at ITS KEY'S column, not at a sequence dash --------------------------------
# The block-scalar skip that closed the impersonation fail-open reached too far: anchored on the
# DASH, it swallowed the entry's SIBLING keys, so a valid `- name: |` step had its real
# `run: bash --version` skipped as scalar text and the lint failed a workflow that is fine.
d="$work/blockkeycol"; mkdir -p "$d"
{ printf 'name: CI\non:\n  pull_request:\n\njobs:\n'
  printf '  linux-job:\n    runs-on: ubuntu-26.04\n    steps:\n'
  printf '      - name: |\n          a multi-line step name\n        run: bash --version\n'
  printf '      - name: floor\n        run: bash scripts/check-bash-floor.sh --runtime\n'
} > "$d/ci.yml"
emit_job "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "0" "a step whose sequence-entry line carries a block scalar still has its sibling keys read"

# ...and closing that must NOT reopen the impersonation hole, in EITHER spelling. Both forms are
# pinned because the fix turns on which pattern is tested first.
d="$work/blockimperson"; mkdir -p "$d"
{ printf 'name: CI\non:\n  pull_request:\n\njobs:\n'
  printf '  linux-job:\n    runs-on: ubuntu-26.04\n    steps:\n'
  printf '      - name: pretend\n        run: |\n'
  printf '          run: bash --version\n          run: bash scripts/check-bash-floor.sh --runtime\n'
} > "$d/ci.yml"
emit_job "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "a plain 'run: |' block that merely PRINTS the guard still proves nothing"
d="$work/blockimperson2"; mkdir -p "$d"
{ printf 'name: CI\non:\n  pull_request:\n\njobs:\n'
  printf '  linux-job:\n    runs-on: ubuntu-26.04\n    steps:\n'
  printf '      - run: |\n'
  printf '          run: bash --version\n          run: bash scripts/check-bash-floor.sh --runtime\n'
} > "$d/ci.yml"
emit_job "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "...and neither does the DASH form '- run: |'"

# --- the eight-field record must refuse what it cannot encode -------------------------------------
# The shared reader's grammar is value-LAST so a tab inside a quoted scalar survives. THIS record
# cannot be: it carries eight fields and static_lint splits them field-by-field. A tab inside a
# quoted `runs-on:` therefore shifted `guard` and `firstlog` into the label's own bytes, and
# independent review reproduced a job with a NONEXISTENT runner being reported as guarded and
# logging — a fail-OPEN in a guard, which is the one outcome this file exists to prevent.
d="$work/tabrunner"; mkdir -p "$d"
{ printf 'name: CI\non:\n  pull_request:\n\njobs:\n'
  printf '  evil:\n    runs-on: "ubuntu-26.04\t1\t1"\n'
} > "$d/ci.yml"
emit_job "$d/ci.yml" macos-job macos-latest 1
run_lint "$d"
eq "$RC" "1" "a TAB inside a quoted runs-on is REFUSED, not silently field-shifted into a pass"
has "$OUT" "cannot encode" "...and the refusal says the record cannot represent the value"

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

# SAME DISTRO. Independent review found this one: keeping only step NUMBERS let a job log distro A's
# bash and prove the floor in distro B, while the ordering rule above reported everything in order.
d="$work/wsl-distromismatch"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job "$WSL_GUARD" 'wsl -d Ubuntu-24.04 -- bash --version'
run_lint "$d"
eq "$RC" "1" "wsl: logging distro A's bash while proving the floor in distro B is rejected"
has "$OUT" "is not the one that was asserted about" "wsl: and the diagnostic names the substitution"

# An EMPTY distro name is syntactically a token but names nothing, so `wsl` falls back to the
# image's default — the exact hole that requiring `-d` was meant to close.
d="$work/wsl-emptydistro"; f="${ new_wf "$d"; }"
emit_job "$f" linux-job ubuntu-26.04 1
emit_job "$f" macos-job macos-latest 1
emit_wsl_job "$f" wsl-job 'wsl -d "" --cd /root/adb -- bash scripts/check-bash-floor.sh --runtime' 'wsl -d "" -- bash --version'
run_lint "$d"
eq "$RC" "1" "wsl: an EMPTY distro name is rejected, not treated as a named distro"
has "$OUT" "names nothing" "wsl: and the diagnostic says why an empty name is not a name"

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

# --- THE SUB-FLOOR HALF: the below-floor set must stay EVALUABLE (#259, #310) ------------------
# The three carve-out files — common.sh (D30), the observer, and the check-lib.sh it sources (D35).
# A modernization sweep is likelier to erase this than anything else in the repo, because the rule
# lives nowhere the edit happens.
#
# The case immediately above executes the observer under /bin/bash precisely because that is the
# situation it is built to diagnose. So none of the three may contain a construct that interpreter
# cannot handle — and there are two distinct ways to break that, which is why `--sub-floor` carries
# two rules and this section drives both:
#
#   RULE A, the source scan. bash 5.3's command substitution is a nastier failure than a syntax
#   error: 3.2 PARSES it happily — `bash -n` is clean — and then dies at expansion, replacing the
#   whole diagnostic with a single `bad substitution` line while still exiting 1. An rc-only
#   assertion would not notice, and rule B genuinely cannot see it.
#
#   RULE B, the parse and the bootstrap probe under a real sub-floor interpreter. This catches the
#   grammar bash grew after 3.2 anywhere in a file, function bodies included, which rule A cannot.
#
# THE PREDICATE MOVED (#310, D54). It used to live here, in this suite, as `bf_above_floor`. That
# made the guard the only place the rule existed — and once `--sub-floor` needed the same list of
# three files, keeping it here meant TWO copies of the below-floor set with nothing tying them
# together. It is now one rule in the lint, driven red from here like every other rule this file
# owns. Nothing it caught is uncaught: all four of its original cases are below, plus the ones only
# an executing check can make.
sf_lint() {   # sf_lint <dir> [env-assignments…] — run --sub-floor against a fixture, set SFRC/SFOUT
  _sfd="$1"; shift
  SFOUT="$(env "$@" bash "$LINT" --sub-floor "$_sfd" 2>&1)"
  SFRC=$?
}

# sf_fixture <dir> — a throwaway tree carrying the three below-floor files at their real relative
# paths, unmodified. Callers mutate ONE thing so a red result is attributable.
#
# THE `rm -rf` IS FENCED TO $work. This helper takes a path and deletes it, and the very next
# assertions point the LINT at `.` — one transposed argument away from erasing the checkout this
# suite is checking, including uncommitted work git could not get back (git-and-prs.md). A refusal
# costs one line; the mistake costs the tree.
#
# `..` IS REFUSED SEPARATELY, because the prefix test alone is LEXICAL and review walked straight
# through it: with `work=/tmp/guard-work`, the path `/tmp/guard-work/../outside` matches
# `"$work"/*` and resolves to a sibling that `rm -rf` would then delete. A fence that can be
# stepped over by two dots is not a fence.
# The fence as its OWN predicate (0 = safe to delete, 1 = refused), so the assertions below can
# drive it without `bad` recording a failure for a refusal that is the correct answer. A guard whose
# safety check cannot be exercised is the shape this whole file exists to reject.
sf_path_ok() {
  case "$1" in
    *"/../"*|*"/..") return 1 ;;
  esac
  case "$1" in
    "$work"/*) return 0 ;;
    *) return 1 ;;
  esac
}

sf_fixture() {
  if ! sf_path_ok "$1"; then
    bad "sub-floor: sf_fixture refused an unsafe path: $1"
    return 1
  fi
  rm -rf "$1"
  mkdir -p "$1/scripts/lib"
  cp scripts/lib/common.sh        "$1/scripts/lib/common.sh"
  cp "$LINT"                      "$1/scripts/check-bash-floor.sh"
  cp scripts/check-lib.sh         "$1/scripts/check-lib.sh"
}

# sf_applied <file> <pattern> <label> — a mutation that did not land makes every assertion after it
# pass for the wrong reason, and a guard suite that cannot tell "the rule fired" from "the fixture
# was never broken" is the failure this whole file exists to prevent.
sf_applied() {
  if grep -Fq -- "$2" "$1"; then ok; else bad "sub-floor: the $3 mutation did NOT apply to $1"; fi
}

SFD="$work/subfloor"

# THE FIXTURE FENCE ITSELF, exercised before anything relies on it. `sf_fixture` takes a path and
# `rm -rf`s it, and the assertions below point the LINT at `.` — one transposed argument from
# erasing the checkout, uncommitted work included. Review walked through the first version of this
# fence: it was a lexical prefix test, and `$work/../outside` satisfies `"$work"/*` while resolving
# to a sibling.
sf_path_ok "$work/ok"                  ; yes $? "fence: a path under \$work is accepted"
sf_path_ok "$work/a/b/c"               ; yes $? "fence: nested paths under \$work are accepted"
sf_path_ok "${work}-sibling/x"         ; no  $? "fence: a path outside \$work is refused"
sf_path_ok "$work/../outside"          ; no  $? "fence: \$work/../outside is refused, not accepted by prefix"
sf_path_ok "$work/a/../../outside"     ; no  $? "fence: a deeper .. escape is refused"
sf_path_ok "$work/.."                  ; no  $? "fence: a trailing .. is refused"
sf_path_ok "."                         ; no  $? "fence: the working tree itself is refused"

# EXTRA ARGUMENTS ARE A USAGE ERROR. This mode's one argument selects the tree it checks, so a
# silently-ignored second one means a green run over a scope the caller did not choose.
bash "$LINT" --sub-floor . unexpected >/dev/null 2>&1
eq "$?" "2" "usage: --sub-floor rejects an extra argument rather than ignoring it"


# THE CLEAN FIXTURE FIRST. Without it every assertion below is satisfied by a mode that returns 1
# unconditionally.
# NOTE this one runs with NO seam, so which summary branch it takes depends on the HOST — macOS has
# a sub-floor bash and runs the probes, a Linux runner has none and states a SKIP. It may therefore
# only assert what BOTH branches say. Pinning a phrase from one of them is precisely what shipped a
# red CI job: it passed on the maintainer's macOS and failed on ubuntu-26.04, on a claim that was
# never about the platform. Both shapes are pinned deterministically further down, through the seams.
sf_fixture "$SFD"
sf_lint "$SFD"
eq "$SFRC" "0" "sub-floor: the clean three-file fixture passes on any host"
has "$SFOUT" "3 file(s) named" "sub-floor: and every branch spells the file count the same way"

# THE TRACKED TREE ITSELF must satisfy the rule — the positive assertion the old in-suite loop made,
# now made against the real mode rather than a private copy of its predicate.
sf_lint "."
eq "$SFRC" "0" "sub-floor: the real tracked below-floor set passes"

# --- rule A: the source scan ---------------------------------------------------------------------
# Injected into COPIES, never the tracked files (self-review.md: negative-test against a copy, and
# git-and-prs.md on why putting a tracked file back is unrecoverable).
#
# EVERY FILE IN THE SET GETS ITS OWN FIXTURE, and that is not thoroughness for its own sake: review
# mutated rule A to skip the observer and the whole suite still passed, because the only fixtures
# were common.sh and check-lib.sh. A rule declared over three files needs three.
#
# ISOLATED, which is why common.sh is NOT the fixture that carries the headline assertion. A
# top-level command substitution in common.sh ALSO fails the evaluation probe, so that fixture
# stays red with rule A deleted entirely — green for the wrong reason. Each file below is checked
# with rule A's own diagnostic, and the isolation is asserted where it can be.
for _sf_target in scripts/check-lib.sh scripts/check-bash-floor.sh scripts/lib/common.sh; do
  sf_fixture "$SFD"
  printf 'ADB_PROBE=${ printf hi; }\n' >> "$SFD/$_sf_target"
  sf_applied "$SFD/$_sf_target" 'ADB_PROBE=${ printf hi; }' "injected command substitution"
  sf_lint "$SFD"
  eq "$SFRC" "1" "rule A: an injected 5.3 command substitution in $_sf_target is caught"
  has "$SFOUT" "5.3 command substitution" "rule A: and the diagnostic says what it found ($_sf_target)"
  has "$SFOUT" "$_sf_target" "rule A: and names the file it found it in"
done

# THE ISOLATING CASE. check-lib.sh is sourced by the observer but carries no gate, and a command
# substitution in it PARSES on 3.2 — so rule A is the only rule that can fail here. If it were
# deleted, this fixture would go green while every other rule still worked.
sf_fixture "$SFD"
printf 'ADB_PROBE=${ printf hi; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule A: fires ALONE — no sub-floor subject, so no other rule can be what failed"
has "$SFOUT" "5.3 command substitution" "rule A: and it is rule A's own diagnostic that fired"

# THE MULTILINE SPELLING, which a pattern requiring a space AFTER the brace cannot see. bash 5.3
# accepts a command substitution whose brace ends the line; review reproduced a fixture the first
# cut of this rule reported clean.
sf_fixture "$SFD"
printf 'ADB_PROBE=${\n  printf hi\n}\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule A: a MULTILINE command substitution is caught too"

# THE QUOTED-HASH CASE, which a naive `sed 's/#.*//'` cannot see: the stripper has no idea the `#`
# is inside quotes, deletes the rest of the line, and the construct after it goes unreported — a
# guard blinded by ordinary code rather than by a hostile input. Review found this originally.
sf_fixture "$SFD"
printf "printf '#'; ADB_PROBE=\${ printf hi; }\n" >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD"
eq "$SFRC" "1" "rule A: a construct after a QUOTED '#' is still seen"

# And it must NOT fire on ordinary parameter expansion, or it would be deleted within a week.
# `set -u`-SAFE by construction: the observer sources check-lib.sh under `set -u`, so a `${#z}` on
# an unset name is an unbound-variable ERROR, and this fixture would go red through the evaluation
# probe while appearing to indict rule A. (That the probe catches it at all is the probe working.)
sf_fixture "$SFD"
printf 'ADB_Y="${HOME}${x:-d}${#HOME}"\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD"
eq "$SFRC" "0" "rule A: ordinary \${VAR} expansion does not trip it"

# ...nor on a whole-line comment DOCUMENTING the hazard, which all three files legitimately do.
sf_fixture "$SFD"
printf '# never write ADB_X=${ printf hi; } in this file\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD"
eq "$SFRC" "0" "rule A: a whole-line comment explaining the rule does not trip it"

# A LINE IS NOT A STATEMENT (#315). A backslash-newline is a line SPLICE, so a construct written
# across one is invisible to a physical-line matcher — a fail-open that BOTH source scans carried
# and that was measured, not reasoned about: a real bash 5.3 expands the fixture below to `hi`,
# and rule A reported the file clean before the splice was added.
sf_fixture "$SFD"
printf 'ADB_PROBE=$\\\n{ printf hi; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule A: a funsub split by a LINE CONTINUATION is caught"

# ...and the splice must REMOVE the backslash, never replace it with a space. A space silently
# reintroduces the hole for this exact input: `X=$\` + `{ …` would become `X=$ {`, which matches
# nothing, instead of the `X=${` bash actually sees. This fixture is what pins that choice.
has "$SFOUT" "5.3 command substitution" "rule A: and the splice rejoins \$ and { rather than separating them"

# --- rule C: the construct scan by NAME (#315) ----------------------------------------------------
# D30 forbids FIVE constructs in these files; rule A owns `${ command; }` and this one owns the
# other four. The gap #315 closed is specifically the FUNCTION BODY: bash 3.2 `bash -n`-accepts all
# four there, and sourcing a file never runs a body, so rules A and B are both blind to them.
#
# EVERY FIXTURE PUTS THE CONSTRUCT IN A FUNCTION BODY, deliberately. A top-level injection is a
# WEAKER test that can pass for the wrong reason: the evaluation probe catches a top-level
# `declare -A` through its stderr half (there is a fixture for exactly that further down), so a
# top-level fixture stays red with rule C deleted entirely.
#
# ADB_BASH_FLOOR=0.0 ON EVERY ONE, which is what makes these assertions about rule C rather than
# about whichever rule happened to fire first: it puts every interpreter on the host at or above the
# floor, so rule B has no subject and cannot supply the redness. That also makes them run
# identically on both runners — the platform split this file's header warns about.
for _sf_target in scripts/check-lib.sh scripts/check-bash-floor.sh scripts/lib/common.sh; do
  # EVERY SPELLING D65 CLAIMS GETS ITS OWN FIXTURE. Review found the first cut pinned only a
  # representative few, so narrowing the flag match, dropping `readonly` from the command
  # alternation, or recognizing only `readlink -f` would each have left the suite green while
  # losing a spelling the decision record advertises. A rule set's claims and its fixtures have to
  # be the same list.
  for _sf_case in \
      'mapfile|adb_probe_fn() { mapfile -t adb_a < /dev/null; }' \
      'mapfile|adb_probe_fn() { readarray -t adb_a < /dev/null; }' \
      'associative-array|adb_probe_fn() { declare -A adb_m; }' \
      'associative-array|adb_probe_fn() { declare -Ag adb_m; }' \
      'associative-array|adb_probe_fn() { declare -gA adb_m; }' \
      'associative-array|adb_probe_fn() { declare -An adb_m; }' \
      'associative-array|adb_probe_fn() { local -Ag adb_m; }' \
      'associative-array|adb_probe_fn() { typeset -A adb_m; }' \
      'associative-array|adb_probe_fn() { readonly -A adb_m; }' \
      'associative-array|adb_probe_fn() { declare -g -A adb_m; }' \
      'associative-array|adb_probe_fn() { declare +x -A adb_m; }' \
      'nameref|adb_probe_fn() { local +x -n adb_r=$1; }' \
      'nameref|adb_probe_fn() { local -n adb_r=$1; }' \
      'nameref|adb_probe_fn() { declare -gn adb_r=$1; }' \
      'nameref|adb_probe_fn() { typeset -n adb_r=$1; }' \
      'nameref|adb_probe_fn() { local -g -n adb_r=$1; }' \
      'readlink-f|adb_probe_fn() { adb_p="$(readlink -f /tmp)"; }' \
      'readlink-f|adb_probe_fn() { adb_p="$(readlink -ef /tmp)"; }' \
      'readlink-f|adb_probe_fn() { adb_p="$(readlink -m /tmp)"; }' \
      'readlink-f|adb_probe_fn() { adb_p="$(readlink -nf /tmp)"; }' \
      'readlink-f|adb_probe_fn() { adb_p="$(readlink --canonicalize /tmp)"; }' ; do
    _sf_class="${_sf_case%%|*}"; _sf_code="${_sf_case#*|}"
    sf_fixture "$SFD"
    printf '%s\n' "$_sf_code" >> "$SFD/$_sf_target"
    sf_applied "$SFD/$_sf_target" "$_sf_code" "injected $_sf_class"
    sf_lint "$SFD" ADB_BASH_FLOOR=0.0
    eq "$SFRC" "1" "rule C: [$_sf_class] in a FUNCTION BODY of $_sf_target is caught"
    has "$SFOUT" "uses $_sf_class" "rule C: and the diagnostic names the construct class"
    has "$SFOUT" "$_sf_target" "rule C: and names the file it found it in"
    has "$SFOUT" "$_sf_code" "rule C: and quotes the offending line back"
  done
done

# THE SPELLINGS THAT MUST NOT FIRE. A rule that reports ordinary code gets deleted within a week,
# and every one of these is real, present shell in this repo's own libraries.
#
# `readlink -n` IS ON THIS LIST DELIBERATELY. The first cut refused every option on `readlink`,
# claiming bare `readlink` was the only portable spelling; review disproved that (`-n` works on
# macOS and GNU alike) and the pattern was narrowed to the CANONICALIZE family — `-f`, `-e`, `-m`,
# `--canonicalize*`, whose letters no other readlink option carries. This fixture is what keeps it
# narrow, since re-widening it to "any flag" would silently ban working, portable shell.
for _sf_clean in \
    'adb_probe_fn() { declare -a adb_idx; }' \
    'adb_probe_fn() { local -r adb_ro=1; }' \
    'adb_probe_fn() { local -i adb_n=1; }' \
    'adb_probe_fn() { local -ir adb_n=1; }' \
    'adb_probe_fn() { declare -x -i adb_c=1; }' \
    'adb_probe_fn() { readonly -f adb_fn; }' \
    'adb_probe_fn() { adb_p="$(readlink /tmp)"; }' \
    'adb_probe_fn() { adb_p="$(readlink -n /tmp)"; }' \
    'adb_probe_fn() { declare +A adb_m; }' \
    'adb_probe_fn() { local +n adb_r; }' \
    'adb_probe_fn() { adb_v="${BASH_VERSINFO[0]:-0}"; }' ; do
  sf_fixture "$SFD"
  printf '%s\n' "$_sf_clean" >> "$SFD/scripts/check-lib.sh"
  sf_lint "$SFD" ADB_BASH_FLOOR=0.0
  eq "$SFRC" "0" "rule C: ordinary shell does not trip it — $_sf_clean"
done

# ...nor a whole-line comment naming the construct, which all three files legitimately do (the real
# tree carries many, this file included). Without this exclusion the rule is noise on its own
# documentation. No count is quoted here on purpose: it changes whenever anyone edits a comment or
# widens a pattern, and review caught the first spelling of this line already stale.
sf_fixture "$SFD"
printf '# never write declare -A or mapfile or local -n or readlink -f in this file\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "rule C: a whole-line comment explaining the rule does not trip it"

# RULE C READS LOGICAL LINES TOO, and the splice makes it STRICTLY stronger: a continuation that
# splits the construct — or even splits a WORD — is rejoined and then caught.
sf_fixture "$SFD"
printf 'adb_probe_fn() { declare \\\n  -A adb_m; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: a construct split by a LINE CONTINUATION is caught"

sf_fixture "$SFD"
printf 'adb_probe_fn() { map\\\nfile -t adb_x < /dev/null; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: a construct whose WORD is split by a continuation is caught"

# ...and neither scan may swallow the line after a COMMENT that happens to end in a backslash. A
# trailing backslash does NOT continue a comment in shell, so the following line is real code — a
# joiner running before the comment rule would consume it and blind both scans to whatever it holds.
sf_fixture "$SFD"
printf '# a comment ending in a backslash \\\nadb_probe_fn() { declare -A adb_m; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: a WHOLE-LINE comment ending in a backslash does not swallow the next line"

# ...and neither does a TRAILING one, which is the harder half and the one review reproduced. Only
# whole-line comments are skipped before the splice, so `code # note \` spliced the following line
# onto a statement that had already ended — and a marker on that next line then sanctioned the
# construct on this one. A line whose last token is a comment never continues, in shell or here.
sf_fixture "$SFD"
printf 'adb_probe_fn() { declare -A adb_m; } # note \\\n:   # adb-allow: sub-floor-associative-array\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: a backslash ending a TRAILING comment does not splice the next line"
has "$SFOUT" "uses associative-array" "rule C: and the construct above the comment is the one reported"

# ...INCLUDING with no whitespace before the `#`, which is the same hole one character narrower.
# bash starts a comment right after a control operator too, so `};# note \` is two independent
# lines — and a probe keyed on `[[:space:]]#` spliced them and let the second line's marker exempt
# the declaration on the first, ending in a green run. Review reproduced it.
sf_fixture "$SFD"
printf 'adb_probe_fn() { declare -A adb_m; };# note \\\n:   # adb-allow: sub-floor-associative-array\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: a comment opened by ';#' also ends the line for splicing purposes"
has "$SFOUT" "uses associative-array" "rule C: and the construct before it is still reported"

# ...nor may the splice make ordinary continued shell trip either scan.
sf_fixture "$SFD"
printf 'adb_probe_fn() { printf "%%s" \\\n  "hello"; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "splice: an ordinary continued command trips neither source scan"

# AN ODD RUN OF TRAILING BACKSLASHES CONTINUES; AN EVEN RUN DOES NOT — the second is an ESCAPED
# backslash and the statement ends there, which a real bash confirms by running the next line as its
# own command. A naive `~ /\\$/` splices both and merges two INDEPENDENT statements, and the
# consequence is not cosmetic: a marker on the second then sanctions a construct on the first.
#
# NO TRAILING COMMENT ON THE FIRST LINE, and that is what makes this fixture about the RULE IT
# NAMES. An earlier spelling put the backslashes inside a `# x\\` comment, and once the splice
# learned that a commented line never continues, THAT guard rejected the fixture and the odd/even
# rule stopped being exercised at all — the fixture still passed, for a reason unrelated to its own
# label. Re-running the mutation battery after the change is what surfaced it: neutralizing the
# backslash COUNT produced zero failures. The line below ends in a bare escaped backslash, so the
# counting rule is the only thing that can decide it.
sf_fixture "$SFD"
printf "adb_probe_fn() { declare -A adb_m; printf '%%s' x\\\\\\\\\n:   # adb-allow: sub-floor-associative-array\n" >> "$SFD/scripts/check-lib.sh"
sf_applied "$SFD/scripts/check-lib.sh" "printf '%s' x\\\\" "even-backslash"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "splice: an EVEN backslash run does not join, so a marker cannot reach back a statement"
has "$SFOUT" "uses associative-array" "splice: and the construct on the first statement is the one reported"

# --- rule C's exemption marker: it must EXEMPT, and it must not OVER-exempt ------------------------
# The marker is the mechanism #315 requires to be "itself observed failing". A marker that exempted
# nothing would make the tracked tree red; one that exempted everything would make the rule inert.
# Both directions are driven here.

# 1. It exempts its own class.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a < /dev/null; }   # adb-allow: sub-floor-mapfile\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "marker: a sanctioned line for THIS class is exempt"

# ...and on a CONTINUED statement it rides the LAST physical line, which is the only place it can
# legally sit — a trailing `#` comment on an earlier half is a syntax error. The splice is what
# makes that work: the marker and the construct end up on one logical line.
sf_fixture "$SFD"
printf 'adb_probe_fn() { declare \\\n  -A adb_m; }   # adb-allow: sub-floor-associative-array\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "marker: on a CONTINUED statement it sanctions from the last physical line"

# 2. A marker for a DIFFERENT class does not exempt. This is the whole reason the marker names a
#    class instead of being a bare `adb-allow: sub-floor` — a per-line escape that covers every
#    construct on the line is a per-line escape that stops being reviewable.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a < /dev/null; }   # adb-allow: sub-floor-nameref\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: a marker naming a DIFFERENT class does not exempt"

# 3. A sanctioned line does not launder a SECOND construct added to it later — the accretion failure
#    a per-line escape is most likely to suffer.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a; declare -A adb_m; }   # adb-allow: sub-floor-mapfile\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: it exempts ONE class, not the whole line"
has "$SFOUT" "uses associative-array" "marker: and the unsanctioned class is the one reported"

# 4. A MALFORMED or STALE marker does not exempt. `adb-allow:` with no class, a typo'd class, and
#    the bare rule name are each one keystroke from the real thing and must all stay red.
for _sf_bad in 'adb-allow: sub-floor' 'adb-allow: sub-floor-mapfil' 'adb-allow: mapfile' 'adballow: sub-floor-mapfile'; do
  sf_fixture "$SFD"
  printf 'adb_probe_fn() { mapfile -t adb_a < /dev/null; }   # %s\n' "$_sf_bad" >> "$SFD/scripts/check-lib.sh"
  sf_lint "$SFD" ADB_BASH_FLOOR=0.0
  eq "$SFRC" "1" "marker: a malformed marker [$_sf_bad] does not exempt"
done

# 5. AN ADJACENT MARKER DOES NOT REACH. Per LINE, never per region — the constraint inherited from
#    check-fact-drift.sh's `req_absent` ban, where per-FILE exclusion made the invariant false.
sf_fixture "$SFD"
printf '# adb-allow: sub-floor-mapfile\nadb_probe_fn() { mapfile -t adb_a < /dev/null; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: a marker on the PRECEDING line does not exempt the next one"

# 7. STRING DATA CANNOT LAUNDER A CONSTRUCT. The marker must be in TRAILING-COMMENT position — a
#    `#`, then the marker, then end of line. The first cut tested for the marker as a bare
#    SUBSTRING, and review walked a real construct straight through it with a single-quoted copy of
#    the marker text: ordinary data sanctioning executable code, and silently incrementing the
#    exemption count on the way past.
sf_fixture "$SFD"
printf "adb_probe_fn() { mapfile -t adb_a; : 'adb-allow: sub-floor-mapfile'; }\n" >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: a QUOTED copy of the marker text does not sanction anything"

# ...and the same anchoring means a marker followed by more code on the line does not sanction it.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a; }   # adb-allow: sub-floor-mapfile then more text\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: it must END the line, so trailing text after it does not sanction"

# 8. THE `#` MUST ACTUALLY BEGIN A COMMENT. Anchoring to end-of-line was not sufficient on its own:
#    `#` opens a comment only at the start of a WORD, so `: x# adb-allow: sub-floor-mapfile` contains
#    no comment at all — `x#` is an ordinary word — yet it sanctioned a real `mapfile` on the same
#    line. Review reproduced it; this is the fixture that keeps the word-start rule.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a; : x# adb-allow: sub-floor-mapfile\n}\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: a '#' that does not begin a comment does not sanction"

# ...and the legitimate no-whitespace form still DOES, since `;#` really is a comment start.
sf_fixture "$SFD"
printf 'adb_probe_fn() { mapfile -t adb_a; };# adb-allow: sub-floor-mapfile\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "marker: a comment opened by ';#' does sanction — the rule is word-start, not whitespace"

# 6. THE REAL SANCTIONED LINE IS LOAD-BEARING. Removing its marker from a COPY must go red — which
#    is what proves rule C actually SEES that line, rather than passing because it matches nothing.
#    A rule silently matching nothing is indistinguishable from a rule finding nothing wrong.
#    THROUGH check_mutate_line, the shared primitive — not a hand-rolled sed plus a bespoke grep.
#    It already does both halves this needs (require the target line to be present EXACTLY once, and
#    prove the substitution took effect), and a byte-copied harness beside it is precisely the drift
#    `docs/design-principles.md` forbids. Review caught the duplication.
sf_fixture "$SFD"
_sf_marked_line="$(grep -n 'cd|read|mapfile|readarray|dd' "$SFD/scripts/check-bash-floor.sh" | head -n 1 | cut -d: -f2-)"
check_mutate_line "$SFD/scripts/check-bash-floor.sh" "$_sf_marked_line" \
  's/   # adb-allow: sub-floor-mapfile$//' "marker de-marking" && ok
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "marker: stripping the REAL sanctioned line's marker goes red — rule C does see it"
has "$SFOUT" "uses mapfile" "marker: and it is rule C's own diagnostic that fires"

# --- rule C cannot go silently inert --------------------------------------------------------------
# Its failure mode is silence in the most literal way available: an emptied table scans nothing and
# prints exactly what four clean rows print.
#
# THIS ONE MUTATES THE LINT, NOT THE SUBJECT, and that distinction is the whole reason it needs its
# own runner. Every fixture above edits the tree that `--sub-floor` SCANS while the TRACKED lint
# does the scanning; here the defect being injected is in the scanner itself. Editing
# `$SFD/scripts/check-bash-floor.sh` and calling `sf_lint` would change the file under test and
# leave the real rule table untouched — the assertion would then be about a scanned copy that lost
# a line, which is a different (and already covered) fact. The first cut of this fixture did
# exactly that and passed for the wrong reason.
#
# The mutated lint has to run from a tree that carries its siblings, because it `cd`s to
# `$(dirname "$0")/..` and sources `scripts/check-lib.sh` — which is precisely what sf_fixture
# builds, so the mutated copy runs out of a second fixture and scans the first.
sf_lint_from() {   # sf_lint_from <lint-path> <dir> [env…] — run a MUTATED lint copy over a fixture
  _sfl="$1"; _sfd="$2"; shift 2
  SFOUT="$(env "$@" bash "$_sfl" --sub-floor "$_sfd" 2>&1)"
  SFRC=$?
}
SFMUT="$work/subfloor-mut"

# First prove the runner itself is not simply red-always: an UNMUTATED copy must still pass.
sf_fixture "$SFD"
sf_fixture "$SFMUT"
sf_lint_from "$SFMUT/scripts/check-bash-floor.sh" "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "rule C: an unmutated lint COPY passes, so the runner is not red-always"

sf_fixture "$SFMUT"
sed '/^mapfile (/d; /^associative-array (/d; /^nameref (/d; /^readlink-f (/d' \
  "$SFMUT/scripts/check-bash-floor.sh" > "$SFMUT/x" && mv "$SFMUT/x" "$SFMUT/scripts/check-bash-floor.sh"
if grep -q '^mapfile (' "$SFMUT/scripts/check-bash-floor.sh"; then
  bad "rule C: the table-emptying mutation did not apply to the lint copy"; else ok; fi
sf_lint_from "$SFMUT/scripts/check-bash-floor.sh" "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: an EMPTY construct table is a failure, not a clean sweep"
has "$SFOUT" "CONSTRUCT set is EMPTY" "rule C: and it says outright that it evaluated nothing"

# ...and the same runner proves rule C's `check_fail` is LOAD-BEARING. A scan that finds a construct,
# prints the diagnostic, and forgets to record the failure exits 0 — diagnostics on stderr and a
# green status, which is the silent-guard shape this whole file exists to refuse. The proof is that
# the identical input the real lint FAILS is PASSED once that one call is removed.
sf_fixture "$SFD"
printf 'adb_probe_fn() { declare -A adb_m; }\n' >> "$SFD/scripts/check-lib.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "rule C: (control) the real lint fails this input"

sf_fixture "$SFMUT"
# Targeted at rule C's arm alone: `$sf_chits` is unique to it, so the `check_fail` neutralized is
# the one on the following line and no other rule's is touched.
awk '{
  if (seen && $0 ~ /check_fail/) { sub(/check_fail/, ":"); seen = 0 }
  if ($0 ~ /sf_chits.*>&2/) seen = 1
  print
}' "$SFMUT/scripts/check-bash-floor.sh" > "$SFMUT/x" && mv "$SFMUT/x" "$SFMUT/scripts/check-bash-floor.sh"
if [ "$(grep -c 'sf_chits' "$SFMUT/scripts/check-bash-floor.sh")" -ge 1 ]; then ok; else
  bad "rule C: the check_fail mutation lost the arm it was aimed at"; fi
sf_lint_from "$SFMUT/scripts/check-bash-floor.sh" "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "rule C: dropping its check_fail passes that same input — the call is load-bearing"
has "$SFOUT" "uses associative-array" "rule C: and it still PRINTED the finding while exiting 0"

# ...and the count it reports is the count it USED, on every branch, so a shrunken table is visible
# in an ordinary log rather than only when it hits zero.
sf_fixture "$SFD"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
has "$SFOUT" "rule C evaluated 4 construct rule(s) over 3 file(s)" "rule C: it says how many rules over how many files"

# THE EXEMPTION COUNT MEANS EXEMPTIONS SPENT, not mentions of the marker string. Counting mentions
# is the obvious `grep -c` spelling and it is wrong: the tracked observer mentions the marker in its
# own definition and in several comments. The first cut reported THREE for a tree with two exempted
# lines, which reads like coverage and is not.
has "$SFOUT" "honouring 2 sanctioned marker(s)" "rule C: the exemption count is lines EXEMPTED, not mentions"

# --- the fake-candidate seam ----------------------------------------------------------------------
# Rule B needs a subject BELOW the floor, and a Linux runner has none — so most of what follows
# would be macOS-only without a seam. `ADB_SUB_FLOOR_CANDIDATES` supplies the enumeration and
# `ADB_BASH_FLOOR` raises the floor above the stubs' reported versions, which together give both
# platforms the same assertions. The genuinely-3.2 cases are still run for real, further down.
#
# The stub DELEGATES everything except the version probe to a real bash, so `-n` and the bootstrap
# probe behave exactly as they would in production. A stub that faked those too would let this
# suite pass against a mode that never ran either.
SELF_BASH="$(command -v bash 2>/dev/null || echo /bin/bash)"
mkdir -p "$work/sfbin"

# sf_stub <path> <reported-version> [delegate] — an interpreter that answers the VERSION PROBE with
# <reported-version> and hands every other invocation to a real bash (or to <delegate>, for the
# cannot-execute case). The probe is recognized by the `BASH_VERSINFO` in the program text, which is
# how adb_bash_version_at asks.
sf_stub() {
  { printf '#!/bin/sh\n'
    printf 'case "$1" in\n'
    printf '  -c)\n'
    printf '    case "$2" in\n'
    printf '      *BASH_VERSINFO*) printf %%s "%s"; exit 0 ;;\n' "$2"
    printf '    esac ;;\n'
    printf 'esac\n'
    printf 'exec "%s" "$@"\n' "${3:-$SELF_BASH}"
  } > "$1"
  chmod +x "$1"
}

# OLDEST, and the versions are chosen so the three plausible implementations DISAGREE: first-listed
# is `newer`, lexically smallest is `10.0.0` (because "1" < "9" as text), and numerically oldest is
# `9.9.9`. A fixture where they coincide proves nothing about which one shipped.
sf_stub "$work/sfbin/newer" "10.0.0"
sf_stub "$work/sfbin/older" "9.9.9"
SF_CANDS="$work/sfbin/newer
$work/sfbin/older"

sf_fixture "$SFD"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
eq "$SFRC" "0" "selection: a stubbed candidate set still passes on a clean fixture"
# THE "IT ALL RAN" SUMMARY, forced through the seam so this shape is pinned on EVERY runner and not
# only on a host that happens to carry an old bash.
has "$SFOUT" "3 file(s) named" "summary: the ran branch names the file count"
has "$SFOUT" "3 parsed and 3 evaluated" "summary: and reports both counts separately"
has "$SFOUT" "$work/sfbin/older (9.9.9)" "selection: the NUMERICALLY oldest candidate is chosen"
hasnt "$SFOUT" "$work/sfbin/newer (10.0.0)" "selection: not the first-listed, and not the lexically smallest"

# An unusable candidate is skipped rather than chosen or fatal: this list is a superset of what any
# one host carries, so a path that is absent is ordinary. Listed FIRST, where a naive
# implementation would take it.
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin/does-not-exist
$SF_CANDS"
eq "$SFRC" "0" "selection: an unusable candidate is skipped, not chosen"
has "$SFOUT" "$work/sfbin/older (9.9.9)" "selection: and the oldest usable one is still picked"

# Duplicates are ordinary — `command -v bash` routinely repeats a fixed prefix already listed above
# it — and must not change the answer.
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS
$work/sfbin/older"
eq "$SFRC" "0" "selection: a duplicated candidate does not change the verdict"

# A CANDIDATE REPORTING A NON-NUMERIC VERSION IS NOT USABLE. This is the ADB_BASH_FLOOR bypass in a
# second costume, and review reproduced it: `adb_version_ge` reads a non-numeric component as 0, so
# a candidate reporting `x` compares as 0.0.0, is judged BELOW the floor, and is chosen — while it
# may in fact hand every real operation to a 5.3. The mode then announces it tested under `(x)` and
# passes without any old bash being involved. Listed alongside a usable stub so the assertion is
# about the REJECTION and not about the list being empty.
sf_stub "$work/sfbin/junkver" "x"
sf_fixture "$SFD"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin/junkver
$SF_CANDS"
eq "$SFRC" "0" "selection: a candidate reporting a non-numeric version does not break the run"
has "$SFOUT" "non-numeric version" "selection: and the refusal says why"
hasnt "$SFOUT" "$work/sfbin/junkver (x)" "selection: and that candidate is never chosen as the subject"
has "$SFOUT" "$work/sfbin/older (9.9.9)" "selection: the oldest VALID candidate is used instead"

# ...and with NOTHING else to fall back to, it must be a stated SKIP rather than a green run that
# claims a subject it could not validate.
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin/junkver"
eq "$SFRC" "0" "selection: a junk-version candidate alone leaves no subject"
has "$SFOUT" "SKIPPED" "selection: and that is reported as a SKIP, not as a parse that happened"

# A candidate that PROBES a version but cannot be executed FAILS CLOSED. Silently degrading to a
# skip here would turn a broken subject into a green run, which is the one outcome a floor guard
# may never produce.
sf_stub "$work/sfbin/broken" "9.0.0" "/nonexistent/interpreter"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin/broken"
eq "$SFRC" "1" "selection: a candidate that probes but cannot RUN fails closed"
has "$SFOUT" "cannot be executed" "selection: and says so rather than blaming the file under test"
# ...and the SUMMARY must name the right problem. Suppressing rule B by clearing the chosen
# interpreter is the obvious implementation, and it makes this run announce "no interpreter below
# the floor exists on this host" about a host that has one and cannot execute it. The verdict would
# still be FAIL, so only this assertion separates a correct explanation from a misleading one.
hasnt "$SFOUT" "no interpreter below the" \
  "selection: a BROKEN interpreter is not reported as an ABSENT one"

# --- rule B: the parse, portable through the seam --------------------------------------------------
# ONE FIXTURE PER FILE, for the reason rule A's loop states: review mutated the implementation to
# skip parsing check-lib.sh and the entire suite stayed green, because the only parse fixture was
# common.sh. A rule declared over three files is only established by three.
for _sf_target in scripts/lib/common.sh scripts/check-lib.sh scripts/check-bash-floor.sh; do
  sf_fixture "$SFD"
  printf 'if then fi\n' >> "$SFD/$_sf_target"
  sf_applied "$SFD/$_sf_target" 'if then fi' "syntax-error"
  sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
  eq "$SFRC" "1" "rule B: $_sf_target failing to PARSE is caught"
  has "$SFOUT" "does not PARSE" "rule B: and says so ($_sf_target)"
  has "$SFOUT" "$_sf_target" "rule B: naming the file that would not parse"
  has "$SFOUT" "$work/sfbin/older (9.9.9)" "rule B: and the interpreter and version it used"
done

# --- rule B: the evaluation probe, portable through the seam ---------------------------------------
# NOTHING ON STDOUT OR STDERR is half the assertion, and it is the half an exit-status test cannot
# make: a file can load with status 0 while printing a diagnostic, which is exactly what an
# unsupported builtin option does on 3.2.
#
# ALL THREE FILES, because D35's property is about all three. Review found the probe wired to
# common.sh alone, so a top-level `declare -A` in check-lib.sh or in the observer passed. The
# observer is reached through its usage arm rather than by sourcing it — sourcing an executable
# lint would run a lint inside the lint — so the injection has to land BEFORE its `case` dispatch
# to be reachable at all, which is what the `sed` below guarantees and `sf_applied` confirms.
for _sf_target in scripts/lib/common.sh scripts/check-lib.sh; do
  sf_fixture "$SFD"
  printf 'printf "adb-probe-noise\\n" >&2\n' >> "$SFD/$_sf_target"
  sf_applied "$SFD/$_sf_target" 'adb-probe-noise' "noisy-load"
  sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
  eq "$SFRC" "1" "probe: $_sf_target loading NOISILY is caught, even at status 0"
  has "$SFOUT" "adb-probe-noise" "probe: and the noise is quoted back as the diagnostic ($_sf_target)"
done

# THE OBSERVER, whose top level is reached through the usage arm. Injected after `check_init` so it
# runs before the `case` exits — appending to the end of the file lands after an `exit` and is
# unreachable on every interpreter, which would make this fixture pass for no reason at all.
sf_fixture "$SFD"
sed -i.bak 's/^check_init "bash-floor"$/check_init "bash-floor"\nprintf "adb-probe-noise\\n" >\&2/' \
  "$SFD/scripts/check-bash-floor.sh" && rm -f "$SFD/scripts/check-bash-floor.sh.bak"
sf_applied "$SFD/scripts/check-bash-floor.sh" 'adb-probe-noise' "observer top-level noise"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
eq "$SFRC" "1" "probe: the OBSERVER emitting at its top level is caught too"
has "$SFOUT" "scripts/check-bash-floor.sh does not evaluate its top level" "probe: and names the observer"

# ...and the other half, which only common.sh carries: the gate must actually be REACHABLE
# afterwards. A file that loads in silence but leaves adb_require_bash undefined is D30's failure in
# its purest form.
sf_fixture "$SFD"
printf 'unset -f adb_require_bash\n' >> "$SFD/scripts/lib/common.sh"
sf_applied "$SFD/scripts/lib/common.sh" 'unset -f adb_require_bash' "gate-removal"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
eq "$SFRC" "1" "probe: a common.sh that loads but leaves adb_require_bash unreachable is caught"

# THE VERDICT CANNOT BE FORGED BY THE FILE UNDER TEST. The first cut carried it in a magic word on
# stdout with stderr folded in, and this exact fixture passed with the gate absent. Reachability
# rides the exit status and silence rides output-emptiness, so the marker has nothing to collide
# with — but only this assertion keeps it that way.
sf_fixture "$SFD"
printf 'unset -f adb_require_bash\nprintf ADB_BOOTSTRAP_REACHABLE\n' >> "$SFD/scripts/lib/common.sh"
sf_applied "$SFD/scripts/lib/common.sh" 'printf ADB_BOOTSTRAP_REACHABLE' "forged marker"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
eq "$SFRC" "1" "probe: the file under test cannot FORGE the reachability verdict"

# ONE DEFECT, ONE LINE: a file that fails to PARSE must not also be reported as failing to load —
# it is the same finding wearing a second hat.
sf_fixture "$SFD"
printf 'if then fi\n' >> "$SFD/scripts/lib/common.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
hasnt "$SFOUT" "does not leave adb_require_bash reachable" "probe: an unparseable file is not ALSO reported as unloadable"
has "$SFOUT" "3 file(s) named; 2 parsed" "probe: and the counts say outright that one file was not parsed"

# --- the three findings the async reviewer raised on PR #316 ---------------------------------------
# Each was reproduced before being fixed, and each gets the fixture that keeps it fixed.

# (i) THE USAGE LINE IS STRIPPED ONLY WHEN IT IS THE WHOLE OUTPUT. The observer's probe runs its
#     usage arm, which prints one line and exits 2 — so that line has to be discarded. A prefix
#     wildcard discards the ENTIRE capture the moment it matches, which means anything printed
#     AFTER it (an EXIT trap, a shutdown warning) vanishes and the evaluation is counted clean.
sf_fixture "$SFD"
sed -i.bak 's/^check_init "bash-floor"$/check_init "bash-floor"\ntrap '"'"'printf "adb-exit-trap-noise\\n" >\&2'"'"' EXIT/' \
  "$SFD/scripts/check-bash-floor.sh" && rm -f "$SFD/scripts/check-bash-floor.sh.bak"
sf_applied "$SFD/scripts/check-bash-floor.sh" 'adb-exit-trap-noise' "EXIT-trap noise after the usage line"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$SF_CANDS"
eq "$SFRC" "1" "usage strip: output appended AFTER the usage line is not swallowed"
has "$SFOUT" "adb-exit-trap-noise" "usage strip: and the appended output is quoted back"

# (ii) `/` IS A SCAN TARGET, not a trailing slash. Stripping it empties the value, the emptiness
#      guard rewrites it to `.`, and since the script has already cd'd to the repo root the run
#      reports a clean scan OF THE CHECKOUT while the caller believes it scanned `/`.
sf_lint "/"
eq "$SFRC" "1" "root target: --sub-floor / scans / rather than aliasing to the repo root"
has "$SFOUT" "not a file under /" "root target: and it says which scope it actually looked in"

# (iii) AN UNENCODABLE CANDIDATE IS A FAILURE WHEN IT IS THE ONLY ONE. Skipping it alone is a
#       fail-open: the run reports "no interpreter below the floor exists", SKIPs both rules and
#       exits 0, while a usable subject was sitting right there — and the candidate list printed
#       directly beneath contradicts the message by showing its below-floor version.
mkdir -p "$work/sfbin-pipe|d"
sf_stub "$work/sfbin-pipe|d/bash" "9.9.9"
sf_fixture "$SFD"
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin-pipe|d/bash"
eq "$SFRC" "1" "unencodable: the ONLY sub-floor candidate being unencodable fails, never SKIPs"
has "$SFOUT" "cannot encode" "unencodable: and the diagnostic says why"
hasnt "$SFOUT" "SKIPPED" "unencodable: it must not read as an ordinary skip — a subject DOES exist"

# ...but a refusal alongside a usable candidate is only a note: the check still ran.
sf_lint "$SFD" ADB_BASH_FLOOR=99.0 ADB_SUB_FLOOR_CANDIDATES="$work/sfbin-pipe|d/bash
$SF_CANDS"
eq "$SFRC" "0" "unencodable: a refusal beside a usable candidate does not fail the run"
has "$SFOUT" "$work/sfbin/older (9.9.9)" "unencodable: the usable candidate is still selected"

# --- the stale-set rule ----------------------------------------------------------------------------
# The list IS the carve-out. A named file that is not there means the lint is silently checking
# fewer files than it claims, which is the shape every other rule in this file exists to refuse.
sf_fixture "$SFD"
rm -f "$SFD/scripts/check-lib.sh"
sf_lint "$SFD"
eq "$SFRC" "1" "stale set: a named carve-out file that is missing is a failure, not a skip"
has "$SFOUT" "is stale" "stale set: and the diagnostic points at the list rather than the tree"

# --- the SKIP path ---------------------------------------------------------------------------------
# A floor of 0.0 puts every interpreter on the host at or above it, so rule B has no subject. The
# honest outcome is a stated skip that still returns 0 — and, crucially, one that does NOT claim to
# have parsed anything. A silent pass here is the exact defect #310 filed.
sf_fixture "$SFD"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "0" "skip: no sub-floor interpreter is a stated SKIP, not a failure"
has "$SFOUT" "SKIPPED" "skip: and it says SKIPPED out loud"
# ...and the SKIP branch opens with the SAME file-count phrasing as the ran branch. One fact, one
# spelling — the alternative made a guard assertion silently platform-dependent.
has "$SFOUT" "3 file(s) named" "skip: the skip branch names the file count identically"
has "$SFOUT" "the source scans (rules A and C) ran on all of them" "skip: and says outright which rules still ran"
has "$SFOUT" "rule C evaluated 4 construct rule(s)" "skip: rule C is named with its own count on the SKIP branch too"
has "$SFOUT" "Candidates probed" "skip: naming every candidate it looked at, so a skip is auditable"
hasnt "$SFOUT" "parses and bootstraps under" "skip: and it never claims a parse it did not do"

# THE SKIP MUST NOT SUPPRESS RULE A. That rule is interpreter-independent, so a host with no old
# bash still gets it — otherwise every Linux runner would be checking nothing at all.
sf_fixture "$SFD"
printf 'ADB_PROBE=${ printf hi; }\n' >> "$SFD/scripts/lib/common.sh"
sf_lint "$SFD" ADB_BASH_FLOOR=0.0
eq "$SFRC" "1" "skip: rule A still runs when rule B has no subject"

# --- the genuinely-3.2 cases -----------------------------------------------------------------------
# Everything above proves the RULES fire. These prove they fire on the REAL hazard, under the real
# interpreter D30 was written for. Guarded on /bin/bash actually being 3.2, so a Linux runner skips
# rather than asserting something false — the same shape as the isolating $BASH case further up.
if [ -x /bin/bash ] && [ "$sysv" = "3.2" ]; then
  # bash-4 GRAMMAR inside a function body: 5.3 parses it, 3.2 does not, and rule A cannot see it.
  # This is the case that makes the parse rule worth having.
  sf_fixture "$SFD"
  printf 'adb_probe_fn() { case x in a) : ;& b) : ;; esac; }\n' >> "$SFD/scripts/lib/common.sh"
  sf_lint "$SFD"
  eq "$SFRC" "1" "real 3.2: post-3.2 grammar in a function body is caught by the parse rule"
  has "$SFOUT" "/bin/bash (3.2.57)" "real 3.2: and the real system interpreter is the one it used"

  # AN EXPANSION FAILURE THAT PARSES CLEANLY AND EXITS 0. `declare -A` at the top level prints
  # `invalid option` on 3.2 and leaves the source status at 0, so neither `bash -n` nor an rc test
  # sees it. Only the probe's stderr half does — which is why that half exists.
  sf_fixture "$SFD"
  printf 'declare -A ADB_PROBE_MAP\n' >> "$SFD/scripts/lib/common.sh"
  sf_lint "$SFD"
  eq "$SFRC" "1" "real 3.2: an associative-array declaration is caught by the probe's stderr half"
  has "$SFOUT" "invalid option" "real 3.2: and 3.2's own words are quoted back"
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
# An advisory classification IS the claim "this file may never exit non-zero", and the library it
# sources is the thing most able to break that: an unreadable or corrupt common.sh must not turn a
# lifecycle hook into a failing one. The original witness was retired out of the tree (#378), so
# the claim is asserted here on the advisory hook that remains and can still be driven end to end.
# Fixtures are copies; the live tree is never touched.
sc_src="agents/claude/scripts/session-currency.sh"
if [ -f "$sc_src" ]; then
  sc="$work/sc"; mkdir -p "$sc/scripts/lib"
  cp "$sc_src" "$sc/scripts/session-currency.sh"
  printf 'this is not valid shell ((((\n' > "$sc/scripts/lib/common.sh"
  # A `startup` payload, so the source gate does not return before the broken library has been
  # reached — without it this would assert nothing about the library at all.
  sc_ev='{"source":"startup","cwd":"/nonexistent-adb-probe"}'
  out="${ printf '%s' "$sc_ev" | "$BASH" "$sc/scripts/session-currency.sh" 2>/dev/null; }"; rc=$?
  eq "$rc" "0" "session-currency: a CORRUPT common.sh still exits 0 (a SessionStart hook may never fail)"
  # stdout on exit 0 is injected into Claude's CONTEXT, so leaked shell noise is not cosmetic.
  eq "$out" "" "session-currency: and emits nothing rather than leaking the library's own errors"

  # ...and the ordinary path is unaffected, or the assertion above is satisfied by a broken script.
  rm -rf "$sc/scripts/lib"; mkdir -p "$sc/scripts/lib"
  cp scripts/lib/common.sh "$sc/scripts/lib/common.sh"
  out="${ printf '%s' "$sc_ev" | "$BASH" "$sc/scripts/session-currency.sh" 2>/dev/null; }"; rc=$?
  eq "$rc" "0" "session-currency: a healthy library still exits 0"
  eq "$out" "" "session-currency: and stays silent when there is nothing to report"
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
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash "$@"\n' > "$d/agents/claude/scripts/session-currency.sh"
ep_lint "$d"
eq "$EPRC" "1" "entrypoints: a declared-ADVISORY file using the hard-failing form is rejected too"
has "$EPOUT" "classified ADVISORY" "entrypoints: the message names the classification it violated"

d="$work/ep-adv-ok"; ep_tree "$d"; mkdir -p "$d/agents/claude/scripts"
printf '#!/usr/bin/env bash\nset -u\nadb_require_bash_advisory "$@"\n' > "$d/agents/claude/scripts/session-currency.sh"
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
# agents/claude` saw `scripts/session-currency.sh` and called every advisory hook a hard gate — a
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

# A ROOT DIRECTORY WHOSE NAME ENDS IN A NEWLINE must scan CLEAN (#343, D82): a newline-delimited
# walk splits every path under it into unreadable fragments, which the scanner correctly refuses —
# and then reports as CRLF corruption, which is the wrong diagnosis and the wrong remedy.
d3="$work/crlf-nl/root
"; mkdir -p "$d3/scripts"
printf '#!/usr/bin/env bash\necho ok\n' > "$d3/scripts/fine.sh"
crlf_scan "$d3"
eq "$CLRC" "0" "crlf: a clean tree under a NEWLINE-named root scans clean (not misreported as CRLF)"
hasnt "$CLOUT" "unreadable" "crlf: and no path under it is reported unverified"
# ...and the scan must still be able to ANSWER there: a walk that reports every tree clean is the
# silence-as-success failure this file exists to prevent.
printf '#!/usr/bin/env bash\r\necho ok\r\n' > "$d3/scripts/fine.sh"
crlf_scan "$d3"
eq "$CLRC" "1" "crlf: a CRLF file under a NEWLINE-named root is still caught"
has "$CLOUT" "fine.sh" "crlf: and it is named"

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
