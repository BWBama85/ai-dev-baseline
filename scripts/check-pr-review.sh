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
#
# What genuinely CANNOT be tested here (needs a live run): that GitHub delivers the App's review,
# that `--match-head-commit` actually rejects a moved head, and real 403/404 bodies.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pr-review.sh   (exit 0 = all pass, 1 = a failure)

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
# A git repo so the helper's repo-root resolution is deterministically $REPO, whatever ambient
# git repo sits above the temp dir.
#
# WITH AN `origin` REMOTE, and it is load-bearing rather than set dressing (#173): the guard anchors
# every read to the checkout's git origin, because a bare `--pr 7` names no repository and the
# documented `GH_REPO` variable silently redirects gh's `repos/{owner}/{repo}` expansion. It must
# agree with the `base.repo.full_name` the PR fixture reports, or every scenario below fails closed.
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ============================ the recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the reviews URL is
# ALSO a `repos/*` URL, so a case arm that matches the general shape first swallows the specific
# one and every scenario silently reads the wrong fixture. Most specific first, always.
cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Answers the two reads the guard makes, from $S fixtures. Knobs:
#   STUB_AUTH_FAIL=1     -> `gh auth status` fails (unauthenticated)
#   STUB_FAIL_PR=1       -> the PR read fails
#   STUB_FAIL_REVIEWS=1  -> the reviews read fails
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
case "$url" in
  */reviews*)
    [ "${STUB_FAIL_REVIEWS:-0}" = "1" ] && exit 1
    # --paginate concatenates ONE JSON DOCUMENT PER PAGE; reviews2.json exists only in the
    # pagination scenario, so the default case still emits a single well-formed page.
    cat "$S/reviews.json"
    [ -f "$S/reviews2.json" ] && cat "$S/reviews2.json"
    exit 0 ;;
  */pulls/*)
    [ "${STUB_FAIL_PR:-0}" = "1" ] && exit 1
    cat "$S/pr.json"; exit 0 ;;
  repos/*)
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$SBIN/gh"

# ---- fixtures --------------------------------------------------------------------------------
pr_fx()      { printf '{"head":{"sha":"%s"},"base":{"repo":{"full_name":"acme/widget"}}}\n' "${1:-$HEAD_SHA}" > "$S/pr.json"; }
pr_fx_raw()  { printf '%s\n' "$1" > "$S/pr.json"; }
# review_fx <login> <state> <sha> [...] — one review per triple.
review_fx() {
  rm -f "$S/reviews2.json"
  : > "$S/reviews.json"
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg st "$2" --arg sha "$3" \
            '. + [{user:{login:$l,type:"Bot"},state:$st,commit_id:$sha}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$S/reviews.json"
}
declare_bots() { printf '%s\n' '[reviewers]' "bots = $1" > "$REPO/agents.toml"; }
undeclare()    { rm -f "$REPO/agents.toml"; rm -f "$GHOME/.config/ai-dev-baseline/agents.toml"; }

# g <args...> : run the guard as the driving agent would — from $REPO, throwaway HOME, stub gh.
g() {
  OUT="$( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
          STUB_AUTH_FAIL="${STUB_AUTH_FAIL:-0}" STUB_FAIL_PR="${STUB_FAIL_PR:-0}" \
          STUB_FAIL_REVIEWS="${STUB_FAIL_REVIEWS:-0}" \
          bash "$PR" "$@" 2>&1 )"; RC_=$?
}
# gout : stdout ONLY (the witnessed SHA contract) — stderr is diagnostics and must not pollute it.
gout() {
  OUT="$( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
          bash "$PR" "$@" 2>/dev/null )"; RC_=$?
}

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
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
gout gate --pr 7
eq "$RC_" "0" "bare login declared + REST '[bot]' login observed -> matched"
eq "$OUT" "$HEAD_SHA" "a satisfied gate prints ONLY the head SHA on stdout"

# THE FAIL-OPEN THIS REPLACED. Stripping `[bot]` from the DECLARATION as well as from the API login
# meant `bots = ["foo[bot]"]` was satisfied by a HUMAN account literally named `foo`. Not
# theoretical: `gh api users/gemini-code-assist` returns a real User account (id 200291788), so the
# collision space is populated by exactly the kind of account that reviews pull requests. A declared
# App must never be satisfied by the human who happens to hold the un-suffixed login.
declare_bots '["chatgpt-codex-connector[bot]"]'
review_fx "chatgpt-codex-connector" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "a HUMAN login does not satisfy a '[bot]'-suffixed declaration (the #176 fail-open)"

# ...while the suffixed declaration still matches the spelling REST actually reports, so declaring
# the strict form is not a way to wedge the guard forever.
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "a '[bot]'-suffixed declaration matches the REST '[bot]' login"

# A doubled suffix must not satisfy the strict form through the same one-suffix rule it exists to
# deny — which is why the suffix is APPENDED to a bare declaration rather than stripped from the API
# login. Unreachable from GitHub, but it is the difference between "asymmetric" and "nearly".
review_fx "chatgpt-codex-connector[bot][bot]" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "a DOUBLED '[bot]' suffix does not satisfy a '[bot]' declaration"

declare_bots '["Chatgpt-Codex-Connector"]'
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
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
declare_bots '["chatgpt-codex-connector"]'; pr_fx "$HEAD_SHA"
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$OLD_SHA"
g gate --pr 7
eq "$RC_" "16" "a review of an EARLIER commit does not satisfy the current head (live: PR #145)"

review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$OLD_SHA" \
          "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "a stale review PLUS a current one is satisfied"

# ============================ review states ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx
# APPROVED and COMMENTED are the two "reviewer is satisfied" states. COMMENTED must count: it is
# what the Codex connector posts even on a clean pass, and holding out for an APPROVED that a
# comment-only bot never sends would deadlock the guard permanently. CHANGES_REQUESTED is handled
# below — it is submitted, but it is not satisfied.
for st in APPROVED COMMENTED; do
  review_fx "chatgpt-codex-connector[bot]" "$st" "$HEAD_SHA"
  g gate --pr 7
  eq "$RC_" "0" "review state $st counts as a satisfied review"
done
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
          "chatgpt-codex-connector[bot]" "COMMENTED"         "$HEAD_SHA"
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
# ...but a recognized ACCEPTED review alongside an unknown one is still a pass: the reviewer
# demonstrably spoke about this commit.
review_fx "chatgpt-codex-connector[bot]" "SOME_NEW_STATE" "$HEAD_SHA" \
          "chatgpt-codex-connector[bot]" "APPROVED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "an accepted review outweighs an unknown-state one from the same reviewer"

# ============================ multiple declared reviewers (ALL, not ANY) ============================
declare_bots '["chatgpt-codex-connector", "gemini-code-assist[bot]"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "16" "ALL declared reviewers must review — one pending still holds the arm"
has "$OUT" "gemini-code-assist" "the pending reviewer is named, the satisfied one is not"
hasnt "$OUT" "awaiting review from: chatgpt-codex-connector" "a satisfied reviewer is not listed as pending"
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA" \
          "gemini-code-assist[bot]"      "APPROVED"  "$HEAD_SHA"
g gate --pr 7
eq "$RC_" "0" "every declared reviewer reviewed -> 0"

# ============================ pagination ============================
# The satisfying review sits on the SECOND page. Without --paginate (or with a per-page cap) the
# guard would report 16 forever on a busy PR.
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "dependabot[bot]" "APPROVED" "$HEAD_SHA"
jq -c -n --arg sha "$HEAD_SHA" \
  '[{user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},state:"COMMENTED",commit_id:$sha}]' \
  > "$S/reviews2.json"
g gate --pr 7
eq "$RC_" "0" "a review on the SECOND page is found (paginated read)"
rm -f "$S/reviews2.json"

# ============================ every unreadable path fails closed ============================
declare_bots '["chatgpt-codex-connector"]'; pr_fx
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"

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
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
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
for bad in '"acme"' '"acme/widget/extra"' '"/widget"' '"acme/"'; do
  pr_fx_raw '{"head":{"sha":"'"$HEAD_SHA"'"},"base":{"repo":{"full_name":'"$bad"'}}}'
  g gate --pr 7
  eq "$RC_" "20" "a base repo slug of $bad is unreadable, not a repo mismatch"
done
pr_fx

# A BARE NUMBER NAMES NO REPOSITORY, so nothing in the argument can catch a redirected read. Every
# read addresses `repos/{owner}/{repo}`, which gh expands — and the documented GH_REPO variable
# overrides that expansion (verified live: `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers
# `cli/cli` from a directory that is not a repository at all). The anchor is therefore the CHECKOUT's
# git origin, which no gh variable can move. Simulated here the only way a stub can: the reads answer
# for a repository that is not this checkout's.
pr_fx "$HEAD_SHA" ; printf '%s\n' '{"head":{"sha":"'"$HEAD_SHA"'"},"base":{"repo":{"full_name":"other/project"}}}' > "$S/pr.json"
review_fx "chatgpt-codex-connector[bot]" "COMMENTED" "$HEAD_SHA"
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
