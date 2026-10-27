#!/usr/bin/env bash
# ai-dev-baseline — end-to-end tests for bin/baseline's currency classification.
#
# bin/baseline decides — from a clone's git state — whether it is safe to fast-forward
# the install-source. That decision is the safety-critical part (it must NEVER pull
# over dirty/ahead/diverged/detached/non-default state), so it is exercised here
# against a real clone backed by a LOCAL bare "origin" (file://, no network). Each case
# asserts both the status word `--check` prints and its documented exit code.
#
# Most cases use a stub install.sh that only logs its argv, so they assert what the update
# DECIDES. The #539 rows at the end install a copy of this tree with the REAL install.sh into
# scratch homes, because what they assert is that a link was actually re-made.
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

# Every row above the release-channel section runs on `channel = "main"` — the pre-#534 behaviour,
# which that channel keeps exactly. The release-channel rows unset this and say so.
export ADB_UPDATE_CHANNEL=main

# --- fixture: a minimal but REAL install-source, served from a bare origin ----
# The source carries the FULL claude install surface (root doc, a skill, the three runtime
# scripts, scripts/lib) because bin/baseline now verifies the shared MANIFEST — every intended
# destination must resolve, not just whatever happens to be linked (#48). The fake HOME below
# pre-links that whole surface to represent an "already installed" clone.
seed="$work/seed"
mkdir -p "$seed/bin" "$seed/scripts/lib" "$seed/agents/claude/skills/demo" "$seed/agents/claude/scripts"
cp "$ROOT/bin/baseline" "$seed/bin/baseline"; chmod +x "$seed/bin/baseline"
# currency-lib.sh too: the release-channel rows drive the currency trigger against this clone.
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/currency-lib.sh" "$seed/scripts/lib/"
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
# ONE manifest destination, derived rather than named, for the "a dest that is not our symlink"
# case far below. A hardcoded basename here was orphaned by a retirement once (#378, D73); taking
# the first of the real set means the next one does not repeat it.
PROBE_SCRIPT="${ADB_SCRIPTS%% *}.sh"

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
eq "${ run_check "$src/bin/baseline" "$fh"; }" "current|0" "current"

# behind: origin advances; src stays put (baseline's own fetch sees the gap).
reset_src
advance_origin "origin-ahead-1"
eq "${ run_check "$src/bin/baseline" "$fh"; }" "behind|10" "behind"

# dirty: an uncommitted change must block, before any branch reasoning.
reset_src
printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md"
eq "${ run_check "$src/bin/baseline" "$fh"; }" "dirty|20" "dirty"

# ahead: an unpushed local commit, origin unchanged.
reset_src
check_git "$src" commit -q --allow-empty -m local-only
eq "${ run_check "$src/bin/baseline" "$fh"; }" "ahead|20" "ahead"

# diverged: unique commits on both sides.
reset_src
check_git "$src" commit -q --allow-empty -m local-div
advance_origin "origin-div"
eq "${ run_check "$src/bin/baseline" "$fh"; }" "diverged|20" "diverged"

# detached HEAD. On the main channel a detached clone on origin's history is re-attached (#534 — a
# release-channel install switched back to main), so it reads `behind`; detached OFF origin's
# history is still refused.
reset_src
git -C "$src" checkout -q --detach HEAD
eq "${ run_check "$src/bin/baseline" "$fh"; }" "behind|10" "detached on origin's history (channel main) → behind, to re-attach"
reset_src
git -C "$src" checkout -q --detach HEAD
check_git "$src" commit -q --allow-empty -m detached-local
eq "${ run_check "$src/bin/baseline" "$fh"; }" "detached|20" "detached off origin's history (channel main) → detached"

# not-default: on a feature branch.
reset_src
git -C "$src" checkout -q -b feature-y
eq "${ run_check "$src/bin/baseline" "$fh"; }" "not-default|20" "not-default"

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
  eq "${ run_check "$src/bin/baseline" "$fh"; }" "in-progress|20" "in-progress ($sentinel)"
  rm -rf "${gitdir:?}/${sentinel%/}"
done

# Unsafe local state must be classified WITHOUT a fetch: `--check` documents itself as changing
# nothing, and the SessionStart hook must not pay a network round trip on a clone it will refuse.
# Proven by pointing origin at a path that cannot be fetched — a run that reached the network
# would report the fetch error (exit 30) instead of the local verdict.
reset_src
printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md"
git -C "$src" remote set-url origin "$work/no-such-origin.git"
eq "${ run_check "$src/bin/baseline" "$fh"; }" "dirty|20" "dirty is classified before any fetch"
git -C "$src" remote set-url origin "$origin"
reset_src

# The update lock serializes the mutating path: a held lock makes a second update step aside
# with exit 5 rather than racing the first through pull + install (several sessions can start
# at once now that a SessionStart hook triggers this).
reset_src
advance_origin "lock-case"
mkdir -p "$gitdir/adb-update.lock"
head_locked="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "5" "a held update lock exits 5"
eq "$(git -C "$src" rev-parse HEAD)" "$head_locked" "a locked-out update changes nothing"
rmdir "$gitdir/adb-update.lock"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "the update proceeds once the lock is released"
if [ -d "$gitdir/adb-update.lock" ]; then bad "the lock must be released on exit"; else ok; fi
# …and a held lock still refuses when `mkdir` reports success for it, as Ubuntu 26.04's uutils mkdir
# does under contention (#473, D105).
reset_src
advance_origin "lock-uutils"
adb_mkdir_excl "$gitdir/adb-update.lock" || bad "fixture: could not take the update lock"
check_mkdir_shim "$work/uutils-shim" || bad "fixture: the non-exclusive mkdir shim could not be written"
head_locked="$(git -C "$src" rev-parse HEAD)"
eq "${ PATH="$work/uutils-shim:$PATH" run_update "$src/bin/baseline" "$fh"; }" "5" "a held update lock exits 5 behind a non-exclusive mkdir"
eq "$(git -C "$src" rev-parse HEAD)" "$head_locked" "…and changes nothing"
adb_rmdir_excl "$gitdir/adb-update.lock"

# A STALE lock (older than the bound) whose holder is GONE is broken rather than blocking
# forever — a killed updater must not lock every future session out. Aged with `touch` rather
# than by waiting, and against the REAL default bound rather than a degenerate 0.
reset_src
advance_origin "stale-lock-case"
mkdir -p "$gitdir/adb-update.lock"
touch -t 202001010000 "$gitdir/adb-update.lock"
head_stale="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "a stale lock with no live holder is broken"
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
eq "${ run_update "$src/bin/baseline" "$fh"; }" "5" "an OLD lock with a LIVE holder is still obeyed"
eq "$(git -C "$src" rev-parse HEAD)" "$head_live" "a live-holder lock blocks the pull"
rm -rf "$gitdir/adb-update.lock"

# …AND A HOLDER WE MAY NOT SIGNAL IS NOT A DEAD ONE (D132): pid 1 is EPERM for a non-root run, and
# alive either way.
reset_src
advance_origin "eperm-holder-case"
mkdir -p "$gitdir/adb-update.lock"
printf '1 1577836800\n' > "$gitdir/adb-update.lock/owner"
touch -t 202001010000 "$gitdir/adb-update.lock"
head_eperm="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "5" "an OLD lock whose holder we may not signal is still obeyed"
eq "$(git -C "$src" rev-parse HEAD)" "$head_eperm" "…and blocks the pull"
rm -rf "$gitdir/adb-update.lock"
# …while a holder the kernel reports gone (ESRCH) is still broken.
reset_src
advance_origin "dead-holder-case"
mkdir -p "$gitdir/adb-update.lock"
printf '%s 1577836800\n' "$( sleep 0 & p=$!; wait "$p"; printf '%s' "$p" )" > "$gitdir/adb-update.lock/owner"
touch -t 202001010000 "$gitdir/adb-update.lock"
head_dead="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "an OLD lock whose recorded holder is gone is broken"
if [ "$(git -C "$src" rev-parse HEAD)" != "$head_dead" ]; then ok; else bad "a dead-holder lock should let the update proceed"; fi
rm -rf "$gitdir/adb-update.lock"

# A FUTURE-dated lock (clock skew) must never be judged stale: a negative age would compare as
# "not older than the bound" only by luck, and a caller reading it as a small number would break
# a live lock. adb_age_secs reports future mtimes as unknown, and an undatable lock is obeyed.
reset_src
advance_origin "future-lock-case"
mkdir -p "$gitdir/adb-update.lock"
touch -t 209901010000 "$gitdir/adb-update.lock"
head_future="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "5" "a future-dated lock is never judged stale"
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
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "update current + healthy links exits 0"

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
  local -a hooks=()
  mapfile -t hooks < <(adb_claude_hook_scripts)
  case "$state" in
    # `none`: every entry removed by the operator — the receipt still lists them all.
    none) printf '{"hooks":{}}\n' > "$fh/.claude/settings.json"; adb_claude_hook_scripts > "$(adb_claude_hooks_receipt "$fh")"; return ;;
  esac
  # Guarded like the other three enumerations (#259, review finding). Without this, an
  # enumerator that returned nothing would write an EMPTY settings.json and iterate zero hooks —
  # so the `wired` fixture would silently become the `none` fixture, and the cases below would
  # still pass while testing the opposite state.
  check_enumerated "adb_claude_hook_scripts (hook_settings $state)" "${hooks[@]}" || return 1
  # THE REAL SHAPE (PR #443 review): the predicates validate event, matcher and handler type, so
  # the fixture is the shipped table with the omitted hooks' handlers deleted — and a RECEIPT of
  # what an earlier wiring wrote, which is what makes a removal deliberate and a new hook new.
  local drop='[]' receipt
  case "$state" in
    # `partial` omits precommit-gate.sh — the exact edit that motivated #242.
    partial) drop='["precommit-gate.sh"]' ;;
    # `shipped` omits session-context.sh — the shape an upgrade produces when a NEW hook lands
    # (PR #443 review): no entry yet, and (the case below removes it) no script link yet either.
    shipped) drop='["session-context.sh"]' ;;
    # `mixed` omits BOTH: one deliberate removal plus one newly shipped hook (#444's shape).
    mixed)   drop='["precommit-gate.sh","session-context.sh"]' ;;
  esac
  printf '{"hooks":%s}\n' "$(sed "s@__ADB_HOME__@$fh@g" "$ROOT/agents/claude/settings.hooks.json")" \
    | jq --argjson drop "$drop" '.hooks |= with_entries(.value |= (map(.hooks |= map(select(.command as $c | ($drop | any(. as $d | $c | endswith("/" + $d))) | not))) | map(select(.hooks | length > 0))))' \
    > "$fh/.claude/settings.json"
  # The receipt: every hook the last successful wiring wrote. For `shipped`/`mixed` that wiring
  # predates session-context.sh, so it is absent from the receipt (never wired); for `partial` it
  # lists precommit-gate.sh (wired once, removed since).
  receipt="$(adb_claude_hooks_receipt "$fh")"; : > "$receipt"
  for s in "${hooks[@]}"; do
    case "$state" in shipped|mixed) [ "$s" = "session-context.sh" ] && continue ;; esac
    printf '%s\n' "$s" >> "$receipt"
  done
}

reset_src; : > "$work/install.log"; hook_settings wired
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "hooks wired → nothing to do (exit 0)"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "0" "hooks wired → the installer is not re-run"

# `none` is the opt-out and must be honoured.
reset_src; : > "$work/install.log"; hook_settings none
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "hooks none (opt-out) → nothing to do (exit 0)"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "0" "hooks none → the opt-out is not overruled"

# `none` WITH NO OWNED LINKS AT ALL is not an opt-out but an install that never wired (a first
# install without jq takes its links back) — the repair runs WITHOUT --no-hooks so the hooks
# arrive once jq does (PR #443 review). Driven through the behind path, where the self-heal runs.
reset_src; advance_origin "never-wired"; : > "$work/install.log"; hook_settings none; rm -f "$(adb_claude_hooks_receipt "$fh")"
mkdir -p "$work/saved-hooks"; for s in $(adb_claude_hook_scripts); do mv "$fh/.claude/scripts/$s" "$work/saved-hooks/$s"; done
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1 || true
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "1" "hooks none + no owned links → the installer runs (never wired is a broken install)"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks none + no owned links → ...WITHOUT --no-hooks: nothing was ever removed by hand"
for s in $(adb_claude_hook_scripts); do mv "$work/saved-hooks/$s" "$fh/.claude/scripts/$s"; done
rm -f "$fh/.claude/settings.json"

# AN UNREADABLE RECEIPT NEVER WIDENS THE INSTALL (#444 review). `none` keeps --no-hooks, since the
# opt-out cannot be told from a never-wired install without it; `partial` says why a repair will
# refuse rather than guess (install.sh aborts on it — check-session-currency.sh). A directory stands
# in for the unreadable receipt. `none` is driven through the behind path, where the self-heal runs.
reset_src; advance_origin "unreadable-receipt"; : > "$work/install.log"; hook_settings none
rm -f "$(adb_claude_hooks_receipt "$fh")"; mkdir "$(adb_claude_hooks_receipt "$fh")"
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1 || true
has "$(cat "$work/install.log")" "--no-hooks" "hooks none + unreadable receipt → the opt-out is kept (--no-hooks)"
rmdir "$(adb_claude_hooks_receipt "$fh")"
reset_src; hook_settings partial
rm -f "$(adb_claude_hooks_receipt "$fh")"; mkdir "$(adb_claude_hooks_receipt "$fh")"
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1 || true)"
has "$out" "cannot be read" "hooks partial + unreadable receipt → the run says the receipt cannot be read"
hasnt "$out" "newly shipped hook(s) not yet wired" "hooks partial + unreadable receipt → ...and never calls the removed hook newly shipped"
rmdir "$(adb_claude_hooks_receipt "$fh")"
rm -f "$fh/.claude/settings.json"

# AN INSTALLER KILLED BETWEEN THE LINK AND THE ENTRY leaves an owned link with no entry — the
# opt-out's shape — and only the receipt can say it was never wired (PR #443 review): the receipt
# does not list session-context.sh, its link exists, its entry does not → repaired, not preserved.
reset_src; advance_origin "killed-mid-wire"; : > "$work/install.log"; hook_settings shipped
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1 || true)"
has "$out" "newly shipped hook(s) not yet wired" "hooks linked-but-unwired with no receipt line → read as not yet wired, not as an opt-out"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks linked-but-unwired with no receipt line → the installer runs WITHOUT --no-hooks"
rm -f "$fh/.claude/settings.json"

# PARTIAL is REPORTED, never repaired. Removing one hook's entry is the DOCUMENTED way to disable
# that hook (docs/installation.md), so re-wiring would destroy a supported configuration — and the
# SessionStart currency hook survives a per-hook removal, so it would be destroyed again next
# session. #242 was that `partial` was indistinguishable from `none` and silent, not unrepaired.
reset_src; : > "$work/install.log"; hook_settings partial
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "hooks PARTIAL → reported, still exit 0 (no false repair)"
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
has "$out" "wires every other one, a newly shipped one included" "hooks partial → the run says the opt-out costs no other hook"
hasnt "$out" "newly shipped hook is not wired" "hooks partial → ...and no longer states a residue that is gone (#444)"
rm -f "$fh/.claude/settings.json"

# NEWLY SHIPPED IS NOT AN OPT-OUT (PR #443 review). A hook with neither an entry nor a script link
# was shipped after the last install; reading that `partial` as a per-hook removal passed
# `--no-hooks` to the repair, which linked the script and never wired it — for good, since
# nothing afterwards distinguishes the result from a choice. The missing link is a broken install,
# so the repair runs, and it must run WITHOUT --no-hooks so the hook is wired.
reset_src; : > "$work/install.log"; hook_settings shipped
mv "$fh/.claude/scripts/session-context.sh" "$work/saved-hook-link"
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1 || true)"
has "$out" "newly shipped hook(s) not yet wired" "hooks newly shipped → reported as shipped, not as an opt-out"
hasnt "$out" "deliberate per-hook opt-out" "hooks newly shipped → ...and not as the opt-out residue"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "1" "hooks newly shipped → the installer IS re-run (the missing link is a broken install)"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks newly shipped → ...WITHOUT --no-hooks, so the new hook gets wired"
mv "$work/saved-hook-link" "$fh/.claude/scripts/session-context.sh"
rm -f "$fh/.claude/settings.json"

# THE MIXED SET (#444): a deliberate removal (precommit-gate.sh, which the receipt lists) AND a hook
# shipped since the last install (session-context.sh, which it does not). The repair must not pass
# --no-hooks, which suppressed the new hook too, but --optout-if-recorded, under which install.sh
# skips exactly the removed hooks. check-session-currency.sh drives that half with the real
# installer and the real-installer rows below drive the whole update; this stub creates no links,
# so the new hook's link is left in place and what is asserted is the decision.
# THE BEHIND PATH, because that is where the mixed state is first produced (an upgrade pulls the hook).
reset_src; advance_origin "ships-a-hook"; : > "$work/install.log"; hook_settings mixed
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1)"; rc=$?
eq "$rc" 0 "hooks mixed (behind) → the update completes (exit 0)"
has "$(cat "$work/install.log")" "--optout-if-recorded" "hooks mixed → the repair asks install.sh to honour the recorded opt-outs"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks mixed → ...and does not pass --no-hooks, which would suppress the new hook too"
has "$out" "kept as your per-hook opt-out: precommit-gate.sh "$'\n' "hooks mixed → only the hook removed by hand is named as the opt-out"
has "$out" "Not removed by hand, so the next self-heal wires them: session-context.sh" "hooks mixed → ...and the new hook is named as one the update wires"
hasnt "$out" "left UNLINKED" "hooks mixed → the new hook is not left unlinked"
rm -f "$fh/.claude/settings.json"

# A NEW HOOK WHOSE LINK IS ABSENT beside the opt-out — the state the pre-#444 stopgap left on
# purpose — is a broken link, so the update repairs it rather than tolerating it as deferred. The
# stub cannot wire it, so this run ends "repair failed"; the real-installer rows show it repaired.
reset_src; : > "$work/install.log"; hook_settings mixed
mv "$fh/.claude/scripts/session-context.sh" "$work/saved-hook-link"
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1)"
has "$out" "unresolved): $fh/.claude/scripts/session-context.sh" "hooks mixed, new hook unlinked → reported BROKEN, not tolerated as deferred"
hasnt "$out" "deferred" "hooks mixed, new hook unlinked → ...and never called deferred"
eq "$(wc -l < "$work/install.log" | tr -d ' ')" "1" "hooks mixed, new hook unlinked → ...so the repair runs"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks mixed, new hook unlinked → ...without --no-hooks"
mv "$work/saved-hook-link" "$fh/.claude/scripts/session-context.sh"
rm -f "$fh/.claude/settings.json"

# ...AND A FAILING INSTALLER IS STILL THE EXIT STATUS of a mixed-set repair. The stub is replaced
# through origin with one that logs and exits 1 (the behind path pulls it), and restored through
# origin afterwards, since every later case resets src to origin/main.
_stub_ok="$(cat "$seed/install.sh")"
_push_stub() {   # _push_stub <script-body> <commit-message>
  check_git "$c2" fetch -q origin; check_git "$c2" reset -q --hard origin/main
  printf '%s' "$1" > "$c2/install.sh"; chmod +x "$c2/install.sh"
  check_git "$c2" add install.sh; check_git "$c2" commit -q -m "$2"; check_git "$c2" push -q origin main
}
reset_src; _push_stub "$(printf '%s\nexit 1\n' "$_stub_ok")" "installer-fails"; : > "$work/install.log"; hook_settings mixed
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1)"; rc=$?
eq "$rc" 1 "hooks mixed + failing installer → the failure is still the exit status (1)"
has "$out" "install.sh exited non-zero" "hooks mixed + failing installer → ...and is reported"
rm -f "$fh/.claude/settings.json"
_push_stub "$_stub_ok" "installer-restored"; reset_src

# ...and a FOREIGN file at the new hook's pathname is a collision, not an opt-out: the repair still
# runs without --no-hooks (PR #443 review — the first cut tested existence, not ownership).
reset_src; : > "$work/install.log"; hook_settings shipped
mv "$fh/.claude/scripts/session-context.sh" "$work/saved-hook-link"; printf 'not ours\n' > "$fh/.claude/scripts/session-context.sh"
out="$(HOME="$fh" "$src/bin/baseline" update 2>&1 || true)"
has "$out" "newly shipped hook(s) not yet wired" "hooks newly shipped over a foreign file → still reported as shipped"
hasnt "$(cat "$work/install.log")" "--no-hooks" "hooks newly shipped over a foreign file → the installer runs WITHOUT --no-hooks"
rm -f "$fh/.claude/scripts/session-context.sh"; mv "$work/saved-hook-link" "$fh/.claude/scripts/session-context.sh"
rm -f "$fh/.claude/settings.json"


# update with a renamed-away ORPHAN (a dangling link into src, no manifest entry) must be
# PRUNED, not fatal: baseline removes the ownership-scoped dead link and completes (exit 0),
# then a second update is an idempotent no-op (#48).
reset_src
mkdir -p "$fh/.claude/skills"
ln -s "$src/agents/claude/skills/ghost" "$fh/.claude/skills/ghost"   # target does not exist
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "update prunes a renamed-away orphan (exit 0)"
if [ -L "$fh/.claude/skills/ghost" ]; then bad "orphaned link should have been pruned"; else ok; fi
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "second update after prune is an idempotent no-op (exit 0)"

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
rm -f "$fh/.claude/scripts/$PROBE_SCRIPT"
printf 'not a link\n' > "$fh/.claude/scripts/$PROBE_SCRIPT"   # a real file shadowing a manifest dest
eq "${ run_update "$src/bin/baseline" "$fh"; }" "1" "verify rejects a manifest dest that is not our symlink into src"
rm -f "$fh/.claude/scripts/$PROBE_SCRIPT"
ln -s "$src/agents/claude/scripts/$PROBE_SCRIPT" "$fh/.claude/scripts/$PROBE_SCRIPT"   # restore canonical link

# A HOME the install manifest cannot represent must FAIL CLOSED, never verify as healthy (#324,
# D64). Both of this file's manifest readers used to swallow the producer's status — the pipeline
# in adb_manifest_dests reported `cut`'s, and adb_verify_links expanded that inside its own heredoc
# — so a refused enumeration produced an EMPTY destination list, the verify loop ran zero times,
# and the function returned 0. "Healthy", asserted about an install nothing had looked at, which is
# precisely the stale-state trust base/practices/verify-before-asserting.md forbids.
#
# The fake home is built to look installed: the agent is detected from ~/.claude, so a bare
# newline-bearing directory would exit for the unrelated reason that no agent is installed there.
reset_src
nlfh="$work/nlhome"$'\n'"shadow"
mkdir -p "$nlfh/.claude/skills" "$nlfh/.claude/scripts"
ln -s "$src/agents/claude/CLAUDE.md" "$nlfh/.claude/CLAUDE.md"
ln -s "$src/scripts/lib" "$nlfh/.claude/scripts/lib"
eq "${ run_update "$src/bin/baseline" "$nlfh"; }" "1" "verify fails closed when HOME cannot be represented in the manifest"

# wrong-clone guard must NOT false-trip on a symlinked-path spelling of the SAME clone
# (physical-path comparison via pwd -P) — regression guard for the bug review's finding.
reset_src
aliasdir="$work/alias-src"; ln -s "$src" "$aliasdir"
eq "${ run_check "$aliasdir/bin/baseline" "$fh"; }" "current|0" "symlinked-path spelling is not treated as wrong-clone"

# The mutating `update` path must also REFUSE ahead state and preserve the local commit
# (the no-data-loss invariant on the write path, not just --check).
reset_src
check_git "$src" commit -q --allow-empty -m local-only-2
head_before="$(git -C "$src" rev-parse HEAD)"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "20" "update refuses ahead (exit 20)"
eq "$(git -C "$src" rev-parse HEAD)" "$head_before" "update preserves HEAD when ahead"

# A `behind` update must ALWAYS re-run the installer (a pulled commit can add a new skill
# that pre-existing links don't cover) — not skip it just because existing links resolve.
reset_src
advance_origin "adds-a-payload"
: > "$work/install.log"
eq "${ run_update "$src/bin/baseline" "$fh"; }" "0" "update behind exits 0"
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
eq "${ run_check "$src/bin/baseline" "$fh"; }" "current|0" "dangling root-doc still resolves the source (thread 3)"

# Prune must NEVER remove an agent ROOT-DOC link, even a dangling one: it lives at a fixed path
# that DETECTS the install (and resolves the source), so a dangling root doc is surfaced loudly,
# never silently pruned. Run the mutating path and assert the link survives (#48).
run_update "$src/bin/baseline" "$fh" >/dev/null 2>&1
if [ -L "$fh/.claude/CLAUDE.md" ]; then ok; else bad "prune must never remove a (dangling) root-doc link"; fi
rm -f "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"   # restore canonical link

# --- the opt-outs reach a repair of a MISSING root doc (#539) ----------------------------------
# Every Claude gate asks whether Claude is ours, and a missing root doc must still answer yes, or the
# repair re-runs install.sh without the flags that keep a recorded opt-out. This stub logs argv only,
# so the repair itself fails verify (exit 1) — what is asserted is the decision.
reset_src; : > "$work/install.log"; hook_settings partial
rm -f "$fh/.claude/CLAUDE.md"
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1 || true
has "$(cat "$work/install.log")" "--agent claude" "root doc missing → claude stays in the self-heal set"
has "$(cat "$work/install.log")" "--optout-if-recorded" "root doc missing → the per-hook opt-out and a recorded --no-sandbox are still honoured (--optout-if-recorded)"
hasnt "$(cat "$work/install.log")" "--no-hooks" "root doc missing, hooks partial → ...and the rest of the set is not suppressed wholesale (#444)"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"
rm -f "$fh/.claude/settings.json"
# ...and EVERY entry removed (`none`) still reaches the repair as --no-hooks.
reset_src; : > "$work/install.log"; hook_settings none
rm -f "$fh/.claude/CLAUDE.md"
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1 || true
has "$(cat "$work/install.log")" "--no-hooks" "root doc missing, hooks none → the whole-set opt-out is still preserved (--no-hooks)"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"
rm -f "$fh/.claude/settings.json"

# The manifest refusing must refuse the update by name, not drop the agent (#539, #324).
out="$(HOME="$nlfh" "$src/bin/baseline" update 2>&1)"
has "$out" "cannot enumerate the intended install destinations" "an unenumerable manifest refuses the update by name"

# =============== #534: the RELEASE channel (the default) ===============
# A stub `gh` first on PATH serves the release list from $work/rel.json — honouring
# --exclude-drafts, --exclude-pre-releases and --limit, and applying --jq with the real jq — logs
# every call to $work/gh.log, and exits with $work/gh.rc's contents when that file exists. The
# clone's origin is spelled as a GitHub URL and rewritten to a local bare repo with
# `url.<path>.insteadOf`, so the slug resolves and every fetch stays offline.
ghbin="$work/ghbin"; mkdir -p "$ghbin"
cat > "$ghbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/gh.log"
[ -f "$work/gh.rc" ] && exit "\$(cat "$work/gh.rc")"
expr="" xd=false xp=false lim=30
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --jq) expr="\$2"; shift 2 ;;
    --limit) lim="\$2"; shift 2 ;;
    --exclude-drafts) xd=true; shift ;;
    --exclude-pre-releases) xp=true; shift ;;
    *) shift ;;
  esac
done
jq -c --argjson xd "\$xd" --argjson xp "\$xp" --argjson lim "\$lim" \\
  '[.[] | select((\$xd and (.isDraft // false)) | not) | select((\$xp and (.isPrerelease // false)) | not)] | .[:\$lim]' \\
  "$work/rel.json" | if [ -n "\$expr" ]; then jq -r "\$expr"; else cat; fi
EOF
chmod +x "$ghbin/gh"
rel_json() { printf '%s\n' "$1" > "$work/rel.json"; rm -f "$work/gh.rc"; : > "$work/gh.log"; }
REL_LIST='[{"tagName":"v1.1.0","isLatest":true},{"tagName":"v1.0.0","isLatest":false}]'

relorigin="$work/relorigin.git"; git clone -q --bare "$origin" "$relorigin"
GHURL="https://github.com/acme/widget.git"
relc2="$work/relc2"; git clone -q "$relorigin" "$relc2"
rel_commit() { check_git "$relc2" commit -q --allow-empty -m "$1"; git -C "$relc2" push -q origin HEAD:main; }
rel_tag() { check_git "$relc2" -c tag.gpgsign=false tag -a "$1" -m "$1" "${2:-HEAD}"; git -C "$relc2" push -q origin "refs/tags/$1"; }
rel_commit r1; rel_tag v1.0.0
rel_commit r2; rel_tag v1.1.0
V100="$(git -C "$relc2" rev-parse 'v1.0.0^{commit}')"
V110="$(git -C "$relc2" rev-parse 'v1.1.0^{commit}')"
relsrc="$work/relsrc"; git clone -q "$relorigin" "$relsrc"
git -C "$relsrc" config "url.$relorigin.insteadOf" "$GHURL"
git -C "$relsrc" remote set-url origin "$GHURL"
relfh="$work/relhome"; mkdir -p "$relfh/.claude/skills" "$relfh/.claude/scripts"
ln -s "$relsrc/agents/claude/CLAUDE.md" "$relfh/.claude/CLAUDE.md"
ln -s "$relsrc/agents/claude/skills/demo" "$relfh/.claude/skills/demo"
for s in $ADB_SCRIPTS; do ln -s "$relsrc/agents/claude/scripts/$s.sh" "$relfh/.claude/scripts/$s.sh"; done
ln -s "$relsrc/scripts/lib" "$relfh/.claude/scripts/lib"

# relenv <command…> — as the release-channel home sees the world: ADB_UPDATE_CHANNEL unset.
relenv() { env -u ADB_UPDATE_CHANNEL HOME="$relfh" PATH="$ghbin:$PATH" XDG_CACHE_HOME="$work/relcache" "$@"; }
# rel_check [VAR=value…] — "<word>|<exit>", stderr kept in $work/rel.err.
rel_check()  { local out rc; out="$(relenv env "$@" "$relsrc/bin/baseline" update --check 2>"$work/rel.err")"; rc=$?; printf '%s|%s' "$out" "$rc"; }
rel_update() { relenv "$relsrc/bin/baseline" update >"$work/rel.out" 2>"$work/rel.err"; printf '%s' "$?"; }
# rel_currency <mode> <trigger> — the currency trigger's one record.
rel_currency() {
  relenv env ADB_SESSION_UPDATE="$1" ADB_SESSION_UPDATE_INTERVAL_SECS=0 \
    bash "$relsrc/scripts/lib/currency-lib.sh" check --trigger "$2" --cwd "$work" 2>/dev/null
}
rel_head()   { git -C "$relsrc" rev-parse HEAD; }
rel_reflog() { git -C "$relsrc" reflog | grep -c .; }
rel_detached() { if git -C "$relsrc" symbolic-ref -q HEAD >/dev/null; then echo attached; else echo detached; fi; }
rel_err() { cat "$work/rel.err"; }

rel_json "$REL_LIST"

# behind: detached at an older release. --check names both versions; notify names the newer one;
# auto moves it and says so in versions, never a commit count.
git -C "$relsrc" checkout -q --detach v1.0.0
eq "${ rel_check; }" "behind|10" "release: detached at v1.0.0, v1.1.0 latest → behind (10)"
has "$(rel_err)" "baseline: installed v1.0.0 (channel release), newest v1.1.0" "release: --check prints the versions line"
out="$(rel_currency notify startup)"
eq "${out%%[[:space:]]*}" "behind" "release: notify reports behind"
has "$out" "a newer release v1.1.0 is available (installed v1.0.0) — run 'baseline update'." "release: notify names both versions"
eq "$(rel_head)" "$V100" "release: notify moves nothing"
out="$(rel_currency auto cleanup)"
has "$out" "updated v1.0.0 → v1.1.0." "release: auto reports the move in versions"
hasnt "$out" "commit" "release: auto never counts commits on the release channel"
# The destination named is the release baseline verified, never another local tag on that commit.
git -C "$relsrc" checkout -q --detach v1.0.0
check_git "$relsrc" -c tag.gpgsign=false tag -a v2.0.0 -m unpublished "$V110"
out="$(rel_currency auto cleanup)"
has "$out" "updated v1.0.0 → v1.1.0." "release: auto names the verified release, not an unpublished tag on the same commit"
hasnt "$out" "v2.0.0" "release: ...and never the unpublished one"
git -C "$relsrc" tag -d v2.0.0 >/dev/null
git -C "$relsrc" checkout -q --detach v1.0.0
: > "$work/install.log"
eq "${ rel_update; }" "0" "release: behind → update exits 0"
eq "$(rel_head)" "$V110" "release: behind → HEAD is v1.1.0's commit"
eq "$(rel_detached)" "detached" "release: behind → HEAD is detached at the release"
[ -s "$work/install.log" ] && ok || bad "release: behind → install.sh is re-run"
has "$(cat "$work/rel.out")" "v1.0.0 → v1.1.0" "release: behind → stdout names the move"
has "$(cat "$work/gh.log")" "--exclude-drafts" "release: the resolver excludes drafts"
has "$(cat "$work/gh.log")" "--exclude-pre-releases" "release: the resolver excludes prereleases"
eq "$(git -C "$relsrc" for-each-ref refs/adb-release-fetch | grep -c .)" "0" "release: the private tag-fetch ref is removed after use"
# ...and one a killed run left behind (its process gone) is swept by the next run.
git -C "$relsrc" update-ref refs/adb-release-fetch/999999-1 HEAD
rel_check >/dev/null
eq "$(git -C "$relsrc" for-each-ref refs/adb-release-fetch | grep -c .)" "0" "release: a dead run's private ref is swept"

# current: detached at the newest release.
eq "${ rel_check; }" "current|0" "release: detached at v1.1.0 → current (0)"
eq "${ rel_update; }" "0" "release: current → update exits 0"
has "$(cat "$work/rel.out")" "already at the newest release v1.1.0" "release: current → says so"
eq "$(rel_head)" "$V110" "release: current → HEAD unchanged"

# main at the release commit (a main install the release caught up with): current, and the update
# detaches in place so a stray `git pull` cannot leave the channel.
git -C "$relsrc" checkout -q -B main "$V110"
eq "${ rel_check; }" "current|0" "release: main at v1.1.0's commit → current"
eq "${ rel_update; }" "0" "release: main at the release → update exits 0"
eq "$(rel_head) $(rel_detached)" "$V110 detached" "release: main at the release → detached in place, HEAD unchanged"

# ahead-of-release: main two commits past the newest release (today's install). HELD — never
# downgraded — with both versions and both ways out named; silent at session start, one line in
# /cleanup.
rel_commit r3; rel_commit r4
git -C "$relsrc" checkout -q main; git -C "$relsrc" fetch -q origin; git -C "$relsrc" reset -q --hard origin/main
head_ahead="$(rel_head)"
eq "${ rel_check; }" "ahead-of-release|20" "release: main two commits past v1.1.0 → ahead-of-release (20)"
eq "${ rel_update; }" "21" "release: ahead-of-release → update holds (21)"
eq "$(rel_head) $(git -C "$relsrc" symbolic-ref -q --short HEAD)" "$head_ahead main" "release: held → HEAD and branch unchanged"
has "$(rel_err)" "v1.1.0+2 (" "release: held → names the installed version"
has "$(rel_err)" "newest v1.1.0) — held, never downgraded" "release: held → names the newest release"
has "$(rel_err)" '[updates] channel = "main"' "release: held → names the way out to main"
out="$(rel_currency auto startup)"
eq "$out" $'silent\t' "release: held → the startup trigger says nothing"
out="$(rel_currency auto cleanup)"
eq "${out%%[[:space:]]*}" "refused" "release: held → /cleanup reports it"
has "$out" "held at v1.1.0+2 (" "release: held → /cleanup names the installed version"
has "$out" "ahead of the newest release v1.1.0" "release: held → /cleanup names the newest release"
eq "$(rel_currency notify cleanup)" $'silent\t' "release: held → notify stays silent"

# main at an OLDER release's commit (a main install behind the newest release) → moves forward onto
# the tag, detached.
git -C "$relsrc" checkout -q -B main "$V100"
eq "${ rel_update; }" "0" "release: main at v1.0.0's commit → update exits 0"
eq "$(rel_head) $(rel_detached)" "$V110 detached" "release: main behind the release → moved forward onto v1.1.0, detached"

# A tag pushed with no Release is never chosen.
rel_tag v1.2.0
eq "${ rel_check; }" "current|0" "release: a tag with no published Release is never followed"

# A prerelease listed first and a backfill created last (not marked latest) are never chosen.
rel_json '[{"tagName":"v1.3.0-rc.1","isLatest":false,"isPrerelease":true},{"tagName":"v1.1.0","isLatest":true},{"tagName":"v1.0.0","isLatest":false},{"tagName":"v0.9.0","isLatest":false}]'
eq "${ rel_check; }" "current|0" "release: a prerelease or a backfill never outranks the latest-marked release"

# tag-moved: origin deletes and re-creates v1.1.0 at another commit; the local tag is unchanged.
# An integrity refusal (40), HEAD unchanged, and reported by BOTH triggers in BOTH modes — never as
# `offline`, never as silence.
rel_json "$REL_LIST"
orig110="$(git -C "$relc2" rev-parse refs/tags/v1.1.0)"
check_git "$relc2" tag -d v1.1.0 >/dev/null
git -C "$relc2" push -q origin :refs/tags/v1.1.0
rel_tag v1.1.0 "$V100"
# ...even when the remote's own configuration would fetch tags, forced: the release channel reads
# origin by URL, so neither tagOpt nor a forced tag refspec can overwrite the local tag first.
git -C "$relsrc" config remote.origin.tagOpt --tags
git -C "$relsrc" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
local110="$(git -C "$relsrc" rev-parse refs/tags/v1.1.0)"
eq "${ rel_check; }" "tag-moved|40" "release: origin moved v1.1.0 → tag-moved (40)"
eq "$(git -C "$relsrc" rev-parse refs/tags/v1.1.0)" "$local110" "release: tag-moved → the local tag is not overwritten, whatever the remote config"
eq "${ rel_update; }" "40" "release: tag-moved → update refuses (40)"
eq "$(rel_head)" "$V110" "release: tag-moved → HEAD unchanged"
has "$(rel_err)" "tag v1.1.0 in $relsrc does not match origin's — refusing to move; a release tag must never move." "release: tag-moved → the refusal names the tag"
for m in notify auto; do
  for t in startup cleanup; do
    out="$(rel_currency "$m" "$t")"
    eq "${out%%[[:space:]]*}" "refused" "release: tag-moved → $m/$t reports it (refused)"
    has "$out" "failed an integrity check" "release: tag-moved → $m/$t says why"
    hasnt "$out" "unreachable" "release: tag-moved → $m/$t is not the offline line"
  done
done
eq "$(rel_head)" "$V110" "release: tag-moved → no trigger moved HEAD"
git -C "$relsrc" config --unset remote.origin.tagOpt
git -C "$relsrc" config --unset remote.origin.fetch '\+refs/tags/\*:refs/tags/\*'
check_git "$relc2" tag -d v1.1.0 >/dev/null
git -C "$relc2" push -q origin :refs/tags/v1.1.0
git -C "$relc2" push -q origin "$orig110:refs/tags/v1.1.0"
eq "${ rel_check; }" "current|0" "fixture: origin's v1.1.0 restored"

# release-off-branch: the latest release's commit is not on origin/main.
git -C "$relc2" checkout -q -b side
check_git "$relc2" commit -q --allow-empty -m side
rel_tag v1.4.0
git -C "$relc2" checkout -q main
rel_json '[{"tagName":"v1.4.0","isLatest":true},{"tagName":"v1.1.0","isLatest":false}]'
eq "${ rel_check; }" "release-off-branch|40" "release: the latest release is off main → release-off-branch (40)"
eq "${ rel_update; }" "40" "release: release-off-branch → update refuses (40)"
eq "$(rel_head)" "$V110" "release: release-off-branch → HEAD unchanged"

# Unresolvable or absent releases: 30, HEAD unchanged, and no fetch, pull or checkout recorded.
git -C "$relsrc" checkout -q --detach v1.0.0
for case_ in gh-fails bad-tag no-release; do
  case "$case_" in
    gh-fails)   rel_json "$REL_LIST"; printf '1' > "$work/gh.rc"; want="release-unresolvable|30"; msg="could not resolve the newest release of acme/widget (gh failed (exit 1))" ;;
    bad-tag)    rel_json '[{"tagName":"v1.1.0;x","isLatest":true}]'; want="release-unresolvable|30"; msg="the latest tag name failed validation" ;;
    no-release) rel_json '[]'; want="no-release|30"; msg="acme/widget has no published stable release" ;;
  esac
  eq "${ rel_check; }" "$want" "release: $case_ → $want"
  n0="$(rel_reflog)"
  eq "${ rel_update; }" "30" "release: $case_ → update exits 30"
  has "$(rel_err)" "$msg" "release: $case_ → the message says why"
  eq "$(rel_head) $(rel_reflog)" "$V100 $n0" "release: $case_ → HEAD unchanged and no new reflog entry"
  out="$(rel_currency auto cleanup)"
  eq "${out%%[[:space:]]*}" "offline" "release: $case_ → the currency trigger records offline"
  has "$out" "currency not verified" "release: $case_ → ...saying currency is not verified"
  hasnt "$out" "unreachable" "release: $case_ → ...not that a reachable remote is unreachable"
done
# gh missing altogether: the same 30, HEAD and reflog unchanged. PATH is every tool the run needs
# except gh, linked into one directory, so no host gh further down the PATH can answer.
ghless="$work/ghless"; mkdir -p "$ghless"
printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r _pd; do
  [ -d "$_pd" ] || continue
  for _pf in "$_pd"/*; do
    _pb="${_pf##*/}"
    [ "$_pb" = gh ] && continue
    [ -x "$_pf" ] && [ ! -d "$_pf" ] && [ ! -e "$ghless/$_pb" ] && ln -s "$_pf" "$ghless/$_pb" 2>/dev/null
  done
done
if [ -e "$ghless/gh" ] || ! PATH="$ghless" command -v git >/dev/null 2>&1; then
  bad "fixture: could not build a PATH without gh"
else
  rel_json "$REL_LIST"; n0="$(rel_reflog)"
  out="$(env -u ADB_UPDATE_CHANNEL HOME="$relfh" PATH="$ghless" XDG_CACHE_HOME="$work/relcache" "$relsrc/bin/baseline" update --check 2>"$work/rel.err")"
  eq "$out|$?" "release-unresolvable|30" "release: gh missing → release-unresolvable (30)"
  has "$(rel_err)" "(gh not found)" "release: gh missing → ...naming why"
  env -u ADB_UPDATE_CHANNEL HOME="$relfh" PATH="$ghless" XDG_CACHE_HOME="$work/relcache" "$relsrc/bin/baseline" update >/dev/null 2>&1
  eq "$?" "30" "release: gh missing → update exits 30"
  eq "$(rel_head) $(rel_reflog)" "$V100 $n0" "release: gh missing → HEAD unchanged and no new reflog entry"
fi
rel_json "$REL_LIST"
# `baseline latest-release` answers through the same resolver, for a clone with nothing installed.
eq "$(relenv "$relsrc/bin/baseline" latest-release 2>/dev/null; printf '|%s' "$?")" "v1.1.0
|0" "latest-release: the newest stable release tag"
rel_json '[]'
eq "$(relenv "$relsrc/bin/baseline" latest-release 2>/dev/null; printf '|%s' "$?")" "|1" "latest-release: none published → 1"
rel_json '[{"tagName":"production","isLatest":true}]'
eq "$(relenv "$relsrc/bin/baseline" latest-release 2>/dev/null; printf '|%s' "$?")" "|2" "latest-release: a tag that is not vX.Y.Z → 2, nothing printed"
rel_json "$REL_LIST"

# Local refusals stay local on the release channel: decided before any network (no gh call), and a
# held lock steps aside before any network too.
printf 'edit\n' >> "$relsrc/agents/claude/CLAUDE.md"
eq "${ rel_check; }|$(grep -c . "$work/gh.log")" "dirty|20|0" "release: dirty → refused with no gh call"
git -C "$relsrc" checkout -q -- agents/claude/CLAUDE.md
git -C "$relsrc" checkout -q -B feature-z
eq "${ rel_check; }|$(grep -c . "$work/gh.log")" "not-default|20|0" "release: not-default → refused with no gh call"
git -C "$relsrc" checkout -q --detach v1.0.0
relgit="$(git -C "$relsrc" rev-parse --absolute-git-dir)"
printf '%s\n' "$V100" > "$relgit/MERGE_HEAD"
eq "${ rel_check; }|$(grep -c . "$work/gh.log")" "in-progress|20|0" "release: in-progress → refused with no gh call"
rm -f "$relgit/MERGE_HEAD"
mkdir -p "$relgit/adb-update.lock"
eq "${ rel_update; }|$(grep -c . "$work/gh.log")|$(rel_head)" "5|0|$V100" "release: a held lock → exit 5, no gh call, HEAD unchanged"
rmdir "$relgit/adb-update.lock"

# Choosing the channel. A misspelled value is the release channel plus a diagnostic; the global
# manifest's `main` is today's behaviour (no release lookup at all); a PROJECT's copy is ignored.
eq "${ rel_check ADB_UPDATE_CHANNEL=mian; }" "behind|10" "release: channel 'mian' → the release channel"
has "$(rel_err)" 'ADB_UPDATE_CHANNEL is not "release" or "main" — following the release channel' "release: a misspelled channel is diagnosed"
mkdir -p "$relfh/.config/ai-dev-baseline"
printf '[updates]\nchannel = "mian"\n' > "$relfh/.config/ai-dev-baseline/agents.toml"
rel_check >/dev/null
has "$(rel_err)" "[updates] channel in $relfh/.config/ai-dev-baseline/agents.toml is not" "release: a misspelled manifest channel is diagnosed"
mkdir -p "$work/proj"; printf '[updates]\nchannel = "main"\n' > "$work/proj/agents.toml"
eq "$(cd "$work/proj" && rel_check)" "behind|10" "release: a PROJECT agents.toml cannot choose the channel"

# release → main: detached at the release, the global manifest switches to main. The default branch
# is re-attached at origin/main (forward only), with the local branch advanced first.
git -C "$relsrc" checkout -q -B main "$V100"
git -C "$relsrc" checkout -q --detach "$V110"
printf '[updates]\nchannel = "main"\n' > "$relfh/.config/ai-dev-baseline/agents.toml"
: > "$work/gh.log"
eq "${ rel_check; }" "behind|10" "main channel: detached at a release on origin's history → behind (re-attach)"
eq "$(grep -c . "$work/gh.log")" "0" "main channel: no release lookup at all"
eq "${ rel_update; }" "0" "main channel: re-attach exits 0"
eq "$(rel_head) $(git -C "$relsrc" symbolic-ref -q --short HEAD)" "$(git -C "$relsrc" rev-parse origin/main) main" "main channel: on main at origin/main"
eq "${ rel_check; }" "current|0" "main channel: then current"
# ...and a local main with unpushed work is never moved under the operator.
check_git "$relsrc" commit -q --allow-empty -m unpushed
git -C "$relsrc" checkout -q --detach "$V110"
eq "${ rel_check; }" "ahead|20" "main channel: detached, local main has unpushed commits → ahead (20)"
eq "$(rel_head)" "$V110" "main channel: ...and HEAD unchanged"
# ...and a switch that fails after the branch was advanced puts the branch back: HEAD and the
# branch both end where they were.
git -C "$relsrc" checkout -q -B main "$V100"
git -C "$relsrc" checkout -q --detach "$V110"
: > "$relgit/index.lock"
eq "${ rel_update; }" "20" "main channel: a failed switch onto main → exit 20"
eq "$(rel_head) $(rel_detached) $(git -C "$relsrc" rev-parse refs/heads/main)" "$V110 detached $V100" \
  "main channel: a failed switch → HEAD still detached where it was, and main put back"
rm -f "$relgit/index.lock"
# ...but when git switched and THEN failed (a post-checkout hook), the switch stands: HEAD is on
# main, and rolling the branch back would rewind the branch HEAD now names.
relhk="$work/relhooks"; mkdir -p "$relhk"; printf '#!/bin/sh\nexit 1\n' > "$relhk/post-checkout"; chmod +x "$relhk/post-checkout"
git -C "$relsrc" config core.hooksPath "$relhk"
eq "${ rel_update; }" "0" "main channel: a post-checkout hook failing after the switch → the re-attach stands (0)"
eq "$(git -C "$relsrc" symbolic-ref -q --short HEAD) $(rel_head)" "main $(git -C "$relsrc" rev-parse origin/main)" \
  "main channel: ...HEAD on main at origin/main, not rolled back"
git -C "$relsrc" config --unset core.hooksPath
# Re-attaching at the commit HEAD is already on is the same-HEAD path: links verified, no installer
# re-run unless one is broken (a repair there exits 6, which a HEAD-watching caller can see).
git -C "$relsrc" checkout -q --detach origin/main
: > "$work/install.log"
eq "${ rel_update; }" "0" "main channel: re-attach at the same commit, links fine → 0"
has "$(cat "$work/rel.out")" "re-attached $relsrc to main at the commit it was on" "main channel: ...says so"
[ -s "$work/install.log" ] && bad "main channel: a same-commit re-attach must take the same-HEAD path, not re-run the installer as a move" || ok
# A host other than github.com is never resolved against a same-named GitHub repository.
rm -f "$relfh/.config/ai-dev-baseline/agents.toml"
git -C "$relsrc" remote set-url origin "https://gitlab.com/acme/widget.git"
eq "${ rel_check; }" "release-unresolvable|30" "release: an origin on another host → release-unresolvable"
has "$(rel_err)" "origin does not name a github.com owner/repo" "release: ...naming why"
eq "$(grep -c . "$work/gh.log")" "0" "release: ...without asking gh about another repository"
git -C "$relsrc" remote set-url origin "$GHURL"
# Release channel: a checkout that git completed before a hook failed is still healed; one that never
# happened takes back the local tag this run recorded for it.
git -C "$relsrc" checkout -q --detach v1.0.0
git -C "$relsrc" config core.hooksPath "$relhk"
: > "$work/install.log"
eq "${ rel_update; }|$(rel_head)" "0|$V110" "release: checkout done, then a hook failed → the move stands (0)"
[ -s "$work/install.log" ] && ok || bad "release: ...and the installer still re-runs"
git -C "$relsrc" config --unset core.hooksPath
git -C "$relsrc" checkout -q --detach v1.0.0
git -C "$relsrc" tag -d v1.1.0 >/dev/null
: > "$relgit/index.lock"
eq "${ rel_update; }|$(rel_head)" "20|$V100" "release: a checkout that never happened → 20, HEAD unchanged"
git -C "$relsrc" rev-parse --verify --quiet refs/tags/v1.1.0 >/dev/null && bad "release: ...and the tag this run recorded is taken back" || ok
rm -f "$relgit/index.lock"
eq "${ rel_update; }|$(rel_head)" "0|$V110" "release: ...and the next run moves it"
rm -f "$relfh/.config/ai-dev-baseline/agents.toml"

# =============== #539: a missing or occupied root doc, against the REAL installer ===============
# The stub above cannot re-link anything, and re-linking is the claim. These rows install a clone of
# THIS tree with the real install.sh into scratch homes. A stub `claude` first on PATH pins the CLI
# version the sandbox fragment asks about, so the host's CLI decides nothing; CODEX_HOME is pinned
# per call so no Codex config outside the scratch home is read or written.
rseed="$work/rseed"
check_copy_subtrees "$ROOT" "$rseed" agents scripts templates bin \
  && cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$rseed/" \
  || { bad "fixture: could not copy the tree for the real-installer rows"; check_summary "baseline"; exit 1; }
rorigin="$work/rorigin.git"
check_make_repo_pair "$rseed" "$rorigin" || { bad "fixture: real-installer repo pair init failed"; check_summary "baseline"; exit 1; }
git -C "$rseed" symbolic-ref HEAD refs/heads/main
check_git "$rseed" add -A
check_git "$rseed" commit -q -m seed
git -C "$rseed" push -q -u origin main
git -C "$rorigin" symbolic-ref HEAD refs/heads/main
rsrc="$work/rsrc"; git clone -q "$rorigin" "$rsrc"
rbin="$work/rbin"; mkdir -p "$rbin"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$rbin/claude"; chmod +x "$rbin/claude"

# rhome <name> <install.sh args…> — RH = a fresh scratch home holding a real install from rsrc.
rhome() {
  local name="$1"; shift
  RH="$work/rh-$name"; mkdir -p "$RH"
  if ( cd "$rsrc" && env HOME="$RH" CODEX_HOME="$RH/.codex" PATH="$rbin:$PATH" ./install.sh "$@" ) \
       > "$work/rh-$name.log" 2>&1; then ok
  else bad "fixture: install.sh $* into $name failed — $(tail -n 3 "$work/rh-$name.log" | tr '\n' ' ')"; fi
}
# renv <home> <command…> — run a command as the scratch home sees the world.
renv() { local h="$1"; shift; env HOME="$h" CODEX_HOME="$h/.codex" PATH="$rbin:$PATH" XDG_CACHE_HOME="$h/.cache" "$@"; }
# rupdate <home> — RRC = exit status, RERR = stderr of `baseline update` (stdout dropped).
rupdate() {
  renv "$1" "$rsrc/bin/baseline" update >/dev/null 2>"$work/rupdate.err"; RRC=$?
  RERR="$(cat "$work/rupdate.err")"
}
# resolves <path> — our link into rsrc, and it resolves.
resolves() { adb_link_into "$1" "$rsrc" && [ -e "$1" ]; }
# backups <home> — how many ai-dev-baseline-* backup directories it holds; `unreadable` when the
# folder exists but cannot be listed, so a failed listing never reads as "none were made".
backups() {
  local d="$1/.claude/backups" out
  [ -e "$d" ] || { printf '0'; return 0; }
  out="$(find "$d" -mindepth 1 -maxdepth 1 -name 'ai-dev-baseline-*')" || { printf 'unreadable'; return 0; }
  printf '%s\n' "$out" | grep -c . || true
}

# Two agents, Claude's root doc and one skill gone: the repair restores both and says so.
rhome cc --agent claude --agent codex; h="$RH"
rm -f "$h/.claude/CLAUDE.md" "$h/.claude/skills/cleanup"
eq "$(renv "$h" "$rsrc/bin/baseline" update --check 2>/dev/null)" "current" "root doc missing → --check stays a clone-currency question"
[ ! -e "$h/.claude/CLAUDE.md" ] && [ ! -L "$h/.claude/CLAUDE.md" ] && ok || bad "root doc missing → --check must repair nothing"
rupdate "$h"
eq "$RRC" "6" "claude+codex, root doc + skill missing → update repairs (exit 6)"
resolves "$h/.claude/CLAUDE.md" && ok || bad "claude+codex → the root doc is re-linked"
resolves "$h/.claude/skills/cleanup" && ok || bad "claude+codex → the missing skill is re-linked"
has "$RERR" "re-linked ~/.claude/CLAUDE.md — it was missing while claude's other links still point into $rsrc." "claude+codex → the re-link is audited on stderr"
rupdate "$h"
eq "$RRC" "0" "claude+codex → the next update is nothing to do"
hasnt "$RERR" "re-linked" "claude+codex → ...and audits no re-link it did not make"

# The automatic callers reach the same repair.
rm -f "$h/.claude/CLAUDE.md" "$h/.claude/skills/cleanup"
out="$(renv "$h" env ADB_SESSION_UPDATE=auto ADB_SESSION_UPDATE_INTERVAL_SECS=0 bash "$h/.claude/scripts/lib/currency-lib.sh" check --trigger startup 2>/dev/null)"
eq "${out%%[[:space:]]*}" "repaired" "root doc missing → the startup currency check records repaired"
resolves "$h/.claude/CLAUDE.md" && ok || bad "startup currency check → the root doc is re-linked"
rm -f "$h/.claude/CLAUDE.md" "$h/.claude/skills/cleanup"
out="$(printf '{"source":"startup","cwd":"/"}' | renv "$h" env ADB_SESSION_UPDATE=auto ADB_SESSION_UPDATE_INTERVAL_SECS=0 bash "$h/.claude/scripts/session-currency.sh" 2>/dev/null)"
has "$out" "repaired the installed links" "root doc missing → the SessionStart hook reports the repair"
has "$out" '"reloadSkills":true' "root doc missing → ...and asks for a skill reload"
resolves "$h/.claude/CLAUDE.md" && ok || bad "SessionStart hook → the root doc is re-linked"

# One agent only: the root doc was the only root-doc link, so discovery falls back to scripts/lib.
for agent in claude codex; do
  rhome "only-$agent" --agent "$agent"; h="$RH"
  doc="$(adb_agent_root_doc "$agent" "$rsrc" "$h")" || bad "$agent only → no root-doc row in the manifest"
  rm -f "$doc"
  eq "$(adb_install_source "$h")" "$rsrc" "$agent only, root doc missing → adb_install_source still names the clone"
  eq "$(renv "$h" bash "$rsrc/scripts/lib/adopt-lib.sh" baseline 2>/dev/null)" "$rsrc" "$agent only, root doc missing → /adopt still locates the baseline"
  rupdate "$h"
  eq "$RRC" "6" "$agent only, root doc missing → update repairs (exit 6)"
  resolves "$doc" && ok || bad "$agent only → the root doc is re-linked"
  rm -f "$doc"
  out="$(renv "$h" bash "$h/.$agent/scripts/lib/currency-lib.sh" check --trigger cleanup 2>/dev/null)"
  eq "${out%%[[:space:]]*}" "repaired" "$agent only, root doc missing → the /cleanup currency check records repaired"
done

# All three agents: Gemini's root doc is re-linked under ~/.gemini/.
rhome all --agent claude --agent codex --agent gemini; h="$RH"
rm -f "$h/.gemini/GEMINI.md"
rupdate "$h"
eq "$RRC" "6" "three agents, GEMINI.md missing → update repairs (exit 6)"
resolves "$h/.gemini/GEMINI.md" && ok || bad "three agents → GEMINI.md is re-linked"

# The opt-outs survive the repair, with the real installer: a hook entry removed by hand and a
# recorded --no-sandbox are still in force after the root doc comes back.
rhome opt --agent claude --no-sandbox; h="$RH"
jq '.hooks |= with_entries(.value |= (map(.hooks |= map(select(.command | endswith("/precommit-gate.sh") | not))) | map(select(.hooks | length > 0))))' \
  "$h/.claude/settings.json" > "$work/opt.json" && mv "$work/opt.json" "$h/.claude/settings.json"
eq "$(adb_claude_hooks_state "$h/.claude/settings.json" "$h")" "partial" "fixture: one hook entry removed by hand"
rm -f "$h/.claude/CLAUDE.md"
rupdate "$h"
resolves "$h/.claude/CLAUDE.md" && ok || bad "opt-outs → the root doc is re-linked"
eq "$(adb_claude_hooks_state "$h/.claude/settings.json" "$h")" "partial" "opt-outs → the removed hook entry stays removed"
eq "$(adb_claude_settings_disposition "$(adb_claude_settings_receipt "$h")" 2>/dev/null)" "skipped-optout" "opt-outs → --no-sandbox stays recorded"
jq -e '.sandbox == null' "$h/.claude/settings.json" >/dev/null && ok || bad "opt-outs → no sandbox key was written"

# THE MIXED SET, END TO END (#444): one hook entry removed by hand AND a hook shipped since the last
# install — no entry, no link, no receipt line. `baseline update` alone must end with the new hook
# wired and the removed one still absent, and the next update must have nothing to do. Twice: with
# the receipt, and with none (an install that predates it, where the link alone marks the opt-out).
for rcpt in kept absent; do
  rhome "mixed-$rcpt" --agent claude --no-sandbox; h="$RH"
  jq '.hooks |= with_entries(.value |= (map(.hooks |= map(select(.command | (endswith("/precommit-gate.sh") or endswith("/session-context.sh")) | not))) | map(select(.hooks | length > 0))))' \
    "$h/.claude/settings.json" > "$work/mixed.json" && mv "$work/mixed.json" "$h/.claude/settings.json"
  rm -f "$h/.claude/scripts/session-context.sh"
  if [ "$rcpt" = kept ]; then
    grep -vxF session-context.sh "$(adb_claude_hooks_receipt "$h")" > "$work/mixed-receipt" && mv "$work/mixed-receipt" "$(adb_claude_hooks_receipt "$h")"
  else
    rm -f "$(adb_claude_hooks_receipt "$h")"
  fi
  eq "$(adb_claude_hooks_state "$h/.claude/settings.json" "$h")" "partial" "fixture ($rcpt receipt): a mixed hook set"
  rupdate "$h"
  eq "$RRC" "6" "mixed set ($rcpt receipt) → update repairs (exit 6)"
  adb_claude_hook_wired "$h/.claude/settings.json" session-context.sh "$h" && ok || bad "mixed set ($rcpt receipt) → the newly shipped hook is wired"
  resolves "$h/.claude/scripts/session-context.sh" && ok || bad "mixed set ($rcpt receipt) → ...and its script is linked"
  if adb_claude_hook_wired "$h/.claude/settings.json" precommit-gate.sh "$h"; then bad "mixed set ($rcpt receipt) → the hook removed by hand must stay removed"; else ok; fi
  eq "$(adb_claude_hooks_missing_deliberate "$h/.claude/settings.json" "$rsrc" "$h" | tr -d '\n')" "precommit-gate.sh" \
    "mixed set ($rcpt receipt) → ...and still reads as the operator's opt-out"
  rupdate "$h"
  eq "$RRC" "0" "mixed set ($rcpt receipt) → the next update is nothing to do"
  if adb_claude_hook_wired "$h/.claude/settings.json" precommit-gate.sh "$h"; then bad "mixed set ($rcpt receipt) → a second update must not re-wire the removed hook"; else ok; fi
done

# An OCCUPIED root doc is never displaced by an update: a regular file, then a link into a path
# that is not a clone. Each is reported by class, and the exit code is what it would be anyway.
rhome rf --agent claude --agent codex; h="$RH"
rm -f "$h/.claude/CLAUDE.md" "$h/.claude/skills/cleanup"
printf 'my own rules\n' > "$h/.claude/CLAUDE.md"; cp "$h/.claude/CLAUDE.md" "$work/rf-copy"
ln -s "$rsrc/agents/claude/skills/ghost" "$h/.claude/skills/ghost"   # an owned link that dangles
b0="$(backups "$h")"
rupdate "$h"
eq "$RRC" "0" "a regular file at the root doc → the exit code is unchanged (0)"
cmp -s "$h/.claude/CLAUDE.md" "$work/rf-copy" && [ ! -L "$h/.claude/CLAUDE.md" ] && ok || bad "a regular file at the root doc → left byte-identical"
eq "$(backups "$h")" "$b0" "a regular file at the root doc → no backup directory is created"
has "$RERR" "NOTE — ~/.claude/CLAUDE.md is not the baseline's root doc (a regular file)" "a regular file at the root doc → the NOTE names its class"
has "$RERR" "restores it (what is there now is moved under ~/.claude/backups/)" "a regular file at the root doc → the NOTE says the installer would back it up"
hasnt "$RERR" "re-linked" "a regular file at the root doc → nothing is re-linked"
[ -L "$h/.claude/skills/ghost" ] && ok || bad "a regular file at the root doc → that agent's dead links are not pruned either"
case "$b0" in ''|*[!0-9]*) bad "fixture: the backup folder could not be listed ($b0), so the no-backup assertion proves nothing" ;; *) ok ;; esac

rhome fl --agent claude --agent codex; h="$RH"
rm -f "$h/.claude/CLAUDE.md" "$h/.claude/skills/cleanup"
mkdir -p "$work/not-a-clone"; ln -s "$work/not-a-clone/CLAUDE.md" "$h/.claude/CLAUDE.md"
rupdate "$h"
eq "$RRC" "0" "a link outside the clone at the root doc → the exit code is unchanged (0)"
eq "$(readlink "$h/.claude/CLAUDE.md")" "$work/not-a-clone/CLAUDE.md" "a link outside the clone → left pointing where it pointed"
has "$RERR" "(a link outside $rsrc)" "a link outside the clone → the NOTE names its class"
hasnt "$RERR" "not-a-clone" "a link outside the clone → the NOTE never prints the link's target"
has "$RERR" "the link is replaced, and where it pointed is not kept" "a link outside the clone → the NOTE promises no backup the installer does not make"

# A root doc linked into ANOTHER VALID clone. When an earlier root doc names this clone, discovery
# keeps it and the other agent is reported, not re-installed. When the foreign one is found first,
# the update refuses as the wrong clone, exactly as before (owner decision, D137).
oclone="$work/other-clone"; mkdir -p "$oclone/agents/claude" "$oclone/agents/codex"; : > "$oclone/install.sh"
rhome oc --agent claude --agent codex; h="$RH"
rm -f "$h/.codex/AGENTS.md"; ln -s "$oclone/agents/codex/AGENTS.md" "$h/.codex/AGENTS.md"
rupdate "$h"
eq "$RRC" "0" "codex's root doc in another clone, claude's ours → the update runs for this clone (exit 0)"
has "$RERR" "NOTE — ~/.codex/AGENTS.md is not the baseline's root doc (a link outside $rsrc)" "...and reports codex's root doc by class"
eq "$(readlink "$h/.codex/AGENTS.md")" "$oclone/agents/codex/AGENTS.md" "...and leaves it pointing at the other clone"
rm -f "$h/.claude/CLAUDE.md"; ln -s "$oclone/agents/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
rupdate "$h"
eq "$RRC" "4" "claude's root doc in another valid clone is found first → refused as the wrong clone (exit 4)"

# A damaged agent is not pruned: codex has lost its root doc and every other codex link dangles
# into the clone. Those dangling links are all that show codex is installed, so the update must
# repair codex rather than prune it into `absent`.
rhome pr --agent claude --agent codex; h="$RH"
rm -f "$h/.codex/AGENTS.md"
while IFS="$(printf '\t')" read -r _s _d; do
  [ "$_d" = "$h/.codex/AGENTS.md" ] && continue
  rm -rf "$_d"; ln -s "$rsrc/gone-${_d##*/}" "$_d"
done <<EOF
$(adb_agent_manifest codex "$rsrc" "$h")
EOF
rupdate "$h"
eq "$RRC" "6" "codex links all dangling + root doc missing → codex is repaired, not pruned away (exit 6)"
resolves "$h/.codex/AGENTS.md" && ok || bad "pruned codex → its root doc is re-linked"
resolves "$h/.codex/scripts/lib" && ok || bad "pruned codex → its scripts/lib is re-linked"

# The owner's Gemini shape: a regular GEMINI.md and no Gemini links at all is `absent` — untouched
# and silent.
rhome gs --agent claude; h="$RH"
mkdir -p "$h/.gemini"; printf 'mine\n' > "$h/.gemini/GEMINI.md"
rupdate "$h"
eq "$RRC" "0" "an unrelated regular GEMINI.md, no Gemini links → nothing to do"
eq "$(cat "$h/.gemini/GEMINI.md")" "mine" "an unrelated regular GEMINI.md → untouched"
hasnt "$RERR" "GEMINI.md" "an unrelated regular GEMINI.md → not mentioned"

# A LEGACY receipt (no `source` row) whose root doc is missing is still ours to uninstall.
rhome lr --agent claude; h="$RH"
grep -v '^source' "$(adb_claude_settings_receipt "$h")" > "$work/lr.rcpt" && cat "$work/lr.rcpt" > "$(adb_claude_settings_receipt "$h")"
rm -f "$h/.claude/CLAUDE.md"
out="$(cd "$rsrc" && renv "$h" ./uninstall.sh --agent claude 2>&1)"
hasnt "$out" "installed from another clone" "legacy receipt, root doc missing → uninstall does not call it another clone's"
[ ! -e "$(adb_claude_settings_receipt "$h")" ] && ok || bad "legacy receipt, root doc missing → the receipt is removed"
jq -e '.sandbox == null' "$h/.claude/settings.json" >/dev/null && ok || bad "legacy receipt, root doc missing → the sandbox keys are removed"

# The release channel's first-install warning (#534): on a clone not at a version tag the real
# installer warns and still installs; at a version tag it is silent.
for _wt in untagged tagged; do
  wh="$work/rh-warn-$_wt"; mkdir -p "$wh"
  [ "$_wt" = tagged ] && check_git "$rsrc" -c tag.gpgsign=false tag -a v9.9.9 -m v9.9.9
  ( cd "$rsrc" && env -u ADB_UPDATE_CHANNEL HOME="$wh" CODEX_HOME="$wh/.codex" PATH="$rbin:$PATH" \
      ./install.sh --agent claude --agent codex --no-hooks ) >/dev/null 2>"$work/warn.err"
  eq "$?" "0" "install.sh, release channel, $_wt clone → installs"
  if [ "$_wt" = untagged ]; then
    has "$(cat "$work/warn.err")" "not at a version tag" "install.sh, untagged clone → warns"
    has "$(cat "$work/warn.err")" "./uninstall.sh --agent claude --agent codex" "install.sh, untagged clone → ...uninstalling the same agent set"
    has "$(cat "$work/warn.err")" "./install.sh --agent claude --agent codex --no-hooks" "install.sh, untagged clone → ...and reinstalling with the same agents and preferences"
  else
    hasnt "$(cat "$work/warn.err")" "not at a version tag" "install.sh, clone at a version tag → no warning"
    has "$(cat "$work/warn.err")" "a version tag; whether it is a PUBLISHED" "install.sh, clone at a version tag → notes publication is unverified offline"
    ( cd "$rsrc" && env -u ADB_UPDATE_CHANNEL ADB_RELEASE_VERIFIED=v9.9.9 HOME="$wh" CODEX_HOME="$wh/.codex" PATH="$rbin:$PATH" \
        ./install.sh --agent claude --agent codex --no-hooks ) >/dev/null 2>"$work/warn.err"
    hasnt "$(cat "$work/warn.err")" "PUBLISHED" "install.sh, a tag baseline update just verified → no note"
    git -C "$rsrc" tag -d v9.9.9 >/dev/null
  fi
done

# LAST, because it moves origin: a pulled commit that adds a skill links it AND re-links the root
# doc on the behind path.
rhome zz --agent claude --agent codex; h="$RH"
rm -f "$h/.claude/CLAUDE.md"
rc2="$work/rc2"; git clone -q "$rorigin" "$rc2"
mkdir -p "$rc2/agents/claude/skills/zz-new"; printf 'zz\n' > "$rc2/agents/claude/skills/zz-new/SKILL.md"
check_git "$rc2" add -A; check_git "$rc2" commit -q -m zz-new; git -C "$rc2" push -q origin main
rupdate "$h"
eq "$RRC" "0" "behind, root doc missing → update completes (exit 0)"
resolves "$h/.claude/skills/zz-new" && ok || bad "behind → the newly shipped skill is linked"
resolves "$h/.claude/CLAUDE.md" && ok || bad "behind → the root doc is re-linked"

check_summary "baseline"
