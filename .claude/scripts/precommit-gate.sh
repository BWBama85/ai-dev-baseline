#!/usr/bin/env bash
# ai-dev-baseline — THIS REPO'S OWN Stop-hook gate (#240, D25).
#
# The global gate runs whatever `agents.toml [gates]` declares. This repo declares
# `test = "bash scripts/selfcheck.sh"` — its entire 40-step offline CI mirror. That is the right
# command for the job CLAUDE.md golden rule 3 gives it (before every PUSH) and the wrong one for a
# Stop hook, which fires at the end of EVERY turn: a run that observed 18m55s during a session that
# edited nothing left the operator no escape but deleting the hook machine-wide.
#
# THAT 18m55s FIGURE IS NOT THE SUITE'S COST, and #260 measured it rather than repeating it. On the
# maintainer's 10-core machine the pre-#260 sequential suite is 273s and 279s, and the post-#260
# parallel suite is 66-72s; a deliberately timed run never came close to nineteen minutes. The
# 18m55s was real, but what has been demonstrated is that it DOES NOT REPRODUCE — not a cause for
# it. That run was not instrumented, so "the machine was busy" is a guess and is not asserted here;
# it is restated as an observation rather than as the suite's runtime.
#
# The decision it justified is unchanged, and does not need the bigger number. One command, two
# cadences, wildly different budgets: even 66s at the end of every turn is the wrong trade, so this
# gate runs the FAST subset that catches what a turn actually breaks (~3s measured), and the full
# mirror stays where it belongs.
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
# cannot be loaded, that decision stays with the machinery that already owns it.
#
# BUT THE CONDITION IS "DID IT LOAD", NOT "DOES THE FILE EXIST" (#299). A file test alone models a
# MISSING library and misses a CORRUPT one: a truncated common.sh exists, sources, and defines
# nothing, so `adb_require_bash` ran as an undefined command — `command not found` on stderr, its
# 127 discarded, and the gate carried on with the floor silently unenforced. That is the same
# missing-vs-corrupt distinction the load below is about, one site earlier.
#
# `set +u` ACROSS THE SOURCE, for the reason check-precommit-gate.sh already writes down: an
# unbound expansion while a library loads is fatal under `set -u` and kills the shell OUTRIGHT.
# Measured at rc 1 — neither a pass nor this gate's blocking 2 — and no `||` can catch it, because
# the shell is gone before the next word is read. Sourcing is not the place to enforce `set -u`;
# it governs everything this gate actually does.
if [ -f "$(dirname "$0")/../../scripts/lib/common.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../../scripts/lib/common.sh"
  set -u
  command -v adb_require_bash >/dev/null 2>&1 && adb_require_bash "$@"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Default branch via the repo's OWN shared primitive, never a local re-derivation (golden rule 4).
# A hand-rolled `origin/HEAD || main` fallback misreads a clone whose origin/HEAD is unset and
# whose default branch is not named `main` — it would classify the real default branch as a
# feature branch and gate on it. adb_default_branch already models the local main/master fallback
# and is the single home for this decision.
#
# THAT MAKES THE LIBRARY REQUIRED, SO A FAILED LOAD FAILS LOUD (exit 2) — never `exit 0` (#299).
# These two lines used to read `. … || exit 0` and `command -v … || exit 0`, so a missing or
# truncated common.sh made this gate SILENTLY PASS at the end of every turn, in exactly the words
# a clean run uses. Nothing distinguished the two. That is enforcement secretly off — the
# inversion the global gate's `fail_loud` exists to prevent (#35) and the one §5 of
# docs/design-principles.md names outright: "no gates detected" (degrade) and "my own library is
# gone" (fail loud) must never look the same to a caller.
#
# THE PRINTER IS LOCAL, and that is forced rather than a copy of convenience — golden rule 4's
# "source the shared primitive, never copy it" cannot reach here, because the one thing this
# function has to report is that `scripts/lib/common.sh` could not be loaded. A helper for that
# cannot live in that file. The REMEDY differs from the global gate's for the same reason the code
# does: that gate's library is an installed symlink repaired by `baseline update`, while this one
# is a tracked file in this very repo.
gate_fail_loud() {
  printf '\nprecommit-gate: FATAL — %s\n' "$1" >&2
  printf 'This is NOT a pass: the gate could not load its own dependency, so it checked NOTHING,\n' >&2
  printf 'and the turn is BLOCKED. scripts/lib/common.sh is a TRACKED file in this repo — restore\n' >&2
  printf 'it (git status -- scripts/lib/common.sh) and retry.\n' >&2
  exit 2
}
lib_common="$repo_root/scripts/lib/common.sh"
[ -f "$lib_common" ] || gate_fail_loud "shared library not found: scripts/lib/common.sh"
# `set +u` across the source, and the status captured on its OWN line BEFORE `set -u` restores it
# (`set -u` succeeds, which would overwrite `$?` with 0 and report every broken library as clean).
# See the floor block above for why the relaxation is needed at all.
set +u
# shellcheck source=/dev/null
. "$lib_common"
lib_rc=$?
set -u
[ "$lib_rc" -eq 0 ] || gate_fail_loud "shared library failed to source: scripts/lib/common.sh"
# PROBE FOR THE FUNCTION, never the source's exit status: a sourced file returns its LAST
# command's status, so `. lib || …` reports whatever that happened to be and says nothing about
# whether the file loaded. A truncated library is precisely the case that distinction exists for —
# it sources cleanly, exits 0, and defines nothing.
command -v adb_default_branch >/dev/null 2>&1 \
  || gate_fail_loud "scripts/lib/common.sh loaded but did not define adb_default_branch (corrupt or truncated)"
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
