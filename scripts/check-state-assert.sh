#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for scripts/lib/state-assert.sh (#138).
#
# The contract under test is narrow and load-bearing:
#   1. A rendered line is PAST-TENSE and carries the observation time.
#   2. MERGED is decided by `mergedAt`, NOT by `state` — GitHub reports a merged PR as CLOSED,
#      so keying off state alone would render "CLOSED without merging" for a merged PR.
#   3. FAIL CLOSED means stdout is EMPTY. Every unverifiable path (gh missing, read error,
#      malformed JSON, foreign repo, unknown state) must render NO sentence — because the whole
#      point is that silence is safe and a guessed status is the bug.
#   4. A number is a number: no flag, path or empty string reaches `gh`.
#
# `gh` is stubbed by a shim on PATH driven by SHIM_* env vars, so the suite runs offline with no
# network and no real repo. Observables per case: exit code AND stdout (stderr is diagnostic only).
#
# It also pins the WORKFLOW WIRING, because a library nothing calls enforces nothing: the three
# narrating workflows must each reference the helper, and implement-issue must not regress to
# claiming `required_conversation_resolution` waits for a future review.
#
# Usage: bash scripts/check-state-assert.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
LIB="$ROOT/scripts/lib/state-assert.sh"

command -v jq >/dev/null 2>&1 || { echo "check-state-assert: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/has + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- gh shim -----------------------------------------------------------------------
# Mirrors the pattern used by check-implement-gate.sh: a PATH shim answering only the
# subcommands the library actually issues, driven entirely by SHIM_* variables.
shimbin="$work/bin"; mkdir -p "$shimbin"
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    if [ "${SHIM_REPO_FAIL:-0}" = "1" ]; then echo "gh: auth error" >&2; exit 1; fi
    printf '%s\n' "${SHIM_REPO_URL:-https://github.com/o/r}" ;;
  "pr view")
    if [ "${SHIM_PR_FAIL:-0}" = "1" ]; then echo "gh: no such PR" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_JSON:-}" ;;
  "issue view")
    if [ "${SHIM_ISSUE_FAIL:-0}" = "1" ]; then echo "gh: no such issue" >&2; exit 1; fi
    printf '%s\n' "${SHIM_ISSUE_JSON:-}" ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"

# Run the library with the shim in front of PATH. Captures stdout only; stderr is diagnostic.
run() { PATH="$shimbin:$PATH" bash "$LIB" "$@" 2>/dev/null; }
run_rc() { PATH="$shimbin:$PATH" bash "$LIB" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# ============================ 1. rendered observations ============================

# An OPEN PR renders past-tense and names the entity.
export SHIM_REPO_URL="https://github.com/o/r"
export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
OUT="$(run observe pr 7)"
has "$OUT" "PR #7 was observed OPEN at " "open PR renders past-tense with a timestamp"
eq "$(run_rc observe pr 7)" "0" "open PR exits 0"

# THE CORE CASE (#138's first observed violation): a PR that MERGED between reads. GitHub reports
# it as state=CLOSED with a mergedAt, so a `state`-only implementation would say "CLOSED without
# merging" — and the run that narrated "#137 is still open" would merely have swapped one wrong
# sentence for another.
export SHIM_PR_JSON='{"state":"CLOSED","mergedAt":"2026-07-27T21:48:14Z","url":"https://github.com/o/r/pull/137"}'
OUT="$(run observe pr 137)"
has "$OUT" "PR #137 was observed MERGED at " "merged PR is MERGED, not CLOSED (mergedAt wins over state)"

# A genuinely closed-without-merge PR says so, and says it distinctly.
export SHIM_PR_JSON='{"state":"CLOSED","mergedAt":null,"url":"https://github.com/o/r/pull/8"}'
OUT="$(run observe pr 8)"
has "$OUT" "PR #8 was observed CLOSED without merging at " "closed-unmerged PR is distinguished from merged"

# Issues: OPEN, closed-completed, and closed-NOT_PLANNED are three different facts. Flattening
# NOT_PLANNED into "closed" is how an ABANDONED requirement reads as a delivered one.
export SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/o/r/issues/138"}'
has "$(run observe issue 138)" "issue #138 was observed OPEN at " "open issue renders"
export SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/o/r/issues/134"}'
has "$(run observe issue 134)" "issue #134 was observed CLOSED as completed at " "completed issue renders"
export SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"NOT_PLANNED","url":"https://github.com/o/r/issues/77"}'
has "$(run observe issue 77)" "issue #77 was observed CLOSED as NOT_PLANNED at " "NOT_PLANNED is not flattened into completed"

# No rendered line may promise the future. These are the words that shipped the second violation.
export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
OUT="$(run observe pr 7)"
case "$OUT" in
  *" is still "*|*" will "*|*" is waiting"*) bad "rendered line contains a predictive phrase: [$OUT]" ;;
  *) ok ;;
esac

# ============================ 2. fail closed = EMPTY stdout ============================
# Each of these must render NOTHING. A non-empty stdout here is the bug the file exists to prevent.

fails_closed() { # <label> — asserts empty stdout AND rc 3, with the env already set
  local label="$1"; shift
  local out rc
  out="$(run "$@")"; rc="$(run_rc "$@")"
  eq "$out" "" "$label: renders no sentence"
  eq "$rc" "3" "$label: exits 3 (unverifiable)"
}

export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
SHIM_PR_FAIL=1 fails_closed "gh read error" observe pr 7
SHIM_PR_FAIL=0 SHIM_PR_JSON='' fails_closed "empty response" observe pr 7
SHIM_PR_JSON='not json at all' fails_closed "malformed JSON" observe pr 7
SHIM_PR_JSON='{"state":"","mergedAt":null,"url":"https://github.com/o/r/pull/7"}' \
  fails_closed "blank state" observe pr 7
SHIM_PR_JSON='{"state":"WEIRD","mergedAt":null,"url":"https://github.com/o/r/pull/7"}' \
  fails_closed "unrecognized state" observe pr 7
# A same-numbered PR in ANOTHER repo must never be rendered as if it were local — the identity
# check #44 established on the Stop-hook side, applied to narration.
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/other/repo/pull/7"}' \
  fails_closed "foreign-repo PR" observe pr 7
SHIM_REPO_FAIL=1 fails_closed "repo unresolvable" observe pr 7

export SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/o/r/issues/1"}'
SHIM_ISSUE_FAIL=1 fails_closed "issue read error" observe issue 1
SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/other/repo/issues/1"}' \
  fails_closed "foreign-repo issue" observe issue 1

# gh absent entirely (a real condition on a fresh machine) — still silence, never a guess.
OUT="$(PATH="$work/empty" bash "$LIB" observe pr 7 2>/dev/null)"
eq "$OUT" "" "gh missing: renders no sentence"

# ============================ 3. argument validation ============================
# rc 2 AND empty stdout. Arguments are passed for real rather than word-split out of a string:
# a quoted "" inside such a string is two literal apostrophes, so the empty-number case would
# silently test something else and pass for the wrong reason.
usage_rejects() { # <label> [args...]
  local label="$1"; shift
  local out rc
  out="$(PATH="$shimbin:$PATH" bash "$LIB" "$@" 2>/dev/null)"
  PATH="$shimbin:$PATH" bash "$LIB" "$@" >/dev/null 2>&1; rc=$?
  eq "$out" "" "usage $label: renders no sentence"
  eq "$rc" "2" "usage $label: exits 2"
}

usage_rejects "missing number"        observe pr
usage_rejects "non-numeric number"    observe pr abc
usage_rejects "empty number"          observe pr ""
usage_rejects "negative number"       observe pr -1
usage_rejects "path traversal"        observe pr ../../etc
usage_rejects "unknown entity kind"   observe bogus 1
usage_rejects "missing kind"          observe
usage_rejects "no arguments at all"
usage_rejects "unknown subcommand"    nonsense
# A trailing flag must not be silently dropped: the caller thinks it asked a narrower question,
# and answering the broader one confidently is precisely this file's failure mode.
usage_rejects "trailing flag"         observe pr 1 --json state

# `help` is not an error path.
eq "$(run_rc --help)" "0" "--help exits 0"

# ============================ 4. workflow wiring ============================
# A library nothing calls enforces nothing. These pin the three narrating workflows to it.
for wf in cleanup implement-issue resolve-pr-threads; do
  src="$ROOT/base/workflows/$wf.md"
  if grep -q '{{STATE_ASSERT_LIB}}' "$src"; then ok; else
    bad "base/workflows/$wf.md does not reference {{STATE_ASSERT_LIB}}"
  fi
done

# The placeholder must actually be substituted by the renderer, or the rendered skills would ship
# a literal `{{STATE_ASSERT_LIB}}` for agents to execute.
if grep -q '{{STATE_ASSERT_LIB}}' "$ROOT/scripts/build.sh"; then ok; else
  bad "scripts/build.sh has no {{STATE_ASSERT_LIB}} substitution"
fi

# The regression that started this: the close-out must not claim the setting waits for a review
# that has not happened. Pin the corrected wording rather than the absence of a phrase, so a
# reflow cannot silently drop the correction.
if grep -q 'never waits for a future review' "$ROOT/base/workflows/implement-issue.md"; then ok; else
  bad "implement-issue.md lost the 'never waits for a future review' correction (#138)"
fi
if grep -q 'not "the PR will wait"' "$ROOT/base/workflows/implement-issue.md"; then ok; else
  bad "implement-issue.md lost the observed-result-not-prediction rule (#138)"
fi

# The practice is the single source for the law; the workflows only carry call sites (#124's
# defect is a law restated per workflow, and this check exists so we do not recreate it).
if grep -q 'Render the sentence from the read, in one step' \
     "$ROOT/base/practices/verify-before-asserting.md"; then ok; else
  bad "verify-before-asserting.md lost the read-and-render section (#138)"
fi

check_summary "check-state-assert"
