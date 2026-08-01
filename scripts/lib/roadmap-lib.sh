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
#   roadmap-lib.sh deps-ambiguous [self-issue-number]             # issue/decision body on stdin
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
# A MIXED-VERSION install is what this probe is for. `install.sh` symlinks the whole scripts/lib
# directory, so the two files always travel together — but a workstation can still be pointing at
# an older checkout, and then the sourced library simply has no `_ADB_MD_AWK` in it. Under `set -u`
# that expansion aborts the shell with status 1, which every caller here reads as a trustworthy
# NEGATIVE. Every hard error in this library is 2 ("do not trust this answer"), so a missing helper
# has to be 2 too — the same symbol probe role-dispatch.sh applies to the TOML readers.
if [ -z "${_ADB_MD_AWK:-}" ] || ! command -v adb_md_prose >/dev/null 2>&1; then
  printf 'roadmap-lib: FATAL — %s is missing the shared markdown filter (_ADB_MD_AWK/adb_md_prose)\n' "$_adb_rm_common" >&2
  exit 2
fi

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

  # --- ONLY PROSE TARGETS (#130/#136) ---------------------------------  # adb-claim-ok: #130 is closed NOT_PLANNED, superseded by #136
  # This predicate used to be the deliberate exception to the structure rule ("jq over GitHub's own
  # computed link set, a different language answering a different question"), and that exception was
  # the bug. Its SECOND half is not GitHub's link set at all — it is a keyword scan over prose an
  # author wrote — so `Closes #42` inside a fenced repro, an HTML comment, a blockquote, a code span
  # or an indented block all read as "this PR targets #42", and /roadmap withheld a ready issue from
  # every bundle. Verified in all five shapes.
  #
  # EACH BODY IS FILTERED ON ITS OWN. The filter carries cross-line state (an unterminated fence or
  # comment swallows to end of input), so concatenating the array would let one PR's stray ``` blind
  # the scan for every PR after it — a fail-open across records.
  #
  # FAIL-CLOSED, per the `rc>1 -> die` band this predicate already keeps: a filter that cannot run,
  # or that is cut short, must never reach jq as a shorter body and answer a clean "not targeted".
  # `adb_md_prose` returns nonzero on both, and each failure here is `die` (exit 2), never 1.
  #
  # `mask`, not a deleting filter, and that is a correctness requirement rather than a taste. Delete
  # a span and its neighbours FUSE: `` clo`x`ses #42 `` becomes `closes #42`, and this predicate
  # then freezes a ready issue on a keyword the author never wrote. Masking to \x01 — the same byte
  # `deps-from-body` masks with, for the same reason — leaves a boundary the keyword cannot cross.
  #
  # The LINKED-ISSUE half below is untouched, because it is genuinely GitHub's own computed set and
  # has no markdown in it. Only `.body` is replaced.
  local cnt idx body prose
  # SHAPE-VALIDATE EVERY MEMBER, not just the top level. `jq -r '.[$i].body'` stringifies a number
  # or an object without complaining, and `any(...)` over a non-array `closingIssuesReferences`
  # yields an empty generator rather than raising — so a malformed PR object answered a clean
  # "not targeted" (1) instead of "cannot answer" (2). That is the fail-open this predicate exists
  # to prevent, reached by a different door than the malformed-JSON one.
  cnt="$(printf '%s' "$json" | jq '
      if type != "array" then error("not an array") else . end
      | if any(.[]; type != "object") then error("member is not an object") else . end
      | if any(.[]; .body != null and (.body | type) != "string") then error("body is not a string") else . end
      | if any(.[]; .closingIssuesReferences != null and (.closingIssuesReferences | type) != "array")
        then error("closingIssuesReferences is not an array") else . end
      | if any(.[]; (.closingIssuesReferences // [])[] | type != "object") then error("reference is not an object") else . end
      | length' 2>/dev/null)" \
    || die "pr-targets-issue: could not parse PR JSON (malformed input, not a JSON array, or a malformed PR object)"
  idx=0
  while [ "$idx" -lt "$cnt" ]; do
    body="$(printf '%s' "$json" | jq -r --argjson i "$idx" '.[$i].body // ""' 2>/dev/null)" \
      || die "pr-targets-issue: could not read the body of PR index $idx"
    prose="$(printf '%s' "$body" | adb_md_prose mask)" \
      || die "pr-targets-issue: the markdown prose filter failed on PR index $idx (refusing to scan an unfiltered body)"
    json="$(printf '%s' "$json" | jq -c --argjson i "$idx" --arg b "$prose" '.[$i].body = $b' 2>/dev/null)" \
      || die "pr-targets-issue: could not rewrite the body of PR index $idx"
    idx=$((idx + 1))
  done

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
  # fenced blocks, blockquotes, indented blocks, and inline code spans.
  #
  # Why it is needed at all: the artifact schema documents the marker BY EXAMPLE, and every body
  # bootstrapped by an earlier version carries `<!-- release-command: /release -->` in its OPTIONAL
  # comment block. Its shape is identical to a real declaration, so no value-based carve-out can
  # tell them apart — `release` is a perfectly legitimate thing to declare. What distinguishes them
  # is MARKUP: the example sits in a code span or a fence; a declaration does not.
  #
  # TWO VALUE FILTERS BELOW, and they answer different questions. The mask-byte one drops a value a
  # SPAN swallowed from outside the comment. The backtick one drops a value carrying backticks of
  # its own — a skill can never be named that, and before the shared filter existed the blanket
  # span-deletion emptied such a value, so this keeps that verdict rather than newly admitting one.
  # `--keep-comments` is the whole reason the shared filter takes that flag (#136). This marker IS
  # an HTML comment, so the filter's comment-stripping half has to be off — which used to be stated
  # here as "the shared filter cannot be reused", above a fourth private fence detector that knew
  # nothing about run lengths, info strings, container columns or CRLF. `mask` replaces a quoted
  # example's bytes with \x01, so its `<!--` can never reach `grep -o`; the `grep -v` below then
  # drops a value that was itself partly quoted, which is not a declaration either. A filter failure
  # is a nonzero return, never a silent empty read.
  # FILTER, THEN PIPE — two statements, never one. `filter || die | grep` parses as
  # `filter || (die | grep)`, so the guard would run INSIDE the pipeline and the failure would be
  # read as "no marker declared": a fail-open on the exact path this guard exists to close.
  local prose
  prose="$(adb_md_prose mask --keep-comments)" \
    || die "release-command: the markdown prose filter failed (refusing to read an unfiltered body)"
  printf '%s' "$prose" \
    | grep -o '<!--[[:space:]]*release-command:[[:space:]]*[^>]*-->' \
    | sed 's/.*release-command:[[:space:]]*//; s/-->$//; s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | LC_ALL=C grep -v "$_ADB_MD_MASKC" \
    | LC_ALL=C grep -v '`' \
    | sed 's/^[/$]//' \
    | grep -vx 'your-skill' \
    | grep -vx 'your-release-skill' \
    | grep -vx 'CMD' \
    | sort -u
  return 0
}

cmd_marker_title() {
  [ "$#" -eq 0 ] || die "marker-title: takes no arguments (roadmap artifact body on stdin)"
  # ONLY PROSE DECLARES, here too (#136). This marker had NO structure filter at all, so a fenced
  # or code-spanned EXAMPLE of `<!-- release-milestone: … -->` was read as a real declaration — and
  # because two distinct titles make the artifact ambiguous, a documented example could refuse a
  # perfectly good artifact. The `NAME` carve-out below is a value-based patch over that same hole;
  # it stays for the placeholder, but markup is what actually distinguishes the two.
  local prose
  prose="$(adb_md_prose mask --keep-comments)" \
    || die "marker-title: the markdown prose filter failed (refusing to read an unfiltered body)"
  # `grep -o` (one match per LINE OF OUTPUT), not `sed s///p` (one substitution per line of
  # INPUT): two markers on a single line must surface as two titles, so the caller can refuse an
  # ambiguous artifact. With sed, the leading `.*` is greedy and silently keeps only the last.
  printf '%s' "$prose" \
    | grep -o '<!--[[:space:]]*release-milestone:[[:space:]]*[^>]*-->' \
    | sed 's/.*release-milestone:[[:space:]]*//; s/-->$//; s/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | LC_ALL=C grep -v "$_ADB_MD_MASKC" \
    | grep -vx 'NAME' \
    | sort -u
  return 0
}

# --- markdown structure: this library's use of the ONE shared filter (#136, was #117) ---------
# The filter itself lives in common.sh (`_ADB_MD_AWK`) — see its header for the model, the two
# views, and why it buffers. This note records only what THIS library asks of it.
#
# Every body-reading subcommand here goes through it, and that is the point of #136: this repo kept
# fixing one bug family one instance at a time (#69 a bare `#N`, #108 a NEGATED mention, #117 a
# mention inside a repro block, #135 a fence inside a list item), and each fix landed in whichever
# consumer happened to get reported. Five consumers, one rule:
#   - `deps-from-body`  a `Depends on #N` inside a fence/comment/blockquote/indented block declares
#                       nothing. Uses MD_TEXT *and* MD_MASK: the KEYWORD is matched against the
#                       masked copy so a quoted clause cannot declare, while the `#N` is read from
#                       the raw copy so `` Depends on `#52` `` still does (#112).  # adb-claim-ok: #112's own example form, quoted
#   - `decisions`       a `| … |` row inside one is not a recorded owner decision, and a `#` line
#                       inside one does not end the section. That second case is #108 exactly — a
#                       real decision going unseen means the question re-asks on every run.
#   - `release-command` and `marker-title` — the MASK view with comments KEPT, because for these two the
#                       declaration IS an HTML comment and what separates it from the schema's own
#                       documented example is markup, never the value.
#   - `pr-targets-issue` sanitizes each PR body before the closing-keyword scan (#130). It used to  # adb-claim-ok: #130 is closed NOT_PLANNED, superseded by #136
#                       be the deliberate exception ("jq over GitHub's own link set, a different
#                       language"), and that exception was the bug: a `Closes #42` inside a fence,
#                       comment, blockquote, span or indented block froze a ready issue.

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
#     The tolerance is deliberately NOT a blanket "skip punctuation" — the STEP block in BEGIN
#     states the grammar and the counterexamples it refuses. What it does NOT cover:
#     emphasis INSIDE the keyword (`Depends **on** #5`), a markdown link (`Depends on [#5](url)`),
#     and HTML emphasis (`<b>#5</b>`), all of which still declare nothing.
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
#   - INDENTED CODE, AT TOP LEVEL ONLY (D27). A line indented >= 4 spaces opens a code block only
#     when no paragraph and no list container is open. Both guards matter: `    Depends on #52` is  # adb-claim-ok: D27/#136s own repro spelling, quoted
#     byte-identical at top level and as a continuation under a `- ` bullet, where CommonMark puts
#     content at column 2 and code therefore needs six. A stateless `^ {4}` skip would delete
#     ordinary continuation PROSE, and that direction is the dangerous one — a dropped edge
#     silently unblocks a bundle that is genuinely blocked. A leading TAB is not indentation here,
#     for the same reason.
#
# The artifact's `## Decisions` rows are fed through this SAME subcommand, so an owner decision
# declares (or retires) an edge with exactly the vocabulary an issue body uses — one rule, one
# implementation, one test. This is the ONLY edge extractor; `pr-targets-issue` answers a
# different question (GitHub CLOSING keywords in a PR body) and deliberately does not share it.
#
# --- deps-ambiguous: the SAME scan, reporting what it REFUSED (#132) ---------------------------
# Every fix in this family resolved an ambiguity by picking a side SILENTLY, so /roadmap could not
# tell "this body declares no edge" from "this body declares an edge I could not parse". The two
# are opposite facts and they produced identical output. `deps-ambiguous` is the second view of
# this one scan, and the sharing is the point: a report computed by a SECOND parser would drift
# from the grammar it is reporting on at the first change to either.
#
# WHY A SIBLING SUBCOMMAND, and not the three alternatives the issue lists. Its own constraints
# eliminate them: stdout must stay a bare list of numbers, so a `?`-prefixed line would corrupt
# every numeric consumer; every caller treats non-zero as a hard stop, so an exit code would turn
# a parse note into a run-ending error; and stderr is outside the workflow output contract and is
# where this library already puts real failures. What is left is a second subcommand over the same
# body — additive, so no existing caller changes at all. Recorded as D28.
#
# WHAT IS AMBIGUOUS, exactly — the closed grammar, which is the whole false-positive budget.
# Report what the grammar REFUSED; never what it RECOGNIZED and correctly excluded. A report on
# every body that merely mentions an issue number is noise, and noise gets ignored, which is worse
# than silence. So a site is reported only when a DECLARING (non-negated) keyword occurrence is
# present in prose, and then:
#   - `partial`  — that occurrence declared >= 1 edge, and an UNQUALIFIED `#M` was left unconsumed
#                  in its window. `Depends on #5 (the gate) and #6` yields 5 and drops 6.
#   - `unparsed` — that occurrence declared NO edge, and an unqualified `#M` sits in its window.
#                  `Depends on [#5](url)`, `Depends on * #5`, `Depends on the gate and #6`.
#   - `no-hash`  — no edge, no `#M` at all, but the author wrote `issue <N>`. That is the ONLY
#                  hash-less shape reported: `Depends on 2 things` is English, not a reference.
# A QUALIFIED reference is silent on purpose. `Depends on acme/repo#5` is not a failure to parse —
# the "reach `#` without crossing a word character" rule IS the cross-repo guard, and it answered
# correctly. Reporting a confident answer as an ambiguity is what turns this into noise.
#
# THE WINDOW is per keyword occurrence and stops at the NEXT keyword on the line. Without it the
# two commonest real lines both false-fire: `Depends on #5 and blocked by #6` would report 6 as
# dropped when the second keyword is about to claim it, and `Depends on #78; it is not blocked by
# #25` would report 25 when the author explicitly retired it. A negated occurrence is skipped  # adb-claim-ok: illustrative clause reusing this librarys standing #25 negation example
# whole — negation is a CONFIDENT answer, not an ambiguity.
#
# THE REPORT CARRIES NO BODY TEXT, and that is a containment decision, not brevity. Issue bodies
# are third-party (`base/practices/untrusted-content.md`) and this output is rendered into the
# roadmap artifact, so echoing a source line would carry arbitrary markup — table delimiters,
# directives, credential-shaped strings — into a tracked document. All three fields come from
# closed sets instead: a kind from the three above, a line NUMBER, and an issue NUMBER. There is
# no byte of author-controlled text in the output at all, so there is nothing to sanitize.
#
# IT WARNS; IT DOES NOT GATE. Nothing here feeds a bundle status: /roadmap renders a report as a
# Reconcile-flags row and a retirable `dep-ambiguous:#N` owner question, exactly as #78 renders an
# unmilestoned release-blocker as a `WARN:` rather than a `HOLD`. Blocking on uncertainty would let
# one false positive stall a ready bundle indefinitely, and the reversal — should the owner want a
# hold — is a status rule in the workflow, not a change to this contract.
#
# NOT A PARSER WIDENING. None of these shapes becomes an edge. `deps-from-body`s stdout is
# byte-identical before and after this change, which is what lets the report be added without
# re-testing every consumer.

# _adb_deps_scan <mode> <self> — the one scan; <mode> is `edges` or `ambiguous`. Body on stdin.
# Callers CAPTURE it rather than piping it, so awk failing is a non-zero status they can see. A
# `awk | sort` pipeline reports only sort, which is how a crashed scan would arrive as a clean
# empty result — the exact fail-open this library exists to refuse (header, "EXIT STATUS IS
# FAIL-CLOSED").
_adb_deps_scan() {
  # LC_ALL=C keeps the byte-wise scan below predictable on a body containing multibyte text; the
  # two dash characters are normalized by literal string replacement rather than a bracket
  # expression, which is exactly what a byte-oriented locale cannot express safely.
  LC_ALL=C awk -v self="$2" -v mode="$1" "$_ADB_MD_AWK"'
    # Literal (never regex) replace-all, so a dash normalization cannot be re-interpreted.
    function lreplace(s, from, to,   out, p) {
      out = ""
      while ((p = index(s, from)) > 0) {
        out = out substr(s, 1, p - 1) to
        s = substr(s, p + length(from))
      }
      return out s
    }
    # THE TWO ALIGNED VIEWS, which is what makes the code-span rule TARGETED rather than blanket.
    # The shared filter hands back MD_TEXT[i] and a byte-for-byte length-matched MD_MASK[i] whose
    # resolved spans are \x01. The KEYWORD is matched against the masked copy, so a whole clause
    # quoted as an example (`` `Depends on #5` ``) declares nothing; the REFERENCE is read from the
    # raw copy, so `` Depends on `#5` `` still declares. Blanket span-stripping would delete the
    # reference outright and put those two rules in direct conflict.
    #
    # NO APOSTROPHE ANYWHERE IN THIS PROGRAM. It is a single-quoted shell string, so one would close
    # the quote and awk source would reach bash as commands — which is why the BEGIN block below
    # builds one with sprintf rather than writing it. A comment is not exempt from that.
    #
    # Advance BOTH copies by the same offset. The 1:1 length invariant is what lets an offset found
    # in one index the other, so consuming them is a single operation with one home — not a
    # convention two call sites have to remember.
    function eat(at) { rest = substr(rest, at); masked = substr(masked, at) }
    # emit <kind> <line> <issue> — one ambiguity record, deduped, in scan order (line ascending,
    # then keyword occurrence, then reference order). Deterministic by construction, so no sort is
    # needed and none is applied; a sort would have to know the field types anyway.
    function emit(kind, ln, n,   key) {
      key = kind "\t" ln "\t" n
      if (key in SEEN) return
      SEEN[key] = 1
      print key
    }
    # report <line> <edges-declared-here> <window> — classify what this keyword occurrence left
    # behind. See the WHAT IS AMBIGUOUS block in the shell comment above for why each shape is in
    # or out; this function is only the mechanism.
    function report(ln, nemit, win,   at, len, pre, num, n2, seg, found) {
      found = 0
      # UNQUALIFIED references left in the window. `#` preceded by a WORD character is a qualified
      # reference (acme/repo#5) — recognized and correctly excluded, so never reported.
      while (match(win, /#[0-9]+/)) {
        at = RSTART; len = RLENGTH
        pre = (at > 1) ? substr(win, at - 1, 1) : " "
        num = substr(win, at + 1, len - 1)
        win = substr(win, at + len)
        if (pre ~ /[a-z0-9_]/) continue
        if (length(num) > 9) continue          # same width bound the edge scan applies
        n2 = num + 0
        if (n2 <= 0 || n2 == self) continue
        emit((nemit > 0) ? "partial" : "unparsed", ln, n2)
        found = 1
      }
      if (found || nemit > 0) return
      # The one hash-less shape that is reported: the author wrote out `issue <N>`. Anything
      # looser turns "Depends on 2 things" into a finding.
      if (!match(win, /(^|[^a-z0-9_])issues?[ \t]+[0-9]+/)) return
      seg = substr(win, RSTART, RLENGTH)
      if (!match(seg, /[0-9]+$/)) return
      num = substr(seg, RSTART, RLENGTH)
      if (length(num) > 9) return
      n2 = num + 0
      if (n2 > 0 && n2 != self) emit("no-hash", ln, n2)
    }
    BEGIN {
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
      #
      # PAIRING IS DELIBERATELY NOT CHECKED, and that is a decision, not an omission. A first cut
      # required an opener to reappear after the digits, so `Depends on **#5` declared nothing. It
      # was wrong twice over. It dropped `Depends on **#5, #6**` down to `6` — the closer follows
      # the LAST chain member, not the first, so the opener went unmatched and the scan resumed
      # INSIDE the text it had just rejected. And what it bought was refusing malformed markup
      # whose edge is real anyway: an author who writes `Depends on **#5` does depend on #5.
      # Under-match is the direction that marks a blocked bundle `ready`, so a rule that trades
      # real edges for tidiness is on the wrong side of it. Balance is also not expressible in
      # `STEP` at all — POSIX ERE has no backreference — so enforcing it means a second mechanism
      # scanning the same bytes, which is what produced the chain bug. What actually keeps the
      # widening safe is the tightness above: `#` must still be reached without crossing a WORD
      # character, so `` Depends on `ignore #5` ``, `Depends on [#5](url)` and
      # `Depends on **acme/repo#5**` all declare nothing.
      STEP = "^" EMR "[ \t]*((:|,|;|&|\\+|and)" EMR ")?[ \t]*" EMR "#[0-9]+"
    }
    { MDL[++MDN] = $0 }
    END {
      # STRUCTURE FIRST (#117/#136) — the whole body is resolved before a single keyword is looked
      # for, so lowercasing, dash normalization, clause/negation analysis and chain parsing never
      # see text the markup marked as quoted or illustrative.
      adb_md_run()
      for (ln = 1; ln <= MDN; ln++) {
        if (MD_SKIP[ln]) continue
        # ONE LINE PER EDGE is preserved deliberately. The filter buffers a PARAGRAPH to pair code
        # spans across a line ending, then hands the lines back separately — the scan below still
        # runs per line, so `Depends on\n#5` declares nothing, exactly as before.
        rest = tolower(MD_TEXT[ln])
        # CHEAP NECESSARY CONDITION, before any rewriting. Every alternative of KW begins `depend` or
        # `blocked`, and the dash normalization below cannot create or destroy those prefixes. Bailing
        # here skips the scan on the ~90% of body lines that can never match.
        if (rest !~ /depend|blocked/) continue
        masked = tolower(MD_MASK[ln])
        # Normalize the dashes that also end a clause (em/en) to a boundary char — LENGTH-PRESERVING,
        # a 3-byte sequence for 3 characters. `masked` is not rewritten at all, so the two copies stay
        # 1:1 only because this substitution cannot shift an offset. A bare "." would shorten `rest`
        # by two bytes per dash and silently slide every keyword offset past its own text.
        rest = lreplace(rest, "\342\200\224", ".  ")
        rest = lreplace(rest, "\342\200\223", ".  ")
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
          nemit = 0
          while (match(rest, STEP)) {
            step = substr(rest, RSTART, RLENGTH)
            eat(RSTART + RLENGTH)
            h = index(step, "#")
            digits = substr(step, h + 1)
            # Bound the width BEFORE the numeric conversion. A run wider than an issue number is
            # not an issue reference, and converting it would leave awk holding a float that prints
            # in exponent/rounded form — emitting a fabricated "issue number" no tracker can have.
            if (length(digits) > 9) continue
            n = digits + 0
            if (n > 0 && n != self) { nemit++; if (mode == "edges") print n }
          }
          if (mode != "ambiguous") continue
          # THE WINDOW ends at the NEXT keyword on this line, so a reference the next keyword is
          # about to claim is never reported as dropped. `masked` and `rest` stay 1:1, which is
          # what lets an offset found in one slice the other; the outer loop re-matches anyway,
          # so consuming RSTART here costs nothing.
          window = rest
          if (match(masked, KW)) window = substr(rest, 1, RSTART - 1)
          # ...and at the first CLAUSE BOUNDARY, the same set the negation scoping above uses (with
          # em/en dashes already normalized to one). A declaration cannot cross a sentence boundary
          # and the chain grammar already refuses to, so a reference past one is commentary, not a
          # dropped edge. Measured, not assumed: without this the report fired 13 times on this
          # repo and ALL THIRTEEN were of that shape — `- #81 depends on #79 — **satisfied**, #79
          # closed COMPLETED (PR #111)` reported both the edge it had just declared and a PR
          # number, and `**Why it is blocked on this issue.** #123 rejects...` reported the first  # adb-claim-ok: quotes #141s body verbatim as the measured witness
          # word of the next sentence. With it, the corpus is silent.
          wcut = 0
          for (wi = 1; wi <= length(window); wi++) {
            wc = substr(window, wi, 1)
            if (wc == "." || wc == ";" || wc == ":" || wc == "!" || wc == "?") { wcut = wi; break }
          }
          if (wcut > 0) window = substr(window, 1, wcut - 1)
          report(ln, nemit, window)
        }
      }
    }
  '
}

cmd_deps_from_body() {
  case "$#" in
    0|1) : ;;
    *) die "deps-from-body: takes at most one argument: [self-issue-number] (body on stdin)" ;;
  esac
  local self="${1:-0}" out
  [ -n "$self" ] || self=0
  is_uint "$self" || die "deps-from-body: <self-issue-number> must be a non-negative integer (got '$1')"

  # CAPTURE, then sort. `awk | sort` reports only sort, so a crashed scan would arrive as a clean
  # empty result — which for this predicate means "this body declares no edges" and silently
  # unblocks a bundle that is genuinely blocked.
  out="$(_adb_deps_scan edges "$self")" || die "deps-from-body: the markdown scan failed"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sort -n -u
}

# --- deps-ambiguous ---------------------------------------------------------------------------
# Print one record per site where a body PLAUSIBLY ATTEMPTED a declaration that `deps-from-body`
# could not confidently attribute (#132). TSV, `<kind>\t<line>\t<issue-number>`; empty output means
# nothing was ambiguous, which is the ordinary result and never an error.
#
# The rules, the closed kind vocabulary, the window, the qualified-reference carve-out and the
# no-body-text containment decision are documented ONCE above `_adb_deps_scan` — this is the same
# scan under a different mode, so restating them here is the drift the sharing exists to prevent.
#
# EXIT STATUS matches `deps-from-body` deliberately: 0 with empty output for "nothing to report",
# 2 for a broken input. It is NOT the 0/1/2 predicate shape, because every caller of the sibling
# subcommand treats non-zero as a hard stop, and a 1 meaning "no ambiguity" would hard-stop a run
# on its most common outcome.
cmd_deps_ambiguous() {
  case "$#" in
    0|1) : ;;
    *) die "deps-ambiguous: takes at most one argument: [self-issue-number] (body on stdin)" ;;
  esac
  local self="${1:-0}" out
  [ -n "$self" ] || self=0
  is_uint "$self" || die "deps-ambiguous: <self-issue-number> must be a non-negative integer (got '$1')"

  out="$(_adb_deps_scan ambiguous "$self")" || die "deps-ambiguous: the markdown scan failed"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
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
  LC_ALL=C awk "$_ADB_MD_AWK"'
    # Structure first (#117/#136), through the SAME filter deps-from-body uses. Two bugs live here
    # without it, both on a document that ships fenced examples and an HTML comment INSIDE this
    # very section: a `| … |` row quoted in a fence would retire an owner question nobody
    # answered, and a `#` line quoted in one would end the section early — hiding every real
    # decision after it, which is #108 returning by another route.
    #
    # MD_TEXT, never MD_MASK: a question id is routinely written as `` `q-1` `` by hand, and the
    # cell strips its own backticks below. Deleting span CONTENT here would erase the id itself.
    { MDL[++MDN] = $0 }
    END {
      adb_md_run()
      for (ln = 1; ln <= MDN; ln++) {
        if (MD_SKIP[ln]) continue
        line = MD_TEXT[ln]
        # Any heading ends the section; the Decisions heading (only) starts it.
        if (line ~ /^[[:space:]]*#/) {
          inside = (tolower(line) ~ /^[[:space:]]*##[[:space:]]+decisions[[:space:]]*$/)
          continue
        }
        if (!inside) continue
        if (line !~ /^[[:space:]]*\|/) continue
        row = line
        sub(/^[[:space:]]*\|/, "", row)
        p = index(row, "|")
        cell = (p > 0) ? substr(row, 1, p - 1) : row
        gsub(/`/, "", cell)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
        if (cell == "") continue
        if (tolower(cell) == "question") continue      # the header row
        if (cell ~ /^[-:]+$/) continue                 # the |---|---| separator row
        print cell
      }
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
    deps-ambiguous)   cmd_deps_ambiguous "$@" ;;
    decisions)        cmd_decisions "$@" ;;
    open-issues)      cmd_open_issues "$@" ;;
    read-complete)    cmd_read_complete "$@" ;;
    compose-candidates) cmd_compose_candidates "$@" ;;
    compose-select)   cmd_compose_select "$@" ;;
    *) printf 'roadmap-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
