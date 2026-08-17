#!/usr/bin/env bash
# ai-dev-baseline — rendered instruction size per agent artifact (#359).
#
# Usage: bash scripts/render-size.sh [-h]
#
# stdout, TAB-separated, one row per rendered artifact and then a TOTAL row:
#
#     name<TAB>lines<TAB>words<TAB>approx_tokens
#
# `name` is the repo-relative path; `TOTAL` is the sum of the rows above it.
# `lines` and `words` are `wc -lwc`'s first two fields. `approx_tokens` is
# ceil(bytes/4) — a SIZE HEURISTIC, not a tokenizer. It is comparable to itself
# across commits of this corpus and to nothing else; do not read it as a vendor
# token count.
#
# The expected artifact set is DERIVED from base/workflows/ and the agent table
# below, never globbed from agents/ — a glob reports what exists, so a skill that
# failed to render would simply be absent from the output.
#
# Exit: 0 every expected artifact was measured · 1 a mechanical fault — MISSING,
# UNREADABLE, UNCOUNTABLE, EMPTY, UNNAMEABLE, or a collapsed derivation · 2 usage.
# Size NEVER fails this command; there is no ceiling.

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
cd "$(dirname "$0")/.." || exit 1

case "${1:-}" in
  '') : ;;
  -h|--help) adb_usage "$0"; exit 0 ;;
  *) printf 'render-size: unknown argument %s (usage: bash scripts/render-size.sh)\n' "$1" >&2; exit 2 ;;
esac

# <agent>:<root-doc-basename>. Restated rather than sourced: scripts/build.sh owns the same triple
# and says why it is not single-sourced yet.
AGENTS='claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md'

rc=0
roots=0
skills=0
t_lines=0
t_words=0
t_tokens=0

# emit <repo-relative-path> — measure one artifact and print its row, or diagnose and fail closed.
emit() {
  local f="$1" counts lines words bytes tokens
  if [ ! -f "$f" ]; then
    printf 'render-size: MISSING %s — the expected artifact does not exist (run scripts/build.sh)\n' "$f" >&2
    rc=1; return 1
  fi
  # LC_ALL=C so the three counts are the same on every runner regardless of the ambient locale —
  # a before/after delta is only readable if both halves were measured the same way.
  if [ ! -r "$f" ] || ! counts="$(LC_ALL=C wc -lwc < "$f" 2>/dev/null)"; then
    printf 'render-size: UNREADABLE %s\n' "$f" >&2
    rc=1; return 1
  fi
  read -r lines words bytes <<< "$counts"
  # Non-numeric counts would evaluate to 0 in the arithmetic below and print a plausible row.
  case "$lines$words$bytes" in ''|*[!0-9]*)
    printf 'render-size: UNCOUNTABLE %s — wc returned %s\n' "$f" "$counts" >&2
    rc=1; return 1 ;;
  esac
  if [ "$bytes" -eq 0 ]; then
    printf 'render-size: EMPTY %s — a rendered artifact is never zero bytes, so this is a truncated render, not a size verdict\n' "$f" >&2
    rc=1; return 1
  fi
  tokens=$(( (bytes + 3) / 4 ))
  printf '%s\t%s\t%s\t%s\n' "$f" "$lines" "$words" "$tokens"
  t_lines=$(( t_lines + lines ))
  t_words=$(( t_words + words ))
  t_tokens=$(( t_tokens + tokens ))
}

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
    printf 'render-size: UNNAMEABLE base/workflows/%s.md — a workflow name outside [A-Za-z0-9._-] cannot be reported in this TSV\n' "$name" >&2
    rc=1; continue ;;
  esac
  sources=$(( sources + 1 ))
  for pair in $AGENTS; do
    emit "agents/${pair%%:*}/skills/$name/SKILL.md" && skills=$(( skills + 1 ))
  done
done

# Zero sources means the derivation collapsed, and a collapsed derivation prints a clean, short
# report instead of failing — the silent-guard shape this whole command is fail-closed against.
if [ "$sources" -eq 0 ]; then
  printf 'render-size: base/workflows/ named no workflow source — the skill set could not be derived\n' >&2
  rc=1
fi

printf 'TOTAL\t%s\t%s\t%s\n' "$t_lines" "$t_words" "$t_tokens"
printf 'render-size: measured %s root doc(s) and %s skill(s) from %s workflow source(s); approx_tokens = ceil(bytes/4), a heuristic, not a tokenizer\n' \
  "$roots" "$skills" "$sources" >&2

exit "$rc"
