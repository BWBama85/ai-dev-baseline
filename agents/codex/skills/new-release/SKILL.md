---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/new-release.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: new-release
description: Review a Claude / Codex / Antigravity CLI release changelog against the current project and ACT on every actionable change — apply config/code/doc fixes this session and ship them as one PR (or edit user-level config directly), surface the few that need an owner decision, and drop the rest. Files a GitHub issue only for work genuinely blocked on a future release. Works in any repo that uses one of those CLIs.
---

# New CLI Release Review

> **Not the command that cuts *your* release.** `/new-release` reviews an **upstream
> CLI's** release (Claude Code · Codex · Antigravity) and applies the fallout to this
> project. It never bumps a version, writes a changelog entry, tags, packages, or
> deploys anything of yours. Cutting your own project's release is the **project-owned
> `release` role** — a `/release` skill your repo supplies; the baseline ships none on
> purpose (`base/roles.md`, issue #3). If you meant "ship our next version," stop: you
> want `/release`, not this.

Argument shape: `/new-release <cli> [version-or-source]`

The first argument is **required** and selects which upstream CLI to review:

- `claude` — `anthropics/claude-code` (binary `claude`)
- `codex` — `openai/codex` (binary `codex`)
- `agy` — `google-antigravity/antigravity-cli` (binary `agy`) — Google's Antigravity CLI, the successor to the now-retired Gemini CLI

The second argument is optional and selects which release. If omitted, default to the latest release for that tool (and consult the state file — see Step 0 — so the operator gets a "you last reviewed X, latest is Y" prompt instead of silently re-reviewing).

- `/new-release claude` — latest Claude Code release
- `/new-release codex 0.20.0` — that specific Codex tag
- `/new-release agy 1.0.9` — that specific Antigravity tag (or run `agy changelog` for the built-in notes)
- `/new-release claude <url>` — URL to a GitHub release, a CHANGELOG anchor, or a raw changelog blob
- `/new-release codex <file>` — local path to a changelog/markdown file (for pre-release notes pasted in)

If the first argument is missing or is not one of `claude` / `codex` / `agy`, stop and ask which tool to review. Do not guess.

Goal: walk the release notes for the chosen tool, cross-reference every line against how **this** project uses that CLI, and **act on every actionable change in the same session** — apply config/code/doc fixes and ship them as one PR (or, for user-level-only config, edit it directly), surface the handful that genuinely need an owner decision, and drop everything else. The deliverable is a change, not a backlog. A release with nothing for us is a valid, common result — report it plainly, never pad it.

## Why this is apply-or-drop (read once)

For a CLI we review every release of (the state file proves it), filing a GitHub issue for a one-line `settings.json` tweak is pure ceremony — it manufactures tracker debt and defers a 30-second edit into a multi-day round-trip. Worse is a "monitor" bucket: there is no monitoring system, so "monitor" means "silently forget." So this skill recognizes exactly four dispositions and **no others**:

- **apply** — make the change now. The verify-before-acting discipline (below) gates *applying*, not filing.
- **decide** — needs an owner choice (cost, security, a behavior change the owner cares about). One concise inline question → apply or drop. Never an issue.
- **drop** — anything not actionable now. This absorbs everything the old skill called "monitor"/"verify." Not actionable = noise.
- **defer-blocked** — the *only* path that files a GitHub issue: work that genuinely cannot be done until a *future* CLI release or external dependency lands. It must carry a concrete trigger ("do X once Claude Code ships Y"). This preserves the project's "out-of-scope → file an issue" rule while refusing to manufacture debt for work that could just be done now.

## Scope

This skill is project-agnostic. It does NOT assume any specific codebase. It only assumes:

- The project uses at least one of the three CLIs somewhere — spawned as a child process, invoked from scripts, driven by hooks, or configured via `.claude/` / `.codex/` / `.gemini/` files.
- It is a git repo with `gh` authenticated, so repo-level changes can ship as a PR.
- `git remote -v` points at the repo we want PRs opened against.

If the project has no integration with the chosen CLI at all, the skill stops at Step 3 with a note to the operator (different tool may be in use — confirm before re-running).

## Tool Dispatch Table

The steps below reference this table whenever they need a tool-specific value. Treat it as the single source of truth — do not hardcode tool names elsewhere.

| Token | Upstream repo | Binary | Project config dir(s) | Model id prefix(es) |
|-|-|-|-|-|
| `claude` | `anthropics/claude-code` | `claude` | `.claude/`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md` | `claude-opus-`, `claude-sonnet-`, `claude-haiku-` |
| `codex` | `openai/codex` | `codex` | `.codex/`, `AGENTS.md` | `gpt-`, `o3`, `o4` (and any `codex-*` IDs the operator has pinned) |
| `agy` | `google-antigravity/antigravity-cli` | `agy` | `.gemini/`, `GEMINI.md` (if present), and the user-global root `~/.gemini/` (`settings.json`, `config/hooks.json`, `config/mcp_config.json`) | `gemini-`, `claude-`, `gpt-oss` (Antigravity is multi-provider) |

If the operator has wired the tool somewhere unusual (a wrapper script in `bin/`, a homegrown config under `tools/`), the surface map in Step 3 will discover it via grep — the table is a starting set, not a closed list.

## Steps

### 0. Load And Sanity-Check State

State file lives at `.codex/state/new-release.json` (project-local, gitignored). Shape:

```json
{
  "claude": { "lastTag": "1.0.50", "reviewedAt": "2026-04-20T15:32:00Z" },
  "codex":  { "lastTag": "0.20.0", "reviewedAt": "2026-04-18T09:11:00Z" },
  "agy":    { "lastTag": "1.0.9", "reviewedAt": "2026-04-12T22:04:00Z" }
}
```

- Read the file with `Read`. If it doesn't exist, treat the per-tool entry as absent — do not create the file yet (creation happens in Step 7 after the review is actually dispositioned, so a cancelled review does not poison future runs).
- If the operator passed an explicit version and the state says that exact tag has already been reviewed (`lastTag === requested`), warn: "You already reviewed `<tool> <tag>` on `<reviewedAt>`. Re-run anyway? [y/n]" and wait for confirmation.
- If no version was passed, fetch the latest tag (Step 1) and compare to `state[tool].lastTag`:
  - **Equal** — tell the operator "Latest `<tool>` release is `<tag>`, already reviewed on `<reviewedAt>`. Nothing to do." and stop.
  - **State missing or older** — name both tags ("Last reviewed `<lastTag>`, latest is `<latestTag>`") and ask whether to review only the latest or walk the range. Reviewing the full range as one combined sweep is usually right (one PR batches all the applies); walk it newest-first.

State is per-tool, so a stale `claude` entry never blocks a `codex` review and vice versa.

Confirm `.codex/state/` is gitignored before writing anything to it. If the project's `.gitignore` does not already cover it (look for `.codex/state/` or a wider `.codex/state*` rule), tell the operator and offer to add the line — do not write state to a tracked path.

### 1. Resolve the Changelog Source

Decide what to fetch based on the second argument and the dispatch table above. Substitute `<repo>` with the table's `Upstream repo` value for the chosen tool.

| Argument shape | Action |
|-|-|
| empty | Fetch latest release via `gh release view --repo <repo> --json tagName,body,name,publishedAt`. If `gh` denies or fails, fall back to `WebFetch` on `https://github.com/<repo>/releases/latest` |
| semver-ish (`1.2.3` or `v1.2.3`) | `gh release view <tag> --repo <repo> --json ...`; fall back to WebFetch on the release URL |
| URL | `WebFetch` the URL directly |
| file path that exists | `Read` the file |
| anything else | Treat as a tag and try the `gh release view` path |

For a range, the upstream `CHANGELOG.md` (e.g. `https://raw.githubusercontent.com/<repo>/main/CHANGELOG.md`) usually carries every intervening version in one fetch — prefer it over N separate `gh release view` calls.

For `agy` specifically, the built-in `agy changelog` subcommand prints the full release-note history newest-first (every intervening version in one shot) — prefer it for ranges, and fall back to `gh release view <tag> --repo google-antigravity/antigravity-cli` or the GitHub releases page if the local binary is unavailable or stale.

Confirm to the operator: "Reviewing `<tool>` `<tag>` (published `<date>`)" before proceeding.

Stash the raw changelog body for later reference at `/tmp/<tool>-changelog-<tag>.md` (use `mktemp` shape `/tmp/<tool>-changelog-<tag>.XXXXXX.md` to avoid clobbering across parallel runs).

### 2. Parse the Changelog Into Candidate Changes

Break the changelog into discrete bullets. For each, classify it into exactly one of:

- **feature** — new flag, new setting, new hook event, new command, new MCP capability, new model support, new subagent capability
- **fix** — a bug fix in behavior we might rely on
- **breaking** — removed/renamed flag, changed default, dropped OS/runtime, tightened permission model
- **deprecation** — still works but flagged for removal
- **security** — CVE fix or hardening that affects how we wire the CLI
- **internal** — refactors, telemetry, docs-only changes → drop

Keep the original bullet wording (not a paraphrase) — it is the evidence quoted in the PR body / commit message / any decide question.

### 3. Map Project's CLI Surface (Tool-Specific)

Before judging anything, understand how **this** project touches the chosen CLI. Parallel greps are fine — this is pure read.

The grep targets vary by tool. Use the sub-procedure for the chosen token; the goal is identical (build a short **CLI Surface Map**), only the patterns differ.

#### 3a. Surface map — `claude`

- **Spawn sites** — `grep -rniE 'spawn\(|spawnSync\(|execFile\(|child_process|Popen' src/ lib/ scripts/ 2>/dev/null | grep -iE 'claude'` (widen the pattern to match the language)
- **Binary invocations in scripts** — `grep -rnE '(^|[[:space:]&;|(/`])claude([[:space:]&;|)`]|$)' scripts/ bin/ .github/ 2>/dev/null`
- **CLI flags in use** — `grep -rnhoE '"--[a-z-]+"' src/ lib/ scripts/ | sort -u`
- **`.claude/` surface** — `find .claude -type f 2>/dev/null` — settings, hooks, skills, rules, agents, slash commands, quality gates
- **Hooks** — both `.claude/hooks/` and any `hooks` block in `.claude/settings*.json`
- **MCP servers** — `.mcp.json`, `claude mcp` invocations, MCP config blocks in settings
- **Model pins** — grep for `claude-opus-`, `claude-sonnet-`, `claude-haiku-` across source and settings (distinguish CLI-harness pins from the *app's* own LLM model strings — the app calling an `anthropic/claude-*` model via an API is NOT the CLI's surface)
- **Subagent types** — `Agent tool` usage, `subagent_type` references, `.claude/agents/`
- **Skill invocations** — `grep -rn '/[a-z-]\+' .claude/skills 2>/dev/null`
- **Permission deny/allow lists** — `.claude/settings.json` and `.claude/settings.local.json`

#### 3b. Surface map — `codex`

- **Spawn sites** — `grep -rniE 'spawn\(|spawnSync\(|execFile\(|child_process|Popen' src/ lib/ scripts/ 2>/dev/null | grep -iE 'codex'`
- **Binary invocations in scripts** — `grep -rnE '(^|[[:space:]&;|(/`])codex([[:space:]&;|)`]|$)' scripts/ bin/ .github/ 2>/dev/null`
- **CLI flags in use** — `grep -rnhoE '"--[a-z-]+"' src/ lib/ scripts/ | sort -u`, plus Codex-specific config overrides: `grep -rnE '\b-c [a-zA-Z0-9_.-]+=' src/ lib/ scripts/ 2>/dev/null`
- **`.codex/` surface** — `find .codex -type f 2>/dev/null` — Codex auto-loads `AGENTS.md` but does NOT auto-load repo-local settings/rules/skills, so the mirror files (`.codex/settings.md`, `.codex/rules.md`, `.codex/skills.md`) are how this project propagates rules to Codex
- **`AGENTS.md`** — root-level Codex auto-load file. Read it. Anything the changelog changes about `AGENTS.md` semantics affects this project directly.
- **Model pins** — grep source and settings for `gpt-`, `o3`, `o4`, and any `codex-*` IDs (`grep -rnE '(gpt-|\bo3\b|\bo4\b|codex-[a-z0-9.-]+)' src/ lib/ scripts/ .codex/ 2>/dev/null`)
- **Effort / reasoning overrides** — `grep -rnE 'effort\s*=|model_reasoning' src/ lib/ scripts/ 2>/dev/null` — Codex callers commonly pin effort via `-c`; flag any release-note change to that surface
- **Sandbox / approval policy** — Codex config keys live under `[sandbox]` / `[approval_policy]`; `grep -rnE 'sandbox|approval_policy' .codex/ src/ lib/ 2>/dev/null`

#### 3c. Surface map — `agy`

Antigravity CLI (`agy`) is the successor to the retired Gemini CLI and **reuses Gemini's `~/.gemini/` config root**: user-global `settings.json` (with `model.name` and `modelConfigs.customAliases`), `GEMINI.md`, shared `config/hooks.json` + `config/mcp_config.json`, and runtime state under `~/.gemini/antigravity-cli/`. So the surface spans both project-local files and that user-global root.

- **Spawn sites** — `grep -rniE 'spawn\(|spawnSync\(|execFile\(|child_process|Popen' src/ lib/ scripts/ 2>/dev/null | grep -iE '\bagy\b'`
- **Binary invocations in scripts** — `grep -rnE '(^|[[:space:]&;|(/`])agy([[:space:]&;|)`]|$)' scripts/ bin/ .github/ 2>/dev/null`
- **CLI flags in use** — `grep -rnhoE '"--[a-z-]+"' src/ lib/ scripts/ | sort -u`. Antigravity flags worth flagging if the changelog touches them: `--print`/`-p`, `--prompt-interactive`/`-i`, `--model`, `--add-dir`, `--sandbox`, `--continue`/`-c`, `--conversation`, `--dangerously-skip-permissions`.
- **`.gemini/` surface** — `find .gemini -type f 2>/dev/null`; also inspect the user-global root `find ~/.gemini -maxdepth 2 -type f 2>/dev/null` for `settings.json`, `config/hooks.json`, `config/mcp_config.json`. Project integration may be shallow.
- **`GEMINI.md`** — root-level (or `~/.gemini/GEMINI.md`) auto-load memory file. Read it if present.
- **Model pins** — Antigravity is multi-provider, so grep for **all three** prefixes: `grep -rnE '(gemini-[a-z0-9.-]+|claude-[a-z0-9.-]+|gpt-oss[a-z0-9.-]*)' src/ lib/ scripts/ .gemini/ ~/.gemini/settings.json 2>/dev/null` (actual `--model` strings look like `gemini-3.1-pro-preview`, plus `Claude Sonnet/Opus 4.6` and `GPT-OSS 120B`). Distinguish an Antigravity model pin from the *app's* own LLM provider strings.
- **API keys / auth** — default auth is **OAuth personal** (Google account: `~/.gemini/oauth_creds.json`, `google_accounts.json`, `settings.json` → `security.auth.selectedType`). Also grep `grep -rnE 'GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_APPLICATION_CREDENTIALS|use_ai_credits' src/ lib/ scripts/ .github/ 2>/dev/null`. A breaking auth change matters only if we set one of these or rely on OAuth.
- **Hooks** — Antigravity hooks live in the shared `~/.gemini/config/hooks.json` (synchronized between the TUI and backend). Check it if a changelog bullet changes hook semantics.
- **MCP / tool config** — `~/.gemini/config/mcp_config.json` plus any project-authored `.gemini/` settings; grep the source for literal Antigravity/Gemini config key references.
- **Customizations / skills / slash commands** — Antigravity supports custom skills and system slash commands (its builtin customizations dir is auto-granted read-only). Check `.gemini/` and `~/.gemini/antigravity-cli/builtin` if the changelog touches the customizations surface.

---

After running the relevant sub-procedure, build a short internal **CLI Surface Map**: a handful of bullets naming the spawn helpers, the flag set, the hook events (where applicable), the MCP servers (where applicable), the pinned models, the permission posture. This is the lens through which every changelog bullet gets judged.

If the surface map is empty (no spawn sites, no config dir, no model pins), stop here and report "No `<tool>` integration detected in this project — nothing to review." Do NOT write state in this case.

### 4. Disposition Each Candidate Against the Surface Map

For every non-internal bullet from Step 2, assign exactly one disposition: **apply**, **decide**, **drop**, or **defer-blocked** (defined in "Why this is apply-or-drop" above).

Apply the project's **investigation protocol** ruthlessly:

- **No `file:line`, no action.** Never claim a bullet affects us without a grep-backed citation from the surface map. A bullet that reads "Fixed bug with `--mcp-config`" is only relevant if we actually pass `--mcp-config`. Memory is not evidence.
- **Steelman before applying.** For each apply/decide candidate, state the strongest reason the change does NOT affect us. If the steelman holds, it is a `drop`.
- **Distinguish the CLI's surface from the app's.** An app that calls an `anthropic/claude-*` (or `gpt-*`, `gemini-*`) model through an API is not the CLI's harness surface — a changelog bullet about the CLI's `/model` picker or `availableModels` does not touch it.
- **Bug fixes are almost always `drop`.** "Fixed X" usually just means *upgrade the CLI* — no repo change. It is only `apply`/`decide` if we built a workaround that should now be removed, or the fix changes a default we depend on.

### 5. Verify, Then Plan The Change Set (Do Not Mutate Yet)

This step turns dispositions into a concrete, reviewable plan. **Nothing is written to disk, committed, or filed before the Step 6 approval.**

For each **apply**:

1. **Verify the exact semantics before writing config.** This is non-negotiable and is what separates apply-or-drop from reckless. Before authoring any new flag, setting, permission rule, or hook field, confirm its real documented behavior — via the official docs (`WebFetch`), the upstream changelog, or a `claude-code-guide` subagent. Release-note wording is a headline, not a spec. (Real example: `Tool(param:value)` permission rules turned out to be `deny`/`ask`-only and useless for *allow*-listing — a rule shipped on the headline alone would have been broken.)
2. **Determine the scope** — does this belong in the repo (`.claude/settings.json`, a hook script, `CLAUDE.md`, `AGENTS.md`, source) or is it **user/managed-only** (e.g. Claude Code's `footerLinksRegexes`, anything the docs say cannot live in project settings)? Repo-scope → goes in the PR. User-level-only → a direct edit to `~/.claude/settings.json` (or the tool's user config), which CANNOT ship as a PR; note that explicitly.
3. **Draft the concrete diff** — the exact lines to add/change, and which file.

For each **decide**: draft the one-line question and the apply-vs-drop branches.

For each **defer-blocked**: draft the GitHub issue (Source w/ verbatim bullet, why-blocked, the concrete future trigger). This is the only issue the skill files.

### 6. Present The Plan And Get One Approval

Output in this exact shape:

```
<Tool display name> <tag> — change plan

CLI Surface Map: <3-6 bullets>

Apply (N):  → ships as <PR | user-level edit>
  - <file>: <one-line diff summary>   [verified: <how>]
Decide (N):
  - <question>   [apply: … / drop: …]
Defer-blocked (N): → GitHub issue
  - <title>   [trigger: …]
Drop (N): <count only, not a list>

Proposed: <N apply edits → 1 PR> [+ <M user-level edits>] [+ <K decide questions>] [+ <J issues>]
— or — "Nothing to ship: this release has no actionable change for our surface."
Approve? [y / n / edit]
```

Do NOT mutate anything before approval. If the operator says `edit`, walk the list: accept / drop / re-scope / merge before executing. If the honest result is "nothing to ship," say so and stop — do not invent work to look productive.

### 7. Execute, Then Persist State

Once approved, in this order:

1. **Decide questions** — ask any outstanding owner decisions (a single `AskUserQuestion` is fine), fold the answers into the apply/drop sets.
2. **Repo changes → one PR.** Never push to a protected branch. Branch off the repo's default branch (e.g. `release-followup/<tool>-<tag>`), make the edits, run the project's gates (typecheck/lint/test/format as configured — a `.claude/`-only or docs-only change may legitimately no-op them), commit with the verbatim release-note bullets in the body, push, and `gh pr create`. Capture the PR URL. Honor the project's commit/PR conventions (co-author trailer, milestone, labels).
3. **User-level-only changes** — edit `~/.claude/settings.json` (or the tool's user config) directly; there is no PR. Tell the operator exactly what changed and flag any cross-project footgun (user-global config affects every repo).
4. **defer-blocked issues** — `gh issue create` with the drafted body; assign the project's tracking milestone/labels if it uses them. Verify each landed (`gh issue list --search "created:>=<today> in:title <tag>"`).

**Then update state.** Read `.codex/state/new-release.json` (creating an empty `{}` if absent) and write back the chosen tool's entry, preserving the other tools':

```json
{ "<tool>": { "lastTag": "<tag-just-reviewed>", "reviewedAt": "<ISO 8601 timestamp>" } }
```

Write state when the review was genuinely dispositioned — a PR opened, a user-level edit made, an issue filed, OR the operator accepted an honest "nothing to ship." A cancelled review (operator said `n`) leaves state untouched so the next run still surfaces the release. If a range was reviewed in one session, write only the **most recent** tag.

### 8. Report

Final report to the operator:

- Tool and tag (or range) reviewed, published date; count of bullets scanned.
- **PR opened** — URL (clickable), one line per applied repo change.
- **User-level edits** — what changed and where, with any cross-project caveat.
- **Decisions made** — each owner choice and its outcome.
- **defer-blocked issues filed** — URL + the trigger that should re-open the work.
- **Dropped** — count only.
- State file: updated to `<tag>` (or "left untouched — review cancelled").
- If nothing shipped: say so plainly. "Mature integration, no actionable change this release" is a good outcome, not a failure.

## Decision Authority

**Do without asking:**
- Fetching any public release notes (gh, WebFetch).
- Grepping the repo to build the surface map.
- Verifying a feature's real semantics against the docs (WebFetch / `claude-code-guide`).
- Dispositioning candidates and drafting the change plan, diffs, and any issue bodies.
- Reading the state file.

**Always ask first (the single Step 6 approval covers all of these):**
- Writing any edit to disk, committing, pushing, or opening a PR.
- Editing user-level config (`~/.claude/settings.json` etc.).
- Filing a `defer-blocked` issue.
- Any `decide`-disposition owner choice.
- Closing or editing pre-existing issues, even if they overlap a finding. Surface the overlap; let the operator decide.
- Adding `.codex/state/` to `.gitignore` if it's not already there.
- Re-reviewing a tag state says was already done (the Step 0 warning).

## Anti-Patterns

- **Do not file an issue for work you could just do.** A one-line `settings.json` tweak ships as a PR or a direct edit this session — not a backlog card. Issues are reserved for `defer-blocked` (blocked on a future release), and they must name the concrete trigger.
- **There is no "monitor" or "track" bucket.** If a change isn't actionable now, it's `drop`. "Relevant but not yet" with no concrete trigger is just `drop` — revisiting happens naturally on the next release review.
- **Do not write config on the release-note headline alone.** Verify the exact documented semantics first (Step 5.1). A plausible-looking but wrong permission/hook/setting rule is worse than none.
- **Do not pad a quiet release.** "Nothing to ship" is the correct, common output for a mature integration. Never invent applies, decides, or issues to look busy.
- **Do not paraphrase release notes.** Quote the bullet verbatim in the PR body / commit / issue / decide question — paraphrasing loses the wording that makes the change re-checkable later.
- **Do not mark a bullet actionable without a `file:line` citation** from the surface map. Memory is not evidence.
- **Do not push to a protected branch or skip the project's gates.** Repo changes go through a branch + PR with gates green, per the project's conventions.
- **Do not invent labels or milestones.** Reuse what the repo already has; otherwise omit.
- **Do not cross-pollinate surface maps.** A `claude` review never greps for `codex` or `agy` patterns and vice versa. The state file is per-tool for the same reason.
- **Do not commit `.codex/state/`.** It's per-workstation review history. If `.gitignore` doesn't cover it, fix that before writing the file.

$ARGUMENTS
