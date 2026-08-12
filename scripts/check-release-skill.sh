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

check_summary "release-skill"
