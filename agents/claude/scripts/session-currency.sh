#!/usr/bin/env bash
# ai-dev-baseline — SessionStart currency hook (issue #36), the Claude HARNESS ADAPTER (issue #139).
#
# Keeps the INSTALLED baseline current without the operator remembering anything. The global
# install is a set of symlinks into one clone (the "install-source"); when that clone lags origin,
# every project on the machine silently runs stale skills, practices, and gates.
#
# WHAT THIS FILE IS. Only the Claude-specific half: read the SessionStart event, decide whether
# this is a genuinely new session, and render at most one line into the harness's operator channel.
# Every DECISION — mode, the install-source, the self-clone guard, the rate limit, git's network
# bounds, running `baseline update` and classifying its outcome — lives in
# scripts/lib/currency-lib.sh, because `/cleanup` needs exactly the same policy from a workflow
# step on three different agents (#139). A Claude hook could never give Codex and Gemini currency;
# a shared lib does. Keeping the policy here is what made currency single-triggered in the first
# place, and #139 is what that cost.
#
# CONTRACT WITH THE HARNESS (docs: https://code.claude.com/docs/en/hooks)
#   - SessionStart CANNOT block a session. A non-zero exit only renders a hook-error notice in the
#     transcript, so this script exits 0 on EVERY path — including its own bugs. Currency is a
#     convenience; it must never be the reason a session looks broken.
#   - Plain stdout on exit 0 is injected into CLAUDE's context. Structured JSON is parsed instead,
#     and `systemMessage` is the OPERATOR-visible channel. The operator is who acts on "your
#     install needs attention", so the line goes there — and nothing is printed at all when the
#     install is current, which is the overwhelmingly common case.
#
# WHEN IT ACTS
#   - `source: startup` only. `clear` and `compact` happen MID-SESSION, `fork` runs beside a live
#     parent, and `resume` continues a conversation whose tooling was loaded earlier. Swapping
#     tooling under any of those is the "surprising mid-session change" this deliberately avoids.
#     The settings matcher already narrows it; the check is repeated here so the guarantee does not
#     depend on the harness honoring a matcher.
#   - That exclusion is also precisely why this hook is NOT sufficient on its own: this repo's own
#     loop ends every batch with `/clear`, so the loop never re-checks. `/cleanup` carries the
#     second trigger (#139). Both call the same library.
#
# MODE is read by the library from the GLOBAL manifest only —
#   ~/.config/ai-dev-baseline/agents.toml  ->  [updates] session_start = "auto"|"notify"|"off"
# and `off` disables BOTH triggers. ADB_SESSION_UPDATE overrides it (tests, CI, one-off runs).

set -u

# Always exit 0 — see the harness contract above. Registered FIRST, before the library source and
# the floor gate below, so even an unbound-variable abort while loading a shared library cannot
# turn into a session-start error notice. (It used to sit after them, which contradicted its own
# "before anything else can fail" claim; independent review caught that.)
trap 'exit 0' EXIT

# bash 5.3 runtime floor (#256) — the ADVISORY form, and the distinction is this file's own
# contract rather than a preference: a SessionStart hook renders an error notice on EVERY session
# start when it exits non-zero, and this one exits 0 on every path by design.
#
# ADVISORY MEANS "STOP QUIETLY", NOT "CARRY ON REGARDLESS". The re-exec is attempted first and is
# silent when it works. When it cannot — no >= 5.3 interpreter anywhere — this hook takes its
# documented no-op path and exits 0. It does NOT run its body under a sub-floor interpreter: once
# #258/#259 land 5.3-only syntax, that body would fail somewhere deep, which is the exact failure
# the floor exists to prevent. Review caught the first cut doing precisely that.
#
# The cost of stopping is one skipped currency check, which is a convenience by this file's own
# framing. The cost of continuing is an unpredictable failure in a session-start hook.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" 2>/dev/null
  if command -v adb_require_bash_advisory >/dev/null 2>&1; then
    adb_require_bash_advisory "$@" || exit 0
  fi
fi

# --- output ------------------------------------------------------------------

# Resolved once: both the event parser and the emitter need it.
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Emit at most one operator-visible line and stop. Uses jq when available (the correct structured
# channel); degrades to plain stdout otherwise, which reaches Claude rather than the operator —
# worse, but never wrong. `reload` adds hookSpecificOutput.reloadSkills, which asks the harness to
# re-read skill definitions after an update actually changed them on disk.
# Usage: say <message> [reload]
say() {
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -cn --arg m "$1" --arg r "${2:-}" \
      '{systemMessage: $m}
       + (if $r == "" then {}
          else {hookSpecificOutput: {hookEventName: "SessionStart", reloadSkills: true}} end)'
  else
    printf '%s\n' "$1"
  fi
  exit 0
}

# --- 1. only a genuinely new session ----------------------------------------

# The event JSON arrives on stdin. `jq` reads it correctly when present; the sed fallback keeps the
# SOURCE GATE — the safety gate — working on a box without it, rather than failing open.
# Usage: hook_field <name>
HOOK_INPUT="$(cat 2>/dev/null || true)"
hook_field() {
  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$HOOK_INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$HOOK_INPUT" \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

[ "$(hook_field source)" = "startup" ] || exit 0

# --- 2. the shared policy ------------------------------------------------------

# currency-lib.sh lives beside this script (install.sh symlinks scripts/lib into
# ~/.claude/scripts/lib). Absent → an incomplete install; stay silent rather than guess.
_adb_cu="$(dirname "$0")/lib/currency-lib.sh"
[ -f "$_adb_cu" ] || exit 0

# `cwd` comes from the event JSON (the session's directory, which need not be this process's);
# fall back to $PWD. The library uses it for the self-clone guard — never update the clone this
# very session is working in.
SESSION_CWD="$(hook_field cwd)"
[ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"

# One bounded call; one outcome record on stdout ("<outcome>\t<message>"). The library never exits
# non-zero for a policy outcome, and this hook cannot fail a session anyway.
RECORD="$(bash "$_adb_cu" check --trigger startup --cwd "$SESSION_CWD" 2>/dev/null)" || exit 0
# Split on the FIRST whitespace run rather than slicing on a literal TAB. The outcome is a single
# word by contract, so `read` gives it to $OUTCOME and every remaining byte to $MESSAGE — and it
# degrades correctly on a record with no separator at all (empty message) instead of needing a
# fixup. It also means no invisible tab character in this file is load-bearing.
{ read -r OUTCOME MESSAGE || true; } <<RECORD_EOF
$RECORD
RECORD_EOF

# --- 3. presentation ------------------------------------------------------------
#
# Three arms, because this hook differs from `/cleanup` in exactly TWO ways and nothing is served
# by spelling out the arms they agree on:
#
#   1. `updated`/`repaired` changed the installed payload, so ask the harness to re-read skills.
#   2. `busy` and `offline` are SILENT here. An unattended check at every session start must never
#      nag about a peer update or a missing network. `/cleanup` reports both, because there the
#      operator explicitly asked — that asymmetry is the whole reason the library returns a record
#      instead of a ready-made line.
#
# Everything else falls through to "say it if there is anything to say", which also means an
# outcome this mapping has not learned is REPORTED rather than silently swallowed. Silent staleness
# is the failure this hook exists to catch, so an unknown outcome must not inherit a reassuring
# silence. Outcomes that are not worth reporting carry an empty message by contract.
case "$OUTCOME" in
  updated|repaired)            say "baseline: $MESSAGE" reload ;;
  busy|offline)                exit 0 ;;
  *) [ -n "$MESSAGE" ] && say "baseline: $MESSAGE"; exit 0 ;;
esac

exit 0
