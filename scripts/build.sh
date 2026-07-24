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
# metadata). Render each into EVERY agent's native skill form. All three agents
# (Claude, Codex, Antigravity/Gemini) converge on the agent-skills SKILL.md folder
# standard — `<agent-skills-dir>/<name>/SKILL.md` with YAML frontmatter — so one
# generic renderer serves them all, parameterised by three per-agent knobs:
#   - the placeholder MAP (each neutral {{TOKEN}} -> that agent's real token),
#   - the frontmatter MODE (see below),
#   - the output tree (agents/<agent>/skills/, symlinked to each agent's skills dir
#     by adb_agent_manifest in scripts/lib/common.sh).
# See docs/adding-an-agent.md and base/workflows/README.md's source contract.
#
# Two transforms happen (see base/workflows/README.md's source contract):
#   1. A generated-file marker is injected as YAML `#` comments right after the
#      opening `---`. It can't be an HTML banner like the root docs use — a SKILL.md
#      must start with `---` for the skill loaders and the CI skill-frontmatter
#      check, and a `#` comment inside the frontmatter is valid YAML all three accept.
#   2. Agent-neutral {{PLACEHOLDER}} tokens in the BODY are substituted to that
#      agent's real tokens (the MAP passed via -v below). The mapping is literal
#      (index/substr, never regex) and body-only. Any {{…}} that survives the map is
#      an unmapped placeholder — a fail-loud error, never emitted into a skill.
#
# Frontmatter MODE, the one place the agents genuinely differ:
#   - verbatim (Claude): the source frontmatter is streamed unchanged (only the marker
#     is injected), so Claude passthrough keys (allowed-tools, argument-hint, effort,
#     user-invocable, …) survive. Because the map reverses #16's neutralization exactly
#     and the frontmatter is untouched, the Claude render stays byte-for-byte what it
#     was before the bodies were neutralized; build-drift proves it every CI run.
#   - synth (Codex, Gemini): those surfaces honor only `name` + `description` (Codex's
#     `name` is implicit from the filename, but emitting it is harmless and keeps the
#     three renders uniform). The renderer emits a minimal `name` + `description`
#     frontmatter and DROPS the Claude-only passthrough keys, plus one caveat comment
#     noting that some body references still describe Claude-specific machinery whose
#     per-agent equivalents are tracked follow-ups (#14/#25).
render_agent_skill() {
  local agent="$1" src="$2" name out tmp first fmname
  local args_to state_dir gate_run role_dispatch current_agent subtask fmmode

  # --- the per-agent MAP + MODE ------------------------------------------------------
  # Only two knobs are genuinely a per-agent choice: the tracked-sub-task primitive and the
  # frontmatter mode. The other three tokens derive mechanically from the agent's dot-dir
  # (.<agent>/…), so they are computed ONCE below rather than restated per arm — and {{ARGS}}
  # is the same on every agent. For claude these derive to exactly the pre-#12/#13 literals, so
  # the render stays byte-for-byte (build-drift proves it).
  case "$agent" in
    claude) subtask='TaskCreate';  fmmode=verbatim ;;
    codex)  subtask='update_plan'; fmmode=synth ;;
    gemini) subtask='Create';      fmmode=synth ;;
    *) echo "build.sh: render_agent_skill: unknown agent '$agent'" >&2; exit 3 ;;
  esac
  args_to='$ARGUMENTS'
  state_dir=".$agent/state"
  gate_run="bash \"\$HOME/.$agent/scripts/lib/project-gates.sh\""
  role_dispatch="bash \"\$HOME/.$agent/scripts/lib/role-dispatch.sh\""
  roadmap_lib="bash \"\$HOME/.$agent/scripts/lib/roadmap-lib.sh\""
  current_agent="$agent"

  name="$(basename "$src" .md)"
  out="$root/agents/$agent/skills/$name/SKILL.md"

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
  # `description:` must be a single, non-empty line. The Codex/Gemini synth render captures ONLY
  # the `description:` line, so a folded/block scalar (`>`/`|`), a plain multi-line continuation,
  # or an empty value would silently drop content and ship a skill whose description — the field
  # that drives activation on those agents — is broken. Reject it at the source (agent-neutral,
  # so it fails uniformly for every agent, before anything is written). No-op for a normal
  # single-line description.
  descprob="$(awk '
    NR==1 { next }
    $0 == "---" { exit }
    seen { if ($0 ~ /^[[:space:]]/) print "a multi-line continuation"; exit }
    /^description:[[:space:]]*$/                     { print "empty"; exit }
    /^description:[[:space:]]*[>|][+-]?[[:space:]]*$/ { print "a folded/block scalar"; exit }
    /^description:/ { seen = 1 }
  ' "$src")"
  if [ -n "$descprob" ]; then
    echo "build.sh: base/workflows/$name.md has a non-single-line 'description:' ($descprob) — it must be one non-empty line (the Codex/Gemini render captures only that line)." >&2
    exit 3
  fi

  mkdir -p "$(dirname "$out")"
  # Render to a temp file and mv into place only on success — a failed render must
  # never truncate the existing SKILL.md, since install.sh symlinks each skill dir
  # and a zero-byte file here would break the live installed skill. Writes only this
  # one file; never clears or recreates the skills directory.
  tmp="$out.tmp"
  # The MAP is the four lreplace() calls below, fed the per-agent tokens via -v. Kept
  # literal (index/substr in awk, no regex) so tokens with $, ", and / substitute
  # cleanly. -v does no escape processing on these values (none contain backslashes),
  # so e.g. Claude's gate command emits its real quotes byte-for-byte.
  awk -v name="$name" -v fmmode="$fmmode" \
      -v args_to="$args_to" -v state_dir="$state_dir" \
      -v gate_run="$gate_run" -v role_dispatch="$role_dispatch" \
      -v roadmap_lib="$roadmap_lib" \
      -v current_agent="$current_agent" -v subtask="$subtask" '
    function lreplace(s, from, to,   out, p) {
      out = ""
      while ((p = index(s, from)) > 0) {
        out = out substr(s, 1, p - 1) to
        s = substr(s, p + length(from))
      }
      return out s
    }
    # marker() prints the shared generated-file banner (identical across agents).
    function marker() {
      print "# GENERATED FILE — do not edit by hand."
      print "# Source: base/workflows/" name ".md · Regenerate: scripts/build.sh"
      print "# Edits here are overwritten on the next build."
    }
    # NR==1 is the opening --- delimiter.
    #   verbatim: emit ---+marker, then stream the rest of the frontmatter unchanged
    #             (no substitution) until the closing --- so passthrough keys survive.
    #   synth:    consume the source frontmatter silently (capturing only description),
    #             then at the closing --- emit a fresh minimal name+description block.
    NR==1 {
      infm = 1
      if (fmmode == "verbatim") { print "---"; marker() }
      next
    }
    infm == 1 {
      if (fmmode == "verbatim") { print; if ($0 == "---") infm = 0; next }
      # synth: capture the (single-line) description; emit synthesized block at close.
      if ($0 ~ /^description:/) { desc = $0; sub(/^description:[[:space:]]*/, "", desc) }
      if ($0 == "---") {
        print "---"
        marker()
        print "# $ARGUMENTS below marks where THIS skill'\''s invocation arguments go (e.g. the issue/PR"
        print "# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,"
        print "# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell"
        print "# variable — fill it in when you run a step. Some other refs (Stop-hook gating,"
        print "# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25."
        print "name: " name
        print "description: " desc
        print "---"
        infm = 0
      }
      next
    }
    {
      line = $0
      line = lreplace(line, "{{ARGS}}",             args_to)
      line = lreplace(line, "{{STATE_DIR}}",        state_dir)
      line = lreplace(line, "{{GATE_RUNNER}}",      gate_run)
      line = lreplace(line, "{{ROLE_DISPATCH}}",    role_dispatch)
      line = lreplace(line, "{{ROADMAP_LIB}}",      roadmap_lib)
      line = lreplace(line, "{{CURRENT_AGENT}}",    current_agent)
      line = lreplace(line, "{{SUBTASK_PRIMITIVE}}", subtask)
      print line
    }
  ' "$src" > "$tmp"

  # Fail loud on any unresolved placeholder: {{…}} is reserved for the neutral vocabulary,
  # so a survivor means a body used a token the MAP does not define (a typo, or a new
  # placeholder added without a mapping in every agent's MAP). Emitting it into a skill would
  # ship a literal {{TOKEN}} to users, so refuse to publish — and don't mv, leaving the
  # tracked skill intact. A placeholder that leaks into synth frontmatter (a {{…}} in the
  # source `description:`) is caught here too, since the guard scans the whole rendered file.
  if LC_ALL=C grep -Fq '{{' "$tmp"; then
    echo "build.sh: unresolved placeholder(s) in the rendered '$agent' '$name' skill — every {{TOKEN}} used in a workflow body must have a mapping in build.sh's render_agent_skill:" >&2
    LC_ALL=C grep -Fn '{{' "$tmp" | sed 's/^/  /' >&2
    rm -f "$tmp"
    exit 3
  fi

  mv "$tmp" "$out"
  echo "wrote ${out#"$root"/}"
}

for wf in "$workflows"/*.md; do
  case "$(basename "$wf")" in README.md) continue ;; esac
  render_agent_skill claude "$wf"
  render_agent_skill codex  "$wf"
  render_agent_skill gemini "$wf"
done
