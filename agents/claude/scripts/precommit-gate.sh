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
# FAIL LOUD (exit 2), never silently — when this gate's OWN required libraries
# (lib/common.sh, lib/project-gates.sh) are missing or corrupt. That is a broken /
# incomplete install, NOT an unfamiliar repo: a gate that silently no-ops then is
# enforcement secretly OFF, which is worse than a hard error (#35). This is distinct
# from "no gates detected" (a legitimate no-op decided INSIDE adb_run_gates).
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

# --- fail-loud dependency loading (#35) --------------------------------------
# This gate's shared libraries live in the sibling lib/ (installed as ~/.<agent>/scripts/lib).
# They are REQUIRED, not optional. A missing/corrupt library is a broken install, and a gate
# that silently no-ops then is enforcement secretly OFF — so it FAILS LOUD (exit 2, blocking),
# never exit 0. Resolving the default branch and the change set needs common.sh's
# adb_default_branch (single-source: never re-implement it here, per docs/design-principles.md),
# so common.sh is required up front — before the branch/changes no-op checks below.
lib_dir="$(dirname "$0")/lib"
fail_loud() {
  printf '\nprecommit-gate: FATAL — %s\n' "$1" >&2
  printf 'This is NOT a pass. The quality gates cannot run, so the turn is BLOCKED. The baseline\n' >&2
  printf "install is incomplete or an installed path moved — repair it with 'baseline update'\n" >&2
  printf '(or re-run install.sh from your baseline clone), then retry.\n' >&2
  exit 2
}
# Source a REQUIRED sibling library or fail loud: a missing file, an un-sourceable one, or one
# sourced but missing its expected function (a corrupt/truncated library) each block the turn.
require_lib() {  # <path> <expected-fn>
  [ -f "$1" ] || fail_loud "shared library not found: $1"
  # shellcheck source=/dev/null
  . "$1" || fail_loud "shared library failed to source: $1"
  command -v "$2" >/dev/null 2>&1 || fail_loud "$1 did not define $2 (corrupt library)"
}
require_lib "$lib_dir/common.sh" adb_default_branch

# Resolve the default branch (origin/HEAD → main → master → "main").
default_branch="$(adb_default_branch "$repo_root")"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  exit 0
fi

# Are there any changes at all on this branch? (committed vs base + working tree)
# `--no-renames` so a moved file surfaces BOTH its old and new path — a gate scoped to
# the area a file moved OUT of must still see the change (see project-gates.sh scope).
base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
committed=""
if git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
  committed="$(git diff --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null || true)"
fi
staged="$(git diff --no-renames --name-only --cached 2>/dev/null || true)"
unstaged="$(git diff --no-renames --name-only 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
changed="$(printf '%s\n%s\n%s\n%s\n' "$committed" "$staged" "$unstaged" "$untracked" | sort -u | sed '/^$/d')"
[ -z "$changed" ] && exit 0

# We are on a feature branch WITH changes: the gate WILL run. The gate library is required
# here too — a missing/corrupt one is the same broken-install fail-loud condition as common.sh
# above (a silent skip here was the old fail-silent bug #35 fixes), never a silent skip.
require_lib "$lib_dir/project-gates.sh" adb_run_gates

# Pass the branch change set so a path-scoped gate ([gates.scope] in agents.toml) runs
# only when it touches a matching file — the escape hatch that lets a repo express
# apps/**-style scoping without forking this whole script.
if adb_run_gates "$repo_root" "$changed"; then
  exit 0
fi

printf '\nprecommit-gate: blocking stop — fix the failing gate(s) above before ending the turn.\n' >&2
exit 2
