#!/usr/bin/env bash
# ai-dev-baseline — regression tests for the workflow-body placeholder substitution that
# scripts/build.sh applies when rendering base/workflows/*.md into the Claude skills (#16).
#
# build-drift already proves the rendered skills match what's committed byte-for-byte; this
# test proves the SUBSTITUTION MECHANISM behind that render is correct and stays correct:
#   1. every neutral {{PLACEHOLDER}} maps to its Claude token (incl. multiple on one line, a
#      path + trailing slash, a command prefix), and non-placeholder `$` text is left alone;
#   2. substitution is BODY-ONLY — a placeholder in frontmatter is not substituted (so a
#      Claude passthrough key can't be mangled), which the fail-loud guard then rejects;
#   3. an unmapped {{TOKEN}} fails the build loud and writes no skill;
#   4. no committed Claude skill ships an unresolved placeholder.
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
  has "$body" 'Track work: TaskCreate some sub-tasks.'                             "{{SUBTASK_PRIMITIVE}} maps to TaskCreate"
  has "$body" 'Literal shell: echo "$HOME" and a bare $ARGUMENTS token.'           "non-placeholder \$HOME/\$ARGUMENTS text is untouched"
  has "$body" 'allowed-tools: Bash, TaskCreate, TaskList'                          "frontmatter emitted verbatim (substitution is body-only)"
  has "$body" 'GENERATED FILE'                                                     "generated-file marker injected"
  hasnt "$body" '{{'                                                               "no unresolved placeholder remains in output"
else
  bad "positive fixture produced no SKILL.md (build.log: $(cat "$d/build.log" 2>/dev/null))"
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

# --- 4: no committed Claude skill ships an unresolved placeholder -----------------------------
for sk in "$ROOT"/agents/claude/skills/*/SKILL.md; do
  [ -f "$sk" ] || continue
  n="$(basename "$(dirname "$sk")")"
  if LC_ALL=C grep -Fq '{{' "$sk"; then
    bad "committed skill '$n' contains an unresolved placeholder"
  else
    ok
  fi
done

check_summary "workflow-render"
