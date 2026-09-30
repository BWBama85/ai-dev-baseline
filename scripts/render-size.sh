#!/usr/bin/env bash
# ai-dev-baseline — rendered instruction size per agent artifact (#359), and its growth (#432).
#
# Usage: bash scripts/render-size.sh [--since <ref> | --descriptions] [--markdown] [-h]
#
# stdout, TAB-separated, one row per rendered artifact and then a TOTAL row:
#
#     name<TAB>lines<TAB>words<TAB>approx_tokens<TAB>fenced_comment_lines
#
# and with --since <ref>, two more columns on every row:
#
#     …<TAB>delta_lines<TAB>delta_tokens
#
# `name` is the repo-relative path; `TOTAL` is the sum of the rows above it, in every column.
# `lines` and `words` are `wc -lwc`'s first two fields. `approx_tokens` is ceil(bytes/4) — a SIZE
# HEURISTIC, not a tokenizer: comparable to itself across commits of this corpus and to nothing
# else. `fenced_comment_lines` is the number of lines whose first non-blank character is `#`
# inside a ```bash, ```sh, ```shell or ```zsh fence — the blocks an agent executes, where every
# comment is loaded as prompt on each invocation (base/practices/code-comments.md). Other fences
# (text, markdown, json, or no info string) hold samples and templates, where `#` is a heading,
# and are not scanned. The rule is lexical — the whole-line rule D75/D76 record for this repo's
# fences — so a shebang or a `#`-led heredoc line counts as one and a trailing comment does not.
# Fences are decided by the shared CommonMark block pass (adb_md_block, scripts/lib/common.sh):
# openers, closers, run length, `~~~`, CRLF, and nested lists at any indentation, one marker per
# line — a fence indented to a list item's content column is a fence, one indented four past it is
# code, and an unterminated list-nested fence ends with its item — and a fence the ending item
# opens on that same line is a new fence, with its own info string. Two shapes the pass does not
# model are not scanned, and the corpus carries neither: a fence on a line that itself carries more
# than one list marker (`- - ```bash`), and a fence inside a blockquote, which is quotation rather
# than a block an agent executes.
#
# --since <ref>: `delta_lines` and `delta_tokens` are `lines` and `approx_tokens` now minus the
# same measurement of the artifact TRACKED at <ref> (any commit-ish; one that begins with `-` is
# accepted only as `--since=<ref>`, and every ref reaches git behind --end-of-options), so a delta is always the
# difference of two figures this command prints. Each artifact's blob is read out of git into a
# `mktemp -d` and measured by the same code; the working tree and the repository are never
# written. An artifact that exists now but not at <ref> reads `new` in both delta columns and
# contributes its whole size to TOTAL's deltas (it cost nothing to load at <ref>); an artifact
# tracked at <ref> that the current tree no longer expects has no row, because the expected set
# is derived from the CURRENT base/workflows/ — a rename is one `new` row, never a removal.
# Tracked artifacts, not a rebuild (D93): `build-drift` fails any commit whose generated files
# are stale, so on the default branch the two are the same bytes, and a measurement does not
# execute another commit's build.
#
# --markdown: the same rows as a GitHub-flavored Markdown table with a header row, for a CI job
# summary, followed by the descriptions table below; the column names here are its ONE home.
#
# --descriptions: stdout is the descriptions figure alone, one row per agent and then a TOTAL row:
#
#     agent<TAB>skills<TAB>words<TAB>approx_tokens
#
# where TOTAL is again the sum of the rows above it, in every column — across agents, although a
# session loads one agent's row. Every artifact is still measured and every fault still fails the
# command; none of their rows is printed. With --markdown, the same rows as a table. It takes no
# --since: the figure is the current tree's.
#
# The `descriptions` figure (#436) is the NOMINAL always-loaded cost: the text of every skill's
# `description:` value, which each agent lists at session start whether or not a skill runs, before
# any host budget — a host may shorten or drop entries when its listing is over one. Its words are
# already inside the SKILL.md rows, so it is never a row of the artifact table — TOTAL would count
# them twice. It is a line of the stderr summary on every run, the whole of stdout with
# --descriptions, and with --markdown, the report CI publishes, a second table after the artifact
# table: the --descriptions rows, TOTAL included. Per agent — one session loads one
# agent's set — it is the skill count, the values' `wc -w` words, and ceil(bytes/4) of the values.
# The value is the one `description:` line's text after the key, and scripts/skill-description.awk
# — the rule build.sh applies to every source — admits only plain text every YAML loader reads as
# itself. That is the descriptions' share of the listing, not the whole of it (each agent adds
# names and paths around them). It is always the current tree's; --since reports growth in the
# SKILL.md rows' deltas. A render that fails the rule is UNDESCRIBED: a broken render, never zero
# words.
#
# The expected artifact set is DERIVED from base/workflows/, base/practices/ and the agent table
# below, never globbed from agents/ — a glob reports what exists, so a skill that failed to render
# would simply be absent from the output. A practice carrying an `adb:procedure` block yields one
# procedure file per agent (#434): agents/claude/rules/ for Claude when the practice declares
# `adb:paths`, agents/<agent>/reference/ otherwise — derived from the source, so a copy in the other
# tree is a fault rather than a substitute. It is measured in the on-demand bucket, and the summary
# reports each root doc's lines against the ~200-line goal, which is a report and never a gate.
#
# Exit: 0 every expected artifact was measured · 1 a mechanical fault — MISSING, UNREADABLE,
# UNCOUNTABLE, EMPTY, UNNAMEABLE, DUPLICATE (a procedure also present in the tree it does not
# render to), UNDESCRIBED, a collapsed
# derivation, or a blob at <ref> that git could not list or read · 2 usage, --since outside a git
# repository, or a <ref> that is not a commit. Size NEVER fails this command; there is no ceiling (#355).

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and before the cd, and confirmed by
# PROBING FOR THE FUNCTION rather than by the source's exit status. Same idiom, same reasons, as
# every sibling check script.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
# The fence rule is the shared one or nothing: a common.sh without it is an older install, and a
# scan that silently matched no fence would report every artifact as comment-free.
[ -n "${_ADB_MD_AWK:-}" ] || {
  printf '%s: FATAL — scripts/lib/common.sh has no _ADB_MD_AWK (the shared fence rule); cannot count fenced comments\n' "${0##*/}" >&2
  exit 1
}

# Argument handling BEFORE the cd: `adb_usage "$0"` re-reads this file, and a relative $0 stops
# resolving once the working directory changes. Values are validated here and resolved after.
SINCE=""
MARKDOWN=0
DESCS_ONLY=0
usage_error() {   # <message> — a usage fault is exit 2, never a silent full run
  printf 'render-size: %s (usage: bash scripts/render-size.sh [--since <ref> | --descriptions] [--markdown])\n' "$1" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) adb_usage "$0"; exit 0 ;;
    --since)
      [ "$#" -ge 2 ] || usage_error '--since needs a ref'
      [ -n "$2" ] || usage_error '--since needs a ref'
      # `--since -x` cannot be told from an option that follows it; the `=` form can name such a ref.
      case "$2" in -*) usage_error "--since needs a ref, got $(adb_display_value "$2") — write --since=<ref> for a ref that begins with -" ;; esac
      [ -z "$SINCE" ] || usage_error '--since given twice'
      SINCE="$2"; shift 2 ;;
    --since=*)
      [ -n "${1#--since=}" ] || usage_error '--since needs a ref'
      [ -z "$SINCE" ] || usage_error '--since given twice'
      SINCE="${1#--since=}"; shift ;;
    --markdown) MARKDOWN=1; shift ;;
    --descriptions) DESCS_ONLY=1; shift ;;
    *) usage_error "unknown argument $(adb_display_value "$1")" ;;
  esac
done
[ "$DESCS_ONLY" -eq 0 ] || [ -z "$SINCE" ] || usage_error '--descriptions reports the current tree, so it takes no --since'

cd "$(dirname "$0")/.." || exit 1
# The description rule is the shared one or nothing: without it every skill would read as an
# unreadable description rather than as a missing file.
[ -r scripts/skill-description.awk ] || {
  printf '%s: FATAL — scripts/skill-description.awk is missing; cannot read skill descriptions\n' "${0##*/}" >&2
  exit 1
}

# <agent>:<root-doc-basename>. Restated rather than sourced: scripts/build.sh owns the same triple
# and says why it is not single-sourced yet.
AGENTS='claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md'

# --since is resolved AFTER the cd, where the repository is. Three outcomes stay distinct all the
# way down — usage (2), a mechanical fault (1), and "not at <ref>" (`new`) — because a failed read
# that printed `new` would report growth that never happened.
SINCE_SHA=""
SINCE_SHORT=""
REF_DIR=""
declare -A AT_REF=()
if [ -n "$SINCE" ]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'render-size: --since needs a git repository, and none contains this checkout\n' >&2; exit 2; }
  SINCE_SHA="$(git rev-parse --verify --quiet --end-of-options "$SINCE^{commit}")" \
    || { printf 'render-size: cannot resolve %s\n' "$(adb_display_value "$SINCE")" >&2; exit 2; }
  SINCE_SHORT="${SINCE_SHA:0:12}"
  REF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/render-size.XXXXXX")" \
    || { printf 'render-size: cannot create a scratch directory for the artifacts at %s\n' "$SINCE_SHORT" >&2; exit 1; }
  trap 'rm -rf "$REF_DIR"' EXIT
  # Membership at <ref> comes from ONE listing, so an absent artifact and a listing git could not
  # produce are different answers: the first is `new`, the second is a fault. An `agents/` that does
  # not exist at <ref> lists nothing and exits 0, which makes every artifact `new`.
  listing="$(git ls-tree -r --name-only "$SINCE_SHA" -- agents)" \
    || { printf 'render-size: could not list agents/ at %s\n' "$SINCE_SHORT" >&2; exit 1; }
  while IFS= read -r entry; do
    [ -n "$entry" ] && AT_REF["$entry"]=1
  done <<< "$listing"
fi

rc=0
roots=0
skills=0
supports=0
news_loaded=0; news_od=0
t_lines=0; t_words=0; t_tokens=0; t_fenced=0; t_dlines=0; t_dtokens=0
# On-demand supporting files (#433) are measured and rowed like everything else but accumulated
# APART, so the loaded-on-invocation figure — the claim the report exists to support — survives
# as its own number. It is carried in the STDERR summary, never as a second total row: the TSV
# contract is one final TOTAL summing every row above it, and a subtotal row would break any
# consumer that sums the rows or reads the last row as the total.
od_lines=0; od_words=0; od_tokens=0; od_fenced=0; od_dlines=0; od_dtokens=0
EMIT_BUCKET=loaded
M_LINES=0; M_WORDS=0; M_TOKENS=0

# measure <file> <label> — set M_LINES / M_WORDS / M_TOKENS from <file>, or diagnose <label> on
# stderr and return 1. ONE code path for both halves of a delta: a before/after is only readable if
# both were measured the same way, which is also why LC_ALL=C pins the counts across runners.
measure() {
  local f="$1" label="$2" counts lines words bytes
  if [ ! -r "$f" ] || ! counts="$(LC_ALL=C wc -lwc < "$f" 2>/dev/null)"; then
    printf 'render-size: UNREADABLE %s\n' "$label" >&2
    return 1
  fi
  read -r lines words bytes <<< "$counts"
  # Non-numeric or MISSING counts would evaluate to 0 in the arithmetic below and print a plausible
  # row, so each field is checked on its own: concatenated, one digit string passes for three.
  local n
  for n in "$lines" "$words" "$bytes"; do
    case "$n" in ''|*[!0-9]*)
      printf 'render-size: UNCOUNTABLE %s — wc returned %s\n' "$label" "$counts" >&2
      return 1 ;;
    esac
  done
  if [ "$bytes" -eq 0 ]; then
    printf 'render-size: EMPTY %s — a rendered artifact is never zero bytes, so this is a truncated render, not a size verdict\n' "$label" >&2
    return 1
  fi
  M_LINES=$lines; M_WORDS=$words; M_TOKENS=$(( (bytes + 3) / 4 ))
}

# describe <SKILL.md> <agent> — add the rendered description to <agent>'s always-loaded figure, or
# diagnose and fail closed. The rule is scripts/skill-description.awk, the one build.sh applies to
# every source: a render that passes it carries plain text every YAML loader reads as itself.
declare -A D_SKILLS=() D_WORDS=() D_BYTES=()
describe() {
  local f="$1" a="$2" out v counts words bytes
  # pipefail INSIDE the substitution: this script runs without it, and a `tr` that failed after
  # writing would otherwise be answered for by awk's status alone.
  out="$(set -o pipefail; LC_ALL=C tr '\000' '\001' < "$f" | LC_ALL=C awk -f scripts/skill-description.awk)" || out=""
  case "$out" in
    ok$'\t'*) v="${out#ok$'\t'}" ;;
    bad$'\t'*)
      printf 'render-size: UNDESCRIBED %s — %s (scripts/skill-description.awk names the admitted shape)\n' "$f" "${out#bad$'\t'}" >&2
      rc=1; return 1 ;;
    *) printf 'render-size: UNREADABLE %s — its description could not be read\n' "$f" >&2
       rc=1; return 1 ;;
  esac
  counts="$(printf '%s' "$v" | LC_ALL=C wc -wc)" || counts=""
  read -r words bytes <<< "$counts"
  local n
  for n in "$words" "$bytes"; do
    case "$n" in ''|*[!0-9]*)
      printf 'render-size: UNCOUNTABLE %s — wc returned %s for its description\n' "$f" "$(adb_display_value "$counts")" >&2
      rc=1; return 1 ;;
    esac
  done
  D_SKILLS[$a]=$(( ${D_SKILLS[$a]:-0} + 1 ))
  D_WORDS[$a]=$(( ${D_WORDS[$a]:-0} + words ))
  D_BYTES[$a]=$(( ${D_BYTES[$a]:-0} + bytes ))
}

# fenced_comments <file> — print the count defined in the header. `adb_md_block` classifies every
# line with the container column it tracks, so a fence indented to a list item's content is seen
# (calling adb_md_fence_delim at column 0, as the two other direct consumers do, reads it as
# indented code — measured: roadmap's two five-space fences, 303 for 305). An OPENER is a line on
# which the pass opened a fence — `md_fence_gen` moved — never a comparison of the delimiter
# before and after, which comes back equal when a list-nested fence is ended by the item that
# opens the next one at the same column. This reads only the opener's info string, first word.
fenced_comments() {
  LC_ALL=C awk "$_ADB_MD_AWK"'
    {
      was_gen = md_fence_gen
      adb_md_block($0)
      line = MD_LINE
      if (md_fence_len && md_fence_gen != was_gen) {
        info = line                            # an OPENER: is this a shell fence?
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*[`~]+[[:space:]]*/, "", info)
        sub(/[[:space:]].*$/, "", info)
        shell = (info == "bash" || info == "sh" || info == "shell" || info == "zsh")
        next
      }
      if (md_fence_len && shell && line ~ /^[[:space:]]*#/) n++
    }
    END { print n + 0 }
  ' "$1"
}

# row <cell>… — one output record, TSV or a Markdown table row; the ONLY writer of stdout rows.
# ROWS_ON=0 measures without printing: --descriptions keeps every artifact's faults, not its rows.
ROWS_ON=1
[ "$DESCS_ONLY" -eq 0 ] || ROWS_ON=0
row() {
  [ "$ROWS_ON" -eq 1 ] || return 0
  if [ "$MARKDOWN" -eq 1 ]; then
    local out="|" cell
    for cell in "$@"; do out="$out $cell |"; done
    printf '%s\n' "$out"
  else
    local IFS=$'\t'
    printf '%s\n' "$*"
  fi
}

# emit <repo-relative-path> — measure one artifact and print its row, or diagnose and fail closed.
emit() {
  local f="$1" lines words tokens fenced dl dt
  if [ ! -f "$f" ]; then
    printf 'render-size: MISSING %s — the expected artifact does not exist (run scripts/build.sh)\n' "$f" >&2
    rc=1; return 1
  fi
  measure "$f" "$f" || { rc=1; return 1; }
  lines=$M_LINES; words=$M_WORDS; tokens=$M_TOKENS; E_LINES=$lines
  fenced="$(fenced_comments "$f")" || fenced=""
  case "$fenced" in ''|*[!0-9]*)
    printf 'render-size: UNCOUNTABLE %s — the fenced-comment scan returned %s\n' "$f" "$(adb_display_value "$fenced")" >&2
    rc=1; return 1 ;;
  esac
  if [ -z "$SINCE_SHA" ]; then
    row "$f" "$lines" "$words" "$tokens" "$fenced"
  elif [ -n "${AT_REF[$f]+x}" ]; then
    # The blob at <ref>, into the scratch tree under its own path, measured by the same function.
    if ! mkdir -p "$REF_DIR/${f%/*}" || ! git cat-file blob "$SINCE_SHA:$f" > "$REF_DIR/$f"; then
      printf 'render-size: could not read %s at %s\n' "$f" "$SINCE_SHORT" >&2
      rc=1; return 1
    fi
    measure "$REF_DIR/$f" "$f at $SINCE_SHORT" || { rc=1; return 1; }
    dl=$(( lines - M_LINES )); dt=$(( tokens - M_TOKENS ))
    if [ "$EMIT_BUCKET" = loaded ]; then t_dlines=$(( t_dlines + dl )); t_dtokens=$(( t_dtokens + dt ))
    else od_dlines=$(( od_dlines + dl )); od_dtokens=$(( od_dtokens + dt )); fi
    row "$f" "$lines" "$words" "$tokens" "$fenced" "$dl" "$dt"
  else
    # Counted PER BUCKET: a batch of new supporting files used to report as "loaded … N new",
    # which misstates the context-growth summary the loaded deltas exist to support.
    if [ "$EMIT_BUCKET" = loaded ]; then news_loaded=$(( news_loaded + 1 )); t_dlines=$(( t_dlines + lines )); t_dtokens=$(( t_dtokens + tokens ))
    else news_od=$(( news_od + 1 )); od_dlines=$(( od_dlines + lines )); od_dtokens=$(( od_dtokens + tokens )); fi
    row "$f" "$lines" "$words" "$tokens" "$fenced" new new
  fi
  if [ "$EMIT_BUCKET" = loaded ]; then
    t_lines=$(( t_lines + lines )); t_words=$(( t_words + words ))
    t_tokens=$(( t_tokens + tokens )); t_fenced=$(( t_fenced + fenced ))
  else
    od_lines=$(( od_lines + lines )); od_words=$(( od_words + words ))
    od_tokens=$(( od_tokens + tokens )); od_fenced=$(( od_fenced + fenced ))
  fi
}

COLS=(name lines words approx_tokens fenced_comment_lines)
[ -z "$SINCE_SHA" ] || COLS+=(delta_lines delta_tokens)
if [ "$MARKDOWN" -eq 1 ]; then
  row "${COLS[@]}"
  SEP=(---)
  while [ "${#SEP[@]}" -lt "${#COLS[@]}" ]; do SEP+=(---:); done
  row "${SEP[@]}"
fi

goal=""
for pair in $AGENTS; do
  emit "agents/${pair%%:*}/${pair#*:}" && { roots=$(( roots + 1 )); goal="${goal:+$goal, }${pair%%:*} $E_LINES"; }
done

procs=0; psources=0
EMIT_BUCKET=ondemand
for pf in base/practices/*.md; do
  [ -f "$pf" ] || continue
  pbase="${pf##*/}"
  case "$pbase" in 00-index.md) continue ;; esac
  # 2 is a practice that could not be read, which must not pass as one with no procedure.
  LC_ALL=C grep -Fqx -- '<!-- adb:procedure -->' "$pf"; grc=$?
  case "$grc" in
    0) : ;;
    1) continue ;;
    *) printf 'render-size: UNREADABLE %s — could not read it to learn whether it has a procedure\n' "$pf" >&2
       rc=1; continue ;;
  esac
  case "$pbase" in *[!A-Za-z0-9._-]*)
    printf 'render-size: UNNAMEABLE base/practices/%s — a practice name outside [A-Za-z0-9._-] cannot be reported in this TSV\n' "$(adb_display_value "$pbase")" >&2
    rc=1; continue ;;
  esac
  psources=$(( psources + 1 ))
  for pair in $AGENTS; do
    a="${pair%%:*}"
    pexp=reference; pother=rules
    if [ "$a" = claude ]; then
      LC_ALL=C grep -q '^<!-- adb:paths ' "$pf"; grc=$?
      case "$grc" in
        0) pexp=rules; pother=reference ;;
        1) : ;;
        *) printf 'render-size: UNREADABLE %s — could not read its adb:paths scope\n' "$pf" >&2
           rc=1; continue ;;
      esac
    fi
    if [ -e "agents/$a/$pother/$pbase" ] || [ -L "agents/$a/$pother/$pbase" ]; then
      printf 'render-size: DUPLICATE %s — agents/%s/%s/%s is a stale copy; this procedure renders to agents/%s/%s/ (delete the stale one)\n' "$pbase" "$a" "$pother" "$pbase" "$a" "$pexp" >&2
      rc=1
    fi
    emit "agents/$a/$pexp/$pbase" && procs=$(( procs + 1 ))
  done
done
EMIT_BUCKET=loaded

sources=0
for wf in base/workflows/*.md; do
  [ -f "$wf" ] || continue
  name="$(basename "$wf" .md)"
  case "$name" in README) continue ;; esac
  # A TAB or newline in a workflow name would forge a field boundary in the TSV this command
  # promises is machine-readable.
  case "$name" in *[!A-Za-z0-9._-]*)
    printf 'render-size: UNNAMEABLE base/workflows/%s.md — a workflow name outside [A-Za-z0-9._-] cannot be reported in this TSV\n' "$(adb_display_value "$name")" >&2
    rc=1; continue ;;
  esac
  sources=$(( sources + 1 ))
  for pair in $AGENTS; do
    emit "agents/${pair%%:*}/skills/$name/SKILL.md" && skills=$(( skills + 1 )) \
      && describe "agents/${pair%%:*}/skills/$name/SKILL.md" "${pair%%:*}"
  done
  # Supporting files (#433): derived from base/workflows/<name>/, never globbed from agents/ —
  # a sibling that failed to render must be MISSING here, not absent from the report.
  if [ -d "base/workflows/$name" ]; then
    EMIT_BUCKET=ondemand
    for sf in "base/workflows/$name"/*.md; do
      [ -f "$sf" ] || continue
      sbase="$(basename "$sf")"
      case "$sbase" in *[!A-Za-z0-9._-]*)
        printf 'render-size: UNNAMEABLE base/workflows/%s/%s — outside [A-Za-z0-9._-]\n' "$name" "$(adb_display_value "$sbase")" >&2
        rc=1; continue ;;
      esac
      for pair in $AGENTS; do
        emit "agents/${pair%%:*}/skills/$name/$sbase" && supports=$(( supports + 1 ))
      done
    done
    EMIT_BUCKET=loaded
  fi
done

# Zero sources means the derivation collapsed, and a collapsed derivation prints a clean, short
# report instead of failing — the silent-guard shape this whole command is fail-closed against.
if [ "$sources" -eq 0 ]; then
  printf 'render-size: base/workflows/ named no workflow source — the skill set could not be derived\n' >&2
  rc=1
fi

# TOTAL is the ONE final row and sums EVERY row above it — the header's own contract, kept even
# with supporting files present. The loaded-on-invocation figure ("the invocation context got
# smaller", #433's claim) is carried in the stderr summary as loaded/on-demand approx_tokens; a
# subtotal ROW would break any consumer that sums the rows or reads the last row as the total.
if [ -z "$SINCE_SHA" ]; then
  row TOTAL "$((t_lines + od_lines))" "$((t_words + od_words))" "$((t_tokens + od_tokens))" "$((t_fenced + od_fenced))"
  printf 'render-size: measured %s root doc(s), %s skill(s) and %s on-demand supporting file(s) from %s workflow source(s), and %s procedure file(s) from %s practice(s); loaded approx_tokens %s, on-demand approx_tokens %s; approx_tokens = ceil(bytes/4), a heuristic, not a tokenizer\n' \
    "$roots" "$skills" "$supports" "$sources" "$procs" "$psources" "$t_tokens" "$od_tokens" >&2
else
  row TOTAL "$((t_lines + od_lines))" "$((t_words + od_words))" "$((t_tokens + od_tokens))" "$((t_fenced + od_fenced))" "$((t_dlines + od_dlines))" "$((t_dtokens + od_dtokens))"
  printf 'render-size: measured %s root doc(s), %s skill(s) and %s on-demand supporting file(s) from %s workflow source(s), and %s procedure file(s) from %s practice(s); loaded approx_tokens %s, on-demand approx_tokens %s; approx_tokens = ceil(bytes/4), a heuristic, not a tokenizer; since %s (%s): loaded delta_lines %s, delta_tokens %s, %s new (on-demand: %s new)\n' \
    "$roots" "$skills" "$supports" "$sources" "$procs" "$psources" "$t_tokens" "$od_tokens" "$(adb_display_value "$SINCE")" "$SINCE_SHORT" "$t_dlines" "$t_dtokens" "$news_loaded" "$news_od" >&2
fi
[ -z "$goal" ] || printf 'render-size: root doc lines against the ~200-line goal (a report, never a gate): %s\n' "$goal" >&2
descs=""
for pair in $AGENTS; do
  a="${pair%%:*}"
  [ -n "${D_SKILLS[$a]+x}" ] || continue
  descs="${descs:+$descs, }$a ${D_SKILLS[$a]} skill(s) ${D_WORDS[$a]} words approx_tokens $(( (D_BYTES[$a] + 3) / 4 ))"
done
[ -z "$descs" ] || printf 'render-size: descriptions, the nominal listing text every session starts with, before any host budget (a report, never a gate): %s\n' "$descs" >&2
# The descriptions rows — --descriptions' whole stdout, and the table --markdown appends. An agent
# with no description measured has no row, as a missing artifact has none above; the run has failed.
desc_rows() {
  local a n=0 w=0 t=0 tok
  ROWS_ON=1
  if [ "$MARKDOWN" -eq 1 ]; then
    row agent skills words approx_tokens
    row --- ---: ---: ---:
  fi
  for pair in $AGENTS; do
    a="${pair%%:*}"
    [ -n "${D_SKILLS[$a]+x}" ] || continue
    tok=$(( (D_BYTES[$a] + 3) / 4 ))
    row "$a" "${D_SKILLS[$a]}" "${D_WORDS[$a]}" "$tok"
    n=$(( n + D_SKILLS[$a] )); w=$(( w + D_WORDS[$a] )); t=$(( t + tok ))
  done
  row TOTAL "$n" "$w" "$t"
}
if [ "$DESCS_ONLY" -eq 1 ]; then
  desc_rows
elif [ "$MARKDOWN" -eq 1 ] && [ -n "$descs" ]; then
  printf '\nSkill descriptions: the nominal listing text every session starts with, before any host budget (the current tree, per agent; #436).\n\n'
  desc_rows
fi

exit "$rc"
