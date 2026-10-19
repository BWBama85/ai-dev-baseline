#!/usr/bin/env bash
# ai-dev-baseline — the selfcheck RUNNER is a guard, so it gets the treatment guards get here (#260).
#
# Since #260 `scripts/selfcheck.sh` no longer runs its steps as thirty inline `if …; then` blocks
# whose failure could not be lost. It runs them through a `wait -n` job pool, and a job pool has a
# failure mode that inline code does not: SILENCE. A dispatcher that drops a worker's exit status,
# or reaps a job and attributes it to the wrong name, or emits a step's banner without ever running
# it, prints exactly what a clean run prints. Every existing check-*.sh would still pass. So the
# thing that must be observed going red is the RUNNER, on a step that fails.
#
# HOW: the real `scripts/selfcheck.sh` is copied into a throwaway fixture tree alongside stub
# `check-*.sh` scripts whose exit status, output volume and duration this suite controls, and the
# real dispatcher is driven over them with `--only`. The tracked tree is never mutated — the copy
# is (base/practices/self-review.md: negative-test against a copy, never the live tree) — and the
# fixture's stubs stand in for real checks, so this suite costs seconds rather than re-running the
# suite it is part of.
#
# WHY IT CANNOT SIMPLY RUN THE REAL SUITE: this check is itself a registered step, so a fixture
# that invoked the real registry would recurse. `--only` over stub steps is what bounds it.
#
# What is asserted:
#   1. a deliberately failing step under parallelism still fails the run, and is NAMED;
#   2. the failure is attributed to the step that actually failed, with its actual exit code;
#   3. collect-all, not fail-fast: a red step does not stop the others being run and reported;
#   4. per-step output is ATOMIC — no step's lines appear inside another's block;
#   5. the concurrency bound is honoured, and the pool is genuinely concurrent (a pool of 1 that
#      passes every other assertion would be this whole change doing nothing);
#   6. `--serial` runs in declaration order, one at a time;
#   7. the serial prologue runs alone and first, even when declared last;
#   8. a filter that selects nothing, or names an unknown step, is an ERROR and not a clean run;
#   9. large output survives intact;
#  10. cancellation terminates the workers instead of orphaning them — including a worker forked
#      but not yet recorded in `LIVE`, and each case observed failing against a runner whose
#      reaping is broken in the one way that case exists to catch;
#  11. a step past ADB_SELFCHECK_OVERRUN_SECS is named live and in the result block, keeps its own
#      verdict under the pool and --serial, and is carried by `--summarize` (#445);
#  12. `--stop` (#551) — the one supported stop — names and removes what a cancelled pool leaves
#      (a detached worker, a STOPPED process, a holder in the checkout, one started only after the
#      TERM), leaves alone what merely works in the checkout, still sweeps after the runner was
#      KILLed, answers 4, never "nothing left", when it cannot see the process table, and is not
#      undone by a second run in the same checkout.
#
# Usage: bash scripts/check-selfcheck.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
# See scripts/selfcheck.sh's own stanza for the full reasoning; the load is confirmed by PROBING
# FOR THE FUNCTION rather than by the source's exit status.
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
# shellcheck source=/dev/null
. "$ROOT/scripts/check-lib.sh"   # ok/bad/eq/has/hasnt/yes/no + check_summary + check_exit_guard

MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *) echo "usage: check-selfcheck.sh [--mutation]" >&2; exit 2 ;;
esac
[ "$#" -gt 1 ] && { echo "usage: check-selfcheck.sh [--mutation]" >&2; exit 2; }

# THE GATE'S ENVIRONMENT IS THIS SUITE'S TO SET, never inherited. The scheduled workflow runs the
# registry with ADB_MUTATION_RUN_ALL=1, and this suite is a registered step there — so the override
# reached the fixture cases that expect a SKIP and turned every row red for the wrong reason, on
# the very run that exists to catch a wrong input set (#441). Each case below sets exactly the
# variables it means to test.
unset ADB_MUTATION_RUN_ALL ADB_MUTATION_BASE
# The grace and the stop's bound (#551) are this suite's to set as well. The grace is short so a case
# whose workers ignore TERM costs seconds, and every cancellation deadline below — the mutation rows'
# 8s included — still exceeds it. The bound is generous because a stop that finds nothing returns
# the moment everything has ended, so only a slow runner pays for it — and on a loaded machine a
# runner's own exit can outlast a tight bound and read as a survivor. The cases that EXPECT
# survivors pass a short one (STOP_SHORT), since they wait it out every time.
# The inspection bound is 12s, which also sizes a cancelled runner's own recording at a fifth of it
# (2s a read: a `prep` of 3 x (2 + 1) + 3 = 12s), so the shortest bound a stop may use here is
# 12 + 2 + 5 = 19s.
export ADB_SELFCHECK_STOP_GRACE_SECS=2 ADB_SELFCHECK_STOP_SECS=20 ADB_SELFCHECK_STOP_INSPECT_SECS=12
STOP_SHORT=19

work="$(mktemp -d)" || { echo "check-selfcheck: cannot create a scratch dir" >&2; exit 1; }

# leak_sweep <ctl> — remove what a section-12 leak stub, or a canary, left: every
# `kind pid pgid lstart…` line of every `*.leaked` file, signalled only while that pid is still the
# SAME process — the same group AND the same `ps lstart` start. A pid and pgid alone are not an
# identity: these leaks lead their own groups, and a recycled pid that leads a new group matches
# both. A red run of section 12 — every mutation row that breaks the stop is one — would otherwise
# leave sleeping and STOPPED processes behind. CONT before KILL, so nothing holds a pending signal.
leak_sweep() {
  local ctl="$1" f p pg st now
  for f in "$ctl"/*.leaked; do
    [ -f "$f" ] || continue
    while read -r _ p pg st; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      case "$pg" in ''|*[!0-9]*) continue ;; esac
      [ -n "$st" ] || continue
      now="$(ps -o pgid=,lstart= -p "$p" 2>/dev/null)"
      [ "$(printf '%s' "$now" | awk '{ $1 = $1; print }')" = "$(printf '%s %s' "$pg" "$st" | awk '{ $1 = $1; print }')" ] || continue
      kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
    done < "$f"
  done
  return 0
}

# cancel_sweep — ask every fixture's stubs to leave, and wait briefly for them to. Runs from the
# EXIT trap BEFORE `$work` is removed, because removing it first is what makes the leak: the stubs
# shut down cooperatively through `$ctl/STOP`, and deleting the directory takes that away while
# they tick out the rest of their 180s backstop. A run interrupted anywhere — ^C, a harness
# timeout, an assertion aborting a case — otherwise leaves them behind.
cancel_sweep() {
  local c deadline
  for c in "$work"/*/ctl; do [ -d "$c" ] || continue; : > "$c/STOP" 2>/dev/null || :; leak_sweep "$c"; done
  deadline=$(( BASH_MONOSECONDS + 5 ))
  while [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do
    for c in "$work"/*/ctl; do
      [ -d "$c" ] || continue
      [ -n "$(enrolled_alive "$c" 2>/dev/null)" ] && { sleep 0.1; continue 2; }
    done
    break
  done
  return 0
}
check_exit_guard "check-selfcheck" "cancel_sweep; rm -rf \"$work\""

# ====================== --mutation: the CASES must be observed going red ========================
# WHY THIS IS A MODE AND NOT FOUR MORE ASSERTIONS. A cancellation assertion's failure mode is
# silence: a run that signalled nothing prints what a run with nothing to signal prints. Asserting
# that the PREDICATE flips is a weaker claim than it looks — it leaves the assertion itself
# untested, so deleting the `eq` at the end of a case would go unnoticed by the very rows that
# claim to cover it. So each row breaks the dispatcher's reaping in ONE way, runs the WHOLE suite
# against the broken copy, and requires it back at exit 1 carrying THAT CASE'S OWN assertion text.
#
# Every row is a single literal edit, which is what lets them ride the vendored shmutant (#519)
# rather than a harness of their own: it already encodes the discipline — the edit must APPLY, the
# child must exit EXACTLY 1, and the failure must be the row's own witness rather than an
# accidental one somewhere else in the suite.
#
# THE SHORTENED DEADLINE IS PAID FOR BY THE CONTROL. These runs lower `ADB_CANCEL_DEADLINE_SECS`,
# and a deadline too short to let a CORRECT dispatcher finish reaping would redden every row for
# the wrong reason. The control run below is an UNMUTATED copy at the SAME setting, required to
# pass — so "the deadline did it" and "the mutation did it" cannot be confused.
#
# WHAT IS NOT COVERED, stated rather than implied: the historical defect 10.2 was written for — a
# serial step run in the FOREGROUND, where a TERM aimed at the runner never reaches it — takes four
# coordinated edits to restore and is not expressible as one literal. `serial-unreapable` proves
# the serial case can go red on a defect that reaches it; it does not reproduce that shape.
if [ "$MODE" = mutation ]; then
  export ADB_CANCEL_DEADLINE_SECS=8

  # mut_prepare <dir> — a throwaway tree the nested suite can run in, built ONCE; shmutant clones
  # it for every row. `scripts` alone: that is this suite's whole mutation surface, and every row
  # pays for what the tree holds (check_copy_subtrees' header).
  mut_prepare() {
    check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1
  }

  # mut_run <root> — the nested suite, guarded by a parse check. A mutation that stops the
  # runner PARSING has changed whether it runs at all rather than how it reaps: its fixture stages
  # no workers, and the nested suite would still fail on the right witness, crediting the row for
  # a defect it never exercised. Returning 9 makes the pool report an ABORT, which is what it was.
  mut_run() {
    local d="$1"
    bash -n "$d/scripts/selfcheck.sh" 2>/dev/null \
      || { printf 'the mutated selfcheck.sh no longer PARSES\n'; return 9; }
    bash "$d/scripts/check-selfcheck.sh" 2>&1
  }

  # THE CONTROL, first. Every row below reads a FAILURE, and a copy that cannot pass at all would
  # satisfy all four while exercising nothing.
  mut_ctl="$work/control"
  if mut_prepare "$mut_ctl"; then
    mut_out="$(mut_run "$mut_ctl" 2>&1)"; mut_rc=$?
    yes "$mut_rc" "control: an UNMUTATED copy passes at the same deadline the rows use (else every row below is red for the wrong reason)"
    # BOTH HALVES, and neither alone (review finding). This was `*"83 passed"*|*" 0 failed"*` — an
    # alternation, so a nested suite reporting `0 passed, 0 failed` satisfied it while running
    # nothing, and the pass count was decorative: bumping it 83 -> 116 -> 119 changed no verdict.
    # A count is PARSED rather than pinned, because an exact number would have to be re-bumped by
    # every future PR that adds an assertion to this file, and a pin nobody can keep current is the
    # next stale figure. What must hold is that the control RAN assertions and none of them failed.
    mut_pass="$(printf '%s\n' "$mut_out" | sed -n 's/.*check-selfcheck: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*/\1 \2/p' | tail -1)"
    case "$mut_pass" in
      ''|'0 '*) bad "control: the unmutated copy reported no assertions at all (got '${mut_pass:-<no summary>}')" ;;
      *' 0')    ok ;;
      *)        bad "control: the unmutated copy reported failures (got '$mut_pass')" ;;
    esac
    # WHICH assertions, when it is red: a control that fails says nothing about the rows, and the
    # only evidence of why is in its own output, which would otherwise be discarded here.
    [ "$mut_rc" -eq 0 ] || printf '%s\n' "$mut_out" | grep '^FAIL: ' | sed 's/^FAIL: /  control said: /' | cut -c1-400
  else
    bad "control: could not build the unmutated copy"
  fi

  # shellcheck source=/dev/null
  . "$ROOT/scripts/shmutant.sh" || bad "selfcheck-guard: scripts/shmutant.sh could not be sourced"
  shmutant_target scripts/selfcheck.sh
  # One row per case. The first two share an edit deliberately: "cancellation signals nothing" is
  # one defect, and BOTH the pool case and the serial case are required to see it.
  #
  # `for p in ""` empties the TERM loop, which also leaves `had` at 0 and so skips the KILL loop —
  # one edit, nothing signalled at all. The KILL loop below it opens with the same words, so the
  # TERM loop carries a `# row-term-loop` marker: shmutant refuses a literal that starts at more than
  # one position, since its rewrite takes the first and that may not be the copy a row means.
  shmutant_mut "pool-unreapable" \
    'for p in "${!LIVE[@]}"; do   # row-term-loop' 'for p in ""; do   # row-term-loop' \
    'cancellation terminates the workers instead of orphaning them'
  shmutant_mut "serial-unreapable" \
    'for p in "${!LIVE[@]}"; do   # row-term-loop' 'for p in ""; do   # row-term-loop' \
    'cancelling --serial terminates the running step instead of leaving it behind'
  # TERM survives; only the escalation goes. Every polite stub dies on the first TERM, so this is
  # invisible to the other three cases and visible to the deaf one — which is why that case exists.
  shmutant_mut "no-kill-escalation" \
    '_adb_bounded_signal KILL "$p"' ':' \
    'the TERM -> grace -> KILL escalation stops a worker that ignores TERM'
  # The fix itself, removed: `_cleanup` is back to reaping only what `LIVE` happens to hold.
  shmutant_mut "live-only-reaping" \
    'LIVE["$j"]=1' ':' \
    'a worker forked but not yet recorded in LIVE is still reaped'
  # The two LANE pins (#423). Both are single literal edits, so they ride the same harness. A lane
  # is policy rather than mechanism, which is exactly why it needs a standing proof: emptying the
  # array changes no behaviour any other assertion watches — every step still runs, and every step
  # still passes — so without these rows the pins would be the kind of check that cannot answer
  # wrong.
  shmutant_mut "lane-emptied" \
    'ISOLATED_STEPS=(session-currency install-migration install-guard selfcheck-guard selfcheck-guard-mutation install-dry-run)' \
    'ISOLATED_STEPS=()' \
    'the load-sensitive lane is exactly the suites'
  # lane_reason stops recognising the isolated lane while lane_of still does, so the two fields
  # disagree — the one defect a single-array design could not have had, and the reason the guard
  # asks BOTH questions rather than trusting one.
  shmutant_mut "lane-reason-lost" \
    'for _p in "${ISOLATED_STEPS[@]}"; do [ "$1" = "$_p" ] && { printf '"'"'load-sensitive\n'"'"'; return 0; }; done' \
    ':' \
    "--list's lane and its reason never disagree about any step"

  # The overrun warning (#445). Each of its halves is a report, and a report's failure mode is the
  # silent one: a ticker that never prints, a result block that drops the names and a digest that
  # forgets them all leave every step green. Two of 8e's assertions are not rows: a ticker left
  # running would make every nested run wait out a full tick, and a ticker reaped as a step corrupts
  # the pool's running count. Their observation is in D122.
  shmutant_mut "overrun-silent" \
    'printf '"'"'selfcheck: still running past %ss: %s (%ss so far)\n'"'"' "$OVERRUN" "$name" "$el"' ':' \
    'a step past the ceiling is named LIVE'
  shmutant_mut "overrun-unreported" \
    '[ "${#OVERRAN[@]}" -gt 0 ] && printf '"'"'overran (past %ss): %s\n'"'"' "$OVERRUN" "${OVERRAN[*]}"' ':' \
    'the result block names a step that overran and passed'
  shmutant_mut "overrun-by-reap-time" \
    '  if s="$(stamp_of started "$1")" && e="$(stamp_of ended "$1")"; then el=$(( e - s )); fi' ':' \
    'a step that ENDED inside the ceiling is not named'
  shmutant_mut "digest-drops-overran" \
    '    summarize_overran "$log"' ':' \
    'a green digest still names a step that overran'

  # The grace (#551): the KILL no longer waits for the workers' own cleanup.
  shmutant_mut "grace-not-awaited" \
    '    while _workers_remain && [ "$BASH_MONOSECONDS" -lt "$_gdl" ]; do sleep 0.1; done   # row-grace-wait' \
    '    :   # row-grace-wait' \
    "a worker's own TERM cleanup finishes inside the grace"
  # The record (#551).
  shmutant_mut "rec-done-ignored" \
    '    [ -n "${REC_DONE[$j]+x}" ] || _rec_group "$j"   # row-rec-done' \
    '    :   # row-rec-done' \
    'a worker cancelled between LIVE and its record is still recorded'
  shmutant_mut "record-clobbered" \
    '    if [ -n "$old" ] && [ "$old" != "$$" ] && ! adb_pid_gone "$old"; then' \
    '    if false; then' \
    "a second run in the checkout leaves the first run's record in place"
  shmutant_mut "record-into-dir" \
    '  if [ -L "$RUN_ROOT/$RUN_RECORD" ] || { [ -e "$RUN_ROOT/$RUN_RECORD" ] && [ ! -f "$RUN_ROOT/$RUN_RECORD" ]; }; then   # row-record-dir' \
    '  if false; then   # row-record-dir' \
    "a FIFO at the record's name is refused without being opened, and the run goes on (rc 124 = it hung)"
  shmutant_mut "old-record-unread-replaced" \
    '    if ! _stop_num "$old"; then   # row-old-record' '    if false; then   # row-old-record' \
    'an existing record that cannot be read is never replaced'
  shmutant_mut "stop-unknown-key-accepted" \
    '      *) STOP_WHY="line $n of $RUN_RECORD has a key no run record carries"; return 4 ;;' \
    '      *) ;;' \
    '12.5: a record that carries an unknown key is refused'
  # The stop (#551). Each ownership rule removed alone, so each survivor's own assertion is what
  # must see it; the temp-root rule widened to the checkout, the shape the owner declined.
  shmutant_mut "stop-root-blind" \
    '  if _stop_under "$c" "$_ENC"; then WHY="works in the run'"'"'s temp root"; return 0; fi   # row-own-tmp' \
    '  :   # row-own-tmp' \
    "after the runner is KILLed, the stop names a survivor working under the run's temp root"
  shmutant_mut "stop-owns-the-checkout" \
    '  _stop_enc "$REC_TMP"   # row-where-tmp' '  _stop_enc "$REC_ROOT"   # row-where-tmp' \
    'an unrelated process in the checkout is named and left alone'
  shmutant_mut "stop-pool-blind" \
    '  for d in "${REC_POOLS[@]}"; do   # row-own-pool' '  for d in; do   # row-own-pool' \
    'after the runner is KILLed, the stop names a detached worker in a registered pool'
  shmutant_mut "stop-closure-lost" \
    '    if [ -n "${OWN_GROUPS[$g]+x}" ]; then   # row-own-closure' \
    '    if false; then   # row-own-closure' \
    "after the runner is KILLed, the stop names a holder in its pool's group"
  shmutant_mut "stop-memory-lost" \
    '    elif [ -n "${OWN_EVER[$p]+x}" ] && _stop_same "$p" "${OWN_EVER[$p]}"; then   # row-own-sticky' \
    '    elif false; then   # row-own-sticky' \
    'after the runner is KILLed, the stop still names a holder whose pool process exited during the stop'
  shmutant_mut "stop-owns-late" \
    '  _stop_owned || { INV_ERR="$OWN_ERR"; _stop_blind; return 4; }   # row-own-first' '  :   # row-own-first' \
    'after the runner is KILLed, the stop sends the step it recorded a TERM, and its cleanup runs'
  shmutant_mut "stop-descent-lost" \
    '          if [ -n "${OWNED[$q]+x}" ]; then   # row-own-descent' '          if false; then   # row-own-descent' \
    "after the runner is KILLed, the stop names a nested worker its step's death reparents"
  shmutant_mut "cancel-records-no-descendants" \
    '  for g in "${!first[@]}"; do   # row-rec-descendants' '  for g in; do   # row-rec-descendants' \
    'a nested group the run recorded as it was cancelled is still found by a later stop'
  shmutant_mut "caller-group-spreads" \
    '  [ -z "${STOP_SHIELD_PGID[$1]+x}" ] && [ "$1" != "${REC_PGID:-}" ] && [ "$1" != "${STOP_RUNNER_PGID:-}" ]' \
    '  [ -z "${STOP_SHIELD_PGID[$1]+x}" ]' \
    "the runner's caller, and anything else in its group, is never treated as the run's"
  shmutant_mut "stop-recorded-ignored" \
    '    elif [ -n "${REC_GROUPS[$g]+x}" ] && _stop_rec_member "$p" "$g"; then   # row-own-recorded' \
    '    elif false; then   # row-own-recorded' \
    'after the runner is KILLed, the stop still stops the step it recorded'
  # Removal, the verdict, the fresh inventory, the bound on the run's grace and on each inspection.
  shmutant_mut "stop-removes-nothing" \
    '      kill -"$sig" -- "-$g" 2>/dev/null   # row-stop-group' '      :   # row-stop-group' \
    'the stop leaves none of them'
  shmutant_mut "stop-green-over-survivors" \
    '  return 1   # row-stop-red' '  return 0   # row-stop-red' \
    'the stop ends red when survivors outlived its bound'
  shmutant_mut "stop-stale-inventory" \
    '    _stop_inventory || { _stop_blind; return 4; }   # row-stop-fresh' \
    '    :   # row-stop-fresh' \
    "a process started after the stop's TERM is named and removed"
  shmutant_mut "stop-ignores-run-grace" \
    '  if [ "$bound" -lt $(( REC_PREP + REC_GRACE + STOP_MARGIN_SECS )) ]; then   # row-run-grace' '  if false; then   # row-run-grace' \
    "a stop never KILLs into a cleanup still inside the run's own grace"
  shmutant_mut "stop-keeps-no-incomplete" \
    '  if [ "$incomplete" -eq 1 ]; then   # row-incomplete-kept' '  if false; then   # row-incomplete-kept' \
    'an incomplete record survives a stop that found and removed survivors'
  shmutant_mut "path-ambiguity-accepted" \
    '  case "$1" in *[[:cntrl:]]*|*'"'"'^'"'"'*) return 1 ;; esac   # row-path-ok' '  :   # row-path-ok' \
    '12.5: a record that registers a pool whose name holds a ^ is refused'
  shmutant_mut "cancel-gaps-unmarked" \
    '  if ! _stop_inventory; then   # row-cancel-whole' '  if false; then   # row-cancel-whole' \
    'a cancelled run whose working-directory listing skips one of its processes marks its record incomplete' 
  shmutant_mut "stop-incomplete-ignored" \
    '    if [ "$incomplete" -eq 1 ]; then   # row-incomplete' '    if false; then   # row-incomplete' \
    'a stop over an incomplete record never answers clean'
  # Each way the inventory can be less than the whole table, folded into "the whole table".
  shmutant_mut "stop-ps-status-ignored" \
    '  if [ "$rc" -ne 0 ]; then   # row-ps-status' '  if false; then   # row-ps-status' \
    'a stop whose ps fails says so, even when ps printed a listing'
  shmutant_mut "stop-start-dated-early" \
    '  now="$EPOCHSECONDS"   # row-ps-now' '  now="$t0"   # row-ps-now' \
    'after the runner is KILLed, the stop sends the step it recorded a TERM, and its cleanup runs'
  shmutant_mut "stop-recheck-folded" \
    '    elif adb_pid_gone "$p"; then' '    else' \
    'a stop whose recheck of a missing directory cannot be read answers 4'
  shmutant_mut "stop-cwd-only-ignored" \
    '  for p in "${!cwd_before[@]}"; do   # row-both-ways' '  for p in; do   # row-both-ways' \
    'a stop whose ps omits a process the cwd listing shows answers 4'
  shmutant_mut "stop-stale-group-claims" \
    '  [ -n "$REC_MTIME" ] && [ "$st" -le $(( REC_MTIME + 60 + STOP_SKEW )) ] || return 1   # row-rec-upper' \
    '  :   # row-rec-upper' \
    'a recorded group whose leader is gone cannot claim a process started after the run was last heard from'
  shmutant_mut "unattributed-called-clean" \
    '    if [ "$UNATTRIBUTED" -gt 0 ]; then   # row-unattributed' '    if false; then   # row-unattributed' \
    'a stop that leaves an unattributed process from the run'"'"'s checkout is never clean (exit 6)'
  shmutant_mut "caller-unknown-spreads" \
    '  [ -n "${REC_PGID:-}${STOP_RUNNER_PGID:-}" ] || return 1   # row-closable-unknown' '  :   # row-closable-unknown' \
    'with no caller group known, no group spreads ownership to a bystander'
  shmutant_mut "signal-on-failed-verify" \
    '  [ "$vrc" -eq 0 ] || e=""   # row-signal-status' '  :   # row-signal-status' \
    'a target the stop could not re-verify is never signalled'
  shmutant_mut "signal-unverified" \
    '    [ -n "${INV_START[$pid]:-}" ] && _stop_same_at "$pid" $(( now - _ETS )) || continue   # row-signal-verify' \
    '    :   # row-signal-verify' \
    'a target whose identity no longer matches is never signalled'
  shmutant_mut "stop-ps-control-folded" \
    'return 1; }   # row-ps-control' 'return 0; }   # row-ps-control' \
    'a stop whose ps lists without it answers 4, never clean'
  shmutant_mut "stop-cwd-gaps-ignored" \
    '  for p in "${!INV_PGID[@]}"; do   # row-cwd-whole' '  for p in; do   # row-cwd-whole' \
    'a stop that cannot read the working directory of a process started during the run answers 4'
  shmutant_mut "stop-inspection-unbounded" \
    '  adb_run_bounded "$STOP_INSPECT" 1 env LC_ALL=C ps -A -o pid=,pgid=,ppid=,uid=,stat=,etime=,command= \' \
    '  env LC_ALL=C ps -A -o pid=,pgid=,ppid=,uid=,stat=,etime=,command= \' \
    'a stop whose inspection hangs answers 4 within its inspection bound'
  # The pools' half lives in check-lib.sh: a registration that writes nothing, and a refusal that
  # leaves the record looking complete.
  shmutant_target scripts/check-lib.sh
  shmutant_mut "register-writes-nothing" \
    '  if [ "$ok" -eq 1 ] && adb_record_append "$ADB_SELFCHECK_RECORD" "pool $p"; then   # row-register' \
    '  if true; then   # row-register' \
    'after the runner is KILLed, the stop names a detached worker in a registered pool'
  shmutant_mut "register-root-as-cwd" \
    '  case "$d" in /) ;; */) d="${d%/}" ;; esac' '  d="${d%/}"' \
    '12.4: registering [/] is refused, and marks the record incomplete'
  shmutant_mut "register-refusal-unmarked" \
    '  if : > "$ADB_SELFCHECK_RECORD.incomplete" 2>/dev/null; then' '  if false; then' \
    'a refused pool registration marks the record incomplete'
  # …and the record's one writer, in common.sh: an append to a record that has gone must fail, never
  # recreate it — which is what makes a late registration mark the record rather than restart it.
  shmutant_target scripts/lib/common.sh
  shmutant_mut "record-append-recreates" \
    '  if [ -f "$f" ] && [ ! -L "$f" ]; then' '  if true; then' \
    'a pool registered after the run record is gone marks it incomplete, never reads as outside selfcheck'

  check_shmutant_pool "selfcheck-guard" "$work/pool" mut_prepare mut_run 4
  check_summary "selfcheck-guard-mutation"
  exit 0
fi

# ============================== the fixture =====================================================
# A minimal tree the REAL selfcheck.sh can run in: itself, the library it sources for the floor
# gate, and stub checks. selfcheck.sh does `cd "$(dirname "$0")/.."`, so `$FX` becomes its repo
# root and `bash scripts/check-<x>.sh` resolves inside the fixture.
FX="$work/fx"

# mkfx <dir> — build one complete fixture tree. A FUNCTION rather than a one-off, because the
# cancellation mutations (section 10) each need their OWN tree: they fault a copy of `selfcheck.sh`
# or of `common.sh`, and a shared tree would carry one mutation into the next case's run.
mkfx() {
  local fx="$1" s
  mkdir -p "$fx/scripts/lib" "$fx/ctl" || return 1
  cp "$ROOT/scripts/selfcheck.sh" "$fx/scripts/selfcheck.sh" || return 1
  cp "$ROOT/scripts/lib/common.sh" "$fx/scripts/lib/common.sh" || return 1
  # The gate (#441): the runner asks it before dispatching any step that declares inputs. None of
  # the stubs do, so it decides nothing in the ordinary cases; section 8d registers one that does.
  cp "$ROOT/scripts/mutation-gate.sh" "$fx/scripts/mutation-gate.sh" || return 1
  # The leak stub (section 12) registers its pool through check-lib's own `check_register_pool`.
  cp "$ROOT/scripts/check-lib.sh" "$fx/scripts/check-lib.sh" || return 1
  for s in "${STUBS[@]}"; do
    printf '%s' "$STUB_SRC" > "$fx/scripts/check-$s.sh" || return 1
    chmod +x "$fx/scripts/check-$s.sh" || return 1
  done
  : > "$fx/ctl/events"
}

# The stub steps, chosen from names the real registry already carries as plain
# `bash scripts/check-<x>.sh` commands — so the fixture exercises the registry as shipped rather
# than a registry this suite rewrote.
STUBS=(practice-index bash-floor-guard gates claims state-assert release-skill workflow-shell injection)

# One generic stub, parameterised at run time by a control file per step, so a case can change a
# step's behaviour without rewriting the fixture. Control keys: RC (exit status), LINES (how many
# sentinel lines to emit), SLEEP (how long to occupy its pool slot).
#
# It also appends `+name` on entry and `-name` on exit to a shared event log. Short appends to a
# regular file opened O_APPEND are atomic, so the ORDER in that file is a valid serialization of
# what actually happened, and replaying it yields the true peak concurrency.
STUB_SRC="$(cat <<'STUB'
#!/usr/bin/env bash
set -u
name="$(basename "$0" .sh)"; name="${name#check-}"
ctl="$ADB_STUB_CTL"
rc=0; lines=1; nap=0
[ -f "$ctl/$name.rc" ]    && rc="$(cat "$ctl/$name.rc")"
[ -f "$ctl/$name.lines" ] && lines="$(cat "$ctl/$name.lines")"
[ -f "$ctl/$name.sleep" ] && nap="$(cat "$ctl/$name.sleep")"
# ENROL BEFORE ANNOUNCING, in cancellation mode. The cancellation cases wait on this event log and
# then cancel, and they ask their question of the ENROLLED set — so a stub that announced itself
# first could be cancelled while its own pid was still unrecorded, and "did every worker stop?"
# would be asked of a set that never contained it. Writing the pid first makes `+name` in the log
# a PROMISE that `$name.pid` is already readable.
#
# The PGID travels with the pid because the pid alone is not an identity: a pid the kernel has
# recycled answers `kill -0` as a stranger. Under the runner's `set -m` each worker is its own
# group leader, so this is the worker subshell's pid, and a recycled pid landing in that same
# group is not a thing that happens.
if [ -f "$ctl/$name.beat" ]; then
  printf '%s %s\n' "$$" "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" > "$ctl/$name.pid"
fi
printf '%s\n' "+$name" >> "$ctl/events"
i=1
while [ "$i" -le "$lines" ]; do printf '%s-line-%s\n' "$name" "$i"; i=$((i + 1)); done
# stderr must land in the same buffer as stdout, in order — that is what "merged" has to mean.
printf '%s-on-stderr\n' "$name" >&2
if [ -f "$ctl/$name.beat" ]; then
  # Cancellation mode: tick a counter into a file instead of sleeping opaquely, so the suite can
  # tell "this worker is still alive" from "this worker is asleep" without pgrep — the workers run
  # as `bash scripts/check-<x>.sh` from the fixture root, so their argv carries no token unique to
  # this suite and a pgrep would match the REAL check-*.sh processes running alongside it.
  #
  # `$name.deaf` additionally makes the worker IGNORE SIGTERM. Without such a worker the runner's
  # TERM -> grace -> KILL escalation cannot be observed at all: every polite stub dies on the first
  # TERM, so deleting the entire KILL loop leaves the suite green. A backstop that only ever runs
  # its first step is not a backstop.
  [ -f "$ctl/$name.deaf" ] && trap '' TERM HUP
  # Where the runner said to put temp files (#551): section 12 compares it with the run's record.
  printf '%s\n' "${TMPDIR:-}" > "$ctl/$name.tmpdir"
  # `$name.slowexit`: a worker whose own TERM cleanup takes the seconds the file holds (1.5 when it
  # is empty) — longer than the fixed 1s the runner used to give before its KILL. `$name.cleaned`
  # exists only if that cleanup was let finish.
  # `$name.trapspawn`: on TERM, start one more process in a group of its own, working in the
  # checkout, and exit at once — a worker born in cleanup that nothing records (#551's exit 6).
  if [ -f "$ctl/$name.trapspawn" ]; then
    trap '( set -m; sleep 300 & printf "spawned %s %s %s\n" "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$ctl/$name.leaked" ); exit 143' TERM
  fi
  if [ -f "$ctl/$name.slowexit" ]; then
    se="$(cat "$ctl/$name.slowexit")"; [ -n "$se" ] || se=1.5
    trap 'sleep "$se"; : > "$ctl/$name.cleaned"; exit 143' TERM
  fi
  if [ -f "$ctl/$name.leak" ]; then
    # `$name.leak` (#551): what a cancelled mutation pool leaves. A pool directory made the way
    # every suite makes one — plain `mktemp -d`, which macOS puts outside TMPDIR — and registered
    # with the run, plus a directory under the run's own TMPDIR. In the pool: a worker in a group of
    # its own, and a STOPPED process beside a holder that works in the checkout, as a shmutant
    # holder does. Under TMPDIR: one more worker. And one started only once the TERM arrives, which
    # no list taken before the stop can hold. Each is recorded `kind pid pgid` in `$name.leaked`
    # before `$name.leakready` is written.
    # shellcheck source=/dev/null
    . "$(dirname "$0")/lib/common.sh"
    # shellcheck source=/dev/null
    . "$(dirname "$0")/check-lib.sh"
    lk="$ctl/$name.leaked"
    # The pool is made OUTSIDE the run's TMPDIR on every platform — where macOS's template-less
    # `mktemp -d` puts every real pool — so only its registration can tie it to the run, and the
    # stop's two ownership rules are each observable on Linux too.
    pd="$(mktemp -d "$(cat "$ctl/$name.poolbase")/pool.XXXXXX")" && check_register_pool "$pd" || exit 97
    td="$(mktemp -d "${TMPDIR:-/tmp}/leak.XXXXXX")" || exit 97
    # Written for ANY bash: a stub runs on whatever `bash` PATH names (3.2 on a stock macOS), not on
    # the interpreter the suite re-exec'd itself into — so no $BASHPID, and each pgid is asked of ps.
    # Each line is `kind pid pgid lstart`: the start is what lets the suite's sweep tell this process
    # from a later one that reused its pid.
    ( cd "$pd" || exit; set -m; sleep 300 & printf 'worker %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk" )
    ( set -m; { ( cd "$pd" && exec sleep 300 ) & s=$!
                printf 'stopped %s %s %s\n' "$s" "$(ps -o pgid= -p "$s" | tr -d ' ')" "$(ps -o lstart= -p "$s")" >> "$lk"; exec sleep 300; } &
      printf 'holder %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk" )
    ( cd "$td" || exit; set -m; sleep 300 & printf 'rooted %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk" )
    # An ANCHORED holder: it works in the checkout beside a pool process that exits once the TERM
    # lands, so after the TERM nothing about it but the stop's own memory ties it to the run.
    ( set -m; { ( cd "$pd" && exec sleep 300 ) & s=$!
                printf 'anchor %s %s %s\n' "$s" "$(ps -o pgid= -p "$s" | tr -d ' ')" "$(ps -o lstart= -p "$s")" >> "$lk"; exec sleep 300; } &
      printf 'anchored %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk" )
    # A NESTED pool worker's shape (#547): a child of this step, in a group of its own, working in the
    # checkout. Once the step dies it is reparented, and only where it came from ties it to the run.
    set -m; sleep 300 & printf 'nested %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk"; set +m
    # STOPPED only now, after the subshell that started its group has exited. Stopping it while that
    # group could still become orphaned would have the kernel send it SIGHUP and SIGCONT, which kill
    # it — so the stopped survivor the case is about would never exist.
    n=0
    until [ "$(grep -c '' "$lk" 2>/dev/null)" -ge 7 ] || [ "$n" -ge 200 ]; do sleep 0.05; n=$((n + 1)); done
    kill -STOP "$(awk '$1 == "stopped" { print $2 }' "$lk")" 2>/dev/null
    an="$(awk '$1 == "anchor" { print $2 }' "$lk")"
    trap 'kill -KILL "$an" 2>/dev/null; ( cd "$pd" || exit; set -m; sleep 300 & printf "late %s %s %s\n" "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$lk" ); exit 143' TERM
    : > "$ctl/$name.leakready"
  fi
  # `$ctl/STOP` is the COOPERATIVE way home, and it is the only one this suite has. A worker a
  # mutation deliberately orphaned is by definition unreachable through the runner, and killing a
  # recorded pid would mean signalling a number that may since have been recycled — so the case
  # asks the stub to leave and then VERIFIES it did, instead. 900 ticks is the backstop for a stub
  # whose case died before it could ask: long enough to outlive any deadline below, short enough
  # that a crashed suite cannot leave one running for the afternoon.
  n=0
  while [ "$n" -lt 900 ]; do
    [ -f "$ctl/STOP" ] && break
    n=$((n + 1)); printf '%s\n' "$n" > "$ctl/$name.beat"; sleep 0.2
  done
else
  [ "$nap" = 0 ] || sleep "$nap"
fi
printf '%s\n' "-$name" >> "$ctl/events"
exit "$rc"
STUB
)"

ONLY="$(IFS=,; printf '%s' "${STUBS[*]}")"

mkfx "$FX" || { echo "check-selfcheck: cannot build the fixture" >&2; exit 1; }

# reset_ctl [fixture] — clear every control file and the event log, so each case starts from a
# known state. Defaults to the primary fixture; the cancellation mutations pass their own.
#
# Whatever a section-12 stub or canary left in the old control directory is swept FIRST: removing
# the directory removes the only record of those processes.
reset_ctl() { local fx="${1:-$FX}"; leak_sweep "$fx/ctl"; rm -rf "$fx/ctl"; mkdir -p "$fx/ctl"; : > "$fx/ctl/events"; }

# sc <args...> — run the fixture's selfcheck, capturing merged output in $OUT and status in $RC_.
sc() {
  OUT="$(ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/selfcheck.sh" "$@" 2>&1)"; RC_=$?
  return 0
}

# peak_concurrency — replay the event log and report the highest number of stubs live at once.
peak_concurrency() {
  awk 'BEGIN{c=0;m=0} /^\+/{c++; if(c>m)m=c} /^-/{c--} END{print m}' "$FX/ctl/events"
}

# block_of <step> — the lines the runner emitted between that step's banner and its verdict.
#
# LIMITATION, stated rather than implied: it stops at the first body line beginning `PASS (` or
# `FAIL (`, so a step whose own output contained such a line would have its block truncated here.
# No stub emits one, so no assertion is silently weakened today — but this helper cannot see
# interleaving that occurred after a verdict-shaped line, and a future stub must not emit one.
block_of() {
  printf '%s\n' "$OUT" | awk -v s="=== $1 ===" '
    $0 == s { inb = 1; next }
    inb && ($0 ~ /^PASS \(/ || $0 ~ /^FAIL \(/) { exit }
    inb { print }'
}

# ============================== 1-4. a failing step under parallelism ==========================
# THE acceptance criterion: a deliberately failing step must still fail the run, and the run must
# say which one. Everything about the pool that could go wrong quietly shows up here.
reset_ctl
printf '3\n' > "$FX/ctl/claims.rc"
sc --only "$ONLY" --jobs 4

no "$RC_" "a failing step under parallelism fails the run"
eq "$RC_" 1 "...with exit 1, the same status the sequential runner used"
has "$OUT" "SOME CHECKS FAILED" "the terminal verdict line is unchanged"
has "$OUT" "FAILED: claims" "the summary NAMES the failing step"
has "$OUT" "7 passed, 1 failed" "the counts are right: one red, the rest green"

# ATTRIBUTION. `wait -n -p` is what maps a reaped pid back to a name; without it a pool can only
# report "something failed". A dispatcher that mixed the two up would still print one FAIL and one
# failing name — just the wrong one — so this asserts the RIGHT step carries it, with the RIGHT
# code, and that no sibling was blamed.
claims_verdict="$(printf '%s\n' "$OUT" | awk '$0 == "=== claims ===" {inb=1; next} inb && /^(PASS|FAIL) \(/ {print; exit}')"
has "$claims_verdict" "FAIL (exit 3" "the failing step's own verdict carries its actual exit code"
eq "$(printf '%s\n' "$OUT" | grep -c '^FAIL (')" "1" "exactly one step is reported failed"

# COLLECT-ALL, not fail-fast. The pre-#260 runner set `fail=1` and carried on; a pool that killed
# its siblings on the first red would be a behaviour change no acceptance criterion asked for.
for s in "${STUBS[@]}"; do
  has "$OUT" "=== $s ===" "collect-all: $s still ran and was reported after a sibling failed"
done

# ATOMICITY. Eight steps each emitting several lines at once: no step's sentinel may appear inside
# another step's block. This is the property the whole buffer-and-emit-on-reap design exists for,
# and the one that a naive `cmd &` would destroy.
inter=0
for s in "${STUBS[@]}"; do
  blk="$(block_of "$s")"
  for other in "${STUBS[@]}"; do
    [ "$other" = "$s" ] && continue
    case "$blk" in *"$other-line-"*) inter=1 ;; esac
  done
  case "$blk" in *"$s-line-1"*) : ;; *) inter=1 ;; esac
done
eq "$inter" "0" "output is atomic: no step's lines appear inside another step's block"

# stderr is merged into the same buffer, not lost and not emitted separately.
has "$(block_of practice-index)" "practice-index-on-stderr" "a step's stderr lands in its own block"

# ============================== 5. the concurrency bound ======================================
# Two halves, and BOTH are load-bearing. The bound alone is satisfied by a pool that runs one job
# at a time — which would pass every assertion above while delivering nothing — so the second half
# asserts the pool is genuinely concurrent.
reset_ctl
for s in "${STUBS[@]}"; do printf '1\n' > "$FX/ctl/$s.sleep"; done
sc --only "$ONLY" --jobs 3
yes "$RC_" "a bounded parallel run of passing steps exits 0"
peak="$(peak_concurrency)"
[ "$peak" -le 3 ] && ok || bad "--jobs 3 was exceeded: peak concurrency was $peak"
[ "$peak" -ge 2 ] && ok || bad "the pool never ran two steps at once (peak $peak) — it is not parallel"

reset_ctl
for s in "${STUBS[@]}"; do printf '1\n' > "$FX/ctl/$s.sleep"; done
sc --only "$ONLY" --jobs 8
peak="$(peak_concurrency)"
[ "$peak" -ge 4 ] && ok || bad "--jobs 8 over 8 sleeping steps only reached concurrency $peak"

# ============================== 6. --serial ===================================================
# Declaration order, one at a time. This is the debugging mode, so "reproduces today's behaviour"
# has to mean something checkable: the sequence, and the absence of overlap.
reset_ctl
sc --serial --only "$ONLY"
yes "$RC_" "--serial over passing steps exits 0"
eq "$(peak_concurrency)" "1" "--serial never runs two steps at once"
serial_order="$(printf '%s\n' "$OUT" | sed -n 's/^=== \(.*\) ===$/\1/p' | grep -v '^result$' | tr '\n' ' ')"
# THE ORACLE MUST BE INDEPENDENT OF THE RUNNER. Deriving the expectation from the same runner's
# `--list` made this assertion tautological: mutate `add` to prepend rather than append and both
# `--list` and `--serial` reverse together, so the suite stayed green while declaration order was
# inverted. (Demonstrated by review, not hypothesised.) The order the `add` lines appear in the
# SOURCE is the independent fact, so read that instead.
#
# WHOLE-NAME membership, not a substring test: `bash-floor` is a substring of `bash-floor-guard`
# (in the registry, NOT selected here — that is why the pair is in the stub set), so an
# unanchored match silently adds a step the run never selected and the expectation is wrong rather
# than the runner.
declared="$(sed -n 's/^add[[:space:]]\{1,\}\([A-Za-z0-9_-]\{1,\}\)[[:space:]].*$/\1/p' \
              "$FX/scripts/selfcheck.sh" | while IFS= read -r n; do
              case ",$ONLY," in *",$n,"*) printf '%s ' "$n" ;; esac; done)"
eq "$(printf '%s' "$declared" | wc -w | tr -d ' ')" "8" \
  "fixture setup: the source-order oracle found all 8 selected steps (not a silent empty match)"
eq "$serial_order" "$declared" "--serial emits steps in DECLARATION order (vs the SOURCE, not --list)"
# ...and --list must agree with the source too, since other guards read --list as the registry.
list_order="$(bash "$FX/scripts/selfcheck.sh" --list | cut -f1 | while IFS= read -r n; do
                case ",$ONLY," in *",$n,"*) printf '%s ' "$n" ;; esac; done)"
eq "$list_order" "$declared" "--list reports the registry in SOURCE declaration order"

# ...and a failing step still fails a serial run, with the same summary shape.
reset_ctl
printf '1\n' > "$FX/ctl/gates.rc"
sc --serial --only "$ONLY"
no "$RC_" "--serial still fails when a step fails"
has "$OUT" "FAILED: gates" "--serial names the failing step too"

# ============================== 7. the serial prologue ========================================
# The MECHANISM, tested by pinning a different step in the COPY: `zulu` is declared last, so if the
# prologue works it is emitted first and holds the pool empty while it runs. Pinning build-drift
# for real cannot be tested here — it runs scripts/build.sh over the working tree, which is
# precisely the thing this suite must not do while the rest of the suite is reading that tree.
cp "$ROOT/scripts/selfcheck.sh" "$FX/scripts/pinned.sh"
cat > "$FX/scripts/check-zulu.sh" <<'STUB'
#!/usr/bin/env bash
set -u
ctl="$ADB_STUB_CTL"
printf '%s\n' "+zulu" >> "$ctl/events"
sleep 1
printf '%s\n' "-zulu" >> "$ctl/events"
echo zulu-ran
STUB
chmod +x "$FX/scripts/check-zulu.sh"
# Register zulu LAST, and pin it. Both edits are to the copy; the tracked file is untouched.
{ printf '\n'; printf 'add zulu                bash scripts/check-zulu.sh\n'; } > "$work/zulu.frag"
awk -v frag="$work/zulu.frag" '
  /^add install-dry-run/ { while ((getline l < frag) > 0) print l }
  { print }
  ' "$FX/scripts/pinned.sh" > "$work/pinned.tmp"
sed 's/^PINNED_STEPS=(build-drift)$/PINNED_STEPS=(zulu)/' "$work/pinned.tmp" > "$FX/scripts/pinned.sh"
grep -q '^PINNED_STEPS=(zulu)$' "$FX/scripts/pinned.sh" && ok \
  || bad "fixture setup: could not re-pin the copied runner (PINNED_STEPS line changed shape?)"
grep -q '^add zulu ' "$FX/scripts/pinned.sh" && ok \
  || bad "fixture setup: could not register the zulu step in the copied runner"

reset_ctl
for s in "${STUBS[@]}"; do printf '1\n' > "$FX/ctl/$s.sleep"; done
OUT="$(ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/pinned.sh" --only "$ONLY,zulu" --jobs 8 2>&1)"; RC_=$?
yes "$RC_" "the prologue run exits 0"
has "$OUT" "serial prologue: zulu" "the header names what runs in the prologue"
eq "$(sed -n 's/^=== \(.*\) ===$/\1/p' <<< "$OUT" | head -1)" "zulu" \
  "a pinned step is emitted FIRST even though it is declared LAST"
# Nothing else may be live while the prologue step runs: its `+zulu` and `-zulu` must be adjacent.
eq "$(awk '/^\+zulu$/{getline nxt; print nxt}' "$FX/ctl/events")" "-zulu" \
  "the prologue step runs ALONE — no pooled step overlapped it"

# ...and the REAL runner's prologue is exactly this set, asked of the runner rather than grepped
# out of it. TWO LANES share the prologue since #423 and they are pinned SEPARATELY, because the
# whole reason they are separate arrays is that they answer different questions: `mutates-tree` is
# a correctness requirement (build.sh rewrites files other steps read) and `load-sensitive` is a
# reliability one (these flap under contention on a 3-4 vCPU runner). A single combined pin would
# stay green while a step moved from one lane to the other, which is a silent change of reason.
real_pinned="$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$3 == "serial" {print $1}' | tr '\n' ' ')"
eq "$real_pinned" \
  "build-drift session-currency install-migration install-guard selfcheck-guard selfcheck-guard-mutation install-dry-run " \
  "the shipped runner's serial prologue is exactly the two lanes' members, in declaration order"
eq "$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$4 == "mutates-tree" {print $1}' | tr '\n' ' ')" \
  "build-drift " "the tracked-tree-mutating lane is exactly build-drift"
eq "$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$4 == "load-sensitive" {print $1}' | tr '\n' ' ')" \
  "session-currency install-migration install-guard selfcheck-guard selfcheck-guard-mutation install-dry-run " \
  "the load-sensitive lane is exactly the suites #423 mined out of CI, plus the install trio"
# THE TWO FIELDS MUST AGREE, in both directions. They are computed by different functions over
# different arrays, so nothing structural stops `lane_of` and `lane_reason` from disagreeing — and
# a step reported `pool`/`load-sensitive` (or `serial`/`concurrent`) would be dispatched by one
# answer and read by the other, which is exactly the drift the third field was added to end.
eq "$(bash "$ROOT/scripts/selfcheck.sh" --list \
       | awk -F'\t' '($3 == "serial") != ($4 != "concurrent") {n++} END {print n + 0}')" "0" \
  "--list's lane and its reason never disagree about any step"
# pinned-install stays POOLED, deliberately (#423): it appears in none of the four mined reds and
# costs 273s on the macOS runner. Isolating a suite on suspicion is what makes the leg long, and
# the length is the other half of the complaint this change answers.
eq "$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$1 == "pinned-install" {print $3}')" "pool" \
  "pinned-install is NOT isolated — speculative isolation is out of scope by decision"

# ============================== 7b. FUNCTION-valued steps ====================================
# Six of the shipped registry's commands are shell FUNCTIONS (`step_shellcheck`,
# `step_build_drift`, `step_workflow_map`, `step_skill_frontmatter`, `step_gate_detector`,
# `step_install_dry_run`), not `bash scripts/check-*.sh`. (The total is deliberately not quoted
# here: it was written as "forty" and the registry has grown past it twice since, so the number
# was a claim that drifted while the six it qualifies did not.) Every stub above is external, so a
# dispatcher that silently skipped every function-valued step — or lost its exit status, which is
# the more likely bug since a function returns rather than exiting — would pass everything so far.
# Register one in the copy and put it through both outcomes.
cp "$ROOT/scripts/selfcheck.sh" "$FX/scripts/fnstep.sh"
cat > "$work/fn.frag" <<'FRAG'

step_fixture_fn() {
  printf '%s\n' "+fnstep" >> "$ADB_STUB_CTL/events"
  printf 'fnstep-line-1\n'
  printf '%s\n' "-fnstep" >> "$ADB_STUB_CTL/events"
  [ -f "$ADB_STUB_CTL/fnstep.fail" ] && return 5
  return 0
}
add fnstep              step_fixture_fn
FRAG
awk -v frag="$work/fn.frag" '
  /^add install-dry-run/ { while ((getline l < frag) > 0) print l }
  { print }
  ' "$FX/scripts/selfcheck.sh" > "$FX/scripts/fnstep.sh"
grep -q '^add fnstep ' "$FX/scripts/fnstep.sh" && ok \
  || bad "fixture setup: could not register a function-valued step in the copied runner"

reset_ctl
OUT="$(ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/fnstep.sh" --only "practice-index,fnstep" --jobs 2 2>&1)"; RC_=$?
yes "$RC_" "a function-valued step that succeeds passes"
has "$OUT" "=== fnstep ===" "a function-valued step is dispatched, not skipped"
has "$(block_of fnstep)" "fnstep-line-1" "a function-valued step's output is captured like any other"
eq "$(grep -c '^+fnstep$' "$FX/ctl/events")" "1" "a function-valued step actually EXECUTED (once)"

reset_ctl
: > "$FX/ctl/fnstep.fail"
OUT="$(ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/fnstep.sh" --only "practice-index,fnstep" --jobs 2 2>&1)"; RC_=$?
no "$RC_" "a function-valued step that RETURNS non-zero fails the run"
has "$OUT" "FAILED: fnstep" "...and is named"
has "$OUT" "FAIL (exit 5" "...carrying the status the function returned, not a generic 1"

# ============================== 7c. registration is validated =================================
# `add` is the one place a step enters the run, so the ways a step can be registered into a silent
# no-op belong here. An empty command registered, then executed nothing and reported PASS.
mkreg() {  # mkreg <line> -> a copy of the runner with <line> appended to the registry
  awk -v line="$1" '/^add install-dry-run/ { print line } { print }' \
    "$FX/scripts/selfcheck.sh" > "$FX/scripts/reg.sh"
  ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/reg.sh" --list >/dev/null 2>&1
}
mkreg 'add empty-cmd            ""' ; eq "$?" "2" "add rejects an EMPTY command (it would PASS having run nothing)"
mkreg 'add bad,name             bash scripts/check-gates.sh'
eq "$?" "2" "add rejects a step name that --only could never select (comma)"
mkreg 'add practice-index       bash scripts/check-gates.sh'
eq "$?" "2" "add rejects a duplicate step name"
# A metacharacter that stays INSIDE the argument. Deliberately not a `;` or a `&&`: those are
# command SEPARATORS, so bash would parse them before `add` ever saw them — the injected text would
# simply run as its own command, which is a hazard to write into a fixture and proves nothing about
# the validator. `?` matches no file here, so it reaches `add` as a literal argument character.
mkreg 'add meta                 bash scripts/check-gates.sh?'
eq "$?" "2" "add rejects a command carrying a shell metacharacter inside an argument"

# ============================== 7d. automatic job sizing ======================================
# `--jobs` is passed explicitly everywhere above, so the DEFAULT — the probe chain, the whitespace
# trim and the cap at 8 — was entirely untested, and a probe that silently answered 1 would undo
# the whole change while every other assertion stayed green. The run header states the count, so
# the runner can be asked. Drive it with a stubbed probe on PATH.
probe() {  # probe <getconf-output> -> the job count the runner chose
  local sb="$work/probe"; rm -rf "$sb"; mkdir -p "$sb"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$sb/getconf"
  # sysctl and nproc are stubbed EMPTY so the fallback chain cannot rescue a bad first answer and
  # make this test pass for the wrong reason.
  printf '#!/bin/sh\nexit 1\n' > "$sb/sysctl"; printf '#!/bin/sh\nexit 1\n' > "$sb/nproc"
  chmod +x "$sb/getconf" "$sb/sysctl" "$sb/nproc"
  # ADB_POOL_JOBS CLEARED: since #335 the runner sizes its pool through `adb_pool_size`, which reads
  # that variable INSTEAD of the probe chain. Left set, every case below would read whatever an
  # operator happened to export and test nothing — while staying green on it.
  PATH="$sb:$PATH" ADB_POOL_JOBS='' ADB_STUB_CTL="$FX/ctl" \
    bash "$FX/scripts/selfcheck.sh" --only practice-index 2>&1 \
    | sed -n 's/^selfcheck: .* \([0-9][0-9]*\) parallel job(s).*/\1/p'
}
eq "$(probe 4)"      "4" "cpu probe: a plain count is used as-is"
eq "$(probe 32)"     "8" "cpu probe: the count is capped at 8"
eq "$(probe '  6  ')" "6" "cpu probe: surrounding whitespace is trimmed, not read as garbage"
eq "$(probe banana)" "1" "cpu probe: unusable output falls back to 1 rather than to an empty bound"
eq "$(probe '')"     "1" "cpu probe: an empty answer falls back to 1"

# ============================== 8. filters that select nothing ================================
# A filter that quietly matches nothing runs zero checks and prints the same clean verdict a full
# green run prints. That is the silent-guard failure this repo keeps paying for, so it is an error.
sc --only nosuchstep
eq "$RC_" "2" "--only with an unknown step name is an error"
has "$OUT" "unknown step" "...and says which"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports a pass"
sc --only ,,
eq "$RC_" "2" "--only that selects nothing is an error, not an empty pass"
# `--only "$LIST"` with an empty LIST is the realistic way this arrives, and the failure it used to
# produce was the worst available: the filter was keyed on a non-empty value, so an empty one ran
# the ENTIRE suite. A narrowing flag must never silently widen.
sc --only ""
eq "$RC_" "2" "--only with an empty value is an error, and never a full run"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports the whole suite as passed"
sc --jobs 0
eq "$RC_" "2" "--jobs 0 is rejected (a pool of zero would never dispatch)"
sc --jobs banana
eq "$RC_" "2" "--jobs with a non-integer is rejected"
sc --jobs
eq "$RC_" "2" "--jobs with no value is rejected"
sc --nonsense
eq "$RC_" "2" "an unknown flag is rejected rather than ignored"

# --list is the registry contract other guards read; it must stay FIVE TAB-separated fields (#423
# added the fourth, #441 the fifth). Field 3 keeps its original meaning — does this run in the
# serial prologue — so a consumer asking `$3 == "serial"` still gets the right answer across both
# lanes; the reason went into a new field rather than widening field 3 into three values, which
# would have made every existing correct query silently wrong instead of erroring. The fifth is
# the step's declared input set, comma-joined, or `-`; appended for the same reason.
sc --list
yes "$RC_" "--list exits 0"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF != 5 {n++} END {print n + 0}')" "0" \
  "--list emits exactly five TAB-separated fields on every row"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$5 != "-" && $5 !~ /^[A-Za-z0-9_.\/-]+(,[A-Za-z0-9_.\/-]+)*$/ {n++} END {print n + 0}')" "0" \
  "--list's fifth field is '-' or a comma-joined list of [A-Za-z0-9_./-] paths on every row"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$1 ~ /-mutation$/ && $5 == "-" {n++} END {print n + 0}')" "0" \
  "every *-mutation step in the shipped registry declares inputs (none shows '-')"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$1 !~ /-mutation$/ && $5 != "-" {n++} END {print n + 0}')" "0" \
  "…and no other step does (the gate is scoped to the mutation harnesses, #441)"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$3 != "pool" && $3 != "serial" {n++} END {print n + 0}')" "0" \
  "--list's third field is always pool or serial"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' \
       '$4 != "concurrent" && $4 != "mutates-tree" && $4 != "load-sensitive" {n++} END {print n + 0}')" "0" \
  "--list's fourth field is always one of the three declared reasons"

# ============================== 8b. --skip ====================================================
# The mirror of --only, and it earns the same fail-closed treatment for the mirror-image reason.
# --only's historical defect was a narrowing flag that silently WIDENED when handed an empty value;
# --skip's equivalent is a flag that silently narrows NOTHING, so `--skip "$LIST"` with an empty
# LIST runs the guard its author believed had been dropped — or, worse, reports a full-registry run
# as if the caller's intent had been honoured. Every one of these is an error, never a quiet pass.
sc --skip nosuchstep
eq "$RC_" "2" "--skip with an unknown step name is an error"
has "$OUT" "unknown step" "...and says which"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports a pass"
sc --skip ""
eq "$RC_" "2" "--skip with an empty value is an error, and never a full run"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports the whole suite as passed"
sc --skip ,,
eq "$RC_" "2" "--skip that names nothing is an error, not a no-op"
sc --skip
eq "$RC_" "2" "--skip with no value is rejected"
sc --only gates --skip gates
eq "$RC_" "2" "--skip that removes every selected step is an error, not an empty pass"

# A TERMINAL MODE MUST NOT BYPASS THE CONTRACT (review finding). Selection used to be validated
# AFTER `--list` and `--summarize` exited, so `--skip does-not-exist --list` returned 0 and printed
# the registry — the documented "an unknown name is an error" held only when no other flag was
# present. That is worse than not having the rule: the invocation LOOKS validated.
sc --skip nosuchstep --list
eq "$RC_" "2" "--list does not excuse an unknown --skip name"
hasnt "$OUT" "$(printf 'gates\t')" "...and the registry is not printed over the error"
sc --only nosuchstep --list
eq "$RC_" "2" "--list does not excuse an unknown --only name either"
sc --skip nosuchstep --summarize "$work/whatever.log"
eq "$RC_" "2" "--summarize does not excuse an unknown --skip name"

# THE POSITIVE HALF, and it is the one that matters: a skipped step must NOT EXECUTE, the run must
# still pass, and the skip must be VISIBLE BY NAME. The first of those is asked of the event log
# rather than of the output — a step that ran and whose block was merely not printed would satisfy
# any assertion made about the text alone, and "it silently still ran" is the failure mode a skip
# flag has.
reset_ctl
sc --only "$ONLY" --skip gates --jobs 4
yes "$RC_" "a run with a step skipped still passes"
eq "$(grep -c '^+gates$' "$FX/ctl/events")" "0" "the skipped step never EXECUTED (not merely unprinted)"
eq "$(grep -c '^+claims$' "$FX/ctl/events")" "1" "...while the steps around it did"
has "$OUT" "SKIPPED 1 step(s) by request: gates" "the skip is announced by name before the run"
has "$OUT" "skipped: gates" "...and again in the result block, where a CI reader looks"
hasnt "$OUT" "=== gates ===" "the skipped step emits no block"
# A plain run must still be the WHOLE registry: the skip is a per-invocation choice, never a new
# default, and a default that quietly shed a step is the silent-coverage-loss this flag exists to
# make impossible.
reset_ctl
sc --only "$ONLY" --jobs 4
eq "$(grep -c '^+gates$' "$FX/ctl/events")" "1" "with no --skip, every selected step runs"
hasnt "$OUT" "SKIPPED" "...and nothing is announced as skipped"

# ============================== 8d. the mutation gate (#441) ====================================
# A step that declares inputs is dispatched only when the change under test touches one of them.
# The proof is the one section 8b makes for --skip, with the same three parts: the gated step must
# NOT EXECUTE (asked of the event log), the run must still pass, and the skip must be VISIBLE BY
# NAME with what it compared. Then the three ways it must run: a touched input, the override, and a
# base the gate cannot resolve (fail-closed — a gate that cannot decide costs minutes, never
# coverage).
#
# Its own fixture, because it needs a git repository: the gate diffs the working tree against a
# merge-base, and every other case here runs in a tree that is deliberately not one.
FXG="$work/fxg"
mkfx "$FXG" || bad "fixture setup: could not build the gated fixture"
printf '%s' "$STUB_SRC" > "$FXG/scripts/check-gatedstep.sh" && chmod +x "$FXG/scripts/check-gatedstep.sh"
printf 'input v1\n' > "$FXG/scripts/gated-input.txt"
{ printf '\n'
  printf 'add gatedstep           bash scripts/check-gatedstep.sh\n'
  printf 'inputs gatedstep        scripts/gated-input.txt\n'; } > "$work/gated.frag"
awk -v frag="$work/gated.frag" '
  /^add install-dry-run/ { while ((getline l < frag) > 0) print l }
  { print }
  ' "$FXG/scripts/selfcheck.sh" > "$work/gated.tmp" && mv "$work/gated.tmp" "$FXG/scripts/selfcheck.sh"
grep -q '^inputs gatedstep ' "$FXG/scripts/selfcheck.sh" && ok \
  || bad "fixture setup: could not register the gated step in the copied runner"
printf 'ctl/\n' > "$FXG/.gitignore"
check_git "$FXG" init -q -b main >/dev/null 2>&1 && check_git "$FXG" add -A >/dev/null 2>&1 \
  && check_git "$FXG" commit -q -m base >/dev/null 2>&1 \
  && check_git "$FXG" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 \
  || bad "fixture setup: could not initialise the gated fixture's repository"
eq "$(bash "$FXG/scripts/selfcheck.sh" --list | awk -F'\t' '$1 == "gatedstep" {print $5}')" "scripts/gated-input.txt" \
  "--list carries the fixture step's declared input in field 5"

# scg <args...> — the gated fixture's selfcheck, same capture contract as sc.
scg() {
  OUT="$(ADB_STUB_CTL="$FXG/ctl" bash "$FXG/scripts/selfcheck.sh" "$@" 2>&1)"; RC_=$?
  return 0
}
reset_ctl "$FXG"
scg --only "$ONLY,gatedstep" --jobs 4
yes "$RC_" "gate: a run whose gated step has untouched inputs still passes"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "0" "gate: the gated step never EXECUTED (not merely unprinted)"
eq "$(grep -c '^+claims$' "$FXG/ctl/events")" "1" "gate: …while the ungated steps around it did"
has "$OUT" "GATED 1 step(s) — inputs unchanged (ADB_MUTATION_RUN_ALL=1 runs them): gatedstep" \
  "gate: the skip is announced by name before the run, with the override that lifts it"
has "$OUT" "SKIP: gatedstep — inputs unchanged against origin/main (merge-base " \
  "gate: …and the gate's own line says what it compared against"
has "$OUT" "inputs: scripts/gated-input.txt)" "gate: …and which inputs it checked"
has "$OUT" "gated (inputs unchanged): gatedstep" "gate: …and again in the result block, where a CI reader looks"
hasnt "$OUT" "=== gatedstep ===" "gate: the gated step emits no block"
has "$OUT" "selfcheck: 8 step(s)," "gate: the dispatch header counts what actually runs (8, not 9)"

# A touched input — UNCOMMITTED, which is the local case that matters — and the step runs.
reset_ctl "$FXG"
printf 'input v2\n' > "$FXG/scripts/gated-input.txt"
scg --only "$ONLY,gatedstep" --jobs 4
yes "$RC_" "gate: with its input touched the run passes"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "1" "gate: a step whose input changed (uncommitted) EXECUTES"
hasnt "$OUT" "GATED" "gate: …and nothing is announced as gated"
has "$OUT" "=== gatedstep ===" "gate: …and its block is emitted"
check_git "$FXG" checkout -q -- scripts/gated-input.txt

# The override: every step runs, untouched or not.
reset_ctl "$FXG"
OUT="$(ADB_MUTATION_RUN_ALL=1 ADB_STUB_CTL="$FXG/ctl" bash "$FXG/scripts/selfcheck.sh" --only "$ONLY,gatedstep" --jobs 4 2>&1)"; RC_=$?
yes "$RC_" "gate: ADB_MUTATION_RUN_ALL=1 passes"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "1" "gate: ADB_MUTATION_RUN_ALL=1 runs the gated step on an untouched tree"
hasnt "$OUT" "GATED" "gate: …and announces no gating"
has "$OUT" "ADB_MUTATION_RUN_ALL is set — the mutation gate is overridden; 1 gated step(s) run regardless" \
  "gate: …but says, once, that the override fired"

# Fail-closed: a base the gate cannot resolve means the step RUNS, and the run says nothing about
# gating — a skip is only ever issued on a diff that was actually computed.
reset_ctl "$FXG"
OUT="$(ADB_MUTATION_BASE=no-such-ref ADB_STUB_CTL="$FXG/ctl" bash "$FXG/scripts/selfcheck.sh" --only "$ONLY,gatedstep" --jobs 4 2>&1)"; RC_=$?
yes "$RC_" "gate: an unresolvable base still passes"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "1" "gate: an unresolvable base RUNS the gated step (fail-closed)"
hasnt "$OUT" "GATED" "gate: …and announces no gating"
has "$OUT" "selfcheck: NOTE — RUN: gatedstep — base no-such-ref does not resolve to a commit (fail-closed" \
  "gate: …and relays the gate's fail-closed line, so a run-because-undecidable is never mistaken for a run-because-changed"

# `--only` naming ONLY a gated step on an untouched tree: nothing runs, and the run says so rather
# than reporting a clean pass over silence.
reset_ctl "$FXG"
scg --only gatedstep --jobs 4
yes "$RC_" "gate: --only <gated step> on an untouched tree exits 0"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "0" "gate: …and did not execute it"
has "$OUT" "selfcheck: 0 step(s)," "gate: …and the header says 0 step(s) ran"
has "$OUT" "gated (inputs unchanged): gatedstep" "gate: …and the result block names it"

# A PRESENT gate that returns a status outside its contract is neither a skip nor a clean run:
# the step runs and a WARN names the code. This is the "error folded into skip" direction, and a
# regression mapping an unknown code to a skip would pass every case above (reviewer finding).
printf '#!/usr/bin/env bash\necho "gate-broken"; exit 9\n' > "$FXG/scripts/mutation-gate.sh"
reset_ctl "$FXG"
scg --only "$ONLY,gatedstep" --jobs 4
yes "$RC_" "gate: a gate returning an unknown status still lets the run pass"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "1" "gate: …and the gated step RUNS (an undecidable gate never skips)"
has "$OUT" "WARN — the mutation gate failed for gatedstep (rc 9); running it: gate-broken" \
  "gate: …and the run says the gate broke, with its code and output"
hasnt "$OUT" "GATED" "gate: …and announces no gating"

# The gate script MISSING from the tree is a loud degradation, never a silent one: every gated
# step runs and a WARN says why.
rm -f "$FXG/scripts/mutation-gate.sh"
reset_ctl "$FXG"
scg --only "$ONLY,gatedstep" --jobs 4
yes "$RC_" "gate: with mutation-gate.sh absent the run still passes"
eq "$(grep -c '^+gatedstep$' "$FXG/ctl/events")" "1" "gate: …and the gated step runs"
has "$OUT" "WARN — scripts/mutation-gate.sh is missing; every gated step runs" "gate: …and the run says the gate was missing"

# ============================== 8c. --summarize ===============================================
# The CI job-summary digest (#423 item 5). A digest's failure mode is silence — one that extracted
# nothing reads exactly like a clean run to the person it exists for — so every case below asserts
# that it SAYS what it could not find rather than rendering an empty section.
sum_fx="$work/summarize"; mkdir -p "$sum_fx"
summarize() { OUT="$(bash "$ROOT/scripts/selfcheck.sh" --summarize "$1" 2>&1)"; RC_=$?; return 0; }

# The real 08-21 shape, reproduced from the CI log that produced it: one failed step, one witness.
cat > "$sum_fx/one.log" <<'LOG'
=== practice-index ===
practice-index: PASS
PASS (0s)
=== session-currency ===
FAIL: install wires exactly one SessionStart currency hook: got [0] want [1]
FAIL (exit 1, 37s)
=== result ===
57 step(s) in 17m51s — 56 passed, 1 failed
FAILED: session-currency
SOME CHECKS FAILED
LOG
summarize "$sum_fx/one.log"
yes "$RC_" "--summarize exits 0 on a red log (it is a reporter, not a gate)"
has "$OUT" '`session-currency`' "the digest NAMES the failed step"
has "$OUT" "    session-currency: install wires exactly one SessionStart currency hook: got [0] want [1]"   "the witness is carried verbatim, in an INDENTED block a witness cannot break out of"
hasnt "$OUT" "practice-index" "a PASSING step's banner is not reported as a failure"

# The 08-19 shape: one step, several witnesses, all of which must survive.
cat > "$sum_fx/many.log" <<'LOG'
=== selfcheck-guard ===
FAIL: cancellation terminates the workers instead of orphaning them: got [0] want [1]
FAIL: cancelling --serial terminates the running step instead of leaving it behind: got [0] want [1]
FAIL: the TERM -> grace -> KILL escalation stops a worker that ignores TERM: got [0] want [1]
FAIL (exit 1, 37s)
=== result ===
FAILED: selfcheck-guard
SOME CHECKS FAILED
LOG
summarize "$sum_fx/many.log"
eq "$(printf '%s\n' "$OUT" | grep -c '^    selfcheck-guard: ')" "3" "every witness line survives, none dropped"

# Two failing steps: each witness must be attributed to ITS OWN step, which is the whole reason the
# extractor tracks banners instead of just grepping FAIL:.
cat > "$sum_fx/two.log" <<'LOG'
=== session-currency ===
FAIL: install wires exactly one SessionStart currency hook: got [0] want [1]
FAIL (exit 1, 37s)
=== selfcheck-guard ===
FAIL: cancellation terminates the workers instead of orphaning them: got [0] want [1]
FAIL (exit 1, 14s)
=== result ===
FAILED: session-currency selfcheck-guard
SOME CHECKS FAILED
LOG
summarize "$sum_fx/two.log"
has "$OUT" '`session-currency`' "both failed steps are named (1/2)"
has "$OUT" '`selfcheck-guard`' "both failed steps are named (2/2)"
has "$OUT" "    session-currency: install wires exactly one" "witness 1 is attributed to its own step"
has "$OUT" "    selfcheck-guard: cancellation terminates" "witness 2 is attributed to its own step"

# A run KILLED before its result block — no FAILED: line at all. "Any selfcheck red" includes this,
# and the digest must say the run never finished rather than imply nothing failed.
printf '=== gates ===\nstill working\n' > "$sum_fx/abort.log"
summarize "$sum_fx/abort.log"
yes "$RC_" "--summarize exits 0 on a log that never reached the result block"
has "$OUT" "no \`FAILED:\` line" "an aborted run is NAMED as aborted, not rendered as an empty digest"

# A failure with no witnesses — a step that died rather than asserting. The digest must volunteer
# that it found none, because an empty witness section is indistinguishable from a clean run.
printf '=== gates ===\nboom\nFAIL (exit 3, 1s)\n=== result ===\nFAILED: gates\nSOME CHECKS FAILED\n' \
  > "$sum_fx/nowit.log"
summarize "$sum_fx/nowit.log"
has "$OUT" '`gates`' "the failed step is still named when it produced no witness"
has "$OUT" "No \`FAIL:\` witness lines were found" "...and the absence of witnesses is STATED"

# A GREEN log must NOT be captioned "failed". CI only calls this on a red run, so this branch is
# off that path — which is exactly why it needs an assertion: nothing else would ever exercise it,
# and a reporter that says "failed" over a passing run is one somebody eventually quotes.
printf '=== gates ===\nfine\nPASS (1s)\n=== result ===\n1 step(s) in 0m01s — 1 passed, 0 failed\nALL CHECKS PASSED\n' \
  > "$sum_fx/green.log"
summarize "$sum_fx/green.log"
yes "$RC_" "--summarize exits 0 on a green log"
has "$OUT" '`selfcheck` passed' "a green log is captioned PASSED, not failed"
hasnt "$OUT" '`selfcheck` failed' "...and never carries the red heading"

# A FORGED `FAILED:` LINE MUST NOT REACH A CODE SPAN (review finding). `add` constrains what may be
# REGISTERED; it vouches for nothing read back out of a log, and any step's own output can print a
# line starting `FAILED: `. A name carrying a backtick would close the span and render the rest of
# the line as markup in a page a maintainer reads.
printf '=== gates ===\nFAIL: real witness\nFAIL (exit 1, 1s)\n=== result ===\nFAILED: gates x`**INJECTED**`\nSOME CHECKS FAILED\n' \
  > "$sum_fx/forged.log"
summarize "$sum_fx/forged.log"
yes "$RC_" "--summarize survives a forged FAILED: line"
has "$OUT" '`gates`' "the legitimate name still renders"
hasnt "$OUT" '**INJECTED**' "the forged markup is NOT rendered"
has "$OUT" "unparsable name omitted" "...and its omission is STATED, not silent"

# Reporter errors are the reporter's own, and they fail closed rather than printing a hopeful blank.
summarize "$sum_fx/does-not-exist.log"
eq "$RC_" "2" "--summarize on an unreadable file is an error"
# `-r` alone is true for a readable DIRECTORY, which parsed as a log with no markers and produced
# an invented "the run was cancelled" report — a reporter inventing a verdict about a run that does
# not exist. A FIFO would have been worse: `sed` on it blocks with no bound but the job timeout.
summarize "$sum_fx"
eq "$RC_" "2" "--summarize on a DIRECTORY is an error, not an invented 'cancelled' report"
sc --summarize
eq "$RC_" "2" "--summarize with no file is rejected"
# `--summarize ""` had no GIVEN bit, so it fell through to the ordinary path: a reporting flag
# silently becoming a full run of the suite. Both spellings, because `--list` is what exposed it.
sc --summarize ""
eq "$RC_" "2" "--summarize with an empty path is rejected, and never a full run"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports the whole suite as passed"
sc --summarize "" --list
eq "$RC_" "2" "--summarize with an empty path is rejected even alongside --list"
OUT="$(bash "$ROOT/scripts/selfcheck.sh" --list --summarize "$sum_fx/one.log" 2>&1)"; RC_=$?
eq "$RC_" "2" "--list and --summarize together are rejected rather than silently ordered"

# ============================== 8e. the overrun warning (#445) ================================
# `wait -n` has no timeout, so a step that never ended used to be awaited in silence. A ticker now
# names every step past ADB_SELFCHECK_OVERRUN_SECS live, and the result block names them again. It
# REPORTS and never kills: an overrunning step must still finish and keep its own verdict, and a red
# one must still fail the run by name — under the pool and under --serial alike.
overrun_sc() {   # <ceiling> <args...> — the fixture's selfcheck under a given ceiling
  local c="$1"; shift
  OUT="$(ADB_STUB_CTL="$FX/ctl" ADB_SELFCHECK_OVERRUN_SECS="$c" bash "$FX/scripts/selfcheck.sh" "$@" 2>&1)"; RC_=$?
}
overran_line() { printf '%s\n' "$OUT" | grep '^overran (past '; }

reset_ctl
printf '10\n' > "$FX/ctl/gates.sleep"
printf '5\n' > "$FX/ctl/claims.sleep"; printf '5\n' > "$FX/ctl/claims.rc"
overrun_sc 2 --only "$ONLY" --jobs 4
eq "$RC_" "1" "a red step past the ceiling still fails the run"
has "$OUT" "FAILED: claims" "...and is named, with the ticker running"
has "$OUT" "FAIL (exit 5," "...with its own exit code"
has "$OUT" "selfcheck: still running past 2s: gates (" "a step past the ceiling is named LIVE"
has "$(block_of gates)" "gates-line-1" "an overrunning step still runs to completion and emits its block"
has "$(overran_line)" "gates" "the result block names a step that overran and passed"
has "$(overran_line)" "claims" "the result block names a step that overran and failed"
hasnt "$(overran_line)" "practice-index" "a step that finished inside the ceiling is not named"
# The ticker is a job in the same `wait -n` and must never be mistaken for a step.
eq "$(printf '%s\n' "$OUT" | grep -c '^=== ')" "9" "the ticker is never emitted as a step (8 banners + result)"
has "$OUT" "8 step(s) in" "the step count is unchanged by the ticker"
# AGAIN at each later multiple, and never more often: a 10s step under a 2s ceiling is ticked about
# every 2s, so it is named more than once, and never more than once per multiple it crossed. The
# last line's elapsed figure must also have reached a SECOND multiple, which a warning that fired
# once and then stayed silent could not show.
_n="$(printf '%s\n' "$OUT" | grep -c '^selfcheck: still running past 2s: gates (')"
# The ceiling on the count is the multiples the step actually crossed, from its OWN reported time:
# under load a 10 s sleep can take longer, and a fixed number would then fail a correct ticker.
_gs="$(printf '%s\n' "$OUT" | awk '/^=== gates ===$/ { p = 1; next } p && /^(PASS|FAIL) \(/ { s = $0; sub(/.*[ (]/, "", s); sub(/s\)$/, "", s); print s; exit }')"
[ "$_n" -ge 2 ] && [ "$_n" -le $(( ${_gs:-0} / 2 )) ] && ok || bad "a ${_gs:-?}s step under a 2s ceiling was named $_n time(s), not once per later multiple it crossed"
_last="$(printf '%s\n' "$OUT" | sed -n 's/^selfcheck: still running past 2s: gates (\([0-9]*\)s so far)$/\1/p' | tail -1)"
[ -n "$_last" ] && [ "$_last" -ge 4 ] && ok || bad "the last warning for a 10s step said ${_last:-nothing}s — it was never repeated at a later multiple"

reset_ctl
printf '5\n' > "$FX/ctl/gates.sleep"
overrun_sc 2 --serial --only "$ONLY"
yes "$RC_" "--serial with an overrunning step that passes still exits 0"
has "$OUT" "selfcheck: still running past 2s: gates (" "--serial names a step past the ceiling LIVE"
has "$(overran_line)" "gates" "--serial's result block names it too"
# …and a step that overruns and THEN fails keeps its own status: the serial loop's wait reaps the
# ticker as well as the step, and only the step's status may reach the verdict.
reset_ctl
printf '5\n' > "$FX/ctl/gates.sleep"; printf '6\n' > "$FX/ctl/gates.rc"
overrun_sc 2 --serial --only "$ONLY"
eq "$RC_" "1" "--serial: a step that overran and then failed still fails the run"
has "$OUT" "FAILED: gates" "--serial: the overrunning failure is named"
has "$OUT" "FAIL (exit 6," "--serial: the overrunning failure keeps its own exit code, not the ticker's"

# The ticker must not hold a fast run open: the default one-minute tick is killed when the pool drains.
reset_ctl
_t0="$EPOCHSECONDS"
# EMPTY, not inherited: a caller's own ceiling would decide which ticker this case exercises.
ADB_SELFCHECK_OVERRUN_SECS='' sc --only "$ONLY" --jobs 4
yes "$RC_" "a fast run under the default ceiling exits 0"
[ $(( EPOCHSECONDS - _t0 )) -lt 30 ] && ok || bad "a fast run took $(( EPOCHSECONDS - _t0 ))s — the ticker held it open"
hasnt "$OUT" "overran" "a fast run names nothing as overrunning"

# The ceiling is validated, and only where it is used: --list never depends on it.
for _v in abc 0 -1 1234567890; do
  overrun_sc "$_v" --only "$ONLY"
  eq "$RC_" "2" "ADB_SELFCHECK_OVERRUN_SECS='$_v' is a usage error"
  has "$OUT" "ADB_SELFCHECK_OVERRUN_SECS must be a positive integer" "ADB_SELFCHECK_OVERRUN_SECS='$_v' is named"
done
overrun_sc abc --list
yes "$RC_" "--list does not depend on the overrun ceiling"

# --summarize carries the names: from the result block, or — for a run cancelled while a step hung,
# which never reaches it — from the live lines. A name is re-validated before it enters a span.
cat > "$sum_fx/overran.log" <<'LOG'
=== gates ===
PASS (1900s)
=== result ===
1 step(s) in 31m40s — 1 passed, 0 failed
overran (past 1800s): gates
ALL CHECKS PASSED
LOG
summarize "$sum_fx/overran.log"
has "$OUT" "Ran past the overrun warning:" "a green digest still names a step that overran"
has "$OUT" '`gates`' "...by name"
printf '=== gates ===\nselfcheck: still running past 1800s: session-context-mutation (1800s so far)\nselfcheck: still running past 1800s: session-context-mutation (3600s so far)\n' > "$sum_fx/hung.log"
summarize "$sum_fx/hung.log"
has "$OUT" '`session-context-mutation`' "a cancelled run's digest names the step from its live warning"
eq "$(printf '%s\n' "$OUT" | grep -o 'session-context-mutation' | wc -l | tr -d ' ')" "1" "...once, however many times it was warned about"
printf '=== result ===\noverran (past 1800s): gates x`**INJECTED**`\nFAILED: gates\nSOME CHECKS FAILED\n' > "$sum_fx/overran-forged.log"
summarize "$sum_fx/overran-forged.log"
hasnt "$OUT" '**INJECTED**' "a forged overrun name is not rendered"
has "$OUT" "unparsable name omitted" "...and its omission is stated"
# A GLOB-SHAPED TOKEN IS ONE TOKEN. The digest runs from the checkout root, where an unquoted
# expansion of `scripts/*` became one omission notice per file there (and a glob that matched
# slug-shaped names would have rendered names no run printed). Both lists, since both split the same way.
printf '=== result ===\noverran (past 1800s): gates scripts/*\nFAILED: gates scripts/*\nSOME CHECKS FAILED\n' > "$sum_fx/glob.log"
summarize "$sum_fx/glob.log"
eq "$(printf '%s\n' "$OUT" | grep -o 'unparsable name omitted' | wc -l | tr -d ' ')" "2" \
  "a glob-shaped name is one omitted token in each list, never expanded against the checkout"

# ============================== 9. large output ===============================================
# A step's buffer is a file precisely so a big one survives; a variable would have eaten the
# trailing newlines and a pipe would have needed a reader. 4000 lines is well past PIPE_BUF.
reset_ctl
printf '4000\n' > "$FX/ctl/gates.lines"
sc --only "$ONLY" --jobs 4
yes "$RC_" "a step emitting thousands of lines still passes"
blk="$(block_of gates)"
has "$blk" "gates-line-1" "large output: the first line survives"
has "$blk" "gates-line-4000" "large output: the last line survives"
eq "$(printf '%s\n' "$blk" | grep -c '^gates-line-')" "4000" "large output: every line survives, none dropped"

# mutate_line <file> <exact-line> <sed-script> <label> — a thin DELEGATION to check-lib.sh's
# `check_mutate_line`. It must remain a delegation and never a second copy: a mutation harness that
# has quietly diverged between two suites is worse than one home, because each suite's proofs then
# rest on a different set of guarantees.
mutate_line() { check_mutate_line "$@"; }

# RACE_SED — the dispatch gate, shared by 10.4 and its mutation so the case and the row that proves
# it can never be injecting different things. Same-line, not a second line: `\n` in a `sed`
# replacement is a GNU extension, and this suite runs on the macOS runner too.
RACE_SED='s#^      ( export GIT_OPTIONAL_LOCKS=0; run_step "\$name" ) >"\$out" 2>&1 &$#      ( export GIT_OPTIONAL_LOCKS=0; run_step "$name" ) >"$out" 2>\&1 \& while [ -f "$ADB_STUB_CTL/HOLD" ]; do sleep 0.05; done#'

# ============================== 10. cancellation ==============================================
# Bash gives an asynchronous command SIGINT-ignore when job control is off, so without the runner's
# own traps a cancelled run kills the parent and leaves up to $JOBS check suites running
# unattended.
#
# WHAT "STOPPED" MEANS HERE, and why it is not a heartbeat. Death is directly observable, so it is
# directly observed: each stub enrols its own pid, and a case waits for ITS OWN enrolled pids to be
# gone. The predicate this replaced sampled heartbeat FILES, and read every one in the control
# directory, so a single surviving worker failed all three cases at once (#387; D84 carries the
# measurements and the diagnosis).
#
# THE DEADLINE IS A GUARD AGAINST MISREADING A LOADED MACHINE, not the thing that makes a case
# pass. A registered worker is reaped inside the runner's TERM trap, synchronously, ending in a
# SIGKILL nothing survives once the grace (ADB_SELFCHECK_STOP_GRACE_SECS, 2s here) has run out — so a
# polite worker's healthy answer arrives at once, a deaf one's within the grace, and a long deadline
# costs a passing run nothing. What it buys is that a runner slow to even PROCESS the signal is
# waited for rather than reported as an orphan.
#
# CANCEL ONLY ONCE THE SET IS CLOSED. A case that cancels while dispatch is still in flight is
# asking its question of a set that is still growing, and "every enrolled pid is gone" is then a
# statement about whichever workers happened to have enrolled — green whether or not the rest were
# reaped. So each case below names how many workers its run will occupy and waits for exactly that
# many enrolments before it signals. The ONE case that deliberately cancels mid-dispatch (10.4) is
# the case about that window, and it says so.

# CANCEL_DEADLINE — how long a case waits for its workers to be gone. Generous by intent: the
# healthy answer arrives inside the runner's own TERM->KILL grace, which this suite sets to 2s. The
# mutations below pass a short one, because a worker that was never signalled is alive IMMEDIATELY
# and stays that way — waiting 30s to be told so would buy nothing and cost it on a required check.
# It must still exceed the grace, or a mutation would "observe survival" during legitimate
# escalation.
CANCEL_DEADLINE="${ADB_CANCEL_DEADLINE_SECS:-30}"

# stub_state <pid> <pgid> — "alive" | "dead" | "gone". Follows check-common-lib.sh's `gc_alive`:
# `kill -0` alone reports a ZOMBIE as alive, and a zombie is a worker that HAS stopped. The pgid is
# checked too, so a recycled pid reads as what it is — not our worker — rather than as a survivor.
stub_state() {
  local p="$1" want_pg="$2" row state pg
  case "$p" in ''|*[!0-9]*) printf 'gone'; return ;; esac
  kill -0 "$p" 2>/dev/null || { printf 'dead'; return; }
  row="$(ps -o state=,pgid= -p "$p" 2>/dev/null)"
  [ -n "$row" ] || { printf 'dead'; return; }
  state="$(printf '%s' "$row" | awk '{print $1}')"
  pg="$(printf '%s' "$row" | awk '{print $2}')"
  case "$state" in Z*) printf 'dead'; return ;; esac
  [ -n "$want_pg" ] && [ -n "$pg" ] && [ "$pg" != "$want_pg" ] && { printf 'dead'; return; }
  printf 'alive'
}

# enrolled_alive <ctl> — print one `name:pid:pgid:state` field per enrolled worker still running,
# and nothing when every one of them has stopped. The RETURN VALUE of these cases, in one place:
# both the verdict and the evidence for it come from here, so a failure can name what survived.
#
# AN UNREADABLE ENROLMENT COUNTS AS PRESENT, never as absent. `> "$ctl/$name.pid"` truncates before
# it writes, so for the microseconds in between the file EXISTS and is EMPTY — and skipping it there
# would let a case conclude "every worker stopped" about a worker whose pid it simply had not read
# yet. Reporting it keeps the poll going; nothing leaves that state for the length of a deadline,
# so it cannot strand a case either.
enrolled_alive() {
  local ctl="$1" f n p pg st out=""
  for f in "$ctl"/*.pid; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.pid}"
    p=""; pg=""
    read -r p pg < "$f" 2>/dev/null || :
    # BOTH fields, or the enrolment is not readable. A pid without its pgid still identifies a
    # process, but not OUR process: it is the pgid that tells a recycled number from the worker,
    # and accepting a half-written line would drop that check silently rather than loudly.
    case "$p$pg" in *[!0-9]*) out="$out $n:${p:-?}:${pg:-?}:unreadable"; continue ;; esac
    [ -n "$p" ] && [ -n "$pg" ] || { out="$out $n:${p:-?}:${pg:-?}:unreadable"; continue ; }
    st="$(stub_state "$p" "$pg")"
    [ "$st" = alive ] && out="$out $n:$p:${pg:-?}:$st"
  done
  printf '%s' "${out# }"
}

# enrolled_count <ctl> — how many workers have READABLY enrolled so far. Readably, because this is
# what closes the set the cases cancel against: a file counted before its pid arrived would let a
# case signal while it still could not name every worker it was about to ask about.
enrolled_count() {
  local ctl="$1" f p c=0
  for f in "$ctl"/*.pid; do
    [ -e "$f" ] || continue
    p=""; pg=""; read -r p pg < "$f" 2>/dev/null || :
    case "$p$pg" in *[!0-9]*) continue ;; esac
    [ -n "$p" ] && [ -n "$pg" ] || continue
    c=$((c + 1))
  done
  printf '%s' "$c"
}

# stop_stubs <ctl> — ask every stub to leave, then VERIFY it did. Cooperative, never a kill: a
# mutation's orphan is unreachable through the runner by construction, and signalling a recorded
# pid means signalling a number the kernel may have recycled. Prints what refused to go, if any.
stop_stubs() {
  local ctl="$1" deadline stragglers=""
  # A STOP that could not be WRITTEN is not a quiet shutdown, it is a shutdown that never happened.
  # Reporting it as no stragglers would hide exactly the workers the caller is asking about.
  : > "$ctl/STOP" 2>/dev/null || { printf 'STOP-unwritable'; return 0; }
  deadline=$(( BASH_MONOSECONDS + 15 ))
  while [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do
    stragglers="$(enrolled_alive "$ctl")"
    [ -z "$stragglers" ] && break
    sleep 0.1
  done
  printf '%s' "$stragglers"
}

# cancel_case <fixture> <label> <want> <deadline-secs> <selfcheck args…> — start a run whose stubs
# heartbeat, wait until <want> of them have ENROLLED, TERM the runner, and report whether every
# enrolled worker stopped. Sets three globals, and asserts NOTHING itself: the callers below assert
# in both directions, because a mutation's whole point is that this must come back the other way.
#
#   CANCEL_TERMINATED  1 = every enrolled worker stopped within the deadline; 0 = one did not;
#                      `unstaged` = the run never started its workers, so nothing was observed
#   CANCEL_RC          the runner's own exit status (after a forced reap, that of the KILL)
#   CANCEL_DIAG        what was observed — the evidence line a CI log otherwise never carries
#
# THE RUNNER IS NOT WAITED FOR FIRST, and that ordering is load-bearing. Bash defers a trapped
# signal while a FOREGROUND child runs, so against the mutation that returns `run_serial` to its
# pre-fix foreground shape the runner cannot exit until its step does — and a `wait` here would
# sit out the stub's entire lifetime and then find everything tidily dead. That is the mutation
# reporting a clean pass, which is the one answer it must never be able to give. The workers are
# therefore polled while the runner is still running, and the runner is reaped afterwards.
cancel_case() {
  local fx="$1" label="$2" want="$3" secs="$4"; shift 4
  local ctl="$fx/ctl" runner deadline got alive="" straggler
  CANCEL_TERMINATED=0; CANCEL_RC=""; CANCEL_DIAG=""

  ADB_STUB_CTL="$ctl" bash "$fx/scripts/selfcheck.sh" --only "$ONLY" "$@" \
    >"$fx/cancel.out" 2>&1 &
  runner=$!

  # SETUP, not assertion: a run whose workers never started has staged nothing, and must not be
  # allowed to answer the question this case asks. Generous, for the same reason as the deadline.
  deadline=$(( BASH_MONOSECONDS + 60 ))
  got=0
  while [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do
    got="$(enrolled_count "$ctl")"
    [ "$got" -ge "$want" ] && break
    sleep 0.05
  done
  if [ "$got" -lt "$want" ]; then
    # "NEVER STAGED" IS ITS OWN ANSWER, and it must not be spellable as either verdict. A run whose
    # workers never started has observed nothing, and `0` here would read to a mutation caller as
    # "a worker survived" — the exact false green that let a mutation which SYNTAX-ERRORED the
    # runner report itself as proof. Same rule as check-common-lib.sh's `gc_alive`: dead and
    # no-evidence are different answers. Every caller compares against `0` or `1`, so this fails
    # both, loudly, carrying the diagnosis.
    CANCEL_TERMINATED="unstaged"
    CANCEL_DIAG="only $got of $want worker(s) enrolled — the case never staged"
    kill -TERM "$runner" 2>/dev/null; wait "$runner" 2>/dev/null; CANCEL_RC=$?
    stop_stubs "$ctl" >/dev/null
    return 1
  fi

  kill -TERM "$runner" 2>/dev/null
  deadline=$(( BASH_MONOSECONDS + secs ))
  while :; do
    alive="$(enrolled_alive "$ctl")"
    [ -z "$alive" ] && { CANCEL_TERMINATED=1; break; }
    [ "$BASH_MONOSECONDS" -ge "$deadline" ] && break
    sleep 0.1
  done

  # The runner is reaped only now, and with a bound of its own — see the header. A runner still
  # blocked in a foreground step is exactly what a red case has just diagnosed; STOP releases it.
  if [ "$CANCEL_TERMINATED" = 1 ]; then
    wait "$runner" 2>/dev/null; CANCEL_RC=$?
    CANCEL_DIAG="all $got enrolled worker(s) stopped; runner exited $CANCEL_RC"
  else
    CANCEL_DIAG="still alive after ${secs}s [$alive] (of $got enrolled)"
    : > "$ctl/STOP" 2>/dev/null
    deadline=$(( BASH_MONOSECONDS + 20 ))
    while kill -0 "$runner" 2>/dev/null && [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do sleep 0.1; done
    kill -KILL "$runner" 2>/dev/null
    wait "$runner" 2>/dev/null; CANCEL_RC=$?
  fi

  straggler="$(stop_stubs "$ctl")"
  [ -n "$straggler" ] && CANCEL_DIAG="$CANCEL_DIAG; STOP left [$straggler] running"
  return 0
}

# mut_parses <fixture> <label> — the control an INJECTED fixture owes. 10.4 edits its copy of the
# runner to hold the dispatch window open; an edit that stops it parsing changes whether the runner
# runs at all rather than when it is cancelled, and stages no workers. `--mutation` owes the same
# check for the same reason, and takes it in `mut_run`.
mut_parses() {
  local fx="$1" label="$2" f rc=0
  for f in "$fx/scripts/selfcheck.sh" "$fx/scripts/lib/common.sh"; do
    bash -n "$f" 2>/dev/null || { bad "$label: the mutated ${f##*/} no longer PARSES — the mutation broke the runner rather than changing its reaping"; rc=1; }
  done
  return "$rc"
}

# arm_cancel <fixture> [deaf] — put every stub into heartbeat mode for the next case.
arm_cancel() {
  local fx="$1" deaf="${2:-}" s
  reset_ctl "$fx"
  for s in "${STUBS[@]}"; do
    printf '0\n' > "$fx/ctl/$s.beat"
    [ -n "$deaf" ] && : > "$fx/ctl/$s.deaf"
  done
}

# --- 10.1 the pool ----------------------------------------------------------------------------
# `--jobs 4` over eight stubs occupies exactly four slots, so four is the closed set.
arm_cancel "$FX"
cancel_case "$FX" "cancellation" 4 "$CANCEL_DEADLINE" --jobs 4
no "$CANCEL_RC" "a cancelled run exits non-zero"
eq "$CANCEL_TERMINATED" "1" "cancellation terminates the workers instead of orphaning them ($CANCEL_DIAG)"

# --- 10.2 --serial ----------------------------------------------------------------------------
# A DIFFERENT code path, and the one that was left uncovered. A serial step used to run in the
# foreground, where a TERM aimed at the runner never reaches it — so cancelling during the
# `build-drift` prologue left a `scripts/build.sh` still rewriting the working tree after the
# runner had exited. One step runs at a time, so one enrolment is the whole set.
arm_cancel "$FX"
cancel_case "$FX" "cancellation (--serial)" 1 "$CANCEL_DEADLINE" --serial
no "$CANCEL_RC" "a cancelled --serial run exits non-zero"
eq "$CANCEL_TERMINATED" "1" "cancelling --serial terminates the running step instead of leaving it behind ($CANCEL_DIAG)"

# --- 10.3 workers that IGNORE SIGTERM ---------------------------------------------------------
# This is what makes the TERM -> grace -> KILL escalation observable: with only polite stubs,
# deleting the entire KILL loop from `_cleanup` leaves every assertion green. A deaf worker is
# stopped only by the escalation, so this is the case that can see it missing.
arm_cancel "$FX" deaf
cancel_case "$FX" "cancellation (TERM-ignoring workers)" 4 "$CANCEL_DEADLINE" --jobs 4
no "$CANCEL_RC" "a cancelled run exits non-zero even when its workers ignore TERM"
eq "$CANCEL_TERMINATED" "1" "the TERM -> grace -> KILL escalation stops a worker that ignores TERM ($CANCEL_DIAG)"

# --- 10.4 cancellation DURING dispatch --------------------------------------------------------
# THE CASE #387 TURNED OUT TO BE ABOUT. `run_pool` forks a worker and records it in `LIVE` on the
# NEXT statement; a cancellation landing between the two used to find a worker `_cleanup` could not
# see, and orphaned it. One statement wide on an idle machine, and wide enough to hit on a 3-core
# runner carrying more suites than it has cores.
#
# THE WINDOW IS HELD OPEN, NOT WAITED FOR. A copy of the runner gets a gate injected at exactly
# that point — a loop that spins while `$ctl/HOLD` exists — so the cancellation is GUARANTEED to
# arrive before the registration rather than likely to. Injecting a `sleep` instead would make this
# case a race about whether a worker enrols faster than the parent wakes, which is precisely the
# kind of assertion #387 exists to delete.
#
# The runner leaves the gate on its own: TERM is trapped, and bash runs the trap between the loop's
# iterations, so `_cleanup` runs and exits from inside it. HOLD is removed afterwards for tidiness,
# not for correctness.
FXRACE="$work/fx-race"
mkfx "$FXRACE" || bad "10.4: could not build the race fixture"
if mutate_line "$FXRACE/scripts/selfcheck.sh" \
     '      ( export GIT_OPTIONAL_LOCKS=0; run_step "$name" ) >"$out" 2>&1 &' \
     "$RACE_SED" "10.4 dispatch gate" && mut_parses "$FXRACE" "10.4"; then
  arm_cancel "$FXRACE"
  : > "$FXRACE/ctl/HOLD"
  cancel_case "$FXRACE" "cancellation (mid-dispatch)" 1 "$CANCEL_DEADLINE" --jobs 4
  rm -f "$FXRACE/ctl/HOLD"
  eq "$CANCEL_TERMINATED" "1" \
    "a worker forked but not yet recorded in LIVE is still reaped ($CANCEL_DIAG)"
fi

# --- 10.5 an overrun is judged by the step's own stamps, not by its dispatch or reaping (#445) --
# A gate injected just AFTER the step's start is recorded holds the parent, so a step that ends at once
# is not reaped until the hold lifts. By then it is past the ceiling, and it must still not be named.
# (After the start stamp, not after the fork: a hold before the stamp delays the start too, and the
# reap would then not be late at all.)
HOLD_T0_SED='s#^      pid_name\["\$pid"\]="\$name"; pid_out\["\$pid"\]="\$out"; pid_t0\["\$pid"\]="\$EPOCHSECONDS"$#&; while [ -f "$ADB_STUB_CTL/HOLD" ]; do sleep 0.05; done#'
FXHOLD="$work/fx-hold"
mkfx "$FXHOLD" || bad "10.5: could not build the hold fixture"
if mutate_line "$FXHOLD/scripts/selfcheck.sh" \
     '      pid_name["$pid"]="$name"; pid_out["$pid"]="$out"; pid_t0["$pid"]="$EPOCHSECONDS"' \
     "$HOLD_T0_SED" "10.5 post-start gate" && mut_parses "$FXHOLD" "10.5"; then
  : > "$FXHOLD/ctl/HOLD"
  ( sleep 4; rm -f "$FXHOLD/ctl/HOLD" ) &
  _hold=$!
  OUT="$(ADB_STUB_CTL="$FXHOLD/ctl" ADB_SELFCHECK_OVERRUN_SECS=2 bash "$FXHOLD/scripts/selfcheck.sh" --only gates --jobs 4 2>&1)"; RC_=$?
  wait "$_hold" 2>/dev/null
  yes "$RC_" "10.5: a run held at dispatch still passes"
  has "$OUT" "gates-line-1" "10.5: the held step ran"
  _rs="$(printf '%s\n' "$OUT" | awk '/^=== gates ===$/ { p = 1; next } p && /^PASS \(/ { s = $0; sub(/.*[ (]/, "", s); sub(/s\)$/, "", s); print s; exit }')"
  [ "${_rs:-0}" -ge 3 ] && ok || bad "10.5: the step was reaped at ${_rs:-?}s, not past the 2s ceiling — the case is not the one it names"
  hasnt "$OUT" "overran" "a step that ENDED inside the ceiling is not named, however late it was reaped"
fi
# …and the mirror image: a hold right after the FORK, before the start is recorded, must not shrink a
# real overrun. A 3 s step under a 2 s ceiling is named, however late the parent recorded its start.
FXHOLD2="$work/fx-hold2"
mkfx "$FXHOLD2" || bad "10.5: could not build the second hold fixture"
if mutate_line "$FXHOLD2/scripts/selfcheck.sh" \
     '      ( export GIT_OPTIONAL_LOCKS=0; run_step "$name" ) >"$out" 2>&1 &' \
     "$RACE_SED" "10.5 dispatch gate" && mut_parses "$FXHOLD2" "10.5"; then
  printf '3\n' > "$FXHOLD2/ctl/gates.sleep"
  : > "$FXHOLD2/ctl/HOLD"
  ( sleep 4; rm -f "$FXHOLD2/ctl/HOLD" ) &
  _hold=$!
  OUT="$(ADB_STUB_CTL="$FXHOLD2/ctl" ADB_SELFCHECK_OVERRUN_SECS=2 bash "$FXHOLD2/scripts/selfcheck.sh" --only gates --jobs 4 2>&1)"; RC_=$?
  wait "$_hold" 2>/dev/null
  yes "$RC_" "10.5: a run held before its start was recorded still passes"
  has "$OUT" "overran (past 2s): gates" "a step that RAN past the ceiling is named, however late its start was recorded"
fi

# --- 10.6 the grace lets a worker's own cleanup finish (#551) --------------------------------
# The runner used to give its workers a fixed 1s between TERM and KILL, so a harness whose own TERM
# cleanup took longer was KILLed in the middle of it — which is how a vendored-shmutant shell is KILLed
# between freezing a tree and killing it, leaving that tree stopped for good (BWBama85/shmutant#47).
# Each worker here takes 1.5s to clean up and marks the end of it. A 6s grace must let all four
# finish — and costs only those 1.5s, since the KILL waits for the groups to be gone, not for the
# grace; KILLing at 1s, or not waiting at all, leaves the marks missing.
arm_cancel "$FX"
for s in "${STUBS[@]}"; do : > "$FX/ctl/$s.slowexit"; done
ADB_SELFCHECK_STOP_GRACE_SECS=6
cancel_case "$FX" "cancellation (slow cleanup)" 4 "$CANCEL_DEADLINE" --jobs 4
ADB_SELFCHECK_STOP_GRACE_SECS=2
eq "$CANCEL_TERMINATED" "1" "cancellation (slow cleanup) still terminates every worker ($CANCEL_DIAG)"
_slow_enrolled=0; _slow_cleaned=0
for s in "${STUBS[@]}"; do
  [ -f "$FX/ctl/$s.pid" ] || continue
  _slow_enrolled=$(( _slow_enrolled + 1 ))
  [ -f "$FX/ctl/$s.cleaned" ] && _slow_cleaned=$(( _slow_cleaned + 1 ))
done
[ "$_slow_enrolled" -ge 4 ] && ok || bad "10.6: only $_slow_enrolled worker(s) enrolled — the case never staged"
eq "$_slow_cleaned" "$_slow_enrolled" "a worker's own TERM cleanup finishes inside the grace instead of being KILLed mid-way"

# --- 10.7 a worker cancelled between LIVE and its record is still recorded (#551) --------------
# Dispatch marks a worker LIVE a statement before it appends the worker's group to the run record.
# A cancellation landing between the two must still leave that group in the record — it is what
# `--stop` reads after a cancelled run — so `_cleanup` records every LIVE worker not yet recorded.
# The window is HELD open in a copy of the runner, as 10.4 holds its own.
REC_HOLD_SED='s#^      LIVE\["\$pid"\]=1$#      LIVE["$pid"]=1; while [ -f "$ADB_STUB_CTL/HOLD" ]; do sleep 0.05; done#'
FXREC="$work/fx-rec"
mkfx "$FXREC" || bad "10.7: could not build the record fixture"
if mutate_line "$FXREC/scripts/selfcheck.sh" '      LIVE["$pid"]=1' "$REC_HOLD_SED" "10.7 record gate" \
     && mut_parses "$FXREC" "10.7"; then
  arm_cancel "$FXREC"
  : > "$FXREC/ctl/HOLD"
  # `ps -A` is refused, as inside a sandbox, so the runner's cancel-time table read cannot record the
  # worker too: the LIVE-based recording in `_cleanup` is the only thing left that can.
  _psA="$work/ps-no-table"; mkdir -p "$_psA"
  printf '#!/bin/sh\ncase " $* " in *" -A "*) echo "ps: operation not permitted" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$(command -v ps)" > "$_psA/ps"; chmod +x "$_psA/ps"
  PATH="$_psA:$PATH" cancel_case "$FXREC" "cancellation (before the record)" 1 "$CANCEL_DEADLINE" --jobs 4
  rm -f "$FXREC/ctl/HOLD"
  _held_pg=""
  for _f in "$FXREC"/ctl/*.pid; do [ -f "$_f" ] && { read -r _ _held_pg < "$_f"; break; }; done
  [ -n "$_held_pg" ] && ok || bad "10.7: the held worker never enrolled — the case did not stage"
  case "$(cat "$FXREC/.selfcheck-run" 2>/dev/null)" in
    *"group $_held_pg "*) ok ;;
    *) bad "a worker cancelled between LIVE and its record is still recorded (group ${_held_pg:-?}): $(cat "$FXREC/.selfcheck-run" 2>/dev/null)" ;;
  esac
fi

# --- the negative half lives in `--mutation` --------------------------------------------------
# Each case above is required to come back RED against a dispatcher broken in the one way that
# case exists to catch. That proof runs the WHOLE suite against a mutated copy and reads its exit
# status and its FAIL line, which cannot be done from inside this run — see the `--mutation` block
# near the top, and `selfcheck-guard-mutation` in the registry.

# ============================== 11. NUL bytes survive =========================================
# The runner buffers to a FILE rather than a variable precisely so binary-ish output survives —
# command substitution cannot hold a NUL. That rationale was prose until now; assert it on bytes.
# `sc` cannot be used here for the same reason it is being tested: $OUT is a shell variable.
reset_ctl
cat > "$FX/scripts/check-gates.sh" <<'STUB'
#!/usr/bin/env bash
printf 'nul-before\n'
printf 'A\000B\n'
printf 'nul-after\n'
STUB
chmod +x "$FX/scripts/check-gates.sh"
ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/selfcheck.sh" --only gates --jobs 1 >"$work/nul.out" 2>&1
yes "$?" "the NUL-emitting step passes"
eq "$(LC_ALL=C tr -dc '\000' < "$work/nul.out" | wc -c | tr -d ' ')" "1" \
  "a NUL byte in a step's output reaches the run's output intact (the file buffer, not a variable)"
has "$(LC_ALL=C tr -d '\000' < "$work/nul.out")" "nul-after" "...and output AFTER the NUL is not truncated"

# ============================== 12. --stop (#551) =============================================
# THE ONE SUPPORTED STOP, observed against what a cancelled mutation pool actually leaves. The
# stopped process, the holder working in the checkout beside it, the holder whose pool process exits
# once the TERM lands, the detached worker, and the process that only exists after the TERM are each
# a way a stop can miss a survivor while printing that nothing is left. Each is named by its own
# assertion, so a stop that misses one fails on that one. The unrelated process is the other half:
# it works in the checkout and started during the run, which is exactly what the stop must NOT
# treat as the run's. Then every way the stop could answer clean without having seen: a `ps` that
# fails, a `ps` without the stopper in it, a cwd listing that skips a process, an inspection that
# hangs, a record marked incomplete — and every refusal asserts its OWN reason, since a record
# refused for the wrong one would let a broken rule pass.
#
# The grace is 2s (set at the top). A case that expects survivors passes STOP_SHORT, so it takes
# about 21s; one that expects a clean stop keeps the generous bound and returns as soon as it can.
# STOP_SHORT is not tighter because the after-the-TERM survivor exists only once the stub is
# scheduled to run its trap, which on a machine at load 150 (observed, D135) is not prompt.
FXS="$work/fx-stop"
mkfx "$FXS" || bad "12: could not build the stop fixture"
FXS_P="$(cd -P "$FXS" && pwd -P)"

# stop_sc <fixture> [VAR=value...] — run `--stop` on a fixture: STOP_OUT, STOP_RC and STOP_SECS_TOOK.
stop_sc() {
  local fx="$1" t0; shift
  t0="$BASH_MONOSECONDS"
  STOP_OUT="$(env "$@" bash "$fx/scripts/selfcheck.sh" --stop 2>&1)"; STOP_RC=$?
  STOP_SECS_TOOK=$(( BASH_MONOSECONDS - t0 ))
  return 0
}

# leaked_pid / leaked_pgid <ctl> <kind> — what the leak stub recorded for <kind>, or nothing.
leaked_pid() { awk -v k="$2" '$1 == k { p = $2 } END { print p }' "$1/gates.leaked" 2>/dev/null; }
leaked_pgid() { awk -v k="$2" '$1 == k { p = $3 } END { print p }' "$1/gates.leaked" 2>/dev/null; }

# leaked_alive <ctl> — `kind:pid` for every recorded leak still alive, or nothing.
leaked_alive() {
  local out="" k p
  for k in worker stopped holder rooted anchored nested late; do
    p="$(leaked_pid "$1" "$k")"; [ -n "$p" ] || continue
    [ "$(stub_state "$p" "$(leaked_pgid "$1" "$k")")" = alive ] && out="$out $k:$p"
  done
  printf '%s' "${out# }"
}

# leak_launch <fixture> — start a run of the leak stub and wait until every leak it stages is in
# place and the stopped one IS stopped. STOP_RUNNER is the runner's pid. 1 = it never staged, which
# is its own answer: a stop asked about a run that leaked nothing has proved nothing.
leak_launch() {
  local fx="$1" ctl="$1/ctl" deadline st
  reset_ctl "$fx"
  printf '0\n' > "$ctl/gates.beat"; : > "$ctl/gates.leak"; printf '%s\n' "$work" > "$ctl/gates.poolbase"
  ADB_STUB_CTL="$ctl" bash "$fx/scripts/selfcheck.sh" --only gates --jobs 1 > "$fx/stop-run.out" 2>&1 &
  STOP_RUNNER=$!; STOP_RUNNER_LSTART="$(ps -o lstart= -p "$STOP_RUNNER" 2>/dev/null)"
  deadline=$(( BASH_MONOSECONDS + 60 ))
  while [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do
    if [ -f "$ctl/gates.leakready" ]; then
      st="$(ps -o stat= -p "$(leaked_pid "$ctl" stopped)" 2>/dev/null | tr -d ' ')"
      case "$st" in T*|t*) return 0 ;; esac
    fi
    sleep 0.05
  done
  return 1
}

# plain_launch <fixture> — a run whose one step only heartbeats; STOP_RUNNER. 1 = never enrolled.
plain_launch() {
  local fx="$1" dl
  reset_ctl "$fx"
  printf '0\n' > "$fx/ctl/gates.beat"
  ADB_STUB_CTL="$fx/ctl" bash "$fx/scripts/selfcheck.sh" --only gates --jobs 1 > "$fx/stop-run.out" 2>&1 &
  STOP_RUNNER=$!; STOP_RUNNER_LSTART="$(ps -o lstart= -p "$STOP_RUNNER" 2>/dev/null)"
  dl=$(( BASH_MONOSECONDS + 60 ))
  until [ "$(enrolled_count "$fx/ctl")" -ge 1 ]; do
    [ "$BASH_MONOSECONDS" -lt "$dl" ] || return 1
    sleep 0.05
  done
  return 0
}

# reap_runner — wait for STOP_RUNNER, bounded: a stop that failed to end it must not hang the suite.
# The KILL backstop goes only to the process this suite launched — the same `ps lstart` it had when
# it was launched — never to whatever now holds its number.
reap_runner() {
  local deadline=$(( BASH_MONOSECONDS + 20 ))
  while kill -0 "$STOP_RUNNER" 2>/dev/null && [ "$BASH_MONOSECONDS" -lt "$deadline" ]; do sleep 0.1; done
  if [ -n "${STOP_RUNNER_LSTART:-}" ] && [ "$(ps -o lstart= -p "$STOP_RUNNER" 2>/dev/null)" = "$STOP_RUNNER_LSTART" ]; then
    kill -KILL "$STOP_RUNNER" 2>/dev/null
  fi
  wait "$STOP_RUNNER" 2>/dev/null
  STOP_RUNNER_LSTART=""
  return 0
}

# canary_launch <fixture> [cwd] — a process started now, detached into a group of its own, working
# in the checkout (or <cwd>): the shape of a review dispatched beside the run. CANARY_PID; recorded
# in ctl/canary.leaked for the sweep.
canary_launch() {
  local dir="${2:-$1}"
  ( cd "$dir" || exit; set -m; sleep 300 & printf 'canary %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$1/ctl/canary.leaked" )
  CANARY_PID="$(awk '$1 == "canary" { p = $2 } END { print p }' "$1/ctl/canary.leaked" 2>/dev/null)"
}

# survivor_named <pid> — STOP_OUT names <pid> in a survivor list.
survivor_named() { case "$STOP_OUT" in *"survivor pid=$1 "*) return 0 ;; esac; return 1; }

# --- 12.1 a live run that leaked --------------------------------------------------------------
if leak_launch "$FXS"; then
  _ctl="$FXS/ctl"
  _rec="$(cat "$FXS/.selfcheck-run" 2>/dev/null)"
  has "$_rec" "pid $STOP_RUNNER" "12.1: a live run's record names its runner"
  has "$_rec" "root $FXS_P" "12.1: ...and its checkout, by its physical path"
  has "$_rec" "grace 2" "12.1: ...and the grace it gives its workers"
  _rtmp="$(printf '%s\n' "$_rec" | sed -n 's/^tmp //p')"
  [ -n "$_rtmp" ] && [ -d "$_rtmp" ] && ok || bad "12.1: the record's private temp root [$_rtmp] is not a live directory"
  eq "$(cat "$_ctl/gates.tmpdir" 2>/dev/null)" "$_rtmp" "12.1: every step is handed the run's private temp root as TMPDIR"
  has "$_rec" "pool " "12.1: a pool registered its directory with the run (check_register_pool)"
  canary_launch "$FXS"
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS="$STOP_SHORT"
  reap_runner
  _w="$(leaked_pid "$_ctl" worker)"; _st="$(leaked_pid "$_ctl" stopped)"; _h="$(leaked_pid "$_ctl" holder)"
  _r="$(leaked_pid "$_ctl" rooted)"; _a="$(leaked_pid "$_ctl" anchored)"; _l="$(leaked_pid "$_ctl" late)"
  eq "$STOP_RC" 1 "the stop ends red when survivors outlived its bound ($STOP_OUT)"
  survivor_named "$_w" && ok || bad "12.1: the stop names a detached worker in a registered pool (pid $_w): $STOP_OUT"
  survivor_named "$_r" && ok || bad "12.1: the stop names a survivor working under the run's temp root (pid $_r): $STOP_OUT"
  survivor_named "$_h" && ok || bad "12.1: the stop names a holder in its pool's group (pid $_h): $STOP_OUT"
  survivor_named "$_a" && ok || bad "12.1: the stop still names a holder whose pool process exited during the stop (pid $_a): $STOP_OUT"
  _n="$(leaked_pid "$_ctl" nested)"
  survivor_named "$_n" && ok || bad "12.1: the stop names a nested pool worker that its step's death reparents (pid $_n): $STOP_OUT"
  case "$STOP_OUT" in
    *"survivor pid=$_st "*"(STOPPED)"*) ok ;;
    *) bad "the stop names the STOPPED process, as stopped (pid $_st): $STOP_OUT" ;;
  esac
  [ -n "$_l" ] && ok || bad "12.1: the stub never started its after-the-TERM process — the case did not stage it"
  if [ -n "$_l" ] && survivor_named "$_l" && [ "$(stub_state "$_l" "$(leaked_pgid "$_ctl" late)")" != alive ]; then ok
  else bad "a process started after the stop's TERM is named and removed (pid ${_l:-none}): $STOP_OUT"; fi
  eq "$(leaked_alive "$_ctl")" "" "the stop leaves none of them"
  [ "$(stub_state "$(awk '{print $1}' "$_ctl/gates.pid" 2>/dev/null)" "")" != alive ] && ok \
    || bad "12.1: the run's own step outlived the stop"
  case "$STOP_OUT" in
    *"NOTE — pid=$CANARY_PID "*"NOT signalled: sleep"*) _cn=1 ;;
    *) _cn=0 ;;
  esac
  if [ "$_cn" -eq 1 ] && [ "$(stub_state "$CANARY_PID" "$CANARY_PID")" = alive ]; then ok
  else bad "an unrelated process in the checkout is named and left alone (pid $CANARY_PID): $STOP_OUT"; fi
  hasnt "$STOP_OUT" "sleep 300" "a process is named by its executable, never its arguments"
  # The canary is named as not tied to the run, so the record is KEPT: it may still be the run's own.
  [ -f "$FXS/.selfcheck-run" ] && ok || bad "12.1: a stop that named unattributed processes keeps the record: $STOP_OUT"
else
  bad "12.1: the leak stub never staged its survivors — nothing about the stop was observed"
  reap_runner
fi
reset_ctl "$FXS"

# --- 12.2 the runner is already gone ---------------------------------------------------------
# A runner that was KILLed ran no cleanup at all, so its step is still running in the worker group
# it recorded, with nothing but the record to tie it to the run. The stop sends what the run owns
# in that group the TERM the runner never sent — which is also what starts the after-the-TERM
# survivor — and still sweeps.
#
# THIS IS THE CASE WHERE EACH OWNERSHIP RULE STANDS ALONE, so each survivor's assertion here is the
# one that rule's mutation row must break. With the runner KILLed nothing was recorded at
# cancellation, every leak but the nested worker was reparented at birth, and the TERM the stop
# sends kills the anchor: the worker is reached only by its pool, the rooted one only by the temp
# root, the holder only by its group, the anchored holder only by the stop's memory, the nested
# worker only by descent, and the step only by its recorded group. (In 12.1 the runner's own
# cancellation records most of them too, so there a single rule removed changes nothing.)
#
# Its FIRST table read is held 10s before ps runs, as on a loaded machine: a start dated from before
# that delay would move every process ten seconds, and the anchored holder — which only the stop's
# memory of its start ties to the run — would then fail to be recognised as the same process. (3s
# was not enough: under a full run's load every later read was itself seconds late.)
_slowps="$work/ps-slow-once"; mkdir -p "$_slowps"
printf '#!/bin/sh\ncase " $* " in *" -A "*) if [ -f "$ADB_TEST_SLOW_ONCE" ]; then rm -f "$ADB_TEST_SLOW_ONCE"; sleep 10; fi ;; esac\nexec "%s" "$@"\n' \
  "$(command -v ps)" > "$_slowps/ps"; chmod +x "$_slowps/ps"
if leak_launch "$FXS"; then
  _ctl="$FXS/ctl"
  _gp="$(awk '{print $1}' "$_ctl/gates.pid" 2>/dev/null)"
  _rt="$(sed -n 's/^tmp //p' "$FXS/.selfcheck-run" 2>/dev/null)"
  kill -KILL "$STOP_RUNNER" 2>/dev/null; wait "$STOP_RUNNER" 2>/dev/null
  : > "$work/slow-once.flag"
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS="$STOP_SHORT" PATH="$_slowps:$PATH" ADB_TEST_SLOW_ONCE="$work/slow-once.flag"
  has "$STOP_OUT" "has already exited" "12.2: the stop says the run had already exited"
  eq "$STOP_RC" 1 "12.2: the leftovers of a KILLed run still end the stop red"
  _w="$(leaked_pid "$_ctl" worker)"; _r="$(leaked_pid "$_ctl" rooted)"; _h="$(leaked_pid "$_ctl" holder)"
  _a="$(leaked_pid "$_ctl" anchored)"; _n="$(leaked_pid "$_ctl" nested)"
  survivor_named "$_w" && ok || bad "after the runner is KILLed, the stop names a detached worker in a registered pool (pid $_w): $STOP_OUT"
  survivor_named "$_r" && ok || bad "after the runner is KILLed, the stop names a survivor working under the run's temp root (pid $_r): $STOP_OUT"
  survivor_named "$_h" && ok || bad "after the runner is KILLed, the stop names a holder in its pool's group (pid $_h): $STOP_OUT"
  survivor_named "$_a" && ok || bad "after the runner is KILLed, the stop still names a holder whose pool process exited during the stop (pid $_a): $STOP_OUT"
  survivor_named "$_n" && ok || bad "after the runner is KILLed, the stop names a nested worker its step's death reparents (pid $_n): $STOP_OUT"
  [ -n "$_gp" ] && [ "$(stub_state "$_gp" "")" != alive ] && ok \
    || bad "after the runner is KILLed, the stop still stops the step it recorded (pid ${_gp:-none}): $STOP_OUT"
  [ -n "$(leaked_pid "$_ctl" late)" ] && ok \
    || bad "after the runner is KILLed, the stop sends the step it recorded a TERM, and its cleanup runs: $STOP_OUT"
  eq "$(leaked_alive "$_ctl")" "" "12.2: nothing the KILLed run left survives the stop"
  # Nothing a record names is ever deleted: a path read from a file is not proof of what it resolves
  # to. The KILLed runner's temp root is left to the system's temp cleaner (here, to this suite).
  [ -n "$_rt" ] && [ -d "$_rt" ] && ok \
    || bad "the stop deletes nothing the record names, not even the run's temp root (${_rt:-no tmp in the record}): $STOP_OUT"
  [ -z "$_rt" ] || rm -rf "$_rt"
else
  bad "12.2: the leak stub never staged its survivors"
  reap_runner
fi
reset_ctl "$FXS"

# --- 12.2b the run was cancelled with a plain TERM, and stopped only later -------------------------
# A ^C reaches the runner alone. Its `_cleanup` must record the groups among its descendants BEFORE
# it signals anything — the nested worker's included — because once the step dies that worker is
# reparented and working in the checkout, and nothing else could tie it to the run.
if leak_launch "$FXS"; then
  _ctl="$FXS/ctl"
  kill -TERM "$STOP_RUNNER" 2>/dev/null
  reap_runner
  _n="$(leaked_pid "$_ctl" nested)"
  [ "$(stub_state "$_n" "$_n")" = alive ] && ok || bad "12.2b: the nested worker did not outlive the plain TERM — the case did not stage it"
  # Marked incomplete, as a run that could not record everything is: the stop still removes what it
  # found, but must KEEP the record, since what it could not see may still be running.
  : > "$FXS/.selfcheck-run.incomplete"
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS="$STOP_SHORT"
  eq "$STOP_RC" 1 "12.2b: what a cancelled run left still ends a later stop red: $STOP_OUT"
  [ -f "$FXS/.selfcheck-run" ] && [ -f "$FXS/.selfcheck-run.incomplete" ] && ok \
    || bad "an incomplete record survives a stop that found and removed survivors: $STOP_OUT"
  # Found, and so reached: the stop sends a recorded group the TERM the runner's cleanup did not, so a
  # polite worker ends inside the bound rather than being named. Unrecorded, nothing would reach it.
  [ "$(stub_state "$_n" "$_n")" != alive ] && ok \
    || bad "a nested group the run recorded as it was cancelled is still found by a later stop (pid $_n): $STOP_OUT"
  eq "$(leaked_alive "$_ctl")" "" "12.2b: nothing the cancelled run left survives the later stop"
else
  bad "12.2b: the leak stub never staged its survivors"
  reap_runner
fi
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run" "$FXS/.selfcheck-run.incomplete"

# --- 12.2d a worker born in cleanup, that nothing ties to the run -------------------------------
# The step's TERM trap starts one more process in a group of its own, working in the checkout, and
# exits at once — after the runner's cancel-time recording, before any listing sees its parent. No
# rule can attribute it, and the stop must not pretend it saw nothing: it names it, never signals
# it, and answers 6 — not clean — keeping the record.
reset_ctl "$FXS"
printf '0\n' > "$FXS/ctl/gates.beat"; : > "$FXS/ctl/gates.trapspawn"
ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 > "$FXS/stop-run.out" 2>&1 &
STOP_RUNNER=$!; STOP_RUNNER_LSTART="$(ps -o lstart= -p "$STOP_RUNNER" 2>/dev/null)"
_dl=$(( BASH_MONOSECONDS + 60 ))
until [ "$(enrolled_count "$FXS/ctl")" -ge 1 ] || [ "$BASH_MONOSECONDS" -ge "$_dl" ]; do sleep 0.05; done
kill -TERM "$STOP_RUNNER" 2>/dev/null
reap_runner
_sp="$(awk '$1 == "spawned" { print $2 }' "$FXS/ctl/gates.leaked" 2>/dev/null)"
if [ -n "$_sp" ]; then
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS="$STOP_SHORT"
  eq "$STOP_RC" 6 "a stop that leaves an unattributed process from the run's checkout is never clean (exit 6): $STOP_OUT"
  has "$STOP_OUT" "NOTE — pid=$_sp " "12.2d: ...and names it"
  [ "$(stub_state "$_sp" "$_sp")" = alive ] && ok || bad "12.2d: the unattributed process was signalled"
  [ -f "$FXS/.selfcheck-run" ] && ok || bad "12.2d: a not-clean stop removed the record"
else
  bad "12.2d: the step never started its cleanup-born process — the case did not stage"
fi
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run" "$FXS/.selfcheck-run.incomplete"

# --- 12.2c a cancelled run whose own listing is not whole marks its record ---------------------
# The runner's cancel-time recording reads where its processes work through the stop's own listing,
# and holds it to the same rule: a process of this user, started during the run, whose directory it
# could not read leaves the record incomplete — since that may be the one process tying a holder to
# the run. The listing is made to skip the nested worker once it exists.
_cst="$work/cancel-stubs"; rm -rf "$_cst"; mkdir -p "$_cst"
_lsof_real="$(command -v lsof || printf /usr/sbin/lsof)"; _find_real="$(command -v find)"
cat > "$_cst/lsof" <<STUB
#!/usr/bin/env bash
d="\$(cat "\$ADB_TEST_DROP_FILE" 2>/dev/null)"
"$_lsof_real" "\$@" | awk -v d="p\$d" '/^p/ { skip = (\$0 == d) } !skip'
STUB
cat > "$_cst/find" <<STUB
#!/usr/bin/env bash
d="\$(cat "\$ADB_TEST_DROP_FILE" 2>/dev/null)"
"$_find_real" "\$@" | while IFS= read -r -d '' r; do case "\$r" in "/proc/\$d"\$'\t'*) ;; *) printf '%s\0' "\$r" ;; esac; done
STUB
chmod +x "$_cst/lsof" "$_cst/find"
: > "$work/drop-pid"
if PATH="$_cst:$PATH" ADB_TEST_DROP_FILE="$work/drop-pid" leak_launch "$FXS"; then
  _ctl="$FXS/ctl"
  leaked_pid "$_ctl" nested > "$work/drop-pid"
  kill -TERM "$STOP_RUNNER" 2>/dev/null
  reap_runner
  [ -f "$FXS/.selfcheck-run.incomplete" ] && ok \
    || bad "a cancelled run whose working-directory listing skips one of its processes marks its record incomplete"
else
  bad "12.2c: the leak stub never staged its survivors"
  reap_runner
fi
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run" "$FXS/.selfcheck-run.incomplete"

# --- 12.3 a clean stop whose own bound is shorter than the run's grace ----------------------------
# The step takes 4s to clean up after its TERM, inside the run's 12s grace. The stopper's environment
# says 2s — a stop started from another shell carries its own — and must still wait out the run's
# recorded prep and grace, so the cleanup FINISHES; KILLing at 2s would cut it off.
reset_ctl "$FXS"
printf '0\n' > "$FXS/ctl/gates.beat"; printf '4\n' > "$FXS/ctl/gates.slowexit"
ADB_SELFCHECK_STOP_GRACE_SECS=12 ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 \
  > "$FXS/stop-run.out" 2>&1 &
STOP_RUNNER=$!; STOP_RUNNER_LSTART="$(ps -o lstart= -p "$STOP_RUNNER" 2>/dev/null)"
_dl=$(( BASH_MONOSECONDS + 60 ))
until [ "$(enrolled_count "$FXS/ctl")" -ge 1 ] || [ "$BASH_MONOSECONDS" -ge "$_dl" ]; do sleep 0.05; done
if [ "$(enrolled_count "$FXS/ctl")" -ge 1 ]; then
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS=2
  reap_runner
  [ -f "$FXS/ctl/gates.cleaned" ] && ok \
    || bad "a stop never KILLs into a cleanup still inside the run's own grace: $STOP_OUT"
  eq "$STOP_RC" 0 "12.3: a run that leaves nothing behind stops clean (exit 0): $STOP_OUT"
  has "$STOP_OUT" "stopped clean" "12.3: ...and says so"
  has "$STOP_OUT" "the bound is 29s" "12.3: the bound is the run's prep (12s) + its grace (12s) + the margin (5s)"
  [ -z "$(enrolled_alive "$FXS/ctl")" ] && ok || bad "12.3: the run's step outlived a clean stop"
  [ ! -e "$FXS/.selfcheck-run" ] && ok || bad "12.3: a clean stop removes the run's record"
else
  bad "12.3: the slow-cleanup run never enrolled"; reap_runner
fi

# --- 12.4 an incomplete record is never clean --------------------------------------------------
if plain_launch "$FXS"; then
  : > "$FXS/.selfcheck-run.incomplete"
  stop_sc "$FXS"
  reap_runner
  eq "$STOP_RC" 4 "a stop over an incomplete record never answers clean: $STOP_OUT"
  has "$STOP_OUT" "could not be recorded" "12.4: ...and says why"
else
  bad "12.4: the plain run never enrolled"; reap_runner
fi
rm -f "$FXS/.selfcheck-run" "$FXS/.selfcheck-run.incomplete"
# …and a pool that cannot be registered is what marks it: a control byte in its path is refused
# before anything could strip it, the record is marked, and the diagnostic carries no raw control byte.
_pr="$work/pool-reg"; mkdir -p "$_pr"; printf 'adb-selfcheck-run 1\n' > "$_pr/rec"
_pr_out="$( ( . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/check-lib.sh"; ADB_SELFCHECK_RECORD="$_pr/rec" check_register_pool "$_pr/bad"$'\n'"FAIL: forged" ) 2>&1)"
[ -f "$_pr/rec.incomplete" ] && ok || bad "a refused pool registration marks the record incomplete"
case "$_pr_out" in *$'\n'"FAIL: forged"*) bad "12.4: a refused pool path forged a line into the log: $_pr_out" ;; *) ok ;; esac
_pr_out="$( ( . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/check-lib.sh"; ADB_SELFCHECK_RECORD="$_pr/rec" check_register_pool "$_pr/good" ) 2>&1)"
has "$(cat "$_pr/rec")" "pool $(cd -P "$_pr" && pwd -P)/good" "12.4: a good pool path is registered, physically"
# `/`, a `^`, and a record that has gone are each a failure that marks the record, never a no-op.
for _bad_pool in "/" "$_pr/x^Ay"; do
  rm -f "$_pr/rec.incomplete"
  ( . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/check-lib.sh"; ADB_SELFCHECK_RECORD="$_pr/rec" check_register_pool "$_bad_pool" ) >/dev/null 2>&1
  [ -f "$_pr/rec.incomplete" ] && ok || bad "12.4: registering [$_bad_pool] is refused, and marks the record incomplete"
done
eq "$(grep -c '^pool ' "$_pr/rec")" 1 "12.4: neither / nor a ^ path was registered — only the good pool is"
rm -f "$_pr/gone.incomplete"
( . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/check-lib.sh"; ADB_SELFCHECK_RECORD="$_pr/gone" check_register_pool "$_pr/good" ) >/dev/null 2>&1
[ -f "$_pr/gone.incomplete" ] && ok || bad "a pool registered after the run record is gone marks it incomplete, never reads as outside selfcheck"
# …and a registration goes through the record's ONE locked writer: while another writer holds the
# lock, it does not slip a line in beside it — it waits, and failing that marks the record.
rm -f "$_pr/rec.incomplete"; mkdir "$_pr/rec.lock" && : > "$_pr/rec.lock/.adb-excl"
( . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/check-lib.sh"; ADB_SELFCHECK_RECORD="$_pr/rec" check_register_pool "$_pr/locked" ) >/dev/null 2>&1
if [ -f "$_pr/rec.incomplete" ] && ! grep -q '/locked$' "$_pr/rec"; then ok
else bad "a pool registration never writes past the record's lock, and marks the record when it cannot take it"; fi
rm -rf "$_pr/rec.lock"

# --- 12.5 nothing recorded, and records that do not validate ----------------------------------
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run"
stop_sc "$FXS"
eq "$STOP_RC" 5 "12.5: with no run recorded the stop says so (exit 5), and is never a clean stop"
# A canary is named as the runner in records that must be refused WHOLE — each for its OWN reason —
# and nothing may be signalled.
canary_launch "$FXS" "$work"
_cp="$CANARY_PID"
_good="adb-selfcheck-run 1
pid $_cp
epoch $EPOCHSECONDS
grace 2
prep 15
root $FXS_P
tmp $work/no-such-root"
_bad_rec() {   # <label> <reason the stop must give> <record bytes, written verbatim>
  printf '%s' "$3" > "$FXS/.selfcheck-run"
  stop_sc "$FXS"
  eq "$STOP_RC" 4 "12.5: a record that $1 is refused (exit 4): $STOP_OUT"
  has "$STOP_OUT" "$2" "12.5: a record that $1 is refused"
}
_nl=$'\n'
_bad_rec "carries an unknown key" "has a key no run record carries" "$_good${_nl}bogus 1$_nl"
_bad_rec "names its pid twice" "names its pid twice" "$_good${_nl}pid 1$_nl"
_bad_rec "has no final newline" "is not whole" "$_good"
_bad_rec "has no grace" "has no grace" "${_good/grace 2$_nl/}$_nl"
_bad_rec "names another checkout" "not this checkout" "${_good/root $FXS_P/root /nonexistent}$_nl"
_bad_rec "registers a pool holding the checkout" "registers a pool" "$_good${_nl}pool $(dirname "$FXS_P")$_nl"
_bad_rec "has a malformed group line" "is not 'group <pgid> <epoch>'" "$_good${_nl}group 12x 1$_nl"
_bad_rec "has no prep" "has no prep" "${_good/prep 15$_nl/}$_nl"
_bad_rec "has a grace no runner could write" "grace is not a number the runner could write" "${_good/grace 2/grace 9999999999}$_nl"
_bad_rec "registers a pool whose name holds a ^" "free of control bytes and ^" "$_good${_nl}pool $work/x^Ay$_nl"
[ "$(stub_state "$_cp" "$_cp")" = alive ] && ok || bad "12.5: a refused record signalled the process it named"

# --- 12.6 it cannot see the whole process table ------------------------------------------------
# Inside an agent's sandbox `ps` is refused outright. A stop that read that, or any partial table, as
# "nothing there" would print the clean verdict over every survivor there is. The record is VALID in
# every case below, and names the canary as its runner: nothing may reach it.
printf '%s\n' "$_good" > "$FXS/.selfcheck-run"
_sb="$work/stop-stubs"; rm -rf "$_sb"; mkdir -p "$_sb/psfail" "$_sb/psnoself" "$_sb/pshang" "$_sb/cwdfail" "$_sb/cwdpart"
_ps_real="$(command -v ps)"; _find_real="$(command -v find)"
_lsof_real="$(command -v lsof || printf /usr/sbin/lsof)"
printf '#!/bin/sh\n"%s" "$@"\necho "ps: operation not permitted" >&2\nexit 1\n' "$_ps_real" > "$_sb/psfail/ps"
printf '#!/bin/sh\nexit 0\n' > "$_sb/psnoself/ps"
printf '#!/bin/sh\nexec sleep 60\n' > "$_sb/pshang/ps"
printf '#!/bin/sh\nexit 1\n' > "$_sb/cwdfail/lsof"; cp "$_sb/cwdfail/lsof" "$_sb/cwdfail/find"
mkdir -p "$_sb/psdrop"
cat > "$_sb/psdrop/ps" <<STUB
#!/usr/bin/env bash
case " \$* " in *" -A "*) "$_ps_real" "\$@" | awk -v d="\$ADB_TEST_DROP" '\$1 != d'; exit "\${PIPESTATUS[0]}" ;; esac
exec "$_ps_real" "\$@"
STUB
# The partial listings drop ONE process — a second canary, started during the "run" — and keep the rest.
cat > "$_sb/cwdpart/lsof" <<STUB
#!/usr/bin/env bash
"$_lsof_real" "\$@" | awk -v d="p\$ADB_TEST_DROP" '/^p/ { skip = (\$0 == d) } !skip'
STUB
cat > "$_sb/cwdpart/find" <<STUB
#!/usr/bin/env bash
"$_find_real" "\$@" | while IFS= read -r -d '' r; do case "\$r" in "/proc/\$ADB_TEST_DROP"\$'\t'*) ;; *) printf '%s\0' "\$r" ;; esac; done
STUB
chmod +x "$_sb"/*/*
stop_sc "$FXS" PATH="$_sb/psfail:$PATH"
eq "$STOP_RC" 4 "a stop whose ps fails answers 4 even when ps printed a listing: $STOP_OUT"
has "$STOP_OUT" "ps could not list processes" "a stop whose ps fails says so, even when ps printed a listing"
stop_sc "$FXS" PATH="$_sb/psnoself:$PATH"
eq "$STOP_RC" 4 "a stop whose ps lists without it answers 4, never clean: $STOP_OUT"
stop_sc "$FXS" PATH="$_sb/pshang:$PATH" ADB_SELFCHECK_STOP_INSPECT_SECS=2
eq "$STOP_RC" 4 "12.6: a stop whose ps hangs answers 4: $STOP_OUT"
# A 2s bound against a 60s hang: under 30s is the bound working, with room for a loaded machine.
[ "$STOP_SECS_TOOK" -lt 30 ] && ok || bad "a stop whose inspection hangs answers 4 within its inspection bound (took ${STOP_SECS_TOOK}s)"
stop_sc "$FXS" PATH="$_sb/cwdfail:$PATH"
eq "$STOP_RC" 4 "12.6: a stop that cannot read working directories at all answers 4: $STOP_OUT"
canary_launch "$FXS" "$work"
stop_sc "$FXS" PATH="$_sb/cwdpart:$PATH" ADB_TEST_DROP="$CANARY_PID"
eq "$STOP_RC" 4 "a stop that cannot read the working directory of a process started during the run answers 4: $STOP_OUT"
has "$STOP_OUT" "pid $CANARY_PID" "12.6: ...and names that process"
# …and when the re-check of that process's state cannot be read either, that is still no answer:
# only a state ps READ, or the kernel's own ESRCH, may excuse a directory the listing did not give.
mkdir -p "$_sb/statfail"
printf '#!/bin/sh\ncase " $* " in *" stat= "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$_ps_real" > "$_sb/statfail/ps"
chmod +x "$_sb/statfail/ps"
stop_sc "$FXS" PATH="$_sb/statfail:$_sb/cwdpart:$PATH" ADB_TEST_DROP="$CANARY_PID"
eq "$STOP_RC" 4 "a stop whose recheck of a missing directory cannot be read answers 4: $STOP_OUT"
# …and the other way round: ps drops a process that the cwd listing shows, and that was running
# before ps ran. It could be a detached worker nothing else would surface; the listing is refused.
stop_sc "$FXS" PATH="$_sb/psdrop:$PATH" ADB_TEST_DROP="$CANARY_PID"
eq "$STOP_RC" 4 "a stop whose ps omits a process the cwd listing shows answers 4: $STOP_OUT"
[ "$(stub_state "$_cp" "$_cp")" = alive ] && ok || bad "12.6: a stop that could not inspect signalled the process its record named"
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run"

# --- 12.7 a second run in the same checkout keeps its hands off the first one's record ----------
# The turn-end gate runs a short `--only` selfcheck in the checkout a long run may be using. It must
# neither replace the long run's record nor remove it on the way out, or the long run is left with
# nothing for `--stop` to find.
if plain_launch "$FXS"; then
  OUT="$(ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only claims --jobs 1 2>&1)"; RC_=$?
  yes "$RC_" "12.7: a second, short run in the same checkout still runs and passes"
  has "$OUT" "another run (pid $STOP_RUNNER) is recorded" "12.7: ...and says it is not recorded, naming the run that is"
  has "$(sed -n 2p "$FXS/.selfcheck-run" 2>/dev/null)" "pid $STOP_RUNNER" \
    "a second run in the checkout leaves the first run's record in place"
  stop_sc "$FXS"
  reap_runner
  eq "$STOP_RC" 0 "12.7: the first run is still found, and stopped clean: $STOP_OUT"
else
  bad "12.7: the plain run never enrolled"; reap_runner
fi

# --- 12.9 the runner's caller is never the run's ------------------------------------------------
# Started without job control, a runner is in its CALLER's process group: the shell or agent that
# launched it. A process the run does own can sit in that group too — here one working under the
# run's temp root — and that must never make the group, and so the caller, the run's. The caller
# is a job of its own here, so the stopper's shield does not cover it: only the rule does.
reset_ctl "$FXS"
printf '0\n' > "$FXS/ctl/gates.beat"
( set -m
  { ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 > "$FXS/stop-run.out" 2>&1 &
    printf '%s\n' "$!" > "$FXS/ctl/caller.runner"
    _dl=$(( BASH_MONOSECONDS + 60 ))
    until grep -q '^tmp ' "$FXS/.selfcheck-run" 2>/dev/null || [ "$BASH_MONOSECONDS" -ge "$_dl" ]; do sleep 0.05; done
    _t="$(sed -n 's/^tmp //p' "$FXS/.selfcheck-run" 2>/dev/null)"
    ( cd "$_t" 2>/dev/null && exec sleep 300 ) & printf 'inside %s %s %s\n' "$!" "$BASHPID" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked"
    sleep 300 & printf 'bystander %s %s %s\n' "$!" "$BASHPID" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked"
    wait
  } &
  printf 'caller %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked" )
_dl=$(( BASH_MONOSECONDS + 60 ))
until [ "$(grep -c '' "$FXS/ctl/canary.leaked" 2>/dev/null)" -ge 3 ] && [ "$(enrolled_count "$FXS/ctl")" -ge 1 ]; do
  [ "$BASH_MONOSECONDS" -lt "$_dl" ] || break
  sleep 0.05
done
_cl="$(awk '$1 == "caller" { print $2 }' "$FXS/ctl/canary.leaked")"
_by="$(awk '$1 == "bystander" { print $2 }' "$FXS/ctl/canary.leaked")"
_in="$(awk '$1 == "inside" { print $2 }' "$FXS/ctl/canary.leaked")"
if [ -n "$_cl" ] && [ -n "$_by" ] && [ -n "$_in" ]; then
  STOP_RUNNER="$(cat "$FXS/ctl/caller.runner" 2>/dev/null)"; STOP_RUNNER_LSTART=""
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS="$STOP_SHORT"
  survivor_named "$_in" && ok || bad "12.9: the process working under the run's temp root is still the run's (pid $_in): $STOP_OUT"
  if [ "$(stub_state "$_cl" "$_cl")" = alive ] && [ "$(stub_state "$_by" "$_cl")" = alive ]; then ok
  else bad "the runner's caller, and anything else in its group, is never treated as the run's (caller $_cl, bystander $_by): $STOP_OUT"; fi
else
  bad "12.9: the caller's group never staged (caller ${_cl:-?}, bystander ${_by:-?}, inside ${_in:-?})"
fi
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run" "$FXS/.selfcheck-run.incomplete"

# --- 12.10 ps leaves out the live runner -----------------------------------------------------------
# A listing that silently omits a process proves nothing about that process. The runner is ALIVE
# here and ps is made to drop its line: the stop must not read that as "the run has exited" — which
# would skip its TERM, call a live run clean and remove its record — but refuse.
if plain_launch "$FXS"; then
  stop_sc "$FXS" PATH="$_sb/psdrop:$PATH" ADB_TEST_DROP="$STOP_RUNNER"
  eq "$STOP_RC" 4 "a stop whose ps omits a process it depends on answers 4, never reads it as gone: $STOP_OUT"
  [ -f "$FXS/.selfcheck-run" ] && ok || bad "12.10: a stop that could not trust its listing removed the run's record"
  stop_sc "$FXS"
  reap_runner
  eq "$STOP_RC" 0 "12.10: with a whole listing the same run then stops clean: $STOP_OUT"
else
  bad "12.10: the plain run never enrolled"; reap_runner
fi

# --- 12.11 a stale record cannot claim a reused group ------------------------------------------
# A record two hours old names a group whose number has since been taken by a NEW group, whose own
# leader has already exited, leaving one member working in the checkout. With the leader gone the
# group's continuity cannot be shown by its leader, and the member started long after the run was
# last heard from (the record's last write, an hour ago here): it is not the run's — named, never
# signalled, and the stop is not clean.
reset_ctl "$FXS"
( cd "$FXS" || exit; set -m; { sleep 300 & printf 'reused %s %s %s\n' "$!" "$BASHPID" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked"; exit 0; } & wait )
_ru="$(awk '$1 == "reused" { print $2 }' "$FXS/ctl/canary.leaked")"
_rg="$(awk '$1 == "reused" { print $3 }' "$FXS/ctl/canary.leaked")"
sleep 0 & _deadp=$!; wait "$_deadp"
_then=$(( EPOCHSECONDS - 7200 ))
printf 'adb-selfcheck-run 1\npid %s\nepoch %s\ngrace 2\nprep 15\nroot %s\ntmp %s\ngroup %s %s\n' \
  "$_deadp" "$_then" "$FXS_P" "$work/no-such-root" "$_rg" "$_then" > "$FXS/.selfcheck-run"
perl -e 'my $t = time - 3600; utime($t, $t, $ARGV[0]) or exit 1' "$FXS/.selfcheck-run" \
  || bad "12.11: could not age the record (perl utime)"
if [ -n "$_ru" ] && [ "$(stub_state "$_ru" "$_rg")" = alive ]; then
  stop_sc "$FXS"
  [ "$(stub_state "$_ru" "$_rg")" = alive ] && ok \
    || bad "a recorded group whose leader is gone cannot claim a process started after the run was last heard from: $STOP_OUT"
  eq "$STOP_RC" 6 "12.11: ...it is named as unattributed, and the stop is not clean: $STOP_OUT"
else
  bad "12.11: the reused group never staged"
fi
reset_ctl "$FXS"
rm -f "$FXS/.selfcheck-run"

# --- 12.12 Linux: a cwd whose ` (deleted)` cannot be told from its real name -----------------------
# The kernel appends ` (deleted)` to a removed directory. If a directory really named that way also
# exists, the two cannot be told apart, and either guess could hide a survivor: refused. macOS's lsof
# names a removed directory by its last path, with no suffix, so there is nothing to tell apart.
if [ -e "/proc/$$/cwd" ]; then
  reset_ctl "$FXS"
  _dd="$work/gone-dir"; mkdir -p "$_dd"
  ( cd "$_dd" || exit; set -m; sleep 300 & printf 'indeleted %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked" )
  rm -rf "$_dd"; mkdir -p "$_dd (deleted)"
  sleep 0 & _deadp=$!; wait "$_deadp"
  printf 'adb-selfcheck-run 1\npid %s\nepoch %s\ngrace 2\nprep 15\nroot %s\ntmp %s\n' \
    "$_deadp" "$EPOCHSECONDS" "$FXS_P" "$work/no-such-root" > "$FXS/.selfcheck-run"
  stop_sc "$FXS"
  eq "$STOP_RC" 4 "a cwd whose ' (deleted)' suffix cannot be told from a real name is refused: $STOP_OUT"
  reset_ctl "$FXS"; rm -rf "$_dd (deleted)" "$FXS/.selfcheck-run"
else
  ok   # macOS: lsof reports a removed directory by its last path; no suffix to disambiguate
fi

# --- 12.13 no caller group known: no group spreads ownership ----------------------------------------
# A runner that could not read its own group (a sandbox refuses ps) writes no `pgid`; once it has
# exited, any group might be its caller's. Here a process under the run's temp root shares a group
# with a bystander and the group's leader: the process is the run's, but neither of the others may
# be made so by the group alone.
reset_ctl "$FXS"
_t13="$work/t13"; mkdir -p "$_t13"
( cd "$FXS" || exit; set -m
  { ( cd "$_t13" && exec sleep 300 ) & printf 'owned13 %s %s %s\n' "$!" "$BASHPID" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked"
    sleep 300 & printf 'bystander13 %s %s %s\n' "$!" "$BASHPID" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked"
    wait; } &
  printf 'leader13 %s %s %s\n' "$!" "$!" "$(ps -o lstart= -p "$!")" >> "$FXS/ctl/canary.leaked" )
_dl=$(( BASH_MONOSECONDS + 30 ))
until [ "$(grep -c '' "$FXS/ctl/canary.leaked" 2>/dev/null)" -ge 3 ] || [ "$BASH_MONOSECONDS" -ge "$_dl" ]; do sleep 0.05; done
_o13="$(awk '$1 == "owned13" { print $2 }' "$FXS/ctl/canary.leaked")"
_b13="$(awk '$1 == "bystander13" { print $2 }' "$FXS/ctl/canary.leaked")"
_l13="$(awk '$1 == "leader13" { print $2 }' "$FXS/ctl/canary.leaked")"
sleep 0 & _deadp=$!; wait "$_deadp"
printf 'adb-selfcheck-run 1\npid %s\nepoch %s\ngrace 1\nprep 1\nroot %s\ntmp %s\n' \
  "$_deadp" "$(( EPOCHSECONDS - 10 ))" "$FXS_P" "$(cd -P "$_t13" && pwd -P)" > "$FXS/.selfcheck-run"
if [ -n "$_o13" ] && [ -n "$_b13" ] && [ -n "$_l13" ]; then
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS=8
  survivor_named "$_o13" && ok || bad "12.13: the process under the run's temp root is still the run's (pid $_o13): $STOP_OUT"
  if [ "$(stub_state "$_b13" "$_l13")" = alive ] && [ "$(stub_state "$_l13" "$_l13")" = alive ]; then ok
  else bad "with no caller group known, no group spreads ownership to a bystander (bystander $_b13, leader $_l13): $STOP_OUT"; fi
else
  bad "12.13: the shared group never staged"
fi
reset_ctl "$FXS"; rm -f "$FXS/.selfcheck-run"

# --- 12.14 a target the stop cannot re-verify is never signalled ------------------------------------
# Every signal re-reads its targets first. When that read FAILS — even after printing rows — or shows a
# process that is no longer the one the inventory dated, nothing is signalled: the survivor is named,
# left alone, and the stop says it could not be removed (3).
_t14="$work/t14"; mkdir -p "$_t14"
mkdir -p "$_sb/verifyfail" "$_sb/verifylie"
printf '#!/bin/sh\ncase "$*" in *pid=,pgid=,etime=*) "%s" "$@"; exit 1 ;; esac\nexec "%s" "$@"\n' \
  "$_ps_real" "$_ps_real" > "$_sb/verifyfail/ps"
printf '#!/bin/sh\ncase "$*" in *pid=,pgid=,etime=*) "%s" "$@" | awk '"'"'{ $3 = "99-00:00:00"; print }'"'"'; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$_ps_real" "$_ps_real" > "$_sb/verifylie/ps"
chmod +x "$_sb/verifyfail/ps" "$_sb/verifylie/ps"
for _vk in verifyfail verifylie; do
  reset_ctl "$FXS"
  canary_launch "$FXS" "$_t14"
  sleep 0 & _deadp=$!; wait "$_deadp"
  printf 'adb-selfcheck-run 1\npid %s\nepoch %s\ngrace 1\nprep 1\nroot %s\ntmp %s\npgid %s\n' \
    "$_deadp" "$(( EPOCHSECONDS - 10 ))" "$FXS_P" "$(cd -P "$_t14" && pwd -P)" "$_deadp" > "$FXS/.selfcheck-run"
  stop_sc "$FXS" ADB_SELFCHECK_STOP_SECS=8 PATH="$_sb/$_vk:$PATH"
  if [ "$_vk" = verifyfail ]; then _vw="a target the stop could not re-verify is never signalled"
  else _vw="a target whose identity no longer matches is never signalled"; fi
  if [ "$(stub_state "$CANARY_PID" "$CANARY_PID")" = alive ] && [ "$STOP_RC" -eq 3 ]; then ok
  else bad "$_vw (rc $STOP_RC): $STOP_OUT"; fi
done
reset_ctl "$FXS"; rm -f "$FXS/.selfcheck-run"

# --- 12.8 the knobs, the mode, and the record's own name --------------------------------------
_k_out="$(ADB_SELFCHECK_STOP_GRACE_SECS=soon bash "$FXS/scripts/selfcheck.sh" --stop 2>&1)"; _k_rc=$?
eq "$_k_rc" 2 "12.8: a grace that is not a number is refused: $_k_out"
_k_out="$(ADB_SELFCHECK_STOP_INSPECT_SECS=0 bash "$FXS/scripts/selfcheck.sh" --stop 2>&1)"; _k_rc=$?
eq "$_k_rc" 2 "12.8: an inspection bound that is not a positive number is refused: $_k_out"
_k_out="$(bash "$FXS/scripts/selfcheck.sh" --stop --list 2>&1)"; _k_rc=$?
eq "$_k_rc" 2 "12.8: --stop composes with no other terminal mode: $_k_out"
# A run that ends on its own leaves no record behind: only a cancelled one keeps it for the stop.
reset_ctl "$FXS"
OUT="$(ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 2>&1)"; RC_=$?
yes "$RC_" "12.8: a plain run of the stop fixture passes"
[ ! -e "$FXS/.selfcheck-run" ] && ok || bad "12.8: a run that ended on its own left its record behind"
# A DIRECTORY where the record goes is refused, and the run says it is not recorded.
mkdir -p "$FXS/.selfcheck-run"
OUT="$(ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 2>&1)"; RC_=$?
yes "$RC_" "12.8: a run with a directory where its record goes still passes"
has "$OUT" "no run record" "a directory at the record's name is refused, never published into"
[ -z "$(ls -A "$FXS/.selfcheck-run" 2>/dev/null)" ] && ok || bad "12.8: the run published its record INTO the directory at its name"
rm -rf "$FXS/.selfcheck-run"
# …and an existing record that cannot be read names a run nobody can show has exited: it is never
# replaced, and the run says so.
printf 'adb-selfcheck-run 1\npid 12345\n' > "$FXS/.selfcheck-run"; chmod 000 "$FXS/.selfcheck-run"
OUT="$(ADB_STUB_CTL="$FXS/ctl" bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 2>&1)"; RC_=$?
chmod 600 "$FXS/.selfcheck-run"
yes "$RC_" "12.8: a run beside an unreadable record still passes"
has "$OUT" "could not be read" "an existing record that cannot be read is never replaced"
has "$(cat "$FXS/.selfcheck-run")" "pid 12345" "12.8: ...and is still the record that was there"
rm -f "$FXS/.selfcheck-run"
# …and a FIFO there must not be OPENED: reading one blocks until something writes it, so the run
# would never start. Bounded, so a regression is a red here rather than a hung suite.
mkfifo "$FXS/.selfcheck-run"
OUT="$(ADB_STUB_CTL="$FXS/ctl" adb_run_bounded 60 1 bash "$FXS/scripts/selfcheck.sh" --only gates --jobs 1 2>&1)"; RC_=$?
eq "$RC_" 0 "a FIFO at the record's name is refused without being opened, and the run goes on (rc 124 = it hung)"
has "$OUT" "no run record" "12.8: ...and the run says it is not recorded"
rm -f "$FXS/.selfcheck-run"

check_summary "check-selfcheck"
