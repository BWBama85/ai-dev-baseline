#!/usr/bin/env bash
# ai-dev-baseline — local CI mirror. Run before every push.
#
# Runs the exact checks CI runs: shellcheck, build-drift, skill-frontmatter, workflow-render,
# gate-detector/gates, common-lib, agent-init, cleanup-enum, repo-settings, baseline,
# session-currency, precommit-gate, implement-gate, install-migration, install-guard,
# fact-drift, fact-mutation, fact-guard, practice-index, release-role, release-skill, and an
# install→uninstall dry-run into a throwaway HOME.
# "Green here" should mean "green in CI". Requires: git, jq. shellcheck is
# optional (the step SKIPs if it's missing, matching a dev box without it).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Enumerate tracked shell files (+ the extensionless bin/ commands).
  files="$(git ls-files '*.sh' 'bin/agent-init' 'bin/baseline')"
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
# Every agent's rendered skills tree (Claude, Codex, Gemini) is regenerated from the
# same base/workflows sources, so a stale/uncommitted render in ANY of them is drift.
for tree in agents/claude/skills agents/codex/skills agents/gemini/skills; do
  if ! git diff --quiet HEAD -- "$tree"; then
    echo "  generated skills stale ($tree) — base/workflows changed; run scripts/build.sh and commit them"
    bd=1
  fi
  # git diff HEAD is blind to untracked files; catch a rendered-but-uncommitted skill.
  # (An ignored one won't show here — the workflow-map tracked-check covers that.)
  if [ -n "$(git ls-files --others --exclude-standard -- "$tree")" ]; then
    echo "  rendered skill(s) not committed ($tree) — run scripts/build.sh and 'git add' the result:"
    git ls-files --others --exclude-standard -- "$tree" | sed 's/^/    /'
    bd=1
  fi
done
[ "$bd" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "workflow-map"
# 1:1 between base/workflows/<name>.md (the source) and its rendered skill FOR EVERY AGENT,
# so a workflow can't lose a skill and a skill can't orphan when its source is removed.
wm=0
for agent in claude codex gemini; do
  for wf in base/workflows/*.md; do
    [ -f "$wf" ] || continue
    n="$(basename "$wf" .md)"
    [ "$n" = README ] && continue
    sk="agents/$agent/skills/$n/SKILL.md"
    if [ ! -f "$sk" ]; then
      echo "  base/workflows/$n.md → no rendered $agent skill"; wm=1
    elif ! git ls-files --error-unmatch "$sk" >/dev/null 2>&1; then
      # Tracked-check is gitignore-immune: git ls-files --others (above) respects
      # .gitignore, so a rendered skill under an ignored path would slip past it.
      echo "  $sk is not git-tracked (untracked or gitignored) — run scripts/build.sh and 'git add' it"; wm=1
    fi
  done
  for sk in agents/$agent/skills/*/SKILL.md; do
    [ -f "$sk" ] || continue
    n="$(basename "$(dirname "$sk")")"
    [ -f "base/workflows/$n.md" ] || { echo "  $agent skill '$n' → no base/workflows/$n.md source (orphan)"; wm=1; }
  done
done
[ "$wm" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "skill-frontmatter"
# Required frontmatter keys are agent-specific: every SKILL.md needs name + description;
# only Claude's skill loader also requires user-invocable (Codex/Antigravity honor only
# name + description — see base/workflows/README.md).
ff=0
for agent in claude codex gemini; do
  case "$agent" in
    claude) keys='name: description: user-invocable:' ;;
    *)      keys='name: description:' ;;
  esac
  for f in agents/$agent/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    head -n1 "$f" | grep -q '^---$' || { echo "  ${f}: no frontmatter"; ff=1; continue; }
    for k in $keys; do
      head -n 20 "$f" | grep -q "^${k}" || { echo "  ${f}: missing ${k}"; ff=1; }
    done
  done
done
[ "$ff" -eq 0 ] && echo "PASS" || { echo "FAIL"; fail=1; }

step "workflow-render"
# The body-placeholder substitution behind the Claude skill render (#16): every neutral
# {{PLACEHOLDER}} maps to its Claude token, substitution is body-only, an unmapped token
# fails loud, and no committed skill ships an unresolved placeholder.
if bash scripts/check-workflow-render.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "workflow-shell"
# A fenced ```bash block in base/workflows/*.md is executed for real, but the linter above only
# sees tracked *.sh files — never a workflow body. This catches the one class that is both
# invisible there and destructive: assigning a zsh-special name. `path` IS $PATH, so
# `read -r kind path key` emptied the search path mid-sweep and made /cleanup a silent no-op on
# macOS (#126). (This comment deliberately does not start a line with the linter's own name —
# that reads as a directive and fails the parse.)
if bash scripts/check-workflow-shell.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "gate-detector"
# The empty-ecosystem no-op (detect on a dir with no toolchain and no agents.toml emits
# nothing) is covered generically by check-gates.sh — run in the "gates" step below — so it
# isn't repeated here. This step asserts only what is specific to THIS repo: repo-root
# detection surfaces the committed agents.toml [gates] override (#7), so CI keeps exercising
# the dogfooded manifest. Records are TAB-delimited "<label>\t<command>".
want_gate="$(printf 'test\tbash scripts/selfcheck.sh')"
got_gate="$(bash scripts/lib/project-gates.sh detect . 2>/dev/null)"   # compare stdout only
if [ "$got_gate" = "$want_gate" ]; then
  echo "PASS (repo-root detect emits the committed test gate)"
else
  echo "FAIL (repo-root detect: got '$got_gate' want '$want_gate')"; fail=1
fi
if bash scripts/lib/project-gates.sh badcmd >/dev/null 2>&1; then
  echo "FAIL (badcmd exited 0)"; fail=1
else
  echo "PASS (badcmd errors)"
fi

step "gates"
# Full behavior tests for the gate model (detection, open set, N/A, path scope).
if bash scripts/check-gates.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "common-lib"
# Unit tests for the shared shell primitives (scripts/lib/common.sh), incl. adb_repo_shape (#23).
if bash scripts/check-common-lib.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "agent-init"
# Integration tests for bin/agent-init's repo-shape tolerance: subdir resolution, bama-style
# untracked-parent + out-of-repo doc surfacing, nested repos, non-git refusal (#23).
if bash scripts/check-agent-init.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "role-dispatch"
# Unit tests for the runtime role-dispatch helper (resolve/bots/invoke + validation, #15).
if bash scripts/check-role-dispatch.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "pr-review"
# Unit tests for the pre-arm review guard (scripts/lib/pr-review.sh, #134): reviewer-identity
# matching across the REST/GraphQL `[bot]` spelling split, head-SHA freshness, the declaration
# tri-state, and every unreadable path failing closed.
if bash scripts/check-pr-review.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "pr-watch"
# Unit tests for the async-reviewer status detector (scripts/lib/pr-watch.sh, #49): the two
# terminal signals (a `+1` reaction = clean, a review at head = findings), the staleness rule that
# stops a reaction left on an earlier head from reading as a pass, the declaration tri-state, every
# unreadable path failing closed, and the bounded wait actually honouring its bound.
if bash scripts/check-pr-watch.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "state-assert"
# Unit tests for the atomic observe-and-render helper (scripts/lib/state-assert.sh, #138):
# mergedAt-over-state, NOT_PLANNED kept distinct, every unverifiable path rendering NO sentence,
# argument validation, and the three narrating workflows' wiring to it.
if bash scripts/check-state-assert.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "skill-compose"
# Unit tests for the partial skill override composer (scripts/lib/skill-compose.sh, #22):
# ops, anchor slugging, inherit-on-recompose, byte-exact currency check, and the safety guards.
if bash scripts/check-skill-compose.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "cleanup-enum"
# Regression test for /cleanup's remote enumeration excluding the origin/HEAD symref (#38).
if bash scripts/check-cleanup-enum.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "cleanup"
# Behavioral tests for the /cleanup decision predicates (scripts/lib/cleanup-lib.sh): squash-merge
# detection against a real fixture (#106 — `--merged` alone is blind to it, so the sweep was a
# permanent no-op), the destructive refusals (a branch that gained commits after its merge; state
# for an open PR or an in-flight run), and the terse output contract (#84). Offline.
if bash scripts/check-cleanup.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "roadmap"
# Behavioral tests for the /roadmap decision predicates (scripts/lib/roadmap-lib.sh): in-flight
# targeting (#69 — a bare `Refs #N` must never freeze a ready member) and release readiness
# (#71), plus a drift guard that the workflow still delegates to them (#45). Offline.
if bash scripts/check-roadmap.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "roadmap-e2e"
# Mocked-gh harness (#75): EXECUTES the workflow's documented snippets against a stub gh, so a
# fenced command that no longer runs is a test failure rather than a surprise at /roadmap time.
# Covers artifact location, the paginated adopt scan, the completeness + in-flight fresh read,
# the readiness pipeline, the gauge, and decision durability. Offline.
if bash scripts/check-roadmap-e2e.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "release-convention"
# Offline unit tests for the release-goal convention helper (scripts/lib/release-convention.sh,
# #27): dispatch, arg-parsing, usage, and the fail-loud gh guard before any gh call.
if bash scripts/check-release-convention.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "repo-settings"
# Offline tests for the repo-settings contract (scripts/lib/repo-settings.sh, #87): CI-check
# discovery (the `on:` block sits at the same indent as job keys — harvesting it would require
# contexts that can never report and deadlock every PR), the load-bearing write order (required
# checks strictly before allow_auto_merge), the narrow-vs-destructive endpoint choice, and the
# automerge-ok exit-code table the workflow's step 10 consumes.
if bash scripts/check-repo-settings.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "baseline"
# End-to-end tests for bin/baseline's currency classification (safety-critical: it
# must never fast-forward over dirty/ahead/diverged/detached/non-default state).
if bash scripts/check-baseline.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "session-currency"
# The SessionStart currency hook (#36) must act ONLY on a genuinely new session, never touch the
# clone the session is working in, refuse unsafe clone state by name, and always exit 0 — a
# non-zero SessionStart hook renders an error notice on every start.
if bash scripts/check-session-currency.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "precommit-gate"
# The Stop-hook quality gate must FAIL LOUD (never silently no-op) when its own shared
# library is missing — a broken install is enforcement secretly off (#35).
if bash scripts/check-precommit-gate.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "implement-gate"
# The implement-issue Stop hook must re-verify PR state LIVE and fail closed — never trust a
# stored prUrl over a PR that was closed without merging (#44).
if bash scripts/check-implement-gate.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "install-migration"
# A plain `git pull` must never dangle an installed symlink: install the merge-base, simulate
# a pull to HEAD, and require every installed link to still resolve (#35).
if bash scripts/check-install-migration.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "install-guard"
# adb_link's fail-loud source guard must thread through install.sh: a missing manifest source
# makes the real installer exit non-zero, never dangling a link or disturbing a real dest (#48).
if bash scripts/check-install-guard.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "fact-drift"
# Canonical facts (gate axes, cross-agent invocations, codex timeout, resolution order)
# must stay consistent across their consumer docs.
if bash scripts/check-fact-drift.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "fact-mutation"
# The negative half of that lint has a failure mode the positive half does not: SILENCE. An
# `absent:` pattern that matches nothing passes forever while checking nothing — which is exactly
# what shipped in #173 and is why #213 exists. Each rule's declared `fires:` witnesses are injected
# into a COPY of every file it pins and the real lint must come back red. Runs ~22 sub-lints
# against a throwaway tree; the working tree is never touched.
if bash scripts/check-fact-drift.sh --mutation; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "fact-guard"
# ...and the guard rails above are themselves guards, so they get the same treatment (#213): the
# witness contract and the mutation harness are each driven against deliberately broken rules in a
# tree copy and must be seen going red. Carries the direct regression test for #173's defect — the
# exact `absent:\[bot\]\$` pattern that could not match either real idiom.
if bash scripts/check-fact-guard.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "claims"
# The OFFLINE half of the claim lint (#212): every D<N> an added line cites resolves to a heading in
# the decision log, and every added decision date is within a day of the commit that introduced it.
#
# The issue/PR-reference half is NOT run here, and that is deliberate rather than an omission. It
# needs the network, and D13 keeps selfcheck hermetic precisely so a local green is a DETERMINISTIC
# predictor of CI — a step whose verdict depends on network, auth and externally-mutable issue state
# would break that promise for every other step too. It rides CI instead, exactly as the one other
# live assertion (`repo-settings.sh required-drift`) does. The check SAYS which half it skipped and
# how many references went unverified, so the gap is visible rather than silent.
if bash scripts/check-claims.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "claims-guard"
# ...and the lint above is a guard, so it gets the treatment guards get here (D22): every rule is
# driven to RED against fixtures in a throwaway repo with a stubbed gh, asserting the DESIGNATED
# exit code and diagnostic rather than "some non-zero". This suite has already earned its place
# twice — it caught a markdown stripper that made one rule structurally unable to fire, and an
# unresolvable --range that silently turned the whole check into a no-op reporting PASS.
if bash scripts/check-claims-guard.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "practice-index"
# Every base/practices/*.md is listed in 00-index.md exactly once (no missing/stale rows).
if bash scripts/check-practice-index.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "release-role"
# #3's decision: release execution stays project-owned and no /release skill ships. A NEGATIVE
# invariant no other check can express — build-drift/workflow-map would happily green-light a
# newly added base/workflows/release.md.
if bash scripts/check-release-role.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "release-skill"
# The other half of #3: the project supplies its OWN release skill, so this repo's copy needs a
# gate. Offline unit tests for .claude/skills/release/release-lib.sh (version-ok, changelog-verify,
# checks-settled) plus the boundary invariants — no {{PLACEHOLDER}} inside a runnable block, no
# release predicate in the installed scripts/lib, and the skill still delegating to the tested
# predicates rather than re-deriving them (D14). Nothing else here reads .claude/skills/.
if bash scripts/check-release-skill.sh; then echo "PASS"; else echo "FAIL"; fail=1; fi

step "install dry-run"
FAKE="$(mktemp -d)"; ok=1
# Install all three agents so codex/gemini adapter paths (which now source common.sh)
# are exercised too, not just Claude's inline install path.
HOME="$FAKE" bash install.sh --agent claude --agent codex --agent gemini >/tmp/adb-selfcheck.log 2>&1 || ok=0
[ -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
[ -L "$FAKE/.claude/skills/implement-issue" ] || ok=0
[ -e "$FAKE/.claude/scripts/lib/project-gates.sh" ] || ok=0
[ -e "$FAKE/.claude/scripts/lib/common.sh" ] || ok=0
# The role-dispatch helper rides the same scripts/lib symlink into every agent home (#15).
[ -e "$FAKE/.claude/scripts/lib/role-dispatch.sh" ] || ok=0
[ -e "$FAKE/.codex/scripts/lib/role-dispatch.sh" ] || ok=0
[ -e "$FAKE/.gemini/scripts/lib/role-dispatch.sh" ] || ok=0
# The skill-override composer rides the same scripts/lib symlink (#22).
[ -e "$FAKE/.claude/scripts/lib/skill-compose.sh" ] || ok=0
# /cleanup's predicates ride it too — and must resolve for EVERY agent, since the rendered
# {{CLEANUP_LIB}} step points each agent's skill at its own copy of the path (#106/#84).
[ -e "$FAKE/.claude/scripts/lib/cleanup-lib.sh" ] || ok=0
[ -e "$FAKE/.codex/scripts/lib/cleanup-lib.sh" ] || ok=0
[ -e "$FAKE/.gemini/scripts/lib/cleanup-lib.sh" ] || ok=0
[ -L "$FAKE/.codex/AGENTS.md" ] || ok=0
# Codex + Gemini now also install rendered workflow skills and the shared gate runner
# (Gemini's skills under its ~/.gemini/config/ customization root).
[ -L "$FAKE/.codex/skills/implement-issue" ] || ok=0
[ -e "$FAKE/.codex/scripts/lib/project-gates.sh" ] || ok=0
[ -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
[ -L "$FAKE/.gemini/config/skills/implement-issue" ] || ok=0
[ -e "$FAKE/.gemini/scripts/lib/project-gates.sh" ] || ok=0
grep -q 'precommit-gate.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
# The SessionStart currency hook is both LINKED and WIRED (#36) — a manifest entry with no
# settings entry (or the reverse) would leave the feature silently inert.
[ -L "$FAKE/.claude/scripts/session-currency.sh" ] || ok=0
grep -q 'session-currency.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
HOME="$FAKE" bash uninstall.sh --agent claude --agent codex --agent gemini >>/tmp/adb-selfcheck.log 2>&1 || ok=0
[ ! -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
[ ! -L "$FAKE/.claude/scripts/session-currency.sh" ] || ok=0
# A leftover SessionStart entry pointing at a removed script would error on EVERY future session.
grep -q 'session-currency.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok=0
[ ! -L "$FAKE/.codex/AGENTS.md" ] || ok=0
[ ! -L "$FAKE/.codex/skills/implement-issue" ] || ok=0
[ ! -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
[ ! -L "$FAKE/.gemini/config/skills/implement-issue" ] || ok=0
rm -rf "$FAKE"
[ "$ok" -eq 1 ] && echo "PASS" || { echo "FAIL (see /tmp/adb-selfcheck.log)"; fail=1; }

step "result"
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
