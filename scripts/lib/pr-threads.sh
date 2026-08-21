#!/usr/bin/env bash
# ai-dev-baseline — /resolve-pr-threads' decision predicates (issues #416, #418).
#
# /resolve-pr-threads is prose an agent executes, so its load-bearing READS lived only as inline
# `gh api graphql` blocks in the skill body — unexecutable, and therefore untestable. This library is
# the ONE home for those decisions so they can be regression-tested offline
# (scripts/check-pr-threads.sh) and CITED by the workflow rather than restated: the DRY discipline of
# docs/design-principles.md, and the same split cleanup-lib.sh makes for /cleanup.
#
# A truncated thread read is observable to nobody: it prints what a clean run prints. The incident
# that proved it, and the alternatives weighed against this design, are in D86.
#
# WHY NOT pr-watch.sh. That module's header states its own boundary — "it does not resolve threads,
# edit code, push, or merge" — and enumerating the threads a resolver is about to reply on and
# resolve is resolver work. Growing it there would break a stated contract rather than respect it.
# `pr-watch.sh` answers "is the reviewer DONE, and with what?"; this module answers "WHICH threads
# are there, and which of them may I touch?"
#
# ------------------------------------------------------------------------------------------------
# THE CONTRACT: A READ EITHER PROVES ITSELF COMPLETE OR REFUSES
#
# `first: N` is a page size, not a ceiling on reality, so every read here paginates to exhaustion
# via `pageInfo{hasNextPage endCursor}` and then proves what it accumulated against the connection's
# own `totalCount`. A read that cannot be proved complete is exit 19; there is no path on which it
# prints a count.
#
# Three cheaper failures are refused beside the shortfall, because arithmetic alone is not
# completeness: a repeated page (duplicate thread ids) satisfies `read >= totalCount` while carrying
# none of the newest threads, a cursor that does not advance loops on one page, and
# `hasNextPage: true` with no cursor cannot be followed at all.
#
# TWO CONSTRAINTS A LATER EDIT MUST NOT "SIMPLIFY" AWAY:
#
#   * THE CONNECTION IS OLDEST-FIRST, so what a `first:` page drops is the NEWEST threads — the
#     current review's findings, which is exactly what the caller is here to address. Raising the
#     page size moves that cliff rather than removing it.
#   * A COUNT COMPUTED INSIDE A TRUNCATED WINDOW CANNOT SEE ITS OWN EDGE, which is why `remaining`
#     shares this read instead of running its own query. "0 remaining" from a short read is
#     byte-for-byte what a clean run prints — the guard-that-cannot-answer-wrong shape
#     base/practices/self-review.md names.
#
# The cursor loop is hand-rolled rather than `gh api graphql --paginate` so that the completeness
# proof compares THIS module's own accumulation, and so the negative test can watch the loop
# iterate. D86 records why that was chosen over the alternatives.
#
# ------------------------------------------------------------------------------------------------
# THE PER-THREAD COMMENT PAGE IS A NARROWED CONTRACT, NOT A PAGE SIZE
#
# Classification is decided by the thread's HEAD comment — its author login is what the allowlist
# matches — and page one always carries it, so that half is complete by construction. The rest of
# the conversation is context a later reply can change: ten are read, and `comments_total`,
# `comments_read` and `comments_truncated` say when there are more. The flag is the contract; the
# number is not.
#
# ------------------------------------------------------------------------------------------------
# THE ALLOWLIST HERE IS THE RESOLVER'S, NOT THE MERGE GUARDS'
#
# base/roles.md gives `[reviewers] bots` two readers with deliberately different semantics. The merge
# guards match ASYMMETRICALLY (a bare `foo` accepts `foo` or `foo[bot]`); this one matches EXACTLY —
# anchored, case-insensitive — because it decides whose threads may be resolved without a human
# looking, and an over-broad match there touches a thread nobody meant it to. Do not "unify" it with
# `adb_reviewer_match_jq`. `list` emits the verdict as a per-thread `is_bot` so the rule has one home.
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   pr-threads.sh infer-pr                       # the ONE open PR, or refuse (#416)
#   pr-threads.sh list      --pr <number|url>    # every review thread, complete. JSON on stdout
#   pr-threads.sh remaining --pr <number|url>    # unresolved BOT threads, complete. count on stdout
#   pr-threads.sh -h | --help
#
# Exit codes — a stable machine contract for the workflow steps that consume them. `18` and `20`
# carry the same meanings they do in pr-watch.sh and pr-review.sh; every other code here is this
# module's own and is deliberately disjoint from theirs.
#
#   0  ok         — `infer-pr`: "<number>". `list`: the JSON document. `remaining`: the count.
#   10 none       — `infer-pr` only: this repository has NO open pull request.
#   11 ambiguous  — `infer-pr` only: two or more are open; the candidates are listed on stderr.
#                   NEVER a guess — an inference that picks wrong replies on and RESOLVES threads
#                   on a pull request nobody asked about.
#   19 short-read — the enumeration could not be proved complete: fewer threads than the
#                   connection's own `totalCount`, a repeated page, or a cursor that did not
#                   advance. THE #418 CODE. Never a lower count, never "0 remaining".
#   18 config     — `[reviewers] bots` is present but malformed. Fix agents.toml.
#   20 unknown    — live state unreadable (API failure, a malformed response, no repository, a
#                   broken install). FAIL CLOSED — never a count, never an empty thread list.
#   2  usage      — bad or missing arguments, or the reads answered for another repository.
#
# NOTE THE OTHER VOCABULARIES IN THIS FAMILY: `pr-watch.sh` uses 0/10-15/17/18/20 and
# `repo-settings.sh automerge-ok` uses 0/10-14/20, so their 10/11 mean entirely different things
# from the 10/11 above. Do not compose the codes of two of these commands without disambiguating
# which produced them.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is reporting FEWER threads than exist. Every
# uncertainty resolves to 19 or 20; there is no path where a failed or partial read degrades into a
# smaller list or a smaller count.
#
# Requires: gh (authenticated), jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_pt_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_pt_common="$_adb_pt_libdir/common.sh"
if [ ! -f "$_adb_pt_common" ]; then
  printf 'pr-threads: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_pt_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_pt_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

# role-dispatch.sh owns the `[reviewers]` manifest key; this module asks it rather than re-reading
# agents.toml, so the repo→global layering can never drift between the consumers. Same seam
# pr-watch.sh and pr-review.sh use, for the same reason.
_ADB_PT_ROLE_DISPATCH="$_adb_pt_libdir/role-dispatch.sh"

usage() { adb_usage "$0"; }

OPT_PR=""

# How many threads one page requests. NOT a ceiling — the loop below pages to exhaustion and then
# proves that it did. 100 is GitHub's documented per-connection maximum, so it costs the fewest
# round trips, and nothing here depends on the value: check-pr-threads.sh drives the same code over
# a 154-thread pull request and requires the cursor loop to iterate.
_ADB_PT_PAGE=100
# A hard ceiling on cursor iterations, so a server that always answers `hasNextPage: true` expires
# LOUDLY instead of spinning (base/practices/shell.md: every poll loop carries a hard deadline).
# 100 pages of 100 is two orders of magnitude past the largest pull request anyone has reported.
_ADB_PT_MAX_PAGES=100
# How many comments of each thread are read. See the header: the number is not the contract, the
# `comments_truncated` flag is.
_ADB_PT_COMMENTS=10
# How many open pull requests `infer-pr` will list. A page size, not a ceiling on reality — which is
# why the ambiguous refusal says "at least" once it is saturated rather than reporting the limit as
# an exact count.
_ADB_PT_PR_LIMIT=100

# The thread query, written ONCE. The first page and every cursor page send this exact document;
# the only difference between them is whether an `endCursor` variable accompanies it, which is a
# variable-binding question and not a query-text one. Two copies differing in one word is how a
# later edit fixes the shape on page 1 and leaves pages 2+ reading the old one.
#
# `baseRepository{nameWithOwner}` is not decoration: it is the ONLY evidence of which repository
# answered, and the workflow that consumes this goes on to REPLY on and RESOLVE the thread ids it
# returns. See the slug cross-check in `_adb_pt_fetch`.
_ADB_PT_QUERY='
  query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
    repository(owner:$owner,name:$name){
      pullRequest(number:$number){
        baseRepository{nameWithOwner}
        reviewThreads(first:'"$_ADB_PT_PAGE"', after:$endCursor){
          totalCount
          pageInfo{ hasNextPage endCursor }
          nodes{
            id isResolved isOutdated
            comments(first:'"$_ADB_PT_COMMENTS"'){
              totalCount
              nodes{ id author{login} path line body createdAt }
            }
          }
        }}}}'

# --- the resolvable-login allowlist -------------------------------------------------------------

# _adb_pt_bot_re — the resolver's EXACT, anchored, case-insensitive allowlist as one jq regex, or
# this module's code for why it could not be built. Prints NOTHING (status 0) for `bots = []`.
#
# `bash <path>` rather than sourcing, exactly as pr-watch.sh does: it keeps role-dispatch.sh's
# globals and shell options out of this file and preserves the process boundary the harness
# exercises. Its stderr is deliberately NOT suppressed — on a malformed declaration it names the
# exact problem, which is the whole value of code 18.
#
# CHECK THE EXIT STATUS, never the emptiness of the output. Empty-and-zero is the deliberate
# `bots = []` disable; empty-and-non-zero is a broken install or a malformed declaration, and
# reading the second as the first would silently classify EVERY thread as human — resolving nothing
# while reporting success, which is the same silent no-op class this repo keeps paying for.
_adb_pt_bot_re() {
  local logins drc
  logins="$(bash "$_ADB_PT_ROLE_DISPATCH" bots)"; drc=$?
  if [ "$drc" -ne 0 ]; then
    echo "pr-threads: could not read '[reviewers] bots' — refusing to classify threads by guessing" >&2
    # role-dispatch's own 2 means malformed; anything else is a broken install.
    [ "$drc" -eq 2 ] && return 18
    return 20
  fi
  [ -n "$logins" ] || return 0
  # Regex-escape the `[` and `]` of a `foo[bot]` login so they match literally, then anchor the
  # alternation. `(?i)`, because GitHub logins are case-insensitive.
  printf '(?i)^(%s)$' "$(printf '%s\n' "$logins" | sed 's/[][]/\\&/g' | paste -sd'|' -)"
}

# --- the complete enumeration -------------------------------------------------------------------

# _adb_pt_fetch <pr-number> <slug> <pr-arg> — every review thread of the pull request, as ONE JSON
# array on stdout, proved complete against the connection's own totalCount.
#
# Returns 19 when completeness cannot be proved, 2 on a repository mismatch, 20 on any unreadable
# or malformed response. Never a partial array.
_adb_pt_fetch() {
  local n="$1" slug="$2" arg="$3" owner name cursor="" prev_cursor="" page=0
  local raw parsed fields total="" page_total more gotslug src got uniq acc="[]"
  local -a curarg=()
  case "$slug" in
    */*) owner="${slug%%/*}"; name="${slug#*/}" ;;
    *) echo "pr-threads: cannot address PR #$n — '$slug' is not an owner/repo pair" >&2; return 20 ;;
  esac

  while :; do
    page=$(( page + 1 ))
    if [ "$page" -gt "$_ADB_PT_MAX_PAGES" ]; then
      echo "pr-threads: PR #$n — the thread cursor did not terminate within $_ADB_PT_MAX_PAGES pages; refusing to report a count" >&2
      return 20
    fi
    # AN EMPTY `-F endCursor=` IS NOT `after: null`. `-f endCursor=""` sends the empty STRING, which
    # GraphQL rejects as an invalid cursor — so the first page omits the variable entirely and the
    # query's own `null` default applies. An array, so the query text above stays one copy.
    curarg=()
    [ -n "$cursor" ] && curarg=(-f "endCursor=$cursor")

    # READ, THEN PARSE — two statements, never a pipeline. A pipeline reports only its LAST
    # command's status, so `gh … | jq` returns jq's: a FAILED read would arrive as empty input and
    # parse into an empty page, which is a read failure wearing "this pull request has no threads"
    # as its answer. That is the exact direction this module must never be wrong in.
    raw="$(gh api graphql -f "owner=$owner" -f "name=$name" -F "number=$n" \
             "${curarg[@]}" -f "query=$_ADB_PT_QUERY" 2>/dev/null)" \
      || { echo "pr-threads: could not read the review threads of PR #$n (page $page)" >&2; return 20; }
    [ -n "$raw" ] \
      || { echo "pr-threads: could not read the review threads of PR #$n (page $page: empty response body)" >&2; return 20; }

    # THE SAME TYPE DISCIPLINE `adb_pw_receipts` applies, and for the same reason: `// 0` and
    # `// []` would read a malformed or absent connection as "no threads", which is precisely the
    # shortfall this module exists to make loud. Every field the completeness proof rests on is
    # type-checked before it is trusted.
    #
    # EVERY NODE IS CHECKED, NOT JUST THE ARRAY AROUND THEM, and the gap that closes is not
    # cosmetic. A node whose `isResolved` is absent or non-boolean sails through the completeness
    # proof — it still counts toward `totalCount` — and is then silently DROPPED by the
    # `.isResolved == false` predicate in `remaining`, turning unreadable state into a LOWER count.
    # That is the one direction this module promises never to be wrong in. The id is checked for
    # the same reason at higher stakes: it is what the caller RESOLVES threads by, so an empty one
    # aims a mutation at nothing. Reported by the declared reviewer on PR #419.
    #
    # AND THE NESTED CONNECTION IS CHECKED TOO — the same defect one level deeper, which the first
    # pass at this rule missed. `comments: {totalCount: 1, nodes: []}` satisfies "nodes is an
    # array": `cmd_list` then defaults the absent head author to `""`, `cmd_remaining` reads that as
    # non-bot, and an unresolved BOT thread disappears from the count. Identical outcome, different
    # nesting level. A non-numeric `totalCount` is refused for the neighbouring reason: `// 0` would
    # read it as zero and hide the truncation `comments_truncated` exists to expose.
    #
    # THE HEAD-AUTHOR RULE IS SCOPED TO UNRESOLVED THREADS, deliberately. That is exactly the set
    # whose classification decides the count, so it closes the hole completely — while a rule over
    # ALL threads would refuse the whole enumeration for an old RESOLVED thread whose author account
    # was since deleted (GitHub returns `author: null`), which is a false refusal bought for nothing.
    #
    # (Written here rather than inside the jq program: a jq comment sits in a single-quoted shell
    # string, so one apostrophe in it ends the string.)
    parsed="$(printf '%s' "$raw" | jq -c '
        if (.errors | length) > 0 then error("graphql errors") else . end
        | (.data.repository.pullRequest // null) as $p
        | if $p == null then error("no pullRequest") else . end
        | ($p.reviewThreads // null) as $t
        | if $t == null then error("no reviewThreads connection") else . end
        | if ($t.nodes | type) != "array" then error("the reviewThreads connection carries no nodes array") else . end
        | if any($t.nodes[]; (.id | type) != "string" or (.id | length) == 0)
          then error("a review thread carries no usable id") else . end
        | if any($t.nodes[]; (.isResolved | type) != "boolean")
          then error("a review thread carries no boolean isResolved") else . end
        | if any($t.nodes[]; (.comments | type) != "object" or (.comments.nodes | type) != "array")
          then error("a review thread carries no comments connection") else . end
        | if any($t.nodes[]; (.comments.totalCount | type) != "number")
          then error("a review thread carries no comments totalCount") else . end
        | if any($t.nodes[]; (.isResolved == false)
                   and (((.comments.nodes | length) == 0)
                        or ((.comments.nodes[0].author.login | type) != "string")
                        or ((.comments.nodes[0].author.login | length) == 0)))
          then error("an unresolved review thread carries no usable head comment author") else . end
        | if ($t.totalCount | type) != "number" then error("the reviewThreads connection carries no totalCount") else . end
        | if (($t.totalCount | floor) != $t.totalCount) or ($t.totalCount < 0)
          then error("the reviewThreads connection carries an impossible totalCount") else . end
        | if ($t.pageInfo | type) != "object" then error("the reviewThreads connection carries no pageInfo") else . end
        | if ($t.pageInfo.hasNextPage | type) != "boolean" then error("pageInfo carries no hasNextPage") else . end
        | { total: $t.totalCount,
            more:  $t.pageInfo.hasNextPage,
            next:  ($t.pageInfo.endCursor // ""),
            slug:  ($p.baseRepository.nameWithOwner // "") }' 2>/dev/null)" \
      || { echo "pr-threads: could not parse the review threads of PR #$n (page $page: errors or an unexpected shape)" >&2; return 20; }

    # CAPTURE FIRST, then split, and CHECK THE STATUS — the discipline pr-watch.sh's `classify`
    # states: jq emits earlier expressions before it evaluates later ones, so a jq that errors
    # partway still writes usable-looking leading lines, and putting the substitution straight into
    # the heredoc would discard the status that tells a partial parse from a clean one.
    fields="$(printf '%s' "$parsed" | jq -r '(.total|tostring), (.more|tostring), .next, .slug' 2>/dev/null)" \
      || { echo "pr-threads: could not read the page state of PR #$n (page $page)" >&2; return 20; }
    prev_cursor="$cursor"
    { IFS= read -r page_total; IFS= read -r more; IFS= read -r cursor; IFS= read -r gotslug; } <<EOF
$fields
EOF
    # KEEP THE LARGEST totalCount ANY PAGE REPORTED, not the last one. Overwriting per page meant the
    # proof below compared against whatever the FINAL page happened to claim, so a count that shrank
    # mid-pagination would lower the bar the read has to clear — the one direction this module must
    # never be wrong in. Taking the max makes a shrinking count unable to mask a shortfall.
    [ -n "$total" ] && [ "$page_total" -le "$total" ] || total="$page_total"

    # PROVE THIS READ ADDRESSED THE REPOSITORY THE CALLER MEANT, on the FIRST page and before any
    # thread id is accumulated. The caller replies on and RESOLVES the ids this returns, so
    # answering about the wrong repository here is a mutation on a stranger's pull request. Both
    # rules — `GH_REPO` redirecting a bare number, and a URL naming another repo — live in
    # `adb_pr_slug_check` (#173) rather than being re-derived here.
    if [ "$page" -eq 1 ]; then
      adb_pr_slug_check pr-threads "$n" "$arg" "$gotslug"; src=$?
      case "$src" in
        0) ;;
        2) return 2 ;;
        *) return 20 ;;
      esac
    fi

    # ACCUMULATE THROUGH STDIN, NEVER THROUGH ARGV. The obvious spelling — `jq --argjson acc "$acc"`
    # — passes the whole accumulated document as one argv entry, and argv is bounded by ARG_MAX
    # (1 MiB, `getconf ARG_MAX`, on this project's macOS runner). That would make this module ship a
    # NEW size cliff in the very commit that removes the old one, and fail as an opaque exec error
    # rather than as the loud shortfall everything else here is careful to produce.
    #
    # MEASURED, not argued (2026-08-20): a 600-thread accumulation with ordinary review bodies is
    # 1,094,291 bytes, and `jq -nc --argjson a "$BIG" '$a|length'` dies with "argument list too
    # long"; the stdin form below returns 600 for the same payload. A shell variable carries no such
    # bound and neither does a pipe, so both values go down stdin and `jq -s` joins them.
    acc="$(printf '%s' "$raw" | jq -c '.data.repository.pullRequest.reviewThreads.nodes' 2>/dev/null \
           | { IFS= read -r _page || _page=""
               [ -n "$_page" ] || exit 3
               printf '%s\n%s' "$acc" "$_page" | jq -s -c '.[0] + .[1]' 2>/dev/null; })" \
      || { echo "pr-threads: could not accumulate the review threads of PR #$n" >&2; return 20; }

    [ "$more" = "true" ] || break
    # A server that says "there is more" and hands back no cursor cannot be paged; one that hands
    # back the SAME cursor would re-fetch this page until the ceiling above fires. Both are refused
    # here rather than left to the arithmetic, which a repeated page can satisfy while carrying none
    # of the newest threads.
    [ -n "$cursor" ] \
      || { echo "pr-threads: PR #$n — page $page reports more threads but carries no cursor; refusing to report an incomplete read" >&2
           return 19; }
    [ "$cursor" != "$prev_cursor" ] \
      || { echo "pr-threads: PR #$n — the thread cursor did not advance past page $page; refusing to report an incomplete read" >&2
           return 19; }
  done

  got="$(printf '%s' "$acc" | jq -r 'length' 2>/dev/null)" \
    || { echo "pr-threads: could not count the review threads of PR #$n" >&2; return 20; }

  # A REPEATED PAGE SATISFIES THE ARITHMETIC WHILE MISSING THE NEWEST THREADS, so identity is
  # checked before the count is. Reported by the independent gap-analysis pass.
  uniq="$(printf '%s' "$acc" | jq -r '[.[].id] | unique | length' 2>/dev/null)" \
    || { echo "pr-threads: could not verify the review threads of PR #$n are distinct" >&2; return 20; }
  if [ "$uniq" -ne "$got" ]; then
    echo "pr-threads: PR #$n — read $got threads but only $uniq distinct ids; a page was served twice, so the enumeration is not complete" >&2
    return 19
  fi

  # THE COMPLETENESS PROOF, and the whole reason this module exists: an incomplete read is LOUD.
  #
  # `-lt`, not `-ne`, AND THE ASYMMETRY IS ARGUED FROM THIS MODULE'S CONTRACT RATHER THAN FROM ANY
  # CLAIM ABOUT GITHUB. An earlier version of this comment justified it by asserting that the
  # connection's counts are eventually consistent; that is a third-party behaviour claim, it was
  # never resolved against a vendor source, and `base/practices/third-party-claims.md` says recall
  # does not close one. So it is gone, and the argument is the local one that does hold:
  #
  #   read < totalCount  — threads exist that this read did not return. That IS the defect (#418),
  #                        and it is refused.
  #   read > totalCount  — more threads were returned than the connection counts. This ALSO refuses,
  #                        and the reasoning that once said otherwise was wrong: an earlier version
  #                        argued it "cannot be an under-read", but that only holds if `totalCount`
  #                        is trustworthy — and this branch is the proof that it is NOT. A response
  #                        claiming `totalCount: 1` while returning two nodes may equally have
  #                        omitted a third, so an inconsistent count cannot establish completeness
  #                        in either direction. Under a complete-or-refuse contract, unprovable is
  #                        refused. Reported by the declared reviewer on PR #419.
  if [ "$got" -ne "$total" ]; then
    if [ "$got" -gt "$total" ]; then
      echo "pr-threads: PR #$n — read $got threads but totalCount is $total; the response is internally inconsistent, so completeness cannot be proved either way" >&2
    else
      echo "pr-threads: PR #$n — read $got of totalCount $total review threads; refusing to report an incomplete enumeration" >&2
    fi
    return 19
  fi
  printf '%s' "$acc"
}

# --- subcommands ---------------------------------------------------------------------------------

# cmd_infer_pr — which pull request does an argument-less /resolve-pr-threads mean? (#416)
#
# EXACTLY ONE open pull request is the ordinary loop state — the one /implement-issue just opened —
# and making the operator look its number up to type it back in is the hand-holding #416 names.
# Zero and two-or-more are both refusals, and the second matters most: resolving is a MUTATION, so
# a guess that picks wrong replies on and resolves the threads of a pull request nobody asked about.
#
# DRAFTS ARE INCLUDED, deliberately. A draft pull request is `state: OPEN`, it accumulates review
# threads like any other, and step 1's existing preflight already admits it — excluding it here
# would make inference and explicit invocation disagree about the same pull request. The candidate
# listing marks it, so the ≥2 refusal is actionable rather than merely correct.
cmd_infer_pr() {
  local raw n list slug
  adb_require_gh jq || return 20
  # SCOPE THE LIST TO THIS CHECKOUT'S OWN REPOSITORY, explicitly. A bare `gh pr list` resolves the
  # repository from gh's own rules, which `GH_REPO` silently redirects — and the number it would
  # then return is a FOREIGN pull request's, handed straight to `list --pr`, which resolves the
  # slug from the git remote and so applies that number to the LOCAL repository. Both halves are
  # individually correct and the pair mis-targets. Everything downstream cross-checks the slug it
  # was answered by (`adb_pr_slug_check`); this is the one read with no answer to cross-check, so it
  # names the repository up front instead.
  slug="$(adb_pr_query_slug pr-threads "")" \
    || { echo "pr-threads: could not resolve which repository to list pull requests for" >&2; return 20; }
  raw="$(gh pr list --repo "$slug" --state open --limit "$_ADB_PT_PR_LIMIT" --json number,title,headRefName,isDraft,url 2>/dev/null)" \
    || { echo "pr-threads: could not list the open pull requests of $slug" >&2; return 20; }
  [ -n "$raw" ] \
    || { echo "pr-threads: could not list this repository's open pull requests (empty response body)" >&2; return 20; }
  # Type-check before counting, for the reason every read here does: `// []` on a malformed response
  # would read as "no open pull requests" — a refusal, so safe, but it would report the wrong
  # REASON and send the operator looking for a pull request that is sitting right there.
  n="$(printf '%s' "$raw" | jq -r 'if type != "array" then error("not an array") else length end' 2>/dev/null)" \
    || { echo "pr-threads: could not parse this repository's open pull requests" >&2; return 20; }

  case "$n" in
    0) echo "pr-threads: this repository has no open pull request — nothing to resolve. Open one, or name a pull request explicitly." >&2
       return 10 ;;
    1) printf '%s' "$raw" | jq -r '.[0].number' 2>/dev/null \
         || { echo "pr-threads: could not read the number of the one open pull request" >&2; return 20; }
       return 0 ;;
  esac
  # SORTED NUMERICALLY, so the refusal is a deterministic contract a test can pin rather than
  # whatever order the API happened to answer in.
  list="$(printf '%s' "$raw" | jq -r 'sort_by(.number)[]
           | "  #\(.number)\(if .isDraft then " [draft]" else "" end)  \(.headRefName)  \(.title)  \(.url)"' 2>/dev/null)" \
    || { echo "pr-threads: could not render the open pull requests" >&2; return 20; }
  # SAY "AT LEAST" WHEN THE LISTING IS SATURATED. `--limit` is a page size, so a repository with more
  # open pull requests than the limit would otherwise be reported as having EXACTLY the limit, and
  # the message would promise a complete candidate list it did not have. The refusal is correct
  # either way — two or more is a refusal — but a count stated as exact when it is a ceiling is the
  # same class of quiet inaccuracy this module exists to remove. Reported by the independent reviewer.
  if [ "$n" -ge "$_ADB_PT_PR_LIMIT" ]; then
    echo "pr-threads: at least $n open pull requests (the listing is capped at $_ADB_PT_PR_LIMIT) — name the one you mean; this never guesses. Showing the first $n:" >&2
  else
    echo "pr-threads: $n open pull requests — name the one you mean; this never guesses:" >&2
  fi
  printf '%s\n' "$list" >&2
  return 11
}

# cmd_list — every review thread of the pull request, classified, complete.
#
# Emits ONE object: `{ pr, total, bot_re, threads: [ … ] }`, where each thread carries the fields
# the resolver classifies on plus `is_bot` — the resolver's own exact-allowlist verdict, computed
# HERE so the workflow never rebuilds the regex (it used to build it twice, in two blocks that could
# not be tested and had already been given a comment warning about the empty-regex trap).
cmd_list() {
  local n slug nodes re rrc out
  [ -n "$OPT_PR" ] || { echo "pr-threads: list requires --pr <number|url>" >&2; return 2; }
  n="$(adb_pr_number "$OPT_PR")" \
    || { echo "pr-threads: '--pr $OPT_PR' is not a PR number or a GitHub PR URL naming a repository" >&2; return 2; }
  adb_require_gh jq || return 20
  # THE MANIFEST IS READ BEFORE THE NETWORK. A malformed `[reviewers] bots` is a configuration fact
  # knowable without a round trip, and reporting it after the reads would make the operator wait for
  # an enumeration whose classification was never going to work.
  re="$(_adb_pt_bot_re)"; rrc=$?
  [ "$rrc" -eq 0 ] || return "$rrc"
  slug="$(adb_pr_query_slug pr-threads "$OPT_PR")" \
    || { echo "pr-threads: could not resolve which repository to read for PR #$n" >&2; return 20; }
  nodes="$(_adb_pt_fetch "$n" "$slug" "$OPT_PR")" || return $?

  # `bots = []` must classify NOTHING as a bot — and jq's `test("")` matches EVERY string, so the
  # emptiness is tested in jq rather than handed to the matcher. That trap used to live in the
  # workflow as a comment beside a `: "${BOT_RE:=…}"` default nothing could exercise; here it is
  # one line of a tested predicate.
  out="$(printf '%s' "$nodes" | jq -c --arg re "$re" --argjson pr "$n" '
      { pr: $pr,
        total: length,
        bot_re: $re,
        threads: [ .[] | (.comments.nodes[0] // {}) as $head | {
          id, isResolved, isOutdated,
          author:    ($head.author.login // ""),
          path:      ($head.path // null),
          line:      ($head.line // null),
          createdAt: ($head.createdAt // ""),
          body:      ($head.body // ""),
          is_bot:    (($re != "") and (($head.author.login // "") | test($re))),
          comments_total:     (.comments.totalCount // 0),
          comments_read:      (.comments.nodes | length),
          comments_truncated: ((.comments.totalCount // 0) > (.comments.nodes | length)),
          comments: [ .comments.nodes[] | {id, author: (.author.login // ""), body, createdAt} ] } ] }' 2>/dev/null)" \
    || { echo "pr-threads: could not classify the review threads of PR #$n" >&2; return 20; }
  printf '%s\n' "$out"
}

# cmd_remaining — how many UNRESOLVED bot threads are left, counted over a COMPLETE enumeration.
#
# This is step 6's sanity check, and #418 is entirely about the fact that it used to share the
# truncating window it was supposed to police. It RE-READS — the count must be of now, not of the
# step-2 snapshot — and it inherits the short-read refusal, so "0 remaining" can only ever be said
# about a read that proved itself complete.
cmd_remaining() {
  local n slug nodes re rrc out
  [ -n "$OPT_PR" ] || { echo "pr-threads: remaining requires --pr <number|url>" >&2; return 2; }
  n="$(adb_pr_number "$OPT_PR")" \
    || { echo "pr-threads: '--pr $OPT_PR' is not a PR number or a GitHub PR URL naming a repository" >&2; return 2; }
  adb_require_gh jq || return 20
  re="$(_adb_pt_bot_re)"; rrc=$?
  [ "$rrc" -eq 0 ] || return "$rrc"
  slug="$(adb_pr_query_slug pr-threads "$OPT_PR")" \
    || { echo "pr-threads: could not resolve which repository to read for PR #$n" >&2; return 20; }
  nodes="$(_adb_pt_fetch "$n" "$slug" "$OPT_PR")" || return $?
  out="$(printf '%s' "$nodes" | jq -r --arg re "$re" '
      [ .[] | select(.isResolved == false)
            | (.comments.nodes[0].author.login // "") as $who
            | select(($re != "") and ($who | test($re))) ] | length' 2>/dev/null)" \
    || { echo "pr-threads: could not count the unresolved bot threads of PR #$n" >&2; return 20; }
  case "$out" in ''|*[!0-9]*) echo "pr-threads: could not count the unresolved bot threads of PR #$n" >&2; return 20 ;; esac
  printf '%s\n' "$out"
}

# --- arg parsing -----------------------------------------------------------------------------
# `--pr` is REQUIRED for `list` and `remaining`. An optional PR would make them silently answer
# about the wrong thing the moment a caller forgot it — which is exactly the failure `infer-pr`
# exists to spare the operator from having to avoid by hand. Inference happens ONCE, in the
# resolver, and the explicit number is passed downstream; no other library here grows an implicit
# target (pr-watch.sh's `--pr` stays mandatory for the same reason).
#
# Every value-taking option checks its ARITY and its VALUE separately, so `--pr ''` reports "must
# not be empty" rather than the arity message for a flag that was in fact supplied.
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)
        [ "$#" -ge 2 ] || { echo "pr-threads: --pr needs a value" >&2; exit 2; }
        [ -n "$2" ] || { echo "pr-threads: --pr must not be empty" >&2; exit 2; }
        OPT_PR="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "pr-threads: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  infer-pr)   parse_opts "$@"; cmd_infer_pr ;;
  list)       parse_opts "$@"; cmd_list ;;
  remaining)  parse_opts "$@"; cmd_remaining ;;
  -h|--help)  usage; exit 0 ;;
  *) echo "pr-threads: unknown subcommand '$SUB' (expected 'infer-pr', 'list' or 'remaining')" >&2; usage >&2; exit 2 ;;
esac
