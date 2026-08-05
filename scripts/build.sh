#!/usr/bin/env bash
# ai-dev-baseline — assemble base/practices/*.md into each agent's generated
# root document (CLAUDE.md / AGENTS.md / GEMINI.md).
#
# base/practices/*.md is the single hand-edited source of truth. The per-agent
# root docs are GENERATED — run this after editing any practice, and commit the
# result. CI re-runs this and fails on drift, so a stale root doc can't merge.

# bash 5.3 runtime floor (#256) — FIRST executable statement, before `set -e` and before anything
# resolves a path or reads input. adb_require_bash re-execs into a >= 5.3 interpreter or exits with
# the platform's install instructions.
#
# Before `set -euo pipefail`, and confirmed by PROBING FOR THE FUNCTION rather than by the source's
# exit status — the same idiom as the check-*.sh family, for the same two reasons. A sourced file
# returns its LAST command's status, so `. lib || exit 1` reports whatever that happened to be and
# says nothing about whether the file loaded; and under errexit a non-zero source aborts the script
# outright, which is the defect review found in statusline.sh.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
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
  local args_to state_dir gate_run role_dispatch roadmap_lib repo_settings cleanup_lib currency_lib pr_review
  local state_assert pr_watch actions_app_slug
  local current_agent subtask fmmode

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
  repo_settings="bash \"\$HOME/.$agent/scripts/lib/repo-settings.sh\""
  pr_review="bash \"\$HOME/.$agent/scripts/lib/pr-review.sh\""
  pr_watch="bash \"\$HOME/.$agent/scripts/lib/pr-watch.sh\""
  cleanup_lib="bash \"\$HOME/.$agent/scripts/lib/cleanup-lib.sh\""
  currency_lib="bash \"\$HOME/.$agent/scripts/lib/currency-lib.sh\""
  state_assert="bash \"\$HOME/.$agent/scripts/lib/state-assert.sh\""
  current_agent="$agent"
  # AGENT-INVARIANT, like {{ARGS}} — this is a GitHub fact, not a per-agent token (#183). A
  # workflow body is prose an agent pastes into a shell, so it can carry a VALUE but can never
  # source `common.sh` to ask for one. Before this token it restated `github-actions` inline, and
  # the only thing keeping that copy honest was an assertion in `check-roadmap.sh` matching the
  # jq text CHARACTER FOR CHARACTER — so reformatting the filter, or renaming a jq variable, broke
  # a test for a reason unrelated to correctness, and the natural repair was to edit the assertion.
  # That is a guard rotting into a rubber stamp. Deriving the value at build time makes the doc
  # track the constant the same way the libraries do via `--arg`.
  #
  # `adb_actions_app_slug` is already in scope: this file sources `scripts/lib/common.sh` at the
  # top for the bash-floor gate. #183 costed this token against "build.sh does not source
  # common.sh today"; that stopped being true in #256, so the token adds no coupling that the
  # interpreter gate has not already paid for.
  #
  # REFUSE AN EMPTY RESULT. `lreplace` would happily substitute "" and emit
  # `(.app.slug // "") == ""`, which matches exactly the check runs whose app CANNOT be identified
  # — the fail-OPEN `branch-health` fails loud about at runtime, silently baked into three shipped
  # skills instead. Same guard, same reason, one layer earlier.
  actions_app_slug="$(adb_actions_app_slug 2>/dev/null)" || actions_app_slug=""
  if [ -z "$actions_app_slug" ]; then
    echo "build.sh: adb_actions_app_slug is unavailable or empty — refusing to render {{ACTIONS_APP_SLUG}} as an empty string (it would match unattributable check runs)" >&2
    exit 3
  fi
  # Where THIS agent discovers skills — project-local first, then the user-global root. The two
  # are not derivable from `.$agent/skills`: Antigravity/Gemini discovers under a `config/`
  # customization root (see adb_agent_manifest in common.sh), so a workflow that resolved a skill
  # by guessing the Claude layout reports every installed Codex/Gemini skill missing.
  # Two tokens, not one joined list: the PROJECT root must be re-anchored to the git toplevel at
  # runtime (a monorepo package invokes from a subdirectory), and the USER root must stay QUOTED —
  # `$HOME` can contain whitespace, and an unquoted rendering word-splits it and reports a valid
  # installed skill missing. Codex also honours CODEX_HOME, so its default is only a fallback.
  # PROJECT-LOCAL discovery is agent-specific and is NOT assumed. A space-separated LIST, empty
  # when this agent has no established project-local skill discovery.
  #   * Claude resolves a repo's own `.claude/skills/<name>/` ahead of the global one
  #     (docs/per-project-overrides.md, Override 2a).
  #   * Codex loads `.codex/skills` AND `.agents/skills` from the repository — verified in review
  #     against Codex CLI 0.144.0-alpha.4 via `codex debug prompt-input`, which listed skills from
  #     both under "Available skills". That supersedes base/workflows/new-release.md's older claim
  #     that Codex "does NOT auto-load repo-local settings/rules/skills", which described the
  #     settings/rules mirror files, not skills.
  #   * Antigravity's project-local SKILL discovery is still unestablished -> empty, fail closed.
  case "$agent" in
    gemini) skills_subdirs="";                            skills_user_root="\"\$HOME/.gemini/config/skills\"" ;;
    codex)  skills_subdirs=".codex/skills .agents/skills"; skills_user_root="\"\${CODEX_HOME:-\$HOME/.codex}/skills\"" ;;
    *)      skills_subdirs=".$agent/skills";              skills_user_root="\"\$HOME/.$agent/skills\"" ;;
  esac
  # An AGENT-NATIVE registry probe, when one exists: it is the ground truth, because it accounts
  # for state the filesystem cannot show — a skill disabled via `[[skills.config]] enabled = false`
  # is omitted from Codex's registry while its SKILL.md sits right there. Prints one skill name per
  # line. Empty => no probe, fall back to the filesystem contract.
  case "$agent" in
    codex) skill_registry_probe="codex debug prompt-input" ;;
    *)     skill_registry_probe="" ;;
  esac
  # How a skill is INVOKED on this agent. Claude and Antigravity use a slash command; Codex's own
  # skill reference documents `$skill`. Rendering Claude's `/` into every agent means no marker
  # value can both validate and invoke on Codex — `/release` passes the check but is not the
  # invocation, and `$release` is rejected as undeclared.
  #
  # PROVENANCE: the Codex value comes from its bundled skill reference as cited in review, not from
  # anything verifiable in this tree. If it is wrong, THIS LINE is the single place to correct it —
  # which is the point of rendering it rather than hardcoding a prefix in the workflow body.
  case "$agent" in
    codex) skill_prefix='$' ;;
    *)     skill_prefix='/' ;;
  esac
  # The EXTRA frontmatter key this agent's loader requires beyond name+description. Claude also
  # needs `user-invocable` (see selfcheck's skill-frontmatter step); Codex and Antigravity honour
  # only the two. A skill missing its loader's required key is not registered, so certifying it
  # would emit an unrunnable command.
  case "$agent" in
    claude) skill_extra_key='user-invocable' ;;
    *)      skill_extra_key='' ;;
  esac

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
      -v roadmap_lib="$roadmap_lib" -v repo_settings="$repo_settings" \
      -v cleanup_lib="$cleanup_lib" -v currency_lib="$currency_lib" \
      -v pr_review="$pr_review" -v state_assert="$state_assert" \
      -v pr_watch="$pr_watch" -v actions_app_slug="$actions_app_slug" \
      -v current_agent="$current_agent" -v subtask="$subtask" \
      -v skills_subdirs="$skills_subdirs" -v skills_user_root="$skills_user_root" \
      -v skill_prefix="$skill_prefix" -v skill_extra_key="$skill_extra_key" \
      -v skill_registry_probe="$skill_registry_probe" '
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
      line = lreplace(line, "{{REPO_SETTINGS_LIB}}", repo_settings)
      line = lreplace(line, "{{PR_REVIEW_LIB}}",    pr_review)
      line = lreplace(line, "{{PR_WATCH_LIB}}",     pr_watch)
      line = lreplace(line, "{{CLEANUP_LIB}}",      cleanup_lib)
      line = lreplace(line, "{{CURRENCY_LIB}}",     currency_lib)
      line = lreplace(line, "{{STATE_ASSERT_LIB}}", state_assert)
      line = lreplace(line, "{{ACTIONS_APP_SLUG}}", actions_app_slug)
      line = lreplace(line, "{{CURRENT_AGENT}}",    current_agent)
      line = lreplace(line, "{{SKILLS_SUBDIRS}}",   skills_subdirs)
      line = lreplace(line, "{{SKILLS_USER_ROOT}}", skills_user_root)
      line = lreplace(line, "{{SKILL_PREFIX}}",     skill_prefix)
      line = lreplace(line, "{{SKILL_EXTRA_KEY}}",  skill_extra_key)
      line = lreplace(line, "{{SKILL_REGISTRY_PROBE}}", skill_registry_probe)
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
