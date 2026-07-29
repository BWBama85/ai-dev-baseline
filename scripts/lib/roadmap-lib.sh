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
#   roadmap-lib.sh compose-candidates <roadmap-issue-number> [bug-label]
#                                     # {issues,edges,exclude,canceled} on stdin
#   roadmap-lib.sh compose-select     # compose-candidates TSV on stdin
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
# BOTH keys are REQUIRED and must be arrays. A missing key is an ERROR, not an empty collection:
# defaulting it would turn an unreadable response into `no-ci`, which reaches `met` — a release
# fabricated from a health read nobody could parse.
#
# Check runs are attributed by `app.slug`: `github-actions` is GitHub Actions (the value comes from
# `adb_actions_app_slug` in common.sh — the ONE home, #179), anything else is another Checks API
# app. That distinction is load-bearing, because <active-workflows> counts ACTIONS workflows — so
# "some check run exists" is not evidence that Actions reported.
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
  #
  # Resolve the Actions slug BEFORE the program and refuse an empty one. This is not defensive
  # boilerplate: the attribution test is `(.app.slug // "") == $aslug`, and the `// ""` normalizes
  # unknown provenance to the empty string — so an empty $aslug would match exactly the check runs
  # whose app CANNOT be identified, and count them as Actions. That flips this predicate fail-OPEN
  # (a confident `green` from a build nobody attributed) in the one place a wrong green cuts a
  # release. A broken install must fail loud here, exactly as the missing-common.sh guard above does.
  local aslug
  aslug="$(adb_actions_app_slug 2>/dev/null)" || aslug=""
  [ -n "$aslug" ] || die "branch-health: adb_actions_app_slug is unavailable or empty (broken install)"
  out="$(printf '%s' "$json" | jq -r --arg sha "$sha" --argjson wf "$workflows" \
                                     --arg aslug "$aslug" '
    if type != "object" then error("not an object") else . end
    # BOTH keys must be PRESENT and be arrays. Defaulting a missing key to [] would convert a
    # malformed or truncated health response into "two empty collections", which reads as `no-ci`
    # and lets release-ready return `met` — fabricating a release from a response nobody could
    # parse. `no-ci` must mean "explicitly nothing reported", never "the shape was unreadable".
    | if (has("check_runs") | not) or (has("statuses") | not)
      then error("check_runs and statuses are both required") else . end
    | .check_runs as $runs
    | .statuses  as $sts
    | if ($runs | type) != "array" or ($sts | type) != "array" then error("check_runs/statuses must be arrays") else . end
    # A check attached to a different commit is evidence about the WRONG build. Count it, and let
    # it force `indeterminate` below — dropping it silently could leave zero checks and read as
    # no-ci, inventing a pass out of a stale read.
    # Compare SHAs case-INSENSITIVELY. GitHub returns them lowercase and the workflow sources the
    # expected one from the same API, so today both sides always match — but a caller that
    # obtained the SHA elsewhere (an operator, or the auto-cut driver in #73) would otherwise get
    # a confident `indeterminate` from nothing but letter case. Fail-closed, yet still wrong.
    # NOTE: no apostrophe anywhere in this jq program — it is a single-quoted shell string, and
    # one stray apostrophe closes it and turns the whole file into a syntax error.
    | ($sha | ascii_downcase) as $want
    | [$runs[] | select((.head_sha // "" | ascii_downcase) == $want)] as $mine
    # Derived, not re-selected: the match is total, so the two sets partition $runs. Writing the
    # complement as its own filter would be a second home for the SHA rule (including the
    # normalization) that has to track the first by hand.
    | (($runs | length) - ($mine | length)) as $wrongsha
    # "Finished" is defined ONCE, as a tag, and both buckets below read that tag. Writing the two
    # as separate hand-maintained complementary predicates would be a standing hazard: widen one
    # notion of "still running" and forget the other, and a check falls into NEITHER bucket and
    # silently reads as GREEN.
    | ([$mine[] | . + {_done: (((.status // "") == "completed") and ((.conclusion // null) != null))}]) as $tagged
    # Not yet completed, or completed with no conclusion => still unknown.
    | ([$tagged[] | select(._done | not)]) as $pending
    | ([$sts[]    | select((.state // "") == "pending")]) as $stpending
    # Only a FINISHED check can be bad. A still-running one has no conclusion, and scoring a null
    # conclusion as "not success" would report a RUNNING build as red — turning every mid-CI run
    # into a false `not-green` instead of the honest `indeterminate`.
    | ([$tagged[] | select(._done) | select(.conclusion | IN("success","skipped","neutral") | not)]) as $bad
    | ([$sts[]  | select((.state // "") | IN("success","pending") | not)]) as $stbad
    # Check runs produced by GitHub ACTIONS, which is what the workflow inventory counts. Actions
    # check runs carry app.slug == "github-actions" ($aslug, from the one home in common.sh); another
    # Checks API app (a linter bot, a deploy provider) carries its own slug. A check run whose app
    # cannot be identified (`app` is nullable in the GitHub REST schema) is deliberately NOT
    # counted as Actions: unknown provenance must not stand in as proof that Actions ran. That
    # direction is safe here, because falling through leaves the verdict indeterminate, never green.
    | ([$mine[] | select((.app.slug // "") == $aslug)]) as $actions
    | (($mine | length) + ($sts | length)) as $total
    | if   ($bad | length) > 0 or ($stbad | length) > 0 then
             "not-green\nfailing: " + ([($bad[] | .name // "check"), ($stbad[] | .context // "status")] | join(", "))
      elif ($pending | length) > 0 or ($stpending | length) > 0 then
             "indeterminate\nstill running: " + ([($pending[] | .name // "check"), ($stpending[] | .context // "status")] | join(", "))
      elif $wrongsha > 0 then
             "indeterminate\n" + ($wrongsha|tostring) + " check(s) report a different commit than " + $sha
      # Active workflows that produced no ACTIONS check run on this commit are unreported, and
      # that is true no matter what anything else said. Testing this before `green` is the whole
      # point: `$total` counts "somebody reported", not "everybody reported", so without this arm
      # one unrelated green result would satisfy $total > 0 and turn a genuinely unreported Actions
      # build into a confident `green` — a FALSE CUT. Two distinct providers can supply that
      # masking result, so the check has to be about ACTIONS specifically, not about volume:
      #   - a legacy commit status (one Vercel deploy), which $total counts; and
      #   - a check run from a DIFFERENT Checks API app, which $total also counts and which a
      #     plain "are there any check runs" test cannot tell apart from an Actions run.
      # Adding an unrelated passing result must never convert a refusal into a release.
      elif $wf > 0 and ($actions | length) == 0 then
             "indeterminate\n" + ($wf|tostring) + " active workflow(s) exist but Actions has not reported on " + $sha
      elif $total > 0 then "green"
      elif $wf == 0 then "no-ci"
      else "indeterminate\nno CI has reported on " + $sha
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
# `release-command` — the SAME discipline as marker-title, for the other required marker (#188).
#
# Why it needs a predicate rather than "assume CMD holds the right value": every bootstrapped
# roadmap body carries the schema's own marker-shaped EXAMPLE, so a naive read cannot tell a real
# declaration from documentation — and the no-marker branch and the declared-but-missing branch
# then stop being deterministically distinguishable, which is the whole point of the emission
# contract. Returns every distinct declared value so the caller can refuse an ambiguous artifact,
# exactly as it must for the milestone marker.
#
# The carve-out drops the placeholder names the schema itself uses (`your-skill`,
# `your-release-skill`, `CMD`), with or without a leading invocation prefix, so copying the example
# verbatim reads as "not declared" rather than as a command that can never resolve.
cmd_release_command() {
  [ "$#" -eq 0 ] || die "release-command: takes no arguments (roadmap artifact body on stdin)"
  # ONLY PROSE DECLARES (#117), applied to this marker. Structure is dropped BEFORE extraction:
  # fenced blocks, blockquotes, and inline code spans.
  #
  # The shared `md_prose` filter cannot be reused here — it strips HTML COMMENTS, and this marker
  # IS an HTML comment — so the same rule is applied with that half omitted.
  #
  # Why it is needed at all: the artifact schema documents the marker BY EXAMPLE, and every body
  # bootstrapped by an earlier version carries `<!-- release-command: /release -->` in its OPTIONAL
  # comment block. Its shape is identical to a real declaration, so no value-based carve-out can
  # tell them apart — `release` is a perfectly legitimate thing to declare. What distinguishes them
  # is MARKUP: the example sits in a code span or a fence; a declaration does not.
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*>/ { next }
    { line = $0; gsub(/`[^`]*`/, "", line); print line }
  ' \
    | grep -o '<!--[[:space:]]*release-command:[[:space:]]*[^>]*-->' \
    | sed 's/.*release-command:[[:space:]]*//; s/-->$//; s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | sed 's/^[/$]//' \
    | grep -vx 'your-skill' \
    | grep -vx 'your-release-skill' \
    | grep -vx 'CMD' \
    | sort -u
  return 0
}

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

# --- shared markdown-structure filter (#117) ---------------------------------------------------
# `md_prose(line)` returns the line with HTML comments removed, and sets MD_SKIP=1 when the line is
# STRUCTURE rather than prose — inside (or delimiting) a fenced block, or a blockquote. State
# carries across lines, so this is a streaming sanitizer, not a per-line test.
#
# WHY IT IS SHARED, and not inlined where it was first needed. This repo keeps fixing one bug
# family one instance at a time: #69 (a bare `#N` read as an edge), #108 (a NEGATED mention read as
# an edge), #117 (a mention inside a repro block read as an edge). The root cause every time is the
# same — TEXT THAT DOCUMENTS THE VOCABULARY IS NOT AN ASSERTION — and it applies to every consumer
# that reads an issue or artifact body, not just the one that happened to get reported. Both
# body-scanning subcommands here use this, so a future variant is fixed once:
#   - `deps-from-body`: a `Depends on #N` inside a fence/comment/blockquote declares nothing.
#   - `decisions`:      a `| … |` row inside one is not a recorded owner decision, and a `#` line
#                       inside one does not end the section. That second case is #108 exactly —
#                       a real decision going unseen means the question re-asks on every run.
# `pr-targets-issue` deliberately does NOT share it: that predicate is jq over GitHub's own
# computed link set, a different language answering a different question. Its body-scan half has
# the same exposure and is tracked separately rather than bolted on here.
#
# Assigned via `read -r -d ''` (not `$(cat <<…)`) for the reason skill-compose.sh gives: the
# program contains backticks, which command substitution would try to execute.
IFS= read -r -d '' _ADB_RM_MD <<'AWKMD' || true
    # Counted with substr/index rather than regex intervals: `{0,3}` is a POSIX interval that the
    # BSD awk on macOS and older mawk builds do not honor, and a silently-unmatched fence rule
    # would fail OPEN — every fence would leak its contents back into the scan.
    function lead_sp(s,   i) { i = 0; while (substr(s, i + 1, 1) == " ") i++; return i }
    function run_len(s, pos, ch,   n) { n = 0; while (substr(s, pos + n, 1) == ch) n++; return n }
    # How many leading characters are CONTAINER, not content: indentation plus an optional list
    # marker (`- ` / `* ` / `+ ` / `1. ` / `1) `) and the spaces after it. Returns -1 when the line
    # is indented past 3 with no marker — indented-block territory, which this pass leaves alone.
    #
    # WHY (#135). Without this, a fence or a blockquote written INSIDE a list item is invisible:
    # `- ```console` puts the delimiter after the marker, so the block was scanned (fabricating an
    # edge) and its indented closer was then read as a NEW opener, swallowing every real edge after
    # the list. Placing an example in a list item is one of the most common shapes in an issue.
    function content_at(s,   i, c, j, nsp, nd) {
      i = lead_sp(s)
      if (i > 3) return -1
      c = substr(s, i + 1, 1)
      if (c == "-" || c == "*" || c == "+") {
        j = i + 1                                   # 1-based position of the marker character
      } else {
        nd = 0
        while (nd < 10 && substr(s, i + 1 + nd, 1) >= "0" && substr(s, i + 1 + nd, 1) <= "9") nd++
        # CommonMark caps an ordered marker at NINE digits. A tenth means this is not a list at
        # all, and treating it as one drops the line: `1234567890. > Depends on #5` would read as
        # a list-nested blockquote and lose a real edge.
        if (nd == 0 || nd > 9) return i
        c = substr(s, i + nd + 1, 1)
        if (c != "." && c != ")") return i
        j = i + nd + 1
      }
      nsp = 0
      while (substr(s, j + 1 + nsp, 1) == " ") nsp++
      if (nsp == 0) return i                        # `**bold**`, `---`, `1.x`: not a list marker
      # 1-4 spaces after the marker are PADDING. At 5 or more, only the first is padding and the
      # remainder is content INDENTATION — so `-     ```' is an indented code line inside the
      # item, not a fence. Consuming it all would open a fence that CommonMark does not.
      if (nsp >= 5) return j + 1
      return j + nsp
    }
    # The CLOSER of an open fence: the same delimiter, a run at least as long, nothing but
    # whitespace after it, and indented no more than 3 past the OPENER's content column. That last
    # clause is container context, and it is load-bearing in both directions: without it a
    # 4-space-indented backtick run *inside* a top-level fence closes it early (scanning quoted
    # text, then reading the real closer as a fresh opener), and with too little of it a
    # list-nested closer never matches and the fence swallows the rest of the body.
    function fence_close(line, ch,   sp) {
      sp = lead_sp(line)
      if (sp > md_fence_at + 3) return 0
      return run_len(line, sp + 1, ch)
    }
    function after_close(line, n,   sp) { sp = lead_sp(line); return substr(line, sp + n + 1) }
    # Remove `<!-- ... -->`, both the inline form and one spanning lines.
    function strip_comments(s,   out, p, q, nbs, k) {
      out = ""
      while (1) {
        if (md_in_comment) {
          q = index(s, "-->")
          if (q == 0) return out                   # the comment swallows the rest of this line
          s = substr(s, q + 3); md_in_comment = 0
          continue
        }
        p = index(s, "<!--")
        if (p == 0) return out s
        # `\<!--` is an ESCAPED opener: CommonMark renders the `<` as text, so this is prose
        # PARITY MATTERS. Only an ODD run of preceding backslashes escapes the `<`: with two, the
        # first escapes the second and the opener is REAL, so treating it as prose would scan a
        # genuine comment's contents and fabricate an edge from them.
        # DISPLAYING the delimiter, not markup (#135). Treating it as real arms the cross-line
        # state, and an illustrative marker rarely has a `-->` — so it swallowed every edge and
        # every recorded decision in the rest of the body. Step over it and keep scanning.
        nbs = 0; k = p - 1
        while (k >= 1 && substr(s, k, 1) == "\\") { nbs++; k-- }
        if (nbs % 2 == 1) {
          out = out substr(s, 1, p + 3)
          s = substr(s, p + 4)
          continue
        }
        out = out substr(s, 1, p - 1)
        s = substr(s, p + 4); md_in_comment = 1; md_opened_here = 1
        # `<!-->` and `<!--->` are EMPTY comments in CommonMark: the opener and closer share their
        # dashes. Searching for `-->` strictly after the opener would miss them and arm the
        # cross-line state, swallowing the rest of the body — the edge-dropping direction.
        if (substr(s, 1, 1) == ">")  { s = substr(s, 2); md_in_comment = 0; continue }
        if (substr(s, 1, 2) == "->") { s = substr(s, 3); md_in_comment = 0; continue }
      }
    }
    # `md_fence_len` IS the in-a-fence flag: an opener only ever sets it from a run of >=3, so a
    # separate boolean would be a second copy of one fact for every site to keep in step.
    function md_prose(line,   fn, at) {
      MD_SKIP = 1
      # A GitHub body submitted through the web UI is CRLF, and `gh` passes it through verbatim.
      # Without this, a closer reads as "```\r", its must-be-blank tail is not blank, the fence
      # NEVER closes, and every edge in the rest of the body silently disappears — a dropped edge
      # marks a genuinely blocked bundle `ready`. Normalize once, for every consumer.
      if (substr(line, length(line), 1) == CR) line = substr(line, 1, length(line) - 1)
      if (md_fence_len) {                          # inside a fence: only its own closer matters
        fn = fence_close(line, md_fence_ch)
        if (fn >= md_fence_len && after_close(line, fn) ~ /^[[:space:]]*$/) {
          md_fence_ch = ""; md_fence_len = 0; md_fence_at = 0
        }
        return ""                                  # opener, content and closer are all skipped
      }
      md_opened_here = 0
      line = strip_comments(line)
      at = content_at(line)                        # the container's content column, computed ONCE
      if (at >= 0) {
        # A backtick fence opener may not carry a backtick in its info string; a tilde one may. The
        # two probes are sequential, not parallel, because that asymmetry is the whole rule. The
        # other delimiter never closes the current fence — that is what makes ``` inside ~~~
        # content. `md_fence_at` remembers this opener's column so its closer can be matched
        # relative to the same container.
        fn = run_len(line, at + 1, "`")
        if (fn >= 3 && index(substr(line, at + fn + 1), "`") == 0) {
          # A `<!--` on the OPENER line is info-string text, not a comment: the fence starts first,
          # so it wins. Leaving the comment armed would leak past the closer (the in-fence branch
          # never runs strip_comments) and swallow the whole rest of the body.
          if (md_opened_here) md_in_comment = 0
          md_fence_ch = "`"; md_fence_len = fn; md_fence_at = at; return ""
        }
        fn = run_len(line, at + 1, "~")
        if (fn >= 3) {
          if (md_opened_here) md_in_comment = 0
          md_fence_ch = "~"; md_fence_len = fn; md_fence_at = at; return ""
        }
        # A blockquote nested under a list marker (`- > …`) is still quoted material (#135), so
        # this tests the CONTENT position rather than the first non-space character.
        if (substr(line, at + 1, 1) == ">") return ""
      }
      MD_SKIP = 0
      return line
    }
    # An UNTERMINATED fence or comment swallows to end-of-body rather than leaking back to prose.
    BEGIN {
      md_fence_ch = ""; md_fence_len = 0; md_fence_at = 0
      md_in_comment = 0; md_opened_here = 0; MD_SKIP = 0
      CR = sprintf("%c", 13)
    }
AWKMD

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
#   - EMPHASIS IS NOT CONTENT (#112). Markdown emphasis and code delimiters (`*`, `**`, `_`,
#     `__`, backtick runs) between the keyword and the `#N`, or wrapping the `#N`, are stepped
#     over: `Depends on **#52**`, `**Depends on:** #78`, `` Depends on `#52` `` and
#     `- **Blocked by** #155` all declare. This is the UNDER-match mirror of #69's over-match and
#     the more dangerous half — a fabricated edge blocks a ready bundle where a dropped one marks
#     a genuinely blocked bundle `ready`, and six real edges were being dropped in this repo.
#     The tolerance is deliberately NOT a blanket "skip punctuation": each run must be tight
#     against the keyword, the separator, or the `#` (see the STEP slots in BEGIN), and a run that
#     OPENS before the reference must close after it. So `Depends on * #5` and
#     `` Depends on `#5 and more` `` still declare nothing. Emphasis INSIDE the keyword
#     (`Depends **on** #5`) is out of scope — that needs the real inline parser #136 carries.
#   - CHAINS. `Depends on #5, #6 and #7` yields all three: after the keyword the scan consumes
#     `#N` runs separated only by `,` `;` `&` `+` `and` or spaces, and STOPS at the first other
#     word. "Depends on #5 (the gate) and #6" therefore yields #5 only — conservative on purpose;
#     an edge invented from prose is what blocks a bundle forever.
#   - ONE LINE PER EDGE. Matching is line-scoped, so a keyword and its reference must share a
#     line. A dependency wrapped across a newline is not an edge (and reads as one to nobody).
#   - NO SELF-EDGE. `<self-issue-number>`, when given, is dropped: an issue depending on itself
#     is a degenerate cycle, never a real prerequisite.
#   - ONLY PROSE DECLARES (#117). Text that MARKUP marks as quoted or illustrative is not the
#     issue speaking, so it is removed BEFORE the keyword scan. See "STRUCTURE" below.
#
# STRUCTURE — an issue that DOCUMENTS the keyword must not acquire the edge (#117).
# This is the third instance of one bug family: #69 (a bare `#N` mention), #108 (a NEGATED
# mention), and now a mention the author never asserted at all — it sits inside a repro block, a
# quoted excerpt, or a schema comment. Each earlier instance was fixed one-off; this one removes
# the whole structural class in a single pass, so a fourth variant has nowhere to hide:
#   - FENCED CODE. A ``` or ~~~ fence (indented 0-3 spaces, run of >=3) opens a block; every line
#     to its closer is skipped. A closer is the SAME character, at least as long, and carries
#     nothing but whitespace after the run — so a mid-sentence ``` or a longer run with trailing
#     text stays content. A backtick fence's info string may not itself contain a backtick. The
#     other delimiter never closes the current fence, which is what makes ``` inside ~~~ (and the
#     reverse) plain content. An UNTERMINATED fence swallows to end-of-body rather than leaking.
#   - HTML COMMENTS. `<!-- … -->` is removed, inline and across lines. The roadmap artifact's own
#     schema comments quote `Depends on #78` as the example vocabulary; before this, reading the
#     `## Decisions` section derived that example as a real edge.
#   - BLOCKQUOTES. A `>` line is quoted material — someone else's text, or an excerpt — never this
#     issue's own declaration.
#   - CONTAINERS. Fences and blockquotes are recognized at the CONTENT column, so a fenced example
#     or a quote written inside a list item (`- ```console`) counts (#135). Missing that failed
#     both ways at once: the block was scanned, AND its indented closer read as a fresh opener,
#     swallowing every real edge after the list.
#   - INLINE CODE SPANS, targeted rather than blanket. The KEYWORD must sit outside a span; the
#     `#N` reference may sit inside one. So `` `**Depends on: #78**` `` (the whole clause quoted as
#     an example) declares nothing, while `` Depends on `#52` `` leaves its reference intact in the
#     scanned text and DOES declare (#112, which the targeting was built to leave room for).
#     Blanket span-stripping would DELETE the reference outright and put this rule in direct
#     conflict with that one; masking only the keyword lets both hold at once.
# DELIBERATELY NOT HANDLED: 4-space INDENTED code blocks. Four spaces are not reliably code — under
# a `- ` bullet, content starts at 2 and code needs 2+4=6, so a `^ {4}` skip deletes ordinary
# continuation PROSE. That direction is the dangerous one: a dropped edge silently unblocks a
# bundle that is genuinely blocked. Tracked separately rather than guessed at here.
#
# The artifact's `## Decisions` rows are fed through this SAME subcommand, so an owner decision
# declares (or retires) an edge with exactly the vocabulary an issue body uses — one rule, one
# implementation, one test. This is the ONLY edge extractor; `pr-targets-issue` answers a
# different question (GitHub CLOSING keywords in a PR body) and deliberately does not share it.
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
  LC_ALL=C awk -v self="$self" "$_ADB_RM_MD"'
    # Literal (never regex) replace-all, so a dash normalization cannot be re-interpreted.
    function lreplace(s, from, to,   out, p) {
      out = ""
      while ((p = index(s, from)) > 0) {
        out = out substr(s, 1, p - 1) to
        s = substr(s, p + length(from))
      }
      return out s
    }
    # --- inline code spans (#117) ---------------------------------------------------------------
    # This half stays LOCAL to deps-from-body: it produces a second, length-aligned copy that only
    # the KEYWORD scan reads, a contract no other consumer has. The line-structural half (fences,
    # HTML comments, blockquotes) is the shared `md_prose` filter prepended above.
    #
    # Replace every byte of an inline code span (delimiters included) with MASK, preserving LENGTH
    # so positions stay 1:1 with the unmasked line. Delimiters are equal-length backtick runs, per
    # CommonMark; an UNMATCHED run is literal text and is left alone. Only the KEYWORD scan reads
    # the masked copy — the reference scan reads the raw line, so a `#N` inside a span is left
    # intact rather than deleted, which is what lets STEP resolve it (see the INLINE CODE SPANS
    # and EMPHASIS IS NOT CONTENT rules above).
    # span_end(s, from, n) — where the run of EXACTLY n backticks that closes this span begins, or
    # 0 when the span is never closed. A LONGER run is not a closer: it is skipped whole, so
    # ``` inside a `` span stays content. (`close` is an awk builtin and cannot name this.)
    function span_end(s, from, n,   L, j, m) {
      L = length(s); j = from
      while (j <= L) {
        if (substr(s, j, 1) != "`") { j++; continue }
        m = run_len(s, j, "`")
        if (m == n) return j
        j += m
      }
      return 0
    }
    # Advance BOTH scan copies by the same offset. The 1:1 length invariant between `rest` and
    # `masked` is what lets an offset found in one index the other, so consuming them is a single
    # operation with one home — not a convention two call sites have to remember.
    function eat(at) { rest = substr(rest, at); masked = substr(masked, at) }
    function mask_spans(s,   out, i, L, n, e, k) {
      if (index(s, "`") == 0) return s            # the common line: nothing to mask, no rebuild
      out = ""; i = 1; L = length(s)
      while (i <= L) {
        if (substr(s, i, 1) != "`") { out = out substr(s, i, 1); i++; continue }
        n = run_len(s, i, "`")
        e = span_end(s, i + n, n)
        # Unmatched: literal text, copied as a SLICE. Matched: MASK must be written byte-by-byte,
        # because it is \x01 by design — padding with spaces instead would let `depends` + span +
        # `on` fuse into a keyword the author never wrote.
        if (e == 0) { out = out substr(s, i, n); i += n }
        else        { for (k = i; k < e + n; k++) out = out MASK; i = e + n }
      }
      return out
    }
    BEGIN {
      MASK = sprintf("%c", 1)   # a byte no issue body carries; never printed, only matched against
      apos = sprintf("%c", 39)   # a literal apostrophe; this program is single-quoted in shell
      KW  = "(depends?|dependent|dependant)[ \t]+(on|upon)|blocked[ \t]+(by|on)"
      NEG = "(^|[^a-z0-9_])(no|not|never|nor|longer|without|remove[sd]?|retire[sd]?"
      NEG = NEG "|drops?|dropped|cancels?|cancell?ed|supersede[sd]?|obsolete|n" apos "t)"
      NEG = NEG "([^a-z0-9_]|$)"
      # The markdown emphasis / code characters, as a SET for index() and as a bracket expression
      # for the regexes below. A bare backtick, because awk has no escape for one and needs none.
      EMPH = "*_`"
      EMR  = "[" EMPH "]*"                 # a run of them, possibly empty
      # A `#N` chain step: an optional emphasis run, an optional separator, then the reference.
      # `#` must still be reached without crossing a WORD character, so `acme/repo#5` (a qualified
      # reference) never enters the chain.
      #
      # WHERE THE THREE EMR SLOTS MAY SIT, and why not simply "skip any punctuation" (#112). Each
      # slot is TIGHT against the thing it belongs to, and that tightness is the whole guard:
      #   1. `^EMR`      — a CLOSER of emphasis that opened before/around the keyword, so it is
      #                    flush against the keyword: `**Depends on** #5` leaves `** #5`.
      #   2. `SEP EMR`   — the same closer when the author put the `:` inside the emphasis:
      #                    `**Depends on:** #5` leaves `:** #5`. Tight against the separator.
      #   3. `EMR#`      — an OPENER wrapping the reference: `Depends on **#5**`. Tight against `#`.
      # A run that floats in whitespace belongs to none of them and is REFUSED, which is what keeps
      # `Depends on * #5` (a stray asterisk, or a bullet that wandered onto the keyword line) from
      # reading as an edge while `*Blocked by* #5` — byte-identical except for that space — still
      # does. A blanket "step over punctuation" cannot tell those two apart.
      STEP = "^" EMR "[ \t]*((:|,|;|&|\\+|and)" EMR ")?[ \t]*" EMR "#[0-9]+"
    }
    {
      # STRUCTURE FIRST, on the RAW line (#117) — a fence is recognized before lowercasing, dash
      # normalization, clause/negation analysis and chain parsing, so none of them ever sees text
      # the markup marked as quoted or illustrative.
      line = md_prose($0)                          # the shared filter; state carries across lines
      if (MD_SKIP) next

      rest = tolower(line)
      # CHEAP NECESSARY CONDITION, before any rewriting. Every alternative of KW begins `depend` or
      # `blocked`, and the dash normalization below maps only em/en-dash to `.` — so it can neither
      # create nor destroy those prefixes. Bailing here skips the masking and the scan on the ~90%
      # of body lines that can never match. Safe at this point precisely because the fence and
      # comment state above is already updated for this line.
      if (rest !~ /depend|blocked/) next
      # Normalize the dashes that also end a clause (em/en) to a single-byte boundary char.
      rest = lreplace(rest, "\342\200\224", ".")
      rest = lreplace(rest, "\342\200\223", ".")
      # The keyword is matched against a copy whose inline code spans are masked, while the
      # reference chain is read from `rest`. The two are the same length, so the offsets below
      # stay aligned as both are consumed in lockstep.
      masked = mask_spans(rest)
      while (match(masked, KW)) {
        kstart = RSTART; klen = RLENGTH
        # The clause is read UNMASKED on purpose. A negator the author happened to code-format —
        # "this is `not` blocked by #5" — is still the author negating, and reading the masked copy
        # here would hide it and MINT an edge the pre-#117 predicate never produced. Masking exists
        # to stop a quoted keyword from DECLARING; it must not also stop a real one from retiring.
        clause = substr(rest, 1, kstart - 1)
        # Keep only the text since the last clause boundary — a negation in an EARLIER sentence
        # must not suppress a later, genuine edge.
        cut = 0
        for (i = 1; i <= length(clause); i++) {
          c = substr(clause, i, 1)
          if (c == "." || c == ";" || c == ":" || c == "!" || c == "?") cut = i
        }
        clause = substr(clause, cut + 1)
        eat(kstart + klen)
        if (clause ~ NEG) continue            # negated: this retires an edge, never declares one
        while (match(rest, STEP)) {
          step = substr(rest, RSTART, RLENGTH)
          eat(RSTART + RLENGTH)
          h = index(step, "#")
          # WRAPPER BALANCE (#112). An emphasis run that OPENS immediately before the reference
          # must reappear immediately after it. `Depends on **#5**` is a wrapped reference;
          # ``Depends on `#5 and more` `` is a quoted PHRASE that merely starts with one, and
          # without this the opener would be stepped over and the phrase mined for a number the
          # author never declared. The run is same-character and maximal, so nesting resolves at
          # its INNERMOST pair (`_**#5**_` checks the `**`) — matching an outer delimiter would
          # need a real inline parser, which is #136, not this predicate.
          #
          # Only an OPENER is held to this. A run with no opener to match is left alone, because
          # `Depends on #5**` already yielded 5 before this change and narrowing that would be the
          # under-match direction this issue exists to close. By the same reasoning an UNCLOSED
          # opener yields nothing: the balanced form is what authors actually write, and the rule
          # has to be statable in one sentence or the next variant has somewhere to hide.
          wrap = ""
          if (h > 1) {
            wc = substr(step, h - 1, 1)
            if (index(EMPH, wc) > 0) {
              j = h - 1
              while (j >= 1 && substr(step, j, 1) == wc) j--
              wrap = substr(step, j + 1, h - 1 - j)
            }
          }
          # `rest` was already advanced past the digits, so it begins exactly where a closer would.
          if (wrap != "" && substr(rest, 1, length(wrap)) != wrap) continue
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
  LC_ALL=C awk "$_ADB_RM_MD"'
    # Structure first (#117), through the SAME filter deps-from-body uses. Two bugs live here
    # without it, both on a document that ships fenced examples and an HTML comment INSIDE this
    # very section: a `| … |` row quoted in a fence would retire an owner question nobody
    # answered, and a `#` line quoted in one would end the section early — hiding every real
    # decision after it, which is #108 returning by another route.
    { $0 = md_prose($0); if (MD_SKIP) next }
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

# --- compose-candidates ----------------------------------------------------------------------
# The MECHANICAL half of release composition (D15 / #80). Rank the open backlog into the slate an
# agent then judges, so the parts that must not vary — tiering, dependency closure and the tie-break
# — are code with tests rather than prose an agent re-derives every cycle.
#
# WHY THIS IS A PREDICATE AND NOT WORKFLOW PROSE. The dangerous failure is not a mediocre pick, it
# is composing a release that can never DRAIN: promote an issue whose prerequisite stays in the
# backlog and the milestone holds a blocker nothing can close, so `/roadmap` reports `unmet`
# forever and the loop stops terminating — the same class of stall D15 exists to remove, one step
# further in. Whether a candidate is blocked is therefore computed here, from the derived edge set,
# and pinned by scripts/check-roadmap.sh.
#
# Stdin is ONE document, `{"issues": [...], "edges": [[dependent, prerequisite], ...]}`, assembled
# by the caller exactly as `branch-health` takes `{check_runs, statuses}`. `issues` is the open-issue
# read; `edges` is what `deps-from-body` derived THIS RUN. Multiple documents are slurped and
# merged, so a `--paginate` stream works unchanged. A missing `edges` key means "no edges known",
# which yields nothing blocked — the caller must not pass an edge set it failed to derive.
#
# Output is TSV, one candidate per line, and EMPTY output is a valid answer (an empty backlog),
# never an error:
#
#   tier  number  blocked  prereqs  title
#   bug   102     0        -        repo-settings: a 4-space-indented workflow is invisible…
#   bug   136     1        112      One paragraph-aware CommonMark prose filter…
#   other 20      0        -        /adopt: project-agnostic migration flow…
#
# ORDERING IS TOTAL AND STABLE: tier (bug before other, the owner-stated priority in D15), then
# unblocked before blocked, then ascending issue number — step 5 rule 4, so two runs over an
# unchanged tracker rank identically. `blocked` counts only prerequisites that are still OPEN in
# the same read: a closed one is satisfied and must not hold a candidate out of the release.
#
# What it deliberately does NOT do: pick. Tier `other` is offered ranked, not selected, because
# "which enhancements matter for this release" is judgement the workflow records in the artifact.
# It also does not rank by unblock leverage or capability closure — that is #80's surviving half.
cmd_compose_candidates() {
  case "$#" in
    1|2) : ;;
    *) die "compose-candidates: needs <roadmap-issue-number> [bug-label] ({issues,edges} JSON on stdin)" ;;
  esac
  command -v jq >/dev/null 2>&1 || die "compose-candidates: jq not found"
  # `${2-bug}`, NOT `${2:-bug}`: `:-` substitutes the default for an EMPTY argument as well as an
  # absent one, so an explicitly-empty label would silently become `bug` and the refusal below
  # could never fire — a caller passing an unset variable would compose against the wrong tier
  # and be told nothing.
  local skip="$1" bug="${2-bug}"
  is_uint "$skip" || die "compose-candidates: <roadmap-issue-number> must be a non-negative integer (got '$1')"
  [ -n "$bug" ] || die "compose-candidates: <bug-label> must not be empty"
  # `--arg`/`--argjson` for BOTH values: the label reaches jq as data, never as filter text, so a
  # label containing a quote or a backslash cannot alter the program (the same injection guard
  # pr-targets-issue applies to the repo slug).
  jq -r -s --arg bug "$bug" --argjson skip "$skip" '
    def clean: gsub("[\t\r\n]+"; " ");
    (map(.issues // []) | add // []) as $in
    | (map(.edges // []) | add // [])                                          as $ed
    | (map(.exclude // []) | add // [] | unique)                               as $ex
    | (map(.canceled // []) | add // [] | unique)                              as $can
    # THE UNIVERSE is every open non-roadmap issue, INCLUDING the excluded ones. Blocking is asked
    # of it, candidacy is asked of the set with `exclude` removed — two different questions, and
    # collapsing them is what would let a bug be promoted whose prerequisite reconcile has already
    # ruled un-emittable.
    | [ $in[] | select(has("pull_request") | not) | select(.number != $skip) ] as $univ
    | ([ $univ[].number ] | unique)                                            as $open
    | [ $univ[] | select(.number as $x | $ex | index($x) == null) ]            as $rows
    | [ $ed[]
        | select(type == "array" and length >= 2)
        | { d: (.[0] | tonumber?), p: (.[1] | tonumber?) }
        | select(.d != null and .p != null) ]                                  as $edges
    | [ $rows[]
        | . as $r
        | ( [ $edges[] | select(.d == $r.number) | .p ]
            | map(select(. != $r.number))
            # A prerequisite BLOCKS when it is still open (whether or not reconcile excluded it)
            # or when it was CANCELED — closed `NOT_PLANNED`. Cancellation does not satisfy a
            # dependent (step 4s `dep-canceled` rule), so equating every non-open prerequisite
            # with success would promote a bug whose prerequisite is never coming.
            | map(select(. as $x | ($open | index($x)) != null or ($can | index($x)) != null))
            | unique )                                                         as $pre
        | { n:     $r.number,
            t:     (if ([$r.labels[]?.name] | index($bug)) != null then 0 else 1 end),
            b:     (if ($pre | length) > 0 then 1 else 0 end),
            pre:   $pre,
            title: (($r.title // "") | clean) } ]
    | sort_by(.t, .b, .n)
    | .[]
    | [ (if .t == 0 then "bug" else "other" end),
        (.n | tostring),
        (.b | tostring),
        (if (.pre | length) > 0 then (.pre | map(tostring) | join(",")) else "-" end),
        .title ]
    | @tsv' 2>/dev/null \
    || die "compose-candidates: malformed JSON on stdin"
  return 0
}

# --- compose-select ---------------------------------------------------------------------------
# Turn the ranked slate into the set that is actually promoted: seed with the bug tier, close over
# prerequisites, then PRUNE anything whose prerequisites cannot all be promoted.
#
# The prune pass is the half that is easy to leave out and expensive to leave out. Closure alone
# pulls in a prerequisite only when it is itself a candidate; a prerequisite that reconcile
# EXCLUDED (tracker-only / owner-review) or that was CANCELED (closed `NOT_PLANNED`) has no row, so
# it can never be pulled in — and promoting its dependent anyway arms the milestone with a blocker
# that nothing can close. `/roadmap` would then report `unmet` forever: the release stops
# terminating, which is the same stall auto-composition exists to remove, one step further in.
#
# Stdin is the `compose-candidates` TSV. Output is one decision per line, so a drop is REPORTED
# rather than silently applied (the no-silent-caps discipline):
#
#   sel   102
#   sel   112
#   drop  136   112        # 136 wanted 112, which is not promotable
#
# Both loops are fixpoints over a finite candidate set, so both terminate: closure only ever adds,
# prune only ever removes, and each pass that changes nothing ends it.
cmd_compose_select() {
  [ "$#" -eq 0 ] || die "compose-select: takes no arguments (compose-candidates TSV on stdin)"
  # POSIX awk only — no gawk extensions, no `asort`. The output is sorted by the caller.
  awk -F'\t' '
    { tier[$2] = $1; pre[$2] = $4; n++; num[n] = $2 }
    END {
      for (i = 1; i <= n; i++) if (tier[num[i]] == "bug") sel[num[i]] = 1
      # closure: pull in every promotable prerequisite of everything selected
      do {
        changed = 0
        for (i = 1; i <= n; i++) {
          k = num[i]
          if (!(k in sel)) continue
          if (pre[k] == "-" || pre[k] == "") continue
          m = split(pre[k], part, ",")
          for (j = 1; j <= m; j++) {
            p = part[j]
            if (!(p in tier)) continue        # not a candidate row -> not promotable
            if (!(p in sel)) { sel[p] = 1; changed = 1 }
          }
        }
      } while (changed)
      # prune: drop anything still holding a prerequisite that will not be promoted, and record why
      do {
        changed = 0
        for (i = 1; i <= n; i++) {
          k = num[i]
          if (!(k in sel)) continue
          if (pre[k] == "-" || pre[k] == "") continue
          m = split(pre[k], part, ",")
          for (j = 1; j <= m; j++) {
            p = part[j]
            if (!(p in sel)) { delete sel[k]; why[k] = p; changed = 1; break }
          }
        }
      } while (changed)
      for (i = 1; i <= n; i++) {
        k = num[i]
        if (k in sel)      print "sel\t" k
        else if (k in why) print "drop\t" k "\t" why[k]
      }
    }' 2>/dev/null \
    || die "compose-select: could not process the candidate slate"
  return 0
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
    release-command)  cmd_release_command "$@" ;;
    deps-from-body)   cmd_deps_from_body "$@" ;;
    decisions)        cmd_decisions "$@" ;;
    open-issues)      cmd_open_issues "$@" ;;
    read-complete)    cmd_read_complete "$@" ;;
    compose-candidates) cmd_compose_candidates "$@" ;;
    compose-select)   cmd_compose_select "$@" ;;
    *) printf 'roadmap-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
