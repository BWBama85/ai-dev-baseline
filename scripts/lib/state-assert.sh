#!/usr/bin/env bash
# state-assert.sh — perform the read AND render the sentence, in one step (issue #138).
#
# Usage:
#   state-assert.sh observe pr    <number>
#   state-assert.sh observe issue <number>
#
# Exit codes:
#   0  observed     — exactly one rendered line on stdout
#   2  usage error  — nothing on stdout
#   3  unverifiable — nothing on stdout; the reason goes to stderr
#
# WHY THIS EXISTS, and why it is not just a getter.
# `base/practices/verify-before-asserting.md` forbids stating volatile external status from
# memory. It had no mechanism behind it, and was violated twice in one session with the practice
# loaded in context: a merged PR narrated as open from a 25-minute-old read, and a gate claimed to
# hold that structurally could not.
#
# A callable `pr-state` would NOT have fixed that — an agent can ignore a getter exactly as easily
# as a paragraph, and a value fetched into a variable can still go stale before the sentence that
# quotes it. So this does BOTH halves in ONE call: the authoritative read, and the finished
# sentence. Callers pass the line through unchanged. No window for the value to age; no paraphrase
# step in which an observation ("was observed OPEN") becomes a prediction ("is still open").
#
# FAIL CLOSED means stdout is EMPTY. Every unverifiable path renders NO sentence. Callers must
# treat empty stdout as "say nothing about this entity", never as licence to fall back on memory.
#
# OBSERVATIONS ARE PAST-TENSE BY CONSTRUCTION. A read supports a claim about the moment it
# happened and nothing more. "is still open" and "will hold" are claims about the future that no
# read can support — #138's second case was exactly such a prediction.
#
# SCOPE — one home per entity kind, deliberately NOT a universal state oracle. PR/issue state is
# here; "is this branch merged?" belongs to cleanup-lib.sh (it already models squash/rebase merges
# and exact-head matching) and "is the branch green?" to roadmap-lib.sh. Re-deriving either here
# would fork a second model of the same question.
#
# THIS IS A HELPER A CALLER MUST CHOOSE TO CALL. Nothing makes it mandatory: unlike
# `pr-review.sh gate`, whose exit code gates an actual merge, this renders optional narration. It
# makes a stated status correct-by-construction; it cannot make an agent state one. That gap is
# the enforcement-hooks layer's, not this file's, and the practice says so rather than implying
# otherwise.
#
# Regression-tested offline (no network) by scripts/check-state-assert.sh.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_sa_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_sa_common="$_adb_sa_libdir/common.sh"
if [ ! -f "$_adb_sa_common" ]; then
  printf 'state-assert: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_sa_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_sa_common"

usage() { adb_usage "$0"; }

# A bare integer, and nothing else. Guards against a flag, a path or an empty string reaching gh.
_sa_is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# gh's own stderr is deliberately discarded at the call sites rather than captured into a temp
# file the way implement-issue-gate.sh does. The trade is conscious: this is a NARRATION helper
# whose failure mode is silence (always safe), not a gate whose failure mode is a wrong decision,
# and the operator's next move — running the same gh command by hand — surfaces the real cause.
_sa_unverifiable() {
  printf 'state-assert: unverifiable (%s) — no status rendered\n' "$1" >&2
  exit 3
}

# _sa_read <kind> <number> — the half that is identical for both entity kinds, written ONCE.
# Sets SA_STATE, SA_EXTRA (mergedAt for a PR, stateReason for an issue) and SA_AT. Exits 3 on any
# unverifiable condition, so a caller that returns has usable values by construction.
#
# NO SEPARATE REPO-IDENTITY CALL. An earlier draft spent a whole `gh repo view` round trip — 55-70%
# of this command's wall time — proving the entity was local. It is redundant: the argument is
# validated as a bare INTEGER, and `gh pr view <n>` resolves that number against the repo of the
# LOCAL remote, exactly the property pr-review.sh relies on for `repos/{owner}/{repo}/...`. A
# number cannot address another repository.
#
# The URL still earns its place, for a different question the number cannot answer: PRs and issues
# share ONE number space, and `gh issue view <PR number>` really does answer with the pull request.
# Only the `/pull/` vs `/issues/` path segment discriminates the two.
_sa_read() {
  local kind="$1" n="$2" subcmd extra_field want_seg json url
  case "$kind" in
    pr)    subcmd="pr";    extra_field="mergedAt";    want_seg="/pull/" ;;
    issue) subcmd="issue"; extra_field="stateReason"; want_seg="/issues/" ;;
    *) usage >&2; exit 2 ;;
  esac

  adb_require_gh jq || _sa_unverifiable "gh/jq unavailable or gh not authenticated"

  # Stamped BEFORE the read, so the sentence dates the observation no later than it actually was —
  # erring older is the safe direction for a freshness claim.
  SA_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Read and parse as SEPARATE steps. A pipeline reports only its LAST command's status, so
  # `gh ... | jq` returns 0 on a failed read and the parser sees empty stdin — indistinguishable
  # from a legitimately empty answer, and a sentence would be rendered from nothing.
  json="$(gh "$subcmd" view "$n" --json "state,$extra_field,url" 2>/dev/null)" \
    || _sa_unverifiable "gh could not read $kind #$n"
  [ -n "$json" ] || _sa_unverifiable "empty response for $kind #$n"

  # One jq pass, one field per line. An absent field stays an EMPTY LINE rather than collapsing,
  # so a missing mergedAt cannot shift url into state's position. Capture first, then split: the
  # substitution's own failure must be visible rather than read back as empty fields.
  local fields
  fields="$(printf '%s' "$json" | jq -r --arg x "$extra_field" '.state // "", (.[$x] // ""), .url // ""' 2>/dev/null)" \
    || _sa_unverifiable "malformed response for $kind #$n"
  { IFS= read -r SA_STATE; IFS= read -r SA_EXTRA; IFS= read -r url; } <<EOF
$fields
EOF
  [ -n "$SA_STATE" ] || _sa_unverifiable "malformed response for $kind #$n"

  case "$url" in
    *"$want_seg"*) : ;;
    *) _sa_unverifiable "#$n is not of kind '$kind' — its URL is not a ${want_seg} reference" ;;
  esac
}

_sa_observe_pr() {
  _sa_read pr "$1"
  # `mergedAt` is the authority for MERGED. GitHub reports a merged PR's state as CLOSED, so
  # keying off state alone renders "closed without merging" for a PR that in fact merged — the
  # same wrong-direction error #44 fixed on the Stop-hook side.
  if [ -n "$SA_EXTRA" ]; then
    printf 'PR #%s was observed MERGED at %s\n' "$1" "$SA_AT"; return 0
  fi
  case "$SA_STATE" in
    OPEN)   printf 'PR #%s was observed OPEN at %s\n' "$1" "$SA_AT" ;;
    CLOSED) printf 'PR #%s was observed CLOSED without merging at %s\n' "$1" "$SA_AT" ;;
    *)      _sa_unverifiable "unrecognized state '$SA_STATE' for PR #$1" ;;
  esac
}

_sa_observe_issue() {
  _sa_read issue "$1"
  # NOT_PLANNED is surfaced rather than flattened into CLOSED: "closed as not planned" means the
  # work was ABANDONED, not delivered, and collapsing the two reads a cancelled requirement as a
  # satisfied one (the distinction /roadmap's release predicate also turns on).
  case "$SA_STATE" in
    OPEN)   printf 'issue #%s was observed OPEN at %s\n' "$1" "$SA_AT" ;;
    CLOSED)
      if [ "$SA_EXTRA" = "NOT_PLANNED" ]; then
        printf 'issue #%s was observed CLOSED as NOT_PLANNED at %s\n' "$1" "$SA_AT"
      else
        printf 'issue #%s was observed CLOSED as completed at %s\n' "$1" "$SA_AT"
      fi ;;
    *) _sa_unverifiable "unrecognized state '$SA_STATE' for issue #$1" ;;
  esac
}

SA_STATE=""; SA_EXTRA=""; SA_AT=""

case "${1:-}" in
  observe)
    # EXACTLY three arguments. Ignoring a tail would let `observe pr 1 --json state` render a
    # sentence while silently dropping the flag — a caller that thinks it asked a narrower
    # question gets a confident answer to a different one.
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    _sa_is_number "$3" || { usage >&2; exit 2; }
    case "$2" in
      pr)    _sa_observe_pr "$3" ;;
      issue) _sa_observe_issue "$3" ;;
      *)     usage >&2; exit 2 ;;
    esac ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
