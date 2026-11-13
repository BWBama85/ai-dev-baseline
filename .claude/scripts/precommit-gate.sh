#!/usr/bin/env bash
# ai-dev-baseline — THIS REPO'S OWN Stop-hook gate (#240, D25).
#
# The global gate runs whatever `agents.toml [gates]` declares. This repo declares
# `test = "bash scripts/selfcheck.sh"` — its entire offline CI mirror. That is the right command
# for the job CLAUDE.md golden rule 3 gives it (before every PUSH) and the wrong one for a Stop
# hook, which fires at the end of EVERY turn: a run that observed 18m55s during a session that
# edited nothing left the operator no escape but deleting the hook machine-wide.
#
# THAT 18m55s FIGURE IS NOT THE SUITE'S COST. #260 measured the suite rather than repeating the
# number, and a deliberately timed run never came close to nineteen minutes; the 18m55s was real
# but DOES NOT REPRODUCE, and that run was not instrumented, so no cause for it is asserted here.
#
# THE SUITE'S COST IS NOT QUOTED HERE EITHER, and that is the correction #335 forced. This comment
# used to carry a figure D37 measured on 2026-08-03 against a 39-step registry — accurate then,
# wrong within a release, and restated in six files that all went stale together. It has ONE home
# now: CLAUDE.md golden rule 3, dated, beside the reminder that the run prints its own elapsed
# time. (The step COUNT is gone from the first paragraph above for the same reason: it said
# "40-step" against a registry of 49.)
#
# The decision that number justified is unchanged and never depended on its size. One command, two
# cadences, wildly different budgets: the mirror costs minutes per run and a turn-end gate must
# cost seconds, so this gate runs the FAST subset that catches what a turn actually breaks, and the
# full mirror stays where it belongs. Its own cost grows with the BRANCH, not the turn: the lint
# below re-checks every shell file the branch has changed against the default branch. The per-check
# PASS lines print their own seconds; read those, not a figure here (#455, D127).
#
# WHICH LINTS RUN HERE (#630, D156). Every step of selfcheck's static tier is a candidate, and one
# joins when it adds about two seconds or less to a turn on a twenty-file branch, measured unloaded;
# D156 carries the measurements. By that rule: the changed-file shell lint, build-drift,
# workflow-render, practice-index, fact-drift, and since #630 tmp-paths (over the changed files
# only), workflow-shell, claims (the committed range only), bash-floor, workflow-map,
# skill-frontmatter and shmutant-pin. `injection` does NOT run here: it has no changed-file mode and
# measured well over the rule whole-tree, so a finding of its kind is still learned from
# `selfcheck.sh`, where it is in the tier that runs first. Nor does `step-inputs` (#629): in its
# registry form it measured 4.8s, over the rule (D157). `check-precommit-gate.sh` requires every
# static-tier step in the registry to be run here or named as left out, so a lint that joins the
# tier later cannot be missed for want of anyone measuring it.
#
# WHAT THIS DOES NOT COVER, stated rather than implied: everything else `selfcheck.sh` runs — every
# check-*.sh suite, install dry-run, the migration and guard checks, and the `injection` lint. This
# is a turn-end smoke test, NOT a CI predictor. A green here says "you did not obviously break the
# build"; it does not say CI will pass. Run `bash scripts/selfcheck.sh` before you push.
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
  # THIS status is the only one that observes a real load — see the load below, which cannot.
  boot_rc=$?
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
# THE FIRST LOAD IS THE AUTHORITATIVE ONE, and on the healthy path it is the ONLY one. `common.sh`
# opens with a double-source guard (`_ADB_COMMON_SH_LOADED`, :35-38), so once the bootstrap above
# has loaded it this `.` returns 0 through that guard WITHOUT reading the file again — `lib_rc`
# then reports the guard, not the library.
#
# That is not a corner: the bootstrap runs on every ordinary invocation, so `lib_rc` is 0 by
# construction almost always. A `common.sh` truncated AFTER the guard and after the two functions
# this gate needs therefore failed the bootstrap, short-circuited here, satisfied both probes
# (they were defined before the truncation) and ran the whole subset — the promised FATAL never
# firing. Found in review on the PR for #299.
#
# So a non-zero bootstrap status OVERRIDES: either load failing is a failed load. `${boot_rc:-0}`
# because the bootstrap is conditional — when it did not run, this source is a real one and its own
# status is the honest answer.
[ "${boot_rc:-0}" -eq 0 ] || lib_rc="$boot_rc"
[ "$lib_rc" -eq 0 ] || gate_fail_loud "shared library failed to source: scripts/lib/common.sh"
# AND THEN PROBE FOR THE FUNCTION, because the source's status above is necessary and NOT
# SUFFICIENT. A sourced file returns its LAST command's status, so a zero says only that the last
# thing in the file worked — not that the file loaded. A truncated library is precisely the case
# that gap exists for: it sources cleanly, exits 0, and defines nothing at all. Both checks are
# kept because they catch different corruptions (an unsourceable file vs. a sourceable empty one)
# and report different causes.
command -v adb_default_branch >/dev/null 2>&1 \
  || gate_fail_loud "scripts/lib/common.sh loaded but did not define adb_default_branch (corrupt or truncated)"
default_branch="$(adb_default_branch "$repo_root")"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
[ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ] && exit 0

base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
# THE CHANGE SET, NUL-delimited and with EVERY PRODUCER'S STATUS CHECKED (#455, D127): a read that
# failed would shrink the set — to nothing, and the gate would exit 0 having checked nothing. Each
# source is read whole and its status taken from `wait "$!"` (a process substitution reports nothing
# on its own); a failed read BLOCKS, naming it, before the empty-set no-op can be reached.
changed=()
enum_err=""
declare -A _seen=()
for _src in "diff ${base_ref}...HEAD" "diff" "diff --cached" "ls-files --others"; do
  _part=()
  case "$_src" in
    "diff ${base_ref}...HEAD") mapfile -d '' -t _part < <(git diff -z --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null) ;;
    diff)                      mapfile -d '' -t _part < <(git diff -z --no-renames --name-only 2>/dev/null) ;;
    "diff --cached")           mapfile -d '' -t _part < <(git diff -z --no-renames --name-only --cached 2>/dev/null) ;;
    "ls-files --others")       mapfile -d '' -t _part < <(git ls-files -z --others --exclude-standard 2>/dev/null) ;;
  esac
  wait "$!" || { enum_err="${enum_err:+$enum_err; }git $_src failed"; continue; }
  for f in "${_part[@]}"; do
    [ -n "$f" ] && [ -z "${_seen[$f]+x}" ] || continue
    _seen["$f"]=1
    changed+=("$f")
  done
done
if [ -n "$enum_err" ]; then
  printf 'precommit-gate: could not enumerate the changed files (%s) — a partial set is never checked as if whole\n' "$enum_err" >&2
  printf 'precommit-gate: blocking stop — fix the read above, or run `bash scripts/selfcheck.sh` by hand.\n' >&2
  exit 2
fi
[ "${#changed[@]}" -eq 0 ] && exit 0

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
# is parsed as a DIRECTIVE.) Read from the checked, NUL-safe set above, so no name is ever
# word-split.
sh_files=()
for f in "${changed[@]}"; do
  case "$f" in
    *.sh|bin/baseline|bin/agent-init) [ -e "$f" ] && sh_files+=("$f") ;;
  esac
done

# THE LINT IS A POOL (#455): one shellcheck per file across `adb_pool_size` workers, through the same
# `scripts/shellcheck-pool.sh` selfcheck and CI call. The PASS line carries the pool's own count
# line, so a lint over zero files can never read as a pass — and a pool that exits 0 WITHOUT naming
# exactly the files it was given, and a worker count between 1 and that number, is a FAIL.
lint_shell() {
  local t0=$SECONDS out rc last want="${#sh_files[@]}" w
  out="$(printf '%s\0' "${sh_files[@]}" | bash "$repo_root/scripts/shellcheck-pool.sh" -0 2>&1)"; rc=$?
  last="${out##*$'\n'}"
  if [ "$rc" -eq 0 ] && [[ "$last" =~ ^shellcheck-pool:\ ([0-9]+)\ file\(s\),\ ([0-9]+)\ worker\(s\)$ ]]; then
    w="${BASH_REMATCH[2]}"
    if [ "${BASH_REMATCH[1]}" = "$want" ] && [ "$w" -ge 1 ] && [ "$w" -le "$want" ]; then
      printf 'precommit-gate: %-16s PASS (%ss, %s)\n' shellcheck "$(( SECONDS - t0 ))" "${last#shellcheck-pool: }" >&2
      return 0
    fi
  fi
  [ "$rc" -eq 0 ] && out="${out:+$out$'\n'}the pool exited 0 without reporting that it linted the $want file(s) it was given"
  printf 'precommit-gate: %-16s FAIL (%ss)\n%s\n' shellcheck "$(( SECONDS - t0 ))" "$out" >&2
  fail=1
}
if [ "${#sh_files[@]}" -eq 0 ]; then
  :
elif command -v shellcheck >/dev/null 2>&1; then
  lint_shell
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

# No fixed shared-temp path in a CHANGED file (#630): `check-tmp-paths.sh --files`, part 2 of that
# lint over the change set, since the whole-tree run is far over this gate's budget. Its count line
# must account for every file it was handed — a mode that exits 0 having accounted for fewer is a
# FAIL — and a change set with nothing under the lint's four roots is a SKIP that says so, never a
# PASS over nothing.
lint_tmp_paths() {
  local t0=$SECONDS out rc last want="${#changed[@]}"
  out="$(printf '%s\0' "${changed[@]}" | bash "$repo_root/scripts/check-tmp-paths.sh" --files 2>&1)"; rc=$?
  last="${out##*$'\n'}"
  if [ "$rc" -eq 0 ] && [[ "$last" =~ ^check-tmp-paths:\ --files:\ ([0-9]+)\ scanned,\ ([0-9]+)\ out\ of\ scope,\ ([0-9]+)\ gone,\ ([0-9]+)\ binary\ or\ empty$ ]]; then
    if [ "$(( BASH_REMATCH[1] + BASH_REMATCH[2] + BASH_REMATCH[3] + BASH_REMATCH[4] ))" = "$want" ]; then
      if [ "${BASH_REMATCH[1]}" -eq 0 ]; then
        skip tmp-paths "none of the $want changed file(s) is one it scans: a text file under base/, scripts/, docs/ or agents/"
      else
        printf 'precommit-gate: %-16s PASS (%ss, %s scanned of %s changed)\n' tmp-paths "$(( SECONDS - t0 ))" "${BASH_REMATCH[1]}" "$want" >&2
      fi
      return 0
    fi
  fi
  [ "$rc" -eq 0 ] && out="${out:+$out$'\n'}the scan exited 0 without accounting for the $want changed file(s) it was given"
  printf 'precommit-gate: %-16s FAIL (%ss)\n%s\n' tmp-paths "$(( SECONDS - t0 ))" "$out" >&2
  fail=1
}
lint_tmp_paths

run workflow-shell  bash scripts/check-workflow-shell.sh
# The claim lint reads the NET ADDED LINES of a range's diff, merge-base to HEAD. So what it covers
# here is what is committed, not the working tree — said in its line, because a PASS that implied
# more would be a wrong one. The range is this gate's own base, which falls back to the local
# default branch with no remote.
run "claims (commits)" bash scripts/check-claims.sh --range "${base_ref}...HEAD"
run bash-floor      bash scripts/check-bash-floor.sh
# Three more static lints, each asked of the runner by name so it runs exactly as its registry
# step does (two of them exist only as functions there). One step per call, so a red one is named
# by its own line.
for _st in workflow-map skill-frontmatter shmutant-pin; do
  run "$_st" bash scripts/selfcheck.sh --only "$_st"
done

if [ "$fail" -ne 0 ]; then
  printf '\nprecommit-gate: blocking stop — fix the failing check(s) above.\n' >&2
  printf 'precommit-gate: this is the FAST subset; run `bash scripts/selfcheck.sh` before pushing.\n' >&2
  exit 2
fi
exit 0
