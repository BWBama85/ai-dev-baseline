# Handling the unknown

**When you meet something the baseline doesn't model, do not improvise a one-off.**
Classify it, put it in that bucket's one prescribed home, and record the decision.

The baseline defines the *known* — practices, workflows, gates for known stacks. The
moment an agent hits something it *doesn't* cover (an unfamiliar toolchain, gate, config,
convention, role setup, doc shape, or tool), improvisation is where drift is born: two
agents, two runs, or two similar projects organize the *same* unknown two *different*
ways. A deterministic protocol makes the same unknown land the same way every time,
regardless of which agent is driving.

## Protocol: classify → place → record → (when unsure) escalate

Classify the unknown into **exactly one** bucket, then act as that bucket prescribes:

1. **General** — many projects would hit or want this. → Use the relevant supported
   config surface if one fits (e.g. a missing gate command → `agents.toml [gates]`).
   Never a bespoke local fix others can't inherit. If no supported surface fits the gap,
   escalate (bucket 4) rather than inventing a new home.

   **File a baseline issue only if the gap clears the bar in `issues-and-scope.md`** —
   you can name who does it and what breaks if nobody ever does. "Many projects *would*
   want this" is a hypothesis about absent users, not an answer to either question; a gap
   *you* just worked around with a stopgap that holds is, by demonstration, not breaking
   anything. A config surface that covered the case is the fix, not a placeholder for one.
2. **Project-specific delta** — legitimately unique to this repo. → Record it in the
   **prescribed home for its category** (table below), never scattered or ad-hoc.
3. **Deviation** — the project deliberately contradicts a baseline rule. → Allowed, but
   **recorded explicitly** as a `DEVIATION` with `{baseline-rule, reason}`. Never a silent
   fork.
4. **Ambiguous / can't classify confidently** — → **STOP and ask the owner** a concrete
   question. Improvisation is how two projects diverge; escalation is the release valve
   that keeps the set honest (the completion-contract discipline, applied to *organization*).

## Prescribed homes (one legal home per category)

Placement is **forced, not the agent's choice.** These are the homes for the categories
the baseline supports *today*; anything outside them is drift. A category with no home
yet is itself an escalation (bucket 4) — say so and ask, don't invent a home.

| Category of project-specific content | One prescribed home |
|---|---|
| Quality-gate command (different/extra/disabled) | `agents.toml [gates]` (`""` disables) |
| Role assignment (who is primary / reviews / …) | `agents.toml [roles]` |
| Project rule / convention / stack boundary | the repo's own root doc (`CLAUDE.md` / `AGENTS.md` / `GEMINI.md`) |
| Custom gate *policy* (order, conditional) | the repo's own `.claude/scripts/precommit-gate.sh` |
| Workflow that genuinely diverges | a project-scoped skill shadowing the global one |
| Deviation from a baseline rule | a `DEVIATION` entry in the decision log |
| General gap (would help many projects) | the supported stopgap surface; a baseline issue **only if it clears the bar** |

See `docs/per-project-overrides.md` for the override surfaces and
`docs/roles-and-agents.md` for `agents.toml`.

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
