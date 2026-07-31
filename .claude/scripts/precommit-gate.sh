#!/usr/bin/env bash
# ai-dev-baseline — THIS REPO'S OWN Stop-hook gate (#240).
#
# The global gate runs whatever `agents.toml [gates]` declares. This repo declares
# `test = "bash scripts/selfcheck.sh"` — its entire ~28-suite offline CI mirror. That is the right
# command for the job CLAUDE.md golden rule 3 gives it (before every PUSH) and the wrong one for a
# Stop hook, which fires at the end of EVERY turn: one measured run took 18m55s during a session
# that edited nothing, and the operator's only escape was deleting the hook machine-wide.
#
# One command, two cadences, wildly different budgets. So this gate runs the FAST subset that
# catches what a turn actually breaks (~11s measured), and the full mirror stays where it belongs.
#
# WHAT THIS DOES NOT COVER, stated plainly rather than implied: everything else `selfcheck.sh`
# runs — every check-*.sh suite, install dry-run, the migration and guard checks. This is a
# turn-end smoke test, NOT a CI predictor. A green here says "you did not obviously break the
# build"; it does not say CI will pass. Run `bash scripts/selfcheck.sh` before you push.
#
# The global gate at ~/.claude/scripts/precommit-gate.sh detects this file and `exec`s it, so
# nothing double-runs. Exit 2 blocks the stop, exactly as the global gate does.

set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Same no-op conditions as the global gate: nothing to gate on the default branch, or with no
# changes at all. Resolving the default branch by asking git, never assuming `main`.
default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
[ -z "$default_branch" ] && default_branch=main
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
run() {  # run <label> <cmd...>; report per-check so a red one is attributable without a stopwatch
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

# Lint only the CHANGED shell files — the whole tree is ~9s and a turn rarely touches more than a
# few. A path that no longer exists must not be passed on, hence the -e guard.
# (This comment deliberately does not begin with the tool's name: a comment starting `# shellcheck`
# is parsed as a DIRECTIVE, and this gate rejected itself for it on first run.)
sh_changed=""
while IFS= read -r f; do
  case "$f" in *.sh) [ -e "$f" ] && sh_changed="${sh_changed:+$sh_changed }$f" ;; esac
done <<EOF
$changed
EOF
if [ -n "$sh_changed" ]; then
  # shellcheck disable=SC2086  # deliberate word-split: a space-separated file list
  run shellcheck shellcheck --severity=warning -e SC1091 $sh_changed
fi

# Generated-file drift: the single most common way a turn leaves this repo inconsistent, because
# editing base/ without rebuilding is invisible until CI. `build.sh` is idempotent.
run build-drift bash -c 'bash scripts/build.sh >/dev/null 2>&1 && git diff --quiet -- agents/'
run workflow-render bash scripts/check-workflow-render.sh
run practice-index  bash scripts/check-practice-index.sh
run fact-drift      bash scripts/check-fact-drift.sh

if [ "$fail" -ne 0 ]; then
  printf '\nprecommit-gate: blocking stop — fix the failing check(s) above.\n' >&2
  printf 'precommit-gate: this is the FAST subset; run `bash scripts/selfcheck.sh` before pushing.\n' >&2
  exit 2
fi
exit 0
