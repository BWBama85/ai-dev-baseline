#!/usr/bin/env bash
# ai-dev-baseline — SessionStart run-state hook (#431), the Claude HARNESS ADAPTER for
# scripts/lib/run-state.sh. Design and rationale: decision D92.
#
# Reads the SessionStart event on stdin; on `source: compact` or `resume` it asks
# `run-state.sh summary` for the /implement-issue run live in the session repository's
# `.claude/state` and prints ONE JSON object:
#   {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "<text>"}}
# whose first line is a provenance header naming the state directory read. Nothing is printed when
# there is nothing to say. Every other source (`startup` is session-currency.sh's) prints nothing.
#
# CONTRACT
#   - Exits 0 on every path it reaches — a SessionStart hook cannot block, and a non-zero exit
#     renders an error notice on every session start. What no trap reaches: a file that does not
#     parse, and a harness timeout, which the bounded stdin read below exists to keep out of range.
#   - stdin is read with a 5 s bound, as the Stop gate reads it: an open pipe must not consume
#     the hook's timeout budget (settings: 30 s).
#   - The identity is `CLAUDE_CODE_SESSION_ID`, else the payload's `session_id`, else empty — the
#     same precedence as implement-issue-gate.sh. The library decides ownership.
#   - Only closed-grammar values the run wrote reach `additionalContext` (the library's contract);
#     the state-directory path comes from `adb_repo_shape`, which refuses tab/newline roots.
#   - the JSON line written to stdout is capped at ADB_SESSION_CONTEXT_MAX_CHARS (default 9500;
#     floor 1024, ceiling 9500), measured ENCODED —
#     the harness replaces hook output over 10,000 characters with a preview and a file path
#     (vendor docs, read 2026-08-26). A capped summary ends with a line saying so.
#   - stderr carries one audit line — the marker summarised, or "no live run" — for the debug log;
#     the transcript sees the provenance header and, on the `run-state:` line right below it, the
#     state directory that was read. ADB_SESSION_CONTEXT=off: one stderr line, exit 0.
#   - jq, common.sh and run-state.sh are required beside this file; any of them missing means one
#     stderr line and nothing injected.

set -u

# Always exit 0 — registered FIRST, before the library load and the floor gate.
trap 'exit 0' EXIT

# bash 5.3 runtime floor (#256) — the ADVISORY form: re-exec when possible, else take the documented
# no-op path rather than run the body under a sub-floor shell (D31). stdout is silenced too: a
# damaged library that prints would otherwise contaminate the single JSON object below.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1
  if command -v adb_require_bash_advisory >/dev/null 2>&1; then
    adb_require_bash_advisory "$@" || exit 0
  fi
fi

case "${ADB_SESSION_CONTEXT:-}" in
  off|0|false) printf 'session-context: disabled (ADB_SESSION_CONTEXT=%s)\n' "$ADB_SESSION_CONTEXT" >&2; exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'session-context: jq not on PATH — nothing injected\n' >&2; exit 0; }
command -v adb_repo_shape >/dev/null 2>&1 || { printf 'session-context: common.sh not loaded — nothing injected\n' >&2; exit 0; }

# --- 1. the event, read with a bound -----------------------------------------------------------
# `-d ''` reads to EOF; `-t 5` bounds an open pipe. bash >= 4.2 KEEPS a partial read on timeout
# (status > 128), so the discard is ours — the same rule the Stop gate documents.
HOOK_INPUT=""; _rc=0
if [ ! -t 0 ]; then
  IFS= read -r -d '' -t 5 HOOK_INPUT || _rc=$?
  [ "$_rc" -gt 128 ] && HOOK_INPUT=""
fi
# `-j` (no trailing newline) plus a SENTINEL, because `$(…)` strips every trailing newline: a
# `cwd` naming `repo<NL>` would arrive as `repo` — a different directory, and often an existing
# sibling — before `adb_repo_shape` could refuse it (D82's shape). A field that really ends in a
# newline then reaches the validators intact and is refused by them.
hook_field() { printf '%s' "$HOOK_INPUT" | jq -j --arg k "$1" 'if type == "object" then (.[$k] // empty | tostring) else empty end' 2>/dev/null; }
field() { local v; v="$(hook_field "$1"; printf x)"; printf '%s' "${v%x}"; }

SOURCE="$(field source; printf x)"; SOURCE="${SOURCE%x}"
case "$SOURCE" in
  compact|resume) : ;;
  *) exit 0 ;;
esac

# --- 2. where, and who -----------------------------------------------------------------------------
SESSION_CWD="$(field cwd; printf x)"; SESSION_CWD="${SESSION_CWD%x}"
[ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
[ -d "$SESSION_CWD" ] || exit 0
SHAPE="$(adb_repo_shape "$SESSION_CWD" 2>/dev/null)" || exit 0
[ "$(adb_shape_val "$SHAPE" in_git)" = 1 ] || exit 0
REPO_ROOT="$(adb_shape_val "$SHAPE" root)"
[ -n "$REPO_ROOT" ] || exit 0
STATE_DIR="$REPO_ROOT/.claude/state"

SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || { SID="$(field session_id; printf x)"; SID="${SID%x}"; }

# --- 3. the library --------------------------------------------------------------------------------
_adb_rs="$(dirname "$0")/lib/run-state.sh"
[ -f "$_adb_rs" ] || { printf 'session-context: run-state.sh not found beside this hook — nothing injected\n' >&2; exit 0; }
SUMMARY="$(bash "$_adb_rs" summary --state "$STATE_DIR" --session "$SID" 2>/dev/null)"; RC=$?
case "$RC" in
  0|4|18|20) : ;;
  *) printf 'session-context: run-state.sh exited %s — nothing injected\n' "$RC" >&2; exit 0 ;;
esac
if [ -z "$SUMMARY" ]; then
  printf 'session-context: no live run in %s — nothing injected\n' "$STATE_DIR" >&2
  exit 0
fi
printf 'session-context: injected the run-state summary from %s (run-state.sh rc %s)\n' "$STATE_DIR" "$RC" >&2

# --- 4. presentation -------------------------------------------------------------------------------
# SHORT, and it names no path: the summary's own first line carries the source, and every
# character here is budget the facts below do not get under a small cap.
HEADER="ai-dev-baseline run-state, read after SessionStart $SOURCE — marker data only (phase, branch, issue numbers, paths, counts), never issue or finding text."
MAX="${ADB_SESSION_CONTEXT_MAX_CHARS:-9500}"
case "$MAX" in ''|*[!0-9]*) MAX=9500 ;; esac
# A FLOOR, so that a cap always leaves room for FACTS, not only for the header and the cap line:
# with the header at ~150 characters and the cap line at ~90, 1024 leaves ~780 for the summary,
# enough for the source line (which carries the state path), the phase, the branch and the
# issue numbers under any ordinary checkout path. Below the floor the arithmetic went negative
# and, once that was bounded, the output was the cap notice alone.
[ "$MAX" -ge 1024 ] 2>/dev/null || MAX=1024
# ...AND A CEILING: the harness's limit is 10,000, so a larger value would only buy the preview-
# and-file-path substitute for the whole injection.
[ "$MAX" -le 9500 ] 2>/dev/null || MAX=9500
# THE CAP LINE IS FIXED-LENGTH: it names no path, because a path is unbounded and a suffix longer
# than the cap made the slice below negative — jq counts a negative end from the END, and the
# "capped" output came out longer than the cap it named (315-char path, 256 cap: 1,315 chars).
# The state directory is on the summary's own first line (the `run-state:` line right below the
# header) and on stderr; the cap line points there.
# THE BUDGET IS MEASURED ON THE ENCODED TEXT — `enc` is the JSON string length minus its quotes —
# because the harness's limit applies to what is written, and a path full of backslashes or
# quotes doubles under escaping (measured: 8,692 decoded characters, 16,779 on the wire).
jq -cn --arg h "$HEADER" --arg s "$SUMMARY" --argjson max "$MAX" '
  def enc: (tojson | length) - 2;
  ($h + "\n" + $s) as $ctx
  | "\n(capped at \($max) characters — the state directory is named on the run-state line below the header, and on stderr)" as $cap
  # 73 = the wrapper object around additionalContext, so the whole stdout line fits in $max.
  | ($max - 73) as $budget
  | ($budget - ($cap | enc)) as $keep
  # LINE BY LINE, IN ORDER, so the short facts survive whatever a long line does: a line that
  # fits is kept; the header or the source line (0 and 1), when too long, is TRUNCATED to a third
  # of the budget rather than dropped, since the path in it is the one unbounded value; any other
  # line that does not fit is skipped and the next one is tried. Every measure is `enc`.
  | (if ($ctx | enc) <= $budget then $ctx
     elif $keep <= 0 then ($cap[1:] | .[:($budget - 2)])
     else (reduce ($ctx | split("\n") | to_entries[]) as $e ("";
             ($e.value) as $l
             | (if . == "" then 0 else (. | enc) + 1 end) as $used
             | if $used + ($l | enc) <= $keep then (if . == "" then $l else . + "\n" + $l end)
               elif $e.key <= 1 and ($keep / 3 | floor) > 8 and $used + ($keep / 3 | floor) <= $keep
                 then (if . == "" then "" else . + "\n" end)
                      + ($l | [range(length)] | map(. + 1) | map(select(($l[:.] | enc) <= ($keep / 3 | floor) - 3)) | last // 0 | $l[:.]) + "…"
               else . end)) + $cap end) as $out
  | {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $out}}'
exit 0
