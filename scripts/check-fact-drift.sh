#!/usr/bin/env bash
# ai-dev-baseline — fact-drift lint.
#
# Some FACTS are unavoidably restated in more than one hand-written doc: the gate
# axis list, the cross-agent invocation commands, the dispatch hang backstop, and
# the role-resolution order. Those restatements are exactly where drift is born (issue
# #30). This lint pins each fact to its canonical source and asserts every consumer
# that restates it still carries the canonical token — so a value changed in one place
# but not the others fails CI instead of silently diverging.
#
# It is deliberately a small, ALLOWLISTED check — not a natural-language equivalence
# engine. Each `fact` rule asserts that a stable token (an axis name, a literal
# invocation string, "2700", "hang backstop") is PRESENT in each file that restates it.
# It never forbids incidental wording, so rewording a doc never trips it; only dropping
# or changing a canonical value does.
#
# `stale` is the narrow negative counterpart, used ONLY for a value a fact has retired:
# presence-checking cannot catch a file that carries the new value AND keeps the old one
# beside it, which is how a superseded figure survives a repoint (#93). Reach for it when
# a fact replaces an earlier one, never as a general prose blocklist.
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

# fact <label> fixed:<token>|regex:<pattern>|absent:<pattern> -- <file> [<file>...]
# Asserts the token/pattern is present in every listed file — or, for `absent:`, that it is NOT.
#
# `absent:` is the negative counterpart, for a value a fact has SUPERSEDED. Positive presence
# alone cannot enforce a replacement: a file carrying the new figure AND the old one beside it
# passes every positive rule while still telling the reader the wrong thing — which is how a stale
# "≥7-minute" bound would survive a repoint to 45 minutes (#93). Reach for it only when a fact
# retires an earlier value, never as a general prose blocklist.
fact() {
  local label="$1" spec="$2" ; shift 2
  [ "$1" = "--" ] && shift
  local kind="${spec%%:*}" needle="${spec#*:}" f
  for f in "$@"; do
    case "$kind" in
      fixed)  req_fixed  "$f" "$needle" "$label" ;;
      regex)  req_regex  "$f" "$needle" "$label" ;;
      absent) req_absent "$f" "$needle" "$label" ;;
      *) check_note "[$label] unknown spec kind '$kind' (want fixed:/regex:/absent:)"; check_fail ;;
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

# --- FACT: the dispatch hang backstop (#93) ----------------------------------
# Canonical source: _ADB_RD_TIMEOUT_SECS in scripts/lib/role-dispatch.sh. The bound is 45 minutes
# (2700 s) and is a HANG BACKSTOP, not a work budget — it stops a wedged process and otherwise
# stays out of the way. Every doc that states the bound must carry the figure, the seconds value,
# the override's name (so the knob stays discoverable rather than buried in the library), and the
# backstop framing (so nobody re-tunes it down toward typical runtime, which is the regression).
# ONE list, used by BOTH directions below. Keeping the positive rules and the superseded sweep on
# separate lists is how the anti-drift lint grows its own drift: add a consumer to one list only,
# and that file gets checked for the new value but never swept for the retired one (or vice-versa)
# — precisely the half-updated state these rules exist to catch.
# The rendered skills are included so a typo'd render path fails loudly: an `absent:` rule is
# vacuously true on a file that does not exist, while `fixed:`/`regex:` report the bad path.
# CHANGELOG.md is deliberately absent: its entries record what shipped at the time, and rewriting
# shipped history to satisfy a lint would be a lie, not a fix.
_bs_all="base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md"
_bs_all="$_bs_all docs/design-principles.md agents/codex/config.toml.sample scripts/lib/role-dispatch.sh"
# docs/adding-an-agent.md is on the list because it TELLS A CONTRIBUTOR what to write about
# timeouts for a new agent. Omitting it let the guide keep directing people to "name the concrete
# minimum timeout" — i.e. to recreate the work-budget model this fact retires — while the sweep
# passed (bot review, PR #105). A doc that propagates a fact is a consumer of it.
_bs_all="$_bs_all docs/adding-an-agent.md"
for _a in claude codex gemini; do _bs_all="$_bs_all agents/$_a/skills/implement-issue/SKILL.md"; done
# The seconds value and the override name are only spelled out where the bound is *explained*, not
# in every file that merely mentions it — so these two keep a narrower list.
_bs_num="base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md"
_bs_num="$_bs_num scripts/lib/role-dispatch.sh"

# shellcheck disable=SC2086  # deliberate word-split of the space-separated file lists
{
fact backstop-45min   regex:'45[-[:space:]](min|minute)'  -- $_bs_all
fact backstop-framing fixed:'hang backstop'               -- $_bs_all
fact backstop-secs    regex:'2700'                        -- $_bs_num
fact backstop-env     fixed:'ADB_DISPATCH_TIMEOUT_SECS'   -- $_bs_num

# SUPERSEDED by the rules above (#93): the 420 s bound sat near typical runtime, so ordinary
# high-reasoning passes tripped it; and the `420000`-`600000` ms guidance taught every reader to
# cap the surrounding call at 10 minutes — a HARNESS artifact, not a property of codex.
fact backstop-stale-ms   absent:'(4[28]0|600)[,]?000'                                   -- $_bs_all
fact backstop-stale-secs absent:'(^|[^0-9])420([^0-9]|$)'                               -- $_bs_all
fact backstop-stale-7min absent:'([≥>]=?[[:space:]]*7|least[[:space:]]*7|3[–-]7)[[:space:]-]*min' -- $_bs_all
}

# --- FACT: gap_analysis never substitutes another agent (#93) ----------------
# The behavioural rule this change actually introduced, and the one an agent is most likely to
# quietly violate under time pressure — a silently-substituted reviewer is exactly what made
# `agents.toml` fiction for three runs. It was restated across six hand-written surfaces and
# pinned by nothing, while the *number* got seven rules. Pin the rule too.
# shellcheck disable=SC2086
fact gap-analysis-no-fallback fixed:'never substitut' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md

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

# --- FACT: the gap-analysis in-flight lock filename (#84) --------------------
# A cross-skill contract: /implement-issue TAKES and RELEASES the lock around its gap dispatch,
# and /cleanup's state-scan RECOGNISES it (so a live pass's artifacts are never swept mid-write).
# The two sides only meet on this literal filename, and a rename that misses one side fails
# SILENTLY in the destructive direction — cleanup reads "no dispatch in flight" and deletes the
# findings the dispatch is still writing. Pin the string so a rename must change both together.
fact gap-analysis-lock fixed:'gap-analysis.lock' -- \
  scripts/lib/cleanup-lib.sh base/workflows/implement-issue.md

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

# --- FACT: the auto-merge guard subcommand (#87) -----------------------------
# `automerge-ok` is the contract between the library that IMPLEMENTS the guard, the workflow step
# that CALLS it before arming auto-merge, and the doc that DOCUMENTS its exit codes. Renaming the
# subcommand in the library alone would leave the workflow calling a subcommand that no longer
# exists — and since a failed guard call is treated as "do not arm", the failure mode is silent:
# auto-merge simply stops being armed and nobody notices. Pin the exact token.
fact automerge-guard "fixed:automerge-ok" -- \
  scripts/lib/repo-settings.sh base/workflows/implement-issue.md docs/repo-settings.md

# --- FACT: the branch-health predicate subcommand (#78) ----------------------
# Same contract shape as `automerge-ok` above: the library IMPLEMENTS the green-branch predicate,
# the workflow CALLS it before emitting a cut, and two docs DOCUMENT its verdicts. A rename in the
# library alone would leave the workflow invoking a subcommand that no longer exists — and because
# `/roadmap` hard-stops on a failed health read, the failure is loud but the DOCS would silently
# keep describing a predicate nobody can run. Pin the exact token across all four.
fact branch-health-predicate "fixed:branch-health" -- \
  scripts/lib/roadmap-lib.sh base/workflows/roadmap.md \
  docs/release-goal-convention.md docs/roadmap-acceptance.md
# The order these two settings are written in is the whole safety property (#87): required checks
# FIRST, then allow_auto_merge. Pin the setting name across the library that writes it, the doc
# that explains the order, and the workflow step that depends on it having been done.
fact allow-auto-merge "fixed:allow_auto_merge" -- \
  scripts/lib/repo-settings.sh docs/repo-settings.md

# --- FACT: the install-currency config surface (#36, #139) -------------------
# The mode key is a multi-way contract: the TEMPLATE advertises it, currency-lib.sh is the one
# thing that READS it, both triggers (the Claude SessionStart hook and the /cleanup step) are
# governed by it, and the DOC + decision log tell the operator it is global-only. Renaming the
# table or the key in one place would leave the others describing a knob that silently does
# nothing — and "silently does nothing" is precisely the failure this feature exists to remove.
#
# The key is still spelled `session_start` even though #139 gave it a second, non-session trigger.
# That is deliberate backward compatibility: an `off` that stopped applying would re-enable an
# updater its owner had switched off. The neutral rename is tracked separately.
fact session-start-config "fixed:session_start" -- \
  templates/agents.toml scripts/lib/currency-lib.sh \
  agents/claude/scripts/session-currency.sh base/workflows/cleanup.md \
  docs/installation.md .ai-dev-baseline/decisions.md
# The event this hook binds to. The settings entry, the script's own source gate, and the docs
# must name the SAME trigger: a matcher the script did not also enforce would let a `/clear` or
# a `compact` swap tooling mid-session.
fact session-start-source "fixed:startup" -- \
  agents/claude/settings.hooks.json agents/claude/scripts/session-currency.sh docs/installation.md

check_result "canonical facts consistent across their consumers"
