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
#      harness says what it compared; every fail-closed path runs everything (#470).
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
run() { ADB_T_LIB="$ADB_T_LIB" bash "$1/suite.sh"; }
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

check_summary "block-rows"
