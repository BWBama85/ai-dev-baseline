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

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
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
    [ -n "${SHIM_ARGLOG:-}" ] && printf '%s\n' "$*" >> "$SHIM_ARGLOG"
    [ -n "${SHIM_DELAY:-}" ] && sleep "$SHIM_DELAY"
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
OUT="${ run observe pr 7; }"
has "$OUT" "PR #7 was observed OPEN at " "open PR renders past-tense with a timestamp"
run observe pr 7 >/dev/null 2>&1; eq "$?" "0" "open PR exits 0"

# THE CORE CASE (#138's first observed violation): a PR that MERGED between reads. GitHub reports
# it as state=CLOSED with a mergedAt, so a `state`-only implementation would say "CLOSED without
# merging" — and the run that narrated "#137 is still open" would merely have swapped one wrong
# sentence for another.
export SHIM_PR_JSON='{"state":"CLOSED","mergedAt":"2026-07-27T21:48:14Z","url":"https://github.com/o/r/pull/137"}'
OUT="${ run observe pr 137; }"
has "$OUT" "PR #137 was observed MERGED at " "merged PR is MERGED, not CLOSED (mergedAt wins over state)"

# A genuinely closed-without-merge PR says so, and says it distinctly.
export SHIM_PR_JSON='{"state":"CLOSED","mergedAt":null,"url":"https://github.com/o/r/pull/8"}'
OUT="${ run observe pr 8; }"
has "$OUT" "PR #8 was observed CLOSED without merging at " "closed-unmerged PR is distinguished from merged"

# Issues: OPEN, closed-completed, and closed-NOT_PLANNED are three different facts. Flattening
# NOT_PLANNED into "closed" is how an ABANDONED requirement reads as a delivered one.
export SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/o/r/issues/138"}'
has "${ run observe issue 138; }" "issue #138 was observed OPEN at " "open issue renders"
export SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/o/r/issues/134"}'
has "${ run observe issue 134; }" "issue #134 was observed CLOSED as completed at " "completed issue renders"
export SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"NOT_PLANNED","url":"https://github.com/o/r/issues/77"}'
has "${ run observe issue 77; }" "issue #77 was observed CLOSED as NOT_PLANNED at " "NOT_PLANNED is not flattened into completed"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# No rendered line may promise the future. These are the words that shipped the second violation.
export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
OUT="${ run observe pr 7; }"
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
  out="${ run "$@"; }"; rc=$?
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
has "${ run observe pr 146; }" "PR #146 was observed OPEN at " "a real PR in a repo named 'issues' still renders"
SHIM_ISSUE_JSON='{"state":"OPEN","stateReason":null,"url":"https://github.com/acme/pull/issues/9"}'
has "${ run observe issue 9; }" "issue #9 was observed OPEN at " "a real issue in a repo named 'pull' still renders"

# The response must be ABOUT the entity asked for. Only a misbehaving read produces this, but
# rendering "PR #9" from a payload describing #146 is a wrong sentence, and a wrong sentence is
# worse than none. Zero-padding must not fail spuriously: `-eq` compares numerically.
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/146"}' \
  fails_closed "payload describes a different entity number" observe pr 9
SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/146"}'
has "${ run observe pr 0146; }" "PR #0146 was observed OPEN at " "a zero-padded argument matches its own URL"
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

# ============ 3b. review findings from PR #154 (chatgpt-codex-connector) ============

# FINDING 1 — the observation time must be recorded AFTER the read, not before it.
# If the entity changes while the read is in flight, a pre-read stamp names an instant at which
# the reported state was demonstrably false. Proven with a deliberately slow read: the rendered
# timestamp must land after the read RETURNS, not when it started.
export SHIM_PR_JSON='{"state":"OPEN","mergedAt":null,"url":"https://github.com/o/r/pull/7"}'
_t_before="$(date -u +%s)"
_rendered="$(SHIM_DELAY=2 run observe pr 7)"
_stamp="${_rendered##*at }"
# Portable ISO-8601 -> epoch: BSD `date -j -f` on macOS, GNU `date -d` elsewhere.
_stamp_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$_stamp" +%s 2>/dev/null \
             || date -u -d "$_stamp" +%s 2>/dev/null)"
if [ -n "$_stamp_epoch" ] && [ "$_stamp_epoch" -ge "$((_t_before + 2))" ]; then ok; else
  bad "timestamp must be recorded after the read returns: stamp=$_stamp before=$_t_before"
fi

# FINDING 2 — every read is pinned to the CHECKOUT's repo with --repo, so the documented GH_REPO
# override cannot redirect it. Without this, both remaining guards still pass (right segment, right
# number) and a confident status is rendered for a DIFFERENT project. Demonstrated live before the
# fix: `GH_REPO=cli/cli ... observe pr 1` rendered "PR #1 was observed MERGED" from this checkout.
_arglog="$work/args.txt"; : > "$_arglog"
SHIM_ARGLOG="$_arglog" run observe pr 7 >/dev/null 2>&1
if grep -q -- '--repo' "$_arglog"; then ok; else
  bad "the read must pass --repo so GH_REPO cannot redirect it (args: $(cat "$_arglog"))"
fi
# The slug is derived from git, which no gh env var can move — so GH_REPO must not change the
# arguments the library builds.
: > "$_arglog"
GH_REPO="other/repo" SHIM_ARGLOG="$_arglog" run observe pr 7 >/dev/null 2>&1
if grep -q -- "--repo" "$_arglog" && ! grep -q -- "other/repo" "$_arglog"; then ok; else
  bad "GH_REPO must not influence the --repo slug (args: $(cat "$_arglog"))"
fi
# No parseable git remote -> fail closed, never an unqualified read.
_norepo="$work/norepo"; mkdir -p "$_norepo"
_out="$(cd "$_norepo" && PATH="$shimbin:$PATH" bash "$LIB" observe pr 7 2>/dev/null)"
eq "$_out" "" "no parseable git remote: renders no sentence"

# FINDING 3 — a CLOSED issue with no recognized stateReason is UNVERIFIABLE, never "completed".
# stateReason is the field that distinguishes delivered work from abandoned work, so inferring
# delivery from the mere absence of evidence is the false-delivery claim this file exists to stop.
# GitHub returns it null for issues closed before the field existed, so the arm is reachable.
SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":null,"url":"https://github.com/o/r/issues/5"}' \
  fails_closed "CLOSED issue with a null stateReason" observe issue 5
SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"REOPENED_THEN_CLOSED","url":"https://github.com/o/r/issues/5"}' \
  fails_closed "CLOSED issue with an unknown stateReason" observe issue 5
export SHIM_ISSUE_JSON='{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/o/r/issues/5"}'
has "${ run observe issue 5; }" "issue #5 was observed CLOSED as completed at " "an explicit COMPLETED still renders"

# ============================ 3b. lint — the claim grammar (#195) ============================
# `observe` makes a stated status correct; it cannot make anyone state one. `lint` is the half that
# can fail a turn, so its grammar is pinned here — precision first, because a gate that cries wolf
# gets worked around and this ships to every adopting repo.

# lint <text> — echo the exit status (0 clean, 1 violations).
lint_rc() { printf '%s\n' "$1" | bash "$LIB" lint >/dev/null 2>&1; printf '%s' "$?"; }
# lint_out <text> — the violation rows.
lint_out() { printf '%s\n' "$1" | bash "$LIB" lint 2>/dev/null; }

# --- 3b-a. THE REGRESSION FIXTURE: the exact sentence that shipped on 2026-07-29 --------------
# One sentence, two clauses: a COMPLIANT `was observed MERGED` and a STALE `(OPEN at …)` quoting a
# 14-minute-old read. A sentence-level test finds the template and passes the whole line, which is
# why the check is per-OCCURRENCE. If this ever goes green, the gate has stopped working.
SHIPPED='PR #194 was observed MERGED at 2026-07-29T15:09:10Z — it merged between my last check (OPEN at 14:55:26Z) and this sweep.'
eq "${ lint_rc "$SHIPPED"; }" 1 "the 2026-07-29 sentence is a violation"
has "${ lint_out "$SHIPPED"; }" "open" "...the stale parenthetical is named"

# --- 3b-b. a verbatim observe line is always compliant ---------------------------------------
for line in \
  'PR #194 was observed MERGED at 2026-07-29T15:09:10Z' \
  'PR #194 was observed OPEN at 2026-07-29T14:55:26Z' \
  'PR #12 was observed CLOSED without merging at 2026-07-29T14:55:26Z' \
  'issue #5 was observed OPEN at 2026-07-29T14:55:26Z' \
  'issue #5 was observed CLOSED as completed at 2026-07-29T14:55:26Z' \
  'issue #5 was observed CLOSED as NOT_PLANNED at 2026-07-29T14:55:26Z'
do
  eq "${ lint_rc "$line"; }" 0 "compliant: ${line:0:38}..."
done

# --- 3b-c. the canonical failures the practice names ------------------------------------------
eq "${ lint_rc 'PR #137 is still open.'; }" 1 "\"still open\" is a violation"
eq "${ lint_rc 'Issue #40 is closed.'; }" 1 "a bare closed-claim is a violation"
eq "${ lint_rc 'CI is green on PR #194.'; }" 1 "an unsourced CI claim bound to a PR is a violation"
eq "${ lint_rc 'PR #194 is merged and #195 is still open.'; }" 1 "multiple claims in one line are caught"

# --- 3b-d. PRECISION: ordinary English must not fire ------------------------------------------
# Every one of these is a verb or an intent, not a state assertion. A gate that flags them is a
# gate that gets disabled.
eq "${ lint_rc 'Let me open a PR for #195.'; }" 0 "\"open a PR\" is a verb, not a claim"
eq "${ lint_rc 'I merged the branch for #195.'; }" 0 "\"merged the branch\" is a verb"
eq "${ lint_rc 'I will close #195 once this lands.'; }" 0 "an intent is not a claim"
eq "${ lint_rc 'Filed as #195 and started the branch.'; }" 0 "no status word at all"
eq "${ lint_rc 'The green path in roadmap-lib was unreachable.'; }" 0 "a status word with no entity reference"
eq "${ lint_rc 'This closed a whole class of bugs.'; }" 0 "\"closed a class\" is a verb with no entity"

# --- 3b-e. ONLY PROSE DECLARES (#117 applied to claims) ---------------------------------------
eq "${ lint_rc "${ printf '```\nPR #1 is still open\n```'; }"; }" 0 "a fenced block declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc "${ printf '~~~\nPR #1 is still open\n~~~'; }"; }" 0 "a tilde fence declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc 'The rule forbids `PR #1 is still open` in prose.'; }" 0 "an inline code span declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc '> PR #1 is still open'; }" 0 "a blockquote declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc '<!-- PR #1 is still open -->'; }" 0 "an HTML comment declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc "${ printf '<!--\nPR #1 is still open\n-->'; }"; }" 0 "a multi-line HTML comment declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
# ...but a real claim AFTER a closed fence is still caught.
eq "${ lint_rc "${ printf '```\ncode\n```\nPR #1 is still open.'; }"; }" 1 "a claim after a fence is still a violation"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# --- 3b-g. the observe phrase binds to ITS OWN word, not to a later one (review round 1) ------
# `was observed [a-z ]*$` let a second status word inherit an earlier clause's compliance, so
# "was observed OPEN but is now CLOSED" passed ENTIRELY — the mixed compliant/stale sentence this
# check is per-occurrence in order to catch. Only an IMMEDIATE `was observed ` counts.
eq "${ lint_rc 'PR #1 was observed OPEN but is now CLOSED.'; }" 1 "a later status word cannot inherit an earlier \"was observed\""  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
has "${ lint_out 'PR #1 was observed OPEN but is now CLOSED.'; }" "closed" "...and the stale word is named"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_out 'PR #1 was observed OPEN but is now CLOSED.' | wc -l | tr -d ' '; }" 1 "...while the genuinely-observed word is not also flagged"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc 'PR #1 was observed OPEN and I then merged the branch.'; }" 0 "a verb after a compliant clause is still a verb"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# --- 3b-h. a status word taking an ENTITY object is a verb (review round 1) -------------------
# "I closed #195" reports an action just performed; it is not an assertion about current state.
# Stripping punctuation before the object test left `nextw` empty and misread these as claims.
eq "${ lint_rc 'I closed #195.'; }" 0 "\"closed #195\" is a verb with an entity object"
eq "${ lint_rc 'I reopened #5 after the revert.'; }" 0 "\"reopened #5\" likewise"
eq "${ lint_rc 'Merged #194 and started the follow-up.'; }" 0 "\"Merged #194\" likewise"
# ...but a genuine state assertion about the same entity still fires.
eq "${ lint_rc 'Issue #195 is closed.'; }" 1 "a predicative claim about the same entity still fires"

# --- 3b-i. multi-backtick code spans declare nothing (review round 1) -------------------------
# CommonMark permits a run of N backticks; a single-backtick-only stripper left that content
# exposed, so quoting a status the way this repo's own docs do would block a turn.
eq "${ lint_rc 'The docs show ``PR #1 is still open`` as an example.'; }" 0 "a double-backtick span declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc 'See ```PR #1 is still open``` inline.'; }" 0 "a triple-backtick span declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc 'Quoting ``PR #1 is still open`` but PR #2 is still open.'; }" 1 "...while a real claim beside a quoted one is still caught"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# --- 3b-i2. ...INCLUDING one whose body carries a lone backtick (#251) -------------------------
# THE APPROXIMATION THAT SHIPPED, and it was a live false positive rather than the "second half of
# one conversion" #251 filed it as. The old stripper collapsed every run of 2+ backticks to one and
# then matched `` `[^`]*` ``, so a CommonMark span fenced by TWO ticks whose body contains a lone
# tick was cut at the INNER tick: `` ``PR ` #1 is still open`` `` stripped to `  #1 is still open` `
# and fired `open`. That is a Stop hook blocking a turn for quoting a status the way this very repo
# documents one — the precision failure the grammar's own header says it is built to avoid.
#
# Observed RED against the pre-conversion library before the shared filter landed (rc 1, naming
# `open`), which is what makes it a witness rather than decoration.
#
# ONE LINE PER ASSERTION, and that is not a style choice: the `adb-claim-ok:` escape is PER LINE, so
# a wrapped `eq` puts the marker on the continuation while the fixture string — carrying `PR #1` —
# sits on the line above, unexempted. The live claim lint caught exactly that here, which is the
# trap check-claims.sh's own header names.
eq "${ lint_rc 'The docs show ``PR ` #1 is still open`` as an example.'; }" 0 "a 2-tick span whose BODY holds a lone backtick declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
# ...and the filter must not swallow live prose to achieve that: a real claim beside it still fires,
# exactly once.
eq "${ lint_rc 'Quoting ``PR ` #1 is still open`` but PR #2 is still open.'; }" 1 "...while a real claim beside THAT span is still caught"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_out 'Quoting ``PR ` #1 is still open`` but PR #2 is still open.' | wc -l | tr -d ' '; }" 1 "...and only the real one is reported"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# THE EXCERPT MUST STAY PRINTABLE. The mask view replaces a span's bytes with \x01, and the Stop
# hook prints this excerpt straight to the operator — so the mask byte is an internal matching
# boundary that must never reach a diagnostic. Asserted on the raw bytes, because a control byte is
# invisible in a diff and in most terminals: exactly the way this would ship unnoticed.
SA_MASKFIX='Quoting ``PR ` #1 is still open`` but PR #2 is still open.'  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_out "$SA_MASKFIX" | tr -d '\001' | wc -c | tr -d ' '; }" "${ lint_out "$SA_MASKFIX" | wc -c | tr -d ' '; }" \
   "the excerpt carries NO \\x01 mask byte — it is printed verbatim by the Stop hook"

# --- 3b-i3. the shared filter's block model, now that lint uses it (#251) ---------------------
# Indented code is structure (D27), so a 4-space-indented claim after a blank line no longer fires.
# STATED AS A COST, not hidden: it is CommonMark's rule and the same one every other consumer of
# the filter obeys, and the alternative — lint keeping a private block model — is the fourth copy
# #136 exists to delete. Indented code CANNOT interrupt a paragraph, so the far commoner shape (an
# indented line continuing prose above it) is unaffected, and that half is pinned too.
eq "${ lint_rc "${ printf 'Intro.\n\n    PR #1 is still open'; }"; }" 0 "the accepted cost: an indented CODE block declares nothing"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "${ lint_rc "${ printf 'Intro.\n    PR #1 is still open'; }"; }" 1 "...but indented code cannot interrupt a paragraph, so a wrapped claim still fires"  # adb-claim-ok: fixture INPUT to the parser under test, not a citation

# --- 3b-j. `draft` is not a status token (live false positive, hours after shipping) ---------
# It is an ordinary English noun and it collided with prose an agent genuinely writes. A gate that
# fires on ordinary prose gets worked around, and then it protects nothing — so the word is out of
# the set, which is the precision-over-recall trade stated in the header.
eq "${ lint_rc 'My first draft of the summary for #196 was wrong.'; }" 0 \
   "\"draft\" as an ordinary noun does not fire"
eq "${ lint_rc 'A rough draft of #196 exists.'; }" 0 "...in any ordinary phrasing"
# The cost is stated rather than hidden: a genuine draft-status claim is no longer caught.
eq "${ lint_rc 'PR #196 is a draft.'; }" 0 \
   "the accepted cost: a genuine draft-status claim is NOT caught"
# ...and removing it must not have weakened anything else.
eq "${ lint_rc 'PR #137 is still open.'; }" 1 "the load-bearing tokens still fire"
eq "${ lint_rc 'CI is green on PR #194.'; }" 1 "...including CI"

# --- 3b-k. straight quotes are PROSE, not markup ---------------------------------------------
# Only markup declares nothing. Double quotes are ambiguous — scare quotes, emphasis, and genuine
# quotation are indistinguishable — and stripping them would let `He said "PR #1 is still open"`
# through, which is a real claim in a real sentence. Backticks are the way to quote a status.
eq "${ lint_rc 'It fired on "CI on #196 is green".'; }" 1 "a double-quoted status is still a claim"
eq "${ lint_rc 'It fired on `CI on #196 is green`.'; }" 0 "...while a backticked one is not"

# --- 3b-f. determinism + hygiene ---------------------------------------------------------------
eq "${ lint_out "$SHIPPED"; }" "${ lint_out "$SHIPPED"; }" "lint is deterministic"
eq "${ printf '' | bash "$LIB" lint >/dev/null 2>&1; printf '%s' "$?"; }" 0 "empty input is clean"
eq "${ printf 'x' | bash "$LIB" lint EXTRA >/dev/null 2>&1; printf '%s' "$?"; }" 2 "lint rejects arguments"

# ================== 3c. the Stop hook that gives the grammar teeth (#195) ===================
# The grammar only matters if something acts on it. These drive the hook end to end against a
# synthetic transcript, because the failure this whole issue is about is a rule nothing enforced.
GATE="$ROOT/agents/claude/scripts/state-claim-gate.sh"
tdir="$work/hook"; mkdir -p "$tdir"
# The gate resolves its linter as `$(dirname $0)/lib/state-assert.sh`, matching the installed
# layout (~/.claude/scripts + ~/.claude/scripts/lib). Mirror that here rather than in the gate.
mkdir -p "$tdir/lib" && cp "$GATE" "$tdir/" && cp "$LIB" "$tdir/lib/" \
  && cp "$ROOT/scripts/lib/common.sh" "$tdir/lib/"
HOOK="$tdir/state-claim-gate.sh"

# transcript <text> — a one-message JSONL session log, then the hook payload naming it.
transcript() {
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "${ printf '%s' "$1" | jq -Rs .; }" > "$tdir/t.jsonl"
  printf '{"transcript_path":"%s"}' "$tdir/t.jsonl"
}
run_hook() { HOOK_OUT="${ printf '%s' "${ transcript "$1"; }" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?; }

run_hook "$SHIPPED"
eq "$HOOK_RC" 2 "the hook BLOCKS the turn on the 2026-07-29 sentence"
has "$HOOK_OUT" "volatile external status" "...and says why"
has "$HOOK_OUT" "state-assert.sh" "...and names the command that fixes it"
has "$HOOK_OUT" "Delete the claim" "...and offers deleting the claim as the other option"

run_hook 'PR #194 was observed MERGED at 2026-07-29T15:09:10Z.'
eq "$HOOK_RC" 0 "a compliant turn passes"
eq "$HOOK_OUT" "" "...silently"

run_hook 'Filed as #195; the branch is pushed.'
eq "$HOOK_RC" 0 "a turn with no status claim passes"

# --- the hook NEVER wedges a session on infrastructure absence -------------------------------
HOOK_OUT="${ printf '{"transcript_path":"/nonexistent/t.jsonl"}' | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "a missing transcript is a no-op, never a block"
HOOK_OUT="${ printf '{}' | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "a payload with no transcript_path is a no-op"
HOOK_OUT="${ printf 'not json' | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "an unparseable payload is a no-op"
printf 'garbage not json\n' > "$tdir/t.jsonl"
HOOK_OUT="${ printf '{"transcript_path":"%s"}' "$tdir/t.jsonl" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "an unparseable transcript is a no-op"
# A turn whose final message is pure tool use has no text to lint.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n' > "$tdir/t.jsonl"
HOOK_OUT="${ printf '{"transcript_path":"%s"}' "$tdir/t.jsonl" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "a text-free final message is a no-op"
# Missing linter -> reports, never blocks (#35: not silent, but not wedging either).
mv "$tdir/lib/state-assert.sh" "$tdir/lib/state-assert.sh.bak"
HOOK_OUT="${ printf '%s' "${ transcript "$SHIPPED"; }" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "a missing linter does not block the session"
has "$HOOK_OUT" "incomplete install" "...but says the claims are NOT being checked"
mv "$tdir/lib/state-assert.sh.bak" "$tdir/lib/state-assert.sh"

# --- A BROKEN LINTER DEPENDENCY IS NOT A CLEAN TURN (review round 1) -------------------------
# state-assert.sh exits 1 BOTH for "violations found" and for "broken install — common.sh
# missing", the latter before it can print a row. Reading an empty exit-1 as "no violations"
# disables this gate exactly when the install is damaged, and discarding the linter's stderr hides
# why. The gate must say so instead of passing silently.
mv "$tdir/lib/common.sh" "$tdir/lib/common.sh.bak"
HOOK_OUT="${ printf '%s' "${ transcript "$SHIPPED"; }" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "a broken linter dependency does not wedge the session"
has "$HOOK_OUT" "NOT being checked" "...but the gate reports that it is disabled"
has "$HOOK_OUT" "common.sh" "...and surfaces the linter's own diagnostic"
mv "$tdir/lib/common.sh.bak" "$tdir/lib/common.sh"

# --- A common.sh WITHOUT THE SHARED FILTER IS ALSO A BROKEN INSTALL (#251) -------------------
# Since the conversion, `lint` has no structure model of its own — it is `_ADB_MD_AWK` or nothing.
# A common.sh that PREDATES the filter loads perfectly well and simply has no `_ADB_MD_AWK` in it.
#
# WHAT THE PROBE BUYS, measured against a copy with its condition neutralized rather than assumed:
# WITHOUT it the run does not scan unstripped prose — awk aborts with `calling undefined function
# adb_md_run` and exits 2, which the Stop hook renders as the catch-all "the linter exited 2".
# WITH it the exit is the documented broken-install 1, and the message names the library and the
# missing primitive, which is what tells an operator to run `baseline update` rather than to go
# reading awk. So this fixture pins the CODE and the DIAGNOSTIC, and it was witnessed going red
# (2 -> 1) that way. Said exactly: the value here is a usable failure, not the difference between
# failing and not.
#
# Doctored in the COPY under $tdir, never in the working tree: this suite reads the tree it is
# testing (base/practices/self-review.md).
cp "$tdir/lib/common.sh" "$tdir/lib/common.sh.bak"
printf '\n_ADB_MD_AWK=""\n' >> "$tdir/lib/common.sh"
LINT_OUT="${ printf 'PR #1 is still open.\n' | bash "$tdir/lib/state-assert.sh" lint 2>&1; }"; LINT_RC=$?  # adb-claim-ok: fixture INPUT to the parser under test, not a citation
eq "$LINT_RC" 1 "a common.sh with no shared filter fails the lint rather than scanning raw markdown"
has "$LINT_OUT" "common.sh" "...and the diagnostic names the library, not a variable"
has "$LINT_OUT" "_ADB_MD_AWK" "...and the missing primitive"
# The Stop hook renders that as "claims are NOT being checked", never as a clean turn.
HOOK_OUT="${ printf '%s' "${ transcript "$SHIPPED"; }" | bash "$HOOK" 2>&1; }"; HOOK_RC=$?
eq "$HOOK_RC" 0 "...and the hook does not wedge the session over it"
has "$HOOK_OUT" "NOT being checked" "...but reports that the gate is disabled"
mv "$tdir/lib/common.sh.bak" "$tdir/lib/common.sh"

# --- EVERY CLAIM KIND GETS A COMMAND THAT CAN ANSWER IT (review round 1) ---------------------
# The grammar flags CI and branch status too, and `observe` answers neither. Offering it for a CI
# claim is advice that cannot be followed, which leaves "delete it" as the only real option even
# when the status was explicitly asked for.
run_hook 'CI is green on PR #194.'
eq "$HOOK_RC" 2 "an unsourced CI claim blocks"
has "$HOOK_OUT" "branch-health" "...and is routed to the CI predicate, not to observe"
run_hook 'The branch for #195 is unmerged.'
eq "$HOOK_RC" 2 "an unsourced branch claim blocks"
has "$HOOK_OUT" "branch-verdict" "...and is routed to the branch predicate"
run_hook 'PR #137 is still open.'
has "$HOOK_OUT" "state-assert.sh" "a PR-state claim is still routed to observe"
has "$HOOK_OUT" "ambiguous" "...and the merged-PR vs merged-branch ambiguity is called out"

# The hook must be in the ONE hook enumeration, or install wires it and uninstall never removes it.
has "$(bash -c '. scripts/lib/common.sh; adb_claude_hook_scripts')" "state-claim-gate.sh" \
  "the gate is registered in adb_claude_hook_scripts"
has "$(cat "$ROOT/agents/claude/settings.hooks.json")" "state-claim-gate.sh" \
  "...and wired as a Stop hook in settings.hooks.json"

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
