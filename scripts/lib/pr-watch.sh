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
# THE SIGNALS — THREE PLACES A REVIEWER CAN SPEAK, AND WHY ALL THREE ARE READ
#
# The Codex connector documents its own contract in every lightweight review body it posts:
#
#     "If Codex has suggestions, it will comment; otherwise it will react with 👍."
#
# That is true, but it describes only ONE of its two operating modes, and which mode a repo gets
# depends on configuration rather than on anything in the PR:
#
#   no Codex Cloud environment → LIGHTWEIGHT REVIEW mode
#       findings → a `COMMENTED` review object, usually with inline threads; no reaction
#       clean    → a `+1` reaction on the PR's opening post; NO review object at all
#
#   a Cloud environment exists → TASK mode
#       findings → ONE ISSUE COMMENT summarising what it found or changed; NO review object,
#                  NO inline threads, and (so far) no reaction either
#
# All of this was observed live on this repo INSIDE ONE DAY, which is the whole argument for
# reading every surface rather than the documented one:
#
#   PRs #53/#54/#66/#83/#88 → a connector `+1`, zero reviews, zero threads      (clean, mode 1)
#   PRs #127/#137/#145/#146/#154/#166 → one review, 1–4 threads, no reaction    (findings, mode 1)
#   PR #166 at 08:01 → mode 1.  PR #178 at 19:30 → mode 2 (one issue comment,
#                      zero reviews, zero threads), after an environment was created in between.
#
# A detector that reads only reviews and reactions therefore sits at `pending` FOREVER on a repo
# configured the second way — the exact wedge this module exists to remove from the arming guard,
# reintroduced by a vendor-side configuration change nobody in the repo made. So: reviews (SHA-
# scoped), issue comments (date-scoped), and reactions (date-scoped) are all read.
#
# The issue that asked for this described a further transient state — a 👀 reaction while the review
# is running, removed when findings are posted. This module deliberately does NOT model it. The
# reactions API exposes only reactions that exist RIGHT NOW, never deletion history, so "👀 was here
# and then vanished" is knowable only to a watcher that happened to be looking across the
# transition. A detector that needed it could not answer correctly after a restart, a resumed
# watch, or a late start — exactly the cases an unattended watcher must survive. Polling for the
# TERMINAL signals instead is restart-safe, idempotent, and needs no memory of what came before.
#
# PRECEDENCE: findings outrank clean, and within findings a review at the head SHA outranks a
# comment. A reviewer that left a stale `+1` from an earlier pass AND has now commented has
# something to say about this head.
#
# WHAT THIS COSTS THE CALLER. `pr-review.sh gate` reads only `pulls/N/reviews`, so a CLEAN Codex
# pass — which posts no review — never satisfies it: it returns 16 ("awaiting review") forever, and
# unattended arming stays off on precisely the PRs that are cleanest. This module reports that case
# correctly as `clean`. Teaching the ARMING guard to accept a reaction is a change to when merges
# happen and is deliberately left to its own issue, not folded in here.
#
# ------------------------------------------------------------------------------------------------
# STALENESS: A REACTION IS NOT COMMIT-SCOPED, SO THE PROOF MUST BE SERVER-ASSIGNED
#
# A review carries `commit_id`, so "did the reviewer review THIS head?" is a field comparison. A
# reaction carries no commit at all — only `created_at` — and an issue comment is the same. A `+1`
# left on an earlier head therefore still sits there after new commits land, and reading it naively
# would report `clean` for code nobody reviewed. That is the one direction this module must never be
# wrong in, so a date-scoped signal counts only when it POSTDATES the moment the current head became
# this pull request's head.
#
# WHERE THAT MOMENT IS READ FROM, AND WHY IT IS NOT THE COMMIT (#175). The obvious lower bound — the
# head commit's committer date — is CLIENT-SUPPLIED: git records `GIT_COMMITTER_DATE` verbatim and
# GitHub echoes back whatever the committing machine claimed. The reaction's timestamp is
# GitHub-assigned, so the comparison was ASYMMETRIC IN ITS TRUST, and only one direction was safe:
#
#   commit dated in the FUTURE  → a genuine `+1` looked stale → `pending`. Safe: waits longer.
#   commit dated in the PAST    → a STALE `+1` looked fresh   → `clean`. A FALSE PASS.
#
# No attacker is needed for the second: a date-preserving rebase
# (`--committer-date-is-author-date`, `filter-repo`) or simply a machine whose clock is behind by
# more than the review latency produces it.
#
# The anchor is now the REPOSITORY ACTIVITY API — the latest activity on the head REF whose `after`
# SHA is the current head. Its `timestamp` is stamped by GitHub when the ref moved, so it answers
# the question directly ("when did this ref become this SHA") instead of approximating it, and it
# covers ordinary pushes, force-pushes and branch creation alike.
#
# THE THREE ANCHORS THAT WERE REJECTED, because each is wrong in a way that is not obvious, and the
# next person to read this will otherwise reach for one of them:
#
#   * the earliest CHECK-SUITE `created_at` for the head SHA is server-assigned, but it is scoped to
#     the SHA, not to the REF. A commit that already ran CI elsewhere carries its ORIGINAL
#     timestamp, so an ordinary fast-forward onto it PRESERVES the fail-open: suite for C at 09:00,
#     a stale `+1` at 10:00, an ordinary `B → C` at 11:00 → 10:00 > 09:00 → `clean`, still false.
#     No force-push happens there, so pairing it with a force-push term does not rescue it. Commit
#     STATUSES have exactly the same flaw, and both also need the repo to HAVE ci.
#   * the PR TIMELINE's `head_ref_force_pushed` events are server-assigned and ref-scoped, but they
#     exist only for FORCE pushes — an ordinary push appears nowhere in them.
#   * `head.repo.pushed_at` is server-assigned, ref-agnostic and free (it is already in the PR
#     object read above), and it is SOUND: it can only ever be too LATE, i.e. a false `pending`,
#     never a false `clean`. It is rejected for LIVENESS, not for safety — it is REPO-scoped, so a
#     push to any unrelated branch after the reaction re-opens a settled verdict, and on an active
#     repo a watch would run to its bound instead of converging.
#
# WHEN THE ANCHOR CANNOT BE ESTABLISHED — a head SHA absent from the ref's recent activity, a head
# repository that no longer exists — the verdict is `pending`. Never `clean`: an unproven signal is
# not a pass. Note that none of this needs CI to exist, so a repo without any keeps the clean signal.
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
# THE EXCEPTIONS THAT REMAIN, stated because a guarantee with unlisted holes is worse than an honest
# one. Both are filed, and NEITHER is a skew or a forgeable timestamp — that class is closed:
#
#   * THE VERDICT IS TRUE OF THE SHA PRINTED BESIDE IT, WHICH MAY NO LONGER BE THE HEAD (#215). The
#     head is read once, at the top of a classification, and a terminal verdict is returned without
#     re-reading it — so a push landing inside that window (4–5 reads) is answered about the
#     previous SHA. This is why stdout is `"<verdict> <sha>"` and not a bare verdict: the SHA the
#     answer is about is IN the answer, and a caller that acts on `clean` can compare it to the live
#     head. Pre-existing; #174's single-read collapse removes the window rather than detecting it.
#   * A RETARGETED BASE CHANGES THE REVIEWED DIFF WITHOUT CHANGING THE HEAD (#216). Every rule here
#     is anchored to the head; none is anchored to the base. Retarget a PR and the diff the reviewer
#     was asked about changes while the head SHA stays byte-identical, so an earlier clean signal
#     survives it. Deliberately not folded into #175: that anchor answers "did this postdate this
#     HEAD", and anchoring to the base as well has a real liveness cost that needs its own decision.
#
# The exception this header used to carry — a BIDIRECTIONAL `[bot]` normalization, under which
# a declaration of `foo[bot]` was also satisfied by a human account literally named `foo` — is CLOSED
# (#173, superseding #176). The match is now asymmetric: the API login is normalized toward the
# declaration and never the reverse. The rule, and what a bare declaration means, live in common.sh's
# `adb_reviewer_match_jq`. Note for anyone tempted to reach for a type filter instead: `user.type`
# does NOT discriminate — verified live, the reactions endpoint reports `type: "User"` for the Codex
# connector while the reviews endpoint reports `type: "Bot"` for the same App, so it would reject the
# real signal.
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
# COST OF A POLL: FOUR reads — the PR, its reviews, its issue comments, its reactions — plus a
# FIFTH, the head ref's activity, only on the branch where a date-scoped signal was actually found.
# (This comment said "three" for as long as the comments read has existed; a budget nobody
# recomputes is how a poll loop quietly doubles.) A full 30-minute watch at 30s is therefore ~240
# requests against an authenticated limit of 5000/hour: comfortable, but not free, which is why the
# interval is tunable and why the clean/findings checks short-circuit the moment either lands.
#
# The anchor read is ONE request and is deliberately NOT `--paginate`d: activity comes back newest-
# first, filtered server-side to the head ref, so the answer is on page one or the head is old
# enough that no anchor is established — which is `pending`, the safe side. An unbounded paginated
# scan for a bound that is only ever used to REFUSE would be paying by PR age for nothing.
# Collapsing the reads into one GraphQL query is #174 (the sibling of #147, which makes the same
# argument about the arming guard but is scoped to that file only).
OPT_INTERVAL=30
OPT_MAX_SECS=1800
# Consecutive unreadable polls tolerated before `wait` gives up. A single 502/rate-limit must not
# abandon a 30-minute watch, but an endlessly unreadable API must not be waited on forever either.
_ADB_PW_MAX_UNREADABLE=3

# --- helpers ---------------------------------------------------------------------------------

# The PR-argument and repository-identity primitives this file used to carry privately —
# `parse_pr_arg`, `parse_pr_slug`, and the URL-slug cross-check — now live in common.sh as
# `adb_pr_number`, `adb_pr_slug` and `adb_pr_slug_check` (#173). pr-review.sh carried its own copies
# of the same three, and they had already diverged: this file's three-form slug parser was the
# stronger one, so its sibling let a scheme-less cross-repo URL through. One home, so a fix to either
# reaches both. Do not re-inline them.

# require_uint <value> <option-name> — a positive integer, or usage. Rejects the empty string, a
# sign, and any non-digit; a zero interval would spin the poll loop as a busy-wait and a zero bound
# would make `wait` return before its first read.
#
# The LENGTH bound is not belt-and-braces: an all-digit value wider than a shell integer overflows
# the `$(( deadline - SECONDS ))` arithmetic below, so `--max-secs 99999999999999999999` would pass
# a digits-only check and then produce a nonsense (possibly negative) remaining time — a "bound"
# that expires immediately or never. 18 digits is the same ceiling `roadmap-lib.sh`'s `is_uint`
# documents for the same reason; the shared validator is #181 (which consolidated #150).
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

# is_utc_instant <value> — exactly `YYYY-MM-DDTHH:MM:SSZ`, the one format the comparisons below are
# allowed to see.
#
# THIS IS NOT DEFENSIVE PADDING, it is what makes a LEXICOGRAPHIC compare a CHRONOLOGICAL one. That
# equivalence holds only while every operand is the same width, the same precision and the same
# zone: `2026-07-25T09:00:00-04:00` sorts BEFORE `2026-07-25T05:00:00Z` as a string and AFTER it as
# an instant, and sub-second precision (`…:00.123Z`) silently loses to `…:01Z` on a prefix compare.
# GitHub returns plain `…Z` on every endpoint this file reads — verified live on reactions, issue
# comments and repository activity — but "verified today on four endpoints" is a weaker claim than a
# check, and the documented example payload for the check-suite anchor that was REJECTED here
# carries a `-04:00` offset, so the format is demonstrably not uniform across the API as a whole.
#
# Rejecting rather than normalizing is deliberate: parsing an offset back to UTC in portable shell
# means `date -d` vs `date -j` (the exact GNU/BSD split this file avoids everywhere else), and a
# format this module has never seen is a reason to stop, not to improvise a conversion.
is_utc_instant() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
    *) return 1 ;;
  esac
}

# head_anchor <pr-number> <head-repo-slug> <head-ref> <head-sha> — the SERVER-ASSIGNED instant at
# which the head ref became the current head SHA. Prints it on stdout.
#
#   0  → the anchor is on stdout, validated
#   11 → no anchor could be established; the caller MUST fall to `pending`, never `clean`
#   20 → the read failed, or what came back could not be parsed
#
# WHY THE ACTIVITY API AND NOT THE COMMIT: see the STALENESS section of the header. In one line —
# the commit's date is whatever the committing machine claimed, and this is whatever GitHub
# recorded when the ref actually moved.
#
# THE LATEST MATCH, NOT THE EARLIEST, and that choice IS the force-push defence: a ref that went
# A → B → A carries two activities whose `after` is A, and only the later one says when it is A
# *now*. Taking the earliest would date the current head from a push that was superseded and then
# undone — precisely the "force-push back to an older commit" path this issue names.
head_anchor() {
  local n="$1" slug="$2" ref="$3" head="$4" raw at
  # A head repository that no longer exists (the fork was deleted) is a REAL state, not a broken
  # response: the PR still reads fine, there is simply nowhere left to ask. That is an unestablished
  # anchor (11), not an unreadable one (20) — the distinction the whole module is built on.
  [ -n "$slug" ] && [ -n "$ref" ] \
    || { echo "pr-watch: PR #$n — no head repository/ref to date the head against (deleted fork?)" >&2
         return 11; }
  # Interpolated into a URL PATH, so it must be a well-formed pair before it goes anywhere near one.
  adb_is_repo_slug "$slug" \
    || { echo "pr-watch: PR #$n reports a malformed head repository ('$slug')" >&2; return 20; }

  # `--method GET` with `-f` is REQUIRED, and the reason is the same trap the reactions read
  # documents: a bare `-f` makes `gh api` switch to POST. Here that would POST to the activity
  # endpoint rather than read it. `-f` also URL-ENCODES the value, which a hand-built query string
  # would not — and a ref name may legally contain `&` or `%`, either of which silently truncates or
  # corrupts an unencoded query.
  #
  # `direction=desc` is explicit rather than inherited from the endpoint's default: the whole point
  # of one un-paginated page is that the newest activity is ON it.
  raw="$(gh api --method GET "repos/$slug/activity" \
           -f ref="refs/heads/$ref" -f direction=desc -f per_page=100 2>/dev/null)" \
    || { echo "pr-watch: could not read the ref activity of PR #$n" >&2; return 20; }
  # Read, then parse — the same split every other read here uses. An empty body is NOT an empty
  # list: a successful read of a ref with no activity returns `[]`, so nothing at all means the call
  # produced no document and must not be mistaken for "no matching activity" (which is 11, a much
  # weaker statement than 20 and one a caller may sit on).
  [ -n "$raw" ] \
    || { echo "pr-watch: could not read the ref activity of PR #$n" >&2; return 20; }
  # Fail loudly on a shape that is not the documented array — `error` here surfaces as rc 20 rather
  # than letting a wrapped error object iterate to zero matches and read as a clean "no anchor".
  at="$(printf '%s' "$raw" | jq -r --arg sha "$head" --arg ref "refs/heads/$ref" '
      if type != "array" then error("activity response is not a JSON array") else . end
      | [ .[]
          | select((.after // "") == $sha)
          | select((.ref // "") == $ref)
          | (.timestamp // "") | select(length > 0) ]
      | sort | last // ""' 2>/dev/null)" \
    || { echo "pr-watch: could not parse the ref activity of PR #$n" >&2; return 20; }

  # The ref match is belt AND braces on purpose: `ref=` is applied server-side, but a filter that is
  # ignored (a param renamed, an endpoint that stops honouring it) would silently widen this read to
  # the whole repository, and an `after` SHA is unique enough that the widened read would still
  # usually match — dating this PR's head from a push to some other branch.
  [ -n "$at" ] \
    || { echo "pr-watch: PR #$n — no recorded activity puts $head on refs/heads/$ref, so a date-scoped signal cannot be proved fresh" >&2
         return 11; }
  is_utc_instant "$at" \
    || { echo "pr-watch: PR #$n — ref activity reported an unrecognized timestamp format ('$at')" >&2
         return 20; }
  printf '%s' "$at"
}

# read_declared_bots — the declared reviewer set in the comparison form, or this module's code for
# why it could not be read. Prints the normalized, de-duplicated login set on stdout.
#
# The work is done by `role-dispatch.sh bots --comparable`, which owns the `[reviewers]` key: the
# status mapping, the normalization, and the "declared something unusable" rejection were duplicated
# here and in pr-review.sh and now live there once (#173). What stays here is this module's own
# wording for a broken install — the one line of the four that genuinely differs between the two
# guards ("refusing to guess" vs "refusing to arm").
#
# `bash <path>` rather than sourcing: role-dispatch.sh supports sourced use, but shelling out keeps
# its globals and shell options out of this file and preserves the process boundary both harnesses
# exercise. Its stderr is deliberately NOT suppressed — on a malformed declaration it names the exact
# problem, which is the whole value of code 18.
read_declared_bots() {
  local want drc
  want="$(bash "$_ADB_PW_ROLE_DISPATCH" bots --comparable)"; drc=$?
  case "$drc" in
    0)     ;;
    17|18) return "$drc" ;;
    *)     echo "pr-watch: could not read '[reviewers] bots' (broken install) — refusing to guess" >&2
           return 20 ;;
  esac
  printf '%s' "$want"
}

# --- the detector ------------------------------------------------------------------------------

# classify <pr-number> <declared-logins> — one bounded classification of the PR's review state.
# Prints "<verdict> <head-sha>" on stdout; returns this module's exit code for that verdict.
# Every read is fresh: this is called once per poll, so a head that moves mid-watch is picked up on
# the next pass without any stored state to reset (base/practices/verify-before-asserting.md).
classify() {
  local n="$1" want="$2" pjson pfields head state merged gotslug src headslug headref
  local reviews hits reacts anchor arc at whojson comments commented match

  # The declared set as a JSON array, built ONCE: all three jq passes below test membership against
  # it, and re-deriving it per pass would fork a second jq for the same value.
  whojson="$(printf '%s' "$want" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" \
    || { echo "pr-watch: could not build the reviewer set" >&2; return 20; }

  # The identity predicate, as a jq prelude prepended to each of those three passes. Read ONCE into a
  # variable rather than substituted three times, so all three provably ask the SAME question — three
  # inline copies of the rule is exactly what this issue removed (#173). It is a constant program;
  # the declarations reach jq through --argjson, never concatenated into the source.
  match="$(adb_reviewer_match_jq)"

  # Read, then parse — two steps, deliberately. Folding the extraction into `gh --jq` makes one
  # status cover both the network read and the shape of what came back, so a PR object that
  # arrived fine but carries no head SHA is indistinguishable from a failed call.
  pjson="$(gh api "repos/{owner}/{repo}/pulls/$n" 2>/dev/null)" \
    || { echo "pr-watch: could not read PR #$n" >&2; return 20; }
  # CAPTURE FIRST, then split, and CHECK THE STATUS. jq emits earlier expressions before it
  # evaluates later ones, so a jq that errors partway still writes usable-looking leading lines;
  # putting the substitution straight into the heredoc would discard the status that tells a
  # partial parse from a clean one.
  # `.head.repo.full_name` and `.head.ref` are read HERE rather than in a second call, because they
  # are the coordinates the staleness anchor is looked up by and they belong to the same snapshot as
  # the head SHA they describe. NOT case-folded, unlike the base slug: that one exists to be
  # COMPARED against the local remote (where case must not decide the answer), while these two are
  # interpolated into a URL and a ref name, both of which GitHub treats as case-sensitive.
  pfields="$(printf '%s' "$pjson" \
             | jq -r '(.head.sha // ""), (.state // "" | ascii_downcase), (.merged_at // ""), (.base.repo.full_name // "" | ascii_downcase), (.head.repo.full_name // ""), (.head.ref // "")' 2>/dev/null)" \
    || { echo "pr-watch: could not parse PR #$n" >&2; return 20; }
  { IFS= read -r head; IFS= read -r state; IFS= read -r merged; IFS= read -r gotslug
    IFS= read -r headslug; IFS= read -r headref; } <<EOF
$pfields
EOF
  [ -n "$head" ] \
    || { echo "pr-watch: could not resolve the head SHA of PR #$n" >&2; return 20; }

  # Prove these reads addressed the repository the caller meant. The base repo's slug is the ONLY
  # evidence of that, so a response without a well-formed one is unreadable — not "no slug to
  # compare"; guarding the comparison on its presence would make the check SILENTLY VANISH exactly
  # when the metadata is malformed. And this checkout's git `origin` is checked even for a bare
  # number, because a bare number names no repository while `GH_REPO` silently redirects the
  # placeholder expansion above — and `/resolve-pr-threads --watch` passes exactly that bare form.
  # Both rules, and the precedence between them, live in adb_pr_slug_check (#173).
  adb_pr_slug_check pr-watch "$n" "$OPT_PR" "$gotslug"; src=$?
  case "$src" in
    0) ;;
    2) return 2 ;;
    *) return 20 ;;
  esac

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
  hits="$(printf '%s' "$reviews" | jq -r --arg sha "$head" --argjson who "$whojson" \
      "$match"'
      [ .[]
        | select((.commit_id // "") == $sha)
        | select(((.state // "") | ascii_upcase) as $st | $st != "PENDING" and $st != "DISMISSED")
        | ((.user.login // "") | ascii_downcase)
        | select(adb_declared_reviewer($who)) ] | unique | .[]' 2>/dev/null)" \
    || { echo "pr-watch: could not evaluate the reviews of PR #$n" >&2; return 20; }

  if [ -n "$hits" ]; then
    printf 'findings %s\n' "$head"
    echo "pr-watch: PR #$n at $head — reviewed with findings by: $(printf '%s' "$hits" | tr '\n' ' ')" >&2
    return 10
  fi

  # --- findings? an ISSUE COMMENT from a declared reviewer, newer than the head commit ----------
  # The connector has TWO output shapes and which one you get depends on how it is configured:
  #
  #   without a Codex Cloud environment → a lightweight review: a `COMMENTED` review object plus
  #                                       inline threads (what the block above reads)
  #   with one                          → a Cloud TASK: a single issue comment summarising what it
  #                                       found or changed, and NO review object at all
  #
  # Observed live on this repo within one day: PR #166 (08:01) took the first shape — one review,
  # three inline threads; PR #178 (19:30), after an environment was created, took the second — one
  # issue comment, zero reviews, zero threads. A detector that reads only reviews therefore sits at
  # `pending` forever on a repo configured the second way, which is the same wedge this module
  # exists to remove from the arming guard. Read both.
  #
  # A comment is NOT commit-scoped, so it gets the reaction's staleness rule rather than the
  # review's SHA equality — see below.
  comments="$(read_list "repos/{owner}/{repo}/issues/$n/comments?per_page=100" comments "$n")" || return 20
  commented="$(printf '%s' "$comments" | jq -r --argjson who "$whojson" \
      "$match"'
      [ .[]
        | select((.user.login // "") | adb_declared_reviewer($who))
        | (.created_at // "") | select(length > 0) ] | sort | last // ""' 2>/dev/null)" \
    || { echo "pr-watch: could not evaluate the comments of PR #$n" >&2; return 20; }

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
  plus1at="$(printf '%s' "$reacts" | jq -r --argjson who "$whojson" \
      "$match"'
      [ .[]
        | select((.content // "") == "+1")
        | select((.user.login // "") | adb_declared_reviewer($who))
        | (.created_at // "") | select(length > 0) ] | sort | last // ""' 2>/dev/null)" \
    || { echo "pr-watch: could not evaluate the reactions of PR #$n" >&2; return 20; }

  # Neither a comment nor a reaction carries a commit, so both are proved against the SERVER's
  # record of when this ref became this head (#175). Read ONCE, and only when at least one candidate
  # exists — a poll with neither signal present is the common case and must not pay for it.
  #
  # An unestablished anchor is `pending` for BOTH signals, not just the clean one. That is a real
  # cost on the findings side — a task-mode comment goes unreported until the bound — and it is the
  # right trade anyway: one rule over both date-scoped signals is checkable, whereas keeping the
  # client-supplied date "just for comments" would leave the forgeable input in the file for a path
  # whose output feeds the same callers.
  if [ -n "$commented" ] || [ -n "$plus1at" ]; then
    # Validate the CANDIDATES too, not only the anchor: a comparison is only as sound as its
    # weaker operand, and these are the values an unrecognized format would arrive in.
    for at in "$commented" "$plus1at"; do
      [ -z "$at" ] || is_utc_instant "$at" \
        || { echo "pr-watch: PR #$n — a reviewer signal carries an unrecognized timestamp format ('$at')" >&2; return 20; }
    done
    anchor="$(head_anchor "$n" "$headslug" "$headref" "$head")"; arc=$?
    case "$arc" in
      0) ;;
      11) printf 'pending %s\n' "$head"
          echo "pr-watch: PR #$n at $head — a reviewer signal exists but the arrival of this head could not be established, so it cannot be proved fresh; refusing to report a pass" >&2
          return 11 ;;
      *)  return 20 ;;
    esac
  fi

  # FINDINGS OUTRANK CLEAN, so the comment is tested first: a reviewer that both commented and left
  # a stale `+1` from an earlier pass has something to say about this head.
  if [ -n "$commented" ] && [ "$commented" \> "$anchor" ]; then
    printf 'findings %s\n' "$head"
    echo "pr-watch: PR #$n at $head — the declared reviewer commented at $commented (this head arrived $anchor); no inline threads may exist, so READ THE COMMENT" >&2
    return 10
  fi

  if [ -n "$plus1at" ]; then
    # Both values are ISO-8601 UTC (`...Z`) — ASSERTED above by `is_utc_instant` rather than assumed,
    # because that is the sole precondition under which a LEXICOGRAPHIC compare is a chronological
    # one. Given it, no date parsing is needed, which is exactly where a bash-3.2/macOS-vs-GNU split
    # would otherwise appear (`date -d` vs `date -j`).
    #
    # THE BACKSLASH IN `\>` IS LOAD-BEARING — do not "clean it up". Unescaped, `>` inside `[ ]` is
    # a REDIRECTION: the test would silently become `[ "$plus1at" ]` (true for any non-empty
    # string) while creating a file named after the commit date, so EVERY `+1` would read as fresh
    # and the staleness rule — the one direction this module must never be wrong in — would be
    # gone with no error anywhere. Note also that `[ a \> b ]` is a bash string comparison, not a
    # POSIX `test` one; this file is bash by shebang and every caller invokes it as `bash <path>`,
    # which is the repo-wide convention. It does NOT work under zsh.
    if [ "$plus1at" \> "$anchor" ]; then
      printf 'clean %s\n' "$head"
      echo "pr-watch: PR #$n at $head — clean pass signalled at $plus1at (this head arrived $anchor)" >&2
      return 0
    fi
    printf 'pending %s\n' "$head"
    echo "pr-watch: PR #$n — a '+1' exists but predates this head ($plus1at <= $anchor); it reviewed an earlier commit" >&2
    return 11
  fi

  printf 'pending %s\n' "$head"
  echo "pr-watch: PR #$n at $head — no terminal signal yet from: $(printf '%s' "$want" | tr '\n' ' ')" >&2
  return 11
}

cmd_observe() {
  local n want wrc
  [ -n "$OPT_PR" ] || { echo "pr-watch: observe requires --pr <number|url>" >&2; return 2; }
  n="$(adb_pr_number "$OPT_PR")" \
    || { echo "pr-watch: '--pr $OPT_PR' is not a PR number or a GitHub PR URL naming a repository" >&2; return 2; }
  want="$(read_declared_bots)"; wrc=$?
  [ "$wrc" -eq 0 ] || return "$wrc"
  adb_require_gh jq || return 20
  classify "$n" "$want"
}

cmd_wait() {
  local n want wrc rc out deadline remaining nap unreadable=0 lasthead="" head

  [ -n "$OPT_PR" ] || { echo "pr-watch: wait requires --pr <number|url>" >&2; return 2; }
  n="$(adb_pr_number "$OPT_PR")" \
    || { echo "pr-watch: '--pr $OPT_PR' is not a PR number or a GitHub PR URL naming a repository" >&2; return 2; }
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
        # Same guard as the deadline path below, and for the same reason: `2` (a slug mismatch) and
        # the config codes print no verdict line, so an unguarded print would emit a bare newline
        # where the contract promises "<verdict> <sha>" or nothing at all.
        [ -n "$out" ] && printf '%s\n' "$out"
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
# validator for this is #181, which consolidated #150; spelled out here until it lands.)
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
