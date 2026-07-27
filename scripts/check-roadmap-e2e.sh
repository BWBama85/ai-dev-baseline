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
cat > "$SBIN/gh" <<'STUB'
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
    -f)          i=$((i+1)); v="${args[$i]:-}"; case "$v" in q=*) qval="${v#q=}" ;; esac ;;
    --body-file) i=$((i+1)); bodyfile="${args[$i]:-}" ;;
    repos/*|search/*) [ -z "$url" ] && url="$a" ;;
  esac
  i=$((i+1))
done

emit() {  # emit <file> — print the fixture, applying --jq when one was given
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" < "$1"; else cat "$1"; fi
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
        # The gauge scopes by milestone; the completeness cross-check does not. Answer each from
        # its own fixture so a snippet that drops the milestone qualifier is visible as a wrong count.
        case "$qval" in
          *milestone:*) emit "$F/search-milestone.json" ;;
          *)            emit "$F/search-total.json" ;;
        esac ;;
      */labels/*)
        lbl="${url##*/labels/}"
        grep -qx "$lbl" "$F/labels.txt" 2>/dev/null || { echo "gh: Not Found" >&2; exit 1; }
        printf '{"name":"%s"}\n' "$lbl" ;;
      # --- #78 branch health: three distinct reads, each independently failable ---------------
      # Ordered before the bare `repos/OWNER/REPO` arm below, which would otherwise swallow them.
      */check-runs*)
        fail_if checkruns
        emit "$F/check-runs.json" ;;
      */commits/*/status*)
        fail_if commitstatus
        emit "$F/commit-status.json" ;;
      */actions/workflows*)
        fail_if workflows
        emit "$F/workflows.json" ;;
      *issues\?milestone=*)
        fail_if milestone
        emit "$F/milestone-issues.json" ;;
      *milestones\?state=open*)
        fail_if milestones
        emit "$F/milestones.json" ;;
      *issues\?state=open*)
        fail_if openissues
        emit "$F/open-issues.json" ;;
      *) echo "gh stub: unhandled api url: $url" >&2; exit 90 ;;
    esac ;;
  issue)
    case "$sub2" in
      list)
        fail_if issuelist
        cat "$F/roadmap-nums" 2>/dev/null || true ;;
      edit|create|comment)
        printf 'issue %s %s %s\n' "$sub2" "${args[0]:-}" "${bodyfile:+body-file}" >> "$F/calls"
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
chmod +x "$SBIN/gh"

# ============================================================================================
# Snippet extraction — the point of the harness
# ============================================================================================
# snippet <name> — the fenced bash between `# ADB-SNIPPET: <name>` and the closing fence.
snippet() {
  awk -v want="$1" '
    $0 ~ ("^[[:space:]]*# ADB-SNIPPET: " want "$") { inb = 1; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { exit }
    inb { print }
  ' "$WF"
}

# run_snippet <name> [tail-code] — execute the documented snippet against the stub, with the
# {{ROADMAP_LIB}} placeholder resolved exactly as scripts/build.sh resolves it for a real agent.
# Prints the snippet's stdout (plus the tail's); sets RC_ to its exit status.
run_snippet() {
  local name="$1" tail_code="${2:-}" code
  code="$(snippet "$name")"
  if [ -z "$code" ]; then
    bad "snippet '$name' not found in base/workflows/roadmap.md (marker removed or renamed?)"
    RC_=90; OUT=""; return 1
  fi
  code="${code//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}"
  # The preamble supplies exactly what an EARLIER step would have produced — the selected member,
  # the resolved milestone number, the artifact number, the configured gauge label. Nothing else:
  # anything a snippet needs beyond these it must resolve itself, which is the property the
  # workflow states and the reason two snippets were found relying on a caller's variables.
  OUT="$(
    PATH="$SBIN:$PATH" ADB_FIX="$FIX" bash -c "
      set -u
      N=\${ADB_N:-1}
      M_NUM=\${ADB_M_NUM:-9}
      ROADMAP_NUM=\${ADB_ROADMAP_NUM:-31}
      LABEL=\${ADB_LABEL-release-blocker}
      BACKLOG_TITLE=\${ADB_BACKLOG:-Backlog}
      NO_AUTOFIX=\${ADB_NO_AUTOFIX:-0}
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
  rm -f "$FIX"/fail-* "$FIX/calls"
  printf '{"nameWithOwner":"acme/widget","defaultBranchRef":{"name":"main"}}\n' > "$FIX/repo"
  printf '31\n'                          > "$FIX/roadmap-nums"
  printf 'release-blocker\nroadmap\n'    > "$FIX/labels.txt"
  printf '[]\n'                          > "$FIX/open-prs.json"
  open_issues 5 12 31
  printf '{"total_count":3}\n'           > "$FIX/search-total.json"
  printf '{"total_count":1}\n'           > "$FIX/search-milestone.json"
  printf '[]\n'                          > "$FIX/milestone-issues.json"
  printf '[{"number":8,"title":"Backlog"},{"number":9,"title":"Next release"}]\n' > "$FIX/milestones.json"
  health_green
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
# health_set <check-runs-json> <statuses-json> <active-workflow-count>
# The commit-status fixture carries `sha` because that is where the snippet resolves HEAD from —
# one request answering both "which commit" and "what do the non-Actions providers say".
health_set() {
  printf '{"check_runs":%s}\n' "$1"                          > "$FIX/check-runs.json"
  printf '{"sha":"%s","state":"x","statuses":%s}\n' "$E2E_SHA" "$2" > "$FIX/commit-status.json"
  printf '{"workflows":%s}\n' "$(wf_arr "$3")"               > "$FIX/workflows.json"
}
# ck1 <status> <conclusion-json> [sha] — the single-check-run fixture the health cases vary.
ck1() { printf '[{"name":"ci","head_sha":"%s","status":"%s","conclusion":%s}]' "${3:-$E2E_SHA}" "$1" "$2"; }
health_green()  { health_set "$(ck1 completed '"success"')" '[]' 1; }
health_red()    { health_set "$(ck1 completed '"failure"')" '[]' 1; }
health_running(){ health_set "$(ck1 in_progress null)"      '[]' 1; }
health_stale()  { health_set "$(ck1 completed '"success"' deadbeefdeadbeefdeadbeef)" '[]' 1; }
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
      local labels='[]'
      case "$n" in *'!') n="${n%!}"; labels='[{"name":"release-blocker"}]' ;; esac
      if [ "$ms" = "$spec" ]; then
        printf '{"number":%s,"state":"open","title":"i%s","body":"","labels":%s,"milestone":null}' "$n" "$n" "$labels"
      else
        printf '{"number":%s,"state":"open","title":"i%s","body":"","labels":%s,"milestone":{"title":"%s"}}' "$n" "$n" "$labels" "$ms"
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

# --- 3g. determinism: same fixtures, byte-identical output (acceptance §6) ------------------
fix_default
ADB_N=5 run_snippet fresh-read 'printf "%s|%s|%s\n" "$GOT" "$EXPECTED" "$(printf "%s" "$OPEN_NUMS" | tr "\n" ",")"' >/dev/null
first="$OUT"
ADB_N=5 run_snippet fresh-read 'printf "%s|%s|%s\n" "$GOT" "$EXPECTED" "$(printf "%s" "$OPEN_NUMS" | tr "\n" ",")"' >/dev/null
eq "$OUT" "$first" "two runs over an unchanged tracker produce identical reads"

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

# A failed milestone read must hard-stop rather than tabulate an empty (=> unarmed) milestone.
fix_default; : > "$FIX/fail-milestone"
readiness
no "$RC_" "a failing milestone read hard-stops instead of reporting an empty release set"

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

fix_default; ms_drained; health_no_ci
readiness
has "$OUT" "HEALTH=no-ci"  "no checks AND no active workflows => no-ci"
has "$OUT" "VERDICT=met"   "...and a repo with no CI is not deadlocked out of releasing (#24)"

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
# 5. DESTINATION GAUGE (acceptance §8)
# ============================================================================================
fix_default
printf '{"total_count":2}\n' > "$FIX/search-milestone.json"
run_snippet gauge 'printf "N=%s\n" "${N:-unset}"' >/dev/null
eq "$RC_" 0 "the gauge snippet runs clean"

# The label probe is the gate: with the label absent the gauge must be OMITTED, and a 404 is
# explicitly NOT an error — the one carve-out from the hard-stop rule.
fix_default; printf 'roadmap\n' > "$FIX/labels.txt"
run_snippet gauge 'printf "DONE\n"' >/dev/null
eq "$RC_" 0 "a 404 on the label probe is not an error (the gauge line is simply omitted)"
has "$OUT" "DONE" "...and the run continues past it"

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
art_without="$(printf '%s\n' '<!-- ai-dev-baseline:roadmap:v1 -->' '# Build roadmap' '## Dependencies' '- #73 depends on #25')"

answered="$(printf '%s' "$art_with_decision" | bash "$RL" decisions)"
eq "$(printf '%s\n' "$answered" | grep -Fqx 'dep-outside-release:#73' && echo retired || echo asked)" \
   retired "a recorded decision retires its question"
answered="$(printf '%s' "$art_without" | bash "$RL" decisions)"
eq "$(printf '%s\n' "$answered" | grep -Fqx 'dep-outside-release:#73' && echo retired || echo asked)" \
   asked "...and an unrecorded one is still asked"

# The stale edge in `## Dependencies` must NOT survive: edges are re-derived from the live
# sources, and the decision row's own text retires this one.
row="$(printf '%s' "$art_with_decision" | awk -F'|' '/dep-outside-release/ { print $3 }')"
eq "$(printf '%s' "$row" | bash "$RL" deps-from-body | tr '\n' ' ' | sed 's/ $//')" '' \
   "the decision row retires the #25 edge (a negated mention never declares one)"
eq "$(printf 'Depends on #78 only.' | bash "$RL" deps-from-body | tr '\n' ' ' | sed 's/ $//')" '78' \
   "...while the body that replaced it declares the edge that IS real"

# ============================================================================================
# 7. AUTOFIX — repair the unambiguous, escalate the rest (#109)
# ============================================================================================
# The acceptance is behavioral in both directions: a repo with issues in limbo must end the run
# with zero in limbo, AND re-running must change nothing. Both are properties of the SELECTION
# (`milestone == null`), which is why they can be tested without a stateful stub.

# --- 7a. every unmilestoned open issue is repaired, one line each ---------------------------
fix_default
limbo_issues 5 12:Backlog 44 31
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the autofix snippet runs clean"
has "$OUT" "fixed: #5 → milestone Backlog (was unmilestoned)"  "an unmilestoned issue is repaired, not reported"
has "$OUT" "fixed: #44 → milestone Backlog (was unmilestoned)" "...every one of them"
hasnt "$OUT" "#12" "an issue already in a milestone is untouched"
hasnt "$OUT" "fixed: #31" "the roadmap artifact is never moved into the backlog"
eq "$(grep -c 'issue edit' "$FIX/calls" 2>/dev/null || echo 0)" 2 "exactly two tracker writes, one per repaired issue"

# --- 7a-bis. #78: an unmilestoned `release-blocker` is WARNED about, never swept --------------
# The carve-out was previously pinned only by prose greps, so deleting the `| not` from the LIMBO
# filter — which inverts the sweep and manufactures exactly the silent-ignore #78 prevents — would
# have passed every executed test. This drives it end to end: the labeled issue must produce NO
# tracker write, while an unlabeled sibling in the same run is still repaired.
fix_default
limbo_issues 5 '44!' 31
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$RC_" 0 "the autofix snippet runs clean with a stray blocker present"
has "$OUT" "WARN: #44 is an open release-blocker in NO milestone" \
  "an unmilestoned release-blocker is surfaced, not buried in Backlog"
hasnt "$OUT" "fixed: #44" "...and is NOT swept"
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
ADB_ROADMAP_NUM=31 run_snippet autofix-unmilestoned >/dev/null
eq "$OUT" "" "a labeled roadmap artifact is neither swept nor warned about"

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
# 8. THE HARNESS GUARDS ITSELF
# ============================================================================================
# Every snippet this file claims to execute must still exist. Without this, renaming a marker
# would make run_snippet quietly find nothing and the suite would go green on zero coverage.
for s in locate-artifact adopt-scan fresh-read readiness gauge autofix-unmilestoned; do
  if [ -n "$(snippet "$s")" ]; then ok; else bad "workflow lost its '# ADB-SNIPPET: $s' marker"; fi
done

# EVERY snippet must PARSE, checked independently of whether a scenario above happens to execute
# the failing line. This is the cheapest guard in the file and it has already earned its place: an
# apostrophe inside a `${VAR:?word}` message is a syntax error even within double quotes, and bash
# then refuses the WHOLE snippet — a fail-loud guard that silently broke everything around it.
for s in locate-artifact adopt-scan fresh-read readiness gauge autofix-unmilestoned; do
  body="$(snippet "$s")"
  [ -n "$body" ] || continue
  printf '%s\n' "${body//\{\{ROADMAP_LIB\}\}/bash \"$RL\"}" > "$work/parse-$s.sh"
  if bash -n "$work/parse-$s.sh" 2>/dev/null; then ok; else
    bad "snippet '$s' is not valid bash: $(bash -n "$work/parse-$s.sh" 2>&1 | head -1)"
  fi
done
# A snippet body must not ship an unresolved placeholder: build.sh maps {{…}} per agent, so a
# token added to a snippet without a mapping would reach a user as literal text.
allsnips="$(for s in locate-artifact adopt-scan fresh-read readiness gauge autofix-unmilestoned; do snippet "$s"; done)"
hasnt "${allsnips//\{\{ROADMAP_LIB\}\}/}" '{{' \
  "no executed snippet carries a placeholder outside the mapped vocabulary"

check_summary "roadmap-e2e"
