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
# WHOLE-NAME membership, not a substring test: `cleanup` is a substring of `cleanup-enum`, so an
# unanchored match silently adds a step the run never selected and the expectation is wrong rather
# than the runner.
declared="$(bash "$FX/scripts/selfcheck.sh" --list | cut -f1 | while IFS= read -r n; do
              case ",$ONLY," in *",$n,"*) printf '%s ' "$n" ;; esac; done)"
eq "$serial_order" "$declared" "--serial emits steps in DECLARATION order"

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

# ============================== 8. filters that select nothing ================================
# A filter that quietly matches nothing runs zero checks and prints the same clean verdict a full
# green run prints. That is the silent-guard failure this repo keeps paying for, so it is an error.
sc --only nosuchstep
eq "$RC_" "2" "--only with an unknown step name is an error"
has "$OUT" "unknown step" "...and says which"
hasnt "$OUT" "ALL CHECKS PASSED" "...and never reports a pass"
sc --only ,,
eq "$RC_" "2" "--only that selects nothing is an error, not an empty pass"
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
reset_ctl
# A pre-created .beat file puts each stub into heartbeat mode: it ticks a counter for ~30s.
for s in "${STUBS[@]}"; do printf '0\n' > "$FX/ctl/$s.beat"; done
ADB_STUB_CTL="$FX/ctl" bash "$FX/scripts/selfcheck.sh" --only "$ONLY" --jobs 4 >"$work/cancel.out" 2>&1 &
runner=$!
# Wait for the pool to be genuinely occupied before signalling, so this tests cancellation rather
# than a race against startup. `grep -c` exits 1 on zero matches while still printing the count,
# so its status is deliberately discarded rather than `|| echo 0`-ed into a two-line result.
started=0; waited=0
while [ "$waited" -lt 100 ]; do
  started="$(grep -c '^+' "$FX/ctl/events" 2>/dev/null)" || :
  [ "${started:-0}" -ge 2 ] && break
  sleep 0.1; waited=$((waited + 1))
done
[ "${started:-0}" -ge 2 ] && ok || bad "cancellation: the pool never started two workers to cancel"
kill -TERM "$runner" 2>/dev/null
wait "$runner" 2>/dev/null; cancel_rc=$?
no "$cancel_rc" "a cancelled run exits non-zero"

# The workers must be GONE, and "gone" is asked of the heartbeats rather than of the process table:
# a live stub ticks every 0.2s, so a 1.5s window it fails to move in is 7 missed ticks. Without the
# runner's traps these would keep ticking for another ~30 seconds.
beats_before="$(cat "$FX"/ctl/*.beat 2>/dev/null)"
sleep 1.5
beats_after="$(cat "$FX"/ctl/*.beat 2>/dev/null)"
eq "$beats_after" "$beats_before" "cancellation terminates the workers instead of orphaning them"

check_summary "check-selfcheck"
