#!/usr/bin/env bash
# ai-dev-baseline — local CI mirror. Run before every push.
#
# Runs the exact checks CI runs: shellcheck, build-drift, skill-frontmatter,
# gate-detector, and an install→uninstall dry-run into a throwaway HOME.
# "Green here" should mean "green in CI". Requires: git, jq. shellcheck is
# optional (the step SKIPs if it's missing, matching a dev box without it).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Enumerate tracked shell files (+ the extensionless bin/agent-init).
  files="$(git ls-files '*.sh' 'bin/agent-init')"
  # shellcheck disable=SC2086
  if shellcheck --severity=warning -e SC1091 $files; then echo "PASS"; else echo "FAIL"; fail=1; fi
else
  echo "SKIP (shellcheck not installed)"
fi

step "build-drift"
bd=0
# Capture the build exit: a malformed source makes build.sh exit non-zero WITHOUT
# rewriting the already-tracked skill, so the diff-only checks below would still see
# a clean tree and print PASS. CI's rebuild step fails on that non-zero exit; the
# local mirror must too, or a broken source passes selfcheck and only fails in CI.
if ! bash scripts/build.sh >/dev/null; then
  echo "  scripts/build.sh failed — a base/practices or base/workflows source is malformed (see its error above)"
  bd=1
fi
# Compare the freshly-built tree against HEAD (committed), not the index — so a
# partial stage (e.g. staging a generated skill but not its edited source) can't
# false-pass locally and then fail only in remote CI. This mirrors what CI does
# (it checks out HEAD, builds, and diffs).
if ! git diff --quiet HEAD -- agents/claude/CLAUDE.md agents/codex/AGENTS.md agents/gemini/GEMINI.md; then
  echo "  root docs stale — base/practices changed; run scripts/build.sh and commit them"
  bd=1
fi
if ! git diff --quiet HEAD -- agents/claude/skills; then
  echo "  generated skills stale — base/workflows changed; run scripts/build.sh and commit them"
  bd=1
fi
# git diff HEAD is blind to untracked files; catch a rendered-but-uncommitted skill.
# (An ignored one won't show here — the workflow-map tracked-check covers that.)
if [ -n "$(git ls-files --others --exclude-standard -- agents/claude/skills)" ]; then
  echo "  rendered skill(s) not committed — run scripts/build.sh and 'git add' the result:"
  git ls-files --others --exclude-standard -- agents/claude/skills | sed 's/^/    /'
  bd=1
fi
[ "$bd" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "workflow-map"
# 1:1 between base/workflows/<name>.md (the source) and its rendered Claude skill, so
# a workflow can't lose its skill and a skill can't orphan when its source is removed.
wm=0
for wf in base/workflows/*.md; do
  [ -f "$wf" ] || continue
  n="$(basename "$wf" .md)"
  [ "$n" = README ] && continue
  sk="agents/claude/skills/$n/SKILL.md"
  if [ ! -f "$sk" ]; then
    echo "  base/workflows/$n.md → no rendered skill"; wm=1
  elif ! git ls-files --error-unmatch "$sk" >/dev/null 2>&1; then
    # Tracked-check is gitignore-immune: git ls-files --others (above) respects
    # .gitignore, so a rendered skill under an ignored path would slip past it.
    echo "  $sk is not git-tracked (untracked or gitignored) — run scripts/build.sh and 'git add' it"; wm=1
  fi
done
for sk in agents/claude/skills/*/SKILL.md; do
  [ -f "$sk" ] || continue
  n="$(basename "$(dirname "$sk")")"
  [ -f "base/workflows/$n.md" ] || { echo "  skill '$n' → no base/workflows/$n.md source (orphan)"; wm=1; }
done
[ "$wm" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "skill-frontmatter"
ff=0
for f in agents/claude/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  head -n1 "$f" | grep -q '^---$' || { echo "  ${f}: no frontmatter"; ff=1; continue; }
  for k in 'name:' 'description:' 'user-invocable:'; do
    head -n 20 "$f" | grep -q "^${k}" || { echo "  ${f}: missing ${k}"; ff=1; }
  done
done
[ "$ff" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "gate-detector"
out="$(bash scripts/lib/project-gates.sh detect . 2>&1)"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  echo "PASS (detect no-ops on unrecognized ecosystem)"
else
  echo "FAIL (out='$out' rc=$rc)"; fail=1
fi
if bash scripts/lib/project-gates.sh badcmd >/dev/null 2>&1; then
  echo "FAIL (badcmd exited 0)"; fail=1
else
  echo "PASS (badcmd errors)"
fi

step "common-lib"
# Unit tests for the shared shell primitives (scripts/lib/common.sh).
if bash scripts/check-common-lib.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "fact-drift"
# Canonical facts (gate axes, cross-agent invocations, codex timeout, resolution order)
# must stay consistent across their consumer docs.
if bash scripts/check-fact-drift.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "practice-index"
# Every base/practices/*.md is listed in 00-index.md exactly once (no missing/stale rows).
if bash scripts/check-practice-index.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "install dry-run"
FAKE="$(mktemp -d)"; ok=1
# Install all three agents so codex/gemini adapter paths (which now source common.sh)
# are exercised too, not just Claude's inline install path.
HOME="$FAKE" bash install.sh --agent claude --agent codex --agent gemini >/tmp/adb-selfcheck.log 2>&1 || ok=0
[ -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
[ -L "$FAKE/.claude/skills/implement-issue" ] || ok=0
[ -e "$FAKE/.claude/scripts/lib/project-gates.sh" ] || ok=0
[ -e "$FAKE/.claude/scripts/lib/common.sh" ] || ok=0
[ -L "$FAKE/.codex/AGENTS.md" ] || ok=0
[ -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
grep -q 'precommit-gate.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
HOME="$FAKE" bash uninstall.sh --agent claude --agent codex --agent gemini >>/tmp/adb-selfcheck.log 2>&1 || ok=0
[ ! -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
[ ! -L "$FAKE/.codex/AGENTS.md" ] || ok=0
[ ! -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
rm -rf "$FAKE"
[ "$ok" -eq 1 ] && echo "PASS" || { echo "FAIL (see /tmp/adb-selfcheck.log)"; fail=1; }

step "result"
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
