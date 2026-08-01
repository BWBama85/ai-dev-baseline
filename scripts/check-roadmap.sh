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

# ACTIONS_SLUG: the value the library attributes against, read from its ONE home rather than
# restated here (check-lib.sh owns how a suite reaches for it). The behavioral pins in section 4d
# are what stop the value itself from silently becoming wrong again.
check_actions_slug

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
# ck <name> <sha> <status> <conclusion> [app-slug] — one check-run object.
# The app slug defaults to what an Actions-produced check run REALLY carries, sourced from the one
# home rather than restated — a hard-coded default here is precisely what hid #179: the fixture
# asserted the code's belief (`github`) instead of the API's behavior, so the suite stayed green
# against a value GitHub never returns. The API-contract test below still pins the literal ONCE,
# on purpose, so implementation and fixtures cannot drift together again.
# Pass a different slug to model another Checks API app (a linter bot, a deploy provider).
ck() { printf '{"name":"%s","head_sha":"%s","status":"%s","conclusion":%s,"app":{"slug":"%s"}}' \
         "$1" "$2" "$3" "$(if [ "$4" = "null" ]; then printf 'null'; else printf '"%s"' "$4"; fi)" "${5:-$ACTIONS_SLUG}"; }
# ck_noapp <name> <sha> <status> <conclusion> — a check run with `app` NULL, which the GitHub REST
# schema permits. Its provenance is UNKNOWN, which is neither Actions nor external.
ck_noapp() { printf '{"name":"%s","head_sha":"%s","status":"%s","conclusion":%s,"app":null}' \
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

# --- 1i. ONLY PROSE TARGETS: structure in a PR body is documentation (#130/#136) ------------  # adb-claim-ok: #130 is closed NOT_PLANNED, superseded by #136
# The body half of this predicate is a keyword scan over prose an author wrote, and until #136 it
# had no notion of markdown at all — so a PR that merely DOCUMENTED `Closes #N` froze that issue
# out of every bundle. All five shapes below were verified returning 0 ("targets") before the fix.
#
# DIRECTION. Each case here guards the OVER-match: a fabricated target withholds a ready issue
# forever, which is visible but wrong. The controls right after guard the UNDER-match, which is the
# worse one — a missed target lets /roadmap emit work an open PR already closes.
# `jb` builds a JSON body string from raw lines, so a fence can be written with real newlines.
jb() { printf '%s\n' "$@" | jq -Rs .; }
BT3='```'
eq "$(targets 42 "$(arr "$(pr 100 "$(jb "$BT3" 'Closes #42' "$BT3")" '[]')")")" 1 \
   "OVER: a closing keyword inside a fenced block does not target"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb '<!-- Closes #42 -->')" '[]')")")" 1 \
   "OVER: ...inside an HTML comment"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb '> Closes #42')" '[]')")")" 1 \
   "OVER: ...inside a blockquote"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'Docs: `Closes #42` is the syntax.')" '[]')")")" 1 \
   "OVER: ...inside an inline code span"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb '    Closes #42')" '[]')")")" 1 \
   "OVER: ...inside a 4-space indented code block (the D27 rule, reaching this consumer too)"
# A span is MASKED, never deleted. Deleting it lets the text on either side fuse into a keyword the
# author never wrote — self-review find, and the reason `deps-from-body` masks with \x01 too.
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'clo`x`ses #42')" '[]')")")" 1 \
   "OVER: two fragments either side of a span do NOT fuse into a closing keyword"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'Docs: fi`x`es #42')" '[]')")")" 1 \
   "OVER: ...for every keyword the pattern accepts"
# UNDER — every real form must still target, or /roadmap emits work a PR already closes.
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'Closes #42')" '[]')")")" 0 \
   "UNDER: plain prose still targets"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'Some prose.' '' '    An indented block.' '' 'Closes #42')" '[]')")")" 0 \
   "UNDER: prose AFTER an indented block still targets (the block ends at column 0)"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb "$BT3" 'x' "$BT3" 'Closes #42')" '[]')")")" 0 \
   "UNDER: prose after a CLOSED fence still targets"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb "Closes $SLUG#42")" '[]')")")" 0 \
   "UNDER: a THIS-repo-qualified closer still targets (stacked PRs depend on it)"
eq "$(targets 42 "$(arr "$(pr 100 "$(jb 'Closes other/repo#42')" '[]')")")" 1 \
   "OVER: an OTHER-repo-qualified closer never targets"
# RECORD BOUNDARY. The filter carries cross-line state, so an unterminated fence swallows to end of
# input. Each body must therefore be filtered ON ITS OWN — otherwise one PR's stray ``` blinds the
# scan for every PR after it, which is a fail-OPEN across records.
eq "$(targets 42 "$(arr "$(pr 100 "$(jb "$BT3" 'unterminated')" '[]')" "$(pr 101 "$(jb 'Closes #42')" '[]')")")" 0 \
   "UNDER: an unterminated fence in one PR body does not blind the next PR's scan"
# The LINKED-ISSUE half is GitHub's own computed set and is never filtered — a PR whose body only
# documents the syntax still targets when the link is real.
# The body documents a DIFFERENT number from the linked one, so a pass here cannot come from the
# body scan. Built on its own line because the escape below is per-line and this fixture wraps.
doc_only_body="$(jb "$BT3" 'Closes #99' "$BT3")"   # adb-claim-ok: fixture DATA — a number the body documents, never a citation
eq "$(targets 42 "$(arr "$(pr 100 "$doc_only_body" "$(arr "$(ref 42)")")")")" 0 \
   "UNDER: the closingIssuesReferences link targets regardless of what the body's markup says"

# --- 1j. FAIL-CLOSED on a FILTER failure, not just a JSON one (#136) ------------------------
# The acceptance property: "no sanitizing path may yield a clean negative on filter failure." A
# body that is truncated or never filtered at all reads as "no keyword here" — the exact fail-open
# the rc>1 band exists to prevent. Driven with a stub `awk` on PATH, so the failure is REAL rather
# than asserted: the guard is watched going red on an input that would otherwise return 0.
sc_stub="$(mktemp -d)"
printf '#!/bin/sh\nexit 7\n' > "$sc_stub/awk"; chmod +x "$sc_stub/awk"
eq "$(printf '%s' "$(arr "$(pr 100 "$(jb 'Closes #42')" '[]')")" \
       | PATH="$sc_stub:$PATH" bash "$RL" pr-targets-issue 42 "$SLUG" >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "a prose-filter failure is an ERROR (2) on a body that WOULD have targeted"
printf '#!/bin/sh\nprintf "half\\n"\nexit 0\n' > "$sc_stub/awk"
eq "$(printf '%s' "$(arr "$(pr 100 "$(jb 'Closes #42')" '[]')")" \
       | PATH="$sc_stub:$PATH" bash "$RL" pr-targets-issue 42 "$SLUG" >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "a TRUNCATED filter run is an ERROR (2) too — a short clean-looking body is the fail-open"
rm -rf "$sc_stub"
# MALFORMED FIELD SHAPES reach the same fail-closed band (review round 1). `jq -r '.[$i].body'`
# stringifies a number without complaining, and `any(...)` over a non-array reference set yields an
# empty generator rather than raising — so a malformed PR object answered a clean "not targeted".
eq "$(targets 42 '[{"body":42,"closingIssuesReferences":[]}]')" 2 \
   "a non-string body is an ERROR (2), never a clean negative"
eq "$(targets 42 '[{"body":"","closingIssuesReferences":{}}]')" 2 \
   "a non-array closingIssuesReferences is an ERROR (2)"
eq "$(targets 42 '["a string member"]')" 2 \
   "an array member that is not an object is an ERROR (2)"
eq "$(targets 42 '[{"body":null,"closingIssuesReferences":null}]')" 1 \
   "...while explicit nulls stay a clean negative — absent is not malformed"

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
has "$(health_why "$(hj '' '')" "$SHA" 3)" "Actions has not reported" "...and explains the difference"

# THE FALSE-CUT REGRESSION (adversarial-review find). `$total` counts "somebody reported", not
# "everybody reported". Without an explicit unreported-workflows arm ahead of `green`, ONE
# unrelated passing legacy status satisfies `$total > 0` and converts a genuinely unreported
# Actions build into a confident `green` — i.e. adding a green status to a repo whose CI has not
# run turns a correct refusal into a RELEASE. Fail-open, the one direction that matters.
eq "$(health "$(hj '' "$(st vercel success)")" "$SHA" 3)" indeterminate \
   "3 active workflows + no check runs + ONE green legacy status => still indeterminate, never green"
has "$(health_why "$(hj '' "$(st vercel success)")" "$SHA" 3)" "Actions has not reported" \
   "...naming the unreported workflows rather than the status that did report"
# The same shape with NO active workflows is the legitimate non-Actions repo: the status IS the CI.
eq "$(health "$(hj '' "$(st vercel success)")" "$SHA" 0)" green \
   "...but with 0 active workflows a green legacy status IS the branch's green (non-Actions CI)"
# And an ACTIONS check run present means the workflows did report — inventory cannot override it.
eq "$(health "$(hj "$(ck ci "$SHA" completed success)" "$(st vercel success)")" "$SHA" 3)" green \
   "an Actions check run present => reported, whatever the inventory count says"

# THE SECOND MASKING PROVIDER (bot-review find, same class as the one above). A check run from a
# DIFFERENT Checks API app also lands in `check_runs`, so a plain "are there any check runs" test
# cannot tell it apart from an Actions run: the inventory read would be skipped and `$total > 0`
# would return `green` while Actions had reported nothing. Attribution is by `app.slug`.
eq "$(health "$(hj "$(ck vercel "$SHA" completed success vercel)" '')" "$SHA" 3)" indeterminate \
   "3 active workflows + a green check run from ANOTHER app => still indeterminate, never green"
has "$(health_why "$(hj "$(ck vercel "$SHA" completed success vercel)" '')" "$SHA" 3)" "Actions has not reported" \
   "...and says Actions specifically has not reported"
eq "$(health "$(hj "$(ck vercel "$SHA" completed success vercel)" '')" "$SHA" 0)" green \
   "...while with 0 active workflows that same app IS the repo's CI"
# Unknown provenance must not stand in as proof Actions ran (fail closed on a missing app field).
eq "$(health "$(printf '{"check_runs":[{"name":"ci","head_sha":"%s","status":"completed","conclusion":"success"}],"statuses":[]}' "$SHA")" "$SHA" 3)" \
   indeterminate "a check run with no identifiable app does not prove Actions reported"
# A FAILING non-Actions check still fails the branch — attribution gates `green`, never `not-green`.
eq "$(health "$(hj "$(ck vercel "$SHA" completed failure vercel)" '')" "$SHA" 3)" not-green \
   "a failing check from another app is still red (attribution never rescues a failure)"

# --- 4d. THE API CONTRACT: what slug does GitHub Actions ACTUALLY stamp? (#179) --------------
# These cases spell the literal out instead of deriving it from `adb_actions_app_slug`, and that is
# deliberate. Every other fixture here derives it, which makes them immune to a CHANGE in the value
# — and therefore blind to the value being WRONG. That blindness is not hypothetical: both
# libraries shipped attributing against `github`, the app OWNER login, while GitHub stamps
# `github-actions` (app id 15368). The fixtures defaulted to `github` too, so the suite was green
# against a value the API never returns, and `branch-health` could not return `green` on any
# Actions repo — deadlocking the release-goal convention at `indeterminate`.
#
# The constant ITSELF is asserted in check-common-lib.sh, which owns common.sh; what these cases
# add is the BEHAVIOR — that an API-shaped check run reaches `green` and that the retired value
# does not. If GitHub ever renames the slug, these are among the tests that must change
# deliberately, which is the entire point.
eq "$(health "$(hj "$(ck ci "$SHA" completed success github-actions)" '')" "$SHA" 1)" green \
   "an API-shaped Actions check run (slug github-actions) + active workflows => GREEN (the #179 bug)"
eq "$(health "$(hj "$(ck ci "$SHA" completed success github)" '')" "$SHA" 1)" indeterminate \
   "the RETIRED literal 'github' is just another app slug, never Actions"
has "$(health_why "$(hj "$(ck ci "$SHA" completed success github)" '')" "$SHA" 1)" "Actions has not reported" \
   "...and the reason names Actions specifically, not the app that did report"
# `app` is required-but-NULLABLE in the REST schema, so this is a real shape, not a hypothetical.
eq "$(health "$(hj "$(ck_noapp ci "$SHA" completed success)" '')" "$SHA" 1)" indeterminate \
   "a null app is UNKNOWN provenance, never proof Actions ran"
# The fix must not have widened attribution to the app OWNER login, which IS `github` — that would
# re-admit the retired literal through a second door and quietly restore the bug.
eq "$(health "$(printf '{"check_runs":[{"name":"ci","head_sha":"%s","status":"completed","conclusion":"success","app":{"slug":"circleci","owner":{"login":"github"}}}],"statuses":[]}' "$SHA")" "$SHA" 1)" \
   indeterminate "attribution is by app.slug ALONE — an app owned by 'github' is not Actions"

# FAIL-CLOSED on every unreadable input. An unparseable health read must never be `green`.
# A MISSING collection is an error, not an empty one (bot-review find). `{}` previously defaulted
# both keys to [] and returned `no-ci`, which release-ready maps to `met` — fabricating a release
# out of a health response nobody could parse. `no-ci` must mean "explicitly nothing reported".
for bad_json in '' 'not json' '[]' '"str"' '{"check_runs":{}}' '{"statuses":5}' \
                '{}' '{"check_runs":[]}' '{"statuses":[]}' '{"check_runs":null,"statuses":null}' \
                '{"check_runs":[],"statuses":null}'; do
  run_health "$bad_json" "$SHA" 1
  eq "$RC_" 2 "malformed health input [${bad_json:-<empty>}] is an ERROR"
  hasnt "$OUT" "green" "[${bad_json:-<empty>}] never yields a green verdict"
  hasnt "$OUT" "no-ci" "[${bad_json:-<empty>}] never yields no-ci (which would reach 'met')"
done
# ...and with BOTH keys explicitly present and empty, `no-ci` is the correct, intended answer.
eq "$(health "$(hj '' '')" "$SHA" 0)" no-ci "two EXPLICIT empty arrays are a real no-ci, not an error"
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

# ============================================================================================
# 2j. COMPOSE-CANDIDATES (D15 / #80) — the mechanical half of release composition
# ============================================================================================
# WHAT MUST NOT VARY. The dangerous failure is not a mediocre pick, it is composing a release that
# can never DRAIN — promote an issue whose prerequisite stays in the backlog and the milestone holds
# a blocker nothing can close, so /roadmap reports `unmet` forever. So: tiering (bugs first),
# blocked-ness computed against the OPEN set only, and a total stable order.

# ci <number> <title> <label> — one open issue row.
ci() { printf '{"number":%s,"title":"%s","labels":[{"name":"%s"}]}' "$1" "$2" "$3"; }
# cdoc <issues-csv> <edges-json> — the {issues,edges} document the predicate reads.
cdoc() { printf '{"issues":[%s],"edges":%s}' "$1" "${2:-[]}"; }
# compose <doc> [roadmap-num] [bug-label] — run it, echo stdout.
compose() { printf '%s' "$1" | bash "$RL" compose-candidates "${2:-31}" "${3:-bug}" 2>/dev/null; }

C_BUGS="$(ci 102 'bug A' bug),$(ci 136 'bug B' bug),$(ci 112 'bug C' bug)"
C_ENH="$(ci 20 'enh A' enhancement),$(ci 80 'enh B' enhancement)"
C_ALL="$C_BUGS,$C_ENH,$(ci 31 'the roadmap' roadmap)"

# --- 2j-a. bugs rank before enhancements, ascending within tier -----------------------------
eq "$(compose "$(cdoc "$C_ALL")" | awk -F'\t' '{printf "%s%s ", $1, $2}')" \
   "bug102 bug112 bug136 other20 other80 " \
   "bugs first, then others; ascending issue number within each tier"

# --- 2j-b. the roadmap artifact is never a candidate ----------------------------------------
eq "$(compose "$(cdoc "$C_ALL")" | grep -c '	31	' || true)" 0 \
   "the roadmap issue is excluded from its own composition"

# --- 2j-c. pull requests are never candidates -----------------------------------------------
# Built through a variable rather than a doubly-nested `$( )`: an escaped quote inside a command
# substitution that is itself inside one does not survive re-parsing, and the fixture arrives as
# malformed JSON — which the predicate correctly rejects, so the test would fail for a reason that
# has nothing to do with the behavior under test.
C_PR="$C_BUGS,{\"number\":999,\"title\":\"a PR\",\"labels\":[],\"pull_request\":{}}"
C_PR_DOC="$(cdoc "$C_PR")"
eq "$(compose "$C_PR_DOC" | wc -l | tr -d ' ')" 3 \
   "a pull_request entry is not a composition candidate"

# --- 2j-d. THE DRAIN GUARD: an open prerequisite marks a candidate blocked -------------------
eq "$(compose "$(cdoc "$C_ALL" '[[136,112]]')" | awk -F'\t' '$2 == 136 { print $3 "/" $4 }')" "1/112" \
   "a candidate with an OPEN prerequisite is blocked, and names it"
eq "$(compose "$(cdoc "$C_ALL" '[[136,112]]')" | awk -F'\t' '$2 == 112 { print $3 "/" $4 }')" "0/-" \
   "the prerequisite itself is unblocked"

# --- 2j-e. a CLOSED prerequisite is satisfied and must not hold a candidate out --------------
# #178 is absent from the open set, so the edge is satisfied. Getting this wrong is the failure
# that would exclude every issue whose history mentions a shipped dependency.
eq "$(compose "$(cdoc "$C_ALL" '[[112,178]]')" | awk -F'\t' '$2 == 112 { print $3 "/" $4 }')" "0/-" \
   "a prerequisite that is not open is satisfied, never blocking"

# --- 2j-f. unblocked sorts before blocked WITHIN a tier --------------------------------------
eq "$(compose "$(cdoc "$C_ALL" '[[102,112]]')" | awk -F'\t' '$1 == "bug" { printf "%s ", $2 }')" "112 136 102 " \
   "within a tier, unblocked candidates rank above blocked ones"

# --- 2j-g. a self-edge is ignored, never a self-block ---------------------------------------
eq "$(compose "$(cdoc "$C_ALL" '[[112,112]]')" | awk -F'\t' '$2 == 112 { print $3 }')" 0 \
   "an issue declaring itself as a prerequisite is not blocked by itself"

# --- 2j-h. duplicate edges collapse ---------------------------------------------------------
eq "$(compose "$(cdoc "$C_ALL" '[[136,112],[136,112]]')" | awk -F'\t' '$2 == 136 { print $4 }')" "112" \
   "a duplicated edge is reported once"

# --- 2j-i. the bug label is configurable, and drives the tier --------------------------------
eq "$(compose "$(cdoc "$(ci 5 'x' defect),$(ci 6 'y' enhancement)")" 31 defect | awk -F'\t' '{printf "%s%s ", $1, $2}')" \
   "bug5 other6 " "the tier label is a parameter, not a hardcoded 'bug'"
eq "$(compose "$(cdoc "$(ci 5 'x' defect),$(ci 6 'y' enhancement)")" | awk -F'\t' '{printf "%s ", $1}')" \
   "other other " "a repo with no issue carrying the label composes an all-'other' slate, not an error"

# --- 2j-j. zero-config generality (#80's non-negotiable): no labels, no edges, no error ------
eq "$(printf '{"issues":[{"number":7,"title":"bare"}]}' | bash "$RL" compose-candidates 31 bug 2>/dev/null | awk -F'\t' '{print $1 "/" $2 "/" $3}')" \
   "other/7/0" "an issue with no labels and no edges key ranks cleanly"

# --- 2j-k. an empty backlog is a valid EMPTY answer, never an error --------------------------
run_c() { OUT="$(printf '%s' "$1" | bash "$RL" compose-candidates "${2:-31}" 2>&1)"; RC_=$?; }
run_c '{"issues":[],"edges":[]}'; yes "$RC_" "an empty backlog exits 0"; eq "$OUT" "" "...with empty output"

# --- 2j-l. TSV integrity: a title containing a tab or newline cannot break the format --------
eq "$(compose "$(cdoc '{"number":9,"title":"a\ttab\nand a newline","labels":[]}')" | wc -l | tr -d ' ')" 1 \
   "a title containing a tab or newline still yields exactly one row"
eq "$(compose "$(cdoc '{"number":9,"title":"a\ttab\nand a newline","labels":[]}')" | awk -F'\t' '{print NF}')" 5 \
   "...with exactly five fields"

# --- 2j-m. determinism (#45) ----------------------------------------------------------------
eq "$(compose "$(cdoc "$C_ALL" '[[136,112],[80,112]]')")" "$(compose "$(cdoc "$C_ALL" '[[136,112],[80,112]]')")" \
   "compose-candidates is deterministic over an unchanged tracker"

# --- 2j-n. FAIL-CLOSED on bad input ----------------------------------------------------------
run_c 'not json';        eq "$RC_" 2 "malformed JSON is an ERROR, never an empty slate"
run_c '{"issues":[]}' x; eq "$RC_" 2 "a non-numeric roadmap number is an ERROR"
eq "$(printf '{"issues":[]}' | bash "$RL" compose-candidates >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "a missing roadmap number is an ERROR"
eq "$(printf '{"issues":[]}' | bash "$RL" compose-candidates 31 bug EXTRA >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "extra arguments are an ERROR"
eq "$(printf '{"issues":[]}' | bash "$RL" compose-candidates 31 '' >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "an empty bug label is an ERROR"

# --- 2j-o. a label containing jq metacharacters is DATA, never filter text -------------------
eq "$(compose "$(cdoc "$(ci 5 'x' 'a\"b')")" 31 'a"b' | awk -F'\t' '{print $1}')" "bug" \
   "a label containing a quote is matched as data (no filter injection)"

# --- 2j-p. `exclude`: present and blocking, but never a candidate (review round 1) -----------
# Reconcile's `tracker-only` / `owner-review` issues, and anything outside the backlog, share one
# meaning here. Both must BLOCK a dependent (they are open and undelivered) while never being
# promoted themselves — collapsing the two questions is what would promote a bug the advance logic
# can never emit.
CX_DOC="$(cdoc "$C_ALL" '[[136,112]]')"
CX_DOC="$(printf '%s' "$CX_DOC" | jq -c '. + {exclude: [112]}')"
eq "$(compose "$CX_DOC" | awk -F'\t' '{printf "%s ", $2}')" "102 136 20 80 " \
   "an excluded issue is not offered as a candidate"
eq "$(compose "$CX_DOC" | awk -F'\t' '$2 == 136 { print $3 "/" $4 }')" "1/112" \
   "...but it still BLOCKS the dependent that needs it"

# --- 2j-q. `canceled`: a NOT_PLANNED prerequisite is not satisfied (review round 1) ----------
# #999 is absent from the open set. As a completed close that is satisfaction; as a cancellation it
# is abandonment, and step 4's `dep-canceled` rule says it does not satisfy the dependent.
eq "$(compose "$(cdoc "$C_ALL" '[[112,999]]')" | awk -F'\t' '$2 == 112 { print $3 "/" $4 }')" "0/-" \
   "a prerequisite absent from the open set is satisfied by default (completed close)"
CN_DOC="$(printf '%s' "$(cdoc "$C_ALL" '[[112,999]]')" | jq -c '. + {canceled: [999]}')"
eq "$(compose "$CN_DOC" | awk -F'\t' '$2 == 112 { print $3 "/" $4 }')" "1/999" \
   "...but a CANCELED one keeps blocking"

# ============================================================================================
# 2k. COMPOSE-SELECT — seed, close, and prune what cannot drain (review round 1)
# ============================================================================================
# sel <candidate-tsv> — the promoted numbers, ascending, space-joined.
sel() { printf '%s\n' "$1" | bash "$RL" compose-select 2>/dev/null | awk -F'\t' '$1=="sel"{print $2}' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
# drops <candidate-tsv> — the `n:blocker` pairs that were dropped.
drops() { printf '%s\n' "$1" | bash "$RL" compose-select 2>/dev/null | awk -F'\t' '$1=="drop"{printf "%s:%s ", $2, $3}' | sed 's/ $//'; }

T_PLAIN="$(printf 'bug\t102\t0\t-\tb1\nother\t20\t0\t-\te1\n')"
eq "$(sel "$T_PLAIN")" "102" "the bug tier is the seed; an unrelated enhancement is not selected"

T_CLOSE="$(printf 'bug\t136\t1\t55\tb1\nother\t55\t0\t-\te1\n')"
eq "$(sel "$T_CLOSE")" "55 136" "closure pulls a promotable prerequisite in, even an enhancement"

T_CHAIN="$(printf 'bug\t136\t1\t55\tb1\nother\t55\t1\t62\te1\nother\t62\t0\t-\te2\n')"
eq "$(sel "$T_CHAIN")" "55 62 136" "closure is transitive"

# THE PRUNE PASS. A prerequisite with no candidate row can never be promoted, so its dependent
# cannot drain — and a milestone holding a blocker nothing can close never reports `met`.
T_PRUNE="$(printf 'bug\t136\t1\t99\tb1\nbug\t102\t0\t-\tb2\n')"
eq "$(sel "$T_PRUNE")" "102" "a bug whose prerequisite is not promotable is dropped"
eq "$(drops "$T_PRUNE")" "136:99" "...and the drop names the prerequisite that caused it"

T_CASCADE="$(printf 'bug\t136\t1\t99\tb1\nbug\t200\t1\t136\tb2\n')"
eq "$(sel "$T_CASCADE")" "" "pruning cascades to whatever depended on the dropped issue"
eq "$(drops "$T_CASCADE")" "136:99 200:136" "...and every drop is reported, never silent"

eq "$(sel "$(printf '')")" "" "an empty slate selects nothing"
eq "$(printf '' | bash "$RL" compose-select >/dev/null 2>&1; printf '%s' "$?")" 0 \
   "...and exits 0, because an empty backlog is an answer"
eq "$(printf 'bug\t1\t0\t-\tx\n' | bash "$RL" compose-select EXTRA >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "compose-select rejects arguments"
eq "$(sel "$T_CASCADE")" "$(sel "$T_CASCADE")" "compose-select is deterministic"

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
# #132 — the ambiguity report is worth nothing if the workflow never asks for it, and "the library
# can be perfect while the skill quietly reverts" is exactly what this section exists to catch.
has "$wf" '{{ROADMAP_LIB}} deps-ambiguous' \
  "workflow asks the shared predicate what it could not parse (#132)"
has "$wf" 'ambiguity scan failed' \
  "...and hard-stops the run when that scan fails (fail-closed, like every other read)"
# Pin the id in the VOCABULARY LIST, not merely somewhere in the file: `dep-ambiguous:#N` also
# appears in the surrounding prose and in the retirement paragraph, so a bare search stays green
# after the id is deleted from the list that actually fixes it. (Independent-review find.)
has "$wf" '`dep-canceled:#N` · `dep-ambiguous:#N`' \
  "workflow gives the ambiguity question a stable id IN the dep-* vocabulary list"
# The two composition call sites discarded the extractor's exit status (`for d in $(…)`), so a
# failed extraction read as "no prerequisites" and promoted an issue whose blocker stays behind.
hasnt "$wf" 'for d in $(printf' \
  "composition captures the edge extraction instead of discarding its status in a for-substitution"
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
# would still be emitted), while zsh aborts the block outright.
#
# Scoped to the `fresh-read` SNIPPET, not the whole workflow. The rule is about that block, whose
# per-member check is a bare `if` with no enclosing loop — asserted file-wide it also fires on a
# `continue` that IS inside a real `for`, which is ordinary shell (the release-command resolver
# iterates skill roots). A guard that flags correct code trains readers to route around it.
freshread_block="$(check_wf_snippet "$WF" fresh-read)"
hasnt "$freshread_block" '|| continue' \
  "the fresh-read snippet's per-member check uses no loop-only 'continue' (bash falls through; zsh aborts)"

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
# Delegates to check_wf_snippet (check-lib.sh), the ONE home for the marker/closing-fence
# contract — three suites execute documented snippets and three copies of this awk could drift.
wf_snippet() { check_wf_snippet "$WF" "$1"; }
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
# The inventory read is gated on ACTIONS having reported, not on "any result exists": both a legacy
# status and a check run from another Checks app can be present while Actions is silent, and
# suppressing the read on either lets the predicate return `green` on an unreported build.
# The expected literal is DERIVED from the one home, not restated: this assertion previously
# pinned `== "github"` into the rendered docs, so the workflow, the library and the fixtures all
# agreed on a value GitHub never returns (#179). Deriving it means the snippet must track the
# constant, while section 4d is what proves the constant itself is right.
has "$readiness_block" ".app.slug // \"\") == \"$ACTIONS_SLUG\"" \
  "the inventory gate attributes check runs by app, so another app cannot stand in for Actions"
hasnt "$readiness_block" '== "github"' \
  "...and the snippet no longer carries the retired literal that could never match"
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

# A FAILED extractor must never look like a clean empty result (#135). These helpers run the
# library inside `$( … )`, and a command substitution's exit status is DISCARDED once the result
# is expanded as an argument — `set -o pipefail` does not reach it. Most structure fixtures expect
# `''`, so without this a crash on exactly those inputs still reports PASS, silently disarming the
# regressions they exist to pin. Convert a nonzero exit into a value nothing can equal.
run_rl() {                     # run_rl <subcommand> [args...]  — body on stdin
  local out rc
  out="$(bash "$RL" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf 'ERR(rc=%s)' "$rc"; return 0; fi
  printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//'
}

# deps <body> [self] -> the edges, space-separated on one line ('' when none).
deps() { printf '%s' "$1" | run_rl deps-from-body ${2:+"$2"}; }

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

# --- 6i. STRUCTURE: an issue that DOCUMENTS the keyword must not acquire the edge (#117) -----
# WHY this rule exists lives once, in the STRUCTURE block of scripts/lib/roadmap-lib.sh. These
# fixtures pin WHAT it does, one structure at a time, so a fourth variant of the family fails here
# rather than shipping.
#
# depsm <line>... — the same runner as `deps`, but for a MULTI-LINE body: `deps` passes its one
# argument through `printf '%s'`, so a fenced block cannot be written as an embedded-newline
# string. One line per argument instead.
depsm() { printf '%s\n' "$@" | run_rl deps-from-body; }
q3='```'; q4='````'
# Backticks inside a DOUBLE-quoted string within `$( … )` open a legacy command substitution — a
# parse error, and one that still reports as a PASS here rather than a failure. (Single quotes are
# fine; it is only the double-quoted fixtures below that need this.)
bt='`'

# Fenced blocks: both characters, info strings, indentation, run lengths, interleaving.
eq "$(depsm "${q3}console" 'Depends on #5' "$q3")" '' "a fenced block declares nothing"
eq "$(depsm '~~~' 'Depends on #5' '~~~')" '' "a ~~~ fence declares nothing"
eq "$(depsm '~~~' "$q3" 'Depends on #5' "$q3" '~~~')" '' \
   'a backtick-fence run inside a ~~~ fence is content, not a closer'
eq "$(depsm "$q3" '~~~' 'Depends on #5' '~~~' "$q3")" '' "...and the reverse"
eq "$(depsm "$q4" 'Depends on #5' "$q3" "$q4")" '' \
   "a closer SHORTER than its opener does not close the fence"
eq "$(depsm "$q3" 'Depends on #5' "$q3 nope" "$q3")" '' \
   "a would-be closer carrying trailing text is content, not a closer"
eq "$(depsm "   $q3" 'Depends on #5' "   $q3")" '' "a fence indented 3 spaces is still a fence"
eq "$(depsm "${q3}a${bt}b" 'Depends on #5')" '5' \
   "a backtick fence whose info string holds a backtick does NOT open (so the prose is scanned)"
eq "$(depsm "~~~a${bt}b" 'Depends on #5' '~~~')" '' "...but a tilde fence's info string may hold one"
# A 4-space run is an INDENTED CODE BLOCK, not a fence — and since D27 its CONTENTS are structure
# too. What this fixture pins now is the block's END: an indented code block ends at the first
# non-blank line indented <= 3, so the middle line below is an ordinary paragraph and its edge
# stands. (The rationale here used to read "indented blocks are deliberately out of scope"; #136's
# acceptance list named this fixture as the one that must FLIP, and it cannot — the flip is in the
# reason, and in the §5-repro fixtures further down. See D27.)
eq "$(depsm "    $q3" 'Depends on #5' "    $q3")" '5' \
   "UNDER: a non-indented line ENDS an indented code block, so the prose between two runs declares"
eq "$(depsm "    $q3" '    Depends on #5' "    $q3")" '' \
   "OVER: ...while a line INSIDE the block declares nothing (this is the #129 exclusion, gone)"  # adb-claim-ok: #129 is closed NOT_PLANNED, superseded by #136
# An unterminated fence must swallow to end-of-body rather than leak its contents back to prose.
eq "$(depsm 'Depends on #9' "$q3" 'Depends on #5')" '9' "an unterminated fence swallows to EOF"
eq "$(depsm "$q3" 'Depends on #9' "$q3" 'Depends on #5')" '5' "prose AFTER a closed fence is scanned"
eq "$(depsm 'Depends on #9' "$q3" 'Depends on #5' "$q3")" '9' "prose BEFORE a fence is scanned"
eq "$(depsm "$q3" 'Depends on #5' "$q3" 'Depends on #3' "$q3" 'Depends on #7' "$q3")" '3' \
   "two fences with prose between them yield only the prose edge"

# HTML comments — the artifact's own schema quotes `Depends on #78` as the example vocabulary.
eq "$(deps 'a <!-- Depends on #5 --> b')" '' "an inline HTML comment declares nothing"
eq "$(depsm '<!-- x' 'Depends on #5' '-->')" '' "a multi-line HTML comment declares nothing"
eq "$(deps '<!-- Depends on #5 --> Depends on #7')" '7' \
   "...and the prose AFTER a closed comment on the same line is still scanned"

# Blockquotes — quoted material, never this issue's own claim.
eq "$(deps '> Depends on #5')"    '' "a blockquote declares nothing"
eq "$(deps '   > Depends on #5')" '' "...including one indented up to 3 spaces"

# Inline code spans — TARGETED, not blanket: the KEYWORD must be outside a span, the `#N` may sit
# inside one. Blanket stripping would delete the reference and collide head-on with #112.
eq "$(deps "see ${bt}Depends on #5${bt} here")" '' "a whole clause quoted in a span declares nothing"
eq "$(deps "see ${bt}${bt} Depends on ${bt}#5${bt} ${bt}${bt} here")" '' \
   "...including a double-backtick span"
eq "$(deps "Depends on ${bt}#5${bt}")" '5' \
   "a span around only the REFERENCE resolves (what the targeted masking left room for; #112)"

# Masking must not leak into the NEGATION rule: it stops a quoted keyword from DECLARING, and must
# not also stop a real one from RETIRING. (Self-review find; see the lib's clause comment.)
eq "$(deps "This is ${bt}not${bt} blocked by #5")" '' \
   "a code-formatted negator still retires (the clause is read unmasked)"
eq "$(deps "It ${bt}no longer${bt} depends on #5")" '' \
   "...including a multi-word one"

# CRLF. A body submitted through the GitHub web UI is CRLF and `gh` passes it through verbatim, so
# a closer arrives as "```\r". Before this was normalized, its must-be-blank tail was not blank,
# the fence NEVER closed, and every edge in the rest of the body vanished — a dropped edge marks a
# genuinely blocked bundle `ready`. This repo's own issues are all API-authored LF, which is
# exactly why nothing here caught it. (Adversarial-review find.)
cr="$(printf '\r')"
eq "$(depsm "$q3" 'repro' "$q3$cr" 'Depends on #5')" '5' \
   "a CRLF fence closer still closes the fence"
eq "$(depsm "$q3$cr" 'repro' "$q3$cr" "Depends on #5$cr")" '5' \
   "...with CRLF throughout"

# An HTML comment must not arm the cross-line state when it is really something else.
eq "$(depsm "${q3}html<!--" '<div/>' "$q3" 'Depends on #5')" '5' \
   "a <!-- in a fence INFO STRING is text: the fence starts first, so it must not arm a comment"
eq "$(depsm '~~~html<!--' '<div/>' '~~~' 'Depends on #5')" '5' "...same for a tilde fence"
eq "$(deps '<!-->')$(depsm '<!-->' 'Depends on #5')" '5' \
   "<!--> is an EMPTY comment (opener and closer share dashes), not an unterminated one"
eq "$(depsm '<!--->' 'Depends on #5')" '5' "...and so is <!--->"
eq "$(depsm '<!--' 'Depends on #9' '-->' 'Depends on #5')" '5' \
   "a genuine multi-line comment still swallows its contents"

# STRUCTURE INSIDE A LIST ITEM (#135). Putting a fenced example in a list item is one of the most
# common shapes in a real issue, and the delimiter then sits after the marker. Missing it failed
# BOTH ways at once: the block was scanned (fabricating an edge), and its indented closer was read
# as a NEW opener, swallowing every genuine edge after the list to end-of-body.
eq "$(depsm '- '"$q3"'console' '  Depends on #5' "  $q3" 'Depends on #7')" '7' \
   "a fence inside a list item is a fence, and its closer does not re-open one"
eq "$(depsm '1. '"$q3" '   Depends on #5' "   $q3" 'Depends on #7')" '7' \
   "...with an ordered list marker"
eq "$(depsm '  - '"$q3" '    Depends on #5' "    $q3" 'Depends on #7')" '7' \
   "...and an indented list item, whose closer sits past the 3-space opener limit"
eq "$(deps '- > Depends on #6')" '' "a blockquote under a list marker is still quoted material"
eq "$(deps '* > Depends on #6')" '' "...for every bullet character"
# The marker rules must not eat ordinary prose.
eq "$(deps '- Depends on #78')"    '78' "a list item of PROSE still declares"
eq "$(deps '1. Depends on #78')"   '78' "...ordered too"
eq "$(deps '**Depends on #78**')"  '78' "a bold run is not a list marker"
eq "$(depsm '---' 'Depends on #78')" '78' "a horizontal rule is not a list marker"

# CONTAINER CONTEXT — the four ways the marker/indent rules go wrong (PR #137 review).
# A closer is matched relative to its OPENER's content column, not globally. Both directions bite:
# too strict and a list-nested closer never matches (the fence swallows the body); too loose and
# indented content inside a top-level fence closes it early, after which the REAL closer reads as
# a fresh opener and eats every edge after the block.
eq "$(depsm "$q3" "    $q3" 'Depends on #5' "$q3" 'Depends on #7')" '7' \
   "an indented backtick run INSIDE a top-level fence is content, not its closer"
# CommonMark: 1-4 spaces after a marker are padding; at 5+, only the first is, and the rest is
# content indentation — so the delimiter is an indented code line, not a fence.
eq "$(depsm "-     $q3" 'Depends on #5' "$q3" 'Depends on #7')" '5' \
   "5+ spaces after a list marker is content indentation, so no fence opens"
# CommonMark caps an ordered marker at NINE digits; a tenth means it is not a list at all.
eq "$(deps '1234567890. > Depends on #5')" '5' \
   "a 10-digit run is not an ordered marker, so this is prose and the edge stands"
eq "$(deps '123456789. > Depends on #5')" '' "...while nine digits IS a marker"
eq "$(deps '1.Depends on #5')" '5' "a marker needs a space after it"

# An ESCAPED comment opener is prose DISPLAYING the delimiter, not markup. Treating it as real
# armed the cross-line state, and an illustrative marker rarely carries a closer — so it swallowed
# every edge and every recorded decision after it.
eq "$(depsm 'Use \<!-- literally' 'Depends on #41')" '41' \
   "a backslash-escaped <!-- does not open a comment"
eq "$(depsm 'Real: <!-- x' 'Depends on #41' '-->' 'Depends on #7')" '7' \
   "...while an unescaped one still does"
# Only an ODD run of backslashes escapes: with two, the first escapes the second and the opener is
# REAL, so treating it as prose would scan a genuine comment and fabricate an edge from it.
eq "$(deps 'Text \\<!-- Depends on #5 --> Depends on #7')" '7' \
   "two backslashes leave a REAL comment opener (only odd parity escapes)"
eq "$(deps 'Text \\\<!-- Depends on #5 -->')" '5' \
   "...and three escape it again"

# MULTI-LINE CODE SPANS (#136 §1). CommonMark lets an inline span cross a line ending inside a
# paragraph, so a clause that RENDERS entirely as code was still being scanned: the line-at-a-time
# filter copied the unmatched opening backtick as literal text. That recreated, in a narrow case,
# the exact false dependency #117 exists to prevent.
#
# DIRECTION. The first group is OVER-match (a fabricated edge blocks a ready bundle). The control
# group right after is UNDER-match, and it is the reason this is PARAGRAPH-scoped rather than
# document-scoped: a stray backtick must not be able to swallow the rest of the body.
eq "$(depsm "${bt}Depends on #5" "still example${bt}")" '' \
   "OVER: a span that crosses a line ending declares nothing"
eq "$(depsm "see ${bt}${bt}Depends on #5" "still example${bt}${bt} here")" '' \
   "OVER: ...for a multi-backtick run too"
eq "$(depsm "${bt}${bt}Depends on #5" "one ${bt} inside" "still example${bt}${bt}")" '' \
   "OVER: ...and a shorter run inside a longer span is content, not its closer"
eq "$(depsm "it${bt}s fine" 'Depends on #5')" '5' \
   "UNDER: an UNMATCHED backtick is literal text and must not swallow the next line"
eq "$(depsm "it${bt}s fine" '' 'Depends on #5')" '5' \
   "UNDER: ...and span state resets at the paragraph boundary, so a later pair cannot reach back"
eq "$(depsm "${bt}Depends on #5" '' "still example${bt}")" '5' \
   "UNDER: a blank line ends the paragraph, so these two backticks are two unmatched literals"
eq "$(depsm "${bt}Depends on #5" 'still example' 'Depends on #7')" '5 7' \
   "UNDER: an opener with no closer anywhere in the paragraph is LITERAL — both edges stand"

# A `<!--` QUOTED IN A SPAN IS TEXT, NOT STRUCTURE (#136 §2). Comment stripping used to run before
# anything knew about spans, so a deliberately-quoted opener armed the cross-line comment state and
# swallowed every following line — the inverse of the rule two blocks up, and the UNDER-match
# direction: a dropped edge marks a genuinely blocked bundle `ready`.
eq "$(depsm "The opener is ${bt}<!--${bt} in the schema." 'Depends on #5')" '5' \
   "UNDER: a <!-- quoted in a code span does not open a comment"
eq "$(depsm "Write ${bt}<!-- x -->${bt} to show it." 'Depends on #5')" '5' \
   "UNDER: ...including a whole quoted comment"
eq "$(deps "A real one: <!-- ${bt} --> Depends on #5")" '5' \
   "UNDER: a backtick INSIDE a real comment is consumed with it (the comment opened first)"
eq "$(depsm '<!-- x' "Depends on ${bt}#5${bt}" '-->' 'Depends on #7')" '7' \
   "OVER: ...and a real comment still swallows a span, because it opened first"

# AN HTML COMMENT THAT STARTS A LINE IS A BLOCK (review round 1). The inline pass runs a whole
# paragraph BEHIND the block pass, so structure written INSIDE a multi-line comment used to mutate
# block state before anything knew a comment was open. Both directions of that were live, and both
# are UNDER-match: a fence opened and never closed, and a blockquote-shaped closer was skipped so
# the comment never closed at all. Either swallowed every edge after it.
eq "$(depsm '<!--' "$q3" '-->' 'Depends on #5')" '5' \
   "UNDER: a fence delimiter INSIDE a multi-line comment opens no fence"
eq "$(depsm '<!--' '> -->' 'Depends on #5')" '5' \
   "UNDER: ...and a blockquote-shaped closer still closes the comment"
eq "$(depsm '<!--' '    indented' '-->' 'Depends on #5')" '5' \
   "UNDER: ...and an indented line inside one opens no code block"
eq "$(depsm '<!--' 'Depends on #9' '-->' 'Depends on #5')" '5' \
   "OVER: ...while the comment still swallows its own contents"
eq "$(deps '<!-- Depends on #5 --> Depends on #7')" '7' \
   "UNDER: a comment CLOSED on its own line stays inline, so the prose after it is still scanned"
eq "$(depsm '- <!--' 'Depends on #9' '-->' 'Depends on #5')" '5' \
   "OVER: a comment block opens at the CONTAINER content column too"

# A LIST MARKER STARTS A NEW BLOCK (review round 1). Two adjacent items were buffered as one
# paragraph, so their backticks paired across the item boundary and masked a real edge away.
eq "$(depsm "- ${bt}Depends on #5" "- another ${bt} item")" '5' \
   "UNDER: backticks in two DIFFERENT list items do not pair"
eq "$(depsm "- ${bt}Depends on #5" "  still item one ${bt}")" '' \
   "OVER: ...but a CONTINUATION line is the same paragraph, so a span across it still resolves"

# AN ESCAPED BACKTICK IS LITERAL (review round 1), so it opens no span. Without the parity check a
# phantom opener pairs with a real tick later in the paragraph and masks everything between.
eq "$(depsm "\\${bt}Depends on #5" "later ${bt}")" '5' \
   "UNDER: a backslash-escaped backtick is not a span opener"
eq "$(depsm "\\\\${bt}Depends on #5" "later ${bt}")" '' \
   "OVER: ...but TWO backslashes leave a real one (only odd parity escapes)"

# The point of the whole family: prose still declares, and a quoted negation is not a retirement.
eq "$(depsm "$q3" 'no longer depends on #5' "$q3" 'Depends on #7')" '7' \
   "a NEGATED mention quoted in a fence neither declares nor retires"
eq "$(depsm "$q3" 'Depends on #5' "$q3" 'Depends on #5, #6 and #7')" '5 6 7' \
   "a chain in prose still resolves with a fence present"

# --- 6i-bis. INDENTED CODE BLOCKS — the #129 fork, decided in D27 ----------------------------  # adb-claim-ok: #129 is closed NOT_PLANNED, superseded by #136 — this is its historical name
# The rule: a line opens an indented code block only when it is indented >= 4 spaces AND no
# paragraph is open AND no list container is open. Both guards are the whole safety argument, so
# each fixture below says which direction it holds.
#
# OVER-match here means scanning quoted code and fabricating an edge (a ready bundle sits blocked —
# visible). UNDER-match means deleting ordinary prose and losing a real edge (a blocked bundle is
# marked `ready` — invisible, and the reason a stateless `^ {4}` rule was refused).
# The issue's §5 repro is written with `#52`; these use `#5` like every other fixture in § 6i.  # adb-claim-ok: quoting the repro's number, not citing it
# The number is fixture DATA — what is under test is the indentation rule, not the reference.
eq "$(deps '    Depends on #5')" '' \
   "OVER: a top-level 4-space-indented line is code and declares nothing (the §5 repro)"
eq "$(depsm '        Depends on #5')" '' "OVER: ...at any depth past 4"
eq "$(depsm 'Prose.' '' '    Depends on #5')" '' "OVER: ...after a blank line"
eq "$(depsm "$q3" 'x' "$q3" '    Depends on #5')" '' "OVER: ...and after a closed fence"
eq "$(depsm '# A heading' '    Depends on #5')" '' "OVER: ...and directly after a heading"
# UNDER — the shapes a stateless rule would have deleted. CommonMark refuses all four as code.
eq "$(depsm '- item' '    Depends on #5')" '5' \
   "UNDER: a 4-space continuation under a list marker is PROSE (content starts at column 2)"
eq "$(depsm '- item' '      Depends on #5')" '5' \
   "UNDER: ...and a 6-space one too, because indented code cannot interrupt a paragraph"
eq "$(depsm '- item' '' '    Depends on #5')" '5' \
   "UNDER: ...and the list container survives a blank line"
eq "$(depsm 'Some prose' '    Depends on #5')" '5' \
   "UNDER: a lazy continuation of an ordinary paragraph is prose, not code"
eq "$(depsm '- a' '' 'Top-level prose.' '' '    Depends on #5')" '' \
   "OVER: ...but a column-0 line CLOSES the list, so the next indented block is code again"
eq "$(depsm '    x' 'Depends on #5')" '5' \
   "UNDER: an indented block ends at the first non-blank line indented <= 3"
eq "$(depsm "\tDepends on #5")" '5' \
   "UNDER: a leading TAB is deliberately not counted as indentation (stated in the filter header)"

# --- 6j. EMPHASIS between the keyword and the #N (#112) --------------------------------------
# The UNDER-match mirror of #69, and the dangerous half of the family: an over-match blocks a
# ready bundle (visible, annoying); an under-match marks a genuinely BLOCKED bundle `ready`, so
# /roadmap emits work whose prerequisite is still open. Six real edges in this repo's own tracker
# were being dropped — every one of them written in the most ordinary markdown an author reaches
# for (`- **Blocked by** #155`).
#
# Each fixture below is labelled UNDER (the edge must appear) or OVER (it must not), because the
# fix widens a match and the only thing keeping that safe is the second group. WHY the grammar is
# what it is lives once, in the STEP block of scripts/lib/roadmap-lib.sh.

# UNDER — every emphasis/code delimiter the acceptance list names.
eq "$(deps 'Depends on **#52**')"   '52' "UNDER: bold around the reference"
eq "$(deps 'Depends on __#52__')"   '52' "UNDER: __bold__ around the reference"
eq "$(deps 'Depends on *#52*')"     '52' "UNDER: *italic* around the reference"
eq "$(deps 'Depends on _#52_')"     '52' "UNDER: _italic_ around the reference"
# (the single-backtick span is pinned in 6i, beside the code-span rule it constrains)
eq "$(deps "Depends on ${bt}${bt}#52${bt}${bt}")" '52' "UNDER: a double-backtick span too"
eq "$(deps 'Blocked by **#52**')"   '52' "UNDER: the blocked-by keyword takes it as well"
eq "$(deps 'Depends on _**#5**_')"  '5'  "UNDER: nesting resolves at the INNERMOST pair"
eq "$(deps 'Depends on *_#5_*')"    '5'  "UNDER: ...whose run is length 1, not 2 (the scan loop)"

# UNDER — the closing run of emphasis that WRAPPED THE KEYWORD, which is what actually broke.
# `- **Blocked by** #155` is the exact form six live edges were written in.
eq "$(deps '- **Blocked by** #155')" '155' "UNDER: a bolded keyword's closer, the live shape"
eq "$(deps '*Blocked by* #155')"     '155' "UNDER: ...italic"
eq "$(deps '**Depends on:** #78')"   '78'  "UNDER: the colon INSIDE the emphasis"
eq "$(deps '**Depends on**: #78')"   '78'  "UNDER: ...and outside it"
eq "$(deps '__Depends on:__ #78')"   '78'  "UNDER: ...with __ delimiters"
eq "$(deps '**Blocked by** **#78**')" '78' "UNDER: both halves formatted at once"

# UNDER — the forms that already worked must not regress. `**Depends on: #78 only.**` is the one
# that made this defect so easy to miss: the `**` never sits between the keyword and the number.
eq "$(deps '**Depends on: #78 only.**')" '78' "UNDER: emphasis PRECEDING the keyword (worked before)"
eq "$(deps '- Blocked by #155')"         '155' "UNDER: the unformatted list item (worked before)"
eq "$(deps '- **Blocked by #155**')"     '155' "UNDER: the whole clause bolded (worked before)"
eq "$(deps 'Depends on #5**')"           '5'   "UNDER: a stray trailing run does not invalidate a direct reference"

# UNDER — chains and the numeric bound survive formatting.
eq "$(deps "Depends on **#5**, **#6** and ${bt}#7${bt}")" '5 6 7' \
   "UNDER: a formatted chain yields every member (the closer must not end the chain)"
eq "$(deps 'Depends on **#5**, #6')"      '5 6' "UNDER: mixed formatted/plain chain"
# ONE wrapper around a WHOLE chain. A first cut of this fix required an opener to reappear right
# after the digits, which is false here — the closer follows the LAST member — so `#5` was dropped
# and the scan resumed inside the text it had just rejected, yielding `6` alone. A partial set is
# the worst outcome available: it reads as resolved while a real prerequisite has vanished.
eq "$(deps 'Depends on **#5, #6**')"      '5 6' "UNDER: one wrapper around a whole chain"
eq "$(deps 'Depends on **#5, #6, #7**')"  '5 6 7' "UNDER: ...of any length"
eq "$(deps 'Depends on **#5 and #6**')"   '5 6' "UNDER: ...joined by 'and'"
eq "$(deps 'Depends on __#5, #6__')"      '5 6' "UNDER: ...for every delimiter"
eq "$(deps "Depends on ${bt}#5, #6${bt}")" '5 6' "UNDER: ...including a code span"
# An UNBALANCED run is accepted on purpose: the author who typed it still declares the edge, and
# refusing it is the under-match direction. See the PAIRING note in roadmap-lib.sh's STEP block.
eq "$(deps 'Depends on **#5')"            '5'   "UNDER: an unclosed opener still declares"
eq "$(deps "Depends on ${bt}#5 and more${bt}")" '5' \
   "UNDER: a phrase-quoted reference still declares (the edge is real; markup is not content)"
eq "$(deps 'Depends on **#73** and **#78**' 73)" '78' "UNDER: the self-edge is still dropped"
eq "$(deps 'Depends on **#999999999**')"  '999999999' "UNDER: a formatted 9-digit reference resolves"

# OVER — the guard that matters most: the tolerance must not become a blanket punctuation skip.
# Each of these is one character away from a fixture above.
eq "$(deps 'Depends on * #5')"   '' \
   "OVER: a run floating in whitespace is not emphasis (cf. '*Blocked by* #5', which IS)"
eq "$(deps 'Depends on ** #5 **')" '' "OVER: spaced asterisks are not emphasis in CommonMark either"
eq "$(deps "Depends on ${bt}ignore #5${bt}")" '' \
   "OVER: the run must reach '#' without crossing a word character"
eq "$(deps 'Depends on **ignore #5**')"       '' "OVER: ...for every delimiter, not just backticks"
# `~` is deliberately NOT in EMPH, and this is the one place widening the set later would be
# actively WRONG rather than merely broader: struck-through text reads as RETRACTED, so honouring
# `~~#5~~` would convert a retirement into a declaration — the #108 direction, inverted.
eq "$(deps 'Depends on ~~#5~~')"   '' "OVER: strikethrough reads as retracted, so it declares nothing"
eq "$(deps 'Depends on [#5](http://x)')"   '' "OVER: a markdown link is not a wrapped reference"
eq "$(deps 'Depends on **[#5](http://x)**')" '' "OVER: ...nor a bolded one"

# OVER — every #69/#108/#117 guarantee re-pinned WITH the newly accepted syntax, because a
# widened match is exactly where an old guard silently loosens. The first three never reach the
# widened grammar at all — they carry no `depend`/`blocked`, so the cheap bail discards the line
# before STEP runs — which is precisely the guarantee they pin: formatting must not turn a
# non-keyword into one. The rest DO exercise STEP.
eq "$(deps 'Refs **#52**')"  '' "OVER: 'Refs' is still not a keyword, however formatted"
eq "$(deps 'See **#52**')"   '' "OVER: ...nor 'See'"
eq "$(deps '**#52**')"       '' "OVER: a bare formatted reference is still not an edge"
eq "$(deps 'Depends on **acme/repo#5**')" '' "OVER: a bolded QUALIFIED reference is still not local"
eq "$(deps 'Depends on acme/repo**#5**')" '' "OVER: ...nor one whose number alone is bolded"
eq "$(deps 'No longer depends on **#25**')" '' "OVER: a formatted negation still RETIRES"
eq "$(deps 'No longer **depends on:** #25')" '' "OVER: ...with the keyword formatted too"
eq "$(deps "This is ${bt}not${bt} blocked by **#5**")" '' \
   "OVER: a code-formatted negator still retires a formatted edge"
eq "$(deps "${bt}Depends on${bt} **#5**")" '' \
   "OVER: a quoted KEYWORD declares nothing even when the reference is real markup"
eq "$(deps 'Depends on **#5** (the gate) and #6')" '5' \
   "OVER: formatting does not defeat the conservative chain stop"
eq "$(deps 'Depends on **#9999999999**')" '' \
   "OVER: the 10-digit bound holds through formatting (leftmost-longest must not truncate to 9)"
eq "$(deps 'Depends on **#99999999999999999999**, **#5**')" '5' \
   "OVER: ...and the rest of a formatted chain still resolves"
eq "$(deps 'Depends on **#0**')" '' "OVER: #0 is not an issue reference, formatted or not"

# OVER — STRUCTURE still wins over the widened match. A formatted edge inside a fence, a comment
# or a blockquote is still documentation (#117); this is the intersection the two rules share.
eq "$(depsm "$q3" 'Depends on **#5**' "$q3" 'Depends on **#7**')" '7' \
   "OVER: a formatted edge quoted in a fence declares nothing"
eq "$(deps '<!-- Depends on **#5** --> Depends on **#7**')" '7' \
   "OVER: ...nor one inside an HTML comment"
eq "$(deps '> Depends on **#5**')" '' "OVER: ...nor a blockquoted one"
eq "$(deps '* Depends on #5')" '5' \
   "a bullet is still a LIST MARKER, not emphasis that swallows the line's prose"

# --- 6k. DEPS-AMBIGUOUS — what the grammar REFUSED, reported instead of dropped (#132) -------
# Every fix in this family (#69, #108, #112, #117, #136) resolved an ambiguity by picking a side
# SILENTLY, so /roadmap could not tell "this body declares no edge" from "this body declares an
# edge I could not parse" — opposite facts with identical output. The reporting contract is D28.
#
# Each fixture is labelled REPORT (the site must surface) or SILENT (it must not). The SILENT
# group is the false-positive budget, and it is the half that decides whether this is useful or
# noise: a report on every body that merely mentions an issue number gets ignored, which is worse
# than the silence it replaced.

# amb <body> [self] -> the records, `kind:line:issue` space-separated ('' when none).
amb() {
  printf '%s' "$1" | run_rl deps-ambiguous ${2:+"$2"} \
    | tr ' ' '\n' | awk -F'\t' 'NF==3 {printf "%s%s:%s:%s", (n++?" ":""), $1, $2, $3}'
}
# ambm <line>... — the same, for a MULTI-LINE body (cf. depsm).
ambm() {
  printf '%s\n' "$@" | run_rl deps-ambiguous \
    | tr ' ' '\n' | awk -F'\t' 'NF==3 {printf "%s%s:%s:%s", (n++?" ":""), $1, $2, $3}'
}

# REPORT — the two witnesses the issue names, verified still ambiguous in the owner's own comment.
eq "$(amb 'Depends on #5 (the gate) and #6')" 'partial:1:6' \
   "REPORT: an interrupted chain names the reference it dropped"
eq "$(deps 'Depends on #5 (the gate) and #6')" '5' \
   "...while the EDGE output is unchanged (this is a report, never a parser widening)"
eq "$(amb 'Depends on issue 5')" 'no-hash:1:5' \
   "REPORT: a reference written without a '#' is surfaced, not silently empty"
eq "$(deps 'Depends on issue 5')" '' "...and still declares no edge"

# REPORT — the shapes #112 deliberately refuses. Each is one character from a form that DECLARES,
# which is exactly why a silent refusal was indistinguishable from no declaration at all.
eq "$(amb 'Depends on [#5](http://x)')" 'unparsed:1:5' "REPORT: a markdown link"
eq "$(amb 'Depends on * #5')"           'unparsed:1:5' "REPORT: a run floating in whitespace"
eq "$(amb "Depends on ${bt}ignore #5${bt}")" 'unparsed:1:5' \
   "REPORT: a reference the span could not reach without crossing a word"
eq "$(amb 'Depends on ~~#5~~')"         'unparsed:1:5' "REPORT: strikethrough (retracted, but visibly so)"
eq "$(amb 'Depends on the gate and #6')" 'unparsed:1:6' "REPORT: prose between the keyword and the reference"
eq "$(amb 'Depends on #5, #6 and the gate and #7')" 'partial:1:7' \
   "REPORT: a chain that resolves two members and drops the third"
eq "$(deps 'Depends on #5, #6 and the gate and #7')" '5 6' "...and the two that resolved still do"

# REPORT — the SYNTAX COLON of `Depends on:` is not a clause boundary. STEP eats it as a separator
# only when a `#N` follows, so on exactly the paths this subcommand exists for it was still sitting
# at the head of the window and the boundary scan cut the window to nothing. Three ordinary
# spellings went silent. (Independent-review find.)
eq "$(amb 'Depends on: issue 5')"    'no-hash:1:5'  "REPORT: the colon form of the hash-less witness"
eq "$(amb 'Depends on: [#5](url)')"  'unparsed:1:5' "REPORT: ...of a markdown link"
eq "$(amb 'Depends on: * #5')"       'unparsed:1:5' "REPORT: ...and of a floating run"
eq "$(deps 'Depends on: #5')" '5' "...while the colon form that RESOLVES still declares its edge"
eq "$(amb 'Depends on: #5')"  ''   "...and reports nothing"
# A colon AFTER a resolved reference is ordinary punctuation and still ends the clause — the strip
# is gated on the chain having consumed nothing, so these two cannot collapse into one rule.
eq "$(amb 'Depends on #5: see #6 for context')" '' "SILENT: a colon after a resolved reference still bounds"

# REPORT — a hash-less reference is surfaced even when the SAME occurrence already declared an edge,
# and every match is named rather than the first. Gating this on "declared nothing" hid a partially
# parsed chain, which is the precise thing this subcommand exists to say. (Independent-review find.)
eq "$(amb 'Depends on #5 and issue 6')" 'partial:1:6' \
   "REPORT: a hash-less reference dropped from a chain that DID declare"
eq "$(deps 'Depends on #5 and issue 6')" '5' "...and the edge it did declare is unchanged"
eq "$(amb 'Depends on issue 5 and issue 6')" 'no-hash:1:5 no-hash:1:6' \
   "REPORT: every hash-less reference, not just the first"
eq "$(amb 'Depends on * #5 and issue 6')" 'unparsed:1:5 no-hash:1:6' \
   "REPORT: the two scans are independent — neither shape subsumes the other"

# REPORT — multiple sites, deduped, in scan order (line ascending). Determinism comes from the
# scan order itself, so no sort is applied and none is needed.
eq "$(ambm 'Depends on * #5' 'Blocked by [#6](u)')" 'unparsed:1:5 unparsed:2:6' \
   "REPORT: one record per site, line-ordered"
eq "$(amb 'Depends on * #5 and blocked by * #5')" 'unparsed:1:5' \
   "REPORT: an identical record from two keyword occurrences collapses"

# SILENT — a QUALIFIED reference is RECOGNIZED and correctly excluded, never "unparsed". The
# word-character guard IS the cross-repo rule; reporting a confident answer is what makes noise.
eq "$(amb 'Depends on acme/repo#5')"        '' "SILENT: a qualified reference is a confident non-edge"
eq "$(amb 'Depends on #5 and other/repo#7')" '' "SILENT: ...including one that ends a chain"
eq "$(amb 'Depends on **acme/repo#5**')"    '' "SILENT: ...formatted"

# SILENT — the two false-positive traps a naive "keyword present, reference unconsumed" rule hits.
# Both were live shapes before the window and the negation skip were added.
eq "$(amb 'Depends on #5 and blocked by #6')" '' \
   "SILENT: the window ends at the NEXT keyword, which is about to claim that reference"
eq "$(deps 'Depends on #5 and blocked by #6')" '5 6' "...and both edges still resolve"
neg_fx='Depends on #78; it is not blocked by #25'  # adb-claim-ok: fixture prose reusing this suite's standing #25/#78 example numbers, not a citation
eq "$(amb "$neg_fx")" '' "SILENT: a NEGATED occurrence is a confident answer, not an ambiguity"
# PAIRED with the edge assertion, because the ambiguity fixture alone is VACUOUS here: remove the
# negation skip and the reference is consumed as an ordinary edge, so the report stays empty either
# way. The edge output is what actually moves. (Independent-review find, the same class as the
# self-reference pair below.)
eq "$(deps "$neg_fx")" '78' "...and the negated reference is not an edge either"
eq "$(amb 'No longer depends on #25')" '' "SILENT: ...whether or not anything else declares"  # adb-claim-ok: fixture prose, not a citation
eq "$(deps 'No longer depends on #25')" '' "...and declares no edge, which is the half a mutation moves"  # adb-claim-ok: fixture prose, not a citation
pre_fx='The #25 prerequisite was dropped; blocked by #78'  # adb-claim-ok: fixture prose, not a citation
eq "$(amb "$pre_fx")" '' "SILENT: a reference BEFORE the keyword is in no window"

# SILENT — the clause boundary. Measured, not assumed: without it this fired 13 times on this
# repo's own 37 open bodies and every one was of this shape — commentary after the declaration.
eq "$(amb '- #81 depends on #79 — **satisfied**, #79 closed COMPLETED (PR #111).')" '' \
   "SILENT: an em-dash ends the declaration, so the restatement and the PR number are commentary"
stop_fx='**Why it is blocked on this issue.** #123 rejects the approach'  # adb-claim-ok: quotes #141's body verbatim as the measured witness; the incident, not a citation
eq "$(amb "$stop_fx")" '' "SILENT: a full stop ends it too, so the next sentence is not a dropped edge"
eq "$(amb 'Depends on #5; see #6 for context')" '' "SILENT: ...and a semicolon"
# ...and the same sentence WITHOUT the punctuation reports, which is the boundary being deliberate
# rather than incidental. An author who meant `and #6` writes almost exactly this, so the clause is
# genuinely ambiguous; punctuation is how a body says "the declaration ended here".
eq "$(amb 'Depends on #5 and see #6 for context')" 'partial:1:6' \
   "REPORT: no clause boundary means the reference is still inside the declaration"

# The numeric width bound applies to the REPORT too — a run wider than an issue number would print
# rounded or in exponent form, fabricating an issue number no tracker can have (cf. § 6f).
eq "$(amb 'Depends on * #999999999')"  'unparsed:1:999999999' "a 9-digit reference still reports"  # adb-claim-ok: a width-bound fixture; the number is deliberately one no tracker can have
eq "$(amb 'Depends on * #9999999999')" '' "...and a 10-digit one is not a reference at all"  # adb-claim-ok: a width-bound fixture; the number is deliberately one no tracker can have
eq "$(amb 'Depends on issue 9999999999')" '' "...on the no-hash path either"
# Two unconsumed references in ONE window are both named; a report that stopped at the first would
# under-state what the line lost.
eq "$(amb 'Depends on * #5 and see #6 for context')" 'unparsed:1:5 unparsed:1:6' \
   "REPORT: every unconsumed reference in the window, not just the first"

# SILENT — ordinary prose. `Depends on 2 things` is English; `issue <N>` is the ONLY hash-less
# shape reported, and widening past it is what turns this into noise.
eq "$(amb 'Depends on 2 things')"          '' "SILENT: a bare number is not an attempted reference"
eq "$(amb 'Depends on the design decision')" '' "SILENT: no reference of any shape"
eq "$(amb 'Refs #69')"                     '' "SILENT: no keyword, so no site at all"
eq "$(amb 'Depends on #5, #6 and #7')"     '' "SILENT: a chain that fully resolves"
eq "$(amb 'Depends on **#52**')"           '' "SILENT: a form #112 made resolve is no longer ambiguous"  # adb-claim-ok: #52 is #112's own example number, quoted
eq "$(amb "Depends on ${bt}#5${bt}")"      '' "SILENT: ...nor a span around only the reference"
eq "$(amb '')"                             '' "SILENT: an empty body"

# SILENT — a SELF reference is dropped by the edge scan on purpose, so it must not resurface here
# as an ambiguity. The load-bearing case is an UNPARSED self reference: a resolvable one is
# consumed by the chain and never reaches the window at all, so the two fixtures below it pin the
# absence of a report without exercising the guard that produces it. (Both shapes are kept — the
# first is the one a mutation can break; the others pin the ordinary path — but only after a
# mutation run showed the ordinary pair passing with the guard deliberately removed.)
eq "$(amb 'Depends on * #73' 73)"        '' "SILENT: an UNPARSED self reference is not an ambiguity"  # adb-claim-ok: #73 is this suite's standing self-edge fixture number
eq "$(amb 'Depends on issue 73' 73)"     '' "SILENT: ...nor a hash-less one"
eq "$(amb 'Depends on #73' 73)"          '' "SILENT: a body depending only on itself"  # adb-claim-ok: fixture self-edge number
eq "$(amb 'Depends on #73 and #78' 73)"  '' "SILENT: ...alongside a real edge"  # adb-claim-ok: fixture self-edge number

# SILENT — STRUCTURE wins here exactly as it does for edges. The report runs on the SAME resolved
# MD_TEXT/MD_MASK views, so a documented example cannot become an ambiguity report either — which
# is the whole reason this is one scan in two modes rather than a second parser.
eq "$(ambm "$q3" 'Depends on * #5' "$q3")" '' "SILENT: a fenced example reports nothing"
eq "$(amb '<!-- Depends on * #5 -->')"     '' "SILENT: ...nor an HTML comment"
eq "$(amb '> Depends on * #5')"            '' "SILENT: ...nor a blockquote"
eq "$(amb "see ${bt}Depends on * #5${bt} here")" '' "SILENT: ...nor a quoted clause"
eq "$(ambm 'para' '' '    Depends on * #5')" '' "SILENT: ...nor a top-level indented block (D27)"

# ARGUMENT VALIDATION — fail-closed, matching every other subcommand.
printf 'x' | bash "$RL" deps-ambiguous notanumber >/dev/null 2>&1
eq "$?" 2 "a non-numeric self-issue-number is an ERROR"
printf 'x' | bash "$RL" deps-ambiguous 1 2 >/dev/null 2>&1
eq "$?" 2 "deps-ambiguous rejects extra arguments"
printf 'Depends on * #5' | bash "$RL" deps-ambiguous >/dev/null 2>&1
eq "$?" 0 "a REPORT still exits 0 — non-zero is a caller hard-stop, so it cannot mean 'found one'"
printf 'nothing here' | bash "$RL" deps-ambiguous >/dev/null 2>&1
eq "$?" 0 "...and so does the ordinary empty result"

# DETERMINISM (#45).
afx='Depends on * #5 and blocked by [#6](u)'
eq "$(amb "$afx")" "$(amb "$afx")" "deps-ambiguous is deterministic"

# --- 6k-bis. A CRASHED SCAN IS AN ERROR, NEVER A CLEAN EMPTY ---------------------------------
# `awk | sort` reports only sort, so before this both subcommands answered a BROKEN scan with
# exit 0 and no output — which for `deps-from-body` means "this body declares no edges" and
# silently unblocks a bundle that is genuinely blocked. The library header promises the opposite
# ("EXIT STATUS IS FAIL-CLOSED"), and nothing was checking it, because a check that cannot answer
# wrong looks exactly like a check that found nothing wrong.
#
# Negative-testing needs a REJECTABLE input, and the input here is a broken library. Build it in a
# TEMP DIR and break the copy — never the tracked file (base/practices/self-review.md: editing a
# tracked file to test a check that reads tracked files ends in a `git checkout -- <path>` that
# has cost this project unsaved work).
crashdir="$(mktemp -d "${TMPDIR:-/tmp}/rl-crash.XXXXXX")"
if [ -d "$crashdir" ]; then
  cp "$ROOT/scripts/lib/common.sh" "$crashdir/common.sh"
  # A syntax error inside the awk program: the scan cannot run, so any answer it gives is a lie.
  #
  # `sed`, not `perl`. Perl is NOT a declared prerequisite of this repo (AGENTS.md asks for portable
  # POSIX-safe shell that passes the linter, and this was the only perl call in the checks tree) — on a
  # minimal Linux or macOS box it would exit 127, leave the copy UNBROKEN, and fail the two
  # assertions below against a perfectly valid library, taking the required `selfcheck` red with it.
  # A test whose failure mode is "the environment lacked a tool nobody promised" is worse than no
  # test. (Bot-review find on PR #254.)
  sed 's/function eat(at)/function eat(at) THIS IS NOT AWK/' "$RL" > "$crashdir/roadmap-lib.sh"
  # ASSERT THE MUTATION LANDED. A substitution that matched nothing leaves a VALID library, and
  # then these assertions would be testing the opposite of what they claim — the same vacuity the
  # unbroken-copy check below guards from the other side.
  if cmp -s "$RL" "$crashdir/roadmap-lib.sh"; then
    bad "the crashed-scan fixture did not break its copy (the anchor text moved?) — assertions would be vacuous"
  else
    printf 'Depends on #5' | bash "$crashdir/roadmap-lib.sh" deps-from-body >/dev/null 2>&1
    eq "$?" 2 "a crashed scan makes deps-from-body an ERROR, not an empty edge set"
    printf 'Depends on * #5' | bash "$crashdir/roadmap-lib.sh" deps-ambiguous >/dev/null 2>&1
    eq "$?" 2 "...and deps-ambiguous too"
  fi
  # Prove the fixture can distinguish: the SAME copy, unbroken, still answers normally. Without
  # this the two assertions above would also pass against a library that always exited 2.
  cp "$RL" "$crashdir/roadmap-lib.sh"
  eq "$(printf 'Depends on #5' | bash "$crashdir/roadmap-lib.sh" deps-from-body)" '5' \
     "...while the same copy UNBROKEN still resolves the edge (the fixture is not vacuous)"
  rm -rf "$crashdir"
else
  bad "could not create a temp dir for the crashed-scan fixture"
fi

# ============================================================================================
# 7. DECISIONS — the durable home that retires an owner question (#108)
# ============================================================================================
# The reproduced bug: a decision recorded in an issue COMMENT is invisible to reconcile, so the
# same question reprinted every run, forever. `decisions` reads the artifact's owner-authoritative
# section so "has the owner already answered this?" is mechanical, not re-litigated each run.

# dcs <body> -> recorded question ids, space-separated ('' when none).
dcs() { printf '%b' "$1" | run_rl decisions; }

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

# STRUCTURE (#117) — `decisions` reads the same document as `deps-from-body`, so it runs the same
# filter. Without it, two bugs live here, and the artifact ships BOTH shapes inside this very
# section (a schema HTML comment, and fenced examples elsewhere in the body).
eq "$(dcs "${D_HEAD}${q3}\n| fake:#99 | a quoted example | — |\n${q3}\n| a:#1 | x | — |\n")" 'a:#1' \
   "a table row quoted in a fence is NOT a recorded decision (it would retire an unanswered question)"
eq "$(dcs "${D_HEAD}${q3}\n# not a heading\n${q3}\n| a:#1 | x | — |\n")" 'a:#1' \
   "a #-line quoted in a fence does not end the section (that is #108 returning by another route)"
eq "$(dcs "${D_HEAD}<!--\n| example:#7 | the schema's own example row | — |\n-->\n| a:#1 | x | — |\n")" 'a:#1' \
   "a row inside a MULTI-LINE HTML comment is not a decision"
eq "$(dcs "${D_HEAD}> | quoted:#8 | from another thread | — |\n| a:#1 | x | — |\n")" 'a:#1' \
   "a blockquoted row is quoted material, not a decision"
eq "$(dcs "${D_HEAD}${q3}\r\nx\r\n${q3}\r\n| a:#1 | y | — |\r\n")" 'a:#1' \
   "a CRLF body closes its fence here too (see the CRLF note in 6i)"
# The #136 repros reach THIS consumer too — it reads the same document through the same filter.
eq "$(dcs "${D_HEAD}The opener is \`<!--\` in the schema.\n| a:#1 | x | — |\n")" 'a:#1' \
   "a <!-- quoted in a span does not swallow the rest of the section (#136 §2, the #108 shape)"
eq "$(dcs "${D_HEAD}\`| fake:#9 | quoted\nacross two lines | — |\`\n| a:#1 | x | — |\n")" 'a:#1' \
   "a row inside a MULTI-LINE code span is not a decision (#136 §1)"
# A BLANK LINE first, because that is what an indented code block actually requires: indented text
# directly under a paragraph line is a lazy continuation, not code. Writing this fixture without
# the blank line would have pinned the opposite rule.
eq "$(dcs "${D_HEAD}\n    | indented:#9 | code | — |\n\n| a:#1 | x | — |\n")" 'a:#1' \
   "a row inside a 4-space indented code block is not a decision (D27)"
eq "$(dcs "${D_HEAD}    | lazy:#9 | a continuation, not code | — |\n")" 'lazy:#9' \
   "UNDER: ...but an indented row DIRECTLY under one is a continuation and is still read"
# UNDER-match control: the section itself must survive every one of those.
eq "$(dcs "${D_HEAD}| a:#1 | x | — |\n| b:#2 | y | — |\n")" 'a:#1 b:#2' \
   "...and ordinary rows are still read (the filter must not eat the section)"

# --- 7b. release-command / marker-title: the two COMMENT-shaped declarations (#136) ----------
# These read a marker that IS an HTML comment, so they run the shared filter with comment
# stripping OFF — spans and blocks still removed. That combination is why the filter takes a
# `--keep-comments` flag at all; before it, each carried its own fence detector (or, for
# `marker-title`, none whatever).
rcmd() { printf '%b' "$1" | run_rl release-command; }
mtit() { printf '%b' "$1" | run_rl marker-title; }
eq "$(rcmd '<!-- release-command: release -->\n')" 'release' "UNDER: a top-level release-command declares"
eq "$(rcmd "${q3}\n<!-- release-command: fenced -->\n${q3}\n")" '' "OVER: ...but a fenced one does not"
eq "$(rcmd '> <!-- release-command: bq -->\n')" '' "OVER: ...nor a blockquoted one"
eq "$(rcmd "See ${bt}<!-- release-command: spanned -->${bt} above.\n")" '' "OVER: ...nor one inside a code span"
eq "$(rcmd '    <!-- release-command: indented -->\n')" '' "OVER: ...nor one in an indented block (D27)"
eq "$(rcmd "<!-- release-command: ${bt}quoted${bt} -->\n")" '' \
   "OVER: a value carrying backticks is not a declaration — a skill can never be named that"
eq "$(mtit '<!-- release-milestone: Next release -->\n')" 'Next release' "UNDER: a top-level marker-title declares"
eq "$(mtit "${q3}\n<!-- release-milestone: Fake -->\n${q3}\n<!-- release-milestone: Real -->\n")" 'Real' \
   "OVER: a FENCED example is not a second title — two titles make the artifact ambiguous and refuse it"
eq "$(mtit "Docs: ${bt}<!-- release-milestone: Fake -->${bt}\n<!-- release-milestone: Real -->\n")" 'Real' \
   "OVER: ...nor is a code-spanned one"
eq "$(mtit '> <!-- release-milestone: Quoted -->\n<!-- release-milestone: Real -->\n')" 'Real' \
   "OVER: ...nor a blockquoted one"
eq "$(mtit '<!-- release-milestone: A -->\n<!-- release-milestone: B -->\n')" 'A B' \
   "UNDER: two REAL markers still both surface, so the caller can refuse an ambiguous artifact"
# A BACKTICK INSIDE A COMMENT IS COMMENT DATA, NOT A SPAN DELIMITER (review round 1). With comment
# detection skipped in keep-comments mode, two comments paired their ticks ACROSS the declaration
# between them and masked it away — a real marker returning nothing, with exit 0.
eq "$(mtit "<!-- note ${bt} -->\n<!-- release-milestone: Real -->\n<!-- ${bt} note -->\n")" 'Real' \
   "UNDER: backticks in two separate comments do not pair across a real marker between them"
eq "$(rcmd "<!-- note ${bt} -->\n<!-- release-command: real -->\n<!-- ${bt} note -->\n")" 'real' \
   "UNDER: ...and the same for release-command"
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

# --- 8d. #117: the workflow states that only PROSE declares an edge --------------------------
# The rule lives in three places in the workflow (the artifact schema comment, the predicate
# contract, the ordering rule). Pin it so a later edit cannot quietly drop the structural half and
# leave agents re-deriving the pre-#117 substring rule by eye.
has "$wf" 'ONLY PROSE DECLARES' \
  "the artifact schema says a mention inside markup is documentation, not a declaration (#117)"
has "$wf" 'Only prose declares' \
  "the predicate contract carries the structural rule (#117)"
has "$wf" 'fenced code block, HTML comment, blockquote or quoted span' \
  "the ordering rule names the structures that never declare an edge (#117)"

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
# ...but ONLY in release-readiness mode. Step 4b is convention-agnostic hygiene that runs on every
# repo, and the overlay promises classic mode stays byte-identical — a repo that merely has the
# label (e.g. ran `release init`, no marker yet) must keep the plain sweep. (Bot-review find.)
has "$autofix_block" 'RELEASE_MODE' \
  "...and the carve-out is gated on release-readiness mode being ACTIVE"
has "$autofix_block" '$carve == 0 or' \
  "...so in classic mode the sweep filter reduces to its pre-overlay form"
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
