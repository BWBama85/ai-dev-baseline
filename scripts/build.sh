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

# Publishing a generated file is ONE operation with two halves — stage a temp beside the
# destination, then rename it into place (#268) — and both renderers call the same pair. Written
# once rather than twice, because two copies of a write rule disagreeing is the entire subject of
# this issue.
#
# THE TEMP NAME IS UNIQUE PER PROCESS, not a fixed `$dest.tmp`, and that is not tidiness. Two builds
# over one checkout — a contributor running `build.sh` while selfcheck's `build-drift` step runs
# one — would share a fixed name, and the interleaving PUBLISHES a torn file rather than preventing
# one: A creates the temp, B clears the name and creates its own, A renames B's half-written file
# over the destination. That is precisely the corruption this fix exists to remove, so it must not
# leave a path back to it. `mktemp` also closes a hole a fixed name cannot: clearing a path and then
# opening it are two operations, so anything that installs a symlink in between is followed by the
# redirect and then renamed over the tracked file. `mktemp` creates with O_EXCL under a name nothing
# can predict, so there is no window and no symlink to follow.
#
# The trap removes whatever is in flight however this script ends. Without it an abort leaves the
# temp behind, and no guard here would name it: `.gitignore` does not cover it, `build-drift`'s
# untracked scan looks only under the skill trees, and `check-tmp-paths.sh` is a content scan a
# well-formed render fragment passes.
#
# A BARE `EXIT` TRAP IS ENOUGH, and that is measured rather than assumed. On bash 5.3.15 it runs
# for SIGINT delivered the way a terminal delivers it (to the process group), for SIGTERM and for
# SIGHUP, and the script still exits 130 / 143 / 129 — so the INT/TERM/HUP handlers that would have
# to re-raise the signal to preserve that status buy nothing and can only get the status wrong. An
# EXIT trap returning 0 does NOT overwrite a failing script's status either, so cleanup cannot mask
# an errexit abort. SIGKILL and power loss remain untrappable; they leave a temp and, which is the
# whole point, an INTACT tracked file.
#
# Cleanup is BEST-EFFORT and says nothing: if the removal fails, the command that already failed has
# printed the reason, and a second line from the trap only buries it. `|| :` for the same reason — a
# cleanup that cannot run must not become the script's verdict.
build_tmp=''
build_cleanup() { if [ -n "$build_tmp" ]; then rm -f "$build_tmp" 2>/dev/null || :; fi; }
trap build_cleanup EXIT

# build_stage <destination> — create an exclusive temp beside it and record it in `build_tmp`.
#
# SETS A GLOBAL RATHER THAN PRINTING THE PATH, deliberately: `t="$(build_stage …)"` would run the
# function in a SUBSHELL, so the assignment the trap depends on would be discarded at the closing
# paren and an interrupted build would leak the very file this records. The caller reads
# `$build_tmp`.
#
# The mode is CHOSEN, not inherited. `mktemp` creates 0600, and the truncate-and-write this replaces
# inherited the destination's mode — so publishing straight from the temp would silently narrow
# every generated doc. Taking the caller's umask instead is the same problem pointing the other way:
# a permissive umask yields group- or world-writable instruction files, and since git records no
# difference among non-executable modes, nothing in this repo would ever notice. 644 is what a fresh
# checkout has, and it is the only value that does not depend on ambient state.
build_stage() {
  local dest="$1"
  build_tmp="$(mktemp "$dest.tmp.XXXXXX")" || return 1
  chmod 644 "$build_tmp" || return 1
}

# build_publish <destination> — rename the staged temp into place and drop the trap's record, so a
# later failure in the same run cannot delete a file that is already published.
build_publish() { mv "$build_tmp" "$1" && build_tmp=''; }

# The agent tokens THIS renderer knows. Its one consumer is block_filter's validator below: a
# marker naming an unknown token is a typo, and a typo that silently resolved to "everyone" is
# precisely the quiet failure this facility must not have.
#
# NOT a single-sourcing of the agent set, deliberately. The three `render` calls, the three
# `render_agent_skill` calls and that function's own per-agent `case` arms each still name their
# agents; consolidating them is #61's job and touching it here would restructure the agent model
# twice. This constant is a CONSUMER of the set, not its new owner.
build_known_agents='claude codex gemini'

# block_filter <agent> <file> — emit <file> with its per-agent blocks resolved for <agent>.
#
# THE ONE HOME for per-agent instruction density (#304), and both renderers call it: the root-doc
# `render()` immediately below, and `render_agent_skill()` further down. Both, because the density
# to be varied lives on both paths — `base/practices/self-review.md` renders through the first and
# `base/workflows/implement-issue.md` through the second — and two copies of an inclusion rule that
# had drifted apart would be exactly what this repo exists to prevent.
#
# THE GRAMMAR IS ONE FORM:
#
#     <!-- adb:except claude -->
#     …block…
#     <!-- adb:end -->
#
# The block renders for every known agent EXCEPT those listed. There is deliberately no `only`
# form: `except` is what every shipped source needs, and a second spelling with no consumer is a
# silently dead knob. It also picks the safe default for an agent nobody has considered yet — a
# fourth agent added tomorrow INHERITS every block, i.e. today's density unchanged, rather than
# silently receiving whatever the most stripped-down render happens to be.
# `docs/adding-an-agent.md` asks that adder to choose deliberately; this is what it defaults to.
#
# WHAT MAY GO IN A BLOCK — stated here because nothing in this file can enforce it: verification
# and scope INSTRUCTION DENSITY only. The procedure, the gates and the state protocol are shared
# content and must render identically to every agent. A rendered doc may differ in how much it is
# told to double-check; it must never differ in what it does. That is a constraint on the author,
# not a mechanism, and saying so plainly is better than implying a check that does not exist.
#
# EVERY MALFORMED SPELLING FAILS THE BUILD (rc 3), because a marker parser's failure mode is
# silence — a block that matches nothing renders exactly like a block that was correctly included.
# Rejected: an unknown agent token · an empty list · a list naming every known agent (the block
# would then render nowhere at all) · a second opener before a close · a close with nothing open ·
# EOF inside a block. What this rule set cannot see is a MISSPELLED KEYWORD — `adb:excpt` matches
# nothing here and would ship literally — so each caller additionally scans its rendered output for
# any surviving `<!-- adb:` and refuses to publish one.
#
# Markers are BODY-ONLY, the same rule `{{TOKEN}}` already lives by. This filter has no notion of
# frontmatter (the practices it also serves have none), so a marker placed in a skill's frontmatter
# is neither rejected nor meaningful — see base/workflows/README.md's source contract.
block_filter() {
  local agent="$1" src="$2"
  # REFUSE ANYTHING THAT IS NOT A READABLE REGULAR FILE, before awk sees it — and this test is
  # load-bearing, not defensive garnish. In the root-doc renderer this call replaced `cat "$f"`,
  # and the two disagree in exactly the direction that matters: `cat` on a DIRECTORY exits 1 with
  # "Is a directory", while `awk` on a directory reads zero records and exits **0**. Without this,
  # a practice path the `*.md` glob matched but the renderer cannot read is silently OMITTED from
  # the root doc and the build still reports success — a whole practice missing, with no
  # diagnostic. That is the same silent-omission failure this facility exists to make impossible,
  # reintroduced one layer down. `scripts/check-build-atomic.sh` injects precisely that fault (a
  # directory named `90-boom.md`, chosen because `cat` refuses it as any uid) and is what caught
  # the regression; an unreadable regular file awk does reject on its own (rc 2), but naming both
  # here keeps one message for one condition.
  if [ ! -f "$src" ] || [ ! -r "$src" ]; then
    printf 'build.sh: cannot read %s — not a readable regular file\n' "$src" >&2
    return 1
  fi
  # A SOURCE MUST END WITH A NEWLINE, and this is enforced rather than tolerated because the
  # filter cannot preserve its absence: `cat` reproduced a missing final newline exactly, while
  # awk's `print` always terminates with ORS. Silently ADDING a byte is the wrong way to differ
  # from the code this replaced — `base/workflows/README.md` already asks sources to be
  # newline-terminated, so the honest move is to make that a rule the build checks instead of one
  # the renderer quietly repairs. `$( )` strips trailing newlines, so a non-empty result means the
  # last byte was NOT one. An empty file yields empty and passes here; the renderers reject an
  # empty workflow on their own.
  if [ -s "$src" ] && [ -n "$(tail -c 1 "$src")" ]; then
    printf 'build.sh: %s does not end with a newline — sources must be newline-terminated (see base/workflows/README.md)\n' "$src" >&2
    return 1
  fi
  awk -v agent="$agent" -v known="$build_known_agents" -v src="$src" '
    # DIAGNOSTICS GO THROUGH A PIPE TO `cat 1>&2`, not to "/dev/stderr". Redirecting to that
    # pseudo-file is what every awk here happens to support, but POSIX does not specify it — and
    # this function already argues its own portability (it avoids whole-array `delete` for exactly
    # that reason), so relying on an unspecified filename beside that argument would be incoherent.
    # A pipe to a command is POSIX, and awk closes it at exit.
    function die(ln, msg) {
      dying = 1
      printf("build.sh: %s:%d: %s\n", src, ln, msg) | "cat 1>&2"
      exit 3
    }
    BEGIN {
      nknown = split(known, ka, " ")
      for (i = 1; i <= nknown; i++) valid[ka[i]] = 1
      # VALIDATE THE TARGET AGENT, not only the tokens inside markers. An unknown target is
      # indistinguishable from a known agent that no marker happens to exclude, so it renders
      # every block and looks entirely correct — a typo in a `render` call would silently ship the
      # wrong density rather than failing. `die` reports at line 0: the fault is the invocation,
      # not any line of the source. (Independent-review find.)
      if (!(agent in valid))
        die(0, "block_filter called for unknown agent `" agent "` — known: " known)
      open = 0; emit = 1
    }
    # Matched as a WHOLE LINE, so a marker quoted inside running prose is text, not a directive.
    /^<!-- adb:end -->$/ {
      if (!open) die(FNR, "`adb:end` with no open block")
      open = 0; emit = 1
      next
    }
    # The loose pattern selects, the strict one validates. Selecting loosely is what lets a
    # mangled opener be REPORTED rather than silently falling through to be emitted as prose.
    /^<!-- adb:except[ \t]/ {
      if ($0 !~ /^<!-- adb:except( [a-z0-9-]+)+ -->$/)
        die(FNR, "malformed `adb:except` marker (want `<!-- adb:except <agent>… -->`): " $0)
      if (open) die(FNR, "nested `adb:except` — close the block opened at line " open_line " first")
      # The already-listed set is a DELIMITED STRING, not an array, so resetting it per marker is
      # an assignment. `delete listed` would read better and is supported by gawk, mawk and
      # onetrue-awk alike — but whole-array `delete` is unspecified in POSIX awk, and this runs in
      # the build path of every CI job on three platforms. A token cannot contain a space (the
      # validating regex above is `[a-z0-9-]+`), so space-delimited membership is exact.
      listed = " "
      nlisted = 0; excluded = 0
      # Fields 3..NF-1 are the agent tokens: $1 `<!--`, $2 `adb:except`, $NF `-->`.
      for (i = 3; i <= NF - 1; i++) {
        if (!($i in valid)) die(FNR, "unknown agent token `" $i "` in an `adb:except` marker")
        if (index(listed, " " $i " ")) die(FNR, "agent `" $i "` listed twice in one `adb:except` marker")
        listed = listed $i " "; nlisted++
        if ($i == agent) excluded = 1
      }
      # A block excluded from every known agent renders nowhere — dead content that reads, in the
      # source, exactly like content that ships. It is always a mistake, so it is always loud.
      if (nlisted == nknown)
        die(FNR, "`adb:except` naming every known agent — this block would render for no agent")
      open = 1; open_line = FNR; emit = !excluded
      next
    }
    { if (emit) print }
    END {
      if (dying) exit 3
      if (open) die(open_line, "unterminated `adb:except` block — no `adb:end` before EOF")
    }
  ' "$src"
}

# block_marker_residue <rendered-file> <what> — refuse to publish output still carrying `<!-- adb:`.
#
# ONE HOME, because both renderers need it and a refusal policy that had drifted between them
# would be the same duplication this file's own law forbids (independent-review find). It exists
# because `block_filter` can only reject spellings it RECOGNISES: a misspelled keyword
# (`adb:excpt`, `adb:unless`) matches none of its rules and sails through as prose, into a tracked
# root doc that install.sh symlinks into a live agent session, or into an installed skill.
#
# THE SUBSTRING IS RESERVED EVERYWHERE IN A RENDERED SOURCE — inside a fence, inside a code span,
# inside running prose. That is broader than the recognizer, which matches only whole lines, and
# the breadth is deliberate: narrowing this to directive-shaped lines would let the one class it
# exists for (a keyword nobody spelled right) through again. The cost is that the marker syntax
# cannot be QUOTED in a file that renders — which is why the two files documenting it,
# `base/practices/00-index.md` and `base/workflows/README.md`, are both files their renderer skips.
block_marker_residue() {
  local f="$1" what="$2"
  LC_ALL=C grep -Fq '<!-- adb:' "$f" || return 0
  echo "build.sh: unresolved per-agent block marker(s) in $what — every marker must be \`<!-- adb:except <agent>… -->\` … \`<!-- adb:end -->\`, and the substring \`<!-- adb:\` is reserved everywhere in a rendered source (see base/workflows/README.md):" >&2
  LC_ALL=C grep -Fn '<!-- adb:' "$f" | sed 's/^/  /' >&2
  return 1
}

render() {
  local agent="$1" outfile="$2" title="$3"
  mkdir -p "$(dirname "$outfile")"
  # Stage, render, publish — the same pair render_agent_skill() below uses (#268). A plain
  # `> "$outfile"` truncates the TRACKED root doc before the first byte is written, so any abort
  # mid-render — ^C, a full disk, an OOM kill — leaves it half-rendered in the working tree, and the
  # next `build-drift` reports drift rather than corruption. It is also read live: install.sh
  # symlinks each agent's own root doc at this path (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
  # `~/.gemini/GEMINI.md`), so the truncate window was visible to a running agent session. A rename
  # is atomic, so a reader of any ONE file sees the old contents or the new and never a torn mix.
  # (Across the three files it is not atomic, and that is what keeps `build-drift` pinned to
  # selfcheck's serial prologue — see that script's concurrency contract.)
  build_stage "$outfile"
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
      block_filter "$agent" "$f"
      printf '\n\n---\n\n'
    done
    printf '_Generated from base/practices. The multi-agent role model lives in base/roles.md._\n'
  } > "$build_tmp"
  # Scanned before the publish, so the tracked file is left intact; the EXIT trap removes the
  # staged temp. Same guard the skill renderer calls — see block_marker_residue.
  block_marker_residue "$build_tmp" "the rendered '$agent' root doc" || exit 3
  build_publish "$outfile"
  echo "wrote ${outfile#"$root"/}"
}

render claude "$root/agents/claude/CLAUDE.md" "Global engineering practices"
render codex  "$root/agents/codex/AGENTS.md"  "Global engineering practices"
render gemini "$root/agents/gemini/GEMINI.md" "Global engineering practices"

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
  local agent="$1" src="$2" name out tmp first fmname fmmarker
  local args_to state_dir gate_run role_dispatch roadmap_lib repo_settings cleanup_lib currency_lib pr_review
  local state_assert pr_watch actions_app_slug implement_lib adopt_lib adopt_readiness
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
  implement_lib="bash \"\$HOME/.$agent/scripts/lib/implement-lib.sh\""
  currency_lib="bash \"\$HOME/.$agent/scripts/lib/currency-lib.sh\""
  state_assert="bash \"\$HOME/.$agent/scripts/lib/state-assert.sh\""
  ci_health="bash \"\$HOME/.$agent/scripts/lib/ci-health.sh\""
  adopt_lib="bash \"\$HOME/.$agent/scripts/lib/adopt-lib.sh\""
  adopt_readiness="bash \"\$HOME/.$agent/scripts/lib/adopt-readiness.sh\""
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
  # PER-AGENT MARKERS ARE BODY-ONLY, and that is REJECTED here rather than merely documented
  # (independent-review find). `block_filter` has no notion of frontmatter — it also serves the
  # practices, which have none — so it processes a marker there like any other, which means a
  # well-formed one could delete a frontmatter key or the closing `---` for one agent and not
  # another. Rejecting is what makes the source contract's "body-only" a fact instead of a wish,
  # and it belongs in this function because this is the renderer that knows where frontmatter ends.
  fmmarker="$(awk 'NR==1 { next } $0 == "---" { exit } /<!-- adb:/ { print NR; exit }' "$src")"
  if [ -n "$fmmarker" ]; then
    echo "build.sh: base/workflows/$name.md carries a per-agent block marker inside its frontmatter (line $fmmarker) — markers are body-only (see base/workflows/README.md)." >&2
    exit 3
  fi

  mkdir -p "$(dirname "$out")"
  # Render to a temp file and mv into place only on success — a failed render must
  # never truncate the existing SKILL.md, since install.sh symlinks each skill dir
  # and a zero-byte file here would break the live installed skill. Writes only this
  # one file; never clears or recreates the skills directory.
  #
  # Staged through the shared pair so this path gets the same unique temp and the same EXIT trap
  # (#268). The `rm -f` on the unresolved-placeholder path below was the only cleanup this renderer
  # had, so an awk failure or a ^C left a `SKILL.md.tmp` behind — where `build-drift`'s untracked
  # scan DOES see it and reports it as "rendered skill(s) not committed", a message about the wrong
  # problem. And its fixed sibling name carried the same collision and symlink hazards render() had;
  # hardening one renderer and not the other would have left the two write paths disagreeing about a
  # hazard they both face, which is the asymmetry #268 exists to end.
  build_stage "$out"
  tmp="$build_tmp"
  # PER-AGENT BLOCKS RESOLVE FIRST, then the MAP substitutes tokens (#304). The order is
  # load-bearing in one direction only — a `{{TOKEN}}` inside an excluded block must never reach
  # the map, or a token that only makes sense for the agent the block was written for would be
  # substituted and emitted for an agent the author excluded. The reverse order buys nothing.
  # Piped rather than passed as a filename, so `set -o pipefail` carries the filter's rc 3 out.
  #
  # The MAP is the lreplace() calls below, fed the per-agent tokens via -v. Kept
  # literal (index/substr in awk, no regex) so tokens with $, ", and / substitute
  # cleanly. -v does no escape processing on these values (none contain backslashes),
  # so e.g. Claude's gate command emits its real quotes byte-for-byte.
  block_filter "$agent" "$src" | awk -v name="$name" -v fmmode="$fmmode" \
      -v args_to="$args_to" -v state_dir="$state_dir" \
      -v gate_run="$gate_run" -v role_dispatch="$role_dispatch" \
      -v roadmap_lib="$roadmap_lib" -v repo_settings="$repo_settings" \
      -v cleanup_lib="$cleanup_lib" -v currency_lib="$currency_lib" \
      -v implement_lib="$implement_lib" \
      -v pr_review="$pr_review" -v state_assert="$state_assert" \
      -v ci_health="$ci_health" \
      -v adopt_lib="$adopt_lib" -v adopt_readiness="$adopt_readiness" \
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
      line = lreplace(line, "{{IMPLEMENT_LIB}}",    implement_lib)
      line = lreplace(line, "{{CURRENCY_LIB}}",     currency_lib)
      line = lreplace(line, "{{STATE_ASSERT_LIB}}", state_assert)
      line = lreplace(line, "{{CI_HEALTH_LIB}}",    ci_health)
      line = lreplace(line, "{{ADOPT_LIB}}",        adopt_lib)
      line = lreplace(line, "{{ADOPT_READINESS}}",  adopt_readiness)
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
  ' > "$tmp"

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
    build_tmp=''
    exit 3
  fi

  # The same refusal the root-doc renderer makes, through the same function.
  if ! block_marker_residue "$tmp" "the rendered '$agent' '$name' skill"; then
    rm -f "$tmp"
    build_tmp=''
    exit 3
  fi

  build_publish "$out"
  echo "wrote ${out#"$root"/}"
}

for wf in "$workflows"/*.md; do
  case "$(basename "$wf")" in README.md) continue ;; esac
  render_agent_skill claude "$wf"
  render_agent_skill codex  "$wf"
  render_agent_skill gemini "$wf"
done
