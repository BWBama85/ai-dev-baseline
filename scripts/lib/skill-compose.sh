#!/usr/bin/env bash
# ai-dev-baseline — the RETIRED partial skill override composer (#22, retired by #540).
#
# A project carries no skills of its own (policy:one-baseline, D148), and a composed
# `.claude/skills/<name>/SKILL.md` never ran where it could be built anyway: composing needs the
# global base skill, and Claude runs that personal skill over a same-named project one. So every
# subcommand refuses, naming why and where to go instead. The file stays at its installed path so
# a project gate that still calls `skill-compose check` gets that reason, not "command not found".
#
# Usage:
#   skill-compose.sh compose|check|list-anchors [...]   # refused: retired
#   skill-compose.sh -h | --help
#
# Exit codes: 0 help · 3 retired (every subcommand) · 2 no or unknown subcommand.

set -u

_adb_sc_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_sc_common" ]; then
  printf 'skill-compose: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_sc_common" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=/dev/null
. "$_adb_sc_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED: sourced, `$0` names the caller, which owns it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

adb_sc_usage() {
  cat <<'EOF'
skill-compose — RETIRED (#540, policy:one-baseline).

  A project carries no skills of its own, so partial overrides (overrides.md) are no longer
  composed. On Claude a same-named personal skill runs instead of a project one in any case.

  What to do instead:
    - make a project need a baseline issue, or project config (the root doc, agents.toml);
    - run /adopt: its `workflows` rung reports every overrides.md and composed SKILL.md left;
    - remove a gate that calls `skill-compose check` from agents.toml [gates].

  See docs/per-project-overrides.md.
EOF
}

adb_sc_main() {
  case "${1:-}" in
    -h|--help) adb_sc_usage; return 0 ;;
    compose|check|list-anchors)
      printf 'skill-compose: %s refused — the composer is retired (#540, policy:one-baseline); run with --help for what to do instead\n' "$1" >&2
      return 3 ;;
    '') printf 'skill-compose: expected a subcommand (retired: run with --help)\n' >&2; return 2 ;;
    *)  printf 'skill-compose: unknown subcommand (retired: run with --help)\n' >&2; return 2 ;;
  esac
}

# Execute only when run directly (never when sourced by a test or another script).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  adb_sc_main "$@"
  exit $?
fi
