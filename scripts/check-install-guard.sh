#!/usr/bin/env bash
# ai-dev-baseline — installer fail-loud guard test (#48). adb_link now REFUSES to create a link
# when its SOURCE is missing (a bad/renamed manifest entry), leaving the destination untouched,
# and that non-zero status threads through install_claude up to install.sh's exit code. This
# proves the TOP-LEVEL guarantee end-to-end against the REAL installer: a missing manifest source
# makes install.sh exit non-zero, never creates a dangling link, and never disturbs a real dest.
#
# It copies the WORKING TREE (uncommitted changes included, unlike a git clone of HEAD) so the
# current install.sh + common.sh are exercised, deletes one fixed manifest source, and asserts.
#
# Usage: bash scripts/check-install-guard.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Copy the working tree (contents of cwd, dotfiles included) then drop .git for speed. `cp -R .`
# is portable across macOS/BSD and GNU and copies the current, uncommitted sources.
repo="$work/repo"; mkdir -p "$repo"
( cd "$ROOT" && cp -R . "$repo" )
rm -rf "$repo/.git"

# Delete ONE manifest source to simulate a bad/renamed entry: the runtime script statusline.sh.
# install.sh's manifest still emits it (a fixed entry), so adb_link's guard must fire.
missing_src="$repo/agents/claude/scripts/statusline.sh"
rm -f "$missing_src"
[ -e "$missing_src" ] && bad "precondition: could not remove the manifest source"

fh="$work/home"; mkdir -p "$fh/.claude/scripts"
# Pre-place a REAL file at the destination the missing source would link to, to prove the guard
# leaves an existing destination untouched (no backup, no clobber, no dangling replacement).
dest="$fh/.claude/scripts/statusline.sh"
printf 'preexisting\n' > "$dest"

log="$work/install.log"
HOME="$fh" bash "$repo/install.sh" --agent claude --no-hooks >"$log" 2>&1
rc=$?

# (1) top-level installer exits non-zero.
if [ "$rc" -ne 0 ]; then ok; else bad "install.sh must exit non-zero when a manifest source is missing (got $rc)"; fi
# (2) stderr names the missing source (loud + specific) with the guard's message.
grep -Fq -- "$missing_src" "$log" && ok || bad "install.sh must name the missing source on stderr"
grep -q 'source does not exist' "$log" && ok || bad "install.sh must emit the guard's fail-loud message"
# (3) the pre-existing real destination is untouched (still a real file, same content, not a link).
if [ -f "$dest" ] && [ ! -L "$dest" ]; then ok; else bad "guard must not disturb a real destination"; fi
[ "$(cat "$dest" 2>/dev/null)" = "preexisting" ] && ok || bad "guard must preserve the destination's content"
# (4) no dangling link was created at the destination.
if [ -L "$dest" ] && [ ! -e "$dest" ]; then bad "guard created a dangling link at the destination"; else ok; fi
# (5) a mid-manifest failure does not abort the rest: the good links still got created.
[ -L "$fh/.claude/CLAUDE.md" ] && ok || bad "install.sh should still link the good entries after one failure"

printf '\ninstall-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "install-guard: PASS"
