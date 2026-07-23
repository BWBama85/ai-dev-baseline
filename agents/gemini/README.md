# Gemini (Antigravity) adapter

Wires this repo's Antigravity payload into Antigravity's user-global config
so the shared baseline practices apply on every `agy` session, in every
project, without per-repo setup.

## What gets wired

`adapter.sh install <repo> <backup_dir>` symlinks:

- `agents/gemini/GEMINI.md` → `~/.gemini/GEMINI.md` — the generated root doc.
- `agents/gemini/skills/<name>/` → `~/.gemini/config/skills/<name>/` — the
  rendered workflow skills. `~/.gemini/config/` is Antigravity's **global
  customization root** (confirmed in `agy`'s own bundled customization docs),
  and it discovers `skills/<name>/SKILL.md` there. See "Native workflow
  parity" below.
- `scripts/lib/` → `~/.gemini/scripts/lib/` — the shared, agent-neutral gate
  runner (`project-gates.sh`) a rendered workflow's gate step calls.

`GEMINI.md` and the skills are **generated** by `scripts/build.sh` (from
`base/practices/*.md` and `base/workflows/*.md` respectively) — do not
hand-edit them, edit the sources and rebuild. Antigravity auto-loads
`~/.gemini/GEMINI.md` at the start of every session (see `base/roles.md`:
"gemini/Antigravity reads `~/.gemini/GEMINI.md` + `~/.gemini/config/`"), so
the baseline practices (shell hygiene, git/PR discipline, CI discipline,
out-of-scope → issue, debugging, self-review, logging/secrets) load
automatically.

An existing real `~/.gemini/GEMINI.md` is backed up (mirroring its absolute
path under `<backup_dir>`) before the symlink is created; re-running is a
no-op once the link is correct. `adapter.sh uninstall <repo>` removes each
symlink only if it still points back into this repo — it never touches a
file you (or another tool) put there independently.

`~/.gemini/settings.json` (model pins, auth, UI prefs, custom model aliases)
and the shared `~/.gemini/config/hooks.json` (lifecycle hooks — synchronized
between the Antigravity IDE/2.0 and the CLI) are **not** touched by the
adapter — they are operator-managed, per-workstation state. A minimal starting
sample of the hooks shape is at `agents/gemini/config/hooks.sample.json`
(copy fields into your real `~/.gemini/config/hooks.json`; it is deliberately
not installed automatically since a live hook wired without review can gate
or inject into every Antigravity session).

### Reading the hooks sample

`hooks.sample.json` is a JSON object keyed by **hook name**, each mapping to
an optional `"enabled"` flag plus one or more **event** arrays (`PreToolUse`,
`PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`). The two included
samples (both shipped `"enabled": false` — a no-op `command: "true"`) show
the two structurally different shapes Antigravity uses:

- `example-stop-reminder` — a **flat** event (`Stop`, `PreInvocation`, and
  `PostInvocation` all take a bare list of handler objects; no matcher
  applies).
- `example-pretool-gate` — a **grouped** event (`PreToolUse` / `PostToolUse`
  wrap their handlers in `{ "matcher": "<tool-name-regex>", "hooks": [...] }`,
  since these events are scoped to specific tools).

Each handler object supports `type` (only `"command"` today), `command` (a
shell command run via `sh -c`, cwd = the directory containing `hooks.json`),
and `timeout` (seconds, default 30). Full contract (including the
stdin/stdout JSON schema for gating tool calls or forcing continuation) lives
in Antigravity's own bundled docs — worth reading before writing a real hook.

## Native workflow parity

The `implement-issue` / `cleanup` / `debug` / … workflows this framework ships
are rendered into **Antigravity skills** — `~/.gemini/config/skills/<name>/SKILL.md`,
the agent-skills folder format `agy` discovers natively (the same `SKILL.md`
standard Claude and Codex use). They are generated from the single
`base/workflows/*.md` sources by `scripts/build.sh`, so a workflow authored
once appears on Antigravity with no per-workflow porting.

Two caveats, both tracked:

- Antigravity honors `name` + `description` frontmatter; the render drops the
  Claude-only keys (`allowed-tools`, `argument-hint`, `effort`,
  `user-invocable`) since `agy` does not act on them.
- The bodies still contain some Claude-specific machinery references
  (Stop-hook gating, `/code-review`) whose per-agent equivalents are tracked
  follow-ups (#14/#15/#25). Each generated skill carries a caveat comment
  saying so; full cross-agent neutralization rides those issues.

Deeper hook parity — wiring a quality-gate Stop equivalent via
`~/.gemini/config/hooks.json`'s `Stop` event — is separate enforcement work,
tracked under #14/#25.

## Cross-agent invocation

When another agent's workflow needs Antigravity for a role it owns, it shells
out non-interactively:

```
agy -p "<prompt>"
```

See `base/roles.md` for the full cross-agent invocation table.
