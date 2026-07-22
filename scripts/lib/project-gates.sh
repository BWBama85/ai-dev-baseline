#!/usr/bin/env bash
# ai-dev-baseline — project gate detection + runner.
#
# Detects a repo's quality gates (typecheck / lint / test / format) for the
# common ecosystems and either prints them or runs them. Honors a repo's
# agents.toml [gates] overrides. Emits NOTHING when it can't find a supported
# ecosystem, so callers can safely no-op in unfamiliar repositories.
#
# Standalone use:
#   bash project-gates.sh detect [root]   # prints "<label>\t<command>" lines
#   bash project-gates.sh run    [root]   # runs them; nonzero exit on any failure
#
# Sourced use (from precommit-gate.sh):
#   . project-gates.sh   ;   adb_run_gates "$repo_root"

set -u

# Shared primitives (adb_toml_get / adb_toml_unquote) live next to this file. At
# runtime this is ~/.<agent>/scripts/lib/common.sh (install.sh symlinks the whole
# scripts/lib dir there); run directly from the repo it is scripts/lib/common.sh.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"

_adb_have() { command -v "$1" >/dev/null 2>&1; }

# Does package.json declare an npm script named $2?
_adb_pkg_has() { grep -Eq "\"$2\"[[:space:]]*:" "$1/package.json" 2>/dev/null; }

# Emit one gate line, letting an agents.toml [gates] override win over the default.
# The override reader is the shared adb_toml_get: present-but-empty ("") disables the
# gate, absent falls through to the detected default.
_adb_emit() {
  local label="$1" default_cmd="$2" root="$3" ov
  if ov="$(adb_toml_get "$root/agents.toml" gates "$label")"; then
    ov="$(adb_toml_unquote "$ov")"
    # Present: a non-empty override replaces the default; "" disables the gate.
    [ -n "$ov" ] && printf '%s\t%s\n' "$label" "$ov"
  else
    # Absent: fall through to the auto-detected default (if any).
    [ -n "$default_cmd" ] && printf '%s\t%s\n' "$label" "$default_cmd"
  fi
}

# Print detected gates as "<label>\t<command>" lines (or nothing).
adb_detect_gates() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local d_typecheck="" d_lint="" d_test="" d_format=""

  if [ -f "$root/package.json" ]; then
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
  elif [ -f "$root/Cargo.toml" ] && _adb_have cargo; then
    d_typecheck="cargo check --quiet"
    cargo clippy --version >/dev/null 2>&1 && d_lint="cargo clippy --quiet -- -D warnings"
    d_test="cargo test --quiet"
    d_format="cargo fmt --check"
  elif [ -f "$root/go.mod" ] && _adb_have go; then
    d_typecheck="go build ./..."
    d_lint="go vet ./..."
    d_test="go test ./..."
    # gofmt -l lists unformatted files; the subshell must expand at run time
    # inside `sh -c`, not now — single quotes are intentional here.
    # shellcheck disable=SC2016
    d_format='test -z "$(gofmt -l .)"'
  elif [ -f "$root/pyproject.toml" ] || [ -f "$root/setup.py" ] || [ -f "$root/setup.cfg" ] || [ -f "$root/requirements.txt" ]; then
    _adb_have mypy && d_typecheck="mypy ."
    _adb_have ruff && d_lint="ruff check ."
    _adb_have ruff && d_format="ruff format --check ."
    if   _adb_have pytest;  then d_test="pytest -q"
    elif _adb_have python3; then d_test="python3 -m pytest -q"
    fi
  fi

  # Emit once for every label so agents.toml overrides always win — and can add a
  # gate that detection missed (e.g. a Makefile repo with no recognized ecosystem).
  _adb_emit typecheck "$d_typecheck" "$root"
  _adb_emit lint      "$d_lint"      "$root"
  _adb_emit test      "$d_test"      "$root"
  _adb_emit format    "$d_format"    "$root"
  return 0
}

# Run every detected gate. Nonzero exit if any fails (with a log tail on stderr).
# Zero exit (success) when no gates are detected — safe no-op in unknown repos.
adb_run_gates() {
  local root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local lines; lines="$(adb_detect_gates "$root")"
  [ -z "$lines" ] && return 0

  local tmp; tmp="$(mktemp -d 2>/dev/null || echo /tmp)"
  local failed="" label cmd logf
  while IFS="$(printf '\t')" read -r label cmd; do
    [ -z "$label" ] && continue
    logf="$tmp/adb-gate-$label.log"
    if ! ( cd "$root" && sh -c "$cmd" ) >"$logf" 2>&1; then
      tail -c 4000 "$logf" >&2 || true
      printf '\nadb: gate "%s" failed (%s)\n' "$label" "$cmd" >&2
      failed="$failed$label "
    fi
  done <<EOF
$lines
EOF

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
    run)    adb_run_gates    "${2:-}" ;;
    *) echo "usage: project-gates.sh [detect|run] [root]" >&2; exit 2 ;;
  esac
fi
