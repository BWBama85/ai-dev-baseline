# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is by git tag. Because
installs are symlinks, changes on `main` reach a user's clone on their next
`git pull` — keep `main` releasable.

## [Unreleased]

### Added

- **Release readiness now verifies the default branch is green** (#78). A drained checklist said
  the *requirements* were done; it said nothing about whether the code was **shippable**, so on a
  repo that deploys on cut `/roadmap` could announce "✅ Release requirements met — cutting" while
  `main` was red. Readiness gains a second, live-verified condition, computed by a new shared
  predicate `roadmap-lib.sh branch-health` and consulted **only** at the would-be-`met` boundary
  (a repo with open blockers never pays for a CI read it cannot act on).
  - **Two new verdicts.** `not-green` — requirements met but the branch is red, naming the failing
    check; the action is `/debug`, not `/implement-issue`. `indeterminate` — health could not be
    established (a check still running, or CI that has never reported on this commit); this
    **fails closed**, because an unverifiable build is treated as unshippable, never as green.
  - **Anchored to the default branch's HEAD commit**, not to `gh run list --branch … --limit 1`,
    which lists runs newest-first across all workflows and can answer with an unrelated scheduled
    workflow, a run for an *older* commit, or one workflow's success while a sibling is red.
  - **Reads both check APIs.** The Checks API (GitHub Actions and check-run apps) *and* the legacy
    commit-status API (CircleCI, Vercel, Cloudflare, …) — reading one silently ignores whole CI
    providers. Check runs are attributed by `app.slug`, so a result from another app cannot stand
    in as proof that Actions reported. `skipped`/`neutral` are not failures, matching how GitHub
    scores a required check.
  - **A repo with no CI is never deadlocked** (#24): with no active workflows and nothing reported,
    health is skipped and the cut is emitted — saying the check was skipped rather than claiming a
    branch is green when it was never checked.
  - **`release-ready` takes a required sixth `<health>` argument.** Required, not defaulted: a
    default would be fail-**open**, letting an un-updated caller keep returning `met` without ever
    verifying the build. `baseline release roll` passes `skipped` explicitly — it is post-cut
    bookkeeping that ships nothing, and gating it on live CI would strand the terminating loop the
    rollover contract (#74) exists to protect.
  - **An unmilestoned open `release-blocker` is no longer swept into `Backlog`** while
    release-readiness mode is active. That would drop a declared must-have out of the set readiness
    counts, so the next run would compute `met` and cut with an abandoned blocker parked in the
    backlog — the autofix manufacturing the silent-ignore this change exists to prevent. It prints
    a `WARN:` line instead; it warns, it does not gate. In classic mode the carve-out is inert and
    the sweep is byte-identical.
- **`/roadmap` fixes the unambiguous tracker-hygiene defects it finds** (#109). The skill reported
  problems it was fully capable of repairing, so each one became a manual chore or a flag that
  reprinted until someone acted. A new step 4b repairs the closed list — an open issue in no
  milestone moves to the backlog, a resolved artifact missing its `roadmap` label gets it, an
  unpinned artifact is pinned — and reports each in **one line**. The tier line is explicit and the
  **default is escalate**: a defect qualifies only if it is unambiguous, mechanical, reversible and
  tracker-only, and anything outside the table surfaces as an owner question instead. It stays
  idempotent, still **never touches repository code**, and `--no-autofix` gives a read-only run.
  The backlog milestone is resolved live (a `backlog-milestone` marker, else `Backlog`); if neither
  resolves it escalates rather than inventing a convention the repo never opted into.
- **A mocked-`gh` harness that executes the workflow's own snippets** (`scripts/check-roadmap-e2e.sh`,
  #75). `docs/roadmap-acceptance.md` was a manual checklist; the mechanical half is now automated in
  `selfcheck` + CI. The harness **extracts each fenced command by its `# ADB-SNIPPET:` marker and
  runs it** against a fixture-driven stub `gh`, so a documented command that no longer works is a
  test failure instead of a surprise mid-run — something a prose lint cannot catch. It found three
  real defects on its first run: the readiness snippet depended on a `$REPO` its caller had to have
  set, the gauge snippet exploded on an unset optional `$LABEL`, and a failed milestone read piped
  empty stdin into the tabulator and reported "no requirements yet" for a milestone full of open
  blockers. All three are fixed here.

### Changed

- **`/roadmap` has an output contract: the last line is always the next action** (#107). The emit
  template printed `Why:` *after* `Next:`, so the command was never last — and nothing in the spec
  said the emission had to come last at all, so runs appended reconcile detail, bundle tables and
  look-ahead after it (one run stranded the instruction fifteen lines from the end). The order is
  now fixed — gauge → owner-action lines → `Why:` → `Next:` — with **nothing after `Next:`**, a
  ≤5-line default, and an explicit never-print list (bundle tables, "what changed since last run",
  per-issue narration, zero-count sections, self-narration about verification performed). Terminal
  states are action lines too (`Next: none — roadmap complete …`), so "the last line tells you what
  to do" holds even when the answer is "nothing". A met release still prints its rollover reminder,
  now **above** the `Next:` line. Reconcile detail is not lost: it goes to the artifact, which is
  the record. `scripts/check-roadmap.sh` pins it — every fenced output example in the workflow must
  end with its `Next:` line.

### Fixed

- **`/roadmap` no longer silently truncates the backlog** (#79). Every list read used a bare
  `--limit 200` with no pagination and no truncation detection — and because `gh` returns
  newest-first, the dropped issues were the **oldest**, which skew foundational and
  dependency-bearing. Truncation is not an error, so the hard-stop-on-`gh`-error rule never fired
  on it. The consequence was not a missing row: an open issue absent from the open set is
  reconciled to **Done**, so real work disappeared from the plan; and a pre-existing roadmap past
  the cap was invisible to the adopt scan, which then created a second artifact — manufacturing the
  split-brain the skill hard-stops on. Collections are now read with `gh api --paginate` (no magic
  constant) and cross-checked against the Search API's exact `total_count`; a **short** read is a
  hard stop, while reading *more* than the index reports is treated as the benign index lag it is.
  The open-PR read, which has no paginated equivalent, hard-stops when it exactly saturates its
  cap. The Search-based gauge/readiness path was already exact and is untouched.
- **A failed `gh` read can no longer be mistaken for an empty tracker** (#75/#79). `gh api … |
  release-counts` reports only the **pipeline's last** status, so a failed milestone read reached
  the tabulator as empty stdin — a legitimately empty milestone — and the run reported
  `unarmed` ("no requirements yet") for a milestone full of open blockers. Reads and parses are now
  separate steps, each checked on its own status. Found by the new harness.
- **`/roadmap` no longer re-asks a question the owner already answered** (#108). Reconcile derived
  dependency edges from issue bodies and from the artifact's own `## Dependencies` section, so a
  decision recorded in a **comment** was invisible and the same prompt reprinted verbatim on three
  consecutive runs, while a stale edge that outlived its source text kept blocking a bundle. Two
  changes fix it: the artifact gains an owner-authoritative **`## Decisions`** section that
  `/roadmap` reads and never rewrites — a question whose id appears there is retired permanently —
  and `## Dependencies` becomes a **derived view**, rebuilt every run from the live sources (issue
  bodies + decision rows) so an edge whose source assertion is gone disappears. Every surfaced
  question now carries a stable id (`dep-outside-release:#N`, `dep-canceled:#N`, …) and names where
  to record the answer, because a question the owner cannot durably answer is a question this skill
  asks forever.
- **Dependency edges are extracted by a tested predicate, not by eye** (`roadmap-lib.sh
  deps-from-body`, #108): explicit keywords only, and a **negated** mention ("no longer depends on
  #25", "does not depend on #25") now **retires** an edge instead of creating one — the same
  over-match class as #69, on the dependency side. A repo-qualified `owner/repo#N` is not a local
  edge, a `#N` chain (`Depends on #5, #6 and #7`) yields every member, and an interrupted chain
  stops rather than inventing an edge that would block a bundle forever.
- **`/roadmap` no longer wastes a guaranteed failed write on every run** (#94). Step 1 created its
  scratch path with `mktemp -t roadmap-body.XXXXXX`, which *creates* the file — and the write tool
  refuses to overwrite a file it has not read, so persisting the artifact failed every single time
  and cost a compensating read plus a retry. It now makes a scratch **directory** and writes inside
  it (the directory exists; the target does not), using the **positional** template rather than
  `-t`, which on macOS keeps the `XXXXXX` literally and appends its own suffix. The same latent
  trap in `/new-release`'s changelog-stash guidance is fixed too.

- **The cross-agent dispatch bound is now a hang backstop, not a work budget**
  (`scripts/lib/role-dispatch.sh`, #93): the default rose from 7 to **45 minutes (2700 s)**.
  The old bound sat near typical runtime, so ordinary high-reasoning passes tripped it — codex
  gap analysis timed out on three consecutive runs (`rc=124`) and each one silently fell back to
  a Claude subagent, which meant `agents.toml` said `gap_analysis = "codex"` while Claude did the
  work. A backstop belongs well above the longest legitimate run; `ADB_DISPATCH_TIMEOUT_SECS`
  still overrides it, but a stock clone needs no environment set. The bound applies to **every**
  agent and role the helper dispatches, not just codex.
- **Gap analysis is dispatched in the background, and the millisecond ceiling is gone**
  (`base/workflows/implement-issue.md`, #93): a harness typically caps a *foreground* command
  (Claude Code: 10 minutes) far below the backstop, so raising the default alone would have
  changed nothing — the outer cap fired first. The old `420000`–`600000` ms guidance was a
  harness artifact documented as if it were a property of codex, and it taught every reader to
  cap itself at 10 minutes; it is retired. Verified on this issue's own run: codex completed in
  **~9.5 minutes**, past both the old default and the 9-minute bound that had failed before it.
- **The backstop always terminates** (`scripts/lib/role-dispatch.sh`, #93): both paths now
  escalate **TERM → grace → KILL** (`timeout -k`, and by hand in the portable watchdog). Sending
  only SIGTERM left `wait` blocking forever on a child that ignores it — tolerable at a
  seven-minute bound under an outer harness cap, an unbounded deadlock at 45 minutes without one.
  A bound-fired kill reports `124` on **every** path, including where GNU `timeout` would
  otherwise relay the child's `137`.
- **Dispatch failures are classified instead of collapsed** (`adb_dispatch_classify_rc`, #93):
  `124` (our backstop) vs `143` (an **outer** bound killed it first) vs `137` (an external kill)
  vs any other non-zero (a real agent error) each carry a different fix, and each now says so on
  stderr. Treating them alike is how a bound problem masqueraded as a codex problem for three runs.
- **`gap_analysis` never silently substitutes another agent** (`base/roles.md`, #93): it retries
  the assigned agent exactly once, then reports the classified incompleteness and stops. A
  too-small bound must surface as a bound problem, not quietly demote the owner's chosen
  reviewer. The `review` role keeps its fallback — its slots are independent and a documented
  substitution there loses no configuration meaning.

### Added

- **`req_absent` / `stale` — enforcing a *superseded* fact** (`scripts/check-lib.sh`,
  `scripts/check-fact-drift.sh`, #93): fact-drift was positive-presence only, so a file carrying
  both the new figure and the old one beside it passed every rule while still misinforming the
  reader. Repointing a fact now also sweeps the retired form out of every consumer, including the
  three rendered skills. `CHANGELOG.md` is deliberately exempt: its entries record what shipped at
  the time, and rewriting shipped history to satisfy a lint would be a lie rather than a fix.

- **`baseline repo` — hand PR merges to GitHub** (`scripts/lib/repo-settings.sh`, #87): sets the
  default branch's required status checks and enables `allow_auto_merge`, so a PR opened by
  `/implement-issue` merges itself once checks pass and threads resolve. It closes a real hole
  first: this repo carried branch protection with `required_conversation_resolution` on and **no
  required status checks**, so a red PR could merge, gated only by a human noticing.
  **The order is the safety property** — checks are written strictly before auto-merge, and a
  failed checks write aborts before auto-merge is touched; reversed, auto-merge lands PRs with
  nothing gating them at all.
  The required contexts are **discovered** from `.github/workflows`, never hardcoded, because
  GitHub validates nothing: it accepts any string as a context and simply waits forever for a
  check that will never report. Discovery is scoped to the `jobs:` block — `on:` puts `push:` and
  `pull_request:` at the same two-space indent as job keys, so a whole-file scan would require two
  contexts that can never report and deadlock every PR — and it emits only jobs it can prove run
  on every PR, loudly skipping the rest (`if:`, matrix, reusable `uses:`, a `${{ }}` name, a
  paths/branches-filtered or non-PR-triggered workflow) rather than guessing.
  `apply` picks the **narrowest endpoint that works**, since a full protection `PUT` replaces the
  whole object: it PATCHes the status-check sub-resource when one exists, and otherwise rebuilds
  the PUT body from the live object, so `required_conversation_resolution` and "require a pull
  request before merging" survive instead of being silently reset.
  `automerge-ok` is the runtime guard `/implement-issue` asks before arming, with a pinned
  exit-code contract (`0` safe · `10` auto-merge off · `11` CI but no required checks · `12` no CI
  — where `--auto` would merge *immediately* · `13` a required context nothing reports, so an armed
  PR would hang · `20` unreadable, fail closed). `status` reports
  drift in both directions, which is the only place a renamed CI job becomes visible: the old
  context stays required and blocks every PR while the new one gates nothing.
  Discovery refuses to require anything it cannot prove reports on every PR — including a
  `pull_request:` that narrows `types:` without both `opened` and `synchronize`, which is the
  merge-cleanup workflow (`types: [closed]`) that would otherwise become a required context no
  open PR ever satisfies. `apply` also **keeps** required contexts it did not discover (an
  external provider such as Codecov is not in `.github/workflows`, and writing the discovered set
  absolutely would delete it silently); `--prune` writes the exact set when a context really is
  stale.
  Defaults are recorded in `.ai-dev-baseline/decisions.md` (D9): `strict` off, `enforce_admins`
  off, required approvals 0 — each the choice that cannot silently stall the loop, with the
  stricter option behind an explicit flag.

- **`baseline release roll` — the release rollover contract** (`scripts/lib/release-convention.sh`,
  #74): after your project-owned release action cuts a version, `roll --version vX.Y.Z` archives the
  release milestone under that version, opens a fresh empty one under the rolling title, and sends
  leftover open non-blockers to `Backlog`. Without it a cut **strands the loop** — the milestone
  stays open with zero open blockers, so the readiness predicate returns `met` on every later run
  and `/roadmap` re-emits the same cut forever. Three things make it safe: it re-verifies readiness
  live through the *shared* predicate (`roadmap-lib.sh release-ready`) and fails closed rather than
  trusting the `/roadmap` run that emitted the cut; `--force` waives that verdict (the override for
  a `held` release) but never the separate refusal to demote an **open** `release-blocker` to
  `Backlog`; and the four mutations run in the one safe order — rename (frees the title, which
  GitHub requires before the create) → create → move → **close last**, so an interruption always
  leaves a resumable state, which a re-run detects and resumes. `--dry-run` prints the plan and
  changes nothing. The rolling title is read from the roadmap artifact's `release-milestone` marker
  rather than defaulting to `Next release` — `--release-name` was never persisted, so a repo that
  opted in under a custom name would otherwise have the wrong milestone rolled — and the marker
  itself never needs editing, because the rolling *title* is what gets recreated.
  `--resume` finishes a roll that was interrupted after the fresh milestone was created (that state
  is genuinely indistinguishable from a pre-existing version-named milestone, so it asks rather than
  guesses); an interruption *before* it — where no milestone carries the rolling title and
  `/roadmap` is hard-stopped — resumes automatically, and restores that title even when a blocker
  was reopened meanwhile, since restoring it is repair rather than rollover. `--backlog-name` names
  a renamed backlog milestone.
- **`roadmap-lib.sh release-counts` and `roadmap-lib.sh marker-title`** (#74): the predicate's
  *inputs* and the release-readiness *activation marker* were being re-derived by each caller while
  only the final verdict was shared, so `roll` and `/roadmap` could still disagree about the same
  tracker. Both now live in the one library `scripts/check-roadmap.sh` regression-tests, which also
  fixed a live divergence — the marker's value is matched `[^>]*` (not `.*`), so it cannot run past
  its own `-->` into a later comment, and it is extracted per occurrence so two markers on one line
  surface as two titles instead of silently resolving to the last.

### Changed

- **Milestone rollover moved out of the project-owned `/release`** (`docs/release-goal-convention.md`,
  `docs/roles-and-agents.md`, decision **D8**, #74): both docs previously assigned it to your own
  release skill. #3/D7 still holds for *cutting* — four surveyed projects cut four incompatible ways,
  so no generic form exists — but rolling has exactly one correct shape, on milestones the baseline
  already creates, and its non-obvious part is a trap: leftover non-blockers must go to `Backlog`,
  never "roll forward", because a milestone counts as *armed* at ≥1 issue **open or closed**, so
  seeding the fresh one re-fires `met` for a release containing nothing. `scripts/check-release-role.sh`
  gains a fifth group pinning the new boundary (roll performs no version bump, changelog, tag,
  package, publish, or deploy) — `release-convention.sh` is now the one file with a plausible path to
  grow into the generic cutter #3 rejected, and the absence checks cannot see that.
- **`/roadmap`'s met-emission names the rollover** (`base/workflows/roadmap.md` → all three agents):
  it now prints `Then: baseline release roll --version <version>` under the `Next:` line, and the
  leftover-issues note says they go to `Backlog` instead of promising they "roll to the next cycle."

## [1.0.0] - 2026-07-25

First tagged release. The baseline is the agent-neutral single source of truth installed
into other projects: shared practices rendered into each agent's root doc, workflows
rendered into native skills for Claude · Codex · Antigravity/Gemini, a role manifest
(`agents.toml`), auto-detected quality gates, and the enforcement hooks that hold them.
Everything below landed before this tag; entries are grouped as they accumulated.

### Changed

- **`release` is documented as a permanently project-owned role — the baseline ships no `/release`**
  (`base/roles.md`, `docs/roles-and-agents.md`, `README.md`, `templates/agents.toml`, #3): the role
  was named but undecided, so it read as "not built yet" rather than "deliberately yours." A sweep of
  four real projects found four incompatible release schemes (SemVer + `git-cliff` + a milestone roll;
  SemVer + a `cosign`-signed GHCR image; **CalVer** `YYYY.MM.patch` with no changelog; a WordPress-plugin
  zip via `build.sh` + `gh release create`), so a generic "bump · changelog · tag · deploy" skeleton
  would be wrong for three of the four — under a permanent published tag. The baseline now states the
  decision on every surface a user lands on, and spells out the contract that most easily misfires:
  **`[roles].release` names an executor and installs nothing** — it stays inert until your own
  `/release` skill resolves it (`role-dispatch.sh resolve release`), so a `release = "codex"` that no
  skill consumes is silently ignored. `/roadmap` is unchanged: it still emits `Next: /release` and
  never runs it, retargetable with `<!-- release-command: CMD -->`.
- **`/new-release` now says what it is not** (`base/workflows/new-release.md` → all three agents' skills,
  #3): the name collides with the project-owned `/release`, and both were live in one session. A scope
  note at the top states that `/new-release` reviews an **upstream** CLI's changelog (Claude · Codex ·
  Antigravity) and never bumps, tags, packages, or deploys anything of yours. Deliberately a note and
  **not** a rename — renaming a shipped skill is a breaking migration (installed symlink targets,
  project `overrides.md` anchors, per-project state files, orphan-render detection); the rename
  decision is tracked separately as #82.
- **`agent-init` prints the full effective role map** (`bin/agent-init`): it advertised the complete
  repo → global → built-in resolution but printed only four of six roles, hiding `issue_author` and
  `release`. All six now print, with a note naming which are actually consumed by a shipped workflow —
  so a resolved `release` is never misread as "the baseline will cut your release."

### Fixed

- **`/roadmap` no longer freezes a ready issue on a passing `#N` mention** (`base/workflows/roadmap.md`,
  `scripts/lib/roadmap-lib.sh`, #69): step 6's in-flight check matched **any** `#N` substring in an open
  PR body, so a bare `Refs #69` — or prose like "similar to #69" — marked a genuinely-ready member
  `in-flight` and froze it **indefinitely**, contradicting the skill's own rule that `Refs #N` is a
  cross-reference and not an edge. A member is now frozen only when an open PR **actually targets** it:
  the union of the PR's **linked-issue set** (`closingIssuesReferences` — GitHub's own computed set) and
  a **closing-keyword scan** of the body (`Closes/Fixes/Resolves` followed by `#N`, `owner/repo#N`, or
  the issue URL — all three forms GitHub documents — which catches a stacked PR into a non-default
  branch that GitHub does not auto-link). Matching is numeric and **repo-scoped**, so `#7`
  never matches `#70` and a cross-repo `owner/repo#N` link never freezes this repo's `#N`. The predicate
  is **fail-closed** — malformed JSON or a missing `jq` exits `>=2` and hard-stops the run rather than
  reading as "no PR targets this", which would emit work someone is already implementing. Also fixes the
  inline comment that described a jq boolean as an empty stream.

### Added

- **`release-role` check — a guard for a *negative* invariant** (`scripts/check-release-role.sh`,
  wired into `scripts/selfcheck.sh` + CI, #3): "no `/release` skill ships" is a decision no existing
  check could express — `build-drift` and `workflow-map` prove source↔render agreement for workflows
  that *exist*, so a future `base/workflows/release.md` would render correctly and pass every gate,
  silently reversing #3. The lint asserts the **absence** (no release workflow source, no rendered
  release skill in any agent tree), the **presence** of the decision on all four user-facing surfaces,
  the `/new-release` disambiguation in the workflow source (and, via `build-drift`, in every agent's
  shipped skill), and the emit contract (`/roadmap` still names `/release` and its `release-command`
  override). Like `fact-drift`
  it is an allowlisted positive-presence check over small stable tokens, so rewording a paragraph
  never fails CI — dropping the claim does. `check-role-dispatch.sh` also gained `release` /
  `issue_author` resolution coverage (explicit value wins; unset falls back to `primary`, proven with
  a non-`claude` primary so the fallback cannot pass by coincidence; lists and unknown tokens rejected).

- **`/roadmap` behavioral test coverage + acceptance script** (`scripts/lib/roadmap-lib.sh`,
  `scripts/check-roadmap.sh`, `docs/roadmap-acceptance.md`, #45): `/roadmap` shipped with CI coverage
  only for frontmatter/render parity — none of its actual behavior. Its two load-bearing decisions are
  now extracted into a shared library (`roadmap-lib.sh`: `pr-targets-issue` and `release-ready`, both
  **pure** — they take already-fetched JSON/arguments and never call `gh`, so the workflow's network
  shape is unchanged) and pinned by an **offline regression suite** wired into `selfcheck` + CI: the #69
  regression cases, word-boundary and cross-repo safety, null/empty/malformed shapes, the fail-closed
  error band, the four-way readiness verdict (`unarmed`/`unmet`/`held`/`met`) including blocker-mode vs
  fallback and the `NOT_PLANNED` withhold, determinism, and a **drift guard** proving the workflow still
  delegates to the tested predicates instead of reverting to inline logic. The behaviors that are
  irreducibly live-tracker (bootstrap, adopt-not-duplicate, reconcile, projection, completion reporting,
  and every release-readiness scenario) are covered by a copy-pasteable acceptance script,
  `docs/roadmap-acceptance.md`, which doubles as the specification for a future mocked-`gh` harness.
  A new `{{ROADMAP_LIB}}` build placeholder renders the helper's path per agent, so Claude, Codex, and
  Gemini each resolve it under their own install root.

- **Release-goal convention module + `/roadmap` release-readiness** (`docs/release-goal-convention.md`,
  `scripts/lib/release-convention.sh`, `bin/baseline`, `base/workflows/roadmap.md`, #27 + #71): an
  **opt-in** module that lets the workflow — not the operator — decide when a release is ready. `baseline
  release init` stands up the `Next release` (rolling) + `Backlog` (standing) milestones and the
  `release-blocker` + `post-deploy` labels in a repo, idempotently, and prints the activation marker to add to
  the roadmap artifact (it never edits the artifact — /roadmap is its sole writer). When a repo opts in (an
  explicit `<!-- release-milestone: NAME -->` marker on the
  roadmap issue — never coincidental milestone-name detection), `/roadmap` computes readiness live every
  run — **0 open `release-blocker` issues in the active milestone** (falling back to 0 open issues when the
  label doesn't exist), requiring an *armed* (non-empty) set and surfacing a `NOT_PLANNED`-canceled blocker
  — scopes advancement to the release set (projecting bundles onto the milestone so `Backlog` work is never
  pulled forward), and emits `Next: /release` with a requirements-met banner once met. It composes with the
  destination-report gauge (#68), which is milestone-scoped in this mode so gauge and trigger agree. Issue
  filing (`/create-issue`, `/implement-issue` deferred-work, and the `issues-and-scope` practice) defaults a
  *discovery* to `Backlog` when the convention is detected live, so the frozen requirement set converges.
  A repo that never adopts it sees **byte-identical** classic behavior. The auto-cut (zero-touch `/release`)
  executor is documented as an opt-in driver-layer concern and tracked as a follow-up; `/roadmap` only emits.
- **Repo-shape tolerance — `adb_repo_shape` + shape-aware `agent-init`** (`scripts/lib/common.sh`,
  `bin/agent-init`, `base/practices/repo-scope.md`, #23): a new shared primitive that reports the
  *shape* of the repo a directory sits in — git-root vs. working dir (`cwd_is_root`), whether the
  parent is itself in a repo (`parent_in_git` / `nested_in`), root docs found **above** the repo
  and outside it (`foreign_doc`), and additional in-tree package root docs (`extra_doc`) — so
  tooling stops assuming git-root == project-root or a single root doc. It canonicalizes paths
  physically (so macOS `/var` vs `/private/var` never mis-compares), and never lets an unknown
  masquerade as a clean answer (an unreadable start emits `warning`, a depth-bounded scan emits
  `scan_truncated`). `bin/agent-init` now consumes it: run from **anywhere inside** a repo it
  resolves and initializes the git root, and it **surfaces** a non-tidy layout — a repo nested in
  an untracked parent tree (e.g. a plugin under a WordPress install), an out-of-repo `CLAUDE.md`
  referenced by relative path, a monorepo/layered layout — instead of hard-failing or writing to
  the wrong root; a non-git directory is refused without writing anything. `base/practices/repo-scope.md`
  gains a "the project may be larger or smaller than the git root" section (rendered into all three
  root docs). New tests: `adb_repo_shape` cases in `check-common-lib.sh` + a dedicated
  `scripts/check-agent-init.sh` integration test (+ CI job) covering subdir resolution, the
  bama-style untracked-parent acceptance case, nested repos, and the non-git refusal. The mechanical
  per-skill preflight wiring (e.g. `/implement-issue`'s post-merge sync consuming the primitive) is
  tracked as a follow-up.
- **Runtime role-dispatch helper + role-model extensibility** (`scripts/lib/role-dispatch.sh`,
  #15 / #8 / #26): a shared, agent-neutral helper that reads `agents.toml`, resolves a role
  through the documented order (repo → global default → built-in), and dispatches the work to
  the configured agent's CLI — so workflows call it instead of hand-writing the same lookup +
  invocation in each skill. `resolve <role>` prints the token(s) and **validates** the manifest
  (an unknown agent token or an explicit `review = []` is a hard error, never a silent
  fall-through past an invalid layer); `invoke <role|agent>` runs one agent's CLI with the ≥7-min
  codex bound and returns only its **clean final message** — for codex via `--output-last-message`,
  so the repo-exploration stream no longer contaminates captured gap-analysis findings (#8). It
  installs beside `project-gates.sh` under every agent's `scripts/lib/`, and the workflows reach
  it through two new render placeholders, `{{ROLE_DISPATCH}}` and `{{CURRENT_AGENT}}`. `agents.toml`
  gains a first-class `[reviewers] bots` allowlist for **async external-bot reviewers** (GitHub
  Apps that post threads after the PR opens); `/resolve-pr-threads` now derives its
  resolvable-login set from that single source as an **exact, anchored allowlist** (never a
  `[bot]`-suffix heuristic, so a human thread can't be caught), and `base/roles.md` states that
  bespoke per-project orchestration stays project-scoped, not new baseline vocabulary (#26).
  `bin/agent-init` prints the full effective role map (repo → global → built-in) through the
  helper. New unit tests: `scripts/check-role-dispatch.sh` (+ CI job) and `adb_toml_array` cases
  in `check-common-lib.sh`.
- **`/roadmap` — maintain the build roadmap and emit the next batch** (`base/workflows/roadmap.md`,
  #39): a new skill that closes the development loop. It locates one canonical roadmap
  artifact (the single open issue bearing the `roadmap` label — adopting a pre-existing pinned
  roadmap issue rather than duplicating it), reconciles it against the live tracker (marking
  done what's *closed*, slotting newly-filed issues, dropping stale refs), and emits the next
  unblocked, one-branch bundle as a ready `Next: /implement-issue <ids>` command with a
  rationale. The artifact holds only order + branch-bundles + dependency edges — never
  milestone membership (the DRY split). Deterministic (same tracker state → same next batch),
  dependency-aware (explicit `Depends on`/`Blocked by` edges only, not `Refs`), and it skips
  in-flight bundles and excludes itself. Rendered into the Claude skill; Codex/Gemini rides the
  existing workflow-parity follow-up.
- **The framework dogfoods its own manifest** (`agents.toml`, #7): a committed repo-root
  `agents.toml` makes the effective roles explicit (`primary`/`gap_analysis`/`review`/`debug`)
  and wires the repo's real gate — `scripts/selfcheck.sh` — as the `test` gate, so the skill's
  in-loop gate and the global precommit Stop-hook both run selfcheck on a feature branch (not
  only CI). The three toolchain-less axes are declared N/A. The `gate-detector` self-check +ci
  now assert the no-op against a clean temp dir *and* positively assert repo-root detection
  surfaces the committed gate. (`.claude/state/` was already gitignored.)
- **`verify-before-asserting` practice** (`base/practices/verify-before-asserting.md`, #42):
  a new baseline practice — rendered into every agent root doc — that forbids stating or
  acting on volatile external state (PR/branch/issue/CI status) from memory or a stale local
  ref, and requires a fresh authoritative check at the moment of assertion. The PR-touching
  skills are hardened to match: `/cleanup` never narrates a PR's open/closed status (it
  decides purely from freshly-fetched merged-detection + `-d`'s merged-only refusal, now
  classifying both local and remote candidates against `origin/<default>`); `/resolve-pr-threads`
  re-checks PR state immediately before replying/resolving; `/implement-issue` fetches and
  checks issue `state`, warning on a CLOSED issue in the batch.

- **Hardened gate detection + a richer gate model** (`scripts/lib/project-gates.sh`,
  #5 · #19):
  - **Exact npm-script detection** — `_adb_pkg_has` now reads `package.json`'s `.scripts`
    with `jq` (falling back to a `"scripts"`-block-scoped heuristic only when `jq` is
    absent), so a *dependency* named `test` no longer produces a phantom `test` gate.
  - **Single-primary-ecosystem detection, made intentional** — the first ecosystem
    (Node → Rust → Go → Python) that yields a command wins, fixing the case where a
    `package.json` with no installed package manager silently suppressed Python detection.
  - **Gates are an open set** — any extra key in `agents.toml [gates]` (e.g. `build`,
    `guards`) is a first-class gate that runs and blocks like the built-in four.
  - **Per-gate N/A** — `[gates.state] <label> = "na"` declares a gate Not-Applicable
    (reported, never a failure or a detection miss), distinct from `""` (disabled).
  - **Per-gate path scope** — `[gates.scope] <label> = "apps/**,packages/**"` runs a gate
    only when the change set (supplied by the Stop-hook `precommit-gate.sh`, now passing
    the branch's changed files) touches a matching path — so a repo expresses docs-only
    skipping without forking the gate script.
  - New `project-gates.sh status` command reports each gate's state (run / N/A / disabled);
    `detect` keeps its two-column `<label>\t<command>` contract. New shared primitive
    `adb_toml_keys`, and a literal-table fix to `adb_toml_get` so a dotted sub-table like
    `[gates.scope]` can't be matched via the `.` regex metacharacter. Behavior is covered
    by `scripts/check-gates.sh` (wired into CI + `selfcheck.sh`).

- **`baseline update` — keep the installed baseline current** (`bin/baseline`, #36):
  one idempotent entrypoint that fast-forwards the install-source clone and self-heals a
  moved installed path, replacing the remembered `git pull` (+ maybe re-`install.sh`)
  ritual. It fast-forwards **only** when the clone is clean, on its default branch, and
  merely behind `origin` — a dirty/detached/non-default/ahead/diverged clone is surfaced
  and left untouched — then **always** re-runs the idempotent installer after the
  fast-forward (self-healing any moved or newly-added link), preserving the installed agent
  set + hook preference, and loudly verifies every canonical link (when already current, it
  re-installs only if a link is found broken). `baseline update --check` reports currency (stable exit-code
  contract for a future `SessionStart` hook, #25) and changes nothing; it **refuses**
  (exit 4) when invoked from a clone other than the one the install points into, so a dev
  clone is never mistaken for the install-source. New primitive `adb_branch_sync_state`
  in `scripts/lib/common.sh`; end-to-end tested by `scripts/check-baseline.sh` (wired into
  CI + `selfcheck.sh`).
- **Post-merge currency sync for the working clone** (#17): `/implement-issue`'s preflight
  now **auto-syncs** to a clean, current default branch when it is *provably safe* —
  clean tree, and the current branch is an ancestor of `origin/<default>` or `gh` reports
  its PR merged (so squash/rebase merges count) — switching to the default, fast-forwarding,
  and deleting merged local branches whose upstream is gone (safe `-d`, protected names
  skipped). It never discards unmerged or uncommitted work: a dirty tree or a
  not-provably-merged branch still hard-errors as before. `/cleanup` now returns to a clean,
  current default **before** sweeping (so the just-merged branch is deletable), and
  `/resolve-pr-threads` restores the branch it started on (or the PR's base) on every exit
  instead of stranding the tree on the PR head.
- **Shared shell library — the ONE home** (`scripts/lib/common.sh`, #30): a single
  implementation of `adb_link` / `adb_unlink_if_ours` (backup-then-symlink and
  ownership-scoped unlink), `adb_default_branch`, `adb_toml_get` / `adb_toml_unquote`
  (used for both `[gates]` and `[roles]`), and `adb_version_ge`. The installer,
  uninstaller, both agent adapters, `agent-init`, and the runtime gates now **source**
  it instead of carrying four-plus copies. `scripts/lib/project-gates.sh` moved here to
  sit beside it (it installs to `~/.<agent>/scripts/lib`). Existing installs keep working
  across the move via a compatibility symlink (`agents/claude/scripts/lib` → `scripts/lib`),
  so a plain `git pull` never silently drops gate enforcement. Unit-tested by
  `scripts/check-common-lib.sh`.
- **CI-enforced no-drift for restated facts** (#30): `scripts/check-fact-drift.sh` pins
  the gate-axis list, cross-agent invocation commands, the codex ≥7-minute timeout, and
  the role-resolution order to their canonical source and fails when a consumer doc
  diverges. `scripts/check-practice-index.sh` keeps `base/practices/00-index.md` in sync
  with the practice files. Both run in CI **and** `selfcheck.sh`; the install dry-run now
  covers all three agents.
- **`docs/design-principles.md`** (#30): the tenets a contribution must satisfy
  (single-source/no-drift, general-over-specific, extensible, config-over-hardcode,
  graceful degradation) with the concrete CI check enforcing each; referenced from
  `CONTRIBUTING.md`. Includes the governance rule that new adapters/gates/hooks build on
  the shared primitives rather than copying logic.
- **`base/practices/handling-the-unknown.md`** (#32): a deterministic
  classify → place → record → escalate protocol for when a project hits something the
  baseline doesn't model, rendered into every agent root doc. Enumerates the prescribed
  home per category (gate → `[gates]`, role → `[roles]`, project rule → the repo's root
  doc, deviation → a `DEVIATION` record, general gap → a baseline issue) and defines the
  per-project decision-log format at `.ai-dev-baseline/decisions.md`. The
  `implement-issue`, `debug`, and `create-issue` workflows reference it.

### Changed

- **`/roadmap` verifies implementable residual before emitting** (`base/workflows/roadmap.md`,
  #50): the reconcile step no longer trusts the roadmap artifact's stored residual note — it
  re-derives each open candidate's done-ness from **ground truth** and classifies it
  `implementable | tracker-only | owner-review` from acceptance-vs-default-branch (read-only),
  merged/closing PRs, and comments/linked follow-ups, **uniformly on every candidate**. A
  still-open issue whose work already shipped under another PR or whose residual was deferred to
  another open issue (the #35 case) is marked `tracker-only` and moved to a new **Reconcile
  flags** section — never emitted as a ready bundle; an unverifiable residual is flagged
  `owner-review` rather than guessed into a batch. The selected bundle is re-classified fresh
  immediately before emit, and a flagged candidate never blocks a genuinely-ready bundle behind
  it. Adds an optional, **config-driven** destination report — a `<!-- destination-label: LABEL -->`
  artifact marker makes each run print `LABEL: N blocker(s) open` (the finish line), kept in the
  artifact rather than hardcoded so the skill stays repo-agnostic. Executable end-to-end coverage
  for the reconcile semantics remains tracked by #45.
- **Stop-hook gates fail loud instead of silently no-opping** (`precommit-gate.sh` ·
  `scripts/lib/project-gates.sh`, #35): a gate that can't load its own shared library
  (`common.sh` / `project-gates.sh`) is a broken/incomplete install — enforcement secretly
  OFF — so it now **blocks (exit 2) with a clear repair message**, never exit 0. `common.sh`
  is required up front (the default-branch resolver is single-source; the gate no longer
  copies it), and `project-gates.sh` fails loud rather than emitting an empty "no gates"
  result when `common.sh` is absent. "No gates detected" (a legitimate no-op) and "the gate
  library is gone" (fail loud) are now distinct. New design principle 6 (never relocate an
  installed path without a self-healing compat shim) with a CI/`selfcheck.sh` guard
  (`scripts/check-install-migration.sh`) that installs the merge-base and simulates a plain
  `git pull` to fail any PR that dangles an installed symlink; `CONTRIBUTING.md` names the
  reflexivity footgun and the two-clone workflow.
- **`implement-issue-gate.sh` re-verifies PR state live** (#44): the Stop hook no longer
  trusts a stored `prUrl`/`phase=complete` to decide a run is done — it queries `gh` at the
  moment it acts, confirms the PR is *this run's* (this repo + this branch) and still OPEN or
  MERGED, and **fails closed**: a closed-without-merge or unverifiable PR keeps the turn going
  (with a state-specific hint) rather than letting it stop on stale state. Extends
  `base/practices/verify-before-asserting.md` to state that automated hooks/gates are in
  scope, not just agent narration. Both hooks tested by `scripts/check-precommit-gate.sh` and
  `scripts/check-implement-gate.sh`.

### Added — initial framework

- **Agent-neutral practices** (`base/practices/`): shell hygiene, git/PR discipline,
  CI diagnose-before-rerun, out-of-scope → tracked issue, repo-scope verification,
  evidence-first debugging, mandatory self-review, logging/secrets.
- **Role model** (`base/roles.md`, `templates/agents.toml`): per-project `primary` /
  `gap_analysis` / `review` / `debug` assignment; swap `primary` with no workflow
  change. Resolution order repo → global default → built-in.
- **Claude agent** (fully wired): six skills — `implement-issue` (role-aware,
  auto-detecting gates, repo-scope + self-review baked in), `create-issue`,
  `resolve-pr-threads`, `new-release`, and the new `cleanup` (sweep all merged
  branches, named explicitly) and `debug` (evidence-first root cause). Two Stop-hook
  gates + statusline.
- **Gate auto-detection** (`scripts/lib/project-gates.sh`): pnpm/npm/yarn/bun, cargo,
  go, python; honors `agents.toml [gates]`; the global gate **defers to any repo that
  ships its own** so nothing double-runs.
- **Codex + Gemini adapters**: install the shared practices into `~/.codex/AGENTS.md`
  / `~/.gemini/GEMINI.md`; deeper workflow parity tracked in Issues.
- **Install contract**: `install.sh --agent …` (symlink + jq-merged Stop hooks,
  backed up, idempotent), `uninstall.sh`, `bin/agent-init`.
- **Tooling**: `scripts/build.sh` (render practices → root docs), `scripts/selfcheck.sh`
  (local CI mirror), CI (shellcheck · build-drift · frontmatter · gate-detector ·
  install dry-run), contributor guide (`CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md`).

### Fixed

- **`/cleanup` no longer offers a phantom `origin` for deletion** (#38): remote branch
  enumeration filtered `git branch -r --merged`'s output with `sed 's@^origin/@@'` alone,
  which left the `origin/HEAD` symref's bare-`origin` short form in the merged list — so
  `/cleanup remote`/`all` would offer `git push origin --delete origin` (a bogus delete of a
  nonexistent branch). The pipeline now drops it (`grep '^origin/' | grep -v '^origin/HEAD$'`
  before the strip). Guarded by a new regression test (`scripts/check-cleanup-enum.sh`, wired
  into `selfcheck.sh` + CI) that reproduces the symref and asserts the fix.
- **`implement-issue` step 8 no longer prescribes an unusable reviewer** (#9): the
  Claude `review` slot now runs an in-process, model-invokable pass — `/simplify`
  (quality) plus a `general-purpose` Claude subagent for the adversarial bug review —
  instead of the user-only `/code-review` (`disable-model-invocation`), which the
  Skill tool rejects. `/code-review` is documented as an optional post-PR human step,
  and the failure-mode note now names the correct cause (user-only by design, not a
  version/toolchain problem).
- **Delegated steps must complete deterministically** (#10): `base/roles.md` and the
  `implement-issue` workflow now carry a **completion contract** — gap-analysis,
  review, and any cross-agent/subagent dispatch run as a single bounded call whose
  outcome is decided by the call *returning* (no output-polling to guess "hung"); on
  timeout/error they abandon → retry once → fall back → block/surface, and never
  finish on partial or empty output. Clarifies that "advisory" is the standing of a
  **completed** finding, not license to skip the step.

[Unreleased]: https://github.com/BWBama85/ai-dev-baseline/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/BWBama85/ai-dev-baseline/releases/tag/v1.0.0
