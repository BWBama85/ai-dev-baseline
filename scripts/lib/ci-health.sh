#!/usr/bin/env bash
# ai-dev-baseline — did this CI run actually EXECUTE? (issue #300)
#
# `base/practices/ci-discipline.md` used to model every CI failure as exactly one of two things,
# flaky, or real. A third class exists: THE JOB NEVER RAN. A platform outage, an unacquired runner,
# a cancelled queue. Zero steps executed, no code was touched, and the red carries no information
# about the diff at all.
#
# Measured, on `BWBama85/thewilsonnet` during the 2026-08-06 GitHub Actions `major_outage`: run
# 31126981959 concluded `failure` after 1h46m with ONE job, conclusion `cancelled`, `steps: []`, and
# the annotation "The job was not acquired by Runner of type hosted even after multiple attempts".
# There is no failure log to read, so that protocol's "read the failure log" step was unexecutable
# and its "classify" step offered two boxes, neither of which fits. Both wrong answers were live:
# debugging your own diff against a run that executed zero lines, and filing a de-flake issue that
# `issues-and-scope.md` forbids (nobody does it; nothing in the repo breaks if nobody ever does).
#
# This module is the classification, as a tested command rather than a fourth paragraph of prose —
# the same move that turned the dependency-edge rule, the release-readiness ladder and `/cleanup`'s
# predicates from remembered rules into code.
#
# WHY A SEPARATE MODULE, and not an arm of something that already exists. Both candidates were
# examined and both are charter violations:
#
#   * `roadmap-lib.sh branch-health` asks a DIFFERENT question — "is this branch green at this
#     commit?" — and answers it by aggregating every Checks API result and commit status attached to
#     one SHA, deliberately never selecting a workflow run. It is also PURE by contract ("never call
#     gh"), so a `--run <id>` arm that reads live state would break the property its whole test
#     suite is built on.
#   * `repo-settings.sh` states its own boundary: "it is repo *settings* bookkeeping." A per-run
#     question is not a repo setting, which is exactly the argument `pr-review.sh` (#134) made for
#     not folding the per-PR review question in there either. This is the same shape a third time.
#
# WHAT THIS MODULE MUST NEVER GROW: it does not re-run, retry, poll, wait, cancel, publish a commit
# status, or read a provider status page (see "PROVIDER STATUS" below). It classifies one run and
# returns.
#
# Usage:
#   ci-health.sh classify --run <id> [--repo <owner/repo>] [--queued-threshold <secs>]
#                                    [--no-annotations]
#                                      # live: read the run + its jobs, then classify
#   ci-health.sh classify-doc            # PURE: the assembled document on stdin, no network
#   ci-health.sh -h | --help
#
# STDOUT is two lines, the same shape `branch-health` uses: the verdict word on line 1, a one-line
# reason on line 2. Advice for a human goes to stderr, so a caller can consume stdout unchanged.
#
# EXIT CODES are a stable machine contract:
#   0  green      — the run concluded `success` (or `skipped`/`neutral`, which is how GitHub itself
#                   scores a non-failing required check).
#   22 failed     — REAL. At least one non-passing job executed at least one step, so a log exists
#                   and the ordinary diagnose-the-diff protocol applies.
#   23 never-ran  — The run concluded non-passing and NOT ONE non-passing job executed a single
#                   step. Do not debug the diff; there is no log and nothing in it to diagnose. Do
#                   not file a de-flake issue; there is no test to de-flake. Note what this does
#                   NOT say: it does not say the PROVIDER failed. A manual cancellation, a
#                   concurrency-group cancellation, a superseded run and a self-hosted runner
#                   nobody started all produce identical evidence. "It did not run" is proven;
#                   "it will clear on its own" is a guess, and the stderr advice says so.
#   24 queued     — the run has NOT STARTED and has been queued for at least <queued-threshold>
#                   seconds. Nothing has executed, so there is nothing to diagnose yet.
#   25 pending    — the run has not concluded and is not overdue: in progress, or queued under the
#                   threshold. A legitimate "ask again later", NOT an error.
#   20 unknown    — the state could not be established: an unreadable response, a truncated job
#                   list, or a shape no arm describes. FAIL CLOSED — see below.
#   2  usage      — bad or missing arguments.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is answering `never-ran` when a job that DID NOT
# PASS executed a step. That is the flattering answer — it says the red is not your fault — and it
# is the one that ships a real failure past a human who stopped reading. So `never-ran` is returned
# only from POSITIVE evidence that every non-passing job carries an explicit, empty `steps` array,
# and every uncertainty resolves to 20. `verify-before-asserting.md` states the rule.
#
# THE INVARIANT IS SCOPED TO NON-PASSING JOBS, NOT TO THE RUN, and that scoping is deliberate rather
# than a weakening. It first read "never-ran must never be returned for a run that DID execute",
# which is a claim this module does not make and should not: a run whose successful shard executed
# fully beside a cancelled shard that never started has still produced a failure with NO LOG, and
# the right advice for it is this one. What would be wrong is the SENTENCE, so the reason line
# reports how many other jobs did run rather than implying none did. (Independent review found the
# over-broad wording by constructing exactly that document.)
#
# A FOURTH EXIT-CODE VOCABULARY, and that is the repo's model rather than a slip. D51 records it —
# "the existing unreadable code (20) is not a repo-wide fact" — and `pr-watch.sh` states it outright
# for the family ("do not unify them by assuming a shared meaning"). Given that freedom, these
# numbers are still chosen NOT to collide with any sibling: `automerge-ok` owns 10-14, `merge-flag`
# owns 15, `pr-review gate` owns 16-19 and 21, so this module starts at 22. Nothing composes them
# today, and picking free numbers costs nothing while making a future caller that branches on two of
# them impossible to get quietly wrong. `20` (unreadable, fail closed) and `2` (usage) deliberately
# DO match the family, because those two meanings are shared by every module in it.
#
# PROVIDER STATUS IS DELIBERATELY NOT READ. `githubstatus.com` reports what is happening NOW, and
# this classifies a run that concluded in the past — a green status page hours later says nothing
# about whether a runner was acquired at 19:34Z, and a red one would let a current incident relabel
# an unrelated historical failure as infrastructure. That is precisely the fail-open direction the
# paragraph above forbids. The verdict therefore rests only on evidence about THIS run; the reason
# line points a human at the status page, which is where that check belongs.
#
# ONE ATTEMPT, AND THE READS ARE ANCHORED TO IT. The run object reports the latest attempt, and the
# jobs are then read from `/attempts/<that number>/jobs` rather than from the plain `/jobs`
# endpoint. That is not tidiness: `/jobs` defaults to `filter=latest`, which is a MOVING target, so
# a re-run landing between the two calls pairs attempt N's run object with attempt N+1's job list —
# and a freshly started attempt's jobs are, for a few seconds, exactly the empty-step shape that
# means `never-ran`. An executed, genuinely failed attempt would be reported as infrastructure.
# Caught by independent review. A run reporting no usable `run_attempt` is 20, because the fallback
# of "use the moving endpoint anyway" is that same race arriving through the error path. The reason
# line prints `attempt N`, so which one was classified is visible rather than assumed.
#
# Requires: gh (authenticated) and jq for `classify`; jq only for `classify-doc`.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_ch_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_ch_common="$_adb_ch_libdir/common.sh"
if [ ! -f "$_adb_ch_common" ]; then
  printf 'ci-health: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_ch_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_ch_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the caller
# is the entry point that owns the gate; re-exec'ing someone else's script from inside a library is
# not this file's decision to make. An `if`, never `[ … ] && …`: the compound form returns non-zero
# on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() { adb_usage "$0"; }

# The default queue threshold, in seconds. 30 minutes, and deliberately generous: a CONCURRENCY
# GROUP can legitimately hold a run for hours, so a short threshold would report "overdue" for a
# repo that is merely busy — and `queued` is one of the two verdicts a reader will hear as "not my
# fault". Being late to notice an outage costs one more look at the status page; being early costs
# the credibility of the whole classification.
ADB_CI_QUEUED_THRESHOLD_DEFAULT=1800

OPT_RUN=""
OPT_REPO=""
OPT_THRESHOLD="$ADB_CI_QUEUED_THRESHOLD_DEFAULT"
OPT_ANNOTATIONS=1

# --- the decision ------------------------------------------------------------------------------
# ONE home for the truth table. `classify` assembles the document from live reads and hands it here;
# `classify-doc` takes the same document on stdin. Neither re-derives a rule the other applies, so a
# fixture that pins this function pins the live path too.
#
# The document (ALL of `run`, `jobs`, `now`, `queued_threshold_secs` are REQUIRED — a missing key is
# an ERROR, never an empty default, for the reason `branch-health` spells out at length: defaulting
# turns a truncated response into a confident verdict):
#
#   { "run":  { "status": "...", "conclusion": "..."|null, "created_at": "...",
#               "run_started_at": "..."?, "run_attempt": N?, "html_url": "..."? },
#     "jobs": { "total_count": N, "jobs": [ { "name": "...", "status": "...",
#                                             "conclusion": "..."|null, "steps": [ ... ] } ] },
#     "annotations": [ { "name": "<job name>", "messages": [ "..." ] } ]?,   # optional enrichment
#     "now": "YYYY-MM-DDTHH:MM:SSZ",
#     "queued_threshold_secs": N }
#
# `annotations` is OPTIONAL and never changes the verdict. It is enrichment for the reason line, and
# keeping it out of the decision is what lets the annotations read fail without weakening anything:
# `never-ran` is established by empty `steps` arrays that were read successfully, and an annotation
# only says WHY. A verdict that degraded when a third read failed would be fail-OPEN in the one
# arm this module must never be wrong about.
_ci_classify_doc() {
  local doc out
  command -v jq >/dev/null 2>&1 || { echo "ci-health: jq is required" >&2; return 20; }
  doc="$(cat)"
  # An EMPTY read is not a benign "nothing here" — it means the reads produced no document at all.
  case "$doc" in *[![:space:]]*) : ;; *)
    echo "ci-health: empty input (the run state could not be read)" >&2; return 20 ;;
  esac

  # ONE jq program decides, so the rules live in one place rather than being re-derived per caller.
  # NOTE: no apostrophe anywhere inside this program — it is a single-quoted shell string, and one
  # stray apostrophe closes it and turns the rest of the file into a syntax error.
  out="$(printf '%s' "$doc" | jq -r '
    # EVERY API-SUPPLIED STRING THAT REACHES THE REASON LINE GOES THROUGH `s1` FIRST. stdout is a
    # TWO-LINE contract — verdict on line 1, reason on line 2 — and a job name is the one field
    # here whose content this code does not control. A workflow may legitimately write
    # `name: >` with a folded block scalar, and GitHub returns the embedded newline verbatim: the
    # reason then spans three lines, a caller reading line 2 gets a truncated sentence, and a
    # caller reading line 3 gets a fragment of a job name where it expects nothing at all.
    # Found by self-review, reproduced with a name carrying a literal newline.
    def s1: tostring | gsub("[\\n\\r\\t]+"; " ");
    # A timestamp must LOOK like one before it is arithmetic. `fromdateiso8601` raises on a value it
    # cannot parse, which this function maps to a generic "malformed input" — fail-closed, but it
    # tells the operator nothing about WHICH field was wrong. Checking the shape first buys a
    # specific reason for the one class of malformation the API can realistically produce.
    def isinstant: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    if type != "object" then error("the document is not an object") else . end
    | if (has("run") | not) or (has("jobs") | not)
      then error("run and jobs are both required") else . end
    | if (has("now") | not) or (has("queued_threshold_secs") | not)
      then error("now and queued_threshold_secs are both required") else . end
    | .run  as $run
    | .jobs as $jobsdoc
    | if ($run | type) != "object" then error("run must be an object") else . end
    | if ($jobsdoc | type) != "object" then error("jobs must be an object") else . end
    | if ($jobsdoc | has("total_count") | not) or (($jobsdoc.total_count | type) != "number")
      then error("jobs.total_count is required and must be a number") else . end
    | if ($jobsdoc | has("jobs") | not) or (($jobsdoc.jobs | type) != "array")
      then error("jobs.jobs is required and must be an array") else . end
    | ($jobsdoc.jobs) as $jobs
    | (.annotations // []) as $anns
    | if ($anns | type) != "array" then error("annotations must be an array") else . end
    | ($run.run_attempt // 1) as $attempt
    | ($run.status // "") as $status
    | ($run.conclusion // null) as $concl

    # --- three guards that all say the same thing: MISSING EVIDENCE IS NOT EVIDENCE -------------
    # Every one of them protects the same arm. `never-ran` is decided by counting steps, and a step
    # count of zero is produced just as readily by a field that never arrived as by a runner that
    # never started. Each of these was a live fail-open, found by independent review.
    #
    # 1. A RUN WITH NO `status`. `($run.status // "")` fell through to the generic pending arm and
    #    returned 25 with the sentence "attempt 1 is " — a verdict, printed confidently, about a
    #    document that says nothing. Reproduced: `{run:{conclusion:null}, …}` -> 25.
    | if (($run.status // null) | ((type != "string") or (. == ""))) then
        "unknown\nthe run carries no status, so nothing about it can be established"
    # 2. A TRUNCATED JOB LIST. A page that never arrived contributes zero jobs and zero steps, which
    #    from here is indistinguishable from the platform having run nothing.
      elif ($jobsdoc.total_count) != ($jobs | length) then
        "unknown\nthe job list is incomplete (the API reports \($jobsdoc.total_count) job(s), \($jobs | length) were read) — refusing to classify a partial read"
      elif ($jobs | map(type != "object") | any) then
        "unknown\nthe job list carries a non-object entry, so what executed cannot be established"
    # 3. A JOB WITH NO `steps` ARRAY. This was the sharpest of the three: `(.steps // [])` read an
    #    ABSENT field, a `null`, or any non-array as "this job executed nothing" and returned 23 —
    #    manufacturing the module`s most consequential verdict out of a field that was never read.
    #    Reproduced with a completed failed job carrying no `steps` key at all.
      elif ($jobs | map((has("steps") | not) or ((.steps | type) != "array")) | any) then
        "unknown\nat least one job carries no readable steps array — a MISSING step list is not an EMPTY one, so what executed cannot be established"
      else

    # --- the run has NOT concluded ------------------------------------------------------------
    # Tested first, because `conclusion` is null here and every arm below reads it.
    if $status != "completed" then
      # WAITING FOR A RUNNER, versus RUNNING SLOWLY. Only a run that has not STARTED can be
      # overdue: a long `in_progress` build is a slow build, not an outage, and calling it one
      # would hand every heavy test suite the excuse this module exists to ration.
      ( if ($status | IN("queued","waiting","requested","pending")) then
          ( ($run.run_started_at // $run.created_at // null) ) as $since
          | if ($since | isinstant | not) then
              "unknown\nthe run has not started and carries no usable UTC timestamp to age it against"
            elif (.now | isinstant | not) then
              "unknown\nthe supplied clock is not a UTC instant, so the queue age cannot be computed"
            else
              ((.now | fromdateiso8601) - ($since | fromdateiso8601)) as $age
              # A NEGATIVE AGE IS A CONTRADICTION, NOT A YOUNG RUN. A run that claims to have
              # started after the current clock means the API and the clock disagree, and the
              # arithmetic below would report `-31527000s, under the threshold` — a confident
              # `pending` derived from nonsense. `adb_age_secs` in common.sh refuses a negative age
              # for the same reason; this is that rule, one layer in.
              | if $age < 0 then
                  "unknown\nthe run reports a start time in the future relative to the supplied clock, so its age cannot be trusted"
                elif $age >= .queued_threshold_secs then
                  "queued\nattempt \($attempt) has been \($status | s1) for \($age | floor) seconds (threshold \(.queued_threshold_secs)) and has executed nothing"
                else
                  "pending\nattempt \($attempt) is \($status | s1) (\($age | floor)s, under the \(.queued_threshold_secs)s threshold)"
                end
            end
        else
          "pending\nattempt \($attempt) is \($status | s1)"
        end )

    # --- the run concluded --------------------------------------------------------------------
    # `skipped` and `neutral` are NOT failures — that is how GitHub scores a required check, and
    # treating a fully-skipped run as red would flag every repo with conditional workflows.
    elif ($concl != null) and ($concl | IN("success","skipped","neutral")) then
      "green\nattempt \($attempt) concluded \($concl | s1)"
    elif $concl == null then
      "unknown\nthe run reports status completed with no conclusion"

    # A run that could not START produces no jobs at all, so without this arm it falls through to
    # the zero-jobs guard and is reported as unreadable — sending the operator to a status page
    # instead of to the workflow file. Classified `failed` because a log-less start failure is
    # still something to READ (the run page names it), which is what separates 22 from 23.
    #
    # THE CAUSAL CLAIM IS DELIBERATELY WEAK, and it used to be too strong: this said "the workflow
    # definition itself could not start, which is this diff and not the platform". Independent
    # review pushed back and it was right twice over — GitHub documents `startup_failure` for check
    # suites while the workflow-run conclusion list omits it, and even where it appears, "failed
    # during startup" does not prove a workflow-definition defect. THIS ARM IS ALSO THE ONE SHAPE
    # HERE WITH NO RECORDED SPECIMEN: 200 runs across two repos yielded only success/failure/null,
    # so its fixture is hand-written and says so. Name what happened, point at both candidates.
    elif $concl == "startup_failure" then
      "failed\nattempt \($attempt) concluded startup_failure — it never got as far as running a job. Check the workflow file and the ref it was dispatched on; the run page states the reason"

    # Zero jobs on a concluded, non-passing run. NOT `never-ran`: "nothing executed" and "nothing
    # could be read about what executed" are different claims, and only the first one is evidence.
    # A successfully-read `total_count: 0` and a response that lost its array are indistinguishable
    # from here, so this fails closed.
    elif ($jobs | length) == 0 then
      "unknown\nattempt \($attempt) concluded \($concl | s1) with no jobs to inspect, so what executed cannot be established"

    else
      # A job is NON-PASSING if it did not conclude in a state GitHub scores as non-failing. A job
      # still `in_progress` inside a COMPLETED run is a contradiction the caller must see, so
      # `status != completed` counts here rather than being quietly dropped.
      ( [ $jobs[]
          | select( ((.status // "") != "completed")
                    or ((.conclusion // null) == null)
                    or ((.conclusion) | IN("success","skipped","neutral") | not) ) ] ) as $bad
      | ( [ $bad[] | select(.steps | length > 0) ] )  as $bad_ran
      | ( [ $bad[] | select(.steps | length == 0) ] ) as $bad_idle
      # How much of the run executed AT ALL, which is a different question from how much of the
      # FAILING part did. It is not used to decide anything — it is used to stop the reason line
      # from claiming more than the evidence supports; see the never-ran arm.
      | ( [ $jobs[] | select(.steps | length > 0) ] | length ) as $ran_any
      | if ($bad | length) == 0 then
          "unknown\nattempt \($attempt) concluded \($concl | s1) but every job passed, so the failure cannot be attributed"

        # AT LEAST ONE non-passing job executed a step, so a log exists and the diff is in scope.
        # This is checked BEFORE `never-ran` on purpose: a matrix in which three shards never
        # acquired a runner while two failed a real assertion is a REAL failure with a partial
        # infrastructure problem beside it, and reporting it as infrastructure would bury the two
        # genuine failures. The idle shards are still NAMED, because a half-run matrix is
        # something the operator has to know about to read the result correctly.
        elif ($bad_ran | length) > 0 then
          "failed\nattempt \($attempt) concluded \($concl | s1); executed and did not pass: "
          + ([$bad_ran[] | "\((.name // "job") | s1) (\((.conclusion // .status // "?") | s1))"] | join(", "))
          + (if ($bad_idle | length) > 0 then
               " — and \($bad_idle | length) job(s) executed NO step: "
               + ([$bad_idle[] | (.name // "job") | s1] | join(", "))
             else "" end)

        # THE THIRD CLASS. Every job that did not pass carries an empty `steps` array, so the red
        # says nothing about the diff.
        #
        # WHAT THIS PROVES IS NARROWER THAN "THE RUN NEVER RAN", and the reason line now says which.
        # A run can have a successful shard that executed fully beside a cancelled one that never
        # started; the FAILURE still has no log, which is the whole point, but "nothing executed"
        # would be a false sentence about that run. Independent review reproduced exactly that shape
        # against the first version, and it is why the invariant in this file`s header is scoped to
        # NON-PASSING jobs rather than to the run.
        else
          ( [ $anns[] | select((.messages // []) | length > 0)
              | "\((.name // "job") | s1): \([(.messages // [])[] | s1] | join("; "))" ] ) as $why
          | "never-ran\nattempt \($attempt) concluded \($concl | s1) and NOT ONE of \($bad_idle | length) non-passing job(s) executed a step: "
            + ([$bad_idle[] | "\((.name // "job") | s1) (\((.conclusion // .status // "?") | s1))"] | join(", "))
            + (if $ran_any > 0 then " (\($ran_any) other job(s) in this run DID execute)" else "" end)
            + (if ($why | length) > 0 then " — annotation: " + ($why | join(" | ")) else "" end)
        end
    end
    end
  ' 2>/dev/null)" || {
    echo "ci-health: could not classify the run (malformed input)" >&2; return 20; }
  [ -n "$out" ] || { echo "ci-health: could not classify the run (malformed input)" >&2; return 20; }

  printf '%s\n' "$out"

  # The verdict word and the exit code are decided in ONE place, from the same string the caller
  # just read, so a program that prints `never-ran` can never return the code for `failed`.
  case "${out%%$'\n'*}" in
    green)     return 0 ;;
    failed)    return 22 ;;
    never-ran)
      echo "ci-health: nothing that failed here executed a step, so there is nothing in this diff to diagnose and no test to de-flake (base/practices/issues-and-scope.md)." >&2
      # WHAT THE EVIDENCE SUPPORTS, AND NOT ONE WORD MORE. This used to say "check githubstatus and
      # re-run once capacity returns", which asserts a PROVIDER OUTAGE — and an empty step list is
      # produced just as well by a manual cancellation, a concurrency-group cancellation, a run
      # superseded by a newer one, or a self-hosted runner nobody brought up. Independent review
      # caught the overclaim. "It did not run" is proven; "it will clear on its own" is not, and it
      # is the flattering half.
      echo "ci-health: the evidence says it did NOT run; it does not say why. A platform incident, an unacquired runner, a concurrency cancellation and a manual cancellation all look like this — check https://www.githubstatus.com/ and who cancelled it before assuming it clears on its own." >&2
      echo "ci-health: a re-run here is NOT green-by-retry: no earlier result is being overridden, because there was never a result." >&2
      return 23 ;;
    queued)
      echo "ci-health: the run has executed nothing yet, so there is nothing to diagnose. A concurrency group can legitimately hold a run for hours — check https://www.githubstatus.com/ and this repo's concurrency limits before concluding anything." >&2
      return 24 ;;
    pending)   return 25 ;;
    unknown)
      echo "ci-health: refusing to guess. An unreadable run must never resolve to \"probably the platform\" (base/practices/verify-before-asserting.md)." >&2
      return 20 ;;
    # Unreachable by construction: every arm above emits one of the six words. An unrecognised one
    # means the table and this mapping have drifted apart, which is exactly the state that must not
    # be reported as a verdict.
    *)
      echo "ci-health: internal error — the classifier emitted an unrecognised verdict" >&2
      return 20 ;;
  esac
}

# --- the live reads ------------------------------------------------------------------------------
cmd_classify() {
  local slug runraw jobsraw jobsdoc annraw doc now run_url attempt

  [ -n "$OPT_RUN" ] || { echo "ci-health: classify requires --run <id>" >&2; return 2; }
  case "$OPT_RUN" in
    ''|*[!0-9]*)
      printf 'ci-health: --run must be a numeric workflow-run id (got %s)\n' "$(adb_display_value "$OPT_RUN")" >&2
      return 2 ;;
  esac

  adb_require_gh jq || return 20

  if [ -n "$OPT_REPO" ]; then
    # A slug reaches a request path, so it is held to the same standard `adb_repo_slug` holds the
    # resolved one to: `a/..` is a well-formed pair AND a path traversal.
    adb_is_path_safe_repo_slug "$OPT_REPO" \
      || { printf 'ci-health: --repo %s is not a safe owner/name slug\n' "$(adb_display_value "$OPT_REPO")" >&2
           return 2; }
    slug="$OPT_REPO"
  else
    slug="$(adb_repo_slug)" || return 20
  fi

  # READ, THEN PARSE — two statements, never one pipeline. A pipeline reports only its LAST
  # command's status, so `gh api … | jq …` returns jq's: a failed read arrives as empty input and is
  # parsed into an empty document, i.e. a read failure wearing "nothing here" as its answer.
  runraw="$(gh api "repos/$slug/actions/runs/$OPT_RUN" 2>/dev/null)" \
    || { echo "ci-health: could not read run $OPT_RUN in $slug" >&2; return 20; }
  [ -n "$runraw" ] \
    || { echo "ci-health: run $OPT_RUN in $slug returned an empty response body" >&2; return 20; }

  # ANCHOR THE JOBS READ TO THE ATTEMPT THE RUN DOCUMENT DESCRIBES (independent-review find). The
  # plain `/jobs` endpoint defaults to `filter=latest`, which is a MOVING target: a re-run landing
  # between these two calls pairs attempt N's run object with attempt N+1's job list — and attempt
  # N+1's jobs are, for a few seconds, exactly the empty-step shape that means `never-ran`. An
  # executed, genuinely failed attempt would then be reported as infrastructure. `/attempts/<n>/jobs`
  # is immutable once that attempt has concluded, so the pair can no longer disagree.
  attempt="$(printf '%s' "$runraw" | jq -r '.run_attempt // empty' 2>/dev/null)"
  case "$attempt" in
    ''|*[!0-9]*)
      # No usable attempt number is a fact this module could not establish, and the fallback of
      # "use the moving endpoint anyway" is the race above, re-entered through the error path.
      echo "ci-health: run $OPT_RUN in $slug reports no usable run_attempt — refusing to pair it with a moving job list" >&2
      return 20 ;;
  esac
  jobsraw="$(gh api --paginate "repos/$slug/actions/runs/$OPT_RUN/attempts/$attempt/jobs?per_page=100" 2>/dev/null)" \
    || { echo "ci-health: could not read the jobs of run $OPT_RUN attempt $attempt in $slug" >&2; return 20; }
  [ -n "$jobsraw" ] \
    || { echo "ci-health: the jobs of run $OPT_RUN attempt $attempt in $slug returned an empty response body" >&2; return 20; }
  # `--paginate` concatenates ONE document per page; `jq -s` slurps them into an array, and the
  # merge below rebuilds the single `{total_count, jobs}` shape the classifier expects.
  #
  # EVERY PAGE IS TYPE-CHECKED BEFORE IT IS MERGED. Iterating a non-object does not fail in jq — a
  # malformed page would flatten to nothing and silently shrink the job list, which is the same
  # partial read the completeness guard exists to catch, arriving through a door it cannot see.
  #
  # AND COMPLETENESS IS NOT A COUNT (independent-review find). Trusting only the first page's
  # `total_count` and comparing lengths accepts a page SWAP: a repeat of page 1 in place of page 2
  # keeps the total right while dropping an executed job and duplicating an idle one — arriving at
  # `never-ran` from evidence that is missing the very job that disproves it. So every page must
  # agree on the total, and the merged job ids must be unique.
  jobsdoc="$(printf '%s' "$jobsraw" | jq -s -c '
      if length == 0 then error("no pages") else . end
      | ( [ .[] | if type != "object" then error("page is not a JSON object") else . end ] ) as $pages
      | ( $pages[0].total_count // error("a page carries no total_count") ) as $total
      | if ([$pages[] | .total_count] | unique | length) != 1
        then error("the pages disagree about total_count") else . end
      | ( [ $pages[] | (.jobs // error("a page carries no jobs array"))[] ] ) as $all
      | if ([$all[] | .id] | any(. == null)) then error("a job carries no id") else . end
      | if (([$all[] | .id] | unique | length) != ($all | length))
        then error("the merged job list repeats an id, so a page was served twice") else . end
      | { total_count: $total, jobs: $all }' 2>/dev/null)" \
    || { echo "ci-health: could not parse the jobs of run $OPT_RUN attempt $attempt in $slug (see the completeness rules in this file)" >&2; return 20; }

  # ANNOTATIONS ARE ENRICHMENT, so they are read LAST, only for the jobs that executed nothing, and
  # a failure here degrades the reason line rather than the verdict. Reading them for every job
  # would be one API call per job — 27 on this repo's own CI — to improve a sentence.
  annraw='[]'
  if [ "$OPT_ANNOTATIONS" -eq 1 ]; then
    annraw="$(_ci_annotations "$slug" "$jobsdoc")" || annraw='[]'
    # BELT TO THE BRACES ABOVE, and not decoration. `--argjson annotations ""` is a jq ERROR, so an
    # empty capture here would fail the document assembly and return 20 — turning a hiccup in the
    # enrichment read into a verdict failure, which is precisely the coupling the paragraph above
    # says cannot happen. The helper always prints something today; this is what keeps that from
    # being load-bearing.
    [ -n "$annraw" ] || annraw='[]'
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  adb_is_utc_instant "$now" \
    || { echo "ci-health: could not read a usable UTC clock" >&2; return 20; }

  doc="$(jq -n --argjson run "$runraw" --argjson jobs "$jobsdoc" \
               --argjson annotations "$annraw" \
               --arg now "$now" --argjson threshold "$OPT_THRESHOLD" \
               '{run:$run, jobs:$jobs, annotations:$annotations, now:$now,
                 queued_threshold_secs:$threshold}' 2>/dev/null)" \
    || { echo "ci-health: could not assemble the run document" >&2; return 20; }

  # Emitted for a human before the verdict, because a run id is not something anyone recognises.
  # SHAPE-CHECKED FIRST: this is an API-supplied string going straight into a log line, and one
  # carrying a newline would forge the line after it. Every other API value in this file is either
  # validated (the slug) or routed through the one-line sanitizer in the jq program; this one is
  # neither, so it is only printed when it looks like a URL and contains no whitespace at all.
  run_url="$(printf '%s' "$runraw" | jq -r '.html_url // ""' 2>/dev/null)"
  case "$run_url" in
    https://*[[:space:]]*|http://*[[:space:]]*) run_url="" ;;
    https://*|http://*) : ;;
    *) run_url="" ;;
  esac
  [ -n "$run_url" ] && echo "ci-health: classifying $run_url" >&2

  printf '%s' "$doc" | _ci_classify_doc
}

# _ci_annotations <slug> <jobs-doc> — the annotation messages of the jobs that executed NO step, as
# `[{name, messages:[…]}]`. Prints `[]` and returns 0 whenever nothing can be read: this output is
# never allowed to change a verdict, so a failure here must not propagate.
_ci_annotations() {
  local slug="$1" jobsdoc="$2" ids out=() line id name raw msgs
  mapfile -t ids < <(printf '%s' "$jobsdoc" | jq -r '
      .jobs[]
      | select(((.steps // []) | length) == 0)
      | select(((.conclusion // null) == null) or ((.conclusion) | IN("success","skipped","neutral") | not))
      | "\(.id // "")\t\(.name // "job")"' 2>/dev/null)
  for line in "${ids[@]}"; do
    id="${line%%$'\t'*}"; name="${line#*$'\t'}"
    case "$id" in ''|*[!0-9]*) continue ;; esac
    # A job id IS the check-run id for an Actions job, which is what the annotations endpoint takes.
    raw="$(gh api "repos/$slug/check-runs/$id/annotations" 2>/dev/null)" || continue
    [ -n "$raw" ] || continue
    msgs="$(printf '%s' "$raw" | jq -c --arg n "$name" '
        if type != "array" then empty
        else {name:$n, messages: [ .[] | .message // empty | select(. != "") ]} end' 2>/dev/null)" || continue
    [ -n "$msgs" ] && out+=("$msgs")
  done
  [ "${#out[@]}" -eq 0 ] && { printf '[]'; return 0; }
  printf '%s' "$(IFS=,; printf '[%s]' "${out[*]}")"
}

# --- arg parsing ---------------------------------------------------------------------------------
# `--run` is REQUIRED, never optional. An optional run id would make the command silently answer
# about something the caller did not name — the fail-open shape this module exists to remove.
parse_classify_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)
        [ "$#" -ge 2 ] || { echo "ci-health: --run needs a value" >&2; exit 2; }
        OPT_RUN="$2"; shift ;;
      --repo)
        [ "$#" -ge 2 ] || { echo "ci-health: --repo needs a value" >&2; exit 2; }
        OPT_REPO="$2"; shift ;;
      --queued-threshold)
        [ "$#" -ge 2 ] || { echo "ci-health: --queued-threshold needs a value" >&2; exit 2; }
        case "$2" in
          ''|*[!0-9]*)
            printf 'ci-health: --queued-threshold must be a non-negative integer (got %s)\n' "$(adb_display_value "$2")" >&2
            exit 2 ;;
        esac
        OPT_THRESHOLD="$2"; shift ;;
      --no-annotations) OPT_ANNOTATIONS=0 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'ci-health: unknown option %s\n' "$(adb_display_value "$1")" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  classify)     parse_classify_opts "$@"; cmd_classify ;;
  classify-doc)
    [ "$#" -eq 0 ] || { echo "ci-health: classify-doc takes no arguments (document on stdin)" >&2; exit 2; }
    _ci_classify_doc ;;
  -h|--help)    usage; exit 0 ;;
  *) printf 'ci-health: unknown subcommand %s (expected classify or classify-doc)\n' "$(adb_display_value "$SUB")" >&2
     usage >&2; exit 2 ;;
esac
