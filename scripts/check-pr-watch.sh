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
#      reviewed. The timestamp rule is pinned in BOTH directions, including the boundary where they
#      are equal.
#   1b. AND ITS LOWER BOUND IS SERVER-ASSIGNED (#175). That rule used to compare against the head
#      commit's COMMITTER DATE, which GitHub echoes back verbatim from the committing machine — so a
#      past-dated head made a stale `+1` look fresh, a false `clean`, with no attacker required. The
#      anchor is now the repository ACTIVITY record for the head REF, and the tests pin three things
#      a weaker anchor would get wrong: the same SHA arriving on ANOTHER ref must not date this one
#      (which is exactly why a check-suite anchor was rejected); the LATEST record decides, so a
#      reverse force-push is caught; and an anchor that cannot be established is `pending` on BOTH
#      date-scoped signals. The committer date is asserted to be NEVER FETCHED, not merely outvoted.
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
PW="$ROOT/scripts/lib/pr-watch.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

[ "$#" -gt 1 ] && { echo "usage: check-pr-watch.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-pr-watch.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ============= --mutation: section 11's cases must be OBSERVED going red (#394) =================
# WHY A MODE AND NOT MORE ASSERTIONS. Every case this table covers has the failure mode #394 was
# filed for — it can pass while looking at nothing. The reported case satisfied `rc 11` after ONE
# poll, with the message it exists to assert never printed; the nap-clamp case counted zero
# oversized naps in a file that did not exist. Both are green states that prove nothing, and no
# assertion inside the suite can tell them from real ones. So each row below breaks ONE thing this
# section claims to catch, runs the WHOLE suite against the broken copy, and requires it back at
# exit 1 carrying THAT CASE'S OWN witness (#213's `fires:` contract, via `check_mutation_pool`).
#
# SCOPED TO SECTION 11, said plainly so nobody reads it as more: it proves the BOUNDED-WAIT cases
# can fire. It is not a mutation suite for `pr-watch.sh` at large, and the classification sections
# above are covered by their own assertions and by nothing here.
#
# TWO POOLS, because `check_mutation_pool` builds one target path per call and these witnesses live
# in two files — the wait loop's own reporting (`pr-watch.sh`) and the staleness rule it delegates
# to (`common.sh`). That is the harness's shape, not a judgement about the rows.
#
# NO SEPARATE CONTROL RUN, unlike `check-selfcheck.sh --mutation`, and the difference is real
# rather than an omission: that mode lowers a deadline for every row, so it owes a run proving an
# UNMUTATED copy survives the same setting. Nothing here perturbs the copy — the rows are literal
# edits and nothing else — so the control is already paid for twice over: `check_mutate_literal`
# reports a row whose literal is absent as "tested NOTHING" rather than scoring it, and selfcheck
# runs the unmutated suite as its own `pr-watch` step in the same invocation.
if [ "$MODE" = mutation ]; then
  # mut_run <copy-dir> — the nested suite, behind a parse check on both mutated files. A mutation
  # that stops either one PARSING has changed whether the code runs at all rather than how it
  # behaves, and the nested suite would still fail on the right witness — crediting the row for a
  # defect it never exercised. 9 makes the pool report an ABORT, which is what it was.
  mut_run() {
    local d="$1"
    bash -n "$d/scripts/lib/pr-watch.sh" 2>/dev/null \
      || { printf 'the mutated pr-watch.sh no longer PARSES\n'; return 9; }
    bash -n "$d/scripts/lib/common.sh" 2>/dev/null \
      || { printf 'the mutated common.sh no longer PARSES\n'; return 9; }
    bash "$d/scripts/check-pr-watch.sh" 2>&1
  }
  # `scripts` alone is this suite's whole mutation surface, so the subtree copier rather than the
  # worktree one: five copies of the repo's ~66MB .git would be spent moving a tree about to be
  # deleted (check_copy_subtrees' own header measures that).
  mut_prep_watch()  { check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1 || return 1
                      printf '%s' "$1/scripts/lib/pr-watch.sh"; }
  mut_prep_common() { check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1 || return 1
                      printf '%s' "$1/scripts/lib/common.sh"; }

  # --- the wait loop's own reporting and bounding ----------------------------------------------
  # The head move goes unreported. The rest of the watch is untouched, so ONLY the two assertions
  # that read that line can catch it — which is the point.
  check_mut "head-move-unreported" \
    'head moved $lasthead -> $head; any earlier signal no longer applies' \
    'head changed; any earlier signal no longer applies' \
    'wait: reports that the head moved under it'
  # The nap is no longer clamped to what remains, so an oversized `--interval` overshoots the bound.
  check_mut "nap-unclamped" \
    '[ "$nap" -gt "$remaining" ] && nap="$remaining"' \
    ':' \
    'wait: clamped the oversized interval down to what remained'
  # THE DEFECT #394 REPORTS, injected at its source: a deadline the fixture cannot outlive. Pinning
  # it to 3s reproduces what a starved runner did to the retired bound, and the case that must
  # notice is the one whose first poll is deliberately slow.
  check_mut "deadline-beats-the-fixture" \
    'deadline=$(( BASH_MONOSECONDS + OPT_MAX_SECS ))' \
    'deadline=$(( BASH_MONOSECONDS + 3 ))' \
    'wait: a first poll outliving the retired bound no longer ends the watch'
  check_mutation_pool "pr-watch-wait" "$work/mw" mut_prep_watch mut_run 4

  # --- the staleness rule the wait delegates to -------------------------------------------------
  # A SECOND TABLE, so the table must be cleared first: `check_mut` appends, and a stale row would
  # be re-run against the wrong target and scored as "did not apply".
  #
  # Both witnesses below are the DISTINCTIVE PREFIX of their assertion rather than the whole label
  # (`check_mut` allows either): the labels carry an apostrophe, and quoting one inside a literal
  # here costs more legibility than the extra words buy. No other assertion in this suite starts
  # with either phrase.
  check_mut_reset
  # The staleness comparison loses its backslash — the exact regression common.sh's own comment
  # warns about, and the one that turns every signal fresh with no error anywhere.
  check_mut "staleness-disarmed" \
    'elif [ "$val" \> "$anchor" ]; then' \
    'elif [ "$val" > "$anchor" ]; then' \
    'wait: a signal from the PREVIOUS head'
  # The verdict stays right and the REASON stops being said. `at $val predates this head` rather
  # than the shorter phrase, because the shorter one also appears in the comment above the echo and
  # a row that edits a comment tests nothing.
  check_mut "staleness-unexplained" \
    'at $val predates this head' \
    'at $val is not evidence about this head' \
    'wait: says WHY the previous era'
  check_mutation_pool "pr-watch-staleness" "$work/ms" mut_prep_common mut_run 4

  check_summary "pr-watch-mutation"
  exit 0
fi

REPO="$work/repo"; GHOME="$work/home"; SBIN="$work/sbin"; S="$work/stub"
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$SBIN" "$S"
# A git repo so the helper's repo-root resolution is deterministically $REPO, whatever ambient git
# repo sits above the temp dir. `check_make_stub_repo` carries the `origin`-remote contract (#173),
# which `/resolve-pr-threads --watch` needs: it passes the bare `--pr 7` form, naming no repository.
check_make_stub_repo "$REPO" https://github.com/acme/widget.git || {
  echo "check-pr-watch: FATAL — could not build the fixture repo" >&2; exit 1; }

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CODEX="chatgpt-codex-connector"
HEAD_REF="feature"
# WHEN THE HEAD REF BECAME THE HEAD SHA, as the repository activity API recorded it (#175) — NOT the
# head commit's committer date, which is client-supplied and which this module no longer reads at
# all. Every reaction/comment fixture is expressed relative to it so the staleness rule is read at a
# glance rather than by comparing two opaque strings.
ARRIVED_AT="2026-07-25T04:42:15Z"
AFTER_AT="2026-07-25T04:45:23Z"    # 3m08s later — the real gap observed on PR #88
BEFORE_AT="2026-07-25T04:40:00Z"
# A committer date deliberately EARLIER than every reaction below. Under the pre-#175 rule this
# alone produced `clean`; it is served by the stub's (now unused) commit route purely so the tests
# can prove the module never asks for it.
FORGED_COMMIT_AT="2026-07-25T00:00:00Z"

# THE RUNAWAY BACKSTOP FOR EVERY `wait` CASE WHOSE ORACLE IS A FIXTURE (#394).
#
# `wait`'s bound is REAL elapsed time, so `--max-secs` is one of two completely different things
# depending on the case, and conflating them is what made this suite load-sensitive:
#
#   * where the DEADLINE is the oracle (the case asserts rc 11, or asserts what a bound-expiry
#     prints), it must stay SMALL — the case is waiting for it, and a loaded runner only reaches
#     it sooner, which is still the answer being asserted;
#   * where a FIXTURE is the oracle (the case asserts what a later poll classifies, reports or
#     returns), the deadline is a runaway backstop and nothing else. It must be far larger than
#     any plausible classification, or a loaded runner reaches it FIRST and the case ends before
#     its fixture ever changes — passing vacuously, or failing with no cause in the diff.
#
# 120s, not 300s and not 30s: a classification here forks a handful of stubbed processes and costs
# ~0.3s unloaded, so this is a two-order-of-magnitude margin, while still bounding what a genuine
# regression costs the suite (a case that stops terminating hangs for two minutes, not five).
WATCH_BACKSTOP=120

# ============================ the recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the reviews URL is ALSO
# a `repos/*/pulls/*` URL, so an arm matching the general shape first swallows the specific one and
# every scenario silently reads the wrong fixture. Most specific first, always.
#
# It also COUNTS polls (one `pulls/N` read per classification) and prefers a per-poll fixture
# `<name>.<n>.json` when one exists, which is how the `wait` scenarios below make the answer change
# between polls without any network.
# THE TWO GRAPHQL ARMS ARE COMPOSED IN FROM check-lib.sh, NOT PASTED. They were literals here
# until the independent review pointed out that `check_pr_graphql_stub_body` and
# `check_pr_receipts_stub_body` were DEFINED as the shared home and then never called — three copies
# of one thing, in a repo whose first golden rule is "source the shared primitive, never copy it".
# It had already drifted once: adding the failure knobs meant hand-patching all three. The stub is
# therefore assembled by a group whose stdout is the program, so the shared bodies arrive by call.
{ cat <<'STUB'
#!/usr/bin/env bash
# Knobs:
#   STUB_AUTH_FAIL=1       -> `gh auth status` fails (unauthenticated)
#   STUB_FAIL_PR=1         -> the PR read fails
#   STUB_FAIL_REVIEWS=1    -> the reviews read fails
#   STUB_FAIL_REACTIONS=1  -> the reactions read fails
#   STUB_FAIL_COMMENTS=1   -> the issue-comments read fails
#   STUB_FAIL_ACTIVITY=1   -> the ref-activity read fails
#   STUB_EMPTY_ACTIVITY=1  -> the ref-activity read SUCCEEDS with an empty body (not `[]`)
#   STUB_EMPTY_REVIEWS/COMMENTS/REACTIONS=1 -> that signal read SUCCEEDS with an empty body
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
case "${1:-}" in
  auth) exit 0 ;;
  api)  ;;
  *)    exit 0 ;;
esac
# --- GraphQL: the ONE read a classification now makes (#174) --------------------------------
# Two different queries reach here. They are told apart by a field only one of them selects:
# the receipt read (#169's request-review) asks for comment BODIES, the classification snapshot
# deliberately does not. Matching on that is the same "ask what the document actually contains"
# discipline the REST arms use, rather than counting arguments.
if [ "${2:-}" = "graphql" ]; then
  _q=""
  for a in "$@"; do case "$a" in query=*) _q="$a" ;; esac; done
  case "$_q" in
    *body*) printf 'graphql:receipts\n' >> "$S/calls"
STUB
check_pr_receipts_stub_body
cat <<'STUB'
      ;;
    *) printf 'graphql:snapshot\n' >> "$S/calls"
STUB
check_pr_graphql_stub_body
cat <<'STUB'
      ;;
  esac
fi
url=""
for a in "$@"; do
  case "$a" in repos/*) [ -z "$url" ] && url="$a" ;; esac
done
# EVERY api call is recorded, which is how the suite proves a NEGATIVE: #175's whole claim is that
# the client-supplied committer date is out of the decision, and the only way to show that is that
# the head-commit endpoint is never asked. An assertion on the verdict alone would still pass if the
# module read the date and happened to weight it differently.
printf '%s\n' "$url" >> "$S/calls"
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
    [ "${STUB_EMPTY_REVIEWS:-0}" = "1" ] && exit 0
    fx reviews
    # --paginate concatenates ONE JSON DOCUMENT PER PAGE; page 2 exists only in the pagination
    # scenario, so the default case still emits a single well-formed page.
    [ -f "$S/reviews2.json" ] && cat "$S/reviews2.json"
    exit 0 ;;
  */issues/*/comments*)
    # A POST, NOT A GET — `request-review` creating a comment (#169). Told apart by the `body=`
    # argument, because the URL is identical. RECORDED (so a test can assert a comment was really
    # posted, and how many times) and PERSISTED into the receipt fixture (so the NEXT invocation
    # sees the real receipt this one created, which is the only way to test idempotency as
    # success-then-repeat rather than as a preloaded fixture). Both gaps were named by the
    # independent review: without the record, deleting `-f body=` from the module stays green.
    _body=""; _isprot=0
    for _a in "$@"; do case "$_a" in body=*) _body="${_a#body=}"; _isprot=1 ;; esac; done
    if [ "$_isprot" = "1" ]; then
      [ "${STUB_FAIL_POST:-0}" = "1" ] && exit 1
      printf '%s\n' "$_body" >> "$S/posted"
      _at="${STUB_POST_AT:-2026-07-25T04:46:00Z}"
      _cur="[]"; [ -f "$S/receipts.json" ] && _cur="$(cat "$S/receipts.json")"
      printf '%s' "$_cur" | jq -c --arg at "$_at" --arg b "$_body" \
        '. + [{created_at:$at, body:$b}]' > "$S/receipts.json.tmp" \
        && mv "$S/receipts.json.tmp" "$S/receipts.json"
      printf '{"id":1}\n'; exit 0
    fi
    [ "${STUB_FAIL_COMMENTS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_COMMENTS:-0}" = "1" ] && exit 0
    fx comments
    [ -f "$S/comments2.json" ] && cat "$S/comments2.json"
    exit 0 ;;
  */reactions*)
    [ "${STUB_FAIL_REACTIONS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_REACTIONS:-0}" = "1" ] && exit 0
    fx reactions
    [ -f "$S/reactions2.json" ] && cat "$S/reactions2.json"
    exit 0 ;;
  */activity*)
    [ "${STUB_FAIL_ACTIVITY:-0}" = "1" ] && exit 1
    # A SUCCESSFUL read with an empty body — distinct from `[]`, and the reason the module reads and
    # parses in two steps. Collapsing them would turn this into "no matching activity" (11) when it
    # is really "the call produced no document" (20).
    [ "${STUB_EMPTY_ACTIVITY:-0}" = "1" ] && exit 0
    fx activity
    exit 0 ;;
  */commits/*)
    # RETIRED BY #175 and kept deliberately — as a BAITED route, not as a working dependency. It
    # still answers, with a committer date old enough to have produced a false `clean` under the old
    # rule, so a future edit that reaches for the head commit again gets a TEMPTING wrong answer
    # rather than nothing.
    #
    # It is not what makes the negative assertion work: `called '/commits/'` reads the unconditional
    # recorder above, and would fail with this arm deleted too (an unmatched `repos/…` falls to the
    # catch-all below and exits 0 with empty stdout — the suite never 404s either way). Kept because
    # a regression should fail on "the head commit was read", which names the defect, rather than on
    # whatever an empty body happens to do three steps later.
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
} | check_write_stub "$SBIN/gh"

# A `sleep` shim that RECORDS the requested nap and then sleeps a flat 1s.
#
# Both halves are necessary and the reason is worth stating, because the obvious stub (record and
# return instantly) HANGS THE SUITE. The bound is elapsed REAL time — `$BASH_MONOSECONDS` against a
# deadline, which is the honest thing to measure — so a sleep that does not actually pass time means
# the deadline is never reached and a `pending` scenario spins forever. Sleeping a flat 1s advances
# the clock enough for
# a small `--max-secs` to expire in a few iterations, while RECORDING the requested value is what
# lets the overshoot assertion below read the clamp the code actually computed rather than the
# shortened one it slept.
check_write_stub "$SBIN/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$S/slept"
exec /bin/sleep 1
SLEEPSTUB

# ---- fixtures --------------------------------------------------------------------------------
# The GraphQL assembler is a CONSTANT program, written once at setup rather than in `reset_fx`:
# it is the TRANSPORT, not a scenario fixture. Recreating it per reset left every scenario
# before the first reset reading an empty document — which is exactly how this suite failed
# while #174 was being wired, and the failure looked like a broken guard rather than a broken
# harness.
check_pr_graphql_assembler "$S/assemble.jq"

reset_fx() {
  rm -f "$S/reviews2.json" "$S/reactions2.json" "$S/comments2.json" "$S/polls" "$S/slept" "$S/calls"
  # The slow-poll injection (#394) is per-scenario and MUST be swept: left behind it would tax the
  # first poll of every scenario that follows, and the one place it is set is the LAST case in
  # section 11 — so a missing sweep is invisible there and shows up as unexplained seconds
  # somewhere else entirely.
  rm -f "$S"/slow-[0-9]*
  rm -f "$S"/pr.[0-9]*.json "$S"/reviews.[0-9]*.json "$S"/reactions.[0-9]*.json \
        "$S"/comments.[0-9]*.json "$S"/activity.[0-9]*.json
  # #174/#169 fixtures: the truncation counters, the receipt read, and the raw-document override.
  rm -f "$S"/*-total.txt "$S/receipts.json" "$S/graphql-raw.json" "$S/posted" "$S/receipts-raw.json"
  rm -f "$S/rpolls" "$S"/rpr.[0-9]*.json
  printf '[]\n' > "$S/reviews.json"
  printf '[]\n' > "$S/reactions.json"
  printf '[]\n' > "$S/comments.json"
  pr_fx
  commit_fx
  activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"
}
# pr_fx [--sha X] [--state X] [--merged-at X] [--base-slug X] [--head-slug X] [--head-ref X]
# A defaults wrapper over `check_pr_json`, which holds the fixture shape (D68). Last flag wins, so
# `pr_fx --head-slug ""` renders `head.repo` null — a deleted fork, which the anchor must degrade on.
pr_fx() {
  check_pr_json "$S/pr.json" --sha "$HEAD_SHA" --state open --merged-at "" \
    --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF" "$@"
}
pr_fx_raw()  { printf '%s\n' "$1" > "$S/pr.json"; }
# pr_poll_fx <n> [flags…] — `pr_fx` writing the per-poll fixture the gh stub prefers on poll <n>.
# A second wrapper rather than a second construction site: the destination is the only difference.
pr_poll_fx() {
  local n="$1"; shift
  check_pr_json "$S/pr.$n.json" --sha "$HEAD_SHA" --state open --merged-at "" \
    --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF" "$@"
}
# The committer date the module MUST NOT consult. Defaulted to a value old enough that reading it
# would flip every staleness assertion below from `pending` to `clean`.
commit_fx()  { jq -n --arg d "${1:-$FORGED_COMMIT_AT}" '{commit:{committer:{date:$d}, author:{date:$d}}}' > "$S/commit.json"; }
# The four payload builders and the call recorder live in check-lib.sh (#167): both PR-guard suites
# now exercise ONE shared classifier, so the response SHAPES must have one home. The `_*_into` seam
# stays because this suite writes page-two and per-poll fixtures as well as the default one.
called()          { check_pr_called "$S/calls" "$1"; }
review_fx()       { check_pr_reviews_json   "$S/reviews.json"   "$@"; }
_reviews_into()   { check_pr_reviews_json   "$@"; }
comment_fx()      { check_pr_comments_json  "$S/comments.json"  "$@"; }
_comments_into()  { check_pr_comments_json  "$@"; }
reaction_fx()     { check_pr_reactions_json "$S/reactions.json" "$@"; }
_reactions_into() { check_pr_reactions_json "$@"; }
activity_fx()     { check_pr_activity_json  "$S/activity.json"  "$@"; }
activity_fx_raw() { printf '%s\n' "$1" > "$S/activity.json"; }
# The reviewer-declaration tri-state lives in check-lib.sh too; both suites pin the same three.
declare_bots() { check_declare_bots   "$REPO" "$1"; }
undeclare()    { check_undeclare_bots "$REPO" "$GHOME"; }

# _w <args...> : run the detector as the driving agent would — from $REPO, throwaway HOME, stubs.
# ONE home for the environment so a new STUB_* knob is wired in a single place; the two wrappers
# below differ only in what they do with stderr, and the redirect composes onto this subshell.
_w() {
  ( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
    STUB_AUTH_FAIL="${STUB_AUTH_FAIL:-0}" STUB_FAIL_PR="${STUB_FAIL_PR:-0}" \
    STUB_FAIL_REVIEWS="${STUB_FAIL_REVIEWS:-0}" STUB_FAIL_REACTIONS="${STUB_FAIL_REACTIONS:-0}" \
    STUB_FAIL_COMMENTS="${STUB_FAIL_COMMENTS:-0}" \
    STUB_FAIL_ACTIVITY="${STUB_FAIL_ACTIVITY:-0}" \
    STUB_EMPTY_ACTIVITY="${STUB_EMPTY_ACTIVITY:-0}" \
    STUB_EMPTY_REVIEWS="${STUB_EMPTY_REVIEWS:-0}" STUB_EMPTY_COMMENTS="${STUB_EMPTY_COMMENTS:-0}" \
    STUB_EMPTY_REACTIONS="${STUB_EMPTY_REACTIONS:-0}" \
    STUB_GRAPHQL_FAIL="${STUB_GRAPHQL_FAIL:-0}" STUB_EMPTY_GRAPHQL="${STUB_EMPTY_GRAPHQL:-0}" \
    STUB_GRAPHQL_RC="${STUB_GRAPHQL_RC:-0}" \
    STUB_FAIL_POST="${STUB_FAIL_POST:-0}" STUB_POST_AT="${STUB_POST_AT:-}" \
    bash "$PW" "$@" )
}
# w : stdout AND stderr, for asserting diagnostics.
w()    { OUT="${ _w "$@" 2>&1; }"; RC_=$?; }
# wout : stdout ONLY (the "<verdict> <sha>" contract) — stderr is diagnostics and must not pollute it.
wout() { OUT="${ _w "$@" 2>/dev/null; }"; RC_=$?; }
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

# The boundary. Equal timestamps mean the reaction cannot be proven to postdate the head's arrival,
# so it must fall to pending — the safe side. A `>=` here would be the fail-open spelling.
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "stale: a '+1' EQUAL to this head's arrival is not proof of a pass"

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

# ============ 2b. the anchor is SERVER-assigned and REF-scoped (#175) ============
# The staleness proof used to rest on the head commit's committer date, which GitHub echoes back
# verbatim from the committing machine. A past-dated head therefore made a STALE `+1` look fresh —
# a false `clean`, the one verdict this module must never produce. Reachable with no attacker: a
# date-preserving rebase, or a clock that is behind by more than the review latency.

# THE ISSUE'S EXACT SCENARIO. The head arrived AFTER the reaction, while the head commit CLAIMS a
# committer date long before it. The old rule read `clean` here; the anchor must read `pending`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT"       # this head arrived at 04:45
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"                          # the `+1` is from 04:42
commit_fx "$FORGED_COMMIT_AT"                                    # ...and the commit claims 00:00
w observe --pr 1;  rc 11 "#175: a '+1' predating this head's ARRIVAL is not clean, whatever the commit claims"

# ...and the proof that it is not merely outweighed: the committer date is never even fetched. This
# is the assertion that would fail if a future edit re-introduced the client-supplied input as a
# tie-breaker, a fallback, or a `max()` term.
if called '/commits/'; then bad "#175: the head-commit endpoint must never be read"; else ok; fi

# THE CASE THAT RULES OUT A CHECK-SUITE ANCHOR, which is the obvious server-assigned candidate and
# the one the issue proposed first. Check suites are scoped to the SHA, not to the REF: a commit
# that already ran CI on another branch carries its ORIGINAL timestamp, so an ordinary fast-forward
# onto it keeps the fail-open with no force-push anywhere in the story. Modelled here as an activity
# record for the SAME SHA on a DIFFERENT ref — which must not be allowed to date this ref.
#
# THE FOREIGN RECORD IS THE NEWER ONE, and that is what makes this assertion able to FAIL. With the
# foreign record older, dropping `select(.ref == $ref)` cannot change the verdict — the code takes
# the LATEST match, so a superset containing only older records yields the same answer and the test
# passes against a module that has no ref filter at all. Ordered this way, dropping the filter picks
# the foreign 04:45 record, the 04:42 `+1` reads fresh against it, and the verdict flips to `clean`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/somewhere-else" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
wout observe --pr 1;  rc 0 "#175: this ref's OWN record dates it, even when a newer one names another ref"
# ...and the ordinary direction: a record for this ref that postdates the signal is stale.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/somewhere-else" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "#175: a '+1' predating this ref's own arrival record is not clean"

# THE `after` FILTER, pinned on its own. Every "no anchor" case above uses an EMPTY activity list,
# which returns 11 whether or not the SHA is matched — so none of them can catch a module that
# dropped `select(.after == $sha)`. Here the ref HAS activity and none of it names the current head:
# the honest answer is "this head's arrival is unrecorded" (11), while an unfiltered read would date
# it from a push of a DIFFERENT commit and report `clean`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$OLD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: activity for a DIFFERENT SHA on this ref does not date this head"

# A REVERSE FORCE-PUSH: the ref went A -> B -> A, so two records carry the same `after`. Only the
# LATER one says when the head is A *now* — taking the earliest would date the current head from a
# push that was superseded and then undone, which is the force-push path the issue names.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "#175: the LATEST record for this SHA decides, so a reverse force-push is caught"
has "$OUT" "predates this head" "#175: says WHY the reaction was rejected"

# AN UNESTABLISHED ANCHOR IS `pending`, NEVER `clean` — on BOTH date-scoped signals. One rule over
# both is what keeps the forgeable input out of the file entirely; the findings side pays for it by
# waiting, which is the safe direction.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx                                   # a well-formed EMPTY list: nothing puts this SHA here
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: no activity record for this head -> pending, not clean"
# The diagnostic comes from `adb_head_anchor` itself, and names the ref and SHA it could not date —
# more precise than the paraphrase `classify` used to re-emit from a boolean it carried for the
# purpose. Asserted on the helper's own wording so the message has ONE author.
has "$OUT" "cannot be proved fresh" "#175: names the unestablished anchor rather than 'no signal yet'"
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: the comment path degrades the same way — one rule over both signals"

# A DELETED HEAD REPOSITORY is a real state, not a broken response: the PR reads fine, there is
# simply nowhere left to ask. That is an unestablished anchor (11), not an unreadable one (20).
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --head-slug ""
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: a deleted head repository -> pending"
has "$OUT" "deleted fork" "#175: names the likely cause"
# ...but a head repository that is present and MALFORMED is a broken response, and it is about to be
# interpolated into a URL PATH — a position no other slug in this family occupies (the base slug is
# only ever COMPARED). Being a well-formed `owner/repo` pair is necessary and NOT sufficient:
# `a/..` is a valid pair and a path traversal, so the charset is pinned too.
pr_fx --head-slug "acme/widget/extra"
w observe --pr 1;  rc 20 "#175: a malformed head repository slug -> 20, never a path-injected read"
for bad_slug in 'acme/..' '../widget' 'acme/.' 'acme/wid get' 'acme/wid?et'; do
  pr_fx --head-slug "$bad_slug"
  w observe --pr 1;  rc 20 "#175: head repository '$bad_slug' is refused before it reaches a URL"
done
# ...but a repository whose NAME merely contains dots is a name, not a traversal, and must still be
# queryable. Over-rejecting it would make every date-scoped signal on that PR permanently 20 —
# failure by availability rather than by safety, which is the kind that ships unnoticed.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --head-slug "acme/api..client"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#175: a head repository named 'api..client' is queryable, not a traversal"

# A MIXED-FORMAT activity response is rejected WHOLE, not just at the winner. Ordering first and
# checking only the survivor is unsound — a lexically-later-but-chronologically-EARLIER record can
# win, and an anchor earlier than the truth is the permissive direction.
#
# Read the two values before assuming which one wins: `2026-07-25T04:40:00Z` and
# `2026-07-25T00:42:15-04:00` diverge at index 12 (`4` vs `0`), so the well-formed `…Z` record sorts
# LAST and would be the survivor. A winner-only check would therefore pass this fixture happily,
# which is exactly why it pins the rule: reaching 20 requires validating the record that LOST.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T00:42:15-04:00"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 20 "#175: ONE unorderable timestamp rejects the whole activity read"

# THE SIGNAL THAT NEEDS NO ANCHOR MUST STILL WORK. A review is commit-scoped, so an unestablished
# anchor must not wedge it — otherwise #175 would have traded one fail-open for a total wedge on any
# repo whose activity is unreadable.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "#175: a review at head is SHA-scoped and needs no anchor at all"

# TIMESTAMP FORMAT. A lexicographic compare is chronological ONLY for identical-width `...Z` UTC.
# `2026-07-25T09:00:00-04:00` sorts before `...T05:00:00Z` as a string and after it as an instant,
# and sub-second precision loses to a whole second on a prefix compare. Reject, never normalize.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T00:42:15-04:00"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 20 "#175: an OFFSET anchor timestamp is rejected, not string-compared"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T04:42:15.123Z"
w observe --pr 1;  rc 20 "#175: a SUB-SECOND anchor timestamp is rejected"
# The candidate side too: a comparison is only as sound as its weaker operand.
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "2026-07-25T00:45:23-04:00"
w observe --pr 1;  rc 20 "#175: an OFFSET reaction timestamp is rejected"
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "not-a-timestamp"
w observe --pr 1;  rc 20 "#175: a junk comment timestamp is rejected, not sorted"

# EVERY MALFORMED ANCHOR RESPONSE -> 20. A wrapped error object must not iterate to zero matches and
# read as the much weaker "no anchor here".
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
activity_fx_raw '{"message":"Not Found"}'
w observe --pr 1;  rc 20 "#175: an activity response that is not an array -> 20, not 'no anchor'"
# The fixture above reaches 20 even WITHOUT the `type != "array"` guard — `.[]` over it yields a
# string and the next `select` dies indexing it — so on its own it names a property it does not
# test. This one is an object whose VALUES are well-formed records: without the guard `.[]` walks
# them happily and manufactures an anchor out of a response that was never a list.
activity_fx_raw "{\"a\":{\"after\":\"$HEAD_SHA\",\"ref\":\"refs/heads/$HEAD_REF\",\"timestamp\":\"$BEFORE_AT\"}}"
w observe --pr 1;  rc 20 "#175: an OBJECT of well-formed records is still not an array -> 20"
activity_fx_raw '{ not json at all'
w observe --pr 1;  rc 20 "#175: an unparseable activity response -> 20"

# ============================ 3. the findings signal ============================
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
wout observe --pr 1;  rc 10 "findings: a submitted review AT THE HEAD -> 10"
eq "$OUT" "findings $HEAD_SHA" "findings: stdout is '<verdict> <sha>'"

# A review of an EARLIER commit is not a review of this one — the same rule pr-review.sh applies,
# and observed live on PR #166 (reviewed 5e527689, head moved to d203c1e7).
review_fx "${CODEX}[bot]" "COMMENTED" "$OLD_SHA"
w observe --pr 1;  rc 11 "findings: a review of an OLDER commit does not count"

# CHANGES_REQUESTED is the reviewer having spoken AND not being satisfied — findings.
review_fx "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "findings: CHANGES_REQUESTED at head counts"

# APPROVED IS `clean`, NOT `findings` — CORRECTED BY #167, and it is a real behaviour change rather
# than a test tidy-up. This module used to treat ANY non-PENDING/DISMISSED review at the head as
# findings, so an explicit approval sent `/resolve-pr-threads --watch` off to resolve threads that a
# satisfied reviewer had, by definition, not created. The shared classifier gives one meaning to one
# piece of evidence for BOTH guards (#167 §4): `APPROVED` means the reviewer is satisfied, which is
# exactly what `pr-review.sh gate` has always read it as. The two modules disagreeing about this
# single word is the concrete form of the drift #167 exists to close.
review_fx "${CODEX}[bot]" "APPROVED" "$HEAD_SHA"
wout observe --pr 1;  rc 0 "findings: APPROVED at head is CLEAN, not findings (#167: one meaning per signal)"
eq "$OUT" "clean $HEAD_SHA" "an APPROVED review reports the clean verdict"

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
comment_fx "${CODEX}[bot]" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "task mode: a comment EQUAL to this head's arrival is not proof"

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
printf '101\n' > "$S/comments-total.txt"
w observe --pr 1;  rc 10 "task mode: a TRUNCATED comments connection falls back to the paginated read"

# An unreadable read must fail closed. The three surfaces are ONE read since #174, so the three
# per-endpoint knobs are one — the invariant is unchanged, only the thing that can break it moved.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 w observe --pr 1; rc 20 "unreadable: a failed single-read -> 20"; STUB_GRAPHQL_FAIL=0

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

# ============ 4b. THE DECLARED SET IS AGGREGATED ALL-OR-NOTHING (#185) ============
# THE BUG THIS SECTION EXISTS FOR: every scenario above declares exactly ONE reviewer, and that is
# precisely why #185 shipped unnoticed. This module used to POOL the declared logins on all three
# surfaces — each selector filtered "login is in the declared set" and then reduced across the whole
# set — so ONE fast `+1` from ANY single bot reported `clean` while the others had not looked at the
# PR at all. `pr-review.sh gate` required all of them; the two guards disagreed about HOW MANY
# reviewers must speak, which is orthogonal to #167's "what does a signal MEAN".
#
# Fail-OPEN in the direction that matters: `/resolve-pr-threads --watch` exited reporting a clean
# pass and the operator reasonably concluded review was finished.
#
# The fold is now: any attention/rejection wins outright -> findings; else any unknown -> 20; else
# any reviewer with no signal -> pending; ONLY all-clean -> clean. Note the findings path was
# already correct under "any wins"; it is the CLEAN path that had to become all-or-nothing.
BOT2="gemini-code-assist[bot]"

# #185's FIRST ACCEPTANCE CRITERION, and the one that fails against the shipped code.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#185: two declared, a fresh '+1' from only ONE -> pending, NOT clean"
has "$OUT" "gemini-code-assist" "#185: pending names the reviewer that has not spoken"
hasnt "$OUT" "clean pass" "#185: a partial set is never reported as a pass"

# ...and the control. If this ever fails, the rule above has become "nothing is ever clean".
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT" "$BOT2" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#185: two declared, BOTH signalled clean -> clean"
eq "$OUT" "clean $HEAD_SHA" "#185: the all-clean verdict still prints '<verdict> <sha>'"

# #185's SECOND ACCEPTANCE CRITERION: findings still win outright and IMMEDIATELY. A reviewer with
# something to say must not be held back waiting for a silent sibling — that direction is safe
# (there is work to do either way) and waiting would make the watch useless on a multi-bot repo.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "#185: one reviewer with findings + one silent -> findings, immediately"

# MIXED EVIDENCE ACROSS SURFACES still folds to all-clean: the classes are per-reviewer, so one
# reviewer's `APPROVED` and another's fresh `+1` are both `clean` and the set is satisfied.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "$BOT2" "APPROVED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#185: an APPROVED from one and a fresh '+1' from the other -> clean"

# ONE FRESH, ONE STALE. The stale reviewer's `+1` reviewed an EARLIER commit, so that reviewer has
# said nothing about this head — the set is incomplete and the verdict is pending. This is the case
# a naive `sort | last` over the pooled set gets wrong in the most dangerous way: it would take the
# FRESH timestamp, from a different reviewer entirely, and call the whole set clean.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT" "$BOT2" "+1" "$BEFORE_AT"
w observe --pr 1;  rc 11 "#185: one fresh '+1' and one STALE -> pending (a pooled max would say clean)"
has "$OUT" "predates this head" "#185: the stale reviewer's signal is named as stale"

# CLEAN + UNKNOWN -> fail closed. An unreadable signal must not be outvoted into a pass by a sibling
# that happened to look clean; `unknown` outranks `clean` in the fold for exactly this reason.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "$BOT2" "SOME_NEW_STATE" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 20 "#185: a clean reviewer alongside an UNCLASSIFIABLE one -> 20, never clean"

# ATTENTION + PENDING -> findings. Attention outranks a missing signal: there is work to read now,
# and reporting "still waiting" would bury it.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "#185: a task-mode comment from one + silence from the other -> findings"

# THE SAME REVIEWER ON TWO SURFACES folds WITHIN that reviewer first: a stale `+1` beside a fresh
# APPROVED is that one reviewer being satisfied, so with the set complete the verdict is clean.
# The within-reviewer order and the across-reviewer order differ on exactly this pair.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "${CODEX}[bot]" "APPROVED" "$HEAD_SHA" "$BOT2" "APPROVED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$BEFORE_AT"
wout observe --pr 1;  rc 0 "#185: a STALE '+1' beside that same reviewer's APPROVED is still clean"

# ============================ 5. pagination ============================
# A busy PR can push the bot's reaction off page 1 behind human reactions. A missed `+1` keeps a
# finished watch running to its deadline, so the read must paginate.
reset_fx; declare_bots "[\"$CODEX\"]"
# Since #174 a busy PR reaches the paginated read through TRUNCATION: a GraphQL connection caps at
# 100 records, so a surface whose totalCount exceeds its nodes is re-read through the REST endpoint
# that always paginated. The page-two fixtures below are visible ONLY to that read, which is what
# makes these assertions prove the fallback ran rather than merely that the answer came out right.
_reactions_into "$S/reactions.json" "human-one" "heart" "$AFTER_AT"
_reactions_into "$S/reactions2.json" "$CODEX" "+1" "$AFTER_AT"
printf '101\n' > "$S/reactions-total.txt"
wout observe --pr 1;  rc 0 "pagination: a '+1' behind a truncated connection is still found"

reset_fx; declare_bots "[\"$CODEX\"]"
_reviews_into "$S/reviews.json"  "somebody" "COMMENTED" "$HEAD_SHA"
_reviews_into "$S/reviews2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
printf '101\n' > "$S/reviews-total.txt"
w observe --pr 1;  rc 10 "pagination: a review behind a truncated connection is still found"
has "$OUT" "more than 100 reviews" "the fallback names which surface overflowed"

# An UNTRUNCATED read must not pay for the fallback — the entire point of the collapse.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
wout observe --pr 1;  rc 10 "control: the untruncated single read still classifies"
if called "/pulls/1/reviews"; then bad "an untruncated read must not fall back to the REST surface"; else ok; fi

# ============================ 6. the PR is no longer live ============================
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
w observe --pr 1;  rc 12 "gone: a MERGED PR is terminal"
has "$OUT" "MERGED" "gone: names the merge"
pr_fx --state closed
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
STUB_GRAPHQL_FAIL=1  w observe --pr 1; rc 20 "unreadable: a failed single-read -> 20"; STUB_GRAPHQL_FAIL=0
STUB_EMPTY_GRAPHQL=1 w observe --pr 1; rc 20 "unreadable: an EMPTY response body -> 20"; STUB_EMPTY_GRAPHQL=0

# The anchor read happens ONLY when a date-scoped signal exists, so it needs a `+1` to reach it.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
STUB_FAIL_ACTIVITY=1 w observe --pr 1; rc 20 "unreadable: a failed ref-activity read -> 20 (never clean)"; STUB_FAIL_ACTIVITY=0
# A SUCCESSFUL call that produced no document is not an empty list. Collapsing the two would report
# 11 ("no matching activity") for a broken read, which a caller may sit on rather than escalate.
STUB_EMPTY_ACTIVITY=1 w observe --pr 1; rc 20 "unreadable: an EMPTY activity body is not an empty list -> 20"; STUB_EMPTY_ACTIVITY=0

# ...AND THE SAME ON EVERY SIGNAL SURFACE. `adb_paginated_list` tested its PARSED output, but
# `printf '' | jq -s '[.[][]]'` emits `[]` — so a 200-with-no-document read as "that surface carried
# no records" and the check written to catch it could never fire. Here that hides a reviewer's
# findings and lets a fresh `+1` report a clean pass; on the arming guard the same hole returned 0
# and printed a head SHA. Both directions are the one thing this family must never be wrong about.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx   "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1; rc 10 "control: the findings are seen when the reviews surface reads normally"
# The #174 shape of that same hole: the document arrives, but a CONNECTION is null or malformed.
# A reader that treated a missing `nodes` as an empty list would discard the rejection and let the
# `+1` report clean — and two of these cases DID exactly that before the adapter type-checked
# `nodes` and `totalCount`, which is why each is pinned separately rather than as one case.
_gql_raw() { printf '%s\n' "$1" > "$S/graphql-raw.json"; }
_pr_ok='"state":"OPEN","merged":false,"mergedAt":null,"headRefOid":"'"$HEAD_SHA"'","headRefName":"'"$HEAD_REF"'","baseRepository":{"nameWithOwner":"acme/widget"},"headRepository":{"nameWithOwner":"acme/widget"}'
_rx_fresh='"reactions":{"totalCount":1,"nodes":[{"createdAt":"'"$AFTER_AT"'","user":{"login":"'"$CODEX"'","__typename":"User"}}]}'
_cm_none='"comments":{"totalCount":0,"nodes":[]}'
_rv_none='"reviews":{"totalCount":0,"nodes":[]}'
for broken in '"reviews":null' '"reviews":{"totalCount":0}' '"reviews":{"totalCount":0,"nodes":{}}'; do
  reset_fx; declare_bots "[\"$CODEX\"]"
  _gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$broken"','"$_cm_none"','"$_rx_fresh"'}}}}'
  w observe --pr 1
  rc 20 "a broken reviews connection -> 20; it must NOT let a fresh '+1' report a clean pass ($broken)"
  wout observe --pr 1
  eq "$OUT" "" "...and prints no verdict line ($broken)"
done
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx  "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1; rc 10 "control: the task-mode comment is seen when the comments surface reads normally"
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"',"comments":null,'"$_rx_fresh"'}}}}'
w observe --pr 1; rc 20 "a null comments connection -> 20, not 'that reviewer said nothing'"
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"','"$_cm_none"',"reactions":null}}}}'
w observe --pr 1; rc 20 "a null reactions connection -> 20, not 'no reaction here'"
# A PARTIAL {data,errors} document is the one GraphQL shape with no REST analogue: gh exits
# non-zero AND writes the body, so the adapter rejects `.errors` a second time.
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"','"$_cm_none"','"$_rx_fresh"'}}},"errors":[{"message":"boom"}]}'
STUB_GRAPHQL_RC=0 w observe --pr 1; rc 20 "a PARTIAL {data,errors} response -> 20 even when gh exits 0"
reset_fx; rm -f "$S/graphql-raw.json"

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
pr_fx --base-slug "other/project"
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
# READ `$WATCH_BACKSTOP`'s comment before changing any `--max-secs` here (#394): a case whose oracle
# is a fixture uses the backstop, a case whose oracle IS the deadline uses a small literal, and
# swapping the two is how this section shipped a test that a loaded runner could end early.
#
# Terminal on the first poll: return immediately, and sleep NOT AT ALL. A watcher that sleeps once
# before checking wastes an interval on a PR that was already done.
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "wait: a terminal first poll returns at once"
eq "$OUT" "clean $HEAD_SHA" "wait: emits the same '<verdict> <sha>' contract as observe"
eq "$( [ -f "$S/slept" ] && wc -l < "$S/slept" | tr -d ' ' || echo 0 )" "0" "wait: does not sleep before its first read"

# Pending, then findings: the loop must converge on the LATER answer, not the first one.
reset_fx; declare_bots "[\"$CODEX\"]"
printf '[]\n' > "$S/reviews.1.json"                                  # poll 1: nothing yet
_reviews_into "$S/reviews.2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"   # poll 2: findings
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 10 "wait: converges when the signal appears on a later poll"

# The deadline is a bound. This half of the claim is load-INSENSITIVE by construction: with no
# terminal signal the loop can only ever leave through the deadline, so a slow poll changes WHEN
# it expires and not WHETHER — which is why this case keeps a small literal bound.
reset_fx; declare_bots "[\"$CODEX\"]"
w wait --pr 1 --interval 30 --max-secs 3;  rc 11 "wait: expires at the bound with no terminal signal"
has "$OUT" "handing off" "wait: says it is handing off rather than claiming a verdict"

# The other half — the sleep must never overshoot the bound — USED TO RIDE THE CASE ABOVE, and that
# is the second instance of #394's defect, confirmed by injection rather than assumed: a nap only
# exists when a poll leaves time on the clock, so a first poll costing more than the 3s bound made
# the watch return without sleeping and the assertion could not fire. Measured: a 4s first poll
# against that case turned it red on `expected at least one recorded nap before the bound expired`.
#
# So the clamp gets its own scenario, where the nap is produced by a FIXTURE rather than by a race:
# the PR closes on poll 2, so exactly one nap is taken, and the interval is far larger than the
# bound so that nap must be the clamped value rather than the requested one. Load can only shorten
# what remains — which keeps both assertions true — instead of deleting the nap altogether.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_poll_fx 2 --state closed --merged-at "2026-07-25T05:00:00Z"
w wait --pr 1 --interval 3000 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: the clamp scenario ends on its fixture, not on its deadline"
if [ -f "$S/slept" ]; then
  eq "$(wc -l < "$S/slept" | tr -d ' ')" "1" "wait: took exactly one nap before the terminal poll"
  eq "$(awk -v b="$WATCH_BACKSTOP" '$1 > b {c++} END {print c+0}' "$S/slept")" "0" "wait: never sleeps past the remaining bound"
  # Asserting the clamp FIRED, not merely that nothing exceeded the bound: an unclamped nap would
  # be the requested 3000, and a `<= bound` test alone passes for a watcher that ignored `--interval`
  # entirely. Both directions, so neither a missing clamp nor a missing interval reads as success.
  eq "$(awk -v i=3000 '$1 >= i {c++} END {print c+0}' "$S/slept")" "0" "wait: clamped the oversized interval down to what remained"
else
  bad "wait: expected exactly one recorded nap before the terminal poll"
fi

# A single transient error must not abandon a long watch...
reset_fx; declare_bots "[\"$CODEX\"]"
printf '{ broken\n' > "$S/pr.1.json"                                  # poll 1 unparseable
_reactions_into "$S/reactions.2.json" "$CODEX" "+1" "$AFTER_AT"       # poll 2 fine
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "wait: rides out ONE unreadable poll and converges"

# The deadline can land while the LAST poll was unreadable, and that poll printed no verdict. The
# contract says stdout is "<verdict> <sha>" or nothing — never a bare newline, which a caller doing
# `read -r verdict sha` would silently take as two empty strings rather than "there was no answer".
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 wout wait --pr 1 --interval 1 --max-secs 1;  rc 11 "wait: a bound reached mid-failure still reports pending"
eq "$OUT" "" "wait: prints NO stdout line when the final poll produced no verdict"
STUB_GRAPHQL_FAIL=0

# ...but an endlessly unreadable API must not be polled forever either.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 20 "wait: gives up after consecutive unreadable polls"
has "$OUT" "consecutive unreadable" "wait: names why it gave up"
STUB_GRAPHQL_FAIL=0

# A PR that merges mid-watch stops the loop rather than running to the deadline.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx
pr_poll_fx 2 --state closed --merged-at "2026-07-25T05:00:00Z"
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: stops as soon as the PR stops being open"

# A head that moves mid-watch is reported, and the new head is judged on ITS OWN arrival: a signal
# left in the previous head's era does not carry over.
#
# THE WATCH IS ENDED BY A FIXTURE, NOT BY THE DEADLINE (#394, D85). This case's oracle is a line
# only the SECOND poll can print, and `wait` bounds itself with real elapsed time — so a
# `--max-secs` tight enough to end the watch is also tight enough for a loaded runner to reach
# first. That is what shipped: the bound was 3s, a starved 8-worker CI run spent longer than that
# in poll 1, the watch returned after ONE poll, `rc 11` was satisfied VACUOUSLY, and the only
# failure was the missing message. Measured rather than supposed — injecting a 4s first poll
# reproduces the CI line byte-for-byte, and the poll counter reads 1 instead of 4.
#
# So poll 3 closes the PR. The watch now leaves through a fixture, `--max-secs` is a runaway
# backstop, and the poll count is asserted so a re-tightened bound cannot quietly become the oracle
# again. rc 12 IS the staleness claim rather than a weaker stand-in for rc 11: a `+1` wrongly
# honoured for the new head returns 0 at poll 2 and never reaches poll 3 at all.
# ONE BUILDER FOR BOTH SCENARIOS BELOW, because they must stay the SAME scenario: the second is the
# first with latency injected, and an edit that reached only one of them would leave the injected
# run quietly testing something else while still reporting a pass.
head_move_fx() {
  reset_fx; declare_bots "[\"$CODEX\"]"
  pr_poll_fx 1 --sha "$OLD_SHA"
  pr_poll_fx 2
  pr_poll_fx 3 --state closed --merged-at "2026-07-25T05:00:00Z"
  # BOTH heads are dated, so "the previous head's era" is something the fixture STATES rather than
  # something a comment claims: bbbb arrives at 04:40, aaaa at 04:45, and the `+1` lands at 04:42 —
  # after the head it belongs to, before the head it must not satisfy. Only aaaa's record is READ
  # (the anchor is fetched for the head being judged, and poll 1 carries no dated signal to judge);
  # bbbb's is here so the era is legible, and so an edit that does put a signal on poll 1 finds the
  # anchor it would then need instead of a pending verdict with no anchor behind it.
  activity_fx "$OLD_SHA"  "refs/heads/$HEAD_REF" "$BEFORE_AT" \
              "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT"
  # THE `+1` ARRIVES ON POLL 2, and it has to. With one declared reviewer a `+1` that is genuinely
  # fresh for the old head classifies `clean` on poll 1 and returns 0 there, so the watch could
  # never observe the move at all — which is why the fixture this case used to carry anchored only
  # the NEW head and left poll 1 pending for want of an anchor, testing the staleness rule nowhere.
  _reactions_into "$S/reactions.1.json"      # poll 1: nobody has said anything yet
  reaction_fx "$CODEX" "+1" "$ARRIVED_AT"    # polls 2+
}

head_move_fx
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: a signal from the PREVIOUS head's era does not satisfy the new one"
has "$OUT" "head moved $OLD_SHA -> $HEAD_SHA" "wait: reports that the head moved under it"
has "$OUT" "predates this head's arrival" "wait: says WHY the previous era's signal does not count"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "wait: ended on the fixture's terminal poll, not on its deadline"

# THE SAME CASE, WITH THE FAILURE INJECTED (#394's first acceptance criterion). A first poll costing
# more than the retired 3s bound is exactly the condition a loaded runner produced, and it is the
# condition under which every assertion above used to be unreachable. Re-running the scenario with
# that latency is what turns "it no longer depends on the clock" from a claim into a check — and it
# is the ONE thing the poll-count assertion above cannot do, because a re-tightened `--max-secs`
# still reads 3 polls on an idle machine.
#
# 4 SECONDS, ONCE. It is a real nap, so it is a real cost; it is spent on the one scenario whose
# recorded defect was a slow first poll, and nowhere else.
head_move_fx
printf '4' > "$S/slow-1"
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: a first poll outliving the retired bound no longer ends the watch"
has "$OUT" "head moved $OLD_SHA -> $HEAD_SHA" "wait: still reports the head move when the first poll is slow"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "wait: a slow first poll costs latency, not polls"

# ============ 11b. THE DEADLINE'S CLOCK IS NOT THE ENVIRONMENT'S TO SET (#258) ============
# Every deadline assertion above passes on either clock source, which is exactly why they cannot
# stand in for these. `wait` used to bound itself with `$SECONDS`; it now uses `BASH_MONOSECONDS`.
#
# T1 proves the PROPERTY on this interpreter, at the primitive: `SECONDS` is an ordinary writable
# variable that a caller can move at will, and `BASH_MONOSECONDS` silently refuses assignment WHILE
# IT RETAINS ITS SPECIAL NATURE. That difference is the entire reason for the change, so it is
# asserted rather than assumed — a future bash that made BASH_MONOSECONDS writable would break the
# premise and nothing else here would say so.
#
# The qualifier is load-bearing and not hedging: `unset BASH_MONOSECONDS` strips the special nature,
# after which assignment works normally. That is why the library's comment scopes its guarantee to
# the system clock and to an EXECUTED entry point (which gets the special variable rebuilt), rather
# than claiming nobody can move it.
# `"$BASH"`, NOT a bare `bash` — and this is the very trap the repo's own shell-discipline practice
# documents, reproduced inside a test written to prove a 5.3 property. This script re-execs itself
# onto a >= 5.3 interpreter, but that does NOT rewrite `PATH`: on macOS a bare `bash` still resolves
# `/bin/bash` 3.2.57, which has no `BASH_MONOSECONDS` at all, so the probe answered `100` and the
# whole suite went red for anyone whose PATH did not already carry the Homebrew prefix. `$BASH` is
# the interpreter actually running this file, which is by construction the one the assertion is about.
#
# The second term compares against `m0` rather than a fixed floor: an absolute `> 100` would have
# made the assertion depend on the machine's UPTIME, so it would fail on a freshly booted host.
mono_probe="$("$BASH" -c 'm0=$BASH_MONOSECONDS
                       SECONDS=100000
                       BASH_MONOSECONDS=5 2>/dev/null
                       printf "%s%s%s" "$(( SECONDS >= 100000 ))" "$(( BASH_MONOSECONDS >= m0 ))" "$(( BASH_MONOSECONDS - m0 < 5 ))"' 2>/dev/null)"
eq "$mono_probe" "111" "T1 SECONDS is writable and BASH_MONOSECONDS is not — the premise of the deadline's clock"

# T2 pins that `wait` actually READS that clock. It is a source pin, not a behavioural assertion,
# and the distinction is stated rather than blurred because a pin that looks like a behavioural test
# is worse than one that admits what it is. The suite already pins source this way at the bottom
# (`absent`), for the same reason: some properties have no reachable fixture.
#
# WHY THERE IS NO END-TO-END FIXTURE HERE — this was attempted and discarded, so the next reader
# does not spend the same hour:
#   - A CONSTANT offset does not discriminate. `SECONDS` is inherited from the environment, so a
#     process can start with it anywhere, including near the top of the signed range — but
#     `deadline=$(( SECONDS + max ))` and `$(( deadline - SECONDS ))` overflow SYMMETRICALLY and the
#     wraparound cancels. Measured: with SECONDS=9223372036854775800 and --max-secs 30, `deadline`
#     is -9223372036854775786 and `remaining` is exactly 30. The pre-#258 code was already correct
#     under that, and a fixture built on it PASSES on both clocks while appearing to prove one.
#   - Only a MID-RUN jump separates them, and that needs an in-process assignment to SECONDS. The
#     `gh`/`sleep` stubs are separate processes and cannot reach the watcher's variables.
# So the property lives in T1 and the wiring lives here, and the headline benefit — a wall-clock
# adjustment mid-watch no longer shortens or extends the bound — is REASONED from the two, not
# reproduced. Saying so is better than a green fixture that proves neither half.
#
# ONE CORRECTION, because the first version of this note overstated it. It claimed no behavioural
# fixture was reachable "without a test seam in production code". That is false, and the independent
# review said so: a `DEBUG` trap injected through `BASH_ENV` with function tracing can read
# `BASH_COMMAND` and move `SECONDS` immediately before the old arithmetic, distinguishing the two
# clocks end-to-end with production untouched. It is not built here — it pins the shape of one
# expression through a trap that fires on every command in the file, which is a fixture that breaks
# on any refactor of code it is not even testing — but "we chose not to" and "it cannot be done" are
# different sentences, and only the first one is true.
uses() { if grep -q "$1" "$PW"; then ok; else bad "$2"; fi; }
uses 'BASH_MONOSECONDS' "T2 wait's bound is computed from the monotonic clock"
eq "$(grep -cE '(deadline|remaining)=\$\(\(.*\bSECONDS\b' "$PW")" "0" \
   "T2 ...and no deadline arithmetic reads the movable \$SECONDS any more"

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
# ...and the retired anchor stays retired (#175). Pinned as the JQ PATH and the ENDPOINT rather than
# as prose, so the header may go on explaining WHY the committer date was rejected — which it must,
# or the next reader reaches for the same obvious lower bound — without tripping this rule.
absent 'commit\.committer\.date' "the staleness proof must never return to the client-supplied committer date"
absent 'commits/\$head'          "the head-commit endpoint must not come back as an anchor read"


# ============================ 13. request-review (#169) ============================
# ROUND 2 COULD NOT HAPPEN. A push is not one of the reviewer's triggers, so after a resolve round
# pushes a fix the watch honestly reads `pending` until the bound expires. `request-review` is the
# ask that closes the loop — and it is this module's ONE mutation, so every refusal path matters
# more than the success path: the failure mode of getting it wrong is spamming a reviewer on every
# poll of a half-hour watch.
receipt_fx() { check_pr_receipts_json "$S/receipts.json" "$@"; }
TRIGGER='@codex review'

# --- the happy path: nothing has been asked yet, so ask exactly once --------------------------
# ASSERT THE POST ITSELF, not the module's own diagnostic about it. The stub records every comment
# it is asked to create, so `$S/posted` is evidence a request really crossed the wire and what it
# said — an assertion on the log line alone stays green if `-f body=...` is deleted or the call is
# aimed at a no-op endpoint. Named by the independent review.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: a head with no prior request is asked for once"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "request-review: exactly ONE comment was actually posted"
eq "$(cat "$S/posted")" "$TRIGGER" "request-review: the posted BODY is the reviewer's own documented trigger"
has "$OUT" "round 1 of 3" "request-review: the round is reported against the cap"
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
wout request-review --pr 1
eq "$OUT" "requested $HEAD_SHA" "request-review: stdout is '<verdict> <sha>', like every other verdict here"

# IDEMPOTENCY AS SUCCESS-THEN-REPEAT, which is the property #169 actually states. The stub persists
# the comment it posted into the receipt fixture, so the second invocation reads the receipt THIS
# RUN created rather than one the scenario preloaded. That is the difference between proving
# "a receipt is recognised" and proving "a successful request BECOMES the receipt". Named by the
# independent review, which observed that the earlier pair proved only the first.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0  "idempotency: the first request succeeds"
w request-review --pr 1;  rc 13 "idempotency: the SECOND invocation sees the receipt the first one created"
w request-review --pr 1;  rc 13 "idempotency: and the third"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "idempotency: still exactly one comment on the wire after three calls"

# THE SAME-SECOND BOUNDARY. GitHub timestamps are second-precision, so a request posted moments
# after the push it answers can share a second with the ref-arrival anchor. The receipt comparison
# is INCLUSIVE for exactly this case — treating the tie as "no receipt" posts again, and then again
# on every poll. Note the signal rules deliberately round the OTHER way; see the function header.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_POST_AT="$ARRIVED_AT" w request-review --pr 1;  rc 0 "same-second: the first request is made"
STUB_POST_AT="$ARRIVED_AT" w request-review --pr 1
rc 13 "same-second: a receipt sharing the anchor's second still counts, and is not re-posted"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "same-second: exactly one comment on the wire"

# A FAILED POST IS NOT A MADE REQUEST.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_FAIL_POST=1 w request-review --pr 1;  rc 20 "request-review: a failed POST is 20, never a made request"
STUB_FAIL_POST=0

# THE PR MUST STILL BE OPEN AT THE MOMENT OF THE MUTATION, not merely when it was first read
# (verify-before-asserting.md). Everything above it is read across two or three round trips.
#
# THE FIXTURE MUST CHANGE *UNDER* THE CALLER, or this proves nothing. The obvious version — a PR
# that is closed from the start — is caught by the EARLIER state check and returns 12 either way,
# so it passes with the re-verify deleted. Observed doing exactly that. `rpr.2.json` closes the PR
# on the SECOND receipt read, which is the re-verify.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
check_pr_json "$S/rpr.2.json" --sha "$HEAD_SHA" --state closed --merged-at "2026-07-25T05:00:00Z" \
  --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF"
w request-review --pr 1;  rc 12 "request-review: a PR closed before the POST is not asked"
if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted to a PR that closed under us"; else ok; fi
# ...and the same for a head that moved: asking for a review of a superseded head is noise.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
check_pr_json "$S/rpr.2.json" --sha "$OLD_SHA" --state open --merged-at "" \
  --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF"
w request-review --pr 1;  rc 20 "request-review: a head that moved before the POST is not asked about"
if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted about a superseded head"; else ok; fi
# The control: an UNCHANGED PR still posts, so the re-verify is not simply blocking everything.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0 "control: an unchanged PR still gets its request"

# --- IDEMPOTENCY, the property #169 names explicitly ------------------------------------------
# The receipt is a trigger comment NEWER than this head's arrival. A second observation of the same
# head must not post again, however many polls make it.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$AFTER_AT" "$TRIGGER"
w request-review --pr 1;  rc 13 "request-review: a request already made for THIS head is not repeated"
has "$OUT" "already requested" "request-review: says why nothing was posted"
wout request-review --pr 1
eq "$OUT" "already $HEAD_SHA" "request-review: the idempotent no-op still names the head it is about"
# ...three times in a row, because "at most one per head however many polls observe it" is the claim.
w request-review --pr 1;  rc 13 "request-review: still idempotent on a third observation"

# A request from BEFORE this head arrived is NOT a receipt for it — that is the whole staleness
# rule, applied to the ask instead of to the answer. This is the case a naive "has anyone ever
# commented?" check gets wrong, and getting it wrong means round 2 never happens.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 0 "request-review: a request predating this head does not count as its receipt"

# THE REVIEWER'S OWN BOILERPLATE MUST NOT COUNT AS A RECEIPT. Every lightweight review body quotes
# the trigger list verbatim — 'Comment "@codex review".' — so a SUBSTRING match would read the
# reviewer's own post as this module's request, spend the cap, and never ask at all.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$AFTER_AT" 'Reviews are triggered when you
- Open a pull request for review
- Comment "@codex review".'
w request-review --pr 1;  rc 0 "request-review: the reviewer's own quoted trigger list is not a receipt"
# ...but surrounding whitespace on a real request still is one: the body is TRIMMED, not exact.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$AFTER_AT" "  $TRIGGER
"
w request-review --pr 1;  rc 13 "request-review: a real request with stray whitespace still counts"

# --- THE ROUND CAP ----------------------------------------------------------------------------
# Counted from the PR, at ANY head — anchoring it to the head would reset the cap on every push,
# which is the runaway it exists to bound.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 15 "request-review: the round cap refuses a fourth ask"
has "$OUT" "cap 3" "request-review: the cap is named"
wout request-review --pr 1
eq "$OUT" "capped $HEAD_SHA" "request-review: the capped verdict names the head"
# ...and the cap is configurable, in both directions.
w request-review --pr 1 --max-rounds 4;  rc 0 "request-review: --max-rounds raises the bound"
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1 --max-rounds 1;  rc 15 "request-review: --max-rounds 1 caps after a single ask"
w request-review --pr 1 --max-rounds 0;  rc 2  "request-review: --max-rounds 0 is a usage error, not an infinite loop"
w request-review --pr 1 --max-rounds x;  rc 2  "request-review: a non-numeric --max-rounds is rejected"

# --- A REVIEWER WITH NO KNOWN TRIGGER IS SKIPPED, NOT FAILED ----------------------------------
# #169 requires exactly this: no request, no error. Posting a guessed phrase at an unknown bot is
# spam nobody asked for.
reset_fx; declare_bots '["some-other-reviewer"]'; receipt_fx
w request-review --pr 1;  rc 14 "request-review: a declared reviewer with no known trigger is skipped"
has "$OUT" "no declared reviewer has a re-review trigger" "request-review: says why it skipped"
reset_fx; declare_bots '[]'; receipt_fx
w request-review --pr 1;  rc 14 "request-review: bots = [] has nobody to ask"
# ...and it prints NO verdict line: the head SHA is not known on that path (reading it would spend
# a call on a repo that just said nobody is coming), and stdout is contracted to be
# "<verdict> <sha>" or nothing — never a verdict with an empty second field.
wout request-review --pr 1
eq "$OUT" "" "request-review: bots = [] prints no verdict line rather than one with an empty SHA"
# ...and a KNOWN reviewer beside an unknown one is still asked.
reset_fx; declare_bots "[\"$CODEX\", \"some-other-reviewer\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: a known trigger beside an unknown reviewer still asks"

# The trigger table tolerates BOTH spellings of the same App, because GraphQL and REST disagree
# about the `[bot]` suffix and a table that knew only one would silently stop firing (#173/D79).
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: the '[bot]'-suffixed spelling resolves the same trigger"
reset_fx; declare_bots '["CHATGPT-Codex-Connector"]'; receipt_fx
w request-review --pr 1;  rc 0 "request-review: the trigger lookup is case-insensitive"

# --- EVERY UNREADABLE PATH REFUSES TO ASK -----------------------------------------------------
# The dangerous direction here is the OPPOSITE of the classifier's: an unprovable receipt must
# never read as "not yet asked", because that re-posts on every poll.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_GRAPHQL_FAIL=1 w request-review --pr 1; rc 20 "request-review: an unreadable read refuses to ask"; STUB_GRAPHQL_FAIL=0
STUB_FAIL_ACTIVITY=1 w request-review --pr 1
rc 20 "request-review: an unreadable ANCHOR refuses to ask — an undatable receipt is not 'no receipt'"
STUB_FAIL_ACTIVITY=0
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
activity_fx "$OLD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"   # nothing puts THIS head on the ref
w request-review --pr 1;  rc 20 "request-review: an UNESTABLISHED anchor refuses to ask"
# THE RECEIPT CONNECTION IS TYPE-VALIDATED, exactly like the classification snapshot, and here the
# direction it protects is POSTING: `// 0` / `// []` would read a malformed read as "no comments",
# which reads as "nobody has asked" and posts again on every poll. Found by the independent review.
for broken in '{"comments":{"totalCount":0}}' '{"comments":{"totalCount":0,"nodes":{}}}' \
              '{"comments":null}' '{"comments":{"totalCount":-1,"nodes":[]}}'; do
  reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
  printf '%s\n' "$broken" > "$S/receipts-raw.json"
  w request-review --pr 1
  rc 20 "request-review: a broken receipt connection refuses to ask ($broken)"
  if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted on an unreadable receipt read ($broken)"; else ok; fi
  rm -f "$S/receipts-raw.json"
done
# A comment carrying no usable createdAt cannot be dated against the anchor, so it can be neither
# honoured as a receipt nor dismissed as absent.
reset_fx; declare_bots "[\"$CODEX\"]"
printf '%s\n' '{"comments":{"totalCount":1,"nodes":[{"body":"@codex review"}]}}' > "$S/receipts-raw.json"
w request-review --pr 1;  rc 20 "request-review: a receipt with no createdAt refuses to ask"
rm -f "$S/receipts-raw.json"

# More than 100 comments means the receipt cannot be proved absent -> refuse, never re-ask.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
printf '101\n' > "$S/receipts-total.txt"
w request-review --pr 1;  rc 20 "request-review: a comment page it cannot see through refuses to ask"
rm -f "$S/receipts-total.txt"

# --- A DEAD PR IS NOT ASKED FOR A REVIEW ------------------------------------------------------
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
w request-review --pr 1;  rc 12 "request-review: a merged PR is not asked for a re-review"

# --- the declaration tri-state, and argument handling -----------------------------------------
reset_fx; undeclare; receipt_fx
w request-review --pr 1;  rc 17 "request-review: an UNDECLARED repo fails closed like every other read here"
reset_fx; printf '%s\n' '[reviewers]' 'bots = ["unterminated' > "$REPO/agents.toml"
w request-review --pr 1;  rc 18 "request-review: a malformed declaration is 18, not a guess"
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review;         rc 2  "request-review: --pr is required"
w request-review --pr 0;  rc 2  "request-review: a PR number of 0 is rejected"
w request-review --pr https://github.com/other/repo/pull/7
rc 2 "request-review: a URL naming ANOTHER repository is refused, before anything is posted"

# --- the mutation itself is bounded ------------------------------------------------------------
# One comment per DISTINCT phrase: two spellings of one App must not produce two comments.
reset_fx; declare_bots "[\"$CODEX\", \"${CODEX}[bot]\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: two spellings of one App still ask once"
eq "$(grep -c "requested a re-review" <<<"$OUT")" "1" "request-review: exactly one comment is posted"
reset_fx

check_summary "pr-watch"
