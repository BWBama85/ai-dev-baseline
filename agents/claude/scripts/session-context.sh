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
# ONLY AN EOF-TERMINATED READ IS A PAYLOAD. `-d ''` makes NUL the delimiter, so `read` returns 0
# when it finds one — with the bytes BEFORE it and the rest unread — and 1 at EOF with everything.
# A JSON event never carries a NUL, so status 0 is a split payload and is discarded, as is a
# timeout (> 128).
HOOK_INPUT=""; _rc=0
if [ ! -t 0 ]; then
  IFS= read -r -d '' -t 5 HOOK_INPUT || _rc=$?
  case "$_rc" in 1) : ;; *) HOOK_INPUT="" ;; esac
fi
# `-j` (no trailing newline) plus a SENTINEL, because `$(…)` strips every trailing newline: a
# `cwd` naming `repo<NL>` would arrive as `repo` — a different directory, and often an existing
# sibling — before `adb_repo_shape` could refuse it (D82's shape). A field that really ends in a
# newline then reaches the validators intact and is refused by them.
# SLURPED AND COUNTED: two objects on stdin would otherwise be evaluated both, and `-j` would
# concatenate their fields — `"com"` + `"pact"` is a source this hook acts on, and two half paths
# are a checkout nobody named. Exactly one object, or no field at all.
# STRINGS ONLY: `tostring` would turn `"cwd": false` into the relative path `false`, which can name
# a nested repository nobody supplied. A field of any other type is absent.
hook_field() { printf '%s' "$HOOK_INPUT" | jq -js --arg k "$1" 'if length == 1 and (.[0]|type) == "object" and (.[0][$k]|type) == "string" then .[0][$k] else empty end' 2>/dev/null; }
field() { local v; v="$(hook_field "$1"; printf x)"; printf '%s' "${v%x}"; }

SOURCE="$(field source; printf x)"; SOURCE="${SOURCE%x}"
case "$SOURCE" in
  compact|resume) : ;;
  *) exit 0 ;;
esac

# --- 2. where, and who -----------------------------------------------------------------------------
SESSION_CWD="$(field cwd; printf x)"; SESSION_CWD="${SESSION_CWD%x}"
# NO $PWD FALLBACK. Every hook payload carries `cwd` (the common-fields contract), so a payload
# without a valid one is not a SessionStart this hook may act on — and $PWD is where the hook
# PROCESS runs, which would inject whichever checkout the process happened to start in.
[ -n "$SESSION_CWD" ] || exit 0
[ -d "$SESSION_CWD" ] || exit 0
SHAPE="$(adb_repo_shape "$SESSION_CWD" 2>/dev/null)" || exit 0
[ "$(adb_shape_val "$SHAPE" in_git)" = 1 ] || exit 0
REPO_ROOT="$(adb_shape_val "$SHAPE" root)"
[ -n "$REPO_ROOT" ] || exit 0
STATE_DIR="$REPO_ROOT/.claude/state"

# --- 2b. one hook per checkout ------------------------------------------------------------------
# A release-pinned project vendors this hook under .claude/adb/ and wires it in the project's
# .claude/settings.json; Claude merges hooks across settings scopes rather than overriding them,
# so a machine that also carries the global install would run BOTH copies on every compact and
# resume — the same state injected twice, possibly by two reader versions. The project-scoped
# copy is the pin's: this one defers to it when it exists AND is wired. A vendored file that is
# not wired, or a settings.json this cannot read, leaves the global hook running — one injection
# either way, never zero.
_adb_vendored="$REPO_ROOT/.claude/adb/session-context.sh"
if [ -f "$_adb_vendored" ] && ! [ "$0" -ef "$_adb_vendored" ]; then
  # ...and only when the group that wires it would FIRE for this source. A matcher made of letters,
  # digits, `_ - space , |` is an exact alternative list; anything else is an UNANCHORED regex;
  # absent, empty or `*` covers every source (the vendor's rule, read this run). A group matched
  # `startup` does not run on `compact`, and deferring to it would be zero injections, not one.
  if jq -e --arg src "$SOURCE" '[.hooks.SessionStart[]? | select((.matcher // "") as $m | $m == "" or $m == "*" or (if ($m | test("^[A-Za-z0-9_ ,|-]+$")) then ([$m | split("|")[] | split(",")[] | gsub("^ +| +$"; "")] | index($src) != null) else ($src | test($m)) end)) | .hooks[]? | select(.type == "command" and (.command|type) == "string" and (.command | test("/\\.claude/adb/session-context\\.sh$")))] | length > 0' "$REPO_ROOT/.claude/settings.json" >/dev/null 2>&1; then
    printf 'session-context: deferring to the pinned hook wired in %s/.claude/settings.json — nothing injected here\n' "$REPO_ROOT" >&2
    exit 0
  fi
fi

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
# THE BUDGET IS MEASURED ON THE ENCODED BYTES — `enc` is the JSON string's UTF-8 byte length
# minus its quotes — because the harness's limit applies to what is written: a path full of
# backslashes or quotes doubles under escaping (measured: 8,692 decoded characters, 16,779 on the
# wire), and a multibyte character is one code point and up to four bytes.
jq -cn --arg h "$HEADER" --arg s "$SUMMARY" --argjson max "$MAX" '
  def enc: (tojson | utf8bytelength) - 2;   # BYTES, not code points: an emoji is 1 to length, 4 on the wire
  ($h + "\n" + $s) as $ctx
  | "\n(capped at \($max) characters — the state directory is named on the run-state line below the header, and on stderr)" as $cap
  # The wrapper around additionalContext is MEASURED, not a constant (a constant of 73 was 5 short
  # of the real 78 and let a 9,505-character line through a 9,500 cap), so the whole stdout line
  # fits in $max.
  # ...and ONE MORE for the newline jq writes after the object, which is on the wire too.
  | ($max - 1 - ({hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ""}} | tojson | utf8bytelength)) as $budget
  | ($budget - ($cap | enc)) as $keep
  # LINE BY LINE, IN ORDER, so the short facts survive whatever a long line does: a line that
  # fits is kept; the header or the source line (0 and 1), when too long, is TRUNCATED to a third
  # of the budget rather than dropped, since the path in it is the one unbounded value; any other
  # line that does not fit is skipped and the next one is tried. Every measure is `enc`.
  | (if ($ctx | enc) <= $budget then $ctx
     elif $keep <= 0 then ($cap[1:] | .[:($budget - 2)])
     else (reduce ($ctx | split("\n") | to_entries[]) as $e ("";
             ($e.value) as $l
             | (if . == "" then 0 else (. | enc) + 2 end) as $used   # +2: a newline is `\n` on the wire
             | if $used + ($l | enc) <= $keep then (if . == "" then $l else . + "\n" + $l end)
               elif $e.key <= 1 and ($keep / 3 | floor) > 8 and $used + ($keep / 3 | floor) <= $keep
                 then (if . == "" then "" else . + "\n" end)
                      + ($l | [range(length)] | map(. + 1) | map(select(($l[:.] | enc) <= ($keep / 3 | floor) - 3)) | last // 0 | $l[:.]) + "…"
               else . end)) + $cap end) as $folded
  # BY CONSTRUCTION, whatever the fold arithmetic did: the serialized object plus the newline that
  # jq writes is measured, and trailing lines (above the cap notice) are dropped until it fits.
  | ($folded | split("\n")) as $ls
  | (if ($ls | length) > 0 and ($ls[-1] | startswith("(capped at")) then $ls[-1] else "" end) as $notice
  | (if $notice == "" then $ls else $ls[:-1] end) as $body
  | ({hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ""}} | tojson | utf8bytelength) as $wrap
  | ($body | until((length == 0) or ((((. + (if $notice == "" then [] else [$notice] end)) | join("\n")) | enc) + $wrap + 1 <= $max); .[:-1])) as $kept
  | (($kept + (if $notice == "" then [] else [$notice] end)) | join("\n")) as $out
  | {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $out}}'
exit 0
