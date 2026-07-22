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
  local src="$1" name out tmp first fmname
  name="$(basename "$src" .md)"
  out="$root/agents/claude/skills/$name/SKILL.md"

  # Validate BEFORE writing anything. The source must start with a --- frontmatter
  # delimiter, and its `name:` must equal the file stem (which becomes the skill
  # directory). This rejects an empty source and a copied-but-not-renamed workflow
  # (e.g. diagnose.md still carrying `name: debug`) that would otherwise install a
  # misidentified or empty skill.
  first="$(head -n1 "$src")"
  if [ "$first" != "---" ]; then
    echo "build.sh: base/workflows/$name.md must start with a --- frontmatter delimiter" >&2
    exit 3
  fi
  fmname="$(awk '
    NR==1 { next }
    $0 == "---" { exit }
    /^name:[[:space:]]/ { sub(/^name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
  ' "$src")"
  if [ "$fmname" != "$name" ]; then
    echo "build.sh: base/workflows/$name.md frontmatter name '$fmname' must equal the file stem '$name'" >&2
    exit 3
  fi

  mkdir -p "$(dirname "$out")"
  # Render to a temp file and mv into place only on success — a failed render must
  # never truncate the existing SKILL.md, since install.sh symlinks each skill dir
  # and a zero-byte file here would break the live installed skill. Writes only this
  # one file; never clears or recreates the skills directory.
  tmp="$out.tmp"
  awk -v name="$name" '
    NR==1 {
      print "---"
      print "# GENERATED FILE — do not edit by hand."
      print "# Source: base/workflows/" name ".md · Regenerate: scripts/build.sh"
      print "# Edits here are overwritten on the next build."
      next
    }
    { print }
  ' "$src" > "$tmp"
  mv "$tmp" "$out"
  echo "wrote ${out#"$root"/}"
}

for wf in "$workflows"/*.md; do
  case "$(basename "$wf")" in README.md) continue ;; esac
  render_skill "$wf"
done
