#!/usr/bin/env bash
# ai-dev-baseline — the async-reviewer status detector (issue #49).
#
# `/implement-issue` opens a PR and ends. The async code-review bot arrives minutes later, usually
# after the session is gone, so the operator has to come back and run `/resolve-pr-threads` by
# hand. This module is the half of that loop a shell can do: it answers "has the declared reviewer
# finished with this PR, and did it find anything?" — and it can WAIT for that answer without
# spending a single model token, because waiting is a `sleep` loop, not a conversation.
#
# WHY IT IS NOT PART OF pr-review.sh. That module's header states its own boundary: "it does not
# wait, poll, retry, resolve threads, or merge", and names this issue as the place a waiting watch
# belongs. Growing it here would break that contract rather than respect it. `pr-review.sh gate`
# answers "may I arm auto-merge NOW?"; this module answers "is the reviewer DONE, and with what?"
#
# ------------------------------------------------------------------------------------------------
# THE SIGNAL, AND WHY IT IS TWO SIGNALS RATHER THAN THREE
#
# The Codex connector documents its own contract in every review body it posts:
#
#     "If Codex has suggestions, it will comment; otherwise it will react with 👍."
#
# So there are exactly TWO terminal outcomes, and they are disjoint:
#
#   clean     → a `+1` reaction on the PR's opening post, and NO review object at all
#   findings  → a submitted review (and usually inline threads), and NO reaction
#
# Verified live on this repo: PRs #53, #54, #66, #83, #88 carry a connector `+1` with ZERO
# connector reviews and ZERO inline threads; PRs #127, #137, #145, #146, #154, #166 carry one
# connector review with 1–4 inline threads and NO reaction. Nothing sits in both sets.
#
# The issue that asked for this described a THIRD, transient state — a 👀 reaction while the review
# is running, removed when findings are posted. This module deliberately does NOT model it. The
# reactions API exposes only reactions that exist RIGHT NOW, never deletion history, so "👀 was here
# and then vanished" is knowable only to a watcher that happened to be looking across the
# transition. A detector that needed it could not answer correctly after a restart, a resumed
# watch, or a late start — exactly the cases an unattended watcher must survive. Polling for either
# TERMINAL signal instead is restart-safe, idempotent, and needs no memory of what came before.
#
# WHAT THIS COSTS THE CALLER. `pr-review.sh gate` reads only `pulls/N/reviews`, so a CLEAN Codex
# pass — which posts no review — never satisfies it: it returns 16 ("awaiting review") forever, and
# unattended arming stays off on precisely the PRs that are cleanest. This module reports that case
# correctly as `clean`. Teaching the ARMING guard to accept a reaction is a change to when merges
# happen and is deliberately left to its own issue, not folded in here.
#
# ------------------------------------------------------------------------------------------------
# STALENESS: A REACTION IS NOT COMMIT-SCOPED
#
# A review carries `commit_id`, so "did the reviewer review THIS head?" is a field comparison. A
# reaction carries no commit at all — only `created_at`. A `+1` left on an earlier head therefore
# still sits there after new commits land, and reading it naively would report `clean` for code
# nobody reviewed. That is the one direction this module must never be wrong in.
#
# So a `+1` counts only when it is NEWER than the current head commit's committer date. A commit
# pushed after the reaction makes the reaction stale, and the verdict falls back to `pending`.
#
# The comparison mixes a GitHub-assigned timestamp (the reaction) with a client-supplied one (the
# commit), so a skewed or deliberately back/forward-dated commit can shift the boundary. It shifts
# it in the SAFE direction: a commit dated in the future makes a genuine `+1` look stale, which
# reports `pending` — a watcher that waits longer, never one that green-lights unreviewed code.
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   pr-watch.sh observe --pr <number|url>            # classify once, print "<verdict> <head-sha>"
#   pr-watch.sh wait    --pr <number|url> \          # poll until terminal, bounded; 0 model tokens
#                       [--interval <secs>] [--max-secs <secs>]
#   pr-watch.sh -h | --help
#
# PLUGGABILITY, STATED PLAINLY: the `+1`-means-clean convention above is the CODEX CONNECTOR's,
# and this module applies it to every login in `[reviewers] bots` without per-reviewer dispatch.
# For a reviewer that signals differently the degradation is safe and bounded, but it is a real
# degradation and worth knowing: one that posts a review even on a clean pass classifies as
# `findings`, so a caller runs its resolve flow and finds nothing; one that signals in some third
# way never converges and the caller stops at the `wait` bound. Neither can produce a false
# `clean`. A per-reviewer signal profile keyed off the same manifest entry is the natural
# generalization and is tracked as #170.
#
# Exit codes are a stable machine contract for the workflow step that consumes them. They are
# deliberately DISJOINT from pr-review.sh's 16–20 where the meanings differ, and identical where
# they are the same question (17/18/20), so a caller can never confuse the two guards.
#
#   0  clean      — a declared reviewer signalled a clean pass for the CURRENT head, or the repo
#                   declared `[reviewers] bots = []` (nothing is coming). STDOUT: "clean <sha>".
#   10 findings   — a declared reviewer submitted a review attached to the CURRENT head SHA. The
#                   caller should run the resolve flow. STDOUT: "findings <sha>".
#   11 pending    — no terminal signal yet. From `wait`, the bound expired while still pending:
#                   hand off to a human. STDOUT: "pending <sha>".
#   12 gone       — the PR is no longer OPEN (merged or closed). Stop watching.
#   17 undeclared — the repo declares no `[reviewers] bots`, so it cannot be known whether a
#                   reviewer is coming. FAIL CLOSED. Declare them, or `bots = []` if there are none.
#   18 config     — `[reviewers] bots` is present but malformed. Fix agents.toml.
#   20 unknown    — live state unreadable (API failure, no head SHA). FAIL CLOSED — never `clean`.
#   2  usage      — bad or missing arguments.
#
# NOTE THE THIRD VOCABULARY IN THIS FAMILY: `repo-settings.sh automerge-ok` uses 0/10–14/20, so its
# 10/11/12 mean entirely different things from the 10/11/12 above. Nothing composes the two today —
# they are read by different steps of different workflows — but do not "unify" them by assuming a
# shared meaning, and do not add a caller that branches on both without disambiguating which
# command produced the code. That the family now has three vocabularies is the argument #148 makes.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is reporting `clean` when the reviewer has not
# actually passed this head. Every uncertainty above therefore resolves to `pending` or a non-zero
# unknown, and there is no path where a failed read degrades into "clean".
#
# What this file must never grow: it does not resolve threads, edit code, push, or merge. It
# observes and it waits. Acting on a `findings` verdict is the resolver's job; arming a merge is
# the arming guard's.
#
# Requires: gh (authenticated), jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_pw_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_pw_common="$_adb_pw_libdir/common.sh"
if [ ! -f "$_adb_pw_common" ]; then
  printf 'pr-watch: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_pw_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_pw_common"

# role-dispatch.sh owns the `[reviewers]` manifest key; this module asks it rather than re-reading
# agents.toml, so the repo→global layering can never drift between the consumers. Same seam
# pr-review.sh uses, for the same reason.
_ADB_PW_ROLE_DISPATCH="$_adb_pw_libdir/role-dispatch.sh"

usage() { adb_usage "$0"; }

OPT_PR=""
# Defaults chosen against the observed shape of a real review: the Codex connector took ~3 minutes
# on this repo's recent PRs, so a 30s poll converges promptly, and 30 minutes is long enough to
# cover a slow or queued review without waiting on one that is never coming.
#
# COST OF A POLL: three reads (the PR, its reviews, its reactions), plus a fourth — the head commit
# — only on the branch where a `+1` was actually found. A full 30-minute watch at 30s is therefore
# ~180 requests against an authenticated limit of 5000/hour: comfortable, but not free, which is
# why the interval is tunable and why the clean/findings checks short-circuit the moment either
# lands. Collapsing the reads into one GraphQL query is #174 (the sibling of #147, which makes the same
# argument about the arming guard but is scoped to that file only).
OPT_INTERVAL=30
OPT_MAX_SECS=1800
# Consecutive unreadable polls tolerated before `wait` gives up. A single 502/rate-limit must not
# abandon a 30-minute watch, but an endlessly unreadable API must not be waited on forever either.
_ADB_PW_MAX_UNREADABLE=3

# --- helpers ---------------------------------------------------------------------------------

# parse_pr_arg <value> — the PR NUMBER from a bare integer or a GitHub PR URL. Same contract as
# pr-review.sh's: the caller's marker holds a `prUrl`, so accepting both removes a caller-side sed.
parse_pr_arg() {
  local n="$1"
  case "$n" in *pull/*) n="${n##*pull/}"; n="${n%%[!0-9]*}" ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$n"
}

# parse_pr_slug <value> — the `owner/repo` of a PR URL, or nothing for a bare number. Used only to
# CROSS-CHECK the URL against the repo the reads actually address: every read below addresses
# `repos/{owner}/{repo}/...`, which gh expands from the LOCAL remote, so a URL naming another
# repository would otherwise be answered about THIS one.
parse_pr_slug() {
  local v="$1" rest
  case "$v" in
    *://*/*/*/pull/*) rest="${v#*://}"; rest="${rest#*/}" ;;
    *) return 0 ;;
  esac
  printf '%s' "${rest%%/pull/*}"
}

# require_uint <value> <option-name> — a positive integer, or usage. Rejects the empty string, a
# sign, and any non-digit; a zero interval would spin the poll loop as a busy-wait and a zero bound
# would make `wait` return before its first read.
#
# The LENGTH bound is not belt-and-braces: an all-digit value wider than a shell integer overflows
# the `$(( deadline - SECONDS ))` arithmetic below, so `--max-secs 99999999999999999999` would pass
# a digits-only check and then produce a nonsense (possibly negative) remaining time — a "bound"
# that expires immediately or never. 18 digits is the same ceiling `roadmap-lib.sh`'s `is_uint`
# documents for the same reason; the shared validator is #150.
require_uint() {
  case "$1" in
    ''|*[!0-9]*) echo "pr-watch: $2 must be a positive integer (got '$1')" >&2; return 1 ;;
  esac
  [ "${#1}" -le 18 ] || { echo "pr-watch: $2 is too large (got '$1')" >&2; return 1; }
  [ "$1" -gt 0 ] 2>/dev/null || { echo "pr-watch: $2 must be greater than zero" >&2; return 1; }
}

# read_list <api-path> <label> <pr-number> — a paginated GET, flattened to one JSON array.
#
# Both signal reads have the same shape, and factoring them together is about the FAIL-CLOSED
# guards rather than the line count: each read needs three of them (the fetch, the parse, and the
# empty-result check), and if a later edit dropped one on a single path that signal would classify
# an unreadable response as "nothing found yet" — `pending` instead of `20`. `pending` looks
# harmless, which is what makes it the dangerous one: the watcher would keep polling a broken API
# to its deadline and report a timeout instead of the failure. One home means both paths cannot
# drift apart.
#
# Read and PARSE separately: a pipeline reports only its LAST command's status, so `gh api … | jq`
# returns 0 on a failed read and the parser then sees empty stdin — indistinguishable from a
# legitimately empty list.
read_list() {
  local url="$1" label="$2" pr="$3" raw flat
  raw="$(gh api --paginate "$url" 2>/dev/null)" \
    || { echo "pr-watch: could not read $label for PR #$pr" >&2; return 20; }
  # --paginate concatenates one JSON document per page; -s flattens them into a single array.
  flat="$(printf '%s' "$raw" | jq -s -c '[.[][]]' 2>/dev/null)" \
    || { echo "pr-watch: could not parse the $label of PR #$pr" >&2; return 20; }
  [ -n "$flat" ] \
    || { echo "pr-watch: could not parse the $label of PR #$pr" >&2; return 20; }
  printf '%s' "$flat"
}

# read_declared_bots — normalize `[reviewers] bots` into the comparison form, or return this
# module's code for why it could not. Prints the normalized, de-duplicated login set on stdout.
#
# The normalization is load-bearing and not cosmetic: the SAME bot has two spellings depending on
# which API answered — GraphQL/REST reaction `user.login` is the bare `chatgpt-codex-connector`
# while REST review `user.login` is `chatgpt-codex-connector[bot]`. Both sides are normalized (here
# and in the jq below) so either spelling works in agents.toml. Lowercase BEFORE stripping so
# `[BOT]` is stripped too; drop blanks AFTER so an entry that is only `[bot]` disappears rather
# than becoming a reviewer that can never match.
read_declared_bots() {
  local declared drc want
  declared="$(bash "$_ADB_PW_ROLE_DISPATCH" bots --declared)"; drc=$?
  case "$drc" in
    0) ;;
    3) echo "pr-watch: this repo declares no '[reviewers] bots' — cannot know whether a reviewer is coming." >&2
       echo "pr-watch: declare the async reviewer logins in agents.toml, or 'bots = []' if there are none." >&2
       return 17 ;;
    2) echo "pr-watch: '[reviewers] bots' is unusable (see above) — fix agents.toml; use [] for none" >&2
       return 18 ;;
    *) echo "pr-watch: could not read '[reviewers] bots' (broken install) — refusing to guess" >&2
       return 20 ;;
  esac

  want="$(printf '%s\n' "$declared" \
          | tr '[:upper:]' '[:lower:]' \
          | sed -e 's/\[bot\]$//' -e '/^[[:space:]]*$/d' \
          | LC_ALL=C sort -u)"

  # A declaration that survived the manifest reader but normalizes to NOTHING (`bots = ["[bot]"]`)
  # is malformed, not "no reviewers". Treating it as the `[]` disable would report `clean` off the
  # back of a typo — the fail-open direction, from the input that looks most like a real
  # declaration.
  if [ -n "$declared" ] && [ -z "$want" ]; then
    echo "pr-watch: '[reviewers] bots' has no usable reviewer logins — fix agents.toml (use [] for none)" >&2
    return 18
  fi
  printf '%s' "$want"
}

# --- the detector ------------------------------------------------------------------------------

# classify <pr-number> <declared-logins> — one bounded classification of the PR's review state.
# Prints "<verdict> <head-sha>" on stdout; returns this module's exit code for that verdict.
# Every read is fresh: this is called once per poll, so a head that moves mid-watch is picked up on
# the next pass without any stored state to reset (base/practices/verify-before-asserting.md).
classify() {
  local n="$1" want="$2" pjson pfields head state merged gotslug wantslug
  local reviews hits reacts cjson commitdate whojson

  # The declared set as a JSON array, built ONCE: both jq passes below test membership against it,
  # and re-deriving it per pass would fork a second jq for the same value.
  whojson="$(printf '%s' "$want" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" \
    || { echo "pr-watch: could not build the reviewer set" >&2; return 20; }

  # Read, then parse — two steps, deliberately. Folding the extraction into `gh --jq` makes one
  # status cover both the network read and the shape of what came back, so a PR object that
  # arrived fine but carries no head SHA is indistinguishable from a failed call.
  pjson="$(gh api "repos/{owner}/{repo}/pulls/$n" 2>/dev/null)" \
    || { echo "pr-watch: could not read PR #$n" >&2; return 20; }
  # CAPTURE FIRST, then split, and CHECK THE STATUS. jq emits earlier expressions before it
  # evaluates later ones, so a jq that errors partway still writes usable-looking leading lines;
  # putting the substitution straight into the heredoc would discard the status that tells a
  # partial parse from a clean one.
  pfields="$(printf '%s' "$pjson" \
             | jq -r '(.head.sha // ""), (.state // "" | ascii_downcase), (.merged_at // ""), (.base.repo.full_name // "" | ascii_downcase)' 2>/dev/null)" \
    || { echo "pr-watch: could not parse PR #$n" >&2; return 20; }
  { IFS= read -r head; IFS= read -r state; IFS= read -r merged; IFS= read -r gotslug; } <<EOF
$pfields
EOF
  [ -n "$head" ] \
    || { echo "pr-watch: could not resolve the head SHA of PR #$n" >&2; return 20; }

  # If the caller passed a URL, prove it names the repo these reads actually addressed. Without
  # this, `--pr https://github.com/other/repo/pull/7` would faithfully report on THIS repo's #7 —
  # a confidently wrong answer, which is the one thing a detector must never produce.
  wantslug="$(parse_pr_slug "$OPT_PR" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$wantslug" ] && [ -n "$gotslug" ] && [ "$wantslug" != "$gotslug" ]; then
    echo "pr-watch: --pr names '$wantslug' but this repo is '$gotslug' — refusing to answer about a different repository" >&2
    return 2
  fi

  # A PR that has merged or closed is terminal whatever the reviewer did. Checked BEFORE the
  # signal reads so a watch on a PR the operator merged by hand stops promptly instead of polling
  # a dead PR to its deadline.
  if [ "$state" != "open" ]; then
    printf 'gone %s\n' "$head"
    if [ -n "$merged" ]; then
      echo "pr-watch: PR #$n is MERGED — nothing left to watch" >&2
    else
      echo "pr-watch: PR #$n is $state — nothing left to watch" >&2
    fi
    return 12
  fi

  # `bots = []` — an explicit declaration that this repo has NO async reviewer. Nothing will ever
  # arrive, so waiting would be an infinite wait for a caller that cannot know better.
  if [ -z "$want" ]; then
    printf 'clean %s\n' "$head"
    echo "pr-watch: PR #$n — no async reviewers declared ([reviewers] bots = []); nothing to watch" >&2
    return 0
  fi

  # --- findings? a submitted review attached to THIS head ---------------------------------------
  # Checked before the clean signal: findings are commit-scoped and therefore the stronger claim,
  # and a reviewer that somehow produced both should be treated as having found something.
  #
  # --paginate so a PR with many reviews cannot silently drop the page carrying the one that
  # matters.
  reviews="$(read_list "repos/{owner}/{repo}/pulls/$n/reviews?per_page=100" reviews "$n")" || return 20

  # One pass over the whole document emitting the declared reviewers that submitted a REAL review
  # of this exact head. PENDING is an unsubmitted draft nobody can see; DISMISSED was explicitly
  # revoked. Neither is the reviewer having spoken, so neither counts as findings.
  hits="$(printf '%s' "$reviews" | jq -r --arg sha "$head" --argjson who "$whojson" '
      [ .[]
        | select((.commit_id // "") == $sha)
        | select(((.state // "") | ascii_upcase) as $st | $st != "PENDING" and $st != "DISMISSED")
        | ((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; ""))
        | select(. as $l | $who | index($l)) ] | unique | .[]' 2>/dev/null)" \
    || { echo "pr-watch: could not evaluate the reviews of PR #$n" >&2; return 20; }

  if [ -n "$hits" ]; then
    printf 'findings %s\n' "$head"
    echo "pr-watch: PR #$n at $head — reviewed with findings by: $(printf '%s' "$hits" | tr '\n' ' ')" >&2
    return 10
  fi

  # --- clean? a `+1` on the PR's opening post, NEWER than the head commit -----------------------
  # A pull request IS an issue as far as reactions go, so the opening post's reactions live at
  # `issues/N/reactions`, not `pulls/N/...`. --paginate because a busy PR can push the bot's
  # reaction off the first page behind human reactions, and a missed `+1` would keep a finished
  # watch running to its deadline.
  #
  # Deliberately NOT filtered server-side with `-f content=+1`: passing `-f` makes `gh api` switch
  # to POST, which would ADD a reaction rather than list them. Filtering in jq avoids the trap.
  reacts="$(read_list "repos/{owner}/{repo}/issues/$n/reactions?per_page=100" reactions "$n")" || return 20

  # The newest `+1` from any declared reviewer, as an ISO-8601 timestamp (empty if none).
  local plus1at
  plus1at="$(printf '%s' "$reacts" | jq -r --argjson who "$whojson" '
      [ .[]
        | select((.content // "") == "+1")
        | select((((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; ""))) as $l | $who | index($l))
        | (.created_at // "") | select(length > 0) ] | sort | last // ""' 2>/dev/null)" \
    || { echo "pr-watch: could not evaluate the reactions of PR #$n" >&2; return 20; }

  if [ -n "$plus1at" ]; then
    # A reaction carries no commit, so prove it POSTDATES the head commit. Only fetched on this
    # branch — the terminating case — so a still-pending poll never pays for it.
    cjson="$(gh api "repos/{owner}/{repo}/commits/$head" 2>/dev/null)" \
      || { echo "pr-watch: could not read the head commit of PR #$n" >&2; return 20; }
    commitdate="$(printf '%s' "$cjson" | jq -r '.commit.committer.date // .commit.author.date // ""' 2>/dev/null)" \
      || { echo "pr-watch: could not parse the head commit of PR #$n" >&2; return 20; }
    [ -n "$commitdate" ] \
      || { echo "pr-watch: could not date the head commit of PR #$n" >&2; return 20; }

    # Both values are ISO-8601 UTC (`...Z`) as GitHub returns them, so a LEXICOGRAPHIC compare is
    # a chronological one — no date parsing, which is exactly where a bash-3.2/macOS-vs-GNU split
    # would otherwise appear (`date -d` vs `date -j`).
    #
    # THE BACKSLASH IN `\>` IS LOAD-BEARING — do not "clean it up". Unescaped, `>` inside `[ ]` is
    # a REDIRECTION: the test would silently become `[ "$plus1at" ]` (true for any non-empty
    # string) while creating a file named after the commit date, so EVERY `+1` would read as fresh
    # and the staleness rule — the one direction this module must never be wrong in — would be
    # gone with no error anywhere. Note also that `[ a \> b ]` is a bash string comparison, not a
    # POSIX `test` one; this file is bash by shebang and every caller invokes it as `bash <path>`,
    # which is the repo-wide convention. It does NOT work under zsh.
    if [ "$plus1at" \> "$commitdate" ]; then
      printf 'clean %s\n' "$head"
      echo "pr-watch: PR #$n at $head — clean pass signalled at $plus1at (head committed $commitdate)" >&2
      return 0
    fi
    printf 'pending %s\n' "$head"
    echo "pr-watch: PR #$n — a '+1' exists but predates this head ($plus1at <= $commitdate); it reviewed an earlier commit" >&2
    return 11
  fi

  printf 'pending %s\n' "$head"
  echo "pr-watch: PR #$n at $head — no terminal signal yet from: $(printf '%s' "$want" | tr '\n' ' ')" >&2
  return 11
}

cmd_observe() {
  local n want wrc
  [ -n "$OPT_PR" ] || { echo "pr-watch: observe requires --pr <number|url>" >&2; return 2; }
  n="$(parse_pr_arg "$OPT_PR")" \
    || { echo "pr-watch: '--pr $OPT_PR' is not a PR number or a GitHub PR URL" >&2; return 2; }
  want="$(read_declared_bots)"; wrc=$?
  [ "$wrc" -eq 0 ] || return "$wrc"
  adb_require_gh jq || return 20
  classify "$n" "$want"
}

cmd_wait() {
  local n want wrc rc out deadline remaining nap unreadable=0 lasthead="" head

  [ -n "$OPT_PR" ] || { echo "pr-watch: wait requires --pr <number|url>" >&2; return 2; }
  n="$(parse_pr_arg "$OPT_PR")" \
    || { echo "pr-watch: '--pr $OPT_PR' is not a PR number or a GitHub PR URL" >&2; return 2; }
  require_uint "$OPT_INTERVAL" --interval || return 2
  require_uint "$OPT_MAX_SECS" --max-secs || return 2

  # Read the declaration ONCE, before the loop: it is repo configuration, not live state, and
  # re-reading it every poll would let an edit mid-watch silently change what is being waited for.
  want="$(read_declared_bots)"; wrc=$?
  [ "$wrc" -eq 0 ] || return "$wrc"
  adb_require_gh jq || return 20

  # $SECONDS is a bash builtin (no fork, works on bash 3.2) counting seconds since shell start.
  # Compute the DEADLINE once rather than keeping a start-time and a duration and subtracting both
  # every pass: the name is then true, and it stays correct when the file is run from a shell whose
  # $SECONDS did not start at 0.
  deadline=$(( SECONDS + OPT_MAX_SECS ))

  # Report an interruption honestly rather than letting the shell's default status stand in for a
  # verdict: an operator ^C is "we stopped watching", which is `pending`, not `clean`. `exit`, not
  # `return`: a trap handler runs in the current shell context, so `return` inside one is only
  # meaningful while a function frame happens to be live and its status is easy to lose. This file
  # is a run-only entry point (the dispatch below executes on load), so exiting is unambiguous.
  trap 'echo "pr-watch: interrupted — no terminal verdict reached" >&2; exit 11' INT TERM

  while :; do
    out="$(classify "$n" "$want")"; rc=$?
    head="${out##* }"

    case "$rc" in
      0|10|12|2|17|18)
        printf '%s\n' "$out"
        trap - INT TERM
        return "$rc" ;;
      20)
        unreadable=$(( unreadable + 1 ))
        if [ "$unreadable" -ge "$_ADB_PW_MAX_UNREADABLE" ]; then
          echo "pr-watch: $unreadable consecutive unreadable polls — giving up rather than guessing" >&2
          trap - INT TERM
          return 20
        fi
        echo "pr-watch: unreadable poll $unreadable/$_ADB_PW_MAX_UNREADABLE — retrying" >&2 ;;
      *)
        # pending: reset the unreadable streak, and say so when the head moves under us. No stored
        # evidence needs resetting — every poll re-derives its verdict from the CURRENT head — but
        # an operator watching the log should see that the clock effectively restarted.
        unreadable=0
        if [ -n "$lasthead" ] && [ "$head" != "$lasthead" ]; then
          echo "pr-watch: PR #$n head moved $lasthead -> $head; any earlier signal no longer applies" >&2
        fi
        lasthead="$head" ;;
    esac

    remaining=$(( deadline - SECONDS ))
    if [ "$remaining" -le 0 ]; then
      # Only echo a verdict line if the last poll actually produced one. An unreadable poll writes
      # nothing to stdout, so an unguarded print would emit a BARE NEWLINE — stdout is contracted
      # to be "<verdict> <sha>" or nothing at all, and a caller doing `read -r verdict sha` would
      # silently get two empty strings instead of noticing there was no answer. Reachable whenever
      # the deadline lands on a transient failure before the 3-strike arm fires.
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "pr-watch: PR #$n — bound of ${OPT_MAX_SECS}s expired with no terminal signal; handing off" >&2
      trap - INT TERM
      return 11
    fi
    # Never sleep past the deadline: a long interval would otherwise overshoot the bound by up to
    # one full interval, which makes `--max-secs` an approximation rather than a bound.
    nap="$OPT_INTERVAL"
    [ "$nap" -gt "$remaining" ] && nap="$remaining"
    sleep "$nap"
  done
}

# --- arg parsing -----------------------------------------------------------------------------
# `--pr` is REQUIRED for both subcommands. An optional PR would make the detector silently answer
# about the wrong thing the moment a caller forgot it.
#
# Every value-taking option checks its ARITY and its VALUE separately, so `--pr ''` reports "must
# not be empty" rather than the arity message for a flag that was in fact supplied. (The shared
# validator for this is #150; spelled out here until it lands.)
parse_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)
        [ "$#" -ge 2 ] || { echo "pr-watch: --pr needs a value" >&2; exit 2; }
        [ -n "$2" ] || { echo "pr-watch: --pr must not be empty" >&2; exit 2; }
        OPT_PR="$2"; shift ;;
      --interval)
        [ "$#" -ge 2 ] || { echo "pr-watch: --interval needs a value" >&2; exit 2; }
        [ -n "$2" ] || { echo "pr-watch: --interval must not be empty" >&2; exit 2; }
        OPT_INTERVAL="$2"; shift ;;
      --max-secs)
        [ "$#" -ge 2 ] || { echo "pr-watch: --max-secs needs a value" >&2; exit 2; }
        [ -n "$2" ] || { echo "pr-watch: --max-secs must not be empty" >&2; exit 2; }
        OPT_MAX_SECS="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "pr-watch: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  observe)   parse_opts "$@"; cmd_observe ;;
  wait)      parse_opts "$@"; cmd_wait ;;
  -h|--help) usage; exit 0 ;;
  *) echo "pr-watch: unknown subcommand '$SUB' (expected 'observe' or 'wait')" >&2; usage >&2; exit 2 ;;
esac
