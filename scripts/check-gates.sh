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

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/lib/project-gates.sh   # transitively sources scripts/lib/common.sh

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
eq()  { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }
yes() { if [ "$1" -eq 0 ]; then ok; else bad "$2 (expected success, rc=$1)"; fi; }
no()  { if [ "$1" -ne 0 ]; then ok; else bad "$2 (expected failure, rc=$1)"; fi; }
has() { case "$1" in *"$2"*) ok ;; *) bad "$3: [$1] missing [$2]" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3: [$1] unexpectedly contains [$2]" ;; *) ok ;; esac; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TAB="$(printf '\t')"

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

printf '\ngates: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "gates: PASS"
