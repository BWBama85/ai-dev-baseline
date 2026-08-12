#!/usr/bin/env bash
# ai-dev-baseline — the ADOPTION COMPLETION CONTRACT and its fail-closed verifier (#81).
#
# `/adopt` (#20) answers "what does this project already have, and what must be reconciled".
# It does NOT answer "is this project now ready to run the loop", and those are different
# questions with different failure modes. Adoption used to install *machinery* and leave the
# hardest decisions — which issues are in the next release, what happens to pre-existing
# milestones, whether the gates actually execute — to whoever noticed they were missing. The
# measured failure mode is not a crash: `unraid-cache-cleaner` came out of adoption with a
# `Next release` milestone holding ZERO issues, so `/roadmap` correctly emitted nothing, and
# adoption "succeeded" having produced a dead flow.
#
# So this library is a REPORTER with a verdict, and three properties do the work:
#
#   1. THE CONTRACT IS DATA, not prose. `contract` prints the rungs, their owners and their
#      titles, and every other subcommand derives from it. A rung cannot be silently dropped
#      by a caller that forgot it, because a rung nobody reported is `unknown`, never absent.
#   2. IT FAILS CLOSED. Unknown is never green. An unreadable tracker, a missing fact and a
#      malformed record all resolve to a NON-green verdict — never to "probably fine", which
#      is the flattering answer and the one that ships a half-adopted project.
#   3. IT SAYS HOW MUCH IT LOOKED AT. Every report ends with the number of rungs evaluated
#      against the number in the contract. A verifier's failure mode is SILENCE — it passes
#      green having checked nothing — so "0 of 12 evaluated" must be visible rather than
#      indistinguishable from a clean run (base/practices/self-review.md).
#
# WHAT IT NEVER DOES: mutate the adopted project. D60 bounds `/adopt` to a scan that creates
# only two files that do not yet exist, and #326 owns executing the migration plan. A verifier
# that repaired what it found would be that executor by another name. Every rung is therefore
# an OBSERVATION plus an OWNER — the answer to the issue's "names precisely what remains and
# who must decide it" — and remediation is the operator's.
#
# Deliberately NOT in scope, because each has its own home and duplicating it would create a
# second model that drifts from the first:
#   - deciding a release's contents          -> roadmap-lib.sh release-ready / compose-*
#   - reading repo settings                  -> repo-settings.sh status
#   - detecting or running gates             -> project-gates.sh detect / status / run
#   - the release-convention primitives       -> release-convention.sh status
#   - classifying a project's own artifacts  -> adopt-lib.sh scan / classify / plan
# This file consumes those readers' output. It does not re-derive any of them.
#
# Usage:
#   adopt-readiness.sh contract                        # <rung>TAB<owner>TAB<title>, the canonical list
#   adopt-readiness.sh probe <project-root> [--agents a,b]   # OFFLINE rung records (filesystem only)
#   adopt-readiness.sh facts [--release-milestone N]   # LIVE tracker facts as JSON (the only gh reads)
#   adopt-readiness.sh tracker                         # tracker rung records (facts JSON on stdin)
#   adopt-readiness.sh receipt run <root>              # EXECUTE this HEAD's gates and record the outcome
#   adopt-readiness.sh receipt check <root>            # ok | failed | stale | none  (exit 0 | 12 | 10 | 11)
#   adopt-readiness.sh verdict                         # decide + report (rung records on stdin)
#   adopt-readiness.sh status [root]                   # probe + facts + tracker + verdict, end to end
#
# Exit codes for `verdict`: 0 green · 10 red (something remains) · 11 indeterminate (a fact
# could not be established) · 2 usage. Red and indeterminate are BOTH non-green; they are
# separate because "this is not done" and "I could not tell" need different next moves.

# bash 5.3 runtime floor (#256) — before `set -u`, because an unbound expansion while a library
# loads is fatal under `set -u` and would kill the shell before this script runs a line of its
# own. The load is confirmed by PROBING FOR THE FUNCTION rather than by the source's exit
# status: a sourced file returns its LAST command's status, which says nothing about the load.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf 'adopt-readiness: FATAL — scripts/lib/common.sh is missing or corrupt\n' >&2
  exit 1
}
adb_require_bash "$@"
set -u

usage() { adb_usage "$0"; }
die() { printf 'adopt-readiness: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"

# --- the contract ------------------------------------------------------------------------------
# ONE HOME for what "ready" means. Every rung below is a line item from #81's own checklist; the
# order is the checklist's order, because a report that reads top-to-bottom in the same sequence
# the operator was given is one they can follow.
#
# `owner` is `agent` or `owner`, and it is the load-bearing half of the issue's requirement that
# an unmet contract "names precisely what remains AND WHO MUST DECIDE IT":
#   agent — a run can finish this without a human judgement (install something, run something).
#   owner — this needs a decision only the project's owner can make (what is in the release,
#           what happens to a pre-existing milestone, whether to change repo settings).
# It is NOT a severity. An `agent` rung left undone blocks exactly as hard as an `owner` one.
#
# ONE CHECKLIST ITEM IS DELIBERATELY ABSENT, and its absence is recorded rather than silent.
# #81's list includes "Project knowledge map created (#33) for a foreign codebase", and that  (adb-claim-ok: #33 was closed NOT_PLANNED — the reference records why a checklist item was DROPPED; it tracks nothing)
# issue was closed NOT_PLANNED on 2026-07-31 — the knowledge map does not exist and is not
# planned — so a rung requiring it could never go green for any project, which is a permanently
# red contract rather than a contract. It is dropped, and this paragraph is why.
#
# Adding a rung means adding a row here and a producer for it; `verdict` needs no change,
# because it reads the contract rather than a second list of its own.
_ar_contract() {
  cat <<EOF
harness${TAB}agent${TAB}the baseline is installed and this project's agents can resolve its skills
manifest${TAB}agent${TAB}agents.toml exists and declares [roles]
shape${TAB}agent${TAB}the repo shape resolved — git root, nesting and out-of-repo docs are known
gates${TAB}agent${TAB}gates are detected AND were executed once at this commit, or explicitly disabled
milestones${TAB}agent${TAB}the release and backlog milestones and the blocker label exist
slate${TAB}owner${TAB}the active release milestone is armed — it holds at least one issue
unmilestoned${TAB}agent${TAB}no open issue is in limbo — every one sits in a milestone
dispositions${TAB}owner${TAB}every pre-existing milestone has a recorded disposition
roadmap${TAB}agent${TAB}exactly one roadmap artifact exists — bootstrapped or adopted, never duplicated
settings${TAB}owner${TAB}repo settings were offered and applied with consent, in the correct order
release${TAB}owner${TAB}the release command resolves to a real target
decisions${TAB}agent${TAB}a decision log exists for the unknowns adoption hit
EOF
}

cmd_contract() {
  [ "$#" -eq 0 ] || die "contract: takes no arguments"
  _ar_contract
}

# Is $1 one of the contract's rungs?
_ar_is_rung() {
  local r
  while IFS="$TAB" read -r r _ _; do [ "$r" = "$1" ] && return 0; done < <(_ar_contract)
  return 1
}

# --- emit one rung record ------------------------------------------------------------------------
# `<rung>TAB<status>TAB<detail>`. A detail is free text for a human and is never parsed; it is
# where the evidence goes, so a red rung reads as an instruction rather than a label.
_ar_emit() {
  local rung="$1" status="$2" detail="${3:-}"
  # BOTH delimiters are neutralised, and the newline is the one that matters more. A tab forges a
  # field boundary and shifts the record; a NEWLINE forges a RECORD boundary — the tail of the
  # detail then arrives at `verdict` as its own line, whose first field is some fragment of prose
  # that is not a rung name, and the whole run dies with a usage error naming a "rung" the
  # operator never wrote. Neither is hypothetical: a detail interpolates milestone titles and
  # filesystem paths out of the SCANNED PROJECT, which is not ours and whose titles come from the
  # GitHub API, where a newline is legal.
  detail="${detail//"$TAB"/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$rung" "$status" "$detail"
}

# --- gate execution receipt ----------------------------------------------------------------------
# "DETECTION IS NOT WORKING." #81's sharpest gate requirement is that adoption must *execute*
# each detected gate once and report the result, because a gate that is detected but errors is a
# silent no-op — the exact failure #35 exists to prevent, arriving through the front door.
#
# But executing them cannot be folded into a status read, and the reason is concrete rather than
# fastidious: `run` executes commands the SCANNED PROJECT configured, in that project, and a
# `format` gate in several ecosystems rewrites files in place. /adopt's boundary (D60) forbids
# touching the project's files, and "re-running adoption changes nothing" is one of #81's own
# acceptance criteria. So execution is a separate, consent-gated act, and what the verifier reads
# is its RECEIPT.
#
# The receipt is keyed by (project root, HEAD commit, gate-configuration digest) because each of
# the three invalidates it for a different reason:
#   - HEAD, because gates pass or fail against a tree, and yesterday's green says nothing about
#     today's commit;
#   - the gate configuration, because editing `agents.toml [gates]` changes WHICH commands the
#     receipt is a receipt for — the same HEAD with a different gate set is unverified;
#   - the root, so a receipt cannot be carried between checkouts.
# Anything that does not match is `stale`, which is NOT `ok`. There is deliberately no "close
# enough".
#
# It lives in the agent's own state dir, never in the scanned project: writing a file into a
# project this workflow promises not to modify would break the boundary to record that the
# boundary was kept.
_ar_receipt_path() {
  local root="$1"
  printf '%s/adopt-gate-receipt.tsv' "${ADB_STATE_DIR:-$root/.claude/state}"
}

# The digest of what the gates ARE right now — every record project-gates.sh would resolve.
# `status`, not `detect`: `detect` prints only RUN gates, so disabling a gate (`= ""`) or
# declaring it N/A would leave the digest unchanged and a receipt written before the change
# would still validate. The digest must move whenever the gate configuration moves.
_ar_gate_digest() {
  local root="$1" recs
  recs="$(bash "$(dirname "${BASH_SOURCE[0]:-$0}")/project-gates.sh" status "$root" 2>/dev/null)" || return 1
  # A missing checksum tool is not "no gates changed" — it is an unanswerable question, and the
  # caller must see it as one.
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$recs" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$recs" | sha256sum | cut -d' ' -f1
  else return 1
  fi
}

_ar_head_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null
}

# THE RECEIPT IS WRITTEN BY THE RUN, NEVER BY A CALLER'S SAY-SO. The first version of this
# exposed a bare `receipt write`, and that is the whole defect the gate rung exists to catch,
# reintroduced one level up: a receipt asserting "the gates were executed" that nothing had
# executed. A caller could satisfy "detection is not working" by writing a file. So `run` is the
# only producer — it executes the gates itself and records WHAT HAPPENED, including a failure.
#
# A FAILING RUN STILL WRITES A RECEIPT, and that is deliberate rather than sloppy: "the gates
# ran and went red" is a different fact from "the gates have never run", it is one the operator
# must see, and discarding it would make a failing project indistinguishable from an unverified
# one on the next `check`.
cmd_receipt() {
  [ "$#" -eq 2 ] || die "receipt: needs <run|check> <project-root>"
  local action="$1" root="$2" path sha digest
  [ -d "$root" ] || die "receipt: not a directory: $root"
  path="$(_ar_receipt_path "$root")"

  case "$action" in
    run)
      sha="$(_ar_head_sha "$root")"    || die "receipt: cannot resolve HEAD in $root"
      digest="$(_ar_gate_digest "$root")" || die "receipt: cannot digest the gate configuration"
      mkdir -p "$(dirname "$path")" || die "receipt: cannot create $(dirname "$path")"
      local outcome=pass rc=0
      # The gate runner's own output goes to the caller's stderr untouched — this is the one
      # place an operator finds out WHY a gate failed, and swallowing it to keep the receipt
      # tidy would be trading the diagnosis for the verdict.
      bash "$(dirname "${BASH_SOURCE[0]:-$0}")/project-gates.sh" run "$root" || { outcome=fail; rc=1; }
      # Staged then renamed: a half-written receipt read by a concurrent verdict would either
      # parse as a different commit (harmless) or as a TRUNCATED digest that happens to prefix
      # the real one (not harmless). A rename is atomic; a redirect is not.
      printf '%s\t%s\t%s\t%s\n' "$root" "$sha" "$digest" "$outcome" > "$path.tmp" \
        && mv "$path.tmp" "$path" \
        || die "receipt: could not write $path"
      printf 'recorded %s at %s\n' "$outcome" "${sha:0:12}"
      return "$rc" ;;
    check) ;;
    *) die "receipt: unknown action '$action' (want run|check)" ;;
  esac

  [ -f "$path" ] || { printf 'none\n'; return 11; }
  local r_root r_sha r_digest r_outcome
  IFS="$TAB" read -r r_root r_sha r_digest r_outcome < "$path" || { printf 'none\n'; return 11; }
  # A receipt missing its outcome column is a receipt this version cannot interpret — an older
  # format, or a truncated file. Unreadable is `none`, never `ok`.
  case "$r_outcome" in pass|fail) ;; *) printf 'none (unreadable receipt)\n'; return 11 ;; esac
  sha="$(_ar_head_sha "$root")"       || { printf 'none\n'; return 11; }
  digest="$(_ar_gate_digest "$root")" || { printf 'none\n'; return 11; }
  # Every field must match. Listing them separately rather than comparing a joined string keeps
  # the reason readable, and the reasons are genuinely different remedies.
  if [ "$r_root" != "$root" ];     then printf 'stale (recorded for a different checkout)\n'; return 10; fi
  if [ "$r_sha" != "$sha" ];       then printf 'stale (recorded at %s, HEAD is now %s)\n' "${r_sha:0:12}" "${sha:0:12}"; return 10; fi
  if [ "$r_digest" != "$digest" ]; then printf 'stale (the gate configuration changed since it was recorded)\n'; return 10; fi
  if [ "$r_outcome" = fail ];      then printf 'failed (the gates ran at this commit and went RED)\n'; return 12; fi
  printf 'ok\n'
  return 0
}

# --- probe: the OFFLINE half ----------------------------------------------------------------------
# Every rung here is decidable from the filesystem alone, so this subcommand is hermetic: no gh,
# no network, no authentication. That is what lets it be regression-tested against `mktemp -d`
# fixtures rather than against somebody's live repository.
#
# The tracker rungs are NOT here. They need live reads, and re-deriving milestone tabulation or
# release readiness in this file would be a second copy of what roadmap-lib.sh and
# release-convention.sh already own. `tracker` (below) takes those readers' output as JSON and
# turns it into rung records, which keeps the derivation testable while the gh call stays in the
# workflow — the same split `release-counts` / `release-ready` already uses.
cmd_probe() {
  local root="" agents="claude"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agents) [ "$#" -ge 2 ] && [ -n "$2" ] || die "probe: --agents needs a non-empty value"
                agents="$2"; shift 2 ;;
      -*) die "probe: unknown option $1" ;;
      *)  [ -z "$root" ] || die "probe: takes one project root"; root="$1"; shift ;;
    esac
  done
  [ -n "$root" ] || die "probe: needs <project-root>"
  [ -d "$root" ] || die "probe: not a directory: $root"

  # --- harness ---------------------------------------------------------------------------
  # `adb_install_source` is the ONE home for "where is the baseline installed" (adopt-lib.sh
  # `shipped` uses the same reader). An absent install is not an unknown: it is a definite,
  # actionable no — run install.sh.
  local src a missing=""
  if src="$(adb_install_source)"; then
    for a in ${agents//,/ }; do
      case "$a" in
        ''|*[!a-z0-9-]*|-*) die "probe: invalid agent token '$a'" ;;
      esac
      # The skills directory is what a workflow invocation actually resolves through, so its
      # absence is what an operator would experience as "the skill is not there".
      [ -d "$HOME/.$a" ] || missing="$missing $a"
    done
    if [ -n "$missing" ]; then
      _ar_emit harness todo "installed from $src, but no home directory for:${missing} — re-run install.sh for those agents"
    else
      _ar_emit harness ok "installed from $src"
    fi
  else
    _ar_emit harness todo "no baseline install found for any agent — run install.sh before adopting"
  fi

  # --- manifest --------------------------------------------------------------------------
  # `[roles]` specifically, not merely a file: an agents.toml with no roles leaves every
  # delegated step resolving to a built-in default the project never chose, which is the
  # silent-default shape this contract exists to surface.
  if [ ! -f "$root/agents.toml" ]; then
    _ar_emit manifest todo "no agents.toml — run bin/agent-init, or apply /adopt's proposal"
  elif adb_toml_get "$root/agents.toml" roles primary >/dev/null 2>&1; then
    _ar_emit manifest ok "agents.toml declares [roles]"
  else
    _ar_emit manifest todo "agents.toml has no [roles] primary — every delegated step falls back to a default this project never chose"
  fi

  # --- shape -----------------------------------------------------------------------------
  # `adb_repo_shape` REFUSES a path it cannot represent (a tab or newline in a directory name,
  # #278) by emitting a `warning` and no facts. That is an UNKNOWN, not a failure: the shape was
  # not established, and reporting it as red would tell the operator to go fix something when
  # what they must actually do is look.
  local shape
  shape="$(adb_repo_shape "$root" 2>/dev/null)"
  if printf '%s\n' "$shape" | grep -q "^warning$TAB"; then
    _ar_emit shape unknown "the repo shape could not be represented: $(printf '%s\n' "$shape" | sed -n "s/^warning$TAB//p" | head -n1)"
  elif printf '%s\n' "$shape" | grep -q "^root$TAB"; then
    local extra=""
    printf '%s\n' "$shape" | grep -q "^nested_in$TAB"  && extra="$extra nested inside another repo;"
    printf '%s\n' "$shape" | grep -q "^foreign_doc$TAB" && extra="$extra a root doc lives OUTSIDE this repo;"
    _ar_emit shape ok "root $(printf '%s\n' "$shape" | sed -n "s/^root$TAB//p" | head -n1)${extra:+ —$extra confirm the boundary}"
  else
    _ar_emit shape unknown "adb_repo_shape returned no root for $root"
  fi

  # --- gates -----------------------------------------------------------------------------
  # THE LOUD ONE. `project-gates.sh` emits nothing for an ecosystem it does not recognize and
  # exits 0, which is right for a gate runner asked about an unknown repo and WRONG for an
  # adoption: a project that finishes adoption with no gates has shipped with no enforcement,
  # and the run that produced it looked identical to a clean one. #81 asks for exactly this
  # inversion — "when no gate can be detected, say so loudly and require an explicit
  # agents.toml [gates] decision (including a deliberate "" disable)".
  # NO DISPLAY STRING DECIDES ANYTHING HERE, and that rule cost two bugs to learn. This block
  # asks two questions, each of a surface with a real contract:
  #
  #   how many gates RUN?          -> `detect`, whose `<label>TAB<command>` two-column output is
  #                                   a documented contract listing RUN gates and nothing else.
  #   is there a RECORDED DECISION -> `agents.toml`'s [gates] / [gates.state] keys, read with the
  #   about gates?                    shared `adb_toml_keys` primitive.
  #
  # The first version counted `grep -c 'run:'` against `status`, which prints `run` WITHOUT a
  # colon, so a repo with a real gate counted zero and the axis reported N/A. The fix for that
  # left a second copy of the same mistake one line below — `[ "$gstatus" = "no gates configured
  # or detected" ]`, an equality against a sentence whose wording nothing pins. Re-word that
  # sentence and this test silently stops matching; the run then falls through to the `grun -eq 0`
  # arm and reports a project with NO gates as "explicitly disabled", which is the flattering
  # answer and the exact inversion this rung exists to prevent. Asking `agents.toml` directly is
  # also the more faithful question: "or explicitly disabled with a recorded reason" is a claim
  # about what the manifest RECORDS, not about what a status table happens to print.
  local grun gkeys
  grun="$(bash "$(dirname "${BASH_SOURCE[0]:-$0}")/project-gates.sh" detect "$root" 2>/dev/null | grep -c . || true)"
  gkeys="$( { adb_toml_keys "$root/agents.toml" gates; adb_toml_keys "$root/agents.toml" gates.state; } 2>/dev/null | grep -c . || true)"
  if [ "$grun" -eq 0 ] && [ "$gkeys" -eq 0 ]; then
    _ar_emit gates todo "NO GATE was detected, and agents.toml records no decision about gates — declare [gates] (a deliberate \"\" disables one, and [gates.state] declares an axis N/A). Adoption must not finish with enforcement silently off"
  elif [ "$grun" -eq 0 ]; then
    _ar_emit gates na "no gate runs, and agents.toml records that decision in $gkeys [gates]/[gates.state] key(s) — a recorded choice, not a detection miss"
  else
    local rc; local receipt
    receipt="$(cmd_receipt check "$root")"; rc=$?
    case "$rc" in
      0)  _ar_emit gates ok "$grun gate(s) detected, executed at this commit, and PASSED" ;;
      12) _ar_emit gates todo "$grun gate(s) detected, and they RAN AT THIS COMMIT AND WENT RED — fix them; a detected gate that errors is enforcement that never happens" ;;
      10) _ar_emit gates todo "$grun gate(s) detected but the execution receipt is $receipt — re-run them" ;;
      *)  _ar_emit gates todo "$grun gate(s) detected and NEVER EXECUTED — detection is not working; run them once ('adopt-readiness.sh receipt run')" ;;
    esac
  fi

  # --- decisions -------------------------------------------------------------------------
  if [ -f "$root/.ai-dev-baseline/decisions.md" ]; then
    _ar_emit decisions ok "decision log present"
  else
    _ar_emit decisions todo "no .ai-dev-baseline/decisions.md — handling-the-unknown.md requires every unmodeled thing adoption hit to be recorded there"
  fi
}

# --- tracker: the rungs that need live reads ------------------------------------------------------
# Stdin is ONE JSON object the caller assembled from the shipped readers. This subcommand turns
# those facts into rung records and does not read GitHub itself, which is what keeps it testable
# offline against fixtures — the same division `release-counts` uses.
#
# Recognized fields (every one of them optional; an ABSENT field yields `unknown` for its rung,
# never a pass — that is the fail-closed rule at its most load-bearing, because the natural bug
# in a caller is to forget a read, and forgetting must never read as success):
#
#   milestones          [ {"title":…, "open_issues":N}, … ]   pre-existing/open milestones
#   release_milestone   "Next release"      the active release milestone's title
#   backlog_milestone   "Backlog"
#   blocker_label       true|false          does the release-blocker label exist
#   armed               N                   issues in the release milestone (open + closed)
#   unmilestoned        N                   open issues in no milestone
#   roadmap_count       N                   open issues carrying the `roadmap` label
#   dispositions        ["milestone:Audit Results", …]   retired question ids from ## Decisions
#   settings            "ok"|"todo"|"unknown"|"na"  + settings_detail
#   release_command     "…"                 the resolved release-command marker
cmd_tracker() {
  [ "$#" -eq 0 ] || die "tracker: takes no arguments (facts JSON on stdin)"
  command -v jq >/dev/null 2>&1 || die "tracker: jq not found"
  local json
  json="$(cat)" || die "tracker: could not read stdin"
  [ -n "$json" ] || json='{}'
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || die "tracker: stdin is not valid JSON"

  # One reader for the facts object, so every field is read the same way and a missing field is
  # always the empty string rather than sometimes `null`.
  q() { printf '%s' "$json" | jq -r "$1" 2>/dev/null; }

  # --- milestones ---
  local rel bak blk
  rel="$(q '.release_milestone // ""')"; bak="$(q '.backlog_milestone // ""')"
  blk="$(q 'if has("blocker_label") then (.blocker_label|tostring) else "" end')"
  if [ -z "$rel" ] || [ -z "$bak" ] || [ -z "$blk" ]; then
    _ar_emit milestones unknown "the release-convention primitives were not read — run 'baseline release status'"
  elif [ "$blk" != "true" ]; then
    _ar_emit milestones todo "the release-blocker label is missing — run 'baseline release init'"
  else
    _ar_emit milestones ok "release '$rel' + backlog '$bak' + the blocker label all exist"
  fi

  # --- slate ---
  # ARMED IS ABOUT COUNT, NOT QUALITY. #81's failure case is a milestone holding zero issues:
  # readiness then reports "no requirements yet" and /roadmap emits nothing, so adoption
  # produced a flow that cannot move. Whether the RIGHT issues are in it is the owner's call —
  # which is exactly why this rung's owner is `owner` and its remedy is a proposal, not a fix.
  local armed
  armed="$(q 'if has("armed") then (.armed|tostring) else "" end')"
  if [ -z "$armed" ] || ! printf '%s' "$armed" | grep -Eq '^[0-9]+$'; then
    _ar_emit slate unknown "the release milestone's contents were not read"
  elif [ "$armed" -eq 0 ]; then
    _ar_emit slate todo "the release milestone holds ZERO issues, so /roadmap has nothing to emit — propose a first slate and let the owner approve it"
  else
    _ar_emit slate ok "$armed issue(s) in the release milestone"
  fi

  # --- unmilestoned ---
  local unm
  unm="$(q 'if has("unmilestoned") then (.unmilestoned|tostring) else "" end')"
  if [ -z "$unm" ] || ! printf '%s' "$unm" | grep -Eq '^[0-9]+$'; then
    _ar_emit unmilestoned unknown "the unmilestoned open issues were not counted"
  elif [ "$unm" -gt 0 ]; then
    _ar_emit unmilestoned todo "$unm open issue(s) are in no milestone — /roadmap's step 4b autofix sweeps them to the backlog"
  else
    _ar_emit unmilestoned ok "no open issue is in limbo"
  fi

  # --- dispositions ---
  # A PRE-EXISTING MILESTONE IS A QUESTION, AND THE ANSWER LIVES IN ONE PLACE. `Audit Results`
  # appeared in 3 of the 4 repos #81 surveyed; those are THEMATIC milestones, and GitHub gives
  # an issue exactly one milestone, so an issue parked in a theme is invisible to release
  # composition — neither slated nor backlogged. 80 issues were invisible that way in one repo.
  #
  # The disposition is recorded as a `## Decisions` row in the roadmap artifact whose Question
  # cell is `milestone:<title>`. That is the shipped home for retiring exactly this kind of
  # tracker question, it is owner-authoritative, and /roadmap never rewrites it.
  #
  # WHAT THIS CHECKS IS THAT AN ANSWER EXISTS, NOT WHICH ANSWER IT IS. Classifying the prose
  # into backlog/theme/merge/leave would add a grammar that can drift, and would buy nothing:
  # this library is read-only, so it cannot act on the difference. What must be mechanical is
  # "has the owner answered for this milestone" — the issue's requirement is that a pre-existing
  # milestone is "never silently ignored", and silence is precisely what this detects.
  local ms_n
  ms_n="$(q 'if has("milestones") then (.milestones|length|tostring) else "" end')"
  if [ -z "$ms_n" ]; then
    _ar_emit dispositions unknown "the project's milestones were not read"
  else
    # The two convention milestones are dispositioned BY the convention itself; requiring a
    # decision row for `Next release` would demand the owner justify the thing they just
    # created. Filtered here rather than by the caller so every caller filters identically.
    #
    # `. as $m` FIRST, and that is not style. Inside `$d | index(…)` the pipe rebinds `.` to
    # `$d`, so a `.title` written there reads the DISPOSITIONS ARRAY's title — which does not
    # exist, so jq aborts. Bound to `$m` up front, the title survives the rebinding.
    #
    # AND THE STATUS IS CHECKED, with no `2>/dev/null` to swallow it. That combination shipped
    # for one test run and produced a FALSE GREEN: jq errored, the redirect hid it, the empty
    # output read as "no undecided milestones", and a repo with 44 issues parked in an
    # undispositioned `Audit Results` was reported as fully dispositioned. An unreadable answer
    # is `unknown`; it is never `ok`.
    local undecided
    if ! undecided="$(printf '%s' "$json" | jq -r --arg rel "$rel" --arg bak "$bak" '
      (.dispositions // []) as $d
      | [ (.milestones // [])[]
          | . as $m
          | select($m.title != $rel and $m.title != $bak)
          | select( ($d | index("milestone:" + $m.title)) == null )
          | "\($m.title) (\($m.open_issues // 0) open)" ]
      | join(", ")')"; then
      _ar_emit dispositions unknown "the milestone list could not be read — do NOT take this as 'all dispositioned'"
      undecided="__unreadable__"
    fi
    if [ "$undecided" = "__unreadable__" ]; then
      : # already emitted
    elif [ -z "$undecided" ]; then
      _ar_emit dispositions ok "every pre-existing milestone has a recorded disposition"
    else
      _ar_emit dispositions todo "no recorded disposition for: $undecided — their open issues are invisible to release composition until the roadmap's ## Decisions carries a 'milestone:<title>' row for each"
    fi
  fi

  # --- roadmap ---
  # EXACTLY ONE. Zero means /roadmap has nothing to reconcile against; two or more is the split
  # brain /roadmap hard-stops on, and it is reachable by adoption in the obvious way — a repo
  # that already had a planning issue, plus a bootstrapped one.
  local rc_n
  rc_n="$(q 'if has("roadmap_count") then (.roadmap_count|tostring) else "" end')"
  if [ -z "$rc_n" ] || ! printf '%s' "$rc_n" | grep -Eq '^[0-9]+$'; then
    _ar_emit roadmap unknown "the roadmap artifact was not looked for"
  elif [ "$rc_n" -eq 0 ]; then
    _ar_emit roadmap todo "no roadmap artifact — /roadmap bootstraps one on its first run"
  elif [ "$rc_n" -gt 1 ]; then
    _ar_emit roadmap todo "$rc_n roadmap-labelled issues (split brain) — /roadmap hard-stops on this; retire all but one"
  else
    _ar_emit roadmap ok "exactly one roadmap artifact"
  fi

  # --- settings ---
  # PASSED THROUGH, not re-derived. `repo-settings.sh` owns what a correctly configured repo
  # looks like and in what ORDER it must be applied (required checks before auto-merge, else a
  # PR can merge with nothing gating it). Restating any of that here would be a second model.
  local st sd
  st="$(q '.settings // ""')"; sd="$(q '.settings_detail // ""')"
  case "$st" in
    ok|todo|na|unknown) _ar_emit settings "$st" "${sd:-reported by repo-settings.sh}" ;;
    "") _ar_emit settings unknown "repo settings were not read — run 'baseline repo status'" ;;
    *)  die "tracker: .settings must be ok|todo|na|unknown (got '$st')" ;;
  esac

  # --- release ---
  # ABSENT AND EMPTY ARE DIFFERENT, and collapsing them was a real defect in the first draft.
  # `.release_command // ""` reads a caller that could not reach the roadmap artifact exactly like
  # one that read it and found no marker — so a transient `gh` failure told the operator to add a
  # marker their artifact may already carry. That is the shape verify-before-asserting.md forbids:
  # say what could not be established, not what is true. `has()` separates them.
  local relcmd
  if [ "$(q 'has("release_command")|tostring')" != "true" ]; then
    _ar_emit release unknown "the roadmap artifact's release-command marker was not read"
  elif relcmd="$(q '.release_command')" && [ -n "$relcmd" ] && [ "$relcmd" != null ]; then
    _ar_emit release ok "release command resolves to '$relcmd'"
  else
    _ar_emit release todo "the roadmap declares no <!-- release-command: … --> marker, so a met release has nothing to emit (#3 makes release execution project-owned — every adopting repo owes itself one)"
  fi
}

# --- verdict: decide and report -------------------------------------------------------------------
cmd_verdict() {
  [ "$#" -eq 0 ] || die "verdict: takes no arguments (rung records on stdin)"

  local -A seen=() status=() detail=()
  local line rung st det
  # `|| [ -n "$line" ]` — READ THE FINAL UNTERMINATED LINE. `read` returns non-zero at EOF even
  # when it filled the variable, so a plain `while read` silently DROPS a last record that has
  # no trailing newline. Every `$(…)` in a caller strips the trailing newline, so
  # `printf '%s' "$records" | verdict` — the obvious way to pipe a captured record set — loses
  # its LAST rung. That direction is fail-closed (a dropped rung is unknown, never a pass), so
  # nothing unsafe shipped, but the verifier would have reported "11 of 12 evaluated" about a
  # complete set and blamed the caller. Caught by this file's own suite.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    rung="${line%%"$TAB"*}"; line="${line#*"$TAB"}"
    st="${line%%"$TAB"*}"
    if [ "$st" = "$line" ]; then det=""; else det="${line#*"$TAB"}"; fi
    _ar_is_rung "$rung" || die "verdict: '$rung' is not a contract rung (see 'contract')"
    case "$st" in
      ok|todo|unknown|na) : ;;
      # An unrecognized status is an ERROR, never a pass. A typo must not fall through to green
      # — the same rule roadmap-lib.sh's release-ready applies to its health argument.
      *) die "verdict: rung '$rung' has status '$st' (want ok|todo|unknown|na)" ;;
    esac
    # A DUPLICATE IS A CALLER BUG, and last-wins would resolve it silently — in whichever
    # direction the caller happened to emit last, which could be the flattering one.
    [ -n "${seen[$rung]:-}" ] && die "verdict: rung '$rung' was reported twice"
    seen[$rung]=1; status[$rung]="$st"; detail[$rung]="$det"
  done

  local total=0 evaluated=0 reds=() unknowns=() greens=0 nas=0 owner title
  while IFS="$TAB" read -r rung owner title; do
    total=$((total + 1))
    st="${status[$rung]:-}"
    # A RUNG NOBODY REPORTED IS UNKNOWN, NOT ABSENT. This is the whole reason `verdict` reads
    # the contract instead of only its stdin: a caller that forgets a fact would otherwise
    # shrink the contract to whatever it remembered, and a shrunken contract is trivially green.
    if [ -z "$st" ]; then
      unknowns+=("$rung${TAB}$owner${TAB}$title${TAB}not reported — no producer supplied this fact")
      continue
    fi
    evaluated=$((evaluated + 1))
    case "$st" in
      ok)      greens=$((greens + 1)) ;;
      na)      nas=$((nas + 1)) ;;
      todo)    reds+=("$rung${TAB}$owner${TAB}$title${TAB}${detail[$rung]}") ;;
      unknown) unknowns+=("$rung${TAB}$owner${TAB}$title${TAB}${detail[$rung]}") ;;
    esac
  done < <(_ar_contract)

  printf 'Adoption completion contract — %d of %d rungs evaluated (%d met, %d N/A, %d outstanding, %d undetermined)\n' \
    "$evaluated" "$total" "$greens" "$nas" "${#reds[@]}" "${#unknowns[@]}"
  printf '\n'

  if [ "${#reds[@]}" -gt 0 ]; then
    printf 'OUTSTANDING — this is what remains, and who decides it:\n'
    for line in "${reds[@]}"; do
      IFS="$TAB" read -r rung owner title det <<<"$line"
      printf '  [%s] %-13s %s\n' "$owner" "$rung" "$title"
      [ -n "$det" ] && printf '                        %s\n' "$det"
    done
    printf '\n'
  fi

  if [ "${#unknowns[@]}" -gt 0 ]; then
    printf 'UNDETERMINED — a fact could not be established. These are NOT passes:\n'
    for line in "${unknowns[@]}"; do
      IFS="$TAB" read -r rung owner title det <<<"$line"
      printf '  [%s] %-13s %s\n' "$owner" "$rung" "$title"
      [ -n "$det" ] && printf '                        %s\n' "$det"
    done
    printf '\n'
  fi

  # PRECEDENCE. Red outranks indeterminate because both withhold "ready" and only red has a
  # deterministic next move — the report above already lists every undetermined rung, so
  # nothing is hidden by the choice of headline word.
  if [ "${#reds[@]}" -gt 0 ]; then
    printf 'VERDICT: red — adoption is NOT complete.\n'
    return 10
  fi
  if [ "${#unknowns[@]}" -gt 0 ]; then
    printf 'VERDICT: indeterminate — nothing is known to be wrong, and that is not the same as ready.\n'
    return 11
  fi
  printf 'VERDICT: green — every rung of the completion contract is met.\n'
  return 0
}

# --- facts: the LIVE gatherer -----------------------------------------------------------------
# The only part of this file that touches the network. It is deliberately thin — it reads and
# assembles, it decides nothing — so that everything with a rule in it stays hermetic and
# testable. `tracker` turns what this prints into rung records; `facts` never classifies.
#
# IT LIVES HERE RATHER THAN IN THE WORKFLOW'S PROSE. The first draft of #81 spelled these reads
# out in `adopt.md` as a fenced block, and this repo has a standing rule against that: a decision
# written as prose is a decision nothing can regression-test, and an agent re-derives it every
# run. The reads themselves are still not unit-tested (they need a live tracker), but having ONE
# spelling of them means `/adopt` and `baseline adopt status` cannot drift apart, which is the
# failure that actually costs something.
#
# READ, THEN PARSE — never one pipeline. A pipeline reports only its LAST command's status, so a
# failed `gh` would arrive as empty input and parse into a plausible ZERO: a repo whose tracker
# could not be read would be reported as a repo with nothing in it. Every field is OMITTED rather
# than defaulted when its read fails, because an omitted field is `unknown` downstream and a
# defaulted one is a lie.
cmd_facts() {
  local rel="Next release" bak="Backlog" blk="release-blocker"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release-milestone) [ "$#" -ge 2 ] || die "facts: --release-milestone needs a value"; rel="$2"; shift 2 ;;
      --backlog-milestone) [ "$#" -ge 2 ] || die "facts: --backlog-milestone needs a value"; bak="$2"; shift 2 ;;
      --blocker-label)     [ "$#" -ge 2 ] || die "facts: --blocker-label needs a value";     blk="$2"; shift 2 ;;
      *) die "facts: unknown argument $1" ;;
    esac
  done
  command -v gh >/dev/null 2>&1 || die "facts: gh not found"
  command -v jq >/dev/null 2>&1 || die "facts: jq not found"

  local repo ms_json ms unm rc_n armed relcmd labels dispo body roadmap_num
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
    || die "facts: cannot resolve the repository from $PWD"

  # Milestones — OPEN ones, PAGINATED (#79). An unpaginated read silently drops the tail, and a
  # dropped milestone is one this contract then never asks the owner about.
  local out="{}"
  if ms_json="$(gh api --paginate "repos/$repo/milestones?state=open&per_page=100" 2>/dev/null)"; then
    if ms="$(printf '%s' "$ms_json" | jq -s '[ (add // [])[] | {title, open_issues} ]' 2>/dev/null)"; then
      out="$(printf '%s' "$out" | jq --argjson ms "$ms" '. + {milestones: $ms}')"
    fi
  fi

  # `is:issue`, because repos/…/issues returns pull requests too and would count them as work.
  if unm="$(gh api -X GET search/issues -f q="repo:$repo is:issue is:open no:milestone" --jq '.total_count' 2>/dev/null)"; then
    out="$(printf '%s' "$out" | jq --argjson n "${unm:-0}" '. + {unmilestoned: $n}')"
  fi
  if rc_n="$(gh api -X GET search/issues -f q="repo:$repo is:issue is:open label:roadmap" --jq '.total_count' 2>/dev/null)"; then
    out="$(printf '%s' "$out" | jq --argjson n "${rc_n:-0}" '. + {roadmap_count: $n}')"
  fi
  # ARMED COUNTS CLOSED ISSUES TOO. A milestone whose work is finished is still armed — it had
  # requirements — and counting only open ones would report a nearly-done release as an empty
  # one and send the owner to re-slate it.
  if armed="$(gh api -X GET search/issues -f q="repo:$repo is:issue milestone:\"$rel\"" --jq '.total_count' 2>/dev/null)"; then
    out="$(printf '%s' "$out" | jq --argjson n "${armed:-0}" '. + {armed: $n}')"
  fi
  if labels="$(gh api --paginate "repos/$repo/labels?per_page=100" --jq '.[].name' 2>/dev/null)"; then
    local has=false
    printf '%s\n' "$labels" | grep -Fxq "$blk" && has=true
    out="$(printf '%s' "$out" | jq --argjson b "$has" --arg r "$rel" --arg k "$bak" \
             '. + {blocker_label: $b, release_milestone: $r, backlog_milestone: $k}')"
  fi

  # The roadmap artifact's ## Decisions rows — read through `roadmap-lib.sh decisions`, which is
  # the ONE home for that table's markdown filtering (fences, HTML comments and blockquotes are
  # stripped there, so a quoted example never retires a real question). A milestone disposition
  # is a row whose Question cell is `milestone:<title>`.
  roadmap_num="$(gh api -X GET search/issues -f q="repo:$repo is:issue is:open label:roadmap" \
                   --jq '.items[0].number // empty' 2>/dev/null || true)"
  if [ -n "${roadmap_num:-}" ] && body="$(gh issue view "$roadmap_num" --json body --jq .body 2>/dev/null)"; then
    if dispo="$(printf '%s' "$body" | bash "$(dirname "${BASH_SOURCE[0]:-$0}")/roadmap-lib.sh" decisions 2>/dev/null \
                  | jq -R -s 'split("\n") | map(select(length > 0))')"; then
      out="$(printf '%s' "$out" | jq --argjson d "$dispo" '. + {dispositions: $d}')"
    fi
    if relcmd="$(printf '%s' "$body" | bash "$(dirname "${BASH_SOURCE[0]:-$0}")/roadmap-lib.sh" release-command 2>/dev/null | head -n1)"; then
      [ -n "$relcmd" ] && out="$(printf '%s' "$out" | jq --arg c "$relcmd" '. + {release_command: $c}')"
    fi
  fi

  # Repo settings — CLASSIFIED BY repo-settings.sh, never re-derived here. Its `automerge-ok`
  # exit code already encodes what a correctly configured repo looks like, including the
  # required-checks-before-auto-merge ordering; restating any of it would be a second model.
  local am
  bash "$(dirname "${BASH_SOURCE[0]:-$0}")/repo-settings.sh" automerge-ok >/dev/null 2>&1; am=$?
  case "$am" in
    0)  out="$(printf '%s' "$out" | jq '. + {settings:"ok",   settings_detail:"auto-merge is enabled and required checks gate it"}')" ;;
    12) out="$(printf '%s' "$out" | jq '. + {settings:"na",   settings_detail:"this repo has no CI, so required checks do not apply (#24)"}')" ;;
    10|11|13|14) out="$(printf '%s' "$out" | jq --arg c "$am" '. + {settings:"todo", settings_detail:("repo-settings.sh automerge-ok returned " + $c + " — run: baseline repo apply")}')" ;;
    *)  out="$(printf '%s' "$out" | jq --arg c "$am" '. + {settings:"unknown", settings_detail:("repo settings could not be read (rc " + $c + ")")}')" ;;
  esac

  printf '%s\n' "$out"
}

# --- status: the whole contract, end to end -------------------------------------------------------
# The re-runnable entry point #81 asks for. It composes the three subcommands above and returns
# `verdict`'s exit code unchanged, so a caller can gate on it.
cmd_status() {
  local root="${1:-$PWD}"
  shift 2>/dev/null || true
  [ -d "$root" ] || die "status: not a directory: $root"
  local probe facts
  probe="$(cmd_probe "$root" "$@")" || die "status: the offline probe failed"
  # A FAILED LIVE READ IS NOT FATAL, and that is deliberate: the offline half is still worth
  # reporting, and every tracker rung it could not establish comes out `unknown` — which is
  # non-green, so nothing is glossed over by continuing.
  facts="$( cd "$root" && cmd_facts 2>/dev/null )" || facts='{}'
  { printf '%s\n' "$probe"; printf '%s' "$facts" | cmd_tracker; } | cmd_verdict
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    contract) cmd_contract "$@" ;;
    probe)    cmd_probe "$@" ;;
    facts)    cmd_facts "$@" ;;
    tracker)  cmd_tracker "$@" ;;
    receipt)  cmd_receipt "$@" ;;
    verdict)  cmd_verdict "$@" ;;
    status)   cmd_status "$@" ;;
    *) printf 'adopt-readiness: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
