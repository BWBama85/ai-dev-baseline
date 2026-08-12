#!/usr/bin/env bash
# ai-dev-baseline — /adopt decision predicates (issue #20, consolidating #21 and #29).
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
#   adopt-lib.sh shipped     <baseline-root> [agent]        # what the baseline installs
#                                                          #   <kind>TAB<name>TAB<agent>TAB<src>
#   adopt-lib.sh scan        <project-root> [--agents a,b]  # the project's adoption surface
#   adopt-lib.sh prescribed  <kind> <name>                  # is this a prescribed home?
#   adopt-lib.sh delta       <kind> <project-path> <baseline-path>   # same|differs|unknown
#   adopt-lib.sh classify    <kind> <collision yes|no> <delta same|differs|unknown> <prescribed yes|no>
#   adopt-lib.sh roles-infer <project-root>                 # propose [roles] from evidence
#   adopt-lib.sh propose                                    # roles-infer TSV on stdin -> agents.toml
#   adopt-lib.sh stack       <project-root>                 # the project's stack label
#   adopt-lib.sh hygiene     <project-root> [--agents a,b]  # the four #29 axes
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

# --- agent-token validation -----------------------------------------------------------------------
# `--agents` is interpolated straight into a path (`$root/.$a`), so an unvalidated token is a
# directory traversal: `--agents '../..'` makes the scan read `$root/.../..` and report what it
# finds there as if it belonged to the project it was pointed at. Read-only, so nothing is
# destroyed — but an inventory that silently describes a DIFFERENT directory is the same class of
# wrong answer D59 refused for `adb_repo_shape`, and the operator acts on this one.
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

# --- shipped -------------------------------------------------------------------------------------
# Print the IDENTITY of every artifact the baseline installs, as `<kind>TAB<name>`. Kinds:
# `skill` (a skill directory name), `script` (a hook/statusline basename), `lib` (the shared
# scripts/lib dir), `rootdoc` (the agent's root doc basename).
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
  local root="$1" want="${2:-}" agent src dest kind name
  [ -d "$root/agents" ] || die "shipped: not a baseline checkout (no agents/ under $root)"
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    [ -z "$want" ] || [ "$agent" = "$want" ] || continue
    # A HOME that cannot appear in a real path, so a manifest line is unambiguously splittable
    # back into agent-relative form. `adb_agent_manifest` interpolates it literally.
    #
    # BOTH columns are read: the DESTINATION carries the identity the classifier matches on,
    # and the SOURCE is where `delta` reads the baseline's own copy from.
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
$(adb_agent_manifest "$agent" "$root" "/ADB_SHIPPED")
EOF
  done <<EOF
$(_ad_agents_from_baseline "$root")
EOF
}

# --- delta ---------------------------------------------------------------------------------------
# Is the project's copy the same as the baseline's? Print `same`, `differs`, or `unknown`; exit 0.
# This is the one input to `classify` that requires reading both files, and it lives here rather
# than as a `cmp -s` in the workflow for two reasons that are not stylistic:
#
#   1. A SKILL IS A DIRECTORY. The manifest's source for a skill is `agents/claude/skills/cleanup`,
#      and `cmp` on a directory is an error, not a comparison — a workflow doing the obvious thing
#      would get a non-zero status and, reading it as "differs", would classify every project's
#      every skill as a fork carrying a delta. The comparison for a skill is its `SKILL.md`.
#   2. `unknown` HAS TO BE REACHABLE. A missing or unreadable baseline file is not "differs"; it
#      is an unanswered question, and `classify` routes it to `escalate`. Collapsing the two is
#      how an unreadable install becomes a confident recommendation.
#
# UNKNOWN IS THE DEFAULT, not the fallback. Every path that fails to establish equality lands
# there, so a case nobody anticipated fails toward asking rather than toward acting.
cmd_delta() {
  [ "$#" -eq 3 ] || die "delta: needs <kind> <project-path> <baseline-path>"
  local kind="$1" proj="$2" base="$3"
  case "$kind" in
    skill)
      # A composed skill carries an ownership marker and is a GENERATED artifact, not a fork —
      # but it is still not byte-identical to the base, so it lands in `differs` and the operator
      # is told to look. That is the correct direction: `move` on an already-composed skill costs
      # a glance, whereas `remove` would delete a project's deltas.
      proj="$proj/SKILL.md"; base="$base/SKILL.md" ;;
    *) ;;
  esac
  [ -f "$proj" ] || { printf 'unknown\n'; return 0; }
  [ -f "$base" ] || { printf 'unknown\n'; return 0; }
  [ -r "$proj" ] && [ -r "$base" ] || { printf 'unknown\n'; return 0; }
  if cmp -s "$proj" "$base"; then printf 'same\n'; else printf 'differs\n'; fi
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
# `src/`, and #29's first axis is why: support-workstation's `src/lib/cli/` IS product code that
# orchestrates agent CLIs, and a scan that classified it would be recommending changes to the
# product. `hygiene` reports on that boundary; `scan` simply does not cross it.
cmd_scan() {
  local root="" agents="" a f d n
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
  [ -n "$agents" ] || agents="claude,codex,gemini"
  _ad_check_agents "$agents" scan

  # Root docs + the manifest + the decision log.
  for f in CLAUDE.md AGENTS.md GEMINI.md; do
    [ -f "$root/$f" ] && _ad_emit rootdoc "$f" "$f"
  done
  [ -f "$root/agents.toml" ] && _ad_emit manifest agents.toml agents.toml
  [ -f "$root/.ai-dev-baseline/decisions.md" ] && _ad_emit decisions .ai-dev-baseline/decisions.md decisions.md
  [ -f "$root/.ai-dev-baseline/upstream.toml" ] && _ad_emit pin .ai-dev-baseline/upstream.toml upstream.toml

  # Prior-framework artifacts (ai-dev-workflow). Reported as their own kind so the plan can carry
  # a reconcile step rather than classifying them as ordinary project content — bama-politics
  # carries both and has diverged far beyond the template they came from.
  [ -f "$root/.claude/UPSTREAM_VERSION" ] && _ad_emit foreign-pin .claude/UPSTREAM_VERSION UPSTREAM_VERSION
  [ -f "$root/CLAUDE.md.upstream" ]       && _ad_emit foreign-pin CLAUDE.md.upstream CLAUDE.md.upstream

  # Per-agent config trees.
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ -d "$root/.$a" ] || continue
    [ -f "$root/.$a/settings.json" ] && _ad_emit settings ".$a/settings.json" settings.json
    for d in "$root/.$a"/skills/*/; do
      [ -d "$d" ] || continue
      n="${d%/}"; n="${n##*/}"
      [ -f "$d/overrides.md" ] && _ad_emit override ".$a/skills/$n/overrides.md" overrides.md
      [ -f "$d/SKILL.md" ]     && _ad_emit skill    ".$a/skills/$n" "$n"
    done
    for f in "$root/.$a"/scripts/*; do
      [ -f "$f" ] || continue
      n="${f##*/}"
      _ad_emit script ".$a/scripts/$n" "$n"
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
_ad_role_hits() {  # <root> <role-regex> — files whose lines name BOTH the role and an agent token
  local root="$1" rx="$2" agent="$3"
  # Config surfaces only, never src/ (#29 axis 1). A miss prints nothing and is not an error.
  grep -rIl --exclude-dir=state -E "$rx" \
    "$root"/.claude "$root"/.codex "$root"/.gemini "$root"/CLAUDE.md "$root"/AGENTS.md "$root"/GEMINI.md \
    2>/dev/null \
    | while IFS= read -r f; do
        grep -IE "$rx" "$f" 2>/dev/null | grep -qE "$agent" && printf '%s\n' "${f#"$root"/}"
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
# AND WHAT THE FIELD MEANS, stated exactly, because #21's wording invites an overclaim: it records
# the STACK OF THE ADOPTED PROJECT. The baseline ships exactly ONE flavor today — there is no
# php-wordpress variant to have applied — so this is the field that lets a future variant be
# recorded and matched, not evidence that variants exist. #285 is where a variant would be consumed.
cmd_stack() {
  [ "$#" -eq 1 ] || die "stack: needs <project-root>"
  local r="$1"
  [ -d "$r" ] || die "stack: not a directory: $r"
  if [ -f "$r/package.json" ]; then
    if [ -f "$r/pnpm-workspace.yaml" ] || [ -f "$r/turbo.json" ] || [ -f "$r/lerna.json" ]; then
      printf 'node-monorepo\n'; return 0
    fi
    printf 'node\n'; return 0
  fi
  [ -f "$r/Cargo.toml" ]  && { printf 'rust\n'; return 0; }
  [ -f "$r/go.mod" ]      && { printf 'go\n'; return 0; }
  if [ -f "$r/composer.json" ] || [ -f "$r/style.css" ] || [ -d "$r/wp-content" ]; then
    grep -rqIl --include='*.php' -e 'add_action' -e 'wp_enqueue' "$r" 2>/dev/null \
      && { printf 'php-wordpress\n'; return 0; }
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

# --- hygiene -------------------------------------------------------------------------------------
# The four adoption-hygiene axes #29 contributed, as `<axis>TAB<severity>TAB<path>TAB<detail>`.
# Severity is `warn` or `note`; neither is a failure, and this subcommand exits 0 unless its
# arguments are bad. These are things a human must look at, not verdicts.
#
# WHAT THIS IS NOT: a secret scanner. The credential axis matches a short, closed list of
# high-confidence prefixes and refuses to guess beyond it, and it REDACTS what it matched rather
# than echoing it (base/practices/logging-and-secrets.md applies to a diagnostic exactly as it
# applies to a log). A novel credential format will not be caught. Saying so is better than
# implying a coverage this cannot have.
cmd_hygiene() {
  local root="" agents="" a f rel line rule where igrc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agents) [ "$#" -ge 2 ] && [ -n "$2" ] || die "hygiene: --agents needs a non-empty value"; agents="$2"; shift 2 ;;
      -*) die "hygiene: unknown option: $1" ;;
      *) [ -z "$root" ] || die "hygiene: takes exactly one <project-root>"; root="$1"; shift ;;
    esac
  done
  [ -n "$root" ] || die "hygiene: needs <project-root>"
  [ -d "$root" ] || die "hygiene: not a directory: $root"
  [ -n "$agents" ] || agents="claude,codex,gemini"
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
    # The pipeline puts the loop in a SUBSHELL, which is safe here only because the loop's whole
    # effect is what it prints — nothing below reads a variable it sets.
    git -C "$root" ls-files -z ".$a" 2>/dev/null | while IFS= read -r -d '' rel; do
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

    # AXIS 3 — statusLine / hook PRECEDENCE. Reported as a fact about layering, never as a verdict
    # about which one wins: that is the harness's resolution order, this file has not verified it,
    # and inventing a winner is exactly the sort of confident wrong answer #29 was filed about.
    if [ -f "$root/.$a/settings.json" ] \
       && grep -q '"statusLine"' "$root/.$a/settings.json" 2>/dev/null; then
      _ad_emit precedence note ".$a/settings.json" "declares statusLine while the global install also provides one — layered definitions; confirm which renders before removing either"
    fi
    if [ -f "$root/.$a/settings.json" ] \
       && grep -q '"hooks"' "$root/.$a/settings.json" 2>/dev/null; then
      _ad_emit precedence note ".$a/settings.json" "declares hooks while the global install also wires them — layered definitions; confirm the effective set before removing either"
    fi

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
      line="$(git -C "$root" check-ignore -v --no-index ".$a/state/implement-issue-active.json" 2>/dev/null)"
      igrc=$?
      if [ "$igrc" -eq 0 ]; then
        # `check-ignore -v` prints `<source>:<line>:<pattern><TAB><pathname>`, and ONLY the
        # <pattern> field may be examined. Matching the whole line is a guard that CANNOT FIRE:
        # the <pathname> column is the path we just asked about, so it always contains
        # `.<agent>/state`, every input looked like an explicit rule, and the axis stayed silent
        # on the exact `*.json` blanket-ignore it was written for. Caught by running it against a
        # fixture rather than by reading it — which is why base/practices/self-review.md requires
        # a new guard to be OBSERVED failing.
        #
        # The two leading fields are stripped positionally, which assumes <source> carries no
        # colon. Git's sources here are `.gitignore` and `.git/info/exclude`; neither does.
        # `where` keeps the tab-free half (`.gitignore:3:*.json`) — the citation the operator
        # needs to go fix it. The FULL line must never reach a record: it carries the tab that
        # separates pattern from pathname, so embedding it made `_ad_emit` refuse the whole
        # finding and print an unreadable warning instead. The record-safety guard caught that,
        # which is the guard working; the message is what needed fixing.
        where="${line%%"$TAB"*}"   # source:line:pattern
        rule="${where#*:}"          # line:pattern
        rule="${rule#*:}"           # pattern
        case "$rule" in
          # A rule that NAMES the state dir is the correct, deliberate state — say nothing.
          *".$a/state"*) : ;;
          # Anything else reaches the state dir by accident. unraid-cache-cleaner's `*.json` is
          # the real instance: it hides `.<agent>/state/*.json` from git, which LOOKS like the
          # right outcome until a future state file lands with a name the blanket rule also
          # swallows and nobody ever notices it went untracked-and-invisible.
          *) _ad_emit ignore-risk warn ".$a/state/" "reached only by the BROAD ignore rule '$rule' (at $where), not by a rule that names it — run bin/agent-init so the rule is deliberate" ;;
        esac
      elif [ "$igrc" -eq 1 ]; then
        _ad_emit ignore-risk warn ".$a/state/" "is NOT gitignored — /implement-issue writes the untrusted issue body here; run bin/agent-init before adopting"
      else
        # Say what could not be established, not what is true. An operator who reads "could not be
        # determined" goes and looks; one who reads "is NOT gitignored" about a repo that ignores
        # it perfectly well learns to discount the axis.
        _ad_emit ignore-risk warn ".$a/state/" "COULD NOT BE DETERMINED — git check-ignore failed (rc $igrc) rather than answering; check this by hand before trusting the rest of this axis"
      fi
    fi
  done <<EOF
$(printf '%s\n' "$agents" | tr ',' '\n')
EOF
  return 0
}

# --- the upstream pin ----------------------------------------------------------------------------
# `.ai-dev-baseline/upstream.toml` — the artifact #21 asked for, and the schema is fixed HERE
# because #285 is going to consume it.
#
# WHY TOML, AND WHY THAT PATH. TOML because `adb_toml_get` already reads it and agents.toml
# already is one — a second config syntax would be a second parser. That path because
# `.ai-dev-baseline/` is already the practice-prescribed, agent-neutral, TRACKED home for
# cross-agent project state (the decision log lives there); putting the pin under `.claude/` would
# make a cross-agent fact Claude-owned, which is the mistake handling-the-unknown.md calls out.
#
# WHAT REPLACES #21's `.upstream` SNAPSHOT — and it is a substitution made on purpose, not an
# omission. #21 asked for "a `.upstream` snapshot (or equivalent) so a project can diff local
# drift against the baseline it inherited". A copied tree is the worse equivalent: it doubles
# every file, goes stale silently, and answers "what did I inherit" with a copy that may itself
# have drifted. A COMMIT is a better snapshot than a snapshot — the install is a symlink into a
# real git clone, so the inherited tree is recoverable exactly, forever, from one 40-byte field.
# `pin-drift` prints the command that does it.
cmd_pin_render() {
  [ "$#" -ge 4 ] && [ "$#" -le 5 ] || die "pin-render: needs <version> <commit> <adopted-date> <stack> [agents]"
  local version="$1" commit="$2" adopted="$3" stack="$4" agents="${5:-}" a out=""
  # A commit is the load-bearing field — it is what `pin-drift` feeds to git — so it is validated
  # rather than trusted. A version may legitimately be empty (a clone with no tag yet); a commit
  # may not, because a pin without one cannot answer the question the pin exists for.
  case "$commit" in
    *[!0-9a-fA-F]*|"") die "pin-render: <commit> must be a hex object name: $commit" ;;
  esac
  [ "${#commit}" -ge 7 ] || die "pin-render: <commit> is too short to be unambiguous: $commit"
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die "pin-render: <adopted-date> must be YYYY-MM-DD: $adopted" ;;
  esac
  case "$stack" in
    node|node-monorepo|rust|go|python|php|php-wordpress|shell|unknown) ;;
    *) die "pin-render: <stack> is not a known stack label: $stack" ;;
  esac
  if [ -n "$agents" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case "$a" in *[!a-z0-9-]*) die "pin-render: bad agent token: $a" ;; esac
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
  printf 'git -C %s log --oneline %s..HEAD\n' "$root" "$commit"
  printf 'git -C %s diff %s..HEAD -- base/ scripts/lib/\n' "$root" "$commit"
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
      printf '%s. %s (%s) — %s\n' "$n" "$adoptpath" "$kind" "$reason"
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
