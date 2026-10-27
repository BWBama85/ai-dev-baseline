# Installation

## Two install models

There are two, and they answer different questions. Everything from *"1. Clone the repo"* to
*"Keeping the install current"* describes the **global symlink install**; the second model has its
own section, [Release-pinned, per project](#release-pinned-per-project).

| | **Global symlink** | **Release-pinned, per project** |
|---|---|---|
| What it is | a permanent clone symlinked into `~/.<agent>` | one released version vendored into one project tree |
| Scope | every project on the machine | exactly the project it is installed in |
| Version | the newest stable release the clone has checked out (the default `release` channel, #534) — `/adopt` records it in `.ai-dev-baseline/upstream.toml` as `git describe --tags` of the clone's commit, a bare `vX.Y.Z` on that channel, beside that full commit | the release named in `.ai-dev-baseline/upstream.toml` (`mode = "pinned"`) |
| Updating | each published release reaches every project at once, at the next currency check (`baseline update`) | `baseline pinned upgrade --to X.Y.Z`, never on its own |
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

**Pick the global model** when the machine is yours and you want every project on it to move to
each new release together. **Pick the pinned model** when a project must state which baseline it runs — a repo
other people clone, a build that has to be reproducible, or any machine where keeping a permanent
clone is not an option.

## 1. Clone the repo

Clone it somewhere stable — you're going to symlink into it, so don't clone
it into a temp directory or delete it later. Check out the **newest stable release**: on the
default `release` channel that is what every project should run, and `baseline update` then moves
the clone forward from one release to the next on its own.

```bash
git clone git@github.com:BWBama85/ai-dev-baseline.git ~/Code/ai-dev-baseline
cd ~/Code/ai-dev-baseline
git checkout --detach "$(gh release view -R BWBama85/ai-dev-baseline --json tagName --jq .tagName)"
```

Without `gh`, take the tag from the repository's Releases page. On the release channel,
`install.sh` warns (and never refuses) when the clone is not at a release tag, and prints these
commands. To run unreleased `main` on purpose, stay on `main` and set the channel (see
[*Keeping the install current*](#keeping-the-install-current)).

## 2. Run the installer

```bash
cd ~/Code/ai-dev-baseline
./install.sh                       # installs the 'claude' agent + wires gates
./install.sh --agent claude --agent codex
./install.sh --agent claude --no-hooks
./install.sh --agent claude --skip-hook precommit-gate.sh
./install.sh --agent claude --no-sandbox
```

Options:

| Flag | Effect |
|---|---|
| `--agent <claude\|codex\|gemini>` | Repeatable. Which agent(s) to install. Default: `claude`. |
| `--no-hooks` | Skip wiring the global Stop-hook gates into `~/.claude/settings.json`. |
| `--skip-hook <name>` | Repeatable. Wire every shipped hook **except** `<name>` (its exact script name, e.g. `precommit-gate.sh`), removing its entry if it was wired. Recorded, so `baseline update` keeps honouring it — which needs `jq`: without it the install fails rather than leave the skip unrecorded. An unknown name exits 2 before anything changes; `--no-hooks` wins over it. |
| `--no-sandbox` | Skip the [least-privilege sandbox settings](#least-privilege-sandbox-settings). Recorded, so `baseline update` keeps honouring it. |
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
| `agents/claude/rules/` (path-scoped procedures) | `~/.claude/rules/ai-dev-baseline` |
| `agents/claude/reference/` (every other procedure) | `~/.claude/ai-dev-baseline/reference` |
| `agents/claude/skills/<name>/` (each skill dir) | `~/.claude/skills/<name>` |
| `agents/claude/scripts/precommit-gate.sh` | `~/.claude/scripts/precommit-gate.sh` |
| `agents/claude/scripts/implement-issue-gate.sh` | `~/.claude/scripts/implement-issue-gate.sh` |
| `agents/claude/scripts/state-claim-gate.sh` | `~/.claude/scripts/state-claim-gate.sh` |
| `agents/claude/scripts/session-currency.sh` | `~/.claude/scripts/session-currency.sh` |
| `agents/claude/scripts/session-context.sh` | `~/.claude/scripts/session-context.sh` |
| `scripts/lib/` (the shared shell library) | `~/.claude/scripts/lib` |

### The root doc holds rules; the procedures load on demand (#434)

Each practice renders in two classes from its one source. The **rule** — what every
session must hold — is in the root doc. The **procedure** — the how, needed only when the
practice applies — is one file per practice, and the root doc ends that practice with a
`**Procedure:**` line naming where it is installed. Where each agent reads it:

| Agent | Procedure surface | Loads |
|---|---|---|
| Claude, practice declares `<!-- adb:paths … -->` | `~/.claude/rules/ai-dev-baseline/<practice>.md`, `paths:` frontmatter | when Claude reads a matching file; otherwise when the pointer is followed |
| Claude, every other practice | `~/.claude/ai-dev-baseline/reference/<practice>.md` | when the pointer is followed |
| Codex | `~/.codex/ai-dev-baseline/reference/<practice>.md` | when the pointer is followed |
| Gemini | `~/.gemini/ai-dev-baseline/reference/<practice>.md` | when the pointer is followed |

Only a path-scoped procedure becomes a Claude rule: Claude loads a rule *without* `paths:`
at launch, which would put the procedure back into every session. Codex and Gemini have no
global on-demand instruction surface — Codex's nested `AGENTS.md` files are scoped to a
project's directories and Gemini's `@file` imports load eagerly — so each gets the reference
bundle its pointers name. Each tree is one directory link, removed by `uninstall.sh` like
every other manifest row; `/context` (Claude) and `/memory show` (Gemini) show what loaded.

**Upgrading from a single-file install:** a bare `git pull` updates the root doc, but the procedure
links are new manifest rows, which only `install.sh` or `baseline update` creates — run either once
(Claude's session-start currency check does it for you in its `auto` mode, not in `notify` or
`off`). Until then the rules still load and each
pointer names a file that is not there yet; the root doc's header says which command links it.

**Want the old single-file shape?** Concatenate them yourself — the procedures are plain
Markdown: `cat ~/.claude/CLAUDE.md ~/.claude/ai-dev-baseline/reference/*.md ~/.claude/rules/ai-dev-baseline/*.md`.
Nothing ships a flag for it.

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

Because these are real symlinks (not copies), whatever `~/Code/ai-dev-baseline` has checked
out is what **every** project on the machine runs — so moving it to a new release (which
`baseline update` does) updates the practices, skills, and gates everywhere at once, with no
per-repo sync step.

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

Removing a hook's entry from `~/.claude/settings.json` — or installing with `--skip-hook <name>` —
is the per-hook opt-out, and `baseline update` preserves it: a hook whose script link is installed
but whose entry is gone is left alone (the set is reported as PARTIAL), while every other hook,
a newly shipped one included, is still wired. The repair runs `install.sh --optout-if-recorded`,
which reads the removed hooks under the settings lock and skips exactly those. A hook shipped **after** your last install has neither an entry
nor a script link, and that is not a choice anybody made — the next `baseline update` links and
wires it (`adb_claude_hooks_missing_deliberate` is what tells the two apart, reading the **wiring
receipt** `~/.claude/.adb-hooks-wired` that a successful `install.sh` writes and `uninstall.sh`
removes: an entry the receipt says was wired — or skipped by name — and is now absent was your
choice; a link the receipt never saw was an install interrupted between the link and the entry,
and is repaired. An install that predates the receipt has none until its next successful wiring, and
until then the link alone is read as the choice — which holds because
an install whose hook wiring **fails** takes back the links it added — restoring whatever each one
displaced — so an interrupted install never leaves the opt-out's shape behind). Removing **every**
entry is different: that set is indistinguishable from an `install.sh --no-hooks` install, so
`baseline update` keeps it unwired — a newly shipped hook included — and never widens it. A plain
`./install.sh` wires the full set, re-adding any hook you removed.

### Least-privilege sandbox settings

`install.sh` also writes a second, **non-hook** fragment into `~/.claude/settings.json` —
Claude Code's sandbox keys — unless `--no-sandbox` is passed. Source:
`agents/claude/settings.fragment.json`.

| Key | Value | What it buys |
|---|---|---|
| `sandbox.enabled` | `true` | Bash commands run under OS-enforced filesystem and network isolation. |
| `sandbox.credentials.files` | `deny` on `~/.aws`, `~/.ssh` | The vendor's default read policy **still allows** reading those; this closes it. |
| `sandbox.credentials.envVars` | `deny` on `GITHUB_TOKEN` | Sandboxed commands inherit the parent environment, credentials included; this unsets it for them. |
| `sandbox.network.allowedDomains` | `api.anthropic.com` and the GitHub hosts | Pre-allows the hosts this repo's GitHub traffic reaches from *inside* the sandbox, so they do not prompt. |
| `sandbox.excludedCommands` | `["git *", "gh *"]` | Runs `git` and `gh` **outside** the sandbox. This is the one key that widens rather than narrows; [why `git` and `gh` run outside the sandbox](#why-git-and-gh-run-outside-the-sandbox) says why and what it costs. |

The allowlist is a starting point, not a claim of completeness: it covers **`api.anthropic.com` and
GitHub**, so a project whose remote is elsewhere, or whose build fetches a package registry, will
still be prompted for those hosts — add them in your own settings, since array keys merge across
every scope. And note that `github.com` is a **broad** entry: the vendor's own security notes point
out that a wide domain can be used for exfiltration when TLS is not inspected (the built-in proxy
does not inspect it by default). It is here because GitHub traffic that stays sandboxed needs it,
not because it is tightly scoped. Excluded `git`/`gh` calls never reach the proxy. The framework's
own library scripts do, because they run `gh` *inside* a `bash` call that no exclusion matches
(#531).

Two keys are deliberately **not** shipped. `sandbox.filesystem.disabled` turns filesystem
isolation *off* (that is what it does — it reads like hardening and is the opposite);
`sandbox.network.strictAllowlist` converts the allowlist from *pre-allow* to *deny*, which is a
larger imposition than the allowlist itself. Both are yours to add.

**It is written to USER scope only** (`~/.claude/settings.json`) — a choice, not a vendor
limitation. The keys shipped here *would* be honoured in a repository's `.claude/settings.json`
(`deny` entries merge from every scope the session loads); the ones that are genuinely user- or
managed-only are `filesystem.disabled`, `strictAllowlist` and the `mask` family, none of which
this fragment ships. It stays user-scoped because the global installer's whole model is user-level
config, and because `install.sh --pinned` writes a **tracked** project settings file — writing a
security policy there would commit one on behalf of every contributor to that repository. The
pinned model therefore does not write these keys at all, and says so.

One thing this does **not** buy you: if the sandbox cannot start — missing packages on Linux or
WSL2, or an unsupported platform — Claude Code warns and runs commands *unsandboxed*, and none of
these rules apply. `sandbox.failIfUnavailable` turns that into a hard error and is deliberately not
shipped, since refusing to start is not a default this installer should choose for you.

**Below the version floor, nothing is written.** The keys need Claude Code **v2.1.187** or later
(`sandbox.credentials`). The installer probes the CLI; below the floor, or when no `claude` binary
can be probed, it writes **no key** and prints the version found, the floor required, and the
protection that was therefore not applied. That absence is recorded as a *skip*, not a choice, so
the next `baseline update` applies the settings by itself once you upgrade the CLI.

#### It applies whole, or not at all

The fragment is installed **only when every key it ships is absent**, with one exception: an
`excludedCommands` of yours that already holds every shipped entry (below). If any other key is
already in your `settings.json`, whatever its value, no policy value is written and the installer
names what is in the way. There is no partial application: a half-applied policy reports protection it
does not have, and `sandbox.enabled` without the credential rules (or the reverse) is exactly that. So
when an update refuses because it started shipping a key you already have, and you have edited none of
the keys an earlier install wrote, those keys are withdrawn. If you have edited one, they are all
yours and stay (the table below).

Your own keys are never in the way unless they *are* one of ours: `sandbox.filesystem.allowWrite`
sits beside our `sandbox.enabled` and is never read, rewritten or removed.

**`sandbox.excludedCommands` is the exception, because you may well have one already.** If yours
is an array that holds every entry we ship (`"git *"` and `"gh *"`), in any order and beside entries
of your own, it is **already satisfied**. The installer leaves it exactly as it is, writes the rest
of the policy, and records that key as *yours*, so uninstall never removes it. The same holds if you
later **extend** the array we wrote: it becomes yours, and the other keys stay ours and current. An
`excludedCommands` that lacks either entry still refuses the lot. The old `["git", "gh"]` recipe
lacks both, since a pattern with no wildcard matches only the bare command.

A receipt at `~/.claude/.adb-settings-owned` records the keys written, the containers created for
them, and the digest of the fragment applied:

| You do this | What happens next |
|---|---|
| Already have any key we ship | **No policy value is written**, and the refusal names it. Remove or rename it and re-run `./install.sh` to take the policy. If an earlier install had already applied the policy (an update started shipping a key you have) and you have not edited any key it wrote, those keys are **withdrawn** rather than left behind with nothing able to remove them. If you have edited one, see the edit row below: the keys are yours and stay. The one exception is an `excludedCommands` that already holds every shipped entry, which counts as satisfied (above). For that key the refusal also names the entries to add. |
| Had your own `excludedCommands` before this release shipped one | If it holds `"git *"` and `"gh *"`, the next update just records it as yours. If it does not, that update **refuses the whole policy**, leaves your `excludedCommands` as it is, and withdraws the keys it installed earlier (unless you have edited one of them, in which case they are all yours and stay). **Add the two entries before you update** to keep the policy. |
| Edit or delete a key we wrote | The surface is yours from then on: the next install refuses rather than rewriting, and names what changed. Deleting is the opt-out, and it is not remembered as ours — so if you later re-add that value by hand, uninstall will not take it. Adding entries of your own to `excludedCommands` is not an edit of this kind: that key becomes yours and nothing else changes. |
| `install.sh --no-sandbox` | Nothing written, the choice recorded; `baseline update` keeps honouring it. |
| A future version stops shipping a key | The next install **prunes** it, so no orphan is left in your file. |
| The shipped values change (a new allowed domain) | `baseline update` notices — the receipt records the **digest** of the fragment it applied, so a changed *value* is caught, not just a changed key. |
| Your CLI is downgraded or drops off `PATH` | Nothing new is written, and the receipt **keeps** what it already owns, so uninstall can still remove it. |
| You already had `{"sandbox": {}}` | It survives uninstall. We delete only the containers we made, which is why they are recorded rather than inferred. |

#### Why `git` and `gh` run outside the sandbox

Inside the sandbox, the framework's own path to GitHub breaks in two independent ways:

- **On macOS, `gh` can fail TLS verification, so its request never reaches GitHub.** It is a Go
  program, and under Seatbelt it may not reach the system trust service. It failed on every macOS
  machine probed for #462, and the vendor says such tools *may* fail:
  `tls: failed to verify certificate: x509: OSStatus -26276`. Inside the sandbox
  `gh auth status` then reports **`The token in keyring is invalid`**. GitHub never saw the token,
  let alone rejected it, so do not re-authenticate, and do not move it to plaintext storage. `git` over HTTPS with the
  keychain credential helper can fail the same way, with `fatal: failed to store: 100001`.
- **`git` over SSH cannot get out, and the credentials are denied besides.** The connection is
  refused at the sandbox's own proxy (`This proxy requires authentication, and this client did not
  offer an authentication method`). The `~/.ssh` deny would hide the key files even past that, and
  the `GITHUB_TOKEN` scrub stops `gh` wherever that variable is its token.

So the fragment ships `sandbox.excludedCommands: ["git *", "gh *"]`. This is the vendor's
documented remedy, and the owner chose it on #462 (D129). **The cost is real:** an excluded call
runs with your full access. It has no filesystem limits and no network proxy, and the credential
denials above do not apply to it. These are the two commands most likely to touch credentials, and
that trade was taken knowingly.

What the patterns match is the vendor's rule, not ours (checked 2026-10-13):

- **The whole call is matched, as text.** Every command in it must match, so
  `git add -A && git commit -m x` runs outside the sandbox and `npm test && git push` does not.
- **Some calls stay sandboxed even when they match.** That covers a `cd`, a `$(...)`, a subshell,
  an `if`/`for`, a redirect to a file (`2>&1` is fine), a command name taken from a variable,
  `git -C`, and a `git clone` into an absolute, `~` or `..` path.
- **A script that runs `gh` internally does not match.** Most of the framework's own GitHub calls
  are made exactly that way, through its library scripts, so on macOS those still fail. That half
  is #531.
- **Excluded is not auto-approved.** A sandboxed command can run without asking; an excluded one
  goes through the regular permission flow. In Manual mode a `git`/`gh` command that is not
  read-only prompts unless one of your allow rules covers it, auto mode sends it to the classifier,
  and `bypassPermissions` runs it unless one of your ask rules matches it. A matching deny rule
  blocks it in every mode, allow rules included. The installer ships no allow rules.
- **Matching changed in newer CLIs.** Before v2.1.277 a compound command was taken out whole when
  only one part matched, and before v2.1.290 a short-form `git clone` option kept the exemption, so
  between the v2.1.187 floor and those versions the exclusion is broader than described here.
  (v2.1.281 went the other way: before it, some calls such as `git rev-parse --git-dir` did not
  match at all.) The floor is not raised for it, because a
  higher floor would narrow nothing on those CLIs. Below the floor the installer writes no *new*
  policy: a fresh install gets no sandbox at all, and an established one keeps the keys it has.

`--no-sandbox` is **not** a way out of an installed sandbox. It records the opt-out so
`baseline update` stops re-applying the policy, and it leaves the keys already in your settings in
place. To take them out, either delete them by hand, which the next install reads as your opt-out
and does not rewrite, or run `./uninstall.sh`. Uninstall removes only the keys this install still
owns, so it leaves any it has already given up. It also deletes the ownership record, so a later
`./install.sh` applies the policy again — unless a key uninstall left behind (one you edited, or one
already given up) is still in your file, which blocks the whole policy as any key of yours does. An
`excludedCommands` that still holds every shipped entry is the exception here too.

#### Cross-model roles and the sandbox

The fragment leaves `codex` and `agy` **inside** the sandbox (#505, D132), and on macOS neither
can start there. Linux and WSL2 are untested. Observed 2026-10-15 under the shipped fragment alone,
on macOS 26.6.2 with Claude Code 2.1.300, codex-cli 0.162.1 and agy 1.2.7 and 1.3.6; D132 records
the full witness:

- **`codex exec` exits 1** with `Error: failed to initialize in-process app-server client:
  Operation not permitted (os error 1)`. The sandbox denies its writes to `~/.codex`.
- **`agy -p` exits 1** with `Failed to start: listen tcp 127.0.0.1:0: bind: operation not
  permitted`. The fragment leaves `sandbox.network.allowLocalBinding` off, so agy cannot open its
  local port. Its log under `~/.gemini` is not writable either, but agy survives that.

`claude -p` starts and works, through `role-dispatch.sh` too. But `codex` is the shipped default
for both `gap_analysis` and `review`, so a sandboxed `/implement-issue` cannot run its gap pass or
its review slot. The
dispatch reports the cause instead of blaming the agent. Its classified line reads
`role-dispatch: gap_analysis (codex) — INCOMPLETE: codex exited 1 before it could start — the OS
refused it ("Operation not permitted") …`. A retry inside the same sandbox fails the same way, and
so does a review slot's cross-model stand-in.

**Cross-model roles need an unsandboxed session, or exclusions you add to your own settings.**
The fragment does neither for you, and the owner decided on #505 not to change it:

- **A `"codex *"` exclusion would never match.** Exclusions match the text of the Bash call (see
  [above](#why-git-and-gh-run-outside-the-sandbox)), and the framework never calls `codex` or
  `agy` as that text. It reaches them through `implement-lib.sh dispatch-*` and `review-loop pass`,
  which call `role-dispatch.sh`. An exclusion that works has to match that whole wrapper call.
  Which wrapper patterns to recommend is the question #531 owns for `gh`, so it is decided there,
  once, for both.
- **A writable `~/.codex` is a privilege escalation.** `filesystem.allowWrite` on `~/.codex` and
  `~/.gemini`, plus `network.allowLocalBinding`, would keep both CLIs sandboxed. But any sandboxed
  command could then rewrite `~/.codex/config.toml` and loosen codex's own sandbox and approval
  policy for the next dispatch.

An exclusion you add costs what the `git`/`gh` one does: the excluded call runs with your full
access, and the agents codex and agy host are then held only by those CLIs' own sandboxing.

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
timestamped backup directory first. `settings.json` is copied **once per run**, before either
writer touches it, so the backup is your original file rather than a half-merged intermediate:

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
     `install.sh` preflights the clone's tracked shell files for this and fails
     with the remedy, and
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
clone they point into. `bin/baseline` keeps that clone current:

```bash
baseline update            # move the install-source clone to the newest stable release + self-heal links
baseline update --check    # report currency only; make NO changes (for a lifecycle hook)
```

### The release channel (the default)

**Every project on the machine runs the newest stable release** (owner decision, #534, D143). A
stable release is a **published** GitHub Release of the repository the clone's `origin` names —
not a draft, not a prerelease, and carrying GitHub's *latest* marker (which `/release` sets). A
tag with no published Release is never followed, and neither is a backfill of an old version. A
fork's install follows the fork's releases.

- **Forward only.** `baseline update` moves the clone to the release's commit as a **detached
  checkout** (`git checkout --detach`), only when `HEAD` is an ancestor of it, and then re-runs the
  installer. It never moves backward. An install **ahead** of the newest release — for example one
  that followed `main` before this channel existed — is **held** where it is (`update` exits `21`,
  `--check` says `ahead-of-release`) until a release that contains it is published, and then moves
  onto that tag.
- **Integrity before any move.** The release's tag in the clone must equal origin's: a release tag
  that origin has deleted and re-created elsewhere is refused (`tag-moved`), never followed. The
  release's commit must also be on `origin/<default>` (`release-off-branch` otherwise). Both exit
  `40`, and both automatic triggers report them in every mode.
- **Nothing falls back to `main`.** When `gh` is missing or unauthenticated, the API fails or takes
  longer than `ADB_RELEASE_TIMEOUT_SECS` (default 30), or a tag name is not `vX.Y.Z`, the answer is
  `release-unresolvable` (`30`) and nothing changes; a repository with no stable release at all is
  `no-release` (`30`).
- **Release cadence is delivery cadence.** A fix merged to `main` reaches release-channel installs
  only when the next release is published. That is the point: the contract is no longer that
  `main` must always be fit to run, but that *a published release reaches every release-channel
  install at its next currency check*.
- **The `HEAD` reflog is the audit trail** (every move is a checkout entry), and `--check` prints one
  stderr line: `baseline: installed v3.1.0 (channel release), newest v3.1.1`.

**Following `main` instead** is a deliberate, machine-wide choice, made in the **global** manifest
only (a repo you open must not choose your machine's update channel):

```toml
# ~/.config/ai-dev-baseline/agents.toml
[updates]
channel = "main"      # release (default) | main
```

`ADB_UPDATE_CHANNEL=main` does the same for one run. A misspelled or unreadable value means
`release`, with a diagnostic, never `main`. On `main` the behaviour below is exactly the pre-#534
one — fast-forward the default branch — plus one addition: a clone left **detached** by the release
channel is re-attached to the default branch when that only moves forward (the local branch is
advanced to `origin/<default>` first, then checked out). Switching back from `main` to `release`
while ahead of the newest release holds the clone until the next release.

**Going back to an older release by hand** is possible and deliberately not automated: an older
installer run over hook entries and a sandbox receipt it may not know can orphan them. If you
must, first set `[updates] session_start = "notify"` (or `"off"`) so the automatic path does not
move the clone forward again, then **uninstall, check out, install** — `./uninstall.sh` with your
`--agent` flags, `git checkout --detach vX.Y.Z` in the clone, and `./install.sh` with the same
flags as before — so the older installer starts from a clean slate. The supported answer to a bad
release is the next (patch) release.

`baseline update` is deliberately conservative on both channels — currency is a convenience, never
a cause of lost work:

- It moves the clone **only** when it is **clean and free of an in-progress git operation**, and
  either on its default branch or (release channel, or a release install on `main`) detached. A
  dirty / mid-rebase / non-default clone, or one with unpushed or diverged commits, is **surfaced and
  left untouched** — you reconcile it by hand. The dirty, mid-rebase and non-default refusals are
  decided from **local state before any network**, so such a run costs no round trip; unpushed or
  diverged work is seen after the fetch. On the release channel the release lookup and the fetch
  for the clone happen only **after** the update lock is taken.
- After a move it **always** re-runs the **idempotent** installer (a pulled commit
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
- **What "installed" means for an agent** (#539): any of its install links (root doc, skills,
  hook scripts, `scripts/lib`) still points into the clone. The clone itself is found from a
  root-doc link first and, when none names one, from an agent's `~/.<agent>/scripts/lib` link.
  An install that has lost both of those is not found; run `./install.sh` again. What sits at
  the agent's **root-doc** path then decides what an update does:
  - **our link** — nothing special;
  - **nothing at all** — that is damage, not a choice: the update re-links it with the other
    missing links and prints `baseline: re-linked ~/.claude/CLAUDE.md — …` (exit `6` when the
    clone was current). Its dead links are pruned on the update after that, not before the
    repair, because they may be all that shows it is installed;
  - **something else** (your own file, a directory, a link outside the clone) — never touched
    by an update. It prints a `NOTE` naming what kind of thing is there, without changing the
    exit code, and that agent's other links are left as they are. `./install.sh --agent <agent>`
    puts the baseline's root doc back — a file or directory there is moved under
    `~/.claude/backups/`, but a symlink there is replaced without keeping where it pointed — and
    `./uninstall.sh --agent <agent>` removes its other links. An update never prunes that
    agent's dead links.

  To opt out of the root doc, uninstall the agent or put your own file at its path. Deleting it
  is not an opt-out: the next update re-links it.

  One residue is stated rather than engineered away: an editor that creates the root doc in the
  instant between the update reading the path as empty and re-linking it would have that file
  moved under `~/.claude/backups/` — displaced, never deleted. When two root docs name two
  different clones, the first one wins exactly as before, and running the update from the other
  clone is refused as the wrong clone.

`baseline update --check` prints one status word and changes nothing in the working tree;
its exit code is the stable contract the SessionStart hook consumes:
`0` current · `10` behind · `20` needs attention (dirty/in-progress/ahead/diverged/
detached/non-default/ahead-of-release) · `30` currency unknown (fetch failed / no
`origin/<default>` / `no-release` / `release-unresolvable`) · `40` integrity refusal
(`tag-moved` / `release-off-branch`).

### Automatic currency — two triggers

Running `baseline update` is still something you have to *remember*, and forgetting it
does not fail loudly — it silently runs **stale tooling**. So the install wires it for you, at
**two** points. Both read the same configuration and share one policy library
(`scripts/lib/currency-lib.sh`); they differ only in when they fire and in what they consider
worth reporting.

| Trigger | Fires | Agents | Issue |
|---|---|---|---|
| `SessionStart` hook (`session-currency.sh`) | a genuinely new session (`source: startup`) | Claude | #36 |
| the last step of `/cleanup` | after every sweep | Claude · Codex · Gemini | #139 |

**Why two.** The hook fires only on `startup`, and the documented loop is
`/implement-issue → merge → /cleanup → /clear → /roadmap`, with `/clear` excluded by design, so the
loop itself never re-checked. On the release channel the install goes stale when a **release is
published**, which happens at the end of `/release` (after its changelog PR merges and the tag is
pushed), so a `/cleanup` run after that merge may still precede the publication — the next sweep or
session start then catches it. On `main` it goes stale at every merge, which `/cleanup` follows
directly. It runs immediately before the `/clear` that the hook skips, and because it is
agent-neutral it is also the only currency Codex and Gemini get.

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
single line naming what updated (`baseline: updated v3.1.0 → v3.1.1.` on the release channel,
`baseline: updated 0c3bbaf → 4eb472f (1 commit).` on `main`) or which state needs attention. An
install **held** ahead of the newest release is silent at session start and named once by
`/cleanup`, with both ways out. It always exits `0` — a SessionStart hook cannot block a session, and
currency must never be the reason one looks broken.

**Mode — configured globally, and only globally:**

```toml
# ~/.config/ai-dev-baseline/agents.toml
[updates]
session_start = "auto"    # auto (default) | notify | off
```

`auto` moves the clone and self-heals; `notify` reports **only** that you are behind (naming the
newer release on the release channel) or an integrity refusal, and stays silent for every other state (it is the mode chosen to be quiet — a clone deliberately parked on a branch
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
the `install.sh` of a newly published release (or, on `main`, of newly merged commits); that is the
same trust you already place in the clone your whole toolchain is symlinked from, but it is now
exercised automatically — use `notify` if you would rather review each release. The tag is checked
against origin's and against the default branch before any move, but not authenticated: release
tags are not signed. Second, the hook runs *after* the session has loaded its global
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
| **dev clone** (e.g. `~/Code/ai-dev-baseline-dev`) | Where you edit the framework and open PRs. It keeps tracking `main`. | `/implement-issue`'s preflight auto-sync (issue #17) |

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
| `.claude/rules/ai-dev-baseline.md` | the practices' rules — a rule with no `paths:` frontmatter loads at session start |
| `.claude/rules/ai-dev-baseline/<practice>.md` | the path-scoped procedures (#434), which load when a matching file is read |
| `.claude/adb/reference/<practice>.md` | every other procedure; the vendored root doc's pointers are re-anchored to these project paths |
| `.claude/skills/<name>/SKILL.md` | the workflows, shadowing any same-named global skill |
| `.claude/adb/lib/*.sh` | the shared shell libraries the skills and gates call |
| `.claude/adb/{precommit,implement-issue,state-claim}-gate.sh` | the Stop gates |
| `.claude/adb/session-context.sh` | the `SessionStart` run-state hook (#431): on `compact\|resume` it reads the project's own `.claude/state` back into context |
| `.claude/settings.json` | the Stop gates and the `SessionStart` hook wired through `${CLAUDE_PROJECT_DIR}` (merged, never replaced) — each under its own event, the hook with the `compact\|resume` matcher |
| `.codex/skills/<name>/SKILL.md`, `.codex/adb/…` | the same, for Codex |
| `AGENTS.md` | Codex's practice rules, inside a delimited managed region; its procedures are `.codex/adb/reference/` |
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
- **`session-currency.sh` is not vendored.** It moves the install-source clone (to the newest
  release, or along `main`), and a pinned project has none. `session-context.sh` **is**: it reads the project's own `.claude/state`.

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
is missing or unverifiable · `30` the release list could not be read. A merged surface Codex cannot
load counts as missing: a root `AGENTS.override.md` added after the install is reported as
`shadowed`, with `20`, because Codex then reads it instead of `AGENTS.md`. A link there that fails
to resolve for any reason but a missing target (a loop, for instance) is reported as `broken`,
because Codex then loads no project docs at all; a link to the root `AGENTS.md` itself, or to a
missing target, is not reported.

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
- **It does not write the least-privilege sandbox settings.** Not because the CLI would ignore
  them — the shipped key set *would* be honoured in project scope, since `deny` entries merge from
  every loaded scope — but because this model's `.claude/settings.json` is **tracked**: writing a
  sandbox policy there commits one on behalf of every contributor to that repository, and the
  ownership and uninstall semantics are the global install's, not a reviewed file's. The install
  says so rather than omitting them silently; run the global `./install.sh` to get them.
- **Codex reads project instructions only up to a byte budget.** Its `project_doc_max_bytes`
  defaults to 32 KiB, shared by the project's `AGENTS.md` and any nested ones, and what lies past it
  is never read. Since #434 the rendered rules fit it with room to spare — the procedures are
  vendored beside them rather than spliced in — so a stock project needs no change. A project whose
  own `AGENTS.md` prose — at the root, or in a nested `AGENTS.md` on the way down to some directory
  — pushes what Codex loads past the budget is told at install, with a line for
  `~/.codex/config.toml` sized to that chain; the setting is yours, not the payload's. The
  measurement counts `AGENTS.override.md`, `AGENTS.md` and every `project_doc_fallback_filenames`
  entry set in `~/.codex/config.toml` or the repository's `.codex/config.toml` (Codex reads the
  latter only for a trusted project, so both are counted), symlinked files included, and
  starts a chain at a nested repository's `.git` as Codex does; custom `project_root_markers` and
  the system, profile and command-line config layers are not read. It gives up with a note after
  30 seconds (`ADB_PINNED_CODEX_SCAN_SECS`) rather than hold the install.
- **A project already carrying an `/adopt` pin is refused, not converted.** That file records a
  commit this installer cannot reconstruct; retire it deliberately first.
- **A Codex install beside a root `AGENTS.override.md` is refused.** In each directory Codex reads
  the first of `AGENTS.override.md` and `AGENTS.md` that is a regular file, an empty file or a link
  to one included, so practices spliced into `AGENTS.md` there would never load. The install, a
  re-install and an upgrade all refuse with `10` before writing anything when the name exists in
  any form, a link of any kind included, and name the file. Move what the override says into
  `AGENTS.md` and remove it, or leave Codex out of the agent set. A Claude-only install is not
  affected, and uninstall never touches the override.
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
session.

It also removes the **sandbox settings** it wrote, and only those: a leaf is deleted while its
value still matches the receipt at `~/.claude/.adb-settings-owned`, one you have edited since is
**kept and named** in the output, and containers emptied by the removal are pruned while an empty
object of your own elsewhere in the file is not. **With no receipt, nothing is removed** — an
install that predates this surface, a below-floor skip and an already-cleaned home are
indistinguishable from `settings.json` alone, and guessing would delete `sandbox` keys the
installer never wrote.

Your backups under
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
