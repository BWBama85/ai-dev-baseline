#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the /resolve-pr-threads decision predicates
# (scripts/lib/pr-threads.sh, #416 + #418). OFFLINE: no network, no gh auth, no real repo touched.
#
# THE ONE DANGEROUS DIRECTION IS REPORTING FEWER THREADS THAN EXIST, and #418 is the worked example
# of how that ships green: both reads were `reviewThreads(first:50)` with no cursor, the connection
# is OLDEST-FIRST, and the step-6 "remaining unresolved" check re-used the same truncating window —
# so the guard that exists to catch a short read CONFIRMED it. On the live pull request that found
# it, 54 threads existed, 5 were seen, 5 were resolved, and the check said "0 remaining" while four
# of the current review's findings sat unaddressed.
#
# Every case below is a way that could happen again:
#
#   1. PAGINATION. A pull request past one page is enumerated COMPLETELY, and the cursor loop is
#      shown ITERATING — the 154-thread fixture needs two pages, and the call recorder proves the
#      second was fetched WITH THE CURSOR rather than page one being read twice.
#   2. THE NEWEST ARE THE ONES AT RISK, so completeness is asserted by IDENTITY and not only by
#      count: the highest-numbered thread must be present. A count-only assertion passes on a
#      re-served page one, which is the shape that made #418 invisible.
#   3. THE COMPLETENESS PROOF MUST BE ABLE TO FIRE. A `totalCount` above what the pages carried,
#      a repeated page, a non-advancing cursor and a `hasNextPage` with no cursor are all 19 —
#      never a lower count, and never "0 remaining".
#   4. ONE READ SERVES BOTH CONSUMERS. `list` and `remaining` share one fetch, so the check can no
#      longer be evaluated inside a window narrower than the pass it is policing.
#   5. INFERENCE NEVER GUESSES. Exactly one open pull request is the answer; zero and two-or-more
#      are refusals with distinct codes, and the ambiguous arm lists candidates in a deterministic
#      order.
#   6. THE ALLOWLIST IS THE RESOLVER'S, NOT THE MERGE GUARDS'. Exact, anchored, case-insensitive —
#      and `bots = []` must classify NOTHING as a bot, because jq's `test("")` matches every string.
#      That trap used to be a COMMENT in the workflow beside a default nothing could exercise.
#   7. EVERY UNREADABLE PATH -> 19, 20 or 2, never a count. A failed read must not look like a pull
#      request with no threads.
#
# `--mutation` drives the pagination and completeness cases against deliberately broken copies and
# requires each to come back RED on its OWN witness (#213's `fires:` contract, #394's precedent):
# these are guards, and a guard's failure mode is silence.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pr-threads.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec. Before `set -u`, because an unbound expansion while
# a library loads is FATAL under it and would kill the suite with a message about a variable rather
# than about the library. And the load is confirmed by PROBING FOR THE FUNCTION, not by the
# source's exit status: a partially-loaded library can still exit 0.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-pr-threads: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-pr-threads: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -gt 1 ] && { echo "usage: check-pr-threads.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-pr-threads.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
# A SUITE THAT SKIPS ITS OWN VERDICT MUST NOT REPORT SUCCESS: `--mutation` exits after its own
# `check_summary`, and an edit that lost that call would exit 0 having counted nothing.
check_exit_guard "check-pr-threads" "rm -rf \"$work\""

# ============= --mutation: the completeness cases must be OBSERVED going red (#418) =============
# WHY A MODE AND NOT MORE ASSERTIONS. These cases can pass while looking at nothing — a green is not
# by itself evidence that anything was checked (D85). So each row breaks ONE thing the suite claims
# to catch, runs the WHOLE suite against the broken copy, and requires it back at exit 1 carrying
# THAT ROW'S OWN witness.
if [ "$MODE" = mutation ]; then
  # mut_run <copy-dir> — the nested suite, behind a parse check. A mutation that stops the file
  # PARSING has changed whether the code runs at all rather than how it behaves, and the nested
  # suite would still fail on the right witness — crediting the row for a defect it never
  # exercised. 9 makes the pool report an ABORT, which is what it was.
  #
  # `"$BASH"`, not a bare `bash`: this file has re-exec'd itself onto a >= 5.3 interpreter but did
  # NOT rewrite PATH, so on macOS a bare `bash` still resolves /bin/bash 3.2.57, and parse-checking
  # a 5.3 file with 3.2 asks the wrong question.
  mut_run() {
    local d="$1"
    "$BASH" -n "$d/scripts/lib/pr-threads.sh" 2>/dev/null \
      || { printf 'the mutated pr-threads.sh no longer PARSES\n'; return 9; }
    "$BASH" "$d/scripts/check-pr-threads.sh" 2>&1
  }
  # `scripts` alone is this suite's whole mutation surface, so the subtree copier rather than the
  # worktree one: copies of the repo's .git would be spent moving a tree about to be deleted.
  mut_prep() { check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1 || return 1
               printf '%s' "$1/scripts/lib/pr-threads.sh"; }

  # THE CONTROL RUNS FIRST, and the reason is causal rather than ceremonial. `_check_mut_witness`
  # only asks whether SOME `FAIL:` line carries the row's witness, so a copied baseline that already
  # fails on that witness would credit the row for a defect the mutation never caused — and this
  # mode is runnable standalone, where no sibling selfcheck step is watching the unmutated tree.
  mut_ctl="$work/control"
  if mut_prep "$mut_ctl" >/dev/null; then
    mut_out="$(mut_run "$mut_ctl" 2>&1)"; mut_rc=$?
    yes "$mut_rc" "control: an UNMUTATED copy passes (else every row below is red for the wrong reason)"
    case "$mut_out" in
      *" 0 failed"*) ok ;;
      *) bad "control: the unmutated copy did not report a clean suite" ;;
    esac
  else
    bad "control: could not build the unmutated copy"
  fi

  # #418 ITSELF, injected at its source: the cursor loop stops after page one. The 154-thread
  # fixture then reads 100 of 154 — and the threads it drops are the NEWEST, which is why the
  # witness is the identity assertion and not merely the count.
  check_mut "no-pagination" \
    '[ "$more" = "true" ] || break' \
    'break' \
    'list: a 154-thread PR carries its NEWEST thread'
  # The cursor is computed but never SENT, so every request re-fetches page one. This is the row
  # that proves the stub is keyed on the cursor rather than on a call counter: without it a stub
  # that served page 2 on the second call regardless would keep this green.
  check_mut "cursor-dropped" \
    'curarg=(-f "endCursor=$cursor")' \
    'curarg=()' \
    'list: a 154-thread PR carries its NEWEST thread'
  # THE COMPLETENESS PROOF ITSELF. With the comparison disabled a short read reports a count — the
  # "0 remaining" over unaddressed findings that #418 observed live.
  check_mut "short-read-silent" \
    'if [ "$got" -lt "$total" ]; then' \
    'if false; then' \
    'remaining: a short read REFUSES rather than reporting a count'
  # ...and its identity half: a page served twice satisfies `read >= totalCount` while carrying
  # none of the newest threads, so arithmetic alone is not completeness.
  check_mut "duplicate-page-accepted" \
    'if [ "$uniq" -ne "$got" ]; then' \
    'if false; then' \
    'list: a repeated page is refused, not counted as completeness'
  check_mutation_pool "pr-threads" "$work/mt" mut_prep mut_run 4
  check_summary "check-pr-threads --mutation"
  exit 0
fi

# ==================================== the fixture =============================================
S="$work/state"; SBIN="$work/bin"; REPO="$work/repo"; GHOME="$work/home"
mkdir -p "$S" "$SBIN" "$REPO" "$GHOME/.config/ai-dev-baseline"

CODEX=chatgpt-codex-connector
LIB="$ROOT/scripts/lib/pr-threads.sh"

# A real git repo whose `origin` names the slug the stub answers for: `adb_pr_slug_check` anchors
# every read to the CHECKOUT's remote set, so a fixture without one refuses everything and the
# suite would be green for the wrong reason.
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/acme/widget.git

# ------------------------------- the recording gh stub ----------------------------------------
# ORDERING IS LOAD-BEARING: `pr` and `auth` are matched before `api`, and the graphql arm is matched
# on `$2` before any URL arm — a GraphQL call carries no `repos/...` argument at all and would
# otherwise fall through to the catch-all and answer empty, which the module reads as unreadable.
#
# PAGES ARE KEYED BY CURSOR, never by a call counter, and that is what makes the `cursor-dropped`
# mutation row meaningful: a stub that served page 2 on the second call regardless would stay green
# with the cursor dropped, so it would be testing the fixture rather than the code.
check_write_stub "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Knobs:
#   STUB_FAIL_PRLIST=1   -> `gh pr list` fails
#   STUB_BAD_PRLIST=1    -> it succeeds with a non-array document
#   STUB_EMPTY_PRLIST=1  -> it succeeds with an EMPTY body (not `[]`)
#   STUB_FAIL_GQL=1      -> the thread read fails
#   STUB_EMPTY_GQL=1     -> the thread read succeeds with an empty body
case "${1:-}" in
  auth) exit 0 ;;
  pr)
    printf '%s\n' "$*" >> "$W/gh-argv"
    [ "${STUB_FAIL_PRLIST:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_PRLIST:-0}" = "1" ] && exit 0
    printf 'pr-list\n' >> "$S/calls"
    if [ "${STUB_BAD_PRLIST:-0}" = "1" ]; then printf '{"oops":true}\n'; exit 0; fi
    cat "$S/prlist.json"; exit 0 ;;
  api) ;;
  *) exit 0 ;;
esac
if [ "${2:-}" = "graphql" ]; then
  [ "${STUB_FAIL_GQL:-0}" = "1" ] && exit 1
  [ "${STUB_EMPTY_GQL:-0}" = "1" ] && exit 0
  _cur=""
  for a in "$@"; do case "$a" in endCursor=*) _cur="${a#endCursor=}" ;; esac; done
  [ -n "$_cur" ] || _cur=1
  printf 'graphql:%s\n' "$_cur" >> "$S/calls"
  if [ -f "$S/page-$_cur.json" ]; then cat "$S/page-$_cur.json"; else printf '\n'; fi
  exit 0
fi
exit 0
STUB

# pt <args…> — run the library against the fixture. stdout in $OUT, stderr in $ERR, status in $RC.
# `cd "$REPO"`, because both `adb_repo_root` (which locates agents.toml) and `adb_git_repo_slugs`
# (which anchors the repository identity check) read the CURRENT checkout.
OUT=""; ERR=""; RC=0
pt() {
  OUT="$( cd "$REPO" && S="$S" W="$work" HOME="$GHOME" PATH="$SBIN:$PATH" \
          bash "$LIB" "$@" 2>"$work/err" )"
  RC=$?
  ERR="$(cat "$work/err")"
}
reset_fx()     { rm -f "$S"/calls "$S"/page-*.json "$S"/prlist.json "$work"/gh-argv; }
declare_bots() { printf '%s\n' '[reviewers]' "bots = $1" > "$REPO/agents.toml"; }
calls_for()    { if [ -f "$S/calls" ]; then grep -c "^$1\$" "$S/calls"; else printf '0\n'; fi; }

# mkpage <cursor-key> <totalCount> <hasNextPage> <nextCursor> <from> <count> [author] [resolved]
#         [comments-total] [slug]
#   One GraphQL page document. Thread ids are `T<n>` and n increases with the page, so the fixture
#   reproduces #418's property — the threads a truncating read drops are the NEWEST — and a test can
#   assert WHICH threads are missing rather than only how many.
mkpage() {
  jq -n --arg key "$1" --argjson total "$2" --argjson more "$3" --arg next "$4" \
        --argjson from "$5" --argjson count "$6" \
        --arg who "${7:-chatgpt-codex-connector}" --argjson resolved "${8:-false}" \
        --argjson ctotal "${9:-1}" --arg slug "${10:-acme/widget}" '
    { data: { repository: { pullRequest: {
        baseRepository: { nameWithOwner: $slug },
        reviewThreads: {
          totalCount: $total,
          pageInfo: { hasNextPage: $more, endCursor: $next },
          nodes: [ range($from; $from + $count) as $i | {
            id: "T\($i)", isResolved: $resolved, isOutdated: false,
            comments: { totalCount: $ctotal, nodes: [ {
              id: "C\($i)", author: { login: $who }, path: "a.txt", line: $i,
              body: "finding \($i)", createdAt: "2026-08-20T00:00:00Z" } ] } } ] } } } } }' \
    > "$S/page-$1.json"
}

# ================================ infer-pr: never a guess (#416) ===============================
declare_bots "[\"$CODEX\"]"

reset_fx
printf '%s\n' '[{"number":42,"title":"the one","headRefName":"feat","isDraft":false,"url":"https://x/42"}]' > "$S/prlist.json"
pt infer-pr
eq "$RC" "0"  "infer-pr: exactly one open PR is the answer"
eq "$OUT" "42" "infer-pr: it prints the bare number, for a caller to pass downstream"

reset_fx; printf '%s\n' '[]' > "$S/prlist.json"
pt infer-pr
eq "$RC" "10" "infer-pr: zero open PRs is a refusal (10), not an empty answer"
has "$ERR" "no open pull request" "infer-pr: the zero arm says what is wrong"

# TWO OR MORE IS A REFUSAL, NOT A CHOICE. Resolving is a MUTATION — a guess that picks wrong
# replies on and resolves the threads of a pull request nobody asked about.
reset_fx
printf '%s\n' '[{"number":9,"title":"nine","headRefName":"b9","isDraft":true,"url":"https://x/9"},
                {"number":7,"title":"seven","headRefName":"b7","isDraft":false,"url":"https://x/7"}]' > "$S/prlist.json"
pt infer-pr
eq "$RC" "11" "infer-pr: two open PRs refuse (11) rather than picking one"
eq "$OUT" ""  "infer-pr: the ambiguous arm prints NO number — a caller reading stdout gets nothing to act on"
has "$ERR" "#7"      "infer-pr: the refusal lists the candidates"
has "$ERR" "#9"      "infer-pr: ...all of them"
has "$ERR" "[draft]" "infer-pr: ...and marks a draft, which is still an open PR with threads"
has "$ERR" "https://x/7" "infer-pr: ...with a URL, so the refusal is actionable"
# DETERMINISTIC ORDER, so the refusal is a contract rather than whatever the API answered in.
case "$ERR" in *"#7"*"#9"*) ok ;; *) bad "infer-pr: candidates are not sorted numerically" ;; esac

# THE LIST IS SCOPED TO THIS CHECKOUT'S REPOSITORY, EXPLICITLY. A bare `gh pr list` resolves the
# repository from gh's own rules, which `GH_REPO` silently redirects — and the number it would then
# return is a FOREIGN pull request's, handed straight to `list --pr`, which resolves the slug from
# the git remote and applies that number to the LOCAL repository. Two individually-correct halves
# that mis-target as a pair. Every other read here cross-checks the slug it was answered by; this is
# the one with no answer to cross-check, so it must NAME the repository up front.
reset_fx
printf '%s\n' '[{"number":42,"title":"the one","headRefName":"feat","isDraft":false,"url":"https://x/42"}]' > "$S/prlist.json"
pt infer-pr
_scoped="$(grep -c -- '--repo acme/widget' "$work/gh-argv" 2>/dev/null || printf '0')"
if [ "$_scoped" -ge 1 ]; then ok; else bad "infer-pr: the PR list is not scoped to the checkout's own repository (GH_REPO could redirect it)"; fi

reset_fx; printf '%s\n' '[]' > "$S/prlist.json"
STUB_FAIL_PRLIST=1 pt infer-pr
eq "$RC" "20" "infer-pr: an unreadable list is 20, never 'no open PRs'"
STUB_BAD_PRLIST=1 pt infer-pr
eq "$RC" "20" "infer-pr: a non-array document is 20, not silently zero"
STUB_EMPTY_PRLIST=1 pt infer-pr
eq "$RC" "20" "infer-pr: an EMPTY body is 20 — a successful call that produced no document is not '[]'"

# =============== list / remaining: the complete enumeration (#418) ==============================
# ONE PAGE, the ordinary case. 6 threads, totalCount 6.
reset_fx; mkpage 1 6 false "" 0 6
pt list --pr 1
eq "$RC" "0" "list: a single-page PR reads cleanly"
eq "$(printf '%s' "$OUT" | jq -r .total)" "6" "list: it reports every thread"
eq "$(calls_for 'graphql:1')" "1" "list: one page costs exactly one read"

# >50 THREADS — the size that found the bug. Still one page here (the page size is 100), which is
# the point: 54 is complete WITHOUT pagination, so a suite that only tested 54 would prove nothing
# about the cursor. That is what the 154 case below is for.
reset_fx; mkpage 1 54 false "" 0 54
pt list --pr 1
eq "$RC" "0" "list: a 54-thread PR (the size that found #418) reads completely"
eq "$(printf '%s' "$OUT" | jq -r .total)" "54" "list: all 54 threads"
has "$OUT" '"T53"' "list: a 54-thread PR carries its NEWEST thread"

# >100 THREADS — TWO PAGES, so the cursor loop must iterate. The assertion that matters is IDENTITY:
# T153 is the newest, and it exists only on page two. A count-only assertion passes on a re-served
# page one, which is exactly the shape that made #418 invisible.
reset_fx
mkpage 1   154 true  c2 0   100
mkpage c2  154 false ""  100 54
pt list --pr 1
eq "$RC" "0" "list: a 154-thread PR reads completely across two pages"
eq "$(printf '%s' "$OUT" | jq -r .total)" "154" "list: all 154 threads"
has "$OUT" '"T153"' "list: a 154-thread PR carries its NEWEST thread"
has "$OUT" '"T0"'   "list: ...and its oldest"
eq "$(calls_for 'graphql:1')"  "1" "list: page one is fetched once"
eq "$(calls_for 'graphql:c2')" "1" "list: page two is fetched WITH THE CURSOR (proving the loop advances)"

# ...and `remaining` shares that read, which is the half #418 is really about: the sanity check can
# no longer be evaluated inside a window narrower than the pass it polices.
reset_fx
mkpage 1   154 true  c2 0   100
mkpage c2  154 false ""  100 54
pt remaining --pr 1
eq "$RC" "0"    "remaining: reads across two pages too"
eq "$OUT" "154" "remaining: it counts every unresolved bot thread, not one page's worth"
eq "$(calls_for 'graphql:c2')" "1" "remaining: the check follows the cursor as well"

# --- THE SHORTFALL IS A HARD ERROR ------------------------------------------------------------
# The exact #418 arithmetic: a page carrying 50 of a declared 101, with no further page. Under the
# old code this is what printed "0 remaining".
reset_fx; mkpage 1 101 false "" 0 50
pt list --pr 1
eq "$RC" "19" "list: a short read is exit 19, not a shorter list"
eq "$OUT" ""  "list: ...and prints NO document, so a caller cannot act on a partial one"
has "$ERR" "read 50 of totalCount 101" "list: the refusal names the shortfall in both numbers"
pt remaining --pr 1
eq "$RC" "19" "remaining: a short read REFUSES rather than reporting a count"
eq "$OUT" ""  "remaining: ...and prints no count at all, never '0'"

# A `hasNextPage: true` with no cursor cannot be followed — refuse rather than stop one page short.
reset_fx; mkpage 1 154 true "" 0 100
pt list --pr 1
eq "$RC" "19" "list: 'more threads' with no cursor is a refusal, not a silent stop"
has "$ERR" "carries no cursor" "list: ...and says which"

# A cursor that does not ADVANCE would re-fetch one page until the ceiling; caught at the cursor.
reset_fx; mkpage c9 154 true c9 0 100
cp "$S/page-c9.json" "$S/page-1.json"
# page 1 hands back cursor c9; page c9 hands back c9 again.
jq '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor = "c9"' "$S/page-1.json" > "$S/t" && mv "$S/t" "$S/page-1.json"
pt list --pr 1
eq "$RC" "19" "list: a cursor that does not advance is a refusal, not an infinite loop"
has "$ERR" "did not advance" "list: ...and says which"

# A REPEATED PAGE SATISFIES THE ARITHMETIC WHILE CARRYING NONE OF THE NEWEST THREADS. `read >=
# totalCount` is true here (200 >= 154) and every id is a duplicate, so identity is what catches it.
reset_fx
mkpage 1  154 true  c2 0 100
mkpage c2 154 false ""  0 100
pt list --pr 1
eq "$RC" "19" "list: a repeated page is refused, not counted as completeness"
has "$ERR" "distinct ids" "list: ...and says the pages overlapped"

# --- EVERY UNREADABLE PATH REFUSES ------------------------------------------------------------
reset_fx; mkpage 1 6 false "" 0 6
STUB_FAIL_GQL=1 pt list --pr 1
eq "$RC" "20" "list: an unreadable read is 20, never an empty thread list"
STUB_EMPTY_GQL=1 pt list --pr 1
eq "$RC" "20" "list: an EMPTY body is 20 — a successful call that produced no document is not 'no threads'"
STUB_FAIL_GQL=1 pt remaining --pr 1
eq "$RC" "20" "remaining: an unreadable read is 20, never a count"

# A document carrying GraphQL `errors` is not a page, however well-formed the rest looks.
reset_fx; mkpage 1 6 false "" 0 6
jq '. + {errors:[{message:"boom"}]}' "$S/page-1.json" > "$S/t" && mv "$S/t" "$S/page-1.json"
pt list --pr 1
eq "$RC" "20" "list: a document carrying GraphQL errors is unreadable, not an empty page"

# A connection with no totalCount must not read as zero — `// 0` is the fail-open this rejects.
reset_fx; mkpage 1 6 false "" 0 6
jq 'del(.data.repository.pullRequest.reviewThreads.totalCount)' "$S/page-1.json" > "$S/t" && mv "$S/t" "$S/page-1.json"
pt list --pr 1
eq "$RC" "20" "list: a connection with no totalCount is unreadable, not complete-by-default"
reset_fx; mkpage 1 6 false "" 0 6
jq 'del(.data.repository.pullRequest.reviewThreads.nodes)' "$S/page-1.json" > "$S/t" && mv "$S/t" "$S/page-1.json"
pt list --pr 1
eq "$RC" "20" "list: a connection with no nodes array is unreadable, not empty"

# --- THE READS MUST ADDRESS THIS REPOSITORY ---------------------------------------------------
# The caller REPLIES ON and RESOLVES the ids this returns, so answering about another repository is
# a mutation on a stranger's pull request.
reset_fx; mkpage 1 6 false "" 0 6 "$CODEX" false 1 "someone/else"
pt list --pr 1
eq "$RC" "2" "list: a response naming another repository is refused"
has "$ERR" "refusing" "list: ...and says so"

# ============================= the resolvable-bot allowlist ====================================
# EXACT, ANCHORED, CASE-INSENSITIVE — the RESOLVER's rule, not the merge guards' asymmetric one.
reset_fx; declare_bots "[\"$CODEX\"]"; mkpage 1 2 false "" 0 2 "$CODEX"
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '[.threads[]|select(.is_bot)]|length')" "2" \
   "list: a declared login classifies as a bot"
reset_fx; mkpage 1 2 false "" 0 2 "some-human"
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '[.threads[]|select(.is_bot)]|length')" "0" \
   "list: an undeclared login is never a bot"
pt remaining --pr 1
eq "$OUT" "0" "remaining: a human thread is not counted"
# CASE-INSENSITIVE...
reset_fx; mkpage 1 1 false "" 0 1 "Chatgpt-Codex-Connector"
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].is_bot')" "true" "list: the match is case-insensitive"
# ...but ANCHORED: a login that merely CONTAINS a declared one is not it.
reset_fx; mkpage 1 1 false "" 0 1 "evil-$CODEX-x"
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].is_bot')" "false" \
   "list: the match is anchored — a login containing a declared one is not a match"

# `bots = []` MUST CLASSIFY NOTHING. jq's `test("")` matches EVERY string, so an empty allowlist
# handed straight to the matcher would mark every thread a bot and auto-resolve a human's. That
# trap used to live as a COMMENT in the workflow, beside a default nothing could exercise.
reset_fx; declare_bots '[]'; mkpage 1 3 false "" 0 3 "$CODEX"
pt list --pr 1
eq "$RC" "0" "list: bots = [] still enumerates (the disable is about resolving, not reading)"
eq "$(printf '%s' "$OUT" | jq -r '[.threads[]|select(.is_bot)]|length')" "0" \
   "list: bots = [] classifies NOTHING as a bot (test(\"\") must not match every login)"
pt remaining --pr 1
eq "$OUT" "0" "remaining: bots = [] counts nothing"

# A MALFORMED DECLARATION IS 18, AND IT IS REPORTED BEFORE THE NETWORK. An operator should not wait
# for an enumeration whose classification was never going to work.
reset_fx; printf '%s\n' '[reviewers]' 'bots = "not-an-array"' > "$REPO/agents.toml"
pt list --pr 1
eq "$RC" "18" "list: a malformed [reviewers] bots is 18"
eq "$(calls_for 'graphql:1')" "0" "list: ...and nothing was read — the manifest is checked first"
pt remaining --pr 1
eq "$RC" "18" "remaining: a malformed [reviewers] bots is 18 there too"

# =============================== the per-thread comment page ===================================
# The contract is narrowed, not the number raised: classification is the HEAD comment (complete by
# construction), context is up to ten, and TRUNCATION IS VISIBLE so an agent knows there is a rest.
reset_fx; declare_bots "[\"$CODEX\"]"; mkpage 1 1 false "" 0 1 "$CODEX" false 25
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].comments_total')"     "25"   "list: a thread reports how many comments it HAS"
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].comments_read')"      "1"    "list: ...and how many were read"
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].comments_truncated')" "true" "list: ...and flags the difference, rather than hiding it"
reset_fx; mkpage 1 1 false "" 0 1 "$CODEX" false 1
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r '.threads[0].comments_truncated')" "false" \
   "list: an untruncated thread is not flagged"

# ================================= resolved vs unresolved =====================================
reset_fx; mkpage 1 4 false "" 0 4 "$CODEX" true
pt remaining --pr 1
eq "$OUT" "0" "remaining: already-resolved threads are not remaining"
pt list --pr 1
eq "$(printf '%s' "$OUT" | jq -r .total)" "4" "list: ...but list still reports them (idempotency needs to see them)"

# ======================================== usage ================================================
pt list
eq "$RC" "2" "list without --pr is a usage error, never an implicit target"
pt remaining
eq "$RC" "2" "remaining without --pr is a usage error"
pt list --pr ""
eq "$RC" "2" "an empty --pr is rejected on its VALUE, not its arity"
pt list --pr abc
eq "$RC" "2" "a non-numeric --pr that names no repository is rejected"
pt bogus
eq "$RC" "2" "an unknown subcommand is a usage error"
pt list --pr 1 --nope
eq "$RC" "2" "an unknown option is a usage error"

check_summary "check-pr-threads"
