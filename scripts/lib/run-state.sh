#!/usr/bin/env bash
# ai-dev-baseline — the RUN-STATE SUMMARY (#431): what a compacted or resumed session reads back
# about the /implement-issue run live in a state directory. Design and rationale: decision D92.
#
# Usage:
#   run-state.sh summary --state <dir> [--session <id>]
#   run-state.sh -h | --help
#
# Exit codes:
#   0   summarised (stdout holds the summary), or NOTHING TO SAY (stdout empty): the directory is
#       absent, or holds neither a run marker nor an unexpired run claim.
#   4   foreign — the marker (or the claim) belongs to another session. One line naming the path;
#       the owner id is never printed.
#   12  jq is not on PATH.
#   18  unreadable — a marker or claim exists but is not a usable record. One factual line.
#   20  the state directory exists but cannot be read or scanned.
#   2   usage, or a <dir> carrying a control/format character, or an <id> carrying whitespace or a
#       control/format character (both are printed into a line-structured document, so they are
#       refused rather than rendered; a space in <dir> is ordinary and allowed).
#
# Output — declarative `key: value` lines, in this order, each omitted when it has nothing to say:
#   run-state: /implement-issue run in progress — source <dir>/implement-issue-active.json
#   phase: <phase>
#   phase-history: <phase>@<at>, …                       (when the marker carries one, #243)
#   branch: <branch>
#   issues: #<n>, #<n>
#   pr: <url>                                            (when prUrl is present)
#   blocked: yes — reason recorded in <dir>/implement-issue-blocked.json
#   artifacts: <path>, …                                 (every gaps/review/docs record present)
#   unsafe-names: <n>                                    (records `state-scan` refused to name)
#   review-required-marks: <n> | unreadable              (when review.md exists)
# Before the branch exists the run CLAIM is the liveness signal:
#   run-state: /implement-issue run before branching — the run claim <dir>/gap-analysis.lock is held
#   issues: #<n>, …                                      (from the issue-<n>.json snapshots)
#   artifacts: …
#
# CONTRACT — every value is a closed-grammar scalar the run itself wrote, because this output lands
# in a model's context (base/practices/untrusted-content.md):
#   - branch, owner: non-empty strings with no whitespace and no character of Unicode category
#     Cc, Cf, Zl or Zp, <=255 / <=128 chars; issue: `n(,n)*`; phase: `[a-z_]{1,32}`;
#     prUrl: `https://` + <=512 non-whitespace/non-control chars; phaseHistory: <=64 entries of
#     {phase, at} with a plausible ISO-8601 UTC `at`, non-decreasing, whose last phase is `.phase`.
#     A pre-#243 marker (no `phaseHistory` key) is valid. Any other value — including a non-string
#     where a string is required, `false` for an absent field included — refuses the marker WHOLE
#     (18). Nothing is coerced, and only `null`/absent reads as "not present".
#   - the blocked marker's `reason` is free text and is never printed; its PATH is.
#   - artifact paths come from `cleanup-lib.sh state-scan`, the one home for what a state file IS;
#     a name it refuses to serialize — or one carrying any control/format character, which it
#     does not refuse (it rejects only its own delimiters) — is counted, never printed.
#   - `review-required-marks` counts LINES of review.md carrying the word REQUIRED — recorded
#     marks, not open findings (the workflow persists no per-finding disposition).
#   - ownership is `adb_owners_compatible` (either side empty = compatible, as the Stop gate).
#   - the marker is read once, the artifacts are inspected, then the marker is re-read; a changed
#     marker restarts the read once and is otherwise reported as changed, never mixed. The claim
#     is read once. `review.md` may be mid-write; only its line count is read.
#
# Requires: jq; scripts/lib/common.sh and scripts/lib/cleanup-lib.sh beside this file.

set -u

_adb_rs_lib="$(dirname "${BASH_SOURCE[0]:-$0}")"
if [ ! -f "$_adb_rs_lib/common.sh" ] || [ ! -f "$_adb_rs_lib/cleanup-lib.sh" ]; then
  printf 'run-state: FATAL — required library not found beside %s (common.sh, cleanup-lib.sh) — broken/incomplete install\n' "$_adb_rs_lib" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_rs_lib/common.sh" >/dev/null 2>&1
command -v adb_owners_compatible >/dev/null 2>&1 || {
  printf 'run-state: FATAL — common.sh loaded but adb_owners_compatible is missing\n' >&2
  exit 2
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() {
  cat <<'EOF'
usage: run-state.sh summary --state <dir> [--session <id>]
       run-state.sh -h | --help

Print the facts of the /implement-issue run live in <dir> — phase, phase history, branch,
issue numbers, PR, blocked state, artifact paths, REQUIRED-mark count — when that run belongs to
<id> (or to nobody). Exit 0 with empty stdout when there is nothing to say.
EOF
}

die() { printf 'run-state: %s\n' "$*" >&2; exit 2; }

# The character class every printed scalar must be free of: the Unicode CATEGORIES Cc (controls,
# C0/C1/DEL), Cf (format: bidi controls, zero-width joiners, soft hyphen, U+061C, U+180E, BOM, …),
# Zl and Zp (line and paragraph separators) — categories, not an enumerated list, so a code point
# the list forgot cannot slip through. `unsafe` adds whitespace on top, for the values that are
# words (branch, owner, session, URL); `unsafe_path` does not, because a checkout path
# legitimately carries spaces and a space cannot forge a line. One jq definition, prepended to
# every program that needs it.
_RS_UNSAFE_JQ='
  def unsafe: test("[\\s\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]");
  def unsafe_path: test("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}]");'

_RS_MARKER_JQ='
  def str(f; max): (f|type) == "string" and ((f|length) <= max);
  def iso: test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$");
  if type != "object" then error("not an object") else . end
  | if (str(.branch; 255) and .branch != "" and (.branch|unsafe|not)) then . else error("branch") end
  | .issue = (if (.issue|type) == "number" then (.issue|tostring) else .issue end)
  | if (str(.issue; 64) and (.issue | test("^[0-9]+(,[0-9]+)*$"))) then . else error("issue") end
  | if (str(.phase; 32) and (.phase | test("^[a-z_]{1,32}$"))) then . else error("phase") end
  | .owner = (if .owner == null then "" else .owner end)
  | if (str(.owner; 128) and (.owner|unsafe|not)) then . else error("owner") end
  | .prUrl = (if .prUrl == null then "" else .prUrl end)
  | if (str(.prUrl; 512) and (.prUrl == "" or ((.prUrl | test("^https://")) and (.prUrl | unsafe | not)))) then . else error("prUrl") end
  | .h = .phaseHistory
  | if (.h == null) then .hs = ""
    elif ((.h|type) != "array") then error("phaseHistory")
    elif ((.h|length) > 64) then error("phaseHistory")
    elif ([.h[] | (type == "object") and str(.phase; 32) and (.phase | test("^[a-z_]{1,32}$"))
                   and str(.at; 20) and (.at | iso)] | all | not) then error("phaseHistory")
    elif ((.h|length) > 0 and (.h[-1].phase != .phase)) then error("phaseHistory")
    elif ([.h[].at] | . == sort | not) then error("phaseHistory")
    else .hs = ([.h[] | "\(.phase)@\(.at)"] | join(", ")) end
  | [ .branch, .issue, .phase, .prUrl, .owner, .hs ] | .[]'

_RS_CLAIM_JQ='
  if type != "object" then error("not an object") else . end
  | .owner = ((if .owner == null then "" else .owner end) | if type == "string" then . else error("owner") end)
  | if (.owner | unsafe) then error("owner") else . end
  | .expiresAt = (.expiresAt // 0 | if type == "number" then floor else error("expiresAt") end)
  | [ .owner, (.expiresAt|tostring) ] | .[]'

_rs_issue_list() { printf '%s' "$1" | sed 's/,/, #/g; s/^/#/'; }

# _rs_scan <dir> — `state-scan` once; sets RS_ARTS (gaps/review/docs paths, sorted, comma-joined),
# RS_ISSUES (`#n, …` from the issue snapshots) and RS_UNSAFE (count of refused names).
_rs_scan() {
  local scan kind sfile key n
  RS_ARTS=""; RS_ISSUES=""; RS_UNSAFE=0
  scan="$(bash "$_adb_rs_lib/cleanup-lib.sh" state-scan "$1" 2>/dev/null)" || return 1
  # `state-scan` refuses only tab and newline in a name (its own delimiters); this output is a
  # line-structured document in a prompt, so every other control or format character is refused
  # here, by re-classifying such a record as `unsafe` before its path can be printed.
  scan="$(printf '%s\n' "$scan" | jq -rR "$_RS_UNSAFE_JQ"' split("\t") | select(length >= 2)
    | if (.[1] | unsafe_path) then "unsafe\t-" else "\(.[0])\t\(.[1])" end' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r kind sfile key; do
    [ -n "$kind" ] || continue
    case "$kind" in
      gaps|review|docs) RS_ARTS="${RS_ARTS:+$RS_ARTS, }$sfile" ;;
      issue)  case "$sfile" in *.json) ;; *) continue ;; esac
              n="${sfile##*/issue-}"; n="${n%.json}"
              case "$n" in ''|*[!0-9]*) continue ;; esac
              RS_ISSUES="${RS_ISSUES:+$RS_ISSUES, }#$n" ;;
      unsafe) RS_UNSAFE=$((RS_UNSAFE + 1)) ;;
    esac
  done <<EOF
$(printf '%s\n' "$scan" | LC_ALL=C sort -t "$(printf '\t')" -k2,2)
EOF
  : "$key"   # read so a fourth field can never spill into `sfile`; not otherwise used
  return 0
}

cmd_summary() {
  local dir="$OPT_STATE" sid="$OPT_SESSION"
  [ -n "$dir" ] || die "summary: --state is required"
  command -v jq >/dev/null 2>&1 || { printf 'run-state: jq is required\n' >&2; return 12; }
  # Both are printed into a line-structured document: a control or format character in the path,
  # or any whitespace in the session id, would forge a line — refused before anything is read.
  # A SPACE in the path is ordinary (`~/My Projects/repo`) and is allowed.
  case "$(jq -rn --arg d "$dir" --arg s "$sid" "$_RS_UNSAFE_JQ"' if (($d|unsafe_path) or ($s|unsafe)) then "bad" else "ok" end')" in
    ok) : ;;
    *) die "summary: --state carries a control character, or --session whitespace or a control character — refused" ;;
  esac
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] && [ -r "$dir" ] || { printf 'run-state: the state directory %s cannot be read\n' "$dir"; return 20; }

  local marker="$dir/implement-issue-active.json" blocked="$dir/implement-issue-blocked.json"
  local claim="$dir/gap-analysis.lock"
  local snap="" again="" fields="" attempt req="" blk="" grc
  local m_branch m_issue m_phase m_pr m_owner m_hist

  if [ -f "$marker" ]; then
    for attempt in 1 2; do
      { snap="$(<"$marker")"; } 2>/dev/null
      [ -n "$snap" ] || { printf 'run-state: the run marker at %s is unreadable\n' "$marker"; return 18; }
      fields="$(printf '%s' "$snap" | jq -r "$_RS_UNSAFE_JQ $_RS_MARKER_JQ" 2>/dev/null)" || fields=""
      [ -n "$fields" ] || { printf 'run-state: the run marker at %s is unreadable (not a usable record)\n' "$marker"; return 18; }
      m_branch=""; m_issue=""; m_phase=""; m_pr=""; m_owner=""; m_hist=""
      { IFS= read -r m_branch; IFS= read -r m_issue; IFS= read -r m_phase
        IFS= read -r m_pr; IFS= read -r m_owner; IFS= read -r m_hist; } <<EOF
$fields
EOF
      if ! adb_owners_compatible "$m_owner" "$sid"; then
        printf 'run-state: a run marker at %s belongs to another session; not summarised\n' "$marker"
        return 4
      fi
      _rs_scan "$dir" || { printf 'run-state: the state directory %s could not be scanned\n' "$dir"; return 20; }
      req=""
      if [ -f "$dir/review.md" ]; then
        req="$(grep -cw 'REQUIRED' "$dir/review.md" 2>/dev/null)"; grc=$?
        case "$grc" in 0|1) : ;; *) req="unreadable" ;; esac   # 1 = no match (grep prints 0)
        case "$req" in ''|*[!0-9a-z]*) req="unreadable" ;; esac
      fi
      blk=""
      if [ -f "$blocked" ]; then
        # The blocked file pairs with THIS marker (same branch and issue, compatible owner) or it
        # is another run's stop. Its `reason` is free text and stays in the file; the path is named.
        blk="$(jq -r --arg b "$m_branch" --arg i "$m_issue" --arg o "$m_owner" '
          if type != "object" then "no"
          elif ((.branch // "") != $b) or (((.issue // "") | tostring) != $i) then "no"
          elif (((.owner // "") | tostring) != "" and $o != "" and ((.owner // "") | tostring) != $o) then "no"
          else "yes" end' "$blocked" 2>/dev/null)" || blk="no"
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
    [ "$blk" = yes ] && printf 'blocked: yes — reason recorded in %s\n' "$blocked"
    [ -n "$RS_ARTS" ] && printf 'artifacts: %s\n' "$RS_ARTS"
    [ "$RS_UNSAFE" -gt 0 ] && printf 'unsafe-names: %s\n' "$RS_UNSAFE"
    [ -n "$req" ] && printf 'review-required-marks: %s\n' "$req"
    return 0
  fi

  # No marker: before the branch exists the CLAIM is the liveness signal (workflow steps 2-4).
  # Read ONCE; owner and lease come from the same bytes.
  [ -f "$claim" ] || return 0
  { snap="$(<"$claim")"; } 2>/dev/null
  fields="$(printf '%s' "$snap" | jq -r "$_RS_UNSAFE_JQ $_RS_CLAIM_JQ" 2>/dev/null)" || fields=""
  [ -n "$fields" ] || { printf 'run-state: the run claim at %s is unreadable (not a usable record)\n' "$claim"; return 18; }
  local c_owner="" c_exp="" now
  { IFS= read -r c_owner; IFS= read -r c_exp; } <<EOF
$fields
EOF
  now="$(date -u +%s)"
  [ "$c_exp" -gt "$now" ] 2>/dev/null || return 0   # an expired claim is a dead run: nothing to say
  if ! adb_owners_compatible "$c_owner" "$sid"; then
    printf 'run-state: a run claim at %s belongs to another session; not summarised\n' "$claim"
    return 4
  fi
  _rs_scan "$dir" || { printf 'run-state: the state directory %s could not be scanned\n' "$dir"; return 20; }
  printf 'run-state: /implement-issue run before branching — the run claim %s is held\n' "$claim"
  [ -n "$RS_ISSUES" ] && printf 'issues: %s\n' "$RS_ISSUES"
  [ -n "$RS_ARTS" ] && printf 'artifacts: %s\n' "$RS_ARTS"
  [ "$RS_UNSAFE" -gt 0 ] && printf 'unsafe-names: %s\n' "$RS_UNSAFE"
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
