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
seed="$work/seed"
mkdir -p "$seed/bin" "$seed/scripts/lib" "$seed/agents/claude"
cp "$ROOT/bin/baseline" "$seed/bin/baseline"; chmod +x "$seed/bin/baseline"
cp "$ROOT/scripts/lib/common.sh" "$seed/scripts/lib/common.sh"
# bin/baseline only checks install.sh EXISTS (install-source detection); --check never
# runs it, so a stub keeps the test hermetic and side-effect free.
printf '#!/usr/bin/env bash\necho "stub-install $*"\n' > "$seed/install.sh"
chmod +x "$seed/install.sh"
printf 'root doc\n' > "$seed/agents/claude/CLAUDE.md"

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

# The install-source clone under test, and a fake HOME pointing into it.
src="$work/src"; git clone -q "$origin" "$src"
fh="$work/home"; mkdir -p "$fh/.claude"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"

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

printf '\nbaseline: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "baseline: PASS"
