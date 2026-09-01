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
#   role-dispatch.sh invoke  <role|agent> [--effort <v>]  # prompt on STDIN → run that CLI; clean stdout
#   role-dispatch.sh effort  <role>          # the reasoning effort for that role (empty+rc1 = inherit)
#   role-dispatch.sh available <agent>       # is that agent's CLI on PATH here? (silent; rc 0/1/2)
#   role-dispatch.sh review-rung [<driver>]  # what will actually review a diff: independent|same-model|deferred|none|unknown
#   role-dispatch.sh bots                    # print the configured async external-bot reviewer logins
#   role-dispatch.sh bots --declared         # the same key as a TRI-STATE, no default (0/2/3)
#   role-dispatch.sh bots --comparable       # the declared set normalized for matching (0/17/18)
#   role-dispatch.sh untrusted <source>      # stdin = third-party text → a containment-safe JSON envelope
# `untrusted` belongs to THIS helper rather than a new one, and the charter question is fair enough
# to answer rather than wave at (raised in review of #214): serialization on its own has nothing to
# do with roles. What places it here is WHO CALLS IT. Its only callers are the sites that build a
# prompt for a dispatched agent — `/implement-issue` steps 3 and 8 — which is exactly the
# hand-written-per-skill incantation this file exists to absorb, and the prompt is this file's
# input. The alternatives were worse in the ways this repo already has opinions about: a new
# `untrusted-lib.sh` adds an install seam and a third one-function library, and common.sh is SOURCED
# rather than executed, so a workflow cannot reach it without one. The envelope itself does live in
# common.sh — `adb_untrusted_block`, the ONE home for the primitive — with this as its CLI surface,
# the same split the reviewer-evidence classifier uses across pr-review.sh and pr-watch.sh. If a
# caller outside prompt construction ever needs it, that is the signal to move the surface out.
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
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi
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

# The reasoning-effort values this helper will pass through to an agent CLI.
#
# WHY VALIDATE AT ALL — the CLI does not. Measured on codex-cli 0.145.0: `codex exec -c
# model_reasoning_effort=definitelynotalevel` prints "reasoning effort: definitelynotalevel" and
# runs anyway. So an unvalidated typo does not fail; it silently runs at whatever the model falls
# back to while the manifest claims a bound. Silently-ignored is indistinguishable from
# it-worked, which is the failure mode base/practices/self-review.md exists to name.
#
# WHERE THE LIST COMES FROM — the CLI's own catalog, not a subset invented here. It is the union
# of `supported_reasoning_levels` across `codex debug models --bundled` (codex-cli 0.145.0):
#   gpt-5.6-sol/terra  low medium high xhigh max ultra
#   gpt-5.6-luna       low medium high xhigh max
#   gpt-5.5 / 5.4 / 5.4-mini / 5.2 / codex-auto-review   low medium high xhigh
# An earlier hand-written list rejected `max` and `ultra` — valid on the frontier models — while
# permitting `minimal`, which NO bundled model supports. Both directions were wrong.
#
# WHAT THIS CANNOT DO, stated plainly: levels are per-MODEL, and this helper does not know which
# model a given call will select. A union therefore accepts `ultra` even when the selected model
# tops out at `xhigh`. That is a deliberately weaker check than "valid for this model" — owning a
# model catalog is not this framework's job — and it is still strictly better than forwarding
# anything at all, because the CLI catches neither case.
_ADB_RD_KNOWN_EFFORT="low medium high xhigh max ultra"

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

# How many bytes of a dispatched agent's LOG STREAM this helper will pass through (#141).
#
# The stream is the agent's live exploration output, routed to stderr below so it is visible for
# debugging and never mixed into stdout. Nothing bounded it: one gap-analysis run wrote 674 KB, the
# run that implemented #84/#106 wrote 428 KB, and the run that implemented THIS issue wrote 766 KB.
# /cleanup sweeps those artifacts BETWEEN runs (#84); what was still unbounded is a SINGLE run's.
#
# EVERY AGENT AND EVERY ROLE, not just gap-analysis. `review.err` is the same stream from the same
# code path with the same growth, so capping one role would leave the identical defect in the other
# and buy it role-specific plumbing — and a slot is dispatched by bare TOKEN (see below), which
# carries no role to key a policy off anyway.
#
# 0 DISABLES the cap: an operator debugging a dispatch wants the whole stream, and "0 = unbounded"
# is the only reading of zero that is useful here (contrast the BOUND above, where 0 is refused
# because neither possible meaning is a backstop).
_ADB_RD_LOG_MAX_BYTES="${ADB_DISPATCH_LOG_MAX_BYTES:-262144}"
# Digit-only is NOT sufficient: a 40-digit value is all digits and still outside bash's integer
# range, where `[ "$max" -eq 0 ]` below dies with `integer expression expected` and awk would carry
# the threshold through a float. Range is checked arithmetically, and the ceiling is a sanity bound
# rather than a policy (anything past it is indistinguishable from "unbounded", which is `0`).
#
# The rejected value is TRUNCATED in the message. Echoing it whole let an arbitrarily long
# environment value into the very artifact this knob exists to bound — the diagnostic undoing the
# cap it was announcing.
_adb_rd_bad_log_max() {
  printf 'role-dispatch: ADB_DISPATCH_LOG_MAX_BYTES="%.40s" is not a whole number of bytes in range — using the %s default\n' \
    "$1" 262144 >&2
  _ADB_RD_LOG_MAX_BYTES=262144
}
case "$_ADB_RD_LOG_MAX_BYTES" in
  ''|*[!0-9]*) _adb_rd_bad_log_max "$_ADB_RD_LOG_MAX_BYTES" ;;
  *) if ! [ "$_ADB_RD_LOG_MAX_BYTES" -le 1073741824 ] 2>/dev/null; then
       _adb_rd_bad_log_max "$_ADB_RD_LOG_MAX_BYTES"
     fi ;;
esac

# How long the log filter gets to finish AFTER the agent exits, before we stop waiting for it.
# This bounds a hang rather than tuning a budget: the filter normally sees EOF within milliseconds
# of our closing the write end, and the only way it does not is a background descendant the agent
# left holding that end open (see `_adb_rd_bounded_capped`). A TEST SEAM like the kill grace, not
# an operator knob — nobody tunes this — so it is clamped rather than validated loudly.
_ADB_RD_LOG_DRAIN_SECS="${ADB_DISPATCH_LOG_DRAIN_SECS:-10}"
case "$_ADB_RD_LOG_DRAIN_SECS" in
  ''|*[!0-9]*) _ADB_RD_LOG_DRAIN_SECS=10 ;;
  *)           [ "$_ADB_RD_LOG_DRAIN_SECS" -eq 0 ] 2>/dev/null && _ADB_RD_LOG_DRAIN_SECS=1 ;;
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
#
# `--with-layer` prefixes the answer with WHICH layer supplied it — `repo <value>` or
# `global <value>` — because a caller that reports a value to an operator has to be able to say
# which file to edit. It is an OUTPUT rather than a global, and that is not a style preference:
# every caller invokes this function inside `$( … )`, which is a subshell, so an assignment to a
# global here is discarded before the caller can read it. That was the first attempt, and it
# returned an empty layer for every case. Callers that omit the flag are byte-for-byte unaffected.
# NOW A THIN WRAPPER over `adb_toml_layered_get` in common.sh, which owns the precedence rule
# itself. It stays as a named function because this module's two callers want the paths bound —
# the shared primitive takes them as arguments precisely so it can serve modules with different
# manifests (#421's ledger, #422's `[mcp]`), and re-typing them at each call site here would be
# the same duplication one level down.
_adb_rd_layered_get() {
  adb_toml_layered_get "$_ADB_RD_REPO_TOML" "$_ADB_RD_GLOBAL_TOML" "$@"
}

# _adb_rd_read_failed <rc> — the diagnostic for a layered read that answered neither 0 nor 1.
#
# A MANIFEST THAT EXISTS BUT CANNOT BE READ IS A HARD ERROR, NEVER "UNSET". `adb_toml_layered_get`
# returns 2 (unreadable) or 3 (contains a NUL byte) without consulting the next layer; every reader
# in this file used to treat any non-zero status as undeclared and fall through to the global
# manifest or the built-in — the silent fall-through this file's own header forbids, reached by
# permissions rather than by a typo. Each caller returns 2 after printing this, the same code its
# malformed-value arm already uses. Reported by the declared reviewer on PR #429.
_adb_rd_read_failed() {
  case "$1" in
    2) printf 'role-dispatch: an agents.toml exists but could not be read — refusing to fall back to a lower layer or a built-in. Check %s and %s.\n' "$_ADB_RD_REPO_TOML" "$_ADB_RD_GLOBAL_TOML" >&2 ;;
    *) printf 'role-dispatch: an agents.toml contains a NUL byte and is not TOML — refusing to read it. Check %s and %s.\n' "$_ADB_RD_REPO_TOML" "$_ADB_RD_GLOBAL_TOML" >&2 ;;
  esac
}

# The built-in default for a role that is UNSET: gap_analysis skips (no output, 0 status); every
# other role — survey included (#435: it is exploration, so same-model is fine and stated) — falls
# back to the primary. A DECLARED empty ("") is resolved by the caller before this is asked:
# gap_analysis and survey read it as the documented skip; every other role lands here. (primary
# itself is resolved directly by adb_resolve_primary, so it never reaches here.) One home, so the
# two callers can't diverge.
_adb_rd_role_default() {
  case "$1" in
    gap_analysis) return 0 ;;
    *)            adb_resolve_primary; return $? ;;
  esac
}

# The built-in reasoning effort for a role whose effort nothing declares (#225). Printing nothing
# and returning 1 means "inherit whatever the agent's own config says" — the pre-#225 behaviour,
# and still the default for every role but one.
#
# `review` defaults to `medium` because effort was the actual cost driver, not the pass itself. A
# workstation carrying `model_reasoning_effort = "xhigh"` in ~/.codex/config.toml silently applied
# it to every dispatched role: one measured review took 37m57s of a 2h28m run. The review's job is
# a named-checklist pass over a diff that is already written, which is not the shape that needs the
# deepest setting — and a reviewer nobody waits for is a reviewer that gets deleted. Declare, do
# not inherit: a value the operator never chose should not govern a step the workflow blocks on.
_adb_rd_effort_default() {
  case "$1" in
    review) printf 'medium' ;;
    *)      return 1 ;;
  esac
}

# Resolve the reasoning effort for ROLE: repo manifest `[roles.effort]` → global manifest → the
# built-in default above. Prints the value and returns 0; prints nothing and returns 1 when
# nothing declares one (inherit); returns 2 on an invalid declared value.
#
# An explicitly EMPTY value (`review = ""`) is a documented escape hatch meaning "inherit" — the
# same shape `[gates]` already uses for "disabled", so the manifest reads consistently.
# Usage: adb_role_effort <role>
adb_role_effort() {
  local role="$1" raw val _rc
  [ -n "$role" ] || return 1
  raw="$(_adb_rd_layered_get roles.effort "$role")"; _rc=$?
  [ "$_rc" -le 1 ] || { _adb_rd_read_failed "$_rc"; return 2; }
  if [ "$_rc" -eq 0 ]; then
    val="$(adb_toml_unquote "$raw")"
    [ -n "$val" ] || return 1
    case " $_ADB_RD_KNOWN_EFFORT " in
      *" $val "*) printf '%s' "$val"; return 0 ;;
      *) printf 'role-dispatch: invalid [roles.effort] %s = "%s" (known: %s)\n' \
           "$role" "$val" "$_ADB_RD_KNOWN_EFFORT" >&2; return 2 ;;
    esac
  fi
  _adb_rd_effort_default "$role"
}

# Resolve `primary` to exactly one concrete, validated agent token. The built-in default is
# `claude`. Resolved on its own (never via the @primary fallback recursion) so the other roles'
# "default to primary" can reuse it without a resolution loop.
adb_resolve_primary() {
  local raw val _rc
  raw="$(_adb_rd_layered_get roles primary)"; _rc=$?
  [ "$_rc" -le 1 ] || { _adb_rd_read_failed "$_rc"; return 2; }
  if [ "$_rc" -eq 0 ]; then
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
# (`gap_analysis` unset or "", and `survey = ""` — #435's documented opt-out; an UNSET survey
# defaults to the primary). A 2 status means an invalid manifest value (unknown
# agent token, or an explicit empty `review = []`) — surfaced, never silently degraded.
adb_resolve_role() {
  local role="$1" raw val elems tok bad=0 _rc

  case "$role" in
    primary) adb_resolve_primary; return $? ;;
    gap_analysis|review|debug|issue_author|release|survey) ;;
    *) printf 'role-dispatch: unknown role "%s"\n' "$role" >&2; return 2 ;;
  esac

  raw="$(_adb_rd_layered_get roles "$role")"; _rc=$?
  [ "$_rc" -le 1 ] || { _adb_rd_read_failed "$_rc"; return 2; }
  if [ "$_rc" -eq 1 ]; then
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
    # A DECLARED empty is not the same word as an unset key for every role: `survey` defaults to
    # the primary when nothing declares it, and `""` is its documented skip (#435) — whereas
    # `review = ""` stays the primary's own pass and `gap_analysis = ""` stays the skip it already
    # was. Only the two skippable roles short-circuit here; everything else takes the unset default.
    case "$role" in gap_analysis|survey) return 0 ;; esac
    _adb_rd_role_default "$role"; return $?     # "" → the primary's own pass (review/debug/…)
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
# Defined in terms of the tri-state reader below, so "the two differ ONLY on unset" is true by
# construction rather than by two copies of the parse agreeing. One home for what a valid
# `[reviewers] bots` is — and for the message that rejects an invalid one.
# The status handling is EXHAUSTIVE on purpose (#173). It used to read "2 is malformed, 0 is
# authoritative, anything else means unset — emit the defaults", so any future status from the reader
# would have silently become the permissive built-in allowlist, in the code that decides which threads
# may be auto-resolved. Only 3 means "not declared anywhere"; an unrecognized status is refused rather
# than defaulted. This is also why `--comparable` below is a WRAPPER rather than a flag on the reader:
# the reader's 0/2/3 contract has to stay exactly that.
adb_dispatch_bots() {
  local out rc
  out="$(adb_dispatch_bots_declared)"; rc=$?
  case "$rc" in
    0) [ -z "$out" ] || printf '%s\n' "$out"   # declared — even as [] — is authoritative
       return 0 ;;
    2) return 2 ;;                              # malformed: already reported by the reader
    3) ;;                                       # not declared anywhere -> the default set below
    *) printf 'role-dispatch: unexpected status %s from the [reviewers] bots reader — refusing to fall back to the default allowlist\n' \
         "$rc" >&2
       return "$rc" ;;
  esac
  printf '%s\n' \
    'chatgpt-codex-connector' \
    'gemini-code-assist[bot]' 'gemini-code-assist' \
    'copilot-pull-request-reviewer[bot]' 'copilot[bot]' \
    'github-actions[bot]' \
    'claude[bot]' 'claude-code[bot]'
}

# adb_dispatch_bots_declared — the SAME manifest key, read as a TRI-STATE, with NO default (#134).
#
# Why a second reader rather than a flag on the first: the two consumers need opposite answers for
# "unset", and both are right for their own job.
#
#   /resolve-pr-threads  asks "which thread authors may I auto-resolve?" — an over-broad default is
#                        harmless there (it resolves a thread nobody was going to read), so unset
#                        falls back to the built-in allowlist above.
#   the pre-arm guard    asks "must I WAIT for a reviewer before arming auto-merge?" — and a
#                        default is exactly wrong. Defaulting to the built-in set would make every
#                        repo wait for eight bots it does not have; defaulting to empty would arm
#                        auto-merge on a repo that DOES have one, which is #134 itself.
#
# So this reader never defaults. Three outcomes, each a distinct operator action:
#   0 + logins  declared and non-empty  -> these reviewers must review before auto-merge is armed
#   0 + nothing declared as `bots = []` -> this repo has NO async reviewer; arming is safe
#   3           not declared anywhere   -> UNKNOWN. The caller must fail closed, never guess.
#   2           malformed               -> same rejection as above, never mistaken for `[]`
#
# The `[]` case is what keeps the guard from being a permanent tax on repos with no bot reviewer:
# one line in agents.toml restores unattended arming.
adb_dispatch_bots_declared() {
  local raw inner out _rc
  raw="$(_adb_rd_layered_get reviewers bots)"; _rc=$?
  case "$_rc" in 0) ;; 1) return 3 ;; *) _adb_rd_read_failed "$_rc"; return 2 ;; esac
  case "$raw" in
    \[*) ;;
    *)   printf 'role-dispatch: [reviewers].bots must be an array (e.g. ["a[bot]","b"]) — use [] to disable\n' >&2; return 2 ;;
  esac

  # A TRUNCATED array must not read as `[]`. `adb_toml_get` is line-based, so a perfectly valid
  # multi-line TOML array —
  #     bots = [
  #       "chatgpt-codex-connector",
  #     ]
  # — yields just `[`, which `adb_toml_array` parses to ZERO elements. That is byte-for-byte what
  # an intentional `bots = []` produces, and the two mean opposite things to the merge gate: one
  # says "this repo has no async reviewer, arming is safe", the other has a reviewer still to come.
  # Reading the first as the second re-creates issue #134 from a config file that is not even
  # wrong. A wrapped array is the same bug one line later: it silently drops every element after
  # the first line, so a declared reviewer simply vanishes.
  #
  # A well-formed single-line array always ENDS in `]` here — `adb_toml_get` has already stripped
  # a trailing comment and trailing whitespace — so "does not end in `]`" is exactly "the value
  # continues on another line" (or is otherwise unclosed). Reject it as malformed: the remedy is
  # to fix agents.toml, and callers must never see it as a declaration of "none".
  case "$raw" in
    *\]) ;;
    *)   printf 'role-dispatch: [reviewers].bots is not closed on one line — a multi-line array is not supported; put it on a single line\n' >&2; return 2 ;;
  esac

  out="$(adb_toml_array "$raw")"
  # An array that is not literally empty but yields no usable element (`[""]`, `[   ]`, `[,]`) is
  # malformed for the same reason: the operator declared SOMETHING, and silently downgrading that
  # to the "no reviewers" disable is the fail-open direction.
  inner="${raw#\[}"; inner="${inner%\]}"
  if [ -z "$out" ] && [ -n "$(printf '%s' "$inner" | tr -d '[:space:]')" ]; then
    printf 'role-dispatch: [reviewers].bots has no usable entries — use [] to disable, or list logins\n' >&2
    return 2
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# adb_dispatch_bots_comparable — the declared set NORMALIZED into the form the two PR guards match
# against, plus their shared vocabulary for why it could not be read (#173). One home for what had
# been ~13 duplicated lines in `pr-review.sh` and `pr-watch.sh`: the status mapping, the
# normalization pipeline, and the "declared something that normalizes to nothing" rejection.
#
#   0  + the set  the comparison form, one login per line. EMPTY with status 0 is the `bots = []`
#                 answer — this repo has no async reviewer — and is not an error.
#   17 undeclared anywhere. The caller must fail closed; it cannot know whether a reviewer is coming.
#   18 malformed, or declared but with no usable login.
#
# WHY THIS IS A SEPARATE FUNCTION AND NOT A FLAG ON adb_dispatch_bots_declared. That reader's 0/2/3
# contract is consumed by `adb_dispatch_bots` above, which treats status 2 as malformed and ANY OTHER
# non-zero as "unset — emit the built-in default allowlist". Returning 18 from the reader itself would
# therefore turn a malformed `[reviewers] bots` into the permissive default set for
# `/resolve-pr-threads` — a fail-open manufactured by tidying up. So the tri-state reader keeps its
# contract untouched and this wrapper maps it for the guards.
#
# NORMALIZATION, and what it deliberately no longer does. Lowercase (logins are case-insensitive) and
# de-duplicate, so the comparison form is built one way regardless of how many reviewers are declared.
# It does NOT strip a trailing `[bot]` any more: stripping the DECLARATION is what let a human account
# named `foo` satisfy `bots = ["foo[bot]"]`. The suffix is now handled on the API side only — see
# `adb_reviewer_match_jq` in common.sh for the asymmetric rule and what a bare login means.
#
# An entry that is ONLY `[bot]` is dropped, which then trips the rejection below rather than becoming
# a reviewer that can never match. `adb_toml_array` has already trimmed whitespace and dropped empty
# elements, so the blank-line arm is defence in depth rather than the working case.
#
# `foo[bot]` IS SUBSUMED BY `foo` when both are declared, and dropping it is not merely tidiness. The
# arming guard requires EVERY declared login to have reviewed, so two spellings of one account would
# become two independent requirements — and since a bare `foo` already matches either spelling while
# `foo[bot]` matches only the suffixed one, an account reported bare could never satisfy both and the
# guard would wedge at "awaiting review" permanently. Declaring both spellings used to be harmless
# (the old normalizer collapsed them) and the old docs actively suggested it, so a repo may well carry
# such a declaration; keeping the WEAKER entry preserves exactly what the operator asked for.
adb_dispatch_bots_comparable() {
  local declared drc want
  declared="$(adb_dispatch_bots_declared)"; drc=$?
  case "$drc" in
    0) ;;
    3) printf 'role-dispatch: this repo declares no '\''[reviewers] bots'\'' — cannot know whether a reviewer is coming.\n' >&2
       printf 'role-dispatch: declare the async reviewer logins in agents.toml, or '\''bots = []'\'' if there are none.\n' >&2
       return 17 ;;
    2) printf 'role-dispatch: '\''[reviewers] bots'\'' is unusable (see above) — fix agents.toml; use [] for none\n' >&2
       return 18 ;;
    *) return "$drc" ;;     # nothing else is reachable; a caller maps the unknown to its own "unreadable"
  esac

  # AN ENTRY WITH INTERNAL WHITESPACE IS MALFORMED, AND IT IS REJECTED RATHER THAN DROPPED.
  # A GitHub login is alphanumerics and hyphens (plus an optional `[bot]` suffix), so `"foo bar"`
  # can never name a real account. Dropping it would be the FAIL-OPEN choice: with two entries
  # declared, silently discarding one SHRINKS the set every consumer must satisfy, and the guards
  # would then arm — or report a clean pass — on the strength of the remaining reviewer alone.
  # Rejecting the whole declaration is fail-closed and hands the operator the right remedy.
  #
  # It also protects the downstream `<login> <class>` line grammar the reviewer-evidence classifier
  # emits (#167): a login carrying a space would split across that boundary, so the class parsed
  # back out would be garbage and the reviewer would silently never match its own evidence.
  case "$declared" in
    *[[:space:]]*)
      if printf '%s\n' "$declared" | grep -q '[^[:space:]][[:space:]][^[:space:]]'; then
        printf 'role-dispatch: '\''[reviewers] bots'\'' contains an entry with embedded whitespace — not a valid GitHub login; fix agents.toml\n' >&2
        return 18
      fi ;;
  esac

  # `${declared,,}` rather than a `tr` stage (#258): a builtin expansion instead of a process, and
  # equivalent here because it is the same LOCALE-AWARE fold the unqualified `tr` was doing (the
  # `tr` carried no `LC_ALL=C`, so both honour the ambient locale identically).
  #
  # Note what is NOT being claimed: the check above rejects only embedded WHITESPACE, so this value
  # is not in fact constrained to ASCII login characters — Unicode survives it. That does not matter
  # for the equivalence, which was measured on both folds, but an earlier version of this comment
  # justified the swap by an input guarantee the code does not make. (Caught in review.)
  want="$(printf '%s\n' "${declared,,}" \
          | sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*\[bot\][[:space:]]*$/d' \
          | LC_ALL=C sort -u \
          | awk '{ e[NR] = $0; seen[$0] = 1 }
                 END { for (i = 1; i <= NR; i++) {
                         b = e[i]; sub(/\[bot\]$/, "", b)
                         if (b != e[i] && (b in seen)) continue   # `foo[bot]` is subsumed by `foo`
                         print e[i] } }')"

  # A declaration that survived the manifest reader but normalizes to NOTHING (`bots = ["[bot]"]`) is
  # malformed, not "no reviewers". The operator declared SOMETHING, and silently downgrading that to
  # the `[]` disable would arm auto-merge — or report a clean pass — off the back of a typo, from the
  # one input that looks most like a real declaration.
  if [ -n "$declared" ] && [ -z "$want" ]; then
    printf 'role-dispatch: '\''[reviewers] bots'\'' has no usable reviewer logins — fix agents.toml (use [] for none)\n' >&2
    return 18
  fi
  [ -z "$want" ] || printf '%s\n' "$want"
  return 0
}

# adb_dispatch_max_rounds — the re-review round cap a repo declares, as `[reviewers] max_rounds`
# (#416). The BOUND lives beside the reviewer declaration it modifies, because it is a fact about
# how this repo's reviewer is driven and about nothing else.
#
#   0 + <n>  declared and usable — a bare positive integer, or the uncapped sentinel `0` (#420)
#   3        not declared anywhere — the CALLER applies its own built-in default. Note this file
#            deliberately does NOT supply one: the caller has to be able to tell a repo policy from
#            a built-in, because its own diagnostic must name which produced the effective cap.
#   2        declared but malformed — a HARD ERROR. Never a silent fall-back to the default: an
#            operator who wrote a bound and got the built-in has a cap they did not choose and no
#            way to notice.
#
# IT LAYERS repo → global like every other manifest key, through the one home
# (`_adb_rd_layered_get`), so a workstation can carry a house default and a repo can override it.
# The one key that is deliberately repo-ONLY is `[repo] reconcile-required-checks`, and its reason
# does not apply here: that switch authorizes an unattended WRITE to branch protection, so reading
# it globally would arm it in repositories the operator never considered. A retry bound authorizes
# nothing — the worst a wrong one does is stop or continue a loop the operator is watching.
#
# ZERO MEANS UNCAPPED, AND IT IS THE ONLY SENTINEL (#420). It follows the `[gates] "" disables`
# precedent — a zero-value sentinel disabling a mechanism, spelled in the config surface's own
# vocabulary — because a project must be able to declare "run until clean, no round ceiling"
# explicitly rather than by picking a number and hoping it is big enough. What it disables is the
# caller's round CEILING and nothing else; this reader neither knows nor cares what the caller does
# with it.
#
# IT IS MATCHED AS THE EXACT STRING `0`, BEFORE the leading-zero rule below and before any
# arithmetic, and both halves of that are load-bearing. Before the leading-zero rule, because `0*`
# claims `0` too and would report the wrong error for the one spelling that is now legal. Before
# arithmetic, because `[ "$raw" -eq 0 ]` is TRUE for `00` and for `0000` — so a numeric test would
# quietly promote spellings TOML does not have into the sentinel, which is the opposite of "0 is the
# only sentinel".
#
# THE ACCEPTED FORM IS NARROWER THAN "A TOML INTEGER", AND THAT IS STATED RATHER THAN IMPLIED.
# This reader accepts exactly a plain decimal positive integer, or `0`: no quotes, no sign, no
# underscore separators, no leading zero. TOML 1.0 would also allow `+6` and `1_000`, and those are REFUSED
# here — a retry bound is a small number and a spelling that needs a thousands separator is far more
# likely a typo than an intent. What matters is that the boundary is written down, because the
# earlier version of this comment claimed to validate "a TOML integer" and did not: it accepted
# `06`, which TOML forbids, and passed it straight to arithmetic. Reported by the independent
# reviewer.
#
# A quoted value is refused for the same reason it is dangerous: `max_rounds = "6"` is a STRING, and
# tolerating a type the format does not have here is the direction in which `max_rounds = "six"`
# degrades into something rather than being rejected.
# With `--with-source` it prints `<value> <layer>` where <layer> is `repo` or `global`, so a caller
# reporting the effective cap can name WHICH agents.toml to edit — the repository's or
# `~/.config/ai-dev-baseline/agents.toml`. The bare form is unchanged, so existing callers are
# untouched. Reported by the declared reviewer on PR #419.
adb_dispatch_max_rounds() {
  local raw layer="" with_source=0 _rc
  [ "${1:-}" = "--with-source" ] && with_source=1
  if [ "$with_source" -eq 1 ]; then
    raw="$(_adb_rd_layered_get reviewers max_rounds --with-layer)"; _rc=$?
    case "$_rc" in 0) ;; 1) return 3 ;; *) _adb_rd_read_failed "$_rc"; return 2 ;; esac
    layer="${raw%% *}"; raw="${raw#* }"
  else
    raw="$(_adb_rd_layered_get reviewers max_rounds)"; _rc=$?
    case "$_rc" in 0) ;; 1) return 3 ;; *) _adb_rd_read_failed "$_rc"; return 2 ;; esac
  fi
  case "$raw" in
    ''|*[!0-9]*)
      printf 'role-dispatch: [reviewers].max_rounds must be a plain decimal positive integer, or 0 for uncapped — no quotes, sign, underscores or leading zero (got %s)\n' \
        "$(adb_display_value "$raw")" >&2
      return 2 ;;
  esac
  # ONE CASE, TWO ARMS, IN THIS ORDER. `0` is the uncapped sentinel and `0*` is the leading-zero
  # refusal, and `0*` matches `0` — so splitting these into two statements, or writing them the
  # other way round, hands `0` the "must not carry a leading zero" error and the sentinel is
  # unreachable.
  #
  # A LEADING ZERO IS NOT A TOML INTEGER AT ALL, so `06` must not reach the arithmetic below — where
  # it would be read as 6 by one shell and, in another context, as octal. Refuse the spelling rather
  # than guess which was meant. `00` is that rule and not the sentinel: TOML has no such integer, so
  # accepting it would invent a second spelling for uncapped.
  case "$raw" in
    0)  ;;
    0*) printf 'role-dispatch: [reviewers].max_rounds must not carry a leading zero — TOML has no such integer (got %s)\n' \
          "$(adb_display_value "$raw")" >&2
        return 2 ;;
  esac
  # The LENGTH bound is not belt-and-braces: an all-digit value wider than a shell integer overflows
  # the consumer's arithmetic, so a "bound" of 99999999999999999999 would pass a digits-only check
  # and then compare as nonsense. 18 digits is the same ceiling `pr-watch.sh`'s `require_uint` and
  # `roadmap-lib.sh`'s `is_uint` document, for the same reason.
  if [ "${#raw}" -gt 18 ]; then
    printf 'role-dispatch: [reviewers].max_rounds is too large (got %s)\n' "$(adb_display_value "$raw")" >&2
    return 2
  fi
  # NO "GREATER THAN ZERO" ARM, AND ITS ABSENCE IS DELIBERATE RATHER THAN AN OVERSIGHT (#420). One
  # stood here while zero was refused. Every value that could reach it is now digits-only, at most 18
  # of them, and — by the case above — either the exact string `0` or a spelling that does not start
  # with one, so the smallest survivor is 1 and the test could never answer. A check that cannot fire
  # reports safety it never verified, which is worse than no check.
  if [ "$with_source" -eq 1 ]; then
    printf '%s %s\n' "$raw" "$layer"
  else
    printf '%s\n' "$raw"
  fi
  return 0
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

# The capping filter: pass the first <max> bytes through, then DRAIN the rest and say how much was
# dropped. Reads stdin, writes stdout.
#
# IT MUST DRAIN, NOT EXIT. A filter that stops reading at the cap closes the pipe, and the next
# write from the agent takes SIGPIPE — so capping its log would KILL the dispatch it was only
# supposed to trim. Draining costs nothing (the bytes are read and discarded) and keeps the agent's
# own exit status the one this helper reports.
#
# A HEAD CAP, decided on evidence rather than taste. The obvious alternative is to keep the TAIL,
# and for this stream it is the worse trade: codex's final message is captured separately by
# --output-last-message, and measurement on the 766 KB stream above found that message duplicated
# at byte 758388 — i.e. the tail is the one part already preserved IN FULL elsewhere. The head is
# not: it carries the CLI version, model, reasoning effort and session id, which nothing else
# records. A head cap also streams live, where a tail cap can emit nothing until EOF.
#
# `dd bs=1`, and the two rejected alternatives are why.
#
#   `head -c` + a drain OVER-READS into its buffer before exiting. It loses an unknown number of
#   bytes and — worse — can consume the entire remainder, leaving the drain to see EOF and report a
#   clean pass on a stream it silently truncated.
#
#   `awk` shipped here first and was replaced after review. Being RECORD-oriented, it does not act
#   until it sees a newline: a newline-free stream (a `\r` progress feed, one very long line) is
#   buffered whole, so it emits none of the head bytes while the agent runs and its memory grows
#   with the record — an indefinitely noisy stream could OOM the filter and SIGPIPE the agent it
#   was meant to protect. It was also not binary-safe: BSD awk on macOS treats a NUL as
#   end-of-string, so `ab\0cdef…` emitted `ab`, dropped the remainder, and printed NO notice.
#
# `dd bs=1` has none of those properties. It reads EXACTLY max bytes (so the drain's count is exact
# rather than approximate), holds one byte at a time (so memory is flat on any input, newlines or
# not), writes each byte as it arrives (so the head streams live), and is byte-transparent (so a
# NUL is passed through rather than ending the stream). Measured: 0.21 s for a 256 KiB cap, and a
# 5 MB newline-free stream handled in 0.23 s with flat memory.
#
# `wc -c` is BOTH the drain and the count, so "was anything discarded" and "how much" are one read
# and cannot disagree. A stream shorter than the cap drains to 0 and prints no notice at all.
# Usage: _adb_rd_cap_stream <max-bytes>
_adb_rd_cap_stream() {
  local max="$1" rest
  dd bs=1 count="$max" 2>/dev/null
  rest="$(wc -c)"
  rest="${rest//[![:digit:]]/}"
  [ "${rest:-0}" -gt 0 ] && printf '\n[role-dispatch: agent log capped at %s bytes (ADB_DISPATCH_LOG_MAX_BYTES); the remaining %s bytes were discarded. This is a HEAD cap — the END of the stream is missing.]\n' "$max" "$rest"
  return 0
}

# Run a bounded dispatch with its LOG stream capped, and return the agent's own status.
#
#   <log_stdout>  1 — the command's STDOUT is part of the log (codex, whose RESULT arrives via
#                     --output-last-message, so its live stdout is exploration, not the answer)
#                 0 — STDOUT is the RESULT and passes through UNCAPPED (claude/gemini, whose final
#                     message IS stdout). Capping a result is data loss, not tidying.
#
# THE TOPOLOGY IS THE HARD PART, and a plain pipeline is the wrong one. `cmd | filter` puts the
# LEFT side in a subshell, and `adb_run_bounded` installs its reap trap on the CALLING shell — so
# the trap would protect a subshell that is not the one being signalled, and an outer TERM would go
# back to orphaning the agent. A process substitution keeps the runner in THIS shell, and forks the
# filter instead — the cheap process rather than the one the bound exists to police.
#
# WHAT THAT DOES NOT COVER, stated rather than glossed: the filter is a SIBLING of the bounded
# command, not a member of its process group, so the bound does not reap it and neither does
# `_adb_bounded_reap` — whose `exit 143` leaves the two lines below unrun. In practice the shell's
# exit closes the write end, the filter sees EOF and flushes; what is genuinely not guaranteed is
# ORDERING on that path, so a caller reading the artifact immediately after an outer kill can race
# the filter's last write. Bounded and rare, but it is not "nothing to protect".
#
# `exec {capfd}>` rather than a redirection on the command, because `$!` must be captured for the
# procsub itself — and `adb_run_bounded` backgrounds its own child and watcher, overwriting `$!`
# before the command returns. Without that pid there is nothing to `wait` on, and the notice above
# can be lost to a race with our own exit.
#
# `{capfd}>&-` ON THE CALL closes the descriptor for the CHILD side, and it is worth its own line:
# the watchdog's ticking `sleep` is deliberately allowed to outlive its watcher (see common.sh), so
# an inherited write end keeps the pipe open after the agent is gone and `wait` blocks for a whole
# tick. Measured: 5.0 s per dispatch with it, 0.05 s without.
# Usage: _adb_rd_bounded_capped <log_stdout> <argv...>
_adb_rd_bounded_capped() {
  local log_stdout="$1"; shift
  local rc capper capfd max="$_ADB_RD_LOG_MAX_BYTES"
  if [ "$max" -eq 0 ]; then
    if [ "$log_stdout" = 1 ]; then _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" "$@" >&2
    else                           _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" "$@"; fi
    return $?
  fi
  exec {capfd}> >(_adb_rd_cap_stream "$max" >&2)
  capper=$!
  if [ "$log_stdout" = 1 ]; then
    _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" "$@" >&"$capfd" 2>&1 {capfd}>&-
  else
    _adb_rd_bounded "$_ADB_RD_TIMEOUT_SECS" "$@" 2>&"$capfd" {capfd}>&-
  fi
  rc=$?
  exec {capfd}>&-
  # THE FILTER'S OWN STATUS IS CHECKED, not discarded. It used to be, and a filter that died took
  # the whole log with it while this function still returned the agent's status — a dispatch that
  # read as clean with its entire logging path gone. We still RETURN the agent's status (the agent
  # really did run), but the failure is now said out loud instead of inferred from a quiet artifact.
  #
  # Note what a dead filter does to that status: the drain protects the agent from SIGPIPE while
  # the filter is HEALTHY, not when it exits early, so an agent still writing when the filter dies
  # takes SIGPIPE and this returns 141. That is a broken environment rather than a broken agent,
  # which is exactly why the warning names the filter.
  #
  # AND THE WAIT IS BOUNDED, because an unbounded one is a hang this function would have INTRODUCED.
  # Closing our write end is not the same as closing the pipe: if the agent left a background
  # descendant that inherited its stdout/stderr, that descendant still holds the write end, the
  # filter never sees EOF, and a plain `wait` blocks forever — AFTER `adb_run_bounded` has returned,
  # so its bound no longer applies and nothing else would ever stop it. An agent that starts a dev
  # server would hang the whole dispatch. The bound is ticked rather than slept in one go, for the
  # reason common.sh's watchdog gives: killing the guard does not kill a `sleep` it already forked,
  # so a single long sleep would leak an orphan per dispatch.
  if [ -n "$capper" ]; then
    local dflag dguard crc
    dflag="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-drain-$$")"; rm -f "$dflag"
    ( waited=0
      while [ "$waited" -lt "$_ADB_RD_LOG_DRAIN_SECS" ]; do
        kill -0 "$capper" 2>/dev/null || exit 0
        sleep 1; waited=$(( waited + 1 ))
      done
      kill -0 "$capper" 2>/dev/null || exit 0
      : > "$dflag"; kill -TERM "$capper" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    dguard=$!
    wait "$capper" 2>/dev/null; crc=$?
    kill -TERM "$dguard" 2>/dev/null; wait "$dguard" 2>/dev/null
    if [ -f "$dflag" ]; then
      printf 'role-dispatch: WARNING — the agent exited but something it spawned still holds the log pipe open, so the log did not end after %ss; the filter was stopped and this dispatch'"'"'s log may be truncated. A background process the agent left running is the usual cause.\n' \
        "$_ADB_RD_LOG_DRAIN_SECS" >&2
    elif [ "$crc" -ne 0 ]; then
      printf 'role-dispatch: WARNING — the log-capping filter failed (exit %s); this dispatch'"'"'s agent log is incomplete or missing, and an agent status of 141 means it took SIGPIPE from the dead filter rather than failing on its own.\n' "$crc" >&2
    fi
    rm -f "$dflag"
  fi
  return "$rc"
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

# The CLI EXECUTABLE each agent token dispatches to. PAIRED WITH `_adb_rd_invoke_agent` BELOW:
# every token with an arm there has a name here and vice versa, because a probe that disagrees
# with dispatch is worse than no probe — it would report an agent usable that cannot run (the
# fail-open direction), or refuse one that works. The pairing is proven by a direct test in
# scripts/check-role-dispatch.sh rather than a lint, since the assertion is "these two agree",
# which no single-file token pin can express. The full invocations stay literal in the arms below
# (base/roles.md's table is their canonical home, pinned by check-fact-drift's invocation-* facts).
adb_agent_cli() {
  case "$1" in
    claude) printf 'claude' ;;
    codex)  printf 'codex' ;;
    gemini) printf 'agy' ;;
    *) return 2 ;;
  esac
}

# Is this agent's CLI actually runnable HERE? A CAPABILITY question, and it is deliberately a
# THIRD thing — distinct from "which agent is assigned" (`resolve`) and from "did the agent fail"
# (a dispatch rc). Collapsing capability into either one is what makes an absent CLI look like an
# agent that broke: `codex exec` with no codex on PATH exits 127, which classify_rc quite
# correctly calls "a real agent/CLI error" — accurate about the exit, wrong about the cause, and
# it arrives at step 8 with the branch, the commits and the gates already done.
#
# Asking FIRST turns that into a fact a caller can act on before it spends anything. It is not a
# guarantee the CLI works (it may be unauthenticated, or wedged); it only answers the one question
# whose "no" is knowable in advance and is a configuration problem rather than a failure.
#   0 = the CLI is on PATH   1 = a known agent whose CLI is absent   2 = not an agent token
adb_agent_available() {
  local cli
  cli="$(adb_agent_cli "$1")" || return 2
  command -v "$cli" >/dev/null 2>&1 || return 1
  return 0
}

# WHAT WILL ACTUALLY REVIEW A DIFF — the review RUNG, computed once, here.
#
# This is a DERIVED answer over three readers (`resolve review`, `available`, `bots --comparable`),
# and it lives in one place because the alternative was tried and failed inside a single PR: the
# workflow prose and `bin/agent-init` each interpreted those readers themselves, and they promptly
# disagreed about which bot reader decides the deferred rung — prose said the bare `bots`, whose
# unset default is eight built-in logins, so a repo that had declared NOTHING would have been told
# an async reviewer was coming. Two consumers, two interpretations, one fail-open. So the ladder is
# a predicate, not a paragraph, and both consumers read it.
#
# Usage: adb_review_rung [<driver-token>]
#   <driver-token>  the agent ACTUALLY RUNNING the workflow. Defaults to `primary`.
#
# WHY THE DRIVER IS AN ARGUMENT AND NOT JUST `primary`. "Independent" means *not the model that
# wrote the diff*, and the manifest's `primary` is only a claim about who normally writes it. The
# workflow renders user-invocable for every agent, so a Codex operator can run it against a repo
# whose manifest says `primary = "claude"` — and comparing the reviewer to `primary` there returns
# `independent codex` while Codex reviews its own change, with the close-out reporting an
# independent pass that did not happen. The caller that knows the truth is the workflow (it renders
# its own agent token), so it passes it; `agent-init` omits it, because it reports the manifest's
# configured shape rather than a live run.
#
# Prints ONE line: `<rung>[ <detail>][ missing=<tokens>]`, and the FIRST FIELD is the contract:
#   independent <token>   a usable CLI that is NOT the driver — a different model reviews the diff
#   same-model  <token>   the only usable reviewer IS the driver: it runs, but reviews its own work
#   deferred    <logins>  no usable in-session reviewer, but an async reviewer is DECLARED
#   none                  nothing in-session, nothing declared — no independent review exists
#   unknown     <why>     a reader failed. NEVER guessed past: rc 2.
#
# `missing=` lists CONFIGURED slots whose CLI is absent, and it is present on every rung that has
# any. Step 8's contract is that EVERY configured reviewer is a slot which must reach a terminal
# state, so `review = ["codex","gemini"]` with only codex installed must not report a bare
# `independent codex` — that silently drops a slot the operator asked for and lets the close-out
# claim unqualified coverage.
#
# `unknown` is the load-bearing arm. Every reader here can fail (an unknown agent token, a
# malformed `[reviewers] bots`, a manifest with no `primary`), and treating a failed read as an
# empty one resolves every failure toward the FLATTERING answer — an invalid `review` list would
# report `deferred`, and a malformed bot declaration would report `none` while the operator has
# plainly declared something. Both are the fail-open direction, so a reader that cannot answer
# makes the rung `unknown` rather than contributing nothing.
#   0 = a determinate rung   2 = unknown
adb_review_rung() {
  local driver="${1:-}" tokens bots rc t indep="" same="" missing="" suffix=""
  if [ -n "$driver" ]; then
    _adb_rd_valid_token "$driver" || { printf 'unknown driver-not-an-agent-token\n'; return 2; }
  else
    driver="$(adb_resolve_role primary 2>/dev/null)" || { printf 'unknown primary-role-unresolvable\n'; return 2; }
    [ -n "$driver" ] || { printf 'unknown primary-role-empty\n'; return 2; }
  fi
  tokens="$(adb_resolve_role review 2>/dev/null)" || { printf 'unknown review-role-unresolvable\n'; return 2; }

  # ONE pass that collects everything, rather than returning on the first independent hit: the
  # early return was what discarded the still-unavailable slots behind it.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! adb_agent_available "$t"; then
      missing="${missing:+$missing,}$t"
      continue
    fi
    # An independent reviewer WINS over a same-model one: `review = ["claude","codex"]` under a
    # claude driver really does get an independent pass, and reporting that as same-model because
    # claude was listed first would understate the review the operator configured.
    if [ "$t" != "$driver" ]; then [ -n "$indep" ] || indep="$t"
    else [ -n "$same" ] || same="$t"; fi
  done <<EOF
$tokens
EOF
  [ -z "$missing" ] || suffix=" missing=$missing"

  [ -z "$indep" ] || { printf 'independent %s%s\n' "$indep" "$suffix"; return 0; }
  [ -z "$same" ]  || { printf 'same-model %s%s\n'  "$same"  "$suffix"; return 0; }

  # No usable in-session reviewer. `--comparable` is the reader the MERGE GUARD itself uses
  # (0 + set · 0 + empty for `bots = []` · 17 undeclared · 18 malformed-or-no-usable-login),
  # deliberately NOT `--declared`: that one accepts a syntactically valid array whose entries no
  # reviewer can ever match (`bots = ["[bot]"]`, embedded whitespace), so it would report a
  # `deferred` handoff to a declaration the guard rejects with 18. Agreeing with the guard is the
  # entire value of this arm — a deferred rung that the guard will not honour is a lie.
  bots="$(adb_dispatch_bots_comparable 2>/dev/null)"; rc=$?
  case "$rc" in
    0)  if [ -n "$bots" ]; then printf 'deferred %s%s\n' "$(printf '%s' "$bots" | tr '\n' ',' | sed 's/,$//')" "$suffix"; return 0
        else printf 'none%s\n' "$suffix"; return 0; fi ;;   # rc 0 + empty is an explicit `bots = []`
    17) printf 'none%s\n' "$suffix"; return 0 ;;             # never declared
    *)  printf 'unknown reviewers-bots-malformed%s\n' "$suffix"; return 2 ;;
  esac
}

# Invoke ONE concrete agent's CLI with the prompt from file $2; the agent's clean FINAL message
# goes to this function's stdout, its exploration/log stream to stderr. Returns the CLI's status
# (124 on timeout); for codex, a 0 exit that produced no final message is treated as incomplete
# (return 1) rather than a clean empty pass.
_adb_rd_invoke_agent() {
  local token="$1" pf="$2" effort="${3:-}" repo rc last lb
  case "$token" in
    # `$(<"$pf")` rather than `$(cat "$pf")` (#258): a builtin file read, no `cat` process. Both
    # strip trailing newlines identically, and the prompt is passed as one argv element either way.
    claude)
      # log_stdout=0: stdout IS the final message, so it passes through uncapped; only the log
      # stream on stderr is bounded.
      _adb_rd_bounded_capped 0 claude -p "$(<"$pf")"
      return $?
      ;;
    gemini)
      _adb_rd_bounded_capped 0 agy -p "$(<"$pf")"
      return $?
      ;;
    codex)
      # Reuse the repo root already resolved for _ADB_RD_REPO_TOML rather than a second git call
      # (only codex's --cd needs it).
      repo="$(dirname "$_ADB_RD_REPO_TOML")"
      last="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-last-$$")"; : > "$last"
      # Route codex's live stream to stderr (visible for debugging, NOT mixed into our stdout);
      # --output-last-message captures only the final agent message (#8).
      #
      # `-c model_reasoning_effort=<effort>` is passed ONLY when an effort was resolved (#225).
      # Omitting it entirely — rather than passing some "default" — is what preserves the
      # pre-#225 behaviour for every role that declares nothing: the CLI's own config governs,
      # exactly as before. `-c` is `codex exec`'s documented key=value override.
      #
      # log_stdout=1: codex's stdout is the LIVE STREAM, not the result — the result is the file
      # --output-last-message writes — so stdout and stderr are one log and both are capped (#141).
      if [ -n "$effort" ]; then
        _adb_rd_bounded_capped 1 \
          codex exec --cd "$repo" -c model_reasoning_effort="$effort" \
                     --output-last-message "$last" - < "$pf"
      else
        _adb_rd_bounded_capped 1 \
          codex exec --cd "$repo" --output-last-message "$last" - < "$pf"
      fi
      rc=$?
      if [ "$rc" -ne 0 ]; then rm -f "$last"; return "$rc"; fi
      if [ ! -s "$last" ]; then
        printf 'role-dispatch: codex exited 0 but wrote no final message — treating as incomplete\n' >&2
        rm -f "$last"; return 1
      fi
      # The materialized message is SIZED and refused BEFORE emission: 8388608 matches the
      # tightest downstream stage cap, and a stated refusal beats a downstream pipe collapse.
      # What this does NOT bound is the materialization itself — --output-last-message is
      # codex's own write, and the disk a runaway costs is spent before this line runs.
      lb="$(wc -c < "$last" 2>/dev/null | tr -d ' ')"
      case "$lb" in ''|*[!0-9]*) lb=0 ;; esac
      if [ "$lb" -gt 8388608 ]; then
        printf 'role-dispatch: the final message is %s bytes — past the 8388608-byte result bound; refusing to emit it\n' "$lb" >&2
        rm -f "$last"; return 1
      fi
      # `cat`'s own status is the emission's: a downstream cap (the survey stage's 8 MiB head
      # bound) closes the pipe mid-result, and masking that SIGPIPE published a TRUNCATED final
      # message as a clean pass.
      cat "$last"; rc=$?
      rm -f "$last"
      if [ "$rc" -ne 0 ]; then
        printf 'role-dispatch: the final message could not be emitted whole (a downstream cap closed the pipe?) — treating as failed\n' >&2
        return "$rc"
      fi
      return 0
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
  [ "$1" = survey ] && printf 'role-dispatch: survey is an accelerator, not a gate — retry once, then continue WITHOUT it and say so (#435).\n' >&2
  return 0
}

# Dispatch a prompt (on STDIN) to a role or an explicit agent token. A role that resolves to
# ONE agent is invoked; a multi-agent role (a `review` list) is refused with guidance to use
# `resolve` + a per-slot `invoke <token>` loop (so same-agent slots stay in-process and each
# slot keeps its own retry/fallback — never one opaque multi-agent call). An unassigned role
# returns 3 (distinct from a completed empty result), so a caller never mistakes "skipped" for
# "ran and found nothing".
adb_dispatch_invoke() {
  local target="$1" effort="${2:-}" pf tokens count rc
  pf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-rd-prompt-$$")"
  cat > "$pf"

  # A bare TOKEN carries no role, so it has no declared effort of its own — the caller supplies
  # one explicitly. That is not a corner case: step 8 dispatches a multi-agent `review` per SLOT
  # by token, so role-keyed resolution alone would never reach the very role whose effort this
  # exists to bound. The workflow asks `effort review` once and passes it per slot.
  if _adb_rd_valid_token "$target"; then
    _adb_rd_invoke_agent "$target" "$pf" "$effort"; rc=$?; rm -f "$pf"
    _adb_rd_report "$target" "$target" "$rc"; return "$rc"
  fi

  # Invoked by ROLE: resolve its effort unless the caller overrode it. rc 2 is an invalid declared
  # value — surface it instead of dispatching, or a typo'd manifest silently runs at the CLI's
  # setting while the operator believes it is bounded.
  if [ -z "$effort" ]; then
    effort="$(adb_role_effort "$target")" || { [ "$?" -eq 2 ] && { rm -f "$pf"; return 2; }; effort=""; }
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
  _adb_rd_invoke_agent "$tokens" "$pf" "$effort"; rc=$?; rm -f "$pf"
  _adb_rd_report "$target" "$tokens" "$rc"; return "$rc"
}

# --- dispatch (only when executed directly, never when sourced) --------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    resolve) adb_resolve_role "${2:-}" ;;
    invoke)  [ "$#" -ge 2 ] || { echo "usage: role-dispatch.sh invoke <role|agent> [--effort <value>]" >&2; exit 2; }
             _rd_target="$2"; shift 2; _rd_effort=""
             while [ "$#" -gt 0 ]; do
               case "$1" in
                 --effort) [ "$#" -ge 2 ] || { echo "role-dispatch: --effort needs a value" >&2; exit 2; }
                           _rd_effort="$2"; shift 2 ;;
                 *) echo "role-dispatch: unknown argument \"$1\"" >&2; exit 2 ;;
               esac
             done
             # Validate a caller-supplied effort HERE, not at the CLI. An unvalidated value would
             # otherwise reach `codex exec -c` mid-dispatch and fail opaquely, or be ignored — and
             # an ignored bound reads exactly like a bound that worked.
             if [ -n "$_rd_effort" ]; then
               case " $_ADB_RD_KNOWN_EFFORT " in
                 *" $_rd_effort "*) ;;
                 *) printf 'role-dispatch: invalid --effort "%s" (known: %s)\n' "$_rd_effort" "$_ADB_RD_KNOWN_EFFORT" >&2; exit 2 ;;
               esac
             fi
             adb_dispatch_invoke "$_rd_target" "$_rd_effort" ;;
    effort)  [ "$#" -ge 2 ] || { echo "usage: role-dispatch.sh effort <role>" >&2; exit 2; }
             # Prints the resolved effort, or NOTHING with rc 1 when nothing declares one (the
             # agent's own config governs). rc 2 = an invalid declared value.
             adb_role_effort "$2" ;;
    review-rung) adb_review_rung "${2:-}" ;;
    available) [ "$#" -ge 2 ] || { echo "usage: role-dispatch.sh available <agent>" >&2; exit 2; }
             # SILENT — the exit code IS the answer. A caller asking about several agents in a
             # ladder would otherwise have to filter this helper's chatter out of its own report.
             adb_agent_available "$2" ;;
    bots)    case "${2:-}" in
               '')            adb_dispatch_bots ;;
               --declared)    adb_dispatch_bots_declared ;;
               --comparable)  adb_dispatch_bots_comparable ;;
               *) echo "usage: role-dispatch.sh bots [--declared|--comparable]" >&2; exit 2 ;;
             esac ;;
    max-rounds) # Prints the declared re-review round cap, or NOTHING with rc 3 when nothing
             # declares one (the caller applies its own built-in). rc 2 = a declared but unusable
             # value, which is a hard error rather than a silent fall-back to that built-in.
             # `--with-source` appends the winning layer (`repo`|`global`) so a caller can name
             # which agents.toml to edit.
             adb_dispatch_max_rounds "${2:-}" ;;
    untrusted) [ "$#" -ge 2 ] || { echo "usage: role-dispatch.sh untrusted <source>   # text on stdin" >&2; exit 2; }
             # A REQUIRED <source>: the envelope's whole job is telling the reader where the text
             # came from, and a defaulted "unknown" would silently ship an unlabelled payload from
             # a caller that simply forgot the argument.
             adb_untrusted_block "$2" ;;
    *) echo "usage: role-dispatch.sh [resolve <role> | invoke <role|agent> | available <agent> | review-rung [<driver>] | bots [--declared|--comparable] | max-rounds | untrusted <source>]" >&2; exit 2 ;;
  esac
fi
