#!/usr/bin/env bash
# ai-dev-baseline — the retired composer's contract (scripts/lib/skill-compose.sh, retired by #540).
#
# The composer no longer composes: every subcommand must refuse with exit 3 and name the
# retirement, both run directly and through `baseline skill-compose`, so a project gate that still
# calls `skill-compose check` fails with a reason rather than passing or vanishing.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-skill-compose.sh   (exit 0 = all pass, 1 = a failure)

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
ROOT="$(pwd)"
SC="$ROOT/scripts/lib/skill-compose.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
REPO="$work/repo"; GHOME="$work/home"
mkdir -p "$REPO/.claude/skills/demo" "$GHOME/.claude/skills/demo"
git init -q "$REPO"
printf '# base\n' > "$GHOME/.claude/skills/demo/SKILL.md"
printf '<!-- adb:override anchor="x" op="append" -->\ny\n<!-- adb:end -->\n' > "$REPO/.claude/skills/demo/overrides.md"

sc() { ( cd "$REPO" && HOME="$GHOME" bash "$SC" "$@" ); }

for sub in compose check list-anchors; do
  out="$(sc "$sub" demo 2>&1)"; rc=$?
  eq "$rc" 3 "$sub: refused with exit 3 (retired), never 0"
  has "$out" "retired (#540" "$sub: ...and the refusal names the retirement"
done
[ ! -e "$REPO/.claude/skills/demo/SKILL.md" ] && ok "compose: writes no composed SKILL.md" \
  || bad "compose: a composed SKILL.md was written by the retired composer"

out="$(sc --help 2>&1)"; rc=$?
eq "$rc" 0 "--help: exits 0"
has "$out" "workflows" "--help: points at /adopt's workflows rung"
has "$out" "agents.toml [gates]" "--help: says to remove a gate that calls it"
sc >/dev/null 2>&1; eq "$?" 2 "no subcommand: usage error 2"
sc frobnicate >/dev/null 2>&1; eq "$?" 2 "unknown subcommand: usage error 2"

# THROUGH THE CLI: `baseline skill-compose` must reach the same refusal.
out="$( cd "$REPO" && HOME="$GHOME" bash "$ROOT/bin/baseline" skill-compose check 2>&1 )"; rc=$?
eq "$rc" 3 "baseline skill-compose check: exits 3"
has "$out" "retired (#540" "baseline skill-compose check: ...naming the retirement"

check_summary "check-skill-compose"
