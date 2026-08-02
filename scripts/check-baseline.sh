#!/usr/bin/env bash
# ai-dev-baseline — end-to-end tests for bin/baseline's currency classification.
#
# bin/baseline decides — from a clone's git state — whether it is safe to fast-forward
# the install-source. That decision is the safety-critical part (it must NEVER pull
# over dirty/ahead/diverged/detached/non-default state), so it is exercised here
# against a real clone backed by a LOCAL bare "origin" (file://, no network). Each case
# asserts both the status word `--check` prints and its documented exit code.
#
# `--check` mutates nothing, so these tests never run the installer — a stub install.sh
# in the fixture satisfies bin/baseline's install-source detection without side effects.
#
# Usage: bash scripts/check-baseline.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq + check_summary + check_git / check_make_repo_pair

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- fixture: a minimal but REAL install-source, served from a bare origin ----
# The source carries the FULL claude install surface (root doc, a skill, the three runtime
# scripts, scripts/lib) because bin/baseline now verifies the shared MANIFEST — every intended
# destination must resolve, not just whatever happens to be linked (#48). The fake HOME below
# pre-links that whole surface to represent an "already installed" clone.
seed="$work/seed"
mkdir -p "$seed/bin" "$seed/scripts/lib" "$seed/agents/claude/skills/demo" "$seed/agents/claude/scripts"
cp "$ROOT/bin/baseline" "$seed/bin/baseline"; chmod +x "$seed/bin/baseline"
cp "$ROOT/scripts/lib/common.sh" "$seed/scripts/lib/common.sh"
# bin/baseline only checks install.sh EXISTS (install-source detection); --check never
# runs it. The `update` path DOES run it, so the stub logs its args to a fixed file (baked
# in at creation time, absolute) — tests assert on WHICH agents self-heal invokes it with.
# The stub does NOT create links: the fixture pre-links the surface, and the update-path tests
# below never ADD a new payload (advance_origin only makes empty commits), so no new link is
# ever needed for verify to pass.
printf '#!/usr/bin/env bash\nprintf "install: %%s\\n" "$*" >> "%s"\n' "$work/install.log" > "$seed/install.sh"
chmod +x "$seed/install.sh"
printf 'root doc\n' > "$seed/agents/claude/CLAUDE.md"
printf 'demo skill\n' > "$seed/agents/claude/skills/demo/SKILL.md"
# Derived from the REAL script set, never re-listed here. adb_agent_manifest links every
# agents/claude/scripts/*.sh, so a hand-maintained list silently omits each newly added hook —
# the manifest then expects a link the fixture never made, and every `baseline update` case in
# this file fails for a reason that has nothing to do with what it tests.
ADB_SCRIPTS="$(for f in "$ROOT"/agents/claude/scripts/*.sh; do b="${f##*/}"; printf '%s ' "${b%.sh}"; done)"
for s in $ADB_SCRIPTS; do
  printf '#stub\n' > "$seed/agents/claude/scripts/$s.sh"
done

origin="$work/origin.git"
check_make_repo_pair "$seed" "$origin" || { echo "baseline fixture: repo pair init failed" >&2; exit 1; }
git -C "$seed" symbolic-ref HEAD refs/heads/main
check_git "$seed" add -A
check_git "$seed" commit -q -m seed
git -C "$seed" push -q -u origin main
# Ensure the bare origin's HEAD names main so a clone checks it out cleanly regardless
# of the host git's init.defaultBranch.
git -C "$origin" symbolic-ref HEAD refs/heads/main

# The install-source clone under test, and a fake HOME whose links mirror the FULL manifest
# surface (root doc + skill + every agents/claude/scripts/*.sh + scripts/lib), so manifest verification passes
# on a healthy install. Spelled to match adb_agent_manifest (absolute, no trailing slash).
src="$work/src"; git clone -q "$origin" "$src"
fh="$work/home"; mkdir -p "$fh/.claude/skills" "$fh/.claude/scripts"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/skills/demo" "$fh/.claude/skills/demo"
for s in $ADB_SCRIPTS; do
  ln -s "$src/agents/claude/scripts/$s.sh" "$fh/.claude/scripts/$s.sh"
done
ln -s "$src/scripts/lib" "$fh/.claude/scripts/lib"

# A second clone used to advance origin independently (produces behind/diverged).
c2="$work/c2"; git clone -q "$origin" "$c2"
advance_origin() { check_git "$c2" fetch -q origin; check_git "$c2" reset -q --hard origin/main; check_git "$c2" commit -q --allow-empty -m "$1"; check_git "$c2" push -q origin main; }

# Return src to a clean checkout of the current origin/main tip (baseline of each case).
reset_src() {
  git -C "$src" checkout -q main 2>/dev/null || git -C "$src" checkout -q -B main
  git -C "$src" fetch -q origin
  git -C "$src" reset -q --hard origin/main
  git -C "$src" clean -qfd
}

# run_check <baseline-exe> <home> -> "<status-word>|<exit-code>"
run_check() {
  local out rc
  out="$(HOME="$2" "$1" update --check 2>/dev/null)"; rc=$?
  printf '%s|%s' "$out" "$rc"
}

# run_update <baseline-exe> <home> -> "<exit-code>"  (the mutating `update` path)
run_update() {
  local rc
  HOME="$2" "$1" update >/dev/null 2>&1; rc=$?
  printf '%s' "$rc"
}

# --- cases -------------------------------------------------------------------

# current: clean, on main, up to date with origin.
reset_src
eq "$(run_check "$src/bin/baseline" "$fh")" "current|0" "current"

# behind: origin advances; src stays put (baseline's own fetch sees the gap).
reset_src
advance_origin "origin-ahead-1"
eq "$(run_check "$src/bin/baseline" "$fh")" "behind|10" "behind"

# dirty: an uncommitted change must block, before any branch reasoning.
reset_src
printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md"
eq "$(run_check "$src/bin/baseline" "$fh")" "dirty|20" "dirty"

# ahead: an unpushed local commit, origin unchanged.
reset_src
check_git "$src" commit -q --allow-empty -m local-only
eq "$(run_check "$src/bin/baseline" "$fh")" "ahead|20" "ahead"

# diverged: unique commits on both sides.
reset_src
check_git "$src" commit -q --allow-empty -m local-div
advance_origin "origin-div"
eq "$(run_check "$src/bin/baseline" "$fh")" "diverged|20" "diverged"

# detached HEAD.
reset_src
git -C "$src" checkout -q --detach HEAD
eq "$(run_check "$src/bin/baseline" "$fh")" "detached|20" "detached"

# not-default: on a feature branch.
reset_src
git -C "$src" checkout -q -b feature-y
eq "$(run_check "$src/bin/baseline" "$fh")" "not-default|20" "not-default"

# in-progress: a mid-operation clone with a CLEAN tree — the case `git status --porcelain` and
# the detached-HEAD test both miss. Each sentinel git itself writes must be recognized, because
# fast-forwarding into a half-finished merge/rebase/cherry-pick is the worst possible moment.
gitdir="$(git -C "$src" rev-parse --absolute-git-dir)"
for sentinel in rebase-merge/ rebase-apply/ sequencer/ MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  reset_src
  case "$sentinel" in
    */) mkdir -p "$gitdir/${sentinel%/}" ;;
    *)  printf '%s\n' "$(git -C "$src" rev-parse HEAD)" > "$gitdir/$sentinel" ;;
  esac
  eq "$(run_check "$src/bin/baseline" "$fh")" "in-progress|20" "in-progress ($sentinel)"
  rm -rf "${gitdir:?}/${sentinel%/}"
done

# Unsafe local state must be classified WITHOUT a fetch: `--check` documents itself as changing
# nothing, and the SessionStart hook must not pay a network round trip on a clone it will refuse.
# Proven by pointing origin at a path that cannot be fetched — a run that reached the network
# would report the fetch error (exit 30) instead of the local verdict.
reset_src
printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md"
git -C "$src" remote set-url origin "$work/no-such-origin.git"
eq "$(run_check "$src/bin/baseline" "$fh")" "dirty|20" "dirty is classified before any fetch"
git -C "$src" remote set-url origin "$origin"
reset_src

# The update lock serializes the mutating path: a held lock makes a second update step aside
# with exit 5 rather than racing the first through pull + install (several sessions can start
# at once now that a SessionStart hook triggers this).
reset_src
advance_origin "lock-case"
mkdir -p "$gitdir/adb-update.lock"
head_locked="$(git -C "$src" rev-parse HEAD)"
eq "$(run_update "$src/bin/baseline" "$fh")" "5" "a held update lock exits 5"
eq "$(git -C "$src" rev-parse HEAD)" "$head_locked" "a locked-out update changes nothing"
rmdir "$gitdir/adb-update.lock"
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "the update proceeds once the lock is released"
if [ -d "$gitdir/adb-update.lock" ]; then bad "the lock must be released on exit"; else ok; fi

# A STALE lock (older than the bound) whose holder is GONE is broken rather than blocking
# forever — a killed updater must not lock every future session out. Aged with `touch` rather
# than by waiting, and against the REAL default bound rather than a degenerate 0.
reset_src
advance_origin "stale-lock-case"
mkdir -p "$gitdir/adb-update.lock"
touch -t 202001010000 "$gitdir/adb-update.lock"
head_stale="$(git -C "$src" rev-parse HEAD)"
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "a stale lock with no live holder is broken"
if [ "$(git -C "$src" rev-parse HEAD)" != "$head_stale" ]; then ok; else bad "a stale-locked update should proceed"; fi
rm -rf "$gitdir/adb-update.lock"

# …but AGE ALONE IS NOT DEATH. A laptop suspended mid-update, or a manual run behind a slow
# fetch, is old and perfectly alive; breaking that lock runs `git pull` + `install.sh` twice at
# once, which is the thing the lock exists to prevent. An old lock whose recorded pid is STILL
# ALIVE must therefore be obeyed. ($$ of this test is alive by construction.)
reset_src
advance_origin "live-holder-case"
mkdir -p "$gitdir/adb-update.lock"
printf '%s 1577836800\n' "$$" > "$gitdir/adb-update.lock/owner"
touch -t 202001010000 "$gitdir/adb-update.lock"
head_live="$(git -C "$src" rev-parse HEAD)"
eq "$(run_update "$src/bin/baseline" "$fh")" "5" "an OLD lock with a LIVE holder is still obeyed"
eq "$(git -C "$src" rev-parse HEAD)" "$head_live" "a live-holder lock blocks the pull"
rm -rf "$gitdir/adb-update.lock"

# A FUTURE-dated lock (clock skew) must never be judged stale: a negative age would compare as
# "not older than the bound" only by luck, and a caller reading it as a small number would break
# a live lock. adb_age_secs reports future mtimes as unknown, and an undatable lock is obeyed.
reset_src
advance_origin "future-lock-case"
mkdir -p "$gitdir/adb-update.lock"
touch -t 209901010000 "$gitdir/adb-update.lock"
head_future="$(git -C "$src" rev-parse HEAD)"
eq "$(run_update "$src/bin/baseline" "$fh")" "5" "a future-dated lock is never judged stale"
eq "$(git -C "$src" rev-parse HEAD)" "$head_future" "a future-dated lock blocks the pull"
rm -rf "$gitdir/adb-update.lock"

# RELEASE IS OWNERSHIP-SCOPED. Once a peer has stale-broken our lock and taken it, our exit must
# NOT remove the peer's lock — doing so would let a THIRD mutator in while the peer is mid-pull.
# Simulated directly against the primitives: take the lock, replace it with a peer's (a different
# owner token), then release and require the peer's lock to survive.
reset_src
mkdir -p "$work/lockprobe"
probe_lock="$work/lockprobe/adb-update.lock"
# shellcheck source=/dev/null
( . "$ROOT/scripts/lib/common.sh"
  # Pull in just the lock primitives from bin/baseline without running its main flow.
  eval "$(sed -n '/^_ADB_LOCK_TOKEN=""/,/^}/p;/^_adb_take_lock()/,/^}/p;/^adb_update_lock()/,/^}/p;/^adb_update_unlock()/,/^}/p' "$ROOT/bin/baseline")"
  _ADB_LOCK_STALE_SECS=600
  adb_update_lock "$probe_lock" || exit 1
  rm -rf "$probe_lock"                                  # peer breaks it …
  mkdir -p "$probe_lock"; printf '99999 1\n' > "$probe_lock/owner"   # … and takes it
  adb_update_unlock "$probe_lock"                        # our exit path runs
  [ -d "$probe_lock" ] || exit 2                         # the peer must still hold it
) && ok || bad "release must not remove a lock another process now owns"
rm -rf "$work/lockprobe"

# wrong-clone guard: invoking THIS repo's baseline (a different clone) against an
# install that points at src must refuse with exit 4, before any classification.
reset_src
HOME="$fh" "$ROOT/bin/baseline" update --check >/dev/null 2>&1; rc=$?
eq "$rc" "4" "wrong-clone guard exits 4"

# no install detected: an empty HOME has no root-doc symlink → exit 3.
empty="$work/emptyhome"; mkdir -p "$empty"
HOME="$empty" "$src/bin/baseline" update --check >/dev/null 2>&1; rc=$?
eq "$rc" "3" "no-install exits 3"

# update (current + all links resolve) → "nothing to do", exit 0.
reset_src
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "update current + healthy links exits 0"

# --- hook state is the OTHER half of "is the installed surface right?" (#242) ------------------
# `current` + healthy links used to exit 0 without ever consulting the hook wiring, so a PARTIAL
# set — the state an operator lands in by removing one expensive hook — was never reported and
# never repaired. The three-state classifier was correct and unreachable on this path.
# The shipped hook list comes from the manifest in common.sh, never a hand-written copy here: a
# list re-typed in the test would keep passing after a hook is added to the real set, which is the
# same drift #242 is about. (Sourced only for this helper; every assertion still runs bin/baseline
# as a subprocess with its own environment.)
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/common.sh"

hook_settings() {   # hook_settings <state>: write a settings.json in the fixture HOME
  local state="$1" s out=""
  case "$state" in
    none) printf '{"hooks":{}}\n' > "$fh/.claude/settings.json"; return ;;
  esac
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    # `partial` omits precommit-gate.sh — the exact edit that motivated #242.
    [ "$state" = partial ] && [ "$s" = "precommit-gate.sh" ] && continue
    out="${out}$fh/.claude/scripts/$s
"
  done <<HS
$(adb_claude_hook_scripts)
HS
  printf '%s' "$out" > "$fh/.claude/settings.json"
}

reset_src; : > "$work/install.log"; hook_settings wired
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "hooks wired → nothing to do (exit 0)"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "0" "hooks wired → the installer is not re-run"

# `none` is the opt-out and must be honoured.
reset_src; : > "$work/install.log"; hook_settings none
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "hooks none (opt-out) → nothing to do (exit 0)"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "0" "hooks none → the opt-out is not overruled"

# PARTIAL is REPORTED, never repaired. Removing one hook's entry is the DOCUMENTED way to disable
# that hook (docs/installation.md), so re-wiring would destroy a supported configuration — and the
# SessionStart currency hook survives a per-hook removal, so it would be destroyed again next
# session. #242 was that `partial` was indistinguishable from `none` and silent, not unrepaired.
reset_src; : > "$work/install.log"; hook_settings partial
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "hooks PARTIAL → reported, still exit 0 (no false repair)"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "0" "hooks PARTIAL → the installer is NOT re-run"
# NOT asserted here: that settings.json still lacks the hook. The fixture's install.sh is a stub
# that only logs its argv — it cannot wire anything — so such a check could never fail and would
# be a guard that reports safety it never verified. "The installer is not re-run" above is the
# real proof: nothing else in this path can rewrite settings.json.

# Visibility IS the fix, so assert the operator can see it — including the residue.
reset_src; hook_settings partial
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1 || true)"
has "$out" "PARTIAL" "hooks partial → the run says so out loud"
has "$out" "precommit-gate.sh" "hooks partial → the run names the hook that is not wired"
has "$out" "newly shipped hook is not wired" "hooks partial → the run states the residue, not just the state"
rm -f "$fh/.claude/settings.json"


# update with a renamed-away ORPHAN (a dangling link into src, no manifest entry) must be
# PRUNED, not fatal: baseline removes the ownership-scoped dead link and completes (exit 0),
# then a second update is an idempotent no-op (#48).
reset_src
mkdir -p "$fh/.claude/skills"
ln -s "$src/agents/claude/skills/ghost" "$fh/.claude/skills/ghost"   # target does not exist
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "update prunes a renamed-away orphan (exit 0)"
if [ -L "$fh/.claude/skills/ghost" ]; then bad "orphaned link should have been pruned"; else ok; fi
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "second update after prune is an idempotent no-op (exit 0)"

# prune is STRICTLY ownership-scoped: it must NEVER remove a still-resolving owned link, a
# dangling link that points ELSEWHERE (not ours), or a real file that lives in a scanned
# namespace. Stage all three, run update, and assert each survives untouched (#48).
reset_src
outside="$work/outside"; mkdir -p "$outside"
ln -s "$outside/gone" "$fh/.claude/skills/foreign"    # dangles, but NOT into src → not ours
printf 'realfile\n' > "$fh/.claude/scripts/keepme"    # a real file in a scanned namespace
run_update "$src/bin/baseline" "$fh" >/dev/null
if [ -L "$fh/.claude/skills/demo" ] && [ -e "$fh/.claude/skills/demo" ]; then ok; else bad "prune kept the resolving owned link"; fi
if [ -L "$fh/.claude/skills/foreign" ]; then ok; else bad "prune must not remove a dangling NON-ours link"; fi
if [ -f "$fh/.claude/scripts/keepme" ]; then ok; else bad "prune must never delete a real file"; fi
rm -f "$fh/.claude/skills/foreign" "$fh/.claude/scripts/keepme"

# A manifest destination occupied by a NON-symlink (or a link NOT into src) must be treated as
# BROKEN, not "healthy" just because the path exists: verify requires each dest to be OUR symlink
# into the source (adb_link's guard can leave a stale pre-existing dest when a source is missing).
# The stub install.sh can't repair it, so the run must be LOUD (exit 1), never a false "nothing to
# do" that skips re-linking (#48, PR #51 review).
reset_src
rm -f "$fh/.claude/scripts/statusline.sh"
printf 'not a link\n' > "$fh/.claude/scripts/statusline.sh"   # a real file shadowing a manifest dest
eq "$(run_update "$src/bin/baseline" "$fh")" "1" "verify rejects a manifest dest that is not our symlink into src"
rm -f "$fh/.claude/scripts/statusline.sh"
ln -s "$src/agents/claude/scripts/statusline.sh" "$fh/.claude/scripts/statusline.sh"   # restore canonical link

# wrong-clone guard must NOT false-trip on a symlinked-path spelling of the SAME clone
# (physical-path comparison via pwd -P) — regression guard for the bug review's finding.
reset_src
aliasdir="$work/alias-src"; ln -s "$src" "$aliasdir"
eq "$(run_check "$aliasdir/bin/baseline" "$fh")" "current|0" "symlinked-path spelling is not treated as wrong-clone"

# The mutating `update` path must also REFUSE ahead state and preserve the local commit
# (the no-data-loss invariant on the write path, not just --check).
reset_src
check_git "$src" commit -q --allow-empty -m local-only-2
head_before="$(git -C "$src" rev-parse HEAD)"
eq "$(run_update "$src/bin/baseline" "$fh")" "20" "update refuses ahead (exit 20)"
eq "$(git -C "$src" rev-parse HEAD)" "$head_before" "update preserves HEAD when ahead"

# A `behind` update must ALWAYS re-run the installer (a pulled commit can add a new skill
# that pre-existing links don't cover) — not skip it just because existing links resolve.
reset_src
advance_origin "adds-a-payload"
: > "$work/install.log"
eq "$(run_update "$src/bin/baseline" "$fh")" "0" "update behind exits 0"
[ -s "$work/install.log" ] && ok || bad "update behind re-runs install.sh (thread 4)"

# self-heal must install ONLY agents whose root doc points into this source — an unrelated
# ~/.codex symlink pointing elsewhere must be left untouched (not backed-up + replaced).
reset_src
advance_origin "another-commit"
mkdir -p "$fh/.codex" "$work/other"
ln -s "$work/other/AGENTS.md" "$fh/.codex/AGENTS.md"   # unrelated install, outside src
: > "$work/install.log"
run_update "$src/bin/baseline" "$fh" >/dev/null
grep -q -- '--agent claude' "$work/install.log" && ok || bad "self-heal installs claude"
grep -q -- '--agent codex' "$work/install.log" && bad "self-heal must not touch unrelated codex symlink (thread 2)" || ok
rm -rf "$fh/.codex"

# A DANGLING root-doc link (the doc path itself moved) must still resolve the source and
# run — not report "no installed baseline". Point claude's doc at a missing file in src.
rm -f "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/CLAUDE-moved.md" "$fh/.claude/CLAUDE.md"   # target missing; clone intact
reset_src
eq "$(run_check "$src/bin/baseline" "$fh")" "current|0" "dangling root-doc still resolves the source (thread 3)"

# Prune must NEVER remove an agent ROOT-DOC link, even a dangling one: it lives at a fixed path
# that DETECTS the install (and resolves the source), so a dangling root doc is surfaced loudly,
# never silently pruned. Run the mutating path and assert the link survives (#48).
run_update "$src/bin/baseline" "$fh" >/dev/null 2>&1
if [ -L "$fh/.claude/CLAUDE.md" ]; then ok; else bad "prune must never remove a (dangling) root-doc link"; fi
rm -f "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"   # restore canonical link

check_summary "baseline"
