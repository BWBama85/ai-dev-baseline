<!-- GENERATED FILE — do not edit by hand.
     Source: base/practices/handling-the-unknown.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->

# Handling the unknown — procedure

The baseline defines the *known* — practices, workflows, gates for known stacks. The
moment an agent hits something it *doesn't* cover (an unfamiliar toolchain, gate, config,
convention, role setup, doc shape, or tool), improvisation is where drift is born: two
agents, two runs, or two similar projects organize the *same* unknown two *different*
ways. A deterministic protocol makes the same unknown land the same way every time,
regardless of which agent is driving.

   **File a baseline issue only if the gap clears the bar in `issues-and-scope.md`** —
   you can name who does it and what breaks if nobody ever does. "Many projects *would*
   want this" is a hypothesis about absent users, not an answer to either question; a gap
   *you* just worked around with a stopgap that holds is, by demonstration, not breaking
   anything. A config surface that covered the case is the fix, not a placeholder for one.

## Prescribed homes (one legal home per category)

Placement is **forced, not the agent's choice.** These are the homes for the categories
the baseline supports *today*; anything outside them is drift. A category with no home
yet is itself an escalation (bucket 4) — say so and ask, don't invent a home.

| Category of project-specific content | One prescribed home |
|---|---|
| Quality-gate command (different/extra/disabled) | `agents.toml [gates]` (`""` disables) |
| Per-package gate command (one package runs its own test, lint, …) | a custom gate in `agents.toml [gates]` named for the package (`test-api`), scoped by `[gates.scope]` |
| Role assignment (who is primary / reviews / …) | `agents.toml [roles]` |
| Project rule / convention / stack boundary that holds repo-wide | the repo's own root doc (`CLAUDE.md` / `AGENTS.md` / `GEMINI.md`) |
| Fact about one package (a subtree with its own manifest) | a nested root doc inside that package (`apps/api/CLAUDE.md`, …) |
| Fact about paths that span the tree (a cross-cutting concern) | `.claude/rules/<name>.md` scoped with `paths:` frontmatter |
| Custom gate *policy* (order, conditional) | the repo's own `.claude/scripts/precommit-gate.sh` |
| Workflow that genuinely diverges | a baseline issue — a project carries no skills of its own (`policy:one-baseline`); `/adopt`'s `workflows` rung reports any it finds |
| Deviation from a baseline rule | a `DEVIATION` entry in the decision log (it explains a `workflows` finding and never clears one; with an `audit-rule` the adoption conformance audit can clear, it turns that finding into a reported deviation) |
| A recurring review-finding class this project keeps hitting | `.ai-dev-baseline/patterns.md` — the pattern ledger and its promoted checklist |
| General gap (would help many projects) | the supported stopgap surface; a baseline issue **only if it clears the bar** |

See `docs/per-project-overrides.md` for the override surfaces and
`docs/roles-and-agents.md` for `agents.toml`.

## Facts and workflows: what a project keeps

Under `policy:one-baseline` a project keeps its **facts** and gives up its own **workflows**.
The test that separates them:

- A **fact** says *what is true of this code*: "migrations under `src/db/` are append-only",
  "UI under `src/components/` must meet WCAG 2.1 AA", "the API package runs
  `pnpm --filter api test`". It is kept, in its home from the table above.
- A **workflow** says *what steps to run* or *which skill to invoke*: "to ship, run `/deploy`",
  "for a new handler, follow these nine steps". It is retired: its delta becomes a baseline
  issue, and the baseline's own workflow runs instead.
- A **mixed** file holds both. It is split: the fact ranges stay in their home and the workflow
  ranges retire.

Every instruction surface obeys this, not only the root doc: a project's `.claude/rules/*.md`
files, its nested root docs, and any `.codex/` or `.gemini/` hand mirror of them.

**Choosing the home for a fact.** Repo-wide → the root doc. One package's own conventions → a
nested root doc inside that package; a package is a directory holding its own manifest
(`package.json`, `go.mod`, `pyproject.toml`, …). Paths that span the tree, or a subtree that is
not a package → `.claude/rules/<name>.md` with `paths:`. `paths:` is the only frontmatter key
Claude Code reads from a rule. A rule scoped with any other key, such as `globs:`, is ignored as
scope and loads at every session start. A rule with no `paths:` holds repo-wide facts, so its
home is the root doc.

**Reach is reported, never assumed.** Claude loads a `paths:` rule when it touches a matching
file, and a nested `CLAUDE.md` once it touches a file in that directory. Codex reads `AGENTS.md`
only from the project root down to its working directory, one file per directory with
`AGENTS.override.md` first, so a session started at the root never sees `apps/api/AGENTS.md`.
Gemini CLI (0.35 and later) loads a nested `GEMINI.md` when a tool touches that directory. Nothing
but Claude reads `.claude/rules/`, so carrying a kept rule to Codex and
Gemini is the cross-agent mirror's job, not something a project improvises per file.

**`agents.toml` carries configuration, never prose**: commands, scopes, roles. A fact lives in
the root doc or a rules file.

**Keeping a surface where it is.** A project may keep a fact surface outside its home with a
`project-delta` entry in the decision log that names the path on a `keeps:` line. The entry
explains a location. It never keeps a workflow, and a `keeps:` line whose path is not one plain
repository path is refused. The refusal is reported, and the finding stands.

## Record every decision

Keep a per-project decision log at **`.ai-dev-baseline/decisions.md`** — one tracked,
agent-neutral file (not under `.claude/`, because the protocol is cross-agent). It makes
any residual divergence visible, auditable, and reviewable: if two projects handled the
same unknown differently, the records make it findable. Append one entry per unknown:

```
## <id> — <short title>
- date:      YYYY-MM-DD
- category:  general | project-delta | deviation
- unknown:   what the baseline didn't cover
- decision:  what you did
- placement: the prescribed home it landed in (path / table / issue #)
- reason:    why this classification and placement
- baseline-issue: #N   (for a "general" gap; else "n/a")
- keeps:     optional, project-delta only — one repository path kept outside its home
```

A **deviation** adds the fields that make it a deliberate, reviewable fork — never silent:

```
## <id> — DEVIATION: <short title>
- date:          YYYY-MM-DD
- category:      deviation
- baseline-rule: the exact baseline rule being contradicted
- conflict:      the project requirement that forces the deviation
- scope:         where it applies (paths / workflows)
- reason:        why the deviation is justified
- audit-rule:    optional — the adoption conformance audit rule it answers (same-model-review)
```

## Rules

- **The only legitimate homes for project-specific content are the prescribed ones.**
  Anything living elsewhere is drift.
- **Never invent a new home to avoid asking.** A category with no prescribed home is
  bucket 4 (escalate), not license to improvise.
- **A general gap earns a filed issue only when it clears the bar** (`issues-and-scope.md`).
  A stopgap that holds is a fix, not a debt: if nothing breaks while it stands, the second
  question has no answer and there is nothing to file. Record the decision either way — the
  decision log, not the tracker, is what makes a divergence visible.
- **Record before you move on.** An unrecorded decision is an invisible divergence.

## Why

The baseline removes drift by giving every known thing one home. Its blind spot is the
*unknown* — and an unhandled unknown is handled by improvisation, which is drift by
another name. A deterministic classify → place → record → escalate protocol closes that
blind spot: the same unknown lands the same way every time, and the few genuinely
ambiguous cases surface to the owner instead of silently forking two projects apart.
