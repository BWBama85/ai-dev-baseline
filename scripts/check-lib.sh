# shellcheck shell=bash
# ai-dev-baseline — shared helpers for the check-*.sh scripts.
#
# The anti-drift checks (check-fact-drift.sh, check-practice-index.sh) were each
# growing their own copy of the same "grep-assert + note + fail accumulator" scaffold.
# In a repo whose thesis is single-source, its own checks shouldn't duplicate that —
# so it lives here once and they source it.
#
# Sourced, never executed. Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks
# the whole scripts/lib dir into ~/.<agent>/scripts/lib, and check/test code must not
# ship into a user's runtime.
#
# A sourcing script calls check_init "<name>" to set the message prefix, then uses
# req_fixed / req_regex (or check_fail directly) to accumulate failures, and
# check_result to emit the final PASS line and return the right status. Callers touch
# state only through these functions, never the vars — so shellcheck sees no
# "unused" false positives across the source boundary.

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
