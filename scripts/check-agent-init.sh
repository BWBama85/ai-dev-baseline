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
# (A subshell cd keeps the test's own cwd — the repo root — intact.) canon() (physical path,
# for the /var vs /private/var comparison) is provided by check-lib.sh.
run_init() { ( cd "$1" && HOME="$FAKEHOME" bash "$AGENT_INIT" 2>&1 ); }

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

# --- (6) the REVIEW RUNG report (#211) ---------------------------------------
# agent-init is where an operator learns what will actually review a diff, BEFORE a workflow
# depends on it. The rung is derived from `resolve review` + `available` + `bots --declared`, the
# same readers /implement-issue step 8 uses, so these cases also guard the two from disagreeing.
#
# PATH is the fixture here: the rung turns on whether an agent's CLI exists, so each case runs
# under an explicit PATH rather than the contributor's (who may well have all three installed).
RBIN="$work/rbin"; mkdir -p "$RBIN"
BARE=/usr/bin:/bin
_leak=0
for _t in claude codex agy; do PATH="$BARE" command -v "$_t" >/dev/null 2>&1 && _leak=1; done
if [ "$_leak" -eq 0 ]; then ok; else bad "rung precondition: no agent CLI may live in $BARE"; fi
run_rung() { ( cd "$1" && HOME="$FAKEHOME" PATH="$2" bash "$AGENT_INIT" 2>&1 ); }

rr="$work/rung"; mkdir -p "$rr"; git init -q "$rr"
run_init "$rr" >/dev/null 2>&1      # seed agents.toml from the template (review = ["codex"])

# (a) no reviewer CLI, nothing declared -> NONE. The honest floor.
out="$(run_rung "$rr" "$BARE")"
has "$out" "Review rung: NONE" "rung: no CLI + no declaration reports NONE"
has "$out" "Nothing independent will review" "rung: NONE says plainly what that means"

# (b) UNSET [reviewers] must NOT read as declared. `bots` (bare) substitutes a built-in default
# set of eight logins, so reading that surface instead of `--declared` would promote this exact
# repo from NONE to "deferred" and tell an operator they have an async reviewer they never set up.
hasnt "$out" "DEFERRED" "rung: an UNSET [reviewers] never reports deferred (bare \`bots\` would)"

# (c) an async reviewer DECLARED, still no CLI -> deferred, and honest about its narrowness.
printf '\n[reviewers]\nbots = ["chatgpt-codex-connector"]\n' >> "$rr/agents.toml"
out="$(run_rung "$rr" "$BARE")"
has "$out" "DEFERRED to the PR layer" "rung: a declared bot with no CLI reports deferred"
has "$out" "chatgpt-codex-connector"  "rung: deferred names the reviewer it is deferring to"
has "$out" "NOT block a manual merge" "rung: deferred states what it does NOT gate"

# (d) the reviewer's CLI present and != primary -> independent.
printf '#!/usr/bin/env bash\nexit 0\n' > "$RBIN/codex"; chmod +x "$RBIN/codex"
out="$(run_rung "$rr" "$RBIN:$BARE")"
has "$out" "independent in-session review" "rung: an available non-primary reviewer is independent"

# (e) review == primary -> SAME-MODEL, even though its CLI is present and it will really run.
sed 's/^review .*/review       = ["claude"]/' "$rr/agents.toml" > "$rr/a.tmp" && mv "$rr/a.tmp" "$rr/agents.toml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RBIN/claude"; chmod +x "$RBIN/claude"
out="$(run_rung "$rr" "$RBIN:$BARE")"
has "$out" "SAME-MODEL only" "rung: a reviewer equal to primary reports same-model, not independent"

# (f) the per-token CLI annotation on the role map marks which half of a list is missing.
sed 's/^review .*/review       = ["codex", "gemini"]/' "$rr/agents.toml" > "$rr/a.tmp" && mv "$rr/a.tmp" "$rr/agents.toml"
out="$(run_rung "$rr" "$RBIN:$BARE")"
has "$out" "gemini [CLI not installed]" "role map: annotates the absent token in a review LIST"
hasnt "$out" "codex [CLI not installed]" "role map: says nothing about a token that IS installed"
# An absent CLI is an annotation, never a verdict: agent-init must still exit 0.
( cd "$rr" && HOME="$FAKEHOME" PATH="$BARE" bash "$AGENT_INIT" >/dev/null 2>&1 )
yes $? "rung: an absent reviewer CLI does not make agent-init fail"

# (g) an INVALID manifest must not read as independent. `primary` is required, so an empty
# resolution means the manifest is broken and "is this reviewer the implementer?" is unanswerable.
# Guessing `independent` there is the flattering answer and the wrong direction to guess in.
sed 's/^primary .*/primary      = "notanagent"/' "$rr/agents.toml" > "$rr/a.tmp" && mv "$rr/a.tmp" "$rr/agents.toml"
out="$(run_rung "$rr" "$RBIN:$BARE")"
has "$out" "Review rung: unknown" "rung: an unresolvable primary reports unknown, not independent"
hasnt "$out" "independent in-session review" "rung: a broken manifest never claims independent review"

check_summary "agent-init"
