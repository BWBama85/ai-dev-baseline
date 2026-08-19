#!/usr/bin/env bash
# ai-dev-baseline — Stop-hook claim gate for volatile external status (issue #195).
#
# Blocks a turn that ends on an unsourced or stale PR/issue/CI status claim, and names the
# offending excerpt so the next turn can correct it.
#
# WHY A HOOK, WHEN THE PRACTICE AND `observe` ALREADY EXIST.
# `base/practices/verify-before-asserting.md` states the rule; `state-assert.sh observe` (#138)
# makes a STATED status correct by performing the read and rendering the sentence in one step.
# Neither can make an agent state one — nothing couples `observe`'s exit code to an action, so it
# renders optional narration. The two places this repo made state-verification stick are both
# structural, because a wrong answer stops the machine: `pr-review.sh gate` gates an actual
# `gh pr merge --auto`, and `cleanup-lib.sh branch-verdict` decides whether a branch is deleted.
# This gate is the third: its exit code gates the END OF THE TURN.
#
# It was earned. On 2026-07-29 a cleanup report volunteered `(OPEN at 14:55:26Z)` for a PR that had
# merged 14 minutes earlier — with the practice loaded in context and the correct reading already
# in hand. The reading was real; quoting a 14-minute-old one as narrative was the defect, and no
# additional paragraph addresses an agent that read correctly and wrote carelessly anyway.
#
# WHAT IT HONESTLY DOES NOT DO. A Stop hook fires AFTER the text has streamed: it forces a
# correction, it can never prevent the claim. And the grammar it delegates to is small by design
# (see `state-assert.sh lint`), so unusual phrasings pass. This narrows the failure; it does not
# close it.
#
# No-op (exit 0) when: the repo ships its own copy of this gate; jq is missing; the transcript is
# absent or unparseable; the turn's final message carries no text. Infrastructure absence is
# REPORTED once on stderr rather than swallowed (#35) — but it never blocks, because wedging a
# session over a missing dependency is worse than the claim it was trying to catch.

set -u

# bash 5.3 runtime floor (#256) — the ADVISORY form, and the distinction is this file's own
# contract rather than a preference: this gate deliberately refuses to wedge a session over
# infrastructure absence (#35), reporting once on stderr instead. Hard-failing here would make a
# sub-floor host look BROKEN rather than out of date, which is exactly the trade this file already
# declined.
#
# ADVISORY MEANS "STOP QUIETLY", NOT "CARRY ON REGARDLESS". The re-exec is attempted first and is
# silent when it works. When it cannot, this takes the same no-op-exit-0 path it already takes for
# a missing jq or an unreadable transcript — it does NOT scan a turn's final message under a
# sub-floor interpreter. Review caught the first cut continuing; once #258/#259 land 5.3-only
# syntax, continuing means failing deep inside a Stop hook, which is the failure the floor exists
# to prevent. The diagnostic has already gone to stderr, so the absence is reported, not swallowed.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" 2>/dev/null
  if command -v adb_require_bash_advisory >/dev/null 2>&1; then
    adb_require_bash_advisory "$@" || exit 0
  fi
fi

# Defer to a project-local copy by RUNNING it, not by stepping aside (#240) — same contract as the
# sibling gates, so a repo can override the policy without editing the install. `exit 0` here was
# enforcement silently OFF: nothing else invokes a project gate, so a repo that shipped its own
# copy got neither. `exec` inherits stdin and propagates the status; `-ef` prevents re-entry.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$repo_root" ]; then
  proj_gate="$repo_root/.claude/scripts/state-claim-gate.sh"
  if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
    [ -x "$proj_gate" ] && exec "$proj_gate" "$@"
    exec bash "$proj_gate" "$@"
  fi
fi

# The linter lives in the sibling lib/ (installed as ~/.claude/scripts/lib). Without it there is
# no grammar to apply — say so, do not block.
lint_lib="$(dirname "$0")/lib/state-assert.sh"
if [ ! -f "$lint_lib" ]; then
  printf 'state-claim-gate: linter missing (%s) — incomplete install; claims are NOT being checked. Run `baseline update`.\n' "$lint_lib" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'state-claim-gate: jq not found — claims are NOT being checked this turn.\n' >&2
  exit 0
fi

# Claude Code passes the hook payload as JSON on stdin. Read stdin ONCE into a variable: it is a
# pipe, so a second read would get nothing.
payload="$(cat 2>/dev/null || true)"

# THE PAYLOAD IS THE SOURCE OF TRUTH FOR THE FINAL MESSAGE; the transcript is the FALLBACK (#383,
# D83). `last_assistant_message` is computed from the live message list, so it is always THIS
# turn's final text. The transcript is a file that the turn's own entries may not have reached
# yet, and a read that loses the race resolves the PREVIOUS message instead — blocking a turn over
# a sentence the operator can no longer see. The measurement is in D83.
#
# THE ORDER IS THE FIX. Do not reverse it, and do not drop the fallback: an absent field is an
# older CLI, where the transcript is the only source there is.
text="$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null || true)"

if [ -z "$text" ]; then
  # `transcript_path` names the JSONL session log. Its FINAL assistant message's text blocks are
  # the user-visible summary, which is where narration lives. Deliberately not every assistant
  # block since the last user turn: intermediate blocks are mostly tool orchestration, and linting
  # them would trade precision for noise in a gate whose whole value depends on being believed
  # when it fires.
  #
  # `-s` slurps the JSONL; a malformed trailing line (a session still being written) makes jq fail,
  # which is an unparseable transcript and therefore a no-op, not a block.
  #
  # SIDECHAIN ENTRIES ARE EXCLUDED: a Task subagent's messages land in this same log, and one of
  # them resolving as "the turn's final message" lints text the operator never wrote.
  transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || true)"
  [ -n "$transcript" ] || exit 0
  [ -f "$transcript" ] || exit 0
  text="$(jq -s -r '
    [ .[] | select(type == "object") | select(.type == "assistant")
          | select(.isSidechain != true) ] as $a
    | if ($a | length) == 0 then ""
      else ($a | last | .message.content // [])
           | map(select(type == "object") | select(.type == "text") | .text // "")
           | join("\n")
      end' "$transcript" 2>/dev/null || true)"
fi
[ -n "$text" ] || exit 0

# Capture stderr separately: the linter's exit-1 is AMBIGUOUS, and discarding the diagnostic is
# what made that ambiguity silent. `state-assert.sh` exits 1 both for "violations found" and for
# "broken install — common.sh missing", the latter before it can print a single row. Treating an
# empty exit-1 as a clean turn disables this gate exactly when the install is damaged — the
# opposite of the contract in this file's header.
lint_err="$(mktemp "${TMPDIR:-/tmp}/state-claim.XXXXXX")" || exit 0
violations="$(printf '%s\n' "$text" | bash "$lint_lib" lint 2>"$lint_err")"
status=$?
err="$(cat "$lint_err" 2>/dev/null)"; rm -f "$lint_err"

if [ "$status" -eq 1 ] && [ -z "$violations" ]; then
  # Exit 1 with nothing to report is not a lint result. Say so (#35) and let the turn end.
  printf 'state-claim-gate: the linter failed without producing findings — claims are NOT being checked this turn.\n' >&2
  [ -n "$err" ] && printf '%s\n' "$err" >&2
  exit 0
fi
if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
  printf 'state-claim-gate: the linter exited %s — claims are NOT being checked this turn.\n' "$status" >&2
  [ -n "$err" ] && printf '%s\n' "$err" >&2
  exit 0
fi
[ "$status" -eq 1 ] || exit 0        # 0 = clean
[ -n "$violations" ] || exit 0

# Each claim KIND has its own authoritative home, and only one of them is `observe`. Offering a
# PR/issue command for a CI claim is advice that cannot be followed — `observe` answers
# open/closed/merged and nothing else — which would leave "delete it" as the only real option even
# when the status was explicitly asked for. The homes are the practice's own one-per-entity-kind
# table; naming the right one per finding is the difference between a gate that teaches and a gate
# that just blocks.
claim_home() {
  case "$1" in
    green|red|passing|failing)
      printf 'CI status -> bash "$HOME/.claude/scripts/lib/roadmap-lib.sh" branch-health (Checks API + commit-status API, fail-closed)' ;;
    unmerged)
      printf 'branch merged? -> bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" branch-verdict (models squash/rebase and exact-head)' ;;
    *)
      printf 'PR/issue state -> bash "$HOME/.claude/scripts/lib/state-assert.sh" observe pr|issue <n>' ;;
  esac
}

{
  printf 'STOP: this turn states volatile external status that was not read in this turn.\n\n'
  printf '%s\n' "$violations" | while IFS="$(printf '\t')" read -r ln word excerpt; do
    printf '  [%s] "%s" — line %s\n' "$word" "$excerpt" "$ln"
    printf '      %s\n' "$(claim_home "$word")"
  done
  printf '\n'
  printf 'A PR/issue/CI/branch status is only assertable from a read taken NOW. Do ONE of:\n'
  printf '  1. Re-read with the command named above for that claim and quote its output\n'
  printf '     verbatim. Empty output means say NOTHING about that entity.\n'
  printf '     Note "merged" is ambiguous: a PR merging is `observe`; a BRANCH being merged\n'
  printf '     is `branch-verdict`. Pick the one you actually mean.\n'
  printf '  2. Delete the claim. Most status narration is unrequested — dropping it is\n'
  printf '     always correct and costs the reader nothing.\n\n'
  printf 'Do not restate the status from memory or from an earlier read in this session:\n'
  printf 'that is the exact failure this gate exists to catch (base/practices/verify-before-asserting.md).\n'
} >&2

exit 2
