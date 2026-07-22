# Installation

## 1. Clone the repo

Clone it somewhere stable — you're going to symlink into it, so don't clone
it into a temp directory or delete it later.

```bash
git clone git@github.com:BWBama85/ai-dev-baseline.git ~/Code/ai-dev-baseline
```

## 2. Run the installer

```bash
cd ~/Code/ai-dev-baseline
./install.sh                       # installs the 'claude' agent + wires gates
./install.sh --agent claude --agent codex
./install.sh --agent claude --no-hooks
```

Options:

| Flag | Effect |
|---|---|
| `--agent <claude\|codex\|gemini>` | Repeatable. Which agent(s) to install. Default: `claude`. |
| `--no-hooks` | Skip wiring the global Stop-hook gates into `~/.claude/settings.json`. |
| `-h`, `--help` | Print the usage header. |

`codex` and `gemini` run their `agents/<token>/adapter.sh`, which symlinks that
agent's generated root doc (`agents/codex/AGENTS.md` → `~/.codex/AGENTS.md`;
`agents/gemini/GEMINI.md` → `~/.gemini/GEMINI.md`) with the same backup +
idempotence behavior as the Claude install, and points you at the
operator-managed config (a sample lives at `agents/codex/config.toml.sample` /
`agents/gemini/config/hooks.sample.json`). This installs the shared **practices**
into those agents today; deeper per-agent **workflow** parity (rendering
`implement-issue`/`cleanup`/`debug` as Codex- or Antigravity-native flows) is
tracked as follow-up issues. See each agent's README under `agents/<token>/`.

## 3. What gets symlinked for Claude

`install_claude()` in `install.sh` links, one by one:

| Source (in this repo) | Destination |
|---|---|
| `agents/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `agents/claude/skills/<name>/` (each skill dir) | `~/.claude/skills/<name>` |
| `agents/claude/scripts/precommit-gate.sh` | `~/.claude/scripts/precommit-gate.sh` |
| `agents/claude/scripts/implement-issue-gate.sh` | `~/.claude/scripts/implement-issue-gate.sh` |
| `agents/claude/scripts/statusline.sh` | `~/.claude/scripts/statusline.sh` |
| `scripts/lib/` (the shared shell library) | `~/.claude/scripts/lib` |

The shared shell library (`scripts/lib/common.sh` + `project-gates.sh`) installs as
`~/.claude/scripts/lib` so the runtime gates can source it as a sibling. An install
made before the library moved to `scripts/lib` still points `~/.claude/scripts/lib` at
`agents/claude/scripts/lib`; that path is now a **compatibility symlink** back to
`scripts/lib`, so a plain `git pull` keeps such installs' gates working without a
re-install (re-running `install.sh` self-heals them to the direct link).

Every link is created by the shared `adb_link()` helper (from `scripts/lib/common.sh`,
sourced by `install.sh`) that is **idempotent**:

- If the destination is already a symlink pointing at the right source, it's
  left alone (`ok`).
- If it's a symlink pointing somewhere else, it's replaced.
- If it's a real file or directory, it's **backed up** first (see below),
  then replaced with the symlink.

Because these are real symlinks (not copies), `git pull` inside
`~/Code/ai-dev-baseline` immediately updates the practices, skills, and gates
in **every** project on the machine — there is no per-repo sync step.

### Global Stop-hook gates

Unless `--no-hooks` is passed, `wire_hooks()` merges the two Stop-hook gate
entries from `agents/claude/settings.hooks.json`
(`precommit-gate.sh` and `implement-issue-gate.sh`, with `__ADB_HOME__`
substituted for your real `$HOME`) into `~/.claude/settings.json`, replacing
any prior entries that reference those same two gate scripts by filename
(so re-running `install.sh` never double-adds them). This step requires `jq`;
if it's missing, the installer prints a warning and skips wiring hooks
without failing the rest of the install.

`~/.claude/settings.json` itself is backed up before being modified (see
below), even though it's edited in place rather than replaced by a symlink.

## 4. Backups

Anything the installer would overwrite — an existing non-symlink
`~/.claude/CLAUDE.md`, a pre-existing skill directory, an existing
`~/.claude/settings.json` — is moved (or copied, for `settings.json`) into a
timestamped backup directory first:

```
~/.claude/backups/ai-dev-baseline-<YYYYMMDD-HHMMSS>/
```

The path structure under that backup directory mirrors the original absolute
path (e.g. a backed-up `~/.claude/CLAUDE.md` lands at
`~/.claude/backups/ai-dev-baseline-.../<HOME>/.claude/CLAUDE.md`). `uninstall.sh`
does **not** restore from these backups automatically — restore manually if
you want your pre-install files back.

## 5. Global default role manifest

The installer also writes a global default agent-role manifest, once:

```
~/.config/ai-dev-baseline/agents.toml
```

It's a straight copy of `templates/agents.toml` (see
[roles-and-agents.md](roles-and-agents.md) for what it contains), written
only if that file doesn't already exist — re-running `install.sh` never
clobbers a manifest you've since edited.

## 6. Put `bin/` on PATH

`bin/agent-init` is the per-project initializer (drops a project-local
`agents.toml`, ensures `.claude/state/` is gitignored, prints the effective
role map). Add the repo's `bin/` directory to your `PATH` so `agent-init`
resolves from any repo:

```bash
export PATH="$HOME/Code/ai-dev-baseline/bin:$PATH"   # add to your shell rc
```

`agent-init` resolves its own location through symlinks (it follows
`BASH_SOURCE[0]` until it stops being a symlink), so it works whether you
call it directly from the clone or through something else on PATH that
symlinks to it. The same `bin/` directory also carries **`baseline`**, the
keep-current command (see [Keeping the install current](#keeping-the-install-current)).

Then, at the root of any project:

```bash
agent-init            # writes ./agents.toml if absent
agent-init --force     # overwrites an existing agents.toml
```

## 7. Requirements

| Tool | Needed for |
|---|---|
| `git` | Cloning this repo; every skill's branch/PR flow. |
| `gh` | The issue/PR-touching skills (`implement-issue`, `create-issue`, `new-release`, `resolve-pr-threads`) and `implement-issue-gate.sh`'s live PR check. |
| `jq` | Wiring/unwiring the Stop hooks in `install.sh`/`uninstall.sh`; parsing state JSON in both gate scripts; `agents.toml`-aware statusline fields. |

Without `jq`, hook wiring is skipped (with a warning) but the rest of the
install still completes. Without `gh`, the install itself still works — only
the `gh`-dependent skills and the gate's fallback PR check are affected at
use time.

## 8. A repo's own gate always wins

Both `precommit-gate.sh` and `implement-issue-gate.sh` check, before doing
anything else, whether the current repo ships its **own** copy of that same
script at `.claude/scripts/<name>.sh`. If it does — and it isn't literally the
same file as the one running (checked with `[ ... -ef ... ]`, i.e. same
inode) — the global gate exits `0` immediately and defers entirely to the
project's version. This means installing the global baseline is always safe
to layer on top of a repo that has already built its own gate: nothing
double-runs. See [per-project-overrides.md](per-project-overrides.md) for how
a project uses this deliberately.

## Keeping the install current

Because the payloads are symlinks, the live global env is only as current as the
clone they point into. Keeping that clone current used to be a remembered ritual —
`git pull` in the clone, plus a re-run of `install.sh` if a PR moved an installed
path. `bin/baseline` replaces the ritual:

```bash
baseline update            # fast-forward the install-source clone + self-heal moved links
baseline update --check    # report currency only; make NO changes (for a lifecycle hook)
```

`baseline update` is deliberately conservative — currency is a convenience, never a
cause of lost work:

- It fast-forwards **only** when the install-source clone is **clean, on its default
  branch, and merely behind** `origin`. A dirty / detached / non-default / ahead /
  diverged clone is **surfaced and left untouched** — you reconcile it by hand.
- After a fast-forward it re-runs the **idempotent** installer **only when an installed
  path actually moved** (a symlink stopped resolving), preserving the exact agent set
  and hook preference already installed, then **loudly verifies** every canonical link
  still resolves and fails if one is broken.

`baseline update --check` fetches, prints one status word, and changes nothing; its
exit code is a stable contract for a future `SessionStart` lifecycle hook (issue #25):
`0` current · `10` behind · `20` needs attention (dirty/ahead/diverged/detached/
non-default) · `30` error (fetch failed / no `origin/<default>`).

### The two-clone topology

A framework developer typically keeps **two** clones:

| Clone | Role | Kept current by |
|---|---|---|
| **install-source** (e.g. `~/Code/ai-dev-baseline`) | The clone the global symlinks point into and whose `bin/` is on `PATH`. Its git state feeds every project. | `baseline update` |
| **dev clone** (e.g. `~/Code/ai-dev-baseline-dev`) | Where you edit the framework and open PRs. | `/implement-issue`'s preflight auto-sync (issue #17) |

`baseline update` operates on the **install-source** — the clone it detects the global
install pointing into. Run it from any *other* clone and it **refuses** (exit `4`),
naming the install-source, so a dev clone is never mistaken for it. The dev clone is
kept current separately: after a PR merges, the next `/implement-issue` auto-syncs it
to a clean, current default branch.

## Uninstalling

```bash
cd ~/Code/ai-dev-baseline
./uninstall.sh                     # all agents present (claude, codex, gemini)
./uninstall.sh --agent claude
```

`uninstall.sh` only removes a destination if it is **currently a symlink
pointing somewhere inside this repo** (`adb_unlink_if_ours`) — a real file, or a
symlink pointing elsewhere, is left alone and reported as `skip ... (not
ours)`. It also strips the two named Stop-hook gate entries out of
`~/.claude/settings.json` (again via `jq`, matched by filename) and removes
the `hooks.Stop` key entirely if that leaves it empty. Your backups under
`~/.claude/backups/ai-dev-baseline-*` are **never** touched by uninstall —
restore from them by hand if you want the pre-install files back.

## See also

- [philosophy.md](philosophy.md) — why the baseline is installed globally
  rather than per-project.
- [roles-and-agents.md](roles-and-agents.md) — the manifest written to
  `~/.config/ai-dev-baseline/agents.toml` and how it's consumed.
- [per-project-overrides.md](per-project-overrides.md) — layering
  project-specific rules once the global baseline is installed.
