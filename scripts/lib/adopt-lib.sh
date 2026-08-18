#!/usr/bin/env bash
# ai-dev-baseline — /adopt decision predicates (issue #20, consolidating #21 and #29).  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work / #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
#
# /adopt brings the baseline into an EXISTING project: it inventories what that project already
# has, classifies each artifact keep / remove / move / escalate, proposes an agents.toml, and
# emits an ordered migration plan. Like /cleanup and /roadmap, the workflow itself is prose an
# agent executes — so its load-bearing DECISIONS live here rather than as inline one-liners in
# the skill body, where they would be unexecutable and therefore untestable
# (scripts/check-adopt.sh). Same split, same reason, and the same DRY discipline from
# docs/design-principles.md: source the shared primitive, never copy it.
#
# WHAT THIS DOES NOT DO — and it is the boundary the whole file is built around. NOTHING here
# deletes, moves, or edits a file in the scanned project. Not one subcommand. `classify` prints
# the word `remove`; it removes nothing, and no subcommand that could is defined. The only writes
# /adopt performs at all are the two artifacts that DO NOT YET EXIST — `agents.toml` and the
# upstream pin — and even those are the workflow's, on explicit approval, from content `propose`
# and `pin-render` merely PRINT.
#
# That boundary is what makes the fail-closed convention below sufficient. A predicate whose
# wrong answer would delete a project's forked skill needs backup, rollback, and partial-failure
# semantics; a predicate whose wrong answer prints a wrong recommendation to an operator who is
# reading the plan needs to be right, and to say when it is not sure. This file is the second
# kind, deliberately (#20's v1 boundary; see the decision log).
#
# NETWORK PURITY. No subcommand here ever calls `gh`, and none calls `git` for anything but
# `check-ignore` (in `hygiene`, where asking git itself is the whole point — reimplementing
# .gitignore precedence is how you get a confidently wrong answer about negations). `scan` and
# `hygiene` read the filesystem: deterministic and offline, not pure. Everything else is a pure
# function of its arguments and stdin. The workflow owns every live read.
#
# EXIT STATUS IS FAIL-CLOSED, and the reason differs from /cleanup's. There the wrong answer
# destroys work; here it MISINFORMS — an operator acting on a plan that said `remove` about an
# artifact carrying behavior they still need. So:
#   0  — an answer this file stands behind
#   1  — a valid, trustworthy negative (a yes/no subcommand answering "no")
#   2  — ERROR: bad arguments, a missing dependency, or input this file cannot read.
# The caller MUST treat 2 as a hard stop. There is deliberately no status that means "probably".
# When a predicate cannot prove its answer it prints `escalate` (or `ambiguous`) and exits 0 —
# that IS the answer, and it routes to base/practices/handling-the-unknown.md's bucket 4.
#
# Usage:
#   adopt-lib.sh resolve     <start-dir>                     # repo shape (adb_repo_shape)
#   adopt-lib.sh shape-field <key>                           # one shape field; record on stdin
#   adopt-lib.sh baseline    [home]                          # the installed baseline's root
#   adopt-lib.sh shipped     <baseline-root> [agent]        # what the baseline installs
#                                                          #   <kind>TAB<name>TAB<agent>TAB<src>
#   adopt-lib.sh scan        <project-root> [--agents a,b]  # the project's adoption surface
#                                                          #   <kind>TAB<relpath>TAB<name>TAB<agent|->
#   adopt-lib.sh prescribed  <kind> <name>                  # is this a prescribed home?
#   adopt-lib.sh delta       <kind> <project-path> <baseline-path>   # same|differs|unknown
#   adopt-lib.sh classify    <kind> <collision yes|no> <delta same|differs|unknown> <prescribed yes|no>
#   adopt-lib.sh roles-infer <project-root>                 # propose [roles] from evidence
#   adopt-lib.sh propose                                    # roles-infer TSV on stdin -> agents.toml
#   adopt-lib.sh stack       <project-root>                 # the project's stack label
#   adopt-lib.sh hygiene     <project-root> [--agents a,b]  # the four #29 axes  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
#   adopt-lib.sh pin-render  <version> <commit> <adopted-date> <stack> [agents]
#   adopt-lib.sh pin-read    <pin-file> <key>
#   adopt-lib.sh pin-drift   <pin-file> <baseline-root>     # the drift command, printed
#   adopt-lib.sh plan                                       # classified TSV on stdin
#   adopt-lib.sh -h | --help
#
# Requires: awk, sed, git (hygiene's ignore axis only). jq is NOT required.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way every sibling module does
# (cleanup-lib.sh, roadmap-lib.sh, repo-settings.sh). adb_usage and adb_tsv_field_safe vanish
# without it, so a missing library FAILS LOUD rather than silently degrading a predicate whose
# output an operator is about to act on.
_adb_ad_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_ad_common" ]; then
  printf 'adopt-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_ad_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_ad_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() { adb_usage "$0"; }

# die <msg> — every hard error exits 2, the fail-closed "do not trust this answer" status. There
# is deliberately no status 1 here: a caller that read 1 as a benign negative would print a
# recommendation this file never made.
die() { printf 'adopt-lib: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"

# --- record safety ------------------------------------------------------------------------------
# Every subcommand that enumerates the filesystem serializes `<field>TAB<field>NL`, and the
# workflow reads it back with `IFS=<tab> read -r`. A field carrying a raw TAB or NEWLINE does not
# corrupt its record — it FORGES A NEW ONE, whose leading field is attacker-chosen text that walks
# past whatever `case` arm the consumer trusts. That is D41's finding for `state-scan` and D59's
# for `adb_repo_shape`, and it applies here for the same reason and with the same fix: test the
# field, and on failure emit a `warning` record instead of the fact.
#
# The test itself is `adb_tsv_field_safe` in common.sh — the ONE home since #278/D59. This file
# only decides what to do with a refusal, which is not the same question.
#
# THE REFUSAL IS PER FIELD, NOT PER SCAN. A project may legitimately track one oddly-named file
# while the other four hundred are ordinary; dropping the whole inventory over one of them would
# destroy real facts to protect against a forged one. Same call D59 made for `extra_doc`.
_ad_emit() {  # _ad_emit <kind> <field>… — print the record, or a warning naming what was refused
  local kind="$1" f
  shift
  for f in "$@"; do
    if ! adb_tsv_field_safe "$f"; then
      printf 'warning%sa %s field contains a tab or newline and cannot be represented: %s\n' \
        "$TAB" "$kind" "$(adb_tsv_field_display "$f")"
      return 0
    fi
  done
  printf '%s' "$kind"
  for f in "$@"; do printf '%s%s' "$TAB" "$f"; done
  printf '\n'
}

# --- object-name validation -----------------------------------------------------------------------
# The pin's `commit` is load-bearing — `pin-drift` feeds it to git — so it is validated both when
# WRITTEN and when READ, and the rule lives in ONE place. It was previously spelled out twice, which
# is the duplication this repo treats as a blocking review finding; it also made the two halves
# independently mutable, so a harness row that disabled one silently left the other catching the
# same inputs and the guard looked covered when it was not.
#
# FULL LENGTH, not merely "long enough": the pin's whole claim is that it recovers the inherited
# tree EXACTLY, and an abbreviation is resolvable only while it stays unambiguous in a growing
# repository — precisely the window the pin exists to outlive. 40 hex for SHA-1, 64 for SHA-256.
_ad_check_commit() {  # <commit> <who>
  local c="$1" who="$2"
  case "$c" in
    "") die "$who: <commit> must not be empty" ;;
    *[!0-9a-fA-F]*) die "$who: <commit> must be a hex object name: $(adb_tsv_field_display "$c")" ;;
  esac
  case "${#c}" in
    40|64) ;;
    *) die "$who: <commit> must be a FULL object name (40 or 64 hex), not abbreviated: $c" ;;
  esac
}

# --- the default agent set ------------------------------------------------------------------------
# THE DEFAULT IS DERIVED FROM THE INSTALLED BASELINE, never a literal. `shipped` already reads its
# agent set from `<baseline>/agents/*/` — the one home `docs/adding-an-agent.md` says you extend —
# while `scan`, `hygiene` and `pin-render` each carried their own `claude,codex,gemini`. A fourth
# agent added through the documented path would therefore have been scanned by none of them and
# silently absent from the inventory, which is the "second hardcoded list" failure this file
# already refuses for the shipped set. Review caught the asymmetry.
#
# It DEGRADES rather than failing: with no install reachable, the three shipped tokens are still a
# better answer than none, and the caller can always pass `--agents` explicitly. That is the
# graceful-degradation rule (design-principles §5) — an absent OPTIONAL input, not a broken install.
_ad_default_agents() {
  local root out=""
  if root="$(adb_install_source 2>/dev/null)" && [ -n "$root" ] && [ -d "$root/agents" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      [ -z "$out" ] || out="$out,"
      out="$out$a"
    done <<EOF
$(_ad_agents_from_baseline "$root")
EOF
  fi
  printf '%s\n' "${out:-claude,codex,gemini}"
}

# --- agent-token validation -----------------------------------------------------------------------
# `--agents` is interpolated straight into a path (`$root/.$a`), so an unvalidated token escapes
# the project directory. THE WITNESS IS `claude/../../sibling`, not `../..` — the code prepends a
# `.`, so `../..` builds `$root/...././..`, whose first component is a directory literally named
# `...` and which normalizes back to `$root` itself. It is the token that starts with a valid
# agent name and then climbs that actually leaves: `$root/.claude/../../sibling` resolves to a
# sibling of the project, and the scan reports whatever is there as the project's own inventory.
# (The first version of this comment named the wrong witness; review caught it, and a fix
# described by an example that does not reproduce is a fix nobody can re-verify.)
#
# Read-only, so nothing is destroyed — but an inventory that silently describes a DIFFERENT
# directory is the same class of wrong answer D59 refused for `adb_repo_shape`, and the operator
# acts on this one.
#
# `pin-render` already validated its agent tokens with exactly this rule; `scan` and `hygiene` did
# not, which is the asymmetry self-review caught. One helper now, so a third caller cannot
# reintroduce it.
#
# The grammar is the one `agents/<token>/` can actually hold and `docs/adding-an-agent.md`
# prescribes: lowercase alphanumerics and dashes. Rejecting is a hard error rather than a skip —
# a silently-dropped agent would report an EMPTY inventory for it, which reads exactly like a
# project that has no config for that agent.
_ad_check_agents() {  # <comma-list> <subcommand-name-for-the-message>
  local list="$1" who="$2" a seen=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    seen=1
    case "$a" in
      *[!a-z0-9-]*|-*) die "$who: invalid agent token: $(adb_tsv_field_display "$a") (expected lowercase letters, digits and dashes)" ;;
    esac
  done <<EOF
$(printf '%s\n' "$list" | tr ',' '\n')
EOF
  [ "$seen" -eq 1 ] || die "$who: --agents was given no usable token"
}

# --- the agent set -------------------------------------------------------------------------------
# Derived from `<baseline-root>/agents/*/`, never a second hardcoded list — the same rule
# bin/agent-init follows for the gitignore set (#250) and for exactly the same reason: a fourth
# agent must not silently fall out of a list nobody remembers to update.
_ad_agents_from_baseline() {
  local root="$1" d a
  for d in "$root"/agents/*/; do
    [ -d "$d" ] || continue
    a="${d%/}"; a="${a##*/}"
    printf '%s\n' "$a"
  done
}

# --- resolve / baseline ---------------------------------------------------------------------------
# Two thin pass-throughs to shared primitives, and they exist for AGENT-NEUTRALITY rather than for
# convenience.
#
# `base/workflows/adopt.md` renders to all three agents, so a fenced block in it may not name any
# one agent's installed paths. The first draft sourced `$HOME/.claude/scripts/lib/common.sh`
# literally to reach `adb_repo_shape` and `adb_install_source` — which works on Claude and makes
# the Codex and Gemini renders fail outright on a machine carrying only their own payload. Review
# caught it. The workflow reaches these through `{{ADOPT_LIB}}`, which every render already maps to
# its own agent's copy, so the hardcoded path disappears and no new placeholder is needed.
#
# They add no logic. `adb_repo_shape` and `adb_install_source` remain the one home for both
# questions; these subcommands only make them reachable from prose.
cmd_resolve() {
  [ "$#" -eq 1 ] || die "resolve: needs <start-dir>"
  adb_repo_shape "$1"
}

# `root` is the only shape field the workflow branches on, and it takes the shape on STDIN so a
# multi-line record never has to survive an argument list.
cmd_shape_field() {
  [ "$#" -eq 1 ] || die "shape-field: needs <key> (the shape record on stdin)"
  local shape
  shape="$(cat)"
  adb_shape_val "$shape" "$1"
}

cmd_baseline() {
  [ "$#" -le 1 ] || die "baseline: takes at most one [home]"
  adb_install_source "${1:-$HOME}" \
    || die "baseline: no installed baseline found — /adopt compares against what is INSTALLED, so there is nothing to compare with. Run install.sh first."
}

# --- shipped -------------------------------------------------------------------------------------
# Print the IDENTITY of every artifact the baseline installs, as `<kind>TAB<name>`. Kinds:
# `skill` (a skill directory name), `script` (a basename under the agent's scripts dir), `lib` (the
# shared scripts/lib dir), `rootdoc` (the agent's root doc basename).
#
# DERIVED FROM `adb_agent_manifest`, which is install.sh's own manifest — the ONE enumeration of
# what this framework ships. A hardcoded list here would be a second answer to "what does the
# baseline install", and the two would diverge the first time a skill was added; the classifier
# would then call a brand-new baseline skill "project-specific" and recommend keeping a fork of it.
#
# IDENTITY, NOT PATH, is what the classifier compares. The manifest's destination is a USER-level
# path (`$HOME/.claude/skills/cleanup`); the thing being classified is a PROJECT-level path
# (`<project>/.claude/skills/cleanup`). They collide by name, never by path, so the path is
# reduced to the identity here and the comparison downstream is name-to-name.
cmd_shipped() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "shipped: needs <baseline-root> [agent]"
  local root="$1" want="${2:-}" agent src dest kind name manifest
  [ -d "$root/agents" ] || die "shipped: not a baseline checkout (no agents/ under $root)"
  # PHASE 1 — PROVE EVERY selected agent's manifest is representable BEFORE emitting one record.
  #
  # `die` exits the process, so a refusal discovered mid-loop cannot un-print what earlier agents
  # already wrote. Without this pass the failure was a PARTIAL WRITE: an independent review dropped
  # a newline into a gemini skill name and measured `shipped` exiting 2 having already emitted 25
  # records for claude and codex. That is the same shape as the defect this whole change refuses —
  # and worse here, because the caller's own belt is a non-empty check, which a partial write passes.
  #
  # Two calls per agent rather than a buffer: the producer is pure string building over a glob, and
  # buffering the emitted records would mean holding and re-splitting the very format whose
  # splitting is the bug.
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    [ -z "$want" ] || [ "$agent" = "$want" ] || continue
    adb_agent_manifest "$agent" "$root" "/ADB_SHIPPED" >/dev/null \
      || die "shipped: cannot enumerate $agent's install manifest under $root (see above)"
  done <<EOF
$(_ad_agents_from_baseline "$root")
EOF
  # PHASE 2 — emit.
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    [ -z "$want" ] || [ "$agent" = "$want" ] || continue
    # A HOME that cannot appear in a real path, so a manifest line is unambiguously splittable
    # back into agent-relative form. `adb_agent_manifest` interpolates it literally.
    #
    # CAPTURED AND CHECKED (#324, D64). This consumer was missed by #324's own inventory, and it
    # had the same swallow as the installers: the producer ran inside the heredoc's `$(…)`, so a
    # refusal for an unrepresentable <baseline-root> became an EMPTY shipped set — and an empty
    # shipped set does not read as an error to `classify`, it reads as "the baseline ships nothing",
    # which makes every artifact in the project look project-specific and recommends keeping a fork
    # of each one. `die`, because that is how every other unanswerable question in this file ends.
    #
    # BOTH columns are read: the DESTINATION carries the identity the classifier matches on,
    # and the SOURCE is where `delta` reads the baseline's own copy from.
    manifest="$(adb_agent_manifest "$agent" "$root" "/ADB_SHIPPED")" \
      || die "shipped: cannot enumerate $agent's install manifest under $root (see above)"
    while IFS="$TAB" read -r src dest; do
      [ -n "$dest" ] || continue
      case "$dest" in
        */skills/*)  kind=skill;   name="${dest##*/}" ;;
        */scripts/lib) kind=lib;   name=lib ;;
        */scripts/*) kind=script;  name="${dest##*/}" ;;
        *)           kind=rootdoc; name="${dest##*/}" ;;
      esac
      # THE SOURCE PATH IS THE FOURTH FIELD, and it is why this subcommand is worth having rather
      # than a name list: `delta` below has to actually read the baseline's copy to compare, and
      # the manifest is the only place that knows where it lives.
      _ad_emit "$kind" "$name" "$agent" "$src"
    done <<EOF
$manifest
EOF
  done <<EOF
$(_ad_agents_from_baseline "$root")
EOF
}

# --- delta ---------------------------------------------------------------------------------------
# Is the project's copy the same as the baseline's? Print `same`, `differs`, or `unknown`; exit 0.
# This is the one input to `classify` that requires reading both sides, and it lives here rather
# than as a `cmp -s` in the workflow for two reasons that are not stylistic:
#
#   1. A SKILL IS A DIRECTORY. The manifest's source for a skill is `agents/claude/skills/cleanup`,
#      and `cmp` on a directory is an error, not a comparison — a workflow doing the obvious thing
#      would get a non-zero status and, reading it as "differs", would classify every project's
#      every skill as a fork.
#   2. `unknown` HAS TO BE REACHABLE. A missing or unreadable file is not "differs"; it is an
#      unanswered question, and `classify` routes it to `escalate`. Collapsing them is how an
#      unreadable install becomes a confident recommendation.
#
# THE SKILL COMPARISON IS THE WHOLE DIRECTORY, NOT `SKILL.md` ALONE — and this is the correction
# that matters most in this file. Comparing only `SKILL.md` while the header claimed the unit was
# the whole artifact meant a project skill with an IDENTICAL `SKILL.md` plus its own `helper.sh`,
# reference doc, or asset answered `same`, which `classify` turns into `remove`, which deletes the
# helper. Review reproduced exactly that. So the comparison is: the sorted RELATIVE FILE LISTS must
# match, and every corresponding pair must be byte-identical. An extra file on either side is
# `differs`, which routes to `move` and loses nothing.
#
# UNKNOWN IS THE DEFAULT, not the fallback. Every path that fails to ESTABLISH equality lands
# there, so a case nobody anticipated fails toward asking rather than toward acting.
_ad_cmp_files() {  # <a> <b> -> same | differs | unknown   (a single pair)
  local a="$1" b="$2" rc
  [ -f "$a" ] && [ -f "$b" ] && [ -r "$a" ] && [ -r "$b" ] || { printf 'unknown\n'; return 0; }
  cmp -s "$a" "$b"; rc=$?
  # `cmp` is THREE-VALUED: 0 identical, 1 different, >1 the comparison FAILED (an I/O error, a
  # file that vanished mid-read, a permission change). Reading >1 as "differs" turns a failure to
  # compare into a confident `move` — the same fail-open shape the ignore axis had.
  case "$rc" in
    0) printf 'same\n' ;;
    1) printf 'differs\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# The sorted relative manifest of <dir>: every regular file AND every symlink, each tagged with
# its type, and a symlink additionally carrying its TARGET.
#
# `-type f` ALONE WAS A DATA-LOSS BUG of exactly the shape that made this whole-directory
# comparison necessary in the first place. A project skill holding the baseline's regular files
# plus its own symlink produced an identical manifest, every compared pair matched, `delta` said
# `same`, and the plan recommended removing a skill that still carried extra behaviour. Review
# caught it — the second instance of the same class in this function.
#
# The TARGET is part of the identity, not decoration: two symlinks with the same name pointing at
# different things are not the same artifact, and comparing only names would call them equal.
_ad_dir_manifest() {  # print the sorted typed entry list of <dir>, or nothing on failure
  ( cd "$1" 2>/dev/null || exit 0
    find . \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r e; do
      if [ -L "$e" ]; then printf 'l %s -> %s\n' "$e" "$(readlink "$e")"
      else printf 'f %s\n' "$e"; fi
    done )
}

cmd_delta() {
  [ "$#" -eq 3 ] || die "delta: needs <kind> <project-path> <baseline-path>"
  local kind="$1" proj="$2" base="$3" pl bl rel verdict
  case "$kind" in
    skill)
      [ -d "$proj" ] && [ -d "$base" ] || { printf 'unknown\n'; return 0; }
      pl="$(_ad_dir_manifest "$proj")"; bl="$(_ad_dir_manifest "$base")"
      # An EMPTY listing means the traversal failed, not that the directory is empty of interest —
      # a skill directory always holds at least SKILL.md. Fail toward asking.
      [ -n "$pl" ] && [ -n "$bl" ] || { printf 'unknown\n'; return 0; }
      [ "$pl" = "$bl" ] || { printf 'differs\n'; return 0; }
      # Same file set: now every pair must match. `unknown` on any pair wins over `same`, because
      # a directory is only provably identical when EVERY member was provably identical.
      # The manifests already matched, so the entry lists (and every symlink TARGET in them) are
      # equal — only the regular files still need their contents compared. A symlink is fully
      # described by its target, which the manifest carried.
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
          'l '*) continue ;;
          'f '*) rel="${rel#f }" ;;
          *) printf 'unknown\n'; return 0 ;;
        esac
        verdict="$(_ad_cmp_files "$proj/$rel" "$base/$rel")"
        case "$verdict" in
          same) ;;
          *) printf '%s\n' "$verdict"; return 0 ;;
        esac
      done <<EOF
$pl
EOF
      printf 'same\n' ;;
    *)
      _ad_cmp_files "$proj" "$base" ;;
  esac
}

# --- prescribed ----------------------------------------------------------------------------------
# Is `<kind>/<name>` one of the PRESCRIBED HOMES base/practices/handling-the-unknown.md names for
# project-specific content? Exit 0 = yes, 1 = no, 2 = bad input.
#
# This is a TRANSCRIPTION of that practice's table, and the transcription is the point: the
# classifier must never recommend removing a file whose whole job is to carry the project's own
# delta. `.claude/scripts/precommit-gate.sh` is the sharpest case — it collides by name with a
# baseline-shipped script AND it is the practice's one legal home for custom gate policy, so a
# collision-only rule would tell every adopting project to delete its gate policy.
#
# WHY THE TABLE IS HERE AND NOT DERIVED: the practice is prose, and parsing a markdown table at
# runtime to recover a decision is a worse coupling than restating it in one testable place. The
# drift risk is real and is handled where this repo handles it — check-adopt.sh asserts every row
# here still appears in the practice, so deleting a home from the practice fails the build.
cmd_prescribed() {
  [ "$#" -eq 2 ] || die "prescribed: needs <kind> <name>"
  local kind="$1" name="$2"
  case "$kind" in
    skill|script|rootdoc|manifest|settings|override|decisions|pin|foreign-pin|lib|other) ;;
    *) die "prescribed: unknown kind: $kind" ;;
  esac
  case "$kind$TAB$name" in
    # Custom gate POLICY — the practice's one home. Collides with a shipped script by name.
    "script${TAB}precommit-gate.sh") return 0 ;;
    # Project rule / convention / stack boundary — the repo's own root doc.
    "rootdoc${TAB}CLAUDE.md"|"rootdoc${TAB}AGENTS.md"|"rootdoc${TAB}GEMINI.md") return 0 ;;
    # Role assignment + gate commands — agents.toml.
    "manifest${TAB}agents.toml") return 0 ;;
    # A workflow that genuinely diverges — a partial compose-override is the preferred form
    # (docs/per-project-overrides.md §2b), so an overrides.md is a home, not a duplicate.
    "override${TAB}overrides.md") return 0 ;;
    # The decision log itself.
    "decisions${TAB}decisions.md") return 0 ;;
    *) return 1 ;;
  esac
}

# --- classify ------------------------------------------------------------------------------------
# THE central decision. Print `<verdict>TAB<reason>`; exit 0 always (an unprovable case is
# `escalate`, which is an answer). Bad input exits 2.
#
# THE UNIT IS A WHOLE ARTIFACT — a skill directory, a script file, a root doc, the manifest. Never
# a line, a section, or a hook entry. A line-level classifier would have to decide whether two
# differently-worded paragraphs "mean the same thing", and there is no way to be right about that;
# gap-analysis called this out and it is the single most dangerous thing this file could try.
#
# "DUPLICATES THE BASELINE" HAS EXACTLY ONE PROOF: byte-identity with the baseline's own shipped
# artifact of the same identity. Not similarity, not a shared heading, not a version marker. That
# is a deliberately narrow test and it will call a lightly-edited fork `differs` — which is the
# safe direction, because `differs` routes to `move` (re-home the delta), and `move` loses nothing.
#
# THE FOUR VERDICTS:
#   keep      a prescribed home, or no baseline artifact of this identity exists. The project's
#             own content. Nothing to do.
#   remove    a byte-identical copy of something the baseline installs, in a path that is NOT a
#             prescribed home. The only case where deleting costs the project nothing — and even
#             here /adopt only ever PRINTS the word.
#   move      a colliding artifact that DIFFERS. The delta is real behavior; it has to be re-homed
#             (a forked skill -> overrides.md, a gate command -> [gates]) before the fork can go.
#             Never `remove`: that is what "parity caveat" means in the issue text.
#   escalate  the delta could not be established, or the kind is not modelled. Bucket 4 of
#             handling-the-unknown.md: stop and ask, never improvise.
#
# NOTE THE ORDER OF THE ARMS. `prescribed` is tested BEFORE collision, because a prescribed home
# that collides is still a home. Reversing them recommends deleting every adopting project's
# precommit-gate.sh, which is the concrete regression check-adopt.sh pins.
cmd_classify() {
  [ "$#" -eq 4 ] || die "classify: needs <kind> <collision yes|no> <delta same|differs|unknown> <prescribed yes|no>"
  local kind="$1" collision="$2" delta="$3" prescribed="$4"
  case "$collision"  in yes|no) ;;              *) die "classify: <collision> must be yes|no: $collision" ;; esac
  case "$delta"      in same|differs|unknown) ;; *) die "classify: <delta> must be same|differs|unknown: $delta" ;; esac
  case "$prescribed" in yes|no) ;;              *) die "classify: <prescribed> must be yes|no: $prescribed" ;; esac
  case "$kind" in
    skill|script|rootdoc|manifest|settings|override|decisions|pin|foreign-pin|lib|other) ;;
    *) printf 'escalate%sunmodelled artifact kind "%s" — classify it by hand (handling-the-unknown.md bucket 4)\n' "$TAB" "$kind"; return 0 ;;
  esac

  # A FOREIGN FRAMEWORK'S PIN IS `move`, AND IT IS TESTED BEFORE EVERYTHING ELSE. It has no
  # baseline counterpart, so the no-collision arm below classified it `keep` — while the workflow's
  # own step 7 told the operator to RETIRE it. The plan therefore preserved the one artifact the
  # prose said must go, and the two halves of this feature contradicted each other in writing.
  # Review caught it. `move` is the right verdict on the merits too: the old pin's *content* (which
  # baseline generation this project came from) has to be reconciled into `upstream.toml` before it
  # can be dropped, which is exactly what `move` means everywhere else in this table.
  # `other` IS AN UNMODELLED KIND BY DEFINITION, so it escalates whatever its collision state —
  # and it is tested here, before the collision arm, because that ordering is the entire point.
  # An `other` artifact never collides (the baseline ships nothing of that identity), so it fell
  # into the no-collision `keep` arm and every unmodelled file was reported as "project-specific,
  # adoption does not touch it". That is the silent-omission defect the `other` kind was ADDED to
  # fix, wearing a verdict instead of a silence — strictly worse, because the inventory now
  # asserted a decision about a file nobody had classified.
  #
  # Caught by re-running the live acceptance scan after the classifier changed; the unit test that
  # was supposed to cover it asserted `collision=yes`, an input this kind cannot have.
  if [ "$kind" = other ]; then
    printf 'escalate%sthe baseline does not model this artifact — classify it per handling-the-unknown.md (general / project-delta / deviation), place it in that bucket'"'"'s prescribed home, and record the decision; do not improvise\n' "$TAB"
    return 0
  fi
  if [ "$kind" = foreign-pin ]; then
    printf 'move%sthis is a PRIOR framework'"'"'s adoption artifact, not project content — reconcile what it records into .ai-dev-baseline/upstream.toml and retire it, so the project ends with ONE upstream rather than two stacked frameworks\n' "$TAB"
    return 0
  fi
  if [ "$prescribed" = yes ]; then
    printf 'keep%sa prescribed home for project-specific content (handling-the-unknown.md) — it exists to carry a delta, so a name collision with a baseline artifact is expected here, not a duplicate\n' "$TAB"
    return 0
  fi
  if [ "$collision" = no ]; then
    printf 'keep%sthe baseline ships nothing of this identity — project-specific, adoption does not touch it\n' "$TAB"
    return 0
  fi
  case "$delta" in
    same)
      printf 'remove%sbyte-identical to the baseline artifact it shadows — the global install already provides it, so removing costs nothing\n' "$TAB" ;;
    differs)
      # THE DESTINATION DEPENDS ON THE KIND, and a generic sentence here is a real cost rather
      # than a wording nit. The first live run against a real adopted project returned `move` for
      # a 294-line forked Stop hook and advised re-homing it "to overrides.md" — a mechanism that
      # exists for skills and does not exist for hook scripts. An operator following that finds no
      # such path and is left to improvise, which is the drift handling-the-unknown.md exists to
      # stop. Each kind gets the destination it actually has.
      case "$kind" in
        skill)
          printf 'move%scollides with a baseline skill BUT differs — carry ONLY the delta in .<agent>/skills/<name>/overrides.md and recompose (baseline skill-compose), then the fork can go; deleting it as-is loses whatever it changed\n' "$TAB" ;;
        script)
          # No compose mechanism exists for a hook script, so the honest instruction is to diff
          # and confirm — not to name a home that does not exist.
          printf 'move%scollides with a baseline script BUT differs, and there is NO compose-override mechanism for scripts — diff it against the baseline copy, move anything project-specific into agents.toml [gates]/[gates.scope] or the repo'"'"'s own precommit-gate.sh, and only then delete it\n' "$TAB" ;;
        rootdoc)
          printf 'move%sduplicates baseline practice text — trim only the lines the baseline already states; a root doc should restate a baseline rule ONLY where it CHANGES it (docs/per-project-overrides.md)\n' "$TAB" ;;
        *)
          printf 'move%scollides with a baseline artifact BUT differs — re-home the delta before the fork goes; deleting it as-is would lose behavior. This kind has no prescribed destination: classify it per handling-the-unknown.md rather than improvising one\n' "$TAB" ;;
      esac ;;
    unknown)
      printf 'escalate%scollides with a baseline artifact and the difference could not be established — do not guess (handling-the-unknown.md bucket 4)\n' "$TAB" ;;
  esac
}

# --- scan ----------------------------------------------------------------------------------------
# Enumerate the project's adoption surface as `<kind>TAB<relpath>TAB<name>` records.
#
# THE SCAN IS BOUNDED TO CONFIG, NOT CODE. It descends only into each agent's own directory, the
# root docs, agents.toml, .ai-dev-baseline/, and the two prior-framework artifacts. It never walks
# `src/`, and #29's first axis is why: support-workstation's `src/lib/cli/` IS product code that  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# orchestrates agent CLIs, and a scan that classified it would be recommending changes to the
# product. `hygiene` reports on that boundary; `scan` simply does not cross it.
cmd_scan() {
  local root="" agents="" a f d n rel
  local -a _ad_others=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # `-n "$2"` as well as the arity check: `--agents ""` passes `[ "$#" -ge 2 ]`, then falls
      # through to the default below and silently scans EVERY agent. An explicit empty value reads
      # as "none" to whoever typed it; giving it the widest possible meaning is the worst reading.
      --agents) [ "$#" -ge 2 ] && [ -n "$2" ] || die "scan: --agents needs a non-empty value"; agents="$2"; shift 2 ;;
      -*) die "scan: unknown option: $1" ;;
      *) [ -z "$root" ] || die "scan: takes exactly one <project-root>"; root="$1"; shift ;;
    esac
  done
  [ -n "$root" ] || die "scan: needs <project-root>"
  [ -d "$root" ] || die "scan: not a directory: $root"
  [ -n "$agents" ] || agents="$(_ad_default_agents)"
  _ad_check_agents "$agents" scan

  # THE AGENT IS THE FOURTH FIELD on every record, and `-` where the artifact is agent-neutral.
  # Without it the collision lookup could only match on <kind, name> and took the FIRST match,
  # which is Claude's — so a byte-identical Codex skill was compared against Claude's copy and came
  # back `differs`. `shipped` already carried the agent; the scan discarding it is what broke the
  # join. Review reproduced it.
  #
  # Root docs + the manifest + the decision log.
  for f in CLAUDE.md AGENTS.md GEMINI.md; do
    [ -f "$root/$f" ] && _ad_emit rootdoc "$f" "$f" -
  done
  [ -f "$root/agents.toml" ] && _ad_emit manifest agents.toml agents.toml -
  [ -f "$root/.ai-dev-baseline/decisions.md" ] && _ad_emit decisions .ai-dev-baseline/decisions.md decisions.md -
  [ -f "$root/.ai-dev-baseline/upstream.toml" ] && _ad_emit pin .ai-dev-baseline/upstream.toml upstream.toml -

  # Prior-framework artifacts (ai-dev-workflow). Reported as their own kind so the plan can carry
  # a reconcile step rather than classifying them as ordinary project content — bama-politics
  # carries both and has diverged far beyond the template they came from.
  [ -f "$root/.claude/UPSTREAM_VERSION" ] && _ad_emit foreign-pin .claude/UPSTREAM_VERSION UPSTREAM_VERSION -
  [ -f "$root/CLAUDE.md.upstream" ]       && _ad_emit foreign-pin CLAUDE.md.upstream CLAUDE.md.upstream -

  # Per-agent config trees.
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ -d "$root/.$a" ] || continue
    [ -f "$root/.$a/settings.json" ] && _ad_emit settings ".$a/settings.json" settings.json "$a"
    for d in "$root/.$a"/skills/*/; do
      [ -d "$d" ] || continue
      n="${d%/}"; n="${n##*/}"
      [ -f "$d/overrides.md" ] && _ad_emit override ".$a/skills/$n/overrides.md" overrides.md "$a"
      [ -f "$d/SKILL.md" ]     && _ad_emit skill    ".$a/skills/$n" "$n" "$a"
    done
    # THE VENDORED SHARED LIBRARY IS ONE ARTIFACT, emitted before the flat file loop. `shipped`
    # reports `lib` as a single identity (install.sh links the whole `scripts/lib` DIRECTORY), so a
    # project that vendored a copy had no `scan` record that could ever join against it: the flat
    # loop skips directories, and the catch-all below then emitted its ~14 members individually as
    # `other`. A byte-identical vendored baseline library — the clearest possible `remove` — came
    # out as fourteen escalations. Review caught it.
    #
    # `-d` and not `-e`: a SYMLINKED `scripts/lib` is the normal shape for a project that ran
    # install.sh, and `-d` follows the link, so that case is reported as the `lib` artifact it is
    # rather than falling through to the catch-all and vanishing.
    [ -d "$root/.$a/scripts/lib" ] && _ad_emit lib ".$a/scripts/lib" lib "$a"
    for f in "$root/.$a"/scripts/*; do
      [ -f "$f" ] || continue
      n="${f##*/}"
      _ad_emit script ".$a/scripts/$n" "$n" "$a"
    done

    # EVERYTHING ELSE UNDER THE AGENT DIR IS EMITTED AS `other`, and this closes a hole that
    # defeated the whole escalate path. Anything the arms above do not recognise —
    # `settings.local.json`, a `rules.md`, a nested `scripts/fixtures/` tree, a file format that
    # does not exist yet — used to be SILENTLY OMITTED. An omitted artifact never reaches
    # `classify`, so it never becomes `escalate`, so handling-the-unknown.md's protocol never runs
    # on the one category it exists for: the thing the baseline does not model. Silence was the
    # worst possible answer here, and it looked exactly like a project that had nothing unusual.
    #
    # `other` classifies to `escalate` for an unmodelled kind, so these surface as questions.
    # THE RUN-STATE DIR IS EXCLUDED: it is regenerated scratch, gitignored, and is the one thing
    # under the agent dir that genuinely carries no adoption decision.
    # NUL-DELIMITED, so a filename carrying a NEWLINE reaches `_ad_emit` whole. Split on newlines,
    # such a name became two or more INVENTED `rel` values — each a path that does not exist — and
    # the scan emitted them as confident `other` records instead of the single `warning` the record
    # format promises. `_ad_emit`'s safety check never saw the real name, so the guard that exists
    # for exactly this input could not fire. Review caught it.
    #
    # `mapfile -d ''` rather than a pipeline, for the reason the credential axis learned: `-print0`
    # output cannot survive a command substitution, because bash strips NUL bytes.
    _ad_others=()
    mapfile -d '' -t _ad_others < <(cd "$root" 2>/dev/null && find ".$a" -type f -print0 2>/dev/null | LC_ALL=C sort -z)
    for rel in "${_ad_others[@]}"; do
      [ -n "$rel" ] || continue
      case "$rel" in
        ".$a/scripts/lib/"*) continue ;;   # covered by the single `lib` artifact above
        ".$a/state/"*|".$a/settings.json") continue ;;
        ".$a/skills/"*/SKILL.md|".$a/skills/"*/overrides.md) continue ;;
        ".$a/scripts/"*) [ "${rel#".$a/scripts/"}" = "${rel##*/}" ] && continue ;;
        # OS FILE-MANAGER ARTIFACTS, and ONLY those. `.DS_Store` and `Thumbs.db` are written by
        # Finder and Explorer and are definitionally not adoption config, so escalating them asks
        # the operator a question with no answer. The exclusion is deliberately this narrow:
        # everything else stays, including lock files and a project's own hook fixtures, because
        # "it looked like noise to me" is how the silent omission this whole arm exists to fix
        # comes back. Observed on a real scan, which reported `.DS_Store` as an artifact to keep.
        */.DS_Store|*/Thumbs.db) continue ;;
      esac
      # A skill directory's OTHER members are already covered by the whole-directory `delta`
      # comparison of the skill itself, so re-emitting each of them would double-report.
      case "$rel" in ".$a/skills/"*) continue ;; esac
      _ad_emit other "$rel" "${rel##*/}" "$a"
    done
  done <<EOF
$(printf '%s\n' "$agents" | tr ',' '\n')
EOF
  return 0
}

# --- roles-infer ---------------------------------------------------------------------------------
# Propose `[roles]` values from evidence already in the project, as
# `<role>TAB<token|ambiguous|none>TAB<evidence>`.
#
# THE SIGNAL TABLE IS CLOSED, and "cannot infer" is a first-class result. Gap-analysis is right
# that `codex exec` on its own is ambiguous — it can mean gap analysis, review, or debugging — so
# the rule is not "codex appears" but "codex appears in a sentence that also names the role". A
# signal that fires for two different tokens yields `ambiguous` and NO proposal, naming both.
#
# IT NEVER BORROWS `role-dispatch.sh resolve`'s ANSWER. That command resolves a CONFIGURED role,
# falling back to built-in defaults; treating those defaults as inferred project intent would
# manufacture evidence — /adopt would report "your project wants codex for gap-analysis" about a
# project that says nothing at all. No signal means `none`, and `none` is printed.
_ad_role_hits() {  # <root> <role-regex> <agent> — files whose lines name BOTH the role and the agent
  local root="$1" rx="$2" agent="$3"
  # THE AGENT TOKEN IS MATCHED ON WORD BOUNDARIES, not as a substring. A bare `grep -qE codex`
  # matches `codexpert`, `codex-like`, and the word inside any longer identifier — so
  # `gap analysis uses codexpert tooling` inferred `gap_analysis = codex`, which directly
  # contradicts this subcommand's whole claim to refuse to guess. Review reproduced it.
  #
  # `\b` is a GNU extension that BSD grep on macOS does not honour, and this file runs on both, so
  # the boundary is spelled out as an explicit character class: the token must be preceded and
  # followed by something that is not a word character or a dash. A dash counts as part of the
  # word here on purpose — `codex-exec` is the tool, `codex-adjacent` is prose about it, and
  # neither should match a bare token search that is trying to identify WHICH AGENT is named.
  local bounded="(^|[^A-Za-z0-9_-])${agent}([^A-Za-z0-9_-]|\$)"
  # Config surfaces only, never src/ (#29 axis 1). A miss prints nothing and is not an error.  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
  grep -rIl --exclude-dir=state -E "$rx" \
    "$root"/.claude "$root"/.codex "$root"/.gemini "$root"/CLAUDE.md "$root"/AGENTS.md "$root"/GEMINI.md \
    2>/dev/null \
    | while IFS= read -r f; do
        grep -IE "$rx" "$f" 2>/dev/null | grep -qE "$bounded" && printf '%s\n' "${f#"$root"/}"
      done
}

cmd_roles_infer() {
  [ "$#" -eq 1 ] || die "roles-infer: needs <project-root>"
  local root="$1" role rx tok hits found first
  [ -d "$root" ] || die "roles-infer: not a directory: $root"
  while IFS='|' read -r role rx; do
    [ -n "$role" ] || continue
    found=""; first=""
    for tok in claude codex gemini; do
      hits="$(_ad_role_hits "$root" "$rx" "$tok" | head -n 1)"
      [ -n "$hits" ] || continue
      if [ -z "$found" ]; then found="$tok"; first="$hits"
      else found="ambiguous"; first="$first, $hits"; fi
    done
    if [ -z "$found" ]; then
      _ad_emit "$role" none "no signal in this project's config — leave unset and let the baseline default apply"
    elif [ "$found" = ambiguous ]; then
      _ad_emit "$role" ambiguous "more than one agent is named for this role ($first) — ask the owner rather than guessing"
    else
      _ad_emit "$role" "$found" "$first"
    fi
  done <<EOF
gap_analysis|gap[- ]analysis|gap analysis|pre-implementation adversarial
review|code[- ]review|reviewer|review pass
debug|root[- ]cause|debugging|incident
EOF
  return 0
}

# --- propose -------------------------------------------------------------------------------------
# Render the PROPOSED agents.toml from `roles-infer` records on stdin. Prints; writes nothing.
#
# EVERY LINE IS EVIDENCE-BEARING, and the ones with no evidence are COMMENTED OUT. That asymmetry
# is the whole design. A proposal that silently wrote `review = ["codex"]` because the baseline
# default happens to say so would be putting words in the project's mouth — the operator reads
# `agents.toml` later as a record of what THEY decided, and a guessed line is indistinguishable
# from a chosen one. So an inferred role is emitted live with its evidence in a trailing comment;
# an `ambiguous` or `none` role is emitted COMMENTED, saying why, for the operator to uncomment.
#
# The result is a file that is correct to write as-is: it asserts only what the project's own
# config already demonstrated.
cmd_propose() {
  [ "$#" -eq 0 ] || die "propose: takes no arguments (roles-infer TSV on stdin)"
  local role tok ev
  local -a recs=()
  mapfile -t recs || die "propose: could not read the roles-infer records on stdin"
  cat <<'HDR'
# ai-dev-baseline — agent role manifest, PROPOSED by /adopt from this project's own config.
#
# Every uncommented line below was inferred from evidence found in this repo; the evidence is
# named in the trailing comment. Every COMMENTED line is a role /adopt could not infer — it is
# left for you to decide rather than guessed, because a guessed role reads later exactly like a
# chosen one. Uncomment and fill in what you want; delete what you do not.
#
# Agent tokens: claude | codex | gemini      Full model: docs/roles-and-agents.md

[roles]
HDR
  # `primary` is never inferred. Nothing in a project's config says which agent DRIVES it — that
  # is a fact about the operator, not about the repo — so proposing one from a stray `codex exec`
  # would be the exact overreach the header above forbids.
  printf '# primary    = "claude"    # WHO DRIVES: not inferable from repo config — set this yourself.\n'
  local rec
  for rec in "${recs[@]}"; do
    IFS="$TAB" read -r role tok ev <<< "$rec"
    [ -n "$role" ] || continue
    # ONLY A KNOWN ROLE KEY MAY BECOME A LINE. `roles-infer` shares `_ad_emit`, which on an
    # unrepresentable field emits a `warning` record instead of the fact — and that record's first
    # field is `warning`, which this loop happily rendered as `warning = "a gap_analysis field…"`
    # while dropping the role it replaced. A malformed TOML key, and the real role silently gone.
    # Review reproduced it. Anything that is not a role key is surfaced as a comment instead.
    case "$role" in
      gap_analysis|review|debug|primary|release|issue_author) ;;
      *) printf '# NOTE: /adopt could not produce a proposal for one role — %s\n' \
                "$(adb_display_value "$rec")"; continue ;;
    esac
    case "$tok" in
      none|ambiguous)
        printf '# %-11s = ""          # NOT INFERRED: %s\n' "$role" "$ev" ;;
      *)
        # `review` is a LIST in the schema; the scalar roles are not. Emitting the wrong shape
        # would produce a manifest `role-dispatch.sh resolve` rejects, so the shape is chosen by
        # the key rather than by the value.
        if [ "$role" = review ]; then
          printf '%-13s = ["%s"]     # inferred from %s\n' "$role" "$tok" "$ev"
        else
          printf '%-13s = "%s"       # inferred from %s\n' "$role" "$tok" "$ev"
        fi ;;
    esac
  done
  return 0
}

# --- stack ---------------------------------------------------------------------------------------
# Print the project's stack label, one word, exit 0. Never empty: an unrecognised project is
# `unknown`, which is a fact and is recorded as one.
#
# WHY A NEW DETECTOR RATHER THAN project-gates.sh: they answer different questions. That module
# detects GATE COMMANDS ("what runs the tests here"); this names the ECOSYSTEM, and a project can
# have a recognisable stack with no runnable gate and vice versa. Deriving one from the other
# would make the pin's stack field a function of which tools happen to be installed.
#
# AND WHAT THE FIELD MEANS, stated exactly, because #21's wording invites an overclaim: it records  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# the STACK OF THE ADOPTED PROJECT. The baseline ships exactly ONE flavor today — there is no
# php-wordpress variant to have applied — so this is the field that lets a future variant be
# recorded and matched, not evidence that variants exist. #285 is where a variant would be consumed.
cmd_stack() {
  [ "$#" -eq 1 ] || die "stack: needs <project-root>"
  local r="$1"
  [ -d "$r" ] || die "stack: not a directory: $r"
  # THE MOST SPECIFIC EVIDENCE WINS, so WordPress is tested BEFORE node. A WordPress plugin or
  # theme routinely carries a `package.json` for its asset build alongside `composer.json` and PHP
  # that calls `add_action`, and a node-first order recorded every one of them as `node` — the
  # ecosystem the pin would then claim the project belongs to. Review caught it. The WordPress test
  # is the narrow one (it requires actual WP API calls in PHP), so putting it first cannot
  # misclassify a genuine node project that merely happens to contain a .php file.
  if grep -rqIl --include='*.php' -e 'add_action' -e 'wp_enqueue' "$r" 2>/dev/null; then
    printf 'php-wordpress\n'; return 0
  fi
  if [ -f "$r/package.json" ]; then
    if [ -f "$r/pnpm-workspace.yaml" ] || [ -f "$r/turbo.json" ] || [ -f "$r/lerna.json" ]; then
      printf 'node-monorepo\n'; return 0
    fi
    printf 'node\n'; return 0
  fi
  [ -f "$r/Cargo.toml" ]  && { printf 'rust\n'; return 0; }
  [ -f "$r/go.mod" ]      && { printf 'go\n'; return 0; }
  if [ -f "$r/composer.json" ] || [ -f "$r/style.css" ] || [ -d "$r/wp-content" ]; then
    printf 'php\n'; return 0
  fi
  for f in pyproject.toml setup.py setup.cfg requirements.txt; do
    [ -f "$r/$f" ] && { printf 'python\n'; return 0; }
  done
  # A repo of shell scripts with no package manifest at all — this framework's own shape, and
  # common enough among the surveyed projects to be worth naming rather than calling unknown.
  # `find`, not a glob: a glob that matches nothing expands to the literal pattern.
  [ -n "$(find "$r" -maxdepth 2 -name '*.sh' -type f -print -quit 2>/dev/null)" ] \
    && { printf 'shell\n'; return 0; }
  printf 'unknown\n'
}
# --- AXIS 4, as its own function -----------------------------------------------------------------
# Extracted so it can run BEFORE the directory-existence check in `cmd_hygiene`. Its probes use
# `--no-index` precisely so they answer for a path that does not exist yet, and gating it on
# `.<agent>/` already existing meant the run that most needs the warning — adopting an agent
# whose dot-directory has not been created — was the one run that never got it.
_ad_ignore_axis() {  # <project-root> <agent>
  local root="$1" a="$2" igrc igraw where
  # AXIS 4 — a BROAD IGNORE that would swallow the runtime state dir. ASK GIT, never a
  # hand-rolled matcher: precedence, negations and directory rules are git's semantics, and a
  # reimplementation that got `!` wrong would report the opposite of the truth.
  # `--no-index` so the probe answers for a path that does not exist yet.
  if [ -d "$root/.git" ] || git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    # THE STATUS IS THREE-VALUED, and collapsing it is a fail-OPEN. `check-ignore` exits 0 for
    # "ignored", 1 for "not ignored", and 128 for an ERROR — a bare repo, a broken index,
    # permissions. Treating everything non-zero as "not ignored" turns a tooling failure into a
    # confident claim about the project ("your state dir is exposed"), which is the stale/unproven
    # assertion base/practices/verify-before-asserting.md forbids and the fail-closed direction
    # this whole file claims to take. Caught by self-review, on a bare-repo fixture.
    #
    # THE DECISION IS MADE BY TWO PROBES, AND NO PATTERN TEXT IS EVER PARSED. That is the third
    # and final shape of this check, and the previous two are worth recording because each was a
    # different way of getting the same idea wrong:
    #
    #   1. Matching the whole `-v` line. The `<pathname>` column is the path just asked about, so
    #      it ALWAYS contains `.<agent>/state` — every input looked like an explicit rule and the
    #      axis was a permanent no-op.
    #   2. Slicing the pattern out of `<source>:<line>:<pattern>` by stripping two colons. That
    #      assumes `<source>` has none, and it is `core.excludesFile` — an arbitrary user path.
    #      Review reproduced a colon-bearing excludes path that suppressed a real `*.json` finding.
    #   (`-z` would separate the fields structurally, but its output cannot survive a command
    #   substitution — bash strips NUL bytes — and `-z` additionally requires `--stdin`.)
    #
    # So stop parsing. THE QUESTION IS NOT "what does the rule look like" BUT "does the ignore
    # cover the DIRECTORY, or only today's filenames" — and git answers that directly if you ask
    # about two paths instead of one:
    #
    #   probe A: the real state file, `…/state/implement-issue-active.json`
    #   probe B: a differently-shaped name in the same directory, matching no common
    #            extension-based pattern
    #
    # A ignored AND B ignored  → the rule reaches the directory itself. Deliberate. Silent.
    # A ignored AND B NOT      → the rule is extension-shaped and covers the state dir only by
    #                            coincidence. That IS #29's finding: `*.json` hides today's state  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
    #                            files and would not hide tomorrow's.
    # A NOT ignored            → not ignored at all.
    #
    # No parsing, no delimiter, no assumption about any path's contents — and it tests the
    # property the axis actually cares about rather than a proxy for it.
    git -C "$root" check-ignore -q --no-index ".$a/state/implement-issue-active.json" 2>/dev/null
    igrc=$?
    if [ "$igrc" -eq 0 ]; then
      git -C "$root" check-ignore -q --no-index ".$a/state/adb-adopt-probe" 2>/dev/null
      igraw=$?
      # The citation is display-only and never a decision input, so a mis-sliced `-v` line here
      # can mislead nobody — it is printed verbatim for the operator to go and read.
      where="$(git -C "$root" check-ignore -v --no-index ".$a/state/implement-issue-active.json" 2>/dev/null \
                 | sed -n '1s/'"$TAB"'.*$//p')"
      if [ "$igraw" -eq 0 ]; then
        : # both probes ignored — the rule covers the directory. Correct, deliberate state.
      elif [ "$igraw" -eq 1 ]; then
        _ad_emit ignore-risk warn ".$a/state/" "reached only by a rule that does NOT cover the directory (see ${where:-your ignore files}) — it hides today's state filenames and would not hide a future one; run bin/agent-init so the rule names the directory"
      else
        _ad_emit ignore-risk warn ".$a/state/" "PARTIALLY DETERMINED — the state file is ignored, but the second probe failed (rc $igraw), so whether the rule covers the whole directory is unverified"
      fi
    elif [ "$igrc" -eq 1 ]; then
      _ad_emit ignore-risk warn ".$a/state/" "is NOT gitignored — /implement-issue writes the untrusted issue body here; run bin/agent-init before adopting"
    else
      # Say what could not be established, not what is true. An operator who reads "could not be
      # determined" goes and looks; one who reads "is NOT gitignored" about a repo that ignores
      # it perfectly well learns to discount the axis.
      _ad_emit ignore-risk warn ".$a/state/" "COULD NOT BE DETERMINED — git check-ignore failed (rc $igrc) rather than answering; check this by hand before trusting the rest of this axis"
    fi
  fi
}


# --- hygiene -------------------------------------------------------------------------------------
# The four adoption-hygiene axes #29 contributed, as `<axis>TAB<severity>TAB<path>TAB<detail>`.  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# Severity is `warn` or `note`; neither is a failure, and this subcommand exits 0 unless its
# arguments are bad. These are things a human must look at, not verdicts.
#
# WHAT THIS IS NOT: a secret scanner. The credential axis matches a short, closed list of
# high-confidence prefixes and refuses to guess beyond it, and it REDACTS what it matched rather
# than echoing it (base/practices/logging-and-secrets.md applies to a diagnostic exactly as it
# applies to a log). A novel credential format will not be caught. Saying so is better than
# implying a coverage this cannot have.
cmd_hygiene() {
  local root="" agents="" a f rel line
  local -a _ad_tracked=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agents) [ "$#" -ge 2 ] && [ -n "$2" ] || die "hygiene: --agents needs a non-empty value"; agents="$2"; shift 2 ;;
      -*) die "hygiene: unknown option: $1" ;;
      *) [ -z "$root" ] || die "hygiene: takes exactly one <project-root>"; root="$1"; shift ;;
    esac
  done
  [ -n "$root" ] || die "hygiene: needs <project-root>"
  [ -d "$root" ] || die "hygiene: not a directory: $root"
  [ -n "$agents" ] || agents="$(_ad_default_agents)"
  _ad_check_agents "$agents" hygiene

  # AXIS 1 — harness config vs PRODUCT CODE. Reported so the operator knows the scan stopped at
  # the boundary; `scan` never descended here in the first place. support-workstation's
  # src/lib/cli/ references agent CLIs and is the product, not config.
  #
  # OUTSIDE the per-agent loop, deliberately: `src/` is one tree and the finding is one fact about
  # it. Inside, a three-agent project would be told three times that its product code is product
  # code — noise that trains an operator to skim the axis that most needs reading.
  if [ -d "$root/src" ] && grep -rqIl -e 'codex exec' -e 'claude -p' -e 'agy -p' "$root/src" 2>/dev/null; then
    _ad_emit product-code note src/ "references an agent CLI but is PRODUCT CODE — outside the adoption boundary; /adopt neither classifies nor changes it"
  fi

  while IFS= read -r a; do
    [ -n "$a" ] || continue

    # AXIS 4 RUNS FIRST, and OUTSIDE the directory-existence check below. Its `--no-index` probes
    # are built for a path that does not exist yet, so gating it on `.<agent>/` already existing
    # was backwards: adopting an agent whose dot-directory has not been created is exactly the run
    # that most needs to be told the state dir is unignored, and it reported nothing. The run would
    # then create `.<agent>/state` and write untrusted issue bodies into an untracked-but-visible
    # directory. Review caught it.
    _ad_ignore_axis "$root" "$a"

    # The axes below genuinely need the directory to exist — they read files inside it.
    [ -d "$root/.$a" ] || continue

    # AXIS 2 — config that may SHIP TO END USERS. A clone-and-run app's .claude/ travels with the
    # product, so a machine-local absolute path breaks on every other machine and a credential is
    # published. Tracked files only: an untracked local file ships nowhere.
    [ -d "$root/.$a" ] || continue
    # `-z`, AND A NUL-DELIMITED READ. `git ls-files` applies `core.quotePath` by default, so a
    # tracked file whose name carries any non-ASCII byte comes back as a C-quoted, escaped string
    # — `".claude/caf\303\251.md"`. The unquoted form does not exist on disk, `[ -f ]` fails, and
    # the file is SILENTLY SKIPPED. On this axis that is the worst possible failure: it is the one
    # that looks for credentials in files that ship to end users, and a skipped file reports
    # exactly what a clean file reports. Reproduced during self-review with a real non-ASCII
    # filename; `-z` disables the quoting entirely, which is why it is the fix rather than an
    # unescaper. Same `read -r -d ''` idiom base/practices/shell.md prescribes for `find -print0`.
    #
    # THE READ'S OWN STATUS IS CHECKED FIRST, in its own statement. Piped straight into `while`,
    # the pipeline's status is the LOOP's, this file sets no `pipefail`, and so an unreadable index
    # or a `ls-files` failure produced exactly the output of a clean scan — the axis silently off.
    # Materializing the list first is what makes the failure visible; a `warning` record is emitted
    # instead of nothing, because "I could not look" and "I looked and found nothing" must never
    # print the same thing on a credential check.
    # TWO CALLS, AND NEITHER PUTS `-z` OUTPUT THROUGH A COMMAND SUBSTITUTION. The first draft of
    # this status check did — `_ad_tracked="$(git ls-files -z …)"` — and bash STRIPS NUL BYTES from
    # a substitution, so the delimiters vanished, `read -d ''` found none, and the axis processed
    # ZERO files while reporting success. That is the same silent-skip this whole block exists to
    # prevent, reintroduced by the fix for its sibling. `mapfile -d ''` reads the NULs correctly
    # because it consumes the pipe directly.
    #
    # The first call is for the VERDICT (did git succeed?), the second for the DATA. Two cheap
    # reads is the price of not having to choose between knowing the status and keeping the
    # delimiters — and iterating an array rather than a pipeline also takes the loop out of a
    # subshell, so nothing here depends on that subtlety any more.
    if ! git -C "$root" ls-files -z ".$a" >/dev/null 2>&1; then
      _ad_emit warning "the tracked-file list for .$a could not be read (git ls-files failed) — the distributable-config axis did NOT run for it"
      continue
    fi
    _ad_tracked=()
    mapfile -d '' -t _ad_tracked < <(git -C "$root" ls-files -z ".$a" 2>/dev/null)
    for rel in "${_ad_tracked[@]}"; do
      [ -n "$rel" ] || continue
      f="$root/$rel"
      [ -f "$f" ] || continue
      if grep -qE '(/Users/|/home/|/Volumes/)[A-Za-z0-9._-]+/' "$f" 2>/dev/null; then
        _ad_emit distributable warn "$rel" "contains a machine-local absolute path — this file is tracked, so it travels to every clone of this project"
      fi
      # Closed prefix list. THE MATCHED VALUE IS NEVER PRINTED — only the PREFIX that identified
      # it, which is the part that is not secret and the part the operator needs to find it.
      # base/practices/logging-and-secrets.md governs a diagnostic exactly as it governs a log,
      # and a report that echoed the token would publish it into the PR body or the CI log the
      # operator pastes this output into. `grep -o` the prefix ALONE, so the secret is never in a
      # shell variable in the first place — redacting after capture is one careless `printf` away
      # from leaking, and this way there is nothing to leak.
      if line="$(grep -oE '(ghp_|gho_|ghu_|ghs_|github_pat_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]{8,}' "$f" 2>/dev/null \
                   | grep -oE '^(ghp_|gho_|ghu_|ghs_|github_pat_|sk-|xox[baprs]-|AKIA)' | head -n 1)" \
         && [ -n "$line" ]; then
        _ad_emit distributable warn "$rel" "contains a credential-shaped literal (prefix '$line', value NOT shown) in a TRACKED file — rotate it and move it out of the repo"
      fi
      if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; then
        _ad_emit distributable warn "$rel" "contains a PEM private-key header in a TRACKED file — rotate it and move it out of the repo"
      fi
    done

    # AXIS 3 — statusLine / hook PRECEDENCE. It reports ONLY WHAT IT READ, which is the project
    # side, and it says so.
    #
    # The first version asserted that "the global install also provides one" on the strength of the
    # PROJECT file alone. That is a claim about a second layer this function never opened, and it
    # is false in ordinary configurations: the Codex and Gemini adapters wire no global hooks at
    # all, and the Claude installer configures no global status line. So the axis was manufacturing
    # a factual finding about a layer it had not looked at — exactly the confidently-wrong answer
    # #29 was filed about, committed by the check written to catch it. Review caught it.  (adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
    #
    # Establishing the global side properly means reading ~/.<agent>/settings.json and knowing each
    # harness's resolution order. `adb_claude_hooks_state` answers part of it for Claude only, and
    # no equivalent exists for the others — so rather than half-answer, this reports the project
    # declaration as the fact it is and names the comparison as the operator's next step.
    if [ -f "$root/.$a/settings.json" ] \
       && grep -q '"statusLine"' "$root/.$a/settings.json" 2>/dev/null; then
      _ad_emit precedence note ".$a/settings.json" "declares its own statusLine — /adopt did NOT inspect the user-level or baseline layers, so it cannot say which one renders; compare them yourself before removing either"
    fi
    if [ -f "$root/.$a/settings.json" ] \
       && grep -q '"hooks"' "$root/.$a/settings.json" 2>/dev/null; then
      _ad_emit precedence note ".$a/settings.json" "declares its own hooks — /adopt did NOT inspect the user-level layer, so the effective set is unverified here; compare them yourself before removing either"
    fi

  done <<EOF
$(printf '%s\n' "$agents" | tr ',' '\n')
EOF
  return 0
}

# --- the upstream pin ----------------------------------------------------------------------------
# `.ai-dev-baseline/upstream.toml` — the artifact #21 asked for, and the schema is fixed HERE  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# because #285 is going to consume it.
#
# WHY TOML, AND WHY THAT PATH. TOML because `adb_toml_get` already reads it and agents.toml
# already is one — a second config syntax would be a second parser. That path because
# `.ai-dev-baseline/` is already the practice-prescribed, agent-neutral, TRACKED home for
# cross-agent project state (the decision log lives there); putting the pin under `.claude/` would
# make a cross-agent fact Claude-owned, which is the mistake handling-the-unknown.md calls out.
#
# WHAT REPLACES #21's `.upstream` SNAPSHOT — and it is a substitution made on purpose, not an  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# omission. #21 asked for "a `.upstream` snapshot (or equivalent) so a project can diff local  (adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work)
# drift against the baseline it inherited". A copied tree is the worse equivalent: it doubles
# every file, goes stale silently, and answers "what did I inherit" with a copy that may itself
# have drifted. A COMMIT is a better snapshot than a snapshot — the install is a symlink into a
# real git clone, so the inherited tree is recoverable exactly, forever, from one 40-byte field.
# `pin-drift` prints the command that does it.
cmd_pin_render() {
  [ "$#" -ge 4 ] && [ "$#" -le 5 ] || die "pin-render: needs <version> <commit> <adopted-date> <stack> [agents]"
  local version="$1" commit="$2" adopted="$3" stack="$4" agents="${5:-}" a out="" seen="" y m d
  # EVERY FIELD IS VALIDATED BECAUSE EVERY FIELD IS INTERPOLATED INTO TOML. `version` was not, and
  # it comes from `git describe`, i.e. from a TAG NAME — which may contain a quote or (via an
  # adversarial or merely odd tag) a newline. Either produces malformed TOML at best and an
  # injected extra key at worst, in a file `adb_toml_get` will later be trusted to read. Review
  # caught it. The grammar is what a version string legitimately needs and nothing more.
  case "$version" in
    "") ;;                                     # legitimately empty: a clone with no tag yet
    *[!A-Za-z0-9._+-]*) die "pin-render: <version> may hold only [A-Za-z0-9._+-]: $(adb_tsv_field_display "$version")" ;;
  esac
  # THE COMMIT MUST BE FULL-LENGTH, not merely "long enough". The pin's whole claim is that it
  # recovers the inherited tree EXACTLY — an abbreviated name is resolvable only while it stays
  # unambiguous in a growing repository, so a 7-character pin can become ambiguous years later,
  # which is precisely the window the pin exists to survive. 40 hex for SHA-1, 64 for SHA-256.
  _ad_check_commit "$commit" pin-render
  # A REAL CALENDAR DATE, not merely the right shape. `2026-99-99` passed the pattern test and
  # would have been written into the pin as the adoption date.
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "pin-render: <adopted-date> must be YYYY-MM-DD: $(adb_tsv_field_display "$adopted")" ;;
  esac
  y="${adopted%%-*}"; m="${adopted#*-}"; m="${m%%-*}"; d="${adopted##*-}"
  # Bounds only — no leap-year table. A month/day range check catches every shape-valid nonsense
  # a caller can produce here (the date comes from `date -u`, so this is a guard against a
  # mis-wired call, not a calendar library), and claiming more than it checks would be the
  # overstatement this file keeps refusing elsewhere.
  { [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] && [ "$y" -ge 1970 ]; } 2>/dev/null \
    || die "pin-render: <adopted-date> is not a calendar date: $adopted"
  case "$stack" in
    node|node-monorepo|rust|go|python|php|php-wordpress|shell|unknown) ;;
    *) die "pin-render: <stack> is not a known stack label: $stack" ;;
  esac
  if [ -n "$agents" ]; then
    # THE SHARED VALIDATOR, not a second copy. This arm used to carry its own `*[!a-z0-9-]*` test,
    # which already disagreed with `_ad_check_agents` about a leading dash — two answers to one
    # question, which is the duplication `docs/design-principles.md` forbids and which made the
    # commit message's "one shared helper now" false. Review caught both halves.
    _ad_check_agents "$agents" pin-render
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      # A DUPLICATE is refused rather than emitted twice: `agents = ["claude", "claude"]` is not a
      # fact about anything, and a reader deduplicating it silently would hide the mis-wired call.
      case ",$seen," in *",$a,"*) die "pin-render: duplicate agent token: $a" ;; esac
      seen="$seen,$a"
      [ -z "$out" ] || out="$out, "
      out="$out\"$a\""
    done <<EOF
$(printf '%s\n' "$agents" | tr ',' '\n')
EOF
  fi
  cat <<TOML
# ai-dev-baseline — upstream pin. Written by /adopt; safe to read, safe to commit.
#
# It records WHICH baseline this project inherited, so drift can be reviewed and an update can be
# taken deliberately instead of discovered. \`commit\` is the load-bearing field: the install is a
# symlink into a git clone, so that one value recovers the exact inherited tree at any time.
# See: adopt-lib.sh pin-drift .ai-dev-baseline/upstream.toml <baseline-root>

[upstream]
version = "$version"
commit  = "$commit"
adopted = "$adopted"
stack   = "$stack"
agents  = [$out]
TOML
}

cmd_pin_read() {
  [ "$#" -eq 2 ] || die "pin-read: needs <pin-file> <key>"
  local file="$1" key="$2" v
  [ -f "$file" ] || die "pin-read: no such pin file: $file"
  case "$key" in
    version|commit|adopted|stack|agents) ;;
    *) die "pin-read: unknown pin key: $key" ;;
  esac
  v="$(adb_toml_get "$file" upstream "$key")" || return 1
  if [ "$key" = agents ]; then adb_toml_array "$v"; else adb_toml_unquote "$v"; fi
}

# Print the command that answers "what has changed in the baseline since I adopted it".
# PRINTS IT, never runs it: the answer belongs in the operator's pager, and running git in a
# clone this file does not own is outside what a predicate should do.
cmd_pin_drift() {
  [ "$#" -eq 2 ] || die "pin-drift: needs <pin-file> <baseline-root>"
  local file="$1" root="$2" commit
  [ -d "$root" ] || die "pin-drift: not a directory: $root"
  commit="$(cmd_pin_read "$file" commit)" || die "pin-drift: could not read the pinned commit from $file"
  [ -n "$commit" ] || die "pin-drift: the pin carries no commit"
  # REVALIDATED HERE, because `pin-render`'s validation governs what THIS TOOL writes and says
  # nothing about a pin that already existed or was edited by hand. A pin carrying `HEAD` produced
  # `git log HEAD..HEAD` — an empty range that reports no drift at all, which is the most
  # reassuring possible wrong answer. Review caught the comment below assuming a guarantee that
  # applied one function away.
  _ad_check_commit "$commit" pin-drift
  # THE PATH IS SHELL-QUOTED, because this subcommand's OUTPUT IS A COMMAND. An unquoted path with
  # a space produces a command that silently targets the wrong directory, and one with a `;` or a
  # `$(…)` produces executable syntax in a line the operator is expected to paste into a shell.
  # `adb_display_value` is the shared quoting home (it is `printf %q`), so this is the existing
  # primitive rather than a local escape. Review caught it.
  #
  # The COMMIT needs no quoting — it was validated as hex above — but it is passed through the same
  # helper anyway so no future edit has to remember which of the two was safe.
  printf 'git -C %s log --oneline %s..HEAD\n' "$(adb_display_value "$root")" "$(adb_display_value "$commit")"
  printf 'git -C %s diff %s..HEAD -- base/ scripts/lib/\n' "$(adb_display_value "$root")" "$(adb_display_value "$commit")"
}

# --- plan ----------------------------------------------------------------------------------------
# Read classified records on stdin (`<verdict>TAB<kind>TAB<path>TAB<reason>`) and print the
# ORDERED migration plan — the issue's "ordered migration plan, not a big-bang change".
#
# THE ORDERING IS THE DECISION, and it is testable precisely because it is not narration:
#   1. escalate  — unresolved questions come FIRST. Everything below is advice that assumes the
#                  questions above were answered; burying them under a list of edits is how they
#                  get skipped.
#   2. move      — re-home every delta BEFORE anything is removed. Reversed, there is a window in
#                  which the behavior has been deleted and not yet re-homed, and if the run stops
#                  there the project has silently lost a capability.
#   3. remove    — only byte-identical duplicates, and only after step 2 has banked the deltas.
#   4. keep      — listed last, for completeness, so "not mentioned" never has to mean "keep".
#
# NOTHING HERE EXECUTES ANY OF IT. The plan is text. /adopt's only writes are agents.toml and the
# pin, both of which are new files, and both on explicit approval.
cmd_plan() {
  [ "$#" -eq 0 ] || die "plan: takes no arguments (classified TSV on stdin)"
  local verdict v kind adoptpath reason n rec
  local -a records=()
  # `mapfile`, NOT a temp file. The first draft used `mktemp` plus a `trap … EXIT` to clean it up,
  # and that trap is the bug: a trap set inside a function is the SHELL's, so it would fire for
  # every later subcommand in a sourced context and, worse, silently replace a caller's own EXIT
  # trap. bash 5.3 is the floor here (this file is not one of D30/D35's three carve-outs), so the
  # in-memory read is available and needs no cleanup at all.
  mapfile -t records || die "plan: could not read the classified records on stdin"

  # AN UNRECOGNISED VERDICT IS REPORTED, NOT DROPPED. The four-verdict loop below only ever prints
  # records whose first field matches one of its own words, so `mov<TAB>…` — a truncation, a typo, a
  # producer that grew a fifth verdict — produced NO output and NO error, and the artifact vanished
  # from the plan entirely. The malformed-record check inside the loop could not catch it, because
  # it runs only AFTER a record has matched a verdict. Review caught it. This pass runs first so the
  # complaint is at the top, where an operator reads it before acting on anything below.
  local bad_n=0
  for rec in "${records[@]}"; do
    [ -n "$rec" ] || continue
    IFS="$TAB" read -r v _ _ _ <<< "$rec"
    case "$v" in
      escalate|move|remove|keep) continue ;;
    esac
    bad_n=$((bad_n + 1))
    [ "$bad_n" -eq 1 ] && printf '## UNRECOGNISED VERDICTS — these artifacts are in NO section below\n'
    printf '%s. %s\n' "$bad_n" "$(adb_display_value "$rec")"
  done
  [ "$bad_n" -gt 0 ] && printf '\n'

  for verdict in escalate move remove keep; do
    n=0
    for rec in "${records[@]}"; do
      [ -n "$rec" ] || continue
      IFS="$TAB" read -r v kind adoptpath reason <<< "$rec"
      [ "$v" = "$verdict" ] || continue
      n=$((n + 1))
      [ "$n" -eq 1 ] && printf '## %s\n' "$verdict"
      # A MALFORMED RECORD IS NAMED, not rendered as blanks. A short record used to print
      # `1.  (skill) — `, an empty path and an empty reason formatted exactly like a real entry —
      # so a producer that had started dropping fields looked like a project with a nameless
      # artifact. That is the silent-guard shape: the failure wearing the output of a success.
      if [ -z "$adoptpath" ] || [ -z "$reason" ]; then
        printf '%s. MALFORMED RECORD — expected <verdict>TAB<kind>TAB<path>TAB<reason>, got: %s\n' \
          "$n" "$(adb_display_value "$rec")"
        continue
      fi
      # THE PATH IS RENDERED, NOT PRINTED RAW. `_ad_emit` deliberately accepts every byte except
      # the two record delimiters, so a legal filename may carry a carriage return or an ANSI
      # escape — and this line goes straight to the operator's terminal. A scanned repository could
      # forge plan lines or move the cursor. The malformed-record arm below already used
      # `adb_display_value`; the ordinary arm is the one an attacker would actually reach.
      printf '%s. %s (%s) — %s\n' "$n" "$(adb_display_value "$adoptpath")" "$kind" "$reason"
    done
    [ "$n" -gt 0 ] && printf '\n'
  done
  return 0
}

# --- dispatch ------------------------------------------------------------------------------------
main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    resolve)     cmd_resolve "$@" ;;
    shape-field) cmd_shape_field "$@" ;;
    baseline)    cmd_baseline "$@" ;;
    shipped)     cmd_shipped "$@" ;;
    scan)        cmd_scan "$@" ;;
    prescribed)  cmd_prescribed "$@" ;;
    delta)       cmd_delta "$@" ;;
    classify)    cmd_classify "$@" ;;
    roles-infer) cmd_roles_infer "$@" ;;
    propose)     cmd_propose "$@" ;;
    stack)       cmd_stack "$@" ;;
    hygiene)     cmd_hygiene "$@" ;;
    pin-render)  cmd_pin_render "$@" ;;
    pin-read)    cmd_pin_read "$@" ;;
    pin-drift)   cmd_pin_drift "$@" ;;
    plan)        cmd_plan "$@" ;;
    *) printf 'adopt-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
