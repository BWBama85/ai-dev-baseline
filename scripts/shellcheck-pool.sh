#!/usr/bin/env bash
# ai-dev-baseline — lint a set of shell files with a bounded pool of shellcheck processes (#455).
#
# ONE HOME for the lint the turn-end gate (`.claude/scripts/precommit-gate.sh`), selfcheck's
# `shellcheck` step and CI's `shellcheck` job all call, so they cannot drift into three shapes. Why
# a pool, and why per file rather than in contiguous batches, with the measurements: D127.
#
# THE CONTRACT:
#   - ONE shellcheck PER FILE, at most W running at a time, W = `adb_pool_size` capped by
#     ADB_SHELLCHECK_JOBS (default 8), and never more workers than files; dispatched largest file
#     first (bytes, a proxy for lint cost), so a heavy file is never the last to start;
#   - every file's output is captured whole and emitted IN THE ORDER THE FILES WERE GIVEN, each as
#     soon as it and everything before it has finished — so diagnostics never interleave;
#   - the status is red ONCE if any file was red, never once per file; a linter that fails (rc >= 2)
#     or an output that cannot be read back is red and counted as NOT linted;
#   - the last line always names what was linted — `shellcheck-pool: N file(s), W worker(s)` — so a
#     run that linted nothing can never look like one that passed. "Workers" is the width actually
#     used, min(W, N), not the configured ceiling.
#   - NOT bounded in time: a lint that hangs holds the files after it, as the single process this
#     replaced did. `ADB_SHELLCHECK_JOBS=1` is how a hang is attributed to one file;
#   - BOUNDED ON DISK, by ADB_SHELLCHECK_MAX_BYTES (default 64 MiB), at two points: each worker's
#     output is cut at the cap AS IT IS WRITTEN (`head -c`), and a lint whose output reached it is
#     red; and the STAGED total — finished files waiting behind a slower earlier one — is checked
#     after every reap, stopping the run red when it passes the cap. Scratch therefore never holds
#     more than the cap staged plus the cap per running worker. On a stop, whatever was staged is
#     emitted (out of order, and labelled so) rather than discarded;
#   - each file is linted ALONE: by default the linter follows a `source` only into files named in
#     the same invocation, so that no longer happens within the set (a `.shellcheckrc` enabling
#     external sources still can). The repo's sources point at `/dev/null` or are excluded by
#     SC1091, so nothing is lost today.
#
# THE POLICY FLAGS LIVE HERE, once, for all three callers: `--severity=warning` drops the style and
# info tiers so the lint fails on correctness findings, not nits; `-e SC1091` because the gates
# source their libraries through dynamically resolved paths the linter cannot follow statically.
#
# Usage:
#   bash scripts/shellcheck-pool.sh [--] <file>...   lint the named files
#   bash scripts/shellcheck-pool.sh -0               lint the NUL-delimited paths on stdin (no
#                                                    word-splitting anywhere: a path may carry a
#                                                    space, a tab or a newline). A final record
#                                                    without its NUL is accepted, as `mapfile -d ''`
#                                                    reads it; completeness of the producer's output
#                                                    is the CALLER's to check, not this framing's.
# Exit: 0 clean · 1 findings, or a lint that did not complete · 2 usage, or nothing to lint ·
#       3 the pool could not be set up (no shellcheck, no scratch directory).
#
# Environment:
#   ADB_SHELLCHECK_JOBS  a CAP on the pool width — it lowers the ordinary `adb_pool_size` budget
#                        (min(cpu, 8), or ADB_POOL_JOBS under the same ceiling), never raises it.
#                        `ADB_SHELLCHECK_JOBS=1` forces a serial lint, which is how a hang is
#                        attributed to one invocation.
#   ADB_POOL_JOBS        the repo-wide budget `adb_pool_size` already honours; the lower of the two wins.
#   ADB_SHELLCHECK_MAX_BYTES  the staged-diagnostics cap above, in bytes (a positive integer; any
#                        other value falls back to the 64 MiB default rather than to "no cap").

# bash 5.3 runtime floor (#256) — FIRST, before `set -u`. Same stanza as every other entry point.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail

ME="shellcheck-pool"
usage() { printf 'usage: %s [--] <file>... | %s -0  (NUL-delimited paths on stdin)\n' "$ME" "$ME" >&2; exit 2; }

files=()
case "${1:-}" in
  -0) [ "$#" -eq 1 ] || usage
      mapfile -d '' -t files ;;
  --) shift; files=("$@") ;;
  -*) usage ;;
  *)  files=("$@") ;;
esac

n="${#files[@]}"
[ "$n" -gt 0 ] || { printf '%s: no files to lint — a lint over nothing is not a pass\n' "$ME" >&2; exit 2; }
command -v shellcheck >/dev/null 2>&1 || { printf '%s: shellcheck is not installed\n' "$ME" >&2; exit 3; }

# The ordinary budget FIRST (min(cpu, 8), or ADB_POOL_JOBS under the same cap), then lowered by
# ADB_SHELLCHECK_JOBS read through the same helper: passing the shellcheck cap AS the budget's cap
# would let a large value lift the eight-worker ceiling.
width="$(adb_pool_size)"
sc_cap="$(adb_pool_size "${ADB_SHELLCHECK_JOBS:-8}")"
[ "$sc_cap" -ge "$width" ] || width="$sc_cap"
[ "$width" -le "$n" ] || width="$n"

tmp="$(mktemp -d)" || { printf '%s: cannot create a scratch directory\n' "$ME" >&2; exit 3; }
declare -A slot=()   # pid -> file index, for every lint still running
# An interrupted lint takes its RUNNING workers with their descendants: an orphaned shellcheck — or
# anything a running linter started — would keep a core busy after the caller has given up on the
# answer. (A descendant a linter leaves behind after it has already exited is not tracked; the
# linter does not do that.) So every
# worker runs in its OWN PROCESS GROUP (job control on, `set -m`, as `selfcheck.sh`'s pool does), and
# cleanup signals the group through the shared `_adb_bounded_signal`: TERM, a bounded grace, then
# KILL for anything that ignored it. `jobs -p`, not only the slot table, so a worker started but not
# yet recorded (the `&` and the assignment are two statements) is reaped too.
cleanup() {
  local p alive i
  local -a kids=()
  mapfile -t kids < <(jobs -p)
  if [ "${#kids[@]}" -gt 0 ]; then
    for p in "${kids[@]}"; do _adb_bounded_signal TERM "$p"; done
    for (( i = 0; i < 20; i++ )); do
      alive=0
      for p in "${kids[@]}"; do kill -0 -- "-$p" 2>/dev/null && alive=1; done
      [ "$alive" -eq 0 ] && break
      sleep 0.1
    done
    for p in "${kids[@]}"; do _adb_bounded_signal KILL "$p"; done
    wait 2>/dev/null
  fi
  [ -z "$tmp" ] || rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set -m

# The dispatch queue: file indices, largest file first. A file that cannot be sized sorts as 0 and is
# still linted (its shellcheck reports why it could not be read).
order=()
mapfile -t order < <(
  for (( i = 0; i < n; i++ )); do
    sz="$(wc -c < "${files[i]}" 2>/dev/null)" || sz=0
    printf '%s %s\n' "${sz//[!0-9]/}" "$i"
  done | sort -k1,1nr -k2,2n | awk '{print $2}')
wait "$!" || { printf '%s: could not order the %s file(s) for dispatch (the sort failed)\n' "$ME" "$n" >&2; exit 3; }
[ "${#order[@]}" -eq "$n" ] || { printf '%s: could not order the %s file(s) for dispatch\n' "$ME" "$n" >&2; exit 3; }

status=()            # file index -> shellcheck's exit status, once reaped
red=0 linted=0 next=0 flushed=0
max_bytes="${ADB_SHELLCHECK_MAX_BYTES:-}"
case "$max_bytes" in ''|*[!0-9]*|0*) max_bytes=67108864 ;; esac
[ "${#max_bytes}" -le 15 ] || max_bytes=67108864
staged=0
declare -A staged_size=()   # file index -> bytes, for finished files not yet emitted
# Emit every finished file whose predecessors have all been emitted. Called after each reap, so the
# output streams in input order rather than arriving all at once at the end.
flush() {
  while [ "$flushed" -lt "$n" ] && [ -n "${status[flushed]+set}" ]; do
    # A lint whose output cannot be read back is not a verdict either: its findings would be lost.
    if ! cat "$tmp/$flushed.out"; then
      red=1
      printf '%s: %s — its lint output could not be read back\n' "$ME" "${files[flushed]}"
    else
      case "${status[flushed]}" in
        125) red=1
           printf '%s: %s — its lint output could not be captured, so its diagnostics are incomplete; not counted as linted\n' \
             "$ME" "${files[flushed]}" ;;
        cut) red=1
           printf '%s: %s produced more than ADB_SHELLCHECK_MAX_BYTES=%s bytes of diagnostics — cut there, not counted as linted\n' \
             "$ME" "${files[flushed]}" "$max_bytes" ;;
        0) linted=$(( linted + 1 )) ;;
        1) linted=$(( linted + 1 )); red=1 ;;   # findings: the file was linted, and is red
        *) red=1                                 # the linter itself failed: not a verdict
           printf '%s: %s did not complete — shellcheck exited %s\n' "$ME" "${files[flushed]}" "${status[flushed]}" ;;
      esac
    fi
    # Emitted: its bytes need not wait for the end of the run. A removal that fails is red — a
    # scratch directory that cannot be cleaned is a fault, never something a green verdict hides.
    rm -f "$tmp/$flushed.out" || { red=1; printf '%s: could not remove the scratch output for %s\n' "$ME" "${files[flushed]}"; }
    staged=$(( staged - ${staged_size[$flushed]:-0} )); unset 'staged_size[$flushed]'
    flushed=$(( flushed + 1 ))
  done
}

while [ "$flushed" -lt "$n" ]; do
  while [ "$next" -lt "$n" ] && [ "${#slot[@]}" -lt "$width" ]; do
    i="${order[next]}"
    # The linter's output is cut at the cap AS IT IS WRITTEN; its status is the linter's own
    # (PIPESTATUS), and one killed by the cut (SIGPIPE) is a failed lint, red like any other. The
    # WRITER's status is checked too: a capture that failed lost diagnostics whatever the linter
    # said, so it returns 125, which flush reports as a capture failure — never as a lint verdict.
    ( shellcheck --severity=warning -e SC1091 -- "${files[i]}" </dev/null 2>&1 | head -c "$(( max_bytes + 1 ))" >"$tmp/$i.out"
      ps=("${PIPESTATUS[@]}"); [ "${ps[1]}" -eq 0 ] || exit 125
      exit "${ps[0]}" ) &
    slot[$!]="$i"
    next=$(( next + 1 ))
  done
  done_pid=""
  wait -n -p done_pid "${!slot[@]}"; st=$?
  # No pid means nothing was reaped — a wait that returned without a child is not a lint result,
  # and looping on it would spin. Every file not yet reaped is then unaccounted for, which is red.
  # `${done_pid:-}`: with no child to reap, `wait -p` UNSETS the variable rather than leaving it
  # empty, and under `set -u` a bare expansion would kill the pool before it could say so.
  if [ -z "${done_pid:-}" ] || [ -z "${slot[$done_pid]+set}" ]; then
    printf '%s: lost track of %s running lint(s) — wait returned %s with no child\n' "$ME" "${#slot[@]}" "$st"
    break
  fi
  i="${slot[$done_pid]}"
  unset 'slot[$done_pid]'
  # Its output is final now: count it as staged until flush emits it. A size that cannot be read
  # STOPS the run: a benign zero would let the cap go unenforced.
  sz="$(wc -c < "$tmp/$i.out" 2>/dev/null)" && sz="${sz//[!0-9]/}" && [ -n "$sz" ] || {
    red=1; printf '%s: could not read the size of %s'"'"'s lint output — stopping, the disk cap cannot be enforced\n' "$ME" "${files[i]}"
    break; }
  # A CUT OUTPUT IS ITS OWN STATE, whatever the linter returned: its diagnostics are incomplete, so
  # the file is red and is not counted as linted.
  if [ "$sz" -gt "$max_bytes" ]; then st="cut"; fi
  status[$i]="$st"
  staged_size[$i]="$sz"; staged=$(( staged + sz ))
  flush
  if [ "$staged" -gt "$max_bytes" ]; then
    red=1
    printf '%s: staged diagnostics reached %s bytes, past ADB_SHELLCHECK_MAX_BYTES=%s — stopping\n' "$ME" "$staged" "$max_bytes"
    # What finished is emitted rather than discarded — out of order, and said so.
    for k in "${!staged_size[@]}"; do
      printf '%s: --- %s (finished; emitted out of order because the run stopped) ---\n' "$ME" "${files[k]}"
      cat "$tmp/$k.out" 2>/dev/null || printf '%s: (its output could not be read back)\n' "$ME"
    done
    printf '%s: %s file(s) emitted in order, %s finished but held back (above), %s still running or never started\n' \
      "$ME" "$flushed" "${#staged_size[@]}" "$(( n - flushed - ${#staged_size[@]} ))"
    break
  fi
done

# The scratch directory is removed BEFORE the verdict, so a removal that fails can still turn it red
# (an EXIT trap's failure cannot change the status the script already chose).
if rm -rf "$tmp"; then tmp=""; else
  red=1; printf '%s: could not remove the scratch directory %s\n' "$ME" "$tmp"
fi

# THE GUARD THAT RAN NOTHING: every file handed in must have been linted to a verdict. A dispatch
# slip that dropped a file, or a lint that died, is red even if nothing reported a finding.
if [ "$linted" -ne "$n" ]; then
  printf '%s: FAIL — linted %s of %s file(s), %s worker(s)\n' "$ME" "$linted" "$n" "$width"
  exit 1
fi
if [ "$red" -ne 0 ]; then
  printf '%s: FAIL — %s file(s), %s worker(s)\n' "$ME" "$n" "$width"
  exit 1
fi
printf '%s: %s file(s), %s worker(s)\n' "$ME" "$n" "$width"
exit 0
