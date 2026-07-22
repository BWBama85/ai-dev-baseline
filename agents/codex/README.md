# Codex adapter

Wires this repo's Codex payload into Codex's user-global config so the shared
baseline practices apply on every Codex session, in every project, without
per-repo setup.

## What gets wired

`adapter.sh install <repo> <backup_dir>` symlinks `agents/codex/AGENTS.md` →
`~/.codex/AGENTS.md`. `AGENTS.md` is **generated** by `scripts/build.sh` from
`base/practices/*.md` — do not hand-edit it, edit the practice files and
rebuild. Codex auto-loads `~/.codex/AGENTS.md` at the start of every session
(see `base/roles.md`: "codex reads `~/.codex/` + `AGENTS.md`"), so the baseline
practices (shell hygiene, git/PR discipline, CI discipline, out-of-scope →
issue, debugging, self-review, logging/secrets) load automatically.

An existing real `~/.codex/AGENTS.md` is backed up (mirroring its absolute
path under `<backup_dir>`) before the symlink is created; re-running is a
no-op once the link is correct. `adapter.sh uninstall <repo>` removes the
symlink only if it still points back into this repo — it never touches a
file `~/.codex/AGENTS.md` you (or another tool) put there independently.

`~/.codex/config.toml` (model, reasoning effort, sandbox/approval policy,
MCP servers, per-project trust levels) is **not** touched by the adapter — it
is operator-managed, per-workstation state. A short, all-commented starting
point is at `agents/codex/config.toml.sample`.

## What is deliberately NOT wired: native workflow parity

Codex does not auto-load `.claude/skills/`-style slash commands, so the
`implement-issue` / `cleanup` / `debug` workflows this framework ships for
Claude are **not** available to Codex as native commands. Today they reach
Codex only indirectly — as guidance baked into `AGENTS.md`, or as an ad hoc
prompt a human or another agent hands to `codex exec`. Rendering those
workflows as genuine Codex-native flows (custom prompts, a Codex equivalent of
a skill, whatever primitive Codex ends up supporting for this) is **deferred**
and tracked as a GitHub issue against this repo — file one (see
`base/practices/issues-and-scope.md`) before treating Codex workflow parity as
done.

## Cross-agent invocation

When another agent's workflow needs Codex for a role it owns (e.g.
`gap_analysis` in `agents.toml`), it shells out non-interactively:

```
codex exec --cd <repo> -
```

`codex exec` reads and reasons over the whole repo and routinely takes
**3–7 minutes** — always give this call a timeout of **at least 7 minutes**.
A 2-minute default will SIGTERM it mid-run; that's a wasted pass, not a
failure of the command. See `base/roles.md` for the full cross-agent
invocation table.
