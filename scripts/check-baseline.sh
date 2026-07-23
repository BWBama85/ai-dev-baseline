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

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
eq()  { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git_q() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

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
for s in precommit-gate implement-issue-gate statusline; do
  printf '#stub\n' > "$seed/agents/claude/scripts/$s.sh"
done

origin="$work/origin.git"; git init -q --bare "$origin"
git init -q "$seed"
git -C "$seed" symbolic-ref HEAD refs/heads/main
git_q "$seed" add -A
git_q "$seed" commit -q -m seed
git -C "$seed" remote add origin "$origin"
git -C "$seed" push -q -u origin main
# Ensure the bare origin's HEAD names main so a clone checks it out cleanly regardless
# of the host git's init.defaultBranch.
git -C "$origin" symbolic-ref HEAD refs/heads/main

# The install-source clone under test, and a fake HOME whose links mirror the FULL manifest
# surface (root doc + skill + the three scripts + scripts/lib), so manifest verification passes
# on a healthy install. Spelled to match adb_agent_manifest (absolute, no trailing slash).
src="$work/src"; git clone -q "$origin" "$src"
fh="$work/home"; mkdir -p "$fh/.claude/skills" "$fh/.claude/scripts"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/skills/demo" "$fh/.claude/skills/demo"
for s in precommit-gate implement-issue-gate statusline; do
  ln -s "$src/agents/claude/scripts/$s.sh" "$fh/.claude/scripts/$s.sh"
done
ln -s "$src/scripts/lib" "$fh/.claude/scripts/lib"

# A second clone used to advance origin independently (produces behind/diverged).
c2="$work/c2"; git clone -q "$origin" "$c2"
advance_origin() { git_q "$c2" fetch -q origin; git_q "$c2" reset -q --hard origin/main; git_q "$c2" commit -q --allow-empty -m "$1"; git_q "$c2" push -q origin main; }

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
git_q "$src" commit -q --allow-empty -m local-only
eq "$(run_check "$src/bin/baseline" "$fh")" "ahead|20" "ahead"

# diverged: unique commits on both sides.
reset_src
git_q "$src" commit -q --allow-empty -m local-div
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

# wrong-clone guard must NOT false-trip on a symlinked-path spelling of the SAME clone
# (physical-path comparison via pwd -P) — regression guard for the bug review's finding.
reset_src
aliasdir="$work/alias-src"; ln -s "$src" "$aliasdir"
eq "$(run_check "$aliasdir/bin/baseline" "$fh")" "current|0" "symlinked-path spelling is not treated as wrong-clone"

# The mutating `update` path must also REFUSE ahead state and preserve the local commit
# (the no-data-loss invariant on the write path, not just --check).
reset_src
git_q "$src" commit -q --allow-empty -m local-only-2
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

printf '\nbaseline: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "baseline: PASS"
