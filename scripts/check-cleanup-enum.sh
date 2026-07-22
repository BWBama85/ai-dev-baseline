#!/usr/bin/env bash
# ai-dev-baseline — regression test for /cleanup's remote branch enumeration (#38).
#
# `git branch -r --merged origin/<default> --format='%(refname:short)'` emits the remote's
# origin/HEAD symbolic ref as a BARE `origin` — which is NOT a branch. The old pipeline
# (`sed 's@^origin/@@'` alone) left that bare `origin` in the merged list, so /cleanup would
# offer `git push origin --delete origin` — a bogus deletion of a nonexistent branch.
#
# This test builds a throwaway local+remote pair with an origin/HEAD symref and a genuinely
# merged remote branch, then runs the EXACT enumeration pipeline from base/workflows/cleanup.md
# and asserts: (1) the raw enumeration really does surface the bare `origin` symref (the repro
# is real), and (2) the shipped pipeline excludes bare `origin` while keeping the real merged
# branch. Self-contained (local file remotes, no network).
#
# Usage: bash scripts/check-cleanup-enum.sh   (exit 0 = pass, 1 = fail)

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "cleanup-enum"

work="$(mktemp -d)" || { check_note "mktemp failed"; exit 1; }
trap 'rm -rf "$work"' EXIT

DEFAULT=main
CURRENT="$DEFAULT"   # /cleanup enumerates after returning to the default branch
PROTECTED='^(HEAD|'"$DEFAULT"'|main|master|develop|release/.*|hotfix/.*)$'

# --- build a local repo with a real origin, an origin/HEAD symref, and a merged branch ---
git init --bare "$work/remote.git" >/dev/null 2>&1
git init "$work/local" >/dev/null 2>&1
(
  cd "$work/local" || exit 1
  git config user.email t@example.com
  git config user.name  tester
  git config commit.gpgsign false
  git checkout -b "$DEFAULT" >/dev/null 2>&1
  git commit --allow-empty -m init >/dev/null 2>&1
  git remote add origin "$work/remote.git"
  git push -u origin "$DEFAULT" >/dev/null 2>&1
  # a feature branch genuinely merged into the default branch
  git checkout -b feature/done >/dev/null 2>&1
  git commit --allow-empty -m work >/dev/null 2>&1
  git checkout "$DEFAULT" >/dev/null 2>&1
  git merge --no-ff feature/done -m merge >/dev/null 2>&1
  git push origin "$DEFAULT" >/dev/null 2>&1
  git push origin feature/done >/dev/null 2>&1
  git remote set-head origin "$DEFAULT" >/dev/null 2>&1   # creates the origin/HEAD symref
  git fetch --prune origin >/dev/null 2>&1
)

run_in_repo() { ( cd "$work/local" && eval "$1" ); }

# (1) Repro guard: the raw enumeration MUST surface the bare `origin` symref, or the fixture
# isn't exercising the bug and a green result would be meaningless.
raw="$(run_in_repo "git branch -r --merged \"origin/$DEFAULT\" --format='%(refname:short)'")"
if ! printf '%s\n' "$raw" | grep -qx 'origin'; then
  check_note "fixture did not reproduce the bare 'origin' symref (raw enumeration: $(printf '%s' "$raw" | tr '\n' ' ')) — test is not exercising #38"
  check_fail
fi

# (2) The shipped pipeline (base/workflows/cleanup.md step 2) — must exclude bare `origin`.
pipeline="git branch -r --merged \"origin/$DEFAULT\" --format='%(refname:short)' \
  | grep '^origin/' | grep -v '^origin/HEAD\$' | sed 's@^origin/@@' \
  | grep -Ev \"$PROTECTED\" | grep -Fxv \"$CURRENT\" | sort -u"
remote_merged="$(run_in_repo "$pipeline")"

if printf '%s\n' "$remote_merged" | grep -qx 'origin'; then
  check_note "phantom 'origin' survived the fixed pipeline: [$(printf '%s' "$remote_merged" | tr '\n' ' ')]"
  check_fail
fi

# (3) …while still keeping the genuinely-merged branch.
if ! printf '%s\n' "$remote_merged" | grep -qx 'feature/done'; then
  check_note "real merged branch 'feature/done' missing from enumeration: [$(printf '%s' "$remote_merged" | tr '\n' ' ')]"
  check_fail
fi

check_result "remote enumeration excludes the origin/HEAD symref, keeps real merged branches"
