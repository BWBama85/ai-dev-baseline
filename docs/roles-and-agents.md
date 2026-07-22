# Roles and agents

This expands `base/roles.md` into a user-facing guide. See
[philosophy.md](philosophy.md) for *why* separating role from agent is the
whole point of an agent-neutral baseline.

## The core idea

The framework separates **what a job is** (a role) from **which AI does it**
(an agent). A project declares the mapping once, in an `agents.toml` at its
repo root; every workflow (`/implement-issue`, `/create-issue`, `/release`,
…) reads that mapping and delegates each step to whichever agent the manifest
names for that role — **with no change to the workflow itself.** Swap
`primary` from `claude` to `codex` in `agents.toml` and the entire
`implement-issue` playbook runs unchanged; only who executes each step moves.

## Roles

| Role | Job | Cardinality | Default if unset |
|---|---|---|---|
| `primary` | Drives implementation end-to-end (`implement-issue`) | exactly 1 | required |
| `gap_analysis` | Adversarial pre-implementation read of the issue | 0 or 1 | skip the pass |
| `review` | Independent code review of the diff before merge | 1+ | primary's own self-review only |
| `debug` | Owns root-cause investigations | 1 | primary |
| `issue_author` | Drafts and files issues (`create-issue`) | 1 | primary |
| `release` | Cuts releases | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice (this is also why
`implement-issue`'s step 8 always runs the primary's own self-review pass in
addition to whichever `review` agent(s) are configured).

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

`[gates]` is documented in full in
[per-project-overrides.md](per-project-overrides.md).

## Resolution order

For any role, a workflow resolves the responsible agent in this order:

1. The value in the **repo's own** `agents.toml` `[roles]`.
2. Else the **global default manifest** at
   `~/.config/ai-dev-baseline/agents.toml` (written once by `install.sh`; see
   [installation.md](installation.md)).
3. Else the **built-in default** in the role table above.

So a repo with no `agents.toml` at all still works — it inherits your global
defaults, and if those were never edited, the built-in defaults (`primary =
claude`, `gap_analysis = codex`, `review = [claude]`, `debug = claude`).

## Cross-agent invocation

When a workflow reaches a step owned by a *different* agent than the one
currently driving, it shells out to that agent's non-interactive entrypoint:

| Agent | Non-interactive invocation | Root config it reads |
|---|---|---|
| `claude` | `claude -p "<prompt>"` (or a native skill when Claude is already driving) | `~/.claude/CLAUDE.md` |
| `codex` | `codex exec --cd <repo> -` (prompt piped on stdin) | `~/.codex/` + `AGENTS.md` |
| `gemini` | `agy -p "<prompt>"` (Antigravity CLI) | `~/.gemini/GEMINI.md` |

> **codex timeout caveat.** `codex exec` reads and reasons over the whole
> repo — it routinely takes **3–7 minutes**, well past a default 2-minute
> command timeout. Any cross-agent `codex exec` call needs a timeout of at
> least **7 minutes (420,000–600,000 ms)**. A SIGTERM at 2 minutes (exit code
> 143) is a timeout that wasted the pass, not a failure of the pass itself —
> re-run it longer, don't treat the exit code as a verdict.

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
   own native `/code-review` skill, **and** separately shells out
   `agy -p "<review prompt over the diff>"` for Gemini's independent pass.
   Both sets of findings feed step 9's triage.
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
   already resident to invoke `/code-review` natively.
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
