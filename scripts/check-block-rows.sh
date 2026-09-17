#!/usr/bin/env bash
# ai-dev-baseline — tests for check-lib.sh's blocks and per-test mutation rows (#468). OFFLINE.
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
#   7. full-suite mode (ADB_MUTATION_FULL_SUITE=1) runs every mutant against the whole suite.
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

variant() {   # <name> <sed-expression> — a copy of the fixture with its suite edited
  mkdir -p "$work/$1"; cp "$fix/lib.sh" "$work/$1/"
  sed "$2" "$fix/suite.sh" > "$work/$1/suite.sh"
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
  : >> "$ADB_T_PREP_LOG"
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

check_summary "block-rows"
