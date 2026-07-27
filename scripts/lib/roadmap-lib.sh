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
#   roadmap-lib.sh branch-health <expected-sha> <active-workflows> # {check_runs,statuses} on stdin
#   roadmap-lib.sh release-ready <label-exists 0|1> <armed 0|1> <open-blockers N> <open-issues N> <canceled 0|1> <health>
#   roadmap-lib.sh release-counts <blocker-label> [roadmap-issue-number]   # milestone JSON on stdin
#   roadmap-lib.sh marker-title                                   # roadmap artifact body on stdin
#   roadmap-lib.sh deps-from-body [self-issue-number]             # issue/decision body on stdin
#   roadmap-lib.sh decisions                                      # roadmap artifact body on stdin
#   roadmap-lib.sh open-issues                                    # paginated issues JSON on stdin
#   roadmap-lib.sh read-complete <read-count> <expected-total>
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

  # Regex-escape the slug so it can be embedded in the keyword pattern below as a LITERAL.
  # A repo name legitimately contains `.`, `-`, `+`; escaping every non-alphanumeric is the
  # portable way to neutralize all of them at once (escaping a char that needs no escape is
  # harmless in Oniguruma). Without this, a repo like `acme/my.app` would match `my_app` too.
  local slug_re
  slug_re="$(printf '%s' "$slug" | LC_ALL=C sed 's/[^a-zA-Z0-9_]/\\&/g')"

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
  #
  # The reference itself accepts all three forms GitHub documents, but ONLY for THIS repo:
  #   #12  ·  owner/repo#12  ·  https://github.com/owner/repo/issues/12
  # The repo-qualified forms matter precisely here: GitHub does not auto-link closing keywords
  # on a PR whose base is not the default branch, so for a stacked PR the body scan is the only
  # signal — and a PR that writes the full `owner/repo#12` syntax would otherwise read as "not
  # targeted" and let /roadmap emit work that PR already closes. Another repo's qualified
  # reference still does NOT match, because the slug is pinned literally.
  printf '%s' "$json" | jq -e --argjson n "$n" --arg slug "$slug" --arg slugre "$slug_re" '
    # Guard the SHAPE first: a non-array (an object, a string) must raise, not quietly return
    # false — a fail-open "no PR targets this" is the outcome this predicate exists to prevent.
    if type != "array" then error("not an array") else . end
    | any(.[];
        # (1) the PR linked-issue set, matched on BOTH number and repository.
        ((.closingIssuesReferences // [])
         | any(.number == $n
               and ((.repository.owner.login // "") + "/" + (.repository.name // "")) == $slug))
        # (2) a closing keyword in the body (`// ""` covers a null body, which test() rejects).
        #     The reference is `#N`, `<this-repo>#N`, or a this-repo issue URL — never one
        #     belonging to another repo, since $slugre pins the current slug as a literal.
        #     (No apostrophes in this program: it is a single-quoted shell string.)
        or ((.body // "")
            | test("\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]*:?[ \t]*"
                   + "((" + $slugre + ")?#|https?://github\\.com/" + $slugre + "/issues/)"
                   + ($n|tostring) + "(?![0-9])"
                   ; "i"))
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

# --- branch-health ---------------------------------------------------------------------------
# Reduce the default branch's live check state to ONE health enum (issue #78). Print it on line 1
# and, when it is not `green`, a one-line reason on line 2. Exit 0 for any computed answer; 2 on
# bad input — a health read that cannot be parsed must never read as `green`.
#
#   green         every check that ran on the expected commit concluded non-failing.
#   not-green     at least one check on that commit concluded in a failing state.
#   indeterminate a check is still running, reports no conclusion, or belongs to a DIFFERENT
#                 commit — i.e. the answer is unknown. The caller FAILS CLOSED on this.
#   no-ci         this repo has no CI at all (no active workflows AND no checks on the commit),
#                 so there is nothing to verify. The caller proceeds and says the check was
#                 skipped — #24's "must not deadlock a repo that has no CI" degradation.
#
# WHY NOT `gh run list --branch <default> --limit 1` (the shape #78's body suggested): that lists
# workflow RUNS by branch, newest first, so it can answer with an unrelated scheduled workflow, a
# run for an OLDER commit, or one workflow's success while a sibling is red. "Is the branch green"
# only means anything against a specific commit, so this predicate is anchored to the expected
# HEAD SHA and evaluates every check attached to it.
#
# WHY BOTH check-runs AND commit statuses: the Checks API carries GitHub Actions and check-run
# apps; the legacy Statuses API carries everything else (CircleCI, Vercel, Cloudflare, …). Reading
# only one silently ignores whole CI providers, which on a deploying repo is the exact
# "confidently ship broken code" failure #78 exists to prevent.
#
# Arguments:
#   <expected-sha>   the default branch's HEAD commit, resolved live by the caller. Every
#                    check-run is matched against it: a check attached to another commit is stale
#                    evidence, so it makes the answer `indeterminate`, never `green`.
#   <active-workflows>  count of ACTIVE CI workflow definitions (0 = none configured). This is the
#                    only thing that distinguishes "no CI exists" from "CI exists but has not
#                    reported here yet" — `gh run list` returns `[]` for both, which is precisely
#                    why it cannot be the discriminator.
#
# stdin is ONE JSON object the caller assembles from its two reads, so this stays pure:
#   {"check_runs": <.check_runs of the check-runs response>, "statuses": <.statuses of the status response>}
#
# A conclusion of `skipped` or `neutral` is NOT a failure — that is how GitHub itself scores a
# required check, and treating a skipped job as red would wedge every repo with conditional jobs.
cmd_branch_health() {
  [ "$#" -eq 2 ] || die "branch-health: needs exactly 2 args: <expected-sha> <active-workflows> (check JSON on stdin)"
  local sha="$1" workflows="$2" json out
  # A SHA is required and must look like one: defaulting it would let a caller that failed to
  # resolve HEAD compare every check against the empty string and get a confident `green`.
  case "$sha" in
    ''|*[!0-9a-fA-F]*) die "branch-health: <expected-sha> must be a hex commit sha (got '$sha')" ;;
  esac
  [ "${#sha}" -ge 7 ] || die "branch-health: <expected-sha> is too short to identify a commit (got '$sha')"
  is_uint "$workflows" || die "branch-health: <active-workflows> must be a non-negative integer (got '$workflows')"
  command -v jq >/dev/null 2>&1 || die "branch-health: jq is required"

  json="$(cat)"
  # Unlike pr-targets-issue, an EMPTY read is not a benign "nothing here": it means the health
  # reads produced nothing at all, which is unknown, not healthy. Fail closed.
  case "$json" in *[![:space:]]*) : ;; *) die "branch-health: empty input (health could not be read)" ;; esac

  # One jq program decides, so the rules live in one place rather than being re-derived per caller.
  # `-e` is deliberately NOT used: this program always prints a verdict, and its exit status is
  # reserved for a genuine parse failure.
  out="$(printf '%s' "$json" | jq -r --arg sha "$sha" --argjson wf "$workflows" '
    if type != "object" then error("not an object") else . end
    | (.check_runs // []) as $runs
    | (.statuses  // []) as $sts
    | if ($runs | type) != "array" or ($sts | type) != "array" then error("check_runs/statuses must be arrays") else . end
    # A check attached to a different commit is evidence about the WRONG build. Count it, and let
    # it force `indeterminate` below — dropping it silently could leave zero checks and read as
    # no-ci, inventing a pass out of a stale read.
    | ([$runs[] | select((.head_sha // "") != $sha)] | length) as $wrongsha
    | [$runs[] | select((.head_sha // "") == $sha)] as $mine
    # Anything not yet `completed`, or completed with no conclusion, is still unknown.
    | ([$mine[] | select((.status // "") != "completed" or (.conclusion // null) == null)]) as $pending
    | ([$sts[]  | select((.state  // "") == "pending")]) as $stpending
    # `$bad` considers ONLY checks that actually finished. A still-running check has no conclusion,
    # and scoring a null conclusion as "not success" would report a RUNNING build as red — turning
    # every mid-CI run into a false `not-green` instead of the honest `indeterminate`.
    | ([$mine[] | select((.status // "") == "completed" and (.conclusion // null) != null)
                | select(.conclusion | IN("success","skipped","neutral") | not)]) as $bad
    | ([$sts[]  | select((.state // "") | IN("success","pending") | not)]) as $stbad
    | (($mine | length) + ($sts | length)) as $total
    | if   ($bad | length) > 0 or ($stbad | length) > 0 then
             "not-green\nfailing: " + ([($bad[] | .name // "check"), ($stbad[] | .context // "status")] | join(", "))
      elif ($pending | length) > 0 or ($stpending | length) > 0 then
             "indeterminate\nstill running: " + ([($pending[] | .name // "check"), ($stpending[] | .context // "status")] | join(", "))
      elif $wrongsha > 0 then
             "indeterminate\n" + ($wrongsha|tostring) + " check(s) report a different commit than " + $sha
      elif $total > 0 then "green"
      elif $wf == 0 then "no-ci"
      else "indeterminate\n" + ($wf|tostring) + " active workflow(s) exist but none has reported on " + $sha
      end
  ' 2>/dev/null)" || die "branch-health: could not parse the health JSON (malformed input)"
  [ -n "$out" ] || die "branch-health: could not parse the health JSON (malformed input)"
  printf '%s\n' "$out"
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
#   <health>         the default branch's live health, from `branch-health` (issue #78):
#                    green | not-green | indeterminate | no-ci | skipped.
#
# BOTH counts are passed and the LIBRARY selects between them. The caller could equally well
# pass one pre-selected count, but then the mode rule above would live in prose an agent
# re-derives every run, and could only be checked by hand; taking both makes it executable and
# lets scripts/check-roadmap.sh pin it.
#
# <health> IS REQUIRED, and that is the point. An optional argument defaulting to "skip" would be
# fail-OPEN: every caller that was not updated would keep returning `met` without ever verifying
# the build, which is the exact hole #78 was filed to close — and it would close silently. A
# required argument breaks such a caller loudly instead. `skipped` remains available as an
# EXPLICIT opt-out for a caller whose decision genuinely is not about shippable code (see
# `baseline release roll`, which runs AFTER the cut and archives bookkeeping); the difference is
# that the opt-out is written at the call site, where a reviewer can see it.
#
# Verdicts, in precedence order (first match wins — every input maps to exactly one):
#   unarmed — the milestone has no requirements yet. Neither ready nor "roadmap complete";
#             an empty release set must never emit a cut.
#   unmet   — requirements remain (open blockers, or open issues in fallback mode).
#   held    — the count is satisfied BUT an abandoned (NOT_PLANNED) must-have is present.
#             Withheld for owner review: an abandoned requirement is an owner decision, not an
#             automatic pass. Deterministic (same tracker state → same verdict every run) and
#             self-clearing on a real tracker edit (reopen / unlabel / drop from the milestone).
#   not-green     — requirements are satisfied but the default branch is RED. A /debug signal,
#                   never a cut signal.
#   indeterminate — requirements are satisfied but health could not be established. FAIL CLOSED:
#                   an unknown build is treated as unshippable, never as green.
#   met     — armed, satisfied, nothing canceled, and the branch is green (or there is no CI to
#             check) → emit the release command.
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
#   canceled + red branch    → `held` WINS. Both withhold the cut, so the choice cannot ship
#                              anything wrong either way; `held` is reported first because it has
#                              a deterministic owner remedy (reopen / unlabel / drop) whereas red
#                              CI clears on its own once the build is fixed. Ordering health after
#                              the tracker verdicts also means health is only consulted at the
#                              would-be-`met` boundary, so a repo with open blockers never blocks
#                              on a CI read it does not need.
#   unmet/unarmed + any health → the tracker verdict wins unchanged, so a repo that has not
#                              adopted CI sees byte-identical behavior until it is actually
#                              at the point of cutting.
cmd_release_ready() {
  [ "$#" -eq 6 ] || die "release-ready: needs exactly 6 args: <label-exists 0|1> <armed 0|1> <open-blockers N> <open-issues N> <canceled 0|1> <health green|not-green|indeterminate|no-ci|skipped>"
  local label_exists="$1" armed="$2" open_blockers="$3" open_issues="$4" canceled="$5" health="$6" count
  case "$label_exists" in 0|1) : ;; *) die "release-ready: <label-exists> must be 0 or 1 (got '$label_exists')" ;; esac
  case "$armed"        in 0|1) : ;; *) die "release-ready: <armed> must be 0 or 1 (got '$armed')" ;; esac
  case "$canceled"     in 0|1) : ;; *) die "release-ready: <canceled> must be 0 or 1 (got '$canceled')" ;; esac
  is_uint "$open_blockers" || die "release-ready: <open-blockers> must be a non-negative integer (got '$open_blockers')"
  is_uint "$open_issues"   || die "release-ready: <open-issues> must be a non-negative integer (got '$open_issues')"
  # An UNRECOGNISED health value is an ERROR, never a pass. A typo must not fall through to `met`.
  case "$health" in
    green|not-green|indeterminate|no-ci|skipped) : ;;
    *) die "release-ready: <health> must be one of green|not-green|indeterminate|no-ci|skipped (got '$health')" ;;
  esac

  # THE MODE SELECTION — the one thing this argument is for.
  if [ "$label_exists" -eq 1 ]; then count="$open_blockers"; else count="$open_issues"; fi

  if [ "$armed" -eq 0 ]; then printf 'unarmed\n'; return 0; fi
  if [ "$count" -gt 0 ]; then printf 'unmet\n'; return 0; fi
  if [ "$canceled" -eq 1 ]; then printf 'held\n'; return 0; fi
  # Health gates ONLY the final step, so it is read at the would-be-`met` boundary and nowhere else.
  case "$health" in
    not-green)     printf 'not-green\n';     return 0 ;;
    indeterminate) printf 'indeterminate\n'; return 0 ;;
  esac
  printf 'met\n'
}

# --- release-counts -------------------------------------------------------------------------
# Derive release-ready's five inputs from one milestone's issues. `release-ready` decides; this
# decides WHAT IT IS TOLD, and those tabulation rules are load-bearing in exactly the same way:
# armed counts closed issues too, the roadmap artifact is excluded, PRs are excluded, and only a
# NOT_PLANNED-closed blocker counts as canceled. Get any one wrong and the verdict is wrong while
# the predicate stays innocent — so both halves belong in the one testable home, not one here and
# one restated per caller (design-principles §1).
#
# Stdin: the JSON array from `gh api --paginate "repos/OWNER/REPO/issues?milestone=N&state=all"`.
# Empty stdin is an empty milestone (`unarmed`), not an error — a milestone with no issues is a
# real, expected state.
#
# `<roadmap-issue-number>` is THE canonical artifact's number, excluded by NUMBER — not by label.
# The workflow's shorthand for this exclusion is a `-label:roadmap` search qualifier, but that is
# broader than what it means: a CLOSED historical issue that still carries the label would also be
# dropped, which can under-count a milestone into `unarmed` or, worse, hide a NOT_PLANNED-canceled
# blocker and turn a `held` release into a `met` one. Excluding the one issue the caller identifies
# as the artifact is exactly the documented rule ("exclude the roadmap issue itself"). Omit the
# argument (or pass 0) when the artifact is known not to be in this milestone.
#
# Prints THREE lines, so a caller can also act on the issues rather than only count them:
#   1. `<armed 0|1> <open-blockers N> <open-issues N> <canceled 0|1>`  — feed straight to release-ready
#   2. space-separated numbers of the OPEN NON-blocker issues (the rollover's leftovers)
#   3. space-separated numbers of the OPEN blocker issues (a caller that must refuse, and name them)
#
# Excluding PRs is not defensive tidying: `repos/…/issues` returns pull requests too, so counting
# them would make a milestone look armed (or blocked) by a PR, disagreeing with every `is:issue`
# query the workflow runs.
cmd_release_counts() {
  case "$#" in
    1|2) : ;;
    *) die "release-counts: needs <blocker-label> [roadmap-issue-number] (milestone issue JSON on stdin)" ;;
  esac
  command -v jq >/dev/null 2>&1 || die "release-counts: jq not found"
  local blk="$1" skip="${2:-0}" out
  [ -n "$skip" ] || skip=0
  is_uint "$skip" || die "release-counts: <roadmap-issue-number> must be a non-negative integer (got '$2')"
  # `-s` + `add`: accept BOTH shapes `gh api --paginate` can produce — one merged array (what
  # gh 2.95 returns for a REST array endpoint) and the separate-array-per-page stream its own
  # `--help` documents ("Each page is a separate JSON array or object"). Reading only the first
  # input would silently undercount a multi-page milestone, and undercounting open blockers
  # produces a `met` verdict that archives a milestone with an open must-have still inside it.
  # Depending on undocumented merging for that is not a bet worth taking; `-s` costs one flag.
  # (Empty stdin slurps to `[]` -> `add` is null -> `// []`, so an empty milestone still works.)
  out="$(jq -r -s --arg blk "$blk" --argjson skip "$skip" '
    (add // []) as $all
    | [ $all[] | select(has("pull_request") | not)
          | select(.number != $skip) ]                                         as $rows
    | [ $rows[] | select(.state == "open") ]                                   as $open
    | [ $open[] | select(([.labels[].name] | index($blk)) != null) ]           as $ob
    | [ $rows[] | select(.state == "closed" and .state_reason == "not_planned")
                | select(([.labels[].name] | index($blk)) != null) ]           as $can
    | (
        "\(if ($rows|length) > 0 then 1 else 0 end) \($ob|length) \($open|length) \(if ($can|length) > 0 then 1 else 0 end)",
        ([ $open[] | select(([.labels[].name] | index($blk)) == null) | .number | tostring ] | join(" ")),
        ([ $ob[] | .number | tostring ] | join(" "))
      )' 2>/dev/null)" \
    || die "release-counts: malformed JSON on stdin"
  # Re-pad to exactly three lines. `$( )` strips TRAILING newlines, so a milestone with no
  # leftovers and no open blockers would collapse the three-record contract to one line. Sequential
  # `read`s happen to survive that; a consumer that takes line 3 directly would not, and a contract
  # that only holds for some inputs is the kind that breaks a caller written later.
  printf '%s\n' "$out" | awk 'NR <= 3 { print } END { for (i = NR + 1; i <= 3; i++) print "" }'
}

# --- marker-title ---------------------------------------------------------------------------
# Print the DISTINCT release-milestone titles named by a roadmap artifact body (stdin), one per
# line. Empty output means "the convention is not active here" — the caller decides whether that
# is a refusal or classic mode; it is never an error.
#
# The value is matched as `[^>]*`, NOT `.*`: a greedy match would run past the marker's own `-->`
# and absorb a later one on the same line, resolving a different title than the reader sees.
#
# The carve-out drops an empty value and the literal `NAME` — the schema's own example token,
# which bootstrap can copy verbatim (base/workflows/roadmap.md). Treating that placeholder as a
# real milestone is the classic false activation this whole opt-in is designed to avoid.
cmd_marker_title() {
  [ "$#" -eq 0 ] || die "marker-title: takes no arguments (roadmap artifact body on stdin)"
  # `grep -o` (one match per LINE OF OUTPUT), not `sed s///p` (one substitution per line of
  # INPUT): two markers on a single line must surface as two titles, so the caller can refuse an
  # ambiguous artifact. With sed, the leading `.*` is greedy and silently keeps only the last.
  grep -o '<!--[[:space:]]*release-milestone:[[:space:]]*[^>]*-->' \
    | sed 's/.*release-milestone:[[:space:]]*//; s/-->$//; s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | grep -vx 'NAME' \
    | sort -u
  return 0
}

# --- deps-from-body ---------------------------------------------------------------------------
# Print the dependency edges DECLARED BY a body (stdin), one issue number per line, ascending and
# deduped. Empty output means "this body declares no edges" — a normal result, never an error.
#
# WHY THIS IS A PREDICATE AND NOT PROSE (#108). /roadmap's edge rule was stated only in the
# workflow ("an issue body that says `Depends on #N` / `Blocked by #N`; `Refs #N` is NOT a
# dependency"), so every run re-derived it by eye. Two failures followed from that, and both are
# the same class as #69's `#N`-substring over-match:
#   1. a NEGATED mention read as an edge — "no longer depends on #25" must retire an edge, not
#      create one, and a reader scanning for the keyword sees only the keyword;
#   2. an edge that outlived its source text kept blocking a bundle, because nothing re-derived
#      the set from the body each run.
# Extracting it here makes the rule executable, so scripts/check-roadmap.sh can pin both
# directions instead of the workflow asserting them in prose nobody can run.
#
# THE RULES, exactly:
#   - KEYWORD-ONLY. `depends on` / `depends upon` / `dependent on` / `blocked by` / `blocked on`
#     (any case, optional `:`). A bare `#N`, `Refs #N`, `Relates to #N` or prose proximity is a
#     cross-reference and never an edge — the rule step 5 already states, now enforced.
#   - NEGATION RETIRES, never creates. If the clause containing the keyword carries a negator
#     (`no`, `not`, `never`, `no longer`, `without`, `removed`, `dropped`, `retired`, `canceled`,
#     `superseded`, `n't`), the match is SKIPPED. A clause runs from the previous `.` `;` `:` `!`
#     `?` or dash to the keyword, so "depends on #78; not blocked by #25" yields #78 only.
#   - THIS REPO ONLY. The reference must be a bare `#N`. `owner/repo#N` is deliberately NOT
#     matched: another repo's issue number is meaningless as a local edge, and matching the
#     trailing `#N` would fabricate an edge to whatever local issue shares that number (the
#     cross-repo false-positive `pr-targets-issue` also refuses).
#   - CHAINS. `Depends on #5, #6 and #7` yields all three: after the keyword the scan consumes
#     `#N` runs separated only by `,` `;` `&` `+` `and` or spaces, and STOPS at the first other
#     word. "Depends on #5 (the gate) and #6" therefore yields #5 only — conservative on purpose;
#     an edge invented from prose is what blocks a bundle forever.
#   - ONE LINE PER EDGE. Matching is line-scoped, so a keyword and its reference must share a
#     line. A dependency wrapped across a newline is not an edge (and reads as one to nobody).
#   - NO SELF-EDGE. `<self-issue-number>`, when given, is dropped: an issue depending on itself
#     is a degenerate cycle, never a real prerequisite.
#
# The artifact's `## Decisions` rows are fed through this SAME subcommand, so an owner decision
# declares (or retires) an edge with exactly the vocabulary an issue body uses — one rule, one
# implementation, one test.
cmd_deps_from_body() {
  case "$#" in
    0|1) : ;;
    *) die "deps-from-body: takes at most one argument: [self-issue-number] (body on stdin)" ;;
  esac
  local self="${1:-0}"
  [ -n "$self" ] || self=0
  is_uint "$self" || die "deps-from-body: <self-issue-number> must be a non-negative integer (got '$1')"

  # LC_ALL=C keeps the byte-wise scan below predictable on a body containing multibyte text; the
  # two dash characters are normalized by literal string replacement rather than a bracket
  # expression, which is exactly what a byte-oriented locale cannot express safely.
  LC_ALL=C awk -v self="$self" '
    # Literal (never regex) replace-all, so a dash normalization cannot be re-interpreted.
    function lreplace(s, from, to,   out, p) {
      out = ""
      while ((p = index(s, from)) > 0) {
        out = out substr(s, 1, p - 1) to
        s = substr(s, p + length(from))
      }
      return out s
    }
    BEGIN {
      apos = sprintf("%c", 39)   # a literal apostrophe; this program is single-quoted in shell
      KW  = "(depends?|dependent|dependant)[ \t]+(on|upon)|blocked[ \t]+(by|on)"
      NEG = "(^|[^a-z0-9_])(no|not|never|nor|longer|without|remove[sd]?|retire[sd]?"
      NEG = NEG "|drops?|dropped|cancels?|cancell?ed|supersede[sd]?|obsolete|n" apos "t)"
      NEG = NEG "([^a-z0-9_]|$)"
      # A `#N` chain step: an optional separator, then the reference. `#` must be reached
      # directly, so `acme/repo#5` (a qualified reference) never enters the chain.
      STEP = "^[ \t]*(:|,|;|&|\\+|and)?[ \t]*#[0-9]+"
    }
    {
      rest = tolower($0)
      # Normalize the dashes that also end a clause (em/en) to a single-byte boundary char.
      rest = lreplace(rest, "\342\200\224", ".")
      rest = lreplace(rest, "\342\200\223", ".")
      while (match(rest, KW)) {
        kstart = RSTART; klen = RLENGTH
        clause = substr(rest, 1, kstart - 1)
        # Keep only the text since the last clause boundary — a negation in an EARLIER sentence
        # must not suppress a later, genuine edge.
        cut = 0
        for (i = 1; i <= length(clause); i++) {
          c = substr(clause, i, 1)
          if (c == "." || c == ";" || c == ":" || c == "!" || c == "?") cut = i
        }
        clause = substr(clause, cut + 1)
        rest = substr(rest, kstart + klen)
        if (clause ~ NEG) continue            # negated: this retires an edge, never declares one
        while (match(rest, STEP)) {
          step = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          h = index(step, "#")
          digits = substr(step, h + 1)
          # Bound the width BEFORE the numeric conversion. A run wider than an issue number is
          # not an issue reference, and converting it would leave awk holding a float that prints
          # in exponent/rounded form — emitting a fabricated "issue number" no tracker can have.
          if (length(digits) > 9) continue
          n = digits + 0
          if (n > 0 && n != self) print n
        }
      }
    }
  ' | sort -n -u
  return 0
}

# --- decisions --------------------------------------------------------------------------------
# Print the QUESTION IDs recorded in the roadmap artifact's `## Decisions` section (body on
# stdin), one per line, deduped. Empty output means no decision is recorded — never an error.
#
# WHY (#108). An owner decision recorded in an issue COMMENT is invisible to reconcile, so the
# same question reprinted on every run — three consecutive runs re-asked the #73/#25 question
# after it had been answered. The fix is a durable home reconcile actually reads, and a run must
# not re-surface a question whose id appears there. That check has to be mechanical: "did the
# owner already answer this?" is exactly the kind of judgment an agent re-litigates every run.
#
# The section is OWNER-AUTHORITATIVE: /roadmap reads it and never rewrites or removes a row (the
# one part of the artifact reconcile does not own). Rows are markdown table rows whose FIRST cell
# is the question id the run printed; surrounding backticks and whitespace are stripped, and the
# header/separator rows are skipped. Parsing stops at the next `#`-heading, so a `|` table in a
# later section can never be mistaken for a decision.
cmd_decisions() {
  [ "$#" -eq 0 ] || die "decisions: takes no arguments (roadmap artifact body on stdin)"
  LC_ALL=C awk '
    # Any heading ends the section; the Decisions heading (only) starts it.
    /^[[:space:]]*#/ {
      inside = (tolower($0) ~ /^[[:space:]]*##[[:space:]]+decisions[[:space:]]*$/)
      next
    }
    !inside { next }
    /^[[:space:]]*\|/ {
      row = $0
      sub(/^[[:space:]]*\|/, "", row)
      p = index(row, "|")
      cell = (p > 0) ? substr(row, 1, p - 1) : row
      gsub(/`/, "", cell)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      if (cell == "") next
      if (tolower(cell) == "question") next          # the header row
      if (cell ~ /^[-:]+$/) next                     # the |---|---| separator row
      print cell
    }
  ' | sort -u
  return 0
}

# --- open-issues ------------------------------------------------------------------------------
# Print the OPEN ISSUE numbers from a paginated `repos/OWNER/REPO/issues?state=open` read (stdin),
# one per line, ascending and deduped. Empty stdin is an empty repo, not an error.
#
# WHY (#79). The workflow read the backlog with a bare `gh issue list --limit 200`: no pagination,
# no truncation detection, and `gh` returns newest-first — so a repo past the cap silently loses
# its OLDEST issues, which skew foundational and dependency-bearing. The worst consequence is not
# a missing row: an open issue absent from the open set is reconciled to **Done**, so real work
# vanishes from the plan. Reading `repos/…/issues` with `gh api --paginate` removes the magic
# constant entirely — completeness stops depending on a number somebody guessed.
#
# Excluding PRs is the load-bearing detail: `repos/…/issues` returns pull requests too, so the
# count would not be comparable to the `is:issue` Search query `read-complete` checks it against —
# and every PR would be slotted into a bundle as if it were work to do.
#
# The roadmap artifact is deliberately NOT excluded here. This set is compared against a
# repo-wide `is:issue is:open` total, so both sides must count the same population; the caller
# drops the artifact where the contract calls for it ("the roadmap issue excludes itself").
# Excluding it here would make every completeness check off by one — a `short` verdict on a
# perfectly complete read, i.e. a hard stop on a healthy repo.
cmd_open_issues() {
  [ "$#" -eq 0 ] || die "open-issues: takes no arguments (paginated issues JSON on stdin)"
  command -v jq >/dev/null 2>&1 || die "open-issues: jq not found"
  local out
  # `-s` + `add`: accept both shapes `gh api --paginate` can produce — one merged array, and the
  # separate-array-per-page stream its own --help documents. Reading only the first input would
  # silently drop every page after the first, which is the exact truncation this subcommand
  # exists to end. (Same reasoning, same idiom as release-counts.)
  out="$(jq -r -s '
    (add // []) as $all
    | [ $all[] | select(has("pull_request") | not) | select(.state == "open") | .number ]
    | unique | .[] | tostring' 2>/dev/null)" \
    || die "open-issues: malformed JSON on stdin"
  [ -z "$out" ] || printf '%s\n' "$out"
}

# --- read-complete ------------------------------------------------------------------------------
# Compare how many issues were actually read against the exact total, and print the verdict:
#   complete — read == expected. Proceed.
#   short    — read <  expected. The read is MISSING issues: never persist a roadmap built from it.
#   ahead    — read >  expected. Benign: the REST read saw an issue the Search index has not
#              caught up to yet. More data than expected can never reconcile an open issue to Done.
# Exit 0 with a verdict; bad input exits 2 (a completeness check that cannot answer must not be
# read as "complete").
#
# WHY THE ASYMMETRY. Truncation is not an error — a full page is indistinguishable from a complete
# list, so the workflow's hard-stop-on-`gh`-error guard never fires on it. The Search API's
# `total_count` IS exact at any size (the workflow already trusts it for the readiness gauge), so
# it is the one cross-check available. Only the SHORT direction is dangerous, and that asymmetry is
# what makes this usable: the Search index lags REST by a moment, so demanding exact equality in
# both directions would hard-stop healthy runs whenever an issue was filed mid-read.
#
# A `short` verdict is either real truncation or a sub-second index lag on a just-closed issue.
# Both are fixed the same way — stop, do not persist a partial plan, and re-run once state settles.
cmd_read_complete() {
  [ "$#" -eq 2 ] || die "read-complete: needs exactly 2 args: <read-count> <expected-total>"
  local got="$1" want="$2"
  is_uint "$got"  || die "read-complete: <read-count> must be a non-negative integer (got '$got')"
  is_uint "$want" || die "read-complete: <expected-total> must be a non-negative integer (got '$want')"
  if   [ "$got" -lt "$want" ]; then printf 'short\n'
  elif [ "$got" -gt "$want" ]; then printf 'ahead\n'
  else                              printf 'complete\n'
  fi
}

# --- dispatch ------------------------------------------------------------------------------
main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    pr-targets-issue) cmd_pr_targets_issue "$@" ;;
    branch-health)    cmd_branch_health "$@" ;;
    release-ready)    cmd_release_ready "$@" ;;
    release-counts)   cmd_release_counts "$@" ;;
    marker-title)     cmd_marker_title "$@" ;;
    deps-from-body)   cmd_deps_from_body "$@" ;;
    decisions)        cmd_decisions "$@" ;;
    open-issues)      cmd_open_issues "$@" ;;
    read-complete)    cmd_read_complete "$@" ;;
    *) printf 'roadmap-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
