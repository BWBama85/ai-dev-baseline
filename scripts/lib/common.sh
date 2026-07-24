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

# Print a CLI's --help text from its own top comment block: skip the shebang (NR==1), strip a
# leading "# ", stop at the first non-comment line (so internal section comments never leak). The
# ONE home for this idiom — bin/baseline and scripts/lib/skill-compose.sh both call it with their
# own file rather than each carrying a copy. Usage: adb_usage <file>   (e.g. adb_usage "$0")
adb_usage() { awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"; }

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

# Resolve the repo root the caller is in: the git top-level, else the current directory (so a
# runtime helper works both inside a checkout and in a throwaway non-git dir, e.g. a unit test).
# The ONE home for this idiom — role-dispatch.sh and project-gates.sh both call it rather than
# re-inlining `git rev-parse --show-toplevel 2>/dev/null || pwd`. Usage: adb_repo_root
adb_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# True (0) iff <dir> holds a recognizable project manifest — the signal adb_repo_shape uses to
# tell a real nested project root (a monorepo package, a nested app) from a bare, stray root doc.
# A `CLAUDE.md` sitting next to a `package.json` is a project; one sitting alone (e.g. this
# framework's own GENERATED agents/<agent>/CLAUDE.md) is not. Deliberately a common-ecosystem
# list; extend as new stacks appear. project-gates.sh carries a DELIBERATELY separate manifest
# list — it answers "which gate command runs" (gated on tool availability), not this "is this a
# project root" structural question, so the two are intentionally not unified. The lists may drift;
# that is accepted. Usage: _adb_has_project_manifest <dir>
_adb_has_project_manifest() {
  local d="$1" m
  for m in package.json pnpm-workspace.yaml composer.json Cargo.toml go.mod pyproject.toml \
           setup.py build.gradle build.gradle.kts pom.xml; do
    [ -f "$d/$m" ] && return 0
  done
  return 1
}

# Report the SHAPE of the repo a starting dir sits in, so tooling can tolerate the messy real
# world — working-dir ≠ git-root, nested repos, a repo dropped inside an untracked parent tree,
# and layered/multiple root docs — instead of assuming a tidy single-root state (#23). Prints
# TAB-separated "<key>\t<value>" facts on stdout, one per line, and ALWAYS returns 0 (a shape is
# descriptive, never an error) — but an unknown never masquerades as a clean answer: an
# unreadable start emits `warning`, and a scan that hits its depth bound emits `scan_truncated`,
# so "couldn't tell" is visible rather than silently collapsing to "nothing found".
#
# Facts (a stable TSV schema; consumers should ignore keys they don't know):
#   in_git         1 if the start dir is inside a git work tree, else 0
#   root           the resolved project root — the git top-level, else the start dir
#   cwd_is_root    1 if the start dir IS that root, else 0 (i.e. working dir is below the git root)
#   parent_in_git  1 if root's parent dir is itself inside ANY git repo, else 0
#   nested_in <p>  emitted once, iff root is nested inside a DIFFERENT enclosing git repo (its root)
#   foreign_doc <p>  0..n, nearest-first: a root doc (CLAUDE.md/AGENTS.md/GEMINI.md) found ABOVE
#                    root — outside this repo, referenced by relative path yet invisible to any
#                    git-aware tool. The walk includes an enclosing repo root (nested_in) and then
#                    stops there; else it climbs to / or a depth bound.
#   extra_doc <p>    0..n: an ADDITIONAL tracked root doc strictly BELOW root that also sits beside
#                    a project manifest (a monorepo/layered signal). git ls-files keeps it
#                    tracked-only + vendor-clean; the top-level root doc itself is never listed.
#   scan_truncated <n>  the upward foreign_doc walk stopped at its depth bound <n> without reaching
#                    / or an enclosing repo — a doc higher up may exist but was not scanned.
#   warning <msg>  a non-fatal problem (e.g. the start dir is unreadable) worth surfacing.
#
# Every path is canonicalized PHYSICALLY (`pwd -P`, resolving symlinks) before comparison, because
# `git rev-parse --show-toplevel` returns a physical path (on macOS `mktemp` gives /var/… while git
# reports /private/var/…) — without this, cwd_is_root would mis-compare. The caller's own working
# directory is never changed (all cd's run in subshells). Paths containing a TAB or newline are
# unsupported (same assumption as adb_agent_manifest). A superproject's `git ls-files` cannot see
# docs inside a submodule/gitlink — such nested docs are not enumerated by extra_doc.
# Usage: adb_repo_shape [start_dir]   (start_dir defaults to the current directory)
adb_repo_shape() {
  local start="${1:-$PWD}" abs root parent parent_root in_git=0 parent_in_git=0 nested_in=""
  local dir depth max=8 doc up truncated rel base mdir

  # Canonicalize the start dir physically; a subshell keeps the caller's cwd intact. An
  # unresolvable start is a `warning`, not a silent empty result.
  abs="$(cd "$start" 2>/dev/null && pwd -P)"
  if [ -z "$abs" ]; then
    printf 'in_git\t0\n'
    printf 'root\t%s\n' "$start"
    printf 'cwd_is_root\t1\n'
    printf 'parent_in_git\t0\n'
    printf 'warning\tstart directory does not exist or is unreadable: %s\n' "$start"
    return 0
  fi
  start="$abs"

  # `git -C <physical dir> rev-parse --show-toplevel` returns a physical (symlink-resolved) path,
  # so — because `start` is already physical — root and parent_root need no further `pwd -P`.
  if root="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
    in_git=1
  else
    root="$start"
  fi
  printf 'in_git\t%s\n' "$in_git"
  printf 'root\t%s\n' "$root"
  if [ "$start" = "$root" ]; then printf 'cwd_is_root\t1\n'; else printf 'cwd_is_root\t0\n'; fi

  parent="$(dirname "$root")"
  # Is root's parent inside ANY git repo? If so and that repo's top-level differs from root, root
  # is NESTED inside it. (root's own .git lives below parent, so a parent match is always a
  # DIFFERENT, enclosing repo — never root itself.) Compute the flag once, emit once.
  parent_in_git=0
  if [ "$in_git" -eq 1 ] && [ "$parent" != "$root" ] \
     && parent_root="$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$parent_root" ]; then
    parent_in_git=1
    if [ "$parent_root" != "$root" ]; then
      nested_in="$parent_root"
      printf 'nested_in\t%s\n' "$parent_root"
    fi
  fi
  printf 'parent_in_git\t%s\n' "$parent_in_git"

  # foreign_doc: root docs ABOVE root, nearest-first. Check each ancestor (including an enclosing
  # repo root, then stop there); else climb to / or the depth bound. truncated stays 1 only if the
  # bound is what stopped us, so scan_truncated discloses a possibly-unscanned higher doc.
  if [ "$in_git" -eq 1 ] && [ "$parent" != "$root" ]; then
    dir="$parent"; depth=0; truncated=1
    while [ "$depth" -lt "$max" ]; do
      for doc in CLAUDE.md AGENTS.md GEMINI.md; do
        [ -f "$dir/$doc" ] && printf 'foreign_doc\t%s\n' "$dir/$doc"
      done
      if [ -n "$nested_in" ] && [ "$dir" = "$nested_in" ]; then truncated=0; break; fi
      up="$(dirname "$dir")"
      if [ "$up" = "$dir" ]; then truncated=0; break; fi
      dir="$up"; depth=$((depth + 1))
    done
    [ "$truncated" -eq 1 ] && printf 'scan_truncated\t%s\n' "$max"
  fi

  # extra_doc: tracked root docs strictly below root that sit beside a project manifest. `-z`
  # output + shell filtering avoids an ambiguous CLAUDE.md pathspec; only .md is enumerated for
  # speed. Only printf's inside the pipe's subshell, so no state needs to survive it.
  if [ "$in_git" -eq 1 ]; then
    git -C "$root" ls-files -z -- '*.md' 2>/dev/null | while IFS= read -r -d '' rel; do
      base="${rel##*/}"
      case "$base" in CLAUDE.md|AGENTS.md|GEMINI.md) : ;; *) continue ;; esac
      case "$rel" in */*) : ;; *) continue ;; esac   # strictly below root (has a path separator)
      mdir="$root/${rel%/*}"
      _adb_has_project_manifest "$mdir" && printf 'extra_doc\t%s\n' "$root/$rel"
    done
  fi
  return 0
}

# Read value(s) for <key> from a TAB-separated "<key>\t<value>" facts blob (as produced by
# adb_repo_shape) — the ONE home for reading the shape TSV, so the delimiter/column contract lives
# in a single place instead of being re-inlined in each consumer (agent-init, tests, and the
# deferred per-skill preflight all call these rather than hand-writing the awk). adb_shape_val
# prints the FIRST match (empty if none); adb_shape_all prints EVERY match, one per line, for a
# repeatable key (foreign_doc / extra_doc / warning).
# Usage: adb_shape_val <facts> <key> ; adb_shape_all <facts> <key>
adb_shape_val() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }
adb_shape_all() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2}'; }

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

# Parse a flat TOML array literal (as returned RAW by adb_toml_get — outer brackets and
# per-element quotes KEPT, e.g. `["claude", "gemini"]`) into its bare string elements, one
# per line: surrounding quotes and whitespace stripped, empty elements dropped. A scalar
# (a value not starting with `[`) prints nothing, and an empty array `[]` prints nothing —
# so a caller distinguishes "unset" (adb_toml_get returned 1) from "set to []" (adb_toml_get
# returned 0 but this prints nothing). Only the single-line, comma-separated quoted-string
# array the templates use is supported (matching adb_toml_get's own scope); an element may
# itself contain `[`/`]` (e.g. a `foo[bot]` login) because the outer close is found as the
# LAST `]`. Elements containing a literal comma are out of scope. Usage: adb_toml_array <raw>
adb_toml_array() {
  awk -v s="$1" '
    BEGIN {
      if (substr(s, 1, 1) != "[") exit 0        # not an array literal → no elements
      s = substr(s, 2)                           # drop the opening "["
      pos = 0                                     # find the LAST "]" (the array close)
      for (i = length(s); i >= 1; i--) { if (substr(s, i, 1) == "]") { pos = i; break } }
      if (pos > 0) s = substr(s, 1, pos - 1)
      m = split(s, parts, ",")
      for (j = 1; j <= m; j++) {
        e = parts[j]
        gsub(/^[[:space:]]+/, "", e); gsub(/[[:space:]]+$/, "", e)   # trim outer whitespace
        sub(/^"/, "", e); sub(/"$/, "", e)                            # strip one quote layer
        gsub(/^[[:space:]]+/, "", e); gsub(/[[:space:]]+$/, "", e)   # trim inside the quotes
        if (e != "") print e
      }
    }'
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
