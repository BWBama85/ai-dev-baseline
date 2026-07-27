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

# Resolved once: both the event parser and the emitter need it.
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Emit at most one operator-visible line and stop. Uses jq when available (the correct
# structured channel); degrades to plain stdout otherwise, which reaches Claude rather than the
# operator — worse, but never wrong. `reload` adds hookSpecificOutput.reloadSkills, which asks
# the harness to re-read skill definitions after an update actually changed them on disk.
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

# The event JSON arrives on stdin. `jq` reads it correctly when present; the sed fallback keeps
# the SOURCE GATE — the safety gate — working on a box without it, rather than failing open.
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

# --- 2. library + mode --------------------------------------------------------

# The shared library lives beside this script (install.sh symlinks scripts/lib into
# ~/.claude/scripts/lib). Absent → an incomplete install; stay silent rather than guess.
_adb_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_adb_lib" ] || exit 0
# shellcheck source=/dev/null
. "$_adb_lib"

# Read the GLOBAL manifest — resolved by the shared primitive, so this reads exactly the file
# install.sh writes. Spelling the path here independently is how a config key silently does
# nothing. A PROJECT's agents.toml is never consulted (see the header).
MODE="${ADB_SESSION_UPDATE:-}"
if [ -z "$MODE" ]; then
  MODE="$(adb_toml_unquote "$(adb_toml_get "$(adb_global_manifest)" updates session_start 2>/dev/null)")"
fi
case "$MODE" in
  off)         exit 0 ;;
  notify|auto) ;;
  *)           MODE=auto ;;   # unset, misspelled, or unreadable → the documented default
esac

# --- 3. rate limit ------------------------------------------------------------
#
# Several sessions per hour is normal; a network round trip on each is not. The stamp records
# the last ATTEMPT (it is written just before `baseline` runs, below), deliberately: a run that
# fails or finds a peer already updating must not make the next session retry immediately and
# hit the same wall. Set the interval to 0 to check on every startup.
INTERVAL="${ADB_SESSION_UPDATE_INTERVAL_SECS:-600}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=600 ;; esac
STAMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ai-dev-baseline"
STAMP="$STAMP_DIR/session-currency.stamp"
if [ "$INTERVAL" -gt 0 ]; then
  # Empty = unknown age (no stamp yet, or an unreadable clock). Proceed with the check: the
  # safe direction here is a redundant fetch, never an indefinitely suppressed one.
  _age="$(adb_age_secs "$STAMP")"
  [ -n "$_age" ] && [ "$_age" -lt "$INTERVAL" ] && exit 0
fi

# --- 4. resolve the install-source -------------------------------------------

SRC="$(adb_install_source)" || exit 0   # nothing installed by symlink → nothing to keep current

# Never update the clone this very session is working in. `cwd` comes from the event JSON
# (the session's directory, which need not be this process's); fall back to $PWD. Comparing
# git ROOTS rather than raw paths means a session started in a subdirectory still matches, and
# `-ef` compares device+inode so two spellings of one clone are correctly seen as the same.
SESSION_CWD="$(hook_field cwd)"
[ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
# Compare the COMMON git dir, not the work-tree root: a linked worktree of the install-source is
# a different toplevel but the same repository, and fast-forwarding the main clone under it is
# the same surprise. --git-common-dir resolves to the shared .git for a worktree and to the
# ordinary .git otherwise, so one comparison covers both. `-ef` is device+inode, so two spellings
# of one path match. Falls back to the toplevel on a git too old to know the flag.
#
# Both sides must resolve the COMMON dir the same way. Falling back to --absolute-git-dir on one
# side would compare a worktree's own `.git/worktrees/<name>` against the main clone's `.git` —
# unequal, so the guard would silently miss exactly the case it was added for. --git-common-dir
# has existed far longer than --path-format, so the fallback asks for the same thing and just
# absolutizes it by hand.
common_git_dir() {
  local d="$1" out
  out="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  # Older git: --git-common-dir may print a path relative to <d>, so resolve it from there.
  out="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  ( cd "$d" 2>/dev/null && cd "$out" 2>/dev/null && pwd -P )
}
SESSION_GIT="$(common_git_dir "$SESSION_CWD" || true)"
SRC_GIT="$(common_git_dir "$SRC" || true)"
if [ -n "$SESSION_GIT" ] && [ -n "$SRC_GIT" ] && [ "$SESSION_GIT" -ef "$SRC_GIT" ]; then
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
# GIT_SSH_COMMAND outranks the repository's own `core.sshCommand`, so setting it unconditionally
# would replace a configured identity file / proxy / custom ssh binary with plain `ssh` — the
# fetch then fails for a clone that works perfectly from the command line, and exit 30 is
# deliberately silent, leaving the baseline stale with no explanation. Only install the default
# when the clone does not configure its own.
if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git -C "$SRC" config --get core.sshCommand 2>/dev/null)" ]; then
  export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'
fi
# Abort an HTTP transfer that has effectively stalled, so git fails cleanly (with a real error)
# instead of being killed mid-pull by the harness timeout — a kill is what leaves index locks.
[ -n "${GIT_HTTP_LOW_SPEED_LIMIT:-}" ] || export GIT_HTTP_LOW_SPEED_LIMIT=1000
[ -n "${GIT_HTTP_LOW_SPEED_TIME:-}" ]  || export GIT_HTTP_LOW_SPEED_TIME=15

# Record the attempt before running it. A crash or a harness kill mid-update must not make the
# next session retry immediately and hit the same wall on every start.
mkdir -p "$STAMP_DIR" 2>/dev/null && : > "$STAMP" 2>/dev/null

# --- 6. notify mode: report, change nothing ----------------------------------

if [ "$MODE" = "notify" ]; then
  # `behind` ONLY. templates/agents.toml and docs/installation.md both define notify as reporting
  # that you are behind, and it is the mode chosen precisely to be quiet — a clone deliberately
  # parked on a branch, or left ahead, would otherwise produce an attention line at every startup
  # past the rate limit, forever, for a state its owner created on purpose. `baseline update` says
  # so plainly when they run it. (auto still reports a refusal: it promised to act and could not,
  # and silence there would be the staleness this hook exists to catch.)
  STATUS="$("$SRC/bin/baseline" update --check 2>/dev/null | head -n1)"
  case "$STATUS" in
    behind) say "baseline: install-source is behind origin — run 'baseline update'." ;;
  esac
  exit 0
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
  6)
    # A same-HEAD repair: already current, but a broken installed link was restored. HEAD did not
    # move, so the delta check above cannot see it — and the skill that was missing when this
    # session initialized is available again only if the harness re-reads them.
    say "baseline: repaired the installed links (clone already current)." reload
    ;;
  5)  exit 0 ;;   # a peer session is already updating this clone — its line covers it
  20)
    # Refused for safety. Name the state so the operator knows which one. No re-fetch is needed
    # or wanted: `baseline` has already fetched if it got that far, so the refs are current.
    say "baseline: install-source not updated ($(adb_clone_status "$SRC" "$(adb_default_branch "$SRC")" 2>/dev/null)) — reconcile $SRC, then 'baseline update'."
    ;;
  30) exit 0 ;;   # offline / unresolvable remote — never nag about a missing network
  *)
    # Includes exit 1: git advanced but the install did not fully heal. That one MUST be loud —
    # a half-repaired global install is the silent-staleness failure this hook exists to prevent.
    if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ]; then
      say "baseline: clone updated $BEFORE → $AFTER but the global install needs repair — run 'baseline update'."
    else
      say "baseline: 'baseline update' failed (exit $RC) — run it manually to see why."
    fi
    ;;
esac

exit 0
