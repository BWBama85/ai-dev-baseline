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
# either way. Three mutations, each applied to a COPY of `build.sh` in a fixture and each required
# to make the assertion above it go red:
#
#   1. the naive `} > "$outfile"` publish restored -> the sentinel doc is truncated mid-render;
#   2. staging returned to a fixed `$dest.tmp`     -> a pre-existing `.tmp` symlink is followed and
#                                                     published over the tracked doc;
#   3. the EXIT trap removed                       -> a failed render leaves its temp in the tree.
#
# (Each mutation is one CHANGE to the publish mechanism, not necessarily one line: 1 and 2 each edit
# two lines, because restoring the superseded shape takes two.)
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

# The bytes that must survive a failed render, kept as a FILE so comparisons can be byte-exact.
# `[ "$(cat f)" = "$SENTINEL" ]` cannot be: command substitution strips every trailing newline, so a
# file with the right bytes and a missing — or doubled — final newline compares EQUAL. A dropped
# final newline is one of the corruptions this suite exists to detect, so the comparison is `cmp`.
SENTINEL="$work/sentinel"
printf 'ADB-SENTINEL-268-DO-NOT-TRUNCATE\n' > "$SENTINEL"
# A string only a COMPLETE root-doc render contains — build.sh emits it as the last line.
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

# tmps <fixture> — every staged temp left anywhere under the fixture, space-joined and relative.
#
# BOTH SPELLINGS. Staging is `mktemp "$dest.tmp.XXXXXX"`, so the live code leaves `…md.tmp.a1B2c3`;
# mutation 2 restores the superseded fixed `…md.tmp`. A pattern matching only one of them would
# report "no residue" for whichever shape it was not written for — a helper that answers clean by
# not looking, which is the failure mode this whole file is about.
#
# The relative paths come from `cd`-ing rather than from stripping a prefix with `sed`: the fixture
# path is a `mktemp -d` result, and interpolating any path into a sed script is the escaping bug
# this repo keeps writing rules about — a `|` anywhere in `TMPDIR` would make the expression a
# syntax error and this helper one that reports "no temps" for every call.
tmps() {
  ( cd "$1" 2>/dev/null && find . \( -name '*.tmp' -o -name '*.tmp.*' \) -print 2>/dev/null \
      | LC_ALL=C sort | tr '\n' ' ' )
}

# --- the mutation primitive -------------------------------------------------------------------

# mutate_line <file> <exact-line> <sed-script> <label> — a thin DELEGATION to check-lib.sh's
# `check_mutate_line`, which is where this harness now lives.
#
# It was promoted when check-precommit-gate.sh needed the same discipline for #299: a second
# byte-identical copy of a mutation harness is precisely the drift this repo's own law forbids, and
# a harness that has silently diverged between two suites is worse than one home, because each
# suite's proofs then rest on a different set of guarantees. The alias stays so the call sites below
# keep reading in build.sh's own vocabulary — it must remain a DELEGATION, never a second copy.
mutate_line() { check_mutate_line "$@"; }

# mutate_fixed_temp <build.sh> <label> — return staging to the superseded fixed `$dest.tmp` shape.
# Two edits, because that is what restoring it takes: the unique name, and the mode it no longer
# needs to set. `#` as the sed delimiter — the replaced line contains `||`, which would end a `|`.
mutate_fixed_temp() {
  local f="$1" label="$2" okc=1
  mutate_line "$f" '  build_tmp="$(mktemp "$dest.tmp.XXXXXX")" || return 1' \
    's#^  build_tmp="\$(mktemp "\$dest\.tmp\.XXXXXX")" || return 1$#  build_tmp="$dest.tmp"#' \
    "$label" || okc=0
  mutate_line "$f" '  chmod 644 "$build_tmp" || return 1' \
    '\#^  chmod 644 "\$build_tmp" || return 1$#d' "$label" || okc=0
  [ "$okc" -eq 1 ]
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
eq "$(tmps "$d")" "" "control: a successful build leaves no staged temp"

# ===================== 2. a failed render must not touch the destination ======================
d="$work/atomic"
mkfixture "$d" || bad "atomic: could not build the fixture"
run_build "$d" || bad "atomic: the fixture's first (clean) build failed"
cp "$SENTINEL" "$d/agents/claude/CLAUDE.md"
break_render "$d"
run_build "$d"; rc=$?
no "$rc" "a render that fails part-way fails the build"
# THE FAULT MUST BE THE INJECTED ONE. A build that failed for an unrelated reason — a missing
# library, a syntax error — would leave the destination untouched too, and would satisfy the
# assertion below while exercising nothing.
has "$(cat "$d/build.log" 2>/dev/null)" "90-boom.md" "the build failed on the INJECTED fault, not on something else"
cmp -s "$SENTINEL" "$d/agents/claude/CLAUDE.md" && ok \
  || bad "the tracked root doc is NOT byte-exact after a failed render"
eq "$(tmps "$d")" "" "a failed render leaves no staged temp behind"

# ------- 2a. MUTATION: the pre-#268 truncate-and-write must destroy that same sentinel ---------
# Without this, the assertion above is green on any build that fails early enough, and green
# forever if someone reverts the fix.
d="$work/mut-naive"
mkfixture "$d" || bad "mut-naive: could not build the fixture"
mutated=1
mutate_line "$d/scripts/build.sh" '  } > "$build_tmp"' 's|^  } > "\$build_tmp"$|  } > "$outfile"|' \
  "mut-naive" || mutated=0
mutate_line "$d/scripts/build.sh" '  build_publish "$outfile"' '\|^  build_publish "\$outfile"$|d' \
  "mut-naive" || mutated=0
if [ "$mutated" -eq 1 ]; then
  run_build "$d" || bad "mut-naive: the mutated fixture's clean build failed — the mutation broke the script rather than changing its write shape"
  cp "$SENTINEL" "$d/agents/claude/CLAUDE.md"
  break_render "$d"
  run_build "$d"; rc=$?
  no "$rc" "mut-naive: the mutated build still fails on the injected fault"
  if cmp -s "$SENTINEL" "$d/agents/claude/CLAUDE.md"; then
    bad "MUTATION 1 DID NOT FIRE: with the naive \`> \"\$outfile\"\` publish restored, the sentinel SURVIVED a failed render — this suite cannot tell the two write shapes apart and proves nothing"
  else ok; fi
  # ...and what it left is specifically a TORN file: the render got far enough to emit the first
  # practice and never reached the trailer. "Different from the sentinel" alone would also be
  # satisfied by an empty file, which is a weaker and less honest claim.
  got="$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)"
  has "$got" "FIRST-PRACTICE-BODY" "mut-naive: what the naive publish leaves is a PARTIAL render"
  hasnt "$got" "$TRAILER" "mut-naive: ...missing the trailer a complete render ends with — i.e. truncated"
fi

# ========== 3. nothing sitting at the predictable `$dest.tmp` name can affect a build ==========
# Staging is `mktemp "$dest.tmp.XXXXXX"`, so the fixed sibling name is not used at all. That is what
# makes two concurrent builds safe — they cannot share a staged file, so neither can rename the
# other's half-written one over the destination — and it is what closes the symlink hole, since
# there is no "clear the path, then open it" window for anything to slip into. Both are asserted
# here through their observable consequence: a pre-existing `CLAUDE.md.tmp` is left completely
# alone, whatever it is.
d="$work/fixedname"
mkfixture "$d" || bad "fixedname: could not build the fixture"
run_build "$d" || bad "fixedname: the fixture's first (clean) build failed"
outside="$work/fixedname-outside.txt"
printf 'OUTSIDE-UNTOUCHED\n' > "$outside"
ln -s "$outside" "$d/agents/claude/CLAUDE.md.tmp"                 # a hostile/stale symlink
printf 'PRE-EXISTING\n' > "$d/agents/codex/AGENTS.md.tmp"         # ...and a plain leftover
mkdir -p "$d/agents/gemini/GEMINI.md.tmp/occupied"                # ...and one that cannot be removed
run_build "$d"; rc=$?
yes "$rc" "fixedname: a build succeeds regardless of what occupies the predictable temp name"
[ ! -L "$d/agents/claude/CLAUDE.md" ] && ok || bad "the tracked root doc was REPLACED BY A SYMLINK sitting at the predictable temp name"
eq "$(cat "$outside")" "OUTSIDE-UNTOUCHED" "a symlink at that name is never written through"
eq "$(cat "$d/agents/codex/AGENTS.md.tmp" 2>/dev/null)" "PRE-EXISTING" "a plain file at that name is never consumed"
[ -d "$d/agents/gemini/GEMINI.md.tmp/occupied" ] && ok || bad "a directory at that name was disturbed"
has "$(cat "$d/agents/claude/CLAUDE.md" 2>/dev/null)" "$TRAILER" "fixedname: the root doc is still a complete render"

# ------- 3a. MUTATION: with a fixed temp name, that symlink IS followed and published ----------
d="$work/mut-fixed"
mkfixture "$d" || bad "mut-fixed: could not build the fixture"
if mutate_fixed_temp "$d/scripts/build.sh" "mut-fixed"; then
  run_build "$d" || bad "mut-fixed: the mutated fixture's clean build failed"
  outside2="$work/mut-fixed-outside.txt"
  printf 'OUTSIDE-UNTOUCHED\n' > "$outside2"
  ln -s "$outside2" "$d/agents/claude/CLAUDE.md.tmp"
  run_build "$d" >/dev/null 2>&1
  if [ -L "$d/agents/claude/CLAUDE.md" ] || [ "$(cat "$outside2")" != "OUTSIDE-UNTOUCHED" ]; then ok; else
    bad "MUTATION 2 DID NOT FIRE: with staging returned to a fixed \$dest.tmp, the pre-existing symlink was still not followed — assertion 3 proves nothing"
  fi
fi

# ================== 4. MUTATION: without the EXIT trap, a failed render leaks ==================
# This is what proves the trap in assertion 2's "leaves no staged temp behind" is load-bearing:
# render() has no cleanup of its own on the failure path, so the trap is the only thing removing it.
d="$work/mut-notrap"
mkfixture "$d" || bad "mut-notrap: could not build the fixture"
if mutate_line "$d/scripts/build.sh" 'trap build_cleanup EXIT' '\|^trap build_cleanup EXIT$|d' "mut-notrap"; then
  run_build "$d" || bad "mut-notrap: the mutated fixture's clean build failed"
  break_render "$d"
  run_build "$d"; rc=$?
  no "$rc" "mut-notrap: the mutated build still fails on the injected fault"
  if [ -n "$(tmps "$d")" ]; then ok; else
    bad "MUTATION 3 DID NOT FIRE: with the EXIT trap removed, a failed render still left no temp — assertion 2's residue check proves nothing"
  fi
fi

# ============ 5. the published mode is CHOSEN, not inherited from the caller's umask ===========
# `mktemp` creates 0600 and the truncate-and-write this replaced inherited the destination's mode,
# so publishing straight from the temp would silently narrow every generated doc — while taking the
# umask instead would let a permissive one produce group/world-writable instruction files. Git
# records no difference among non-executable modes, so nothing else in this repo would ever notice.
# Asserted under a HOSTILE umask at each extreme, which is the only way to tell "chosen" from
# "happened to match".
for um in 077 000; do
  d="$work/mode-$um"
  mkfixture "$d" || bad "mode($um): could not build the fixture"
  ( cd "$d" && umask "$um" && bash scripts/build.sh ) > "$d/build.log" 2>&1 \
    || bad "mode($um): the build failed"
  eq "$(ls -l "$d/agents/claude/CLAUDE.md" 2>/dev/null | cut -c1-10)" "-rw-r--r--" \
    "the published root doc is 644 under umask $um"
  eq "$(ls -l "$d/agents/claude/skills/fixture/SKILL.md" 2>/dev/null | cut -c1-10)" "-rw-r--r--" \
    "the published skill is 644 under umask $um"
done

# ================== 6. the skill path leaves no residue either ================================
# A PARITY PIN, and it is honest about what it is: the unresolved-placeholder path has always had
# its own `rm -f`, so this assertion was green before #268 and stays green after. What it guards is
# that the skill renderer keeps publishing without residue while its sibling changes around it —
# the asymmetry between the two write paths is the whole subject of this file.
d="$work/skill"
mkfixture "$d" || bad "skill: could not build the fixture"
printf 'An unmapped {{NOPE}} token.\n' >> "$d/base/workflows/fixture.md"
run_build "$d"; rc=$?
eq "$rc" "3" "an unmapped placeholder fails the build loud (rc 3)"
eq "$(tmps "$d")" "" "...and leaves no staged temp beside the skill trees"

check_summary "check-build-atomic"
