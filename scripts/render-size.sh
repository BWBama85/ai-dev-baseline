#!/usr/bin/env bash
# ai-dev-baseline — rendered instruction size per agent artifact (#359), and its growth (#432).
#
# Usage: bash scripts/render-size.sh [--since <ref>] [--markdown] [-h]
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
# summary; the column names above are its ONE home.
#
# The expected artifact set is DERIVED from base/workflows/ and the agent table below, never
# globbed from agents/ — a glob reports what exists, so a skill that failed to render would simply
# be absent from the output.
#
# Exit: 0 every expected artifact was measured · 1 a mechanical fault — MISSING, UNREADABLE,
# UNCOUNTABLE, EMPTY, UNNAMEABLE, a collapsed derivation, or a blob at <ref> that git could not
# list or read · 2 usage, --since outside a git repository, or a <ref> that is not a commit.
# Size NEVER fails this command; there is no ceiling (#355).

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
usage_error() {   # <message> — a usage fault is exit 2, never a silent full run
  printf 'render-size: %s (usage: bash scripts/render-size.sh [--since <ref>] [--markdown])\n' "$1" >&2
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
    *) usage_error "unknown argument $(adb_display_value "$1")" ;;
  esac
done

cd "$(dirname "$0")/.." || exit 1

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
  # Non-numeric counts would evaluate to 0 in the arithmetic below and print a plausible row.
  case "$lines$words$bytes" in ''|*[!0-9]*)
    printf 'render-size: UNCOUNTABLE %s — wc returned %s\n' "$label" "$counts" >&2
    return 1 ;;
  esac
  if [ "$bytes" -eq 0 ]; then
    printf 'render-size: EMPTY %s — a rendered artifact is never zero bytes, so this is a truncated render, not a size verdict\n' "$label" >&2
    return 1
  fi
  M_LINES=$lines; M_WORDS=$words; M_TOKENS=$(( (bytes + 3) / 4 ))
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
row() {
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
  lines=$M_LINES; words=$M_WORDS; tokens=$M_TOKENS
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

for pair in $AGENTS; do
  emit "agents/${pair%%:*}/${pair#*:}" && roots=$(( roots + 1 ))
done

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
    emit "agents/${pair%%:*}/skills/$name/SKILL.md" && skills=$(( skills + 1 ))
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
  printf 'render-size: measured %s root doc(s), %s skill(s) and %s on-demand supporting file(s) from %s workflow source(s); loaded approx_tokens %s, on-demand approx_tokens %s; approx_tokens = ceil(bytes/4), a heuristic, not a tokenizer\n' \
    "$roots" "$skills" "$supports" "$sources" "$t_tokens" "$od_tokens" >&2
else
  row TOTAL "$((t_lines + od_lines))" "$((t_words + od_words))" "$((t_tokens + od_tokens))" "$((t_fenced + od_fenced))" "$((t_dlines + od_dlines))" "$((t_dtokens + od_dtokens))"
  printf 'render-size: measured %s root doc(s), %s skill(s) and %s on-demand supporting file(s) from %s workflow source(s); loaded approx_tokens %s, on-demand approx_tokens %s; approx_tokens = ceil(bytes/4), a heuristic, not a tokenizer; since %s (%s): loaded delta_lines %s, delta_tokens %s, %s new (on-demand: %s new)\n' \
    "$roots" "$skills" "$supports" "$sources" "$t_tokens" "$od_tokens" "$(adb_display_value "$SINCE")" "$SINCE_SHORT" "$t_dlines" "$t_dtokens" "$news_loaded" "$news_od" >&2
fi

exit "$rc"
