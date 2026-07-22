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
bash scripts/build.sh >/dev/null
if git diff --quiet -- agents/claude/CLAUDE.md agents/codex/AGENTS.md agents/gemini/GEMINI.md; then
  echo "PASS"
else
  echo "FAIL — base/practices changed; run scripts/build.sh and commit the root docs"
  fail=1
fi

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
out="$(bash agents/claude/scripts/lib/project-gates.sh detect . 2>&1)"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  echo "PASS (detect no-ops on unrecognized ecosystem)"
else
  echo "FAIL (out='$out' rc=$rc)"; fail=1
fi
if bash agents/claude/scripts/lib/project-gates.sh badcmd >/dev/null 2>&1; then
  echo "FAIL (badcmd exited 0)"; fail=1
else
  echo "PASS (badcmd errors)"
fi

step "install dry-run"
FAKE="$(mktemp -d)"; ok=1
HOME="$FAKE" bash install.sh --agent claude >/tmp/adb-selfcheck.log 2>&1 || ok=0
[ -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
[ -L "$FAKE/.claude/skills/implement-issue" ] || ok=0
[ -e "$FAKE/.claude/scripts/lib/project-gates.sh" ] || ok=0
grep -q 'precommit-gate.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
HOME="$FAKE" bash uninstall.sh --agent claude >>/tmp/adb-selfcheck.log 2>&1 || ok=0
[ ! -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
rm -rf "$FAKE"
[ "$ok" -eq 1 ] && echo "PASS" || { echo "FAIL (see /tmp/adb-selfcheck.log)"; fail=1; }

step "result"
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
