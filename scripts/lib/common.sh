# shellcheck shell=bash
# ai-dev-baseline — shared shell primitives (the ONE home).
#
# This library is the single implementation of the small shell primitives that
# otherwise get copy-pasted across the installer, uninstaller, per-agent adapters,
# agent-init, and the runtime gates. The framework's whole thesis is single-source +
# no-drift (docs/design-principles.md); this file is that thesis applied to its own
# shell code.
#
# It is SOURCED, never executed. Two execution contexts source it:
#   - install-time (runs from the repo): install.sh, uninstall.sh,
#     agents/<agent>/adapter.sh, bin/agent-init — source "$REPO/scripts/lib/common.sh".
#   - runtime (installed under ~/.<agent>/scripts/lib/): project-gates.sh,
#     precommit-gate.sh, implement-issue-gate.sh — source it as a sibling, because
#     install.sh symlinks the whole scripts/lib/ dir into ~/.<agent>/scripts/lib/.
#
# Contract, so a sourced library never surprises its caller:
#   - Portable to macOS bash 3.2 (no mapfile, no readlink -f, no associative arrays).
#   - Passes shellcheck --severity=warning -e SC1091.
#   - Depends on NO caller globals (REPO / BACKUP_DIR / HOME-relative state) — every
#     input is a function argument. ($HOME is read only to prettify log paths.)
#   - Sets NO shell options (no set -e/-u/pipefail) — it must not mutate the caller's
#     shell. It is written to be safe under a caller's `set -u`.

# Guard against double-sourcing (e.g. precommit-gate.sh sources this AND then sources
# project-gates.sh, which sources it again). Idempotent: the second source returns
# immediately, so function definitions are never re-run.
if [ -n "${_ADB_COMMON_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ADB_COMMON_SH_LOADED=1

# --- logging -----------------------------------------------------------------

# Print a status line. The one print helper, so even this trivial wrapper has a home.
adb_info() { printf '%s\n' "$*"; }

# --- symlink install / uninstall --------------------------------------------

# Back up an existing path (unless it is already our correct symlink), then symlink.
# Usage: adb_link <src> <dest> <backup_dir>
#   - dest is already the correct symlink → no-op.
#   - dest is a symlink elsewhere        → replace it.
#   - dest is a real file/dir            → move it under backup_dir (mirrored absolute
#                                          path) before linking.
# Idempotent: running twice produces the same end state with no duplicate backups.
#
# Fail-loud source guard (#48): if <src> does not exist (or is a dangling symlink), refuse
# LOUDLY and return non-zero WITHOUT touching <dest> — no backup, no removal, no link. A bad
# manifest entry must never silently leave a dangling install link or clobber a real dest; the
# caller propagates this status so the top-level installer exits non-zero (see install.sh).
adb_link() {
  local src="$1" dest="$2" backup_dir="$3"
  if [ ! -e "$src" ]; then
    printf 'adb_link: source does not exist: %s — refusing to link %s (dest left untouched)\n' \
      "$src" "$dest" >&2
    return 1
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      adb_info "  ok     ${dest/#$HOME/~}"
      return
    fi
    rm -f "$dest"
  elif [ -e "$dest" ]; then
    mkdir -p "$backup_dir$(dirname "$dest")"
    mv "$dest" "$backup_dir$dest"
    adb_info "  backup ${dest/#$HOME/~} → ${backup_dir/#$HOME/~}$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  adb_info "  link   ${dest/#$HOME/~} → ${src/#$HOME/~}"
}

# Remove dest ONLY if it is a symlink pointing back inside repo. Never deletes a real
# file or a symlink to somewhere else.
# Usage: adb_unlink_if_ours <dest> <repo>
adb_unlink_if_ours() {
  local dest="$1" repo="$2"
  if [ -L "$dest" ]; then
    case "$(readlink "$dest")" in
      "$repo"/*) rm -f "$dest"; adb_info "  unlink ${dest/#$HOME/~}" ;;
      *)         adb_info "  skip   ${dest/#$HOME/~} (not ours)" ;;
    esac
  else
    adb_info "  skip   ${dest/#$HOME/~} (not a symlink)"
  fi
}

# --- install manifest (the ONE enumeration of the install surface) -----------

# Print the install manifest for ONE agent token as TAB-separated "<src>\t<dest>" lines,
# given a repo/source root and a target home. This is the SINGLE source of what the install
# links (#48): install.sh + the per-agent adapters consume it to CREATE the links; uninstall.sh
# consumes the <dest> column to remove them; bin/baseline consumes it to VERIFY them. Because
# all four read the same producer, the create-set, remove-set, and verify-set can never drift
# (a path added/moved here changes every consumer at once).
#
# Spelling is canonical: absolute <src> with NO trailing slash (so bin/baseline's exact-readlink
# idempotency check is stable). scripts/lib is linked at its CANONICAL path (not the pre-#34
# compat shim) — a plain `git pull` keeps old installs working via that shim, and a re-run
# self-heals them to this direct link. Paths are assumed free of tabs/newlines (unsupported).
# An unknown token prints nothing (return 0). Usage: adb_agent_manifest <agent> <repo> <home>
# Emit "<src-skill-dir>\t<dest-parent>/<name>" manifest lines for every rendered skill folder
# under <src-skills-dir>. The ONE place the skill-folder enumeration convention lives (glob
# dirs; unmatched glob stays literal and is filtered by -d; canonical trailing-slash-free src
# so bin/baseline's exact-readlink idempotency check stays stable) — every agent's branch of
# adb_agent_manifest calls this rather than re-inlining the loop. Usage:
#   _adb_skill_manifest_lines <src-skills-dir> <dest-skills-parent>
_adb_skill_manifest_lines() {
  local src_dir="$1" dest_parent="$2" d sdir
  for d in "$src_dir"/*/; do
    [ -d "$d" ] || continue
    sdir="${d%/}"
    printf '%s\t%s\n' "$sdir" "$dest_parent/${sdir##*/}"
  done
}

adb_agent_manifest() {
  local agent="$1" repo="$2" home="$3" s
  case "$agent" in
    claude)
      printf '%s\t%s\n' "$repo/agents/claude/CLAUDE.md" "$home/.claude/CLAUDE.md"
      _adb_skill_manifest_lines "$repo/agents/claude/skills" "$home/.claude/skills"
      for s in precommit-gate.sh implement-issue-gate.sh statusline.sh; do
        printf '%s\t%s\n' "$repo/agents/claude/scripts/$s" "$home/.claude/scripts/$s"
      done
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.claude/scripts/lib"
      ;;
    codex)
      printf '%s\t%s\n' "$repo/agents/codex/AGENTS.md" "$home/.codex/AGENTS.md"
      # Rendered workflow skills (agent-skills SKILL.md folders) → Codex's skills dir, which
      # discovers ~/.codex/skills/<name>/SKILL.md.
      _adb_skill_manifest_lines "$repo/agents/codex/skills" "$home/.codex/skills"
      # The shared, agent-neutral gate runner (project-gates.sh + common.sh) so a rendered
      # workflow's {{GATE_RUNNER}} step (bash "$HOME/.codex/scripts/lib/project-gates.sh" run)
      # actually resolves. This is the runner only — NOT the Claude Stop-hook enforcement
      # (that per-agent equivalent is #14). Same source dir the claude branch links.
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.codex/scripts/lib"
      ;;
    gemini)
      printf '%s\t%s\n' "$repo/agents/gemini/GEMINI.md" "$home/.gemini/GEMINI.md"
      # Rendered workflow skills → Antigravity's GLOBAL customization root, ~/.gemini/config/
      # (agy discovers skills/<name>/SKILL.md there; confirmed in agy's own bundled
      # agy-customizations docs). The scripts/lib runner lives beside the other agents' at
      # ~/.gemini/scripts/lib so {{GATE_RUNNER}} resolves — see the codex note above.
      _adb_skill_manifest_lines "$repo/agents/gemini/skills" "$home/.gemini/config/skills"
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.gemini/scripts/lib"
      ;;
  esac
}

# Consume a manifest (TAB-separated "<src>\t<dest>" lines on stdin) and adb_link each entry,
# so column parsing lives in ONE place (install.sh and the adapters both call this rather than
# re-interpreting the columns). Accumulates failures: returns non-zero iff ANY line failed —
# a missing source (adb_link's guard) or a malformed line — so a caller propagates a single
# exit status. A blank line is skipped; a line missing either column is a hard failure (a
# malformed manifest must never silently link nothing). Usage: adb_link_manifest <backup_dir>
adb_link_manifest() {
  local backup_dir="$1" tab src dest rc=0
  tab="$(printf '\t')"
  while IFS="$tab" read -r src dest; do
    [ -n "$src$dest" ] || continue
    if [ -z "$src" ] || [ -z "$dest" ]; then
      printf 'adb_link_manifest: malformed manifest line (want <src>TAB<dest>): [%s|%s]\n' \
        "$src" "$dest" >&2
      rc=1; continue
    fi
    adb_link "$src" "$dest" "$backup_dir" || rc=1
  done
  return "$rc"
}

# Consume a manifest (TAB-separated "<src>\t<dest>" lines on stdin) and adb_unlink_if_ours each
# <dest> — the remove-side mirror of adb_link_manifest, so uninstall parses the manifest columns
# in the SAME one place install does (no drift between what is linked and what is removed). Only
# the <dest> column is used; ownership scoping is adb_unlink_if_ours's job (never removes a real
# file or a link pointing elsewhere). Usage: adb_unlink_manifest <repo>
adb_unlink_manifest() {
  local repo="$1" tab dest
  tab="$(printf '\t')"
  while IFS="$tab" read -r _ dest; do
    [ -n "$dest" ] || continue
    adb_unlink_if_ours "$dest" "$repo"
  done
}

# --- git ---------------------------------------------------------------------

# Resolve a repo's default branch: origin/HEAD → a local main/master → "main".
# Usage: adb_default_branch [root]   (root defaults to the current directory)
adb_default_branch() {
  local root="${1:-.}" b db
  db="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  if [ -z "$db" ]; then
    for b in main master; do
      if git -C "$root" show-ref --verify --quiet "refs/heads/$b"; then db="$b"; break; fi
    done
  fi
  [ -z "$db" ] && db="main"
  printf '%s\n' "$db"
}

# Classify a local branch's currency versus its origin/<branch> counterpart, using
# ONLY already-fetched refs — the CALLER must `git fetch` first (this function never
# touches the network, so it is safe to unit-test against a local bare "origin"). It
# prints exactly one status word and returns 0:
#   current   — local branch and origin/<branch> point at the same commit
#   behind    — origin/<branch> has commits the local branch lacks (fast-forwardable)
#   ahead     — the local branch has commits origin/<branch> lacks (unpushed)
#   diverged  — both sides have commits the other lacks
#   no-remote — origin/<branch> does not exist (nothing to compare against)
# Returns 1 (printing nothing) only on an internal git error, so a caller under
# `set -e` still sees a hard failure rather than a silent mis-classification.
# Usage: adb_branch_sync_state <root> <branch>
adb_branch_sync_state() {
  local root="$1" branch="$2" counts ahead behind
  if ! git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    printf 'no-remote\n'; return 0
  fi
  # `--left-right --count A...B` prints "<left>\t<right>": left = commits in A (local)
  # not in B (origin), right = commits in B not in A. awk splits on the tab robustly.
  counts="$(git -C "$root" rev-list --left-right --count "$branch...origin/$branch" 2>/dev/null)" || return 1
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  [ -n "$ahead" ] && [ -n "$behind" ] || return 1
  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then printf 'current\n'
  elif [ "$ahead" -eq 0 ]; then printf 'behind\n'
  elif [ "$behind" -eq 0 ]; then printf 'ahead\n'
  else printf 'diverged\n'
  fi
}

# --- minimal TOML reader -----------------------------------------------------

# Read one `key = value` from a named table of a TOML file. Prints the raw RHS value
# (trailing comment and surrounding whitespace stripped; quotes/brackets KEPT so the
# caller decides how to interpret a scalar vs. an array). Returns 0 when the key is
# present in the table (even if its value is an empty string ""), 1 when the file is
# missing or the key is absent — so callers can distinguish "unset" from "set to empty".
#
# Supports the subset the templates actually use: a `[table]` header, quoted scalar
# strings, and flat quoted-string arrays. Within a quoted scalar a `#` is preserved
# (only a comment OUTSIDE the string is stripped), and a backslash-escaped quote
# (`\"`) does NOT end the string — so a command with nested quotes survives verbatim,
# backslashes and all (escape *decoding* like `\"`→`"` is intentionally out of scope;
# the value is returned as written). Inline tables and multi-line values are out of
# scope (see docs/design-principles.md).
# Usage: adb_toml_get <file> <table> <key>
adb_toml_get() {
  local file="$1" table="$2" key="$3"
  [ -f "$file" ] || return 1
  awk -v tbl="$table" -v key="$key" '
    # A table header toggles whether we are inside the target table. The header name is
    # compared LITERALLY, not as a regex — so a dotted sub-table like [gates.scope] can
    # never accidentally match table "gatesXscope" via the "." metacharacter, and a
    # caller-supplied table name is never a regex-injection surface.
    /^[[:space:]]*\[/ {
      hdr = $0
      sub(/^[[:space:]]*\[/, "", hdr)   # drop leading whitespace + the opening "["
      sub(/\][[:space:]]*$/, "", hdr)   # drop the closing "]" + trailing whitespace
      intbl = (hdr == tbl)
      next
    }
    intbl && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)   # strip "key =" and the space after it
      if (substr(line, 1, 1) == "\"") {
        # Quoted scalar: walk to the closing quote, skipping backslash-escaped chars
        # (so \" does not close and # inside the string is not a comment). Reconstruct
        # the value with its outer quotes; the caller unquotes if it wants the bare form.
        rest = substr(line, 2); n = length(rest); i = 1; body = ""
        while (i <= n) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { body = body c substr(rest, i + 1, 1); i += 2; continue }
          if (c == "\"") break
          body = body c; i++
        }
        line = "\"" body "\""
      } else {
        sub(/[[:space:]]*#.*$/, "", line)      # unquoted / array: strip trailing comment
      }
      sub(/[[:space:]]*$/, "", line)           # strip trailing whitespace
      printf "%s", line
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Strip one layer of surrounding double quotes from a scalar TOML value.
# ("" → empty string; "pnpm test" → pnpm test). Leaves an array ([...]) untouched.
adb_toml_unquote() {
  local v="$1"
  v="${v#\"}"
  v="${v%\"}"
  printf '%s' "$v"
}

# List the bare identifier keys defined in a TOML table, one per line, in file order.
# Only keys matching [A-Za-z0-9_-]+ at the start of a line are returned (quoted keys and
# comment lines are skipped). Uses the SAME literal-table matching as adb_toml_get, so a
# request for table "gates" never leaks keys from a sub-table like [gates.scope]. Returns
# 0 even when the file is missing or the table is absent (prints nothing), so callers can
# iterate the output unconditionally. Usage: adb_toml_keys <file> <table>
adb_toml_keys() {
  local file="$1" table="$2"
  [ -f "$file" ] || return 0
  awk -v tbl="$table" '
    /^[[:space:]]*\[/ {
      hdr = $0
      sub(/^[[:space:]]*\[/, "", hdr)
      sub(/\][[:space:]]*$/, "", hdr)
      intbl = (hdr == tbl)
      next
    }
    intbl && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      k = $0
      sub(/^[[:space:]]*/, "", k)        # leading whitespace
      sub(/[[:space:]]*=.*$/, "", k)     # from the "=" onward
      print k
    }
  ' "$file"
}

# --- versions ----------------------------------------------------------------

# Compare dot-separated numeric versions. Returns 0 iff have >= want. Missing trailing
# components count as 0 (so 2.1 >= 2.1.0). Non-numeric junk in a component sorts as 0.
# Usage: adb_version_ge <have> <want>
adb_version_ge() {
  awk -v v="$1" -v min="$2" '
    BEGIN {
      nv = split(v, V, "."); nm = split(min, M, ".");
      n = (nv > nm) ? nv : nm;
      for (i = 1; i <= n; i++) {
        a = (i <= nv) ? V[i] + 0 : 0; b = (i <= nm) ? M[i] + 0 : 0;
        if (a > b) exit 0; if (a < b) exit 1;
      }
      exit 0;
    }'
}
