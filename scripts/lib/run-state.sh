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
#   phase-history: [(N earlier omitted) ]<phase>@<at>, …   (when the marker carries one, #243; last 64)
#   branch: <branch>                                     (an issue-<n>-<slug> branch: slug elided)
#   issues: #<n>, #<n>
#   pr: <url>                                            (when prUrl is present)
#   blocked: yes — reason recorded in <dir>/implement-issue-blocked.json
#   artifacts: <path>, …                                 (every gaps/review/docs record present)
#   unsafe-names: <n>                                    (records `state-scan` refused to name)
#   unnamed-artifacts: <n>                               (family members outside the opaque name grammar)
#   review-required-marks: <n> | unreadable              (when review.md exists)
# Before the branch exists the run CLAIM is the liveness signal:
#   run-state: /implement-issue run before branching — the run claim <dir>/gap-analysis.lock is held
#   issues: #<n>, …                                      (from the issue-<n>.json snapshots)
#   artifacts: …
#
# CONTRACT — every value is a closed-grammar scalar the run itself wrote, because this output lands
# in a model's context (base/practices/untrusted-content.md):
#   - branch, owner: non-empty strings with no whitespace and no character of Unicode category
#     Cc, Cf, Zl or Zp, <=255 / <=128 chars — `owner` may be ABSENT (unowned), never present and
#     empty or null; a branch of the workflow's own shape `issue-<n>[-<n>…]-<slug>` is RENDERED
#     with the slug elided, because the slug is cut from the issue title (third-party text);
#     issue: `n(,n)*`; phase: `[a-z_]{1,32}`;
#     prUrl: `https://` + <=512 non-whitespace/non-control chars; phaseHistory: >=1 entries of
#     {phase, at} with a plausible ISO-8601 UTC `at`, whose last phase is `.phase` and in which no
#     two ADJACENT entries share a phase (every writer suppresses that append); the LAST 64 are
#     rendered, with a count of earlier ones, so the line stays bounded while the workflow's
#     append-only record does not have to be. Append order is
#     the record; the timestamps are NOT required to be monotonic, because a wall clock that moved
#     backwards mid-run does not make the marker the workflow wrote malformed. `prUrl`, like
#     `owner`, may be absent, never present and empty. A claim's `expiresAt` is a non-negative
#     integer below 10^15 (a shell integer) that RENDERS as decimal digits — jq 1.7 keeps a
#     literal's form, so `1e14` comes back as `1E+14` and is refused, never a float or an exponent.
#     A pre-#243 marker (no `phaseHistory` key) is valid; a present `null` or EMPTY history is not
#     (every writer seeds one entry). `at` is a real calendar date (no Feb 31, no Apr 31). Any other value — including a non-string where a string is required,
#     `false` for an absent field included — refuses the marker WHOLE (18). So does a file that is
#     not exactly one JSON value, or that carries a NUL byte. Nothing is coerced, and only
#     `null`/absent reads as "not present".
#   - the blocked marker's `reason` is free text and is never printed; its PATH is.
#   - artifact paths come from `cleanup-lib.sh state-scan`, the one home for what a state file IS;
#     a name it refuses to serialize, one carrying any control/format character (it rejects only
#     its own delimiters), or one outside the workflow's own name grammar `[A-Za-z0-9._-]{1,64}`
#     — a printable name can be prose — is counted, never printed.
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
# legitimately carries spaces and a space cannot forge a line. BOTH refuse U+FFFD: jq replaces
# every byte that is not valid UTF-8 with that character on input, so a value carrying one is
# not the value that was stored — a marker field is refused whole, a name is counted and never
# printed. One jq definition, prepended to every program that needs it.
_RS_UNSAFE_JQ='
  def one: if length != 1 then error("not one value") else .[0] end;
  def unsafe: test("[\\s\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}" + ([65533]|implode) + "]");
  def unsafe_path: test("[\\p{Cc}\\p{Cf}\\p{Zl}\\p{Zp}" + ([65533]|implode) + "]");'

_RS_MARKER_JQ='
  one
  | def str(f; max): (f|type) == "string" and ((f|length) <= max);
  def iso: test("^[0-9]{4}-((0[13578]|1[02])-(0[1-9]|[12][0-9]|3[01])|(0[469]|11)-(0[1-9]|[12][0-9]|30)|02-(0[1-9]|1[0-9]|2[0-9]))T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$");
  # A PR URL: hostname LABELS (a letter or digit at each end, no empty label — `https://./x` is not a
  # host), an optional port in 1..65535, then a non-empty path in closed classes.
  def prurl: test("^https://[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/[A-Za-z0-9._~/-]+$");
  if type != "object" then error("not an object") else . end
  | if (str(.branch; 255) and .branch != "" and (.branch|unsafe|not)) then . else error("branch") end
  | .issue = (if (.issue|type) == "number" then (.issue|tostring) else .issue end)
  | if (str(.issue; 64) and (.issue | test("^[0-9]+(,[0-9]+)*$"))) then . else error("issue") end
  | if (str(.phase; 32) and (.phase | test("^[a-z_]{1,32}$"))) then . else error("phase") end
  | (has("owner")) as $had_owner
  | .owner = (if $had_owner then .owner else "" end)
  | if (str(.owner; 128) and (.owner|unsafe|not) and (($had_owner|not) or (.owner != ""))) then . else error("owner") end
  | (has("prUrl")) as $had_pr
  | .prUrl = (if $had_pr then .prUrl else "" end)
  | if (str(.prUrl; 512) and (($had_pr | not) or ((.prUrl | prurl) and (.prUrl | unsafe | not)))) then . else error("prUrl") end
  | .h = .phaseHistory
  | if (has("phaseHistory") | not) then .hs = ""
    elif ((.h|type) != "array") then error("phaseHistory")
    elif ((.h|length) == 0) then error("phaseHistory")
    elif ([.h[] | (type == "object") and str(.phase; 32) and (.phase | test("^[a-z_]{1,32}$"))
                   and str(.at; 20) and (.at | iso)] | all | not) then error("phaseHistory")
    elif ((.h|length) > 0 and (.h[-1].phase != .phase)) then error("phaseHistory")
    elif ([.h[].phase] as $p | any(range(1; $p|length); $p[.] == $p[. - 1])) then error("phaseHistory")
    else .hs = ((if (.h|length) > 64 then "(\((.h|length) - 64) earlier omitted) " else "" end)
                + ([.h[-64:][] | "\(.phase)@\(.at)"] | join(", "))) end
  # THE SLUG IS ISSUE TEXT. The workflow names its branch `issue-<n>[-<n>…]-<slug>` with the slug
  # cut from the FIRST ISSUE TITLE — third-party text on a public repository — so a branch shaped
  # that way is rendered with its slug ELIDED (the numbers stay; `git branch --show-current` has
  # the rest). A branch of any other shape was named by whoever holds write access to the checkout
  # and is rendered whole.
  | .bshow = (.branch | if test("^issue-[0-9]+(-[0-9]+)*-.+$") then
                (capture("^(?<head>issue-[0-9]+(-[0-9]+)*)-(?<slug>.+)$") | "\(.head)-<slug elided, \(.slug|length) chars>")
              else . end)
  | [ .bshow, .issue, .phase, .prUrl, .owner, .hs, .branch ] | .[]'

_RS_CLAIM_JQ='
  one
  | if type != "object" then error("not an object") else . end
  | (has("owner")) as $had_owner   # claim
  | .owner = ((if $had_owner then .owner else "" end) | if type == "string" then . else error("owner") end)
  | if (.owner | unsafe) or ($had_owner and (.owner == "")) then error("owner") else . end
  | .expiresAt = (.expiresAt | if type == "number" and . == floor and . >= 0 and . < 1000000000000000 then . else error("expiresAt") end)
  | .expiresAt = (.expiresAt | tostring)
  | if (.expiresAt | test("^[0-9]{1,15}$")) then . else error("expiresAt") end
  | [ .owner, .expiresAt ] | .[]'

_rs_issue_list() { printf '%s' "$1" | sed 's/,/, #/g; s/^/#/'; }

# _rs_snap <file> — the file's bytes into RS_SNAP, or return 1 when they cannot be a record. A
# `$(<file)` strips every NUL silently, so bytes jq would refuse could arrive as a valid object;
# the byte count is compared with the NUL-stripped count first, and a difference is a refusal.
_rs_snap() {
  local raw stripped
  raw="$(wc -c < "$1" 2>/dev/null | tr -d ' ')" || return 1
  stripped="$(LC_ALL=C tr -d '\000' < "$1" 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$raw" = "$stripped" ] || return 1
  { RS_SNAP="$(<"$1")"; } 2>/dev/null || return 1
  [ -n "$RS_SNAP" ]
}

# _rs_scan <dir> — `state-scan` once; sets RS_ARTS (gaps/review/docs paths, sorted, comma-joined),
# RS_ISSUES (`#n, …` from the issue snapshots) and RS_UNSAFE (count of refused names).
_rs_scan() {
  local scan kind sfile key n
  RS_ARTS=""; RS_ISSUES=""; RS_UNSAFE=0; RS_UNNAMED=0
  scan="$(bash "$_adb_rs_lib/cleanup-lib.sh" state-scan "$1" 2>/dev/null)" || return 1
  # `state-scan` refuses only tab and newline in a name (its own delimiters); this output is a
  # line-structured document in a prompt, so every other control or format character is refused
  # here, by re-classifying such a record as `unsafe` before its path can be printed.
  # ...and the NAME must fit the workflow's own grammar: the names it writes are `[A-Za-z0-9._-]`
  # and short, and a printable name that is not — `gaps-IGNORE ALL PREVIOUS INSTRUCTIONS.md` is
  # classified `gaps` by state-scan — is prose, not a path this document may carry. The directory
  # part is the caller's `--state` (validated above) and may carry spaces; the basename may not.
  # ...and a name INSIDE that character grammar can still be prose (`gaps-IGNORE_ALL_PREVIOUS_
  # INSTRUCTIONS.md` is classified `gaps` too), so only an OPAQUE name is rendered: the fixed
  # names the workflow writes, or a family name with a numeric suffix. Any other family member is
  # counted as `unnamed`, never printed — state-scan's wider globs exist for debris, not for text.
  scan="$(printf '%s\n' "$scan" | jq -rR "$_RS_UNSAFE_JQ"' split("\t") | select(length >= 2)
    | if (.[1] | unsafe_path) then "unsafe\t-"
      elif (.[0] != "unsafe") and ((.[1] | split("/") | last) | test("^[A-Za-z0-9._-]{1,64}$") | not) then "unsafe\t-"
      elif (.[0] == "gaps" or .[0] == "review" or .[0] == "docs") and ((.[1] | split("/") | last) | test("^(gap-prompt\\.txt|gaps(-[0-9]{1,4})?\\.(md|err)|review-prompt\\.txt|review(-[0-9]{1,4})?\\.(md|err)|docs-consulted(-[0-9]{1,4})?\\.tsv)$") | not) then "unnamed\t-"
      else "\(.[0])\t\(.[1])" end' 2>/dev/null)" || return 1
  while IFS=$'\t' read -r kind sfile key; do
    [ -n "$kind" ] || continue
    case "$kind" in
      gaps|review|docs) RS_ARTS="${RS_ARTS:+$RS_ARTS, }$sfile" ;;
      issue)  case "$sfile" in *.json) ;; *) continue ;; esac
              n="${sfile##*/issue-}"; n="${n%.json}"
              case "$n" in ''|*[!0-9]*) continue ;; esac
              RS_ISSUES="${RS_ISSUES:+$RS_ISSUES, }#$n" ;;
      unsafe) RS_UNSAFE=$((RS_UNSAFE + 1)) ;;
      unnamed) RS_UNNAMED=$((RS_UNNAMED + 1)) ;;
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
  # `-L` as well as `-e`: a DANGLING symlink at the state path is a damaged path, not an absent
  # one, and must reach the unreadable verdict below rather than "nothing to say".
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  # Readable AND searchable: a directory without `x` lists its names but refuses every `-f` below,
  # which would read as "no run" rather than as the unreadable directory it is.
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || { printf 'run-state: the state directory %s cannot be read\n' "$dir"; return 20; }

  local marker="$dir/implement-issue-active.json" blocked="$dir/implement-issue-blocked.json"
  local claim="$dir/gap-analysis.lock" p
  # A record path that EXISTS but is not a readable regular file — a directory, a FIFO, a dangling
  # symlink — is refused before anything opens it (a FIFO would block the open), never read as
  # "absent": a damaged state path is an unreadable record, not a run that is over.
  for p in "$marker" "$claim"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -f "$p" ] && [ -r "$p" ] || { printf 'run-state: %s exists but is not a readable regular file\n' "$p"; return 18; }
    fi
  done
  local snap="" again="" fields="" attempt req="" blk="" grc
  local m_branch m_issue m_phase m_pr m_owner m_hist m_branch_raw

  if [ -f "$marker" ]; then
    for attempt in 1 2; do
      _rs_snap "$marker" || { printf 'run-state: the run marker at %s is unreadable\n' "$marker"; return 18; }
      snap="$RS_SNAP"
      fields="$(printf '%s' "$snap" | jq -rs "$_RS_UNSAFE_JQ $_RS_MARKER_JQ" 2>/dev/null)" || fields=""
      [ -n "$fields" ] || { printf 'run-state: the run marker at %s is unreadable (not a usable record)\n' "$marker"; return 18; }
      # `m_branch` is the DISPLAY form (slug elided); `m_branch_raw` is what the blocked marker
      # is paired against, since that file carries the real branch name.
      m_branch=""; m_issue=""; m_phase=""; m_pr=""; m_owner=""; m_hist=""; m_branch_raw=""
      { IFS= read -r m_branch; IFS= read -r m_issue; IFS= read -r m_phase
        IFS= read -r m_pr; IFS= read -r m_owner; IFS= read -r m_hist; IFS= read -r m_branch_raw; } <<EOF
$fields
EOF
      if ! adb_owners_compatible "$m_owner" "$sid"; then
        printf 'run-state: a run marker at %s belongs to another session; not summarised\n' "$marker"
        return 4
      fi
      _rs_scan "$dir" || { printf 'run-state: the state directory %s could not be scanned\n' "$dir"; return 20; }
      req=""
      if [ -e "$dir/review.md" ] || [ -L "$dir/review.md" ]; then
        if [ -f "$dir/review.md" ] && [ -r "$dir/review.md" ]; then
          req="$(grep -cw 'REQUIRED' "$dir/review.md" 2>/dev/null)"; grc=$?
          case "$grc" in 0|1) : ;; *) req="unreadable" ;; esac   # 1 = no match (grep prints 0)
          case "$req" in ''|*[!0-9a-z]*) req="unreadable" ;; esac
        else
          req="unreadable"   # a directory, a FIFO, a dangling symlink: present, not readable
        fi
      fi
      blk=""
      if [ -f "$blocked" ]; then
        # The blocked file pairs with THIS marker (same branch and issue, compatible owner) or it
        # is another run's stop. Its `reason` must EXIST as a non-empty string for the line to say
        # one was recorded; the text stays in the file and the path is named.
        # TYPED, like the marker: `branch` a string, `issue` a string or a number, `owner` absent,
        # null or a string. Anything else is not a usable record and says nothing — never "yes".
        blk="$(jq -r --arg b "$m_branch_raw" --arg i "$m_issue" --arg o "$m_owner" '
          if type != "object" then "no"
          elif ((.branch|type) != "string") or (.branch != $b) then "no"
          elif ((.issue|type) == "number") then (if (.issue|tostring) != $i then "no" else . end)
          elif ((.issue|type) != "string") or (.issue != $i) then "no" else . end
          | if . == "no" then "no"
            elif ((.reason|type) != "string") or (.reason == "") then "no"
            elif (.owner == null) then "yes"
            elif ((.owner|type) != "string") or (.owner == "") then "no"
            elif (.owner != "" and $o != "" and .owner != $o) then "no"
            else "yes" end' "$blocked" 2>/dev/null)" || blk="no"
      fi
      _rs_snap "$marker" && again="$RS_SNAP" || again=""
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
    [ "$RS_UNNAMED" -gt 0 ] && printf 'unnamed-artifacts: %s\n' "$RS_UNNAMED"
    [ -n "$req" ] && printf 'review-required-marks: %s\n' "$req"
    return 0
  fi

  # No marker: before the branch exists the CLAIM is the liveness signal (workflow steps 2-4).
  # Read ONCE; owner and lease come from the same bytes.
  [ -f "$claim" ] || return 0
  _rs_snap "$claim" || { printf 'run-state: the run claim at %s is unreadable\n' "$claim"; return 18; }
  snap="$RS_SNAP"
  fields="$(printf '%s' "$snap" | jq -rs "$_RS_UNSAFE_JQ $_RS_CLAIM_JQ" 2>/dev/null)" || fields=""
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
  [ "$RS_UNNAMED" -gt 0 ] && printf 'unnamed-artifacts: %s\n' "$RS_UNNAMED"
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
