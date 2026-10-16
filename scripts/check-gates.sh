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
# A failing run KEEPS its log directory under $TMPDIR (D133), so this suite's TMPDIR is its own:
# every directory a red fixture keeps lands in $work, and the trap removes it.
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"

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

# A MANIFEST THAT CANNOT BE READ AS TOML IS A FATAL, NOT AUTO-DETECTION (PR #429). `adb_toml_get`
# returns 3 for a NUL byte (2 for an unreadable file), and every read here treated both as "key
# absent" — so a `""`-disabled gate ran, a declared command became a default, a custom gate vanished.
d="$work/nul-manifest"; mkdir -p "$d"
printf '[gates]\ntest = ""\nbuild = "exit 1"\000\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" 2>&1)"; rc=$?
eq "$rc" 2 "nul-manifest: run refuses (2) rather than auto-detecting over a manifest it cannot read"
has "$err" "cannot be read as TOML" "nul-manifest: …and says why"
err="$(_adb_gate_records "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 2 "nul-manifest: the records function refuses too"
eq "$(_adb_gate_records "$d" 2>/dev/null | wc -l | tr -d ' ')" 0 "nul-manifest: …and emits no record"
adb_detect_gates "$d" >/dev/null 2>&1; eq "$?" 2 "nul-manifest: detect refuses"
adb_status_gates "$d" >/dev/null 2>&1; eq "$?" 2 "nul-manifest: status refuses"

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

# Case-insensitive, so a manifest written "Full" is not a silent typo of the above. Asserted on
# FOUR observations, not just the absent marker: dropping the uppercase gate's record entirely
# would satisfy "heavy did not run" while breaking everything else about it.
d="$work/cad-case"; mk_cadence_repo "$d" "FULL"
err="$(adb_run_gates "$d" "" turn-end 2>&1)"; rc=$?
yes "$rc" "cadence: 'FULL' is recognized, so the failing gate is skipped and the run is green"
if ran "$d" heavy; then bad "cadence: values are case-insensitive ('FULL' == 'full')"; else ok; fi
if ran "$d" light; then ok; else bad "cadence: the uppercase fixture's OTHER gate must still run"; fi
has "$err" 'skipped (cadence "full"' "cadence: 'FULL' is normalized to lower case in the report"
hasnt "$err" 'unrecognized cadence' "cadence: 'FULL' is not treated as a typo"

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
#
# A `true`/`false` fixture proves only that the WORDS are printed — a hardcoded constant, or a
# number that never advances, would satisfy that. So one gate deliberately sleeps past a
# one-second boundary and the reported figure is read back and compared NUMERICALLY. That is what
# distinguishes "elapsed is measured" from "elapsed is spelled".
d="$work/cad-elapsed"; mkdir -p "$d"
printf '[gates]\nquick = "true"\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" "" full 2>&1)"
has "$err" 'gate "quick": ok (' "elapsed: a passing gate reports its elapsed seconds"

d="$work/cad-elapsed-slow"; mkdir -p "$d"
printf '[gates]\nslow = "sleep 1.2"\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" "" full 2>&1)"
secs="$(printf '%s\n' "$err" | sed -n 's/.*gate "slow": ok (\([0-9][0-9]*\)s).*/\1/p')"
case "$secs" in
  ''|*[!0-9]*) bad "elapsed: could not read a numeric elapsed for a slow gate, got: $err" ;;
  *) if [ "$secs" -ge 1 ]; then ok; else
       bad "elapsed: a gate that slept >1s reported ${secs}s — the value is not measured"; fi ;;
esac
# …and a fast gate in the same run must NOT inherit that figure, which a shared or accumulating
# timer would produce.
#
# ASSERT THE PROPERTY, NOT A LITERAL (#308). This used to pin the exact string `ok (0s)`, and
# BASH_MONOSECONDS counts WHOLE seconds: two samples straddling a tick differ by 1 however little
# happened between them, so a `true` gate legitimately reports `1s` and the assertion went red at
# random. Measured on this very fixture, the timed window is 4-18 ms (mean ~8 ms; 16 busy spinners
# on a 10-core box moved the mean only to ~9.5 ms). Over a uniformly distributed clock phase that
# mean implies a straddle in ~0.8% of runs, about one in 125; #308 observed one in 400 by sampling.
# Either way it is rare enough to read as a flake and frequent enough to cost a diagnosis on every
# PR, twice over, since this suite runs on both hosted runners and `ci-discipline.md` forbids
# re-running past it.
#
# The RELATION is what "not cumulative" means, and its detection is structural rather than
# probabilistic: with one shared `t0` the fast gate's window CONTAINS the slow gate's, so its
# reported figure comes back >= the slow gate's every time, for any sleep length.
#
# THE SLEEP IS 2.2s, AND SHORTENING IT SILENTLY DISARMS THIS. At 1.2s a cumulative timer reports
# `bfast=1s` — the same reading a legitimate tick-straddle produces — so the bug and the flake are
# indistinguishable and no tolerant form of this assertion can separate them. Past 2s the slow
# gate's own figure is >= 2 by construction, which is why that is pinned below rather than assumed.
#
# That pin is asymmetric, and worth stating exactly rather than flatteringly: at 2.2s it NEVER
# fires spuriously, because a 2.2s window spans two ticks whatever the phase. As a tripwire against
# someone shortening the sleep it is only PROBABLE — back at 1.2s the slow gate still reads `2s`
# whenever its window straddles two ticks, which is the fractional part, ~20% of runs. So it catches
# that edit about four times in five, not always. The asymmetry is the right way round (a guard that
# cries wolf is the defect this file is fixing), but it is a tripwire, not a proof.
#
# What is NOT claimed is determinism. A spurious failure now needs that ~10 ms window to inflate
# past a full second, >55x the worst observed under deliberate CPU oversubscription. That bounds
# the residual rather than removing it, which is all any wall-clock assertion can do — and the
# alternatives are worse: a synthetic clock driven by a DEBUG trap would encode how many simple
# commands sit between the two samples and break on any refactor of the loop, and grepping for the
# assignment would test that elapsed is SPELLED, which is what the block above exists not to do.

# Read ONE gate's reported elapsed out of a run's stderr. Anchored to the WHOLE line, because an
# unanchored `.*gate "x": ok (…)` also matches that text quoted inside a gate's own captured
# output; and the caller requires exactly one all-digit value PER GATE, because an empty or
# two-line read fed into `[ … -lt … ]` fails as a shell arithmetic error rather than as the parse
# failure it is.
elapsed_of() { printf '%s\n' "$1" | sed -n 's/^adb: gate "'"$2"'": ok (\([0-9][0-9]*\)s)$/\1/p'; }

d="$work/cad-elapsed-mixed"; mkdir -p "$d"
printf '[gates]\naslow = "sleep 2.2"\nbfast = "true"\n' > "$d/agents.toml"
err="$(adb_run_gates "$d" "" full 2>&1)"
slow_secs="$(elapsed_of "$err" aslow)"
fast_secs="$(elapsed_of "$err" bfast)"
# The `:` is a SEPARATOR, not decoration: concatenating the two readings lets one empty value hide
# behind the other's digits — `""` and `"2"` join to `2`, which is all-digits, and the arithmetic
# below then dies on the empty one. Held apart, `:0` and `2:` are each rejected by their own arm.
# A two-line read carries a newline, which `[!0-9:]` catches wherever it lands.
case "$slow_secs:$fast_secs" in
  :*|*:|*[!0-9:]*) bad "elapsed: could not read exactly one numeric elapsed per gate, got: $err" ;;
  *)
    # The slow gate must run FIRST, or a cumulative timer would credit the fast gate with nothing
    # and this whole fixture would pass while blind. Read the order off the output rather than
    # trusting that the labels sort the way they were named to.
    case "${err%%adb: gate \"bfast\"*}" in
      *'gate "aslow": ok'*) ok ;;
      *) bad "elapsed: the fixture's slow gate did not run first, so independence is untested: $err" ;;
    esac
    if [ "$slow_secs" -ge 2 ]; then ok; else
      bad "elapsed: the fixture's slow gate reported ${slow_secs}s — it must read at least 2s, or a cumulative timer is indistinguishable from a tick-straddle"; fi
    if [ "$fast_secs" -lt "$slow_secs" ]; then ok; else
      bad "elapsed: each gate is timed independently, not cumulatively — the fast gate reported ${fast_secs}s against the slow gate's ${slow_secs}s"; fi ;;
esac

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

# Output names are validated before `local -n` binds them (D34): an unvalidated name reaches
# `declare -n`, which evaluates an array subscript inside it, and this library ships to consumers.
# A reserved-prefix name would otherwise bind circularly and leave the caller's variable UNSET —
# a silent wrong answer rather than an error.
_adb_rec_split "$(printf 'run\tL\tC\tsc\tfull')" _ars_o1 xlabel xcmd xscope xcad 2>/dev/null
eq "$?" "2" "split: a reserved-prefix output name is refused, not bound circularly"
# The payload writes into the suite's OWN scratch dir, never the repo root: when this guard is
# absent the subscript really does execute (observed), and a relative path would litter the
# developer's tracked tree with a file named by a failing test.
_adb_rec_split "$(printf 'run\tL\tC\tsc\tfull')" "arr[\$(touch $work/pwned)]" xlabel xcmd xscope xcad 2>/dev/null
eq "$?" "2" "split: a subscript-bearing output name is refused before declare -n evaluates it"
if [ -e "$work/pwned" ]; then bad "split: a subscript output name EXECUTED (arbitrary command run)"; else ok; fi
_adb_rec_split "$(printf 'run\tL\tC\tsc\tfull')" "" xlabel xcmd xscope xcad 2>/dev/null
eq "$?" "2" "split: an empty output name is refused"

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

# --- a failed `mktemp -d` runs NO gate, and never touches the shared temp dir ------
# Once a fallback resolved to a literal /tmp and the cleanup did `rm -rf /tmp`. There is no
# fallback now (D133, local review pass 3): with no private log directory, every gate that would
# run counts as failed, says why, and is not run — and nothing is written to or removed from the
# shared dir.
d="$work/mktemp-fail"; mkdir -p "$d"
printf '[gates]\nbuild = "touch ran-build"\n' > "$d/agents.toml"
faketmp="$work/faketmp"; mkdir -p "$faketmp"; : > "$faketmp/sentinel"
err="$( mktemp() { return 1; }        # force mktemp -d to fail
        TMPDIR="$faketmp"
        adb_run_gates "$d" 2>&1 >/dev/null )"; rc=$?
eq "$rc" 1 "mktemp-fail: a gate that would have passed fails the run, because it was not run"
has "$err" 'adb: gate "build" failed: no private log directory could be created under' "mktemp-fail: the gate says why it was not run"
has "$err" 'failing gates: build' "mktemp-fail: it counts as failed"
if [ -e "$d/ran-build" ]; then bad "mktemp-fail: a gate with no private log directory must NOT run"; else ok; fi
if [ -f "$faketmp/sentinel" ]; then ok; else bad "mktemp-fail: cleanup must NOT rm the shared temp dir"; fi
eq "$(LC_ALL=C ls -A "$faketmp" | tr '\n' ' ')" "sentinel " "mktemp-fail: nothing is written to the shared temp dir"

# …and the boundary local review pass 3 found: a writable file ALREADY at the old predictable name.
# The fallback opened it, so the gate ran (and a plain `>` truncated the file, or wrote through it
# had it been a planted link). Now the gate is not run and the file is untouched — with no
# `set -C`, which is what the fallback needed to refuse it.
d="$work/mktemp-fail-planted"; faketmp="$work/planted-faketmp"; mkdir -p "$d" "$faketmp"
printf '[gates]\nprobe = "touch ran-probe; echo overwritten"\n' > "$d/agents.toml"
printf 'planted\n' > "$faketmp/adb-gate-probe.log"
err="$( mktemp() { return 1; }
        TMPDIR="$faketmp"
        adb_run_gates "$d" 2>&1 >/dev/null )"; rc=$?
eq "$rc" 1 "mktemp-fail (planted name): the run fails"
has "$err" 'adb: gate "probe" failed: no private log directory could be created under' "mktemp-fail (planted name): the gate says why it was not run"
if [ -e "$d/ran-probe" ]; then bad "mktemp-fail (planted name): a pre-existing log name must not let the gate run"; else ok; fi
eq "$(cat "$faketmp/adb-gate-probe.log")" "planted" "mktemp-fail (planted name): the existing file is neither truncated nor written"
# The same boundary for real, as the reviewer probed it: a mode-500 $TMPDIR, where mktemp -d fails
# on its own and the planted file is still writable. Skipped as root, which writes through the mode.
if [ "$(id -u)" -ne 0 ]; then
  ro="$work/ro-tmp"; mkdir -p "$ro"; printf 'planted\n' > "$ro/adb-gate-probe.log"; chmod 500 "$ro"
  err="$(export TMPDIR="$ro"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
  chmod 700 "$ro"
  eq "$rc" 1 "read-only TMPDIR (planted name): the run fails"
  has "$err" 'adb: gate "probe" failed: no private log directory could be created under' "read-only TMPDIR (planted name): the gate says why it was not run"
  if [ -e "$d/ran-probe" ]; then bad "read-only TMPDIR (planted name): the gate must not run"; else ok; fi
  eq "$(cat "$ro/adb-gate-probe.log")" "planted" "read-only TMPDIR (planted name): the existing file is untouched"
fi

# --- a failed gate's FULL log is kept, and its path reported (#509, D133) ----------
# The runner prints a 4000-byte tail, so a failure marker printed early is gone from stderr; what
# makes it recoverable is the kept file. Each fixture runs under its OWN temp dir, so "which
# directory did this run keep" is answered by listing it rather than by guessing a random name.
noisy_gate() {   # <dir> <id> <rc> — writes noisy-<id>.sh: EARLY-<id>, >4000 bytes, exit <rc>
  printf 'echo EARLY-%s\ni=0\nwhile [ $i -lt 300 ]; do echo "filler line $i xxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done\nexit %s\n' \
    "$2" "$3" > "$1/noisy-$2.sh"
}
kept_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d -name 'adb-gates.*' | LC_ALL=C sort; }   # <tmpdir>
reported_log() { printf '%s\n' "$1" | sed -n 's/^adb: gate "'"$2"'": full log kept at //p'; }    # <stderr> <label>

d="$work/keep-fail"; kt="$work/keep-fail-tmp"; mkdir -p "$d" "$kt"
noisy_gate "$d" MARK509 3
printf '[gates]\nnoisy = "sh ./noisy-MARK509.sh"\n' > "$d/agents.toml"
( cd "$d" && sh ./noisy-MARK509.sh ) > "$work/keep-fail.expected" 2>&1
err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "kept log: a failing gate still fails the run (1)"
hasnt "$err" EARLY-MARK509 "kept log: the marker is outside the printed tail (else this fixture proves nothing)"
kd="$(kept_dirs "$kt")"
eq "$(printf '%s\n' "$kd" | grep -c .)" 1 "kept log: a failing run keeps exactly one log directory"
# The report is DISPLAY text (shell-quoted), never a filename: assert its form against the raw path
# found on disk, then read the raw path.
kf="$kd/adb-gate-noisy.log"
eq "$(reported_log "$err" noisy)" "$(printf '%q' "$kf")" "kept log: the reported path is the kept file"
if [ -f "$kf" ] && cmp -s "$kf" "$work/keep-fail.expected"; then ok; else
  bad "kept log: the file at the reported path holds the gate's whole output, byte for byte"; fi
grep -q EARLY-MARK509 "$kf" 2>/dev/null; yes $? "kept log: the failure marker is recoverable from the reported path"
eq "$(adb_file_mode "$kd")" 700 "kept log: the kept directory is owner-only"
has "$err" "failing gates: noisy — full logs kept in $(printf '%q' "$kd")" "kept log: the summary line names the kept directory"

# A second failing run keeps its own directory and leaves the first one's evidence alone.
( export TMPDIR="$kt"; adb_run_gates "$d" >/dev/null 2>&1 )
kd2="$(kept_dirs "$kt")"
eq "$(printf '%s\n' "$kd2" | grep -c .)" 2 "kept log: a second failing run keeps a directory of its own"
while IFS= read -r x; do
  if cmp -s "$x/adb-gate-noisy.log" "$work/keep-fail.expected"; then ok; else
    bad "kept log: every failing run's log survives the next run ($x)"; fi
done <<EOF
$kd2
EOF

# Failing and passing gates mixed: every gate runs, and exactly the failing gates' logs are kept.
d="$work/keep-mixed"; kt="$work/keep-mixed-tmp"; mkdir -p "$d" "$kt"
noisy_gate "$d" MARKA 1
noisy_gate "$d" MARKC 2
printf '[gates]\na_fail = "sh ./noisy-MARKA.sh"\nb_pass = "echo passing-output; touch ran-b"\nc_fail = "sh ./noisy-MARKC.sh"\n' > "$d/agents.toml"
err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "kept log (mixed): the run fails"
if [ -f "$d/ran-b" ]; then ok; else bad "kept log (mixed): a gate after a failure still runs"; fi
kd="$(kept_dirs "$kt")"
eq "$(cd "$kd" 2>/dev/null && LC_ALL=C ls -A | tr '\n' ' ')" "adb-gate-a_fail.log adb-gate-c_fail.log " \
   "kept log (mixed): exactly the failing gates' logs are kept, never the passing gate's"
for g in a_fail c_fail; do
  eq "$(reported_log "$err" "$g")" "$(printf '%q' "$kd/adb-gate-$g.log")" "kept log (mixed): $g's reported path is its kept file"
done
grep -q EARLY-MARKA "$kd/adb-gate-a_fail.log" 2>/dev/null; yes $? "kept log (mixed): the first failing gate's marker is recoverable"
grep -q EARLY-MARKC "$kd/adb-gate-c_fail.log" 2>/dev/null; yes $? "kept log (mixed): the second failing gate's marker is recoverable"
has "$err" "failing gates: a_fail c_fail — full logs kept in" "kept log (mixed): the summary names both gates and the directory"

# A PASSING run removes its directory. The positive control is what makes the absence mean
# something: a gate lists $TMPDIR mid-run, proving the directory was created where we look.
d="$work/keep-pass"; kt="$work/keep-pass-tmp"; mkdir -p "$d" "$kt"
printf 'ls "$TMPDIR" > seen\n' > "$d/probe.sh"
printf '[gates]\nprobe = "sh ./probe.sh"\nother = "echo noise"\n' > "$d/agents.toml"
( export TMPDIR="$kt"; adb_run_gates "$d" >/dev/null 2>&1 ); rc=$?
eq "$rc" 0 "kept log (pass): a passing run succeeds"
has "$(cat "$d/seen" 2>/dev/null)" "adb-gates." "kept log (pass): positive control — the run's log directory was created under TMPDIR"
eq "$(kept_dirs "$kt")" "" "kept log (pass): a passing run leaves no log directory behind"

# A gate that deletes its own log: the runner must not claim a log it does not have, and keeps
# no directory for it.
d="$work/keep-selfdelete"; kt="$work/keep-selfdelete-tmp"; mkdir -p "$d" "$kt"
printf 'rm -f "$TMPDIR"/adb-gates.*/adb-gate-selfdel.log\nexit 1\n' > "$d/selfdel.sh"
printf '[gates]\nselfdel = "sh ./selfdel.sh"\n' > "$d/agents.toml"
err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "kept log (no file): the gate still fails the run"
has "$err" 'gate "selfdel": no log kept — the gate removed its own log at' "kept log (no file): the failure says the gate removed its log"
hasnt "$err" "full log kept at" "kept log (no file): no missing log is advertised as kept"
eq "$(kept_dirs "$kt")" "" "kept log (no file): a directory with nothing in it is not kept"

# A temp dir whose path holds a space: the path is reported shell-quoted, and names the real file.
d="$work/keep-fail"; kt="$work/keep space tmp"; mkdir -p "$kt"
err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"
kd="$(kept_dirs "$kt")"
eq "$(reported_log "$err" noisy)" "$(printf '%q' "$kd/adb-gate-noisy.log")" "kept log (space): the reported path is the kept file, quoted"
if cmp -s "$kd/adb-gate-noisy.log" "$work/keep-fail.expected"; then ok; else bad "kept log (space): the kept file is whole"; fi

# Executed, not sourced: the standalone `run` keeps and reports exactly the same.
kt="$work/keep-standalone-tmp"; mkdir -p "$kt"
err="$(TMPDIR="$kt" bash scripts/lib/project-gates.sh run "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "kept log (standalone): run exits 1"
kd="$(kept_dirs "$kt")"
eq "$(reported_log "$err" noisy)" "$(printf '%q' "$kd/adb-gate-noisy.log")" "kept log (standalone): the reported path is the kept file"
if cmp -s "$kd/adb-gate-noisy.log" "$work/keep-fail.expected"; then ok; else
  bad "kept log (standalone): the kept file holds the whole log"; fi

# NO BYTE OF $TMPDIR REACHES STDERR UNESCAPED. A newline in it would let any native diagnostic that
# echoes the path (rm's, the log redirect's) print a line the reader takes as the runner's own. A
# gate makes the log directory read-only, so the passing gate's rm, the next gate's redirect and the
# final rm -rf all fail: every stderr line naming the directory must then be one the runner printed.
# Skipped as root, which writes through the mode and so never reaches those failures.
if [ "$(id -u)" -ne 0 ]; then
  d="$work/keep-nl"; kt="$work/nl"$'\n'"tmp"; mkdir -p "$d" "$kt"
  printf 'chmod 500 "$TMPDIR"/adb-gates.*\n' > "$d/lock.sh"
  printf '[gates]\na_lock = "sh ./lock.sh"\nb_next = "touch ran-next"\n' > "$d/agents.toml"
  err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
  for x in "$kt"/adb-gates.*; do [ -d "$x" ] && chmod 700 "$x"; done
  eq "$rc" 1 "escaped (newline TMPDIR): a gate whose log cannot be created fails the run"
  has "$err" 'adb: NOTE — could not delete the log of passing gate "a_lock"' "escaped (newline TMPDIR): the failed rm is reported"
  has "$err" 'adb: gate "b_next" failed: its log could not be created at' "escaped (newline TMPDIR): the failed log creation is reported"
  if [ -e "$d/ran-next" ]; then bad "escaped (newline TMPDIR): a gate whose log could not be created must NOT run"; else ok; fi
  has "$err" 'adb: NOTE — could not delete the gate log directory' "escaped (newline TMPDIR): the failed cleanup is reported"
  stray="$(printf '%s\n' "$err" | grep 'adb-gates\.' | grep -v '^adb: ')"
  eq "$stray" "" "escaped (newline TMPDIR): every line naming the log directory is the runner's own"

  # …and the fourth such command, `tail`: a gate that makes its own log unreadable.
  d="$work/keep-unread"; mkdir -p "$d"
  printf 'echo early\nchmod 000 "$TMPDIR"/adb-gates.*/adb-gate-u_unread.log\nexit 1\n' > "$d/unread.sh"
  printf '[gates]\nu_unread = "sh ./unread.sh"\n' > "$d/agents.toml"
  err="$(export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
  for x in "$kt"/adb-gates.*/adb-gate-u_unread.log; do [ -f "$x" ] && chmod 600 "$x"; done
  eq "$rc" 1 "escaped (unreadable log): the failing gate fails the run"
  has "$err" 'adb: gate "u_unread": could not print its log tail' "escaped (unreadable log): the failed tail is reported"
  stray="$(printf '%s\n' "$err" | grep 'adb-gates\.' | grep -v '^adb: ')"
  eq "$stray" "" "escaped (unreadable log): every line naming the log directory is the runner's own"
fi

# A CALLER'S `set -C` (noclobber) neither stops a gate running nor its log being written: the log
# is opened once and the gate writes through that descriptor — which the gate itself never
# inherits.
d="$work/keep-noclobber"; kt="$work/keep-noclobber-tmp"; mkdir -p "$d" "$kt"
noisy_gate "$d" MARKNC 4
printf 'if : >&9 2>/dev/null; then touch fd9-leaked; fi\n' > "$d/fd9.sh"
printf '[gates]\na_noisy = "sh ./noisy-MARKNC.sh"\nb_fd = "sh ./fd9.sh; touch ran-b"\n' > "$d/agents.toml"
( cd "$d" && sh ./noisy-MARKNC.sh ) > "$work/noclobber.expected" 2>&1
err="$(set -C; export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "noclobber: the failing gate still fails the run"
kd="$(kept_dirs "$kt")"
if cmp -s "$kd/adb-gate-a_noisy.log" "$work/noclobber.expected"; then ok; else
  bad "noclobber: under a caller's set -C the gate runs and its whole output is kept"; fi
if [ -f "$d/ran-b" ]; then ok; else bad "noclobber: under a caller's set -C a passing gate still runs"; fi
if [ -e "$d/fd9-leaked" ]; then bad "noclobber: a gate must not inherit the log's descriptor"; else ok; fi
# A $TMPDIR THAT DOES NOT EXIST fails closed: no gate can have a log, so none runs, and every one
# counts as failed and says why — enforcement never goes quietly off with a broken temp dir.
d="$work/keep-badtmp"; mkdir -p "$d"
printf '[gates]\nfirst = "touch ran-first"\nsecond = "touch ran-second"\n' > "$d/agents.toml"
err="$(export TMPDIR="$work/does-not-exist"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "broken TMPDIR: the run fails"
has "$err" 'adb: gate "first" failed: no private log directory could be created under' "broken TMPDIR: the first gate says it was not run"
has "$err" 'adb: gate "second" failed: no private log directory could be created under' "broken TMPDIR: so does the second"
has "$err" 'failing gates: first second' "broken TMPDIR: both count as failed"
if [ -e "$d/ran-first" ] || [ -e "$d/ran-second" ]; then bad "broken TMPDIR: a gate with no log must not run"; else ok; fi

# A LOG OPEN THAT FAILS INSIDE the private directory: the first gate deletes the run's directory, so
# the second gate's open fails. That gate is not run and says so; the open's own diagnostic is
# discarded (the group's `2>/dev/null` comes first); and a sourcing caller's `set -e` does not cut
# the report short at it (the group's `|| :`), so the third gate is still reported. Root-safe: a
# missing directory refuses root too, unlike the mode-500 fixture above.
d="$work/keep-wiped"; kt="$work/keep-wiped-tmp"; mkdir -p "$d" "$kt"
printf 'rm -rf "$TMPDIR"/adb-gates.*\n' > "$d/wipe.sh"
printf '[gates]\na_wipe = "sh ./wipe.sh"\nb_next = "touch ran-next"\nc_last = "touch ran-last"\n' > "$d/agents.toml"
err="$(set -e; export TMPDIR="$kt"; adb_run_gates "$d" 2>&1 >/dev/null)"; rc=$?
eq "$rc" 1 "wiped log dir: a gate whose log cannot be opened fails the run"
has "$err" 'adb: gate "b_next" failed: its log could not be created at' "wiped log dir: the failed open is reported"
has "$err" 'adb: gate "c_last" failed: its log could not be created at' "wiped log dir under set -e: the next gate is still reported"
has "$err" 'failing gates: b_next c_last' "wiped log dir under set -e: every gate is reported, the run is not killed"
if [ -e "$d/ran-next" ] || [ -e "$d/ran-last" ]; then bad "wiped log dir: a gate whose log could not be opened must NOT run"; else ok; fi
stray="$(printf '%s\n' "$err" | grep -v '^adb: ' | grep -v '^$')"
eq "$stray" "" "wiped log dir: no native diagnostic of the failed open reaches stderr"

# A RELATIVE $TMPDIR is made absolute before mktemp sees it. One spelled `-tmp` would otherwise be
# parsed as an option, so mktemp -d would fail and no gate would run; and the printed path must not
# depend on the reader's working directory.
rt="$work/reltmp"; mkdir -p "$rt/-tmp"
d="$work/keep-fail"
err="$(cd "$rt" && export TMPDIR=-tmp && adb_run_gates "$d" 2>&1 >/dev/null)"
kd="$(kept_dirs "$rt/-tmp")"
eq "$(printf '%s\n' "$kd" | grep -c .)" 1 "relative TMPDIR (-tmp): the run keeps its directory under it, not the fallback"
hasnt "$err" "no private log directory" "relative TMPDIR (-tmp): mktemp -d succeeded"
eq "$(reported_log "$err" noisy)" "$(printf '%q' "$kd/adb-gate-noisy.log")" "relative TMPDIR (-tmp): the reported path is absolute"
if cmp -s "$kd/adb-gate-noisy.log" "$work/keep-fail.expected"; then ok; else bad "relative TMPDIR (-tmp): the kept file is whole"; fi

# --- empty repo: detect nothing / exit 0 (the unknown-repo contract) ---------
d="$work/empty"; mkdir -p "$d"
out="$(adb_detect_gates "$d")"; eq "$out" "" "empty: detect emits nothing"
adb_run_gates "$d" >/dev/null 2>&1; yes $? "empty: run is a clean no-op (exit 0)"

# --- PHP (#81) ---------------------------------------------------------------
# The failure this closes: a PHP repo was a RECOGNISED project root with ZERO gates, which is
# the silent-no-gate shape #35 exists to prevent — `detect` printed nothing and exited 0, exactly
# as it does for a directory containing no project at all. `adopt-lib.sh stack` already answered
# `php` for the same tree, so the two libraries disagreed about whether the repo was even known.
#
# EVERY PHP TOOL HERE IS A STUB on PATH or under vendor/bin. The point is which command the
# detector CHOOSES, not what PHPStan does — and requiring a real PHP toolchain would make this
# whole section a SKIP on both CI runners, i.e. a test that proves nothing where it matters.
php_stub() {   # <dir> <name...> — executable no-op stubs
  local dir="$1"; shift; mkdir -p "$dir"
  local n; for n in "$@"; do printf '#!/bin/sh\nexit 0\n' > "$dir/$n"; chmod +x "$dir/$n"; done
}

# vendor/bin beats PATH: a Composer-pinned tool is the version the project's config was
# written against, so a globally installed PHPStan of another major must NOT win.
d="$work/php-vendor"; mkdir -p "$d"
printf '{"name":"a/b"}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpstan phpunit phpcs
out="$(adb_detect_gates "$d")"
has "$out" "vendor/bin/phpstan analyse" "php: vendor/bin phpstan is the typecheck gate"
has "$out" "vendor/bin/phpunit"         "php: vendor/bin phpunit is the test gate"

# EVERY declared composer script is honoured, not just test/lint. The docs claim declared
# commands beat inferred binaries; honouring only two of the four made that claim false for the
# other two, and silently preferred an inferred phpstan over a script the project wrote.
d="$work/php-scripts-all"; mkdir -p "$d"
printf '{"scripts":{"typecheck":"phpstan analyse -c custom.neon","format:check":"php-cs-fixer check"}}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpstan php-cs-fixer
( PATH="$work/php-bin-composer2:$PATH"; php_stub "$work/php-bin-composer2" composer
  out="$(adb_detect_gates "$d")"
  case "$out" in *"composer run-script typecheck"*) : ;; *) exit 1 ;; esac
  case "$out" in *"composer run-script format:check"*) : ;; *) exit 1 ;; esac )
yes $? "php: declared typecheck and format:check scripts beat the inferred binaries"

# A declared composer script beats an inferred binary — the project stating its own command.
d="$work/php-scripts"; mkdir -p "$d"
printf '{"scripts":{"test":"phpunit --testdox","lint":"phpcs --standard=PSR12"}}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpunit phpcs
( PATH="$work/php-bin-composer:$PATH"; php_stub "$work/php-bin-composer" composer
  out="$(adb_detect_gates "$d")"
  case "$out" in
    *"composer run-script test"*) : ;;
    *) exit 1 ;;
  esac
  case "$out" in *"composer run-script lint"*) : ;; *) exit 1 ;; esac )
yes $? "php: a declared composer script wins over vendor/bin"

# ...but ONLY when composer itself is runnable. Without it the script NAMES are unusable, so
# the gate must fall back to the binary rather than emitting `composer run-script test` as a
# gate whose first act is "command not found" — a gate that always fails is not enforcement.
d="$work/php-noc"; mkdir -p "$d"
printf '{"scripts":{"test":"phpunit"}}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpunit
( _adb_have() { case "$1" in composer) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  out="$(adb_detect_gates "$d")"
  case "$out" in
    *"composer run-script"*) exit 1 ;;
    *"vendor/bin/phpunit"*)  exit 0 ;;
    *) exit 1 ;;
  esac )
yes $? "php: no composer on PATH → the declared script is dropped for the binary"

# FORMAT MUST NOT REWRITE THE TREE. php-cs-fixer defaults to fixing in place; a gate that
# edits files turns verification into mutation, which is what makes unattended gate execution
# unsafe at all. The chosen command must carry --dry-run.
d="$work/php-fmt"; mkdir -p "$d"
printf '{"name":"a/b"}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" php-cs-fixer
out="$(adb_detect_gates "$d")"
has   "$out" "php-cs-fixer fix --dry-run" "php: format is --dry-run, never an in-place fix"
# --dry-run covers the SOURCE files; PHP CS Fixer caches by default and writes .php-cs-fixer.cache
# progressively, so without this the "non-mutating" gate still drops a file into the project —
# which is what makes running it unattended unsafe in the first place.
has   "$out" "--using-cache=no" "php: format does not write a cache file into the project"
hasnt "$out" "phpcbf"                     "php: phpcbf (no check mode) is never a gate"

# composer.json present but NOTHING runnable: the adapter must DECLINE rather than claim the
# repo with an empty record set. Claiming would be worse than not detecting — it looks
# identical to a clean project while stopping every later adapter from being consulted.
d="$work/php-bare"; mkdir -p "$d"
printf '{"name":"a/b"}\n' > "$d/composer.json"
( _adb_have() { case "$1" in composer|phpunit|phpcs|phpstan|psalm|php-cs-fixer) return 1 ;;
                            *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  out="$(adb_detect_gates "$d")"; [ -z "$out" ] )
yes $? "php: composer.json with no runnable tool detects nothing (declines, not claims)"

# Malformed composer.json must not crash or invent a gate from a key it could not parse.
d="$work/php-bad"; mkdir -p "$d"
printf '{ this is not json\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpunit
out="$(adb_detect_gates "$d" 2>/dev/null)"
hasnt "$out" "composer run-script" "php: malformed composer.json yields no script gate"
has   "$out" "vendor/bin/phpunit"  "php: malformed composer.json still finds the binary"

# ORDERING (the polyglot decision). A WordPress-shaped repo carrying BOTH manifests keeps its
# NODE gates: those are commands the project DECLARED, and replacing them with inferred PHP
# ones would silently change behaviour for every already-adopted mixed repo. This assertion is
# the one that goes red if someone later moves PHP ahead of node "to match adopt-lib stack".
d="$work/php-mixed"; mkdir -p "$d"
printf '{"scripts":{"test":"jest","lint":"eslint ."}}\n' > "$d/package.json"
printf '{"scripts":{"test":"phpunit"}}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpunit
out="$(adb_detect_gates "$d")"
has   "$out" "npm run test" "php: a mixed node+composer repo keeps its node gates"
hasnt "$out" "phpunit"      "php: a mixed repo does NOT get PHP gates layered in silently"

# An explicit override still wins over PHP detection, and "" still disables — the open set is
# the documented escape for the mixed case above, so it must actually reach a PHP repo.
d="$work/php-override"; mkdir -p "$d"
printf '{"name":"a/b"}\n' > "$d/composer.json"
php_stub "$d/vendor/bin" phpunit
printf '[gates]\ntest = "phpunit --group=fast"\nlint = ""\n' > "$d/agents.toml"
out="$(adb_detect_gates "$d")"
has   "$out" "phpunit --group=fast" "php: an agents.toml override beats detection"
hasnt "$out" "lint"                 "php: a \"\" override disables the axis"

# --- the adapter-registry contract itself (#81) -------------------------------
# AN ADAPTER THAT DECLINES MUST LEAVE NOTHING BEHIND. The five shipped adapters each happen to
# assign only on a path that also claims, so this invariant is unreachable through any real
# ecosystem today — which is exactly why it is asserted through a STUB adapter instead of left
# as a comment. The refactor from five inline `if` blocks to a registry is what makes it a
# contract at all: the next adapter someone writes will assign before its final test, and a
# leak would hand a later ecosystem's record a command from one that did not claim the repo.
#
# A comment saying "reset, so nothing leaks" is the shape self-review.md calls a guard nobody
# has seen fail. This is the fixture that makes it fail.
d="$work/eco-leak"; mkdir -p "$d"
printf '{"scripts":{"test":"jest"}}\n' > "$d/package.json"
( _ADB_ECOSYSTEMS="leaky node"
  # Assigns, then declines. Without the reset its `d_test` survives into node's record.
  # The four d_* names are the adapter contract, assigned here and read by _adb_gate_records
  # through bash's dynamic scope — invisible to shellcheck, which is what SC2034 is reporting.
  # shellcheck disable=SC2034
  _adb_eco_leaky() { d_test="LEAKED"; d_typecheck="LEAKED"; return 1; }
  out="$(adb_detect_gates "$d")"
  case "$out" in *LEAKED*) exit 1 ;; esac
  case "$out" in *"npm run test"*) exit 0 ;; *) exit 1 ;; esac )
yes $? "registry: a declining adapter's assignments never reach the next one"

# ...and the loop must STOP at the first claim, not keep walking and let a later adapter
# overwrite the winner. First-wins is the documented semantic; a loop that ran to completion
# would silently make it last-wins.
( _ADB_ECOSYSTEMS="node greedy"
  # shellcheck disable=SC2034
  _adb_eco_greedy() { d_test="OVERWROTE"; return 0; }
  out="$(adb_detect_gates "$d")"
  case "$out" in *OVERWROTE*) exit 1 ;; *"npm run test"*) exit 0 ;; *) exit 1 ;; esac )
yes $? "registry: the first claiming adapter wins and stops the walk"

# A detected PHP gate must actually RUN and BLOCK like any other, and a failing one must not
# stop the rest being attempted.
d="$work/php-run"; mkdir -p "$d"
printf '{"name":"a/b"}\n' > "$d/composer.json"
printf '[gates]\ntest = "exit 3"\nbuild = "exit 0"\n' > "$d/agents.toml"
php_stub "$d/vendor/bin" phpunit
err="$(adb_run_gates "$d" 2>&1)"; rc=$?
no  "$rc" "php: a failing gate makes run non-zero"
has "$err" 'failing gates: test' "php: the failing gate is named"

check_summary "gates"
