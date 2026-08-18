#!/usr/bin/env bash
# ai-dev-baseline — the release-pinned per-project install (#285).
#
# The global model symlinks a clone into ~/.<agent>, so every project on the machine runs
# whatever `main` says right now. This one vendors ONE released version into ONE project tree:
# the project records the version it is on, a machine with no clone can install it, and a
# breaking change upstream reaches nothing until someone upgrades on purpose.
#
# Both models coexist. The global install is untouched by every path here, and where both are
# active the agent harness already resolves the project's copy first (docs/per-project-overrides.md,
# Override 2) — `status` reports the overlap rather than trying to arbitrate it.
#
# THIS CODE WRITES INTO SOMEBODY ELSE'S REPOSITORY, which is why the refusals below are the
# load-bearing half and why every destructive step is keyed to a digest rather than to a path.
#
# Usage:
#   pinned-install.sh install --project DIR [--agent claude|codex]...
#                             ( --version X.Y.Z | --artifact FILE --sums FILE )
#   pinned-install.sh status    [--project DIR] [--offline]
#   pinned-install.sh notice    [--project DIR] [--check-latest]   # silent unless pinned
#   pinned-install.sh upgrade   --to X.Y.Z [--project DIR] [--artifact FILE --sums FILE]
#   pinned-install.sh uninstall [--project DIR]
#   pinned-install.sh payload   <agent> <artifact-root> <project-root>
#   pinned-install.sh reanchor  <agent> <project-root>       (stdin -> stdout)
#   pinned-install.sh verify    <tarball> <sums-file>
#   pinned-install.sh -h | --help
#
# Exit codes:
#   install/upgrade/uninstall  0 ok · 10 refused (state) · 11 verification failed · 12 a required
#                              tool is missing · 13 fetch failed · 14 publish/removal failed · 2 usage
#   status                     0 pinned and current · 10 pinned, a newer release exists
#                              · 11 not pinned · 20 pinned but the payload is missing, altered or
#                              unverifiable · 30 the release list could not be read
#   verify                     0 verified · 10 no usable record for that filename · 11 digest
#                              mismatch · 12 no usable sha256 tool / unreadable input
#   payload/reanchor           0 ok · 1 a root or member this manifest cannot represent · 2 usage
#
# Globals read: ADB_PINNED_REPO (default BWBama85/ai-dev-baseline) — the release source, used only
# when the pin records none. ADB_PINNED_MIN_VERSION overrides the coarse version floor.

set -u

# --- required shared library ---------------------------------------------------------------
# common.sh lives beside this file; the install lands the whole lib directory together, so a
# missing one is a broken install and fails loud rather than degrading.
_pi_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_pi_common" ]; then
  printf 'pinned-install: FATAL — required library not found: %s (broken/incomplete install)\n' "$_pi_common" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$_pi_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the caller, and the
# caller owns its own gate. An `if`, never `[ … ] && …`, which returns non-zero on the sourced
# path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi
if ! command -v adb_pinned_owned >/dev/null 2>&1 || ! command -v adb_claude_hook_scripts >/dev/null 2>&1; then
  printf 'pinned-install: FATAL — %s is missing adb_pinned_owned/adb_claude_hook_scripts\n' "$_pi_common" >&2
  return 1 2>/dev/null || exit 1
fi

PI_DEFAULT_REPO="${ADB_PINNED_REPO:-BWBama85/ai-dev-baseline}"

# A COARSE floor only. The real one is structural: `_pi_probe_tree` requires the artifact to carry
# this very file, so a release published before this feature existed is refused for the reason that
# actually matters — it cannot supply the status/upgrade/uninstall path the docs promise — rather
# than by a version number someone has to remember to bump.
PI_MIN_VERSION="${ADB_PINNED_MIN_VERSION:-2.0.0}"

# Everything this install owns lives under ONE directory per agent, `.<agent>/adb/`, and the
# harness-fixed skills root. The namespace is load-bearing rather than tidy: `.claude/scripts/`
# is `handling-the-unknown.md`'s one prescribed home for a project's OWN gate policy, so an
# install that wrote its gates there would occupy the path the practice reserves for the project.
# Hooks and `lib/` sit as siblings inside it because every gate script resolves its library as
# `$(dirname "$0")/lib/common.sh` — that layout is what lets them be vendored byte-unchanged.
PI_NS="adb"

# The ONE statement of which shipped Claude hooks a pinned project does NOT get.
# `adb_claude_hook_scripts` in common.sh remains the enumeration of the hook set; this is the
# single exclusion on top of it, so a hook added there is vendored and wired here automatically
# instead of being silently omitted. `session-currency.sh` fast-forwards the install-source clone,
# and a pinned project has none.
PI_HOOKS_EXCLUDED="session-currency.sh"

# Codex silently truncates a project doc at `project_doc_max_bytes`, whose default is 32 KiB
# (`AGENTS_MD_MAX_BYTES` in codex-rs/core/src/config/mod.rs: "Larger files are *silently truncated*
# to this size"). The rendered practices are larger than that, so the operator is told — loudly,
# with the one config line that fixes it — rather than left with half the law and no symptom.
PI_CODEX_DOC_DEFAULT_MAX=32768

# The managed region in a project's own AGENTS.md. Codex discovers project instructions by
# concatenating every AGENTS.md from the project root down to the cwd; its own discovery module
# (codex-rs/core/src/agents_md.rs, read this run) documents that walk, and the fallback it does
# offer is a filename list (`project_doc_fallback_filenames`), not an include directive — so the
# root file is the only place a payload can put text Codex will read.
PI_BEGIN='<!-- ai-dev-baseline:begin (managed by pinned-install.sh — do not edit inside) -->'
PI_END='<!-- ai-dev-baseline:end -->'

_pi_say() { printf '%s\n' "$*"; }
_pi_err() { printf 'pinned-install: %s\n' "$*" >&2; }

# _pi_need_val <option> <argc> — every option below takes a value, and `shift 2` with one argument
# left FAILS and shifts NOTHING, so the parse loop spins forever on a truncated command line.
# Checked rather than assumed at every site.
_pi_need_val() {
  [ "$2" -ge 2 ] || { _pi_err "$1 needs a value"; return 2; }
  return 0
}

# _pi_project_root — the git toplevel of the current directory, or non-zero.
#
# NOT adb_repo_root: that helper falls back to `pwd` and always returns 0, so outside a repository
# it would answer with whatever directory the operator happened to be standing in — and this value
# decides where a payload is written and, at uninstall, what is deleted.
_pi_project_root() {
  local r
  r="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}

# The digest and the escaping-path rule live in `common.sh` (#285): `adopt-lib.sh` asks the same
# questions of the same receipt, and two implementations of "is this file still the one we wrote"
# is exactly the drift that library exists to prevent. Thin local names keep the call sites short.
_pi_sha256() { adb_sha256 "$@" || { _pi_err "could not digest: ${1:-<none>}"; return 1; }; }
_pi_relpath_safe() { adb_pinned_relpath_safe "$@"; }

# _pi_owns <newline-list> <path> — membership, not a prefix test. `.claude/adb/` looks like a safe
# prefix until a project puts its own file there.
_pi_owns() {
  local nl
  nl="$(printf '\nx')"; nl="${nl%x}"
  [ -n "$1" ] || return 1
  case "$nl$1$nl" in
    *"$nl$2$nl"*) return 0 ;;
  esac
  return 1
}

# --- the payload map -------------------------------------------------------------------------

# _pi_hook_scripts — the Claude hooks a pinned project gets: the shared enumeration minus this
# file's one documented exclusion. One producer for the payload AND the wiring below.
_pi_hook_scripts() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case " $PI_HOOKS_EXCLUDED " in *" $s "*) continue ;; esac
    printf '%s\n' "$s"
  done <<EOF
$(adb_claude_hook_scripts)
EOF
}

# cmd_payload <agent> <artifact-root> <project-root> — print `<src>TAB<dest>` for every plain
# file this install copies, dest absolute under <project-root>.
#
# THE ONE PRODUCER. install copies it, the receipt digests it, `status` re-checks it and uninstall
# removes it, so the four cannot drift (docs/design-principles.md). The two MERGED surfaces — the
# project's settings.json and its AGENTS.md — are deliberately NOT here: they are regions inside
# files the project owns, not files this install owns, and a remover that treated them as owned
# would delete a project's own configuration. `_pi_check_surfaces` is what covers them instead.
#
# An unknown agent prints nothing and returns 0, mirroring adb_agent_manifest. A root or member
# this map cannot represent prints NOTHING and returns 1: half a map is worse than none.
cmd_payload() {
  [ "$#" -eq 3 ] || { _pi_err "payload: needs <agent> <artifact-root> <project-root>"; return 2; }
  local agent="$1" a="$2" p="$3" d f name
  if ! adb_tsv_field_safe "$a" || ! adb_tsv_field_safe "$p"; then
    _pi_err "payload: a root contains a tab or newline, which this manifest cannot represent"
    return 1
  fi
  case "$agent" in claude|codex) ;; *) return 0 ;; esac

  local doc skills dot
  dot=".$agent"
  case "$agent" in
    claude) doc="$a/agents/claude/CLAUDE.md";  skills="$a/agents/claude/skills" ;;
    codex)  doc="$a/agents/codex/AGENTS.md";   skills="$a/agents/codex/skills" ;;
  esac

  # The practices. Claude reads `.claude/rules/*.md` at session start for a rule carrying no
  # `paths:` frontmatter; Codex has no such directory, so its copy is staged here and spliced into
  # the project's AGENTS.md as a managed region instead.
  case "$agent" in
    claude) printf '%s\t%s\n' "$doc" "$p/.claude/rules/ai-dev-baseline.md" ;;
    codex)  printf '%s\t%s\n' "$doc" "$p/$dot/$PI_NS/AGENTS.practices.md" ;;
  esac

  # The skills, at the harness-fixed project root for this agent.
  for d in "$skills"/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"; name="${name##*/}"
    adb_tsv_field_safe "$name" || {
      _pi_err "payload: skill directory name contains a tab or newline: $(adb_tsv_field_display "$name")"
      return 1
    }
    # A SUBDIRECTORY IS REFUSED, NOT SKIPPED, and the glob covers DOTFILES — a skill adding
    # `.assets/` or a `.config` would otherwise be dropped without a word, producing a payload
    # silently missing a file the skill reads at runtime. Every shipped skill is flat today, so
    # refusing costs nothing now and turns a future bundled skill into a build failure rather than
    # a broken install.
    for f in "$d".[!.]* "$d"..?* "$d"*; do
      [ -e "$f" ] || continue
      if [ -d "$f" ]; then
        _pi_err "payload: skill '$name' bundles a subdirectory (${f##*/}), which this payload map does not model"
        return 1
      fi
      [ -f "$f" ] || continue
      printf '%s\t%s\n' "$f" "$p/$dot/skills/$name/${f##*/}"
    done
  done

  # The shared libraries. Every rendered skill invokes them by path, and `reanchor` below is what
  # repoints those invocations here.
  for f in "$a"/scripts/lib/*.sh; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "$f" "$p/$dot/$PI_NS/lib/${f##*/}"
  done

  # Claude's Stop-hook gates, from the shared enumeration.
  if [ "$agent" = claude ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ -f "$a/agents/claude/scripts/$name" ] || continue
      printf '%s\t%s\n' "$a/agents/claude/scripts/$name" "$p/.claude/$PI_NS/$name"
    done <<EOF
$(_pi_hook_scripts)
EOF
  fi
}

# cmd_reanchor <agent> <project-root> — rewrite the library prefix on stdin, to stdout.
#
# A rendered skill reaches its libraries through `$HOME/.<agent>/scripts/lib/` (scripts/build.sh),
# which is one directory shared by the global install and by every project on the machine. A
# vendored payload must not write there, so the vendored SKILL.md is repointed at the project's own
# copy. `git rev-parse --show-toplevel` rather than an absolute path because the result is
# committed into somebody else's repository, and the agent may invoke from a subdirectory.
#
# The prefix carries `scripts/lib/` on purpose. `$HOME/.<agent>/skills` also appears in a rendered
# body and must NOT be rewritten — it genuinely means the user-global skills root.
cmd_reanchor() {
  [ "$#" -eq 2 ] || { _pi_err "reanchor: needs <agent> <project-root>"; return 2; }
  local agent="$1" from to
  case "$agent" in claude|codex) ;; *) _pi_err "reanchor: unknown agent: $agent"; return 2 ;; esac
  from="\$HOME/.$agent/scripts/lib/"
  to="\$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.$agent/$PI_NS/lib/"
  ADB_PI_FROM="$from" ADB_PI_TO="$to" awk '
    BEGIN { from = ENVIRON["ADB_PI_FROM"]; to = ENVIRON["ADB_PI_TO"]; n = length(from) }
    {
      out = ""
      while ((i = index($0, from)) > 0) {
        out = out substr($0, 1, i - 1) to
        $0 = substr($0, i + n)
      }
      print out $0
    }
  '
}

# --- artifact verification -------------------------------------------------------------------

# cmd_verify <tarball> <sums-file> — check <tarball> against the SHA256SUMS record naming its
# basename. The record is matched on the EXACT filename, never on position: a SHA256SUMS listing
# several assets, or listing them in another order, must not verify one file against another's
# digest.
cmd_verify() {
  [ "$#" -eq 2 ] || { _pi_err "verify: needs <tarball> <sums-file>"; return 2; }
  local tar="$1" sums="$2" base want have n
  [ -f "$tar" ]  || { _pi_err "verify: no such archive: $tar"; return 12; }
  [ -f "$sums" ] || { _pi_err "verify: no such checksum file: $sums"; return 12; }
  base="${tar##*/}"
  n="$(ADB_PI_BASE="$base" awk '
        BEGIN { want = ENVIRON["ADB_PI_BASE"] }
        NF >= 2 { name = $2; sub(/^\*/, "", name); if (name == want) c++ }
        END { print c + 0 }' "$sums")" || { _pi_err "verify: could not read $sums"; return 12; }
  case "$n" in
    0) _pi_err "verify: $sums has no record for $base — refusing to unpack an unchecksummed archive"; return 10 ;;
    1) ;;
    *) _pi_err "verify: $sums has $n records for $base — ambiguous, refusing"; return 10 ;;
  esac
  want="$(ADB_PI_BASE="$base" awk '
        BEGIN { want = ENVIRON["ADB_PI_BASE"] }
        NF >= 2 { name = $2; sub(/^\*/, "", name); if (name == want) { print tolower($1); exit } }' "$sums")"
  case "$want" in
    ''|*[!0-9a-f]*) _pi_err "verify: the record for $base does not carry a hex digest"; return 10 ;;
  esac
  [ "${#want}" -eq 64 ] || { _pi_err "verify: the record for $base is not a 64-character SHA-256"; return 10; }
  have="$(_pi_sha256 "$tar")" || return 12
  if [ "$have" != "$want" ]; then
    _pi_err "verify: DIGEST MISMATCH for $base"
    _pi_err "  expected $want"
    _pi_err "  actual   $have"
    return 11
  fi
  _pi_say "verified $base (sha256:$have)"
  return 0
}

# _pi_tar_is_safe <tarball> — refuse an archive whose members could escape the extraction
# directory or write through a link.
#
# THE LISTING IS CAPTURED AND ITS STATUS CHECKED, never piped straight into a filter: a pipeline
# reports only its LAST command's status, so a `tar -tzf` that emitted some clean names and then
# FAILED would reach the filter as a short but valid list and the guard would declare the archive
# safe. `-v`, because a member name can be perfectly innocent while the member is a SYMLINK
# pointing at an absolute host path — staging's `cp` would then copy the host's file into the
# project. Links are refused outright; the payload needs none.
_pi_tar_is_safe() {
  local tar="$1" names bad
  # NAMES ONLY, AND FROM `-tzf`. `tar -tv` column positions are NOT portable — BSD and GNU render
  # the date differently, so a field-offset rule that extracts the name on one platform extracts a
  # timestamp on the other and the guard silently inspects the wrong string. `-tzf` gives one name
  # per line on both. LINK TARGETS ARE NOT CHECKED HERE: they cannot be read without parsing that
  # same unportable output, and `_pi_links_are_safe` answers the question exactly, after extraction
  # into a throwaway directory, by resolving them.
  names="$(tar -tzf "$tar" 2>/dev/null)" || { _pi_err "could not list the archive's members: $tar"; return 1; }
  [ -n "$names" ] || { _pi_err "the archive lists no members: $tar"; return 1; }
  bad="$(printf '%s\n' "$names" | awk '
      /^\// { print "absolute member: " $0; next }
      /(^|\/)\.\.(\/|$)/ { print "parent-relative member: " $0 }
    ' | head -5)"
  if [ -n "$bad" ]; then
    _pi_err "the archive carries absolute or parent-relative members — refusing to unpack:"
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

# _pi_links_are_safe <unpacked-root> — no symlink in the unpacked tree may resolve outside it.
#
# A MEMBER NAME CAN BE PERFECTLY INNOCENT WHILE THE MEMBER IS A SYMLINK to an absolute host path,
# and staging copies with `cp`, which FOLLOWS one — so that link is how a host file gets copied
# into somebody's project. Refusing links outright is not an option: this framework ships a
# legitimate one (`agents/claude/scripts/lib` -> `../../../scripts/lib`, the compat shim
# docs/installation.md describes), so the rule has to be about where a link RESOLVES, not that it
# exists. Checked after extraction because that is the only portable way to read a target.
_pi_links_are_safe() {
  local root="$1" real l target rc=0
  real="$(cd "$root" && pwd -P)" || return 1
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    target="$(cd "$(dirname "$l")" 2>/dev/null && cd -P "$(readlink "$l")" 2>/dev/null && pwd -P)" || target=""
    if [ -z "$target" ]; then
      # Not a directory target (a file link) or dangling: resolve its PARENT instead, which is
      # what decides whether writing through it escapes.
      target="$(cd "$(dirname "$l")" 2>/dev/null && cd -P "$(dirname "$(readlink "$l")")" 2>/dev/null && pwd -P)" || target=""
    fi
    if [ -z "$target" ]; then
      _pi_err "the unpacked tree has a symlink whose target cannot be resolved: ${l#"$root"/} -> $(readlink "$l")"
      rc=1; continue
    fi
    case "$target/" in
      "$real"/*) ;;
      *) _pi_err "the unpacked tree has a symlink resolving OUTSIDE it: ${l#"$root"/} -> $(readlink "$l")"; rc=1 ;;
    esac
  done <<EOF
$(find "$root" -type l 2>/dev/null | LC_ALL=C sort)
EOF
  return "$rc"
}

# _pi_artifact_version <tarball> — print the version its name declares, or fail.
_pi_artifact_version() {
  local base="${1##*/}" v
  case "$base" in
    ai-dev-baseline-*.tar.gz) ;;
    *) _pi_err "not a baseline release archive: $base (expected ai-dev-baseline-<version>.tar.gz)"; return 1 ;;
  esac
  v="${base#ai-dev-baseline-}"; v="${v%.tar.gz}"
  # A DOTTED NUMERIC VERSION, checked as a grammar rather than as a character class: `2..0`, `.1`
  # and `2.` all pass a bare `*[!0-9.]*` test and then compare as something nobody meant.
  case "$v" in
    ''|.*|*.|*..*) _pi_err "the archive name does not carry a dotted numeric version: $base"; return 1 ;;
    *[!0-9.]*)     _pi_err "the archive name does not carry a dotted numeric version: $base"; return 1 ;;
  esac
  printf '%s' "$v"
}

# _pi_probe_tree <root> <agent>… — assert an unpacked tree actually carries the payload this
# installer copies. A valid checksum proves the bytes arrived intact; it says nothing about the
# tree being a baseline of a shape this code understands.
#
# THE REAL FLOOR LIVES HERE, not in the version number. A release published before this feature
# existed carries no `scripts/lib/pinned-install.sh`, so a project installed from it could never
# run the status/upgrade/uninstall path the docs promise — and that is the fact worth refusing on,
# rather than a constant somebody has to remember to bump.
_pi_probe_tree() {
  local root="$1"; shift
  local agent rc=0
  [ -d "$root/scripts/lib" ] || { _pi_err "the unpacked tree has no scripts/lib — not a usable payload"; rc=1; }
  [ -f "$root/scripts/lib/common.sh" ] || { _pi_err "the unpacked tree has no scripts/lib/common.sh"; rc=1; }
  [ -f "$root/scripts/lib/pinned-install.sh" ] || {
    _pi_err "the unpacked tree has no scripts/lib/pinned-install.sh — this release predates the pinned"
    _pi_err "  install, so the project could never run 'status', 'upgrade' or 'uninstall' from it"
    rc=1
  }
  for agent in "$@"; do
    case "$agent" in
      claude)
        [ -f "$root/agents/claude/CLAUDE.md" ] || { _pi_err "the unpacked tree has no agents/claude/CLAUDE.md"; rc=1; }
        [ -d "$root/agents/claude/skills" ]    || { _pi_err "the unpacked tree has no agents/claude/skills"; rc=1; }
        [ -f "$root/agents/claude/settings.hooks.json" ] || { _pi_err "the unpacked tree has no agents/claude/settings.hooks.json"; rc=1; } ;;
      codex)
        [ -f "$root/agents/codex/AGENTS.md" ]  || { _pi_err "the unpacked tree has no agents/codex/AGENTS.md"; rc=1; }
        [ -d "$root/agents/codex/skills" ]     || { _pi_err "the unpacked tree has no agents/codex/skills"; rc=1; } ;;
    esac
  done
  return "$rc"
}

# --- the pin ----------------------------------------------------------------------------------

_pi_pin_path() { printf '%s/.ai-dev-baseline/upstream.toml' "$1"; }
_pi_receipt_path() { printf '%s/.ai-dev-baseline/pinned-files.sha256' "$1"; }

# _pi_pin_mode <project-root> — print the recorded install mode, or nothing.
#
# ABSENT MEANS GLOBAL, not "pinned". `/adopt` already writes this pin for projects running the
# global symlink model (D60), so presence of the file is not the discriminator — the `mode` key is,
# and a pin written before this key existed is a global-mode pin by construction.
_pi_pin_mode() {
  local f; f="$(_pi_pin_path "$1")"
  [ -f "$f" ] || return 0
  adb_toml_unquote "$(adb_toml_get "$f" upstream mode 2>/dev/null)" 2>/dev/null
}

_pi_pin_get() {
  local f; f="$(_pi_pin_path "$1")"
  [ -f "$f" ] || return 1
  adb_toml_unquote "$(adb_toml_get "$f" upstream "$2" 2>/dev/null)" 2>/dev/null
}

# _pi_pin_source <project-root> — the release repository this project was installed from.
#
# THE PIN WINS OVER THE ENVIRONMENT. A project installed from a private fork must not have `status`
# or `upgrade` quietly consult the public default because the operator's shell no longer carries
# ADB_PINNED_REPO — that reads a different repository's releases and would rewrite the pin to it.
_pi_pin_source() {
  local s; s="$(_pi_pin_get "$1" source 2>/dev/null)" || s=""
  if [ -n "$s" ]; then printf '%s' "$s"; else printf '%s' "$PI_DEFAULT_REPO"; fi
}

# _pi_pin_agents <project-root> — the recorded agent set, one token per line.
_pi_pin_agents() {
  adb_toml_array "$(adb_toml_get "$(_pi_pin_path "$1")" upstream agents 2>/dev/null)" 2>/dev/null
}

# _pi_write_pin <project-root> <version> <source> <agents-csv> <adopted> <artifact-sha256> [stack]
#
# It EXTENDS the schema D60 fixed rather than replacing it: `version`, `adopted`, `stack` and
# `agents` keep their meanings; `mode`, `source` and `artifact` are what this model adds. `commit`
# is absent because a pinned project has no clone in which one could be resolved — `artifact` is
# the equivalent that IS resolvable here, and it is what makes "the same version means the same
# bytes" checkable rather than assumed.
_pi_write_pin() {
  local p="$1" version="$2" src="$3" agents="$4" adopted="$5" artifact="$6" stack="${7:-}"
  local f tmp out="" a
  case "$version" in *[!A-Za-z0-9._+-]*) _pi_err "refusing to write a pin for an unrepresentable version"; return 1 ;; esac
  case "$src" in *[!A-Za-z0-9._/-]*) _pi_err "refusing to write a pin for an unrepresentable source repo"; return 1 ;; esac
  case "$artifact" in ''|*[!0-9a-f]*) _pi_err "refusing to write a pin without a hex artifact digest"; return 1 ;; esac
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) _pi_err "refusing to write a pin with a malformed adoption date: $adopted"; return 1 ;;
  esac
  case "$stack" in *[!a-z0-9-]*) _pi_err "refusing to write a pin with an unrepresentable stack label"; return 1 ;; esac
  for a in ${agents//,/ }; do
    case "$a" in *[!a-z0-9-]*) _pi_err "refusing to write a pin for an unrepresentable agent token"; return 1 ;; esac
    [ -z "$out" ] || out="$out, "
    out="$out\"$a\""
  done
  f="$(_pi_pin_path "$p")"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.adb.$$.tmp"
  {
    cat <<TOML
# ai-dev-baseline — upstream pin. Written by pinned-install.sh; safe to read, safe to commit.
#
# \`mode = "pinned"\` means this project carries a VENDORED payload of the released baseline named
# by \`version\`, rather than inheriting a machine's global symlink install. A pin without this key
# is a global-mode pin written by /adopt, and nothing here owns it.
#
# \`artifact\` is the SHA-256 of the release archive this payload came from. A pinned project has no
# clone, so there is no commit to resolve; this is what makes "the same version is the same bytes"
# a checkable claim rather than an assumption.
#
# See: pinned-install.sh status

[upstream]
mode     = "pinned"
version  = "$version"
source   = "$src"
artifact = "$artifact"
adopted  = "$adopted"
TOML
    [ -n "$stack" ] && printf 'stack    = "%s"\n' "$stack"
    printf 'agents   = [%s]\n' "$out"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# --- managed regions in files the PROJECT owns -------------------------------------------------

# _pi_block_state <file> — `absent` · `balanced` · `unbalanced`.
#
# UNBALANCED IS REFUSED EVERYWHERE, and this predicate is why it can be. A begin marker with no end
# marker made both the splice and the strip delete everything from that marker to EOF — a project's
# own prose, destroyed by an installer, with no way back. A stray end with no begin is the same
# class.
_pi_block_state() {
  local f="$1" b e
  [ -f "$f" ] || { printf 'absent'; return 0; }
  b="$(ADB_PI_B="$PI_BEGIN" awk 'BEGIN{m=ENVIRON["ADB_PI_B"]} $0==m{c++} END{print c+0}' "$f")"
  e="$(ADB_PI_E="$PI_END" awk 'BEGIN{m=ENVIRON["ADB_PI_E"]} $0==m{c++} END{print c+0}' "$f")"
  if [ "$b" -eq 0 ] && [ "$e" -eq 0 ]; then printf 'absent'; return 0; fi
  if [ "$b" -eq 1 ] && [ "$e" -eq 1 ]; then printf 'balanced'; return 0; fi
  printf 'unbalanced'
}

# _pi_splice_block <file> <content-file> — put the managed region into <file>, creating it if
# absent, replacing an existing region IN PLACE, and appending otherwise.
#
# IN PLACE, NOT AT EOF. Strip-then-append moved the block past any prose the project had added
# after it, which reverses instruction order for the reader and breaks byte idempotence on a
# re-install. The replacement keeps the block exactly where the project put it.
_pi_splice_block() {
  local f="$1" body="$2" tmp="$1.adb.$$.tmp" state
  state="$(_pi_block_state "$f")"
  if [ "$state" = unbalanced ]; then
    _pi_err "$f carries an unbalanced ai-dev-baseline managed region — refusing to touch it"
    _pi_err "  repair the begin/end markers by hand; editing it here could delete your own prose"
    return 1
  fi
  mkdir -p "$(dirname "$f")" || return 1
  if [ "$state" = balanced ]; then
    ADB_PI_B="$PI_BEGIN" ADB_PI_E="$PI_END" ADB_PI_BODY="$body" awk '
      BEGIN { b = ENVIRON["ADB_PI_B"]; e = ENVIRON["ADB_PI_E"]; body = ENVIRON["ADB_PI_BODY"] }
      $0 == b { print b; while ((getline line < body) > 0) print line; close(body); print e; skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    {
      [ -f "$f" ] && cat "$f"
      printf '%s\n' "$PI_BEGIN"
      cat "$body"
      printf '%s\n' "$PI_END"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# _pi_strip_block <file> — remove the managed region, and remove the file entirely if that is all
# it ever held. A file carrying the project's own prose keeps it. Refuses an unbalanced region for
# the same reason the splice does.
_pi_strip_block() {
  local f="$1" tmp="$1.adb.$$.tmp" state
  state="$(_pi_block_state "$f")"
  [ "$state" = absent ] && return 0
  if [ "$state" = unbalanced ]; then
    _pi_err "$f carries an unbalanced ai-dev-baseline managed region — refusing to edit it"
    return 1
  fi
  ADB_PI_B="$PI_BEGIN" ADB_PI_E="$PI_END" awk '
    BEGIN { b = ENVIRON["ADB_PI_B"]; e = ENVIRON["ADB_PI_E"] }
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -s "$tmp" ] && grep -q '[^[:space:]]' "$tmp"; then
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp" "$f"
  fi
}

# _pi_hook_groups <artifact-root> — the project's hook wiring, DERIVED from the same
# `settings.hooks.json` the global installer merges, so a newly shipped hook is wired here too
# instead of being silently omitted by a hardcoded list. Two substitutions: the home placeholder
# becomes `${CLAUDE_PROJECT_DIR}` (nothing machine-local may be committed) and `scripts/` becomes
# this install's namespace. Excluded hooks are dropped, and a group or event left empty goes with
# them.
_pi_hook_groups() {
  local a="$1"
  local src="$a/agents/claude/settings.hooks.json"
  [ -f "$src" ] || { _pi_err "the artifact has no agents/claude/settings.hooks.json"; return 1; }
  jq --arg ns "$PI_NS" --arg excl "$PI_HOOKS_EXCLUDED" '
      ( $excl | split(" ") ) as $drop
      | with_entries(
          .value |= ( map(
              .hooks |= map(select(((.command // "") | split("/") | last) as $b | ($drop | index($b)) | not))
              | .hooks |= map(.command |= sub("^__ADB_HOME__/\\.claude/scripts/"; "${CLAUDE_PROJECT_DIR}/.claude/" + $ns + "/"))
            ) | map(select((.hooks | length) > 0)) )
        )
      | with_entries(select((.value | length) > 0))
    ' "$src" || { _pi_err "could not derive the project hook wiring from $src"; return 1; }
}

# _pi_hook_regex — the ownership test for our entries in a project's settings.json.
_pi_hook_regex() { printf '\\$\\{CLAUDE_PROJECT_DIR\\}/\\.claude/%s/' "$PI_NS"; }

# _pi_wire_hooks <artifact-root> <project-root> — merge the Stop gates into the project's
# .claude/settings.json. Same ownership shape as install.sh's global wiring: drop any group
# referencing one of OUR commands, then append ours, so a re-run replaces rather than doubles and
# a user's own groups survive.
#
# Prints `1` on stdout when it had to CREATE settings.json, so the caller can record that in the
# receipt — uninstall must not delete a file it cannot prove it made.
_pi_wire_hooks() {
  local a="$1" p="$2"
  local settings="$p/.claude/settings.json"
  local tmp groups re created=0
  groups="$(_pi_hook_groups "$a")" || return 1
  { [ -n "$groups" ] && [ "$groups" != '{}' ]; } || { _pi_err "the derived hook wiring is empty — refusing to report gates wired"; return 1; }
  re="$(_pi_hook_regex)"
  mkdir -p "$p/.claude" || return 1
  # `-s`, not `-f`: jq reads an EMPTY file as an empty stream and exits 0 printing nothing, which
  # would install a 0-byte settings.json while reporting success.
  if [ ! -s "$settings" ]; then
    [ -e "$settings" ] || created=1
    echo '{}' > "$settings" || return 1
  fi
  tmp="$settings.adb.$$.tmp"
  if ! jq --argjson groups "$groups" --arg re "$re" '
        .hooks = (.hooks // {})
        | reduce ($groups | to_entries[]) as $e (.;
            .hooks[$e.key] = (((.hooks[$e.key] // [])
              | map(select(([.hooks[]?.command // ""] | any(test($re))) | not)))
              + $e.value))
      ' "$settings" > "$tmp"; then
    rm -f "$tmp"
    _pi_err "$settings is not valid JSON — Stop gates NOT wired"
    return 1
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; _pi_err "hook wiring produced an empty settings.json — NOT wired"; return 1; }
  mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
  printf '%s' "$created"
}

# _pi_unwire_hooks <project-root> — the mirror. Same ownership regex, every event, and an event key
# is dropped only once it is empty. Non-zero when the entries could not be removed, which the
# caller MUST honour: deleting the gate scripts while settings.json still points at them leaves a
# broken hook firing on every later session.
_pi_unwire_hooks() {
  local p="$1"
  local settings="$p/.claude/settings.json"
  local re tmp
  [ -s "$settings" ] || return 0
  grep -Fq "/.claude/$PI_NS/" "$settings" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || { _pi_err "jq is required to remove this install's hook entries from .claude/settings.json"; return 1; }
  re="$(_pi_hook_regex)"
  tmp="$settings.adb.$$.tmp"
  if jq --arg re "$re" '
        if (.hooks | type) == "object" then
          .hooks |= with_entries(
            if (.value | type) == "array"
            then .value |= map(select(([.hooks[]?.command // ""] | any(test($re))) | not))
            else . end
            | select((.value | type) != "array" or (.value | length) > 0))
        else . end
      ' "$settings" > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
    _pi_say "  hooks  removed project Stop gates from .claude/settings.json"
    return 0
  fi
  rm -f "$tmp"
  _pi_err "could not rewrite .claude/settings.json — hook entries NOT removed"
  return 1
}

# --- fetch ------------------------------------------------------------------------------------

# _pi_fetch <version> <dest-dir> <source-repo> — put the tarball and SHA256SUMS in <dest-dir> and
# print the tarball's path. `gh` first because it carries the operator's auth (a private fork
# resolves), curl as the fallback so a machine with no clone and no gh can still install. Both are
# time-bounded: an install that hangs forever on a stalled transfer is its own failure mode.
_pi_fetch() {
  local v="$1" dir="$2" repo="$3"
  local tag="v${v#v}" base="ai-dev-baseline-${v#v}.tar.gz" url
  if command -v gh >/dev/null 2>&1 \
     && gh release download "$tag" -R "$repo" -D "$dir" -p "$base" -p SHA256SUMS >/dev/null 2>&1; then
    :
  elif command -v curl >/dev/null 2>&1; then
    url="https://github.com/$repo/releases/download/$tag"
    curl -fsSL --max-time 600 -o "$dir/$base" "$url/$base" || { _pi_err "could not download $base from $url"; return 1; }
    curl -fsSL --max-time 120 -o "$dir/SHA256SUMS" "$url/SHA256SUMS" || { _pi_err "could not download SHA256SUMS from $url"; return 1; }
  else
    _pi_err "neither gh nor curl is available — cannot fetch the release artifact"
    return 1
  fi
  { [ -f "$dir/$base" ] && [ -f "$dir/SHA256SUMS" ]; } || { _pi_err "the download did not produce both assets"; return 1; }
  printf '%s' "$dir/$base"
}

# _pi_latest_version <source-repo> — the newest published release's bare version, or fail.
_pi_latest_version() {
  command -v gh >/dev/null 2>&1 || return 1
  local t
  t="$(gh release list -R "$1" --limit 1 --json tagName,isDraft \
        --jq 'map(select(.isDraft | not)) | .[0].tagName' 2>/dev/null)" || return 1
  { [ -n "$t" ] && [ "$t" != null ]; } || return 1
  printf '%s' "${t#v}"
}

# --- receipt ------------------------------------------------------------------------------------

# _pi_receipt_paths <receipt> — the path column of every record, one per line. A record whose path
# is unsafe is DROPPED and reported: the receipt is committed, so on any repository a stranger can
# send a pull request to it is attacker-influenced text.
_pi_receipt_paths() {
  local f="$1" hash rel
  [ -f "$f" ] || return 0
  while read -r hash rel; do
    case "$hash" in ''|'#'*) continue ;; esac
    [ -n "$rel" ] || continue
    if ! _pi_relpath_safe "$rel"; then
      _pi_err "receipt: ignoring an unsafe path: $(adb_tsv_field_display "$rel")"
      continue
    fi
    printf '%s\n' "$rel"
  done < "$f"
}

# _pi_receipt_digest <receipt> <path> — the digest recorded for one path, or nothing.
_pi_receipt_digest() { awk -v r="$2" '$1 !~ /^#/ && $2 == r { print $1; exit }' "$1" 2>/dev/null; }

# _pi_receipt_flag <receipt> <line> — true when the receipt carries that exact marker comment.
# `# created: <path>` is how the install remembers it made a merged surface, so uninstall can
# remove one it made and must leave one it did not.
_pi_receipt_flag() {
  [ -f "$1" ] || return 1
  grep -Fqx "$2" "$1"
}

# _pi_verify_tree <project-root> <receipt> — print `<missing> <altered> <records>`.
_pi_verify_tree() {
  local p="$1" f="$2" hash rel have missing=0 altered=0 n=0
  while read -r hash rel; do
    case "$hash" in ''|'#'*) continue ;; esac
    [ -n "$rel" ] || continue
    n=$((n + 1))
    if ! _pi_relpath_safe "$rel"; then altered=$((altered + 1)); continue; fi
    if [ ! -f "$p/$rel" ]; then missing=$((missing + 1)); continue; fi
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    [ "$have" = "$hash" ] || altered=$((altered + 1))
  done < "$f"
  printf '%s %s %s' "$missing" "$altered" "$n"
}

# _pi_check_surfaces <project-root> <agents-csv> <receipt> — report the MERGED surfaces, which the
# receipt cannot cover because they are regions inside files the project owns. Prints one line per
# problem; silent when both are intact. Non-zero iff something is wrong.
_pi_check_surfaces() {
  local p="$1" agents="$2" rp="$3" rc=0
  case ",$agents," in
    *,codex,*)
      case "$(_pi_block_state "$p/AGENTS.md")" in
        balanced) ;;
        absent)     _pi_say "  missing  AGENTS.md managed region (Codex would load none of the practices)"; rc=1 ;;
        unbalanced) _pi_say "  broken   AGENTS.md managed region (unbalanced markers)"; rc=1 ;;
      esac ;;
  esac
  case ",$agents," in
    *,claude,*)
      if _pi_receipt_flag "$rp" "# unwired: .claude/settings.json"; then
        _pi_say "  missing  Stop-gate wiring (this install ran without jq)"; rc=1
      elif ! grep -Fq "/.claude/$PI_NS/" "$p/.claude/settings.json" 2>/dev/null; then
        _pi_say "  missing  Stop-gate entries in .claude/settings.json"; rc=1
      fi ;;
  esac
  return "$rc"
}

# --- install ------------------------------------------------------------------------------------

# _pi_stage <artifact-root> <project-root> <staging-root> <agent>… — build the COMPLETE payload
# under <staging-root>, mirroring each destination's path relative to <project-root>. Nothing is
# written into the project until every file has been produced and re-anchored, so a failure here
# leaves the project exactly as it was.
_pi_stage() {
  local a="$1" p="$2" stage="$3"; shift 3
  local agent src dest rel manifest
  for agent in "$@"; do
    manifest="$(cmd_payload "$agent" "$a" "$p")" || return 1
    [ -n "$manifest" ] || { _pi_err "the payload map for '$agent' is empty — refusing to install nothing"; return 1; }
    while IFS="$(printf '\t')" read -r src dest; do
      { [ -n "$src" ] && [ -n "$dest" ]; } || continue
      rel="${dest#"$p"/}"
      _pi_relpath_safe "$rel" || { _pi_err "stage: the payload map produced an unsafe destination: $(adb_tsv_field_display "$rel")"; return 1; }
      mkdir -p "$stage/$(dirname "$rel")" || return 1
      case "$dest" in
        */skills/*/SKILL.md)
          cmd_reanchor "$agent" "$p" < "$src" > "$stage/$rel" || return 1 ;;
        *)
          cp "$src" "$stage/$rel" || return 1 ;;
      esac
      case "$dest" in *.sh) chmod +x "$stage/$rel" || return 1 ;; esac
    done <<EOF
$manifest
EOF
  done
  return 0
}

# _pi_assert_reanchored <staging-root> <agent>… — no staged skill may still reach the user-global
# library directory. The re-anchor's failure mode is silence: a substitution that matched nothing
# produces a file that looks correct and quietly runs the OTHER install's libraries.
#
# BOTH SPELLINGS. `build.sh` renders `$HOME/…` today; a future `${HOME}/…` would make the transform
# match zero occurrences AND make a one-spelling assertion pass over a payload that was never
# re-anchored at all.
_pi_assert_reanchored() {
  local stage="$1"; shift
  local agent hits rc=0
  for agent in "$@"; do
    [ -d "$stage/.$agent/skills" ] || continue
    hits="$(grep -rlE -- "\\\$(HOME|\\{HOME\\})/\\.$agent/scripts/lib/" "$stage/.$agent/skills" 2>/dev/null)" || true
    if [ -n "$hits" ]; then
      _pi_err "staged $agent skills still reach the user-global library — the re-anchor did not take:"
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      rc=1
    fi
  done
  return "$rc"
}

# _pi_publish <staging-root> <project-root> <prior-receipt> <backup-dir> <receipt-out>
#
# Copy the staged tree into the project, writing the receipt to <receipt-out> as it goes.
# Publishing is per-file and by RENAME, so no destination is ever observable half-written (D52).
#
# THE RECEIPT IS WRITTEN INCREMENTALLY, AND ON FAILURE IT IS KEPT. Publishing many files is not one
# atomic act, so an interrupted run leaves a partly-populated project; what makes that recoverable
# rather than permanent is that the receipt always describes exactly what was written, so
# `uninstall` can always take it back out. A run that fails and leaves no receipt is the
# unrecoverable shape, and that is the one this ordering removes.
#
# A PRE-EXISTING DESTINATION THIS INSTALL DOES NOT ALREADY OWN IS BACKED UP FIRST.
# `.claude/skills/<name>/SKILL.md` is where a project may legitimately keep a hand-authored fork or
# a `skill-compose` output (docs/per-project-overrides.md, Override 2), and a first install would
# otherwise replace it with no warning. `adb_link` has exactly this contract for the global model;
# the backup goes OUTSIDE the project, because a copy dropped inside it is one `git add -A` from
# being committed. "Already own" comes from the PRIOR receipt, so a re-install overwrites its own
# previous output silently while never touching a file it did not write.
_pi_publish() {
  local stage="$1" p="$2" prior="$3" backup="$4" out="$5"
  local f rel digest listing n=0 owned="" bdest
  listing="$(cd "$stage" && find . -type f | LC_ALL=C sort)" || {
    _pi_err "publish: could not enumerate the staged payload"
    return 1
  }
  [ -n "$listing" ] || { _pi_err "publish: the staged payload is empty — refusing to publish nothing"; return 1; }
  owned="$(_pi_receipt_paths "$prior" 2>/dev/null)" || owned=""
  mkdir -p "$(dirname "$out")" || return 1
  printf '# ai-dev-baseline — files written by pinned-install.sh. Do not edit.\n' > "$out" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#./}"
    _pi_relpath_safe "$rel" || { _pi_err "publish: refusing an unrepresentable payload path: $(adb_tsv_field_display "$rel")"; return 1; }
    mkdir -p "$p/$(dirname "$rel")" || return 1
    if [ -e "$p/$rel" ] && ! _pi_owns "$owned" "$rel"; then
      bdest="$backup/$rel"
      mkdir -p "$(dirname "$bdest")" || return 1
      cp -R "$p/$rel" "$bdest" || { _pi_err "publish: could not back up the existing $rel — refusing to replace it"; return 1; }
      printf '  backup %s → %s/%s\n' "$rel" "${backup/#$HOME/~}" "$rel" >&2
    fi
    cp "$stage/$rel" "$p/$rel.adb.$$.tmp" || return 1
    if [ -x "$stage/$rel" ]; then chmod +x "$p/$rel.adb.$$.tmp" || return 1; fi
    mv "$p/$rel.adb.$$.tmp" "$p/$rel" || { rm -f "$p/$rel.adb.$$.tmp"; return 1; }
    digest="$(_pi_sha256 "$p/$rel")" || return 1
    printf '%s  %s\n' "$digest" "$rel" >> "$out" || return 1
    n=$((n + 1))
  done <<EOF
$listing
EOF
  [ "$n" -gt 0 ] || { _pi_err "publish: published no files"; return 1; }
  return 0
}

# _pi_retire <project-root> <prior-paths> <new-receipt> <prior-receipt> — remove what the PREVIOUS
# payload owned and this one does not.
#
# Without this, an upgrade that drops a file — or a re-install with a smaller agent set — leaves
# the old copy behind owned by nobody: the new receipt does not list it, so `uninstall` will not
# remove it and `status` will not report it. Removal is by digest against the OLD receipt, so a
# file the operator edited is kept and named rather than deleted.
_pi_retire() {
  local p="$1" prior_paths="$2" new="$3" old="$4"
  local rel have want kept=0 gone=0 keepset
  [ -n "$prior_paths" ] || return 0
  keepset="$(_pi_receipt_paths "$new" 2>/dev/null)" || keepset=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # THE PIN IS NEVER RETIRED. It is appended to the new receipt only after this runs, so it is
    # in `prior_paths` and not yet in `keepset` — and retiring it DELETES the file the very next
    # step reads `adopted` and `stack` back out of, silently resetting both on every re-install.
    [ "$rel" = ".ai-dev-baseline/upstream.toml" ] && continue
    _pi_owns "$keepset" "$rel" && continue
    [ -f "$p/$rel" ] || continue
    want="$(_pi_receipt_digest "$old" "$rel")"
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    if [ -n "$want" ] && [ "$have" = "$want" ]; then
      rm -f "$p/$rel" && gone=$((gone + 1))
    else
      kept=$((kept + 1)); _pi_say "  kept   $rel (retired by this version, but locally modified)"
    fi
  done <<EOF
$prior_paths
EOF
  [ "$gone" -eq 0 ] || _pi_say "  retire $gone file(s) this version no longer ships"
  return 0
}

cmd_install() {
  local p="" version="" artifact="" sums="" upgrade=0
  local -a agents=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)      _pi_need_val "$1" "$#" || return 2; p="$2"; shift 2 ;;
      --agent)        _pi_need_val "$1" "$#" || return 2; agents+=("$2"); shift 2 ;;
      --version|--to) _pi_need_val "$1" "$#" || return 2; version="$2"; shift 2 ;;
      --artifact)     _pi_need_val "$1" "$#" || return 2; artifact="$2"; shift 2 ;;
      --sums)         _pi_need_val "$1" "$#" || return 2; sums="$2"; shift 2 ;;
      --upgrade)      upgrade=1; shift ;;
      *) _pi_err "install: unknown option: $1"; return 2 ;;
    esac
  done

  # `--upgrade` IS NOT A PUBLIC BYPASS. It exists so `upgrade` can reuse this code path, and it
  # carries the same requirement: the operator names the version. Without this, `install --upgrade`
  # skipped the different-version refusal entirely and no approval was expressed anywhere.
  if [ "$upgrade" -eq 1 ] && [ -z "$version" ]; then
    _pi_err "install: --upgrade requires the version to be named (--to X.Y.Z) — use 'upgrade --to'"
    return 2
  fi

  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "install: --project not given and the current directory is not in a git repository"; return 2; }
  [ -d "$p" ] || { _pi_err "install: no such project directory: $p"; return 2; }
  p="$(cd "$p" && pwd)"
  # THE PROJECT MUST BE THE REPOSITORY ROOT. The vendored skills resolve their libraries through
  # `git rev-parse --show-toplevel`, so a payload installed into a SUBDIRECTORY is unreachable from
  # the very commands it exists to serve — an install that succeeds and produces a runtime nothing
  # can find.
  local top
  top="$(cd "$p" && git rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || { _pi_err "install: $p is not inside a git repository — a pinned payload is committed with the project"; return 2; }
  # `-ef` (same device+inode), NOT string equality. `git rev-parse` answers with the PHYSICAL path,
  # so on macOS a perfectly ordinary project under /var — where /var is a symlink to /private/var —
  # compares unequal to itself and every install is refused. `bin/baseline`'s wrong-clone guard
  # learned this first and for the same reason.
  if ! [ "$top" -ef "$p" ]; then
    _pi_err "install: --project must be the repository ROOT, not a subdirectory."
    _pi_err "         given: $p"
    _pi_err "         root:  $top"
    _pi_err "         The vendored skills resolve their libraries from the git toplevel, so a payload"
    _pi_err "         installed below it could never be found."
    return 2
  fi

  [ "${#agents[@]}" -gt 0 ] || agents=(claude)
  local agent
  for agent in "${agents[@]}"; do
    case "$agent" in
      claude|codex) ;;
      gemini) _pi_err "install: pinned mode does not support 'gemini' — it has no project-local skill discovery (scripts/build.sh), so a vendored payload could not be loaded"; return 2 ;;
      *) _pi_err "install: unknown agent: $agent"; return 2 ;;
    esac
  done

  if [ -n "$artifact" ]; then
    [ -n "$sums" ] || { _pi_err "install: --artifact requires --sums"; return 2; }
  else
    [ -n "$version" ] || { _pi_err "install: needs --version X.Y.Z, or --artifact FILE --sums FILE"; return 2; }
  fi

  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/adb-pinned.XXXXXX")" || { _pi_err "install: cannot create a working directory"; return 12; }
  # SINGLE-QUOTED, so `$work` is expanded when the trap FIRES. The other spelling bakes the path
  # into a quoted string, and a TMPDIR carrying a single quote then produces a trap body that is
  # either a syntax error or a different command.
  trap 'rm -rf "$work"' EXIT

  local source_repo; source_repo="$(_pi_pin_source "$p")"
  if [ -z "$artifact" ]; then
    _pi_say "fetching ai-dev-baseline ${version#v} from $source_repo …"
    artifact="$(_pi_fetch "${version#v}" "$work" "$source_repo")" || { rm -rf "$work"; trap - EXIT; return 13; }
    sums="$work/SHA256SUMS"
  fi

  local ver rc
  ver="$(_pi_artifact_version "$artifact")" || { rm -rf "$work"; trap - EXIT; return 11; }
  # THE NAMED VERSION IS CHECKED AGAINST THE ARCHIVE. Otherwise `--to 3.0.0 --artifact
  # ai-dev-baseline-2.2.0.tar.gz` installs 2.2.0 while the operator approved 3.0.0.
  if [ -n "$version" ] && [ "${version#v}" != "$ver" ]; then
    _pi_err "install: the named version ${version#v} does not match the archive, which is $ver"
    rm -rf "$work"; trap - EXIT; return 11
  fi
  if ! adb_version_ge "$ver" "$PI_MIN_VERSION"; then
    _pi_err "install: $ver is below the minimum installable baseline release ($PI_MIN_VERSION)"
    rm -rf "$work"; trap - EXIT; return 11
  fi

  # THE PIN IS CONSULTED HERE, not before the version is known — with --artifact the version is a
  # property of the archive, so an earlier check would have had to refuse on the mere EXISTENCE of
  # a pin and re-running the same version would not have been idempotent.
  local mode cur prior_stack=""
  mode="$(_pi_pin_mode "$p")"
  if [ -f "$(_pi_pin_path "$p")" ] && [ "$mode" != pinned ]; then
    # A GLOBAL-MODE PIN IS NOT CONVERTED SILENTLY. It carries /adopt's `commit` and `stack` — state
    # this installer cannot reconstruct — and D60 records that file as /adopt's. Overwriting it
    # loses that, so the operator retires it deliberately instead.
    _pi_err "install: this project already carries a GLOBAL-mode pin (.ai-dev-baseline/upstream.toml)."
    _pi_err "         It records what /adopt inherited, including a commit this installer cannot"
    _pi_err "         reconstruct. Reconcile or remove it deliberately, then re-run."
    rm -rf "$work"; trap - EXIT; return 10
  fi
  if [ "$mode" = pinned ]; then
    cur="$(_pi_pin_get "$p" version)"
    prior_stack="$(_pi_pin_get "$p" stack 2>/dev/null)" || prior_stack=""
    if [ "$cur" != "$ver" ] && [ "$upgrade" -eq 0 ]; then
      _pi_err "install: this project is already pinned to ${cur:-an unrecorded version}, not $ver."
      _pi_err "         Changing the pinned version is an upgrade; name it explicitly:"
      _pi_err "           pinned-install.sh upgrade --to $ver"
      rm -rf "$work"; trap - EXIT; return 10
    fi
  fi

  cmd_verify "$artifact" "$sums"; rc=$?
  case "$rc" in
    0) ;;
    # THE DEPENDENCY CODE SURVIVES. Collapsing 12 into 11 told an operator with no sha256 tool that
    # their download had failed verification, which sends them to re-download rather than to
    # install a tool.
    12) rm -rf "$work"; trap - EXIT; return 12 ;;
    *)  rm -rf "$work"; trap - EXIT; return 11 ;;
  esac
  local artifact_sha; artifact_sha="$(_pi_sha256 "$artifact")" || { rm -rf "$work"; trap - EXIT; return 12; }

  # THE SAME VERSION MUST MEAN THE SAME BYTES. Without this, a re-install from a different archive
  # carrying the same filename replaces the whole payload while "re-running changes nothing" still
  # claims otherwise — a pin records a version, and a version is not a content identity.
  if [ "$mode" = pinned ] && [ "$upgrade" -eq 0 ]; then
    local prior_art; prior_art="$(_pi_pin_get "$p" artifact 2>/dev/null)" || prior_art=""
    if [ -n "$prior_art" ] && [ "$prior_art" != "$artifact_sha" ]; then
      _pi_err "install: this project is pinned to $ver from a DIFFERENT archive."
      _pi_err "         pinned artifact sha256: $prior_art"
      _pi_err "         this archive:           $artifact_sha"
      _pi_err "         Same version, different bytes — resolve that deliberately rather than here."
      rm -rf "$work"; trap - EXIT; return 10
    fi
  fi

  _pi_tar_is_safe "$artifact" || { rm -rf "$work"; trap - EXIT; return 11; }

  local unpacked="$work/unpacked"
  mkdir -p "$unpacked"
  tar -xzf "$artifact" -C "$unpacked" || { _pi_err "install: could not unpack $artifact"; rm -rf "$work"; trap - EXIT; return 11; }
  local root="$unpacked/ai-dev-baseline-$ver"
  [ -d "$root" ] || { _pi_err "install: the archive does not contain ai-dev-baseline-$ver/ — refusing"; rm -rf "$work"; trap - EXIT; return 11; }
  _pi_links_are_safe "$root" || { rm -rf "$work"; trap - EXIT; return 11; }
  _pi_probe_tree "$root" "${agents[@]}" || { rm -rf "$work"; trap - EXIT; return 11; }

  # CRLF is acquired at UNPACK time as easily as at clone time, and an unpacked payload is not
  # governed by this repo's .gitattributes. The same shared scanner install.sh runs on a clone runs
  # here, on the tree that is about to be vendored.
  local crlf
  if ! crlf="$(adb_crlf_scan "$root")"; then
    _pi_err "install: CRLF line endings in the unpacked artifact:"
    printf '%s\n' "$crlf" | sed 's/^/  /' >&2
    adb_crlf_remedy
    rm -rf "$work"; trap - EXIT; return 11
  fi

  local stage="$work/stage"
  mkdir -p "$stage"
  _pi_stage "$root" "$p" "$stage" "${agents[@]}" || { _pi_err "install: could not stage the payload — nothing was written to the project"; rm -rf "$work"; trap - EXIT; return 14; }
  _pi_assert_reanchored "$stage" "${agents[@]}" || { rm -rf "$work"; trap - EXIT; return 14; }

  # READ BEFORE ANY WRITE. Both fields live in a file later steps rewrite, and reading them late
  # made their value depend on what had happened to that file in between.
  local adopted
  adopted="$(_pi_pin_get "$p" adopted 2>/dev/null)" || adopted=""
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) adopted="$(date -u +%Y-%m-%d)" ;;
  esac

  local rp; rp="$(_pi_receipt_path "$p")"
  local prior_paths; prior_paths="$(_pi_receipt_paths "$rp" 2>/dev/null)" || prior_paths=""
  local prior_copy="$work/prior-receipt"
  if [ -f "$rp" ]; then cp "$rp" "$prior_copy" || { rm -rf "$work"; trap - EXIT; return 14; }; else : > "$prior_copy"; fi

  local want rel have
  while IFS= read -r rel; do
    { [ -n "$rel" ] && [ -f "$p/$rel" ]; } || continue
    want="$(_pi_receipt_digest "$prior_copy" "$rel")"
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    [ "$have" = "$want" ] || _pi_say "  NOTE   $rel was modified locally and is being replaced"
  done <<EOF
$prior_paths
EOF

  _pi_say "installing ai-dev-baseline $ver into ${p##*/} (agents: ${agents[*]})"
  local backup; backup="$HOME/.claude/backups/ai-dev-baseline-pinned-$(date -u +%Y%m%d-%H%M%S)"
  if ! _pi_publish "$stage" "$p" "$prior_copy" "$backup" "$rp"; then
    _pi_err "install: publishing failed. The receipt at ${rp#"$p"/} lists exactly what WAS written —"
    _pi_err "         run 'pinned-install.sh uninstall' to take it back out."
    rm -rf "$work"; trap - EXIT; return 14
  fi

  _pi_retire "$p" "$prior_paths" "$rp" "$prior_copy"

  # Codex reads only the root AGENTS.md, so its practices are spliced there as a delimited region.
  local created bytes
  for agent in "${agents[@]}"; do
    [ "$agent" = codex ] || continue
    _pi_splice_block "$p/AGENTS.md" "$p/.codex/$PI_NS/AGENTS.practices.md" \
      || { _pi_err "install: could not splice the practices into AGENTS.md"; rm -rf "$work"; trap - EXIT; return 14; }
    _pi_say "  block  managed region written into AGENTS.md"
    # SILENT TRUNCATION IS THE WORST FAILURE MODE THERE IS, so it is said out loud with the fix.
    bytes="$(wc -c < "$p/AGENTS.md" | tr -d ' ')"
    if [ "$bytes" -gt "$PI_CODEX_DOC_DEFAULT_MAX" ]; then
      _pi_say ""
      _pi_say "  WARNING  AGENTS.md is now $bytes bytes, and Codex reads at most $PI_CODEX_DOC_DEFAULT_MAX by"
      _pi_say "           default (project_doc_max_bytes). It TRUNCATES SILENTLY, so much of the"
      _pi_say "           practices would never reach it. Raise the limit in ~/.codex/config.toml:"
      _pi_say ""
      _pi_say "               project_doc_max_bytes = 262144"
      _pi_say ""
    fi
  done

  for agent in "${agents[@]}"; do
    [ "$agent" = claude ] || continue
    if ! command -v jq >/dev/null 2>&1; then
      # THE ONE TOLERATED DEGRADATION, as it is globally — and it is RECORDED, so `status` reports
      # the gap rather than letting an unwired install look complete.
      _pi_say "  WARN   jq not found — project Stop gates NOT wired; install jq and re-run"
      printf '# unwired: .claude/settings.json\n' >> "$rp"
    else
      created="$(_pi_wire_hooks "$root" "$p")" || {
        _pi_err "install: the project's Stop gates could not be wired (see above)"
        rm -rf "$work"; trap - EXIT; return 14
      }
      _pi_say "  hooks  wired project Stop gates into .claude/settings.json"
      # RECORDED, because uninstall must not delete a settings.json it cannot prove it created —
      # and CARRIED FORWARD from the prior receipt, because only the FIRST install creates it. A
      # re-run that dropped the marker would both break byte idempotence and quietly hand the file
      # back to the project, leaving an orphan behind at uninstall.
      if [ "$created" = 1 ] || _pi_receipt_flag "$prior_copy" "# created: .claude/settings.json"; then
        printf '# created: .claude/settings.json\n' >> "$rp"
      fi
    fi
  done

  # `adopted` RECORDS THE FIRST ADOPTION and is carried forward, never restamped: rewriting it
  # would make "re-running changes nothing" false on any day but the first, and would make the
  # field mean "last install" while its name says otherwise. Resolved above, before any write.
  local csv
  csv="$(IFS=,; printf '%s' "${agents[*]}")"
  _pi_write_pin "$p" "$ver" "$source_repo" "$csv" "$adopted" "$artifact_sha" "$prior_stack" \
    || { _pi_err "install: could not write the pin"; rm -rf "$work"; trap - EXIT; return 14; }
  printf '%s  %s\n' "$(_pi_sha256 "$(_pi_pin_path "$p")")" ".ai-dev-baseline/upstream.toml" >> "$rp" \
    || { _pi_err "install: could not finish the receipt"; rm -rf "$work"; trap - EXIT; return 14; }

  _pi_say "pinned to $ver — commit .ai-dev-baseline/ and the vendored .<agent>/ payload"
  rm -rf "$work"; trap - EXIT
  return 0
}

cmd_upgrade() {
  local p="" to="" artifact="" sums=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to)       _pi_need_val "$1" "$#" || return 2; to="$2"; shift 2 ;;
      --project)  _pi_need_val "$1" "$#" || return 2; p="$2"; shift 2 ;;
      --artifact) _pi_need_val "$1" "$#" || return 2; artifact="$2"; shift 2 ;;
      --sums)     _pi_need_val "$1" "$#" || return 2; sums="$2"; shift 2 ;;
      *) _pi_err "upgrade: unknown option: $1"; return 2 ;;
    esac
  done
  # NO DEFAULT AND NO PROMPT. `--to` is how approval is expressed: the operator names the version.
  # Two automatic triggers already invoke `baseline update` (the SessionStart hook and /cleanup),
  # so a command that could upgrade without an explicit version would upgrade unattended.
  [ -n "$to" ] || { _pi_err "upgrade: needs --to X.Y.Z — nothing here upgrades to a version the operator did not name"; return 2; }
  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "upgrade: --project not given and the current directory is not in a git repository"; return 2; }
  p="$(cd "$p" && pwd)"
  [ "$(_pi_pin_mode "$p")" = pinned ] || { _pi_err "upgrade: this project is not pinned — use 'install' first"; return 10; }

  # The agent set is READ BACK FROM THE PIN, never re-defaulted: an upgrade that silently dropped
  # an agent would leave that agent's vendored payload behind.
  local a
  local -a aargs=()
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$a" in claude|codex) aargs+=(--agent "$a") ;; esac
  done <<EOF
$(_pi_pin_agents "$p")
EOF
  [ "${#aargs[@]}" -gt 0 ] || { _pi_err "upgrade: the pin records no usable agent set — re-run 'install' naming the agents"; return 10; }
  if [ -n "$artifact" ]; then
    [ -n "$sums" ] || { _pi_err "upgrade: --artifact requires --sums"; return 2; }
    cmd_install --project "$p" --to "$to" --upgrade "${aargs[@]}" --artifact "$artifact" --sums "$sums"
    return $?
  fi
  cmd_install --project "$p" --to "$to" --upgrade "${aargs[@]}"
}

# --- status ------------------------------------------------------------------------------------

cmd_status() {
  local p="" offline=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) _pi_need_val "$1" "$#" || return 2; p="$2"; shift 2 ;;
      --offline) offline=1; shift ;;
      *) _pi_err "status: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "status: not in a git repository and --project was not given"; return 2; }
  p="$(cd "$p" && pwd)"

  local mode; mode="$(_pi_pin_mode "$p")"
  if [ "$mode" != pinned ]; then
    if [ -f "$(_pi_pin_path "$p")" ]; then
      _pi_say "mode: global (an /adopt pin is present, but it records no pinned payload)"
    else
      _pi_say "mode: global (no pin)"
    fi
    return 11
  fi

  local ver src agents
  ver="$(_pi_pin_get "$p" version)"; src="$(_pi_pin_source "$p")"
  agents="$(_pi_pin_agents "$p" | tr '\n' ',')"
  _pi_say "mode:    pinned"
  _pi_say "version: ${ver:-<unrecorded>}"
  _pi_say "source:  $src"

  # The payload is re-checked against the receipt, never assumed present from the pin. A pin is a
  # claim about a tree; the digests are the tree.
  local rp counts missing altered records surfaces=0 rel
  rp="$(_pi_receipt_path "$p")"
  if [ ! -f "$rp" ]; then
    _pi_say "payload: NO RECEIPT — cannot verify what is installed"
    return 20
  fi
  counts="$(_pi_verify_tree "$p" "$rp")"
  missing="$(printf '%s' "$counts" | awk '{print $1}')"
  altered="$(printf '%s' "$counts" | awk '{print $2}')"
  records="$(printf '%s' "$counts" | awk '{print $3}')"
  # ZERO RECORDS IS NOT AN INTACT PAYLOAD. A truncated receipt evaluates zero digests and lands on
  # missing=0, altered=0 — reporting a verified tree in exactly the words a real one uses.
  if [ "$records" -eq 0 ]; then
    _pi_say "payload: EMPTY RECEIPT — it records no files, so nothing here has been verified"
    return 20
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$p/$rel" ] || { _pi_say "  missing  $rel"; continue; }
    [ "$(_pi_sha256 "$p/$rel" 2>/dev/null)" = "$(_pi_receipt_digest "$rp" "$rel")" ] \
      || _pi_say "  altered  $rel"
  done <<EOF
$(_pi_receipt_paths "$rp")
EOF
  _pi_check_surfaces "$p" "$agents" "$rp" || surfaces=1

  # ALTERED IS UNVERIFIABLE, and the exit-code contract says so. Reporting a modified payload while
  # returning 0 makes the machine-readable answer disagree with the human-readable one.
  if [ "$missing" -gt 0 ] || [ "$altered" -gt 0 ] || [ "$surfaces" -ne 0 ]; then
    _pi_say "payload: NOT INTACT — $missing missing, $altered locally modified, merged surfaces $([ "$surfaces" -eq 0 ] && printf 'ok' || printf 'incomplete')"
    return 20
  fi
  _pi_say "payload: intact ($records files)"

  # Coexistence is REPORTED, not arbitrated: the harness already resolves the project's copy ahead
  # of the global one, and saying which one wins is more useful than pretending to choose.
  if [ -L "$HOME/.claude/CLAUDE.md" ] || [ -L "$HOME/.codex/AGENTS.md" ]; then
    _pi_say "note:    a GLOBAL symlink install is also active on this machine."
    _pi_say "         This project's vendored skills shadow it (docs/per-project-overrides.md, Override 2)."
  fi

  [ "$offline" -eq 1 ] && return 0

  local latest
  if latest="$(_pi_latest_version "$src")"; then
    _pi_say "latest:  $latest"
    if [ -n "$ver" ] && ! adb_version_ge "$ver" "$latest"; then
      _pi_say ""
      _pi_say "A newer release is available. Nothing here upgrades on its own. Review the change first:"
      _pi_say "  gh release view v$latest -R $src"
      _pi_say "then, if you want it:"
      _pi_say "  bash .claude/$PI_NS/lib/pinned-install.sh upgrade --to $latest"
      return 10
    fi
    return 0
  fi
  _pi_say "latest:  unknown (could not read $src's releases)"
  return 30
}

# cmd_notice — the report `baseline update` prints in a pinned project.
#
# Silent and non-zero when the project is not pinned, so a caller can print it unconditionally and
# see nothing in the global case. `--check-latest` is what makes it satisfy #285's "reports a newer
# release"; without the flag it touches no network at all, which is what keeps `--check` free.
cmd_notice() {
  local p="" latest=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)      _pi_need_val "$1" "$#" || return 2; p="$2"; shift 2 ;;
      --check-latest) latest=1; shift ;;
      *) _pi_err "notice: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || return 11
  [ "$(_pi_pin_mode "$p")" = pinned ] || return 11
  local ver rp counts missing altered records src newest agents
  ver="$(_pi_pin_get "$p" version)"
  src="$(_pi_pin_source "$p")"
  agents="$(_pi_pin_agents "$p" | tr '\n' ',')"
  printf 'baseline: this project runs a PINNED baseline payload (%s) — the global install does not govern it.\n' \
    "${ver:-version unrecorded}" >&2
  rp="$(_pi_receipt_path "$p")"
  if [ -f "$rp" ]; then
    counts="$(_pi_verify_tree "$p" "$rp")"
    missing="$(printf '%s' "$counts" | awk '{print $1}')"
    altered="$(printf '%s' "$counts" | awk '{print $2}')"
    records="$(printf '%s' "$counts" | awk '{print $3}')"
    if [ "$records" -eq 0 ] || [ "$missing" -gt 0 ] || [ "$altered" -gt 0 ] \
       || ! _pi_check_surfaces "$p" "$agents" "$rp" >/dev/null 2>&1; then
      printf 'baseline:   payload: %s missing, %s locally modified (%s records) — run: bash .claude/%s/lib/pinned-install.sh status\n' \
        "$missing" "$altered" "$records" "$PI_NS" >&2
    fi
  else
    printf 'baseline:   payload: no receipt — run: bash .claude/%s/lib/pinned-install.sh status\n' "$PI_NS" >&2
  fi
  if [ "$latest" -eq 1 ] && newest="$(_pi_latest_version "$src")"; then
    if [ -n "$ver" ] && ! adb_version_ge "$ver" "$newest"; then
      printf 'baseline:   a newer release is available: %s (pinned: %s). Review it, then upgrade deliberately:\n' "$newest" "$ver" >&2
      printf 'baseline:     gh release view v%s -R %s\n' "$newest" "$src" >&2
      printf 'baseline:     bash .claude/%s/lib/pinned-install.sh upgrade --to %s\n' "$PI_NS" "$newest" >&2
    fi
  fi
  return 0
}

# --- uninstall -----------------------------------------------------------------------------------

cmd_uninstall() {
  local p=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) _pi_need_val "$1" "$#" || return 2; p="$2"; shift 2 ;;
      *) _pi_err "uninstall: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "uninstall: not in a git repository and --project was not given"; return 2; }
  p="$(cd "$p" && pwd)"
  [ "$(_pi_pin_mode "$p")" = pinned ] || { _pi_err "uninstall: this project has no pinned install"; return 10; }

  local rp; rp="$(_pi_receipt_path "$p")"
  [ -f "$rp" ] || { _pi_err "uninstall: no receipt at ${rp#"$p"/} — refusing to guess which files are ours"; return 10; }

  # THE HOOK ENTRIES COME OUT BEFORE THE SCRIPTS THEY POINT AT, and a failure here STOPS the run.
  # Deleting the gate scripts while settings.json still names them leaves a hook that errors on
  # every later Claude session — strictly worse than not uninstalling.
  if ! _pi_unwire_hooks "$p"; then
    _pi_err "uninstall: refusing to remove the gate scripts while .claude/settings.json still points at them."
    _pi_err "           Install jq (or remove those entries by hand), then re-run."
    return 12
  fi
  _pi_strip_block "$p/AGENTS.md" || { _pi_err "uninstall: refusing to continue with an unrepairable AGENTS.md"; return 10; }

  # REMOVE BY DIGEST. A file whose contents no longer match the receipt was changed after the
  # install, so it is the operator's now and is kept and named — an uninstaller that deletes work
  # it did not write is worse than one that leaves a file behind.
  local rel want have kept=0 gone=0 failed=0
  local -a dirs=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dirs+=("$(dirname "$rel")")
    [ -f "$p/$rel" ] || continue
    want="$(_pi_receipt_digest "$rp" "$rel")"
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    if [ -n "$want" ] && [ "$have" = "$want" ]; then
      if rm -f "$p/$rel"; then gone=$((gone + 1)); else failed=$((failed + 1)); _pi_say "  FAILED $rel (could not remove)"; fi
    else
      kept=$((kept + 1)); _pi_say "  kept   $rel (locally modified)"
    fi
  done <<EOF
$(_pi_receipt_paths "$rp")
EOF

  # A settings.json this install CREATED, and that now holds nothing but an empty `hooks` object,
  # is an orphan; one it did not create is the project's file and stays, whatever it now contains.
  if _pi_receipt_flag "$rp" "# created: .claude/settings.json" && command -v jq >/dev/null 2>&1; then
    if jq -e '(. | del(.hooks)) == {} and ((.hooks // {}) == {})' "$p/.claude/settings.json" >/dev/null 2>&1; then
      rm -f "$p/.claude/settings.json" && _pi_say "  hooks  removed .claude/settings.json (this install created it)"
    fi
  fi

  # THE RECEIPT IS THE OWNERSHIP EVIDENCE, so it survives a partial removal. Deleting it after a
  # failed `rm` leaves a file nothing can ever identify as ours again.
  if [ "$failed" -gt 0 ]; then
    _pi_err "uninstall: $failed file(s) could not be removed; the receipt is KEPT so a re-run can finish."
    _pi_say "uninstalled partially: $gone removed, $kept kept, $failed failed"
    return 14
  fi
  rm -f "$rp"

  # PRUNE ONLY THE DIRECTORIES THE RECEIPT NAMES, deepest first, and only when empty. A blanket
  # `find .claude .codex .ai-dev-baseline -type d` also removed directories this install never
  # created — an intentional empty one the project keeps, for instance.
  local d
  while IFS= read -r d; do
    { [ -n "$d" ] && [ "$d" != "." ]; } || continue
    [ -d "$p/$d" ] && rmdir "$p/$d" 2>/dev/null
  done <<EOF
$(printf '%s\n' "${dirs[@]}" | awk '{ n = split($0, a, "/"); acc = ""; for (i = 1; i <= n; i++) { acc = (i == 1 ? a[i] : acc "/" a[i]); print length(acc) "\t" acc } }' | LC_ALL=C sort -rn -k1,1 | cut -f2 | awk '!seen[$0]++')
EOF

  _pi_say "uninstalled the pinned payload: $gone file(s) removed, $kept kept"
  return 0
}

# --- dispatch ------------------------------------------------------------------------------------

usage() { adb_usage "$0"; }

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    install)   cmd_install "$@" ;;
    upgrade)   cmd_upgrade "$@" ;;
    status)    cmd_status "$@" ;;
    notice)    cmd_notice "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    payload)   cmd_payload "$@" ;;
    reanchor)  cmd_reanchor "$@" ;;
    verify)    cmd_verify "$@" ;;
    -h|--help) usage ;;
    *) _pi_err "unknown subcommand: ${sub:-<none>}"; usage >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then main "$@"; fi
