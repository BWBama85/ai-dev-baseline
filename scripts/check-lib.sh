# shellcheck shell=bash
# ai-dev-baseline — shared helpers for the check-*.sh scripts. In a repo whose thesis is
# single-source, its own checks shouldn't grow copy-pasted scaffolds — so all three cooperating
# helper sets live here once and every check sources what it needs:
#
#   1. grep-assert family (below) — check_init / req_fixed / req_regex / check_fail /
#      check_result: many assertions collapse to ONE boolean verdict (the anti-drift lints).
#   2. unit-test assertion family (§ further down) — ok / bad / bad_quiet / eq / yes / no /
#      has / hasnt + a pass/fail COUNTER + check_summary: the *.sh unit tests.
#   3. git fixture helpers (§ further down) — check_git + check_make_repo_pair: the throwaway
#      identity wrapper and the local+bare-origin scaffold, accounting-neutral so either family
#      can guard them.
#
# Sourced, never executed. Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks the whole
# scripts/lib dir into ~/.<agent>/scripts/lib, and check/test code must not ship into a user's
# runtime.
#
# Families 1 and 2 keep SEPARATE state (CHECK_FAIL/CHECK_LABEL vs pass/fail) and never collide;
# a single check may use one, or both (e.g. check-cleanup-enum.sh uses grep-assert accounting
# AND the git fixture). Callers touch state only through these functions, never the vars — so
# ShellCheck sees no SC2154 / "unused" false positives across the source boundary.
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

# check_summary <name> — emit the terminal "<name>: N passed, M failed" line, then exit 1 if any
# assertion failed, else print "<name>: PASS". Callers end with this instead of re-reading
# $pass/$fail (which would trip SC2154, since ShellCheck does not follow the sourced file).
check_summary() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  echo "$1: PASS"
}

# --- git fixture helpers (identity wrapper + local+bare-origin pair) --------------------------
# The check-*.sh tests each hand-rolled the same "git with a throwaway identity" wrapper and the
# same "bare origin + local repo wired to it" scaffold. Centralize only the BOILERPLATE; each
# test keeps its own topology (branch names, origin/HEAD form, merge shape, push sequence).

# check_git <dir> <git-args...> — run git in <dir> with a fixed throwaway identity and signing
# OFF, so a contributor whose global config sets commit.gpgsign=true still gets clean, unsigned
# fixture commits. Use for EVERY commit-producing fixture git call (this is what closes the
# signing gap the per-file wrappers left in some tests).
check_git() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

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
