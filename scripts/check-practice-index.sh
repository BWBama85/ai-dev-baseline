#!/usr/bin/env bash
# ai-dev-baseline — practice-index parity check.
#
# base/practices/00-index.md carries a table listing every practice file and its
# concern. build-drift catches a changed generated root doc, but it does NOT notice
# a NEW practice whose index row was forgotten (the root docs render from the *.md
# glob, not from the index). This check closes that gap: every base/practices/*.md
# (except the index itself) must appear in the index table exactly once, and every
# file the index names must exist — so adding a practice without indexing it, or
# leaving a stale row after a rename, fails CI.
#
# Usage: bash scripts/check-practice-index.sh   (exit 0 = in sync, 1 = drift)

set -u
cd "$(dirname "$0")/.." || exit 1

index="base/practices/00-index.md"
fail=0
note() { printf 'practice-index: %s\n' "$*" >&2; }

if [ ! -f "$index" ]; then
  note "index not found: $index"
  exit 1
fi

# Every practice source (except the index) must be named in the index.
for f in base/practices/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  [ "$base" = "00-index.md" ] && continue
  n="$(grep -Fc -- "\`$base\`" "$index")"
  if [ "$n" -eq 0 ]; then
    note "practice '$base' has no row in $index (add it to the table)"
    fail=1
  elif [ "$n" -gt 1 ]; then
    note "practice '$base' is listed $n times in $index (should be exactly once)"
    fail=1
  fi
done

# Every file the index names in backticks (…\`something.md\`…) must exist as a source.
named="$(grep -oE '`[a-z0-9-]+\.md`' "$index" | tr -d '`' | sort -u)"
for base in $named; do
  [ "$base" = "00-index.md" ] && continue
  if [ ! -f "base/practices/$base" ]; then
    note "index names '$base' but base/practices/$base does not exist (stale row)"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "practice-index: PASS (every practice indexed exactly once, no stale rows)"
  exit 0
fi
exit 1
