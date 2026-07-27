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
# ready <5 args> [health] — run the readiness predicate, echo its stdout verdict.
# Args: <label-exists> <armed> <open-blockers> <open-issues> <canceled> [health]
# `health` defaults to `green` so the TRACKER-precedence table below reads exactly as it did
# before #78 added the sixth input — those cases are about counts, not CI. The health cases pass
# it explicitly. (The REQUIRED arity of the real subcommand is pinned separately, in 2g.)
ready() { bash "$RL" release-ready "$1" "$2" "$3" "$4" "$5" "${6:-green}" 2>/dev/null; }
# health <json> [sha] [workflows] — run branch-health, echo line 1 (the enum).
health() {
  printf '%s' "$1" | bash "$RL" branch-health "${2:-$SHA}" "${3:-1}" 2>/dev/null | sed -n '1p'
}
# health_why <json> [sha] [workflows] — line 2 (the reason), for the cases that must explain.
health_why() {
  printf '%s' "$1" | bash "$RL" branch-health "${2:-$SHA}" "${3:-1}" 2>/dev/null | sed -n '2p'
}
# run_health <args...> — stdin-taking capture, mirroring `run` for the non-stdin subcommands.
run_health() { OUT="$(printf '%s' "$1" | bash "$RL" branch-health "${@:2}" 2>&1)"; RC_=$?; }
# ck <name> <sha> <status> <conclusion> — one check-run object.
ck() { printf '{"name":"%s","head_sha":"%s","status":"%s","conclusion":%s}' \
         "$1" "$2" "$3" "$(if [ "$4" = "null" ]; then printf 'null'; else printf '"%s"' "$4"; fi)"; }
# st <context> <state> — one legacy commit-status object.
st() { printf '{"context":"%s","state":"%s"}' "$1" "$2"; }
# hj <check-objs-csv> <status-objs-csv> — the {check_runs,statuses} document branch-health reads.
hj() { printf '{"check_runs":[%s],"statuses":[%s]}' "$1" "$2"; }

SHA=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
OTHER_SHA=999999999999999999999999999999999999abcd
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

# --- 1c-ter. repository-QUALIFIED closing keywords, for THIS repo only ----------------------
# GitHub documents three reference forms after a closing keyword: `#N`, `owner/repo#N`, and the
# issue URL. The qualified forms matter exactly where the body scan is load-bearing: GitHub does
# not auto-link keywords on a PR whose base is not the default branch, so a stacked PR writing
# the full syntax would otherwise read "not targeted" and let /roadmap emit work it closes.
# (Reported by the codex reviewer on PR #76.)
eq "$(targets 69 "$(arr "$(pr 100 '"Closes acme/widget#69"' '[]')")")" 0 \
   "'Closes acme/widget#69' (repo-qualified, this repo) freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Fixes acme/widget#69"' '[]')")")" 0 \
   "'Fixes acme/widget#69' freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes https://github.com/acme/widget/issues/69"' '[]')")")" 0 \
   "an issue-URL reference to this repo freezes"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes http://github.com/acme/widget/issues/69"' '[]')")")" 0 \
   "the http (non-TLS) issue-URL form freezes too"
# ...and the cross-repo guarantee must survive the widened pattern.
eq "$(targets 69 "$(arr "$(pr 100 '"Closes other/repo#69"' '[]')")")" 1 \
   "'Closes other/repo#69' does NOT freeze (different repo)"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes acme/other#69"' '[]')")")" 1 \
   "same-owner different-repo qualified keyword does NOT freeze"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes https://github.com/other/repo/issues/69"' '[]')")")" 1 \
   "an issue-URL for another repo does NOT freeze"
eq "$(targets 69 "$(arr "$(pr 100 '"Refs acme/widget#69"' '[]')")")" 1 \
   "a qualified reference without a closing keyword does NOT freeze"
eq "$(targets 7 "$(arr "$(pr 100 '"Closes acme/widget#70"' '[]')")")" 1 \
   "#7 does not match a qualified #70 (boundary holds in the widened pattern)"
# The slug is embedded as a LITERAL: a repo name containing regex metacharacters must not match
# by pattern (`acme/my.app` must never match `acme/myXapp`).
eq "$(targets 69 "$(arr "$(pr 100 '"Closes acme/myXapp#69"' '[]')")" 'acme/my.app')" 1 \
   "a '.' in the slug is literal, not a wildcard"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes acme/my.app#69"' '[]')")" 'acme/my.app')" 0 \
   "...while the exact dotted slug still matches"
eq "$(targets 69 "$(arr "$(pr 100 '"Closes acme/c++-lib#69"' '[]')")" 'acme/c++-lib')" 0 \
   "a slug with regex metacharacters (+) matches literally"

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
run release-ready 1 1 x 0 0 green;   eq "$RC_" 2 "non-numeric blocker count is an ERROR"; has "$OUT" "non-negative integer" "count error names the field"
run release-ready 1 1 0 x 0 green;   eq "$RC_" 2 "non-numeric issue count is an ERROR"
run release-ready 1 1 -1 0 0 green;  eq "$RC_" 2 "negative count is an ERROR"
run release-ready 2 1 0 0 0 green;   eq "$RC_" 2 "label-exists=2 is an ERROR";  has "$OUT" "must be 0 or 1" "flag error names the constraint"
run release-ready 1 2 0 0 0 green;   eq "$RC_" 2 "armed=2 is an ERROR"
run release-ready 1 1 0 0 2 green;   eq "$RC_" 2 "canceled=2 is an ERROR"
run release-ready 1 1 0 0 green;     eq "$RC_" 2 "too few args is an ERROR";    has "$OUT" "exactly 6" "arity error states the arity"
run release-ready 1 1 0 0 0 green x; eq "$RC_" 2 "too many args is an ERROR"

# #78: the health argument is REQUIRED, and that is a deliberate fail-LOUD choice. An optional
# sixth argument defaulting to "skip" would let every un-updated caller keep returning `met`
# without ever verifying the build — reopening the hole #78 closed, silently. The old 5-argument
# call must therefore be an ERROR, never a legacy-compatible pass.
run release-ready 1 1 0 0 0
eq "$RC_" 2 "the pre-#78 five-argument call is an ERROR (no silent fail-open)"
hasnt "$OUT" "met" "...and prints no verdict"
# An unrecognised health value must never fall through to `met`.
for bad_health in GREEN red yes '' 'green x'; do
  run release-ready 1 1 0 0 0 "$bad_health"
  eq "$RC_" 2 "health='$bad_health' is an ERROR"
  hasnt "$OUT" "met" "health='$bad_health' prints no 'met' verdict"
done

# A count too wide for a shell integer must ERROR, never fall through. `[ "$n" -gt 0 ]` fails on
# such a value, and because that test guards the `unmet` branch the failure would print `met` —
# inventing a release cut from a value the shell could not evaluate. (Adversarial-review find.)
# NOTE: every tuple below carries the SIXTH (health) argument. Without it the call dies on ARITY
# before it ever reaches the validator under test, so the assertion would still pass while proving
# nothing — which is exactly what happened when #78 bumped the arity 5 -> 6 and these were missed.
run release-ready 1 1 99999999999999999999 0 0 green
eq "$RC_" 2 "an over-wide blocker count is an ERROR, not a fabricated verdict"
hasnt "$OUT" "met" "an over-wide count never yields 'met'"
has "$OUT" "non-negative integer" "...and it fails on the COUNT, not on arity"
run release-ready 0 1 0 99999999999999999999 0 green
eq "$RC_" 2 "an over-wide issue count is an ERROR in fallback mode too"
hasnt "$OUT" "met" "an over-wide fallback count never yields 'met'"
has "$OUT" "non-negative integer" "...and it fails on the COUNT, not on arity"
# 18 digits is inside the supported range and must still compute normally.
eq "$(ready 1 1 999999999999999999 0 0)" unmet "an 18-digit count still evaluates (bound is not over-tight)"

# Every errored readiness call must print no verdict — assert it per call, not just on the last
# one (the previous single check only inspected whichever `run` happened to be most recent).
# The first three are 6-argument tuples so they reach their respective validators; the last is
# deliberately short, to keep the sub-arity path covered too.
for bad_args in "1 1 x 0 0 green" "2 1 0 0 0 green" "1 1 0 0 2 green" "1 1 0 0"; do
  # shellcheck disable=SC2086  # deliberate word-split of the fixture arg string
  run release-ready $bad_args
  eq "$RC_" 2 "[$bad_args] is an ERROR"
  hasnt "$OUT" "met"     "[$bad_args] prints no 'met' verdict"
  hasnt "$OUT" "unmet"   "[$bad_args] prints no 'unmet' verdict"
  hasnt "$OUT" "unarmed" "[$bad_args] prints no 'unarmed' verdict"
done

# --- 2i. #78: branch health gates the FINAL step, and only the final step -------------------
# The whole point of the issue: a drained checklist is not a shippable build.
eq "$(ready 1 1 0 0 0 green)"         met           "0 blockers + green branch => met (the cut)"
eq "$(ready 1 1 0 0 0 not-green)"     not-green     "0 blockers + RED branch => not-green, never a cut"
eq "$(ready 1 1 0 0 0 indeterminate)" indeterminate "0 blockers + unknown health => fail closed"
eq "$(ready 1 1 0 0 0 no-ci)"         met           "a repo with no CI is not deadlocked (#24)"
eq "$(ready 1 1 0 0 0 skipped)"       met           "an explicit opt-out (release roll) still reaches met"

# Health is consulted ONLY at the would-be-met boundary — a repo still building never has its
# verdict changed by CI, so /roadmap need not read CI at all while blockers remain.
eq "$(ready 1 1 2 0 0 not-green)"     unmet   "open blockers outrank a red branch (still building)"
eq "$(ready 1 1 2 0 0 indeterminate)" unmet   "open blockers outrank unknown health"
eq "$(ready 0 1 0 3 0 not-green)"     unmet   "fallback mode: open issues outrank a red branch"
eq "$(ready 1 0 0 0 0 not-green)"     unarmed "unarmed outranks a red branch (nothing to cut)"
eq "$(ready 1 0 0 0 0 indeterminate)" unarmed "unarmed outranks unknown health"

# held vs health: BOTH withhold the cut, so neither ordering can ship anything wrong. `held` is
# reported first because it has a deterministic owner remedy (reopen / unlabel / drop), whereas
# red CI clears itself once the build is fixed. Pinned so the precedence cannot drift silently.
eq "$(ready 1 1 0 0 1 not-green)"     held "a canceled blocker outranks a red branch (held first)"
eq "$(ready 1 1 0 0 1 indeterminate)" held "a canceled blocker outranks unknown health"
eq "$(ready 1 1 0 0 1 green)"         held "...and still holds on a green branch"

# ============================================================================================
# 2j. BRANCH HEALTH (#78) — "is the default branch green" as a pure, testable decision
# ============================================================================================
# Anchored to a COMMIT, never to a run list. `gh run list --branch X --limit 1` can answer with an
# unrelated scheduled workflow, a run for an older commit, or one workflow's success while a
# sibling is red — which is why the predicate takes the expected HEAD sha and evaluates the checks
# attached to it.
eq "$(health "$(hj "$(ck ci "$SHA" completed success)" '')")" green "one successful check => green"
eq "$(health "$(hj "$(ck a "$SHA" completed success),$(ck b "$SHA" completed success)" '')")" green \
   "every check successful => green"
eq "$(health "$(hj "$(ck a "$SHA" completed success)" "$(st vercel success)")")" green \
   "checks AND legacy statuses both green => green"

# A red build is red no matter how many siblings passed.
eq "$(health "$(hj "$(ck a "$SHA" completed success),$(ck b "$SHA" completed failure)" '')")" not-green \
   "one failing check among successes => not-green (the #78 headline case)"
has "$(health_why "$(hj "$(ck a "$SHA" completed success),$(ck b "$SHA" completed failure)" '')")" "b" \
   "...and it NAMES the failing check (a /debug signal must be actionable)"
for bad in failure timed_out cancelled action_required startup_failure stale; do
  eq "$(health "$(hj "$(ck ci "$SHA" completed "$bad")" '')")" not-green "conclusion '$bad' is not green"
done
# GitHub itself scores these as passing a required check; treating them as red would wedge every
# repo with conditional jobs.
for okc in success skipped neutral; do
  eq "$(health "$(hj "$(ck ci "$SHA" completed "$okc")" '')")" green "conclusion '$okc' does not fail the branch"
done
# A non-Actions provider reports through the legacy status API only. Reading one API and not the
# other would silently ignore a whole CI provider.
eq "$(health "$(hj '' "$(st vercel failure)")")" not-green "a failing legacy status alone => not-green"
eq "$(health "$(hj '' "$(st vercel error)")")"   not-green "a legacy 'error' state => not-green"

# A RUNNING build is unknown, not red — scoring a null conclusion as "not success" would report
# every mid-CI run as a false failure. (Caught by smoke-testing the first implementation.)
eq "$(health "$(hj "$(ck ci "$SHA" in_progress null)" '')")" indeterminate "an in-progress check => indeterminate"
eq "$(health "$(hj "$(ck ci "$SHA" queued null)" '')")"      indeterminate "a queued check => indeterminate"
eq "$(health "$(hj "$(ck ci "$SHA" completed null)" '')")"   indeterminate "completed with NO conclusion => indeterminate"
eq "$(health "$(hj '' "$(st vercel pending)")")"             indeterminate "a pending legacy status => indeterminate"
# ...but a check that has already FAILED settles it: a pending sibling cannot un-fail it.
eq "$(health "$(hj "$(ck a "$SHA" completed failure),$(ck b "$SHA" in_progress null)" '')")" not-green \
   "a failure plus a still-running sibling => not-green (the failure is decisive)"

# STALE EVIDENCE. A check attached to a different commit describes the wrong build. Dropping it
# silently could leave zero checks and read as `no-ci` — inventing a pass out of a stale read.
eq "$(health "$(hj "$(ck ci "$OTHER_SHA" completed success)" '')")" indeterminate \
   "a green check on a DIFFERENT commit is never this branch's green"
has "$(health_why "$(hj "$(ck ci "$OTHER_SHA" completed success)" '')")" "different commit" \
   "...and says so"

# THE no-ci / indeterminate DISCRIMINATOR — the one #78 could not resolve from `gh run list`,
# which returns [] for BOTH. The active-workflow count is what separates them.
eq "$(health "$(hj '' '')" "$SHA" 0)" no-ci "no checks AND no active workflows => no-ci (skip, per #24)"
eq "$(health "$(hj '' '')" "$SHA" 3)" indeterminate \
   "no checks BUT 3 active workflows => indeterminate, NOT no-ci (fail closed)"
has "$(health_why "$(hj '' '')" "$SHA" 3)" "none has reported" "...and explains the difference"

# FAIL-CLOSED on every unreadable input. An unparseable health read must never be `green`.
for bad_json in '' 'not json' '[]' '"str"' '{"check_runs":{}}' '{"statuses":5}'; do
  run_health "$bad_json" "$SHA" 1
  eq "$RC_" 2 "malformed health input [${bad_json:-<empty>}] is an ERROR"
  hasnt "$OUT" "green" "[${bad_json:-<empty>}] never yields a green verdict"
done
run_health "$(hj '' '')" "" 1;      eq "$RC_" 2 "an empty sha is an ERROR (never compare against nothing)"
run_health "$(hj '' '')" "zzz" 1;   eq "$RC_" 2 "a non-hex sha is an ERROR"
run_health "$(hj '' '')" "abc" 1;   eq "$RC_" 2 "a too-short sha is an ERROR"
run_health "$(hj '' '')" "$SHA" x;  eq "$RC_" 2 "a non-numeric workflow count is an ERROR"
run_health "$(hj '' '')" "$SHA" -1; eq "$RC_" 2 "a negative workflow count is an ERROR"
run_health "$(hj '' '')" "$SHA";    eq "$RC_" 2 "too few args is an ERROR"; has "$OUT" "exactly 2" "arity error states the arity"
run_health "$(hj '' '')" "$SHA" 1 EXTRA; eq "$RC_" 2 "extra args are an ERROR"

# SHA comparison is case-insensitive. GitHub returns lowercase and the workflow sources the
# expected sha from the same API, so both sides match today — but a caller that got the sha
# elsewhere (an operator, or #73's auto-cut driver) must not be told `indeterminate` by nothing
# but letter case. (Self-review find.)
UPPER_SHA="$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
eq "$(health "$(hj "$(ck ci "$SHA" completed success)" '')" "$UPPER_SHA")" green \
   "an UPPERCASE expected sha still matches a lowercase check sha"
eq "$(health "$(hj "$(ck ci "$UPPER_SHA" completed success)" '')" "$SHA")" green \
   "...and the reverse (case never fabricates stale evidence)"

# A check-run with NO head_sha cannot be attributed to this commit, so it is stale evidence, not
# a silent drop — dropping it could leave zero checks and read as `no-ci`, inventing a pass.
eq "$(health "$(printf '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}],"statuses":[]}')")" \
   indeterminate "a check-run with no head_sha is stale evidence, never green"

# Determinism: a pure function of its inputs, so /roadmap's "same tracker => same emit" holds.
fx_h="$(hj "$(ck a "$SHA" completed success),$(ck b "$SHA" completed failure)" "$(st vercel success)")"
eq "$(health "$fx_h")$(health "$fx_h")" "not-greennot-green" "branch-health is deterministic"

# --- 2g-bis. arity is enforced on BOTH subcommands ------------------------------------------
# pr-targets-issue previously ignored extra arguments; a caller that appended a stray field
# would get a silent answer computed from the first two. (Adversarial-review find.)
eq "$(printf '[]' | bash "$RL" pr-targets-issue 69 "$SLUG" EXTRA >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "pr-targets-issue rejects extra arguments"
eq "$(printf '[]' | bash "$RL" pr-targets-issue 69 >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "pr-targets-issue rejects a missing slug"

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
# #78 — the health gate must stay delegated and stay anchored to a commit.
has "$wf" '{{ROADMAP_LIB}} branch-health' \
  "workflow delegates branch health to the shared predicate"
has "$wf" 'an unreadable build is never green' \
  "workflow hard-stops when branch-health cannot answer (fail-closed)"
# The autofix must never sweep a declared must-have into the backlog (#78's guard).
has "$wf" 'index("release-blocker") | not' \
  "step 4b excludes an unmilestoned release-blocker from the Backlog sweep"
has "$wf" 'WARN: #$n is an open release-blocker in NO milestone' \
  "...and surfaces it as a non-retirable warning instead"
has "$wf" 'in-flight check failed' \
  "workflow hard-stops the run when the targeting predicate cannot answer (fail-closed)"
has "$wf" 'A failed targeting check is a hard stop, never a negative.' \
  "workflow states the fail-closed rule as an imperative, not only as a snippet comment"
has "$wf" 'readiness predicate failed' \
  "workflow hard-stops the run when the readiness predicate fails"

# The live `gh` reads that feed the predicate must themselves be hard-stopped. An unchecked
# capture is the one way to defeat the whole fail-closed design from outside the library: a
# failed `gh pr list` yields empty stdin, which is a legitimate "no open PRs" (exit 1), so the
# in-flight member would be emitted. (Adversarial-review find.)
has "$wf" 'could not list open PRs' \
  "workflow hard-stops when the open-PR read fails (an empty capture reads as 'no PRs')"
has "$wf" 'could not list open issues' \
  "workflow hard-stops when the open-issue read fails"

# `continue` outside a loop: bash only warns and FALLS THROUGH (so a member closed since step 4
# would still be emitted), while zsh aborts the block outright. The snippet must not use it.
hasnt "$wf" '|| continue' \
  "workflow's per-member check uses no loop-only 'continue' (bash falls through; zsh aborts)"

# Each fenced snippet must resolve "$REPO" itself: these steps can be run as separate shell
# invocations that share no variables, so a slug hoisted into an earlier step arrives EMPTY and
# every in-flight check dies on a bad slug. (Adversarial-review find on the first fix attempt.)
inflight_block="$(awk '/^# Self-contained: each fenced block/,/^```$/' "$WF")"
has "$inflight_block" 'REPO=' \
  "the in-flight snippet resolves \$REPO itself (no cross-snippet variable dependency)"
has "$inflight_block" 'OPEN_PRS=' \
  "...and fetches the open-PR set in that same snippet"
# Extract each executable snippet by its `# ADB-SNIPPET:` marker — the same anchors
# scripts/check-roadmap-e2e.sh runs them from. Anchoring on a marker rather than on a prose line
# (or on "the line immediately above the comment") is what keeps this guard from breaking when
# a legitimate statement is added to the block, which a positional check did.
wf_snippet() {
  awk -v want="$1" '
    $0 ~ ("^[[:space:]]*# ADB-SNIPPET: " want "$") { inb = 1; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { exit }
    inb { print }
  ' "$WF"
}
gauge_block="$(wf_snippet gauge)"
has "$gauge_block" 'labels/$LABEL' \
  "the destination-report snippet probes the label"
has "$gauge_block" 'REPO=' \
  "the destination-report snippet resolves \$REPO itself"
# The gauge is OPTIONAL, so an unset LABEL is the normal "not configured" case: it must
# short-circuit, never probe `repos/OWNER/REPO/labels/` with an empty name and never die under
# `set -u`. (Found by the e2e harness executing this snippet.)
has "$gauge_block" 'LABEL="${LABEL:-}"' \
  "the gauge tolerates an unconfigured destination-label instead of exploding on it"
has "$gauge_block" '[ -n "$LABEL" ] &&' \
  "...and skips the probe entirely when none is configured"
readiness_block="$(wf_snippet readiness)"
has "$readiness_block" 'gh repo view' \
  "the readiness snippet resolves \$REPO itself (it may run as its own shell invocation)"
has "$readiness_block" 'M_NUM:?' \
  "...and fails loud on an unresolved milestone number rather than addressing milestone=''"
# A pipeline reports only its LAST command's status, so `gh api … | release-counts` returns 0 on a
# failed read — the tabulator sees empty stdin, which is a legitimately empty milestone, and the
# verdict becomes `unarmed`. Read and tabulate must be separate, separately-checked steps.
has "$readiness_block" 'M_ISSUES=' \
  "the milestone READ is captured and checked on its own status, not through a pipeline"
has "$readiness_block" 'could not read milestone' \
  "...and a failed read reports as a failed read, never as an empty release set"

# --- #78: the health reads, asserted against the EXECUTABLE block ---------------------------
# Scoped to the snippet, not the whole document: the prose deliberately QUOTES `gh run list
# --branch … --limit 1` to explain why it is unsound, so a document-wide `hasnt` would fail on
# the explanation itself. What must never regress is the executable code.
hasnt "$readiness_block" 'gh run list' \
  "the readiness snippet does NOT use the run-list green test (it can answer with an unrelated workflow or an older commit)"
has "$readiness_block" 'commits/$HEAD_SHA/check-runs' \
  "health is read from the Checks API for the resolved HEAD commit"
has "$readiness_block" 'commits/$DEFAULT_BRANCH/status' \
  "...AND from the legacy status API, so non-Actions CI providers are not silently ignored"
has "$readiness_block" 'actions/workflows' \
  "...AND from the active-workflow inventory, the only no-ci/indeterminate discriminator"
has "$readiness_block" '{{ROADMAP_LIB}} branch-health' \
  "the snippet delegates the verdict to the shared predicate rather than re-deriving it"
has "$readiness_block" 'HEALTH=skipped' \
  "health starts at the honest 'skipped', never a fabricated green"
has "$readiness_block" 'defaultBranchRef' \
  "the default branch is resolved live from the REMOTE, not assumed to be main"
has "$readiness_block" 'REPO_VIEW=' \
  "...captured on its own status first, since an exit inside a heredoc substitution only leaves the subshell"
# Each health read is captured and checked on its OWN status, for the same reason the milestone
# read is: a pipeline reports only its last command, so a failed read would arrive as empty JSON.
for v in CHECKS_JSON STATUS_JSON WF_JSON WF_COUNT HEAD_SHA; do
  has "$readiness_block" "$v=" "the $v read is captured on its own status"
done
# WF_JSON/WF_COUNT are deliberately two statements, and this asserts the property rather than the
# formatting: the COUNT must be parsed out of the CAPTURED read. Piping the inventory read
# straight into its parser would report only the parser's status, so a failed read would count 0
# active workflows and silently downgrade a fail-closed `indeterminate` into a "no CI here" pass.
# (Found by the e2e fail-injection case, which the first implementation did not survive.)
has "$readiness_block" '"$WF_JSON" | jq' \
  "the active-workflow count is parsed from the captured read, not piped from gh"
# Every LIST read here must paginate, for the reason #79 established. It matters most on the
# status endpoint, which pages at 30 by default: a truncated health read that loses the one red
# status is a FALSE GREEN — the most dangerous direction this predicate can be wrong in.
has "$readiness_block" 'commits/$DEFAULT_BRANCH/status?per_page=100' \
  "the commit-status read is paginated (a dropped failing status would be a false green)"
has "$readiness_block" 'check-runs?per_page=100' \
  "the check-runs read is paginated too"
has "$readiness_block" '"$HEALTH"' \
  "the resolved health is passed to release-ready (not dropped on the floor)"


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

# ============================================================================================
# 4. RELEASE-COUNTS — the predicate's five INPUTS (#74)
# ============================================================================================
# release-ready decides; release-counts decides what it is told. The tabulation rules are
# load-bearing in the same way the verdict is — armed counts CLOSED issues too, the roadmap
# artifact and PRs are excluded, and only a NOT_PLANNED-closed blocker is "canceled". Get one
# wrong and the verdict is wrong while the predicate stays innocent, so both halves are pinned.

# counts <json> -> "<line1>|<line2>|<line3>": the four counts, the leftovers, the open blockers.
counts() { printf '%s' "$1" | bash "$RL" release-counts release-blocker "${2:-0}" 2>/dev/null | tr '\n' '|'; }
iss_json() { printf '[%s]' "$1"; }
I_CLOSED_BLK='{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]}'
I_OPEN_PLAIN='{"number":99,"state":"open","state_reason":null,"labels":[{"name":"enhancement"}]}'
I_OPEN_BLK='{"number":88,"state":"open","state_reason":null,"labels":[{"name":"release-blocker"}]}'
I_CANCELED='{"number":77,"state":"closed","state_reason":"not_planned","labels":[{"name":"release-blocker"}]}'
I_ROADMAP='{"number":31,"state":"open","state_reason":null,"labels":[{"name":"roadmap"}]}'
I_PR='{"number":50,"state":"open","state_reason":null,"labels":[],"pull_request":{"url":"x"}}'

eq "$(counts '[]')"                    '0 0 0 0|||'  "empty milestone => unarmed, nothing to move"
eq "$(counts "$(iss_json "$I_CLOSED_BLK")")"        '1 0 0 0|||' "a closed blocker still ARMS the milestone"
eq "$(counts "$(iss_json "$I_CLOSED_BLK,$I_OPEN_PLAIN")")" '1 0 1 0|99||' "open non-blocker is a leftover, not a blocker"
eq "$(counts "$(iss_json "$I_CLOSED_BLK,$I_OPEN_BLK")")"   '1 1 1 0||88|' "an open blocker is reported, never a leftover"
eq "$(counts "$(iss_json "$I_CANCELED")")"          '1 0 0 1|||' "a NOT_PLANNED blocker sets canceled"
# A NOT_PLANNED close of a NON-blocker is not a canceled requirement.
eq "$(counts "$(iss_json '{"number":60,"state":"closed","state_reason":"not_planned","labels":[]}')")" \
   '1 0 0 0|||' "a NOT_PLANNED non-blocker does not set canceled"
# The two exclusions, asserted by their EFFECT on every field.
eq "$(counts "$(iss_json "$I_CLOSED_BLK,$I_OPEN_PLAIN,$I_ROADMAP")" 31)" '1 0 1 0|99||' \
   "the roadmap artifact is excluded BY NUMBER from counts and leftovers"
eq "$(counts "$(iss_json "$I_CLOSED_BLK,$I_OPEN_PLAIN,$I_PR")")" '1 0 1 0|99||' \
   "a PR carrying the milestone is excluded from counts and leftovers"
eq "$(counts "$(iss_json "$I_ROADMAP")" 31)" '0 0 0 0|||' \
   "a milestone holding ONLY the roadmap artifact is unarmed, not armed by it"
# ...and the exclusion is BY NUMBER, never by label. A CLOSED issue that still carries the
# `roadmap` label is ordinary history: dropping it could under-count a milestone into `unarmed`,
# or -- the dangerous direction -- hide a NOT_PLANNED-canceled blocker and turn `held` into `met`.
I_OLD_ROADMAP_BLK='{"number":77,"state":"closed","state_reason":"not_planned","labels":[{"name":"roadmap"},{"name":"release-blocker"}]}'
eq "$(counts "$(iss_json "$I_ROADMAP,$I_OLD_ROADMAP_BLK")" 31)" '1 0 0 1|||' \
   "a closed issue still carrying the roadmap label is counted, not dropped"
eq "$(counts "$(iss_json "$I_CLOSED_BLK,$I_OPEN_PLAIN,$I_ROADMAP")" 0)" '1 0 2 0|99 31||' \
   "with no artifact number given, nothing is excluded by label"
bash "$RL" release-counts release-blocker notanumber >/dev/null 2>&1 </dev/null
eq "$?" 2 "a non-numeric roadmap-issue-number is exit 2"
# An issue with no labels is an ordinary leftover.
eq "$(counts "$(iss_json '{"number":12,"state":"open","state_reason":null,"labels":[]}')")" \
   '1 0 1 0|12||' "an unlabelled open issue is a leftover"
# Fail-closed: malformed input is an ERROR (>=2), never an innocent-looking zero row.
printf 'not json' | bash "$RL" release-counts release-blocker >/dev/null 2>&1
eq "$?" 2 "malformed JSON is exit 2, never a silent '0 0 0 0'"
bash "$RL" release-counts >/dev/null 2>&1 </dev/null
eq "$?" 2 "release-counts without its label argument is exit 2"

# ============================================================================================
# 5. MARKER-TITLE — the release-readiness activation marker (#74)
# ============================================================================================
# This is the MODE SWITCH for the whole release-readiness overlay, so a false positive turns the
# overlay on in a repo that never opted in, and a missed second value hides an ambiguous artifact.
mt() { printf '%b' "$1" | bash "$RL" marker-title 2>/dev/null | tr '\n' '|'; }

eq "$(mt '<!-- release-milestone: Next release -->\n')" 'Next release|' "a valued marker resolves"
eq "$(mt 'no marker here\n')"                           ''              "no marker => empty, not an error"
eq "$(mt '<!-- release-milestone: -->\n')"              ''              "an empty value is not a title"
eq "$(mt '<!-- release-milestone: NAME -->\n')"         ''              "the literal placeholder NAME is not a title"
eq "$(mt '<!-- release-milestone:Next release-->\n')"   'Next release|' "spacing around the value is optional"
eq "$(mt '<!-- release-milestone: A -->\n<!-- release-milestone: A -->\n')" 'A|' "the same value twice is one title"
eq "$(mt '<!-- release-milestone: B -->\n<!-- release-milestone: A -->\n')" 'A|B|' \
   "two different values BOTH surface, so the caller can refuse an ambiguous artifact"
# The greedy-match trap: two markers on ONE line must still be two titles. A `.*`-anchored match
# keeps only the last, silently resolving a title the reader never wrote.
eq "$(mt '<!-- release-milestone: B --> x <!-- release-milestone: A -->\n')" 'A|B|' \
   "two markers on one line are two titles, not the last one"
# ...and the value must not run past its own `-->` into a later comment on the same line.
eq "$(mt '<!-- release-milestone: A --> then <!-- something else -->\n')" 'A|' \
   "the value stops at its own marker terminator"
bash "$RL" marker-title extra-arg >/dev/null 2>&1
eq "$?" 2 "marker-title takes no arguments"

# ============================================================================================
# 6. DEPS-FROM-BODY — the dependency-edge rule, executable (#108)
# ============================================================================================
# The edge rule used to live only as prose ("an issue body that says `Depends on #N`"), so every
# run re-derived it by eye — and two failures followed: a NEGATED mention read as an edge, and an
# edge that outlived its source text kept blocking a bundle. Same over-match class as #69, on the
# dependency side. Pin both directions.

# deps <body> [self] -> the edges, space-separated on one line ('' when none).
deps() { printf '%s' "$1" | bash "$RL" deps-from-body ${2:+"$2"} 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# --- 6a. the explicit keywords DO declare an edge -------------------------------------------
eq "$(deps 'Depends on #78')"        '78' "'Depends on #78' is an edge"
eq "$(deps 'Depends on: #78 only.')" '78' "the colon form is an edge"
eq "$(deps 'Blocked by #25')"        '25' "'Blocked by #25' is an edge"
eq "$(deps 'Blocked on #25')"        '25' "'Blocked on #25' is an edge"
eq "$(deps 'DEPENDS ON #12')"        '12' "the keyword is case-insensitive"
eq "$(deps 'depends upon #12')"      '12' "'depends upon' is an edge"
eq "$(deps 'This is dependent on #9')" '9' "'dependent on' is an edge"
eq "$(deps '- Depends on #78')"      '78' "a markdown list item is scanned"
eq "$(deps 'Cannot proceed: blocked by #78')" '78' \
   "'cannot' does not read as the negator 'not' (substring guard)"

# --- 6b. a cross-reference is NEVER an edge (the #69 rule, dependency side) ------------------
eq "$(deps 'Refs #69')"                    '' "'Refs #69' is not an edge"
eq "$(deps 'Relates to #69 and see #70')"  '' "prose proximity is not an edge"
eq "$(deps 'See #12 for context')"         '' "'See #12' is not an edge"
eq "$(deps '#78')"                         '' "a bare #N is not an edge"

# --- 6c. NEGATION retires an edge, never creates one (the #108 bug) --------------------------
eq "$(deps 'No longer depends on #25.')"          '' "'no longer depends on' is not an edge"
eq "$(deps 'This does not depend on #25')"        '' "'does not depend on' is not an edge"
eq "$(deps 'It is not blocked by #25')"           '' "'is not blocked by' is not an edge"
eq "$(deps 'Never depended on #25')"              '' "'never depended on' is not an edge"
eq "$(deps 'Rescoped — no longer blocked by #25')" '' "an em-dash clause boundary is honored"
eq "$(deps 'The #25 prerequisite was dropped; blocked by #78')" '78' \
   "a negator in an EARLIER clause does not suppress a later real edge"
eq "$(deps 'Depends on #78; it is not blocked by #25')" '78' \
   "one line can declare one edge and retire another"

# --- 6d. this repo only — a qualified reference is not a local edge --------------------------
eq "$(deps 'Depends on acme/repo#5')"                          '' "owner/repo#N is not a local edge"
eq "$(deps 'Depends on https://github.com/acme/repo/issues/5')" '' "an issue URL is not a local edge"
eq "$(deps 'Depends on #5 and other/repo#7')"                  '5' \
   "a qualified reference ends the chain instead of contributing a false edge"

# --- 6e. chains, ordering, dedup, self-edges ------------------------------------------------
eq "$(deps 'Depends on #5, #6 and #7')" '5 6 7' "a comma/and chain yields every member"
eq "$(deps 'Depends on #7 #5')"         '5 7'   "output is ascending, not source order"
eq "$(deps 'Depends on #5 and #5')"     '5'     "duplicates collapse"
eq "$(deps 'Depends on #5 (the gate) and #6')" '5' \
   "an interrupted chain stops (conservative: an invented edge blocks a bundle forever)"
eq "$(deps 'Depends on #73 and #78' 73)" '78'   "the self-edge is dropped"
eq "$(deps 'Depends on #73' 73)"         ''     "a body depending only on itself yields nothing"
eq "$(deps 'Depends on #7')"             '7'    "#7 is not confused with #70"
eq "$(deps 'Depends on #70')"            '70'   "...nor #70 with #7"

# --- 6f. shapes that must be a clean empty, never an error ----------------------------------
eq "$(deps '')"                  '' "an empty body yields no edges"
eq "$(deps 'nothing here')"      '' "a body with no reference yields no edges"
eq "$(deps 'Depends on issue 5')" '' "a reference without '#' is not an edge"
# A digit run wider than any issue number must be REJECTED before the numeric conversion: awk
# would otherwise hold a float and print it rounded/in exponent form, emitting a fabricated
# "issue number" no tracker can have. (Self-review find, mirrors release-ready's is_uint bound.)
eq "$(deps 'Depends on #99999999999999999999')" '' \
   "an over-wide reference is not an edge (never a float-formatted fake number)"
eq "$(deps 'Depends on #99999999999999999999, #5')" '5' \
   "...and the rest of the chain still resolves"
eq "$(deps 'Depends on #999999999')" '999999999' "a 9-digit reference still resolves (bound is not over-tight)"
eq "$(deps 'Depends on #0')" '' "#0 is not an issue reference"
# A keyword and its reference must share a line — a wrapped 'dependency' reads as one to nobody.
eq "$(deps "$(printf 'Depends on\n#5')")" '' "a keyword and reference split across lines is not an edge"

# --- 6g. argument validation (fail-closed, like every other subcommand) ---------------------
printf 'x' | bash "$RL" deps-from-body notanumber >/dev/null 2>&1
eq "$?" 2 "a non-numeric self-issue-number is an ERROR"
printf 'x' | bash "$RL" deps-from-body 1 2 >/dev/null 2>&1
eq "$?" 2 "deps-from-body rejects extra arguments"
printf 'Depends on #5' | bash "$RL" deps-from-body >/dev/null 2>&1
eq "$?" 0 "deps-from-body with no argument is valid (no self-number)"

# --- 6h. determinism ------------------------------------------------------------------------
dfx='Depends on #9, #3 and #5; no longer blocked by #4'
eq "$(deps "$dfx")" "$(deps "$dfx")" "deps-from-body is deterministic"
eq "$(deps "$dfx")" '3 5 9'          "...and mixed declare/retire resolves to the declared set"

# ============================================================================================
# 7. DECISIONS — the durable home that retires an owner question (#108)
# ============================================================================================
# The reproduced bug: a decision recorded in an issue COMMENT is invisible to reconcile, so the
# same question reprinted every run, forever. `decisions` reads the artifact's owner-authoritative
# section so "has the owner already answered this?" is mechanical, not re-litigated each run.

# dcs <body> -> recorded question ids, space-separated ('' when none).
dcs() { printf '%b' "$1" | bash "$RL" decisions 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

D_HEAD='## Decisions\n| Question | Decision | Recorded |\n| -------- | -------- | -------- |\n'
eq "$(dcs "${D_HEAD}| dep-outside-release:#73 | re-scoped | #73 body |\n")" 'dep-outside-release:#73' \
   "a recorded question id is reported"
eq "$(dcs "${D_HEAD}| \`dep-outside-release:#73\` | re-scoped | — |\n")" 'dep-outside-release:#73' \
   "surrounding backticks are stripped (a row is written by hand)"
eq "$(dcs "${D_HEAD}|   unmilestoned:#5   | leave it | — |\n")" 'unmilestoned:#5' \
   "cell whitespace is trimmed"
eq "$(dcs "${D_HEAD}| a:#1 | x | — |\n| b:#2 | y | — |\n")" 'a:#1 b:#2' "every row is reported"
eq "$(dcs "${D_HEAD}| a:#1 | x | — |\n| a:#1 | y | — |\n")" 'a:#1' "duplicate rows collapse"
eq "$(dcs '# Roadmap\n## Bundles\n| B1 | #5 |\n')" '' \
   "no Decisions section => nothing recorded (not an error)"
eq "$(dcs "${D_HEAD}")" '' "the header and separator rows are not decisions"
# The section ENDS at the next heading: a table in a later section must never read as a decision.
eq "$(dcs "${D_HEAD}| a:#1 | x | — |\n## Bundles\n| B1 | #5 | gates | — | ready |\n")" 'a:#1' \
   "parsing stops at the next heading (a Bundles row is not a decision)"
eq "$(dcs '## Bundles\n| B1 | #5 |\n## Decisions\n| a:#1 | x | — |\n')" 'a:#1' \
   "a section BEFORE Decisions does not leak into it"
eq "$(dcs '## decisions\n| a:#1 | x | — |\n')" 'a:#1' "the heading match is case-insensitive"
eq "$(dcs '## Decisions log\n| a:#1 | x | — |\n')" '' \
   "a differently-titled heading is NOT the Decisions section"
eq "$(dcs "${D_HEAD}<!-- a comment -->\n| a:#1 | x | — |\n")" 'a:#1' \
   "an HTML comment inside the section is skipped"
bash "$RL" decisions extra-arg >/dev/null 2>&1
eq "$?" 2 "decisions takes no arguments"

# A decision row can DECLARE or RETIRE an edge in the same vocabulary an issue body uses — the
# composition that makes `## Decisions` a real edge source rather than a second dialect.
eq "$(deps 'Re-scoped to a standalone driver; no longer depends on #25')" '' \
   "a decision row that retires an edge yields no edge"
eq "$(deps 'Confirmed: depends on #78 only.')" '78' \
   "a decision row that declares an edge yields it"

# ============================================================================================
# 8. OUTPUT CONTRACT + SCHEMA DRIFT GUARDS (#107, #108, #94)
# ============================================================================================
# These pin the parts of the workflow that are prose an agent executes. They are the only thing
# standing between "the spec says the action is last" and a run that appends fifteen lines after
# it — which is exactly what #107 was filed for.

# --- 8a. #107: every OUTPUT EXAMPLE ends with the action line -------------------------------
# Output examples are fenced ```text (bash snippets are ```bash, the artifact schema ```markdown),
# so this can be checked mechanically. A block may be indented inside a list item.
contract="$(awk '
  /^[[:space:]]*```text[[:space:]]*$/ { inb = 1; last = ""; next }
  inb && /^[[:space:]]*```[[:space:]]*$/ {
    inb = 0; n++
    line = last; sub(/^[[:space:]]+/, "", line)
    if (line !~ /^Next:/) { bad++; printf "  block %d ends with: %s\n", n, last > "/dev/stderr" }
    next
  }
  inb { if ($0 ~ /[^[:space:]]/) last = $0 }
  END { printf "%d %d\n", n, bad + 0 }
' "$WF")"
eq "${contract##* }" 0 'every fenced text output example in the workflow ends with the Next: action line'
[ "${contract%% *}" -ge 4 ] && ok || bad "workflow carries too few output examples (got ${contract%% *}, want >=4)"

has "$wf" 'The final line is ALWAYS the single next action' \
  "workflow states the last-line rule as an imperative (#107)"
has "$wf" 'Next: none —' \
  "workflow gives terminal states an action line too, so 'last line = next action' always holds"
hasnt "$wf" 'Next: /implement-issue 5 19
Why:' \
  "the emit template no longer prints Why AFTER Next (the #107 defect)"

# --- 8b. #94: the scratch path must not pre-exist, and must be portable ---------------------
has "$wf" 'mktemp -d' \
  "workflow makes a scratch DIRECTORY (a mktemp'd FILE fails every write, #94)"
hasnt "$wf" 'mktemp -t' \
  "workflow does not use the non-portable 'mktemp -t' (macOS keeps the Xs literally, #94)"
has "$wf" 'ROADMAP_BODY="$ROADMAP_DIR/body.md"' \
  "the body path is inside the scratch dir and does not yet exist"
nr="$(cat "$ROOT/base/workflows/new-release.md" 2>/dev/null)"
hasnt "$nr" 'mktemp` shape' \
  "new-release no longer steers an agent into the same pre-created-file trap (#94)"

# --- 8c. #108: edges are re-derived from a live source, and decisions are durable ------------
has "$wf" '{{ROADMAP_LIB}} deps-from-body' \
  "workflow delegates edge extraction to the shared predicate"
has "$wf" '{{ROADMAP_LIB}} decisions' \
  "workflow reads recorded decisions before surfacing a question"
has "$wf" '## Decisions' \
  "the artifact schema carries the Decisions section (the prescribed home for an answer)"
has "$wf" 'DERIVED VIEW' \
  "the Dependencies section is documented as derived, never a source (#108)"
has "$wf" 'Never rewrite `## Decisions`' \
  "reconcile is told not to overwrite the owner-authoritative section"
has "$wf" 'dep-outside-release:' \
  "workflow fixes a stable question-id vocabulary so the same condition retires once"
has "$wf" 'Record: <where>' \
  "a surfaced question names where to record the answer"
has "$wf" 'grep -Fqx' \
  "the recorded-decision lookup is a literal whole-line match (a:#1 never matches a:#12)"

# The retirement rule must not be allowed to defeat the readiness withhold. `held` and every STOP
# condition have to print on EVERY run that they hold: a suppressed `held` line is a release that
# silently never cuts, with the only explanation removed. (Self-review find — #108 vs #71.)
has "$wf" 'Retirement suppresses a QUESTION, never a VERDICT' \
  "retirement is scoped to prompts, never to a ground-truth verdict"
hasnt "$wf" 'canceled-blocker:#N' \
  "the withheld-cut condition is NOT in the retirable id vocabulary (#71's hold must stay visible)"
has "$wf" 'never** retirable' \
  "workflow names the conditions that can never be retired by a recorded row"
# Bootstrap has to create the home a question will point at, or the first question asked in a
# fresh repo has nowhere durable to be answered.
has "$wf" 'empty `## Decisions` section' \
  "bootstrap seeds the Decisions section so the first question has a recording home"

# ============================================================================================
# 9. OPEN-ISSUES + READ-COMPLETE — completeness of the backlog read (#79)
# ============================================================================================
# The read used a bare `--limit 200` with no pagination and no truncation detection. Because `gh`
# returns newest-first the DROPPED issues are the oldest, and because an open issue missing from
# the open set is reconciled to `Done`, a truncated read does not merely omit rows — it deletes
# real work from the plan. Truncation is not an error, so the hard-stop-on-gh-error rule never
# fired on it; these two predicates are what makes completeness checkable.

# oi <json> -> the open issue numbers, space-separated.
oi() { printf '%s' "$1" | bash "$RL" open-issues 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
O_OPEN_A='{"number":5,"state":"open"}'
O_OPEN_B='{"number":12,"state":"open"}'
O_CLOSED='{"number":7,"state":"closed"}'
O_PR='{"number":9,"state":"open","pull_request":{"url":"x"}}'

eq "$(oi "[$O_OPEN_A,$O_OPEN_B]")"  '5 12' "open issues are reported"
eq "$(oi "[$O_OPEN_B,$O_OPEN_A]")"  '5 12' "output is ascending, not source order"
eq "$(oi "[$O_OPEN_A,$O_CLOSED]")"  '5'    "a closed issue is not in the open set"
eq "$(oi "[$O_OPEN_A,$O_PR]")"      '5'    "a PR is excluded (repos/../issues returns PRs too)"
eq "$(oi '[]')"                     ''     "an empty repo is empty output, not an error"
eq "$(oi "[$O_OPEN_A,$O_OPEN_A]")"  '5'    "duplicates across page boundaries collapse"
# The artifact is deliberately NOT excluded here: this set is compared against a repo-wide
# `is:issue is:open` total, so both sides must count the same population. Excluding it here would
# make every completeness check off by one — a `short` verdict, i.e. a hard stop, on a healthy repo.
eq "$(oi '[{"number":31,"state":"open","labels":[{"name":"roadmap"}]}]')" '31' \
   "the roadmap artifact is counted (the caller drops it; the completeness check must not)"
# `gh api --paginate` can emit ONE merged array or a separate array per page. Reading only the
# first input would silently drop every page after the first — the exact truncation this ends.
eq "$(oi "[$O_OPEN_A]
[$O_OPEN_B]")" '5 12' "a separate-array-per-page stream is fully consumed"
printf 'not json' | bash "$RL" open-issues >/dev/null 2>&1
eq "$?" 2 "malformed JSON is exit 2, never a silent empty open set"
printf '[]' | bash "$RL" open-issues extra >/dev/null 2>&1
eq "$?" 2 "open-issues takes no arguments"

# rc <read> <expected> -> the verdict.
rcv() { bash "$RL" read-complete "$1" "$2" 2>/dev/null; }
eq "$(rcv 140 140)" complete "an exact match is complete"
eq "$(rcv 0 0)"     complete "an empty repo is complete, not short"
eq "$(rcv 200 231)" short    "a capped read that came back short is SHORT (the #79 failure)"
eq "$(rcv 0 3)"     short    "a read that returned nothing against a non-zero total is SHORT"
eq "$(rcv 141 140)" ahead    "more than expected is 'ahead' (the Search index lags REST)"
# The asymmetry is the whole design: demanding equality in BOTH directions would hard-stop a
# healthy run whenever an issue was filed between the two reads.
run read-complete 200;        eq "$RC_" 2 "too few args is an ERROR"
run read-complete 1 2 3;      eq "$RC_" 2 "too many args is an ERROR"
run read-complete x 1;        eq "$RC_" 2 "a non-numeric read count is an ERROR"
run read-complete 1 x;        eq "$RC_" 2 "a non-numeric expected total is an ERROR"
run read-complete -1 1;       eq "$RC_" 2 "a negative count is an ERROR"
run read-complete 99999999999999999999 1
eq "$RC_" 2 "an over-wide count is an ERROR, not a fabricated verdict"
# An errored call must print NO VERDICT on stdout — a caller reads stdout, and a `case` that fell
# through to `complete` would proceed on a read it could not verify. Assert stdout alone (the
# combined-output helper cannot: the diagnostic legitimately names the `read-complete` subcommand,
# which contains the word "complete").
for bad_rc in "-1 1" "x 1" "1 x" "99999999999999999999 1" "1"; do
  # shellcheck disable=SC2086  # deliberate word-split of the fixture arg string
  eq "$(bash "$RL" read-complete $bad_rc 2>/dev/null)" '' "[$bad_rc] prints no verdict on stdout"
done

# --- 9a. the workflow must actually USE them ------------------------------------------------
has "$wf" 'gh api --paginate' \
  "workflow reads collections with --paginate instead of a magic --limit constant (#79)"
has "$wf" '{{ROADMAP_LIB}} open-issues' \
  "workflow parses the paginated open-issue read through the shared predicate"
has "$wf" '{{ROADMAP_LIB}} read-complete' \
  "workflow cross-checks the read against the exact Search total"
has "$wf" 'incomplete backlog, hard stop' \
  "workflow FAILS LOUD on a short read rather than persisting a partial roadmap"
has "$wf" 'possibly truncated, hard stop' \
  "workflow treats a saturated open-PR read as possibly truncated, never as complete"
hasnt "$wf" 'gh issue list --state open --limit 200' \
  "the capped backlog reads are gone (#79)"
# The gauge/readiness path was ALREADY exact (search/issues total_count) and must stay untouched.
has "$wf" "--jq '.total_count'" \
  "the Search-API gauge/readiness path is unchanged (already exact at any size)"

# ============================================================================================
# 10. AUTOFIX TIER — fix the unambiguous, escalate the rest (#109)
# ============================================================================================
# The tier line has to be explicit and CLOSED, or the next agent guesses which side a new defect
# falls on — and a wrong guess means /roadmap silently rewrites tracker state on judgment it was
# never given.
has "$wf" '### 4b. Autofix the unambiguous' \
  "workflow carries the autofix step"
has "$wf" 'unambiguous** (exactly one correct repair)' \
  "the four-part qualification test for autofix is stated"
has "$wf" 'default is escalate' \
  "anything unclassified escalates rather than being repaired on a guess"
has "$wf" 'The list is closed' \
  "the autofix table is closed — a new defect escalates until it is added deliberately"
has "$wf" 'Idempotent' \
  "autofix is required to be idempotent (a second run finds nothing)"
has "$wf" '--no-autofix' \
  "a repo can opt out for a read-only run"
has "$wf" 'do not
create a milestone' \
  "a missing backlog milestone escalates instead of inventing the repo's convention"
has "$wf" 'backlog-milestone:' \
  "the autofix target milestone is configurable, not hardcoded into an agent-neutral skill"
has "$wf" 'Never edits repository code' \
  "the tracker-only boundary is restated where the new write powers are introduced"
# The write powers must not leak past the tracker: no branch/commit/PR verbs anywhere.
hasnt "$wf" 'git commit' "the skill never commits"
hasnt "$wf" 'git push'   "the skill never pushes"
hasnt "$wf" 'gh pr create' "the skill never opens a PR"
# The autofix must be a runnable step, not a description of one — otherwise "fix what you find"
# is re-invented by every agent that reads it. scripts/check-roadmap-e2e.sh executes this snippet.
autofix_block="$(wf_snippet autofix-unmilestoned)"
has "$autofix_block" 'select(.milestone == null)' \
  "the limbo set is DERIVED from milestone == null (which is what makes autofix idempotent)"
# #78's carve-out lives here too — one home for every assertion about this snippet.
has "$autofix_block" 'index("release-blocker") | not' \
  "step 4b excludes an unmilestoned release-blocker from the Backlog sweep (#78)"
has "$autofix_block" 'WARN:' \
  "...and surfaces it instead of silently burying a declared must-have"
# It WARNS, it does not gate — nothing feeds it to the predicate, so the wording must not promise
# a hold the code does not implement. (Altitude-review find.)
hasnt "$autofix_block" 'HOLD:' \
  "...and does NOT call it a HOLD, which would claim a gate that is not wired"
hasnt "$autofix_block" '? unmilestoned:#$n — open release-blocker' \
  "...and does NOT file it as a retirable question (a Decisions row must not hide a release risk)"
has "$autofix_block" 'first // empty' \
  "the backlog milestone is resolved by title, and an unresolved one stays empty"
has "$autofix_block" 'NO_AUTOFIX:-0' \
  "the snippet honors --no-autofix rather than only the prose promising it"
has "$autofix_block" 'gh issue edit' \
  "the repair is a real tracker write"
hasnt "$autofix_block" 'gh api --method POST' \
  "autofix never CREATES a milestone (that would invent a convention the repo never opted into)"

check_summary "roadmap"
