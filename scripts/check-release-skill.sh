#!/usr/bin/env bash
# ai-dev-baseline — offline regression tests for THIS PROJECT'S release predicates (D14).
#
# Subject: `.claude/skills/release/release-lib.sh` — the project-scoped library behind `/release`.
#
# WHY A CHECK FOR A PROJECT-SCOPED SKILL. `/release`'s first cut lived entirely in SKILL.md prose,
# and two review rounds found 17 defects in it — one fatal. `selfcheck` was GREEN for all of them,
# because nothing in the harness reads `.claude/skills/`. A green gate that cannot see the change
# it is gating is worse than no gate: it reads as evidence. This closes that for the one skill in
# the repo that performs an irreversible act (a merge and a pushed tag).
#
# EVERY CASE BELOW IS A REGRESSION, not a hypothetical. Each maps to a defect that was actually
# written and shipped into review:
#   * `1x1x0` satisfying an unescaped `grep` pattern for `1.1.0`
#   * a link ref accepted while comparing the WRONG previous tag
#   * a non-empty `[Unreleased]` passing the stamp assertions
#   * `v1.2.3-rc1` / `v1x.2.3` / `v1.2.3.4` passing a shell-glob "validator"
#   * a reused version accepted, then unable to tag after the stamp had already merged
#   * an EMPTY check-run set read as "all checks complete"
#   * the currently-registered set read as the whole set, while CI was still registering jobs
#
# The general version of this — executing inline snippets from any project-scoped skill — is #190.
# This file covers the predicates; it does not execute SKILL.md's remaining prose.
#
# Usage: bash scripts/check-release-skill.sh   (exit 0 = pass, 1 = fail)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RL="$ROOT/.claude/skills/release/release-lib.sh"
SKILL="$ROOT/.claude/skills/release/SKILL.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

[ -f "$RL" ] || { printf 'FAIL: %s missing\n' "$RL" >&2; exit 1; }

run() { bash "$RL" "$@"; }          # stdout+stderr to caller, status preserved
rc_of() { bash "$RL" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# =================================================================================================
# version-ok
# =================================================================================================

# --- format: the shell-glob validator accepted all of these -------------------------------------
eq "$(printf '' | rc_of version-ok v1.2.3)"      0 "v1.2.3 with no prior versions is valid"
eq "$(printf '' | rc_of version-ok v1.2.3-rc1)"  2 "v1.2.3-rc1 rejected (glob accepted it)"
eq "$(printf '' | rc_of version-ok v1x.2.3)"     2 "v1x.2.3 rejected (glob accepted it)"
eq "$(printf '' | rc_of version-ok v1.2.3.4)"    2 "v1.2.3.4 rejected (4 components)"
eq "$(printf '' | rc_of version-ok v1.2)"        2 "v1.2 rejected (2 components)"
eq "$(printf '' | rc_of version-ok 1.2.3)"       2 "1.2.3 rejected (no leading v)"
eq "$(printf '' | rc_of version-ok v1.02.3)"     2 "v1.02.3 rejected (leading zero)"
eq "$(printf '' | rc_of version-ok v.2.3)"       2 "v.2.3 rejected (empty component)"
eq "$(printf '' | rc_of version-ok v0.0.0)"      0 "v0.0.0 is well-formed"

# --- reuse: the case that stamps main for a release that can never be tagged ---------------------
eq "$(printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.1.0)" 3 "exact reuse rejected"
eq "$(printf '1.0.0\n1.1.0\n'   | rc_of version-ok v1.1.0)" 3 "reuse rejected across bare/v forms"

# --- ordering -----------------------------------------------------------------------------------
eq "$(printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.2.0)" 0 "newer than the max is accepted"
eq "$(printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.0.5)" 4 "older than the max is rejected"
eq "$(printf 'v1.10.0\nv1.9.0\n' | rc_of version-ok v1.11.0)" 0 "numeric (not lexical) comparison: 1.11 > 1.10"
eq "$(printf 'v1.10.0\n'         | rc_of version-ok v1.9.0)"  4 "numeric (not lexical): 1.9 < 1.10 rejected"
# Unsorted input must not change the verdict — the max is computed, not assumed to be last.
eq "$(printf 'v1.1.0\nv1.0.0\nv0.9.0\n' | rc_of version-ok v1.0.5)" 4 "max is computed regardless of input order"
eq "$(printf '\n  \nv1.0.0\n'    | rc_of version-ok v1.1.0)" 0 "blank lines ignored"
has "$(printf 'v1.2.3\n' | run version-ok v1.3.0 2>&1)" "1.3.0" "prints the bare version on success"

# =================================================================================================
# changelog-verify
# =================================================================================================
SLUG="BWBama85/ai-dev-baseline"; TODAY="2026-07-28"; BASE="https://github.com/$SLUG"

good_cl() {   # <version> <last>
  printf '# Changelog\n\n## [Unreleased]\n\n## [%s] - %s\n\ntext\n\n' "${1#v}" "$TODAY"
  printf '[Unreleased]: %s/compare/%s...HEAD\n' "$BASE" "$1"
  if [ -n "$2" ]; then printf '[%s]: %s/compare/%s...%s\n' "${1#v}" "$BASE" "$2" "$1"
  else printf '[%s]: %s/releases/tag/%s\n' "${1#v}" "$BASE" "$1"; fi
}

eq "$(good_cl v1.2.0 v1.1.0 | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY")" 0 "well-formed stamp passes"
eq "$(good_cl v1.0.0 ''     | rc_of changelog-verify v1.0.0 ''     "$SLUG" "$TODAY")" 0 "first release uses releases/tag"

# THE METACHARACTER REGRESSION: `1x1x0` must not satisfy a check for `1.1.0`.
printf '# Changelog\n\n## [Unreleased]\n\n## [1x1x0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.1.0...HEAD\n[1.1.0]: %s/compare/v1.0.0...v1.1.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-meta.$$
eq "$(rc_of changelog-verify v1.1.0 v1.0.0 "$SLUG" "$TODAY" < /tmp/adb-cl-meta.$$)" 5 "1x1x0 does not satisfy the 1.1.0 heading"
rm -f /tmp/adb-cl-meta.$$

# THE WRONG-PREVIOUS-TAG REGRESSION: comparing from v1.0.0 when v1.1.0 is the previous release.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.0.0...v1.2.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-prev.$$
eq "$(rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-prev.$$)" 5 "wrong previous tag in the compare ref is rejected"
rm -f /tmp/adb-cl-prev.$$

# THE NON-EMPTY [Unreleased] REGRESSION.
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- leftover\n\n## [1.2.0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.1.0...v1.2.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-full.$$
eq "$(rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-full.$$)" 5 "non-empty [Unreleased] is rejected"
rm -f /tmp/adb-cl-full.$$

# Misdated heading, and a missing [Unreleased] ref.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - 2020-01-01\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.1.0...v1.2.0\n' \
  "$BASE" "$BASE" > /tmp/adb-cl-date.$$
eq "$(rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-date.$$)" 5 "misdated version heading is rejected"
rm -f /tmp/adb-cl-date.$$
eq "$(printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - %s\n\ntext\n' "$TODAY" \
      | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY")" 5 "missing link refs are rejected"
# A first-release shape must NOT satisfy a subsequent release (and vice versa).
eq "$(good_cl v1.2.0 '' | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY")" 5 "releases/tag shape rejected when a previous tag exists"

# =================================================================================================
# checks-settled
# =================================================================================================
runs() {   # <n-completed> <n-pending>
  printf '{"check_runs":['
  i=0; sep=""
  while [ "$i" -lt "$1" ]; do printf '%s{"name":"c%s","status":"completed"}' "$sep" "$i"; sep=","; i=$((i+1)); done
  i=0
  while [ "$i" -lt "$2" ]; do printf '%s{"name":"p%s","status":"in_progress"}' "$sep" "$i"; sep=","; i=$((i+1)); done
  printf ']}'
}

# THE EMPTY-SET REGRESSION: zero check runs is "CI has not registered", never "all complete".
eq "$(runs 0 0  | rc_of checks-settled 26)" 7 "empty check-run set is 'none', not settled"
has "$(runs 0 0 | run checks-settled 26 2>&1)" "none" "empty set reports none"

# THE INCREMENTAL-REGISTRATION REGRESSION: a fast check completing before its siblings appear.
eq "$(runs 1 0  | rc_of checks-settled 26)" 8 "1 complete of 26 expected is 'short', not settled"
has "$(runs 1 0 | run checks-settled 26 2>&1)" "short" "partial registration reports short"

eq "$(runs 20 6 | rc_of checks-settled 26)" 6 "still-running checks report pending"
eq "$(runs 26 0 | rc_of checks-settled 26)" 0 "full complete set is settled"
eq "$(runs 30 0 | rc_of checks-settled 26)" 0 "MORE checks than expected is settled (a job was added)"
eq "$(runs 26 0 | rc_of checks-settled 0)"  0 "expected=0 with real checks is settled"
eq "$(runs 0 0  | rc_of checks-settled 0)"  7 "expected=0 with NO checks is still 'none' (fail closed)"
# Paginated input: --paginate concatenates one document per page.
eq "$(printf '%s\n%s\n' "$(runs 13 0)" "$(runs 13 0)" | rc_of checks-settled 26)" 0 "paginated pages are summed"
# A malformed body must be a usage error, never a silent 'settled'.
eq "$(printf 'not json' | rc_of checks-settled 26)" 2 "malformed JSON is an error, not settled"

# =================================================================================================
# Boundary invariants — the library must not drift back into the baseline, and the skill must
# keep delegating rather than re-deriving.
# =================================================================================================
check_init "release-skill"
# D7: nothing generic may appear under scripts/lib. `adb_agent_manifest` links that whole dir into
# every install, so a release predicate landing there ships release machinery to every adopter.
if [ -e "$ROOT/scripts/lib/release-lib.sh" ]; then
  check_note "scripts/lib/release-lib.sh exists — that installs into EVERY adopting repo (common.sh:175)"
  check_note "and reverses #3/D7 by accident. This project's release predicates belong beside its skill."
  check_fail
fi
# THE FATAL DEFECT: a build placeholder pasted into a RUNNABLE step.
#
# Scanned only INSIDE fenced code blocks. A `{{ROADMAP_LIB}}` in prose is the skill *explaining*
# why the placeholder is dangerous — documentation, not an assertion. Flagging that is the #117
# over-match this repo has now fixed three times (#69 bare mention, #108 negated, #117 fenced), and
# the first version of this very check reproduced it: it failed on the paragraph describing the bug.
PLACEHOLDER_HIT="$(awk '
  /^[[:space:]]*```/ { infence = !infence; next }
  infence && /\{\{[A-Z_]+\}\}/ { print FILENAME ":" FNR ": " $0 }
' "$SKILL" 2>/dev/null)"
if [ -n "$PLACEHOLDER_HIT" ]; then
  check_note "a {{PLACEHOLDER}} appears inside a RUNNABLE fenced block:"
  check_note "$PLACEHOLDER_HIT"
  check_note "Only scripts/build.sh substitutes those, and it does not render project-scoped"
  check_note "skills — so this is a command-not-found at release time. This is the fatal defect"
  check_note "review round 1 found; the check exists so it cannot come back."
  check_fail
fi
# Do not re-derive predicates that already have a tested home.
req_fixed "$SKILL" 'marker-title'      skill-uses-marker-title-predicate
req_fixed "$SKILL" 'release-ready'     skill-uses-readiness-predicate
req_fixed "$SKILL" 'branch-health'     skill-uses-branch-health-predicate
req_fixed "$SKILL" 'match-head-commit' skill-pins-the-merge-to-the-reviewed-head
req_fixed "$SKILL" 'mergeCommit'       skill-tags-the-prs-own-merge-commit
# BRIDGE THE TWO ACCOUNTINGS. `check_result` RETURNS non-zero; `check_summary` exits on its own
# pass/fail counter. Leaving them unjoined made this script report the boundary failures and then
# exit 0 — a gate that prints diagnostics and passes anyway, which is the exact "green tells you
# nothing" failure this file was written to close. `bad_quiet` folds the boolean into the counter
# without reprinting (check_note already emitted the detail).
check_result "release skill delegates its decisions and stays out of the installed lib dir" || bad_quiet

check_summary "release-skill"
