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
| `survey` | Bounded pre-implementation repo survey (`implement-issue` step 2b, #435) | 0 or 1 | primary (`""` skips) |
| `review` | Independent code review of the diff before merge | 1+ | the primary's own review pass |
| `debug` | Owns root-cause investigations | 1 | primary |
| `issue_author` | Drafts and files issues (`create-issue`) | 1 | primary |
| `release` | Cuts releases — **project-owned**, see below | 1 | primary |

More than one `review` agent is encouraged — independent perspectives from
different models catch more than one model reviewing twice (this is also why
`implement-issue`'s step 8 always runs the primary's own self-review pass in
addition to whichever `review` agent(s) are configured).

**Prefer a `review` token that is not `primary` (#211).** The role's job is the word in
its own row — *independent* — and a reviewer that is the same model as the implementer
cannot supply it. Both vendors' published prompting guidance points at the same split
from opposite ends: Anthropic's Opus 5 guidance asks that Claude **not** be given
explicit verification scaffolding (it self-corrects natively, and over-verifies when told
to), while OpenAI's asks Codex for exactly the named-checklist, required-vs-optional pass
step 8 sends. Hence the shipped manifest pairs `primary = "claude"` with
`review = ["codex"]`. A same-agent slot still runs — see [the review rungs](#which-review-actually-happens-the-rungs)
for how it is reported.

## `release` is project-owned — the baseline ships no `/release`

The baseline **names** the `release` role and resolves it like any other. It
deliberately ships **no `/release` workflow**, and will not (issue #3).

Cutting a release is the one job with no defensible generic shape. A sweep of
four real projects found four incompatible schemes:

| Project shape | Version | Changelog | Artifact / publish |
|---|---|---|---|
| App with a generated changelog | SemVer | `git-cliff` | tag |
| Container service | SemVer | hand-written | GHCR image, `cosign`-signed |
| Support tooling | **CalVer** `YYYY.MM.patch` | **none** | tag only |
| WordPress plugin | plugin header | readme.txt section | `build.sh` zip + `gh release create` |

*Milestone rollover is deliberately absent from this table.* It was the one step all four shapes
shared, so #74 factored it out of every one of them into `baseline release roll` — what remains
above is only what genuinely differs, which is the evidence for the decision.

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
RD="$HOME/.claude/scripts/lib/role-dispatch.sh"
RELEASE_PROMPT="Cut the release for this repo: <your procedure here>."

# Exit non-zero on an invalid manifest — do NOT let an unresolvable role fall through to a
# branch. `resolve` prints the error itself; swallowing its status is the same silent-ignore
# this whole section warns about.
RELEASE_AGENT="$(bash "$RD" resolve release)" || exit 1

if [ "$RELEASE_AGENT" = "claude" ]; then
  : # Claude is already driving — run the release steps in-process.
else
  printf '%s' "$RELEASE_PROMPT" | bash "$RD" invoke release
fi
```

Skip that lookup and the manifest entry is silently ignored — a common and
confusing failure, because `agents.toml` *looks* like it is in force.

**3. Let `/roadmap` call it.** In release-readiness mode `/roadmap` prints your release
command once the active milestone's requirements are met — it **emits, never runs**.

Name it on the roadmap artifact with `` `<!-- release-command: /your-skill -->` `` (see
[release-goal-convention.md](release-goal-convention.md)). There is **no default**, and
`/roadmap` verifies the command **resolves to an installed skill** before emitting it: a repo
with no release skill gets `Next: none — …` naming what to add, not a suggestion that cannot
run. That is deliberate — an unresolvable slash command does not fail loudly, it fuzzy-matches
the nearest built-in, so a bare `/release` on a repo without one silently opens an unrelated
viewer at the moment the roadmap says *cutting* (#188).

**4. End it with `baseline release roll`.** Milestone rollover is the one part
of cutting that is *not* yours to invent: it has a single correct shape, on
milestones the baseline already creates, and skipping it strands the loop
(`/roadmap` keeps re-emitting the same cut). So the baseline ships it, and your
`/release` should call it last — `baseline release roll --version vX.Y.Z`. What
it does and why it refuses what it refuses is documented once, in
[release-goal-convention.md](release-goal-convention.md) (#74).

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
review       = ["codex"]    # code review before merge. 1+ agents; more = better.
                            # Prefer a token that is NOT `primary` — see below.
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
  `gap_analysis = codex`, `review = ["codex"]`, `debug = claude`. This is what
  most machines actually resolve against.
- **The built-in fallback** — used only when even the global manifest is absent —
  is the "Default if unset" column of the role table above: `primary = claude`,
  `gap_analysis` **skips**, and `review` / `debug` / `issue_author` / `release` /
  `survey` fall back to the **primary** (a DECLARED `survey = ""` is the skip, #435). (So the built-in `review` is *the primary's own
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

> **Dispatch bound (hang backstop).** `codex exec` reads and reasons over the whole
> repo; at high reasoning effort a non-trivial diff **routinely runs longer than 10
> minutes**. `role-dispatch.sh` therefore bounds every invocation at **45 minutes
> (2700 s)**, overridable with `ADB_DISPATCH_TIMEOUT_SECS` — though a stock clone
> should never need to set it. The bound applies to **every agent and role** the
> helper dispatches, not just codex gap analysis.
>
> Treat it as a **hang backstop, not a work budget.** A backstop belongs well above
> the longest legitimate run; setting it near typical runtime is what made ordinary
> passes fail for three consecutive runs (issue #93). It escalates TERM → grace →
> KILL, so it always terminates rather than hanging on a signal-resistant child.
>
> **Dispatch long passes in the background.** A harness commonly caps a *foreground*
> command (Claude Code: 10 minutes) far below this bound — so in the foreground the
> outer cap fires first and raising the backstop changes nothing. Use the harness's
> own detached-execution facility; a shell `&` does not escape the cap.
>
> Read the **classified** failure the helper prints rather than treating any non-zero
> as "the agent failed": rc **124** is our backstop, rc **143** (SIGTERM) is an outer
> bound killing it first, anything else is a real agent error. Each has a different
> fix. An incomplete invocation is retried once, then handled per the delegated-step
> completion contract in [`roles.md`](../base/roles.md) — which for `gap_analysis`
> means **surfacing, never substituting another agent**.

## The role-dispatch helper (runtime)

`scripts/lib/role-dispatch.sh` turns the resolution order and the invocation table above into
a runtime command, installed beside `project-gates.sh` under every agent's `scripts/lib/`. A
workflow calls it instead of hand-writing the same lookup + CLI in each skill:

| Command | What it does |
|---|---|
| `role-dispatch.sh resolve <role>` | Print the resolved agent token(s), one per line. Empty output = a legitimate skip (`gap_analysis` unset/`""`, and `survey = ""`). Validates the manifest — an unknown token or an explicit `review = []` is a hard error, never a silent fall-through. |
| `role-dispatch.sh invoke <role\|agent>` | Prompt on stdin → run one agent's CLI with the documented flags + the 45-min hang backstop; stdout is that agent's **clean final message** (for `codex`, captured via `--output-last-message`, so exploration-stream noise never leaks in). A non-zero exit prints one **classified** line to stderr (our backstop 124 / outer SIGTERM 143 / real agent error). A multi-agent `review` role is refused — use `resolve` + a per-slot `invoke <token>` loop so same-agent slots stay in-process. |
| `role-dispatch.sh available <agent>` | Is that agent's CLI on PATH **here**? Silent — the exit code is the answer (`0` available · `1` known agent whose CLI is absent · `2` not an agent token). A third question, deliberately separate from *which agent is assigned* (`resolve`) and *did the agent fail* (an `invoke` rc): an absent CLI is a configuration fact knowable in advance, not a reviewer that broke. It answers "on PATH" and claims no more — not authenticated, not configured, not working. |
| `role-dispatch.sh bots` | Print the configured async external-bot reviewer logins (see below). |

## Which review actually happens: the rungs

A role names an agent; it cannot make that agent's CLI exist. `implement-issue` step 8
therefore asks **before** it dispatches, and reports which rung the project is on.

**One predicate owns the ladder: `role-dispatch.sh review-rung`.** Step 8 and `agent-init`
both *call* it rather than each interpreting `resolve` + `available` + the bot allowlist in
their own words. That is not tidiness — the two-interpretation version was written and
promptly diverged, with the workflow naming the bare `bots` (whose unset default is eight
built-in logins) so a repo that had declared nothing would have been told an async reviewer
was coming. It prints one line, `<rung>[ <detail>][ missing=<tokens>]`, and takes the **driving agent** as an
optional argument — `implement-issue` passes its own token (because "independent" means *not the
model that wrote the diff*, and `primary` is only a claim about who normally writes it), while
`agent-init` omits it to describe the configured shape. The `missing=` field lists configured
reviewer slots whose CLI is absent, on any rung: `independent codex missing=gemini` means the diff
was independently reviewed **and** a slot the operator configured reviewed nothing. The deferred
rung is decided with `bots --comparable`, the same reader the merge guard uses, so a rung can never
promise a hand-off the guard rejects:

| Rung | Condition | What happens |
|---|---|---|
| **independent** | a `review` slot's CLI is available and its token ≠ the driving agent | the real thing: an independent model reviews the diff |
| **same-model** | the only usable slot is the driving agent itself | the slot **runs**, and is labelled *not independent* |
| **deferred** | no usable in-session slot, but `[reviewers] bots` **declares** an async reviewer | the PR opens; the declared reviewer gates step 10's auto-arm |
| **none** | neither | the run proceeds and says plainly that nothing independent reviewed the diff |

Three properties of this ladder are load-bearing:

- **An absent CLI never blocks the run, and never writes a blocked marker.** It is not a
  reviewer that failed. A reviewer that *ran* and did not return still blocks, exactly as
  before — the two are different facts and step 8 names which one happened. Collapsing
  them would block most first runs (the CLI is usually the thing missing) or ship a diff
  nobody reviewed.
- **The gap is never filled with a same-model stand-in.** A second opinion from the model
  that wrote the diff is not a second opinion, and manufacturing one is worse than the
  honest gap because it reads as coverage in the close-out.
- **"Deferred" is narrower than it sounds.** The async reviewer gates
  `implement-issue`'s `--auto` arm and nothing else: `pr-review.sh gate` withholds
  *unattended arming* until the declared reviewer has seen the head commit. It does not
  block a manual merge, it is not branch protection, and it resolves no threads. The
  honest reading is *"an independent reviewer will see this before it can merge
  unattended"* — not *"the diff has been reviewed."*

The **declared** allowlist is what decides the deferred rung, read through
`bots --declared` rather than the bare `bots`. The two differ on *unset*: bare `bots`
substitutes the built-in default set of common review bots, so an unset `[reviewers]`
would otherwise report eight logins and promote a project that has declared nothing from
*none* to *deferred*.

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

### The same key has two readers, and they disagree about "unset" on purpose (#134)

`[reviewers] bots` now answers a second question: **must `/implement-issue` wait for a reviewer
before it arms auto-merge?** The two consumers need opposite defaults, and each is right for its
own job:

| Reader | Question | Unset means |
|---|---|---|
| `role-dispatch.sh bots` (`/resolve-pr-threads`) | *whose threads may I auto-resolve?* | the built-in allowlist |
| `role-dispatch.sh bots --comparable` (`pr-review.sh gate`, `pr-watch.sh`) — wraps `bots --declared` | *whose review must I wait for?* | **undeclared — fail closed** |

An over-broad default is harmless when resolving threads; as a *merge* gate it is exactly wrong.
Defaulting to the built-in set would make every repo wait for eight bots it does not have.
Defaulting to empty would arm auto-merge on a repo that **does** have one — which is #134 itself,
where a PR merged 29 seconds after opening and six minutes before its reviewer posted five real
bugs. So the merge gate never defaults; it reads the key as a tri-state:

- **declared, non-empty** → those reviewers must have reviewed the PR's **current head commit**
  before auto-merge is armed. All of them, not any one — the list is declared, so it names exactly
  the bots this repo has;
- **`bots = []`** → this repo has **no** async reviewer; unattended arming continues as before;
- **undeclared** → unknowable, so the guard fails closed and reports what to add.

**A repo with no bot reviewer should declare `bots = []`** — one line that keeps `gh pr merge
--auto` working. A repo that *is* bot-reviewed should list its reviewers.

### How a declared login is matched (#173)

GitHub reports the same App two ways — GraphQL says `chatgpt-codex-connector`, REST says
`chatgpt-codex-connector[bot]` — so the guards normalize the `[bot]` suffix. They normalize it
**one way only: the API login toward your declaration, never your declaration toward the API.**

| You declare | It is satisfied by | Meaning |
|---|---|---|
| `foo` (bare) | API login `foo` **or** `foo[bot]` | **either** — the App, or a human account named `foo` |
| `foo[bot]` | API login `foo[bot]` only | **that App, exactly** — a human named `foo` never satisfies it |

**Bare is the portable spelling and the recommended default.** It matches whichever form the
reading API returns, which is why the built-in allowlist and this repo's own manifest use it.

**`foo[bot]` is the strict spelling**, and its strictness is against the *observed API spelling*
rather than a stable App identity: a guard that later reads a different API surface would stop
satisfying it. That fails safe — the guard withholds the arm rather than merging — but it is real,
and closing it needs an identity that is not a login string (tracked in #207).

> **Why not normalize both sides?** Because that is lossy in the dangerous direction. Stripping
> `[bot]` from your *declaration* too meant `bots = ["foo[bot]"]` was also satisfied by a **human
> account literally named `foo`** — and reactions are publicly writable, so on the clean-pass
> signal the bar was a login collision and nothing else. Not hypothetical: `gh api
> users/gemini-code-assist` returns a real **User** account, so the collision space is populated by
> exactly the kind of account that reviews pull requests. A `user.type` filter cannot rescue it —
> the reactions endpoint reports `type: "User"` for the Codex connector itself, so filtering on
> type would reject the real signal.

> **Prefer declaring it per repo.** The key layers repo → global like every other manifest key,
> so a declaration in `~/.config/ai-dev-baseline/agents.toml` applies to **every** repo on the
> machine — including ones where that App is not installed, where the guard will then wait for a
> reviewer that never arrives and auto-merge simply stops being armed. That fails in the safe
> direction and a per-repo `bots = []` overrides it, but "which bot reviews *this* repo" is
> repo-level information and reads best where it is true.

Expect the guard to skip arming on a bot-reviewed repo: step 10 runs seconds after the PR opens,
so a reviewer that takes minutes has definitionally not reviewed yet. That is the intended trade.

**The waiting half now exists** (#49), and since #416 it is the **default**: `/resolve-pr-threads`,
with no arguments, infers the one open PR, polls for the reviewer in a shell loop, resolves any
findings, asks for a re-review and goes round again until the reviewer passes or the round cap
(`[reviewers] max_rounds`, built-in 6) is reached — unless that cap is `0`, which removes the
ceiling entirely and so is never reached (#420). The waiting itself spends no model tokens — it is
a `sleep` loop with no model in it — provided the caller dispatches it as a background task rather
than chunking it across foreground shell calls, which is #417 and is specified in the skill's step
0b. It does **not** arm auto-merge afterwards, so unattended *arming* is still suspended on a
bot-reviewed repo. Whether the watcher should arm is an open decision, not an oversight: #49's
own text says it must "never merge", while this page and `docs/repo-settings.md` were written
expecting it to arm. That contradiction is #168, tracked rather than resolved by assumption.

> **Scope.** The role model is a static declaration plus this bot allowlist — **not** a dynamic
> orchestration engine. Bespoke per-project patterns (dynamic mid-task consult agents,
> worktree-parallel swarms, a hardened per-repo CLI wrapper) stay **project-scoped skills** (the
> `handling-the-unknown` home for a genuinely-diverging workflow), not new `agents.toml`
> vocabulary. The baseline hands every project the same resolvable roles; it does not replace a
> project's own orchestrator.

## Worked example (a): Claude primary + Codex gap-analysis + Codex & Gemini review

```toml
[roles]
primary      = "claude"
gap_analysis = "codex"
review       = ["codex", "gemini"]
debug        = "claude"
```

Running `/implement-issue 123` with Claude as the driving agent:

1. Claude does preflight + reads the issue (native).
2. **Step 3 (gap analysis)** resolves to `codex` → Claude builds the
   gap-analysis prompt and pipes it to `codex exec --cd <repo> -` under the
   45-minute hang backstop, **dispatched in the background** so the harness's
   10-minute foreground cap can't kill it first, then reads codex's findings
   back in. If codex cannot complete, Claude surfaces that — it does **not**
   quietly run the pass itself.
3. Claude implements, runs gates, commits (all native — `primary` is Claude).
4. **Step 8 (review)** resolves to `["codex", "gemini"]` → neither token is the
   driving agent, so `review-rung` reports `independent codex` and both slots
   shell out: `codex exec --cd <repo> -` for Codex and `agy -p "<review prompt
   over the diff>"` for Gemini, each under the 45-minute hang backstop. Each
   reviewer is a slot that must complete (retry → fallback → block on failure);
   both sets of completed findings feed step 9's triage. Had either CLI been
   absent, that slot would have been reported as a rung rather than failing the
   run — see [the rungs](#which-review-actually-happens-the-rungs).
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
