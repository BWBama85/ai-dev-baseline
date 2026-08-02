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
# PRECEDENCE, AND WHERE IT IS DECIDED. Findings outrank clean, and a reviewer that left a stale `+1`
# from an earlier pass AND has now commented has something to say about this head. The rule itself is
# NOT spelled in this file: it is the shared per-reviewer classifier in common.sh
# (`adb_reviewer_evidence` + `adb_reviewer_classes`), which both this module and `pr-review.sh gate`
# fold — so the two can no longer disagree about what a signal MEANS (#167) or about how many
# reviewers must have produced one (#185). This module maps `rejected`/`attention` to `findings`,
# `clean` to a pass, and requires EVERY declared reviewer to be clean before reporting one.
#
# WHAT THIS ONCE COST THE CALLER, AND NO LONGER DOES. `pr-review.sh gate` used to read only
# `pulls/N/reviews`, so a CLEAN Codex pass — which posts no review — never satisfied it: 16
# ("awaiting review") forever, with unattended arming off on precisely the PRs that were cleanest,
# and 16 on EVERY PR for a repo whose connector runs in task mode. #167 taught that guard to read
# all three surfaces through the same classifier, so the asymmetry this paragraph used to describe
# is gone. What #167 did NOT do is re-arm automatically — `/implement-issue` still asks the gate
# once, seconds after the PR opens, when no async reviewer has responded (#168).
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
# Three other server-assigned anchors were considered and rejected, each wrong in a way that is not
# obvious; the argument is kept with the code (see WHY NOT THE OBVIOUS ANCHORS, below the dispatch
# preamble) rather than here, because this block is `--help` and an operator does not need an essay
# about designs that were not built.
#
# WHEN THE ANCHOR CANNOT BE ESTABLISHED — a head SHA absent from the ref's recent activity, a head
# repository that no longer exists — the verdict is `pending`. Never `clean`: an unproven signal is
# not a pass. Note that none of this needs CI to exist, so a repo without any keeps the clean signal.
#
# ONE THING THIS MOVED, WORTH KNOWING BEFORE YOU DEBUG IT: the anchor is read from the HEAD
# repository (`head.repo.full_name`), not the base one every other read here addresses — a ref's
# history lives where the ref lives. On a same-repo pull request, which is what `/implement-issue`
# creates, those are the same place. On a FORK pull request they are not: a public fork reads fine,
# but one the caller cannot read answers 403, which is an unreadable read (20) rather than `pending`
# — so `wait` gives up after its unreadable-poll streak instead of running to the bound. Both are
# safe (neither is `clean`) and both hand off to a human, but they hand off differently, and "20 on
# a fork PR" is otherwise a confusing thing to meet.
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
# generalization and is tracked as #186 (#170 was folded into #167 and closed).
#
# Exit codes are a stable machine contract for the workflow step that consumes them. They are
# deliberately DISJOINT from pr-review.sh's 16–20 where the meanings differ, and identical where
# they are the same question (17/18/20), so a caller can never confuse the two guards.
#
#   0  clean      — a declared reviewer signalled a clean pass for the CURRENT head, or the repo
#                   declared `[reviewers] bots = []` (nothing is coming). STDOUT: "clean <sha>".
#   10 findings   — a declared reviewer submitted a review attached to the CURRENT head SHA. The
#                   caller should run the resolve flow. STDOUT: "findings <sha>".
#   11 pending    — no terminal signal yet, OR a signal exists whose freshness cannot be PROVED
#                   because the head's arrival could not be established (#175). Those two share a
#                   code but not a remedy — the first means wait longer, the second means this
#                   signal will never be provable — so the stderr line says which. From `wait`, the
#                   bound expired while still pending: hand off to a human. STDOUT: "pending <sha>".
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
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

# ------------------------------------------------------------------------------------------------
# WHERE THE STALENESS ANCHOR WENT (#167). `head_anchor` and `is_utc_instant` were PRIVATE to this
# file until `pr-review.sh gate` needed the same predicate at higher stakes — a date-scoped signal
# it accepts authorizes an ARMED MERGE. They now live in common.sh as `adb_head_anchor` and
# `adb_is_utc_instant`, with neutral codes (0 anchor / 1 unestablished / 2 unreadable) each caller
# maps to its own vocabulary, and the rejected-candidate argument travelled with them.
#
# D19 recorded that promotion as #167's FIRST step rather than something to copy, for a stated
# reason: #173 exists because two private copies of the PR primitives diverged into a live
# fail-open. Do not re-inline either function here.
# ------------------------------------------------------------------------------------------------

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
# recomputes is how a poll loop quietly doubles.)
#
# A full 30-minute watch at 30s is ~240 requests with no signal present — but price the OTHER regime
# too, because it is the common one and pricing the exception as the rule is how this comment went
# stale the first time. A `+1` or task-mode comment from a PREVIOUS head PERSISTS on the PR, so it
# satisfies the anchor's guard on EVERY poll until it is proved fresh or the watch expires. That is
# the ordinary state of a PR that got a clean pass and was then pushed to — exactly what `--watch`
# is for — and it costs the fifth read every poll: ~300 requests, +25%. Against an authenticated
# limit of 5000/hour both are comfortable but neither is free, which is why the interval is tunable
# and why the clean/findings checks short-circuit the moment either lands.
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
# the `$(( deadline - BASH_MONOSECONDS ))` arithmetic below, so `--max-secs 99999999999999999999` would pass
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

# THE PAGINATED SIGNAL READ LIVES IN common.sh as `adb_paginated_list`. It was private here until
# the arming guard grew the same two extra surfaces (#167), at which point keeping it would have
# made FIVE copies of one fail-closed read across two files — the third-duplication #167 §6 names
# explicitly. Do not re-inline it: the empty-result check is the half an edit drops, and dropping it
# turns an unreadable response into "nothing found yet", which is a withhold that looks harmless
# while the watcher polls a broken API to its deadline.

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
  local classes verdict

  # THE IDENTITY PREDICATE IS NO LONGER APPLIED HERE. `adb_reviewer_match_jq` used to be hoisted into
  # a local and pasted in front of three separate jq passes in this function; all three now happen
  # inside `adb_reviewer_evidence`, which prepends it once. Reaching for it directly again would
  # re-create the per-surface copies #173 removed — and, worse, would mean this file was selecting
  # evidence on its own terms rather than the shared ones (#167).

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

  # The whole read-and-classify pipeline is ONE shared call (#167): three surface reads, evidence
  # selection, the conditional head-arrival anchor, and the per-reviewer classification. Both this
  # module and the arming guard used to open-code those six steps identically, differing only in a
  # label — including the decision about when to fetch the anchor, which was a pattern match against
  # a record format common.sh owns. What stays here is the mapping below: this module's own verdicts.
  classes="$(adb_reviewer_classes_for_pr pr-watch "$n" "$want" "$head" "$headslug" "$headref")" \
    || { echo "pr-watch: PR #$n — could not read the review state" >&2; return 20; }
  verdict="$(adb_fold_reviewer_classes "$classes")"

  # --- map the shared classification onto THIS module's vocabulary ------------------------------
  # `gate` maps the same classes to entirely different codes; that is the point of sharing a
  # classifier rather than a verdict (#167 §4).
  case "$verdict" in
    rejected|attention)
      printf 'findings %s\n' "$head"
      echo "pr-watch: PR #$n at $head — reviewed with findings by: $(adb_reviewers_in_class "$classes" rejected attention)" >&2
      echo "pr-watch: inline threads may not exist at all (a task-mode signal creates none), so READ THE COMMENT or review body" >&2
      return 10 ;;
    unknown)
      echo "pr-watch: PR #$n at $head — could not classify the signal from: $(adb_reviewers_in_class "$classes" unknown)" >&2
      return 20 ;;
    clean)
      printf 'clean %s\n' "$head"
      echo "pr-watch: PR #$n at $head — every declared reviewer signalled a clean pass" >&2
      return 0 ;;
    *)
      printf 'pending %s\n' "$head"
      # No flag distinguishing "nobody has spoken" from "somebody spoke unprovably": when the anchor
      # could not be established `adb_head_anchor` has ALREADY said so on stderr, and in more precise
      # words than a re-statement here could ("no recorded activity puts <sha> on refs/heads/<ref>",
      # or "no head repository/ref … deleted fork?"). Carrying a boolean to paraphrase a line that
      # was already printed is state that can only go out of date.
      echo "pr-watch: PR #$n at $head — no terminal signal yet from: $(adb_reviewers_in_class "$classes" none)" >&2
      return 11 ;;
  esac
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

  # $BASH_MONOSECONDS is a bash 5.3 builtin (no fork) reading CLOCK_MONOTONIC. It replaced $SECONDS
  # here under the 5.3 floor (#258), and the difference is not cosmetic: $SECONDS is `time(NULL)`
  # minus the shell's start, so it MOVES WITH THE WALL CLOCK. An ntp step or a manual clock change
  # during a half-hour watch — which is exactly the length this loop is built for — either expires
  # the bound early or extends it indefinitely. The monotonic clock does not move that way.
  #
  # SAY THE GUARANTEE EXACTLY, because the obvious stronger sentence is false. "$BASH_MONOSECONDS
  # cannot be moved by anyone" is wrong: while the variable retains its special nature bash refuses
  # a direct assignment, but `unset BASH_MONOSECONDS` STRIPS that nature, after which it is an
  # ordinary writable variable (measured; the independent review found the overclaim). What is
  # actually true, and sufficient here: this file is an EXECUTED entry point — it gates its own
  # interpreter above and dispatches unconditionally on load, never sourced — and an executed bash
  # constructs the special variable afresh regardless of what the environment carried. So the
  # guarantee is against the SYSTEM CLOCK, not against an in-process caller; and an in-process
  # caller who can `unset` a shell variable can already run anything this file could.
  # Pinned in check-pr-watch.sh, T1 (the property) and T2 (that this code reads it).
  #
  # Compute the DEADLINE once rather than keeping a start-time and a duration and subtracting both
  # every pass: the name is then true, and it stays correct whatever the counter's origin happens
  # to be — which is why a shell whose clock did not start at 0 was never the problem worth solving.
  deadline=$(( BASH_MONOSECONDS + OPT_MAX_SECS ))

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

    remaining=$(( deadline - BASH_MONOSECONDS ))
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
