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
# CONCURRENCY, STATED AND BOUNDED. Records are appended with `>>` and no read-modify-write happens
# here at all, so there is nothing for a second writer to clobber. What makes the append itself
# safe is that every field is length-bounded (`_ADB_DL_FIELD_MAX`): a whole record then fits in one
# stdio buffer and reaches the file as a single write(), which is atomic under O_APPEND. The
# earlier version of this paragraph claimed safety "for the short lines this module writes" while
# enforcing shortness nowhere, and the reviewer produced malformed TSV from 30 concurrent appends
# of 100 KiB evidence. Record ORDER is still not guaranteed, and nothing reads it.
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
# The per-field byte bound. It is a CONCURRENCY guarantee, not a style rule: records are appended
# with `>>`, and a single write() to a file opened O_APPEND is atomic — but stdio splits a buffer
# larger than its own into SEVERAL writes, and two writers then interleave halves of two records.
# Reproduced by the reviewer on PR #429: 30 concurrent appends carrying 100 KiB of evidence
# produced malformed TSV that `report` then refused. Keeping every field under this bound keeps a
# whole record inside one stdio buffer, and 512 bytes is far more than one line of evidence needs.
_ADB_DL_FIELD_MAX=512

# _adb_dl_bytes <value> — the value's length in BYTES.
#
# `${#var}` counts CHARACTERS in the caller's locale, and the atomic-write guarantee is about
# bytes: two fields of 512 four-byte characters are ~4 KiB of record, which stdio splits and two
# appenders then interleave. The reviewer reproduced six malformed lines from 200 concurrent calls
# that all passed a 512-"byte" check. Reported by the declared reviewer on PR #429.
_adb_dl_bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }

_adb_dl_ok_field() {
  [ -n "$1" ] || return 1
  [ "$(_adb_dl_bytes "$1")" -le "$_ADB_DL_FIELD_MAX" ] || return 1
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
# The whole-record bound. Bounding each FIELD is necessary and not sufficient: three bounded fields
# plus their separators still add up, and it is the assembled record that must reach the file in
# one write. Checked here, at the single place every record is written.
_ADB_DL_RECORD_MAX=2048

_adb_dl_append() {
  local f d
  if [ "$(_adb_dl_bytes "$*")" -gt "$_ADB_DL_RECORD_MAX" ]; then
    printf 'docs-lib: refusing a %s-byte record — the append bound is %s bytes, because a record larger than one stdio buffer can be split and interleaved with another writer.\n' \
      "$(_adb_dl_bytes "$*")" "$_ADB_DL_RECORD_MAX" >&2
    exit 19
  fi
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
  local f="$1" kind a b c
  [ -f "$f" ] || return 0
  # ARITY IS CHECKED IN awk, BEFORE the shell loop, because `read` cannot check it. Tab is IFS
  # WHITESPACE, so `IFS=<tab> read` collapses adjacent tabs and strips trailing ones — which means
  # `probe<TAB>server<TAB>usable<TAB>evidence<TAB>` (an extra empty column) arrived at the loop
  # below looking exactly like a well-formed four-field record, and this module promises to refuse
  # every record it would not itself write. `awk -F'\t'` does no folding, so NF is the real count.
  # Reported by the declared reviewer on PR #429.
  awk -F'\t' '
    $1 == "probe"       { if (NF != 4) { bad = 1; exit } next }
    $1 == "consulted"   { if (NF != 4) { bad = 1; exit } next }
    $1 == "none-needed" { if (NF != 2) { bad = 1; exit } next }
    { bad = 1; exit }
    END { exit (bad ? 1 : 0) }
  ' "$f" || return 1
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
        # Exactly two fields — now also guaranteed by the arity pass above, and kept because a
        # reader auditing this loop should not have to look elsewhere to see that the rule exists.
        [ -z "$b$c" ] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$f"
  # THE FINAL BYTE MUST BE A NEWLINE, and testing "does the file contain any newline" was not that.
  # `read` silently DROPS an unterminated last line, so the loop above never validates it — while
  # `cmd_verdict`'s awk reads it perfectly well. A file holding one complete record plus an
  # unterminated `probe<TAB>server<TAB>usable` therefore passed validation, and that ghost record
  # then OVERRODE an earlier degraded result to return a clean verdict with no evidence: the exact
  # fail-open this module exists to prevent, reachable by appending one line without a newline.
  # Reported by the declared reviewer on PR #429.
  [ -s "$f" ] || return 0
  [ "$(tail -c 1 "$f" | wc -l | tr -d ' ')" -eq 1 ] || return 1
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
  local key="$1" raw layer layered parsed one _dupfile _dupes
  # THE PRECEDENCE RULE IS `adb_toml_layered_get`'s (common.sh), not a third copy of it. The loop
  # this replaced also fell THROUGH an empty repo-level declaration to the global manifest, so a
  # project that wrote `required =` silently inherited the machine's list.
  #
  # `--manifest` replaces only the REPO layer: a test pointing at a throwaway manifest still has
  # the real global one underneath, which is what the runtime does.
  layered="$(adb_toml_layered_get "${OPT_MANIFEST:-$(adb_repo_root 2>/dev/null)/agents.toml}" \
                                  "$(adb_global_manifest)" mcp "$key" --with-layer)" || return 1
  layer="${layered%% *}"; raw="${layered#* }"
  # PRESENT-BUT-EMPTY IS MALFORMED, NOT UNDECLARED. `required =` is invalid TOML, and the layered
  # reader returns success with an empty value for it — so this used to answer with the same `1` an
  # absent key gets, silently skipping the preflight for a project that plainly tried to configure
  # one. Reported by the declared reviewer on PR #429.
  if [ -z "$raw" ]; then
    printf 'docs-lib: [mcp] %s in the %s manifest is present but empty — not valid TOML, and not the same as leaving the key out.\n' \
      "$key" "$layer" >&2
    return 18
  fi
  # A KEY DECLARED TWICE IN ONE TABLE IS INVALID TOML, and `adb_toml_get` stops at the first
  # match — so a manifest repeating `required = [...]` had its FIRST array accepted while a real
  # TOML parser would reject the file outright, and a probe for only those servers could then earn
  # a clean verdict. Counted in the file the layered read actually answered from, so a duplicate in
  # the global manifest is not blamed on the repo one.
  # Reported by the declared reviewer on PR #429.
  case "$layer" in
    repo)   _dupfile="${OPT_MANIFEST:-$(adb_repo_root 2>/dev/null)/agents.toml}" ;;
    global) _dupfile="$(adb_global_manifest)" ;;
    *)      _dupfile="" ;;
  esac
  if [ -n "$_dupfile" ] && [ -f "$_dupfile" ]; then
    _dupes="$(awk -v k="$key" '
      /^[[:space:]]*\[/ { hdr = $0; sub(/^[[:space:]]*\[/, "", hdr); sub(/\][[:space:]]*$/, "", hdr)
                          intbl = (hdr == "mcp"); next }
      intbl && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") { n++ }
      END { print n + 0 }' "$_dupfile")"
    if [ "${_dupes:-0}" -gt 1 ]; then
      printf 'docs-lib: [mcp] %s is declared %s times in the %s manifest — that is not valid TOML, and only the first would ever be read.\n' \
        "$key" "$_dupes" "$layer" >&2
      return 18
    fi
  fi
  case "$raw" in
    \[*\]) ;;
    *) printf 'docs-lib: [mcp] %s in the %s manifest is not an array (got %s)\n' \
         "$key" "$layer" "$(adb_display_value "$raw")" >&2; return 18 ;;
  esac
  # EVERY ELEMENT MUST BE A QUOTED TOML STRING. `adb_toml_array` is deliberately permissive — it
  # strips one quote layer when present and passes a bare token through otherwise — so
  # `required = [context7]` parsed to a usable name and returned SUCCESS, where the documented
  # answer for a malformed declaration is 18. TOML has no bare-word array element, so accepting one
  # means this reader and the spec disagree about what the operator actually wrote, and a probe
  # could then earn a clean verdict against a manifest no TOML parser would load.
  # Reported by the declared reviewer on PR #429.
  if ! printf '%s' "$raw" | awk '
        {
          s = $0
          sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s)
          n = split(s, parts, ",")
          for (i = 1; i <= n; i++) {
            e = parts[i]
            gsub(/^[[:space:]]+/, "", e); gsub(/[[:space:]]+$/, "", e)
            if (e == "") {
              # AN EMPTY ELEMENT IS LEGAL IN EXACTLY TWO PLACES: the whole array is empty (n == 1),
              # or it is the single trailing comma TOML permits (the last split field). A LEADING
              # comma (`[, "a"]`) or a repeated one (`["a",,]`) lands here too, and treating every
              # empty element as fine accepted both — which is the same partial-validation shape
              # this file has now been corrected for three times: the check covered less than the
              # grammar it claimed to enforce. Reported by the declared reviewer on PR #429.
              if (n == 1) continue                      # []
              if (i == n) continue                      # one trailing comma
              bad = 1; exit
            }
            # NON-EMPTY between the quotes. `[""]` is syntactically a quoted string, so `.*`
            # admitted it — and `adb_toml_array` then drops empty elements, leaving `mcp-required`
            # reporting success with NO servers for an operator who declared one. It has to be
            # caught HERE, on the raw literal: after parsing, `[""]` and the legal `[]` are
            # indistinguishable. Reported by the declared reviewer on PR #429.
            # THE FULL NAME GRAMMAR, ON THE RAW VALUE. `adb_toml_array` trims whitespace INSIDE
            # the quotes, so `[" context7 "]` reached the charset check as `context7` and passed —
            # validating a normalized replacement rather than what the operator wrote, and letting
            # a probe for a DIFFERENT name earn a clean verdict. A whitespace-only string was
            # likewise normalized to empty and slipped past the empty-name rule. The raw literal
            # here is the only place the actual value still exists.
            # Reported by the declared reviewer on PR #429.
            if (e !~ /^"[A-Za-z0-9_.-]+"$/) { bad = 1; exit }
          }
        }
        END { exit (bad ? 1 : 0) }'; then
    printf 'docs-lib: [mcp] %s in the %s manifest is not a well-formed array of server names (got %s).\n' \
      "$key" "$layer" "$(adb_display_value "$raw")" >&2
    printf 'docs-lib: each element must be a QUOTED, non-empty name of [A-Za-z0-9_.-] — TOML has no\n' >&2
    printf 'docs-lib: bare-word element, and a name carrying whitespace is not the name a probe\n' >&2
    printf 'docs-lib: result could ever match — so every run would report DEGRADED, blaming a server\n' >&2
    printf 'docs-lib: that was never the problem.\n' >&2
    return 18
  fi
  # EVERY ELEMENT IS VALIDATED, against the same charset `probe-record` enforces. A declared name
  # the recorder can never accept — `"bad name"`, say — is not a harmless typo: nothing could ever
  # record a result for it, so `verdict` would report the run DEGRADED forever, blaming a server
  # that was never the problem. Caught here, where the message can name the file to fix.
  parsed="$(adb_toml_array "$raw")"
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    # REDUNDANT BY CONSTRUCTION with the raw grammar above, which already proved every element
    # matches this charset — kept as insurance against `adb_toml_array` changing what it returns,
    # and deliberately carrying no mutation row, because a row for a branch the code cannot reach
    # would claim a coverage that does not exist.
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
  local f n_consulted=0 n_none=0 n_probe=0 required rc vrc _srv _ev _report_rc=0
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
      # THE EVIDENCE IS RENDERED, not merely demanded. `probe-record` requires `--evidence` so a
      # reader can re-run what answered — and this block used to drop it, asserting only that the
      # server "answered". The record file is gitignored run state that `admit` and /cleanup remove,
      # so the report is the ONLY place that evidence ever reaches a reviewer: withholding it here
      # made the mandatory field unreadable by the audience it exists for.
      # Reported by the declared reviewer on PR #429.
      printf -- '- MCP preflight: every required server answered a real query.\n'
      while IFS= read -r _srv; do
        [ -n "$_srv" ] || continue
        printf -- '  - `%s` — %s\n' "$_srv" \
          "$(awk -F'\t' -v n="$_srv" '$1 == "probe" && $2 == n { e = $4 } END { print e }' "$f")"
      done <<SERVERS
$required
SERVERS
    else
      printf -- '- MCP preflight: **DEGRADED** — %s\n' "$(cmd_verdict 2>&1 >/dev/null | awk -F'did not answer: ' 'NF > 1 { print $2 }' | head -1)"
      # THE EVIDENCE, ON THIS ARM TOO. The clean arm gained it first and this one was left
      # asserting only a status — which is backwards: a reader needs the auth error or the failed
      # query far more than the text of a success, and the record file is swept, so this is the
      # only place either survives. Same `evidence-discarded` class as the clean arm, missed by
      # fixing the reported instance instead of sweeping the siblings.
      # Reported by the declared reviewer on PR #429.
      while IFS= read -r _srv; do
        [ -n "$_srv" ] || continue
        _ev="$(awk -F'\t' -v n="$_srv" '$1 == "probe" && $2 == n { e = $4 } END { print e }' "$f")"
        [ -n "$_ev" ] || _ev='(no probe was recorded for this server)'
        printf -- '  - `%s` — %s\n' "$_srv" "$_ev"
      done <<SERVERS
$required
SERVERS
      printf -- '  This run fell back to rung 3 (current vendor documentation via web search).\n'
    fi
  elif [ "$rc" -eq 18 ]; then
    # NOT the "declares nothing" line. A malformed declaration is a project that ASKED for a
    # preflight and mis-spelled it, and reporting that as "declares no [mcp] required" tells the
    # reader the opposite of what is true — the flattering reading, in the one block whose job is
    # to be audited.
    # AND THE STATUS SAYS SO. Printing UNREADABLE and then returning `printf`'s 0 told step 10
    # "paste the block", which is the arm meaning a successfully rendered report — so a malformed
    # manifest was reported as a good run. Reported by the declared reviewer on PR #429.
    _report_rc=18
    printf '\n- MCP preflight: **UNREADABLE** — `[mcp] required` is malformed; fix agents.toml.\n'
  elif [ "$n_probe" -gt 0 ]; then
    printf '\n- MCP preflight: probes recorded, but this repo declares no `[mcp] required`.\n'
  fi
  return "$_report_rc"
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
