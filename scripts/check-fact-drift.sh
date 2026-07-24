#!/usr/bin/env bash
# ai-dev-baseline — fact-drift lint.
#
# Some FACTS are unavoidably restated in more than one hand-written doc: the gate
# axis list, the cross-agent invocation commands, the codex ≥7-minute timeout, and
# the role-resolution order. Those restatements are exactly where drift is born (issue
# #30). This lint pins each fact to its canonical source and asserts every consumer
# that restates it still carries the canonical token — so a value changed in one place
# but not the others fails CI instead of silently diverging.
#
# It is deliberately a small, ALLOWLISTED, positive-presence check — not a
# natural-language equivalence engine. Each rule asserts that a stable token (an axis
# name, a literal invocation string, the number 7, "420000") is PRESENT in each file
# that restates it. It never forbids incidental wording (e.g. prose that correctly
# calls the 2-minute default "too short"), so rewording a doc never trips it; only
# dropping or changing a canonical value does.
#
# The token appears in the lint too — that is intentional, not a fourth copy: the
# canonical source (base/roles.md, scripts/lib/project-gates.sh) is itself in every
# rule's file list, so renaming the value there fails the lint until the rename is
# propagated to the token here AND to every consumer together. Adding a fact = add a
# `fact <label> <token-or-pattern> -- <files…>` line. Adding a consumer that restates
# an existing fact = append the file to that fact's list.
#
# Usage: bash scripts/check-fact-drift.sh   (exit 0 = no drift, 1 = drift found)

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "fact-drift"

# fact <label> fixed:<token>|regex:<pattern> -- <file> [<file>...]
# Asserts the token/pattern is present in every listed file.
fact() {
  local label="$1" spec="$2" ; shift 2
  [ "$1" = "--" ] && shift
  local kind="${spec%%:*}" needle="${spec#*:}" f
  for f in "$@"; do
    case "$kind" in
      fixed) req_fixed "$f" "$needle" "$label" ;;
      regex) req_regex "$f" "$needle" "$label" ;;
    esac
  done
}

# --- FACT: gate axes ---------------------------------------------------------
# Canonical source: the _adb_emit <axis> calls in the gate detector. Every doc that
# enumerates the gate list must mention every axis, so adding an axis to the code
# without documenting it fails here.
axes="$(grep -oE '_adb_emit [a-z]+' scripts/lib/project-gates.sh | awk '{print $2}')"
[ -n "$axes" ] || { check_note "[gate-axes] could not derive axes from scripts/lib/project-gates.sh"; check_fail; }
for a in $axes; do
  fact gate-axes "fixed:$a" -- docs/per-project-overrides.md docs/roles-and-agents.md templates/agents.toml
done

# --- FACT: cross-agent invocations -------------------------------------------
# Canonical home: base/roles.md's cross-agent table. Each invocation is checked in
# every doc that restates THAT agent's entrypoint (incl. the hand-written per-agent
# READMEs, which are otherwise a silent drift surface).
# scripts/lib/role-dispatch.sh is the runtime EMBODIMENT of this table (issue #15): it necessarily
# restates each agent's CLI to invoke it, so it is pinned here alongside the prose consumers — a
# command changed in base/roles.md must change in the helper too, or this lint fails.
fact invocation-codex fixed:'codex exec --cd' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md \
  scripts/lib/role-dispatch.sh
fact invocation-gemini fixed:'agy -p' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/gemini/README.md \
  scripts/lib/role-dispatch.sh
fact invocation-claude fixed:'claude -p' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md \
  scripts/lib/role-dispatch.sh

# --- FACT: codex exec timeout minimum ----------------------------------------
# The bound is ≥7 minutes (420000 ms). Every doc that states the codex timeout must
# carry the 7-minute bound; the two that give the millisecond form must agree on it.
fact codex-timeout-7min regex:'7[-[:space:]]min' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md \
  agents/codex/README.md agents/codex/config.toml.sample scripts/lib/role-dispatch.sh
fact codex-timeout-ms regex:'420[,]?000' -- \
  base/workflows/implement-issue.md docs/roles-and-agents.md

# --- FACT: role-resolution order ---------------------------------------------
# The order is repo agents.toml → global default manifest → built-in default.
fact resolution-order fixed:'global default' -- base/roles.md docs/roles-and-agents.md scripts/lib/role-dispatch.sh
fact resolution-order fixed:'built-in'       -- base/roles.md docs/roles-and-agents.md scripts/lib/role-dispatch.sh

# --- FACT: cleanup origin/HEAD symref filter (#38) ---------------------------
# The remote-enumeration pipeline that drops the bare `origin` symref lives in the workflow
# doc AND is re-asserted by its regression test — which can only re-implement, not source, a
# pipeline that lives inside a markdown fence. Pin the critical fragment so editing the doc's
# pipeline without updating the test (or vice-versa) fails CI instead of silently drifting.
fact cleanup-origin-symref "fixed:grep '^origin/'" -- \
  base/workflows/cleanup.md scripts/check-cleanup-enum.sh

# --- FACT: default async-bot reviewer allowlist (#26) ------------------------
# adb_dispatch_bots() in role-dispatch.sh is the source of the default bot logins; the
# resolve-pr-threads workflow re-lists them in prose for the reader. Pin each login so the prose
# can't silently drift from the code default (grep -F, so the [bot] brackets are literal).
for bot in chatgpt-codex-connector 'gemini-code-assist[bot]' gemini-code-assist \
           'copilot-pull-request-reviewer[bot]' 'copilot[bot]' 'github-actions[bot]' \
           'claude[bot]' 'claude-code[bot]'; do
  fact reviewer-bots-default "fixed:$bot" -- \
    scripts/lib/role-dispatch.sh base/workflows/resolve-pr-threads.md
done

# --- FACT: release-goal convention label string (#27/#71) --------------------
# The `release-blocker` label is load-bearing across three surfaces that MUST agree: the setup
# helper CREATES it, the /roadmap workflow QUERIES it for the readiness predicate/gauge, and the
# module doc DOCUMENTS it. A rename in one place that misses the others silently breaks readiness.
# Pin the exact string (grep -F) so any divergence fails CI. (The milestone NAMES are deliberately
# NOT pinned into the generic shared law — issues-and-scope.md stays convention-agnostic, #27.)
fact release-blocker-label "fixed:release-blocker" -- \
  docs/release-goal-convention.md base/workflows/roadmap.md scripts/lib/release-convention.sh

check_result "canonical facts consistent across their consumers"
