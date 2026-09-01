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

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
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
  mkdir -p "$dst/scripts" "$dst/scripts/lib" "$dst/base/practices" "$dst/base/workflows" || return 2
  cp "$ROOT/scripts/build.sh" "$dst/scripts/build.sh" || return 2
  # build.sh gates its own interpreter (#256), so the fixture repo needs the library that holds the
  # gate. Without it the fixture dies at the source line and EVERY assertion below reports the same
  # "no SKILL.md" — a fixture failure wearing a render failure's clothes.
  cp "$ROOT/scripts/lib/common.sh" "$dst/scripts/lib/common.sh" || return 2
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
Auto-merge guard: {{REPO_SETTINGS_LIB}} automerge-ok
Cleanup predicate: {{CLEANUP_LIB}} state-verdict threads open
Run admission: {{IMPLEMENT_LIB}} admit {{STATE_DIR}}
State observation: {{STATE_ASSERT_LIB}} observe pr 137
Currency policy: {{CURRENCY_LIB}} check --trigger cleanup
Adoption scan: {{ADOPT_LIB}} scan .
Actions slug: {{ACTIONS_APP_SLUG}} and again {{ACTIONS_APP_SLUG}}.
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
  has "$body" 'Auto-merge guard: bash "$HOME/.claude/scripts/lib/repo-settings.sh" automerge-ok' "{{REPO_SETTINGS_LIB}} is a command prefix"
  has "$body" 'Cleanup predicate: bash "$HOME/.claude/scripts/lib/cleanup-lib.sh" state-verdict'  "{{CLEANUP_LIB}} is a command prefix"
  has "$body" 'Run admission: bash "$HOME/.claude/scripts/lib/implement-lib.sh" admit .claude/state' "{{IMPLEMENT_LIB}} is a command prefix"
  has "$body" 'State observation: bash "$HOME/.claude/scripts/lib/state-assert.sh" observe' "{{STATE_ASSERT_LIB}} is a command prefix"
  has "$body" 'Adoption scan: bash "$HOME/.claude/scripts/lib/adopt-lib.sh" scan'           "{{ADOPT_LIB}} is a command prefix"
  has "$body" 'Currency policy: bash "$HOME/.claude/scripts/lib/currency-lib.sh" check'      "{{CURRENCY_LIB}} is a command prefix"
  has "$body" 'Actions slug: github-actions and again github-actions.' "{{ACTIONS_APP_SLUG}} → the real Actions app slug (agent-invariant, and pinned as a LITERAL: deriving it here would make this test blind to the VALUE being wrong, which is how #179 shipped)"
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
  has "$cbody" 'Auto-merge guard: bash "$HOME/.codex/scripts/lib/repo-settings.sh" automerge-ok' "codex {{REPO_SETTINGS_LIB}} → the ~/.codex guard"
  has "$cbody" 'Cleanup predicate: bash "$HOME/.codex/scripts/lib/cleanup-lib.sh" state-verdict'  "codex {{CLEANUP_LIB}} → the ~/.codex predicate"
  has "$cbody" 'Run admission: bash "$HOME/.codex/scripts/lib/implement-lib.sh" admit .codex/state' "codex {{IMPLEMENT_LIB}} → the ~/.codex admission guard"
  has "$cbody" 'State observation: bash "$HOME/.codex/scripts/lib/state-assert.sh" observe' "codex {{STATE_ASSERT_LIB}} is a command prefix"
  has "$cbody" 'Adoption scan: bash "$HOME/.codex/scripts/lib/adopt-lib.sh" scan'           "codex {{ADOPT_LIB}} → the ~/.codex library"
  has "$cbody" 'Currency policy: bash "$HOME/.codex/scripts/lib/currency-lib.sh" check'      "codex {{CURRENCY_LIB}} → the ~/.codex policy"
  has "$cbody" 'Actions slug: github-actions and again github-actions.' "codex {{ACTIONS_APP_SLUG}} → the real Actions app slug (agent-invariant, and pinned as a LITERAL: deriving it here would make this test blind to the VALUE being wrong, which is how #179 shipped)"
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
  has "$gbody" 'Auto-merge guard: bash "$HOME/.gemini/scripts/lib/repo-settings.sh" automerge-ok' "gemini {{REPO_SETTINGS_LIB}} → the ~/.gemini guard"
  has "$gbody" 'Cleanup predicate: bash "$HOME/.gemini/scripts/lib/cleanup-lib.sh" state-verdict'  "gemini {{CLEANUP_LIB}} → the ~/.gemini predicate"
  has "$gbody" 'Run admission: bash "$HOME/.gemini/scripts/lib/implement-lib.sh" admit .gemini/state' "gemini {{IMPLEMENT_LIB}} → the ~/.gemini admission guard"
  has "$gbody" 'State observation: bash "$HOME/.gemini/scripts/lib/state-assert.sh" observe' "gemini {{STATE_ASSERT_LIB}} is a command prefix"
  has "$gbody" 'Adoption scan: bash "$HOME/.gemini/scripts/lib/adopt-lib.sh" scan'           "gemini {{ADOPT_LIB}} → the ~/.gemini library"
  has "$gbody" 'Currency policy: bash "$HOME/.gemini/scripts/lib/currency-lib.sh" check'      "gemini {{CURRENCY_LIB}} → the ~/.gemini policy"
  has "$gbody" 'Actions slug: github-actions and again github-actions.' "gemini {{ACTIONS_APP_SLUG}} → the real Actions app slug (agent-invariant, and pinned as a LITERAL: deriving it here would make this test blind to the VALUE being wrong, which is how #179 shipped)"
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

# --- 3c: the EMPTY-SLUG refusal, OBSERVED FAILING (#183) --------------------------------------
# A guard is not done until it has been seen going red on an input it is supposed to reject, and
# this one's failure mode is the quiet kind: if `adb_actions_app_slug` ever returned empty, the map
# would substitute "" and the rendered skills would carry `(.app.slug // "") == ""` — which matches
# exactly the check runs whose app CANNOT be identified, i.e. a confident `green` from a build
# nobody attributed, baked into three shipped skills. Nothing else in this suite can catch that:
# every other case runs the real, non-empty accessor. (Independent-review find: the refusal existed
# and had never been watched working.)
#
# The fixture replaces the ACCESSOR in the copied library rather than editing anything tracked —
# `render_fixture` already copies `common.sh` into a throwaway tree, so the override lands there.
neg_slug="$WORK/neg-slug-src.md"
cat > "$neg_slug" <<'EOF'
---
name: fixture
description: t
user-invocable: true
---

# /fixture
Slug: {{ACTIONS_APP_SLUG}}
EOF
for broken in 'adb_actions_app_slug() { printf ""; }' 'adb_actions_app_slug() { return 1; }'; do
  d="$WORK/neg-slug-$(printf '%s' "$broken" | cksum | cut -d' ' -f1)"
  mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows"
  cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
  cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
  # Appended AFTER the real definition, so it wins — and the bash-floor gate above it still loads.
  printf '\n%s\n' "$broken" >> "$d/scripts/lib/common.sh"
  printf '# index\n' > "$d/base/practices/00-index.md"
  printf '# dummy practice\n' > "$d/base/practices/aaa.md"
  cp "$neg_slug" "$d/base/workflows/fixture.md"
  bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
  no "$rc" "a broken adb_actions_app_slug [$broken] FAILS the build"
  has "$(cat "$d/build.log" 2>/dev/null)" 'adb_actions_app_slug is unavailable or empty' \
      "...and the error names the accessor rather than dying somewhere downstream"
  if [ -f "$d/agents/claude/skills/fixture/SKILL.md" ]; then
    bad "a skill was written despite the empty Actions slug [$broken]"
  else
    ok
  fi
done

# --- 3b: a dot-named supporting source FAILS the build, never silently renders nowhere (#433) --
# `*.md` skips dotfiles, so before the enumeration included them the leading-dot refusal was
# unreachable: `.notes.md` committed cleanly, rendered to no agent, and passed every 1:1 check.
d="$WORK/dotsupport"
mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/fixture"
cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
printf '# index\n' > "$d/base/practices/00-index.md"
printf '# dummy practice\n' > "$d/base/practices/aaa.md"
cp "$pos" "$d/base/workflows/fixture.md"
printf '# hidden notes\n' > "$d/base/workflows/fixture/.notes.md"
bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
no "$rc" "a dot-named supporting source FAILS the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'must not begin with a dot' "...naming the dot rule"

# --- 3d: reserved-name and duplicate checks fold case (#433) -----------------------------------
# macOS checkouts sit on a case-insensitive filesystem, so `Skill.md` beside a rendered SKILL.md
# aliases or overwrites the skill entry there while rendering fine on Linux — the tree becomes
# unrepresentable on the repository's other CI platform.
d="$WORK/casefold"
mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/fixture"
cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
printf '# index\n' > "$d/base/practices/00-index.md"
printf '# dummy practice\n' > "$d/base/practices/aaa.md"
cp "$pos" "$d/base/workflows/fixture.md"
printf '# case variant\n' > "$d/base/workflows/fixture/Skill.md"
bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
no "$rc" "a case variant of SKILL.md FAILS the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'collide with the rendered skill entry' "...naming the collision"
# Case-folded duplicates among supporting files — buildable only on a case-sensitive filesystem,
# so the fixture is probed for and the case runs where it can exist (Linux CI).
: > "$WORK/CaseProbe"
if [ ! -e "$WORK/caseprobe" ]; then
  rm -f "$WORK/CaseProbe"
  d="$WORK/casedup"
  mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/fixture"
  cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
  cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
  printf '# index\n' > "$d/base/practices/00-index.md"
  printf '# dummy practice\n' > "$d/base/practices/aaa.md"
  cp "$pos" "$d/base/workflows/fixture.md"
  printf '# lower\n' > "$d/base/workflows/fixture/notes.md"
  printf '# upper\n' > "$d/base/workflows/fixture/Notes.md"
  bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
  no "$rc" "case-folded duplicate supporting files FAIL the build"
  has "$(cat "$d/build.log" 2>/dev/null)" 'collides case-insensitively' "...naming the duplicate rule"
else
  rm -f "$WORK/CaseProbe"
fi

# --- 3e: README/ is reserved — its source is skipped, so its supporting files render to nobody --
d="$WORK/readmedir"
mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/README"
cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
printf '# index\n' > "$d/base/practices/00-index.md"
printf '# dummy practice\n' > "$d/base/practices/aaa.md"
cp "$pos" "$d/base/workflows/fixture.md"
printf 'readme\n' > "$d/base/workflows/README.md"
printf '# notes\n' > "$d/base/workflows/README/notes.md"
bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
no "$rc" "a supporting directory for the reserved README source FAILS the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'README' "...naming the reserved source"

# --- 3c: hidden and nested DIRECTORIES are refused too, not silently skipped (#433) ------------
# `*/` never visits `.notes/`, so the orphan refusal did not run on it — the source committed,
# rendered to no agent, and passed every 1:1 check. Same shape one level down: a subdirectory
# inside a supporting dir is enumerated by nothing and must be refused where it is born.
d="$WORK/dotdir"
mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/.notes"
cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
printf '# index\n' > "$d/base/practices/00-index.md"
printf '# dummy practice\n' > "$d/base/practices/aaa.md"
cp "$pos" "$d/base/workflows/fixture.md"
printf '# hidden reference\n' > "$d/base/workflows/.notes/reference.md"
bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
no "$rc" "a hidden directory under base/workflows FAILS the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'hidden director' "...naming the hidden-directory rule"
d="$WORK/nestdir"
mkdir -p "$d/scripts/lib" "$d/base/practices" "$d/base/workflows/fixture/extra"
cp "$ROOT/scripts/build.sh" "$d/scripts/build.sh"
cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh"
printf '# index\n' > "$d/base/practices/00-index.md"
printf '# dummy practice\n' > "$d/base/practices/aaa.md"
cp "$pos" "$d/base/workflows/fixture.md"
printf '# nested\n' > "$d/base/workflows/fixture/extra/y.md"
bash "$d/scripts/build.sh" >"$d/build.log" 2>&1; rc=$?
no "$rc" "a subdirectory inside a supporting dir FAILS the build"
has "$(cat "$d/build.log" 2>/dev/null)" 'flat' "...naming the flat-directory rule"

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
