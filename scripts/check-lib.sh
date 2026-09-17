# shellcheck shell=bash
# ai-dev-baseline — shared helpers for the check-*.sh scripts. In a repo whose thesis is
# single-source, its own checks shouldn't grow copy-pasted scaffolds — so all three cooperating
# helper sets live here once and every check sources what it needs:
#
#   1. grep-assert family (below) — check_init / req_fixed / req_regex / check_fail /
#      check_result: many assertions collapse to ONE boolean verdict (the anti-drift lints).
#   2. unit-test assertion family (§ further down) — ok / bad / bad_quiet / eq / yes / no /
#      has / hasnt + a pass/fail COUNTER + check_summary: the *.sh unit tests.
#   3. git fixture helpers (§ further down) — check_git, check_make_repo_pair,
#      check_make_stub_repo, check_write_stub: throwaway repos and executable stubs.
#   4. PR payload builders (§ further down) — check_pr_*_json, check_pr_json, check_declare_bots.
#   5. mutation harness (§ with check_mutate_line) — check_mutate_literal, check_mut,
#      check_mutation_pool: a defect per row into a tree COPY, require RED (family 2's counters).
#   6. blocks and per-test rows (§ #468) — check_blocks_init, check_block, check_row,
#      check_mutation_rows: a mutant runs only the block that witnesses it, plus its dependencies.
#
# Sourced, never executed. Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks the whole
# scripts/lib dir into ~/.<agent>/scripts/lib, and check/test code must not ship into a user's
# runtime.
#
# Families 1 and 2 keep SEPARATE state (CHECK_FAIL/CHECK_LABEL vs pass/fail) and never collide;
# a single check may use one, or both. Callers touch state only through these functions, never
# the vars — so ShellCheck sees no SC2154 / "unused" false positives across the source boundary.
#
# --- grep-assert family: check_init "<name>" sets the message prefix, req_fixed / req_regex
# (or check_fail directly) accumulate into CHECK_FAIL, and check_result emits the PASS line and
# returns the status.

CHECK_LABEL="check"
CHECK_FAIL=0

# Name this check (used as the diagnostic prefix and in the PASS line).
check_init() { CHECK_LABEL="$1"; }

# Emit a diagnostic line, prefixed with the check's name.
check_note() { printf '%s: %s\n' "$CHECK_LABEL" "$*" >&2; }

# Mark the run failed.
check_fail() { CHECK_FAIL=1; }

# Assert a FIXED string is present in a file. Usage: req_fixed <file> <token> <fact-label>
req_fixed() {
  if [ ! -f "$1" ]; then check_note "[$3] file not found: $1"; check_fail; return; fi
  grep -Fq -- "$2" "$1" || { check_note "[$3] canonical token '$2' missing from $1"; check_fail; }
}

# Assert an EXTENDED-REGEX pattern matches in a file. Usage: req_regex <file> <pattern> <fact-label>
req_regex() {
  if [ ! -f "$1" ]; then check_note "[$3] file not found: $1"; check_fail; return; fi
  grep -Eq -- "$2" "$1" || { check_note "[$3] canonical pattern /$2/ missing from $1"; check_fail; }
}

# Assert an EXTENDED-REGEX pattern does NOT match in a file, reporting the offending lines.
# Usage: req_absent <file> <pattern> <fact-label>
#
# The counterpart to req_regex, for a fact that SUPERSEDES an earlier value. Positive presence
# alone cannot catch a file that carries the new value AND quietly keeps the old one next to it —
# it satisfies req_regex and still misinforms every reader (#93). A missing file is NOT a failure
# here: absence-in-a-nonexistent-file is vacuously true, and the positive rules already fail loudly
# on a bad path, so duplicating that would double-report one typo.
req_absent() {   # adb-allow: req_absent
  [ -f "$1" ] || return 0
  if grep -Eq -- "$2" "$1"; then
    check_note "[$3] superseded pattern /$2/ still present in $1:"
    grep -En -- "$2" "$1" | sed 's/^/    /' >&2
    check_fail
  fi
}

# Emit the terminal result and return 0 (pass) / 1 (fail). Usage: check_result "<pass note>"
check_result() {
  if [ "$CHECK_FAIL" -eq 0 ]; then
    echo "$CHECK_LABEL: PASS${1:+ ($1)}"
    return 0
  fi
  echo "$CHECK_LABEL: FAIL — see the diagnostics above" >&2
  return 1
}

# --- unit-test assertion family (ok/bad/eq/yes/no/has/hasnt + pass/fail counter) --------------
# A SECOND, independent accounting style for the *.sh unit tests (check-common-lib,
# check-baseline, check-gates, check-precommit-gate, check-implement-gate, check-install-migration,
# check-install-guard). They count INDIVIDUAL assertions, where the grep-assert family above
# tracks a single boolean. Each test used to carry a byte-identical copy of these helpers; they
# live here once and every test sources them. Callers touch pass/fail ONLY through ok / bad /
# bad_quiet / check_summary — never the bare vars — so the two accounting styles never collide
# and ShellCheck sees no SC2154 across the source boundary.
pass=0
fail=0
# Set by check_summary as its FIRST action, so a suite can prove its summary actually ran. Without
# that proof a suite fails OPEN: the script's exit status is its last command's, `bad` only records
# into `fail`, and `fail` is only ever consulted inside check_summary — so a file truncated before
# its final line, or an early `exit 0`/`return`, prints `FAIL:` lines and still exits 0. selfcheck
# and CI then report the step as passing. See check_exit_guard below (#213).
CHECK_SUMMARY_RAN=0

# Count one passing assertion.
ok()   { pass=$((pass + 1)); }
# Count one failing assertion AND print a FAIL diagnostic.
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
# Count one failing assertion WITHOUT printing — for callers that already emitted their own
# (possibly multi-line) diagnostic and only need the failure recorded.
bad_quiet() { fail=$((fail + 1)); }

# eq <actual> <expected> <label> — string equality.
eq()   { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }
# yes <rc> <label> — assert an already-captured status is success. Call as: cmd; yes $? "label"
yes()  { if [ "$1" -eq 0 ]; then ok; else bad "$2 (expected success, rc=$1)"; fi; }
# no <rc> <label> — assert an already-captured status is failure.
no()   { if [ "$1" -ne 0 ]; then ok; else bad "$2 (expected failure, rc=$1)"; fi; }
# has <haystack> <needle> <label> — assert needle is a substring of haystack.
has()  { case "$1" in *"$2"*) ok ;; *) bad "$3: [$1] missing [$2]" ;; esac; }
# hasnt <haystack> <needle> <label> — assert needle is NOT a substring of haystack.
hasnt() { case "$1" in *"$2"*) bad "$3: [$1] unexpectedly contains [$2]" ;; *) ok ;; esac; }

# expect_rejection <label> <assertion-helper> [args…] — run an assertion helper that MUST record a
# failure, and count ONE assertion for whether it did. The rehearsal a guard needs before it can be
# trusted: `base/practices/self-review.md` requires a check to be OBSERVED going red on an input it
# is supposed to reject, and a suite cannot observe that by simply calling the helper — the failure
# it wants to see is the one that would redden the suite.
#
# IT BELONGS IN THIS FAMILY, not at a call site. The header above says callers touch pass/fail only
# through ok / bad / bad_quiet / check_summary, and a helper that snapshots and restores them from
# outside is a second accounting style reaching into this one's private state (review finding).
# Here it IS this family, so the invariant holds by construction.
#
# The subject's own `FAIL:` line is discarded: a deliberate rehearsal printed alongside real
# findings would be read as a real finding — by a person, and by the CI digest that harvests
# `FAIL:` lines (`selfcheck.sh --summarize`).
#
# Arguments: <label> then the command. Globals: pass, fail (restored). Outputs: none on success.
# Returns: 0 always; the verdict is recorded as an assertion.
# THE PREDICATE AND THE ASSERTION ARE SPLIT, and that is what makes the rehearsal testable.
# Folded together, the helper could only be proven by applying it to itself — and self-application
# is circular: an `expect_rejection` that always recorded success would certify itself. (Measured:
# it did. The mutation that broke it left the suite green.) `rejects` is the logic and records
# NOTHING, so a suite can assert on its STATUS in both directions with ordinary ok/bad.
#
# rejects <assertion-helper> [args…] — did the subject record a failure?
# Globals: pass, fail (read and restored, never left modified). Outputs: none — the subject's own
# `FAIL:` line is discarded, or a deliberate rehearsal would be read as a real finding by a person
# and by the CI digest that harvests `FAIL:` lines. Returns: 0 if it rejected, 1 if it accepted.
rejects() {
  local p0="$pass" f0="$fail" fired
  "$@" >/dev/null 2>&1
  fired=$(( fail - f0 ))
  pass="$p0"; fail="$f0"
  [ "$fired" -gt 0 ]
}

# expect_rejection <label> <assertion-helper> [args…] — assert that the subject REJECTS its input.
# The rehearsal `base/practices/self-review.md` asks for: a check is not done until it has been
# observed going red on something it is supposed to reject.
expect_rejection() {
  local label="$1"; shift
  if rejects "$@"; then ok; else bad "$label (it ACCEPTED an input it must reject)"; fi
}

# check_enumerated <label> <item>… — a `mapfile`-built list is USABLE: non-empty, and carrying no
# blank entry. Returns 0 when it is, else records ONE failure and returns 1 (#259).
#
# The reason it is a function and not `[ "${#a[@]}" -gt 0 ]` at each site: that test passes on the
# exact input it most needs to reject. `mapfile -t` over a producer that emitted a single blank
# line yields an array of ONE EMPTY STRING, so the count is 1, the guard reports "not empty", and
# the loop below it iterates once with an empty name — building a fixture out of `/…/scripts/`
# rather than a hook. The advertised zero-coverage guard then goes green for the wrong reason,
# which is the silent-guard shape this repo keeps paying for. Review caught it.
#
# Takes the items as ARGUMENTS rather than an array name on purpose: check-lib.sh is sourced by
# the floor observer and must stay evaluable on bash 3.2 (D35), which has no namerefs.
check_enumerated() {
  local label="$1" x n=0
  shift
  for x in "$@"; do
    if [ -z "$x" ]; then
      bad "$label: enumeration produced a BLANK entry — the producer is broken, not the list empty"
      return 1
    fi
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    bad "$label: enumeration produced NOTHING — everything below it would assert less, silently"
    return 1
  fi
  return 0
}

# check_mutate_line <file> <exact-line> <sed-script> <label> — revert ONE line of a fixture copy to
# a superseded shape, refusing to proceed unless the edit demonstrably applied. Returns 0 when the
# mutation took, else records ONE failure and returns 1.
#
# Requires EXACTLY ONE line of <file> to equal <exact-line> before the edit and NONE after. Both
# halves matter, and both are the difference between a proof and a decoration: without the first, a
# rename in the mutated file turns the mutation into a no-op and the "proof" silently becomes an
# assertion about unmodified code; without the second, a sed that matched but did not substitute
# does exactly the same. Whole-line matching, because these needles are routinely substrings of one
# another's neighbours and only one line is meant to change.
#
# It lives here because TWO suites now drive mutations this way — check-build-atomic.sh, which
# established the discipline, and check-precommit-gate.sh (#299) — and a byte-copied harness is the
# thing this file exists to prevent. `sed` writes to a sibling and is renamed over the target rather
# than using `-i`, whose spelling differs between BSD and GNU.
check_mutate_line() {
  local f="$1" line="$2" script="$3" label="$4" n
  n="$(grep -Fxc -- "$line" "$f")"
  if [ "$n" -ne 1 ]; then
    bad "$label: expected exactly 1 line [$line] in ${f##*/}, found $n — the mutation no longer describes the code it mutates, so it would prove nothing"
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

# --- mutation-harness family (#373) ------------------------------------------------------------
# Inject one defect per row into a COPY of the tree and require the suite under test to come back
# RED. A SIBLING of `check_mutate_line` above, not a replacement: that one applies a `sed` script
# and needs whole-line uniqueness, this one takes an arbitrary literal substring. (D68)

# check_mutate_literal <file> <old> <new> — replace the FIRST occurrence of literal <old> with
# <new>, in place. Returns:
#   0  applied
#   1  the rewrite failed (unreadable file, unwritable dir)
#   2  the literal matched NOTHING — the file is unchanged, so this row tests nothing
#
# `ENVIRON`, not `awk -v`: -v processes backslash escapes, so `\$` and `\n` arrive altered. (D68)
# `index()` sees one record, so a literal spanning two source lines always returns 2.
# Sibling-then-rename, not `sed -i` (BSD/GNU differ), so a failed rewrite cannot half-write <file>.
check_mutate_literal() {
  local f="$1" tmp="$1.adb-mut"
  ADB_MUT_OLD="$2" ADB_MUT_NEW="$3" awk '
    BEGIN { old = ENVIRON["ADB_MUT_OLD"]; new = ENVIRON["ADB_MUT_NEW"] }
    !hit { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); hit = 1 } }
    { print }
  ' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 2; fi
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# check_mut <name> <old-literal> <new-literal> <witness> — append one table row. Fixed strings,
# never regexes. The witness is the assertion label (or a distinctive fragment) the child must fail
# on, since red for the wrong reason is not evidence (#213's `fires:<witness>` contract).
CHECK_MUT_NAMES=(); CHECK_MUT_OLD=(); CHECK_MUT_NEW=(); CHECK_MUT_WIT=()
check_mut() {
  CHECK_MUT_NAMES+=("$1"); CHECK_MUT_OLD+=("$2"); CHECK_MUT_NEW+=("$3"); CHECK_MUT_WIT+=("$4")
}

# check_mut_reset — empty the table, for a suite that runs `check_mutation_pool` more than once.
# A second pool call is how a suite whose witnesses live in TWO files covers both, since a pool
# builds ONE target path for every row it runs; without this the first table's rows would be
# re-run against the second target and scored "did not apply". It lives here, beside the arrays it
# clears, so a caller neither reaches into check-lib's state nor carries a `disable=SC2034` for
# assignments ShellCheck cannot see used across the source boundary.
check_mut_reset() {
  CHECK_MUT_NAMES=(); CHECK_MUT_OLD=(); CHECK_MUT_NEW=(); CHECK_MUT_WIT=()
}

# _check_mut_witness <output> <witness> — true when some line of <output> begins with `FAIL: ` and
# carries <witness>. Per LINE, so a mid-label witness cannot match a passing assertion's echo.
# `case` over a here-string, never `printf | grep -q`: pipefail promotes grep's early-exit SIGPIPE.
# `*"$2"*` is quoted, so the witness matches literally — three live witnesses carry glob bytes. (D68)
_check_mut_witness() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "FAIL: "*) case "$line" in *"$2"*) return 0 ;; esac ;;
    esac
  done <<< "$1"
  return 1
}

# _check_mut_one <index> <workdir> <prepare-fn> <run-fn> — one row, start to verdict. Writes
# `<verdict>|<why>` to `<workdir>/mut-<i>/verdict`: it runs in a background subshell, where an
# incremented counter would die with it (#259). Its own status is always 0 — the pool reaps exactly
# one job per `wait -n`, so a non-zero worker would miscount the pool. (D68)
_check_mut_one() {   # <index> <workdir> <prepare-fn> <run-fn>
  local i="$1" copy="$2/mut-$1" prep="$3" run="$4" tgt out src rc
  if ! tgt="$("$prep" "$copy")" || [ -z "$tgt" ]; then
    printf 'bad|could not build the tree copy\n' > "$copy/verdict" 2>/dev/null; return 0
  fi
  check_mutate_literal "$tgt" "${CHECK_MUT_OLD[$i]}" "${CHECK_MUT_NEW[$i]}"; rc=$?
  case "$rc" in
    0) ;;
    2) printf 'bad|the injection did not apply — this row tests NOTHING\n' > "$copy/verdict"; return 0 ;;
    *) printf 'bad|the rewrite failed\n' > "$copy/verdict"; return 0 ;;
  esac
  # The status AND the witness: matching printed text alone accepts a child that prints the expected
  # line and then exits 0. Exactly 1 is a failed assertion; anything else is the suite dying. (D68)
  out="$("$run" "$copy" 2>&1)"; src=$?
  _check_mut_score "$copy/verdict" "$out" "$src" "${CHECK_MUT_WIT[$i]}"
  return 0
}

# _check_mut_score <verdict-file> <output> <status> <witness> — the ONE verdict taxonomy, shared by
# both pools. Status exactly 1 AND a `FAIL:` line carrying the witness is the only green-for-the-row
# answer; everything else is named. (D68)
_check_mut_score() {
  local vf="$1" out="$2" src="$3" wit="$4"
  case "$src" in
    1)
      if _check_mut_witness "$out" "$wit"; then
        printf 'ok|applied\n' > "$vf"
      else
        case "$out" in
          *"FAIL:"*) printf 'bad|went red, but NOT on its witness [%s] — caught by accident, not by the assertion that claims to cover it\n' \
                       "$wit" > "$vf" ;;
          *)         printf 'bad|exited 1 with no FAIL: line at all — it aborted, it did not fail an assertion\n' > "$vf" ;;
        esac
      fi ;;
    0) printf 'bad|stayed GREEN (exit 0) — nothing here can detect this defect\n' > "$vf" ;;
    *) printf 'bad|exited %s, not 1 — the suite ABORTED rather than failing its assertion\n' "$src" > "$vf" ;;
  esac
}

# check_mutation_pool <label> <workdir> <prepare-fn> <run-fn> <pool-cap> — run every table row
# through a bounded pool, scoring into family 2's counters. Width from `adb_pool_size`
# (min(cpu, cap)); the cap is a parameter because the two adopt suites differ deliberately (D66).
# The parent scores every index and asserts rows-scored == table size (D68). Callbacks:
#   <prepare-fn> <copy-dir>  build the tree copy; PRINT the path to mutate, nothing else. Non-zero
#                            or empty stdout fails that row.
#   <run-fn>     <copy-dir>  run the suite in <copy-dir>. Its output AND exit status are the verdict.
check_mutation_pool() {
  local label="$1" wd="$2" prep="$3" run="$4" cap="$5"
  local n i pool running=0 applied=0 red=0 scored=0 verdict why
  n="${#CHECK_MUT_NAMES[@]}"
  if [ "$n" -eq 0 ]; then
    bad "$label --mutation: the mutation table is EMPTY — this harness proves nothing"
    return 1
  fi
  if ! command -v adb_pool_size >/dev/null 2>&1; then
    bad "$label --mutation: adb_pool_size is unavailable — source scripts/lib/common.sh before check-lib.sh"
    return 1
  fi
  pool="$(adb_pool_size "$cap")"

  for (( i = 0; i < n; i++ )); do
    mkdir -p "$wd/mut-$i"
    _check_mut_one "$i" "$wd" "$prep" "$run" &
    running=$((running + 1))
    # `wait -n` alone: a `|| wait` fallback drains every child while decrementing once, degrading
    # the pool to serial silently. `_check_mut_one` always returns 0, so nothing needs it. (D68)
    if [ "$running" -ge "$pool" ]; then wait -n; running=$((running - 1)); fi
  done
  wait

  for (( i = 0; i < n; i++ )); do
    scored=$((scored + 1))
    if [ ! -f "$wd/mut-$i/verdict" ]; then
      bad "mutation '${CHECK_MUT_NAMES[$i]}': produced NO verdict — its worker died without reporting"
      continue
    fi
    IFS='|' read -r verdict why < "$wd/mut-$i/verdict"
    if [ "$verdict" = ok ]; then
      ok; red=$((red + 1)); applied=$((applied + 1))
    else
      bad "mutation '${CHECK_MUT_NAMES[$i]}': $why"
      # `applied` counts rows whose defect reached the code; a row that never got that far tested
      # nothing at all, which is worse than a guard that missed one.
      case "$why" in
        *"did not apply"*|*"could not build"*|*"rewrite failed"*) : ;;
        *) applied=$((applied + 1)) ;;
      esac
    fi
  done
  if [ "$scored" -ne "$n" ]; then
    bad "$label --mutation: scored $scored of $n row(s) — the harness skipped rows and would have reported on none of them"
  fi
  # SAY THE WIDTH IT ACTUALLY USED. A pool that degrades to one finishes with the same counts and
  # the same verdict as a healthy one — the only difference is how long it took, which nothing reads.
  printf '\n%s --mutation: %d/%d mutation(s) applied, %d observed RED on their own witness (pool=%s)\n' \
    "$label" "$applied" "$n" "$red" "$pool"
  [ "$applied" -eq "$n" ] || bad "$label --mutation: only $applied of $n mutations actually applied — the rest tested nothing"
}

# --- blocks and per-test mutation rows (#468) --------------------------------------------------
# A suite that declares BLOCKS lets a mutant run only the block its witness lives in, plus the blocks
# that one declares it needs, instead of the whole suite — the technique Stryker calls `perTest`.
# A block is written, at the start of a line, exactly as
#
#     if check_block <id> [<dep-id>...]; then
#       ...
#     fi
#
# and the last block is followed, at the start of a line, by `check_blocks_done`. That terminator is
# what bounds the last block's source: a suite's own sections hold top-level `if … fi` of their own, so
# no `fi` can mark where a block ends. `check_blocks_init <suite-file>` reads those lines from the suite's own SOURCE before any block
# runs, which is what lets a selected block's dependency closure be known when the earlier blocks are
# reached. Ids are [a-z0-9-] and unique; a dependency must be declared earlier in the file.
#   ADB_CHECK_BLOCK=<id>[,<id>...] run the prelude, the named block(s) and their dependency closure; skip the rest
#   ADB_CHECK_BLOCK_COUNTS=<file>  append `<id><TAB><assertions>` for every block that ran
# A malformed, duplicate, out-of-order or unknown declaration exits 2 — never 1, which is a failed
# assertion, and never 0. Declared dependencies are TRUSTED ONLY ONCE PROVEN: `check_mutation_rows`
# requires each selected block, unmutated, to run exactly the assertions it runs in a full pass.

CHECK_BLOCK_IDS=(); CHECK_BLOCK_DEPS=(); CHECK_BLOCK_LINES=()
CHECK_BLOCK_SEL=""; CHECK_BLOCK_SELSET=" "; CHECK_BLOCK_RUNSET=" "; CHECK_BLOCK_NEXT=0
CHECK_BLOCK_CUR=""; CHECK_BLOCK_CUR_P0=0; CHECK_BLOCK_SEL_N=0; CHECK_BLOCK_ERR=""
CHECK_PB_IDS=(); CHECK_PB_DEPS=(); CHECK_PB_LINES=(); CHECK_PB_END=0

# _check_blocks_parse <suite-file> — fill CHECK_PB_IDS / CHECK_PB_DEPS / CHECK_PB_LINES from the
# declarations. Returns 0, or 2 with the first problem in CHECK_BLOCK_ERR. A declaration spelled any
# other way (indented, trailing text) is refused rather than skipped: an unscanned block could never
# be selected, and every row naming it would be refused for a reason nobody could see.
_check_blocks_parse() {
  local f="$1" ln=0 line rest id dep i known
  local -a parts
  CHECK_PB_IDS=(); CHECK_PB_DEPS=(); CHECK_PB_LINES=(); CHECK_PB_END=0; CHECK_BLOCK_ERR=""
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then CHECK_BLOCK_ERR="check-blocks: cannot read $f"; return 2; fi
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in
      "check_blocks_done")
        if [ "$CHECK_PB_END" -ne 0 ]; then CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln repeats check_blocks_done"; return 2; fi
        CHECK_PB_END="$ln"; continue ;;
      "if check_block "*)
        if [ "$CHECK_PB_END" -ne 0 ]; then CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln declares a block after check_blocks_done"; return 2; fi ;;
      [[:space:]]*"if check_block "*)
        CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln declares a block that is not at the start of the line"; return 2 ;;
      *) continue ;;
    esac
    case "$line" in
      *"; then") ;;
      *) CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln is not in the form 'if check_block <id> [<dep>...]; then'"; return 2 ;;
    esac
    rest="${line#if check_block }"; rest="${rest%; then}"
    read -r -a parts <<< "$rest"
    if [ "${#parts[@]}" -eq 0 ]; then CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln names no block id"; return 2; fi
    id="${parts[0]}"
    for dep in "${parts[@]}"; do
      case "$dep" in
        ''|*[!a-z0-9-]*) CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln has an id outside [a-z0-9-]: '$dep'"; return 2 ;;
      esac
    done
    for (( i = 0; i < ${#CHECK_PB_IDS[@]}; i++ )); do
      if [ "${CHECK_PB_IDS[$i]}" = "$id" ]; then
        CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln declares block '$id' twice (first at line ${CHECK_PB_LINES[$i]})"; return 2
      fi
    done
    for (( i = 1; i < ${#parts[@]}; i++ )); do
      known=0
      for dep in ${CHECK_PB_IDS[@]+"${CHECK_PB_IDS[@]}"}; do [ "$dep" = "${parts[$i]}" ] && known=1; done
      if [ "$known" -eq 0 ]; then
        CHECK_BLOCK_ERR="check-blocks: ${f##*/}:$ln block '$id' needs '${parts[$i]}', which is not declared EARLIER"; return 2
      fi
    done
    CHECK_PB_IDS+=("$id"); CHECK_PB_LINES+=("$ln"); CHECK_PB_DEPS+=("${parts[*]:1}")
  done < "$f"
  if [ "${#CHECK_PB_IDS[@]}" -gt 0 ] && [ "$CHECK_PB_END" -eq 0 ]; then
    CHECK_BLOCK_ERR="check-blocks: ${f##*/} declares blocks but no 'check_blocks_done' line after the last one"; return 2
  fi
  return 0
}

# check_blocks_init <suite-file> — scan the declarations and resolve ADB_CHECK_BLOCK. Call once, after
# sourcing this file and before the first block. Exits 2 on any declaration problem or unknown id.
# Globals: CHECK_BLOCK_* (written).
check_blocks_init() {
  local i sel=-1 id dep
  if ! _check_blocks_parse "$1"; then printf '%s\n' "$CHECK_BLOCK_ERR" >&2; exit 2; fi
  CHECK_BLOCK_IDS=(); CHECK_BLOCK_DEPS=(); CHECK_BLOCK_LINES=()
  for (( i = 0; i < ${#CHECK_PB_IDS[@]}; i++ )); do
    CHECK_BLOCK_IDS+=("${CHECK_PB_IDS[$i]}"); CHECK_BLOCK_DEPS+=("${CHECK_PB_DEPS[$i]}"); CHECK_BLOCK_LINES+=("${CHECK_PB_LINES[$i]}")
  done
  CHECK_BLOCK_SEL="${ADB_CHECK_BLOCK:-}"; CHECK_BLOCK_SELSET=" "; CHECK_BLOCK_RUNSET=" "; CHECK_BLOCK_NEXT=0
  CHECK_BLOCK_SEL_N=0
  [ -n "$CHECK_BLOCK_SEL" ] || return 0
  local want found
  case ",$CHECK_BLOCK_SEL," in
    *,,*) printf "check-blocks: ADB_CHECK_BLOCK '%s' has an empty element\n" "$CHECK_BLOCK_SEL" >&2; exit 2 ;;
  esac
  for want in ${CHECK_BLOCK_SEL//,/ }; do
    case "$CHECK_BLOCK_SELSET" in
      *" $want "*) printf "check-blocks: ADB_CHECK_BLOCK names '%s' twice\n" "$want" >&2; exit 2 ;;
    esac
    found=-1
    for (( i = 0; i < ${#CHECK_BLOCK_IDS[@]}; i++ )); do [ "${CHECK_BLOCK_IDS[$i]}" = "$want" ] && found=$i; done
    if [ "$found" -lt 0 ]; then
      printf "check-blocks: ADB_CHECK_BLOCK names '%s', which is not a declared block in %s\n" "$want" "${1##*/}" >&2; exit 2
    fi
    [ "$found" -gt "$sel" ] && sel=$found
    CHECK_BLOCK_SELSET="$CHECK_BLOCK_SELSET$want "
  done
  # Dependencies are always EARLIER, so one pass from the last selected block backwards closes the set.
  CHECK_BLOCK_RUNSET="$CHECK_BLOCK_SELSET"
  for (( i = sel; i >= 0; i-- )); do
    id="${CHECK_BLOCK_IDS[$i]}"
    case "$CHECK_BLOCK_RUNSET" in
      *" $id "*) for dep in ${CHECK_BLOCK_DEPS[$i]}; do
                   case "$CHECK_BLOCK_RUNSET" in *" $dep "*) ;; *) CHECK_BLOCK_RUNSET="$CHECK_BLOCK_RUNSET$dep " ;; esac
                 done ;;
    esac
  done
  return 0
}

# check_block <id> [<dep-id>...] — the condition of a block's `if`. Returns 0 to run the block, 1 to
# skip it. Exits 2 when blocks are reached out of declaration order, which is how a declaration the
# scan did not see — or a block nested inside a conditional — is caught instead of silently skipped.
check_block() {
  local id="$1" idx="$CHECK_BLOCK_NEXT"
  _check_block_close
  if [ "$idx" -ge "${#CHECK_BLOCK_IDS[@]}" ] || [ "${CHECK_BLOCK_IDS[$idx]}" != "$id" ]; then
    printf "check-blocks: block '%s' was reached out of declaration order (expected '%s') — call check_blocks_init, and declare every block at the start of a line\n" \
      "$id" "${CHECK_BLOCK_IDS[$idx]:-none}" >&2
    exit 2
  fi
  CHECK_BLOCK_NEXT=$((idx + 1))
  if [ -n "$CHECK_BLOCK_SEL" ]; then
    case "$CHECK_BLOCK_RUNSET" in *" $id "*) ;; *) return 1 ;; esac
  fi
  CHECK_BLOCK_CUR="$id"; CHECK_BLOCK_CUR_P0=$((pass + fail))
  return 0
}

# check_blocks_done — the line after the last block. Closes its count and requires that every declared
# block was reached, so a suite that stopped early cannot pass as a complete one.
check_blocks_done() {
  _check_block_close
  [ "$CHECK_BLOCK_NEXT" -eq "${#CHECK_BLOCK_IDS[@]}" ] \
    || bad "check-blocks: only $CHECK_BLOCK_NEXT of ${#CHECK_BLOCK_IDS[@]} declared blocks were reached before check_blocks_done"
}

# _check_block_close — attribute the assertions counted since the running block began to it.
_check_block_close() {
  [ -n "$CHECK_BLOCK_CUR" ] || return 0
  local n=$(( pass + fail - CHECK_BLOCK_CUR_P0 ))
  [ -z "${ADB_CHECK_BLOCK_COUNTS:-}" ] || printf '%s\t%s\n' "$CHECK_BLOCK_CUR" "$n" >> "$ADB_CHECK_BLOCK_COUNTS"
  case "$CHECK_BLOCK_SELSET" in *" $CHECK_BLOCK_CUR "*) CHECK_BLOCK_SEL_N=$((CHECK_BLOCK_SEL_N + n)) ;; esac
  CHECK_BLOCK_CUR=""
}

# _check_blocks_finish — called by check_summary. Reports a selection and refuses one that proved
# nothing, and refuses a full run that did not reach every declared block.
_check_blocks_finish() {
  _check_block_close
  [ "${#CHECK_BLOCK_IDS[@]}" -gt 0 ] || return 0
  if [ -n "$CHECK_BLOCK_SEL" ]; then
    printf "check-blocks: ran selected block(s) '%s' with %d dependency block(s); %d assertion(s) in the selection\n" \
      "$CHECK_BLOCK_SEL" "$(( $(printf '%s' "$CHECK_BLOCK_RUNSET" | wc -w) - $(printf '%s' "$CHECK_BLOCK_SELSET" | wc -w) ))" "$CHECK_BLOCK_SEL_N"
    [ "$CHECK_BLOCK_SEL_N" -gt 0 ] \
      || bad "check-blocks: the selection '$CHECK_BLOCK_SEL' ran NO assertions — a selection that proves nothing"
  fi
  [ "$CHECK_BLOCK_NEXT" -eq "${#CHECK_BLOCK_IDS[@]}" ] \
    || bad "check-blocks: only $CHECK_BLOCK_NEXT of ${#CHECK_BLOCK_IDS[@]} declared blocks were reached — the suite ended early"
}

# check_row <name> <target> <block> <old-literal> <new-literal> <witness> — append one PER-TEST row.
# <target> is the file to mutate, relative to the tree root; <block> is the declared block — or a
# comma-separated list of blocks — whose assertions must catch the defect; <witness> is the FAIL: text
# that proves they did. Name several blocks only when the witness text genuinely lives in each. Fixed
# strings.
CHECK_ROW_NAMES=(); CHECK_ROW_TGT=(); CHECK_ROW_BLOCK=(); CHECK_ROW_OLD=(); CHECK_ROW_NEW=(); CHECK_ROW_WIT=()
check_row() {
  CHECK_ROW_NAMES+=("$1"); CHECK_ROW_TGT+=("$2"); CHECK_ROW_BLOCK+=("$3")
  CHECK_ROW_OLD+=("$4"); CHECK_ROW_NEW+=("$5"); CHECK_ROW_WIT+=("$6")
}

# _check_literal_count <file> <literal> — print how many positions <literal> STARTS at in <file>,
# overlapping starts included (`aa` in `aaa` is two), which is what makes "exactly once" mean that a
# first-match rewrite has only one place it could apply. Returns 2 for a missing or unreadable file, 3 when the scan itself failed.
_check_literal_count() {
  [ -f "$1" ] && [ -r "$1" ] || return 2
  ADB_MUT_OLD="$2" awk '
    BEGIN { o = ENVIRON["ADB_MUT_OLD"]; n = 0 }
    { s = $0; while ((i = index(s, o)) > 0) { n++; s = substr(s, i + 1) } }
    END { print n }
  ' "$1" 2>/dev/null || return 3
}

# _check_row_one <index> <workdir> <prepare-fn> <run-fn> <full> — one per-test row, start to verdict.
_check_row_one() {
  local i="$1" copy="$2/row-$1" prep="$3" run="$4" full="$5" root tgt out src cnt rc
  if ! root="$("$prep" "$copy")" || [ -z "$root" ]; then
    printf 'bad|could not build the tree copy\n' > "$copy/verdict" 2>/dev/null; return 0
  fi
  tgt="$root/${CHECK_ROW_TGT[$i]}"
  # CHECKED AGAIN ON THE COPY, immediately before the rewrite: the preflight read the pristine tree,
  # and a prepare step that transforms what it copies must not turn "exactly once" into "first of two".
  cnt="$(_check_literal_count "$tgt" "${CHECK_ROW_OLD[$i]}")"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$cnt" != 1 ]; then
    printf 'bad|the injection did not apply — the copied target holds the literal %s time(s), so this row tests NOTHING\n' "${cnt:-?}" > "$copy/verdict"; return 0
  fi
  check_mutate_literal "$tgt" "${CHECK_ROW_OLD[$i]}" "${CHECK_ROW_NEW[$i]}"; rc=$?
  case "$rc" in
    0) ;;
    2) printf 'bad|the injection did not apply — this row tests NOTHING\n' > "$copy/verdict"; return 0 ;;
    *) printf 'bad|the rewrite failed\n' > "$copy/verdict"; return 0 ;;
  esac
  if [ "$full" -eq 1 ]; then
    out="$(ADB_CHECK_BLOCK="" "$run" "$root" 2>&1)"; src=$?
  else
    out="$(ADB_CHECK_BLOCK="${CHECK_ROW_BLOCK[$i]}" "$run" "$root" 2>&1)"; src=$?
  fi
  _check_mut_score "$copy/verdict" "$out" "$src" "${CHECK_ROW_WIT[$i]}"
  return 0
}

# _check_block_ctl <workdir> <prepare-fn> <run-fn> <block> — prove one selection, unmutated, on its own tree
# copy (a runner may write inside its root, so no two runs share one): it must pass and run exactly the assertions the full control counted for that block. Writes `ok` or `bad|<why>`.
_check_block_ctl() {
  local wd="$1" prep="$2" run="$3" b="$4" key="${4//,/+}" root out src want got
  if ! root="$("$prep" "$wd/ctl-$key")" || [ -z "$root" ]; then
    printf 'bad|its control tree copy could not be built\n' > "$wd/ctl-$key.verdict"; return 0
  fi
  out="$(ADB_CHECK_BLOCK="$b" ADB_CHECK_BLOCK_COUNTS="$wd/ctl-$key.counts" "$run" "$root" 2>&1)"; src=$?
  want="$(awk -F '\t' -v bs=",$b," 'index(bs, "," $1 ",") { s += $2; hit = 1 } END { if (hit) print s }' "$wd/control.counts" 2>/dev/null)"
  got="$(awk -F '\t' -v bs=",$b," 'index(bs, "," $1 ",") { s += $2; hit = 1 } END { if (hit) print s }' "$wd/ctl-$key.counts" 2>/dev/null)"
  if [ "$src" -ne 0 ]; then
    printf 'bad|its unmutated control failed (rc %s) — a dependency is undeclared, or the block is red on its own\n' "$src" > "$wd/ctl-$key.verdict"
  elif [ -z "$want" ] || [ "$want" != "$got" ]; then
    printf 'bad|its unmutated control ran %s assertion(s) where the full suite runs %s — the selection does not reproduce the block\n' "${got:-no}" "${want:-none}" > "$wd/ctl-$key.verdict"
  else
    printf 'ok\n' > "$wd/ctl-$key.verdict"
  fi
  return 0
}

# check_mutation_rows <label> <workdir> <suite-path> <prepare-fn> <run-fn> <pool-cap> — run every
# per-test row through a bounded pool. <suite-path> is the suite's path relative to the tree root.
# Callbacks: <prepare-fn> <copy-dir> builds a tree copy and PRINTS ITS ROOT; <run-fn> <root> runs the
# suite there, and its output and status are the verdict.
#   1. Every row's declaration is checked against the PRISTINE tree before anything is built: target
#      present and readable, literal non-empty, single-line, different from its replacement and
#      present EXACTLY once, block declared, witness present in that block's source. Any failure
#      stops the pool with every problem named.
#   2. One full unmutated run must pass; it records each block's assertion count.
#   3. Each selected block's unmutated control must reproduce that count (skipped in full-suite mode).
#   4. Each row runs only its block and that block's dependencies — or the whole suite when
#      ADB_MUTATION_FULL_SUITE=1, the nightly's mode, which also catches a witness that has drifted.
check_mutation_rows() {
  local label="$1" wd="$2" suite="$3" prep="$4" run="$5" cap="$6"
  local n i j pool running=0 errs=0 cnt rc b bi text wit full=0 root blocks=" " nblocks=0
  local applied=0 red=0 scored=0 verdict why
  n="${#CHECK_ROW_NAMES[@]}"
  if [ "$n" -eq 0 ]; then bad "$label --mutation: the row table is EMPTY — this harness proves nothing"; return 1; fi
  if ! command -v adb_pool_size >/dev/null 2>&1; then
    bad "$label --mutation: adb_pool_size is unavailable — source scripts/lib/common.sh before check-lib.sh"; return 1
  fi
  [ "${ADB_MUTATION_FULL_SUITE:-0}" = 1 ] && full=1
  pool="$(adb_pool_size "$cap")"
  # A FRESH workdir: counts and verdicts are read back by name, so a previous run's files would be scored.
  if [ -e "$wd" ] && [ -n "$(ls -A "$wd" 2>/dev/null)" ]; then
    bad "$label --mutation: workdir '$wd' is not empty — a previous run's counts or verdicts would be scored"; return 1
  fi
  mkdir -p "$wd"

  # 1. declarations, against the pristine tree
  if ! _check_blocks_parse "$ROOT/$suite"; then
    bad "$label --mutation: $CHECK_BLOCK_ERR"; return 1
  fi
  for (( i = 0; i < n; i++ )); do
    local nm="${CHECK_ROW_NAMES[$i]}" tg="${CHECK_ROW_TGT[$i]}" old="${CHECK_ROW_OLD[$i]}"
    wit="${CHECK_ROW_WIT[$i]}"; b="${CHECK_ROW_BLOCK[$i]}"
    if [ -z "$old" ] || [ -z "$wit" ]; then
      bad "row '$nm': its literal or its witness is EMPTY"; errs=$((errs + 1)); continue
    fi
    case "$old" in *$'\n'*) bad "row '$nm': its literal spans lines, and a line-wise rewrite can never apply it"; errs=$((errs + 1)); continue ;; esac
    if [ "$old" = "${CHECK_ROW_NEW[$i]}" ]; then
      bad "row '$nm': its replacement equals its literal — it injects no defect"; errs=$((errs + 1)); continue
    fi
    cnt="$(_check_literal_count "$ROOT/$tg" "$old")"; rc=$?
    case "$rc" in
      0) ;;
      2) bad "row '$nm': target '$tg' is missing or unreadable (witness: $wit)"; errs=$((errs + 1)); continue ;;
      *) bad "row '$nm': target '$tg' could not be scanned (witness: $wit)"; errs=$((errs + 1)); continue ;;
    esac
    if [ "$cnt" -eq 0 ]; then
      bad "row '$nm': its literal is ABSENT from '$tg' — the code moved under it (witness: $wit)"; errs=$((errs + 1)); continue
    elif [ "$cnt" -gt 1 ]; then
      bad "row '$nm': its literal occurs $cnt times in '$tg' — a first-match rewrite could mutate the wrong one (witness: $wit)"; errs=$((errs + 1)); continue
    fi
    local one undeclared="" seen=0
    text=""
    for one in ${b//,/ }; do
      bi=-1
      for (( j = 0; j < ${#CHECK_PB_IDS[@]}; j++ )); do [ "${CHECK_PB_IDS[$j]}" = "$one" ] && bi=$j; done
      if [ "$bi" -lt 0 ]; then undeclared="$one"; break; fi
      if [ $((bi + 1)) -lt "${#CHECK_PB_IDS[@]}" ]; then
        text="$text$(sed -n "${CHECK_PB_LINES[$bi]},$(( CHECK_PB_LINES[bi + 1] - 1 ))p" "$ROOT/$suite")"
      else
        text="$text$(sed -n "${CHECK_PB_LINES[$bi]},$(( CHECK_PB_END - 1 ))p" "$ROOT/$suite")"
      fi
      seen=$((seen + 1))
    done
    if [ -n "$undeclared" ] || [ "$seen" -eq 0 ]; then
      bad "row '$nm': block '${undeclared:-$b}' is not declared in $suite"; errs=$((errs + 1)); continue
    fi
    case "$text" in
      *"$wit"*) ;;
      *) bad "row '$nm': witness '$wit' does not appear in block(s) '$b' — selecting them could never show it"; errs=$((errs + 1)); continue ;;
    esac
    case "$blocks" in *" $b "*) ;; *) blocks="$blocks$b "; nblocks=$((nblocks + 1)) ;; esac
  done
  if [ "$errs" -gt 0 ]; then
    bad "$label --mutation: $errs row declaration(s) are invalid — nothing was built or run"; return 1
  fi

  # 2. one full, unmutated control
  if ! root="$("$prep" "$wd/control")" || [ -z "$root" ]; then
    bad "$label --mutation: the control tree copy could not be built"; return 1
  fi
  : > "$wd/control.counts"
  ADB_CHECK_BLOCK="" ADB_CHECK_BLOCK_COUNTS="$wd/control.counts" "$run" "$root" > "$wd/control.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label --mutation: the UNMUTATED suite failed (rc $rc) — no row can be scored against a red baseline"; return 1
  fi

  # 3. each selected block, unmutated, must reproduce its own count
  if [ "$full" -eq 0 ]; then
    running=0
    for b in $blocks; do
      _check_block_ctl "$wd" "$prep" "$run" "$b" &
      running=$((running + 1))
      if [ "$running" -ge "$pool" ]; then wait -n; running=$((running - 1)); fi
    done
    wait
  fi

  # 4. the rows
  running=0
  for (( i = 0; i < n; i++ )); do
    mkdir -p "$wd/row-$i"
    b="${CHECK_ROW_BLOCK[$i]}"
    if [ "$full" -eq 0 ] && [ "$(cat "$wd/ctl-${b//,/+}.verdict" 2>/dev/null)" != ok ]; then
      printf 'bad|control failed for block %s: %s\n' "$b" "$(cut -d'|' -f2- "$wd/ctl-${b//,/+}.verdict" 2>/dev/null)" > "$wd/row-$i/verdict"
      continue
    fi
    _check_row_one "$i" "$wd" "$prep" "$run" "$full" &
    running=$((running + 1))
    if [ "$running" -ge "$pool" ]; then wait -n; running=$((running - 1)); fi
  done
  wait

  for (( i = 0; i < n; i++ )); do
    scored=$((scored + 1))
    if [ ! -f "$wd/row-$i/verdict" ]; then
      bad "mutation '${CHECK_ROW_NAMES[$i]}': produced NO verdict — its worker died without reporting"; continue
    fi
    IFS='|' read -r verdict why < "$wd/row-$i/verdict"
    if [ "$verdict" = ok ]; then
      ok; red=$((red + 1)); applied=$((applied + 1))
    else
      bad "mutation '${CHECK_ROW_NAMES[$i]}': $why"
      case "$why" in
        *"did not apply"*|*"could not build"*|*"rewrite failed"*|"control failed"*) : ;;
        *) applied=$((applied + 1)) ;;
      esac
    fi
  done
  [ "$scored" -eq "$n" ] || bad "$label --mutation: scored $scored of $n row(s)"
  if [ "$full" -eq 1 ]; then
    printf '\n%s --mutation: %d/%d mutation(s) applied, %d observed RED on their own witness (pool=%s; full suite per mutant)\n' "$label" "$applied" "$n" "$red" "$pool"
  else
    printf '\n%s --mutation: %d/%d mutation(s) applied, %d observed RED on their own witness (pool=%s; per-block, %d block(s) controlled)\n' "$label" "$applied" "$n" "$red" "$pool" "$nblocks"
  fi
  [ "$applied" -eq "$n" ] || bad "$label --mutation: only $applied of $n mutations actually applied — the rest tested nothing"
}

# check_summary <name> — emit the terminal "<name>: N passed, M failed" line, then exit 1 if any
# assertion failed, else print "<name>: PASS". Callers end with this instead of re-reading
# $pass/$fail (which would trip SC2154, since ShellCheck does not follow the sourced file).
check_summary() {
  CHECK_SUMMARY_RAN=1
  _check_blocks_finish
  printf '\n%s: %d passed, %d failed\n' "$1" "$pass" "$fail"
  # ZERO ASSERTIONS IS NOT A PASS (#213). `fail -eq 0` alone reports PASS for a suite that ran
  # nothing at all — a file truncated by a bad merge, an early `exit` or `return`, a case block
  # sliced away by an edit — and it reports it in exactly the words a real pass uses. That is the
  # silent-guard failure this repo keeps paying for, one level up: the suites are what prove the
  # guards can go red, so a suite that quietly stops running is a guard that quietly stops being
  # checked. Every suite here runs dozens of assertions; none can legitimately reach zero.
  if [ "$((pass + fail))" -eq 0 ]; then
    printf '%s: FAIL — zero assertions ran, which is not a pass. The suite executed nothing.\n' "$1" >&2
    exit 1
  fi
  [ "$fail" -eq 0 ] || exit 1
  echo "$1: PASS"
}

# check_exit_guard <name> [cleanup-command] — install an EXIT trap that FAILS CLOSED unless
# check_summary actually ran, then runs <cleanup-command> (typically `rm -rf "$work"`).
#
# The hole it closes: a suite's exit status is its LAST COMMAND's, and the only thing that ever
# consults the `fail` counter is check_summary. Lose that final line — a truncating edit, a
# misplaced `exit 0`, an early `return` — and the suite prints its `FAIL:` diagnostics, exits 0,
# and is reported as PASSING by both selfcheck and CI. The assertions ran and their verdict was
# discarded, which is exactly the silent-guard failure this repo keeps paying for.
#
# It must be INSTALLED per suite rather than armed automatically when this file is sourced,
# because a suite that later installs its own `trap … EXIT` would silently REPLACE ours — a guard
# that goes inert in the one place it is needed. So the cleanup it would have installed is passed
# to this instead, keeping one EXIT trap per suite. Usage, before the first assertion:
#     work="$(mktemp -d)"; check_exit_guard "check-thing" "rm -rf \"$work\""
check_exit_guard() {
  local name="$1" cleanup="${2:-}"
  # Single-quoted so $? is read when the trap FIRES, not when it is installed; $name/$cleanup are
  # interpolated now, which is what makes the message and the cleanup suite-specific.
  # shellcheck disable=SC2064  # deliberate: name/cleanup are expanded at install time
  trap "_check_exit_guard \"$name\" \"\$?\"; ${cleanup:-:}" EXIT
}

# The trap body. Separate so the trap string stays short and quoting stays legible.
_check_exit_guard() {
  [ "$CHECK_SUMMARY_RAN" -eq 1 ] && return 0
  printf '%s: FAIL — the suite ended without running check_summary, so its assertions were never\n' "$1" >&2
  printf '%s:        counted. Exiting non-zero: a suite that skips its own verdict must never be\n' "$1" >&2
  printf '%s:        reported as passing (exit status was %s).\n' "$1" "$2" >&2
  # `exit` inside an EXIT trap sets the final status without re-entering the trap.
  exit 1
}

# --- git fixture helpers (identity wrapper + local+bare-origin pair) --------------------------
# The check-*.sh tests each hand-rolled the same "git with a throwaway identity" wrapper and the
# same "bare origin + local repo wired to it" scaffold. Centralize only the BOILERPLATE; each
# test keeps its own topology (branch names, origin/HEAD form, merge shape, push sequence).

# check_copy_worktree <src> <dest> — copy a whole working tree (dotfiles included) into <dest>,
# creating it, then drop the copied `.git`. The ONE home for the throwaway-tree-copy move, now that
# three suites need it: the installer fail-loud test, the fact-drift mutation mode, and its guard
# suite. A fourth open-coded copy is how the "faithful copier" details drift — `cp -R .` from
# inside <src> is deliberate (it takes the CONTENTS, dotfiles included, and preserves symlinks and
# modes on both BSD and GNU), and `git ls-files | cp` is deliberately NOT used: it needs `-z`,
# per-file `mkdir -p`, and a policy for tracked-but-deleted paths, and it silently misses anything
# uncommitted — which is the whole reason these suites copy the tree instead of cloning HEAD.
#
# Dropping `.git` is for speed (this repo's is ~27 MB), and it means the copy is NOT a git repo:
# code under test that shells out to git must tolerate that. Returns non-zero WITHOUT exiting so a
# `set -u` caller can guard it.
check_copy_worktree() {
  mkdir -p "$2" || return 1
  ( cd "$1" && cp -R . "$2" ) || return 1
  rm -rf "$2/.git"
}

# check_copy_subtrees <src> <dst> <dir>… — the same throwaway copy, restricted to named top-level
# directories. Use it when a suite's whole mutation surface is a known set of subtrees; use
# check_copy_worktree when it is not, or when the code under test needs the repo's root files.
#
# THE COST IS THE REASON, and it is measured rather than assumed. `check_copy_worktree` copies the
# repo CONTENTS — including `.git`, which on this repo is ~66 MB — and then deletes it. One copy is
# unnoticeable; a mutation harness doing it a dozen times spends most of its wall clock in the
# kernel moving a directory it is about to throw away. `check-tmp-paths.sh` ran 63s that way and
# 6s copying only its four scanned roots (4.4 MB), which is the same fixture for its purposes.
#
# Same faithful-copier details as above (`cp -R` of the CONTENTS, so dotfiles, symlinks and modes
# survive), and the same contract: the result is NOT a git repo, and a failure returns non-zero
# without exiting. A named directory that does not exist in <src> is skipped, not an error — a
# suite may legitimately list a root that only some trees carry.
check_copy_subtrees() {
  local src="$1" dst="$2" d
  shift 2
  [ "$#" -gt 0 ] || return 1
  mkdir -p "$dst" || return 1
  for d in "$@"; do
    [ -d "$src/$d" ] || continue
    mkdir -p "$dst/$d" || return 1
    ( cd "$src/$d" && cp -R . "$dst/$d" ) || return 1
  done
}

# check_git <dir> <git-args...> — run git in <dir> with a fixed throwaway identity and signing
# OFF, so a contributor whose global config sets commit.gpgsign=true still gets clean, unsigned
# fixture commits. Use for EVERY commit-producing fixture git call (this is what closes the
# signing gap the per-file wrappers left in some tests).
check_git() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# check_wf_snippet <workflow-file> <name> — print the fenced bash between `# ADB-SNIPPET: <name>`
# and the closing fence. The ONE home for the marker/closing-fence contract: three suites execute
# documented workflow snippets (check-roadmap.sh, check-roadmap-e2e.sh, check-cleanup.sh), and three
# copies of this awk meant a change to the marker convention had to be found in three places with
# nothing checking they agreed. Prints nothing when the marker is absent, so callers guard on empty.
check_wf_snippet() {
  awk -v want="$2" '
    $0 ~ ("^[[:space:]]*# ADB-SNIPPET: " want "$") { inb = 1; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { exit }
    inb { print }
  ' "$1"
}

# check_actions_slug — set ACTIONS_SLUG from its one home, `adb_actions_app_slug` in common.sh.
# The ONE home for how a suite reaches into common.sh for that value: three suites build check-run
# fixtures (check-roadmap.sh, check-roadmap-e2e.sh, check-repo-settings.sh), and each hard-coding
# the slug is exactly what let #179 ship — the fixtures asserted the code's belief rather than the
# API's behavior, so a value GitHub never returns stayed green in every suite.
#
# Sources in a SUBSHELL so the suite does not inherit common.sh's other definitions, and FATALs on
# an empty result: a silently-empty slug would make every fixture default to `app.slug: ""`, which
# is the unknown-provenance shape — the suites would then pass while testing the wrong thing.
# The exit must live here rather than inside a command substitution, or it would only kill the
# subshell and the suite would carry on with an empty value.
check_actions_slug() {
  ACTIONS_SLUG="$(. scripts/lib/common.sh >/dev/null 2>&1; adb_actions_app_slug)"
  [ -n "$ACTIONS_SLUG" ] || {
    echo "${CHECK_LABEL:-check}: FATAL — adb_actions_app_slug is unavailable or empty" >&2; exit 1; }
}

# canon <dir> — the physical (symlink-resolved) absolute path of <dir>, mirroring what code that
# uses `git rev-parse --show-toplevel` / `pwd -P` compares against. On macOS a mktemp dir is
# /var/… while its physical form is /private/var/…; without canonicalizing, a naive path assertion
# would flap. Used by repo-shape tests (adb_repo_shape / bin/agent-init). Prints nothing if <dir>
# is unreadable. Usage: expected="$(canon "$fixture")"
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# check_make_repo_pair <local_dir> <bare_dir> — init a bare origin, init a local repo (its dir
# may already contain files), stamp the local's throwaway identity + signing-off config, and
# wire `origin` to the bare repo. It deliberately does NOT commit, branch, push, or set
# HEAD/symref — those differ per test and stay caller-owned (a caller then commits via check_git
# or its own subshell git, whose identity the config above already covers). Returns non-zero
# WITHOUT exiting on any failure, so a `set -u` caller can guard it:
#   check_make_repo_pair "$local" "$bare" || { bad "fixture init failed"; }
check_make_repo_pair() {
  git init -q --bare "$2" || return 1
  git init -q "$1" || return 1
  git -C "$1" config user.email t@t || return 1
  git -C "$1" config user.name  t   || return 1
  git -C "$1" config commit.gpgsign false || return 1
  git -C "$1" remote add origin "$2" || return 1
}

# check_make_stub_repo <dir> <origin-url> — create <dir>, init it, stamp the throwaway identity +
# signing-off config, and point `origin` at <origin-url>. Returns non-zero WITHOUT exiting.
# The sibling of check_make_repo_pair: no bare repo to push to, only an origin URL.
# The remote is load-bearing (#173) — the code under test anchors every `gh` read to the checkout's
# git origin, so the slug must agree with the PR fixture's `base.repo.full_name`.
check_make_stub_repo() {
  mkdir -p "$1" || return 1
  git init -q "$1" || return 1
  git -C "$1" config user.email t@t || return 1
  git -C "$1" config user.name  t   || return 1
  git -C "$1" config commit.gpgsign false || return 1
  git -C "$1" remote add origin "$2" || return 1
}

# check_write_stub <path> — read a stub program from STDIN, write it to <path> (creating its
# parent) and make it executable. Returns non-zero WITHOUT exiting. A stub left non-executable is
# never used, and the suite then silently exercises the real command. Usage:
#         check_write_stub "$SBIN/gh" <<'STUB'
#         #!/usr/bin/env bash
#         …
#         STUB
check_write_stub() {
  # `${1%/*}` is the whole path when it carries no slash, so a bare name would `mkdir` the file.
  case "$1" in */*) mkdir -p "${1%/*}" || return 1 ;; esac
  cat > "$1" || return 1
  chmod +x "$1" || return 1
}

# --- PR reviewer-signal payload builders (#167) ------------------------------------------------
# The four GitHub response shapes the two PR-guard suites stub. They live here rather than in each
# suite because BOTH now exercise ONE shared classifier (`adb_reviewer_evidence` /
# `adb_reviewer_classes` / `adb_head_anchor` in common.sh): with a copy per suite, a change to the
# record shape has no single place to be made, and one suite can stay green against a payload the
# other no longer produces. That is the same two-copies-diverge failure #167 and #173 were filed to
# fix — which makes duplicating it in the tests of the fix a poor trade.
#
# Each takes the destination path first, so a suite can write a default fixture, a page-two fixture
# or a per-poll fixture with the same builder. What stays per-suite is everything genuinely local:
# the `gh` stub's routing and knobs, the PR object (whose fields differ — pr-watch needs state and
# merged_at), the poll counter, and the timestamp constants each suite reads its own scenarios by.

# check_pr_reviews_json <out> <login> <state> <sha> [...] — one review object per triple.
check_pr_reviews_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg st "$2" --arg sha "$3" \
            '. + [{user:{login:$l,type:"Bot"},state:$st,commit_id:$sha}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_comments_json <out> <login> <created_at> [...] — one ISSUE COMMENT per pair. This is the
# Codex connector's "task mode" output: a single comment, no review object, no inline threads.
check_pr_comments_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 2 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg at "$2" \
            '. + [{user:{login:$l},created_at:$at,body:"### Summary"}]')"
    shift 2
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_reactions_json <out> <login> <content> <created_at> [...] — one reaction per triple.
# NOTE the reactions endpoint reports `type: "User"` for the Codex connector while reviews report
# `type: "Bot"` for the same App, which is why no builder here sets a discriminating type on it.
check_pr_reactions_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg c "$2" --arg at "$3" \
            '. + [{user:{login:$l},content:$c,created_at:$at}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_activity_json <out> <after-sha> <ref> <timestamp> [...] — one repository-activity record
# per triple, in the newest-first order the API returns them. This is the SERVER-ASSIGNED anchor
# #175/D19 replaced the client-supplied committer date with, so its shape is the one most worth
# having in a single place: `adb_head_anchor` selects on `.after`, `.ref` and `.timestamp`.
check_pr_activity_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg sha "$1" --arg ref "$2" --arg at "$3" \
            '. + [{activity_type:"push", ref:$ref, before:"0000000000000000000000000000000000000000",
                   after:$sha, timestamp:$at}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_json <out> [--sha X] [--state X] [--merged-at X] [--base-slug X] [--head-slug X]
#               [--head-ref X] — the PULL-REQUEST OBJECT, the fifth shape both suites stub.
#
# Named flags, never positional — a positional superset mis-shifts calls silently (D68). Last wins.
# Empty is meaningful: `--head-slug ""` renders `head.repo` null, `--merged-at ""` likewise.
# Every field defaults to empty (the fixture constants live in the suites); a bad flag fails loudly.
check_pr_json() {
  local out="$1"; shift
  local sha="" state="open" merged="" bslug="" hslug="" href=""
  while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then bad "check_pr_json: flag '$1' has no value"; return 1; fi
    case "$1" in
      --sha)       sha="$2" ;;
      --state)     state="$2" ;;
      --merged-at) merged="$2" ;;
      --base-slug) bslug="$2" ;;
      --head-slug) hslug="$2" ;;
      --head-ref)  href="$2" ;;
      *) bad "check_pr_json: unknown flag '$1'"; return 1 ;;
    esac
    shift 2
  done
  jq -n --arg sha "$sha" --arg st "$state" --arg m "$merged" --arg slug "$bslug" \
        --arg hslug "$hslug" --arg href "$href" \
    '{head:{sha:$sha, ref:$href, repo:(if $hslug == "" then null else {full_name:$hslug} end)},
      state:$st, merged_at:(if $m == "" then null else $m end),
      base:{repo:{full_name:$slug}}}' > "$out"
}

# check_declare_bots <repo-dir> <toml-array> — declare the reviewer set the guards read, e.g.
#   check_declare_bots "$REPO" '["chatgpt-codex-connector"]'
# `[]` (arm) and NO FILE (fail closed) are different answers; their collapse IS #134.
check_declare_bots() { printf '%s\n' '[reviewers]' "bots = $2" > "$1/agents.toml"; }

# check_undeclare_bots <repo-dir> <fake-home> — the UNDECLARED arm of that tri-state. Both homes,
# because the manifest resolves project-first then user-level.
check_undeclare_bots() { rm -f "$1/agents.toml" "$2/.config/ai-dev-baseline/agents.toml"; }

# check_pr_called <calls-file> <substring> — did any recorded `gh api` call address <substring>?
# Both suites record every call so they can prove NEGATIVES: that the head-commit endpoint is never
# read (the client-supplied date #175 removed), and that the ref-activity read is not paid for when
# no date-scoped signal needs dating.
check_pr_called() { [ -f "$1" ] && grep -q -- "$2" "$1"; }

# check_pr_graphql_assembler <path> — write the jq program that turns the four REST-shaped fixtures
# above into the ONE GraphQL document `adb_pr_snapshot` reads (#174).
#
# WHY A PROGRAM FILE RATHER THAN A SHELL FUNCTION: both suites' `gh` stubs need it, and a stub is a
# separate executable that cannot call back into this library. Writing it to the fixture directory
# once gives the shape a single home while keeping the stubs standalone.
#
# THE ASSEMBLER IS THE INVERSE OF THE ADAPTER, so the suites exercise the real normalization rather
# than a parallel implementation of it. Two mappings are load-bearing:
#
#   * `__typename` DEFAULTS TO "User", and is "Bot" only when a fixture asks (`--bot-typename`).
#     This is the difference between preserving ~170 existing assertions and silently rewriting
#     them. The adapter appends `[bot]` to a Bot-typed login, so blanket-typing every fixture actor
#     as Bot would turn the fixture login `chatgpt-codex-connector` into
#     `chatgpt-codex-connector[bot]` — which flips check-pr-review.sh's #176 fail-open test (a HUMAN
#     login must NOT satisfy a `foo[bot]` declaration) from a refusal into a match. The reconstruction
#     gets its own explicit fixtures instead, which is what a new behaviour is owed.
#   * `totalCount` DEFAULTS TO THE NODE COUNT, so nothing looks truncated unless a scenario says so.
#     A scenario asks for truncation by writing `<surface>-total.txt` with a larger number.
check_pr_graphql_assembler() {
  cat > "$1" <<'JQPROG'
# $pr/$reviews/$comments/$reactions arrive as --argjson; $rvtotal/$cmtotal/$rxtotal as --arg.
def actor($login; $isbot):
  if $isbot then {login:($login | sub("\\[bot\\]$";"")), __typename:"Bot"}
  else {login:$login, __typename:"User"} end;
def tc($given; $nodes): if ($given|length) > 0 then ($given|tonumber) else ($nodes|length) end;
{ data: { repository: {
    pullRequest: (
      if $pr == null then null else {
        state: (if ($pr.state // "open") == "open" then "OPEN"
                elif (($pr.merged_at // null) != null) then "MERGED" else "CLOSED" end),
        merged: (($pr.merged_at // null) != null),
        mergedAt: ($pr.merged_at // null),
        headRefOid: ($pr.head.sha // null),
        headRefName: ($pr.head.ref // null),
        baseRepository: (if ($pr.base.repo.full_name // null) == null then null
                         else {nameWithOwner: $pr.base.repo.full_name} end),
        headRepository: (if ($pr.head.repo // null) == null then null
                         else {nameWithOwner: ($pr.head.repo.full_name // null)} end),
        reviews: { totalCount: tc($rvtotal; $reviews),
                   nodes: [ $reviews[] | {author: actor(.user.login; (.gqlbot // false)),
                                          state: .state,
                                          commit: (if (.commit_id // null) == null then null
                                                   else {oid: .commit_id} end)} ] },
        comments: { totalCount: tc($cmtotal; $comments),
                    nodes: [ $comments[] | {author: actor(.user.login; (.gqlbot // false)),
                                            createdAt: .created_at} ] },
        reactions: { totalCount: tc($rxtotal; ($reactions | map(select(.content == "+1")))),
                     nodes: [ $reactions[] | select(.content == "+1")
                              | {createdAt: .created_at,
                                 user: actor(.user.login; (.gqlbot // false))} ] }
      } end ) } } }
JQPROG
}

# check_pr_graphql_stub_body — the shell the `gh` stubs run for a `gh api graphql` call. Emitted as
# a string so each suite can drop it into its own stub without a second copy of the wiring.
#
# Reads the same `$S/*.json` fixtures the REST arms read, so a scenario that writes `review_fx …`
# needs no change: only the TRANSPORT moved. `STUB_GRAPHQL_RAW` overrides the whole body (for the
# malformed/partial-error cases), and `STUB_GRAPHQL_FAIL` makes the call fail outright.
#
# `$S/slow-<n>` MAKES POLL <n> COST THAT MANY SECONDS (#394) — the one knob here that is a fixture
# rather than a response. A `wait` bounds itself with real elapsed time, so a case whose oracle is
# something only a LATER poll can print is racing its own deadline: on a loaded runner the first
# poll can outlive the bound and the watch ends before the fixture ever changes. This makes that
# latency injectable, so "a slow poll no longer breaks this case" is a test rather than an anecdote.
# `/bin/sleep`, NOT `sleep`: the suites shim `sleep` on PATH to record naps, and a nap this stub
# took would be counted as one the watcher requested.
check_pr_graphql_stub_body() {
  cat <<'BODY'
  if [ "${STUB_GRAPHQL_FAIL:-0}" = "1" ]; then exit 1; fi
  if [ "${STUB_EMPTY_GRAPHQL:-0}" = "1" ]; then exit 0; fi
  if [ -f "$S/graphql-raw.json" ]; then cat "$S/graphql-raw.json"; exit "${STUB_GRAPHQL_RC:-0}"; fi
  _prf="$S/pr.json"; _n=0
  [ -f "$S/polls" ] && _n="$(cat "$S/polls")"
  _n=$(( _n + 1 )); printf '%s' "$_n" > "$S/polls"
  [ -f "$S/slow-$_n" ] && /bin/sleep "$(cat "$S/slow-$_n")"
  [ -f "$S/pr.$_n.json" ] && _prf="$S/pr.$_n.json"
  _fx() { if [ -f "$S/$1.$_n.json" ]; then printf '%s' "$S/$1.$_n.json"; else printf '%s' "$S/$1.json"; fi; }
  _rd() { if [ -f "$1" ]; then cat "$1"; else printf '[]'; fi; }
  _tot() { [ -f "$S/$1-total.txt" ] && cat "$S/$1-total.txt"; }
  jq -n --argjson pr "$(_rd "$_prf")" \
        --argjson reviews "$(_rd "$(_fx reviews)")" \
        --argjson comments "$(_rd "$(_fx comments)")" \
        --argjson reactions "$(_rd "$(_fx reactions)")" \
        --arg rvtotal "$(_tot reviews)" --arg cmtotal "$(_tot comments)" \
        --arg rxtotal "$(_tot reactions)" \
        -f "$S/assemble.jq"
  exit 0
BODY
}

# check_pr_receipts_stub_body — the `request-review` receipt read (#169). A DIFFERENT query over the
# same PR, selecting comment BODIES, so it needs its own assembly; `$S/receipts.json` is the
# fixture, an array of `{created_at, body}`.
check_pr_receipts_stub_body() {
  cat <<'BODY'
  # The SAME failure knobs as the snapshot arm: an unreadable read is an unreadable read whichever
  # query asked, and `request-review` must refuse to post on one — an unprovable receipt read as
  # "not yet asked" re-posts on every poll, which is the one way this mutation becomes spam.
  if [ "${STUB_GRAPHQL_FAIL:-0}" = "1" ]; then exit 1; fi
  if [ "${STUB_EMPTY_GRAPHQL:-0}" = "1" ]; then exit 0; fi
  # A raw override for shapes the assembler below would never build — a malformed or absent
  # comments connection. Spliced INTO a well-formed pullRequest so the scenario under test is the
  # connection, not the envelope.
  if [ -f "$S/receipts-raw.json" ]; then
    jq -n --argjson pr "$(cat "$S/pr.json")" --argjson cm "$(cat "$S/receipts-raw.json")" '
      { data: { repository: { pullRequest: (
          { state: (if ($pr.state // "open") == "open" then "OPEN" else "CLOSED" end),
            headRefOid: ($pr.head.sha // null), headRefName: ($pr.head.ref // null),
            baseRepository: {nameWithOwner: ($pr.base.repo.full_name // null)},
            headRepository: {nameWithOwner: ($pr.head.repo.full_name // null)} } + $cm ) } } }'
    exit 0
  fi
  # PER-CALL FIXTURE ROTATION. `request-review` reads this endpoint TWICE — once to find the
  # receipt, and once immediately before the POST to re-verify the state that gates it. A scenario
  # that wants the PR to change UNDER the caller writes `rpr.<n>.json` for the nth call; without
  # this the re-verify can only ever see what the first read saw, and a test for it would pass
  # whether or not the re-verify exists (observed: it did).
  _rn=0; [ -f "$S/rpolls" ] && _rn="$(cat "$S/rpolls")"
  _rn=$(( _rn + 1 )); printf '%s' "$_rn" > "$S/rpolls"
  _prf="$S/pr.json"; [ -f "$S/rpr.$_rn.json" ] && _prf="$S/rpr.$_rn.json"
  _rd() { if [ -f "$1" ]; then cat "$1"; else printf '[]'; fi; }
  jq -n --argjson pr "$(_rd "$_prf")" \
        --argjson rc "$(_rd "$S/receipts.json")" \
        --arg total "$( [ -f "$S/receipts-total.txt" ] && cat "$S/receipts-total.txt" )" '
    { data: { repository: { pullRequest: {
        state: (if ($pr.state // "open") == "open" then "OPEN"
                elif (($pr.merged_at // null) != null) then "MERGED" else "CLOSED" end),
        headRefOid: ($pr.head.sha // null),
        headRefName: ($pr.head.ref // null),
        baseRepository: (if ($pr.base.repo.full_name // null) == null then null
                         else {nameWithOwner: $pr.base.repo.full_name} end),
        headRepository: (if ($pr.head.repo // null) == null then null
                         else {nameWithOwner: ($pr.head.repo.full_name // null)} end),
        comments: { totalCount: (if ($total|length) > 0 then ($total|tonumber) else ($rc|length) end),
                    nodes: [ $rc[] | {createdAt: .created_at, body: .body} ] } } } } }'
  exit 0
BODY
}

# check_pr_mark_bot <fixture> — flag every actor in a REST-shaped fixture as one GraphQL will
# report with `__typename: "Bot"` and the BARE login. This is how a scenario opts INTO the
# suffix-reconstruction path; without it the assembler types actors as `User` and passes the login
# through, which is what keeps every pre-#174 assertion meaning what it meant.
check_pr_mark_bot() {
  local t; t="$(mktemp)"
  jq -c 'map(. + {gqlbot:true})' "$1" > "$t" && mv "$t" "$1"
}

# check_pr_receipts_json <out> <created_at> <body> [...] — one PR issue comment per pair, for the
# receipt read above.
check_pr_receipts_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 2 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg at "$1" --arg b "$2" '. + [{created_at:$at, body:$b}]')"
    shift 2
  done
  printf '%s\n' "$acc" > "$out"
}
