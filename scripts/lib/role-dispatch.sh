#!/usr/bin/env bash
# ai-dev-baseline — runtime role-dispatch helper (issue #15).
#
# Reads a repo's agents.toml, resolves a ROLE to the AGENT(s) configured for it, and — for a
# single-agent role — dispatches the work to that agent's non-interactive CLI. It is the
# programmatic embodiment of base/roles.md's resolution order and cross-agent invocation table,
# so a workflow shells to `role-dispatch.sh resolve <role>` / `invoke <role>` instead of
# hand-writing the same lookup + CLI incantation in every skill.
#
# Resolution order (base/roles.md): the repo's own agents.toml [roles] → the global default
# manifest at ~/.config/ai-dev-baseline/agents.toml → the built-in default in the role table.
# An invalid value at a higher-precedence layer is a hard error, never a silent fall-through to
# the next layer (a typo'd or empty-array role must surface, not degrade).
#
# Surfaces:
#   role-dispatch.sh resolve <role>          # print the agent token(s), one per line (empty = skip)
#   role-dispatch.sh invoke  <role|agent>    # prompt on STDIN → run that agent's CLI; clean stdout
#   role-dispatch.sh bots                    # print the configured async external-bot reviewer logins
# The `bots` surface makes this the one runtime reader of the agents.toml manifest (roles AND the
# `[reviewers]` bot allowlist), rather than standing up a second helper + install seam for it.
# Sourced use: `. role-dispatch.sh` then call `adb_resolve_role <role>` / `adb_dispatch_bots`
# in-process (the CLI dispatch below is guarded so sourcing defines the functions without running).
#
# Cross-agent invocation (canonical home: base/roles.md; pinned by scripts/check-fact-drift.sh):
#   claude → claude -p "<prompt>"            (stdout is the final message)
#   codex  → codex exec --cd <repo> -        (prompt on stdin; --output-last-message = clean final msg)
#   gemini → agy -p "<prompt>"               (Antigravity CLI; stdout is the final message)
# codex exec reads the whole repo and routinely runs 3–7 min, so every invocation is given a
# ≥7-min (420 s) bound (ADB_DISPATCH_TIMEOUT_SECS) — the helper's own inner watchdog, on top of
# whatever outer bound the caller's shell imposes.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib). Without it the TOML reads silently vanish and every resolution reads
# as "no config" — enforcement/config secretly wrong — so a missing library FAILS LOUD.
_adb_rd_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_rd_common" ]; then
  printf 'role-dispatch: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_rd_common" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$_adb_rd_common"
if ! command -v adb_toml_get >/dev/null 2>&1 \
   || ! command -v adb_toml_unquote >/dev/null 2>&1 \
   || ! command -v adb_toml_array >/dev/null 2>&1; then
  printf 'role-dispatch: FATAL — %s is missing a required helper (adb_toml_get/unquote/array)\n' "$_adb_rd_common" >&2
  return 1 2>/dev/null || exit 1
fi

# --- config ------------------------------------------------------------------------------------
# The known agent tokens. Kept in sync with base/roles.md's "Agent tokens" list; adding an agent
# (docs/adding-an-agent.md) means adding its token here so the validator accepts it.
_ADB_RD_KNOWN="claude codex gemini"

# The repo manifest is resolved relative to the repo the caller is in (git top-level, else CWD,
# via the shared adb_repo_root), so the helper works the same whether run from a skill mid-task or
# a unit test in a temp dir.
_ADB_RD_REPO_TOML="$(adb_repo_root)/agents.toml"
# The global default manifest install.sh writes. HOME-relative, so a test that overrides HOME
# points it at a throwaway global manifest with no extra seam.
_ADB_RD_GLOBAL_TOML="${HOME:-/root}/.config/ai-dev-baseline/agents.toml"

# The per-invocation timeout bound (seconds). ≥7-min (420 s) matches the codex-timeout fact.
_ADB_RD_TIMEOUT_SECS="${ADB_DISPATCH_TIMEOUT_SECS:-420}"

# --- resolution --------------------------------------------------------------------------------

# True iff $1 is a known agent token.
_adb_rd_valid_token() {
  case " $_ADB_RD_KNOWN " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Print the raw [<section>].<key> value from the repo manifest, else the global manifest; return 0
# if found in EITHER (repo wins, and — crucially — a repo value is returned even when invalid, so
# resolution never falls through a bad higher-precedence value to the next layer). Return 1 when
# neither manifest defines the key. The ONE home for the repo→global precedence — both the role
# lookup (`roles`) and the bot allowlist (`reviewers`) go through it, so the order can't drift.
_adb_rd_layered_get() {
  local section="$1" key="$2" raw
  if raw="$(adb_toml_get "$_ADB_RD_REPO_TOML"   "$section" "$key")"; then printf '%s' "$raw"; return 0; fi
  if raw="$(adb_toml_get "$_ADB_RD_GLOBAL_TOML" "$section" "$key")"; then printf '%s' "$raw"; return 0; fi
  return 1
}

# The built-in default for a role that is UNSET or set to "": gap_analysis skips (no output, 0
# status); every other role falls back to the primary. (primary itself is resolved directly by
# adb_resolve_primary, so it never reaches here.) One home, so the two callers can't diverge.
_adb_rd_role_default() {
  case "$1" in
    gap_analysis) return 0 ;;
    *)            adb_resolve_primary; return $? ;;
  esac
}

# Resolve `primary` to exactly one concrete, validated agent token. The built-in default is
# `claude`. Resolved on its own (never via the @primary fallback recursion) so the other roles'
# "default to primary" can reuse it without a resolution loop.
adb_resolve_primary() {
  local raw val=""
  if raw="$(_adb_rd_layered_get roles primary)"; then
    case "$raw" in
      \[*) val="$(adb_toml_array "$raw" | head -n1)" ;;   # tolerate a mistaken array; take the first
      *)   val="$(adb_toml_unquote "$raw")" ;;
    esac
  fi
  [ -n "$val" ] || val="claude"
  if ! _adb_rd_valid_token "$val"; then
    printf 'role-dispatch: [roles].primary = "%s" is not a known agent (known: %s)\n' "$val" "$_ADB_RD_KNOWN" >&2
    return 2
  fi
  printf '%s\n' "$val"
}

# Resolve a role to its agent token(s), one per line. Empty output with a 0 status means "skip"
# (only `gap_analysis` resolves that way). A 2 status means an invalid manifest value (unknown
# agent token, or an explicit empty `review = []`) — surfaced, never silently degraded.
adb_resolve_role() {
  local role="$1" raw val elems tok bad=0

  case "$role" in
    primary) adb_resolve_primary; return $? ;;
    gap_analysis|review|debug|issue_author|release) ;;
    *) printf 'role-dispatch: unknown role "%s"\n' "$role" >&2; return 2 ;;
  esac

  if ! raw="$(_adb_rd_layered_get roles "$role")"; then
    _adb_rd_role_default "$role"; return $?     # unset in every manifest → built-in default
  fi

  case "$raw" in
  \[*)
    elems="$(adb_toml_array "$raw")"
    if [ -z "$elems" ]; then
      # An explicit empty array is a configuration mistake, not a way to disable review — leaving
      # the key UNSET is the documented way to get the primary's own pass (base/roles.md). Reject.
      printf 'role-dispatch: [roles].%s = [] is invalid — leave it unset to use the primary'\''s own review pass, or list agent(s)\n' "$role" >&2
      return 2
    fi
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      _adb_rd_valid_token "$tok" || {
        printf 'role-dispatch: [roles].%s lists unknown agent "%s" (known: %s)\n' "$role" "$tok" "$_ADB_RD_KNOWN" >&2
        bad=1
      }
    done <<EOF
$elems
EOF
    [ "$bad" -eq 0 ] || return 2
    printf '%s\n' "$elems"
    return 0
    ;;
  esac

  # scalar value
  val="$(adb_toml_unquote "$raw")"
  if [ -z "$val" ]; then
    _adb_rd_role_default "$role"; return $?     # "" → skip (gap_analysis) or the primary's own pass
  fi
  if ! _adb_rd_valid_token "$val"; then
    printf 'role-dispatch: [roles].%s = "%s" is not a known agent (known: %s)\n' "$role" "$val" "$_ADB_RD_KNOWN" >&2
    return 2
  fi
  printf '%s\n' "$val"
}

# --- async external-bot reviewers (issue #26) --------------------------------------------------
# A first-class notion of a reviewer that posts AFTER the PR opens (a GitHub App bot such as the
# Codex connector), distinct from the in-session `review` role agents. The set of known bot
# logins lives in agents.toml `[reviewers] bots = [...]`; `/resolve-pr-threads` derives the
# logins it may auto-resolve from here, so the manifest is the single source. An explicit
# `bots = []` intentionally disables auto-resolution (distinct from an invalid `review = []`).

# Print the configured async external-bot reviewer logins, one per line. If `[reviewers] bots`
# is set (even to []) that is authoritative; if unset, the built-in default allowlist of the
# common GitHub review bots is printed. These are EXACT logins (an anchored allowlist), never a
# `[bot]`-suffix heuristic — so the matcher can never catch a human login.
# NOTE: this default set is pinned to base/workflows/resolve-pr-threads.md by check-fact-drift.sh
# (fact `reviewer-bots-default`) — change a login here and the doc must change too, or CI fails.
adb_dispatch_bots() {
  local raw
  if raw="$(_adb_rd_layered_get reviewers bots)"; then
    adb_toml_array "$raw"
    return 0
  fi
  printf '%s\n' \
    'chatgpt-codex-connector' \
    'gemini-code-assist[bot]' 'gemini-code-assist' \
    'copilot-pull-request-reviewer[bot]' 'copilot[bot]' \
    'github-actions[bot]' \
    'claude[bot]' 'claude-code[bot]'
}

# --- invocation --------------------------------------------------------------------------------

# Run <argv> with a ≥7-min bound. Prefers a real timeout binary (GNU `timeout` on Linux CI,
# `gtimeout` from coreutils on macOS); when neither exists (a stock Mac) it falls back to a
# bash-3.2-safe background watchdog. Returns the child's status, or 124 when the bound fired
# (matching GNU timeout's convention). stdin/stdout/stderr are whatever the caller redirected.
# ADB_DISPATCH_NO_TIMEOUT_BIN=1 forces the watchdog path (exercised by the unit test).
_adb_rd_bounded() {
  local secs="$1"; shift
  if [ "${ADB_DISPATCH_NO_TIMEOUT_BIN:-0}" != "1" ]; then
    if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  fi
  local flag rc
  flag="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-flag-$$")"; rm -f "$flag"
  # `<&0` is load-bearing: a backgrounded command in a non-interactive shell has its stdin
  # redirected from /dev/null UNLESS it carries an explicit redirection. The caller's `< "$pf"`
  # is on THIS function's invocation, not on the inner `&`, so without `<&0` the child (codex,
  # fed its prompt on stdin) would read /dev/null — an empty prompt. Duping fd 0 in suppresses
  # the /dev/null substitution; harmless for claude/gemini (their prompt is in argv).
  "$@" <&0 & local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null && : > "$flag"; ) </dev/null >/dev/null 2>&1 &
  local watcher=$!
  wait "$cmd_pid" 2>/dev/null; rc=$?
  kill -TERM "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  if [ -f "$flag" ]; then rm -f "$flag"; return 124; fi
  rm -f "$flag"; return "$rc"
}

# Invoke ONE concrete agent's CLI with the prompt from file $2; the agent's clean FINAL message
# goes to this function's stdout, its exploration/log stream to stderr. Returns the CLI's status
# (124 on timeout); for codex, a 0 exit that produced no final message is treated as incomplete
# (return 1) rather than a clean empty pass.
_adb_rd_invoke_agent() {
  local token="$1" pf="$2" repo rc last
  case "$token" in
    claude)
      _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" claude -p "$(cat "$pf")"
      return $?
      ;;
    gemini)
      _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" agy -p "$(cat "$pf")"
      return $?
      ;;
    codex)
      # Reuse the repo root already resolved for _ADB_RD_REPO_TOML rather than a second git call
      # (only codex's --cd needs it).
      repo="$(dirname "$_ADB_RD_REPO_TOML")"
      last="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-last-$$")"; : > "$last"
      # Route codex's live stream to stderr (visible for debugging, NOT mixed into our stdout);
      # --output-last-message captures only the final agent message (#8).
      _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" \
        codex exec --cd "$repo" --output-last-message "$last" - < "$pf" >&2
      rc=$?
      if [ "$rc" -ne 0 ]; then rm -f "$last"; return "$rc"; fi
      if [ ! -s "$last" ]; then
        printf 'role-dispatch: codex exited 0 but wrote no final message — treating as incomplete\n' >&2
        rm -f "$last"; return 1
      fi
      cat "$last"; rm -f "$last"; return 0
      ;;
    *)
      printf 'role-dispatch: cannot invoke unknown agent "%s"\n' "$token" >&2; return 2
      ;;
  esac
}

# Dispatch a prompt (on STDIN) to a role or an explicit agent token. A role that resolves to
# ONE agent is invoked; a multi-agent role (a `review` list) is refused with guidance to use
# `resolve` + a per-slot `invoke <token>` loop (so same-agent slots stay in-process and each
# slot keeps its own retry/fallback — never one opaque multi-agent call). An unassigned role
# returns 3 (distinct from a completed empty result), so a caller never mistakes "skipped" for
# "ran and found nothing".
adb_dispatch_invoke() {
  local target="$1" pf tokens count rc
  pf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-prompt-$$")"
  cat > "$pf"

  if _adb_rd_valid_token "$target"; then
    _adb_rd_invoke_agent "$target" "$pf"; rc=$?; rm -f "$pf"; return "$rc"
  fi

  if ! tokens="$(adb_resolve_role "$target")"; then rm -f "$pf"; return 2; fi
  if [ -z "$tokens" ]; then
    printf 'role-dispatch: role "%s" is unassigned — nothing invoked\n' "$target" >&2
    rm -f "$pf"; return 3
  fi
  count="$(printf '%s\n' "$tokens" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    printf 'role-dispatch: role "%s" resolves to multiple agents (%s) — use "resolve %s" then "invoke <token>" per slot\n' \
      "$target" "$(printf '%s' "$tokens" | tr '\n' ' ')" "$target" >&2
    rm -f "$pf"; return 2
  fi
  _adb_rd_invoke_agent "$tokens" "$pf"; rc=$?; rm -f "$pf"; return "$rc"
}

# --- dispatch (only when executed directly, never when sourced) --------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    resolve) adb_resolve_role "${2:-}" ;;
    invoke)  [ "$#" -ge 2 ] || { echo "usage: role-dispatch.sh invoke <role|agent>" >&2; exit 2; }
             adb_dispatch_invoke "$2" ;;
    bots)    adb_dispatch_bots ;;
    *) echo "usage: role-dispatch.sh [resolve <role> | invoke <role|agent> | bots]" >&2; exit 2 ;;
  esac
fi
