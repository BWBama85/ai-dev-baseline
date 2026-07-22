# Adding a new agent

The framework currently ships `claude`, `codex`, and `gemini` as agent
tokens (see [roles-and-agents.md](roles-and-agents.md)). Adding another AI
coding agent — this doc uses a hypothetical token `foo` as the running
example — touches a small, well-defined set of places. Deep per-agent
workflow parity (matching Claude's skills feature-for-feature, say) is the
harder, optional part; the steps below are what's required for `foo` to be
installable and assignable to a role at all.

## 1. Add `agents/foo/adapter.sh`

`install.sh` and `uninstall.sh` already know how to drive an adapter for any
token that isn't `claude` — the `codex` and `gemini` branches in both scripts
call `bash "$REPO/agents/$agent/adapter.sh" install|uninstall …` if that file
exists, and print `"adapter not present yet (deferred) — skipping"` if it
doesn't. `codex` and `gemini` each ship a working `adapter.sh` you can copy as a
template; `foo` just needs its own, following the same contract (and the same
symlink + backup pattern Claude's `install_claude()`/`uninstall_claude()`
functions implement inline).

The adapter must implement two subcommands, matching how it's invoked:

```bash
# install.sh calls:
bash "$REPO/agents/foo/adapter.sh" install "$REPO" "$BACKUP_DIR"

# uninstall.sh calls:
bash "$REPO/agents/foo/adapter.sh" uninstall "$REPO"
```

`install <repo> <backup_dir>` must, at minimum:

- **Symlink the generated root doc** (`agents/foo/FOO.md` or whatever `foo`'s
  native root-doc filename is) into `foo`'s home config location (e.g.
  `~/.foo/FOO.md`).
- **Back up any existing file** at that destination before replacing it —
  mirror Claude's `link()` helper in `install.sh`: if the destination is
  already the correct symlink, no-op; if it's a symlink to something else,
  replace it; if it's a real file, move it under `$BACKUP_DIR` (preserving
  the absolute path structure) before linking.
- **Be idempotent.** Running `install.sh --agent foo` twice in a row must
  produce the same end state with no duplicate backups and no broken links.
- If `foo` supports skills or gate scripts analogous to Claude's, symlink
  those too, following the same backup-then-link pattern.

`uninstall <repo>` must only remove a destination if it is **currently a
symlink pointing back into `$repo`** — never delete a real file or a symlink
to somewhere else (mirror `unlink_if_ours()` in `uninstall.sh`). It does not
receive a backup directory; it never needs to write one.

The cleanest way to write this is to lift the `link()` /
`unlink_if_ours()` logic directly out of `install.sh` / `uninstall.sh` rather
than reinventing it — they're small, dependency-free bash functions.

## 2. Add `foo` to `scripts/build.sh`

Add one `render(...)` call so `foo`'s root doc is generated from
`base/practices/*.md` like the other three:

```bash
render "$root/agents/foo/FOO.md" "Global engineering practices"
```

Run `bash scripts/build.sh` and commit the generated file — CI re-runs this
script and fails the build if the checked-in output has drifted from what
`base/practices/*.md` would currently render, so this step isn't optional
even though the file is generated.

`scripts/build.sh` also renders `base/workflows/*.md` — the single source for
each workflow's procedure + metadata — into the **Claude** skills
(`agents/claude/skills/<name>/SKILL.md`). When `foo` gains a native
command/skill surface, its workflow renderer plugs in here the same way and reads
those same `base/workflows/*.md` sources — so the workflows are authored once, not
re-authored per agent. That work is the "deep workflow parity" part below, tracked
as its own issues; a `render()` for `foo`'s root doc is all that's required for
`foo` to be installable and role-assignable.

## 3. Register `foo` in `base/roles.md`

Two additions to `base/roles.md`:

- **Agent tokens** list: add `foo` alongside `claude` · `codex` · `gemini`.
- **Cross-agent invocation table**: add a row with `foo`'s non-interactive
  entrypoint and the root config it reads, e.g.:

  | Agent | Non-interactive invocation | Root config it reads |
  |---|---|---|
  | `foo` | `foo exec --cd <repo> -` (adjust to `foo`'s actual CLI) | `~/.foo/FOO.md` |

  If `foo`, like `codex`, is slow enough on a full-repo pass to need a longer
  Bash timeout than the 2-minute default, document that the same way the
  codex-timeout note in `base/roles.md` does — name the concrete minimum
  timeout, don't just say "give it more time."

Once `foo` is in both places, it's automatically usable in any project's
`agents.toml [roles]` table for `primary`, `gap_analysis`, `review`, `debug`,
`issue_author`, or `release` — the role-resolution logic in
`base/roles.md`/the skills doesn't hardcode the three existing tokens; it
just looks up whatever string is configured.

## 4. Install it

```bash
cd ~/Code/ai-dev-baseline
./install.sh --agent foo
```

This runs `write_global_manifest` (writes
`~/.config/ai-dev-baseline/agents.toml` if it doesn't already exist — no
change needed there, the manifest format doesn't enumerate agent tokens) and
`run_adapter foo`, which now finds `agents/foo/adapter.sh` and actually
installs it instead of printing the "deferred" message.

## 5. Confirm the role table works end to end

- Set `primary = "foo"` (or any other role) in a test repo's `agents.toml`.
- Run a workflow that reads that role (e.g. `/implement-issue`) and confirm
  it resolves `foo`'s cross-agent invocation correctly when `foo` isn't the
  agent currently driving.
- Run `agent-init` in a fresh repo and confirm `foo` appears as a valid value
  wherever the printed effective-role-map script expects a quoted token.

## What's deliberately out of scope here

This doc covers making `foo` **installable and assignable** — the floor every
existing agent already meets. Deep workflow parity (native skills equivalent
to Claude's `/implement-issue`, `/debug`, `/cleanup`, `/create-issue`,
`/new-release`, `/resolve-pr-threads`; a Stop-hook-equivalent gating
mechanism if `foo`'s harness supports one) is real work and is the harder,
optional part — a project can assign `foo` to `review` or `debug` today via
its cross-agent invocation alone, without `foo` having any native skills at
all, exactly the way `codex` and `gemini` already work as `review`/
`gap_analysis` agents without a `codex`/`gemini`-native skill system.

## See also

- [roles-and-agents.md](roles-and-agents.md) — the role table and resolution
  order `foo` becomes eligible for once registered.
- [installation.md](installation.md) — what the existing `install_claude()`
  path does, as the concrete reference implementation to mirror.
- [philosophy.md](philosophy.md) — why agent-neutrality is structural
  (rendered from one source) rather than three hand-maintained copies.
