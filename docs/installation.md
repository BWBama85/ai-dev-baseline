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
| `agents/claude/scripts/session-currency.sh` | `~/.claude/scripts/session-currency.sh` |
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

### Global lifecycle hooks

Unless `--no-hooks` is passed, `wire_hooks()` merges **every** hook-event group
in `agents/claude/settings.hooks.json` (with `__ADB_HOME__` substituted for your
real `$HOME`) into `~/.claude/settings.json`:

| Event | Script | What it does |
|---|---|---|
| `Stop` | `precommit-gate.sh` | Blocks ending a turn while the repo's quality gates are red. |
| `Stop` | `implement-issue-gate.sh` | Keeps an `/implement-issue` run going until its PR is open. |
| `SessionStart` (matcher `startup`) | `session-currency.sh` | Keeps the install-source clone current — see [Automatic currency](#automatic-currency-sessionstart). |

The merge is driven by that file's own top-level keys, so adding an event there
is the only edit a new hook needs. For each event it drops any group whose command
is **exactly one of the paths this install writes**
(`$HOME/.claude/scripts/<name>.sh`) and appends ours — so re-running `install.sh`
never double-adds them, and **your own hooks under any event are preserved**.
Matching the full path rather than the filename is what makes that promise real:
a basename match would also claim your own `/custom/precommit-gate.sh`, and since
the filters walk every event, uninstall would delete it from an unrelated event
such as `PreToolUse`. `uninstall.sh` is the exact mirror: it removes only those
entries and drops an event key once it is empty.

This step requires `jq`; if it's missing, the installer prints a warning and
skips wiring hooks without failing the rest of the install. A malformed
`~/.claude/settings.json` is also reported (and the file left alone) rather than
silently claimed as wired.

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

Then, **anywhere inside** any project's repo (it resolves the git root itself —
you don't have to be at the top level):

```bash
agent-init            # writes agents.toml at the git root if absent
agent-init --force     # overwrites an existing agents.toml
```

`agent-init` is repo-shape tolerant (#23): run from a subdirectory it still writes
at the git root, and it **surfaces** a non-tidy layout instead of silently guessing —
a repo nested inside an untracked parent tree (e.g. a plugin under a WordPress
install), a `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` that lives *outside* the repo, or a
monorepo/layered layout with multiple root docs. It reports what it can and cannot
see, then initializes only the resolved git root. A non-git directory is refused with
a clear message (nothing is written) — `git init` first if it really is a project.

## 7. Requirements

| Tool | Needed for |
|---|---|
| `git` | Cloning this repo; every skill's branch/PR flow. |
| `gh` | The issue/PR-touching skills (`implement-issue`, `create-issue`, `new-release`, `resolve-pr-threads`) and `implement-issue-gate.sh`'s live PR check. |
| `jq` | Wiring/unwiring the lifecycle hooks in `install.sh`/`uninstall.sh`; parsing state JSON in both gate scripts; the SessionStart hook's structured output; `agents.toml`-aware statusline fields. |

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

- It fast-forwards **only** when the install-source clone is **clean, free of an
  in-progress git operation, on its default branch, and merely behind** `origin`. A dirty /
  mid-rebase / detached / non-default / ahead / diverged clone is **surfaced and left
  untouched** — you reconcile it by hand. Those refusals are decided from **local state
  before any fetch**, so a run that will refuse costs no network round trip.
- After a fast-forward it **always** re-runs the **idempotent** installer (a pulled commit
  may add a new skill or script that existing links don't cover, so "links resolve" does
  not imply "everything is linked"), preserving the exact agent set and hook preference
  already installed, then **loudly verifies** every canonical link still resolves and fails
  if one is broken. When the clone is already **current**, it re-installs only if that
  verification finds a broken link.
- The mutating path takes a **per-clone lock**. Concurrent updates are ordinary now that a
  SessionStart hook can trigger several at once, so a second one exits `5` and steps aside
  instead of racing the first through pull + install. A lock left behind by a killed updater
  goes stale after 10 minutes (`ADB_UPDATE_LOCK_STALE_SECS`) **and its holder is gone** before it
  is broken — age alone is not death, and breaking a live updater's lock would run the pull twice.
- It exits **`6`** on a successful **same-HEAD repair**: the clone was already current, but a
  broken installed link was restored. Distinct from `0` ("nothing to do") because the installed
  surface changed while `HEAD` did not — a caller watching only `HEAD` cannot tell them apart.

`baseline update --check` prints one status word and changes nothing in the working tree;
its exit code is the stable contract the SessionStart hook consumes:
`0` current · `10` behind · `20` needs attention (dirty/in-progress/ahead/diverged/
detached/non-default) · `30` error (fetch failed / no `origin/<default>`).

### Automatic currency — two triggers

Running `baseline update` is still something you have to *remember*, and forgetting it
does not fail loudly — it silently runs **stale tooling**. So the install wires it for you, at
**two** points. Both read the same configuration and share one policy library
(`scripts/lib/currency-lib.sh`); they differ only in when they fire and in what they consider
worth reporting.

| Trigger | Fires | Agents | Issue |
|---|---|---|---|
| `SessionStart` hook (`session-currency.sh`) | a genuinely new session (`source: startup`) | Claude | #36 |
| the last step of `/cleanup` | after every sweep — i.e. right after a merge | Claude · Codex · Gemini | #139 |

**Why two.** The hook alone left a hole big enough to drive the whole loop through: it fires only
on `startup`, and the documented loop is `/implement-issue → merge → /cleanup → /clear → /roadmap`.
`/clear` is excluded by design, so the loop never re-checked — while staleness *begins* at the
merge. That is not theoretical: a `/roadmap` run once computed a release verdict with pre-fix logic
one commit after the fix shipped, and a later one derived dependency edges from a predicate two
commits stale. `/cleanup` is the natural second trigger because it runs immediately after the merge
and immediately before the `/clear` that the hook skips — and because it is agent-neutral, it is
also the only currency Codex and Gemini get.

The `SessionStart` hook is deliberately narrow about when it acts:

- **Only on `source: startup`** — a genuinely new session. `/clear`, `/compact`, `resume`
  and `fork` all happen with work already in flight, and swapping tooling underneath them
  is exactly the mid-session surprise this avoids.
- **Never the clone your session is working in.** If you start a session inside the
  install-source itself (or a subdirectory of it), the hook does nothing. A session in any
  *other* project still updates it.
- **Never over unsafe state** — it delegates to `baseline update`, so every refusal above
  applies unchanged.
- **Rate-limited** to one check per 10 minutes (`ADB_SESSION_UPDATE_INTERVAL_SECS`, `0` =
  every startup), and git is barred from interactive prompting so a session start can never
  block on a credential prompt or a stalled transfer.

Output is **one line or silence**: nothing at all when you are current, and otherwise a
single line naming what updated (`baseline: updated 0c3bbaf → 4eb472f (1 commit).`) or which
state needs attention. It always exits `0` — a SessionStart hook cannot block a session, and
currency must never be the reason one looks broken.

**Mode — configured globally, and only globally:**

```toml
# ~/.config/ai-dev-baseline/agents.toml
[updates]
session_start = "auto"    # auto (default) | notify | off
```

`auto` pulls and self-heals; `notify` reports **only** that you are behind and stays silent for
every other state (it is the mode chosen to be quiet — a clone deliberately parked on a branch
would otherwise produce an attention line at every startup, forever); `off` disables **both
triggers**. `ADB_SESSION_UPDATE` overrides it for one run. A copy of this key in a **project's**
`agents.toml` is ignored on purpose — whether your global tooling updates itself must not depend on
which repo you happened to open.

`notify` means: never changes the working tree or the installed payload. It does still fetch
remote-tracking refs, which is what makes "you are behind" a fact rather than a memory.

The key is still spelled `session_start` although it now governs a trigger that is not a session
start. That is kept for backward compatibility — a key that silently stopped applying would
re-enable an updater someone had deliberately switched `off`.

**The two triggers differ in what they report, on purpose.** The hook is unattended, so it says
nothing when a peer update holds the lock or the remote is unreachable — otherwise every session
start would nag about a missing network. `/cleanup` reports both, because there you explicitly
asked for a currency check and silence would be indistinguishable from success.

**`/cleanup` ignores the rate-limit interval.** The shared stamp records the last *attempt* and
cannot tell "startup just checked and nothing changed" from "startup checked, then a merge landed".
Suppressing the post-merge check would defeat the point, so the deliberate trigger always runs —
and still refreshes the stamp, so the next session start is suppressed by it. Two sweeps in a row
therefore each fetch, which is the right cost for something you asked for.

In `auto` mode a refusal *is* reported, because that mode promised to act and could not — silence
there would be the staleness this whole feature exists to catch.

**Two things worth knowing.** First, `auto` means each new session may fetch and then execute
the newly pulled `install.sh`; that is the same trust you already place in the clone your
whole toolchain is symlinked from, but it is now exercised automatically — use `notify` if you
would rather review each pull. Second, the hook runs *after* the session has loaded its global
root doc, so an update that changes `CLAUDE.md` fully applies from the **next** session; skills
are re-read via `reloadSkills`.

**Upgrading an existing install:** the hook can only wire itself by being installed, so a bare
`git pull` in your clone is not enough. Run `baseline update` (or `./install.sh`) **once** by
hand after upgrading; every session after that is automatic. An install made with `--no-hooks`
stays opted out.

**Neither trigger can bootstrap itself, and the `/cleanup` one is the easier to misread.** Your
installed skills are symlinks into the install-source clone, so the `/cleanup` you invoke
immediately after this change lands is still the **old** one — it has no currency step, and its
silence looks exactly like "already current". Run `baseline update` by hand once; from the next
sweep on it carries itself. The same applies to a `--no-hooks` install, where `/cleanup` becomes
your *only* automatic trigger.

**One thing an update does not do:** a project's *composed* skills — a partial override merged onto
a base skill — are not recomposed when the base skill changes. Their staleness is a separate check;
see issue #64.

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

The SessionStart hook respects the same split from the other direction: it always targets the
install-source (resolving it the same way `baseline` does, never via `PATH`), and it skips
entirely when the session you just started is *inside* that clone. So a session in the dev
clone updates the install-source; a session in the install-source updates nothing.

## Uninstalling

```bash
cd ~/Code/ai-dev-baseline
./uninstall.sh                     # all agents present (claude, codex, gemini)
./uninstall.sh --agent claude
```

`uninstall.sh` only removes a destination if it is **currently a symlink
pointing somewhere inside this repo** (`adb_unlink_if_ours`) — a real file, or a
symlink pointing elsewhere, is left alone and reported as `skip ... (not
ours)`. It also strips the baseline's own hook entries — the two `Stop` gates
and the `SessionStart` currency check — out of `~/.claude/settings.json` (again
via `jq`, matched by filename) and removes a hook-event key entirely once that
leaves it empty. Hooks you added yourself under the same events are left alone.
Removing the SessionStart entry matters as much as unlinking the script: a
leftover entry pointing at a deleted command would error on every future
session. Your backups under
`~/.claude/backups/ai-dev-baseline-*` are **never** touched by uninstall —
restore from them by hand if you want the pre-install files back.

## See also

- [philosophy.md](philosophy.md) — why the baseline is installed globally
  rather than per-project.
- [roles-and-agents.md](roles-and-agents.md) — the manifest written to
  `~/.config/ai-dev-baseline/agents.toml` and how it's consumed.
- [per-project-overrides.md](per-project-overrides.md) — layering
  project-specific rules once the global baseline is installed.
