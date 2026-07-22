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
adb_link() {
  local src="$1" dest="$2" backup_dir="$3"
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
    # A table header toggles whether we are inside the target table.
    /^[[:space:]]*\[/ {
      intbl = ($0 ~ ("^[[:space:]]*\\[" tbl "\\][[:space:]]*$"))
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
