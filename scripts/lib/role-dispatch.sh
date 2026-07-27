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
# Every invocation is bounded by the 45-min hang backstop — see _ADB_RD_TIMEOUT_SECS below for
# what that means and why the figure is where it is.

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
_ADB_RD_GLOBAL_TOML="$(adb_global_manifest)"

# The per-invocation HANG BACKSTOP (seconds); 45-min (2700 s) matches the backstop-* facts in
# scripts/check-fact-drift.sh. It is a backstop, NOT a work budget: it exists to stop a wedged
# process, so it belongs well above the longest legitimate run rather than near the typical one.
# The previous default sat near typical runtime and so killed ordinary high-reasoning passes (#93).
# Applies to EVERY agent and role this helper dispatches (claude / codex / gemini; gap_analysis and
# review alike) — not only codex gap analysis — because it wraps every invocation below.
# ADB_DISPATCH_TIMEOUT_SECS overrides it, but a stock clone needs no environment at all.
_ADB_RD_TIMEOUT_SECS="${ADB_DISPATCH_TIMEOUT_SECS:-2700}"
# WHOLE SECONDS only, validated loudly. `timeout` accepts a fractional DURATION, but this helper
# also compares the bound arithmetically (the 137→124 normalization) and counts it down in the
# portable watchdog — both integer-only in POSIX shell. An unvalidated `0.5` therefore produced
# `[: 0.5: integer expression expected` and fired the bound instantly, i.e. every dispatch failed
# at once. A hang backstop has no legitimate sub-second use, so reject rather than support it.
case "$_ADB_RD_TIMEOUT_SECS" in
  ''|*[!0-9]*|0)
    printf 'role-dispatch: ADB_DISPATCH_TIMEOUT_SECS="%s" is not a positive whole number of seconds — using the %ss default\n' \
      "$_ADB_RD_TIMEOUT_SECS" 2700 >&2
    _ADB_RD_TIMEOUT_SECS=2700 ;;
esac

# How long a TERM'd child gets to exit before the backstop escalates to KILL. Escalation is what
# makes the backstop a backstop at all — see _adb_rd_bounded. ADB_DISPATCH_KILL_GRACE_SECS is a
# TEST SEAM, not an operator knob (nobody tunes a SIGKILL grace); the unit test shortens it so the
# escalation cases don't each burn the full grace. Same status as ADB_DISPATCH_NO_TIMEOUT_BIN.
_ADB_RD_KILL_GRACE_SECS="${ADB_DISPATCH_KILL_GRACE_SECS:-10}"
# Clamped here so THIS VARIABLE's contract holds for anyone reading it (the unit test asserts its
# value directly). `adb_run_bounded` clamps its own `grace` argument too, for the same reasons,
# documented once at that function — it is a shared primitive and must validate what it is handed,
# not assume a caller pre-clamped. Two guards, one rule, stated in one place.
case "$_ADB_RD_KILL_GRACE_SECS" in
  ''|*[!0-9]*) _ADB_RD_KILL_GRACE_SECS=10 ;;
  *)           [ "$_ADB_RD_KILL_GRACE_SECS" -eq 0 ] && _ADB_RD_KILL_GRACE_SECS=1 ;;
esac

# --- resolution --------------------------------------------------------------------------------

# True iff $1 is EXACTLY a known agent token. Compares against each token rather than a
# substring test — ` *" $1 "* ` would accept a space-joined typo like "claude codex" because
# that run of text occurs inside the allowlist string.
_adb_rd_valid_token() {
  local t
  # shellcheck disable=SC2086  # intentional word-split of the space-separated token list
  for t in $_ADB_RD_KNOWN; do [ "$1" = "$t" ] && return 0; done
  return 1
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
  local raw val
  if raw="$(_adb_rd_layered_get roles primary)"; then
    # primary is a single-owner role: an array or an empty value is malformed and must SURFACE,
    # not silently reroute (taking the first of a list, or defaulting to claude) — because every
    # other role can inherit from primary, so a bad primary quietly rewires the whole workflow.
    case "$raw" in
      \[*) printf 'role-dispatch: [roles].primary must be a single agent, not a list\n' >&2; return 2 ;;
    esac
    val="$(adb_toml_unquote "$raw")"
    if [ -z "$val" ]; then
      printf 'role-dispatch: [roles].primary is empty — set it to a known agent (%s)\n' "$_ADB_RD_KNOWN" >&2
      return 2
    fi
  else
    val="claude"   # UNSET in every manifest → the built-in default
  fi
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
    # Only `review` has list cardinality; every other role is single-owner, so an array is
    # malformed config that must surface here — not be accepted and then rejected later at invoke.
    if [ "$role" != review ]; then
      printf 'role-dispatch: [roles].%s must be a single agent, not a list (only review may list multiple)\n' "$role" >&2
      return 2
    fi
    elems="$(adb_toml_array "$raw")"
    if [ -z "$elems" ]; then
      # An explicit empty array is a configuration mistake, not a way to disable review — leaving
      # the key UNSET is the documented way to get the primary's own pass (base/roles.md). Reject.
      printf 'role-dispatch: [roles].review = [] is invalid — leave it unset to use the primary'\''s own review pass, or list agent(s)\n' >&2
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
    # Present but not an array (e.g. bots = "x") is malformed — reject it rather than let
    # adb_toml_array emit nothing and be mistaken for the intentional `bots = []` disable.
    case "$raw" in
      \[*) adb_toml_array "$raw"; return 0 ;;
      *)   printf 'role-dispatch: [reviewers].bots must be an array (e.g. ["a[bot]","b"]) — use [] to disable\n' >&2; return 2 ;;
    esac
  fi
  printf '%s\n' \
    'chatgpt-codex-connector' \
    'gemini-code-assist[bot]' 'gemini-code-assist' \
    'copilot-pull-request-reviewer[bot]' 'copilot[bot]' \
    'github-actions[bot]' \
    'claude[bot]' 'claude-code[bot]'
}

# --- invocation --------------------------------------------------------------------------------

# Run <argv> with the hang backstop. THE mechanism lives once in common.sh as `adb_run_bounded`
# (shared with currency-lib.sh, which bounds `baseline update`); this wrapper only binds the two
# dispatch-specific knobs so callers here keep the one-argument form. Copying the watchdog instead
# would be the duplicate-detector drift #131 was filed about.
#
# Returns the child's status, or 124 when the bound fired. stdin/stdout/stderr are whatever the
# caller redirected. ADB_DISPATCH_NO_TIMEOUT_BIN=1 still forces the portable watchdog path.
_adb_rd_bounded() {
  local secs="$1"; shift
  adb_run_bounded "$secs" "$_ADB_RD_KILL_GRACE_SECS" "$@"
}

# Classify a dispatch exit status in one line. Collapsing every non-zero rc into "the agent
# failed" is precisely what let a too-small bound masquerade as a codex problem for three runs
# (#93): our own backstop, an OUTER bound, and a genuine agent error each warrant a different
# response, so name which one happened rather than making the reader infer it.
adb_dispatch_classify_rc() {
  case "$1" in
    0)   printf 'completed' ;;
    124) printf 'INCOMPLETE: our %ss hang backstop fired — the work genuinely outran it; raise ADB_DISPATCH_TIMEOUT_SECS' "$_ADB_RD_TIMEOUT_SECS" ;;
    143) printf 'INCOMPLETE: SIGTERM (rc 143) — an OUTER bound killed it before our %ss backstop; re-dispatch in the background, or raise THAT bound (ours is not the cap here)' "$_ADB_RD_TIMEOUT_SECS" ;;
    137) printf 'INCOMPLETE: SIGKILL (rc 137) — killed from outside this helper (OOM killer or an outer harness), not by our backstop' ;;
    *)   printf 'INCOMPLETE: agent exited %s — a real agent/CLI error, not a bound firing' "$1" ;;
  esac
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

# Emit the one-line classified outcome of a failed dispatch: `<role> (<agent>) — <classification>`.
# Always stderr — stdout is reserved for the agent's clean final message (#8) — and silent on
# success, so a failure is the only thing the operator sees.
#
# Naming the ROLE, not just the agent token, is what lets this line carry the role's fallback
# policy. That matters most for `gap_analysis`, whose policy is "never substitute another agent":
# stating it at the moment of failure puts it where the operator (or agent) is actually deciding
# what to do next, rather than only in prose several hundred lines up a workflow doc — the layer
# that already failed three times (#93).
# Usage: _adb_rd_report <role-or-token> <agent-token> <rc>
_adb_rd_report() {
  [ "$3" -eq 0 ] && return 0
  local who="$1"
  [ "$1" = "$2" ] || who="$1 ($2)"
  printf 'role-dispatch: %s — %s\n' "$who" "$(adb_dispatch_classify_rc "$3")" >&2
  [ "$1" = gap_analysis ] && printf 'role-dispatch: gap_analysis does NOT fall back — surface this as a %s incompleteness; do not substitute another agent.\n' "$2" >&2
  return 0
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
    _adb_rd_invoke_agent "$target" "$pf"; rc=$?; rm -f "$pf"
    _adb_rd_report "$target" "$target" "$rc"; return "$rc"
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
  _adb_rd_invoke_agent "$tokens" "$pf"; rc=$?; rm -f "$pf"
  _adb_rd_report "$target" "$tokens" "$rc"; return "$rc"
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
