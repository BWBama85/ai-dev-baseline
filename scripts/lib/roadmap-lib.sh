#!/usr/bin/env bash
# ai-dev-baseline — /roadmap decision predicates (issues #69 + #45).
#
# The /roadmap workflow is prose an agent executes, so its two load-bearing DECISIONS used to
# live only as inline gh/jq one-liners in the skill body — unexecutable, and therefore
# untestable. This library is the ONE home for both, so they can be regression-tested offline
# (scripts/check-roadmap.sh) and cited by the workflow instead of restated (the DRY discipline
# of docs/design-principles.md: source the shared primitive, never copy it).
#
# Both subcommands are PURE: they take already-fetched JSON on stdin (or plain arguments) and
# never call gh themselves. The workflow owns the live reads — one `gh pr list` for the whole
# batch, exactly as before — and pipes the result here. That keeps the network shape unchanged
# and makes every predicate hermetically testable with a fixture.
#
# --- in-flight targeting (#69) -----------------------------------------------------------
# A bundle member is frozen as "in-flight" only when an open PR ACTUALLY TARGETS it. The old
# test matched any `#N` substring in a PR body, so a passing `Refs #69` or prose ("similar to
# #69") froze a genuinely-ready issue indefinitely — contradicting the skill's own rule that
# `Refs #N` is a cross-reference, NOT an edge. Targeting is now the union of:
#   1. the PR's linked-issue set (`closingIssuesReferences`) — GitHub's OWN computed set, from
#      closing keywords or a manual link. Numeric, so `#7` can never match `#70`.
#   2. a tightly-scoped closing-keyword scan of the PR body (close/closes/closed, fix/fixes/
#      fixed, resolve/resolves/resolved — GitHub's exact keyword list, case-insensitive,
#      followed by optional whitespace/colon and `#N` at a word boundary).
# (2) is not redundant: GitHub only auto-links closing keywords on a PR targeting the DEFAULT
# branch, so a stacked PR into a feature branch has an empty closingIssuesReferences while its
# body still declares intent to close. Freezing it is the conservative, correct read — the
# point of the freeze is "someone is already implementing this."
#
# Cross-repo safety: closingIssuesReferences entries carry their own repository, and GitHub
# supports cross-repo closing links (`owner/repo#N`). Matching a bare number would let
# `other/repo#69` freeze THIS repo's #69, so a repo slug is required and both owner and name
# must match. Body-keyword matches are same-repo by construction (a bare `#N` in a body always
# means this repo; a cross-repo `owner/repo#N` mention is deliberately NOT matched).
#
# --- release readiness (#71/#27) ----------------------------------------------------------
# The release-goal convention's readiness predicate, factored out of the workflow prose so its
# four-way outcome is pinned by tests rather than re-derived in prose every run.
#
# EXIT STATUS IS FAIL-CLOSED. Every subcommand distinguishes a real answer from a broken input:
#   0  — yes / the answer is "targeted"
#   1  — no  / the answer is "not targeted" (a valid, trustworthy negative)
#   2  — ERROR: malformed JSON, bad arguments, or a missing dependency (jq).
# The caller MUST treat >=2 as a hard stop, never as a negative: a tooling failure that reads
# as "no open PR targets this" would emit an issue that is already being implemented, which is
# exactly the duplicate-work class this predicate exists to prevent.
#
# Usage:
#   roadmap-lib.sh pr-targets-issue <issue-number> <owner/repo>   # PR JSON on stdin
#   roadmap-lib.sh release-ready <label-exists 0|1> <armed 0|1> <open-blockers N> <canceled 0|1>
#   roadmap-lib.sh -h | --help
#
# `pr-targets-issue` stdin is the output of:
#   gh pr list --state open --limit 200 --json number,body,closingIssuesReferences
# An empty stdin (no open PRs) is a valid "not targeted" (exit 1), NOT an error — `gh pr list`
# prints `[]` for an empty set, and a genuinely empty string is treated the same way.
#
# Requires: jq (JSON parsing only — never gh).

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way the sibling scripts/lib modules
# do (skill-compose.sh, release-convention.sh). adb_usage vanishes without it, so a missing
# library FAILS LOUD rather than silently degrading a predicate the roadmap trusts.
_adb_rm_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_rm_common" ]; then
  printf 'roadmap-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_rm_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_rm_common"

usage() { adb_usage "$0"; }

# die <msg> — every hard error exits 2 (the fail-closed "do not trust this answer" status),
# never 1, which is reserved for a trustworthy negative.
die() { printf 'roadmap-lib: %s\n' "$*" >&2; exit 2; }

# is_uint <string> — true iff the argument is a non-empty run of digits. Guards every numeric
# argument so a typo ("N", "-1", "1 2") is an ERROR (2), never silently coerced to 0 — which
# for release-ready would fabricate a "met" release.
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# --- pr-targets-issue ---------------------------------------------------------------------
# Exit 0 iff some open PR targets issue <n> in repo <slug>; 1 if none does; 2 on bad input.
cmd_pr_targets_issue() {
  local n="${1-}" slug="${2-}" json rc
  is_uint "$n" || die "pr-targets-issue: issue number must be a positive integer (got '${n-}')"
  # The slug is required (never defaulted from `gh repo view`): this library must stay pure,
  # and a silently-wrong repo would reintroduce the cross-repo false freeze it exists to stop.
  case "$slug" in
    */*) : ;;
    *)   die "pr-targets-issue: repo slug must be OWNER/REPO (got '${slug-}')" ;;
  esac
  command -v jq >/dev/null 2>&1 || die "pr-targets-issue: jq is required"

  json="$(cat)"
  # An empty read is the "no open PRs" case, not a malformed one — `gh pr list` on an empty
  # set prints `[]`, but a caller piping from an empty capture is treated identically.
  # Whitespace is stripped with `tr` (not a ${var//} bash-4 expansion) to stay bash-3.2-safe.
  if [ -z "$(printf '%s' "$json" | tr -d '[:space:]')" ]; then return 1; fi

  # One jq program does both halves of the union. The issue number and slug are passed as
  # typed --arg/--argjson values, never interpolated into the program text, so a slug with
  # regex or jq metacharacters can neither break nor inject into the filter.
  #
  # Keyword regex mirrors GitHub's documented closing keywords. `[ \t]*:?[ \t]*` allows the
  # "Closes: #12" form; `(?![0-9])` stops `#7` matching `#70`; `"i"` is case-insensitive.
  # test() is applied to a NON-NULL body only (a PR body can be null, which test() rejects).
  printf '%s' "$json" | jq -e --argjson n "$n" --arg slug "$slug" '
    def targets_by_link:
      (.closingIssuesReferences // [])
      | any(
          .number == $n
          and ((.repository.owner.login // "") + "/" + (.repository.name // "")) == $slug
        );
    def targets_by_keyword:
      ((.body // "") | type == "string")
      and ((.body // "")
           | test("(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]*:?[ \t]*#" + ($n|tostring) + "(?![0-9])"; "i"));
    if type != "array" then error("not an array") else . end
    | any(.[]; targets_by_link or targets_by_keyword)
  ' >/dev/null 2>&1
  rc=$?
  # jq -e: 0 = true, 1 = false/null, >1 = a jq error (malformed JSON, non-array input). Map
  # the error band to 2 so a parse failure can never be read as a clean "not targeted".
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "pr-targets-issue: could not parse PR JSON (malformed input or not a JSON array)" ;;
  esac
}

# --- release-ready ------------------------------------------------------------------------
# Print the readiness verdict for the active release milestone and exit 0 (a computed verdict
# is a success; only bad input is an error). Arguments, in order:
#   <label-exists>   1 = the release-blocker label EXISTS in the repo, 0 = it does not (404).
#                    Keyed off label EXISTENCE, never the live count, so closing the last
#                    blocker never flips the repo from blocker-mode to fallback mode.
#   <armed>          1 = the milestone holds >=1 issue (open or closed), 0 = it is empty.
#   <open-blockers>  in blocker-mode: open release-blocker issues IN the milestone.
#                    in fallback mode (label absent): open issues in the milestone.
#   <canceled>       1 = a release-blocker in the milestone is closed as NOT_PLANNED.
#
# Verdicts, in precedence order (first match wins — every input maps to exactly one):
#   unarmed — the milestone has no requirements yet. Neither ready nor "roadmap complete";
#             an empty release set must never emit a cut.
#   unmet   — requirements remain (open blockers, or open issues in fallback mode).
#   held    — the count is satisfied BUT an abandoned (NOT_PLANNED) must-have is present.
#             Withheld for owner review: an abandoned requirement is an owner decision, not an
#             automatic pass. Deterministic (same tracker state → same verdict every run) and
#             self-clearing on a real tracker edit (reopen / unlabel / drop from the milestone).
#   met     — armed, satisfied, nothing canceled → emit the release command.
#
# Precedence rationale for the two combinations the plan review flagged:
#   unarmed + canceled     → unarmed. An empty milestone has nothing to cut regardless.
#   canceled + open blockers → unmet. The open blockers already withhold the cut, and reporting
#                            "unmet" keeps the operator building; the canceled row is still
#                            recorded in the artifact's Reconcile flags by the workflow.
cmd_release_ready() {
  local label_exists="${1-}" armed="${2-}" open_count="${3-}" canceled="${4-}"
  [ "$#" -eq 4 ] || die "release-ready: needs exactly 4 args: <label-exists 0|1> <armed 0|1> <open-blockers N> <canceled 0|1>"
  case "$label_exists" in 0|1) : ;; *) die "release-ready: <label-exists> must be 0 or 1 (got '$label_exists')" ;; esac
  case "$armed"        in 0|1) : ;; *) die "release-ready: <armed> must be 0 or 1 (got '$armed')" ;; esac
  case "$canceled"     in 0|1) : ;; *) die "release-ready: <canceled> must be 0 or 1 (got '$canceled')" ;; esac
  is_uint "$open_count" || die "release-ready: <open-blockers> must be a non-negative integer (got '$open_count')"

  # label_exists selects WHICH count the caller passed (blocker-mode vs fallback); the
  # predicate itself is the same "is the count zero" test either way. It is validated and
  # documented rather than ignored so the workflow and the tests agree on the contract.
  : "$label_exists"

  if [ "$armed" -eq 0 ]; then printf 'unarmed\n'; return 0; fi
  if [ "$open_count" -gt 0 ]; then printf 'unmet\n'; return 0; fi
  if [ "$canceled" -eq 1 ]; then printf 'held\n'; return 0; fi
  printf 'met\n'
}

# --- dispatch ------------------------------------------------------------------------------
main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    pr-targets-issue) cmd_pr_targets_issue "$@" ;;
    release-ready)    cmd_release_ready "$@" ;;
    *) printf 'roadmap-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
