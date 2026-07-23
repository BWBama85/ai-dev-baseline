# Codex adapter

Wires this repo's Codex payload into Codex's user-global config so the shared
baseline practices apply on every Codex session, in every project, without
per-repo setup.

## What gets wired

`adapter.sh install <repo> <backup_dir>` symlinks:

- `agents/codex/AGENTS.md` → `~/.codex/AGENTS.md` — the generated root doc.
- `agents/codex/skills/<name>/` → `~/.codex/skills/<name>/` — the rendered
  workflow skills (see "Native workflow parity" below).
- `scripts/lib/` → `~/.codex/scripts/lib/` — the shared, agent-neutral gate
  runner (`project-gates.sh`) a rendered workflow's gate step calls.

`AGENTS.md` and the skills are **generated** by `scripts/build.sh` (from
`base/practices/*.md` and `base/workflows/*.md` respectively) — do not
hand-edit them, edit the sources and rebuild. Codex auto-loads
`~/.codex/AGENTS.md` at the start of every session (see `base/roles.md`:
"codex reads `~/.codex/` + `AGENTS.md`"), so the baseline practices (shell
hygiene, git/PR discipline, CI discipline, out-of-scope → issue, debugging,
self-review, logging/secrets) load automatically.

An existing real `~/.codex/AGENTS.md` is backed up (mirroring its absolute
path under `<backup_dir>`) before the symlink is created; re-running is a
no-op once the link is correct. `adapter.sh uninstall <repo>` removes each
symlink only if it still points back into this repo — it never touches a
file you (or another tool) put there independently.

`~/.codex/config.toml` (model, reasoning effort, sandbox/approval policy,
MCP servers, per-project trust levels) is **not** touched by the adapter — it
is operator-managed, per-workstation state. A short, all-commented starting
point is at `agents/codex/config.toml.sample`.

## Native workflow parity

The `implement-issue` / `cleanup` / `debug` / … workflows this framework ships
are rendered into **Codex skills** — `~/.codex/skills/<name>/SKILL.md`, the
agent-skills folder format Codex discovers natively (the same `SKILL.md`
standard Claude and Antigravity use). They are generated from the single
`base/workflows/*.md` sources by `scripts/build.sh`, so a workflow authored
once appears on Codex with no per-workflow porting.

Two caveats, both tracked:

- Codex honors `name` + `description` frontmatter; the render drops the
  Claude-only keys (`allowed-tools`, `argument-hint`, `effort`,
  `user-invocable`) since Codex does not act on them.
- The bodies still contain some Claude-specific machinery references
  (Stop-hook gating, `/code-review`) whose per-agent equivalents are tracked
  follow-ups (#14/#15/#25). Each generated skill carries a caveat comment
  saying so; full cross-agent neutralization rides those issues.

(Codex custom prompts under `~/.codex/prompts/` — the surface an earlier issue
targeted — were deprecated in favor of skills, so the render targets skills.)

## Cross-agent invocation

When another agent's workflow needs Codex for a role it owns (e.g.
`gap_analysis` in `agents.toml`), it shells out non-interactively:

```
codex exec --cd <repo> -
```

`codex exec` reads and reasons over the whole repo and routinely takes
**3–7 minutes** — always give this call a timeout of **at least 7 minutes**.
A 2-minute default will SIGTERM it mid-run: that's too tight a bound, so
re-run longer rather than reading exit 143 as a verdict. A genuine timeout or
non-zero exit at the **full** ≥7-minute bound is an **incomplete** invocation,
not an acceptable "wasted pass" to move past — kill it, retry once, then fall
back, per the delegated-step **completion contract** in `base/roles.md` (which
also carries the full cross-agent invocation table).
