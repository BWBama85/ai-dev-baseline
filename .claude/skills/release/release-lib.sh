#!/usr/bin/env bash
# ai-dev-baseline — THIS PROJECT'S release predicates (decision D14; skill: ./SKILL.md).
#
# WHY THIS FILE EXISTS, AND WHY IT IS HERE RATHER THAN IN scripts/lib/
#
# The first cut of `/release` put its whole procedure in SKILL.md prose with inline shell. Two
# review rounds found 17 defects in it, one fatal (a `{{ROADMAP_LIB}}` build placeholder pasted
# into a runnable step, so every release would have died with `command not found`). The defects
# were not careless typing — they were the predictable cost of putting DECISIONS in a medium no
# test can execute. This repo already learned that lesson three times: `cleanup-lib.sh` (#106/#84),
# `roadmap-lib.sh` (#69), `pr-review.sh` (#134) were all extracted from workflow prose for exactly
# this reason. `/release` is the fourth, and it is the one holding an IRREVERSIBLE act.
#
# It is NOT in `scripts/lib/`, and that is deliberate. `adb_agent_manifest` (common.sh:175) links
# `$repo/scripts/lib` -> `$home/.claude/scripts/lib` as a WHOLE DIRECTORY, so anything dropped
# there installs into every adopting project. Decision #3/D7 says the baseline ships no generic
# release machinery, precisely because a four-project sweep found four mutually incompatible
# release schemes. The predicates below encode THIS repo's scheme — Keep a Changelog headings,
# `vX.Y.Z` tags, and this repo's compare-link URL shape — so shipping them to everyone would be
# D7 reversed by accident. They live beside the skill that owns them.
#
# What is NOT here, because a tested home already exists — never re-derive these:
#   * version ordering        -> `adb_version_ge` (scripts/lib/common.sh)
#   * is the branch green     -> `roadmap-lib.sh branch-health`
#   * release readiness       -> `roadmap-lib.sh release-ready` / `release-counts`
#   * the release-milestone marker -> `roadmap-lib.sh marker-title` (returns EVERY distinct title,
#                                     so the caller can refuse an ambiguous artifact)
#
# Regression-tested offline by `scripts/check-release-skill.sh`, wired into selfcheck + CI.
#
# Usage:
#   release-lib.sh version-ok <version>            # existing versions on stdin, one per line
#   release-lib.sh changelog-verify <version> <last> <slug> <today>   # CHANGELOG on stdin
#   release-lib.sh unreleased-entries              # PRE-STAMP CHANGELOG on stdin
#   release-lib.sh checks-settled <expected>       # check-runs JSON on stdin
#   release-lib.sh -h | --help
#
# Exit codes are a stable machine contract:
#   version-ok        0 ok · 2 malformed · 3 already used · 4 not newer than the latest known
#   changelog-verify  0 ok · 5 a required assertion failed (reason on stderr)
#   checks-settled    0 settled · 6 pending · 7 none registered · 8 short of expected
#   unreleased-entries 0 has entries (count on stdout) · 9 nothing to release
#   any               2 usage

set -u

die() { printf 'release-lib: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# --- version-ok --------------------------------------------------------------------------------
# A shell glob is NOT a validator: `v[0-9]*.[0-9]*.[0-9]*` accepts `v1.2.3-rc1`, `v1x.2.3` and
# `v1.2.3.4`, because `*` consumes anything. Every component is checked as digits-only, and the
# component COUNT is checked as exactly three. `adb_version_ge` coerces junk components to 0, so a
# malformed value that reached it would compare as something it is not.
cmd_version_ok() {
  [ "$#" -eq 1 ] || die "version-ok: needs exactly <version>"
  v="$1"
  case "$v" in
    v*) bare="${v#v}" ;;
    *) printf 'version-ok: %s must start with `v`\n' "$v" >&2; exit 2 ;;
  esac
  # Reject a leading, trailing or doubled dot BEFORE the loop. The loop alone cannot see a TRAILING
  # one: for `1.2.3.` it consumes 1, 2, 3, then `${rest#*.}` yields the empty string and it exits
  # with n=3 — so `v1.2.3.` validated, was printed back as the bare version, and would have been
  # written into the changelog and used as a permanent tag. (A leading or doubled dot does surface
  # as an empty component inside the loop; they are folded in here so one guard covers the family.)
  case "$bare" in
    .*|*.|*..*) printf 'version-ok: %s has an empty component (leading, trailing or doubled dot)\n' "$v" >&2; exit 2 ;;
  esac
  # Exactly three dot-separated, all-digit components. Leading zeros are rejected too (`v1.02.3`
  # would tag differently than it reads).
  n=0; rest="$bare"
  while [ -n "$rest" ]; do
    comp="${rest%%.*}"
    case "$comp" in
      ''|*[!0-9]*) printf 'version-ok: %s has a non-numeric component (%s)\n' "$v" "$comp" >&2; exit 2 ;;
    esac
    case "$comp" in
      0) : ;;
      0*) printf 'version-ok: %s has a leading-zero component (%s)\n' "$v" "$comp" >&2; exit 2 ;;
    esac
    n=$((n + 1))
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
  done
  [ "$n" -eq 3 ] || { printf 'version-ok: %s must have exactly 3 components (got %s)\n' "$v" "$n" >&2; exit 2; }

  # Existing versions on stdin: tags and/or changelog headings, with or without a `v`. Compared
  # BARE so `v1.1.0` and `1.1.0` are recognised as the same release.
  best=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    eb="${line#v}"
    [ "$eb" = "$bare" ] && { printf 'version-ok: %s is already used (matched "%s")\n' "$v" "$line" >&2; exit 3; }
    if [ -z "$best" ] || adb_version_ge "$eb" "$best"; then best="$eb"; fi
  done
  if [ -n "$best" ]; then
    adb_version_ge "$bare" "$best" || { printf 'version-ok: %s is not newer than %s\n' "$v" "$best" >&2; exit 4; }
  fi
  printf '%s\n' "$bare"
  return 0
}

# SOURCE the shared comparator; never re-implement it. This file previously carried a local copy
# with a comment claiming the skill used `adb_version_ge` — it did not, the copy WAS the active
# comparator. That is CLAUDE.md Golden Rule 4 ("source the shared primitives, never copy them")
# broken while quoting it, and the cost is real: a future fix to ordering semantics in common.sh
# would leave release validation silently disagreeing with the rest of the framework.
#
# Resolved relative to this file first (the layout is fixed: .claude/skills/release/ -> repo root),
# with a git-root fallback so the predicate still resolves when invoked through a symlink or from
# an unusual working directory.
_ADB_SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
_ADB_COMMON="$_ADB_SELF_DIR/../../../scripts/lib/common.sh"
if [ ! -f "$_ADB_COMMON" ]; then
  _ADB_ROOT="$(git -C "$_ADB_SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  _ADB_COMMON="$_ADB_ROOT/scripts/lib/common.sh"
fi
[ -f "$_ADB_COMMON" ] || { printf 'release-lib: cannot locate scripts/lib/common.sh\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$_ADB_COMMON"
command -v adb_version_ge >/dev/null 2>&1 \
  || { printf 'release-lib: common.sh did not provide adb_version_ge\n' >&2; exit 2; }

# --- changelog-verify --------------------------------------------------------------------------
# Asserts the stamp mechanically. Every comparison is FIXED-STRING and whole-line where the text
# allows: a version like `1.1.0` is all `.` metacharacters, and a plain `grep` accepts `1x1x0` —
# that bug was written, shipped into review, and caught only by a hand-run fixture.
#
# The link refs are matched WHOLE, derived from slug/last/version. A "does `[1.1.0]: ` appear"
# test passes on a link comparing the WRONG previous tag, which is the exact navigation the
# changelog exists to provide.
cmd_changelog_verify() {
  [ "$#" -eq 4 ] || die "changelog-verify: needs <version> <last> <slug> <today>"
  ver="$1"; last="$2"; slug="$3"; today="$4"
  case "$ver" in v*) bare="${ver#v}" ;; *) die "changelog-verify: <version> must start with v" ;; esac
  body="$(cat)"
  base="https://github.com/$slug"
  rc=0
  _has() { printf '%s\n' "$body" | grep -Fxq "$1" || { printf 'changelog-verify: missing exact line: %s\n' "$1" >&2; rc=5; }; }

  _has '## [Unreleased]'
  _has "## [$bare] - $today"
  _has "[Unreleased]: $base/compare/$ver...HEAD"
  if [ -n "$last" ]; then
    _has "[$bare]: $base/compare/$last...$ver"
  else
    # Only the FIRST tag uses the releases/tag shape; every later one is a compare range.
    _has "[$bare]: $base/releases/tag/$ver"
  fi

  # [Unreleased] must be EMPTY: its heading, one blank line, then the new version heading. Line
  # numbers are compared in the shell rather than interpolating the version into an awk regex,
  # for the same metacharacter reason as above.
  nu="$(printf '%s\n' "$body" | grep -Fxn '## [Unreleased]' | cut -d: -f1 | head -n1)"
  nv="$(printf '%s\n' "$body" | grep -Fxn "## [$bare] - $today" | cut -d: -f1 | head -n1)"
  if [ -n "$nu" ] && [ -n "$nv" ]; then
    [ "$((nv - nu))" -eq 2 ] || {
      printf 'changelog-verify: [Unreleased] is not empty (heading gap %s, expected 2)\n' "$((nv - nu))" >&2; rc=5; }
  fi
  [ "$rc" -eq 0 ] && printf 'changelog ok: %s\n' "$ver"
  return "$rc"
}

# --- unreleased-entries ------------------------------------------------------------------------
# "Is there anything to release?" — asked on the PRE-STAMP changelog, before the branch is cut.
#
# `changelog-verify` cannot answer this: it only ever sees the POST-edit file, where [Unreleased]
# is empty BY CONSTRUCTION (that is what it asserts). So "refuse an empty release" was carried
# only by a prose instruction — an agent that skipped the sentence would stamp a version heading
# over nothing, push an irreversible tag, and all 37 assertions would stay green. This is the
# executable half of that refusal.
#
# An "entry" is any non-blank, non-comment line between `## [Unreleased]` and the next `## [`
# heading. A bare `### Added` with nothing under it is NOT an entry — an empty subsection is
# exactly the shape a half-finished release leaves behind.
cmd_unreleased_entries() {
  [ "$#" -eq 0 ] || die "unreleased-entries: takes no arguments (CHANGELOG on stdin)"
  # HTML-comment state is tracked ACROSS lines. Recognising only a single-line `<!-- … -->` skips
  # the opening line of a MULTILINE comment and then counts its body as release entries — so a
  # section holding nothing but a placeholder comment reported "has entries" and would have let an
  # empty release through to a permanent tag, which is the one thing this predicate exists to stop.
  count="$(awk '
    /^## \[Unreleased\]/ { inblock = 1; next }
    /^## \[/             { inblock = 0 }
    inblock {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (incomment) {
        if (line ~ /-->/) { sub(/^.*-->/, "", line); incomment = 0 } else next
        sub(/^[[:space:]]+/, "", line)
        if (line == "") next
      }
      # Strip any number of complete single-line comments, then detect an unterminated opener.
      while (line ~ /<!--.*-->/) { sub(/<!--.*?-->/, "", line) }
      if (line ~ /<!--/) { sub(/<!--.*$/, "", line); incomment = 1 }
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "") next                 # blank, or nothing left after comment removal
      if (line ~ /^###/) next              # a subsection heading is not itself an entry
      n++
    }
    END { print n + 0 }
  ')"
  printf '%s\n' "$count"
  [ "$count" -gt 0 ] || return 9
  return 0
}

# --- checks-settled ----------------------------------------------------------------------------
# "Are this commit's checks DONE?" — deliberately NOT "are they green" (that is
# `roadmap-lib.sh branch-health`, which owns the Checks + commit-status union and the fail-closed
# rule). Two ways to get this wrong, both of which tag an unverified commit:
#
#   1. TREATING AN EMPTY SET AS COMPLETE. Zero check runs means CI has not registered on this
#      commit yet, not that everything passed. -> `none`.
#   2. TREATING THE CURRENTLY-REGISTERED SET AS THE WHOLE SET. GitHub registers jobs
#      INCREMENTALLY: on a repo with ~26 independent jobs, a fast one can complete before the
#      others appear, so "nothing is pending" is briefly true and catastrophically wrong. That is
#      why <expected> is required — normally the number of checks that ran on the reviewed head,
#      since the same CI config produced them. -> `short` until the set is at least that big.
cmd_checks_settled() {
  [ "$#" -eq 1 ] || die "checks-settled: needs <expected>"
  case "$1" in ''|*[!0-9]*) die "checks-settled: <expected> must be a non-negative integer" ;; esac
  expected="$1"
  command -v jq >/dev/null 2>&1 || die "checks-settled: jq not found"
  json="$(cat)"
  total="$(printf '%s' "$json" | jq -s '[.[].check_runs[]?] | length' 2>/dev/null)" \
    || die "checks-settled: unreadable check-run JSON"
  [ -n "$total" ] || die "checks-settled: unreadable check-run JSON"
  pending="$(printf '%s' "$json" | jq -s '[.[].check_runs[]? | select(.status != "completed")] | length' 2>/dev/null)" \
    || die "checks-settled: unreadable check-run JSON"

  if [ "$total" -eq 0 ]; then
    printf 'none 0/%s\n' "$expected"; return 7
  fi
  if [ "$total" -lt "$expected" ]; then
    printf 'short %s/%s\n' "$total" "$expected"; return 8
  fi
  if [ "$pending" -gt 0 ]; then
    printf 'pending %s/%s\n' "$pending" "$total"; return 6
  fi
  printf 'settled %s/%s\n' "$total" "$expected"
  return 0
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  sub="$1"; shift
  case "$sub" in
    version-ok)       cmd_version_ok "$@" ;;
    changelog-verify) cmd_changelog_verify "$@" ;;
    unreleased-entries) cmd_unreleased_entries "$@" ;;
    checks-settled)   cmd_checks_settled "$@" ;;
    -h|--help)        usage ;;
    *) printf 'release-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
