#!/usr/bin/env bash
# ai-dev-baseline — global Stop-hook quality gate.
#
# Claude Code runs this when the agent tries to end its turn. It blocks the stop
# (exit 2) if the repo's auto-detected quality gates (typecheck / lint / test /
# format) would fail on the current feature branch — so an autonomous run can't
# finalize work while CI-critical checks are red.
#
# No-op (exit 0) when:
#   - not in a git repo;
#   - the repo ships its OWN precommit gate at .claude/scripts/precommit-gate.sh
#     (project owns its gates — we defer to it, so nothing double-runs);
#   - HEAD is the default branch, detached, or unknown;
#   - there are zero changes on the branch (nothing to check);
#   - no supported ecosystem/gates are detected (safe in unfamiliar repos).
#
# A red gate is genuinely wrong-until-fixed, so this stays a hard exit-2 block
# (unlike the soft "keep going" cue in implement-issue-gate.sh). See
# base/practices/ci-discipline.md for the diagnose-before-rerun philosophy.

set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Defer to a project-local gate if one exists and it isn't this very file.
proj_gate="$repo_root/.claude/scripts/precommit-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  exit 0
fi

# Resolve the default branch (origin/HEAD → main → master → "main").
default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
if [ -z "$default_branch" ]; then
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then default_branch="$b"; break; fi
  done
fi
[ -z "$default_branch" ] && default_branch="main"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  exit 0
fi

# Are there any changes at all on this branch? (committed vs base + working tree)
base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
committed=""
if git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
  committed="$(git diff --name-only "${base_ref}...HEAD" 2>/dev/null || true)"
fi
staged="$(git diff --name-only --cached 2>/dev/null || true)"
unstaged="$(git diff --name-only 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
changed="$(printf '%s\n%s\n%s\n%s\n' "$committed" "$staged" "$unstaged" "$untracked" | sort -u | sed '/^$/d')"
[ -z "$changed" ] && exit 0

# Load the gate library that lives next to this script (both are installed as
# symlinks into the same ~/.<agent>/scripts/ directory).
lib="$(dirname "$0")/lib/project-gates.sh"
if [ ! -f "$lib" ]; then
  printf 'precommit-gate: gate library not found at %s — skipping\n' "$lib" >&2
  exit 0
fi
# shellcheck source=/dev/null
. "$lib"

if adb_run_gates "$repo_root"; then
  exit 0
fi

printf '\nprecommit-gate: blocking stop — fix the failing gate(s) above before ending the turn.\n' >&2
exit 2
