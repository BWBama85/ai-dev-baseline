#!/usr/bin/env bash
# ai-dev-baseline — the pre-arm review guard (issue #134).
#
# `/implement-issue` step 10 hands the merge to GitHub with `gh pr merge --auto`. GitHub then
# merges the instant the REQUIRED STATUS CHECKS pass. An async bot reviewer — a GitHub App that
# posts review threads minutes after the PR opens — is not a required check, so it can never gate
# anything. On PR #133 that race was not close: opened 20:55:32, green 20:55:55, merged 20:56:01,
# and the reviewer posted five findings at 21:02:19. All five were real bugs, merged unreviewed.
#
# `required_conversation_resolution` did not fail. It was BYPASSED BY TIMING: it only blocks a
# merge on threads that ALREADY EXIST, and at arming time there are none.
#
# So the wait has to happen BEFORE the arm, and that is all this module does: given a PR, answer
# "has every reviewer this repo declares already reviewed THIS head commit?" — and refuse to
# answer "yes" whenever it cannot prove it.
#
# WHY A SEPARATE MODULE. repo-settings.sh states its own boundary: "it is repo *settings*
# bookkeeping. It does not merge, review, tag, release, or deploy." Review state is per-PR, not a
# repo setting, so folding it in there (even as a new subcommand) would break that contract rather
# than respect it. `automerge-ok` keeps answering "will the CHECKS gate this?"; this module
# answers "has REVIEW happened?"; step 10 composes the two.
#
# ------------------------------------------------------------------------------------------------
# THREE SURFACES, NOT ONE (#167) — WHY THIS GUARD USED TO WEDGE AT 16 FOREVER
#
# This module read ONLY `pulls/N/reviews`. The Codex connector states its own contract in every
# lightweight review body it posts — "If Codex has suggestions, it will comment; otherwise it will
# react with 👍" — so on a CLEAN pass it posts NO REVIEW OBJECT AT ALL, only a `+1` reaction on the
# PR's opening post. The review had happened; this guard could not see it, classified the reviewer
# `pending`, and returned 16 forever. Unattended arming was off on precisely the cleanest PRs.
#
# And there is a wider shape. With a Codex Cloud environment the connector runs as a TASK and posts
# a SINGLE ISSUE COMMENT — no review, no threads, no reaction. On a repo configured that way this
# guard returned 16 on EVERY PR, so #87/#134's unattended arming was silently dead, disabled by a
# vendor-side setting nobody in the repo changed.
#
# Both shapes were observed live on this repo, and they are disjoint: PRs #53/#54/#66/#83/#88 carry
# a `+1` and zero reviews; #127/#137/#145/#146/#154/#166 carry a review and zero reactions; PR #184
# reproduced the wedge end-to-end (a connector `+1` at 21:33:47Z, zero reviews, `pr-watch observe`
# reporting clean while this guard returned 16, merged by hand). So all three surfaces are read.
#
# WHAT IS SHARED WITH pr-watch.sh IS A CLASSIFIER, NOT A VERDICT. The two modules ask different
# FINAL questions — "may I arm the merge now?" vs "is the reviewer done?" — so sharing one binary
# verdict is the trap. What they share is `adb_reviewer_evidence` + `adb_reviewer_classes` in
# common.sh: one neutral per-reviewer classification, which each module maps to its OWN exit codes.
# Answering it separately is how the two libraries already disagreed about what `APPROVED` means and
# about how many reviewers must have spoken (#185).
#
# ------------------------------------------------------------------------------------------------
# Usage:
#   pr-review.sh gate --pr <number|url>   # the pre-arm guard; prints the witnessed head SHA on 0
#   pr-review.sh -h | --help
#
# `gate` exit codes are a stable machine contract for the workflow step:
#   0  safe    — every declared reviewer signalled a CLEAN pass for the CURRENT head — an APPROVED
#                review at this SHA, or a `+1` proved newer than the moment this head arrived — or
#                the repo declared `[reviewers] bots = []` (no async reviewer). STDOUT is the
#                witnessed head SHA, which the caller MUST pass to `gh pr merge --match-head-commit`.
#   16 wait    — a declared reviewer has NOT spoken about this head SHA yet. Do not arm; the operator
#                merges after the review lands (or /resolve-pr-threads then a re-run).
#   17 unknown — the repo declares no `[reviewers] bots` at all, so whether a reviewer is coming
#                cannot be known. FAIL CLOSED. Declare the reviewers, or `bots = []` if there are
#                none. Deliberately NOT 20: the operator action is "declare it", not "retry".
#   18 config  — `[reviewers] bots` is present but malformed. Like 17 the remedy is "fix
#                agents.toml", not "retry", so it is not folded into 20.
#   19 rejected — a declared reviewer left CHANGES_REQUESTED on this head SHA. Distinct from 16:
#                the work exists and is described, rather than being waited for.
#   21 attention — REVIEW COMPLETE, ATTENTION REQUIRED (#167 §3). A declared reviewer left a
#                `COMMENTED` review at this head, or a fresh issue comment. The reviewer HAS spoken
#                and is NOT satisfied, so the arm is withheld and the operator reads what it said.
#                THIS IS DELIBERATELY NOT 0, and the distinction is the whole point: "the reviewer
#                has spoken" is not the same claim as "the reviewer is satisfied", and only the
#                second one makes arming safe. A fresh issue comment is the task-mode FINDINGS
#                shape — PR #178's sole Codex comment reported unresolved selfcheck warnings — so
#                mapping it to 0 would authorize auto-merging code the reviewer had just flagged:
#                the exact fail-open #134 exists to prevent, reintroduced through the fix for its
#                sibling. Distinct from 19 (nothing was formally rejected) and from 16 (nobody is
#                being waited for). NOTE FOR CALLERS: it is a NEW code — a `*)` arm that lumps it
#                in with 20 reports "unreadable, retry" for a PR whose review is sitting right there.
#   20 unknown — live state unreadable (API failure, no head SHA, an unrecognized review state, a
#                reviewer signal that cannot be dated). FAIL CLOSED, never assume reviewed.
#   2  usage   — bad or missing arguments.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is returning 0 when a reviewer is still coming.
# Every uncertainty above therefore resolves to a non-zero code, and there is no path where a
# failed read degrades into "no reviewers pending".
#
# REVIEWER IDENTITY IS NOT SPELLED HERE. The same GitHub App is reported as `foo` by GraphQL and
# `foo[bot]` by REST, and this module reads REST. The matching rule — asymmetric, so a declared
# `foo[bot]` is never satisfied by a human account named `foo` — lives once in common.sh as
# `adb_reviewer_match_jq`, and the declaration is normalized once by `role-dispatch.sh bots
# --comparable` (#173, superseding #176). Both were duplicated here and in pr-watch.sh, and the
# duplicate stripped the DECLARATION as well as the API login, which is the fail-open that removed
# a human account's inability to satisfy a declared App.
#
# What this file must never grow: it does not wait, poll, retry, resolve threads, or merge. A PR
# watch that waits for the review and then arms is issue #49; this is the cheap guard that stops
# the bleeding until that lands.
#
# Requires: gh (authenticated), jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_pr_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_pr_common="$_adb_pr_libdir/common.sh"
if [ ! -f "$_adb_pr_common" ]; then
  printf 'pr-review: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_pr_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_pr_common"

# role-dispatch.sh owns the `[reviewers]` manifest key; this module asks it rather than re-reading
# agents.toml, so the layering (repo -> global) can never drift between the two consumers. It sits
# beside this file — install.sh symlinks the whole scripts/lib dir, so the two always ship together.
_ADB_PR_ROLE_DISPATCH="$_adb_pr_libdir/role-dispatch.sh"

usage() { adb_usage "$0"; }

OPT_PR=""

# The PR-argument and repository-identity primitives this file used to carry privately —
# `parse_pr_arg`, `parse_pr_slug`, and the URL-slug cross-check — now live in common.sh as
# `adb_pr_number`, `adb_pr_slug` and `adb_pr_slug_check` (#173). They were duplicated in pr-watch.sh
# and had already DIVERGED: this file's slug parser handled only `scheme://…`, so a scheme-less
# `github.com/other/repo/pull/7` produced an empty slug, skipped the cross-repo refusal, and let this
# guard authorize an arm against a pull request the operator never named. Do not re-inline them.

# --- the guard -------------------------------------------------------------------------------

cmd_gate() {
  local n drc want head pjson pfields gotslug src headslug headref
  local classes verdict

  [ -n "$OPT_PR" ] || { echo "pr-review: gate requires --pr <number|url>" >&2; return 2; }
  n="$(adb_pr_number "$OPT_PR")" \
    || { echo "pr-review: '--pr $OPT_PR' is not a PR number or a GitHub PR URL naming a repository" >&2; return 2; }

  # Read the DECLARED reviewers first, before any network call: the `bots = []` and undeclared
  # answers need no API access at all, and an unauthenticated repo should not be told "unreadable"
  # when the real answer is "you have not declared reviewers".
  #
  # `--comparable` returns the set already normalized for matching, and returns this module's own
  # 17/18 for why it could not be — the mapping, the normalization and the "declared something
  # unusable" rejection all live once in role-dispatch.sh, which owns the `[reviewers]` key (#173).
  #
  # `bash <path>`, never `<path>` directly: scripts/lib/*.sh are sourced-or-run libraries and are
  # not guaranteed to carry the execute bit (a direct call returns 126, which this function would
  # then have to disambiguate from a real read failure). Every other caller in the baseline —
  # including all three rendered workflows — spells it the same way. Shelling out rather than
  # sourcing also keeps role-dispatch's globals and shell options out of this file.
  #
  # stderr is deliberately NOT suppressed: on a malformed declaration the reader names the exact
  # problem ("not closed on one line", "no usable entries"), and that diagnosis is the whole value
  # of code 18. Swallowing it would leave the operator with a generic "malformed" and a file that
  # looks fine.
  want="$(bash "$_ADB_PR_ROLE_DISPATCH" bots --comparable)"; drc=$?
  case "$drc" in
    0)     ;;
    17|18) return "$drc" ;;
    *)     echo "pr-review: could not read '[reviewers] bots' (broken install) — refusing to arm" >&2
           return 20 ;;
  esac

  adb_require_gh jq || return 20

  # Read, then parse — two steps, deliberately. Folding the extraction into `gh --jq` would make
  # one status cover both the network read and the shape of what came back, so a PR object that
  # arrived fine but carries no head SHA would be indistinguishable from a failed call. Both are
  # fatal here, but only separate steps can SAY which, and the same discipline is what stops a
  # `gh … | jq` pipeline from reporting the parser's success for the reader's failure.
  pjson="$(gh api "repos/{owner}/{repo}/pulls/$n" 2>/dev/null)" \
    || { echo "pr-review: could not read PR #$n — refusing to arm" >&2; return 20; }
  # One jq pass for both fields this object is read for. The slug is case-folded inside it; the
  # shared cross-check folds it again rather than trusting that, because a primitive with two callers
  # must not carry a precondition one of them could quietly stop meeting.
  #
  # CAPTURE FIRST, then split, and CHECK THE STATUS. jq emits `.head.sha` before it evaluates the
  # second expression, so a jq that errors partway still writes a usable-looking first line: `head`
  # ends up set and `gotslug` empty, which would skip the different-repository refusal below
  # entirely. Putting the substitution straight into the heredoc would discard the very status that
  # distinguishes that from a clean read.
  #
  # `.head.repo.full_name` and `.head.ref` are read HERE rather than in a second call, because they
  # are the coordinates the staleness anchor is looked up by and they belong to the same snapshot as
  # the head SHA they describe. NOT case-folded, unlike the base slug: that one exists to be
  # COMPARED against the local remote (where case must not decide the answer), while these two are
  # interpolated into a URL and a ref name, both of which GitHub treats as case-sensitive.
  pfields="$(printf '%s' "$pjson" \
             | jq -r '(.head.sha // ""), (.base.repo.full_name // "" | ascii_downcase), (.head.repo.full_name // ""), (.head.ref // "")' 2>/dev/null)" \
    || { echo "pr-review: could not parse PR #$n — refusing to arm" >&2; return 20; }
  { IFS= read -r head; IFS= read -r gotslug; IFS= read -r headslug; IFS= read -r headref; } <<EOF
$pfields
EOF
  [ -n "$head" ] \
    || { echo "pr-review: could not resolve the head SHA of PR #$n — refusing to arm" >&2; return 20; }

  # Prove these reads addressed the repository the caller meant — the argument's own slug when it
  # carried one, and this checkout's git `origin` always, since a bare number names no repository and
  # `GH_REPO` silently redirects the placeholder expansion above. Without it,
  # `--pr https://github.com/other/repo/pull/7` would faithfully report on THIS repo's #7 — a
  # confidently wrong answer, which is the one thing a guard must never produce.
  #
  # The old check was guarded on `[ -n "$gotslug" ]`, so it VANISHED on exactly the malformed
  # responses it exists to catch. Unreadable metadata now fails closed at 20 and outranks a
  # mismatched argument; see adb_pr_slug_check.
  adb_pr_slug_check pr-review "$n" "$OPT_PR" "$gotslug"; src=$?
  case "$src" in
    0) ;;
    2) return 2 ;;
    *) return 20 ;;
  esac

  # `bots = []` — an explicit declaration that this repo has NO async reviewer. Nothing to wait
  # for, so arming is safe. The head SHA is still emitted: --match-head-commit is about the
  # push-during-arm race, which exists whether or not a reviewer does.
  if [ -z "$want" ]; then
    printf '%s\n' "$head"
    echo "pr-review: PR #$n — no async reviewers declared ([reviewers] bots = []); review gate not applicable" >&2
    return 0
  fi

  # The whole read-and-classify pipeline is ONE shared call (#167): three surface reads, evidence
  # selection, the conditional head-arrival anchor, and the per-reviewer classification. What stays
  # here is the mapping below — this guard's own exit codes, which are the thing that must NOT be
  # shared with the watcher.
  classes="$(adb_reviewer_classes_for_pr pr-review "$n" "$want" "$head" "$headslug" "$headref")" \
    || { echo "pr-review: PR #$n — refusing to arm on review state it could not read" >&2; return 20; }
  verdict="$(adb_fold_reviewer_classes "$classes")"

  # --- map the shared classification onto THIS module's exit codes ------------------------------
  # The fold is ALL-OR-NOTHING on `clean` (#185) — `adb_fold_reviewer_classes` ranks `none` above
  # `clean` for exactly that reason, so one fast bot can never release code before the reviewer the
  # owner actually cares about. The order below is the fold's, spelled out as remedies.
  case "$verdict" in
    # A rejection is reported BEFORE anything else: it names work that already exists to be done.
    # Nothing else catches it — this repo's branch protection carries
    # `required_approving_review_count: 0` (verified live), so GitHub will happily merge a PR whose
    # only review says "do not merge this", and `required_conversation_resolution` gates on threads
    # rather than on the verdict. It is not a deadlock either: addressing the feedback pushes a
    # commit, which moves the head SHA, and the next review is evaluated against that.
    rejected)
      echo "pr-review: PR #$n at $head — changes requested by: $(adb_reviewers_in_class "$classes" rejected)" >&2
      echo "pr-review: not arming auto-merge; a submitted review is not a satisfied one, and branch protection does not block on the verdict." >&2
      echo "pr-review: address the feedback and push (which moves the head, and is re-reviewed), or merge by hand if you disagree." >&2
      return 19 ;;
    # REVIEW COMPLETE, ATTENTION REQUIRED. The reviewer spoke and is not satisfied. This used to be
    # a silent 0: `COMMENTED` was treated as "satisfied" on the argument that a comment-only bot
    # never sends APPROVED. That premise was disproved — on a clean pass the connector posts NO
    # review object at all — so the deadlock it feared does not exist, and the branch it justified
    # let a reviewer's body-only findings authorize a merge.
    attention)
      echo "pr-review: PR #$n at $head — review complete, attention required from: $(adb_reviewers_in_class "$classes" attention)" >&2
      echo "pr-review: not arming auto-merge; the reviewer HAS spoken and is not satisfied — there may be NO inline threads, so read the review body or the issue comment." >&2
      return 21 ;;
    unknown)
      echo "pr-review: PR #$n at $head — cannot classify the signal from: $(adb_reviewers_in_class "$classes" unknown) — refusing to arm" >&2
      return 20 ;;
    clean)
      printf '%s\n' "$head"
      echo "pr-review: PR #$n — every declared reviewer signalled a clean pass for $head" >&2
      return 0 ;;
    *)
      echo "pr-review: PR #$n at $head — awaiting review from: $(adb_reviewers_in_class "$classes" none)" >&2
      echo "pr-review: not arming auto-merge; GitHub gates on checks and on threads that already exist, neither of which waits for a reviewer." >&2
      return 16 ;;
  esac
}

# --- arg parsing -----------------------------------------------------------------------------
# `--pr` is REQUIRED, never optional. An optional PR would make the guard silently permissive the
# moment a caller forgot it — the fail-open shape this whole module exists to remove.
parse_gate_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr)
        [ "$#" -ge 2 ] || { echo "pr-review: --pr needs a value" >&2; exit 2; }
        OPT_PR="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "pr-review: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  gate)      parse_gate_opts "$@"; cmd_gate ;;
  -h|--help) usage; exit 0 ;;
  *) echo "pr-review: unknown subcommand '$SUB' (expected 'gate')" >&2; usage >&2; exit 2 ;;
esac
