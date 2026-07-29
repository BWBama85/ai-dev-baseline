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

# Defer to a project-local copy if one exists and isn't this file (same contract as the sibling
# gates, so a repo can override the policy without editing the install).
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$repo_root" ]; then
  proj_gate="$repo_root/.claude/scripts/state-claim-gate.sh"
  if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
    exit 0
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

# Claude Code passes the hook payload as JSON on stdin; `transcript_path` names the JSONL session
# log. Read stdin ONCE into a variable: it is a pipe, so a second read would get nothing.
payload="$(cat 2>/dev/null || true)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || true)"
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

# The FINAL assistant message's text blocks — the user-visible summary, which is where narration
# lives. Deliberately not every assistant block since the last user turn: intermediate blocks are
# mostly tool orchestration, and linting them would trade precision for noise in a gate whose
# whole value depends on being believed when it fires.
#
# `-s` slurps the JSONL; a malformed trailing line (a session still being written) makes jq fail,
# which is an unparseable transcript and therefore a no-op, not a block.
text="$(jq -s -r '
  [ .[] | select(type == "object") | select(.type == "assistant") ] as $a
  | if ($a | length) == 0 then ""
    else ($a | last | .message.content // [])
         | map(select(type == "object") | select(.type == "text") | .text // "")
         | join("\n")
    end' "$transcript" 2>/dev/null || true)"
[ -n "$text" ] || exit 0

violations="$(printf '%s\n' "$text" | bash "$lint_lib" lint 2>/dev/null)"
status=$?
[ "$status" -eq 1 ] || exit 0        # 0 = clean; 2 = the linter itself failed -> never block
[ -n "$violations" ] || exit 0

{
  printf 'STOP: this turn states volatile external status that was not read in this turn.\n\n'
  printf '%s\n' "$violations" | while IFS="$(printf '\t')" read -r ln word excerpt; do
    printf '  [%s] "%s" — %s\n' "$word" "$excerpt" "line $ln"
  done
  printf '\n'
  printf 'A PR/issue/CI status is only assertable from a read taken NOW. Do ONE of:\n'
  printf '  1. Re-read and quote the rendered line verbatim:\n'
  printf '       bash "$HOME/.claude/scripts/lib/state-assert.sh" observe pr|issue <n>\n'
  printf '     Empty stdout means say NOTHING about that entity.\n'
  printf '  2. Delete the claim. Most status narration is unrequested — dropping it is\n'
  printf '     always correct and costs the reader nothing.\n\n'
  printf 'Do not restate the status from memory or from an earlier read in this session:\n'
  printf 'that is the exact failure this gate exists to catch (base/practices/verify-before-asserting.md).\n'
} >&2

exit 2
