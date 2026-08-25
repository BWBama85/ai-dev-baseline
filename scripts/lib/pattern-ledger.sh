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
#   21 oversized  — `checklist` / `verify`: the promoted checklist exceeds the prompt budget (see
#                   "What may be stored"). NOTHING is emitted: a truncated checklist would drop the
#                   sweep a class earned, silently, which is the count-too-low direction.
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
# Both stored texts — a rule and a summary — are BOUNDED in bytes (`_ADB_PL_TEXT_MAX_BYTES`), and
# so is the checklist `checklist` emits (`_ADB_PL_CHECKLIST_MAX_BYTES`); the constants below carry
# the numbers and the reason. A rule outside its bound is refused (19) and never stored; a region
# outside its bound is refused at `promote` (19) and, if a hand edit or a merge produced one
# anyway, at `checklist` (21) rather than emitted into a prompt in part.
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
# CONCURRENCY IS LOCKED, because the argument for not locking it was false. An earlier version of
# this header claimed the writer was sequential by construction, on the ground that
# `/implement-issue`'s run admission permits one run per checkout per agent. But the writer here is
# `/resolve-pr-threads`, which never takes that claim — so nothing serialized two overlapping
# resolver runs, and `_adb_pl_insert`'s read-modify-write would have the second rename silently
# discard every hit the first wrote. Silent loss of the signal this module exists to keep is the
# one outcome it must not have, so the guarantee is now real rather than asserted.
# Reported by the declared reviewer on PR #429.
#
# `mkdir` is the lock: it is atomic on every POSIX filesystem, needs no helper, and leaves a
# directory a human can see and remove. The wait is bounded and the failure is loud — a caller that
# cannot take the lock is told, never left to write anyway. A lock older than the stale age is
# broken with a note, so a killed writer cannot block the ledger forever.
#
# Two *checkouts* writing one ledger is still a git-merge question, not a locking one, and the
# template says how that resolves.
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

# The built-in threshold. TWO, because #421 fixes the meaning: "a class recurring past a threshold
# (default 2 — a pattern, not an incident)". One occurrence is the incident; the second is what
# makes it a pattern, so promotion is owed at count >= 2 and not at 3.
_ADB_PL_DEFAULT_THRESHOLD=2

_ADB_PL_CK_BEGIN='<!-- adb:checklist:begin -->'
_ADB_PL_CK_END='<!-- adb:checklist:end -->'
_ADB_PL_HIT_BEGIN='<!-- adb:hits:begin -->'
_ADB_PL_HIT_END='<!-- adb:hits:end -->'
# THE PROMPT BUDGET. `checklist` is the one subcommand whose output enters an agent's prompt, and
# both consumers inject it whole — so an unbounded region could crowd out the issue and review
# instructions it exists to sharpen. Two bounds, both in BYTES: one per stored text (a rule or a
# summary), enforced at write time and on every read; one on the whole emitted checklist, enforced
# by `promote` before it appends (19) and by `checklist` before it emits (21).
# Reported by the declared reviewer on PR #429.
_ADB_PL_TEXT_MAX_BYTES=1024
_ADB_PL_CHECKLIST_MAX_BYTES=16384

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

# A POSITIVE whole number — zero is refused, because both callers' diagnostics say "positive" and
# a predicate that accepts `0` while its message forbids it is a contract nobody can rely on.
# `-gt 0` rather than a `!= 0` string test, so `0`, `00` and `000` are all caught.
_adb_pl_ok_pr() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 12 ] || return 1
  [ "$1" -gt 0 ]
}

_adb_pl_ok_date() {
  # A REAL CALENDAR DATE, YYYY-MM-DD — not only the shape. This used to be a shape check on the
  # argument that a wrong-but-well-formed date is display, and that held while the date was only
  # displayed. It is not any more: `stats --pr` orders a class's history by it to decide which pull
  # request first recorded the class, so `0000-00-00` — accepted by the shape check and sorting
  # before every real date — moved `pr-new-classes` credit to whichever record carried it. A
  # validator has to match the field's OPERATIONAL use, and the use is now ordering.
  # Reported by the declared reviewer on PR #429.
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  local y m d dim
  y=$((10#${1%%-*})); m="${1#*-}"; d=$((10#${m#*-})); m=$((10#${m%-*}))
  [ "$y" -ge 1 ] && [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] || return 1
  case "$m" in
    1|3|5|7|8|10|12) dim=31 ;;
    4|6|9|11)        dim=30 ;;
    *) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then dim=29; else dim=28; fi ;;
  esac
  [ "$d" -le "$dim" ]
}

# A value that may not move a parsed field: no backtick (the field separator), no tab, no newline
# (the record separator), and nothing unprintable. Used for `site` and, with the backtick rule
# relaxed, for the display fields.
_adb_pl_ok_span() {
  [ -n "$1" ] || return 1
  # THE DELIMITER TEST IS `adb_tsv_field_safe`'s — one home for "can this be a field in a
  # TAB-separated, newline-terminated record", which is the exact question, and whose header
  # records why forgery rather than corruption is the failure it prevents. The BACKTICK and the
  # control-character rules below are this format's own additions and stay here.
  adb_tsv_field_safe "$1" || return 1
  case "$1" in *'`'*) return 1 ;; esac
  # Refuse control characters wholesale. `tr -d` and a length compare rather than a glob, because
  # a bracket expression naming the control range is not portable across the shells this runs in.
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | wc -c)" -eq "$(printf '%s' "$1" | wc -c)" ]
}

# One line, printable, and never allowed to forge a record boundary or a region marker. The
# backtick IS permitted here — the summary sits after every parsed field, so it cannot move one —
# which matters because review findings routinely quote identifiers.
_adb_pl_ok_text() {
  [ -n "$1" ] || return 1
  adb_tsv_field_safe "$1" || return 1
  # A value containing a region marker could close the region it lives in and silently truncate
  # every record after it — the count-too-low direction this module must never take.
  # STRUCTURAL MARKUP IS REFUSED, not escaped. `<!-- adb:` was banned because it can close a
  # REGION; any `<!--` can open an HTML comment that GitHub honours, hiding every hit and rule
  # after it in the review view — and a summary routinely quotes hostile reviewer text. Refusing
  # keeps the tracked file readable, which escaping into entities would not.
  # Reported by the declared reviewer on PR #429.
  case "$1" in *'<!--'*|*'-->'*) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" -le "$_ADB_PL_TEXT_MAX_BYTES" ] || return 1
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
through the normal pull-request path, so a rule only takes effect once a change carrying it has
been merged — which takes repository write access, and is reviewable in the diff like any other
change. (Write access is what the guarantee actually rests on; whether a human read the diff is up
to the project's own review settings.)

**Editing by hand is fine.** Reword a rule that reads badly, delete one that stopped being true.
The only lines with a machine-read grammar are the ones between the markers below; the prose
around them is yours.

**Resolving a `fix` sha after the pull request merged.** On a squash-merging repo the per-thread
commits never become ancestors of the default branch, so a bare `git show <fix>` fails once the
branch is gone. GitHub keeps the pull request's own commits, so fetch them by PR number — which is
why every entry carries one:

```sh
git fetch origin "refs/pull/<pr>/head" && git show <fix>
```

**Two branches can both append here, and that is handled by ordinary means.** Git may report a
conflict when two pull requests add hits at the same point — take both sides; the entries are
independent and are keyed on their review-thread ids, so nothing is lost by keeping them. Promotion
is decided by *reading this file*, never by a counter carried in a branch: two branches that each
recorded a class's first hit merge into a file holding two, and the class is then due.

**What makes that converge is a check on the CLEAN-PASS path**, not the ordinary one. A resolver run
that finds nothing to fix exits before it would ever ask which classes are due, so "the next run
promotes it" was only true of a run that happened to have other findings. `/resolve-pr-threads`
therefore reconciles due promotions before exiting on a clean pass — the one thing a clean run still
does.

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
  # NUL BYTES ARE REFUSED ON THE RAW BYTES, BEFORE ANY COMMAND SUBSTITUTION. Every reader captures
  # this region with `$( … )`, and bash DISCARDS an embedded NUL there — so a stored class of
  # `partial<NUL>-validation` reached the validators as `partial-validation` and counted toward
  # that class's promotion, a record the writer could never have produced. The same defect, and
  # the same fix, as docs-lib's record reader. Reported by the declared reviewer on PR #429.
  [ "$(LC_ALL=C tr -d '\000' < "$1" | wc -c | tr -d ' ')" -eq "$(LC_ALL=C wc -c < "$1" | tr -d ' ')" ] || return 1
  awk -v b="$2" -v e="$3" '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == b { nb++; inb = 1; next }
    line == e { ne++; if (!inb) crossed = 1; inb = 0; next }
    inb { print }
    END { if (nb != 1 || ne != 1 || crossed || inb) exit 1 }
  ' "$1"
}

# _adb_pl_hits_raw <file> — one `<class>TAB<site>TAB<fix>TAB<thread>TAB<pr>TAB<date>TAB<summary>`
# record per hit; the summary field is empty when the record carries none.
#
# Splits on the backtick, which is exact: the four operative fields are the first four code spans
# and none of them may contain one (enforced by the validators at write time). A line inside the
# region that does not carry four spans is MALFORMED and fails the whole read (1) rather than being
# skipped — skipping is how a count silently drops.
#
# THE SUMMARY IS EMITTED, NOT DISCARDED. This parser used to reconstruct the whole suffix and then
# print only the PR number, so no reader ever saw the summary again — and a hand edit or a merge
# that put `<!--` into one passed `verify`, `classes`, `due` and `checklist` while GitHub rendered
# everything after it, up to the hits end marker, as one HTML comment. The writer refuses that
# text; the readers now apply the writer's own predicate to it (`_adb_pl_hits`), which is the
# refuse-whole contract holding for the display field as it already did for the operative ones.
# Reported by the declared reviewer on PR #429.
_adb_pl_hits_raw() {
  local region
  region="$(_adb_pl_region "$1" "$_ADB_PL_HIT_BEGIN" "$_ADB_PL_HIT_END")" || return 1
  printf '%s\n' "$region" | awk -F'`' '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == "" { next }
    {
      if (NF < 9)             { bad = 1; exit }
      # THE PREFIX, not just the span count and the suffix. `FORGED `class` …` carries nine fields
      # and a well-formed tail, so a hand edit or a merge could put anything before the first code
      # span and still be counted toward a promotion. The writer emits exactly `- ` there.
      # Reported by the declared reviewer on PR #429.
      if ($1 != "- ")         { bad = 1; exit }
      if ($2 == "" || $4 == "" || $6 == "" || $8 == "") { bad = 1; exit }
      # THE WHOLE SUFFIX, not a substring search. `match($9, /PR #[0-9]+/)` found its pattern
      # ANYWHERE, so a hand-edited `garbage PR #999xyz no-date` parsed cleanly and was attributed
      # to PR 999 — malformed data counted against a pull request it never belonged to. The writer
      # emits exactly ` PR #<n> <date>` with an optional ` — <summary>`, so that is what is
      # required. Reconstructed across $9..$NF because a summary may itself contain backticks.
      # Reported by the declared reviewer on PR #429.
      suffix = $9
      for (i = 10; i <= NF; i++) suffix = suffix "`" $i
      # `.+` AFTER THE SEPARATOR, not `.*`: the writer never emits a separator with nothing behind
      # it, so `PR #1 2026-08-24 — ` is a hand edit and is refused rather than read as no summary.
      if (suffix !~ /^ PR #[0-9]+ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]( — .+)?$/) { bad = 1; exit }
      pr = suffix
      sub(/^ PR #/, "", pr)
      sub(/ .*$/, "", pr)
      dt = suffix
      sub(/^ PR #[0-9]+ /, "", dt)
      sub(/ .*$/, "", dt)
      summ = suffix
      if (!sub(/^ PR #[0-9]+ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] — /, "", summ)) summ = ""
      # A CONTROL CHARACTER IN THE SUMMARY IS REFUSED HERE, in awk, and not left to the shell
      # predicate alone: a TAB would split the field the shell reads, and `read` strips a trailing
      # one before `_adb_pl_ok_text` could see it. The predicate still runs on what arrives; this
      # is the structural half that makes what arrives the whole summary.
      if (summ ~ /[[:cntrl:]]/) { bad = 1; exit }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $4, $6, $8, pr, dt, summ
    }
    END { if (bad) exit 1 }
  '
}

# _adb_pl_hits <file> — the same records, but only if EVERY ONE obeys the grammar and no thread id
# repeats. This is the function every reader calls; `_adb_pl_hits_raw` exists for `verify`, which
# has to enumerate the bad records in order to name them.
#
# THE VALIDATION LIVES HERE RATHER THAN IN `verify`, and that placement is the whole finding. With
# the checks only in `verify`, a hand-edited or badly-merged ledger reached `classes`, `due`,
# `stats` and `checklist` unchallenged — and a duplicated thread id then counted one finding twice,
# carrying a class to a promotion nothing earned. `verify` reported 18 while `due` reported the
# class as ready, which is the "refused whole" claim being false at the readers that act on it.
#
# VALIDATED THROUGH THE WRITER'S OWN PREDICATES, not a second set of regexes here. The grammar has
# one home; a reader that re-spelled it would drift from the writer, and the drift would show up as
# records the writer cannot produce being accepted (or vice versa).
_adb_pl_hits() {
  local raw c s f th pr dt summ
  raw="$(_adb_pl_hits_raw "$1")" || return 1
  [ -n "$raw" ] || return 0
  local -A seen=()
  while IFS="$TAB" read -r c s f th pr dt summ; do
    [ -n "$c$s$f$th" ] || continue
    _adb_pl_ok_class  "$c"  || return 1
    _adb_pl_ok_span   "$s"  || return 1
    _adb_pl_ok_fix    "$f"  || return 1
    _adb_pl_ok_thread "$th" || return 1
    # THE PR IS REQUIRED, not optional-if-present. The raw parser emits an empty field when a
    # hand-edited record has lost its `PR #<n>` segment, and permitting that let the hit count
    # toward promotion while `stats --pr` omitted it — a per-PR figure lower than the records
    # actually attributable to that run, from a record the writer could never have produced.
    # Missing and invalid are now the same answer. Reported by the declared reviewer on PR #429.
    _adb_pl_ok_pr "$pr" || return 1
    _adb_pl_ok_date "$dt" || return 1
    # THE SUMMARY TOO, WITH THE WRITER'S PREDICATE. A summary is display, but it is display inside
    # a file whose structure is markup: `<!--` in it hides every record after it in the review
    # view, and the writer refuses exactly that. Empty means the record carries none.
    # Reported by the declared reviewer on PR #429.
    if [ -n "$summ" ]; then _adb_pl_ok_text "$summ" || return 1; fi
    # THE DUPLICATE IS A DEFECT, not a duplicate hit: `record` refuses one, so a pair here means a
    # hand edit or a merge that took both sides of the same record — and the count is now higher
    # than the number of findings that actually happened, in the direction that promotes.
    [ -z "${seen[$th]+x}" ] || return 1
    seen["$th"]=1
  done <<RAW
$raw
RAW
  printf '%s\n' "$raw"
}

# _adb_pl_promoted <file> — the promoted class slugs, one per line.
_adb_pl_promoted_raw() {
  local region
  region="$(_adb_pl_region "$1" "$_ADB_PL_CK_BEGIN" "$_ADB_PL_CK_END")" || return 1
  printf '%s\n' "$region" | awk -F'`' '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line == "" { next }
    # NF >= 3 AND A NON-EMPTY RULE BODY. A damaged line like ``- `collection-identity` `` splits
    # into three backtick fields with an empty third, so a count-only test accepted it — and
    # `checklist` then injected a class name carrying NO instruction into the gap-analysis and
    # self-review prompts, silently dropping the sweep that class had earned. The separator is
    # display; the TEXT after it is the contract. Reported by the declared reviewer on PR #429.
    {
      if (NF < 3 || $2 == "") { bad = 1; exit }
      # THE WRITER'"'"'S COMPLETE LINE SHAPE, and the rule TEXT emitted for validation. Requiring
      # only "non-empty after the class" accepted a suffix carrying bytes `promote` refuses — a tab
      # or a control character — and `checklist` then emitted that raw line straight into an
      # agent'"'"'s prompt. The shell side validates the text with the writer'"'"'s own predicate;
      # this side pins the shape it must arrive in. Reported by the declared reviewer on PR #429.
      # THE WHOLE LINE, not a field: a rule may itself contain code spans, so $NF is not the rule
      # and splitting on backticks cannot recover it. Strip the exact prefix the writer emits.
      # (No apostrophes in this comment: the awk program is a single-quoted shell string, and one
      # would close it — which is exactly how the first version of this line failed to parse.)
      rest = $0
      sub(/^- `[^`]*` — /, "", rest)
      if (rest == $0) { bad = 1; exit }   # the separator was not there in the writer'"'"'s form
      if (rest == "") { bad = 1; exit }
      printf "%s\t%s\n", $2, rest
    }
    END { if (bad) exit 1 }
  '
}

# _adb_pl_promoted <file> — the same slugs, but only if every rule names a valid class and no class
# appears twice. Same placement argument as `_adb_pl_hits`: a reader that skipped this would let a
# hand-edited checklist reach the prompt surface, and a class listed twice would make `promote`'s
# already-promoted check answer about the wrong entry.
_adb_pl_promoted() {
  local raw c rule out=""
  raw="$(_adb_pl_promoted_raw "$1")" || return 1
  [ -n "$raw" ] || return 0
  local -A seen=()
  while IFS="$TAB" read -r c rule; do
    [ -n "$c" ] || continue
    _adb_pl_ok_class "$c" || return 1
    # THE RULE TEXT, THROUGH THE WRITER'"'"'S OWN PREDICATE. `promote` refuses a tab, a newline, a
    # control character and an `<!-- adb:` marker; a hand edit or a merge can introduce any of them,
    # and `checklist` feeds this text to another agent. Validating only the class left the half
    # that actually reaches a prompt unchecked.
    _adb_pl_ok_text "$rule" || return 1
    [ -z "${seen[$c]+x}" ] || return 1
    seen["$c"]=1
    out="${out}${c}"$'\n'
  done <<RAW
$raw
RAW
  printf '%s' "$out"
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
    _adb_pl_ok_pr "$OPT_THRESHOLD" \
      || die "--threshold must be a positive whole number, got $(adb_display_value "$OPT_THRESHOLD")"
    printf '%s flag\n' "$OPT_THRESHOLD"; return 0
  fi
  # THE PRECEDENCE RULE IS `adb_toml_layered_get`'s, not this module's. It used to be a `for` loop
  # over the two manifests here, and that loop had a real defect the shared primitive does not:
  # `[ -n "$v" ] || continue` fell THROUGH an empty repo-level declaration to the global one, so a
  # project that wrote `threshold =` got the machine's value while believing it had set its own.
  # A higher-precedence layer that defines the key wins even when its value is unusable — that is
  # the whole point, and it is why the validation below fails loud instead of reading on.
  local layered _tfile _lrc
  layered="$(adb_toml_layered_get "$(adb_repo_root 2>/dev/null)/agents.toml" \
                                  "$(adb_global_manifest)" patterns threshold --with-layer)"; _lrc=$?
  # A MANIFEST THAT EXISTS BUT CANNOT BE READ IS A HARD ERROR, NOT THE BUILT-IN. The layered reader
  # returns 2 (unreadable) or 3 (contains a NUL byte) without consulting the next layer; treating
  # either as "undeclared" here handed the operator the built-in threshold in place of the one in
  # a file they could not read — the fall-through this function's own header forbids, by another
  # route. Reported by the declared reviewer on PR #429.
  case "$_lrc" in
    0|1) ;;
    2) printf 'pattern-ledger: an agents.toml exists but could not be read — refusing to fall back to a lower layer or the built-in threshold. Check %s and %s.\n' "$(adb_repo_root 2>/dev/null)/agents.toml" "$(adb_global_manifest)" >&2; return 2 ;;
    *) printf 'pattern-ledger: an agents.toml contains a NUL byte and is not TOML — refusing to read a threshold from it. Check %s and %s.\n' "$(adb_repo_root 2>/dev/null)/agents.toml" "$(adb_global_manifest)" >&2; return 2 ;;
  esac
  if [ "$_lrc" -eq 0 ]; then
    src="${layered%% *}"; v="${layered#* }"
    # THE RAW SCALAR MUST BE SYNTACTICALLY COMPLETE. `adb_toml_get` walks to the closing quote and,
    # not finding one, RECONSTRUCTS the value with both quotes — so `threshold = "2` (invalid TOML,
    # no closing quote) came back as `"2"`, unquoted to `2`, and was accepted. The reconstructed
    # value cannot be told from a well-formed one, so the source line is the only place the defect
    # still exists. Reported by the declared reviewer on PR #429.
    case "$src" in
      repo)   _tfile="$(adb_repo_root 2>/dev/null)/agents.toml" ;;
      global) _tfile="$(adb_global_manifest)" ;;
      *)      _tfile="" ;;
    esac
    if [ -n "$_tfile" ] && [ -f "$_tfile" ]; then
      # DUPLICATES TOO, in the same pass. `adb_toml_get` returns the FIRST assignment, so a manifest
      # declaring `threshold` twice was accepted and silently used the earlier value — the same
      # defect already fixed for `[mcp]`, in the sibling this scan is modelled on and which I did
      # not sweep. Reported by the declared reviewer on PR #429.
      if ! awk '
            # THE TABLE HEADER IS COUNTED TOO. A manifest declaring `[patterns]` twice is invalid
            # TOML even when `threshold` appears once — the same case already fixed for `[mcp]`,
            # in the scan this one is modelled on. Reported by the declared reviewer on PR #429.
            # SAME NORMALIZATION AS THE SHARED READER, for the same reason its sibling in
            # docs-lib needed it: a legal `[patterns] # …` header left `intbl` unset, so neither
            # the repeated-table rule nor the duplicate-key rule could fire.
            # Reported by the declared reviewer on PR #429.
            /^[[:space:]]*\[/ { hdr = $0; sub(/^[[:space:]]*\[/, "", hdr)
                                inq = 0
                                for (i = 1; i <= length(hdr); i++) {
                                  c = substr(hdr, i, 1)
                                  if (c == "\"") { inq = !inq; continue }
                                  if (c == "#" && !inq) { hdr = substr(hdr, 1, i - 1); break }
                                }
                                sub(/\][[:space:]]*$/, "", hdr); sub(/[[:space:]]+$/, "", hdr)
                                intbl = (hdr == "patterns"); if (intbl && ++tbl > 1) { bad = 1; exit }
                                next }
            intbl && $0 ~ /^[[:space:]]*threshold[[:space:]]*=/ {
              if (++seen > 1) { bad = 1; exit }
              # A complete scalar: a bare integer, or a fully quoted one. Trailing comment allowed.
              # NO LEADING ZEROS: TOML integers may not carry them, so `02` and `08` are invalid
              # even though the domain check would accept the value they parse to. Exactly `0` or
              # a nonzero first digit; the positive-domain check then rejects `0` itself.
              if ($0 ~ /^[[:space:]]*threshold[[:space:]]*=[[:space:]]*(0|[1-9][0-9]*)[[:space:]]*(#.*)?$/) next
              if ($0 ~ /^[[:space:]]*threshold[[:space:]]*=[[:space:]]*"(0|[1-9][0-9]*)"[[:space:]]*(#.*)?$/) next
              bad = 1; exit
            }
            END { exit (bad ? 1 : 0) }
          ' "$_tfile"; then
        printf 'pattern-ledger: [patterns] threshold in the %s manifest is not a single, complete TOML scalar — an unterminated quote, or the key declared more than once. Refusing rather than guessing what was meant.\n' "$src" >&2
        return 2
      fi
    fi
    v="$(adb_toml_unquote "$v")"
    if ! _adb_pl_ok_pr "$v"; then
      printf 'pattern-ledger: [patterns] threshold in the %s manifest is %s — must be a positive whole number\n' \
        "$src" "$(adb_display_value "$v")" >&2
      return 2
    fi
    printf '%s %s\n' "$v" "$src"; return 0
  fi
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
# How long to wait for the write lock, and when to declare an existing one abandoned. The wait is
# short because every holder does one read-modify-write of a small file; the stale age is generous
# because breaking a LIVE lock is the failure that loses data, and waiting a little longer is not.
# OVERRIDABLE FROM THE ENVIRONMENT, following `ADB_DISPATCH_TIMEOUT_SECS`'s precedent, because a
# bound nothing can vary is a bound nothing can test: the fall-through-to-the-wait behaviour is
# only observable by watching the writer actually give up. A stock clone needs no environment.
# Non-numeric or zero values are refused loudly rather than silently taking the default — a wait
# the operator thinks they shortened but did not is the same class of lie as a threshold that
# quietly falls back.
_ADB_PL_LOCK_WAIT_SECS="${ADB_PATTERN_LOCK_WAIT_SECS:-30}"
_ADB_PL_LOCK_STALE_SECS="${ADB_PATTERN_LOCK_STALE_SECS:-300}"
# AND BOUNDED IN WIDTH, the same discipline `pr-watch.sh` applies to `--max-rounds`. An all-digit
# value wider than a shell integer makes `[ "$waited" -ge "$bound" ]` error and evaluate FALSE on
# every iteration — so the advertised timeout is not merely wrong, it is gone, and the writer waits
# forever. Reported by the declared reviewer on PR #429.
case "$_ADB_PL_LOCK_WAIT_SECS" in
  ''|*[!0-9]*|0) printf 'pattern-ledger: ADB_PATTERN_LOCK_WAIT_SECS="%s" is not a positive whole number of seconds\n' "$_ADB_PL_LOCK_WAIT_SECS" >&2; exit 2 ;;
esac
[ "${#_ADB_PL_LOCK_WAIT_SECS}" -le 18 ] || { printf 'pattern-ledger: ADB_PATTERN_LOCK_WAIT_SECS is too large to compare as an integer\n' >&2; exit 2; }
case "$_ADB_PL_LOCK_STALE_SECS" in
  ''|*[!0-9]*|0) printf 'pattern-ledger: ADB_PATTERN_LOCK_STALE_SECS="%s" is not a positive whole number of seconds\n' "$_ADB_PL_LOCK_STALE_SECS" >&2; exit 2 ;;
esac
[ "${#_ADB_PL_LOCK_STALE_SECS}" -le 18 ] || { printf 'pattern-ledger: ADB_PATTERN_LOCK_STALE_SECS is too large to compare as an integer\n' >&2; exit 2; }

# _adb_pl_owner_gone <lock-dir> — can we PROVE the lock's owner is no longer running?
#
# True only when the lock records a host we are on and a pid that no longer exists. Everything else
# — no metadata, an unreadable file, another host, a pid still alive — answers NO, because the cost
# of a wrong "yes" is two writers in the critical section and the cost of a wrong "no" is a wait
# that ends in a loud, actionable refusal. Cross-host locks on a shared filesystem are therefore
# never reclaimed automatically, and the diagnostic says so rather than pretending.
_adb_pl_owner_gone() {
  local meta="$1/meta" host pid
  [ -r "$meta" ] || return 1
  IFS="$TAB" read -r host pid < "$meta" 2>/dev/null || return 1
  [ -n "$host" ] && [ -n "$pid" ] || return 1
  [ "$host" = "$(uname -n 2>/dev/null)" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # `ps -p`, NOT `kill -0`. `kill -0` fails for BOTH "no such process" (ESRCH) and "not yours"
  # (EPERM), and treating every failure as death means a contender running as another user reclaims
  # a LIVE lock in a shared checkout — verified by the reviewer, running the predicate as `nobody`
  # against a root-owned live pid. `ps -p` answers about existence regardless of ownership.
  # If `ps` is unavailable at all we cannot prove anything, which reads as alive.
  command -v ps >/dev/null 2>&1 || return 1
  ps -p "$pid" >/dev/null 2>&1 && return 1
  return 0
}

# _adb_pl_lock <ledger> — take the ledger's write lock, or fail. Prints nothing on success.
#
# THE LOCK CARRIES AN OWNER TOKEN, and `_adb_pl_unlock` removes the directory only while that token
# is still the one inside it. Without it a writer paused past the stale interval — suspended,
# swapped out, stopped at a breakpoint — could resume after another writer had reclaimed its lock
# and then unlock its SUCCESSOR's, letting a third process into the critical section.
# Reported by the declared reviewer on PR #429.
_adb_pl_lock() {
  local dir="$1.lock" waited=0 age tomb
  _ADB_PL_LOCK_TOKEN="$$.$RANDOM.$RANDOM"
  while ! mkdir "$dir" 2>/dev/null; do
    # A LOCK OLDER THAN THE STALE AGE IS BROKEN, so a writer killed mid-insert cannot wedge the
    # ledger permanently. `adb_age_secs` is the shared primitive for this question; if it cannot
    # answer, the lock is treated as live, which fails closed toward waiting rather than toward
    # two concurrent writers.
    age="$(adb_age_secs "$dir" 2>/dev/null)" || age=""
    # AGE IS NOT DEATH, and reclaiming on age alone is what made this unsafe. A writer suspended
    # past the stale interval is still ALIVE and may still be holding a prepared replacement file:
    # reclaim its lock, let a successor update the ledger, and the original resumes and renames its
    # stale copy over the successor's work. The tokenized release stops it deleting their LOCK; it
    # cannot stop that write. So the owner must be PROVEN GONE before anything is reclaimed.
    # Reported by the declared reviewer on PR #429.
    if [ -n "$age" ] && [ "$age" -gt "$_ADB_PL_LOCK_STALE_SECS" ] && _adb_pl_owner_gone "$dir"; then
      # RENAME TO A TOMBSTONE, THEN DELETE — never `rmdir` the observed directory. Two writers can
      # see the same stale lock: with a bare removal the first deletes it and takes a FRESH lock,
      # and the second then deletes the first writer's live lock and takes one too, so both enter
      # the critical section during recovery. `mv` onto a name that does not exist is a single
      # rename(2): exactly one writer wins it, and the loser's `mv` fails because the source is
      # already gone. Reported by the declared reviewer on PR #429.
      tomb="$dir.stale.$$.$RANDOM"
      if mv "$dir" "$tomb" 2>/dev/null; then
        printf 'pattern-ledger: broke a stale write lock (%ss old): %s\n' "$age" "$dir" >&2
        # A TOMBSTONE THAT CANNOT BE REMOVED IS A LOUD FAILURE, not debris left in silence. In a
        # group-writable checkout a contender can RENAME the dead owner's 0755 lock directory
        # (the parent is writable) but cannot unlink `meta` or the token inside it, so this `rm`
        # failed, the contender carried on, and an unignored `patterns.md.lock.stale.*` tree was
        # left in the working tree — where the resolver's dirty-tree guard then aborts every later
        # round. Refusing here names the path; proceeding would hide it.
        # Reported by the declared reviewer on PR #429.
        if ! rm -rf "$tomb" 2>/dev/null || [ -e "$tomb" ]; then
          printf 'pattern-ledger: could not remove the stale lock %s after renaming it — it is owned by another user, or its contents are not deletable here. Nothing was written; remove it by hand.\n' "$tomb" >&2
          return 1
        fi
        continue
      fi
      # A FAILED RECLAMATION FALLS THROUGH TO THE WAIT, it does not retry immediately. An
      # unconditional `continue` here neither slept nor incremented `waited`, so a rename that can
      # never succeed — an unwritable parent, a lock owned by another user — busy-spun forever and
      # the advertised 30-second bound never applied. Reported by the declared reviewer on PR #429.
    fi
    if [ "$waited" -ge "$_ADB_PL_LOCK_WAIT_SECS" ]; then
      printf 'pattern-ledger: could not take the write lock after %ss: %s\n' "$waited" "$dir" >&2
      printf 'pattern-ledger: another writer holds it. Nothing was written.\n' >&2
      printf 'pattern-ledger: a lock is only reclaimed when its owner is PROVEN gone (same host, pid\n' >&2
      printf 'pattern-ledger: no longer running). A live-but-stuck writer, or one on another host, is\n' >&2
      printf 'pattern-ledger: never reclaimed automatically — remove %s by hand once you are sure.\n' "$dir" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # THE TOKEN IS A SUBDIRECTORY, not a file, and that is what makes release atomic. Reading an
  # `owner` file and then deleting the directory is check-then-act: a successor can reclaim the
  # stale lock and create a fresh one between the read and the `rm`, and the original writer then
  # deletes THEIR lock. With the token as a directory, release is `rmdir "$dir/$TOKEN"` — which can
  # only ever remove our own marker — followed by `rmdir "$dir"`, which succeeds only while the
  # directory is empty, so a successor's marker keeps their lock alive.
  # Reported by the declared reviewer on PR #429.
  #
  # A FAILURE HERE MEANS THE PARENT WAS YANKED between our winning `mkdir` and this one — a
  # stale-breaker renaming it away. We never held the lock, so there is nothing to release: start
  # the whole acquisition again rather than returning success over a lock we do not have.
  if ! mkdir "$dir/$_ADB_PL_LOCK_TOKEN" 2>/dev/null; then
    _adb_pl_lock "$1"
    return $?
  fi
  # WHO WE ARE, so a later contender can tell a dead owner from a slow one. Advisory only: it is
  # read to decide RECLAMATION, never to decide release, so a torn or missing write degrades to
  # "cannot prove dead", which is the safe answer.
  printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "$$" > "$dir/meta" 2>/dev/null || true
  return 0
}

# Remove the lock ONLY while it is still ours. A token that no longer matches means our lock was
# reclaimed as stale and somebody else holds this directory now — deleting it would hand a third
# process into the critical section alongside them. An unreadable token is treated as not-ours for
# the same reason: fail toward leaving a lock that expires on its own.
_adb_pl_unlock() {
  local dir="$1.lock"
  [ -n "${_ADB_PL_LOCK_TOKEN:-}" ] || return 0
  # TWO rmdirs, NO test. `rmdir` is the check: the first removes only the marker we created, and
  # fails harmlessly if our lock was reclaimed and the directory now holds somebody else's. The
  # second succeeds only while the directory is empty, so a successor's marker keeps their lock.
  # Neither can delete a lock we do not hold, which a read-then-delete could.
  rmdir "$dir/$_ADB_PL_LOCK_TOKEN" 2>/dev/null || return 0
  # THE METADATA GOES WITH IT. `meta` is a FILE inside the lock directory, so leaving it there makes
  # the `rmdir` below fail forever and the lock leaks — every later writer then waits out its bound
  # and gives up. Removing it is safe precisely here: the `rmdir` above succeeding proves this was
  # our lock, and nobody can create `$dir` while it still exists.
  rm -f "$dir/meta" 2>/dev/null
  rmdir "$dir" 2>/dev/null || true
}

_adb_pl_insert() {
  local file="$1" end="$2" line="$3" tmp rc=0 held_here=0
  # THE CALLER MAY ALREADY HOLD THE LOCK, and for `record` and `promote` it must — see their
  # headers. Locking only the read-modify-write here fixed lost updates and left the real race
  # untouched: both commands CHECK a precondition (this thread is not recorded; this class has no
  # rule) and then ACT on it, so two runs could both pass the check outside the lock and then
  # serialize two inserts of the same thing. Measured by the reviewer: 30 parallel `record` calls
  # for one thread produced 30 rows, which every reader then refuses as a duplicate.
  # `_ADB_PL_LOCK_HELD` is how a holder says so. Reported by the declared reviewer on PR #429.
  if [ "${_ADB_PL_LOCK_HELD:-}" != "$file" ]; then
    _adb_pl_lock "$file" || return 1
    held_here=1
  fi
  tmp="$(mktemp "${file}.XXXXXX")" || { [ "$held_here" -eq 1 ] && _adb_pl_unlock "$file"; return 1; }
  # THE LEDGER KEEPS ITS MODE. `mktemp` creates 0600 and the rename below installs that over the
  # tracked file, so with an ordinary umask the first `record` silently took `patterns.md` from
  # 0644 to 0600 — invisible in the diff, because git tracks only the execute bit, and enough to
  # stop everyone else in a shared checkout from reading the project's ledger. `cp -p` copies the
  # existing mode onto the temp (the redirection below truncates the content but keeps the mode),
  # which avoids `stat`'s incompatible flags between macOS and GNU.
  # Reported by the declared reviewer on PR #429.
  cp -p "$file" "$tmp" 2>/dev/null || true
  if ! ADB_PL_LINE="$line" awk -v e="$end" '
        { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
        l == e && !done { print ENVIRON["ADB_PL_LINE"]; done = 1 }
        { print }
        END { if (!done) exit 1 }
      ' "$file" > "$tmp"; then
    rm -f "$tmp"; [ "$held_here" -eq 1 ] && _adb_pl_unlock "$file"; return 1
  fi
  # THE LEASE IS RE-VERIFIED IMMEDIATELY BEFORE THE RENAME. Everything above — reading the file,
  # running awk, writing the replacement — takes time, and a writer suspended across it may have had
  # its lock reclaimed and a successor may have updated the ledger meanwhile. Renaming a replacement
  # built from the PRE-successor contents would silently discard their work. Reclamation now refuses
  # to take a lock whose owner is still alive, so this window should never open; checking anyway is
  # what makes that a belt rather than an argument, and it costs one `[ -d ]`.
  # Reported by the declared reviewer on PR #429.
  if [ ! -d "$file.lock/${_ADB_PL_LOCK_TOKEN:-}" ]; then
    printf 'pattern-ledger: this writer'"'"'s lock was revoked while it prepared its update — discarding it rather than overwriting whoever holds the ledger now.\n' >&2
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; rc=1; }
  [ "$held_here" -eq 1 ] && _adb_pl_unlock "$file"
  return "$rc"
}

# --- subcommands --------------------------------------------------------------------------------

cmd_record() {
  [ -n "$OPT_CLASS" ]  || die "record: --class is required"
  [ -n "$OPT_SITE" ]   || die "record: --site is required"
  [ -n "$OPT_FIX" ]    || die "record: --fix is required"
  [ -n "$OPT_PR" ]     || die "record: --pr is required"
  [ -n "$OPT_THREAD" ] || die "record: --thread is required"

  _adb_pl_ok_class "$OPT_CLASS" || {
    printf 'pattern-ledger: refusing class %s — a class is [a-z][a-z0-9-]* up to 48 chars. It is
  the unit recurrence is counted in, so it has to be the SAME string next time.\n' "$(adb_display_value "$OPT_CLASS")" >&2; exit 19; }
  _adb_pl_ok_span "$OPT_SITE" || {
    printf 'pattern-ledger: refusing site %s — no backtick, tab, newline or control character.\n' "$(adb_display_value "$OPT_SITE")" >&2; exit 19; }
  _adb_pl_ok_fix "$OPT_FIX" || {
    printf 'pattern-ledger: refusing fix %s — 7-40 lowercase hex digits (a commit sha).\n' "$(adb_display_value "$OPT_FIX")" >&2; exit 19; }
  _adb_pl_ok_pr "$OPT_PR" || {
    printf 'pattern-ledger: refusing pr %s — a positive whole number.\n' "$(adb_display_value "$OPT_PR")" >&2; exit 19; }
  _adb_pl_ok_thread "$OPT_THREAD" || {
    printf 'pattern-ledger: refusing thread %s — [A-Za-z0-9_=-] up to 256 chars (a review thread node id).\n' "$(adb_display_value "$OPT_THREAD")" >&2; exit 19; }

  local date="${OPT_DATE:-$(date -u +%Y-%m-%d)}"
  _adb_pl_ok_date "$date" || {
    printf 'pattern-ledger: refusing date %s — a real calendar date, YYYY-MM-DD.\n' "$(adb_display_value "$date")" >&2; exit 19; }

  local summary="${OPT_SUMMARY:-}"
  if [ -n "$summary" ]; then
    _adb_pl_ok_text "$summary" || {
      printf 'pattern-ledger: refusing summary — one printable line, no tab, no newline, and it may
  not contain the string "<!-- adb:" (which would close a region and truncate the ledger).\n' >&2; exit 19; }
  fi

  local ledger; ledger="$(_adb_pl_resolve_ledger)" || exit 20

  # THE PARENT DIRECTORY IS MADE FIRST — the lock lives beside the ledger, so `_adb_pl_lock` needs
  # somewhere to mkdir. Creating the LEDGER, though, waits for the lock.
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || { printf 'pattern-ledger: cannot create %s\n' "$(dirname "$ledger")" >&2; exit 20; }

  # EXACTLY-ONCE, keyed on the review thread. The resolver records BEFORE it resolves the thread
  # (a crash between the two must not lose the signal), so a re-run over the same pull request
  # re-offers hits that are already here. That is the ordinary case, so it exits 10 and says
  # nothing alarming — it is not a failure and must not read like one.
  # THE LOCK SPANS CHECK-THEN-ACT. The dedupe test below and the insert that follows it are one
  # decision: two runs that both read "this thread is not recorded" and then both insert produce a
  # duplicate that every reader refuses. Measured by the reviewer: 30 parallel `record` calls for
  # one thread produced 30 rows. Taking the lock HERE, not inside `_adb_pl_insert`, is what makes
  # the check and the act one operation. Reported by the declared reviewer on PR #429.
  _adb_pl_lock "$ledger" || exit 20
  export _ADB_PL_LOCK_HELD="$ledger"
  # THE TRAP TEXT IS FIXED; the path travels in a VARIABLE. `trap "… '$ledger'" EXIT` interpolates
  # the path into shell source that `trap` evaluates later — so a ledger under a directory named
  # `x'"'"'; touch INJECTED; #` executed that command when the trap fired. Reproduced by the
  # reviewer on PR #429. Single quotes here mean the handler is a constant string and the expansion
  # happens at trap time, where a path is an argument and not syntax.
  _ADB_PL_LOCKED_FILE="$ledger"
  trap '_adb_pl_unlock "$_ADB_PL_LOCKED_FILE"' EXIT

  # CREATED INSIDE THE CRITICAL SECTION, and re-checked here rather than above. Two processes
  # recording the first hits concurrently could both see the ledger absent; the slower one then
  # wrote the template over a file the faster one had already created AND inserted into, erasing
  # that hit before either locked insert finished. The existence test has to happen where the
  # decision is protected. Reported by the declared reviewer on PR #429.
  if [ ! -f "$ledger" ]; then
    # STAGED AND RENAMED, like every other write. A direct redirection that is killed part-way — or
    # hits a full filesystem — leaves a HALF-WRITTEN ledger: the call returns 20, and every retry
    # then finds the file present and returns 18, so a first-run failure needs manual repair.
    # Reported by the declared reviewer on PR #429.
    _tpl="$(mktemp "${ledger}.XXXXXX")" || { printf 'pattern-ledger: cannot stage %s\n' "$ledger" >&2; exit 20; }
    # AND THE NEW LEDGER GETS THE MODE A NEW FILE WOULD HAVE. `mktemp` creates 0600 and the rename
    # installs it, so staging the template silently made the FIRST ledger unreadable to everyone
    # else in a shared checkout — the same defect the update path already fixes by copying the
    # existing mode, reappearing on the one path that has no existing file to copy from. Derived
    # from the umask, which is what an ordinary `>` redirection would have honoured.
    chmod "$(printf '%o' "$(( 0666 & ~0$(umask) ))")" "$_tpl" 2>/dev/null || true
    if ! _adb_pl_template > "$_tpl" || ! mv "$_tpl" "$ledger"; then
      rm -f "$_tpl"
      printf 'pattern-ledger: cannot write %s\n' "$ledger" >&2; exit 20
    fi
  fi
  [ -r "$ledger" ] && [ -w "$ledger" ] || { printf 'pattern-ledger: %s is not readable and writable\n' "$ledger" >&2; exit 20; }

  local hits _tpl
  # BOTH REGIONS, before appending anything. Validating only the hits half let `record` report a
  # hit written successfully into a file from which no reader can then read a count or a checklist
  # — the refuse-whole contract holding for reads and not for writes. Same partial-validation shape
  # as the PR field and the empty array element: the check covered less than the consumers do.
  # Reported by the declared reviewer on PR #429.
  hits="$(_adb_pl_hits "$ledger")" || { printf 'pattern-ledger: %s does not parse (the hits region) — refusing to append to a ledger whose existing records cannot be read\n' "$ledger" >&2; exit 18; }
  _adb_pl_promoted "$ledger" >/dev/null || { printf 'pattern-ledger: %s does not parse (the checklist region) — refusing to append to a ledger every reader would then refuse\n' "$ledger" >&2; exit 18; }
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
  # THE PROMOTED LIST TRAVELS THROUGH THE ENVIRONMENT, not through `awk -v`. Its value is
  # MULTI-LINE, and `-v` cannot carry a newline — awk dies with "newline in string" the moment a
  # second class is promoted. Every fixture in the suite had at most one, so 120 assertions passed
  # over a `classes`, `due`, `stats` and `promote` that break on any real project's second
  # promotion. `_adb_pl_insert` in this same file already documents this exact trap and uses
  # ENVIRON for it; reintroducing it 200 lines later is what the promoted `partial-validation` rule
  # means by "grep the siblings". Found by dogfooding this ledger on its own pull request.
  printf '%s\n' "$hits" | ADB_PL_PROM="$promoted" awk -F'\t' -v TAB="$TAB" '
    BEGIN { n = split(ENVIRON["ADB_PL_PROM"], p, "\n"); for (i = 1; i <= n; i++) if (p[i] != "") isprom[p[i]] = 1 }
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
  _adb_pl_ok_class "$OPT_CLASS" || { printf 'pattern-ledger: refusing class %s\n' "$(adb_display_value "$OPT_CLASS")" >&2; exit 19; }
  _adb_pl_ok_text "$OPT_RULE"   || {
    printf 'pattern-ledger: refusing rule — one printable line of at most %s bytes, no tab, no newline, and no HTML comment marker.\n' "$_ADB_PL_TEXT_MAX_BYTES" >&2; exit 19; }

  local ledger t tsrc
  read -r t tsrc < <(_adb_pl_threshold) || exit 2
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || { printf 'pattern-ledger: no ledger at %s — nothing has been recorded yet\n' "$ledger" >&2; exit 12; }

  # BOTH REGIONS, BEFORE THE EARLY RETURN. The `already promoted` arm below exits 13 without ever
  # reaching `cmd_classes`, so a ledger whose HITS region was damaged reported "already has a
  # checklist rule" and the resolver carried on over a file every reader is documented to refuse
  # whole. Validating here puts the refuse-whole contract ahead of every exit from this command,
  # not just the ones that happen to read the hits. Reported by the declared reviewer on PR #429.
  # SAME CRITICAL SECTION AS `record`, and for the same reason: two runs that both read "this
  # class has no rule yet" would both append one, and the reviewer measured that too.
  _adb_pl_lock "$ledger" || exit 20
  export _ADB_PL_LOCK_HELD="$ledger"
  # THE TRAP TEXT IS FIXED; the path travels in a VARIABLE. `trap "… '$ledger'" EXIT` interpolates
  # the path into shell source that `trap` evaluates later — so a ledger under a directory named
  # `x'"'"'; touch INJECTED; #` executed that command when the trap fired. Reproduced by the
  # reviewer on PR #429. Single quotes here mean the handler is a constant string and the expansion
  # happens at trap time, where a path is an argument and not syntax.
  _ADB_PL_LOCKED_FILE="$ledger"
  trap '_adb_pl_unlock "$_ADB_PL_LOCKED_FILE"' EXIT

  local promoted count
  _adb_pl_hits "$ledger" >/dev/null || { printf 'pattern-ledger: %s does not parse (the hits region)\n' "$ledger" >&2; exit 18; }
  promoted="$(_adb_pl_promoted "$ledger")" || { printf 'pattern-ledger: %s does not parse (the checklist region)\n' "$ledger" >&2; exit 18; }
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

  # THE AGGREGATE BUDGET, AT THE WRITE. A rule that fits its own bound can still be the one that
  # pushes the emitted checklist past the prompt budget; refusing it here, naming the number, is
  # what keeps `checklist`'s 21 an event only a hand edit or a merge can cause.
  local ckregion newsize
  ckregion="$(_adb_pl_region "$ledger" "$_ADB_PL_CK_BEGIN" "$_ADB_PL_CK_END")" \
    || { printf 'pattern-ledger: %s does not parse (the checklist region)\n' "$ledger" >&2; exit 18; }
  newsize=$(( $(printf '%s\n' "$ckregion" | awk 'NF { print }' | LC_ALL=C wc -c | tr -d ' ') \
            + $(printf -- '- `%s` — %s\n' "$OPT_CLASS" "$OPT_RULE" | LC_ALL=C wc -c | tr -d ' ') ))
  if [ "$newsize" -gt "$_ADB_PL_CHECKLIST_MAX_BYTES" ]; then
    printf 'pattern-ledger: refusing to promote %s — the checklist would be %s bytes, over the %s-byte prompt budget. Retire or tighten a rule first.\n' \
      "$OPT_CLASS" "$newsize" "$_ADB_PL_CHECKLIST_MAX_BYTES" >&2
    exit 19
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
  # THE PROMPT BUDGET, BEFORE ANYTHING IS EMITTED. Both consumers inject this output whole into an
  # agent's context, so an oversized region would crowd out the instructions it is meant to
  # sharpen. `promote` keeps the file under the bound; this catches what a hand edit or a merge
  # put there, and refuses loudly (21) rather than emitting a truncated or crowding payload.
  # Reported by the declared reviewer on PR #429.
  local emitted size
  emitted="$(printf '%s\n' "$region" | awk 'NF { print }')"
  size="$(printf '%s\n' "$emitted" | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$size" -gt "$_ADB_PL_CHECKLIST_MAX_BYTES" ]; then
    printf 'pattern-ledger: the promoted checklist is %s bytes, over the %s-byte prompt budget — refusing to emit it into a prompt. Retire or tighten rules in %s.\n' \
      "$size" "$_ADB_PL_CHECKLIST_MAX_BYTES" "$ledger" >&2
    exit 21
  fi
  if [ -n "$emitted" ]; then printf '%s\n' "$emitted"; fi
}

# `stats` — the numbers /resolve-pr-threads' summary reports. #421's own honest boundary says the
# observable is the finding-per-round trend, so the loop has to keep printing it: a learning
# mechanism whose effect cannot be seen in that number is not learning.
#
# `recurring` counts HITS IN CLASSES AT OR OVER THE THRESHOLD — not the number of such classes.
# That is the quantity that should fall as the checklist starts working: classes accumulate
# forever, while repeat hits in a known class are exactly the avoidable ones.
cmd_stats() {
  local ledger t tsrc hits total=0 recurring=0 classes=0 promoted=0 thispr=0 prrecur=0 prnew=0
  # THE FILTER IS VALIDATED, or a mistyped one is indistinguishable from a real pull request with
  # no findings: `--pr not-a-pr` and `--pr 0` both returned success with every PR-scoped metric at
  # zero, which is a falsely clean summary for any caller outside the workflow's own numeric
  # parser. Same predicate `record` uses. Reported by the declared reviewer on PR #429.
  if [ -n "$OPT_PR" ] && ! _adb_pl_ok_pr "$OPT_PR"; then
    die "stats: --pr must be a positive whole number, got $(adb_display_value "$OPT_PR")"
  fi
  read -r t tsrc < <(_adb_pl_threshold) || exit 2
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  if [ ! -f "$ledger" ]; then
    # ABSENT IS ITS OWN FACT, emitted as a field rather than left to be inferred from zeros. The
    # resolver's summary is required to distinguish "this project has no ledger yet" from "the
    # ledger is empty", and it could not: `stats` returned 0 with zero-valued fields for both, so
    # the workflow's own "no ledger yet" arm was unreachable. A caller must not have to stat the
    # file to answer a question this command already knows.
    # Reported by the declared reviewer on PR #429.
    printf 'ledger\tabsent\n'
    printf 'hits\t0\nclasses\t0\nrecurring\t0\npromoted\t0\nthreshold\t%s\nthreshold-source\t%s\n' "$t" "$tsrc"
    [ -n "$OPT_PR" ] && printf 'pr-hits\t0\npr-recurring\t0\npr-new-classes\t0\n'
    exit 0
  fi
  hits="$(_adb_pl_hits "$ledger")" || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  # READ, THEN COUNT — two statements. As one pipeline this depended on `pipefail` to surface
  # `_adb_pl_promoted`'s status, and a pipeline's `$?` is otherwise its LAST command's: `tr` always
  # succeeds, so a malformed checklist region would have been counted as zero promoted rules
  # instead of refusing. It happens to be correct today because this file sets `pipefail`, which
  # is exactly the kind of load-bearing implicitness a later edit removes without noticing.
  local promoted_raw
  promoted_raw="$(_adb_pl_promoted "$ledger")" \
    || { printf 'pattern-ledger: %s does not parse\n' "$ledger" >&2; exit 18; }
  promoted="$(printf '%s\n' "$promoted_raw" | awk 'NF' | wc -l | tr -d ' ')"
  if [ -n "$hits" ]; then
    total="$(printf '%s\n' "$hits" | awk 'NF' | wc -l | tr -d ' ')"
    classes="$(printf '%s\n' "$hits" | awk -F'\t' 'NF && $1 != "" { c[$1] } END { print length(c) }')"
    recurring="$(printf '%s\n' "$hits" | awk -F'\t' -v t="$t" '
      NF && $1 != "" { c[$1]++; rows[NR] = $1 }
      END { n = 0; for (i in rows) if (c[rows[i]] >= t) n++; print n }')"
    if [ -n "$OPT_PR" ]; then
      thispr="$(printf '%s\n' "$hits" | awk -F'\t' -v p="$OPT_PR" '$5 == p { n++ } END { print n + 0 }')"
      # RECURRING HITS *IN THIS PR*, decided by LIFETIME class counts. The unscoped `recurring`
      # below is a lifetime figure over an append-only file, so it can only ever rise — and it
      # jumps by every prior hit at the moment a class crosses the threshold. It therefore cannot
      # carry the per-round trend the resolve summary is judged by, which is the one number #421
      # says makes the mechanism falsifiable. Lifetime counts still decide WHICH classes are
      # recurring; only the reported count is filtered.
      # Reported by the declared reviewer on PR #429.
      # CLASSES FIRST SEEN IN THIS PR — decided by the record DATE, not by row position. The hits
      # region is append-only on one branch, but the ledger's own header tells two branches that
      # both appended to take both sides of the conflict, and nothing says in which order: a
      # later PR's row can land above an earlier merged row of the same class, and a first-row
      # test then credited the class to the wrong pull request. The date is the ordering fact
      # every record already carries and a merge cannot reorder. What it cannot settle is two PRs
      # recording one class on the SAME day, where row order still decides — a residue of the
      # day-resolution stamp, stated rather than hidden. `promoted this round` is NOT derivable —
      # nothing timestamps a promotion — so the workflow captures that from its own `promote`
      # calls rather than this command inventing a number for it.
      # Reported by the declared reviewer on PR #429.
      prnew="$(printf '%s\n' "$hits" | awk -F'\t' -v p="$OPT_PR" '
        NF && $1 != "" { if (!($1 in first) || $6 < firstd[$1]) { first[$1] = $5; firstd[$1] = $6 } }
        END { n = 0; for (k in first) if (first[k] == p) n++; print n + 0 }')"
      prrecur="$(printf '%s\n' "$hits" | awk -F'\t' -v t="$t" -v p="$OPT_PR" '
        NF && $1 != "" { c[$1]++; cls[NR] = $1; prs[NR] = $5 }
        END { n = 0; for (i in cls) if (c[cls[i]] >= t && prs[i] == p) n++; print n + 0 }')"
    fi
  fi
  printf 'ledger\tpresent\n'
  printf 'hits\t%s\nclasses\t%s\nrecurring\t%s\npromoted\t%s\nthreshold\t%s\nthreshold-source\t%s\n' \
    "$total" "$classes" "$recurring" "$promoted" "$t" "$tsrc"
  [ -n "$OPT_PR" ] && printf 'pr-hits\t%s\npr-recurring\t%s\npr-new-classes\t%s\n' "$thispr" "$prrecur" "$prnew"
  return 0
}

# `verify` — does this ledger parse, and does every record obey the grammar? Reports what it
# CHECKED, not only that it passed (base/practices/self-review.md): a validator that scanned zero
# records prints the same "ok" as one that scanned forty, and the count is what tells them apart.
cmd_verify() {
  local ledger hits promoted nh=0 np=0 bad=0 c s f th
  ledger="$(_adb_pl_resolve_ledger)" || exit 20
  [ -f "$ledger" ] || { printf 'pattern-ledger: no ledger at %s\n' "$ledger" >&2; exit 20; }
  # THE RAW PARSERS, deliberately. `verify` exists to NAME the bad record, and the validating
  # readers refuse the file whole — correct for every other caller, useless for this one, which
  # would then report "does not parse" without saying which line.
  hits="$(_adb_pl_hits_raw "$ledger")" || { printf 'pattern-ledger: %s — the hits region is missing, duplicated, crossed, or holds a record that is not in the grammar\n' "$ledger" >&2; exit 18; }
  promoted="$(_adb_pl_promoted_raw "$ledger")" || { printf 'pattern-ledger: %s — the checklist region is missing, duplicated, crossed, or holds a rule that is not in the grammar\n' "$ledger" >&2; exit 18; }

  if [ -n "$hits" ]; then
    while IFS="$TAB" read -r c s f th _pr _dt _summ; do
      [ -n "$c$s$f$th" ] || continue
      nh=$((nh + 1))
      _adb_pl_ok_class  "$c"  || { printf 'pattern-ledger: record %s has an invalid class "%s"\n' "$nh" "$c" >&2; bad=1; }
      _adb_pl_ok_span   "$s"  || { printf 'pattern-ledger: record %s has an invalid site "%s"\n' "$nh" "$s" >&2; bad=1; }
      _adb_pl_ok_fix    "$f"  || { printf 'pattern-ledger: record %s has an invalid fix "%s"\n' "$nh" "$f" >&2; bad=1; }
      _adb_pl_ok_thread "$th" || { printf 'pattern-ledger: record %s has an invalid thread "%s"\n' "$nh" "$th" >&2; bad=1; }
      # THE PR TOO, or `verify` and the readers disagree about the same file — which is the exact
      # split that made the original defect invisible: one command said 18 while another counted
      # the record and promoted on it.
      _adb_pl_ok_pr "$_pr" || { printf 'pattern-ledger: record %s has a missing or invalid PR number ("%s")\n' "$nh" "$_pr" >&2; bad=1; }
      _adb_pl_ok_date "$_dt" || { printf 'pattern-ledger: record %s has an invalid date ("%s")\n' "$nh" "$_dt" >&2; bad=1; }
      # THE SUMMARY, so `verify` and the readers agree about it — the same split that hid the
      # duplicate-thread defect. Reported by the declared reviewer on PR #429.
      if [ -n "$_summ" ] && ! _adb_pl_ok_text "$_summ"; then
        printf 'pattern-ledger: record %s carries a summary this module would not write — a control character, or an HTML comment marker\n' "$nh" >&2; bad=1
      fi
    done < <(printf '%s\n' "$hits")
  fi
  if [ -n "$promoted" ]; then
    while IFS="$TAB" read -r c _rule; do
      [ -n "$c" ] || continue
      np=$((np + 1))
      _adb_pl_ok_class "$c" || { printf 'pattern-ledger: checklist rule %s names an invalid class "%s"\n' "$np" "$c" >&2; bad=1; }
      _adb_pl_ok_text  "$_rule" || { printf 'pattern-ledger: checklist rule %s (%s) carries text this module would not write — a tab, a newline, a control character, or a region marker\n' "$np" "$c" >&2; bad=1; }
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
  # A DUPLICATED CHECKLIST CLASS, for the same reason and with the same consequence. `promote`
  # refuses one, so a pair means a hand edit or a merge that took both sides — and every
  # operational reader already returns 18 for it while `verify` validated each slug independently
  # and said `ok`. The command advertised as the recovery diagnostic disagreeing with every reader
  # is precisely the split that made the first version of this defect invisible.
  # Reported by the declared reviewer on PR #429.
  local ckdupes=""
  if [ -n "$promoted" ]; then
    ckdupes="$(printf '%s\n' "$promoted" | awk -F'\t' 'NF { print $1 }' | LC_ALL=C sort | LC_ALL=C uniq -d)"
    [ -z "$ckdupes" ] || { printf 'pattern-ledger: duplicate checklist class(es): %s\n' "$(printf '%s' "$ckdupes" | tr '\n' ' ')" >&2; bad=1; }
  fi
  # THE PROMPT BUDGET, so `verify` and `checklist` agree: a region every rule of which is in the
  # grammar can still be one `checklist` refuses to emit, and the diagnostic command has to say so.
  local ckregion cksize over=0
  ckregion="$(_adb_pl_region "$ledger" "$_ADB_PL_CK_BEGIN" "$_ADB_PL_CK_END")" || ckregion=""
  cksize="$(printf '%s\n' "$ckregion" | awk 'NF { print }' | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$cksize" -gt "$_ADB_PL_CHECKLIST_MAX_BYTES" ]; then
    printf 'pattern-ledger: the promoted checklist is %s bytes, over the %s-byte prompt budget — `checklist` will refuse to emit it (21)\n' \
      "$cksize" "$_ADB_PL_CHECKLIST_MAX_BYTES" >&2; over=1
  fi
  [ "$bad" -eq 0 ] || exit 18
  [ "$over" -eq 0 ] || exit 21
  printf 'ok %s hit(s), %s checklist rule(s) checked in %s (checklist %s of %s bytes)\n' "$nh" "$np" "$ledger" "$cksize" "$_ADB_PL_CHECKLIST_MAX_BYTES"
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
