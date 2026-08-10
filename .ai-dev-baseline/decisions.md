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

## D39 — the WSL job runs the framework as an ordinary user, and the guard for that could not be the one the issue asked for
- date:      2026-08-04
- category:  project-delta
- unknown:   #271. D38's job passed `--user root` to every in-distro command, and one assertion in
             the offline suite depends on POSIX mode bits to DENY a write. Root holds
             `CAP_DAC_OVERRIDE`, so that write succeeds, the assertion inverts, and the weekly job
             cannot reach a passing run. The issue's own test plan then asked for a regression guard
             spelled `absent:--user root` — which turns out to be unsatisfiable, and *why* is the
             part worth recording.
- decision:  Create an ordinary `adb` user in the distro and hand it everything the framework
             touches (clone, distro bash log, floor guard, `install.sh`, `selfcheck.sh`,
             `uninstall.sh`). Exactly three in-distro invocations keep `--user root`: the
             `/etc/os-release` read, which precedes the account, plus `apt-get` and `useradd`, which
             are privileged by nature. Guard it with a **contextual** negative rule plus a
             **positive rule per framework command**, not with the literal pin requested.
- placement: `.github/workflows/wsl-smoke.yml`; the `wsl-smoke-nonroot-framework` /
             `wsl-smoke-runs-as-adb` / `wsl-smoke-clones-as-adb` / `wsl-smoke-asserts-nonroot-uid`
             rules in `scripts/check-fact-drift.sh`.
- reason:    **The workflow was wrong, not the check.** `scripts/check-skill-compose.sh:329-330`
             chmods a directory `555` and requires the next compose to fail; it passes on
             `ubuntu-26.04` and on a maintainer's macOS workstation, both of which run as a normal
             user. Weakening or skipping it under root would have deleted real coverage to
             accommodate a CI choice. And the fix is not merely a UID swap: `docs/installation.md`
             tells a Windows user to clone and install inside WSL **as themselves**, so running as
             root was proving a setup no real user has. Fixing it raises the job's fidelity.

             **The literal `absent:--user root` rule is unsatisfiable, and that is a fact about the
             `fact` grammar rather than about this workflow.** `fact` applies ONE pattern to a WHOLE
             file — there is no step selector. Three invocations must stay root (the
             `/etc/os-release` read precedes the account; `apt-get` and `useradd` are privileged by
             nature), and the workflow's own comments discuss the old form. A bare pin would
             therefore fail on a CORRECT file, which
             under `--mutation` means it never even reaches its witness: the mode requires a clean
             baseline before injecting. So the pattern is contextual — root **and** reaching a
             framework command. It covers `-u root`, which is the same instruction spelled short, and
             a numeric uid for a weaker reason that review was right to force apart from the first:
             `wsl --user` resolves a NAME through `getpwnam`, so `--user 0` names a user that does not
             exist and errors rather than running as root. That branch is defence against a future
             `wsl.exe` that accepts a uid; its witness proves the pattern matches, not that the
             spelling would run as root. The original entry claimed all four spellings were "the same
             instruction to `wsl.exe`", which was simply false.

             **The negative half alone is insufficient, and the reason generalizes.** The regression
             this exists to stop is "the job silently returns to root", and the cheapest way to get
             there spells nothing at all: `wsl --install --no-launch` provisions no user, so an
             invocation that simply DROPS `--user` runs as the image's default, which is root. **No
             negative pattern can match an absent flag.** Hence a positive rule per framework command
             asserting that line names `adb` — one per command, because a `fact` proves only that
             SOME line matches, so a single rule would be satisfied by one compliant step while the
             other four had drifted. This is the same both-directions shape as the `actions-slug-*`
             family, arrived at from the opposite side: there the negative caught a stale copy kept
             beside the new value; here the positive catches a value deleted rather than changed.

             **Observed failing, on the real superseded input.** Every rule was driven red against the
             pre-#271 workflow, and each regression vector was driven red individually on a throwaway
             tree copy: dropping the flag, `-u root`, `--user 0`, `--user root` on `install.sh`, a
             root-performed clone, root restored on the distro bash log, and a neutered uid
             comparison. The fixed file is green and three legitimate variants — a trailing comment
             naming the old form, the `-u adb` shorthand, `--distribution` spelled out — were
             confirmed NOT to fire, so the pins do not merely fire, they discriminate. Two of the
             negative rule's eight witnesses are spellings that were never in the tree (`-u root`,
             `--user 0`); that is said in the file rather than implied, because
             `base/practices/self-review.md` asks a guard to be proven on REAL superseded input and
             those two are not that.

             **AND THE FIRST CUT OF THIS GUARD HAD FOUR HOLES, WHICH IS THE MOST INSTRUCTIVE PART.**
             All four were found by independent review, all four were reproduced against this file,
             and none of them was visible from the vectors above — because every one of those vectors
             was written by the same person who wrote the rules, testing the failures that person had
             already thought of. That is the specific limit of self-negative-testing, and it is worth
             recording as plainly as the technique it qualifies:

               1. **A trailing comment is not a comment as far as an anchored rule is concerned.**
                  Anchoring at `run:` excludes a whole-line comment, and the entry originally claimed
                  on that basis that "a comment can never satisfy — or trip — either half". False:
                  `run: wsl … # once --user root … bash scripts/selfcheck.sh` put the forbidden text
                  on an executable line, and an unbounded `.*` read straight through the `#`.
               2. **The same hole in the positive rules fails OPEN**, which is worse.
                  `run: wsl --help # --user adb --cd /home/adb/x -- bash scripts/selfcheck.sh`
                  satisfied the pin while executing `wsl --help`; the clone pin fell to the same
                  trick with `bash -c "true" # git clone /home/adb/`. `[^#]*` between the anchors is
                  the fix, plus `"[^"]*` to confine the clone match to inside the quoted string.
               3. **A guard pinned to the INPUT of an assertion is not pinned to the assertion.** The
                  uid rule matched the `id -u` read, so changing `if ($uid -eq '0')` to compare
                  against anything else left the lint green — the value was still being read and
                  simply no longer judged. It is two rules now, the read and the judgement.
               4. **The one framework line with no `--cd` and no script name was uncovered.** The
                  distro's `bash --version` log matched none of the negative rule's framework tokens
                  and had no positive pin, so `--user adb` could be dropped from the very line whose
                  job is to say which interpreter the framework runs under, with nothing going red.

             A fifth, in the workflow rather than the lint: the DrvFs assertion treated the absence of
             a match as a pass, so a `df` that never ran reported "not DrvFs" — and pwsh propagates
             only the LAST native exit code, which a later command supplied. It now checks the exit
             code and the shape of what it read.

             **The uid is asserted, not merely logged, which is a deliberate strengthening of the
             issue's own wording.** The issue asked to "log the effective user … so a future
             inversion of this kind is readable in the log rather than reconstructed from a failing
             assertion". Reconstructing it was exactly what #271 cost: the only symptom was one
             failing compose assertion far downstream. A `throw` on `uid = 0` fails the job at the
             cause, which serves that stated goal strictly better than a line in a log nobody reads
             on a green run. `id -u` rather than bare `id`, because `id` output carries `uid=0(root)`
             AND `gid=0(root)` AND every supplementary group, so any pattern loose enough to find the
             uid in it is satisfiable by a group — the "a note about the thing read as the thing"
             fail-open this repo has been bitten by more than once.

             **The clone is made AS the user, and its ownership is asserted.** A root-owned tree
             handed to a non-root user fails later and confusingly — git refuses it with "detected
             dubious ownership" and `install.sh` hits permission errors — rather than at the step that
             caused it. `--cd` cannot be leaned on to enforce this either: WSL treats a failed
             `chdir` as non-fatal and launches the command anyway, so a clone that landed elsewhere
             would not stop the steps below at their own boundary.

             **What is NOT discharged by the change, said plainly.** The job still has not been
             observed green. D38 already drew this boundary for #2's "seen green at least once"
             criterion, and it holds identically here: the live half is discharged by a
             `workflow_dispatch`, not by the diff that fixes it. Everything checkable offline was
             checked — the YAML parses at 14 steps, `check-bash-floor.sh` still reports `1 WSL-host`,
             and every new LINT rule was observed rejecting its own violation.

             The boundary inside that sentence is deliberate. The lint rules were observed failing;
             the two RUNTIME assertions this change adds — the effective uid is not 0, the clone is
             owned by `adb` — were not, and cannot be from here, because they execute only inside
             WSL. What is known about them is that they are reachable and correctly shaped, not that
             they have been seen red. Saying "every new guard was observed failing" would have
             covered two that were not, which is exactly the overstatement
             `base/practices/self-review.md` exists to prevent.
- baseline-issue: n/a — this is this repo's own CI shape and its own lint, not a gap in the
             baseline's config surfaces.

## D40 — review artifacts are swept on the run marker alone, and the marker is re-read at the delete
- date:      2026-08-04
- category:  project-delta
- unknown:   #264. `/implement-issue` step 8 writes `review-prompt.txt`, `review.md` and
             `review.err`; nothing removed them. The mechanical half of the fix (a preflight clear,
             a `review` arm in `state-scan`) had an obvious precedent in the gap artifacts. The half
             that did not was liveness: the gap arm answers "is a dispatch running right now?" with
             `gap-analysis.lock`, and **review has no equivalent lock**. The issue named this as its
             one design question — does review need a lock, or is the run marker enough? — rather
             than something to port by analogy.
- decision:  **No review lock.** `state-verdict review` takes `<run keep|stale|none>` and no lock
             argument. The caller derives that word from the marker records in the **re-scan** that
             already re-reads the lock — `RUN_NOW=keep` when any `marker` record survives it — and
             explicitly **not** from the `$RUN` computed earlier in the step.
- placement: `scripts/lib/cleanup-lib.sh` (the `review` arms of `state-scan` and `state-verdict`);
             `base/workflows/cleanup.md` step 5; `base/workflows/implement-issue.md` preflight;
             pinned in `scripts/check-cleanup.sh` sections 2c2, 3 and 6.
- reason:    **The lock exists for a window review does not have.** Gap analysis runs in step 3,
             *before* the branch and the run marker exist (step 5 writes them), so a live gap
             dispatch has no marker to consult and its artifacts read as a finished run's
             leftovers. Review is written in step 8 — after step 5, while the run's local branch
             still exists — so `state-verdict marker` returns `keep` for every review write **within
             the one-active-run-per-checkout boundary `/implement-issue` already declares**. The
             marker already is the signal there. A second one could leak, be cleared late, and
             disagree with the first, and it would need the whole gap-lock protocol (take before the
             write, release outside the detached block, clear leaks at preflight) to buy nothing.

             **That boundary is stated because outside it the claim is false, and a lock does not
             rescue it.** A second run's preflight clears the fixed marker paths unconditionally, so
             it can delete a live run's marker (#202); the first run then reaches step 8 with no
             marker and this sweep would call its live artifacts stale. A review lock lives at a
             fixed path too and would be cleared by that same preflight. The independent review of
             this change caught the original wording claiming "every reachable write" without that
             qualifier — the engineering decision is unchanged, the scope of what it promises is
             not.

             **What that costs, and where it is paid: `$RUN` is not good enough.** `$RUN` is
             decided during a marker pass that makes live PR round trips, and the step already
             states the rule that governs this — *the signal that governs a destructive delete must
             be the one true at the delete*. So review's liveness is re-derived from the fresh
             scan. That is equivalent to `$RUN` in every non-race case (the pass deletes exactly the
             markers it proved stale; a delete that fails or finds a changed file forces
             `RUN=keep`) and strictly safer when a marker appears mid-sweep. Passing `$RUN` is
             pinned as a NEGATIVE in `check-cleanup.sh`, because both spellings run and both print
             a verdict — nothing else in the suite can see the substitution.

             **The residual race is named rather than claimed closed.** A file deleted after the
             re-scan but recreated at the same path before `sweep_file` reaches its record is not
             excluded by anything here — the same consistency model the `gaps` and `threads` arms
             already use. Reaching it needs a new marker to appear *after* the re-scan **and** that
             run to get from preflight to step 8 before this loop ends, which is minutes of work
             inside a window of milliseconds. True exclusion would need delete-time file identity,
             which is what markers get and what their failure mode (a disarmed continuation gate)
             justifies; a re-fetchable prompt does not.

             **The preflight and classifier sets are kept byte-identical, including the family
             globs.** The issue asked for `review-*.md|review-*.err` so a future per-slot output is
             covered. A name `/cleanup` can sweep but preflight cannot clear is a stale artifact
             that a *new* run's marker makes read as live — the exact trap #264 is about — so
             preflight clears the family too, and a test pins the two lists against each other.
- baseline-issue: n/a — the artifacts, the sweep and the workflow are all this repo's own code, and
             `cleanup-lib.sh` was already the prescribed home for a `/cleanup` decision predicate.

## D41 — `state-scan` refuses to serialize a name it cannot encode, and the marker record survives that refusal
- date:      2026-08-04
- category:  project-delta
- unknown:   #273. `state-scan` serializes `<kind>TAB<path>TAB<key>NL` with no escaping, and the
             sweep parses it with `IFS=<tab> read -r kind sfile key` before handing `$sfile` to
             `rm -f`. A field carrying a raw tab or newline therefore does not corrupt a record —
             it **forges** one, with an attacker-chosen `kind`. The baseline models "which files
             may be deleted" (the `other` allowlist) but had no model at all for "which values may
             be written into a record", so the question the issue asked — where does the fix go,
             and what happens to a name that cannot be encoded — had no prescribed answer.
- decision:  **Refuse at the record format, in three parts.**
             1. A file whose emitted path is unserializable gets an **`unsafe`** record whose path
                field is a `%q`-ENCODED rendering, and **exit stays 0**.
             2. The **state directory's own** path being unserializable is **fatal** (exit 2, no
                stdout), because it poisons every record at once.
             3. A marker's `.branch` carrying **any ASCII control character** (codepoint < 0x20
                **or** 0x7f) is treated as **unreadable** — empty key -> `-` -> `unknown` -> keep —
                and **the marker record is still emitted**. That rejection happens **inside jq**,
                not in the shell.
- placement: `scripts/lib/cleanup-lib.sh` (`_adb_cl_tsv_safe`, `_adb_cl_tsv_display`, the guard
             ahead of `state-scan`'s `case`, and `_adb_cl_marker_branch`); `base/workflows/cleanup.md`
             step 5 (the captured scan status and the `unsafe` NOTES loop); pinned in
             `scripts/check-cleanup.sh` sections 3b and 6.
- reason:    **Per-arm checks were never the fix.** The carrier that reproduced this was classified
             `other` — the *safest* kind, the one that is never swept — because the defect is in
             the serialization, not in which arm matched. The forged record's kind is attacker-
             chosen text, so it can name `gaps` no matter what the carrier is.

             **`other` is not sufficient either, and that is the trap worth recording.** The
             obvious-looking fix is to classify such a file `other` and rely on the allowlist. It
             does not work: `other` is still *emitted*, so the raw name still reaches stdout and
             the forged second line survives the safest classification in the file. The name has to
             not be printed, which is why the refusal sits ahead of the `case` rather than inside it.

             **Both fields carry the bug, and the second one is worse.** A filename cannot contain
             `/`, so that carrier reaches only names in the directory the sweep is anchored at
             (`CHANGELOG.md`, `install.sh`, `CLAUDE.md`). A marker's `.branch` is a JSON string that
             **can** contain `/`, so it reaches an **absolute** path. A pathname-only fix would have
             gone green with the worse half still live; the independent gap-analysis pass and a
             hand reproduction both landed on this before any code was written.

             **Refusing the marker's KEY must not cost its RECORD, and this is the half a naive fix
             gets backwards.** The workflow derives run liveness from the *presence* of a `marker`
             record (`RUN_NOW=keep`). Dropping the record would report "no run in flight" — exactly
             the verdict that lets a **live** run's gap and review artifacts be swept out from under
             it. So the record is emitted with the `-` key, which the existing contract already
             maps to `unknown` and `state-verdict marker` already fails closed on. Calling the value
             *unreadable* is honest rather than a euphemism: `git check-ref-format` rejects ASCII
             control characters, so such a value was never a branch name and every ref query built
             from it was guaranteed to miss. `check-cleanup.sh` pins the surviving record, and that
             assertion was observed going red against a deliberately-written naive fix — it cannot
             go red against the pre-fix library, so it needed its own negative test.

             **The marker-key rejection had to move INSIDE jq, and that is a correctness fix rather
             than a style choice.** The first implementation checked the value in the shell, after
             `b="$(jq -r '.branch // empty' …)"` — and `$(…)` *mutates the value on the way out*, so
             a malformed marker was normalized into a well-formed one before anything could judge
             it. Two live defects, both reproduced under bash 5.3 by the independent review:
             command substitution strips **every** trailing newline, so `"dead-branch\n"` — not a
             branch name — arrived as the perfectly ordinary `dead-branch`, was accepted, and with
             no matching ref and no PR would be classified **stale and deleted**; and JSON permits
             `\u0000`, which bash silently drops from a substitution (`"dead\u0000branch"` ->
             `deadbranch`) *while warning on stderr*, breaking the reader's quiet-on-every-failure
             contract in the same move. Neither is a forgery — they are the opposite failure, a
             malformed marker quietly becoming a valid-looking one — and both are invisible to a
             check that only ever sees the post-substitution string. jq now returns `empty` for any
             ASCII control character, so the bad bytes never reach the shell at all; the shell-side
             predicate stays as a belt-and-braces re-check. Reverting to the shell-side form was
             observed turning four assertions red, including the stderr-silence one.

             **The control class is `< 0x20` OR `0x7f`, and the first attempt at it stopped short.**
             That version cited `git check-ref-format` while implementing only `< 0x20` — but git
             rejects **DEL** too, and DEL is the control character that sits *above* the printable
             range, so a `< 32` test is exactly the shape that misses it. The consequence was not
             cosmetic: DEL serializes perfectly well, so it forged nothing and instead triggered the
             *other* failure this reader guards — emitted as an ordinary key, matched no ref, had no
             recorded PR, and `state-verdict marker` returned **stale**, deleting the marker and the
             run's artifacts with it. Caught by the second review round; pinned now, with the
             boundary either side of DEL tested rather than the one example.

             **What it is NOT is a reimplementation of `git check-ref-format`.** That grammar also
             rejects spaces, `~^:?*[`, `\`, a leading `-`, `..`, `@{` and a trailing `.lock`. Every
             one of those is a value a ref query simply fails to find, which the existing
             no-such-ref path already handles correctly. A control character is the case that
             *additionally* corrupts the record — so the control class is the line, and the claim is
             now stated that narrowly rather than borrowing git's authority for a wider one.

             **Exit 0 for a file, exit 2 for the directory.** An unserializable filename is not a
             tooling failure; it is a file this subcommand declines to classify, which is the state
             `other` already describes and which already resolves to "never deleted". The directory
             is different in kind: every record would be refused, and a scan that silently returns
             nothing is indistinguishable from a clean, empty state dir — a sweep reporting success
             while doing nothing, which is the #106 class this library exists to remove. The
             workflow therefore captures the scan's status with an `if` rather than letting it fall
             through, and its diagnostic deliberately does **not** interpolate the offending path,
             which would move the injection into the operator's output.

             **NUL-delimited records were rejected on portability, not taste.** `<kind>TAB<path>
             TAB<key>NUL` still permits a tab inside the path, and fully NUL-delimited fields need a
             new consumer grammar. Decisively: both snapshots are captured into shell variables via
             `$(…)`, and **bash strips NUL bytes while zsh preserves them** — macOS runs zsh
             (`base/practices/shell.md`), so the record format would behave differently on the two
             platforms CI now covers (D29). `read -r -d ''` works in both shells; the capture
             architecture around it does not.

             **The validator is PRIVATE to `cleanup-lib.sh`, not promoted to `common.sh`.** This
             cuts against the usual "one home for shared primitives" instinct, so the reason is
             recorded: the policy is state-record-specific (it must cover the marker key, not just
             filenames), and the obvious second callers **do not want it yet**. `adb_repo_shape`
             and `adb_agent_manifest` emit path-bearing TSV while explicitly declaring tab/newline
             paths *unsupported* — whether to support them is a separate cross-library decision
             with its own consequences (`bin/agent-init` uses a parsed shape value as its write
             root), and folding it into this issue would make that decision silently. A shared
             primitive whose obvious adopters deliberately abstain is worse than a private one.
             `project-gates.sh` has a narrower `_adb_has_tab` and is **not** a third site with this
             bug: its producer is `adb_toml_get`, an awk line-oriented reader, so a TOML value can
             never contain a newline.

             **The `review` set-equality invariant becomes containment, and the prose says so.**
             `/cleanup` can now sweep strictly fewer names than `/implement-issue`'s preflight
             clears, because `find … -exec rm -f {} +` handles a control-character name that
             `state-scan` refuses to serialize. That is the harmless direction — the invariant that
             matters is *everything sweepable is clearable* — so the fix is to qualify the claim,
             **not** to mirror the refusal into preflight, which would only stop it cleaning a file
             it can clean perfectly well.
- baseline-issue: n/a — `state-scan`, its record format and the sweep that consumes it are all this
             repo's own code, and `cleanup-lib.sh` was already the prescribed home for a `/cleanup`
             decision predicate.

## D42 — the filter carries ONE integer of list state: the open item's content column
- date:      2026-08-05
- category:  general
- unknown:   #252 asks the filter to recognize a fence or a blockquote indented to the content
             column of the list item it sits in. D27 declined exactly that, calling it "option 2"
             in #136 §5 and pricing it as "list-depth, content column and laziness state carried
             through every container — a parser this framework has no reason to own, and a large
             surface for the under-match direction to hide in". So the unknown is not whether to
             close the hole but HOW MUCH of option 2 a fix has to buy, and D27's cost argument is
             what it has to answer. Gap analysis raised three sub-forks as BLOCKING: the container
             state's lifetime and depth model, whether the container column and the delimiter
             column are the same number, and what happens to the two consumers that call the fence
             predicate directly rather than through `adb_md_block`.
- decision:  ONE INTEGER, `md_list_at`, holding the content column of the innermost open list item
             — and it REPLACES the `md_list` boolean rather than joining it, the same way
             `md_fence_len` is itself the in-a-fence flag. A marker's content column is always >= 2,
             so a non-zero value IS "a list is open" and the two can never drift apart.

             `adb_md_content_at` and `adb_md_fence_delim` take it as a `base` parameter, and the
             indent cutoff becomes one comparison:

                 if (i - base > 3) return -1          # was: if (i > 3) return -1

             THAT IS NOT THE WHOLE BEHAVIOURAL CHANGE, and an earlier draft of this entry said it
             was (review finding). The closer bound moved independently — see fork 2 below — and it
             moves for every caller, including the two that never track a container at all. Two
             changes, stated as two.

             THE LIFETIME (fork 1) IS THE BOOLEAN'S PLUS ONE QUALIFIER. A blank line preserves the
             column, a marker sets it to that marker's own content column (so a marker written
             further left dedents by plain assignment), and a column-0 line clears it ONLY WHEN NO
             PARAGRAPH IS OPEN. That last clause is CommonMark's laziness rule, it costs no new
             state because `md_para` already distinguishes the case, and it is not optional — see
             the stale-SHALLOW paragraph below. The column does NOT pop on a dedent carrying no
             marker: that needs the container stack D27 refused.

             STALENESS IS BOUNDED IN BOTH DIRECTIONS, and an earlier draft of this entry claimed it
             could only ever go one way. That was wrong, and independent review produced the
             counterexample:

               - STALE-DEEP, from a markerless dedent, is harmless for the indent cutoff. `base`
                 moves where indented-block territory STARTS and never changes the column the
                 function returns, because marker detection already happens at the line's own first
                 non-space character — so a too-deep base still passes for a line written further
                 LEFT (the difference goes negative) and can only admit structure a little deeper
                 than CommonMark would, where CommonMark says "indented code", which is not a
                 declaration either. It is NOT harmless for the closer bound, which is why that is
                 clamped (below).

               - A COLUMN-0 BLOCK STARTER is not lazy, and the `md_para` qualifier alone treated it
                 as though it were (review round 3). CommonMark's laziness covers continuation TEXT
                 only, so a heading, blockquote, fence or HTML block at column 0 ends the item even
                 mid-paragraph. Left unqualified, `- item` / `# Repro` / `    Depends on #5`
                 fabricated an edge the parent correctly read as top-level indented code — the very
                 over-match this decision exists to remove, reintroduced one rule later.
                 `adb_md_col0_block` clears the column at each of those branches, excluding a MARKER
                 line (`at == lead`), which opens an item rather than ending one.

               - STALE-SHALLOW was the one the draft missed. A lazy continuation — `- item` /
                 `lazy continuation` at column 0 — cleared the column to 0 while the item was still
                 open. A fence at column 2 then stored a bound of 3 and REJECTED its own valid
                 closer at 4, ran to end-of-body and ate every edge after it. That is the dangerous
                 direction, and no clamp can repair it because the state was already too small. The
                 laziness qualifier prevents it at the source.

             A FENCE OPENED INSIDE AN ITEM ENDS WHEN THE ITEM DOES — a non-blank line written to
             the LEFT of the fence's own container column (`lead < md_fence_base`), which needs no
             separate `> 0` test since no lead is below zero, so a top-level unterminated fence
             still swallows to end-of-body as it always has. COLUMN 0 IS NOT THE BOUNDARY, and an
             earlier draft tested exactly that: an INDENTED item ends well before column 0, so
             `  - item` / `      ~~~` / `      code` / `  Depends on #5` swallowed a real edge the
             parent read correctly (review round 3). Its OWN CLOSER IS TRIED FIRST: a list-nested fence is
             most often closed by a delimiter written back at column 0, which satisfies both tests,
             and ending the container first consumed that line as a terminator and then re-read it
             as a fresh OPENER — reintroducing the swallow this rule exists to prevent. Without this
             half, the container-relative closer bound is a net LOSS: it correctly refuses an
             over-indented closer, and the fence then takes every edge after it.

             THE STALE COLUMN IS CLAMPED WHERE IT WOULD OTHERWISE BITE. "Leave it standing" is
             harmless for `adb_md_content_at`, by the argument above, but NOT for the closer bound:
             self-review found that a markerless dedent (`- outer` / `    - inner` / `  ~~~`) left
             the column at 6 while the fence really sat in `outer` at 2, admitting a closer at 9 —
             so a 6-space delimiter closed that fence early, fabricated an edge from the quoted line
             after it, and let the real closer read as a fresh opener that ate every edge to
             end-of-body. The PARENT commit got that body right, so this would have traded #252's
             bug for a rarer one. A container cannot begin to the right of its own content, so the
             delimiter's column is a hard ceiling on the true one: `adb_md_fence_delim` stores
             `min(base, at)`, which turns a stale reading into a merely conservative one.

             THE CONTAINER COLUMN AND THE DELIMITER COLUMN ARE DIFFERENT NUMBERS (fork 2), so
             `md_fence_at` became `md_fence_base` and bounds a closer at container + 3. Those were
             the same number until a fence could open at an item's content: `- item` / `    ~~~`
             puts the container at 2 and the delimiter at 4, and the old bound accepted a closer 4
             past the container, which CommonMark calls fence CONTENT. That was not cosmetic — it
             failed BOTH ways in one body, fabricating an edge from the quoted line after the early
             close AND dropping every edge after the real closer, which then read as a fresh
             opener. It also settles the top-level case that was always reachable: an opener at 3
             no longer accepts a closer at 4-6. Fixing it here rather than deferring is deliberate,
             because #252's own fixtures could not hold in both directions without it.

             DIRECT CONSUMERS KEEP THE TOP-LEVEL RULE (fork 3). `skill-compose.sh` and
             `check-release-skill.sh` call `adb_md_fence_delim` without ever driving `adb_md_block`,
             and now pass a container column of 0 explicitly rather than relying on awk's
             uninitialized-parameter rule — which also says at the call site why they are
             top-level-only. Stated exactly rather than flatteringly: this is NOT byte-identical
             behaviour, and an earlier draft of this entry claimed it was. Fork 2 makes the closer
             bound container-relative for everyone, so a fence these two open at indent 1-3 now
             needs its closer at indent <= 3, where the old opener-relative bound allowed opener + 3.
             What IS true is that no file in the tree moves: every indented opener today (2-3 spaces,
             in `base/workflows/`) pairs with a closer at the same indent. Extending them to track
             containers means driving the block pass, which changes what those two files compose and
             guard, not this filter.

             D27's GUARD IS NOT MOVED. With `base` in play its fork now reads "4+ past the OPEN
             ITEM's content", which is genuinely item-relative indented code — and stripping it
             would delete a list continuation, the under-match direction D27 exists to refuse. A
             fixture pins that boundary as a decision rather than leaving it to look like an
             oversight.
- placement: `scripts/lib/common.sh` (`_ADB_MD_AWK`: `adb_md_content_at`, `adb_md_close_run`,
             `adb_md_fence_delim`, `adb_md_block`, `BEGIN`), fixtures in `scripts/check-roadmap.sh`
             § 6i and `scripts/check-common-lib.sh`, and the rule's prose in
             `base/workflows/roadmap.md` (rendered into all three agents' skills).
- reason:    Option 2 in full was refused for a reason that still holds, and this does not buy it:
             no depth, no pop on a markerless dedent, no laziness tracking, no item-relative
             indented code. What it buys is the one piece the hole actually needed, and the piece
             whose failure mode is provably one-directional. Everything the header already declines
             to model — tabs, Setext headings, mid-line comment containers, other HTML blocks — is
             declined still, and the list of what is NOT modelled grew rather than shrank.

             The issue's framing that this is "the only container shape the filter gets wrong" is
             narrower than it reads, and repeating it would be a false claim: several conservative
             non-CommonMark cases are retained on purpose. The defensible claim is that this was
             the remaining REPORTED list-continuation hole.

             MEASURED AGAINST A COMMONMARK REFERENCE PARSER, which is the evidence that decides
             the shape rather than argues it. 1888 generated container shapes (list markers at four
             indents, nested and not, both fence delimiters at every reachable column, closers at
             four columns, blockquotes, with and without a blank line) were classified by
             markdown-it-py in strict CommonMark mode, and every candidate line carries a unique
             issue number so "did the filter declare N" maps 1:1 onto "is line L prose":

                                     over-match      under-match
                 parent                     526               46
                 this change                389                2   (newly dropped: 0)

             THE SWEEP DID NOT FIND EVERYTHING, and saying so is the point of recording it. Both
             round-3 defects sit in shapes the generator never produces — a column-0 block starter
             after a list paragraph, and an indented item ending before column 0 — so the numbers
             above were IDENTICAL before and after fixing them. A generated corpus proves the axes
             it varies and nothing else; the independent reviewer found what it could not see.

             Better in BOTH directions, and — the number that actually governs — ZERO shapes where
             this drops an edge the parent declared. Over-match blocks a ready bundle and is
             visible; under-match marks a genuinely blocked bundle `ready` and is not. The two
             under-matches that remain are artifacts of the oracle, which models block structure
             only: both are backtick runs that CommonMark pairs as an INLINE code span, which this
             filter also suppresses and the oracle does not model.

             Intermediate shapes were measured rather than assumed, and two were rejected on the
             numbers: the container column with the closer bound left opener-relative (389/34, but
             it keeps the early-close bug that fails both ways at once), and the container-end rule
             applied before the closer check (389 over, and it re-swallowed bodies).

             EVIDENCE ON THE LIVE CORPUS, to D27's own standard. `deps-from-body` was run over all
             210 issue bodies in this tracker with the parent library and with this one, and the
             edge sets are IDENTICAL — 30 edges either way, no body's reading moved. Said plainly
             rather than spun: that means this was a LATENT hole, not an incident in progress. The
             only shape that would have moved is the one #252 reports, and even its own repro is
             written inside a top-level fence, so the issue body does not trip its own bug. The
             corpus run is therefore evidence of SAFETY (nothing regressed across 210 real bodies),
             and the fixtures are the evidence of the fix.

             ORDERING stated exactly as D27 asks. Nineteen of the new assertions were run against
             the parent's `scripts/lib/common.sh` in a throwaway copy of the tree and observed RED —
             seventeen in `check-roadmap.sh`, two in `check-common-lib.sh` — while the assertions
             pinning deliberately-unchanged behaviour stayed green, which is the split that makes
             them witnesses rather than decoration.

             OTHERS cannot be witnessed that way, because the parent reads those bodies correctly
             and a red-at-parent run therefore proves nothing about them. Each was driven RED
             against a deliberately wrong build instead: the closer-bound fixture against one
             carrying the container column WITHOUT the clamp, and both laziness fixtures against one
             whose column-0 rule drops the `md_para` qualifier. A further fixture was found by
             review to pin nothing at all — a two-space fence that every candidate model recognizes
             — and its description now claims only the negative-offset half it actually witnesses.

             This entry lands in the SAME commit as the code, so the diff cannot evidence that it
             was written first and nobody should read it as evidenced; the red-at-parent fixtures
             are the part a reviewer can check.
- baseline-issue: #252

## D43 — the shared filter's comment/span semantics are adopted as-is, not worked around per-consumer
- date:      2026-08-05
- category:  general
- unknown:   #251 converts `check-claims.sh` and `state-assert.sh lint` onto `_ADB_MD_AWK`. Gap
             analysis raised two BLOCKING semantic deltas that the issue does not decide, both
             affecting only the two joining consumers because the other seven already live with
             them. (1) The shared filter DELETES an HTML comment's bytes where both private copies
             substituted a space, so `D<!--x-->99` becomes `D99` and `cl<!--x-->osed` becomes
             `closed` — text fusing into a token neither copy would have seen. (2) A resolved code
             span becomes one `\x01` PER BYTE where `cc_prose` substituted a single space, so the
             C1 kind hint in `PR`x`#7` stops matching and the reference is recorded `bare` rather
             than `pull`. Either could be called a regression, and adopting them silently would be
             the "silently disabled rule" failure `check-claims.sh`'s own header is about.
- decision:  ADOPT BOTH, and pin each with a fixture rather than reproducing the old spacing.
             (1) is CORRECT, not a regression: an HTML comment is ZERO-WIDTH in CommonMark, so the
             rendered text a reader sees genuinely is `D99`. The space substitution was the
             approximation — it invented a word break nobody wrote. This is also exactly what
             distinguishes a comment from a code span, whose content is visible-but-code and is
             therefore MASKED rather than dropped; the filter already draws that line and draws it
             deliberately. (2) is a FIX in the same direction as `\x01` itself: reading `PR #7`
             across a code span is the phrase fusion the mask byte exists to prevent, and the
             reference is still resolved for EXISTENCE — only the fabricated KIND claim is lost.
             The alternative in both cases is a boundary-preserving third view in `common.sh`,
             which would change the reading of all seven existing consumers to spare two new ones.
- placement: scripts/lib/common.sh (unchanged), the two consumers, and fixtures in
             scripts/check-claims-guard.sh + scripts/check-state-assert.sh
- reason:    The single-source law only pays if joining a consumer means adopting the shared
             semantics. A per-consumer workaround for a semantic it dislikes is the fourth copy
             #136 exists to delete, wearing a smaller costume — and it would have to be maintained
             against a filter that keeps moving (#135, #252).

             DIRECTION, stated as D27 asks. (1) is an OVER-match: a fabricated `D99`/`#4242` could
             fail CI on text that is not a claim. It needs `<!--` written mid-token with no
             surrounding space, which nothing in this tree does and no author writes; the audited
             `adb-claim-ok:` escape covers the pathological case. (2) is an UNDER-match confined
             to the kind hint, and the number is still resolved. Both were measured on fixtures
             before being accepted rather than reasoned about.

             SCOPE REFUSED, deliberately: no boundary-preserving view, no widening of the parser's
             documented exclusions (leading tabs, a container stack, item-relative indented code,
             Setext headings, mid-line comment containers), and no revival of the removed
             path-claim rule.
- baseline-issue: #251

## D44 — the workflow reader lands in `common.sh`, and a blind parse is a failure rather than an empty repo
- date:      2026-08-05
- category:  general
- unknown:   #262 asks for ONE job enumerator to replace the two hand-written scanners in
             `scripts/lib/repo-settings.sh` and `scripts/check-bash-floor.sh`, and #102 asks for
             discovery to stop being blind to a 4-space-indented workflow. Gap analysis raised
             three questions neither issue decides. (1) WHERE the shared reader lives —
             `common.sh` carries D30's permanent below-floor restriction and framework-wide blast
             radius, while a new `scripts/lib/workflow-lib.sh` is "least coupled". (2) Whether
             #102's fix belongs only in the job enumerator, when the reported symptom
             (`no pull_request trigger`) comes from the separate TRIGGER parser. (3) What "fail
             loud" means as a machine contract, given `discover_checks` deliberately returns 0 for
             a legitimately CI-less repo (#24) and four guards consume it.
- decision:  (1) `scripts/lib/common.sh`, as an awk FUNCTION LIBRARY (`_ADB_WF_AWK`) plus two
             wrappers (`adb_wf_on`, `adb_wf_jobs`) — the shape #136 chose for
             `_ADB_MD_AWK`/`adb_md_prose` and #251/D43 affirmed, answering the identical question
             (N consumers, one parser, opposite needs). (2) BOTH parsers become indent-agnostic, and neither detects
             an indent "unit": the reader tracks RELATIVE DEPTH, so 2-space, 4-space and MIXED
             files all read. (3) The structural facts every workflow must have — an `on:` key, a
             `jobs:` block, at least one job — are checked on EVERY file, and a violation returns
             non-zero; `apply` then refuses to write, and `automerge-ok`/`required-drift` return
             the existing fail-closed **20**.
- placement: `scripts/lib/common.sh` (the reader), both consumers, fixtures in
             `scripts/check-common-lib.sh` + `scripts/check-repo-settings.sh` +
             `scripts/check-bash-floor-guard.sh`, structural pins in `scripts/check-fact-drift.sh`,
             and `docs/repo-settings.md` + `docs/ci-runners.md`
- reason:    **(1) A new library does not escape the below-floor constraint, it duplicates it.**
             `check-bash-floor.sh` is the D31 OBSERVER — exempt from `adb_require_bash` on purpose,
             and executed under `/bin/bash` 3.2 by its own guard suite — so anything it sources
             must stay evaluable there. A new file would therefore need its own permanent
             carve-out, its own entry in `check-bash-floor-guard.sh`'s hard-coded `bf_above_floor`
             list (whose omission fails silently), a missing-library bootstrap in two consumers,
             and either a new `check-*.sh` plus a `selfcheck` registry entry or a split test home.
             `common.sh` needs none of that: both consumers already source it, D30 already covers
             it, `bf_above_floor` already scans it, and `check-common-lib.sh` is already the home
             for exactly this kind of contract test. "Least coupled" counted the coupling a new
             file adds as zero; it is not.

             **(2) Fixing only the job enumerator would have left #102 unfixed in the reported
             case.** Reproduced before writing any code: a uniform 4-space `ci.yml` is rejected by
             `_adb_rs_file_verdict` — which pinned trigger names to 2 spaces and filters to 4 —
             *before* job enumeration is ever reached. And the issue's own suggested remedy,
             "detect the file's indent unit", is wrong for a file that has TWO (a 2-space `on:`
             block above a 4-space `jobs:` block is valid YAML that GitHub runs). Relative depth
             has no unit to get wrong, and it also makes the mixed case work rather than merely
             not crashing on it.

             **(3) The two empties had to stop being the same observable.** "This repo has no CI"
             (#24, legitimate, 0) and "this parser went blind" were indistinguishable, which is
             the whole of #102: the 4-space repo produced `nwant=0`, and `required-drift` — the
             backstop that was supposed to catch the under-requirement — derives its desired set
             from the same discovery, so it returned 0 and reported "in sync" about a comparison
             it never made. The structural check therefore runs on files the trigger verdict
             SKIPPED too: a blind trigger parse looks exactly like "no `pull_request` trigger", so
             checking only the files that passed would omit it from precisely the case it exists
             for. `20` rather than a new code because it already means "fail closed"; `12` in
             particular would have been a confident claim ("this repo has no CI") about a repo
             whose CI could not be read, sending the operator to the wrong remedy.

             STATED PLAINLY: this makes `repo-settings.sh` able to exit non-zero where it
             previously always exited 0, for adopting repos as well as this one. That is the
             behaviour #102 asks for, and every mapping is fail-closed — the worst outcome is an
             un-armed auto-merge and a named file, against a prior worst outcome of `apply`
             reporting success while gating nothing.

             REVIEW moved one line of this decision. The first cut treated ANY value on a job-key
             line as an inline flow mapping, and skipped every inline job outright. Independent
             review showed both halves were wrong in opposite directions: a YAML ANCHOR
             (`build: &base_job`) is an ordinary job whose properties still follow below, and an
             inline mapping with NO `name:` has a provably correct context — its key — so skipping
             it left valid PR CI ungated, the mirror image of the phantom this file exists to
             prevent. The reader now distinguishes `{…}` / `&anchor` / `*alias`, and reports
             `unnamed` so the consumer can require the key when that is provable.

             SCOPE REFUSED: discovery's matrix/`if:`/reusable/dynamic-name exclusions are
             unchanged, the floor lint still sees every one of those jobs, no YAML library or
             general parser was introduced, and the real workflows were not reindented. The reader
             is explicitly NOT a YAML parser: multi-line flow collections and merge keys (`<<:`)
             are unsupported and documented as such, and both under-report — which skips a job
             rather than requiring one that can never report.
- baseline-issue: #262, #102

## D45 — `no-ci` needs two probes, and the escape hatch that keeps the fix from reducing reachability
- date:      2026-08-05
- category:  general
- unknown:   #115 (consolidating #113) asks for `branch-health`'s CI-existence probe to become  <!-- adb-claim-ok: #113 was consolidated INTO #115 and closed NOT_PLANNED as superseded; the reference is the history of this change, not tracked work -->
             provider-agnostic using `read_branch` as the evidence source, and for an owner-visible
             escape hatch for a repo whose CI never reports on the default branch. Gap analysis
             raised four questions neither issue decides. (1) Whether "some contexts are required"
             is enough, or the context NAMES must be carried — a count leaves the masking hole the
             Actions arm exists to close. (2) Whether the owner opt-out may excuse an UNREADABLE
             required-context list, not just an unreported one. (3) Whether the opt-out reuses the
             existing `skipped` health value. (4) What authorizes a marker that bypasses a
             release-safety refusal, given an issue's author can edit its body forever regardless
             of repo permissions.
- decision:  (1) Carry the NAMES. `required_contexts` joins `branch-health`'s stdin document as a
             REQUIRED key (`array` | `null`), and a declared context that has not reported on the
             commit is `indeterminate`. This makes the arity change ONCE (2 args -> 3) rather than
             twice, which #115's API note asks for. (2) NO — `null` gets its own arm, is never
             `no-ci`, and the opt-out deliberately cannot reach it. (3) A NEW verdict word,
             `unreported-ok`; `release-ready` accepts it and it falls through to `met`. (4) The
             existing adopt-time `author_association` gate is the authority, and it is RE-VALIDATED
             at the point of use — `/roadmap` re-reads the artifact author's standing in the same
             step that acts on the marker.
- placement: `scripts/lib/roadmap-lib.sh` (`branch-health`, `release-ready`, the new
             `health-optout` marker predicate), `scripts/lib/repo-settings.sh`
             (`_adb_rs_classify_branch` + the `branch-required-contexts` subcommand),
             `base/workflows/roadmap.md` (schema marker, readiness snippet, emissions),
             `.claude/skills/release/release.sh`, fixtures in `scripts/check-roadmap.sh` +
             `scripts/check-roadmap-e2e.sh` + `scripts/check-repo-settings.sh`, pins in
             `scripts/check-fact-drift.sh`, and `docs/release-goal-convention.md` +
             `docs/roadmap-acceptance.md` + `docs/repo-settings.md`
- reason:    **(1) A count re-opens the hole through a second door.** The Actions arm exists because
             `$total` counts "somebody reported", not "everybody reported" — one unrelated green
             legacy status, or a check run from another Checks API app, would otherwise convert a
             genuinely unreported build into a confident `green`. A provider-agnostic probe that
             knew only "N contexts are required" would be beaten by exactly that input: required
             `["ci/circleci: build"]`, one green Vercel status, nothing from CircleCI -> `green`.
             With the names the predicate can ask the only question that settles it, and the
             subtraction is exact-value because GitHub matches a required CONTEXT by literal name.
             That is the whole of what is matched here, and it is narrower than what GitHub can
             express: the newer `checks` array can additionally bind a context to an expected
             `app_id`, so a same-named result from another provider satisfies the requirement. The
             `contexts` list is what `read_branch`, `live_contexts` and `required-drift` have always
             read, so this keeps the repo's one model rather than introducing a second — and it is
             not a regression, since before this change the names were not consulted at all.
             Measured against this repo before committing to the stricter rule: all 27 required
             contexts reported on `main`'s HEAD, so `on: push` repos are unaffected.

             **(2) Fail-closed beats reachability where the premise itself is unreadable.** The
             tempting argument for excusing `null` is that protection-readability is orthogonal to
             the results read, so the cut-safety question is still fully answered. It was rejected:
             letting an owner declaration override an unreadable state is exactly the shape
             `read_branch`'s `opaque` exists to refuse.

             THE FIRST IMPLEMENTATION OF THIS DECISION DID NOT HOLD IT, and independent review
             found it. Gating only the unreadable ARM is not the same as refusing an unreadable
             LIST: with `required_contexts == null` AND active Actions workflows, the ACTIONS arm
             matches first, so the opt-out excused precisely what this paragraph forbids. An early
             draft of this entry even reasoned FROM that behaviour — "a ruleset-protected PR-only
             Actions repo is already served by the Actions arm" — which described the defect rather
             than the decision. Both unreported arms are now gated on `$reqknown`, and the pin
             carries active workflows, the only fixture shape that can observe it. The cost is
             real and accepted: a ruleset-protected repo with PR-only CI cannot use the hatch.

             **(3) Two authorities must not share one word.** `skipped` is documented as the opt-out
             for a caller whose decision is NOT about shippable code (`baseline release roll`, which
             runs after the cut). This one is about shippable code, is chosen by the artifact rather
             than the call site, and is computed only after `branch-health` has ruled out failing,
             running and stale checks. Reusing `skipped` would make the two indistinguishable in the
             emission — and would let a caller hand-write the owner's decision. The cost is one arm
             in `release-ready` and its pinned value set; the alternative was a permanently
             ambiguous banner at the exact moment a release is cut.

             **(4) Adoption answers it once, and with the wrong field for this purpose.** The
             adopt gate refuses an artifact opened by a non-maintainer precisely because labelling
             an issue does not bring its body under maintainer control. That check is correct and
             sufficient for `## Decisions` rows, which only inform. This marker BYPASSES a refusal,
             so it is re-checked at consumption — and NOT with `author_association`, which is what
             adoption uses. Independent review showed that set does not mean what it looks like: an
             organization `MEMBER` can hold read-only access to a repo, and `COLLABORATOR` covers
             the read and triage roles, so it admits accounts that could never push a line of code
             but could arm a release cut by editing an issue body. The consumption check therefore
             asks `collaborators/{user}/permission` and honours only `admin` or `write`, failing
             CLOSED when the permission cannot be read (that endpoint needs push access itself, so a
             403 means authority could not be established — not a licence to assume it).

             SCOPE REFUSED: the marker-vocabulary generalization (#92, closed NOT_PLANNED) was not  <!-- adb-claim-ok: #92 is closed NOT_PLANNED; cited as the scope this change deliberately did NOT take on -->
             attempted — `health-optout` is a focused predicate in the shape `marker-title` and
             `release-command` already established. The unreachable arm #115 asked to disposition
             is DELETED, not revived: a first pass kept its verdict text and documented the
             unreachability, which review correctly called neither of the two things #115 asked
             for. What stands in its place is an `error(...)` — an assertion, not a verdict — so a
             state the arm table cannot describe refuses loudly (exit 2, a hard stop for every
             caller) instead of printing an `indeterminate` indistinguishable from a working one. The deliberate literals
             in `check-roadmap.sh` 4d, `check-repo-settings.sh` and `check-common-lib.sh` were left
             alone: they are API-contract fixtures whose whole value is that they do NOT derive the
             slug.
- baseline-issue: #115, #113, #183; the unprotected-branch residue is #293  <!-- adb-claim-ok: #113 was consolidated INTO #115 and closed NOT_PLANNED as superseded; the reference is the history of this change, not tracked work -->

## D46 — a second run in one checkout is REFUSED, and staleness (not ownership) authorizes the clear
- date:      2026-08-06
- category:  project-delta
- unknown:   #202. `/implement-issue` writes its run state to fixed paths, and preflight `rm -f`'d
             them unconditionally — so a second session's *start* deleted a first session's LIVE
             marker before #180's ownership check could ever see it, silently switching off the
             no-stop-until-PR invariant for a run that still needed it. The same clear released the
             live `gap-analysis.lock`, after which a concurrent `/cleanup` deleted the findings of a
             10-minute dispatch that was still running. The issue asked for the DECISION first:
             support concurrent runs, or refuse them.
- decision:  **Refuse.** Preflight calls `implement-lib.sh admit` before it touches anything; a
             second run in the same checkout is turned away rather than accommodated. Four
             sub-decisions carry the weight, because each picks a failure DIRECTION:
             (a) NO PER-RUN STATE PATHS. The sketch in #202's body (`implement-issue-active-<runId>`)
                 was rejected: two runs in one checkout share ONE HEAD, so they fight over the
                 checked-out branch whether or not their files collide. Per-run paths would make the
                 state layer safe for a configuration that still cannot work, at the cost of moving
                 the Stop hook, `.marker.tmp`, `state-scan`, `/cleanup` and every rendered workflow.
             (b) ADMISSION NEVER CONSULTS `owner`. A session is an ACTOR, not a run: ownership is
                 transferable (D17c), one session may legitimately invoke the workflow twice, and
                 `owners_compatible` reads an ABSENT owner as compatible — right for a hook deciding
                 whether to speak, wrong for a starter deciding whether to delete. So `owner`
                 governs enforcement and **staleness** governs deletion. A live marker refuses even
                 the session that wrote it.
             (c) STALENESS IS ASKED, NOT RE-DERIVED. `cleanup-lib.sh state-verdict marker` is
                 already the one home for "is this run marker dead?", and `/cleanup` reaps a crashed
                 run's marker with it today — which is why the deferral reason recorded in D17
                 ("preflight is the only cleaner, so an owner-aware preflight would leave a crashed
                 run uncleanable") was wrong, as #202's own comment says. `admit` gathers the same
                 three facts the same way `base/workflows/cleanup.md` does and asks that predicate.
             (d) ADMISSION IS SINGLE-THREADED, inside a `mkdir` lock on the state directory. Three
                 rounds of making each individual step safe were not enough, and each looked it:
                 `rm -f` + re-create let two breakers win; a `rename` made the move exclusive but
                 not its OPERAND, so a delayed breaker took a successor's claim (three winners);
                 verifying the operand and re-reading our own token after acquiring still left the
                 real hole, which macOS CI found — a losing breaker MOVES the claim before it can
                 know whose it is, and a third contender acquires in the few syscalls while the path
                 is free, after the first run has already passed its re-read. A window that opens
                 behind you cannot be closed by checking afterwards. The lock is held for the
                 duration of `admit` only (sub-second plus at most one `gh` call), never for the
                 run, and is broken on age at 5 minutes so a killed admission cannot block a
                 checkout. The per-step guards are kept as defence in depth because `release` runs
                 outside the lock, from another process.
                 ACQUIRE BEFORE YOU CLEAR, still. The claim is taken BEFORE anything is deleted, by
                 `link`ing a fully-written temp file into place — create-or-fail like `O_EXCL`, but
                 with no window in which the claim exists and is EMPTY (a `set -C` + `>` acquire
                 creates the file at redirection time and fills it after, and a contender reading it
                 in between calls it corrupt and breaks it). A session that loses the race for a
                 HELD claim is refused having mutated nothing; breaking an EXPIRED claim removes a
                 stale file, and is a `rename` whose OPERAND IS VERIFIED — a bare rename is exclusive
                 about the move and says nothing about what it moved, which let a delayed breaker
                 rename a successor's brand-new claim away (the review reproduced three winners).
                 Identity and expiry are read in ONE probe for the same reason: as two reads, a
                 breaker could pair the old file's expiry with the new file's identity and verify
                 the very claim it was meant to protect. After acquiring, the run re-reads its own
                 token before acting, because a losing breaker frees the path for a few syscalls.
                 With the lock the property is EXACTLY one winner, and it holds under load: the
                 suite races twelve contenders against both an empty directory and an expired claim
                 and requires one of each, and is run under eight concurrent copies of itself —
                 which is how the earlier two-winner and zero-winner outcomes were both reproduced.
                 Check-then-act between two reads was the residual hole a plain guarded clear would
                 have left. And because a verdict still describes the marker *as it was read*, the
                 file is re-identified at the delete with `cleanup-lib.sh marker-identity` — the
                 same primitive, and the same rule, `/cleanup` already applies at ITS delete. A
                 marker that changed in between belongs to a different run, so this one stands down
                 and releases. The identity is captured BEFORE the ref and `gh` reads, not after: a
                 capture taken after them fingerprints whatever arrived during them and would
                 compare a replacement against itself (observed while writing the test).
             The claim is the EXISTING `gap-analysis.lock`, widened rather than joined by a second
             file: it already means "a run is live and has not written its marker yet", and
             admission only moves its acquisition earlier (preflight instead of step 3) so it covers
             that whole pre-marker window. `/cleanup` reads it unchanged, and holding it longer only
             ever preserves more. A second lock beside it could leak, be cleared late, and disagree
             with the first — the trap D40 declined for review artifacts.
             It carries a **lease of 9000s (2h30m)** — a flat constant, deliberately NOT derived
             from `ADB_DISPATCH_TIMEOUT_SECS`. Deriving it meant this module independently
             interpreting a variable `role-dispatch.sh` already owns, and the two immediately
             disagreed: role-dispatch rejects a zero or non-numeric value and falls back to 2700,
             while the arithmetic here accepted `0` and choked on `08` as octal. One owner per
             environment variable. `ADB_RUN_CLAIM_LEASE_SECS` overrides it, and an invalid value is
             an ERROR rather than a silent fallback.
             The lease is the answer to the permanent-block risk #202 warns about: `/cleanup` never
             deletes a `lock` record, and preflight no longer clears one unconditionally, so without
             an expiry one killed run would refuse every later run in that checkout forever.
             **It is a real trade, not a free fix**: a run that outlives its lease CAN have its claim
             broken while it is alive. Two things bound that, and neither removes it — the exposure
             is PRE-MARKER only (once step 5 writes a marker, a second run is refused on the marker
             regardless of the claim, and this run has released the claim anyway), and 9000s is far
             longer than that window can legitimately be (one 45-minute dispatch, at most one retry,
             plus reading). The alternative is the permanent block, which is worse.
             This is not "mtime as liveness" — the file's age is not evidence about a PR or a
             branch; it is an expiry on a lease. A pre-#202 empty lock has no lease and is broken
             with a reported NOTE, which is the migration path and matches the unconditional clear
             it replaces.
             **`release` drops only the claim its caller holds**, compared by a per-acquire `token`
             that `admit` prints and the workflow threads to every release site. An unconditional
             `rm` was a hole in the same family: if a run's lease expired and a successor
             legitimately took over, the first run's later stop path deleted the SUCCESSOR's claim
             and a third run walked in behind it.
             **The tokenless fallback is weaker, and the limit is recorded rather than implied.**
             `release` is a fresh process with no memory of what its run took, so without a token it
             can only compare the claim's `owner` against the caller's session id. That catches a
             successor from a DIFFERENT session; a successor carrying the same owner, or none at all
             (the shape a harness with no session id writes), is indistinguishable and is released.
             Refusing instead would strand a claim on every stop path for those harnesses, which is
             worse — so the fix is that the workflow passes `--token`, and a test pins that every
             release site does.
- placement: `scripts/lib/implement-lib.sh` (new; the decision) · `base/workflows/implement-issue.md`
             (preflight, the step-2/4/5 release points, step 3's no-longer-taken lock, rendered to
             all three agents) · `scripts/build.sh` + `base/workflows/README.md` (the
             `{{IMPLEMENT_LIB}}` placeholder) · `scripts/check-implement-lib.sh` (new suite) ·
             `scripts/check-implement-gate.sh` (the end-to-end acceptance case) ·
             `scripts/check-cleanup.sh` (the containment guard, now EXECUTED) · `scripts/selfcheck.sh`.
- reason:    Ownership made the READER safe; nothing made the PATH exclusive, and the path is what a
             second *start* attacks. Refusing is also the honest model of what the tool can do:
             #159 (see a sibling agent live in this tree) and #206 (a shared atomic claim-release)  <!-- adb-claim-ok: both are cited as DECLINED work, which is the whole point of the sentence; they deliberately track nothing -->
             were both closed NOT_PLANNED, so no design here may assume host-terminal liveness — and
             none does. Every refusal is decided from an observable fact instead: a branch ref, a
             PR state, a lease, a file mode.

             **Not all of those resolve on their own, and claiming they do would be false.** A lease
             expires and a merged PR's branch disappears, but an abandoned marker whose local or
             remote ref survives is kept by `admit` AND by `/cleanup`, by design; so are a malformed
             marker, an indefinitely-open PR with both refs gone, a persistent `git`/`gh` failure,
             missing `jq`, and a state directory with the wrong permissions. Those need the
             operator. The property this change actually keeps is narrower, and is the one worth
             stating: **no refusal blocks a checkout without printing what will clear it** — the
             message names the branch to finish, `/cleanup`, or the exact file to delete.

             **The scope is this agent's state directory, stated rather than implied.** `{{STATE_DIR}}`
             is `.claude/state` / `.codex/state` / `.gemini/state`, so this excludes a second run of
             the SAME agent, and nothing more. A Claude run and a Codex run never collide on these
             paths at all; they collide on HEAD, and only PARTIALLY — the branch check hard-errors
             once one of them has switched away from the default branch, but two agents starting
             CONCURRENTLY while both are still on it both pass, and whichever branches first moves
             the other's HEAD underneath it. Cross-agent exclusion would need a new shared state
             home and is deliberately not invented here. Nothing in this change may be described as
             checkout-wide.

             **What is NOT closed, named rather than claimed.** The refusal is decided from
             staleness, which cannot tell a live run from an abandoned one whose branch still
             exists — so an abandoned run does block new runs in that checkout until `/cleanup`
             reaps it or the operator removes the marker, and the refusal message names all three
             ways out. That is the deliberate direction: the alternative is guessing a run is dead,
             which is the fail-open this exists to remove. The window a lease covers is likewise
             bounded, not eliminated.

             **The test moved with the decision.** `check-cleanup.sh`'s containment guard used to
             grep the preflight PROSE for each pattern `state-scan` sweeps; the clear is a real
             script now, so it RUNS it — materializing one file per pattern derived from the
             library's own arms and requiring every one to be gone. Both suites were driven red on
             mutation — removing the refusal, reverting the acquire to create-then-write, reverting
             the break to `rm -f`, making `release` unconditional, dropping the readability check,
             mapping an unreadable PR state to `none`, letting ownership authorize the clear, and
             narrowing the clear set — because a guard whose failure mode is *deleting something* is
             indistinguishable from a healthy run until it is watched failing. The concurrency cases
             run eight real processes against one directory, and the suite says which of them
             actually catches a non-atomic acquire (the EXPIRED-claim race) rather than implying the
             empty-directory race covers it.

             **Three defects the PR review found, all the same shape — refusing forever rather than
             admitting twice.** A dangling symlink at the claim path reads as absent to `-e` while
             still making `ln` fail with `EEXIST`, so admission reported "not writable" and never
             reached the break path; a failed `git switch -c` kept the claim over an invocation that
             started nothing; and the claim token lived only in a shell variable while the releases
             that need it sit in later fenced blocks that may run as separate shells. Every
             existence test on the claim now asks `-L` too, an unreadable claim probes to NO identity
             (so the break removes it unconditionally rather than comparing an empty-string digest
             against an undigestable link), the branch-creation failure releases, and the workflow
             prints the token and tells the agent to substitute its literal value.
- baseline-issue: #202

## D47 — cadence is a gate's CALLER, not a budget; and ownership suppresses only on positive proof
- date:      2026-08-06
- category:  general
- unknown:   Two Stop-hook defects with one shape: the gate had no notion of WHEN it was being
             asked to run (#240) and no notion of WHOSE tree it was gating (#241). `[gates]`
             could say what a gate costs to run but not that a cost was wrong for a cadence, and
             `[gates.scope]` could not stand in — a repo-wide CI mirror legitimately matches
             almost any changed path. Meanwhile the gate's inputs were pure git state, which
             carries no session identity, so a session that wrote nothing ran (and could be
             blocked by) another session's mid-edit tree at every turn-end.
- decision:  **#240 — a cadence key, spelled as a third `[gates.*]` sub-table.** `[gates.cadence]
             <label> = always|full|turn-end`, default `always`, resolved in `_adb_resolve_record`
             beside state and scope. `adb_run_gates` takes a third `context` argument
             (`turn-end`|`full`, default `full`); a gate runs iff `cadence == always` or
             `cadence == context`. The Stop hook is the only caller passing `turn-end`.

             The issue offered four shapes and this is its option 1. The other three were
             rejected on evidence: a seconds *budget* needs timing history that does not exist; a
             shipped project-gate *template* answers "how do I fork?" when the point is not to
             fork; *detect-and-warn* names the problem without giving anyone a way to fix it.

             **The value is `full`, NOT `pre-push`, and that is a correctness point rather than a
             naming preference.** There is no automatic pre-push path in this framework — nothing
             wires a pre-push hook. `project-gates.sh run` is a manual/full invocation that the
             workflows happen to call before they push. Naming the value `pre-push` would have
             promised a guarantee the gate model cannot make, and a hand-typed `git push` would
             have quietly broken it.

             **#241 — suppress only on positive proof, never on absence of evidence.** The gate
             no-ops when a run marker for THE CURRENT BRANCH is owned by a DIFFERENT session.
             Every unknown — no marker, a marker for another branch, a malformed or ownerless
             marker, no `jq`, no `CLAUDE_CODE_SESSION_ID` — keeps the pre-existing run-and-block
             behaviour.

             That is deliberately NARROWER than the issue's own preferred direction, which was
             "when ownership is unknowable, prefer reporting over blocking". Taken literally that
             disables the gate for nearly every ordinary dirty tree, because a marker exists only
             during an `/implement-issue` run — the fail-silent class of #35 and §5 of
             `design-principles.md`. It is not a judgement call in retrospect: mutating the
             implementation to suppress on unknown ownership turns SEVEN pre-existing
             fail-loud assertions red, including the #35 regression tests themselves.

             **The ownership check sits BEFORE the project-gate `exec`, and reads identity from
             the environment only.** Both halves are forced by evidence. The second observed
             incident reported `build-drift FAIL` — a check name in this repo's OWN
             `.claude/scripts/precommit-gate.sh` — so a check placed after the delegation would
             miss the very case the issue documents, in every repo using the escape hatch. And
             `docs/per-project-overrides.md` documents the `exec`'d project gate as inheriting
             stdin (the hook payload), so consuming stdin to identify the session would break a
             documented contract to answer an optional question. A host exposing no session id
             therefore degrades to "unknown" → enforce: one rung shorter than
             `implement-issue-gate.sh`, stated rather than implied.

             **The comparator is promoted; the session-id READER is not.** `adb_owners_compatible`
             moves to `common.sh` as the one home for "do these two ids permit acting". Its
             callers keep their own identity discovery, because those differ by design — the
             sibling gate may read the payload, this one must not. Only the pure comparator enters
             `common.sh`, which must stay parseable below the bash floor (D30); nothing
             version-sensitive was added to it.

             **The timeout deliverable is rescoped, not delivered.** #240 asked for a gate that
             exceeds the hook timeout to be "terminated with a classified status". That cannot be
             built as asked: the 240s bound belongs to the Claude harness, which cancels the hook
             — a killed process cannot then report its own status. A separate INNER deadline would
             be a different feature, and reusing `adb_run_bounded` for it would inherit that
             helper's documented macOS limitation (grandchildren outliving the bound), which an
             arbitrary `sh -c` gate is especially likely to hit. Sequential gates each consuming a
             per-gate allowance also leaves the TOTAL unbounded, so a per-gate timeout would not
             even substitute for the harness bound. What ships instead is per-gate ELAPSED
             reporting — which is what makes a slow gate attributable — plus documentation of what
             the 240s bound is and is not. The 18m55s that motivated the ask does not reproduce
             (#260/D37 measured 273s serial, 66-72s parallel), so the cost problem is answered by
             cadence rather than by a kill.
             **Two defects self-review found in this branch's own new code, both failing toward the
             gate switching itself off.** First, reading `.branch`/`.owner` as two newline-separated
             values let a newline INSIDE a field re-aim the decode — an owner of `<my-id>\nBBBB`
             truncated to something that no longer matched me, and a branch of `feat\nevil` matched
             `feat` while replacing the real owner with `evil`. `@tsv` fixes the shifting, and a
             plausibility test on the decoded owner fixes what @tsv faithfully preserves: a corrupt
             value is a broken marker, not proof of a second session, and only proof may suppress.
             Second, `_adb_rec_split` bound caller-supplied names with `local -n` without validating
             them; dropping the validation and re-running the suite showed the subscript in
             `arr[$(touch pwned)]` ACTUALLY EXECUTING, confirming D34's arbitrary-command-execution
             claim on new code in a library that installs into consumer repos. It adopts D34's
             identifier-plus-reserved-prefix rule, and deliberately not that function's fuller
             `declare -p` chain analysis: this helper is private and both call sites pass literals,
             so the nameref-chaining seam needs a caller that does not exist. If it is ever made
             public it owes the fuller check.
             **What the independent review changed.** Eight REQUIRED findings, all taken. The one
             that altered behaviour: a same-branch foreign marker suppressed the gate with no
             liveness bound, so a CRASHED run would have left its branch un-gated for every later
             session indefinitely — and in a repo that also declared its gates `full`, turn-end
             enforcement would have been gone entirely, which is the exact combination this design
             exists to avoid. The suppression is now bounded by marker age
             (`ADB_MARKER_STALE_SECS`, default 9000 to match #202's run-claim lease). The canonical
             staleness predicate `cleanup-lib.sh state-verdict marker` is deliberately NOT used:
             its `<pr-state>` argument must come from a live `gh` query, and a hook that fires at
             every turn-end cannot afford a network round trip — age is the signal that is both
             offline and honest at this cadence. The skip message was also over-claiming (that the
             other session "gates that work", that this one "did not write it"); a marker records
             who STARTED a run, not who made the changes, and it now says only that.

             The rest were accuracy and test-strength: "every skip is reported" was false (a
             DISABLED gate is silently skipped, by long-standing design) and is now scoped to
             cadence and scope skips; "behaves exactly as before" was false for stderr consumers,
             since a passing gate now prints an elapsed line, and is now scoped to selection and
             exit status. Four test gaps were real — the no-`jq` path was unreachable by any
             fixture (every ownership fixture NEEDS jq, so a mutation suppressing on a missing jq
             would have passed; it now runs against a symlink farm that genuinely lacks it), the
             unknown-ownership cases asserted only `rc=2` without proving the gate EXECUTED, the
             elapsed assertions matched words rather than a measured number, and #241's own
             "exactly one comparator" criterion was behavioural-only and is now pinned structurally.

             **The timeout criterion is re-homed rather than dropped**: #297 (Backlog), which
             records the diagnosis and depends on #141.
- placement: `scripts/lib/project-gates.sh` (cadence + elapsed), `scripts/lib/common.sh`
             (`adb_owners_compatible`), `agents/claude/scripts/precommit-gate.sh` (ownership +
             the `turn-end` context), `agents.toml` `[gates.cadence]`, `templates/agents.toml`,
             `docs/per-project-overrides.md` §3a.
- reason:    Both are general capabilities every adopting repo inherits, so they belong in the
             shared gate model rather than in this repo's own gate script. D25 recorded the LOCAL
             stopgap for #240 and said the general half stayed open; this is that half. This
             repo's `.claude/scripts/precommit-gate.sh` deliberately REMAINS — its fast subset is
             a different set of checks, not merely a cheaper cadence, and `[gates]` cannot express
             a changed-file-scoped shellcheck. So the new `[gates.cadence] test = "full"` line in
             this repo's manifest changes nothing about its turn-end behaviour today; it is the
             correct declaration for the general mechanism and what would take effect if the local
             gate were ever removed.
- baseline-issue: #240, #241

## D48 — the drift verdict is a fact on push and a prediction on a PR, and only a fact may hard-fail
- date:      2026-08-06
- category:  project-delta
- unknown:   #122 put `required-drift` in CI so a newly added job could not silently stay
             non-required, and it worked — but the step was wired to ONE question asked on TWO
             events, and the baseline models neither "a guard whose verdict changes meaning with
             its trigger" nor "a CI step that must report without failing". `required-drift`
             discovers jobs from the CHECKED-OUT tree and reads required contexts from the DEFAULT
             BRANCH. On a push to `main` those are one tree, so the answer is a fact. On a PR they
             are two, so the answer is a prediction about a merge that has not happened — and #122
             hard-failed on it.

             That had an unmodelled tail. The only way to make the introducing PR green was
             `baseline repo apply` FROM the PR branch, which requires the context on `main` before
             the job exists there. Abandon that PR and `main` is left requiring a context nothing
             will ever report: every merge blocked, clearable only with an admin token CI does not
             have. `docs/repo-settings.md` shipped that as a documented operating caveat and said
             the fix "is filed as a follow-up rather than guessed at here".
- decision:  **Split the step by event.** The `push` arm keeps the hard failure; the
             `pull_request` arm reports the same finding as advice and never fails on it. The
             `github.ref == refs/heads/<default>` disjunct in the old `if:` is deleted, which is
             sound only because #99's half of this issue landed first.  <!-- adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work -->
             `on: push: branches: [main]` makes `event_name == 'push'` already mean "the default
             branch".

             **Deleting that disjunct ALONE would have been a bug**, and the gap-analysis pass
             flagged it as the single biggest risk: it leaves one PR-only step and removes every
             hard failure in the file. The disjunct is redundant with respect to the SPLIT, not on
             its own. Recorded because the issue text described the deletion without the split.

             **`required-drift --porcelain`** (new): same exit codes, stdout carries only the
             drifted context names, no prose and deliberately no remedy. The advisory step needs
             the NAMES; what it must not do is echo the human code-14 text, which ends in
             `baseline repo apply` — correct on the default branch, and the precise instruction
             that strands a phantom context when followed from a PR branch. A caller that parsed
             the prose would have repeated the hazard this entry exists to remove.

             The flag is REFUSED by the other four read subcommands rather than accepted inert: it
             reshapes one command's stdout, and an accepted-but-inert flag promises an output
             change that did not happen (the same reason `branch-required-contexts` refuses
             `--branch`).

             **The advisory SURFACE is written by the workflow step, not the library** —
             `$GITHUB_STEP_SUMMARY` plus a `::warning`. That preserves `repo-settings.sh`'s stated
             boundary (it reads `.github/workflows` and writes only the two GitHub settings
             `apply` owns), and both surfaces need no permission beyond the `contents: read` this
             workflow already declares. A PR comment would need `pull-requests: write`, which a
             fork PR's token does not get; `pull_request_target` was rejected outright, since it
             hands elevated credentials to a workflow that runs PR-authored code.
- placement: `.github/workflows/ci.yml` (the two arms + the `on: push` filter),
             `scripts/lib/repo-settings.sh` (`--porcelain`), `scripts/check-repo-settings.sh`
             (predicate + wiring assertions), `scripts/check-fact-drift.sh` (the three-surface
             pin), `docs/repo-settings.md` ("Which event asks the question decides what the answer
             means"), `CLAUDE.md` golden rule 3.
- reason:    A guard whose only remedy manufactures a deadlock is the wrong guard. Moving the hard
             failure to the event where the comparison is a FACT keeps #122's property — a job
             that gates nothing gets caught, loudly, with a one-command fix — while removing the
             window in which following the guard's own advice breaks the repo.

             **WHAT THIS GIVES UP, because it is a real loss and not a wash.** A PR can now add a
             job that is red and non-required and still merge; the first hard failure comes after
             it lands. The exposure moves from "never caught" to "merged but not yet applied", and
             the backstop is the push arm going red immediately. That is #165's own acceptance
             criterion — "report a PR's prospective drift as advisory" — so it is an accepted
             trade, not an oversight, and it is stated in `docs/repo-settings.md` rather than left
             for someone to discover.

             **Only a proven `14` is softened.** A `20` — live state unreadable, discovery
             contradicting it, or a workflow file the parser could not read (#102) — still fails
             the PR. "Your PR predicts drift" and "the comparison could not be made" are different
             answers, and collapsing them would have bought the advisory by reintroducing the
             fail-open #102 closed.

             **The wiring is pinned STRUCTURALLY, and the fact pins do LESS than they look like
             they do.** `required-drift-wired` is a fixed-string presence test over `ci.yml`, and
             that file names the invocation in COMMENTS as well as in the two `run:` lines — so it
             survives BOTH steps being deleted, and it survives the two `if:` conditions being
             swapped, which would leave the default branch merely advised while pull requests are
             hard-failed: the exact inversion of this decision, under a green lint. (The review
             caught this entry over-crediting the pin with catching deletion; it does not.)

             So `check-repo-settings.sh` carries the real guard: it COUNTS the call sites, compares
             each arm's `if:` for EQUALITY (a token search passes `== 'push' && false`, and an
             equality does not), requires the enforcing arm's `run:` to invoke the library rather
             than merely name it, parses the `push:` branch filter into entries and compares them
             exactly to `main` (a substring test is satisfied by `[not-main]`, and one that reads
             comments is satisfied by a commented-out filter), and finally EXECUTES the advisory
             step's shell under `bash -e` against a stub. Every one of those was observed going RED
             on a copied tree.

             The execution matters most, and it is why "structural" alone was not enough: the arm
             first shipped as `drifted="$(…)"; rc=$?`, which is correct under `bash file` and fatal
             under `bash -e file`. GitHub runs a Linux `run:` step as `bash -e {0}` and
             `set -uo pipefail` does not clear errexit, so on the drift path the step died at that
             line with exit 14 — no advisory, PR hard-failed, this decision inert — while every
             static assertion still passed.
- also:      D13 is AMENDED, not contradicted. It reasoned about "the live assertion" as one CI
             step; there are now two, on the same job, reading the same live state. The hermetic
             boundary it drew is untouched — `selfcheck` still runs the offline half through the
             `gh` stub, and now the offline half covers the wiring as well as the predicate.

             The `on: push` filter (#99, consolidated into #165) is what makes the disjunct <!-- adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work -->
             deletion legal, and it is not free: `branches:` excludes TAG pushes, so pushing a
             `v*` tag no longer runs `ci.yml`. Safe here for two independent reasons —
             `wsl-smoke.yml` carries its own `push: tags: ['v*']`, and `/release` verifies the
             merge commit is green BEFORE it pushes the tag — but "zero risk" was the issue's
             word, not this entry's. It also ends the doubled check-run shape on this repo's PR
             heads (measured: `total=54 distinct=27` on PR #296), which `release-lib.sh`'s
             distinct-name counting was written against; that counting stays, because a re-run
             duplicates a name on any repo and adopting repos may keep unfiltered triggers.
- baseline-issue: #165 (supersedes #99) <!-- adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work -->

## D49 — the bound reaps a GROUP on both paths, and the log cap is a head cap outside the diagnosis
- date:      2026-08-06
- category:  project-delta
- unknown:   #141 asked for two things whose CODE homes were never in doubt — the bounded-execution
             primitive already lived in `common.sh`, dispatch-specific stream handling already
             lived in `role-dispatch.sh`. What had no prescribed answer was the POLICY each needed:
             the process-group MECHANISM, and the cap's scope, contract and topology. First, `adb_run_bounded`'s two
             paths agreed on STATUS and diverged on process CLEANUP: GNU `timeout` signals a
             process group, the portable watchdog signalled one PID, so on a stock Mac — the exact
             host the fallback exists for — a grandchild outlived the bound while the caller got a
             clean 124. Reproduced: watchdog `alive`, timeout binary `dead`, both rc 124. Second,
             a single dispatch's captured stream had no bound at all. The issue named 674 KB and
             428 KB; the gap-analysis pass for this very issue wrote **766,399 bytes**.

             Neither had a prescribed home. The mechanism question was open (`setsid` is absent
             from stock macOS, and `set -m` is shell-global in a SOURCED library with two live
             callers), and the issue itself left the cap's scope, contract and topology
             unresolved — it called the scope "an open question that gates #123's test matrix".  <!-- adb-claim-ok: #123 was closed NOT_PLANNED as SUPERSEDED by #141, which consolidated it; the reference is this change's provenance, not tracked work -->
- decision:  **Process group via job control held for exactly one command.** `set -m`, the `&`,
             then restore the caller's prior state — read from `$-`, so a caller that already had
             job control keeps it and one that did not never acquires it. Signalling is
             `_adb_bounded_signal`: the group form AND the bare pid, unconditionally, because the
             group form only lands if `set -m` took effect; and a `''|0|*[!0-9]*` guard, because
             `kill -- -0` signals the caller's own shell and everything in it.

             This is **not a new invention** — `scripts/selfcheck.sh`'s `_cleanup` already reaps
             its worker pool by exactly this rule, `-0` guard and dual form included. It was
             written for the same problem one level up and its header cites #141 as the open
             case. `adb_run_bounded` now matches it; the prose in both files is corrected so
             neither still describes the divergence as live.

             **`wait -f`, but only under a caller's job control.** With job control on, plain
             `wait` returns when a job merely CHANGES STATUS — measured returning **145 in 0 s
             with the child alive and running** — and a naive re-wait loop **spins** (51
             iterations in 0 s, measured). Putting the child in its own group makes that newly
             reachable without an operator ^Z, since a background group reading the tty takes
             SIGTTIN, so the flag is part of this change rather than a tidy-up. It applies to
             BOTH paths: with job control on, bash puts the `timeout` binary in its own group too,
             so this was never watchdog-only.

             It is gated on TWO conditions — job control on AND bash 5.1+ — and the second is not
             redundant. The tempting single condition ("anything old enough to lack `-f` has job
             control off") is FALSE: bash 3.2 supports `set -m`, so a 3.2 caller reaches that line
             with had_m=1, and an unguarded `wait -f` fails there with `invalid option` and status
             2 — returned as the child's status while the child runs on. Verified on Apple's
             /bin/bash 3.2.57. D30 holds because the capability is CHECKED, not assumed.

             **The cap: `ADB_DISPATCH_LOG_MAX_BYTES`, 256 KiB, `0` disables, invalid warns and
             falls back.** Three sub-decisions the issue left open:

             1. **Every agent and every role, in `role-dispatch.sh`.** `review.err` is the same
                stream from the same code path with the same growth, so capping only
                gap-analysis would leave the identical defect next door — and a review slot is
                dispatched by bare TOKEN, which carries no role to key a policy off. Not
                `common.sh`: one consumer, and that file must stay parseable below the floor
                (D30) — the `cpu_count` precedent in `selfcheck.sh`. Not the workflow: too late,
                and it would make every consumer re-implement it.
             2. **A HEAD cap, decided on evidence.** Gap analysis recommended keeping the tail.
                Measurement rejected it: codex's final message is captured separately by
                `--output-last-message`, and on the 766 KB stream that message was found
                duplicated at byte 758,388 — the tail is the one part already preserved IN FULL
                elsewhere, while the head carries the CLI version, model, reasoning effort and
                session id that nothing else records. A head cap also streams live.
             3. **The cap bounds the AGENT's stream, NOT this helper's own lines.** Gap analysis
                argued the cap must cover everything "or `gaps.err` can still exceed it". Refused
                deliberately: `/implement-issue` is instructed to read the classified
                `role-dispatch:` line at the TAIL of `gaps.err`, and a cap that included it would
                bound the file by deleting the one line that says why the dispatch failed. Those
                lines are O(1); the stream is the unbounded thing. The file is therefore bounded
                by `cap + a small constant`, and that is the correct contract.

             **The filter topology.** `exec {capfd}> >(_adb_rd_cap_stream …)`, not a pipeline: a
             pipeline puts the LEFT side in a subshell, and `adb_run_bounded` installs its reap
             trap on the CALLING shell — the trap would protect a subshell that is not the one
             being signalled, re-orphaning the agent under an outer TERM. `exec` rather than a
             redirection on the command, because `$!` must name the procsub and
             `adb_run_bounded` overwrites `$!` with its own child and watcher. The filter DRAINS
             past the cap instead of exiting, or the next agent write takes SIGPIPE and capping a
             log would kill the dispatch. `{capfd}>&-` on the call closes the descriptor for the
             child side: the watchdog's ticking `sleep` is deliberately allowed to outlive its
             watcher, and an inherited write end held the pipe open for a whole tick — measured
             5.0 s per dispatch, 0.05 s with the close.

             **`dd bs=1` + `wc -c`, after awk was tried and rejected.** `head` over-reads into its buffer: it loses an
             unknown number of bytes and can swallow the entire remainder, leaving the drain to
             see EOF and report a clean pass on a stream it silently truncated. awk counts every
             discarded byte, so the notice is never omitted; `LC_ALL=C` makes
             `length()` count bytes so a multibyte stream cannot overshoot. The count is exact for
             a NEWLINE-TERMINATED stream and over-reports by one for an unterminated final line —
             documented rather than engineered away, being a debugging aid in a notice.

             **awk was the first implementation and the review killed it.** Record-oriented, it
             does not act until it sees a newline: a newline-free stream buffered whole, emitted
             none of the head bytes while the agent ran, and grew without bound — an indefinitely
             noisy stream could OOM the filter and SIGPIPE the agent it was meant to protect. It
             was also not binary-safe (BSD awk treats a NUL as end-of-string: `ab\0cdef...` gave
             `ab`, no remainder, NO notice — macOS only). `dd bs=1` reads exactly `max` bytes, holds
             one byte, writes as it reads and is byte-transparent, so every one of those goes away
             and the count becomes exact rather than off-by-one on an unterminated line. Measured
             0.21 s for a 256 KiB cap; a 5 MB newline-free stream in 0.23 s with flat memory.

             **The cap also introduced a hang, which is now bounded.** Closing our write end is not
             closing the pipe: a background descendant that inherited the agent's stdout/stderr
             holds it, the filter never sees EOF, and the wait blocks forever — AFTER
             `adb_run_bounded` returned, so its bound no longer applies. `ADB_DISPATCH_LOG_DRAIN_SECS`
             (10 s, ticked so it leaks no orphan) bounds it and reports why the log ended early.
- placement: `scripts/lib/common.sh` (`_adb_bounded_signal`, the launch, the watcher, the reap,
             the wait); `scripts/lib/role-dispatch.sh` (`_ADB_RD_LOG_MAX_BYTES`,
             `_adb_rd_cap_stream`, `_adb_rd_bounded_capped`, the three agent arms);
             `scripts/check-common-lib.sh` + `scripts/check-role-dispatch.sh` (coverage);
             stale prose corrected in `scripts/selfcheck.sh` and
             `base/workflows/implement-issue.md`.
- reason:    A project-delta rather than a general gap: both are defects in this repo's own shared
             library, fixed in the one home each already had. No new config surface was invented —
             the cap knob follows the `ADB_DISPATCH_*` shape the bound and grace already use.
- baseline-issue: #141 (supersedes #123)  <!-- adb-claim-ok: #123 was closed NOT_PLANNED as SUPERSEDED by #141, which consolidated it; the reference is this change's provenance, not tracked work -->
- also:      **The guards were observed failing, against a copy of the pre-fix tree, never the
             working tree.** Watchdog grandchild `alive`→`dead`; stopped child `rc=145`→`rc=0`;
             nine cap assertions red without the cap. The timeout-binary grandchild case is green
             on BOTH sides and is named as an agreement pin, not a regression detector.

             **CI corrected a premise this entry had accepted.** The issue reported the
             `timeout`-binary path as already reaping grandchildren, measured on macOS, and the
             first cut encoded that as an "the paths AGREE" pin. On `ubuntu-26.04` the identical
             probe left the grandchild ALIVE on that path. The lesson is not about coreutils
             versions: a guarantee that matters should not rest on a third-party tool's undocumented
             group semantics, so the binary path now takes `set -m` too and sweeps its group after
             the wait. Conditional on the bound having fired — a command that finished on its own
             may have deliberately left work running, and an unconditional sweep would kill it
             (pinned by its own case, observed failing).

             **Self-review found the `-0` guard did not actually guard.** `''|0|*[!0-9]*` rejects
             the string `0` and not `00`, and `kill -- -00` resolves to group 0 — the caller's own
             shell. Both sides are arithmetic now. The rule was copied from `selfcheck.sh`'s
             `_cleanup`, which **carried the same gap in both loops** and is fixed here rather than
             filed: a confirmed sibling of the same defect, in a file this change already touches
             (`base/practices/debugging.md` — grep for the class, not the instance).

             **A first version of the grandchild guard was itself flaky and was rewritten.** It
             counted `ps -eo command` matches for a fixed argv marker, which a stale `ppid 1`
             orphan from an earlier aborted run also matched — turning a tree that was actually
             fixed red, and the marker had to be kept out of the harness's own argv besides. It
             now asks one RECORDED pid whether it is alive, with a zombie counted as dead. That
             failure is recorded because a name-scan probe is the obvious first thing to write.

             **The independent codex review raised 23 findings; all were acted on.** Four were
             already fixed by the self-review commit that preceded it (the timeout-path `wait`, the
             `-00` guard, the tautological "0 disables" assertion, the missing `env -u`). The rest
             produced the `wait -f` capability gate, the NUL guard, the filter-status warning, the
             range check on the cap value, the truncated diagnostic, the `_cleanup` de-duplication,
             and five test repairs (missing-evidence false pass, an unsynchronised STOP, nested
             bare `bash` resolving to macOS 3.2, no prefix/NUL/CRLF/newline-free fixtures, and no
             coverage of the `log_stdout=0` arm). Two were answered by wording rather than code:
             the outer-reap ordering race is now stated instead of dismissed as "nothing to
             protect", and the acceptance criterion that `gaps.err` "cannot exceed the cap" is
             named as a deliberate deviation rather than reported as met.

             **The one-home law was the review's sharpest point and it was right.** The first cut
             "matched" `selfcheck.sh`'s `_cleanup` rule rather than sourcing it — and the proof
             that this was duplication, not convergence, is that BOTH copies shipped the `-00`
             defect and both had to be fixed. `_cleanup` now calls `_adb_bounded_signal`.

             **#181's "ship this before the common.sh promotion sweep" is moot**: #181 was  <!-- adb-claim-ok: #181 was closed NOT_PLANNED; cited to record that this issue's stated sequencing constraint no longer applies, not as tracked work -->
             observed CLOSED as NOT_PLANNED (closedAt 2026-07-31T06:40:32Z), so the ordering
             constraint has nothing left to order against. <!-- adb-claim-ok: #181 was closed NOT_PLANNED; cited to record that this issue's stated sequencing constraint no longer applies, not as tracked work -->

## D50 — run data lands under `{{STATE_DIR}}`, and `mktemp` was rejected on lifetime grounds
- date:      2026-08-07
- category:  project-delta
- unknown:   #250 left the home for /implement-issue's issue snapshot open between two candidates —
             a per-run `mktemp -d` or `{{STATE_DIR}}` — and said the two "should be decided together"
             with #202's per-run state naming rather than in isolation.
- decision:  `{{STATE_DIR}}`, with the snapshot registered as a first-class state family. #202 has
             since landed and decided the model it was waiting on: exclusion is per checkout PER
             AGENT, enforced by `implement-lib.sh admit`, and `{{STATE_DIR}}` renders to
             `.<agent>/state` (`scripts/build.sh:112`) — the same boundary, so a fixed name inside
             it cannot collide with anything `admit` permits to exist.

             `mktemp -d` was rejected on cost, and the cost is real rather than fatal — the
             independent review was right that the first draft of this entry overstated it. Two
             problems have to be SOLVED for it to work, where `{{STATE_DIR}}` has neither: the
             directory's identity is a SHELL VARIABLE, and this workflow's own step 1 already warns
             that a later fenced block may run as a separate shell — while the snapshot is written
             in step 2 and last read in step 8, an hour and a dozen blocks later; and it has no
             cleanup owner inside the run, because a trap in the creating block either fires before
             step 8 or dies with that shell. Both are answerable — a state-file pointer could carry
             the identity across shells, and OS temp reaping eventually reclaims an orphan — but
             the pointer is itself a second piece of run state needing its own lifecycle, which is
             the thing `{{STATE_DIR}}` already provides. Simplicity decided it, not impossibility.
- placement: `base/workflows/implement-issue.md` (the 7 sites plus the containment prose);
             `scripts/lib/cleanup-lib.sh` (`state-scan`'s `issue` arm, `state-verdict issue`);
             `scripts/lib/implement-lib.sh` (`_il_clear`'s family globs);
             `base/workflows/cleanup.md` (the sweep arm);
             `scripts/check-tmp-paths.sh` + `scripts/selfcheck.sh` + `.github/workflows/ci.yml`
             (the guard and its two wirings);
             `scripts/check-cleanup.sh`, `scripts/check-implement-lib.sh`,
             `scripts/check-injection.sh`, `scripts/check-common-lib.sh` (coverage).
- reason:    A project-delta, not a general gap: the defect is in this repo's own workflow source
             and shared libraries, and every piece of the fix landed in a home that already
             existed. No new config surface was invented and no baseline rule was contradicted.
- baseline-issue: #250
- also:      **`state-verdict issue` SHARES the `gaps` arm rather than copying it.** The same two
             signals decide both — a pre-marker run holding the claim, and a marker describing a
             live run — so one body answers for both. Two bodies that must agree are two bodies
             that stop agreeing after one is edited; the alias keeps one implementation while
             letting `base/workflows/cleanup.md` ask under the name of the file it is actually
             deciding about. `scripts/check-cleanup.sh` section 2c1 restates every `gaps` case for
             `issue`, so a future split that changes one side fails there.

             **The LIFETIMES are not identical, though, and the first cut of this entry said they
             were.** Gap artifacts stop being consumed after step 4; the snapshot is consumed again
             in step 8. That is why the sweep asks `issue` with `$RUN_NOW` (the fresh re-scan) and
             `gaps` with `$RUN` (the marker pass) — a run that reached step 5 mid-sweep is live in
             one and stale in the other, and passing the stale answer would delete a live run's
             issue text from under its own review dispatch. Gaps' PREDICATE, review's FRESHNESS.

             **The clear matches the scan arm EXACTLY, and the first cut widening it was a defect
             the independent review caught.** The containment rule is that everything `/cleanup`
             can sweep, `admit` must be able to clear — and "widening the clear is always safe" is
             true of `gaps-*` and `review-*`, whose prefixes nothing else writes. It is FALSE for
             `issue-*`. This state directory is SHARED: `/new-release` keeps `new-release.json`
             there as durable history and `/resolve-pr-threads` keeps `threads-<N>.json`, so a bare
             `issue-*.json` glob would have this workflow's preflight silently delete a plausible
             neighbour such as `issue-cache.json` — a fresh defect introduced by the fix for an old
             one. Equality satisfies containment either way, and it is the reading that cannot
             destroy another workflow's file. `check-implement-lib.sh` pins the destructive side.

             **The guard was observed failing on the real superseded input, twice over.** Before
             the rebuild, `check-tmp-paths.sh`'s part 1 reported six host-global resolutions — the
             `.json` and the `.assoc` in each of the three rendered skills — and its part 2
             reported every other instance of the class across the four scanned roots; and its
             permanent mutation harness re-injects thirteen pre-fix and near-miss spellings into a
             COPY of the tree on every run, requiring thirteen reds.

             **Acceptance criterion 2 is met by EXECUTION, not by a string comparison.** The
             independent review's sharpest point was that a textual mutation harness proves textual
             detection and nothing about two runs observing one file. Part 1b now takes the path
             expression out of the rendered skill, resolves `$n`, and has two simulated checkouts
             each write their own sentinel through it and read it back — which fails on any
             host-global spelling and passes on the shipped one. The topology is NAMED rather than
             left to "two concurrent runs": this is TWO CHECKOUTS (equivalently two agents in one
             checkout, which get different state dirs); two runs of ONE agent in ONE checkout are
             refused by `admit` and covered by `check-implement-lib.sh`, and no filename can help
             there because they share one HEAD.

             **Its own self-test caught two defects in it before anything else did.** `awk -v`
             interprets backslash escapes in the assignment, so the entropy allowance passed as
             `\$\$|\$RANDOM|XXXXXX` arrived as a regex whose `$$` is two end-of-string anchors —
             and `/tmp/adb-cl-meta.$$`, the spelling #250's acceptance explicitly permits, was
             reported as a violation. It is a tab-separated literal list matched with `index()`
             now. The second was a false positive on its own source: every fixture has to produce
             the exact text the scanner hunts, so the two literals are composed at runtime from
             variables rather than typed — exempting the whole file would have hidden a real
             regression introduced in it later, and marking each fixture line is impossible inside
             a `for … in 'a' \` continuation and would make the marker fixture self-exempting
             besides (the trap `check-claims-guard.sh` already records for `adb-claim-ok`).

             **A `_il_clear` edit dropped the `review` arm from `state-scan` and `check-cleanup.sh`
             caught it immediately** — five `review` fixtures fell to `other` in one run. Recorded
             because it is the argument for those fixtures existing: the arm would otherwise have
             shipped silently, and `/cleanup` would have stopped sweeping review artifacts while
             reporting a clean run.

             **A generic harness assumption was corrected rather than worked around.** The
             containment loop builds a fixture per arm by substituting a token for `*`, and used
             the word `slot` — which `issue-*.json`'s digit rule rejects, making the fixture name a
             file `/cleanup` would never sweep and the deletion assertion vacuous. The token is
             numeric now, which is legal for every arm's `*`, so the loop stays generic.

             **Scope held where #250 drew it.** `check-release-skill.sh`'s `$$` files are named in
             the acceptance criterion as an allowed spelling and were left alone (`selfcheck.sh`'s
             note claiming they "belong to #250" is corrected to say so); `.github/workflows/ci.yml`
             runs on an ephemeral single-tenant runner and is out of scope by the issue's own
             survey. The two "fold in or drop" items were folded in, because the lint this change
             adds defines them as violations — leaving them would have meant shipping a guard with
             two exemptions on its first day.

             **The independent codex review raised 18 findings; every one was acted on.** Six were
             real defects in code this change added and are fixed above: the `issue-*` clear glob
             over-reaching in a SHARED state directory (the sharpest one — `issue-cache.json` from
             any future skill would have been deleted by this workflow's preflight); part 1's
             is-it-relative test passing `${TMPDIR:-/tmp}/issue-$n.json` and `../shared/issue-$n.json`,
             both host-global; `XXXXXX` accepted as entropy without `mktemp` on the line, which is a
             literal filename rather than a template; a global site FLOOR satisfiable after an entire
             half of the snapshot is renamed away; the class scan limited to `*.md`/`*.sh`, so an
             extensionless script or a shell command in a `.yml` was invisible while the changelog
             claimed the roots were covered; and `find`'s newline-delimited output. Each now has its
             own mutation case, taking the harness from seven reds to thirteen.

             **Two more were defects in the prose this change wrote**, both the same shape: a
             cleanup command becoming the block's exit status. `gh issue create … ; rm -f "$BODY"`
             reported a FAILED filing as success, and `diff … && echo IDENTICAL; rm -rf "$D"`
             reported DRIFTED as identical. A third — `git diff HEAD > "$(mktemp …)"` throwing away
             the only handle on the backup — was the best finding in the set: a patch you cannot
             name is a patch you do not have, which is the exact failure that practice exists to
             prevent.

             **Acceptance criterion 2 was correctly reported UNMET and now is not.** See part 1b
             above; the review's point that a textual mutation harness proves textual detection was
             right, and prose could not have answered it.

             **Five were claim-integrity findings against this entry and the changelog**, all
             upheld: "identical lifetimes" (they are not — hence `$RUN_NOW`), "widening the clear is
             always safe" (not in a shared directory), the guard covering "anywhere" under the roots
             (it has three named blind spots, now written into its own header), the mktemp rejection
             stated as impossibility rather than cost, and the observation claim standing in for the
             concurrency criterion. Every one is corrected in place rather than annotated.

             **One was dispositioned rather than applied.** The review called the class lint
             over-broad for flagging READS as well as writes. Telling one from the other needs a
             shell evaluator, which is the same machinery its own correctly-identified blind spots
             rule out — and a rule that guessed would miss writes. The breadth stands, the
             `adb-tmp-ok: <reason>` escape is documented as the intended answer rather than a
             grudging one, and the limits are stated in the header instead of discovered later.

             **One was deferred to a filed issue: #305.** `/cleanup` deletes artifacts by stored
             pathname, so a run that recreates the same fixed name between the pre-delete re-scan
             and the `rm` loses its files. It is ONE defect with THREE sites (`gaps`, `review`,
             `issue`), it predates this change in the two older arms, and the remedy — the identity
             re-capture the `marker` arm already performs — is a change to `/cleanup`'s shared
             delete discipline rather than to anything #250 asked for.

             **A measured optimization came out of the same pass.** The mutation harness ran 63s
             because `check_copy_worktree` copies this repo's ~66 MB `.git` and then deletes it,
             thirteen times. `check_copy_subtrees` (new, in `scripts/check-lib.sh`) copies only the
             named roots — which for this suite are exactly the scanned ones — and the suite runs
             5.7s. The fixture is proved once up front, because a copier's failure mode is thirteen
             reports blaming the scanner for a tree the mutator never managed to break.

             **A second independent review (the PR's async reviewer) raised 5 more; all 5 were real
             and all are fixed.** Three were holes in the new guard that had shipped green: the
             state-dir check accepted any DESCENDANT, so `.claude/state/issues/issue-$n.json` and
             `.claude/state/../shared/issue-$n.json` both passed — and the two-checkout demo passes
             them too, since each checkout still gets a distinct file, while `state-scan` (direct
             children only) would never see either, defeating the flat invariant the workflow states
             in prose; `$RANDOM` was a substring test, so `$RANDOM_SUFFIX` counted as entropy while
             the shell reads a different, probably-unset parameter; and `XXXXXX` accepted `mktemp`
             anywhere on the UNSTRIPPED line, so a trailing `# TODO: use mktemp` beside a literal
             template counted. Each now has its own mutation case, taking the harness to sixteen.

             **The fourth was the sharpest, and it is the exposure this change itself created.**
             `bin/agent-init` ignores `.claude/state/` only, and `{{STATE_DIR}}` renders per agent —
             so moving the snapshot from a shared temp directory INTO the repo meant a Codex or
             Gemini run left the untrusted issue body untracked in the working tree, one `git add -A`
             from being committed. In `/tmp` that was impossible. `agent-init` now derives the set
             from `agents/<token>/` and ignores every rendered state dir, and since that helps only
             repos initialized from now on, step 2 also REFUSES TO WRITE unless `git check-ignore`
             confirms the exact file shapes are ignored. That guard probes FILE paths, not the
             directory: a `.../state/` rule cannot match a directory path git cannot see is a
             directory, so the obvious `check-ignore {{STATE_DIR}}` answers "not ignored" whenever
             the directory does not yet exist — and would have passed here for a reason unrelated to
             what it claims to check.

             **The fifth was a fixture writing outside its own sandbox.** The behavioural mutation
             aliased both checkouts onto `/adb-tmp-shared-fixture/` and leaned on `mkdir -p` failing
             for lack of permission — which is a property of WHO RUNS THE SUITE, not of the test. As
             root (routine in a dev container, and this is a mandatory gate) it succeeds, writes
             outside `$work`, and the demo's own cleanup does not reach it. The aliased path is
             inside `$work` now, so the EXIT trap removes it however the run ends.

             **One review premise was checked and did not hold, and the fix landed anyway.** The P1
             finding said Apple's `sort` rejects `-z`, which would make the required `selfcheck-macos`
             job red for every change. Measured on this workstation — `/usr/bin/sort` 2.3-Apple,
             macOS 26.5.1 — it round-trips NUL-delimited input correctly, so the stated failure does
             not occur on that build. But the runner's image is a different build, `sort -z` is not
             POSIX, and ordering here is a REPORT property that no verdict depends on. So the option
             is PROBED (on its output, not its exit status — an implementation that accepted `-z` and
             reordered nothing would pass a status check) and falls through to `find` order when
             absent. Verified green under a stub `sort` that rejects `-z` exactly as the finding
             described.

## D51 — the slug has FOUR producers, and each module keeps its own fail-closed code
- date:      2026-08-08
- category:  project-delta
- unknown:   #218 prescribed ONE chokepoint (`adb_repo_slug`) and ONE failure code (`20`) for
             routing every API-supplied slug through `adb_is_path_safe_repo_slug`. Both premises
             are false of this repo, and neither is false in a way that shows up as a test failure —
             a fix built on either would have looked complete and covered less than it claimed.
- decision:  Validate at **every** producer boundary, and return **each module's existing** code.

             **Four producers, not one — and the count itself is the lesson.** The first pass found
             two, because it swept `scripts/lib/`, `bin/` and `agents/*/scripts/`; independent
             review found two more by not assuming the search space. `.claude/skills/release/
             release.sh` carries its own `slug()` (outside `scripts/lib/` by D14's design), and
             `base/workflows/roadmap.md` resolves `nameWithOwner` at SIX places — prose, which no
             grep for a shell function would ever have surfaced. A rule that "exists in one place"
             is only as good as the inventory of who bypasses it, and this inventory was wrong
             twice: once in the issue, once in the fix that corrected the issue.

             **The prose producer needed a mechanism, not just a call.** `roadmap.md` is pasted
             into a shell and cannot source a library, so the rule reaches it as
             `roadmap-lib.sh slug-ok` — a thin delegate, in the library whose charter is already
             "/roadmap's decisions lifted out of the prose so they are testable". Restating the
             charset and traversal rules in Markdown would have put a copy of a security predicate
             where no test runs, which is the failure this whole issue is about. Same shape as
             `role-dispatch.sh untrusted` exposing `adb_untrusted_block`.

             **`adb_repo_slug` still has exactly one production caller:** `release-convention.sh:79`,
             and that single checked assignment (`REPO_SLUG="$(adb_repo_slug)" || exit 1`, run by `init`, `status` and
             `roll` alike) is what all ten of that module's `repos/$(repo_slug)/...` sites descend
             from, so hardening the getter covers every one. It covers `repo-settings.sh` not at
             all: that module reads its slug from the `.full_name` of the repo object it already
             fetches, deliberately, to avoid a second round trip on the one call that runs on every
             `/implement-issue`. Its boundary is `repo_json`, and it is the module that decides
             whether **auto-merge may be armed** — so a one-place fix would have hardened the
             cheaper half and left the consequential one untouched while reading as done.

             **The getter is hardened rather than wrapped.** No caller wants the raw value, and a
             wrapper would leave the unvalidated spelling as the shorter, more obvious one — the
             shape that produced this issue.

             **Validation cannot live at the interpolations.** In
             `release-convention.sh` the accessor's status is discarded inside the string that
             quotes it (`"repos/$(repo_slug)/milestones"`), so a refusal there prints and the
             `gh api` call still goes out.

             **Each module keeps its own code**, because "the existing unreadable code (20)" is not
             a repo-wide fact. In `repo-settings.sh`, `automerge-ok` / `merge-flag` /
             `required-drift` map a `repo_json` failure to 20 while `apply` / `status` map it to 1.
             In `release-convention.sh` the slug is resolved inside `require_gh`, so all three
             subcommands surface a bad one as that function's `exit 1` — narrowly, because the
             module is NOT uniformly "exit 1": it reserves 2 for usage and argument errors. Both
             guards therefore return the failure their module already defines, and each caller maps
             it as it always has. A uniform 20 in the producer would have handed `apply` an exit
             code its contract does not define.

             **Both validate BEFORE committing the cache**, which is the whole correctness story
             and not a style point: assigning first and rejecting after fails the FIRST call and
             then returns 0 with the rejected slug on the SECOND — a fail-open one line below the
             guard, invisible to every single-call test. The guard is the memo variable in each
             case, and only that one: `_ADB_REPO_SLUG` in the getter, and in `repo_json`
             **`REPO_JSON` alone** — `REPO_SLUG` rides along with it rather than being tested
             independently, so moving `REPO_SLUG` by itself cannot produce the bypass.

             **The diagnostic renders the value (`adb_display_value`, `%q`) rather than echoing
             it.** The values a guard rejects are by construction the least well-behaved, so a
             newline in one forges the log line after it — re-opening in the operator's output the
             hole the check just closed. Deliberately NOT shared with `cleanup-lib.sh`'s
             `_adb_cl_tsv_display`, which adds a re-test and a fixed fallback token because it
             guards a machine-read record format; here a fixed token would destroy the only thing
             the line exists for. Two contracts; the shared part is one `printf`.
- placement: `scripts/lib/common.sh` (`adb_repo_slug`, plus `adb_display_value` in the logging
             section), `scripts/lib/repo-settings.sh` (`repo_json`). Regression tests in the three
             owning suites — `scripts/check-common-lib.sh`, `scripts/check-repo-settings.sh`,
             `scripts/check-release-convention.sh` — all already registered in `selfcheck.sh`.
             `release-convention.sh` itself needed no edit, and its suite proves that transitively.
- reason:    Both false premises are the kind that pass review: each is stated confidently in the
             issue, each is true of the module a reader is most likely to open first, and neither
             produces a red test when acted on literally. Recording them is the point — the next
             person to add a gh-backed module will reach for "the chokepoint" and there will still
             be two.
- guard-observability: `adb_repo_slug`'s cache ordering is pinned BEHAVIOURALLY (a second call
             after a rejection must also fail). `repo_json`'s cannot be: every subcommand checks
             that function's status on its first call and bails, so the wrong order is
             indistinguishable today — measured, not assumed, by running that exact reorder against
             the suite and watching it stay green at 380/380. It is pinned STRUCTURALLY instead,
             the same move the `required-drift` CI wiring gets, and the test says which kind it is.
             All six mutations (each guard removed, each cache reordered, the escaping disabled)
             were observed RED against a throwaway copy, each on its own assertion.
- baseline-issue: n/a — this repo IS the baseline; #218 is the tracking issue.

## D52 — a rename replaces a truncate, and the three things a rename made necessary
- date:      2026-08-09
- category:  project-delta
- unknown:   #268 asked for one change: give `render()` the temp-then-`mv` shape
             `render_agent_skill()` already had, "reusing the existing idiom rather than inventing
             a second one". Literal reuse is not sufficient, and the reason is that a rename does
             not merely replace a truncate — it introduces a second file, and the existing idiom
             has nothing to say about that file's NAME, its lifetime, or its mode.
- decision:  Publish through one shared `build_stage` / `build_publish` pair, used by BOTH
             renderers, and settle all three consequences rather than inherit them silently.

             **1. The temp name is unique per process, not `$dest.tmp`.** The first cut reused the
             existing fixed-sibling spelling, and independent review found that this leaves a path
             straight back to the corruption being fixed: two builds over one checkout — a
             contributor running `build.sh` while selfcheck's `build-drift` step runs one — share
             the name, and the interleaving PUBLISHES a torn file. A stages, B clears the name and
             stages its own, A renames B's half-written file over the destination. `mktemp` also
             closes a hole the first cut's `rm -f` only appeared to close: clearing a path and
             opening it are two operations, so a symlink installed between them is still followed.
             Unlinking first defends against a STALE artifact, never a hostile one, and the first
             cut's comments claimed otherwise. O_EXCL under an unpredictable name has no window.

             **2. An abort leaves a temp, and nothing in this repo would report it.** The defect is
             fixed the moment the destination stops being truncated, so the residue is not a
             correctness question — but `.gitignore` does not cover it, `build-drift`'s untracked
             scan looks only under the skill trees, and `check-tmp-paths.sh` is a CONTENT scan that
             a well-formed render fragment passes (verified: a real half-rendered root doc left at
             `agents/claude/CLAUDE.md.tmp` leaves that lint green and unmentioned). One
             `trap build_cleanup EXIT` removes it.

             **A bare `EXIT` trap is enough, and that is MEASURED.** The gap-analysis pass held
             that it "is insufficient for direct TERM" and prescribed INT/TERM/HUP handlers exiting
             130/143/129 by hand. On bash 5.3.15 that is false: the EXIT trap runs for SIGINT
             delivered the way a terminal delivers it (to the process group), for SIGTERM and for
             SIGHUP, and the script still exits 130 / 143 / 129 on its own. The prescribed handlers
             would therefore add the one thing they exist to prevent — a hand-written status that
             can be wrong. An EXIT trap returning 0 was also confirmed not to overwrite a failing
             script's status, so cleanup cannot mask an errexit abort. Independent review confirmed
             the measurement and the SIGINT qualification. SIGKILL and power loss stay untrappable,
             and there the residue is the correct outcome: the tracked file is intact, which is the
             entire guarantee.

             **3. The mode is CHOSEN, not inherited — reversing the first cut's decision on
             evidence.** That cut declined mode handling as unobservable. Two things falsified it.
             `mktemp` creates 0600, so publishing straight from the temp would have silently
             narrowed every generated doc; and inheriting the umask instead is the same problem
             pointing the other way — review noted a permissive umask yields group- or
             world-writable INSTRUCTION files, and running the new suite against the pre-#268 code
             shows exactly that (`-rw-rw-rw-` under `umask 000`). Git records no difference among
             non-executable modes, so no existing check here could ever have noticed. `chmod 644`
             is the only value that does not depend on ambient state, and it is asserted under a
             hostile umask at each extreme.

             **What is NOT claimed.** A rename makes a reader of any ONE file see the old contents
             or the new, never a torn mix. It does not make the three root docs update atomically
             with respect to each other, which is why `build-drift` keeps its serial prologue.
- placement: `scripts/build.sh` (`build_stage`, `build_publish`, the file-level trap, and both
             renderers); `scripts/check-build-atomic.sh` (new, registered in `scripts/selfcheck.sh`
             as a POOLED step and wired as a step on CI's existing `build-drift` job); a
             `build-atomic-wired` pin in `scripts/check-fact-drift.sh`; the falsified claims in
             `scripts/selfcheck.sh`'s concurrency-contract header and this repo's `CLAUDE.md`.
- reason:    The issue named the change and, correctly, its scope; what it could not name is that
             the safe version of a two-line fix is a shared helper with three decisions in it. Two
             of those three were settled WRONG in the first cut and corrected by review — the fixed
             temp name, and declining the mode — which is the strongest argument for writing them
             down: each looked obviously fine, and each had a counter-example one layer down.
- guard-observability: The suite is observed RED against the pre-#268 `build.sh` — the failure it
             prints is the truncated root doc itself, plus the world-writable modes. Below that,
             each change to the publish mechanism has its own mutation applied to a COPY in a
             fixture (naive publish · fixed temp name · trap removed), each required to make the
             assertion above it go red, and each verifying its own edit applied (exactly one
             matching line before, none after) so a sed that silently stopped matching fails loud
             instead of turning three proofs into assertions about unmodified code. Byte-exactness
             is compared with `cmp`, not `[ "$(cat f)" = … ]`, which strips trailing newlines and
             therefore cannot see a dropped final one — review found that hole. The
             `build-atomic-wired` pin was driven red from both `selfcheck.sh` and `ci.yml` against a
             green tree copy. What is NOT proven: the trap's coverage of the SKILL path
             specifically — inducing a non-placeholder failure there needs a signal race, so that
             path rides the root-doc proof, and saying so is better than implying a coverage that
             does not exist.
- baseline-issue: n/a — this repo IS the baseline; #268 is the tracking issue.

## D53 — a git ref crossing into an API path is ENCODED; both spellings work, and that was measured
- date:      2026-08-10
- category:  project-delta
- unknown:   `scripts/lib/repo-settings.sh` interpolated the branch name raw into six API paths, so
             `release/v1` built `branches/release/v1/protection` rather than one encoded segment.
             #103 correctly refused to guess: several GitHub REST endpoints accept a raw slash and
             others require `%2F`, this repo had no slashed branch to test against, and "fixing" it
             from documentation risks breaking the path that already works.
- decision:  Run the experiment first, then encode.

             **The experiment, read-only, on branches that already existed.** The issue proposes
             creating a `release/v1` branch; that turned out to be unnecessary — several repos the
             owner administers already carry slashed branches, and public repos carry them at two
             and four levels deep. So nothing was created, pushed or mutated to learn this. On
             2026-08-09 with `gh` 2.95.0:

             - `GET repos/{o}/{r}/branches/{b}` returned **200** for both `actions/inactive-collaborators`
               and `actions%2Finactive-collaborators` (nodejs/node, one slash), and for
               `automation/bors/auto` / `automation%2Fbors%2Fauto` (rust-lang/rust, two). Both
               spellings returned the SAME `.name` and the same commit sha, so they addressed one
               branch — status alone would not have shown that.
             - `GET .../commits/{ref}/check-runs` returned 200 with an identical `total_count` for
               both spellings (one slash).
             - `GET .../branches/{b}/protection` — admin-only — returned
               `404 {"message":"Branch not protected"}` for both spellings on a real
               `release/11.11.0` (one slash) and on a real four-slash
               `dependabot/composer/stacks/php-wordpress/all-minor-patch-…`, while a nonexistent
               control returned `404 {"message":"Branch not found"}`. **That message pair is the
               discriminator**: a bare 404 would have proved nothing, and on a repo where the token
               lacks admin every one of these is an opaque `Not Found` — which is why the probe had
               to run on repos the owner administers.
             - `GET .../protection/required_status_checks`, the sub-resource `apply` PATCHes,
               behaved identically (one slash).

             **And the finished library was watched AT THE `gh` BOUNDARY** — not on the wire, and
             the difference is worth stating: this observes the path the library HANDS to `gh`,
             while the `GH_DEBUG=api` probes above observe what `gh` puts on the wire. Together they
             cover both hops; separately, neither is the other. With an argument-logging shim in
             front of the real `gh`,
             `required-drift --branch release/v1` requested
             `repos/BWBama85/ai-dev-baseline/branches/release%2Fv1` while the same command with no
             `--branch` requested `.../branches/main`, byte-identical. That is the encoded path and
             the no-op property observed through the real code path rather than through a stub.
             (`GH_DEBUG=api` does NOT work for this — `_adb_rs_api_i` runs `gh api -i "$1" 2>/dev/null`,
             so gh's own debug log is discarded before it can be read. The shim is the way in.)
             It stays a recorded one-off rather than a test: it needs network and auth, and
             `selfcheck` is hermetic by construction (D13/D24).
             - `GH_DEBUG=api` confirms `gh` normalizes nothing: `/` goes on the wire as `/`, `%2F`
               as `%2F`. So the answer is GitHub's, not the CLI's.

             **Both accepted, so encoding is a choice — and the choice is encode**, per the issue's
             own instruction for that outcome. The argument is not the slash. Git forbids space,
             `~^:?*[` and `\` in a ref but ALLOWS `#`, `%`, `+`, `=`, `;`, `&` and any UTF-8, and a
             raw `#` opens a URI fragment: `gh` was observed dropping it and everything after it, so
             `branches/feat/#42/protection` silently asks about `branches/feat/`. A wrong answer with
             a 200 status is worse than the 404 the slash case produced.

             **`jq @uri`, not a shell character loop, and that is a correctness decision rather than
             a style one.** Bash's `printf '%02X' "'é"` yields the CODEPOINT (`E9` — an invalid
             UTF-8 escape) in a UTF-8 locale and the first BYTE (`C3`) under `LC_ALL=C`. A
             hand-rolled encoder is therefore right on one runner and wrong on another, with nothing
             in the output to tell them apart. `@uri` is byte-oriented and verified identical under
             both; jq is already a hard requirement of every caller that builds one of these paths.

             **The encoding checks its own fidelity, found in self-review.** `@uri`'s input is not
             guaranteed to survive it: a git ref is a BYTE string (`git check-ref-format` bars ASCII
             control characters, not high bytes) while jq's `--arg` is a JSON string, so `rel\xffv1`
             arrives as U+FFFD and encodes to `rel%EF%BF%BDv1` — a different, unreachable branch,
             returned with a ZERO status. Measured, not theorised. jq now emits its own view of the
             input as a second line, that line is compared against the bytes that went in, and a
             mismatch refuses. One invocation, not two: the round trip is an extra output line
             rather than an extra process.

             **An exact `.` or `..` segment is encoded rather than passed through.** `@uri` leaves
             dots alone, so `--branch ..` built `repos/o/r/branches/../protection` and resolved one
             level up — the traversal #218 refused for slugs, arriving through the ref door, and it
             was observed in the pre-fix suite run. RFC 3986 removes dot segments BEFORE
             percent-decoding, so `%2E%2E` is an ordinary name. Only the WHOLE segment counts;
             `v1..v2` is a name and is pinned unchanged.

             **What is NOT claimed.** The protection-endpoint measurement is a **GET**. The three
             writes (`PATCH …/required_status_checks`, `POST …/enforce_admins`, `PUT …/protection`)
             share those routes and were not exercised against the live API — issuing a write to
             prove a route is not worth a mutation on someone's repository. What IS proven offline
             is that this library now emits the encoded path on all three.
- placement: `scripts/lib/common.sh` (`adb_url_path_segment`, the generic primitive, beside
             `adb_is_path_safe_repo_slug` — the same "safe to build a request path from" question,
             opposite remedy); `scripts/lib/repo-settings.sh` (`_adb_rs_ref_path`, and the six call
             sites plus the two printed `gh api` commands); `scripts/check-common-lib.sh` and
             `scripts/check-repo-settings.sh` (coverage); `docs/repo-settings.md` (the `--branch`
             contract); `.claude/skills/release/release.sh` (its two ref-in-path sites, added on
             review — it already sources `common.sh`, and it is the template D14 tells every
             adopting repo to copy, so a raw interpolation there propagates by design).

             NOT named `_adb_rs_branch_path`, though the issue reaches for that: one of the six is
             `commits/{ref}/check-runs`, a different collection whose segment is a ref, and a
             branch-only helper would have left exactly that site — the newest of them — raw.
- reason:    The issue asked for an empirical answer and it deserved one, because the plausible
             guesses point both ways. The measurement also changed what the fix is FOR: with both
             spellings accepted, this was never a broken-endpoint bug, and shipping it as one would
             have left the reader thinking a slash was the hazard. It is not — `#` is, and the
             encoder is what covers the class rather than the instance.
- guard-observability: Both suites were observed RED before being trusted, on the real superseded
             input rather than a convenient one. The 20 new `check-repo-settings.sh` assertions were
             run against the PRE-FIX library (a `git archive` copy, never the working tree) and 13
             failed, each printing the raw path the old code really built — including
             `branches/../protection`. The other seven are controls that MUST stay green there (the
             byte-identical `main` path, the no-mutation check, the query-string guard), so they are
             driven red separately, further down this entry. Six plausible-but-wrong encoders were spliced into copies and
             each required to go red on its own assertion: slash-only substitution, a bash character
             loop (caught only by the locale pair), a "don't double-encode" guard, a soft failure
             that returns empty when jq is absent, no dot-segment handling, and bare `@uri` with no
             fidelity round trip. Each mutation
             verifies its own edit applied, so a splice that stopped matching fails loud instead of
             asserting about unmodified code. The BYTE-IDENTITY control — an ordinary run contains no
             `%` at all — was driven red separately by the plausible over-correction of encoding the
             slug too. What is NOT covered: the live write verbs, per the note above; and the
             UTF-8-locale half of the locale pair is skipped with a printed NOTE on a host that
             generates no UTF-8 locale, rather than counting a pass it did not earn.
- review:    The independent pass (codex) returned 6 REQUIRED + 4 OPTIONAL, and three of them were
             defects the author's own self-review had missed — worth recording, because each is a
             way this change could have shipped looking finished:

             1. **`apply` could still mutate after an unreadable protection state.** The no-CI arm
                skips `write_required_checks` (which refuses `error`) and falls through to the
                `allow_auto_merge` PATCH. PREDATES #103 — a 5xx reached it too — but #103 adds a
                second way in, so `cmd_apply` now refuses `error|forbidden` before any write.
             2. **The non-admin path reconstructed the raw URL** when the encoder refused, and
                PRINTED it as two runnable commands. A tool that refuses to build a path and then
                prints it anyway has not refused; the commands are now withheld with the reason.
             3. **The suite never tested an unbuildable path.** The section labelled "fail closed
                when the path cannot be built" passed `..` — which the encoder deliberately
                SUCCEEDS on. It could not have caught either defect above. It now uses invalid
                UTF-8, the reachable failure, and asserts all four obligations separately: non-zero
                exit, no request, no mutation, no runnable raw path printed.
             4. **`has` is substring, not equality.** `has ".../branches/release%2Fv1"` is satisfied
                by a request for `.../branches/release%2Fv1/protection` — a different endpoint — and
                the stub answers both from one fixture, so no outcome check would have caught it.
                Whole-record matchers (`read_is`/`call_is`) replace it, which also makes the
                byte-identity control mean what its name says.
             5. **The encoder refused a trailing newline**, because `$( )` strips one before the
                round trip compares. No git ref can contain a newline, so no caller was affected —
                but this is published as a generic primitive. A `.` sentinel inside the jq call
                makes it total.

             The four OPTIONAL findings were all claim-accuracy defects in this entry, the changelog
             and the doc, and all four were correct: "nonexistent branch" (a branch literally named
             `release%2Fv1` is legal and may exist), "no path that worked before changed at all"
             (the slashed path's spelling did change), "Five" encoders where six are listed, and
             "on the wire" for an observation taken at the `gh` boundary. All corrected above.
- guard-observability-of-the-review-fixes: Each fix was reverted on a COPY and its new assertion
             required to go red: the `cmd_apply` guard removed (the no-mutation assertion fires),
             the raw fallback restored (the no-runnable-command assertion fires), the builder made
             to append a suffix a substring match would swallow (the exact matcher fires where
             `has` would not), and the sentinel dropped (the trailing-newline assertion fires).

             **What is NOT tracked, said plainly:** both mutation harnesses are one-off runs from a
             scratch directory, not committed checks. That is a deliberate call rather than an
             omission — these unit tests assert concrete input→output pairs, so their failure mode
             is a loud `FAIL`, not the silence that makes a GUARD unable to answer wrong. The repo's
             own rule is to automate the observation where the rule set is CLOSED; the set of future
             wrong encoders is open, so this stays a discipline. `check-build-atomic.sh` and
             `check-fact-drift.sh --mutation` exist because their subjects fail silently; this one
             does not.
- baseline-issue: n/a — this repo IS the baseline; #103 is the tracking issue.
                  Follow-up filed: #310 (D30's sub-floor carve-out is documented but never executed).

## D54 — the below-floor rule moves INTO the lint, and what an executed carve-out can and cannot prove

- date:      2026-08-10
- category:  project-delta
- unknown:   #310 asks for a mode that runs `bash -n scripts/lib/common.sh` under "the oldest
             interpreter available on the host", so D30's carve-out is executed rather than
             asserted in prose. Three things the issue could not settle from outside the code:
             what that interpreter set IS, what a parse actually proves, and where the rule lives —
             because D35 had already put a *source scan* for the same carve-out in
             `check-bash-floor-guard.sh`, and a new mode needs the same three-file list.
- decision:  A `--sub-floor [DIR]` mode carrying **two** rules, and the D35 predicate **moves into
             it** — the guard keeps driving it red, exactly as it drives every other rule this lint
             owns.

             **The interpreter set is `adb_bash_candidates`**, filtered to strictly below the floor
             and reduced to the NUMERICALLY oldest, through `adb_version_ge`. Not a filesystem
             sweep, not a hardcoded `/bin/bash`, not `sort -V` (banned here), and not the
             first-listed hit: that list is ordered for finding a modern re-exec TARGET — fixed
             prefixes first, `command -v` last — which is the opposite question, so taking its first
             sub-floor entry would pick whichever old bash happened to sit earliest in an ordering
             built for something else.

             **Parse alone was measured, and it is not enough.** Against a real `/bin/bash` 3.2.57
             and a real 5.3.15: `bash -n` rejects the grammar bash grew after 3.2 —
             `coproc NAME { … }`, `;&`, `;;&`, `|&` — anywhere in a file, function bodies included.
             It ACCEPTS every construct D30 actually names: `${ command; }`, `mapfile`,
             `declare -A`, `local -n`. So a parse-only mode would be a check that cannot answer
             wrong on its own subject matter. Hence rule A (the source scan, which catches the
             command-substitution case statically and interpreter-independently) and a **bootstrap
             probe** beside the parse: source `common.sh` under the old interpreter and require
             `adb_require_bash` reachable with NOTHING on stderr. The stderr half is not
             decoration — `declare -A` at the top level prints `invalid option` on 3.2 and leaves
             the source status at **0**, so an rc-only probe passes it.

             **What is NOT claimed**, stated in the mode's own header: a 5.3-only construct inside a
             FUNCTION BODY that is neither new grammar nor a command substitution is invisible to
             both rules, because 3.2 parses it and sourcing never runs the body. This half proves
             parseability and gate reachability. Full behavioural compatibility of every function in
             `common.sh` is a third, much larger claim, and it is deliberately not made.

             **It rides the BARE invocation**, not a new step and not a new job. That is what makes
             it run at all: both hosted runners resolve a bash at or above the floor, so the only
             per-PR environment with a real subject is `macos-latest`, which reaches this suite
             through `selfcheck-macos`. A separately registered mode nobody invokes would skip on
             Linux and never run on macOS — #310's defect, reintroduced one layer up. A new job
             would add a branch-protection context, which this lint's own header argues against.

             **The new seam is fenced out of CI the same way the old one is.** `ADB_SUB_FLOOR_CANDIDATES`
             joins `ADB_BASH_FLOOR` in the static lint's workflow rule, because it is the same class
             of bypass and the sneakier member of it: pointed at a nonexistent path it leaves no
             candidate below the floor, so the half reports a SKIP and the job is green with rule B
             disabled on every job in scope. It is not a substring of `ADB_BASH_FLOOR`, so the
             single-token grep that rule used to be would never have matched it — which is why the
             widening carries its own fixture rather than being assumed covered.

             **A skip is stated and audited, never silent**: where nothing is below the floor the
             mode names every candidate it probed with the version each reported, and its PASS line
             says outright that the parse did not happen. Installing or building an old bash on
             Linux to manufacture a subject was rejected — it turns a small offline check into
             provisioning work for coverage macOS already supplies.
- placement: `scripts/check-bash-floor.sh` (`SUB_FLOOR_FILES`, `sub_floor_subject`,
             `sub_floor_funsubs`, `sub_floor_lint`, and the `--sub-floor` arm plus the bare case);
             every rule driven to red in `scripts/check-bash-floor-guard.sh`; the third half named
             in `CLAUDE.md` golden rule 4, `CONTRIBUTING.md` § Style, `docs/ci-runners.md` and
             `scripts/selfcheck.sh`'s registry comment.
- reason:    D35 placed the source scan in the guard because there was no mode to put it in, and its
             recorded reason is about the scan being a SCAN rather than an execution — platform
             independence — not about which file should hold it. Once `--sub-floor` needs the same
             three-file list, leaving the predicate in the guard means TWO copies of the below-floor
             set with nothing tying them together: add a fourth carve-out file and one list silently
             does not move. That is the drift `docs/design-principles.md` forbids and the shared
             workflow reader (#262) already settled once. The rule is unchanged and nothing it
             caught is now uncaught — all four of its original cases are fixtures against the mode,
             joined by the ones only an executing check can make.

             The gap-analysis pass argued the D35 scan is additive and must not be deleted as
             superseded by `bash -n`. That is right, and it is why rule A still exists at all: it is
             relocated, not replaced, and the measurements above are the evidence for keeping it.
- guard-observability: TEN mutations of the shipped mode, each applied to a COPY of the tree and
             each required to make `check-bash-floor-guard.sh` go red: rule A's `check_fail`
             dropped; selection taking the first-listed candidate instead of the numerically oldest;
             the probe comparing rc only and ignoring stderr; an unexecutable candidate degraded to
             a skip; that same candidate reported as ABSENT rather than broken; the stale-set rule
             made to `continue`; rule A suppressed whenever rule B has no subject; the SKIP's note
             made to claim a parse it did not do; rule A wired to `common.sh` alone; and the
             workflow seam rule narrowed back to the single `ADB_BASH_FLOOR` token. The tracked tree
             was never mutated.

             The stub interpreters the selection fixtures use report a fake version to the probe and
             **delegate everything else to a real bash**, so `-n` and the bootstrap probe behave as
             they do in production — a stub that faked those too would let the suite pass against a
             mode that ran neither.
- baseline-issue: n/a — this repo IS the baseline; #310 is the tracking issue.
