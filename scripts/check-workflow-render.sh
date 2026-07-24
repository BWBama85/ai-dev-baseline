#!/usr/bin/env bash
# ai-dev-baseline — regression tests for the workflow-body placeholder substitution that
# scripts/build.sh applies when rendering base/workflows/*.md into each agent's skills (#16, #12/#13).
#
# build-drift already proves the rendered skills match what's committed byte-for-byte; this
# test proves the SUBSTITUTION MECHANISM behind that render is correct and stays correct:
#   1. every neutral {{PLACEHOLDER}} maps to its per-agent token — Claude (verbatim frontmatter),
#      Codex, and Gemini (synth frontmatter: name+description, Claude-only keys dropped) — incl.
#      multiple on one line, a path + trailing slash, a command prefix; non-placeholder `$` text
#      is left alone;
#   2. substitution is BODY-ONLY — a placeholder in frontmatter is not substituted (so a
#      Claude passthrough key can't be mangled), which the fail-loud guard then rejects;
#   3. an unmapped {{TOKEN}} fails the build loud and writes no skill;
#   4. no committed skill (any agent) ships an unresolved placeholder.
#
# Uses the shared unit-test assertion family from check-lib.sh (ok/bad/eq/has/hasnt +
# check_summary). Run standalone or via scripts/selfcheck.sh.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# render_fixture <dst> <name> <src> — build a throwaway repo skeleton mirroring what build.sh
# expects (a copy of build.sh, a minimal base/practices so the root-doc render has something to
# emit, and a base/workflows holding ONLY this fixture), run the real build.sh against it, and
# return its exit code. Output lands at <dst>/agents/claude/skills/<name>/SKILL.md; the build
# log at <dst>/build.log.
render_fixture() {
  local dst="$1" name="$2" src="$3"
  mkdir -p "$dst/scripts" "$dst/base/practices" "$dst/base/workflows" || return 2
  cp "$ROOT/scripts/build.sh" "$dst/scripts/build.sh" || return 2
  printf '# index\n' > "$dst/base/practices/00-index.md"
  printf '# dummy practice\n' > "$dst/base/practices/aaa.md"
  cp "$src" "$dst/base/workflows/$name.md" || return 2
  bash "$dst/scripts/build.sh" >"$dst/build.log" 2>&1
}

# --- 1 + 2: positive fixture exercises every placeholder + body-only frontmatter passthrough --
pos="$WORK/pos-src.md"
cat > "$pos" <<'EOF'
---
name: fixture
description: test fixture
user-invocable: true
allowed-tools: Bash, TaskCreate, TaskList
---

# /fixture

Args are {{ARGS}} and again {{ARGS}}.
State file: {{STATE_DIR}}/fixture.json and dir {{STATE_DIR}}/.
Run gates: {{GATE_RUNNER}} run
Dispatch: {{ROLE_DISPATCH}} resolve review
Roadmap predicate: {{ROADMAP_LIB}} release-ready 1 1 0 0 0
I am {{CURRENT_AGENT}}.
Track work: {{SUBTASK_PRIMITIVE}} some sub-tasks.
Literal shell: echo "$HOME" and a bare $ARGUMENTS token.
EOF

d="$WORK/pos"
render_fixture "$d" fixture "$pos"; rc=$?
yes "$rc" "positive fixture builds cleanly"
out="$d/agents/claude/skills/fixture/SKILL.md"
if [ -f "$out" ]; then
  body="$(cat "$out")"
  has "$body" 'Args are $ARGUMENTS and again $ARGUMENTS.'                         "{{ARGS}} maps + multiple on one line"
  has "$body" 'State file: .claude/state/fixture.json and dir .claude/state/.'     "{{STATE_DIR}} as path and with trailing slash"
  has "$body" 'Run gates: bash "$HOME/.claude/scripts/lib/project-gates.sh" run'   "{{GATE_RUNNER}} is a command prefix"
  has "$body" 'Dispatch: bash "$HOME/.claude/scripts/lib/role-dispatch.sh" resolve review' "{{ROLE_DISPATCH}} is a command prefix"
  has "$body" 'Roadmap predicate: bash "$HOME/.claude/scripts/lib/roadmap-lib.sh" release-ready' "{{ROADMAP_LIB}} is a command prefix"
  has "$body" 'I am claude.'                                                       "{{CURRENT_AGENT}} maps to claude"
  has "$body" 'Track work: TaskCreate some sub-tasks.'                             "{{SUBTASK_PRIMITIVE}} maps to TaskCreate"
  has "$body" 'Literal shell: echo "$HOME" and a bare $ARGUMENTS token.'           "non-placeholder \$HOME/\$ARGUMENTS text is untouched"
  has "$body" 'allowed-tools: Bash, TaskCreate, TaskList'                          "frontmatter emitted verbatim (Claude passthrough key preserved; body-only proven by neg2 below)"
  has "$body" 'GENERATED FILE'                                                     "generated-file marker injected"
  hasnt "$body" '{{'                                                               "no unresolved placeholder remains in output"
else
  bad "positive fixture produced no SKILL.md (build.log: $(cat "$d/build.log" 2>/dev/null))"
fi

# --- 1 (Codex): the codex MAP + synth frontmatter (name+description, Claude-only keys dropped) --
cout="$d/agents/codex/skills/fixture/SKILL.md"
if [ -f "$cout" ]; then
  cbody="$(cat "$cout")"
  has "$cbody" 'Args are $ARGUMENTS and again $ARGUMENTS.'                          "codex {{ARGS}} → \$ARGUMENTS"
  has "$cbody" 'State file: .codex/state/fixture.json and dir .codex/state/.'       "codex {{STATE_DIR}} → .codex/state"
  has "$cbody" 'Run gates: bash "$HOME/.codex/scripts/lib/project-gates.sh" run'    "codex {{GATE_RUNNER}} → the ~/.codex runner"
  has "$cbody" 'Dispatch: bash "$HOME/.codex/scripts/lib/role-dispatch.sh" resolve review' "codex {{ROLE_DISPATCH}} → the ~/.codex helper"
  has "$cbody" 'Roadmap predicate: bash "$HOME/.codex/scripts/lib/roadmap-lib.sh" release-ready' "codex {{ROADMAP_LIB}} → the ~/.codex predicate"
  has "$cbody" 'I am codex.'                                                        "codex {{CURRENT_AGENT}} → codex"
  has "$cbody" 'Track work: update_plan some sub-tasks.'                            "codex {{SUBTASK_PRIMITIVE}} → update_plan"
  has "$cbody" 'name: fixture'                                                      "codex synth frontmatter emits name"
  has "$cbody" 'description: test fixture'                                          "codex synth frontmatter emits description"
  has "$cbody" 'Claude-specific'                                                    "codex render carries the Claude-flavored caveat comment"
  hasnt "$cbody" 'allowed-tools'                                                    "codex synth DROPS the Claude-only allowed-tools key"
  hasnt "$cbody" 'user-invocable'                                                   "codex synth DROPS the Claude-only user-invocable key"
  hasnt "$cbody" '{{'                                                               "codex render has no unresolved placeholder"
else
  bad "positive fixture produced no codex SKILL.md (build.log: $(cat "$d/build.log" 2>/dev/null))"
fi

# --- 1 (Gemini): the gemini MAP (Antigravity tokens) + the same synth frontmatter policy -------
gout="$d/agents/gemini/skills/fixture/SKILL.md"
if [ -f "$gout" ]; then
  gbody="$(cat "$gout")"
  has "$gbody" 'State file: .gemini/state/fixture.json and dir .gemini/state/.'     "gemini {{STATE_DIR}} → .gemini/state"
  has "$gbody" 'Run gates: bash "$HOME/.gemini/scripts/lib/project-gates.sh" run'   "gemini {{GATE_RUNNER}} → the ~/.gemini runner"
  has "$gbody" 'Dispatch: bash "$HOME/.gemini/scripts/lib/role-dispatch.sh" resolve review' "gemini {{ROLE_DISPATCH}} → the ~/.gemini helper"
  has "$gbody" 'Roadmap predicate: bash "$HOME/.gemini/scripts/lib/roadmap-lib.sh" release-ready' "gemini {{ROADMAP_LIB}} → the ~/.gemini predicate"
  has "$gbody" 'I am gemini.'                                                       "gemini {{CURRENT_AGENT}} → gemini"
  has "$gbody" 'Track work: Create some sub-tasks.'                                 "gemini {{SUBTASK_PRIMITIVE}} → Create"
  has "$gbody" 'name: fixture'                                                      "gemini synth frontmatter emits name"
  hasnt "$gbody" 'allowed-tools'                                                    "gemini synth DROPS the Claude-only allowed-tools key"
  hasnt "$gbody" '{{'                                                               "gemini render has no unresolved placeholder"
else
  bad "positive fixture produced no gemini SKILL.md (build.log: $(cat "$d/build.log" 2>/dev/null))"
fi

# --- 3: an unmapped placeholder in the body fails the build and writes no skill ---------------
neg1="$WORK/neg1-src.md"
cat > "$neg1" <<'EOF'
---
name: fixture
description: t
user-invocable: true
---

# /fixture
Bad token: {{BOGUS_TOKEN}} here.
EOF
d="$WORK/neg1"
render_fixture "$d" fixture "$neg1"; rc=$?
no "$rc" "unmapped {{BOGUS_TOKEN}} fails the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'unresolved placeholder' "build error names the unresolved placeholder"
if [ -f "$d/agents/claude/skills/fixture/SKILL.md" ]; then
  bad "skill was written despite the unmapped placeholder"
else
  ok
fi

# --- 2 (negative): a placeholder in FRONTMATTER is not substituted, so the guard rejects it ---
neg2="$WORK/neg2-src.md"
cat > "$neg2" <<'EOF'
---
name: fixture
description: {{ARGS}}
user-invocable: true
---

# /fixture
body ok
EOF
d="$WORK/neg2"
render_fixture "$d" fixture "$neg2"; rc=$?
no "$rc" "a placeholder in frontmatter is left verbatim → fails the build (body-only proof)"
# Assert it failed for the RIGHT reason (the guard caught the surviving frontmatter placeholder),
# not some unrelated earlier error — this is what makes it a body-only proof, not just "build failed".
has "$(cat "$d/build.log" 2>/dev/null)" 'unresolved placeholder' "neg2 fails via the fail-loud guard (frontmatter placeholder not substituted)"

# --- 3b: a non-single-line `description:` fails the build (Codex/Gemini synth would drop content) --
# A folded/block scalar (`>`) description spans multiple lines; the synth render captures only the
# `description:` line, so the source contract requires one line and build.sh rejects the rest loud.
neg3="$WORK/neg3-src.md"
cat > "$neg3" <<'EOF'
---
name: fixture
description: >-
  first line of a folded description
  that continues onto a second line
user-invocable: true
---

# /fixture
body ok
EOF
d="$WORK/neg3"
render_fixture "$d" fixture "$neg3"; rc=$?
no "$rc" "a folded/multi-line description fails the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'non-single-line' "neg3 fails via the single-line-description guard"
if [ -f "$d/agents/claude/skills/fixture/SKILL.md" ]; then
  bad "skill was written despite the multi-line description"
else
  ok
fi

# --- 4: no committed skill ships an unresolved placeholder (EVERY agent's rendered tree) ------
for a in claude codex gemini; do
  for sk in "$ROOT"/agents/"$a"/skills/*/SKILL.md; do
    [ -f "$sk" ] || continue
    n="$(basename "$(dirname "$sk")")"
    if LC_ALL=C grep -Fq '{{' "$sk"; then
      bad "committed $a skill '$n' contains an unresolved placeholder"
    else
      ok
    fi
  done
done

check_summary "workflow-render"
