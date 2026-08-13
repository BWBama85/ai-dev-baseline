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
# INLINE `dirname` HERE, deliberately — `_AR_LIB_DIR` is defined further down and cannot be used
# before this source completes. Safe relatively: nothing has changed directory yet at line 1.
# shellcheck disable=SC2155
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

# THE LIBRARY DIRECTORY, RESOLVED ONCE AND ABSOLUTELY. Every sibling invocation below used
# `$(dirname "${BASH_SOURCE[0]:-$0}")` inline, which is whatever path the CALLER typed — and this
# file is routinely invoked as `bash scripts/lib/adopt-readiness.sh …`, i.e. relatively. Two
# functions then run that relative path from INSIDE a `cd "$root"` subshell (`_ar_primary_ok`,
# and `cmd_status`'s call to `cmd_facts`), where it no longer resolves: the sibling silently
# fails, and its failure reads as "the fact could not be established" about a project that is
# perfectly fine. Caught when a valid `primary = "claude"` reported `todo`.
_AR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || _AR_LIB_DIR="."

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

# Is `[roles] primary` a token role-dispatch will actually accept? MERE PRESENCE IS NOT ENOUGH:
# `adb_toml_get` succeeds for `primary = ""`, for an array, and for an unknown agent name, while
# `role-dispatch.sh` rejects all three — so the rung certified a manifest under which every
# delegated step fails at dispatch. The known-token set is role-dispatch's, read from its own
# resolver rather than re-listed here: `resolve primary` prints the token on success and fails on
# anything it would reject, which is exactly the question being asked.
#
# It runs INSIDE the project, because role-dispatch resolves the manifest from the repository it
# is standing in — asked from anywhere else it would validate THIS repo's manifest and report on
# somebody else's.
_ar_primary_ok() {
  local root="$1" tok
  # THE REPO'S OWN MANIFEST MUST DECLARE IT. `resolve` deliberately falls back to the global
  # manifest and then to a built-in default, so on its own it answers "claude" for a project that
  # declares nothing — and this rung's question is whether THIS project chose. Require the local
  # key first; `resolve` then validates the value (an invalid repo value makes it fail rather than
  # fall through, which is the property being borrowed).
  adb_toml_get "$root/agents.toml" roles primary >/dev/null 2>&1 || return 1
  tok="$( cd "$root" 2>/dev/null && bash "$_AR_LIB_DIR/role-dispatch.sh" resolve primary 2>/dev/null )" || return 1
  [ -n "$tok" ] || return 1
  # Exactly one token. `primary` is single-valued by contract; an array would resolve to several
  # and is precisely one of the malformed shapes this exists to reject.
  [ "$(printf '%s\n' "$tok" | grep -c .)" -eq 1 ]
}

# Does <dir> contain at least one installed skill (a `*/SKILL.md`)? A directory that merely
# EXISTS proves nothing — an interrupted or partly-removed install leaves it empty.
_ar_any_skill() {
  [ -d "$1" ] || return 1
  [ -n "$(find "$1" -mindepth 2 -maxdepth 2 -name SKILL.md -print -quit 2>/dev/null)" ]
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
  # And the carriage return, which forges no record but DOES overwrite the line already printed —
  # a milestone title ending in \r plus padding can blank the rung name it was reported under.
  detail="${detail//$'\r'/ }"
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
  recs="$(bash "$_AR_LIB_DIR/project-gates.sh" status "$root" 2>/dev/null)" || return 1
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

# THE COMMIT IS NOT THE TREE, and keying on HEAD alone let a receipt outlive the bytes it was a
# receipt for. Edit a tracked source file without committing and the root, the HEAD and the gate
# configuration are all unchanged — so yesterday's passing run still validated against a tree the
# gates have never seen. That is the single most valuable thing this receipt asserts, quietly
# false.
#
# IT HASHES CONTENT, NOT `--porcelain`. The first fix hashed the status output, and review caught
# that it only moves the digest when the FILE LIST or a status code changes. Record a receipt
# while the tree is already dirty, then keep editing those same already-modified paths, and
# `--porcelain` prints the identical ` M src/foo` lines forever — so the digest matches and the
# receipt returns `ok` for bytes the gates never saw. That is the exact defect one level in, and
# it is the likelier one in practice: a dirty tree is the normal state during development.
#
# So three things are hashed together, and each covers what the others cannot:
#   * `git diff HEAD` — the CONTENT of every tracked change, staged and unstaged alike;
#   * `--porcelain` — the file LIST, which is what notices an untracked file appearing or a
#     rename, neither of which `diff HEAD` shows;
#   * every untracked file's CONTENT — because a gate that globs the tree reads those too, and
#     `diff HEAD` is blind to them by construction.
#
# A repo whose status cannot be read yields nothing, and the caller treats that as unanswerable
# rather than as "clean" — the fail-closed direction, since "clean" is the flattering answer.
_ar_worktree_digest() {
  local root="$1" st
  st="$(git -C "$root" status --porcelain 2>/dev/null)" || return 1
  {
    printf '%s\n--\n' "$st"
    git -C "$root" diff HEAD 2>/dev/null || return 1
    printf -- '--\n'
    # `-z` + NUL-delimited read, because a filename may contain anything but NUL. `cat` on each
    # so the CONTENT is in the digest, not merely the name.
    git -C "$root" ls-files --others --exclude-standard -z 2>/dev/null \
      | while IFS= read -r -d '' f; do
          printf '%s\n' "$f"
          cat -- "$root/$f" 2>/dev/null || printf '<unreadable>'
          printf '\n'
        done
  } | { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
        elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
        else return 1
        fi; }
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
  local action="$1" root="$2" path sha digest tree
  [ -d "$root" ] || die "receipt: not a directory: $root"
  # CANONICALISE THE ROOT. The key compares this textually, so `.` and `/abs/path` name the same
  # checkout and would not share a receipt — a pointless `stale` on every invocation that spelled
  # the path differently. And a path this record format cannot represent is REFUSED rather than
  # written: a tab or newline in the root would forge a field boundary and corrupt the receipt on
  # read-back. `/adopt` never produces such a path (adb_repo_shape refuses it first, #278), but
  # `receipt` is a public subcommand and takes whatever it is handed.
  root="$(cd "$root" 2>/dev/null && pwd -P)" || die "receipt: cannot resolve $2"
  case "$root" in *"$TAB"*|*"
"*) die "receipt: the project root contains a tab or newline, which this record cannot represent" ;; esac
  path="$(_ar_receipt_path "$root")"

  case "$action" in
    run)
      sha="$(_ar_head_sha "$root")"    || die "receipt: cannot resolve HEAD in $root"
      digest="$(_ar_gate_digest "$root")" || die "receipt: cannot digest the gate configuration"
      tree="$(_ar_worktree_digest "$root")" || die "receipt: cannot read the worktree status"
      mkdir -p "$(dirname "$path")" || die "receipt: cannot create $(dirname "$path")"
      local outcome=pass rc=0
      # BOTH CADENCE CONTEXTS, and that is what makes "every detected gate was executed" true.
      # `run` defaults to the `full` context, which SKIPS every gate declared `turn-end` (#240) —
      # while `detect` lists those gates, so the probe counted them and the receipt claimed they
      # had run. A repo with a `turn-end` gate got a green rung for a gate nothing executed.
      # Running both contexts is the honest reading of the contract; a gate declared `always`
      # runs in both, which costs a second execution and is the price of the claim being true.
      bash "$_AR_LIB_DIR/project-gates.sh" run "$root" "" full     || { outcome=fail; rc=1; }
      bash "$_AR_LIB_DIR/project-gates.sh" run "$root" "" turn-end || { outcome=fail; rc=1; }
      # Staged then renamed, and the stage has a UNIQUE name. A fixed `$path.tmp` is shared by
      # every concurrent writer — two runs can rename each other's file, so a caller publishes a
      # result it never produced — and the redirect follows a pre-planted `$path.tmp` SYMLINK out
      # of the state dir. `mktemp` in the destination directory removes both, and keeps the
      # rename atomic by keeping it on one filesystem.
      local tmp
      tmp="$(mktemp "$(dirname "$path")/.adopt-receipt.XXXXXX")" || die "receipt: cannot stage a receipt"
      printf '%s\t%s\t%s\t%s\t%s\n' "$root" "$sha" "$digest" "$tree" "$outcome" > "$tmp" \
        && mv "$tmp" "$path" \
        || { rm -f "$tmp"; die "receipt: could not write $path"; }
      printf 'recorded %s at %s\n' "$outcome" "${sha:0:12}"
      return "$rc" ;;
    check) ;;
    *) die "receipt: unknown action '$action' (want run|check)" ;;
  esac

  [ -f "$path" ] || { printf 'none\n'; return 11; }
  local r_root r_sha r_digest r_tree r_outcome
  IFS="$TAB" read -r r_root r_sha r_digest r_tree r_outcome < "$path" || { printf 'none\n'; return 11; }
  # A receipt missing its outcome column is a receipt this version cannot interpret — an older
  # format, or a truncated file. Unreadable is `none`, never `ok`.
  case "$r_outcome" in pass|fail) ;; *) printf 'none (unreadable receipt)\n'; return 11 ;; esac
  sha="$(_ar_head_sha "$root")"       || { printf 'none\n'; return 11; }
  digest="$(_ar_gate_digest "$root")" || { printf 'none\n'; return 11; }
  tree="$(_ar_worktree_digest "$root")" || { printf 'none\n'; return 11; }
  # Every field must match. Listing them separately rather than comparing a joined string keeps
  # the reason readable, and the reasons are genuinely different remedies.
  if [ "$r_root" != "$root" ];     then printf 'stale (recorded for a different checkout)\n'; return 10; fi
  if [ "$r_sha" != "$sha" ];       then printf 'stale (recorded at %s, HEAD is now %s)\n' "${r_sha:0:12}" "${sha:0:12}"; return 10; fi
  if [ "$r_digest" != "$digest" ]; then printf 'stale (the gate configuration changed since it was recorded)\n'; return 10; fi
  if [ "$r_tree" != "$tree" ];     then printf 'stale (the working tree changed since it was recorded — the gates have not seen these bytes)\n'; return 10; fi
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

  # RESOLVE THE REPOSITORY ROOT FIRST. `status`' documented no-argument form defaults to `$PWD`,
  # and from a SUBDIRECTORY every filesystem rung below then reads that subdirectory — reporting
  # `agents.toml`, the gate config and the decision log as missing when they sit perfectly well at
  # the root. The `shape` rung would have found the real root moments later, which makes the
  # disagreement worse rather than better: one rung answers about the project and four answer
  # about wherever the operator happened to be standing.
  local _rr
  if _rr="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_rr" ]; then root="$_rr"; fi

  # --- harness ---------------------------------------------------------------------------
  # `adb_install_source` is the ONE home for "where is the baseline installed" (adopt-lib.sh
  # `shipped` uses the same reader). An absent install is not an unknown: it is a definite,
  # actionable no — run install.sh.
  #
  # IT CHECKS THE THREE THINGS A RUN ACTUALLY NEEDS, not just that a directory exists. The first
  # version tested `[ -d "$HOME/.<agent>" ]` under a comment claiming it checked "the skills
  # directory" — a directory that exists the moment anything writes state into it, so an agent
  # with no install at all passed. The contract's words are "skills resolve, root doc present":
  #
  #   * the ROOT DOC, which is what carries the practices into the agent's context;
  #   * the SKILLS TREE, which is what a `/adopt` or `/implement-issue` invocation resolves through;
  #   * `scripts/lib`, because every workflow step shells into it and a partial install that
  #     linked the docs but not the libraries fails at the first fenced block rather than at setup.
  # ARGUMENT VALIDATION IS UNCONDITIONAL, and it was not. This loop used to live INSIDE the
  # `if adb_install_source` branch below, so on any machine with no baseline install — which is
  # every CI runner, and every first run on a new workstation — an invalid or traversal `--agents`
  # token was never rejected at all. Input validation that only runs when an unrelated lookup
  # succeeds is validation that is off exactly where the input is least trusted. CI caught it;
  # the local suite could not, because the developer's machine always has an install.
  local src a missing="" doc
  for a in ${agents//,/ }; do
    case "$a" in
      ''|*[!a-z0-9-]*|-*) die "probe: invalid agent token '$a'" ;;
    esac
  done

  if src="$(adb_install_source)"; then
    for a in ${agents//,/ }; do
      case "$a" in
        claude) doc=CLAUDE.md ;; codex) doc=AGENTS.md ;; gemini) doc=GEMINI.md ;;
        # An agent this library does not model is not a failure — it is a fact it cannot check.
        # Saying so beats inventing a filename and reporting its absence as the agent's problem.
        *) missing="$missing $a(unknown-agent)"; continue ;;
      esac
      # FILES, NOT DIRECTORIES. A partial or half-removed install leaves `skills/` and
      # `scripts/lib/` present and EMPTY, and a directory test then certifies a harness that
      # cannot resolve a single skill or source a single library. Probe for an artifact that must
      # exist inside each: any `*/SKILL.md`, and `common.sh` — the library every workflow's first
      # fenced block sources.
      [ -e "$HOME/.$a/$doc" ] || missing="$missing $a(root-doc)"
      _ar_any_skill "$HOME/.$a/skills" || _ar_any_skill "$HOME/.$a/config/skills" \
        || missing="$missing $a(skills)"
      [ -e "$HOME/.$a/scripts/lib/common.sh" ] || missing="$missing $a(scripts/lib/common.sh)"
    done
    if [ -n "$missing" ]; then
      _ar_emit harness todo "installed from $src, but these are absent:${missing} — re-run install.sh"
    else
      _ar_emit harness ok "installed from $src; root doc, skills and scripts/lib resolve for: ${agents}"
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
  elif _ar_primary_ok "$root"; then
    _ar_emit manifest ok "agents.toml declares [roles] primary = $(adb_toml_unquote "$(adb_toml_get "$root/agents.toml" roles primary)")"
  elif adb_toml_get "$root/agents.toml" roles primary >/dev/null 2>&1; then
    _ar_emit manifest todo "agents.toml's [roles] primary is not a usable agent token ($(adb_toml_unquote "$(adb_toml_get "$root/agents.toml" roles primary)")) — role-dispatch rejects it, so every delegated step fails at dispatch rather than falling back"
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
  # AND THE DETECTOR'S EXIT STATUS IS KEPT. Piping straight into `grep -c` discards it, so a
  # detector that FAILED (a corrupt common.sh, an unreadable agents.toml — the fail-loud cases
  # project-gates.sh added on purpose) counted zero and, if the manifest happened to carry any
  # gate key, was reported as a deliberate N/A. A broken detector must never resolve to "the
  # owner meant it".
  local gdetect grun gkeys gstat
  gdetect="$(bash "$_AR_LIB_DIR/project-gates.sh" detect "$root" 2>/dev/null)"; gstat=$?
  grun="$(printf '%s' "$gdetect" | grep -c . || true)"
  # A KEY IS NOT A DECISION. Counting bare `[gates]`/`[gates.state]` keys treated ANY entry as a
  # recorded choice — so `[gates.state] test = "todo"`, an unsupported value `project-gates.sh`
  # ignores, made this rung report the whole gate system as a deliberate N/A while enforcement was
  # simply off. A typo must never read as intent. Only two spellings are decisions:
  #   [gates] <label> = ""        -> deliberately disabled
  #   [gates.state] <label> = na  -> declared not-applicable
  # Anything else is counted as NOTHING, so the rung falls through to the loud `todo`.
  gkeys=0
  local _k _v
  while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    _v="$(adb_toml_unquote "$(adb_toml_get "$root/agents.toml" gates "$_k" 2>/dev/null)" 2>/dev/null)"
    [ -z "$_v" ] && gkeys=$((gkeys + 1))
  done < <(adb_toml_keys "$root/agents.toml" gates 2>/dev/null)
  while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    _v="$(adb_toml_unquote "$(adb_toml_get "$root/agents.toml" gates.state "$_k" 2>/dev/null)" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [ "$_v" = na ] && gkeys=$((gkeys + 1))
  done < <(adb_toml_keys "$root/agents.toml" gates.state 2>/dev/null)
  if [ "$gstat" -ne 0 ]; then
    _ar_emit gates unknown "the gate detector FAILED (exit $gstat) — this is not 'no gates', and it is not a recorded N/A; fix the detector or the manifest it reads"
  elif [ "$grun" -eq 0 ] && [ "$gkeys" -eq 0 ]; then
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

  # A SECOND ECOSYSTEM THE PRIMARY ONE HID. Gate detection is single-primary first-wins, so a
  # WordPress-shaped repo carrying both a package.json and a composer.json gets its Node gates
  # and NO PHP ones. That is the right default (those Node commands are what the project itself
  # declared) but it is invisible, and invisible is the thing this whole file exists to fix — the
  # operator cannot layer the PHP gates through `[gates]` if nobody tells them the PHP is there.
  # A NOTE, not a rung: it is information, not an unmet requirement.
  #
  # ON STDERR, and that is load-bearing rather than tidy. Stdout is the RECORD STREAM, and every
  # line of it is parsed as `<rung>TAB<status>TAB<detail>` — so a `note` line here would reach
  # `verdict`, fail `_ar_is_rung`, and kill the whole run with a usage error about a rung nobody
  # wrote. Caught in review of this very block, which is the same lesson the newline fix taught
  # one field lower down: anything that shares a channel with the records must be a record.
  if [ -f "$root/composer.json" ] && [ "$grun" -gt 0 ] \
     && ! printf '%s' "$gdetect" | grep -qE 'composer|php'; then
    printf 'adopt-readiness: NOTE: %s also has a composer.json, but another ecosystem won gate detection (single-primary, first-wins), so its PHP gates are NOT running. Layer them through agents.toml [gates] if you want them.\n' "$root" >&2
  fi

  # --- decisions -------------------------------------------------------------------------
  # WHAT THIS CAN AND CANNOT ESTABLISH, said plainly rather than overclaimed. The contract item is
  # "every unmodeled thing adoption hit is recorded here", and nothing offline can know what a
  # given adoption run hit — that knowledge lives in the scan's `escalate` verdicts, which this
  # library never sees. So the rung asserts the weaker, checkable thing: a decision log EXISTS,
  # i.e. there is a home for those records in its one prescribed place. An empty one is reported
  # `ok` WITH the caveat attached, because an adoption that genuinely hit no unknowns has an empty
  # log legitimately, and failing it would be a rung no clean project could pass.
  if [ -f "$root/.ai-dev-baseline/decisions.md" ]; then
    if grep -q '^## ' "$root/.ai-dev-baseline/decisions.md" 2>/dev/null; then
      _ar_emit decisions ok "decision log present, with recorded entries"
    else
      _ar_emit decisions ok "decision log present but EMPTY — correct only if adoption hit no unknowns; cross-check the scan's 'escalate' findings yourself, which this rung cannot see"
    fi
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
#   slate_armed         true|false          release-counts' armed verdict for the release milestone
#   unmilestoned        N                   open issues in no milestone
#   roadmap_count       N                   open issues carrying the `roadmap` label
#   dispositions        ["milestone:Audit Results", …]   retired question ids from ## Decisions
#   settings            "ok"|"todo"|"unknown"|"na"  + settings_detail
#   release_command     "…"                 the first declared release-command marker
#   release_command_count N               how many were declared (>1 is AMBIGUOUS, and refused)
#   release_command_resolved true|false   does a skill by that name actually exist
cmd_tracker() {
  local rc _rc
  [ "$#" -eq 0 ] || die "tracker: takes no arguments (facts JSON on stdin)"
  command -v jq >/dev/null 2>&1 || die "tracker: jq not found"
  local json
  json="$(cat)" || die "tracker: could not read stdin"
  [ -n "$json" ] || json='{}'
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || die "tracker: stdin is not valid JSON"

  # TYPES ARE VALIDATED, NOT COERCED — and this replaces a `tostring` that produced THREE
  # confirmed false greens, every one of them found by the independent review:
  #
  #   "blocker_label":"true"   (the STRING) -> tostring gives "true" -> milestones = ok
  #   "milestones":null                     -> `// []` swallows it   -> dispositions = ok
  #   "release_command":false               -> non-empty scalar      -> release = ok
  #
  # Each is a malformed fact reading as a satisfied rung, which is the exact direction this
  # library exists to make impossible. `tostring` is the whole bug: it turns "is this fact what
  # it claims to be" into "can this be printed", and everything can be printed.
  #
  # So each reader asks jq for the TYPE and returns nothing unless it matches. Absent and
  # wrong-type both yield the empty string — both are `unknown` downstream, which is correct for
  # both: one fact was not gathered, the other cannot be trusted, and neither is a pass. A
  # wrong-type fact additionally sets `_bad`, so the report can say "malformed" rather than "not
  # read" and the operator looks at the right thing.
  # THE MISMATCH TRAVELS AS AN EXIT CODE, NOT A VARIABLE. The first version of this recorded
  # wrong-type keys by appending to a `_bad` string inside `_fact` — and every caller reads
  # `_fact` through `$( … )`, which is a SUBSHELL, so the assignment died with it and `_bad` was
  # permanently empty. The "malformed" branch could therefore never fire: a check that silently
  # never runs, which is the failure mode this whole file exists to reject, reintroduced in the
  # code meant to report it. An exit status is the one thing a command substitution DOES carry
  # back, so the distinction rides that instead.
  #
  #   0 = present and the right type   ·   1 = absent   ·   2 = present but WRONG type
  #
  # Absent and wrong-type are both `unknown` downstream — one fact was not gathered, the other
  # cannot be trusted, and neither is a pass — but they send the operator to different places, so
  # the report says which.
  _fact() {  # <key> <json-type> — print the value iff present AND of that type
    local k="$1" t="$2" present
    present="$(printf '%s' "$json" | jq -r --arg k "$k" 'has($k)|tostring' 2>/dev/null)"
    [ "$present" = true ] || return 1
    printf '%s' "$json" | jq -e --arg k "$k" --arg t "$t" '.[$k]|type == $t' >/dev/null 2>&1 || return 2
    printf '%s' "$json" | jq -r --arg k "$k" '.[$k] | if type=="string" then . else tostring end' 2>/dev/null
  }
  # A COUNT IS BOUNDED, because the shell's arithmetic is. An arbitrary digit string reaches
  # `[ "$n" -eq 0 ]`, and bash answers `integer expected` on stderr and returns NON-ZERO — which
  # falls through to the `else` arm and reports the rung SATISFIED. Reproduced by the review with
  # 18446744073709551616. A fractional count is rejected for the same reason; 15 digits is far
  # above any real tracker and safely inside a signed 64-bit shell integer.
  _count() {  # <key> — print a non-negative integer count; 1 absent, 2 malformed
    local v rc; v="$(_fact "$1" number)"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    case "$v" in ''|*[!0-9]*) return 2 ;; esac
    [ "${#v}" -le 15 ] || return 2
    printf '%s' "$v"
  }
  _why() {  # <rc> <key> <what-was-not-read> — "malformed" vs "not read", said precisely
    if [ "$1" -eq 2 ]; then
      printf 'the "%s" fact is MALFORMED (wrong JSON type or out of range) — do not read this as satisfied' "$2"
    else
      printf '%s' "$3"
    fi
  }

  # --- milestones ---
  # THE MILESTONES MUST BE OBSERVED, not merely named. `release_milestone` is the title the
  # caller ASKED about; on its own it proves nothing, and the first version treated those two
  # non-empty strings as proof that both milestones exist — so a repo carrying the label but
  # neither milestone reported `ok`. The observed list is what settles it.
  local rel bak blk rc_rel rc_bak rc_blk rc_ms worst
  rel="$(_fact release_milestone string)"; rc_rel=$?
  bak="$(_fact backlog_milestone string)"; rc_bak=$?
  blk="$(_fact blocker_label boolean)";    rc_blk=$?
  _fact milestones array >/dev/null;       rc_ms=$?
  # The WORST code wins the explanation: a malformed fact is more urgent than an absent one,
  # because it means a producer is lying rather than merely silent.
  worst=0
  for _rc in "$rc_rel" "$rc_bak" "$rc_blk" "$rc_ms"; do [ "$_rc" -gt "$worst" ] && worst="$_rc"; done
  if [ "$worst" -ne 0 ]; then
    _ar_emit milestones unknown "$(_why "$worst" "one of release_milestone/backlog_milestone/blocker_label/milestones" "the release-convention primitives were not read — run 'baseline release status'")"
  else
    local missing=""
    printf '%s' "$json" | jq -e --arg m "$rel" '[(.milestones//[])[].title] | index($m) != null' >/dev/null 2>&1 \
      || missing="$missing '$rel'"
    printf '%s' "$json" | jq -e --arg m "$bak" '[(.milestones//[])[].title] | index($m) != null' >/dev/null 2>&1 \
      || missing="$missing '$bak'"
    if [ "$blk" != "true" ]; then
      _ar_emit milestones todo "the release-blocker label is missing — run 'baseline release init'"
    elif [ -n "$missing" ]; then
      _ar_emit milestones todo "the label exists but these milestones do NOT:${missing} — run 'baseline release init'"
    else
      _ar_emit milestones ok "release '$rel' + backlog '$bak' + the blocker label were all observed"
    fi
  fi

  # --- slate ---
  # ARMED IS ABOUT COUNT, NOT QUALITY. #81's failure case is a milestone holding zero issues:
  # readiness then reports "no requirements yet" and /roadmap emits nothing, so adoption
  # produced a flow that cannot move. Whether the RIGHT issues are in it is the owner's call —
  # which is exactly why this rung's owner is `owner` and its remedy is a proposal, not a fix.
  #
  # THE COUNT MUST EXCLUDE THE ROADMAP ARTIFACT, because `roadmap-lib.sh release-counts` — the
  # one home for "is this milestone armed" — excludes it by number. A release milestone holding
  # ONLY the roadmap issue would otherwise read as armed here and unarmed there, and the two
  # disagreeing about the same milestone is worse than either answer alone. `cmd_facts` does the
  # excluding, because it is the half that knows the artifact's number.
  local armed
  armed="$(_fact slate_armed boolean)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _ar_emit slate unknown "$(_why "$rc" slate_armed "the release milestone's contents were not tabulated")"
  elif [ "$armed" != true ]; then
    _ar_emit slate todo "the release milestone holds NO requirements, so /roadmap has nothing to emit — propose a first slate and let the owner approve it"
  else
    _ar_emit slate ok "the release milestone is armed (tabulated by roadmap-lib.sh release-counts, which excludes PRs and the roadmap artifact)"
  fi

  # --- unmilestoned ---
  local unm
  unm="$(_count unmilestoned)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _ar_emit unmilestoned unknown "$(_why "$rc" unmilestoned "the unmilestoned open issues were not counted")"
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
  # `milestones` must be an ARRAY. `.milestones|length` accepted `null` (length 0) and a string
  # (its character count), so `"milestones":null` produced an empty undecided-set and reported
  # `ok` — a repo whose milestone read failed was told every milestone was dispositioned.
  # BOTH inputs are type-checked, and `dispositions` is the subtle one: jq's `index()` on a
  # STRING does SUBSTRING matching, so `"dispositions":"milestone:Audit Results"` — a malformed
  # scalar where an array belongs — still "finds" the milestone, drops it from `undecided`, and
  # reports the rung `ok`. A false green produced by a type nobody checked.
  local rc_ms rc_dp
  _fact milestones array >/dev/null; rc_ms=$?
  rc_dp=0
  if printf '%s' "$json" | jq -e 'has("dispositions")' >/dev/null 2>&1; then
    _fact dispositions array >/dev/null; rc_dp=$?
  fi
  if [ "$rc_ms" -ne 0 ] || [ "$rc_dp" -ne 0 ]; then
    rc=$(( rc_ms > rc_dp ? rc_ms : rc_dp ))
    _ar_emit dispositions unknown "$(_why "$rc" "milestones/dispositions" "the project's milestones were not read")"
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
  rc_n="$(_count roadmap_count)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _ar_emit roadmap unknown "$(_why "$rc" roadmap_count "the roadmap artifact was not looked for")"
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
  #
  # WHAT IT DOES NOT COVER, stated rather than implied: `automerge-ok` is bounded to auto-merge
  # and the required-check contexts. `delete_branch_on_merge` and conversation-resolution are
  # deliberately NOT in it — `baseline repo apply` is bounded to exactly two settings by a
  # recorded decision that says "do not add a third" — so this rung is narrower than #81's
  # settings bullet. Widening it needs that decision reversed first, not a third reader here.
  local st sd
  st="$(_fact settings string)"; rc=$?
  sd="$(_fact settings_detail string)" || sd=""
  [ "$rc" -eq 0 ] || st=""
  case "$st" in
    ok|todo|na|unknown) _ar_emit settings "$st" "${sd:-reported by repo-settings.sh}" ;;
    "") _ar_emit settings unknown "$(_why "$rc" settings "repo settings were not read — run 'baseline repo status'")" ;;
    *)  die "tracker: .settings must be ok|todo|na|unknown (got '$st')" ;;
  esac

  # --- release ---
  # ABSENT AND EMPTY ARE DIFFERENT, and collapsing them was a real defect in the first draft.
  # `.release_command // ""` reads a caller that could not reach the roadmap artifact exactly like
  # one that read it and found no marker — so a transient `gh` failure told the operator to add a
  # marker their artifact may already carry. That is the shape verify-before-asserting.md forbids:
  # say what could not be established, not what is true. `has()` separates them.
  #
  # AND IT MUST BE A STRING. `"release_command":false` is neither absent nor a marker, and the
  # first version accepted it as one because it was a non-empty scalar.
  #
  # AMBIGUITY IS ITS OWN ANSWER. `roadmap-lib.sh release-command` deliberately returns EVERY
  # declared value so a caller can refuse a split declaration — `release-convention.sh status`
  # reports exactly that as AMBIGUOUS. Taking `head -n1` threw that away and picked one at
  # random, which is the one outcome worse than reporting the problem. `cmd_facts` now passes the
  # count through.
  local relcmd rc_count
  rc_count="$(_count release_command_count)" || rc_count=""
  relcmd="$(_fact release_command string)"; rc=$?
  if [ -n "$rc_count" ] && [ "$rc_count" -gt 1 ]; then
    _ar_emit release todo "the roadmap declares $rc_count release-command markers — /roadmap needs exactly one; retire the extras"
  elif [ "$rc" -ne 0 ]; then
    _ar_emit release unknown "$(_why "$rc" release_command "the roadmap artifact's release-command marker was not read")"
  elif [ -n "$relcmd" ]; then
    # THE CONTRACT SAYS "RESOLVES TO A REAL TARGET", and a non-empty marker is not that. A marker
    # naming a skill that is missing or disabled leaves `/roadmap` emitting `Next: none` and the
    # release loop dead — which is precisely the shape of #81's original complaint, one step
    # further along. `cmd_facts` carries the resolution result across; when it could not be
    # established the rung says so rather than guessing either way.
    local resolved
    resolved="$(_fact release_command_resolved boolean)" || resolved=""
    case "$resolved" in
      true)  _ar_emit release ok "release command '$relcmd' resolves to an installed skill" ;;
      false) _ar_emit release todo "the roadmap declares release-command '$relcmd', but no installed skill by that name was found — /roadmap would emit 'Next: none' and the release loop stays dead" ;;
      *)     _ar_emit release unknown "release-command '$relcmd' is declared, but whether it RESOLVES could not be established — a declared marker is not a real target (#3)" ;;
    esac
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
# The only part of this file that touches the network. It is deliberately thin: it reads, and
# where a verdict is needed it DELEGATES to the reader that owns that verdict rather than forming
# one — the armed decision to `roadmap-lib.sh release-counts`, the settings decision to
# `repo-settings.sh automerge-ok`, the `## Decisions` rows to `roadmap-lib.sh decisions`. It
# carries their answers across; it does not compute its own. (Saying it "classifies nothing"
# would overstate that: mapping `automerge-ok`'s exit code onto ok/todo/na IS a classification —
# it is just not a NEW model, which is the property that matters.) `tracker` turns what this
# prints into rung records, and every rule with judgement in it lives there, offline and tested.
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

  local repo ms_json ms unm rc_n relcmd labels dispo body roadmap_num
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
    || die "facts: cannot resolve the repository from $PWD"

  # Milestones — `state=all`, PAGINATED (#79). Two separate reasons, and the first was a real
  # gap: a CLOSED milestone can still hold OPEN issues, and those issues are exactly as invisible
  # to release composition as the ones in an open theme — so reading `state=open` let a closed
  # `Audit Results` escape the disposition rung entirely, while the criterion says EVERY
  # pre-existing milestone. And an unpaginated read silently drops the tail, which is one more
  # milestone this contract would never ask the owner about.
  local out="{}"
  if ms_json="$(gh api --paginate "repos/$repo/milestones?state=all&per_page=100" 2>/dev/null)"; then
    # A CLOSED milestone with zero open issues is genuinely settled and asking about it would be
    # noise, so the disposition question is limited to milestones that still HOLD open work —
    # which is the thing the criterion is actually about.
    if ms="$(printf '%s' "$ms_json" | jq -s '[ (add // [])[] | select((.open_issues // 0) > 0 or .state == "open") | {title, open_issues} ]' 2>/dev/null)"; then
      out="$(printf '%s' "$out" | jq --argjson ms "$ms" '. + {milestones: $ms}')"
    fi
  fi

  # SEARCH QUALIFIERS TAKE THEIR VALUE AS DATA, and a milestone title is project-supplied text.
  # `milestone:"$rel"` interpolated the title straight into the query, so a supported custom name
  # containing a quote or a backslash rewrites the query rather than filtering it. `release-
  # convention.sh` already models this correctly: keep the filter fixed, pass the title as a
  # parameter. Here that means asking the MILESTONE ENDPOINT for its number and counting against
  # that, which needs no quoting at all — and is the same identifier `release-counts` works from.
  _ghq() {  # <query> — total_count for a search, or nothing (the read is NOT defaulted to 0)
    gh api -X GET search/issues -f q="$1" --jq '.total_count' 2>/dev/null
  }
  # `is:issue`, because repos/…/issues returns pull requests too and would count them as work.
  if unm="$(_ghq "repo:$repo is:issue is:open no:milestone")" && [ -n "$unm" ]; then
    out="$(printf '%s' "$out" | jq --argjson n "$unm" '. + {unmilestoned: $n}')"
  fi
  if rc_n="$(_ghq "repo:$repo is:issue is:open label:roadmap")" && [ -n "$rc_n" ]; then
    out="$(printf '%s' "$out" | jq --argjson n "$rc_n" '. + {roadmap_count: $n}')"
  fi

  # The roadmap artifact's NUMBER, resolved once. It is needed twice: to read the artifact's body,
  # and to EXCLUDE it from the armed count below.
  roadmap_num="$(gh api -X GET search/issues -f q="repo:$repo is:issue is:open label:roadmap" \
                   --jq '.items[0].number // empty' 2>/dev/null || true)"

  # ARMED IS TABULATED BY `roadmap-lib.sh release-counts`, NOT COUNTED HERE. That predicate is the
  # one home for "is this milestone armed", and its rules are load-bearing in ways a `total_count`
  # cannot reproduce: it counts CLOSED issues too (a nearly-done release is still armed), it
  # excludes pull requests, and it EXCLUDES THE ROADMAP ARTIFACT BY NUMBER. A milestone holding
  # only the roadmap issue is unarmed there and would have been armed here — the two disagreeing
  # about one milestone is worse than either answer alone, and re-deriving the rule is exactly
  # what this repo's design principles forbid.
  # REUSE THE RESPONSE ALREADY READ. This was a SECOND, identical milestone request whose failure
  # `|| true` swallowed into an empty `ms_num` — and because `out` already carried `milestones`,
  # the branch below then asserted `slate_armed:false`, diagnosing an empty release milestone from
  # a transient network error. `ms_json` is the same list, already fetched and already known to
  # have parsed; the number is in it.
  local ms_num=""
  if [ -n "${ms_json:-}" ]; then
    ms_num="$(printf '%s' "$ms_json" | jq -r -s --arg t "$rel" \
                '[ (add // [])[] | select(.title == $t) | .number ] | first // empty' 2>/dev/null || true)"
  fi
  if [ -n "${ms_num:-}" ]; then
    local mi_json armed_flag
    if mi_json="$(gh api --paginate "repos/$repo/issues?milestone=$ms_num&state=all&per_page=100" 2>/dev/null)"; then
      # Field 1 of line 1 IS the armed verdict. Taking it whole is the point: `release-counts`
      # owns what "armed" means, and the previous version called it only to discard its answer
      # and re-count the list itself — which is the copy this delegation exists to remove.
      armed_flag="$(printf '%s' "$mi_json" | bash "$_AR_LIB_DIR/roadmap-lib.sh" \
                      release-counts "$blk" "${roadmap_num:-0}" 2>/dev/null | sed -n '1p' | awk '{print $1}')" || armed_flag=""
      case "$armed_flag" in
        0) out="$(printf '%s' "$out" | jq '. + {slate_armed: false}')" ;;
        1) out="$(printf '%s' "$out" | jq '. + {slate_armed: true}')" ;;
        *) : ;;   # unreadable -> omit the fact -> `unknown` downstream, never a pass
      esac
    fi
  elif [ -n "${ms_json:-}" ] && printf '%s' "$out" | jq -e 'has("milestones")' >/dev/null 2>&1; then
    # The milestone genuinely does not appear in a list we DID read — a real, observed "not armed"
    # rather than an unread fact. Gated on `ms_json` being non-empty so a FAILED milestone read
    # can never reach here; that path omits the fact and yields `unknown`, which is the truth.
    out="$(printf '%s' "$out" | jq '. + {slate_armed: false}')"
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
  if [ -n "${roadmap_num:-}" ] && body="$(gh issue view "$roadmap_num" --json body --jq .body 2>/dev/null)"; then
    if dispo="$(printf '%s' "$body" | bash "$_AR_LIB_DIR/roadmap-lib.sh" decisions 2>/dev/null \
                  | jq -R -s 'split("\n") | map(select(length > 0))')"; then
      out="$(printf '%s' "$out" | jq --argjson d "$dispo" '. + {dispositions: $d}')"
    fi
    # EVERY declared value, and the COUNT with it. `release-command` returns them all precisely so
    # a split declaration can be REFUSED — `release-convention.sh status` reports that as
    # AMBIGUOUS. `head -n1` discarded the ambiguity and picked one arbitrarily, which is the one
    # outcome worse than reporting the problem.
    local rc_all rc_count
    if rc_all="$(printf '%s' "$body" | bash "$_AR_LIB_DIR/roadmap-lib.sh" release-command 2>/dev/null)"; then
      rc_count="$(printf '%s\n' "$rc_all" | sed '/^$/d' | wc -l | tr -d ' ')"
      out="$(printf '%s' "$out" | jq --argjson n "${rc_count:-0}" '. + {release_command_count: $n}')"
      relcmd="$(printf '%s\n' "$rc_all" | sed '/^$/d' | head -n1)"
      out="$(printf '%s' "$out" | jq --arg c "${relcmd:-}" '. + {release_command: $c}')"
      # DOES IT RESOLVE? The marker is an agent invocation (`/release`, `release`), and a skill
      # of that name must exist somewhere the agent will look: the project's own scoped skills
      # first (which is where decision D14 says every adopting repo puts its release skill), then
      # each installed agent home. Emitted as a FACT rather than decided here — `tracker` owns the
      # rung — and OMITTED when no agent home is present at all, because then the question is
      # unanswerable rather than answered "no".
      local rel_name rel_found=false rel_checked=false ah
      rel_name="${relcmd#/}"; rel_name="${rel_name%% *}"
      if [ -n "$rel_name" ]; then
        for ah in "$PWD/.claude/skills" "$PWD/.codex/skills" "$PWD/.gemini/config/skills" \
                  "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/config/skills"; do
          [ -d "$ah" ] || continue
          rel_checked=true
          [ -f "$ah/$rel_name/SKILL.md" ] && { rel_found=true; break; }
        done
        [ "$rel_checked" = true ] \
          && out="$(printf '%s' "$out" | jq --argjson r "$rel_found" '. + {release_command_resolved: $r}')"
      fi
    fi
  fi

  # Repo settings — CLASSIFIED BY repo-settings.sh, never re-derived here. Its `automerge-ok`
  # exit code already encodes what a correctly configured repo looks like, including the
  # required-checks-before-auto-merge ordering; restating any of it would be a second model.
  local am
  bash "$_AR_LIB_DIR/repo-settings.sh" automerge-ok >/dev/null 2>&1; am=$?
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
  # THE ROOT IS OPTIONAL AND IT IS POSITIONAL, so it may only be taken from a NON-option argument.
  # Taking `$1` unconditionally meant the documented `baseline adopt status --agents codex` bound
  # `--agents` to `root`, shifted it away, and died with "not a directory: --agents" — every
  # option-only invocation of the advertised command.
  local root=""
  case "${1:-}" in
    -*|'') : ;;
    *) root="$1"; shift ;;
  esac
  [ -n "$root" ] || root="$PWD"
  [ -d "$root" ] || die "status: not a directory: $root"
  # THE OPTIONS ARE SPLIT AND FORWARDED, not all handed to `probe`. A repo initialised with
  # `release-convention.sh --release-name` uses a milestone this command must be TOLD about;
  # forwarding everything to `probe` meant `--release-milestone` reached the one subcommand that
  # does not take it, so a custom-named release was unreportable through the documented entry
  # point. Each option goes to the half that owns it.
  local probe facts p_args=() f_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release-milestone|--backlog-milestone|--blocker-label)
        [ "$#" -ge 2 ] || die "status: $1 needs a value"; f_args+=("$1" "$2"); shift 2 ;;
      --agents) [ "$#" -ge 2 ] || die "status: --agents needs a value"; p_args+=("$1" "$2"); shift 2 ;;
      *) die "status: unknown argument $1" ;;
    esac
  done
  probe="$(cmd_probe "$root" "${p_args[@]+"${p_args[@]}"}")" || die "status: the offline probe failed"
  # A FAILED LIVE READ IS NOT FATAL, and that is deliberate: the offline half is still worth
  # reporting, and every tracker rung it could not establish comes out `unknown` — which is
  # non-green, so nothing is glossed over by continuing.
  facts="$( cd "$root" && cmd_facts "${f_args[@]+"${f_args[@]}"}" 2>/dev/null )" || facts='{}'
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
