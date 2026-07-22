# base/workflows

**Reserved for agent-neutral workflow specs.** The idea: describe each workflow
(`implement-issue`, `create-issue`, `resolve-pr-threads`, `cleanup`, `debug`,
`review`, `release`) once here, provider-agnostically, and have each agent adapter
render it into that agent's native form.

**Today**, the canonical workflow implementations are the **Claude skills** under
[`agents/claude/skills/`](../../agents/claude/skills). Extracting the shared
procedure into specs here is what unlocks first-class Codex/Gemini workflows — see
the "multi-agent parity" issue in the repo's tracker.

Until those specs land, `base/roles.md` documents the roles each workflow uses, and
the Claude `SKILL.md` files are the source of the detailed procedure.
