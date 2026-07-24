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
# WHAT each predicate means — the targeting rules, the `Refs #N` carve-out, and the readiness
# verdicts — is documented once, for the agent that executes it, in `base/workflows/roadmap.md`
# step 6. This header documents the CONTRACT (arguments, stdin shape, exit status); the
# per-function comments below note only what the code itself cannot show.
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
#   roadmap-lib.sh release-ready <label-exists 0|1> <armed 0|1> <open-blockers N> <open-issues N> <canceled 0|1>
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

# is_uint <string> — true iff the argument is a non-empty run of digits that `[` can actually
# compare. Guards every numeric argument so a typo ("N", "-1", "1 2") is an ERROR (2), never
# silently coerced to 0 — which for release-ready would fabricate a "met" release.
#
# The length bound is part of that same guarantee, not decoration: a value wider than a shell
# integer makes `[ "$n" -gt 0 ]` fail with "integer expression expected", and because that test
# guards the `unmet` branch, the failure would fall through and print `met` — inventing a
# release cut from a value the shell could not even evaluate. 18 digits stays inside signed
# 64-bit on every supported shell, and no real issue count approaches it.
is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 18 ]
}

# --- pr-targets-issue ---------------------------------------------------------------------
# Exit 0 iff some open PR targets issue <n> in repo <slug>; 1 if none does; 2 on bad input.
cmd_pr_targets_issue() {
  [ "$#" -eq 2 ] || die "pr-targets-issue: needs exactly 2 args: <issue-number> <owner/repo> (PR JSON on stdin)"
  local n="$1" slug="$2" json rc
  is_uint "$n" || die "pr-targets-issue: issue number must be a positive integer (got '$n')"
  # The slug is required (never defaulted from `gh repo view`): this library must stay pure,
  # and a silently-wrong repo would reintroduce the cross-repo false freeze it exists to stop.
  case "$slug" in
    */*) : ;;
    *)   die "pr-targets-issue: repo slug must be OWNER/REPO (got '$slug')" ;;
  esac
  command -v jq >/dev/null 2>&1 || die "pr-targets-issue: jq is required"

  json="$(cat)"
  # An empty read is the "no open PRs" case, not a malformed one — `gh pr list` on an empty
  # set prints `[]`, but a caller piping from an empty capture is treated identically.
  # A `case` glob does this with no subshell and no bash-4 expansion (bash-3.2 safe).
  case "$json" in *[![:space:]]*) : ;; *) return 1 ;; esac

  # One jq program does both halves of the union. The issue number and slug are passed as
  # typed --arg/--argjson values, never interpolated into the program text, so a slug with
  # regex or jq metacharacters can neither break nor inject into the filter.
  #
  # Keyword regex mirrors GitHub's documented closing keywords. `\b` on the LEFT keeps the
  # keyword a standalone word — without it "precloses #12" / "unfixes #12" would match inside a
  # longer word and re-introduce the very over-match this fix removes. `[ \t]*:?[ \t]*` allows
  # the "Closes: #12" form; `(?![0-9])` stops `#7` matching `#70`; `"i"` is case-insensitive.
  printf '%s' "$json" | jq -e --argjson n "$n" --arg slug "$slug" '
    # Guard the SHAPE first: a non-array (an object, a string) must raise, not quietly return
    # false — a fail-open "no PR targets this" is the outcome this predicate exists to prevent.
    if type != "array" then error("not an array") else . end
    | any(.[];
        # (1) the PR linked-issue set, matched on BOTH number and repository.
        ((.closingIssuesReferences // [])
         | any(.number == $n
               and ((.repository.owner.login // "") + "/" + (.repository.name // "")) == $slug))
        # (2) a closing keyword in the body (`// ""` covers a null body, which test() rejects).
        or ((.body // "")
            | test("\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]*:?[ \t]*#" + ($n|tostring) + "(?![0-9])"; "i"))
      )
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
#   <label-exists>   1 = the `release-blocker` label EXISTS in the repo, 0 = it does not (404).
#                    This SELECTS THE MODE, and it is keyed off label EXISTENCE, never a live
#                    count — so closing the last blocker can never flip the repo from
#                    blocker-mode to fallback mode (which would silently raise the bar from
#                    "no blockers left" to "no issues left" exactly when a release came due).
#   <armed>          1 = the milestone holds >=1 issue (open or closed), 0 = it is empty.
#   <open-blockers>  open `release-blocker` issues IN the milestone. Used in blocker-mode.
#   <open-issues>    open issues in the milestone (any label). Used in fallback mode.
#   <canceled>       1 = a `release-blocker` in the milestone is closed as NOT_PLANNED.
#
# BOTH counts are passed and the LIBRARY selects between them. The caller could equally well
# pass one pre-selected count, but then the mode rule above would live in prose an agent
# re-derives every run, and could only be checked by hand; taking both makes it executable and
# lets scripts/check-roadmap.sh pin it.
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
# Precedence rationale for the combinations that are not self-evident:
#   unarmed + canceled       → unarmed. An empty milestone has nothing to cut regardless.
#   canceled + open blockers → unmet. The open blockers already withhold the cut, and reporting
#                              "unmet" keeps the operator building; the canceled row is still
#                              recorded in the artifact's Reconcile flags by the workflow.
#   canceled in FALLBACK     → still `held`. With no `release-blocker` label the workflow cannot
#                              produce a canceled blocker, so this combination should not arise
#                              from a real tracker; if a caller reports one anyway, withholding
#                              is the safe read (never invent a cut from a contradictory input).
cmd_release_ready() {
  [ "$#" -eq 5 ] || die "release-ready: needs exactly 5 args: <label-exists 0|1> <armed 0|1> <open-blockers N> <open-issues N> <canceled 0|1>"
  local label_exists="$1" armed="$2" open_blockers="$3" open_issues="$4" canceled="$5" count
  case "$label_exists" in 0|1) : ;; *) die "release-ready: <label-exists> must be 0 or 1 (got '$label_exists')" ;; esac
  case "$armed"        in 0|1) : ;; *) die "release-ready: <armed> must be 0 or 1 (got '$armed')" ;; esac
  case "$canceled"     in 0|1) : ;; *) die "release-ready: <canceled> must be 0 or 1 (got '$canceled')" ;; esac
  is_uint "$open_blockers" || die "release-ready: <open-blockers> must be a non-negative integer (got '$open_blockers')"
  is_uint "$open_issues"   || die "release-ready: <open-issues> must be a non-negative integer (got '$open_issues')"

  # THE MODE SELECTION — the one thing this argument is for.
  if [ "$label_exists" -eq 1 ]; then count="$open_blockers"; else count="$open_issues"; fi

  if [ "$armed" -eq 0 ]; then printf 'unarmed\n'; return 0; fi
  if [ "$count" -gt 0 ]; then printf 'unmet\n'; return 0; fi
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
