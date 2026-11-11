#!/usr/bin/env bash
# ai-dev-baseline — tests for the command allowlist (scripts/lib/permissions-lib.sh, #288, D155).
# OFFLINE: no network, no real `claude`, and the tracked tree is never mutated.
#
# WHAT EACH BLOCK GUARDS AGAINST:
#
#   payload    an entry the workflows need going missing, a blanket or interpreter-wide rule
#              arriving, or a second `permissions` key riding the same file
#   union      an install that rewrites or removes an entry the operator owns, re-adds one they
#              removed, strands one it added, or leaves entries installed with no record
#   audit      a CLEAN verdict nobody earned: a prompt source not named, or a scope that could not
#              be read — and an audit that evaluated nothing — reported as clean
#   installer  the surface not being reached from install.sh and uninstall.sh at all
#
# `--mutation` breaks each rule in a copy of the library and requires this suite back RED on that
# row's own witness.
#
# Usage: bash scripts/check-permissions.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-permissions: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-permissions: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -gt 1 ] && { echo "usage: check-permissions.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-permissions.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
check_exit_guard "check-permissions" "rm -rf \"$work\""
check_init check-permissions

PL="$ROOT/scripts/lib/permissions-lib.sh"
PAYLOAD="$ROOT/agents/claude/settings.permissions.json"
unset CLAUDE_CONFIG_DIR

# ============================= --mutation: the rules must be seen RED ============================
if [ "$MODE" = mutation ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/shmutant.sh" || bad "check-permissions: scripts/shmutant.sh could not be sourced"
  shmutant_target scripts/lib/permissions-lib.sh
  shmutant_mut declined-rewritten \
    '             elif has_el($rc.added; $e) or has_el($rc.declined; $e) then .declined += [$e]   # declined-not-rewritten' \
    '             elif false then .declined += [$e]   # declined-not-rewritten' \
    'an entry the operator removed by hand must not be written again'
  shmutant_mut theirs-recorded-as-added \
    '             if has_el($kept; $e) then (if has_el($rc.added; $e) then .added += [$e] else . end)' \
    '             if has_el($kept; $e) then (.added += [$e])' \
    'an entry already present must not be recorded as ours'
  shmutant_mut retire-skipped \
    '        | [ $live[] | select(. as $e | has_el($retire; $e) | not) ] as $kept' \
    '        | $live as $kept' \
    'a recorded entry the payload no longer ships must be retired'
  shmutant_mut allow-shape-unchecked \
    '      elif ($cur | has("permissions")) and ($cur.permissions | has("allow")) and ($cur.permissions.allow | type) != "array" then   # allow-shape' \
    '      elif false then   # allow-shape' \
    'a permissions.allow that is not an array must block the install'
  shmutant_mut remove-takes-theirs \
    '        | [ $live[] | select(. as $e | has_el($rc.added; $e) | not) ] as $new   # remove-only-added' \
    '        | [ $live[] | select(false) ] as $new   # remove-only-added' \
    'uninstall must leave every entry it did not add'
  shmutant_mut rollback-skipped \
    '      if _adb_perm_restore "$settings"; then' \
    '      if true; then' \
    'a receipt that will not publish must put settings.json back byte for byte'
  shmutant_mut rollback-loses-the-link \
    '  if [ "$_ADB_PERM_WAS_LINK" -eq 1 ]; then   # restore-link' \
    '  if false; then   # restore-link' \
    'a receipt that will not publish must leave settings.json the symlink it was'
  shmutant_mut rollback-deletes-instead-of-restoring \
    '  elif [ "$_ADB_PERM_HAD" -eq 1 ]; then' \
    '  elif false; then' \
    'a receipt that will not publish must leave an empty settings.json in place'
  shmutant_mut stage-readable \
    '  if ! { ( umask 077; : > "$tmp" ) && printf '"'"'%s'"'"' "$1" | jq '"'"'.settings'"'"' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; }; then   # stage-owner-only' \
    '  if ! { ( : > "$tmp" ) && printf '"'"'%s'"'"' "$1" | jq '"'"'.settings'"'"' > "$tmp" 2>/dev/null && [ -s "$tmp" ]; }; then   # stage-owner-only' \
    'a settings.json this install creates is owner-only'
  shmutant_mut publish-not-strict \
    '  adb_publish_json "$tmp" "$2" --strict   # publish-strict' \
    '  adb_publish_json "$tmp" "$2"   # publish-strict' \
    'a settings.json whose mode cannot be read is not rewritten'
  shmutant_mut recorded-optout-ignored \
    '  if [ "$if_recorded" = 1 ] && [ "$disp" = skipped-optout ]; then optout=1; fi' \
    '  if false; then optout=1; fi' \
    'a recorded --no-permissions must be honoured by --optout-if-recorded'
  shmutant_mut floor-unchecked \
    '  if ! adb_version_ge "$version" "$floor"; then' \
    '  if false; then' \
    'below the floor no allow entry is written'
  shmutant_mut payload-second-key \
    '       and (.permissions | type == "object" and keys == ["allow"])' \
    '       and (.permissions | type == "object")' \
    'a payload carrying a second permissions key must be refused'
  shmutant_mut foreign-source-removed \
    '  if [ -n "$recorded" ] && [ "$recorded" != "$repo" ]; then' \
    '  if false; then' \
    'a record naming another clone must be left alone'
  shmutant_mut damaged-receipt-accepted \
    '        else .bad = true end)   # unknown-line' \
    '        else . end)   # unknown-line' \
    'a receipt with an unrecognised line must refuse the install'
  shmutant_mut receipt-row-count-unchecked \
    '         or ((.rows | tonumber) != ((.added | length) + (.declined | length) + (.created | length)))   # row-count' \
    '         or false   # row-count' \
    'a receipt with fewer rows than it counts must refuse the install'
  shmutant_mut record-not-validated-on-optout \
    '    if [ "$rrc" -ne 0 ]; then   # record-validated-first' \
    '    if false; then   # record-validated-first' \
    'an opt-out over a record that does not parse must refuse and leave the record as it was'
  shmutant_mut pending-skips-validation \
    '  case "$rrc" in 0) ;; 20|21) return "$rrc" ;; *) return 21 ;; esac   # pending-validates-whole' \
    '  case "$rrc" in *) ;; esac   # pending-validates-whole' \
    'a current record with an unrecognised line is damaged to the currency check too'
  shmutant_mut payload-missing-is-current \
    '  [ -s "$payload" ] || return 24   # payload-missing' \
    '  [ -s "$payload" ] || return 1   # payload-missing' \
    'a clone with no allowlist payload is unanswerable, not current'
  shmutant_mut foreign-source-not-pending \
    '  if [ "$disp" != none ] && [ "$source" != "$src" ]; then return 0; fi   # foreign-source-pending' \
    '  if false; then return 0; fi   # foreign-source-pending' \
    'a record naming another clone is pending'
  shmutant_mut audit-deny-ignored \
    '    | [ ($R[] | . as $sc | .deny[] | {rule: ., where: $sc.where, kind: "deny"}),' \
    '    | [ ($R[] | . as $sc | .deny[] | select(false) | {rule: ., where: $sc.where, kind: "deny"}),' \
    'a deny rule that can match a shipped entry must make the audit red'
  shmutant_mut audit-ask-ignored \
    '          + {hit: (if $c.cls == "bash" then [ $ship[] | select(. as $e | overlaps($c.spec; ($e | aspec))) ] else [] end)} ] as $classified' \
    '          + {hit: []} ] as $classified' \
    'an ask rule that can match a shipped entry must be named'
  shmutant_mut audit-ruled-counted-covered \
    '    | [ $E[] | select(.listed and ($allow_inert | not) and (.entry as $e | $ruled | any(.[]; . == $e) | not)) ] as $covered   # ruled-not-covered' \
    '    | [ $E[] | select(.listed and ($allow_inert | not)) ] as $covered   # ruled-not-covered' \
    'an entry a deny rule can match is not counted as covered'
  shmutant_mut audit-missing-ignored \
    '    | [ $ship[] | . as $e | {entry: $e, listed: ($allow | any(.[]; . as $a | subsumes($a; $e)))} ] as $E' \
    '    | [ $ship[] | . as $e | {entry: $e, listed: true} ] as $E' \
    'a shipped entry in no allow list must make the audit red'
  shmutant_mut audit-broader-rule-ignored \
    '      | $as != null and $es != null' \
    '      | false and $as != null and $es != null' \
    'an entry held by a broader allow rule is not a finding'
  shmutant_mut audit-unread-is-clean \
    '    | (if $nu > 0 or ($ship | length) == 0 then "unevaluated" elif $nf > 0 then "findings" else "clean" end) as $verdict   # verdict' \
    '    | (if false then "unevaluated" elif $nf > 0 then "findings" else "clean" end) as $verdict   # verdict' \
    'a settings file that is not valid JSON must be NOT EVALUATED'
  shmutant_mut audit-legacy-suffix \
    'def norm: if endswith(":*)") then .[:-3] + " *)" else . end;' \
    'def norm: .;' \
    'an ask rule in the legacy :* spelling must be named'
  shmutant_mut audit-mode-precedence \
    '    | ([ ("managed", "local", "project", "user") as $n | $S[] | select(.name == $n and .mode != null) ] | .[0] // null) as $top   # mode-precedence' \
    '    | ([ ("user") as $n | $S[] | select(.name == $n and .mode != null) ] | .[0] // null) as $top   # mode-precedence' \
    'a project defaultMode that narrows the user one must be named'
  shmutant_mut audit-classify-all \
    '    | (($mode == "auto") and $classify_all) as $allow_inert   # classify-all' \
    '    | false as $allow_inert   # classify-all' \
    'autoMode.classifyAllShell must be reported as suspending the allowlist'
  shmutant_mut audit-bare-command \
    'def rmatch($t; $p): gmatch($t; $p) or (($p | endswith(" *")) and ($p[:-2] | contains("*") | not) and $t == $p[:-2]);' \
    'def rmatch($t; $p): gmatch($t; $p);' \
    'an exact deny of the bare command must be named'
  shmutant_mut audit-bare-command-two-wildcards \
    'def rmatch($t; $p): gmatch($t; $p) or (($p | endswith(" *")) and ($p[:-2] | contains("*") | not) and $t == $p[:-2]);' \
    'def rmatch($t; $p): gmatch($t; $p) or (($p | endswith(" *")) and gmatch($t; $p[:-2]));' \
    'a pattern with two wildcards does not match its bare form'
  shmutant_mut audit-tool-glob-ignored \
    'def tool_is($t): if (.tool | contains("*")) then gmatch(($t | ascii_downcase); (.tool | ascii_downcase)) else (.tool | ascii_downcase) == ($t | ascii_downcase) end;' \
    'def tool_is($t): (.tool | ascii_downcase) == ($t | ascii_downcase);' \
    'a deny rule that globs the tool name is named'
  shmutant_mut audit-param-rule-ignored \
    '                (if ($p.spec | test("^command[ ]*:")) then {cls: "ignored"} else {cls: "param"} end)' \
    '                (if ($p.spec | test("^command[ ]*:")) then {cls: "ignored"} else {cls: "other"} end)' \
    'a parameter rule on Bash is NOT EVALUATED'
  shmutant_mut audit-auto-keeps-blanket \
    '    | [ $allow_all_rules[] | select(($mode == "auto" and suspended) | not) ] as $allow   # auto-suspends' \
    '    | $allow_all_rules as $allow   # auto-suspends' \
    'in auto mode a blanket Bash allow rule holds no shipped entry'
  shmutant_mut audit-asked-ignores-mode \
    '    | (if $dp or $mode == "dontAsk" then "blocked" else "prompt" end) as $asked   # asked-level' \
    '    | "prompt" as $asked   # asked-level' \
    'in dontAsk an ask rule is refused, not asked'
  shmutant_mut audit-bypass-version-fixed \
    '    if adb_version_ge "$cli" 2.1.257; then bypass_local=ignored; else bypass_local=honoured; fi' \
    '    bypass_local=ignored' \
    'a project bypassPermissions takes effect on a CLI before v2.1.257'
  shmutant_mut audit-wrong-type-read-as-absent \
    '           p_shape: (if ($doc | has("permissions") | not) then "absent" elif ($p | type) == "object" then "object" else "bad" end),   # shape-of-permissions' \
    '           p_shape: (if ($doc | has("permissions") | not) then "absent" elif ($p | type) == "object" then "object" else "absent" end),   # shape-of-permissions' \
    'a permissions that is not an object is NOT EVALUATED'
  shmutant_mut audit-worktree-own-local-file \
    '        if [ "$gd" != "$cdir" ]; then   # worktree-local-file' \
    '        if false; then   # worktree-local-file' \
    'in a linked worktree the main checkout'"'"'s local settings are the ones audited'
  shmutant_mut audit-record-forged \
    '    def rec($k; $l; $w; $t): [$k, $l, ($w | clean), ($t | clean)] | join("\t");   # record-one-line' \
    '    def rec($k; $l; $w; $t): [$k, $l, $w, $t] | join("\t");   # record-one-line' \
    'a control character in a rule cannot break a record into two'
  shmutant_mut audit-local-auto-falls-to-user \
    '       elif $top_local and $top.mode == "auto" then {mode: $builtin, src: $top.where, why: "local-auto"}   # local-auto-builtin' \
    '       elif false then {mode: $builtin, src: $top.where, why: "local-auto"}   # local-auto-builtin' \
    '…and where the built-in default cannot be established, neither can the mode'
  shmutant_mut audit-local-bypass-not-manual \
    '          elif $bypass_local == "ignored" then {mode: "default", src: $top.where, why: "local-bypass"}   # local-bypass-manual' \
    '          elif $bypass_local == "ignored" then {mode: "auto", src: $top.where, why: "set"}   # local-bypass-manual' \
    'a project bypassPermissions starts the session in default mode'
  shmutant_mut audit-plan-judged \
    '    | ((["auto", "acceptEdits", "bypassPermissions", "default", "dontAsk"] | any(.[]; . == $mode))' \
    '    | ((["auto", "acceptEdits", "bypassPermissions", "default", "dontAsk", "plan"] | any(.[]; . == $mode))' \
    'defaultMode plan is NOT EVALUATED'
  shmutant_mut audit-bypass-disable-ignored \
    '       and (($mode == "bypassPermissions" and ($no_bypass | length) > 0) | not)) as $mode_known   # mode-known' \
    '       and true) as $mode_known   # mode-known' \
    'bypassPermissions under disableBypassPermissionsMode is NOT EVALUATED'
  shmutant_mut audit-two-documents-read-as-one \
    '      (if length == 1 then .[0] else error("not one JSON document") end)   # scope-one-document' \
    '      (.[0])   # scope-one-document' \
    'a settings file holding two JSON documents is NOT EVALUATED'
  shmutant_mut audit-early-record-forged \
    '    printf '"'"'note\tunevaluated\t%s\t%s\n'"'"' "${1//[[:cntrl:]]/?}" "${2//[[:cntrl:]]/?}"   # early-record-one-line' \
    '    printf '"'"'note\tunevaluated\t%s\t%s\n'"'"' "$1" "$2"   # early-record-one-line' \
    'an early failure cannot forge a record either'
  shmutant_mut audit-other-tool-rule-dropped \
    '        ( $classified[] | select(.cls == "other" or (.cls == "bash" and (.hit | length) == 0))' \
    '        ( $classified[] | select(false)' \
    'a rule on another tool is listed, not dropped'
  shmutant_mut audit-shadowed-ask-prompts \
    '            | ($h.kind == "ask" and $h.cls == "bash" and ($deny_specs | any(.[]; . as $d | contains_spec($d; $h.spec)))) as $shadowed   # ask-shadowed' \
    '            | false as $shadowed   # ask-shadowed' \
    'an ask rule a deny rule shadows is not reported as a prompt'
  shmutant_mut audit-shadow-by-shared-entry \
    '  $d == "*" or $d == $a' \
    '  true or $d == "*" or $d == $a' \
    'an ask rule beside a deny rule for other commands still prompts'
  shmutant_mut payload-two-documents \
    '    if length == 1 then .[0] else error("not one JSON document") end   # payload-one-document' \
    '    .[0]   # payload-one-document' \
    'a payload file holding two JSON documents must be refused'
  shmutant_mut unreadable-record-published \
    '  back="$(_adb_perm_receipt_json "$1")" || return 1   # rendered-validated' \
    '  back="$(_adb_perm_receipt_json "$1")" || return 0   # rendered-validated' \
    'a clone path holding a newline refuses the install before anything is written'
  shmutant_mut record-names-another-clone \
    '  [ "$(printf '"'"'%s'"'"' "$back" | jq -r '"'"'.source // ""'"'"' 2>/dev/null; printf x)" = "$2"$'"'"'\nx'"'"' ]   # rendered-source' \
    '  true   # rendered-source' \
    'a record that would read back naming another clone is not published'
  shmutant_mut stage-outside-deferral \
    '  adb_settings_lock_defer_signals   # stage-inside-deferral' \
    '  :   # stage-inside-deferral' \
    'an interrupt during the transaction leaves no staged copy of settings.json behind'
  shmutant_mut audit-empty-file-absent \
    '    empty) printf '"'"'%s\n'"'"' '"'"'{"state":"unread"}'"'"' > "$out"; return "$?" ;;   # empty-not-absent' \
    '    empty) printf '"'"'%s\n'"'"' '"'"'{"state":"absent"}'"'"' > "$out"; return "$?" ;;   # empty-not-absent' \
    'a zero-byte settings file is NOT EVALUATED, not absent'
  shmutant_mut audit-tool-case-sensitive \
    'def tool_is($t): if (.tool | contains("*")) then gmatch(($t | ascii_downcase); (.tool | ascii_downcase)) else (.tool | ascii_downcase) == ($t | ascii_downcase) end;' \
    'def tool_is($t): if (.tool | contains("*")) then gmatch($t; .tool) else .tool == $t end;' \
    'a rule whose tool name is spelled in another case is not missed'
  shmutant_mut audit-spec-whitespace-read \
    '           elif ($p | tool_is("Bash")) and $p.spec != null and ($p.spec | test("^\\s|\\s$")) then {cls: "unparsed"}   # spec-whitespace' \
    '           elif false then {cls: "unparsed"}   # spec-whitespace' \
    'a Bash rule whose specifier has outer whitespace is NOT EVALUATED'
  # Each needs a file or directory the runner cannot use; root has none, and then the case does not run.
  if [ "$(id -u)" -ne 0 ]; then
    shmutant_mut audit-unsearchable-read-as-absent \
      '      if [ -d "$dir" ] && [ -x "$dir" ]; then   # absence-vouched' \
      '      if true; then   # absence-vouched' \
      'a settings file under a directory that cannot be searched is NOT EVALUATED'
    shmutant_mut audit-gate-moves-verdict \
      '        ( if $gates_state == "unread" then rec("gate"; "info"; "-"; "the gate commands of the project could not be detected, so none is listed")   # gate-report-only' \
      '        ( if $gates_state == "unread" then rec("gate"; "unevaluated"; "-"; "the gate commands of the project could not be detected, so none is listed")   # gate-report-only' \
      'an undetectable gate set does not change the verdict'
    shmutant_mut stuck-record-left-claiming \
      '  if ! { rm -f "$receipt" 2>/dev/null && [ ! -e "$receipt" ]; } && ! { : > "$receipt"; } 2>/dev/null; then   # receipt-emptied' \
      '  if ! { rm -f "$receipt" 2>/dev/null && [ ! -e "$receipt" ]; }; then   # receipt-emptied' \
      'a record that cannot be deleted at uninstall must be emptied'
  fi

  prep() { check_copy_subtrees "$ROOT" "$1" scripts base agents docs bin >/dev/null 2>&1; }
  runner() { ( cd "$1" && CP_MUTATION_CHILD=1 bash scripts/check-permissions.sh 2>&1 ); }
  # THE CONTROL: a copy nothing was mutated in must be GREEN, or every row below is red for a reason
  # that is not its mutation. The pool runs no baseline of its own.
  if prep "$work/control" && control_out="$(runner "$work/control")"; then ok
  else bad "the unmodified mutation copy is not green — its rows prove nothing: $(printf '%s\n' "${control_out:-the copy could not be made}" | grep -E '^FAIL|FATAL' | head -3 | tr '\n' ' ')"; fi
  check_shmutant_pool check-permissions "$work/pool" prep runner 6
  check_summary check-permissions
  exit 0
fi

# ------------------------------------------------------------------------------------------------
STUB="$work/bin"; mkdir -p "$STUB"
stub() { printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$STUB/claude"; chmod +x "$STUB/claude"; }
stub "2.1.300 (Claude Code)"

mkhome() {   # mkhome <name> [settings-json] -> the home path
  local h="$work/$1"
  mkdir -p "$h/.claude"
  [ "$#" -lt 2 ] || printf '%s\n' "$2" > "$h/.claude/settings.json"
  printf '%s' "$h"
}
mkrepo() {   # mkrepo <name> <json-array> -> a fixture clone holding only that allowlist payload
  local r="$work/$1"
  mkdir -p "$r/agents/claude"
  jq -n --argjson a "$2" '{permissions: {allow: $a}}' > "$r/agents/claude/settings.permissions.json"
  printf '%s' "$r"
}
# The lib is sourced in a subshell: apply and remove re-arm the settings-lock traps, which must
# never reach this suite's own EXIT guard. `pipefail` because install.sh runs under it.
apply() {    # apply <repo> <home> [optout] [if-recorded] -> the installer lines; status is apply's
  ( export HOME="$2"; PATH="$STUB:$PATH"; . "$PL"; set -o pipefail
    adb_permissions_apply "$1" "$2" "$2/backup" "${3:-0}" "${4:-0}" ) 2>&1
}
remove() {   # remove <repo> <home> [ours]
  ( export HOME="$2"; . "$PL"; set -o pipefail; adb_permissions_remove "$1" "$2" "${3:-1}" ) 2>&1
}
allow() { jq -c '.permissions.allow' "$1/.claude/settings.json" 2>/dev/null; }
rcpt() { printf '%s/.claude/.adb-permissions-owned' "$1"; }
rows() { grep -c "^$2$(printf '\t')" "$(rcpt "$1")" 2>/dev/null || true; }
disp() { ( . "$PL"; adb_permissions_disposition "$(rcpt "$1")" ); }

SHIP="$( . "$PL"; adb_permissions_entries "$PAYLOAD" )" || SHIP='[]'
NSHIP="$(printf '%s' "$SHIP" | jq 'length')"

# ====================================== 1. the payload ===========================================
[ "$NSHIP" -gt 0 ] && ok || bad "the shipped payload must parse as a non-empty allowlist"
eq "$( . "$PL"; adb_permissions_floor )" "2.1.0" "the floor is the release that added wildcard Bash rules"

# Every entry, pinned by name: removing one the workflows spell, or adding one, is a change this
# list has to be edited to allow.
WANT_PLAIN='Bash(agent-init)
Bash(baseline adopt status *)
Bash(baseline permissions *)
Bash(baseline repo status *)
Bash(baseline update --check)
Bash(gh auth status)
Bash(gh issue create *)
Bash(gh issue edit *)
Bash(gh issue list *)
Bash(gh issue view *)
Bash(gh label create *)
Bash(gh label list *)
Bash(gh pr checks *)
Bash(gh pr create *)
Bash(gh pr diff *)
Bash(gh pr edit *)
Bash(gh pr list *)
Bash(gh pr view *)
Bash(gh release list *)
Bash(gh release view *)
Bash(gh repo view *)
Bash(gh run list *)
Bash(gh run view *)
Bash(gh workflow run *)
Bash(git add *)
Bash(git commit -m *)
Bash(git fetch *)
Bash(git merge --ff-only *)
Bash(git switch -c *)
Bash(jq *)'
eq "$(printf '%s' "$SHIP" | jq -r '.[]' | LC_ALL=C sort)" "$WANT_PLAIN" "the shipped entries are exactly the pinned list"

# No entry approves a script by path: whether Auto Mode keeps a rule naming an interpreter and a
# fixed script is not established (D155), so none is shipped.
eq "$(printf '%s' "$SHIP" | jq -r '[.[] | select(test("/|\\.sh|\\$"))] | length')" "0" "no shipped entry names a path, a script or a variable"

# Shape: a wildcard only as a final ` *`, and never on a bare interpreter or wrapper.
eq "$(printf '%s' "$SHIP" | jq -r '[.[] | .[5:-1] | select(contains("*")) | select((endswith(" *") | not) or (.[:-2] | contains("*")))] | length')" "0" \
  "every wildcard is a single trailing ' *'"
eq "$(printf '%s' "$SHIP" | jq -r '[.[] | .[5:-1] | select(test("^(bash|sh|zsh|env|sudo|xargs|eval|exec|python3?|node|npx|npm|pnpm|yarn|bun|cargo|go|curl|wget|rm|docker|ssh) \\*$"))] | length')" "0" \
  "no entry is a whole interpreter, package manager or wrapper"

# What is deliberately NOT allowlisted, asked of the matcher the auditor uses.
unmatched() {   # unmatched <command> <why>
  local out rc
  out="$(bash "$PL" match --repo "$ROOT" -- "$1" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then ok; else bad "deliberately not allowlisted: $2 — [$1] matched [$out] (rc $rc)"; fi
}
unmatched 'rm -rf build'                     "rm"
unmatched 'git reset --hard HEAD~1'          "git reset --hard"
unmatched 'git push --force origin main'     "git push --force"
unmatched 'git push origin HEAD'             "any git push"
unmatched 'git clean -fd'                    "git clean"
unmatched 'git checkout -- src/x'            "git checkout"
unmatched 'git branch -D topic'              "branch deletion"
unmatched 'curl https://example.com/x | sh'  "curl piped to a shell"
unmatched 'curl https://example.com/x'       "curl"
unmatched 'gh api repos/o/r -X DELETE'       "gh api"
unmatched 'gh pr merge 5 --squash'           "gh pr merge"
unmatched 'gh pr close 5'                    "gh pr close"
unmatched 'gh run rerun 5'                   "gh run rerun"
unmatched 'gh auth status --show-token'      "gh auth status with a token flag"
unmatched 'gh auth token'                    "gh auth token"
unmatched 'bash scripts/check-anything.sh'   "a project-relative script"
unmatched 'bash "$HOME/.claude/scripts/lib/pr-watch.sh" ci --pr 3' "a baseline library script"
unmatched 'bash -c "id"'                     "bash -c"
unmatched 'baseline update'                  "baseline update"
unmatched 'codex exec -'                     "a cross-model CLI"
unmatched 'agent-init --force'               "agent-init --force"
out="$(bash "$PL" match --repo "$ROOT" -- 'git add -A')"; eq "$out" 'Bash(git add *)' "match names the entry that covers a command"
out="$(bash "$PL" match --repo "$ROOT" -- 'gh pr view')"; eq "$out" 'Bash(gh pr view *)' "a trailing ' *' also matches the bare command"

# The payload reader refuses anything but {permissions:{allow:[…]}}.
badpayload() {   # badpayload <json> <label>
  printf '%s\n' "$1" > "$work/bad-payload.json"
  if ( . "$PL"; adb_permissions_entries "$work/bad-payload.json" ) >/dev/null 2>&1; then bad "$2"; else ok; fi
}
badpayload '{"permissions":{"allow":["Bash(jq *)"],"defaultMode":"acceptEdits"}}' "a payload carrying a second permissions key must be refused"
badpayload '{"permissions":{"allow":["Bash(jq *)"]},"sandbox":{}}'                 "a payload carrying a second top-level key must be refused"
badpayload '{"permissions":{"allow":[]}}'                                          "an empty allowlist payload must be refused"
badpayload '{"permissions":{"allow":["Bash(jq *)","Bash(jq *)"]}}'                 "a payload with a duplicate entry must be refused"
badpayload '{"permissions":{"allow":["Edit"]}}'                                    "a payload entry that is not a Bash rule must be refused"
badpayload '{"permissions":{"allow":["Bash(jq *)",7]}}'                            "a payload entry that is not a string must be refused"
badpayload '{"permissions":{"allow":["Bash(jq *)"]}}{"permissions":{"allow":["Bash(rm *)"]}}' "a payload file holding two JSON documents must be refused"

# ====================================== 2. the union =============================================
E3='["Bash(a *)","Bash(b *)","Bash(c *)"]'
R3="$(mkrepo r3 "$E3")"

# A first install appends what is missing, after the operator's own, and touches nothing else.
h="$(mkhome first '{"model":"opus","permissions":{"allow":["Bash(ps:*)","Bash(b *)"],"defaultMode":"auto"}}')"
out="$(apply "$R3" "$h")"; yes $? "a first install succeeds"
eq "$(allow "$h")" '["Bash(ps:*)","Bash(b *)","Bash(a *)","Bash(c *)"]' "a first install appends the missing entries after the operator's own"
eq "$(jq -c 'del(.permissions.allow)' "$h/.claude/settings.json")" '{"model":"opus","permissions":{"defaultMode":"auto"}}' \
  "an install writes nothing but permissions.allow"
eq "$(rows "$h" added)" "2" "an entry already present must not be recorded as ours"
if [ "$(id -u)" -ne 0 ]; then
  hm="$(mkhome backup-mode '{"permissions":{"allow":[]},"env":{"K":"v"}}')"; chmod 600 "$hm/.claude/settings.json"
  apply "$R3" "$hm" >/dev/null
  eq "$( . "$PL"; adb_file_mode "$hm/backup$hm/.claude/settings.json" )" "600" "the backup of a 0600 settings.json is 0600 too"
  eq "$( . "$PL"; adb_file_mode "$hm/.claude/settings.json" )" "600" "the rewritten settings.json keeps its 0600 mode"
fi
eq "$(disp "$h")" installed "a first install records itself as installed"
has "$out" "2 allow entries added" "the install line counts what it added"
[ -f "$h/backup$h/.claude/settings.json" ] && ok || bad "the original settings.json is backed up before it is rewritten"

# Re-applying changes nothing, byte for byte.
cp "$h/.claude/settings.json" "$work/before.json"
out="$(apply "$R3" "$h")"; yes $? "a second install succeeds"
cmp -s "$h/.claude/settings.json" "$work/before.json" && ok || bad "a second install must leave settings.json byte-identical"
has "$out" "current — nothing to add" "a second install says there was nothing to add"

# Uninstall takes back exactly what it added.
out="$(remove "$R3" "$h")"; yes $? "uninstall succeeds"
eq "$(allow "$h")" '["Bash(ps:*)","Bash(b *)"]' "uninstall must leave every entry it did not add"
[ ! -e "$(rcpt "$h")" ] && ok || bad "uninstall deletes the allowlist record"

# By-hand removal is a decision: not rewritten, and an entry put back by hand is the operator's.
h="$(mkhome declined '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
jq '.permissions.allow -= ["Bash(b *)"]' "$h/.claude/settings.json" > "$work/t.json" && mv "$work/t.json" "$h/.claude/settings.json"
out="$(apply "$R3" "$h")"; yes $? "an install over a hand-removed entry succeeds"
eq "$(allow "$h")" '["Bash(a *)","Bash(c *)"]' "an entry the operator removed by hand must not be written again"
eq "$(rows "$h" declined)" "1" "the hand-removed entry is recorded as declined"
has "$out" "Bash(b *)" "the install names the entry it left out"
jq '.permissions.allow += ["Bash(b *)"]' "$h/.claude/settings.json" > "$work/t.json" && mv "$work/t.json" "$h/.claude/settings.json"
apply "$R3" "$h" >/dev/null
eq "$(rows "$h" declined)" "0" "an entry put back by hand is no longer declined"
remove "$R3" "$h" >/dev/null
eq "$(allow "$h")" '["Bash(b *)"]' "an entry the operator put back by hand survives uninstall"

# Retirement: a recorded entry the payload stops shipping is removed; the operator's stay.
h="$(mkhome retire '{"permissions":{"allow":["Bash(mine *)"]}}')"
apply "$R3" "$h" >/dev/null
R2="$(mkrepo r2 '["Bash(a *)","Bash(d *)"]')"
out="$(apply "$R2" "$h")"; yes $? "an install from a changed payload succeeds"
eq "$(allow "$h")" '["Bash(mine *)","Bash(a *)","Bash(d *)"]' "a recorded entry the payload no longer ships must be retired"
has "$out" "2 retired" "the install line counts what it retired"
eq "$(rows "$h" added)" "2" "the record lists only what is still shipped and ours"

# Containers: created ones go when empty; the operator's stay.
h="$(mkhome fresh)"
apply "$R3" "$h" >/dev/null
eq "$(jq -c . "$h/.claude/settings.json")" '{"permissions":{"allow":["Bash(a *)","Bash(b *)","Bash(c *)"]}}' "an install creates settings.json when there is none"
remove "$R3" "$h" >/dev/null
eq "$(jq -c . "$h/.claude/settings.json")" '{}' "uninstall removes the permissions object it created"
h="$(mkhome own-container '{"permissions":{}}')"
apply "$R3" "$h" >/dev/null; remove "$R3" "$h" >/dev/null
eq "$(jq -c . "$h/.claude/settings.json")" '{"permissions":{}}' "uninstall keeps a permissions object the operator already had"
h="$(mkhome grew '{}')"
apply "$R3" "$h" >/dev/null
jq '.permissions.allow += ["Bash(mine *)"]' "$h/.claude/settings.json" > "$work/t.json" && mv "$work/t.json" "$h/.claude/settings.json"
remove "$R3" "$h" >/dev/null
eq "$(allow "$h")" '["Bash(mine *)"]' "a created allow list the operator added to is kept"

# Nothing to record still records: every entry already there, under pipefail.
h="$(mkhome all-theirs '{"permissions":{"allow":["Bash(a *)","Bash(b *)","Bash(c *)"]}}')"
out="$(apply "$R3" "$h")"; yes $? "an install with nothing to add succeeds under pipefail"
eq "$(disp "$h")" installed "an install with nothing to add still records itself"
eq "$(rows "$h" added)" "0" "an install that added nothing records no entry as ours"
remove "$R3" "$h" >/dev/null
eq "$(allow "$h")" '["Bash(a *)","Bash(b *)","Bash(c *)"]' "uninstall removes nothing from a list that was all the operator's"

# Shapes an entry cannot be appended to refuse, and are recorded.
blocked() {   # blocked <name> <settings-json> <label>
  local h; h="$(mkhome "$1" "$2")"
  cp "$h/.claude/settings.json" "$work/blocked-before.json"
  apply "$R3" "$h" >/dev/null; local rc=$?
  if [ "$rc" -eq 0 ] && cmp -s "$h/.claude/settings.json" "$work/blocked-before.json" && [ "$(disp "$h")" = skipped-blocked ]; then ok
  else bad "$3 (rc $rc, disposition $(disp "$h"))"; fi
}
blocked blk-allow '{"permissions":{"allow":"Bash(x)"}}' "a permissions.allow that is not an array must block the install"
blocked blk-perm  '{"permissions":"nope"}'              "a permissions that is not an object must block the install"
blocked blk-root  '[1,2]'                               "a settings.json that is not an object must block the install"
h="$(mkhome invalid '{ not json')"
apply "$R3" "$h" >/dev/null; no $? "a settings.json that is not valid JSON fails the install"
eq "$(cat "$h/.claude/settings.json")" '{ not json' "an invalid settings.json is left exactly as it was"
[ ! -e "$(rcpt "$h")" ] && ok || bad "an install that could not read settings.json records nothing"

# The opt-out: recorded without writing, honoured when recorded, and it keeps earlier ownership.
h="$(mkhome optout '{"permissions":{"allow":["Bash(ps:*)"]}}')"
out="$(apply "$R3" "$h" 1)"; yes $? "--no-permissions succeeds"
eq "$(allow "$h")" '["Bash(ps:*)"]' "--no-permissions writes no entry"
eq "$(disp "$h")" skipped-optout "--no-permissions is recorded"
apply "$R3" "$h" 0 1 >/dev/null
eq "$(allow "$h")" '["Bash(ps:*)"]' "a recorded --no-permissions must be honoured by --optout-if-recorded"
apply "$R3" "$h" >/dev/null
eq "$(allow "$h" | jq 'length')" "4" "a plain install after an opt-out applies the allowlist"
apply "$R3" "$h" 1 >/dev/null
eq "$(rows "$h" added)" "3" "an opt-out keeps the record of what an earlier install added"
remove "$R3" "$h" >/dev/null
eq "$(allow "$h")" '["Bash(ps:*)"]' "uninstall after an opt-out still removes what the earlier install added"

# The version probe: below the floor and unprobeable both write nothing and say why.
h="$(mkhome below '{"permissions":{"allow":[]}}')"
stub "2.0.9 (Claude Code)"
out="$(apply "$R3" "$h")"; yes $? "a below-floor skip is not a failure"
eq "$(allow "$h")" '[]' "below the floor no allow entry is written"
eq "$(disp "$h")" skipped-below-floor "a below-floor skip is recorded as one"
stub "not a version"
h="$(mkhome unprobeable '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
eq "$(allow "$h")" '[]' "an unprobeable CLI writes no allow entry"
eq "$(disp "$h")" skipped-unprobeable "an unprobeable skip is recorded as one"
stub "2.1.300 (Claude Code)"
apply "$R3" "$h" >/dev/null
eq "$(allow "$h" | jq 'length')" "3" "a skip is retried once the CLI clears the floor"

# The record is read whole or not at all.
h="$(mkhome damaged '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
printf 'surprise\n' >> "$(rcpt "$h")"
jq '.permissions.allow = []' "$h/.claude/settings.json" > "$work/t.json" && mv "$work/t.json" "$h/.claude/settings.json"
apply "$R3" "$h" >/dev/null; rc=$?
if [ "$rc" -ne 0 ] && [ "$(allow "$h")" = '[]' ]; then ok; else bad "a receipt with an unrecognised line must refuse the install"; fi
remove "$R3" "$h" >/dev/null; no $? "a receipt with an unrecognised line refuses the uninstall too"
h="$(mkhome contradict '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
printf 'declined\t"Bash(a *)"\n' >> "$(rcpt "$h")"
apply "$R3" "$h" >/dev/null; no $? "an entry recorded both added and declined refuses the install"
h="$(mkhome rcpt-dir '{"permissions":{"allow":[]}}')"
mkdir -p "$(rcpt "$h")"
apply "$R3" "$h" >/dev/null; no $? "a receipt path that is a directory refuses the install"
eq "$(allow "$h")" '[]' "…and nothing is written beside a record that cannot be read"
# …on the opt-out path too: a row nobody could read is not carried into the next record.
h="$(mkhome damaged-optout '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
printf 'surprise\n' >> "$(rcpt "$h")"   # a line the row-copying skip path would drop without a word
cp "$(rcpt "$h")" "$work/damaged-before.rcpt"
apply "$R3" "$h" 1 >/dev/null; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$(rcpt "$h")" "$work/damaged-before.rcpt"; then ok
else bad "an opt-out over a record that does not parse must refuse and leave the record as it was (rc $rc)"; fi
h="$(mkhome nodisp '{"permissions":{"allow":[]}}')"
printf 'added\t"Bash(a *)"\n' > "$(rcpt "$h")"
apply "$R3" "$h" >/dev/null; no $? "a receipt with rows and no disposition refuses the install"
# A record short of what it says it holds is damaged, not smaller.
badrcpt() {   # badrcpt <name> <sed-script> <label>: install, damage the record, expect a refusal and an untouched list
  local h; h="$(mkhome "$1" '{"permissions":{"allow":[]}}')"
  apply "$R3" "$h" >/dev/null
  sed "$2" "$(rcpt "$h")" > "$work/t.rcpt" && mv "$work/t.rcpt" "$(rcpt "$h")"
  cp "$h/.claude/settings.json" "$work/badrcpt-before.json"
  apply "$R3" "$h" >/dev/null; local rc=$?
  if [ "$rc" -ne 0 ] && cmp -s "$h/.claude/settings.json" "$work/badrcpt-before.json"; then ok; else bad "$3 (rc $rc)"; fi
}
badrcpt rc-short  '$d'            "a receipt with fewer rows than it counts must refuse the install"
badrcpt rc-noflr  '/^floor /d'    "a receipt missing a metadata line must refuse the install"
badrcpt rc-nosrc  '/^source/d'    "a receipt with no source row must refuse the install"
badrcpt rc-dupver 's/^version .*/&\
version 9.9.9/'                   "a receipt carrying a metadata line twice must refuse the install"
badrcpt rc-digest 's/^payload .*/payload nothex/' "a receipt whose payload digest is not a digest must refuse the install"
h="$(mkhome rc-unterminated '{"permissions":{"allow":[]}}')"
printf 'disposition installed\nadded\t"Bash(a *)"' > "$(rcpt "$h")"
apply "$R3" "$h" >/dev/null; no $? "a truncated receipt with no final newline refuses the install"
eq "$(allow "$h")" '[]' "…and nothing is written over it"

# A receipt that will not publish takes the entries back out.
failing_receipt() {   # failing_receipt <repo> <home>: apply with the receipt publication forced to fail
  ( export HOME="$2"; PATH="$STUB:$PATH"; . "$PL"; set -o pipefail
    eval "$(declare -f adb_publish_json | sed '1s/.*/_real_publish_json ()/')"
    adb_publish_json() { case "$2" in */.adb-permissions-owned) rm -f "$1"; return 1 ;; esac; _real_publish_json "$@"; }
    adb_permissions_apply "$1" "$2" "$2/backup" 0 0 ) 2>&1
}
h="$(mkhome rollback '{"permissions":{"allow":["Bash(ps:*)"]},"env":{"K":"v"}}')"
cp "$h/.claude/settings.json" "$work/pre.json"
out="$(failing_receipt "$R3" "$h")"; no $? "an install whose receipt cannot be written fails"
cmp -s "$h/.claude/settings.json" "$work/pre.json" && ok || bad "a receipt that will not publish must put settings.json back byte for byte"
h="$(mkhome rollback-absent)"
failing_receipt "$R3" "$h" >/dev/null
[ ! -e "$h/.claude/settings.json" ] && ok || bad "a receipt that will not publish must remove a settings.json this run created"
h="$(mkhome rollback-link)"; mkdir -p "$h/real"
printf '{"model":"opus"}\n' > "$h/real/settings.json"; ln -s "$h/real/settings.json" "$h/.claude/settings.json"
failing_receipt "$R3" "$h" >/dev/null
if [ -L "$h/.claude/settings.json" ] && [ "$(readlink "$h/.claude/settings.json")" = "$h/real/settings.json" ] \
   && [ "$(cat "$h/real/settings.json")" = '{"model":"opus"}' ]; then ok
else bad "a receipt that will not publish must leave settings.json the symlink it was"; fi
if [ "$(id -u)" -ne 0 ]; then
  h="$(mkhome created-mode)"
  ( umask 022; apply "$R3" "$h" >/dev/null )
  eq "$( . "$PL"; adb_file_mode "$h/.claude/settings.json" )" "600" "a settings.json this install creates is owner-only"
  # The original's mode cannot be read: refuse, rather than publish at whatever the stage has.
  h="$(mkhome strict-mode '{"permissions":{"allow":[]}}')"; cp "$h/.claude/settings.json" "$work/strict-before.json"
  ( export HOME="$h"; PATH="$STUB:$PATH"; . "$PL"; set -o pipefail
    adb_file_mode() { return 1; }
    adb_permissions_apply "$R3" "$h" "$h/backup" 0 0 ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ] && cmp -s "$h/.claude/settings.json" "$work/strict-before.json" && [ ! -e "$(rcpt "$h")" ]; then ok
  else bad "a settings.json whose mode cannot be read is not rewritten (rc $rc)"; fi
fi
h="$(mkhome rollback-empty)"; : > "$h/.claude/settings.json"
failing_receipt "$R3" "$h" >/dev/null
if [ -f "$h/.claude/settings.json" ] && [ ! -s "$h/.claude/settings.json" ]; then ok
else bad "a receipt that will not publish must leave an empty settings.json in place"; fi

# A record its own reader would refuse is never published, and then nothing else is written.
RN="$(mkrepo "r-new
line" "$E3")"
h="$(mkhome newline-clone '{"permissions":{"allow":["Bash(ps:*)"]}}')"; cp "$h/.claude/settings.json" "$work/nl-before.json"
apply "$RN" "$h" >/dev/null; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$h/.claude/settings.json" "$work/nl-before.json" && [ ! -e "$(rcpt "$h")" ]; then ok
else bad "a clone path holding a newline refuses the install before anything is written (rc $rc)"; fi
RH="$(mkrepo "r-hash
#suffix" "$E3")"
h="$(mkhome hash-clone '{"permissions":{"allow":[]}}')"; cp "$h/.claude/settings.json" "$work/hc-before.json"
apply "$RH" "$h" >/dev/null; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$h/.claude/settings.json" "$work/hc-before.json" && [ ! -e "$(rcpt "$h")" ]; then ok
else bad "a record that would read back naming another clone is not published (rc $rc)"; fi
# An interrupt inside the transaction is held until both writes are done, and leaves no stage behind.
h="$(mkhome interrupted '{"permissions":{"allow":[]},"env":{"K":"v"}}')"
( export HOME="$h"; PATH="$STUB:$PATH"; . "$PL"; set -o pipefail
  eval "$(declare -f _adb_perm_publish_settings | sed '1s/.*/_real_publish_settings ()/')"
  _adb_perm_publish_settings() { kill -TERM "$BASHPID"; _real_publish_settings "$@"; }
  adb_permissions_apply "$R3" "$h" "$h/backup" 0 0 ) >/dev/null 2>&1; rc=$?
left="$(find "$h/.claude" -name '*.adb.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rc" -eq 143 ] && [ "$left" = 0 ] && [ "$(allow "$h" | jq 'length')" = 3 ] && [ "$(rows "$h" added)" = 3 ]; then ok
else bad "an interrupt during the transaction leaves no staged copy of settings.json behind (rc $rc, $left left)"; fi
h="$(mkhome multidoc)"; printf '{"permissions":{"allow":[]}}\n{}\n' > "$h/.claude/settings.json"; cp "$h/.claude/settings.json" "$work/md-before.json"
apply "$R3" "$h" >/dev/null; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$h/.claude/settings.json" "$work/md-before.json"; then ok
else bad "a settings.json holding two JSON documents is not written to (rc $rc)"; fi

# Whose record is it?
h="$(mkhome foreign '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
out="$(remove "$R2" "$h")"; yes $? "an uninstall from another clone is not a failure"
if [ "$(allow "$h" | jq 'length')" = 3 ] && [ -f "$(rcpt "$h")" ]; then ok; else bad "a record naming another clone must be left alone"; fi
has "$out" "$R3" "…and the uninstall names the clone to run it from"
h="$(mkhome gone-settings '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null; rm -f "$h/.claude/settings.json"
remove "$R3" "$h" >/dev/null; yes $? "an uninstall with no settings.json succeeds"
[ ! -e "$(rcpt "$h")" ] && ok || bad "…and deletes the record of entries that cannot exist"
h="$(mkhome never)"
remove "$R3" "$h" >/dev/null; yes $? "an uninstall with no record is a no-op"
# A record that cannot be unlinked is emptied instead. Needs a directory the runner cannot write
# to, which does not exist for root.
if [ "$(id -u)" -ne 0 ]; then
  h="$(mkhome stuck-record '{"permissions":{"allow":[]}}')"
  apply "$R3" "$h" >/dev/null
  jq '.permissions.allow = []' "$h/.claude/settings.json" > "$work/t.json" && mv "$work/t.json" "$h/.claude/settings.json"
  chmod 555 "$h/.claude"
  remove "$R3" "$h" >/dev/null; rc=$?
  chmod 755 "$h/.claude"
  if [ "$rc" -eq 0 ] && [ "$(disp "$h")" = none ]; then ok
  else bad "a record that cannot be deleted at uninstall must be emptied, so a later install does not read its entries as declined (rc $rc)"; fi
fi

# Currency.
pending() {   # pending <repo> <home> -> status of adb_permissions_pending, with the install owned
  ( export HOME="$2"; PATH="$STUB:$PATH"; . "$PL"; adb_agent_ours() { return 0; }; adb_permissions_pending "$1" "$2" )
}
# The payload is changed IN PLACE: a different clone path would be pending for another reason.
RP="$(mkrepo rp "$E3")"
repay() { jq -n --argjson a "$1" '{permissions: {allow: $a}}' > "$RP/agents/claude/settings.permissions.json"; }
h="$(mkhome pend '{"permissions":{"allow":[]}}')"
pending "$RP" "$h"; eq "$?" "0" "no record and a usable CLI is pending"
apply "$RP" "$h" >/dev/null
pending "$RP" "$h"; eq "$?" "1" "an applied allowlist is not pending"
repay '["Bash(a *)","Bash(d *)"]'
pending "$RP" "$h"; eq "$?" "0" "a changed payload is pending"
apply "$RP" "$h" 1 >/dev/null
repay "$E3"
pending "$RP" "$h"; eq "$?" "1" "an opt-out is never pending"
h="$(mkhome pend-blocked '{"permissions":"x"}')"
apply "$RP" "$h" >/dev/null
pending "$RP" "$h"; eq "$?" "1" "a refusal is not retried while the payload is unchanged"
repay '["Bash(a *)","Bash(d *)"]'
pending "$RP" "$h"; eq "$?" "0" "a refusal is retried when the payload changes"
repay "$E3"
h="$(mkhome pend-below '{"permissions":{"allow":[]}}')"
stub "2.0.9 (Claude Code)"; apply "$R3" "$h" >/dev/null
pending "$R3" "$h"; eq "$?" "1" "a below-floor skip is not pending while the CLI is still below"
stub "2.1.300 (Claude Code)"
pending "$R3" "$h"; eq "$?" "0" "a below-floor skip is pending once the CLI clears the floor"
h="$(mkhome pend-foreign '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null
sed "s|^source$(printf '\t').*|source$(printf '\t')/some/other/clone|" "$(rcpt "$h")" > "$work/t.rcpt" && mv "$work/t.rcpt" "$(rcpt "$h")"
pending "$R3" "$h"; eq "$?" "0" "a record naming another clone is pending"
apply "$R3" "$h" >/dev/null
pending "$R3" "$h"; eq "$?" "1" "…and one install makes it this clone's and current"
h="$(mkhome pend-damaged '{"permissions":{"allow":[]}}')"
printf 'nonsense\n' > "$(rcpt "$h")"
pending "$R3" "$h"; eq "$?" "21" "a damaged record is neither pending nor current"
h="$(mkhome pend-extra-line '{"permissions":{"allow":[]}}')"
apply "$R3" "$h" >/dev/null; printf 'surprise\n' >> "$(rcpt "$h")"
pending "$R3" "$h"; eq "$?" "21" "a current record with an unrecognised line is damaged to the currency check too"
mkdir -p "$work/r-nopayload"
pending "$work/r-nopayload" "$(mkhome pend-nopayload)"; eq "$?" "24" "a clone with no allowlist payload is unanswerable, not current"

# What a self-heal did to the allowlist is read from what changed, not from the record's word.
heal() {   # heal <repo> <home> <allow-before> <receipt-before> -> HOUT, HRC
  HOUT="$( ( export HOME="$2"; . "$PL"; adb_permissions_heal_report "$1" "$2" "$3" "$4" ) 2>&1 )"; HRC=$?
}
sig() { ( . "$PL"; adb_permissions_allow_sig "$1" ); }
rsig() { ( . "$PL"; adb_sha256 "$(rcpt "$1")" 2>/dev/null || printf none ); }
h="$(mkhome heal '{"permissions":{"allow":[]}}')"
a0="$(sig "$h")"; r0="$(rsig "$h")"
apply "$RP" "$h" >/dev/null
heal "$RP" "$h" "$a0" "$r0"; eq "$HRC" "0" "a heal that added entries reports a changed allow list"
has "$HOUT" "was updated" "…and says the list was updated"
a1="$(sig "$h")"; r1="$(rsig "$h")"
heal "$RP" "$h" "$a1" "$r1"; eq "$HRC $HOUT" "1 " "a heal that touched nothing says nothing"
stub "2.1.301 (Claude Code)"; apply "$RP" "$h" >/dev/null; stub "2.1.300 (Claude Code)"
heal "$RP" "$h" "$a1" "$r1"; eq "$HRC" "1" "a heal that only rewrote the record did not change the allow list"
has "$HOUT" "refreshed the command-allowlist record" "…and is reported as a refreshed record, not a repair"
h="$(mkhome heal-blocked '{"permissions":"x"}')"
a0="$(sig "$h")"; r0="$(rsig "$h")"
apply "$RP" "$h" >/dev/null
heal "$RP" "$h" "$a0" "$r0"; eq "$HRC" "1" "a heal that was refused did not change the allow list"
has "$HOUT" "NOT applied (skipped-blocked)" "…and the refusal is reported with its disposition"
BL="$(cat "$ROOT/bin/baseline")"
eq "$(printf '%s\n' "$BL" | grep -c 'adb_permissions_heal_report "\$SRC" "\$HOME"')" "2" "bin/baseline reports the allowlist outcome on both healing paths"

# ====================================== 3. the audit =============================================
audit() {   # audit <repo> <home> <project|""> [managed] -> AOUT, ARC
  AOUT="$(HOME="$2" PATH="$STUB:$PATH" bash "$PL" audit --repo "$1" --home "$2" --project "$3" --managed "${4:-$work/no-managed.json}" 2>&1)"; ARC=$?
}
level_of() { printf '%s\n' "$AOUT" | awk -F'\t' -v k="$1" '$1 == k { print $2 }' | LC_ALL=C sort -u | tr '\n' ' '; }
summary() { printf '%s\n' "$AOUT" | awk -F'\t' '$1 == "summary" { print $2 " " $4 }'; }
clean_settings() { jq -cn --argjson a "$1" --arg m "${2:-auto}" '{permissions: {allow: $a, defaultMode: $m}}'; }

# A clean project is clean, and says how much it looked at.
h="$(mkhome a-clean "$(clean_settings "$E3")")"
audit "$R3" "$h" ""
eq "$ARC" "0" "a home holding every shipped entry in auto mode audits clean"
has "$AOUT" "ASSUMED: auto mode is available to the session" "an auto verdict states the availability it assumes"
eq "$(summary)" "clean entries=3/3 scopes=2/2 rules=0 findings=0 unevaluated=0" "a clean audit reports its coverage"
audit "$ROOT" "$(mkhome a-clean-real "$(clean_settings "$SHIP")")" ""
eq "$ARC" "0" "the real payload audits clean when every entry is installed"

# A shipped entry in no allow list.
h="$(mkhome a-missing "$(clean_settings '["Bash(a *)","Bash(c *)"]')")"
audit "$R3" "$h" ""
eq "$ARC" "10" "a shipped entry in no allow list must make the audit red"
has "$AOUT" "Bash(b *) is in no allow list" "the audit names the missing entry"
eq "$(level_of entry)" "classifier " "in auto mode a missing entry is a classifier finding"
h="$(mkhome a-missing-accept "$(clean_settings '["Bash(a *)","Bash(c *)"]' acceptEdits)")"
audit "$R3" "$h" ""
eq "$(level_of entry)" "prompt " "outside auto mode a missing entry prompts"

# A broader allow rule of the operator's own holds a shipped entry; a narrower or unrelated one does not.
RB="$(mkrepo rb '["Bash(git add *)","Bash(gh auth status)","Bash(jq *)"]')"
audit "$RB" "$(mkhome a-broad-allow "$(clean_settings '["Bash(git:*)","Bash(gh auth *)","Bash(jq *)"]')")" ""
eq "$ARC" "0" "an entry held by a broader allow rule is not a finding"
audit "$RB" "$(mkhome a-narrow-allow "$(clean_settings '["Bash(git add -A)","Bash(gh auth status)","Bash(jq *)"]')")" ""
eq "$ARC" "10" "a narrower allow rule does not hold a shipped entry"
audit "$RB" "$(mkhome a-lookalike "$(clean_settings '["Bash(git addendum *)","Bash(gh auth status)","Bash(jq *)"]')")" ""
eq "$ARC" "10" "an allow rule for another word with the same prefix does not hold a shipped entry"
audit "$RB" "$(mkhome a-midglob "$(clean_settings '["Bash(git * main)","Bash(gh auth status)","Bash(jq *)"]')")" ""
eq "$ARC" "10" "an allow rule with a wildcard before its last word does not hold a shipped entry"

# deny and ask rules, in every spelling that can match.
ruled() {   # ruled <name> <deny|ask> <rule> -> audits a clean home plus that rule
  local h; h="$(mkhome "$1" "$(clean_settings "$E3" | jq -c --arg k "$2" --arg r "$3" '.permissions[$k] = [$r]')")"
  audit "$R3" "$h" ""
}
ruled a-deny deny 'Bash(a *)'
eq "$ARC" "10" "a deny rule that can match a shipped entry must make the audit red"
has "$AOUT" "deny rule Bash(a *) can match 1 shipped entry: Bash(a *)" "the audit names the deny rule and what it hits"
eq "$(level_of rule)" "blocked " "a matching deny rule is a blocked finding"
has "$(summary)" "entries=2/3" "an entry a deny rule can match is not counted as covered"
ruled a-ask ask 'Bash(b *)'
eq "$ARC" "10" "an ask rule that can match a shipped entry must make the audit red"
has "$AOUT" "$(printf 'rule\tprompt\t~/.claude/settings.json\task rule Bash(b *) can match 1 shipped entry: Bash(b *)')" "an ask rule that can match a shipped entry must be named"
eq "$(level_of rule)" "prompt " "a matching ask rule is a prompt finding"
ruled a-legacy ask 'Bash(b:*)'
has "$AOUT" "ask rule Bash(b:*) can match 1 shipped entry: Bash(b *)" "an ask rule in the legacy :* spelling must be named"
ruled a-broad deny 'Bash'
has "$AOUT" "can match 3 shipped entries" "a whole-tool deny matches every shipped entry"
ruled a-prefix ask 'Bash(b x*)'
eq "$ARC" "10" "a narrower ask rule under a shipped prefix is a prompt source"
ruled a-exact deny 'Bash(c)'
has "$AOUT" "deny rule Bash(c) can match 1 shipped entry: Bash(c *)" "an exact deny of the bare command must be named"
ruled a-unrelated deny 'Bash(rm *)'
eq "$ARC" "0" "a deny rule that matches no shipped entry is not a finding"
has "$(summary)" "rules=1" "…and it is still counted as evaluated"
ruled a-other-tool deny 'Edit(.env)'
eq "$ARC" "0" "a path-scoped rule on another tool is not a finding"
has "$AOUT" "deny rule Edit(.env) matches no shipped command" "a rule on another tool is listed, not dropped"
# Shadowing is containment: two rules that both reach one shipped entry need not match the same commands.
hs="$(mkhome a-not-shadowed "$(clean_settings "$E3" | jq -c '.permissions.deny = ["Bash(b -u *)"] | .permissions.ask = ["Bash(b -A *)"]')")"
audit "$R3" "$hs" ""
eq "$(printf '%s\n' "$AOUT" | awk -F'\t' '$1 == "rule" && $4 ~ /^ask rule/ { print $2 }')" "prompt" "an ask rule beside a deny rule for other commands still prompts"
ruled a-tool-case deny 'bash(a *)'
eq "$ARC" "10" "a rule whose tool name is spelled in another case is not missed"
ruled a-spec-space deny 'Bash( a *)'
eq "$ARC" "11" "a Bash rule whose specifier has outer whitespace is NOT EVALUATED"
hs="$(mkhome a-shadowed "$(clean_settings "$E3" | jq -c '.permissions.deny = ["Bash(b *)"] | .permissions.ask = ["Bash(b x*)"]')")"
audit "$R3" "$hs" ""
eq "$(printf '%s\n' "$AOUT" | awk -F'\t' '$1 == "rule" && $4 ~ /^ask rule/ { print $2 }')" "info" "an ask rule a deny rule shadows is not reported as a prompt"
has "$AOUT" "deny is evaluated first" "…and the audit says why"
ruled a-whole-edit ask 'Edit'
eq "$ARC" "10" "an ask rule on the whole Edit tool is a prompt source"

# Rule forms the vendor documents beyond `Bash(<command>)`.
ruled a-glob-all deny '*'
eq "$ARC" "10" "a deny rule that globs the tool name is named"
has "$AOUT" "can match 3 shipped entries" "…and a tool glob with no specifier matches every shipped entry"
ruled a-glob-bash ask 'Bash*'
eq "$ARC" "10" "an ask rule whose tool glob matches Bash is a prompt source"
ruled a-glob-spec deny 'B*(a *)'
has "$AOUT" "deny rule B*(a *) can match 1 shipped entry" "a tool glob with a specifier is matched by its specifier"
ruled a-glob-mcp deny 'mcp__*'
eq "$ARC" "0" "a tool glob that does not match Bash is not a finding"
ruled a-param ask 'Bash(run_in_background:true)'
eq "$ARC" "11" "a parameter rule on Bash is NOT EVALUATED"
ruled a-param-command deny 'Bash(command:a x)'
eq "$ARC" "0" "a rule naming the command parameter is ignored by the CLI, so it is not a finding"
has "$AOUT" "which the CLI ignores" "…and the audit says so"
ruled a-unparsed deny 'Bash(a'
eq "$ARC" "11" "a rule that is not rule-shaped is NOT EVALUATED"

# Auto Mode sets arbitrary-execution allow rules aside; other modes keep them.
audit "$R3" "$(mkhome a-blanket-auto "$(clean_settings '["Bash(*)"]')")" ""
eq "$ARC" "10" "in auto mode a blanket Bash allow rule holds no shipped entry"
has "$AOUT" "auto mode sets aside 1 allow rule" "…and the audit names the rule it set aside"
audit "$R3" "$(mkhome a-blanket-accept "$(clean_settings '["Bash"]' acceptEdits)")" ""
eq "$ARC" "0" "outside auto mode a whole-tool allow rule holds every shipped entry"
RI="$(mkrepo ri '["Bash(npm run build)"]')"
audit "$RI" "$(mkhome a-pm-auto "$(clean_settings '["Bash(npm run *)"]')")" ""
eq "$ARC" "10" "in auto mode a wildcarded package-manager run rule holds no shipped entry"
audit "$RI" "$(mkhome a-pm-accept "$(clean_settings '["Bash(npm run *)"]' acceptEdits)")" ""
eq "$ARC" "0" "outside auto mode the same rule holds it"
audit "$R3" "$(mkhome a-glob-allow "$(clean_settings '["B*","*"]')")" ""
eq "$ARC" "10" "an allow rule that globs the tool name approves nothing"

# The starting mode.
moded() {   # moded <name> <mode-json-or-null> -> audits a clean home with that defaultMode
  local h; h="$(mkhome "$1" "$(jq -cn --argjson a "$E3" --argjson m "$2" '{permissions: ({allow: $a} + (if $m == null then {} else {defaultMode: $m} end))}')")"
  audit "$R3" "$h" ""
}
moded m-default '"default"'; eq "$ARC $(level_of mode)" "10 prompt " "defaultMode default is a prompt source"
moded m-manual  '"manual"';  eq "$ARC $(level_of mode)" "10 prompt " "defaultMode manual is default"
moded m-plan    '"plan"';    eq "$ARC $(level_of mode)" "11 unevaluated " "defaultMode plan is NOT EVALUATED"
moded m-dontask '"dontAsk"'; eq "$ARC $(level_of mode)" "10 blocked " "defaultMode dontAsk refuses instead of asking"
moded m-accept  '"acceptEdits"'; eq "$ARC $(level_of mode)" "0 ok " "defaultMode acceptEdits with every entry installed is clean"
moded m-bypass  '"bypassPermissions"'; eq "$ARC $(level_of mode)" "0 info " "bypassPermissions is reported, and is not a prompt source"
hnb="$(mkhome m-bypass-disabled "$(clean_settings "$E3" bypassPermissions | jq -c '.permissions.disableBypassPermissionsMode = "disable"')")"
audit "$R3" "$hnb" ""
eq "$ARC $(level_of mode)" "11 unevaluated " "bypassPermissions under disableBypassPermissionsMode is NOT EVALUATED"
# What a missing entry or an ask rule BECOMES follows the mode it is met in.
miss() {   # miss <name> <mode> [extra-jq] -> audits a home missing Bash(b *) in that mode
  local h; h="$(mkhome "$1" "$(clean_settings '["Bash(a *)","Bash(c *)"]' "$2" | jq -c "${3:-.}")")"
  audit "$R3" "$h" ""
}
miss x-bypass bypassPermissions; eq "$ARC $(level_of entry)" "0 " "in bypassPermissions a missing entry is not a finding"
miss x-dontask dontAsk;          eq "$(level_of entry)" "blocked " "in dontAsk a missing entry is refused, not asked"
miss x-default default;          eq "$(level_of entry)" "prompt " "in default mode a missing entry prompts"
miss x-typo Auto;                eq "$(level_of entry)" "unevaluated " "under an undocumented mode a missing entry is not classified"
hd="$(mkhome x-ask-dontask "$(clean_settings "$E3" dontAsk | jq -c '.permissions.ask = ["Bash(b *)"]')")"
audit "$R3" "$hd" ""
eq "$(level_of rule)" "blocked " "in dontAsk an ask rule is refused, not asked"
stub "2.1.320 (Claude Code)"
miss x-dp default '.permissions.denyInsteadOfPrompting = true'
eq "$(level_of entry)" "blocked " "with denyInsteadOfPrompting a missing entry is refused, not asked"
stub "2.1.300 (Claude Code)"
miss x-dp-old default '.permissions.denyInsteadOfPrompting = true'
eq "$(level_of entry)" "prompt " "denyInsteadOfPrompting is not applied on a CLI that predates it"
has "$AOUT" "needs CLI v2.1.319" "…and the audit says why"
moded m-typo    '"Auto"';    eq "$ARC $(level_of mode)" "11 unevaluated " "an undocumented defaultMode is NOT EVALUATED"
moded m-unset   null;        eq "$ARC $(level_of mode)" "0 ok " "no defaultMode on a CLI with the built-in auto default is auto"
stub "2.1.200 (Claude Code)"
moded m-unset-old null;      eq "$ARC $(level_of mode)" "11 unevaluated " "no defaultMode on an older CLI is NOT EVALUATED"
stub "2.1.300 (Claude Code)"

# Project scopes: narrowing is named with its file; an unhonoured `auto` is not a source.
proj() {   # proj <name> [shared-json] [local-json] -> a project root
  local p="$work/$1"; mkdir -p "$p/.claude"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$p/.claude/settings.json"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$p/.claude/settings.local.json"
  printf '%s' "$p"
}
h="$(mkhome a-proj "$(clean_settings "$E3")")"
audit "$R3" "$h" "$(proj p-mode '{"permissions":{"defaultMode":"default"}}')"
eq "$ARC" "10" "a project defaultMode that narrows the user one must be named"
has "$AOUT" "$(printf 'mode\tprompt\t.claude/settings.json')" "…with the project file as its source"
audit "$R3" "$h" "$(proj p-deny '{"permissions":{"deny":["Bash(a *)"]}}')"
has "$AOUT" "$(printf 'rule\tblocked\t.claude/settings.json')" "a project deny rule over a user allow entry is named with its file"
audit "$R3" "$h" "$(proj p-local '' '{"permissions":{"ask":["Bash(c *)"]}}')"
has "$AOUT" "$(printf 'rule\tprompt\t.claude/settings.local.json')" "a local ask rule is named with its file"
# Two values do not take effect from project or local settings, and each falls somewhere else.
audit "$R3" "$h" "$(proj p-bypass '{"permissions":{"defaultMode":"bypassPermissions"}}')"
eq "$ARC $(level_of mode)" "10 prompt " "a project bypassPermissions starts the session in default mode"
has "$AOUT" "does not take effect from project or local settings" "…and the audit says it did not take effect"
hud="$(mkhome a-user-default "$(clean_settings "$E3" default)")"
audit "$R3" "$hud" "$(proj p-autolocal '' '{"permissions":{"defaultMode":"auto"}}')"
eq "$ARC" "0" "a project defaultMode auto falls to the built-in default, not to the user mode"
has "$AOUT" "$(printf 'mode\tok\t.claude/settings.local.json')" "…and the audit names the file that set it"
stub "2.1.200 (Claude Code)"
audit "$R3" "$hud" "$(proj p-autolocal-old '' '{"permissions":{"defaultMode":"auto"}}')"
eq "$ARC" "11" "…and where the built-in default cannot be established, neither can the mode"
stub "2.1.250 (Claude Code)"
hb="$(mkhome a-proj-bypass-old "$(clean_settings '["Bash(a *)"]' default)")"
audit "$R3" "$hb" "$(proj p-bypass-old '{"permissions":{"defaultMode":"bypassPermissions"}}')"
has "$AOUT" "$(printf 'mode\tinfo\t.claude/settings.json\tbypassPermissions')" "a project bypassPermissions takes effect on a CLI before v2.1.257"
stub "not a version"
audit "$R3" "$hb" "$(proj p-bypass-unknown '{"permissions":{"defaultMode":"bypassPermissions"}}')"
eq "$ARC" "11" "a project bypassPermissions is NOT EVALUATED when the CLI version cannot be read"
stub "2.1.300 (Claude Code)"
audit "$R3" "$h" "$(proj p-noauto '{"disableAutoMode":"disable"}')"
eq "$ARC $(level_of mode)" "10 prompt " "disableAutoMode in any scope turns an auto start into a prompting one"
audit "$R3" "$h" "$(proj p-allow '{"permissions":{"allow":["Bash(z *)"]}}')"
eq "$ARC" "0" "a project allow list does not narrow the user one"
has "$AOUT" "only once the workspace trust dialog has been accepted" "a project allow rule is reported as conditional on workspace trust"
h2="$(mkhome a-proj-split "$(clean_settings '["Bash(a *)"]')")"
audit "$R3" "$h2" "$(proj p-union '{"permissions":{"allow":["Bash(b *)"]}}' '{"permissions":{"allow":["Bash(c *)"]}}')"
eq "$ARC" "0" "allow lists merge across scopes"

# Managed settings, and the keys that make an allowlist inert.
printf '%s\n' '{"permissions":{"defaultMode":"default"}}' > "$work/managed-mode.json"
audit "$R3" "$h" "" "$work/managed-mode.json"
eq "$ARC" "10" "a managed defaultMode outranks the user one"
printf '%s\n' '{"allowManagedPermissionRulesOnly":true}' > "$work/managed-only.json"
audit "$R3" "$h" "" "$work/managed-only.json"
eq "$ARC" "10" "allowManagedPermissionRulesOnly makes the user allowlist inert"
has "$AOUT" "allowManagedPermissionRulesOnly is set" "…and the audit names it"
h3="$(mkhome a-classify "$(clean_settings "$E3" | jq -c '.autoMode = {classifyAllShell: true}')")"
audit "$R3" "$h3" ""
eq "$ARC" "10" "autoMode.classifyAllShell must be reported as suspending the allowlist"
has "$(summary)" "entries=0/3" "…and no entry counts as covered while it is on"
mkdir -p "$work/mdir/managed-settings.d"; : > "$work/mdir/managed-settings.d/10-x.json"
audit "$R3" "$h" "" "$work/mdir/managed-settings.json"
eq "$ARC" "11" "a managed-settings.d the audit does not read is NOT EVALUATED"

# What could not be read is never clean.
h4="$(mkhome a-invalid '{ not json')"
audit "$R3" "$h4" ""
eq "$ARC" "11" "a settings file that is not valid JSON must be NOT EVALUATED"
has "$AOUT" "$(printf 'scope\tunevaluated\t~/.claude/settings.json')" "…and the audit names the file it could not read"
h4="$(mkhome a-array '[]')"; audit "$R3" "$h4" ""
eq "$ARC" "11" "a settings file that is not an object is NOT EVALUATED"
h4="$(mkhome a-shape '{"permissions":{"allow":"Bash(a *)","defaultMode":"auto"}}')"; audit "$R3" "$h4" ""
eq "$ARC" "11" "a permissions.allow that is not a list of strings is NOT EVALUATED"
h4="$(mkhome a-shape2 "$(clean_settings "$E3" | jq -c '.permissions.deny = [1]')")"; audit "$R3" "$h4" ""
eq "$ARC" "11" "a deny list holding a non-string is NOT EVALUATED"
# A key present with the wrong type is not an absent key, even when another scope supplies coverage.
clean_settings "$E3" > "$work/managed-clean.json"
audit "$R3" "$(mkhome a-perm-false '{"permissions":false}')" "" "$work/managed-clean.json"
eq "$ARC" "11" "a permissions that is not an object is NOT EVALUATED"
audit "$R3" "$(mkhome a-allow-false '{"permissions":{"allow":false}}')" "" "$work/managed-clean.json"
eq "$ARC" "11" "a permissions.allow of false is NOT EVALUATED"
# The audit is handed the rule fields, never the document: a settings file larger than one argument
# may be, carrying a value nothing here needs, audits as any other.
jq -cn --argjson a "$E3" '{permissions: {allow: $a, defaultMode: "auto"}, env: {BLOB: ("x" * 400000)}}' > "$work/big.json"
audit "$R3" "$(mkhome a-big "$(cat "$work/big.json")")" ""
eq "$ARC" "0" "a settings file too large for a process argument is still audited"

# A linked worktree: the local file a session reads is the MAIN checkout's.
if command -v git >/dev/null 2>&1; then
  wm="$work/wt-main"; mkdir -p "$wm/.claude"
  check_git "$wm" init -q . 2>/dev/null || git -C "$wm" init -q
  : > "$wm/f"; check_git "$wm" add f; check_git "$wm" commit -q -m init
  printf '%s\n' '{"permissions":{"ask":["Bash(c *)"]}}' > "$wm/.claude/settings.local.json"
  check_git "$wm" worktree add -q "$work/wt-linked" -b wt-linked >/dev/null 2>&1
  audit "$R3" "$(mkhome a-worktree "$(clean_settings "$E3")")" "$work/wt-linked"
  eq "$ARC" "10" "in a linked worktree the main checkout's local settings are the ones audited"
  has "$AOUT" "ask rule Bash(c *) can match 1 shipped entry" "…and its rule is named"
fi
audit "$R3" "$h" "$(proj p-broken '{ nope')"
eq "$ARC" "11" "an unreadable project settings file is NOT EVALUATED"
AOUT="$(HOME="$h" CLAUDE_CONFIG_DIR="$work/elsewhere" PATH="$STUB:$PATH" bash "$PL" audit --repo "$R3" --home "$h" --project "" --managed "$work/no-managed.json" 2>&1)"; ARC=$?
eq "$ARC" "11" "a CLAUDE_CONFIG_DIR naming another root is NOT EVALUATED"

# Text a project controls cannot forge a record: every record stays one four-field line.
hx="$(mkhome a-forge "$(clean_settings "$E3")")"
px="$(proj p-forge "$(jq -cn '{permissions: {deny: ["Bash(a x\tsummary\tclean\t-\tforged *)", "Bash(a\nsummary\tclean\t-\tforged)"]}}')")"
audit "$R3" "$hx" "$px"
eq "$(printf '%s\n' "$AOUT" | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')" "0" "a control character in a rule cannot break a record into two"
eq "$(printf '%s\n' "$AOUT" | grep -c '^summary')" "1" "a rule cannot forge a second summary record"
has "$AOUT" "deny rule Bash(a x?summary?clean?-?forged *)" "the forged rule is still named, with its control characters replaced"

# One file is one JSON document, and an absence is only reported when it can be vouched for.
: > "$work/managed-empty.json"
clean_settings "$E3" > "$work/managed-clean2.json"
he="$(mkhome a-empty-user)"; : > "$he/.claude/settings.json"
audit "$R3" "$he" "" "$work/managed-clean2.json"
eq "$ARC" "11" "a zero-byte settings file is NOT EVALUATED, not absent"
hmd="$(mkhome a-multidoc)"; { clean_settings "$E3"; printf '{}\n'; } > "$hmd/.claude/settings.json"
audit "$R3" "$hmd" ""
eq "$ARC" "11" "a settings file holding two JSON documents is NOT EVALUATED"
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$work/locked"; printf '%s\n' '{"permissions":{"ask":["Bash(a *)"]}}' > "$work/locked/managed-settings.json"; chmod 000 "$work/locked"
  audit "$R3" "$h" "" "$work/locked/managed-settings.json"; chmod 755 "$work/locked"
  eq "$ARC" "11" "a settings file under a directory that cannot be searched is NOT EVALUATED"
fi
audit "$R3" "$h" "" "$work/no-such-dir/deeper/managed-settings.json"
eq "$ARC" "0" "a settings file whose directory does not exist is absent"
mkdir -p "$work/r-nl
summary	clean	-	forged"
audit "$work/r-nl
summary	clean	-	forged" "$h" ""
eq "$(printf '%s\n' "$AOUT" | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ') $(printf '%s\n' "$AOUT" | grep -c '^summary')" "0 1" "an early failure cannot forge a record either"

# An audit that evaluated nothing prints something a clean run cannot.
mkdir -p "$work/r-none"
audit "$work/r-none" "$h" ""
eq "$ARC" "11" "an audit with no shipped allowlist to evaluate is NOT EVALUATED"
has "$(summary)" "unevaluated entries=0/0" "…and its summary says zero entries were evaluated"
mkdir -p "$work/r-empty/agents/claude"; printf '{"permissions":{"allow":[]}}\n' > "$work/r-empty/agents/claude/settings.permissions.json"
audit "$work/r-empty" "$h" ""
eq "$ARC" "11" "an empty shipped allowlist is NOT EVALUATED, never clean"
if check_mirror_without jq "$work/nojq"; then
  AOUT="$(HOME="$h" PATH="$work/nojq" "$BASH" "$PL" audit --repo "$R3" --home "$h" --project "" --managed "$work/no-managed.json" 2>&1)"; ARC=$?
  eq "$ARC" "11" "an audit without jq is NOT EVALUATED"
fi

# Gates are reported and never move the verdict.
p="$(proj p-gates)"; printf '[gates]\ntest = "npm test"\nlint = "npm run lint && echo ok"\n' > "$p/agents.toml"
hg="$(mkhome a-gates "$(clean_settings '["Bash(a *)","Bash(b *)","Bash(c *)","Bash(npm test)"]')")"
audit "$R3" "$hg" "$p"
eq "$ARC" "0" "gate records never change a clean verdict"
has "$AOUT" "$(printf 'gate\tinfo\ttest\tnpm test — run as written it matches the allow rule Bash(npm test)')" "a gate is reported with the allow rule a direct call matches"
has "$AOUT" "a compound command, matched part by part (not evaluated)" "a compound gate command is not judged as one command"
# The bare-command form belongs to a pattern whose ONLY wildcard is the trailing one.
pg2="$(proj p-gates-bare)"; printf '[gates]\ntest = "x --help"\n' > "$pg2/agents.toml"
# acceptEdits: in auto mode a rule that begins with a wildcard is set aside, and would match nothing either way.
audit "$R3" "$(mkhome a-gates-bare "$(clean_settings '["Bash(a *)","Bash(b *)","Bash(c *)","Bash(* --help *)"]' acceptEdits)")" "$pg2"
has "$AOUT" "x --help — run as written it matches no allow rule" "a pattern with two wildcards does not match its bare form"
pg3="$(proj p-gates-two)"; printf '[gates]\ntest = "x --help y"\n' > "$pg3/agents.toml"
audit "$R3" "$(mkhome a-gates-two "$(clean_settings '["Bash(a *)","Bash(b *)","Bash(c *)","Bash(* --help *)"]' acceptEdits)")" "$pg3"
has "$AOUT" "run as written it matches the allow rule Bash(* --help *)" "…and does match a command that fills both"
if [ "$(id -u)" -ne 0 ]; then
  pg4="$(proj p-gates-unread)"; printf '[gates]\ntest = "npm test"\n' > "$pg4/agents.toml"; chmod 000 "$pg4/agents.toml"
  audit "$R3" "$hg" "$pg4"; chmod 644 "$pg4/agents.toml"
  eq "$ARC" "0" "an undetectable gate set does not change the verdict"
  has "$AOUT" "could not be detected" "…and is still said"
fi
audit "$R3" "$h" ""
has "$AOUT" "no project: only the managed file and user settings were read" "an audit with no project says which scopes it read"

# `missing` lists what a hand merge needs.
out="$(bash "$PL" missing --repo "$R3" --home "$(mkhome miss '{"permissions":{"allow":["Bash(b *)"]}}')")"; yes $? "missing succeeds on a readable home"
eq "$out" "$(printf 'Bash(a *)\nBash(c *)')" "missing prints the shipped entries the user settings lack"
bash "$PL" missing --repo "$R3" --home "$(mkhome miss-bad '{ nope')" >/dev/null 2>&1; eq "$?" "11" "missing refuses a settings file it cannot read"
bash "$PL" nope >/dev/null 2>&1; eq "$?" "2" "an unknown subcommand is usage"

# ================================ 4. wiring: workflow, docs, installer ===========================
WF="$ROOT/base/workflows/adopt.md"
snip="$(check_wf_snippet "$WF" permissions-audit)"
has "$snip" '{{PERMISSIONS_LIB}} audit --repo "$BASELINE" --project "$PROJECT"' "adopt.md runs the audit against the baseline and the project"
has "$snip" 'case "$PERM_RC" in 0|10|11) : ;;' "adopt.md treats clean, findings and not-evaluated as reportable, and anything else as a stop"
if grep -qF 'every `gate` record' "$WF"; then ok; else bad "adopt.md's report keeps the gate records: they are info-level, and the scratch files are swept"; fi
has "$(cat "$ROOT/agents/claude/skills/adopt/SKILL.md")" 'bash "$HOME/.claude/scripts/lib/permissions-lib.sh" audit' "the rendered Claude skill invokes the installed library"
# The docs name every allowlisted command and the boundary. `grep -F` on the file, not `has`: a
# miss must print one line, not the document.
DOC="$ROOT/docs/installation.md"
indoc() { if grep -qF -- "$1" "$DOC"; then ok; else bad "$2"; fi; }
while IFS= read -r e; do
  [ -n "$e" ] || continue
  indoc "\`${e#Bash(}" "docs/installation.md names the allowlisted command: $e"
done <<EOF
$(printf '%s\n' "$WANT_PLAIN" | sed 's/)$//')
EOF
for w in 'git push' 'git reset --hard' 'curl' 'gh api' 'gh pr merge' 'bypassPermissions' '--no-permissions'; do
  indoc "$w" "docs/installation.md states the boundary: $w"
done

# The installer reaches the surface. Skipped in a mutation child, whose copy has no installer.
if [ -z "${CP_MUTATION_CHILD:-}" ]; then
  FH="$(mkhome e2e '{"permissions":{"allow":["Bash(ps:*)"],"defaultMode":"auto"}}')"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/install.sh" --agent claude 2>&1)"; yes $? "install.sh succeeds on a home with an existing allow list"
  eq "$(allow "$FH" | jq 'length')" "$((NSHIP + 1))" "install.sh adds every shipped entry beside the operator's own"
  eq "$(jq -r '.permissions.defaultMode' "$FH/.claude/settings.json")" "auto" "install.sh leaves defaultMode as it found it"
  has "$out" "allow entries added to ~/.claude/settings.json" "install.sh reports the allowlist step"
  AOUT="$(HOME="$FH" PATH="$STUB:$PATH" bash "$ROOT/bin/baseline" permissions audit --project "" --managed "$work/no-managed.json" 2>&1)"; ARC=$?
  eq "$ARC" "0" "baseline permissions audit is clean after an install"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/uninstall.sh" --agent claude 2>&1)"; yes $? "uninstall.sh succeeds"
  eq "$(allow "$FH")" '["Bash(ps:*)"]' "uninstall.sh removes the entries the install added and keeps the operator's"
  [ ! -e "$(rcpt "$FH")" ] && ok || bad "uninstall.sh deletes the allowlist record"
  FH="$(mkhome e2e-optout '{"permissions":{"allow":["Bash(ps:*)"]}}')"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/install.sh" --agent claude --no-permissions 2>&1)"; yes $? "install.sh --no-permissions succeeds"
  eq "$(allow "$FH")" '["Bash(ps:*)"]' "install.sh --no-permissions writes no allow entry"
  [ "$(jq -r '.sandbox.enabled' "$FH/.claude/settings.json")" = true ] && ok || bad "--no-permissions leaves the sandbox fragment to apply"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/install.sh" --agent claude --optout-if-recorded 2>&1)"
  eq "$(allow "$FH")" '["Bash(ps:*)"]' "a self-heal keeps honouring a recorded --no-permissions"
  # A hook wiring that FAILED puts settings.json back, and nothing more is written over it.
  FH="$(mkhome e2e-hooks-failed)"; : > "$FH/.claude/settings.json"
  mkdir "$( . "$PL"; adb_claude_hooks_receipt "$FH" )"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/install.sh" --agent claude --no-sandbox 2>&1)"; no $? "an install whose hook wiring fails is a failure"
  if [ -f "$FH/.claude/settings.json" ] && [ ! -s "$FH/.claude/settings.json" ]; then ok
  else bad "the allowlist is not written after a hook wiring that failed"; fi
  [ ! -e "$(rcpt "$FH")" ] && ok || bad "…and no allowlist record is written either"
  # A sandbox step that FAILED leaves settings.json to whoever repairs it: nothing more is written.
  FH="$(mkhome e2e-fragment-failed '{"permissions":{"allow":["Bash(ps:*)"]}}')"
  mkdir -p "$FH/.claude/.adb-settings-owned"
  out="$(HOME="$FH" PATH="$STUB:$PATH" "$ROOT/install.sh" --agent claude --no-hooks 2>&1)"; no $? "an install whose sandbox step fails is a failure"
  eq "$(allow "$FH")" '["Bash(ps:*)"]' "the allowlist is not written after a sandbox step that failed"
  has "$out" "allowlist  NOT written" "…and the install says so"
fi

check_summary check-permissions
