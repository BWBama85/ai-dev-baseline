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
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$BIN"
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

# ============================ invoke (PATH-stubbed agents) ============================
# codex stub: write ONLY the clean report to --output-last-message, stream noise to stdout, and
# drain the prompt on stdin — exactly the shape the helper must tame (#8).
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do case "$prev" in --output-last-message) out="$a" ;; esac; prev="$a"; done
echo "EXPLORATION NOISE — must not reach captured stdout"
cat >/dev/null
[ -n "$out" ] && printf 'BLOCKING\n- none\nVERDICT: proceed\n' > "$out"
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

# codex: stdout is the CLEAN final message; noise is on stderr, not stdout.
out="$(printf 'do gap analysis' | rd invoke gap_analysis 2>/dev/null)"; rc=$?
yes "$rc" "invoke gap_analysis (codex) succeeds"
eq "$out" "$(printf 'BLOCKING\n- none\nVERDICT: proceed')" "codex invoke returns ONLY the final message"
err="$(printf 'x' | rd invoke gap_analysis 2>&1 >/dev/null)"
has "$err" "EXPLORATION NOISE" "codex exploration stream is routed to stderr"
hasnt "$out" "EXPLORATION NOISE" "codex exploration noise never contaminates stdout"

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
out_rc=0; printf 'x' | ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" ADB_DISPATCH_TIMEOUT_SECS=1 bash "$RD" invoke gap_analysis >/dev/null 2>&1 ) || out_rc=$?
eq "$out_rc" "124" "invoke enforces the timeout (rc 124)"
# force the portable watchdog path (no timeout binary) and confirm it also fires
out_rc=0; printf 'x' | ( cd "$REPO" && HOME="$GHOME" PATH="$BIN:$PATH" ADB_DISPATCH_TIMEOUT_SECS=1 ADB_DISPATCH_NO_TIMEOUT_BIN=1 bash "$RD" invoke gap_analysis >/dev/null 2>&1 ) || out_rc=$?
eq "$out_rc" "124" "the bash watchdog fallback also enforces the timeout"

# ============================ source guard ============================
# Sourcing must define the functions but NOT run the CLI dispatch (no usage/exit).
# shellcheck source=/dev/null
srcout="$( . "$RD" >/dev/null 2>&1; printf 'T=%s' "$(type -t adb_resolve_role)" )"
eq "$srcout" "T=function" "sourcing defines adb_resolve_role without dispatching"

# ============================ usage ============================
rd >/dev/null 2>&1; no $? "no subcommand prints usage and exits nonzero"

check_summary "role-dispatch"
