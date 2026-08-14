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
. scripts/check-lib.sh   # ok/bad + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Copy the working tree (contents of cwd, dotfiles included) then drop .git for speed — through
# the shared helper, so the three suites that need a throwaway tree copy cannot drift apart.
repo="$work/repo"
check_copy_worktree "$ROOT" "$repo" || { echo "check-install-guard: could not copy the tree" >&2; exit 1; }

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

# --- a HOME the manifest cannot represent (#324, D64) -------------------------------------------
#
# The SAME end-to-end claim, for the other fault class. Above, one entry is bad and install links
# the rest; here the RECORD FORMAT itself cannot carry the paths, so the correct outcome is the
# opposite — refuse the whole surface and write nothing at all.
#
# THIS RUNS THE REAL install.sh, which is the only way to test what actually broke. Every unit
# assertion in check-common-lib.sh passes against a build where the producer refuses correctly and
# install.sh still swallows the status in its heredoc — a manifest nobody can produce becomes an
# EMPTY manifest, zero links, and exit 0. The gap between "the primitive refuses" and "the
# installer refuses" is exactly one command substitution, and only this test spans it.
#
# `$HOME` is the input to use rather than the clone path: it reaches the producer intact (an
# environment variable is never passed through a `$(…)`), whereas a clone directory whose name
# ENDS in a newline is truncated by each entry point's own bootstrap before the producer is
# reached — a separate defect, tracked in #343 and deliberately not claimed here.
nl_home="$work/nlhome"$'\n'"shadow"
mkdir -p "$nl_home/.claude"
# The truncated sibling is the whole danger: `<work>/nlhome` is a REAL directory with real content,
# and it is what the split record names as a destination. It must be created on its own — the
# mkdir above builds `nlhome<NL>shadow`, a single directory whose NAME contains a newline, and it
# does not bring a `nlhome` sibling into existence.
prefix="$work/nlhome"
mkdir -p "$prefix"
printf 'PRECIOUS\n' > "$prefix/keep.txt"
cp "$prefix/keep.txt" "$work/nl-pristine.txt"
# A second clone copy, so the missing statusline.sh above cannot be what fails this run.
repo2="$work/repo2"
check_copy_worktree "$ROOT" "$repo2" || { echo "check-install-guard: could not copy the tree (2)" >&2; exit 1; }

nl_log="$work/install-nl.log"
HOME="$nl_home" bash "$repo2/install.sh" --agent claude --no-hooks >"$nl_log" 2>&1
nl_rc=$?

if [ "$nl_rc" -ne 0 ]; then ok; else bad "install.sh must exit non-zero when HOME cannot be represented in the manifest (got $nl_rc)"; fi
grep -q 'cannot represent' "$nl_log" && ok || bad "install.sh must emit the producer's refusal diagnostic"
grep -q 'nothing was linked' "$nl_log" && ok || bad "install.sh must say that nothing was linked"
# THE FILESYSTEM ASSERTIONS ARE THE POINT. A non-zero exit is satisfied by the pre-fix code too —
# it moved the real directory into backup and symlinked over it, THEN returned non-zero.
if [ -d "$prefix" ] && [ ! -L "$prefix" ]; then ok; else bad "install.sh must not replace the truncated-prefix directory"; fi
if cmp -s "$prefix/keep.txt" "$work/nl-pristine.txt"; then ok; else bad "install.sh must leave the truncated-prefix content byte-identical"; fi
# And no link was created anywhere under the real (newline-bearing) home either.
if [ -e "$nl_home/.claude/CLAUDE.md" ]; then bad "install.sh must link nothing when it refuses"; else ok; fi

# The uninstaller refuses the same pair, and says so instead of printing "Uninstalled".
nl_ulog="$work/uninstall-nl.log"
HOME="$nl_home" bash "$repo2/uninstall.sh" --agent claude >"$nl_ulog" 2>&1
nl_urc=$?
if [ "$nl_urc" -ne 0 ]; then ok; else bad "uninstall.sh must exit non-zero when HOME cannot be represented (got $nl_urc)"; fi
grep -q 'NOTHING was unlinked' "$nl_ulog" && ok || bad "uninstall.sh must say that nothing was unlinked"
grep -q 'Uninstall INCOMPLETE' "$nl_ulog" && ok || bad "uninstall.sh must not report a clean uninstall it did not perform"

check_summary "install-guard"
