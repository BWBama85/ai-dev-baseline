#!/usr/bin/env bash
# ai-dev-baseline — mocked-`gh` end-to-end harness for /roadmap (#75).
#
# WHAT THIS ADDS THAT check-roadmap.sh DOES NOT. That suite tests the LIBRARY predicates against
# fixture JSON, and lints the workflow's prose for drift. Neither proves the thing that actually
# breaks in practice: that the shell the workflow TELLS AN AGENT TO RUN works. A snippet can be
# perfectly linted and still reference an undefined variable, mis-parse a `gh` response, or fall
# through a `case` on an error — and the first person to find out is whoever runs /roadmap.
#
# So this harness EXTRACTS each documented snippet from base/workflows/roadmap.md by its
# `# ADB-SNIPPET: <name>` marker and EXECUTES IT, unmodified, against a stub `gh` driven by
# fixtures. That makes doc↔behavior drift a test failure: edit the fenced command into something
# broken and this goes red, which a prose lint can never do.
#
# docs/roadmap-acceptance.md is the specification (issue #75); the cases automated here are marked
# there. What stays manual is the genuinely agent-judgment half — bundling by subsystem,
# tracker-only vs owner-review classification, the artifact's prose — which no stub can decide.
#
# OFFLINE: no network, no real repo, no `gh`. Requires bash + jq.
# Usage: bash scripts/check-roadmap-e2e.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RL="$ROOT/scripts/lib/roadmap-lib.sh"
WF="$ROOT/base/workflows/roadmap.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

if ! command -v jq >/dev/null 2>&1; then
  echo "check-roadmap-e2e: FATAL — jq is required to run these tests" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/adb-roadmap-e2e.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
FIX="$work/fix"; SBIN="$work/sbin"
mkdir -p "$FIX" "$SBIN"

# ============================================================================================
# The stub `gh`
# ============================================================================================
# Answers reads from $ADB_FIX fixtures and records every mutation to $ADB_FIX/calls. It applies
# `--jq` with REAL jq rather than pre-baking filtered output: the filters are part of what the
# workflow documents, so a snippet whose jq program is wrong must fail here.
check_write_stub "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
set -u
F="$ADB_FIX"
fail_if() { [ -f "$F/fail-$1" ] && { echo "gh: simulated failure ($1)" >&2; exit 1; }; return 0; }
# Collect the pieces we care about out of gh's argv.
sub="${1:-}"; shift 2>/dev/null || true
sub2="${1:-}"
jqexpr=""; url=""; qval=""; bodyfile=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    --jq)        i=$((i+1)); jqexpr="${args[$i]:-}" ;;
    # Every spelling gh accepts for a raw string field, not just the one the snippets use today
    # (#376 review): a `-f q=` rewritten to `--raw-field q=` must not silently route the search
    # arm to the wrong fixture. The arm itself refuses a query this parse did not capture.
    -f|-F|--raw-field) i=$((i+1)); v="${args[$i]:-}"; case "$v" in q=*) qval="${v#q=}" ;; esac ;;
    --body-file) i=$((i+1)); bodyfile="${args[$i]:-}" ;;
    repos/*|search/*) [ -z "$url" ] && url="$a" ;;
  esac
  i=$((i+1))
done

emit() {  # emit <file> — print the fixture, applying --jq when one was given
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" < "$1"; else cat "$1"; fi
}

# default_branch — the branch this repo declares, from $F/repo's defaultBranchRef: the ONE source
# (#376 review — a second `default-branch` fixture duplicated it, already disagreeing in the
# newline case, and its `|| echo main` fell OPEN into the very assumption the branch-addressed
# arms exist to police). A missing/unreadable repo fixture is a harness defect, not a scenario:
# fail CLOSED, distinct from both the 90 "unhandled" and a simulated gh failure. Callers must
# `db="$(default_branch)" || exit` — the exit here only leaves the substitution's subshell.
default_branch() {
  jq -re '.defaultBranchRef.name // empty' "$F/repo" 2>/dev/null && return 0
  echo "gh stub: cannot derive the default branch from \$ADB_FIX/repo" >&2
  exit 91
}

case "$sub" in
  auth) exit 0 ;;
  repo)
    fail_if repo
    # A real JSON object, run through the caller's OWN --jq — so a snippet asking for
    # `.nameWithOwner` and one asking for `.nameWithOwner, .defaultBranchRef.name` each get
    # exactly what they requested, and a snippet that asks for a field the fixture lacks fails
    # here instead of silently receiving the whole blob.
    emit "$F/repo" ;;
  api)
    case "$url" in
      search/issues)
        fail_if search
        # Two search reads are documented (#376 review): fresh-read's completeness cross-check
        # (unscoped) and the label gauge (label:-qualified). Answer each from its own fixture, so
        # a gauge that lost its label scoping reads the unscoped count and fails as a wrong
        # number. A query the parse did not capture is refused loudly rather than routed to a
        # default — that is how a rewritten flag spelling would silently pick a fixture.
        [ -n "$qval" ] || { echo "gh stub: search/issues read with no captured q= — teach the argv parse its spelling" >&2; exit 90; }
        case "$qval" in
          *label:*) emit "$F/search-label.json" ;;
          *)        emit "$F/search-total.json" ;;
        esac ;;
      */labels/*)
        lbl="${url##*/labels/}"
        grep -qx "$lbl" "$F/labels.txt" 2>/dev/null || { echo "gh: Not Found" >&2; exit 1; }
        printf '{"name":"%s"}\n' "$lbl" ;;
      # --- #78 branch health: three distinct reads, each independently failable ---------------
      # Ordered before the bare `repos/OWNER/REPO` arm below, which would otherwise swallow them.
      # SHA-ANCHORED, like the snippet that calls it (#376 review): health is only meaningful
      # about the commit the status read resolved, so this arm answers for THAT sha and no other
      # ref. Real GitHub also accepts a BRANCH name here, so before this guard a snippet
      # rewritten to branch-addressed `commits/$DEFAULT_BRANCH/check-runs` — reopening the
      # stale-evidence race the anchoring prevents — passed every case.
      */check-runs*)
        fail_if checkruns
        ref="${url#*/commits/}"; ref="${ref%%/check-runs*}"
        sha="$(jq -r '.sha // empty' "$F/commit-status.json" 2>/dev/null)" || sha=""
        { [ -n "$sha" ] && [ "$ref" = "$sha" ]; } || { echo "gh: Not Found (no commit '$ref')" >&2; exit 1; }
        emit "$F/check-runs.json" ;;
      # The BRANCH-ADDRESSED reads answer only for the branch this repo actually declares as its
      # default (#376). Without that, a snippet that hard-coded `main` behaved identically to one
      # that resolved `defaultBranchRef` live, because the fixture's default IS `main` — so the
      # rule "never assume main" was unexecutable and only a token pin could watch it.
      # The ref is stripped of any query string the same way in both arms.
      */commits/*/status*)
        fail_if commitstatus
        ref="${url#*/commits/}"; ref="${ref%%/status*}"; ref="${ref%%\?*}"
        db="$(default_branch)" || exit
        [ "$ref" = "$db" ] || { echo "gh: Not Found (no branch '$ref')" >&2; exit 1; }
        emit "$F/commit-status.json" ;;
      */actions/workflows*)
        fail_if workflows
        emit "$F/workflows.json" ;;
      # #115: the provider-agnostic existence probe. Ordered with the other health reads and BEFORE
      # the bare `repos/OWNER/REPO` arms below, which would otherwise swallow it.
      */branches/*)
        fail_if branch
        b="${url##*/branches/}"; b="${b%%\?*}"
        db="$(default_branch)" || exit
        [ "$b" = "$db" ] || { echo "gh: Not Found (no branch '$b')" >&2; exit 1; }
        emit "$F/branch.json" ;;
      # #115: the artifact author's REPOSITORY PERMISSION, which authorizes the health opt-out. An
      # ABSENT fixture models an unreadable permission (the endpoint itself needs push access, so a
      # 403 is a real outcome) and must exit non-zero, so the snippet fails closed rather than
      # reading an empty body as authority.
      */collaborators/*/permission)
        [ -f "$F/permission.json" ] || { echo "gh: Not Found" >&2; exit 1; }
        emit "$F/permission.json" ;;
      *issues\?milestone=*)
        fail_if milestone
        emit "$F/milestone-issues.json" ;;
      *milestones\?state=open*)
        fail_if milestones
        emit "$F/milestones.json" ;;
      *issues\?state=open*)
        fail_if openissues
        emit "$F/open-issues.json" ;;
      # A single issue by number — the canceled-prerequisite probe, and (#115) the roadmap ARTIFACT
      # read, which the readiness snippet makes for the `release-health` opt-out marker and the
      # author association that authorizes it. Both are served by the same per-number fixture, so
      # the artifact is just `issue-<ROADMAP_NUM>.json`. Absent fixture => a normal completed close,
      # which is the common case and must NOT read as canceled.
      */issues/[0-9]*)
        fail_if artifact
        n="${url##*/issues/}"; n="${n%%\?*}"
        if [ -f "$F/issue-$n.json" ]; then emit "$F/issue-$n.json"
        else printf '{"number":%s,"state":"closed","state_reason":"completed"}\n' "$n" | { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
        fi ;;
      *) echo "gh stub: unhandled api url: $url" >&2; exit 90 ;;
    esac ;;
  issue)
    case "$sub2" in
      list)
        fail_if issuelist
        cat "$F/roadmap-nums" 2>/dev/null || true ;;
      edit|create|comment)
        # Record the FULL argv. `${args[0]}` is the subcommand itself (argv is shifted once, so it
        # re-prints "edit"), which meant the issue NUMBER never reached the log — and an assertion
        # like `grep 'issue edit 44'` could therefore never match, passing whatever the snippet did.
        # The flags matter too now: composition's correctness is "promoted AND labelled", and a
        # promotion that dropped `--add-label release-blocker` arms a phantom cut.
        printf 'issue %s %s\n' "$*" "${bodyfile:+body-file}" >> "$F/calls"
        # `fail-edit-after N` fails every PROMOTION past the Nth, so a partial composition — and the
        # rollback that must follow it — can be driven. Counted on `--add-label`, which only
        # promotions carry, so the rollback's own edits never trip it.
        if [ -f "$F/fail-edit-after" ]; then
          lim="$(cat "$F/fail-edit-after")"
          cnt="$(grep -c -- '--add-label' "$F/calls" 2>/dev/null || true)"
          [ "${cnt:-0}" -gt "${lim:-0}" ] && { echo "gh: simulated edit failure" >&2; exit 1; }
        fi
        printf 'https://example.invalid/issues/1\n' ;;
      *) echo "gh stub: unhandled issue subcommand: $sub2" >&2; exit 90 ;;
    esac ;;
  pr)
    fail_if prlist
    emit "$F/open-prs.json" ;;
  label)
    printf 'label %s\n' "$sub2" >> "$F/calls" ;;
  *) echo "gh stub: unhandled command: $sub" >&2; exit 90 ;;
esac
STUB

# ============================================================================================
# Snippet extraction — the point of the harness
# ============================================================================================
# snippet <name> — the fenced bash between `# ADB-SNIPPET: <name>` and the closing fence.
# Delegates to check_wf_snippet (check-lib.sh), the ONE home for the marker/closing-fence
# contract — three suites execute documented snippets and three copies of this awk could drift.
snippet() { check_wf_snippet "$WF" "$1"; }

# run_snippet <name> [tail-code] — execute the documented snippet against the stub, with the
# {{ROADMAP_LIB}} placeholder resolved exactly as scripts/build.sh resolves it for a real agent.
# Prints the snippet's stdout (plus the tail's); sets RC_ to its exit status.
run_snippet() {
  local name="$1" tail_code="${2:-}" code
  code="${ snippet "$name"; }"
  if [ -z "$code" ]; then
    bad "snippet '$name' not found in base/workflows/roadmap.md (marker removed or renamed?)"
    RC_=90; OUT=""; return 1
  fi
  printf '%s\n' "$name" >> "$work/ran"   # the executed-name ledger the section-8 set guard audits
  code="${code//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}"
  code="${code//\{\{REPO_SETTINGS_LIB\}\}/bash \"$ROOT/scripts/lib/repo-settings.sh\"}"
  # {{ACTIONS_APP_SLUG}} is resolved THE WAY build.sh RESOLVES IT — from `adb_actions_app_slug`,
  # the one home — not from a literal restated here. A hard-coded copy in this harness is exactly
  # what let #179 ship: the fixtures agreed with the code about a value GitHub never returns, so
  # the suite was green while `branch-health` could not reach `green` on any Actions repo. The
  # LITERAL is pinned once, deliberately, in check-roadmap.sh section 4d and check-common-lib.sh.
  code="${code//\{\{ACTIONS_APP_SLUG\}\}/$ACTIONS_SLUG}"
  # The preamble supplies exactly what an EARLIER step would have produced — the selected member,
  # the resolved milestone number, the artifact number, the adopt candidate, the configured gauge
  # label, and the SELECTED BUNDLE'S member classifications (#352: step 4's four-state judgment,
  # which no `gh` read can produce because it is the agent's). Nothing else: anything a snippet
  # needs beyond these it must resolve itself, which is the property the workflow states and the
  # reason two snippets were found relying on a caller's variables.
  #
  # ADB_UNSET names preamble variables to leave UNSET, which is how a snippet's own defaulting is
  # exercised (#376). A snippet that writes `${LABEL:-}` or `${NO_AUTOFIX:-0}` is claiming to
  # tolerate an absent input; with the preamble always assigning one, that claim is untestable and
  # only a token pin could watch it. Unsetting after the assignments keeps the list in one place
  # instead of wrapping every line in a conditional. The word-split is deliberate: the value is a
  # space-separated variable list written by this file, never by a fixture.
  OUT="$(
    PATH="$SBIN:$PATH" ADB_FIX="$FIX" bash -c "
      set -u
      N=\${ADB_N:-1}
      M_NUM=\${ADB_M_NUM:-9}
      ROADMAP_NUM=\${ADB_ROADMAP_NUM:-31}
      CAND=\${ADB_CAND:-7}
      LABEL=\${ADB_LABEL-release-blocker}
      BACKLOG_TITLE=\${ADB_BACKLOG:-Backlog}
      NO_AUTOFIX=\${ADB_NO_AUTOFIX:-0}
      RELEASE_MODE=\${ADB_RELEASE_MODE:-0}
      COMPOSE_EXCLUDE=\${ADB_EXCLUDE-}
      MEMBERS=\${ADB_MEMBERS-}
      [ -z \"\${ADB_UNSET:-}\" ] || unset -v \$ADB_UNSET
      $code
      $tail_code
    " 2>&1
  )"
  RC_=$?
  printf '%s' "$OUT"
}

# --- fixture writers -------------------------------------------------------------------------
# Every scenario starts from fix_default, so no case inherits another's edits.
fix_default() {
  # Per-number issue fixtures are reset too (#376 review): a leaked issue-7.json outlives its
  # case, permanently shadows the stub's documented per-number fallback, and falsifies the
  # sentence above. artifact_fx rewrites #31 below.
  rm -f "$FIX"/fail-* "$FIX/calls" "$FIX"/issue-*.json
  printf '{"nameWithOwner":"acme/widget","defaultBranchRef":{"name":"main"}}\n' > "$FIX/repo"
  printf '31\n'                          > "$FIX/roadmap-nums"
  printf 'release-blocker\nroadmap\n'    > "$FIX/labels.txt"
  printf '[]\n'                          > "$FIX/open-prs.json"
  open_issues 5 12 31
  printf '{"total_count":3}\n'           > "$FIX/search-total.json"
  printf '{"total_count":1}\n'           > "$FIX/search-label.json"
  printf '[]\n'                          > "$FIX/milestone-issues.json"
  printf '[{"number":8,"title":"Backlog"},{"number":9,"title":"Next release"}]\n' > "$FIX/milestones.json"
  # The roadmap ARTIFACT as the readiness snippet reads it (#115): a body with NO `release-health`
  # marker, authored by a maintainer. Both fields matter — the marker decides whether the opt-out is
  # declared, `author_association` decides whether it is honoured.
  artifact_fx '' write
  health_green
}
# artifact_fx <body> <author_association> — the roadmap artifact issue, served through the stub's
# per-number fixture. `--arg` rather than interpolation: a body carries newlines and quotes.
# The AUTHOR'S REPOSITORY PERMISSION is what authorizes the opt-out, not the issue author's
# association: an org `MEMBER` can hold read-only access and a `COLLABORATOR` can be read or triage,
# so the association set admits accounts that could never push a line of code. `permission` is the
# `collaborators/{user}/permission` answer the stub serves; empty models an unreadable one (a 403),
# which must fail closed.
artifact_fx() {
  jq -n --arg b "$1" --argjson n "${ADB_ROADMAP_NUM:-31}" \
     '{number:$n, state:"open", state_reason:null, body:$b, user:{login:"artifact-author"}}' \
     > "$FIX/issue-${ADB_ROADMAP_NUM:-31}.json"
  if [ -n "${2-}" ]; then
    printf '{"permission":"%s"}\n' "$2" > "$FIX/permission.json"
  else
    rm -f "$FIX/permission.json"
  fi
}
# cand_fx <number> <author_association> — the step-3 adopt candidate, served through the stub's
# per-number issue fixture. Step 3 asks for `author_association` and nothing else, so that is the
# only field this needs beyond the identity the stub's fallback already supplies.
cand_fx() {
  printf '{"number":%s,"state":"open","author_association":"%s"}\n' "$1" "$2" > "$FIX/issue-$1.json"
}

# --- #78 branch-health fixtures ---------------------------------------------------------------
# The default is a GREEN default branch, so every pre-existing readiness case keeps asserting what
# it always asserted (a `met` milestone is still `met`) and the health-specific cases below each
# change exactly one thing.
E2E_SHA=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
# wf_arr <n> — n active workflow definitions, built without spawning jq: fix_default runs on every
# scenario, so a process here is a process paid ~35 times for a constant.
wf_arr() {
  local i=0 out=""
  while [ "$i" -lt "$1" ]; do
    [ -z "$out" ] || out="$out,"
    out="$out{\"state\":\"active\"}"
    i=$((i+1))
  done
  printf '[%s]' "$out"
}
# health_set <check-runs-json> <statuses-json> <active-workflow-count> [branch-json]
# The commit-status fixture carries `sha` because that is where the snippet resolves HEAD from —
# one request answering both "which commit" and "what do the non-Actions providers say".
#
# The BRANCH fixture is the provider-agnostic existence probe (#115). It defaults to an
# authoritatively UNPROTECTED branch — declaring no required contexts — because that is what every
# pre-#115 scenario implicitly assumed, so each keeps its original verdict and only the new cases
# vary it. Pass `br_checks`/`br_ruleset` to model a branch that declares contexts or one whose
# protection this endpoint cannot describe.
health_set() {
  printf '{"check_runs":%s}\n' "$1"                          > "$FIX/check-runs.json"
  printf '{"sha":"%s","state":"x","statuses":%s}\n' "$E2E_SHA" "$2" > "$FIX/commit-status.json"
  printf '{"workflows":%s}\n' "${ wf_arr "$3"; }"               > "$FIX/workflows.json"
  printf '%s\n' "${4:-${ br_unprotected; }}"                    > "$FIX/branch.json"
}
# The three branch-endpoint shapes, spelled once. `br_ruleset` is verbatim what github/docs and
# vercel/next.js really return: `contexts` IS a real empty array there, which is why an array-only
# test would read a ruleset-protected branch as "requires nothing" and let it reach `no-ci`.
br_unprotected() { printf '{"protected":false}'; }
br_checks()      { printf '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":[%s]}}}' "$1"; }
br_ruleset()     { printf '{"protected":true,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[]}}}'; }
# ck1 <status> <conclusion-json> [sha] [app-slug] — the single-check-run fixture the health cases
# vary. The app slug defaults to the value an Actions-produced check run really carries, read from
# its one home (common.sh) rather than restated — the hard-coded `github` that used to sit here
# agreed with the two libraries about a value GitHub never returns, which is what let #179 ship.
# This suite drives the WORKFLOW end to end, so it is also the check that the snippet and the
# predicate attribute against the same value.
check_actions_slug
ck1() { printf '[{"name":"ci","head_sha":"%s","status":"%s","conclusion":%s,"app":{"slug":"%s"}}]' \
          "${3:-$E2E_SHA}" "$1" "$2" "${4:-$ACTIONS_SLUG}"; }
health_green()  { health_set "${ ck1 completed '"success"'; }" '[]' 1; }
health_red()    { health_set "${ ck1 completed '"failure"'; }" '[]' 1; }
health_running(){ health_set "${ ck1 in_progress null; }"      '[]' 1; }
health_stale()  { health_set "${ ck1 completed '"success"' deadbeefdeadbeefdeadbeef; }" '[]' 1; }
health_no_ci()  { health_set '[]' '[]' 0; }
health_norun()  { health_set '[]' '[]' 2; }
# A non-Actions provider reports only through the legacy status API.
health_legacy_red() { health_set '[]' '[{"context":"vercel","state":"failure"}]' 0; }

# limbo_issues <spec>... — an open-issue fixture where `<n>` is unmilestoned and `<n>:M` is in
# milestone M. This is what step 4b selects on, so the fixture has to model it directly.
limbo_issues() {
  { printf '['
    local first=1 spec n ms
    for spec in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      n="${spec%%:*}"; ms="${spec#*:}"
      # A `!` suffix on the number labels the issue `release-blocker` — the #78 carve-out is
      # keyed on labels, so a fixture that never emits a `labels` array cannot exercise it.
      # A trailing `^` (outermost, so `N!^` combines) makes the entry a PULL REQUEST: the
      # `issues?state=open` endpoint returns PRs too, and both jq filters in the snippet must
      # drop them — a fixture without one left `select(has("pull_request") | not)` deletable
      # with every suite green (#376 review).
      local labels='[]' prfrag=''
      case "$n" in *'^') n="${n%^}"; prfrag='"pull_request":{"url":"x"},' ;; esac
      case "$n" in *'!') n="${n%!}"; labels='[{"name":"release-blocker"}]' ;; esac
      if [ "$ms" = "$spec" ]; then
        printf '{"number":%s,"state":"open","title":"i%s","body":"",%s"labels":%s,"milestone":null}' "$n" "$n" "$prfrag" "$labels"
      else
        printf '{"number":%s,"state":"open","title":"i%s","body":"",%s"labels":%s,"milestone":{"title":"%s"}}' "$n" "$n" "$prfrag" "$labels" "$ms"
      fi
    done
    printf ']\n'
  } > "$FIX/open-issues.json"
}

# open_issues <n>... — an open-issue fixture in the `repos/../issues` shape.
open_issues() {
  { printf '['
    local first=1 n
    for n in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"number":%s,"state":"open","title":"issue %s","body":"","labels":[]}' "$n" "$n"
    done
    printf ']\n'
  } > "$FIX/open-issues.json"
}

# ============================================================================================
# 1. LOCATE THE ARTIFACT — the split-brain contract (acceptance §1, §2)
# ============================================================================================
fix_default
run_snippet locate-artifact 'printf "COUNT=%s NUM=%s\n" "$COUNT" "$(printf "%s" "$ROADMAP_NUM" | tr "\n" ",")"' >/dev/null
eq "$RC_" 0 "locate-artifact runs clean against the stub"
has "$OUT" "COUNT=1 NUM=31" "exactly one labeled artifact resolves to it (the ordinary path)"

printf '' > "$FIX/roadmap-nums"
run_snippet locate-artifact 'printf "COUNT=%s\n" "$COUNT"' >/dev/null
has "$OUT" "COUNT=0" "no labeled artifact counts 0 (the bootstrap path, not an error)"

printf '31\n52\n' > "$FIX/roadmap-nums"
run_snippet locate-artifact 'printf "COUNT=%s\n" "$COUNT"' >/dev/null
has "$OUT" "COUNT=2" "two labeled artifacts count 2 (the split-brain STOP the workflow must never guess through)"

# ============================================================================================
# 2. ADOPT SCAN — a pre-existing roadmap must be found at ANY backlog size (#79 + acceptance §2)
# ============================================================================================
# The old scan was `gh issue list --limit 200`. A hand-maintained roadmap sitting past the cap was
# missed, and step 3 then CREATED a second artifact — manufacturing the very split-brain step 2
# hard-stops on. Prove the paginated scan finds a candidate buried behind 250 newer issues.
fix_default
{ printf '['
  i=250
  while [ "$i" -ge 2 ]; do
    printf '{"number":%s,"state":"open","title":"noise %s","body":"nothing"},' "$i" "$i"
    i=$((i-1))
  done
  printf '{"number":1,"state":"open","title":"Old plan","body":"<!-- ai-dev-baseline:roadmap:v1 -->"}]\n'
} > "$FIX/open-issues.json"
run_snippet adopt-scan 'printf "NCAND=%s CANDS=%s\n" "$NCAND" "$(printf "%s" "$CANDS" | tr "\n" ",")"' >/dev/null
eq "$RC_" 0 "adopt-scan runs clean"
has "$OUT" "NCAND=1 CANDS=1" "the marked roadmap is found behind 250 newer issues (no page cap), and it is the right issue"

# A title-matched candidate is found too, and a PR carrying the marker is NOT a candidate.
fix_default
printf '[{"number":9,"state":"open","title":"Roadmap & execution order","body":"x"},
        {"number":8,"state":"open","title":"pr","body":"<!-- ai-dev-baseline:roadmap:v1 -->","pull_request":{"url":"x"}}]\n' \
  > "$FIX/open-issues.json"
run_snippet adopt-scan 'printf "NCAND=%s CANDS=%s\n" "$NCAND" "$(printf "%s" "$CANDS" | tr "\n" ",")"' >/dev/null
has "$OUT" "NCAND=1 CANDS=9" "a title-matched roadmap is the only candidate — a PR carrying the marker is NOT adopted as the artifact"

# ============================================================================================
# 2b. ADOPT OWNERSHIP — the precondition beyond "exactly one candidate" (#376)
# ============================================================================================
# The ninth documented snippet, and the last one nothing executed. Adopting an issue opened by an
# outside account makes a canonical artifact whose body that account keeps rewriting — while step 4
# reads its `## Decisions` rows as maintainer decisions and the release roll archives from its
# marker. So the gate is load-bearing in the same way the health opt-out's authority check is, and
# it deserves the same instrument.

# Each of the three standings GitHub reports for an account that could have edited these workflows
# anyway adopts silently: the gate adds nothing for them, so it must cost nothing either.
for assoc in OWNER MEMBER COLLABORATOR; do
  fix_default; cand_fx 7 "$assoc"
  run_snippet adopt-ownership 'printf "ADOPTED\n"' >/dev/null
  eq "$RC_" 0 "a $assoc-authored candidate passes the ownership gate"
  has "$OUT" "ADOPTED" "...and the run continues into the adopt branch"
  hasnt "$OUT" "adopt-untrusted-author" "...with no escalation raised"
done

# Anything else is an ESCALATION, not a pick — and specifically not a hard stop: the operator is
# being asked a question, and a run that died here would take the rest of the roadmap with it.
for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR; do
  fix_default; cand_fx 7 "$assoc"
  run_snippet adopt-ownership 'printf "ADOPTED\n"' >/dev/null
  eq "$RC_" 0 "a $assoc-authored candidate does not crash the run"
  has "$OUT" "? adopt-untrusted-author:#7" "...it escalates with the stable id"
  has "$OUT" "$assoc account" "...naming the standing it actually read"
  has "$OUT" "Record:" "...and where to record the answer"
  hasnt "$OUT" "ADOPTED" "...and the adopt branch is NOT entered"
done

# THE CANDIDATE NUMBER IS AN INPUT, NOT A CONSTANT (#376 review). Every case above rides the
# preamble default (7), so a snippet that hard-coded the number behaved identically — the same
# fixture-agrees-with-default class the trunk-branch case closes for `main`. 13 is served only by
# its own fixture: a literal-7 snippet reads the stub's per-number FALLBACK, which carries no
# author_association, and the gate cannot pass it.
fix_default; cand_fx 13 OWNER
ADB_CAND=13 run_snippet adopt-ownership 'printf "ADOPTED\n"' >/dev/null
eq "$RC_" 0 "a candidate that is NOT the preamble default runs clean"
has "$OUT" "ADOPTED" "...and passes the gate on its own fixture — the snippet addresses \$CAND, not a literal"
hasnt "$OUT" "adopt-untrusted-author" "...with no escalation raised"

# A failed read is a hard stop, like every other read in this workflow: `--jq` on an errored
# response yields an empty association, which would fall through the `case` to the escalation arm
# and report a candidate as untrusted on the strength of an API failure.
fix_default; cand_fx 7 OWNER; : > "$FIX/fail-artifact"
run_snippet adopt-ownership 'printf "ADOPTED\n"' >/dev/null
no "$RC_" "a failing author-association read hard-stops"
has "$OUT" "could not read #7's author association" "...failing for THAT read, not for an unrelated error"
hasnt "$OUT" "ADOPTED" "...and adopts nothing"

# ============================================================================================
# 3. THE FRESH READ — completeness, in-flight, and the hard stops (#79, acceptance §5)
# ============================================================================================

# --- 3a. a backlog PAST the old 200 cap reconciles completely (the #79 acceptance) ----------
fix_default
seq_nums=""; i=1
while [ "$i" -le 231 ]; do seq_nums="$seq_nums $i"; i=$((i+1)); done
# shellcheck disable=SC2086  # deliberate word-split into the fixture writer's argument list
open_issues $seq_nums
printf '{"total_count":231}\n' > "$FIX/search-total.json"
ADB_N=1 run_snippet fresh-read 'printf "GOT=%s EXPECTED=%s\n" "$GOT" "$EXPECTED"' >/dev/null
eq "$RC_" 0 "a 231-issue backlog reads clean (past the old --limit 200)"
has "$OUT" "GOT=231 EXPECTED=231" "every open issue is read — completeness verified against total_count"

# --- 3b. an artificially TRUNCATED read fails loudly ----------------------------------------
# This is the dangerous direction and the reason the check exists: an open issue missing from the
# read is reconciled to `Done`, so a partial read deletes real work from the plan.
fix_default
# shellcheck disable=SC2086
open_issues 1 2 3
printf '{"total_count":231}\n' > "$FIX/search-total.json"
ADB_N=1 run_snippet fresh-read >/dev/null
no "$RC_" "a short read is a HARD STOP, not a silently partial roadmap"
has "$OUT" "read 3 of 231 open issues" "the hard stop names how much it actually read"

# --- 3c. the Search index lagging BEHIND the read is benign ---------------------------------
fix_default
open_issues 5 12 31 40
printf '{"total_count":3}\n' > "$FIX/search-total.json"
ADB_N=5 run_snippet fresh-read 'printf "OK\n"' >/dev/null
eq "$RC_" 0 "reading MORE than the index reports proceeds (an issue filed mid-read is not truncation)"

# --- 3d. a SATURATED open-PR read is treated as possibly truncated --------------------------
fix_default
{ printf '['
  i=1
  while [ "$i" -le 1000 ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"number":%s,"body":"noise","closingIssuesReferences":[]}' "$i"
    i=$((i+1))
  done
  printf ']\n'
} > "$FIX/open-prs.json"
ADB_N=5 run_snippet fresh-read >/dev/null
no "$RC_" "an open-PR read that exactly saturates the cap is a hard stop"
has "$OUT" "possibly truncated" "...and says why"

# --- 3e. a failing gh read is a hard stop, never an empty set -------------------------------
for kind in openissues prlist search; do
  fix_default
  : > "$FIX/fail-$kind"
  ADB_N=5 run_snippet fresh-read >/dev/null
  no "$RC_" "a failing '$kind' read hard-stops (an errored gh must never read as 'nothing open')"
done
# ...and specifically NOT by luck. A pipeline reports only its last command's status, so
# `gh api … | open-issues` returns 0 on a failed read (the parser sees empty stdin = an empty
# repo). The read must be captured and checked on its OWN status, or the hard stop depends on the
# completeness cross-check happening to disagree — which it would not if both reads failed.
fix_default; : > "$FIX/fail-openissues"
ADB_N=5 run_snippet fresh-read >/dev/null
has "$OUT" "could not list open issues" \
   "the failing READ is what reports, not a downstream count mismatch"

# --- 3f. in-flight targeting, end to end through the documented snippet (acceptance §5) -----
# The #69 regression at the level that actually ships: the snippet, not the predicate.
fix_default
printf '[{"number":100,"body":"Refs #5","closingIssuesReferences":[]}]\n' > "$FIX/open-prs.json"
ADB_N=5 run_snippet fresh-read 'printf "%s" "$OPEN_PRS" | bash "'"$RL"'" pr-targets-issue 5 "$REPO"; printf "TARGETS=%s\n" "$?"' >/dev/null
has "$OUT" "TARGETS=1" "a bare 'Refs #5' does NOT freeze #5 (the #69 bug, through the real snippet)"
printf '[{"number":100,"body":"Closes #5","closingIssuesReferences":[]}]\n' > "$FIX/open-prs.json"
ADB_N=5 run_snippet fresh-read 'printf "%s" "$OPEN_PRS" | bash "'"$RL"'" pr-targets-issue 5 "$REPO"; printf "TARGETS=%s\n" "$?"' >/dev/null
has "$OUT" "TARGETS=0" "a PR that actually closes #5 DOES freeze it"

# --- 3g-bis. a member CLOSED since step 4 is dropped, without a loop-only `continue` (#376) --
# The per-member check is a bare `if` with no enclosing loop, so writing it as `… || continue` is
# the tempting spelling and the broken one: bash only WARNS and then FALLS THROUGH, which re-emits
# an issue that closed since reconcile, while zsh aborts the block outright. Both are wrong, and
# the warning is the executable evidence — it lands on stderr of the run itself, which this harness
# captures. #44 is absent from the open set, so the drop path is the one taken here.
#
# The tail also proves SELF-CONTAINMENT: `$REPO` and `$NPR` exist only because the snippet resolved
# them from its own reads. The preamble supplies neither, and the run is under `set -u`, so a slug
# hoisted from an earlier step would abort here rather than silently addressing `repos//…`.
#
# LC_ALL=C, because the `hasnt` witness below is bash's OWN warning text and bash localizes it
# (de_DE prints "nur in einer for-, while- oder until-Schleife sinnvoll") — unpinned, the check
# passes vacuously on any non-English workstation (#376 review). A temp assignment on a function
# call does not outlive it, so nothing later inherits the pin.
fix_default
ADB_N=44 LC_ALL=C run_snippet fresh-read 'printf "DROPPED REPO=%s NPR=%s\n" "$REPO" "$NPR"' >/dev/null
eq "$RC_" 0 "a member that closed since step 4 is dropped without stopping the run"
has "$OUT" "DROPPED REPO=acme/widget NPR=0" "...and the snippet resolved the slug and the open-PR set itself"
hasnt "$OUT" "only meaningful in" \
  "...through a bare 'if', never a loop-only 'continue' (which bash falls through, re-emitting the closed member)"

# --- 3g. determinism: same fixtures, byte-identical output (acceptance §6) ------------------
fix_default
ADB_N=5 run_snippet fresh-read 'printf "%s|%s|%s\n" "$GOT" "$EXPECTED" "$(printf "%s" "$OPEN_NUMS" | tr "\n" ",")"' >/dev/null
first="$OUT"
ADB_N=5 run_snippet fresh-read 'printf "%s|%s|%s\n" "$GOT" "$EXPECTED" "$(printf "%s" "$OPEN_NUMS" | tr "\n" ",")"' >/dev/null
eq "$OUT" "$first" "two runs over an unchanged tracker produce identical reads"

# ============================================================================================
# 3h. OWNER-ACTION — a ready bundle whose FIRST action is the owner's (#352, acceptance §4b)
# ============================================================================================
# The defect this executes: a bundle rendered `ready`, prose twenty lines later declared "no
# agent-implementable bundle", and the owner's step arrived as trailing prose on the terminal line
# — where nothing parses it and an operator reading only the last line sees `Next: none`. The
# state now has a name, a predicate and a terminal string, and this is the run that proves the
# three agree. TAB-separated records, exactly as the snippet's contract states: a space-separated
# copy would put the whole record in field 1 and hard-stop, which is the fail-closed direction.
OA_ONE=$'#12\towner-action\tset the DEPLOY_TOKEN repo secret; #12 is otherwise ready.'
OA_TWO=$'#12\towner-action\tset the DEPLOY_TOKEN repo secret; #12 is otherwise ready.\n#13\towner-action\tgrant the deploy app write access to this repo.'
OA_MIX=$'#12\towner-action\tset the DEPLOY_TOKEN repo secret; #12 is otherwise ready.\n#5\timplementable\t'
OA_DEAD=$'#35\ttracker-only\t\n#36\towner-review\t'

last_line() { printf '%s\n' "$1" | sed -e '/^$/d' | tail -1; }

fix_default
ADB_MEMBERS="$OA_ONE" run_snippet owner-action >/dev/null
eq "$RC_" 0 "a bundle whose every buildable member is owner-action emits a terminal report, not an error"
has "$OUT" '! owner-action:#12 — set the DEPLOY_TOKEN repo secret; #12 is otherwise ready.' \
  "the owner's step renders as an owner-action VERDICT line ('!', the slot the output contract defines)"
eq "${ last_line "$OUT"; }" 'Next: none — owner-action: do the 1 action(s) above, then re-run.' \
  "the LAST line is the state's terminal string, with no trailing prose on it"
hasnt "$OUT" '/implement-issue' \
  "owner-executed work is never emitted as /implement-issue input"
hasnt "$OUT" 'Next: none — owner-action: do the 1 action(s) above, then re-run. set the' \
  "the action is not appended to the Next: line (the shape observed in #352)"

# TWO actions: the count is the number of lines printed, not a hardcoded 1.
ADB_MEMBERS="$OA_TWO" run_snippet owner-action >/dev/null
eq "$RC_" 0 "two owner-action members still emit a terminal report"
has "$OUT" '! owner-action:#13 — grant the deploy app write access to this repo.' \
  "...one owner-action line per member"
eq "${ last_line "$OUT"; }" 'Next: none — owner-action: do the 2 action(s) above, then re-run.' \
  "...and the terminal count is derived from the members, never hardcoded"

# ONE implementable member beside it is still a `ready` bundle: the batch wins, the owner-action
# member is reported above it. An owner step must never hold agent-implementable work hostage.
ADB_MEMBERS="$OA_MIX" run_snippet owner-action 'printf "VERDICT=%s\n" "$VERDICT"' >/dev/null
eq "$RC_" 0 "a mixed bundle does not stop the run"
has "$OUT" "VERDICT=ready" "...it stays 'ready' and falls through to the ordinary advance"
hasnt "$OUT" "Next: none" "...so no terminal line is emitted for it"

# Nothing left to build routes to step 7's existing report, NOT to the new one.
ADB_MEMBERS="$OA_DEAD" run_snippet owner-action 'printf "VERDICT=%s\n" "$VERDICT"' >/dev/null
eq "$RC_" 0 "an all-flagged bundle does not stop the run"
has "$OUT" "VERDICT=tracker-only" "...it reports tracker-only, which is step 7's existing path"
hasnt "$OUT" "owner-action:" "...and never borrows the owner-action terminal string"

# FAIL-CLOSED, both ways. A word outside the four-state vocabulary and an empty member set are
# each a hard stop: a skipped member silently demotes a ready bundle and deletes work from the plan.
ADB_MEMBERS=$'#12\tmaybe-later\t' run_snippet owner-action >/dev/null
no "$RC_" "a classification outside step 4's vocabulary hard-stops the run"
has "$OUT" "emit-verdict could not classify the selected bundle" \
  "...and the snippet reports the hard stop rather than falling through to an emission"
ADB_MEMBERS="" run_snippet owner-action >/dev/null
no "$RC_" "an EMPTY member set hard-stops too (a bundle with no open member is 'done', decided earlier)"
# The snippet writes `${MEMBERS:-}`, which CLAIMS to tolerate an absent input; with the preamble
# always assigning one that claim is untestable, so unset it and watch the claim hold under `set -u`.
ADB_UNSET="MEMBERS" run_snippet owner-action >/dev/null
no "$RC_" "an UNSET member set hard-stops on the predicate, not on a set -u abort"
has "$OUT" "emit-verdict could not classify the selected bundle" \
  "...so the snippet's own defaulting is what carries it there"
# The TAB is the contract, so prove the other spelling refuses rather than guessing: `cut -f2` on a
# space-separated record returns the WHOLE record, which is not a classification word.
ADB_MEMBERS='#12 owner-action set the DEPLOY_TOKEN repo secret.' run_snippet owner-action >/dev/null
no "$RC_" "a SPACE-separated record hard-stops instead of being re-interpreted"
has "$OUT" "emit-verdict could not classify the selected bundle" \
  "...naming the classification step, so the record can be fixed rather than guessed at"

# Determinism (acceptance §6): the same members render the same bytes.
ADB_MEMBERS="$OA_TWO" run_snippet owner-action >/dev/null; oa_first="$OUT"
ADB_MEMBERS="$OA_TWO" run_snippet owner-action >/dev/null
eq "$OUT" "$oa_first" "two runs over an unchanged bundle emit byte-identical owner-action output"

# ============================================================================================
# 4. RELEASE READINESS — the documented pipeline, end to end (acceptance §9b)
# ============================================================================================
# check-roadmap.sh pins the VERDICT TABLE. What is proven here is the wiring: the label probe, the
# paginated milestone read, the three-line `release-counts` contract, and the `read` that feeds
# release-ready — the places a working predicate still yields a wrong verdict.
ms_issues() { printf '%s\n' "$1" > "$FIX/milestone-issues.json"; }
readiness() {
  run_snippet readiness 'printf "VERDICT=%s ARMED=%s BLK=%s OPEN=%s CANCELED=%s HEALTH=%s WHY=%s\n" "$VERDICT" "$ARMED" "$M_BLOCKERS" "$M_OPEN" "$CANCELED" "$HEALTH" "${HEALTH_WHY:-}"' >/dev/null
}
# A milestone whose requirements are DRAINED — the only state in which health can change the
# verdict. Every health case below starts from it, so each asserts health and nothing else.
ms_drained() {
  ms_issues '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]}]'
}

fix_default; ms_issues '[]'
readiness
eq "$RC_" 0 "the readiness pipeline runs clean"
has "$OUT" "VERDICT=unarmed" "an empty milestone is unarmed — never a cut"

fix_default
ms_issues '[{"number":78,"state":"open","state_reason":null,"labels":[{"name":"release-blocker"}]},
            {"number":94,"state":"open","state_reason":null,"labels":[{"name":"bug"}]}]'
readiness
has "$OUT" "VERDICT=unmet"  "an open blocker in the milestone is unmet"
has "$OUT" "BLK=1 OPEN=2"   "...with the counts tabulated from the paginated read"

fix_default
ms_issues '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
            {"number":94,"state":"open","state_reason":null,"labels":[{"name":"bug"}]}]'
readiness
has "$OUT" "VERDICT=met" "0 open blockers is met — an open non-blocker does not hold the cut"

fix_default
ms_issues '[{"number":77,"state":"closed","state_reason":"not_planned","labels":[{"name":"release-blocker"}]}]'
readiness
has "$OUT" "VERDICT=held" "a NOT_PLANNED blocker withholds the cut for owner review"

# Mode selection is keyed off label EXISTENCE. With the label absent, the SAME milestone that was
# `met` in blocker-mode is `unmet` in fallback mode — the rule closing the last blocker must never
# silently flip. Proven here through the live probe, not just the predicate's argument.
fix_default; printf 'roadmap\n' > "$FIX/labels.txt"
ms_issues '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
            {"number":94,"state":"open","state_reason":null,"labels":[{"name":"bug"}]}]'
readiness
has "$OUT" "VERDICT=unmet" "with the label absent (404) the bar is 0 OPEN ISSUES, not 0 blockers"

# The roadmap artifact is excluded BY NUMBER: a milestone holding only it is unarmed, so a stray
# membership can never fabricate an armed release set.
fix_default
ms_issues '[{"number":31,"state":"open","state_reason":null,"labels":[{"name":"roadmap"}]}]'
readiness
has "$OUT" "VERDICT=unarmed" "a milestone holding only the artifact is unarmed (excluded by number)"

# A failed milestone read must hard-stop rather than tabulate an empty (=> unarmed) milestone —
# and it must fail AS a failed read. Piping the read straight into `release-counts` reports only
# the tabulator's status, so the read's failure would arrive as an empty milestone and the run
# would exit 0 reporting `unarmed`. Naming the diagnostic is what separates that from a hard stop
# that happened for some unrelated reason (the discipline §4c states for its own injections).
#
# The `hasnt … "VERDICT="` lines here and below CO-FIRE with their adjacent `no "$RC_"`: the tail
# that prints VERDICT= runs only when the snippet failed to stop, which is the same event the
# exit-status assertion watches. They attribute WHICH promise broke — they are not independent
# coverage. (#376 review)
fix_default; : > "$FIX/fail-milestone"
readiness
no "$RC_" "a failing milestone read hard-stops instead of reporting an empty release set"
has "$OUT" "could not read milestone" "...and reports as a failed READ, not as an empty release set"
hasnt "$OUT" "VERDICT=" "...emitting no verdict at all"

# --- the two inputs that come from EARLIER steps must fail loud, never default (#376) ---------
# `M_NUM` addresses the milestone read. Unset, a bare expansion would send `issues?milestone=` —
# which GitHub answers, with a set of issues that is not this release's — so the snippet declares
# it required instead. The refusal must arrive BEFORE the read, or the wrong answer is already in
# hand by the time anyone notices. `set -u` alone does not settle this: it aborts with a message
# about a variable, and the snippet is what has to name which step resolves it.
#
# ASSERT THE SENTENCE, NOT MERELY THE HARD STOP. Delete the declaration and `set -u` still kills
# the run at the first expansion — same exit status, same variable name in the text — so a case
# that asked only for "nonzero, mentions M_NUM" passes against the defect it was written for. What
# the declaration adds is the STEP that resolves the value, which a shell dying cannot say.
fix_default; ms_issues '[]'
ADB_UNSET=M_NUM readiness
no "$RC_" "an unresolved M_NUM is a hard stop"
has "$OUT" "resolve the marker first" "...naming the step that resolves it, not just the variable"
hasnt "$OUT" "unbound variable" "...as the snippet's own refusal, not a shell death at first use"
hasnt "$OUT" "could not read milestone" "...refusing BEFORE the read, not because the read failed"
hasnt "$OUT" "VERDICT=" "...and no verdict is computed"

fix_default; ms_issues '[]'
ADB_UNSET=ROADMAP_NUM readiness
no "$RC_" "an unresolved ROADMAP_NUM is a hard stop too"
has "$OUT" "run step 2 first" "...naming the step that resolves it"
hasnt "$OUT" "unbound variable" "...as the snippet's own refusal"
hasnt "$OUT" "VERDICT=" "...and no verdict is computed"

# --- a newline INSIDE the packed repo view is refused before it is split (#218, #376) ----------
# One request returns the slug AND the default branch separated by a newline, so a newline inside
# either value silently re-partitions them: `nameWithOwner` = "victim/repo\nmain" leaves REPO as
# the entirely valid-looking `victim/repo` and DEFAULT_BRANCH as `main`, with the REAL default
# branch discarded — every read below then addresses a DIFFERENT REPOSITORY. `slug-ok` cannot see
# it: by the time it runs, the value it is handed is clean.
fix_default; ms_drained
printf '{"nameWithOwner":"victim/repo\\nmain","defaultBranchRef":{"name":"real-default"}}\n' > "$FIX/repo"
readiness
no "$RC_" "a repo view carrying an embedded newline is a hard stop"
has "$OUT" "expected exactly 2 lines" "...refused on the LINE COUNT, the only place the substitution is still visible"
hasnt "$OUT" "VERDICT=" "...so no verdict is derived from a re-partitioned read"

# --- the default branch is the REMOTE's, never assumed to be `main` (#376) --------------------
# Health is a statement about the branch a release would be cut from, and a clone can disagree
# with the remote (stale origin/HEAD, a detached checkout). The stub answers the branch-addressed
# reads only for the branch the repo fixture DECLARES, so a snippet that hard-coded `main` here
# addresses a branch that does not exist and hard-stops — which is what makes this executable at
# all rather than a token pin on `defaultBranchRef`.
fix_default; ms_drained; health_green
printf '{"nameWithOwner":"acme/widget","defaultBranchRef":{"name":"trunk"}}\n' > "$FIX/repo"
readiness
eq "$RC_" 0 "a repo whose default branch is not 'main' reads clean"
has "$OUT" "HEALTH=green" "...because health is read on the branch the REMOTE declares"
has "$OUT" "VERDICT=met" "...and the cut is reached normally"

# `null` is what --jq prints for an absent defaultBranchRef (a commit-less repo). It is four
# non-empty characters, so a bare `-n` test passes it through and every later read addresses
# `commits/null/...` — a nonsense path whose failure would be blamed on the wrong thing.
fix_default; ms_drained; health_green
printf '{"nameWithOwner":"acme/widget","defaultBranchRef":null}\n' > "$FIX/repo"
readiness
no "$RC_" "a repo with no resolvable default branch is a hard stop"
has "$OUT" "cannot resolve the default branch" "...named as that, not as a failed read of commits/null"
hasnt "$OUT" "VERDICT=" "...and no verdict is computed"

# ============================================================================================
# 4b. BRANCH HEALTH end to end (#78) — the live reads, wired through the documented snippet
# ============================================================================================
# check-roadmap.sh pins the branch-health VERDICT TABLE. What is proven here is the wiring: that
# the snippet resolves the default branch and its HEAD live, reads BOTH check APIs plus the
# workflow inventory, and feeds the result to release-ready — the places a perfect predicate
# still yields a wrong verdict.
fix_default; ms_drained; health_green
readiness
eq "$RC_" 0            "the health pipeline runs clean"
has "$OUT" "HEALTH=green"  "a green default branch resolves to green"
has "$OUT" "VERDICT=met"   "...and a drained milestone on a green branch is the cut"

fix_default; ms_drained; health_red
readiness
has "$OUT" "VERDICT=not-green" "a RED default branch withholds the cut (#78's headline case)"
has "$OUT" "WHY=failing: ci"   "...and names the failing check, so the report is actionable"

fix_default; ms_drained; health_running
readiness
has "$OUT" "VERDICT=indeterminate" "a still-running check fails closed, and is NOT reported as red"
has "$OUT" "still running"         "...naming what it is waiting on"

fix_default; ms_drained; health_stale
readiness
has "$OUT" "VERDICT=indeterminate" "a green check on a DIFFERENT commit is never this branch's green"

# #293, END TO END. Nothing reported, no workflows, an unprotected branch — and NOTHING DECLARED.
# This exact fixture emitted the cut before #293, reported as "no CI configured", on a repo that may
# well have had CircleCI: an unprotected branch declares no required contexts whether or not CI
# exists, so the two are indistinguishable from here. It fails closed now, and the refusal names the
# marker that settles it. This is the assertion that reverts if the arm ever goes back to inferring.
fix_default; ms_drained; health_no_ci
readiness
has "$OUT" "HEALTH=indeterminate" "no checks, no workflows, NOTHING DECLARED => indeterminate, not a fabricated no-ci (#293)"
has "$OUT" "VERDICT=indeterminate" "...and the readiness verdict fails closed rather than emitting the cut"
has "$OUT" "release-health: no-ci" "...and the run names the declaration that would settle it"
# ...and WITH the declaration, the #24 degradation is exactly as it was — a repo that never adopted
# CI still reaches the cut. What changed is who said so, and the banner now has something true to
# say. The artifact is maintainer-authored, because a declaration bypasses a release-safety refusal.
fix_default; ms_drained; health_no_ci
artifact_fx '<!-- ai-dev-baseline:roadmap:v1 -->
<!-- release-health: no-ci -->' write
readiness
has "$OUT" "HEALTH=no-ci"  "...and a DECLARED no-ci repo resolves to no-ci"
has "$OUT" "VERDICT=met"   "...so a repo with no CI is still not deadlocked out of releasing (#24)"
# The same declaration from an author who cannot push is NOT honoured — it would otherwise be a
# release cut armed by anyone able to edit an issue body.
fix_default; ms_drained; health_no_ci
artifact_fx '<!-- ai-dev-baseline:roadmap:v1 -->
<!-- release-health: no-ci -->' read
readiness
has "$OUT" "VERDICT=indeterminate" "...but a read-access author cannot arm it"
has "$OUT" "WARN:" "...and the refusal is reported, not silent"

fix_default; ms_drained; health_norun
readiness
has "$OUT" "VERDICT=indeterminate" \
  "active workflows that have not reported here => indeterminate, NOT no-ci (the discriminator)"

# THE FALSE-CUT REGRESSION, end to end (adversarial-review find). One unrelated GREEN legacy
# status must not suppress the workflow-inventory read, and must not satisfy the predicate on
# behalf of workflows that reported nothing. Before the fix this emitted a release.
fix_default; ms_drained; health_set '[]' '[{"context":"vercel","state":"success"}]' 3
readiness
has "$OUT" "VERDICT=indeterminate" \
  "a green status from ONE provider never speaks for 3 workflows that have not reported"
hasnt "$OUT" "VERDICT=met" "...so adding an unrelated passing status cannot turn a refusal into a cut"

# The SECOND masking provider (bot-review find): a check run from a different Checks API app lands
# in `check_runs` too, so gating the inventory read on "any check runs" would skip it and let
# `$total > 0` return green while Actions reported nothing. Attribution is by `app.slug`.
fix_default; ms_drained; health_set "${ ck1 completed '"success"' "$E2E_SHA" vercel; }" '[]' 3
readiness
has "$OUT" "VERDICT=indeterminate" \
  "a green check run from ANOTHER Checks app never speaks for 3 silent Actions workflows"
has "$OUT" "Actions has not reported" "...and the reason names Actions specifically"
# Same fixture, no active workflows: that app IS the repo's CI, so it legitimately reports green.
fix_default; ms_drained; health_set "${ ck1 completed '"success"' "$E2E_SHA" vercel; }" '[]' 0
readiness
has "$OUT" "VERDICT=met" "...while with 0 active workflows that same app is the repo's CI"

fix_default; ms_drained; health_legacy_red
readiness
has "$OUT" "VERDICT=not-green" \
  "a non-Actions provider reporting failure through the legacy status API still withholds the cut"

# Health is only consulted at the would-be-met boundary: with an open blocker the verdict is
# `unmet` and the snippet must not even resolve health (so a repo mid-build never blocks on CI).
fix_default; health_red
ms_issues '[{"number":78,"state":"open","state_reason":null,"labels":[{"name":"release-blocker"}]}]'
readiness
has "$OUT" "VERDICT=unmet"     "an open blocker outranks a red branch"
has "$OUT" "HEALTH=skipped"    "...and health is not read at all while requirements remain"

# EVERY health read is separately checked. A failed read must hard-stop — falling through would
# leave the health variable empty, and an empty health argument is exactly what must never be
# allowed to reach `met`.
for kind in repo checkruns commitstatus; do
  fix_default; ms_drained; health_green; : > "$FIX/fail-$kind"
  readiness
  no "$RC_" "a failing '$kind' read hard-stops instead of emitting a cut on unknown health"
  hasnt "$OUT" "VERDICT=met" "...and never reports met"
done
# The workflow inventory is read ONLY when nothing reported on the commit, so its failure has to
# be injected against a fixture that reaches that branch — with checks present the read never
# happens, and asserting a hard stop there would pass for the wrong reason.
fix_default; ms_drained; health_no_ci; : > "$FIX/fail-workflows"
readiness
no "$RC_" "a failing workflow-inventory read hard-stops rather than counting 0 and passing as no-ci"
hasnt "$OUT" "VERDICT=met" "...and never reports met"

# The inventory read is SKIPPED entirely when checks already answered — a green branch must not
# pay for a read whose result the predicate cannot consult.
fix_default; ms_drained; health_green; : > "$FIX/fail-workflows"
readiness
has "$OUT" "VERDICT=met" "with checks present the workflow inventory is never read (its failure cannot matter)"

# ============================================================================================
# 4c. THE PROVIDER-AGNOSTIC EXISTENCE PROBE + THE ESCAPE HATCH, end to end (#115, was #113)  # adb-claim-ok: #113 was consolidated into #115 and closed as superseded — history, not tracked work
# ============================================================================================
# check-roadmap.sh pins the ARM TABLE. What is proven here is the WIRING: that the snippet reads
# the branch endpoint, classifies it through the shared reader, splices the result into the health
# document, resolves the artifact marker, and passes the opt-out to the predicate. Every one of
# those is a place a perfect predicate still yields a wrong verdict.

# THE FAIL-OPEN #115 WAS FILED FOR, end to end. A non-Actions CI repo — zero Actions workflows,
# nothing reported yet — used to read `no-ci` and EMIT THE CUT. Its required context is the
# evidence that CI exists here.
fix_default; ms_drained; health_set '[]' '[]' 0 "${ br_checks '"ci/circleci: build"'; }"
readiness
has "$OUT" "VERDICT=indeterminate" \
  "a non-Actions CI repo with a required context does NOT resolve to no-ci (the #115 headline)"
hasnt "$OUT" "VERDICT=met" "...so the cut is withheld instead of emitted against an unchecked branch"
has "$OUT" "required context(s) have not reported" "...and the reason names the unreported context"

# ...and that same repo IS green once its declared provider reports. The fix must not make
# non-Actions CI un-releasable, only un-fabricatable.
fix_default; ms_drained
health_set '[]' '[{"context":"ci/circleci: build","state":"success"}]' 0 "${ br_checks '"ci/circleci: build"'; }"
readiness
has "$OUT" "VERDICT=met" "...while the same repo with its declared context reporting green cuts normally"

# An unrelated green must not mask a silent declared provider — the masking law, generalized.
fix_default; ms_drained
health_set '[]' '[{"context":"vercel","state":"success"}]' 0 "${ br_checks '"ci/circleci: build"'; }"
readiness
has "$OUT" "VERDICT=indeterminate" "one unrelated green status never speaks for a silent required context"

# A RULESET-protected branch reports a real empty `contexts` array. Read as "requires nothing" it
# would reach `no-ci` and cut; it must fail closed instead.
fix_default; ms_drained; health_set '[]' '[]' 0 "${ br_ruleset; }"
readiness
has "$OUT" "VERDICT=indeterminate" "a ruleset-protected branch is never read as 'requires nothing' => no-ci"
has "$OUT" "could not be read" "...and says the required checks could not be read"

# The genuinely CI-less repo still passes (#24) — unprotected AND no workflows AND nothing reported
# AND the owner says so. That last conjunct is #293: the same three probes describe a CircleCI repo
# with no branch protection just as well, so the declaration is the only thing that tells them apart.
fix_default; ms_drained; health_no_ci
artifact_fx '<!-- ai-dev-baseline:roadmap:v1 -->
<!-- release-health: no-ci -->' write
readiness
has "$OUT" "HEALTH=no-ci" "an unprotected repo with no workflows, no results and a no-ci declaration is a real no-ci"
has "$OUT" "VERDICT=met"  "...and is not deadlocked out of releasing"

# --- the escape hatch, wired ------------------------------------------------------------------
OPTOUT_BODY='<!-- ai-dev-baseline:roadmap:v1 -->
<!-- release-health: skip-unreported -->'
# PR-only CI: required contexts declared, nothing on default-branch HEAD. Held without the marker.
fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"
readiness
has "$OUT" "VERDICT=indeterminate" "a PR-only-CI repo is held at indeterminate without the opt-out"
# ...and reaches a cut with it.
fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "HEALTH=unreported-ok" "...and the declared opt-out resolves to unreported-ok"
has "$OUT" "VERDICT=met"          "...so a PR-only-CI repo CAN reach a cut (#115 acceptance)"
hasnt "$OUT" "HEALTH=green"       "...without ever being reported as green"

# THE UNREADABLE CONTEXT LIST IS NOT EXCUSABLE, AND IT MUST BE TESTED WITH ACTIVE WORKFLOWS.
# With `null` AND active workflows the ACTIONS arm matches first, so an opt-out gated only on the
# later unreadable arm still excused it — a real fail-open the zero-workflow fixture could not see,
# because it never reaches the Actions arm at all. (Independent-review find.)
fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_ruleset; }"; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "VERDICT=indeterminate" "a RULESET-protected branch + active workflows + opt-out is STILL held"
hasnt "$OUT" "HEALTH=unreported-ok" "...the opt-out verdict is never produced from an unreadable list"
hasnt "$OUT" "VERDICT=met" "...and no cut is emitted"

# AUTHORITY IS RE-VALIDATED AT THE POINT OF USE, AND IT IS THE REPOSITORY PERMISSION. An issue's
# author can keep editing its body forever regardless of repo permissions, and this marker bypasses
# a release-safety refusal — so it is honoured only from an artifact whose author could have changed
# the code instead. `author_association` is NOT that check: an org MEMBER may hold read-only access
# and a COLLABORATOR may be read or triage. (Independent-review find.)
for perm in read triage none; do
  fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"; artifact_fx "$OPTOUT_BODY" "$perm"
  readiness
  has "$OUT" "VERDICT=indeterminate" "an opt-out from a '$perm'-access author is NOT honoured"
  has "$OUT" "WARN:" "...and the run says so rather than silently ignoring it"
done
for perm in write admin; do
  fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"; artifact_fx "$OPTOUT_BODY" "$perm"
  readiness
  has "$OUT" "VERDICT=met" "...while a '$perm'-access author IS honoured"
done
# An UNREADABLE permission fails closed: the endpoint needs push access itself, so a 403 means
# "authority could not be established", which is not a licence to assume it.
fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"; artifact_fx "$OPTOUT_BODY" ""
readiness
has "$OUT" "VERDICT=indeterminate" "an unreadable author permission fails CLOSED (opt-out not applied)"
has "$OUT" "WARN:" "...and says the permission could not be established"
yes "$RC_" "...without hard-stopping the run (an unverifiable opt-out simply does not apply)"

# The opt-out cannot excuse a branch that is actually broken — the whole safety property.
fix_default; ms_drained; health_red; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "VERDICT=not-green" "the opt-out never excuses a RED branch, even end to end"
fix_default; ms_drained; health_running; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "VERDICT=indeterminate" "...nor a still-running check"
fix_default; ms_drained; health_stale; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "VERDICT=indeterminate" "...nor stale evidence from another commit"
fix_default; ms_drained; health_set '[]' '[]' 0 "${ br_ruleset; }"; artifact_fx "$OPTOUT_BODY" write
readiness
has "$OUT" "VERDICT=indeterminate" "...and NEVER a branch whose required checks could not be read"

# A marker the predicate does not recognise refuses to excuse anything AND is reported — an owner
# who wrote it wrong must not face a permanent indeterminate with nothing saying why.
fix_default; ms_drained; health_set '[]' '[]' 2 "${ br_checks '"ci"'; }"
artifact_fx '<!-- release-health: skip -->' write
readiness
has "$OUT" "VERDICT=indeterminate" "an unusable release-health value excuses nothing"
has "$OUT" "WARN:" "...and is reported, not silently ignored"

# BOTH new reads are separately checked, like every sibling: a failed read must hard-stop rather
# than fall through to a verdict computed from a document it never saw.
#
# EACH ASSERTS ITS OWN DIAGNOSTIC, not merely "nonzero and not met". A stub arm that never matched,
# an unresolved `{{TOKEN}}`, or a death on arity all produce a nonzero exit with no `met` in it —
# so a bare `no "$RC_"` passes for whatever went wrong first and stops testing the injection it was
# written for. Naming the expected message is what keeps these honest.
fix_default; ms_drained; health_green; : > "$FIX/fail-branch"
readiness
no "$RC_" "a failing branch-protection read hard-stops instead of emitting a cut on unknown health"
hasnt "$OUT" "VERDICT=met" "...and never reports met"
has "$OUT" "could not read branch protection" "...failing for THAT read, not for an unrelated error"

fix_default; ms_drained; health_green; : > "$FIX/fail-artifact"
readiness
no "$RC_" "a failing roadmap-artifact read hard-stops rather than proceeding with the opt-out unresolved"
hasnt "$OUT" "VERDICT=met" "...and never reports met"
has "$OUT" "could not read roadmap artifact" "...failing for THAT read, not for an unrelated error"

# ============================================================================================
# 5. DESTINATION GAUGE (acceptance §8)
# ============================================================================================
# The gauge's `q` is label:-qualified, so the stub answers it from its own fixture
# (search-label.json) while the unscoped completeness cross-check reads search-total.json (#376
# review). Asserting the COUNT, not merely a clean exit, is what makes the label probe below a
# gate rather than decoration — and the two fixtures carry different counts, so a gauge that lost
# its label scoping entirely reads the unscoped number and fails as a wrong count.
#
# `N` is UNSET for every case here, and that is load-bearing: the preamble's `N` is step 5's
# selected bundle member, the gauge's `N` is its own count, and they collide by name. Left set, a
# gauge that counted nothing still prints the member number and reads as a count.
fix_default
printf '{"total_count":2}\n' > "$FIX/search-label.json"
ADB_UNSET=N run_snippet gauge 'printf "N=%s\n" "${N:-unset}"' >/dev/null
eq "$RC_" 0 "the gauge snippet runs clean"
has "$OUT" "N=2" "...and counts the open issues carrying the label"

# The label probe is the gate: with the label absent the gauge must be OMITTED, and a 404 is
# explicitly NOT an error — the one carve-out from the hard-stop rule. `N=unset` is the half that
# matters: an unconditional count would exit 0 and print DONE too, having reported a gauge for a
# label the repo does not have.
fix_default; printf 'roadmap\n' > "$FIX/labels.txt"
ADB_UNSET=N run_snippet gauge 'printf "DONE N=%s\n" "${N:-unset}"' >/dev/null
eq "$RC_" 0 "a 404 on the label probe is not an error (the gauge line is simply omitted)"
has "$OUT" "DONE N=unset" "...and the run continues past it having counted nothing"

# --- AN UNCONFIGURED GAUGE DECIDES BEFORE IT RESOLVES ANYTHING (#218, executed by #376) -------
# The gauge is OPTIONAL. Every line it needs — the slug, the slug's validation, the label probe —
# belongs INSIDE the `[ -n "$LABEL" ]` conditional, because a step that can fail the run before it
# has decided whether it is even taken converts an opt-in report into a hard stop for the whole
# roadmap. The slug guard was first added ABOVE that decision, and this is that defect executed:
# with no marker configured, a `gh repo view` that merely fails must be a request never made.
#
# LABEL is left UNSET rather than empty, which is the real shape (no marker in the artifact) and
# the one that also proves `LABEL="${LABEL:-}"` is still there: without it, `set -u` kills the
# snippet on the very first expansion.
fix_default; : > "$FIX/fail-repo"
ADB_UNSET="LABEL N" run_snippet gauge 'printf "SKIPPED N=%s\n" "${N:-unset}"' >/dev/null
eq "$RC_" 0 "an unconfigured gauge survives a FAILING repo read — it never makes the request"
has "$OUT" "SKIPPED N=unset" "...and the rest of the run proceeds"
hasnt "$OUT" "cannot resolve repo" "...so an optional feature cannot hard-stop the roadmap"

# ...and the slug GUARD is likewise not reached. Both lines are present either way; only their
# position relative to the LABEL decision differs, and a malformed slug is what makes the
# difference visible.
fix_default
printf '{"nameWithOwner":"acme/..","defaultBranchRef":{"name":"main"}}\n' > "$FIX/repo"
ADB_UNSET="LABEL N" run_snippet gauge 'printf "SKIPPED\n"' >/dev/null
eq "$RC_" 0 "an unconfigured gauge survives a MALFORMED slug too"
has "$OUT" "SKIPPED" "...and the run continues"
hasnt "$OUT" "malformed repository slug" "...because the guard sits inside the conditional, not above it"

# THE OTHER DIRECTION, or the two cases above pass for a gauge that resolves nothing at all: with
# the marker configured, each of those reads IS made and each failure IS a hard stop.
fix_default; : > "$FIX/fail-repo"
ADB_UNSET=N run_snippet gauge 'printf "REACHED\n"' >/dev/null
no "$RC_" "a CONFIGURED gauge hard-stops on a failing repo read"
has "$OUT" "cannot resolve repo" "...naming that read"
hasnt "$OUT" "REACHED" "...and does not fall through"

fix_default
printf '{"nameWithOwner":"acme/..","defaultBranchRef":{"name":"main"}}\n' > "$FIX/repo"
ADB_UNSET=N run_snippet gauge 'printf "REACHED\n"' >/dev/null
no "$RC_" "a CONFIGURED gauge refuses a malformed slug (it interpolates into a path AND a query)"
has "$OUT" "malformed repository slug" "...naming the guard that refused"
hasnt "$OUT" "REACHED" "...and does not fall through"

# ============================================================================================
# 6. DECISION DURABILITY — a recorded answer retires the question (#108, acceptance §11)
# ============================================================================================
# The reproduced bug, end to end: the same prompt reprinted on three consecutive runs because the
# answer lived in a comment. Here the artifact body IS the input, exactly as a run reads it.
art_with_decision="$(printf '%s\n' \
  '<!-- ai-dev-baseline:roadmap:v1 -->' \
  '# Build roadmap' \
  '## Dependencies' \
  '- #73 depends on #25' \
  '## Decisions' \
  '| Question | Decision | Recorded |' \
  '| -------- | -------- | -------- |' \
  '| dep-outside-release:#73 | Re-scoped; no longer depends on #25 | #73 body |')"
art_without="${ printf '%s\n' '<!-- ai-dev-baseline:roadmap:v1 -->' '# Build roadmap' '## Dependencies' '- #73 depends on #25'; }"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

answered="${ printf '%s' "$art_with_decision" | bash "$RL" decisions; }"
eq "${ printf '%s\n' "$answered" | grep -Fqx 'dep-outside-release:#73' && echo retired || echo asked; }" retired "a recorded decision retires its question"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
answered="${ printf '%s' "$art_without" | bash "$RL" decisions; }"
eq "${ printf '%s\n' "$answered" | grep -Fqx 'dep-outside-release:#73' && echo retired || echo asked; }" asked "...and an unrecorded one is still asked"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# The stale edge in `## Dependencies` must NOT survive: edges are re-derived from the live
# sources, and the decision row's own text retires this one.
row="${ printf '%s' "$art_with_decision" | awk -F'|' '/dep-outside-release/ { print $3 }'; }"
eq "${ printf '%s' "$row" | bash "$RL" deps-from-body | tr '\n' ' ' | sed 's/ $//'; }" '' \
   "the decision row retires the #25 edge (a negated mention never declares one)"
eq "${ printf 'Depends on #78 only.' | bash "$RL" deps-from-body | tr '\n' ' ' | sed 's/ $//'; }" '78' \
   "...while the body that replaced it declares the edge that IS real"

# ============================================================================================
# 7. AUTOFIX — repair the unambiguous, escalate the rest (#109)
# ============================================================================================
# The acceptance is behavioral in both directions: a repo with issues in limbo must end the run
# with zero in limbo, AND re-running must change nothing. Both are properties of the SELECTION
# (`milestone == null`), which is why they can be tested without a stateful stub.

# --- 7a. every unmilestoned open issue is repaired, one line each ---------------------------
fix_default
limbo_issues 5 12:Backlog 44 31 61^
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the autofix snippet runs clean"
has "$OUT" "fixed: #5 → milestone Backlog (was unmilestoned)"  "an unmilestoned issue is repaired, not reported"
has "$OUT" "fixed: #44 → milestone Backlog (was unmilestoned)" "...every one of them"
hasnt "$OUT" "#12" "an issue already in a milestone is untouched"
hasnt "$OUT" "#61" "an open PR is untouched too — the issues endpoint returns PRs, and the sweep must never milestone one"
hasnt "$OUT" "fixed: #31" "the roadmap artifact is never moved into the backlog"
eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 2 "exactly two tracker writes, one per repaired issue"

# --- 7a-bis. #78: an unmilestoned `release-blocker` is WARNED about, never swept --------------
# The carve-out was previously pinned only by prose greps, so deleting the `| not` from the LIMBO
# filter — which inverts the sweep and manufactures exactly the silent-ignore #78 prevents — would
# have passed every executed test. This drives it end to end: the labeled issue must produce NO
# tracker write, while an unlabeled sibling in the same run is still repaired.
fix_default
limbo_issues 5 '44!' 31 '61!^'
ADB_ROADMAP_NUM=31 ADB_RELEASE_MODE=1 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the autofix snippet runs clean with a stray blocker present"
has "$OUT" "WARN: #44 is an open release-blocker in NO milestone" \
  "an unmilestoned release-blocker is surfaced, not buried in Backlog"
hasnt "$OUT" "fixed: #44" "...and is NOT swept"
hasnt "$OUT" "#61" \
  "a release-blocker-labelled open PR is neither swept nor warned about (the STRAY filter drops PRs too)"
# It WARNS, it does not gate — nothing feeds this line to the readiness predicate, so wording it as
# a HOLD would claim a gate that is not wired.
hasnt "$OUT" "HOLD:" "...and does not call it a HOLD, which would promise a gate nothing implements"
# ...nor is it filed as a retirable `unmilestoned:#N` question: a `## Decisions` row would then
# suppress a real release risk forever. It is derived from ground truth and prints every run.
hasnt "$OUT" "? unmilestoned:#44" \
  "...and is not filed as a retirable question (a Decisions row must not be able to hide it)"
has "$OUT" "fixed: #5 → milestone Backlog (was unmilestoned)" \
  "...while an unlabeled unmilestoned issue in the same run IS still repaired"
# `grep -c` prints 0 AND exits 1 on no-match, so the `|| echo 0` idiom used above would emit TWO
# lines here (the file exists, since #5 was edited). Count with wc, which always exits 0.
eq "$(grep 'issue edit 44' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 \
  "no tracker write touches the stray blocker (the sweep would have made readiness count 0)"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 1 "exactly one write: the unlabeled issue"
# The artifact is excluded even when it carries the label, so a labeled roadmap issue is silent.
fix_default
limbo_issues '31!'
ADB_ROADMAP_NUM=31 ADB_RELEASE_MODE=1 run_snippet autofix-unmilestoned >/dev/null
eq "$OUT" "" "a labeled roadmap artifact is neither swept nor warned about"

# CLASSIC MODE must stay byte-identical (bot-review find). The carve-out is overlay behavior, so
# with RELEASE_MODE unset the SAME fixture takes the plain sweep: the labeled issue is repaired
# like any other unmilestoned issue, and nothing warns about a release milestone the repo has not
# adopted. A repo that ran `baseline release init` (which creates the label) but has not yet added
# the marker sits in exactly this state.
fix_default
limbo_issues 5 '44!' 31
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "classic mode runs clean with a labeled issue present"
has "$OUT" "fixed: #44 → milestone Backlog (was unmilestoned)" \
  "in CLASSIC mode a release-blocker label is just a label — the issue is swept normally"
hasnt "$OUT" "WARN:" "...and no release-overlay warning is printed in classic mode"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 2 \
  "...so BOTH unmilestoned issues are repaired, exactly as before the overlay existed"

# --- 7a-ter. THE OPTIONAL INPUTS ARE OPTIONAL (#376) -----------------------------------------
# `NO_AUTOFIX` and `RELEASE_MODE` are flags an EARLIER step sets, and the snippet may be run as its
# own shell invocation where neither exists. It defaults both — `${NO_AUTOFIX:-0}` and
# `RELEASE_MODE="${RELEASE_MODE:-0}"` — and with the preamble always assigning them, that claim was
# only ever watched by a token pin. Left genuinely unset, a bare expansion dies under `set -u`: the
# whole step would abort over a flag nobody set, on every repo that runs the blocks separately.
#
# The defaults must also be the RIGHT ones: repairing (not reporting), and classic (not overlay).
# The same fixture 7a-bis drives in release mode is used, so a wrong `RELEASE_MODE` default is
# visible as the carve-out firing — #44 warned about instead of swept.
fix_default
limbo_issues 5 '44!' 31
ADB_UNSET="NO_AUTOFIX RELEASE_MODE" ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the autofix snippet runs with NO_AUTOFIX and RELEASE_MODE unset (it defaults both)"
has "$OUT" "fixed: #5 → milestone Backlog (was unmilestoned)" "...defaulting NO_AUTOFIX to a repairing run"
has "$OUT" "fixed: #44 → milestone Backlog (was unmilestoned)" "...and RELEASE_MODE to classic mode"
hasnt "$OUT" "WARN:" "...so the overlay carve-out does not fire on a repo that never adopted it"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 2 "...and both repairs are real tracker writes"

# --- 7b. IDEMPOTENT: the second run finds nothing (#109's acceptance) ------------------------
# Model the post-repair tracker — which is what the first run produced — and re-run.
fix_default
limbo_issues 5:Backlog 12:Backlog 44:Backlog 31
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the second run is clean"
eq "$OUT" "" "re-running changes nothing and prints nothing (idempotent by selection)"
eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 0 "...and performs no tracker write"

# --- 7c. no backlog milestone => ESCALATE, never invent the repo's convention ----------------
fix_default
printf '[{"number":9,"title":"Next release"}]\n' > "$FIX/milestones.json"
limbo_issues 5 31
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "a missing backlog milestone is not a crash"
has "$OUT" "? unmilestoned:#5" "it escalates as an owner question with the stable id"
has "$OUT" "Record:" "...and names where to record the answer"
hasnt "$OUT" "fixed:" "nothing is repaired on a guess"
eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 0 "no milestone is created and no issue is moved"
# The stub answers only the reads this workflow documents, so a `gh api --method POST …/milestones`
# — inventing the repo's convention rather than escalating — reaches its unhandled arm. Asserted by
# name, because a bare `eq "$RC_" 0` above would also go red for an unrelated failure.
hasnt "$OUT" "gh stub: unhandled" "...and no milestone is CREATED (that would invent the repo's convention)"

# --- 7d. a configured backlog title is honored ----------------------------------------------
fix_default
printf '[{"number":7,"title":"Icebox"}]\n' > "$FIX/milestones.json"
limbo_issues 5 31
ADB_ROADMAP_NUM=31 ADB_BACKLOG=Icebox run_snippet autofix-unmilestoned >/dev/null
has "$OUT" "fixed: #5 → milestone Icebox" "the backlog-milestone marker overrides the default title"

# --- 7e. --no-autofix is a read-only run ----------------------------------------------------
fix_default
limbo_issues 5 31
ADB_ROADMAP_NUM=31 ADB_NO_AUTOFIX=1 run_snippet autofix-unmilestoned >/dev/null
has "$OUT" "? unmilestoned:#5" "--no-autofix reports instead of repairing"
hasnt "$OUT" "fixed:" "...and repairs nothing"
eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 0 "--no-autofix performs NO tracker write"

# --- 7f. failing reads hard-stop rather than 'finding nothing in limbo' ----------------------
for kind in milestones openissues; do
  fix_default; limbo_issues 5 31
  : > "$FIX/fail-$kind"
  ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
  no "$RC_" "a failing '$kind' read hard-stops instead of silently finding nothing to fix"
  eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 0 "...and writes nothing on the way out"
done

# ============================================================================================
# 7b. release-command RESOLUTION (#188)
# ============================================================================================
# The met-emission must name a command that EXISTS. An unresolvable slash command does not fail
# loudly — Claude Code fuzzy-matches the nearest built-in, so a bare `/release` on a repo without
# one silently opens the CLI's release-notes viewer at the moment the roadmap says "cutting".
rc_snip() {   # <CMD> <user-root> [subdirs] [prefix] [extra-key] [probe] [cwd] -> prints RESOLVES
  # `local`, and it is load-bearing rather than tidiness (#259). This file also drives a
  # file-scope `body` through the snippet-parse loop below, and the two are the same name. That
  # was harmless only for as long as every caller wrapped this in `$( )`, where the subshell
  # swallowed the assignment — so the helper was one modernization away from clobbering a
  # variable in the caller it never knew about. `${ command; }` runs in the CURRENT shell.
  local body
  body="${ snippet release-command; }"
  printf 'release-command\n' >> "$work/ran"   # rc_snip is this snippet's only executor
  body="${body//\{\{SKILLS_SUBDIRS\}\}/${3-no-project-skills}}"
  body="${body//\{\{SKILL_REGISTRY_PROBE\}\}/${6-}}"
  body="${body//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}"
  body="${body//\{\{SKILLS_USER_ROOT\}\}/\"$2\"}"
  body="${body//\{\{SKILL_PREFIX\}\}/${4:-/}}"
  body="${body//\{\{SKILL_EXTRA_KEY\}\}/${5-}}"
  printf 'ARTIFACT_BODY=%s\n%s\nprintf %%s "$RESOLVES"\n' \
    "${ printf '%q' "<!-- release-command: $1 -->"; }" "$body" > "$work/rc.sh"
  ( cd "${7:-$work}" && bash "$work/rc.sh" )
}
# A LOADABLE skill: opening `---` plus the two keys every registry needs. `printf x` is not one.
mk_skill() { mkdir -p "$1"; printf -- '---\nname: %s\ndescription: d\nuser-invocable: true\n---\n' "$(basename "$1")" > "$1/SKILL.md"; }
mkdir -p "$work/sk" "$work/empty-sk"
mk_skill "$work/sk/release"; mk_skill "$work/sk/ship"

eq "${ rc_snip '/release' "$work/sk"; }"                 1 "a declared command with a SKILL.md resolves"
eq "${ rc_snip '/nope' "$work/sk"; }"                    0 "a declared command with no skill does NOT resolve"
eq "${ rc_snip '' "$work/sk"; }"                         0 "an absent marker never resolves (no /release default)"
# A marker may carry ARGUMENTS. Resolution must use the command name only, or a valid skill reads
# as missing — skills take invocation arguments, so this is an ordinary marker, not an edge case.
eq "${ rc_snip '/ship --channel production' "$work/sk"; }" 1 "arguments are stripped before resolution"
eq "${ rc_snip '/ship --channel production' "$work/empty-sk"; }" 0 "still refuses when the named skill is absent"
# A directory without a SKILL.md is not a skill.
mkdir -p "$work/sk/hollow"
eq "${ rc_snip '/hollow' "$work/sk"; }"                  0 "a directory without SKILL.md does not resolve"
# EXISTENCE IS NOT LOADABILITY: a SKILL.md the agent's registry would reject must not certify a
# command. Missing frontmatter, and present-but-incomplete frontmatter, both fail.
mkdir -p "$work/sk/nofm"; printf 'just prose\n' > "$work/sk/nofm/SKILL.md"
eq "${ rc_snip '/nofm' "$work/sk"; }"                    0 "SKILL.md without frontmatter does not resolve"
mkdir -p "$work/sk/partialfm"; printf -- '---\nname: partialfm\n---\n' > "$work/sk/partialfm/SKILL.md"
eq "${ rc_snip '/partialfm' "$work/sk"; }"               0 "SKILL.md missing description: does not resolve"
# The marker must declare an INVOCATION. `release` resolves a directory but emits `Next: release`,
# which is not a runnable command.
eq "${ rc_snip '/' "$work/sk"; }"                        0 "a bare prefix with no name does not resolve"
# The PROJECT root is searched too — and is anchored at the git toplevel, not $PWD, so /roadmap
# invoked from a package subdirectory of a monorepo still finds the repo-root skills.
eq "${ rc_snip '/release' "$work/empty-sk" sk; }"        1 "a project-root skill resolves"
# $HOME (or any user root) containing whitespace must not word-split.
mkdir -p "$work/sp ace"; mk_skill "$work/sp ace/release"
eq "${ rc_snip '/release' "$work/sp ace"; }"             1 "a user root containing a space still resolves"
# An EMPTY project subdir (agents with no established project-local discovery, e.g. Codex) must
# search the USER root only — and must not glob, word-split, or resolve from the git root.
eq "${ rc_snip '/release' "$work/sk" ''; }"              1 "empty project subdir still resolves from the user root"
eq "${ rc_snip '/release' "$work/empty-sk" ''; }"        0 "empty project subdir does not fall back to the git root"
# The invocation prefix is RENDERED per agent: Codex uses `$skill`, not a slash command. With a
# `$` prefix, `/release` must be REJECTED and `$release` accepted — the mirror of the Claude case.
# The marker is stored AGENT-NEUTRAL: whatever prefix the author wrote is stripped, and each
# agent's render re-attaches its own. So one artifact is correct on every agent — which is the
# real fix for a Codex adopter copying `/release` out of the schema.
eq "${ rc_snip '$release' "$work/sk" sk '$'; }"          1 "codex render resolves a \$-written marker"
eq "${ rc_snip '/release' "$work/sk" sk '$'; }"          1 "codex render also resolves a /-written marker"
eq "${ rc_snip '$release' "$work/sk" sk '/'; }"          1 "claude render resolves a \$-written marker"
eq "${ rc_snip 'release'  "$work/sk" sk '/'; }"          1 "a bare name resolves (prefix is re-attached)"
eq "${ rc_snip '/your-skill' "$work/sk" sk '/'; }"       0 "the schema placeholder never resolves"
# `name: # TODO` parses as YAML null — the remainder is a comment, so the field is absent.
mkdir -p "$work/sk/todofm"
printf -- '---\nname: # TODO\ndescription: # TODO\n---\n' > "$work/sk/todofm/SKILL.md"
eq "${ rc_snip '/todofm' "$work/sk" sk; }"               0 "a commented-out frontmatter value does not resolve"
# THE AGENT SKILLS NAME GRAMMAR: lowercase hyphen-case, <=64, no leading/trailing/consecutive
# hyphens. A looser check certifies a directory the agent will not register.
# NOT `Release`: macOS is case-insensitive, so that directory IS `release` and mk_skill would
# overwrite the shared fixture's name field, breaking every later /release assertion.
mk_skill "$work/sk/Upcase"
eq "${ rc_snip '/Upcase' "$work/sk" sk '/' user-invocable; }"      0 "an uppercase name does not resolve"
mk_skill "$work/sk/trail-"
eq "${ rc_snip '/trail-' "$work/sk" sk '/' user-invocable; }"      0 "a trailing hyphen does not resolve"
mk_skill "$work/sk/dou--ble"
eq "${ rc_snip '/dou--ble' "$work/sk" sk '/' user-invocable; }"    0 "consecutive hyphens do not resolve"
mk_skill "$work/sk/under_score"
eq "${ rc_snip '/under_score' "$work/sk" sk '/' user-invocable; }" 0 "an underscore does not resolve"
LONGNAME="${ printf 'a%.0s' $(seq 1 65); }"
mk_skill "$work/sk/$LONGNAME"
eq "${ rc_snip "/$LONGNAME" "$work/sk" sk '/' user-invocable; }"   0 "a name over 64 chars does not resolve"
mk_skill "$work/sk/ok-name"
eq "${ rc_snip '/ok-name' "$work/sk" sk '/' user-invocable; }"     1 "valid hyphen-case resolves"
# A TAB is a valid shell argument separator; splitting on a literal space alone leaves it in
# the name and reports an installed skill as missing.
eq "${ rc_snip "${ printf '/release\t--channel prod'; }" "$work/sk" sk '/' user-invocable; }" 1 "tab-separated arguments still resolve"
# A valid unquoted YAML value ends at an inline comment; the loader sees `release`.
mkdir -p "$work/sk/inlinec"
printf -- '---\nname: inlinec # the project cutter\ndescription: d\nuser-invocable: true\n---\n' > "$work/sk/inlinec/SKILL.md"
eq "${ rc_snip '/inlinec' "$work/sk" sk '/' user-invocable; }"  1 "an inline YAML comment after the name resolves"
mkdir -p "$work/sk/quotedc"
printf -- '---\nname: "quotedc" # note\ndescription: d\nuser-invocable: true\n---\n' > "$work/sk/quotedc/SKILL.md"
eq "${ rc_snip '/quotedc' "$work/sk" sk '/' user-invocable; }"  1 "a quoted name with a trailing comment resolves"
# Structure never declares: a marker inside a fence, blockquote or code span is documentation.
eq "$(printf '\140\140\140\n<!-- release-command: fenced -->\n\140\140\140\n' \
      | bash "$RL" release-command | sed "/^$/d" | wc -l | tr -d " ")" 0 "a fenced marker declares nothing"
eq "$(printf '> <!-- release-command: bq -->\n' \
      | bash "$RL" release-command | sed "/^$/d" | wc -l | tr -d " ")" 0 "a blockquoted marker declares nothing"
# `user-invocable: false` is an explicit statement that the operator cannot invoke the skill.
mkdir -p "$work/sk/notinvocable"
printf -- '---\nname: notinvocable\ndescription: d\nuser-invocable: false\n---\n' > "$work/sk/notinvocable/SKILL.md"
eq "${ rc_snip '/notinvocable' "$work/sk" sk '/' user-invocable; }" 0 "user-invocable: false does not resolve"
# An untrusted name reaching grep as an OPTION exits 0 with no match, certifying a phantom skill.
eq "${ rc_snip '/--help' "$work/sk" sk '/' user-invocable; }"    0 "an option-shaped name does not resolve"
eq "${ rc_snip '/../escape' "$work/sk" sk '/' user-invocable; }" 0 "a path-traversal name does not resolve"
# The LEGACY schema example every upgraded artifact carries must not read as a declaration.
eq "$(printf 'Optionally `<!-- release-command: /release -->` overrides it.\n' \
      | bash "$RL" release-command | sed "/^$/d" | wc -l | tr -d " ")" 0 "the backticked schema example declares nothing"
eq "$(printf '<!-- release-command: release -->\n' \
      | bash "$RL" release-command)" release "a top-level declaration is read"
# A QUOTED YAML name is valid and registers fine; a raw compare would reject it.
mkdir -p "$work/sk/quoted"
printf -- '---\nname: "quoted"\ndescription: d\nuser-invocable: true\n---\n' > "$work/sk/quoted/SKILL.md"
eq "${ rc_snip '/quoted' "$work/sk" sk '/' user-invocable; }"    1 "a quoted YAML name resolves"
# The FIRST line must be the opening `---`. A file whose frontmatter starts later is rejected by
# the loader, but a scan that skips line 1 finds the later delimiter and calls it the close.
mkdir -p "$work/sk/lateopen"
printf 'stray prose\n---\nname: lateopen\ndescription: d\nuser-invocable: true\n---\n' > "$work/sk/lateopen/SKILL.md"
eq "${ rc_snip '/lateopen' "$work/sk" sk '/' user-invocable; }" 0 "frontmatter not starting at line 1 does not resolve"
# A repo path containing SPACES must not word-split the project root.
mkdir -p "$work/sp dir"; cp -R "$work/sk" "$work/sp dir/sk"
( cd "$work/sp dir" && :; )
eq "${ rc_snip '/release' "$work/empty-sk" sk '/' user-invocable '' "$work/sp dir"; }" 1 "a project root containing spaces still resolves"
# The loader contract, per agent. `name` must EQUAL the directory (a mismatch is the
# misidentified-skill case build.sh refuses), and Claude additionally requires `user-invocable`.
mkdir -p "$work/sk/misnamed"
printf -- '---\nname: something-else\ndescription: d\nuser-invocable: true\n---\n' > "$work/sk/misnamed/SKILL.md"
eq "${ rc_snip '/misnamed' "$work/sk" sk '/' user-invocable; }"  0 "name not matching the directory does not resolve"
mkdir -p "$work/sk/noinvoke"
printf -- '---\nname: noinvoke\ndescription: d\n---\n' > "$work/sk/noinvoke/SKILL.md"
eq "${ rc_snip '/noinvoke' "$work/sk" sk '/' user-invocable; }" 0 "Claude: missing user-invocable does not resolve"
eq "${ rc_snip '/noinvoke' "$work/sk" sk '/' ''; }"            1 "Codex/Antigravity: name+description suffice"
# Frontmatter must be CLOSED. An unterminated block is an incomplete edit the loader rejects.
mkdir -p "$work/sk/unclosed"
printf -- '---\nname: unclosed\ndescription: d\n' > "$work/sk/unclosed/SKILL.md"
eq "${ rc_snip '/unclosed' "$work/sk" sk; }"             0 "unterminated frontmatter does not resolve"
# ...and the values must be non-empty.
mkdir -p "$work/sk/emptyval"
printf -- '---\nname:\ndescription:\n---\n' > "$work/sk/emptyval/SKILL.md"
eq "${ rc_snip '/emptyval' "$work/sk" sk; }"             0 "empty frontmatter values do not resolve"

# ============================================================================================
# 9. AUTO-COMPOSITION — an empty release milestone is filled, not reported (D15 / #80)
# ============================================================================================
# WHY END-TO-END AND NOT JUST THE PREDICATE. check-roadmap.sh proves `compose-candidates` ranks
# correctly. What it cannot prove is that the shell the workflow hands an agent actually promotes
# anything — and the failure mode that matters is not "promoted the wrong issue", it is
# "promoted WITHOUT the release-blocker label", which arms the milestone with zero blockers so the
# next run reads `met` and emits a cut for a release nobody built. That is a property of the
# snippet's argv, so it is only visible here.

# compose_issues <spec>... — open-issues.json for composition. Spec: `N` (enhancement),
# `N!` (bug), `N>P` (declares `Depends on #P` in its body), `N@Title` (a milestone other than the
# backlog), combinable as `N!>P@Title`. Default milestone is `Backlog`, because composition draws
# ONLY from the backlog membership — a fixture left unmilestoned would be filtered out and every
# case here would pass by composing nothing.
compose_issues() {
  { printf '['
    local first=1 spec n dep ms labels body
    for spec in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      n="$spec"; dep=""; ms="Backlog"; labels='[{"name":"enhancement"}]'; body=""
      case "$n" in *'@'*) ms="${n#*@}"; n="${n%%@*}" ;; esac
      case "$n" in *'>'*) dep="${n#*>}"; n="${n%%>*}" ;; esac
      case "$n" in *'!') n="${n%!}"; labels='[{"name":"bug"}]' ;; esac
      [ -z "$dep" ] || body="Depends on #$dep"
      if [ "$ms" = "none" ]; then
        printf '{"number":%s,"state":"open","title":"issue %s","body":"%s","labels":%s,"milestone":null}' \
          "$n" "$n" "$body" "$labels"
      else
        printf '{"number":%s,"state":"open","title":"issue %s","body":"%s","labels":%s,"milestone":{"title":"%s"}}' \
          "$n" "$n" "$body" "$labels" "$ms"
      fi
    done
    printf ']\n'
  } > "$FIX/open-issues.json"
}
# artifact_body <text> — append the roadmap artifact (#31) to open-issues.json carrying <text>.
# The Decisions-edge source is the artifact itself, so a case that exercises it needs the artifact
# present in the SAME open read.
artifact_body() {
  local body; body="${ printf '%s' "$1" | jq -Rs .; }"
  jq --argjson a "{\"number\":31,\"state\":\"open\",\"title\":\"roadmap\",\"labels\":[{\"name\":\"roadmap\"}],\"milestone\":null,\"body\":$body}" \
     '. + [$a]' "$FIX/open-issues.json" > "$FIX/open-issues.json.tmp" \
     && mv "$FIX/open-issues.json.tmp" "$FIX/open-issues.json"
}
# promoted — the issue numbers the snippet actually promoted, ascending, space-joined.
promoted() {
  grep '^issue edit ' "$FIX/calls" 2>/dev/null | awk '{print $3}' | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# --- 9a. bugs are the floor: every bug is promoted, enhancements are not ---------------------
fix_default
compose_issues '102!' '112!' 20 80 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "$RC_" 0 "the compose snippet runs clean"
eq "${ promoted; }" "102 112" "every open bug is promoted; enhancements are not"
has "$OUT" "composed: #102 -> Next release (release-blocker)" "each promotion reports one line"
has "$OUT" "rider candidates" "the enhancement slate is printed for judgement"

# --- 9b. THE PHANTOM-CUT GUARD: every promotion carries the blocker label --------------------
# A milestone armed with issues that carry NO release-blocker label reads `met` on the next run
# (`release-ready 1 1 0 N 0 green` -> met) and emits a cut for a release nothing has built.
eq "$(grep -- '--add-label release-blocker' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 2 \
   "every promotion carries --add-label release-blocker"
eq "$(grep -- '--milestone Next release' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 2 \
   "...and names the milestone by TITLE, resolved from its number"

# --- 9c. dependency closure: a prerequisite is pulled in even when it is not a bug -----------
# Without this the milestone holds a blocker whose prerequisite sits in the backlog — it can never
# close, so /roadmap reports `unmet` forever and the loop stops terminating one step further in.
fix_default
compose_issues '136!>55' 55 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "55 136" "a bug's open prerequisite is promoted with it, even as an enhancement"

# --- 9c-bis. closure is TRANSITIVE --------------------------------------------------------
fix_default
compose_issues '136!>55' '55>62' 62 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "55 62 136" "closure follows the chain to its end, not one hop"

# --- 9c-ter. a CLOSED prerequisite is satisfied and pulls nothing in -------------------------
# #999 is absent from the open read, so the edge is already satisfied.
fix_default
compose_issues '136!>999' 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "136" "a prerequisite that is not open is satisfied and promotes nothing extra"

# --- 9d. --no-autofix is read-only ----------------------------------------------------------
fix_default
compose_issues '102!' 31
ADB_RELEASE_MODE=1 ADB_NO_AUTOFIX=1 run_snippet compose-candidates >/dev/null
eq "$RC_" 0 "--no-autofix exits clean"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 "--no-autofix performs NO tracker write"
has "$OUT" "no-autofix" "...and says why"

# --- 9e. classic mode composes nothing ------------------------------------------------------
fix_default
compose_issues '102!' 31
ADB_RELEASE_MODE=0 run_snippet compose-candidates >/dev/null
eq "$RC_" 0 "classic mode exits clean"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 \
   "a repo that never adopted the convention is never composed for"

# --- 9f. no bugs open: the floor is empty, and nothing is promoted by accident ---------------
# Promoting an unlabeled rider here is exactly how a phantom cut is armed, so the snippet must
# write NOTHING and hand the decision back.
fix_default
compose_issues 20 80 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "$RC_" 0 "an all-enhancement backlog exits clean"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 "no bugs -> no automatic promotion"
has "$OUT" "no promotable bugs" "...and the empty floor is stated"

# --- 9g. the roadmap artifact is never promoted into the release it plans --------------------
fix_default
compose_issues '31!' '102!'
ADB_RELEASE_MODE=1 ADB_ROADMAP_NUM=31 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "102" "the roadmap issue is excluded even when it carries the bug label"

# --- 9h. hard stops: a failed read never composes a release out of nothing -------------------
fix_default; compose_issues '102!' 31; : > "$FIX/fail-openissues"
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
no "$RC_" "a failed open-issue read is a hard stop"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 "...and writes nothing on the way out"
fix_default; compose_issues '102!' 31; : > "$FIX/fail-milestones"
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
no "$RC_" "a failed milestone read is a hard stop"

# --- 9i. an unresolvable milestone number refuses rather than promoting into nothing ---------
fix_default; compose_issues '102!' 31
ADB_RELEASE_MODE=1 ADB_M_NUM=4242 run_snippet compose-candidates >/dev/null
no "$RC_" "a milestone number with no open title is a hard stop"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 "...and promotes nothing"

# --- 9k. A NON-EMPTY MILESTONE IS NEVER ADDED TO — the scope-drift guard, structural ---------
# This is the whole answer to #80's objection, so it must be code rather than calling prose: a
# re-run after composition would otherwise promote every bug filed since into a set the owner
# already froze. Open and closed members both count as "composed".
fix_default
compose_issues '102!' '112!' 31
printf '[{"number":77,"state":"open","labels":[],"title":"already composed"}]\n' > "$FIX/milestone-issues.json"
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "$RC_" 0 "a non-empty milestone exits clean"
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 \
   "a milestone that already holds work is never added to"
has "$OUT" "already holds" "...and says so"
# A milestone holding only CLOSED work is mid-cycle, not fresh.
fix_default
compose_issues '102!' 31
printf '[{"number":77,"state":"closed","labels":[],"title":"delivered"}]\n' > "$FIX/milestone-issues.json"
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 \
   "a milestone holding only closed issues is a composed set, not an empty one"
# ...but the roadmap artifact sitting in the milestone does NOT make it non-empty.
fix_default
compose_issues '102!' 31
printf '[{"number":31,"state":"open","labels":[{"name":"roadmap"}],"title":"the roadmap"}]\n' > "$FIX/milestone-issues.json"
ADB_RELEASE_MODE=1 ADB_ROADMAP_NUM=31 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "102" "the artifact itself never counts as a composed member"

# --- 9l. NON-IMPLEMENTABLE ISSUES ARE NEVER PROMOTED (review round 1) -----------------------
# A `bug` that step 4 classified `tracker-only` or `owner-review` is never emitted by the advance
# logic. Promoting it on the strength of its LABEL alone arms the milestone with a blocker that
# nothing can close: readiness stays `unmet` forever and the release stops terminating — the same
# stall auto-composition exists to remove, one step further in.
fix_default
compose_issues '102!' '112!' 31
ADB_RELEASE_MODE=1 ADB_EXCLUDE="112" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "102" "an excluded (tracker-only / owner-review) bug is not promoted"

# ...and a bug whose PREREQUISITE is excluded is dropped too, with the reason stated.
fix_default
compose_issues '136!>112' '112!' 31
ADB_RELEASE_MODE=1 ADB_EXCLUDE="112" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "" "a bug whose prerequisite is excluded is not promoted either"
has "$OUT" "#136 NOT promoted" "...and the drop is reported, never silent"

# COMPOSE_EXCLUDE must be SET, even when empty — a silently-unset exclusion set is the bug above.
#
# This case builds the snippet by hand (rather than via run_snippet) precisely so it can OMIT
# COMPOSE_EXCLUDE, so it must resolve {{ROADMAP_LIB}} itself the way run_snippet does. Without
# that the snippet's own guards fail as `{{ROADMAP_LIB}}: command not found` and the run stops for
# a reason that has nothing to do with the variable under test — which is what happened when #218
# added a `slug-ok` guard ahead of this point.
fix_default
compose_issues '102!' 31
_cc="${ snippet compose-candidates; }"
_cc="${_cc//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}"
OUT="$(PATH="$SBIN:$PATH" ADB_FIX="$FIX" bash -c "
  set -u
  M_NUM=9; ROADMAP_NUM=31; RELEASE_MODE=1
  $_cc" 2>&1)"; RC_=$?
no "$RC_" "an UNSET COMPOSE_EXCLUDE is a hard stop, not an empty set"
has "$OUT" "COMPOSE_EXCLUDE" "...and the message names the variable"

# --- 9m. A CANCELED PREREQUISITE STILL BLOCKS (review round 1) -------------------------------
# Closed `NOT_PLANNED` means abandoned, not delivered — step 4's `dep-canceled` rule. Treating it
# like a completed close promotes a bug whose prerequisite is never coming.
fix_default
compose_issues '136!>99' '102!' 31
printf '{"number":99,"state":"closed","state_reason":"not_planned"}\n' > "$FIX/issue-99.json"
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "102" "a bug whose prerequisite was CANCELED is not promoted"
has "$OUT" "#136 NOT promoted" "...and says which prerequisite cannot be promoted"
# ...while a prerequisite closed as COMPLETED is genuinely satisfied.
fix_default
compose_issues '136!>99' 31
printf '{"number":99,"state":"closed","state_reason":"completed"}\n' > "$FIX/issue-99.json"
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "136" "a prerequisite closed as COMPLETED is satisfied and blocks nothing"

# --- 9n. ISSUES IN ANOTHER MILESTONE ARE NOT CANDIDATES (review round 1) ---------------------
# An issue slated into some other milestone carries a scope decision an owner already made;
# `gh issue edit --milestone` would silently overwrite it, and step 4b calls choosing a slated
# issue's milestone an owner escalation.
fix_default
compose_issues '102!' '200!@v2.0' 31
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "102" "a bug already slated into another milestone is never reassigned"
# ...and it is not silently pulled in as a prerequisite either.
fix_default
compose_issues '136!>200' '200!@v2.0' 31
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "" "...nor dragged in through another issue's dependency closure"

# --- 9o. DECISIONS ROWS ARE AN EDGE SOURCE (review round 1) ----------------------------------
# Step 4 defines the edge set as issue bodies UNION the artifact's `## Decisions` rows. Reading
# only bodies loses an edge reconcile already knew, and the dependent gets promoted while its
# prerequisite stays in the backlog.
fix_default
compose_issues '73!' 78
artifact_body '## Decisions

| Question | Decision | Recorded |
| --- | --- | --- |
| dep-outside-release:#73 | Re-scoped to a thin driver; Depends on #78 only. | #73 body |'
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "73 78" "an edge declared only in a Decisions row still pulls its prerequisite in"

# ...and attribution is PER ROW: a second row must not cross-multiply into a fabricated edge.
fix_default
compose_issues '73!' 78 '90!'
artifact_body '## Decisions

| Question | Decision | Recorded |
| --- | --- | --- |
| dep-outside-release:#73 | Depends on #78 only. | #73 body |
| install-currency:#90 | No dependency; a policy note. | #90 body |'
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "73 78 90" "a second decision row declares nothing extra (no cross-product edges)"

# --- 9p. --no-autofix PREVIEWS the slate instead of a generic message (review round 1) -------
# The refusal contract promises to say what a normal run WOULD have promoted; returning before the
# slate is computed can only print "reporting only", which is not an audit of a new mutation.
fix_default
compose_issues '102!' '112!' 20 31
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" ADB_NO_AUTOFIX=1 run_snippet compose-candidates >/dev/null
eq "$(grep 'issue edit' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 0 "--no-autofix still writes nothing"
has "$OUT" "would promote 2 issue(s)" "--no-autofix names how many it would have promoted"
has "$OUT" "102" "...and which"
has "$OUT" "rider candidates" "...and still prints the rider slate"

# --- 9q. PARTIAL COMPOSITION ROLLS BACK (review round 1) ------------------------------------
# Stopping halfway leaves the milestone non-empty, and the emptiness guard would then refuse to
# compose ever again — freezing the release around whichever prefix happened to succeed while the
# rest of the bugs sit in the backlog. Undo instead, so the next run retries the whole selection.
fix_default
compose_issues '102!' '112!' 31
# Fail every promotion past the first, then assert the rollback returns the milestone to empty.
printf '1\n' > "$FIX/fail-edit-after"
ADB_RELEASE_MODE=1 ADB_EXCLUDE="" run_snippet compose-candidates >/dev/null
no "$RC_" "a failed promotion is a hard stop"
has "$OUT" "rolling back" "...and says it is rolling back"
eq "$(grep -- '--remove-label release-blocker' "$FIX/calls" 2>/dev/null | wc -l | tr -d ' ')" 1 \
   "the already-promoted issue is returned to the backlog and unlabelled"
has "$OUT" "is empty again" "...and states the milestone is composable again"

# --- 9j. determinism: two runs over an unchanged tracker promote the same set ----------------
fix_default; compose_issues '102!' '112!>20' 20 80 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null; FIRST="${ promoted; }"
fix_default; compose_issues '102!' '112!>20' 20 80 31
ADB_RELEASE_MODE=1 run_snippet compose-candidates >/dev/null
eq "${ promoted; }" "$FIRST" "composition is deterministic over an unchanged tracker"
eq "$FIRST" "20 102 112" "...and closes the chain it selected"

# ============================================================================================
# 8. THE HARNESS GUARDS ITSELF
# ============================================================================================
# THE SET THIS HARNESS EXECUTES IS THE SET THE WORKFLOW DOCUMENTS (#376). The list used to be
# hand-copied into each loop below, and a hand-copied list is how `adopt-ownership` — the gate that
# refuses to adopt an artifact an outside account can keep rewriting — shipped documented, parsed
# by nothing and executed by nothing, for as long as it took someone to count the markers by hand.
# Both sides pass through the SAME sort, so this compares sets rather than orderings — a name
# added to the list in the wrong position must not fail for a reason that is not the point. A new
# marker fails these guards until a case EXECUTES it: the declared list must match the documented
# markers, and the names run_snippet/rc_snip actually ran must match the declared list, so a name
# parked in EXECUTED with zero cases is caught too (#376 review). A renamed marker fails from the
# other side.
EXECUTED=(locate-artifact adopt-scan adopt-ownership fresh-read readiness gauge
          autofix-unmilestoned release-command compose-candidates owner-action)
# The listing anchor is BYTE-IDENTICAL to check_wf_snippet's (check-lib.sh, the one home for the
# marker contract): the extractor accepts ANY name running to end of line, so a narrower listing
# grammar — the `[a-z-]+` this replaced — is how a documented `2fa-gate` stayed invisible and a
# `gauge2` truncated into `gauge` and deduped away (#376 review; #390 lifts the listing itself
# into that home).
mapfile -t DOCUMENTED < <(sed -n 's/^[[:space:]]*# ADB-SNIPPET: //p' "$WF" | LC_ALL=C sort -u)
mapfile -t EXEC_SORTED < <(printf '%s\n' "${EXECUTED[@]}" | LC_ALL=C sort -u)
eq "${DOCUMENTED[*]}" "${EXEC_SORTED[*]}" \
  "every '# ADB-SNIPPET' marker in roadmap.md is executed by this harness, and no more"
mapfile -t RAN < <(LC_ALL=C sort -u "$work/ran" 2>/dev/null)
eq "${EXEC_SORTED[*]}" "${RAN[*]}" \
  "every name EXECUTED declares was actually RUN by a case above (a declaration with zero cases cannot pass)"

# Every snippet this file claims to execute must still exist. Without this, renaming a marker
# would make run_snippet quietly find nothing and the suite would go green on zero coverage.
for s in "${EXECUTED[@]}"; do
  if [ -n "${ snippet "$s"; }" ]; then ok; else bad "workflow lost its '# ADB-SNIPPET: $s' marker"; fi
done

# EVERY snippet must PARSE, checked independently of whether a scenario above happens to execute
# the failing line. This is the cheapest guard in the file and it has already earned its place: an
# apostrophe inside a `${VAR:?word}` message is a syntax error even within double quotes, and bash
# then refuses the WHOLE snippet — a fail-loud guard that silently broke everything around it.
for s in "${EXECUTED[@]}"; do
  body="${ snippet "$s"; }"
  [ -n "$body" ] || continue
  body="${body//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}"
  body="${body//\{\{SKILLS_SUBDIRS\}\}/.claude\/skills}"
  body="${body//\{\{SKILL_REGISTRY_PROBE\}\}/}"
  body="${body//\{\{SKILLS_USER_ROOT\}\}/\"\$HOME\/.claude\/skills\"}"
  body="${body//\{\{SKILL_PREFIX\}\}/\/}"
  body="${body//\{\{SKILL_EXTRA_KEY\}\}/user-invocable}"
  body="${body//\{\{REPO_SETTINGS_LIB\}\}/bash \"$ROOT/scripts/lib/repo-settings.sh\"}"
  body="${body//\{\{ACTIONS_APP_SLUG\}\}/$ACTIONS_SLUG}"
  printf '%s\n' "$body" > "$work/parse-$s.sh"
  if bash -n "$work/parse-$s.sh" 2>/dev/null; then ok; else
    bad "snippet '$s' is not valid bash: $(bash -n "$work/parse-$s.sh" 2>&1 | head -1)"
  fi
done
# A snippet body must not ship an unresolved placeholder: build.sh maps {{…}} per agent, so a
# token added to a snippet without a mapping would reach a user as literal text.
allsnips="$(for s in "${EXECUTED[@]}"; do snippet "$s"; done)"
allsnips="${allsnips//\{\{ROADMAP_LIB\}\}/}"
allsnips="${allsnips//\{\{SKILLS_SUBDIRS\}\}/}"
allsnips="${allsnips//\{\{SKILL_REGISTRY_PROBE\}\}/}"
allsnips="${allsnips//\{\{SKILLS_USER_ROOT\}\}/}"
allsnips="${allsnips//\{\{SKILL_PREFIX\}\}/}"
allsnips="${allsnips//\{\{SKILL_EXTRA_KEY\}\}/}"
allsnips="${allsnips//\{\{REPO_SETTINGS_LIB\}\}/}"
allsnips="${allsnips//\{\{ACTIONS_APP_SLUG\}\}/}"
hasnt "$allsnips" '{{' \
  "no executed snippet carries a placeholder outside the mapped vocabulary"

# THE STUB'S REF GUARDS, observed failing (#376 review). No documented snippet addresses a branch
# or commit the fixtures do not declare, so only a direct probe can watch these arms refuse — and
# an unobserved refusal is a guard whose failure mode is silence. Each probe drives the real stub
# through PATH exactly as a snippet reaches it.
fix_default
OUT="$(PATH="$SBIN:$PATH" ADB_FIX="$FIX" gh api repos/acme/widget/commits/nonexistent/status 2>&1)"; RC_=$?
no "$RC_" "the stub refuses a status read for a branch the repo fixture does not declare"
has "$OUT" "no branch 'nonexistent'" "...and the refusal names the branch"
OUT="$(PATH="$SBIN:$PATH" ADB_FIX="$FIX" gh api repos/acme/widget/branches/nonexistent 2>&1)"; RC_=$?
no "$RC_" "the stub refuses a branch-protection read for an undeclared branch too"
has "$OUT" "no branch 'nonexistent'" "...with the same refusal"
OUT="$(PATH="$SBIN:$PATH" ADB_FIX="$FIX" gh api repos/acme/widget/commits/deadbeef/check-runs 2>&1)"; RC_=$?
no "$RC_" "the stub refuses a check-runs read for a sha the status fixture did not resolve"
has "$OUT" "no commit 'deadbeef'" "...naming the sha"
# ...and the shared branch deriver fails CLOSED: a missing repo fixture is a harness defect and
# must never quietly become `main` — that fail-open is the assumption the arms exist to police.
rm -f "$FIX/repo"
OUT="$(PATH="$SBIN:$PATH" ADB_FIX="$FIX" gh api repos/acme/widget/branches/main 2>&1)"; RC_=$?
eq "$RC_" 91 "asked to derive the default branch with no repo fixture, the stub refuses distinctly (91)"
has "$OUT" "cannot derive the default branch" "...and says which fixture is broken"
fix_default

check_summary "roadmap-e2e"
