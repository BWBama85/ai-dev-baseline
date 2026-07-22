#!/usr/bin/env bash
# ai-dev-baseline — assemble base/practices/*.md into each agent's generated
# root document (CLAUDE.md / AGENTS.md / GEMINI.md).
#
# base/practices/*.md is the single hand-edited source of truth. The per-agent
# root docs are GENERATED — run this after editing any practice, and commit the
# result. CI re-runs this and fails on drift, so a stale root doc can't merge.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
practices="$root/base/practices"

render() {
  local outfile="$1" title="$2"
  mkdir -p "$(dirname "$outfile")"
  {
    printf '<!-- GENERATED FILE — do not edit by hand.\n'
    printf '     Source: base/practices/*.md · Regenerate: scripts/build.sh\n'
    printf '     Edits here are overwritten on the next build. -->\n\n'
    printf '# %s\n\n' "$title"
    printf 'Your global engineering practices, shared across every project via\n'
    printf '[ai-dev-baseline](https://github.com/BWBama85/ai-dev-baseline).\n'
    printf 'A project-specific doc in the current repo overrides anything here\n'
    printf '(see base/practices/00-index.md for precedence).\n\n'
    printf -- '---\n\n'
    local f
    for f in "$practices"/*.md; do
      case "$(basename "$f")" in 00-index.md) continue ;; esac
      cat "$f"
      printf '\n\n---\n\n'
    done
    printf '_Generated from base/practices. The multi-agent role model lives in base/roles.md._\n'
  } > "$outfile"
  echo "wrote ${outfile#"$root"/}"
}

render "$root/agents/claude/CLAUDE.md" "Global engineering practices"
render "$root/agents/codex/AGENTS.md"  "Global engineering practices"
render "$root/agents/gemini/GEMINI.md" "Global engineering practices"
