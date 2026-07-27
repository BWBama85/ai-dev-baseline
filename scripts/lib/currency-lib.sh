#!/usr/bin/env bash
# ai-dev-baseline — install-currency TRIGGER POLICY (issues #36 + #139).
#
# `bin/baseline update` already does the work, safely, and owns the unsafe-state ladder (dirty /
# in-progress / ahead / diverged / detached / not-default are all refused) plus its own flock. What
# this library owns is the layer above it: WHEN running it is safe and free of surprises, and what
# a given outcome should be reported as. That policy used to live inside the Claude `SessionStart`
# hook, which made it unreachable from anywhere else — and #139 is what that cost: currency had
# exactly ONE trigger, bound to `source: startup`, so the baseline's own loop
# (`/implement-issue -> merge -> /cleanup -> /clear -> /roadmap`) never re-checked. Staleness
# begins at the merge and the next step in the loop could not notice.
#
# TWO CALLERS, ONE POLICY:
#   - agents/claude/scripts/session-currency.sh   (trigger `startup`, unattended)
#   - base/workflows/cleanup.md                   (trigger `cleanup`, deliberate, all three agents)
# The workflow path is why this is a `scripts/lib` module rather than more hook code: install.sh
# symlinks this whole directory into ~/.claude, ~/.codex and ~/.gemini, so Codex and Gemini get
# currency from the same source. A Claude-only hook could never give them that.
#
# NOT A PREDICATE LIBRARY, DELIBERATELY. Its sibling scripts/lib/cleanup-lib.sh opens with a
# network-purity contract ("No subcommand here ever calls `gh` … the workflow owns every live
# read") because its answers gate `rm` and ref deletes and must be hermetically testable. This
# library is the opposite kind of thing: an EXECUTOR. `check` fetches, pulls and re-runs the
# installer. Keep them separate rather than blurring one contract into the other — and keep the
# pure decisions here (`mode`, `same-clone`, `stamp-fresh`) individually callable so they can be
# tested without the network.
#
# OUTCOME PROTOCOL — one machine record, presentation left to the caller. `check` prints exactly
# one line:
#
#     <outcome><TAB><message>
#
# outcome is one of:
#   silent    nothing happened worth reporting (already current)      message empty
#   updated   the clone advanced; installed payload changed
#   repaired  same HEAD, but a broken installed link was restored
#   behind    notify mode: the clone IS behind and was left alone
#   refused   `baseline` refused for safety; message names the clone state
#   offline   the remote was unreachable / unresolvable
#   busy      a peer `baseline update` holds the lock
#   failed    `baseline update` failed; message says how
#   skipped   policy declined to run at all (mode=off, self-clone, rate-limited, no install)
#
# WHY a record instead of a ready-made line: the two triggers legitimately disagree about what
# deserves the operator's attention. The startup hook deliberately says NOTHING for `busy` and
# `offline` — it must never nag at every session start about a missing network — while #139
# requires `/cleanup` to print one line when an update was unreachable or refused, because there
# the operator just asked for it. Baking one rc->line mapping into this library would force one of
# those two behaviors to be wrong. Classification is shared; presentation is the caller's.
#
# EVERY PATH IS BOUNDED. `check` runs `baseline update` under adb_run_bounded (common.sh), because
# `/cleanup` has no harness timeout at all — the Claude hook's 60 s settings timeout does not exist
# for Codex, Gemini, or a workflow step. git's own network bounds are set too (no credential
# prompt, no stalled transfer), but those cannot bound a local wedge, and an unbounded currency
# check inside a sweep would hang the sweep.
#
# Usage:
#   currency-lib.sh mode                                  # auto|notify|off
#   currency-lib.sh same-clone   <dir-a> <dir-b>           # exit 0 = the same repository
#   currency-lib.sh stamp-fresh  <stamp-path> <interval>   # exit 0 = suppressed by the rate limit
#   currency-lib.sh check --trigger startup|cleanup [--cwd <dir>]
#   currency-lib.sh -h | --help
#
# Requires: git. `bin/baseline` is resolved from the install-source clone.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) ----------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), resolved the same one-line way every sibling module does.
_adb_cu_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_cu_common" ]; then
  printf 'currency-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_cu_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_cu_common"

usage() { adb_usage "$0"; }
die() { printf 'currency-lib: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"

# The wall-clock bound on one `baseline update`. This is a fetch + a fast-forward pull + an
# idempotent symlink pass — seconds of work — so the bound is a backstop for a wedge, not a work
# budget, and it is deliberately nothing like role-dispatch's 45-minute agent bound.
_ADB_CU_TIMEOUT_SECS="${ADB_CURRENCY_TIMEOUT_SECS:-120}"
case "$_ADB_CU_TIMEOUT_SECS" in ''|*[!0-9]*) _ADB_CU_TIMEOUT_SECS=120 ;; 0) _ADB_CU_TIMEOUT_SECS=120 ;; esac
_ADB_CU_KILL_GRACE_SECS="${ADB_CURRENCY_KILL_GRACE_SECS:-5}"

# The default rate-limit interval, and the stamp both triggers share. See `check` for why the
# `cleanup` trigger reads it differently from the way it writes it.
_ADB_CU_INTERVAL_DEFAULT=600
_adb_cu_stamp_dir() { printf '%s/ai-dev-baseline\n' "${XDG_CACHE_HOME:-$HOME/.cache}"; }
_adb_cu_stamp() { printf '%s/session-currency.stamp\n' "$(_adb_cu_stamp_dir)"; }

# --- mode ---------------------------------------------------------------------------------------
# Print auto|notify|off, exit 0 always. An unset / misspelled / unreadable value degrades to the
# documented default (auto) rather than failing — currency is a convenience and must never be the
# reason something looks broken.
#
# Read from the GLOBAL manifest ONLY. A project's agents.toml is deliberately not consulted: an
# arbitrary repo you happen to open must not control whether your global tooling updates. That
# matters more now than it did for #36, because `/cleanup` runs this from inside whatever repo the
# operator is standing in.
#
# The key is still spelled `session_start` even though it now governs two triggers. Honoring the
# EXISTING key is what keeps every already-configured machine working — an `off` that silently
# stopped applying would re-enable an updater its owner had switched off, which is the worst
# possible direction for this class of change. The neutral rename is tracked separately.
cmd_mode() {
  [ "$#" -eq 0 ] || die "mode: takes no arguments"
  local m="${ADB_SESSION_UPDATE:-}"
  if [ -z "$m" ]; then
    m="$(adb_toml_unquote "$(adb_toml_get "$(adb_global_manifest)" updates session_start 2>/dev/null)")"
  fi
  case "$m" in
    off|notify|auto) printf '%s\n' "$m" ;;
    *)               printf 'auto\n' ;;
  esac
}

# --- same-clone ---------------------------------------------------------------------------------
# Exit 0 iff both paths are the same REPOSITORY. Compares the COMMON git dir, not the work-tree
# root: a linked worktree of the install-source is a different toplevel but the same repository,
# and fast-forwarding the main clone under it is the same surprise. `-ef` is device+inode, so two
# spellings of one path match, and comparing roots (not raw paths) means a session started in a
# SUBDIRECTORY still matches.
#
# Both sides must resolve the common dir the same way. Falling back to --absolute-git-dir on one
# side would compare a worktree's own .git/worktrees/<name> against the main clone's .git —
# unequal, so the guard would silently miss exactly the case it exists for.
_adb_cu_common_git_dir() {
  local d="$1" out
  out="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  # Older git: --git-common-dir may print a path relative to <d>, so resolve it from there.
  out="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  ( cd "$d" 2>/dev/null && cd "$out" 2>/dev/null && pwd -P )
}

cmd_same_clone() {
  [ "$#" -eq 2 ] || die "same-clone: needs exactly 2 args: <dir-a> <dir-b>"
  local a b
  a="$(_adb_cu_common_git_dir "$1" || true)"
  b="$(_adb_cu_common_git_dir "$2" || true)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -ef "$b" ]
}

# --- stamp-fresh --------------------------------------------------------------------------------
# Exit 0 iff the rate limit SUPPRESSES a check right now (the stamp exists and is younger than
# <interval>). Interval 0 disables the limit, so this always exits 1 there.
#
# An unreadable age is treated as "not suppressed": the safe direction is a redundant fetch, never
# an indefinitely suppressed one. adb_age_secs already refuses to return a negative age (a clock
# skew or a restored cache would otherwise read as "checked very recently" forever).
cmd_stamp_fresh() {
  [ "$#" -eq 2 ] || die "stamp-fresh: needs exactly 2 args: <stamp-path> <interval-secs>"
  local stamp="$1" interval="$2" age
  case "$interval" in ''|*[!0-9]*) die "stamp-fresh: <interval-secs> must be a non-negative integer (got '$interval')" ;; esac
  [ "$interval" -gt 0 ] || return 1
  age="$(adb_age_secs "$stamp")"
  [ -n "$age" ] && [ "$age" -lt "$interval" ]
}

# --- check --------------------------------------------------------------------------------------
# The whole policy, for one trigger. Prints ONE outcome record and exits 0 — always. A currency
# check is housekeeping: it must never be the reason a session start looks broken or a `/cleanup`
# sweep aborts, so even an internal failure resolves to a record rather than a status.
cmd_check() {
  local trigger="" cwd="" interval=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -ge 2 ] || die "check: --trigger needs a value"; trigger="$2"; shift 2 ;;
      --cwd)     [ "$#" -ge 2 ] || die "check: --cwd needs a value";     cwd="$2";     shift 2 ;;
      --interval) [ "$#" -ge 2 ] || die "check: --interval needs a value"; interval="$2"; shift 2 ;;
      *) die "check: unknown argument: $1" ;;
    esac
  done
  case "$trigger" in
    startup|cleanup) ;;
    *) die "check: --trigger must be startup or cleanup (got '${trigger:-}')" ;;
  esac
  [ -n "$cwd" ] || cwd="$PWD"

  # 1. mode. `off` disables BOTH triggers — the operator switched the updater off, and honoring
  #    that only for the hook would quietly reintroduce an updater they had disabled.
  local mode; mode="$(cmd_mode)"
  [ "$mode" = off ] && { _adb_cu_emit skipped ""; return 0; }

  # 2. the install-source. Nothing installed by symlink -> nothing to keep current. This is the
  #    ordinary state of a machine that never ran install.sh, so it is silent, not a failure.
  local src; src="$(adb_install_source)" || { _adb_cu_emit skipped ""; return 0; }
  [ -x "$src/bin/baseline" ] || { _adb_cu_emit skipped ""; return 0; }

  # 3. never update the clone the caller is working IN. Updating the clone you are editing is
  #    exactly the "pulled out from under active work" case. For `/cleanup` this is also what
  #    keeps a baseline developer's own `-dev` sweep from fast-forwarding the clone under them.
  if cmd_same_clone "$cwd" "$src"; then _adb_cu_emit skipped ""; return 0; fi

  # 4. the rate limit — and the ONE place the two triggers deliberately differ.
  #
  #    The stamp records the last ATTEMPT and cannot distinguish "startup just checked and nothing
  #    changed" from "startup checked, and then a baseline merge landed". For an unattended check
  #    at every session start that is the right trade: several sessions an hour must not each cost
  #    a network round trip.
  #
  #    For `/cleanup` it is the WRONG trade, and suppressing there would defeat the whole point of
  #    #139: `/cleanup` runs immediately after a merge, which is precisely the moment the stamp is
  #    freshest and the clone is most likely stale. So the `cleanup` trigger BYPASSES the read
  #    while still WRITING the stamp below — the deliberate, operator-initiated check always
  #    happens, and the next session start is still suppressed by it. Two back-to-back sweeps
  #    therefore each fetch, which is the correct cost for an explicitly requested action.
  local stamp; stamp="$(_adb_cu_stamp)"
  if [ -z "$interval" ]; then
    case "$trigger" in
      startup) interval="${ADB_SESSION_UPDATE_INTERVAL_SECS:-$_ADB_CU_INTERVAL_DEFAULT}" ;;
      cleanup) interval=0 ;;
    esac
  fi
  case "$interval" in ''|*[!0-9]*) interval="$_ADB_CU_INTERVAL_DEFAULT" ;; esac
  if cmd_stamp_fresh "$stamp" "$interval"; then _adb_cu_emit skipped ""; return 0; fi

  # 5. bound git's network and interaction BEFORE any of it runs. Without these an HTTPS remote
  #    with no cached credential blocks on a terminal read forever — the one failure mode a
  #    timeout cannot make graceful. Each is set only when the caller has not, so a deliberate
  #    local git configuration always wins.
  [ -n "${GIT_TERMINAL_PROMPT:-}" ] || export GIT_TERMINAL_PROMPT=0
  [ -n "${GIT_ASKPASS:-}" ]         || export GIT_ASKPASS=true
  [ -n "${SSH_ASKPASS:-}" ]         || export SSH_ASKPASS=true
  # GIT_SSH_COMMAND outranks the repository's own core.sshCommand, so setting it unconditionally
  # would replace a configured identity file / proxy / custom ssh binary with plain `ssh` — the
  # fetch then fails for a clone that works perfectly from the command line. Only install the
  # default when the clone does not configure its own.
  if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git -C "$src" config --get core.sshCommand 2>/dev/null)" ]; then
    export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'
  fi

  # 6. record the attempt BEFORE running it. A crash or a harness kill mid-update must not make
  #    the next trigger retry immediately and hit the same wall.
  mkdir -p "$(_adb_cu_stamp_dir)" 2>/dev/null && : > "$stamp" 2>/dev/null

  # 7. notify: report, change nothing. Precisely: it does not change the working tree or the
  #    installed payload — `--check` still fetches remote-tracking refs, which is what makes the
  #    answer true rather than remembered.
  #
  #    `behind` ONLY. A clone deliberately parked on a branch, or left dirty, would otherwise
  #    produce an attention line at every trigger past the rate limit, forever, for a state its
  #    owner created on purpose — in the very mode chosen to be quiet. `baseline update` says so
  #    plainly when they run it.
  local status rc
  if [ "$mode" = notify ]; then
    status="$(adb_run_bounded "$_ADB_CU_TIMEOUT_SECS" "$_ADB_CU_KILL_GRACE_SECS" \
                "$src/bin/baseline" update --check 2>/dev/null | head -n1)" || true
    case "$status" in
      behind) _adb_cu_emit behind "install-source is behind origin — run 'baseline update'." ;;
      *)      _adb_cu_emit silent "" ;;
    esac
    return 0
  fi

  # 8. auto: update. The outcome is read from the EXIT CODE and the before/after HEAD, never by
  #    parsing `baseline`'s human-facing prose — prose is free to change, the contract is not.
  local before after n
  before="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)"
  adb_run_bounded "$_ADB_CU_TIMEOUT_SECS" "$_ADB_CU_KILL_GRACE_SECS" \
    "$src/bin/baseline" update >/dev/null 2>&1
  rc=$?
  after="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)"

  case "$rc" in
    0)
      # Unchanged HEAD means it was already current — nothing worth reporting.
      if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
        n="$(git -C "$src" rev-list --count "$before..$after" 2>/dev/null)"
        case "$n" in ''|*[!0-9]*) n="" ;; esac
        if [ "$n" = "1" ]; then
          _adb_cu_emit updated "updated $before → $after (1 commit)."
        elif [ -n "$n" ]; then
          _adb_cu_emit updated "updated $before → $after ($n commits)."
        else
          _adb_cu_emit updated "updated $before → $after."
        fi
      else
        _adb_cu_emit silent ""
      fi
      ;;
    6)
      # A same-HEAD repair: already current, but a broken installed link was restored. HEAD did
      # not move, so a caller inferring "something changed" from the delta would miss it entirely.
      _adb_cu_emit repaired "repaired the installed links (clone already current)."
      ;;
    5)  _adb_cu_emit busy "another 'baseline update' is already running for the install-source." ;;
    20) _adb_cu_emit refused \
          "install-source not updated ($(adb_clone_status "$src" "$(adb_default_branch "$src")" 2>/dev/null)) — reconcile $src, then 'baseline update'." ;;
    30) _adb_cu_emit offline "install-source remote unreachable — currency not verified." ;;
    124)
      # Our own bound fired. Distinct from `offline`: the remote may be fine and something is
      # wedged, so it must not be reported as a missing network.
      _adb_cu_emit failed "'baseline update' exceeded ${_ADB_CU_TIMEOUT_SECS}s and was stopped — run it manually to see why."
      ;;
    *)
      # Includes exit 1: git advanced but the install did not fully heal. That one MUST be loud —
      # a half-repaired global install is the silent-staleness failure this exists to prevent.
      if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
        _adb_cu_emit failed "clone updated $before → $after but the global install needs repair — run 'baseline update'."
      else
        _adb_cu_emit failed "'baseline update' failed (exit $rc) — run it manually to see why."
      fi
      ;;
  esac
  return 0
}

# Emit the one outcome record. A literal TAB separates the fields, and the message is single-line
# by construction (every caller above passes one); newlines are stripped anyway so a message that
# ever grew one cannot break the record into two.
_adb_cu_emit() {
  printf '%s%s%s\n' "$1" "$TAB" "$(printf '%s' "$2" | tr -d '\n\r')"
}

# --- dispatch -----------------------------------------------------------------------------------
main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    mode)         cmd_mode "$@" ;;
    same-clone)   cmd_same_clone "$@" ;;
    stamp-fresh)  cmd_stamp_fresh "$@" ;;
    check)        cmd_check "$@" ;;
    *) printf 'currency-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
