#!/usr/bin/env bash
# ai-dev-baseline — partial skill override composer.
#
# A project that needs a small delta on a baseline skill used to fork the ENTIRE
# SKILL.md — which freezes it in time and misses every later baseline improvement to
# the OTHER steps (issue #22). This composer lets a project carry ONLY its deltas in a
# tiny `overrides.md` and MERGE them onto the CURRENT installed baseline skill, so every
# step the project does not touch keeps inheriting upstream changes.
#
# The model mirrors scripts/build.sh: the base skill is the source, the project's
# overrides are the deltas, and the composed `.claude/skills/<name>/SKILL.md` is a
# GENERATED artifact (it carries an ownership marker; recompose after the baseline
# updates and it re-merges onto the new base). Claude's harness then resolves the
# project-local composed skill ahead of the global one ("most specific wins", the
# existing Override-2 behavior — see docs/per-project-overrides.md).
#
# Anchors are the base skill's `### ` step headings, addressed by a slug: the leading
# "N." step number is stripped (so renumbering a step does NOT break an override), the
# rest lowercased with each run of non-alphanumerics collapsed to "-". An override that
# targets an anchor the base no longer has FAILS LOUD — that doubles as the "warn when a
# fork has diverged from its baseline source" lint. `list-anchors` prints the valid set.
#
# Overrides file — `.claude/skills/<name>/overrides.md` — is HTML-comment directives:
#
#   <!-- adb:override anchor="implement" op="append" -->
#   - [ ] Docs-zone sign-off: every changed doc zone re-read and initialed.
#   <!-- adb:end -->
#
#   op ∈ append | prepend | replace   (all operate on ONE anchored section)
#     append  — insert the content at the END of the step (before the next `### `)
#     prepend — insert the content right AFTER the step heading
#     replace — replace the step BODY (heading kept, everything under it swapped)
#   One directive per anchor (a duplicate anchor FAILS LOUD). Inserting whole NEW steps
#   (before/after) and codex/gemini are tracked follow-ups; v1 is Claude + these three ops.
#
# Usage:
#   skill-compose.sh compose      [--repo DIR] [NAME ...]   # write composed SKILL.md(s)
#   skill-compose.sh check        [--repo DIR] [NAME ...]   # nonzero if any is stale
#   skill-compose.sh list-anchors [--repo DIR] NAME         # print the base skill's anchors
#   skill-compose.sh -h | --help
#
# With no NAME, compose/check discover every `.claude/skills/*/overrides.md` in the repo.
# `check` recomposes to a temp file and byte-compares it against the committed output, so
# it also catches a hand-edit or a composer-version change — not just an input change. Wire
# it as a project gate (agents.toml [gates] skillcompose = "… check") to enforce currency.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib). Without it adb_repo_root vanishes, so a missing library FAILS LOUD.
_adb_sc_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_sc_common" ]; then
  printf 'skill-compose: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_sc_common" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$_adb_sc_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi
if ! command -v adb_repo_root >/dev/null 2>&1; then
  printf 'skill-compose: FATAL — %s is missing adb_repo_root\n' "$_adb_sc_common" >&2
  return 1 2>/dev/null || exit 1
fi
# The fence rule now lives in common.sh (#136/#131). A library predating it would leave
# `$_ADB_MD_AWK` unset, and under `set -u` the awk invocation below would abort mid-run — so probe
# for it by name and fail loud instead, the way the adb_repo_root probe above already does.
if [ -z "${_ADB_MD_AWK:-}" ]; then
  printf 'skill-compose: FATAL — %s is missing the shared markdown filter (_ADB_MD_AWK)\n' "$_adb_sc_common" >&2
  return 1 2>/dev/null || exit 1
fi

# --- config -----------------------------------------------------------------------------------
_ADB_SC_AGENT="claude"                 # v1 supports Claude only (codex/gemini are a follow-up)
_ADB_SC_MARKER="# adb:composed-skill"  # ownership token: identifies OUR generated output
_ADB_SC_VERSION="v1"
_ADB_SC_OPS="append prepend replace"

# The engine (awk), one program with two modes so the anchor rule lives ONCE:
#   mode=compose — merge the overrides onto the base, emit the composed skill on stdout.
#   mode=list    — emit "<anchor>  (line N)  <heading>" for each base step (feeds list-anchors).
# The base file is identified by FILENAME == the `-v base=` path (NOT a record counter), so an
# EMPTY overrides.md — which yields no records and would never advance a counter — still composes
# to base+marker instead of silently emitting nothing. Exit: 0 ok · 2 overrides error · 3
# base/anchor error. Kept to POSIX awk (index/substr/2-arg match/gsub — no gensub, no
# match(s,re,arr)) so it runs on BSD awk (macOS) as well as gawk; callers run it under LC_ALL=C
# for byte-stable classes.
# Assigned via `read -r -d ''` rather than `$(cat <<…)`, and it STAYS that way under the 5.3 floor
# (#258) — for a better reason than the one it replaced. The original rationale was a bash 3.2
# defect: that parser's command-substitution scanner mis-paired the backticks this program contains
# (fence detection, backtick-stripping in slug()) across a heredoc. 5.3 parses that form correctly,
# so the defect is gone — but `$(cat …)` costs a fork and a subshell to move a compile-time
# constant, and `read` is a builtin that costs neither. `-d ''` reads to EOF (returns nonzero there,
# hence `|| true`) and `-r` keeps every backslash literal.
IFS= read -r -d '' _ADB_SC_AWK <<'AWK' || true
function err(m) { printf "skill-compose: %s\n", m > "/dev/stderr" }
function emit(s) { if (s != "") print s }              # empty content emits nothing
function slug(s,   t) {
  t = tolower(s)
  gsub(/`/, "", t)                                     # strip inline-code backticks
  gsub(/[^a-z0-9]+/, "-", t)                           # runs of non-alnum -> single dash
  sub(/^-+/, "", t); sub(/-+$/, "", t)                 # trim leading/trailing dashes
  return t
}
# A `### ` heading line -> its anchor: strip the leading "N." step number so a step can be
# renumbered without breaking an override, then slugify. The ONE definition of the anchor rule,
# shared by both modes so list-anchors can never advertise an anchor the compose pass rejects.
function anchor_of(line,   t) {
  t = line; sub(/^###[[:space:]]+/, "", t); sub(/^[0-9]+\.[[:space:]]*/, "", t)
  return slug(t)
}
# Fence detection is NOT defined here. `adb_md_fence_delim` from common.sh is prepended to this
# program (#136/#131): it answers "does this line open or close a fenced block?", and `md_fence_len`
# is the in-a-fence flag.
#
# This file used to carry its own — a boolean toggle on any ``` after 0-3 spaces — and the two
# detectors had already drifted apart, in both directions at once. `roadmap-lib` honored `~~~` and
# this did not, so a tilde-fenced `### ` line was ADVERTISED as a composable anchor; and a ``` that
# closed a longer run left the toggle inverted for the whole rest of the file, HIDING every real
# step after it. Two copies of one rule, two suites, and neither could see the other drift.
BEGIN {
  in_block = 0; fatal = 0; base_seen = 0
  frontmatter = 1; fmdelims = 0
  split(ops, _o, " "); for (i in _o) opok[_o[i]] = 1
}

# ---------- the overrides file (compose mode only; in list mode no file != base) ----------
FILENAME != base {
  if (in_block) {
    if ($0 ~ /^<!--[[:space:]]*adb:end[[:space:]]*-->[[:space:]]*$/) {
      dir_content[curdir] = blockbuf; in_block = 0; next
    }
    if ($0 ~ /<!--[[:space:]]*adb:override/) { err("nested adb:override before adb:end (overrides line " FNR ")"); fatal = 2; exit 2 }
    blockbuf = (seen_content ? blockbuf "\n" $0 : $0); seen_content = 1
    next
  }
  if ($0 ~ /^[[:space:]]*$/) next                        # blank line — ok
  if ($0 ~ /<!--[[:space:]]*adb:skill/) next             # optional header comment — ignored
  if ($0 ~ /<!--[[:space:]]*adb:end/) { err("stray adb:end with no open block (overrides line " FNR ")"); fatal = 2; exit 2 }
  if ($0 ~ /<!--[[:space:]]*adb:override/) {
    if ($0 !~ /^<!--[[:space:]]*adb:override[[:space:]]+anchor="[a-z0-9][a-z0-9-]*"[[:space:]]+op="[a-z]+"[[:space:]]*-->[[:space:]]*$/) {
      err("malformed adb:override (overrides line " FNR ") — want: <!-- adb:override anchor=\"slug\" op=\"append|prepend|replace\" -->"); fatal = 2; exit 2
    }
    match($0, /anchor="[a-z0-9][a-z0-9-]*"/); a = substr($0, RSTART + 8, RLENGTH - 9)
    match($0, /op="[a-z]+"/);                 o = substr($0, RSTART + 4, RLENGTH - 5)
    if (!(o in opok)) { err("unknown op \"" o "\" (overrides line " FNR ") — allowed: " ops); fatal = 2; exit 2 }
    if (a in dir_op)  { err("duplicate override for anchor \"" a "\" (overrides line " FNR ") — one directive per anchor"); fatal = 2; exit 2 }
    curdir = a; dir_op[a] = o; dir_content[a] = ""; blockbuf = ""; seen_content = 0; in_block = 1
    next
  }
  if ($0 ~ /adb:/) { err("unrecognized adb: directive outside a block (overrides line " FNR "): " $0); fatal = 2; exit 2 }
  next                                                   # any other prose outside a block — ignored
}

# ---------- the base skill ----------
FILENAME == base && FNR == 1 {                           # opening --- (+ marker injection in compose mode)
  base_seen = 1
  if (in_block) { err("adb:override block was not closed with adb:end before end of overrides file"); fatal = 2; exit 2 }
  if ($0 != "---") { err("base skill does not start with a '---' frontmatter delimiter"); fatal = 3; exit 3 }
  if (mode == "compose") {
    print "---"
    print marker " " version " — DO NOT EDIT BY HAND."
    print "# Generated by scripts/lib/skill-compose.sh — merges this project's deltas onto the"
    print "# installed ai-dev-baseline base skill. Sources:"
    print "#   base:      ~/." agent "/skills/" skillname "/SKILL.md   (the installed baseline skill)"
    print "#   overrides: ." agent "/skills/" skillname "/overrides.md   (this project's deltas)"
    print "# Edit overrides.md and recompose (skill-compose.sh); never hand-edit this file."
  }
  fmdelims = 1
  next
}
FILENAME == base && frontmatter {                        # stream frontmatter verbatim (compose) to its close
  if (mode == "compose") print
  if ($0 == "---") { fmdelims++; if (fmdelims >= 2) frontmatter = 0 }
  next
}
FILENAME == base {
  # Track fence state ALWAYS (so a `### ` inside a fence is never a heading, even while a replace
  # is skipping the body), but only PRINT the delimiter when not skipping — otherwise a replaced
  # step's fenced block would leak its empty ``` ``` delimiters into the output.
  if (adb_md_fence_delim($0)) { if (mode == "compose" && !skipping) print; next }
  if (!md_fence_len && $0 ~ /^### /) {
    a = anchor_of($0)
    if (mode == "list") {                                # advertise the anchor; flag a base collision
      h = $0; sub(/^###[[:space:]]+/, "", h)
      dup = (a in baseseen) ? "  [DUPLICATE — compose will reject]" : ""
      baseseen[a] = 1
      printf "%-52s (line %d)  %s%s\n", a, FNR, h, dup
      next
    }
    if (pending != "") { emit(dir_content[pending]); pending = "" }   # flush prior append
    skipping = 0
    if (a in baseseen) { err("duplicate anchor \"" a "\" in base skill (two headings collide) — ambiguous target"); fatal = 3; exit 3 }
    baseseen[a] = 1
    print
    if (a in dir_op) {
      used[a] = 1
      if (dir_op[a] == "replace") { emit(dir_content[a]); skipping = 1; next }
      if (dir_op[a] == "prepend") { emit(dir_content[a]); next }
      if (dir_op[a] == "append")  { pending = a; next }
    }
    next
  }
  if (mode == "list") next
  if (skipping) next
  print
}
END {
  if (fatal) exit fatal                                  # a mid-stream error already reported + set the code
  if (!base_seen) { err("base skill was not read or is empty"); exit 3 }
  if (mode == "list") exit 0
  if (pending != "") emit(dir_content[pending])
  for (a in dir_op) if (!(a in used)) {
    err("override targets anchor \"" a "\" which is not a '### ' step heading in the base skill — the baseline may have renamed/removed that step; update overrides.md"); errflag = 1
  }
  if (errflag) exit 3
}
AWK

# --- helpers ----------------------------------------------------------------------------------

adb_sc_err() { printf 'skill-compose: %s\n' "$*" >&2; }

# A skill name must be a single path segment of [a-z0-9-] starting alnum: rejects "", a leading
# dash, and anything with "/", ".." or other metacharacters — so it can never traverse out of the
# skills dir or be interpolated anywhere dangerous.
adb_sc_valid_name() {
  case "$1" in
    ''|-*) return 1 ;;
    *[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Render the composed skill for <name> to <tmp>. Returns nonzero (and leaves nothing usable) on
# any engine error OR a self-validation failure — CI never inspects a project's composed output,
# so the composer validates its own result here. Usage: adb_sc_render <name> <base> <ov> <tmp>
adb_sc_render() {
  local name="$1" base="$2" ov="$3" tmp="$4" k
  if ! LC_ALL=C awk -v mode=compose -v base="$base" -v ops="$_ADB_SC_OPS" -v agent="$_ADB_SC_AGENT" \
        -v skillname="$name" -v marker="$_ADB_SC_MARKER" -v version="$_ADB_SC_VERSION" \
        "$_ADB_MD_AWK$_ADB_SC_AWK" "$ov" "$base" > "$tmp"; then
    return 1
  fi
  # Self-validate the result (CI never inspects a project's composed output): still a loadable
  # SKILL.md, and no leftover directive residue. Frontmatter is streamed verbatim from the base,
  # so these re-assert a base invariant cheaply rather than trusting it blindly.
  if [ "$(head -n1 "$tmp")" != "---" ]; then
    adb_sc_err "composed output for '$name' does not start with '---' (internal error)"; return 1
  fi
  for k in 'name:' 'description:' 'user-invocable:'; do
    if ! head -n 40 "$tmp" | grep -q "^${k}"; then
      adb_sc_err "composed output for '$name' is missing required frontmatter key '${k}'"; return 1
    fi
  done
  # Match only the actual directive shapes (`adb:override ` + attrs, or `adb:end -->`), not any
  # content that merely contains the substring "adb:end" (e.g. a legitimate `<!-- adb:endpoint -->`).
  if grep -Eq '<!--[[:space:]]*adb:(override[[:space:]]|end[[:space:]]*-->)' "$tmp"; then
    adb_sc_err "composed output for '$name' still contains an adb: directive (internal error)"; return 1
  fi
  return 0
}

# Paths for <name> under <repo>/<home>, returned through NAMEREFS: $4, $5 and $6 name the caller's
# own variables for base / overrides / output. Returns 0, or 2 on an unusable output name.
#
# This used to write three shared `_sc_*` globals because bash 3.2 had no namerefs (#258). Three
# call sites then read state nothing had declared, and every one of them had to remember which
# global held which path — the ordering bug that a nameref makes unrepresentable.
#
# THE OUTPUT NAMES ARE VALIDATED, and that is not defensive garnish. `declare -n ref=$x` EVALUATES
# an array subscript inside $x, so an unvalidated name is an arbitrary-command-execution seam in a
# library `install.sh` symlinks into every consumer's runtime. Requiring a plain identifier closes
# it. The same pass catches the other two nameref failures, both of which are silent:
#   - a name equal to one of THIS function's locals is a circular reference — bash warns on stderr
#     and the caller's variable stays unset, so it composes against an empty path;
#   - three names that are really one variable would leave all three paths equal to the last
#     assignment, which is a wrong compose that looks like a working one.
# Refusing beats warning: the caller gets a status it can act on. Fixtures: check-skill-compose.sh (S).
adb_sc_paths() {
  # `${4-}`, NOT `$4`. This library is SOURCED, so an unbound expansion under the caller's `set -u`
  # does not fail the call — it kills the caller. A stale pre-#258 three-argument call must get a
  # clean refusal, not take a consumer's hook down with "unbound variable"; an empty name falls
  # straight into the validation below. Fixture: check-skill-compose.sh S11.
  local _asp_n="${1-}" _asp_r="${2-}" _asp_h="${3-}" _asp_v
  for _asp_v in "${4-}" "${5-}" "${6-}"; do
    case "$_asp_v" in
      ''|*[!A-Za-z0-9_]*|[0-9]*)
        adb_sc_err "adb_sc_paths: '$_asp_v' is not a usable output variable name"; return 2 ;;
      _asp_n|_asp_r|_asp_h|_asp_v|_asp_base|_asp_ov|_asp_out)
        adb_sc_err "adb_sc_paths: output name '$_asp_v' collides with this function's own locals"; return 2 ;;
    esac
  done
  if [ "${4-}" = "${5-}" ] || [ "${4-}" = "${6-}" ] || [ "${5-}" = "${6-}" ]; then
    adb_sc_err "adb_sc_paths: the three output names must be distinct (got '${4-}' '${5-}' '${6-}')"; return 2
  fi
  # SC2034 ("appears unused") is wrong for a nameref OUTPUT parameter: assigning it is the entire
  # point, and the read happens in the caller's scope through a name shellcheck cannot follow.
  # Declared explicitly rather than left to luck — without it this file passes only because the
  # collision `case` above happens to MENTION these three names, so deleting that guard would turn
  # the linter red for a reason unrelated to the guard.
  # shellcheck disable=SC2034
  local -n _asp_base="${4-}" _asp_ov="${5-}" _asp_out="${6-}"
  _asp_base="$_asp_h/.$_ADB_SC_AGENT/skills/$_asp_n/SKILL.md"
  _asp_ov="$_asp_r/.$_ADB_SC_AGENT/skills/$_asp_n/overrides.md"
  _asp_out="$_asp_r/.$_ADB_SC_AGENT/skills/$_asp_n/SKILL.md"
}

# compose one skill. Returns 0 on success, 1 on any error. Usage: adb_sc_compose_one <name> <repo> <home>
adb_sc_compose_one() {
  local name="$1" repo="$2" home="$3" tmp rc=0
  local sc_base sc_ov sc_out
  adb_sc_paths "$name" "$repo" "$home" sc_base sc_ov sc_out || return 1
  [ -f "$sc_ov" ]   || { adb_sc_err "no overrides file: $sc_ov"; return 1; }
  [ -f "$sc_base" ] || { adb_sc_err "no installed base skill: $sc_base (is the baseline installed for $_ADB_SC_AGENT?)"; return 1; }
  # Refuse to clobber a destination we do not own — a pre-existing SKILL.md WITHOUT our marker is a
  # hand-authored full fork; overwriting it would silently destroy the project's work. Our marker
  # always sits near the very top (line 2, right after the opening ---), so only the head is
  # inspected — a fork that merely *mentions* the marker deep in its prose isn't mistaken for ours.
  if [ -e "$sc_out" ] && ! head -n 5 "$sc_out" 2>/dev/null | grep -Fq "$_ADB_SC_MARKER"; then
    adb_sc_err "refusing to overwrite $sc_out — it exists but is not a skill-compose output (a hand-authored fork?). Remove or rename it, then recompose."
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/adb-sc.XXXXXX")" || { adb_sc_err "mktemp failed"; return 1; }
  if adb_sc_render "$name" "$sc_base" "$sc_ov" "$tmp"; then
    # A failed mkdir/mv (read-only tree, ENOSPC, …) must NOT report success — automation would
    # otherwise believe the composed SKILL.md was refreshed while the old/missing file remains.
    if mkdir -p "$(dirname "$sc_out")" && mv "$tmp" "$sc_out"; then
      printf 'skill-compose: composed %s\n' "$sc_out"
    else
      adb_sc_err "failed to write $sc_out (read-only project tree? no space?)"; rc=1
    fi
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

# check one skill's currency (recompose + byte-compare). Returns 0 current, 1 stale/error.
adb_sc_check_one() {
  local name="$1" repo="$2" home="$3" tmp rc=0
  local sc_base sc_ov sc_out
  adb_sc_paths "$name" "$repo" "$home" sc_base sc_ov sc_out || return 1
  [ -f "$sc_ov" ]   || { adb_sc_err "no overrides file: $sc_ov"; return 1; }
  [ -f "$sc_base" ] || { adb_sc_err "no installed base skill: $sc_base"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/adb-sc.XXXXXX")" || { adb_sc_err "mktemp failed"; return 1; }
  if ! adb_sc_render "$name" "$sc_base" "$sc_ov" "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [ ! -e "$sc_out" ]; then
    printf 'skill-compose: STALE %s — composed output missing; run: skill-compose compose %s\n' "$sc_out" "$name" >&2
    rc=1
  elif ! cmp -s "$tmp" "$sc_out"; then
    printf 'skill-compose: STALE %s — differs from a fresh compose (base updated, overrides changed, or hand-edited); run: skill-compose compose %s\n' "$sc_out" "$name" >&2
    rc=1
  else
    printf 'skill-compose: current %s\n' "$sc_out"
  fi
  rm -f "$tmp"
  return "$rc"
}

# Discover skill names with an overrides.md under <repo>/.claude/skills/*/. Prints one per line.
adb_sc_discover() {
  local repo="$1" d name
  for d in "$repo/.$_ADB_SC_AGENT/skills"/*/; do
    [ -f "${d}overrides.md" ] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done
}

# Discover ORPHANED composed outputs: a skill dir with OUR composed SKILL.md (ownership marker
# near the top) but NO overrides.md. Its source is gone, so it is now a frozen-fork shadow that
# no-name discovery would silently skip — the currency gate must catch it. Prints one name/line.
adb_sc_orphans() {
  local repo="$1" d name
  for d in "$repo/.$_ADB_SC_AGENT/skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    [ -f "${d}overrides.md" ] && continue                                   # has its source
    head -n 5 "${d}SKILL.md" 2>/dev/null | grep -Fq "$_ADB_SC_MARKER" || continue  # only OUR outputs
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done
}

# --- CLI (only when executed, not when sourced) -----------------------------------------------
adb_sc_usage() { adb_usage "${BASH_SOURCE[0]:-$0}"; }

adb_sc_main() {
  local cmd="" repo="" agent="$_ADB_SC_AGENT" home="${HOME:-}"
  local -a names=()
  [ $# -gt 0 ] && { cmd="$1"; shift; }
  while [ $# -gt 0 ]; do
    case "$1" in
      # Validate the operand BEFORE `shift 2`: `shift 2` with only one arg left fails and leaves
      # $# unchanged under this non-errexit loop, which would spin forever on `--repo`/`--agent`
      # given no value (a simple typo could wedge a gate).
      --repo)  [ $# -ge 2 ] || { adb_sc_err "--repo requires a value"; return 2; };  repo="$2";  shift 2 ;;
      --agent) [ $# -ge 2 ] || { adb_sc_err "--agent requires a value"; return 2; }; agent="$2"; shift 2 ;;
      -h|--help) adb_sc_usage; return 0 ;;
      --*) adb_sc_err "unknown option: $1"; return 2 ;;
      *) names+=("$1"); shift ;;
    esac
  done

  case "$cmd" in
    -h|--help) adb_sc_usage; return 0 ;;
    compose|check|list-anchors) ;;
    '') adb_sc_err "expected a subcommand (compose | check | list-anchors)"; return 2 ;;
    *)  adb_sc_err "unknown subcommand '$cmd' (compose | check | list-anchors)"; return 2 ;;
  esac

  # v1 is Claude-only: the composed-skill project-shadow precedence is documented for Claude, and
  # Gemini's base skill installs under a different root (~/.gemini/config/skills). Codex/Gemini
  # support is a tracked follow-up; refuse other agents loudly rather than compose a broken path.
  if [ "$agent" != "claude" ]; then
    adb_sc_err "v1 supports --agent claude only (codex/gemini are a tracked follow-up)"; return 2
  fi
  [ -n "$home" ] || { adb_sc_err "HOME is not set — cannot locate the installed base skill"; return 2; }
  [ -n "$repo" ] || repo="$(adb_repo_root)"

  local n rc=0
  if [ "$cmd" = "list-anchors" ]; then
    [ "${#names[@]}" -eq 1 ] || { adb_sc_err "list-anchors takes exactly one NAME"; return 2; }
    n="${names[0]}"
    adb_sc_valid_name "$n" || { adb_sc_err "invalid skill name: '$n'"; return 2; }
    local sc_base sc_ov sc_out
    adb_sc_paths "$n" "$repo" "$home" sc_base sc_ov sc_out || return 1
    [ -f "$sc_base" ] || { adb_sc_err "no installed base skill: $sc_base"; return 1; }
    LC_ALL=C awk -v mode=list -v base="$sc_base" -v ops="$_ADB_SC_OPS" "$_ADB_MD_AWK$_ADB_SC_AWK" "$sc_base"
    return
  fi

  # compose | check: explicit names, else discover overrides in the repo. A named orphan (an owned
  # SKILL.md without overrides.md) already errors via adb_sc_*_one's "no overrides file" guard; the
  # gap this closes is the no-name path, which keys off overrides.md and would skip an orphan.
  if [ "${#names[@]}" -eq 0 ]; then
    local disc orph
    disc="$(adb_sc_discover "$repo")"
    orph="$(adb_sc_orphans "$repo")"
    if [ -z "$disc" ] && [ -z "$orph" ]; then
      adb_sc_err "no .$_ADB_SC_AGENT/skills/*/overrides.md found under $repo — nothing to $cmd"
      return 0
    fi
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done <<EOF
$disc
EOF
    # Orphaned owned outputs are a frozen-fork shadow with no source — always a failure, in both
    # compose (can't regenerate it) and check (it's stale by definition).
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      adb_sc_err "orphaned composed skill: $repo/.$_ADB_SC_AGENT/skills/$n/SKILL.md carries the ownership marker but its overrides.md is gone — a now-frozen shadow with no source. Restore overrides.md or remove the SKILL.md."
      rc=1
    done <<EOF
$orph
EOF
  fi

  for n in "${names[@]}"; do
    if ! adb_sc_valid_name "$n"; then adb_sc_err "invalid skill name: '$n'"; rc=1; continue; fi
    if [ "$cmd" = "compose" ]; then
      adb_sc_compose_one "$n" "$repo" "$home" || rc=1
    else
      adb_sc_check_one "$n" "$repo" "$home" || rc=1
    fi
  done
  return "$rc"
}

# Execute only when run directly (never when sourced by a test or another script).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  adb_sc_main "$@"
  exit $?
fi
