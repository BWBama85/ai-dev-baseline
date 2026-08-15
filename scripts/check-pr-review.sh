#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the pre-arm review guard (scripts/lib/pr-review.sh, #134).
# OFFLINE: no network, no gh auth, no real repo is touched.
#
# The guard has exactly one dangerous direction: returning 0 while a reviewer is still coming.
# Every case below is chosen because it is a way that could happen, or a way the guard could wedge
# at non-zero forever and quietly disable auto-merge for good:
#
#   1. IDENTITY, ASYMMETRICALLY. The same bot has two spellings — GraphQL says
#      `chatgpt-codex-connector`, REST says `chatgpt-codex-connector[bot]` — and the shipped
#      allowlist carries the bare form, so an anchored exact match would never fire and the guard
#      would sit at 16 even after the review landed. The API login is therefore normalized TOWARD
#      the declaration, never the reverse (#173): a bare declaration accepts either spelling, a
#      `[bot]` declaration accepts only the suffixed one. Pinned in both directions, plus a WRONG
#      bot, plus the fail-open this replaced — stripping the DECLARATION too, which let a HUMAN
#      account named `foo` satisfy `bots = ["foo[bot]"]`.
#   1b. REPOSITORY IDENTITY. Every read addresses `repos/{owner}/{repo}`, so the guard can be
#      pointed at another project two ways: a URL argument naming one (including the scheme-less
#      form this module used to let through with an empty slug), or `GH_REPO` redirecting gh's own
#      expansion when the argument is a bare number. Both are refused, and neither may print a head
#      SHA — printing it is what authorized the arm.
#   2. THE SHA. A review of an earlier commit is not a review of this one. Observed live on
#      PR #145: the bot reviewed b302fa0e, three commits landed after it.
#   3. THE DECLARATION TRI-STATE. `bots = []` (no reviewer -> arm) and undeclared (unknowable ->
#      fail closed) must never collapse into each other; that collapse IS #134.
#   4. EVERY UNREADABLE PATH -> 20. A failed read must never look like "nobody is pending".
#   5. THERE ARE THREE SURFACES, AND THEY ARE ORDERED (#167). This guard read only
#      `pulls/N/reviews`, so the connector's other two output shapes were invisible: a clean pass
#      posts a `+1` reaction and NO review object (16 forever), and in task mode it posts ONE issue
#      comment and no review at all (16 on EVERY PR — unattended arming silently dead, disabled by
#      a vendor-side setting nobody in the repo changed). Both shapes are live on this repo and are
#      disjoint. The order is rejected > attention > unknown > clean > none, and the two positions
#      that carry weight are pinned: a COMMENTED review or a fresh issue comment is `attention`
#      (21) and NOT a satisfied review — "the reviewer has spoken" is not "the reviewer is
#      satisfied" — and an UNKNOWN state is no longer outweighed by an accepted one.
#   5b. AND A DATE-SCOPED SIGNAL NEEDS A SERVER-ASSIGNED LOWER BOUND (#175/D19). A reaction carries
#      no commit, so a `+1` from an earlier head still sits there after new commits land; accepting
#      it would ARM A MERGE on unreviewed code. The anchor is the ref-activity record, never the
#      client-supplied committer date — asserted as a NEGATIVE (the endpoint is never addressed),
#      because a verdict assertion alone would pass against a module that read it and weighted it
#      differently. An unestablished anchor is 16, never 0.
#   6. THE SET IS ALL-OR-NOTHING (#185). One declared reviewer's `+1` must not speak for the whole
#      declared set — on the two new surfaces as much as on reviews.
#
# What genuinely CANNOT be tested here (needs a live run): that GitHub delivers the App's review,
# that `--match-head-commit` actually rejects a moved head, and real 403/404 bodies. A stub can
# prove the PARSING and the DECISION; it can never prove which SHAPE the connector emits, since
# that is decided by vendor-side configuration rather than by anything in the repo — which is
# exactly why the guard reads all three surfaces instead of the one the vendor documents.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pr-review.sh   (exit 0 = all pass, 1 = a failure)

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
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
PR="$ROOT/scripts/lib/pr-review.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

REPO="$work/repo"; GHOME="$work/home"; SBIN="$work/sbin"; S="$work/stub"
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$SBIN" "$S"
# A git repo so the helper's repo-root resolution is deterministically $REPO, whatever ambient git
# repo sits above the temp dir. `check_make_stub_repo` carries the `origin`-remote contract (#173).
check_make_stub_repo "$REPO" https://github.com/acme/widget.git || {
  echo "check-pr-review: FATAL — could not build the fixture repo" >&2; exit 1; }

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ============================ the recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the reviews URL is
# ALSO a `repos/*` URL, so a case arm that matches the general shape first swallows the specific
# one and every scenario silently reads the wrong fixture. Most specific first, always.
check_write_stub "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Answers the FIVE reads the guard can make, from $S fixtures. Knobs:
#   STUB_AUTH_FAIL=1       -> `gh auth status` fails (unauthenticated)
#   STUB_FAIL_PR=1         -> the PR read fails
#   STUB_FAIL_REVIEWS=1    -> the reviews read fails
#   STUB_FAIL_COMMENTS=1   -> the issue-comments read fails
#   STUB_FAIL_REACTIONS=1  -> the reactions read fails
#   STUB_FAIL_ACTIVITY=1   -> the ref-activity read fails
#   STUB_EMPTY_ACTIVITY=1  -> the ref-activity read SUCCEEDS with an empty body (not `[]`)
#   STUB_EMPTY_<SURFACE>=1 -> that signal read SUCCEEDS with an empty body (REVIEWS/COMMENTS/REACTIONS)
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
case "${1:-}" in
  auth) exit 0 ;;
  api)  ;;
  *)    exit 0 ;;
esac
url=""
for a in "$@"; do
  case "$a" in repos/*) [ -z "$url" ] && url="$a" ;; esac
done
# EVERY api call is recorded, which is how the suite proves NEGATIVES — that the head-commit
# endpoint is never read (the client-supplied date #175 removed), and that the ref-activity read is
# NOT paid for on a PR with no date-scoped signal.
printf '%s\n' "$url" >> "$S/calls"
# emit <file> : the fixture, or `[]` when the scenario wrote none. AN ABSENT FIXTURE MEANS "no
# records", which the real API spells `[]` — it NEVER answers a bare empty body for an empty list.
# Modelling it as an empty body would make every scenario that does not write comments/reactions
# exercise the unreadable path instead of the one it is testing; the deliberate empty-body case has
# its own STUB_EMPTY_* knob.
emit() { if [ -f "$1" ]; then cat "$1"; else printf '[]\n'; fi; }
case "$url" in
  */reviews*)
    [ "${STUB_FAIL_REVIEWS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_REVIEWS:-0}" = "1" ] && exit 0
    # --paginate concatenates ONE JSON DOCUMENT PER PAGE; page 2 exists only in the pagination
    # scenario, so the default case still emits a single well-formed page.
    emit "$S/reviews.json"
    [ -f "$S/reviews2.json" ] && cat "$S/reviews2.json"
    exit 0 ;;
  */issues/*/comments*)
    [ "${STUB_FAIL_COMMENTS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_COMMENTS:-0}" = "1" ] && exit 0
    emit "$S/comments.json"
    [ -f "$S/comments2.json" ] && cat "$S/comments2.json"
    exit 0 ;;
  */reactions*)
    [ "${STUB_FAIL_REACTIONS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_REACTIONS:-0}" = "1" ] && exit 0
    emit "$S/reactions.json"
    [ -f "$S/reactions2.json" ] && cat "$S/reactions2.json"
    exit 0 ;;
  */activity*)
    [ "${STUB_FAIL_ACTIVITY:-0}" = "1" ] && exit 1
    # A SUCCESSFUL read with an empty body — distinct from `[]`, and the reason the module reads and
    # parses in two steps. Collapsing them would turn this into "no matching activity" (an
    # unestablished anchor, which the gate sits on as 16) when it is really "the call produced no
    # document" (20).
    [ "${STUB_EMPTY_ACTIVITY:-0}" = "1" ] && exit 0
    emit "$S/activity.json"
    exit 0 ;;
  */pulls/*)
    [ "${STUB_FAIL_PR:-0}" = "1" ] && exit 1
    cat "$S/pr.json"; exit 0 ;;
  repos/*)
    exit 0 ;;
esac
exit 0
STUB

# ---- fixtures --------------------------------------------------------------------------------
# WHEN THE HEAD REF BECAME THE HEAD SHA, as the repository activity API recorded it (#175/D19) —
# NOT the head commit's committer date, which is client-supplied and which the guard never reads.
# Every reaction/comment fixture is expressed relative to it so the staleness rule reads at a glance.
HEAD_REF="feature"
ARRIVED_AT="2026-07-25T04:42:15Z"
AFTER_AT="2026-07-25T04:45:23Z"    # 3m08s later — the real gap observed on PR #88
BEFORE_AT="2026-07-25T04:40:00Z"

# pr_fx [--sha X] [--base-slug X] [--head-slug X] [--head-ref X] [--state X] [--merged-at X]
# A defaults wrapper over `check_pr_json`, which holds the fixture shape (D68). Last flag wins, so
# `pr_fx --head-slug ""` renders `head.repo` null — a deleted fork, which the anchor must degrade on.
pr_fx() {
  check_pr_json "$S/pr.json" --sha "$HEAD_SHA" --base-slug acme/widget \
    --head-slug acme/widget --head-ref "$HEAD_REF" "$@"
}
pr_fx_raw()  { printf '%s\n' "$1" > "$S/pr.json"; }
# The four payload builders and the call recorder live in check-lib.sh (#167): both PR-guard suites
# now exercise ONE shared classifier, so the response SHAPES must have one home or a change to them
# has nowhere single to be made. What stays local is the PR object and the reset, which differ.
review_fx()   { check_pr_reviews_json   "$S/reviews.json"   "$@"; rm -f "$S/reviews2.json"; }
comment_fx()  { check_pr_comments_json  "$S/comments.json"  "$@"; }
reaction_fx() { check_pr_reactions_json "$S/reactions.json" "$@"; }
activity_fx() { check_pr_activity_json  "$S/activity.json"  "$@"; }
called()      { check_pr_called "$S/calls" "$1"; }
# reset_fx — every surface back to "nothing here", with the anchor dating this head. Needed because
# the guard now reads THREE signal surfaces: a fixture left over from a previous scenario would
# otherwise leak a signal into the next one.
reset_fx() {
  rm -f "$S/reviews2.json" "$S/comments2.json" "$S/reactions2.json" "$S/calls"
  printf '[]\n' > "$S/reviews.json"
  printf '[]\n' > "$S/comments.json"
  printf '[]\n' > "$S/reactions.json"
  pr_fx
  activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"
}
# The reviewer-declaration tri-state lives in check-lib.sh too; both suites pin the same three.
declare_bots() { check_declare_bots   "$REPO" "$1"; }
undeclare()    { check_undeclare_bots "$REPO" "$GHOME"; }

# g <args...> : run the guard as the driving agent would — from $REPO, throwaway HOME, stub gh.
# ONE home for the environment so a new STUB_* knob is wired in a single place; the two wrappers
# below differ only in what they do with stderr, and the redirect composes onto this subshell.
_g() {
  ( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
    STUB_AUTH_FAIL="${STUB_AUTH_FAIL:-0}" STUB_FAIL_PR="${STUB_FAIL_PR:-0}" \
    STUB_FAIL_REVIEWS="${STUB_FAIL_REVIEWS:-0}" STUB_FAIL_COMMENTS="${STUB_FAIL_COMMENTS:-0}" \
    STUB_FAIL_REACTIONS="${STUB_FAIL_REACTIONS:-0}" STUB_FAIL_ACTIVITY="${STUB_FAIL_ACTIVITY:-0}" \
    STUB_EMPTY_ACTIVITY="${STUB_EMPTY_ACTIVITY:-0}" \
    STUB_EMPTY_REVIEWS="${STUB_EMPTY_REVIEWS:-0}" STUB_EMPTY_COMMENTS="${STUB_EMPTY_COMMENTS:-0}" \
    STUB_EMPTY_REACTIONS="${STUB_EMPTY_REACTIONS:-0}" \
    bash "$PR" "$@" )
}
g() { OUT="${ _g "$@" 2>&1; }"; RC_=$?; }
# gout : stdout ONLY (the witnessed SHA contract) — stderr is diagnostics and must not pollute it.
gout() { OUT="${ _g "$@" 2>/dev/null; }"; RC_=$?; }

# ============================ usage / dispatch ============================
g -h;      yes "$RC_" "-h exits 0";  has "$OUT" "the pre-arm review guard" "-h prints the usage header"
g;         eq "$RC_" "2" "no subcommand exits 2"
g bogus;   eq "$RC_" "2" "unknown subcommand exits 2"
has "$OUT" "unknown subcommand 'bogus'" "unknown subcommand names itself"
g gate --bogus; eq "$RC_" "2" "unknown option exits 2"
g gate;    eq "$RC_" "2" "gate without --pr exits 2 (never permissive by default)"
has "$OUT" "requires --pr" "the missing --pr is named"
g gate --pr;      eq "$RC_" "2" "--pr without a value exits 2"
g gate --pr abc;  eq "$RC_" "2" "--pr with a non-number exits 2"
g gate --pr 0;    eq "$RC_" "2" "--pr 0 is rejected"
g gate --pr -3;   eq "$RC_" "2" "--pr with a negative number is rejected"

# ============================ the declaration tri-state ============================
# The whole point of #134: "no reviewer" and "undeclared" must never be the same answer.
declare_bots '["chatgpt-codex-connector"]'; pr_fx; review_fx
undeclare
g gate --pr 7
eq "$RC_" "17" "UNDECLARED [reviewers] bots -> 17 (fail closed; cannot know if a reviewer is coming)"
has "$OUT" "declares no '[reviewers] bots'" "17 explains what is missing"
has "$OUT" "bots = []" "17 names the escape hatch for a repo with no reviewer"

declare_bots '[]'; pr_fx; review_fx
gout gate --pr 7
eq "$RC_" "0" "bots = [] (explicitly NO async reviewer) -> 0, unattended arming preserved"
eq "$OUT" "$HEAD_SHA" "bots = [] still emits the witnessed head SHA for --match-head-commit"

printf '%s\n' '[reviewers]' 'bots = "not-an-array"' > "$REPO/agents.toml"
g gate --pr 7
eq "$RC_" "18" "malformed [reviewers] bots -> 18 (a CONFIG remedy, not 20's retry, nor the [] disable)"
has "$OUT" "must be an array" "18 surfaces the reader's specific diagnosis"
has "$OUT" "fix agents.toml" "18 names the remedy"

# --- the fail-open family: a declaration that READS as `[]` but is not one ---------------------
# All three of these once returned 0 and armed auto-merge with a reviewer still to come — the one
# direction this module must never be wrong in — because the manifest reader is line-based and
# `adb_toml_array` yields zero elements for each, exactly as it does for a real `bots = []`.
pr_fx; review_fx    # no review from anyone

# A MULTI-LINE array is valid TOML and idiomatic. `adb_toml_get` returns just `[`.
printf '%s\n' '[reviewers]' 'bots = [' '  "chatgpt-codex-connector",' ']' > "$REPO/agents.toml"
g gate --pr 7
eq "$RC_" "18" "a multi-line bots array is malformed, NOT the [] disable (fail-open regression)"
has "$OUT" "not closed on one line" "the multi-line array is named as the problem"

# A WRAPPED array silently drops every element after the first line.
printf '%s\n' '[reviewers]' 'bots = ["chatgpt-codex-connector",' '        "gemini-code-assist[bot]"]' > "$REPO/agents.toml"
g gate --pr 7
eq "$RC_" "18" "a wrapped bots array is malformed rather than silently truncated"

# An array that is not literally empty but yields nothing usable.
for decl in '[""]' '["   "]' '["[bot]"]'; do
  declare_bots "$decl"
  g gate --pr 7
  eq "$RC_" "18" "bots = $decl is malformed, not the [] disable"
done

# ...and the control: a REAL `[]` still arms. If this ever fails, the checks above are too broad.
declare_bots '[]'
gout gate --pr 7
eq "$RC_" "0" "a genuine bots = [] still arms (the fixes above did not over-reject)"
eq "$OUT" "$HEAD_SHA" "the genuine [] case still emits the head SHA"

# ============================ identity matching ============================
# The REST/GraphQL spelling split. The match is ASYMMETRIC (#173, superseding #176): the API login is
# normalized TOWARD the declaration and never the reverse, so a bare declaration accepts either
# spelling while a `[bot]` declaration accepts only the suffixed one.
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
gout gate --pr 7
eq "$RC_" "0" "bare login declared + REST '[bot]' login observed -> matched"
eq "$OUT" "$HEAD_SHA" "a satisfied gate prints ONLY the head SHA on stdout"

# THE FAIL-OPEN THIS REPLACED. Stripping `[bot]` from the DECLARATION as well as from the API login
# meant `bots = ["foo[bot]"]` was satisfied by a HUMAN account literally named `foo`. Not
# theoretical: `gh api users/gemini-code-assist` returns a real User account (id 200291788), so the
# collision space is populated by exactly the kind of account that reviews pull requests. A declared
# App must never be satisfied by the human who happens to hold the un-suffixed login.
declare_bots '["chatgpt-codex-connector[bot]"]'
review_fx "chatgpt-codex-connector" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "a HUMAN login does not satisfy a '[bot]'-suffixed declaration (the #176 fail-open)"

# ...while the suffixed declaration still matches the spelling REST actually reports, so declaring
# the strict form is not a way to wedge the guard forever.
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "a '[bot]'-suffixed declaration matches the REST '[bot]' login"

# A doubled suffix must not satisfy the strict form through the same one-suffix rule it exists to
# deny — which is why the suffix is APPENDED to a bare declaration rather than stripped from the API
# login. Unreachable from GitHub, but it is the difference between "asymmetric" and "nearly".
review_fx "chatgpt-codex-connector[bot][bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "a DOUBLED '[bot]' suffix does not satisfy a '[bot]' declaration"

declare_bots '["Chatgpt-Codex-Connector"]'
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "login comparison is case-insensitive"

# A DIFFERENT bot must not satisfy the declared reviewer — the guard is an allowlist, not a
# "some bot spoke" heuristic.
declare_bots '["chatgpt-codex-connector"]'
review_fx "dependabot[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "an UNRELATED bot's review does not satisfy the declared reviewer"
has "$OUT" "awaiting review from: chatgpt-codex-connector" "16 names who is still pending"

# ============================ the head SHA ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx --sha "$HEAD_SHA"
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$OLD_SHA"
g gate --pr 7
eq "$RC_" "16" "a review of an EARLIER commit does not satisfy the current head (live: PR #145)"

review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$OLD_SHA" \
          "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "a stale review PLUS a current one is satisfied"

# ============================ review states ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx
# APPROVED is the ONLY review state that satisfies this guard.
#
# THIS TEST USED TO ASSERT THE OPPOSITE FOR `COMMENTED`, AND ITS STATED PREMISE WAS FACTUALLY WRONG
# (#167 §2). The old comment argued that COMMENTED "is what the Codex connector posts even on a
# clean pass", so holding out for an APPROVED would deadlock the guard permanently. It does not:
# on a clean pass the connector posts NO REVIEW OBJECT AT ALL — only a `+1` reaction (PRs
# #53/#54/#66/#83/#88, live). The deadlock the old rule was defending against never existed, and
# the branch it justified let a reviewer put actionable findings in a review BODY, create no inline
# threads, and have this guard call it satisfied — with `required_approving_review_count: 0` and
# `required_conversation_resolution` unable to block on a thread that does not exist, nothing else
# would have caught it. Raised by the codex reviewer on PR #146; folded into #167 because the fix
# is the same one rule.
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "review state APPROVED counts as a satisfied review"

# COMMENTED is now `attention` (21): the reviewer HAS spoken and is NOT satisfied.
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "21" "COMMENTED is 'review complete, attention required' (21), NOT a satisfied review"
has "$OUT" "attention required" "21 says the reviewer spoke and is not satisfied"
has "$OUT" "read the review body" "21 points at where the findings actually are"
gout gate --pr 7
eq "$OUT" "" "21 prints NO head SHA — printing it is what authorizes the arm"
for st in PENDING DISMISSED; do
  review_fx "chatgpt-codex-connector[bot]" "$st" "$HEAD_SHA"
  g gate --pr 7
  eq "$RC_" "16" "review state $st does NOT count as reviewed"
done

# --- CHANGES_REQUESTED is a REJECTION, not a "the reviewer has spoken" pass -------------------
# Reported by the reviewer on this module's own PR (#146). "Submitted" is not "satisfied", and
# nothing else catches the difference: this repo's branch protection carries
# `required_approving_review_count: 0` (verified live), so GitHub merges a PR whose only review
# says do-not-merge, and required_conversation_resolution gates on threads, not on the verdict.
review_fx "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "19" "CHANGES_REQUESTED is a rejection (19), never a satisfied review"
has "$OUT" "changes requested by: chatgpt-codex-connector" "19 names who rejected it"
has "$OUT" "address the feedback and push" "19 names the remedy, which differs from 16's 'wait'"

# A standing rejection OUTRANKS any other review the same reviewer left on the same commit —
# in either order. "Any accepted state wins" would let an earlier COMMENTED cancel a later
# CHANGES_REQUESTED, which is the fail-open in a different disguise.
review_fx "chatgpt-codex-connector[bot]" "COMMENTED"         "$HEAD_SHA" \
          "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "19" "COMMENTED then CHANGES_REQUESTED on one commit -> rejected"
review_fx "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA" \
          "chatgpt-codex-connector[bot]" "COMMENTED"         "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "19" "CHANGES_REQUESTED then COMMENTED on one commit -> still rejected"

# ...but a rejection of an EARLIER commit does not block the current one: pushing a fix moves the
# head, which is exactly how a 19 is meant to clear.
review_fx "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$OLD_SHA" \
          "chatgpt-codex-connector[bot]" "APPROVED"          "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "a rejection of an EARLIER commit does not block the reviewed current head"

# A rejection is reported ahead of a merely-missing review: it names work that already exists.
declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'
review_fx "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "19" "a rejection outranks a pending reviewer in the reported verdict"
declare_bots '["chatgpt-codex-connector"]'
# An unrecognized state is indeterminate, and indeterminate is NEVER "reviewed" and never a
# silent 16 either: a future GitHub state meaning "reviewed" must surface, not wedge the guard.
review_fx "chatgpt-codex-connector[bot]" "SOME_NEW_STATE" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "20" "an unrecognized review state -> 20 (fail closed, and it is reported)"
has "$OUT" "unrecognized review state 'SOME_NEW_STATE'" "the unknown state is named"
# ...AND AN ACCEPTED REVIEW NO LONGER OUTWEIGHS IT. This assertion is REVERSED by #167 §8 ("every
# unreadable path still fails closed"), and the reversal is the point rather than a side effect:
# `unknown` now outranks `clean` in the classifier's order, so a state nobody could interpret can
# never be outvoted into a merge authorization by a second signal that happened to look clean. The
# old rule was the one place a fresh unrecognized state was silently discarded — and an
# unrecognized state is exactly what a future GitHub review verdict arrives as.
review_fx "chatgpt-codex-connector[bot]" "SOME_NEW_STATE" "$HEAD_SHA" \
          "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "20" "an UNKNOWN state is not outweighed by an accepted review (#167: unknown > clean)"
gout gate --pr 7
eq "$OUT" "" "the unclassifiable case prints NO head SHA"

# ============ THE THREE SURFACES: the wedge #167 exists to remove ============
# This guard read ONLY `pulls/N/reviews`, and both of the connector's other output shapes were
# therefore invisible to it:
#
#   clean pass (lightweight mode) -> a `+1` reaction, NO review object   -> 16 forever
#   any result  (task mode)       -> ONE issue comment, NO review object -> 16 on EVERY PR
#
# The second is the wider one: a repo that gains a Codex Cloud environment silently loses unattended
# arming entirely, disabled by a vendor-side setting nobody in the repo changed. PR #184 reproduced
# the first end-to-end (a `+1` at 21:33:47Z, zero reviews; `pr-watch observe` said clean, this guard
# said 16, merged by hand).
reset_fx; declare_bots '["chatgpt-codex-connector"]'

# #167'S HEADLINE ACCEPTANCE CRITERION. A `+1` newer than this head's arrival is a clean pass.
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
gout gate --pr 7
eq "$RC_" "0" "#167: a fresh '+1' with NO review object -> 0 (was 16 forever)"
eq "$OUT" "$HEAD_SHA" "#167: the reaction path still emits the witnessed head SHA"

# ...and the REST spelling of the same App satisfies a bare declaration, on this surface too.
reset_fx; reaction_fx "chatgpt-codex-connector[bot]" "+1" "$AFTER_AT"
gout gate --pr 7;  eq "$RC_" "0" "#167: a '[bot]'-suffixed reaction login matches a bare declaration"

# A NON-`+1` REACTION IS NOT A PASS. The connector's contract names 👍 specifically; anything else
# is somebody reacting to the PR, and reactions are publicly writable.
reset_fx; reaction_fx "chatgpt-codex-connector" "heart" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "16" "#167: a non-'+1' reaction is not a clean signal"

# ...and neither is an UNDECLARED account's `+1`. Reactions being publicly writable is exactly why
# the identity check has to hold on this surface: without it, anyone could arm a merge.
reset_fx; reaction_fx "some-passerby" "+1" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "16" "#167: a '+1' from an UNDECLARED account never arms the merge"

# #167 §3's CORRECTED CRITERION, and the one the issue explicitly says must NOT be implemented as
# originally written. A task-mode issue comment is the FINDINGS shape — PR #178's sole Codex comment
# reported unresolved selfcheck warnings — so mapping it to 0 would auto-merge code the reviewer had
# just flagged. It moves the guard off 16 (the reviewer HAS spoken) without authorizing the arm.
reset_fx; comment_fx "chatgpt-codex-connector[bot]" "$AFTER_AT"
g gate --pr 7
eq "$RC_" "21" "#167 §3: a fresh task-mode COMMENT -> 21 attention, NOT 0 and NOT 16"
has "$OUT" "attention required" "21 names the outcome"
gout gate --pr 7
eq "$OUT" "" "#167 §3: the comment path prints NO head SHA — it must not authorize an arm"

# A COMMENT OUTRANKS A `+1` from the same reviewer: it has something to say about this head.
reset_fx
comment_fx  "chatgpt-codex-connector[bot]" "$AFTER_AT"
reaction_fx "chatgpt-codex-connector"      "+1" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "21" "#167: a fresh comment outranks a fresh '+1' (attention > clean)"

# A REVIEW AT THE HEAD OUTRANKS A REACTION, and a rejection outranks everything.
reset_fx
review_fx   "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
reaction_fx "chatgpt-codex-connector"      "+1" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "19" "#167: a rejection at the head outranks a fresh '+1'"

# ---- STALENESS ON THE ARMING PATH (#175/D19), which is where it matters most --------------------
# A reaction carries no commit, so a `+1` left on an EARLIER head still sits there after new commits
# land. Accepting it would arm a merge on code nobody reviewed — the one direction this guard must
# never be wrong in. The lower bound is the SERVER's record of when the ref became this SHA.
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$BEFORE_AT"
g gate --pr 7
eq "$RC_" "16" "#175: a '+1' PREDATING this head's arrival does not arm the merge"
has "$OUT" "predates this head" "#175: says WHY the reaction was rejected"
gout gate --pr 7;  eq "$OUT" "" "#175: a stale '+1' prints no head SHA"

# The head-COMMIT date is client-supplied and must never be consulted. Proven as a NEGATIVE: the
# endpoint is never addressed at all.
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
gout gate --pr 7
if called '/commits/'; then bad "#175: the arming guard must never read the head commit's date"; else ok; fi

# THE SAME SHA ARRIVING ON ANOTHER REF must not date this one — the case that rules out a
# check-suite anchor, which is scoped to the SHA rather than to the ref.
reset_fx
activity_fx "$HEAD_SHA" "refs/heads/somewhere-else" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF"      "$BEFORE_AT"
reaction_fx "chatgpt-codex-connector" "+1" "$ARRIVED_AT"
gout gate --pr 7;  eq "$RC_" "0" "#175: this ref's OWN record dates it, even when a newer one names another ref"

# A REVERSE FORCE-PUSH (A -> B -> A) leaves two records for this SHA; only the LATER one says when
# it is A *now*.
reset_fx
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "chatgpt-codex-connector" "+1" "$ARRIVED_AT"
g gate --pr 7;  eq "$RC_" "16" "#175: the LATEST record decides, so a reverse force-push is caught"

# AN UNESTABLISHED ANCHOR IS 16, NEVER 0 — an unproven signal is not a pass. Distinct from 20:
# nothing failed to read, there is simply no record putting this SHA on this ref.
reset_fx; activity_fx    # a well-formed EMPTY list
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "16" "#175: no activity record for this head -> 16, never an arm"
reset_fx; activity_fx
comment_fx "chatgpt-codex-connector[bot]" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "16" "#175: the comment path degrades the same way — one rule over both"

# A DELETED HEAD REPOSITORY is a real state, not a broken response.
reset_fx; pr_fx --head-slug ""
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "16" "#175: a deleted head repository -> 16"
has "$OUT" "deleted fork" "#175: names the likely cause"

# A COMMIT-SCOPED REVIEW NEEDS NO ANCHOR, so an unestablished one must NOT suppress it. This is the
# per-signal anchor state the fold depends on: erasing it globally would mask real evidence.
reset_fx; activity_fx
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
gout gate --pr 7;  eq "$RC_" "0" "an APPROVED review is unaffected by an unestablished anchor"

# ---- THE ANCHOR READ IS CONDITIONAL (cost) -----------------------------------------------------
# It is a FIFTH request, and a PR whose reviewer has said nothing must not pay for it.
reset_fx
gout gate --pr 7
if called '/activity'; then bad "the ref-activity read must not happen with no date-scoped signal"; else ok; fi
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
gout gate --pr 7
if called '/activity'; then ok; else bad "the ref-activity read MUST happen when a '+1' needs dating"; fi

# ---- every NEW surface fails closed ------------------------------------------------------------
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
STUB_FAIL_COMMENTS=1  g gate --pr 7; eq "$RC_" "20" "a failed issue-comments read -> 20"; STUB_FAIL_COMMENTS=0
STUB_FAIL_REACTIONS=1 g gate --pr 7; eq "$RC_" "20" "a failed reactions read -> 20"; STUB_FAIL_REACTIONS=0
STUB_FAIL_ACTIVITY=1  g gate --pr 7; eq "$RC_" "20" "a failed ref-activity read -> 20 (never an arm)"; STUB_FAIL_ACTIVITY=0
STUB_EMPTY_ACTIVITY=1 g gate --pr 7; eq "$RC_" "20" "an EMPTY activity body is not an empty list -> 20"; STUB_EMPTY_ACTIVITY=0

# AN EMPTY RESPONSE BODY ON A SIGNAL SURFACE IS NOT AN EMPTY LIST — and getting this wrong ARMED AN
# UNREVIEWED MERGE. `adb_paginated_list` tested the PARSED value, but `printf '' | jq -s '[.[][]]'`
# emits `[]`, so the check could never fire and a 200-with-no-document read as "that surface carried
# no records". Harmless while the gate read one surface (no reviews -> withhold anyway); a false 0
# once three surfaces are folded, because the emptied surface's evidence simply vanishes and
# whatever is left decides. The scenario below is the reproduction, and it must never return 0.
reset_fx; declare_bots '["chatgpt-codex-connector"]'
review_fx   "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7; eq "$RC_" "19" "control: the rejection is seen when the reviews surface reads normally"
STUB_EMPTY_REVIEWS=1 g gate --pr 7
eq "$RC_" "20" "an EMPTY reviews body -> 20; it must NOT let a fresh '+1' arm over a hidden rejection"
STUB_EMPTY_REVIEWS=1 gout gate --pr 7
eq "$OUT" "" "...and prints NO head SHA — printing it is what authorizes the arm"
STUB_EMPTY_REVIEWS=0
# The same hole on the other two surfaces, where an emptied read hides an ATTENTION signal instead.
reset_fx; comment_fx "chatgpt-codex-connector[bot]" "$AFTER_AT"
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7; eq "$RC_" "21" "control: the task-mode comment is seen when the comments surface reads normally"
STUB_EMPTY_COMMENTS=1 g gate --pr 7
eq "$RC_" "20" "an EMPTY comments body -> 20; it must not let a '+1' arm over a hidden comment"
STUB_EMPTY_COMMENTS=0
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
STUB_EMPTY_REACTIONS=1 g gate --pr 7
eq "$RC_" "20" "an EMPTY reactions body -> 20, not 'no reaction here'"
STUB_EMPTY_REACTIONS=0
for bad_json in 'not json at all' '{"message":"Not Found"}'; do
  reset_fx; printf '%s\n' "$bad_json" > "$S/comments.json"
  g gate --pr 7; eq "$RC_" "20" "an unparseable/wrapped comments response -> 20 ($bad_json)"
  reset_fx; printf '%s\n' "$bad_json" > "$S/reactions.json"
  g gate --pr 7; eq "$RC_" "20" "an unparseable/wrapped reactions response -> 20 ($bad_json)"
done
# A NON-ARRAY DOCUMENT ON A SIGNAL SURFACE IS NOT AN EMPTY LIST — the empty-body bug's twin, and it
# reaches the same false arm. Iterating a non-array does not fail: `{}` flattens to `[]`, i.e.
# exactly "this surface carried no records". So a malformed reviews document discards a standing
# rejection and lets a fresh `+1` fold to `clean`. Reported by the codex reviewer on PR #219.
reset_fx; declare_bots '["chatgpt-codex-connector"]'
review_fx   "chatgpt-codex-connector[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7; eq "$RC_" "19" "control: the rejection is seen when the reviews document is an array"
for doc in '{}' '{"a":[]}' '{"message":"Not Found"}'; do
  reset_fx
  reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
  printf '%s\n' "$doc" > "$S/reviews.json"
  g gate --pr 7
  eq "$RC_" "20" "a NON-ARRAY reviews document -> 20, never 'no reviews here' ($doc)"
  gout gate --pr 7
  eq "$OUT" "" "...and prints NO head SHA ($doc)"
done
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
printf '%s\n' '{}' > "$S/comments.json"
g gate --pr 7; eq "$RC_" "20" "a NON-ARRAY comments document -> 20"
reset_fx; printf '%s\n' '{}' > "$S/reactions.json"
g gate --pr 7; eq "$RC_" "20" "a NON-ARRAY reactions document -> 20"

# A REVIEW THAT CANNOT BE TIED TO A COMMIT is unknown, not absent — end to end, on the arming path.
# The commit filter used to run before the reviewer match, so this rejection vanished and the `+1`
# armed the merge.
reset_fx
printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"CHANGES_REQUESTED"}]' > "$S/reviews.json"
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7
eq "$RC_" "20" "a declared reviewer review with NO commit_id -> 20, not outvoted by a fresh '+1'"
gout gate --pr 7
eq "$OUT" "" "...and prints NO head SHA"
has "${ _g gate --pr 7 2>&1; }" "no usable commit_id" "the undatable review is named"

# AN IMPOSSIBLE TIMESTAMP must not read as fresh. `9999-99-99T99:99:99Z` passes a character-class
# glob and sorts above every real anchor INCLUDING the no-anchor sentinel, so it defeated the
# fail-closed default outright.
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "9999-99-99T99:99:99Z"
g gate --pr 7; eq "$RC_" "20" "an out-of-range timestamp -> 20, never a clean pass"
gout gate --pr 7; eq "$OUT" "" "...and prints NO head SHA"

# The activity endpoint answering a NON-ARRAY must surface rather than iterate to zero matches and
# read as a clean "no anchor".
reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
printf '%s\n' '{"message":"Not Found"}' > "$S/activity.json"
g gate --pr 7; eq "$RC_" "20" "a non-array activity response -> 20, not a silent 'no anchor'"

# ---- object shapes: a record that cannot be DATED is not a record that says nothing -------------
# A declared reviewer's signal with no `created_at` is a malformed response. Treating it as absent
# would silently drop a reviewer's comment — and on the clean path that is a false pass.
reset_fx
printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector"},"content":"+1"}]' > "$S/reactions.json"
g gate --pr 7; eq "$RC_" "20" "a '+1' with NO timestamp -> 20 (undatable, not absent)"
reset_fx
printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector"},"body":"x"}]' > "$S/comments.json"
g gate --pr 7; eq "$RC_" "20" "a comment with NO timestamp -> 20"
# An unorderable FORMAT is rejected rather than normalized: a lexicographic compare is only a
# chronological one while every operand is the same width, precision and zone.
for ts in "2026-07-25T04:45:23-04:00" "2026-07-25T04:45:23.500Z" "not-a-date"; do
  reset_fx; reaction_fx "chatgpt-codex-connector" "+1" "$ts"
  g gate --pr 7; eq "$RC_" "20" "an unorderable timestamp format -> 20 ($ts)"
done
# A record from an UNDECLARED login with a broken shape is ignored, not fatal — only the declared
# reviewers' evidence is classified, so a human's malformed comment cannot wedge the guard.
reset_fx
printf '%s\n' '[{"user":{"login":"a-human"},"body":"x"}]' > "$S/comments.json"
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
gout gate --pr 7; eq "$RC_" "0" "an UNDECLARED login's undatable comment is ignored, not fatal"

# ---- pagination on the two new surfaces --------------------------------------------------------
# A busy PR pushes the bot's reaction off page 1 behind human reactions; a missed `+1` wedges the
# guard at 16 on a PR that was in fact reviewed clean.
reset_fx
printf '%s\n' '[{"user":{"login":"a-human"},"content":"heart","created_at":"'"$AFTER_AT"'"}]' > "$S/reactions.json"
printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector"},"content":"+1","created_at":"'"$AFTER_AT"'"}]' > "$S/reactions2.json"
gout gate --pr 7;  eq "$RC_" "0" "a '+1' on the SECOND page is found (paginated read)"
reset_fx
printf '%s\n' '[{"user":{"login":"a-human"},"created_at":"'"$AFTER_AT"'"}]' > "$S/comments.json"
printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector"},"created_at":"'"$AFTER_AT"'"}]' > "$S/comments2.json"
g gate --pr 7;  eq "$RC_" "21" "a comment on the SECOND page is found (paginated read)"
reset_fx

# ============================ multiple declared reviewers (ALL, not ANY) ============================
declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "ALL declared reviewers must review — one pending still holds the arm"
has "$OUT" "gemini-code-assist" "the pending reviewer is named, the satisfied one is not"
hasnt "$OUT" "awaiting review from: chatgpt-codex-connector" "a satisfied reviewer is not listed as pending"
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA" \
          "gemini-code-assist[bot]"      "APPROVED"  "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "every declared reviewer reviewed -> 0"

# #185's THIRD ACCEPTANCE CRITERION: this guard's all-must-speak behaviour is UNCHANGED — and it now
# has to hold on the two surfaces it just learned to read, which is where the sibling module's
# pooled aggregation went wrong. A `+1` from one declared bot must not speak for the set.
reset_fx; declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
g gate --pr 7
eq "$RC_" "16" "#185: a fresh '+1' from ONE of two declared reviewers does not arm the merge"
has "$OUT" "gemini-code-assist" "#185: the silent reviewer is named"
gout gate --pr 7;  eq "$OUT" "" "#185: a partial set prints no head SHA"

# ...and the control: both spoke, by DIFFERENT mechanisms, so the set is satisfied.
reset_fx; declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
review_fx   "gemini-code-assist[bot]" "APPROVED" "$HEAD_SHA"
gout gate --pr 7
eq "$RC_" "0" "#185: a '+1' from one and an APPROVED from the other -> 0"
eq "$OUT" "$HEAD_SHA" "#185: the all-clean set emits the witnessed head SHA"

# ATTENTION from one outranks SILENCE from the other: there is something to read now, and reporting
# "still waiting" would bury it. Both withhold the arm, so the ordering is about which remedy the
# operator is handed first.
reset_fx; declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'
comment_fx "chatgpt-codex-connector[bot]" "$AFTER_AT"
g gate --pr 7;  eq "$RC_" "21" "#167: attention from one reviewer outranks another's silence"

# ...and a clean reviewer alongside an UNCLASSIFIABLE one fails closed rather than arming.
reset_fx; declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'
reaction_fx "chatgpt-codex-connector" "+1" "$AFTER_AT"
review_fx   "gemini-code-assist[bot]" "SOME_NEW_STATE" "$HEAD_SHA"
g gate --pr 7;  eq "$RC_" "20" "a clean reviewer alongside an unclassifiable one -> 20, never 0"
reset_fx; declare_bots '["chatgpt-codex-connector"]'

# ============================ pagination ============================
# The satisfying review sits on the SECOND page. Without --paginate (or with a per-page cap) the
# guard would report 16 forever on a busy PR.
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "dependabot[bot]" "APPROVED" "$HEAD_SHA"
jq -c -n --arg sha "$HEAD_SHA" \
  '[{user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},state:"APPROVED",commit_id:$sha}]' \
  > "$S/reviews2.json"
g gate --pr 7
eq "$RC_" "0" "a review on the SECOND page is found (paginated read)"
rm -f "$S/reviews2.json"

# ============================ every unreadable path fails closed ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"

STUB_AUTH_FAIL=1 g gate --pr 7;    eq "$RC_" "20" "unauthenticated gh -> 20"; STUB_AUTH_FAIL=0
STUB_FAIL_PR=1 g gate --pr 7;      eq "$RC_" "20" "a failed PR read -> 20 (never 'not reviewed')"; STUB_FAIL_PR=0
STUB_FAIL_REVIEWS=1 g gate --pr 7; eq "$RC_" "20" "a failed reviews read -> 20"; STUB_FAIL_REVIEWS=0

pr_fx_raw '{"head":{}}';        g gate --pr 7; eq "$RC_" "20" "a PR object with no head SHA -> 20"
pr_fx_raw '{"head":{"sha":null}}'; g gate --pr 7; eq "$RC_" "20" "a null head SHA -> 20"
pr_fx_raw 'not json at all';    g gate --pr 7; eq "$RC_" "20" "an unparseable PR object -> 20"
pr_fx
printf '%s\n' 'not json either' > "$S/reviews.json"
g gate --pr 7; eq "$RC_" "20" "unparseable reviews JSON -> 20"

# ============================ the --pr URL form ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
gout gate --pr "https://github.com/acme/widget/pull/7"
eq "$RC_" "0" "a full PR URL is accepted"
eq "$OUT" "$HEAD_SHA" "the URL form yields the same witnessed SHA"
gout gate --pr "https://github.com/acme/widget/pull/7/files"
eq "$RC_" "0" "a PR sub-page URL is accepted"
g gate --pr "https://github.com/acme/widget/issues/7"
eq "$RC_" "2" "a non-PR URL is rejected rather than guessed at"

# A URL naming a DIFFERENT repository must be refused, not answered. Every read addresses
# repos/{owner}/{repo}, which gh expands from the LOCAL remote, so without this cross-check the
# guard would faithfully report on this repo's #7 while the caller meant another repo's — a
# confidently wrong answer, the one output a guard must never produce.
g gate --pr "https://github.com/other/project/pull/7"
eq "$RC_" "2" "a PR URL naming a different repository is refused"
has "$OUT" "refusing to answer about a different repository" "the repo mismatch is named"

# THE ACCEPTANCE CRITERION OF #173. This module's slug parser handled only `scheme://…`, while
# pr-watch.sh's handled three forms — so a scheme-less URL, an ordinary browser copy-paste, produced
# an EMPTY wanted slug here, skipped the refusal above entirely, answered about THIS repo's #7, and
# printed a head SHA that `/implement-issue` step 10 then armed `gh pr merge --auto` against. The
# stdout assertion is not decoration: printing the SHA is what authorized the arm, so "refuses" has
# to mean "and says nothing a caller could arm on".
for u in "github.com/other/project/pull/7" "other/project/pull/7"; do
  g gate --pr "$u"
  eq "$RC_" "2" "a scheme-less URL naming a different repository is refused ($u)"
  gout gate --pr "$u"
  eq "$OUT" "" "a refused cross-repo argument prints NO head SHA ($u)"
done

# An argument that is neither a bare number nor a URL naming a repository cannot be answered at all:
# taking the digits after `pull/` alone reduces these to `7`, which would then be answered about
# whichever repository the reads happen to address — the same wrong answer from a different input.
for u in "pull/7" "https://github.com/pull/7"; do
  g gate --pr "$u"
  eq "$RC_" "2" "a PR-ish argument that names no repository is rejected ($u)"
done

# jq emits `.head.sha` BEFORE it evaluates the slug expression, so a PR object whose `base` has an
# unexpected shape makes jq error only partway: the head SHA still arrives and the slug does not.
# Discarding jq's status there would set `head`, leave `gotslug` empty, and skip the cross-repo
# refusal below it — answering confidently about the wrong repository.
pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"},"base":"acme/widget"}'
g gate --pr "https://github.com/other/project/pull/7"
eq "$RC_" "20" "a PR object that breaks jq PARTWAY fails closed (does not skip the repo check)"

# MALFORMED OR ABSENT METADATA IS UNREADABLE, NOT "NOTHING TO COMPARE". The old check was guarded on
# `[ -n "$gotslug" ]`, so it silently VANISHED on exactly these responses and a foreign URL was then
# answered about this repo. Unreadable outranks mismatched: the foreign-URL cases below must report
# 20 rather than 2, and none of them may print a SHA.
pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"}}'
g gate --pr 7;    eq "$RC_" "20" "a PR with no base repository -> 20, never classified"
has "$OUT" "unidentifiable repository" "the missing base repo is named"
g gate --pr "https://github.com/other/project/pull/7"
eq "$RC_" "20" "a missing base repo cannot silently skip the cross-repo refusal"
pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"},"base":{"repo":null}}'
g gate --pr 7;    eq "$RC_" "20" "an explicitly null base repo -> 20"
# A slug that arrives but is not an owner/repo PAIR is a broken response, and must be reported as
# one — comparing it would call a malformed read "a different repository".
for v in '"acme"' '"acme/widget/extra"' '"/widget"' '"acme/"'; do
  pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"},"base":{"repo":{"full_name":'"$v"'}}}'
  g gate --pr 7
  eq "$RC_" "20" "a base repo slug of $v is unreadable, not a repo mismatch"
done
pr_fx

# A BARE NUMBER NAMES NO REPOSITORY, so nothing in the argument can catch a redirected read. Every
# read addresses `repos/{owner}/{repo}`, which gh expands — and the documented GH_REPO variable
# overrides that expansion (verified live: `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers
# `cli/cli` from a directory that is not a repository at all). The anchor is therefore the CHECKOUT's
# git origin, which no gh variable can move. Simulated here the only way a stub can: the reads answer
# for a repository that is not this checkout's.
pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"},"base":{"repo":{"full_name":"other/project"}}}'
review_fx "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "2" "a bare number whose reads answered for ANOTHER repo is refused (the GH_REPO class)"
has "$OUT" "GH_REPO" "the refusal names the likely cause"
gout gate --pr 7
eq "$OUT" "" "a redirected read prints NO head SHA"
pr_fx

# ============================ workflow drift pins ============================
# The library can be perfectly correct while the workflow never calls it — which is exactly the
# state #134 describes. These pin the wiring, in the SOURCE (the agent skills are generated).
WFSRC="$ROOT/base/workflows/implement-issue.md"
if grep -q '{{PR_REVIEW_LIB}} gate --pr' "$WFSRC"; then ok; else
  bad "base/workflows/implement-issue.md no longer calls {{PR_REVIEW_LIB}} gate before arming auto-merge"
fi
if grep -q -- '--match-head-commit "\$HEAD_SHA"' "$WFSRC"; then ok; else
  bad "base/workflows/implement-issue.md arms auto-merge without --match-head-commit (head-SHA race)"
fi
# The review gate must sit INSIDE automerge-ok's 0 arm: reachable only when the checks guard has
# already passed, and never bypassed by an early `gh pr merge`.
if awk '/^\{\{REPO_SETTINGS_LIB\}\} automerge-ok/,/^esac/' "$WFSRC" | grep -q 'PR_REVIEW_LIB'; then ok; else
  bad "the review gate is not inside the automerge-ok decision block in implement-issue.md"
fi
if grep -q 'gh pr merge "\$PR" --auto' "$WFSRC"; then
  if [ "$(grep -c 'gh pr merge "\$PR" --auto' "$WFSRC")" = "1" ]; then ok; else
    bad "implement-issue.md has more than one arming call — one of them may bypass the review gate"
  fi
else
  bad "implement-issue.md no longer arms auto-merge at all"
fi

check_summary "pr-review"
