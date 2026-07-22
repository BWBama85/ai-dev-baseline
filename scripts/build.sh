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
workflows="$root/base/workflows"

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

# base/workflows/<name>.md is the single source for each workflow (procedure +
# metadata). Render each into the Claude agent's native skill form. Codex/Gemini
# renderers plug in here the same way — see docs/adding-an-agent.md.
#
# The Claude skill format IS the reference form, so the render is near-verbatim:
# the source is emitted unchanged except for a generated-file marker injected as
# YAML `#` comments right after the opening `---`. It can't be an HTML banner like
# the root docs use — a SKILL.md must start with `---` for Claude's skill loader
# and the CI skill-frontmatter check, and a `#` comment inside the frontmatter is
# valid YAML that both already accept.
render_skill() {
  local src="$1" name out
  name="$(basename "$src" .md)"
  out="$root/agents/claude/skills/$name/SKILL.md"
  mkdir -p "$(dirname "$out")"
  # Writes only this one SKILL.md; never clears or recreates the skills directory
  # (install.sh symlinks each skill dir, so a wholesale rebuild would break links).
  awk -v name="$name" '
    NR==1 {
      if ($0 != "---") {
        printf "build.sh: base/workflows/%s.md must start with a --- frontmatter delimiter\n", name > "/dev/stderr"
        exit 3
      }
      print "---"
      print "# GENERATED FILE — do not edit by hand."
      print "# Source: base/workflows/" name ".md · Regenerate: scripts/build.sh"
      print "# Edits here are overwritten on the next build."
      next
    }
    { print }
  ' "$src" > "$out"
  echo "wrote ${out#"$root"/}"
}

for wf in "$workflows"/*.md; do
  case "$(basename "$wf")" in README.md) continue ;; esac
  render_skill "$wf"
done
