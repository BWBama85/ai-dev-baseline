#!/usr/bin/env bash
# ai-dev-baseline — the VENDOR-DOCUMENTATION DUTY's decision predicates (#422).
#
# THE QUESTION THIS MODULE ANSWERS: for this run, which documentation surfaces did the agent
# actually resolve, did the MCP servers this project declares REQUIRED answer a real query, and
# what must the run say about both?
#
# `base/practices/third-party-claims.md` already ranks HOW to resolve a claim (probe > context7 >
# vendor docs > recall). What it did not carry until #422 is WHEN the duty fires at all — its
# trigger was a claim already in doubt, and an agent confident in stale recall has no claim in
# doubt. The practice now carries the proportionality rule; this module is the auditable half:
# a run that consulted nothing has to SAY so, which turns a silent omission into a reviewable line.
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   docs-lib.sh mcp-required  [--manifest <file>]        # declared required servers, one per line
#   docs-lib.sh mcp-optional  [--manifest <file>]
#   docs-lib.sh probe-record  --server <name> --result usable|degraded|absent \
#                             --evidence <text> [--state <dir>]
#   docs-lib.sh consulted     --surface <text> --rung <1|2|3> --source <text> [--state <dir>]
#   docs-lib.sh none-needed   --justification <text> [--state <dir>]
#   docs-lib.sh verdict       [--state <dir>] [--manifest <file>]
#   docs-lib.sh report        [--state <dir>] [--manifest <file>]
#   docs-lib.sh -h | --help
#
# Exit codes — a stable machine contract for the workflow step that consumes them.
#
#   0  ok
#   1  none        — `mcp-required` / `mcp-optional`: the key is not declared. THE ORDINARY CASE,
#                    and not a problem: `[mcp]` stays optional per repo.
#   10 degraded    — `verdict`: at least one REQUIRED server did not answer. The run proceeds and
#                    says so; see "Why degraded and not fatal" below.
#   11 unstated    — `report`: this run recorded NOTHING — no consultation and no "none needed".
#                    #422 calls that the defect: an unstated disposition is indistinguishable from
#                    an agent that never considered the question.
#   18 config      — `[mcp] required` / `optional` is present but malformed.
#   19 refused     — a field this module will not store (a tab, a newline, a control character).
#   20 unknown     — the state directory could not be read or written.
#   2  usage
#
# ------------------------------------------------------------------------------------------------
# WHO PERFORMS THE PROBE, AND WHY IT IS NOT THIS SCRIPT
#
# MCP is an in-harness protocol, not a command line. Probed 2026-08-24: `codex mcp` offers
# list/get/add/remove/login/logout and `claude mcp` offers add/get/list/login/logout/remove/serve —
# every one of them CONFIGURATION management, and `serve` runs the agent AS a server rather than
# calling another one's tools. Neither exposes a generic tool call.
#
# WHAT THEY DO OFFER IS EXACTLY THE INSUFFICIENT SIGNAL. `claude mcp list`/`get` health-check
# approved servers, so a preflight could cheaply learn that a server is Connected — and the
# practice's connected-is-not-usable paragraph is about precisely that: a bad credential still
# reports Connected, still answers `tools/list`, and returns the auth failure INSIDE an HTTP 200
# tool result. Building the preflight on that check would report a dead server as present, which
# is worse than not checking, because it would carry an assurance nobody earned.
#
# So the work is split at the only line that holds for all three agents:
#
#   the AGENT issues one real read-only query per declared required server, in-harness, and
#   records the verdict here;   this MODULE owns the declaration read, the record grammar, and a
#   FAIL-CLOSED adjudication — a required server with no recorded result is DEGRADED, never assumed
#   well.
#
# What that buys is a verdict that cannot be quietly skipped: silence adjudicates the same as
# failure. What it does NOT buy is proof that the agent really issued the query, and saying so is
# part of the contract rather than a caveat — this is the same "prose, no gate" posture
# `third-party-claims.md` already states about the duty as a whole. The mechanism is the auditable
# report line, and review is what reads it.
#
# WHY DEGRADED AND NOT FATAL. `docs/design-principles.md` §5 says a missing REQUIRED dependency
# fails loud. That rule is about a mechanism's own machinery — the gate whose `common.sh` is gone
# is a broken install, and a silent no-op there is enforcement secretly off. A documentation server
# is not that: it is a preferred SOURCE with a lower rung underneath it, and the practice's own
# ladder says an unavailable rung 2 descends to rung 3. `templates/agents.toml` already defined the
# key that way ("a run that cannot reach one is DEGRADED; say so instead of proceeding quietly"),
# so the loud part is the SAYING. D90 records the reading.
#
# CONCURRENCY, STATED RATHER THAN LOCKED. Records are appended with `>>`, which is atomic for the
# short lines this module writes, so two writers interleave records rather than corrupting one. No
# read-modify-write happens here at all, so there is nothing for a second writer to clobber. The
# ordering between records is not guaranteed under concurrency, and nothing reads it.
#
# Requires: awk. No network, no gh, no jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) -----------
_adb_dl_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_dl_common="$_adb_dl_libdir/common.sh"
if [ ! -f "$_adb_dl_common" ]; then
  printf 'docs-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_dl_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_dl_common"
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

die() { printf 'docs-lib: %s\n' "$*" >&2; exit 2; }
usage() { adb_usage "$0"; }

TAB="$(printf '\t')"

# The run-scoped record file. One TSV, under the agent's own state directory, because it is run
# evidence and not project history — the ledger in .ai-dev-baseline/ is the durable artifact, this
# is cleared when the run that wrote it is done. /cleanup classifies it `docs` and
# implement-lib.sh's `admit` clears it; both are required of anything written here.
_ADB_DL_FILE=docs-consulted.tsv

# --- validation ---------------------------------------------------------------------------------
# The record file is TSV read back with `IFS=<tab> read`, so a tab or newline in a value does not
# corrupt a display — it FORGES A FIELD, and a forged field is how a `degraded` record reads back
# as `usable`. Refuse rather than escape.
_adb_dl_ok_field() {
  [ -n "$1" ] || return 1
  # THE DELIMITER TEST IS `adb_tsv_field_safe`'s — one home for exactly this question, and its
  # header records why the failure is FORGERY rather than corruption: a value carrying a delimiter
  # does not make the record malformed, it makes TWO records, the second entirely chosen by
  # whoever supplied the value. The control-character rule below is this module's own addition.
  adb_tsv_field_safe "$1" || return 1
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | wc -c)" -eq "$(printf '%s' "$1" | wc -c)" ]
}

# A server name is compared against a declaration, so it is held to a name charset rather than to
# "no tabs": a value that merely avoids the separators could still differ from the declared entry
# by whitespace and silently never match it.
_adb_dl_ok_server() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

# --- the state file -----------------------------------------------------------------------------
_adb_dl_state_dir() {
  if [ -n "${OPT_STATE:-}" ]; then printf '%s\n' "$OPT_STATE"; return 0; fi
  if [ -n "${ADB_DOCS_STATE:-}" ]; then printf '%s\n' "$ADB_DOCS_STATE"; return 0; fi
  local root; root="$(adb_repo_root 2>/dev/null)" || root=""
  [ -n "$root" ] || { printf 'docs-lib: not inside a git repository and no --state given\n' >&2; return 1; }
  printf '%s/.%s/state\n' "$root" "${ADB_AGENT:-claude}"
}

_adb_dl_file() {
  local d; d="$(_adb_dl_state_dir)" || return 1
  printf '%s/%s\n' "$d" "$_ADB_DL_FILE"
}

# Append one record, creating the file — and the state directory — on first write. The directory is
# created rather than required: the caller names it (`--state`), and a run whose very first docs
# action precedes any other state write would otherwise fail on a directory it is entitled to have.
_adb_dl_append() {
  local f d
  f="$(_adb_dl_file)" || exit 20
  d="$(dirname "$f")"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || { printf 'docs-lib: cannot create %s\n' "$d" >&2; exit 20; }
  printf '%s\n' "$*" >> "$f" || { printf 'docs-lib: cannot write %s\n' "$f" >&2; exit 20; }
}

# _adb_dl_records <file> — every stored record, but only if the WHOLE file obeys the grammar.
#
# THE READERS USED TO PARSE WITHOUT VALIDATING, and the independent review reproduced what that
# costs: a hand-written `probe<TAB>context7<TAB>usable` — three fields, no evidence — earned exit 0
# from `verdict`. So the adjudication enforced "a missing server result degrades" while the header
# claimed "silence or unverifiable evidence degrades", and the difference is a clean verdict nobody
# earned. An unknown record type, a short line, or a field the writer would have refused now stops
# both readers (18) instead of being skipped or half-read.
#
# VALIDATED THROUGH THE WRITER'S OWN PREDICATES, so the grammar keeps one home and a reader cannot
# drift from what `probe-record` and `consulted` will actually produce.
_adb_dl_records() {
  local f="$1" kind a b c n
  [ -f "$f" ] || return 0
  while IFS="$TAB" read -r kind a b c; do
    [ -n "$kind" ] || continue
    case "$kind" in
      probe)
        _adb_dl_ok_server "$a" || return 1
        case "$b" in usable|degraded|absent) ;; *) return 1 ;; esac
        _adb_dl_ok_field "$c" || return 1 ;;
      consulted)
        _adb_dl_ok_field "$a" || return 1
        case "$b" in 1|2|3) ;; *) return 1 ;; esac
        _adb_dl_ok_field "$c" || return 1 ;;
      none-needed)
        _adb_dl_ok_field "$a" || return 1
        # EXACTLY TWO FIELDS. A third would mean a tab reached a justification, which is the
        # forgery case `_adb_dl_ok_field` exists to prevent — caught here as well, because by the
        # time it is on disk the writer's check is behind us.
        [ -z "$b$c" ] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$f"
  n="$(wc -l < "$f" | tr -d ' ')"
  # A FINAL LINE WITHOUT A NEWLINE is a truncated write, and `read` drops it silently — so the
  # readers would adjudicate over a file whose last record they never saw.
  [ "$(wc -c < "$f" | tr -d ' ')" -eq 0 ] || [ "$n" -gt 0 ] || return 1
  return 0
}

# --- the manifest -------------------------------------------------------------------------------
# `[mcp] required` / `[mcp] optional`, read from the repo manifest then the global one. Read the
# way role-dispatch.sh reads `[reviewers] bots`, so the repo→global layering cannot drift between
# the consumers.
#
# A KEY THAT IS PRESENT BUT NOT AN ARRAY IS 18, never "none". `required = "context7"` is a
# plausible typo, and reading it as an undeclared key would report a project that asked for a
# preflight as a project that declined one.
_adb_dl_mcp_key() {
  local key="$1" raw layer layered parsed one
  # THE PRECEDENCE RULE IS `adb_toml_layered_get`'s (common.sh), not a third copy of it. The loop
  # this replaced also fell THROUGH an empty repo-level declaration to the global manifest, so a
  # project that wrote `required =` silently inherited the machine's list.
  #
  # `--manifest` replaces only the REPO layer: a test pointing at a throwaway manifest still has
  # the real global one underneath, which is what the runtime does.
  layered="$(adb_toml_layered_get "${OPT_MANIFEST:-$(adb_repo_root 2>/dev/null)/agents.toml}" \
                                  "$(adb_global_manifest)" mcp "$key" --with-layer)" || return 1
  layer="${layered%% *}"; raw="${layered#* }"
  [ -n "$raw" ] || return 1
  case "$raw" in
    \[*\]) ;;
    *) printf 'docs-lib: [mcp] %s in the %s manifest is not an array (got %s)\n' \
         "$key" "$layer" "$(adb_display_value "$raw")" >&2; return 18 ;;
  esac
  # EVERY ELEMENT IS VALIDATED, against the same charset `probe-record` enforces. A declared name
  # the recorder can never accept — `"bad name"`, say — is not a harmless typo: nothing could ever
  # record a result for it, so `verdict` would report the run DEGRADED forever, blaming a server
  # that was never the problem. Caught here, where the message can name the file to fix.
  parsed="$(adb_toml_array "$raw")"
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    _adb_dl_ok_server "$one" || {
      printf 'docs-lib: [mcp] %s in the %s manifest names %s, which is not a usable server name ([A-Za-z0-9_.-]). Nothing could record a result for it, so every run would report DEGRADED.\n' \
        "$key" "$layer" "$(adb_display_value "$one")" >&2
      return 18; }
  done <<ELEMS
$parsed
ELEMS
  printf '%s' "$parsed" | awk 'NF'
  return 0
}

# --- subcommands --------------------------------------------------------------------------------

cmd_mcp_required() { _adb_dl_mcp_key required; local rc=$?; [ "$rc" -eq 0 ] && return 0; return "$rc"; }
cmd_mcp_optional() { _adb_dl_mcp_key optional; local rc=$?; [ "$rc" -eq 0 ] && return 0; return "$rc"; }

cmd_probe_record() {
  [ -n "$OPT_SERVER" ]   || die "probe-record: --server is required"
  [ -n "$OPT_RESULT" ]   || die "probe-record: --result is required"
  [ -n "$OPT_EVIDENCE" ] || die "probe-record: --evidence is required"
  _adb_dl_ok_server "$OPT_SERVER" || {
    printf 'docs-lib: refusing server %s — [A-Za-z0-9_.-] up to 128 chars, matching the declared name.\n' "$(adb_display_value "$OPT_SERVER")" >&2; exit 19; }
  case "$OPT_RESULT" in
    usable|degraded|absent) ;;
    *) die "probe-record: --result must be usable, degraded or absent (got '$OPT_RESULT')" ;;
  esac
  # THE EVIDENCE IS MANDATORY AND IS THE POINT. `third-party-claims.md` requires recording WHAT
  # answered, not merely which rung did: "probed: resolve-library-id('bash') returned 5 libraries"
  # can be re-run by a reader, and a bare "usable" cannot be told from a guess.
  _adb_dl_ok_field "$OPT_EVIDENCE" || {
    printf 'docs-lib: refusing evidence — one printable line, no tab, no newline.\n' >&2; exit 19; }
  _adb_dl_append "probe${TAB}${OPT_SERVER}${TAB}${OPT_RESULT}${TAB}${OPT_EVIDENCE}"
  printf 'probe %s %s\n' "$OPT_SERVER" "$OPT_RESULT"
}

cmd_consulted() {
  [ -n "$OPT_SURFACE" ] || die "consulted: --surface is required"
  [ -n "$OPT_RUNG" ]    || die "consulted: --rung is required"
  [ -n "$OPT_SOURCE" ]  || die "consulted: --source is required"
  case "$OPT_RUNG" in
    1|2|3) ;;
    4) die "consulted: rung 4 is training-data recall, which never closes a claim — it is not a consultation (third-party-claims.md)" ;;
    *) die "consulted: --rung must be 1 (probe), 2 (context7) or 3 (vendor docs), got '$OPT_RUNG'" ;;
  esac
  _adb_dl_ok_field "$OPT_SURFACE" || { printf 'docs-lib: refusing surface — one printable line, no tab, no newline.\n' >&2; exit 19; }
  _adb_dl_ok_field "$OPT_SOURCE"  || { printf 'docs-lib: refusing source — one printable line, no tab, no newline.\n' >&2; exit 19; }
  _adb_dl_append "consulted${TAB}${OPT_SURFACE}${TAB}${OPT_RUNG}${TAB}${OPT_SOURCE}"
  printf 'consulted %s rung %s\n' "$OPT_SURFACE" "$OPT_RUNG"
}

# The explicit "no lookup was needed" disposition. It exists so that a trivial run can be COMPLETE
# rather than silent: #422's proportionality rule is real only if declining to look something up is
# a statement someone can review, and the justification is what makes it reviewable.
cmd_none_needed() {
  [ -n "$OPT_JUSTIFICATION" ] || die "none-needed: --justification is required"
  _adb_dl_ok_field "$OPT_JUSTIFICATION" || { printf 'docs-lib: refusing justification — one printable line, no tab, no newline.\n' >&2; exit 19; }
  _adb_dl_append "none-needed${TAB}${OPT_JUSTIFICATION}"
  printf 'none-needed\n'
}

# `verdict` — did every REQUIRED server answer?
#
# FAIL CLOSED IN BOTH DIRECTIONS THAT MATTER: a declared server with no recorded probe is degraded
# (silence adjudicates as failure, so skipping the probe cannot buy a clean verdict), and a
# malformed declaration is 18 rather than "none declared". The only rc 0 is "every declared
# required server has a recorded `usable`", or "nothing is declared".
cmd_verdict() {
  local required rc f probes="" bad="" s res
  required="$(_adb_dl_mcp_key required)"; rc=$?
  case "$rc" in
    0) ;;
    1) printf 'docs-lib: no [mcp] required declared — nothing to preflight\n'; return 0 ;;
    *) return "$rc" ;;
  esac
  if [ -z "$required" ]; then
    printf 'docs-lib: [mcp] required is empty — nothing to preflight\n'; return 0
  fi
  f="$(_adb_dl_file)" || exit 20
  _adb_dl_records "$f" >/dev/null || {
    printf 'docs-lib: %s holds a record that is not in the grammar — refusing to adjudicate over a file this module would not have written\n' "$f" >&2
    return 18; }
  [ -f "$f" ] && probes="$(awk -F'\t' '$1 == "probe" { print $2 "\t" $3 }' "$f")"

  # THE LAST RECORD FOR A SERVER WINS, which is why the awk keeps assigning instead of exiting on
  # the first match. The duty allows a retry — a server that answered an auth error and then, once
  # the operator fixed the credential, answered a real query, is usable — and reading the FIRST
  # record would pin the run to a degradation it has already cleared. The append-only file is the
  # audit trail; the verdict is about the latest state.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    res="$(printf '%s\n' "$probes" | awk -F'\t' -v n="$s" '$1 == n { r = $2 } END { print r }')"
    case "$res" in
      usable) ;;
      degraded|absent) bad="${bad}${s} (${res}) " ;;
      *)               bad="${bad}${s} (no probe recorded) " ;;
    esac
  done < <(printf '%s\n' "$required")

  if [ -n "$bad" ]; then
    printf 'docs-lib: DEGRADED — required MCP server(s) did not answer: %s\n' "${bad% }" >&2
    printf 'docs-lib: this run falls back to rung 3 (current vendor documentation via web search).\n' >&2
    printf 'docs-lib: say so in the run report; do NOT proceed on training-data recall.\n' >&2
    return 10
  fi
  printf 'docs-lib: all required MCP server(s) answered: %s\n' "$(printf '%s' "$required" | tr '\n' ' ')"
}

# `report` — the "Docs consulted" block for the pull-request body and the close-out.
#
# rc 11 WHEN NOTHING WAS RECORDED, and that is the whole mechanism. #422's honest boundary is that
# no classifier decides whether a surface was complex enough to need documentation; what can be
# decided is whether the run SAID anything about it. An empty record file is the unstated
# disposition, which is indistinguishable from an agent that never considered the question — so it
# is a distinct code the workflow step must handle, never an empty string it can print and move on
# from.
cmd_report() {
  local f n_consulted=0 n_none=0 n_probe=0 required rc vrc
  f="$(_adb_dl_file)" || exit 20
  _adb_dl_records "$f" >/dev/null || {
    printf 'docs-lib: %s holds a record that is not in the grammar — refusing to render a report from it\n' "$f" >&2
    return 18; }
  if [ -f "$f" ]; then
    n_consulted="$(awk -F'\t' '$1 == "consulted"'   "$f" | wc -l | tr -d ' ')"
    n_none="$(awk -F'\t'      '$1 == "none-needed"' "$f" | wc -l | tr -d ' ')"
    n_probe="$(awk -F'\t'     '$1 == "probe"'       "$f" | wc -l | tr -d ' ')"
  fi
  if [ "$n_consulted" -eq 0 ] && [ "$n_none" -eq 0 ]; then
    printf 'docs-lib: nothing recorded — this run has stated NO documentation disposition.\n' >&2
    printf 'docs-lib: record what you resolved (`consulted`), or state that nothing needed it\n' >&2
    printf 'docs-lib: (`none-needed --justification "…"`). An unstated disposition is the defect.\n' >&2
    return 11
  fi

  printf '**Docs consulted**\n\n'
  if [ "$n_consulted" -gt 0 ]; then
    awk -F'\t' '$1 == "consulted" { printf "- %s — rung %s: %s\n", $2, $3, $4 }' "$f"
  fi
  if [ "$n_none" -gt 0 ]; then
    awk -F'\t' '$1 == "none-needed" { printf "- none needed: %s\n", $2 }' "$f"
  fi
  # BOTH KINDS IN ONE RUN IS NOT AN ERROR, BUT IT IS WORTH SAYING. A run can legitimately declare
  # its surfaces trivial and then discover one that is not — the record is append-only and there is
  # no supersession rule, deliberately, because the earlier judgement is part of the audit trail.
  # What must not happen is the two sitting side by side looking like one coherent statement, so
  # the later consultation is named as superseding the scope of the earlier claim.
  if [ "$n_consulted" -gt 0 ] && [ "$n_none" -gt 0 ]; then
    printf '\n_This run recorded both: a surface was resolved after an earlier "none needed". The\n'
    printf '_"none needed" covers only what had been considered at that point._\n'
  fi

  # The MCP line is part of the same block, because a degraded server changes what the rungs above
  # are worth: "resolved via vendor web docs" reads differently when the reason is that context7
  # was unreachable.
  required="$(_adb_dl_mcp_key required)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$required" ]; then
    printf '\n'
    cmd_verdict >/dev/null 2>&1; vrc=$?
    if [ "$vrc" -eq 0 ]; then
      printf -- '- MCP preflight: %s answered a real query.\n' "$(printf '%s' "$required" | tr '\n' ' ' | sed 's/ $//')"
    else
      printf -- '- MCP preflight: **DEGRADED** — %s\n' "$(cmd_verdict 2>&1 >/dev/null | awk -F'did not answer: ' 'NF > 1 { print $2 }' | head -1)"
      printf -- '  This run fell back to rung 3 (current vendor documentation via web search).\n'
    fi
  elif [ "$rc" -eq 18 ]; then
    # NOT the "declares nothing" line. A malformed declaration is a project that ASKED for a
    # preflight and mis-spelled it, and reporting that as "declares no [mcp] required" tells the
    # reader the opposite of what is true — the flattering reading, in the one block whose job is
    # to be audited.
    printf '\n- MCP preflight: **UNREADABLE** — `[mcp] required` is malformed; fix agents.toml.\n'
  elif [ "$n_probe" -gt 0 ]; then
    printf '\n- MCP preflight: probes recorded, but this repo declares no `[mcp] required`.\n'
  fi
}

# --- arguments ----------------------------------------------------------------------------------
OPT_SERVER=""; OPT_RESULT=""; OPT_EVIDENCE=""; OPT_SURFACE=""; OPT_RUNG=""; OPT_SOURCE=""
OPT_JUSTIFICATION=""; OPT_STATE=""; OPT_MANIFEST=""

[ "$#" -ge 1 ] || { usage; exit 2; }
SUB="$1"; shift
case "$SUB" in -h|--help) usage; exit 0 ;; esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server)        [ "$#" -ge 2 ] || die "$SUB: --server needs a value";        OPT_SERVER="$2";        shift 2 ;;
    --result)        [ "$#" -ge 2 ] || die "$SUB: --result needs a value";        OPT_RESULT="$2";        shift 2 ;;
    --evidence)      [ "$#" -ge 2 ] || die "$SUB: --evidence needs a value";      OPT_EVIDENCE="$2";      shift 2 ;;
    --surface)       [ "$#" -ge 2 ] || die "$SUB: --surface needs a value";       OPT_SURFACE="$2";       shift 2 ;;
    --rung)          [ "$#" -ge 2 ] || die "$SUB: --rung needs a value";          OPT_RUNG="$2";          shift 2 ;;
    --source)        [ "$#" -ge 2 ] || die "$SUB: --source needs a value";        OPT_SOURCE="$2";        shift 2 ;;
    --justification) [ "$#" -ge 2 ] || die "$SUB: --justification needs a value"; OPT_JUSTIFICATION="$2"; shift 2 ;;
    --state)         [ "$#" -ge 2 ] || die "$SUB: --state needs a value";         OPT_STATE="$2";         shift 2 ;;
    --manifest)      [ "$#" -ge 2 ] || die "$SUB: --manifest needs a value";      OPT_MANIFEST="$2";      shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "$SUB: unknown option '$1'" ;;
  esac
done

case "$SUB" in
  mcp-required) cmd_mcp_required ;;
  mcp-optional) cmd_mcp_optional ;;
  probe-record) cmd_probe_record ;;
  consulted)    cmd_consulted ;;
  none-needed)  cmd_none_needed ;;
  verdict)      cmd_verdict ;;
  report)       cmd_report ;;
  *)            die "unknown subcommand '$SUB' (mcp-required|mcp-optional|probe-record|consulted|none-needed|verdict|report)" ;;
esac
