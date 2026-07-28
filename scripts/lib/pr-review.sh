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
# Usage:
#   pr-review.sh gate --pr <number|url>   # the pre-arm guard; prints the witnessed head SHA on 0
#   pr-review.sh -h | --help
#
# `gate` exit codes are a stable machine contract for the workflow step:
#   0  safe    — every declared reviewer has reviewed the CURRENT head SHA, or the repo declared
#                `[reviewers] bots = []` (no async reviewer). STDOUT is the witnessed head SHA,
#                which the caller MUST pass to `gh pr merge --match-head-commit`.
#   16 wait    — a declared reviewer has NOT reviewed this head SHA yet. Do not arm; the operator
#                merges after the review lands (or /resolve-pr-threads then a re-run).
#   17 unknown — the repo declares no `[reviewers] bots` at all, so whether a reviewer is coming
#                cannot be known. FAIL CLOSED. Declare the reviewers, or `bots = []` if there are
#                none. Deliberately NOT 20: the operator action is "declare it", not "retry".
#   18 config  — `[reviewers] bots` is present but malformed. Like 17 the remedy is "fix
#                agents.toml", not "retry", so it is not folded into 20.
#   20 unknown — live state unreadable (API failure, no head SHA, an unrecognized review state).
#                FAIL CLOSED, never assume reviewed.
#   2  usage   — bad or missing arguments.
#
# THE ONE DIRECTION THIS MUST NEVER BE WRONG IN is returning 0 when a reviewer is still coming.
# Every uncertainty above therefore resolves to a non-zero code, and there is no path where a
# failed read degrades into "no reviewers pending".
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

# --- helpers ---------------------------------------------------------------------------------

# parse_pr_arg <value> — the PR NUMBER from a bare integer or a GitHub PR URL.
#
# Step 10 has a `prUrl` in its marker, not a number, so accepting both removes a caller-side sed.
# Only the NUMBER is taken from a URL: every read below addresses `repos/{owner}/{repo}/...`,
# which gh expands from the LOCAL remote. Trusting a URL's own slug instead would let the guard
# be pointed at another repository entirely; parse_pr_slug below verifies the two agree rather
# than silently answering about a different PR of the same number.
parse_pr_arg() {
  local n="$1"
  case "$n" in *pull/*) n="${n##*pull/}"; n="${n%%[!0-9]*}" ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$n"
}

# parse_pr_slug <value> — the `owner/repo` of a PR URL, or nothing for a bare number.
# Used only to CROSS-CHECK the URL against the repo the reads actually address. A bare number
# carries no slug and needs no check.
parse_pr_slug() {
  local v="$1" rest
  case "$v" in
    *://*/*/*/pull/*) rest="${v#*://}"; rest="${rest#*/}" ;;   # host/ -> owner/repo/pull/N
    *) return 0 ;;
  esac
  printf '%s' "${rest%%/pull/*}"
}

# --- the guard -------------------------------------------------------------------------------

cmd_gate() {
  local n declared drc want head pjson pfields reviews rjson kinds wantslug gotslug pending=""

  [ -n "$OPT_PR" ] || { echo "pr-review: gate requires --pr <number|url>" >&2; return 2; }
  n="$(parse_pr_arg "$OPT_PR")" \
    || { echo "pr-review: '--pr $OPT_PR' is not a PR number or a GitHub PR URL" >&2; return 2; }

  # Read the DECLARED reviewers first, before any network call: the `bots = []` and undeclared
  # answers need no API access at all, and an unauthenticated repo should not be told "unreadable"
  # when the real answer is "you have not declared reviewers".
  # `bash <path>`, never `<path>` directly: scripts/lib/*.sh are sourced-or-run libraries and are
  # not guaranteed to carry the execute bit (a direct call returns 126, which this function would
  # then have to disambiguate from a real read failure). Every other caller in the baseline —
  # including all three rendered workflows — spells it the same way.
  # stderr is deliberately NOT suppressed: on a malformed declaration the reader names the exact
  # problem ("not closed on one line", "no usable entries"), and that diagnosis is the whole value
  # of code 18. Swallowing it would leave the operator with a generic "malformed" and a file that
  # looks fine.
  declared="$(bash "$_ADB_PR_ROLE_DISPATCH" bots --declared)"; drc=$?
  case "$drc" in
    0) ;;
    3) echo "pr-review: this repo declares no '[reviewers] bots' — cannot know whether a reviewer is coming." >&2
       echo "pr-review: declare the async reviewer logins in agents.toml, or 'bots = []' if there are none." >&2
       return 17 ;;
    2) echo "pr-review: '[reviewers] bots' is unusable (see above) — fix agents.toml; use [] for none" >&2
       return 18 ;;
    *) echo "pr-review: could not read '[reviewers] bots' (broken install) — refusing to arm" >&2
       return 20 ;;
  esac

  # Normalize and de-duplicate the declaration in ONE pass, so the comparison form is built the
  # same way no matter how many reviewers are declared.
  #
  # The normalization is load-bearing, not cosmetic: the SAME bot has two spellings depending on
  # which API answered —
  #   GraphQL  author.login -> chatgpt-codex-connector        (what /resolve-pr-threads matches)
  #   REST     user.login   -> chatgpt-codex-connector[bot]   (what THIS module reads)
  # both verified live against PR #133. The built-in allowlist carries the bare form for the Codex
  # connector, so an anchored exact match against a REST login would silently never fire — and "no
  # declared reviewer matched" looks exactly like "the reviewer has not reviewed yet", wedging the
  # guard at 16 forever even after the review landed. Normalizing BOTH sides (here, and in the jq
  # select below) makes either spelling work in agents.toml.
  #
  # Lowercase BEFORE stripping, so `[BOT]` is stripped too; drop blanks AFTER, so an entry that is
  # only `[bot]` becomes empty and is dropped rather than becoming a reviewer that can never match.
  want="$(printf '%s\n' "$declared" \
          | tr '[:upper:]' '[:lower:]' \
          | sed -e 's/\[bot\]$//' -e '/^[[:space:]]*$/d' \
          | LC_ALL=C sort -u)"

  # A declaration that survived the manifest reader but normalizes to NOTHING (`bots = ["[bot]"]`)
  # is malformed, not "no reviewers". The operator declared something; treating it as the `[]`
  # disable would arm auto-merge off the back of a typo — the fail-open direction, from the one
  # input that looks most like a real declaration.
  if [ -n "$declared" ] && [ -z "$want" ]; then
    echo "pr-review: '[reviewers] bots' has no usable reviewer logins — fix agents.toml (use [] for none)" >&2
    return 18
  fi

  adb_require_gh jq || return 20

  # Read, then parse — two steps, deliberately. Folding the extraction into `gh --jq` would make
  # one status cover both the network read and the shape of what came back, so a PR object that
  # arrived fine but carries no head SHA would be indistinguishable from a failed call. Both are
  # fatal here, but only separate steps can SAY which, and the same discipline is what stops a
  # `gh … | jq` pipeline from reporting the parser's success for the reader's failure.
  pjson="$(gh api "repos/{owner}/{repo}/pulls/$n" 2>/dev/null)" \
    || { echo "pr-review: could not read PR #$n — refusing to arm" >&2; return 20; }
  # One jq pass for both fields this object is read for. The slug is case-folded inside it, so the
  # comparison below needs no second `tr` over the same value.
  #
  # CAPTURE FIRST, then split, and CHECK THE STATUS. jq emits `.head.sha` before it evaluates the
  # second expression, so a jq that errors partway still writes a usable-looking first line: `head`
  # ends up set and `gotslug` empty, which would skip the different-repository refusal below
  # entirely. Putting the substitution straight into the heredoc would discard the very status that
  # distinguishes that from a clean read.
  pfields="$(printf '%s' "$pjson" \
             | jq -r '(.head.sha // ""), (.base.repo.full_name // "" | ascii_downcase)' 2>/dev/null)" \
    || { echo "pr-review: could not parse PR #$n — refusing to arm" >&2; return 20; }
  { IFS= read -r head; IFS= read -r gotslug; } <<EOF
$pfields
EOF
  [ -n "$head" ] \
    || { echo "pr-review: could not resolve the head SHA of PR #$n — refusing to arm" >&2; return 20; }

  # If the caller passed a URL, prove it names the repo these reads actually addressed. Without
  # this, `--pr https://github.com/other/repo/pull/7` would faithfully report on THIS repo's #7 —
  # a confidently wrong answer, which is the one thing a guard must never produce.
  wantslug="$(parse_pr_slug "$OPT_PR" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$wantslug" ] && [ -n "$gotslug" ] && [ "$wantslug" != "$gotslug" ]; then
    echo "pr-review: --pr names '$wantslug' but this repo is '$gotslug' — refusing to answer about a different repository" >&2
    return 2
  fi

  # `bots = []` — an explicit declaration that this repo has NO async reviewer. Nothing to wait
  # for, so arming is safe. The head SHA is still emitted: --match-head-commit is about the
  # push-during-arm race, which exists whether or not a reviewer does.
  if [ -z "$want" ]; then
    printf '%s\n' "$head"
    echo "pr-review: PR #$n — no async reviewers declared ([reviewers] bots = []); review gate not applicable" >&2
    return 0
  fi

  # --paginate so a PR with many reviews cannot silently drop the page carrying the one that
  # matters. Read and PARSE separately: a pipeline reports only its last command's status, so
  # `gh api … | jq` would return 0 on a failed read, the parser would see empty stdin — a
  # legitimately unreviewed PR — and the guard would report 16 for a repo it could not read. That
  # direction is merely annoying; the same mistake in the opposite branch would be a false 0.
  rjson="$(gh api --paginate "repos/{owner}/{repo}/pulls/$n/reviews?per_page=100" 2>/dev/null)" \
    || { echo "pr-review: could not read reviews for PR #$n — refusing to arm" >&2; return 20; }

  # --paginate concatenates one JSON document per page; -s flattens them into one array.
  reviews="$(printf '%s' "$rjson" | jq -s -c '[.[][]]' 2>/dev/null)" \
    || { echo "pr-review: could not parse the reviews of PR #$n — refusing to arm" >&2; return 20; }
  [ -n "$reviews" ] \
    || { echo "pr-review: could not parse the reviews of PR #$n — refusing to arm" >&2; return 20; }

  # For each declared reviewer, ask ONLY about reviews attached to the current head SHA. A review
  # of an earlier commit is not a review of this one — observed live on PR #145, where the bot
  # reviewed b302fa0e and three further commits landed afterwards.
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    kinds="$(printf '%s' "$reviews" | jq -r --arg sha "$head" --arg who "$login" '
        [ .[]
          | select((.commit_id // "") == $sha)
          | select(((.user.login // "") | ascii_downcase | sub("\\[bot\\]$"; "")) == $who)
          | (.state // "") ] | .[]' 2>/dev/null)" \
      || { echo "pr-review: could not evaluate reviews for '$login' — refusing to arm" >&2; return 20; }

    # The state taxonomy, in its one home. A review is a submitted opinion regardless of verdict —
    # COMMENTED is what the Codex connector posts, and waiting for an APPROVED that a comment-only
    # bot never sends would deadlock the guard. PENDING is an unsubmitted draft nobody can see and
    # DISMISSED was explicitly revoked, so neither counts. Anything else is a state this module
    # does not recognize: it must surface (20), never be quietly read as "not reviewed", because a
    # future GitHub state that actually means "reviewed" would otherwise wedge the guard at 16.
    local satisfied=0 sawunknown=0 st
    while IFS= read -r st; do
      case "$st" in
        '') continue ;;
        APPROVED|CHANGES_REQUESTED|COMMENTED) satisfied=1 ;;
        PENDING|DISMISSED) ;;
        *) sawunknown=1; echo "pr-review: PR #$n — unrecognized review state '$st' from '$login'" >&2 ;;
      esac
    done <<EOF
$kinds
EOF

    if [ "$satisfied" -eq 0 ] && [ "$sawunknown" -eq 1 ]; then
      echo "pr-review: cannot classify '$login''s review of $head — refusing to arm" >&2
      return 20
    fi
    [ "$satisfied" -eq 1 ] || pending="${pending:+$pending }$login"
  done <<EOF
$want
EOF

  # ALL declared reviewers must have reviewed, not any one of them. The set is DECLARED rather
  # than defaulted, so it lists exactly the bots this repo actually has — under "any", a fast
  # second bot would release code before the reviewer the owner actually cares about.
  if [ -n "$pending" ]; then
    echo "pr-review: PR #$n at $head — awaiting review from: $pending" >&2
    echo "pr-review: not arming auto-merge; GitHub gates on checks and on threads that already exist, neither of which waits for a reviewer." >&2
    return 16
  fi

  printf '%s\n' "$head"
  echo "pr-review: PR #$n — every declared reviewer has reviewed $head" >&2
  return 0
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
