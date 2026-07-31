# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is by git tag. Because
installs are symlinks, changes on `main` reach a user's clone on their next
`git pull` — keep `main` releasable.

## [Unreleased]

### Added

- **A verifiable claim written into a tracked file is now gated before it can MERGE** (#212, D24).
  (Not before it is *committed* — see the scope note at the end of this entry.)
  The #173 run committed four factual claims nothing checked, and three were wrong: a `#206`
  citation that tracked something else, a `#207` citation for an issue that **did not exist** —
  rendered into all three agents' skills — and "(recorded as D17)" for a decision that is D18. The
  practice forbidding exactly this for PR/issue *status* was loaded in context the whole time, which
  is the same argument D16 already made for turning a rule into an exit code.
  - **`scripts/check-claims.sh`** scans the **added lines of a range** and asserts three things:
    every `#N` resolves, is the kind it is cited as (`gh issue view` answers for a PR number too,
    so `issue #210` naming a pull request is a wrong claim bare existence waves through), and is
    not closed `NOT_PLANNED`; every `D<N>` resolves to a `## D<N> — ` heading in the decision log;
    and every added `- date:` there is within a day of the commit that introduced it — in **both**
    directions, because the #173 entry was stamped a day *ahead*.
  - **The live half is CI-only, and that is D13 rather than an omission.** `selfcheck` stays
    hermetic so a local green keeps predicting CI; the `#N` reads ride CI exactly as
    `required-drift` does, and **fail closed** (exit 3 on an unavailable or unauthenticated `gh`,
    never a pass). The offline run reports how many references it left unverified.
  - **An audited per-line `adb-claim-ok: <reason>` escape**, because prose *about* an abandoned
    issue is legitimate — a blanket `NOT_PLANNED` rejection is semantically wrong, and a gate with
    no way to say so gets worked around. Its first use is this lint's own header, citing
    #150. <!-- adb-claim-ok: cited BECAUSE it is closed NOT_PLANNED — the cautionary case. In
    markdown the marker rides an HTML comment so it does not render; the exemption is per-line,
    so it must sit on the same physical line as the reference. -->
  - **`scripts/check-claims-guard.sh`** drives every rule to RED offline against fixtures in a
    throwaway repo with a stubbed `gh`, asserting the **designated** exit code and diagnostic
    rather than "some non-zero", and pins the active invocation sites so commenting a call out
    breaks a test. It earned its place immediately: it caught a markdown stripper that made one
    rule structurally unable to fire, and an unresolvable `--range` that silently turned the whole
    check into a no-op reporting PASS.
  - **Where the gate actually sits, stated exactly.** It reads COMMITTED revisions, so it runs in
    `selfcheck` (pre-push) and in CI (pre-merge) — there is no pre-commit hook and nothing scans the
    index or working tree. #212 asked for "a pre-commit gate" and that half is **unmet**: activation
    is the open question tracked in #233, because only one agent currently has Stop-hook wiring. The
    distinction matters because "before it is committed" would promise a guarantee nothing delivers.

- **The path-claim check asked for by #212 was built, measured, and deliberately not shipped**
  (#234). Over the last five merges it scored **seven false positives and zero true positives**, in
  the verb-free form and the change-verb form alike, because a changelog is a *historical* document:
  a commit that reflows an older entry re-adds prose making true claims about a different commit. It
  also cannot catch the defect #212 cites as its justification — that sentence named `base/roles.md`,
  which **was** in the diff; what was false was the *kind* of change claimed of it. The judgement
  half moved to a fifth **Claim integrity** lens in `/implement-issue`'s review prompt, which is
  where #212's own follow-up comment puts it.

- **Every negative pin in the anti-drift lint now has to prove it can go red** (#213, D22). An
  `absent:` rule's failure mode is silence: `absent:\[bot\]\$` asked for a contiguous `[bot]$`,
  the two real idioms are `sed 's/\[bot\]$//'` and `sub("\\[bot\\]$"; "")` where the bracket is
  always backslash-escaped, so the pin matched **neither** and shipped green while checking
  nothing. Nothing could have caught it: every assertion still passed.
  - **`fires:<witness>` is now mandatory on every `absent:` rule.** Each witness is a real
    superseded spelling, and `check-fact-drift.sh` fails if a pattern does not match its own
    witness — the unfirable-pin check, run on every invocation. Multi-spelling pins carry one
    witness per spelling, because a pattern that catches three of four is green on the fourth.
  - **`check-fact-drift.sh --mutation`** injects each witness into a **copy** of every file the
    rule pins, re-runs the real lint there, and requires the drift verdict naming that rule and
    that file. It refuses to run against an already-red tree, and distinguishes "the lint stayed
    green" (an unfirable pin) from "the lint crashed" (a broken harness).
  - **`scripts/check-fact-guard.sh`** applies the same rule to the two guards above — they are
    driven against deliberately broken rules and observed failing. It carries the direct
    regression test for the original defect.
  - **The lint now reports what it evaluated** — rules, rule-file assertions, absent rules, files
    scanned, witnesses verified — so "checked and clean" and "matched nothing" are no longer the
    same log line. Zero rules, zero files, an empty pattern and a missing `--` are all failures.
  - **`check_exit_guard`** (in `check-lib.sh`) — a suite's exit status is its LAST COMMAND's, and
    only `check_summary` consults the `fail` counter, so a suite that loses that final line prints
    its `FAIL:` diagnostics and still exits 0. It installs one EXIT trap that fails closed unless
    the summary ran, then runs the cleanup it was given. Wired into `check-fact-guard.sh` here;
    the sweep across the other 22 suites is #231.
  - The wiring pins anchor on `^[^#]*`, an **active** invocation rather than the raw token: a
    `fixed:` pin is satisfied by a commented-out command, which would have left both guards
    un-run with both tokens present — the silent unwiring the pins exist to catch, reproduced by
    the pins themselves.
  - Two latent defects were found by writing the witnesses. `backstop-stale-7min` used
    `[≥>]` and `3[–-]7`; a bracket expression holding a multibyte character is matched **bytewise**
    under a C locale, so `3–7 min` could not be caught there at all — a pin that fired on a UTF-8
    dev box and silently did not on a C-locale runner. Both are now literal alternations.

- **`role-dispatch.sh available <agent>` and `role-dispatch.sh review-rung`** (#211, D21) — a
  reviewer that is not installed is not a reviewer that failed.
  - `available` answers "is this agent's CLI on PATH here?" (`0` available · `1` known agent whose
    CLI is absent · `2` not a token), a third question distinct from `resolve` (who is assigned)
    and an `invoke` status (did the agent fail). Without it, `codex exec` with no `codex` on PATH
    exits **127**, which classifies quite correctly as "a real agent/CLI error" — accurate about
    the exit, wrong about the cause, and arriving at step 8 with the branch, the commits and the
    gates already paid for.
  - `review-rung` decides the whole ladder once and prints `independent <agent>` ·
    `same-model <agent>` · `deferred <logins>` · `none` · `unknown <why>`. `/implement-issue`
    step 8 and `bin/agent-init` both *call* it instead of each interpreting the underlying readers,
    because the two-interpretation version diverged immediately: one side read the bare `bots`,
    whose unset default is eight built-in logins, and would have told a repo that declared nothing
    that an async reviewer was coming.
  - **An absent reviewer CLI no longer blocks a run** and never writes a blocked marker; a reviewer
    that *ran* and did not return still does. `unknown` is never resolved past — an invalid
    `review` token or a malformed `[reviewers] bots` reports `unknown` rather than the flattering
    rung it would otherwise land on.
  - `agent-init` prints the rung at setup time and annotates each role token whose CLI is missing,
    so this is discoverable before a workflow depends on it rather than mid-run.

- **The state-claim rule is now a gate, not documentation** (#195, D16). An agent stating a
  PR/issue/CI status in prose that is stale, paraphrased or never read had been "fixed" twice —
  as a practice, and as `state-assert.sh observe` (#138) — and both fixes were advisory, because
  neither gated anything. It recurred on 2026-07-29 *with the practice loaded and the correct
  reading already in hand*: a `/cleanup` report volunteered `(OPEN at 14:55:26Z)` for a PR that had
  merged fourteen minutes earlier.
  - **`state-assert.sh lint`** — the grammar, as a pure offline predicate. One rule: in prose, a
    status word in the same sentence as an issue/PR reference must itself be introduced by
    `was observed`. Checked **per occurrence, not per sentence** — the shipped sentence carried a
    compliant `was observed MERGED` clause *and* the stale one, so a sentence-level test passes the
    exact defect. That sentence is the regression fixture.
  - **`state-claim-gate.sh`** — a new **`Stop` hook** whose exit code gates the end of the turn,
    joining `pr-review.sh gate` (gates a real merge) and `cleanup-lib.sh branch-verdict` (gates a
    branch delete) as the third guard that works because a wrong answer stops the machine.
  - Precision-first by design: fenced blocks, code spans (including multi-backtick), blockquotes
    and HTML comments declare nothing; `open a PR` and `closed #195` are verbs; and words that
    collide with ordinary prose (`draft`) are kept out of the token set. It never wedges a
    session — missing `jq`, an unreadable transcript, a text-free turn or a broken linter install
    are reported on stderr and allowed through.
  - `verify-before-asserting.md`'s *"what this does not claim to enforce"* section is **rewritten,
    not deleted**: a Stop hook forces a correction but cannot prevent the claim, the grammar is
    small, and the wiring is Claude-only today.

- **This repo now has its own `/release`** (`.claude/skills/release/SKILL.md`, D14). Decision
  **#3/D7** committed the baseline to shipping **no** generic release workflow and made `release`
  a permanently project-owned role — but this project never supplied its own copy, so the role was
  named, `/roadmap` emitted it on a `met` readiness verdict, and nothing resolved it. The procedure
  lived as three prose sentences in `CONTRIBUTING.md` → *Releases* and was hand-executed for both
  v1.0.0 and v1.1.0.
  - **#188 is what made the gap visible.** A slash command that does not exist does not fail loudly
    in Claude Code — it fuzzy-matches the nearest built-in (`release-notes`). Verified against the
    2.1.220 binary: there is **no** `/release` built-in, only `release-notes`, and `release` is not
    among the 110 built-in command names. So a repo that *does* ship a `/release` skill was never
    broken by this; a repo without one gets a silent wrong answer at the exact moment `/roadmap`
    says "cutting."
  - **Every decision is delegated to an already-tested predicate** — `release-ready` and
    `branch-health` gate the cut, `pr-watch.sh wait` waits out the reviewer, `baseline release roll`
    closes the loop. The skill is glue plus the two genuinely project-specific parts: the CHANGELOG
    format and the tag convention.
  - **It lives outside `base/` and `agents/*/skills/`**, the two paths `check-release-role.sh`
    guards, so D7's negative invariant stays green — "the baseline ships no `/release`" and "this
    project has one" are both true, which is what D7 intended.
  - **Two SHAs are captured rather than re-derived**, because both guard a race against an
    irreversible act: the reviewed head becomes `--match-head-commit` so a commit pushed after the
    pass cannot merge unreviewed, and the PR's own `mergeCommit.oid` is what gets tagged — a second
    PR merging in between moves the default branch's HEAD, and tagging that would ship commits the
    changelog never mentions.
  - **It resolves `[roles].release`** before any mutation and stops if the configured executor is
    not the agent driving, rather than silently ignoring the manifest.
- **`agents.toml` declares `release = "claude"` explicitly** instead of leaving it to the `primary`
  default, so the key that the new skill resolves is visible where a reader looks for it.
- **The release skill's decisions live in a tested library, not in prose**
  (`.claude/skills/release/release-lib.sh` + `scripts/check-release-skill.sh`, wired into
  `selfcheck` and CI). The first cut put the whole procedure in SKILL.md with inline shell; two
  review rounds found **17** defects in it, one fatal — and `selfcheck` was **green for all of
  them**, because nothing in the harness reads `.claude/skills/`.
  - `version-ok` — rejects a malformed version (a shell glob is not a validator: `v1.2.3-rc1`,
    `v1x.2.3` and `v1.2.3.4` all pass one), a **reused** version, and one not strictly newer than
    the latest already-used. Reuse matters more than it looks: the stamp merges first, so the
    failure surfaces at `git tag`, leaving the branch claiming a release that was never cut.
  - `changelog-verify` — asserts the heading, the date, that `[Unreleased]` is left **empty**, and
    that **both** link refs match whole-line against URLs derived from slug/last/version, so a
    compare against the *wrong previous tag* is caught. Fixed-string throughout, because `1.1.0`
    is all `.` metacharacters and a plain `grep` accepts `1x1x0`.
  - `checks-settled` — "are this commit's checks **done**", distinct from `branch-health`'s "are
    they **green**". Refuses both shapes that tag an unverified commit: an empty set (CI has not
    registered) and a set smaller than the reviewed head's (GitHub registers jobs incrementally,
    so on a ~26-job repo one fast check finishing makes "nothing pending" briefly true).
  - The library sits **beside the skill**, never in `scripts/lib/` — `adb_agent_manifest` links
    that directory into every install, so a release predicate there would ship generic release
    machinery to every adopting repo, reversing #3/D7 by accident. The check asserts that
    boundary, and that no `{{PLACEHOLDER}}` appears inside a runnable fenced block.

### Changed

- **Deferred work is tracked when it clears a bar, not by default.** `issues-and-scope.md` used to
  read *"File by default; do not ask."* That rule stopped silent scope loss, but it is a generator
  with no sink and nothing else in the baseline pushed the other way. Measured on this repo on
  2026-07-31: **191 issues filed in 14 days against 98 closed — and 35 of those 98 closed
  `NOT_PLANNED`.** More than a third of everything ever tracked turned out not to be worth doing,
  filing outran completion roughly 3:1, and the backlog diverged rather than converged; a triage the
  same day closed 59 of 93 open issues in one pass, almost all of them shapes rather than defects.
  - **The bar:** file only if both questions have concrete answers — *who does this*, and *what
    breaks if nobody ever does*. Either unanswerable → don't file.
  - **Named non-reasons**, because these produced most of the closed set: the same rule stated
    twice, a helper that would live better elsewhere, a check that could be more thorough, a sibling
    that *might* share a bug (go look — a real one is filable, a hypothetical one is not), a feature
    that could be generalized, an edge case nothing has hit. Only a defect *caused by* one of those
    is filable, and then you file the defect.
  - **The second generator is bounded too:** `handling-the-unknown.md`'s "a general gap always earns
    a filed issue" now defers to the same bar — a stopgap that holds is a fix, not a debt, and
    "many projects *would* want this" is a hypothesis about absent users, not an answer.
  - **The workflows follow the practice rather than restating a stricter version.**
    `/implement-issue` step 12 applies the bar and reports "3 deferrals, 1 filed" as a normal
    outcome instead of treating a filing count as proof the step ran; `/create-issue` step 7 now
    treats its 11 axes as a scope-*finding* instrument whose output must clear the bar before being
    offered, and filing nothing is an expected result. `docs/philosophy.md` and `README.md` carried
    the old absolute wording and are corrected.

- **Follow-up issues are filed before anything cites them** (#212). `/implement-issue` used to file
  deferred work in step 12, *after* step 10 had already written a PR body citing it — so the
  citation was committed before the thing it cited existed. Step 9 now files each deferral at the
  moment it is decided, step 10 may only cite numbers that already resolve, and step 12 becomes a
  reconcile sweep that adds the PR-side link (which step 9 structurally cannot) and dedupes two
  phases filing into one tracker. `/create-issue` gains the sequence that resolves its genuine
  parent/child ordering cycle — file the primary, file the siblings citing it, then edit the primary
  to add the links — and `/roadmap`, which files nothing, gains the narrower rule that a number
  written into its never-rewritten `## Decisions` table must already resolve.

- **`git checkout -- <path>`, `git restore <path>` and `git stash drop` joined the destructive-git
  list** (#213), in `base/practices/git-and-prs.md` and therefore in every agent's root doc. The
  list held `reset --hard`, `push --force`, `clean -fd` and branch/tag deletion — all of which
  mostly move *committed* history, where the reflog usually recovers it. One of the three added
  here discarded ~40 minutes of unsaved work while "restoring" a file after a test.
  The entry is precise about recoverability rather than lumping them together: an edit that was
  never staged was never turned into a git object, so nothing recovers it; a staged snapshot does
  exist as a blob and a dropped stash *is* commit objects, both sometimes salvageable via
  `git fsck --unreachable` until gc prunes them. It is also precise about `git restore`, whose
  `--staged` form rewrites the index and leaves the working file alone.
- **`base/practices/self-review.md` gained two rules** (#213): *a new guard is not done until it
  has been observed failing* — not "test your code", but specifically prove the check can go red,
  on the real superseded input — and *negative-test against a copy, never the live tree*, which is
  the method that avoids the `git checkout` above entirely.

- **The in-session reviewer is now the model that did *not* write the diff** (#211, D21). The
  shipped manifest paired `primary = "claude"` with `review = ["claude"]`, so the prescribed
  review was Claude grading its own work. Both vendors' published guidance argues against that
  from opposite ends — Anthropic's Opus 5 guidance asks that explicit verification scaffolding be
  *removed* from Claude's instructions, while OpenAI's asks Codex for exactly the named-checklist,
  required-vs-optional pass this slot runs.
  - `templates/agents.toml` (and therefore the global manifest `install.sh` writes) now ships
    **`review = ["codex"]`**. **The resolver's built-in fallback for an *unset* `review` is
    unchanged** — still the primary's own pass — so a repo with no manifest behaves exactly as
    before. These are two different "defaults" and only one moved.
  - **Existing manifests are not migrated and do not need to be.** The `claude` review arm stays
    supported: neither `install.sh` nor `agent-init` rewrites an existing `agents.toml`, and a
    Codex-primary repo reviewing with Claude is the same split pointing the other way. What
    changed is that a slot whose token equals `primary` is now *labelled* `same-model (not
    independent)` rather than presented as an independent pass.

### Fixed

- **`pr-watch`'s staleness proof no longer rests on a timestamp the committing machine chose**
  (#175, D19). A review carries `commit_id`, so "did the reviewer review THIS head?" was a field
  comparison — but a **reaction carries no commit at all**, only `created_at`, and neither does a
  task-mode issue comment. Their freshness was proved against the head commit's **committer date**,
  which git records from `GIT_COMMITTER_DATE` verbatim and GitHub echoes back unmodified. The
  reaction's timestamp is GitHub-assigned and the commit's was not, so the comparison was
  **asymmetric in its trust** and only one direction was safe: a future-dated commit made a genuine
  `+1` look stale (`pending` — waits longer), while a **past**-dated one made a **stale `+1` look
  fresh** and returned **`clean` for a head no reviewer had passed**. No attacker was needed — a
  date-preserving rebase (`--committer-date-is-author-date`, `filter-repo`) or a machine whose clock
  is behind by more than the review latency produces it.
  - **The anchor is now the repository activity API** — the latest activity on the head **ref**
    whose `after` SHA is the current head. GitHub stamps that `timestamp` when the ref moved, so it
    answers the question directly ("when did this ref become this SHA") instead of approximating it,
    and it covers ordinary pushes, force-pushes and branch creation alike. **Taking the latest
    matching record, not the earliest, is what catches a reverse force-push**: a ref that went
    `A → B → A` carries two records for `A`, and only the later one says when it is `A` *now*.
  - **The three obvious candidates were rejected, and the reasons are in the module header** so the
    next reader does not re-derive them. Check suites are **SHA-scoped, not ref-scoped**: a commit
    that already ran CI elsewhere carries its *original* timestamp, so an ordinary fast-forward onto
    it keeps the fail-open with no force-push in the story at all — that case is now a regression
    test. Commit statuses share the flaw exactly, and both also require the repo to *have* CI.
    Timeline `head_ref_force_pushed` events are ref-scoped but exist only for **force** pushes.
    `head.repo.pushed_at` is free and genuinely **sound** — it can only ever be too late — but it is
    repo-scoped, so any unrelated push re-opens a settled verdict and an active repo's watch would
    run to its bound instead of converging.
  - **An unestablished anchor is `pending`, on both date-scoped signals.** That costs the findings
    side a wait, and it is still the right trade: one rule over both is what keeps the forgeable
    input out of the file rather than leaving it in "just for comments". A **review** at the head is
    commit-scoped and needs no anchor, so it keeps working regardless — pinned by a test. Because
    the anchor needs no CI, a repo without any **keeps** the clean signal.
  - **Timestamps are validated, not assumed.** Lexicographic comparison is chronological only for
    identical-width `…Z` UTC; `2026-07-25T09:00:00-04:00` sorts *before* `…T05:00:00Z` as a string
    and *after* it as an instant. Every anchor and candidate is checked and anything else is `20` —
    mutation-testing showed that without it an offset timestamp compares straight to `clean`.
  - The header's per-poll request budget said **three** reads for as long as the issue-comments read
    has existed; it is four, plus the anchor on the branch where a signal was found.
  - Two remaining exceptions are now **stated** rather than implied, and filed: a verdict is true of
    the SHA printed beside it, which may no longer be the head (#215), and a retargeted base changes
    the reviewed diff without changing the head SHA (#216).

- **One home for the PR-argument and reviewer-identity primitives — and three fail-open bypasses
  closed** (#173, D18, superseding #176). `pr-review.sh` (#134) and `pr-watch.sh` (#49) each carried
  private copies of four primitives, and the copies had already **diverged into a live defect**: only
  pr-watch's slug parser handled a scheme-less URL, so `pr-review.sh gate --pr
  github.com/other/repo/pull/7` — an ordinary browser copy-paste — produced an *empty* wanted slug,
  skipped the cross-repo refusal entirely, answered about **this** repo's #7, and printed a head SHA
  that `/implement-issue` step 10 then armed `gh pr merge --auto` against. A guard whose entire job
  is to refuse was authorizing an arm on a pull request the operator never named.
  - **`adb_pr_number` / `adb_pr_slug` / `adb_pr_slug_check` / `adb_reviewer_match_jq`** now live once
    in `common.sh`, taking the stronger spelling in every case. `adb_git_origin_slug` is promoted out
    of `state-assert.sh`, which had the only copy. `check-fact-drift.sh` pins both directions — each
    guard still calls each primitive, and no local copy has come back.
  - **The cross-check fails closed.** It was guarded on a non-empty observed slug, so it *vanished*
    on exactly the malformed responses it exists to catch (already fixed in pr-watch after the #178
    review, never back-propagated). Missing, malformed, or non-`owner/repo` metadata is now
    unreadable (20) and **outranks** a mismatched argument.
  - **A bare PR number is no longer cross-repo redirectable.** Every read addresses
    `repos/{owner}/{repo}`, which `gh` expands — and the documented `GH_REPO` variable overrides that
    expansion (verified: `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers `cli/cli` from a
    directory that is not a repository). A bare number names no repository, so nothing in the
    argument could catch it — and `/resolve-pr-threads --watch` passes exactly that form. Both guards
    now anchor to the set of repositories the checkout's **git remotes** name, which no `gh`
    variable can move. Membership rather than equality with `origin`: in a fork clone the pull
    request lives on `upstream`, so an origin-only anchor manufactures a *false* refusal — and a
    clone whose only GitHub remote is named `upstream` had no anchor at all. Both are ordinary
    layouts, and `docs/design-principles.md` §2 rules out hardcoding a remote *name* in a primitive
    shipped into projects the baseline has never seen.
  - **Reviewer identity is matched asymmetrically** (D18). Both modules stripped a trailing `[bot]`
    from the API login *and* from the declaration, which meant `bots = ["foo[bot]"]` was satisfied by
    a **human account literally named `foo`** — and reactions are publicly writable, so on the
    clean-pass signal the bar was a login collision and nothing else (`gh api
    users/gemini-code-assist` returns a real User account). The API login is now normalized *toward*
    the declaration and never the reverse: bare `foo` matches `foo` or `foo[bot]` (portable, the
    documented default), while `foo[bot]` matches only `foo[bot]`. A `user.type` filter cannot do
    this — the reactions endpoint reports `type: "User"` for the Codex connector itself.
  - Documented in `docs/roles-and-agents.md`, `base/roles.md` and `templates/agents.toml`, whose
    examples move to the bare spelling **for arming** — while stating plainly that the two consumers of
    this key do not share a safety property: `/resolve-pr-threads` matches the login *exactly*, so a
    bare entry resolves threads from whatever account bears it, human included. Its claim that the
    allowlist "can **never** match a human login" is corrected accordingly (two built-in defaults are
    bare; bounded to thread resolution, not merges; #208).
  - **A trailing slash hid the `.git` suffix from the repo-slug strip.** `owner/repo.git/` — a valid
    remote URL — reduced to `owner/repo.git`, a slug matching no real repository, so the shared anchor
    disagreed with the API's `owner/repo`. Pre-existing in `state-assert.sh`'s private copy since #138
    and inherited by the promotion, which is the argument for having one home: fixed once, for every
    caller.

- **The `/implement-issue` run marker is owned by a session, not by a checkout** (#180, D17).
  `implement-issue-gate.sh` decided whether the active-run marker was its own by comparing branch
  names — but a checkout is a **working-tree** property, so every session in one clone matched the
  **same** marker. Two live reproductions, an hour apart: a tracker-only session that had never run
  `/implement-issue` was instructed to `gh pr create` against another session's branch that
  *already had an open PR*, and the blocked-marker escape at the same keying meant one session's
  give-up would have ended another session's healthy run.
  - The marker and its blocked file now carry an **`owner`** — the id of the session that wrote
    them — and the gate compares it against its own session before reading the marker as its own.
    A foreign marker is left strictly alone: not acted on, not deleted, never overwritten. Identity
    is read env-first (`CLAUDE_CODE_SESSION_ID`) with the Stop-hook stdin payload's `session_id` as
    fallback, and that read is **bounded** — an open-but-silent pipe would otherwise burn the
    hook's 30s budget, and a hook killed by its timeout enforces nothing.
  - **Every absence picks a failure direction on purpose**, because the wrong pick is silent. An
    unowned marker (an install predating the field, or an agent whose harness has no session id),
    or a hook that cannot identify itself, falls back to the branch-name behaviour the gate always
    had: going inert would switch the no-stop-until-PR invariant **off** for those runs, and a
    false "mine" costs one misdirected hint where a false "not mine" costs the invariant. The
    **blocked file inverts this** and degrades *permissive* (owners compared only when both carry
    one) — a wrongly refused escape is an **unstoppable turn**. Ownership also **transfers**, so a
    resumed session reclaims its run at the next phase update instead of being locked out of it.
  - **No pid fallback**, despite the issue proposing `session_id` "falling back to pid": the writer
    is a tool-call shell and the hook a separate process, so neither derives the same pid and a pid
    would manufacture mismatches rather than resolve them. No id available → no `owner` key.
  - Also closes the **staleness** half. The marker is read **once** into a snapshot instead of
    through four separate `jq` calls (a concurrent delete used to hand back a half-read marker that
    still looked well-formed enough to nag about), and that snapshot is re-verified immediately
    before the hook speaks **and** before every `rm -f`. A marker that vanished or was replaced
    mid-hook now produces **silence**, and a replacement marker is never deleted. A failed branch
    lookup now reports that it *could not check* rather than asserting no PR exists
    (`verify-before-asserting.md` — #44 covered the completion direction, never this one).
  - **Hardened the marker parse, because the ownership decision is decoded by position.** The five
    fields arrive as newline-separated `jq` output and `owner` is **last**, so one embedded newline
    re-aims the ownership test: a `prUrl` carrying a warning line above the URL made a run's own
    marker look foreign (invariant off), and a newline in `branch` pushed `owner` off the end so a
    foreign marker read as unowned — the original defect, returning. A newline in a field that
    gates a decision now refuses the marker; one in `prUrl` (which gates nothing — the live lookup
    is authoritative) is dropped to empty so enforcement continues. The same pass restores the
    non-object rejection that folding `jq -e .` into the extract had silently dropped: a `null` or
    whitespace-only marker used to yield five empty fields, skip both the owner check and the branch
    guard, and nag about issue `#` on branch `` in **every** session in the checkout.
  - `live_pr` is keyed on `gh`'s **exit status**, not on whether it wrote to stderr. Keying on
    stderr looked equivalent and was not: a silent `gh` failure — and, worse, a temp file that could
    not be created, which made the `2>` redirection fail so `gh` never ran at all — both produced
    the confident "has not opened a PR yet". Its stderr capture also moved out of the repo into
    `TMPDIR`, since the repo directory is not guaranteed writable.
  - 48 new fixtures in `scripts/check-implement-gate.sh`, each mutation-verified against a
    deliberately broken gate. Every invocation is fed an explicit stdin and an explicit session
    identity, so the suite can neither block on an inherited terminal nor pass because of whoever
    happened to run it — and two properties that three prose passages claimed are now asserted: that
    the env var **wins** over a conflicting stdin payload, and that an stdin pipe which never closes
    cannot hang the hook past its bound.
  - **Scope is one active run plus unrelated sessions.** Two *concurrent* runs in one checkout
    still collide on the fixed state filenames before ownership can help — separating a live
    foreign marker from a dead one is liveness detection, and an owner-aware preflight without it
    would leave a crashed run's marker uncleanable. Tracked in #202.

- **`/roadmap` no longer drops a dependency edge that carries markdown emphasis** (#112).
  `roadmap-lib.sh deps-from-body` required the `#N` to sit directly after the keyword, so
  `Depends on **#52**`, `**Depends on:** #78`, `` Depends on `#52` `` and `- **Blocked by** #155`
  all declared **nothing** — while `- **Blocked by #155**` (the same bold, one character over)
  worked, which is why it survived three releases. A corpus scan of this repo's 91 open issue
  bodies found **six** real edges being dropped, four of them load-bearing.
  - This is the **under-match** mirror of #69, and the dangerous half of that family: an
    over-match blocks a bundle that is ready (visible, annoying), while a dropped edge marks a
    genuinely **blocked** bundle `ready` — so the skill emits work whose prerequisite is open.
  - The tolerance is not a blanket punctuation skip, which would trade one silent fabrication
    for another. Each emphasis run must sit **tight** against the keyword, the separator, or the
    `#`, and the `#` must still be reached without crossing a **word** character. So
    `*Blocked by* #5` declares while `Depends on * #5` does not, and `` Depends on `#5` ``
    declares while `` Depends on `ignore #5` `` and `Depends on **acme/repo#5**` do not.
  - Delimiter **pairing is deliberately not checked**. A first cut required an opener to reappear
    after the digits; it dropped `Depends on **#5, #6**` to `6` — the closer follows the *last*
    chain member, so the scan resumed inside text it had just rejected — and all it bought was
    refusing malformed markup whose edge is real anyway. A partial set is the worst outcome
    available: it reads as resolved while a prerequisite has silently vanished.
  - Every #69/#108/#117 guarantee is re-pinned **with** the new syntax: `Refs **#52**`, bare
    `**#52**` and `Depends on **acme/repo#5**` are still not edges; `no longer depends on **#25**`
    still retires; a formatted edge inside a fence, comment or blockquote still declares nothing.
    53 new fixtures in `scripts/check-roadmap.sh`, each labelled UNDER or OVER.
  - Still **not** covered, and stated so the next pass does not mistake them for regressions:
    emphasis inside the keyword (`Depends **on** #5`), markdown links, HTML emphasis, and a
    bolded connective (`Depends on #5 **and** #6` yields `5`). Tracked separately.

## [1.1.0] - 2026-07-28

The loop closes on itself. v1.0.0 shipped the practices, the workflows and the gates;
v1.1.0 makes the parts that *decide* — readiness, review, cleanup, edge extraction —
tested shell predicates instead of remembered prose, and stops the model paying for
waits a shell can do. `/implement-issue` no longer arms auto-merge before the declared
reviewer has spoken; `/resolve-pr-threads --watch` waits out the async reviewer for free;
release readiness verifies the default branch is actually green; `/cleanup` sees squash
and rebase merges; and `verify-before-asserting` gained a command that performs the read
and renders the sentence in one step.

### Added

- **Waiting for the async reviewer no longer costs model tokens** (#49). `/implement-issue` opens a
  PR and ends; the Codex connector reviews minutes later, usually after the session is gone, so the
  operator had to come back and run `/resolve-pr-threads` by hand. The waiting half of that loop is
  something a shell can do, and now does.
  - **`scripts/lib/pr-watch.sh`** — `observe --pr N` classifies once (`"<verdict> <head-sha>"` on
    stdout); `wait --pr N` polls until a terminal answer, bounded by `--interval`/`--max-secs`.
    The model is not in the loop, so a half-hour wait costs nothing.
  - **Three surfaces are read, because the reviewer has two output shapes and the repo does not
    choose which it gets.** Without a Codex Cloud environment the connector posts a review object
    (plus inline threads) for findings and a bare `+1` reaction for a clean pass — the contract it
    documents in every review body: *"If Codex has suggestions, it will comment; otherwise it will
    react with 👍."* **With** an environment it runs as a task and posts a **single issue comment**:
    no review, no threads, no reaction. Both shapes were observed on this repo *the same day*
    (PR #166 at 08:01 → review + 3 threads; PR #178 at 19:30 → one comment, zero reviews), so a
    detector reading only reviews would sit at `pending` **forever** on a repo configured the second
    way — the same wedge this exists to remove, reintroduced by a vendor-side setting nobody in the
    repo changed. Reviews are matched by head SHA; comments and reactions by timestamp. Findings
    outrank clean; a review at the head outranks a comment.
  - **`/resolve-pr-threads` no longer reports "nothing to do" on a task-mode review.** A `10`
    verdict now tells the caller to read the reviewer's latest issue comment first, because under
    that shape the comment *is* the review and there are zero threads to resolve — and to verify any
    commit such a comment claims to have made, which does not exist on the branch unless the
    reviewer has push access.
  - **The transient 👀 is deliberately not modelled.** The reactions API exposes only what exists
    *now*, never deletion history, so "👀 was here and then vanished" is knowable only to a watcher
    that happened to be looking across the transition — it cannot survive a restart, a resumed
    watch, or a late start. Polling for either *terminal* signal is restart-safe and idempotent.
  - **A reaction is not commit-scoped, and that is the one dangerous direction.** A `+1` left on an
    earlier head still sits there after new commits land; counting it would report a clean pass for
    code nobody reviewed. A `+1` therefore counts only when it postdates the head commit's
    committer date. Every unreadable path fails closed — never `clean`.
  - **`/resolve-pr-threads <PR#> --watch`** waits, then runs the existing resolve flow only when
    there are findings, exits quietly on a clean pass, and reports every other verdict. Without the
    flag the workflow behaves exactly as before. `/implement-issue`'s close-out offers this form of
    the resume hint on a code-16 skip.
  - **Known boundary, stated rather than implied:** this does not arm auto-merge (#168 — #49's own
    text says "never merges" while three docs expected it to arm; that contradiction is an owner
    decision, not an oversight), does not survive the session (#171, with tree isolation as #172),
    and does not trigger a re-review (#169 — the connector re-reviews on open / ready-for-review /
    an explicit `@codex review`, **not** on a push). Per-reviewer signal profiles are #170.
  - **A latent bug this surfaced, filed not fixed:** `pr-review.sh gate` reads only
    `pulls/N/reviews`, so a clean Codex pass — which posts no review — leaves it returning `16`
    ("awaiting review") forever, disabling unattended arming on the cleanest PRs. That is **#167**;
    fixing it changes when merges happen, so it did not ride along with a detector.

- **`verify-before-asserting` is now executable where it can be, and honest about where it cannot**
  (#138). The practice is one of the most explicit rules in the baseline, and it was violated twice
  in one session *with the practice loaded in context*: a merged PR narrated as open from a read 25
  minutes stale (which then shaped the plan — it pre-committed a sweep to preserving an
  already-deletable branch), and a close-out claiming an armed PR would wait on
  `required_conversation_resolution` when it merged 29 seconds later. Prose was the one option
  already known not to work, so the rule became a command — the same move that turned the
  dependency-edge rule, the release-readiness ladder and `/cleanup`'s predicates into tested code.
  - **`scripts/lib/state-assert.sh observe pr|issue <n>`** performs the authoritative read **and**
    renders the finished sentence in one call, so there is no window for the value to age between
    the read and the claim, and no paraphrase step in which an observation becomes a prediction.
    Callers pass the line through unchanged. A getter alone would not have fixed this: an agent can
    ignore a getter exactly as easily as a paragraph.
  - **Fail closed means empty stdout.** Every unverifiable path — no `gh`, read error, malformed
    JSON, a same-numbered PR in another repo, an unrecognized state — renders **no sentence** and
    exits non-zero. Silence is safe; a guessed status is the bug.
  - **`mergedAt` decides MERGED, not `state`.** GitHub reports a merged PR as `CLOSED`, so a
    state-only reading would have called the merged PR "closed without merging" — swapping one
    wrong sentence for another. `NOT_PLANNED` stays distinct from completed for the same reason: an
    abandoned issue is not a delivered one.
  - **Observations are past-tense by construction.** A read supports a claim about the moment it
    happened and nothing more, so `/implement-issue` now reports the guard's *observed* result
    ("review guard returned 16; auto-merge was not armed") instead of predicting what will hold.
  - **One home per entity kind, no second model:** PR/issue state here; "is this branch merged?"
    stays with `cleanup-lib.sh branch-verdict` (which already handles squash/rebase and exact-head
    matching); "is the branch green?" stays with `roadmap-lib.sh branch-health`.
  - **Scope is stated rather than overclaimed.** The enforceable guarantee covers the *defined*
    status outputs of `/cleanup`, `/implement-issue` and `/resolve-pr-threads`. Free-form prose is
    **not** mechanically enforced — a Stop hook fires after the text has already streamed, so it
    could only ever force a correction, and a shell classifier over arbitrary English would be
    theatre. Portable per-agent enforcement remains with the enforcement-hooks layer.
  - **Every read is pinned to the checkout's repo** with `--repo`, and the slug comes from `git
    remote`, not from `gh`: an unqualified read is redirected by the documented `GH_REPO` override,
    and the entity-kind and number guards both still pass, so a confident status was rendered for a
    *different project*. A `gh repo view` identity call could not have caught it either — that
    honors `GH_REPO` too and would simply have agreed with itself.
  - **The observation time is recorded after the read returns**, not before it starts. If the
    entity changes mid-flight, a pre-read stamp names an instant at which the reported state was
    demonstrably false.
  - **A `CLOSED` issue with no recognized `stateReason` is unverifiable**, never "completed" —
    inferring delivery from absent evidence is the exact false-delivery claim this prevents, and
    GitHub returns the field null for issues closed before it existed.
  - Regression-tested offline by **`scripts/check-state-assert.sh`** (67 assertions, `gh` stubbed
    on PATH), wired into `selfcheck.sh` and CI.

- **`/implement-issue` no longer arms auto-merge before the reviewer has spoken** (#134). PR #133
  merged **29 seconds** after opening and **six minutes before** the Codex connector posted five
  review threads — all five were real bugs, and they landed on `main` unreviewed.
  `required_conversation_resolution` did not fail; it was bypassed by timing, because it only
  blocks a merge on threads that **already exist**, and at arming time there are none. Auto-merge
  fires when the required *status checks* pass, and a bot reviewer is not a check, so the race was
  never winnable by tuning.
  - A second guard, **`scripts/lib/pr-review.sh gate --pr <n>`**, runs before the arm and answers
    the question repo settings cannot: *has every reviewer this repo declares reviewed **this head
    commit**?* Exit `0` (+ the witnessed SHA on stdout) · `16` a declared reviewer is still
    pending · `17` no `[reviewers] bots` declaration, so it is unknowable · `18` that declaration is
    malformed · `19` a reviewer requested changes · `20` unreadable. Every uncertainty is non-zero — the guard never degrades a failed
    read into "nobody is pending" — and each code carries its own remedy, the same one-code-per-fix
    rule `automerge-ok` follows.
  - It is a **separate module** on purpose: `repo-settings.sh` declares itself repo *settings*
    bookkeeping that "does not merge, review, tag, release, or deploy", and review state is
    per-PR. `automerge-ok` still answers *will the checks gate this?*; step 10 composes the two.
  - **`[reviewers] bots` now also gates the merge**, read as a tri-state through
    `role-dispatch.sh bots --declared`: declared → wait for them; `bots = []` → this repo has no
    async reviewer, keep unattended arming; **undeclared → fail closed**. The two readers differ
    only on *unset*, deliberately — a permissive default is harmless when picking which threads
    `/resolve-pr-threads` may resolve and is exactly wrong as a merge gate. Reviewers are
    **declared, never inferred** from PR history: absence of past evidence must never authorize
    an arm.
  - Either login spelling works. GitHub reports the same bot as `chatgpt-codex-connector` over
    GraphQL and `chatgpt-codex-connector[bot]` over REST, so the guard normalizes the suffix — an
    anchored exact match would silently never fire and wedge the gate at `16` forever.
  - The arm now passes **`--match-head-commit`**, so a commit pushed between the check and the arm
    makes GitHub reject the arm instead of merging an unreviewed tip.
  - **Expect this to skip arming on a bot-reviewed repo**, every time: step 10 runs seconds after
    the PR opens. Unattended *arming* is suspended there until **#49** adds the PR watch that
    waits, resolves threads, and arms afterwards. A repo with no async reviewer sets `bots = []`.
  - **A submitted review is not a satisfied one.** `APPROVED` and `COMMENTED` count —
    `COMMENTED` is what the Codex connector posts even on a clean pass, and holding out for an
    `APPROVED` it never sends would deadlock the gate. **`CHANGES_REQUESTED` does not** (`19`), and
    nothing else catches that: with `required_approving_review_count: 0` GitHub merges a PR whose
    only review says *do not merge*, and `required_conversation_resolution` gates on threads, not
    on the verdict. A standing rejection also outranks any other review the same reviewer left on
    the same commit, in either order. Reported by the reviewer on this feature's own PR.
  - **A declaration that only *looks* empty is now rejected, not obeyed.** `adb_toml_get` is
    line-based, so a perfectly valid multi-line TOML array (`bots = [` / `  "…",` / `]`) returned
    just `[` and parsed to zero elements — byte-identical to an intentional `bots = []`. The guard
    would have armed auto-merge on a repo that had just declared a reviewer. A wrapped array was
    the same bug one line later, silently dropping every element after the first. Both now fail
    with code `18` naming the cause, as does an array with no usable entries (`[""]`, `["[bot]"]`).
    Found by the adversarial review of this very PR.
  - Declare `bots` **per repo** where you can: the key layers repo → global, so a global
    declaration suspends unattended arming on every repo on the machine (safely, and overridable
    with a per-repo `bots = []`).
  - New `{{PR_REVIEW_LIB}}` placeholder (all three agents), `scripts/check-pr-review.sh` (57
    offline cases), a `pr-review` CI job and a `pr-review-guard` fact pin. Recorded as **D12**,
    which also records the two deliberate trades: enforcement is agent-side (GitHub has no
    primitive for "wait for a bot's COMMENTED review"), and the declaration's repo→global layering.

### Fixed

- **Neither library could ever recognize a GitHub Actions check run, because both attributed them
  to the wrong app** (#179). GitHub stamps `app.slug` = **`github-actions`**; the app's *owner*
  login is `github`, and that near-miss is what shipped — in two places, plus every fixture that
  was supposed to catch it.
  - **`branch-health` deadlocked the release gate.** With the Actions set always empty, the
    "active workflows exist but Actions has not reported" arm fired ahead of `green` on **every**
    repo whose CI is GitHub Actions. `/roadmap` therefore could not emit a cut once a milestone
    drained — the release-goal convention (#27/#71/#78) could not terminate. Caught live on this
    repo: `main` carried 26 successful Actions checks and read as `indeterminate`.
  - **`required-drift` had the same literal, but there it failed OPEN.** With
    `_adb_rs_actions_contexts` always empty, the contradiction detector never fired and the lint
    took its "external CI — nothing to require" pass instead. The check that exists to catch a
    gate that stopped gating was itself a gate that had stopped gating.
  - **Provenance is now tri-state.** `app` is required-but-*nullable* in GitHub's REST schema, so
    "not Actions" and "unattributable" are different answers. A required context whose producing
    app cannot be identified now fails closed (`20`) instead of passing as somebody else's CI.
  - **The value has one home** — `adb_actions_app_slug` in `common.sh` — passed to both jq
    programs as a typed `--arg`. Fixtures derive it from there rather than restating it, since
    fixtures that restate a constant are precisely what let this ship: they asserted the code's
    belief instead of the API's behavior, so the suite stayed green against a value GitHub never
    returns. One explicit API-contract test still pins the literal, and a drift guard in
    `check-common-lib.sh` fails if either consumer grows a copy again.

- **The `/roadmap` edge scanner missed markdown structure inside list items, escaped comment
  openers, and — worse — its own fixtures could not fail** (#135). Five findings from the codex
  review of PR #133, which merged before the review landed (#134); all five reproduced on `main`.
  - **A fenced block inside a list item was not a fence**, because the delimiter sits after the
    list marker. This failed **both ways at once**: the block's contents were scanned (fabricating
    an edge), and its indented closing fence was then read as a *new opener*, swallowing every
    genuine edge after the list to end-of-body. Putting an example in a list item is one of the
    most common shapes in a real issue. Fences and blockquotes are now recognized at the **content
    column**, and a closer may sit at any indentation — failing to close is the far worse error.
  - **A blockquote under a list marker** (`- > Depends on #6`) was scanned as prose.
  - **`\<!--` armed the cross-line comment state.** CommonMark renders an escaped `<` as text, so
    this is prose *displaying* the delimiter; such an illustrative marker rarely carries a `-->`,
    so it silently swallowed every edge and every recorded decision in the rest of the body.
  - **The fixtures could pass while the extractor crashed.** The test helpers ran the library
    inside `$( … )`, whose exit status is discarded once expanded as an argument — `pipefail` does
    not reach it. Most structure fixtures expect an empty result, so a crash on exactly those
    inputs still reported PASS. A nonzero exit is now converted to a value nothing can equal.
  - **Container context for fence closers.** A closer is matched relative to its *opener's*
    content column. Both directions bite: too strict and a list-nested closer never matches (the
    fence swallows the body); too loose — the first cut of this fix — and a 4-space-indented
    backtick run *inside* a top-level fence closes it early, after which the real closer reads as
    a fresh opener and eats every edge after the block.
  - **Marker padding is capped.** CommonMark treats 1–4 spaces after a list marker as padding; at
    five or more, only the first is, and the rest is content indentation — so `-     ` + a
    delimiter is an indented code line, not a fence.
  - **Ordered markers stop at nine digits**, per CommonMark. A tenth means the line is not a list
    at all, and reading it as one dropped a real edge from e.g. `1234567890. > Depends on #5`.
  - **Escaped comment openers are counted by parity.** Only an *odd* run of backslashes escapes
    `<!--`; with two, the first escapes the second and the opener is real, so treating it as prose
    scanned a genuine comment and fabricated an edge from its contents.
  - Multi-line code spans (the fifth finding) are tracked in #136 rather than fixed here: the
    streaming fix would mask to end-of-paragraph on a stray backtick, trading a rare fabricated
    edge for a common **dropped** one — the strictly more dangerous direction.

- **`/roadmap` invented dependency edges from issues that merely *documented* the keyword**
  (#117). `deps-from-body` scanned every line for `Depends on #N` / `Blocked by #N` with no notion
  of markup, so a repro block, a quoted excerpt or a schema comment was read as if the issue had
  declared the edge. Live on this tracker: #112's fenced `console` blocks fabricated a
  **#112 → #52** edge, marking a `ready` bundle `blocked` behind an issue it has no relationship
  with — and nothing in the artifact distinguishes a fabricated edge from a real one.
  - **Fixed as a class, not an instance.** This was the third variant of one bug family — #69 (a
    bare `#N` mention), #108 (a *negated* mention), #117 (a mention the author never asserted).
    The predicate now strips **fenced code blocks** (both ``` and `~~~`, info strings and longer
    runs recognized, the other delimiter never closing the current fence, an unterminated fence
    swallowing to end-of-body), **HTML comments** (inline and multi-line), and **blockquotes**
    before scanning.
  - **Inline code spans are handled by position, not by blanket stripping.** The *keyword* must
    sit outside a span; the `#N` reference may sit inside one. So `` `Depends on #78` `` (a quoted
    example) declares nothing, while `` Depends on `#52` `` keeps its reference visible — which is
    what keeps #112 implementable on top of this instead of in conflict with it.
  - **4-space indented blocks are deliberately *not* treated as code.** Under a `- ` bullet,
    content starts at column 2 and code needs 2+4=6, so a `^ {4}` skip would delete ordinary
    continuation prose and silently drop a *real* blocker. A dropped edge unblocks a genuinely
    blocked bundle, which is the more dangerous direction. Tracked separately.
  - Fence and span scanning are counted with `substr`/`index` rather than regex intervals:
    `{0,3}` is not honored by the BSD awk on macOS or older mawk, and an unmatched fence rule
    fails **open** — every fence would leak its contents back into the scan.
  - **`decisions` reads the same document, so it runs the same filter.** Two bugs lived there:
    a `| … |` row quoted in a fence was read as a recorded owner decision — retiring a question
    *nobody answered* — and a `#` line quoted in one ended the section early, hiding every real
    decision after it, which is **#108 returning by another route**. The artifact ships an HTML
    comment inside that very section, safe until now only because no line in it began with `|`.
  - **CRLF bodies.** A body submitted through the GitHub web UI is CRLF and `gh` passes it
    through verbatim, so a fence closer arrives as ``` ```\r ```. Its must-be-blank tail was not
    blank, the fence never closed, and every edge in the rest of the body disappeared. Lines are
    now normalized once, for every consumer. This repo's own issues are all API-authored LF,
    which is exactly why the fixtures could not have caught it.
  - `<!-->` / `<!--->` are empty comments in CommonMark (opener and closer share their dashes);
    they were parsed as *unterminated* openers and swallowed the rest of the body. A `<!--` in a
    fence **info string** no longer arms the cross-line comment state either — the fence starts
    first, so it wins.
  - 40 new fixtures in `scripts/check-roadmap.sh` pin the whole family, plus three drift guards
    that keep the rule stated in the workflow prose.

- **`/cleanup` was a permanent no-op on any squash-merging repo** (#106). It decided local-branch
  eligibility from `git branch --merged origin/<default>` plus `git branch -d`'s merged-only
  refusal — and a squash merge writes a *new* commit, so the branch tip is never an ancestor and
  **neither signal can ever fire**. The sweep reported "nothing to sweep" while stale branches
  piled up: the exact failure its own opening paragraph says it exists to prevent. Observed live
  in this repo, which merges with `gh pr merge --auto --squash`.
  - **A branch now counts as merged on either of two proofs**, each of which re-validates itself
    at the moment of deletion: the tip is an ancestor of `origin/<default>` (deleted with
    `git branch -d`, whose refusal *is* the re-check), or a **freshly-queried merged PR** whose
    `mergeCommit.oid` is contained in `origin/<default>` **and** whose `headRefOid` equals the
    local tip.
  - **That second condition is not in the issue, and it is the one that protects work.** Without
    it, a branch squash-merged and *then* given new local commits still matches and gets deleted.
  - **`git branch -D` is never used.** A rewritten-merge branch is removed with
    `git update-ref -d refs/heads/<b> <tip>` — an atomic compare-and-delete that fails if the
    branch moved between being classified and being deleted. `-D` deletes whatever is there
    *now*, on a decision made earlier.
  - **The guardrail was reworded, not deleted.** It forbade PR status outright, which is what
    left the skill with no detector at all; it now forbids *stale* status. A status queried live
    in this run and then proved by local ancestry is not the thing it was protecting against.
  - **A repo with no `gh` or no remote behaves exactly as before** — fast-forward detection only.
    A repo that *has* `gh` and whose query *fails* is reported `UNVERIFIED` and preserved, never
    silently downgraded to "not merged".

### Added

- **`/cleanup` sweeps resolved run-state, and reports tersely** (#84). It cleaned only git
  branches, so `{{STATE_DIR}}` accumulated indefinitely — 12 thread caches for long-merged PRs
  and a 428 KB captured-stderr log were sitting there when this shipped — and it narrated itself,
  emitting ~15 lines (including a `(0)` section and two paragraphs about its own re-fetch
  discipline) for a run that deleted one branch.
  - **Thread caches for closed/merged PRs, run markers whose branch is gone, and finished runs'
    gap artifacts are now swept.** Liveness comes from a live PR read or a freshly-fetched ref —
    **never file mtime** — and every unknown fails closed to *keep*.
  - **State for an OPEN PR or an in-flight run is never touched.** An open PR outranks branch
    absence, because a branch is often tidied while its run is still live; deleting that marker
    would silently disarm `/implement-issue`'s continuation gate.
  - **A new `gap-analysis.lock`** closes the one window the markers cannot cover: gap analysis
    runs *before* the branch and marker exist, so without it a live pass's artifacts read as a
    finished run's leftovers and were eligible for deletion mid-write.
  - **Anything the scan cannot classify is `other`, and `other` is never deleted.**
  - **Terse output contract:** one line per category that actually changed plus a truthful final
    state line, target ≤3 lines. Empty categories cannot be printed — the report is built from
    records, so there is no zero-section to suppress. Guardrail hits, refusals, unverified
    branches and anything left behind still report in full.
  - The **final state line is derived from `adb_clone_status`**, so a dirty tree, a failed
    fast-forward, divergence or a detached HEAD is stated rather than papered over with
    "clean, in sync" — which, under a ≤3-line contract, is the only state the operator sees.
  - Bounding a **single** dispatch's captured stream is split out as #123: every safe place to
    do it is inside `role-dispatch.sh`, and the obvious implementations regress the #93 reap/rc
    hardening.
- **`scripts/lib/cleanup-lib.sh`** — the one home for those decisions (`branch-verdict`,
  `state-scan`, `state-verdict`, `report`, `state-line`), following the `roadmap-lib.sh`
  precedent so they are executable and regression-tested rather than re-derived from prose each
  run. It never calls `gh`; the workflow owns every live read. Covered by
  `scripts/check-cleanup.sh` (87 assertions, offline, real squash-merge git fixture) in both
  `selfcheck.sh` and CI.
- **`{{CLEANUP_LIB}}`** joins the neutral workflow placeholder vocabulary, and the table in
  `base/workflows/README.md` gains the `{{REPO_SETTINGS_LIB}}` row it was missing.

- **The installed baseline now keeps itself current** (#36). Payloads are symlinks into one
  clone, so when that clone lags `origin` every project on the machine silently runs stale
  skills, practices, and gates — and forgetting the manual `baseline update` does not fail
  loudly. It bit exactly that way: the operator's clone sat one commit behind while `/roadmap`
  computed a release verdict with the *pre-fix* logic, minutes after shipping the fix.
  - **Two triggers, one shared policy** (#36, #139). Both read the same configuration and the same
    library (`scripts/lib/currency-lib.sh`); they differ only in when they fire and in what they
    consider worth reporting.
  - **A Claude `SessionStart` hook** (`session-currency.sh`, wired by `install.sh`) fast-forwards
    the install-source and re-runs the idempotent install, then reports **one line or nothing**.
  - **The hook acts only on `source: startup`.** `/clear`, `/compact`, `resume` and `fork` all
    happen with work in flight; swapping tooling underneath them is the mid-session surprise this
    avoids.
  - **The last step of `/cleanup` is the second trigger** (#139), on **all three agents**. The
    `startup`-only matcher left the baseline's own loop uncovered: `/implement-issue → merge →
    /cleanup → /clear → /roadmap` never re-checked, while staleness *begins* at the merge. It bit
    exactly that way a second time — an install two commits behind meant `/roadmap` would have
    re-derived the very dependency edges #117 had just deleted. `/cleanup` runs right after the
    merge and right before the `/clear` the hook skips, and being agent-neutral it is the **only**
    currency Codex and Gemini get at all.
  - **`/cleanup` ignores the rate-limit interval** (while still refreshing the shared stamp). The
    stamp cannot distinguish "startup just checked" from "startup checked, then a merge landed", so
    honoring it would suppress the check at exactly the moment it matters. See decision **D11**.
  - **The two triggers report differently, on purpose.** The unattended hook stays silent about a
    peer update or an unreachable remote; `/cleanup` reports both, because there you asked for it.
  - **It never updates the clone your session is working in** — the two-clone dev split, enforced
    from the hook side by comparing git roots (a session in a *subdirectory* still counts). A
    session in any other project still updates it.
  - **It always exits 0.** A SessionStart hook cannot block a session, but a non-zero exit renders
    an error notice on every start; currency must never be the reason a session looks broken.
  - **Configured globally, and only globally:** `[updates] session_start = "auto" | "notify" |
    "off"` in `~/.config/ai-dev-baseline/agents.toml` (`ADB_SESSION_UPDATE` overrides one run;
    `ADB_SESSION_UPDATE_INTERVAL_SECS` bounds the 10-minute rate limit). A **project's**
    `agents.toml` is ignored on purpose — see decisions **D10** and **D11**, which record the
    trust consequence of defaulting to `auto` and why one key now governs both triggers. `off`
    disables **both**. The key keeps its now-inaccurate name for backward compatibility (a key that
    silently stopped applying would re-enable an updater someone had switched off); the rename is
    tracked in #140.
  - **Upgrading:** neither trigger can bootstrap itself, so run `baseline update` (or
    `./install.sh`) **once** by hand after pulling this change. The hook can only wire itself by
    being installed, and your installed `/cleanup` is a symlink into the still-old clone — its
    silence looks exactly like "already current".
  - **`--no-hooks` no longer means "no currency".** Such an install opts out of the `SessionStart`
    hook only; `/cleanup` still carries the second trigger, since it is a workflow step rather than
    a hook. Set `[updates] session_start = "off"` to disable **both**.

### Changed

- **`baseline update` classifies unsafe clone state before touching the network** (#36). A dirty /
  mid-rebase / detached / non-default clone was going to be refused regardless, so asking `origin`
  first was pure cost — and not side-effect-free either, since `git fetch` writes remote-tracking
  refs that `--check` documents itself as never doing. A session started from an unsafe clone now
  pays no network round trip.
- **A new `in-progress` clone state** (#36) covers a merge / rebase / cherry-pick / revert /
  bisect. A clean working tree is not proof of safety — a rebase between steps and a bisect both
  leave one, and only some of them detach `HEAD`. Reported by `--check` as exit `20`.
- **The mutating `baseline update` path takes a per-clone lock** (#36), exiting `5` when another
  update holds it. Concurrent updates became ordinary the moment a SessionStart hook could start
  several at once. A lock left by a killed updater goes stale after 10 minutes and is broken.
- **Hook wiring is driven by `settings.hooks.json`'s own event keys**, not a hardcoded `Stop`, and
  `uninstall.sh` mirrors it across every event. Your own hooks under the same events are preserved
  by both. `wire_hooks()` also no longer reports success when `jq` failed or the settings file was
  unwritable — a broken `settings.json` was being claimed as wired, i.e. enforcement silently off.

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

[Unreleased]: https://github.com/BWBama85/ai-dev-baseline/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/BWBama85/ai-dev-baseline/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BWBama85/ai-dev-baseline/releases/tag/v1.0.0
