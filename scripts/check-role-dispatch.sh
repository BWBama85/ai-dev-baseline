#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the runtime role-dispatch helper (scripts/lib/role-dispatch.sh, #15).
#
# Exercises the three surfaces without touching a real agent CLI:
#   resolve — repo → global → built-in order, review cardinality, skip/unset, and validation
#             (unknown token, empty `review = []`, no fall-through past an invalid higher layer);
#   bots    — the async-reviewer allowlist (default set / [reviewers] override / [] disable);
#   invoke  — dispatch to a PATH-STUBBED agent, proving codex's --output-last-message clean
#             capture (exploration noise never reaches stdout), the multi-agent refusal, the
#             unassigned/incomplete/timeout exit codes, and the source guard.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-role-dispatch.sh   (exit 0 = all pass, 1 = a failure)

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
RD="$ROOT/scripts/lib/role-dispatch.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

REPO="$work/repo"; GHOME="$work/home"; BIN="$work/bin"
# A second stub dir, so a concurrent case can install a DIFFERENT codex stub without racing the
# others over $BIN/codex.
BIN2="$work/bin2"
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$BIN" "$BIN2"
# A git repo so `git rev-parse --show-toplevel` inside the helper is deterministically $REPO,
# regardless of any ambient git repo above the temp dir.
git init -q "$REPO"

# Run the helper as the repo's driving agent would: from $REPO, with the throwaway HOME (global
# manifest) and the stub agents on PATH.
rd() { ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" bash "$RD" "$@" ); }
set_repo()   { printf '%s\n' "$@" > "$REPO/agents.toml"; }
clr_repo()   { rm -f "$REPO/agents.toml"; }
set_global() { printf '%s\n' "$@" > "$GHOME/.config/ai-dev-baseline/agents.toml"; }
clr_global() { rm -f "$GHOME/.config/ai-dev-baseline/agents.toml"; }

# ============================ resolve ============================
set_repo '[roles]' 'primary = "claude"' 'gap_analysis = "codex"' 'review = ["claude"]' 'debug = "claude"'
clr_global
eq "${ rd resolve primary; }"      "claude" "resolve primary from repo"
eq "${ rd resolve gap_analysis; }" "codex"  "resolve gap_analysis from repo"
eq "${ rd resolve review; }"       "claude" "resolve single-element review"
eq "${ rd resolve debug; }"        "claude" "resolve debug from repo"

# multi-agent review list
set_repo '[roles]' 'primary = "claude"' 'review = ["claude", "gemini"]'
eq "${ rd resolve review | tr '\n' ','; }" "claude,gemini," "resolve multi-agent review list"

# resolution ORDER: no repo file → global default manifest wins
clr_repo
set_global '[roles]' 'primary = "codex"' 'review = ["gemini"]'
eq "${ rd resolve primary; }" "codex"  "unset repo → global primary"
eq "${ rd resolve review; }"  "gemini" "unset repo → global review"

# built-in fallback (no manifest anywhere): primary=claude; review/debug → primary; gap → skip
clr_repo; clr_global
eq "${ rd resolve primary; }" "claude" "built-in primary default is claude"
eq "${ rd resolve review; }"  "claude" "built-in review falls back to primary"
eq "${ rd resolve debug; }"   "claude" "built-in debug falls back to primary"
out="${ rd resolve gap_analysis; }"; rc=$?
eq "$out" "" "built-in gap_analysis is a skip (no output)"; yes "$rc" "skip is a 0 status"

# gap_analysis = "" is the explicit skip
set_repo '[roles]' 'gap_analysis = ""'
out="${ rd resolve gap_analysis; }"; rc=$?
eq "$out" "" 'gap_analysis="" → empty'; yes "$rc" 'gap_analysis="" is a 0 status'

# review = "" (empty string) → the primary's own pass (documented default), NOT an error
set_repo '[roles]' 'primary = "claude"' 'review = ""'
eq "${ rd resolve review; }" "claude" 'review="" → primary'

# --- `release` + `issue_author`: declared roles with no shipped consumer (#3) ------------------
# The baseline ships no /release skill on purpose — `release` names WHO would cut a release in a
# project-owned skill someone else writes. Resolution is therefore the ONLY contract the baseline
# owes it, so pin it. Validation (unknown token, list cardinality) is NOT re-tested per role: the
# resolver handles gap_analysis|review|debug|issue_author|release in ONE case arm, so the
# gap_analysis cases below already cover that arm for every key.
set_repo '[roles]' 'primary = "claude"' 'release = "codex"'
eq "${ rd resolve release; }" "codex" "explicit release wins over the primary fallback"

# "Falls back to primary" must be proven with a NON-claude primary. The built-in-default cases at
# the top can't do this (with no manifest anywhere, primary IS claude), so "falls back to primary"
# and "returns the literal string claude" are indistinguishable there. Set a gemini primary and
# assert EVERY primary-defaulting role at once — the general check, not one special-cased to the
# two roles this change happened to add.
set_repo '[roles]' 'primary = "gemini"'
for r in review debug issue_author release; do
  eq "${ rd resolve "$r"; }" "gemini" "unset $r falls back to primary (not literal claude)"
done

# --- validation: errors, and NO fall-through past an invalid higher-precedence value ---
set_repo '[roles]' 'review = []'
rd resolve review >/dev/null 2>&1; no $? "review = [] is rejected (nonzero)"
err="$(rd resolve review 2>&1 >/dev/null)"; has "$err" "[]" "review = [] error explains the empty array"

# repo review=[] must NOT silently fall through to a valid global review
set_global '[roles]' 'review = ["claude"]'
rd resolve review >/dev/null 2>&1; no $? "invalid repo value does not fall through to global"
clr_global

set_repo '[roles]' 'gap_analysis = "gpt5"'
rd resolve gap_analysis >/dev/null 2>&1; no $? "unknown agent token is rejected"
err="$(rd resolve gap_analysis 2>&1 >/dev/null)"; has "$err" "gpt5" "unknown-token error names the token"

set_repo '[roles]' 'review = ["claude", "bogus"]'
rd resolve review >/dev/null 2>&1; no $? "unknown token inside a review list is rejected"

clr_repo; clr_global
rd resolve nosuchrole >/dev/null 2>&1; no $? "unknown role name is rejected"

# --- validation hardening (PR #59 Codex-connector review) ---
# primary must be a single, non-empty, exact token.
set_repo '[roles]' 'primary = []'
rd resolve primary >/dev/null 2>&1; no $? "primary = [] is rejected (not silently → claude)"
rd resolve debug   >/dev/null 2>&1; no $? "a role inheriting from an invalid primary also surfaces the error"
set_repo '[roles]' 'primary = ["claude", "gemini"]'
rd resolve primary >/dev/null 2>&1; no $? "primary = [list] is rejected (not silently first-of-list)"
set_repo '[roles]' 'primary = ""'
rd resolve primary >/dev/null 2>&1; no $? "primary = \"\" is rejected"
set_repo '[roles]' 'primary = "claude codex"'
rd resolve primary >/dev/null 2>&1; no $? "space-joined token is rejected (exact match, not substring)"
err="$(set_repo '[roles]' 'review = ["claude codex"]'; rd resolve review 2>&1 >/dev/null)"; has "$err" "unknown agent" "space-joined token inside a list is rejected"
# only review may be a list — a single-owner role given an array must surface.
set_repo '[roles]' 'gap_analysis = ["codex", "gemini"]'
rd resolve gap_analysis >/dev/null 2>&1; no $? "gap_analysis = [list] is rejected (single-owner role)"
err="$(rd resolve gap_analysis 2>&1 >/dev/null)"; has "$err" "single agent" "non-review array error explains single-owner cardinality"
set_repo '[roles]' 'debug = ["claude"]'
rd resolve debug >/dev/null 2>&1; no $? "debug = [list] is rejected (single-owner role)"

# ============================ bots ============================
clr_repo; clr_global
b="${ rd bots; }"
has "$b" "chatgpt-codex-connector" "default bot allowlist includes the Codex connector"
has "$b" "copilot[bot]"            "default bot allowlist includes copilot[bot]"
has "$b" "claude-code[bot]"        "default bot allowlist includes claude-code[bot]"

set_repo '[reviewers]' 'bots = ["chatgpt-codex-connector", "my-bot[bot]"]'
eq "${ rd bots | tr '\n' ','; }" "chatgpt-codex-connector,my-bot[bot]," "[reviewers] bots override is authoritative"

set_repo '[reviewers]' 'bots = []'
out="${ rd bots; }"; rc=$?
eq "$out" "" "bots = [] disables (empty output)"; yes "$rc" "bots = [] is a 0 status"

# a non-array bots value is malformed — rejected, NOT mistaken for the [] disable
set_repo '[reviewers]' 'bots = "my-bot[bot]"'
rd bots >/dev/null 2>&1; no $? "scalar [reviewers].bots is rejected (not treated as disabled)"

# ---- bots --declared : the same key read as a TRI-STATE, with NO default (#134) ---------------
# The pre-arm review guard needs the opposite answer from /resolve-pr-threads for "unset": a
# default is harmless when deciding which threads to auto-resolve, and is exactly wrong when
# deciding whether to WAIT for a reviewer. So this reader must never fall back to the built-in
# set — a default would either make every repo wait for eight bots it does not have, or arm
# auto-merge on a repo that does have one, which is #134 itself.
set_repo '[reviewers]' 'bots = ["chatgpt-codex-connector"]'
clr_global
out="${ rd bots --declared; }"; rc=$?
eq "$out" "chatgpt-codex-connector" "bots --declared returns the declared logins"
yes "$rc" "a declared non-empty list is a 0 status"

set_repo '[reviewers]' 'bots = []'
out="${ rd bots --declared; }"; rc=$?
eq "$out" "" "bots --declared: [] is declared-and-empty (no async reviewer)"
yes "$rc" "declared [] is a 0 status — distinct from undeclared"

clr_repo; clr_global
out="${ rd bots --declared 2>/dev/null; }"; rc=$?
eq "$out" "" "bots --declared prints nothing when undeclared"
eq "$rc" "3" "UNDECLARED is its own status (3), never the built-in default set"
# The contrast that matters: the SAME state yields the default allowlist for /resolve-pr-threads.
has "${ rd bots; }" "chatgpt-codex-connector" "undeclared still yields the DEFAULT set for the plain 'bots' reader"

# global-only declaration still counts as declared (the layering is repo -> global)
clr_repo; set_global '[reviewers]' 'bots = ["my-bot[bot]"]'
out="${ rd bots --declared; }"; rc=$?
eq "$out" "my-bot[bot]" "a GLOBAL declaration counts as declared"
yes "$rc" "global declaration is a 0 status"
clr_global

set_repo '[reviewers]' 'bots = "my-bot[bot]"'
rd bots --declared >/dev/null 2>&1
eq "$?" "2" "malformed [reviewers].bots is 2 under --declared (never confused with 3 or [])"

rd bots --bogus >/dev/null 2>&1; eq "$?" "2" "an unknown bots flag is rejected"

# ---- bots --comparable : the same key normalized for MATCHING (#173) --------------------------
# pr-review.sh and pr-watch.sh each carried this normalization, the status mapping, and the
# "declared something unusable" rejection — ~13 duplicated lines whose whole job is to decide who
# must review before a merge is armed. One home, here, beside the manifest reader it wraps.
clr_repo; clr_global
set_repo '[reviewers]' 'bots = ["Chatgpt-Codex-Connector", "MY-BOT[BOT]", "chatgpt-codex-connector"]'
out="${ rd bots --comparable; }"; rc=$?
yes "$rc" "bots --comparable is a 0 status for a usable declaration"
eq "${ printf '%s' "$out" | tr '\n' ','; }" "chatgpt-codex-connector,my-bot[bot]" \
   "bots --comparable lowercases and de-duplicates"

# THE SUFFIX IS NO LONGER STRIPPED FROM THE DECLARATION, and that is the #176 fix: stripping it meant
# `bots = ["foo[bot]"]` was satisfied by a HUMAN account named `foo`. The suffix now survives into the
# comparison form, where the asymmetric matcher (common.sh) treats it as "this App, exactly".
set_repo '[reviewers]' 'bots = ["foo[bot]"]'
eq "${ rd bots --comparable; }" "foo[bot]" "bots --comparable PRESERVES a declared '[bot]' suffix"

# BOTH SPELLINGS OF ONE ACCOUNT ARE ONE REVIEWER. The arming guard requires EVERY declared login to
# have reviewed, so keeping both would make one account two independent requirements — and because a
# bare `foo` matches either spelling while `foo[bot]` matches only the suffixed one, an account
# reported bare could never satisfy both and the guard would wedge at "awaiting review" for good.
# Declaring both used to be harmless and the old docs suggested it, so real manifests carry it.
set_repo '[reviewers]' 'bots = ["foo", "foo[bot]"]'
eq "${ rd bots --comparable | tr '\n' ','; }" "foo," \
   "bots --comparable: a declared 'foo[bot]' is subsumed by a declared 'foo'"
# ...and the suffixed entry survives on its own, where it is the operator's strict choice.
set_repo '[reviewers]' 'bots = ["foo[bot]", "bar"]'
eq "${ rd bots --comparable | tr '\n' ','; }" "bar,foo[bot]," \
   "bots --comparable: an unpaired '[bot]' entry is preserved"
# Subsumption is per-account, not global — an unrelated suffixed login is untouched.
set_repo '[reviewers]' 'bots = ["foo", "foo[bot]", "baz[bot]"]'
eq "${ rd bots --comparable | tr '\n' ','; }" "baz[bot],foo," \
   "bots --comparable: subsumption applies only to the matching bare login"

set_repo '[reviewers]' 'bots = []'
out="${ rd bots --comparable; }"; rc=$?
eq "$out" "" "bots --comparable: [] is the empty set, not an error"
yes "$rc" "declared [] is a 0 status under --comparable too"

clr_repo; clr_global
rd bots --comparable >/dev/null 2>&1
eq "$?" "17" "UNDECLARED is 17 under --comparable (the two guards' shared 'fail closed' code)"

set_repo '[reviewers]' 'bots = "my-bot[bot]"'
rd bots --comparable >/dev/null 2>&1
eq "$?" "18" "a malformed declaration is 18 under --comparable (a config remedy, not a retry)"

# A declaration that survives the reader but normalizes to NOTHING is malformed, not the `[]` disable.
# The operator declared SOMETHING, and downgrading that to "no reviewers" would arm auto-merge off the
# back of a typo — the fail-open direction, from the input that looks most like a real declaration.
set_repo '[reviewers]' 'bots = ["[bot]"]'
rd bots --comparable >/dev/null 2>&1
eq "$?" "18" "a declaration that normalizes to nothing is 18, never the [] disable"

# AN ENTRY WITH EMBEDDED WHITESPACE IS REJECTED WHOLESALE, NOT DROPPED. A GitHub login is
# alphanumerics and hyphens (plus an optional `[bot]` suffix), so `"foo bar"` can never name a real
# account. DROPPING just the bad entry is the fail-OPEN choice: with two declared, discarding one
# SHRINKS the set every consumer must satisfy, and the guards would then arm — or report a clean
# pass — on the remaining reviewer alone. It also protects the `<login> <class>` line grammar the
# reviewer-evidence classifier emits (#167), which a space would split across.
set_repo '[reviewers]' 'bots = ["foo bar"]'
rd bots --comparable >/dev/null 2>&1
eq "$?" "18" "an entry with embedded whitespace is 18 (a config remedy)"
set_repo '[reviewers]' 'bots = ["good-bot", "foo bar"]'
rd bots --comparable >/dev/null 2>&1
eq "$?" "18" "...and it rejects the WHOLE declaration rather than silently shrinking the set"
# ...while an ordinary declaration is untouched by the new check.
set_repo '[reviewers]' 'bots = ["good-bot", "other-bot[bot]"]'
eq "${ rd bots --comparable 2>/dev/null | tr '\n' ' '; }" "good-bot other-bot[bot] " \
   "a well-formed multi-entry declaration still passes through unchanged"

# THE TRI-STATE READER'S OWN CONTRACT MUST NOT MOVE. `adb_dispatch_bots` maps the reader's statuses,
# so teaching the reader to return 18 would change what the DEFAULT reader does — and that reader
# decides which threads /resolve-pr-threads may auto-resolve. That is why --comparable is a wrapper
# rather than a flag on the reader.
set_repo '[reviewers]' 'bots = "my-bot[bot]"'
rd bots --declared >/dev/null 2>&1
eq "$?" "2" "--comparable's 17/18 did not leak into --declared's 0/2/3 contract"
rd bots >/dev/null 2>&1
eq "$?" "2" "a malformed declaration is still REJECTED by the plain reader, not defaulted"

# ...and the mapping is EXHAUSTIVE, which it was not. It read "2 is malformed, 0 is authoritative,
# anything else means unset — emit the defaults", so ANY future status from the reader would have
# silently become the permissive built-in allowlist. Only 3 means "not declared anywhere". Asserted by
# sourcing the library and overriding the reader, because no manifest can produce an unexpected status
# — which is exactly why the arm was easy to get wrong and impossible to notice.
clr_repo; clr_global
_unexpected="$( cd "$REPO" && HOME="$GHOME" bash -c '
  . "$1" 2>/dev/null
  adb_dispatch_bots_declared() { return 9; }
  adb_dispatch_bots >/dev/null 2>&1; echo $?' _ "$RD" )"
eq "$_unexpected" "9" "an UNEXPECTED reader status is refused, never defaulted to the built-in allowlist"
_undeclared="$( cd "$REPO" && HOME="$GHOME" bash -c '
  . "$1" 2>/dev/null
  adb_dispatch_bots_declared() { return 3; }
  adb_dispatch_bots 2>/dev/null | grep -c .' _ "$RD" )"
if [ "$_undeclared" -gt 0 ]; then ok; else bad "status 3 (undeclared) must still yield the default allowlist"; fi
clr_repo; clr_global

# ============================ invoke (PATH-stubbed agents) ============================
# codex stub: capture the prompt from stdin and REFLECT it into --output-last-message (so the
# test proves the prompt actually reached codex — the watchdog-stdin bug), while streaming noise
# to stdout that the helper must route to stderr (#8).
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do case "$prev" in --output-last-message) out="$a" ;; esac; prev="$a"; done
in="$(cat)"
echo "EXPLORATION NOISE — must not reach captured stdout"
[ -n "$out" ] && printf 'RECEIVED:%s\nVERDICT: proceed\n' "$in" > "$out"
exit 0
EOF
chmod +x "$BIN/codex"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
p=""; prev=""; for a in "$@"; do case "$prev" in -p) p="$a" ;; esac; prev="$a"; done
printf 'CLAUDE:%s\n' "$p"
EOF
chmod +x "$BIN/claude"
cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
p=""; prev=""; for a in "$@"; do case "$prev" in -p) p="$a" ;; esac; prev="$a"; done
printf 'GEMINI:%s\n' "$p"
EOF
chmod +x "$BIN/agy"

set_repo '[roles]' 'primary = "claude"' 'gap_analysis = "codex"' 'review = ["claude", "gemini"]'

# codex: stdout is the CLEAN final message; noise is on stderr, not stdout; and the prompt
# reached codex on stdin (default path — GNU timeout on CI).
out="${ printf 'do gap analysis' | rd invoke gap_analysis 2>/dev/null; }"; rc=$?
yes "$rc" "invoke gap_analysis (codex) succeeds"
eq "$out" "${ printf 'RECEIVED:do gap analysis\nVERDICT: proceed'; }" "codex invoke returns ONLY the final message AND the prompt reached codex"
err="$(printf 'x' | rd invoke gap_analysis 2>&1 >/dev/null)"
has "$err" "EXPLORATION NOISE" "codex exploration stream is routed to stderr"
hasnt "$out" "EXPLORATION NOISE" "codex exploration noise never contaminates stdout"
# REGRESSION (watchdog stdin bug): the portable watchdog path must ALSO deliver the prompt on
# stdin, not /dev/null. Before the `<&0` fix this returned "RECEIVED:" (empty).
outw="${ printf 'watchdog-prompt' | ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" ADB_DISPATCH_NO_TIMEOUT_BIN=1 bash "$RD" invoke gap_analysis 2>/dev/null ); }"
has "$outw" "RECEIVED:watchdog-prompt" "watchdog path delivers the prompt on stdin (not /dev/null)"

# explicit agent tokens invoke directly
eq "${ printf 'review it' | rd invoke claude 2>/dev/null; }" "CLAUDE:review it" "invoke <claude> runs claude -p"
eq "${ printf 'review it' | rd invoke gemini 2>/dev/null; }" "GEMINI:review it" "invoke <gemini> runs agy -p"

# a multi-agent role is refused (use resolve + per-slot invoke)
printf 'x' | rd invoke review >/dev/null 2>&1; no $? "invoke of a multi-agent role is refused"
err="$(printf 'x' | rd invoke review 2>&1 >/dev/null)"; has "$err" "multiple agents" "multi-agent refusal explains why"

# unassigned role → exit 3 (distinct from a completed empty result)
set_repo '[roles]' 'gap_analysis = ""'
printf 'x' | rd invoke gap_analysis >/dev/null 2>&1; eq "$?" "3" "invoke of an unassigned role returns 3"

# codex exits 0 but writes NO final message → treated as incomplete (nonzero), not a clean pass
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo "noise only"; exit 0
EOF
chmod +x "$BIN/codex"
set_repo '[roles]' 'gap_analysis = "codex"'
printf 'x' | rd invoke gap_analysis >/dev/null 2>&1; no $? "codex 0-exit with no final message is incomplete"

# timeout: a codex that outlives the bound returns 124 (via timeout binary or the watchdog)
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; sleep 2; exit 0
EOF
chmod +x "$BIN/codex"
# Run the helper under the fixture with extra leading env assignments: `rd_env VAR=1 ... <args>`.
# The fixture's environment contract (cwd + HOME + PATH) already lives in `rd()`; without this the
# new bound/escalation cases each re-spell it, so adding one fixture variable would be a six-site
# edit. `env` rather than bare assignments on `rd` — in bash a prefix assignment on a FUNCTION call
# persists after it returns and would leak into later assertions.
rd_env() { ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" env "$@" ); }

# ONE dispatch feeds both the rc and the stderr assertion — re-running a 1-second timeout purely to
# capture the other stream doubles the wall-clock cost of a test whose cost IS the sleep.
err="$(printf 'x' | rd_env ADB_DISPATCH_TIMEOUT_SECS=1 bash "$RD" invoke gap_analysis 2>&1 >/dev/null)"; out_rc=$?
eq "$out_rc" "124" "invoke enforces the timeout (rc 124)"
has "$err" "backstop" "a timed-out dispatch reports the classified reason on stderr"
has "$err" "gap_analysis" "the report names the ROLE, not just the resolved agent"
has "$err" "does NOT fall back" "a failed gap_analysis states its no-substitution policy inline"
# force the portable watchdog path (no timeout binary) and confirm it also fires
out_rc=0; printf 'x' | rd_env ADB_DISPATCH_TIMEOUT_SECS=1 ADB_DISPATCH_NO_TIMEOUT_BIN=1 bash "$RD" invoke gap_analysis >/dev/null 2>&1 || out_rc=$?
eq "$out_rc" "124" "the bash watchdog fallback also enforces the timeout"

# --- the committed DEFAULT bound (#93) ---------------------------------------
# The bound that matters is the one a fresh clone gets with NO environment set. Every timeout
# assertion above passes ADB_DISPATCH_TIMEOUT_SECS explicitly, so all of them would still pass
# with the default back at its old too-small value — which is exactly the regression that cost
# three runs. Pin the default itself, from the library rather than a copy of the number.
# `env -u` is load-bearing: without it this subshell inherits the very variable whose ABSENCE it
# asserts, so a contributor who exports the knob the docs now advertise gets a red selfcheck
# blaming the committed default.
# Usage: rd_var <VAR-to-print> [ENV=VAL ...]  — the var name FIRST, so it is never mistaken for
# the command `env` should exec.
# NOTE the `rd_var` arg0: the library must NOT be passed as $0. Its "executed directly, never when
# sourced" guard compares BASH_SOURCE[0] to $0, so `bash -c '. "$0"' "$RD"` makes them equal, trips
# the CLI dispatch, and exits 2 before printing anything.
rd_var() { local v="$1"; shift
  env -u ADB_DISPATCH_TIMEOUT_SECS -u ADB_DISPATCH_KILL_GRACE_SECS -u ADB_DISPATCH_NO_TIMEOUT_BIN \
    -u ADB_DISPATCH_LOG_MAX_BYTES \
    "$@" bash -c '. "$1" >/dev/null 2>&1; printf %s "${!2:-unset}"' rd_var "$RD" "$v"; }
eq "${ rd_var _ADB_RD_TIMEOUT_SECS; }" "2700" "the no-environment default bound is 2700s (45-min hang backstop)"
eq "${ rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=99; }" "99" "ADB_DISPATCH_TIMEOUT_SECS still overrides the default"
eq "${ rd_var _ADB_RD_KILL_GRACE_SECS; }" "10" "the no-environment kill grace is 10s"
# Both degenerate grace values are clamped: `timeout -k 0` means "no SIGKILL at all" to GNU
# timeout (so a 0 grace would leave the binary path with NO escalation while the watchdog path
# kills immediately), and a non-numeric value makes timeout exit 125 — which would classify as
# "a real agent error" and send the reader hunting a codex bug that isn't there.
eq "${ rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=0; }" "1"  "a 0 kill grace is clamped to 1 (never 'no escalation')"
eq "${ rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=x; }" "10" "a non-numeric kill grace falls back to the default"
eq "${ rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=3; }" "3"  "a valid kill grace is honored"
# The bound is compared arithmetically (the 137->124 normalization) and counted down by the
# portable watchdog, both integer-only — so a fractional override that `timeout` would happily
# accept produced `[: 0.5: integer expression expected` and fired the bound instantly, failing
# every dispatch at once. Reject it loudly instead (bot review, PR #105).
eq "${ rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=0.5 2>/dev/null; }" "2700" "a fractional bound falls back to the default rather than breaking every dispatch"
eq "${ rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=0   2>/dev/null; }" "2700" "a zero bound falls back to the default"
eq "${ rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=abc 2>/dev/null; }" "2700" "a non-numeric bound falls back to the default"
# NOT via rd_var: it silences the sourcing's stderr, which is exactly the stream under test here.
frac_err="$(ADB_DISPATCH_TIMEOUT_SECS=0.5 bash -c '. "$1" >/dev/null' rd_var "$RD" 2>&1)"
has "$frac_err" "not a positive whole number" "a rejected bound says so on stderr rather than failing silently"

# --- failure-mode classification (#93) ---------------------------------------
# 124 (our backstop) / 143 (an OUTER bound) / a real agent error each need a different response;
# collapsing them into "the agent failed" is what let a bound problem masquerade as a codex
# problem. Assert each rc maps to a DISTINCT, self-explaining classification.
# ONE subshell sources the library and precomputes every classification. Re-sourcing per assertion
# also re-forks `git rev-parse` (via adb_repo_root at load), so seven lookups cost seven loads.
# shellcheck source=/dev/null
_cls_all="$( . "$RD" >/dev/null 2>&1; for r in 0 7 124 137 143; do printf '%s|%s\n' "$r" "$(adb_dispatch_classify_rc "$r")"; done )"
cls() { printf '%s\n' "$_cls_all" | grep "^$1|" | cut -d'|' -f2-; }
has "${ cls 124; }" "backstop"     "rc 124 is classified as our own hang backstop"
has "${ cls 124; }" "ADB_DISPATCH_TIMEOUT_SECS" "the 124 classification names the override knob"
has "${ cls 143; }" "OUTER"        "rc 143 is classified as an OUTER bound, not ours"
has "${ cls 137; }" "outside"      "rc 137 is classified as an external kill"
has "${ cls 7; }"   "real agent"   "an arbitrary nonzero rc is classified as a real agent error"
hasnt "${ cls 7; }" "backstop"     "a real agent error is NOT blamed on our backstop"
eq "${ cls 0; }" "completed"       "rc 0 is classified as completed"

# --- the backstop must actually terminate (#93) ------------------------------
# A backstop that only sends SIGTERM is not a backstop: a child that traps TERM leaves `wait`
# blocking forever. Harmless when the bound was minutes and an outer harness cap sat above it —
# an unbounded deadlock now that the bound is 45 min and background dispatch removes that cap.
# This codex TRAPS SIGTERM and keeps running; the run must still come back, via KILL escalation.
# Two TERM-resistant stubs: one that IGNORES TERM outright, and one that TRAPS it and exits 0 —
# ordinary well-behaved-CLI cleanup, and the case that a verdict gated on the child's exit status
# (rather than on "did the bound fire") silently reports as a clean pass carrying truncated output.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
cat >/dev/null; sleep 30; exit 0
EOF
chmod +x "$BIN/codex"
cat > "$BIN/codex-trap0" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
cat >/dev/null; sleep 30; exit 0
EOF
chmod +x "$BIN/codex-trap0"
# The two paths (hand-rolled watchdog vs `timeout -k`) are genuinely different code and both need
# covering — but each is a fixed ~2s wait, and this sleep is the ONLY material cost this suite
# adds to every pre-push selfcheck. So run them CONCURRENTLY (they share only a read-only stub)
# and keep the grace at its floor of 1: the child TRAPS TERM, so the grace is a fixed wait rather
# than a race and a short one cannot flake. Sequential at the default grace, these cost ~6s; this
# way, ~2s.
# The outer-termination probe rides this same concurrent window rather than adding its own serial
# ~3s: when an OUTER bound kills OUR shell mid-dispatch (a harness foreground cap, a cancelled
# detached job), the agent must not be reparented to init and left running out the full 45-minute
# backstop. Verified pre-fix to leak the `timeout` process AND the agent under it (bot review, PR
# #105). The stub name is written into a FILE, never a live command line, so the `ps` probe cannot
# match the harness's own argv and self-report a false positive.
printf '#!/usr/bin/env bash\nsleep 300\n' > "$work/qqstub"; chmod +x "$work/qqstub"
{ printf '. "%s"\n' "$RD"; printf '_adb_rd_bounded 2700 "%s/qqstub"\n' "$work"; } > "$work/probe.sh"

esc_w="$(mktemp)"; esc_t="$(mktemp)"; esc_0="$(mktemp)"; start=$SECONDS
# A BARE `timeout` is GNU-only. On a stock Mac it is absent, the subshell exits 127, the bare `wait`
# below discards that status, and the zero-process assertion then passes because nothing was ever
# STARTED — a probe reporting a clean run while exercising nothing. Invisible until #257 first ran
# this suite on macOS. Line 484 below already resolves timeout-or-gtimeout; this now agrees with it,
# and says so out loud when neither exists rather than silently proving nothing.
OUTER_TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
if [ -n "$OUTER_TIMEOUT" ]; then
  ( "$OUTER_TIMEOUT" 2 bash "$work/probe.sh" >/dev/null 2>&1 ) &
else
  echo "check-role-dispatch: NOTE — no timeout/gtimeout binary; outer-termination probe not exercised" >&2
fi
( rc=0; printf 'x' | rd_env ADB_DISPATCH_TIMEOUT_SECS=1 ADB_DISPATCH_KILL_GRACE_SECS=1 ADB_DISPATCH_NO_TIMEOUT_BIN=1 \
    bash "$RD" invoke gap_analysis >/dev/null 2>&1 || rc=$?; printf '%s' "$rc" > "$esc_w" ) &
( rc=0; printf 'x' | rd_env ADB_DISPATCH_TIMEOUT_SECS=1 ADB_DISPATCH_KILL_GRACE_SECS=1 \
    bash "$RD" invoke gap_analysis >/dev/null 2>&1 || rc=$?; printf '%s' "$rc" > "$esc_t" ) &
( cp "$BIN/codex-trap0" "$BIN2/codex"
  rc=0; printf 'x' | ( cd "$REPO" && HOME="$GHOME" PATH="$BIN2:$PATH" env \
    ADB_DISPATCH_TIMEOUT_SECS=1 ADB_DISPATCH_KILL_GRACE_SECS=1 ADB_DISPATCH_NO_TIMEOUT_BIN=1 \
    bash "$RD" invoke gap_analysis >/dev/null 2>&1 ) || rc=$?; printf '%s' "$rc" > "$esc_0" ) &
wait
elapsed=$(( SECONDS - start ))
eq "$(cat "$esc_w")" "124" "watchdog: a TERM-resistant child still returns 124 (escalates to KILL)"
# REGRESSION: gating the verdict on the child's exit status made this return 0 with truncated
# output — a killed run accepted as a clean pass, the exact silent-incompleteness class #93 exists
# to remove. GNU timeout returns 124 here too, so this also keeps the paths agreeing by platform.
eq "$(cat "$esc_0")" "124" "a TERM-trapping child that exits 0 is still reported as timed out"
# Only a distinct assertion when a timeout binary actually exists; without one this second case
# takes the watchdog path too and would just re-assert the line above.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  eq "$(cat "$esc_t")" "124" "timeout -k: a TERM-resistant child still returns 124, not 137"
fi
rm -f "$esc_w" "$esc_t" "$esc_0"
if [ "$elapsed" -lt 15 ]; then
  ok "escalation returns promptly instead of hanging (${elapsed}s vs the child's 30s sleep)"
else
  bad "a TERM-resistant child hung the backstop (${elapsed}s)"
fi

# The watchdog must not leak its `sleep` when the child finishes early. Killing the watcher does
# NOT take an already-forked sleep with it — it is reparented to init and runs to term — so a
# single `sleep "$secs"` orphans one process per dispatch, each living the FULL bound. At the old
# 7-minute default that was untidy; at 45 minutes it is a pile of half-hour zombies (15 were found
# on the author's machine from one day's runs). The watchdog ticks instead, so the only sleep that
# can outlive it is one tick long — and never one matching the bound.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; printf 'VERDICT: quick\n'; exit 0
EOF
chmod +x "$BIN/codex"
printf 'x' | rd_env ADB_DISPATCH_TIMEOUT_SECS=31337 ADB_DISPATCH_NO_TIMEOUT_BIN=1 \
  bash "$RD" invoke gap_analysis >/dev/null 2>&1
eq "$(pgrep -f 'sleep 31337' 2>/dev/null | grep -c . | tr -d ' ')" "0" \
  "the watchdog leaves no orphaned bound-length sleep behind after a fast child"

# When an OUTER bound kills OUR shell mid-dispatch (a harness foreground cap, a cancelled detached
# job), the agent must not be reparented to init and left running out the full backstop — 45
# minutes of agent work after the run was cancelled. Verified pre-fix to leak the `timeout` process
# AND the agent under it (bot review, PR #105). The stub name is written into a FILE, never a live
# command line, so the `ps` probe cannot match the test harness's own argv and self-report.
#
# GATED ON THE PROBE HAVING RUN. With no timeout binary the probe above never starts, and "zero
# qqstub processes" is then trivially true — a green assertion for a scenario that was never
# staged. Counting that as a pass is the silent-guard failure this repo keeps paying for, so it is
# reported as not-exercised instead.
if [ -n "$OUTER_TIMEOUT" ]; then
  eq "$(ps -eo command | grep -c '[q]qstub' | tr -d ' ')" "0" \
    "an outer termination reaps the dispatched agent instead of orphaning it for the full bound"
else
  echo "check-role-dispatch: NOTE — outer-termination reaping not asserted (no timeout binary)" >&2
fi
pkill -f '[q]qstub' >/dev/null 2>&1 || true

# ==================== the captured log stream is BOUNDED (#141) ====================
# The dispatched agent's exploration stream is routed to this helper's stderr, and the workflow
# redirects that into `gaps.err` / `review.err`. Nothing capped it: one gap-analysis run wrote
# 674 KB, and the run that implemented THIS issue wrote 766 KB. /cleanup sweeps those artifacts
# BETWEEN runs (#84); a SINGLE run's stream is what these cases pin.
#
# A noisy stub, sized well past the caps used below so every case is genuinely over the line.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
last=""
while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { last="$2"; shift; }; shift; done
cat >/dev/null
i=0; while [ "$i" -lt 4000 ]; do printf 'exploring %05d wwwwwwwwwwwwwwwwwwwwwwwwwww\n' "$i"; i=$(( i + 1 )); done
printf 'and some stderr noise\n' >&2
[ -n "$last" ] && printf 'VERDICT: fine\n' > "$last"
exit 0
EOF
chmod +x "$BIN/codex"
set_repo '[roles]' 'gap_analysis = "codex"'

# The uncapped size, measured rather than assumed — every bound below is compared against THIS, so
# a stub that quietly stopped being noisy would otherwise make the whole section vacuously green.
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=0 bash "$RD" invoke gap_analysis \
  >/dev/null 2>"$work/uncapped.err"
uncapped="$(wc -c < "$work/uncapped.err" | tr -d ' ')"
if [ "$uncapped" -gt 100000 ]; then ok; else bad "the noisy stub must produce a genuinely large stream (got $uncapped bytes)"; fi

# THE CAP HOLDS. The bound is the cap plus this helper's OWN lines, which are deliberately outside
# it — see the assertion two blocks down for why — so the comparison allows a small fixed margin
# and nothing like the 100 KB+ the stream would otherwise carry.
out="$(printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=1000 bash "$RD" invoke gap_analysis 2>"$work/capped.err")"
capped="$(wc -c < "$work/capped.err" | tr -d ' ')"
if [ "$capped" -lt 2000 ]; then ok; else bad "the log stream was not capped (got $capped bytes, cap was 1000)"; fi
has "$(cat "$work/capped.err")" "capped at" "a capped stream SAYS it was capped, rather than truncating silently"
has "$(cat "$work/capped.err")" "HEAD cap" "the notice states which END of the stream is missing"

# THE RESULT IS NOT THE LOG. codex's final message arrives via --output-last-message, and capping
# a result would be data loss rather than tidying. Asserted at the smallest cap used here, where a
# leak into stdout would be unmistakable.
eq "$out" "VERDICT: fine" "the agent's final message survives the cap untouched"

# 0 DISABLES it. Without this, a value of 0 could just as easily read as "cap at zero bytes", which
# would discard the whole stream — the opposite of the escape hatch an operator reaches for. So the
# assertion is that the 0 run kept EVERYTHING the capped run threw away, and emitted no notice.
# (Written against the CAPPED run rather than re-measuring `uncapped.err`: comparing that file to
# the variable read from it is a tautology, which is a guard that cannot answer wrong.)
if [ "$uncapped" -gt "$(( capped * 50 ))" ]; then ok
else bad "ADB_DISPATCH_LOG_MAX_BYTES=0 must leave the stream unbounded ($uncapped vs capped $capped)"; fi
hasnt "$(cat "$work/uncapped.err")" "capped at" "a disabled cap emits no truncation notice at all"

# THE DISCARD COUNT IS EXACT, not an estimate. This is the whole reason the filter is awk and not
# `head -c` + a drain: `head` over-reads into its buffer, so it loses an unknown number of bytes
# AND can swallow the entire remainder — leaving the drain to see EOF and report a clean pass on a
# stream it silently truncated. kept + discarded must reconstruct the uncapped size exactly.
kept="$(sed -n 's/.*capped at \([0-9][0-9]*\) bytes (ADB.*/\1/p' "$work/capped.err")"
gone="$(sed -n 's/.*remaining \([0-9][0-9]*\) bytes were discarded.*/\1/p' "$work/capped.err")"
if [ -n "$kept" ] && [ -n "$gone" ] && [ "$(( kept + gone ))" -eq "$uncapped" ]; then ok
else bad "kept + discarded must equal the uncapped size ($kept + $gone != $uncapped)"; fi

# A CAPPED STREAM MUST NOT SWALLOW THE DIAGNOSIS. `/implement-issue` is told to read the classified
# line at the TAIL of gaps.err, so this helper's own lines are emitted OUTSIDE the cap and must
# still arrive — and arrive last. They are O(1); the agent's stream is the unbounded thing. A cap
# that included them would bound the file at the cost of deleting the one line that says why the
# dispatch failed.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
i=0; while [ "$i" -lt 4000 ]; do printf 'exploring %05d wwwwwwwwwwwwwwwwwwwwwwwwwww\n' "$i"; i=$(( i + 1 )); done
sleep 20
EOF
chmod +x "$BIN/codex"
out_rc=0
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=500 ADB_DISPATCH_TIMEOUT_SECS=1 \
  ADB_DISPATCH_KILL_GRACE_SECS=1 bash "$RD" invoke gap_analysis >/dev/null 2>"$work/late.err" || out_rc=$?
eq "$out_rc" "124" "the bound still fires through the cap"
has "$(tail -1 "$work/late.err")" "does NOT fall back" "the classified line is the LAST thing on stderr, after the cap notice"
has "$(cat "$work/late.err")" "backstop" "the failure classification survives a capped stream"
# ...and on the portable watchdog path too, which is where the process-group half of #141 landed.
out_rc=0
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=500 ADB_DISPATCH_TIMEOUT_SECS=1 \
  ADB_DISPATCH_KILL_GRACE_SECS=1 ADB_DISPATCH_NO_TIMEOUT_BIN=1 bash "$RD" invoke gap_analysis \
  >/dev/null 2>"$work/late2.err" || out_rc=$?
eq "$out_rc" "124" "the watchdog path also bounds and caps together"
has "$(tail -1 "$work/late2.err")" "does NOT fall back" "watchdog path: the classified line still arrives last"

# WHAT SURVIVES MUST BE THE INPUT'S PREFIX. Every assertion above is satisfied by a filter that
# throws the whole stream away and prints the hard-coded notice: the size is small, the notice is
# present, and `kept + dropped` still adds up if `kept` is 0. So the bytes themselves are checked —
# a HEAD cap that does not retain the head is not the thing this change claims to have built.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
last=""
while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { last="$2"; shift; }; shift; done
cat >/dev/null
printf 'FIRSTLINE-provenance-header\n'
printf 'SECONDLINE-model-and-effort\n'
printf 'NULBEFORE\000NULAFTER\n'            # a NUL mid-stream: BSD awk treated it as end-of-string
printf 'crlf-line\r\n'
i=0; while [ "$i" -lt 4000 ]; do printf 'noise %05d qqqqqqqqqqqqqqqq\n' "$i"; i=$(( i + 1 )); done
printf 'TAILMARKER-must-not-survive-a-head-cap\n'
[ -n "$last" ] && printf 'VERDICT: fine\n' > "$last"
exit 0
EOF
chmod +x "$BIN/codex"
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=120 bash "$RD" invoke gap_analysis \
  >/dev/null 2>"$work/prefix.err"
has   "$(head -1 "$work/prefix.err")" "FIRSTLINE-provenance-header" "the cap keeps the HEAD of the stream (the provenance header)"
hasnt "$(cat  "$work/prefix.err")"    "TAILMARKER"                  "...and drops the tail, which is what a head cap means"
# A NUL must not silently end the stream. BSD awk treats it as a string terminator, so before
# `tr -d` this dropped everything after it AND emitted no notice — a truncated log indistinguishable
# from a complete one, on macOS only. The bytes AROUND the NUL must still come through.
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=100000 bash "$RD" invoke gap_analysis \
  >/dev/null 2>"$work/nul.err"
has "$(cat "$work/nul.err")" "NULAFTER" "a NUL byte does not truncate the stream (what killed the awk filter)"
has "$(cat "$work/nul.err")" "crlf-line" "a CRLF line survives the filter"
has "$(cat "$work/nul.err")" "capped at" "a stream past the cap still reports it even after a NUL"

# A stream with NO newline before the cap must still yield its first `max` bytes. Record-granular
# capping returned ZERO bytes here — bounded, but throwing away the very head the cap exists to
# keep, and reporting "capped at 0 bytes".
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
i=0; while [ "$i" -lt 400 ]; do printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; i=$(( i + 1 )); done
printf '\n'
exit 0
EOF
chmod +x "$BIN/codex"
printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=64 bash "$RD" invoke gap_analysis \
  >/dev/null 2>"$work/oneline.err"
has "$(head -c 64 "$work/oneline.err")" "AAAAAAAAAA" "a newline-free stream is still cut AT the cap, not discarded whole"

# A DESCENDANT THE AGENT LEFT BEHIND MUST NOT HANG THE DISPATCH. Closing our write end is not the
# same as closing the pipe: a background process that inherited the agent's stdout/stderr still
# holds it, so the filter never sees EOF. An unbounded wait there blocks forever — and it blocks
# AFTER `adb_run_bounded` has returned, so its bound no longer applies and nothing else would ever
# stop it. This is a hang the cap would have INTRODUCED; the outer `timeout` is what proves it is
# gone, since a regression here does not fail an assertion, it wedges the suite.
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
last=""
while [ "$#" -gt 0 ]; do [ "$1" = "--output-last-message" ] && { last="$2"; shift; }; shift; done
cat >/dev/null
printf 'agent output before exiting\n'
sleep 120 &                     # inherits stdout/stderr, so it holds the log pipe open
[ -n "$last" ] && printf 'VERDICT: fine\n' > "$last"
exit 0
EOF
chmod +x "$BIN/codex"
hang_out="$(printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=100000 ADB_DISPATCH_LOG_DRAIN_SECS=2 \
  timeout 60 bash "$RD" invoke gap_analysis 2>"$work/drain.err")"; hang_rc=$?
eq "$hang_rc" "0" "a descendant holding the log pipe does not hang or fail the dispatch"
eq "$hang_out" "VERDICT: fine" "...and the agent's final message still comes back"
has "$(cat "$work/drain.err")" "still holds the log pipe open" \
    "...and the bounded drain SAYS why the log ended early rather than truncating silently"
has "$(cat "$work/drain.err")" "agent output before exiting" "...and what the agent did write is kept"
pkill -f 'sleep 120' >/dev/null 2>&1 || true

# EVERY AGENT, not just codex — the change claims the cap covers all of them, and claude/gemini
# take the OTHER arm (`log_stdout=0`), where stdout is the RESULT and only stderr is capped. With
# only a codex case, a regression in that arm stays green. `gemini` is used because its stub is a
# plain `agy` on PATH; the assertion is about the arm, not the vendor.
cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
i=0; while [ "$i" -lt 4000 ]; do printf 'gnoise %05d qqqqqqqqqqqqqqqq\n' "$i" >&2; i=$(( i + 1 )); done
printf 'GEMINI-FINAL-MESSAGE\n'
exit 0
EOF
chmod +x "$BIN/agy"
set_repo '[roles]' 'gap_analysis = "gemini"'
gout="$(printf 'x' | rd_env ADB_DISPATCH_LOG_MAX_BYTES=800 bash "$RD" invoke gap_analysis 2>"$work/gem.err")"
eq "$gout" "GEMINI-FINAL-MESSAGE" "log_stdout=0 arm: stdout is the RESULT and is never capped"
gcap="$(wc -c < "$work/gem.err" | tr -d ' ')"
if [ "$gcap" -lt 2000 ]; then ok; else bad "log_stdout=0 arm: stderr must still be capped (got $gcap bytes)"; fi
has "$(cat "$work/gem.err")" "capped at" "log_stdout=0 arm: the cap notice is emitted too"
set_repo '[roles]' 'gap_analysis = "codex"'

# The knob itself: the committed default, an override, and a rejected value that says so rather
# than silently running unbounded. Same shape as the bound/grace knobs above.
eq "${ rd_var _ADB_RD_LOG_MAX_BYTES; }" "262144" "the no-environment default log cap is 262144 bytes (256 KiB)"
eq "${ rd_var _ADB_RD_LOG_MAX_BYTES ADB_DISPATCH_LOG_MAX_BYTES=4096; }" "4096" "ADB_DISPATCH_LOG_MAX_BYTES overrides the default"
eq "${ rd_var _ADB_RD_LOG_MAX_BYTES ADB_DISPATCH_LOG_MAX_BYTES=0; }" "0" "0 is a legal value (the documented disable), not a rejected one"
eq "${ rd_var _ADB_RD_LOG_MAX_BYTES ADB_DISPATCH_LOG_MAX_BYTES=abc 2>/dev/null; }" "262144" "a non-numeric cap falls back to the default"
cap_err="$(ADB_DISPATCH_LOG_MAX_BYTES=abc bash -c '. "$1" >/dev/null' rd_var "$RD" 2>&1)"
has "$cap_err" "not a whole number of bytes" "a rejected cap says so on stderr rather than failing silently"
# All digits is NOT enough: a value past bash's integer range makes `[ "$max" -eq 0 ]` die with
# `integer expression expected`, and awk would carry the threshold through a float.
eq "${ rd_var _ADB_RD_LOG_MAX_BYTES ADB_DISPATCH_LOG_MAX_BYTES=99999999999999999999999999 2>/dev/null; }" \
   "262144" "an all-digit value outside bash's integer range is rejected, not accepted"
# ...and the complaint must not itself be unbounded. Echoing the rejected value whole put an
# arbitrarily long environment string into the very artifact this knob exists to bound.
long_err="$(ADB_DISPATCH_LOG_MAX_BYTES="$(printf 'x%.0s' $(seq 1 5000))" \
  bash -c '. "$1" >/dev/null' rd_var "$RD" 2>&1)"
if [ "${#long_err}" -lt 300 ]; then ok
else bad "the rejected-value diagnostic must be truncated, not echo an unbounded env value (${#long_err} bytes)"; fi

# ============================ effort (declared, not inherited — #225) ============================
# Two halves, and the second is the one that matters: the RESOLVER can return "medium" while the
# flag never reaches the CLI, and a bound that is not passed is indistinguishable from a bound that
# worked. So every resolver case is paired with an assertion over the agent's RECORDED ARGV.

# --- resolver -------------------------------------------------------------------------------
clr_repo; clr_global
eq "${ rd effort review; }" "medium" "built-in review effort is medium"
out="${ rd effort gap_analysis; }"; rc=$?
eq "$out" "" "gap_analysis has no built-in effort (inherit)"; eq "$rc" "1" "inherit is rc 1, not 0"
out="${ rd effort debug; }"; rc=$?; eq "$rc" "1" "a role with no default inherits"

set_repo '[roles]' 'primary = "claude"' '[roles.effort]' 'review = "low"'
eq "${ rd effort review; }" "low" "repo [roles.effort] wins over the built-in default"

clr_repo; set_global '[roles]' 'primary = "claude"' '[roles.effort]' 'review = "high"'
eq "${ rd effort review; }" "high" "global [roles.effort] applies when the repo declares none"

set_repo '[roles]' 'primary = "claude"' '[roles.effort]' 'review = "ultra"'
eq "${ rd effort review; }" "ultra" "repo beats global"

# An explicit "" is the documented escape hatch: inherit, do NOT fall through to the built-in.
set_repo '[roles]' 'primary = "claude"' '[roles.effort]' 'review = ""'
out="${ rd effort review; }"; rc=$?
eq "$out" "" 'explicit "" means inherit'; eq "$rc" "1" 'explicit "" is rc 1, not the medium default'

# An invalid value must SURFACE. Falling back to the default here would mean a typo'd manifest
# runs at a setting the operator never chose while believing it is bounded.
set_repo '[roles]' 'primary = "claude"' '[roles.effort]' 'review = "vigorous"'
out="${ rd effort review 2>/dev/null; }"; rc=$?
eq "$rc" "2" "an invalid declared effort is rc 2"

# The allowlist must track the CLI's own catalog, not a hand-written subset. `max` and `ultra` are
# real levels on the frontier models and were wrongly rejected; `minimal` is in NO bundled model's
# supported_reasoning_levels and was wrongly accepted. Both directions are pinned here so a future
# edit cannot quietly reintroduce either.
for lvl in low medium high xhigh max ultra; do
  set_repo '[roles]' 'primary = "claude"' '[roles.effort]' "review = \"$lvl\""
  eq "${ rd effort review; }" "$lvl" "the CLI's catalog level '$lvl' is accepted"
done
set_repo '[roles]' 'primary = "claude"' '[roles.effort]' 'review = "minimal"'
rd effort review >/dev/null 2>&1; eq "$?" "2" "'minimal' is rejected — no bundled model supports it"
eq "$out" "" "an invalid declared effort prints no value"
has "$(rd effort review 2>&1 >/dev/null)" "invalid [roles.effort]" "and says so on stderr"

# --- does the flag actually reach the CLI? ----------------------------------------------------
BIN3="$work/bin3"; mkdir -p "$BIN3"
ARGV="$work/effort-argv.log"
cat > "$BIN3/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ADB_ARGV_LOG"
out=""; prev=""
for a in "$@"; do case "$prev" in --output-last-message) out="$a" ;; esac; prev="$a"; done
cat >/dev/null
[ -n "$out" ] && printf 'VERDICT: proceed\n' > "$out"
exit 0
EOF
chmod +x "$BIN3/codex"
rd3() { ( cd "$REPO" && HOME="$GHOME" PATH="$BIN3:$PATH" ADB_ARGV_LOG="$ARGV" bash "$RD" "$@" ); }

# `review` must RESOLVE to codex for this to exercise anything: the built-in default falls back to
# `primary` (claude), so a bare clr_repo here would dispatch a claude slot and record no argv at
# all — which the resolver tests above cannot detect.
set_repo '[roles]' 'primary = "claude"' 'review = ["codex"]'
clr_global; : > "$ARGV"
printf 'x' | rd3 invoke review >/dev/null 2>&1
has "$(cat "$ARGV")" "model_reasoning_effort=medium" \
  "invoking the review ROLE passes the resolved effort to codex exec"

: > "$ARGV"; printf 'x' | rd3 invoke codex --effort high >/dev/null 2>&1
has "$(cat "$ARGV")" "model_reasoning_effort=high" \
  "a per-SLOT token dispatch honours an explicit --effort (the path step 8 actually uses)"

# The negative that protects every role nobody has declared an effort for: NO flag at all, so the
# agent's own config still governs and #225 changes nothing for them.
set_repo '[roles]' 'primary = "claude"' 'gap_analysis = "codex"'
: > "$ARGV"; printf 'x' | rd3 invoke gap_analysis >/dev/null 2>&1
hasnt "$(cat "$ARGV")" "model_reasoning_effort" \
  "a role with no declared effort passes NO override (pre-#225 behaviour preserved)"

# An invalid --effort must be rejected BEFORE dispatch, not discovered by the CLI mid-run.
: > "$ARGV"; rc=0; printf 'x' | rd3 invoke codex --effort bogus >/dev/null 2>&1 || rc=$?
eq "$rc" "2" "an invalid --effort exits 2"
eq "$(wc -l < "$ARGV" | tr -d ' ')" "0" "and the agent is never invoked"

clr_repo; clr_global

# ============================ available (capability probe, #211) ============================
# `available` answers a THIRD question — is this agent's CLI on PATH here? — separate from
# `resolve` (who is assigned) and an `invoke` rc (did the agent fail). Step 8 and `agent-init`
# both branch on it, so it needs its own coverage AND a proof that it agrees with dispatch.
#
# A MINIMAL PATH is what makes an "absent" assertion mean anything: the fixture's normal PATH is
# "$BIN:$PATH", so a contributor with a real claude/codex/agy installed would find the real binary
# the moment a stub is removed and every absence test would silently pass for the wrong reason.
# `rd_path <PATH> <args...>` runs the helper under an explicit PATH instead.
rd_path() { local p="$1"; shift; ( cd "$REPO" && HOME="$GHOME" PATH="$p" bash "$RD" "$@" ); }
BARE=/usr/bin:/bin
# Assert the PRECONDITION rather than assuming it. If some machine ships an agent CLI in a system
# directory, the absence cases below would be vacuous — better to fail loudly here than to pass.
_leak=0
for _t in claude codex agy; do PATH="$BARE" command -v "$_t" >/dev/null 2>&1 && _leak=1; done
if [ "$_leak" -eq 0 ]; then ok; else bad "test precondition: no agent CLI may live in $BARE"; fi

# Re-stub all three (earlier cases overwrote the codex stub with failing variants).
for _t in codex claude agy; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$_t"; chmod +x "$BIN/$_t"; done

rd_path "$BIN:$BARE" available codex  >/dev/null 2>&1; yes $? "available: a stubbed codex reports 0"
rd_path "$BIN:$BARE" available claude >/dev/null 2>&1; yes $? "available: a stubbed claude reports 0"
rd_path "$BIN:$BARE" available gemini >/dev/null 2>&1; yes $? "available: a stubbed gemini reports 0 (its CLI is agy)"
rd_path "$BARE" available codex  >/dev/null 2>&1; eq "$?" "1" "available: a known agent with no CLI reports 1"
rd_path "$BARE" available gemini >/dev/null 2>&1; eq "$?" "1" "available: gemini with no agy reports 1"
rd_path "$BIN:$BARE" available bogus  >/dev/null 2>&1; eq "$?" "2" "available: an unknown token reports 2 (not 1)"
rd_path "$BIN:$BARE" available >/dev/null 2>&1; eq "$?" "2" "available with no agent argument is a usage error"
# O3: rc alone cannot tell the usage guard from `adb_agent_cli ""` (both 2). Pin the DIAGNOSTIC too,
# or removing the guard is invisible.
has "${ rd_path "$BIN:$BARE" available 2>&1; }" "usage:" "available with no argument prints a usage diagnostic"

# SILENT: the exit code IS the answer. A ladder asking about several agents must not have to
# filter this helper's chatter out of its own report.
# BYTES, not `$(...)`. Command substitution strips trailing newlines, so a stray `printf '\n'`
# on either path would satisfy an `eq "" ` assertion while plainly violating the silent contract.
eq "${ rd_path "$BIN:$BARE" available codex 2>&1 | wc -c | tr -d ' '; }" "0" "available emits ZERO bytes when the CLI is present"
eq "${ rd_path "$BARE" available codex 2>&1 | wc -c | tr -d ' '; }" "0" "available emits ZERO bytes when the CLI is absent"

# --- THE PAIRING PROOF ---------------------------------------------------------------------
# `adb_agent_cli` names the executable and `_adb_rd_invoke_agent` runs it. If those two ever
# disagree, `available` reports an agent usable that dispatch cannot run (fail-open) or refuses one
# that works. No single-file token pin can express "these two agree", so assert it directly: with
# EXACTLY ONE agent's CLI on PATH, that agent must be the only one `available` accepts — which is
# only true if the probe is looking for the same binary name dispatch would exec.
for _pair in "codex codex" "claude claude" "gemini agy"; do
  set -- $_pair; _tok="$1"; _bin="$2"
  _only="$work/only-$_tok"; mkdir -p "$_only"
  # The stub must survive a real `invoke`, not just a `command -v`: codex is dispatched with
  # --output-last-message and a 0 exit that writes no final message is INCOMPLETE by design, so a
  # bare `exit 0` stub would fail the dispatch half for reasons unrelated to pairing.
  cat > "$_only/$_bin" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do case "$prev" in --output-last-message) out="$a" ;; esac; prev="$a"; done
cat >/dev/null 2>&1
[ -n "$out" ] && printf 'ok\n' > "$out"
exit 0
STUB
  chmod +x "$_only/$_bin"
  rd_path "$_only:$BARE" available "$_tok" >/dev/null 2>&1
  yes $? "pairing: $_tok reports available when only '$_bin' exists"
  # ...AND DISPATCH MUST AGREE. The probe half alone proved nothing about pairing: mutating
  # `_adb_rd_invoke_agent`'s executable while leaving `adb_agent_cli` alone kept this loop green,
  # which is the exact fail-open the loop is named for. With ONLY `$_bin` on PATH, `invoke` can
  # only succeed if dispatch execs that same binary — so run it and require success.
  printf 'x' | rd_path "$_only:$BARE" invoke "$_tok" >/dev/null 2>&1
  yes $? "pairing: invoke $_tok SUCCEEDS when only '$_bin' exists (dispatch execs what the probe found)"
  # ...and every OTHER token must be absent under that same PATH, so a probe that fell back to a
  # shared or hardcoded name would be caught rather than passing the positive half by luck.
  _other_ok=1
  for _o in claude codex gemini; do
    [ "$_o" = "$_tok" ] && continue
    rd_path "$_only:$BARE" available "$_o" >/dev/null 2>&1 && _other_ok=0
  done
  if [ "$_other_ok" -eq 1 ]; then ok; else bad "pairing: only '$_bin' exists, so only $_tok may report available"; fi
done

# ============================ review-rung (the ladder predicate, #211) ============================
# One predicate answers "what will actually review a diff", and BOTH /implement-issue step 8 and
# bin/agent-init consume it. Every arm is pinned here, including the three fail-opens the PR-227
# review found: comparing against `primary` instead of the real driver, accepting a bot declaration
# the merge guard rejects, and silently dropping unavailable slots.
rung() { ( cd "$REPO" && HOME="$GHOME" PATH="$1" bash "$RD" review-rung "${2:-}" ) ; }
RB="$work/rungbin"; mkdir -p "$RB"
for _t in codex claude agy; do printf '#!/usr/bin/env bash\nexit 0\n' > "$RB/$_t"; chmod +x "$RB/$_t"; done
clr_global

set_repo '[roles]' 'primary = "claude"' 'review = ["codex"]'
eq "${ rung "$RB:$BARE"; }"          "independent codex" "rung: a usable non-primary reviewer is independent"
# THE DRIVER ARGUMENT. Same manifest, run BY codex: the reviewer is now the model writing the diff,
# so `independent` would be a false claim of an independent pass. Comparing against `primary` (the
# manifest's guess at who writes) instead of the real driver is the fail-open this argument closes.
eq "${ rung "$RB:$BARE" codex; }"    "same-model codex"  "rung: driver=codex makes a codex reviewer same-model"
eq "${ rung "$RB:$BARE" gemini; }"   "independent codex" "rung: driver=gemini keeps a codex reviewer independent"
rung "$RB:$BARE" notanagent >/dev/null 2>&1; eq "$?" "2" "rung: a bogus driver token is unknown, not ignored"
has "${ rung "$RB:$BARE" notanagent; }" "unknown" "rung: the bogus-driver line says unknown"

set_repo '[roles]' 'primary = "claude"' 'review = ["claude"]'
eq "${ rung "$RB:$BARE"; }" "same-model claude" "rung: review == primary is same-model"

# MISSING SLOTS SURVIVE. An early return on the first available agent discarded the rest, so a
# partially-installed list reported unqualified coverage while a configured slot ran nothing.
set_repo '[roles]' 'primary = "claude"' 'review = ["codex", "gemini"]'
ONLYC="$work/onlyc"; mkdir -p "$ONLYC"; cp "$RB/codex" "$ONLYC/codex"
eq "${ rung "$ONLYC:$BARE"; }" "independent codex missing=gemini" "rung: an unavailable slot is reported alongside the rung"
eq "${ rung "$BARE"; }"        "none missing=codex,gemini"        "rung: every unavailable slot is listed"

# THE DEFERRED ARM AGREES WITH THE MERGE GUARD. `--declared` accepts a syntactically valid array
# whose entries no reviewer can match; `--comparable` (what pr-review.sh gate uses) rejects it 18.
# Reporting `deferred` off the looser reader promises a hand-off the guard will refuse.
set_repo '[roles]' 'primary = "claude"' 'review = ["codex"]' '[reviewers]' 'bots = ["chatgpt-codex-connector"]'
eq "${ rung "$BARE"; }" "deferred chatgpt-codex-connector missing=codex" "rung: a usable declared bot defers"
set_repo '[roles]' 'primary = "claude"' 'review = ["codex"]' '[reviewers]' 'bots = ["[bot]"]'
rung "$BARE" >/dev/null 2>&1; eq "$?" "2" "rung: a declaration the merge guard rejects is unknown, not deferred"
hasnt "${ rung "$BARE"; }" "deferred" "rung: an unmatchable bot login never reports deferred"
set_repo '[roles]' 'primary = "claude"' 'review = ["codex"]' '[reviewers]' 'bots = []'
eq "${ rung "$BARE"; }" "none missing=codex" "rung: an explicit bots = [] is none, not deferred"

# READER FAILURES ARE NEVER EMPTY CONFIG.
set_repo '[roles]' 'primary = "claude"' 'review = ["bogus"]' '[reviewers]' 'bots = ["chatgpt-codex-connector"]'
rung "$BARE" >/dev/null 2>&1; eq "$?" "2" "rung: an invalid review token is unknown, not deferred"
set_repo '[roles]' 'primary = "notanagent"' 'review = ["codex"]'
rung "$RB:$BARE" >/dev/null 2>&1; eq "$?" "2" "rung: an unresolvable primary is unknown, not independent"
clr_repo

# ============================ source guard ============================
# Sourcing must define the functions but NOT run the CLI dispatch (no usage/exit).
# shellcheck source=/dev/null
srcout="$( . "$RD" >/dev/null 2>&1; printf 'T=%s' "$(type -t adb_resolve_role)" )"
eq "$srcout" "T=function" "sourcing defines adb_resolve_role without dispatching"

# ============================ usage ============================
rd >/dev/null 2>&1; no $? "no subcommand prints usage and exits nonzero"

check_summary "role-dispatch"
