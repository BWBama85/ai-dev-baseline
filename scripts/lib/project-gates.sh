#!/usr/bin/env bash
# ai-dev-baseline — project gate detection + runner.
#
# Detects a repo's quality gates for the common ecosystems and either prints them
# or runs them. Honors a repo's agents.toml [gates] overrides, and — beyond the four
# built-in axes — an OPEN SET of custom gates, per-gate N/A, and per-gate path scope.
# Emits NOTHING when it can't find a supported ecosystem or any configured gate, so
# callers can safely no-op in unfamiliar repositories.
#
# The gate model
# --------------
#   * Built-in axes (auto-detected):  typecheck · lint · test · format
#   * Open set: any additional key in agents.toml [gates] (e.g. build, guards) is a
#     first-class gate that runs and blocks exactly like the built-in four.
#   * Per-gate state:
#       [gates] <label> = "cmd"   → run <cmd>
#       [gates] <label> = ""      → disabled (intentionally off; silently skipped)
#       [gates.state] <label> = "na"  → declared N/A (reported, skipped, never a failure)
#     "N/A" is distinct from a *detection miss* (an axis nothing detected and no override
#     is simply absent — no record), so a project like a stdlib-only tool can DECLARE it
#     has no lint/typecheck rather than looking like detection failed.
#   * Per-gate path scope (a changed-files condition):
#       [gates.scope] <label> = "apps/**,packages/**"
#     A scoped gate runs only when the change set touches a matching path. Scope is only
#     evaluated when a change set is supplied (the Stop-hook precommit-gate supplies it);
#     standalone `run` has no change set and therefore runs scoped gates unconditionally.
#
# Detection is single-primary-ecosystem: the FIRST ecosystem (Node → Rust → Go → Python)
# that yields at least one command wins, and the rest are skipped. A polyglot repo layers
# the second ecosystem's gates via the open-set [gates] override (see
# docs/per-project-overrides.md). Running every detected ecosystem's gates automatically
# is tracked as a follow-up (pluggable multi-ecosystem adapters).
#
# Standalone use:
#   bash project-gates.sh detect [root]   # prints "<label>\t<command>" for RUN gates only
#   bash project-gates.sh status [root]   # human-readable per-gate state (run/N/A/disabled)
#   bash project-gates.sh run    [root]   # runs them; nonzero exit on any failure
#
# Sourced use (from precommit-gate.sh):
#   . project-gates.sh   ;   adb_run_gates "$repo_root" "$changed_files"
#
# The `detect` output stays a two-column "<label>\t<command>" contract (RUN gates only);
# the richer per-gate state (N/A / disabled / scope) is surfaced by `status`, and consumed
# internally by adb_run_gates.

set -u

# Shared primitives (adb_toml_get / adb_toml_unquote / adb_toml_keys) live next to this
# file. At runtime this is ~/.<agent>/scripts/lib/common.sh (install.sh symlinks the whole
# scripts/lib dir there); run directly from the repo it is scripts/lib/common.sh.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"

# One literal TAB — the record field delimiter. A gate whose command or scope contains a
# tab is rejected (below) so the delimiter can never be forged.
_ADB_TAB="$(printf '\t')"
# A literal newline, for building/splitting newline-joined lists without a subshell.
_ADB_NL='
'
# The built-in gate axes, in emission order — the ONE place the axis set is named for the
# open-set exclusion below. (The four literal `_adb_emit <axis>` calls remain the canonical
# source scripts/check-fact-drift.sh derives from; adding an axis means updating both.)
_ADB_BUILTIN_AXES="typecheck lint test format"

_adb_have() { command -v "$1" >/dev/null 2>&1; }

# A valid gate label: starts with a letter, then letters/digits/underscore/hyphen. This
# keeps a label safe to use as an awk regex key, a TOML lookup, and a log filename.
_adb_valid_label() {
  case "$1" in
    [A-Za-z]*) case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}

_adb_has_tab() { case "$1" in *"$_ADB_TAB"*) return 0 ;; *) return 1 ;; esac; }

# Does package.json declare an npm script named $2? Prefer jq (exact .scripts membership);
# fall back to a scripts-block-scoped awk heuristic only when jq is unavailable.
_adb_pkg_has() {
  local root="$1" name="$2" pkg="$1/package.json"
  [ -f "$pkg" ] || return 1
  if _adb_have jq; then
    # Authoritative: is <name> a key of the .scripts OBJECT? A missing .scripts, a
    # non-object .scripts, or malformed JSON all make jq exit non-zero → treated as
    # "absent" (a safe no-op), so a dependency/devDependency named e.g. "test" never
    # produces a phantom gate.
    jq -e --arg name "$name" '(.scripts // {}) | has($name)' "$pkg" >/dev/null 2>&1
    return
  fi
  # jq absent → best-effort: only match a "<name>": key INSIDE the top-level "scripts"
  # object (brace depth tracked), so a top-level dependency named "test" no longer
  # false-matches. A minified single-line package.json is out of this heuristic's reach —
  # install jq for exact detection.
  awk -v name="$name" '
    BEGIN { depth = 0; inscripts = 0; found = 0 }
    inscripts == 0 && $0 ~ /"scripts"[[:space:]]*:[[:space:]]*\{/ { inscripts = 1; depth = 1; next }
    inscripts == 1 {
      if ($0 ~ ("\"" name "\"[[:space:]]*:")) found = 1
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")   # count braces (best-effort; ignores braces in strings)
      depth += o - c
      if (depth <= 0) inscripts = 2
    }
    END { exit(found ? 0 : 1) }
  ' "$pkg"
}

# --- gate records ------------------------------------------------------------
# The internal representation is one tab-separated record per gate:
#   <state>\t<label>\t<command>\t<scope>
# state ∈ { run, na, disabled }. Undetected axes (nothing detected, no override, no
# declared N/A) produce NO record — that is a detection miss, not a gate.

# Resolve one gate label (built-in or custom) against agents.toml and print its record,
# or nothing when the label resolves to a detection miss.
_adb_resolve_record() {
  local label="$1" default_cmd="$2" root="$3"
  local toml="$root/agents.toml"
  local cmd="" state="" scope="" raw

  _adb_valid_label "$label" || {
    printf 'project-gates: ignoring invalid gate label "%s"\n' "$label" >&2
    return 0
  }

  # command: an agents.toml [gates] override wins; present-but-empty ("") disables the
  # gate; absent falls through to the auto-detected default (built-ins only).
  if raw="$(adb_toml_get "$toml" gates "$label")"; then
    cmd="$(adb_toml_unquote "$raw")"
    [ -z "$cmd" ] && state="disabled"
  else
    cmd="$default_cmd"
  fi

  # explicit N/A: [gates.state] <label> = "na" | "n/a" (case-insensitive). Declared N/A
  # wins over everything else — the gate is reported, skipped, and never a failure.
  if raw="$(adb_toml_get "$toml" gates.state "$label")"; then
    case "$(adb_toml_unquote "$raw")" in
      [Nn][Aa]|[Nn]/[Aa]) state="na" ;;
    esac
  fi

  # Finalize an as-yet-undecided state: a command → run; nothing → a detection miss.
  if [ -z "$state" ]; then
    if [ -n "$cmd" ]; then state="run"; else return 0; fi
  fi

  # Path scope only matters for a gate that actually runs.
  if [ "$state" = run ] && raw="$(adb_toml_get "$toml" gates.scope "$label")"; then
    scope="$(adb_toml_unquote "$raw")"
  fi

  if _adb_has_tab "$label" || _adb_has_tab "$cmd" || _adb_has_tab "$scope"; then
    printf 'project-gates: ignoring gate "%s" (embedded tab in command/scope)\n' "$label" >&2
    return 0
  fi

  printf '%s\t%s\t%s\t%s\n' "$state" "$label" "$cmd" "$scope"
}

# Emit a built-in axis record. These four calls are the CANONICAL gate-axis list —
# scripts/check-fact-drift.sh derives the axes from `_adb_emit <axis>`, so keep them
# spelled literally.
_adb_emit() { _adb_resolve_record "$1" "$2" "$3"; }

# Print every gate record for a repo (built-in axes first, then open-set custom gates).
_adb_gate_records() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local toml="$root/agents.toml"
  local d_typecheck="" d_lint="" d_test="" d_format="" found=0 key

  # --- single-primary-ecosystem detection: first ecosystem that yields a command wins.
  if [ "$found" -eq 0 ] && [ -f "$root/package.json" ]; then
    local pm=npm
    [ -f "$root/pnpm-lock.yaml" ] && pm=pnpm
    [ -f "$root/yarn.lock" ]      && pm=yarn
    [ -f "$root/bun.lockb" ]      && pm=bun
    if _adb_have "$pm"; then
      _adb_pkg_has "$root" typecheck && d_typecheck="$pm run typecheck"
      _adb_pkg_has "$root" lint      && d_lint="$pm run lint"
      _adb_pkg_has "$root" test      && d_test="$pm run test"
      if   _adb_pkg_has "$root" "format:check"; then d_format="$pm run format:check"
      elif _adb_pkg_has "$root" format;         then d_format="$pm run format"
      fi
    fi
    [ -n "$d_typecheck$d_lint$d_test$d_format" ] && found=1
  fi
  if [ "$found" -eq 0 ] && [ -f "$root/Cargo.toml" ] && _adb_have cargo; then
    d_typecheck="cargo check --quiet"
    cargo clippy --version >/dev/null 2>&1 && d_lint="cargo clippy --quiet -- -D warnings"
    d_test="cargo test --quiet"
    d_format="cargo fmt --check"
    [ -n "$d_typecheck$d_lint$d_test$d_format" ] && found=1
  fi
  if [ "$found" -eq 0 ] && [ -f "$root/go.mod" ] && _adb_have go; then
    d_typecheck="go build ./..."
    d_lint="go vet ./..."
    d_test="go test ./..."
    # gofmt -l lists unformatted files; the subshell must expand at run time inside
    # `sh -c`, not now — single quotes are intentional here.
    # shellcheck disable=SC2016
    d_format='test -z "$(gofmt -l .)"'
    [ -n "$d_typecheck$d_lint$d_test$d_format" ] && found=1
  fi
  if [ "$found" -eq 0 ] && { [ -f "$root/pyproject.toml" ] || [ -f "$root/setup.py" ] || [ -f "$root/setup.cfg" ] || [ -f "$root/requirements.txt" ]; }; then
    _adb_have mypy && d_typecheck="mypy ."
    _adb_have ruff && d_lint="ruff check ."
    _adb_have ruff && d_format="ruff format --check ."
    if   _adb_have pytest;  then d_test="pytest -q"
    elif _adb_have python3; then d_test="python3 -m pytest -q"
    fi
    [ -n "$d_typecheck$d_lint$d_test$d_format" ] && found=1
  fi

  # Built-in axes — emit once each so an agents.toml override always wins (and can add a
  # built-in that detection missed). KEEP these `_adb_emit <axis>` calls literal.
  _adb_emit typecheck "$d_typecheck" "$root"
  _adb_emit lint      "$d_lint"      "$root"
  _adb_emit test      "$d_test"      "$root"
  _adb_emit format    "$d_format"    "$root"

  # Open set: every non-built-in key across [gates] (custom gates) and [gates.state]
  # (declared-N/A axes with no command) is a gate. Resolve the deduped union once —
  # [gates] keys first (file order), then any state-only key — so a key present in both
  # tables is emitted exactly once, and the built-in exclusion lives in one place.
  { adb_toml_keys "$toml" gates; adb_toml_keys "$toml" gates.state; } \
    | awk '!seen[$0]++' \
    | while IFS= read -r key; do
        case " $_ADB_BUILTIN_AXES " in *" $key "*) continue ;; esac
        _adb_resolve_record "$key" "" "$root"
      done
  return 0
}

# --- path scope --------------------------------------------------------------
# A scope is a comma-separated list of shell-`case` globs, where `*` matches across "/"
# (so "apps/*" matches "apps/x/y.js"). Match is any-path-against-any-glob.

# Does <path> ($2) match any glob in <globs> ($1, one per line, pre-trimmed)?
_adb_glob_list_match() {
  local globs="$1" path="$2" pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    # $pat is an intentional glob pattern here.
    # shellcheck disable=SC2254
    case "$path" in $pat) return 0 ;; esac
  done <<EOF
$globs
EOF
  return 1
}

# Does any path in <changeset> (newline-separated) match any pattern in <scope>
# (comma-separated)? Scope patterns are split + trimmed ONCE up front (they don't vary by
# path); a heredoc keeps each while-loop in the current shell so `return` exits here.
_adb_path_in_scope() {
  local scope="$1" changeset="$2" path pat prest globs=""
  prest="$scope"
  while [ -n "$prest" ]; do
    case "$prest" in
      *,*) pat="${prest%%,*}"; prest="${prest#*,}" ;;
      *)   pat="$prest"; prest="" ;;
    esac
    pat="${pat#"${pat%%[![:space:]]*}"}"   # trim leading whitespace
    pat="${pat%"${pat##*[![:space:]]}"}"   # trim trailing whitespace
    [ -n "$pat" ] && globs="$globs$pat$_ADB_NL"
  done
  [ -z "$globs" ] && return 1
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    _adb_glob_list_match "$globs" "$path" && return 0
  done <<EOF
$changeset
EOF
  return 1
}

# --- public surfaces ---------------------------------------------------------

# Print RUN gates as "<label>\t<command>" lines (or nothing). Back-compatible two-column
# contract — N/A / disabled / scope live in `status`, not here.
adb_detect_gates() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local state label cmd scope
  _adb_gate_records "$root" | while IFS="$_ADB_TAB" read -r state label cmd scope; do
    [ "$state" = run ] || continue
    printf '%s\t%s\n' "$label" "$cmd"
  done
}

# Human-readable per-gate state: run / N/A / disabled, with commands and scopes.
adb_status_gates() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local out
  out="$(_adb_gate_records "$root" | awk -F"$_ADB_TAB" '
    { state=$1; label=$2; cmd=$3; scope=$4
      if      (state=="run")      printf "%-12s run       %s%s\n", label, cmd, (scope!="" ? "   [scope: " scope "]" : "")
      else if (state=="na")       printf "%-12s N/A       (declared not-applicable)\n", label
      else if (state=="disabled") printf "%-12s disabled  (override \"\")\n", label
    }')"
  if [ -z "$out" ]; then
    printf 'no gates configured or detected\n'
  else
    printf '%s\n' "$out"
  fi
}

# Run every gate. Nonzero exit if any RUN gate fails (with a log tail on stderr). N/A and
# disabled gates are skipped (N/A is reported); a scoped gate is skipped when a change set
# is supplied and no changed path matches. Zero exit when no gates exist — a safe no-op in
# unknown repos. Usage: adb_run_gates <root> [changeset]
adb_run_gates() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local changeset="${2:-}"
  local records; records="$(_adb_gate_records "$root")"
  [ -z "$records" ] && return 0

  local tmp; tmp="$(mktemp -d 2>/dev/null || echo /tmp)"
  local failed="" state label cmd scope logf
  while IFS="$_ADB_TAB" read -r state label cmd scope; do
    [ -z "$label" ] && continue
    case "$state" in
      na)       printf 'adb: gate "%s": N/A (declared, skipped)\n' "$label" >&2; continue ;;
      disabled) continue ;;
    esac
    if [ -n "$scope" ] && [ -n "$changeset" ] && ! _adb_path_in_scope "$scope" "$changeset"; then
      printf 'adb: gate "%s": skipped (scope "%s" matched no changed file)\n' "$label" "$scope" >&2
      continue
    fi
    logf="$tmp/adb-gate-$label.log"
    if ! ( cd "$root" && sh -c "$cmd" ) >"$logf" 2>&1; then
      tail -c 4000 "$logf" >&2 || true
      printf '\nadb: gate "%s" failed (%s)\n' "$label" "$cmd" >&2
      failed="$failed$label "
    fi
  done <<EOF
$records
EOF
  rm -rf "$tmp" 2>/dev/null || true

  if [ -n "$failed" ]; then
    printf '\nadb: failing gates: %s\n' "$failed" >&2
    return 1
  fi
  return 0
}

# Dispatch only when executed directly, never when sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    detect) adb_detect_gates "${2:-}" ;;
    status) adb_status_gates "${2:-}" ;;
    run)    adb_run_gates    "${2:-}" ;;
    *) echo "usage: project-gates.sh [detect|status|run] [root]" >&2; exit 2 ;;
  esac
fi
