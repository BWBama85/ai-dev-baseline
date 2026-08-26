#!/usr/bin/env bash
# ai-dev-baseline — the RUN-STATE SUMMARY: what a compacted session needs read back (#431).
#
# THE QUESTION THIS MODULE ANSWERS: is there an /implement-issue run live in this state directory
# that belongs to the asking session, and what are its facts? The state directory was always
# structured note-taking — the marker carries phase, branch, issue and owner; `gaps.md`,
# `review.md` and `docs-consulted.tsv` carry the run's findings — but nothing read any of it back
# after the harness compacted the context. This is the reader. The Claude adapter
# (`agents/claude/scripts/session-context.sh`) injects its output on `compact` and `resume`; a
# Codex or Gemini workflow step can call it after their own compaction (#14).
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   run-state.sh summary --state <dir> [--session <id>]
#   run-state.sh -h | --help
#
# Exit codes:
#   0   summarised (stdout holds the summary), or NOTHING TO SAY (stdout empty): the directory is
#       absent, or holds neither a live run marker nor an unexpired run claim.
#   4   foreign — the marker (or the claim) belongs to another session. ONE line on stdout naming
#       the path; the owner id is never printed.
#   12  jq is not on PATH.
#   18  unreadable — a marker exists but is not a usable record. ONE factual line on stdout.
#   20  the state directory exists but cannot be read.
#   2   usage.
#
# OUTPUT CONTRACT — declarative `key: value` lines, one per line, in this order, each omitted when
# it has nothing to say. Every value is drawn from a CLOSED grammar the run itself wrote (a phase
# word, a branch name, issue numbers, ISO-8601 timestamps, paths under the state directory, a
# count). No issue text and no finding prose ever enters this output: the summary is injected into
# a model's context, and the prompts and findings under the state directory carry third-party text
# (base/practices/untrusted-content.md).
#
#   run-state: /implement-issue run in progress — source <dir>/implement-issue-active.json
#   phase: <phase>
#   phase-history: <phase>@<at>, <phase>@<at>, …        (only when the marker carries one, #243)
#   branch: <branch>
#   issues: #<n>, #<n>
#   pr: <url>                                            (only when prUrl is present and clean)
#   blocked: <reason>                                    (only when a matching blocked marker exists)
#   artifacts: <dir>/gap-prompt.txt, <dir>/gaps.md, …    (the run-state files that exist)
#   review-required-marks: <n>                           (only when review.md exists)
#
# Before the branch exists — steps 2-4 of the workflow, where the long gap-analysis pass runs —
# there is no marker yet; the run CLAIM (`gap-analysis.lock`) is the liveness signal and the issue
# snapshots name the issues:
#
#   run-state: /implement-issue run before branching — the run claim <dir>/gap-analysis.lock is held
#   issues: #<n>
#   artifacts: …
#
# `review-required-marks` is the number of LINES in `review.md` carrying the word REQUIRED. It is a
# count of findings the reviewer RECORDED, not of findings still open: the workflow persists no
# per-finding disposition, so "open" is not a number this file can support, and a field named for
# it would be a metric-scope mismatch. The compaction guidance in the root doc is what asks the
# compactor to carry each finding's disposition forward.
#
# OWNERSHIP. `--session` is the asking session's id; the marker's `owner` (and the claim's) is
# compared to it by `adb_owners_compatible` — the ONE home for that rule (#180, #241): either side
# empty is compatible, so a harness that exposes no id, or a marker written by one, is summarised;
# two ids that differ are foreign. A foreign marker earns one line and NO facts, the same posture
# the Stop gate takes: injecting another session's run into this one's context is the defect.
#
# VALIDATION IS WHOLE, and it is the same shape the Stop gate's marker read uses: a non-object,
# a newline or control byte in a decision field, a phase outside `[a-z_]`, an `issue` that is not
# a comma-separated list of numbers, or a `phaseHistory` that is not a list of `{phase, at}` with
# an ISO-8601 UTC `at` refuses the marker as UNREADABLE. It is refused whole rather than rendered
# in part because every field here reaches a prompt. A marker written before #243 — no
# `phaseHistory` key at all — is valid and simply carries no history line.
#
# READ ONCE, THEN RE-VERIFY. The marker is snapshotted once and the artifacts are inspected
# afterwards; the marker is then re-read and, if its bytes changed, the whole read starts over,
# twice at most. A marker that keeps changing is reported as such rather than summarised from a
# mix of two states. The marker is published by rename, so a torn read of the marker itself is
# impossible; the artifacts beside it are not, which is why only their PATHS are reported.
#
# Requires: jq. Sources scripts/lib/common.sh (beside this file) for adb_owners_compatible.

set -u

_adb_rs_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_rs_common" ]; then
  printf 'run-state: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_rs_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_rs_common"
command -v adb_owners_compatible >/dev/null 2>&1 || {
  printf 'run-state: FATAL — common.sh loaded but adb_owners_compatible is missing\n' >&2
  exit 2
}
# bash 5.3 runtime floor (#256), gated only when executed — a sourcing caller has already gated.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() {
  cat <<'EOF'
usage: run-state.sh summary --state <dir> [--session <id>]
       run-state.sh -h | --help

Print the facts of the /implement-issue run live in <dir> — phase, phase history, branch,
issue numbers, PR, blocked reason, artifact paths, REQUIRED-mark count — when that run belongs to
<id> (or to nobody). Exit 0 with empty stdout when there is nothing to say.
EOF
}

die() { printf 'run-state: %s\n' "$*" >&2; exit 2; }

# The phase vocabulary is `[a-z_]` rather than the workflow's nine-word enum on purpose: the
# property that matters for a value bound for a prompt is that it is a bare word, and a tenth
# phase added to the workflow must not make the summary refuse a healthy marker.
_RS_MARKER_JQ='
  def s: if . == null then "" elif type == "string" then . else tostring end;
  def clean: test("[\u0000-\u001f\u007f]") | not;
  if type != "object" then error("not an object") else . end
  | { b: (.branch|s), i: (.issue|s), p: (.phase|s), u: (.prUrl|s), o: (.owner|s), h: .phaseHistory }
  | if (.b == "" or (.b|clean|not)) then error("branch") else . end
  | if (.i | test("^[0-9]+(,[0-9]+)*$") | not) then error("issue") else . end
  | if (.p | test("^[a-z_]{1,32}$") | not) then error("phase") else . end
  | if (.o | clean | not) then error("owner") else . end
  | if (.h == null) then .hs = ""
    elif ((.h|type) != "array") then error("phaseHistory")
    elif ([.h[] | (type == "object")
            and ((.phase|type) == "string") and (.phase | test("^[a-z_]{1,32}$"))
            and ((.at|type) == "string")
            and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))]
          | all | not) then error("phaseHistory")
    else .hs = ([.h[] | "\(.phase)@\(.at)"] | join(", ")) end
  | .u = (if (.u | test("^https://[^\u0000-\u0020\u007f]+$")) then .u else "" end)
  | [ .b, .i, .p, .u, .o, .hs ] | .[]'

# _rs_artifacts <dir> — the run-state files that exist, as a comma-joined path list. A FIXED set:
# these are the names the workflow writes and `cleanup-lib.sh state-scan` classifies, so a file
# somebody else dropped into the directory is never named into a prompt.
_rs_artifacts() {
  local d="$1" f out=""
  for f in gap-prompt.txt gaps.md gaps.err review-prompt.txt review.md review.err docs-consulted.tsv; do
    [ -f "$d/$f" ] || continue
    out="${out:+$out, }$d/$f"
  done
  printf '%s' "$out"
}

# _rs_issues_from_snapshots <dir> — `#n, #n` from the issue-<n>.json snapshots step 2 writes.
_rs_issues_from_snapshots() {
  local d="$1" f n out=""
  for f in "$d"/issue-*.json; do
    [ -f "$f" ] || continue
    n="${f##*/issue-}"; n="${n%.json}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    out="${out:+$out, }#$n"
  done
  printf '%s' "$out"
}

# _rs_issue_list "1,2" -> "#1, #2"
_rs_issue_list() { printf '%s' "$1" | sed 's/,/, #/g; s/^/#/'; }

cmd_summary() {
  local dir="$OPT_STATE" sid="$OPT_SESSION"
  [ -n "$dir" ] || die "summary: --state is required"
  command -v jq >/dev/null 2>&1 || { printf 'run-state: jq is required\n' >&2; return 12; }
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] && [ -r "$dir" ] || { printf 'run-state: the state directory %s cannot be read\n' "$dir"; return 20; }

  local marker="$dir/implement-issue-active.json" blocked="$dir/implement-issue-blocked.json"
  local claim="$dir/gap-analysis.lock"
  local snap="" again="" fields="" attempt
  local m_branch m_issue m_phase m_pr m_owner m_hist arts req blk_reason=""

  if [ -f "$marker" ]; then
    for attempt in 1 2; do
      { snap="$(<"$marker")"; } 2>/dev/null
      [ -n "$snap" ] || { printf 'run-state: the run marker at %s is unreadable\n' "$marker"; return 18; }
      fields="$(printf '%s' "$snap" | jq -r "$_RS_MARKER_JQ" 2>/dev/null)" || fields=""
      [ -n "$fields" ] || { printf 'run-state: the run marker at %s is unreadable (not a usable record)\n' "$marker"; return 18; }
      m_branch=""; m_issue=""; m_phase=""; m_pr=""; m_owner=""; m_hist=""
      { IFS= read -r m_branch; IFS= read -r m_issue; IFS= read -r m_phase
        IFS= read -r m_pr; IFS= read -r m_owner; IFS= read -r m_hist; } <<EOF
$fields
EOF
      # Whose marker is this? Decided before any artifact is looked at, so a foreign run costs
      # one comparison and leaks nothing but the path.
      if ! adb_owners_compatible "$m_owner" "$sid"; then
        printf 'run-state: a run marker at %s belongs to another session; not summarised\n' "$marker"
        return 4
      fi
      arts="$(_rs_artifacts "$dir")"
      req=""
      if [ -f "$dir/review.md" ]; then
        req="$(grep -c 'REQUIRED' "$dir/review.md" 2>/dev/null || true)"
        case "$req" in ''|*[!0-9]*) req=0 ;; esac
      fi
      blk_reason=""
      if [ -f "$blocked" ]; then
        # The blocked file pairs with THIS marker (same branch and issue, compatible owner) or it is
        # somebody else's stop and says nothing about this run. Its reason is the run's own text;
        # a control byte in it is refused rather than injected.
        blk_reason="$(jq -r --arg b "$m_branch" --arg i "$m_issue" --arg o "$m_owner" '
          if type != "object" then empty
          elif ((.branch // "") != $b) or (((.issue // "") | tostring) != $i) then empty
          elif ((.owner // "") != "" and $o != "" and (.owner // "") != $o) then empty
          else (.reason // "" | tostring
                | if test("[\u0000-\u001f\u007f]") then "(reason withheld: control bytes)" else . end)
          end' "$blocked" 2>/dev/null)" || blk_reason=""
      fi
      { again="$(<"$marker")"; } 2>/dev/null
      [ "$again" = "$snap" ] && break
      if [ "$attempt" = 2 ]; then
        printf 'run-state: the run marker at %s changed while it was being read; not summarised\n' "$marker"
        return 0
      fi
    done
    printf 'run-state: /implement-issue run in progress — source %s\n' "$marker"
    printf 'phase: %s\n' "$m_phase"
    [ -n "$m_hist" ] && printf 'phase-history: %s\n' "$m_hist"
    printf 'branch: %s\n' "$m_branch"
    printf 'issues: %s\n' "$(_rs_issue_list "$m_issue")"
    [ -n "$m_pr" ] && printf 'pr: %s\n' "$m_pr"
    [ -n "$blk_reason" ] && printf 'blocked: %s\n' "$blk_reason"
    [ -n "$arts" ] && printf 'artifacts: %s\n' "$arts"
    [ -n "$req" ] && printf 'review-required-marks: %s\n' "$req"
    return 0
  fi

  # No marker: before the branch exists the CLAIM is the liveness signal (workflow steps 2-4).
  [ -f "$claim" ] || return 0
  local c_owner c_exp now
  c_owner="$(jq -r 'if type != "object" then "" else (.owner // "" | tostring) end' "$claim" 2>/dev/null)" || return 0
  c_exp="$(jq -r 'if type != "object" then "" else (.expiresAt // "" | tostring) end' "$claim" 2>/dev/null)" || return 0
  case "$c_exp" in ''|*[!0-9]*) return 0 ;; esac
  now="$(date -u +%s)"
  [ "$c_exp" -gt "$now" ] || return 0            # an expired claim is a dead run: nothing to say
  case "$c_owner" in *[[:cntrl:]]*) return 0 ;; esac
  if ! adb_owners_compatible "$c_owner" "$sid"; then
    printf 'run-state: a run claim at %s belongs to another session; not summarised\n' "$claim"
    return 4
  fi
  printf 'run-state: /implement-issue run before branching — the run claim %s is held\n' "$claim"
  local iss; iss="$(_rs_issues_from_snapshots "$dir")"
  [ -n "$iss" ] && printf 'issues: %s\n' "$iss"
  arts="$(_rs_artifacts "$dir")"
  [ -n "$arts" ] && printf 'artifacts: %s\n' "$arts"
  return 0
}

# --- dispatch -------------------------------------------------------------------------------------
OPT_STATE=""; OPT_SESSION=""
[ "$#" -ge 1 ] || { usage; exit 2; }
SUB="$1"; shift
case "$SUB" in -h|--help) usage; exit 0 ;; esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state)   [ "$#" -ge 2 ] || die "$SUB: --state needs a value";   OPT_STATE="$2";   shift 2 ;;
    --session) [ "$#" -ge 2 ] || die "$SUB: --session needs a value"; OPT_SESSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "$SUB: unknown option '$1'" ;;
  esac
done
case "$SUB" in
  summary) cmd_summary ;;
  *)       die "unknown subcommand '$SUB' (summary)" ;;
esac
