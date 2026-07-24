# ai-dev-baseline

**One source of truth for how AI coding agents work — across every project, every
stack, and every agent.**

Your engineering practices shouldn't be re-typed into every repo, and they
shouldn't be tied to one AI. `ai-dev-baseline` holds your baseline **once** —
agent-neutral — and installs it at the **user level** so it applies in every
project automatically. Each project can then layer its own rules on top, and each
project decides **which** AI is primary (drives implementation) and which handle
reviews, debugging, or other roles.

- **Agent-neutral.** The practices and workflows are written once and rendered into
  each agent's native config: Claude (`~/.claude/CLAUDE.md` + skills + gates),
  Codex (`~/.codex/AGENTS.md`), Gemini/Antigravity (`~/.gemini/GEMINI.md`). Adding
  another AI is one new adapter.
- **Global, with per-project override.** Installed into your home config so it's on
  in every repo; a repo's own doc/skills/gates always win where they differ.
- **Role-based multi-agent.** A repo's `agents.toml` declares who is `primary`, who
  does `gap_analysis`, who does `review`, who `debug`s — swap `primary = "codex"`
  and Codex drives while Claude reviews, with no change to the workflows.
- **Single source of truth, live.** Payloads are **symlinked**, so `git pull` in
  this repo updates every project at once.

## Quickstart

```bash
git clone git@github.com:BWBama85/ai-dev-baseline.git ~/Code/ai-dev-baseline
cd ~/Code/ai-dev-baseline
./install.sh --agent claude            # add --agent codex --agent gemini as needed
export PATH="$HOME/Code/ai-dev-baseline/bin:$PATH"   # for `agent-init`
```

In any repo:

```bash
agent-init          # writes agents.toml (roles), gitignores runtime state, prints the role map
```

Existing files are backed up to `~/.claude/backups/ai-dev-baseline-*`; re-running is
idempotent; `./uninstall.sh` reverses everything. See [docs/installation.md](docs/installation.md).

Keep the install current without remembering a `git pull`:

```bash
baseline update            # fast-forward the install-source clone + self-heal links
baseline update --check    # report currency only (for a lifecycle hook); changes nothing
```

## The roles model

A repo drops an [`agents.toml`](templates/agents.toml) at its root:

```toml
[roles]
primary      = "claude"             # drives /implement-issue
gap_analysis = "codex"              # adversarial pre-implementation pass
review       = ["claude", "gemini"] # independent code review before merge
debug        = "claude"
```

| Role | Job | Default |
|---|---|---|
| `primary` | Drives implementation end-to-end | required |
| `gap_analysis` | Adversarial pre-implementation read of the issue | `codex` (or skip) |
| `review` | Independent code review before merge | `["claude"]` |
| `debug` | Root-cause investigations | primary |
| `issue_author` / `release` | File issues / cut releases | primary |

Unset roles fall back to your global default manifest, then to the built-in
default. Full model: [docs/roles-and-agents.md](docs/roles-and-agents.md).

## What's inside

**Practices** ([`base/practices/`](base/practices)) — the agent-neutral law, one
concern per file, rendered into every agent's root doc:

- **Shell** — portable, single-purpose commands (no zsh/bash footguns).
- **Git & PRs** — feature-branch-only, no destructive git, and a real branch
  cleanup sweep (all merged branches, named explicitly).
- **CI discipline** — diagnose before you re-run; never gamble on a flaky green.
- **Issues & scope** — deferred/out-of-scope work always becomes a tracked issue.
- **Repo scope** — confirm work belongs to *this* repo before starting.
- **Debugging** — evidence-backed root cause, not guesses.
- **Self-review** — a mandatory pre-PR pass that catches real bugs.
- **Logging & secrets** — structured logs; never log secrets.

**Skills** ([`agents/claude/skills/`](agents/claude/skills)) — invokable workflows,
generated from the agent-neutral sources in [`base/workflows/`](base/workflows):

| Skill | What it does |
|---|---|
| `/implement-issue` | Issue → repo-scope check → role-assigned gap-analysis → implement → auto-detected gates → self-review + assigned review → PR |
| `/create-issue` | File a well-scoped issue via an 11-axis adversarial gap-analysis pass |
| `/resolve-pr-threads` | Address + resolve bot review threads so branch protection unblocks |
| `/cleanup` | Sweep **all** merged branches (local + remote), naming each explicitly |
| `/debug` | Evidence-first root-cause investigation and fix |
| `/roadmap` | Reconcile the roadmap artifact and emit the next `/implement-issue` batch |
| `/new-release` | Review an **upstream** CLI's release notes and apply what affects you |

There is deliberately **no `/release`.** Cutting your own project's release is the
project-owned [`release` role](docs/roles-and-agents.md#release-is-project-owned--the-baseline-ships-no-release):
release schemes (SemVer vs CalVer, changelog vs none, tag vs image vs zip) vary too
much for a generic skeleton to be right. `/new-release` is the opposite direction —
it reacts to *someone else's* release, and never touches your version or tags.

**Gates** ([`agents/claude/scripts/`](agents/claude/scripts)) — Stop-hook quality
gates that **auto-detect** the toolchain (pnpm/npm/yarn/bun, cargo, go, python) and
**skip any repo that ships its own gate**, so project-specific gates keep winning.

## Layout

```
base/practices/     agent-neutral practices (single source of truth for the root docs)
base/workflows/     agent-neutral workflows (single source of truth for the skills)
base/roles.md       the multi-agent role registry
agents/<agent>/     per-agent rendering: root doc + skills + scripts + adapter
scripts/build.sh    renders base/practices → root docs, base/workflows → Claude skills
templates/          the per-project agents.toml
install.sh          global installer (per --agent, symlinks + wires gates)
bin/agent-init      per-project role setup
bin/baseline        keep the installed baseline current; also `baseline release init` (opt-in release-goal convention)
docs/               installation, roles, per-project overrides, release-goal convention, roadmap acceptance, adding an agent
```

## Status

Claude is fully wired (practices, six skills, auto-detecting gates). The Codex and
Gemini/Antigravity adapters install the shared practices into each agent's root
doc today; deeper per-agent workflow parity is tracked as issues. See
[docs/adding-an-agent.md](docs/adding-an-agent.md).

## Contributing

Dev guide: [CONTRIBUTING.md](CONTRIBUTING.md) (agents working on the repo start at
[CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md)). The one rule to remember: edit
`base/practices/*.md`, **never** the generated `agents/*/…` root docs, and run
`scripts/selfcheck.sh` before pushing — it mirrors CI.

## License

MIT — see [LICENSE](LICENSE).
