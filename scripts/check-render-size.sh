#!/usr/bin/env bash
# ai-dev-baseline — scripts/render-size.sh must be seen going RED (#359).
#
# Usage: bash scripts/check-render-size.sh   (exit 0 = pass, 1 = fail)
#
# render-size.sh reports; the only thing it can FAIL on is mechanics, and that arm's failure mode
# is silence — an enumeration that quietly stopped deriving the expected set prints a clean report
# of whatever happens to exist. So every mechanical rule is driven red against a throwaway fixture
# tree, and the size rules are driven the other way: an artifact made arbitrarily large must still
# exit 0, because there is no ceiling.
#
# Never touches the tracked tree — every case builds its own fixture under one `mktemp -d`.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and before the cd; the load is confirmed
# by probing for the function, not by the source's exit status.
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

REPO="$PWD"
WORK="$(mktemp -d)" || { echo "check-render-size: FATAL — cannot create a scratch directory" >&2; exit 1; }
check_exit_guard "check-render-size" "rm -rf \"$WORK\""

# mk_fixture <name> — a minimal tree with the shape render-size.sh derives from. Prints its root.
# Two workflow sources plus a README (which must yield no rows), three agents, nine artifacts.
mk_fixture() {
  local fx="$WORK/$1" agent name
  mkdir -p "$fx/scripts/lib" "$fx/base/workflows" || return 1
  cp "$REPO/scripts/render-size.sh" "$fx/scripts/render-size.sh" || return 1
  cp "$REPO/scripts/lib/common.sh" "$fx/scripts/lib/common.sh" || return 1
  for name in alpha beta README; do
    printf 'source %s\n' "$name" > "$fx/base/workflows/$name.md" || return 1
  done
  for agent in claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md; do
    mkdir -p "$fx/agents/${agent%%:*}" || return 1
    printf 'root doc for %s\nsecond line\n' "${agent%%:*}" > "$fx/agents/${agent%%:*}/${agent#*:}" || return 1
    for name in alpha beta; do
      mkdir -p "$fx/agents/${agent%%:*}/skills/$name" || return 1
      printf -- '---\nname: %s\n---\n\nbody words here\n' "$name" > "$fx/agents/${agent%%:*}/skills/$name/SKILL.md" || return 1
    done
  done
  printf '%s\n' "$fx"
}

# run_rs <fixture-root> — run the copied command; set RS_OUT / RS_ERR / RS_RC.
run_rs() {
  RS_RC=0
  ( cd "$1" && bash scripts/render-size.sh ) >"$WORK/out" 2>"$WORK/err" || RS_RC=$?
  RS_OUT="$(cat "$WORK/out")"
  RS_ERR="$(cat "$WORK/err")"
}

# --- the green run ------------------------------------------------------------------------------

fx="$(mk_fixture green)" || bad "fixture: could not build the green tree"
run_rs "$fx"
yes "$RS_RC" "green: a complete tree exits 0"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "10" "green: 9 artifact rows + TOTAL"
has "$RS_OUT" "agents/claude/CLAUDE.md" "green: the claude root doc is measured"
has "$RS_OUT" "agents/gemini/skills/beta/SKILL.md" "green: every agent's every skill is measured"
hasnt "$RS_OUT" "README" "green: base/workflows/README.md is not a workflow source"
# Every row is exactly four TAB-separated fields — the contract a consumer parses.
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')" "0" "green: every row has 4 TAB fields"
# TOTAL is the sum of the rows above it, not an independently computed number.
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" { l += $2; w += $3; t += $4 } END { print l, w, t }')" \
   "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "TOTAL" { print $2, $3, $4 }')" \
   "green: TOTAL equals the sum of the artifact rows"
has "$RS_ERR" "measured 3 root doc(s) and 6 skill(s)" "green: it says what it checked"
has "$RS_ERR" "not a tokenizer" "green: the approximation is stated, not implied"

# --- the mechanical failures ---------------------------------------------------------------------

fx="$(mk_fixture missing)" || bad "fixture: could not build the missing tree"
rm -f "$fx/agents/codex/skills/beta/SKILL.md"
run_rs "$fx"
no "$RS_RC" "missing: a missing artifact fails the command"
has "$RS_ERR" "MISSING agents/codex/skills/beta/SKILL.md" "missing: the diagnostic names the artifact"
# The other eight are still measured: one gap must not hide the rest of the report.
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "9" "missing: the surviving artifacts are still reported"

fx="$(mk_fixture empty)" || bad "fixture: could not build the empty tree"
: > "$fx/agents/claude/skills/alpha/SKILL.md"
run_rs "$fx"
no "$RS_RC" "empty: a zero-byte artifact fails the command"
has "$RS_ERR" "EMPTY agents/claude/skills/alpha/SKILL.md" "empty: the diagnostic names the artifact"

fx="$(mk_fixture noworkflows)" || bad "fixture: could not build the no-source tree"
rm -f "$fx"/base/workflows/*.md
run_rs "$fx"
no "$RS_RC" "no-sources: a collapsed derivation fails rather than printing a short clean report"
has "$RS_ERR" "named no workflow source" "no-sources: the diagnostic says the derivation collapsed"

fx="$(mk_fixture badname)" || bad "fixture: could not build the bad-name tree"
printf 'source\n' > "$fx/base/workflows/two words.md"
run_rs "$fx"
no "$RS_RC" "bad-name: a workflow name that would forge a TSV field boundary fails the command"
has "$RS_ERR" "UNNAMEABLE" "bad-name: the diagnostic names the rule"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')" "0" "bad-name: the emitted rows stay 4-field"

if [ "$(id -u)" -eq 0 ]; then
  echo "check-render-size: SKIP the unreadable case — running as root, where mode 000 is still readable"
else
  fx="$(mk_fixture unreadable)" || bad "fixture: could not build the unreadable tree"
  chmod 000 "$fx/agents/gemini/GEMINI.md"
  run_rs "$fx"
  chmod 644 "$fx/agents/gemini/GEMINI.md"
  no "$RS_RC" "unreadable: an unreadable artifact fails the command"
  has "$RS_ERR" "UNREADABLE agents/gemini/GEMINI.md" "unreadable: the diagnostic names the artifact"
fi

# --- and the direction it must NEVER fail in ------------------------------------------------------
# The owner rejected caps (2026-08-15). A ceiling reintroduced here would look exactly like the
# mechanical arm above, so the absence of one is asserted rather than assumed.

fx="$(mk_fixture nocap)" || bad "fixture: could not build the no-cap tree"
awk 'BEGIN { for (i = 0; i < 40000; i++) print "a line of instruction prose that costs context" }' \
  >> "$fx/agents/claude/skills/alpha/SKILL.md"
run_rs "$fx"
yes "$RS_RC" "no-cap: an arbitrarily large artifact still exits 0"
big="$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "agents/claude/skills/alpha/SKILL.md" { print $4 }')"
if [ -n "$big" ] && [ "$big" -gt 100000 ]; then ok; else bad "no-cap: the large artifact's approx_tokens ($big) did not grow with it"; fi

# --- usage ---------------------------------------------------------------------------------------

fx="$(mk_fixture usage)" || bad "fixture: could not build the usage tree"
RS_RC=0; ( cd "$fx" && bash scripts/render-size.sh --nonsense ) >/dev/null 2>&1 || RS_RC=$?
eq "$RS_RC" "2" "usage: an unknown argument exits 2, never a silent full run"
RS_RC=0; ( cd "$fx" && bash scripts/render-size.sh -h ) >"$WORK/out" 2>&1 || RS_RC=$?
yes "$RS_RC" "usage: -h exits 0"
has "$(cat "$WORK/out")" "approx_tokens" "usage: -h prints the output contract"

check_summary "check-render-size"
