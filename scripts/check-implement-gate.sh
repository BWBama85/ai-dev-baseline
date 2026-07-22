#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for implement-issue-gate.sh's LIVE PR re-verification (#44).
#
# The Stop hook must not trust a stored prUrl/phase=complete to decide a run is done — it
# re-checks GitHub at the moment it acts, confirms the PR is THIS run's (this repo + branch)
# and still OPEN or MERGED, and FAILS CLOSED: a closed-without-merge or unverifiable PR keeps
# the turn going rather than letting it stop on stale state.
#
# `gh` is stubbed by a shim on PATH driven by SHIM_* env vars, and CLAUDE_CODE_EXECPATH is
# unset so the deterministic legacy signal (keep-going = exit 2) is used regardless of where
# the suite runs. Observables per case: exit code AND whether the active marker survives
# (a pass removes it; keep-going retains it).
#
# Usage: bash scripts/check-implement-gate.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
GATE="$ROOT/agents/claude/scripts/implement-issue-gate.sh"

command -v jq >/dev/null 2>&1 || { echo "check-implement-gate: jq required" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
eq()  { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3 (missing [$2] in output)" ;; esac; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git_q() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# --- gh shim -----------------------------------------------------------------
shimbin="$work/bin"; mkdir -p "$shimbin"
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") printf '%s\n' "${SHIM_REPO_URL:-}" ;;
  "pr view")
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_JSON:-}" ;;
  "pr list") printf '%s\n' "${SHIM_OPEN_PR_URL:-}" ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"

# --- fixture repo (.claude/state gitignored so the marker never dirties the tree) --
repo="$work/repo"; mkdir -p "$repo/.claude/state"
git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main
printf '.claude/state/\n' > "$repo/.gitignore"
printf 'seed\n' > "$repo/README.md"
git_q "$repo" add .gitignore README.md; git_q "$repo" commit -q -m seed
git -C "$repo" checkout -q -b feat
marker_file="$repo/.claude/state/implement-issue-active.json"

REPO_URL="https://github.com/acme/repo"

# Export the shim knobs ONCE (empty), so each case plain-reassigns them (keeping them exported
# for the shim subprocess) without `export VAR="$(...)"` masking a command-substitution status.
export SHIM_REPO_URL="" SHIM_PR_JSON="" SHIM_OPEN_PR_URL="" SHIM_PR_VIEW_FAIL=""
reset_shim() { SHIM_REPO_URL=""; SHIM_PR_JSON=""; SHIM_OPEN_PR_URL=""; SHIM_PR_VIEW_FAIL=""; }

pr_json() {  # <state> <mergedAt-or-empty> <url> <headRefName>
  jq -cn --arg s "$1" --arg m "$2" --arg u "$3" --arg h "$4" \
    '{state:$s, mergedAt:(if $m=="" then null else $m end), url:$u, headRefName:$h}'
}
write_marker() {  # <phase> <prUrl-or-empty>
  jq -n --arg b feat --arg i 35 --arg p "$1" --arg u "$2" \
    '{branch:$b, issue:$i, phase:$p} + (if $u=="" then {} else {prUrl:$u} end)' > "$marker_file"
}
run_gate() {  # sets RC, OUT ; SHIM_* read from the (exported) env
  OUT="$(cd "$repo" && unset CLAUDE_CODE_EXECPATH && PATH="$shimbin:$PATH" bash "$GATE" 2>&1)"; RC=$?
}
gone() { [ ! -f "$marker_file" ]; }

# --- cases -------------------------------------------------------------------

# A. stored PR OPEN and this-run's → satisfied: marker removed, exit 0.
reset_shim; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json OPEN '' "$REPO_URL/pull/1" feat)"
run_gate
eq "$RC" 0 "A: open stored PR → exit 0"
if gone; then ok; else bad "A: open stored PR removes the marker"; fi

# B. stored PR MERGED → satisfied, even though phase=complete is not trusted on its own.
reset_shim; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json MERGED 2026-01-01T00:00:00Z "$REPO_URL/pull/1" feat)"
run_gate
eq "$RC" 0 "B: merged stored PR → exit 0"
if gone; then ok; else bad "B: merged stored PR removes the marker"; fi

# C. stored PR CLOSED-unmerged, no replacement → keep going, marker retained, closed message.
reset_shim; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json CLOSED '' "$REPO_URL/pull/1" feat)"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "C: closed-unmerged → keep going (exit 2)"
if gone; then bad "C: closed-unmerged must RETAIN the marker"; else ok; fi
has "$OUT" "CLOSED without merging" "C: message names the closed PR"

# D. stored PR belongs to a DIFFERENT repo → unverified → keep going.
reset_shim; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json OPEN '' "https://github.com/other/repo/pull/1" feat)"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "D: wrong-repo PR is unverified → keep going"
if gone; then bad "D: wrong-repo unverified must RETAIN the marker"; else ok; fi

# E. stored PR CLOSED but a replacement OPEN PR exists for the branch → satisfied.
reset_shim; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json CLOSED '' "$REPO_URL/pull/1" feat)"; SHIM_OPEN_PR_URL="$REPO_URL/pull/2"
run_gate
eq "$RC" 0 "E: closed stored + replacement open PR → exit 0"
if gone; then ok; else bad "E: replacement open PR removes the marker"; fi

# F. gh pr view errors → unverified (fail closed, NOT trust-the-marker) → keep going.
reset_shim; write_marker complete "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_VIEW_FAIL=1; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "F: gh error → unverified → keep going (fail closed)"
if gone; then bad "F: gh error must RETAIN the marker"; else ok; fi
has "$OUT" "could not be verified" "F: message flags the unverified state"

# G. no prUrl but an OPEN PR exists for the branch (marker not yet updated) → satisfied.
reset_shim; write_marker committed ""
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL="$REPO_URL/pull/1"
run_gate
eq "$RC" 0 "G: no prUrl + live open PR → exit 0"
if gone; then ok; else bad "G: live open PR removes the marker"; fi

# H. no prUrl, no open PR, clean tree → keep going with the has-not-opened message.
reset_shim; write_marker committed ""
SHIM_REPO_URL="$REPO_URL"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "H: no prUrl + no open PR → keep going"
if gone; then bad "H: no-PR must RETAIN the marker"; else ok; fi
has "$OUT" "has not opened a PR yet" "H: message is the not-yet-opened hint"

# I. stored PR is for a DIFFERENT branch → unverified → keep going.
reset_shim; write_marker committed "$REPO_URL/pull/1"
SHIM_REPO_URL="$REPO_URL"; SHIM_PR_JSON="$(pr_json OPEN '' "$REPO_URL/pull/1" some-other-branch)"; SHIM_OPEN_PR_URL=""
run_gate
eq "$RC" 2 "I: PR on a different branch is unverified → keep going"

printf '\nimplement-gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "implement-gate: PASS"
