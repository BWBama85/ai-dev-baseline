#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the CI-run classifier (issue #300).
#
# `scripts/lib/ci-health.sh` answers one question — did this run actually EXECUTE? — and its answer
# decides whether an agent spends the next hour bisecting its own diff or walks away and re-runs.
# It is a GUARD, so it gets what guards get here: it is driven to RED on the real superseded input,
# and the assertions that prove it are themselves proven able to fail.
#
# WHY THAT MATTERS MORE THAN USUAL. A classifier's dangerous answer is the FLATTERING one:
# `never-ran` says the red is not your fault. A version that returned it too eagerly — from a
# truncated job list, from a matrix where three shards failed for real and two never started, from
# a response nobody could parse — would read exactly like a working one on every green repo, and
# would quietly wave real failures through. So every arm below that resolves to `20` is tested as
# carefully as the arms that resolve to a verdict.
#
# WHAT IS PROVEN HERE:
#
#   1. THE REAL SPECIMEN. Run 31126981959 on `BWBama85/thewilsonnet` — the 2026-08-06 GitHub Actions
#      `major_outage` run named in #300 — is RECORDED here as a fixture and must classify
#      `never-ran` (23) with its runner-acquisition annotation quoted. The payloads are frozen
#      rather than fetched: a test that depends on a third-party run staying fetchable is a test
#      that goes red for a reason unrelated to this repo.
#   2. THE CONTROL. A recorded excerpt of a REAL red run of this repo's own CI (31460894856, whose
#      `precommit-gate` job failed after executing 8 steps) must classify `failed` (22). Without a
#      control, a classifier wedged at `never-ran` passes item 1 perfectly.
#   3. THE WHOLE TRUTH TABLE, exhaustively, through the pure `classify-doc` arm: green, skipped /
#      neutral, startup_failure, queued over and under the threshold, in_progress, a mixed matrix,
#      an all-passing job set under a failed run, no conclusion, no jobs, a truncated list, and
#      malformed input at every level of the document.
#   4. THE LIVE WIRING, through a recording `gh` stub: that `classify --run` performs the reads it
#      claims to, merges paginated job pages, reaches the SAME decision the pure arm reaches, and
#      fails closed on each read failure. A stub proves the parsing and the decision; it can never
#      prove what GitHub returns, which is why item 1 is a recording rather than a hand-written
#      shape.
#   5. THE ENRICHMENT BOUNDARY: the annotations read is enrichment, so a failure there must degrade
#      the reason line and NOT the verdict — and `--no-annotations` must skip it entirely.
#   6. SIX SPECIFIC ASSERTIONS ARE OBSERVED FAILING (the mutation section at the end). Six
#      mutations of a COPY of the library — never the tracked tree (`base/practices/self-review.md`)
#      — each verified applied by the shared `check_mutate_line`, each verified to still LOAD, and
#      each required to make ONE NAMED assertion above go red: the truncation guard, the
#      executed-failure arm's precedence, the verdict-to-exit-code mapping, the one-line sanitizer,
#      the missing-`steps` guard, and the attempt anchoring.
#
#      SAY WHAT THAT DOES NOT COVER, because "the assertions above are proven" would be a claim
#      about all of them and it is not true. Pagination totals, live/pure equivalence, the
#      annotation-failure isolation, the queue boundary, the API-read failures, `startup_failure`
#      and the usage arm have assertions but no paired mutation — they are tested, not proven able
#      to fail. Independent review named this gap; six is where the cost/benefit landed, and the
#      six chosen are the ones whose failure mode is a WRONG VERDICT rather than a missing one.
#
# WHAT CANNOT BE TESTED HERE: that GitHub emits this shape during the next incident, and that a
# runner-acquisition annotation always carries that wording. Both are vendor behaviour. The
# classifier therefore decides on STEP COUNTS, which are structural, and treats the annotation as
# enrichment — item 5 is what pins that split.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-ci-health.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a sourced
# file returns its LAST command's status, so `. lib || exit 1` reports whatever that happened to be.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
CH="$ROOT/scripts/lib/ci-health.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary + check_exit_guard

work="$(mktemp -d)"
# FAIL CLOSED unless check_summary actually ran (#213): a suite's exit status is its last command's,
# and only check_summary consults the failure counter — so a truncating edit would print the FAIL
# diagnostics and still exit 0, reported as passing by both selfcheck and CI.
check_exit_guard "check-ci-health" "rm -rf \"$work\""

REPO="$work/repo"; SBIN="$work/sbin"; S="$work/stub"
mkdir -p "$REPO" "$SBIN" "$S"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/BWBama85/thewilsonnet.git

# ============================ the RECORDED real payloads ============================
# Frozen from the live API on 2026-08-11, trimmed to the fields the classifier reads. These are
# the specimen #300 names, and they are the reason this suite can claim the guard was observed
# classifying the real never-ran shape rather than a hand-written imitation of it.
NEVER_RUN_JSON='{"id":31126981959,"name":"ci","status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2026-08-06T19:34:34Z","run_started_at":"2026-08-06T19:34:34Z","html_url":"https://github.com/BWBama85/thewilsonnet/actions/runs/31126981959"}'
NEVER_JOBS_JSON='{"total_count":1,"jobs":[{"id":92701613298,"name":"ci","status":"completed","conclusion":"cancelled","steps":[]}]}'
NEVER_ANN_JSON='[{"path":".github","annotation_level":"failure","title":"","message":"The job was not acquired by Runner of type hosted even after multiple attempts","raw_details":""}]'

# A REAL red run of this repo's own CI, excerpted to two jobs: one that passed and one that failed
# after executing steps. This is the control that proves the classifier is not wedged.
RED_RUN_JSON='{"id":31460894856,"name":"CI","status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2026-08-11T05:12:39Z","run_started_at":"2026-08-11T05:12:39Z","html_url":"https://github.com/BWBama85/ai-dev-baseline/actions/runs/31460894856"}'
RED_JOBS_JSON='{"total_count":2,"jobs":[{"id":93684015080,"name":"shellcheck","status":"completed","conclusion":"success","steps":[{"name":"Set up job","conclusion":"success","number":1},{"name":"Complete job","conclusion":"success","number":15}]},{"id":93684015182,"name":"precommit-gate","status":"completed","conclusion":"failure","steps":[{"name":"Set up job","conclusion":"success","number":1},{"name":"Stop-hook quality gate must fail loud on a missing library (#35)","conclusion":"failure","number":6}]}]}'

# ============================ pure-arm helpers ============================
# doc <run-json> <jobs-json> [annotations-json] [now] [threshold] — assemble the classifier's
# document. Built with jq rather than string concatenation so a malformed fixture fails HERE, as a
# test-harness error, instead of arriving at the classifier as the malformed-input case some other
# assertion is trying to test.
doc() {
  jq -nc --argjson run "$1" --argjson jobs "$2" \
         --argjson ann "${3:-[]}" \
         --arg now "${4:-2026-08-06T21:30:00Z}" --argjson thr "${5:-1800}" \
         '{run:$run, jobs:$jobs, annotations:$ann, now:$now, queued_threshold_secs:$thr}'
}

# cd <doc> : run the PURE arm. Sets VERD (line 1), REASON (line 2) and RC.
VERD=""; REASON=""; RC=0; ERROUT=""
cd_() {
  local out
  out="$(printf '%s' "$1" | bash "${MUT_CH:-$CH}" classify-doc 2>"$work/err")"; RC=$?
  VERD="$(printf '%s' "$out" | sed -n '1p')"
  REASON="$(printf '%s' "$out" | sed -n '2p')"
  ERROUT="$(cat "$work/err")"
}

# verdict <doc> <want-word> <want-rc> <label> — the assertion this whole suite is made of. BOTH the
# word and the code, always: they are produced by one `case` and a mutation that desynchronizes
# them would otherwise pass every test that checks only one.
verdict() {
  cd_ "$1"
  eq "$VERD" "$2" "$4: verdict word"
  eq "$RC" "$3" "$4: exit code"
}

# ============================ 1 + 2. the real specimen and its control ============================
verdict "$(doc "$NEVER_RUN_JSON" "$NEVER_JOBS_JSON" "[{\"name\":\"ci\",\"messages\":[\"The job was not acquired by Runner of type hosted even after multiple attempts\"]}]")" \
        never-ran 23 "the REAL 2026-08-06 outage run (31126981959)"
has "$REASON" "NOT ONE of 1 non-passing job(s) executed a step" "...and the reason says nothing executed"
has "$REASON" "ci (cancelled)" "...and names the job and its conclusion"
has "$REASON" "not acquired by Runner of type hosted" "...and quotes the runner-acquisition annotation"
has "$ERROUT" "no test to de-flake" "...and refuses the de-flake issue issues-and-scope.md forbids"
# THE ADVICE MUST NOT ASSERT AN OUTAGE. An empty step list is produced just as well by a manual
# cancellation, a concurrency cancellation, a superseded run, or a self-hosted runner nobody
# started — so "it will clear on its own" is a guess where "it did not run" is proof.
has "$ERROUT" "it does not say why" "...and does NOT assert a provider outage"
has "$ERROUT" "manual cancellation" "...and names the other causes that look identical"
has "$ERROUT" "NOT green-by-retry" "...and says the re-run is not green-by-retry"

verdict "$(doc "$RED_RUN_JSON" "$RED_JOBS_JSON")" failed 22 "the REAL red run of this repo's CI (31460894856)"
has "$REASON" "precommit-gate (failure)" "...and names the job that actually executed and failed"
hasnt "$REASON" "shellcheck" "...and does not name the job that passed"

# The specimen with its annotation UNAVAILABLE is still never-ran. This is the enrichment boundary
# stated as a verdict: the decision rests on the empty `steps` array, which was read successfully.
verdict "$(doc "$NEVER_RUN_JSON" "$NEVER_JOBS_JSON" '[]')" never-ran 23 "never-ran with no annotation read"
hasnt "$REASON" "annotation:" "...and the reason simply omits the annotation clause"

# ============================ 3. the rest of the truth table ============================
R_OK='{"status":"completed","conclusion":"success","created_at":"2026-08-06T19:34:34Z"}'
J_NONE='{"total_count":0,"jobs":[]}'

verdict "$(doc "$R_OK" "$J_NONE")" green 0 "success"
verdict "$(doc '{"status":"completed","conclusion":"skipped","created_at":"2026-08-06T19:34:34Z"}' "$J_NONE")" \
        green 0 "skipped is not a failure (GitHub scores it non-failing)"
verdict "$(doc '{"status":"completed","conclusion":"neutral","created_at":"2026-08-06T19:34:34Z"}' "$J_NONE")" \
        green 0 "neutral is not a failure"

# startup_failure is the diff, not the platform — it produces zero jobs, so without its own arm it
# would land on the no-jobs guard and send the operator to a status page instead of to the workflow
# file they just edited.
verdict "$(doc '{"status":"completed","conclusion":"startup_failure","created_at":"2026-08-06T19:34:34Z"}' "$J_NONE")" \
        failed 22 "startup_failure is REAL, not infrastructure"
# THE CAUSAL CLAIM IS DELIBERATELY WEAK. This arm used to assert "which is this diff and not the
# platform"; review pointed out that GitHub documents `startup_failure` for check suites while the
# workflow-run conclusion list omits it, and that even where it appears it does not prove a
# workflow-definition defect. Assert what it DOES say, and assert that it no longer overclaims.
has "$REASON" "never got as far as running a job" "...and says no job ran"
hasnt "$REASON" "not the platform" "...and no longer claims to have ruled the platform out"

# Queue ageing, including the exact boundary. `>=` is the documented comparison, so the threshold
# second itself is overdue; one second under it is not.
Q='{"status":"queued","conclusion":null,"created_at":"2026-08-06T19:00:00Z","run_started_at":"2026-08-06T19:00:00Z"}'
verdict "$(doc "$Q" "$J_NONE" '[]' "2026-08-06T19:30:00Z" 1800)" queued  24 "queued exactly AT the threshold"
verdict "$(doc "$Q" "$J_NONE" '[]' "2026-08-06T19:29:59Z" 1800)" pending 25 "queued one second UNDER the threshold"
verdict "$(doc "$Q" "$J_NONE" '[]' "2026-08-06T21:00:00Z" 1800)" queued  24 "queued far past the threshold"
has "$REASON" "has executed nothing" "...and says nothing executed"
verdict "$(doc '{"status":"waiting","conclusion":null,"created_at":"2026-08-06T19:00:00Z"}' "$J_NONE" '[]' "2026-08-06T21:00:00Z" 1800)" \
        queued 24 "a run in the waiting state ages the same way"

# A LONG BUILD IS NOT AN OUTAGE. Only a run that has not STARTED can be overdue; without this,
# every heavy test suite would inherit the excuse this module exists to ration.
verdict "$(doc '{"status":"in_progress","conclusion":null,"created_at":"2026-08-06T01:00:00Z"}' "$J_NONE" '[]' "2026-08-06T21:00:00Z" 1800)" \
        pending 25 "a long in_progress run is pending, NEVER queued-beyond-threshold"

# A run with no timestamp to age against cannot be classified — it must not default to `pending`,
# which is the answer that says "nothing is wrong".
verdict "$(doc '{"status":"queued","conclusion":null}' "$J_NONE")" unknown 20 "queued with no timestamp is unreadable"

# THE MIXED MATRIX. A real failure beside an infrastructure one is a REAL failure: there is a log.
# Reporting it as infrastructure would bury two genuine failures behind "not your fault".
MIX='{"total_count":3,"jobs":[
  {"id":1,"name":"shard-1","status":"completed","conclusion":"failure","steps":[{"name":"test"}]},
  {"id":2,"name":"shard-2","status":"completed","conclusion":"cancelled","steps":[]},
  {"id":3,"name":"shard-3","status":"completed","conclusion":"success","steps":[{"name":"test"}]}]}'
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$MIX")" \
        failed 22 "a mixed matrix (one real failure, one never started) is REAL"
has "$REASON" "shard-1 (failure)" "...and names the shard that actually failed"
has "$REASON" "executed NO step: shard-2" "...and STILL names the shard that never started"

# Every non-passing job idle => never-ran, even across several jobs.
ALLIDLE='{"total_count":2,"jobs":[
  {"id":1,"name":"a","status":"completed","conclusion":"cancelled","steps":[]},
  {"id":2,"name":"b","status":"completed","conclusion":"failure","steps":[]}]}'
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$ALLIDLE")" \
        never-ran 23 "several non-passing jobs, none of which executed a step"

# A job still running inside a COMPLETED run is a contradiction the caller must see. It counts as
# non-passing, and with no steps it is the idle set — never silently dropped, which would leave
# `$bad` empty and turn a real inconsistency into `unknown` for the wrong reason.
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":[{"id":1,"name":"a","status":"in_progress","conclusion":null,"steps":[]}]}')" \
        never-ran 23 "a still-running job in a completed run counts as non-passing"

# --- the fail-closed arms -------------------------------------------------------------------
# THE TRUNCATION GUARD is the most important one in the file. A page that never arrived contributes
# zero jobs and zero steps, which is byte-identical to the platform running nothing.
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":9,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure","steps":[]}]}')" \
        unknown 20 "a TRUNCATED job list is unreadable, NOT never-ran"
has "$REASON" "the job list is incomplete" "...and says the read was partial"

verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$J_NONE")" \
        unknown 20 "a concluded failure with NO jobs cannot be attributed"
verdict "$(doc '{"status":"completed","conclusion":null,"created_at":"2026-08-06T19:34:34Z"}' "$J_NONE")" \
        unknown 20 "completed with no conclusion is unreadable"
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"success","steps":[{"name":"t"}]}]}')" \
        unknown 20 "a failed run whose every job passed cannot be attributed"

# --- the two-line stdout contract, against the one field this code does not control -----------
# A JOB NAME MAY CONTAIN A NEWLINE. `name: >` in a workflow is a folded block scalar and GitHub
# returns the embedded newline verbatim, so an unsanitized name splits the reason across lines: a
# caller reading line 2 gets a truncated sentence and line 3 carries a fragment of a job name where
# it expects nothing. Found by self-review, and asserted on the LINE COUNT rather than on the text,
# because that is the property that actually breaks.
NASTY='{"total_count":1,"jobs":[{"id":1,"name":"a\nb\tc\rd","status":"completed","conclusion":"cancelled","steps":[]}]}'
NASTY_ANN='[{"name":"j\nk","messages":["m\nn"]}]'
OUT2="$(printf '%s' "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$NASTY" "$NASTY_ANN")" \
        | bash "$CH" classify-doc 2>/dev/null)"
eq "$(printf '%s\n' "$OUT2" | wc -l | tr -d ' ')" "2" \
   "a job name carrying a newline does NOT break the two-line stdout contract"
has "$OUT2" "a b c d" "...the name is collapsed to one line rather than dropped"
has "$OUT2" "j k: m n" "...and so is the annotation"

# Unicode and embedded quotes survive intact — collapsing whitespace must not mangle the name.
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":[{"id":1,"name":"tëst \"job\" ✓","status":"completed","conclusion":"cancelled","steps":[]}]}')" \
        never-ran 23 "a unicode/quoted job name classifies normally"
has "$REASON" 'tëst "job" ✓' "...and is reproduced verbatim"

# A malformed timestamp must say WHICH field was wrong, not just "malformed input". Both are 20
# either way; the difference is whether the operator can act on it.
verdict "$(doc '{"status":"queued","conclusion":null,"created_at":"yesterday"}' "$J_NONE")" \
        unknown 20 "an unparseable run timestamp is unreadable"
has "$REASON" "no usable UTC timestamp" "...and names the run timestamp as the problem"
verdict "$(doc '{"status":"queued","conclusion":null,"created_at":"2026-08-06T19:00:00Z"}' "$J_NONE" '[]' 'nope')" \
        unknown 20 "an unparseable clock is unreadable"
has "$REASON" "clock is not a UTC instant" "...and names the clock as the problem"

# --- MISSING EVIDENCE IS NOT EVIDENCE (every one of these was a live fail-open) ---------------
# All four were reproduced by independent review against the first version, and every one of them
# manufactured this module's most consequential verdict out of a field that was never read. They
# are grouped because they are one mistake wearing four hats.
verdict "$(doc '{"conclusion":null}' "$J_NONE")" unknown 20 \
        "a run with NO status is unreadable, not pending"
has "$REASON" "carries no status" "...and says so"
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure"}]}')" \
        unknown 20 "a failed job with NO steps FIELD is unreadable, not never-ran"
has "$REASON" "MISSING step list is not an EMPTY one" "...and says exactly why"
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure","steps":null}]}')" \
        unknown 20 "a job whose steps is null is unreadable, not never-ran"
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":1,"jobs":["not an object"]}')" \
        unknown 20 "a non-object job entry is unreadable"
# A FUTURE start time is a contradiction between the API and the clock, not a young run. The first
# version printed `pending ... (-31527000s, under the threshold)` — a confident verdict from
# nonsense. `adb_age_secs` refuses a negative age for the same reason.
verdict "$(doc '{"status":"queued","conclusion":null,"created_at":"2027-08-06T19:00:00Z"}' "$J_NONE")" \
        unknown 20 "a start time in the FUTURE is unreadable, not pending"
has "$REASON" "future relative to the supplied clock" "...and names the contradiction"

# --- what `never-ran` actually proves, stated in the sentence ---------------------------------
# A successful shard that executed fully, beside a cancelled shard that never started. The FAILURE
# still has no log, so 23 is right — but "nothing executed" would be a false sentence about this
# run, and the first version said exactly that.
verdict "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
               '{"total_count":2,"jobs":[{"id":1,"name":"ok","status":"completed","conclusion":"success","steps":[{"name":"t"}]},{"id":2,"name":"idle","status":"completed","conclusion":"cancelled","steps":[]}]}')" \
        never-ran 23 "an idle failing job beside an executed PASSING job is still never-ran"
has "$REASON" "1 other job(s) in this run DID execute" \
    "...and the reason says other jobs ran, rather than claiming nothing did"
# ...and the plain case must NOT carry that clause, or it is decoration rather than a distinction.
cd_ "$(doc "$NEVER_RUN_JSON" "$NEVER_JOBS_JSON")"
hasnt "$REASON" "DID execute" "a run where genuinely nothing executed does not claim otherwise"

# Malformed documents, at every level. Each must be 20 — never a verdict.
for bad_doc in \
  '' \
  'not json' \
  '[]' \
  '{"jobs":{"total_count":0,"jobs":[]},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":{"total_count":0,"jobs":[]},"queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":{"total_count":0,"jobs":[]},"now":"2026-08-06T21:30:00Z"}' \
  '{"run":"nope","jobs":{"total_count":0,"jobs":[]},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":[],"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":{"jobs":[]},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":{"total_count":"1","jobs":[]},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed"},"jobs":{"total_count":0,"jobs":{}},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"completed","conclusion":"failure"},"jobs":{"total_count":0,"jobs":[]},"annotations":{},"now":"2026-08-06T21:30:00Z","queued_threshold_secs":1800}' \
  '{"run":{"status":"queued"},"jobs":{"total_count":0,"jobs":[]},"now":"not-a-date","queued_threshold_secs":1800}' \
; do
  cd_ "$bad_doc"
  eq "$RC" "20" "malformed input fails closed: ${bad_doc:0:56}"
done

# ============================ 4 + 5. the LIVE arm, through a recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the annotations URL and
# the jobs URL are BOTH `repos/*` URLs, so a case arm matching the general shape first swallows the
# specific ones and every scenario silently reads the wrong fixture. Most specific first, always.
cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Answers the four reads `classify` can make, from $S fixtures. Knobs:
#   STUB_AUTH_FAIL=1  -> `gh auth status` fails
#   STUB_FAIL_RUN=1   -> the run read fails
#   STUB_FAIL_JOBS=1  -> the jobs read fails
#   STUB_FAIL_ANN=1   -> the annotations read fails
#   STUB_EMPTY_RUN=1  -> the run read SUCCEEDS with an empty body
#   STUB_EMPTY_JOBS=1 -> the jobs read SUCCEEDS with an empty body
#   STUB_JOBS_PAGES=1 -> the jobs read emits TWO concatenated pages (what --paginate really does)
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
case "${1:-}" in
  auth) exit 0 ;;
  repo) printf '%s\n' "${STUB_SLUG:-BWBama85/thewilsonnet}"; exit 0 ;;
  api)  ;;
  *)    exit 0 ;;
esac
url=""
for a in "$@"; do
  case "$a" in repos/*) [ -z "$url" ] && url="$a" ;; esac
done
printf '%s\n' "$url" >> "$S/calls"
case "$url" in
  */annotations)
    [ "${STUB_FAIL_ANN:-0}" = "1" ] && exit 1
    if [ -f "$S/ann.json" ]; then cat "$S/ann.json"; else printf '[]\n'; fi ;;
  */jobs*)
    [ "${STUB_FAIL_JOBS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_JOBS:-0}" = "1" ] && exit 0
    if [ "${STUB_JOBS_PAGES:-0}" = "1" ]; then cat "$S/jobs-p1.json"; cat "$S/jobs-p2.json"
    elif [ "${STUB_JOBS_DUPE:-0}" = "1" ]; then cat "$S/jobs-p1.json"; cat "$S/jobs-p1.json"
    elif [ "${STUB_JOBS_TOTALS:-0}" = "1" ]; then cat "$S/jobs-p1.json"; cat "$S/jobs-p2b.json"
    else cat "$S/jobs.json"; fi ;;
  repos/*/actions/runs/*)
    [ "${STUB_FAIL_RUN:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_RUN:-0}" = "1" ] && exit 0
    cat "$S/run.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$SBIN/gh"

# live <args…> : run the guard as the driving agent would — from $REPO, with the stub first on PATH.
LOUT=""; LRC=0
live() {
  : > "$S/calls"
  LOUT="$( cd "$REPO" && PATH="$SBIN:$PATH" S="$S" bash "${MUT_CH:-$CH}" "$@" 2>&1 )"; LRC=$?
}

printf '%s' "$NEVER_RUN_JSON"  > "$S/run.json"
printf '%s' "$NEVER_JOBS_JSON" > "$S/jobs.json"
printf '%s' "$NEVER_ANN_JSON"  > "$S/ann.json"

live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "23" "live: the recorded outage run classifies never-ran end to end"
has "$LOUT" "never-ran" "live: ...and prints the verdict word"
has "$LOUT" "not acquired by Runner of type hosted" "live: ...and reaches the annotations endpoint for the idle job"
has "$(cat "$S/calls")" "repos/BWBama85/thewilsonnet/actions/runs/31126981959" "live: ...reads the run"
has "$(cat "$S/calls")" "/jobs" "live: ...reads the jobs"
has "$(cat "$S/calls")" "check-runs/92701613298/annotations" "live: ...and reads THAT job's annotations"

# `--no-annotations` must not pay for the read at all. Asserted as a NEGATIVE, because a verdict
# assertion alone would pass against a version that read them and discarded the result.
live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "23" "live: --no-annotations still classifies never-ran"
hasnt "$(cat "$S/calls")" "annotations" "live: --no-annotations never addresses the annotations endpoint"

# THE ENRICHMENT BOUNDARY. A failed annotations read degrades the sentence, never the verdict — the
# empty `steps` array was read successfully and is what the answer rests on.
( : ) ; STUB_FAIL_ANN=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "23" "live: a FAILED annotations read does not change the verdict"
hasnt "$LOUT" "not acquired by Runner" "live: ...it only drops the annotation from the reason"

# The repo slug comes from the checkout's git origin when --repo is omitted.
live classify --run 31126981959
eq "$LRC" "23" "live: the slug resolves from the checkout when --repo is omitted"

# PAGINATION. Two concatenated pages must merge into one job list whose length matches total_count;
# a merge that dropped a page would land on the truncation guard, so this is proven by the run
# NOT being 20.
printf '%s' '{"total_count":2,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure","steps":[{"name":"t"}]}]}' > "$S/jobs-p1.json"
printf '%s' '{"total_count":2,"jobs":[{"id":2,"name":"b","status":"completed","conclusion":"cancelled","steps":[]}]}'          > "$S/jobs-p2.json"
STUB_JOBS_PAGES=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "22" "live: two --paginate pages merge into one complete job list"
has "$LOUT" "executed NO step: b" "live: ...and the second page's job is present in the verdict"

# THE JOBS READ IS ANCHORED TO THE RUN'S OWN ATTEMPT. The plain `/jobs` endpoint defaults to
# `filter=latest`, a MOVING target: a re-run landing between the two calls pairs attempt N's run
# object with attempt N+1's empty job list, which is exactly the never-ran shape. Asserted as a
# NEGATIVE too, because a verdict assertion alone passes against a version that reads the moving
# endpoint and happens to get the same answer from a stub.
live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
has "$(cat "$S/calls")" "/attempts/1/jobs" "live: the jobs read is anchored to the run's own attempt"
hasnt "$(cat "$S/calls")" "runs/31126981959/jobs" "live: ...and the moving filter=latest endpoint is never used"
# A run with no usable attempt number must NOT fall back to the moving endpoint — that is the same
# race arriving through the error path.
printf '%s' '{"id":1,"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' > "$S/run.json"
live classify --run 1 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "20" "live: a run with no run_attempt is 20, not a moving-endpoint fallback"
hasnt "$(cat "$S/calls")" "jobs" "live: ...and no job read is attempted at all"
printf '%s' "$NEVER_RUN_JSON" > "$S/run.json"

# PAGINATION COMPLETENESS IS NOT A COUNT. A repeat of page 1 in place of page 2 keeps the total
# right while dropping an executed job and duplicating an idle one — arriving at `never-ran` from
# evidence that is missing the job which disproves it.
printf '%s' '{"total_count":3,"jobs":[{"id":2,"name":"b","status":"completed","conclusion":"cancelled","steps":[]}]}' > "$S/jobs-p2b.json"
STUB_JOBS_DUPE=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "20" "live: a duplicated page is unreadable, NOT never-ran"
STUB_JOBS_TOTALS=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "20" "live: pages that disagree about total_count are unreadable"

# Each live read failure is 20 — fail closed, never a verdict.
STUB_FAIL_RUN=1  live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "20" "live: an unreadable RUN is 20"
STUB_FAIL_JOBS=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "20" "live: an unreadable JOB list is 20"
STUB_EMPTY_RUN=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "20" "live: an EMPTY run body is 20, not an empty run"
STUB_EMPTY_JOBS=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "20" "live: an EMPTY jobs body is 20, not an empty job list"
STUB_AUTH_FAIL=1 live classify --run 31126981959 --repo BWBama85/thewilsonnet
eq "$LRC" "20" "live: unauthenticated gh is 20"

# A FORGED `html_url` MUST NOT FORGE A LOG LINE. That value is API-supplied and goes straight to
# stderr; one carrying a newline would print a second line that reads like this tool's own output.
# Every other API value here is validated or sanitized, so this one is shape-checked and dropped
# when it does not look like a whitespace-free URL.
printf '%s' '{"id":1,"status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2026-08-06T19:34:34Z","html_url":"https://x/y\nci-health: everything is fine, merge away"}' > "$S/run.json"
printf '%s' "$NEVER_JOBS_JSON" > "$S/jobs.json"
live classify --run 1 --repo BWBama85/thewilsonnet --no-annotations
eq "$LRC" "23" "live: a forged html_url does not change the verdict"
hasnt "$LOUT" "everything is fine" "live: ...and the forged log line is never printed"
printf '%s' "$NEVER_RUN_JSON" > "$S/run.json"

# The green control, through the live path too.
printf '%s' "$RED_RUN_JSON"  > "$S/run.json"
printf '%s' "$RED_JOBS_JSON" > "$S/jobs.json"
live classify --run 31460894856 --repo BWBama85/ai-dev-baseline --no-annotations
eq "$LRC" "22" "live: the recorded REAL red run classifies failed, not never-ran"

# --- usage --------------------------------------------------------------------------------------
live classify;                                            eq "$LRC" "2" "usage: --run is required"
live classify --run abc;                                  eq "$LRC" "2" "usage: --run must be numeric"
live classify --run 1 --repo 'a/..';                      eq "$LRC" "2" "usage: a path-traversing --repo slug is refused"
live classify --run 1 --queued-threshold -5;              eq "$LRC" "2" "usage: a negative threshold is refused"
live classify --run 1 --nope;                             eq "$LRC" "2" "usage: an unknown option is refused"
live nonsense;                                            eq "$LRC" "2" "usage: an unknown subcommand is refused"
live classify-doc extra </dev/null;                       eq "$LRC" "2" "usage: classify-doc takes no arguments"
live --help;                                              eq "$LRC" "0" "usage: --help exits 0"
has "$LOUT" "ci-health.sh classify --run" "usage: --help documents the live invocation"

# ============================ structural pins ============================
# The module's charter, its exit-code table, and the boundary against the two homes it deliberately
# is not part of. Pinned because each was a real decision (#300) that a later edit could undo by
# accident — and because a header claim nothing checks is a header claim that drifts.
#
# ONE ACCOUNTING STYLE. These use the ok/bad family like everything above rather than the
# grep-assert family (`req_fixed`/`CHECK_FAIL`): only `check_summary` decides this suite's exit
# status, and it consults `pass`/`fail` alone — so a `req_fixed` failure here would print a
# diagnostic and be discarded unless every call site remembered to bridge the two counters.
#
# AND THEY ARE TOKEN-PRESENCE CHECKS, WHICH IS WEAKER THAN THEIR SUBJECTS SOUND. Each proves the
# header still SPELLS a thing, not that the surrounding prose still means it — a rewrite that
# reversed the charter while keeping the word would pass. They are worth having as rename tripwires
# and are labelled accordingly; the behaviour they describe is pinned by the executable assertions
# above, not here. (Independent review flagged the original labels as claiming more than this.)
CHSRC="$(cat "$CH")"
has "$CHSRC" "23 never-ran" "the header still spells the never-ran code"
has "$CHSRC" "22 failed"    "the header still spells the real-failure code"
has "$CHSRC" "24 queued"    "the header still spells the queued code"
has "$CHSRC" "20 unknown"   "the header still spells the fail-closed code"
has "$CHSRC" "branch-health" "the header still names branch-health (rename tripwire for the charter argument)"
has "$CHSRC" "repo-settings.sh" "the header still names repo-settings.sh (rename tripwire for the charter argument)"
# THE CHARTER. `pr-watch.sh` had to be kept out of `pr-review.sh` for exactly this reason: a guard
# that grows a wait becomes a different thing, and nothing but a pin stops it. Asserted over the
# EXECUTABLE lines only, so the header sentence that forbids polling does not satisfy the search
# for polling.
CHCODE="$(grep -v '^[[:space:]]*#' "$CH")"
hasnt "$CHCODE" "sleep " "ci-health never sleeps or polls"
hasnt "$CHCODE" "while true" "ci-health never loops waiting"

# The practice, the predicate and the classifier must agree that the third class exists.
PRAC="$(cat base/practices/ci-discipline.md)"
has "$PRAC" "never-ran" "the practice still spells the third class"
has "$PRAC" "issues-and-scope.md" "the practice cites issues-and-scope.md where it forbids the de-flake issue"
has "$PRAC" "ci-health.sh classify --run" "the practice still names the command that decides it"
# Step 5 (never merge on a flaky re-run) must be SCOPED to results that exist — the carve-out #300
# asks for. Without it the rule reads as forbidding the re-run of a job that produced no result.
has "$PRAC" "of a result that exists" "the green-by-retry rule still carries its results-that-exist scope"

# ============================ 6. the guard, OBSERVED FAILING ============================
# A classifier's failure mode is a plausible wrong answer, so the assertions above are themselves
# proven able to go red. Each mutation is applied to a COPY (never the tracked tree —
# base/practices/self-review.md), VERIFIED APPLIED, and then required to break a specific
# assertion. A mutation that silently failed to apply would leave a green run that proved nothing.
#
# THE WHOLE `scripts/lib` DIRECTORY IS COPIED, not just the one file, because `ci-health.sh`
# resolves `common.sh` beside itself and fails loud when it is absent (design-principles §5). A
# lone mutant copy in a temp dir therefore dies on the missing library BEFORE it classifies
# anything — and every "the assertion went red" test would then pass for the wrong reason,
# reporting a broken install as a proven mutation. Found by running M1 and getting an empty
# verdict. The copy also keeps the tracked tree untouched, which is the point.
#
# THE APPLY-AND-PROVE-IT-TOOK STEP IS `check_mutate_line`, THE SHARED PRIMITIVE (check-lib.sh:160),
# not a local reimplementation. Two suites already drive mutations this way, and it is strictly
# stronger than the hand-rolled version this replaced: it requires EXACTLY ONE matching line before
# the edit and NONE after, so a mutation that silently stopped describing the code it mutates fails
# instead of quietly becoming an assertion about unmodified source. Only the two things it does not
# model stay local — copying the whole lib tree, and the load probe below.
mutate() {   # mutate <label> <exact-line> <sed-script>
  local label="$1" line="$2" script="$3"
  rm -rf "$work/mutlib"
  cp -R "$ROOT/scripts/lib" "$work/mutlib" || { bad "$label: could not copy scripts/lib"; MUT_CH=""; return 1; }
  MUT_CH="$work/mutlib/ci-health.sh"
  check_mutate_line "$MUT_CH" "$line" "$script" "$label" || { MUT_CH=""; return 1; }
  # ...and the mutant must still LOAD. A copy that cannot run is indistinguishable, from every
  # assertion below, from a guard whose removal changed nothing.
  if ! printf '%s' "$(doc "$R_OK" "$J_NONE")" | bash "$MUT_CH" classify-doc >/dev/null 2>&1; then
    bad "$label: the mutant does not run at all (its green control failed) — the assertion below would prove nothing"
    MUT_CH=""; return 1
  fi
  ok
  return 0
}

# M1 — remove the truncation guard. The real hazard: a partial read then looks exactly like the
# platform having run nothing, so the most dangerous verdict is reached from the least evidence.
if mutate "M1 truncation guard removed" \
          '      elif ($jobsdoc.total_count) != ($jobs | length) then' \
          's@elif ($jobsdoc.total_count) != ($jobs | length) then@elif false then@'; then
  cd_ "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
             '{"total_count":9,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure","steps":[]}]}')"
  if [ "$RC" = "20" ]; then bad "M1: the truncation assertion did NOT go red — it is not testing the guard"
  else ok; fi
  eq "$VERD" "never-ran" "M1: ...and without the guard a truncated read really does read as never-ran"
fi
MUT_CH=""

# M2 — check never-ran BEFORE the executed-failure arm. A matrix with a real failure beside an
# unacquired shard would then be reported as infrastructure, burying the genuine failure.
if mutate "M2 never-ran wins over a real failure" \
          '        elif ($bad_ran | length) > 0 then' \
          's@elif ($bad_ran | length) > 0 then@elif false then@'; then
  cd_ "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$MIX")"
  if [ "$VERD" = "failed" ]; then bad "M2: the mixed-matrix assertion did NOT go red"
  else ok; fi
  eq "$RC" "23" "M2: ...and the mutant really does misreport a real failure as infrastructure"
fi
MUT_CH=""

# M3 — desynchronize the verdict word from the exit code. This is why every assertion checks BOTH:
# a caller branches on the code, a human reads the word, and a mutant that prints `never-ran` while
# returning 0 passes any test that looks at only one of them.
if mutate "M3 verdict word and exit code desynchronized" \
          '      return 23 ;;' \
          's@      return 23 ;;@      return 0 ;;@'; then
  cd_ "$(doc "$NEVER_RUN_JSON" "$NEVER_JOBS_JSON")"
  eq "$VERD" "never-ran" "M3: the mutant still PRINTS the right word"
  if [ "$RC" = "23" ]; then bad "M3: the exit-code assertion did NOT go red — the suite is only checking the word"
  else ok; fi
fi
MUT_CH=""

# M4 — neuter the one-line sanitizer. Its failure mode is pure silence: every ordinary job name
# passes through `s1` unchanged, so a `def s1: .` reads identically on every real repo and only
# breaks on the one input nobody has locally. That is exactly the class this section exists for.
if mutate "M4 the one-line sanitizer neutered" \
          '    def s1: tostring | gsub("[\\n\\r\\t]+"; " ");' \
          's@def s1: tostring | gsub(.*$@def s1: tostring;@'; then
  MOUT="$(printf '%s' "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' "$NASTY" "$NASTY_ANN")" \
          | bash "$MUT_CH" classify-doc 2>/dev/null)"
  if [ "$(printf '%s\n' "$MOUT" | wc -l | tr -d ' ')" = "2" ]; then
    bad "M4: the two-line-contract assertion did NOT go red — it is not testing the sanitizer"
  else ok; fi
fi
MUT_CH=""

# M5 — restore `(.steps // [])`, the exact fail-open independent review found. A job whose `steps`
# field never arrived then reads as a job that executed nothing, which is this module's most
# consequential verdict manufactured out of an unread field. The most important mutation here.
if mutate "M5 a missing steps array reads as an empty one" \
          '      elif ($jobs | map((has("steps") | not) or ((.steps | type) != "array")) | any) then' \
          's@elif ($jobs | map((has("steps") | not) or ((.steps | type) != "array")) | any) then@elif false then@'; then
  MOUT="$(printf '%s' "$(doc '{"status":"completed","conclusion":"failure","created_at":"2026-08-06T19:34:34Z"}' \
                             '{"total_count":1,"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"failure"}]}')" \
          | bash "$MUT_CH" classify-doc 2>/dev/null)"; MRC=$?
  if [ "$MRC" = "20" ]; then bad "M5: the missing-steps assertion did NOT go red"; else ok; fi
  has "$MOUT" "never-ran" "M5: ...and without the guard an unread steps field really does read as never-ran"
fi
MUT_CH=""

# M6 — point the jobs read back at the moving `filter=latest` endpoint. Its failure mode is a RACE,
# so it is invisible to every assertion about a verdict; only the negative call-recording assertion
# catches it, which is exactly why that assertion is written as a negative.
if mutate "M6 the jobs read is un-anchored from the attempt" \
          '  jobsraw="$(gh api --paginate "repos/$slug/actions/runs/$OPT_RUN/attempts/$attempt/jobs?per_page=100" 2>/dev/null)" \' \
          's@/attempts/\$attempt/jobs@/jobs@'; then
  live classify --run 31126981959 --repo BWBama85/thewilsonnet --no-annotations
  case "$(cat "$S/calls")" in
    *"/attempts/1/jobs"*) bad "M6: the attempt-anchoring assertion did NOT go red" ;;
    *) ok ;;
  esac
  has "$(cat "$S/calls")" "runs/31126981959/jobs" "M6: ...and the mutant really does use the moving endpoint"
fi
MUT_CH=""

check_summary "ci-health"
