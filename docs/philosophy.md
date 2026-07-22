# Philosophy

## Why this exists

Every AI coding agent — Claude Code, Codex, Gemini/Antigravity, and whatever
comes next — needs the same handful of hard-won engineering disciplines to
behave well across a long, autonomous session: don't guess at root causes,
don't gamble on flaky CI, don't leave deferred work untracked, don't touch the
wrong repo, review your own diff before anyone else does. None of that is
specific to one vendor's agent. It's specific to *doing unattended agentic
work well*.

**ai-dev-baseline** is a single, agent-neutral source of truth for those
practices, installed once at the **user level** so they apply in every
project you touch — not re-authored per repo, not copy-pasted into every
`CLAUDE.md` you own, and not silently absent the day you start a new
repository. A project can still layer its own rules on top (see
[per-project-overrides.md](per-project-overrides.md)), but the floor is the
same everywhere.

## Agent-neutral, not Claude-specific

The practices in `base/practices/*.md` say nothing about Claude, Codex, or
Gemini. They're written in terms of what an agent should do, not which agent
does it. That neutrality is enforced structurally:

- The practice files live once, under `base/practices/`.
- `scripts/build.sh` **renders** them into each agent's native root document —
  `agents/claude/CLAUDE.md`, `agents/codex/AGENTS.md`, `agents/gemini/GEMINI.md`
  — by concatenating every practice file (skipping the index) under a
  generated-file banner. The three outputs are byte-for-byte the same body
  today (only the surrounding agent-specific wiring differs by design), because
  the source they're rendered from is the same.
- CI re-runs `build.sh` and fails on drift, so nobody can hand-edit a rendered
  root doc and have it silently diverge from the source of truth.

The **workflows** follow the same structure: `base/workflows/*.md` is the single
source for each workflow's procedure + metadata, and `build.sh` renders it into the
Claude skills (`agents/claude/skills/<name>/SKILL.md`), drift-checked the same way.
Rendering those same sources into other agents' native command surfaces is the
in-progress skill-parity work — but the *source* is already agent-neutral and
authored once.

This is also what makes **per-project role assignment** possible at all (see
[roles-and-agents.md](roles-and-agents.md)): because the same practices and
the same workflow shape exist under every agent, a project can pick *which*
agent drives, gap-analyzes, reviews, or debugs — via a small `agents.toml` —
without the workflow itself changing. Swap `primary` from `claude` to `codex`
and the `implement-issue` playbook is unchanged; only who executes each step
moves.

## Practices as law, not suggestion

`base/practices/00-index.md` states the precedence explicitly: an explicit
task instruction wins, a project's own doc wins over the baseline where it
conflicts, and the baseline is the default everywhere else. But absent an
override, the baseline is not optional color commentary — it is treated as
law: a Stop-hook gate blocks ending a turn on red quality gates
(`precommit-gate.sh`), and a second gate refuses to let an `/implement-issue`
run end before its PR exists (`implement-issue-gate.sh`). The practices aren't
just documentation an agent might read; where the harness can enforce them
mechanically, it does.

## The lessons encoded

Each file under `base/practices/` exists because a specific failure mode
happened and was expensive enough to codify a rule against:

- **Shell portability** (`shell.md`) — bash arrays and `[[ ]]` breaking under
  zsh/sh, compound `A && B && C` chains getting blocked by command-safety
  gating, unquoted expansions silently word-splitting. The fix is one command
  per purpose, quoted expansions, no bashisms outside a real `#!/usr/bin/env
  bash` script.
- **Diagnose-before-rerun CI discipline** (`ci-discipline.md`) — re-running a
  red CI job as a first resort burns minutes, hides the real cause, and can
  ship a latent bug on a lucky green. The rule: read the failure log,
  classify flaky vs. real with evidence, fix real failures at the root, and
  file an issue for anything genuinely flaky *before* re-running it.
- **Sweep-all-merged-branches cleanup** (`git-and-prs.md`, the `cleanup`
  skill) — a cleanup that deletes only the current task's branch and leaves
  dozens of merged branches behind is a failed cleanup. The `cleanup` skill
  enumerates every branch already merged into the default branch and names
  each one explicitly in its own delete call, which also sidesteps
  command-safety gating that blocks vague, branch-less "clean up" requests.
- **Verify repo scope** (`repo-scope.md`) — a whole session was once lost
  implementing against issues that lived in a *different* repository than the
  one checked out. A three-second `gh issue view <n>` up front fails fast
  instead of burning a session on the wrong codebase.
- **Mandatory self-review** (`self-review.md`) — a dedicated, pre-PR review
  pass focused on real bugs (edge cases, escaping/encoding, cascade effects,
  off-by-one, idempotency, resource leaks) has repeatedly caught landmines —
  a cascade-cancel guard bug, a JS-escaping bug, NUL-byte-corrupted generated
  files — that a casual "looks fine" read missed. It's a gate, not a victory
  lap.
- **Evidence-first root-cause debugging** (`debugging.md`, the `debug`
  skill) — "probably X" is a hypothesis, not a diagnosis. Reproduce on
  demand, prove the cause with logs/diffs/a failing regression test written
  *before* the fix, and rule out your own stale state (a deployed build
  lagging the default branch behind a release gate is not a platform bug)
  before blaming the platform.
- **Out-of-scope → tracked issue** (`issues-and-scope.md`) — anything
  deferred, punted, or listed as a parent issue's own "Out of scope" section
  evaporates the moment that issue closes on merge. A PR-body note is not
  tracking. The rule: file a real GitHub issue, automatically, before calling
  the work done — never ask first.
- **Logging and secrets** (`logging-and-secrets.md`) — structured,
  correlated logs by default; never log API keys, tokens, JWTs, credential-
  bearing headers, or full bodies that might carry them.

## Global install, project overrides layered separately

The baseline is installed once, at the user level (`~/.claude`, and the
equivalent for other agents), via symlinks back into a cloned copy of this
repo (see [installation.md](installation.md)). That's a deliberate choice:

- `git pull` in the cloned repo updates every project's practices, skills,
  and gates at once — no per-repo sync step.
- A project layers its *own* needs on top without forking or editing the
  baseline: its own root doc, a same-named skill that shadows the global one,
  or `agents.toml` overrides (see
  [per-project-overrides.md](per-project-overrides.md)).
- Because the baseline is agent-neutral and the workflow reads role
  assignment from `agents.toml`, the same install works whether a given
  project is driven by Claude, Codex, Gemini, or a mix reviewing each other's
  work (see [roles-and-agents.md](roles-and-agents.md)).

## See also

- [design-principles.md](design-principles.md) — the tenets a contribution must
  satisfy, and the CI checks that enforce each (single-source/no-drift, general-
  over-specific, config-over-hardcode, graceful degradation).
- [installation.md](installation.md) — how the global install actually wires
  symlinks and hooks.
- [roles-and-agents.md](roles-and-agents.md) — the role/agent separation that
  agent-neutrality enables.
- [per-project-overrides.md](per-project-overrides.md) — how a repo layers
  its own rules on top.
- [adding-an-agent.md](adding-an-agent.md) — extending the framework to a new
  AI coding agent.
