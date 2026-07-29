# Decision log

Per `base/practices/handling-the-unknown.md`: one entry per unknown the baseline
didn't already model, so any residual divergence stays visible and auditable.

## D1 — selfcheck.sh as this repo's in-loop `test` gate
- date:      2026-07-22
- category:  project-delta
- unknown:   This repo has no standard ecosystem, so `project-gates.sh` auto-detects no
             gates — its in-loop gate + the precommit Stop-hook were no-ops, leaving
             `scripts/selfcheck.sh` enforced only at CI (#7).
- decision:  Wire `scripts/selfcheck.sh` as the `test` gate in the repo-root `agents.toml`
             `[gates]`, and declare the three toolchain-less axes (typecheck/lint/format)
             N/A via `[gates.state]`.
- placement: `agents.toml [gates]` / `[gates.state]` — the prescribed home for a
             project-specific gate command (handling-the-unknown table).
- reason:    selfcheck IS this repo's real quality gate; the gate model's whole point is to
             let a repo name its own. `[gates] test = "…"` is the supported surface.
- operating note: selfcheck is a **post-commit (pre-push) mirror** — its build-drift step
             compares the freshly-built tree against HEAD (committed), exactly as CI does.
             The precommit Stop-hook runs at *turn-end*, after commits, so it sees a clean
             tree; and `/implement-issue`'s invariant forces a PR (all commits landed) before
             the turn can end. Commit source + generated output together (Golden Rule #1) and
             the gate is green. Running selfcheck against an uncommitted rebuild (a manual
             mid-edit `project-gates.sh run`) will report the generated files as differing
             from HEAD — expected for a pre-push mirror, not a defect. selfcheck's drift logic
             was intentionally left unchanged (a working-tree-relative rewrite is out of #7's
             scope and would weaken the CI-accurate HEAD comparison).
- baseline-issue: n/a

## D2 — canonical home for the /roadmap artifact
- date:      2026-07-22
- category:  project-delta
- unknown:   #39 named two candidate homes ("a pinned issue labeled `roadmap`, or a
             `ROADMAP.md`") without precedence; the existing pinned roadmap issue (#31)
             carries the `documentation` label, not `roadmap`, so a strict locator would
             bootstrap a duplicate.
- decision:  One home only — the single open issue bearing the `roadmap` label. `ROADMAP.md`
             is not used (a tracked file needs a branch+PR every run, conflicting with the
             post-`/cleanup`/`/clear` loop). The skill *adopts* a pre-existing pinned roadmap
             issue (by marker/title) instead of duplicating it; >1 labeled roadmap is an
             explicit ambiguous-stop.
- placement: `base/workflows/roadmap.md` (the skill's own contract) documents the home,
             locator precedence, adoption path, and split-brain behavior.
- reason:    Determinism requires exactly one home + one locator; adoption handles the #31
             migration without a duplicate.
- baseline-issue: n/a

## D3 — Codex/Antigravity workflow render targets the agent-skills SKILL.md surface
- date:      2026-07-23
- category:  project-delta
- unknown:   Issues #12/#13 named the render targets as "Codex custom prompts
             (`~/.codex/prompts/<name>.md`)" and "the Gemini/Antigravity command surface",
             but instructed to "verify each CLI's current surface first." Verification
             against the installed CLIs contradicted the issue text: Codex 0.145.0 has NO
             `~/.codex/prompts/` (custom prompts deprecated in favor of skills; broke in
             codex-cli 0.117), and Antigravity's global command surface is skills, not a
             flat command file.
- decision:  Render every workflow into the **agent-skills `SKILL.md` folder standard** for
             all three agents (Claude already used it). Codex → `~/.codex/skills/<name>/`;
             Antigravity → `~/.gemini/config/skills/<name>/` (`~/.gemini/config/` is agy's
             global customization root, confirmed in agy's own bundled `agy-customizations`
             docs). One generic `render_agent_skill` in `scripts/build.sh` serves all three,
             parameterised by placeholder map + frontmatter mode + output tree. Codex/Gemini
             frontmatter is synthesised to `name` + `description` (Claude-only keys dropped);
             Claude stays verbatim (byte-for-byte, proven by build-drift).
- placement: `scripts/build.sh` (`render_agent_skill`), `scripts/lib/common.sh`
             (`adb_agent_manifest` install locations), and the agent READMEs +
             `base/workflows/README.md` document the surfaces.
- reason:    The issue explicitly told us to verify + adapt to the current surface; the live
             binaries make skills the only working target. The convergence on one SKILL.md
             standard also collapses two bespoke renderers into one.
- baseline-issue: n/a

## D4 — install the shared gate runner for Codex/Gemini so {{GATE_RUNNER}} resolves
- date:      2026-07-23
- category:  project-delta
- unknown:   The neutral `{{GATE_RUNNER}}` token maps to `bash "$HOME/.<agent>/scripts/lib/
             project-gates.sh"`, but pre-#12/#13 only Claude installed `scripts/lib/`. A
             Codex/Gemini render of a gate step would point at a script that isn't there.
- decision:  Extend `adb_agent_manifest` so the codex + gemini branches also link
             `scripts/lib/` → `~/.codex/scripts/lib/` and `~/.gemini/scripts/lib/`. This is
             the agent-neutral gate *runner* only — NOT the Claude Stop-hook *enforcement*
             (that per-agent equivalent stays #14). The remaining Claude-flavored body
             references (Stop-hook gating, `/code-review`) render verbatim with a generated
             caveat comment; full cross-agent neutralization is a filed follow-up.
- placement: `scripts/lib/common.sh` (`adb_agent_manifest`); the runner install is verified
             by selfcheck's install dry-run + CI's install-dry-run job.
- reason:    A rendered workflow's gate step must resolve to a real command; the runner is
             already agent-neutral and single-sourced, so mirroring the Claude link is the
             honest, DRY choice (owner-confirmed).
- baseline-issue: n/a

## D5 — release-readiness activation is an explicit artifact marker, not milestone-name detection
- date:      2026-07-24
- category:  project-delta
- unknown:   #71 makes `/roadmap` compute release readiness from "the active release milestone."
             How does the agent-neutral skill KNOW a repo opts in without either hardcoding the
             name `Next release` (assumption #27 exists to remove) or silently changing output for
             any repo that merely happens to have such a milestone?
- decision:  Opt-in is a single explicit marker on the roadmap artifact,
             `<!-- release-milestone: NAME -->`, resolved live to exactly one OPEN milestone.
             Absent/empty → classic backlog-wide mode, byte-identical. Present-but-unresolvable
             (0 or >1) → STOP and surface, never silently classic. This mirrors the existing
             `destination-label` opt-in exactly (bootstrap never writes it). The readiness
             fallback keys off the `release-blocker` LABEL existing (a `gh api …/labels/…` 404
             probe), never the live open-count, so closing the last blocker never flips the bar.
- placement: `base/workflows/roadmap.md` ("Release-readiness mode" section + the artifact
             schema markers); the setup helper is `scripts/lib/release-convention.sh` invoked as
             `baseline release …` (dispatched from `bin/baseline` like `skill-compose`); the
             module is documented in `docs/release-goal-convention.md`.
- reason:    An explicit marker is the only safe opt-in that keeps classic behavior byte-identical
             and honors the repo's own "never silently enable on a coincidental label/milestone"
             law (the destination-label precedent). Both the gap-analysis and the adversarial
             fallback flagged name-detection as a backward-compat violation.
- baseline-issue: n/a

## D6 — DEVIATION: the release-readiness "configurable last mile" ships docs-only (no auto-cut executor)
- date:          2026-07-24
- category:      deviation
- baseline-rule: issues-and-scope.md — "Out-of-scope work always becomes a tracked issue"; and
                 #71's acceptance "Configurable last mile: … documented opt-in auto-cut."
- conflict:      #71 asks for a configurable auto-cut, but `/roadmap` carries `disallowed-tools:
                 Edit` and the contract "it never implements / never runs a command." A safe
                 auto-cut executor needs a driver/hook, live revalidation, one-shot idempotency, a
                 failure circuit-breaker, and a deploy/charge guard — none of which can live in a
                 skill that never executes.
- scope:         `base/workflows/roadmap.md` + `docs/release-goal-convention.md` document the
                 opt-in, off-by-default auto-cut and name its prescribed home (the #14/#25 hooks/
                 driver layer). The default emit-only path IS the shipped last mile.
- reason:        Acceptance says "documented opt-in auto-cut," which this satisfies; the executor
                 mechanism is filed as a tracked follow-up (per issues-and-scope) rather than
                 bolted onto a never-execute skill.

## D7 — release execution stays project-owned; the baseline ships no `/release`
- date:      2026-07-24
- category:  project-delta
- unknown:   #3 asked the framework to decide between shipping a *generic* `release` workflow
             (bump a version, regenerate a changelog, tag, hand off to deploy) and documenting
             `release` as an explicitly project-owned role. `base/roles.md` already named the
             role, and `/roadmap` already emits `Next: /release`, but nothing said which of the
             two the baseline was committing to — so the role read as "unimplemented yet."
- decision:  Project-owned, permanently. The baseline NAMES `release` and resolves it like any
             other role, and ships no `/release` workflow. A four-project sweep found four
             mutually incompatible schemes (SemVer + git-cliff + milestone roll; SemVer + GHCR
             image + cosign; CalVer `YYYY.MM.patch` with no changelog; a WP-plugin zip via
             `build.sh` + `gh release create`), so a "skeleton with extension points" would be
             wrong for three of four — and wrong under a permanent published tag. Three things
             ship instead of a skill: (1) the decision, stated on every surface a user lands on;
             (2) the contract that `[roles].release` names an EXECUTOR and is inert until a
             project's own skill resolves it (`role-dispatch.sh resolve release`), since a
             silently-ignored manifest entry was the likeliest misread; (3) a lint pinning the
             negative invariant. The `/new-release` name collision reported on #3 is fixed with
             a clarifying scope note, NOT a rename — renaming a shipped skill is a breaking
             migration (installed symlink targets, project `overrides.md` anchors, per-project
             state files, orphan-render detection), so the rename decision is tracked separately
             as #82 (which also depends on #52, the untested renamed-skill prune/relink path).
- placement: `base/roles.md` (role model) + `docs/roles-and-agents.md` (user guide) + `README.md`
             (skill table) + `templates/agents.toml` (manifest comment); the disambiguation note
             in `base/workflows/new-release.md` (rendered to all three agents); the guard in
             `scripts/check-release-role.sh`, wired into `scripts/selfcheck.sh` and CI.
- reason:    "General over specific" (`docs/design-principles.md`) argues FOR extraction only
             when a general form exists; here the sweep proves it does not, so the honest
             baseline contribution is the role + the resolution contract, not a skeleton.
             Recorded as a decision rather than a code comment because the tempting future
             change ("just add a small generic /release") looks like a feature, not a reversal —
             the lint makes reversing it deliberate instead of incidental.
- baseline-issue: n/a (this repo IS the baseline; #3 is the tracking issue)

## D8 — milestone rollover crosses back over the D7 line into `baseline release roll`
- date:      2026-07-25
- category:  project-delta
- unknown:   D7 (#3) put release execution permanently in the project's hands, and the shipped
             docs then assigned *milestone rollover* to that project-owned `/release` too
             (`docs/release-goal-convention.md`, `docs/roles-and-agents.md`). #74 asked where the
             rollover contract actually belongs. The baseline had no rule for "part of a
             project-owned job that is nonetheless identical everywhere."
- decision:  Rollover moves OUT of the project-owned half and ships as
             `baseline release roll --version X [--dry-run] [--force]`, a third subcommand of the
             existing `release-convention.sh`. D7 holds for *cutting*: the four-project sweep found
             four incompatible schemes (SemVer+git-cliff, SemVer+GHCR+cosign, CalVer, WP-plugin
             zip), so no generic form exists. Rolling is the opposite — it has exactly ONE correct
             shape because it operates on milestones `init` already creates, and the shape is not
             obvious: the disposition of leftover non-blockers must be `Backlog`, because a
             milestone is "armed" at >=1 issue open OR closed, so rolling them forward arms the
             fresh milestone with zero open blockers and the readiness predicate returns `met`
             immediately, re-emitting a cut for an empty release. Every project re-deriving that
             would get it wrong, and getting it wrong strands the loop. The boundary is stated in
             the helper and pinned by a new group 5 in `scripts/check-release-role.sh`: roll does
             no version bump, changelog, tag, package, publish, or deploy.
- placement: `scripts/lib/release-convention.sh` (the `roll` subcommand + its stated boundary);
             `scripts/check-release-role.sh` group 5 (the pin); `docs/release-goal-convention.md`
             ("Rolling over on the cut"); `docs/roles-and-agents.md` (step 4 of "what you do
             instead", and the sweep table's rollover column); `base/workflows/roadmap.md` (the
             met-emission now names the roll); `scripts/check-release-convention.sh` (offline
             ordering + refusal coverage).
- reason:    "General over specific" (`docs/design-principles.md`) says extract only when a general
             form exists. D7 applied that rule to conclude one does NOT exist for cutting; the same
             rule applied to rolling concludes one DOES. Recording it as its own entry rather than
             amending D7 keeps both readable: D7 is "no generic cutter," D8 is "rollover was never
             part of the cutter." The tempting future change is the mirror image of D7's — here it
             is `roll` growing a `--tag` flag "while we're already in the release milestone" — so
             the pin guards that direction specifically.
- baseline-issue: n/a (this repo IS the baseline; #74 is the tracking issue)

## D9 — the baseline mutates GitHub repo settings; and the three defaults it picks
- date:      2026-07-25
- category:  project-delta
- unknown:   #87 asks the baseline to hand PR merges to GitHub — which means WRITING repo
             settings (branch protection + `allow_auto_merge`) out-of-band. Nothing in the
             baseline had ever mutated a repo's GitHub configuration; every prior helper wrote
             only issues, milestones, labels, and files. It also forced three security-relevant
             defaults the baseline had no position on: `strict`, `enforce_admins`, and the
             required approving review count.
- decision:  Ship it as `baseline repo` (`scripts/lib/repo-settings.sh`), bounded to exactly two
             settings, with these defaults:
             1. **`strict` OFF.** "Require branches to be up to date" makes any commit on the
                default branch un-arm an already-armed PR, and GitHub's auto-update behavior for
                auto-merge PRs is not a documented guarantee (merge queue is the supported
                answer). On, the realistic outcome is an auto-merge that silently never fires —
                reintroducing the very touchpoint #87 removes. `--strict` opts in.
             2. **`enforce_admins` OFF.** Turning it on removes the owner's break-glass. With it
                off the AUTOMATED path is still fully gated (`gh pr merge --auto` cannot fire on
                red) while a human keeps an explicit override. `--enforce-admins` opts in. This
                is why #87's acceptance criterion "a PR with failing CI CANNOT merge" holds for
                the automated path but NOT against a deliberate admin override — recorded here
                rather than silently reinterpreted.
             3. **Required approving reviews stays 0** when standing protection up. Requiring a
                PR enforces the feature-branch rule; inventing an approval requirement would
                block a solo-maintainer loop outright.
             Two further boundaries: the checks write ALWAYS precedes the auto-merge write (a
             failed checks write aborts before auto-merge is touched), and the required contexts
             are DISCOVERED from `.github/workflows`, never hardcoded.
- placement: `scripts/lib/repo-settings.sh` (the library + its stated boundary); `bin/baseline`
             (the `repo` dispatch); `base/workflows/implement-issue.md` step 10 (the guarded
             arm); `docs/repo-settings.md` (the operator contract); `scripts/check-repo-settings.sh`
             + the `repo-settings` CI job + `scripts/selfcheck.sh` (the offline pins).
- reason:    Writing repo settings sits on the D7 line ("release execution stays project-owned"),
             so it needs the same test D8 passed: does ONE correct shape exist? For merge gating
             it does — "require the checks your CI actually reports, then let GitHub merge" is
             not project-specific the way cutting a release is. The defaults all resolve the same
             way: prefer the choice that cannot silently stop the loop, and make the stricter
             choice an explicit flag rather than a surprise. What this file must never grow is
             the mirror of D8's temptation — a `--merge` or `--deploy` flag "while we are already
             holding the repo's settings."
- baseline-issue: n/a (this repo IS the baseline; #87 is the tracking issue)

## D10 — the global-only `[updates]` config surface, and auto-update as the default
- date:      2026-07-27
- category:  general
- unknown:   #36's remaining half is a Claude `SessionStart` hook that keeps the install-source
             clone current. Two things the baseline did not model: (a) where a **user-level,
             global** behavior toggle lives — every existing override surface (`agents.toml
             [roles]`/`[gates]`, the repo root doc, `.claude/scripts/precommit-gate.sh`, a
             project-scoped skill) is **per-project**, and a repo you happen to open must not
             decide whether your global tooling updates itself; and (b) whether the hook should
             auto-update or merely notify.
- decision:  1. **A new global-only table `[updates]` with one key, `session_start = "auto" |
                "notify" | "off"`,** read from `~/.config/ai-dev-baseline/agents.toml` and
                **nowhere else**. `ADB_SESSION_UPDATE` overrides it for one run.
             2. **`auto` is the default** — the owner's recommendation on #36: a session begins
                from a clean slate, which is the safe moment to change tooling. `notify` is a
                first-class alternative for anyone who wants to review each pull.
             3. The hook acts **only** on `source: startup`, and **never** on the clone the
                session itself is working in.
- placement: `templates/agents.toml` (the documented surface, marked GLOBAL ONLY);
             `agents/claude/scripts/session-currency.sh` (the only reader);
             `docs/installation.md` → *Automatic currency (SessionStart)* (the operator contract);
             `scripts/check-session-currency.sh` + the `session-currency` CI job + `selfcheck.sh`.
- reason:    Adding a table to the existing global manifest reuses the file the installer already
             writes and the TOML reader already in `common.sh`, so it invents no new config
             format and no new file — the cheapest legal home. It is marked GLOBAL ONLY because
             the per-project reading would be actively wrong: the hook runs before any project
             context is meaningful, and honoring a project's copy would let an arbitrary repo
             disable (or enable) a machine-wide updater. Defaulting to `auto` accepts a real
             consequence, recorded here rather than buried: **each new session may fetch and then
             execute the newly pulled `install.sh`.** That is the same trust already placed in
             the clone the whole toolchain is symlinked from, but it is now exercised without a
             human in the loop — which is why `notify`/`off` exist, why the hook refuses every
             unsafe clone state, and why it never touches the clone you are working in.
- baseline-issue: n/a (this repo IS the baseline; #36 is the tracking issue)

## D11 — currency gets a second trigger in `/cleanup`, and `session_start` keeps its name
- date:      2026-07-27
- category:  general
- unknown:   D10 bound install currency to ONE trigger — a Claude `SessionStart` hook on
             `source: startup`, justified there because "a session begins from a clean slate,
             which is the safe moment to change tooling." #139 is the hole that reasoning left:
             the baseline's own documented loop is `/implement-issue → merge → /cleanup → /clear
             → /roadmap`, and `/clear` is **deliberately excluded** from the matcher. So the loop
             never re-checks, while staleness *begins* at the merge. Three things the baseline did
             not model: (a) where a SECOND, non-session trigger belongs; (b) whether a key named
             `session_start` may govern a trigger that is not a session start; (c) how a
             deliberate check should interact with a rate limit designed for an unattended one.
- decision:  1. **`/cleanup`'s last step is the second trigger.** It runs immediately after a
                merge (when the install goes stale) and immediately before the `/clear` the hook
                skips. Being agent-neutral, it is also the only currency Codex and Gemini get —
                a Claude hook could never give them any.
             2. **The shared policy moves to `scripts/lib/currency-lib.sh`**, leaving
                `session-currency.sh` a thin harness adapter. `check` returns a machine record
                `<outcome><TAB><message>`; **presentation stays with the caller**, because the two
                triggers legitimately disagree — the unattended hook must not nag about a peer
                update or a missing network, while `/cleanup` must report both, having been asked.
             3. **`[updates] session_start` keeps its name and now governs BOTH triggers; `off`
                disables both.** The name is wrong and kept anyway: a key that silently stopped
                applying would re-enable an updater its owner had switched off. The neutral
                rename is tracked as #140 rather than shipped as a silent semantic change.
             4. **The deliberate trigger ignores the rate-limit interval** while still refreshing
                the shared stamp. The stamp records the last *attempt* and cannot distinguish
                "startup just checked, nothing changed" from "startup checked, then a merge
                landed" — so honoring it in `/cleanup` would suppress the check at the exact
                moment #139 exists to cover.
- placement: `scripts/lib/currency-lib.sh` (the one reader of the key, and the one policy);
             `base/workflows/cleanup.md` step 7 (the trigger, rendered for all three agents);
             `agents/claude/scripts/session-currency.sh` (harness adapter only);
             `templates/agents.toml` + `docs/installation.md` (the operator contract);
             `scripts/check-cleanup.sh` + `scripts/check-session-currency.sh` + the
             `session-start-config` fact in `scripts/check-fact-drift.sh`.
- reason:    D10's premise was that a clean session boundary is the safe moment to swap tooling.
             That is still true, but it is not the only safe moment, and treating it as the only
             one is what produced a two-commit-stale predicate deciding a release board. The end
             of `/cleanup` is a comparably clean boundary — the sweep is finished, the report is
             already composed, and the operator is between tasks — and it is the boundary that
             actually follows a merge. It is deliberately **not** a gate: it cannot fail the
             sweep, it is bounded by a wall-clock backstop (`adb_run_bounded`, shared with
             role-dispatch rather than copied), and it refuses the install-source clone when that
             is what is being swept. The residual D10 named — `auto` executes a freshly pulled
             `install.sh` — is now exercised from a second place, which is why #120 (the
             auto-update trust boundary) matters more than it did, and why the ordering
             constraint is explicit: the report is composed BEFORE the update, so no run reports
             itself through a library that was swapped underneath it.
- baseline-issue: n/a (this repo IS the baseline; #139 is the tracking issue)

## D12 — auto-merge waits for a declared reviewer, and the declaration is `[reviewers] bots`
- date:      2026-07-27
- category:  general
- unknown:   The baseline had no way to express "this repo is reviewed by an async bot, so do not
             hand the merge to GitHub until that reviewer has spoken." `automerge-ok` answers
             "will the CHECKS gate this?"; nothing answered "has REVIEW happened?", and GitHub
             cannot answer it either — auto-merge fires when required status checks pass, a bot
             reviewer is not a check, and `required_conversation_resolution` only blocks on
             threads that already exist. PR #133 merged 29s after opening and 6m18s before its
             reviewer posted five real bugs.
- decision:  Four choices, each of which could have gone the other way:
             1. **A separate module, `scripts/lib/pr-review.sh`** — not a new `repo-settings.sh`
                subcommand. That file states its own boundary ("repo *settings* bookkeeping … it
                does not merge, review, tag, release, or deploy"); review state is per-PR, so
                adding it there would have broken the contract rather than honored it. Step 10
                composes the two guards; neither grows into the other's question.
             2. **Reuse `[reviewers] bots` rather than invent a key**, read through a second
                reader, `bots --declared`, that reads it as a TRI-STATE WITH NO DEFAULT. The two
                consumers need opposite answers for "unset" and both are right: a permissive
                default is harmless when choosing which threads to auto-resolve, and is exactly
                wrong as a merge gate. Declared → wait; `[]` → no reviewer, keep unattended
                arming; undeclared → unknowable, fail closed.
             3. **Declaration, never inference.** Scanning PR history for past bot reviews was
                rejected: a new repo, a bounded lookback, or a read failure all yield "no bot
                found" while a reviewer is configured — authorizing an arm on absence of
                evidence, in the one direction this must never be wrong. A disabled bot leaves
                stale evidence forever. Which reviewers a repo has is configuration.
             4. **Anchor to the head COMMIT, and arm with `--match-head-commit`.** A review of an
                earlier push is not a review of what is about to merge (observed live on PR #145,
                where the bot reviewed b302fa0e and three commits landed after it). Re-reading
                before arming still leaves a race, so the witnessed SHA is passed to the merge
                command and GitHub rejects the arm if the head moved.
             `17` (undeclared) is deliberately distinct from `20` (unreadable): both refuse, but
             the operator action differs — declare your reviewers vs. retry — and one code for
             two fixes sends people to the wrong one.
- placement: `scripts/lib/pr-review.sh` (the guard); `scripts/lib/role-dispatch.sh`
             (`bots --declared`, in the module that owns the manifest); `base/workflows/
             implement-issue.md` step 10/11 (rendered for all three agents);
             `{{PR_REVIEW_LIB}}` in `scripts/build.sh` + `base/workflows/README.md`;
             `templates/agents.toml` + `docs/roles-and-agents.md` + `docs/repo-settings.md` +
             `base/roles.md` (the operator contract); `scripts/check-pr-review.sh` +
             `scripts/check-role-dispatch.sh` (coverage); this repo's own `agents.toml` declares
             `bots = ["chatgpt-codex-connector"]` (dogfood).
- reason:    The accepted cost is explicit: on a bot-reviewed repo this SUSPENDS unattended
             arming, because step 10 runs seconds after the PR opens and a reviewer that takes
             minutes has definitionally not reviewed yet. That is the correct trade for now —
             #87's convenience is worth less than the five real bugs the race shipped — and it is
             a stopgap, not the end state: #49 adds the PR watch that waits for the review,
             resolves its threads, and arms afterwards, at which point the guard becomes the
             precondition that watch satisfies rather than a reason to skip. A repo with no async
             reviewer opts back into unattended merging with one line, `bots = []`.
- trade-offs recorded (both surfaced by review, both deliberate):
             a. **Enforcement is agent-side, not GitHub-side.** #87's own premise was "let GitHub
                be the gate so no human has to be", and this guard is an `if` in step 10: an
                operator, the GitHub UI's auto-merge button, or any future caller bypasses it.
                The GitHub-side version would be a check run reporting "the declared reviewer has
                reviewed this SHA", made required via branch protection — but GitHub has no
                primitive for "wait for a COMMENTED review from an App"
                (`required_approving_review_count` needs an APPROVED from a write-access human),
                so the baseline would have to WRITE a workflow into the target repo, crossing
                repo-settings' "reads .github/workflows, never writes them" line. Agent-side is
                also where #49 lands, so this is the end state for now, not a stopgap shape.
                `--match-head-commit` is the one part GitHub *can* enforce, and it is pushed there.
             b. **The declaration layers repo -> global, so a GLOBAL declaration suspends arming
                machine-wide.** "Which logins are bots" is genuinely machine-level; "does THIS repo
                have an async reviewer" is repo-level, and one key answers both. An operator who
                declares the Codex connector globally therefore stops unattended arming in every
                repo, including ones where that App is not installed — recoverable with a per-repo
                `bots = []`, which inverts what the layering is for. Kept because it fails in the
                SAFE direction and matches the key's established semantics; the cleaner shape (a
                repo-scoped `[reviewers] blocking`, letting the two policies diverge — you want
                `github-actions[bot]`'s threads resolved but never blocking a merge) is filed
                rather than guessed at.
- baseline-issue: n/a (this repo IS the baseline; #134 is the tracking issue)

## D13 — `selfcheck` stays hermetic; the one live assertion is CI-only
- date:      2026-07-28
- category:  project-delta
- unknown:   #122 needs required-check drift caught on the PR that introduces the job, and only a
             LIVE read of branch protection can answer that. Every other check this repo runs is
             deterministic and offline, so there was no established home for a check whose input
             is external mutable state.
- decision:  The live assertion runs in CI only — a step in the already-required `repo-settings`
             job. `scripts/selfcheck.sh` does NOT run it and keeps the offline half:
             `scripts/check-repo-settings.sh` drives the predicate through a recording `gh` stub
             over in-sync, drifted, all-ungated, unprotected, opaque, malformed and
             401/403/404/500 responses. Golden Rule #3 in `CLAUDE.md` was AMENDED in the same
             commit — from "mirrors CI exactly" to "mirrors every *offline* check CI runs" — so
             this is a corrected over-statement, not a standing fork. That is why this is a
             project-delta and not a `DEVIATION`: after the amendment there is no rule left to
             contradict.
- placement: `.github/workflows/ci.yml` (the step), `scripts/selfcheck.sh` (deliberately absent),
             `CLAUDE.md` Golden Rule #3 (amended), `docs/repo-settings.md` (the reasoning).
- reason:    `selfcheck` earns its keep by being a DETERMINISTIC predictor of CI: same tree, same
             answer, every time, offline. A step whose verdict depends on network, auth, and
             settings someone else can change out from under it is the one thing that would break
             that property — a red local gate would no longer mean "your tree is wrong".
             Note what this reasoning does NOT claim, because the first draft of it overstated the
             case: a local step is not forced to choose between "always red offline" and
             "fail-open". The predicate already returns a third code (`20` = unreadable) and
             `selfcheck` already prints a third result (`SKIP`), so a 0→PASS / 14→FAIL / 20→SKIP
             arm is perfectly possible and would catch drift BEFORE the push — strictly earlier
             than CI, and strictly better for #122's goal. It was not taken here only to keep the
             gate hermetic, which is a preference, not an impossibility. Filed as a follow-up so
             the option is tracked rather than argued away: see the issue linked from #122.
- also:      The step rides the ALREADY-REQUIRED `repo-settings` job rather than taking a job of
             its own. A new job would itself be a newly added, non-required context — the fix
             would commit the defect it detects, and would gate nothing until someone ran
             `baseline repo apply`. It also reads the ordinary `repos/{slug}/branches/{branch}`
             endpoint rather than the admin-only `/protection` one, because `administration` is
             not a grantable `GITHUB_TOKEN` permission; the two return the same contexts.
- baseline-issue: n/a (this repo IS the baseline; #122 is the tracking issue)

## D14 — this repo supplies its own `/release`, and it calls the working tree, not the install
- date:      2026-07-28
- category:  project-delta
- unknown:   D7 committed the baseline to shipping NO `/release` and made `release` a permanently
             project-owned role. What it never did was supply THIS project's copy. So the repo sat
             in the one state D7 does not describe: the role is named, `/roadmap` emits it on a met
             readiness verdict, and nothing resolves it. The procedure lived only as three prose
             sentences in `CONTRIBUTING.md` -> Releases and was hand-executed for v1.0.0 and again
             for v1.1.0. The trigger was #188: a slash command that does not exist does not fail
             loudly in Claude Code, it fuzzy-matches the nearest built-in (`release-notes`), so the
             gap was invisible at the exact moment `/roadmap` said "cutting".
- decision:  Write the project's own skill at `.claude/skills/release/SKILL.md`. Four sub-decisions
             are worth pinning because each has a plausible-looking wrong answer:
             (1) IT CALLS THE WORKING TREE'S `scripts/lib/`, not the installed symlinks under
                 `~/.claude/scripts/lib/`. You are releasing this tree, so the predicates that gate
                 the release must be the ones in it — an installed lib can lag the tree (#142's
                 stale-read concern) and would gate the cut on code that is not what ships.
             (2) IT WAITS ON `pr-watch.sh`, NEVER `pr-review.sh gate`. The guard reads only the
                 reviews surface, so the Codex connector's clean pass — a `+1` reaction with NO
                 review object — wedges it at 16 forever (#167, reproduced live on PR #187 during
                 the v1.1.0 cut). A release skill that consulted the guard could never merge.
             (3) TAG-ONLY. No GitHub Release object, no package publish, no deploy — matching
                 v1.0.0 and v1.1.0. Adding one is a decision change, not an implementation detail.
             (4) IT REFUSES ON `indeterminate` HEALTH and on a zero-check read of the merge commit.
                 An unverifiable build is never tagged; zero check runs is "CI has not registered
                 yet", not "all checks complete".
- placement: `.claude/skills/release/SKILL.md` — the prescribed home for a project-scoped skill
             (`docs/per-project-overrides.md` -> Override 2a). Deliberately OUTSIDE `base/` and
             `agents/*/skills/`, the two paths `scripts/check-release-role.sh` guards, so D7's
             negative invariant stays intact and green.
- reason:    D7 says the baseline ships no generic release workflow BECAUSE the four real schemes
             are mutually incompatible. That argument is about the BASELINE's contents; it never
             argued a project should keep its own cut in prose. Leaving it unwritten is what made
             `/roadmap`'s terminating loop stop terminating at the last step. This is a
             project-delta and not a DEVIATION: writing the project's own copy is D7 being
             executed, not contradicted.
- amended:   2026-07-28, AFTER two review rounds found 17 defects in the prose-only first cut — one
             FATAL (a `{{ROADMAP_LIB}}` build placeholder pasted into a runnable step, so every
             release would have died with `command not found`), four more that could tag the wrong
             commit, merge an unreviewed head, or stamp `main` for a release that could never be
             tagged. The defects were not careless typing; they were the predictable cost of
             putting DECISIONS in a medium no test can execute. `selfcheck` was GREEN for all 17,
             because nothing in the harness reads `.claude/skills/`.
             SO THE SHAPE CHANGED: every decision moved into
             `.claude/skills/release/release-lib.sh` (`version-ok`, `changelog-verify`,
             `checks-settled`), regression-tested by `scripts/check-release-skill.sh` and wired
             into `selfcheck` + CI. SKILL.md is now orchestration prose that CALLS predicates,
             which is the same move `cleanup-lib.sh` (#106/#84), `roadmap-lib.sh` (#69) and
             `pr-review.sh` (#134) each made out of workflow prose. `/release` is the fourth, and
             the only one holding an irreversible act.
             The library sits BESIDE THE SKILL, not in `scripts/lib/`: `adb_agent_manifest`
             (common.sh:175) links that whole directory into every install, so a release predicate
             there would ship generic release machinery to every adopting repo — D7 reversed by
             accident. The check asserts that boundary, so it cannot drift back.
             The check also pins two lessons as executable invariants: no `{{PLACEHOLDER}}` inside
             a fenced (runnable) block — scanned fence-aware, since a placeholder in PROSE is the
             skill explaining the hazard, the #117 over-match — and the skill must still reference
             the tested predicates it delegates to.
- known-gap: The skill's remaining PROSE snippets are still not executed. The decisions are now
             covered; the orchestration around them is not. The general fix — executing inline
             snippets from any project-scoped skill, the way `check-roadmap-e2e.sh` does for
             `base/workflows/` — is #190.
- baseline-issue: n/a (this repo IS the baseline; #3/D7 is the standing decision, #188 the trigger)

## D15 — /roadmap composes the next release set itself; "advisory, never automatic" is retracted
- date:      2026-07-29
- category:  general
- unknown:   The release-goal convention (#27/#71) makes the loop TERMINATE — readiness is computed
             live and the cut is emitted rather than remembered. What it never covered is the state
             immediately AFTER a cut. `baseline release roll` archives the release milestone and
             opens a fresh EMPTY one, so the very next `/roadmap` run computes `unarmed` and stops:
             "release milestone has no requirements yet". Nothing in the baseline fills it. Observed
             live on 2026-07-29, the first run after the v1.1.0 roll: 62 open issues, every one of
             them implementable, and the workflow emitted no batch and no cut.
             So the convention closes the loop at the release boundary and re-opens it at the
             composition boundary. It is not a bug in any predicate — every one returned the right
             answer — it is a MISSING STEP, and the owner's judgement was the only thing that
             supplied it.
- decision:  `/roadmap` auto-composes the next release set when it detects `unarmed`, then continues
             the SAME run into the ordinary `unmet` advance. Four sub-decisions:
             (1) IT LIVES IN `/roadmap`, NOT IN `baseline release roll`. `roll` is deterministic
                 shell whose header states it has "exactly ONE correct shape"; composition needs
                 judgement, which shell cannot hold. `roll` also fires once, at cut time, while the
                 milestone can drain at any point — `/roadmap` runs every iteration and already owns
                 the bundles, the derived edges and the ordering.
             (2) BUGS ARE THE FLOOR, NOT A BUDGET LINE. Every implementable open `bug` is promoted
                 and labelled `release-blocker`. Enhancement riders are judgement-selected and capped
                 by `<!-- release-budget: N -->` (default 3). Owner-stated priority.
             (3) THE MECHANICAL HALF IS A TESTED PREDICATE, THE JUDGEMENT HALF IS RECORDED.
                 `roadmap-lib.sh compose-candidates` owns tiering, dependency closure and the stable
                 tie-break; the agent picks riders from that ranked slate and WRITES ITS REASONING
                 into the artifact. Determinism is preserved where it is checkable and made auditable
                 where it cannot be.
             (4) COMPOSITION IS ONCE PER CYCLE, BY CONSTRUCTION. It fires only on `unarmed`, and its
                 first act makes the milestone non-empty — so no later run re-composes, exactly as
                 step 4b's autofix is idempotent because it re-selects on `milestone == null`.
                 Nothing is remembered between runs and nothing needs to be.
- placement: `base/workflows/roadmap.md` (the compose step) + `scripts/lib/roadmap-lib.sh`
             (`compose-candidates`) + `scripts/check-roadmap.sh` (regression tests).
- reason:    A loop that terminates into a manual step every cycle is not a closed loop — it is a
             loop with a person wired into it, which is the exact shape this convention exists to
             remove. The counter-argument is real and is why #80 said "advisory, never automatic":
             auto-composition can reintroduce scope drift, and a frozen human-approved set is what
             made the release converge. It is answered rather than ignored: the set is still FROZEN
             once composed (the trigger is an empty milestone, never a non-empty one), it is bounded
             (bugs are finite, riders are capped), and every promotion is a reversible tracker edit
             the owner can undo with one `gh issue edit`. Scope drift came from an ever-GROWING set;
             this composes a bounded set once and then leaves it alone.
- retracts:  #80's Design section C and two of its acceptance criteria — "`/roadmap` **never**
             milestones issues itself" and "The proposal is advisory: nothing is milestoned without
             owner action." The rest of #80 (leverage ranking, capability closure, shown scores,
             zero-config generality, reproducible slates) SURVIVES and is what upgrades the ranking
             this decision ships. #80 is re-scoped, not superseded.
- known-gap: The ranking shipped here is bug-first + ascending number + dependency closure. It does
             NOT rank by unblock leverage or capability closure — that is #80's remaining half, and
             it is itself weakened until #112 lands, because `deps-from-body` still drops an edge
             written with markdown emphasis and the graph is what leverage is computed from.
- baseline-issue: n/a (this repo IS the baseline; #80 is the tracking issue)

## D16 — the state-claim rule becomes a gate, because as documentation it kept failing
- date:      2026-07-29
- category:  general
- unknown:   `base/practices/verify-before-asserting.md` states the rule, and #138 built
             `state-assert.sh observe` so a STATED status is correct by construction. Neither makes
             an agent state one — `observe`'s exit code gates nothing, so it renders optional
             narration, and the practice said so honestly rather than implying otherwise. What the
             baseline had no home for was the remaining failure: an agent that reads correctly and
             then writes a stale or unsourced sentence anyway.
             Exercised again on 2026-07-29 with the practice loaded in context and the correct
             reading in hand: a `/cleanup` report volunteered `(OPEN at 14:55:26Z)` for a PR that
             had merged fourteen minutes earlier. The owner's response — that this has been
             "resolved" across multiple closed issues and keeps recurring — is the accurate
             diagnosis: every prior fix was documentation, and documentation cannot bind behavior
             it only describes.
- decision:  Add a THIRD structural guard, matching the only two that have ever worked here —
             `pr-review.sh gate` (gates an actual merge) and `cleanup-lib.sh branch-verdict` (gates
             a branch delete). Both work because a wrong answer stops the machine.
             (1) `state-assert.sh lint` — the grammar, as a pure offline predicate. ONE rule: in
                 prose, a status word in the same sentence as an issue/PR reference must itself be
                 introduced by `was observed`.
             (2) `state-claim-gate.sh` — a Stop hook whose exit code gates THE END OF THE TURN.
             Three sub-decisions are worth pinning:
             (a) PER-OCCURRENCE, NOT PER-SENTENCE. The sentence that shipped contained a compliant
                 `was observed MERGED` clause AND a stale `(OPEN at …)` clause; a sentence-level
                 test finds the template and passes the exact defect. It is the regression fixture.
             (b) SMALL GRAMMAR, BIASED TOWARD PRECISION. The practice already ruled that a
                 classifier over arbitrary English "would be theatre beyond a small documented
                 grammar", so this is that much and no more: `#N` binding, `was observed`
                 introduction, #117-style container stripping, and verb carve-outs so `open a PR`
                 never fires. A gate that cries wolf gets worked around, and this ships to every
                 adopting repo.
             (c) NEVER WEDGES A SESSION. Missing jq, an unreadable transcript, a text-free turn and
                 a missing linter are all no-ops — reported on stderr (#35), never blocking.
                 Deliberately NOT fail-closed: this gates NARRATION, not an irreversible act, and a
                 session wedged by a missing dependency is worse than the claim it would catch.
- placement: `scripts/lib/state-assert.sh` (the predicate, beside `observe` — one home per entity
             kind) + `agents/claude/scripts/state-claim-gate.sh` (the hook) +
             `adb_claude_hook_scripts` (the ONE hook enumeration, so install and uninstall both
             pick it up) + `scripts/check-state-assert.sh` (regression tests).
- reason:    The repo's own evidence says prose does not bind an agent: the dependency-edge rule,
             the release-readiness ladder and `/cleanup`'s predicates each stopped drifting only
             when they became tested code. This rule had been through the same cycle twice and was
             still prose. Making the turn itself the thing that fails is the smallest change that
             moves it into the category that has actually held.
- known-gap: A Stop hook fires AFTER the text streams — it forces a correction, it cannot prevent
             the claim. The grammar is small, so unusual phrasings pass. And the wiring is
             Claude-only today; the predicate is agent-neutral shell, so Codex/Gemini equivalents
             ride the enforcement-hooks epic (#14/#25).
- baseline-issue: #195
