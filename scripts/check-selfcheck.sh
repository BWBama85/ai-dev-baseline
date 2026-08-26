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
#      reaping is broken in the one way that case exists to catch.
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

work="$(mktemp -d)" || { echo "check-selfcheck: cannot create a scratch dir" >&2; exit 1; }

# cancel_sweep — ask every fixture's stubs to leave, and wait briefly for them to. Runs from the
# EXIT trap BEFORE `$work` is removed, because removing it first is what makes the leak: the stubs
# shut down cooperatively through `$ctl/STOP`, and deleting the directory takes that away while
# they tick out the rest of their 180s backstop. A run interrupted anywhere — ^C, a harness
# timeout, an assertion aborting a case — otherwise leaves them behind.
cancel_sweep() {
  local c deadline
  for c in "$work"/*/ctl; do [ -d "$c" ] || continue; : > "$c/STOP" 2>/dev/null || :; done
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
# Every row is a single literal edit, which is what lets them ride `check_mutation_pool` rather
# than a harness of their own: the shared one already encodes the discipline — the edit must
# APPLY, the child must exit EXACTLY 1, and the failure must be the row's own witness rather than
# an accidental one somewhere else in the suite.
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

  # mut_prepare <copy-dir> — a throwaway tree the nested suite can run in, and the path to mutate.
  # `scripts` alone: that is this suite's whole mutation surface, and copying the repo's contents
  # (with its ~66MB .git) four times over is the cost check_copy_subtrees exists to avoid.
  mut_prepare() {
    local d="$1"
    check_copy_subtrees "$ROOT" "$d" scripts >/dev/null 2>&1 || return 1
    printf '%s' "$d/scripts/selfcheck.sh"
  }

  # mut_run <copy-dir> — the nested suite, guarded by a parse check. A mutation that stops the
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
  if mut_prepare "$mut_ctl" >/dev/null; then
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
  else
    bad "control: could not build the unmutated copy"
  fi

  # One row per case. The first two share an edit deliberately: "cancellation signals nothing" is
  # one defect, and BOTH the pool case and the serial case are required to see it.
  #
  # `for p in ""` empties the TERM loop, which also leaves `had` at 0 and so skips the KILL loop —
  # one edit, nothing signalled at all.
  check_mut "pool-unreapable" \
    'for p in "${!LIVE[@]}"; do' 'for p in ""; do' \
    'cancellation terminates the workers instead of orphaning them'
  check_mut "serial-unreapable" \
    'for p in "${!LIVE[@]}"; do' 'for p in ""; do' \
    'cancelling --serial terminates the running step instead of leaving it behind'
  # TERM survives; only the escalation goes. Every polite stub dies on the first TERM, so this is
  # invisible to the other three cases and visible to the deaf one — which is why that case exists.
  check_mut "no-kill-escalation" \
    '_adb_bounded_signal KILL "$p"' ':' \
    'the TERM -> grace -> KILL escalation stops a worker that ignores TERM'
  # The fix itself, removed: `_cleanup` is back to reaping only what `LIVE` happens to hold.
  check_mut "live-only-reaping" \
    'LIVE["$j"]=1' ':' \
    'a worker forked but not yet recorded in LIVE is still reaped'
  # The two LANE pins (#423). Both are single literal edits, so they ride the same harness. A lane
  # is policy rather than mechanism, which is exactly why it needs a standing proof: emptying the
  # array changes no behaviour any other assertion watches — every step still runs, and every step
  # still passes — so without these rows the pins would be the kind of check that cannot answer
  # wrong.
  check_mut "lane-emptied" \
    'ISOLATED_STEPS=(session-currency install-migration install-guard selfcheck-guard selfcheck-guard-mutation install-dry-run)' \
    'ISOLATED_STEPS=()' \
    'the load-sensitive lane is exactly the suites'
  # lane_reason stops recognising the isolated lane while lane_of still does, so the two fields
  # disagree — the one defect a single-array design could not have had, and the reason the guard
  # asks BOTH questions rather than trusting one.
  check_mut "lane-reason-lost" \
    'for _p in "${ISOLATED_STEPS[@]}"; do [ "$1" = "$_p" ] && { printf '"'"'load-sensitive\n'"'"'; return 0; }; done' \
    ':' \
    "--list's lane and its reason never disagree about any step"

  check_mutation_pool "selfcheck-guard" "$work" mut_prepare mut_run 4
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
reset_ctl() { local fx="${1:-$FX}"; rm -rf "$fx/ctl"; mkdir -p "$fx/ctl"; : > "$fx/ctl/events"; }

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
# SIGKILL nothing survives — so the healthy answer arrives in about a second and a long deadline
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
# healthy answer arrives inside the runner's own 1s TERM->KILL grace. The mutations below pass a
# short one, because a worker that was never signalled is alive IMMEDIATELY and stays that way —
# waiting 30s to be told so would buy nothing and cost it on a required check. It must still
# exceed that 1s grace, or a mutation would "observe survival" during legitimate escalation.
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

check_summary "check-selfcheck"
