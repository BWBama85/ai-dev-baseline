#!/usr/bin/env bash
# ai-dev-baseline — SessionStart currency hook (issue #36).
#
# Keeps the INSTALLED baseline current without the operator remembering anything. The global
# install is a set of symlinks into one clone (the "install-source"); when that clone lags
# origin, every project on the machine silently runs stale skills, practices, and gates. That is
# not hypothetical: the operator's clone once sat one commit behind while `/roadmap` computed a
# release verdict with the *pre-fix* logic, minutes after shipping the fix.
#
# `bin/baseline update` already does the work safely. This hook is the trigger — it decides
# WHEN running it is safe and free of surprises, and reduces the outcome to at most one line.
#
# CONTRACT WITH THE HARNESS (docs: https://code.claude.com/docs/en/hooks)
#   - SessionStart CANNOT block a session. A non-zero exit only renders a hook-error notice in
#     the transcript, so this script exits 0 on EVERY path — including its own bugs. Currency is
#     a convenience; it must never be the reason a session looks broken.
#   - Plain stdout on exit 0 is injected into CLAUDE's context. Structured JSON is parsed
#     instead, and `systemMessage` is the OPERATOR-visible channel. The operator is who acts on
#     "your install needs attention", so the line goes there — and nothing is printed at all when
#     the install is current, which is the overwhelmingly common case.
#
# WHEN IT ACTS
#   - `source: startup` only. `clear` and `compact` happen MID-SESSION (this repo's own loop
#     ends every batch with `/clear`), `fork` runs beside a live parent, and `resume` continues
#     a conversation whose tooling was loaded earlier. Swapping tooling under any of those is
#     the "surprising mid-session change" the design deliberately avoids; a new session is the
#     clean slate. The settings matcher already narrows this, but the check is repeated here so
#     the guarantee does not depend on the harness honoring a matcher.
#   - Never when the session's OWN repo is the install-source: updating the clone you are
#     working in is exactly the "pulled out from under active work" case. (A session in any
#     OTHER project still updates it — that is the whole point.)
#   - Never over unsafe clone state. `bin/baseline` decides that (dirty / mid-rebase / detached
#     / non-default / ahead / diverged are all refused), so this hook does not re-derive it.
#
# MODE, and where it is configured — GLOBAL only:
#   ~/.config/ai-dev-baseline/agents.toml  ->  [updates] session_start = "auto"|"notify"|"off"
#   auto (default) pulls + self-heals · notify only reports · off disables the hook entirely.
#   A PROJECT's agents.toml is deliberately NOT read: an arbitrary repo you happen to open must
#   not control whether your global tooling updates. ADB_SESSION_UPDATE overrides both (tests,
#   CI, one-off runs).
#
# Every path is bounded: rate-limited between runs, git is barred from interactive prompting,
# and the settings entry carries its own timeout as a far backstop.

set -u

# Always exit 0 — see the harness contract above. Registered before anything else can fail, so
# even a syntax-level surprise in a sourced library cannot turn into a session-start error.
trap 'exit 0' EXIT

# --- output ------------------------------------------------------------------

# Emit at most one operator-visible line and stop. Uses jq when available (the correct
# structured channel); degrades to plain stdout otherwise, which reaches Claude rather than the
# operator — worse, but never wrong. `reload` adds hookSpecificOutput.reloadSkills, which asks
# the harness to re-read skill definitions after an update actually changed them on disk.
# Usage: say <message> [reload]
say() {
  local msg="$1" reload="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    if [ -n "$reload" ]; then
      jq -cn --arg m "$msg" \
        '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", reloadSkills: true}}'
    else
      jq -cn --arg m "$msg" '{systemMessage: $m}'
    fi
  else
    printf '%s\n' "$msg"
  fi
  exit 0
}

# --- 1. only a genuinely new session ----------------------------------------

# The event JSON arrives on stdin. `jq` reads it correctly when present; the sed fallback keeps
# the SOURCE GATE — the safety gate — working on a box without it, rather than failing open.
# Usage: hook_field <name>
HOOK_INPUT="$(cat 2>/dev/null || true)"
hook_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$HOOK_INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$HOOK_INPUT" \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
  fi
}

[ "$(hook_field source)" = "startup" ] || exit 0

# --- 2. library + mode --------------------------------------------------------

# The shared library lives beside this script (install.sh symlinks scripts/lib into
# ~/.claude/scripts/lib). Absent → an incomplete install; stay silent rather than guess.
_adb_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_adb_lib" ] || exit 0
# shellcheck source=/dev/null
. "$_adb_lib"

MODE="${ADB_SESSION_UPDATE:-}"
if [ -z "$MODE" ]; then
  GLOBAL_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/ai-dev-baseline/agents.toml"
  MODE="$(adb_toml_unquote "$(adb_toml_get "$GLOBAL_TOML" updates session_start 2>/dev/null)")"
fi
case "$MODE" in
  off)         exit 0 ;;
  notify|auto) ;;
  *)           MODE=auto ;;   # unset, misspelled, or unreadable → the documented default
esac

# --- 3. rate limit ------------------------------------------------------------
#
# Several sessions per hour is normal; a network round trip on each is not. The stamp records
# the last COMPLETED check, so a skipped or locked run never suppresses the next one. Set the
# interval to 0 to check on every startup.
INTERVAL="${ADB_SESSION_UPDATE_INTERVAL_SECS:-600}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=600 ;; esac
STAMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-dev-baseline"
STAMP="$STAMP_DIR/session-currency.stamp"
if [ "$INTERVAL" -gt 0 ] && [ -f "$STAMP" ]; then
  _last="$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null)"
  _now="$(date +%s 2>/dev/null)"
  if [ -n "$_last" ] && [ -n "$_now" ] && [ "$((_now - _last))" -lt "$INTERVAL" ]; then
    exit 0
  fi
fi

# --- 4. resolve the install-source -------------------------------------------

SRC="$(adb_install_source)" || exit 0   # nothing installed by symlink → nothing to keep current

# Never update the clone this very session is working in. `cwd` comes from the event JSON
# (the session's directory, which need not be this process's); fall back to $PWD. Comparing
# git ROOTS rather than raw paths means a session started in a subdirectory still matches, and
# `-ef` compares device+inode so two spellings of one clone are correctly seen as the same.
SESSION_CWD="$(hook_field cwd)"
[ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
SESSION_ROOT="$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$SESSION_ROOT" ] && [ "$SESSION_ROOT" -ef "$SRC" ]; then
  exit 0
fi

# --- 5. bound git's network + interaction ------------------------------------
#
# A session start must never sit behind a credential prompt or a stalled transfer. Without
# these, an HTTPS remote with no cached credential blocks on a terminal read FOREVER — the one
# failure mode a timeout cannot make graceful. Each is set only when the operator has not set
# it themselves, so a deliberate local git configuration always wins.
[ -n "${GIT_TERMINAL_PROMPT:-}" ] || export GIT_TERMINAL_PROMPT=0
[ -n "${GIT_ASKPASS:-}" ]         || export GIT_ASKPASS=true
[ -n "${SSH_ASKPASS:-}" ]         || export SSH_ASKPASS=true
[ -n "${GIT_SSH_COMMAND:-}" ]     || export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'
# Abort an HTTP transfer that has effectively stalled, so git fails cleanly (with a real error)
# instead of being killed mid-pull by the harness timeout — a kill is what leaves index locks.
[ -n "${GIT_HTTP_LOW_SPEED_LIMIT:-}" ] || export GIT_HTTP_LOW_SPEED_LIMIT=1000
[ -n "${GIT_HTTP_LOW_SPEED_TIME:-}" ]  || export GIT_HTTP_LOW_SPEED_TIME=15

# Record the attempt before running it. A crash or a harness kill mid-update must not make the
# next session retry immediately and hit the same wall on every start.
mkdir -p "$STAMP_DIR" 2>/dev/null && : > "$STAMP" 2>/dev/null

DEFAULT_BRANCH="$(adb_default_branch "$SRC" 2>/dev/null)"
[ -n "$DEFAULT_BRANCH" ] || exit 0

# --- 6. notify mode: report, change nothing ----------------------------------

if [ "$MODE" = "notify" ]; then
  STATUS="$("$SRC/bin/baseline" update --check 2>/dev/null | head -n1)"
  case "$STATUS" in
    current|'')  exit 0 ;;
    behind)      say "baseline: install-source is behind origin — run 'baseline update'." ;;
    fetch-failed) exit 0 ;;   # offline is not news; a plain start should not nag about it
    *)           say "baseline: install-source needs attention ($STATUS) — see 'baseline update'." ;;
  esac
fi

# --- 7. auto mode: update ------------------------------------------------------
#
# One invocation, one fetch. The outcome is read from the EXIT CODE and the before/after HEAD,
# never by parsing `baseline`'s human-facing prose — prose is free to change, the contract is not.
BEFORE="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || true)"
"$SRC/bin/baseline" update >/dev/null 2>&1
RC=$?
AFTER="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || true)"

case "$RC" in
  0)
    # Unchanged HEAD means it was already current (or self-healed a link) — nothing worth a line.
    [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ] || exit 0
    N="$(git -C "$SRC" rev-list --count "$BEFORE..$AFTER" 2>/dev/null)"
    case "$N" in ''|*[!0-9]*) N="" ;; esac
    if [ "$N" = "1" ]; then
      say "baseline: updated $BEFORE → $AFTER (1 commit)." reload
    elif [ -n "$N" ]; then
      say "baseline: updated $BEFORE → $AFTER ($N commits)." reload
    else
      say "baseline: updated $BEFORE → $AFTER." reload
    fi
    ;;
  5)  exit 0 ;;   # a peer session is already updating this clone — its line covers it
  20)
    # Refused for safety. Name the state so the operator knows which one, without re-fetching:
    # the classification is local-only, and `baseline` has already fetched if it got that far.
    STATE="$(adb_clone_local_state "$SRC" "$DEFAULT_BRANCH" 2>/dev/null)"
    [ "$STATE" = "local-ok" ] && STATE="$(adb_branch_sync_state "$SRC" "$DEFAULT_BRANCH" 2>/dev/null)"
    say "baseline: install-source not updated ($STATE) — reconcile $SRC, then 'baseline update'."
    ;;
  30) exit 0 ;;   # offline / unresolvable remote — never nag about a missing network
  *)
    # Includes exit 1: git advanced but the install did not fully heal. That one MUST be loud —
    # a half-repaired global install is the silent-staleness failure this hook exists to prevent.
    if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ]; then
      say "baseline: clone updated $BEFORE → $AFTER but the global install needs repair — run 'baseline update'."
    fi
    say "baseline: 'baseline update' failed (exit $RC) — run it manually to see why."
    ;;
esac

exit 0
