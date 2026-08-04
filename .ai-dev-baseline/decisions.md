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

## D13 — `selfcheck` stays hermetic; live assertions are CI-only
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
- amended:   2026-07-30 by D24 (#212). This entry said "the ONE live assertion", and a second
             one now exists: the live half of the claim lint. The PRINCIPLE is unchanged and was
             applied rather than bent — `selfcheck` stays hermetic and the network-dependent half
             rides CI — but the COUNT in this entry's title and in `CLAUDE.md` was a factual claim
             that had gone stale, which is precisely the class #212 exists to catch. Corrected in
             both places rather than left to drift.

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

## D17 — run-marker ownership is a session id, and every absence fails toward enforcement
- date:      2026-07-29
- category:  project-delta
- unknown:   The baseline had no model for **which session** a piece of run state belongs to. Every
             workflow keyed its state to the checkout (a branch name), and the Stop hook read it
             the same way — so in a clone with two Claude sessions, both matched the same marker.
             That is not a hypothetical: a tracker-only session was instructed to `gh pr create`
             against another session's branch that already had an open PR.
- decision:  The `/implement-issue` run marker (and its blocked file) carry an `owner` — the id of
             the SESSION that wrote them — and `implement-issue-gate.sh` compares it against its
             own session before treating the marker as its own. Four sub-decisions are the load-
             bearing ones, because each picks a failure DIRECTION and the wrong pick is silent:
             (a) ABSENT OWNER FAILS TOWARD ENFORCEMENT, NOT INERT. A marker with no `owner` (an
                 install predating the field, or an agent whose harness exposes no session id), or
                 a hook that cannot identify its own session, falls back to the branch-name
                 behaviour this gate always had. A false "mine" costs one misdirected hint; a false
                 "not mine" silently switches the no-stop-until-PR invariant off. Enforcement code
                 must not go quiet when it is unsure what it is looking at.
             (b) NO PID FALLBACK, despite the filing issue suggesting `session_id` "falling back to
                 pid". The writer is a tool-call shell and the hook is a separate process; neither
                 derives the same pid, so a pid manufactures mismatches rather than resolving them.
                 No id available → no `owner` key → (a).
             (c) OWNERSHIP IS TRANSFERABLE. A resumed or successor session re-stamps `owner` on its
                 next phase update. Without that, any session-id change would strand a live run's
                 marker as permanently foreign — fail-open for the rest of the run, which is (a)'s
                 failure by another route.
             (d) THE BLOCKED FILE DEGRADES PERMISSIVE. Owners are compared only when BOTH files
                 carry one; a mixed-vintage pair falls back to branch/issue. The directions are not
                 symmetric here: a wrongly-REFUSED escape is an unstoppable turn, while a wrongly-
                 granted one merely ends a turn early. This inverts (a) on purpose, because the
                 blocked file is the escape hatch rather than the enforcement.
             Identity is read env-first (`CLAUDE_CODE_SESSION_ID`) with the hook's stdin
             `session_id` payload as fallback, and the payload read is BOUNDED — an open-but-silent
             pipe would otherwise burn the hook's 30s budget, and a hook killed by its timeout
             enforces nothing.
- placement: `base/workflows/implement-issue.md` (the schema + writers, rendered to all three
             agents) + `agents/claude/scripts/implement-issue-gate.sh` (the reader) +
             `scripts/check-implement-gate.sh` (regression tests).
- reason:    A checkout is a working-tree property and a run is a session property; keying one to
             the other is the whole defect. The field is Claude-consumed today because the Stop
             hook is, which puts it squarely in the "enforcement references stay agent-literal
             until #14/#25" carve-out `base/workflows/README.md` already documents — so it needed
             no new `{{PLACEHOLDER}}` and no new config surface.
- known-gap: Ownership makes the READER safe, not the PATH exclusive. Two real runs in one
             checkout still collide on the fixed state filenames, and preflight's unconditional
             clear can delete a live foreign marker before any ownership check sees it. Tracked in
             #202. The reason to defer is NOT that a crashed run's marker would become uncleanable
             — `cleanup-lib.sh state-verdict marker` reaps a stale marker from PR state and branch
             refs, with no session liveness involved, so `/cleanup` is a second cleaner. It is that
             per-run state paths would be solving the wrong problem: two `/implement-issue` runs in
             one checkout share ONE HEAD, so they fight over the branch whether or not their state
             files collide. #202's likely resolution is therefore "refuse to start a second run"
             (which wants #159's liveness read), not per-session filenames.
- baseline-issue: #180

## D18 — a declared reviewer login is matched asymmetrically, and a bare login means "either"
- date:      2026-07-29
- category:  project-delta
- unknown:   `[reviewers] bots` declares reviewer LOGINS, but GitHub reports the same App two ways
             depending on which API answered — GraphQL `foo`, REST `foo[bot]` — and the baseline had
             never decided what a given declaration MEANS. Both PR guards resolved the ambiguity the
             same lossy way: strip a trailing `[bot]` from the declaration AND from the API login,
             then compare. Nothing recorded that as a choice, so nothing flagged that it made
             `bots = ["foo[bot]"]` satisfiable by a **human account literally named `foo`** — and
             reactions are publicly writable, so on the clean-pass signal the bar was a login
             collision and nothing else. `gh api users/gemini-code-assist` returns a real User
             account, so the collision space is populated by the kind of account that reviews PRs.
- decision:  Normalize the API login TOWARD the declaration, never the reverse — and by APPENDING
             the suffix to a bare declaration rather than stripping it from the API login, so the
             rule is strictly one-directional:
             (a) declared `foo` (bare) matches API `foo` OR `foo[bot]` — **either**, App or human.
                 This is the PORTABLE spelling and the documented default: it matches whichever form
                 the reading API returns, which is what keeps the guards working across the
                 GraphQL/REST split, and it is what the built-in allowlist and this repo already
                 declare. Choosing "App only" here would have silently wedged every existing
                 declaration at "awaiting review" forever.
             (b) declared `foo[bot]` matches API `foo[bot]` ONLY — **that App, exactly**. A human
                 named `foo` can never satisfy it. This is the strict spelling, available by
                 choosing it.
             A `user.type` filter was rejected as the discriminator: verified live, the reactions
             endpoint reports `type: "User"` for the Codex connector while the reviews endpoint
             reports `type: "Bot"` for the same App, so a type filter would reject the real signal.
- placement: `scripts/lib/common.sh` (`adb_reviewer_match_jq` — the one jq def all four filters in
             the two guards share) + `scripts/lib/role-dispatch.sh` (`bots --comparable`, which owns
             the declaration side and no longer strips the suffix) + `docs/roles-and-agents.md` and
             `templates/agents.toml` (the operator-facing spelling table).
- reason:    The issue required the implementation to DECIDE what a bare login means, because it was
             ambiguous in both directions. "Either" is the only choice that is simultaneously
             back-compatible, portable across the two APIs, and honest — and it costs nothing that
             the strict spelling does not recover for an operator who wants it.
- known-gap: (b)'s strictness is against the OBSERVED API SPELLING, not a stable App identity. A
             guard that later reads a different API surface — #174 proposes collapsing these reads
             into one GraphQL query, which reports the bare form — would stop satisfying a declared
             `foo[bot]`. That fails SAFE (the guard withholds the arm rather than merging) but it is
             real, and the documented examples were changed to the bare form so no shipped default
             depends on it. Closing it needs an identity that is not a login string (an App/account
             id); tracked in #207.
- baseline-issue: #173

## D19 — a reviewer signal's freshness is proved against a server-assigned ref-change record
- date:      2026-07-30
- category:  project-delta
- unknown:   `pr-watch.sh` must decide whether a date-scoped reviewer signal (a `+1` reaction, a
             task-mode issue comment) applies to the CURRENT head. Neither carries a commit, so the
             proof is a timestamp comparison — and the baseline had never decided WHAT the lower
             bound of that comparison should be. The obvious choice, the head commit's committer
             date, is CLIENT-SUPPLIED: git records `GIT_COMMITTER_DATE` verbatim and GitHub echoes
             it back unmodified, so the comparison was asymmetric in its trust. A past-dated head
             made a stale `+1` look fresh and returned `clean` for a head nobody had reviewed —
             reachable with no attacker, via a date-preserving rebase or a slow clock. #167 raises
             the stakes: it lets a `+1` authorize `pr-review.sh gate` returning 0, i.e. an
             automatic merge.
- decision:  Prove freshness against the REPOSITORY ACTIVITY record for the head REF — the LATEST
             activity whose `after` SHA is the current head — and drop the commit read entirely.
             Four properties decided it, and the three rejected candidates each fail one:
             (a) SERVER-ASSIGNED. GitHub stamps the timestamp when the ref moved. The committer
                 date fails this and is the whole defect.
             (b) REF-SCOPED, not SHA-scoped. This is the property that is easy to miss, and it is
                 why the CHECK-SUITE anchor the issue proposed first was rejected: a suite belongs
                 to the SHA, so a commit that already ran CI elsewhere carries its ORIGINAL
                 timestamp and an ordinary fast-forward onto it PRESERVES the fail-open — with no
                 force-push anywhere, so pairing it with a force-push term does not rescue it.
                 Commit statuses have the identical flaw.
             (c) COVERS ORDINARY PUSHES. Timeline `head_ref_force_pushed` events are server-assigned
                 AND ref-scoped, but exist only for FORCE pushes.
             (d) DOES NOT DESTROY LIVENESS. `head.repo.pushed_at` satisfies (a)–(c) and is free (it
                 is already in the PR object). It was rejected on liveness ALONE, and it is worth
                 recording that it is genuinely SOUND — being repo-wide it can only ever be too
                 LATE, i.e. a false `pending`, never a false `clean`. But a push to any unrelated
                 branch re-opens a settled verdict, so on an active repo a watch would run to its
                 bound instead of converging. Safety was not the axis; usefulness was.
             Taking the LATEST matching record rather than the earliest is deliberate and is the
             force-push defence: a ref that went A -> B -> A carries two records for A, and only
             the later one says when it is A *now*.
             An anchor that cannot be established yields `pending` for BOTH date-scoped signals,
             never `clean`. Keeping the client-supplied date "just for the comment path" was
             rejected: it would leave the forgeable input in the file for a path feeding the same
             callers, and one rule over both signals is checkable where two are not. A REVIEW is
             commit-scoped and needs no anchor, so it is unaffected — and because the anchor needs
             no CI, a repo without any keeps the clean signal.
- placement: `scripts/lib/pr-watch.sh` (`head_anchor` + `is_utc_instant`), with the rejected-anchor
             reasoning kept BELOW the dispatch preamble rather than in the leading comment block,
             because `adb_usage` renders that block as `--help` and an operator does not need an
             essay on designs that were not built. The path-safe slug test went the other way — it
             is a GENERIC primitive, so it landed in `common.sh` as `adb_is_path_safe_repo_slug`
             beside the shape test it strengthens, with its own tests in `check-common-lib.sh`.
             Regression tests in `scripts/check-pr-watch.sh`; operator-facing consequence in
             `base/workflows/resolve-pr-threads.md` (rendered into all three agents' skills).
- second-consumer: `head_anchor` stays PRIVATE to pr-watch.sh for now, and this is a deliberate
             choice rather than an oversight, because #167 will give it a second consumer:
             `pr-review.sh gate` returning 0 on a reaction is an ARMED MERGE, so it needs exactly
             this predicate at higher stakes. It is not promoted TODAY because the neutral-code
             shape a shared version needs (0 anchor / 1 unestablished / 2 unreadable, mapped by
             each caller to its own vocabulary — the `adb_pr_slug_check` pattern) should be
             designed against a real second caller, not guessed at with one. The risk this accepts
             is named honestly: #173 exists because two private copies DIVERGED into a live
             fail-open, so promoting late is how that happens again. The mitigation is that #167
             must promote it as its first step rather than copy it — recorded on that issue, not
             left to memory.
- reason:    The staleness rule is the one place this module can be wrong in the dangerous
             direction, so its lower bound is a design decision rather than an implementation
             detail — and the next person to touch it will reach for check suites, which is the
             candidate that looks right and is not. Recording WHY each alternative fails is the
             point of the entry.
- baseline-issue: #175

## D20 — one reviewer-evidence classifier for both PR guards, and the two folds that are NOT the same order
- date:      2026-07-30
- category:  project-delta
- unknown:   `pr-review.sh gate` and `pr-watch.sh` were both answering one underlying question —
             *given everything a declared reviewer emitted, has this head been reviewed, and was it
             clean?* — in two places, and the two answers had already diverged in both dimensions
             the question has. WHAT a signal means: `APPROVED` was `findings` in the watcher and
             `satisfied` in the arming guard. HOW MANY reviewers must produce one: the guard
             required all of them, the watcher pooled the set and answered on any one (#185). The
             guard also read only ONE of the three surfaces a reviewer can speak on, so a clean
             Codex pass (a `+1`, no review object) and a task-mode result (one issue comment, no
             review) were invisible to it — 16 forever, and on a task-mode repo 16 on EVERY PR.
- decision:  ONE neutral per-reviewer CLASSIFIER, shared; NOT shared exit codes. State the reason
             PRECISELY, because the loose version is the dangerous one to leave in a decision log:
             the two modules do NOT apply different decision FUNCTIONS. Put the two mapping tables
             side by side and every class produces the same decision in both — withhold on
             rejected/attention/unknown/none, pass only on clean. There is no class where one guard
             proceeds and the other does not, and there must never be one.

             What differs is REPORTING GRANULARITY. `pr-watch` collapses {rejected, attention} into
             one code because its consumer's next action is identical either way; `pr-review` splits
             them 19/21 because its consumer's next action differs (address a rejection vs read a
             comment). That is a real difference and it does justify per-module mappings — but it is
             a much narrower claim than "they ask different questions", and the narrower claim is
             the stronger mandate: the two guards may differ in how finely they REPORT, never in
             what they DECIDE. A future reader who believes they ask different questions will
             conclude they may legitimately diverge in logic, which is exactly what #185 was.

             The rule, stated once:

               CHANGES_REQUESTED at this head               -> rejected
               COMMENTED at this head, or a FRESH comment   -> attention
               APPROVED at this head, or a FRESH `+1`       -> clean
               stale / PENDING / DISMISSED / nothing        -> none
               unrecognized state, or an undatable record   -> unknown

             THE TWO FOLDS ARE DELIBERATELY DIFFERENT ORDERS, and this is the entry's real content
             because reusing one for both IS the #185 bug:

               within a reviewer:  rejected > attention > unknown > clean > none
               across the set:     rejected > attention > unknown > none  > clean

             Within a reviewer, take the strongest thing that reviewer produced — a stale `+1`
             beside a fresh `APPROVED` is `clean`. Across the set, `clean` is the WEAKEST class, so
             a pass requires EVERY declared reviewer: one silent reviewer beside one clean reviewer
             is NOT a pass. Two other positions are load-bearing in both orders. `unknown` outranks
             `clean`, which REVERSES the older "an accepted review outweighs an unknown-state one" —
             a state nobody could interpret must never be outvoted into a merge authorization, and
             that rule was the one place a fresh unrecognized state was silently discarded.
             `rejected`/`attention` outrank `unknown` because both already withhold the arm AND name
             concrete work, where `unknown` only says "retry".

             MAPPINGS: pr-watch renders rejected/attention as `findings` (10), unknown as 20, none
             as `pending` (11), clean as 0. pr-review renders rejected as 19, attention as a NEW
             code **21**, unknown as 20, none as 16, clean as 0.

             **21 = "review complete, attention required"** is the correction #167 §3 makes to its
             own original acceptance criterion, which asked for 0 and was UNSAFE. A fresh issue
             comment is the task-mode FINDINGS shape (PR #178's sole Codex comment reported
             unresolved selfcheck warnings), so 0 would have authorized auto-merging code the
             reviewer had just flagged — the exact fail-open #134 exists to prevent, reintroduced
             through the fix for its sibling. It is distinct from 19 (nothing was formally rejected)
             and from 16 (nobody is being waited for), because the operator action differs: read
             what the reviewer said, rather than wait or address a rejection.

             THREE SUB-DECISIONS that were left to control-flow accident before and are now stated:

             (a) THE ANCHOR IS PER-SIGNAL, NOT GLOBAL. A date-scoped signal that cannot be proved
                 fresh degrades to `none` for THAT reviewer; it never poisons the fold and never
                 suppresses commit-scoped review evidence, which carries its own `commit_id` and
                 needs no anchor (D19). An unestablished anchor resolves to the far-future sentinel
                 `ADB_NO_ANCHOR` rather than the empty string — every freshness test is
                 `[ "$candidate" \> "$anchor" ]`, so an empty default is the fail-open spelling
                 exactly, and the sentinel inverts it so forgetting to set an anchor yields
                 pending/awaiting rather than clean.
             (b) NO SHORT-CIRCUIT ON THE FIRST SURFACE. Both modules now read all three surfaces
                 before classifying anything. The verdict is a property of the whole declared set,
                 so every reviewer's evidence must be in hand; and a failed read is 20 UNIFORMLY
                 rather than invisible on whichever path happened to return early. Which of two
                 fail-closed answers an operator gets must not depend on read order. Costs two
                 extra reads on a watch's terminal poll and nothing in the steady state.
             (c) THE ANCHOR READ STAYS CONDITIONAL. It is a fifth request, paid for only when a
                 date-scoped candidate actually exists. Pinned by a test asserting the endpoint is
                 NOT addressed when no such signal is present.
- placement: `scripts/lib/common.sh` — `adb_reviewer_evidence` (selection), `adb_reviewer_classes`
             (dating + the within-reviewer fold), `adb_fold_reviewer_classes` (the across-set fold),
             `adb_reviewers_in_class` (diagnostics), `adb_reviewer_classes_for_pr` (the whole
             read-and-classify pipeline), plus `adb_head_anchor` / `adb_is_utc_instant` /
             `adb_paginated_list` PROMOTED out of pr-watch.sh.

             THE PIPELINE IS SHARED TOO, not just the classifier, and that was a correction made
             during review. Sharing only the classifier left both guards open-coding the same six
             steps — three surface reads, evidence selection, the anchor decision, classification —
             differing by a label. Worst of it: each decided whether to fetch the anchor by
             PATTERN-MATCHING the evidence record format, which common.sh owns. Change the delimiter
             (as the move to TAB below did) and both guards silently stop fetching the anchor, every
             date-scoped signal degrades to `none`, and both wedge at once with no error anywhere.
             The record grammar is TAB-separated for the same class of reason: a login is the one
             field this code does not control, and under a space delimiter one carrying a space
             splits across the boundary, so the reviewer never matches its own evidence. TAB makes
             the split total by construction; `role-dispatch.sh` independently rejects such a
             declaration (18, fail-closed — dropping the entry alone would SHRINK the set every
             consumer must satisfy), and neither guard is load-bearing alone.

             NOT split into its own `scripts/lib/pr-evidence.sh`, though a review pass argued for it
             on volume (the PR-domain blocks are now ~45% of common.sh). Two reasons: #167 §7
             prescribes `common.sh` following #179's precedent, and the strongest argument offered
             for splitting — that this introduces the first network I/O into a library sourced by
             `install.sh` — is FALSE: `adb_require_gh` (`gh auth status`) and `adb_repo_slug`
             (`gh repo view`) already shelled out to `gh` before this change. The volume argument
             survives on its own and is filed rather than acted on here. D19's `second-consumer` field
             required that promotion as #167's first step rather than a copy, and #167 §6 named
             `read_list` as the third thing a naive implementation would duplicate. Thin consumer
             mappings in `scripts/lib/pr-review.sh` and `scripts/lib/pr-watch.sh`; direct tests in
             `scripts/check-common-lib.sh`; consumer-level mapping tests in `scripts/check-pr-review.sh`
             and `scripts/check-pr-watch.sh`; `pr-classifier-shared` / `pr-classifier-no-copies` pins
             in `scripts/check-fact-drift.sh` proving both consumers call the shared helpers and keep
             no local copy (including the sentinel literal, whose failure mode is silent). Operator
             surfaces: `docs/repo-settings.md`, `base/workflows/implement-issue.md` step 10 (an
             explicit `21)` arm — folded into `*)` it reports "unreadable, retry" for a PR whose
             review is sitting right there) and `base/workflows/resolve-pr-threads.md`.
- reason:    Answering one question in two places is how the two libraries disagreed, and the
             disagreement was invisible because each module's tests only ever exercised its own
             vocabulary — `check-pr-watch.sh` declared exactly ONE reviewer in all ~35 scenarios,
             which is precisely why #185 shipped. A shared classifier with per-module mappings keeps
             the two guards' different FINAL questions intact while making the underlying rule
             checkable in one place, at one altitude, with one set of direct tests.
- what-this-does-NOT-do: restore unattended arming. `/implement-issue` asks the gate exactly once,
             seconds after `gh pr create`, when an async reviewer has definitionally not responded,
             and no path re-arms afterwards. #167 delivers a gate that returns the RIGHT ANSWER when
             asked — which matters for a re-run, a manual invocation, and as the precondition for
             any automatic arming. Automatic re-arming is #168, an open owner decision, and
             per-reviewer signal profiles are #186.
- baseline-issue: #167, #185

## D21 — the in-session reviewer is the model that did NOT write the diff, and an absent CLI is a rung, not a failure
- date:      2026-07-30
- category:  project-delta
- unknown:   `agents.toml` shipped `primary = "claude"` alongside `review = ["claude"]`, so the
             prescribed in-session review was Claude checking Claude — the implementer grading its
             own work. Both vendors' published prompting guidance argues against that arrangement
             from opposite ends: Anthropic's Opus 5 guidance asks that explicit verification
             scaffolding be REMOVED from Claude's instructions (it self-corrects natively and
             over-verifies when told to), while OpenAI's asks Codex for exactly the named-checklist,
             required-vs-optional pass this slot runs. Read together they are not a conflict but an
             assignment. What the baseline did not model was the consequence: pointing `review` at
             an agent whose CLI may not be installed, in a step that runs AFTER the branch, the
             commits and the gates.
- decision:  Three things, and the second is the one that makes the first safe.

             (1) THE SHIPPED MANIFEST DEFAULT MOVES to `review = ["codex"]`
             (`templates/agents.toml`, this repo's `agents.toml`, and the global manifest
             `install.sh` copies from the template). The RESOLVER's built-in fallback for an unset
             `review` is deliberately UNCHANGED — still the primary's own pass — so a repo with no
             manifest at all is untouched. These are two different "defaults" and only one moved.

             (2) CAPABILITY BECOMES A THIRD QUESTION, asked before dispatch.
             `role-dispatch.sh available <agent>` answers "is this agent's CLI on PATH here?"
             (0/1/2), separate from `resolve` ("who is assigned") and from an `invoke` rc ("did the
             agent fail"). Step 8 asks it FIRST and reports a rung — independent · same-model ·
             deferred to the PR layer · none — instead of discovering the answer as a 127 that
             classify_rc quite correctly calls "a real agent/CLI error": accurate about the exit,
             wrong about the cause, and arriving at the most expensive possible moment. An absent
             CLI therefore never writes a blocked marker. A reviewer that RAN and did not return
             still does; the two are different facts and the step names which one happened.

             (3) A SAME-AGENT SLOT IS LABELLED, NOT DELETED. The `claude` review arm stays
             implemented and supported, because removing it would strand every installed project
             that still carries `review = ["claude"]` (neither `install.sh` nor `agent-init`
             rewrites an existing manifest) AND the legitimate Codex-primary-reviews-with-Claude
             case, which is this same split pointing the other way. The anti-pattern is
             `review` token == `primary` token — an agent-neutral property — not "Claude reviews".
             Such a slot runs and is reported *same-model (not independent)*.
- placement: `scripts/lib/role-dispatch.sh` (`adb_agent_cli` + `adb_agent_available`, paired with
             `_adb_rd_invoke_agent` and proven paired by `scripts/check-role-dispatch.sh`);
             `base/workflows/implement-issue.md` step 8 (the rung table, the review-prompt shape)
             and step 11 (the rung is reported, never rendered as a ✅); `bin/agent-init` (the same
             rung at setup time, from the same readers); `base/roles.md` + `docs/roles-and-agents.md`
             (the law and the operator doc); `templates/agents.toml` + `agents.toml` (the manifests).
- reason:    The narrower fix — flip the default and delete the Claude arm, as #211 §1 literally
             asked — breaks two supported configurations and blocks the run at the worst point for
             every adopter without `codex`. Making CAPABILITY a first-class question is what lets
             the default move without either consequence, and it generalizes: it is about any agent
             whose CLI may be absent, not about Codex.

             The rung ladder is also deliberately HONEST about its weakest rung. "Deferred to the PR
             layer" gates step 10's `--auto` arm and nothing else — not a manual merge, not branch
             protection, and it resolves no threads — so it is reported as *deferred*, never as a
             completed review. `agent-init` reads the DECLARED allowlist (`bots --declared`) rather
             than the bare `bots`, whose unset default is a built-in set of eight common review
             bots and would otherwise promote a project that has declared nothing from *none* to
             *deferred*.
- what-this-does-NOT-do: strip the verification scaffolding from Claude's own instructions
             (#211 §2) or build the per-agent instruction-density mechanism (#211 §3). Those two
             cannot be separated from each other — `base/practices/self-review.md` renders into ALL
             THREE root docs, so rewriting it also removes verification guidance from Codex, the
             agent whose guidance asks for it — and `build.sh` has no home for a per-agent block
             today: the practices `render()` takes no agent parameter at all (it concatenates), and
             the workflow substitution is line-based literal token replacement, so the
             `{{VERIFICATION_GUIDANCE}}` block named in the issue is not the cheap candidate it
             looks like. §3's invariant ("a rendered skill must never differ in WHAT it does") also
             conflicts with §2 as written, since the self-review pass produces named findings that
             step 9 triages and the PR body reports. That is an owner-facing design question, so it
             ships as one atomic follow-up rather than being guessed at here.
- baseline-issue: #211

## D22 — a negative pin must declare the spellings it retires, and be watched failing on each
- date:      2026-07-30
- category:  general
- unknown:   The baseline says a gate must be able to answer wrong (`base/roles.md`'s review lens 4,
             `docs/design-principles.md`). What it did not model is how to ENFORCE that for a check
             whose failure mode is silence. A positive assertion that breaks goes red; a NEGATIVE
             one that breaks goes green, reports exactly what a clean run reports, and is invisible
             to every existing test because every assertion still passes. `absent:\[bot\]\$` shipped
             matching neither real idiom — the bracket is always backslash-escaped — and was caught
             only because the agent chose to negative-test. Nothing required it.
- decision:  Three layers, each one the negative test of the layer above it.

             (1) A DECLARATION, checked on every run. Every `absent:` rule must carry one or more
             `fires:<witness>` arguments naming the real superseded spellings it exists to catch,
             and `fact()` fails if a pattern does not match its own witness. One witness PER
             SPELLING, because a pattern that catches three of four is green on the fourth — which
             is precisely the shape of the original defect, one spelling wider.

             (2) AN EXECUTION, `check-fact-drift.sh --mutation`. Each witness is injected into a
             COPY of every file the rule pins and the real lint is re-run there; it must return
             the drift verdict naming that rule and that file. Exactly rc 1 — "any non-zero" would
             accept a crash — and rc 0 is reported as *this pin cannot fire*, distinct from a
             broken harness, because rc 0 is the failure the mode exists for. It refuses to run
             against an already-red tree, where every injection would "fail" for the wrong reason.

             (3) THE GUARDS' OWN NEGATIVE TEST, `scripts/check-fact-guard.sh`. (1) and (2) are
             themselves guards, so they get the same rule: both are driven against deliberately
             broken rules in a tree copy and must be seen going red. It stops at three layers
             honestly — layer 3's assertions fail LOUDLY (a normal unit test), so it is not itself
             a silent-failure guard and does not owe a layer 4.

             The enumeration is never serialized. `--mutation` is a MODE of the lint, so `fact()`
             stays the single enumeration of rules; a TSV side-channel would have been lossy
             (tabs, newlines, backslashes) and its labels are not even unique — four patterns share
             `pr-classifier-no-copies`.
- placement: `scripts/check-fact-drift.sh` (grammar, witnesses, `--mutation`, counters, and the
             `req_absent` call-site invariant); `scripts/check-fact-guard.sh` (the guards' negative
             tests); `scripts/selfcheck.sh` + `.github/workflows/ci.yml` (wired as STEPS of the
             existing `fact-drift` job, never a new job — a new job is a new check context branch
             protection would not require, which `required-drift` exists to flag);
             `base/practices/self-review.md` (the two rules, rendered into all three root docs).
- reason:    Prose had already failed: the rule "a gate must be able to fail" was written down and
             the unfirable pin shipped anyway. The three mechanisms this repo has that actually
             stick all work because a wrong answer stops the machine, so this one is wired the same
             way — the witness contract fails the lint, and the mutation step fails CI.

             Two latent defects surfaced while writing the witnesses, which is the argument for the
             approach in miniature. `backstop-stale-7min` used `[≥>]` and `3[–-]7`: a bracket
             expression holding a multibyte character is matched BYTEWISE under a C locale, so
             `3–7 min` could not be caught there — a pin that fired on a UTF-8 dev box and silently
             did not on a C-locale runner. And the new call-site invariant shipped with the exact
             match-nothing defect it polices (`[^#[:space:]]` consumed the first character, so a
             line STARTING with the call never matched), caught by layer 3.
- baseline-issue: #213
- what-this-does-NOT-do: mechanize "any future gate whose failure mode is silence" (#213's second
             bullet). Where a guard's rules are ENUMERABLE the harness is generic — `fact()` names
             every rule, so present and future `absent:` pins are covered without anyone
             remembering. Where the set is OPEN, an arbitrary future gate has no enumeration to
             drive and no declared rejectable input, so it stays a DISCIPLINE stated in
             `self-review.md`, not a mechanism. Saying that plainly is the point: implying
             coverage that does not exist is the same failure one level up. The `req_absent`
             family specifically IS closed, and is closed by asserting there is no caller outside
             `fact()`.

             It also does not ship the `PreToolUse` hook #213 asks the reader to *consider*; see
             D23 for why that is a separately designed piece of work.

## D23 — the destructive-git rules ship as practice text; the MECHANISM is a separate design
- date:      2026-07-30
- category:  general
- unknown:   #213's second half asked the reader to *"consider a hook"* — a Claude `PreToolUse` hook
             refusing `git checkout`/`git restore` against a path with unstaged modifications. The
             baseline models Stop and SessionStart hooks; it had never modelled a hook that BLOCKS
             AN ARBITRARY SHELL COMMAND, which is a different problem from the three shipped gates:
             those read state the repo owns, this one has to understand a raw command string.
- decision:  Ship the practice text in this PR (`git-and-prs.md`'s destructive list, with the
             per-command recoverability distinction, and `self-review.md`'s copy-don't-mutate
             method) and file the mechanism as its own issue rather than guessing at it.

             The `PreToolUse` CONTRACT was verified live, not assumed — `matcher: "Bash"`, stdin
             `cwd` + `tool_input.command`, exit 2 blocks with stderr fed back, plus a JSON
             `permissionDecision` alternative. The contract is not the problem. Hand-splitting a
             raw shell string on `;`/`&&`/`||`/`|` cannot recover the command or its argv, and the
             naive guard fails in BOTH directions at once: it blocks `git checkout -b`,
             `git restore --staged` (which preserves the worktree) and the words inside a heredoc,
             while missing `git -C`, aliases, `eval`, everything inside a script (`PreToolUse` sees
             `bash foo.sh`, never what it runs), and the staged data a `git diff --name-only`
             predicate never looks at. The draft's in-command escape hatch was worse: a literal
             token the agent can type itself is not authorization.
- placement: `base/practices/git-and-prs.md` + `base/practices/self-review.md` (the rules, rendered
             into all three root docs); issue #228 (the mechanism, in `Backlog`).
- reason:    A guard that blocks safe work gets disabled, and one that misses the destructive case
             is theatre — this design manages both, which makes shipping it worse than the honest
             gap. #213's own wording is *consider*, and its release-blocking argument rests on the
             rule being written down where every adopting project inherits it.

             Saying which half shipped is part of the decision: this is documentation, and
             documentation is what already failed once here. #228 carries the two candidate
             mechanisms (a real command parse vs declarative `permissions.deny` rules, which need
             no parser but impose global policy through an install surface `install.sh` does not
             write today), the fail-open/fail-closed posture question, and the full integration
             debt a fourth hook owes.

             A third candidate surfaced in review and is recorded so #228 does not re-derive it:
             a hook entry can carry an `if` PERMISSION-RULE filter (e.g. `if: "Bash(git restore *)"`),
             so the harness decides which commands reach the hook at all — its own parser rather
             than ours. That removes the classification problem from our code but not the design
             work: the hook still has to decide the TARGET STATE question (does this path actually
             hold unstaged work?) and the OWNER-AUTHORIZATION question (what is the escape hatch
             that the agent cannot take for itself?), which are the two that make this a design
             rather than a patch. Classified `general` rather than `project-delta` for the same
             reason the issue was filed at all: the hook would ship to every adopting project.
- baseline-issue: #228

### D22 — amendment after independent review (2026-07-30)

The independent Codex pass reproduced three holes in the layer-3 machinery, and each is the same
shape the decision is about — a guard that is green because it never looked:

- **`check_summary` reported PASS for a suite that ran ZERO assertions.** The suites are what prove
  the guards can go red, so a suite that quietly stops running is a guard that quietly stops being
  checked. `pass + fail == 0` is now a failure, in the shared primitive, for every suite in the repo.
- **The `req_absent` call-site invariant excluded three whole FILES**, so a real direct call added
  to any of them passed undetected — the invariant was simply false. Exemption is now PER LINE via
  an `adb-allow: req_absent` marker, which makes every sanctioned occurrence deliberate and
  reviewable and catches a new one wherever it lives.
- **It scanned `*.sh` only**, so `bin/agent-init` and `bin/baseline` — real shell programs with no
  extension — were invisible. It now scans anything with a shell shebang.

Two further corrections in the same pass: `--mutation`'s "files scanned" counted path ARGUMENTS,
so a pinned file that did not exist was reported as scanned (an `absent:`-only path is now a
failure, not a vacuous pass, and only real files are counted); and the new wiring in `selfcheck.sh`
and `ci.yml` was unpinned, so deleting either invocation would have removed the protection while
the `fact-drift` check context stayed green — now pinned by `fact-mutation-wired` and
`fact-guard-wired`.

Recorded rather than silently folded in because it is the decision's own evidence: three layers of
"prove it can fail" still shipped three checks that could not, and an independent reviewer — not
the author — is what found them.

### D22 — second amendment, after the async bot review of PR #230 (2026-07-30)

The Codex connector found two more instances of the same shape, both in code added by the fix:

- **A suite could exit 0 without ever running `check_summary`.** The exit status is the last
  command's, and nothing but `check_summary` consults the `fail` counter — so a truncating edit or
  a stray early `exit` prints `FAIL:` lines and is still reported as passing by selfcheck and CI.
  `check_exit_guard` now installs one EXIT trap that fails closed unless the summary ran, and takes
  the suite's cleanup as an argument so a second `trap … EXIT` can never silently replace it. Wired
  into `check-fact-guard.sh` here; the sweep across the other 22 suites is #231.
- **The new wiring pins were `fixed:` on the command text**, so commenting out the selfcheck line
  and the workflow step would leave both tokens present and both guards un-run — the silent
  unwiring the pins exist to catch, recreated by the pins. They now anchor on `^[^#]*`: an ACTIVE
  invocation. Deliberately not `^[[:space:]]*[^#[:space:]].*TOKEN`, the shape that has now failed
  twice in this file by consuming the first character.

Three rounds of "prove it can fail" — author, independent review, async review — each found
something the previous round did not. That is the argument for the discipline, and also its honest
limit: none of them is sufficient alone.

## D24 — a claim lint that only proves RESOLUTION, and the check that was measured and dropped
- date:      2026-07-30
- category:  project-delta
- unknown:   #212 asked for one `check-claims.sh` covering four claim classes, "run in
             `selfcheck.sh` and as a pre-commit gate", degrading offline by skipping locally and
             failing closed in CI. Three parts of that had no home in the baseline as written: a
             network-dependent step inside a mirror D13 promises is hermetic; a check whose one
             prescribed home (`scripts/check-*.sh` vs the installed `scripts/lib/`) decides whether
             every adopting project inherits it; and a path-claim rule that turned out to be a
             natural-language classifier, which this repo has twice refused to build.
- decision:  Ship three of the four checks, in two halves, and drop the fourth on measurement.
             * `scripts/check-claims.sh` scans the ADDED lines of a range and asserts every `#N`
               resolves / is the kind it is cited as / is not closed `NOT_PLANNED`; every `D<N>`
               resolves to a `## D<N> — ` heading; every added `- date:` in the decision log is
               within a day of the commit that introduced it.
             * The OFFLINE half (decisions, dates) runs in `selfcheck.sh`. The LIVE half (`--live`,
               the `#N` reads) is CI-only and fails closed with exit 3 — it never degrades to a
               pass. `selfcheck` reports how many references it left unverified, so the gap is
               stated rather than silent.
             * An audited per-line `adb-claim-ok: <reason>` escape exists because prose ABOUT an
               abandoned issue is legitimate; a blanket `NOT_PLANNED` rejection is semantically
               wrong, and a gate with no way to say so gets worked around.
             * `scripts/check-claims-guard.sh` drives every rule to RED offline against fixtures in
               a throwaway repo with a stubbed gh, asserting the DESIGNATED exit code and
               diagnostic, and pins the active invocation sites in `selfcheck.sh` and `ci.yml`.
             * The PATH-CLAIM check is NOT in the lint. It moved to a fifth review lens in
               `base/workflows/implement-issue.md` step 8; the controlled-syntax version is #234.
- unmet:     #212's "run it as a pre-commit gate" is NOT delivered, and is named here rather than
             implied away. The lint reads committed revisions, so it runs pre-push (`selfcheck`) and
             pre-merge (CI); nothing scans the index or the working tree and no pre-commit hook
             invokes it. Activation is the genuinely open problem — only Claude has Stop-hook wiring
             today — and it is #233's subject, not something to fake with a claim.
- placement: `scripts/check-claims.sh` + `scripts/check-claims-guard.sh` beside
             `check-fact-drift.sh` / `check-fact-guard.sh` — the prescribed home for a repo lint
             that must NOT ship into a user's runtime (`install.sh` symlinks all of `scripts/lib/`
             into every agent home; `scripts/check-*.sh` never installs). Wired as a `selfcheck`
             step and as steps of the existing `fact-drift` CI job — a NEW job would be a new check
             context branch protection does not require, which is the drift `required-drift`
             exists to flag. Generalizing it into an installed primitive is #233.
- reason:    Two of the three hard calls were forced by existing law rather than chosen.
             D13 says `selfcheck` stays hermetic so a local green is a DETERMINISTIC predictor of
             CI, and names the ONE live assertion it deliberately does not mirror. A second
             network-dependent step inside `selfcheck` would break that promise for every other
             step too — so the split is what D13 already prescribes, and this is NOT a deviation
             from it. `handling-the-unknown`'s table then forces the placement: a check that must
             not reach a user's runtime has exactly one home, and the "would many projects want
             this?" half earns a filed issue rather than a local guess.

             The third call was decided by measurement, against the issue's own stated priority.
             #212 calls the path-claim check "the highest-value" of the four. It is not, and the
             argument for it does not hold: the sentence it cites as its witness named
             `base/roles.md`, and `git show --name-only 9e61dfd` lists that file — the path WAS in
             the diff, and what was false was the KIND of change claimed of it, which no
             "is this path in the diff?" predicate can see. Built and run over the last five
             merges it scored SEVEN false positives and ZERO true positives, in the verb-free form
             and the change-verb form alike, because a changelog is a HISTORICAL document: a
             commit that reflows an older entry re-adds prose making true claims about a different
             commit. This repo's own law says a gate that fires on ordinary prose gets worked
             around and then protects nothing, so shipping it would have cost precision and bought
             no coverage. #212's own follow-up comment already assigns judgement-heavy claim
             validation to the review step, which is where it went.
- baseline-issue: #233 (ship it as an installed primitive), #234 (controlled path-claim syntax),
             #235 (PR bodies are not tracked files), #236 (prove file-then-cite by `createdAt`),
             #237 (audit the pre-existing `NOT_PLANNED` citations)

## D25 — this repo owns its Stop-hook gate, because its `[gates] test` is its own CI mirror
- date:      2026-07-31
- category:  project-delta
- unknown:   The baseline's Stop-hook gate runs whatever `agents.toml [gates]` declares, once per
             TURN. This repo declares `test = "bash scripts/selfcheck.sh"` — its entire ~28-suite
             offline CI mirror — which is correct for the job golden rule 3 gives it (before every
             push) and ruinous at turn-end. One measured Stop-hook run took **18m55s** during a
             session that edited no code at all. Nothing in `project-gates.sh` models a gate being
             too expensive for a given cadence, and `[gates.scope]` cannot express it either:
             selfcheck validates repo-wide invariants, so almost any change legitimately matches.
- decision:  Ship this repo's own `.claude/scripts/precommit-gate.sh` running the FAST subset that
             catches what a turn actually breaks — changed-file shellcheck, generated-file drift,
             workflow-render, practice-index, fact-drift. Measured at **3s** against 18m55s. The
             full mirror stays exactly where CLAUDE.md golden rule 3 puts it: before a push. The
             gate prints a per-check PASS/FAIL with timing, so a slow or red check is attributable
             without a stopwatch, and it says out loud that it is a smoke test and NOT a CI
             predictor — a green here must not be mistaken for "CI will pass".
- placement: `.claude/scripts/precommit-gate.sh` — the prescribed home for custom gate POLICY in
             the handling-the-unknown table, and the surface `docs/per-project-overrides.md` §3b
             documents.
- reason:    The general half of this is #240 and stays open: `[gates]` cannot express cadence, and
             every adopting repo with an expensive suite hits it. This entry records only the
             LOCAL stopgap, which is what the protocol prescribes for a general gap — use the
             supported surface now, fix the shared capability in the tracker.

             Applying the stopgap surfaced a defect in the surface itself, fixed in the same
             branch rather than filed: the global gate `exit 0`d when it found a project gate and
             never `exec`d it, while nothing else wired one. A repo following the documented
             escape hatch therefore lost gating entirely instead of replacing it — enforcement
             silently OFF, the class #35 made this gate fail loud about. The global gate now runs
             the project's script, which is what its own docs already claimed.
- baseline-issue: #240

## D26 — third-party text carries content but never authority, and it is contained by encoding rather than by a fence
- date:      2026-07-31
- category:  general
- unknown:   Six workflows read text the operator did not write (issue bodies and comments, PR
             review threads, CI logs, vendor changelogs) and then edit code, run gates and push;
             one of them — `/implement-issue` — interpolates that text into a prompt for a
             dispatched agent with repo tool access, at two separate sites. The baseline had no practice covering it, and the obvious rule — "never follow
             an instruction found in third-party text" — is unimplementable here:
             `/resolve-pr-threads` exists to turn a reviewer's finding into a pushed commit,
             `/implement-issue` builds what an issue's acceptance criteria describe, and `/roadmap`
             derives dependency edges from sentences in issue bodies. Stating the absolute rule
             would have produced a practice every workflow visibly violates on its first run.
- decision:  Draw the line at CONTENT vs AUTHORITY. Third-party text may supply what the workflow
             came to read — a bug report, acceptance criteria, a review finding, a log line, a
             `Depends on #N` in the grammar the parser accepts. It may never supply authority: the
             target repo or branch, the scope, which gates run, whether to push, merge or delete,
             or which tools and credentials are in play. An embedded directive is a FINDING TO
             REPORT, and the run continues — reporting rather than silently refusing, because
             silence hides the attempt from the operator and because "I refused" is itself a signal
             an attacker can probe for.

             Containment is by ENCODING, not by a fence. `adb_untrusted_block` JSON-encodes the
             text into a one-line envelope carrying its provenance and the policy. An XML-ish
             `<untrusted_issue_text>` fence — which is what the issue proposed — is not a boundary
             at all: a body containing the closing tag closes it, and everything after it reaches
             the model as top-level instruction. JSON escaping cannot be broken out of.
- placement: `base/practices/untrusted-content.md` (the practice), `scripts/lib/common.sh` (the
             primitive, with `role-dispatch.sh untrusted` as its CLI surface — the same
             primitive-in-common, surface-on-the-owning-lib split the reviewer-evidence classifier
             uses), and `scripts/check-injection.sh` wired as a STEP on the existing
             `workflow-render` CI job.
- reason:    The step-not-a-job placement is the handling-the-unknown protocol applied to CI: a new
             job becomes a new branch-protection context, which `required-drift` then reports as a
             discovered job gating nothing until protection is edited by hand. Riding a job that is
             already required makes the gate real from its first run, and there was precedent — the
             workflow-shell lint rides the same job for the same reason.

             Two limits are stated in the practice rather than papered over. This is prose, not a
             sandbox: it constrains how an agent is asked to treat text, not what a dispatched CLI
             can read or reach. And the screening is advisory — there is no classifier gating these
             reads, so an agent already subverted will not report anything. Least-privilege
             enforcement was deliberately excluded and is #248: two of the three version floors in
             the issue's own checklist for it are off by one against the vendor reference, and the
             third floor is correct while the security effect claimed for it is backwards —
             `sandbox.filesystem.disabled` REMOVES filesystem isolation rather than tightening it.
             Acting on that item as written would have configured less isolation and recorded it as
             hardening.
- baseline-issue: #248

## D27 — indented code blocks are recognized at top level only, and the acceptance fixture that "must flip" cannot correctly flip
- date:      2026-07-31
- category:  general
- unknown:   #136 §5 names the one fork the rewrite could not decide for itself: are 4-space
             INDENTED code blocks structure (so a `Depends on #N` inside one declares nothing), or
             are they deliberately out of scope as #117 left them? It offers three options —
             (1) permanent exclusion, (2) full container-aware indent tracking, (3) top-level-only
             stripping — and says to settle it before writing code, because the answer decides how
             much container state the parser has to carry.

             A second unknown surfaced while answering the first. The acceptance list requires that
             "the fixture that currently pins the present behavior is flipped … a rewrite that
             leaves it green has not done the work", naming `check-roadmap.sh` § 6i's 4-space-indent
             exclusion. At HEAD that is exactly one fixture, and its middle line sits at column 0.
- decision:  OPTION 3, made implementable by two bits of block state rather than none. A line opens
             an indented code block only when ALL of: it is indented >= 4 spaces, a paragraph is NOT
             open (the previous line was blank, or structure, or nothing), and no list container is
             open. The block then continues over blank lines and lines indented >= 4, and ends at
             the first non-blank line indented <= 3.

             The two bits are what make option 3 safe, and a stateless `^ {4}` rule is what makes it
             dangerous. `    Depends on #52` is lexically identical at top level and as a
             continuation under a list item, so a stateless rule DELETES real edges — the under-match
             direction, which marks a genuinely blocked bundle `ready`. Both protected shapes the
             issue names still declare: `- item` + 4-space continuation, and `- item` + 6-space
             continuation. So does a lazy continuation of an ordinary paragraph, which CommonMark
             also refuses to read as code ("indented code cannot interrupt a paragraph").

             THE ACCEPTANCE FIXTURE CANNOT CORRECTLY FLIP, and this is the same trap the owner's own
             comment on #136 documented for the #112 bullet. The fixture is three lines: an indented
             backtick run, then `Depends on #5` at COLUMN 0, then another indented run. Under
             CommonMark an indented code block ends at the first non-blank line indented < 4, so the
             middle line is a paragraph and `5` is the correct answer both before and after this
             change. An implementation that turned it empty would have to let an indented block
             swallow lines at lower indentation — which is precisely the under-match this decision
             exists to refuse. What was actually owed is honored instead: that fixture's RATIONALE is
             rewritten (it no longer says indented blocks are out of scope; it now pins that a
             non-indented line ENDS the block), and the §5 repros the issue actually reports —
             `    Depends on #52` and `        Depends on #52` — become new fixtures that go from
             `52` to empty. Both are red without this change.
- placement: `scripts/lib/common.sh` (`_ADB_MD_AWK`, `adb_md_block`), the flipped rationale and new
             fixtures in `scripts/check-roadmap.sh` § 6i, and the rule's prose in
             `base/workflows/roadmap.md` (rendered into all three agents' skills).
- reason:    Option 1 leaves the top-level false edge the issue reports and contradicts its own
             acceptance list. Option 2 is CommonMark-correct and needs list-depth, content-column
             and laziness state carried through every container — a parser this framework has no
             reason to own, and a large surface for the under-match direction to hide in. Option 3
             with a paragraph bit and a list bit costs two integers, is decidable in one line-order
             pass, and errs toward NOT stripping in every case it cannot prove: an unclosed list
             keeps scanning (over-match, visible as a bundle that sits blocked) rather than deleting
             text (under-match, invisible). A leading TAB is deliberately still not counted as
             indentation, for the same reason — miscounting it would delete prose.

             The evidence that this is safe is empirical, not argued. The rewritten filter was run
             over all 193 issue bodies in this tracker and produced a byte-identical edge set, and
             over the whole existing 122-fixture § 6 suite with no expectation changed.

             ORDERING, stated exactly rather than flatteringly. The acceptance list asks for this
             entry "before implementation", and it was written before the code — but it lands in
             the SAME commit, so the diff cannot evidence that and nobody should read it as
             evidenced. What history does show is the substitute that actually matters: the new
             fixtures fail against the parent commit. A future decision of this kind should be
             committed on its own first, which is the only form of the claim a reviewer can check.
- baseline-issue: #136

## D28 — an edge the grammar refused is REPORTED, on a sibling subcommand that shares the one scan
- date:      2026-08-01
- category:  general
- unknown:   #132 asks for a decision before code, and names the fork itself: "Where does an
             ambiguity surface — a second output stream, a `?`-prefixed line, a non-zero exit, or a
             separate subcommand?" Three further questions ride on it: does an ambiguity merely warn
             or make the dependent ineligible; what closed grammar counts as "plausibly attempts a
             declaration"; and how is a report attributed and retired. The gap-analysis pass ran all
             four as BLOCKING.
- decision:  A SIBLING SUBCOMMAND, `deps-ambiguous`, sharing ONE awk scan with `deps-from-body`
             through a mode flag. Output is TSV, `<kind>\t<line>\t<issue>`; empty output and exit 0
             mean nothing was ambiguous.

             The other three options are eliminated by constraints the issue itself states, not by
             taste. A `?`-prefixed line corrupts a stdout every consumer reads as bare numbers. A
             non-zero exit collides head-on with the callers that DO preserve the status — it would
             turn a parse note into a run-ending error on the predicate's most common input. stderr
             is outside the workflow output contract and is already where this library puts real
             failures.

             STATED EXACTLY, because the issue's own framing is not quite right and repeating it
             would be a false claim: it says "every current caller treats non-zero as a hard stop",
             and gap analysis showed two do NOT — the composition sites discard it in a
             `for d in $(…)`. That makes the argument stronger, not weaker (a status-based design
             would have to repair those first), and both are repaired here regardless. What is
             purely additive is the STDOUT CONTRACT: `deps-from-body`s output is byte-identical,
             verified over all 37 open bodies in this tracker, so no caller changes on account of
             the new subcommand.

             SHARING THE SCAN IS THE LOAD-BEARING PART, not an optimization. A report computed by a
             second parser drifts from the grammar it reports on at the first change to either, and
             this is a family (#69, #108, #112, #117, #136) whose entire history is one rule being
             fixed in one consumer at a time.

             IT WARNS; IT DOES NOT GATE. A report renders as a `dep-ambiguous` Reconcile-flags row
             and a retirable `dep-ambiguous:#N` question; nothing feeds a bundle status. Blocking on
             UNCERTAINTY is different from blocking on a known-unsatisfiable edge (`dep-canceled`):
             one false positive would stall a ready bundle indefinitely. This is the trade #78 made
             when it chose `WARN:` over `HOLD`, and the reversal is a status rule in the workflow,
             not a change to this contract — which is why it is safe to ship the smaller half first.

             THE CLOSED GRAMMAR: report what the scan REFUSED, never what it RECOGNIZED and
             correctly excluded. `partial` (a chain declared an edge and dropped a later reference),
             `unparsed` (a reference in the clause, no edge out), `no-hash` (the author wrote
             `issue <N>`). A qualified `owner/repo#5` stays SILENT — the "reach `#` without crossing
             a word character" rule IS the cross-repo guard and it answered correctly; reporting a
             confident answer is what turns a signal into noise. So do a negated clause, a reference
             the next keyword is about to claim, and anything past a clause boundary.

             THE RECORD CARRIES NO BODY TEXT. All three fields come from closed sets — a kind, a
             line number, an issue number. Issue bodies are third-party and this output is rendered
             into a tracked artifact, so echoing a source line would carry arbitrary markup, table
             delimiters or credential-shaped strings into it. There is nothing to sanitize because
             there is no author-controlled byte to begin with.
- placement: `scripts/lib/roadmap-lib.sh` (`_adb_deps_scan`, `cmd_deps_ambiguous`), the rendering
             and question vocabulary in `base/workflows/roadmap.md` (rendered into all three
             agents' skills), fixtures in `scripts/check-roadmap.sh` § 6k.
- reason:    The false-positive budget is the whole design, and it was MEASURED rather than argued.
             A first cut reported 13 sites across this repo's 37 open bodies, and inspecting all 13
             showed a single shape: a reference sitting past a clause boundary — commentary, not a
             dropped edge. `- #81 depends on #79 — **satisfied**, #79 closed COMPLETED (PR #111)`
             reported both the edge it had just declared and a PR number. Bounding the window at the
             same clause boundaries the negation scoping already uses took the corpus to ZERO
             reports while both documented witnesses still fire. That is the number the issue asks
             for when it says noise gets ignored, which is worse than silence.

             The guard was observed failing before it was called done. Eight mutations against a
             throwaway copy of the tree — dropping the clause boundary, the window bound, the
             qualified-reference guard, the self guard on each of its two paths, the partial/
             unparsed split, the negation skip, and the no-hash tightening — each turned exactly the
             fixtures written for it red. One of those runs earned its keep immediately: the two
             self-reference fixtures passed with the guard REMOVED, because a resolvable self
             reference is consumed by the chain and never reaches the window at all. They were
             vacuous, and only the mutation run said so.

             A fail-open in the existing code was fixed in the same change, because the new report
             inherits it otherwise: `awk | sort` reports only sort, so a CRASHED scan answered exit
             0 with no output — which for this predicate means "this body declares no edges" and
             silently unblocks a bundle that is genuinely blocked. Demonstrated against `origin/main`
             (rc 0) and pinned by a fixture that breaks a COPY of the library rather than the tracked
             file. The two composition call sites had the same hole from the other side (`for d in
             $(…)` discards the substitution status) and are now captured.
- baseline-issue: #132

## D29 — the CI runner is chosen for its bash, and every job proves which one it got
- date:      2026-08-01
- category:  project-delta
- unknown:   The baseline models gates, roles and overrides, but has nothing to say about *which
             runner image* a project's CI must use, or how a repo proves at runtime that the
             interpreter it got is the one it requires. #255 made bash 5.3 this framework's runtime
             floor; CI was 26 jobs on `ubuntu-latest`, which is `ubuntu-24.04`, which is bash
             **5.2.21** — below the floor it would be proving. There was no macOS job at all, and
             macOS is where the floor is hardest to reach, because Apple pins `/bin/bash` at
             3.2.57 — still 3.2.57 on macOS 26 per the runner inventory — and 5.3 is reachable only
             through `PATH`.
- decision:  Pin every Linux job to `ubuntu-26.04` (bash 5.3.9, verified from the runner-image
             inventory), add ONE aggregate `selfcheck-macos` job on `macos-latest` that installs
             Homebrew bash + ShellCheck and runs the full offline suite, and give every job a
             `scripts/check-bash-floor.sh --runtime` step that ASSERTS >= 5.3 and prints which
             interpreter it judged, preceded by a bare `bash --version` as the job's FIRST step.
             A static half of the same script lints the workflow so job 27 cannot be added below the
             floor, and `check-bash-floor-guard.sh` drives each of its nine static and three runtime
             rules to red — isolating each where isolation is possible, since a fixture that only
             goes red through some OTHER rule proves nothing about the one it is named for.
- placement: `.github/workflows/ci.yml` (the jobs), `scripts/check-bash-floor.sh` +
             `scripts/check-bash-floor-guard.sh` (the one home for the rule and its negative),
             `docs/ci-runners.md` (the choice, the evidence, and the fallback threshold).
- reason:    Four things forced the shape rather than being chosen freely:

             **No `strategy.matrix`.** `repo-settings.sh` discovery skips matrix jobs because their
             check-run names gain a suffix (`docs/repo-settings.md`). A two-platform matrix would
             leave all 26 required contexts reporting nothing while the 52 suffixed replacements
             stayed undiscoverable — required-but-never-reported, which is the phantom deadlock
             `automerge-ok` code 13 names and which needs an admin token to clear.

             **One macOS job, not 26.** `scripts/selfcheck.sh` IS the full offline suite by
             construction (golden rule 3 keeps it in lockstep). Mirroring the jobs individually
             would need a hand-added job every time a `check-*.sh` lands, and the forgotten one
             would be invisible. The two CI-only steps — `required-drift` and the live claim lint —
             assert facts about settings and the tracker, which are platform-independent.

             **The guard asserts `$BASH`, not just `command -v bash`.** On macOS those diverge
             exactly when it matters: under `/bin/bash` 3.2 with Homebrew first on `PATH`,
             `command -v bash` reports the 5.3 while the code runs on the 3.2. Verified locally —
             same script, two invocations, `command -v bash` identical, `$BASH` 3.2.57 vs 5.3.15.
             A guard reading only `PATH` would have passed on the 2006 interpreter.

             **ShellCheck is installed on the macOS job on purpose.** selfcheck SKIPs that step
             when the binary is absent and the macOS image ships none, so without it "the full
             suite runs on macOS" would be false in exactly the silent way this repo writes guards
             against.

             The runtime half is deliberately NOT run by `selfcheck`: pinning a local gate to the
             real floor would fail a contributor still on 5.2, which is #256's enforcement to
             introduce with install instructions — not this lint's. Its negative test drives
             `ADB_BASH_FLOOR` instead, so it holds identically on 3.2 and 5.3.

             `ubuntu-26.04` is a public-preview image, accepted knowingly as the only hosted Linux
             label that clears the floor. The fallback threshold is written down rather than left
             to taste: fall back for image/provisioning failures, never for a reproducible test
             failure caused by the newer toolchain — that is a real finding, and
             `base/practices/debugging.md` applies.
- review:    An independent pass found SIX fail-opens in the first cut of the lint, every one of
             them the same species this repo keeps paying for — a guard reporting a clean run while
             checking less than it claimed. Recorded because the fixes are the design, not polish:

             * `ADB_BASH_FLOOR` was an unvalidated bypass. `adb_version_ge` reads a non-numeric
               component as 0, so `x`, `-1` and the Arabic-Indic `٥.٣` each let bash 3.2.57 pass —
               all three reproduced. Now a malformed floor is a hard error, and a workflow that sets
               the variable at all is itself a lint failure (the only place the bypass could be
               applied at scale, and the one the guard cannot see from inside itself).
             * An INLINE flow-mapping job (`hidden: {runs-on: …, steps: […]}`) was invisible: the
               job-key rule required the key alone on its line, and a per-file zero-jobs rule cannot
               see PARTIAL blindness. Any two-space key under `jobs:` is now a job.
             * `runs-on: "ubuntu-26.04 # not-the-label"` was truncated to an approved label by
               stripping comments BEFORE quotes. This is the concrete cost of the second YAML
               reader: `repo-settings.sh`'s `yaml_scalar` already had the order right, and the two
               had drifted before either shipped.
             * `defaults: {run: {shell: sh}}` routes every step around bash and a line-anchored
               `^shell:` grep never saw it.
             * The guard invocation in an `env:` value satisfied a bare substring test while
               executing nothing; it is now anchored to a `run:` line.
             * Two harness assertions did not isolate their rules — the zero-total-jobs fixture went
               red through the per-file rule, and the 99.0 runtime fixture failed BOTH comparisons at
               once. The redundant rule is deleted and the runtime rules are now isolated with an old
               `/bin/bash` at the real floor and a stale-bash-on-PATH stub respectively, each proven
               by deleting its target rule and watching only its own assertions fail.
- consequence: `selfcheck` is no longer an unqualified predictor of CI, and the claim was narrowed
             wherever it appears rather than left standing. It predicts the OFFLINE checks on ONE
             platform; CI now runs them on two. That does not change D13/D24's hermetic-gate rule —
             the set of things a local green cannot predict simply grew, and the honest statement
             of it is in `scripts/selfcheck.sh`'s header, `CLAUDE.md`, `CONTRIBUTING.md` and
             `docs/repo-settings.md`.
- baseline-issue: n/a — this is how THIS repo proves its own floor. The general question (should
             the baseline model a runner/interpreter floor for adopting projects?) is #255's to
             answer once #256 and #261 have settled what the floor demands of an installed repo.

## D30 — the file that installs the floor is the one file exempt from it
- date:      2026-08-01
- category:  project-delta
- unknown:   #255 made bash 5.3 the runtime floor and #258/#259 will spend it — associative arrays,
             namerefs, `mapfile`, `${ command; }` across `scripts/lib/` and the check suite. #256
             puts the enforcing gate (`adb_require_bash`) in `scripts/lib/common.sh`. Those two
             facts are in direct conflict and nothing in the baseline models the conflict: a caller
             cannot reach a function in a library until sourcing that library has finished, so a
             5.3-only construct anywhere in `common.sh` makes the gate unreachable on precisely the
             hosts it exists for — the sub-floor ones. The gap-analysis pass named it a bootstrap
             paradox and treated it as blocking.
- decision:  `scripts/lib/common.sh` stays **parseable by the interpreter it is upgrading FROM**,
             permanently. It is the one file the 5.3 modernization must skip: no `mapfile`, no
             `readlink -f`, no associative arrays, no namerefs, no `${ command; }`. Recorded in its
             own contract header (where an editor is standing when they would break it), in golden
             rule 4, and in `CONTRIBUTING.md`.

             This also settles the OTHER half of the same premise. Both #256 and #261 assert that
             `install.sh` "cannot source `common.sh` — it is what installs it", and ask for a
             standalone copy of the gate as a documented exception to *source, never copy*. The
             premise is false: `install.sh` runs **from** the clone it installs and already sources
             `common.sh` (`install.sh:24`). The copy was therefore not implemented. It would have
             bought nothing and cost a second implementation of candidate resolution, version
             comparison and per-platform diagnostics, free to drift from the first — the exact
             failure `docs/design-principles.md` forbids. What actually makes the installer able to
             source the gate is the carve-out above, not a duplicate.
- placement: `scripts/lib/common.sh` contract header; `CLAUDE.md` golden rule 4; `CONTRIBUTING.md`;
             pinned by `check-fact-drift.sh`'s `bash-floor-bootstrap-carveout` rule so a later
             modernization pass cannot quietly delete the explanation.
- reason:    A carve-out that lives only in an issue is a carve-out the next agent removes. #258 and
             #259 are explicitly chartered to modernize `scripts/lib/` and the check suite, so the
             file most likely to be "cleaned up" is the one that must not be. Writing the rule where
             the edit would happen — and pinning it with a lint — is what makes it survive.
- baseline-issue: n/a — this is a property of THIS repo's bootstrap, not a general practice. An
             adopting project with a floor of its own would face the same shape, but the baseline
             does not model runtime floors for adopters yet; #255 owns that question.

## D31 — an entry point either gates its interpreter, degrades, or observes — and the set is closed
- date:      2026-08-01
- category:  project-delta
- unknown:   #256 says "every process entry point" calls the gate and "every entry point exits
             non-zero" below the floor. Three shipped files contradict that in their own headers:
             `session-currency.sh` exits 0 on every path because a non-zero SessionStart hook
             renders an error notice on every session start; `statusline.sh` renders one cosmetic
             string on every render; `state-claim-gate.sh` deliberately refuses to wedge a session
             over infrastructure absence (#35). A fourth, `check-bash-floor.sh`, is #257's
             *observer* — and `check-bash-floor-guard.sh` runs it under an old `/bin/bash` and
             asserts it reports red (the assertion named *"the $BASH rule fires ALONE"*), so wiring
             the gate into it would silently un-test that. Cited by assertion name rather than by
             line: this very entry named a line number that the same PR then moved 22 lines down.
             The issue's own call-site list omits all four; nothing said what to do about them.
- decision:  Three classes, forced and enumerated in `scripts/check-bash-floor.sh`:
             **gate** (`adb_require_bash` — re-exec, else exit non-zero; the default, 55 files),
             **advisory** (`adb_require_bash_advisory` — same re-exec, RETURNS instead of exiting;
             the three files above), and **exempt** (must NOT call it; `check-bash-floor.sh` alone).
             `--entrypoints` fails the build on a shebang-bearing file that is unclassified, calls
             the wrong form for its class, calls it in a comment, or calls it after a `cd` or a
             stdin read.
- placement: `scripts/check-bash-floor.sh` (`ADVISORY_ENTRYPOINTS` / `EXEMPT_ENTRYPOINTS`, each with
             its reason); every rule driven to red in `scripts/check-bash-floor-guard.sh`.
- reason:    "Fail closed" is right for a gate and wrong for a statusline: hard-failing there makes
             a sub-floor host look BROKEN rather than out of date, on every render, which is worse
             than the degraded behaviour those files already promise. But *advisory* must not become
             a dial the next script quietly picks, so the classification is bidirectional — a
             declared-advisory file using the hard form fails the lint too — and the exemption is
             asserted rather than implied, because an exemption that looks like an oversight will be
             "fixed" by someone.

             The lint checks POSITION, not just presence, and that is the half a grep cannot do.
             `$0` is frozen at invocation and is relative when invoked relatively, so a call after a
             `cd` may be unable to name its own script; and a hook that has already drained its
             payload from stdin cannot get it back, because the re-exec restarts the script with
             that fd inherited. Both are silent failures.
- review:    Building the negative harness immediately found a defect in the gate itself, which is
             the argument for building it: `_ADB_BASH_REEXEC` is **exported**, so a re-exec'd parent
             handed the loop sentinel to every child, and a child starting on the old interpreter
             then read "already attempted" and failed closed instead of repairing itself.
             `selfcheck.sh` is exactly that shape — it re-execs, then spawns ~30
             `bash scripts/check-*.sh`, each resolving `bash` through the same wrong `PATH` — so
             every one of them would have died on a machine with a shadowed Homebrew prefix. The
             fix clears the sentinel once the version check has PASSED, which keeps it a loop guard
             (an exec chain that has not yet reached a good interpreter still carries it) while
             stopping the leak. Pinned by a fixture that was watched failing without the fix.
- baseline-issue: n/a

## D32 — Windows via WSL2: the checkout is the delta, and the CI leg is sliced
- date:      2026-08-01
- category:  project-delta
- unknown:   #2's rewritten body scopes Windows support to WSL2 and lists three items: docs, a
             CRLF + `/mnt/` preflight, and a CI shape. The third asks for a WSL smoke job on a
             release/weekly trigger that "has been seen green at least once". Two things make that
             unreachable from this PR, and the baseline models neither.
- decision:  Ship items 1 and 2 in full; **slice item 3** into its own tracked issue. #2 is
             therefore `Refs`, not `Closes`.
- placement: `docs/installation.md` §7 (prerequisites table + the WSL2 section); `adb_crlf_scan` /
             `adb_crlf_remedy` / `adb_drvfs_warn` in `common.sh`, preflighted by `install.sh`;
             `.gitattributes`; fixtures in `check-bash-floor-guard.sh`. CI leg → a follow-up issue.
- reason:    Two independent blockers, both structural rather than a matter of effort. **A
             scheduled or manually-dispatched workflow must already exist on the default branch
             before it can run**, so "seen green" cannot be satisfied by the PR that introduces it —
             any claim otherwise would be the unverified support claim
             `base/practices/verify-before-asserting.md` exists to stop. And a Windows job would
             have to change #257's workflow grammar, which just shipped: `check-bash-floor.sh`
             allows only proven Linux/macOS labels and rejects every `shell:` key, both of which a
             WSL job needs. Widening a guard that is one PR old, to accommodate a job that cannot be
             verified in the same PR, is two risks stacked. The distro question is also open — the
             common `setup-wsl` action's supported list stops at Ubuntu 24.04, which is *below the
             floor*, so the job needs a custom 26.04 import that nothing here has exercised.

             The CRLF preflight ships with its boundary stated rather than implied: a **fully**
             CRLF-corrupted checkout cannot run it, because `./install.sh` dies on its own `bash\r`
             shebang first. `.gitattributes` is the guarantee for a fresh clone; the preflight
             catches the already-cloned and partially-corrupted cases; `docs/installation.md` names
             the `bash: $'\r'` symptom so the unrunnable case stays diagnosable by a human.

             **Review narrowed that boundary once already, and the correction is the interesting
             part.** The first cut could not protect the very file it depends on: `install.sh`
             sources `common.sh` BEFORE the scanner runs, and the scanner selected files by
             SHEBANG — which a sourced library does not have. A checkout with only `common.sh`
             converted therefore emitted raw `$'\r': command not found` from inside a library the
             user has never heard of, while a direct scan afterwards reported the tree clean. Both
             halves are fixed: a nine-line CR check on `common.sh` runs BEFORE the source (the one
             place a standalone snippet is unavoidable, because it guards the loading of all shared
             code), and the scanner now selects on `*.sh` OR a shebang, so sourced libraries and
             extensionless commands are both in scope.

             Two details corrected against the issue text. Its suggested repair, `git checkout .`,
             is one of the commands `base/practices/git-and-prs.md` names as destroying uncommitted
             work with no reflog to recover it — the remedy leads with re-cloning inside WSL
             instead. And the `/mnt/` warning matches the Windows **drive** shape
             (`/mnt/<letter>/`) under WSL only, not a bare `/mnt/` prefix.

             **That second one is a DEVIATION from the issue's literal acceptance criterion, and is
             recorded as one rather than quietly satisfied:** #2 says a `/mnt/` path warns.
             `/mnt/data` and `/mnt/nfs` are ordinary Linux mountpoints on machines that have never
             seen Windows, and warning there is the kind of noise that teaches people to ignore the
             real warning. The criterion is met in spirit, not to the letter.
- baseline-issue: n/a. The CI leg is tracked by **#2 itself, which stays OPEN** — the PR `Refs` it
             rather than closing it. No child issue was filed on purpose: #2's remaining scope is
             exactly this one item, so a second issue would be the duplicate
             `base/practices/issues-and-scope.md` calls worse than a gap ("it splits context and
             doubles triage"). The requirement that practice actually imposes is that deferred work
             live in an OPEN ISSUE rather than a PR-body note, and #2 satisfies it.

## D33 — #258's acceptance list was written before D30, and D30 wins
- date:      2026-08-02
- category:  project-delta
- unknown:   #258 ("modernize `scripts/lib/`, adapters and hook scripts") was filed against a tree
             where `scripts/lib/common.sh` was in scope. D30 then exempted that file permanently
             and named #258 as the thing it constrains. Nothing said what happens to the issue's
             acceptance list, and four of its six checkboxes turn out to be affected — two of them
             unsatisfiable as literally written. An implementer reading only the issue would either
             break the bootstrap carve-out or report criteria met that were not.
- decision:  D30 wins; #258's list is honoured as narrowed below, and the narrowing is recorded
             here rather than re-derived by the next reader.
             1. "Zero bash-3.2 workaround comments in `scripts/lib/`" — **narrowed** to the
                non-bootstrap files. `common.sh` KEEPS its 3.2 rationale by design (D30 pins the
                word `parseable` there via `check-fact-drift.sh`'s `bash-floor-bootstrap-carveout`),
                so a literal reading of this box requires deleting the carve-out it must preserve.
                Met for the eligible set: the four accommodation sites are gone. What remains in
                those files is PAST-TENSE history of what changed and why, which is retained
                deliberately — deleting it makes the next reader re-derive the shape of the code.
             2. "`skill-compose.sh` returns via nameref" — **met**, and see the API note below.
             3. "The temp-dir-as-map and parallel-array patterns are gone in favour of `declare -A`"
                — **vacuous**: no such pattern exists in the eligible files. There is no `eval`-as-
                map, no `mktemp -d` used as a map (`project-gates.sh`'s is a per-run log dir — what
                `check-gates.sh` asserts about it is the FAILURE path, that a failed `mktemp -d`
                must not `rm -rf` the shared temp dir; the successful cleanup is unobserved, so
                deleting it would leak a log dir per run and leave the suite green), and no
                key/value array pair. The map-shaped
                code that does exist is inside awk programs, which have had associative arrays since
                1977. Nothing was converted, because converting the ordered lists that ARE there
                (`skill-compose.sh`'s `names`, `statusline.sh`'s `parts`) to an unordered container
                would lose ordering their callers depend on.
             4. "`adb_run_bounded` and `pr-watch.sh` time against `BASH_MONOSECONDS`" — the
                `pr-watch.sh` half is **met**; the `adb_run_bounded` half is **refused**, because
                that function is in `common.sh`. Referencing `BASH_MONOSECONDS` there would parse
                below the floor (it is an ordinary expansion), so this is not the bootstrap paradox
                D30 was written for — it is refused on D30's plain terms instead: `common.sh` is the
                one file the modernization skips, and a carve-out that admits a first exception on a
                judgement call is not a carve-out. The gain forgone is small and worth naming: the
                `$SECONDS` reference there guards ONE heuristic (normalizing GNU `timeout`'s 137 to
                124 when the bound really did elapse), so a clock step would at worst mislabel an
                already-failed run's status.
             5. "Every existing `check-*.sh` still passes, on all three platforms" — **met for
                two.** CI runs this suite on `ubuntu-26.04` and `macos-latest`; there is no
                Windows/WSL2 job, because D32 sliced that CI leg and **#2 stays open to track it**.
                Reporting three platforms would be a claim no run supports.
             6. "shellcheck still clean (may need a `--shell=bash` version bump)" — **met, no bump
                needed**, but the premise is wrong twice and #259 will hit the second one. It
                conflates shell MODE with tool VERSION: mode is already selected by each file's bash
                shebang, and CI pins no version at all (apt on Ubuntu, brew on macOS). Measured on
                0.11.0, `${ command; }`, `mapfile`, `${var,,}` and `declare -A` all parse clean.
                **Namerefs do not, quite:** `SC2034 "appears unused"` fires on a nameref local that
                is only ever assigned — which is exactly the output-parameter shape #258 asks for,
                since the read happens in the caller's scope through a name shellcheck cannot
                follow. It needs an explicit `# shellcheck disable=SC2034`. `adb_sc_paths` carries
                one; without it that file was clean only because its collision `case` arm happens to
                mention the three names, which is luck, not cleanliness.
             **The issue's one non-checkbox request is dispositioned too**, because a reconciliation
             that covers only the boxes leaves the next reader to re-litigate the rest. #258 invites
             a pass over four long functions — `cmd_roll` (`release-convention.sh:429`),
             `_adb_deps_scan` (`roadmap-lib.sh:787`), `cmd_check` (`currency-lib.sh:185`) and
             `cmd_gate` (`pr-review.sh:137`) — on the stated grounds that "associative arrays and
             namerefs are exactly what they were missing". All four were inspected; none of them was
             missing either. `_adb_deps_scan` is 207 lines of **awk**, a language with associative
             arrays since 1977 and no namerefs to want, so the premise does not apply to it at all;
             the other three are control flow and API sequencing, not data structures. No concrete
             transformation is specified and none is implied by the constructs named, so nothing was
             changed. This is recorded as *inspected and inapplicable*, not as skipped.
- placement: this entry; `CHANGELOG.md` [Unreleased]; and restated in the implementing PR's body so
             the issue's reader and the diff's reader see the same list.
- reason:    An acceptance list that cannot be satisfied is not a standard, it is a trap: the next
             agent either breaks D30 to tick box 1, or ticks box 3 by inventing a `declare -A`
             refactor of code that has no map in it. Both were live risks — the gap-analysis pass
             classified all three of these as BLOCKING and stopped. Writing the reconciliation down
             once means the issue can close honestly instead of staying open against boxes that
             describe a tree that no longer exists.
- review:    Building U2 in `check-implement-gate.sh` found a REAL defect that the floor itself had
             made universal, which is the argument for treating a "comment-only" modernization as
             code. (Precisely: the reliance arrived with #180; until #256 the shebang was a bare
             `#!/usr/bin/env bash`, so the behaviour depended on which interpreter `PATH` resolved —
             stock macOS gave 3.2 and the safe discard, a Homebrew-first `PATH` gave 4.2+ and the
             retention. #256's re-exec removed the coin flip in the unsafe direction.)
             `this_session()` in `implement-issue-gate.sh` relied on bash 3.2 DISCARDING partial
             input when `read -t` fires, and said so. bash >= 4.2 KEEPS it (measured: 3.2 returns
             status 1 with an empty variable, 5.3 returns 142 with the bytes), so on the floor
             interpreter a writer that sent a complete payload and never closed the pipe had its
             session id ADOPTED — and the Stop hook then fell silent for a marker it should have
             enforced. Only jq's refusal to parse a truncated object was preventing the same thing
             for partial writes, which is luck, not a rule. The existing bound fixture (case U)
             could not see it: it writes no bytes at all, so it cannot tell a discard from a
             retention. The discard is now explicit (`rc > 128`) and U2 pins it.
- baseline-issue: n/a — this is a scope reconciliation between two of THIS repo's own records.

## D34 — `adb_sc_paths` takes output-variable names, and validates them
- date:      2026-08-02
- category:  project-delta
- unknown:   #258 requires `skill-compose.sh:264` to "return via nameref, not globals". The function
             is `adb_sc_paths` — no underscore prefix, so by this repo's naming convention it reads
             as a PUBLIC surface of a library that `install.sh` symlinks into every consumer's
             `~/.<agent>/scripts/lib`. Changing how a public function returns is a compatibility
             question the issue does not answer, and the gap-analysis pass raised it as needing an
             owner decision.
- decision:  Converted, with no compatibility shim. The function's OUTPUTS were `_sc_base`,
             `_sc_ov` and `_sc_out` — underscore-prefixed, i.e. private by the same convention that
             made the function name look public. A consumer could only have depended on this by
             reading names the repo marks private, and a tree-wide search found no reader outside
             `skill-compose.sh` itself (three call sites, all updated in the same commit). So the
             surface that looked public had no public part to preserve.

             The nameref conversion VALIDATES its three output names — a plain identifier, not
             colliding with the function's own locals, all three distinct — and returns 2 rather
             than warning. That is not defensive garnish: `declare -n ref=$x` EVALUATES an array
             subscript inside `$x`, so an unvalidated output name is an arbitrary-command-execution
             seam in a library that installs into consumer repos. The other two rejections cover
             the nameref failures that are SILENT — a circular reference leaves the caller's
             variable unset (it would compose against an empty path), and three names that are one
             variable would make all three paths equal to the last assignment.
- placement: `scripts/lib/skill-compose.sh` (`adb_sc_paths` and its three callers); fixtures S1-S15
             in `scripts/check-skill-compose.sh`, which call the function DIRECTLY — every
             pre-existing assertion reaches it through the CLI and can only observe the file it
             eventually wrote, so none of them can see a return convention at all.
- reason:    A shim for a contract nobody held would be permanent cost for zero protection, and
             `docs/design-principles.md` already forbids the second implementation it would create.
             The validation is here rather than left to bash because the seam is real and the two
             non-security failures are silent, which is the failure mode this repo's self-review
             practice singles out as worse than a crash.
- baseline-issue: n/a

## D35 — the below-floor set is three files, and the rule is "who reports the bad interpreter"

- date:      2026-08-03
- category:  project-delta
- unknown:   D30 exempts `scripts/lib/common.sh` from the 5.3 floor by name, and names #258/#259 as
             the issues that must skip it. #259 then asks for **all** of `scripts/check-*.sh` to be
             modernized. Nothing in the baseline says whether the floor OBSERVER — which D31
             deliberately exempts from the runtime gate so it can run on a below-floor interpreter —
             is also exempt from 5.3 *syntax*, and nothing at all says what happens to a file the
             observer SOURCES.
- decision:  Three files, not one, and all three ENFORCED rather than two enforced and one assumed.
             `scripts/lib/common.sh` (D30), `scripts/check-bash-floor.sh`
             (the observer), and `scripts/check-lib.sh` (which the observer sources at line 35)
             must stay EVALUABLE below the floor. The rule that decides membership is not "is it a
             library" but **"does this code have to run in order to report that the interpreter is
             too old"** — everything on that path is exempt, transitively, and everything else is
             not. `check-bash-floor-guard.sh` DOES gate its own interpreter and is not exempt.

             Measured rather than assumed, because the failure is subtler than a syntax error:
             bash 3.2 PARSES `${ command; }` (a `bash -n` over the converted observer is clean) and
             fails at EXPANSION, so the observer's whole diagnostic is replaced by one
             `bad substitution` line while the exit status stays 1. An rc-only assertion sees
             nothing wrong. Proven by converting a COPY of the tree and running
             `/bin/bash scripts/check-bash-floor.sh --runtime`: pristine prints
             `running interpreter /bin/bash (3.2.57)`, converted prints only the bad-substitution
             line.
- placement: `scripts/check-bash-floor-guard.sh` — a source scan asserting that none of the three
             contains `${ …; }` / `${| …; }`, plus negative tests on copies. A SOURCE scan rather
             than an execution because the existing under-3.2 case is guarded on `/bin/bash`
             genuinely being 3.2 and therefore skips on every Linux runner, while this invariant
             has to hold on both.

             `common.sh` IS in the scanned set even though D30 already covers it in prose. Review
             asked why it was omitted, and the answer was that D30 "already says so" — which is the
             same reasoning that left the observer unpinned in the first place. A rule stated in a
             decision and enforced nowhere is the one a sweep erases.

             The predicate drops WHOLE-LINE comments only. The obvious `sed 's/#.*//'` — the idiom
             the `sort -V` ban uses — has no idea about quoting, so `printf '#'; x=${ printf hi; }`
             is truncated at the quoted hash and the funsub after it is invisible. Review found
             that; it is now one of the negative tests, alongside an injected funsub, an ordinary
             `${VAR}` expansion, and a whole-line comment that documents the hazard.
- reason:    D30's own wording — "a caller cannot reach that function until sourcing has finished,
             so a 5.3-only construct there makes the gate unreachable on exactly the hosts it exists
             for" — is an argument about *reachability on an old interpreter*, not about that one
             file. The observer is the same argument one step further out: it is the thing that
             TELLS you the interpreter is too old, so it cannot require the new one. Leaving that
             implicit is what a mechanical sweep erases, which is why it is pinned rather than
             written down.
- baseline-issue: n/a

## D36 — #259's acceptance list, narrowed on evidence

- date:      2026-08-03
- category:  project-delta
- unknown:   #259 states five acceptance criteria in absolute terms ("no bash-3.2 workaround
             comments remain", "helper-function and `printf` substitutions use `${ command; }`",
             "passes on all three platforms"). The gap-analysis pass classified four of the five as
             literally unsatisfiable. D33 is the precedent — #258's list was likewise written
             before the constraint that governs it — so the same treatment applies rather than
             either failing the issue or quietly under-delivering.
- decision:  Delivered as narrowed, one criterion at a time:

             1. **"No bash-3.2 workaround comments"** → no *workaround* remains. Three classes of
                3.2 MENTION deliberately stay, and each is load-bearing: the floor observer and its
                guard suite (which build and execute real 3.2 fixtures), `check-fact-drift.sh`'s
                negative-pin rules and their `fires:` witnesses (which must spell the retired
                strings to be firable at all), and `check-implement-gate.sh`'s account of the
                `read -t` divergence, which explains why case U2 exists. That last one was
                re-measured rather than trusted: 3.2 returns status 1 with an empty variable, 5.3
                returns 142 with the bytes — exactly as written. Where the constraint is gone but
                the shape is right, the rationale is REWRITTEN, not deleted (#258's precedent).
             2. **`check-claims.sh` caches in a `declare -A`** → delivered in full.
             3. **"Helper-function and `printf` substitutions use `${ command; }`"** → delivered for
                the ELIGIBLE, audited set. Counted per commit with one quote/heredoc-aware scanner,
                over the IN-CODE sites (a `$( )` inside a comment or a heredoc is prose or fixture
                text, not a substitution this repo runs):

                    origin/main   2208 in-code      (2249 spans incl. comments/heredocs)
                    + the sweep    646   (-1562)
                    + structural   644     (-2)     one `cat "$CACHE/$n"` replaced by a map read,
                                                    one `$(printf '\t')` replaced by `$'\t'`
                    + the markers  644     (+0)     markers and line joins move no substitution

                So **1,564 of 2,208 in-code sites eliminated, 644 left by design.** The sweep's own
                report said "1,562 of 2,251" because it ran on a working tree that already carried
                two new explanatory comments, each of which quotes `$( )` in prose; the scanner
                counts those as spans and the conversion correctly does not touch them. Both
                framings are recorded because they answer different questions — what the tool did,
                and what the tree now holds. The criterion as written is a
                LEXICAL test on the first word, and the safe set is smaller, because `${ ; }` also
                stops containing what the body does. What is excluded, and why:
                  * 546 an external binary (the issue itself says not to churn these);
                  * 52 a multi-line body; 24 in a comment; 16 in a heredoc (prose and fixture text);
                  * 21 in a file that must stay evaluable below the floor (D35);
                  * 20 with no leading command word;
                  * 8 the `cmd 2>&1 >/dev/null` stderr-only capture, and 2 an unquoted
                    word-splitting context. These two are NOT safety: bash treats both spellings
                    identically (probed both ways), but shellcheck 0.11.0 models only `$( )` and
                    fires SC2043/SC2069 on the funsub, so converting would buy nothing and cost a
                    `# shellcheck disable=` line.
                A helper that assigns a global, `cd`s outside a subshell, or calls `exit` is
                excluded too — `exit` inside a funsub kills the whole harness (verified). Two such
                helpers were FIXED rather than excluded (`rc_snip`, `runs`), because both were
                latent hazards that only the subshell was containing.
             4. **"`selfcheck.sh` passes on all three platforms"** → met for the two CI actually
                runs, `ubuntu-26.04` and `macos-latest`. There is no WSL2 leg; D32 sliced it and #2
                tracks it. Same narrowing D33 applied to #258.
             5. **Report the measured before/after wall clock** → delivered, and the issue's
                *premise* is corrected rather than confirmed. #259 attributes the 18m55s to "`gh`
                network round-trips"; `selfcheck` is hermetic (roadmap stubs `gh`, claims omits its
                live half), so there are none. The ~1% prediction survives anyway, for a different
                reason: a subshell fork is ~0.30 ms (measured), and even several thousand runtime
                sites is single-digit seconds against a run of this length.
- placement: this entry; the PR body carries the measurements and the per-suite equivalence proof.
- reason:    An acceptance list is a statement of intent written before the code was read. Where
             reading it proves a criterion cannot hold, the honest move is to say which one, why,
             and what was delivered instead — not to force it and break a guard, and not to call
             the issue done while quietly meeting less. Every narrowing above is backed by a
             measurement or a proof in the tree, not by preference.
- baseline-issue: n/a

## D37 — #260's acceptance target was already met before the change, and the runner became a guard
- date:          2026-08-03
- category:      project-delta
- unknown:       Two things the baseline does not model. (1) An acceptance criterion that a
                 measurement *falsifies* — #260 asks for "under 6 minutes on an 8-core machine",
                 and the suite already did that before a line was written. (2) What a step
                 orchestrator owes when it stops being straight-line code: `selfcheck.sh` went
                 from 39 sequential inline steps — most an `if bash …; then` line, some a
                 multi-command block — none of which could lose a failure, to a job pool, which
                 can.
- decision:      Build the work as specified, correct the premise in the tree rather than in the
                 PR body alone, and give the runner its own guard suite.
                 1. **The measurement, taken before the branch existed.** Pre-change HEAD
                    (`00340a1`), 10-core macOS, bash 5.3.15: **272.63s** and **279.48s**. After:
                    **66.20s**, **69.69s** and **71.97s**. `--serial` on the new code:
                    **283.56s** and **298.07s** — the pre-change wall clock plus the ~9.8s the
                    one added step costs, within run-to-run variance. The gap-analysis pass measured
                    310.66s independently and reached the same conclusion.
                 2. **The 18m55s figure is corrected where it is restated** (`CLAUDE.md`,
                    `.claude/scripts/precommit-gate.sh`), not deleted. It was a real observation
                    that did not reproduce; that run was not instrumented, so no cause is
                    asserted. The decision it justified — D25's fast Stop-hook
                    subset — survives without it: 66s at the end of every turn is still the wrong
                    trade. What is removed is the implication that 18m55s is the suite's cost.
                 3. **`build-drift` alone is pinned to a serial prologue.** It runs `build.sh`,
                    which rewrites tracked generated files, and the root-doc render is a plain
                    `> "$outfile"` truncate-and-write — so a concurrent reader of
                    `agents/*/CLAUDE.md` can see a half-written file. Everything else reads the
                    tree or works inside its own `mktemp -d`; the `gh`-shaped suites drive stubs
                    (D13), so there is no rate limit to serialize on.
                 4. **Output ordering is a contract, and it is completion order.** A failure
                    surfaces when it happens rather than behind a straggler, and `--serial`
                    supplies declaration order for debugging. The `FAILED: <names>` line is the
                    second-to-last — immediately before the verdict, which stays last as the
                    recognisable terminal contract — because `project-gates.sh` tails only the
                    final few KB on failure.
                 5. **`scripts/check-selfcheck.sh`.** The pool's failure mode is silence, and no
                    existing check would notice it, so the suite was driven to RED against five
                    deliberately broken copies of the runner — a dropped exit status, a
                    misattributed pid, unbuffered output, a pool of one, and an empty `--only` that
                    widened instead of narrowing. That is the core of the dispatcher, not literally
                    all 53 assertions, and the distinction is stated rather than rounded up.
- placement:     `scripts/selfcheck.sh` (the runner + its concurrency-contract header);
                 `scripts/check-selfcheck.sh`; this entry; the PR body carries the full
                 measurement table.
- reason:        An acceptance number written before the code was read can be wrong, and #260's
                 was — it was satisfied by the status quo. Meeting it silently would have let a
                 4x improvement be reported as "target met" while the target proved nothing, and
                 dropping the work because the target was stale would have delivered nothing.
                 Measuring first, saying which criterion cannot discriminate and why, and fixing
                 the falsified claim where it lives is the honest third option — the same move
                 D36 made for #259's list. The guard suite is not garnish: a dispatcher that
                 loses a status reports what a clean run reports, which is the exact failure this
                 repo keeps writing guards against.
- baseline-issue: n/a

## D38 — the Windows leg is one scheduled job, and the host's own bash is why the lint needed a third class
- date:      2026-08-03
- category:  project-delta
- unknown:   #2's last open item — the CI shape for Windows/WSL2. D32 deliberately left three things
             unresolved: the trigger, the distro mechanism, and how #257's workflow grammar could
             admit a Windows job without weakening what it proves for Linux and macOS.
- decision:  Ship **one** `windows-latest` job in **its own workflow file**, on a weekly `schedule`
             + `workflow_dispatch` + `push: tags`, installing **Ubuntu 26.04** into WSL2 via
             `wsl --install` and running the real installer plus the full `selfcheck.sh` on a clone
             that lives on the Linux filesystem. Give `check-bash-floor.sh` a **WSL-host class**
             rather than widening the existing allowlist.
- placement: `.github/workflows/wsl-smoke.yml`; `APPROVED_WSL_HOST` + the WSL rules in
             `scripts/check-bash-floor.sh`; red fixtures in `scripts/check-bash-floor-guard.sh`;
             `docs/ci-runners.md` ("Windows: the host clears the floor, and that is the problem").
- reason:    **The generic widening was a trap, and it is the finding worth recording.**
             `windows-latest` (Windows Server 2025) ships Git-Bash **5.3.15**, which *clears this
             repo's floor*. So the ordinary rule — `run: bash scripts/check-bash-floor.sh
             --runtime` — PASSES on that runner without ever entering WSL, proving the floor for
             native MSYS2: precisely the userland #2 ruled out of scope. Adding the label to
             `APPROVED_RUNNERS` and stopping would have produced a green Windows job that proved
             the floor for an unsupported runtime, and no other assertion in the suite would have
             noticed — the silent-guard failure mode `base/practices/self-review.md` exists for.
             Hence a class whose defining rule is `wsl -d <distro> -- …`, with `-d` required
             because a bare `wsl --` runs the image's *default* distro rather than the installed
             one, and with the distro's `bash --version` logged BEFORE the guard, because a version
             printed after the proof describes a run already asserted about. The converse is
             enforced too: the `wsl` form does not satisfy a Linux/macOS job.

             **The `shell:` ban survives untouched**, which was not obvious going in. The job runs
             under the runner's default pwsh and calls `wsl.exe` explicitly, **one command per
             step** — necessary anyway, because a multi-line pwsh block propagates only its LAST
             native exit code, so a failing middle command would be invisible. One command per step
             fixes that and removes the need for a carve-out in the same move.

             **Its own file is structural, not tidiness.** `ci.yml` carries only unfiltered `push:`
             and `pull_request:` triggers, so a `schedule:` there would run all 27 of its jobs
             weekly to gain one. And `repo-settings.sh` discovery skips a workflow with no
             `pull_request` trigger, so a schedule-only file can never be discovered as a required
             context — putting the job in `ci.yml` would have made it both a per-PR cost and a
             required check. **Not `release:`**: this repo versions by pushed git tag and never
             publishes a Release object, so that trigger would have fired zero times.

             **The distro question from D32 is settled, and the answer changed.** `Vampire/setup-wsl`
             still stops at Ubuntu-24.04 (bash 5.2.21, below the floor), so it cannot express the
             only distro permitted here. But the premise it forced has moved: the runner image now
             ships WSLv2 2.7.10.0 as the default, and Microsoft's own distribution manifest carries
             `Ubuntu-26.04`. So `wsl --install --distribution Ubuntu-26.04` is a documented,
             first-party mechanism with no third party in the chain.

             **What is verified, and what is not — said exactly.** Source-verifiable and verified:
             the manifest entry, the runner inventory, the YAML, the lint accepting the job, and
             every new lint rule OBSERVED rejecting its own violation (including a fixture where a
             WSL job satisfies its guard with the bare host invocation). NOT verified: that
             `wsl --install` completes unattended on a hosted runner. That is unknowable from a
             workstation, so the job asserts every step of it — registration, WSL version 2,
             `VERSION_ID="26.04"`, a non-DrvFs clone, and the floor — and **fails closed**. A
             mechanism that does not work yields red, never a green that proved nothing.

             **DEVIATION-adjacent, and named rather than glossed:** #2's criterion "has been seen
             green at least once" is NOT satisfied by the PR that ships this. A `schedule` /
             `workflow_dispatch` workflow must already exist on the default branch before it can
             run, exactly as D32 predicted. The criterion is discharged by a manual dispatch after
             merge; claiming otherwise would be the unverified support claim
             `base/practices/verify-before-asserting.md` exists to prevent.

             **One asymmetry, deliberate — and independent review was right that the first version
             of it was wrong.** Linux and macOS each have an "at least one job must exist" aggregate
             rule; WSL does not, because requiring one would turn every fixture in
             `check-bash-floor-guard.sh` red for a reason other than the rule under test — the
             isolation failure that file's own header warns against. But the original justification
             stopped there, at "the count is printed", and review named the flaw exactly: *printing
             zero is visibility, not enforcement, and that rationale lets fixture convenience decide
             a production invariant.* Correct. The fix is a different HOME rather than a different
             rule: `check-fact-drift.sh` now pins the workflow's EXECUTABLE FIELDS — `runs-on:
             windows-latest` and the floor-guard line naming `Ubuntu-26.04`, each anchored to the
             start of a YAML line — plus the `schedule:` trigger and the two docs that assert the
             claim. A positive `fact` rule reports a missing path rather than passing vacuously, so
             deleting the workflow fails loudly, and pinning both sides means the job and the claim
             cannot drift apart in either direction. Strictly stronger than the aggregate, at no
             fixture cost.

             **A SECOND review round caught that this enforcement was itself hollow, which is the
             most instructive part of the whole change.** The first cut pinned the bare tokens
             `windows-latest` / `Ubuntu-26.04` anywhere in the workflow — and both also appear in
             that file's own explanatory COMMENTS. Reproduced: repoint `runs-on:` at `ubuntu-26.04`,
             restore the bare floor step, and the Windows leg is gone while `check-fact-drift.sh`
             says PASS and `check-bash-floor.sh` says `0 WSL-host … PASS`. That is precisely the
             "a note about the thing read as the thing" fail-open the floor lint had already been
             bitten by twice, reintroduced in the very rule written to prevent a silent
             disappearance. The lesson is narrower than "test your guards": the deletion case HAD
             been observed failing, and passing that test is what made the mutation case feel
             covered. `base/practices/self-review.md` says to prove a guard on the REAL superseded
             input, and a mutated file — not just a missing one — is that input here.

             Negative-testing the REPLACEMENT then found a second, narrower hole: a rule reading
             "some `run:` step names the distro" was still satisfied by the `wsl --install
             --distribution Ubuntu-26.04` line after every `-d` invocation had been repointed at
             Ubuntu-24.04 — a distro BELOW the floor. So the pin sits on the floor-guard line
             specifically, because that is the line whose interpreter is the claim. All five
             mutation vectors (runner repointed, guard reverted to the bare form, distro repointed,
             `schedule:` removed, workflow deleted) were each observed firing their own named rule.

             **What review changed, recorded because the reproductions are the valuable part.** The
             first cut ran the suite from a clone of the `actions/checkout` workspace. Review
             reproduced two failures in that topology: the `/mnt/<drive>` mount becomes `origin`,
             which is not GitHub-shaped, so `adb_git_origin_slug` cannot resolve it and
             `check-state-assert.sh` fails 14 assertions (selfcheck 39/1); and on a **tag** ref
             `actions/checkout` leaves HEAD detached, so the clone carries tags but no
             `origin/<default>` and `check-claims.sh` exits 2 — the `push: tags` leg could not have
             run the suite at all. Cloning from the canonical remote inside WSL fixes both, is the
             topology `docs/installation.md` actually prescribes, and let `actions/checkout` go
             entirely. Review also caught that the bootstrap installed ShellCheck (to avoid a silent
             skip) while omitting Node/npm, which `check-gates.sh` skips on identically; that the
             distro-list match was unanchored and satisfied by a `FakeUbuntu-26.04`; and that
             retaining only step NUMBERS let a job log distro A's bash and prove the floor in distro
             B. All fixed, the last two with their own red fixtures.
- baseline-issue: n/a — this is this repo's own CI shape, not a gap in the baseline's config
             surfaces. Windows support is a per-project platform question; nothing here needs a new
             override surface.
