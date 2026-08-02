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

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "practice-index"

index="base/practices/00-index.md"
if [ ! -f "$index" ]; then
  check_note "index not found: $index"
  exit 1
fi

# Every practice source (except the index) must be named in the index exactly once.
for f in base/practices/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  [ "$base" = "00-index.md" ] && continue
  n="$(grep -Fc -- "\`$base\`" "$index")"
  if [ "$n" -eq 0 ]; then
    check_note "practice '$base' has no row in $index (add it to the table)"
    check_fail
  elif [ "$n" -gt 1 ]; then
    check_note "practice '$base' is listed $n times in $index (should be exactly once)"
    check_fail
  fi
done

# Every file the index names in backticks (…`something.md`…) must exist as a source.
named="$(grep -oE '`[a-z0-9-]+\.md`' "$index" | tr -d '`' | sort -u)"
for base in $named; do
  [ "$base" = "00-index.md" ] && continue
  if [ ! -f "base/practices/$base" ]; then
    check_note "index names '$base' but base/practices/$base does not exist (stale row)"
    check_fail
  fi
done

check_result "every practice indexed exactly once, no stale rows"
