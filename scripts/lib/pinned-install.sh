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
# Usage:
#   pinned-install.sh install --project DIR [--agent claude|codex]...
#                             ( --version X.Y.Z | --artifact FILE --sums FILE )
#   pinned-install.sh status    [--project DIR]
#   pinned-install.sh notice    [--project DIR]   # local-only; silent unless pinned
#   pinned-install.sh upgrade   --to X.Y.Z [--project DIR] [--artifact FILE --sums FILE]
#   pinned-install.sh uninstall [--project DIR]
#   pinned-install.sh payload   <agent> <artifact-root> <project-root>
#   pinned-install.sh reanchor  <agent> <project-root>       (stdin -> stdout)
#   pinned-install.sh verify    <tarball> <sums-file>
#   pinned-install.sh -h | --help
#
# Exit codes:
#   install/upgrade/uninstall  0 ok · 10 refused (state) · 11 verification failed · 12 missing tool
#                              · 13 fetch failed · 14 publish failed · 2 usage
#   status                     0 pinned and current · 10 pinned, a newer release exists
#                              · 11 not pinned · 20 pinned but the payload is missing or altered
#                              · 30 the release list could not be read
#   verify                     0 verified · 10 no record for that filename · 11 digest mismatch
#                              · 12 no usable sha256 tool / unreadable input
#   payload/reanchor           0 ok · 1 a root this manifest cannot represent · 2 usage
#
# Globals read: ADB_PINNED_REPO (default BWBama85/ai-dev-baseline) — the release source, recorded
# into the pin so `upgrade` reads the same one. ADB_PINNED_MIN_VERSION overrides the payload floor.

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
if ! command -v adb_repo_root >/dev/null 2>&1; then
  printf 'pinned-install: FATAL — %s is missing adb_repo_root\n' "$_pi_common" >&2
  return 1 2>/dev/null || exit 1
fi

PI_REPO="${ADB_PINNED_REPO:-BWBama85/ai-dev-baseline}"

# The oldest release whose tarball carries a payload this installer understands. A release below
# it is REFUSED rather than half-installed: the structural probe below can only say that a tree
# looks wrong, and "looks wrong" is the same answer a truncated download gives.
PI_MIN_VERSION="${ADB_PINNED_MIN_VERSION:-2.0.0}"

# Everything this install owns lives under ONE directory per agent, `.<agent>/adb/`, and the
# harness-fixed skills root. The namespace is load-bearing rather than tidy: `.claude/scripts/`
# is `handling-the-unknown.md`'s one prescribed home for a project's OWN gate policy, so an
# install that wrote its gates there would occupy the path the practice reserves for the project.
# Hooks and `lib/` sit as siblings inside it because every gate script resolves its library as
# `$(dirname "$0")/lib/common.sh` — that layout is what lets them be vendored byte-unchanged.
PI_NS="adb"

# The managed region in a project's own AGENTS.md. Codex discovers project instructions by
# concatenating every AGENTS.md from the project root down to the cwd and supports no include
# directive (verified this run against codex-rs/core/src/agents_md.rs via context7), so the root
# file is the only place its practices can be reached from.
PI_BEGIN='<!-- ai-dev-baseline:begin (managed by pinned-install.sh — do not edit inside) -->'
PI_END='<!-- ai-dev-baseline:end -->'

_pi_say() { printf '%s\n' "$*"; }
_pi_err() { printf 'pinned-install: %s\n' "$*" >&2; }

# _pi_sha256 <file> — print the file's lowercase hex SHA-256, or fail non-zero.
#
# LOCAL, not promoted to common.sh: this is its only caller. The release skill carries its own
# `release-lib.sh sha256`, which is deliberately not shared — that skill is project-scoped and is
# never installed into an agent home, so the two live in trees that never meet.
_pi_sha256() {
  local f="$1" out hex
  case "$f" in -*) _pi_err "refusing a path that begins with '-': $f"; return 1 ;; esac
  [ -f "$f" ] || { _pi_err "not a regular file: $f"; return 1; }
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum -- "$f")" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 -- "$f")" || return 1
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 -r "$f")" || return 1
  else
    _pi_err "no sha256 tool found (tried sha256sum, shasum, openssl)"
    return 1
  fi
  hex="${out%% *}"
  case "$hex" in
    ''|*[!0-9a-f]*) _pi_err "unparseable digest output for $f"; return 1 ;;
  esac
  printf '%s' "$hex"
}

# --- the payload map -------------------------------------------------------------------------

# cmd_payload <agent> <artifact-root> <project-root> — print `<src>TAB<dest>` for every plain
# file this install copies, dest absolute under <project-root>.
#
# THE ONE PRODUCER. install copies it, the receipt digests it, `status` re-checks it and
# uninstall removes it, so the four cannot drift (docs/design-principles.md). The two MERGED
# surfaces — the project's settings.json and its AGENTS.md — are deliberately NOT here: they are
# regions inside files the project owns, not files this install owns, and a remover that treated
# them as owned would delete a project's own configuration.
#
# An unknown agent prints nothing and returns 0, mirroring adb_agent_manifest. A root carrying a
# tab or newline prints NOTHING and returns 1: half a map is worse than none, because every
# consumer below would act on the half.
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
  # `paths:` frontmatter (vendor docs, fetched this run); Codex has no such directory, so its
  # copy is staged here and spliced into the project's AGENTS.md as a managed region instead.
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
    for f in "$d"*; do
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

  # Claude's Stop-hook gates. `session-currency.sh` is deliberately absent: it fast-forwards the
  # install-source clone, and a pinned project has none — wiring it would report a broken install
  # on every session start.
  if [ "$agent" = claude ]; then
    for name in precommit-gate.sh implement-issue-gate.sh state-claim-gate.sh; do
      [ -f "$a/agents/claude/scripts/$name" ] || continue
      printf '%s\t%s\n' "$a/agents/claude/scripts/$name" "$p/.claude/$PI_NS/$name"
    done
  fi
}

# cmd_reanchor <agent> <project-root> — rewrite the library prefix on stdin, to stdout.
#
# A rendered skill reaches its libraries through `$HOME/.<agent>/scripts/lib/` (scripts/build.sh),
# which is one directory shared by the global install and by every project on the machine. A
# vendored payload must not write there, so the vendored SKILL.md is repointed at the project's
# own copy. `git rev-parse --show-toplevel` rather than an absolute path because the result is
# committed into someone else's repository: an absolute path would be machine-local, and the
# agent may invoke from a subdirectory.
#
# The prefix carries `scripts/lib/` on purpose. `$HOME/.claude/skills` also appears in a rendered
# body and must NOT be rewritten — it genuinely means the user-global skills root, and a pinned
# project asking what is installed globally is asking a real question.
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
  # Two columns, the second being the name, per the sha256sum record format. A record whose name
  # carries the `*` binary marker is accepted with it stripped.
  n="$(ADB_PI_BASE="$base" awk '
        BEGIN { want = ENVIRON["ADB_PI_BASE"] }
        NF >= 2 { name = $2; sub(/^\*/, "", name); if (name == want) c++ }
        END { print c + 0 }' "$sums")"
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

# _pi_tar_is_safe <tarball> — reject an archive whose members could escape the extraction
# directory. Checked BEFORE extraction, because `tar` on some platforms strips these silently and
# on others honours them; neither is a basis for unpacking a downloaded file.
_pi_tar_is_safe() {
  local tar="$1" bad
  bad="$(tar -tzf "$tar" 2>/dev/null | awk '
      /^\// { print; next }
      /(^|\/)\.\.(\/|$)/ { print }
    ' | head -5)" || return 1
  if [ -n "$bad" ]; then
    _pi_err "the archive carries absolute or parent-relative members — refusing to unpack:"
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

# _pi_artifact_version <tarball> — print the version its name declares, or fail.
_pi_artifact_version() {
  local base="${1##*/}" v
  case "$base" in
    ai-dev-baseline-*.tar.gz) ;;
    *) _pi_err "not a baseline release archive: $base (expected ai-dev-baseline-<version>.tar.gz)"; return 1 ;;
  esac
  v="${base#ai-dev-baseline-}"; v="${v%.tar.gz}"
  case "$v" in
    ''|*[!0-9.]*) _pi_err "the archive name does not carry a numeric version: $base"; return 1 ;;
  esac
  printf '%s' "$v"
}

# _pi_probe_tree <root> <agent>… — assert an unpacked tree actually carries the payload this
# installer copies. A valid checksum proves the bytes arrived intact; it says nothing about the
# tree being a baseline of a shape this code understands.
_pi_probe_tree() {
  local root="$1"; shift
  local agent rc=0
  [ -d "$root/scripts/lib" ] || { _pi_err "the unpacked tree has no scripts/lib — not a usable payload"; rc=1; }
  [ -f "$root/scripts/lib/common.sh" ] || { _pi_err "the unpacked tree has no scripts/lib/common.sh"; rc=1; }
  for agent in "$@"; do
    case "$agent" in
      claude)
        [ -f "$root/agents/claude/CLAUDE.md" ] || { _pi_err "the unpacked tree has no agents/claude/CLAUDE.md"; rc=1; }
        [ -d "$root/agents/claude/skills" ]    || { _pi_err "the unpacked tree has no agents/claude/skills"; rc=1; } ;;
      codex)
        [ -f "$root/agents/codex/AGENTS.md" ]  || { _pi_err "the unpacked tree has no agents/codex/AGENTS.md"; rc=1; }
        [ -d "$root/agents/codex/skills" ]     || { _pi_err "the unpacked tree has no agents/codex/skills"; rc=1; } ;;
    esac
  done
  return "$rc"
}

# --- the pin ----------------------------------------------------------------------------------

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

_pi_pin_path() { printf '%s/.ai-dev-baseline/upstream.toml' "$1"; }
_pi_receipt_path() { printf '%s/.ai-dev-baseline/pinned-files.sha256' "$1"; }

# _pi_pin_mode <project-root> — print the recorded install mode, or nothing.
#
# ABSENT MEANS GLOBAL, not "pinned". `/adopt` already writes this pin for projects running the
# global symlink model (D60), so presence of the file is not the discriminator — the `mode` key
# is, and a pin written before this key existed is a global-mode pin by construction.
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

# _pi_write_pin <project-root> <version> <source-repo> <agents-csv> <adopted-date> — render the pin.
#
# It EXTENDS the schema D60 fixed rather than replacing it: `version`, `adopted`, `stack` and
# `agents` keep their meanings, `commit` is omitted because a pinned project has no clone in which
# a commit could be resolved, and `mode` + `source` are the two keys this model adds.
_pi_write_pin() {
  local p="$1" version="$2" src="$3" agents="$4" adopted="$5"
  local f tmp out="" a
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) _pi_err "refusing to write a pin with a malformed adoption date: $adopted"; return 1 ;;
  esac
  f="$(_pi_pin_path "$p")"
  case "$version" in *[!A-Za-z0-9._+-]*) _pi_err "refusing to write a pin for an unrepresentable version"; return 1 ;; esac
  case "$src" in *[!A-Za-z0-9._/-]*) _pi_err "refusing to write a pin for an unrepresentable source repo"; return 1 ;; esac
  for a in ${agents//,/ }; do
    case "$a" in *[!a-z0-9-]*) _pi_err "refusing to write a pin for an unrepresentable agent token"; return 1 ;; esac
    [ -z "$out" ] || out="$out, "
    out="$out\"$a\""
  done
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$f.adb.$$.tmp"
  cat > "$tmp" <<TOML
# ai-dev-baseline — upstream pin. Written by pinned-install.sh; safe to read, safe to commit.
#
# \`mode = "pinned"\` means this project carries a VENDORED payload of the released baseline named
# by \`version\`, rather than inheriting a machine's global symlink install. A pin without this key
# is a global-mode pin written by /adopt, and nothing here owns it.
#
# See: pinned-install.sh status

[upstream]
mode    = "pinned"
version = "$version"
source  = "$src"
adopted = "$adopted"
agents  = [$out]
TOML
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# --- managed regions in files the PROJECT owns -------------------------------------------------

# _pi_splice_block <file> <content-file> — put the managed region into <file>, creating it if
# absent, replacing an existing region in place, and appending otherwise. Idempotent by
# construction: the region is delimited, so a re-run rewrites exactly the same bytes.
_pi_splice_block() {
  local f="$1" body="$2" tmp="$1.adb.$$.tmp"
  mkdir -p "$(dirname "$f")" || return 1
  {
    if [ -f "$f" ]; then
      ADB_PI_B="$PI_BEGIN" ADB_PI_E="$PI_END" awk '
        BEGIN { b = ENVIRON["ADB_PI_B"]; e = ENVIRON["ADB_PI_E"] }
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
      ' "$f"
    fi
    printf '%s\n' "$PI_BEGIN"
    cat "$body"
    printf '%s\n' "$PI_END"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# _pi_strip_block <file> — remove the managed region, and remove the file entirely if that is all
# it ever held. A file carrying the project's own prose keeps it.
_pi_strip_block() {
  local f="$1" tmp="$1.adb.$$.tmp"
  [ -f "$f" ] || return 0
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

# _pi_wire_hooks <project-root> — merge the Stop gates into the project's .claude/settings.json,
# pointed at the vendored copies through ${CLAUDE_PROJECT_DIR} so nothing machine-local is
# committed. Same ownership shape as install.sh's global wiring: drop any group referencing one of
# OUR commands, then append ours, so a re-run replaces rather than doubles and a user's own groups
# survive. A missing jq is the ONE tolerated degradation, as it is globally.
_pi_wire_hooks() {
  local p="$1"
  local settings="$p/.claude/settings.json" tmp groups re
  if ! command -v jq >/dev/null 2>&1; then
    _pi_say "  WARN   jq not found — project Stop gates NOT wired; install jq and re-run"
    return 0
  fi
  re="\\\$\\{CLAUDE_PROJECT_DIR\\}/\\.claude/$PI_NS/"
  groups="$(cat <<JSON
{"Stop":[{"hooks":[
 {"type":"command","command":"\${CLAUDE_PROJECT_DIR}/.claude/$PI_NS/precommit-gate.sh","timeout":240,"statusMessage":"ai-dev-baseline: quality gates"},
 {"type":"command","command":"\${CLAUDE_PROJECT_DIR}/.claude/$PI_NS/implement-issue-gate.sh","timeout":30,"statusMessage":"ai-dev-baseline: implement-issue completion gate"},
 {"type":"command","command":"\${CLAUDE_PROJECT_DIR}/.claude/$PI_NS/state-claim-gate.sh","timeout":20,"statusMessage":"ai-dev-baseline: state-claim gate"}
]}]}
JSON
)"
  mkdir -p "$p/.claude" || return 1
  # `-s`, not `-f`: jq reads an EMPTY file as an empty stream and exits 0 printing nothing, which
  # would install a 0-byte settings.json while reporting success.
  [ -s "$settings" ] || echo '{}' > "$settings"
  tmp="$settings.adb.$$.tmp"
  if ! jq --argjson groups "$groups" --arg re "$re" '
        .hooks = (.hooks // {})
        | reduce ($groups | to_entries[]) as $e (.;
            .hooks[$e.key] = (((.hooks[$e.key] // [])
              | map(select(([.hooks[]?.command // ""] | any(test($re))) | not)))
              + $e.value))
      ' "$settings" > "$tmp"; then
    rm -f "$tmp"
    _pi_say "  WARN   $settings is not valid JSON — Stop gates NOT wired"
    return 1
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; _pi_say "  WARN   hook wiring produced an empty settings.json — NOT wired"; return 1; }
  mv "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
  _pi_say "  hooks  wired project Stop gates into .claude/settings.json"
}

# _pi_unwire_hooks <project-root> — the mirror. Same ownership regex, every event, and an event
# key is dropped only once it is empty.
_pi_unwire_hooks() {
  local p="$1"
  local settings="$p/.claude/settings.json" re tmp
  [ -s "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || { _pi_say "  WARN   jq not found — hook entries left in .claude/settings.json"; return 0; }
  re="\\\$\\{CLAUDE_PROJECT_DIR\\}/\\.claude/$PI_NS/"
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
    # A settings.json that now holds NOTHING but an empty `hooks` object is one this install
    # created and nothing else ever used: leaving it behind is the orphan the uninstall contract
    # forbids. Any other key — a permission, a model, an env — means it is the project's file and
    # it stays. Proven from the content, never from a memory of who wrote it.
    if jq -e '(. | del(.hooks)) == {} and ((.hooks // {}) == {})' "$settings" >/dev/null 2>&1; then
      rm -f "$settings"
      _pi_say "  hooks  removed .claude/settings.json (it held only this install's wiring)"
    fi
  else
    rm -f "$tmp"
    _pi_say "  WARN   could not rewrite .claude/settings.json — hook entries NOT removed"
  fi
}

# --- fetch ------------------------------------------------------------------------------------

# _pi_fetch <version> <dest-dir> — put `ai-dev-baseline-<version>.tar.gz` and `SHA256SUMS` in
# <dest-dir>. `gh` first because it carries the operator's auth (a private fork resolves), curl
# as the fallback so a machine with no clone and no gh can still install.
_pi_fetch() {
  local v="$1" dir="$2"
  local tag="v${v#v}" base="ai-dev-baseline-${v#v}.tar.gz" url
  if command -v gh >/dev/null 2>&1 \
     && gh release download "$tag" -R "$PI_REPO" -D "$dir" -p "$base" -p SHA256SUMS >/dev/null 2>&1; then
    :
  elif command -v curl >/dev/null 2>&1; then
    url="https://github.com/$PI_REPO/releases/download/$tag"
    curl -fsSL -o "$dir/$base" "$url/$base" || { _pi_err "could not download $base from $url"; return 1; }
    curl -fsSL -o "$dir/SHA256SUMS" "$url/SHA256SUMS" || { _pi_err "could not download SHA256SUMS from $url"; return 1; }
  else
    _pi_err "neither gh nor curl is available — cannot fetch the release artifact"
    return 1
  fi
  [ -f "$dir/$base" ] && [ -f "$dir/SHA256SUMS" ] || { _pi_err "the download did not produce both assets"; return 1; }
  printf '%s' "$dir/$base"
}

# _pi_latest_version — print the newest published release's bare version, or fail.
_pi_latest_version() {
  command -v gh >/dev/null 2>&1 || return 1
  local t
  t="$(gh release list -R "$PI_REPO" --limit 1 --json tagName,isDraft \
        --jq 'map(select(.isDraft | not)) | .[0].tagName' 2>/dev/null)" || return 1
  [ -n "$t" ] && [ "$t" != null ] || return 1
  printf '%s' "${t#v}"
}

# --- install ------------------------------------------------------------------------------------

# _pi_stage <artifact-root> <project-root> <staging-root> <agent>… — build the COMPLETE payload
# under <staging-root>, mirroring each destination's path relative to <project-root>. Nothing is
# written into the project until every file has been produced and re-anchored, so a failure
# halfway through leaves the project exactly as it was.
_pi_stage() {
  local a="$1" p="$2" stage="$3"; shift 3
  local agent src dest rel manifest
  for agent in "$@"; do
    manifest="$(cmd_payload "$agent" "$a" "$p")" || return 1
    [ -n "$manifest" ] || { _pi_err "the payload map for '$agent' is empty — refusing to install nothing"; return 1; }
    while IFS="$(printf '\t')" read -r src dest; do
      [ -n "$src" ] && [ -n "$dest" ] || continue
      rel="${dest#"$p"/}"
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
_pi_assert_reanchored() {
  local stage="$1"; shift
  local agent hits rc=0
  for agent in "$@"; do
    [ -d "$stage/.$agent/skills" ] || continue
    hits="$(grep -rl -- "\$HOME/.$agent/scripts/lib/" "$stage/.$agent/skills" 2>/dev/null)" || true
    if [ -n "$hits" ]; then
      _pi_err "staged $agent skills still reach \$HOME/.$agent/scripts/lib/ — the re-anchor did not take:"
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      rc=1
    fi
  done
  return "$rc"
}

# _pi_publish <staging-root> <project-root> — copy the staged tree into the project and print the
# receipt (`<sha256>  <repo-relative path>`) on stdout. Publishing is per-file and by RENAME, so
# no destination is ever observable half-written (D52).
_pi_publish() {
  local stage="$1" p="$2" f rel digest
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$stage"/}"
    mkdir -p "$p/$(dirname "$rel")" || return 1
    cp "$f" "$p/$rel.adb.$$.tmp" || return 1
    if [ -x "$f" ]; then chmod +x "$p/$rel.adb.$$.tmp" || return 1; fi
    mv "$p/$rel.adb.$$.tmp" "$p/$rel" || { rm -f "$p/$rel.adb.$$.tmp"; return 1; }
    digest="$(_pi_sha256 "$p/$rel")" || return 1
    printf '%s  %s\n' "$digest" "$rel"
  done <<EOF
$(cd "$stage" && find . -type f | sed "s|^\./|$stage/|" | LC_ALL=C sort)
EOF
}

cmd_install() {
  local p="" version="" artifact="" sums="" upgrade=0
  local -a agents=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)  p="${2:-}"; shift 2 ;;
      --agent)    agents+=("${2:-}"); shift 2 ;;
      --version|--to) version="${2:-}"; shift 2 ;;
      --artifact) artifact="${2:-}"; shift 2 ;;
      --sums)     sums="${2:-}"; shift 2 ;;
      --upgrade)  upgrade=1; shift ;;
      *) _pi_err "install: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "install: --project not given and the current directory is not in a git repository"; return 2; }
  [ -d "$p" ] || { _pi_err "install: no such project directory: $p"; return 2; }
  p="$(cd "$p" && pwd)"
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
    [ -z "$version" ] || _pi_say "note: --version is ignored when --artifact is given (the archive names its own)"
  else
    [ -n "$version" ] || { _pi_err "install: needs --version X.Y.Z, or --artifact FILE --sums FILE"; return 2; }
  fi

  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/adb-pinned.XXXXXX")" || { _pi_err "install: cannot create a working directory"; return 12; }
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  if [ -z "$artifact" ]; then
    _pi_say "fetching ai-dev-baseline ${version#v} from $PI_REPO …"
    artifact="$(_pi_fetch "${version#v}" "$work")" || { rm -rf "$work"; trap - EXIT; return 13; }
    sums="$work/SHA256SUMS"
  fi

  local ver rc
  ver="$(_pi_artifact_version "$artifact")" || { rm -rf "$work"; trap - EXIT; return 11; }
  if ! adb_version_ge "$ver" "$PI_MIN_VERSION"; then
    _pi_err "install: $ver is below the minimum installable baseline release ($PI_MIN_VERSION) — its artifact predates this payload format"
    rm -rf "$work"; trap - EXIT; return 11
  fi

  # THE PIN IS CONSULTED HERE, not before the version is known — with --artifact the version is a
  # property of the archive, so an earlier check would have had to refuse on the mere EXISTENCE of
  # a pin and re-running the same version would not have been idempotent.
  #
  # Same version -> proceed; the run republishes identical bytes and changes nothing.
  # Different version -> refuse, because an in-place version change is an upgrade and an upgrade is
  # a decision the operator makes by naming the version (`upgrade --to`).
  # A GLOBAL-mode pin is left alone entirely: it records another model and nothing here owns it.
  local mode cur
  mode="$(_pi_pin_mode "$p")"
  if [ "$mode" = pinned ] && [ "$upgrade" -eq 0 ]; then
    cur="$(_pi_pin_get "$p" version)"
    if [ "$cur" != "$ver" ]; then
      _pi_err "install: this project is already pinned to ${cur:-an unrecorded version}, not $ver."
      _pi_err "         Changing the pinned version is an upgrade; name it explicitly:"
      _pi_err "           pinned-install.sh upgrade --to $ver"
      rm -rf "$work"; trap - EXIT; return 10
    fi
  fi

  cmd_verify "$artifact" "$sums"; rc=$?
  [ "$rc" -eq 0 ] || { rm -rf "$work"; trap - EXIT; return 11; }
  _pi_tar_is_safe "$artifact" || { rm -rf "$work"; trap - EXIT; return 11; }

  local unpacked="$work/unpacked"
  mkdir -p "$unpacked"
  tar -xzf "$artifact" -C "$unpacked" || { _pi_err "install: could not unpack $artifact"; rm -rf "$work"; trap - EXIT; return 11; }
  local root="$unpacked/ai-dev-baseline-$ver"
  [ -d "$root" ] || { _pi_err "install: the archive does not contain ai-dev-baseline-$ver/ — refusing"; rm -rf "$work"; trap - EXIT; return 11; }
  _pi_probe_tree "$root" "${agents[@]}" || { rm -rf "$work"; trap - EXIT; return 11; }

  # CRLF is acquired at UNPACK time as easily as at clone time, and an unpacked payload is not
  # governed by this repo's .gitattributes. The same shared scanner install.sh runs on a clone
  # runs here, on the tree that is about to be vendored.
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

  # NAME WHAT THIS RUN IS ABOUT TO OVERWRITE. The payload is generated and the docs say not to
  # edit it, but "we told you not to" is not a reason to replace an operator's edit in silence —
  # and on a same-version re-install this line is also the repair notice.
  local prev want rel have
  prev="$(_pi_receipt_path "$p")"
  if [ -f "$prev" ]; then
    while read -r want rel; do
      case "$want" in ''|'#'*) continue ;; esac
      [ -n "$rel" ] && [ -f "$p/$rel" ] || continue
      have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
      [ "$have" = "$want" ] || _pi_say "  NOTE   $rel was modified locally and is being replaced"
    done < "$prev"
  fi

  _pi_say "installing ai-dev-baseline $ver into ${p##*/} (agents: ${agents[*]})"
  local receipt="$work/receipt"
  _pi_publish "$stage" "$p" > "$receipt" || { _pi_err "install: publishing failed — the project tree may be partially written"; rm -rf "$work"; trap - EXIT; return 14; }

  # Codex reads only the root AGENTS.md, so its practices are spliced there as a delimited region
  # rather than copied to a path it would never load.
  for agent in "${agents[@]}"; do
    [ "$agent" = codex ] || continue
    _pi_splice_block "$p/AGENTS.md" "$p/.codex/$PI_NS/AGENTS.practices.md" \
      || { _pi_err "install: could not splice the practices into AGENTS.md"; rm -rf "$work"; trap - EXIT; return 14; }
    _pi_say "  block  managed region written into AGENTS.md"
  done

  for agent in "${agents[@]}"; do
    [ "$agent" = claude ] || continue
    _pi_wire_hooks "$p" || true
  done

  # `adopted` RECORDS THE FIRST ADOPTION and is carried forward, never restamped. Rewriting it on
  # every run would make "re-running changes nothing" false on any day but the first, and would
  # also make the field mean "last install" while its name says otherwise.
  local csv adopted
  csv="$(IFS=,; printf '%s' "${agents[*]}")"
  adopted="$(_pi_pin_get "$p" adopted 2>/dev/null)" || adopted=""
  case "$adopted" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) adopted="$(date -u +%Y-%m-%d)" ;;
  esac
  _pi_write_pin "$p" "$ver" "$PI_REPO" "$csv" "$adopted" || { _pi_err "install: could not write the pin"; rm -rf "$work"; trap - EXIT; return 14; }
  # The receipt is written LAST and lists the pin too, so a run interrupted before this point
  # leaves no receipt claiming files it had not finished writing.
  local rp; rp="$(_pi_receipt_path "$p")"
  {
    printf '# ai-dev-baseline — files written by pinned-install.sh. Do not edit.\n'
    cat "$receipt"
    printf '%s  %s\n' "$(_pi_sha256 "$(_pi_pin_path "$p")")" ".ai-dev-baseline/upstream.toml"
  } > "$rp.adb.$$.tmp" && mv "$rp.adb.$$.tmp" "$rp" || { _pi_err "install: could not write the receipt"; rm -rf "$work"; trap - EXIT; return 14; }

  _pi_say "pinned to $ver — commit .ai-dev-baseline/ and the vendored .<agent>/ payload"
  rm -rf "$work"; trap - EXIT
  return 0
}

cmd_upgrade() {
  local p="" to="" artifact="" sums=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      --project) p="${2:-}"; shift 2 ;;
      # An already-downloaded pair, for an operator installing from media and for the offline
      # check. `--to` is still required: it is the approval, and it is compared against what the
      # archive actually contains rather than trusted.
      --artifact) artifact="${2:-}"; shift 2 ;;
      --sums) sums="${2:-}"; shift 2 ;;
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
  # an agent would leave that agent's vendored payload behind, unowned by the new receipt.
  local a
  local -a aargs=()
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$a" in claude|codex) aargs+=(--agent "$a") ;; esac
  done <<EOF
$(adb_toml_array "$(adb_toml_get "$(_pi_pin_path "$p")" upstream agents 2>/dev/null)" 2>/dev/null)
EOF
  [ "${#aargs[@]}" -gt 0 ] || { _pi_err "upgrade: the pin records no usable agent set — re-run 'install' naming the agents"; return 10; }
  if [ -n "$artifact" ]; then
    [ -n "$sums" ] || { _pi_err "upgrade: --artifact requires --sums"; return 2; }
    # THE NAMED VERSION IS CHECKED AGAINST THE ARCHIVE. Without this, `--to 3.0.0 --artifact
    # ai-dev-baseline-2.2.0.tar.gz` would install 2.2.0 while the operator approved 3.0.0.
    local av
    av="$(_pi_artifact_version "$artifact")" || return 11
    [ "$av" = "${to#v}" ] || { _pi_err "upgrade: --to ${to#v} does not match the archive, which is $av"; return 11; }
    cmd_install --project "$p" --upgrade "${aargs[@]}" --artifact "$artifact" --sums "$sums"
    return $?
  fi
  cmd_install --project "$p" --to "$to" --upgrade "${aargs[@]}"
}

# --- status ------------------------------------------------------------------------------------

cmd_status() {
  local p=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) p="${2:-}"; shift 2 ;;
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

  local ver src; ver="$(_pi_pin_get "$p" version)"; src="$(_pi_pin_get "$p" source)"
  _pi_say "mode:    pinned"
  _pi_say "version: ${ver:-<unrecorded>}"
  _pi_say "source:  ${src:-$PI_REPO}"

  # The payload is re-checked against the receipt, never assumed present from the pin. A pin is a
  # claim about a tree; the digests are the tree.
  local rp missing=0 altered=0 want have rel
  rp="$(_pi_receipt_path "$p")"
  if [ ! -f "$rp" ]; then
    _pi_say "payload: NO RECEIPT — cannot verify what is installed"
    return 20
  fi
  while read -r want rel; do
    case "$want" in ''|'#'*) continue ;; esac
    [ -n "$rel" ] || continue
    if [ ! -f "$p/$rel" ]; then
      missing=$((missing + 1)); _pi_say "  missing  $rel"; continue
    fi
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    [ "$have" = "$want" ] || { altered=$((altered + 1)); _pi_say "  altered  $rel"; }
  done < "$rp"
  if [ "$missing" -gt 0 ]; then
    _pi_say "payload: INCOMPLETE — $missing file(s) missing, $altered altered"
    return 20
  fi
  [ "$altered" -eq 0 ] && _pi_say "payload: intact" || _pi_say "payload: $altered file(s) locally modified (kept; uninstall will not remove them)"

  # Coexistence is REPORTED, not arbitrated: the harness already resolves the project's copy
  # ahead of the global one, and saying which one wins is more useful than pretending to choose.
  if [ -L "$HOME/.claude/CLAUDE.md" ] || [ -L "$HOME/.codex/AGENTS.md" ]; then
    _pi_say "note:    a GLOBAL symlink install is also active on this machine."
    _pi_say "         This project's vendored skills shadow it (docs/per-project-overrides.md, Override 2)."
  fi

  local latest
  if latest="$(_pi_latest_version)"; then
    _pi_say "latest:  $latest"
    if [ -n "$ver" ] && ! adb_version_ge "$ver" "$latest"; then
      _pi_say ""
      _pi_say "A newer release is available. Nothing here upgrades on its own — review, then run:"
      _pi_say "  bash .claude/$PI_NS/lib/pinned-install.sh upgrade --to $latest"
      return 10
    fi
    return 0
  fi
  _pi_say "latest:  unknown (could not read $PI_REPO's releases)"
  return 30
}

# cmd_notice <project-root> — the LOCAL-ONLY pinned report, for a caller that must not reach the
# network. Silent and non-zero when the project is not pinned, so a caller can print it
# unconditionally and see nothing in the global case.
#
# IT DOES NOT ASK GITHUB WHETHER A NEWER RELEASE EXISTS. `baseline update --check` documents
# itself as making no changes and reaching the network only when local state is safe, and two
# automatic triggers call it; adding a release lookup there would put a round trip on every
# session start. `status` is the subcommand that asks, and the operator runs it deliberately.
cmd_notice() {
  local p=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) p="${2:-}"; shift 2 ;;
      *) _pi_err "notice: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || return 11
  [ "$(_pi_pin_mode "$p")" = pinned ] || return 11
  local ver rp want rel have missing=0 altered=0
  ver="$(_pi_pin_get "$p" version)"
  printf 'baseline: this project runs a PINNED baseline payload (%s) — the global install does not govern it.\n' \
    "${ver:-version unrecorded}" >&2
  rp="$(_pi_receipt_path "$p")"
  if [ -f "$rp" ]; then
    while read -r want rel; do
      case "$want" in ''|'#'*) continue ;; esac
      [ -n "$rel" ] || continue
      if [ ! -f "$p/$rel" ]; then missing=$((missing + 1)); continue; fi
      have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
      [ "$have" = "$want" ] || altered=$((altered + 1))
    done < "$rp"
    if [ "$missing" -gt 0 ] || [ "$altered" -gt 0 ]; then
      printf 'baseline:   payload: %s missing, %s locally modified — run: bash .claude/%s/lib/pinned-install.sh status\n' \
        "$missing" "$altered" "$PI_NS" >&2
    fi
  else
    printf 'baseline:   payload: no receipt — run: bash .claude/%s/lib/pinned-install.sh status\n' "$PI_NS" >&2
  fi
  printf 'baseline:   to check for a newer release: bash .claude/%s/lib/pinned-install.sh status\n' "$PI_NS" >&2
  return 0
}

# --- uninstall -----------------------------------------------------------------------------------

cmd_uninstall() {
  local p=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) p="${2:-}"; shift 2 ;;
      *) _pi_err "uninstall: unknown option: $1"; return 2 ;;
    esac
  done
  [ -n "$p" ] || p="$(_pi_project_root)" || p=""
  [ -n "$p" ] || { _pi_err "uninstall: not in a git repository and --project was not given"; return 2; }
  p="$(cd "$p" && pwd)"
  [ "$(_pi_pin_mode "$p")" = pinned ] || { _pi_err "uninstall: this project has no pinned install"; return 10; }

  local rp; rp="$(_pi_receipt_path "$p")"
  [ -f "$rp" ] || { _pi_err "uninstall: no receipt at ${rp#"$p"/} — refusing to guess which files are ours"; return 10; }

  _pi_unwire_hooks "$p"
  _pi_strip_block "$p/AGENTS.md" || _pi_say "  WARN   could not strip the managed region from AGENTS.md"

  # REMOVE BY DIGEST. A file whose contents no longer match the receipt was changed after the
  # install, so it is the operator's now and is kept and named — an uninstaller that deletes work
  # it did not write is worse than one that leaves a file behind.
  local want rel have kept=0 gone=0
  while read -r want rel; do
    case "$want" in ''|'#'*) continue ;; esac
    [ -n "$rel" ] || continue
    [ -f "$p/$rel" ] || continue
    have="$(_pi_sha256 "$p/$rel" 2>/dev/null)" || have=""
    if [ "$have" = "$want" ]; then
      rm -f "$p/$rel" && gone=$((gone + 1))
    else
      kept=$((kept + 1)); _pi_say "  kept   $rel (locally modified)"
    fi
  done < "$rp"
  rm -f "$rp"

  # Prune the directories this install created, deepest first, and only when empty — so a project
  # file dropped into one of them is never taken with it.
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$p/$d" ] && rmdir "$p/$d" 2>/dev/null
  done <<EOF
$(cd "$p" && find .claude .codex .ai-dev-baseline -depth -type d 2>/dev/null | sed 's|^\./||')
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
