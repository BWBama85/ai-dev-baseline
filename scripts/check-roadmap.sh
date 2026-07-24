#!/usr/bin/env bash
# ai-dev-baseline — behavioral tests for the /roadmap decision predicates (#69) and a
# source-drift guard on the workflow that consumes them (#45).
#
# WHY THIS EXISTS. /roadmap is prose an agent executes against a live tracker, so most of it
# (marker parsing, milestone resolution, bundle projection, artifact rewriting) cannot be unit
# tested without a full mocked-gh harness. What CAN be pinned — and is what actually went wrong
# in #69 — are the two load-bearing DECISIONS, now factored into scripts/lib/roadmap-lib.sh:
#   1. in-flight targeting: does an open PR actually target issue #N?
#   2. release readiness: unarmed / unmet / held / met.
# This test exercises both hermetically (fixture JSON on stdin, no network, no gh), plus a
# drift guard proving the workflow body still delegates to the helper and has NOT regressed to
# the `#N`-substring test. The remaining end-to-end behaviors #45 lists are covered by the
# documented acceptance script in docs/roadmap-acceptance.md.
#
# OFFLINE by construction: the library never calls gh, so this needs only bash + jq.
# Usage: bash scripts/check-roadmap.sh   (exit 0 = all pass, 1 = a failure)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RL="$ROOT/scripts/lib/roadmap-lib.sh"
WF="$ROOT/base/workflows/roadmap.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

SLUG="acme/widget"

# jq is the library's only hard dependency; without it every pr-targets-issue case would exit 2
# and the suite would report a wall of misleading failures. Fail loud and early instead.
if ! command -v jq >/dev/null 2>&1; then
  echo "check-roadmap: FATAL — jq is required to run these tests" >&2
  exit 1
fi

# --- fixture builders ----------------------------------------------------------------------
# ref <number> [owner] [repo] — one closingIssuesReferences entry (defaults to $SLUG's repo).
ref() {
  local n="$1" owner="${2:-acme}" repo="${3:-widget}"
  printf '{"number":%s,"repository":{"name":"%s","owner":{"login":"%s"}}}' "$n" "$repo" "$owner"
}
# pr <number> <body-json> <refs-json-array> — one PR object.
pr() { printf '{"number":%s,"body":%s,"closingIssuesReferences":%s}' "$1" "$2" "$3"; }
# arr <obj>... — wrap objects into a JSON array.
arr() { local IFS=,; printf '[%s]' "$*"; }

# targets <issue> <json> [slug] — run the predicate, echo its exit status.
# NOTE `${3-...}` (not `${3:-...}`): the default applies only when the argument is UNSET, so a
# deliberately EMPTY slug still reaches the library and exercises its validation.
targets() {
  local n="$1" json="$2" slug="${3-$SLUG}"
  printf '%s' "$json" | bash "$RL" pr-targets-issue "$n" "$slug" >/dev/null 2>&1
  printf '%s' "$?"
}
# ready <5 args> — run the readiness predicate, echo its stdout verdict.
# Args: <label-exists> <armed> <open-blockers> <open-issues> <canceled>
ready() { bash "$RL" release-ready "$1" "$2" "$3" "$4" "$5" 2>/dev/null; }
# run <subcommand> <args...> — capture combined output + status into OUT/RC_ (one capture idiom
# for every non-stdin call, so `2>&1` handling can't drift between call sites).
run() { OUT="$(bash "$RL" "$@" 2>&1)"; RC_=$?; }

# ============================================================================================
# 1. IN-FLIGHT TARGETING (#69) — the regression the bug was filed for
# ============================================================================================

# --- 1a. the bug itself: a bare cross-reference must NOT freeze a ready member --------------
# This is #69 verbatim. `Refs #69` / prose ("similar to #69") used to match the `#N` substring
# test and freeze the member forever. Step 5 already says Refs is NOT an edge; now step 6 agrees.
eq "$(targets 69 "$(arr "$(pr 100 '"Refs #69"' '[]')")")" 1 \
   "bare 'Refs #69' does NOT freeze (the #69 bug)"
eq "$(targets 69 "$(arr "$(pr 100 '"similar to #69 but unrelated"' '[]')")")" 1 \
   "prose mention of #69 does NOT freeze"
eq "$(targets 69 "$(arr "$(pr 100 '"See #69 for context. Also #69."' '[]')")")" 1 \
   "repeated non-closing mentions do NOT freeze"

# --- 1b. a PR that genuinely targets the issue DOES freeze ----------------------------------
eq "$(targets 69 "$(arr "$(pr 100 '"unrelated body"' "$(arr "$(ref 69)")")")")" 0 \
   "linked-issue set (closingIssuesReferences) freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes #69"' '[]')")")" 0 \
   "closing keyword in body freezes (stacked/non-default-branch PR GitHub does not auto-link)"
for kw in Closes closes CLOSES Close Closed Fixes fix Fixed Resolves resolve Resolved; do
  eq "$(targets 69 "$(arr "$(pr 100 "\"$kw #69\"" '[]')")")" 0 \
     "closing keyword '$kw' freezes (GitHub's keyword list, case-insensitive)"
done
eq "$(targets 69 "$(arr "$(pr 100 '"Closes: #69"' '[]')")")" 0 \
   "'Closes: #69' (colon form) freezes"

# --- 1c. word-boundary: #7 must never match #70 ---------------------------------------------
# The old test used \b, which this preserves; keep it pinned so a future regex edit can't
# reintroduce prefix matching in either direction.
eq "$(targets 7 "$(arr "$(pr 100 '"Closes #70"' '[]')")")" 1 \
   "#7 does NOT match a body closing #70"
eq "$(targets 7 "$(arr "$(pr 100 '"unrelated"' "$(arr "$(ref 70)")")")")" 1 \
   "#7 does NOT match a linked #70 (numeric compare, not substring)"
eq "$(targets 70 "$(arr "$(pr 100 '"Closes #70"' '[]')")")" 0 \
   "#70 DOES match its own closing keyword"

# --- 1c-bis. the keyword must be a STANDALONE WORD (left boundary) --------------------------
# Caught in self-review: without a leading \b, "precloses #69" matched inside a longer word and
# froze a ready member — the same over-match class #69 is about, just on the keyword side.
for w in precloses unfixes XCloses reresolves deresolved prefix; do
  eq "$(targets 69 "$(arr "$(pr 100 "\"$w #69\"" '[]')")")" 1 \
     "'$w #69' does NOT freeze (keyword must be a standalone word)"
done
# ...while the same keywords still match at a word boundary after punctuation/newlines.
eq "$(targets 69 "$(arr "$(pr 100 '"Some text\nCloses #69\nmore"' '[]')")")" 0 \
   "a closing keyword on its own line freezes (multi-line body)"
eq "$(targets 69 "$(arr "$(pr 100 '"(Closes #69)"' '[]')")")" 0 \
   "a closing keyword after an opening paren freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes #69 — 日本語 🎉"' '[]')")")" 0 \
   "a body with multibyte/emoji content is matched correctly (no encoding corruption)"

# --- 1d. cross-repo safety: other/repo#69 must not freeze this repo's #69 --------------------
# GitHub supports cross-repository closing links, so closingIssuesReferences can carry an issue
# from ANOTHER repo. Matching a bare number would let it freeze this repo's same-numbered issue.
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69 someone other)")")")")" 1 \
   "cross-repo link (someone/other#69) does NOT freeze acme/widget#69"
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69 acme other)")")")")" 1 \
   "same-owner different-repo link does NOT freeze"
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69 other widget)")")")")" 1 \
   "same-repo-name different-owner link does NOT freeze"
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69 someone other)" "$(ref 69)")")")")" 0 \
   "a matching link still freezes when a cross-repo link is also present"

# --- 1e. multi-PR sets: any targeting PR freezes; none targeting does not -------------------
eq "$(targets 69 "$(arr "$(pr 100 '"Refs #69"' '[]')" "$(pr 101 '"Closes #69"' '[]')")")" 0 \
   "one targeting PR among several freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Refs #69"' '[]')" "$(pr 101 '"Closes #45"' "$(arr "$(ref 45)")")")")" 1 \
   "a set where no PR targets #69 does NOT freeze"
eq "$(targets 45 "$(arr "$(pr 100 '"Refs #69"' '[]')" "$(pr 101 '"Closes #45"' "$(arr "$(ref 45)")")")")" 0 \
   "the same set DOES freeze #45 (the one actually targeted)"

# --- 1f. empty / null / absent shapes are a clean negative, never an error ------------------
eq "$(targets 69 '[]')" 1                            "empty PR array = not targeted"
eq "$(targets 69 '')" 1                              "empty stdin (no open PRs) = not targeted"
eq "$(targets 69 '   ')" 1                           "whitespace-only stdin = not targeted"
eq "$(targets 69 "$(arr "$(pr 100 'null' '[]')")")" 1 \
   "a null PR body is handled (not an error, not a match)"
eq "$(targets 69 "$(arr '{"number":100}')")" 1 \
   "a PR object missing body+closingIssuesReferences is handled"
eq "$(targets 69 "$(arr "$(pr 100 'null' "$(arr "$(ref 69)")")")")" 0 \
   "a null body still freezes when the link matches"

# --- 1g. FAIL-CLOSED: a broken input must be an ERROR (>=2), never a silent negative --------
# This is the safety property. If a tooling failure returned 1 ("not targeted"), /roadmap would
# emit an issue that is already being implemented — the duplicate-work class this prevents.
eq "$(targets 69 '{not json')" 2        "malformed JSON is an ERROR (2), not a negative"
eq "$(targets 69 '{"a":1}')" 2          "a JSON object (not an array) is an ERROR (2)"
eq "$(targets 69 '"a string"')" 2       "a JSON string (not an array) is an ERROR (2)"
eq "$(targets 69 '[]' 'no-slash-slug')" 2 "a malformed repo slug is an ERROR (2)"
eq "$(targets 69 '[]' '')" 2              "an empty repo slug is an ERROR (2)"
eq "$(targets 'abc' '[]')" 2              "a non-numeric issue number is an ERROR (2)"
eq "$(targets '' '[]')" 2                 "an empty issue number is an ERROR (2)"
eq "$(targets '-1' '[]')" 2               "a negative issue number is an ERROR (2)"

# --- 1h. jq-metacharacter safety in the slug (no injection into the filter) -----------------
# The slug is passed as a typed --arg, never interpolated into the program text.
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69)")")")" 'a"/b')" 1 \
   "a slug containing a quote is compared literally (no injection, no crash)"
eq "$(targets 69 "$(arr "$(pr 100 '"x"' "$(arr "$(ref 69)")")")" '.*/.*')" 1 \
   "a regex-metacharacter slug does not match by pattern (exact compare)"

# ============================================================================================
# 2. RELEASE READINESS (#71/#27 predicate, scenarios from the #45 owner comment)
# ============================================================================================

# Arg order throughout: <label-exists> <armed> <open-blockers> <open-issues> <canceled>

# --- 2a. armed guard: an empty milestone is neither ready nor complete ----------------------
eq "$(ready 1 0 0 0 0)" unarmed "empty milestone (armed=0) => unarmed, never a cut"
eq "$(ready 0 0 0 0 0)" unarmed "unarmed in fallback mode too"

# --- 2b. blocker-mode (label EXISTS): met iff 0 open release-blockers in the milestone ------
eq "$(ready 1 1 3 9 0)" unmet "blocker-mode with 3 open blockers => unmet"
eq "$(ready 1 1 1 9 0)" unmet "blocker-mode with 1 open blocker => unmet"
eq "$(ready 1 1 0 9 0)" met   "blocker-mode with 0 open blockers => met (open non-blockers roll over)"

# --- 2c. fallback (label ABSENT/404): met iff 0 open issues in the milestone ----------------
eq "$(ready 0 1 0 2 0)" unmet "fallback mode with 2 open issues => unmet"
eq "$(ready 0 1 0 0 0)" met   "fallback mode with 0 open issues => met"

# --- 2b/2c-bis. MODE SELECTION is keyed off label EXISTENCE, never a live count -------------
# The load-bearing rule: the same counts must yield OPPOSITE verdicts depending only on whether
# the label exists. Previously this could only be checked by hand (a manual acceptance
# checkbox) because the predicate ignored the flag; passing both counts makes it executable.
eq "$(ready 1 1 0 5 0)" met   "label EXISTS: 5 open non-blockers do NOT block the cut"
eq "$(ready 0 1 0 5 0)" unmet "label ABSENT: the same 5 open issues DO block the cut"
eq "$(ready 1 1 4 0 0)" unmet "label EXISTS: 4 open blockers block, even with 0 counted issues"
eq "$(ready 0 1 4 0 0)" met   "label ABSENT: the blocker count is IGNORED (fallback reads issues)"

# --- 2d. NOT_PLANNED-canceled blocker withholds the cut for owner review --------------------
eq "$(ready 1 1 0 0 1)" held "count satisfied BUT a canceled blocker => held (owner review)"
eq "$(ready 0 1 0 0 1)" held "held applies in fallback mode too (contradictory input => withhold)"

# --- 2e. precedence — every input maps to exactly one verdict, deterministically ------------
eq "$(ready 1 0 0 0 1)" unarmed "unarmed outranks canceled (nothing to cut in an empty set)"
eq "$(ready 1 1 2 0 1)" unmet   "open blockers outrank canceled (still building)"

# --- 2f. determinism (#45) ------------------------------------------------------------------
# Both predicates are pure functions of their inputs — no clock, RNG, network, or filesystem
# read — which is what makes /roadmap's "two runs, no tracker change => identical emit" contract
# reachable. The verdict table above IS the determinism proof for release-ready (a fixed input
# is asserted against a fixed expected verdict), so re-running it and comparing it to itself
# would add no distinct failure mode. For the targeting predicate, which parses external JSON,
# assert repeat-invocation stability explicitly on one mixed fixture.
fx="$(arr "$(pr 100 '"Refs #69"' '[]')" "$(pr 101 '"Closes #45"' "$(arr "$(ref 45)")")")"
eq "$(targets 69 "$fx")$(targets 69 "$fx")" "11" "pr-targets-issue is deterministic (negative)"
eq "$(targets 45 "$fx")$(targets 45 "$fx")" "00" "pr-targets-issue is deterministic (positive)"
eq "$(ready 1 1 5 0 0)" unmet "an unlisted tuple still lands on exactly one verdict"

# --- 2g. FAIL-CLOSED on bad readiness input -------------------------------------------------
# A fabricated "met" from a bad count would cut a release that isn't ready — the worst failure
# mode in the whole convention. Every malformed argument must exit >=2 with NO verdict printed.
run release-ready 1 1 x 0 0;   eq "$RC_" 2 "non-numeric blocker count is an ERROR"; has "$OUT" "non-negative integer" "count error names the field"
run release-ready 1 1 0 x 0;   eq "$RC_" 2 "non-numeric issue count is an ERROR"
run release-ready 1 1 -1 0 0;  eq "$RC_" 2 "negative count is an ERROR"
run release-ready 2 1 0 0 0;   eq "$RC_" 2 "label-exists=2 is an ERROR";  has "$OUT" "must be 0 or 1" "flag error names the constraint"
run release-ready 1 2 0 0 0;   eq "$RC_" 2 "armed=2 is an ERROR"
run release-ready 1 1 0 0 2;   eq "$RC_" 2 "canceled=2 is an ERROR"
run release-ready 1 1 0 0;     eq "$RC_" 2 "too few args is an ERROR";    has "$OUT" "exactly 5" "arity error states the arity"
run release-ready 1 1 0 0 0 0; eq "$RC_" 2 "too many args is an ERROR"
hasnt "$OUT" "met" "an errored readiness call never prints a verdict"

# --- 2h. dispatch surface -------------------------------------------------------------------
run -h;     yes "$RC_" "-h exits 0"; has "$OUT" "roadmap-lib.sh" "-h prints usage"
run --help; yes "$RC_" "--help exits 0"
run;        eq "$RC_" 2 "no subcommand is an ERROR"
run bogus;  eq "$RC_" 2 "unknown subcommand is an ERROR"
has "$OUT" "unknown subcommand" "unknown subcommand names itself"

# ============================================================================================
# 3. SOURCE-DRIFT GUARD — the workflow must keep delegating to the tested predicate
# ============================================================================================
# The library can be perfect while the skill quietly reverts to inline logic; then these tests
# would pass and /roadmap would still be broken. Pin the consumer side too.
wf="$(cat "$WF" 2>/dev/null)"
hasnt "$wf" 'any(.body|test("#"+$n' \
  "workflow no longer carries the #N-substring in-flight test (#69 regression guard)"
hasnt "$wf" '# must be empty' \
  "workflow no longer carries the comment that mislabeled a boolean as an empty stream (#69)"
has "$wf" 'closingIssuesReferences' \
  "workflow fetches the linked-issue set in its open-PR read"
has "$wf" '{{ROADMAP_LIB}} pr-targets-issue' \
  "workflow delegates in-flight targeting to the shared predicate"
has "$wf" '{{ROADMAP_LIB}} release-ready' \
  "workflow delegates release readiness to the shared predicate"
has "$wf" 'in-flight check failed' \
  "workflow hard-stops the run when the targeting predicate cannot answer (fail-closed)"
has "$wf" 'A failed targeting check is a hard stop, never a negative.' \
  "workflow states the fail-closed rule as an imperative, not only as a snippet comment"
has "$wf" 'readiness predicate failed' \
  "workflow hard-stops the run when the readiness predicate fails"

# Every rendered agent skill must carry the RESOLVED helper path. check-workflow-render.sh
# proves {{ROADMAP_LIB}} substitutes correctly against a synthetic fixture and that no committed
# skill ships an unresolved `{{`; neither of those reads the committed ROADMAP skill for this
# path, so assert it here — that is what catches a rebuild that dropped the delegation.
for a in claude codex gemini; do
  sk="$ROOT/agents/$a/skills/roadmap/SKILL.md"
  if [ -f "$sk" ]; then
    has "$(cat "$sk")" "\$HOME/.$a/scripts/lib/roadmap-lib.sh" \
        "$a roadmap skill resolves {{ROADMAP_LIB}} to its own install path"
  else
    bad "$a roadmap SKILL.md is missing"
  fi
done

check_summary "roadmap"
