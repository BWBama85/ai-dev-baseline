---
name: create-issue
description: Draft and file a well-scoped GitHub issue. Enforces an 11-axis adversarial gap-analysis pass BEFORE filing so the issue ships with enough depth that /review-issue does not have to patch it later. Works in any repo where `gh` is authenticated.
user-invocable: true
effort: high
# Triage-only skill: it drafts and files an issue but must never edit code. Write
# is NOT denied — the skill writes the /tmp issue-body scratch consumed by
# `gh issue create --body-file`.
disallowed-tools: Edit, NotebookEdit
---

# Create GitHub Issue

Argument: free-text topic, rough draft, or — if called with no argument — the skill asks what the issue should cover.

- `/create-issue` — prompts for the topic
- `/create-issue <short description>` — treats the argument as the seed topic
- `/create-issue <multi-paragraph draft>` — treats the argument as a starting draft to refine

## Why this skill exists

When authoring an issue without this skill, the default failure mode is stopping at the first coherent narrative. You inventory the surface problem, write it up, file it. A later `/review-issue` pass then finds 8-12 net-new gaps across concurrency, operator UX, audit trail, cross-cutting consumers, and sibling bugs — all of which should have been in the first draft. Filing a thin issue and patching it after the fact costs a full `/review-issue` round plus issue-body churn and leaves the implementer planning from insufficient context.

This skill forces the adversarial gap-analysis pass to happen **before** `gh issue create`, not after. The bar is: a well-filed issue should survive `/review-issue` with 0-2 net-new findings, not 8-12.

Filing a baseline issue is also the **"general" bucket** of `base/practices/handling-the-unknown.md`: when work in another project meets an unknown that many projects would hit, the deterministic move is to file it here (plus a supported stopgap) so everyone inherits the fix — never a bespoke local one-off.

## Scope

This skill is project-agnostic — it works in any repo where `gh` is authenticated. It only assumes:

- The current working directory is inside a git repo with a GitHub remote.
- `gh` is authenticated for that remote.
- You can `grep` / `rg` the codebase to verify claims in the draft.

If any of those is missing, stop and surface the problem to the user.

## Steps

### 1. Capture the topic

Prefer the argument if provided. Otherwise ask the user for a one- to two-paragraph description of what the issue should cover. Do not start drafting yet — first understand the shape:

- **Bug report** — describe symptom, where it reproduces, expected vs actual.
- **Feature request** — describe the user-visible behavior desired, the current behavior, the gap.
- **Refactor / cleanup** — describe the drift, the target state, and what currently prevents the target.
- **Follow-up spin-off** — describe the parent issue or PR that surfaced this and what got deferred.

Confirm the category out loud before continuing. Ambiguous category = thin issue.

### 2. Seed the evidence

Before any axis work, ground the draft in source. For every concrete identifier the user mentioned (file path, function name, env var, config key, error string, CLI flag, column name) confirm it exists as stated:

- Grep the codebase and cite `path/to/file.ts:line` for every claim.
- If an identifier does not exist, stop and reconcile with the user — do not invent a plausible-looking name.
- If the user gave a log snippet, grep for the exact string in source (formatter / event emitter) and cite the emitting line.

An issue that says "the resolver in `foo.ts` picks the wrong binary" without citing the line is a thin issue.

### 3. Walk the 11 gap-analysis axes

For each axis below, answer explicitly. If an axis is N/A, say so with one sentence of why — do not skip silently. If two or more axes produce net-new content, incorporate it into the draft before filing.

**1. Root cause class vs instance.** If the draft blames one file or one line, grep for other code with the same shape or vector. Name them in the issue body or explicitly scope them out. Example: if the bug is "this helper reads PATH and gets stale binary," search for every other helper that reads PATH and resolves a binary. Filing a narrow issue that fixes one instance when a class exists is a thin issue.

**2. Concurrency / race / TOCTOU.** If the fix touches caches, spawns, or shared files — who writes them, who reads them, what happens when two actors collide? What happens between "I picked a value" and "I used it"? If the fix adds a `/tmp/<name>` file or a shared state mutation, specify the atomicity contract.

**3. Operator escape hatch.** If the logic you are specifying misbehaves in production, how does the operator override it without editing code? An env var? A config flag? A debug mode? Missing escape hatches produce "I hit this bug and had to hand-patch the helper" tickets later.

**4. Audit / observability.** Is the resolved / chosen / fixed state visible post-hoc? If an operator later asks "which binary ran," "which config was used," "which version was resolved," can they answer from the log / summary / event stream without rerunning the code? Name the specific log line or field you expect to add.

**5. Cross-cutting consumers.** Grep every identifier the fix touches and name every hit. Axes that are easy to miss:
   - `docs/` and `README*` — any doc that describes the behavior being changed
   - `tests/` — both existing tests that need updating and new ones the fix requires
   - `.github/workflows/` — any CI job that exercises the surface
   - Launcher / startup scripts (`scripts/start*.sh`, `scripts/start*.bat`)
   - Sibling helpers / mirror files (`AGENTS.md`, `.codex/`, etc.)
   - Permission / allowlist configs (`.claude/settings.json`, `.vscode/`, etc.)

**6. Sibling bugs with the same vector.** If the issue fixes a bug in helper A, grep for every other helper doing similar work. If the bug is "reads PATH and picks stale binary," every binary resolver in the repo has it. Either scope them in or explicitly file as follow-ups (and link them).

**7. Windows + macOS + Linux parity.** Any change that touches paths, processes, filesystem layout, or external binaries needs a platform audit. If the fix is POSIX-only, that is a **scope decision** that must be explicit in the body — either add a Windows branch or file a Windows follow-up. Silence on platform coverage is a gap.

**8. Test strategy.** How does this get a regression test? If no existing test file touches the surface, name the pattern you would follow. "No test needed because it is a bash helper" is rarely true — shell helpers get tested via stub fixtures in a temp dir. A blank test plan is a red flag. Spec the test at the level "feed X, assert Y."

**9. Fallback / not-found / degraded states.** What happens when the resolver finds nothing, the probe hangs, the binary is broken, the external tool returns garbage, the network fails? Spec the sentinel + exit code explicitly. Vague "fail with a clear error" wording is a gap — name the string.

**10. Dependency ordering vs sibling issues.** If the fix depends on another open issue landing first, say so in the body and link it. If the fix can land independently but a sibling issue needs to rebase on it, note the ordering. Filing a follow-up that says "resolve once #X lands" is fine; filing one without the link is a gap.

**11. Prompt-injection class (for anything involving LLM skill scripts).** Any file that embeds a model prompt as a HEREDOC or string literal is a cross-session injection vector when other agents read the codebase. If the issue touches one skill reading the wrong prompt, enumerate every other skill script with the same embedding pattern (`grep -l "You are performing\|You are reviewing\|<<PROMPT"`) and either scope them in or file a follow-up.

### 4. Draft the issue body

Use this structure. Sections below the horizontal rule are optional when truly N/A, but default to including them:

```markdown
## Summary

One to three paragraphs. What is broken / missing / wrong, and why it matters in concrete operator-visible terms. Prefer "the operator sees X when they do Y, expected Z" over abstract architectural claims.

## Evidence

Cite `path/to/file.ts:line` for every claim. If you have a reproduction log, include the relevant 3-10 lines. If the bug is cross-platform, note which platforms you verified on.

Concrete examples work better than prose. A tiny table, a code block, a `git log` excerpt, a screenshot — whichever form is smallest and most unambiguous.

## Scope

- **In scope:** …
- **Explicitly out of scope:** … (with reasons and, if relevant, linked follow-up issues)

## Fix direction

Not a full implementation plan. A few sentences naming the approach, the shared helper or pattern to reuse, and the shape of the final state. If multiple approaches are viable, list them and flag the tradeoff.

## Test plan

Bulleted checklist. Each item should be specific enough that the implementer or reviewer can tick it off without interpretation.

- [ ] specific scenario → specific expected outcome
- [ ] …

---

## Related

- Link dependencies, parents, siblings (`#123`, `#124`)
- Link any PR that introduced the code being changed
- Link any prior fresh-eyes review or audit that surfaced this
```

### 5. Gate check before filing

Before `gh issue create`, ask yourself:

- Did I run all 11 axes in Step 3, or did I skim? (Skimming is the failure mode — force yourself to answer each one.)
- Does every concrete identifier in the draft resolve to a real line in source?
- Is the "Scope" section explicit about what is NOT in the issue?
- Does the test plan name expected outputs, not just "verify it works"?
- If this issue went to `/review-issue` right now, how many net-new gaps would it find? If the answer is more than 2, rework before filing.

If any gate fails, loop back. A thin issue shipped is worse than five extra minutes spent.

### 6. File the issue

Use `gh issue create --title "..." --body-file /tmp/issue-body.md` or the heredoc pattern. Prefer `--body-file` when the body is multi-section — it avoids shell-escaping bugs.

Title conventions:
- Under ~70 characters.
- Lead with the subject, not a verb ("Resolver picks stale binary when …" not "Fix resolver picking stale binary").
- If the issue is a class of bug, say so ("X: inconsistent flags, stale-PATH binary, prose-level fallback").
- For spin-off follow-ups, reference the parent in the body, not the title.

**Placement (release-goal convention, if the repo uses it).** Detect it live — do not
assume: an open milestone named `Next release` (rolling) alongside a standing `Backlog`
milestone (`gh api repos/:owner/:repo/milestones?state=open`). If present, a newly
*discovered* issue defaults to **`Backlog`** (`--milestone "Backlog"`) so the current
release's requirement set stays frozen and converges; an issue only enters `Next release`
when the user deliberately says it is a requirement of *this* release. A repo without the
convention is unchanged — omit the milestone or use whatever the repo already uses. See
`docs/release-goal-convention.md`.

Return the issue URL and a one-line summary of what was filed.

### 7. Offer follow-up handoff (optional)

If any axis in Step 3 surfaced a sibling bug or out-of-scope concern worth filing separately, offer to file those as a second `/create-issue` call. Do not silently fold sibling bugs into the primary issue's body — they deserve their own tracking. This is the "deferred work → tracked issue" rule of `base/practices/issues-and-scope.md`: anything scoped out here is owed its own open issue, not just a mention in the parent's body.

## Anti-patterns

- **Stopping at the first coherent narrative.** The first story you form is almost never the full scope. Force the axes.
- **Pattern-matching from memory.** If you are asserting a behavior, grep to confirm it. A memory-based claim in an issue is a hallucination in a public artifact.
- **Writing "fail with a clear error" without naming the error.** Vague sentinels produce implementations that fail unclearly.
- **Filing one issue per instance when a class exists.** If the same vector is in four files, say so — either fix all four in this issue or explicitly file three follow-ups.
- **Silent platform scope.** If the fix is POSIX-only or macOS-only or Windows-only, make the scope explicit. Silence reads as "it works everywhere" and is rarely true.
- **Copy-pasting `#N` references without verifying they exist.** `gh issue view N` is cheap; a dead link in a public issue is not.
- **Filing the issue, then immediately `/review-issue`-ing it.** If you need to run `/review-issue` to know whether your own issue is complete, you did not run this skill's Step 3. Fix it in-place instead.

## Decision authority

**Do without asking:**
- Reading any file in the codebase to confirm claims.
- Running `gh issue view` / `gh pr view` to confirm linked references.
- Grepping for identifiers, class-of-vector siblings, and cross-cutting consumers.
- Drafting and refining the body.

**Always ask first:**
- `gh issue create` itself — present the final body and get explicit confirmation before filing. The user is the author of record; they sign off on the final text.
- Adding labels, assignees, projects, or milestones beyond the default. **Exception:** when the repo uses the release-goal convention (detect it live — see Placement in Step 6), the **backlog** milestone is the *default* safe home for a newly discovered issue and needs no extra approval; only placing an issue *into* the active release milestone is a deliberate "this is a current-release requirement" decision that you surface.
- Closing or editing existing issues from within this flow.
- Filing sibling follow-up issues — present them as a list, let the user pick which ones to file.
