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
#   declined  recorded as `added` once and since removed by hand. Not written again. The row only
#             ever SUPPRESSES a write; it authorises no removal, so an entry the operator puts back
#             is theirs.
#
# A recorded entry the payload no longer ships is retired: removed while still present, forgotten
# either way. Only `permissions.allow` is ever written — never `defaultMode`, `deny` or `ask`.
#
# THE AUDIT IS READ-ONLY and reports, per scope it could read: a shipped entry no allow rule holds,
# a `deny` or `ask` rule that can match one, the starting permission mode, and the settings that
# make allow rules inert. A scope it could not read, or an audit that evaluated nothing, is NOT
# EVALUATED (11) and never clean.
#
# Usage (executed):
#   permissions-lib.sh entries [--repo <clone>]
#       the shipped allow entries, one per line
#   permissions-lib.sh missing [--repo <clone>] [--home <home>]
#       shipped entries absent from <home>/.claude/settings.json, one per line (0, maybe none · 11 unreadable)
#   permissions-lib.sh match [--repo <clone>] -- <command>
#       the shipped entries that match ONE simple command as written (0 some · 1 none). A compound
#       command is matched part by part by the CLI, never by this
#   permissions-lib.sh audit [--repo <clone>] [--home <home>] [--project <root>] [--managed <file>]
#       stdout: `<kind>\t<level>\t<where>\t<text>` records, then one `summary` record
#       kind   scope | mode | entry | rule | gate | note
#       level  ok | info | classifier | prompt | blocked | unevaluated
#       exit   0 clean · 10 prompt sources found · 11 not evaluated · 2 usage
#   --repo defaults to the clone the global install points into; --project to the git root of the
#   working directory; --managed to the platform's managed-settings.json.
#
# Sourced (install.sh, uninstall.sh, bin/baseline): adb_permissions_apply, adb_permissions_remove,
# adb_permissions_pending. apply and remove expect the caller to HOLD the settings lock
# (adb_settings_lock_take): each defers and resumes that lock's signal traps around its two writes.
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

# Usage: adb_permissions_payload <clone>
adb_permissions_payload() { printf '%s/agents/claude/settings.permissions.json' "$1"; }

# Usage: adb_permissions_receipt [home]
adb_permissions_receipt() { printf '%s/.claude/.adb-permissions-owned' "${1:-${HOME:-/root}}"; }

# The CLI floor for the entries as shipped: every one is a `Bash(<prefix> *)` or exact-command
# rule, and `*` at any position in a Bash rule arrived in v2.1.0 (vendor CHANGELOG, "## 2.1.0",
# read 2026-11-11). `permissions.allow` itself states no floor.
adb_permissions_floor() { printf '2.1.0'; }

# The shipped entries as ONE compact JSON array. The payload must be exactly
# `{"permissions":{"allow":[…]}}`: a second key would be a setting this surface never writes.
# Usage: adb_permissions_entries <payload>
# Returns: 0 · 1 the payload is missing or not that shape · 2 no jq
adb_permissions_entries() {
  command -v jq >/dev/null 2>&1 || return 2
  [ -s "$1" ] || return 1
  jq -c -e '
    if type == "object" and keys == ["permissions"]
       and (.permissions | type == "object" and keys == ["allow"])
       and (.permissions.allow | type == "array" and length > 0
            and all(.[]; type == "string" and startswith("Bash(") and endswith(")") and length > 6
                         and (explode | all(.[]; . >= 32 and . != 127)))
            and length == (unique | length))
    then .permissions.allow else error("not an allowlist payload") end
  ' "$1" 2>/dev/null || return 1
}

# The receipt's disposition, readable without jq: `none` for an absent or empty receipt.
# Usage: adb_permissions_disposition <receipt>
# Returns: 0 · 20 the receipt could not be read · 21 it carries no recognised disposition
adb_permissions_disposition() {
  local receipt="$1" line grc
  case "$(adb_settings_doc_state "$receipt")" in
    absent|empty) printf 'none'; return 0 ;;
    present) ;;
    *) return 20 ;;
  esac
  line="$(grep -m1 '^disposition ' "$receipt" 2>/dev/null)"; grc=$?
  [ "$grc" -le 1 ] || return 20
  [ "$grc" -eq 0 ] || return 21
  case "${line#disposition }" in
    installed|skipped-optout|skipped-below-floor|skipped-unprobeable|skipped-blocked) printf '%s' "${line#disposition }" ;;
    *) return 21 ;;
  esac
}

# The whole receipt as JSON, validated whole: one unrecognised line, an entry that is not a JSON
# string, or an entry recorded both `added` and `declined` refuses the lot.
#   {"disposition","payload","source","added":[…],"declined":[…],"created":[…]}
# Usage: _adb_perm_receipt_json <receipt>
# Returns: 0 · 2 no jq · 20 unreadable · 21 damaged
_adb_perm_receipt_json() {
  local receipt="$1"
  command -v jq >/dev/null 2>&1 || return 2
  case "$(adb_settings_doc_state "$receipt")" in
    absent|empty)
      printf '%s\n' '{"disposition":"none","payload":null,"source":null,"added":[],"declined":[],"created":[]}'
      return 0 ;;
    present) ;;
    *) return 20 ;;
  esac
  local raw
  raw="$(cat "$receipt" 2>/dev/null)" || return 20
  printf '%s\n' "$raw" | jq -c -R -s '
    def entry($prefix; $l): ($l[($prefix | length):] | try fromjson catch null);
    [ split("\n")[] | select(length > 0 and (startswith("#") | not)) ] as $ls
    | reduce $ls[] as $l (
        {disposition: null, version: null, floor: null, payload: null, source: null,
         added: [], declined: [], created: [], bad: false};
        if .bad then .
        elif ($l | startswith("disposition ")) and .disposition == null then .disposition = $l[12:]
        elif ($l | startswith("version ")) and .version == null then .version = $l[8:]
        elif ($l | startswith("floor ")) and .floor == null then .floor = $l[6:]
        elif ($l | startswith("payload ")) and .payload == null then .payload = $l[8:]
        elif ($l | startswith("source\t")) and .source == null then .source = $l[7:]
        elif ($l | startswith("added\t")) then
          (entry("added\t"; $l)) as $v
          | if ($v | type) == "string" and ($v | length) > 0 then .added += [$v] else .bad = true end
        elif ($l | startswith("declined\t")) then
          (entry("declined\t"; $l)) as $v
          | if ($v | type) == "string" and ($v | length) > 0 then .declined += [$v] else .bad = true end
        elif $l == "created\tallow" or $l == "created\tpermissions" then .created += [$l[8:]]
        else .bad = true end)
    | (.disposition) as $d
    | if .bad
         or (["installed","skipped-optout","skipped-below-floor","skipped-unprobeable","skipped-blocked"] | any(.[]; . == $d) | not)
         or ((.added + .declined) | length != (unique | length))
      then error("damaged receipt")
      else {disposition, payload, source, added, declined, created: (.created | unique)} end
  ' 2>/dev/null || return 21
}

# Render a receipt. Rows arrive on stdin exactly as they are stored (`added<TAB><json string>`,
# `declined<TAB><json string>`, `created<TAB>allow|permissions`).
# Usage: adb_permissions_receipt_render <disposition> <version> <floor> <payload-digest> <clone>
adb_permissions_receipt_render() {
  printf '# ai-dev-baseline command allowlist (#288) — written by install.sh; do not hand-edit.\n'
  printf 'disposition %s\nversion %s\nfloor %s\npayload %s\n' "$1" "$2" "$3" "$4"
  printf 'source\t%s\n' "$5"
  cat
}

# Record a run that wrote no entry, keeping every row an earlier install recorded: a skip means
# "write nothing new", never "forget what is there". Needs no jq.
# Usage: _adb_perm_record_skip <disposition> <version> <floor> <digest|-> <receipt> <clone>
#   <digest> `-` keeps the digest already recorded, so the skip does not claim a payload it never applied.
# Returns: 0 recorded · 1 the receipt could not be read or written (the previous one is left as it was)
_adb_perm_record_skip() {
  local disposition="$1" version="$2" floor="$3" digest="$4" receipt="$5" repo="$6"
  local rows="" prior="-" line state
  state="$(adb_settings_doc_state "$receipt")"
  case "$state" in
    absent|empty) ;;
    present)
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "added$_ADB_PERM_TAB"*|"declined$_ADB_PERM_TAB"*|"created$_ADB_PERM_TAB"*) rows+="$line"$'\n' ;;
          "payload "*) prior="${line#payload }" ;;
        esac
      done < "$receipt" || return 1
      ;;
    *) return 1 ;;
  esac
  [ "$digest" != "-" ] || digest="$prior"
  if printf '%s' "$rows" | adb_permissions_receipt_render "$disposition" "$version" "$floor" "$digest" "$repo" \
       > "$receipt.adb.$$.tmp" && adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; then
    return 0
  fi
  rm -f "$receipt.adb.$$.tmp"
  return 1
}

# The union, as arithmetic over three inputs and nothing else: the live document, the shipped
# entries, and the prior record. Prints
#   {"verdict":"write"|"unchanged"|"blocked","why",
#    "settings","wrote":[…],"retired":[…],"added":[…],"declined":[…],"created":[…]}
# `blocked` means `permissions` or `permissions.allow` is there in a shape an entry cannot be
# appended to; nothing is written and `why` names the shape.
# Usage: _adb_perm_merge <settings-file> <shipped-json-array> <receipt-json>
# Returns: 0 · 1 the settings file is not valid JSON
_adb_perm_merge() {
  jq -c --argjson ship "$2" --argjson rc "$3" '
    def has_el($xs; $x): any($xs[]; . == $x);
    . as $cur
    | if ($cur | type) != "object" then {verdict: "blocked", why: "settings.json does not hold a JSON object"}
      elif ($cur | has("permissions")) and ($cur.permissions | type) != "object" then
        {verdict: "blocked", why: "`permissions` is not an object"}
      elif (($cur.permissions // {}) | has("allow")) and ($cur.permissions.allow | type) != "array" then
        {verdict: "blocked", why: "`permissions.allow` is not an array"}
      else
        ($cur.permissions.allow // []) as $live
        | [ $rc.added[] | select(. as $e | has_el($ship; $e) | not) | select(. as $e | has_el($live; $e)) ] as $retire
        | [ $live[] | select(. as $e | has_el($retire; $e) | not) ] as $kept
        | (reduce $ship[] as $e ({wrote: [], added: [], declined: []};
             if has_el($kept; $e) then (if has_el($rc.added; $e) then .added += [$e] else . end)
             elif has_el($rc.added; $e) or has_el($rc.declined; $e) then .declined += [$e]   # declined-not-rewritten
             else .wrote += [$e] | .added += [$e] end)) as $r
        | ($kept + $r.wrote) as $new
        | ([ (if ($cur | has("permissions")) then empty else "permissions" end),
             (if (($cur.permissions // {}) | has("allow")) then empty else "allow" end) ]
           | if ($r.wrote | length) > 0 then . else [] end) as $made
        | {verdict: (if $new == $live then "unchanged" else "write" end), why: "",
           settings: (if $new == $live then $cur else ($cur | .permissions = ((.permissions // {}) | .allow = $new)) end),
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

# Put the pre-image of settings.json back after a receipt that would not publish, so no entry is
# left installed with nothing recording it. <pre> is a copy of the original, or empty when there
# was no file. Usage: _adb_perm_restore <settings> <pre>   Returns: 0 restored · 1 it could not be
_adb_perm_restore() {
  local settings="$1" pre="$2"
  if [ -n "$pre" ]; then
    adb_publish_json "$pre" "$settings" --allow-empty
  else
    rm -f "$settings" 2>/dev/null && [ ! -e "$settings" ]
  fi
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
    adb_info "  allowlist  SKIPPED — claude v$version is below the v$floor floor for wildcard Bash rules."
    adb_info "             Upgrade the CLI; the next \`baseline update\` applies them."
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

  local pre=""
  if [ "$verdict" = write ]; then
    # `empty` too: a zero-byte file is a file, and a rollback that deleted it would not be one.
    if [ "$docst" != absent ]; then   # pre-image-of-empty
      if [ ! -e "$backup$settings" ]; then
        mkdir -p "$backup$(dirname "$settings")" 2>/dev/null && cp -p "$settings" "$backup$settings" 2>/dev/null || {
          adb_info "  WARN   could not back up $settings under $backup — allow entries NOT written"
          return 1; }
      fi
      pre="$(mktemp "${TMPDIR:-/tmp}/adb-allow.XXXXXX" 2>/dev/null)" && cp "$settings" "$pre" 2>/dev/null || {
        rm -f "${pre:-}"
        adb_info "  WARN   could not stage a copy of $settings to roll back to — allow entries NOT written"
        return 1; }
    fi
  fi

  # TWO PUBLICATIONS, ONE TRANSACTION: the settings, then the record of what in them is ours.
  adb_settings_lock_defer_signals
  if [ "$verdict" = write ]; then
    if ! { printf '%s' "$result" | jq '.settings' > "$settings.adb.$$.tmp" 2>/dev/null \
           && adb_publish_json "$settings.adb.$$.tmp" "$settings"; }; then
      rm -f "$settings.adb.$$.tmp" "$pre"
      adb_settings_lock_resume_signals
      adb_info "  WARN   could not rewrite ~/.claude/settings.json — allow entries NOT written"
      return 1
    fi
  fi
  [ -z "$rows" ] || rows+=$'\n'
  if ! { printf '%s' "$rows" \
           | adb_permissions_receipt_render installed "$version" "$floor" "$digest" "$repo" > "$receipt.adb.$$.tmp" \
         && adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; }; then
    rm -f "$receipt.adb.$$.tmp"
    if [ "$verdict" = write ]; then
      if _adb_perm_restore "$settings" "$pre"; then
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
  [ -z "$pre" ] || rm -f "$pre"
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
# Usage: adb_permissions_remove <clone> <home> [ours 0|1]
#   <ours> 1 when ~/.claude is installed from <clone>; consulted only for a receipt with no source row.
# Globals: the caller's settings lock traps (deferred and resumed around the two writes)
# Returns: 0 removed, nothing to remove, or left alone because the record is another clone's (said)
#          1 could not be removed; the reason is printed
adb_permissions_remove() {
  local repo="$1" home="$2" ours="${3:-0}"
  local settings="$home/.claude/settings.json" receipt disp drc rj rrc
  receipt="$(adb_permissions_receipt "$home")"
  disp="$(adb_permissions_disposition "$receipt")"; drc=$?
  if [ "$drc" -ne 0 ]; then
    adb_info "  ERROR  $receipt cannot be read or classified, so the allow entries it records cannot be"
    adb_info "         removed by it. NOTHING was removed — restore it and re-run."
    return 1
  fi
  if [ "$disp" = none ]; then
    [ ! -e "$receipt" ] || rm -f "$receipt" 2>/dev/null || true
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
  if [ -z "$recorded" ] && [ "$ours" != 1 ]; then
    adb_info "  allowlist  left alone — ~/.claude is installed from another clone, so its allow entries are not ours to remove"
    return 0
  fi

  local docst result changed n_removed
  docst="$(adb_settings_doc_state "$settings")"
  case "$docst" in
    absent|empty)
      rm -f "$receipt" 2>/dev/null && [ ! -e "$receipt" ] || {
        adb_info "  ERROR  $receipt could not be deleted — remove it by hand."; return 1; }
      return 0 ;;
    present) ;;
    *)
      adb_info "  WARN   ~/.claude/settings.json does not resolve to a readable file — allow entries NOT removed."
      return 1 ;;
  esac
  result="$(jq -c --argjson rc "$rj" '
    def has_el($xs; $x): any($xs[]; . == $x);
    . as $cur
    | if ($cur | type) != "object" or (($cur.permissions // null) | type) != "object"
         or (($cur.permissions.allow // null) | type) != "array"
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
    if ! { printf '%s' "$result" | jq '.settings' > "$settings.adb.$$.tmp" 2>/dev/null \
           && adb_publish_json "$settings.adb.$$.tmp" "$settings"; }; then
      rm -f "$settings.adb.$$.tmp"
      adb_settings_lock_resume_signals
      adb_info "  WARN   could not rewrite ~/.claude/settings.json — allow entries NOT removed; $receipt lists them."
      return 1
    fi
  fi
  # GONE, OR FAILING THAT, EMPTY. An empty record reads as none, so a later install cannot take the
  # entries just removed for ones the operator declined.
  if ! { rm -f "$receipt" 2>/dev/null && [ ! -e "$receipt" ]; } && ! { : > "$receipt"; } 2>/dev/null; then   # receipt-emptied
    adb_settings_lock_resume_signals
    adb_info "  ERROR  the allow entries were removed but $receipt could not be deleted or emptied. Remove it by"
    adb_info "         hand: a later install would read every entry it lists as one you declined."
    return 1   # receipt-delete-failed
  fi
  adb_settings_lock_resume_signals
  adb_info "  allowlist  removed $n_removed allow entr$([ "$n_removed" = 1 ] && printf 'y' || printf 'ies') this install added to ~/.claude/settings.json"
  return 0
}

# Would an install change the allowlist or its record? Asked by `baseline update` when every link
# already resolves. A refusal and an install are retried when the PAYLOAD changes, a version skip
# when the CLI now clears the floor; an opt-out never is. A record naming another clone is pending
# whatever it says: the installer rewrites its source, so that converges after one visit.
# Usage: adb_permissions_pending <clone> [home]
# Returns: 0 pending · 1 not pending · 20 the receipt could not be read · 21 it is damaged
#          24 the payload could not be hashed
adb_permissions_pending() {
  local src="$1" home="${2:-$HOME}" receipt payload disp drc have want version
  adb_agent_ours claude "$src" "$home" || return 1
  payload="$(adb_permissions_payload "$src")"
  [ -s "$payload" ] || return 1
  receipt="$(adb_permissions_receipt "$home")"
  disp="$(adb_permissions_disposition "$receipt")"; drc=$?
  case "$drc" in 0) ;; 20|21) return "$drc" ;; *) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  if [ "$disp" != none ]; then
    local grc=0
    have="$(grep -m1 "^source$_ADB_PERM_TAB" "$receipt" 2>/dev/null)" || grc=$?
    [ "$grc" -le 1 ] || return 20
    if [ -n "$have" ] && [ "${have#source"$_ADB_PERM_TAB"}" != "$src" ]; then return 0; fi   # foreign-source-pending
  fi
  case "$disp" in
    skipped-optout) return 1 ;;
    installed|skipped-blocked)
      have="$(grep -m1 '^payload ' "$receipt" 2>/dev/null)" || return 0
      want="$(adb_sha256 "$payload")" || return 24
      [ "${have#payload }" = "$want" ] && return 1
      return 0 ;;
  esac
  version="$(adb_claude_cli_version)" || return 1
  adb_version_ge "$version" "$(adb_permissions_floor)"
}

# --- the audit -----------------------------------------------------------------------------------

# The jq definitions the rule readers share, prepended to each program that asks, so matching has
# ONE spelling:
#   norm                 the legacy `:*` suffix is the other vendor spelling of a trailing ` *`
#   spec                 the Bash specifier of a rule: "*" for the whole tool, null for another tool
#   gmatch($t; $p)       does glob $p — `*` is its only special character — match the whole of $t?
#   rmatch($t; $p)       gmatch, plus: a trailing ` *` also matches the bare command (vendor:
#                        `Bash(npm run *)` matches `npm run`)
#   overlaps($d; $e)     can specifier $d match a command that specifier $e matches?
#   subsumes($a; $e)     does allow RULE $a hold every command RULE $e does? The same rule, or a
#                        `<prefix> *` rule whose prefix is a whole-word prefix of $e. Anything
#                        else answers no, so a miss is over-reported and never under-reported.
_adb_perm_jq_defs() {
  printf '%s\n' '
def norm: if endswith(":*)") then .[:-3] + " *)" else . end;
def spec: norm | if . == "Bash" then "*" elif startswith("Bash(") and endswith(")") then .[5:-1] else null end;
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
def rmatch($t; $p): gmatch($t; $p) or (($p | endswith(" *")) and gmatch($t; $p[:-2]));
def lit: split("*")[0];
def subsumes($a; $e):
  ($a | norm) as $a | ($e | norm) as $e
  | $a == $e
    or (($a | spec) as $as | ($e | spec) as $es
        | $as != null and $es != null and ($as | endswith(" *")) and ($as[:-2] | contains("*") | not)
          and (($es | if endswith(" *") then .[:-2] else . end) as $q
               | ($q | contains("*") | not) and ($q == $as[:-2] or ($q | startswith($as[:-1])))));
def overlaps($d; $e):
  if ($d | contains("*") | not) then rmatch($d; $e)
  elif ($e | contains("*") | not) then rmatch($e; $d)
  else (($d | lit) as $a | ($e | lit) as $b | ($a | startswith($b)) or ($b | startswith($a))) end;'
}


# One settings scope as `{"state":"absent"|"read"|"unread","doc":{…}}`.
# Usage: _adb_perm_scope <file>
_adb_perm_scope() {
  local f="$1" doc
  case "$(adb_settings_doc_state "$f")" in
    absent|empty) printf '%s' '{"state":"absent","doc":{}}'; return 0 ;;
    present) ;;
    *) printf '%s' '{"state":"unread","doc":{}}'; return 0 ;;
  esac
  if doc="$(jq -c 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" && [ -n "$doc" ]; then
    printf '{"state":"read","doc":%s}' "$doc"
  else
    printf '%s' '{"state":"unread","doc":{}}'
  fi
}

# Usage: adb_permissions_audit <clone> <home> <project-root|""> <managed-file>
# Outputs: the records documented in this file's header, on stdout
# Returns: 0 clean · 10 prompt sources found · 11 not evaluated
adb_permissions_audit() {
  local repo="$1" home="$2" project="$3" managed="$4"
  local ship user proj local_ mgd gates="" gates_state=none cli="" cfg_other=false mgd_dir=false out rc
  if ! command -v jq >/dev/null 2>&1; then
    printf 'note\tunevaluated\t-\tjq is not installed, so no settings file was read\n'
    printf 'summary\tunevaluated\t-\tentries=0/0 scopes=0/0 rules=0 findings=0 unevaluated=1\n'
    return 11
  fi
  if ! ship="$(adb_permissions_entries "$(adb_permissions_payload "$repo")")"; then
    printf 'note\tunevaluated\t%s\tthe shipped allowlist could not be read, so no entry was evaluated\n' "$(adb_permissions_payload "$repo")"
    printf 'summary\tunevaluated\t-\tentries=0/0 scopes=0/0 rules=0 findings=0 unevaluated=1\n'
    return 11
  fi
  mgd="$(_adb_perm_scope "$managed")"
  user="$(_adb_perm_scope "$home/.claude/settings.json")"
  if [ -n "$project" ]; then
    proj="$(_adb_perm_scope "$project/.claude/settings.json")"
    local_="$(_adb_perm_scope "$project/.claude/settings.local.json")"
    local g grc=0
    g="$(bash "$_adb_perm_libdir/project-gates.sh" detect "$project" 2>/dev/null)" || grc=$?
    if [ "$grc" -eq 0 ]; then
      gates_state=detected
      gates="$(printf '%s' "$g" | jq -c -R -s '[ split("\n")[] | select(length > 0) | split("\t") | {label: .[0], cmd: (.[1:] | join("\t"))} ]' 2>/dev/null)" || gates_state=unread
    else
      gates_state=unread
    fi
  else
    proj='{"state":"none","doc":{}}'; local_='{"state":"none","doc":{}}'
  fi
  [ -n "$gates" ] || gates='[]'
  cli="$(adb_claude_cli_version 2>/dev/null)" || cli=""
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ ! "$CLAUDE_CONFIG_DIR" -ef "$home/.claude" ]; then cfg_other=true; fi
  if [ -d "$(dirname "$managed")/managed-settings.d" ]; then
    local mgd_ls
    # A directory that cannot be listed is not an empty one.
    if ! mgd_ls="$(ls -A "$(dirname "$managed")/managed-settings.d" 2>/dev/null)" || [ -n "$mgd_ls" ]; then mgd_dir=true; fi
  fi
  # v2.1.283: the release from which `auto` is the built-in starting mode of an interactive
  # session on every plan (vendor permission-modes page, read 2026-11-11). Before it the built-in
  # start depends on the plan, which this cannot see.
  local auto_default=false
  if [ -n "$cli" ] && adb_version_ge "$cli" 2.1.283; then auto_default=true; fi

  local defs; defs="$(_adb_perm_jq_defs)"
  out="$(jq -n -r --argjson ship "$ship" --argjson mgd "$mgd" --argjson user "$user" --argjson proj "$proj" \
      --argjson local "$local_" --argjson gates "$gates" --arg gates_state "$gates_state" --arg cli "$cli" \
      --argjson auto_default "$auto_default" --argjson cfg_other "$cfg_other" --argjson mgd_dir "$mgd_dir" \
      --arg managed "$managed" "$defs"'
    # One record is one line of four fields: a control character in a rule, a path or a gate
    # command — text a project controls — is replaced, so it cannot end a field or start a record.
    def clean: explode | map(if . < 32 or . == 127 then 63 else . end) | implode;
    def rec($k; $l; $w; $t): [$k, $l, ($w | clean), ($t | clean)] | join("\t");   # record-one-line
    def strs($v): if ($v | type) == "array" and all($v[]; type == "string") then $v else null end;

    [ {name: "managed", s: $mgd, where: $managed},
      {name: "user", s: $user, where: "~/.claude/settings.json"},
      {name: "project", s: $proj, where: ".claude/settings.json"},
      {name: "local", s: $local, where: ".claude/settings.local.json"} ] as $scopes
    | [ $scopes[] | select(.s.state != "none") ] as $known
    | [ $known[] | . as $sc
        | ($sc.s.doc.permissions // {}) as $p
        | {name, where, state: $sc.s.state,
           shape_ok: (($p | type) == "object"
                      and all(("allow", "deny", "ask"); . as $k | ($p | has($k) | not) or (strs($p[$k]) != null))),
           allow: (if ($p | type) == "object" then (strs($p.allow // []) // []) else [] end),
           deny:  (if ($p | type) == "object" then (strs($p.deny // []) // []) else [] end),
           ask:   (if ($p | type) == "object" then (strs($p.ask // []) // []) else [] end),
           mode:  (if ($p | type) == "object" then ($p.defaultMode // null) else null end),
           no_auto: (($sc.s.doc.disableAutoMode // null) == "disable"
                     or (($p | type) == "object" and (($p.disableAutoMode // null) == "disable"))),
           classify_all: (($sc.s.doc.autoMode // {}) | if type == "object" then (.classifyAllShell // false) == true else false end),
           managed_only: (($sc.s.doc.allowManagedPermissionRulesOnly // false) == true)} ] as $S
    | ([ $S[] | select(.name == "managed") | .managed_only ] | any) as $managed_only
    | [ $S[] | select(($managed_only | not) or .name == "managed") ] as $R       # the scopes whose rules count
    | [ $R[] | .allow[] | norm ] as $allow
    | [ $R[] | . as $sc | .deny[] | {rule: ., where: $sc.where} ] as $deny
    | [ $R[] | . as $sc | .ask[]  | {rule: ., where: $sc.where} ] as $ask
    | ($allow | any(.[]; . == "Bash" or . == "Bash(*)")) as $allow_all

    # --- the starting mode: managed > local > project > user; `auto` and `bypassPermissions`
    #     take effect only from user or managed settings
    | ([ $S[] | select(.no_auto) | .where ]) as $no_auto
    | ([ ("managed", "local", "project", "user") as $n | $S[] | select(.name == $n and .mode != null)
         | select((.name == "local" or .name == "project") and (.mode == "auto" or .mode == "bypassPermissions") | not) ]
       | .[0] // null) as $msrc
    | ([ $S[] | select((.name == "local" or .name == "project") and (.mode == "auto" or .mode == "bypassPermissions")) ]) as $ignored
    | (if $msrc != null then $msrc.mode elif $auto_default then "auto" else null end) as $mode0
    | (if $mode0 == "auto" and ($no_auto | length) > 0 then "default" else $mode0 end) as $mode
    | (if $mode == "manual" then "default" else $mode end) as $mode
    | ([ $S[] | select(.name == "managed" or .name == "user") | .classify_all ] | any) as $classify_all
    | (($mode == "auto") and $classify_all) as $allow_inert
    | (if $mode == "auto" then "classifier" else "prompt" end) as $miss_level

    # --- every deny and ask rule, classified ONCE: the entries it can match
    | ([ $deny[], $ask[] ] | length) as $nrules
    | [ ($deny[] | . + {kind: "deny"}), ($ask[] | . + {kind: "ask"}) ] as $rules
    | [ $rules[] | . as $r | ($r.rule | spec) as $d
        | ($r.rule | test("^(Edit|Write|Read)(\\(\\*\\))?$")) as $whole
        | [ $ship[] | select($d != null and overlaps($d; (. | spec))) ] as $hit
        | select(($hit | length) > 0 or $whole)
        | $r + {hit: $hit, whole: $whole} ] as $hits
    | [ $hits[] | .hit[] ] as $ruled

    # --- every shipped entry: held by an allow rule (its own, or a broader one), and by no deny or ask
    | [ $ship[] | . as $e | {entry: $e, listed: ($allow_all or ($allow | any(.[]; . as $a | subsumes($a; $e))))} ] as $E
    | [ $E[] | select(.listed and ($allow_inert | not) and (.entry as $e | $ruled | any(.[]; . == $e) | not)) ] as $covered   # ruled-not-covered

    | [
        # scopes
        ( $S[] | if .state == "unread" then rec("scope"; "unevaluated"; .where; "exists but is not a readable JSON object, so nothing in it was evaluated")
                 elif .state == "absent" then rec("scope"; "ok"; .where; "absent")
                 elif (.shape_ok | not) then rec("scope"; "unevaluated"; .where; "`permissions` or one of its allow/deny/ask lists is not the documented shape, so its rules were not evaluated")
                 else rec("scope"; "ok"; .where; "read: \(.allow | length) allow, \(.deny | length) deny, \(.ask | length) ask") end ),
        ( if ($proj.state == "none") then rec("scope"; "info"; "-"; "no project: only the managed file and user settings were read") else empty end ),
        ( if $cfg_other then rec("scope"; "unevaluated"; "CLAUDE_CONFIG_DIR"; "names another configuration root; the user settings a session there reads were not evaluated") else empty end ),
        ( if $mgd_dir then rec("scope"; "unevaluated"; "managed-settings.d"; "holds managed settings fragments this audit does not read") else empty end ),
        ( if $managed_only then rec("note"; "prompt"; $managed; "allowManagedPermissionRulesOnly is set: allow, deny and ask rules outside managed settings are ignored, the installed allowlist included") else empty end ),

        # mode
        ( $ignored[] | rec("mode"; "info"; .where; "defaultMode \"\(.mode)\" is not honoured from project or local settings") ),
        ( if $mode == null then
            rec("mode"; "unevaluated"; "-"; "no defaultMode is set and the built-in starting mode could not be established (claude \(if $cli == "" then "was not found" else "v" + $cli + " predates the v2.1.283 built-in auto default" end))")
          elif $mode == "auto" then
            rec("mode"; "ok"; ($msrc.where // "built-in default"); "auto: no routine prompts; a command no allow rule matches is judged by the classifier")
          elif $mode == "acceptEdits" then
            rec("mode"; "ok"; $msrc.where; "acceptEdits: edits run unasked; a Bash command that no allow rule or sandbox covers prompts")
          elif $mode == "bypassPermissions" then
            rec("mode"; "info"; $msrc.where; "bypassPermissions: nothing prompts and nothing is checked — the posture this allowlist exists to avoid")
          elif $mode == "default" and $mode0 == "auto" then
            rec("mode"; "prompt"; ($no_auto | join(", ")); "disableAutoMode turns auto mode off, so sessions start in default mode and every unlisted command prompts")
          elif $mode == "default" or $mode == "plan" then
            rec("mode"; "prompt"; $msrc.where; "defaultMode \"\($msrc.mode)\": every command no allow rule matches prompts")
          elif $mode == "dontAsk" then
            rec("mode"; "blocked"; $msrc.where; "defaultMode \"dontAsk\": a command no allow rule matches is denied instead of prompting")
          else
            rec("mode"; "unevaluated"; $msrc.where; "defaultMode \(($msrc.mode | tojson)) is not a documented mode")
          end ),
        ( if $allow_inert then rec("note"; "classifier"; "autoMode.classifyAllShell"; "is on: in auto mode every shell allow rule is suspended, so no shipped entry skips the classifier") else empty end ),

        # rules that can match the shipped surface
        ( $hits[] | rec("rule"; (if .kind == "deny" then "blocked" else "prompt" end); .where;
            "\(.kind) rule \(.rule) " + (if .whole then "covers a whole tool the workflows use"
              else "can match \(.hit | length) shipped entr\(if (.hit | length) == 1 then "y" else "ies" end): \(.hit[:3] | join(", "))\(if (.hit | length) > 3 then ", …" else "" end)" end)
            + (if .kind == "deny" then " — refused in every mode" else " — prompts in every mode, auto included" end)) ),

        # shipped entries no allow rule holds
        ( $E[] | select(.listed | not)
            | rec("entry"; $miss_level; "-"; "\(.entry) is in no allow list" + (if $miss_level == "classifier" then " — judged by the classifier on every use" else " — prompts" end)) ),

        # the gates of the project, report only
        ( if $gates_state == "unread" then rec("gate"; "unevaluated"; "-"; "the gate commands of the project could not be detected")
          elif $gates_state == "none" then empty
          elif ($gates | length) == 0 then rec("gate"; "info"; "-"; "no gate command is configured or detected")
          else
            ( "Bash(bash \"$HOME/.claude/scripts/lib/project-gates.sh\" *)" as $w
              | ([ $covered[] | select(.entry == $w) ] | length > 0) as $wok
              | $gates[] | . as $g
              | ($g.cmd | test("[;&|]|\\$\\(|`")) as $compound
              | ([ $allow[] | select((. | spec) as $a | $a != null and ($compound | not) and rmatch($g.cmd; $a)) ] | .[0] // null) as $by
              | rec("gate"; "info"; $g.label;
                  "\($g.cmd) — " + (if $wok then "runs unasked through the allowlisted gate wrapper" else "the gate wrapper is not allowlisted here" end)
                  + "; run directly it is " + (if $compound then "a compound command, matched part by part (not evaluated)"
                                               elif $by != null then "allowed by \($by)" else "in no allow list" end)) )
          end ),
        rec("note"; "info"; "-"; "not inspected: MDM and server-managed settings, and the --settings, --permission-mode and --allowedTools flags of a session")
      ] as $lines
    | ([ $lines[] | split("\t")[1] ]) as $levels
    | ([ $levels[] | select(. == "unevaluated") ] | length) as $nu
    | ([ $levels[] | select(. == "prompt" or . == "blocked" or . == "classifier") ] | length) as $nf
    | ([ $S[] | select(.state != "unread" and .shape_ok) ] | length) as $nread
    | (if $nu > 0 or ($ship | length) == 0 then "unevaluated" elif $nf > 0 then "findings" else "clean" end) as $verdict
    | $lines[],
      rec("summary"; $verdict; "-";
          "entries=\($covered | length)/\($ship | length) scopes=\($nread)/\($S | length) rules=\($nrules) findings=\($nf) unevaluated=\($nu)")
  ' 2>/dev/null)" || {
    printf 'note\tunevaluated\t-\tthe audit could not be computed\n'
    printf 'summary\tunevaluated\t-\tentries=0/0 scopes=0/0 rules=0 findings=0 unevaluated=1\n'
    return 11
  }
  printf '%s\n' "$out"
  rc="$(printf '%s\n' "$out" | awk -F'\t' '$1 == "summary" { v = $2 } END { print v }')"
  case "$rc" in
    clean) return 0 ;;
    findings) return 10 ;;
    *) return 11 ;;
  esac
}

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
  case "$_adb_perm_sub" in
    entries)
      _adb_perm_e="$(adb_permissions_entries "$(adb_permissions_payload "$_adb_perm_repo")")" || {
        printf 'permissions-lib: the shipped allowlist could not be read: %s\n' "$(adb_permissions_payload "$_adb_perm_repo")" >&2; exit 11; }
      printf '%s' "$_adb_perm_e" | jq -r '.[]' ;;
    missing)
      _adb_perm_e="$(adb_permissions_entries "$(adb_permissions_payload "$_adb_perm_repo")")" || {
        printf 'permissions-lib: the shipped allowlist could not be read: %s\n' "$(adb_permissions_payload "$_adb_perm_repo")" >&2; exit 11; }
      _adb_perm_u="$(_adb_perm_scope "$_adb_perm_home/.claude/settings.json")"
      printf '%s' "$_adb_perm_u" | jq -r --argjson ship "$_adb_perm_e" '
        if .state == "unread" then error("unread")
        else ((.doc.permissions // {}) | if type == "object" then (.allow // []) else [] end
              | if type == "array" then . else [] end) as $live
          | $ship[] | select(. as $e | any($live[]; . == $e) | not) end' 2>/dev/null || {
        printf 'permissions-lib: %s is not a readable JSON object\n' "$_adb_perm_home/.claude/settings.json" >&2; exit 11; } ;;
    match)
      [ "$#" -ge 1 ] && [ -n "$1" ] || { _adb_perm_usage; exit 2; }
      _adb_perm_e="$(adb_permissions_entries "$(adb_permissions_payload "$_adb_perm_repo")")" || {
        printf 'permissions-lib: the shipped allowlist could not be read: %s\n' "$(adb_permissions_payload "$_adb_perm_repo")" >&2; exit 11; }
      _adb_perm_m="$(jq -n -r --argjson ship "$_adb_perm_e" --arg cmd "$1" "$(_adb_perm_jq_defs)"'
        $ship[] | select((. | spec) as $s | $s != null and rmatch($cmd; $s))')" || exit 11
      [ -n "$_adb_perm_m" ] || exit 1
      printf '%s\n' "$_adb_perm_m" ;;
    audit)
      if [ "$_adb_perm_project_set" -eq 0 ]; then
        _adb_perm_project="$(git rev-parse --show-toplevel 2>/dev/null)" || _adb_perm_project=""
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
