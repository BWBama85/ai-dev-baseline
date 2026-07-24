# Roles and agents

This expands `base/roles.md` into a user-facing guide. See
[philosophy.md](philosophy.md) for *why* separating role from agent is the
whole point of an agent-neutral baseline.

## The core idea

The framework separates **what a job is** (a role) from **which AI does it**
(an agent). A project declares the mapping once, in an `agents.toml` at its
repo root; a **role-aware** workflow resolves that mapping at run time and
delegates the step to whichever agent the manifest names — **with no change to
the workflow itself.** Swap `primary` from `claude` to `codex` in
`agents.toml` and the entire `implement-issue` playbook runs unchanged; only
who executes each step moves.

"Role-aware" is a property of the *consumer*, not something the manifest
imposes. A role only takes effect where some workflow explicitly resolves it
(via `role-dispatch.sh`, below). Today `/implement-issue` consumes
`gap_analysis` + `review`, and `/resolve-pr-threads` consumes the
`[reviewers]` bot allowlist. `debug`, `issue_author`, and `release` are
**declared but not yet consumed** by any shipped workflow — they resolve
correctly and are there for your own skills to honor. This matters most for
`release`, which the baseline never implements at all (see below): a
project-owned `/release` skill is responsible for resolving its own role, or
`release = "codex"` is silently ignored.

## Roles

| Role | Job | Cardinality | Default if unset |
|---|---|---|---|
| `primary` | Drives implementation end-to-end (`implement-issue`) | exactly 1 | required |
| `gap_analysis` | Adversarial pre-implementation read of the issue | 0 or 1 | skip the pass |
| `review` | Independent code review of the diff before merge | 1+ | the primary's own review pass |
| `debug` | Owns root-cause investigations | 1 | primary |
| `issue_author` | Drafts and files issues (`create-issue`) | 1 | primary |
| `release` | Cuts releases — **project-owned**, see below | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice (this is also why
`implement-issue`'s step 8 always runs the primary's own self-review pass in
addition to whichever `review` agent(s) are configured).

## `release` is project-owned — the baseline ships no `/release`

The baseline **names** the `release` role and resolves it like any other. It
deliberately ships **no `/release` workflow**, and will not (issue #3).

Cutting a release is the one job with no defensible generic shape. A sweep of
four real projects found four incompatible schemes:

| Project shape | Version | Changelog | Artifact / publish |
|---|---|---|---|
| App with a milestone roll | SemVer | `git-cliff` | tag + roll the milestone |
| Container service | SemVer | hand-written | GHCR image, `cosign`-signed |
| Support tooling | **CalVer** `YYYY.MM.patch` | **none** | tag only |
| WordPress plugin | plugin header | readme.txt section | `build.sh` zip + `gh release create` |

A skeleton that "bumps a version, regenerates a changelog from commits, tags,
and hands off to deploy" is wrong for three of those four. It is also wrong in
the expensive direction — a release is the one workflow whose mistakes are
published under a permanent tag, so a plausible-but-wrong default costs more
than no default at all. The general-over-specific rule in
[design-principles.md](design-principles.md) points the same way: there is no
general form here to extract, only four specific ones.

### What you do instead

**1. Write your repo's own `/release` skill.** This is the
`handling-the-unknown` prescribed home for a workflow that genuinely diverges:
a project-scoped skill. For Claude the path is verified today —
`.claude/skills/release/SKILL.md`, which takes precedence over any installed
base skill of the same name (see
[per-project-overrides.md](per-project-overrides.md)). Codex and Gemini
project-local skill placement is **not** verified end-to-end yet
(`scripts/lib/skill-compose.sh` is Claude-only in v1, and Gemini's skills
install under a different root); if your primary is one of those, check
follow-up #62 rather than assuming the symmetric path works.

**2. Have that skill honor `[roles].release` itself.** Setting

```toml
[roles]
release = "codex"
```

installs nothing and changes no behavior on its own — it is a *declaration*,
and only a consumer makes it real. Your release skill resolves it and shells
out when the resolved token is not the agent already driving:

```bash
RELEASE_AGENT="$(bash "$HOME/.claude/scripts/lib/role-dispatch.sh" resolve release)"
if [ "$RELEASE_AGENT" != "claude" ]; then
  printf '%s' "$RELEASE_PROMPT" \
    | bash "$HOME/.claude/scripts/lib/role-dispatch.sh" invoke release
fi
```

Skip that lookup and the manifest entry is silently ignored — a common and
confusing failure, because `agents.toml` *looks* like it is in force.

**3. Let `/roadmap` call it.** In release-readiness mode `/roadmap` prints
`Next: /release` once the active milestone's requirements are met — it
**emits, never runs**. A repo with no release skill therefore gets an
unrunnable suggestion, not an error. Point the emission at a different command
with the roadmap artifact's `<!-- release-command: CMD -->` marker (see
[release-goal-convention.md](release-goal-convention.md)).

### `/release` is not `/new-release`

These two are easy to confuse — both shipped in the same session once — and
they share no work:

| | `/new-release` (ships in the baseline) | `/release` (yours to write) |
|---|---|---|
| Subject | an **upstream CLI's** release — Claude Code, Codex, Antigravity | **your project's** release |
| Trigger | that vendor cut a version you want to adopt | your release milestone's requirements are met |
| Does | reads the changelog, applies config/code/doc fallout as one PR | bumps the version, tags, publishes the artifact |
| Touches your version/tags | **never** | that is its whole job |

Rule of thumb: `/new-release` reacts to *someone else's* release;
`/release` produces *yours*.

## Agent tokens

`claude` · `codex` · `gemini` (Antigravity). Adding another agent is one new
`agents/<token>/` adapter — see [adding-an-agent.md](adding-an-agent.md).

## The `agents.toml` manifest

A project drops its own copy of `templates/agents.toml` at its repo root
(typically via `agent-init`) and edits `[roles]` (and optionally `[gates]`):

```toml
# ai-dev-baseline — per-project agent role manifest.
#
# Drop this file at your repo root and set who does what for THIS project, then
# run `agent-init`. Any role you leave unset falls back to your global default
# manifest, then to the built-in default (see docs/roles-and-agents.md).
#
# Agent tokens: claude | codex | gemini

[roles]
primary      = "claude"     # drives /implement-issue. Exactly one agent.
gap_analysis = "codex"      # pre-implementation adversarial pass. "" to skip.
review       = ["claude"]   # code review before merge. 1+ agents; more = better.
debug        = "claude"     # owns root-cause investigations.
# issue_author = "claude"   # defaults to `primary` if unset
# release      = "claude"   # defaults to `primary` if unset

# Optional: override the auto-detected quality gates for this repo. The gate
# runner auto-detects pnpm/npm/yarn/bun, cargo, go, and python projects; set
# these only when detection is wrong or the repo needs specific commands.
# An empty string disables that gate.
[gates]
# typecheck = "pnpm typecheck"
# lint      = "pnpm lint"
# test      = "pnpm test"
# format    = "pnpm format:check"
```

`[gates]` is an open set — beyond overriding the built-in `typecheck` / `lint`
/ `test` / `format`, you can add custom gates (e.g. `build`), declare a gate
N/A via `[gates.state]`, or path-scope one via `[gates.scope]`. It is
documented in full in [per-project-overrides.md](per-project-overrides.md).

## Resolution order

For any role, a workflow resolves the responsible agent in this order:

1. The value in the **repo's own** `agents.toml` `[roles]`.
2. Else the **global default manifest** at
   `~/.config/ai-dev-baseline/agents.toml` (written once by `install.sh`; see
   [installation.md](installation.md)).
3. Else the **built-in default** in the role table above.

So a repo with no `agents.toml` at all still works — it inherits your global
default manifest. Two layers are easy to conflate, so name them precisely:

- **The global default manifest** `install.sh` writes sets `primary = claude`,
  `gap_analysis = codex`, `review = ["claude"]`, `debug = claude`. This is what
  most machines actually resolve against.
- **The built-in fallback** — used only when even the global manifest is absent —
  is the "Default if unset" column of the role table above: `primary = claude`,
  `gap_analysis` **skips**, and `review` / `debug` / `issue_author` / `release`
  fall back to the **primary**. (So the built-in `review` is *the primary's own
  pass*, not `[claude]` literally — they happen to coincide when the primary is
  Claude, but they are different rules.)

`scripts/lib/role-dispatch.sh` implements exactly this order (see below).

## Cross-agent invocation

When a workflow reaches a step owned by a *different* agent than the one
currently driving, it shells out to that agent's non-interactive entrypoint:

| Agent | Non-interactive invocation | Root config it reads |
|---|---|---|
| `claude` | `claude -p "<prompt>"` (when Claude is already driving, the step runs in-process via **model-invokable** tools — an Agent-tool subagent and/or a model-invokable skill like `/simplify`; never a user-only skill such as `/code-review`) | `~/.claude/CLAUDE.md` |
| `codex` | `codex exec --cd <repo> -` (prompt piped on stdin) | `~/.codex/` + `AGENTS.md` |
| `gemini` | `agy -p "<prompt>"` (Antigravity CLI) | `~/.gemini/GEMINI.md` |

> **codex timeout caveat.** `codex exec` reads and reasons over the whole
> repo — it routinely takes **3–7 minutes**, well past a default 2-minute
> command timeout. Any cross-agent `codex exec` call needs a timeout of at
> least **7 minutes (420,000–600,000 ms)**. A SIGTERM at 2 minutes (exit code
> 143) is a too-tight bound, not a failure of the pass — re-run it longer,
> don't treat the exit code as a verdict. A genuine timeout at the *full*
> ≥7-min bound **is** an incomplete invocation, though — retry, then fall back,
> per the delegated-step completion contract in [`roles.md`](../base/roles.md).

## The role-dispatch helper (runtime)

`scripts/lib/role-dispatch.sh` turns the resolution order and the invocation table above into
a runtime command, installed beside `project-gates.sh` under every agent's `scripts/lib/`. A
workflow calls it instead of hand-writing the same lookup + CLI in each skill:

| Command | What it does |
|---|---|
| `role-dispatch.sh resolve <role>` | Print the resolved agent token(s), one per line. Empty output = a legitimate skip (only `gap_analysis`). Validates the manifest — an unknown token or an explicit `review = []` is a hard error, never a silent fall-through. |
| `role-dispatch.sh invoke <role\|agent>` | Prompt on stdin → run one agent's CLI with the documented flags + the ≥7-min codex bound; stdout is that agent's **clean final message** (for `codex`, captured via `--output-last-message`, so exploration-stream noise never leaks in). A multi-agent `review` role is refused — use `resolve` + a per-slot `invoke <token>` loop so same-agent slots stay in-process. |
| `role-dispatch.sh bots` | Print the configured async external-bot reviewer logins (see below). |

`bin/agent-init` sources it to print the full effective role map (repo → global → built-in),
and `/implement-issue` / `/resolve-pr-threads` call it for gap-analysis, review, and the
bot-thread allowlist.

## Async external-bot reviewers

The `review` role is for **in-session** reviewers (agent CLIs run while the work is live). A
repo may *also* be reviewed by an **async external bot** — a GitHub App that posts review
threads *after* the PR opens (the Codex connector `chatgpt-codex-connector`, a `…[bot]`
reviewer). Those get their own manifest home, `[reviewers]`:

```toml
[reviewers]
# Logins that post threads after the PR opens. /resolve-pr-threads auto-resolves ONLY threads
# whose author is in this allowlist (exact login match — never a [bot]-suffix heuristic, so a
# human thread is never touched). unset → the built-in default set; [] → disable.
bots = ["chatgpt-codex-connector", "gemini-code-assist[bot]", "copilot[bot]"]
```

`/resolve-pr-threads` derives its resolvable-login set from `role-dispatch.sh bots`, so the
manifest is the single source and a repo can add or disable a bot without editing a skill.

> **Scope.** The role model is a static declaration plus this bot allowlist — **not** a dynamic
> orchestration engine. Bespoke per-project patterns (dynamic mid-task consult agents,
> worktree-parallel swarms, a hardened per-repo CLI wrapper) stay **project-scoped skills** (the
> `handling-the-unknown` home for a genuinely-diverging workflow), not new `agents.toml`
> vocabulary. The baseline hands every project the same resolvable roles; it does not replace a
> project's own orchestrator.

## Worked example (a): Claude primary + Codex gap-analysis + Claude & Gemini review

```toml
[roles]
primary      = "claude"
gap_analysis = "codex"
review       = ["claude", "gemini"]
debug        = "claude"
```

Running `/implement-issue 123` with Claude as the driving agent:

1. Claude does preflight + reads the issue (native).
2. **Step 3 (gap analysis)** resolves to `codex` → Claude builds the
   gap-analysis prompt and pipes it to `codex exec --cd <repo> -` with a
   ≥7-minute Bash timeout, then reads codex's findings back in.
3. Claude implements, runs gates, commits (all native — `primary` is Claude).
4. **Step 8 (review)** resolves to `["claude", "gemini"]` → Claude runs its
   own **in-process** review pass (`/simplify` for quality, then a
   `general-purpose` Claude subagent for the adversarial bug review — it never
   model-invokes the user-only `/code-review`), **and** separately shells out
   `agy -p "<review prompt over the diff>"` for Gemini's independent pass. Each
   reviewer is a slot that must complete (retry → fallback → block on failure);
   both sets of completed findings feed step 9's triage.
5. Claude pushes, opens the PR, and files any deferred work as issues (step
   12) — all native, since `primary` is Claude throughout.

## Worked example (b): Codex primary + Claude review

```toml
[roles]
primary      = "codex"
gap_analysis = ""            # skip the gap-analysis pass entirely
review       = ["claude"]
debug        = "codex"
```

Here Codex is the one driving the whole `implement-issue` run (invoked as
`codex exec --cd <repo> -` from whatever kicks it off) — the same playbook,
just executed by a different agent:

1. Codex does preflight, reads the issue, and — because `gap_analysis = ""`
   — skips step 3 entirely, noting "gap-analysis skipped (unassigned)" for
   the eventual PR body.
2. Codex implements, runs gates, commits.
3. **Step 8 (review)** resolves to `["claude"]`, a different agent than the
   one driving → Codex shells out `claude -p "<review prompt over the
   diff>"` to get Claude's independent review pass, since Claude isn't
   already resident to run that pass in-process.
4. Codex triages the findings, pushes, opens the PR, and files follow-up
   issues.

## Why this matters

Because the practices in `base/practices/` are agent-neutral and every
agent's rendered root doc carries the same content (see
[philosophy.md](philosophy.md)), the only thing that changes between these
two examples is four lines in `agents.toml`. The workflow, the gates, the
state protocol, and the discipline are identical either way.

## See also

- [installation.md](installation.md) — where the global default manifest
  gets written.
- [per-project-overrides.md](per-project-overrides.md) — `[gates]` overrides
  and other per-project layering.
- [adding-an-agent.md](adding-an-agent.md) — registering a new agent token so
  it can fill any role above.
