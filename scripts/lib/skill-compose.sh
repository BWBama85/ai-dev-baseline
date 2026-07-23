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
if ! command -v adb_repo_root >/dev/null 2>&1; then
  printf 'skill-compose: FATAL — %s is missing adb_repo_root\n' "$_adb_sc_common" >&2
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
# Assigned via `read -r -d ''` (NOT `$(cat <<…)`): the program contains backticks (fence
# detection, backtick-stripping in slug()), which bash 3.2's naive command-substitution scanner
# mis-pairs across a heredoc. Feeding the heredoc to `read` sidesteps that scan entirely; `-d ''`
# reads to EOF (returns nonzero there, hence `|| true`) and `-r` keeps every backslash literal.
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
BEGIN {
  in_block = 0; fatal = 0; base_seen = 0
  frontmatter = 1; fmdelims = 0; infence = 0
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
  if ($0 ~ /^```/) { infence = !infence; if (mode == "compose") print; next }   # a fenced line is never a heading
  if (!infence && $0 ~ /^### /) {
    a = anchor_of($0)
    if (mode == "list") { h = $0; sub(/^###[[:space:]]+/, "", h); printf "%-52s (line %d)  %s\n", a, FNR, h; next }
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
        "$_ADB_SC_AWK" "$ov" "$base" > "$tmp"; then
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
  if grep -Eq '<!--[[:space:]]*adb:(override|end)' "$tmp"; then
    adb_sc_err "composed output for '$name' still contains adb: directives (internal error)"; return 1
  fi
  return 0
}

# Paths for <name> under <repo>/<home>. Sets base/ov/out globals (bash 3.2: no namerefs).
adb_sc_paths() {
  local name="$1" repo="$2" home="$3"
  _sc_base="$home/.$_ADB_SC_AGENT/skills/$name/SKILL.md"
  _sc_ov="$repo/.$_ADB_SC_AGENT/skills/$name/overrides.md"
  _sc_out="$repo/.$_ADB_SC_AGENT/skills/$name/SKILL.md"
}

# compose one skill. Returns 0 on success, 1 on any error. Usage: adb_sc_compose_one <name> <repo> <home>
adb_sc_compose_one() {
  local name="$1" repo="$2" home="$3" tmp rc=0
  adb_sc_paths "$name" "$repo" "$home"
  [ -f "$_sc_ov" ]   || { adb_sc_err "no overrides file: $_sc_ov"; return 1; }
  [ -f "$_sc_base" ] || { adb_sc_err "no installed base skill: $_sc_base (is the baseline installed for $_ADB_SC_AGENT?)"; return 1; }
  # Refuse to clobber a destination we do not own — a pre-existing SKILL.md WITHOUT our marker is a
  # hand-authored full fork; overwriting it would silently destroy the project's work.
  if [ -e "$_sc_out" ] && ! grep -Fq "$_ADB_SC_MARKER" "$_sc_out" 2>/dev/null; then
    adb_sc_err "refusing to overwrite $_sc_out — it exists but is not a skill-compose output (a hand-authored fork?). Remove or rename it, then recompose."
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/adb-sc.XXXXXX")" || { adb_sc_err "mktemp failed"; return 1; }
  if adb_sc_render "$name" "$_sc_base" "$_sc_ov" "$tmp"; then
    mkdir -p "$(dirname "$_sc_out")"
    mv "$tmp" "$_sc_out"
    printf 'skill-compose: composed %s\n' "$_sc_out"
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

# check one skill's currency (recompose + byte-compare). Returns 0 current, 1 stale/error.
adb_sc_check_one() {
  local name="$1" repo="$2" home="$3" tmp rc=0
  adb_sc_paths "$name" "$repo" "$home"
  [ -f "$_sc_ov" ]   || { adb_sc_err "no overrides file: $_sc_ov"; return 1; }
  [ -f "$_sc_base" ] || { adb_sc_err "no installed base skill: $_sc_base"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/adb-sc.XXXXXX")" || { adb_sc_err "mktemp failed"; return 1; }
  if ! adb_sc_render "$name" "$_sc_base" "$_sc_ov" "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [ ! -e "$_sc_out" ]; then
    printf 'skill-compose: STALE %s — composed output missing; run: skill-compose compose %s\n' "$_sc_out" "$name" >&2
    rc=1
  elif ! cmp -s "$tmp" "$_sc_out"; then
    printf 'skill-compose: STALE %s — differs from a fresh compose (base updated, overrides changed, or hand-edited); run: skill-compose compose %s\n' "$_sc_out" "$name" >&2
    rc=1
  else
    printf 'skill-compose: current %s\n' "$_sc_out"
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

# --- CLI (only when executed, not when sourced) -----------------------------------------------
adb_sc_usage() { adb_usage "${BASH_SOURCE[0]:-$0}"; }

adb_sc_main() {
  local cmd="" repo="" agent="$_ADB_SC_AGENT" home="${HOME:-}"
  local -a names=()
  [ $# -gt 0 ] && { cmd="$1"; shift; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)  repo="${2:-}"; shift 2 ;;
      --agent) agent="${2:-}"; shift 2 ;;
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
    adb_sc_paths "$n" "$repo" "$home"
    [ -f "$_sc_base" ] || { adb_sc_err "no installed base skill: $_sc_base"; return 1; }
    LC_ALL=C awk -v mode=list -v base="$_sc_base" -v ops="$_ADB_SC_OPS" "$_ADB_SC_AWK" "$_sc_base"
    return
  fi

  # compose | check: explicit names, else discover overrides in the repo.
  if [ "${#names[@]}" -eq 0 ]; then
    local disc
    disc="$(adb_sc_discover "$repo")"
    if [ -z "$disc" ]; then
      adb_sc_err "no .$_ADB_SC_AGENT/skills/*/overrides.md found under $repo — nothing to $cmd"
      return 0
    fi
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done <<EOF
$disc
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
