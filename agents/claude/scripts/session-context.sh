#!/usr/bin/env bash
# ai-dev-baseline — SessionStart run-state hook (#431), the Claude HARNESS ADAPTER.
#
# When the harness compacts a session's context — or resumes one — the /implement-issue run that
# was in flight survives only as far as the summary happened to carry it. The run's own state
# directory holds the facts (phase, branch, issue, the findings' paths); this hook reads them back
# through `scripts/lib/run-state.sh summary` and injects the result as `additionalContext`.
#
# WHAT THIS FILE IS. Only the Claude-specific half: read the SessionStart event, act on `compact`
# and `resume` only, resolve the state directory and the session id, and render the library's
# answer into the harness's context channel. Every DECISION — liveness, ownership, validation, the
# output grammar — lives in the library, so a Codex or Gemini workflow step can ask it the same
# question after their own compaction (#14). Same split as session-currency.sh ↔ currency-lib.sh.
#
# CONTRACT WITH THE HARNESS (docs: https://code.claude.com/docs/en/hooks)
#   - SessionStart CANNOT block a session, and this hook exits 0 on EVERY path — including its own
#     bugs. A run summary is a convenience; it must never be the reason a session looks broken.
#   - `hookSpecificOutput.additionalContext` on exit 0 is injected into Claude's context. Nothing
#     is printed when there is nothing to say, which is every session that has no run in flight.
#   - stderr from an exit-0 hook goes to the debug log, NOT the transcript. So the audit line —
#     which marker was summarised — rides INSIDE the injected text as its first line, where the
#     transcript shows it; stderr carries only the disabled note.
#
# WHEN IT ACTS
#   - `source: compact` and `source: resume` only. `startup` is session-currency.sh's, `clear` starts
#     a fresh conversation whose run is over by construction, and `fork` runs beside a live parent.
#     The settings matcher already narrows it; the check is repeated here so the guarantee does not
#     depend on the harness honoring a matcher.
#
# WHAT IS INJECTED, AND WHAT NEVER IS. Only fields the run itself wrote — a phase word, a branch
# name, issue NUMBERS, paths, counts. Never an issue's text, never a finding's prose: those files
# carry third-party text, and this output lands in a model's context
# (base/practices/untrusted-content.md). The library enforces that; this file only renders.
#
# ESCAPE HATCH: ADB_SESSION_CONTEXT=off — one stderr line, no injection.

set -u

# Always exit 0 — see the harness contract above. Registered FIRST, before the library source and
# the floor gate below, so even an unbound-variable abort while loading a shared library cannot
# turn into a session-start error notice.
trap 'exit 0' EXIT

# bash 5.3 runtime floor (#256) — the ADVISORY form: a SessionStart hook renders an error notice
# on every session start when it exits non-zero, and this one exits 0 on every path by design.
# ADVISORY MEANS "STOP QUIETLY", NOT "CARRY ON REGARDLESS": when no >= 5.3 interpreter can be
# reached, this takes its documented no-op path rather than running its body under a sub-floor
# shell (D31).
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" 2>/dev/null
  if command -v adb_require_bash_advisory >/dev/null 2>&1; then
    adb_require_bash_advisory "$@" || exit 0
  fi
fi

case "${ADB_SESSION_CONTEXT:-}" in
  off|0|false) printf 'session-context: disabled (ADB_SESSION_CONTEXT=%s)\n' "$ADB_SESSION_CONTEXT" >&2; exit 0 ;;
esac

# jq is required on both sides: the event is JSON in and the injection is JSON out. Without it
# nothing is injected — a hook cannot block, and a plain-stdout fallback would put an unstructured
# line into the context with no provenance header.
command -v jq >/dev/null 2>&1 || { printf 'session-context: jq not on PATH — nothing injected\n' >&2; exit 0; }

# --- 1. the event: act on compact and resume only ------------------------------------------------
HOOK_INPUT="$(cat 2>/dev/null || true)"
hook_field() { printf '%s' "$HOOK_INPUT" | jq -r --arg k "$1" 'if type == "object" then (.[$k] // empty | tostring) else empty end' 2>/dev/null; }

case "$(hook_field source)" in
  compact|resume) : ;;
  *) exit 0 ;;
esac

# --- 2. where, and who ---------------------------------------------------------------------------
# `cwd` is the session's directory, which need not be this process's. The state directory is the
# checkout's `.claude/state`, resolved from the repository root exactly as the Stop gate resolves
# its marker; a cwd outside any repository has no run state to read.
SESSION_CWD="$(hook_field cwd)"
[ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
[ -d "$SESSION_CWD" ] || exit 0
REPO_ROOT="$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 0
STATE_DIR="$REPO_ROOT/.claude/state"

# The session id, the same two ways the Stop gate reads it (#180): the env var when the harness
# exports it, else the payload's `session_id`. Empty is a real answer — "cannot identify myself" —
# which the library treats as compatible with any marker, never as foreign.
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || SID="$(hook_field session_id)"

# --- 3. the library ------------------------------------------------------------------------------
_adb_rs="$(dirname "$0")/lib/run-state.sh"
[ -f "$_adb_rs" ] || { printf 'session-context: run-state.sh not found beside this hook — nothing injected\n' >&2; exit 0; }

SUMMARY="$(bash "$_adb_rs" summary --state "$STATE_DIR" --session "$SID" 2>/dev/null)"; RC=$?
case "$RC" in
  0|4|18|20) : ;;                       # each prints what it has to say, or nothing
  *) printf 'session-context: run-state.sh exited %s — nothing injected\n' "$RC" >&2; exit 0 ;;
esac
[ -n "$SUMMARY" ] || exit 0

# --- 4. presentation -----------------------------------------------------------------------------
# The first line is the provenance header — the audit the transcript can show. Declarative, like
# every line under it: the vendor asks that injected context be stated as fact, not instruction.
HEADER="ai-dev-baseline run-state (source: $STATE_DIR; read after SessionStart $(hook_field source)). The lines below are the run's own marker data — phase, branch, issue numbers, paths, counts — never issue or finding text."
jq -cn --arg h "$HEADER" --arg s "$SUMMARY" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ($h + "\n" + $s)}}'
exit 0
