#!/usr/bin/env bash
# ai-dev-baseline — the COMMAND ALLOWLIST (#288, D155).
#
# TWO QUESTIONS, ONE HOME:
#
#   which `permissions.allow` entries in ~/.claude/settings.json are OURS?   apply · remove · pending
#   what would still prompt, be refused, or reach the classifier?            audit
#
# THE INSTALL IS A UNION, AND OWNERSHIP IS PER ENTRY. `permissions.allow` is an array the operator
# also writes to, so the fragment's whole-or-nothing rule (D100) would refuse on nearly every
# machine. Each shipped entry is instead one of:
#
#   added     absent when this install met it, appended by it. Recorded; uninstall removes it.
#   theirs    already present. Never recorded, never removed.
#   declined  recorded as `added`, and gone when a later install looked. Not written again. The row
#             only ever SUPPRESSES a write; it authorises no removal, so an entry put back after
#             that is theirs. (Removed and put back BETWEEN two installs, it was never seen gone
#             and is still `added`.)
#
# A recorded entry the payload no longer ships is retired: removed while still present, forgotten
# either way. Only `permissions.allow` is ever written — never `defaultMode`, `deny` or `ask`.
#
# THE AUDIT IS READ-ONLY and is about the SHIPPED COMMANDS in an interactive terminal session. It
# reports, per scope it could read: a shipped entry no allow rule holds, a `deny` or `ask` rule
# that can match one, the starting permission mode, and the settings that make allow rules inert.
# CLEAN (0) says: the starting mode is one this audit can state and is `auto`, `acceptEdits` or
# `bypassPermissions`; and, outside `bypassPermissions`, every shipped entry is held by an allow
# rule in effect and matched by no deny or ask rule. It says nothing about any other command. What
# it rests on and cannot see is printed as `assume` records: that auto mode is available where it
# reports `auto`, that each file it parsed is one the CLI loads (it does not check the settings
# schema), and that the workspace is trusted where project rules count. A rule about another tool
# is listed and not judged, and the sandbox is not modelled. A scope it could not read, a rule or a mode it cannot model, or an audit
# that evaluated nothing, is NOT EVALUATED (11) and never clean. It models the CLI at
# adb_permissions_floor and later, and nothing older: on an older CLI, or one whose version it
# cannot read, it evaluates nothing.
#
# Usage (executed):
#   permissions-lib.sh entries [--repo <clone>]
#       the shipped allow entries, one per line
#   permissions-lib.sh missing [--repo <clone>] [--home <home>]
#       shipped entries absent from <home>/.claude/settings.json, one per line (0, maybe none · 11 unreadable)
#   permissions-lib.sh match [--repo <clone>] -- <command>
#       the shipped entries that match ONE simple command as written (0 some · 1 none · 2 the
#       text holds a shell operator or substitution, quoted or not: the CLI may match it part by
#       part, and this does not parse shell)
#   permissions-lib.sh audit [--repo <clone>] [--home <home>] [--project <root>] [--managed <file>]
#       stdout: `<kind>\t<level>\t<where>\t<text>` records, then one `summary` record
#       kind   scope | mode | entry | rule | gate | note | assume
#       level  ok | info | classifier | prompt | blocked | unevaluated
#       exit   0 clean · 10 prompt sources found · 11 not evaluated · 2 usage
#   --repo defaults to the clone the global install points into; --project to the working
#   directory — the directory a session would be started in, which is where Claude Code reads the
#   shared project file from; --managed to the platform's managed-settings.json.
#
# Sourced (install.sh, uninstall.sh, bin/baseline): adb_permissions_apply, adb_permissions_remove,
# adb_permissions_pending, adb_permissions_allow_sig, adb_permissions_heal_report. apply and remove
# expect the caller to HOLD the settings lock (adb_settings_lock_take): each defers and resumes that
# lock's signal traps around its two writes.
#
# Requires: jq for everything but recording an opt-out.

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then set -u; fi

_adb_perm_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
if [ ! -f "$_adb_perm_libdir/common.sh" ]; then
  printf 'permissions-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_perm_libdir/common.sh" >&2
  return 1 2>/dev/null || exit 1
fi
# Sourced by a caller that already loaded common.sh, it is NOT loaded again: that would reset the
# settings-lock globals the caller may be holding.
if ! command -v adb_publish_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$_adb_perm_libdir/common.sh"
fi
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

_ADB_PERM_TAB="$(printf '\t')"
_ADB_PERM_RECEIPT_MAX=1048576   # bytes; a receipt is a few KiB

# Usage: adb_permissions_payload <clone>
adb_permissions_payload() { printf '%s/agents/claude/settings.permissions.json' "$1"; }

# Usage: adb_permissions_receipt [home]
adb_permissions_receipt() { printf '%s/.claude/.adb-permissions-owned' "${1:-${HOME:-/root}}"; }

# The CLI floor: the NEWEST Claude Code release this surface was read against, and the only release
# line it supports (D155). Below it nothing is installed and nothing is audited. Bump it with every
# Claude release `/new-release` reviews here.
adb_permissions_floor() { printf '2.1.322'; }

# The shipped entries as ONE compact JSON array. The payload must be exactly
# `{"permissions":{"allow":[…]}}`: a second key would be a setting this surface never writes.
# Usage: adb_permissions_entries <payload>
# Returns: 0 · 1 the payload is missing or not that shape · 2 no jq
adb_permissions_entries() {
  command -v jq >/dev/null 2>&1 || return 2
  [ -s "$1" ] || return 1
  jq -c -e -s '
    if length == 1 then .[0] else error("not one JSON document") end   # payload-one-document
    | if type == "object" and keys == ["permissions"]
       and (.permissions | type == "object" and keys == ["allow"])
       and (.permissions.allow | type == "array" and length > 0
            and all(.[]; type == "string" and startswith("Bash(") and endswith(")") and length > 6
                         and (explode | all(.[]; . >= 32 and . != 127)))
            and length == (unique | length))
    then .permissions.allow else error("not an allowlist payload") end
  ' "$1" 2>/dev/null || return 1
}

# --- the receipt ---------------------------------------------------------------------------------
#
#   # <comment>
#   disposition installed|skipped-optout|skipped-below-floor|skipped-unprobeable|skipped-blocked
#   version <cli version, or ->
#   floor <version>
#   payload <sha-256 of the payload applied, or ->
#   rows <N>                      how many added/declined/created rows follow — a truncated record
#   source<TAB><clone>            is then short of its own count, not merely short
#   added<TAB><json string>
#   declined<TAB><json string>
#   created<TAB>allow|permissions

# The byte rules every reader of a present receipt shares: a regular file, no NUL, a final newline.
# Usage: _adb_perm_receipt_state <receipt>
# Outputs: `none` (absent or empty) or `present`
# Returns: 0 · 20 it could not be read · 21 it breaks a byte rule
_adb_perm_receipt_state() {
  case "$(adb_settings_doc_state "$1")" in
    absent|empty) printf 'none'; return 0 ;;
    present) ;;
    *) return 20 ;;
  esac
  adb_bytes_whole "$1" "$_ADB_PERM_RECEIPT_MAX"
  case "$?" in 0) printf 'present'; return 0 ;; 18) return 21 ;; *) return 20 ;; esac
}

# The receipt's disposition, readable without jq: `none` for an absent or empty receipt. It checks
# the byte rules and the disposition line only; `_adb_perm_receipt_json` is the whole validation.
# Usage: adb_permissions_disposition <receipt>
# Returns: 0 · 20 the receipt could not be read · 21 it is damaged
adb_permissions_disposition() {
  local receipt="$1" line grc st
  st="$(_adb_perm_receipt_state "$receipt")" || return "$?"
  [ "$st" = present ] || { printf 'none'; return 0; }
  line="$(grep -m1 '^disposition ' "$receipt" 2>/dev/null)"; grc=$?
  [ "$grc" -le 1 ] || return 20
  [ "$grc" -eq 0 ] || return 21
  case "${line#disposition }" in
    installed|skipped-optout|skipped-below-floor|skipped-unprobeable|skipped-blocked) printf '%s' "${line#disposition }" ;;
    *) return 21 ;;
  esac
}

# The whole receipt as JSON, validated whole against the grammar above: every metadata line exactly
# once and well-formed, no line it does not know, every entry a JSON string, no entry recorded
# twice or both `added` and `declined`, and as many rows as `rows` says.
#   {"disposition","payload","source","added":[…],"declined":[…],"created":[…]}
# Usage: _adb_perm_receipt_json <receipt>
# Returns: 0 · 2 no jq · 20 unreadable · 21 damaged
_adb_perm_receipt_json() {
  local receipt="$1" st
  command -v jq >/dev/null 2>&1 || return 2
  st="$(_adb_perm_receipt_state "$receipt")" || return "$?"
  if [ "$st" != present ]; then
    printf '%s\n' '{"disposition":"none","payload":null,"source":null,"added":[],"declined":[],"created":[]}'
    return 0
  fi
  jq -c -R -s '
    def entry($prefix; $l): ($l[($prefix | length):] | try fromjson catch null);
    def once($k; $v): if .[$k] == null then .[$k] = $v else .bad = true end;
    (split("\n") | if .[-1] == "" then .[:-1] else . end) as $all
    | reduce ($all[] | select(startswith("#") | not)) as $l (
        {disposition: null, version: null, floor: null, payload: null, rows: null, source: null,
         added: [], declined: [], created: [], bad: false};
        if .bad then .
        elif ($l | startswith("disposition ")) then once("disposition"; $l[12:])
        elif ($l | startswith("version ")) then once("version"; $l[8:])
        elif ($l | startswith("floor ")) then once("floor"; $l[6:])
        elif ($l | startswith("payload ")) then once("payload"; $l[8:])
        elif ($l | startswith("rows ")) then once("rows"; $l[5:])
        elif ($l | startswith("source\t")) then once("source"; $l[7:])
        elif ($l | startswith("added\t")) then
          (entry("added\t"; $l)) as $v
          | if ($v | type) == "string" and ($v | length) > 0 then .added += [$v] else .bad = true end
        elif ($l | startswith("declined\t")) then
          (entry("declined\t"; $l)) as $v
          | if ($v | type) == "string" and ($v | length) > 0 then .declined += [$v] else .bad = true end
        elif $l == "created\tallow" or $l == "created\tpermissions" then .created += [$l[8:]]
        else .bad = true end)   # unknown-line
    | (.disposition) as $d
    | if .bad
         or any((.disposition, .version, .floor, .payload, .rows, .source); . == null)   # metadata-required
         or (["installed","skipped-optout","skipped-below-floor","skipped-unprobeable","skipped-blocked"] | any(.[]; . == $d) | not)
         or (.version | test("^(-|[0-9]+(\\.[0-9]+)*)$") | not)
         or (.floor | test("^[0-9]+(\\.[0-9]+)*$") | not)
         or (.payload | test("^(-|[0-9a-f]{64})$") | not)
         or (.rows | test("^(0|[1-9][0-9]*)$") | not)
         or (.source | length) == 0
         or ((.rows | tonumber) != ((.added | length) + (.declined | length) + (.created | length)))   # row-count
         or ((.added + .declined) | length != (unique | length))
         or (.created | length != (unique | length))
      then error("damaged receipt")
      else {disposition, payload, source, added, declined, created} end
  ' "$receipt" 2>/dev/null || return 21
}

# Render a receipt. Rows arrive on stdin exactly as they are stored; the count is taken from them.
# Usage: adb_permissions_receipt_render <disposition> <version> <floor> <payload-digest> <clone>
adb_permissions_receipt_render() {
  local rows line n=0
  rows="$(cat)"
  if [ -n "$rows" ]; then
    while IFS= read -r line; do n=$((n + 1)); done <<EOF
$rows
EOF
  fi
  printf '# ai-dev-baseline command allowlist (#288) — written by install.sh; do not hand-edit.\n'
  printf 'disposition %s\nversion %s\nfloor %s\npayload %s\nrows %s\n' "$1" "$2" "$3" "$4" "$n"
  printf 'source\t%s\n' "$5"
  [ -z "$rows" ] || printf '%s\n' "$rows"
}

# Is a receipt this run just rendered one its own reader accepts, naming the clone it was rendered
# for? Asked BEFORE it is published, so a record nothing can read back is never the one left on
# disk. Without jq the question cannot be asked and the answer is yes.
# Usage: _adb_perm_rendered_ok <staged-receipt> <clone>
_adb_perm_rendered_ok() {
  local back
  command -v jq >/dev/null 2>&1 || return 0
  back="$(_adb_perm_receipt_json "$1")" || return 1   # rendered-validated
  # ...and it must name THIS clone: a path the line-oriented record cannot carry reads back as a
  # different one, or as a comment.
  [ "$(printf '%s' "$back" | jq -r '.source // ""' 2>/dev/null; printf x)" = "$2"$'\nx' ]   # rendered-source
}

# Record a run that wrote no entry, keeping every row an earlier install recorded: a skip means
# "write nothing new", never "forget what is there". Needs no jq; the caller validates the record
# first whenever jq is there to do it. Without jq the record is read by its line grammar alone, and
# one that is not whole by it — a line that is not in the grammar, a metadata line missing or met twice — is
# left for a run that can read it: rewriting it would drop the only sign of the damage. The rows
# themselves are carried as written.
# Usage: _adb_perm_record_skip <disposition> <version> <floor> <digest|-> <receipt> <clone>
#   <digest> `-` keeps the digest already recorded, so the skip does not claim a payload it never applied.
# Returns: 0 recorded · 1 the receipt could not be read or written, is not whole by its line
#          grammar, or holds fewer rows than it counts (the previous one is left as it was)
_adb_perm_record_skip() {
  local disposition="$1" version="$2" floor="$3" digest="$4" receipt="$5" repo="$6"
  local rows="" prior="-" line st counted=0 declared="" meta="" key
  # a metadata line, as the receipt grammar above writes it
  local re=$'^(disposition (installed|skipped-optout|skipped-below-floor|skipped-unprobeable|skipped-blocked)|version (-|[0-9]+(\\.[0-9]+)*)|floor [0-9]+(\\.[0-9]+)*|payload (-|[0-9a-f]{64})|rows (0|[1-9][0-9]*)|source\t.+)$'
  st="$(_adb_perm_receipt_state "$receipt")" || return 1
  if [ "$st" = present ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "#"*) ;;
        "added$_ADB_PERM_TAB"*|"declined$_ADB_PERM_TAB"*|"created$_ADB_PERM_TAB"*) rows+="$line"$'\n'; counted=$((counted + 1)) ;;
        *)
          [[ "$line" =~ $re ]] || return 1   # skip-line-grammar
          key="${line%%[ $_ADB_PERM_TAB]*}"; meta+="$key"$'\n'
          case "$key" in payload) prior="${line#payload }" ;; rows) declared="${line#rows }" ;; esac ;;
      esac
    done < "$receipt" || return 1
    # every metadata line exactly once
    [ "$(printf '%s' "$meta" | LC_ALL=C sort | tr '\n' ' ')" = "disposition floor payload rows source version " ] || return 1   # skip-metadata-whole
    # A record short of its own count is not rewritten as a whole one: re-rendering would recount
    # the surviving rows and erase the only sign that some are gone. This holds without jq.
    [ "$declared" = "$counted" ] || return 1   # carry-counts-rows
  fi
  [ "$digest" != "-" ] || digest="$prior"
  if printf '%s' "$rows" | adb_permissions_receipt_render "$disposition" "$version" "$floor" "$digest" "$repo" \
       > "$receipt.adb.$$.tmp" && _adb_perm_rendered_ok "$receipt.adb.$$.tmp" "$repo" \
     && adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; then
    return 0
  fi
  rm -f "$receipt.adb.$$.tmp"
  return 1
}

# --- the union -----------------------------------------------------------------------------------

# The union, as arithmetic over three inputs and nothing else: the live document, the shipped
# entries, and the prior record. Prints
#   {"verdict":"write"|"unchanged"|"blocked","why",
#    "settings","wrote":[…],"retired":[…],"added":[…],"declined":[…],"created":[…]}
# `blocked` means `permissions` or `permissions.allow` is there in a shape an entry cannot be
# appended to; nothing is written and `why` names the shape.
# Usage: _adb_perm_merge <settings-file> <shipped-json-array> <receipt-json>
# Returns: 0 · 1 the settings file is not valid JSON
_adb_perm_merge() {
  jq -c -s --argjson ship "$2" --argjson rc "$3" '
    def has_el($xs; $x): any($xs[]; . == $x);
    (if length == 1 then .[0] else error("not one JSON document") end) as $cur
    | if ([$cur | .. | numbers | select(isnan or isinfinite)] | length) > 0 then error("not JSON") else . end   # merge-strict-numbers
    | $cur
    | if ($cur | type) != "object" then {verdict: "blocked", why: "settings.json does not hold a JSON object"}
      elif ($cur | has("permissions")) and ($cur.permissions | type) != "object" then
        {verdict: "blocked", why: "`permissions` is not an object"}
      elif ($cur | has("permissions")) and ($cur.permissions | has("allow")) and ($cur.permissions.allow | type) != "array" then   # allow-shape
        {verdict: "blocked", why: "`permissions.allow` is not an array"}
      elif ($cur | has("permissions")) and ($cur.permissions | has("allow")) and ($cur.permissions.allow | all(.[]; type == "string") | not) then   # allow-elements
        {verdict: "blocked", why: "`permissions.allow` holds an entry that is not a string"}
      else
        (if ($cur | has("permissions")) and ($cur.permissions | has("allow")) then $cur.permissions.allow else [] end) as $live
        | [ $rc.added[] | select(. as $e | has_el($ship; $e) | not) | select(. as $e | has_el($live; $e)) ] as $retire
        | [ $live[] | select(. as $e | has_el($retire; $e) | not) ] as $kept
        | (reduce $ship[] as $e ({wrote: [], added: [], declined: []};
             if has_el($kept; $e) then (if has_el($rc.added; $e) then .added += [$e] else . end)
             elif has_el($rc.added; $e) or has_el($rc.declined; $e) then .declined += [$e]   # declined-not-rewritten
             else .wrote += [$e] | .added += [$e] end)) as $r
        | ($kept + $r.wrote) as $new
        | ([ (if ($cur | has("permissions")) then empty else "permissions" end),
             (if ($cur | has("permissions")) and ($cur.permissions | has("allow")) then empty else "allow" end) ]
           | if ($r.wrote | length) > 0 then . else [] end) as $made
        | {verdict: (if $new == $live then "unchanged" else "write" end), why: "",
           settings: (if $new == $live then $cur
                      else ($cur | .permissions = ((if has("permissions") then .permissions else {} end) | .allow = $new)) end),
           wrote: $r.wrote, retired: $retire, added: $r.added, declined: $r.declined,
           created: (($rc.created + $made) | unique)}
      end
  ' "$1" 2>/dev/null
}

# The receipt rows for a merge result, as they are stored.
# Usage: _adb_perm_rows <merge-result-json>
_adb_perm_rows() {
  printf '%s' "$1" | jq -r '
    (.added[] | "added\t" + tojson), (.declined[] | "declined\t" + tojson), (.created[] | "created\t" + .)'
}

# What a failed transaction must put back, captured BEFORE the first write: the bytes, or the fact
# that there was no file, and the link itself when settings.json is one — a rollback that restored
# only the bytes behind a link would leave a regular file where the operator had a link.
# Usage: _adb_perm_snapshot <settings>
# Globals (written): _ADB_PERM_PRE (the pre-image file, or empty), _ADB_PERM_HAD (0|1),
#   _ADB_PERM_WAS_LINK (0|1), _ADB_PERM_LINK (its target)
# Returns: 0 · 1 it could not be captured, and nothing was left behind
_ADB_PERM_PRE=""; _ADB_PERM_HAD=0; _ADB_PERM_WAS_LINK=0; _ADB_PERM_LINK=""
_adb_perm_snapshot() {
  local settings="$1" t
  _ADB_PERM_PRE=""; _ADB_PERM_HAD=0; _ADB_PERM_WAS_LINK=0; _ADB_PERM_LINK=""
  if [ -L "$settings" ]; then
    # `&&`: with `;` a failed readlink would still yield the sentinel and read as an empty target.
    t="$(readlink -n "$settings" && printf x)" || return 1
    [ "$t" != x ] || return 1
    _ADB_PERM_WAS_LINK=1; _ADB_PERM_LINK="${t%x}"
  fi
  if [ -e "$settings" ]; then
    _ADB_PERM_HAD=1
    _ADB_PERM_PRE="$settings.adb.$$.pre"
    rm -f "$_ADB_PERM_PRE"
    # Owner-only before it is populated: it is a copy of a file that can hold an `env` block.
    if ! { ( umask 077; : > "$_ADB_PERM_PRE" ) && cat "$settings" > "$_ADB_PERM_PRE"; }; then
      rm -f "$_ADB_PERM_PRE"; _ADB_PERM_PRE=""
      return 1
    fi
  fi
  return 0
}

# Usage: _adb_perm_snapshot_drop
_adb_perm_snapshot_drop() { [ -z "$_ADB_PERM_PRE" ] || rm -f "$_ADB_PERM_PRE"; _ADB_PERM_PRE=""; }

# Put back what `_adb_perm_snapshot` captured.
# Usage: _adb_perm_restore <settings>   Returns: 0 restored · 1 it could not be
_adb_perm_restore() {
  local settings="$1"
  if [ "$_ADB_PERM_WAS_LINK" -eq 1 ]; then   # restore-link
    _adb_perm_snapshot_drop
    rm -f -- "$settings" 2>/dev/null && ln -s -- "$_ADB_PERM_LINK" "$settings" 2>/dev/null   # link-operand
  elif [ "$_ADB_PERM_HAD" -eq 1 ]; then
    adb_publish_json "$_ADB_PERM_PRE" "$settings" --allow-empty && _ADB_PERM_PRE=""
  else
    rm -f "$settings" 2>/dev/null && [ ! -e "$settings" ] && [ ! -L "$settings" ]
  fi
}

# Stage `.settings` of a result beside its destination and publish it. The stage is owner-only
# before it holds anything, and `--strict` refuses rather than publish at a mode it could not carry
# over from the original.
# Usage: _adb_perm_publish_settings <result-json> <settings>   Returns: 0 published · 1 not
_adb_perm_publish_settings() {
  local tmp="$2.adb.$$.tmp"
  rm -f "$tmp"
  if ! { ( umask 077; : > "$tmp" ) && printf '%s' "$1" | jq '.settings' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; }; then   # stage-owner-only
    rm -f "$tmp"
    return 1
  fi
  adb_publish_json "$tmp" "$2" --strict   # publish-strict
}

# Add the shipped entries that are missing, record which, retire what is no longer shipped.
# Usage: adb_permissions_apply <clone> <home> <backup-dir> [optout 0|1] [optout-if-recorded 0|1]
# Globals: the caller's settings lock traps (deferred and resumed around the two writes)
# Returns: 0 applied, already current, or deliberately skipped — the receipt records which
#          1 nothing was written, or it was and has been put back; the reason is printed
#          3 skipped for want of jq
adb_permissions_apply() {
  local repo="$1" home="$2" backup="$3" optout="${4:-0}" if_recorded="${5:-0}"
  local settings="$home/.claude/settings.json" receipt payload floor disp drc
  receipt="$(adb_permissions_receipt "$home")"
  payload="$(adb_permissions_payload "$repo")"
  floor="$(adb_permissions_floor)"

  disp="$(adb_permissions_disposition "$receipt")"; drc=$?
  if [ "$drc" -ne 0 ]; then
    adb_info "  WARN   $receipt cannot be read or classified — allow entries NOT written."
    adb_info "         It is the only record of which entries are ours; restore it, or remove it and re-run."
    return 1
  fi
  # THE RECORD IS VALIDATED WHOLE BEFORE ANY PATH REWRITES IT, the opt-out and the skips included:
  # each of them carries its rows forward, and a row nobody checked would be carried into a record
  # no later run can read. Without jq the rows are copied as they stand and checked when it arrives.
  local rj='' rrc=0
  if command -v jq >/dev/null 2>&1; then
    rj="$(_adb_perm_receipt_json "$receipt")"; rrc=$?
    if [ "$rrc" -ne 0 ]; then   # record-validated-first
      adb_info "  WARN   $receipt does not parse as an allowlist record — allow entries NOT written."
      adb_info "         Restore it, or remove it and re-run (every entry then present is read as yours)."
      return 1
    fi
  fi
  if [ "$if_recorded" = 1 ] && [ "$disp" = skipped-optout ]; then optout=1; fi
  if [ "$optout" = 1 ]; then
    if ! _adb_perm_record_skip skipped-optout - "$floor" - "$receipt" "$repo"; then
      adb_info "  WARN   --no-permissions was honoured for this run but could NOT be recorded in $receipt."
      return 1
    fi
    adb_info "  allowlist  --no-permissions: no allow entries written (recorded, so \`baseline update\` keeps honouring it)"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — cannot write the command allowlist; install jq and re-run"
    return 3
  fi

  # ONE READ OF THE PAYLOAD: the entries and the digest recorded for them come from the same bytes.
  local snap ship digest
  snap="$(mktemp "${TMPDIR:-/tmp}/adb-allow.XXXXXX" 2>/dev/null)" && cat "$payload" > "$snap" 2>/dev/null || {
    rm -f "${snap:-}"
    adb_info "  WARN   could not read $payload — allow entries NOT written"
    return 1
  }
  if ! ship="$(adb_permissions_entries "$snap")" || ! digest="$(adb_sha256 "$snap")"; then
    rm -f "$snap"
    adb_info "  WARN   $payload is not a readable allowlist payload — allow entries NOT written"
    return 1
  fi
  rm -f "$snap"

  local version
  if ! version="$(adb_claude_cli_version)"; then
    _adb_perm_record_skip skipped-unprobeable - "$floor" - "$receipt" "$repo" || {
      adb_info "  WARN   the allowlist was skipped (no \`claude\` binary could be version-probed) and the skip could NOT be recorded."
      return 1; }
    adb_info "  allowlist  SKIPPED — no \`claude\` binary could be version-probed, so no allow entry was written."
    adb_info "             Put \`claude\` on PATH; the next \`baseline update\` applies them."
    return 0
  fi
  if ! adb_version_ge "$version" "$floor"; then
    _adb_perm_record_skip skipped-below-floor "$version" "$floor" - "$receipt" "$repo" || {
      adb_info "  WARN   the allowlist was skipped (claude v$version is below v$floor) and the skip could NOT be recorded."
      return 1; }
    adb_info "  allowlist  SKIPPED — claude v$version is older than v$floor, and only the current CLI is supported."
    adb_info "             Update Claude Code; the next \`baseline update\` applies them."
    return 0
  fi

  local docst input synth=""
  docst="$(adb_settings_doc_state "$settings")"
  case "$docst" in
    present) input="$settings" ;;
    absent|empty)
      synth="$(mktemp "${TMPDIR:-/tmp}/adb-allow.XXXXXX" 2>/dev/null)" && printf '{}\n' > "$synth" || {
        rm -f "${synth:-}"
        adb_info "  WARN   could not stage the settings input — allow entries NOT written"
        return 1; }
      input="$synth" ;;
    *)
      adb_info "  WARN   ~/.claude/settings.json does not resolve to a readable file — allow entries NOT written."
      return 1 ;;
  esac
  local result verdict
  result="$(_adb_perm_merge "$input" "$ship" "$rj")" || result=""
  [ -z "$synth" ] || rm -f "$synth"
  verdict="$(printf '%s' "$result" | jq -r '.verdict' 2>/dev/null)" || verdict=""
  case "$verdict" in
    write|unchanged) ;;
    blocked)
      local why
      why="$(printf '%s' "$result" | jq -r '.why' 2>/dev/null)" || why="its shape could not be read"
      _adb_perm_record_skip skipped-blocked "$version" "$floor" "$digest" "$receipt" "$repo" || {
        adb_info "  WARN   the allowlist was refused ($why) and the refusal could NOT be recorded."
        return 1; }
      adb_info "  allowlist  NOT written — $why, so no entry can be appended to it."
      adb_info "             Fix that key and re-run ./install.sh (\`baseline update\` retries only when the list changes)."
      return 0 ;;
    *)
      adb_info "  WARN   ~/.claude/settings.json is not valid JSON — allow entries NOT written."
      return 1 ;;
  esac

  local rows n_wrote n_retired n_declined
  rows="$(_adb_perm_rows "$result")" \
    && n_wrote="$(printf '%s' "$result" | jq -r '.wrote | length')" \
    && n_retired="$(printf '%s' "$result" | jq -r '.retired | length')" \
    && n_declined="$(printf '%s' "$result" | jq -r '.declined | length')" || {
    adb_info "  WARN   the allowlist merge result could not be read — allow entries NOT written."
    return 1; }

  # FROM HERE TO THE END OF THE TRANSACTION a signal is held: the pre-image and the staged record
  # exist only inside this window, so an interrupt cannot leave a copy of settings.json behind.
  adb_settings_lock_defer_signals   # stage-inside-deferral
  if [ "$verdict" = write ]; then
    if [ -e "$settings" ] && [ ! -e "$backup$settings" ]; then
      mkdir -p "$backup$(dirname "$settings")" 2>/dev/null && cp -p "$settings" "$backup$settings" 2>/dev/null || {
        adb_settings_lock_resume_signals
        adb_info "  WARN   could not back up $settings under $backup — allow entries NOT written"
        return 1; }
    fi
    if ! _adb_perm_snapshot "$settings"; then
      adb_settings_lock_resume_signals
      adb_info "  WARN   could not capture $settings to roll back to — allow entries NOT written"
      return 1
    fi
  fi

  # THE RECORD IS RENDERED AND READ BACK BEFORE ANYTHING IS PUBLISHED.
  [ -z "$rows" ] || rows+=$'\n'
  if ! { printf '%s' "$rows" \
           | adb_permissions_receipt_render installed "$version" "$floor" "$digest" "$repo" > "$receipt.adb.$$.tmp" \
         && _adb_perm_rendered_ok "$receipt.adb.$$.tmp" "$repo"; }; then
    rm -f "$receipt.adb.$$.tmp"
    _adb_perm_snapshot_drop
    adb_settings_lock_resume_signals
    adb_info "  WARN   could not render an allowlist record its own reader accepts — allow entries NOT written."
    adb_info "         The record is line-oriented and names this clone: a control character in $(adb_display_value "$repo") is one cause."
    return 1
  fi

  # TWO PUBLICATIONS, ONE TRANSACTION: the settings, then the record of what in them is ours.
  if [ "$verdict" = write ]; then
    if ! _adb_perm_publish_settings "$result" "$settings"; then
      rm -f "$receipt.adb.$$.tmp"
      _adb_perm_snapshot_drop
      adb_settings_lock_resume_signals
      adb_info "  WARN   could not rewrite ~/.claude/settings.json — allow entries NOT written"
      return 1
    fi
  fi
  if ! adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; then
    rm -f "$receipt.adb.$$.tmp"
    if [ "$verdict" = write ]; then
      if _adb_perm_restore "$settings"; then
        adb_info "  WARN   could not write $receipt — the allow entries were taken back out, so nothing is"
        adb_info "         installed without a record. Make it writable and re-run."
      else
        adb_info "  ERROR  could not write $receipt, and ~/.claude/settings.json could not be put back:"
        adb_info "         it holds allow entries nothing records. The original is under $backup."
      fi
    else
      adb_info "  WARN   could not write $receipt — the allowlist record was NOT refreshed."
    fi
    adb_settings_lock_resume_signals
    return 1   # receipt-publish-failed
  fi
  _adb_perm_snapshot_drop
  adb_settings_lock_resume_signals

  local n_ours n_ship
  n_ours="$(printf '%s' "$result" | jq -r '.added | length' 2>/dev/null)" || n_ours="?"
  n_ship="$(printf '%s' "$ship" | jq -r 'length' 2>/dev/null)" || n_ship="?"
  if [ "$verdict" = write ]; then
    adb_info "  allowlist  $n_wrote allow entr$([ "$n_wrote" = 1 ] && printf 'y' || printf 'ies') added to ~/.claude/settings.json, $n_retired retired ($n_ours of $n_ship shipped are recorded as ours; original backed up)"
  else
    adb_info "  allowlist  current — nothing to add ($n_ours of $n_ship shipped are recorded as ours)"
  fi
  if [ "$n_declined" != 0 ]; then
    adb_info "             $n_declined entr$([ "$n_declined" = 1 ] && printf 'y was' || printf 'ies were') removed from the list earlier and left out. Add one back yourself to restore it,"
    adb_info "             or delete $receipt and re-run to restore them all:"
    printf '%s' "$result" | jq -r '.declined[] | "               " + .' 2>/dev/null
  fi
  return 0
}

# The mirror of adb_permissions_apply: remove the entries the receipt records as `added` that are
# still present, drop the containers it records as created once they are empty, delete the receipt.
# Whose entries they are is the record's own `source` row, which its reader requires.
# Usage: adb_permissions_remove <clone> <home>
# Globals: the caller's settings lock traps (deferred and resumed around the two writes)
# Returns: 0 removed, nothing to remove, or left alone because the record is another clone's (said)
#          1 could not be removed; the reason is printed
adb_permissions_remove() {
  local repo="$1" home="$2"
  local settings="$home/.claude/settings.json" receipt disp drc rj rrc
  receipt="$(adb_permissions_receipt "$home")"
  disp="$(adb_permissions_disposition "$receipt")"; drc=$?
  if [ "$drc" -ne 0 ]; then
    adb_info "  ERROR  $receipt cannot be read or classified, so the allow entries it records cannot be"
    adb_info "         removed by it. NOTHING was removed — restore it and re-run."
    return 1
  fi
  if [ "$disp" = none ]; then
    # An empty record owns nothing and reads as none to every later run, so one that cannot be
    # deleted is left where it is and is not a failure of this removal.
    rm -f "$receipt" 2>/dev/null
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — allow entries left in ~/.claude/settings.json; $receipt lists them."
    adb_info "         Install jq and re-run."
    return 1
  fi
  rj="$(_adb_perm_receipt_json "$receipt")"; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    adb_info "  ERROR  $receipt does not parse as an allowlist record. NOTHING was removed — restore it and re-run."
    return 1
  fi
  local recorded
  recorded="$(printf '%s' "$rj" | jq -r '.source // ""' 2>/dev/null)" || {
    adb_info "  ERROR  the source recorded in $receipt could not be read, so this run cannot tell whose"
    adb_info "         entries these are. NOTHING was removed."
    return 1; }
  if [ -n "$recorded" ] && [ "$recorded" != "$repo" ]; then
    adb_info "  allowlist  left alone — its record names another clone as its source. Uninstall from: $recorded"
    return 0
  fi

  local docst result changed n_removed
  docst="$(adb_settings_doc_state "$settings")"
  case "$docst" in
    absent|empty)
      _adb_perm_receipt_clear "$receipt" || {   # clear-without-settings
        adb_info "  ERROR  $receipt could not be deleted or emptied — remove it by hand: a later install"
        adb_info "         would read every entry it lists as one you declined."; return 1; }
      return 0 ;;
    present) ;;
    *)
      adb_info "  WARN   ~/.claude/settings.json does not resolve to a readable file — allow entries NOT removed."
      return 1 ;;
  esac
  result="$(jq -c -s --argjson rc "$rj" '
    def has_el($xs; $x): any($xs[]; . == $x);
    (if length == 1 then .[0] else error("not one JSON document") end) as $cur
    | if ([$cur | .. | numbers | select(isnan or isinfinite)] | length) > 0 then error("not JSON") else . end
    | $cur
    | if ($cur | type) != "object" or ($cur | has("permissions") | not) or ($cur.permissions | type) != "object"
         or ($cur.permissions | has("allow") | not) or ($cur.permissions.allow | type) != "array"
      then {changed: false, removed: 0, settings: $cur}
      else
        ($cur.permissions.allow) as $live
        | [ $live[] | select(. as $e | has_el($rc.added; $e) | not) ] as $new   # remove-only-added
        | ($cur | .permissions.allow = $new
           | if $new == [] and has_el($rc.created; "allow") then del(.permissions.allow) else . end
           | if .permissions == {} and has_el($rc.created; "permissions") then del(.permissions) else . end) as $out
        | {changed: ($out != $cur), removed: (($live | length) - ($new | length)), settings: $out}
      end' "$settings" 2>/dev/null)" || {
    adb_info "  WARN   ~/.claude/settings.json is not valid JSON — allow entries NOT removed; $receipt lists them."
    return 1; }
  changed="$(printf '%s' "$result" | jq -r '.changed' 2>/dev/null)" || changed=""
  n_removed="$(printf '%s' "$result" | jq -r '.removed' 2>/dev/null)" || n_removed=""
  case "$changed" in true|false) ;; *)
    adb_info "  WARN   the allowlist removal could not be computed — allow entries NOT removed; $receipt lists them."
    return 1 ;;
  esac

  adb_settings_lock_defer_signals
  if [ "$changed" = true ]; then
    if ! _adb_perm_publish_settings "$result" "$settings"; then
      adb_settings_lock_resume_signals
      adb_info "  WARN   could not rewrite ~/.claude/settings.json — allow entries NOT removed; $receipt lists them."
      return 1
    fi
  fi
  if ! _adb_perm_receipt_clear "$receipt"; then
    adb_settings_lock_resume_signals
    adb_info "  ERROR  the allow entries were removed but $receipt could not be deleted or emptied. Remove it by"
    adb_info "         hand: a later install would read every entry it lists as one you declined."
    return 1   # receipt-delete-failed
  fi
  adb_settings_lock_resume_signals
  adb_info "  allowlist  removed $n_removed allow entr$([ "$n_removed" = 1 ] && printf 'y' || printf 'ies') this install added to ~/.claude/settings.json"
  return 0
}

# Clear the record after a removal: gone, or failing that, EMPTY. An empty record reads as none,
# so a later install cannot take the entries just removed for ones the operator declined.
# Usage: _adb_perm_receipt_clear <receipt>   Returns: 0 gone or empty · 1 neither
_adb_perm_receipt_clear() {
  { rm -f "$1" 2>/dev/null && [ ! -e "$1" ]; } || { : > "$1"; } 2>/dev/null   # receipt-emptied
}

# Would an install change the allowlist or its record? Asked by `baseline update` when every link
# already resolves. A refusal and an install are retried when the PAYLOAD changes, a version skip
# when the CLI now clears the floor; an opt-out never is. A record naming another clone is pending
# whatever it says: the installer rewrites its source, so that converges after one visit.
# Usage: adb_permissions_pending <clone> [home]
# Returns: 0 pending · 1 not pending · 20 the receipt could not be read · 21 it is damaged
#          24 the payload is missing, or could not be hashed
adb_permissions_pending() {
  local src="$1" home="${2:-$HOME}" receipt payload disp drc rj rrc fields source have want version
  adb_agent_ours claude "$src" "$home" || return 1
  payload="$(adb_permissions_payload "$src")"
  [ -s "$payload" ] || return 24   # payload-missing
  receipt="$(adb_permissions_receipt "$home")"
  disp="$(adb_permissions_disposition "$receipt")"; drc=$?
  case "$drc" in 0) ;; 20|21) return "$drc" ;; *) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  # THE SAME WHOLE VALIDATION apply and remove perform: a record they would refuse is not current.
  rj="$(_adb_perm_receipt_json "$receipt")"; rrc=$?
  case "$rrc" in 0) ;; 20|21) return "$rrc" ;; *) return 21 ;; esac   # pending-validates-whole
  fields="$(printf '%s' "$rj" | jq -r '[.source // "", .payload // ""] | join("\t")' 2>/dev/null)" || return 21
  source="${fields%%"$_ADB_PERM_TAB"*}"; have="${fields#*"$_ADB_PERM_TAB"}"
  if [ "$disp" != none ] && [ "$source" != "$src" ]; then return 0; fi   # foreign-source-pending
  case "$disp" in
    skipped-optout) return 1 ;;
    installed|skipped-blocked)
      want="$(adb_sha256 "$payload")" || return 24
      [ "$have" = "$want" ] && return 1
      return 0 ;;
  esac
  version="$(adb_claude_cli_version)" || return 1
  adb_version_ge "$version" "$(adb_permissions_floor)"
}

# The live allow list as one comparable word, for a before/after comparison across a self-heal:
# its digest, `absent` when there is no list, `unread` when it could not be read.
# Usage: adb_permissions_allow_sig [home]
adb_permissions_allow_sig() {
  local settings="${1:-$HOME}/.claude/settings.json" out
  case "$(adb_settings_doc_state "$settings")" in
    absent|empty) printf 'absent'; return 0 ;;
    present) ;;
    *) printf 'unread'; return 0 ;;
  esac
  out="$(jq -c 'if type == "object" and has("permissions") and (.permissions | type) == "object" and (.permissions | has("allow"))
                then .permissions.allow else "absent" end' "$settings" 2>/dev/null)" || { printf 'unread'; return 0; }
  if [ "$out" = '"absent"' ]; then printf 'absent'; return 0; fi
  printf '%s' "$out" | adb_sha256_stdin || printf 'unread'
}

# After a self-heal, say what happened to the allowlist — from what CHANGED, never from what the
# record now says. Prints at most one line on stderr.
# Usage: adb_permissions_heal_report <clone> <home> <allow-sig-before> <receipt-sig-before>
# Returns: 0 the allow list changed · 1 it did not
adb_permissions_heal_report() {
  local src="$1" home="$2" allow_before="$3" rcpt_before="$4" receipt allow_now rcpt_now disp
  receipt="$(adb_permissions_receipt "$home")"
  allow_now="$(adb_permissions_allow_sig "$home")"
  rcpt_now="$(adb_sha256 "$receipt" 2>/dev/null)" || rcpt_now="none"
  if [ "$allow_now" != "$allow_before" ]; then
    printf 'baseline: the command allowlist in ~/.claude/settings.json was updated.\n' >&2
    return 0
  fi
  [ "$rcpt_now" != "$rcpt_before" ] || return 1
  disp="$(adb_permissions_disposition "$receipt" 2>/dev/null)" || disp="unreadable"
  case "$disp" in
    installed) printf 'baseline: refreshed the command-allowlist record; no allow entry was added or removed.\n' >&2 ;;
    *) printf 'baseline: the command allowlist was NOT applied (%s) — run ./install.sh in %s to see why.\n' "$disp" "$src" >&2 ;;
  esac
  return 1
}

# --- the audit -----------------------------------------------------------------------------------

# The jq definitions the rule readers share, prepended to each program that asks, so matching has
# ONE spelling. Vendor rules they encode, read 2026-11-11 (code.claude.com/docs/en/permissions):
#   norm                 the legacy `:*` suffix is the other spelling of a trailing ` *`
#   gmatch($t; $p)       does glob $p — `*` is its only special character — match the whole of $t?
#   rmatch($t; $p)       gmatch, plus: a pattern whose ONLY wildcard is a trailing ` *` also matches
#                        the bare command (`Bash(npm run *)` matches `npm run`)
#   parse                a rule as {tool, spec}: `spec` null for a rule naming a whole tool; null
#                        when the text is not rule-shaped at all
#   tool_is($t)          does a parsed rule name tool $t? A deny or ask rule may glob the tool
#                        name; case is ignored, so a rule spelled another way is never missed
#   aspec                the Bash specifier of an ALLOW rule ("*" for the whole tool), or null: an
#                        allow rule names its tool literally, a glob there approves nothing
#   overlaps($d; $e)     can specifier $d match a command that specifier $e matches?
#   contains_spec($d; $a) does specifier $d match EVERY command specifier $a matches? The whole
#                        tool, the same pattern, or a `<prefix> *` whose prefix every such command
#                        starts with. Anything else answers no
#   subsumes($a; $e)     does allow RULE $a hold every command RULE $e does? The same rule, the
#                        whole tool, or a `<prefix> *` rule whose prefix is a whole-word prefix of
#                        $e. Anything else answers no: a miss is over-reported, never under-reported
#   suspended            is an allow rule one Auto Mode sets aside — the whole tool, or a wildcard
#                        directly after an interpreter, a wrapper or a package-manager run command?
#                        The vendor gives this class by example, so the list is this audit's reading
_adb_perm_jq_defs() {
  printf '%s\n' '
def norm: if endswith(":*)") then .[:-3] + " *)" else . end;
def gmatch($t; $p):
  ($p | split("*")) as $s
  | if ($s | length) == 1 then $t == $p
    elif ($t | startswith($s[0]) | not) then false
    else
      (reduce $s[1:-1][] as $m ({rest: $t[($s[0] | length):], ok: true};
         if (.ok | not) or $m == "" then .
         else (.rest | split($m)) as $parts
           | if ($parts | length) < 2 then .ok = false else .rest = ($parts[1:] | join($m)) end
         end)) as $st
      | $st.ok and ($st.rest | endswith($s[-1]))
    end;
def rmatch($t; $p): gmatch($t; $p) or (($p | endswith(" *")) and ($p[:-2] | contains("*") | not) and $t == $p[:-2]);
def parse: norm | (capture("^(?<tool>[^()]+)\\((?<spec>.*)\\)$") // (if test("^[^()]+$") then {tool: ., spec: null} else null end));
def tool_is($t): if (.tool | contains("*")) then gmatch(($t | ascii_downcase); (.tool | ascii_downcase)) else (.tool | ascii_downcase) == ($t | ascii_downcase) end;
def aspec: parse as $p | if $p != null and $p.tool == "Bash" then (if $p.spec == null then "*" else $p.spec end) else null end;
def lit: split("*")[0];
def contains_spec($d; $a):
  $d == "*" or $d == $a
  or (($d | endswith(" *")) and ($d[:-2] | contains("*") | not)
      and (($a | lit) as $al
           | ($al | startswith($d[:-1])) or (($a | contains("*") | not) and $a == $d[:-2])));
def overlaps($d; $e):
  if ($d | contains("*") | not) then rmatch($d; $e)
  elif ($e | contains("*") | not) then rmatch($e; $d)
  else (($d | lit) as $a | ($e | lit) as $b | ($a | startswith($b)) or ($b | startswith($a))) end;
def subsumes($a; $e):
  ($a | norm) == ($e | norm)
  or (($a | aspec) as $as | ($e | aspec) as $es
      | $as != null and $es != null
        and ($as == "*"
             or (($as | endswith(" *")) and ($as[:-2] | contains("*") | not)
                 and (($es | if endswith(" *") then .[:-2] else . end) as $q
                      | ($q | contains("*") | not) and ($q == $as[:-2] or ($q | startswith($as[:-1])))))));
# MAY be more than one simple command: an operator or a substitution anywhere in the text. This reads
# text, not shell syntax, so one inside quotes counts too — it declines to answer; it does not guess.
def compound: test("[;&|\n]|\\$\\(|`|[<>]\\(");
def suspended:
  aspec as $s
  | $s != null and ($s | contains("*"))
    and (($s | lit | rtrimstr(" ")) as $head
         | $head == "" or any(("bash", "sh", "zsh", "dash", "ksh", "fish", "python", "python2", "python3", "node",
                               "deno", "ruby", "perl", "php", "env", "sudo", "xargs", "eval", "exec", "npx", "bunx",
                               "npm run", "npm exec", "pnpm run", "pnpm exec", "pnpm dlx", "yarn", "yarn run",
                               "bun run", "bun x"); . == $head));'
}

# One settings scope, reduced to the fields the audit reads and written to <out>. Never the whole
# document: a settings file also carries `env`, and nothing here is handed more than it needs.
#   {"state":"absent"} · {"state":"unread"} · {"state":"read", p_shape, allow, deny, ask, mode,
#    no_auto, deny_prompts, no_bypass, classify_all, managed_only}
# `p_shape` is absent | object | bad, so a `permissions` of the wrong type is not read as absent.
# A file is `absent` only when this run can VOUCH for that: under a directory it cannot search, a
# path reads as missing whether or not it exists, and that is `unread`. So is a zero-byte file: it
# is there, and it is not one JSON object.
# Usage: _adb_perm_scope <file> <out>   Returns: 0 written · 1 <out> could not be written
_adb_perm_scope() {
  local f="$1" out="$2" vroot vrel
  case "$(adb_settings_doc_state "$f")" in
    empty) printf '%s\n' '{"state":"unread"}' > "$out"; return "$?" ;;   # empty-not-absent
    absent)
      case "$f" in /*) vroot=""; vrel="${f#/}" ;; *) vroot=.; vrel="$f" ;; esac
      if adb_parents_searchable "$vroot" "$vrel"; then   # absence-vouched
        printf '%s\n' '{"state":"absent"}' > "$out"
      else
        printf '%s\n' '{"state":"unread"}' > "$out"
      fi
      return "$?" ;;
    present) ;;
    *) printf '%s\n' '{"state":"unread"}' > "$out"; return "$?" ;;
  esac
  if jq -c -s '
      def key($o; $k): if ($o | type) == "object" and ($o | has($k)) then $o[$k] else null end;
      (if length == 1 then .[0] else error("not one JSON document") end)   # scope-one-document
      # jq reads NaN and Infinity; JSON has neither, and the CLI would not load the file
      | if ([.. | numbers | select(isnan or isinfinite)] | length) > 0 then error("not JSON") else . end   # scope-strict-numbers
      | if type != "object" then error("not an object") else
        . as $doc
        | key($doc; "permissions") as $p
        | {state: "read",
           p_shape: (if ($doc | has("permissions") | not) then "absent" elif ($p | type) == "object" then "object" else "bad" end),   # shape-of-permissions
           allow: (if ($p | type) == "object" and ($p | has("allow")) then $p.allow else [] end),
           deny:  (if ($p | type) == "object" and ($p | has("deny")) then $p.deny else [] end),
           ask:   (if ($p | type) == "object" and ($p | has("ask")) then $p.ask else [] end),
           mode: key($p; "defaultMode"),
           no_auto: (key($doc; "disableAutoMode") == "disable" or key($p; "disableAutoMode") == "disable"),
           deny_prompts: (key($p; "denyInsteadOfPrompting") == true),
           no_bypass: (key($p; "disableBypassPermissionsMode") == "disable"),
           classify_all: (key(key($doc; "autoMode"); "classifyAllShell") == true),
           managed_only: (key($doc; "allowManagedPermissionRulesOnly") == true)}
      end' "$f" > "$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  printf '%s\n' '{"state":"unread"}' > "$out"
}

# Is the repository root one the CLI keeps the local settings file at: the root, its `.git` and its
# `.claude` (when there is one) all owned by this user?
# Usage: _adb_perm_owned <repository-root>
_adb_perm_owned() {
  [ -O "$1" ] && [ -O "$1/.git" ] && { [ ! -e "$1/.claude" ] || [ -O "$1/.claude" ]; }
}

# Usage: adb_permissions_audit <clone> <home> <session-directory|""> <managed-file>
#   <session-directory> the directory a Claude Code session would be started in
# Outputs: the records documented in this file's header, on stdout
# Returns: 0 clean · 10 prompt sources found · 11 not evaluated
# A subshell body: its temp directory is removed on every way out.
adb_permissions_audit() (
  repo="$1"; home="$2"; project="$3"; managed="$4"
  _adb_perm_unevaluated() {   # every field through the same rule the records follow: no control character
    printf 'note\tunevaluated\t%s\t%s\n' "${1//[[:cntrl:]]/?}" "${2//[[:cntrl:]]/?}"   # early-record-one-line
    printf 'summary\tunevaluated\t-\tentries=0/0 scopes=0/0 rules=0 findings=0 unevaluated=1\n'
  }
  if ! command -v jq >/dev/null 2>&1; then
    _adb_perm_unevaluated - "jq is not installed, so no settings file was read"; return 11
  fi
  d="$(mktemp -d "${TMPDIR:-/tmp}/adb-audit.XXXXXX" 2>/dev/null)" || {
    _adb_perm_unevaluated - "no temporary directory could be made, so no settings file was read"; return 11; }
  trap 'rm -rf "$d"' EXIT
  if ! adb_permissions_entries "$(adb_permissions_payload "$repo")" > "$d/ship.json"; then
    _adb_perm_unevaluated "$(adb_permissions_payload "$repo")" "the shipped allowlist could not be read, so no entry was evaluated"; return 11
  fi
  # ONE RELEASE LINE (D155): what follows states what the CLI at the floor and later does.
  floor="$(adb_permissions_floor)"
  cli="$(adb_claude_cli_version 2>/dev/null)" || cli=""
  if [ -z "$cli" ] || ! adb_version_ge "$cli" "$floor"; then   # audit-cli-current
    _adb_perm_unevaluated claude "${cli:+v$cli is older than v$floor: }${cli:-its version could not be read: }nothing was evaluated — this audit models claude v$floor and later, so update Claude Code"; return 11
  fi

  # WHICH FILES A SESSION STARTED IN <project> LOADS (vendor settings page, "Where Claude Code keeps
  # the local file in a git repository", read 2026-11-11):
  #   shared  `.claude/settings.json` of the SESSION's directory — not the repository root
  #   local   `.claude/settings.local.json` at the repository root (the MAIN checkout's, in a
  #           linked worktree) — but beside the shared file when there is no repository, when the
  #           root is the home directory, or when the root, its `.git` or its `.claude` is not
  #           the user's own
  #   also    a local file an older CLI left in the session's directory: its rules apply too
  local_file=""; local_where=".claude/settings.local.json"; local_unresolved=false; gates_state=none
  local2_file=""; gates_root="$project"
  printf '%s\n' '{"state":"none"}' > "$d/proj.json"; cp "$d/proj.json" "$d/local.json"; cp "$d/proj.json" "$d/local2.json"
  printf '%s\n' '[]' > "$d/gates.json"
  # One line of git output as the path it names: the sentinel keeps a newline that ends a directory
  # name, and exactly the one newline git terminates its answer with is taken off.
  _adb_perm_git_path() {
    local out
    out="$(git -C "$1" rev-parse "${@:2}" 2>/dev/null && printf x)" || return 1
    out="${out%x}"; out="${out%$'\n'}"   # git-path-exact
    [ -n "$out" ] || return 1
    printf '%s' "$out"; printf x
  }
  if [ -n "$project" ]; then
    sess_local="$project/.claude/settings.local.json"
    local_file="$sess_local"
    if ! top="$(_adb_perm_git_path "$project" --show-toplevel)"; then
      # NO REPOSITORY is one answer git gives in one message; any other failure — no git on PATH, a
      # repository git will not open — leaves which local file a session reads unestablished.
      top=""
      case "$(LC_ALL=C git -C "$project" rev-parse --show-toplevel 2>&1 >/dev/null)" in
        "fatal: not a git repository (or any"*) ;;
        *) local_file=""; local_unresolved=true ;;   # git-failure-not-absence
      esac
    else
      top="${top%x}"
      gates_root="$top"; root="$top"
      if gd="$(_adb_perm_git_path "$project" --path-format=absolute --git-dir)" \
         && cdir="$(_adb_perm_git_path "$project" --path-format=absolute --git-common-dir)"; then
        gd="${gd%x}"; cdir="${cdir%x}"
        if [ "$gd" != "$cdir" ]; then   # worktree-local-file
          case "$cdir" in
            */.git) root="${cdir%/.git}" ;;
            *) root=""; local_unresolved=true ;;
          esac
        fi
      else
        root=""; local_unresolved=true
      fi
      if [ -n "$root" ]; then
        if [ "$root" -ef "$home" ] || ! _adb_perm_owned "$root"; then   # local-stays-with-session
          local_file="$sess_local"
        elif [ "$root/.claude/settings.local.json" -ef "$sess_local" ] || [ "$root/.claude/settings.local.json" = "$sess_local" ]; then
          local_file="$sess_local"
        else
          local_file="$root/.claude/settings.local.json"   # local-at-root
          local_where="the repository root's .claude/settings.local.json"
          local2_file="$sess_local"   # legacy-local
        fi
      else
        local_file=""
      fi
    fi
    _adb_perm_scope "$project/.claude/settings.json" "$d/proj.json" || { _adb_perm_unevaluated - "the audit could not stage its inputs"; return 11; }   # shared-from-session
    if [ -n "$local_file" ]; then
      _adb_perm_scope "$local_file" "$d/local.json" || { _adb_perm_unevaluated - "the audit could not stage its inputs"; return 11; }
    else
      printf '%s\n' '{"state":"unread"}' > "$d/local.json"
    fi
    if [ -n "$local2_file" ]; then
      _adb_perm_scope "$local2_file" "$d/local2.json" || { _adb_perm_unevaluated - "the audit could not stage its inputs"; return 11; }
    fi
    grc=0
    g="$(bash "$_adb_perm_libdir/project-gates.sh" detect "$gates_root" 2>/dev/null)" || grc=$?
    if [ "$grc" -eq 0 ] && printf '%s' "$g" \
         | jq -c -R -s '[ split("\n")[] | select(length > 0) | split("\t") | {label: .[0], cmd: (.[1:] | join("\t"))} ]' > "$d/gates.json" 2>/dev/null; then
      gates_state=detected
    else
      gates_state=unread; printf '%s\n' '[]' > "$d/gates.json"
    fi
  fi
  { _adb_perm_scope "$managed" "$d/mgd.json" && _adb_perm_scope "$home/.claude/settings.json" "$d/user.json"; } \
    || { _adb_perm_unevaluated - "the audit could not stage its inputs"; return 11; }

  cfg_other=false; mgd_dir=false
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ ! "$CLAUDE_CONFIG_DIR" -ef "$home/.claude" ]; then cfg_other=true; fi
  if [ -d "$(dirname "$managed")/managed-settings.d" ]; then
    # A directory that cannot be listed is not an empty one.
    if ! mgd_ls="$(ls -A "$(dirname "$managed")/managed-settings.d" 2>/dev/null)" || [ -n "$mgd_ls" ]; then mgd_dir=true; fi
  fi

  out="$(jq -n -r --slurpfile ship "$d/ship.json" --slurpfile mgd "$d/mgd.json" --slurpfile user "$d/user.json" \
      --slurpfile proj "$d/proj.json" --slurpfile local "$d/local.json" --slurpfile local2 "$d/local2.json" \
      --slurpfile gates "$d/gates.json" \
      --arg gates_state "$gates_state" --arg cli "$cli" --argjson cfg_other "$cfg_other" \
      --argjson mgd_dir "$mgd_dir" --argjson local_unresolved "$local_unresolved" \
      --arg managed "$managed" --arg local_where "$local_where" "$(_adb_perm_jq_defs)"'
    # One record is one line of four fields: a control character in a rule, a path or a gate
    # command — text a project controls — is replaced, so it cannot end a field or start a record.
    def clean: explode | map(if . < 32 or . == 127 then 63 else . end) | implode;
    def rec($k; $l; $w; $t): [$k, $l, ($w | clean), ($t | clean)] | join("\t");   # record-one-line
    def strs: type == "array" and all(.[]; type == "string");
    def plural($n; $one; $many): if $n == 1 then $one else $many end;

    $ship[0] as $ship | $gates[0] as $gates
    | [ {name: "managed", s: $mgd[0], where: $managed},
        {name: "user", s: $user[0], where: "~/.claude/settings.json"},
        {name: "project", s: $proj[0], where: ".claude/settings.json"},
        {name: "local", s: $local[0], where: $local_where},
        {name: "local2", s: $local2[0], where: ".claude/settings.local.json (left in the session directory by an older CLI)"} ] as $scopes
    | [ $scopes[] | select(.s.state != "none") | . as $sc | $sc.s as $x
        | ($x.state == "read" and $x.p_shape != "bad" and ($x.allow | strs) and ($x.deny | strs) and ($x.ask | strs)) as $ok
        | {name, where, state: $x.state, shape_ok: ($x.state != "read" or $ok),
           allow: (if $ok then $x.allow else [] end), deny: (if $ok then $x.deny else [] end),
           ask: (if $ok then $x.ask else [] end),
           mode: (if $x.state == "read" then $x.mode else null end),
           no_auto: ($x.state == "read" and $x.no_auto), deny_prompts: ($x.state == "read" and $x.deny_prompts),
           no_bypass: ($x.state == "read" and $x.no_bypass),
           classify_all: ($x.state == "read" and $x.classify_all), managed_only: ($x.state == "read" and $x.managed_only)} ] as $S
    | ([ $S[] | select(.name == "managed") | .managed_only ] | any) as $managed_only
    | [ $S[] | select(($managed_only | not) or .name == "managed") ] as $R       # the scopes whose rules count

    # --- the starting mode of an INTERACTIVE TERMINAL session (vendor "Which mode a session starts
    #     in", read 2026-11-11): the `defaultMode` of the highest of managed > local > project > user
    #     that sets one, else the built-in default. Where the root local file and one left in the
    #     session directory both set it, the root value applies. Two values do not take effect from project or
    #     local settings: `auto` falls to the BUILT-IN default (not to the user value), and
    #     `bypassPermissions` starts the session in default mode. `auto` is the built-in default
    #     of an interactive terminal session.
    | ([ $S[] | select(.no_auto) | .where ]) as $no_auto
    | ([ $S[] | select(.no_bypass) | .where ]) as $no_bypass
    | ([ ("managed", "local", "local2", "project", "user") as $n | $S[] | select(.name == $n and .mode != null) ] | .[0] // null) as $top   # mode-precedence
    | ($top != null and ($top.name == "local" or $top.name == "local2" or $top.name == "project")) as $top_local
    | (if $top == null then {mode: "auto", src: "built-in default", why: "builtin"}
       elif $top_local and $top.mode == "auto" then {mode: "auto", src: $top.where, why: "local-auto"}   # local-auto-builtin
       elif $top_local and $top.mode == "bypassPermissions" then {mode: "default", src: $top.where, why: "local-bypass"}   # local-bypass-manual
       else {mode: (if $top.mode == "manual" then "default" else $top.mode end), src: $top.where, why: "set"} end) as $m0
    | (if ($no_auto | length) > 0 and $m0.mode == "auto"
       then ($m0 | .mode = "default" | .why = "no-auto") else $m0 end) as $m
    | $m.mode as $mode
    # A mode whose effect this audit can state. `plan` is not one: what happens to a command there
    # depends on whether bypass and auto mode are available to the session.
    | ((["auto", "acceptEdits", "bypassPermissions", "default", "dontAsk"] | any(.[]; . == $mode))
       and (($mode == "bypassPermissions" and ($no_bypass | length) > 0) | not)) as $mode_known   # mode-known
    | ([ $S[] | select((.name == "managed" or .name == "user") and .classify_all) | .where ]) as $cas_where
    | (($mode == "auto") and ($cas_where | length) > 0) as $allow_inert   # classify-all
    | ([ $S[] | select((.name == "managed" or .name == "user") and .deny_prompts) | .where ]) as $dp_where
    | (($dp_where | length) > 0) as $dp
    # what a would-be prompt becomes
    | (if $dp or $mode == "dontAsk" then "blocked" else "prompt" end) as $asked   # asked-level
    | (if ($mode_known | not) then "unevaluated" elif $mode == "auto" then "classifier"
       elif $mode == "bypassPermissions" then null else $asked end) as $miss_level

    # --- the allow rules in effect: Auto Mode sets the arbitrary-execution ones aside
    | [ $R[] | .allow[] ] as $allow_all_rules
    | [ $allow_all_rules[] | select($mode == "auto" and suspended) ] as $set_aside
    | [ $allow_all_rules[] | select(($mode == "auto" and suspended) | not) ] as $allow   # auto-suspends

    # --- every deny and ask rule, classified ONCE
    | [ ($R[] | . as $sc | .deny[] | {rule: ., where: $sc.where, kind: "deny"}),
        ($R[] | . as $sc | .ask[]  | {rule: ., where: $sc.where, kind: "ask"}) ] as $rules
    | [ $rules[] | . as $r | ($r.rule | parse) as $p
        | (if $p == null then {cls: "unparsed"}
           elif ($p | tool_is("Bash")) and $p.spec != null and ($p.spec | test("^\\s|\\s$")) then {cls: "unparsed"}   # spec-whitespace
           elif ($p | tool_is("Bash")) then
             (if $p.spec == null or $p.spec == "*" then {cls: "bash", spec: "*"}
              elif ($p.spec | test("^[A-Za-z_][A-Za-z0-9_]*[ ]*:")) then
                (if ($p.spec | test("^command[ ]*:")) then {cls: "ignored"} else {cls: "param"} end)
              else {cls: "bash", spec: $p.spec} end)
           elif ($p.spec == null or $p.spec == "*") and any(("Edit", "Write", "Read"); . as $t | $p | tool_is($t)) then {cls: "whole"}
           else {cls: "other"} end) as $c   # other-tool
        | $r + $c
          + {hit: (if $c.cls == "bash" then [ $ship[] | select(. as $e | overlaps($c.spec; ($e | aspec))) ] else [] end)} ] as $classified
    | [ $classified[] | select(.cls == "whole" or (.cls == "bash" and (.hit | length) > 0)) ] as $hits
    | [ $hits[] | .hit[] ] as $ruled
    | [ $classified[] | select(.kind == "deny" and .cls == "bash") | .spec ] as $deny_specs

    # --- every shipped entry: held by an allow rule (its own, or a broader one), and by no deny or ask
    | [ $ship[] | . as $e | {entry: $e, listed: ($allow | any(.[]; . as $a | subsumes($a; $e)))} ] as $E
    | [ $E[] | select(.listed and ($allow_inert | not) and (.entry as $e | $ruled | any(.[]; . == $e) | not)) ] as $covered   # ruled-not-covered

    | [
        # scopes
        ( $S[] | if .state == "unread" then rec("scope"; "unevaluated"; .where; "exists but is not a readable JSON object, so nothing in it was evaluated")
                 elif .state == "absent" then rec("scope"; "ok"; .where; "absent")
                 elif (.shape_ok | not) then rec("scope"; "unevaluated"; .where; "`permissions` or one of its allow/deny/ask lists is not the documented shape, so its rules were not evaluated")
                 else rec("scope"; "ok"; .where; "read: \(.allow | length) allow, \(.deny | length) deny, \(.ask | length) ask") end ),
        ( if ($proj[0].state == "none") then rec("scope"; "info"; "-"; "no project: only the managed file and user settings were read") else empty end ),
        ( if $local_unresolved then rec("scope"; "unevaluated"; ".claude/settings.local.json"; "which local settings file a session here reads could not be established — git could not say whether this directory is in a repository, or it is a linked worktree whose main checkout was not found") else empty end ),
        ( if $cfg_other then rec("scope"; "unevaluated"; "CLAUDE_CONFIG_DIR"; "names another configuration root; the user settings a session there reads were not evaluated") else empty end ),
        ( if $mgd_dir then rec("scope"; "unevaluated"; "managed-settings.d"; "holds managed settings fragments this audit does not read") else empty end ),
        ( if $managed_only then rec("note"; "info"; $managed; "allowManagedPermissionRulesOnly is set: allow, deny and ask rules outside managed settings are ignored, the installed allowlist included — only the managed rules were counted") else empty end ),   # managed-only-notice

        # mode
        ( if ($mode_known | not) then
            (if $mode == "plan" then
               rec("mode"; "unevaluated"; $m.src; "defaultMode \"plan\": whether a planning command is judged, asked or neither depends on whether bypass and auto mode are available to the session, which this audit cannot see")
             elif $mode == "bypassPermissions" then
               rec("mode"; "unevaluated"; $m.src; "defaultMode \"bypassPermissions\" while disableBypassPermissionsMode is set (\($no_bypass | join(", "))): bypass mode cannot be entered, and what the session starts in was not established")
             else
               rec("mode"; "unevaluated"; $m.src; "defaultMode \($top.mode | tojson) is not a documented mode")
             end)
          elif $mode == "auto" then
            rec("mode"; "ok"; $m.src;
                (if $m.why == "local-auto" then "defaultMode \"auto\" does not take effect from project or local settings, so the built-in default applies, and on claude v\($cli) an interactive terminal session starts in auto"
                 elif $m.why == "builtin" then "no defaultMode is set; on claude v\($cli) an interactive terminal session starts in auto (`claude -p` and SDK runs start in default mode)"
                 else "auto" end)
                + ": no routine prompts; a command no allow rule matches is judged by the classifier")
          elif $mode == "acceptEdits" then
            rec("mode"; "ok"; $m.src; "acceptEdits: edits run unasked; a Bash command that no allow rule or sandbox covers \(if $asked == "blocked" then "is refused" else "prompts" end)")
          elif $mode == "bypassPermissions" then
            rec("mode"; "info"; $m.src; "bypassPermissions: nothing prompts and nothing is checked, so no shipped entry is needed — the posture this allowlist exists to avoid")
          elif $mode == "dontAsk" then
            rec("mode"; "blocked"; $m.src; "defaultMode \"dontAsk\": a command no allow rule matches is denied instead of prompting")
          else
            rec("mode"; $asked;
                (if $m.why == "no-auto" then ($no_auto | join(", ")) else $m.src end);
                (if $m.why == "no-auto" then "disableAutoMode turns auto mode off, so sessions start in default mode"
                 elif $m.why == "local-bypass" then "defaultMode \"bypassPermissions\" does not take effect from project or local settings, so the session starts in default mode"
                 else "defaultMode \"\($top.mode)\"" end)
                + ": every command no allow rule matches \(if $asked == "blocked" then "is refused" else "prompts" end)")
          end ),
        ( if $dp then rec("note"; "info"; ($dp_where | join(", ")); "denyInsteadOfPrompting is on: what would prompt is refused instead") else empty end ),
        # WHAT THE VERDICT RESTS ON AND CANNOT SEE, said rather than left implied
        ( if $mode == "auto" then rec("assume"; "info"; "-"; "auto mode is available to the session (a supported model, not turned off for the account, no HIPAA configuration) — where it is not, the session starts in default mode and every unlisted command prompts") else empty end ),   # assume-auto
        ( if ([ $S[] | select(.state == "read") ] | length) > 0 then rec("assume"; "info"; "-"; "each settings file read here is one the CLI loads: this audit parses JSON as jq does and does not check the settings schema, so a file the CLI rejects at startup (it reports a Settings Error) is counted as if it had loaded") else empty end ),   # assume-loads
        ( [ $R[] | select(.name == "project" or .name == "local" or .name == "local2") | .allow[] ] as $pa
          | if ($pa | length) > 0 then rec("assume"; "info"; "-"; "the workspace is trusted: \($pa | length) allow \(plural($pa | length; "rule comes"; "rules come")) from the settings of this project, which count only once its trust dialog has been accepted (the local file too, when it is tracked or `.claude` is a link)") else empty end ),   # assume-trust
        ( if $allow_inert then rec("note"; "classifier"; "autoMode.classifyAllShell"; "is on: in auto mode every shell allow rule is suspended, so no shipped entry skips the classifier") else empty end ),
        ( if ($set_aside | length) > 0 then rec("note"; "info"; "-"; "auto mode sets aside \($set_aside | length) allow \(plural($set_aside | length; "rule"; "rules")) that would run arbitrary code, so \(plural($set_aside | length; "it holds"; "they hold")) no shipped entry: \($set_aside[:3] | join(", "))\(if ($set_aside | length) > 3 then ", …" else "" end)") else empty end ),

        # rules: the ones that can match the shipped surface, and the ones this audit cannot model
        ( $hits[] | . as $h
            # an ask rule never gets to ask when ONE deny rule matches every command it does
            | ($h.kind == "ask" and $h.cls == "bash" and ($deny_specs | any(.[]; . as $d | contains_spec($d; $h.spec)))) as $shadowed   # ask-shadowed
            | rec("rule"; (if $h.kind == "deny" then "blocked" elif $shadowed then "info" else $asked end); $h.where;
                "\($h.kind) rule \($h.rule) " + (if $h.cls == "whole" then "covers a whole tool the workflows use"
                  else "can match \($h.hit | length) shipped \(plural($h.hit | length; "entry"; "entries")): \($h.hit[:3] | join(", "))\(if ($h.hit | length) > 3 then ", …" else "" end)" end)
                + (if $h.kind == "deny" then " — refused in every mode"
                   elif $shadowed then " — but a deny rule matches the same commands, and deny is evaluated first"
                   elif $asked == "blocked" then " — refused instead of asked here"
                   else " — prompts in every mode, auto included" end)) ),
        ( $classified[] | select(.cls == "param")
            | rec("rule"; "unevaluated"; .where; "\(.kind) rule \(.rule) matches Bash calls by an input parameter, whatever the command; which calls it reaches is not something this audit can see") ),   # param-rule
        ( $classified[] | select(.cls == "unparsed")
            | rec("rule"; "unevaluated"; .where; "\(.kind) rule \(.rule) is not in a form this audit can read") ),
        ( $classified[] | select(.cls == "ignored")
            | rec("rule"; "info"; .where; "\(.kind) rule \(.rule) names the `command` parameter, which the CLI ignores with a startup warning") ),
        ( $classified[] | select(.cls == "other" or (.cls == "bash" and (.hit | length) == 0))
            | rec("rule"; "info"; .where; "\(.kind) rule \(.rule) matches no shipped command; whether a workflow step runs into it is outside this audit") ),   # rule-reported
        ( [ $allow_all_rules[] | select(parse == null) ] as $odd
          | if ($odd | length) > 0 then rec("note"; "info"; "-"; "\($odd | length) allow \(plural($odd | length; "rule is"; "rules are")) not rule-shaped and \(plural($odd | length; "holds"; "hold")) nothing: \($odd[:3] | join(", "))\(if ($odd | length) > 3 then ", …" else "" end)") else empty end ),

        # shipped entries no allow rule holds
        ( if $miss_level == null then empty else
            ( $E[] | select(.listed | not)
              | rec("entry"; $miss_level; "-"; "\(.entry) is in no allow list"
                  + (if $miss_level == "classifier" then " — judged by the classifier on every use"
                     elif $miss_level == "blocked" then " — refused"
                     elif $miss_level == "prompt" then " — prompts"
                     else " — what then happens depends on the starting mode, which was not established" end)) )
          end ),

        # the gates of the project: reported, and never part of the verdict
        ( if $gates_state == "unread" then rec("gate"; "info"; "-"; "the gate commands of the project could not be detected, so none is listed")   # gate-report-only
          elif $gates_state == "none" then empty
          elif ($gates | length) == 0 then rec("gate"; "info"; "-"; "no gate command is configured or detected")
          else
            ( $gates[] | . as $g
              | ($g.cmd | compound) as $compound
              | ([ $allow[] | select(aspec as $a | $a != null and ($compound | not) and rmatch($g.cmd; $a)) ] | .[0] // null) as $by
              | rec("gate"; "info"; $g.label;
                  "\($g.cmd) — run as written it " + (if $compound then "holds a shell operator or substitution, so the CLI may match it part by part (not evaluated)"
                                                       elif $by != null then "matches the allow rule \($by)\(if $allow_inert then ", which is suspended while autoMode.classifyAllShell is on" else "" end) (deny and ask rules are not checked against it)"
                                                       else "matches no allow rule" end)) )
          end ),
        rec("note"; "info"; "-"; "not inspected: MDM and server-managed settings; the --settings, --permission-mode and --allowedTools flags of a session; and the sandbox, which runs a sandboxed command unasked whatever is reported here")
      ] as $lines
    | ([ $lines[] | split("\t")[1] ]) as $levels
    | ([ $levels[] | select(. == "unevaluated") ] | length) as $nu
    | ([ $levels[] | select(. == "prompt" or . == "blocked" or . == "classifier") ] | length) as $nf
    | ([ $S[] | select(.state != "unread" and .shape_ok) ] | length) as $nread
    | (if $nu > 0 or ($ship | length) == 0 then "unevaluated" elif $nf > 0 then "findings" else "clean" end) as $verdict   # verdict
    | $lines[],
      rec("summary"; $verdict; "-";
          "entries=\($covered | length)/\($ship | length) scopes=\($nread)/\($S | length) rules=\($rules | length) findings=\($nf) unevaluated=\($nu)")
  ' 2>/dev/null)" || {
    _adb_perm_unevaluated - "the audit could not be computed"; return 11
  }
  printf '%s\n' "$out"
  case "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "summary" { v = $2 } END { print v }')" in
    clean) return 0 ;;
    findings) return 10 ;;
    *) return 11 ;;
  esac
)

# --- dispatch, only when executed ----------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _adb_perm_usage() {
    printf 'usage: permissions-lib.sh entries [--repo <clone>]\n' >&2
    printf '       permissions-lib.sh missing [--repo <clone>] [--home <home>]\n' >&2
    printf '       permissions-lib.sh match   [--repo <clone>] -- <command>\n' >&2
    printf '       permissions-lib.sh audit   [--repo <clone>] [--home <home>] [--project <root>] [--managed <file>]\n' >&2
  }
  [ "$#" -ge 1 ] || { _adb_perm_usage; exit 2; }
  _adb_perm_sub="$1"; shift
  _adb_perm_repo=""; _adb_perm_home="${HOME:-}"; _adb_perm_project=""; _adb_perm_project_set=0; _adb_perm_managed=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)    [ "$#" -ge 2 ] || { _adb_perm_usage; exit 2; }; _adb_perm_repo="$2"; shift 2 ;;
      --home)    [ "$#" -ge 2 ] || { _adb_perm_usage; exit 2; }; _adb_perm_home="$2"; shift 2 ;;
      --project) [ "$#" -ge 2 ] || { _adb_perm_usage; exit 2; }; _adb_perm_project="$2"; _adb_perm_project_set=1; shift 2 ;;
      --managed) [ "$#" -ge 2 ] || { _adb_perm_usage; exit 2; }; _adb_perm_managed="$2"; shift 2 ;;
      -h|--help) _adb_perm_usage; exit 0 ;;
      --) shift; break ;;
      *) _adb_perm_usage; exit 2 ;;
    esac
  done
  [ -n "$_adb_perm_home" ] || { printf 'permissions-lib: no home directory (set HOME or pass --home)\n' >&2; exit 2; }
  if [ -z "$_adb_perm_repo" ]; then
    _adb_perm_repo="$(adb_install_source "$_adb_perm_home")" \
      || _adb_perm_repo="$(cd -P "$_adb_perm_libdir" 2>/dev/null && cd ../.. && pwd -P)" \
      || { printf 'permissions-lib: cannot locate the baseline clone (pass --repo)\n' >&2; exit 2; }
  fi
  _adb_perm_ship() {
    adb_permissions_entries "$(adb_permissions_payload "$_adb_perm_repo")" || {
      printf 'permissions-lib: the shipped allowlist could not be read: %s\n' "$(adb_permissions_payload "$_adb_perm_repo")" >&2
      return 1; }
  }
  case "$_adb_perm_sub" in
    entries)
      _adb_perm_e="$(_adb_perm_ship)" || exit 11
      printf '%s' "$_adb_perm_e" | jq -r '.[]' ;;
    missing)
      _adb_perm_e="$(_adb_perm_ship)" || exit 11
      _adb_perm_t="$(mktemp "${TMPDIR:-/tmp}/adb-allow.XXXXXX" 2>/dev/null)" || exit 11
      _adb_perm_scope "$_adb_perm_home/.claude/settings.json" "$_adb_perm_t" && [ -s "$_adb_perm_t" ] || {   # missing-staged
        rm -f "$_adb_perm_t"
        printf 'permissions-lib: could not stage %s for reading\n' "$_adb_perm_home/.claude/settings.json" >&2
        exit 11; }
      _adb_perm_m="$(jq -r --argjson ship "$_adb_perm_e" '
        if .state == "unread" or (.state == "read" and (.p_shape == "bad" or (.allow | type) != "array" or (.allow | all(.[]; type == "string") | not))) then error("unread")   # missing-elements
        else (if .state == "read" then .allow else [] end) as $live
          | $ship[] | select(. as $e | any($live[]; . == $e) | not) end' "$_adb_perm_t" 2>/dev/null)" || {
        rm -f "$_adb_perm_t"
        printf 'permissions-lib: %s is not a readable JSON object with a usable permissions.allow\n' "$_adb_perm_home/.claude/settings.json" >&2
        exit 11; }
      rm -f "$_adb_perm_t"
      [ -z "$_adb_perm_m" ] || printf '%s\n' "$_adb_perm_m" ;;
    match)
      [ "$#" -eq 1 ] && [ -n "$1" ] || { _adb_perm_usage; exit 2; }   # match-one-argument
      _adb_perm_e="$(_adb_perm_ship)" || exit 11
      jq -n -e --arg cmd "$1" "$(_adb_perm_jq_defs)"'$cmd | compound | not' >/dev/null 2>&1; _adb_perm_c=$?
      [ "$_adb_perm_c" -ne 1 ] || {   # match-one-command
        printf 'permissions-lib: match answers for ONE simple command; this one holds a shell operator or substitution (quoted or not), which the CLI may match part by part\n' >&2
        exit 2; }
      [ "$_adb_perm_c" -eq 0 ] || exit 11
      _adb_perm_m="$(jq -n -r --argjson ship "$_adb_perm_e" --arg cmd "$1" "$(_adb_perm_jq_defs)"'
        $ship[] | select(aspec as $s | $s != null and rmatch($cmd; $s))')" || exit 11
      [ -n "$_adb_perm_m" ] || exit 1
      printf '%s\n' "$_adb_perm_m" ;;
    audit)
      if [ "$_adb_perm_project_set" -eq 0 ]; then
        _adb_perm_project="$PWD"
      fi
      if [ -z "$_adb_perm_managed" ]; then
        case "$(uname -s 2>/dev/null)" in
          Darwin) _adb_perm_managed="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
          *)      _adb_perm_managed="/etc/claude-code/managed-settings.json" ;;
        esac
      fi
      adb_permissions_audit "$_adb_perm_repo" "$_adb_perm_home" "$_adb_perm_project" "$_adb_perm_managed" ;;
    *) _adb_perm_usage; exit 2 ;;
  esac
fi
