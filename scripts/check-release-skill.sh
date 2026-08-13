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
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RL="$ROOT/.claude/skills/release/release-lib.sh"
SKILL="$ROOT/.claude/skills/release/SKILL.md"
DRV="$ROOT/.claude/skills/release/release.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary
# shellcheck source=/dev/null
. scripts/lib/common.sh  # _ADB_MD_AWK — the ONE fence rule (#136); this file used to carry a copy

[ -f "$RL" ] || { printf 'FAIL: %s missing\n' "$RL" >&2; exit 1; }

# The throwaway root for the driver fixture built at the bottom of this file (#313), created here
# so ONE EXIT trap covers the whole suite. `check_exit_guard` is what makes that trap fail closed:
# a suite's exit status is its LAST command's, and only `check_summary` ever consults the `fail`
# counter — so a truncating edit or a stray early `exit` would print every FAIL: line and still be
# reported as passing. Installing our own bare `trap … EXIT` for the cleanup would have replaced
# that guard rather than joined it, which is why the cleanup is passed IN.
work="$(mktemp -d)"
check_exit_guard "release-skill" "rm -rf \"$work\""

run() { bash "$RL" "$@"; }          # stdout+stderr to caller, status preserved
rc_of() { bash "$RL" "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# =================================================================================================
# version-ok
# =================================================================================================

# --- format: the shell-glob validator accepted all of these -------------------------------------
eq "${ printf '' | rc_of version-ok v1.2.3; }"      0 "v1.2.3 with no prior versions is valid"
eq "${ printf '' | rc_of version-ok v1.2.3-rc1; }"  2 "v1.2.3-rc1 rejected (glob accepted it)"
eq "${ printf '' | rc_of version-ok v1x.2.3; }"     2 "v1x.2.3 rejected (glob accepted it)"
eq "${ printf '' | rc_of version-ok v1.2.3.4; }"    2 "v1.2.3.4 rejected (4 components)"
eq "${ printf '' | rc_of version-ok v1.2; }"        2 "v1.2 rejected (2 components)"
eq "${ printf '' | rc_of version-ok 1.2.3; }"       2 "1.2.3 rejected (no leading v)"
eq "${ printf '' | rc_of version-ok v1.02.3; }"     2 "v1.02.3 rejected (leading zero)"
eq "${ printf '' | rc_of version-ok v.2.3; }"       2 "v.2.3 rejected (empty component)"
eq "${ printf '' | rc_of version-ok v0.0.0; }"      0 "v0.0.0 is well-formed"

# --- reuse: the case that stamps main for a release that can never be tagged ---------------------
eq "${ printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.1.0; }" 3 "exact reuse rejected"
eq "${ printf '1.0.0\n1.1.0\n'   | rc_of version-ok v1.1.0; }" 3 "reuse rejected across bare/v forms"

# --- ordering -----------------------------------------------------------------------------------
eq "${ printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.2.0; }" 0 "newer than the max is accepted"
eq "${ printf 'v1.0.0\nv1.1.0\n' | rc_of version-ok v1.0.5; }" 4 "older than the max is rejected"
eq "${ printf 'v1.10.0\nv1.9.0\n' | rc_of version-ok v1.11.0; }" 0 "numeric (not lexical) comparison: 1.11 > 1.10"
eq "${ printf 'v1.10.0\n'         | rc_of version-ok v1.9.0; }"  4 "numeric (not lexical): 1.9 < 1.10 rejected"
# Unsorted input must not change the verdict — the max is computed, not assumed to be last.
eq "${ printf 'v1.1.0\nv1.0.0\nv0.9.0\n' | rc_of version-ok v1.0.5; }" 4 "max is computed regardless of input order"
eq "${ printf '\n  \nv1.0.0\n'    | rc_of version-ok v1.1.0; }" 0 "blank lines ignored"
has "${ printf 'v1.2.3\n' | run version-ok v1.3.0 2>&1; }" "1.3.0" "prints the bare version on success"

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

eq "${ good_cl v1.2.0 v1.1.0 | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY"; }" 0 "well-formed stamp passes"
eq "${ good_cl v1.0.0 ''     | rc_of changelog-verify v1.0.0 ''     "$SLUG" "$TODAY"; }" 0 "first release uses releases/tag"

# THE METACHARACTER REGRESSION: `1x1x0` must not satisfy a check for `1.1.0`.
printf '# Changelog\n\n## [Unreleased]\n\n## [1x1x0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.1.0...HEAD\n[1.1.0]: %s/compare/v1.0.0...v1.1.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-meta.$$
eq "${ rc_of changelog-verify v1.1.0 v1.0.0 "$SLUG" "$TODAY" < /tmp/adb-cl-meta.$$; }" 5 "1x1x0 does not satisfy the 1.1.0 heading"
rm -f /tmp/adb-cl-meta.$$

# THE WRONG-PREVIOUS-TAG REGRESSION: comparing from v1.0.0 when v1.1.0 is the previous release.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.0.0...v1.2.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-prev.$$
eq "${ rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-prev.$$; }" 5 "wrong previous tag in the compare ref is rejected"
rm -f /tmp/adb-cl-prev.$$

# THE NON-EMPTY [Unreleased] REGRESSION.
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- leftover\n\n## [1.2.0] - %s\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.1.0...v1.2.0\n' \
  "$TODAY" "$BASE" "$BASE" > /tmp/adb-cl-full.$$
eq "${ rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-full.$$; }" 5 "non-empty [Unreleased] is rejected"
rm -f /tmp/adb-cl-full.$$

# Misdated heading, and a missing [Unreleased] ref.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - 2020-01-01\n\ntext\n\n[Unreleased]: %s/compare/v1.2.0...HEAD\n[1.2.0]: %s/compare/v1.1.0...v1.2.0\n' \
  "$BASE" "$BASE" > /tmp/adb-cl-date.$$
eq "${ rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY" < /tmp/adb-cl-date.$$; }" 5 "misdated version heading is rejected"
rm -f /tmp/adb-cl-date.$$
eq "$(printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - %s\n\ntext\n' "$TODAY" \
      | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY")" 5 "missing link refs are rejected"
# A first-release shape must NOT satisfy a subsequent release (and vice versa).
eq "${ good_cl v1.2.0 '' | rc_of changelog-verify v1.2.0 v1.1.0 "$SLUG" "$TODAY"; }" 5 "releases/tag shape rejected when a previous tag exists"

# =================================================================================================
# checks-settled
# =================================================================================================
runs_named() {   # <name-prefix> <n-completed> <n-pending>
  # `local`, for the same reason rc_snip in check-roadmap-e2e.sh now declares its own (#259):
  # `i` and `sep` were plain globals, and the only thing keeping them out of the caller was the
  # `$( )` subshell every call site happened to wrap them in. `${ command; }` runs in the CURRENT
  # shell, so a loop counter named `i` anywhere above would have been silently reset mid-loop.
  local pfx i sep
  pfx="$1"
  printf '{"check_runs":['
  i=0; sep=""
  while [ "$i" -lt "$2" ]; do printf '%s{"name":"%s%s","status":"completed"}' "$sep" "$pfx" "$i"; sep=","; i=$((i+1)); done
  i=0
  while [ "$i" -lt "$3" ]; do printf '%s{"name":"p%s","status":"in_progress"}' "$sep" "$i"; sep=","; i=$((i+1)); done
  printf ']}'
}

runs() { runs_named c "$1" "$2"; }

dup_runs() {   # <n-distinct> -> each name TWICE, all completed (the PR-head shape)
  # The shape a PR branch head actually has when one workflow carries both an unfiltered `push:`
  # and a `pull_request:` trigger. Deliberately built as ONE document rather than two pages, so it
  # cannot be mistaken for the pagination fixture above.
  local i sep
  printf '{"check_runs":['
  i=0; sep=""
  while [ "$i" -lt "$1" ]; do
    printf '%s{"name":"c%s","status":"completed"},{"name":"c%s","status":"completed"}' "$sep" "$i" "$i"
    sep=","; i=$((i+1))
  done
  printf ']}'
}

# THE EMPTY-SET REGRESSION: zero check runs is "CI has not registered", never "all complete".
eq "${ runs 0 0  | rc_of checks-settled 26; }" 7 "empty check-run set is 'none', not settled"
has "${ runs 0 0 | run checks-settled 26 2>&1; }" "none" "empty set reports none"

# THE INCREMENTAL-REGISTRATION REGRESSION: a fast check completing before its siblings appear.
eq "${ runs 1 0  | rc_of checks-settled 26; }" 8 "1 complete of 26 expected is 'short', not settled"
has "${ runs 1 0 | run checks-settled 26 2>&1; }" "short" "partial registration reports short"

eq "${ runs 20 6 | rc_of checks-settled 26; }" 6 "still-running checks report pending"
eq "${ runs 26 0 | rc_of checks-settled 26; }" 0 "full complete set is settled"
eq "${ runs 30 0 | rc_of checks-settled 26; }" 0 "MORE checks than expected is settled (a job was added)"
eq "${ runs 26 0 | rc_of checks-settled 0; }"  0 "expected=0 with real checks is settled"
eq "${ runs 0 0  | rc_of checks-settled 0; }"  7 "expected=0 with NO checks is still 'none' (fail closed)"
# Paginated input: --paginate concatenates one document per page. The pages must carry DISTINCT
# names, because a real paginated response does — two pages of the same 13 runs is not pagination,
# it is the duplicate-name case pinned immediately below, and conflating the two is what let the
# raw-count bar look correct.
eq "${ printf '%s\n%s\n' "${ runs 13 0; }" "${ runs_named d 13 0; }" | rc_of checks-settled 26; }" 0 "paginated pages are summed"
# A malformed body must be a usage error, never a silent 'settled'.
eq "${ printf 'not json' | rc_of checks-settled 26; }" 2 "malformed JSON is an error, not settled"

# THE TWO-TRIGGER REGRESSION (v2.0.0 — the bar was recorded on a commit class that cannot match).
# A workflow carrying an unfiltered `push:` AND a `pull_request:` trigger gives a PR branch head
# BOTH runs of every job, so each name appears twice, while the merge commit on the default branch
# receives only the `push:` run. Live numbers from the v2.0.0 cut, when this repo's `ci.yml` was
# shaped that way: reviewed head 25cca85 = 54 runs over 27 names; merge commit 1c02f24 = 27 runs
# over the SAME 27 names, all successful. Counting raw runs made `verify-merge` demand >= 54 on a
# commit that can only ever have 27 — unreachable, so it burned its full 90 iterations and refused
# to tag a genuinely green release.
#
# THE FIXTURES BELOW STAY, and this repo's own trigger no longer produces the doubled shape (#165
# filtered `push:` to `main`). They are not describing this repo — they are pinning the invariant
# for any repo that runs this library, and a re-run duplicates a name everywhere regardless of
# triggers. A test deleted because THIS repo stopped exercising the input is a test that was
# guarding the wrong thing.
#
# The bar recorded from the PR head must therefore be the DISTINCT-NAME count...
eq "${ dup_runs 27 | run checks-settled 0; }" "settled 27/0" "a doubled PR-head set counts its distinct names, not its runs"
# ...and the merge commit's single set must then SATISFY that bar rather than read short.
eq "${ runs 27 0 | rc_of checks-settled 27; }" 0 "the merge commit's single set satisfies a bar taken from the doubled head"
# The hazard the bar exists for is untouched: a genuinely MISSING job still reads short, because an
# incrementally-registering set has fewer NAMES, not fewer duplicates.
eq "${ dup_runs 26 | rc_of checks-settled 27; }" 8 "a job missing from the doubled set is still short"
eq "${ runs 26 0 | rc_of checks-settled 27; }" 8 "a job missing from the single set is still short"
# A duplicate whose second run is still going is pending, not settled — a re-run in flight must not
# be collapsed away by the dedup. The second document repeats a name the first already carried, so
# the distinct-name count stays 27 and only the pending arm can catch it.
eq "${ printf '%s\n{"check_runs":[{"name":"c0","status":"in_progress"}]}\n' "${ runs 27 0; }" | rc_of checks-settled 27; }" 6 "an in-flight duplicate run still reports pending"

# --- version-ok: the empty-component family ------------------------------------------------------
# A TRAILING dot is the one the component loop cannot see: it consumes 1, 2, 3, then `${rest#*.}`
# yields "" and the loop exits with n=3. `v1.2.3.` therefore validated and would have been written
# into the changelog and used as a permanent tag.
eq "${ printf '' | rc_of version-ok v1.2.3.; }"  2 "trailing dot rejected"
eq "${ printf '' | rc_of version-ok v.1.2.3; }"  2 "leading dot rejected"
eq "${ printf '' | rc_of version-ok v1..2.3; }"  2 "doubled dot rejected"
eq "${ printf '' | rc_of version-ok v1.2.3..; }" 2 "doubled trailing dot rejected"
# The success path must still print a version with NO trailing dot.
eq "${ printf '' | run version-ok v1.2.3 2>/dev/null; }" "1.2.3" "valid version echoes cleanly"

# --- unreleased-entries: the pre-stamp emptiness refusal ------------------------------------------
# `changelog-verify` cannot cover this — it only sees the POST-edit file, where [Unreleased] is
# empty by construction. Before this predicate the refusal was prose only, so an agent that skipped
# the sentence could stamp a version over nothing and push an irreversible tag with 37 green tests.
ue() { printf '%s' "$1" | bash "$RL" unreleased-entries >/dev/null 2>&1; printf '%s' "$?"; }
eq "$(ue '## [Unreleased]

### Added

- a real entry

## [1.1.0] - 2026-07-28
')" 0 "entries present -> ok"
eq "$(ue '## [Unreleased]

## [1.1.0] - 2026-07-28
')" 9 "empty [Unreleased] -> nothing to release"
eq "$(ue '## [Unreleased]

### Added

## [1.1.0] - 2026-07-28
')" 9 "a bare subsection heading is not an entry"
eq "$(ue '## [Unreleased]

<!-- a comment is not an entry -->

## [1.1.0] - 2026-07-28
')" 9 "a comment is not an entry"
eq "$(printf '## [Unreleased]\n\n- one\n- two\n\n## [1.0.0] - 2026-01-01\n' \
      | run unreleased-entries 2>/dev/null)" "2" "counts entries"
# Entries must be counted ONLY inside the [Unreleased] block, never from a released section.
eq "$(ue '## [Unreleased]

## [1.1.0] - 2026-07-28

### Added

- this belongs to a SHIPPED release
')" 9 "entries in a released section do not count"

# =================================================================================================
# Block self-containment — the structural guard for the class that produced a P1.
#
# This repo has TWO opposite execution models for fenced blocks, and neither is discoverable from
# the block itself: `base/workflows/roadmap.md` states its blocks "may be run as SEPARATE shell
# invocations that share no variables", while `base/workflows/cleanup.md` states "THIS WORKFLOW IS
# ONE SHELL". The first cut of this skill silently assumed cleanup's model while resembling
# roadmap's — so `$LIB`, `$ROOT`, `$SLUG`, `$TMPD` and `$RLIB` were carried across blocks, and under
# roadmap's model the very first use expands to empty and stops every release.
#
# Prose cannot fix that, because the assumption is invisible. This asserts it instead: every
# variable a fenced block READS must be assigned in that SAME block (or be an environment/shell
# name). It is what makes "self-contained" a checked property rather than an intention.
# =================================================================================================
# The awk program contains NO literal single quote: the quote is passed in with -v Q, and the
# single-quoted-region regex is built from it. Embedding one directly inside this single-quoted
# shell string requires '"'"'-style escaping, which broke the program's syntax — and a crashed awk
# prints nothing, so SC_VIOLATIONS was empty and this check PASSED VACUOUSLY. That is the same
# "green because nothing ran" failure the file exists to close, so the status is now fatal.
SC_RC=0
SC_VIOLATIONS="$(awk -v Q="'" '
  BEGIN {
    split("HOME PATH PWD TMPDIR SHELL USER LOGNAME EDITOR IFS OLDPWD RANDOM LINENO", a, " ")
    for (i in a) allow[a[i]] = 1
    SQ = Q "[^" Q "]*" Q
  }
  /^[[:space:]]*```bash/ { inblock = 1; blockstart = FNR; delete assigned; delete used; next }
  /^[[:space:]]*```/ {
    if (inblock) {
      for (u in used) if (!(u in assigned) && !(u in allow)) printf "%d:%s\n", blockstart, u
      inblock = 0
    }
    next
  }
  inblock {
    line = $0
    sub(/#.*$/, "", line)
    # Drop SINGLE-QUOTED regions. Not a heuristic: the shell does not expand inside single quotes,
    # so jq --arg t "$X" ... $t ... reads no shell variable named t.
    while (match(line, SQ)) { line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH) }
    # Assignments anywhere a command can START: line head, or after ; & | ( ) { } do then else.
    # A head-anchored match alone misses X="$(...)"; RC=$? and A=0; B=1; i=0.
    rest2 = line
    while (match(rest2, /(^[[:space:]]*|[;&|(){}][[:space:]]*|[[:space:]](do|then|else)[[:space:]]+)[A-Za-z_][A-Za-z0-9_]*=/)) {
      seg = substr(rest2, RSTART, RLENGTH)
      # Take the TRAILING identifier. A greedy sub of everything up to the last non-word char eats
      # the name itself and registers nothing, so every assignment would look undefined.
      nm = seg; sub(/=$/, "", nm)
      if (match(nm, /[A-Za-z_][A-Za-z0-9_]*$/)) { assigned[substr(nm, RSTART, RLENGTH)] = 1 }
      rest2 = substr(rest2, RSTART + RLENGTH)
    }
    if (line ~ /(^|[^A-Za-z0-9_])read([[:space:]]+-[A-Za-z]+)*[[:space:]]/) {
      n = split(line, toks, /[^A-Za-z0-9_]+/)
      for (i = 1; i <= n; i++) if (toks[i] ~ /^[A-Z][A-Z0-9_]*$/) assigned[toks[i]] = 1
    }
    if (line ~ /for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in/) {
      m = line; sub(/^.*for[[:space:]]+/, "", m); sub(/[[:space:]]+in.*$/, "", m); assigned[m] = 1
    }
    s = line
    while (match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
      nm = substr(s, RSTART, RLENGTH); sub(/^\$\{?/, "", nm); used[nm] = 1
      s = substr(s, RSTART + RLENGTH)
    }
  }
' "$SKILL")" || SC_RC=$?
if [ "$SC_RC" -ne 0 ]; then
  printf 'FAIL: the block self-containment scanner did not run (awk exit %s).\n' "$SC_RC" >&2
  printf '  An extractor that crashes prints nothing, which would read as "no violations".\n' >&2
  bad_quiet
elif [ -n "$SC_VIOLATIONS" ]; then
  printf 'FAIL: SKILL.md fenced blocks read variables they do not define:\n' >&2
  printf '%s\n' "$SC_VIOLATIONS" | sed 's/^/  line /' >&2
  printf '  Each ```bash block must re-resolve what it needs — the two workflow families in this\n' >&2
  printf '  repo disagree about shell-session sharing, so carrying state across blocks is a bug.\n' >&2
  bad_quiet
else
  ok
fi

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
#
# The fence rule is SOURCED, not restated (#136). The toggle this replaced fired on any ``` after
# 0-3 spaces: it ignored the delimiter character, the run length, a trailing closer, and container
# columns — so a `~~~` block was invisible to it and a short closer inverted the flag for the rest
# of the file. This check's polarity is INVERTED from the roadmap consumers (it wants what is
# inside a fence, not what is outside one), which is exactly why the shared primitive is a
# `adb_md_fence_delim` predicate plus the `md_fence_len` flag rather than a whole sanitizer.
# The explicit `0` is the CONTAINER COLUMN (#252, D42): this scan calls the fence predicate
# directly rather than driving `adb_md_block`, so it tracks no list container and every fence it
# sees is top-level — unchanged from before that column existed, and said at the call site instead
# of inherited from awk's uninitialized-parameter rule.
PLACEHOLDER_HIT="$(LC_ALL=C awk "$_ADB_MD_AWK"'
  { if (adb_md_fence_delim($0, 0)) next }
  md_fence_len && /\{\{[A-Z_]+\}\}/ { print FILENAME ":" FNR ": " $0 }
' "$SKILL" 2>/dev/null)"
if [ -n "$PLACEHOLDER_HIT" ]; then
  check_note "a {{PLACEHOLDER}} appears inside a RUNNABLE fenced block:"
  check_note "$PLACEHOLDER_HIT"
  check_note "Only scripts/build.sh substitutes those, and it does not render project-scoped"
  check_note "skills — so this is a command-not-found at release time. This is the fatal defect"
  check_note "review round 1 found; the check exists so it cannot come back."
  check_fail
fi
# THE DOCUMENTED REGENERATION COMMAND MUST CARRY THE SAME `tar.umask` PIN THE DRIVER DOES (#284).
#
# SKILL.md publishes a two-line recipe for rebuilding the release artifact and checking its digest.
# `git archive` takes mode bits from `tar.umask`, which is settable per-repo and per-user, so a
# recipe missing the pin produces a DIFFERENT archive for a maintainer whose config differs — and
# the advertised verification then reports a perfectly good release as corrupt. A verification
# procedure that can raise a false alarm is worse than none, which is why it is gated rather than
# left to review.
#
# SCANNED INSIDE FENCED BLOCKS ONLY, through the shared fence predicate (#136). Prose is allowed to
# discuss `git archive`; a runnable block is what a reader copies. The `0` is the container column,
# as in the placeholder scan above.
ARCHIVE_UNPINNED="$(LC_ALL=C awk "$_ADB_MD_AWK"'
  { if (adb_md_fence_delim($0, 0)) next }
  md_fence_len && /git .*archive/ && !/tar\.umask=/ { print FILENAME ":" FNR ": " $0 }
' "$SKILL" 2>/dev/null)"
if [ -n "$ARCHIVE_UNPINNED" ]; then
  check_note "a documented 'git archive' command omits the tar.umask pin the driver uses:"
  check_note "$ARCHIVE_UNPINNED"
  check_note "git honours tar.umask per-repo and per-user, so this recipe would regenerate a"
  check_note "different archive and report a valid release as mismatched."
  check_fail
fi

# The DRIVER is where the shell lives now, so the delegation invariants assert against it.
req_fixed "$DRV" 'marker-title'      driver-uses-marker-title-predicate
req_fixed "$DRV" 'release-ready'     driver-uses-readiness-predicate
req_fixed "$DRV" 'branch-health'     driver-uses-branch-health-predicate
# THE HEALTH DECLARATION, PINNED LINE BY LINE (#293). This suite is STATIC by design — it never
# executes the driver — so "does the marker reach the predicate" can only be asserted as the
# presence of the statements that carry it. Independent review found the first version of this
# pinned only the token `health-decl`, which also appears in four comment lines: the call could be
# deleted, or the resolution replaced with a hardcoded `off`, and the suite stayed green. Each pin
# below is a load-bearing STATEMENT, so each of those mutations goes red.
#
# Why the driver consults the marker at all: before #293 `no-ci` was INFERRED, so a CI-less repo
# reached `case green|no-ci` in verify-merge and tagged. Now it is DECLARED — a driver that passed
# `off` unconditionally would answer `indeterminate` for that repo and refuse to ever tag it.
req_fixed "$DRV" 'health-optout'                     driver-reads-the-marker-with-the-shared-predicate
req_fixed "$DRV" 'health-decl "$hraw" "$hperm"'      driver-resolves-authority-with-the-shared-predicate
req_fixed "$DRV" 'collaborators/$rauthor/permission' driver-rechecks-the-artifact-authors-permission
req_fixed "$DRV" 'rset HEALTH_DECL'                  driver-pins-the-declaration-in-run-state
req_fixed "$DRV" 'rs HEALTH_DECL'                    driver-consumes-the-pinned-declaration
req_fixed "$DRV" 'branch-health "$sha" "$wf" "$hd"'  driver-passes-the-declaration-to-the-predicate
# THE ASYMMETRY IS THE RELEASE-SAFETY HALF, and it is one line: `no-ci` is honoured, everything
# else — `skip-unreported` above all — is flattened to `off`. Deleting it would let this driver TAG
# a commit on a repo whose CI exists and simply never reported, which is precisely what D45 gave it
# a stricter policy than /roadmap's to prevent.
req_fixed "$DRV" '"$hd" = "no-ci"'                   driver-honours-only-no-ci-never-skip-unreported
req_fixed "$DRV" 'match-head-commit' driver-pins-the-merge-to-the-reviewed-head
req_fixed "$DRV" 'mergeCommit'       driver-tags-the-prs-own-merge-commit
req_fixed "$DRV" 'adb_version_ge'    driver-uses-the-shared-comparator
req_fixed "$DRV" 'assert_role'       driver-keeps-the-release-role-guard
req_fixed "$DRV" 'exit-code'         driver-verifies-the-remote-tag-with-exit-code
# STRUCTURAL, and labelled as such (#284). `git archive` honours `tar.umask`, which is settable
# per-repo and per-user, so two machines with the same git and gzip emit different mode headers and
# different digests without it. A RUN cannot distinguish a pinned umask from a host whose config
# happens to agree, so this asserts how the command is WRITTEN — weaker than driving it, and said
# rather than implied.
# AGAINST COMMENT-STRIPPED SOURCE, because both of these strings appear in the prose that explains
# them. A `req_fixed` over the whole file is satisfied by the comment, so deleting the actual flag
# left the pin green — measured: removing `-c tar.umask=0022` from the archive command produced
# 300 passed, 0 failed. That is the same "the check matched its own documentation" defect the
# `$(slug)` and `need` scanners above already strip comments to avoid.
DRV_CODE="$(sed 's/#.*//' "$DRV")"
case "$DRV_CODE" in
  *'tar.umask=0022'*) ok ;;
  *) bad "release.sh does not pin tar.umask in live code — git honours per-repo/per-user config, so the archive digest would vary by machine" ;;
esac
case "$DRV_CODE" in
  *'--verify-tag'*) ok ;;
  *) bad "release.sh does not pass --verify-tag in live code — gh release create would MINT a tag from the default branch head" ;;
esac
# THE BAN STAYS, AND ITS OLD RATIONALE DID NOT (#259 asked for this to be settled with evidence).
#
# What changed: Golden Rule 4 no longer says "macOS bash 3.2 / BSD userland" — the floor is bash
# 5.3 (#256). And the flat claim that `sort -V` "does not exist on stock macOS" is no longer true:
# measured on macOS 26 (Darwin 25.5), Apple's own /usr/bin/sort is `2.3-Apple (199)` and it accepts
# `-V`, ordering 1.9 before 1.10 correctly.
#
# What did NOT change, and is why the rule survives its own rationale:
#   * `sort` is coreutils/BSD, not bash. The 5.3 floor says nothing about it either way.
#   * `-V` is not POSIX. It is a BSD/GNU extension, and this repo states no minimum macOS version,
#     so "current macOS has it" is not "every supported host has it".
#   * CI deliberately keeps Homebrew's `gnubin` OFF PATH on the macOS leg (.github/workflows/ci.yml)
#     precisely so BSD userland is what gets exercised — a GNU-flag habit would go unnoticed there.
#   * The failure mode is the reason it is a GATE rather than a preference: inside a command
#     substitution without pipefail, an unsupported flag is MASKED, leaving an empty
#     previous-version that reads as "first release" — a wrong release, silently.
#
# Asserted against COMMENT-STRIPPED source so the file can explain the hazard.
if sed 's/#.*//' "$DRV" | grep -q 'sort -V'; then
  check_note "release.sh uses GNU-only 'sort -V' in live code — '-V' is not POSIX, and an"
  check_note "unsupported flag inside a command substitution is masked into an empty previous tag"
  check_fail
fi
# BRIDGE THE TWO ACCOUNTINGS. `check_result` RETURNS non-zero; `check_summary` exits on its own
# pass/fail counter. Leaving them unjoined made this script report the boundary failures and then
# exit 0 — a gate that prints diagnostics and passes anyway, which is the exact "green tells you
# nothing" failure this file was written to close. `bad_quiet` folds the boolean into the counter
# without reprinting (check_note already emitted the detail).
check_result "release skill delegates its decisions and stays out of the installed lib dir" || bad_quiet

# =================================================================================================
# version-format — the FORMAT half, split out of version-ok for the backfill path (#284)
#
# The point of the split is the CONTRAST, so both halves are asserted on the same inputs: the format
# rules must still reject everything version-ok rejects for format reasons, and the reuse/ordering
# rules must NOT apply. A `version-format` that simply called `version-ok` would pass every format
# case here and silently reject every legitimate backfill target — which is the whole bug.
# =================================================================================================
eq "${ rc_of version-format v1.2.3; }"     0 "version-format accepts a well-formed version"
eq "${ rc_of version-format v1.2.3-rc1; }" 2 "version-format rejects a pre-release suffix"
eq "${ rc_of version-format v1.2.3.4; }"   2 "version-format rejects 4 components"
eq "${ rc_of version-format 1.2.3; }"      2 "version-format rejects a missing leading v"
eq "${ rc_of version-format v1.02.3; }"    2 "version-format rejects a leading-zero component"
eq "${ rc_of version-format v1.2.3.; }"    2 "version-format rejects a trailing dot"
eq "${ rc_of version-format; }"            2 "version-format requires an argument"
eq "${ rc_of version-format a b; }"        2 "version-format rejects extra arguments"
has "${ run version-format v2.1.0 2>&1; }" "2.1.0" "version-format prints the bare version"
# THE CONTRAST. `version-ok` rejects a used version (3) and an older one (4); a backfill target is
# BOTH by definition, and `version-format` must not care. Its stdin is deliberately ignored.
eq "${ printf 'v2.0.0\nv2.1.0\n' | rc_of version-ok v2.0.0; }"     3 "version-ok rejects a used version"
eq "${ printf 'v2.0.0\nv2.1.0\n' | rc_of version-format v2.0.0; }" 0 "version-format accepts that same used version — the backfill case"

# =================================================================================================
# tag-message — the release notes ARE the tag message, byte for byte (#284)
# =================================================================================================
tagobj() {   # <message-body-with-escapes> -> a raw tag object on stdout
  printf 'object 0000000000000000000000000000000000000000\ntype commit\ntag v9.9.9\ntagger t <t@t> 0 +0000\n\n'
  printf '%b' "$1"
}
# BYTE-EXACT, COMPARED AS FILES. `$(…)` strips every trailing newline, so a command-substitution
# comparison cannot see the one difference this predicate exists to preserve — it would pass on an
# implementation that dropped the final newline from every release body.
TM="$work/tm"; mkdir -p "$TM"
printf 'v9.9.9\n\nA paragraph with `backticks` and únicode.\n\n# A markdown heading\n\nProvenance: x\n' > "$TM/want"
tagobj 'v9.9.9\n\nA paragraph with `backticks` and únicode.\n\n# A markdown heading\n\nProvenance: x\n' \
  | bash "$RL" tag-message > "$TM/got"
if cmp -s "$TM/want" "$TM/got"; then ok; else
  bad "tag-message did not reproduce the message byte for byte (want $(wc -c < "$TM/want") bytes, got $(wc -c < "$TM/got"))"
fi
# The `#` line is the one git's DEFAULT tag cleanup deletes, which is why `cmd_tag` passes
# --cleanup=verbatim. Pinned separately so a regression names itself.
has "$(cat "$TM/got")" '# A markdown heading' "tag-message keeps a #-leading Markdown heading"
# A blank line inside the body must not be mistaken for the header/message separator — only the
# FIRST one is. An implementation splitting on every blank line truncates every multi-paragraph note.
tagobj 'one\n\ntwo\n\nthree\n' | bash "$RL" tag-message > "$TM/multi"
eq "$(wc -l < "$TM/multi" | tr -d ' ')" 5 "tag-message keeps blank lines inside the body"
eq "${ tagobj '' | rc_of tag-message; }"        13 "tag-message refuses an empty message"
eq "${ tagobj '  \n\n' | rc_of tag-message; }"  13 "tag-message refuses a whitespace-only message"
eq "${ tagobj 'notes\n-----BEGIN PGP SIGNATURE-----\nabc\n' | rc_of tag-message; }" 12 \
   "tag-message refuses a signed tag"
# AND EMITS NOTHING when it refuses. A caller that checked `-s` before the status would otherwise
# publish the signature as release notes.
tagobj 'notes\n-----BEGIN PGP SIGNATURE-----\nabc\n' | bash "$RL" tag-message > "$TM/sig" 2>/dev/null
eq "$(wc -c < "$TM/sig" | tr -d ' ')" 0 "a refused signed tag produces no output at all"
eq "${ tagobj 'x\n' | rc_of tag-message extra; }" 2 "tag-message takes no arguments"
# NO FINAL NEWLINE. `git tag -F --cleanup=verbatim` really does store a message without one, and
# every line-oriented filter ADDS one — reproduced by independent review as a 19-byte annotation
# coming back as 20. This is the case that forced the byte-offset + `tail -c` extraction.
printf 'no trailing newline' > "$TM/nonl-want"
tagobj 'no trailing newline' | bash "$RL" tag-message > "$TM/nonl-got"
if cmp -s "$TM/nonl-want" "$TM/nonl-got"; then ok; else
  bad "tag-message added or lost bytes on a message with no final newline (want $(wc -c < "$TM/nonl-want"), got $(wc -c < "$TM/nonl-got"))"
fi
# A CRLF message is preserved verbatim too — which is why `publish_verify` compares raw bytes
# rather than stripping CR from either side.
printf 'crlf line\r\n\r\nsecond\r\n' > "$TM/crlf-want"
tagobj 'crlf line\r\n\r\nsecond\r\n' | bash "$RL" tag-message > "$TM/crlf-got"
if cmp -s "$TM/crlf-want" "$TM/crlf-got"; then ok; else
  bad "tag-message did not preserve CRLF bytes"
fi
# FOUR SIGNATURE ENVELOPES, not one. Git signs with GPG, with SSH keys, and with X.509 via gpgsm,
# and the RFC1991 path emits a PGP MESSAGE. A detector that knew only the modern GPG envelope let
# the other three into the release notes while this file documented a refusal.
eq "${ tagobj 'n\n-----BEGIN SSH SIGNATURE-----\nx\n'    | rc_of tag-message; }" 12 "tag-message refuses an SSH-signed tag"
eq "${ tagobj 'n\n-----BEGIN SIGNED MESSAGE-----\nx\n'   | rc_of tag-message; }" 12 "tag-message refuses an X.509-signed tag"
eq "${ tagobj 'n\n-----BEGIN PGP MESSAGE-----\nx\n'      | rc_of tag-message; }" 12 "tag-message refuses an RFC1991 PGP message"
# A tag object with no blank line at all is unreadable, not empty: it must not be reported as a
# verdict about the message.
eq "$(printf 'object x\ntype commit\n' | bash "$RL" tag-message >/dev/null 2>&1; printf '%s' "$?")" 2 \
   "tag-message refuses a tag object with no header separator"

# =================================================================================================
# release-state — absent vs draft vs published, and the two answers that are NOT a verdict (#284)
# =================================================================================================
rs_of() { printf '%s' "$1" | bash "$RL" release-state "${2:-v2.1.0}" >/dev/null 2>&1; printf '%s' "$?"; }
eq "$(rs_of '[]')" 0 "release-state: an empty listing is absent"
eq "$(rs_of '[{"tag_name":"v1.0.0","id":1,"draft":false}]')" 0 "release-state: a listing without the tag is absent"
# --paginate emits ONE ARRAY PER PAGE. A predicate that read only the first page would report absent
# for a release sitting on page 2 — and absent is the arm that CREATES a second release.
eq "$(rs_of '[{"tag_name":"v1.0.0","id":1,"draft":false}]
[{"tag_name":"v2.1.0","id":2,"draft":false}]')" 11 "release-state: finds a release on a later page"
eq "$(rs_of '[{"tag_name":"v2.1.0","id":7,"draft":true}]')"  10 "release-state: a draft is its own verdict"
eq "$(rs_of '[{"tag_name":"v2.1.0","id":7,"draft":false}]')" 11 "release-state: published"
eq "$(rs_of '[{"tag_name":"v2.1.0","id":7,"draft":false},{"tag_name":"v2.1.0","id":8,"draft":true}]')" 14 \
   "release-state: two releases for one tag is ambiguous, not a winner to pick"
# THE jq `//` TRAP, pinned. `.draft // "missing"` yields "missing" for `false` as well as for null,
# so the first cut of this predicate refused every genuinely PUBLISHED release. Nothing about that
# code reads wrong; only running it says so.
has "$(printf '%s' '[{"tag_name":"v2.1.0","id":7,"draft":false}]' | bash "$RL" release-state v2.1.0 2>&1)" \
    "published 7" "release-state prints the verdict and the release id"
eq "$(rs_of '[{"tag_name":"v2.1.0","id":7}]')" 2 "release-state refuses a release that does not declare draft"
eq "$(rs_of 'not json')" 2 "release-state refuses unreadable JSON rather than calling it absent"

# =================================================================================================
# sha256 — the checksum that is the published product (#284)
# =================================================================================================
printf 'abc' > "$TM/abc"
eq "$(bash "$RL" sha256 "$TM/abc")" \
   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
   "sha256 matches the published NIST vector for 'abc'"
: > "$TM/empty"
eq "$(bash "$RL" sha256 "$TM/empty")" \
   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
   "sha256 of an empty file is the known empty-string digest"
eq "${ rc_of sha256 "$TM/does-not-exist"; }" 2 "sha256 refuses a missing file"
eq "${ rc_of sha256; }"                      2 "sha256 requires an argument"

# =================================================================================================
# The driver's argument surface. These are the exact classes round 3 produced: a fenced block
# cannot receive positional arguments, so `${1:?}` aborted before doing anything. A real script
# takes real arguments — and these assert that it does, and that it refuses bad ones.
# =================================================================================================
drv() { bash "$DRV" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
eq "${ drv --help; }"                 0 "driver --help exits 0"
eq "${ drv; }"                        2 "no subcommand is a usage error"
eq "${ drv not-a-subcommand; }"       2 "unknown subcommand is a usage error"
eq "${ drv version-guard; }"          2 "version-guard requires an argument"
eq "${ drv version-guard a b; }"      2 "version-guard rejects extra arguments"
eq "${ drv record-pr; }"              2 "record-pr requires an argument"
eq "${ drv record-pr not-a-number; }" 1 "record-pr rejects a non-numeric PR"
eq "${ drv tag; }"                    2 "tag requires --message-file"
eq "${ drv tag --message-file; }"     2 "tag --message-file requires a path"
eq "${ drv tag --message-file /nonexistent/nope; }" 1 "tag refuses a missing message file"
eq "${ drv tag --wrong-flag x; }"     2 "tag rejects an unknown flag"
eq "${ drv publish --wrong-flag; }"   2 "publish rejects an unknown flag"
eq "${ drv publish --version; }"      2 "publish --version requires a value"
# The VALUE-level argument cases are driven in the publish fixture below, not here: with no run
# state in this checkout every one of them exits 1 whether the guard works or not, so an rc-only
# assertion cannot tell a refusal from a coincidence.
# An EMPTY message file must be refused too — an empty annotated tag is the release's only note.
: > /tmp/adb-empty-msg.$$
eq "${ drv tag --message-file /tmp/adb-empty-msg.$$; }" 1 "tag refuses an empty message file"
rm -f /tmp/adb-empty-msg.$$

# ============ the driver's own slug producer is validated (#218) ============
# `release.sh` carries its OWN `slug()` — it lives outside `scripts/lib/` by D14, which is exactly
# why a sweep of that directory reported "no additional producers" and missed it. Every consumer
# concatenates the result into `repos/<slug>/...`, four of them in the tag/merge path.
#
# STRUCTURAL, and this file is the honest place to say why — with the boundary redrawn by #313.
#
# The driver IS driven now: the last section of this file stands up a throwaway checkout with a
# stubbed `gh` and its own run state, and runs `release.sh` for real. So "state and gh stubbing are
# unavailable" is no longer true, and this comment used to say so.
#
# These three pins stay structural anyway, because they assert how the producer is WRITTEN rather
# than what it returns: that it delegates to the shared charset predicate instead of restating it,
# and that it prints its diagnostic with `printf`. A run cannot distinguish a delegated check from
# a hand-rolled one that happens to agree, and the `echo`/`printf` hazard only appears under a
# shell option this suite does not set. `release.sh` also still dispatches on load, so its
# functions cannot be SOURCED and unit-tested one at a time; the fixture drives it as a PROCESS
# instead, which reaches whole subcommands but not individual helpers. A pin that reads the source
# is weaker than one that runs it; where that is what is available, the test says which kind it is.
drv="$(cat "$DRV")"
slug_fn="$(awk '/^slug\(\) \{/,/^\}/' "$DRV")"
if printf '%s' "$slug_fn" | grep -q 'adb_is_path_safe_repo_slug'; then ok; else
  bad "release.sh slug() must validate through adb_is_path_safe_repo_slug before returning an API-supplied slug (#218)"
fi
# It must DELEGATE, never restate the rule: a hand-rolled charset test here would be a second copy
# of a security predicate, which is the failure #218 exists to end.
if printf '%s' "$slug_fn" | grep -qE '\[!A-Za-z0-9|\[\^A-Za-z0-9'; then
  bad "release.sh slug() restates the charset rule instead of calling the shared predicate"
else ok; fi
# The diagnostic must be printed with printf, not echo: under `shopt -s xpg_echo`, echo decodes
# %q's escape back into a real newline and re-forges the line the renderer just escaped.
if printf '%s' "$slug_fn" | grep -qE '^\s*echo '; then
  bad "release.sh slug() prints its diagnostic with echo — xpg_echo would undo adb_display_value's escaping"
else ok; fi
# And EVERY consumer must check it — not just the assignments.
#
# THIS CHECK'S FIRST CUT MATCHED ONLY `sl="$(slug)"`, and independent review found what that let
# through: `await_checks` interpolated `$(slug)` DIRECTLY into a request path inside a retry loop,
# so a rejected slug became `repos//commits/...` polled 90 times over fifteen minutes and reported
# as a timeout. A guard scoped to one spelling of the thing it guards is the failure mode this
# repo keeps writing down; the pattern now matches any `$(slug)` use.
#
# The accepted shapes are exactly two: an assignment that checks its status (`x="$(slug)" || …`),
# and nothing else. A bare `$(slug)` anywhere — interpolated into a string, passed as an argument —
# discards the status by construction and is what this rejects.
#
# Comment lines are stripped first, so prose mentioning the idiom cannot be read as a site (the
# first cut of this check flagged its own explanatory comment).
code_only="$(printf '%s\n' "$drv" | grep -vE '^[[:space:]]*#')"
unchecked="$(printf '%s\n' "$code_only" | grep -nF '$(slug)' | grep -vE '="\$\(slug\)"[[:space:]]*(\|\||$)' || true)"
if [ -z "$unchecked" ]; then ok; else
  bad "release.sh uses \$(slug) without checking its status: $unchecked"
fi

# =================================================================================================
# THE RUN-STATE GUARDS (#313) — structural shape, then the driver actually run.
#
# `need` reads a cross-step value or stops the release. It used to PRINT the value, so all eleven
# of its call sites captured it with `v="$(need KEY hint)"` — and a command substitution is a
# subshell, so `die`'s `exit 1` left only the subshell. The message reached stderr and the step
# CARRIED ON with an empty string.
#
# Cutting v2.1.0, that turned "you skipped a step" into a fifteen-minute wrong answer:
# `verify-merge` ran with neither MERGE_SHA nor EXPECTED_CHECKS recorded, `await_checks "" ""`
# polled `repos/<slug>/commits//check-runs` 90 times at 10s intervals, and reported
# "never reached a settled set of >= ". `cmd_roll`'s milestone pin-revalidation was defeated the
# same way, by its own empty inputs: `[ "" = "" ]` passes.
#
# WHY EXIT CODE ALONE PROVES ALMOST NOTHING HERE, and why the oracle below is as strict as it is.
# Run against the pre-fix driver, 11 of these 14 refusal cases STILL EXIT 1 — a later `die`, on a
# later line, for a different reason — so a `yes`/`no` on the status would have been green for all
# eleven. (The three that do not are the `roll-preflight` cases, which reach the rollover with an
# empty `--version`; that is caught here by the no-rollover assertion, and in a real checkout by
# `bin/baseline` refusing an empty version.) So each case requires the exit to be exactly 1, stdout
# to be EMPTY, stderr to be EXACTLY the guard's own one line, no gh request issued at all, and no
# rollover: the last two are what distinguish "stopped at the guard" from "stopped at a convenient
# downstream failure".
# =================================================================================================

# --- structural: `need` is only ever reached as a direct statement --------------------------------
# Two rules over comment-stripped source, both reported with what they counted. The first bans the
# superseded spelling outright; the second is the completeness half — every `need` USE must be one
# of the direct call sites, so a use in any other position (an argument, a pipeline, a `[ ]` test)
# is caught even though it is not a `$( )`.
#
# Comments are stripped first because `release.sh`'s own header quotes the superseded spelling to
# explain the bug, and the sibling `$(slug)` check above shipped its first cut flagging exactly
# that kind of prose.
#
# SAY WHAT THESE DO NOT CATCH, rather than implying more — a scanner trusted past its reach is how
# a green gate starts reading as evidence. This is a LEXICAL line scan, not a shell parser:
#
#   * it strips only WHOLE-LINE comments, so a trailing `# …` comment, a heredoc body, or any
#     quoted string is still scanned — which is why `total` is anchored to command position rather
#     than to the bare word (see below);
#   * it cannot see a substitution split across lines — `x=$(` on one line and `need …` at the head
#     of the next reads to it as a direct call;
#   * `total` enumerates a SET of command-start contexts. It is a good set, not a proof of one.
#
# What covers all three is the driven suite below, where a driver that does not stop simply fails.
# These rules are the cheap immediate half; the behaviour is the proof.
need_subst_in() {   # <file> -> print offending lines; empty output = clean
  grep -vE '^[[:space:]]*#' "$1" | grep -nE '\$\(need[[:space:]]|`need[[:space:]]' || true
}
need_counts_in() {  # <file> -> "<direct> <total>"
  local code direct total
  code="$(grep -vE '^[[:space:]]*#' "$1")"
  # COMMAND POSITION, not merely "the word `need`". Anchoring on any non-word character before it
  # counted `die "… — need exactly 1"` (release.sh's roadmap-title refusal) as a thirteenth call
  # site, so `direct` and `total` could never agree and the rule failed on correct code.
  #
  # The set is the places a command can START: line head; after `; & | ( ) { }` or a backtick —
  # which is what makes `$(need …)` and `` `need …` `` count, since both open with one of them; and
  # after a RESERVED WORD. Review caught that last group missing: without it `if need …; then :; fi`
  # lowered `direct` and `total` by one each, leaving the equality green while a call site vanished
  # from the direct inventory. Neither the definition (`need() {`, no following space) nor the
  # private nameref (`_need_dest`) can match.
  total="$(printf '%s\n' "$code" \
    | grep -cE '(^|[;&|(){}`]|[[:space:]](if|then|else|elif|do|while|until|time|!)[[:space:]])[[:space:]]*need[[:space:]]' || true)"
  direct="$(printf '%s\n' "$code" | grep -cE '^[[:space:]]*need[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]' || true)"
  printf '%s %s' "$direct" "$total"
}
eq "$(need_subst_in "$DRV")" '' "release.sh never reaches need through a command substitution (#313)"
read -r NEED_DIRECT NEED_TOTAL <<EOF
$(need_counts_in "$DRV")
EOF
# A scanner that matched nothing reports exactly what a clean scan reports, so the count is
# asserted non-zero before it is compared with anything.
if [ "${NEED_TOTAL:-0}" -gt 0 ]; then ok; else
  bad "the need-call scanner matched NOTHING in release.sh — it would report clean either way"
fi
eq "$NEED_DIRECT" "$NEED_TOTAL" "every need use in release.sh is a direct statement (found $NEED_DIRECT of $NEED_TOTAL)"

# --- the fixture: a throwaway checkout, a refusing gh, and this run's own state -------------------
# ROOTED IN ITS OWN `git init`, and that is load-bearing rather than tidy. `release.sh` derives
# `ROOT` from `git rev-parse --show-toplevel` and puts its run state at
# `$ROOT/.claude/state/release-run.env` — so driving the TRACKED script would read, and the failure
# cases below would overwrite, a real in-progress release's state.
#
# Only `scripts` and `.claude/skills` are copied. `.claude` as a whole would drag in `.claude/state`
# — gitignored, live, and the very file this suite must not inherit.
FIX="$work/repo"
if check_copy_subtrees "$ROOT" "$FIX" scripts .claude/skills \
   && git -C "$FIX" init -q >/dev/null 2>&1 \
   && mkdir -p "$FIX/.claude/state" "$FIX/bin" "$work/ghbin"; then ok; else
  bad "could not build the release-driver fixture — every driven case below would prove nothing"
fi
FIX_DRV="$FIX/.claude/skills/release/release.sh"
FIX_RS="$FIX/.claude/state/release-run.env"
cp "$FIX_DRV" "$work/pristine-release.sh"
printf 'a tag message\n' > "$work/msg.txt"

# A RECORDING, REFUSING gh stub. Present, so `have_gh` passes; answers nothing, so `slug()` and
# every gh-backed path refuse immediately.
#
# REFUSING IS WHAT KEEPS THIS SUITE FROM HANGING. Given a stub that ANSWERED, a regressed
# `verify-merge` would enter `await_checks`'s 90 x 10s retry loop and this file would sit there for
# fifteen minutes instead of going red — reproducing the bug rather than reporting it. Measured:
# an answering stub blew a 2-minute bound; this one returns in well under a second.
cat > "$work/ghbin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "${1:-}" in auth) exit 0 ;; esac
exit 1
STUB
chmod +x "$work/ghbin/gh"

# A recording `bin/baseline`, so the one PRESENT-VALUE case below can prove the value actually
# arrived. Every missing-value case asserts this log stays empty, which is how "the guard stopped
# the run" is told apart from "the rollover ran with an empty version".
#
# ONE ARGUMENT PER LINE, not `"$*"`. Flattening argv into a single space-joined string cannot tell
# `--version v9.9.9` from `--version` followed by `v9.9.9` as one argument, nor an empty version
# from a dropped one — so the present-value assertion would have been about a substring, not about
# the argv it claims to check.
cat > "$FIX/bin/baseline" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$BASELINE_CALLS"
STUB
chmod +x "$FIX/bin/baseline"

# rel_case <state> <args…> — write <state> as the run-state file (empty string = no file at all),
# then run the fixture driver, capturing stdout and stderr SEPARATELY.
#
# Under `adb_run_bounded`, because a regression's signature is a wait, not a crash: 90x10s in
# `await_checks` and 30 minutes in `pr-watch` are both reachable from these inputs. The bound
# returns 124, which the `rc = 1` assertion rejects — a timeout must never be scored as "it
# refused". `env`, not a variable prefix: assignments preceding a FUNCTION call persist in the
# calling shell in bash, which would leave the stub on PATH for the rest of the suite.
rel_case() {
  local state="$1"; shift
  : > "$work/gh-calls"; : > "$work/baseline-calls"
  if [ -n "$state" ]; then printf '%s\n' "$state" > "$FIX_RS"; else rm -f "$FIX_RS"; fi
  adb_run_bounded 60 5 env "PATH=$work/ghbin:$PATH" "GH_CALLS=$work/gh-calls" \
      "BASELINE_CALLS=$work/baseline-calls" bash "$FIX_DRV" "$@" \
      > "$work/out" 2> "$work/err"
  REL_RC=$?
  REL_OUT="$(cat "$work/out")"; REL_ERR="$(cat "$work/err")"
  REL_GH="$(cat "$work/gh-calls")"; REL_BL="$(cat "$work/baseline-calls")"
}

# rel_guard <label> <expected-key-and-hint> <state> <args…> — the five-part oracle: exit exactly 1,
# empty stdout, stderr equal to the guard's own single line, no gh request, no rollover.
#
# TWO MODES, because the matrix below is run TWICE. `REL_MODE=assert` requires the oracle to hold;
# `REL_MODE=broken` requires it NOT to, and is what the M2 mutation uses to prove that every one of
# these positions can actually go red rather than only the one position a single spot-check reaches.
REL_MODE=assert
rel_guard() {
  local label="$1" want="$2" state="$3"; shift 3
  rel_case "$state" "$@"
  if [ "$REL_MODE" = "assert" ]; then
    eq "$REL_RC"  1  "$label: exits 1"
    eq "$REL_OUT" '' "$label: writes nothing to stdout"
    eq "$REL_ERR" "release: $want" "$label: stops with its OWN message, and only that"
    eq "$REL_GH"  '' "$label: issues no gh request — it stopped AT the guard"
    eq "$REL_BL"  '' "$label: never reaches the rollover"
  elif [ "$REL_RC" = "1" ] && [ "$REL_OUT" = "" ] && [ "$REL_ERR" = "release: $want" ] \
       && [ "$REL_GH" = "" ] && [ "$REL_BL" = "" ]; then
    bad "$label: satisfied the oracle even with need() unable to refuse — those assertions cannot go red"
  else ok; fi
}

# guard_matrix — every guard position, in order. Twelve of them, plus the two empty-value spellings;
# the earlier guard in each function is cleared with partial state so the later one is reachable at
# all. A FUNCTION, not a straight-line list, so the M2 mutation can replay the identical set.
guard_matrix() {
  rel_guard "roll-preflight/no state" "VERSION not recorded yet — run version-guard first" '' roll-preflight
  rel_guard "stamp-verify/no state"   "VERSION not recorded yet — run version-guard first" '' stamp-verify
  rel_guard "await-review/no state"   "PR not recorded yet — run record-pr first"          '' await-review
  rel_guard "merge/no state"          "PR not recorded yet — run record-pr first"          '' merge
  rel_guard "merge/PR pinned"         "REVIEWED_SHA not recorded yet — run await-review first" 'PR=42' merge
  rel_guard "verify-merge/no state"   "MERGE_SHA not recorded yet — run merge first"       '' verify-merge
  rel_guard "verify-merge/sha pinned" "EXPECTED_CHECKS not recorded yet — run await-review first" 'MERGE_SHA=abc123' verify-merge
  rel_guard "tag/no state"            "VERSION not recorded yet — run version-guard first" '' tag --message-file "$work/msg.txt"
  rel_guard "tag/version pinned"      "MERGE_SHA not recorded yet — run merge first"       'VERSION=v9.9.9' tag --message-file "$work/msg.txt"
  rel_guard "roll/no state"           "VERSION not recorded yet — run version-guard first" '' roll
  rel_guard "roll/version pinned"     "M_NUM not recorded yet — run readiness first"       'VERSION=v9.9.9' roll
  # The twelfth is NEW (#313). `cmd_readiness` writes M_NUM and MS_NAME together, so this state
  # "cannot happen" — but the run state is an appended text file a resumed run can leave partial,
  # and an empty MS_NAME does not merely propagate: it makes the milestone pin-revalidation compare
  # `[ "" = "" ]` and PASS, waving through the roll it exists to refuse.
  rel_guard "roll/milestone half-pinned" "MS_NAME not recorded yet — run readiness first" 'VERSION=v9.9.9
M_NUM=7' roll
  # A recorded key with an EMPTY value is the same missing state. `rs` greps `^KEY=` and cuts the
  # value, so `VERSION=` yields the empty string exactly as an absent file does — and `tail -n1`
  # means a LATER empty line overrides an earlier real one, which is the shape a partially
  # rewritten state file actually has. Both must refuse.
  rel_guard "roll-preflight/empty value" "VERSION not recorded yet — run version-guard first" 'VERSION=' roll-preflight
  rel_guard "roll-preflight/emptied by a later line" "VERSION not recorded yet — run version-guard first" 'VERSION=v1.0.0
VERSION=' roll-preflight
}
guard_matrix

# --- a refused guard must not touch the run state --------------------------------------------------
# `cmp -s` against a saved copy, not a checksum: a CRC is a collision away from calling two files
# equal, and the point of this case is byte equality. It does NOT claim the file was never opened or
# rewritten with identical bytes — only that its contents did not change.
printf 'VERSION=v9.9.9\n' > "$FIX_RS"
cp "$FIX_RS" "$work/rs-before"
rel_case 'VERSION=v9.9.9' roll
if cmp -s "$work/rs-before" "$FIX_RS"; then ok; else
  bad "a refused guard changed the run state's bytes"
fi

# --- THE PRESENT-VALUE CASE: the nameref really delivers ------------------------------------------
# Every case above is a REFUSAL, and all fourteen would still pass against a `need` that refused
# unconditionally — or one that never assigned at all. This is the case that cannot: `roll-preflight`
# interpolates the value it read into the rollover's `--version`, so the recorded argv is proof that
# `need` wrote `v9.9.9` through the nameref into its CALLER's `v`.
#
# THE EXPECTED ARGV HAS ONE HOME, and that is not tidiness — it is the defect this variable
# replaces. The literal was written out twice, here and in M3's "did it still deliver?" test; when
# the stub changed from `"$*"` to one-argument-per-line, this copy was updated and M3's was not. M3
# then compared against a space-joined string the log can no longer produce, so it took the `else
# ok` branch unconditionally and proved nothing — a mutation harness silently asserting nothing,
# which is the exact shape this file exists to catch. Sharing the constant makes that drift
# impossible, and the assertion below passing is what proves M3's comparison is live: the same
# string, compared the same way, is known to match on unmutated code.
ROLL_ARGV='release
roll
--version
v9.9.9
--dry-run'
rel_case 'VERSION=v9.9.9' roll-preflight
eq "$REL_RC" 0  "roll-preflight/version pinned: succeeds when the value IS recorded"
eq "$REL_BL" "$ROLL_ARGV" \
   "roll-preflight/version pinned: the value reaches the caller through the nameref, as its own argv word"

# --- MUTATION PROOF: the new assertions are required to go RED -------------------------------------
# Against a COPY of the driver, never the tracked file (base/practices/self-review.md: editing the
# real tree to test a check that reads the real tree is how uncommitted work gets discarded).
# `check_mutate_line` refuses to proceed unless its edit demonstrably applied, so a mutation that
# stops describing the code cannot quietly turn these into assertions about unmodified source.
#
# WHAT EACH ONE COVERS, stated so the coverage is not overread: M1 reddens both structural rules and
# `verify-merge`'s behaviour; M2 replays the WHOLE matrix and requires every one of the fourteen
# positions to stop satisfying the oracle; M3 reddens the present-value case. The run-state
# byte-equality case above is not mutated — it is a property of a refusal that already has to hold.
mut_restore() { cp "$work/pristine-release.sh" "$FIX_DRV"; }

# M1 — restore ONE call site to the superseded `$( )` spelling. It must redden BOTH structural rules
# and the behaviour of `verify-merge`, the subcommand whose 15-minute misdiagnosis is #313.
#
# THE MUTATION KEEPS THE NEW THREE-ARGUMENT SHAPE and only wraps it, which is the whole point:
# review caught the first cut writing the OLD two-argument `$(need EXPECTED_CHECKS 'hint')`, which
# makes today's `need` take `EXPECTED_CHECKS` as its DESTINATION and die on an unset `$3` under
# `set -u`. That goes red for an argument-contract error, not because `die` exits only the subshell
# — a mutation proving a different proposition than the one it is captioned with.
#
# EXPECTED_CHECKS, because `check_mutate_line` requires its needle to match exactly ONE line and
# four of the twelve call sites are byte-identical to another (`need v VERSION …` appears four
# times, `need pr PR …` and `need msha MERGE_SHA …` twice each). This one is unique, and it sits in
# `cmd_verify_merge` — so `MERGE_SHA` is supplied below to get past the guard ahead of it.
mut_restore
if check_mutate_line "$FIX_DRV" \
     "  need exp EXPECTED_CHECKS 'run await-review first'" \
     "s|^  need exp EXPECTED_CHECKS 'run await-review first'\$|  exp=\"\$(need exp EXPECTED_CHECKS 'run await-review first')\"|" \
     "M1 command-substitution call site"; then
  if [ -n "$(need_subst_in "$FIX_DRV")" ]; then ok; else
    bad "M1: the \$(need …) ban did NOT report the restored site — it cannot go red"
  fi
  read -r M1_DIRECT M1_TOTAL <<EOF
$(need_counts_in "$FIX_DRV")
EOF
  if [ "$M1_DIRECT" != "$M1_TOTAL" ]; then ok; else
    bad "M1: the direct-vs-total rule stayed green on a wrapped call site (got $M1_DIRECT of $M1_TOTAL)"
  fi
  rel_case 'MERGE_SHA=abc123' verify-merge
  if [ "$REL_ERR" = "release: EXPECTED_CHECKS not recorded yet — run await-review first" ]; then
    bad "M1: the mutated driver still stopped at the guard — the behavioural oracle proves nothing"
  else ok; fi
fi

# M2 — delete the emptiness test inside `need`, leaving a helper that reads and never refuses, then
# REPLAY THE ENTIRE MATRIX. Spot-checking one subcommand would have left thirteen positions whose
# assertions were never shown capable of failing; `REL_MODE=broken` requires each of them to stop
# satisfying the oracle.
mut_restore
if check_mutate_line "$FIX_DRV" \
     '  [ -n "$_need_dest" ] || die "$2 not recorded yet — $3"' \
     '/_need_dest.*|| die/d' \
     "M2 need never refuses"; then
  REL_MODE=broken
  guard_matrix
  REL_MODE=assert
fi

# M3 — make `need` refuse unconditionally. Every refusal case still passes; only the present-value
# case can catch it, which is why that case exists.
mut_restore
if check_mutate_line "$FIX_DRV" \
     '  _need_dest="$(rs "$2")"' \
     's|^  _need_dest="\$(rs "\$2")"$|  _need_dest=""|' \
     "M3 need never assigns"; then
  rel_case 'VERSION=v9.9.9' roll-preflight
  if [ "$REL_BL" = "$ROLL_ARGV" ]; then
    bad "M3: a need() that never assigns still delivered the value — the present-value case proves nothing"
  else ok; fi
fi
mut_restore

# =================================================================================================
# THE PUBLISH SUITE (#284) — a real repo, a real origin, a real annotated tag, and a gh SIMULATOR.
#
# WHY THIS NEEDS A DIFFERENT STUB THAN EVERYTHING ABOVE. The refusing stub is what keeps the guard
# matrix fast and hang-free, and for a REFUSAL that is exactly right: the assertion is that the
# driver stopped before it ever asked GitHub anything. `publish`'s contract is the opposite — it is
# entirely about what the driver does WITH GitHub's answers, so a stub that answers nothing can only
# ever prove the refusals. The hazard the refusing stub's header warns about does not apply here:
# `publish` has no retry loop, so an answering stub returns immediately rather than reproducing a
# fifteen-minute wait.
#
# WHY A REAL REPO AND A REAL ORIGIN. The notes are read with `git cat-file tag`, the artifact is
# built with `git archive`, the tag is resolved with `git ls-remote --tags origin`, and the
# on-default-branch guard is `git merge-base --is-ancestor … origin/main`. Faking any of those would
# be testing the fake. A bare repo on disk is a real `origin` that touches no network.
#
# THE ACCEPTANCE CRITERION THIS EXISTS FOR: "check-release-skill.sh fails when the publish step is
# removed or stubbed out." Three mutations at the bottom prove it — a token grep could not.
# =================================================================================================
PUB="$work/pubrepo"; PUBO="$work/puborigin.git"; PUBGH="$work/pubgh"
PUB_RS="$PUB/.claude/state/release-run.env"
PUB_STATE="$work/pub-state.json"; PUB_STORE="$work/pub-assets"; PUB_TAGS="$work/pub-tags"

# A NOTES BODY THAT EXERCISES WHAT ORDINARY PROSE DOES NOT: backticks (which an inline `-m` would
# execute), a `#`-leading Markdown heading (which git's DEFAULT tag cleanup deletes), non-ASCII, a
# blank line, and a trailing newline. If the pipeline mangles any of them, byte-identity fails here
# rather than in a release nobody can un-publish.
printf 'v9.9.9\n\nRelease with `backticks`, únicode — and a blank line below.\n\n# Heading\n\nProvenance: test\n' \
  > "$work/pub-msg.txt"

PUB_DRV="$PUB/.claude/skills/release/release.sh"
pub_built=0
if check_copy_subtrees "$ROOT" "$PUB" scripts .claude/skills \
   && mkdir -p "$PUB/.claude/state" "$PUBGH" "$PUB_STORE" \
   && printf '[roles]\nrelease = "claude"\n' > "$PUB/agents.toml" \
   && git init -q -b main "$PUB" >/dev/null 2>&1 \
   && check_git "$PUB" add -A >/dev/null 2>&1 \
   && check_git "$PUB" commit -qm init >/dev/null 2>&1 \
   && git init -q --bare "$PUBO" >/dev/null 2>&1 \
   && check_git "$PUB" remote add origin "$PUBO" >/dev/null 2>&1 \
   && check_git "$PUB" push -q origin main >/dev/null 2>&1 \
   && printf 'VERSION=v9.9.9\nMERGE_SHA=%s\n' "$(check_git "$PUB" rev-parse HEAD)" > "$PUB_RS" \
   && bash "$PUB_DRV" tag --message-file "$work/pub-msg.txt" >/dev/null 2>&1 \
   && check_git "$PUB" tag v8.8.8 >/dev/null 2>&1 \
   && check_git "$PUB" push -q origin v8.8.8 >/dev/null 2>&1 \
   && check_git "$PUB" fetch -q --tags origin >/dev/null 2>&1; then
  pub_built=1; ok
else
  bad "could not build the publish fixture — every publish case below would prove nothing"
fi
cp "$PUB_DRV" "$work/pristine-publish.sh" 2>/dev/null || true
PUB_SHA="$(check_git "$PUB" rev-list -n1 v9.9.9 2>/dev/null)"

# `agents.toml` is written INTO the fixture on purpose: `assert_role` resolves `[roles].release`, and
# without a manifest here the resolver would walk up to the developer's own global one. A suite
# whose verdict depends on the machine it runs on is not a suite.
#
# THE TAG IS CREATED BY THE DRIVER, NOT BY THIS FILE, AND THAT IS LOAD-BEARING. The first cut of
# this fixture ran `git tag -a … --cleanup=verbatim` itself, which made the byte-identity assertions
# below a statement about the FIXTURE's tag rather than about `cmd_tag`. Measured: deleting
# `--cleanup=verbatim` from the driver and re-running this suite came back **261 passed, 0 failed**
# — the assertion could not fail on the mutation it exists to catch. Driving `release.sh tag` puts
# the flag under test, and the same deletion is now caught here. `cmd_tag` touches only git, so a
# bare repo on disk is enough; no part of this needs the simulator.
#
# `v8.8.8` is deliberately LIGHTWEIGHT, and is created by hand for the opposite reason: the driver
# will never produce one, and it is the input for the refusal case.

# --- the simulator --------------------------------------------------------------------------------
# It answers, records every invocation, and keeps release state on disk so a second run sees what the
# first one did — which is the only way "re-running changes nothing" can be an assertion rather than
# a hope. It models the two GitHub behaviours the driver's design turns on:
#   * `create` without `--verify-tag` MINTS A TAG. It records `FORGED-TAG`, so a driver that dropped
#     the flag is caught by an assertion rather than by a reviewer noticing.
#   * `upload` of an existing asset name FAILS. That is what makes "upload only what is missing"
#     testable, and why the driver must never reach for `--clobber` to get past it.
cat > "$PUBGH/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "${1:-}" in
  auth) exit 0 ;;
  repo)
    case "$*" in
      *nameWithOwner*)    printf '%s\n' "$GH_SLUG"; exit 0 ;;
      *defaultBranchRef*) printf 'main\n'; exit 0 ;;
    esac
    exit 1 ;;
  api)
    case "$*" in
      *releases*per_page*) cat "$GH_STATE"; exit 0 ;;
    esac
    exit 1 ;;
  release) : ;;
  *) exit 1 ;;
esac
action="$2"; shift 2
tag=""; notes=""; dir=""; draftflag=""; verify=0; lt=""; assets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R)            shift 2 ;;
    --verify-tag)  verify=1; shift ;;
    --title)       shift 2 ;;
    --notes-file)  notes="$2"; shift 2 ;;
    --dir)         dir="$2"; shift 2 ;;
    --draft)       draftflag=true; shift ;;
    --draft=false) draftflag=false; shift ;;
    --latest)       lt=true;  shift ;;
    --latest=true)  lt=true;  shift ;;
    --latest=false) lt=false; shift ;;
    --clobber)      shift ;;
    -*)            shift ;;
    *) if [ -z "$tag" ]; then tag="$1"; else assets+=("$1"); fi; shift ;;
  esac
done
jqw() { jq "$@" "$GH_STATE" > "$GH_STATE.tmp" && mv "$GH_STATE.tmp" "$GH_STATE"; }
case "$action" in
  create)
    if ! grep -qxF "$tag" "$GH_TAGS"; then
      if [ "$verify" -eq 1 ]; then printf 'gh: %s does not exist on the remote\n' "$tag" >&2; exit 1; fi
      printf 'FORGED-TAG %s\n' "$tag" >> "$GH_CALLS"
    fi
    mkdir -p "$GH_ASSETS/$tag"; names=()
    for a in "${assets[@]}"; do cp "$a" "$GH_ASSETS/$tag/${a##*/}" || exit 1; names+=("${a##*/}"); done
    [ -n "$notes" ] || { printf 'gh: no notes\n' >&2; exit 1; }
    d=false; [ "$draftflag" = "true" ] && d=true
    # A test hook, not a GitHub behaviour: it lets one case reach the "created, but still a draft"
    # state that the driver's final post-condition read exists to catch.
    [ -n "${GH_FORCE_DRAFT:-}" ] && [ -e "$GH_FORCE_DRAFT" ] && d=true
    # --argjson, NOT `--args`. jq's `--args` consumes every remaining argument as a positional
    # STRING, so `jqw`'s trailing "$GH_STATE" became one of them and jq read from stdin instead of
    # the state file — the create exited 0 having written nothing, which is precisely the silent
    # no-op this suite exists to catch, wearing the test harness as a disguise.
    njson="$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" || exit 1
    ltj='"unset"'; [ -n "$lt" ] && ltj="$lt"
    jqw --arg t "$tag" --rawfile body "$notes" --argjson d "$d" --argjson names "$njson" \
        --argjson lt "$ltj" \
        '. + [{tag_name:$t, id:(length+1), draft:$d, body:$body, latest:$lt,
               assets:($names | map({name:.}))}]' || exit 1
    ;;
  upload)
    for a in "${assets[@]}"; do
      n="${a##*/}"
      [ -e "$GH_ASSETS/$tag/$n" ] && { printf 'gh: asset %s already exists\n' "$n" >&2; exit 1; }
      mkdir -p "$GH_ASSETS/$tag"; cp "$a" "$GH_ASSETS/$tag/$n" || exit 1
      jqw --arg t "$tag" --arg n "$n" \
          'map(if .tag_name == $t then .assets += [{name:$n}] else . end)' || exit 1
    done
    ;;
  edit)
    [ "$draftflag" = "false" ] || { printf 'gh: unsupported edit\n' >&2; exit 1; }
    ltj='"unset"'; [ -n "$lt" ] && ltj="$lt"
    jqw --arg t "$tag" --argjson lt "$ltj" \
        'map(if .tag_name == $t then (.draft = false | .latest = $lt) else . end)' || exit 1
    ;;
  download)
    [ -n "$dir" ] || exit 1
    mkdir -p "$dir"
    ls "$GH_ASSETS/$tag" >/dev/null 2>&1 || { printf 'gh: no assets\n' >&2; exit 1; }
    cp "$GH_ASSETS/$tag/"* "$dir/" 2>/dev/null || exit 1
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$PUBGH/gh"
printf 'v9.9.9\nv8.8.8\n' > "$PUB_TAGS"

# pub_run <args…> — drive the fixture driver against the simulator, capturing streams separately.
pub_run() {
  : > "$work/pub-calls"
  adb_run_bounded 120 5 env "PATH=$PUBGH:$PATH" "GH_CALLS=$work/pub-calls" \
      "GH_STATE=$PUB_STATE" "GH_ASSETS=$PUB_STORE" "GH_TAGS=$PUB_TAGS" "GH_SLUG=acme/widget" \
      "GH_FORCE_DRAFT=$work/pub-force-draft" \
      "ADB_RELEASE_READ_TRIES=2" "ADB_RELEASE_READ_SLEEP=0" \
      bash "$PUB_DRV" "$@" > "$work/pub-out" 2> "$work/pub-err"
  PUB_RC=$?
  PUB_OUT="$(cat "$work/pub-out")"; PUB_ERR="$(cat "$work/pub-err")"; PUB_CALLS="$(cat "$work/pub-calls")"
}
pub_reset() {   # <releases-json> [run-state]
  printf '%s' "$1" > "$PUB_STATE"
  rm -rf "$PUB_STORE"; mkdir -p "$PUB_STORE"
  if [ "$#" -ge 2 ]; then printf '%s\n' "$2" > "$PUB_RS"; else rm -f "$PUB_RS"; fi
}
pub_norm_state="VERSION=v9.9.9
MERGE_SHA=$PUB_SHA"

# An annotated tag on a commit that never reached the default branch — pushed as a TAG only, so
# `origin/main` does not contain it. Built here rather than inline so the case below reads as one
# assertion instead of six setup lines.
if [ "$pub_built" -eq 1 ]; then
  if check_git "$PUB" checkout -q -b side >/dev/null 2>&1 \
     && check_git "$PUB" commit -q --allow-empty -m side >/dev/null 2>&1 \
     && check_git "$PUB" tag -a v5.5.5 --cleanup=verbatim -F "$work/pub-msg.txt" >/dev/null 2>&1 \
     && check_git "$PUB" push -q origin v5.5.5 >/dev/null 2>&1 \
     && check_git "$PUB" checkout -q main >/dev/null 2>&1; then ok; else
    bad "could not build the off-branch tag — the on-default-branch case below would prove nothing"
  fi
fi

if [ "$pub_built" -eq 1 ] && [ -n "$PUB_SHA" ]; then
  # --- A: absent -> create ------------------------------------------------------------------------
  pub_reset '[]' "$pub_norm_state"
  pub_run publish
  eq "$PUB_RC" 0 "publish/absent: creates the release (stderr: $PUB_ERR)"
  has "$PUB_CALLS" "release create v9.9.9" "publish/absent: calls gh release create for the tag"
  has "$PUB_CALLS" "--verify-tag"          "publish/absent: passes --verify-tag, so gh can never mint a tag"
  hasnt "$PUB_CALLS" "FORGED-TAG"          "publish/absent: no tag was created by the publish"
  hasnt "$PUB_CALLS" "release upload"      "publish/absent: attaches assets in the create, with no separate upload"
  hasnt "$PUB_CALLS" "--latest=false"      "publish/absent: a current cut is marked Latest"
  eq "$(jq -r '.[0].latest' "$PUB_STATE")" true "publish/absent: and the platform recorded it as Latest"
  # BYTE-IDENTITY, THE ACCEPTANCE CRITERION. Compared as FILES with cmp: `$(…)` strips trailing
  # newlines, so a substitution comparison passes on an implementation that drops the last byte of
  # every release body. `jq -j` so no newline is invented on the way out either.
  jq -j '.[0].body' "$PUB_STATE" > "$work/pub-body"
  check_git "$PUB" cat-file tag v9.9.9 > "$work/pub-tagobj" 2>/dev/null
  bash "$RL" tag-message < "$work/pub-tagobj" > "$work/pub-wantnotes"
  if cmp -s "$work/pub-wantnotes" "$work/pub-body"; then ok; else
    bad "publish/absent: the release body is not byte-identical to the tag message"
  fi
  if cmp -s "$work/pub-msg.txt" "$work/pub-body"; then ok; else
    bad "publish/absent: the release body is not byte-identical to the operator's message FILE (--cleanup=verbatim)"
  fi
  eq "$(jq -r '[.[0].assets[].name] | sort | join(",")' "$PUB_STATE")" \
     "SHA256SUMS,ai-dev-baseline-9.9.9.tar.gz" "publish/absent: both assets are attached"
  eq "$(jq -r '.[0].draft' "$PUB_STATE")" false "publish/absent: the release is published, not left a draft"
  # The checksum file must describe the tarball that was actually uploaded — a SHA256SUMS naming a
  # digest nothing on the release has is worse than none, because it reads as verification.
  PUB_SUMHEX="$(awk '{print $1}' "$PUB_STORE/v9.9.9/SHA256SUMS")"
  eq "$PUB_SUMHEX" "$(bash "$RL" sha256 "$PUB_STORE/v9.9.9/ai-dev-baseline-9.9.9.tar.gz")" \
     "publish/absent: SHA256SUMS holds the uploaded tarball's real digest"
  has "$(cat "$PUB_RS")" "PUBLISHED=v9.9.9" "publish/absent: records the publish receipt roll depends on"

  # --- B: re-run converges and mutates nothing ------------------------------------------------------
  cp "$PUB_STATE" "$work/pub-state-before"
  pub_run publish
  eq "$PUB_RC" 0 "publish/published: a re-run against the same release exits clean"
  hasnt "$PUB_CALLS" "release create" "publish/published: creates no second release"
  hasnt "$PUB_CALLS" "release upload" "publish/published: uploads nothing"
  hasnt "$PUB_CALLS" "release edit"   "publish/published: edits nothing"
  if cmp -s "$work/pub-state-before" "$PUB_STATE"; then ok; else
    bad "publish/published: a converging re-run changed the remote state's bytes"
  fi
  # THE RUN STATE IS STATE TOO. `rset` APPENDS, so an unconditional receipt write made every
  # converging re-run add another `PUBLISHED=` line — "re-running changes nothing" was true of the
  # release and false of the file the NEXT step reads.
  eq "$(grep -c '^PUBLISHED=' "$PUB_RS")" 1 "publish/published: the receipt is written once, not appended per run"

  # --- C: an interrupted upload left a DRAFT --------------------------------------------------------
  # Rewound from the real converged state rather than hand-written, so the surviving asset's BYTES
  # are the ones a real interrupted run would have left — a hand-built fixture would be asserting
  # against whatever the fixture author happened to type.
  jq 'map(.draft = true | .assets |= map(select(.name == "SHA256SUMS")))' "$PUB_STATE" > "$PUB_STATE.t" \
    && mv "$PUB_STATE.t" "$PUB_STATE"
  rm -f "$PUB_STORE/v9.9.9/ai-dev-baseline-9.9.9.tar.gz"
  printf '%s\n' "$pub_norm_state" > "$PUB_RS"
  pub_run publish
  eq "$PUB_RC" 0 "publish/draft: resumes the draft (stderr: $PUB_ERR)"
  hasnt "$PUB_CALLS" "release create" "publish/draft: does not create a second release"
  has "$PUB_CALLS" "release upload v9.9.9" "publish/draft: uploads the missing asset"
  hasnt "$PUB_CALLS" "SHA256SUMS" "publish/draft: does NOT re-upload the asset that survived"
  has "$PUB_CALLS" "release edit v9.9.9" "publish/draft: publishes the draft once verified"
  eq "$(jq -r '.[0].draft' "$PUB_STATE")" false "publish/draft: the release is no longer a draft"
  eq "$(jq -r '[.[0].assets[].name] | sort | join(",")' "$PUB_STATE")" \
     "SHA256SUMS,ai-dev-baseline-9.9.9.tar.gz" "publish/draft: both assets present after the resume"
  # THE LATEST FLAG ON THE RESUME PATH. Computed inside the `absent` arm it never reached the edit,
  # and GitHub picks Latest automatically when it is not set — so a resumed backfill could take the
  # badge from the current release.
  eq "$(jq -r '.[0].latest' "$PUB_STATE")" true "publish/draft: the resumed publish still sets Latest explicitly"

  # --- A2: the argument guards, WHERE RUN STATE EXISTS ----------------------------------------------
  # These belong here rather than with the other argument cases: the bug they cover is `--version ""`
  # falling through to NORMAL mode, and normal mode is only distinguishable from a refusal when
  # there IS a VERSION to fall through to. Each asserts the message, because with the guard removed
  # the run would SUCCEED — publishing the in-flight release for an empty argument.
  pub_reset '[]' "$pub_norm_state"
  pub_run publish --version ""
  eq "$PUB_RC" 1 "publish/empty --version: refuses instead of falling back to the run state's VERSION"
  has "$PUB_ERR" "not a version" "publish/empty --version: rejects the value rather than ignoring the flag"
  hasnt "$PUB_CALLS" "release create" "publish/empty --version: publishes nothing"
  pub_run publish --version v1.0.0 --version v2.0.0
  eq "$PUB_RC" 1 "publish/repeated --version: refused"
  has "$PUB_ERR" "given more than once" "publish/repeated --version: says so rather than taking the last"
  pub_run publish --latest --no-latest
  eq "$PUB_RC" 1 "publish/contradictory Latest: refused"
  has "$PUB_ERR" "contradictory" "publish/contradictory Latest: says so rather than taking the last"
  pub_run publish --no-latest --latest
  eq "$PUB_RC" 1 "publish/contradictory Latest: refused in either order"
  pub_run publish --latest --latest
  eq "$PUB_RC" 1 "publish/repeated --latest: refused"

  # --- C2: a create that silently leaves a DRAFT is caught -------------------------------------------
  # `publish_verify` checks the notes and the assets and says nothing about draft status, and the
  # `absent` arm never runs the `--draft=false` edit — so without the final post-condition read, a
  # release that came out a draft would be verified, reported as published, and recorded as the
  # receipt `roll` trusts, while being invisible to every consumer this issue exists to serve.
  # The simulator is told to create drafts for one run, which is the cheapest way to reach that state.
  # A MARKER FILE, not `GH_FORCE_DRAFT=1 pub_run …`. An assignment preceding a FUNCTION call persists
  # in the calling shell in bash — the same trap `rel_case`'s `env` prefix exists to avoid — so that
  # spelling would leave every later case creating drafts.
  : > "$work/pub-force-draft"
  pub_reset '[]' "$pub_norm_state"
  pub_run publish
  rm -f "$work/pub-force-draft"
  eq "$PUB_RC" 1 "publish/silent-draft: refuses when the created release is still a draft"
  has "$PUB_ERR" "not in a published state" "publish/silent-draft: says so rather than reporting success"
  hasnt "$(cat "$PUB_RS")" "PUBLISHED" "publish/silent-draft: records no receipt for an invisible release"

  # --- C3: a DRAFT that is not ours is refused BEFORE anything is uploaded into it ------------------
  # `publish_verify` runs after the uploads, so without an identity check the artifacts would be
  # pushed into someone else's draft and only then refused. The upload IS the mutation.
  pub_reset '[{"tag_name":"v9.9.9","id":1,"draft":true,"body":"a different draft","assets":[]}]' "$pub_norm_state"
  pub_run publish
  eq "$PUB_RC" 1 "publish/foreign-draft: refuses a draft whose notes are not this tag's message"
  has "$PUB_ERR" "refusing to upload into a release this step did not create" "publish/foreign-draft: says why"
  hasnt "$PUB_CALLS" "release upload" "publish/foreign-draft: uploads NOTHING into it"
  hasnt "$PUB_CALLS" "release edit"   "publish/foreign-draft: does not publish it"

  # A draft with the right notes but an asset this step never produces is the same class of doubt.
  jq --rawfile body "$work/pub-wantnotes" \
     '[{tag_name:"v9.9.9", id:1, draft:true, body:$body, assets:[{name:"surprise.bin"}]}]' \
     <<< 'null' > "$PUB_STATE"
  pub_run publish
  eq "$PUB_RC" 1 "publish/foreign-draft-asset: refuses a draft carrying an asset this step did not upload"
  hasnt "$PUB_CALLS" "release upload" "publish/foreign-draft-asset: uploads nothing into it"

  # --- D: a published release whose notes differ is REFUSED, not repaired ---------------------------
  pub_reset '[{"tag_name":"v9.9.9","id":1,"draft":false,"body":"someone else wrote this","assets":[]}]' \
            "$pub_norm_state"
  cp "$PUB_STATE" "$work/pub-state-before"
  pub_run publish
  eq "$PUB_RC" 1 "publish/mismatch: refuses a published release that is not ours"
  has "$PUB_ERR" "not the tag message" "publish/mismatch: says which invariant failed"
  hasnt "$PUB_CALLS" "release edit"   "publish/mismatch: does not edit it"
  hasnt "$PUB_CALLS" "release upload" "publish/mismatch: does not upload over it"
  hasnt "$PUB_CALLS" "release create" "publish/mismatch: does not create a second one"
  if cmp -s "$work/pub-state-before" "$PUB_STATE"; then ok; else
    bad "publish/mismatch: a refusal changed the remote state"
  fi

  # --- E: an asset set that is not ours is REFUSED (extras included) --------------------------------
  jq --rawfile body "$work/pub-wantnotes" \
     '[{tag_name:"v9.9.9", id:1, draft:false, body:$body,
        assets:[{name:"ai-dev-baseline-9.9.9.tar.gz"},{name:"SHA256SUMS"},{name:"surprise.bin"}]}]' \
     <<< 'null' > "$PUB_STATE"
  pub_run publish
  eq "$PUB_RC" 1 "publish/extra-asset: refuses a release carrying an asset this step did not upload"
  has "$PUB_ERR" "assets are" "publish/extra-asset: names the asset sets it compared"

  # --- F: the tag must peel to the VERIFIED merge commit --------------------------------------------
  pub_reset '[]' "VERSION=v9.9.9
MERGE_SHA=0000000000000000000000000000000000000000"
  pub_run publish
  eq "$PUB_RC" 1 "publish/wrong-sha: refuses when origin's tag is not the verified merge commit"
  has "$PUB_ERR" "not the verified merge commit" "publish/wrong-sha: says so"
  hasnt "$PUB_CALLS" "release create" "publish/wrong-sha: nothing was published"

  # --- G: a LIGHTWEIGHT tag has no message, and the message is the notes ----------------------------
  pub_reset '[]'
  pub_run publish --version v8.8.8
  eq "$PUB_RC" 1 "publish/lightweight: refuses a tag with no annotation"
  has "$PUB_ERR" "not an ANNOTATED tag" "publish/lightweight: says why"
  hasnt "$PUB_CALLS" "release create" "publish/lightweight: nothing was published"

  # --- H: a tag that is not on origin at all --------------------------------------------------------
  pub_reset '[]'
  pub_run publish --version v7.7.7
  eq "$PUB_RC" 1 "publish/no-tag: refuses a version with no tag on origin"
  has "$PUB_ERR" "is not on origin" "publish/no-tag: says so, and never asks gh to create one"
  hasnt "$PUB_CALLS" "release create" "publish/no-tag: gh release create is never reached"

  # --- I: a BACKFILL must not write to an unrelated run's state -------------------------------------
  # The scenario is real: an operator backfills an old tag from a checkout where a different release
  # is mid-flight. Stamping PUBLISHED there would tell THAT release its publish step had happened.
  pub_reset '[]' "VERSION=v1.2.3
MERGE_SHA=abc123"
  cp "$PUB_RS" "$work/pub-rs-before"
  pub_run publish --version v9.9.9
  eq "$PUB_RC" 0 "publish/backfill: publishes a historical tag with no run state of its own"
  if cmp -s "$work/pub-rs-before" "$PUB_RS"; then ok; else
    bad "publish/backfill: wrote to another release's run state"
  fi
  hasnt "$(cat "$PUB_RS")" "PUBLISHED" "publish/backfill: records no publish receipt"
  eq "$(jq -r '.[0].draft' "$PUB_STATE")" false "publish/backfill: the historical release is published"
  # A backfill must not steal "Latest" from the version that actually is latest — publishing v2.0.0
  # after v2.1.0 would otherwise point every downstream consumer at the older release.
  has "$PUB_CALLS" "--latest=false" "publish/backfill: a historical release does NOT become Latest"
  eq "$(jq -r '.[0].latest' "$PUB_STATE")" false "publish/backfill: and the platform recorded it as NOT Latest"

  # --- L: a tag pointing off the default branch -----------------------------------------------------
  # The one guard a normal cut can never exercise (its commit is on main by construction) and a
  # backfill absolutely can: a tag pushed from a branch nobody merged.
  pub_reset '[]'
  pub_run publish --version v5.5.5
  eq "$PUB_RC" 1 "publish/off-branch: refuses a tag whose commit is not on the default branch"
  has "$PUB_ERR" "not an ancestor of origin/main" "publish/off-branch: says which invariant failed"
  hasnt "$PUB_CALLS" "release create" "publish/off-branch: nothing was published"

  # --- J: --dry-run makes no GitHub write and no run-state write --------------------------------------
  # NOT "mutates nothing": like every other subcommand it runs `git fetch --prune --tags` first, so
  # local remote-tracking refs and tags do change. The claim asserted here is the one that is true.
  pub_reset '[]' "$pub_norm_state"
  pub_run publish --dry-run
  eq "$PUB_RC" 0 "publish/dry-run: exits clean"
  has "$PUB_OUT" "would publish v9.9.9" "publish/dry-run: prints the plan"
  hasnt "$PUB_CALLS" "release create" "publish/dry-run: creates nothing"
  eq "$(cat "$PUB_STATE")" '[]' "publish/dry-run: the remote state is untouched"
  hasnt "$(cat "$PUB_RS")" "PUBLISHED" "publish/dry-run: records no receipt"

  # --- K: roll refuses without the publish receipt --------------------------------------------------
  # `cmd_roll` deletes the run state as its last act, so a release rolled before it was published can
  # only ever be published through the backfill path afterwards. This is what makes the step ORDER a
  # property rather than a row in a table.
  rel_guard "roll/unpublished" "PUBLISHED not recorded yet — run publish first" 'VERSION=v9.9.9
M_NUM=7
MS_NAME=Next release' roll
  rel_case 'VERSION=v9.9.9
M_NUM=7
MS_NAME=Next release
PUBLISHED=v1.0.0' roll
  eq "$REL_RC" 1 "roll/stale receipt: refuses a PUBLISHED that names another version"
  has "$REL_ERR" "PUBLISHED records" "roll/stale receipt: says which version it found"
  eq "$REL_BL" '' "roll/stale receipt: never reaches the rollover"

  # --- M: the TAG step's own identity guards, driven ------------------------------------------------
  # These need no simulator at all — `cmd_tag` touches only git — but they need the real origin, so
  # they live here rather than with the argument-surface cases above.
  #
  # A tag that already exists is the RESUMED-RUN path (a create that succeeded, a push that did
  # not), and checking only where it POINTS accepts a lightweight tag or a completely different
  # annotation and pushes it — after which `publish` reads THAT message as the release notes.
  printf '%s\n' "$pub_norm_state" > "$PUB_RS"
  pub_run tag --message-file "$work/pub-msg.txt"
  eq "$PUB_RC" 0 "tag/idempotent: re-running with the SAME message file is a clean no-op"

  printf 'v9.9.9\n\nsomething else entirely\n' > "$work/pub-other-msg.txt"
  pub_run tag --message-file "$work/pub-other-msg.txt"
  eq "$PUB_RC" 1 "tag/different message: refuses to push an existing tag whose annotation is not this file"
  has "$PUB_ERR" "DIFFERENT message" "tag/different message: says so"

  printf '   \n\n\t\n' > "$work/pub-blank-msg.txt"
  pub_run tag --message-file "$work/pub-blank-msg.txt"
  eq "$PUB_RC" 1 "tag/blank message: refuses whitespace-only content BEFORE the irreversible push"
  has "$PUB_ERR" "no non-whitespace content" "tag/blank message: says why"

  # v8.8.8 is lightweight and points at the same commit, so a commit-only check would accept it.
  pub_reset '[]' "VERSION=v8.8.8
MERGE_SHA=$PUB_SHA"
  pub_run tag --message-file "$work/pub-msg.txt"
  eq "$PUB_RC" 1 "tag/lightweight: refuses an existing lightweight tag even at the right commit"
  has "$PUB_ERR" "LIGHTWEIGHT" "tag/lightweight: says why rather than pushing a message-less tag"

  # --- N: a tag this step CREATES must be usable as release notes, checked BEFORE the push ----------
  # THE REAL TRAP, DRIVEN. `git tag -a` signs automatically under `tag.gpgSign = true` — no flag is
  # passed and nothing asked for it — and `publish` refuses a signed tag, so without this check that
  # version is permanently locked out of the Release path, because a pushed tag never moves. Found
  # by independent review on PR #330.
  #
  # SIGNED WITH SSH, not GPG: `gpg.format=ssh` needs only `ssh-keygen`, so the case drives a REAL
  # signature without depending on the developer's keyring. Capability is PROBED rather than
  # assumed — a host or git too old for ssh signing gets a stated SKIP, because a case that
  # silently stops exercising its subject is the failure this file exists to catch.
  ssh-keygen -t ed25519 -N '' -f "$work/pub-sk" -q >/dev/null 2>&1
  pub_can_sign=0
  if [ -f "$work/pub-sk" ] \
     && check_git "$PUB" -c gpg.format=ssh -c user.signingkey="$work/pub-sk" -c tag.gpgSign=true \
          tag -a v3.3.3 --cleanup=verbatim -F "$work/pub-msg.txt" >/dev/null 2>&1 \
     && [ "$(check_git "$PUB" cat-file -t v3.3.3 2>/dev/null)" = "tag" ]; then
    check_git "$PUB" cat-file tag v3.3.3 2>/dev/null | bash "$RL" tag-message >/dev/null 2>&1 \
      || pub_can_sign=1
  fi
  check_git "$PUB" tag -d v3.3.3 >/dev/null 2>&1 || true
  if [ "$pub_can_sign" -eq 1 ]; then
    ok
    check_git "$PUB" config tag.gpgSign true >/dev/null 2>&1
    check_git "$PUB" config gpg.format ssh >/dev/null 2>&1
    check_git "$PUB" config user.signingkey "$work/pub-sk" >/dev/null 2>&1
    pub_reset '[]' "VERSION=v4.4.4
MERGE_SHA=$PUB_SHA"
    pub_run tag --message-file "$work/pub-msg.txt"
    eq "$PUB_RC" 1 "tag/auto-signed: refuses a tag git signed on its own (tag.gpgSign)"
    has "$PUB_ERR" "cannot be used as release notes" "tag/auto-signed: says why, and names tag.gpgSign"
    # THE LOCAL TAG IS GONE and NOTHING WAS PUSHED — the two halves that make this a safe refusal
    # rather than a half-finished release. Deleting it is legitimate precisely because it was never
    # pushed; leaving it would make the retry fail for a second, more confusing reason.
    if check_git "$PUB" rev-parse -q --verify refs/tags/v4.4.4 >/dev/null 2>&1; then
      bad "tag/auto-signed: the unusable local tag was left behind"
    else ok; fi
    if check_git "$PUB" ls-remote --exit-code --tags origin refs/tags/v4.4.4 >/dev/null 2>&1; then
      bad "tag/auto-signed: an unusable tag reached origin — it can never be moved"
    else ok; fi
    check_git "$PUB" config --unset tag.gpgSign >/dev/null 2>&1 || true
    check_git "$PUB" config --unset gpg.format >/dev/null 2>&1 || true
    check_git "$PUB" config --unset user.signingkey >/dev/null 2>&1 || true
  else
    printf 'release-skill: SKIP — ssh tag signing unavailable here, so the auto-signed-tag case did not run\n' >&2
    ok
  fi

  # --- O: preflight refuses when the PUBLISH step's tools are absent --------------------------------
  # The point is WHEN, not whether: without these the first failure is at step 11, after step 10 has
  # permanently pushed the tag.
  #
  # TWO SHADOW PATHS, ONE PER TOOL, because the checks COVER FOR EACH OTHER. The first cut removed
  # both tools at once, so deleting either check left the other one refusing with a message the
  # assertion still matched — both mutations came back green against a suite that looked thorough.
  #
  # Each mirror is PATH minus exactly one name, not a hand-listed allowlist: an earlier attempt
  # enumerated the tools preflight "needs", omitted `bash` itself, and died 127 before reaching the
  # check — a fixture failure wearing the assertion's clothes.
  pub_shadow() {   # <dir> <name-to-omit>…
    local dir="$1"; shift
    mkdir -p "$dir"
    local d f b skip
    for d in /bin /usr/bin /usr/sbin /sbin /opt/homebrew/bin /usr/local/bin; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        b="${f##*/}"; skip=0
        for n in "$@"; do [ "$b" = "$n" ] && skip=1; done
        [ "$skip" -eq 1 ] && continue
        [ -e "$dir/$b" ] || ln -s "$f" "$dir/$b" 2>/dev/null
      done
    done
    cp "$PUBGH/gh" "$dir/gh" 2>/dev/null || true
  }
  pub_preflight_on() {   # <bin-dir> -> PUB_PRE_RC / PUB_PRE_ERR
    PUB_PRE_RC=0
    adb_run_bounded 60 5 env "PATH=$1" "GH_CALLS=$work/pub-calls" \
        "GH_STATE=$PUB_STATE" "GH_ASSETS=$PUB_STORE" "GH_TAGS=$PUB_TAGS" "GH_SLUG=acme/widget" \
        bash "$PUB_DRV" preflight > "$work/pre-out" 2> "$work/pre-err" || PUB_PRE_RC=$?
    PUB_PRE_ERR="$(cat "$work/pre-err")"
  }
  pub_shadow "$work/nogzip" gzip
  pub_preflight_on "$work/nogzip"
  eq "$PUB_PRE_RC" 1 "preflight/no gzip: refuses at step 1 rather than at step 11"
  has "$PUB_PRE_ERR" "gzip not found" "preflight/no gzip: names the missing tool"
  pub_shadow "$work/nohash" sha256sum shasum openssl
  pub_preflight_on "$work/nohash"
  eq "$PUB_PRE_RC" 1 "preflight/no hash tool: refuses at step 1 rather than at step 11"
  has "$PUB_PRE_ERR" "no SHA-256 utility" "preflight/no hash tool: names what it looked for"

  # --- MUTATION PROOF: "fails when the publish step is removed or stubbed out" -----------------------
  # The acceptance criterion, executed. Each mutation is applied to the COPIED driver and each is
  # required to redden a NAMED assertion above — a publish step that silently no-ops looks exactly
  # like one that succeeded, which is the whole reason this section exists.
  pub_restore() { cp "$work/pristine-publish.sh" "$PUB_DRV"; }

  # M4 — remove the dispatch. The subcommand simply stops existing.
  pub_restore
  if check_mutate_line "$PUB_DRV" '    publish)        cmd_publish "$@" ;;' \
       '/^    publish)        cmd_publish "\$@" ;;$/d' "M4 publish dispatch removed"; then
    pub_reset '[]' "$pub_norm_state"
    pub_run publish
    if [ "$PUB_RC" = "0" ]; then
      bad "M4: publish still exited 0 with its dispatch deleted — case A cannot go red"
    else ok; fi
    eq "$(cat "$PUB_STATE")" '[]' "M4: and nothing was published"
  fi

  # M5 — keep the dispatch, neuter the EFFECT. `true` swallows the same arguments and succeeds, so
  # the step reports success having created nothing: the exact silent no-op the criterion names.
  pub_restore
  if check_mutate_line "$PUB_DRV" \
       '      gh release create "$v" -R "$pub_sl" --verify-tag --title "$v" \' \
       's|^      gh release create |      true |' "M5 publish create stubbed out"; then
    pub_reset '[]' "$pub_norm_state"
    pub_run publish
    if [ "$PUB_RC" = "0" ]; then
      bad "M5: a publish that created nothing still exited 0 — the read-back verification proves nothing"
    else ok; fi
    has "$PUB_ERR" "has no release after the publish step ran" "M5: the verification is what catches it"
  fi

  # M6 — drop `--verify-tag`, and say EXACTLY what that proves. It reddens case A's assertion that
  # the flag is passed, and nothing more: the driver's own `ls-remote` guard stops a nonexistent tag
  # before `gh` is ever reached, so this mutation cannot reach the simulator's forged-tag path and
  # does NOT demonstrate a tag being minted. The flag is a BACKSTOP for paths the primary guard does
  # not cover, and a backstop's test can only assert that it is present. An earlier comment here
  # claimed the mutation forged a tag; it does not, and overstating a witness is the same defect as
  # a guard that cannot fire.
  pub_restore
  if check_mutate_line "$PUB_DRV" \
       '      gh release create "$v" -R "$pub_sl" --verify-tag --title "$v" \' \
       's|--verify-tag ||' "M6 --verify-tag dropped"; then
    pub_reset '[]' "VERSION=v6.6.6
MERGE_SHA=$PUB_SHA"
    # v6.6.6 has no tag, so the driver's own ls-remote guard stops it first. That is the PRIMARY
    # guard doing its job, which is worth pinning on its own — it is not evidence about the flag.
    pub_run publish
    eq "$PUB_RC" 1 "M6: the ls-remote guard still refuses a version with no tag"
    pub_reset '[]' "$pub_norm_state"
    pub_run publish
    case "$PUB_CALLS" in
      *--verify-tag*) bad "M6: --verify-tag survived the mutation, so case A's assertion about it proves nothing" ;;
      *) ok ;;
    esac
  fi
  pub_restore
fi

check_summary "release-skill"
