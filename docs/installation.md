# Installation

## Two install models

There are two, and they answer different questions. Everything from *"1. Clone the repo"* to
*"Keeping the install current"* describes the **global symlink install**; the second model has its
own section, [Release-pinned, per project](#release-pinned-per-project).

| | **Global symlink** | **Release-pinned, per project** |
|---|---|---|
| What it is | a permanent clone symlinked into `~/.<agent>` | one released version vendored into one project tree |
| Scope | every project on the machine | exactly the project it is installed in |
| Version | whatever the clone's `main` says right now | the release named in `.ai-dev-baseline/upstream.toml` |
| Updating | `git pull` reaches every project at once | `baseline pinned upgrade --to X.Y.Z`, never on its own |
| Needs a clone | yes, forever | no |
| Committed to the project | no | yes — the payload ships with the repo |
| Agents | claude · codex · gemini | claude · codex |

**They coexist, and neither one degrades the other.** A machine can run the global install and
still open a project that carries a pinned payload: the agent harness resolves a project's own
skills ahead of the user-global ones ("most specific wins" —
[per-project-overrides.md](per-project-overrides.md), Override 2), so inside such a project the
pinned version governs, and everywhere else the global install does. Nothing arbitrates that at
install time; it is the harness's own precedence, and `baseline pinned status` reports the overlap
rather than pretending to resolve it.

**Pick the global model** when the machine is yours and you want one `git pull` to update
everything. **Pick the pinned model** when a project must state which baseline it runs — a repo
other people clone, a build that has to be reproducible, or any machine where keeping a permanent
clone is not an option.

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
| `agents/claude/scripts/state-claim-gate.sh` | `~/.claude/scripts/state-claim-gate.sh` |
| `agents/claude/scripts/session-currency.sh` | `~/.claude/scripts/session-currency.sh` |
| `agents/claude/scripts/session-context.sh` | `~/.claude/scripts/session-context.sh` |
| `scripts/lib/` (the shared shell library) | `~/.claude/scripts/lib` |

The shared shell library (`scripts/lib/common.sh` + `project-gates.sh`) installs as
`~/.claude/scripts/lib` so the runtime gates can source it as a sibling. An install
made before the library moved to `scripts/lib` still points `~/.claude/scripts/lib` at
`agents/claude/scripts/lib`; that path is now a **compatibility symlink** back to
`scripts/lib`, so a plain `git pull` keeps such installs' gates working without a
re-install (re-running `install.sh` self-heals them to the direct link).

### When a path is retired

A **move** keeps its old path alive as a compat symlink, as above. A **retirement** —
a payload deleted outright — has nothing to point one at, so the old link is *removed*
instead: `install.sh` and `uninstall.sh` both sweep a small register of retired
destinations (`adb_agent_manifest_retired` in `scripts/lib/common.sh`) and unlink each
one that is still this install's own symlink to the now-absent source. A real file you
put there, a link pointing somewhere else, and a link that still resolves are never
touched.

The sweep needs *something* to run, so a plain `git pull` alone leaves the dead link in
place until the next `install.sh`, `baseline update`, or session-start currency check —
harmless, since nothing referenced it, and `baseline update`'s orphan prune catches it
even if the register has since been trimmed. `scripts/check-install-migration.sh`
enforces the distinction in CI: an undeclared dangling link still fails and still asks
for a compat shim, and a declared one is only accepted once the installer is observed
actually removing it.

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
| `Stop` | `implement-issue-gate.sh` | Keeps an `/implement-issue` run going until its PR is open — for **that session's own** run; see [Run markers are session-owned](#run-markers-are-session-owned). |
| `Stop` | `state-claim-gate.sh` | Blocks ending a turn that states a PR/issue/CI status the turn did not read. |
| `SessionStart` (matcher `startup`) | `session-currency.sh` | Keeps the install-source clone current — see [Automatic currency](#automatic-currency-sessionstart). |
| `SessionStart` (matcher `compact\|resume`) | `session-context.sh` | Reads an in-flight `/implement-issue` run's state back into context after compaction or resume — see [A run survives compaction](#a-run-survives-compaction). |

Removing a hook's entry from `~/.claude/settings.json` is the per-hook opt-out, and `baseline
update` preserves it: a hook whose script link is installed but whose entry is gone is left alone
(the set is reported as PARTIAL). A hook shipped **after** your last install has neither an entry
nor a script link, and that is not a choice anybody made — the next `baseline update` links and
wires it (`adb_claude_hooks_missing_deliberate` is what tells the two apart, reading the **wiring
receipt** `~/.claude/.adb-hooks-wired` that a successful `install.sh` writes and `uninstall.sh`
removes: an entry the receipt says was wired and is now gone was removed by you; a link the
receipt never saw wired was an install interrupted between the link and the entry, and is
repaired. An install that predates the receipt has none until its next successful wiring, and
until then the link alone is read as the choice — which holds because
an install whose hook wiring **fails** takes back the links it added — restoring whatever each one
displaced — so an interrupted install never leaves the opt-out's shape behind). **Unless the set
also carries a deliberate opt-out:** `install.sh --no-hooks` is all-or-nothing, so a mixed set —
one entry you removed plus one hook that just shipped — keeps the opt-out and leaves the new hook
**unlinked** as well as unwired (a linked-but-unwired hook would read as a second opt-out on the
next update), restoring anything the install displaced at that path; the update says so every run, and `./install.sh` wires the full set (which re-adds
the one you removed). The per-hook form that resolves this is #444.

### Run markers are session-owned

`/implement-issue` records its in-flight run in `.claude/state/implement-issue-active.json`, and
`implement-issue-gate.sh` reads that marker at every turn-end to decide whether the run still owes
a PR. The marker carries an **`owner`** — the id of the session that started the run — and the
hook compares it against its own session before treating the marker as its own.

That comparison is what makes **more than one Claude session in a single clone** safe. A checkout
is a working-tree property: every session sees the same current branch, so a marker matched on
branch name alone matched *every* session in that clone. A session that had never run
`/implement-issue` was once told to `gh pr create` on another session's branch that already had an
open PR. A marker whose owner is another session is now left strictly alone — not acted on, not
deleted, and never overwritten with a blocked file.

Two properties are worth knowing because they are deliberate choices, not accidents:

- **An unowned marker is still enforced.** A marker written before this field existed, or by an
  agent whose harness exposes no session id, falls back to branch-name matching. Enforcement code
  going quiet when it is unsure would silently switch the invariant off, which is worse than one
  misdirected hint.
- **It does not make two concurrent runs safe.** Both runs write the same fixed filenames, and a
  new run's preflight clears them unconditionally, so a second `/implement-issue` in the same
  clone can still delete the first one's marker. Ownership makes the *reader* safe, not the
  *path* exclusive — see issue #202.

### A run survives compaction

A long `/implement-issue` run outlives its context window: the harness compacts mid-step, and the
summary may or may not carry which step it was on or where its findings live. The state directory
already holds those facts, so `session-context.sh` reads them back. On `SessionStart` with `source`
`compact` or `resume` (the matcher is `compact|resume`; `startup` belongs to the currency hook and a
`clear` starts a conversation whose run is over by construction) it asks
`scripts/lib/run-state.sh summary` for the run live in `<repo>/.claude/state` and injects the answer
as `hookSpecificOutput.additionalContext`: the phase and its append-only history (#243), the
branch, the issue **numbers**, the PR, whether a blocked marker was written (its path, never its
reason), the **paths** of the gap/review/docs artifacts — every path relative to the repository
root (`.claude/state/…`), because a checkout directory is named by whoever cloned it and a name is
prose — and a count of `REQUIRED` marks in
`review.md`. Before the branch
exists — the long gap-analysis pass — the run claim is the liveness signal and the issue snapshots
name the issues.

**It runs once per checkout.** A release-pinned project vendors this hook under `.claude/adb/` and
wires it in the project's `.claude/settings.json`, and Claude Code merges hooks across settings
scopes rather than overriding them — so on a machine that also carries the global install both
copies would fire on every compact and resume, injecting the same state twice, possibly through two
reader versions. The global copy therefore defers when the vendored hook exists, is executable and readable beside
its (readable) libraries,
**and** is wired there in a `SessionStart` group whose matcher covers the current `source` (it says
so on stderr); a vendored file that is not wired, not runnable, a group matched to some other
source, or a `settings.json` it cannot read, leaves the global hook running — one injection either
way, never zero. The wiring is recognised by
the exact command the pinned installer writes, never by a suffix. The hook acts only on a payload
whose `cwd` is an absolute path, hands the reader the repository root, and the reader refuses a
`.claude/state` that is not physically inside it (a symlink to another checkout would summarise that
run as this one) and any symlinked record.

**It says whether the checkout is still on the run's branch.** Another session, or the operator, may
have switched the shared checkout since the marker was written; the hook hands the live branch to
the reader, which reports `checkout: on the run's branch` or `checkout: NOT on the run's branch — …`
without naming the live branch (the Stop gate treats the same mismatch as "not this run"; the
reader reports it so the resumed agent does not continue on the wrong branch).

Three properties are deliberate:

- **Owner-scoped, like the Stop gate.** A marker whose `owner` is another session earns one line
  naming the path and no facts; the owner id is never printed. A harness that exposes no session id
  is compatible with any marker, exactly as `implement-issue-gate.sh` treats it.
- **Facts the run wrote, never text it collected.** Only closed-grammar values are injected — a
  phase word, a branch with no whitespace or control characters, numbers, timestamps, paths, a
  count. `gap-prompt.txt`, `gaps.md`, `review.md` and the blocked marker's `reason` carry free
  text, and what this hook emits lands in a model's context, so they are named by path and never
  quoted. A marker with any field outside the grammar — a non-string (`false` included), any
  whitespace or any character of Unicode category Cc/Cf/Zl/Zp, a `prUrl` that is not `https://<host>/<owner>/<repo>/pull/<n>` (hostname labels, a real port, an owner without dots, a repository name that is not a dot segment), a phase outside the nine the workflow writes, a branch that is not the workflow's `issue-<n>[-<n>…]-<slug>` shape, an issue number that is not positive and canonical, a branch whose issue prefix disagrees with the issue list, a February 29 outside a leap year,
  a history that disagrees with `.phase` — is refused whole. The injected text is capped below
  the harness's 10,000-character hook-output limit (`ADB_SESSION_CONTEXT_MAX_CHARS`, default 9500,
  clamped to 1024–9500 so the facts survive the cap and the cap stays under the limit) and says so
  when it was cut.
- **It never blocks, and its audit is written twice.** Exit 0 on every path the script reaches;
  stdin is read with a five-second bound so an open pipe cannot spend the hook's timeout; nothing
  is injected when no run is live. One stderr line names what was summarised (the debug log), and
  the summary's own `run-state:` line — right below the provenance header — names the state
  directory that was read (the transcript).
  `ADB_SESSION_CONTEXT=off` disables it with one stderr line.

The root docs carry a `# Compact instructions` section (rendered from
`base/practices/compact-instructions.md`) telling the compactor what to preserve — the run phase,
the state-directory path, the modified files, the gate command, every open `REQUIRED` finding.
That is guidance to the summarizer; the hook is the mechanism that restores the marker's facts
regardless of what the summary kept.

### The state-claim gate

`state-claim-gate.sh` lints the turn's final message for **volatile external status stated without
a read in that turn** — the failure `base/practices/verify-before-asserting.md` describes. It
applies one small, documented rule (`state-assert.sh lint`):

> In prose, a status word appearing in the same sentence as an issue/PR reference must itself be
> introduced by `was observed`.

When it fires, it names the offending excerpt and the command that can answer that *kind* of claim
(PR/issue state, CI, or branch-merged — they have different homes), and the turn does not end until
the claim is re-read or removed.

It is deliberately **precision-first**: quoting a status inside a fence, a code span, a blockquote
or an HTML comment declares nothing, `open a PR` / `closed #195` are treated as verbs, a status
word directly before one of a few curated nouns is attributive rather than predicative (`merged
files`, `green suite`) unless a copula or possession verb precedes it, `in passing` is an idiom
unless its preposition is a verb's complement (`resulted in passing` still fires), and words that
collide too often with ordinary prose are kept out of the token set entirely. Emphasis or a
markdown link around a neighbouring word does not break adjacency; clause punctuation does. It
also never wedges a session — a missing `jq`, a text-free turn or a broken linter install are all
reported on stderr and then allowed through.

It reads the turn's final message from the hook payload's `last_assistant_message`, and falls back
to the transcript file whenever that yields nothing — an older CLI omits the field, and so does a
current one when the final message carries no text. On that fallback path an unreadable transcript
is a no-op, and so is a transcript whose newest assistant text predates the last user record, which
is how a not-yet-written final message is told apart from a real one.

To turn it off, remove its entry from `~/.claude/settings.json`, or shadow it per-repo with your
own `.claude/scripts/state-claim-gate.sh` (see [A repo's own gate always wins](#8-a-repos-own-gate-always-wins)).

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

### bash 5.3 is a hard floor

Every entry point checks its own interpreter before doing anything else. If the
one it got is below **5.3**, it **re-execs** into a newer one it finds at a fixed
path; if there is none, it **exits non-zero** and prints your platform's install
command. There is no flag to lower it.

| Platform | How to get bash >= 5.3 |
|---|---|
| **macOS** | `brew install bash`. `/bin/bash` is **3.2.57** and has been for the whole bash-4-and-later era; Apple has shown no sign of shipping a newer one. Homebrew is the usual route; MacPorts, Nix and a source build into `/usr/local` are searched too (see the `PATH` note). |
| **Ubuntu 26.04+** | Ships 5.3 — nothing to do. |
| **Ubuntu 24.04 / <= 25.10** | Below the floor (24.04 ships 5.2.x). Upgrade the release, use a backport, or build from source. |
| **Debian stable** | Below the floor (5.2.x). Same three options. |
| **Fedora** | `sudo dnf install bash` |
| **RHEL / CentOS / Rocky / Alma** | **`dnf install bash` will not clear the floor** — RHEL 9's bash is 5.1.x. Build from source, or use a backport / third-party build. |
| **Arch** | `sudo pacman -S bash` |
| **Alpine** | `apk add bash` |
| **Windows** | **WSL2 only** — see below. |

Exact patch levels move; check your own distribution's package index rather than
trusting a version pinned in this table. The floor itself does not move: **5.3**.

**macOS: it is a `PATH` problem, not an install problem.** Homebrew installs
5.3 *alongside* Apple's 3.2.57 rather than replacing it, so which one a
`#!/usr/bin/env bash` script gets is decided entirely by `PATH` ordering. A
`PATH` that lists `/usr/bin:/bin` **before** `/opt/homebrew/bin` still resolves
the 2006 interpreter, even though `brew install bash` succeeded. Homebrew warns
about this at install time (`shadowed by /bin/bash`) and it is easy to miss.
Non-interactive shells — hooks, gate scripts, anything another agent's CLI
spawns — often carry no Homebrew prefix at all. This is why the gate re-execs
rather than merely complaining, and it means you do not have to get `PATH` right
for the framework to work.

**Which locations it searches**, in order, before falling back to `PATH`:
`/opt/homebrew/bin` (Homebrew, Apple Silicon) · `/usr/local/bin` (Homebrew on
Intel, and the default `make install` prefix, so source builds land here) ·
`/opt/local/bin` (MacPorts) · the Nix system and user profiles · `/usr/bin` ·
`/bin`. If your bash 5.3 lives somewhere else entirely, put its directory on
`PATH` — that is the last thing checked, so it still works, and the failure
message lists every path it tried.

### Windows: WSL2 only

Windows is supported **through WSL2 and nothing else**. WSL2 *is* Linux — same
interpreter, same userland, same symlinks — so there is no separate Windows port
to install. Git Bash / MSYS2 and Cygwin are **not** supported: MSYS2 is a
different userland that has had no portability pass here, and Cygwin's bash
(5.2.x at the time of writing) is below the floor regardless.

Two things to get right:

1. **The distro must ship bash 5.3.** `wsl --install` may still default to an
   Ubuntu LTS that does not — 24.04 ships `5.2.21`. Install a 26.04 distro:
   ```powershell
   wsl --install -d Ubuntu-26.04
   ```
2. **Clone inside the WSL filesystem, not under `/mnt/c`.** Two distinct
   failures live there:
   - **CRLF.** A clone made by *Windows* git with `core.autocrlf=true` and then
     run from WSL gives every script `\r` line endings, and the symptom is the
     unhelpful `bash: $'\r': command not found` — on every entry point at once.
     `install.sh` preflights for this and fails with the remedy, and
     `.gitattributes` pins `*.sh` (and the extensionless `bin/` commands) to LF
     so a fresh clone cannot acquire it. A checkout that is *already* fully
     corrupted cannot run the preflight at all — `./install.sh` dies on its own
     shebang first — so if you see that `$'\r'` error, re-clone inside WSL.
   - **DrvFs semantics.** Exec bits and file modes on `/mnt/c` do not behave like
     a Linux filesystem without the `metadata` mount option, and it is markedly
     slower. `install.sh` **warns** here rather than failing.

   The install *destination* is fine either way: `$HOME` under WSL is the Linux
   home, so `~/.claude` and its symlinks land on the Linux filesystem regardless.

### Tools

| Tool | Needed for |
|---|---|
| `git` | Cloning this repo; every skill's branch/PR flow. |
| `gh` | The issue/PR-touching skills (`implement-issue`, `create-issue`, `new-release`, `resolve-pr-threads`) and `implement-issue-gate.sh`'s live PR check. |
| `jq` | Wiring/unwiring the lifecycle hooks in `install.sh`/`uninstall.sh`; parsing state JSON in both gate scripts; the SessionStart hook's structured output. |

Without `jq`, hook wiring is skipped (with a warning) but the rest of the
install still completes — and the hook script links that run would have added are taken
back, so the set reads as "not yet installed" rather than as a per-hook opt-out; install
`jq` and re-run to get them. Without `gh`, the install itself still works — only
the `gh`-dependent skills and the gate's fallback PR check are affected at
use time.

Bash is different from all three: it is not degradable, so it is checked and
enforced rather than warned about.

## 8. A repo's own gate always wins

`precommit-gate.sh`, `implement-issue-gate.sh` and `state-claim-gate.sh` each check, before doing
anything else, whether the current repo ships its **own** copy of that same
script at `.claude/scripts/<name>.sh`. If it does — and it isn't literally the
same file as the one running (checked with `[ ... -ef ... ]`, i.e. same
inode) — the global gate **`exec`s the project's copy**, which then *is* the
gate: it inherits stdin (the hook payload) and its exit status becomes the
hook's, so a project gate can still block a stop with `2`. This means
installing the global baseline is always safe to layer on top of a repo that
has already built its own gate: nothing double-runs, and the project's policy
wins. See [per-project-overrides.md](per-project-overrides.md) for how a
project uses this deliberately.

It `exec`s rather than exiting `0` because **nothing else invokes a project
gate** — the install wires only the global paths (#240). Stepping aside left
a repo with a gate script nothing ran and the global gate stood down, i.e.
enforcement silently off.

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

## Release-pinned, per project

The second model. It vendors **one released version** into **one project tree** — no clone, no
symlinks, and no dependency on what any machine's `main` happens to say. The project records which
version it is on, and nothing moves it until someone names a new one.

### Getting it in the first place

The payload comes from a published GitHub Release, never from a checkout — so the bootstrap is a
download you verify yourself, and every command after it runs from the vendored copy:

```bash
V=2.2.0
curl -fsSLO "https://github.com/BWBama85/ai-dev-baseline/releases/download/v$V/ai-dev-baseline-$V.tar.gz"
curl -fsSLO "https://github.com/BWBama85/ai-dev-baseline/releases/download/v$V/SHA256SUMS"
shasum -a 256 -c SHA256SUMS          # or: sha256sum -c SHA256SUMS
tar xzf "ai-dev-baseline-$V.tar.gz"

cd /path/to/your/project
bash "/path/to/ai-dev-baseline-$V/install.sh" --pinned --project . --version "$V" --agent claude
```

The installer **re-fetches and re-checksums the release artifact** even when you run it out of an
unpacked one. That is deliberate: what lands in your project is then a *named published version*
rather than whatever tree the driver happened to be sitting in, and it is the same code path
whether you started from a download or from a full clone. To install from the copy you already
have — an air-gapped machine, or media — hand it the pair directly and skip the second fetch:

```bash
bash install.sh --pinned --project . --artifact ../ai-dev-baseline-2.2.0.tar.gz --sums ../SHA256SUMS
```

Either way the archive's SHA-256 is checked **against the `SHA256SUMS` record naming that exact
filename** before anything is unpacked. The tree is then rejected if it carries an absolute or
`../` member, if a symlink in it resolves outside the tree, if its internal
`ai-dev-baseline-<version>/` prefix disagrees with the filename, if it arrived with CRLF line
endings, or if it carries no `scripts/lib/pinned-install.sh` — a release published before this
feature existed, which could never give the project the `status` / `upgrade` / `uninstall` commands
below. That last test is the real floor; the version comparison is only a coarse one.

Note what two assets from one Release do and do not prove: they detect **corruption and
truncation**, not authenticity — an attacker who can replace one can replace both.

### What gets vendored, and where

| Path in your project | What |
|---|---|
| `.claude/rules/ai-dev-baseline.md` | the practices — a rule with no `paths:` frontmatter loads at session start |
| `.claude/skills/<name>/SKILL.md` | the workflows, shadowing any same-named global skill |
| `.claude/adb/lib/*.sh` | the shared shell libraries the skills and gates call |
| `.claude/adb/{precommit,implement-issue,state-claim}-gate.sh` | the Stop gates |
| `.claude/adb/session-context.sh` | the `SessionStart` run-state hook (#431): on `compact\|resume` it reads the project's own `.claude/state` back into context |
| `.claude/settings.json` | the Stop gates and the `SessionStart` hook wired through `${CLAUDE_PROJECT_DIR}` (merged, never replaced) — each under its own event, the hook with the `compact\|resume` matcher |
| `.codex/skills/<name>/SKILL.md`, `.codex/adb/…` | the same, for Codex |
| `AGENTS.md` | Codex's practices, inside a delimited managed region |
| `.ai-dev-baseline/upstream.toml` | the pin — `mode`, `version`, `source`, `artifact` (the release archive's SHA-256), `adopted`, `agents`, and `stack` when a previous pin recorded one |
| `.ai-dev-baseline/pinned-files.sha256` | the receipt: every file this install wrote, and its digest |

Four of those choices are decisions rather than layout, and each is load-bearing:

- **`.claude/adb/`, not `.claude/scripts/`.** The latter is
  [`handling-the-unknown.md`](../base/practices/handling-the-unknown.md)'s one prescribed home for
  a project's *own* gate policy. An install that wrote there would occupy the path the practice
  reserves for you — so a pinned project can still ship `.claude/scripts/precommit-gate.sh`, and
  the vendored gate steps aside for it exactly as the global one does.
- **The gates and `lib/` are siblings.** Every gate resolves its library as
  `$(dirname "$0")/lib/common.sh`, which is what lets them be vendored byte-unchanged.
- **The payload is re-anchored at install time** — the skills *and* the practices. A rendered skill
  reaches its libraries through `$HOME/.<agent>/scripts/lib/`, one directory shared by the global
  install and by every project on the machine; so do the practice documents, which spell out
  `bash "$HOME/.claude/scripts/lib/ci-health.sh" classify …`. Every such reference in the vendored
  copies is rewritten to `$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.<agent>/adb/lib/`
  instead, so two projects pinned to different versions cannot reach into each other, and no
  absolute path is committed.
- **`session-currency.sh` is not vendored.** It fast-forwards the install-source clone, and a
  pinned project has none. `session-context.sh` **is**: it reads the project's own `.claude/state`.

Everything else the repository ships — `base/`, `bin/`, `docs/`, `templates/`, the `scripts/check-*`
suites, the build — stays out. It is the framework's own development surface, not a runtime.

### Living with it

```bash
baseline pinned status                     # or: bash .claude/adb/lib/pinned-install.sh status
baseline pinned upgrade --to 2.3.0
baseline pinned uninstall                  # or: ./uninstall.sh --pinned --project .
```

`status` reports the mode, the pinned version, whether the payload still matches its receipt, and —
this one call reaches the network — whether a newer release exists. Its exit code is the machine
contract: `0` pinned and current · `10` a newer release exists · `11` not pinned · `20` the payload
is missing or unverifiable · `30` the release list could not be read.

**Nothing upgrades on its own, and `--to` *is* the approval.** There is no prompt, because two
things already invoke `baseline update` unattended (the `SessionStart` hook and the last step of
`/cleanup`) and a command that could upgrade without a named version would upgrade in both. In a
pinned project `baseline update` prints a notice — the pinned version, whether the payload still matches its
receipt, and whether a newer release exists — and then keeps doing its ordinary job on the
install-source clone. Reporting the newer release costs one read of the release list, on the
*mutating* path only; `baseline update --check` is untouched and still makes no changes and no call
it did not already need.

**Re-running the install changes nothing.** The same version republishes identical bytes — the
adoption date is carried forward rather than restamped — and a *different* version is refused with
the `upgrade --to` command spelled out, because changing the pinned version is a decision, not a
side effect. The pin also records the **archive's SHA-256**, so "the same version" means the same
bytes: a second archive with the same filename and different contents is refused too, rather than
quietly replacing the payload. An upgrade removes what the previous version shipped and the new one
does not, so nothing is left behind unowned.

**Uninstall removes by digest.** A vendored file whose contents still match the receipt is removed;
one you edited is **kept and named**, because an uninstaller that deletes work it did not write is
worse than one that leaves a file behind. Your own `AGENTS.md` prose and your own `settings.json`
keys survive — a `settings.json` is removed only when this install **created** it and nothing but
this install's wiring is left in it, so one that existed beforehand always stays.

### What it does not do

Said plainly, because a model that overstates itself is worse than a narrow one:

- **Gemini is not supported.** It has no established project-local skill discovery
  (`scripts/build.sh`), so a vendored payload could not be loaded — the installer refuses
  `--agent gemini` and says so rather than installing something inert. Global mode still covers all
  three agents.
- **`skill-compose` overrides do not work in pinned mode.** The composer writes
  `.claude/skills/<name>/SKILL.md` by merging your `overrides.md` onto the *installed base* skill —
  and in this model that output path *is* the base. Carrying a delta on top of a pinned skill needs
  a separate home; `/adopt` still reports an `overrides.md` it finds, so the situation is visible
  rather than silent.
- **It vendors a runtime, not a development environment.** There is no `build.sh`, no `selfcheck`,
  and no `bin/` — a pinned project consumes the baseline, it does not develop it.
- **The pin is not a lock file.** It records what was installed; the receipt is what proves the
  tree still matches it.
- **Codex truncates long project instructions, and this install cannot stop it.** Its
  `project_doc_max_bytes` defaults to 32 KiB and larger files are truncated *silently*, while the
  rendered practices are far bigger. The install measures the resulting `AGENTS.md` and prints the
  one line that fixes it — put `project_doc_max_bytes = 262144` in `~/.codex/config.toml` — but the
  setting is yours, not the payload's.
- **A project already carrying an `/adopt` pin is refused, not converted.** That file records a
  commit this installer cannot reconstruct; retire it deliberately first.
- **A symlinked `AGENTS.md` or `.claude/settings.json` is refused.** Publishing by rename would
  replace the link with a regular file, and uninstall could never put it back — so a repository that
  deliberately shares one instruction file across checkouts is told, rather than silently
  restructured.
- **A directory sitting where a payload file goes is refused.** `mv` would move the file *inside*
  it and report success.

## Uninstalling

This section is the **global symlink** install's mirror. The pinned model has its own remover —
`./uninstall.sh --pinned --project DIR`, or `baseline pinned uninstall` — described under
[Release-pinned, per project](#release-pinned-per-project); the two share no destination, so a run
is one or the other.

```bash
cd ~/Code/ai-dev-baseline
./uninstall.sh                     # all agents present (claude, codex, gemini)
./uninstall.sh --agent claude
```

`uninstall.sh` only removes a destination if it is **currently a symlink
pointing somewhere inside this repo** (`adb_unlink_if_ours`) — a real file, or a
symlink pointing elsewhere, is left alone and reported as `skip ... (not
ours)`. It also strips the baseline's own hook entries — the three `Stop` gates
and both `SessionStart` hooks (currency and run-state) — out of `~/.claude/settings.json` (again
via `jq`, matched by filename) and removes a hook-event key entirely once that
leaves it empty. Hooks you added yourself under the same events are left alone.
Removing the SessionStart entry matters as much as unlinking the script: a
leftover entry pointing at a deleted command would error on every future
session. Your backups under
`~/.claude/backups/ai-dev-baseline-*` are **never** touched by uninstall —
restore from them by hand if you want the pre-install files back.

## See also

- [philosophy.md](philosophy.md) — why the baseline is installed globally
  rather than per-project. That reasoning still holds for the global model; the
  release-pinned model above answers the different question of how a *project*
  states which baseline it runs.
- [roles-and-agents.md](roles-and-agents.md) — the manifest written to
  `~/.config/ai-dev-baseline/agents.toml` and how it's consumed.
- [per-project-overrides.md](per-project-overrides.md) — layering
  project-specific rules once the global baseline is installed.
