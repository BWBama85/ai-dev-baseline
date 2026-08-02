#!/usr/bin/env bash
# ai-dev-baseline — THIS REPO'S OWN Stop-hook gate (#240, D25).
#
# The global gate runs whatever `agents.toml [gates]` declares. This repo declares
# `test = "bash scripts/selfcheck.sh"` — its entire ~28-suite offline CI mirror. That is the right
# command for the job CLAUDE.md golden rule 3 gives it (before every PUSH) and the wrong one for a
# Stop hook, which fires at the end of EVERY turn: one measured run took 18m55s during a session
# that edited nothing, and the operator's only escape was deleting the hook machine-wide.
#
# One command, two cadences, wildly different budgets. So this gate runs the FAST subset that
# catches what a turn actually breaks (~3s measured), and the full mirror stays where it belongs.
#
# WHAT THIS DOES NOT COVER, stated rather than implied: everything else `selfcheck.sh` runs — every
# check-*.sh suite, install dry-run, the migration and guard checks. This is a turn-end smoke test,
# NOT a CI predictor. A green here says "you did not obviously break the build"; it does not say CI
# will pass. Run `bash scripts/selfcheck.sh` before you push.
#
# The global gate at ~/.claude/scripts/precommit-gate.sh detects this file and `exec`s it, so
# nothing double-runs. Exit 2 blocks the stop, exactly as the global gate does.

set -u
# bash 5.3 runtime floor (#256) — FIRST, before the cd and before ANY read of the hook payload on
# stdin: the re-exec inherits that fd and restarts this script from the top, so anything already
# consumed would be lost.
#
# The source is CONDITIONAL on purpose. This file has a deliberate broken-install posture of its
# own a few lines below, and the floor gate is not entitled to override it — if the shared library
# is missing, that decision stays with the machinery that already owns it.
if [ -f "$(dirname "$0")/../../scripts/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../../scripts/lib/common.sh"
  adb_require_bash "$@"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Default branch via the repo's OWN shared primitive, never a local re-derivation (golden rule 4).
# A hand-rolled `origin/HEAD || main` fallback misreads a clone whose origin/HEAD is unset and
# whose default branch is not named `main` — it would classify the real default branch as a
# feature branch and gate on it. adb_default_branch already models the local main/master fallback
# and is the single home for this decision.
# shellcheck source=/dev/null
. "$repo_root/scripts/lib/common.sh" || exit 0
command -v adb_default_branch >/dev/null 2>&1 || exit 0
default_branch="$(adb_default_branch "$repo_root")"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
[ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ] && exit 0

base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
changed="$( { git diff --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null
              git diff --no-renames --name-only 2>/dev/null
              git diff --no-renames --name-only --cached 2>/dev/null
              git ls-files --others --exclude-standard 2>/dev/null; } | sort -u | sed '/^$/d' )"
[ -z "$changed" ] && exit 0

fail=0
run() {  # run <label> <cmd...>; report per-check so a red or slow one is attributable
  local label="$1"; shift
  local t0=$SECONDS out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'precommit-gate: %-16s PASS (%ss)\n' "$label" "$(( SECONDS - t0 ))" >&2
  else
    printf 'precommit-gate: %-16s FAIL (%ss)\n%s\n' "$label" "$(( SECONDS - t0 ))" "$out" >&2
    fail=1
  fi
}
skip() { printf 'precommit-gate: %-16s SKIP (%s)\n' "$1" "$2" >&2; }

# Lint the changed shell files. The selector mirrors selfcheck's exactly — `*.sh` PLUS the
# extensionless `bin/` entrypoints — because `bin/baseline` and `bin/agent-init` are shell and CI
# lints them; a `*.sh`-only filter silently skipped them and deferred the failure to push time.
# (This comment deliberately does not begin with the tool's name: a comment starting `# shellcheck`
# is parsed as a DIRECTIVE, and this gate rejected itself for it on first run.)
sh_changed=""
while IFS= read -r f; do
  case "$f" in
    *.sh|bin/baseline|bin/agent-init) [ -e "$f" ] && sh_changed="${sh_changed:+$sh_changed }$f" ;;
  esac
done <<EOF
$changed
EOF
if [ -z "$sh_changed" ]; then
  :
elif command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086  # deliberate word-split: a space-separated file list
  run shellcheck shellcheck --severity=warning -e SC1091 $sh_changed
else
  # OPTIONAL dependency, exactly as selfcheck.sh treats it. Turning a missing optional tool into a
  # blocking exit 2 would wedge every turn that touches a .sh file on a dev box without it.
  skip shellcheck "shellcheck not installed"
fi

# Generated-file drift: the most common way a turn leaves this repo inconsistent, because editing
# base/ without rebuilding is invisible until CI. `build.sh` is idempotent.
#
# `git diff` alone is NOT enough: a NEW workflow whose skills were never rendered makes build.sh
# create those skill dirs as UNTRACKED files, which `git diff --quiet` ignores — so the forgotten
# render passed this gate while CI rejected it. Check both the tracked diff and untracked output.
# Ask whether BUILD.SH changed anything, not whether agents/ is dirty. `git diff -- agents/` alone
# reports every legitimate hand edit under that tree — the hook scripts there are hand-written
# source, not generated — so a turn editing one would be told its "generated files are stale".
# Snapshotting across the rebuild isolates what the build itself produced, which is the actual
# question. Untracked output is included because a NEW workflow whose skills were never rendered
# creates untracked dirs that `git diff` cannot see.
run build-drift bash -c '
  snap() { git diff --name-only -- agents/; git ls-files --others --exclude-standard -- agents/; }
  before="$(snap)"
  bash scripts/build.sh >/dev/null 2>&1 || { echo "build.sh failed"; exit 1; }
  after="$(snap)"
  [ "$before" = "$after" ] || {
    echo "build.sh changed generated output — rebuild and commit it:"
    printf "%s\n" "$after" | grep -vxF "$(printf "%s" "$before")" 2>/dev/null || printf "%s\n" "$after"
    exit 1; }
'
run workflow-render bash scripts/check-workflow-render.sh
run practice-index  bash scripts/check-practice-index.sh
run fact-drift      bash scripts/check-fact-drift.sh

if [ "$fail" -ne 0 ]; then
  printf '\nprecommit-gate: blocking stop — fix the failing check(s) above.\n' >&2
  printf 'precommit-gate: this is the FAST subset; run `bash scripts/selfcheck.sh` before pushing.\n' >&2
  exit 2
fi
exit 0
