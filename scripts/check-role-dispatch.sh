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
eq "$(rd resolve primary)"      "claude" "resolve primary from repo"
eq "$(rd resolve gap_analysis)" "codex"  "resolve gap_analysis from repo"
eq "$(rd resolve review)"       "claude" "resolve single-element review"
eq "$(rd resolve debug)"        "claude" "resolve debug from repo"

# multi-agent review list
set_repo '[roles]' 'primary = "claude"' 'review = ["claude", "gemini"]'
eq "$(rd resolve review | tr '\n' ',')" "claude,gemini," "resolve multi-agent review list"

# resolution ORDER: no repo file → global default manifest wins
clr_repo
set_global '[roles]' 'primary = "codex"' 'review = ["gemini"]'
eq "$(rd resolve primary)" "codex"  "unset repo → global primary"
eq "$(rd resolve review)"  "gemini" "unset repo → global review"

# built-in fallback (no manifest anywhere): primary=claude; review/debug → primary; gap → skip
clr_repo; clr_global
eq "$(rd resolve primary)" "claude" "built-in primary default is claude"
eq "$(rd resolve review)"  "claude" "built-in review falls back to primary"
eq "$(rd resolve debug)"   "claude" "built-in debug falls back to primary"
out="$(rd resolve gap_analysis)"; rc=$?
eq "$out" "" "built-in gap_analysis is a skip (no output)"; yes "$rc" "skip is a 0 status"

# gap_analysis = "" is the explicit skip
set_repo '[roles]' 'gap_analysis = ""'
out="$(rd resolve gap_analysis)"; rc=$?
eq "$out" "" 'gap_analysis="" → empty'; yes "$rc" 'gap_analysis="" is a 0 status'

# review = "" (empty string) → the primary's own pass (documented default), NOT an error
set_repo '[roles]' 'primary = "claude"' 'review = ""'
eq "$(rd resolve review)" "claude" 'review="" → primary'

# --- `release` + `issue_author`: declared roles with no shipped consumer (#3) ------------------
# The baseline ships no /release skill on purpose — `release` names WHO would cut a release in a
# project-owned skill someone else writes. Resolution is therefore the ONLY contract the baseline
# owes it, so pin it. Validation (unknown token, list cardinality) is NOT re-tested per role: the
# resolver handles gap_analysis|review|debug|issue_author|release in ONE case arm, so the
# gap_analysis cases below already cover that arm for every key.
set_repo '[roles]' 'primary = "claude"' 'release = "codex"'
eq "$(rd resolve release)" "codex" "explicit release wins over the primary fallback"

# "Falls back to primary" must be proven with a NON-claude primary. The built-in-default cases at
# the top can't do this (with no manifest anywhere, primary IS claude), so "falls back to primary"
# and "returns the literal string claude" are indistinguishable there. Set a gemini primary and
# assert EVERY primary-defaulting role at once — the general check, not one special-cased to the
# two roles this change happened to add.
set_repo '[roles]' 'primary = "gemini"'
for r in review debug issue_author release; do
  eq "$(rd resolve "$r")" "gemini" "unset $r falls back to primary (not literal claude)"
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
b="$(rd bots)"
has "$b" "chatgpt-codex-connector" "default bot allowlist includes the Codex connector"
has "$b" "copilot[bot]"            "default bot allowlist includes copilot[bot]"
has "$b" "claude-code[bot]"        "default bot allowlist includes claude-code[bot]"

set_repo '[reviewers]' 'bots = ["chatgpt-codex-connector", "my-bot[bot]"]'
eq "$(rd bots | tr '\n' ',')" "chatgpt-codex-connector,my-bot[bot]," "[reviewers] bots override is authoritative"

set_repo '[reviewers]' 'bots = []'
out="$(rd bots)"; rc=$?
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
out="$(rd bots --declared)"; rc=$?
eq "$out" "chatgpt-codex-connector" "bots --declared returns the declared logins"
yes "$rc" "a declared non-empty list is a 0 status"

set_repo '[reviewers]' 'bots = []'
out="$(rd bots --declared)"; rc=$?
eq "$out" "" "bots --declared: [] is declared-and-empty (no async reviewer)"
yes "$rc" "declared [] is a 0 status — distinct from undeclared"

clr_repo; clr_global
out="$(rd bots --declared 2>/dev/null)"; rc=$?
eq "$out" "" "bots --declared prints nothing when undeclared"
eq "$rc" "3" "UNDECLARED is its own status (3), never the built-in default set"
# The contrast that matters: the SAME state yields the default allowlist for /resolve-pr-threads.
has "$(rd bots)" "chatgpt-codex-connector" "undeclared still yields the DEFAULT set for the plain 'bots' reader"

# global-only declaration still counts as declared (the layering is repo -> global)
clr_repo; set_global '[reviewers]' 'bots = ["my-bot[bot]"]'
out="$(rd bots --declared)"; rc=$?
eq "$out" "my-bot[bot]" "a GLOBAL declaration counts as declared"
yes "$rc" "global declaration is a 0 status"
clr_global

set_repo '[reviewers]' 'bots = "my-bot[bot]"'
rd bots --declared >/dev/null 2>&1
eq "$?" "2" "malformed [reviewers].bots is 2 under --declared (never confused with 3 or [])"

rd bots --bogus >/dev/null 2>&1; eq "$?" "2" "an unknown bots flag is rejected"

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
out="$(printf 'do gap analysis' | rd invoke gap_analysis 2>/dev/null)"; rc=$?
yes "$rc" "invoke gap_analysis (codex) succeeds"
eq "$out" "$(printf 'RECEIVED:do gap analysis\nVERDICT: proceed')" "codex invoke returns ONLY the final message AND the prompt reached codex"
err="$(printf 'x' | rd invoke gap_analysis 2>&1 >/dev/null)"
has "$err" "EXPLORATION NOISE" "codex exploration stream is routed to stderr"
hasnt "$out" "EXPLORATION NOISE" "codex exploration noise never contaminates stdout"
# REGRESSION (watchdog stdin bug): the portable watchdog path must ALSO deliver the prompt on
# stdin, not /dev/null. Before the `<&0` fix this returned "RECEIVED:" (empty).
outw="$(printf 'watchdog-prompt' | ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" ADB_DISPATCH_NO_TIMEOUT_BIN=1 bash "$RD" invoke gap_analysis 2>/dev/null ))"
has "$outw" "RECEIVED:watchdog-prompt" "watchdog path delivers the prompt on stdin (not /dev/null)"

# explicit agent tokens invoke directly
eq "$(printf 'review it' | rd invoke claude 2>/dev/null)" "CLAUDE:review it" "invoke <claude> runs claude -p"
eq "$(printf 'review it' | rd invoke gemini 2>/dev/null)" "GEMINI:review it" "invoke <gemini> runs agy -p"

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
    "$@" bash -c '. "$1" >/dev/null 2>&1; printf %s "${!2:-unset}"' rd_var "$RD" "$v"; }
eq "$(rd_var _ADB_RD_TIMEOUT_SECS)" "2700" "the no-environment default bound is 2700s (45-min hang backstop)"
eq "$(rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=99)" "99" "ADB_DISPATCH_TIMEOUT_SECS still overrides the default"
eq "$(rd_var _ADB_RD_KILL_GRACE_SECS)" "10" "the no-environment kill grace is 10s"
# Both degenerate grace values are clamped: `timeout -k 0` means "no SIGKILL at all" to GNU
# timeout (so a 0 grace would leave the binary path with NO escalation while the watchdog path
# kills immediately), and a non-numeric value makes timeout exit 125 — which would classify as
# "a real agent error" and send the reader hunting a codex bug that isn't there.
eq "$(rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=0)" "1"  "a 0 kill grace is clamped to 1 (never 'no escalation')"
eq "$(rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=x)" "10" "a non-numeric kill grace falls back to the default"
eq "$(rd_var _ADB_RD_KILL_GRACE_SECS ADB_DISPATCH_KILL_GRACE_SECS=3)" "3"  "a valid kill grace is honored"
# The bound is compared arithmetically (the 137->124 normalization) and counted down by the
# portable watchdog, both integer-only — so a fractional override that `timeout` would happily
# accept produced `[: 0.5: integer expression expected` and fired the bound instantly, failing
# every dispatch at once. Reject it loudly instead (bot review, PR #105).
eq "$(rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=0.5 2>/dev/null)" "2700" "a fractional bound falls back to the default rather than breaking every dispatch"
eq "$(rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=0   2>/dev/null)" "2700" "a zero bound falls back to the default"
eq "$(rd_var _ADB_RD_TIMEOUT_SECS ADB_DISPATCH_TIMEOUT_SECS=abc 2>/dev/null)" "2700" "a non-numeric bound falls back to the default"
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
has "$(cls 124)" "backstop"     "rc 124 is classified as our own hang backstop"
has "$(cls 124)" "ADB_DISPATCH_TIMEOUT_SECS" "the 124 classification names the override knob"
has "$(cls 143)" "OUTER"        "rc 143 is classified as an OUTER bound, not ours"
has "$(cls 137)" "outside"      "rc 137 is classified as an external kill"
has "$(cls 7)"   "real agent"   "an arbitrary nonzero rc is classified as a real agent error"
hasnt "$(cls 7)" "backstop"     "a real agent error is NOT blamed on our backstop"
eq "$(cls 0)" "completed"       "rc 0 is classified as completed"

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
( timeout 2 bash "$work/probe.sh" >/dev/null 2>&1 ) &
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
eq "$(ps -eo command | grep -c '[q]qstub' | tr -d ' ')" "0" \
  "an outer termination reaps the dispatched agent instead of orphaning it for the full bound"
pkill -f '[q]qstub' >/dev/null 2>&1 || true

# ============================ source guard ============================
# Sourcing must define the functions but NOT run the CLI dispatch (no usage/exit).
# shellcheck source=/dev/null
srcout="$( . "$RD" >/dev/null 2>&1; printf 'T=%s' "$(type -t adb_resolve_role)" )"
eq "$srcout" "T=function" "sourcing defines adb_resolve_role without dispatching"

# ============================ usage ============================
rd >/dev/null 2>&1; no $? "no subcommand prints usage and exits nonzero"

check_summary "role-dispatch"
