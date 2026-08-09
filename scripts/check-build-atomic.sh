#!/usr/bin/env bash
# ai-dev-baseline — scripts/build.sh must publish a generated file by RENAME, never by truncating
# it in place (#268).
#
# THE DEFECT THIS PINS. `render()` used to write the three tracked root docs with a plain
# `} > "$outfile"`, which truncates the destination before the first byte is written. Any abort
# mid-render — ^C, a full disk, an OOM kill — therefore left a TRACKED file half-rendered in the
# working tree, and nothing announced it: the next `build-drift` reports drift, not corruption. The
# skill renderer in the same file had done temp-then-`mv` since it was written.
#
# WHY IT NEEDS ITS OWN SUITE. `build-drift` (selfcheck and CI alike) runs `build.sh` against the
# TRACKED tree, so it cannot inject a failure without damaging the checkout it is checking — and a
# successful build is exactly the case where the two write shapes are indistinguishable.
# `check-workflow-render.sh` runs a copied `build.sh` in a fixture, but its charter is the
# placeholder MAP, not the write. So the hazard is exercised here, in a throwaway tree.
#
# AND IT IS OBSERVED FAILING, because a guard over a hazard nothing triggers reports a clean run
# either way. Three mutations, one per line of the fix, each applied to a COPY of `build.sh` in a
# fixture and each required to make the assertion above it go red:
#
#   1. the naive `} > "$outfile"` publish  -> the sentinel doc is truncated mid-render;
#   2. the unlink before the redirect gone -> a stale `.tmp` SYMLINK is published over the doc;
#   3. the EXIT trap gone                  -> a failed render leaves its `.tmp` in the tree.
#
# Every mutation VERIFIES ITS OWN EDIT APPLIED (exactly one matching line before, none after) and
# fails loud otherwise: a sed that silently matches nothing would turn all three proofs into
# assertions about unmodified code, which is the same silence this suite exists to remove.
#
# Never mutates the tracked tree — every fixture lives under one `mktemp -d`.
#
# Usage: bash scripts/check-build-atomic.sh   (exit 0 = pass, 1 = fail)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

work="$(mktemp -d)" || { echo "check-build-atomic: mktemp failed" >&2; exit 1; }
check_exit_guard "check-build-atomic" "rm -rf \"$work\""

# The bytes that must survive a failed render. Distinctive enough that finding them is proof the
# destination was never opened, and finding anything else is proof it was.
SENTINEL='ADB-SENTINEL-268-DO-NOT-TRUNCATE'
# A string only a COMPLETE root-doc render contains — build.sh emits it as the last line. Its
# absence from a non-sentinel file is what distinguishes "truncated" from merely "different".
TRAILER='Generated from base/practices'

# --- fixtures ---------------------------------------------------------------------------------

# mkfixture <dst> — a throwaway repo skeleton the real build.sh can run in: a copy of build.sh, the
# library that holds its bash-floor gate, enough practices for the root-doc render to have a middle,
# and one valid workflow so the skill render has a source.
mkfixture() {
  local dst="$1"
  mkdir -p "$dst/scripts/lib" "$dst/base/practices" "$dst/base/workflows" || return 1
  cp "$ROOT/scripts/build.sh" "$dst/scripts/build.sh" || return 1
  # build.sh gates its own interpreter (#256), so the fixture needs common.sh. Without it the
  # fixture dies at the source line and every assertion below reports the same "no output" — a
  # fixture failure wearing a render failure's clothes.
  cp "$ROOT/scripts/lib/common.sh" "$dst/scripts/lib/common.sh" || return 1
  printf '# index\n' > "$dst/base/practices/00-index.md"
  printf '# first practice\n\nFIRST-PRACTICE-BODY\n' > "$dst/base/practices/10-aaa.md"
  printf '# second practice\n\nSECOND-PRACTICE-BODY\n' > "$dst/base/practices/20-bbb.md"
  cat > "$dst/base/workflows/fixture.md" <<'EOF'
---
name: fixture
description: a fixture workflow
user-invocable: true
---

# /fixture

Nothing to substitute here.
EOF
}

# break_render <fixture> — make the root-doc render fail PART-WAY THROUGH.
#
# A DIRECTORY named like a practice, not a `chmod 000` file: root reads an unreadable file, so on a
# runner that happens to be root the fault would silently not fire and this suite would report a
# clean run having proved nothing. `cat` refuses a directory as any uid, on Linux and macOS alike.
#
# The name sorts AFTER the two real practices, so the failure lands with content already written —
# which is what makes the naive shape leave a TRUNCATED doc rather than an empty one, and therefore
# what makes mutation 1 a proof rather than a coincidence.
break_render() { mkdir -p "$1/base/practices/90-boom.md"; }

# run_build <fixture> — run the fixture's build.sh in it; log to <fixture>/build.log; return its rc.
run_build() { ( cd "$1" && bash scripts/build.sh ) > "$1/build.log" 2>&1; }

# tmps <fixture> — every sibling temp file left anywhere under the fixture, space-joined and
# fixture-relative. The relative paths come from `cd`-ing rather than from stripping a prefix with
# `sed`: the fixture path is a `mktemp -d` result, and interpolating any path into a sed script is
# the escaping bug this repo keeps writing rules about — a `|` anywhere in `TMPDIR` would turn the
# expression into a syntax error and this helper into one that reports "no temps" for every call.
tmps() { ( cd "$1" 2>/dev/null && find . -name '*.tmp' -print 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' ); }

# --- the mutation primitive -------------------------------------------------------------------

# mutate_line <file> <exact-line> <sed-script> <label>
#
# Requires EXACTLY ONE line of <file> to equal <exact-line> before the edit and NONE after. Both
# halves matter: without the first, a rename in build.sh turns the mutation into a no-op and the
# "proof" becomes an assertion about unmodified code; without the second, a sed that matched but
# did not substitute would do the same. Whole-line matching, because `rm -f "$build_tmp"` appears
# both in render() and inside build_cleanup() and only one of them is being removed.
mutate_line() {
  local f="$1" line="$2" script="$3" label="$4" n
  n="$(grep -Fxc -- "$line" "$f")"
  if [ "$n" -ne 1 ]; then
    bad "$label: expected exactly 1 line [$line] in the copied build.sh, found $n — the mutation harness no longer describes the code it mutates, so it proves nothing"
    return 1
  fi
  sed "$script" "$f" > "$f.mut" && mv "$f.mut" "$f" || { bad "$label: could not apply the mutation"; return 1; }
  n="$(grep -Fxc -- "$line" "$f")"
  if [ "$n" -ne 0 ]; then
    bad "$label: the mutation left [$line] in place ($n remaining) — it did not take effect"
    return 1
  fi
  return 0
}

# ============================ 1. control: a clean build still works ============================
# Not garnish. Every assertion below reads a failed build, and a fixture that cannot build at all
# would satisfy most of them for the wrong reason.
d="$work/control"
mkfixture "$d" || bad "control: could not build the fixture"
run_build "$d"; rc=$?
yes "$rc" "control: a clean fixture builds successfully"
[ -s "$d/agents/claude/CLAUDE.md" ] && ok || bad "control: the root doc was not written"
has "$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)" "$TRAILER" "control: the root doc is a COMPLETE render"
[ -s "$d/agents/claude/skills/fixture/SKILL.md" ] && ok || bad "control: the skill was not rendered"
eq "$(tmps "$d")" "" "control: a successful build leaves no sibling temp file"

# ===================== 2. a failed render must not touch the destination ======================
d="$work/atomic"
mkfixture "$d" || bad "atomic: could not build the fixture"
run_build "$d" || bad "atomic: the fixture's first (clean) build failed"
printf '%s\n' "$SENTINEL" > "$d/agents/claude/CLAUDE.md"
break_render "$d"
run_build "$d"; rc=$?
no "$rc" "a render that fails part-way fails the build"
# THE FAULT MUST BE THE INJECTED ONE. A build that failed for an unrelated reason — a missing
# library, a syntax error — would leave the destination untouched too, and would satisfy the
# assertion below while exercising nothing.
has "$(cat "$d/build.log" 2>/dev/null)" "90-boom.md" "the build failed on the INJECTED fault, not on something else"
eq "$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)" "$SENTINEL" \
  "the tracked root doc is byte-exact after a failed render (never truncated)"
eq "$(tmps "$d")" "" "a failed render leaves no sibling temp behind"

# ------- 2a. MUTATION: the pre-#268 truncate-and-write must destroy that same sentinel ---------
# Without this, the assertion above is green on any build that fails early enough, and green
# forever if someone reverts the fix.
d="$work/mut-naive"
mkfixture "$d" || bad "mut-naive: could not build the fixture"
mutated=1
mutate_line "$d/scripts/build.sh" '  } > "$build_tmp"' 's|^  } > "\$build_tmp"$|  } > "$outfile"|' \
  "mut-naive" || mutated=0
mutate_line "$d/scripts/build.sh" '  mv "$build_tmp" "$outfile"' '\|^  mv "\$build_tmp" "\$outfile"$|d' \
  "mut-naive" || mutated=0
if [ "$mutated" -eq 1 ]; then
  run_build "$d" || bad "mut-naive: the mutated fixture's clean build failed — the mutation broke the script rather than changing its write shape"
  printf '%s\n' "$SENTINEL" > "$d/agents/claude/CLAUDE.md"
  break_render "$d"
  run_build "$d"; rc=$?
  no "$rc" "mut-naive: the mutated build still fails on the injected fault"
  got="$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)"
  if [ "$got" != "$SENTINEL" ]; then ok; else
    bad "MUTATION 1 DID NOT FIRE: with the naive \`> \"\$outfile\"\` publish restored, the sentinel SURVIVED a failed render — this suite cannot tell the two write shapes apart and proves nothing"
  fi
  # ...and what it left is specifically a TORN file: the render got far enough to emit the first
  # practice and never reached the trailer. "Different from the sentinel" alone would also be
  # satisfied by an empty file, which is a weaker and less honest claim.
  has "$got" "FIRST-PRACTICE-BODY" "mut-naive: what the naive publish leaves is a PARTIAL render"
  hasnt "$got" "$TRAILER" "mut-naive: ...missing the trailer a complete render ends with — i.e. truncated"
fi

# =============== 3. a stale or hostile sibling temp is never published over the doc ============
# `>` writes THROUGH a symlink, so a leftover `CLAUDE.md.tmp` pointing elsewhere would be filled
# with the render and then renamed onto the tracked root doc — replacing a generated file with a
# link, and clobbering whatever it pointed at on the way.
d="$work/stale"
mkfixture "$d" || bad "stale: could not build the fixture"
run_build "$d" || bad "stale: the fixture's first (clean) build failed"
outside="$work/stale-outside.txt"
printf 'OUTSIDE-UNTOUCHED\n' > "$outside"
ln -s "$outside" "$d/agents/claude/CLAUDE.md.tmp"
run_build "$d"; rc=$?
yes "$rc" "stale: a build with a leftover .tmp symlink still succeeds"
[ ! -L "$d/agents/claude/CLAUDE.md" ] && ok || bad "the tracked root doc was REPLACED BY A SYMLINK from a stale .tmp"
eq "$(cat "$outside")" "OUTSIDE-UNTOUCHED" "the stale symlink's target is never written through"
has "$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)" "$TRAILER" "stale: the root doc is still a complete render"

# ------- 3a. MUTATION: without the unlink, that symlink IS followed and published --------------
d="$work/mut-nounlink"
mkfixture "$d" || bad "mut-nounlink: could not build the fixture"
if mutate_line "$d/scripts/build.sh" '  rm -f "$build_tmp"' '\|^  rm -f "\$build_tmp"$|d' "mut-nounlink"; then
  run_build "$d" || bad "mut-nounlink: the mutated fixture's clean build failed"
  outside2="$work/nounlink-outside.txt"
  printf 'OUTSIDE-UNTOUCHED\n' > "$outside2"
  ln -s "$outside2" "$d/agents/claude/CLAUDE.md.tmp"
  run_build "$d" || bad "mut-nounlink: the mutated build failed unexpectedly"
  if [ -L "$d/agents/claude/CLAUDE.md" ] || [ "$(cat "$outside2")" != "OUTSIDE-UNTOUCHED" ]; then ok; else
    bad "MUTATION 2 DID NOT FIRE: with the unlink removed, the stale .tmp symlink was still not followed — assertion 3 proves nothing"
  fi
fi

# ================== 4. MUTATION: without the EXIT trap, a failed render leaks ==================
# This is what proves the trap in assertion 2's "leaves no sibling temp behind" is load-bearing:
# render() has no cleanup of its own on the failure path, so the trap is the only thing removing it.
d="$work/mut-notrap"
mkfixture "$d" || bad "mut-notrap: could not build the fixture"
if mutate_line "$d/scripts/build.sh" 'trap build_cleanup EXIT' '\|^trap build_cleanup EXIT$|d' "mut-notrap"; then
  run_build "$d" || bad "mut-notrap: the mutated fixture's clean build failed"
  break_render "$d"
  run_build "$d"; rc=$?
  no "$rc" "mut-notrap: the mutated build still fails on the injected fault"
  if [ -n "$(tmps "$d")" ]; then ok; else
    bad "MUTATION 3 DID NOT FIRE: with the EXIT trap removed, a failed render still left no temp file — assertion 2's residue check proves nothing"
  fi
fi

# ============ 4b. something UNREMOVABLE in the temp path fails closed, never over it ===========
# The unlink in section 3 is what makes the publish safe, so what it does when it CANNOT run is a
# real branch, not a curiosity: a directory sitting at `CLAUDE.md.tmp` (a stale `mkdir`, an
# unpacked archive) makes `rm -f` fail. The build must stop with the reason on stderr and the
# tracked doc untouched — publishing over a path it could not clear is the one outcome that would
# turn this fix into a different corruption.
d="$work/blocked"
mkfixture "$d" || bad "blocked: could not build the fixture"
run_build "$d" || bad "blocked: the fixture's first (clean) build failed"
printf '%s\n' "$SENTINEL" > "$d/agents/claude/CLAUDE.md"
mkdir -p "$d/agents/claude/CLAUDE.md.tmp/occupied"
run_build "$d"; rc=$?
no "$rc" "an unremovable temp path fails the build"
has "$(cat "$d/build.log" 2>/dev/null)" "CLAUDE.md.tmp" "...naming the path it could not clear"
eq "$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)" "$SENTINEL" "...and the tracked doc is left untouched"
# The trap's removal fails too, and must do so SILENTLY: a second `rm:` line buries the one that
# explains the failure. Exactly one occurrence, not "at least one".
#
# COUNTED BY THE PATH, NOT BY `rm`'s MESSAGE. The two platforms this suite runs on word it
# differently — GNU coreutils prints `Is a directory` (capital, it is strerror(EISDIR)) and BSD/macOS
# prints `is a directory` — so matching the sentence would have passed on the workstation and failed
# on the Linux runner. The path is the part both platforms agree on, and it is what the assertion
# actually means.
eq "$(grep -c 'CLAUDE\.md\.tmp' "$d/build.log" 2>/dev/null)" "1" \
  "...and the failure is reported ONCE (best-effort cleanup does not echo it again)"

# ================== 5. the skill path leaves no residue either ================================
# A PARITY PIN, and it is honest about what it is: the unresolved-placeholder path has always had
# its own `rm -f`, so this assertion was green before #268 and stays green after. What it guards is
# that the skill renderer keeps publishing without residue while its sibling changes around it —
# the asymmetry between the two write paths is the whole subject of this file.
d="$work/skill"
mkfixture "$d" || bad "skill: could not build the fixture"
printf 'An unmapped {{NOPE}} token.\n' >> "$d/base/workflows/fixture.md"
run_build "$d"; rc=$?
eq "$rc" "3" "an unmapped placeholder fails the build loud (rc 3)"
eq "$(tmps "$d")" "" "...and leaves no sibling temp beside the skill trees"

check_summary "check-build-atomic"
