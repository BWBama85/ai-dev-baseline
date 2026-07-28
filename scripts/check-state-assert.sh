#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for scripts/lib/state-assert.sh (#138).
#
# The contract under test is narrow and load-bearing:
#   1. A rendered line is PAST-TENSE and carries the observation time.
#   2. MERGED is decided by `mergedAt`, NOT by `state` — GitHub reports a merged PR as CLOSED,
#      so keying off state alone would render "CLOSED without merging" for a merged PR.
#   3. FAIL CLOSED means stdout is EMPTY. Every unverifiable path (unauthenticated gh, read
#      error, malformed JSON, wrong entity kind, unknown state) must render NO sentence — the
#      whole point is that silence is safe and a guessed status is the bug.
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
  "auth status")
    # adb_require_gh (common.sh) checks auth before any read; an unauthenticated gh must
    # fail closed exactly like an unreadable one.
    if [ "${SHIM_AUTH_FAIL:-0}" = "1" ]; then echo "gh: not authenticated" >&2; exit 1; fi
    exit 0 ;;
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
# ONE invocation per assertion. `out="$(run ...)"; rc=$?` yields both the stdout and the exit
# status, because a command substitution's status IS the command's. Running twice (once for each)
# doubled every case's process cost for nothing. `local out rc` must stay on its own line: a
# combined `local out="$(...)"` would mask $? with local's own status.
run() { PATH="$shimbin:$PATH" bash "$LIB" "$@" 2>/dev/null; }

# ============================ 1. rendered observations ============================

# An OPEN PR renders past-tense and names the entity.
export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
OUT="$(run observe pr 7)"
has "$OUT" "PR #7 was observed OPEN at " "open PR renders past-tense with a timestamp"
run observe pr 7 >/dev/null 2>&1; eq "$?" "0" "open PR exits 0"

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

# expect_silent <rc> <label> [args...] — the one shape both the unverifiable and the usage
# families need: stdout MUST be empty, and the exit code must be the expected one.
expect_silent() {
  local want_rc="$1" label="$2"; shift 2
  local out rc
  out="$(run "$@")"; rc=$?
  eq "$out" "" "$label: renders no sentence"
  eq "$rc" "$want_rc" "$label: exits $want_rc"
}
fails_closed() { local label="$1"; shift; expect_silent 3 "$label" "$@"; }

export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
SHIM_PR_FAIL=1 fails_closed "gh read error" observe pr 7
SHIM_PR_FAIL=0 SHIM_PR_JSON='' fails_closed "empty response" observe pr 7
SHIM_PR_JSON='not json at all' fails_closed "malformed JSON" observe pr 7
SHIM_PR_JSON='{"state":"","mergedAt":null,"url":"https://github.com/o/r/pull/7"}' \
  fails_closed "blank state" observe pr 7
SHIM_PR_JSON='{"state":"WEIRD","mergedAt":null,"url":"https://github.com/o/r/pull/7"}' \
  fails_closed "unrecognized state" observe pr 7
# Cross-repo safety is now STRUCTURAL rather than a string compare: the argument is validated as
# a bare integer and `gh pr view <n>` resolves it against the LOCAL remote's repo, so no other
# repository is addressable. An earlier draft spent a whole `gh repo view` round trip proving
# this — 55-70% of the command's wall time for a property the argument type already guarantees.
# What the URL check still earns is the entity-kind discrimination below, which the number cannot
# answer. gh being present but UNAUTHENTICATED is a real condition and must fail closed too.
SHIM_AUTH_FAIL=1 fails_closed "gh not authenticated" observe pr 7

export SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/o/r/issues/1"}'
SHIM_ISSUE_FAIL=1 fails_closed "issue read error" observe issue 1
# PRs and issues share ONE number space, and `gh issue view <PR number>` really does answer with
# the pull request (GitHub models a PR as an issue). Verified live against this repo. Only the
# URL discriminates — `/pull/N` vs `/issues/N` — so without that check `observe issue 146` would
# confidently render a PR's state as an issue's. Pin it: the number-space overlap is permanent.
SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/o/r/pull/146"}' \
  fails_closed "a PR answered by 'gh issue view' is not an issue" observe issue 146
# ...and the mirror: a PR read whose URL is an issue URL is equally not a PR.
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/issues/138"}' \
  fails_closed "an issue answered by 'gh pr view' is not a PR" observe pr 138

# REPO-NAME COLLISION. The kind segment is compared EXACTLY at its known position, never searched
# for in the URL, because an ordinary repo NAME can supply it. Repos called `issues` exist in the
# wild (esphome/issues, cmangos/issues, tuna/issues) and this library installs into arbitrary
# projects. Under a substring test, a PR in `acme/issues` has the URL
# `https://github.com/acme/issues/pull/146` — which contains `/issues/` — so `observe issue 146`
# rendered "issue #146 was observed CLOSED as completed" for a PULL REQUEST, at exit 0, in one
# clean sentence. Demonstrated against the real library before the fix.
SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/acme/issues/pull/146"}' \
  fails_closed "a PR in a repo NAMED 'issues' is not an issue" observe issue 146
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/acme/pull/issues/9"}' \
  fails_closed "an issue in a repo NAMED 'pull' is not a PR" observe pr 9

# ...and the legitimate members of those same repos must STILL render, or the fix would have
# traded a wrong sentence for a missing one.
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/acme/issues/pull/146"}'
has "$(run observe pr 146)" "PR #146 was observed OPEN at " "a real PR in a repo named 'issues' still renders"
SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/acme/pull/issues/9"}'
has "$(run observe issue 9)" "issue #9 was observed OPEN at " "a real issue in a repo named 'pull' still renders"

# The response must be ABOUT the entity asked for. Only a misbehaving read produces this, but
# rendering "PR #9" from a payload describing #146 is a wrong sentence, and a wrong sentence is
# worse than none. Zero-padding must not fail spuriously: `-eq` compares numerically.
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/146"}' \
  fails_closed "payload describes a different entity number" observe pr 9
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/146"}'
has "$(run observe pr 0146)" "PR #0146 was observed OPEN at " "a zero-padded argument matches its own URL"
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/abc"}' \
  fails_closed "unparseable entity number in the URL" observe pr 7

# NOTE on "gh absent": deliberately NOT tested here. `adb_require_gh` (common.sh) prepends the
# brew prefix when gh is missing, so on a macOS dev box an empty PATH still finds the real gh and
# the case would silently become a live network test. The authentication arm above covers the same
# fail-closed branch offline and deterministically.

# ============================ 3. argument validation ============================
# rc 2 AND empty stdout. Arguments are passed for real rather than word-split out of a string:
# a quoted "" inside such a string is two literal apostrophes, so the empty-number case would
# silently test something else and pass for the wrong reason.
usage_rejects() { local label="$1"; shift; expect_silent 2 "usage $label" "$@"; }

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
run --help >/dev/null 2>&1; eq "$?" "0" "--help exits 0"

# ============================ 4. wiring lives in its declared home ============================
# The token pins that used to sit here moved to scripts/check-fact-drift.sh, which is the lint
# whose charter this is:
#   - `state-assert-observe`  pins `{{STATE_ASSERT_LIB}} observe` across all three workflows.
#   - `no-arm-prediction`     pins the RETIRED predictive phrasing with `absent:`.
# Two reasons, both learned from #148. First, this file is a library UNIT test; a cross-file docs
# lint is a different genre and belongs with the other facts. Second, the pins here grepped ENGLISH
# SENTENCES — one of them containing a nested quote sitting near the wrap column — so a reflow
# would fail CI with zero behavior change, while a freshly-added prediction two lines away would
# leave the grep green. `absent:` pins what must not come back, which survives reformatting.
#
# Per-agent render coverage for {{STATE_ASSERT_LIB}} likewise lives in check-workflow-render.sh
# beside the other placeholders, rather than as a weaker grep of build.sh for the bare token.

check_summary "check-state-assert"
