# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is by git tag. Because
installs are symlinks, changes on `main` reach a user's clone on their next
`git pull` — keep `main` releasable.

## [Unreleased]

### Fixed

- **`/roadmap` no longer freezes a ready issue on a passing `#N` mention** (`base/workflows/roadmap.md`,
  `scripts/lib/roadmap-lib.sh`, #69): step 6's in-flight check matched **any** `#N` substring in an open
  PR body, so a bare `Refs #69` — or prose like "similar to #69" — marked a genuinely-ready member
  `in-flight` and froze it **indefinitely**, contradicting the skill's own rule that `Refs #N` is a
  cross-reference and not an edge. A member is now frozen only when an open PR **actually targets** it:
  the union of the PR's **linked-issue set** (`closingIssuesReferences` — GitHub's own computed set) and
  a **closing-keyword scan** of the body (`Closes/Fixes/Resolves #N`, which catches a stacked PR into a
  non-default branch that GitHub does not auto-link). Matching is numeric and **repo-scoped**, so `#7`
  never matches `#70` and a cross-repo `owner/repo#N` link never freezes this repo's `#N`. The predicate
  is **fail-closed** — malformed JSON or a missing `jq` exits `>=2` and hard-stops the run rather than
  reading as "no PR targets this", which would emit work someone is already implementing. Also fixes the
  inline comment that described a jq boolean as an empty stream.

### Added

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

[Unreleased]: https://github.com/BWBama85/ai-dev-baseline/commits/main
