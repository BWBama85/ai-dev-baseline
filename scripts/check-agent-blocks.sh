#!/usr/bin/env bash
# ai-dev-baseline — the per-agent block facility renders a DIFFERENT instruction density to
# different agents, and NOTHING ELSE differently (#304).
#
# WHAT IT PINS. `scripts/build.sh`'s `block_filter` resolves
#
#     <!-- adb:except claude -->  …  <!-- adb:end -->
#
# on BOTH render paths — the root-doc `render()` and the skill `render_agent_skill()`. The
# facility's whole purpose is that two renders of one source differ in a marked region, so the
# thing that must be proved is a CONJUNCTION: they differ THERE, and they are byte-identical
# EVERYWHERE ELSE. Half of that is what a careless implementation gets right by accident.
#
# WHY IT NEEDS ITS OWN SUITE, and this is the guard-silence argument from
# `base/practices/self-review.md` applied to a renderer:
#
#   * `build-drift` proves the tracked generated files match a fresh build. It cannot notice that
#     a per-agent facility renders the SAME bytes to every agent — it would simply agree with
#     whatever was committed. A facility that silently stopped varying anything looks exactly like
#     one that worked.
#   * It equally cannot notice the opposite overreach: a shared paragraph reworded in one render
#     only. Regenerate, commit, and `build-drift` is green on both.
#   * `check-workflow-render.sh` runs a copied `build.sh` in a fixture, but its charter is the
#     `{{TOKEN}}` MAP — substitution, not block inclusion — and it exercises the skill path alone.
#
# THE ORACLE IS THREE LITERAL SOURCES, not a diff computed from the marked one. For each path the
# fixture carries:
#
#     A — shared content WITH an `adb:except claude` block
#     B — the same content with the block and both markers physically removed  (what claude wants)
#     C — the same content with only the two MARKER LINES removed              (what codex wants)
#
# and asserts `render(A, claude) == render(B, claude)` and `render(A, codex) == render(C, codex)`
# BYTE-FOR-BYTE. B and C are written out literally rather than derived from A, so the expectation
# is genuinely independent of the code under test — a filter bug and an oracle bug cannot cancel.
# Byte equality also carries "identical everywhere else" without a separate assertion, including
# the blank lines and separators around the block, which is exactly where a line-reconstructing
# implementation goes wrong.
#
# AND IT IS OBSERVED FAILING. Four mutations, each applied to a COPY of `build.sh` in a fixture and
# each required to make the assertion above it go red:
#
#   1. inclusion forced ON  (`emit = 1`)      -> claude receives the block on BOTH paths;
#   2. inclusion forced OFF (`emit = 0`)      -> codex/gemini LOSE it on BOTH paths;
#   3. the root-doc surviving-marker scan deleted -> a misspelled marker ships into a root doc;
#   4. the skill surviving-marker scan deleted    -> …and into a skill.
#
# 1 and 2 are the pair that matters: either one alone is satisfiable by a filter that is wrong in
# the other direction. Each mutation VERIFIES ITS OWN EDIT APPLIED (exactly one matching line
# before, none after) via check-lib.sh's `check_mutate_line`, so a sed that silently matched
# nothing cannot turn a proof into an assertion about unmodified code.
#
# Never mutates the tracked tree — every fixture lives under one `mktemp -d`. The tracked-tree
# section at the end only READS.
#
# Usage: bash scripts/check-agent-blocks.sh   (exit 0 = pass, 1 = fail)

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

work="$(mktemp -d)" || { echo "check-agent-blocks: mktemp failed" >&2; exit 1; }
check_exit_guard "check-agent-blocks" "rm -rf \"$work\""

# --- fixtures ---------------------------------------------------------------------------------

# mkfixture <dst> — a throwaway repo skeleton the real build.sh can run in.
#
# It carries a copy of build.sh, the library holding its bash-floor gate, an index (skipped by the
# renderer) and ONE practice + ONE workflow, both written by the caller afterwards. Deliberately
# minimal: every byte the renders are compared on should be a byte this suite put there.
mkfixture() {
  local dst="$1"
  mkdir -p "$dst/scripts/lib" "$dst/base/practices" "$dst/base/workflows" || return 1
  cp "$ROOT/scripts/build.sh" "$dst/scripts/build.sh" || return 1
  # build.sh gates its own interpreter (#256), so the fixture needs common.sh. Without it the
  # fixture dies at the source line and every assertion below reports the same "no output" — a
  # fixture failure wearing a render failure's clothes.
  cp "$ROOT/scripts/lib/common.sh" "$dst/scripts/lib/common.sh" || return 1
  printf '# index\n' > "$dst/base/practices/00-index.md"
}

run_build() { ( cd "$1" && bash scripts/build.sh ) > "$1/build.log" 2>&1; }

# --- the three practice sources (root-doc path) ------------------------------------------------
# Note the authoring idiom the source contract documents: the OPENING marker sits immediately
# after the preceding content line and the block's own blank line goes INSIDE it, so both the
# included and the excluded render come out with correct markdown spacing. B and C below are what
# that idiom is supposed to produce, written by hand.

P_A="$work/practice-A.md"; P_B="$work/practice-B.md"; P_C="$work/practice-C.md"
cat > "$P_A" <<'EOF'
# fixture practice

SHARED-BEFORE-SENTINEL
<!-- adb:except claude -->

DENSITY-BLOCK-SENTINEL

- a bullet inside the block
<!-- adb:end -->

SHARED-AFTER-SENTINEL
EOF
cat > "$P_B" <<'EOF'
# fixture practice

SHARED-BEFORE-SENTINEL

SHARED-AFTER-SENTINEL
EOF
cat > "$P_C" <<'EOF'
# fixture practice

SHARED-BEFORE-SENTINEL

DENSITY-BLOCK-SENTINEL

- a bullet inside the block

SHARED-AFTER-SENTINEL
EOF

# --- the three workflow sources (skill path) ---------------------------------------------------
# `wf_src <marker-body>` — a valid workflow whose frontmatter satisfies build.sh's validation
# (line 1 `---`, `name:` equal to the stem, single-line `description:`). No {{TOKEN}} appears, so
# the two synth-frontmatter renders (codex, gemini) are byte-identical and any difference between
# them is attributable to block inclusion alone.
wf_src() { # <dst> <body-file>
  { printf -- '---\nname: fixture\ndescription: a fixture workflow\nuser-invocable: true\n---\n\n# /fixture\n\n'
    cat "$2"; } > "$1"
}
W_A="$work/wf-A.md"; W_B="$work/wf-B.md"; W_C="$work/wf-C.md"
wf_src "$W_A" "$P_A"; wf_src "$W_B" "$P_B"; wf_src "$W_C" "$P_C"

# build_one <fixture> <practice-src> <workflow-src> — a fresh fixture rendered from one pair of
# sources. Returns the build's rc; artifacts land under <fixture>/agents/.
build_one() {
  local d="$1"
  mkfixture "$d" || return 2
  cp "$2" "$d/base/practices/10-fixture.md" || return 2
  cp "$3" "$d/base/workflows/fixture.md" || return 2
  run_build "$d"
}

doc() { printf '%s/agents/%s/%s' "$1" "$2" "$3"; }
CDOC=CLAUDE.md; XDOC=AGENTS.md; GDOC=GEMINI.md
skill() { printf '%s/agents/%s/skills/fixture/SKILL.md' "$1" "$2"; }

# ======================= 1. control: the filter is a NO-OP on unmarked input =====================
# Not garnish. Every assertion below is about a marked source; if the filter perturbed ordinary
# content — a dropped final newline, a lost blank line — the equalities below would still hold
# (both sides pass through the same filter) while every real practice silently changed.
d="$work/control"
build_one "$d" "$P_B" "$W_B"; rc=$?
yes "$rc" "control: a fixture with no markers builds"
cmp -s "$(doc "$d" claude "$CDOC")" "$(doc "$d" codex "$XDOC")" && ok \
  || bad "control: an UNMARKED source renders differently to claude and codex — the filter is not a no-op on ordinary content"
cmp -s "$(doc "$d" codex "$XDOC")" "$(doc "$d" gemini "$GDOC")" && ok \
  || bad "control: an unmarked source renders differently to codex and gemini"
cmp -s "$(skill "$d" codex)" "$(skill "$d" gemini)" && ok \
  || bad "control: an unmarked workflow renders differently to codex and gemini"

# ============ 2. the marked source: the two renders differ THERE and nowhere else ===============
# `d` is the marked build; `db` and `dc` are the two hand-written oracles.
d="$work/marked"; db="$work/oracle-b"; dc="$work/oracle-c"
build_one "$d"  "$P_A" "$W_A"; rc=$?; yes "$rc" "a marked source builds"
build_one "$db" "$P_B" "$W_B" || bad "oracle B failed to build"
build_one "$dc" "$P_C" "$W_C" || bad "oracle C failed to build"

# --- 2a. root-doc path -------------------------------------------------------------------------
cmp -s "$(doc "$d" claude "$CDOC")" "$(doc "$db" claude "$CDOC")" && ok \
  || bad "ROOT/claude: the render is not byte-identical to the block-free oracle — claude got more (or less) than the shared content"
cmp -s "$(doc "$d" codex "$XDOC")" "$(doc "$dc" codex "$XDOC")" && ok \
  || bad "ROOT/codex: the render is not byte-identical to the markers-stripped oracle — codex did not get exactly shared+block"
cmp -s "$(doc "$d" gemini "$GDOC")" "$(doc "$dc" gemini "$GDOC")" && ok \
  || bad "ROOT/gemini: an unlisted agent did not inherit the block — `adb:except` must exclude only what it names"

# The equalities above already imply these, but a failing `cmp` says only "differ"; these name
# WHICH way it went, which is the difference between a two-minute fix and a bisect.
hasnt "$(cat "$(doc "$d" claude "$CDOC")")" "DENSITY-BLOCK-SENTINEL" "ROOT/claude: the excluded block is absent"
has   "$(cat "$(doc "$d" claude "$CDOC")")" "SHARED-BEFORE-SENTINEL"  "ROOT/claude: shared content before the block survives"
has   "$(cat "$(doc "$d" claude "$CDOC")")" "SHARED-AFTER-SENTINEL"   "ROOT/claude: shared content after the block survives"
has   "$(cat "$(doc "$d" codex "$XDOC")")"  "DENSITY-BLOCK-SENTINEL" "ROOT/codex: the included block is present"

# --- 2b. skill path ----------------------------------------------------------------------------
# The SAME facility, exercised through the OTHER renderer. Proving it on one path says nothing
# about the other: they are two different awk programs sharing one filter, and the issue's §2
# needs a block on each.
cmp -s "$(skill "$d" claude)" "$(skill "$db" claude)" && ok \
  || bad "SKILL/claude: the render is not byte-identical to the block-free oracle"
cmp -s "$(skill "$d" codex)" "$(skill "$dc" codex)" && ok \
  || bad "SKILL/codex: the render is not byte-identical to the markers-stripped oracle"
cmp -s "$(skill "$d" gemini)" "$(skill "$dc" gemini)" && ok \
  || bad "SKILL/gemini: an unlisted agent did not inherit the block"
hasnt "$(cat "$(skill "$d" claude)")" "DENSITY-BLOCK-SENTINEL" "SKILL/claude: the excluded block is absent"
has   "$(cat "$(skill "$d" codex)")"  "DENSITY-BLOCK-SENTINEL" "SKILL/codex: the included block is present"

# --- 2c. no marker survives ANY render ---------------------------------------------------------
leaked="$( (cd "$d" && grep -rl -- '<!-- adb:' agents 2>/dev/null) | LC_ALL=C sort | tr '\n' ' ')"
eq "$leaked" "" "no rendered file carries a marker"

# ============================ 3. every malformed spelling is LOUD ===============================
# A marker parser's failure mode is silence, so each rejectable spelling is exercised on the real
# build and required to fail it. `bad_marker <label> <marker-line> <expected-message-fragment>`
# builds a practice carrying that opener, closes it (unless the case is about an unclosed one),
# and asserts rc 3 plus a diagnostic that names the actual problem — an rc alone would be
# satisfied by ANY build failure, including a broken fixture.
bad_marker() {
  local label="$1" opener="$2" want="$3" close="${4:-1}" dd="$work/bad-${1//[^a-z0-9]/-}"
  mkfixture "$dd" || { bad "$label: fixture"; return; }
  { printf 'SHARED\n%s\nBLOCK\n' "$opener"; [ "$close" = 1 ] && printf '<!-- adb:end -->\n'; } \
    > "$dd/base/practices/10-fixture.md"
  cp "$W_B" "$dd/base/workflows/fixture.md"
  run_build "$dd"; local rc=$?
  eq "$rc" "3" "$label: fails the build loud (rc 3)"
  has "$(cat "$dd/build.log" 2>/dev/null)" "$want" "$label: the diagnostic names the real problem"
  [ ! -e "$dd/agents/claude/$CDOC" ] && ok \
    || bad "$label: a root doc was published despite the malformed marker"
}
bad_marker unknown-token  '<!-- adb:except cladue -->'               'unknown agent token'
bad_marker empty-list     '<!-- adb:except -->'                      'malformed `adb:except` marker'
bad_marker all-agents     '<!-- adb:except claude codex gemini -->'  'would render for no agent'
bad_marker duplicate      '<!-- adb:except claude claude -->'        'listed twice'
bad_marker no-space       '<!-- adb:except claude-->'                'malformed `adb:except` marker'
bad_marker unterminated   '<!-- adb:except claude -->'               'unterminated'                0
bad_marker nested         '<!-- adb:except claude -->
<!-- adb:except codex -->'                                           'nested `adb:except`'

# A stray close needs no opener at all.
dd="$work/bad-stray"
mkfixture "$dd" || bad "stray-end: fixture"
printf 'SHARED\n<!-- adb:end -->\n' > "$dd/base/practices/10-fixture.md"
cp "$W_B" "$dd/base/workflows/fixture.md"
run_build "$dd"; rc=$?
eq "$rc" "3" "stray-end: fails the build loud (rc 3)"
has "$(cat "$dd/build.log" 2>/dev/null)" '`adb:end` with no open block' "stray-end: the diagnostic names the real problem"

# ================== 4. a MISSPELLED KEYWORD is caught by the output scan ========================
# This is the one class block_filter cannot see: `adb:only` matches none of its rules, so it falls
# through as ordinary prose. Without the scan it ships literally into a tracked root doc that
# install.sh symlinks into a live agent session. Exercised on BOTH paths, because each renderer
# carries its own scan.
dd="$work/typo-root"
mkfixture "$dd" || bad "typo-root: fixture"
printf 'SHARED\n<!-- adb:only claude -->\nBLOCK\n' > "$dd/base/practices/10-fixture.md"
cp "$W_B" "$dd/base/workflows/fixture.md"
run_build "$dd"; rc=$?
eq "$rc" "3" "typo/root: an unrecognised marker keyword fails the build"
has "$(cat "$dd/build.log" 2>/dev/null)" "unresolved per-agent block marker" "typo/root: the scan names the problem"
[ ! -e "$dd/agents/claude/$CDOC" ] && ok || bad "typo/root: the root doc was published carrying a literal marker"

dd="$work/typo-skill"
mkfixture "$dd" || bad "typo-skill: fixture"
cp "$P_B" "$dd/base/practices/10-fixture.md"
{ cat "$W_B"; printf '\n<!-- adb:only claude -->\nBLOCK\n'; } > "$dd/base/workflows/fixture.md"
run_build "$dd"; rc=$?
eq "$rc" "3" "typo/skill: an unrecognised marker keyword fails the build"
has "$(cat "$dd/build.log" 2>/dev/null)" "unresolved per-agent block marker" "typo/skill: the scan names the problem"
[ ! -e "$(skill "$dd" claude)" ] && ok || bad "typo/skill: the skill was published carrying a literal marker"

# ============================== 5. MUTATIONS — observed failing =================================
mutate_line() { check_mutate_line "$@"; }

# --- 5a. inclusion forced ON: claude must stop matching the block-free oracle -------------------
# Without this, assertion 2's claude equalities are green for a filter that never excludes
# anything AND for one that works — the two are indistinguishable on an unmarked tree, and this
# repo's own history is that "the guard scanned zero files" reads exactly like "the guard passed".
dd="$work/mut-always-in"
mkfixture "$dd" || bad "mut-always-in: fixture"
if mutate_line "$dd/scripts/build.sh" '      open = 1; open_line = FNR; emit = !excluded' \
     's|^      open = 1; open_line = FNR; emit = !excluded$|      open = 1; open_line = FNR; emit = 1|' \
     "mut-always-in"; then
  cp "$P_A" "$dd/base/practices/10-fixture.md"; cp "$W_A" "$dd/base/workflows/fixture.md"
  run_build "$dd" || bad "mut-always-in: the mutated fixture failed to build — the mutation broke the script rather than changing its policy"
  if cmp -s "$(doc "$dd" claude "$CDOC")" "$(doc "$db" claude "$CDOC")"; then
    bad "MUTATION 1 DID NOT FIRE (root): with exclusion forced ON, claude's root doc STILL matched the block-free oracle — assertion 2a proves nothing"
  else ok; fi
  if cmp -s "$(skill "$dd" claude)" "$(skill "$db" claude)"; then
    bad "MUTATION 1 DID NOT FIRE (skill): with exclusion forced ON, claude's skill STILL matched the block-free oracle — assertion 2b proves nothing"
  else ok; fi
fi

# --- 5b. inclusion forced OFF: codex/gemini must stop matching the full oracle ------------------
# The other half of the pair. A filter that excludes everything satisfies 5a's assertion and every
# "claude lacks the block" check; only this one tells it apart from a correct filter.
dd="$work/mut-always-out"
mkfixture "$dd" || bad "mut-always-out: fixture"
if mutate_line "$dd/scripts/build.sh" '      open = 1; open_line = FNR; emit = !excluded' \
     's|^      open = 1; open_line = FNR; emit = !excluded$|      open = 1; open_line = FNR; emit = 0|' \
     "mut-always-out"; then
  cp "$P_A" "$dd/base/practices/10-fixture.md"; cp "$W_A" "$dd/base/workflows/fixture.md"
  run_build "$dd" || bad "mut-always-out: the mutated fixture failed to build"
  if cmp -s "$(doc "$dd" codex "$XDOC")" "$(doc "$dc" codex "$XDOC")"; then
    bad "MUTATION 2 DID NOT FIRE (root): with inclusion forced OFF, codex's root doc STILL matched the full oracle — assertion 2a proves nothing"
  else ok; fi
  if cmp -s "$(skill "$dd" codex)" "$(skill "$dc" codex)"; then
    bad "MUTATION 2 DID NOT FIRE (skill): with inclusion forced OFF, codex's skill STILL matched the full oracle — assertion 2b proves nothing"
  else ok; fi
fi

# --- 5c/5d. the surviving-marker scans are load-bearing -----------------------------------------
# Delete each scan's `grep -Fq` test and feed the misspelled marker again: the build must now
# SUCCEED and publish a literal `<!-- adb:` into the artifact. That is what makes section 4 a
# proof rather than an observation that some builds fail.
dd="$work/mut-noscan-root"
mkfixture "$dd" || bad "mut-noscan-root: fixture"
if mutate_line "$dd/scripts/build.sh" '  if LC_ALL=C grep -Fq '"'"'<!-- adb:'"'"' "$build_tmp"; then' \
     's|^  if LC_ALL=C grep -Fq .<!-- adb:. "\$build_tmp"; then$|  if false; then|' \
     "mut-noscan-root"; then
  printf 'SHARED\n<!-- adb:only claude -->\nBLOCK\n' > "$dd/base/practices/10-fixture.md"
  cp "$W_B" "$dd/base/workflows/fixture.md"
  run_build "$dd"
  if grep -Fq -- '<!-- adb:only claude -->' "$(doc "$dd" claude "$CDOC")" 2>/dev/null; then ok; else
    bad "MUTATION 3 DID NOT FIRE: with the root-doc marker scan removed, a literal marker still did not reach the root doc — section 4's root assertion proves nothing"
  fi
fi

dd="$work/mut-noscan-skill"
mkfixture "$dd" || bad "mut-noscan-skill: fixture"
if mutate_line "$dd/scripts/build.sh" '  if LC_ALL=C grep -Fq '"'"'<!-- adb:'"'"' "$tmp"; then' \
     's|^  if LC_ALL=C grep -Fq .<!-- adb:. "\$tmp"; then$|  if false; then|' \
     "mut-noscan-skill"; then
  cp "$P_B" "$dd/base/practices/10-fixture.md"
  { cat "$W_B"; printf '\n<!-- adb:only claude -->\nBLOCK\n'; } > "$dd/base/workflows/fixture.md"
  run_build "$dd"
  if grep -Fq -- '<!-- adb:only claude -->' "$(skill "$dd" claude)" 2>/dev/null; then ok; else
    bad "MUTATION 4 DID NOT FIRE: with the skill marker scan removed, a literal marker still did not reach the skill — section 4's skill assertion proves nothing"
  fi
fi

# ============================ 6. the TRACKED tree, read-only ===================================
# Sections 1-5 prove the mechanism. This proves it is USED, and used only as intended — a facility
# nobody applies renders the same bytes everywhere, which is indistinguishable from a broken one.

# It is applied at all.
#
# `-rl` PIPED INTO `grep -c .`, never `grep -rlc`. Combining `-l` and `-c` is not portable and
# resolves the wrong way here: under bash on this machine `-c` wins and the command prints
# `<file>:0` for EVERY file scanned, so the count was the file count — 21 — whether or not
# anything matched, and this assertion could not fail. Caught only by negative-testing it against
# a stripped copy, which is the whole argument of base/practices/self-review.md's guard section.
n="$(grep -rl -- '<!-- adb:except ' base/practices base/workflows 2>/dev/null | grep -c .)"
if [ "$n" -gt 0 ]; then ok; else
  bad "no source declares a per-agent block — the facility has no consumer, so every render is identical and this suite's tracked-tree assertions are vacuous"
fi

# Nothing leaked into what ships.
leaked="$(grep -rl -- '<!-- adb:' agents 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
eq "$leaked" "" "no tracked generated file carries a marker"

# The unlisted agents still receive byte-identical root docs. This is the assertion that catches a
# shared paragraph reworded in one render only — build-drift cannot, because it agrees with
# whatever was committed.
cmp -s agents/codex/AGENTS.md agents/gemini/GEMINI.md && ok \
  || bad "the codex and gemini root docs differ — no shipped block excludes either, so they must be byte-identical"

# NOTHING IS CLAUDE-EXCLUSIVE TODAY. Every shipped block is an `except claude`, so claude's root
# doc is a strict subset of codex's and `diff` must produce no `<` lines at all. A future block
# excluding a different agent would fail here — deliberately: it must come with its own assertion
# rather than silently widening what this one covers.
onlyclaude="$(diff agents/claude/CLAUDE.md agents/codex/AGENTS.md | grep -c '^<')"
eq "$onlyclaude" "0" "the claude root doc adds nothing the codex root doc lacks"

# And the difference is the one #304 asked for, named concretely so a render that varies the WRONG
# text cannot pass by merely varying something.
for s in '## What to look for' 'not a victory lap'; do
  hasnt "$(cat agents/claude/CLAUDE.md)" "$s" "claude's root doc drops the verification scaffolding: $s"
  has   "$(cat agents/codex/AGENTS.md)"  "$s" "codex's root doc keeps it: $s"
done
for a in codex gemini; do
  has "$(cat "agents/$a/skills/implement-issue/SKILL.md")" 'self-review is the mandatory floor' \
    "$a's implement-issue skill keeps the self-review scaffolding"
done
hasnt "$(cat agents/claude/skills/implement-issue/SKILL.md)" 'self-review is the mandatory floor' \
  "claude's implement-issue skill drops it"

# THE STEP ITSELF IS SHARED, and this is the invariant the whole facility is bounded by: only
# instruction DENSITY varies, never what the workflow does. Step 9 triages self-review findings
# and step 10's PR body reports them, so an agent told not to produce them would be running a
# different procedure — which `adb:except` must never be used to express.
for a in claude codex gemini; do
  has "$(cat "agents/$a/skills/implement-issue/SKILL.md")" 'Do your own self-review pass first' \
    "$a is still instructed to run the self-review pass"
done
for f in agents/claude/CLAUDE.md agents/codex/AGENTS.md agents/gemini/GEMINI.md; do
  has "$(cat "$f")" 'run a **dedicated self-review pass focused on real bugs**' \
    "${f##*/} still carries the self-review step itself"
done

check_summary "check-agent-blocks"
