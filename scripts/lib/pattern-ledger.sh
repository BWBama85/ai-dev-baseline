#!/usr/bin/env bash
# ai-dev-baseline — the per-project PATTERN LEDGER and its promoted checklist (#421).
#
# THE QUESTION THIS MODULE ANSWERS: which review-finding classes has this project already paid for,
# and which of them has it decided to sweep for before every future pull request?
#
# Every resolved review thread is a labeled example — a class, a site, and the commit that fixed it
# — and the loop used to discard all of it at the moment of resolution. This module is where that
# signal is kept. `record` is called by /resolve-pr-threads as each thread is resolved as a real
# code change; `checklist` is read by /implement-issue's gap dispatch and self-review pass.
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   pattern-ledger.sh record --class <slug> --site <path> --fix <sha> --pr <n> --thread <id> \
#                            [--summary <text>] [--date <YYYY-MM-DD>] [--ledger <file>]
#   pattern-ledger.sh classes   [--ledger <file>]           # <count>TAB<class>TAB<promoted 0|1>
#   pattern-ledger.sh due       [--ledger <file>] [--threshold <n>]   # classes owed a rule
#   pattern-ledger.sh promote --class <slug> --rule <text> [--ledger <file>] [--threshold <n>]
#   pattern-ledger.sh checklist [--ledger <file>]           # the promoted rules, one per line
#   pattern-ledger.sh stats     [--ledger <file>] [--threshold <n>] [--pr <n>]
#   pattern-ledger.sh verify    [--ledger <file>]
#   pattern-ledger.sh threshold [--ledger <file>]           # the effective threshold + its source
#   pattern-ledger.sh -h | --help
#
# Globals read: ADB_PATTERN_LEDGER (default <repo-root>/.ai-dev-baseline/patterns.md).
#
# Exit codes — a stable machine contract for the workflow steps that consume them. Deliberately
# DISJOINT from pr-threads.sh's and pr-watch.sh's where the meanings differ.
#
#   0  ok
#   10 duplicate  — `record`: this thread id is already recorded. A NO-OP, not a failure: the
#                   resolver may be re-run over a pull request it has already processed.
#   11 none-due   — `due`: no class has reached the threshold. The ordinary case.
#   12 below      — `promote`: that class has not reached the threshold yet.
#   13 already    — `promote`: that class already carries a checklist rule.
#   18 malformed  — the ledger exists but does not parse: a missing or crossed region marker, a
#                   record that is not in the record grammar. NEVER a partial count.
#   19 refused    — a field this module will not store. See "What may be stored" below.
#   20 unknown    — the ledger could not be read, created, or replaced.
#   2  usage      — bad or missing arguments.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is reporting a class as *rarer than it is*. A count
# that is too low leaves a recurring defect unpromoted, which is the exact failure #421 exists to
# end, and it is invisible — an unpromoted class looks like a class nobody has hit twice. So every
# uncertainty resolves to 18 or 20 and never to a smaller number: a ledger this module cannot parse
# is refused whole rather than counted in part.
#
# ------------------------------------------------------------------------------------------------
# What may be stored, and why the grammar is this strict
#
# Four fields are OPERATIVE — they are parsed, counted, compared, and (for the class) rendered into
# a prompt. Each is validated at `record` time against a closed charset, and a value outside it is
# REFUSED (19) rather than escaped:
#
#   class    [a-z][a-z0-9-]{0,47}      the finding class; the unit recurrence is counted in
#   site     no backtick, tab, newline the file (optionally :line) the finding was found at
#   fix      [0-9a-f]{7,40}            the commit that fixed it
#   thread   [A-Za-z0-9_=-]{1,256}     the review thread's node id — the IDEMPOTENCY KEY
#
# One field is DISPLAY: `summary`, one line of the resolving agent's own words. It is stored so a
# human reading the ledger can see what the class means in practice, and it is the one field this
# module treats as untrusted — it is never counted, never compared, and NEVER emitted by
# `checklist`, which is the only subcommand whose output reaches another agent's prompt.
#
# That split is what makes the ledger safe to feed forward. Review-thread text is third-party
# (base/practices/untrusted-content.md): a body on a public repo is written by anyone with an
# account. The operative output of this module is the PROMOTED CHECKLIST, and a rule reaches it
# only by being written into a tracked file that merges through the normal pull-request path — so
# its authority comes from the repo write access required to land it, not from the words a reviewer
# typed. `record` stores what a stranger may have influenced; `checklist` emits only what a
# maintainer merged.
#
# ------------------------------------------------------------------------------------------------
# The file format
#
# One tracked, agent-neutral Markdown file beside `.ai-dev-baseline/decisions.md` (D89). Markdown
# because a human has to read it in review — a promotion IS a diff someone approves — and because
# `decisions.md` already established that home for cross-agent project memory.
#
# Two machine-read regions, each fenced by HTML comment markers so the surrounding prose is free:
#
#   <!-- adb:checklist:begin -->  … promoted rules …   <!-- adb:checklist:end -->
#   <!-- adb:hits:begin -->       … recorded hits …    <!-- adb:hits:end -->
#
# A hit is one Markdown list item whose four operative fields are the first four CODE SPANS, in a
# fixed order:
#
#   - `<class>` `<site>` `<fix>` `<thread>` PR #<n> <date> — <summary>
#
# Splitting the line on the backtick therefore lands the operative fields on fields 2, 4, 6 and 8
# exactly, because none of the four may contain a backtick and that is enforced at write time. The
# summary sits after all of them and may contain anything printable without moving a field. A
# checklist rule is the same shape with one code span: ``- `<class>` — <rule>``.
#
# Lives OUTSIDE the state directory on purpose. This is durable project history, not run debris:
# /cleanup sweeps run-state whose PR has resolved, and a ledger swept on merge would forget exactly
# the thing it exists to remember.
#
# Requires: awk, and a writable ledger directory. No network, no gh, no jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) -----------
_adb_pl_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_pl_common="$_adb_pl_libdir/common.sh"
if [ ! -f "$_adb_pl_common" ]; then
  printf 'pattern-ledger: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_pl_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_pl_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller owns its own gate. An `if`, never `[ … ] && …`, which would return non-zero on the sourced
# path and trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

die() { printf 'pattern-ledger: %s\n' "$*" >&2; exit 2; }
usage() { adb_usage "$0"; }

TAB="$(printf '\t')"
# NOT `NL="$(printf '\n')"`, which is the EMPTY STRING: command substitution strips trailing
# newlines, so that spelling turns `case "$x" in *"$NL"*)` into a substring test against "" — which
# matches EVERY value, and every validator below would reject everything. The same trap
# scripts/lib/cleanup-lib.sh names beside its own TAB.
NL=$'\n'

# The built-in threshold. TWO, because #421 fixes the meaning: "a class recurring past a threshold
# (default 2 — a pattern, not an incident)". One occurrence is the incident; the second is what
# makes it a pattern, so promotion is owed at count >= 2 and not at 3.
_ADB_PL_DEFAULT_THRESHOLD=2

_ADB_PL_CK_BEGIN='<!-- adb:checklist:begin -->'
_ADB_PL_CK_END='<!-- adb:checklist:end -->'
_ADB_PL_HIT_BEGIN='<!-- adb:hits:begin -->'
_ADB_PL_HIT_END='<!-- adb:hits:end -->'

# --- validation ---------------------------------------------------------------------------------
# Each predicate answers ONE field. They are separate functions rather than one `case` with four
# arms because the diagnostic has to name the field AND its domain: "refused" with no domain is a
# message an operator cannot act on, and these values arrive from an agent filling in a template.

_adb_pl_ok_class() {
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
    [!a-z]*)         return 1 ;;   # must START with a letter, so `-x` and `9x` are refused
  esac
  [ "${#1}" -le 48 ]
}

_adb_pl_ok_fix() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]
}

_adb_pl_ok_thread() {
  case "$1" in ''|*[!A-Za-z0-9_=-]*) return 1 ;; esac
  [ "${#1}" -le 256 ]
}

_adb_pl_ok_pr() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 12 ]
}

_adb_pl_ok_date() {
  # YYYY-MM-DD, digits and dashes only. Not a calendar check — a wrong-but-well-formed date is a
  # display defect, while a date carrying a backtick or a newline is a FORMAT defect and would
  # move a field. Only the second kind can corrupt a count, so only the second kind is refused.
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# A value that may not move a parsed field: no backtick (the field separator), no tab, no newline
# (the record separator), and nothing unprintable. Used for `site` and, with the backtick rule
# relaxed, for the display fields.
_adb_pl_ok_span() {
  [ -n "$1" ] || return 1
  case "$1" in *'`'*|*"$TAB"*) return 1 ;; esac
  case "$1" in *"$NL"*) return 1 ;; esac
  # Refuse control characters wholesale. `tr -d` and a length compare rather than a glob, because
  # a bracket expression naming the control range is not portable across the shells this runs in.
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | wc -c)" -eq "$(printf '%s' "$1" | wc -c)" ]
}

# One line, printable, and never allowed to forge a record boundary or a region marker. The
# backtick IS permitted here — the summary sits after every parsed field, so it cannot move one —
# which matters because review findings routinely quote identifiers.
_adb_pl_ok_text() {
  [ -n "$1" ] || return 1
  case "$1" in *"$TAB"*) return 1 ;; esac
  case "$1" in *"$NL"*) return 1 ;; esac
  # A value containing a region marker could close the region it lives in and silently truncate
  # every record after it — the count-too-low direction this module must never take.
  case "$1" in *'<!-- adb:'*) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | wc -c)" -eq "$(printf '%s' "$1" | wc -c)" ]
}

# --- the ledger file ----------------------------------------------------------------------------
# Resolved once. `--ledger` wins so a test (and `verify` on an arbitrary file) needs no seam;
# ADB_PATTERN_LEDGER is the environment escape; otherwise it is the prescribed home under the
# repository root.
_adb_pl_resolve_ledger() {
  if [ -n "${OPT_LEDGER:-}" ]; then printf '%s\n' "$OPT_LEDGER"; return 0; fi
  if [ -n "${ADB_PATTERN_LEDGER:-}" ]; then printf '%s\n' "$ADB_PATTERN_LEDGER"; return 0; fi
  local root; root="$(adb_repo_root 2>/dev/null)" || root=""
  [ -n "$root" ] || { printf 'pattern-ledger: not inside a git repository and no --ledger given\n' >&2; return 1; }
  printf '%s/.ai-dev-baseline/patterns.md\n' "$root"
}

# The template a first `record` creates. The prose is part of the artifact: this file is read by
# humans in review, and a ledger that arrives with no explanation of what a promotion means is a
# file the first reviewer deletes.
_adb_pl_template() {
  cat <<'TPL'
# Pattern ledger

**What this project has already learned from its own review threads.** Every entry below was a
review finding somebody fixed: the class of defect, where it was found, and the commit that closed
it. It is written automatically by `/resolve-pr-threads` as each thread is resolved, and read
automatically by `/implement-issue` — the gap-analysis dispatch and the pre-PR self-review sweep
both receive the promoted checklist.

**The checklist is the operative half.** A class seen more than once is a pattern rather than an
incident, and is owed a rule: a sweep to run before the next pull request opens. Rules land here
through the normal pull-request path, so every one of them was reviewed by a human before any
agent was told to follow it.

**Editing by hand is fine.** Reword a rule that reads badly, delete one that stopped being true.
The only lines with a machine-read grammar are the ones between the markers below; the prose
around them is yours.

## Promoted checklist

Sweep each of these before opening a pull request.

<!-- adb:checklist:begin -->
<!-- adb:checklist:end -->

## Hits

One line per resolved review thread, newest last.

<!-- adb:hits:begin -->
<!-- adb:hits:end -->
TPL
}

# --- reading the file ---------------------------------------------------------------------------
# _adb_pl_region <file> <begin-marker> <end-marker> — the lines strictly between the markers.
#
# Returns 1 — never a partial region — when the markers are missing, duplicated, or crossed. That
# refusal is the whole reason the region is delimited rather than found by heading: a truncated
# region reads as "this project has recorded fewer hits", which is the one wrong direction.
_adb_pl_region() {
  awk -v b="$2" -v e="$3" '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == b { nb++; inb = 1; next }
    line == e { ne++; if (!inb) crossed = 1; inb = 0; next }
    inb { print }
    END { if (nb != 1 || ne != 1 || crossed || inb) exit 1 }
  ' "$1"
}

# _adb_pl_hits <file> — one `<class>TAB<site>TAB<fix>TAB<thread>TAB<pr>` record per hit.
#
# Splits on the backtick, which is exact: the four operative fields are the first four code spans
# and none of them may contain one (enforced by the validators at write time). A line inside the
# region that does not carry four spans is MALFORMED and fails the whole read (1) rather than being
# skipped — skipping is how a count silently drops.
_adb_pl_hits() {
  local region
  region="$(_adb_pl_region "$1" "$_ADB_PL_HIT_BEGIN" "$_ADB_PL_HIT_END")" || return 1
  printf '%s\n' "$region" | awk -F'`' '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == "" { next }
    {
      if (NF < 9)             { bad = 1; exit }
      if ($2 == "" || $4 == "" || $6 == "" || $8 == "") { bad = 1; exit }
      pr = ""
      if (match($9, /PR #[0-9]+/)) pr = substr($9, RSTART + 4, RLENGTH - 4)
      printf "%s\t%s\t%s\t%s\t%s\n", $2, $4, $6, $8, pr
    }
    END { if (bad) exit 1 }
  '
}

# _adb_pl_promoted <file> — the promoted class slugs, one per line.
_adb_pl_promoted() {
  local region
  region="$(_adb_pl_region "$1" "$_ADB_PL_CK_BEGIN" "$_ADB_PL_CK_END")" || return 1
  printf '%s\n' "$region" | awk -F'`' '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == "" { next }
    { if (NF < 3 || $2 == "") { bad = 1; exit } print $2 }
    END { if (bad) exit 1 }
  '
}

# --- the threshold ------------------------------------------------------------------------------
# `--threshold` > `[patterns] threshold` in the repo manifest > the same key in the global manifest
# > the built-in. Prints "<n> <source>".
#
# A MALFORMED DECLARED VALUE IS A HARD ERROR, never a fall-back to the built-in. Falling back would
# hand the operator a threshold they did not choose, from a file they thought they had configured,
# with nothing said — and this number decides whether a recurring defect is ever swept for at all.
# The same rule `pr-watch.sh` applies to `max_rounds`, for the same reason.
_adb_pl_threshold() {
  local v src file
  if [ -n "${OPT_THRESHOLD:-}" ]; then
    _adb_pl_ok_pr "$OPT_THRESHOLD" && [ "$OPT_THRESHOLD" -ge 1 ] \
      || die "--threshold must be a positive whole number, got '$OPT_THRESHOLD'"
    printf '%s flag\n' "$OPT_THRESHOLD"; return 0
  fi
  for file in "$(adb_repo_root 2>/dev/null)/agents.toml" "$(adb_global_manifest)"; do
    [ -f "$file" ] || continue
    v="$(adb_toml_get "$file" patterns threshold 2>/dev/null)" || continue
    [ -n "$v" ] || continue
    v="$(adb_toml_unquote "$v")"
    if ! _adb_pl_ok_pr "$v" || [ "$v" -lt 1 ]; then
      printf 'pattern-ledger: [patterns] threshold in %s is "%s" — must be a positive whole number\n' "$file" "$v" >&2
      return 2
    fi
    case "$file" in
      */.config/ai-dev-baseline/*) src=global ;;
      *) src=agents.toml ;;
    esac
    printf '%s %s\n' "$v" "$src"; return 0
  done
  printf '%s built-in\n' "$_ADB_PL_DEFAULT_THRESHOLD"
}

# _adb_pl_insert <file> <end-marker> <line> — put <line> immediately before <end-marker>, atomically.
#
# THE LINE TRAVELS THROUGH THE ENVIRONMENT, not through `awk -v`. `-v` processes backslash escapes
# in its value, so a site or summary containing `\n` or `\\` would arrive at awk already rewritten —
# silently storing something other than what was validated. `ENVIRON` hands the bytes over
# untouched.
#
# Published by RENAME, for the reason #268 established for the build: a reader that starts mid-write
# must see the old file whole or the new file whole, never a truncated one.
_adb_pl_insert() {
  local file="$1" end="$2" line="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if ! ADB_PL_LINE="$line" awk -v e="$end" '
        { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
        l == e && !done { print ENVIRON["ADB_PL_LINE"]; done = 1 }
        { print }
        END { if (!done) exit 1 }
      ' "$file" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# --- subcommands --------------------------------------------------------------------------------

cmd_record() {
  [ -n "$OPT_CLASS" ]  || die "record: --class is required"
  [ -n "$OPT_SITE" ]   || die "record: --site is required"
  [ -n "$OPT_FIX" ]    || die "record: --fix is required"
  [ -n "$OPT_PR" ]     || die "record: --pr is required"
  [ -n "$OPT_THREAD" ] || die "record: --thread is required"

  _adb_pl_ok_class "$OPT_CLASS" || {
    printf 'pattern-ledger: refusing class "%s" — a class is [a-z][a-z0-9-]* up to 48 chars. It is
  the unit recurrence is counted in, so it has to be the SAME string next time.\n' "$OPT_CLASS" >&2; exit 19; }
  _adb_pl_ok_span "$OPT_SITE" || {
    printf 'pattern-ledger: refusing site "%s" — no backtick, tab, newline or control character.\n' "$OPT_SITE" >&2; exit 19; }
  _adb_pl_ok_fix "$OPT_FIX" || {
    printf 'pattern-ledger: refusing fix "%s" — 7-40 lowercase hex digits (a commit sha).\n' "$OPT_FIX" >&2; exit 19; }
  _adb_pl_ok_pr "$OPT_PR" || {
    printf 'pattern-ledger: refusing pr "%s" — a positive whole number.\n' "$OPT_PR" >&2; exit 19; }
  _adb_pl_ok_thread "$OPT_THREAD" || {
    printf 'pattern-ledger: refusing thread "%s" — [A-Za-z0-9_=-] up to 256 chars (a review thread node id).\n' "$OPT_THREAD" >&2; exit 19; }

  local date="${OPT_DATE:-$(date -u +%Y-%m-%d)}"
  _adb_pl_ok_date "$date" || {
    printf 'pattern-ledger: refusing date "%s" — YYYY-MM-DD.\n' "$date" >&2; exit 19; }

  local summary="${OPT_SUMMARY:-}"
  if [ -n "$summary" ]; then
    _adb_pl_ok_text "$summary" || {
      printf 'pattern-ledger: refusing summary — one printable line, no tab, no newline, and it may
  not contain the string "<!-- adb:" (which would close a region and truncate the ledger).\n' >&2; exit 19; }
  fi

  local ledger; ledger="$(_adb_pl_resolve_ledger)" || exit 20

  if [ ! -f "$ledger" ]; then
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || { printf 'pattern-ledger: cannot create %s\n' "$(dirname "$ledger")" >&2; exit 20; }
    _adb_pl_template > "$ledger" || { printf 'pattern-ledger: cannot write %s\n' "$ledger" >&2; exit 20; }
  fi
  [ -r "$ledger" ] && [ -w "$ledger" ] || { printf 'pattern-ledger: %s is not readable and writable\n' "$ledger" >&2; exit 20; }

  # EXACTLY-ONCE, keyed on the review thread. The resolver records BEFORE it resolves the thread
  # (a crash between the two must not lose the signal), so a re-run over the same pull request
  # re-offers hits that are already here. That is the ordinary case, so it exits 10 and says
  # nothing alarming — it is not a failure and must not read like one.
  local hits
  hits="$(_adb_pl_hits "$ledger")" || { printf 'pattern-ledger: %s does not parse — refusing to append to a ledger whose existing records cannot be read\n' "$ledger" >&2; exit 18; }
  if printf '%s\n' "$hits" | awk -F'\t' -v t="$OPT_THREAD" '$4 == t { found = 1 } END { exit !found }'; then
    printf 'pattern-ledger: thread %s is already recorded — nothing appended\n' "$OPT_THREAD" >&2
    exit 10
  fi

  local rec
  if [ -n "$summary" ]; then
    rec="$(printf -- '- `%s` `%s` `%s` `%s` PR #%s %s — %s' "$OPT_CLASS" "$OPT_SITE" "$OPT_FIX" "$OPT_THREAD" "$OPT_PR" "$date" "$summary")"
  else
    rec="$(printf -- '- `%s` `%s` `%s` `%s` PR #%s %s' "$OPT_CLASS" "$OPT_SITE" "$OPT_FIX" "$OPT_THREAD" "$OPT_PR" "$date")"
  fi
  _adb_pl_insert "$ledger" "$_ADB_PL_HIT_END" "$rec" \
    || { printf 'pattern-ledger: could not append to %s\n' "$ledger" >&2; exit 20; }
  printf 'recorded %s %s\n' "$OPT_CLASS" "$OPT_THREAD"
}

cmd_classes() {
  local ledger hits promoted
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || exit 0            # no ledger yet is no classes, not an error
  hits="$(_adb_pl_hits "$ledger")"      || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  promoted="$(_adb_pl_promoted "$ledger")" || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  [ -n "$hits" ] || exit 0
  printf '%s\n' "$hits" | awk -F'\t' -v TAB="$TAB" -v prom="$promoted" '
    BEGIN { n = split(prom, p, "\n"); for (i = 1; i <= n; i++) if (p[i] != "") isprom[p[i]] = 1 }
    $1 != "" { c[$1]++ }
    END { for (k in c) printf "%d%s%s%s%d\n", c[k], TAB, k, TAB, (k in isprom ? 1 : 0) }
  ' | LC_ALL=C sort -t"$TAB" -k1,1nr -k2,2
}

# `due` — the classes that have reached the threshold and carry no rule yet. Exit 11 (not 0) when
# there are none, so a caller can branch on the code instead of testing whether stdout was empty:
# an empty stdout is also what a broken read produces, and those two must never look alike.
cmd_due() {
  local ledger t tsrc line n out="" rows crc
  read -r t tsrc < <(_adb_pl_threshold) || exit 2
  [ -n "$t" ] || exit 2
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || exit 11
  # CAPTURED AND ITS STATUS CHECKED, never consumed straight from `< <(cmd_classes)`. A process
  # substitution runs in a SUBSHELL, so `cmd_classes`'s `exit 18` terminated only that subshell:
  # the loop read no lines, `out` stayed empty, and a ledger this module cannot parse came back as
  # 11 — "no class is due". That is the count-too-low direction wearing the ordinary answer's face,
  # on the one subcommand whose whole job is to say what earned a rule.
  rows="$(cmd_classes)"; crc=$?
  [ "$crc" -eq 0 ] || exit "$crc"
  while IFS="$TAB" read -r n line _prom; do
    [ -n "$n" ] || continue
    [ "$_prom" = "0" ] || continue
    [ "$n" -ge "$t" ] || continue
    out="${out}${line}${TAB}${n}"$'\n'
  done <<ROWS
$rows
ROWS
  [ -n "$out" ] || exit 11
  printf '%s' "$out"
  printf 'pattern-ledger: threshold %s (from %s)\n' "$t" "$tsrc" >&2
}

# `promote` — write the rule a class earned. The RULE TEXT IS THE AGENT'S OWN WORDS, not a
# rendering of the hits: a class, a site and a sha do not say what to look for next time, and a
# derived sentence would be a template nobody reads. What this module owns is that the class is
# real, is at the threshold, and is not already on the list.
cmd_promote() {
  [ -n "$OPT_CLASS" ] || die "promote: --class is required"
  [ -n "$OPT_RULE" ]  || die "promote: --rule is required"
  _adb_pl_ok_class "$OPT_CLASS" || { printf 'pattern-ledger: refusing class "%s"\n' "$OPT_CLASS" >&2; exit 19; }
  _adb_pl_ok_text "$OPT_RULE"   || {
    printf 'pattern-ledger: refusing rule — one printable line, no tab, no newline, and it may not
  contain "<!-- adb:".\n' >&2; exit 19; }

  local ledger t tsrc
  read -r t tsrc < <(_adb_pl_threshold) || exit 2
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || { printf 'pattern-ledger: no ledger at %s — nothing has been recorded yet\n' "$ledger" >&2; exit 12; }

  local promoted count
  promoted="$(_adb_pl_promoted "$ledger")" || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  if printf '%s\n' "$promoted" | awk -v c="$OPT_CLASS" '$0 == c { f = 1 } END { exit !f }'; then
    printf 'pattern-ledger: %s already has a checklist rule\n' "$OPT_CLASS" >&2
    exit 13
  fi

  # SAME TRAP AS `due`: a pipeline reports its LAST command's status, so `cmd_classes | awk`
  # returns awk's — and a ledger that does not parse would arrive as no input, `count` would fall
  # to 0, and the refusal would be 12 ("below the threshold") for a file nobody could read. Read
  # first, check the status, then parse.
  local rows crc
  rows="$(cmd_classes)"; crc=$?
  [ "$crc" -eq 0 ] || exit "$crc"
  count="$(printf '%s\n' "$rows" | awk -F"$TAB" -v c="$OPT_CLASS" '$2 == c { print $1; exit }')"
  [ -n "$count" ] || count=0
  if [ "$count" -lt "$t" ]; then
    printf 'pattern-ledger: %s has %s hit(s), threshold is %s (from %s) — not promoting\n' \
      "$OPT_CLASS" "$count" "$t" "$tsrc" >&2
    exit 12
  fi

  _adb_pl_insert "$ledger" "$_ADB_PL_CK_END" "$(printf -- '- `%s` — %s' "$OPT_CLASS" "$OPT_RULE")" \
    || { printf 'pattern-ledger: could not write %s\n' "$ledger" >&2; exit 20; }
  printf 'promoted %s (%s hits, threshold %s from %s)\n' "$OPT_CLASS" "$count" "$t" "$tsrc"
}

# `checklist` — THE ONLY SUBCOMMAND WHOSE OUTPUT REACHES ANOTHER AGENT'S PROMPT, and the reason
# the record grammar splits operative fields from display ones. It emits promoted rules and nothing
# else: no site, no sha, and above all no summary. A summary is a reviewer's words, and a reviewer
# on a public repository is anyone; a rule is a maintainer's, because a rule only exists here after
# a pull request carrying it merged.
cmd_checklist() {
  local ledger region
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || exit 0
  # BOTH REGIONS, even though only one is emitted. This module's contract is that a ledger it
  # cannot parse is refused WHOLE rather than read in part, and this is the subcommand where
  # breaking that would be quietest: the checklist half can be perfectly well-formed while the hits
  # half has been truncated, and then the read side feeds an agent a checklist the write side would
  # refuse to add to. A damaged ledger is loud everywhere or it is loud nowhere.
  _adb_pl_hits "$ledger" >/dev/null \
    || { printf 'pattern-ledger: %s does not parse (the hits region) — refusing to emit a checklist from a ledger that is half readable\n' "$ledger" >&2; exit 18; }
  region="$(_adb_pl_region "$ledger" "$_ADB_PL_CK_BEGIN" "$_ADB_PL_CK_END")" \
    || { printf 'pattern-ledger: %s does not parse (the checklist region)\n' "$ledger" >&2; exit 18; }
  _adb_pl_promoted "$ledger" >/dev/null \
    || { printf 'pattern-ledger: %s does not parse (a checklist rule is not in the grammar)\n' "$ledger" >&2; exit 18; }
  printf '%s\n' "$region" | awk 'NF { print }'
}

# `stats` — the numbers /resolve-pr-threads' summary reports. #421's own honest boundary says the
# observable is the finding-per-round trend, so the loop has to keep printing it: a learning
# mechanism whose effect cannot be seen in that number is not learning.
#
# `recurring` counts HITS IN CLASSES AT OR OVER THE THRESHOLD — not the number of such classes.
# That is the quantity that should fall as the checklist starts working: classes accumulate
# forever, while repeat hits in a known class are exactly the avoidable ones.
cmd_stats() {
  local ledger t tsrc hits total=0 recurring=0 classes=0 promoted=0 thispr=0
  read -r t tsrc < <(_adb_pl_threshold) || exit 2
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  if [ ! -f "$ledger" ]; then
    printf 'hits\t0\nclasses\t0\nrecurring\t0\npromoted\t0\nthreshold\t%s\nthreshold-source\t%s\n' "$t" "$tsrc"
    [ -n "$OPT_PR" ] && printf 'pr-hits\t0\n'
    exit 0
  fi
  hits="$(_adb_pl_hits "$ledger")" || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  promoted="$(_adb_pl_promoted "$ledger" | awk 'NF' | wc -l | tr -d ' ')" \
    || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  if [ -n "$hits" ]; then
    total="$(printf '%s\n' "$hits" | awk 'NF' | wc -l | tr -d ' ')"
    classes="$(printf '%s\n' "$hits" | awk -F'\t' 'NF && $1 != "" { c[$1] } END { print length(c) }')"
    recurring="$(printf '%s\n' "$hits" | awk -F'\t' -v t="$t" '
      NF && $1 != "" { c[$1]++; rows[NR] = $1 }
      END { n = 0; for (i in rows) if (c[rows[i]] >= t) n++; print n }')"
    if [ -n "$OPT_PR" ]; then
      thispr="$(printf '%s\n' "$hits" | awk -F'\t' -v p="$OPT_PR" '$5 == p { n++ } END { print n + 0 }')"
    fi
  fi
  printf 'hits\t%s\nclasses\t%s\nrecurring\t%s\npromoted\t%s\nthreshold\t%s\nthreshold-source\t%s\n' \
    "$total" "$classes" "$recurring" "$promoted" "$t" "$tsrc"
  [ -n "$OPT_PR" ] && printf 'pr-hits\t%s\n' "$thispr"
  return 0
}

# `verify` — does this ledger parse, and does every record obey the grammar? Reports what it
# CHECKED, not only that it passed (base/practices/self-review.md): a validator that scanned zero
# records prints the same "ok" as one that scanned forty, and the count is what tells them apart.
cmd_verify() {
  local ledger hits promoted nh=0 np=0 bad=0 c s f th
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || { printf 'pattern-ledger: no ledger at %s\n' "$ledger" >&2; exit 20; }
  hits="$(_adb_pl_hits "$ledger")" || { printf 'pattern-ledger: %s — the hits region is missing, duplicated, crossed, or holds a record that is not in the grammar\n' "$ledger" >&2; exit 18; }
  promoted="$(_adb_pl_promoted "$ledger")" || { printf 'pattern-ledger: %s — the checklist region is missing, duplicated, crossed, or holds a rule that is not in the grammar\n' "$ledger" >&2; exit 18; }

  if [ -n "$hits" ]; then
    while IFS="$TAB" read -r c s f th _pr; do
      [ -n "$c$s$f$th" ] || continue
      nh=$((nh + 1))
      _adb_pl_ok_class  "$c"  || { printf 'pattern-ledger: record %s has an invalid class "%s"\n' "$nh" "$c" >&2; bad=1; }
      _adb_pl_ok_span   "$s"  || { printf 'pattern-ledger: record %s has an invalid site "%s"\n' "$nh" "$s" >&2; bad=1; }
      _adb_pl_ok_fix    "$f"  || { printf 'pattern-ledger: record %s has an invalid fix "%s"\n' "$nh" "$f" >&2; bad=1; }
      _adb_pl_ok_thread "$th" || { printf 'pattern-ledger: record %s has an invalid thread "%s"\n' "$nh" "$th" >&2; bad=1; }
    done < <(printf '%s\n' "$hits")
  fi
  if [ -n "$promoted" ]; then
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      np=$((np + 1))
      _adb_pl_ok_class "$c" || { printf 'pattern-ledger: checklist rule %s names an invalid class "%s"\n' "$np" "$c" >&2; bad=1; }
    done < <(printf '%s\n' "$promoted")
  fi
  # A DUPLICATE THREAD ID IS A DEFECT, not a duplicate hit: `record` refuses one, so a pair here
  # means the file was hand-edited or two branches merged the same record twice, and the count is
  # now higher than the number of findings that actually happened.
  local dupes=""
  if [ -n "$hits" ]; then
    dupes="$(printf '%s\n' "$hits" | awk -F'\t' 'NF { print $4 }' | LC_ALL=C sort | LC_ALL=C uniq -d)"
    [ -z "$dupes" ] || { printf 'pattern-ledger: duplicate thread id(s): %s\n' "$(printf '%s' "$dupes" | tr '\n' ' ')" >&2; bad=1; }
  fi
  [ "$bad" -eq 0 ] || exit 18
  printf 'ok %s hit(s), %s checklist rule(s) checked in %s\n' "$nh" "$np" "$ledger"
}

cmd_threshold() {
  local t src
  read -r t src < <(_adb_pl_threshold) || exit 2
  printf '%s %s\n' "$t" "$src"
}

# --- arguments ----------------------------------------------------------------------------------
OPT_CLASS=""; OPT_SITE=""; OPT_FIX=""; OPT_PR=""; OPT_THREAD=""
OPT_SUMMARY=""; OPT_DATE=""; OPT_RULE=""; OPT_LEDGER=""; OPT_THRESHOLD=""

[ "$#" -ge 1 ] || { usage; exit 2; }
SUB="$1"; shift
case "$SUB" in -h|--help) usage; exit 0 ;; esac

# Every option takes a value, and each arm asks for one. `[ "$#" -ge 2 ]` alone would let a
# TRAILING `--class` consume the empty string and record a hit with no class — which then fails
# validation with a message about the value rather than about the missing argument.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --class)     [ "$#" -ge 2 ] || die "$SUB: --class needs a value";     OPT_CLASS="$2";     shift 2 ;;
    --site)      [ "$#" -ge 2 ] || die "$SUB: --site needs a value";      OPT_SITE="$2";      shift 2 ;;
    --fix)       [ "$#" -ge 2 ] || die "$SUB: --fix needs a value";       OPT_FIX="$2";       shift 2 ;;
    --pr)        [ "$#" -ge 2 ] || die "$SUB: --pr needs a value";        OPT_PR="$2";        shift 2 ;;
    --thread)    [ "$#" -ge 2 ] || die "$SUB: --thread needs a value";    OPT_THREAD="$2";    shift 2 ;;
    --summary)   [ "$#" -ge 2 ] || die "$SUB: --summary needs a value";   OPT_SUMMARY="$2";   shift 2 ;;
    --date)      [ "$#" -ge 2 ] || die "$SUB: --date needs a value";      OPT_DATE="$2";      shift 2 ;;
    --rule)      [ "$#" -ge 2 ] || die "$SUB: --rule needs a value";      OPT_RULE="$2";      shift 2 ;;
    --ledger)    [ "$#" -ge 2 ] || die "$SUB: --ledger needs a value";    OPT_LEDGER="$2";    shift 2 ;;
    --threshold) [ "$#" -ge 2 ] || die "$SUB: --threshold needs a value"; OPT_THRESHOLD="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "$SUB: unknown option '$1'" ;;
  esac
done

case "$SUB" in
  record)    cmd_record ;;
  classes)   cmd_classes ;;
  due)       cmd_due ;;
  promote)   cmd_promote ;;
  checklist) cmd_checklist ;;
  stats)     cmd_stats ;;
  verify)    cmd_verify ;;
  threshold) cmd_threshold ;;
  *)         die "unknown subcommand '$SUB' (record|classes|due|promote|checklist|stats|verify|threshold)" ;;
esac
