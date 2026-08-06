#!/usr/bin/env bash
# ai-dev-baseline — tests for the gate detector + model (scripts/lib/project-gates.sh).
#
# Covers issues #5 (jq-based package.json parse, single-primary detection) and #19 (open
# set of gates, per-gate N/A, per-gate path scope). Fixtures are self-contained temp dirs
# (no network, no installed-toolchain dependence except the jq/npm-guarded blocks, which
# SKIP when the tool is absent — mirroring selfcheck's shellcheck-skip pattern).
#
# Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks the whole scripts/lib dir
# into ~/.<agent>/scripts/lib, and test code must not ship into a user's runtime.
#
# Usage: bash scripts/check-gates.sh   (exit 0 = all pass, 1 = a failure)

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
# shellcheck source=/dev/null
. scripts/lib/project-gates.sh   # transitively sources scripts/lib/common.sh
# shellcheck source=/dev/null
. scripts/check-lib.sh           # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TAB=$'\t'

# --- _adb_valid_label --------------------------------------------------------
_adb_valid_label build;   yes $? "valid label: build"
_adb_valid_label test-py; yes $? "valid label: test-py (hyphen)"
_adb_valid_label a_b1;    yes $? "valid label: a_b1"
_adb_valid_label 1build;  no  $? "invalid label: leading digit"
_adb_valid_label "a b";   no  $? "invalid label: space"
_adb_valid_label "a.b";   no  $? "invalid label: dot"

# --- _adb_path_in_scope (glob matching; single path passed as the change set) ------------
_adb_path_in_scope "apps/**"            "apps/x/y.js"; yes $? "scope apps/** matches apps/x/y.js"
_adb_path_in_scope "apps/**"            "docs/readme"; no  $? "scope apps/** does not match docs/readme"
_adb_path_in_scope "apps/**,packages/**" "packages/a"; yes $? "scope multi matches packages/a"
_adb_path_in_scope "apps/** , packages/**" "packages/a"; yes $? "scope tolerates whitespace"
_adb_path_in_scope "routes/**"          "routes/api.ts"; yes $? "scope routes/** matches nested"
_adb_path_in_scope "apps/*"             "apps/x/y.js"; yes $? "scope apps/* also crosses / (case glob)"
_adb_path_in_scope "*.md"               "README.md";   yes $? "scope *.md matches README.md"

# --- _adb_pkg_has (jq path) --------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  d="$work/pkg-scripts"; mkdir -p "$d"
  cat > "$d/package.json" <<'EOF'
{
  "name": "demo",
  "scripts": { "test": "jest", "lint": "eslint .", "format:check": "prettier -c ." },
  "dependencies": { "left-pad": "1.0.0" }
}
EOF
  _adb_pkg_has "$d" test;         yes $? "pkg_has: real script 'test'"
  _adb_pkg_has "$d" lint;         yes $? "pkg_has: real script 'lint'"
  _adb_pkg_has "$d" "format:check"; yes $? "pkg_has: 'format:check' with colon"
  _adb_pkg_has "$d" build;        no  $? "pkg_has: absent script 'build'"

  # ACCEPTANCE (#5): a DEPENDENCY named 'test' must NOT count as a script.
  d="$work/pkg-deponly"; mkdir -p "$d"
  cat > "$d/package.json" <<'EOF'
{
  "name": "demo",
  "scripts": { "build": "webpack" },
  "dependencies": { "test": "1.2.3" },
  "devDependencies": { "lint": "^2.0.0" }
}
EOF
  _adb_pkg_has "$d" test; no $? "pkg_has: dependency named 'test' is NOT a script (jq)"
  _adb_pkg_has "$d" lint; no $? "pkg_has: devDependency named 'lint' is NOT a script (jq)"

  # No .scripts at all, .scripts null, and malformed JSON → absent (no crash).
  d="$work/pkg-noscripts"; mkdir -p "$d"; printf '{"dependencies":{"test":"1"}}\n' > "$d/package.json"
  _adb_pkg_has "$d" test; no $? "pkg_has: no .scripts object → absent"
  d="$work/pkg-null"; mkdir -p "$d"; printf '{"scripts":null}\n' > "$d/package.json"
  _adb_pkg_has "$d" test; no $? "pkg_has: .scripts null → absent"
  d="$work/pkg-bad"; mkdir -p "$d"; printf '{ this is not json \n' > "$d/package.json"
  _adb_pkg_has "$d" test; no $? "pkg_has: malformed JSON → absent (no crash)"
else
  printf 'SKIP: jq not installed — skipping jq-path _adb_pkg_has tests\n' >&2
fi

# --- _adb_pkg_has (jq-absent fallback: braces in a script value) -------------
# Regression: a brace inside a script command value must not skew brace-depth tracking and
# drop a later real script (false negative) or scan into dependencies (false positive).
( _adb_have() { case "$1" in jq) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  d="$work/fb-negative"; mkdir -p "$d"
  cat > "$d/package.json" <<'JSON'
{
  "scripts": {
    "format": "prettier '{src,test}/**/*.js'",
    "build": "tsc && echo }",
    "test": "jest"
  },
  "dependencies": { "lint": "1.0.0" }
}
JSON
  _adb_pkg_has "$d" test; t=$?
  _adb_pkg_has "$d" lint; l=$?
  [ "$t" -eq 0 ] && [ "$l" -ne 0 ]
) ; yes $? "fallback: brace in a value keeps later 'test' and rejects dep 'lint'"

( _adb_have() { case "$1" in jq) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  d="$work/fb-positive"; mkdir -p "$d"
  cat > "$d/package.json" <<'JSON'
{
  "scripts": {
    "build": "echo {{"
  },
  "dependencies": { "test": "1.0.0" }
}
JSON
  _adb_pkg_has "$d" test   # a dependency, outside scripts — must stay absent
) ; no $? "fallback: an extra '{' in a value does not leak into dependencies"

# A COMPACT single-line scripts object must open AND close on its own line, so following
# dependency lines are not scanned as if inside scripts (Codex PR #41 finding).
( _adb_have() { case "$1" in jq) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  d="$work/fb-compact"; mkdir -p "$d"
  cat > "$d/package.json" <<'JSON'
{
  "scripts": {"build": "webpack"},
  "dependencies": {"test": "1.2.3"}
}
JSON
  _adb_pkg_has "$d" build; b=$?
  _adb_pkg_has "$d" test;  t=$?
  [ "$b" -eq 0 ] && [ "$t" -ne 0 ]
) ; yes $? "fallback: compact one-line scripts object detects its script, not a dep named 'test'"

# --- detect integration: dep-named 'test' emits no 'test' gate (npm-guarded) --
if command -v npm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  d="$work/detect-deponly"; mkdir -p "$d"
  cat > "$d/package.json" <<'EOF'
{ "name": "d", "scripts": { "lint": "eslint ." }, "dependencies": { "test": "1.0.0" } }
EOF
  out="$(adb_detect_gates "$d")"
  has  "$out" "lint${TAB}npm run lint" "detect: emits detected lint gate"
  hasnt "$out" "test${TAB}"            "detect: dep-named 'test' emits NO test gate"

  d="$work/detect-realtest"; mkdir -p "$d"
  cat > "$d/package.json" <<'EOF'
{ "name": "d", "scripts": { "test": "jest" } }
EOF
  out="$(adb_detect_gates "$d")"
  has "$out" "test${TAB}npm run test" "detect: real 'test' script emits a test gate"
else
  printf 'SKIP: npm or jq missing — skipping detect integration tests\n' >&2
fi

# --- open set: a custom 'build' gate runs and blocks like the built-in four ---
d="$work/openset"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates]
build = "exit 0"
EOF
recs="$(_adb_gate_records "$d")"
has "$recs" "run${TAB}build${TAB}exit 0${TAB}" "open-set: custom build gate is a run record"
adb_run_gates "$d" >/dev/null 2>&1; yes $? "open-set: passing custom gate → run succeeds"

d="$work/openset-fail"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates]
a_fail = "exit 1"
b_pass = "touch ran-b"
EOF
err="$(adb_run_gates "$d" 2>&1)"; rc=$?
no  "$rc" "open-set: failing custom gate → run fails (blocks)"
has "$err" 'gate "a_fail" failed' "open-set: failure names the failing gate"
if [ -f "$d/ran-b" ]; then ok; else bad "open-set: later gate still runs after an earlier failure"; fi

# --- N/A: declared not-applicable, reported, never a failure -----------------
d="$work/na"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates.state]
lint = "na"
typecheck = "N/A"
EOF
recs="$(_adb_gate_records "$d")"
has "$recs" "na${TAB}lint${TAB}"      "N/A: lint is an 'na' record"
has "$recs" "na${TAB}typecheck${TAB}" "N/A: 'N/A' (case-insensitive) is recognized"
err="$(adb_run_gates "$d" 2>&1)"; rc=$?
yes "$rc" "N/A: a declared-N/A gate never fails the run"
has "$err" 'gate "lint": N/A' "N/A: run reports the N/A gate"
status="$(adb_status_gates "$d")"
has "$status" "N/A" "N/A: status reports N/A"

# N/A is DISTINCT from a detection miss: with no state/override, lint produces no record.
d="$work/miss"; mkdir -p "$d"
recs="$(_adb_gate_records "$d")"
eq "$recs" "" "miss: an undetected axis with no config produces NO record"

# --- disabled ("") is silent and distinct from N/A ---------------------------
d="$work/disabled"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates]
lint = ""
EOF
recs="$(_adb_gate_records "$d")"
has "$recs" "disabled${TAB}lint${TAB}" "disabled: \"\" override → disabled record"
err="$(adb_run_gates "$d" 2>&1)"; rc=$?
yes "$rc" "disabled: run succeeds"
hasnt "$err" "N/A" "disabled: not reported as N/A"

# --- path scope --------------------------------------------------------------
mk_scope_repo() {
  local dir="$1"; mkdir -p "$dir"
  cat > "$dir/agents.toml" <<'EOF'
[gates]
build = "touch scope-ran"

[gates.scope]
build = "apps/**,packages/**"
EOF
}
d="$work/scope-match"; mk_scope_repo "$d"
adb_run_gates "$d" "apps/web/index.ts" >/dev/null 2>&1; yes $? "scope: matching change → run ok"
if [ -f "$d/scope-ran" ]; then ok; else bad "scope: gate ran on a matching changed path"; fi

d="$work/scope-nomatch"; mk_scope_repo "$d"
err="$(adb_run_gates "$d" "docs/readme.md" 2>&1)"; rc=$?
yes "$rc" "scope: non-matching change → run ok (gate skipped, not failed)"
if [ -f "$d/scope-ran" ]; then bad "scope: gate should have been SKIPPED on docs-only change"; else ok; fi
has "$err" 'skipped (scope' "scope: skip is reported"

d="$work/scope-nochange"; mk_scope_repo "$d"
adb_run_gates "$d" "" >/dev/null 2>&1
if [ -f "$d/scope-ran" ]; then ok; else bad "scope: no change set → scoped gate runs (fail-safe)"; fi

# --- per-gate cadence (#240) -------------------------------------------------
# Every fixture gate here BOTH leaves a marker AND exits non-zero. That is what makes
# "did it run?" observable in two independent ways at once: the marker proves execution,
# and the run's exit status proves the runner SAW the failure. A fixture that merely
# `exit 0`s would pass whether the gate ran or was skipped — the same blind spot case 8 of
# check-precommit-gate.sh was rewritten to remove.
mk_cadence_repo() {  # <dir> <cadence-for-'heavy'>
  local dir="$1" cadence="$2"; mkdir -p "$dir"
  { printf '[gates]\nheavy = "touch heavy-ran; exit 1"\nlight = "touch light-ran"\n'
    [ -n "$cadence" ] && printf '\n[gates.cadence]\nheavy = "%s"\n' "$cadence"
  } > "$dir/agents.toml"
}
ran()  { [ -f "$1/$2-ran" ]; }

# A `full` gate is SKIPPED at turn-end: no marker, the skip is reported, and — because the
# gate it skipped would have FAILED — the run is green. That last part is the real assertion:
# it proves the skip happened before execution rather than after a swallowed failure.
d="$work/cad-full-turnend"; mk_cadence_repo "$d" full
err="$(adb_run_gates "$d" "" turn-end 2>&1)"; rc=$?
yes "$rc" "cadence: a 'full' gate is not run at turn-end (a failing one cannot fail the run)"
if ran "$d" heavy; then bad "cadence: 'full' gate must NOT execute at turn-end"; else ok; fi
if ran "$d" light; then ok; else bad "cadence: an undeclared gate must still run at turn-end"; fi
has "$err" 'skipped (cadence "full", this is a "turn-end" run)' "cadence: the turn-end skip names cadence AND context"

# …and the same gate DOES run in a full run, where its failure must surface. If this case
# ever passes while the one above also passes for the wrong reason, the marker files
# disagree — which is why both are asserted rather than just the exit code.
d="$work/cad-full-full"; mk_cadence_repo "$d" full
adb_run_gates "$d" "" full >/dev/null 2>&1; rc=$?
no "$rc" "cadence: a 'full' gate runs in a full run and its failure surfaces"
if ran "$d" heavy; then ok; else bad "cadence: 'full' gate must execute in a full run"; fi

# The mirror image, so the model is symmetric rather than a one-way special case.
d="$work/cad-turnend-full"; mk_cadence_repo "$d" turn-end
err="$(adb_run_gates "$d" "" full 2>&1)"; rc=$?
yes "$rc" "cadence: a 'turn-end' gate is not run in a full run"
if ran "$d" heavy; then bad "cadence: 'turn-end' gate must NOT execute in a full run"; else ok; fi
has "$err" 'skipped (cadence "turn-end", this is a "full" run)' "cadence: the full-run skip is reported"

d="$work/cad-turnend-turnend"; mk_cadence_repo "$d" turn-end
adb_run_gates "$d" "" turn-end >/dev/null 2>&1
if ran "$d" heavy; then ok; else bad "cadence: 'turn-end' gate must execute at turn-end"; fi

# BACK-COMPATIBILITY, the criterion #240's test plan names explicitly: a repo with no
# [gates.cadence] table behaves exactly as before in BOTH contexts.
for ctx in turn-end full; do
  d="$work/cad-none-$ctx"; mk_cadence_repo "$d" ""
  adb_run_gates "$d" "" "$ctx" >/dev/null 2>&1; rc=$?
  no "$rc" "cadence: undeclared gates still run and still fail in a '$ctx' run"
  if ran "$d" heavy; then ok; else bad "cadence: an undeclared gate must run in a '$ctx' run"; fi
done

# An explicit "always" is the default spelled out, and must behave identically.
d="$work/cad-always"; mk_cadence_repo "$d" always
adb_run_gates "$d" "" turn-end >/dev/null 2>&1
if ran "$d" heavy; then ok; else bad "cadence: an explicit 'always' runs at turn-end"; fi

# A TYPO MUST NOT SILENTLY DISABLE A GATE. This is the direction that matters: the tempting
# reading of an unknown value is "skip until you fix it", which turns a one-character mistake
# into enforcement quietly off — indistinguishable from a passing gate (#35).
d="$work/cad-typo"; mk_cadence_repo "$d" "pre-push"
err="$(adb_run_gates "$d" "" turn-end 2>&1)"; rc=$?
no "$rc" "cadence: an unrecognized cadence RUNS the gate (fails toward enforcement)"
if ran "$d" heavy; then ok; else bad "cadence: an unrecognized cadence must not skip the gate"; fi
has "$err" 'unrecognized cadence' "cadence: an unrecognized cadence is reported, not silent"

# Case-insensitive, so a manifest written "Full" is not a silent typo of the above.
d="$work/cad-case"; mk_cadence_repo "$d" "FULL"
adb_run_gates "$d" "" turn-end >/dev/null 2>&1
if ran "$d" heavy; then bad "cadence: values are case-insensitive ('FULL' == 'full')"; else ok; fi

# An INVALID CALLER CONTEXT is a caller bug, not a config typo, and must fail loudly rather
# than guess: both guesses are wrong (ignore the repo's cadence, or run nothing at all).
d="$work/cad-badctx"; mk_cadence_repo "$d" full
err="$(adb_run_gates "$d" "" bogus 2>&1)"; rc=$?
eq "$rc" "2" "cadence: an unknown run context returns 2"
has "$err" "unknown run context" "cadence: an unknown run context says so"
if ran "$d" heavy || ran "$d" light; then bad "cadence: a bad context must run NOTHING"; else ok; fi

# Cadence must not resurrect a gate the other two tables already decided, nor manufacture one.
d="$work/cad-precedence"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates]
off = ""

[gates.state]
naxis = "na"

[gates.cadence]
off    = "turn-end"
naxis  = "turn-end"
ghost  = "turn-end"
EOF
recs="$(_adb_gate_records "$d" 2>/dev/null)"
has   "$recs" "disabled${TAB}off"  "cadence: a disabled gate stays disabled"
has   "$recs" "na${TAB}naxis"      "cadence: an N/A gate stays N/A"
hasnt "$recs" "ghost"              "cadence: a cadence-only key does not manufacture a gate"

# Per-gate elapsed (#240): a slow gate must be attributable without a stopwatch.
d="$work/cad-elapsed"; mkdir -p "$d"
printf '[gates]\nquick = "true"\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" "" full 2>&1)"
has "$err" 'gate "quick": ok (' "elapsed: a passing gate reports its elapsed seconds"
d="$work/cad-elapsed-fail"; mkdir -p "$d"
printf '[gates]\nbroken = "false"\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" "" full 2>&1)"
has "$err" 'failed after ' "elapsed: a failing gate reports its elapsed seconds too"

# --- an empty MIDDLE field must not shift the record (the #240 parse bug) -----
# `IFS=<tab> read` collapses runs of tabs, so an empty `scope` silently ate the `cadence`
# field and every gate was skipped in every context — enforcement off, from a reader that
# still looked correct. Pinned end-to-end: a gate with NO scope and an explicit cadence.
d="$work/cad-emptyscope"; mkdir -p "$d"
printf '[gates]\nheavy = "touch heavy-ran"\n\n[gates.cadence]\nheavy = "full"\n' > "$d/agents.toml"
adb_run_gates "$d" "" full >/dev/null 2>&1
if ran "$d" heavy; then ok; else bad "record: an empty scope must not shift cadence out of position"; fi
# …and the split itself, asserted directly on the empty-field shapes. Pre-initialised because
# the values arrive through namerefs, which shellcheck cannot follow (SC2154).
xstate=""; xlabel=""; xcmd=""; xscope=""; xcad=""
_adb_rec_split "$(printf 'run\tL\tC\t\tfull')" xstate xlabel xcmd xscope xcad
eq "$xstate${TAB}$xlabel${TAB}$xcmd${TAB}$xscope${TAB}$xcad" "run${TAB}L${TAB}C${TAB}${TAB}full" \
   "split: empty scope keeps cadence in place"
_adb_rec_split "$(printf 'run\tL\t\tapps/**\talways')" xstate xlabel xcmd xscope xcad
eq "$xcmd"   ""        "split: an empty command does not shift scope"
eq "$xscope" "apps/**" "split: scope survives an empty command"
eq "$xcad"   "always"  "split: cadence survives an empty command"

# --- dotted-table isolation (relies on the literal-table fix in common.sh) ----
d="$work/dotted"; mkdir -p "$d"
cat > "$d/agents.toml" <<'EOF'
[gates]
build = "run-build"

[gates.scope]
build = "apps/**"
EOF
eq "$(adb_toml_unquote "$(adb_toml_get "$d/agents.toml" gates build)")"       "run-build" "dotted: [gates] build is not shadowed by [gates.scope]"
eq "$(adb_toml_unquote "$(adb_toml_get "$d/agents.toml" gates.scope build)")" "apps/**"   "dotted: [gates.scope] build reads its own value"
eq "$(adb_toml_keys "$d/agents.toml" gates)" "build" "dotted: keys of [gates] exclude sub-table keys"

# --- tab in a command is rejected (delimiter cannot be forged) ---------------
d="$work/tabby"; mkdir -p "$d"
printf '[gates]\nbuild = "echo\thi"\n' > "$d/agents.toml"
recs="$(_adb_gate_records "$d" 2>/dev/null)"
hasnt "$recs" "build" "tab: a command containing a tab is rejected"

# --- regression: a failed `mktemp -d` must not delete the shared temp dir ------
# Once the fallback resolved to a literal /tmp and the cleanup did `rm -rf /tmp`.
d="$work/mktemp-fail"; mkdir -p "$d"
printf '[gates]\nbuild = "exit 0"\n' > "$d/agents.toml"
faketmp="$work/faketmp"; mkdir -p "$faketmp"; : > "$faketmp/sentinel"
( mktemp() { return 1; }        # force the mktemp-failure fallback path
  TMPDIR="$faketmp"
  adb_run_gates "$d" >/dev/null 2>&1 )
if [ -f "$faketmp/sentinel" ]; then ok; else bad "mktemp-fail: cleanup must NOT rm the shared temp dir"; fi

# --- empty repo: detect nothing / exit 0 (the unknown-repo contract) ---------
d="$work/empty"; mkdir -p "$d"
out="$(adb_detect_gates "$d")"; eq "$out" "" "empty: detect emits nothing"
adb_run_gates "$d" >/dev/null 2>&1; yes $? "empty: run is a clean no-op (exit 0)"

check_summary "gates"
