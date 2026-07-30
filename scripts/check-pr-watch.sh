#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the async-reviewer status detector (scripts/lib/pr-watch.sh, #49).
# OFFLINE: no network, no gh auth, no real repo is touched.
#
# The detector has exactly one dangerous direction: reporting `clean` when the declared reviewer
# has NOT passed the current head. Every case below is chosen because it is a way that could
# happen, or a way the detector could wedge and either watch forever or hand off a healthy PR:
#
#   1. STALENESS. A review carries `commit_id`; a REACTION CARRIES NO COMMIT. A `+1` left on an
#      earlier head survives new commits, so reading it naively reports `clean` for code nobody
#      reviewed. The timestamp rule (`+1` must postdate the head commit) is pinned in BOTH
#      directions, including the boundary where they are equal.
#   2. IDENTITY, ASYMMETRICALLY. The same App is spelled two ways depending on which API answered,
#      and a declaration may use either — but the normalization runs ONE WAY ONLY (#173): the API
#      login is normalized toward the declaration, never the reverse. Stripping both sides let a
#      declared `foo[bot]` be satisfied by a HUMAN account named `foo`, and reactions are publicly
#      writable, so on that signal the bar was a login collision and nothing else. Pinned on all
#      THREE signals, because the rule had three inline copies here and one shared predicate has to
#      be proved on each — plus a WRONG bot, which must satisfy none of them.
#   2b. REPOSITORY IDENTITY. Every read addresses `repos/{owner}/{repo}`, so the detector can be
#      pointed at another project by a URL argument naming one, or — when the argument is the bare
#      number `/resolve-pr-threads --watch` passes — by `GH_REPO` redirecting gh's own expansion.
#      Both are refused, and the anchor is the set of repositories the checkout's git remotes name —
#      which no gh variable can move, and which accepts a fork or upstream-only layout.
#   3. THERE ARE THREE SURFACES, AND THEY ARE ORDERED. The connector has two operating modes and
#      the repo does not pick which it gets: WITHOUT a Codex Cloud environment it posts a review
#      object (+ inline threads) for findings and a bare `+1` reaction for a clean pass; WITH one it
#      runs as a task and posts a single ISSUE COMMENT — no review, no threads, no reaction. Both
#      shapes were observed on this repo the same day (PR #166 at 08:01 vs PR #178 at 19:30, after
#      an environment was created). Reading only reviews wedges at `pending` forever on the second.
#      Findings outrank clean; a review at the head outranks a comment.
#   4. NON-SIGNALS. A `PENDING` (unsubmitted draft) or `DISMISSED` review is not the reviewer
#      having spoken, and a review of an OLDER commit is not a review of this one.
#   5. EVERY UNREADABLE PATH -> 20, never `clean`. A failed read must not look like a pass.
#   6. THE BOUND IS A BOUND. `wait` must stop at its deadline, must never sleep past it, must not
#      abandon a watch on one transient error, and must give up rather than poll an endlessly
#      unreadable API forever.
#
# What genuinely CANNOT be tested here (needs a live run): which SHAPE the connector emits, since
# that is decided by vendor-side configuration rather than by anything in the repo — verified live
# here (PRs #53/#54/#66/#83/#88 carry a `+1` with zero reviews; #127/#137/#145/#146/#154/#166 carry
# a review with zero reactions; #178 carries one issue comment with zero reviews and zero
# reactions); that it re-reviews after a push (it does NOT — its triggers are open /
# ready-for-review / an explicit `@codex review`); and GitHub's eventual consistency between the
# endpoints. A stub can prove the PARSING and the DECISION; it can never prove the premise — which
# is exactly why the decision reads all three surfaces instead of the one the vendor documents.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pr-watch.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
PW="$ROOT/scripts/lib/pr-watch.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

REPO="$work/repo"; GHOME="$work/home"; SBIN="$work/sbin"; S="$work/stub"
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$SBIN" "$S"
# A git repo so the helper's repo-root resolution is deterministically $REPO, whatever ambient git
# repo sits above the temp dir.
#
# WITH AN `origin` REMOTE, and it is load-bearing rather than set dressing (#173): the detector
# anchors every read to the checkout's git origin, because a bare `--pr 7` names no repository and
# the documented `GH_REPO` variable silently redirects gh's `repos/{owner}/{repo}` expansion —
# `/resolve-pr-threads --watch` passes exactly that bare form. It must agree with the
# `base.repo.full_name` the PR fixture reports, or every scenario below fails closed.
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CODEX="chatgpt-codex-connector"
# The head commit's date. Every reaction fixture is expressed relative to it so the staleness rule
# is read at a glance rather than by comparing two opaque strings.
COMMIT_AT="2026-07-25T04:42:15Z"
AFTER_AT="2026-07-25T04:45:23Z"    # 3m08s later — the real gap observed on PR #88
BEFORE_AT="2026-07-25T04:40:00Z"

# ============================ the recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the reviews URL is ALSO
# a `repos/*/pulls/*` URL, so an arm matching the general shape first swallows the specific one and
# every scenario silently reads the wrong fixture. Most specific first, always.
#
# It also COUNTS polls (one `pulls/N` read per classification) and prefers a per-poll fixture
# `<name>.<n>.json` when one exists, which is how the `wait` scenarios below make the answer change
# between polls without any network.
cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Knobs:
#   STUB_AUTH_FAIL=1       -> `gh auth status` fails (unauthenticated)
#   STUB_FAIL_PR=1         -> the PR read fails
#   STUB_FAIL_REVIEWS=1    -> the reviews read fails
#   STUB_FAIL_REACTIONS=1  -> the reactions read fails
#   STUB_FAIL_COMMENTS=1   -> the issue-comments read fails
#   STUB_FAIL_COMMIT=1     -> the head-commit read fails
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
# fx <base> : echo the per-poll fixture if present, else the default one. The poll number comes
# from the counter file the `pulls/N` arm below bumps once per classification — NOT from an
# environment variable, which cannot survive between the separate `gh` processes one poll makes.
fx() {
  local n=0
  [ -f "$S/polls" ] && n="$(cat "$S/polls")"
  if [ -f "$S/$1.$n.json" ]; then cat "$S/$1.$n.json"; return 0; fi
  [ -f "$S/$1.json" ] && cat "$S/$1.json"
  return 0
}
case "$url" in
  */reviews*)
    [ "${STUB_FAIL_REVIEWS:-0}" = "1" ] && exit 1
    fx reviews
    # --paginate concatenates ONE JSON DOCUMENT PER PAGE; page 2 exists only in the pagination
    # scenario, so the default case still emits a single well-formed page.
    [ -f "$S/reviews2.json" ] && cat "$S/reviews2.json"
    exit 0 ;;
  */issues/*/comments*)
    [ "${STUB_FAIL_COMMENTS:-0}" = "1" ] && exit 1
    fx comments
    [ -f "$S/comments2.json" ] && cat "$S/comments2.json"
    exit 0 ;;
  */reactions*)
    [ "${STUB_FAIL_REACTIONS:-0}" = "1" ] && exit 1
    fx reactions
    [ -f "$S/reactions2.json" ] && cat "$S/reactions2.json"
    exit 0 ;;
  */commits/*)
    [ "${STUB_FAIL_COMMIT:-0}" = "1" ] && exit 1
    cat "$S/commit.json"; exit 0 ;;
  */pulls/*)
    [ "${STUB_FAIL_PR:-0}" = "1" ] && exit 1
    # Count the poll BEFORE answering, then re-read it so `fx` above sees the same number for the
    # reads that follow within this same classification.
    n=0; [ -f "$S/polls" ] && n="$(cat "$S/polls")"
    n=$(( n + 1 )); printf '%s' "$n" > "$S/polls"
    if [ -f "$S/pr.$n.json" ]; then cat "$S/pr.$n.json"; else cat "$S/pr.json"; fi
    exit 0 ;;
  repos/*)
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$SBIN/gh"

# A `sleep` shim that RECORDS the requested nap and then sleeps a flat 1s.
#
# Both halves are necessary and the reason is worth stating, because the obvious stub (record and
# return instantly) HANGS THE SUITE. The bound is wall-clock — `$SECONDS - t0`, which is the honest
# thing to measure — so a sleep that does not actually pass time means the deadline is never
# reached and a `pending` scenario spins forever. Sleeping a flat 1s advances the clock enough for
# a small `--max-secs` to expire in a few iterations, while RECORDING the requested value is what
# lets the overshoot assertion below read the clamp the code actually computed rather than the
# shortened one it slept.
cat > "$SBIN/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$S/slept"
exec /bin/sleep 1
SLEEPSTUB
chmod +x "$SBIN/sleep"

# ---- fixtures --------------------------------------------------------------------------------
reset_fx() {
  rm -f "$S/reviews2.json" "$S/reactions2.json" "$S/comments2.json" "$S/polls" "$S/slept"
  rm -f "$S"/pr.[0-9]*.json "$S"/reviews.[0-9]*.json "$S"/reactions.[0-9]*.json "$S"/comments.[0-9]*.json
  printf '[]\n' > "$S/reviews.json"
  printf '[]\n' > "$S/reactions.json"
  printf '[]\n' > "$S/comments.json"
  pr_fx
  commit_fx
}
# pr_fx [sha] [state] [merged_at] [slug]
pr_fx() {
  jq -n --arg sha "${1:-$HEAD_SHA}" --arg st "${2:-open}" --arg m "${3:-}" --arg slug "${4:-acme/widget}" \
    '{head:{sha:$sha}, state:$st, merged_at:(if $m == "" then null else $m end), base:{repo:{full_name:$slug}}}' \
    > "$S/pr.json"
}
pr_fx_raw()  { printf '%s\n' "$1" > "$S/pr.json"; }
commit_fx()  { jq -n --arg d "${1:-$COMMIT_AT}" '{commit:{committer:{date:$d}, author:{date:$d}}}' > "$S/commit.json"; }
# review_fx <login> <state> <sha> [...] — one review per triple, into the DEFAULT fixture.
review_fx() { _reviews_into "$S/reviews.json" "$@"; }
_reviews_into() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg st "$2" --arg sha "$3" \
            '. + [{user:{login:$l,type:"Bot"},state:$st,commit_id:$sha}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}
# comment_fx <login> <created_at> [...] — one ISSUE COMMENT per pair (Codex "task mode" output).
comment_fx() { _comments_into "$S/comments.json" "$@"; }
_comments_into() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 2 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg at "$2" \
            '. + [{user:{login:$l},created_at:$at,body:"### Summary"}]')"
    shift 2
  done
  printf '%s\n' "$acc" > "$out"
}
# reaction_fx <login> <content> <created_at> [...] — one reaction per triple.
reaction_fx() { _reactions_into "$S/reactions.json" "$@"; }
_reactions_into() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg c "$2" --arg at "$3" \
            '. + [{user:{login:$l},content:$c,created_at:$at}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}
declare_bots() { printf '%s\n' '[reviewers]' "bots = $1" > "$REPO/agents.toml"; }
undeclare()    { rm -f "$REPO/agents.toml" "$GHOME/.config/ai-dev-baseline/agents.toml"; }

# _w <args...> : run the detector as the driving agent would — from $REPO, throwaway HOME, stubs.
# ONE home for the environment so a new STUB_* knob is wired in a single place; the two wrappers
# below differ only in what they do with stderr, and the redirect composes onto this subshell.
_w() {
  ( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
    STUB_AUTH_FAIL="${STUB_AUTH_FAIL:-0}" STUB_FAIL_PR="${STUB_FAIL_PR:-0}" \
    STUB_FAIL_REVIEWS="${STUB_FAIL_REVIEWS:-0}" STUB_FAIL_REACTIONS="${STUB_FAIL_REACTIONS:-0}" \
    STUB_FAIL_COMMENTS="${STUB_FAIL_COMMENTS:-0}" \
    STUB_FAIL_COMMIT="${STUB_FAIL_COMMIT:-0}" \
    bash "$PW" "$@" )
}
# w : stdout AND stderr, for asserting diagnostics.
w()    { OUT="$(_w "$@" 2>&1)"; RC_=$?; }
# wout : stdout ONLY (the "<verdict> <sha>" contract) — stderr is diagnostics and must not pollute it.
wout() { OUT="$(_w "$@" 2>/dev/null)"; RC_=$?; }
rc() { eq "$RC_" "$1" "$2"; }

reset_fx
declare_bots "[\"$CODEX\"]"

# ============================ 1. the clean signal ============================
# The whole point of the module: a connector `+1` on the PR's opening post, with NO review object
# anywhere, is a PASS. `pr-review.sh gate` cannot see this case at all (it reads only reviews), so
# if this arm regressed the detector would inherit that blind spot and never converge on a clean PR.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "clean: +1 after the head commit -> 0"
eq "$OUT" "clean $HEAD_SHA" "clean: stdout is '<verdict> <sha>'"

# The REST spelling of the same bot must work too — a bare declaration accepts either form.
reaction_fx "${CODEX}[bot]" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "clean: '[bot]'-suffixed reaction login still matches a bare declaration"

# ...but NOT the reverse. The match is ASYMMETRIC (#173, superseding #176): the API login is
# normalized toward the declaration, never the declaration toward the API. Stripping both sides let a
# declared `foo[bot]` be satisfied by a HUMAN account literally named `foo` — and REACTIONS ARE
# PUBLICLY WRITABLE, so on this signal the bar was a login collision and nothing else. `gh api
# users/gemini-code-assist` returns a real User account (id 200291788), i.e. the collision space is
# populated by the kind of account that reviews pull requests. A `user.type` filter cannot rescue it:
# verified live, this endpoint reports `type: "User"` for the Codex connector itself.
declare_bots "[\"${CODEX}[bot]\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a HUMAN '+1' does not satisfy a '[bot]' declaration (the #176 fail-open)"
# ...while the strict declaration still matches the spelling REST actually reports.
reaction_fx "${CODEX}[bot]" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "identity: a '[bot]' declaration matches the REST '[bot]' reaction login"
# A doubled suffix must not satisfy the strict form through the same one-suffix rule it denies.
reaction_fx "${CODEX}[bot][bot]" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a DOUBLED '[bot]' suffix does not satisfy a '[bot]' declaration"

# THE SAME RULE ON ALL THREE SIGNALS. The matcher had three inline copies here — reviews, issue
# comments, reactions — so one shared predicate has to be proved on each, not just on the one that
# happens to be checked first. A human login satisfying a declared App on ANY surface is the defect.
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"
review_fx "$CODEX" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "identity: a HUMAN review does not satisfy a '[bot]' declaration"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "identity: the suffixed review login does satisfy it"
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"
comment_fx "$CODEX" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a HUMAN issue comment does not satisfy a '[bot]' declaration"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "identity: the suffixed comment login does satisfy it"

reset_fx; declare_bots "[\"$CODEX\"]"

# ============================ 2. staleness — the dangerous direction ============================
# A reaction is NOT commit-scoped. A `+1` left on an earlier head is still sitting there after new
# commits land; counting it would report `clean` for code nobody reviewed. This is THE case the
# module must never get wrong.
reaction_fx "$CODEX" "+1" "$BEFORE_AT"
w observe --pr 1;  rc 11 "stale: a '+1' predating the head commit is NOT clean"
has "$OUT" "predates this head" "stale: says WHY it was rejected"

# The boundary. Equal timestamps mean the reaction cannot be proven to postdate the commit, so it
# must fall to pending — the safe side. A `>=` here would be the fail-open spelling.
reaction_fx "$CODEX" "+1" "$COMMIT_AT"
w observe --pr 1;  rc 11 "stale: a '+1' EQUAL to the head commit date is not proof of a pass"

# A reaction from a bot we do not declare proves nothing.
reaction_fx "some-other-bot[bot]" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a '+1' from an UNDECLARED login is not clean"

# Not every reaction is the pass signal. A 👀 (`eyes`) is the connector's in-progress marker and a
# 👎 is not a pass at all; neither may be read as one.
reaction_fx "$CODEX" "eyes" "$AFTER_AT"
w observe --pr 1;  rc 11 "content: an 'eyes' reaction is in-progress, not a pass"
reaction_fx "$CODEX" "-1" "$AFTER_AT"
w observe --pr 1;  rc 11 "content: a '-1' reaction is not a pass"

# The newest `+1` decides. An old stale one must not veto a fresh one that followed a re-review.
reaction_fx "$CODEX" "+1" "$BEFORE_AT" "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "staleness uses the NEWEST '+1', not the first one found"

# ============================ 3. the findings signal ============================
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
wout observe --pr 1;  rc 10 "findings: a submitted review AT THE HEAD -> 10"
eq "$OUT" "findings $HEAD_SHA" "findings: stdout is '<verdict> <sha>'"

# A review of an EARLIER commit is not a review of this one — the same rule pr-review.sh applies,
# and observed live on PR #166 (reviewed 5e527689, head moved to d203c1e7).
review_fx "${CODEX}[bot]" "COMMENTED" "$OLD_SHA"
w observe --pr 1;  rc 11 "findings: a review of an OLDER commit does not count"

# CHANGES_REQUESTED and APPROVED are both the reviewer having spoken about this head.
review_fx "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "findings: CHANGES_REQUESTED at head counts"
review_fx "${CODEX}[bot]" "APPROVED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "findings: APPROVED at head counts"

# ...but a draft nobody can see, and one that was explicitly revoked, are not.
review_fx "${CODEX}[bot]" "PENDING" "$HEAD_SHA"
w observe --pr 1;  rc 11 "findings: an unsubmitted PENDING review does not count"
review_fx "${CODEX}[bot]" "DISMISSED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "findings: a DISMISSED review does not count"

# A human's review is not the declared async reviewer's.
review_fx "somebody" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "identity: a review from an UNDECLARED login does not count"

# ============================ 3b. findings via an ISSUE COMMENT (Codex "task mode") ============
# The connector has TWO output shapes and the repo does not choose which it gets: with a Codex
# Cloud environment it runs as a TASK and posts ONE ISSUE COMMENT — no review object, no inline
# threads, no reaction. Observed live on this repo the same day as the review-shaped output
# (PR #166 at 08:01 → review + 3 threads; PR #178 at 19:30 → one comment, zero reviews).
# A detector reading only reviews sits at `pending` FOREVER on such a repo.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "task mode: an issue comment from the reviewer, newer than the head -> findings"
has "$OUT" "READ THE COMMENT" "task mode: tells the caller there may be no threads to resolve"

# A comment carries no commit either, so it gets the SAME staleness rule as a reaction — otherwise
# a summary from a previous head would keep re-triggering the resolve flow after every push.
comment_fx "${CODEX}[bot]" "$BEFORE_AT"
w observe --pr 1;  rc 11 "task mode: a comment predating this head is stale, not findings"
comment_fx "${CODEX}[bot]" "$COMMIT_AT"
w observe --pr 1;  rc 11 "task mode: a comment EQUAL to the head commit date is not proof"

# Ordinary human chatter on the PR is not a reviewer signal.
comment_fx "somebody" "$AFTER_AT"
w observe --pr 1;  rc 11 "task mode: a comment from an UNDECLARED login is not findings"

# The newest comment decides, so a fresh summary after a stale one still converges.
comment_fx "${CODEX}[bot]" "$BEFORE_AT" "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "task mode: uses the NEWEST comment, not the first found"

# Pagination, same reasoning as the other two signals.
reset_fx; declare_bots "[\"$CODEX\"]"
_comments_into "$S/comments.json"  "somebody" "$AFTER_AT"
_comments_into "$S/comments2.json" "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "task mode: a comment on page 2 is still found"

# An unreadable comments read must fail closed like every other read.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_COMMENTS=1 w observe --pr 1; rc 20 "unreadable: a failed comments read -> 20"; STUB_FAIL_COMMENTS=0

# FINDINGS OUTRANK CLEAN across shapes: a reviewer that commented about this head has something to
# say, even if a `+1` from an earlier pass is still sitting there.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 10 "precedence: a fresh comment outranks a fresh '+1'"

# ...and a review at the head still outranks a comment (the commit-scoped claim is strongest).
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "precedence: a review at head and a comment both yield findings"

# A clean pass must still be reachable when the reviewer has commented only on an OLDER head.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "precedence: a STALE comment does not mask a fresh clean pass"

# ============================ 4. the two signals together ============================
# They are disjoint in practice (a clean pass posts no review; a findings pass posts no reaction),
# but if both ever appear the commit-scoped claim is the stronger one and must win.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 10 "precedence: findings at head outrank a fresh '+1'"

# ============================ 5. pagination ============================
# A busy PR can push the bot's reaction off page 1 behind human reactions. A missed `+1` keeps a
# finished watch running to its deadline, so the read must paginate.
reset_fx; declare_bots "[\"$CODEX\"]"
_reactions_into "$S/reactions.json" "human-one" "heart" "$AFTER_AT"
_reactions_into "$S/reactions2.json" "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "pagination: a '+1' on page 2 is still found"

reset_fx; declare_bots "[\"$CODEX\"]"
_reviews_into "$S/reviews.json"  "somebody" "COMMENTED" "$HEAD_SHA"
_reviews_into "$S/reviews2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "pagination: a review on page 2 is still found"

# ============================ 6. the PR is no longer live ============================
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx "$HEAD_SHA" "closed" "2026-07-25T05:00:00Z"
w observe --pr 1;  rc 12 "gone: a MERGED PR is terminal"
has "$OUT" "MERGED" "gone: names the merge"
pr_fx "$HEAD_SHA" "closed" ""
w observe --pr 1;  rc 12 "gone: a CLOSED PR is terminal"
# Terminal-ness is checked BEFORE the signal reads, so a merged PR stops promptly rather than
# being classified off whatever the reviewer happened to leave behind.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 12 "gone: outranks a clean signal — there is nothing left to watch"

# ============================ 7. the declaration tri-state ============================
reset_fx
declare_bots "[]"
wout observe --pr 1;  rc 0 "declaration: 'bots = []' means nothing is coming -> clean, not an infinite wait"
eq "$OUT" "clean $HEAD_SHA" "declaration: '[]' still reports the witnessed head"

undeclare
w observe --pr 1;  rc 17 "declaration: UNDECLARED is unknowable -> fail closed at 17, never clean"

declare_bots '["[bot]"]'
w observe --pr 1;  rc 18 "declaration: a value that normalizes to nothing is malformed, not '[]'"

# A GLOBAL declaration counts as declared (the repo→global layering role-dispatch owns).
undeclare
printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" > "$GHOME/.config/ai-dev-baseline/agents.toml"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "declaration: a GLOBAL declaration is honoured"
undeclare; declare_bots "[\"$CODEX\"]"

# ============================ 8. every unreadable path -> 20 ============================
# A failed read must never look like a pass, and must never look like "nothing found yet" either:
# the first would arm on unreviewed code, the second would silently watch a broken API forever.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_PR=1       w observe --pr 1; rc 20 "unreadable: a failed PR read -> 20"; STUB_FAIL_PR=0
STUB_FAIL_REVIEWS=1  w observe --pr 1; rc 20 "unreadable: a failed reviews read -> 20"; STUB_FAIL_REVIEWS=0
STUB_FAIL_REACTIONS=1 w observe --pr 1; rc 20 "unreadable: a failed reactions read -> 20"; STUB_FAIL_REACTIONS=0

# The head-commit read happens ONLY on the clean branch, so it needs a `+1` present to reach it.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
STUB_FAIL_COMMIT=1   w observe --pr 1; rc 20 "unreadable: a failed head-commit read -> 20 (never clean)"; STUB_FAIL_COMMIT=0

# A PR object that arrives fine but carries no head SHA is not a network failure — and must still
# not be classified. This is why the read and the parse are separate steps.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx_raw '{"state":"open","base":{"repo":{"full_name":"acme/widget"}}}'
w observe --pr 1;  rc 20 "unreadable: a PR with no head SHA -> 20"

# A PR object that arrives WITHOUT its base repository is unreadable, not "nothing to compare
# against". Guarding the cross-repo refusal on a non-empty slug would make that refusal silently
# VANISH on exactly the malformed responses it exists to catch — and a URL naming another repo
# would then be answered about THIS repo. Both spellings of the missing field are pinned.
pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\"}"
w observe --pr 1;  rc 20 "unreadable: a PR with no base repo -> 20, never classified"
has "$OUT" "unidentifiable repository" "unreadable: names the missing base repo"
w observe --pr "https://github.com/other/repo/pull/7";  rc 20 "unreadable: a missing base repo cannot silently skip the cross-repo refusal"
pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\",\"base\":{\"repo\":null}}"
w observe --pr 1;  rc 20 "unreadable: an explicitly null base repo -> 20"
# A slug that ARRIVES but is not an owner/repo PAIR is a broken response and must be reported as one.
# Comparing it instead would call a malformed read "a different repository" — a confident answer about
# the wrong question.
for v in '"acme"' '"acme/widget/extra"' '"/widget"' '"acme/"'; do
  pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\",\"base\":{\"repo\":{\"full_name\":$v}}}"
  w observe --pr 1;  rc 20 "unreadable: a base repo slug of $v is malformed, not a repo mismatch"
done
pr_fx_raw '{ not json at all'
w observe --pr 1;  rc 20 "unreadable: an unparseable PR object -> 20"

reset_fx; declare_bots "[\"$CODEX\"]"
STUB_AUTH_FAIL=1 w observe --pr 1; rc 20 "unreadable: unauthenticated gh -> 20"; STUB_AUTH_FAIL=0

# ============================ 9. never answer about another repository ============================
# `repos/{owner}/{repo}` expands from the LOCAL remote, so a URL naming a different repo would be
# faithfully answered about THIS one — a confidently wrong answer, the one thing a detector must
# never produce.
reset_fx; declare_bots "[\"$CODEX\"]"
w observe --pr "https://github.com/other/repo/pull/7";  rc 2 "slug: a URL naming another repo is refused"
has "$OUT" "different repository" "slug: says why"
# The SCHEME IS OPTIONAL in a pasted URL, and matching only `*://*` let these through with an empty
# slug — skipping the refusal entirely and confidently answering about THIS repo's #7.
w observe --pr "github.com/other/repo/pull/7";  rc 2 "slug: a scheme-less URL naming another repo is refused"
w observe --pr "other/repo/pull/7";             rc 2 "slug: a bare owner/repo/pull/N naming another repo is refused"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr "https://github.com/acme/widget/pull/7";  rc 0 "slug: a URL naming THIS repo is accepted"
eq "$OUT" "clean $HEAD_SHA" "slug: a URL argument yields the same contract as a bare number"
wout observe --pr "acme/widget/pull/7";  rc 0 "slug: a scheme-less URL naming THIS repo is still accepted"

# An argument that is neither a bare number nor a URL naming a repository cannot be answered at all:
# taking the digits after `pull/` alone reduces these to `7`, which is then answered about whichever
# repository the reads happen to address — the cross-repo answer reached from a different input.
w observe --pr "pull/7";                     rc 2 "slug: a PR-ish argument naming no repository is rejected"
w observe --pr "https://github.com/pull/7";  rc 2 "slug: a URL with no owner/repo is rejected"

# A BARE NUMBER NAMES NO REPOSITORY, so nothing in the argument can catch a redirected read — and
# `/resolve-pr-threads --watch` passes exactly that form. Every read addresses `repos/{owner}/{repo}`,
# which gh expands, and the documented GH_REPO variable overrides that expansion (verified live:
# `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers `cli/cli` from a directory that is not a
# repository at all). The anchor is therefore the CHECKOUT's git origin, which no gh variable can
# move. Simulated the only way a stub can: the reads answer for a repository that is not this one.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx "$HEAD_SHA" "open" "" "other/project"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 2 "slug: a bare number whose reads answered for ANOTHER repo is refused (GH_REPO class)"
has "$OUT" "GH_REPO" "slug: the refusal names the likely cause"
wout observe --pr 1
eq "$OUT" "" "slug: a redirected read prints no verdict line"
reset_fx; declare_bots "[\"$CODEX\"]"

# stdout is "<verdict> <sha>" or NOTHING — never a bare newline. `wait`'s terminal arm prints the
# captured line, and a slug mismatch produces a code with no line, so an unguarded print would emit
# one empty line that a caller doing `read -r verdict sha` would take as two empty strings.
wout wait --pr "https://github.com/other/repo/pull/7" --interval 1 --max-secs 5;  rc 2 "wait: a slug mismatch is refused"
eq "$OUT" "" "wait: prints NO stdout line for a verdict-less terminal code"

# ============================ 10. usage ============================
w;                                rc 2 "usage: no subcommand"
w badsub;                         rc 2 "usage: unknown subcommand"
w observe;                        rc 2 "usage: observe without --pr"
w wait;                           rc 2 "usage: wait without --pr"
w observe --pr;                   rc 2 "usage: --pr with no value"
w observe --pr "";                rc 2 "usage: --pr empty"
has "$OUT" "must not be empty" "usage: an EMPTY value reports emptiness, not the arity message"
w observe --pr notanumber;        rc 2 "usage: --pr not a number or URL"
w observe --pr 0;                 rc 2 "usage: --pr zero"
w observe --pr 1 --bogus x;       rc 2 "usage: unknown option"
w wait --pr 1 --interval 0;       rc 2 "usage: --interval zero would busy-wait"
w wait --pr 1 --interval abc;     rc 2 "usage: --interval non-numeric"
w wait --pr 1 --max-secs 0;       rc 2 "usage: --max-secs zero would return before the first read"
w wait --pr 1 --max-secs "";      rc 2 "usage: --max-secs empty"
# All-digits is not enough: a value wider than a shell integer overflows the deadline arithmetic,
# turning the bound into a nonsense (possibly negative) remaining time — a bound that expires at
# once or never. Digits-only validators are exactly how that slips through.
w wait --pr 1 --max-secs 99999999999999999999;  rc 2 "usage: --max-secs wider than a shell integer"
w wait --pr 1 --interval 99999999999999999999;  rc 2 "usage: --interval wider than a shell integer"

# ============================ 11. the bounded wait ============================
# Terminal on the first poll: return immediately, and sleep NOT AT ALL. A watcher that sleeps once
# before checking wastes an interval on a PR that was already done.
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout wait --pr 1 --interval 1 --max-secs 30;  rc 0 "wait: a terminal first poll returns at once"
eq "$OUT" "clean $HEAD_SHA" "wait: emits the same '<verdict> <sha>' contract as observe"
eq "$( [ -f "$S/slept" ] && wc -l < "$S/slept" | tr -d ' ' || echo 0 )" "0" "wait: does not sleep before its first read"

# Pending, then findings: the loop must converge on the LATER answer, not the first one.
reset_fx; declare_bots "[\"$CODEX\"]"
printf '[]\n' > "$S/reviews.1.json"                                  # poll 1: nothing yet
_reviews_into "$S/reviews.2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"   # poll 2: findings
w wait --pr 1 --interval 1 --max-secs 30;  rc 10 "wait: converges when the signal appears on a later poll"

# The deadline is a bound, and the sleep must never overshoot it. With an interval far larger than
# the bound, every nap must be clamped to what REMAINS — otherwise `--max-secs` is an approximation
# that can overshoot by a whole interval.
reset_fx; declare_bots "[\"$CODEX\"]"
w wait --pr 1 --interval 30 --max-secs 3;  rc 11 "wait: expires at the bound with no terminal signal"
has "$OUT" "handing off" "wait: says it is handing off rather than claiming a verdict"
if [ -f "$S/slept" ]; then
  eq "$(awk '$1 > 3 {c++} END {print c+0}' "$S/slept")" "0" "wait: never sleeps past the remaining bound"
else
  bad "wait: expected at least one recorded nap before the bound expired"
fi

# A single transient error must not abandon a long watch...
reset_fx; declare_bots "[\"$CODEX\"]"
printf '{ broken\n' > "$S/pr.1.json"                                  # poll 1 unparseable
_reactions_into "$S/reactions.2.json" "$CODEX" "+1" "$AFTER_AT"       # poll 2 fine
w wait --pr 1 --interval 1 --max-secs 30;  rc 0 "wait: rides out ONE unreadable poll and converges"

# The deadline can land while the LAST poll was unreadable, and that poll printed no verdict. The
# contract says stdout is "<verdict> <sha>" or nothing — never a bare newline, which a caller doing
# `read -r verdict sha` would silently take as two empty strings rather than "there was no answer".
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_PR=1 wout wait --pr 1 --interval 1 --max-secs 1;  rc 11 "wait: a bound reached mid-failure still reports pending"
eq "$OUT" "" "wait: prints NO stdout line when the final poll produced no verdict"
STUB_FAIL_PR=0

# ...but an endlessly unreadable API must not be polled forever either.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_PR=1 w wait --pr 1 --interval 1 --max-secs 300;  rc 20 "wait: gives up after consecutive unreadable polls"
has "$OUT" "consecutive unreadable" "wait: names why it gave up"
STUB_FAIL_PR=0

# A PR that merges mid-watch stops the loop rather than running to the deadline.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx "$HEAD_SHA" "open" ""
jq -n --arg sha "$HEAD_SHA" '{head:{sha:$sha}, state:"closed", merged_at:"2026-07-25T05:00:00Z", base:{repo:{full_name:"acme/widget"}}}' > "$S/pr.2.json"
w wait --pr 1 --interval 1 --max-secs 300;  rc 12 "wait: stops as soon as the PR stops being open"

# A head that moves mid-watch is reported, and the earlier signal must not carry over: the `+1` on
# poll 1 is fresh for head A, but poll 2's head B was committed after it.
reset_fx; declare_bots "[\"$CODEX\"]"
jq -n --arg sha "$OLD_SHA"  '{head:{sha:$sha}, state:"open", merged_at:null, base:{repo:{full_name:"acme/widget"}}}' > "$S/pr.1.json"
jq -n --arg sha "$HEAD_SHA" '{head:{sha:$sha}, state:"open", merged_at:null, base:{repo:{full_name:"acme/widget"}}}' > "$S/pr.2.json"
jq -n --arg sha "$HEAD_SHA" '{head:{sha:$sha}, state:"open", merged_at:null, base:{repo:{full_name:"acme/widget"}}}' > "$S/pr.3.json"
# The commit fixture is the NEW head's date, which postdates the reaction — so the reaction that
# was valid for the old head is stale for this one.
commit_fx "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$COMMIT_AT"
w wait --pr 1 --interval 1 --max-secs 3;  rc 11 "wait: a signal for the PREVIOUS head does not satisfy the new one"
has "$OUT" "head moved" "wait: reports that the head moved under it"

# ============================ 12. the module's own boundary ============================
# pr-review.sh's header names this module as where a waiting watch belongs, and this module's
# header promises not to resolve, push, or merge. Pin that promise: a detector that grew an arming
# call would silently turn an observation into a merge, which is the one escalation nothing else
# here would catch — every assertion above would still pass.
absent() { if grep -q "$1" "$PW"; then bad "$2"; else ok; fi; }
absent 'gh pr merge'        "the detector must never arm or perform a merge"
absent 'git push'           "the detector must never push"
absent 'resolveReviewThread' "the detector must never resolve threads"
absent 'git switch'         "the detector must never move the working tree"

check_summary "pr-watch"
