#!/usr/bin/env bash
# ai-dev-baseline — tests for check-lib.sh's fixture copier, blocks and per-test mutation rows
# (#468, #469, #470). OFFLINE.
#
# Every case drives the REAL harness over a throwaway fixture suite under mktemp -d:
#   1. selection — a named block runs with exactly its dependency closure, and records its count;
#   2. declaration refusals — unknown, duplicate, forward, indented, unterminated: each exits 2;
#   3. a selection that runs no assertion exits 1;
#   4. preflight — a wrong-block witness, an ambiguous literal and an absent literal are each named,
#      and nothing is built (the prepare callback is never called);
#   5. an undeclared dependency fails its block's unmutated control, and its rows say so;
#   6. the verdict taxonomy — applied, stayed GREEN, off-witness, exited 1 with no FAIL:, exited N,
#      and an injection a prepare step made ambiguous on the copy;
#   7. full-suite mode (ADB_MUTATION_FULL_SUITE=1) runs every mutant against the whole suite;
#   8. check_copy_worktree — the copy carries the working tree and never `.git`, so the result is
#      not a repository (#469);
#   9. per-row gating — a row whose target the diff does not touch is GATED, not run, and the
#      harness says what it compared; every fail-closed path runs everything (#470);
#  10. the row deadline — a mutant or a control that never finishes ends as a named verdict within
#      ADB_MUTATION_ROW_TIMEOUT_SECS, leaves no suite running (a TERM-proof one and a cancelled
#      harness included), and a bound that is not a positive integer is refused (#445); and the
#      whole-suite pool, which is the vendored shmutant since #519: its adapter turns every verdict
#      but `killed` into a FAIL, carries this repository's settings, and refuses a stream it cannot
#      read whole (10g);
#  11. sharding — ADB_MUTATION_SHARD=<k>/<K> keeps only shard k's rows, the shards partition the
#      table exactly once, a row outside the shard is never built and never a pass, and a malformed
#      or impossible selector is refused before anything is built (#532);
#  12. block mode for the shmutant pool (#631) — the adapter refuses a row whose block is missing,
#      undeclared, repeated or does not carry its witness, hands shmutant the settings that make
#      its baselines the controls, forwards each run's block counts, turns a selected block that
#      reported none red, and reads the baseline records back: each expected, in order, and green;
#  13. sharding the shmutant pool (#631) — the same rule as 11, on the rows the pool is handed.
#
# The copier lives here rather than in a suite of its own because check-lib.sh is one library and
# this is its suite; the file is named for the feature that first needed one.
#
# Usage: bash scripts/check-block-rows.sh   (exit 0 = all pass, 1 = a failure)

# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-block-rows: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-block-rows: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -eq 0 ] || { echo "usage: check-block-rows.sh" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/adb-block-rows.XXXXXX")" || { echo "check-block-rows: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) ok ;; *) bad "$3: output lacks [$2]"; printf '%s\n' "$1" | sed 's/^/    | /' >&2 ;; esac; }
lacks() { case "$1" in *"$2"*) bad "$3: output carries [$2]"; printf '%s\n' "$1" | sed 's/^/    | /' >&2 ;; *) ok ;; esac; }

# --- the fixture: a library, a suite over it in four blocks, and a driver that runs rows ----------
fix="$work/fix"
mkdir -p "$fix"
cat > "$fix/lib.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
mul() { echo $(( $1 * $2 )); }
neg() { echo $(( 0 - $1 )); }
sq() { echo $(( $1 * $1 )); }
T_A=1
T_B=1
# a comment nothing reads
EOF
cat > "$fix/suite.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$ADB_T_LIB"
cd "$(dirname "$0")" || exit 3
check_blocks_init "$PWD/suite.sh"
. ./lib.sh
if check_block base; then
  eq "$(add 2 3)" 5 "add-sum"
fi
if check_block mult base; then
  helper=7
  eq "$(mul 2 3)" 6 "mul-product"
fi
if check_block uses-helper mult; then
  eq "${helper:-unset}" 7 "helper-set"
  eq "$(neg 4)" -4 "neg-value"
  eq "$(sq 3)" 9 "sq-value"
fi
if check_block empty; then
  :
fi
check_blocks_done
check_summary fixture
EOF
T_LIB="$work/libs.sh"
printf '. %q\n. %q\n' "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/check-lib.sh" > "$T_LIB"

suite() {   # <suite-dir> [ENV=val...] — run the fixture suite; prints output, returns its status
  local d="$1"; shift
  env ADB_T_LIB="$T_LIB" "$@" bash "$d/suite.sh" 2>&1
}

# A STUB ROW GATE inside every fixture root, because `check_mutation_rows` asks
# `$ROOT/scripts/mutation-gate.sh rows` and the driver sets ROOT to the fixture. The real gate's
# DECISIONS are proved in check-mutation-gate.sh against throwaway repositories; what is proved
# here is that the consumer HONOURS each answer — which needs every answer on demand, including
# the ones a real repository cannot be made to give (an unreadable decision, a non-zero rc).
# `ADB_T_GATE` picks the answer; unset means the ordinary "decided, everything runs" reply.
stub_gate() {   # <fixture-root>
  mkdir -p "$1/scripts"
  cat > "$1/scripts/mutation-gate.sh" <<'GATE'
#!/usr/bin/env bash
# test stub — see stub_gate in scripts/check-block-rows.sh
[ "${1:-}" = rows ] || { echo "stub gate: unexpected subcommand ${1:-}" >&2; exit 2; }
ids=()
while IFS="$(printf '\t')" read -r id _tgt; do [ -n "$id" ] && ids+=("$id"); done
case "${ADB_T_GATE:-}" in
  runall11) echo "RUN-ALL: stub — fail-closed"; for i in "${ids[@]}"; do echo "$i	run"; done; exit 11 ;;
  runall12) echo "RUN-ALL: stub — override";    for i in "${ids[@]}"; do echo "$i	run"; done; exit 12 ;;
  garbage)  echo "GATED: stub — unreadable";    for i in "${ids[@]}"; do echo "$i	maybe"; done; exit 0 ;;
  short)    echo "GATED: stub — short";         for i in "${ids[@]:1}"; do echo "$i	run"; done; exit 0 ;;
  dup)      echo "GATED: stub — duplicate id";  for i in "${ids[@]}"; do echo "$i	skip"; done; echo "${ids[0]}	skip"; exit 0 ;;
  oor)      echo "GATED: stub — out of range";  for i in "${ids[@]}"; do echo "$i	skip"; done; echo "99	skip"; exit 0 ;;
  crash)    echo "stub gate: exploded" >&2; exit 9 ;;
esac
skip=",${ADB_T_GATE_SKIP:-},"
n=0; for i in "${ids[@]}"; do case "$skip" in *",$i,"*) n=$((n+1)) ;; esac; done
echo "GATED: stub — $(( ${#ids[@]} - n )) of ${#ids[@]} row(s) run, $n gated"
for i in "${ids[@]}"; do
  case "$skip" in *",$i,"*) echo "$i	skip" ;; *) echo "$i	run" ;; esac
done
exit 0
GATE
  chmod +x "$1/scripts/mutation-gate.sh"
}
stub_gate "$fix"

variant() {   # <name> <sed-expression> — a copy of the fixture with its suite edited
  mkdir -p "$work/$1"; cp "$fix/lib.sh" "$work/$1/"
  sed "$2" "$fix/suite.sh" > "$work/$1/suite.sh"
  stub_gate "$work/$1"
}

# 1. selection and its closure
out="$(suite "$fix")"; eq "$?" 0 "full fixture run passes"
: > "$work/c1"
out="$(suite "$fix" ADB_CHECK_BLOCK=uses-helper ADB_CHECK_BLOCK_COUNTS="$work/c1")"; eq "$?" 0 "a selection with dependencies passes"
has "$out" "with 2 dependency block(s); 3 assertion(s) in the selection" "selection report"
eq "$(cut -f1 "$work/c1" | tr '\n' ' ')" "base mult uses-helper " "the closure ran, in order, and nothing else"
: > "$work/c2"
out="$(suite "$fix" ADB_CHECK_BLOCK=mult ADB_CHECK_BLOCK_COUNTS="$work/c2")"; eq "$?" 0 "a mid-file selection passes"
eq "$(tr '\n' ' ' < "$work/c2")" "base	1 mult	1 " "a later block's dependency is not run"
out="$(suite "$fix" ADB_CHECK_BLOCK=base,mult)"; eq "$?" 0 "a multi-block selection passes"
has "$out" "with 0 dependency block(s); 2 assertion(s)" "a selected dependency is not double-counted"

# 2. declaration refusals
out="$(suite "$fix" ADB_CHECK_BLOCK=nope)"; eq "$?" 2 "an unknown selection exits 2"
has "$out" "names 'nope', which is not a declared block" "unknown selection named"
out="$(suite "$fix" ADB_CHECK_BLOCK=base,nope)"; eq "$?" 2 "an unknown id inside a list exits 2"
variant dup 's/^if check_block empty; then/if check_block base; then/'
out="$(suite "$work/dup")"; eq "$?" 2 "a duplicate id exits 2"
has "$out" "declares block 'base' twice" "duplicate named"
variant fwd 's/^if check_block base; then/if check_block base mult; then/'
out="$(suite "$work/fwd")"; eq "$?" 2 "a forward dependency exits 2"
has "$out" "which is not declared EARLIER" "forward dependency named"
variant ind 's/^if check_block empty; then/  if check_block empty; then/'
out="$(suite "$work/ind")"; eq "$?" 2 "an indented declaration exits 2"
has "$out" "not at the start of the line" "indentation named"
variant noend '/^check_blocks_done$/d'
out="$(suite "$work/noend")"; eq "$?" 2 "a missing terminator exits 2"
has "$out" "no 'check_blocks_done' line" "missing terminator named"
variant bad-id 's/^if check_block empty; then/if check_block Empty; then/'
out="$(suite "$work/bad-id")"; eq "$?" 2 "an id outside [a-z0-9-] exits 2"

out="$(suite "$fix" ADB_CHECK_BLOCK=base,base)"; eq "$?" 2 "a block named twice in a selection exits 2"
has "$out" "names 'base' twice" "repeated selection named"
out="$(suite "$fix" ADB_CHECK_BLOCK=base,,mult)"; eq "$?" 2 "an empty selection element exits 2"
has "$out" "has an empty element" "empty selection element named"

# 3. a selection that proves nothing
out="$(suite "$fix" ADB_CHECK_BLOCK=empty)"; eq "$?" 1 "a zero-assertion selection exits 1"
has "$out" "ran NO assertions" "zero-assertion selection named"

# --- the row driver --------------------------------------------------------------------------------
cat > "$work/driver.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$ADB_T_LIB"
ROOT="$ADB_T_FIX"
prep() {   # <copy-dir> — copy the fixture and print its root; records that a copy was built
  printf 'copy\n' >> "$ADB_T_PREP_LOG"   # one line per tree copy: existence AND count
  mkdir -p "$1" && cp -R "$ROOT" "$1/t" || return 1
  [ -z "${ADB_T_DUP:-}" ] || printf '# add() { echo\n' >> "$1/t/lib.sh"
  printf '%s' "$1/t"
}
# ADB_T_UNLINK removes the rows' captured output once the suite has run, so the harness's read of it fails.
run() { local rc; ADB_T_LIB="$ADB_T_LIB" bash "$1/suite.sh"; rc=$?; [ -z "${ADB_T_UNLINK:-}" ] || rm -f "$ADB_T_WD"/row-*.out; return "$rc"; }
. "$ADB_T_ROWS"
check_mutation_rows "fixture" "$ADB_T_WD" "suite.sh" prep run 4
check_summary driver
EOF

rows() {   # <name> <rows-file-content> [ENV=val...] — run the driver; sets $out and $rc
  local nm="$1" body="$2"; shift 2
  printf '%s\n' "$body" > "$work/rows-$nm.sh"
  rm -f "$work/prep-$nm.log"
  out="$(env ADB_T_LIB="$T_LIB" ADB_T_FIX="${ADB_T_FIX:-$fix}" ADB_T_ROWS="$work/rows-$nm.sh" \
           ADB_T_WD="$work/wd-$nm" ADB_T_PREP_LOG="$work/prep-$nm.log" "$@" bash "$work/driver.sh" 2>&1)"
  rc=$?
}

good_rows="check_row add lib.sh base '\$1 + \$2' '\$1 - \$2' 'add-sum'
check_row mul lib.sh mult '\$1 * \$2' '\$1 + \$2' 'mul-product'
check_row neg lib.sh uses-helper '0 - \$1' '0 + \$1' 'neg-value'"

# 6a. applied, per block
rows good "$good_rows"; eq "$rc" 0 "valid rows pass"
has "$out" "3/3 mutation(s) applied, 3 observed RED on their own witness (pool=" "per-block tally"
has "$out" "per-block, 3 block(s) controlled" "per-block mode named"

# 7. full-suite mode. A mutant only a LATER block detects stays GREEN when its row selects `base`,
# and goes red off-witness when the whole suite runs — which is what proves the mode reaches the runner.
rows full "$good_rows" ADB_MUTATION_FULL_SUITE=1; eq "$rc" 0 "valid rows pass in full-suite mode"
has "$out" "full suite per mutant" "full-suite mode named"
elsewhere="check_row elsewhere lib.sh base '\$1 * \$2' '\$1 + \$2' 'add-sum'"
rows elsewhere-sel "$elsewhere"
has "$out" "mutation 'elsewhere': stayed GREEN" "a per-block row runs only its block"
rows elsewhere-full "$elsewhere" ADB_MUTATION_FULL_SUITE=1
has "$out" "mutation 'elsewhere': went red, but NOT on its witness" "a full-suite row runs every block"

# 4. preflight: each problem named, nothing built
rows pre "check_row wrongblock lib.sh base '\$1 * \$2' '\$1 + \$2' 'mul-product'
check_row ambiguous lib.sh base 'echo' 'printf' 'add-sum'
check_row absent lib.sh base 'no such text' 'x' 'add-sum'
check_row undeclared lib.sh ghost '\$1 + \$2' '\$1 - \$2' 'add-sum'
check_row same lib.sh base '\$1 + \$2' '\$1 + \$2' 'add-sum'
check_row missing nope.sh base 'a' 'b' 'add-sum'"
eq "$rc" 1 "invalid rows fail"
has "$out" "witness 'mul-product' does not appear in block(s) 'base'" "wrong-block witness named"
has "$out" "row 'ambiguous': its literal occurs 4 times" "ambiguous literal named"
has "$out" "row 'absent': its literal is ABSENT" "absent literal named"
has "$out" "block 'ghost' is not declared" "undeclared block named"
has "$out" "row 'same': its replacement equals its literal" "no-op row named"
has "$out" "target 'nope.sh' is missing or unreadable" "missing target named"
has "$out" "6 row declaration(s) are invalid — nothing was built or run" "preflight total"
if [ -e "$work/prep-pre.log" ]; then bad "preflight: the prepare callback ran before the declarations were valid"; else ok; fi

# 4b. an overlapping literal is two places a first-match rewrite could apply, and a used workdir is refused
printf 'T_C=aaa\n' >> "$fix/lib.sh"
rows overlap "check_row overlap lib.sh base 'aa' 'X' 'add-sum'"
has "$out" "row 'overlap': its literal occurs 2 times" "overlapping occurrences counted"
mkdir -p "$work/wd-reused"; : > "$work/wd-reused/control.counts"
rows reused "$good_rows"
eq "$rc" 1 "a non-empty workdir fails"
has "$out" "is not empty" "non-empty workdir named"

# 5. an undeclared dependency fails its control
variant nodep 's/^if check_block uses-helper mult; then/if check_block uses-helper base; then/'
ADB_T_FIX="$work/nodep" rows nodep "check_row neg lib.sh uses-helper '0 - \$1' '0 + \$1' 'neg-value'"
eq "$rc" 1 "a row whose block lacks a dependency fails"
has "$out" "control failed for block uses-helper: its unmutated control failed" "undeclared dependency named"

# 6b. the rest of the taxonomy
rows tax "check_row green lib.sh base 'nothing reads' 'anyone reads' 'add-sum'
check_row offwit lib.sh uses-helper '0 - \$1' '0 + \$1' 'sq-value'
check_row aborted lib.sh uses-helper 'T_A=1' 'exit 3' 'neg-value'"
eq "$rc" 1 "undetected mutants fail the harness"
has "$out" "mutation 'green': stayed GREEN" "stayed GREEN named"
has "$out" "mutation 'offwit': went red, but NOT on its witness [sq-value]" "off-witness named"
has "$out" "mutation 'aborted': exited 3, not 1" "abort named"
has "$out" "3/3 mutation(s) applied, 0 observed RED" "undetected rows still count as applied"
lacks "$out" "mutation 'green': the injection did not apply" "a GREEN row is not misreported as unapplied"

# the library is sourced by the suite's own shell, so an `exit` there ends the suite before any assertion
rows nofail "check_row nofail lib.sh base 'T_B=1' 'exit 1' 'add-sum'"
has "$out" "mutation 'nofail': exited 1 with no FAIL: line at all" "exit-1-without-FAIL named"

# 6c. a prepare step that makes the literal ambiguous on the copy
rows dupcopy "check_row add lib.sh base 'add() { echo' 'add() { echo 1; echo' 'add-sum'" ADB_T_DUP=1
eq "$rc" 1 "a copy the prepare step made ambiguous fails"
has "$out" "holds the literal 2 time(s), so this row tests NOTHING" "copy recount named"
has "$out" "0/1 mutation(s) applied" "an unapplied row is not counted as applied"

# --- 9. per-row gating: the consumer honours every answer the gate can give (#470) ---------------
#
# The row gate's own DECISIONS live in check-mutation-gate.sh. What is asserted here is the half
# that decides what actually runs: a gated row must not be BUILT (the prepare log is the evidence —
# printed output could be produced by a row that ran and was then hidden), must not be scored as a
# pass, and must be named in the summary. Every fail-closed answer must run the whole table.

# THE SAME THREE ROWS THE TALLY CASES USE, all of them detected: every count below is then an
# exact number rather than a range, so a gated row scored as a pass — or an applied count still
# compared against the whole table — moves one of them.
three="$good_rows"

# baseline: the stub decides, nothing is gated, and the table behaves exactly as before.
rows g-none "$three"
eq "$rc" 0 "an ungated table is scored exactly as before"
has "$out" "3/3 mutation(s) applied, 3 observed RED" "ungated rows are all applied"
has "$out" "driver: 3 passed, 0 failed" "an ungated table scores one assertion per row"
lacks "$out" "row(s) gated" "an ungated run does not claim to have gated anything"

# one row gated: it is never built, never scored, and the summary says so.
rows g-one "$three" ADB_T_GATE_SKIP=1
eq "$rc" 0 "a partially gated table passes"
has "$out" "1 row(s) gated (targets unchanged: lib.sh)" "the gated row is named with its target"
# 2/2, NOT 2/3: the applied count is compared against the rows that RAN, or every gated run is red.
has "$out" "2/2 mutation(s) applied, 2 observed RED" "a partially gated run tallies against the rows that ran"
# ...and the gated row contributes NO assertion — 3 rows minus 1 gated is 2 passes, not 3.
has "$out" "driver: 2 passed, 0 failed" "a gated row is not scored as a passing assertion"
# THE PREPARE LOG, not the printed output: a row that was built and then hidden would look the
# same on stdout. One line per tree copy. Ungated: one full control, one control per selected
# block (3), one per row (3) = 7. Gating `mul` removes its row AND the control for `mult`, the
# only block it selects = 5. Both numbers are pinned, so building too much and building too
# little are separate failures.
eq "$(wc -l < "$work/prep-g-none.log" | tr -d ' ')" 7 "an ungated table builds one copy per control and per row"
eq "$(wc -l < "$work/prep-g-one.log" | tr -d ' ')" 5 "a gated row builds neither its own copy nor its block's control"

# a block only gated rows select loses its control too — nothing consumes it.
rows g-block "$three" ADB_T_GATE_SKIP=2
has "$out" "1 row(s) gated" "gating a block's only row is reported"
has "$out" "2 block(s) controlled" "a block only gated rows select is not controlled"

# every row gated: no control, no rows, and a line that says exactly that.
rows g-all "$three" ADB_T_GATE_SKIP=0,1,2
has "$out" "0/3 row(s) run — every row gated" "a fully gated run says so"
[ ! -e "$work/prep-g-all.log" ] && ok || bad "a fully gated run must build no tree copy at all, control included"
# ...and it adds NO assertion, which is the honest answer rather than a manufactured pass. In this
# fixture the harness is the driver's only source of assertions, so `check_summary`'s zero-assertion
# rule is what decides — exactly as it should. A real suite runs its own blocks either way.
eq "$rc" 1 "a fully gated harness asserts nothing, so a suite with nothing else still reports zero"
has "$out" "driver: 0 passed, 0 failed" "the fully gated run scored no assertion at all"

# fail-closed: an override, a fail-closed answer, an unreadable decision, a short answer, a crash.
# Each must run the WHOLE table — the cost of a wrong gate is minutes, never coverage.
for _g in runall11 runall12 garbage short crash; do
  rows "g-$_g" "$three" "ADB_T_GATE=$_g"
  has "$out" "3/3 mutation(s) applied, 3 observed RED" "gate answer '$_g' runs every row"
  lacks "$out" "row(s) gated" "gate answer '$_g' gates nothing"
done
has "$out" "the row gate failed (rc 9)" "a gate that exits non-zero is named, not swallowed"

# ...and every unreadable answer is NAMED, not merely survived. `short` is the one that matters:
# it omits a row's decision line rather than corrupting it, so a table pre-filled with `run` would
# run everything and report nothing — fail-closed and silent, which is a guard that cannot fire.
rows g-say "$three" ADB_T_GATE=garbage
has "$out" "the row gate returned no usable decision" "an unreadable decision is named"
rows g-missing "$three" ADB_T_GATE=short
has "$out" "the row gate returned no usable decision for row 0" "a MISSING decision is named, and says which row owed it"
# ...and a reply that is partly WELL-FORMED is not partly believed: a duplicate id, an id out of
# range, or an unreadable decision voids the whole reply, or a corrupt answer carrying a full set
# of `skip`s would still gate everything. Reported by the declared reviewer.
for _g in dup oor; do
  rows "g-$_g" "$three" "ADB_T_GATE=$_g" "ADB_T_GATE_SKIP=0,1,2"
  has "$out" "3/3 mutation(s) applied, 3 observed RED" "a '$_g' reply gates nothing, despite carrying a full set of skips"
  has "$out" "the row gate returned no usable decision" "…and says the reply was unusable"
done

# --- 8. check_copy_worktree: the working tree, never `.git` (#469) --------------------------------
#
# The copier's failure mode is a copy that is still a repository, and the assertion that catches it
# has to look at the COPY rather than at the source. Every property the old `cp -R .` form
# delivered is re-asserted here, because the mechanism that delivered them changed: the entry loop
# is now what omits `.git`, and there is no `rm -rf` behind it to paper over a broken skip.

cw="$work/cw"; mkdir -p "$cw/src/sub/deep"
# A REAL repository, not a hand-made `.git` directory: the "the copy is not a repository"
# assertion can only fire if a copied `.git` would actually make one, and a stub with two files
# in it leaves `git rev-parse` failing for the wrong reason — so the assertion would pass on a
# copier that copied `.git` wholesale.
check_git "$cw/src" init -q 2>/dev/null || git -C "$cw/src" init -q
printf 'visible\n'    > "$cw/src/plain.txt"
printf 'hidden\n'     > "$cw/src/.dotfile"
printf 'nested\n'     > "$cw/src/sub/deep/n.txt"
printf '#!/bin/sh\n'  > "$cw/src/exec.sh"; chmod 755 "$cw/src/exec.sh"
printf 'dashed\n'     > "$cw/src/-leading-dash"
printf 'gitish\n'     > "$cw/src/.gitignore"
ln -s plain.txt "$cw/src/link"

check_copy_worktree "$cw/src" "$cw/dst"; eq "$?" 0 "check_copy_worktree returns 0 on a good copy"

# THE point of #469, and the one assertion a re-introduced `rm -rf "$dst/.git"` would also satisfy —
# which is why the `rm` is gone rather than kept: with it, this could not tell the two apart.
[ -e "$cw/dst/.git" ] && bad "the copy must not contain .git at all" || ok
git -C "$cw/dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && bad "the copy must not be a git repository" || ok
# ...and a `.git`-PREFIXED name is not `.git`: a skip written as a prefix match would eat it.
[ -f "$cw/dst/.gitignore" ] && ok || bad ".gitignore must survive — only the entry named .git is skipped"

[ -f "$cw/dst/plain.txt" ] && ok || bad "a plain file must be copied"
[ -f "$cw/dst/.dotfile" ] && ok || bad "a dotfile must be copied"
[ -f "$cw/dst/sub/deep/n.txt" ] && ok || bad "a nested file must be copied"
[ -f "$cw/dst/-leading-dash" ] && ok || bad "an entry whose name begins with - must be copied, not read as an option"
[ -x "$cw/dst/exec.sh" ] && ok || bad "the executable mode must survive the copy"
[ -L "$cw/dst/link" ] && ok || bad "a symlink must stay a symlink"
cmp -s "$cw/src/plain.txt" "$cw/dst/plain.txt" && ok || bad "the copied bytes must match"

# A DESTINATION THAT IS ALREADY A REPOSITORY IS REFUSED, not cleaned up: the contract says the
# result is not a git repo, and the old `rm -rf "$dst/.git"` used to make that hold here too.
mkdir -p "$cw/dirty-dst"
check_git "$cw/dirty-dst" init -q 2>/dev/null || git -C "$cw/dirty-dst" init -q
check_copy_worktree "$cw/src" "$cw/dirty-dst" 2>/dev/null; [ "$?" -ne 0 ] && ok \
  || bad "a destination that already contains .git must be REFUSED — the copier must never delete a repository it did not create"
[ -e "$cw/dirty-dst/.git" ] && ok || bad "...and the refusal must leave that .git alone"

# An EMPTY source is a copy of nothing, not a failure: `.* *` leaves a literal `*` behind when the
# glob matches nothing, and an unguarded loop would try to copy it and return 1.
mkdir -p "$cw/empty"
check_copy_worktree "$cw/empty" "$cw/empty-dst"; eq "$?" 0 "an empty source copies cleanly"
[ -d "$cw/empty-dst" ] && ok || bad "an empty source must still create the destination"

# A source that does not exist must FAIL, not report an empty copy.
# stderr is silenced because the `cd` diagnostic IS the expected behaviour here, not noise to fix.
check_copy_worktree "$cw/nope" "$cw/nope-dst" 2>/dev/null; [ "$?" -ne 0 ] && ok \
  || bad "a missing source must return non-zero, not an empty success"

# --- 10. the row deadline (#445) ------------------------------------------------------------------
#
# A mutant that BLOCKS must end as a named verdict within the bound, in both pools, and so must a
# control that never finishes. Every hang below is a `sleep` of a duration carrying THIS run's pid, so
# "nothing survived" is a process-table question that can only ever match this run's own fixtures —
# and each sleep is itself bounded (45 s), so a broken deadline fails these cases by name, in about
# a minute, instead of holding the suite until its job is cancelled.
HANG="45.$$"; HANG_RE="^sleep 45\\.$$[0-9]\$"
# survivors — this run's hang fixtures still running, or `ERR rc=<n>: <stderr>` when the process
# table cannot be read: pgrep exits 1 for "no match" and above 1 for a failure, and only the first is
# an empty answer. A failure is retried twice, briefly — the probe is not what is under test — and
# the last one's status and diagnostic are what a red reports.
survivors() {
  local out rc err _
  for _ in 1 2 3; do
    out="$(pgrep -f "$HANG_RE" 2>"$work/pgrep.err")"; rc=$?
    case "$rc" in 0|1) break ;; esac
    sleep 0.3
  done
  case "$rc" in
    0) printf '%s' "$out" | tr '\n' ' ' ;;
    1) : ;;
    *) err="$(head -c 300 "$work/pgrep.err" 2>/dev/null | tr '\n' ' ')"; printf 'ERR rc=%s: %s' "$rc" "$err" ;;
  esac
}
kill_own() { pkill -KILL -f "$HANG_RE" 2>/dev/null; return 0; }
no_survivor() {   # <label> — after the harness has returned, none of this run's hung suites may live
  local s; s="$(survivors)"
  case "$s" in
    '')  ok ;;
    ERR*) bad "$1: the process table could not be read (pgrep failed: ${s#ERR }), so whether a hung suite survived is unknown" ;;
    *)   bad "$1: hung suite(s) still running after the harness returned (pids $s)"; kill_own ;;
  esac
}
# within <label> <t0> — the harness returned well inside the fixtures' own 45 s sleep: the bound, not
# the sleep ending, is what let it go.
within() { if [ $(( SECONDS - $2 )) -lt 40 ]; then ok; else bad "$1: took $(( SECONDS - $2 ))s — the bound did not end it, the fixture's own sleep did"; fi; }

# 10a. row mode: a hung mutant is named, counted as applied, never as RED.
_t0=$SECONDS
rows hang "check_row hang lib.sh uses-helper 'T_A=1' 'sleep ${HANG}1' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "a hung row" "$_t0"
eq "$rc" 1 "a hung row fails the harness"
has "$out" "mutation 'hang': hung — no verdict within 3s" "a hung row is named, with the bound"
has "$out" "1/1 mutation(s) applied, 0 observed RED" "a hung row reached the code, so it is applied, and it is never RED"
has "$out" "row deadline 3s" "the tally names the bound it ran under"
no_survivor "row mode"

# 10b. a suite that IGNORES TERM is still reaped, and so is a TERM-proof descendant of a suite that
# died on the TERM: in both, only the group sweep after the fired bound reaches what is left.
_t0=$SECONDS
rows hang-stubborn "check_row stubborn lib.sh uses-helper 'T_A=1' 'trap \"\" TERM; sleep ${HANG}2' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "a TERM-proof suite" "$_t0"
has "$out" "mutation 'stubborn': hung — no verdict within 3s" "a TERM-proof hung row is named"
no_survivor "a suite that ignores TERM"
_t0=$SECONDS
rows hang-orphan "check_row orphan lib.sh uses-helper 'T_A=1' '( trap \"\" TERM; exec sleep ${HANG}7 ) & sleep ${HANG}8' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "a suite with a TERM-proof descendant" "$_t0"
has "$out" "mutation 'orphan': hung — no verdict within 3s" "a hung row whose suite left a TERM-proof descendant is named"
no_survivor "a TERM-proof descendant of a suite that died on TERM"

# 10c. a mutant that finishes INSIDE the bound is scored as what it was, not as hung.
rows slow "check_row slow lib.sh uses-helper 'neg() { echo' 'neg() { sleep 1; echo \"\$(( 1 + \$1 ))\"; return; echo' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=8
eq "$rc" 0 "a slow row that is caught within the bound passes"
has "$out" "1/1 mutation(s) applied, 1 observed RED" "a slow row is scored on its witness"
lacks "$out" "hung" "a row that finished inside the bound is not called hung"

# 10d. the full unmutated control hangs: no row can be scored, and the harness says why.
# awk, not `variant`'s sed: BSD sed does not read `\n` in a replacement as a newline.
variant_after() {   # <name> <exact line> <line to insert after it>
  mkdir -p "$work/$1"; cp "$fix/lib.sh" "$work/$1/"
  ADB_T_AT="$2" ADB_T_ADD="$3" awk '{ print } $0 == ENVIRON["ADB_T_AT"] { print ENVIRON["ADB_T_ADD"] }' \
    "$fix/suite.sh" > "$work/$1/suite.sh"
  stub_gate "$work/$1"
}
variant_after hangctl '  eq "$(sq 3)" 9 "sq-value"' "sleep ${HANG}3"
_t0=$SECONDS
ADB_T_FIX="$work/hangctl" rows hangctl "check_row neg lib.sh uses-helper '0 - \$1' '0 + \$1' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "a hung full control" "$_t0"
eq "$rc" 1 "a hung full control fails the harness"
has "$out" "the UNMUTATED suite did not finish within 3s" "a hung full control is named"
no_survivor "a hung full control"

# 10e. a block's control hangs only when it runs as a SELECTION: its rows say so.
variant_after hangsel 'if check_block base; then' "  [ -z \"\${ADB_CHECK_BLOCK:-}\" ] || sleep ${HANG}4"
_t0=$SECONDS
ADB_T_FIX="$work/hangsel" rows hangsel "check_row add lib.sh base '\$1 + \$2' '\$1 - \$2' 'add-sum'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "a hung block control" "$_t0"
eq "$rc" 1 "a hung block control fails the harness"
has "$out" "control failed for block base: its unmutated control did not finish within 3s" "a hung block control is named on its rows"
no_survivor "a hung block control"

# 10f. the bound itself: refused unless it is a positive integer, before anything is built.
for _v in abc 0 00 -5 1234567890; do
  rows "badsecs$_v" "$good_rows" "ADB_MUTATION_ROW_TIMEOUT_SECS=$_v"
  eq "$rc" 1 "ADB_MUTATION_ROW_TIMEOUT_SECS='$_v' fails the harness"
  has "$out" "ADB_MUTATION_ROW_TIMEOUT_SECS must be a positive integer" "ADB_MUTATION_ROW_TIMEOUT_SECS='$_v' is named"
  [ ! -e "$work/prep-badsecs$_v.log" ] && ok || bad "ADB_MUTATION_ROW_TIMEOUT_SECS='$_v': a tree copy was built before the bound was validated"
done
rows octal "$good_rows" ADB_MUTATION_ROW_TIMEOUT_SECS=0900
has "$out" "row deadline 900s" "a zero-padded bound is read as decimal"
rows default "$good_rows" ADB_MUTATION_ROW_TIMEOUT_SECS=
has "$out" "row deadline 1800s" "the default bound is 1800s"

# 10g. the whole-suite pool is the vendored shmutant (#519), scored by check_shmutant_pool. What is
# proved here is the ADAPTER: shmutant's own verdicts are its suite's business, upstream. So every
# verdict the adapter must turn into a FAIL is driven through a real pool over the fixture, the
# settings it must carry are observed from inside the call, and the stream it must refuse is forged
# by a stub standing in for shmutant_pool.
cat > "$work/shm-driver.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$ADB_T_LIB"
# shellcheck source=/dev/null
[ -n "${ADB_T_NO_SHMUTANT:-}" ] || . "$ADB_T_SHMUTANT"
[ -z "${ADB_T_CWD:-}" ] || cd "$ADB_T_CWD" || exit 3
# ADB_T_PREP_CD: a prepare that changes directory, which shmutant permits.
prep() { printf 'copy\n' >> "$ADB_T_PREP_LOG"; cp -R "$ADB_T_FIX/." "$1/" || return 1; [ -z "${ADB_T_PREP_CD:-}" ] || cd /; }
# "$BASH", never a bare `bash`: on macOS a PATH without Homebrew first resolves /bin/bash 3.2, which
# shmutant refuses to load and the fixture suite was never written for.
run() { ADB_T_LIB="$ADB_T_LIB" "$BASH" "$1/suite.sh"; }
# ADB_T_RM: an `rm` that removes a run's count file and then fails (`status`), or leaves a dangling
# link where it was (`link`). The adapter calls `rm` by name; shmutant's own calls are `command -p`.
if [ -n "${ADB_T_RM:-}" ]; then
  rm() {
    local rc a
    command rm "$@"; rc=$?
    for a in "$@"; do
      case "$a" in
        */pool.counts/run.??????)
          case "$ADB_T_RM" in status) return 77 ;; link) ln -s /nonexistent/adb "$a" ;; esac ;;
      esac
    done
    return "$rc"
  }
fi
[ -z "${ADB_T_ERREXIT:-}" ] || set -e
if [ -n "${ADB_T_STUB:-}" ]; then
  # A stand-in for shmutant_pool: it records what it was handed, then writes the stream ADB_T_STUB
  # names and returns the status that goes with it.
  shmutant_pool() {
    local r s
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$SHMUTANT_TIMEOUT" "$SHMUTANT_JOBS" "$SHMUTANT_BASELINE" "$SHMUTANT_STREAM" \
      "$SHMUTANT_RED_STATUS" "$SHMUTANT_RED_PREFIX" "$SHMUTANT_COUNTS" > "$ADB_T_SEEN"
    bash -c 'printf "%s" "${SHMUTANT_TIMEOUT-unexported}"' > "$ADB_T_SEEN.env"
    # Templates for printf, with one %s each: the row's verdict, the summary's kill count. The summary
    # reports the width it was given, as shmutant's does.
    r=$'shmutant\t1\trow\t%s\tcaught\tlib.sh\tneg-value\t0.100\tthe detail'
    s=$'shmutant\t1\tsummary\tfixture\t1\t%s\t'"$SHMUTANT_JOBS"$'\t0.200'
    case "$ADB_T_STUB" in
      ok)           printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      garbage)      printf '%s\nnot a record\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      short-field)  printf 'shmutant\t1\trow\tkilled\tcaught\n%s\n' "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      version)      printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $2 = 2; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      rc1-killed)   printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 1 ;;
      rc0-survived) printf '%s\n%s\n' "$(printf "$r" survived)" "$(printf "$s" 0)" >> "$SHMUTANT_STREAM"; return 0 ;;
      no-row)       printf '%s\n' "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      no-summary)   printf '%s\n' "$(printf "$r" killed)" >> "$SHMUTANT_STREAM"; return 0 ;;
      late-row)     printf '%s\n%s\n' "$(printf "$s" 1)" "$(printf "$r" killed)" >> "$SHMUTANT_STREAM"; return 0 ;;
      bad-summary)  printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 0)" >> "$SHMUTANT_STREAM"; return 0 ;;
      no-stream)    return 0 ;;
      wrong-name)   printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $5 = "another"; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      wrong-target) printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $6 = "other.sh"; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      wrong-select) printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $7 = "sq-value"; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      bad-seconds)  printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $8 = "soon"; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      bad-verdict)  printf '%s\n%s\n' "$(printf "$r" kiled)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      bad-escape)   printf '%s\n%s\n' "$(printf "$r" killed | awk 'BEGIN { FS = OFS = "\t" } { $9 = "a \\q b"; print }')" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      baseline-rec) printf 'shmutant\t1\tbaseline\tneg-value\tgreen\t0.100\tgreen before injection\n%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      other-label)  printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1 | awk 'BEGIN { FS = OFS = "\t" } { $4 = "another-pool"; print }')" >> "$SHMUTANT_STREAM"; return 0 ;;
      nul)          { printf '%s\n' "$(printf "$r" killed)"; printf 'shmutant\t1\tsummary\tfix\000ture\t1\t1\t4\t0.200\n'; } >> "$SHMUTANT_STREAM"; return 0 ;;
      zero-jobs)    printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1 | awk 'BEGIN { FS = OFS = "\t" } { $7 = 0; print }')" >> "$SHMUTANT_STREAM"; return 0 ;;
      other-jobs)   printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1 | awk 'BEGIN { FS = OFS = "\t" } { $7 = 99; print }')" >> "$SHMUTANT_STREAM"; return 0 ;;
      lock-art)     printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"
                    chmod 555 "${SHMUTANT_STREAM%/*/*}"; return 0 ;;   # the evidence root: its pool dir can no longer be unlinked
      unreadable)   printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; chmod 000 "$SHMUTANT_STREAM"; return 0 ;;
      fifo)         rm -f "$SHMUTANT_STREAM"; mkfifo "$SHMUTANT_STREAM.fifo" && ln -s "$SHMUTANT_STREAM.fifo" "$SHMUTANT_STREAM"; return 0 ;;
      unterminated) printf '%s\n%s' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
      rc2)          return 2 ;;
      rc7)          printf '%s\n%s\n' "$(printf "$r" killed)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 7 ;;
      # BLOCK MODE (#631): the same row under the selector the table gives it, behind the baseline
      # records shmutant writes first — the unselected run, then the row's selection.
      blk-*)
        local rb b0 b1
        rb="$(printf 'shmutant\t1\trow\tkilled\tcaught\tlib.sh\t%s\t0.100\tthe detail' "${SHMUTANT_ROWS_SEL[0]}")"
        b0=$'shmutant\t1\tbaseline\t\tgreen\t0.100\tgreen before injection, every test run: the reference for the counts'
        b1="$(printf 'shmutant\t1\tbaseline\t%s\t%%s\t0.100\tthe baseline detail' "${SHMUTANT_ROWS_SEL[0]}")"
        case "$ADB_T_STUB" in
          blk-ok)        printf '%s\n%s\n%s\n%s\n' "$b0" "$(printf "$b1" green)" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-no-base)   printf '%s\n%s\n' "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-one-base)  printf '%s\n%s\n%s\n' "$b0" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-order)     printf '%s\n%s\n%s\n%s\n' "$(printf "$b1" green)" "$b0" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-other)     printf '%s\n%s\n%s\n%s\n' "$b0" "$(printf "$b1" green | awk 'BEGIN { FS = OFS = "\t" } { $4 = "base"; print }')" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-extra)     printf '%s\n%s\n%s\n%s\n%s\n' "$b0" "$(printf "$b1" green)" "$(printf "$b1" green)" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-red-rc0)   printf '%s\n%s\n%s\n%s\n' "$b0" "$(printf "$b1" red)" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-verdict)   printf '%s\n%s\n%s\n%s\n' "$b0" "$(printf "$b1" greeen)" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-short)     printf '%s\nshmutant\t1\tbaseline\tuses-helper\tgreen\n%s\n%s\n' "$b0" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-late-base) printf '%s\n%s\n%s\n%s\n' "$rb" "$(printf "$s" 1)" "$b0" "$(printf "$b1" green)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-mid-base)  printf '%s\n%s\n%s\n%s\n' "$b0" "$rb" "$(printf "$b1" green)" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
          blk-full)      printf 'shmutant\t1\tbaseline\t%s\tgreen\t0.100\tgreen before injection\n%s\n%s\n' "${SHMUTANT_ROWS_SEL[0]}" "$rb" "$(printf "$s" 1)" >> "$SHMUTANT_STREAM"; return 0 ;;
        esac ;;
    esac
  }
fi
[ -n "${ADB_T_NO_SHMUTANT:-}" ] || shmutant_target lib.sh
eval "${ADB_T_ROWS:-}"
# ADB_T_SUITE: the sixth argument — the selectors are blocks of that suite, read under ROOT.
ROOT="$ADB_T_FIX"
if [ -n "${ADB_T_SUITE:-}" ]; then
  check_shmutant_pool "fixture" "$ADB_T_WD" prep "${ADB_T_RUN_CB:-run}" 4 "$ADB_T_SUITE"
else
  check_shmutant_pool "fixture" "$ADB_T_WD" prep "${ADB_T_RUN_CB:-run}" 4
fi
printf 'adapter-rc=%s\n' "$?"
[ -n "${ADB_T_NO_SHMUTANT:-}" ] || printf 'table-after=%s %s\n' "${#SHMUTANT_ROWS_NAME[@]}" "${SHMUTANT_ROWS_SEL[*]}"
check_summary shm-driver
EOF
shm() {   # <name> <rows> [ENV=val...] — sets $out and $rc
  local nm="$1" rws="$2"; shift 2
  rm -f "$work/prep-$nm.log"
  # The stream lands beside the workdir, and shmutant requires that directory to exist already.
  mkdir -p "$work/shm-$nm"
  # `-u ADB_MUTATION_ARTIFACTS`: selfcheck-macos exports it to the whole suite, and a fixture that
  # inherited it would run its pool somewhere other than the path it asserts on. `-u
  # ADB_MUTATION_ROW_TIMEOUT_SECS`: an operator's raised row deadline would replace the default the
  # cases below assert. `-u ADB_MUTATION_SHARD -u ADB_MUTATION_FULL_SUITE`: the adapter reads both
  # (#631), and a shard or a mode inherited from the caller would change every tally below. A case
  # that wants any of them passes it explicitly, after this.
  out="$(env -u ADB_MUTATION_ARTIFACTS -u ADB_MUTATION_ROW_TIMEOUT_SECS -u ADB_MUTATION_SHARD -u ADB_MUTATION_FULL_SUITE ADB_T_LIB="$T_LIB" ADB_T_SHMUTANT="$ROOT/scripts/shmutant.sh" ADB_T_FIX="$fix" ADB_T_ROWS="$rws" \
           ADB_T_WD="$work/shm-$nm/pool" ADB_T_PREP_LOG="$work/prep-$nm.log" ADB_T_SEEN="$work/seen-$nm" \
           "$@" "$BASH" "$work/shm-driver.sh" 2>&1)"; rc=$?
}
CAUGHT="shmutant_mut caught '0 - \$1' '0 + \$1' 'neg-value'"
shm killed "$CAUGHT"
eq "$rc" 0 "shmutant: a killed row passes the suite"
has "$out" "adapter-rc=0" "shmutant: …and the adapter itself returns 0"
has "$out" "1/1 mutation(s) killed on their own witness (shmutant; pool=" "shmutant: the tally names the harness and its width"
has "$out" "row deadline 1800s" "shmutant: the default row deadline is this repository's 1800s, not shmutant's 300"
eq "$(cat "$work/prep-killed.log" 2>/dev/null)" "copy" "shmutant: prepare ran ONCE for the pool"
shm survived "shmutant_mut cosmetic '# a comment nothing reads' '# a comment nobody reads' 'add-sum'"
eq "$rc" 1 "shmutant: a survived row fails the suite"
has "$out" "FAIL: mutation 'cosmetic': survived" "shmutant: …on a FAIL: line naming the row and its verdict"
shm accidental "shmutant_mut wrong-witness '0 - \$1' '0 + \$1' 'sq-value'"
eq "$rc" 1 "shmutant: an accidental row fails the suite"
has "$out" "FAIL: mutation 'wrong-witness': accidental" "shmutant: …named as accidental"
shm aborted "shmutant_mut dies 'T_A=1' 'exit 7' 'neg-value'"
eq "$rc" 1 "shmutant: an aborted row fails the suite"
has "$out" "FAIL: mutation 'dies': aborted" "shmutant: …named as aborted"
_t0=$SECONDS
shm hang "shmutant_mut hung 'T_A=1' 'sleep ${HANG}5' 'neg-value'" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "shmutant: a hung row" "$_t0"
eq "$rc" 1 "shmutant: a hung row fails the suite"
has "$out" "FAIL: mutation 'hung': timeout" "shmutant: the row deadline reaches shmutant — the hung row is a named timeout"
has "$out" "row deadline 3s" "shmutant: …and the tally names the bound it ran under"
no_survivor "shmutant: a hung row"
shm ambiguous "shmutant_mut twice 'echo \$((' 'echo \$(( 1 +' 'add-sum'"
eq "$rc" 1 "shmutant: a harness error fails the suite"
has "$out" "HARNESS ERROR (status 2)" "shmutant: …named as the harness's own failure, not as a verdict"
shm badsecs "$CAUGHT" ADB_MUTATION_ROW_TIMEOUT_SECS=x
eq "$rc" 1 "shmutant: a row deadline that is not a positive integer fails the suite"
has "$out" "ADB_MUTATION_ROW_TIMEOUT_SECS must be a positive integer" "shmutant: …naming it"
[ ! -e "$work/prep-badsecs.log" ] && ok || bad "shmutant: a tree was prepared before the bound was validated"
shm unsourced "" ADB_T_NO_SHMUTANT=1
eq "$rc" 1 "shmutant: a suite that never sourced shmutant fails"
has "$out" "shmutant_pool is unavailable" "shmutant: …saying what is missing"
# When CI asks for it, the pool's workdir IS the evidence: shmutant leaves the stream and every row's
# output under ADB_MUTATION_ARTIFACTS, outside the suite's own cleanup, and nothing is copied.
shm art "shmutant_mut cosmetic '# a comment nothing reads' '# a comment nobody reads' 'add-sum'" ADB_MUTATION_ARTIFACTS="$work/artifacts"
_art="$(find "$work/artifacts" -mindepth 1 -maxdepth 1 -type d -name 'fixture.*' 2>/dev/null | head -1)"
[ -n "$_art" ] && [ -f "$_art/pool.tsv" ] && [ -f "$_art/pool/mut-0/output" ] && ok \
  || bad "shmutant: ADB_MUTATION_ARTIFACTS did not hold the stream and the row's output"
has "$(cat "$_art/pool/mut-0/output" 2>/dev/null)" "fixture: " "shmutant: the kept output is the run's own — the suite's summary line"
has "$out" "is kept in $_art" "shmutant: …and the log says where"
# An evidence location that cannot be used REFUSES the pool: falling back to the caller's workdir would
# lose a failure's evidence to the suite's own cleanup. The pool never runs (prepare is never called).
printf 'not a directory\n' > "$work/artifacts-file"
shm art-unusable "$CAUGHT" ADB_MUTATION_ARTIFACTS="$work/artifacts-file"
eq "$rc" 1 "shmutant: an unusable ADB_MUTATION_ARTIFACTS fails the suite"
has "$out" "cannot take this pool's workdir" "shmutant: …saying why"
[ ! -e "$work/prep-art-unusable.log" ] && ok || bad "shmutant: the pool ran although its evidence could not be kept"
# A stale stream that cannot be removed stops the pool: shmutant would APPEND to it.
mkdir -p "$work/shm-stale-stream/pool.tsv"
shm stale-stream "$CAUGHT"
eq "$rc" 1 "shmutant: a stale stream that cannot be removed fails the suite"
has "$out" "a stale verdict stream" "shmutant: …saying why"
rmdir "$work/shm-stale-stream/pool.tsv" 2>/dev/null
# A passing pool's directory that cannot be removed is a failure: it would read as a failed pool's
# evidence in the upload. (Root unlinks through mode 555.)
if [ "$(id -u)" -ne 0 ]; then
  shm stub-lock-art "$CAUGHT" ADB_T_STUB=lock-art ADB_POOL_JOBS=2 ADB_MUTATION_ARTIFACTS="$work/artifacts-lock"
  eq "$rc" 1 "shmutant: a passing pool whose evidence directory cannot be removed fails the suite"
  has "$out" "could not be removed — it would read as a failed pool's evidence" "shmutant: …saying why"
  chmod 755 "$work/artifacts-lock" 2>/dev/null
fi
# A pool that passes removes its own directory, so what remains is the evidence of a failure.
shm art-green "$CAUGHT" ADB_MUTATION_ARTIFACTS="$work/artifacts-green"
eq "$(find "$work/artifacts-green" -mindepth 1 -maxdepth 1 -name 'fixture.*' 2>/dev/null | wc -l | tr -d ' ')" 0 \
  "shmutant: a green pool leaves nothing under ADB_MUTATION_ARTIFACTS"
# …unless the operator asked shmutant to keep its clones: SHMUTANT_KEEP=1 keeps the directory.
shm keep-art "$CAUGHT" SHMUTANT_KEEP=1 ADB_MUTATION_ARTIFACTS="$work/artifacts-keep"
eq "$rc" 0 "shmutant: SHMUTANT_KEEP=1 with a passing pool still passes"
[ -n "$(find "$work/artifacts-keep" -mindepth 1 -maxdepth 1 -type d -name 'fixture.*' 2>/dev/null)" ] && ok \
  || bad "shmutant: SHMUTANT_KEEP=1 did not keep the passing pool's directory"
# A RELATIVE ADB_MUTATION_ARTIFACTS means the invocation's directory, whatever prepare does to it.
shm relart "shmutant_mut cosmetic '# a comment nothing reads' '# a comment nobody reads' 'add-sum'" \
  ADB_T_CWD="$work/shm-relart" ADB_MUTATION_ARTIFACTS=arts ADB_T_PREP_CD=1
[ -n "$(find "$work/shm-relart/arts" -mindepth 1 -maxdepth 1 -type d -name 'fixture.*' 2>/dev/null)" ] && ok \
  || bad "shmutant: a relative ADB_MUTATION_ARTIFACTS was not resolved against the invocation's directory"
# The settings are PINNED, not inherited: an operator's exported shmutant knobs cannot change the verdict
# (a counts run needs the baseline, which is off, so an exported SHMUTANT_COUNTS=1 used to be a refusal).
shm hostile-env "$CAUGHT" SHMUTANT_COUNTS=1 SHMUTANT_BASELINE=1 SHMUTANT_RED_PREFIX='NOPE: ' SHMUTANT_RED_STATUS=9 SHMUTANT_TIMEOUT=1
eq "$rc" 0 "shmutant: exported SHMUTANT_* settings do not reach the pool — it still kills the row"

# The settings the adapter owes shmutant, observed from inside the call, and the stream it must
# refuse whole. Each stub line is a stream shmutant could never write, or a status that disagrees.
shm stub-ok "$CAUGHT" ADB_T_STUB=ok ADB_MUTATION_ROW_TIMEOUT_SECS=77 ADB_POOL_JOBS=3
eq "$rc" 0 "stub: a consistent stream and status pass"
eq "$(cat "$work/seen-stub-ok" 2>/dev/null)" "77|3|0|$work/shm-stub-ok/pool.tsv|1|FAIL: |0" \
  "stub: shmutant got the row deadline, adb_pool_size's width, no baseline, a stream beside the workdir, check-lib's red and no counts"
eq "$(cat "$work/seen-stub-ok.env" 2>/dev/null)" "unexported" "stub: …as locals this call does not export to the suites a row runs"
for _c in garbage:"is not in shmutant's v1 grammar" short-field:"is not in shmutant's v1 grammar" \
          version:"is not in shmutant's v1 grammar" rc1-killed:"returned 1 (a row not killed) but every row record says killed" \
          rc0-survived:"returned 0 while 1 row(s) were not killed" no-row:"carries 0 row verdict(s) for a table of 1" \
          no-summary:"summary record is missing" late-row:"a row record follows the summary record" bad-summary:"summary record is missing, repeated, or names another pool, other than its 1 row(s)" \
          no-stream:"carries 0 row verdict(s) for a table of 1" rc2:"HARNESS ERROR (status 2)" rc7:"returned 7, which is not one of its statuses" \
          wrong-name:"which is not the table's row 0 ('caught')" wrong-target:"which is not the table's row 0 ('caught')" \
          wrong-select:"which is not the table's row 0 ('caught')" bad-seconds:"is not in shmutant's v1 grammar" \
          bad-verdict:"is not in shmutant's v1 grammar" bad-escape:"is not in shmutant's v1 grammar" \
          baseline-rec:"or is a baseline record, and none was run" other-label:"names another pool" \
          nul:"is not whole (a NUL" unterminated:"is not whole (a NUL, no final newline" \
          zero-jobs:"is not in shmutant's v1 grammar" other-jobs:"or a width other than the 2 it was given" \
          fifo:"is not a regular file, or could not be read into a snapshot"; do
  _m="${_c%%:*}"; _w="${_c#*:}"
  # The width is PINNED (ADB_POOL_JOBS=2), so the summary's expected width is the same on every host —
  # adb_pool_size is min(cpu, cap), and a 3-core runner would otherwise expect 3 where this one has 4.
  shm "stub-$_m" "$CAUGHT" ADB_T_STUB="$_m" ADB_POOL_JOBS=2
  eq "$rc" 1 "stub $_m: the suite fails"
  has "$out" "$_w" "stub $_m: …saying why"
  has "$out" "adapter-rc=1" "stub $_m: …and the adapter itself returns non-zero, whatever its caller does next"
done
# A failure of the STREAM keeps its evidence too: the stream the pool wrote stays where it was written.
shm stub-garbage-art "$CAUGHT" ADB_T_STUB=garbage ADB_MUTATION_ARTIFACTS="$work/artifacts-garbage"
_art="$(find "$work/artifacts-garbage" -mindepth 1 -maxdepth 1 -type d -name 'fixture.*' 2>/dev/null | head -1)"
[ -n "$_art" ] && [ -f "$_art/pool.tsv" ] && ok || bad "shmutant: a malformed stream was not kept as evidence"
# A record that cannot be trusted scores NOTHING: the killed row beside the garbage is not an `ok`.
has "$out" "the stream was NOT trusted — its 1 kill(s) of 1 are not counted" "shmutant: an untrusted stream's kills are named as uncounted"
has "$out" "shm-driver: 0 passed" "shmutant: …and none of them reached the pass counter"
# A stream replaced by a link to a FIFO is refused WITHOUT being opened — a read would block on it —
# and the pool's directory is still kept.
shm stub-fifo-art "$CAUGHT" ADB_T_STUB=fifo ADB_MUTATION_ARTIFACTS="$work/artifacts-fifo"
eq "$rc" 1 "shmutant: a FIFO in the stream's place fails the suite, and does not hang it"
has "$out" "is kept in" "shmutant: …and its evidence directory is kept"
# A stream the adapter cannot read is refused, never scored. (Root reads through mode 000.)
if [ "$(id -u)" -ne 0 ]; then
  shm stub-unreadable "$CAUGHT" ADB_T_STUB=unreadable
  has "$out" "could not be read into a snapshot" "shmutant: an unreadable stream is refused"
  chmod 600 "$work/shm-stub-unreadable/pool.tsv" 2>/dev/null
fi
# A RELATIVE workdir survives a prepare that changes directory: the adapter makes it absolute first.
shm reldir "$CAUGHT" ADB_T_CWD="$work/shm-reldir" ADB_T_WD=pool ADB_T_PREP_CD=1
eq "$rc" 0 "shmutant: a relative workdir still scores after a prepare that changed directory"
# A caller under `set -e` still gets the verdict scored and named before its shell acts on the status.
shm errexit "shmutant_mut cosmetic '# a comment nothing reads' '# a comment nobody reads' 'add-sum'" ADB_T_ERREXIT=1
has "$out" "FAIL: mutation 'cosmetic': survived" "shmutant: a caller's errexit does not end the shell before the survivor is named"
# An EMPTY table proves nothing, whatever a pool would say about it — and it is refused before an
# evidence directory is made, so a refusal leaves nothing to upload.
shm empty "" ADB_MUTATION_ARTIFACTS="$work/artifacts-empty"
eq "$rc" 1 "shmutant: an empty table fails the suite"
has "$out" "the mutation table is EMPTY" "shmutant: …saying so, before any pool runs"
eq "$(find "$work/artifacts-empty" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0 "shmutant: …and leaves no evidence directory behind"
# A workdir of `/` is not a directory of the pool's own: `<workdir>.tsv` would land at the root.
shm rootwd "$CAUGHT" ADB_T_WD=/
eq "$rc" 1 "shmutant: a workdir of / is refused"
has "$out" "the workdir must name a directory of its own" "shmutant: …saying why"
# shmutant ESCAPES a backslash in a field; the adapter must accept the records its own pool writes.
shm escaped-name "shmutant_mut 'slash\\name' '0 - \$1' '0 + \$1' 'neg-value'"
eq "$rc" 0 "shmutant: a row whose name holds a backslash round-trips through the stream"

# 10g'. an output that cannot be read back is not scored: a read that failed part-way can still
# carry the witness, so the row gets its own verdict instead of a RED it did not earn.
rows unreadable "check_row add lib.sh base '\$1 + \$2' '\$1 - \$2' 'add-sum'" ADB_T_UNLINK=1
eq "$rc" 1 "a row whose output cannot be read back fails the harness"
has "$out" "mutation 'add': its output could not be read back" "an unreadable output is named"
has "$out" "1/1 mutation(s) applied, 0 observed RED" "an unreadable output is applied, never RED"

# 10g". the bounded subshell restores the caller's override EXACTLY — absent, exported, or set but not
# exported — so the suite under test sees the environment it was given and nothing the bound needed.
_envcb() { bash -c 'printf "%s" "${ADB_NO_TIMEOUT_BIN-UNSET}"'; }
( unset ADB_NO_TIMEOUT_BIN; CHECK_ROW_SECS=30; _check_run_bounded "$work/env1" _envcb )
eq "$(cat "$work/env1")" UNSET "an absent override stays absent inside the bound"
( export ADB_NO_TIMEOUT_BIN=0; CHECK_ROW_SECS=30; _check_run_bounded "$work/env2" _envcb )
eq "$(cat "$work/env2")" 0 "an exported override is restored, exported"
# shellcheck disable=SC2034  # both are read by _check_run_bounded, in check-lib.sh
( unset ADB_NO_TIMEOUT_BIN; ADB_NO_TIMEOUT_BIN=caller-local; CHECK_ROW_SECS=30; _check_run_bounded "$work/env3" _envcb )
eq "$(cat "$work/env3")" UNSET "an override the caller never exported does not reach the suite under test"

# 10h. CANCELLATION: the bound runs each suite in a process group of its own, so terminating the
# harness the way selfcheck's _cleanup does (TERM to the harness's group) must still reach it.
printf '%s\n' "check_row cancel lib.sh uses-helper 'T_A=1' 'sleep ${HANG}6' 'neg-value'" > "$work/rows-cancel.sh"
set -m
env ADB_T_LIB="$T_LIB" ADB_T_FIX="$fix" ADB_T_ROWS="$work/rows-cancel.sh" ADB_T_WD="$work/wd-cancel" \
  ADB_T_PREP_LOG="$work/prep-cancel.log" ADB_MUTATION_ROW_TIMEOUT_SECS=600 bash "$work/driver.sh" > /dev/null 2>&1 &
_cpid=$!
set +m
_deadline=$(( EPOCHSECONDS + 30 ))
until [ -n "$(survivors)" ] || [ "$EPOCHSECONDS" -ge "$_deadline" ]; do sleep 0.2; done
case "$(survivors)" in
  ''|ERR*) bad "cancellation: the hung row never started (or the process table is unreadable), so this case proves nothing" ;;
  *) ok ;;
esac
kill -TERM -- "-$_cpid" 2>/dev/null
_deadline=$(( EPOCHSECONDS + 15 ))
until [ -z "$(survivors)" ] || [ "$EPOCHSECONDS" -ge "$_deadline" ]; do sleep 0.2; done
no_survivor "cancelling the harness"
wait "$_cpid" 2>/dev/null
kill_own

# 11. SHARDING (#532). The shards of one table must cover every row exactly once — asked of the
# verdict files each run leaves, not of its printed output — and a row outside the shard must
# contribute no assertion: the three rows below are all detected, so every count is exact.
ran_rows() {   # <workdir> — the row indices this run scored (any verdict but outside), one per line
  local f
  for f in "$1"/row-*/verdict; do
    [ -f "$f" ] || continue
    case "$(cut -d'|' -f1 "$f")" in outside) ;; *) f="${f%/verdict}"; printf '%s\n' "${f##*/row-}" ;; esac
  done
}
for _of in 1 2 3; do
  : > "$work/shard-union-$_of"
  for (( _k = 1; _k <= _of; _k++ )); do
    rows "shard-$_k-$_of" "$three" "ADB_MUTATION_SHARD=$_k/$_of"
    eq "$rc" 0 "shard $_k/$_of of the table passes"
    _mine=0; for (( _i = 0; _i < 3; _i++ )); do [ $(( _i % _of )) -eq $(( _k - 1 )) ] && _mine=$((_mine + 1)); done
    has "$out" "shard $_k/$_of — $_mine of 3 row(s) belong to it" "shard $_k/$_of names its share of the table"
    has "$out" "$_mine/$_mine mutation(s) applied, $_mine observed RED" "shard $_k/$_of tallies only its own rows"
    has "$out" "driver: $_mine passed, 0 failed" "shard $_k/$_of: a row outside it is not scored as a passing assertion"
    [ "$_of" -eq 1 ] || has "$out" "$((3 - _mine)) row(s) left to the other shard(s)" "shard $_k/$_of: the summary counts the rows it left"
    ran_rows "$work/wd-shard-$_k-$_of" >> "$work/shard-union-$_of"
  done
  eq "$(LC_ALL=C sort -n "$work/shard-union-$_of" | tr '\n' ' ')" "0 1 2 " "the $_of shard(s) together score every row exactly once"
done
# THE PREPARE LOG: per-block mode, shard 1/3 holds only `add` (block `base`) — one full control, one
# block control, one row = 3 copies. A row outside the shard built anyway would move this.
eq "$(wc -l < "$work/prep-shard-1-3.log" | tr -d ' ')" 3 "shard 1/3 builds only its own row and that row's controls"
rows shard-full "$three" ADB_MUTATION_SHARD=2/3 ADB_MUTATION_FULL_SUITE=1
eq "$rc" 0 "a shard in full-suite mode passes"
has "$out" "1/1 mutation(s) applied, 1 observed RED on their own witness (pool=" "a full-suite shard scores only its own row"
has "$out" "full suite per mutant" "the shard keeps full-suite mode"
# …and the gate applies inside the shard: its only row gated is a shard with nothing to run, while a
# gated row in ANOTHER shard is not this shard's to count.
rows shard-gated "$three" ADB_MUTATION_SHARD=1/3 ADB_T_GATE_SKIP=0
has "$out" "0/1 row(s) run — every row gated" "a shard whose only row is gated says so"
[ ! -e "$work/prep-shard-gated.log" ] && ok || bad "a shard whose rows are all gated must build no tree copy"
rows shard-gated-other "$three" ADB_MUTATION_SHARD=1/3 ADB_T_GATE_SKIP=1
has "$out" "1/1 mutation(s) applied" "a row gated in another shard does not change this one"
lacks "$out" "row(s) gated" "a row outside the shard is never reported as gated here"
# A broken declaration OUTSIDE the shard still refuses it: every shard validates the whole table.
rows shard-decl "$three
check_row absent lib.sh base 'no such text' 'x' 'add-sum'" ADB_MUTATION_SHARD=1/4
eq "$rc" 1 "a broken row outside the shard still fails the shard"
has "$out" "row 'absent': its literal is ABSENT" "the broken row outside the shard is named"
# THE SELECTOR, refused before anything is built — never read as "no shard".
for _v in 0/3 4/3 3 /3 1/ a/3 1/3/3 '1 /3' -1/3 1/0 1/1234567890 1.0/3; do
  rows "badshard-${_v//[^0-9a-z]/_}" "$three" "ADB_MUTATION_SHARD=$_v"
  eq "$rc" 1 "ADB_MUTATION_SHARD='$_v' fails the harness"
  has "$out" "ADB_MUTATION_SHARD" "ADB_MUTATION_SHARD='$_v' is named"
  [ ! -e "$work/prep-badshard-${_v//[^0-9a-z]/_}.log" ] && ok || bad "ADB_MUTATION_SHARD='$_v': a tree copy was built before the selector was validated"
done
rows shard-toomany "$three" ADB_MUTATION_SHARD=1/4
has "$out" "splits 3 row(s) into 4 shards, so a shard would hold no row" "more shards than rows is refused"
rows shard-past "$three" ADB_MUTATION_SHARD=3/2
has "$out" "names shard 3 of only 2" "a shard past the count is refused"
rows shard-empty "$three" ADB_MUTATION_SHARD=
eq "$rc" 0 "an empty selector runs the whole table"
has "$out" "3/3 mutation(s) applied" "an empty selector shards nothing"
lacks "$out" "shard " "an empty selector prints no shard line"

# 12. BLOCK MODE FOR THE SHMUTANT POOL (#631): a sixth argument says the selectors are blocks. The
# controls are shmutant's own baselines, so what is proved here is the ADAPTER's half, through real
# pools over the same fixture: the declarations it checks itself, the settings and the selection it
# hands shmutant, the block counts it forwards, the one hole it closes (a selected block that
# reported no count), and the baseline records it must read. `copies` counts the trees a run's
# prepare built — one line per call.
copies() { if [ -f "$work/prep-$1.log" ]; then wc -l < "$work/prep-$1.log" | tr -d ' '; else echo 0; fi; }
shm_three="shmutant_mut add '\$1 + \$2' '\$1 - \$2' 'add-sum' base
shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult
shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper"
shm blk "$shm_three" ADB_T_SUITE=suite.sh
eq "$rc" 0 "shmutant blocks: rows that name their blocks pass"
has "$out" "3/3 mutation(s) killed on their own witness (shmutant; pool=" "shmutant blocks: the tally counts every row"
has "$out" "per-block, 3 selection(s) controlled; row deadline" "shmutant blocks: the tally names the mode and the selections controlled"
eq "$(copies blk)" 1 "shmutant blocks: prepare runs once — every control is a clone of the pool's tree, as every row is"
[ ! -e "$work/shm-blk/pool.counts" ] && ok || bad "shmutant blocks: the directory the runs' count files went to is removed when the pool returns"
eq "$(awk -F'\t' '$3 == "baseline" { printf "[%s:%s]", $4, $5 }' "$work/shm-blk/pool.tsv" 2>/dev/null)" \
   "[:green][base:green][mult:green][uses-helper:green]" \
   "shmutant blocks: the stream holds the unselected baseline and one per selection, each green on its counts"
# THE SELECTION REACHES THE SUITE. A defect only a LATER block detects stays green when its row
# selects `base`, and goes red off-witness once every mutant runs the whole suite.
shm_elsewhere="shmutant_mut elsewhere '\$1 * \$2' '\$1 + \$2' 'add-sum' base"
shm blk-elsewhere "$shm_elsewhere" ADB_T_SUITE=suite.sh
eq "$rc" 1 "shmutant blocks: a row whose block cannot see its defect fails"
has "$out" "FAIL: mutation 'elsewhere': survived" "shmutant blocks: a row runs only the block it names"
shm blk-elsewhere-full "$shm_elsewhere" ADB_T_SUITE=suite.sh ADB_MUTATION_FULL_SUITE=1
has "$out" "FAIL: mutation 'elsewhere': accidental" "shmutant blocks: full-suite mode runs every block for the same row"
# FULL-SUITE MODE: ONE baseline, the whole suite, however many selections the rows declare.
shm blk-full "$shm_three" ADB_T_SUITE=suite.sh ADB_MUTATION_FULL_SUITE=1
eq "$rc" 0 "shmutant blocks: valid rows pass in full-suite mode"
has "$out" "3/3 mutation(s) killed on their own witness (shmutant; pool=" "shmutant blocks: full-suite mode tallies every row"
has "$out" "full suite per mutant; row deadline" "shmutant blocks: full-suite mode is named"
eq "$(awk -F'\t' '$3 == "baseline" { n++ } END { print n + 0 }' "$work/shm-blk-full/pool.tsv" 2>/dev/null)" 1 \
   "shmutant blocks: full-suite mode runs one baseline, not one whole-suite run per declared selection"
has "$out" "table-after=3 base mult uses-helper" "shmutant blocks: full-suite mode leaves the caller's table as it was declared, selectors included"
# WITHOUT the sixth argument nothing here applies: the selectors are whatever the caller made them.
shm blk-off "$shm_three"
eq "$rc" 0 "shmutant: rows with a fifth argument still pass a pool that is not in block mode"
lacks "$out" "per-block" "shmutant: …and that pool's tally names no block mode"
eq "$(awk -F'\t' '$3 == "baseline" { n++ } END { print n + 0 }' "$work/shm-blk-off/pool.tsv" 2>/dev/null)" 0 "shmutant: …and it runs no baseline"
# THE DECLARATIONS, each refused before anything is built — in full-suite mode too, where the
# selector is not used to run anything and a broken one would otherwise never be seen.
for _c in "omitted|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value'|its selector equals its witness" \
          "undeclared|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' nope|block 'nope' is not declared in suite.sh" \
          "in-list|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper,nope|block 'nope' is not declared in suite.sh" \
          "glob|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' '*'|block '*' is not declared in suite.sh" \
          "repeated|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper,uses-helper|its selector 'uses-helper,uses-helper' names block 'uses-helper' twice" \
          "with-a-gap|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper,,base|its selector 'uses-helper,,base' has an empty element" \
          "ending-in-a-comma|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper,|its selector 'uses-helper,' has an empty element" \
          "elsewhere|shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' base|witness 'neg-value' does not appear in block(s) 'base'"; do
  _m="${_c%%|*}"; _c="${_c#*|}"; _r="${_c%%|*}"; _w="${_c#*|}"
  for _f in "" 1; do
    shm "decl-$_m$_f" "$_r" ADB_T_SUITE=suite.sh "ADB_MUTATION_FULL_SUITE=$_f"
    eq "$rc" 1 "shmutant blocks: a row with its block $_m fails the suite (full-suite '$_f')"
    has "$out" "row 'neg': $_w" "shmutant blocks: …naming the row and why (full-suite '$_f')"
    has "$out" "1 row declaration(s) are invalid — nothing was built or run" "shmutant blocks: …and that nothing ran (full-suite '$_f')"
    eq "$(copies "decl-$_m$_f")" 0 "shmutant blocks: a refused declaration builds no tree (full-suite '$_f')"
  done
done
# A caller under `set -e` still gets the refusal named.
shm decl-errexit "shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' nope" ADB_T_SUITE=suite.sh ADB_T_ERREXIT=1
has "$out" "row 'neg': block 'nope' is not declared in suite.sh" "shmutant blocks: a caller's errexit does not end the shell before a refused declaration is named"
# A witness that SPELLS a block id: the block's own declaration line carries it, so only the equality
# rule can tell an omitted fifth argument from a real selector.
shm decl-spelled "shmutant_mut neg '0 - \$1' '0 + \$1' 'uses-helper'" ADB_T_SUITE=suite.sh
has "$out" "row 'neg': its selector equals its witness" "shmutant blocks: an omitted block is refused even when the witness spells a block id"
shm decl-noblocks "$shm_three" ADB_T_SUITE=lib.sh
eq "$rc" 1 "shmutant blocks: a suite that declares no blocks fails"
has "$out" "lib.sh declares no blocks" "shmutant blocks: …saying so"
shm decl-missing "$shm_three" ADB_T_SUITE=absent.sh
has "$out" "cannot read" "shmutant blocks: a suite that cannot be read is refused"
# A WITNESS IS FOUND IN ONE BLOCK, never across the end of one and the start of the next.
shm decl-seam "shmutant_mut neg '0 - \$1' '0 + \$1' 'fiif check_block mult base; then' base,mult" ADB_T_SUITE=suite.sh
eq "$rc" 1 "shmutant blocks: a witness spelled by the end of one block and the start of the next is refused"
has "$out" "does not appear in block(s) 'base,mult'" "shmutant blocks: …as a witness neither block carries"
# A SOURCE READ THAT FAILS IS NOT THE BLOCK: this sed prints the witness and then fails, for the
# shmutant pool and for the per-block rows, which read the source through the same helper.
mkdir -p "$work/sed-stub"
printf '#!/bin/sh\ncase "$1 $2" in "-n "*p) printf "neg-value\\n"; exit 77 ;; esac\nexec "%s" "$@"\n' "$(command -v sed)" > "$work/sed-stub/sed"; chmod +x "$work/sed-stub/sed"
shm decl-sed "shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper" ADB_T_SUITE=suite.sh PATH="$work/sed-stub:$PATH"
eq "$rc" 1 "shmutant blocks: a block whose source could not be read fails the suite"
has "$out" "row 'neg': the source of block(s) 'uses-helper' could not be read from suite.sh" "shmutant blocks: …saying the read failed, never that the witness is there"
eq "$(copies decl-sed)" 0 "shmutant blocks: …before anything is built"
rows decl-sed "check_row neg lib.sh uses-helper '0 - \$1' '0 + \$1' 'neg-value'" PATH="$work/sed-stub:$PATH"
eq "$rc" 1 "a block whose source could not be read fails the per-block rows too"
has "$out" "row 'neg': the source of block(s) 'uses-helper' could not be read from suite.sh" "…named the same way"
# THE COUNT DIRECTORY IS MADE BY THE POOL, never found: one left by another run is refused.
mkdir -p "$work/shm-decl-counts/pool.counts"
shm decl-counts "$shm_three" ADB_T_SUITE=suite.sh
eq "$rc" 1 "shmutant blocks: a block-count directory that already exists fails the suite"
has "$out" "pool.counts already exists or could not be made" "shmutant blocks: …saying why"
eq "$(copies decl-counts)" 0 "shmutant blocks: …before anything is built"
# …and one this pool cannot remove afterwards is a failure, not a leftover. (Root unlinks through 555.)
if [ "$(id -u)" -ne 0 ]; then
  variant_after shm-keep 'check_blocks_done' '[ -z "${ADB_CHECK_BLOCK_COUNTS:-}" ] || { d="$(dirname "$ADB_CHECK_BLOCK_COUNTS")/locked"; mkdir -p "$d" && : > "$d/f" && chmod 555 "$d"; }'
  shm ctl-keep "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-keep"
  eq "$rc" 1 "shmutant blocks: a block-count directory that cannot be removed fails the suite"
  has "$out" "pool.counts could not be removed" "shmutant blocks: …saying which"
  # A caller under `set -e` gets the same diagnostic: the removal is tried before errexit is put back.
  shm ctl-keep-e "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-keep" ADB_T_ERREXIT=1
  has "$out" "pool.counts could not be removed" "shmutant blocks: a caller's errexit does not end the shell before the removal failure is named"
  has "$out" "1/1 mutation(s) killed" "shmutant blocks: …or before the rows are scored"
  chmod -R u+w "$work/shm-ctl-keep" "$work/shm-ctl-keep-e" 2>/dev/null
fi
# The selection is set around <run-fn>, so it has to be something that can be called from the wrapper.
shm decl-run "$shm_three" ADB_T_SUITE=suite.sh ADB_T_RUN_CB=/bin/cat
eq "$rc" 1 "shmutant blocks: a <run-fn> that is not a shell function is refused"
has "$out" "<run-fn> must then be a shell function — '/bin/cat' is not one" "shmutant blocks: …saying so"
eq "$(copies decl-run)" 0 "shmutant blocks: …before anything is built"
# THE CONTROLS ARE SHMUTANT'S BASELINES, and a row is scored only under a green one. A red whole
# suite leaves no selection anything to be compared with: every row is `baseline`, none is run.
variant_after shm-red 'if check_block base; then' '  eq 1 2 "forced-red"'
shm ctl-red "$shm_three" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-red"
eq "$rc" 1 "shmutant blocks: a red whole-suite baseline fails the suite"
has "$out" "FAIL: fixture --mutation: baseline [the whole suite, unselected]: red" "shmutant blocks: …named as the unselected baseline"
has "$out" "FAIL: mutation 'add': baseline" "shmutant blocks: …and its rows are scored baseline, not killed"
has "$out" "shm-driver: 0 passed" "shmutant blocks: …so none of them reaches the pass counter"
# A selection that fails on its own (an undeclared dependency) costs only the rows on it.
variant shm-nodep 's/^if check_block uses-helper mult; then$/if check_block uses-helper; then/'
shm ctl-nodep "$shm_three" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-nodep"
eq "$rc" 1 "shmutant blocks: a selection that fails on its own fails the suite"
has "$out" "FAIL: fixture --mutation: baseline [uses-helper]: red" "shmutant blocks: an undeclared dependency is named on its selection"
has "$out" "FAIL: mutation 'neg': baseline" "shmutant blocks: …and the row on it is scored baseline"
lacks "$out" "baseline [base]" "shmutant blocks: …while a selection that reproduces its block is not named"
has "$out" "2/3 mutation(s) killed" "shmutant blocks: …and the rows on the other selections are still scored"
has "$out" "adapter-rc=1" "shmutant blocks: …and the adapter returns non-zero"
# THE COUNTS ARE COMPARED PER BLOCK, DEPENDENCIES INCLUDED. `base` runs one more assertion when it
# runs as part of a selection: its own baseline is incomplete, and so is every selection that only
# depends on it.
variant_after shm-count 'if check_block base; then' '  [ -z "${ADB_CHECK_BLOCK:-}" ] || ok'
shm ctl-count "shmutant_mut add '\$1 + \$2' '\$1 - \$2' 'add-sum' base
shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-count"
eq "$rc" 1 "shmutant blocks: a selection that runs another count fails the suite"
has "$out" "baseline [base]: incomplete" "shmutant blocks: the selection whose own count moved is incomplete"
has "$out" "unit [base] ran 2 assertion(s) here and 1 in the unselected run" "shmutant blocks: …naming the block and both counts"
has "$out" "baseline [mult]: incomplete" "shmutant blocks: a selection whose DEPENDENCY ran another count is incomplete too"
shm ctl-count-full "$shm_three" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-count" ADB_MUTATION_FULL_SUITE=1
eq "$rc" 0 "shmutant blocks: full-suite mode runs no selection, so it has none to compare"
# A count line off the grammar is refused by shmutant's own reader, which is the one that reads them.
variant_after shm-junk 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || printf 'x\\t1junk\\n' >> \"\$ADB_CHECK_BLOCK_COUNTS\""
shm ctl-junk "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-junk"
eq "$rc" 1 "shmutant blocks: a count line that is not <unit><TAB><digits> fails the suite"
has "$out" "baseline [mult]: incomplete" "shmutant blocks: …as an incomplete baseline"
has "$out" "its count lines are unusable" "shmutant blocks: …saying the counts could not be used"
# THE ONE HOLE THE WRAPPER CLOSES: shmutant compares the units a run REPORTS, so a selected block
# that reported nothing would pass on its dependency's count alone.
variant_after shm-silent 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || { grep -v '^mult' \"\$ADB_CHECK_BLOCK_COUNTS\" > \"\$ADB_CHECK_BLOCK_COUNTS.kept\"; cat \"\$ADB_CHECK_BLOCK_COUNTS.kept\" > \"\$ADB_CHECK_BLOCK_COUNTS\"; }"
shm ctl-silent "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-silent" SHMUTANT_KEEP=1
eq "$rc" 1 "shmutant blocks: a selection that reports no count for a block it selected fails the suite"
has "$out" "baseline [mult]: red" "shmutant blocks: …as a red baseline, never a green one"
has "$(cat "$work"/shm-ctl-silent/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: the selection 'mult' reported no count for block 'mult', which it runs" \
    "shmutant blocks: …and the run's own output says which block"
# WHAT IS CHECKED IS WHAT WAS HANDED OVER. This `head` appends the missing block's count to the file
# just after the snapshot of it is taken, as a process the run left behind could: the count never
# reached shmutant, so it must not satisfy the check either.
mkdir -p "$work/head-stub"
printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase "$3" in */pool.counts/run.??????) printf "mult\\t1\\n" >> "$3" ;; esac\nexit "$rc"\n' "$(command -v head)" > "$work/head-stub/head"; chmod +x "$work/head-stub/head"
shm ctl-late "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-silent" PATH="$work/head-stub:$PATH"
eq "$rc" 1 "shmutant blocks: a count that appears in the file only after its snapshot was taken does not count"
has "$out" "baseline [mult]: red" "shmutant blocks: …so the selection is still red"
# THE BYTES ARE HANDED OVER AS THE RUN WROTE THEM, or not at all. A NUL and an oversized file are
# refused here by the byte rules; an empty record is left for shmutant's own reader to refuse, which
# it can only do if nothing on the way has tidied it up.
variant_after shm-nul 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || printf 'ba\\000se\\t1\\n' >> \"\$ADB_CHECK_BLOCK_COUNTS\""
shm ctl-nul "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-nul" SHMUTANT_KEEP=1
eq "$rc" 1 "shmutant blocks: a count file holding a NUL fails the suite"
has "$out" "baseline [mult]: red" "shmutant blocks: …as a red baseline"
has "$(cat "$work"/shm-ctl-nul/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: this run's block counts are not whole" "shmutant blocks: …refused by the byte rules, not passed on with the NUL dropped"
variant_after shm-big 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || { head -c 1100000 /dev/zero | tr '\\000' x; printf '\\n'; } >> \"\$ADB_CHECK_BLOCK_COUNTS\""
shm ctl-big "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-big" SHMUTANT_KEEP=1
eq "$rc" 1 "shmutant blocks: a count file past the bound fails the suite"
has "$(cat "$work"/shm-ctl-big/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: this run's block counts are not whole" "shmutant blocks: …refused by the bound"
variant_after shm-blank 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || printf '\\n' >> \"\$ADB_CHECK_BLOCK_COUNTS\""
shm ctl-blank "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-blank"
eq "$rc" 1 "shmutant blocks: a count file with an empty record fails the suite"
has "$out" "baseline [mult]: incomplete" "shmutant blocks: …because the empty record reached shmutant, whose reader refuses it"
has "$out" "its count lines are unusable" "shmutant blocks: …saying the counts could not be used"
# The snapshot is a file of this run's own making: owner-only, and at a name nothing could have
# put a link at. The suite leaves a link where a predictable name would have been, and the file it
# points at must still be untouched afterwards.
variant_after shm-link 'check_blocks_done' '[ -z "${ADB_CHECK_BLOCK_COUNTS:-}" ] || ln -s "$ADB_T_VICTIM" "$ADB_CHECK_BLOCK_COUNTS.snap"'
printf 'untouched\n' > "$work/victim"
shm ctl-link "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-link" ADB_T_VICTIM="$work/victim"
eq "$rc" 0 "shmutant blocks: a link left beside a run's count file does not stop the pool"
eq "$(cat "$work/victim")" "untouched" "shmutant blocks: …and what it points at is not written through"
# A count file's removal is judged by `rm`'s own status AND by what is left at the path. The driver's
# `rm` (ADB_T_RM) removes a run's count file and then returns 77, or leaves a dangling link in its
# place. A function, not a stub on PATH: a real pool leaves `rm` hashed to the system's own.
for _m in status link; do
  shm "ctl-rm-$_m" "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_RM="$_m" SHMUTANT_KEEP=1
  eq "$rc" 1 "shmutant blocks: a count file whose removal fails ($_m) fails the suite"
  has "$(cat "$work/shm-ctl-rm-$_m"/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: this run's block-count file could not be removed" "shmutant blocks: …and the run's own output says so ($_m)"
done
# A RUN THAT WAS NOT GREEN KEEPS ITS OWN STATUS. This mutant prints the row's witness, removes its
# count file and exits 2: an abort, which no trouble with its counts may turn into a red.
shm ctl-abort "shmutant_mut dies 'T_A=1' 'printf \"FAIL: neg-value\\n\"; rm -f \"\$ADB_CHECK_BLOCK_COUNTS\"; exit 2' 'neg-value' uses-helper" ADB_T_SUITE=suite.sh
eq "$rc" 1 "shmutant blocks: a mutant that aborts after printing its witness fails the suite"
has "$out" "FAIL: mutation 'dies': aborted" "shmutant blocks: …as aborted, never killed"
# A run's own count files go before it returns, and a file that will not go is that run's failure.
if [ "$(id -u)" -ne 0 ]; then
  variant_after shm-stuck 'check_blocks_done' '[ -z "${ADB_CHECK_BLOCK_COUNTS:-}" ] || chmod 555 "$(dirname "$ADB_CHECK_BLOCK_COUNTS")"'
  shm ctl-stuck "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-stuck" SHMUTANT_KEEP=1
  eq "$rc" 1 "shmutant blocks: a run whose count files cannot be removed fails the suite"
  has "$(cat "$work"/shm-ctl-stuck/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: this run's block-count file could not be removed" "shmutant blocks: …and the run's own output says so"
  chmod -R u+w "$work/shm-ctl-stuck" 2>/dev/null
fi
# …and the same for a block the selection only DEPENDS on, and for any block of the unselected run.
variant_after shm-silent-dep 'check_blocks_done' "[ -z \"\${ADB_CHECK_BLOCK:-}\" ] || { grep -v '^base' \"\$ADB_CHECK_BLOCK_COUNTS\" > \"\$ADB_CHECK_BLOCK_COUNTS.kept\"; cat \"\$ADB_CHECK_BLOCK_COUNTS.kept\" > \"\$ADB_CHECK_BLOCK_COUNTS\"; }"
shm ctl-silent-dep "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-silent-dep" SHMUTANT_KEEP=1
eq "$rc" 1 "shmutant blocks: a selection that reports no count for a block it depends on fails the suite"
has "$out" "baseline [mult]: red" "shmutant blocks: …as a red baseline"
has "$(cat "$work"/shm-ctl-silent-dep/pool/base-*/output 2>/dev/null)" "FAIL: check-blocks: the selection 'mult' reported no count for block 'base', which it runs" \
    "shmutant blocks: …naming the dependency"
variant_after shm-silent-ref 'check_blocks_done' "[ -n \"\${ADB_CHECK_BLOCK:-}\" ] || { grep -v '^empty' \"\$ADB_CHECK_BLOCK_COUNTS\" > \"\$ADB_CHECK_BLOCK_COUNTS.kept\"; cat \"\$ADB_CHECK_BLOCK_COUNTS.kept\" > \"\$ADB_CHECK_BLOCK_COUNTS\"; }"
shm ctl-silent-ref "shmutant_mut mul '\$1 * \$2' '\$1 + \$2' 'mul-product' mult" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-silent-ref" SHMUTANT_KEEP=1
eq "$rc" 1 "shmutant blocks: an unselected run that reports no count for a declared block fails the suite"
has "$out" "baseline [the whole suite, unselected]: red" "shmutant blocks: …as a red reference"
has "$(cat "$work"/shm-ctl-silent-ref/pool/base-*/output 2>/dev/null)" "reported no count for block 'empty', which it runs" \
    "shmutant blocks: …naming the block the reference left out"
# The row deadline reaches the baselines as it reaches the rows.
variant_after shm-hang '  eq "$(sq 3)" 9 "sq-value"' "sleep ${HANG}9"
_t0=$SECONDS
shm ctl-hang "shmutant_mut neg '0 - \$1' '0 + \$1' 'neg-value' uses-helper" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-hang" ADB_MUTATION_ROW_TIMEOUT_SECS=3
within "shmutant blocks: a hung baseline" "$_t0"
has "$out" "baseline [the whole suite, unselected]: timeout" "shmutant blocks: a hung baseline is a named timeout"
no_survivor "shmutant blocks: a hung baseline"
# A failed baseline keeps the pool's evidence where CI uploads it, as a failed row does.
shm ctl-art "$shm_three" ADB_T_SUITE=suite.sh ADB_T_FIX="$work/shm-nodep" ADB_MUTATION_ARTIFACTS="$work/artifacts-ctl"
_art="$(find "$work/artifacts-ctl" -mindepth 1 -maxdepth 1 -type d -name 'fixture.*' 2>/dev/null | head -1)"
[ -n "$_art" ] && [ -f "$_art/pool.tsv" ] && ok || bad "shmutant blocks: a failed baseline's stream was not kept under ADB_MUTATION_ARTIFACTS"
[ ! -e "$_art/pool.counts" ] && ok || bad "shmutant blocks: the runs' count files are not evidence and must not be kept beside it"
has "$out" "is kept in $_art" "shmutant blocks: …and the log says where"
shm ctl-art-green "$shm_three" ADB_T_SUITE=suite.sh ADB_MUTATION_ARTIFACTS="$work/artifacts-ctl-green"
eq "$(find "$work/artifacts-ctl-green" -mindepth 1 -maxdepth 1 -name 'fixture.*' 2>/dev/null | wc -l | tr -d ' ')" 0 \
  "shmutant blocks: a green pool leaves nothing behind under ADB_MUTATION_ARTIFACTS"
# THE SETTINGS and THE STREAM, through the stub: what block mode hands shmutant, and the baseline
# records it must then find — each one expected, in shmutant's order, and green.
_blk="shmutant_mut caught '0 - \$1' '0 + \$1' 'neg-value' uses-helper"
shm stub-blk-ok "$_blk" ADB_T_STUB=blk-ok ADB_POOL_JOBS=2 ADB_T_SUITE=suite.sh
eq "$rc" 0 "stub: block mode accepts the baseline records its table calls for"
eq "$(cut -d'|' -f3,7 "$work/seen-stub-blk-ok" 2>/dev/null)" "1|1" "stub: block mode turns shmutant's baseline and counts on"
# An `rm` that FAILS has not been shown to have removed the count directory, even when nothing is
# left there. Through the stand-in pool: a real one leaves `rm` hashed to the system's own (its
# `command -p rm`), so a stub on PATH would not be the one the adapter then calls.
mkdir -p "$work/rm-stub"
printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase "$*" in *pool.counts) exit 77 ;; esac\nexit "$rc"\n' "$(command -v rm)" > "$work/rm-stub/rm"; chmod +x "$work/rm-stub/rm"
shm stub-rm-status "$_blk" ADB_T_STUB=blk-ok ADB_POOL_JOBS=2 ADB_T_SUITE=suite.sh PATH="$work/rm-stub:$PATH"
eq "$rc" 1 "stub: a removal of the block-count directory that exits non-zero fails the suite"
has "$out" "pool.counts could not be removed (rm exited 77)" "stub: …with the status it exited"
has "$out" "per-block, 1 selection(s) controlled" "stub: …and counts the selections, not the unselected reference"
shm stub-blk-full "$_blk" ADB_T_STUB=blk-full ADB_POOL_JOBS=2 ADB_T_SUITE=suite.sh ADB_MUTATION_FULL_SUITE=1
eq "$rc" 0 "stub: full-suite block mode accepts its one baseline"
eq "$(cut -d'|' -f3,7 "$work/seen-stub-blk-full" 2>/dev/null)" "1|0" "stub: full-suite block mode keeps the baseline and turns the counts off"
for _c in blk-no-base:"carries 0 baseline record(s) where this table's selection(s) need 2" \
          blk-one-base:"carries 1 baseline record(s) where this table's selection(s) need 2" \
          blk-order:"is not the baseline shmutant runs at that position" \
          blk-other:"baseline record 1 is for selector 'base'" \
          blk-extra:"is not the baseline shmutant runs at that position" \
          blk-red-rc0:"returned 0 while 1 baseline(s) were not green" \
          blk-late-base:"a baseline record follows the summary record" \
          blk-mid-base:"a baseline record follows a row record" \
          blk-verdict:"is not in shmutant's v1 grammar" blk-short:"is not in shmutant's v1 grammar"; do
  _m="${_c%%:*}"; _w="${_c#*:}"
  shm "stub-$_m" "$_blk" ADB_T_STUB="$_m" ADB_POOL_JOBS=2 ADB_T_SUITE=suite.sh
  eq "$rc" 1 "stub $_m: the suite fails"
  has "$out" "$_w" "stub $_m: …saying why"
  has "$out" "the stream was NOT trusted" "stub $_m: …and nothing in that stream is scored"
done
has "$(shm stub-blk-red-rc0 "$_blk" ADB_T_STUB=blk-red-rc0 ADB_POOL_JOBS=2 ADB_T_SUITE=suite.sh; printf '%s' "$out")" \
    "FAIL: fixture --mutation: baseline [uses-helper]: red — the baseline detail" "stub: a baseline that is not green is named with shmutant's own detail"
# Outside block mode a baseline record is still what it was: a record of a run nobody made.
shm stub-blk-ok-off "$_blk" ADB_T_STUB=blk-ok ADB_POOL_JOBS=2
has "$out" "or is a baseline record, and none was run" "stub: a pool that runs no baseline still refuses a baseline record"

# 13. SHARDING THE SHMUTANT POOL (#631). The same rule as the per-block rows' (11): the shards cover
# every row exactly once — asked of the row records each run's stream holds — a row outside the shard
# is never run and never a pass, and the caller's table is whole again afterwards.
shm_rows_run() {   # <name> — the row names this run's stream scored, one per line
  awk -F'\t' '$3 == "row" { print $5 }' "$work/shm-$1/pool.tsv" 2>/dev/null
}
for _of in 1 2 3; do
  : > "$work/shm-shard-union-$_of"
  for (( _k = 1; _k <= _of; _k++ )); do
    shm "shard-$_k-$_of" "$shm_three" "ADB_MUTATION_SHARD=$_k/$_of"
    eq "$rc" 0 "shmutant: shard $_k/$_of of the table passes"
    _mine=$(( (3 - _k) / _of + 1 ))
    has "$out" "shard $_k/$_of — $_mine of 3 row(s) belong to it" "shmutant: shard $_k/$_of names its share of the table"
    has "$out" "$_mine/$_mine mutation(s) killed on their own witness" "shmutant: shard $_k/$_of tallies only its own rows"
    has "$out" "shm-driver: $_mine passed, 0 failed" "shmutant: shard $_k/$_of scores no row outside it as a pass"
    has "$out" "table-after=3" "shmutant: shard $_k/$_of leaves the caller's table whole"
    if [ "$_of" -eq 1 ]; then lacks "$out" "left to the other shard(s)" "shmutant: one shard of one leaves no row to another"
    else has "$out" "shard $_k/$_of, $((3 - _mine)) row(s) left to the other shard(s); row deadline" "shmutant: shard $_k/$_of's tally counts the rows it left"; fi
    shm_rows_run "shard-$_k-$_of" >> "$work/shm-shard-union-$_of"
  done
  eq "$(LC_ALL=C sort "$work/shm-shard-union-$_of" | tr '\n' ' ')" "add mul neg " "shmutant: the $_of shard(s) together score every row exactly once"
done
eq "$(shm_rows_run shard-2-3)" "mul" "shmutant: shard 2/3 is the row at index 1"
# In block mode a shard controls only the selections its own rows name.
shm shard-blk "$shm_three" ADB_T_SUITE=suite.sh ADB_MUTATION_SHARD=1/3
eq "$rc" 0 "shmutant blocks: a shard passes"
has "$out" "per-block, 1 selection(s) controlled; shard 1/3, 2 row(s) left to the other shard(s)" "shmutant blocks: a shard's tally names its mode and its share"
eq "$(awk -F'\t' '$3 == "baseline" { printf "[%s:%s]", $4, $5 }' "$work/shm-shard-blk/pool.tsv" 2>/dev/null)" "[:green][base:green]" \
   "shmutant blocks: a shard runs the unselected baseline and its own row's selection, and no other shard's"
# A broken declaration OUTSIDE the shard still refuses it: every shard validates the whole table.
shm shard-decl "$shm_three
shmutant_mut sq '\$1 * \$1' '\$1 + \$1' 'sq-value' nope" ADB_T_SUITE=suite.sh ADB_MUTATION_SHARD=1/4
eq "$rc" 1 "shmutant blocks: a broken row outside the shard still fails the shard"
has "$out" "row 'sq': block 'nope' is not declared" "shmutant blocks: …and is named"
# THE SELECTOR, refused before anything is built — never read as "no shard".
for _v in 0/3 4/3 1/0 x/3 1/ /3 1 1/2/3 "1 /3" -1/3; do
  shm "badshard-${_v//[^0-9a-z]/_}" "$shm_three" "ADB_MUTATION_SHARD=$_v"
  eq "$rc" 1 "shmutant: ADB_MUTATION_SHARD='$_v' fails the suite"
  has "$out" "ADB_MUTATION_SHARD" "shmutant: ADB_MUTATION_SHARD='$_v' is named"
  eq "$(copies "badshard-${_v//[^0-9a-z]/_}")" 0 "shmutant: ADB_MUTATION_SHARD='$_v' builds no tree"
done
shm shard-toomany "$shm_three" ADB_MUTATION_SHARD=1/4
has "$out" "splits 3 row(s) into 4 shards, so a shard would hold no row" "shmutant: more shards than rows is refused"
shm shard-empty "$shm_three" ADB_MUTATION_SHARD=
eq "$rc" 0 "shmutant: an empty selector runs the whole table"
has "$out" "3/3 mutation(s) killed" "shmutant: an empty selector shards nothing"
lacks "$out" "shard " "shmutant: an empty selector prints no shard line"

check_summary "block-rows"
