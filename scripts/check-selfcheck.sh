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
#  10. cancellation terminates the workers instead of orphaning them.
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

work="$(mktemp -d)" || { echo "check-selfcheck: cannot create a scratch dir" >&2; exit 1; }
check_exit_guard "check-selfcheck" "rm -rf \"$work\""

# ============================== the fixture =====================================================
# A minimal tree the REAL selfcheck.sh can run in: itself, the library it sources for the floor
# gate, and stub checks. selfcheck.sh does `cd "$(dirname "$0")/.."`, so `$FX` becomes its repo
# root and `bash scripts/check-<x>.sh` resolves inside the fixture.
FX="$work/fx"
mkdir -p "$FX/scripts/lib" "$FX/ctl"
cp "$ROOT/scripts/selfcheck.sh" "$FX/scripts/selfcheck.sh"
cp "$ROOT/scripts/lib/common.sh" "$FX/scripts/lib/common.sh"

# The stub steps, chosen from names the real registry already carries as plain
# `bash scripts/check-<x>.sh` commands — so the fixture exercises the registry as shipped rather
# than a registry this suite rewrote.
STUBS=(practice-index cleanup-enum gates claims fact-guard release-role workflow-shell injection)

# One generic stub, parameterised at run time by a control file per step, so a case can change a
# step's behaviour without rewriting the fixture. Control keys: RC (exit status), LINES (how many
# sentinel lines to emit), SLEEP (how long to occupy its pool slot).
#
# It also appends `+name` on entry and `-name` on exit to a shared event log. Short appends to a
# regular file opened O_APPEND are atomic, so the ORDER in that file is a valid serialization of
# what actually happened, and replaying it yields the true peak concurrency.
for s in "${STUBS[@]}"; do
  cat > "$FX/scripts/check-$s.sh" <<'STUB'
#!/usr/bin/env bash
set -u
name="$(basename "$0" .sh)"; name="${name#check-}"
ctl="$ADB_STUB_CTL"
rc=0; lines=1; nap=0
[ -f "$ctl/$name.rc" ]    && rc="$(cat "$ctl/$name.rc")"
[ -f "$ctl/$name.lines" ] && lines="$(cat "$ctl/$name.lines")"
[ -f "$ctl/$name.sleep" ] && nap="$(cat "$ctl/$name.sleep")"
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
  n=0
  while [ "$n" -lt 150 ]; do n=$((n + 1)); printf '%s\n' "$n" > "$ctl/$name.beat"; sleep 0.2; done
else
  [ "$nap" = 0 ] || sleep "$nap"
fi
printf '%s\n' "-$name" >> "$ctl/events"
exit "$rc"
STUB
  chmod +x "$FX/scripts/check-$s.sh"
done

ONLY="$(IFS=,; printf '%s' "${STUBS[*]}")"

# reset_ctl — clear every control file and the event log, so each case starts from a known state.
reset_ctl() { rm -rf "$FX/ctl"; mkdir -p "$FX/ctl"; : > "$FX/ctl/events"; }

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
# WHOLE-NAME membership, not a substring test: `cleanup` is a substring of `cleanup-enum`, so an
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

# ...and the REAL runner pins build-drift, asked of the runner rather than grepped out of it.
real_pinned="$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$3 == "serial" {print $1}' | tr '\n' ' ')"
eq "$real_pinned" "build-drift " "the shipped runner's serial prologue is exactly build-drift"

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
  PATH="$sb:$PATH" ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/selfcheck.sh" --only practice-index 2>&1 \
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

# --list is the registry contract other guards read; it must stay three TAB-separated fields.
sc --list
yes "$RC_" "--list exits 0"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF != 3 {n++} END {print n + 0}')" "0" \
  "--list emits exactly three TAB-separated fields on every row"
eq "$(printf '%s\n' "$OUT" | awk -F'\t' '$3 != "pool" && $3 != "serial" {n++} END {print n + 0}')" "0" \
  "--list's third field is always pool or serial"

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

# ============================== 10. cancellation ==============================================
# Bash gives an asynchronous command SIGINT-ignore when job control is off, so without the runner's
# own traps a cancelled run kills the parent and leaves up to $JOBS check suites running
# unattended. The stubs here sleep far longer than the poll below, so a surviving worker is
# unambiguous rather than a race.
# cancel_run <label> <extra-setup-fn> — start a run whose stubs heartbeat, wait until the pool is
# genuinely occupied, TERM the runner, and report whether the workers stopped ticking.
#
# "Stopped ticking" is polled to a QUIESCENT state rather than sampled once. A single 1.5s sample
# can read a live-but-descheduled process as dead, and this suite itself runs inside the pool
# alongside seven other steps, so being descheduled is not hypothetical. Polling until two
# consecutive reads agree, with a hard ceiling, is both faster in the common case and not a race:
# the stubs tick for ~30s, so a surviving worker cannot produce two identical reads 0.5s apart.
cancel_run() {
  local label="$1"; shift
  local want="${1:-2}"; shift 2>/dev/null || true
  local runner started=0 waited=0 a b tries=0
  ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/selfcheck.sh" --only "$ONLY" "$@" \
    >"$work/cancel.out" 2>&1 &
  runner=$!
  # `grep -c` exits 1 on zero matches while still printing the count, so its status is deliberately
  # discarded rather than `|| echo 0`-ed into a two-line result.
  while [ "$waited" -lt 100 ]; do
    started="$(grep -c '^+' "$FX/ctl/events" 2>/dev/null)" || :
    [ "${started:-0}" -ge "$want" ] && break
    sleep 0.1; waited=$((waited + 1))
  done
  [ "${started:-0}" -ge "$want" ] && ok || bad "$label: only $started worker(s) started; needed $want to cancel"
  kill -TERM "$runner" 2>/dev/null
  wait "$runner" 2>/dev/null; CANCEL_RC=$?

  a="$(cat "$FX"/ctl/*.beat 2>/dev/null)"
  QUIET=0
  while [ "$tries" -lt 12 ]; do
    tries=$((tries + 1))
    sleep 0.5
    b="$(cat "$FX"/ctl/*.beat 2>/dev/null)"
    if [ "$b" = "$a" ]; then QUIET=1; break; fi
    a="$b"
  done
}

reset_ctl
# A pre-created .beat file puts each stub into heartbeat mode: it ticks a counter for ~30s.
for s in "${STUBS[@]}"; do printf '0\n' > "$FX/ctl/$s.beat"; done
cancel_run "cancellation" 2 --jobs 4
no "$CANCEL_RC" "a cancelled run exits non-zero"
eq "$QUIET" "1" "cancellation terminates the workers instead of orphaning them"

# ...and in --serial, which is a DIFFERENT code path and was the one left uncovered. A serial step
# used to run in the foreground, where a TERM aimed at the runner never reaches it — so cancelling
# during the `build-drift` prologue left a `scripts/build.sh` still rewriting the working tree after
# the runner had exited. Only one worker runs at a time here, so one started worker is the bar.
reset_ctl
for s in "${STUBS[@]}"; do printf '0\n' > "$FX/ctl/$s.beat"; done
cancel_run "cancellation (--serial)" 1 --serial
no "$CANCEL_RC" "a cancelled --serial run exits non-zero"
eq "$QUIET" "1" "cancelling --serial terminates the running step instead of leaving it behind"

# ...and the same again with workers that IGNORE SIGTERM. This is what makes the TERM -> grace ->
# KILL escalation observable: with only polite stubs, deleting the entire KILL loop from _cleanup
# leaves every assertion green (demonstrated by review). A deaf worker is stopped only by the
# escalation, so this case is the one that can see it missing.
reset_ctl
for s in "${STUBS[@]}"; do printf '0\n' > "$FX/ctl/$s.beat"; : > "$FX/ctl/$s.deaf"; done
cancel_run "cancellation (TERM-ignoring workers)" 2 --jobs 4
no "$CANCEL_RC" "a cancelled run exits non-zero even when its workers ignore TERM"
eq "$QUIET" "1" "the TERM -> grace -> KILL escalation stops a worker that ignores TERM"

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
