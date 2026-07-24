#!/usr/bin/env bash
# ai-dev-baseline — integration tests for bin/agent-init's repo-shape tolerance (#23).
#
# The adb_repo_shape UNIT tests (in check-common-lib.sh) verify the shape FACTS; this verifies
# agent-init's BEHAVIOR on top of them — the acceptance criterion from #23 and its siblings:
#   - it resolves the git root even when run from a subdirectory, writing agents.toml at the
#     ROOT and never in the subdir;
#   - bama-style (a git repo dropped inside an untracked parent tree with a root doc ABOVE it),
#     it identifies the inner repo as the root, NOTES the untracked parent + the out-of-repo doc,
#     and leaves that parent untouched — "doesn't assume it can see them";
#   - it surfaces a nested-inside-another-repo layout;
#   - a non-git directory is refused WITHOUT writing anything (a clear, documented fallback).
#
# Lives OUTSIDE scripts/lib/ (test code must not ship into a user's runtime). Runs agent-init with
# an isolated HOME so its role-map print never reads or writes the contributor's real ~/.config.
#
# Usage: bash scripts/check-agent-init.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
AGENT_INIT="$REPO/bin/agent-init"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
FAKEHOME="$work/home"; mkdir -p "$FAKEHOME"

# Run agent-init with cwd=<dir> and an isolated HOME; capture merged stdout+stderr and status.
# (A subshell cd keeps the test's own cwd — the repo root — intact.)
run_init() { ( cd "$1" && HOME="$FAKEHOME" bash "$AGENT_INIT" 2>&1 ); }
# Physical canonical path — agent-init echoes shape paths canonicalized via `pwd -P`, so on macOS
# a /var vs /private/var mismatch would make a naive substring assertion flap.
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# --- (1) tidy repo, cwd == root: writes at root, exits 0, stays quiet ---------
tidy="$work/tidy"; mkdir -p "$tidy"; git init -q "$tidy"
out="$(run_init "$tidy")"; rc=$?
yes "$rc" "tidy: agent-init exits 0"
if [ -f "$tidy/agents.toml" ]; then ok; else bad "tidy: agents.toml written at the root"; fi
hasnt "$out" "working dir is below" "tidy: no working-dir note on a clean layout"
hasnt "$out" "NESTED"               "tidy: no nested note on a clean layout"
hasnt "$out" "OUTSIDE this repo"    "tidy: no foreign-doc note on a clean layout"

# --- (2) run from a subdirectory: agents.toml lands at the git ROOT -----------
subrepo="$work/subrepo"; mkdir -p "$subrepo/a/b/c"; git init -q "$subrepo"
out="$(run_init "$subrepo/a/b/c")"; rc=$?
yes "$rc" "subdir: exits 0"
has "$out" "working dir is below the git root" "subdir: surfaces the working-dir note"
if [ -f "$subrepo/agents.toml" ]; then ok; else bad "subdir: agents.toml written at the git ROOT"; fi
if [ ! -f "$subrepo/a/b/c/agents.toml" ]; then ok; else bad "subdir: agents.toml NOT written in the subdir"; fi

# --- (3) bama-style acceptance: untracked parent + out-of-repo root doc -------
site="$work/site"; plugin="$site/wp-content/plugins/myplugin"
mkdir -p "$plugin"; git init -q "$plugin"
printf 'site root doc\n' > "$site/CLAUDE.md"     # outside any repo, referenced by relative path
out="$(run_init "$plugin")"; rc=$?
yes "$rc" "bama: exits 0 (surfaces, never hard-fails)"
has "$out" "$(canon "$site")/CLAUDE.md" "bama: names the out-of-repo site CLAUDE.md"
has "$out" "OUTSIDE this repo"          "bama: flags the doc as outside this repo"
has "$out" "untracked project tree"     "bama: notes the untracked parent"
if [ -f "$plugin/agents.toml" ]; then ok; else bad "bama: agents.toml written at the plugin root"; fi
if [ ! -f "$site/agents.toml" ]; then ok; else bad "bama: the untracked parent is left untouched"; fi
eq "$(cat "$site/CLAUDE.md")" "site root doc" "bama: the out-of-repo doc is never modified"

# --- (4) nested inside another git repo --------------------------------------
nouter="$work/nouter"; mkdir -p "$nouter"; git init -q "$nouter"
ninner="$nouter/sub/inner"; mkdir -p "$ninner"; git init -q "$ninner"
out="$(run_init "$ninner")"; rc=$?
yes "$rc" "nested: exits 0"
has "$out" "NESTED inside another git repo" "nested: surfaces the nested-repo note"
has "$out" "$(canon "$nouter")"             "nested: names the enclosing repo"
if [ -f "$ninner/agents.toml" ]; then ok; else bad "nested: agents.toml written at the inner root"; fi
if [ ! -f "$nouter/agents.toml" ]; then ok; else bad "nested: the outer repo is left untouched"; fi

# --- (5) a non-git directory is refused WITHOUT writing anything -------------
plain="$work/plain"; mkdir -p "$plain"
out="$(run_init "$plain")"; rc=$?
no "$rc" "non-git: exits non-zero"
has "$out" "not inside a git repo" "non-git: explains the refusal"
if [ ! -f "$plain/agents.toml" ]; then ok; else bad "non-git: writes nothing (no agents.toml)"; fi
if [ ! -f "$plain/.gitignore" ]; then ok; else bad "non-git: writes nothing (no .gitignore)"; fi

check_summary "agent-init"
