#!/usr/bin/env bash
# ai-dev-baseline — atomic observe-and-render for mutable external state (issue #138).
#
# WHY THIS EXISTS, and why it is not just a getter.
# `base/practices/verify-before-asserting.md` forbids stating volatile external status from memory.
# It had no mechanism behind it: an agent was trusted to remember to re-read, and twice in one
# session it did not — a merged PR was narrated as open from a 25-minute-old read, and a gate was
# claimed to hold that structurally could not.
#
# A callable `pr-state` would NOT have fixed that. An agent can ignore a getter exactly as easily
# as it can ignore a paragraph of prose, and a value fetched into a shell variable can go stale
# between the fetch and the sentence that quotes it. So this command does BOTH halves in ONE call:
# it performs the authoritative read AND renders the finished sentence. The caller passes that line
# through UNCHANGED. There is no window in which the value can age, and no paraphrase step in which
# an observation ("was observed OPEN") can quietly become a prediction ("is still open").
#
# FAIL CLOSED — and note precisely what that means here. An unverifiable read prints NOTHING on
# stdout and exits non-zero. Emitting no status line is always safe; emitting a guessed one is the
# entire bug this file exists to remove. Callers must therefore treat empty stdout as "say nothing
# about this entity", never as a licence to fall back on a remembered value.
#
# OBSERVATIONS ARE PAST-TENSE BY CONSTRUCTION. Every rendered line is of the form
# "<entity> was observed <STATE> at <ISO-8601 UTC>". This is deliberate and is not a style choice:
# a read can only ever support a claim about the moment it happened. "is still open" and "will
# wait" are claims about the future that no read can support — #138's second observed case was
# exactly such a prediction, and no amount of freshness would have made it true.
#
# SCOPE — one home per entity kind, deliberately NOT a universal state oracle:
#   PR / issue state ....... HERE.
#   branch merged? ......... scripts/lib/cleanup-lib.sh `branch-verdict` (it already models
#                            squash/rebase merges, exact-head matching and base containment).
#   release / branch health  scripts/lib/roadmap-lib.sh `branch-health` (Checks API + the legacy
#                            commit-status API, with its own no-CI and fail-closed arms).
# Re-implementing either of those here would fork a second model of the same question, which is the
# drift this repo's shared-primitive rule exists to prevent. Ask the owner of the question.
#
# Usage:
#   state-assert.sh observe pr    <number>
#   state-assert.sh observe issue <number>
#
# Exit codes:
#   0  observed        — exactly one rendered line on stdout
#   2  usage error     — nothing on stdout
#   3  unverifiable    — nothing on stdout; the reason goes to stderr
#
# Regression-tested offline (no network, no gh) by scripts/check-state-assert.sh.

set -u

_sa_usage() {
  cat >&2 <<'EOF'
usage: state-assert.sh observe <pr|issue> <number>

Performs the live read AND renders the sentence, so the two cannot drift apart.
Pass the printed line through unchanged. Empty stdout means SAY NOTHING about the
entity — never substitute a remembered value (that is the bug this prevents).

  observe pr    <number>   -> PR #<n> was observed <OPEN|MERGED|CLOSED> at <ISO-8601 UTC>
  observe issue <number>   -> issue #<n> was observed <OPEN|CLOSED> at <ISO-8601 UTC>

Branch merged?  -> cleanup-lib.sh branch-verdict
Release health? -> roadmap-lib.sh branch-health
EOF
}

# A bare integer, and nothing else. Guards against an argument like `1 --json` or `../../x`
# reaching `gh`, and against the empty string silently addressing the whole collection.
_sa_is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# One timestamp per invocation, captured at the moment of the read rather than at render time, so
# the sentence dates the observation and not the printing.
_sa_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_sa_unverifiable() {
  printf 'state-assert: unverifiable (%s) — no status rendered\n' "$1" >&2
  exit 3
}

_sa_require_tools() {
  command -v gh >/dev/null 2>&1 || _sa_unverifiable "gh not on PATH"
  command -v jq >/dev/null 2>&1 || _sa_unverifiable "jq not on PATH"
}

# Resolve THIS repo once. Used to prove an entity belongs here before its state is rendered —
# the same identity check implement-issue-gate.sh applies to a stored prUrl (#44). Without it a
# same-numbered PR in another repo could render a confident, wrong sentence.
_sa_repo_url() {
  local url
  url="$(gh repo view --json url --jq '.url' 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

_sa_observe_pr() {
  local n="$1" repo_url pr_json state merged pr_url observed_at
  _sa_require_tools
  repo_url="$(_sa_repo_url)" || _sa_unverifiable "cannot resolve this repository"

  observed_at="$(_sa_now)"
  # Read and parse as SEPARATE steps. A pipeline reports only its LAST command's status, so
  # `gh ... | jq` would return 0 on a failed read and the parser would see empty stdin — which is
  # indistinguishable from a legitimately empty answer, and would render a sentence from nothing.
  pr_json="$(gh pr view "$n" --json state,mergedAt,url 2>/dev/null)" \
    || _sa_unverifiable "gh could not read PR #$n"
  [ -n "$pr_json" ] || _sa_unverifiable "empty response for PR #$n"

  # One jq pass, one field per line. An absent field stays an EMPTY LINE rather than collapsing,
  # so a missing mergedAt cannot shift url into state's position.
  { IFS= read -r state; IFS= read -r merged; IFS= read -r pr_url; } <<EOF
$(printf '%s' "$pr_json" | jq -r '.state // "", .mergedAt // "", .url // ""' 2>/dev/null)
EOF
  [ -n "$state" ] || _sa_unverifiable "malformed response for PR #$n"

  # Belongs to THIS repo? A full URL targets its own host/repo, so a stale or cross-repo number
  # must not be rendered as if it were local.
  case "$pr_url" in
    "$repo_url"/pull/*) : ;;
    *) _sa_unverifiable "PR #$n does not belong to $repo_url" ;;
  esac

  # `mergedAt` is the authority for MERGED. GitHub reports a merged PR's state as CLOSED, so
  # keying off state alone would render "was observed CLOSED" for a PR that in fact merged — the
  # exact wrong-direction error #44 fixed on the gate side.
  if [ -n "$merged" ]; then
    printf 'PR #%s was observed MERGED at %s\n' "$n" "$observed_at"
    return 0
  fi
  case "$state" in
    OPEN)   printf 'PR #%s was observed OPEN at %s\n' "$n" "$observed_at" ;;
    CLOSED) printf 'PR #%s was observed CLOSED without merging at %s\n' "$n" "$observed_at" ;;
    *)      _sa_unverifiable "unrecognized state '$state' for PR #$n" ;;
  esac
}

_sa_observe_issue() {
  local n="$1" repo_url issue_json state reason issue_url observed_at
  _sa_require_tools
  repo_url="$(_sa_repo_url)" || _sa_unverifiable "cannot resolve this repository"

  observed_at="$(_sa_now)"
  issue_json="$(gh issue view "$n" --json state,stateReason,url 2>/dev/null)" \
    || _sa_unverifiable "gh could not read issue #$n"
  [ -n "$issue_json" ] || _sa_unverifiable "empty response for issue #$n"

  { IFS= read -r state; IFS= read -r reason; IFS= read -r issue_url; } <<EOF
$(printf '%s' "$issue_json" | jq -r '.state // "", .stateReason // "", .url // ""' 2>/dev/null)
EOF
  [ -n "$state" ] || _sa_unverifiable "malformed response for issue #$n"

  case "$issue_url" in
    "$repo_url"/issues/*) : ;;
    *) _sa_unverifiable "issue #$n does not belong to $repo_url" ;;
  esac

  # NOT_PLANNED is surfaced rather than flattened into CLOSED: "closed as not planned" means the
  # work was ABANDONED, not delivered, and collapsing the two is how a cancelled requirement gets
  # read as a satisfied one (the same distinction /roadmap's release predicate turns on).
  case "$state" in
    OPEN)   printf 'issue #%s was observed OPEN at %s\n' "$n" "$observed_at" ;;
    CLOSED)
      if [ "$reason" = "NOT_PLANNED" ]; then
        printf 'issue #%s was observed CLOSED as NOT_PLANNED at %s\n' "$n" "$observed_at"
      else
        printf 'issue #%s was observed CLOSED as completed at %s\n' "$n" "$observed_at"
      fi ;;
    *) _sa_unverifiable "unrecognized state '$state' for issue #$n" ;;
  esac
}

case "${1:-}" in
  observe)
    # EXACTLY three arguments. Ignoring a tail would let `observe pr 1 --json state` render a
    # sentence while silently dropping the flag — a caller that thinks it asked a narrower
    # question gets a confident answer to a different one. Caught by check-state-assert.sh.
    [ "$#" -eq 3 ] || { _sa_usage; exit 2; }
    _sa_is_number "${3:-}" || { _sa_usage; exit 2; }
    case "${2:-}" in
      pr)    _sa_observe_pr "$3" ;;
      issue) _sa_observe_issue "$3" ;;
      *)     _sa_usage; exit 2 ;;
    esac ;;
  -h|--help|help) _sa_usage; exit 0 ;;
  *) _sa_usage; exit 2 ;;
esac
