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
#   release-lib.sh version-format <version>        # FORMAT only — no reuse/ordering rules
#   release-lib.sh changelog-verify <version> <last> <slug> <today>   # CHANGELOG on stdin
#   release-lib.sh unreleased-entries              # PRE-STAMP CHANGELOG on stdin
#   release-lib.sh checks-settled <expected>       # check-runs JSON on stdin
#   release-lib.sh tag-message                     # raw `git cat-file tag` output on stdin
#   release-lib.sh release-state <tag>             # releases JSON on stdin
#   release-lib.sh sha256 <file>
#   release-lib.sh -h | --help
#
# Exit codes are a stable machine contract:
#   version-ok        0 ok · 2 malformed · 3 already used · 4 not newer than the latest known
#   version-format    0 ok · 2 malformed
#   changelog-verify  0 ok · 5 a required assertion failed (reason on stderr)
#   checks-settled    0 settled · 6 pending · 7 none registered · 8 short of expected
#   unreleased-entries 0 has entries (count on stdout) · 9 nothing to release
#   release-state     0 absent · 10 draft · 11 published · 14 ambiguous (>1 for one tag)
#   tag-message       0 ok · 12 signed tag (unsupported) · 13 empty message
#   sha256            0 ok (lowercase hex on stdout)
#   any               2 — usage, OR an input this library refuses to interpret (unreadable JSON, a
#                     malformed tag object, a missing hash tool). Both are "I cannot answer", which
#                     is the distinction the exit code carries; "the answer is no" always has its
#                     own code above.

set -u

# bash 5.3 runtime floor (#256) — the bootstrap is FIRST, ahead of every function definition below.
#
# Not merely tidiness: bash parses a function's body when it reaches the definition, so once
# #258/#259 put 5.3-only grammar in any function down there, a 3.2 interpreter would fail to PARSE
# this file before it ever reached the gate that exists to rescue it. The gate has to precede the
# code it protects, not sit in the middle of it. (It also has to precede the `read` loops further
# down: the re-exec restarts this script with stdin inherited, so anything already consumed is
# gone.) Independent review caught both.
#
# Resolved relative to this file first (the layout is fixed: .claude/skills/release/ -> repo root),
# with a git-root fallback so it still resolves through a symlink or from an unusual cwd.
_adb_boot_src="$0"; _adb_boot_rel="."
# ADB-BOOTSTRAP-BEGIN (#343) — BYTE-IDENTICAL IN EVERY ENTRY POINT; pinned by scripts/check-bootstrap.sh,
# which carries why each line is shaped this way. Lossless because `$(…)` strips every trailing newline:
# `${src%/*}` cannot strip, and the `X` sentinel bounds what the `pwd` capture can. Logical `pwd` (not
# `-P`) preserves how install.sh records its symlink targets. bash 3.2-safe: this runs before the gate.
_adb_boot_dir="${_adb_boot_src%/*}"
if [ "$_adb_boot_dir" = "$_adb_boot_src" ]; then _adb_boot_dir="."; elif [ -z "$_adb_boot_dir" ]; then _adb_boot_dir="/"; fi
_adb_boot_abs="$(cd -- "$_adb_boot_dir/$_adb_boot_rel" && pwd && printf 'X')"
_adb_boot_abs="${_adb_boot_abs%X}"; _adb_boot_abs="${_adb_boot_abs%$'\n'}"
[ -n "$_adb_boot_abs" ] || { printf '%s: FATAL - cannot resolve this clone location.\n' "${0##*/}" >&2; exit 1; }
# ADB-BOOTSTRAP-END
_ADB_SELF_DIR="$_adb_boot_abs"
_ADB_COMMON="$_ADB_SELF_DIR/../../../scripts/lib/common.sh"
if [ ! -f "$_ADB_COMMON" ]; then
  _ADB_ROOT="$(git -C "$_ADB_SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  _ADB_COMMON="$_ADB_ROOT/scripts/lib/common.sh"
fi
[ -f "$_ADB_COMMON" ] || { printf 'release-lib: cannot locate scripts/lib/common.sh\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$_ADB_COMMON"
adb_require_bash "$@"

die() { printf 'release-lib: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# --- version-ok --------------------------------------------------------------------------------
# A shell glob is NOT a validator: `v[0-9]*.[0-9]*.[0-9]*` accepts `v1.2.3-rc1`, `v1x.2.3` and
# `v1.2.3.4`, because `*` consumes anything. Every component is checked as digits-only, and the
# component COUNT is checked as exactly three. `adb_version_ge` coerces junk components to 0, so a
# malformed value that reached it would compare as something it is not.
# THE FORMAT HALF IS ITS OWN FUNCTION, and that split is what `version-format` exists for (#284).
#
# `version-ok` answers three questions at once — is it well formed, is it unused, is it newer — and
# for a NEW cut all three are wanted. A BACKFILL publishes a release for a tag that is already used
# and is by definition not newer, so `version-ok` rejects every valid backfill target on rules that
# do not apply to it. The tempting shortcut is for the publish step to skip validation entirely and
# interpolate whatever the operator typed; that value reaches `git ls-remote`, a `repos/<slug>/...`
# request path and an asset FILENAME, so "unvalidated" is the wrong direction to relax in.
#
# Hence one parser with two entry points, rather than a second spelling of the rules living in the
# driver. `_version_format` SETS `bare` and returns 0, or explains on stderr and returns 2. It
# prints nothing: its callers print, because a value returned through stdout would have to be
# captured in a command substitution, and that subshell is what makes a `return 2` unnoticeable.
_version_format() {
  label="$1"; v="$2"
  case "$v" in
    v*) bare="${v#v}" ;;
    *) printf '%s: %s must start with `v`\n' "$label" "$v" >&2; return 2 ;;
  esac
  # Reject a leading, trailing or doubled dot BEFORE the loop. The loop alone cannot see a TRAILING
  # one: for `1.2.3.` it consumes 1, 2, 3, then `${rest#*.}` yields the empty string and it exits
  # with n=3 — so `v1.2.3.` validated, was printed back as the bare version, and would have been
  # written into the changelog and used as a permanent tag. (A leading or doubled dot does surface
  # as an empty component inside the loop; they are folded in here so one guard covers the family.)
  case "$bare" in
    .*|*.|*..*) printf '%s: %s has an empty component (leading, trailing or doubled dot)\n' "$label" "$v" >&2; return 2 ;;
  esac
  # Exactly three dot-separated, all-digit components. Leading zeros are rejected too (`v1.02.3`
  # would tag differently than it reads).
  n=0; rest="$bare"
  while [ -n "$rest" ]; do
    comp="${rest%%.*}"
    case "$comp" in
      ''|*[!0-9]*) printf '%s: %s has a non-numeric component (%s)\n' "$label" "$v" "$comp" >&2; return 2 ;;
    esac
    case "$comp" in
      0) : ;;
      0*) printf '%s: %s has a leading-zero component (%s)\n' "$label" "$v" "$comp" >&2; return 2 ;;
    esac
    n=$((n + 1))
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
  done
  [ "$n" -eq 3 ] || { printf '%s: %s must have exactly 3 components (got %s)\n' "$label" "$v" "$n" >&2; return 2; }
  return 0
}

cmd_version_format() {
  [ "$#" -eq 1 ] || die "version-format: needs exactly <version>"
  # NOT `bare="$(_version_format …)"`, and `_version_format` does not print — it sets `bare`: a
  # command substitution is a subshell,
  # so the function's `return 2` would be the SUBSHELL's status while this function carried on —
  # the same shape `release.sh`'s `need` header documents from #313. Called as a plain command its
  # status is this shell's to branch on, and it leaves `bare` set for the caller to print.
  _version_format version-format "$1" || exit 2
  printf '%s\n' "$bare"
  return 0
}

cmd_version_ok() {
  [ "$#" -eq 1 ] || die "version-ok: needs exactly <version>"
  v="$1"
  _version_format version-ok "$v" || exit 2

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
#      why <expected> is required. -> `short` until the set is at least that big.
#
# COUNT DISTINCT NAMES, NOT CHECK RUNS — and the difference is not cosmetic, it is the whole
# reason a bar recorded on one commit can be applied to another. `<expected>` is normally taken
# from the reviewed PR head, and the tempting premise ("the same CI config produced both, so the
# counts match") is FALSE whenever a workflow carries both an unfiltered `push:` and a
# `pull_request:` trigger. A PR branch head then receives BOTH runs and every job name appears
# TWICE, while the merge commit on the default branch receives only the `push:` run. Measured live
# on v2.0.0, when this repo's own `ci.yml` was shaped that way: the reviewed head 25cca85 carried
# **54** check runs over **27** distinct names; the merge commit 1c02f24 carried **27** runs over
# the SAME 27 names, all successful. A raw-count bar of 54 is therefore unreachable on any merge
# commit in such a repo — `verify-merge` spent its full 90 iterations and refused to tag a release
# that was genuinely green.
#
# THIS REPO NO LONGER HAS THAT SHAPE, AND THE RULE IS UNCHANGED (#165). `ci.yml` now filters
# `push:` to `main`, so a PR head here receives 27 runs over 27 names rather than 54 — the
# asymmetry that produced the v2.0.0 regression is gone from *this* repo. Counting distinct names
# stays correct for two reasons that never depended on it: a **re-run** duplicates a name on any
# repo, and this library is the project-scoped `/release` every adopting repo is told to copy
# (D7/D14) — and an adopting repo may well carry unfiltered triggers. A bar that is only right
# under one trigger shape is the bug, not the fix.
#
# Distinct names are invariant across that trigger asymmetry while still catching hazard 2: an
# incrementally-registering set has FEWER names, not fewer duplicates. A job that is genuinely
# missing from the merge commit still shows up as `short`, which is the property being protected.
# Duplicate runs of one name are also exactly what a re-run produces, and a re-run must not inflate
# the bar for the next commit either.
cmd_checks_settled() {
  [ "$#" -eq 1 ] || die "checks-settled: needs <expected>"
  case "$1" in ''|*[!0-9]*) die "checks-settled: <expected> must be a non-negative integer" ;; esac
  expected="$1"
  command -v jq >/dev/null 2>&1 || die "checks-settled: jq not found"
  json="$(cat)"
  # `unique` over names, so two runs of `shellcheck` count once. A run with no `name` would
  # collapse every such run into one bucket, so they are counted individually via `// empty` +
  # the raw-run fallback below rather than silently merged under `null`.
  total="$(printf '%s' "$json" | jq -s '[.[].check_runs[]?.name // empty] | unique | length' 2>/dev/null)" \
    || die "checks-settled: unreadable check-run JSON"
  [ -n "$total" ] || die "checks-settled: unreadable check-run JSON"
  # A check run without a `name` is not nameless in practice, but if the API ever returns one it
  # must not vanish from the count — that would under-report and read as `short` forever.
  unnamed="$(printf '%s' "$json" | jq -s '[.[].check_runs[]? | select(has("name") | not)] | length' 2>/dev/null)" \
    || die "checks-settled: unreadable check-run JSON"
  total=$((total + unnamed))
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

# --- tag-message -------------------------------------------------------------------------------
# The release notes ARE the tag message (#284), so this extracts the message from a raw tag object
# — `git cat-file tag <v>` on stdin — byte for byte.
#
# WHY THE TAG OBJECT AND NOT THE MESSAGE FILE. The acceptance criterion is that a release's notes
# are byte-identical to the tag message, and there are two candidate subjects for "the tag message":
# the file the operator wrote, and the annotation git actually stored. They are NOT the same string
# unless the tag was created with `--cleanup=verbatim` — measured here, git's default cleanup for
# `git tag -F` DELETED a `# A markdown heading line` from an 80-byte message, storing 54. Release
# notes are Markdown, so a `#`-leading line is ordinary content, not a comment.
#
# `release.sh cmd_tag` therefore passes `--cleanup=verbatim`, and this reads the stored annotation.
# That makes the two subjects the same string by construction, and it is the only one of the two
# that still EXISTS for a backfill of a tag pushed months ago — the message file is long gone.
#
# NOT `%(contents)`: for-each-ref appends a newline that is not part of the message, so a caller
# comparing its output against the operator's file is off by one byte in a way nothing announces.
# A tag object is `<headers>\n\n<message>`, so everything after the first empty line is the message.
#
# A SIGNED TAG IS REFUSED rather than published. Its signature lives inside the message region, so
# the extraction would carry `-----BEGIN PGP SIGNATURE-----` and its base64 into the release notes.
# This repo does not sign tags; a repo that does needs a `%(contents:body)`-shaped split, and
# refusing loudly is the honest placeholder for work nobody has done.
cmd_tag_message() {
  [ "$#" -eq 0 ] || die "tag-message: takes no arguments (raw tag object on stdin)"
  # BYTE OFFSETS AND `tail -c`, NOT A LINE-ORIENTED FILTER. Every line tool terminates the last
  # line it emits, so `awk`/`sed` silently ADD a final newline to a message stored without one —
  # reproduced by independent review: a 19-byte annotation came back as 20 bytes, which breaks the
  # one property this predicate exists to provide. `tail -c` copies the remaining bytes verbatim,
  # including the absence of that newline.
  #
  # An earlier cut used `msg="$(awk …; printf X)"` with a sentinel to protect the trailing newline
  # from command substitution. It protected the newline and lost something else: the substitution's
  # status became `printf`'s, so an `awk` that emitted a PARTIAL message and exited non-zero
  # returned 0 here and the partial output was published. A guard whose failure mode is "succeed"
  # is the one shape this repo keeps writing down.
  tm_raw="$(mktemp)" || die "tag-message: cannot create a temporary file"
  tm_msg="$tm_raw.msg"
  cat > "$tm_raw" || { rm -f "$tm_raw"; die "tag-message: could not read the tag object"; }
  # LC_ALL=C so `length()` counts BYTES. In a UTF-8 locale it counts characters, and a header with
  # a non-ASCII tagger name would then yield an offset shorter than the header actually is,
  # prefixing the notes with the tail of a header line.
  tm_off="$(LC_ALL=C awk '{ n += length($0) + 1 } /^$/ { print n; exit }' "$tm_raw")" \
    || { rm -f "$tm_raw"; die "tag-message: could not scan the tag object"; }
  [ -n "$tm_off" ] \
    || { rm -f "$tm_raw"; die "tag-message: no blank line separates the tag headers from the message"; }
  tail -c "+$((tm_off + 1))" "$tm_raw" > "$tm_msg" \
    || { rm -f "$tm_raw" "$tm_msg"; die "tag-message: could not extract the message"; }

  # CHECKED BEFORE ANYTHING IS EMITTED, so a refusal produces no output at all. Emitting first and
  # refusing after would hand the caller a half-written notes file alongside a non-zero status, and
  # a caller that tested `-s` before the status would publish the signature.
  #
  # FOUR ENVELOPES, not one. Git signs tags with GPG, with SSH keys (`gpg.format = ssh`) and with
  # X.509 via gpgsm, and the older RFC1991 path emits a PGP MESSAGE rather than a PGP SIGNATURE.
  # A detector that knew only the modern GPG envelope would let the other three straight into the
  # release notes while this file documented a refusal.
  tm_rc=0
  if LC_ALL=C grep -q -e '-----BEGIN PGP SIGNATURE-----' -e '-----BEGIN PGP MESSAGE-----' \
                     -e '-----BEGIN SSH SIGNATURE-----' -e '-----BEGIN SIGNED MESSAGE-----' "$tm_msg"; then
    tm_rc=12
  elif ! LC_ALL=C grep -q '[^[:space:]]' "$tm_msg"; then
    # Whitespace-only is empty for this purpose: it would publish a blank release body, which is
    # the outcome "the notes are the tag message" exists to prevent.
    tm_rc=13
  else
    cat "$tm_msg" || tm_rc=2
  fi
  rm -f "$tm_raw" "$tm_msg"
  return "$tm_rc"
}

# --- release-state -----------------------------------------------------------------------------
# "Does a Release already exist for this tag, and is it finished?" — the decision `publish` branches
# on, kept here rather than in the driver because it is the difference between converging on an
# existing release and creating a second one (#284).
#
# THE INPUT IS A FULL LISTING, NOT A `releases/tags/<tag>` LOOKUP, and that is a fail-closed choice
# rather than a stylistic one. `gh api repos/<slug>/releases/tags/<tag>` exits non-zero for "no such
# release" AND for an expired token, a network failure and a 5xx — so a caller that reads a non-zero
# status as "absent" creates a SECOND release every time GitHub hiccups. A listing either succeeds
# (and absence from it is a fact) or fails (and the driver dies). One read, two unambiguous answers.
#
# MORE THAN ONE MATCH IS ITS OWN VERDICT. GitHub permits only one release per tag, so two is not a
# state to pick a winner from — it is evidence the input is not what this predicate thinks it is.
cmd_release_state() {
  [ "$#" -eq 1 ] || die "release-state: needs exactly <tag>"
  tag="$1"
  command -v jq >/dev/null 2>&1 || die "release-state: jq not found"
  json="$(cat)"
  # `-s` because `gh api --paginate` emits one array per page; `.[][]` flattens them.
  sel="$(printf '%s' "$json" | jq -s -c --arg t "$tag" \
           '[.[][] | select(.tag_name == $t)]' 2>/dev/null)" \
    || die "release-state: unreadable releases JSON"
  [ -n "$sel" ] || die "release-state: unreadable releases JSON"
  n="$(printf '%s' "$sel" | jq 'length' 2>/dev/null)" || die "release-state: unreadable releases JSON"
  case "$n" in
    0) printf 'absent -\n'; return 0 ;;
    1) : ;;
    *) printf 'ambiguous %s\n' "$n"; return 14 ;;
  esac
  id="$(printf '%s' "$sel" | jq -r '.[0].id // empty')" || die "release-state: unreadable releases JSON"
  [ -n "$id" ] || die "release-state: the matching release carries no id"
  # `has("draft")`, NOT `.draft // "missing"`. jq's `//` yields its right side whenever the left is
  # `null` OR `false` — so a genuinely PUBLISHED release (`"draft": false`) took the "missing" arm
  # and this predicate refused every release it was written to recognise. Caught by smoke-testing
  # the four inputs; nothing about the code reads wrong.
  #
  # The distinction the `missing` arm is actually for stands: an input that does not say whether
  # the release is a draft is an input this predicate has no answer for, and guessing "published"
  # would publish over a draft.
  case "$(printf '%s' "$sel" | jq -r '.[0] | if has("draft") then (.draft | tostring) else "missing" end')" in
    true)  printf 'draft %s\n' "$id"; return 10 ;;
    false) printf 'published %s\n' "$id"; return 11 ;;
    *) die "release-state: the matching release does not declare draft true/false" ;;
  esac
}

# --- sha256 ------------------------------------------------------------------------------------
# The checksum published beside the release artifact (#284). It lives HERE, beside its only
# consumer, rather than becoming `adb_sha256_file` in `scripts/lib/common.sh`: that directory is
# symlinked wholesale into every install (common.sh's `adb_agent_manifest`), so a primitive with
# exactly one project-scoped caller would ship to every adopting repo to serve nobody. If a second
# consumer ever appears, promoting it then is the right move — inventing a shared home for one
# caller now is not.
#
# THREE IMPLEMENTATIONS, because there is no one tool. `sha256sum` is coreutils (Linux); macOS
# ships `shasum` (perl) and `openssl` but no `sha256sum` unless Homebrew put one there. The output
# is REPARSED rather than trusted: all three print `<hex> <something>`, and a 64-lowercase-hex
# assertion is what turns "the command exited 0" into "a digest was actually produced".
cmd_sha256() {
  [ "$#" -eq 1 ] || die "sha256: needs exactly <file>"
  f="$1"
  # A leading `-` would be read as an option by `openssl dgst`, which takes no `--` terminator.
  # Refusing is honest; silently hashing the wrong thing, or hashing nothing and parsing whatever
  # openssl printed, is not. Callers here always pass an absolute path.
  case "$f" in -*) die "sha256: refusing a path that begins with '-': $f" ;; esac
  [ -f "$f" ] || die "sha256: not a regular file: $f"
  out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum -- "$f")" || die "sha256: sha256sum failed on $f"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 -- "$f")" || die "sha256: shasum failed on $f"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 -r "$f")" || die "sha256: openssl failed on $f"
  else
    die "sha256: no sha256 tool found (tried sha256sum, shasum, openssl)"
  fi
  hex="${out%% *}"
  case "$hex" in
    ''|*[!0-9a-f]*) die "sha256: unparseable digest output for $f" ;;
  esac
  [ "${#hex}" -eq 64 ] || die "sha256: digest for $f is ${#hex} characters, not 64"
  printf '%s\n' "$hex"
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  sub="$1"; shift
  case "$sub" in
    version-ok)       cmd_version_ok "$@" ;;
    version-format)   cmd_version_format "$@" ;;
    changelog-verify) cmd_changelog_verify "$@" ;;
    unreleased-entries) cmd_unreleased_entries "$@" ;;
    checks-settled)   cmd_checks_settled "$@" ;;
    tag-message)      cmd_tag_message "$@" ;;
    release-state)    cmd_release_state "$@" ;;
    sha256)           cmd_sha256 "$@" ;;
    -h|--help)        usage ;;
    *) printf 'release-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
