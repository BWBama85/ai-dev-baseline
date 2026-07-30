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

# --- FACT: the required-check drift lint (#122) ------------------------------
# The same three-surface contract, with one twist that makes the pin matter more than usual: this
# check exists to catch a gate that silently stopped gating, so an unpinned version reproduces
# #122's own failure class one level up. The library IMPLEMENTS `required-drift`, the CI job CALLS
# it, and the doc DOCUMENTS its exit codes. Deleting the step from ci.yml is invisible to every
# other check in this repo — nothing else greps the workflow for it — so pin the call site too,
# not just the token.
fact required-drift-lint "fixed:required-drift" -- \
  scripts/lib/repo-settings.sh docs/repo-settings.md
fact required-drift-wired "fixed:repo-settings.sh required-drift" -- \
  .github/workflows/ci.yml

# --- FACT: the pre-arm review guard subcommand (#134) ------------------------
# Identical contract shape, and identically silent when it breaks: the library IMPLEMENTS
# `gate`, the workflow CALLS it before arming, and the doc DOCUMENTS its exit codes. Because a
# failed guard call is treated as "do not arm", a rename in the library alone would silently stop
# auto-merge being armed — the same invisible failure mode `automerge-guard` above exists to
# prevent, so it gets the same pin rather than relying on the structural greps in
# scripts/check-pr-review.sh (which pin the WIRING, not the token).
fact pr-review-guard "fixed:{{PR_REVIEW_LIB}} gate" -- \
  base/workflows/implement-issue.md

# --- FACT: the observe-and-render subcommand (#138) --------------------------
# The worst failure shape of the four. The library IMPLEMENTS `observe` and all three narrating
# workflows CALL it to render a status line. Rename it in the library alone and every call exits 2
# with EMPTY stdout — which the workflows explicitly instruct the agent to read as "say nothing
# about this entity". The mechanism goes permanently inert and reports nothing at all, so nothing
# surfaces the breakage. Pin the exact token across every CALLER (the library spells the
# subcommand as a bare `observe)` case arm, which carries no placeholder to pin; its own rename is
# caught loudly by scripts/check-state-assert.sh instead).
fact state-assert-observe "fixed:{{STATE_ASSERT_LIB}} observe" -- \
  base/workflows/cleanup.md base/workflows/implement-issue.md \
  base/workflows/resolve-pr-threads.md

# --- FACT: the close-out must not predict a future gate effect (#134, #138) --
# The RETIRED phrasing, pinned with `absent:` rather than pinning the corrected sentence. Grepping
# for the correction pins an English sentence: a reflow across the wrap column fails CI with zero
# behavior change, and a freshly-added prediction two lines away leaves the grep green. Pinning
# what must NOT come back survives reformatting and catches the actual regression.
fact no-arm-prediction "absent:will wait on" -- \
  base/workflows/implement-issue.md

# --- FACT: the branch-health predicate subcommand (#78) ----------------------
# Same contract shape as `automerge-ok` above: the library IMPLEMENTS the green-branch predicate,
# the workflow CALLS it before emitting a cut, and two docs DOCUMENT its verdicts. A rename in the
# library alone would leave the workflow invoking a subcommand that no longer exists — and because
# `/roadmap` hard-stops on a failed health read, the failure is loud but the DOCS would silently
# keep describing a predicate nobody can run. Pin the exact token across all four.
# The practice joined this list in #138: its "one home per entity kind" routing table names the
# predicate, and that table renders into EVERY agent's root doc — so a rename that missed it would
# leave the most-read document in the baseline naming a subcommand nobody can run.
fact branch-health-predicate "fixed:branch-health" -- \
  scripts/lib/roadmap-lib.sh base/workflows/roadmap.md \
  docs/release-goal-convention.md docs/roadmap-acceptance.md \
  base/practices/verify-before-asserting.md

# --- FACT: the GitHub Actions app slug (#179) --------------------------------
# `app.slug` is `github-actions`. The app's OWNER login is `github`, and BOTH consumers shipped
# attributing against that near-miss: `branch-health` could then never return `green` on an Actions
# repo (deadlocking the release cut) and `required-drift`'s provenance check silently matched
# nothing (fail-open). `adb_actions_app_slug` in common.sh is now the one home.
#
# Both directions are pinned, which is the whole reason `absent:` exists. Positive presence alone
# would pass a file that calls the accessor AND keeps a hard-coded copy beside it — precisely the
# state this fix removes. The negative pattern is anchored to a NON-comment line, because both
# libraries quote the retired literal in prose to explain the bug.
#
# base/workflows/roadmap.md restates the value deliberately: it is prose an agent pastes into a
# shell, so it can carry a value but never source a library. That is why it is pinned here rather
# than deduplicated away.
fact actions-slug-value  "fixed:github-actions" -- \
  scripts/lib/common.sh base/workflows/roadmap.md
fact actions-slug-home   "fixed:adb_actions_app_slug" -- \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh
fact actions-slug-stale  'absent:^[[:space:]]*[^#[:space:]].*(slug|aslug)[^=]*== *"github"' -- \
  scripts/lib/common.sh scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh \
  base/workflows/roadmap.md

# --- FACT: the branch-merge verdict subcommand (#106, #138) ------------------
# Same routing table, second entry. Previously pinned only by a structural grep in
# scripts/check-cleanup.sh; the practice is now a second restatement site, so the token gets a
# real pin across the library that implements it and both documents that name it.
fact branch-verdict-predicate "fixed:branch-verdict" -- \
  scripts/lib/cleanup-lib.sh base/workflows/cleanup.md \
  base/practices/verify-before-asserting.md
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
# updater its owner had switched off. The neutral rename is tracked in #140.
fact session-start-config "fixed:session_start" -- \
  templates/agents.toml scripts/lib/currency-lib.sh \
  agents/claude/scripts/session-currency.sh base/workflows/cleanup.md \
  docs/installation.md .ai-dev-baseline/decisions.md
# The event this hook binds to. The settings entry, the script's own source gate, and the docs
# must name the SAME trigger: a matcher the script did not also enforce would let a `/clear` or
# a `compact` swap tooling mid-session.
fact session-start-source "fixed:startup" -- \
  agents/claude/settings.hooks.json agents/claude/scripts/session-currency.sh docs/installation.md

# --- FACT: the currency outcome vocabulary (#139) -----------------------------
# currency-lib.sh's `check` returns `<outcome><TAB><message>` and leaves PRESENTATION to the caller,
# because the two triggers legitimately disagree about what deserves attention. That split is only
# safe while the caller's tokens match the ones the library actually emits — and the coupling is
# invisible: rename an outcome in the library and the Claude hook's `case` silently stops matching,
# which costs the `reloadSkills` on an update (a repaired skill stays unavailable for the session)
# or turns the deliberate silence on `busy`/`offline` into a nagging line at every session start.
# Nothing else pins it: the executing tests only assert the outcomes that exist today.
#
# Only the four tokens a caller BRANCHES on are pinned. The workflow step deliberately branches on
# none of them (it keys on message-emptiness), so it is not a consumer of this fact.
#
# Pinned at the CONSTRUCTS, not as bare words. A plain presence check is useless here: every one of
# these tokens also appears in this library's own header, which documents the vocabulary — so
# renaming an emit site while leaving the docs intact would pass a `fixed:` rule. Verified: a
# `fixed:busy` rule did NOT catch `_adb_cu_emit busy` → `_adb_cu_emit occupied`. Anchor on the
# emitter call in the library and on the `case` arm in the hook, which are the two things that must
# agree.
for _o in updated repaired busy offline; do
  fact currency-outcomes "regex:_adb_cu_emit +$_o" -- scripts/lib/currency-lib.sh
done
fact currency-outcomes regex:'updated\|repaired\)' -- agents/claude/scripts/session-currency.sh
fact currency-outcomes regex:'busy\|offline\)'     -- agents/claude/scripts/session-currency.sh

# --- FACT: run-marker ownership (#180) ---------------------------------------
# The marker's `owner` only works because the WRITER and the READER name the same session id. The
# writer is prose an agent executes (`base/workflows/implement-issue.md`); the reader is the Stop
# hook. Nothing else couples them: rename the variable on one side and the field keeps being
# written, keeps being read as empty, and the gate silently reverts to matching every session in
# the checkout — the exact defect this shipped to fix, back with no test failing. The rendered
# skills are pinned too, so a render that drops the writer fails loudly rather than quietly
# shipping an agent that never stamps an owner.
#
# EXPECTED TO CHANGE at #14/#25. Pinning a Claude env-var name in the Codex/Gemini renders is only
# right while `owner` has no reader outside Claude; once those agents get their own enforcement
# hook the writer becomes a placeholder and this rule must narrow to the Claude render. A failure
# here at that point is this tripwire working — see base/workflows/README.md's carve-out list.
_own_all="base/workflows/implement-issue.md agents/claude/scripts/implement-issue-gate.sh"
for _a in claude codex gemini; do _own_all="$_own_all agents/$_a/skills/implement-issue/SKILL.md"; done
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
fact marker-owner-env fixed:'CLAUDE_CODE_SESSION_ID' -- $_own_all
# The field NAME, pinned at the read. Renaming `owner` in the workflow while the hook keeps
# reading `.owner` leaves both halves working and the comparison permanently empty.
fact marker-owner-field fixed:'.owner // ""' -- agents/claude/scripts/implement-issue-gate.sh
# Deliberately NOT pinned here: the absent-owner direction (fall back to enforcement, never inert).
# It is a DIRECTION, not a token, and a word-presence rule over prose is the "general prose
# blocklist" this lint's header warns against. `scripts/check-implement-gate.sh` cases N and O
# assert it against the real gate, which is the stronger guard.

# --- FACT: the PR-argument and reviewer-identity primitives have ONE home (#173) -------------
# The two PR guards each carried private copies of four primitives, and the copies DIVERGED into a
# live fail-open: pr-review.sh's slug parser handled only `scheme://…`, so a scheme-less
# `github.com/other/repo/pull/7` produced an empty slug, skipped the cross-repo refusal, and let the
# arming guard print a head SHA for a pull request the operator never named.
#
# Both directions are pinned, because neither half is sufficient. The POSITIVE rules prove each guard
# still routes through the shared primitive — a library can be perfectly correct while a caller quietly
# stops calling it, which is the state #134 itself described. The `absent:` rules prove no copy came
# back; presence alone cannot catch a file that calls the shared function AND keeps a local definition
# beside it, which is exactly how the divergence above survived. This is the narrow, superseded-value
# use `absent:` exists for, not a general prose blocklist.
_prguards="scripts/lib/pr-review.sh scripts/lib/pr-watch.sh"
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _fn in adb_pr_number adb_pr_slug_check; do
  fact pr-primitives-shared "fixed:$_fn" -- $_prguards
done
# `adb_reviewer_match_jq` is DELIBERATELY NOT PINNED HERE any more. Both guards stopped pasting the
# identity predicate in front of their own jq passes when #167 moved evidence SELECTION into
# `adb_reviewer_evidence`, which prepends it once — so a pin at the guards would demand a call that
# correctly no longer exists. Pinning it at `common.sh` instead was worse than nothing: that file
# both defines and calls it, so the rule could only fail if the function were deleted outright,
# which `check-common-lib.sh`'s direct matrix already catches. A pin that cannot fail is the shape
# this lint's own header warns about.

# --- FACT: ONE reviewer-evidence classifier and ONE head anchor, for BOTH guards (#167) ----------
# The two guards answer different FINAL questions, so they must not share a verdict — but they were
# answering the SAME underlying question ("given everything this reviewer emitted, has this head
# been reviewed, and was it clean?") in two places, and the two answers had already diverged:
# `APPROVED` meant *findings* in the watcher and *satisfied* in the arming guard, and the watcher
# pooled the declared set where the guard required all of it (#185).
#
# Both directions are pinned, because neither half is sufficient. The POSITIVE rules prove each
# guard still routes through the shared primitives — a library can be perfectly correct while a
# caller quietly stops calling it. The `absent:` rules prove no copy came back; presence alone
# cannot catch a file that calls the shared function AND keeps a local definition beside it, which
# is exactly how the #173 divergence survived.
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _fn in adb_reviewer_classes_for_pr adb_fold_reviewer_classes; do
  fact pr-classifier-shared "fixed:$_fn" -- $_prguards
done
# ...and the pipeline's own steps are pinned at the ONE place that now performs them. Pinning these
# at the guards is what would push a future edit back toward open-coding the pipeline in each of
# them, which is the duplication #167 removed at review time.
# shellcheck disable=SC2086
for _fn in adb_paginated_list adb_reviewer_evidence adb_reviewer_classes adb_head_anchor; do
  fact pr-classifier-shared "fixed:$_fn" -- scripts/lib/common.sh
done
# NO `absent:` RULE ON THE PIPELINE'S STEPS, deliberately. The tempting one — "no guard may name
# `adb_paginated_list` / `adb_reviewer_evidence`" — cannot be written as a bare token: both guards
# legitimately NAME them in the pointer comments that tell the next reader where the pipeline went,
# and this lint's own convention is to pin the DEFINITION form (`^name()`) precisely so those
# comments are not mistaken for the drift. There is no definition to pin here, because these were
# never defined in the guards. The positive `adb_reviewer_classes_for_pr` rule above is what proves
# each guard still routes through the shared pipeline, and a guard that re-open-coded the six steps
# would have to stop calling it to do so.
# The anchor was PRIVATE to pr-watch.sh, and D19 recorded its promotion as #167's first step rather
# than something to copy — precisely because `gate` returning 0 on a date-scoped signal is an armed
# merge, i.e. the same predicate at higher stakes. It is pinned in common.sh above; neither guard
# names it directly any more, because the pipeline function decides when it is consulted.
# NO COPY SURVIVES, pinned as the DEFINITION form (`^name()`) so the pointer comments each guard
# keeps — telling the next reader where these went and not to re-inline them — are not themselves
# the drift this rule hunts.
# shellcheck disable=SC2086
for _gone in '^head_anchor\(\)' '^is_utc_instant\(\)' '^read_list\(\)'; do
  fact pr-classifier-no-copies "absent:$_gone" -- $_prguards
done
# The far-future staleness sentinel has ONE spelling, in common.sh. A guard that re-inlines the
# literal is a guard that can be given a DIFFERENT one — and the failure mode of a wrong sentinel is
# silent: an empty or low value makes every signal read as fresh, which is the false-clean/false-arm
# direction this whole family exists to prevent.
# shellcheck disable=SC2086
fact pr-classifier-no-copies 'absent:9999-12-31' -- $_prguards
# The declaration normalizer is reached through role-dispatch's CLI, so the pinned token is the
# subcommand rather than the function name. The two docs that name WHICH reader the merge gate uses are
# pinned with it: they described `--declared` (the tri-state reader this one wraps) for a while after
# the guards had moved, and a doc naming the wrong reader is exactly the drift this lint exists for.
# shellcheck disable=SC2086
fact pr-primitives-shared fixed:'bots --comparable' -- \
  $_prguards scripts/lib/role-dispatch.sh base/roles.md docs/roles-and-agents.md
# The git-origin anchor. state-assert.sh (#138) had the only copy until the guards needed the same
# defence against the same `GH_REPO` override; the guards reach it through adb_pr_slug_check, so its
# consumers are the library that defines it and the module that calls it directly.
fact pr-primitives-shared fixed:'adb_git_origin_slug' -- \
  scripts/lib/common.sh scripts/lib/state-assert.sh
# NO COPY SURVIVES. Pinned as the DEFINITION form (`^name()`), so the pointer comments in each guard
# that name the retired primitives — telling the next reader where they went and not to re-inline
# them — are not themselves the drift this rule hunts.
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _gone in '^parse_pr_arg\(\)' '^parse_pr_slug\(\)'; do
  fact pr-primitives-no-copies "absent:$_gone" -- $_prguards
done
# The reviewer-identity half, pinned as the STRIP IDIOM rather than a function name: the suffix is
# now handled only on the API side, inside common.sh's shared jq def, so an ANCHORED `[bot]` match
# anywhere in a guard means the rule has been re-inlined. The DIRECTION of such a copy is the entire
# defect (#176): stripping the declaration too let a human account named `foo` satisfy a declared
# `foo[bot]`.
#
# The `\\*` is load-bearing and this rule was WRONG without it, which a negative test caught: the two
# real idioms are `sed 's/\[bot\]$//'` and jq's `sub("\\[bot\\]$"; "")`, so the bracket is always
# BACKSLASH-ESCAPED and a pattern for a contiguous `[bot]$` matches neither. It passed by matching
# nothing at all — a pin that cannot fire, which is worse than no pin. `bot\\*\]\$` accepts any number
# of escaping backslashes before the closing bracket and so catches both spellings.
# shellcheck disable=SC2086
fact pr-primitives-no-copies 'absent:bot\\*\]\$' -- $_prguards
# ...and the private anchor is gone from its old home rather than shadowing the promoted one.
fact pr-primitives-no-copies 'absent:^_sa_local_slug\(\)' -- scripts/lib/state-assert.sh

check_result "canonical facts consistent across their consumers"
