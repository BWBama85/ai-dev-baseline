# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is by git tag. Because
installs are symlinks, changes on `main` reach a user's clone on their next
`git pull` — keep `main` releasable.

## [Unreleased]

### Added

- **One source can now render a different instruction DENSITY to each agent — and nothing else
  differently (#304).**

  The framework dispatches roles to two models whose vendors publish opposite guidance on
  verification prompting: Anthropic's Opus 5 guidance asks that explicit verification scaffolding
  be *removed* from Claude's instructions (it self-corrects natively and over-verifies when told
  to); OpenAI's asks Codex for exactly the named-checklist, required-vs-optional pass. `build.sh`
  had nowhere to put that. `render()` took `(outfile, title)` and concatenated every practice
  unconditionally, and the skill renderer's per-agent map is `{{TOKEN}}` → string substitution,
  which cannot omit a paragraph. So one instruction set went to both models, wrong for at least
  one of them, in every project that installs the baseline.

  **The mechanism.** `block_filter` resolves `<!-- adb:except claude -->` … `<!-- adb:end -->` on
  **both** render paths — the root-doc `render()`, which now takes the agent token its call sites
  already named, and the skill `render_agent_skill()`. Exclusion-only, deliberately: a fourth
  agent *inherits* every block (today's density, unchanged) rather than silently receiving the
  most stripped-down render, and `docs/adding-an-agent.md` asks that adder to choose and say so.

  Every malformed spelling fails the build, and three conditions that used to be tolerated now do
  too: an unknown **target** agent (so a typo in a `render` call fails instead of quietly rendering
  full density), a source with **no final newline** (`cat` reproduced its absence and awk cannot,
  so the documented rule is enforced rather than silently repaired), and a marker inside a skill's
  **frontmatter**. A misspelled *keyword* matches no rule at all, so both renderers additionally
  refuse — through one shared guard — to publish output carrying a surviving `<!-- adb:`.

  **What actually changed for readers.** Claude's root doc and `implement-issue` skill drop the
  "mandatory gate, not a victory lap" exhortation and the enumerated `What to look for` checklist.
  The Codex and Gemini **root docs are byte-identical to before** — the block wraps the existing
  paragraphs rather than rewording them, so the density change is visible in exactly one of the
  three. All three `implement-issue` skills do change: Claude's for the block, and all three for
  the two edits that are shared by design — a reflowed self-review sentence, and the fallback
  removal below.

  **The *step* is untouched for everyone.**
  #304 asks both that Claude "drop the standing instruction to verify" and that renders "never
  differ in what they do", which read literally contradict, and the invariant wins: step 9 triages
  self-review findings and the PR body reports them, so removing the step would be a different
  procedure rather than a lighter one. Also removed, in every restatement: the review completion
  contract's fallback to a subagent of the driving agent — reachable only when that agent wrote
  the diff, i.e. the model grading its own work. Cross-model fallbacks stay. Decision **D67**.

  **`scripts/check-agent-blocks.sh`** pins it, because `build-drift` structurally cannot: it
  agrees with whatever was committed, so a facility that varies nothing and a shared paragraph
  reworded in one render only both look like a clean build. Three hand-written oracle sources make
  "differs there, byte-identical everywhere else" a `cmp` on both paths, and five mutations of a
  copied `build.sh` are each required to make a named assertion go red. It found two bugs in this
  change's own guards during that exercise.

- **#335 lands as option 3 (accept the cost, fix the docs): neither reading of "parallelise it"
  made `selfcheck` faster (#335).**

  `CLAUDE.md` golden rule 3 told every contributor and every agent that the mandatory pre-push gate
  cost **66-72s**. Eight full runs on the maintainer's 10-core macOS machine spanned
  **8m46s to 12m55s** — an order of magnitude out, and the spread itself is part of the answer.
  The old figure was not careless: D37 measured it correctly on 2026-08-03, against a **39-step**
  registry. The registry is **49** steps now, and the one that dominates it did not exist then.

  **Measured first, and the measurement refused the obvious fix.** `adopt-readiness-mutation` is
  **493s of the 526s wall — 94% of the critical path** — and 1115 of the suite's 2546 CPU-seconds.
  It runs `check-adopt-readiness.sh` in full once per injected defect, 38 times, through a pool
  that was hardcoded at 4. Widening that pool is what the issue proposed, so it was tried:

  | inner pool | wall | CPU (user + sys) |
  |---|---|---|
  | 4 | 328s | 1115s |
  | 8 | 299s | 1627s |

  **Nine percent of wall clock for 46% more CPU.** The step is syscall-bound — `sys` exceeds `user`
  throughout — so more workers mostly buy contention. The width stays 4.

  What was actually costing 165s: the box ran **48% utilised** while that step got 2.26 cores out
  of the 4 it nominally held, because `selfcheck` dispatched 8 step slots *and* two of those steps
  forked pools of their own on top. `--jobs N` bounded a number nobody cared about.

  - **A machine-wide process budget was built, measured, and is NOT shipped.** `selfcheck`'s
    `min(cpu, 8)` bounds STEPS, and three of them run pools of their own — so `--jobs N` bounds a
    number nobody cares about. The obvious fix is to bound processes instead: each pooled step
    declares a width, the pool admits by summed width, each worker is handed its slice. That was
    built in full, guarded by five negative cases against a copied runner, and then measured:

    | configuration | wall | CPU | critical step |
    |---|---|---|---|
    | **shipped** (no leaf bound) | **526s** | 2546s | 493s |
    | leaf budget 8 | 705s | 2904s | 587s |
    | leaf budget 16, width 4 | 603s | 2787s | 552s |
    | leaf budget 16, width 8 | 591s | 3090s | 521s |
    | leaf budget 16 + breadth cap 8 | 692s | 3172s | 628s |
    | leaf budget 20 | 724s, **`selfcheck-guard` went red** | 3214s | 695s |

    **Not one configuration beat leaving it alone** — and the stronger finding is that this
    machine could not measure the difference. Trees with small functional differences produced
    **526s, 583s and 775s**, and two runs with *different* inner pool widths reported CPU totals
    within 0.1% of each other when the standalone numbers predicted a ~500s gap. The table is a
    record of what was observed, **not a ranking**; treating it as one is the mistake this entry
    exists to prevent.

    What did survive the noise is qualitative: collapsing "steps in flight" into "leaf workers"
    doubles the breadth, and that took `shellcheck` from **57s to 270s** and timed the cancellation
    assertions out — a step change rather than a few percent. So the budget is reverted, the
    reasons it looked right are in D66, and `--jobs N` still bounds steps rather than processes.

    `ADB_POOL_JOBS` survives as an override on `adb_pool_size` — the seam that lets the sizing be
    tested, and the only way an operator on a shared machine can ask these harnesses for a smaller
    pool. **Nothing exports it**; the hand-down went with the revert.
  - **A third harness is pooled, because this change broke it.** `check-common-lib.sh
    --mutation` ran its mutations one at a time against a *shared* tree copy, rewriting one
    `common.sh` in place — which is exactly why it could not be parallel. Adding the six rows the
    new primitive needs took it from **323s to 596s** and made it the critical path: a fix that
    traded one long pole for another, caught by measuring the result rather than assuming it. Each mutation now owns its copy, as the two siblings already
    did — and the step is **128s standalone** for 14 mutations, against 596s for the serial
    version's 14 and 323s for its original 8.
  - **The harness's width is `min(cpu, 4)`.** On a 10-core workstation it spells the same `4` the
    constant did; on the 3-core `macos-latest` runner, where the constant forked *more* workers
    than the machine has cores, it gives **3**. Two honest caveats: fewer workers there **may cost
    wall clock** — a real trade against over-forking a 3-core box, not a free win, and not
    benchmarked here because CI timing is #339's subject; and `ADB_POOL_JOBS` can now shrink this
    pool on any machine, which is a second behavioural change and a deliberate seam. No claim is
    made that 4 is optimal.
  - **`min(cpu, 8)` moves to `scripts/lib/common.sh`, on the instruction that was already there.**
    `selfcheck.sh`'s comment read *"deliberately NOT promoted: it has one consumer — if a second
    appears, promote it then."* Two appeared, and the third spelling — `check-adopt-readiness.sh`'s
    — got the number wrong: 4 is half a workstation's usable width and a third more than the 3-core
    `macos-latest` runner has. `adb_cpu_count` / `adb_pool_size` are the one home, below the 5.3
    floor and verified under a real `/bin/bash` 3.2.57.
  - **Two defects in the harness itself**, both surfaced by the gap-analysis pass. Its
    `wait -n 2>/dev/null || wait` fallback waited for **every** child while decrementing the
    counter once — 5s against the correct 2s on an 8-worker fixture at pool 4, a silent degrade
    toward serial. And its verdict matched the recursive suite's `FAIL:` **string** while throwing
    the exit status away, so *"38 observed RED"* was a claim about what a child printed. It now
    requires exactly exit 1 **and** that mutation's own witness, and reports the pool it used.

  **What is enforceable about the number, stated narrowly.** Nothing offline can re-measure a wall
  clock, so no lint can tell you the figure has aged. What went wrong was cheaper than that: it was
  restated in **seven** files and went stale in all of them together. Five of those restatements
  are deleted in favour of "minutes, not seconds" and a pointer; `check-fact-drift.sh` pins the
  live value across the two that remain and refuses the retired one in all seven — in **three**
  spellings, because the real ones differed (ASCII hyphen, en-dash, and a bare `66s`), and the
  en-dash is why the first grep for this figure found five of seven sites. Golden rule 3's
  hand-copied step list is gone for the same reason: it named 29 of 49, and `--list` cannot go
  stale.

  Deliberately **not** here: #339 (the same step running on both CI legs) and #297 (a hanging gate
  is unattributable). Both are tracked, neither blocks this.

- **The below-floor carve-out is enforced by NAME, not just by parse (#315).**

  #310 shipped `--sub-floor` and stated its own gap in its header: D30 forbids **five** constructs
  in the three files that must run on an old interpreter, and only `${ command; }` was checked. The
  other four — `mapfile`/`readarray`, associative arrays, namerefs, `readlink -f` — were invisible
  to both existing rules **inside a function body**, because bash 3.2 parses all four there and
  loading a file never runs a body.

  Measured against a real `/bin/bash` 3.2.57 rather than assumed, and the measurement is the reason
  this matters: **none of them stops the shell.**

  | construct in a function body | 3.2 `bash -n` | 3.2 at call time |
  |---|---|---|
  | `mapfile -t a` | accepts | `command not found` (status 127), array left empty |
  | `declare -A m; m[x]=1` | accepts | `invalid option` (status 2), then writes index 0 of an *indexed* array — so the value reads back correctly by accident |
  | `local -n r=$1` | accepts | `invalid option` (status 2), ref empty |
  | `readlink -f` | accepts | works on current macOS; D30 carries it as a coreutils rule, not a bash-version one |

  The builtins do report a failure — and nothing reads it. These files set no `set -e`, so the
  function runs on past it with the wrong data and the script still exits 0. `adb_require_bash`'s
  repair path could therefore silently compute the wrong answer on exactly the hosts it exists for,
  while every CI job stayed green — both runners launch at or above the floor, which
  is precisely the situation the gate is for.

  **Rule C** closes it: a source scan by name over the **whole** of all three files, function bodies
  included. It needs no interpreter, so unlike the parse and the probe it runs on every host and in
  every job rather than only where an old bash exists.

  - **Whole-file, not the issue's gate call-path.** A hand-declared function list is the second copy
    D54 removed, one level down. Whole-file needs no declaration and is already what these files say
    about themselves — `common.sh`'s header states the ban for the file, and `check-lib.sh` says its
    own `check_enumerated` "must stay evaluable on bash 3.2 (D35), which has no namerefs" about a
    helper that is not on the observer's path. Measured cost of the wider scope: **zero**.
  - **The one false positive is MARKED, never deleted or pattern-loosened.** The entry-point lint's
    stdin-consumer regex spells `mapfile|readarray` as data; requiring command position does not
    help, because the `|` alternation puts each word in command position for any line matcher. The
    escape is the per-line `# adb-allow: sub-floor-<class>` marker `check-fact-drift.sh` already
    uses for `req_absent`, inheriting its constraint: **per line, never per file.**
  - **The marker names the class**, so it cannot over-sanction: a line exempt from the `mapfile`
    rule still goes red the moment a `declare -A` is added to it.

  **Both source scans now read LOGICAL lines, which fixed a pre-existing fail-open in rule A.**
  Self-review asked whether a construct could escape across a line continuation, and it could — in
  *both* scans. Measured rather than argued: a real bash 5.3 expands

  ```sh
  X=$\
  { printf hi; }
  ```

  to `hi`, and rule A reported the file clean. A backslash-newline is a line *splice* in shell, so
  both scans now splice before matching, through one shared fragment. The backslash is **removed,
  not replaced by a space** — a space would silently reintroduce the hole for that exact input
  (`X=$ {` matches nothing) — and the run of trailing backslashes is **counted**, because an even
  run is an escaped backslash that does *not* continue the line. Getting that second one wrong is
  not cosmetic: it merges two independent statements, so a marker on the later one silently
  sanctions a construct on the earlier. The splice also makes both patterns stronger — a
  continuation splitting a *word* (`map\` + `file -t`) is rejoined and then caught.

  Twelve mutations of the shipped rules were each applied to a tree copy and each observed making
  the guard suite go red, plus a thirteenth inside the suite that neutralizes rule C's own
  `check_fail` in a lint copy and requires the identical input to pass while still printing the
  finding — the silent-guard shape, demonstrated rather than asserted.

  The PR review found three more, each reproduced against a real bash before being fixed: a `#` that
  does not begin a comment (`: x# adb-allow: …` — `x#` is an ordinary word) sanctioned a construct
  beside it; a comment opened right after a control operator (`};# note \`) was invisible to the
  splice probe, which then joined the next line on so *its* marker exempted the declaration above;
  and bash's declaration builtins accept `+` options, so `declare +x -A m` and `local +x -n r=m`
  passed. Both comment sites now use bash's own word-start rule rather than a whitespace heuristic.
  The final option stays `-`-only on purpose: `+A` and `+n` *remove* the attribute, so matching them
  would flag a line that creates no hazard.

  The independent review found four live bypasses in the first cut and every one is fixed with its
  own fixture: separated option clusters (`declare -g -A m`) escaped a pattern that only ever read
  the first option word; a quoted copy of the marker text laundered a real construct, because the
  exemption was a bare substring test rather than the documented trailing comment; a backslash
  ending a *trailing* comment spliced the next line onto a statement that had already ended; and
  the `readlink` rule refused every option — including the portable `-n` — instead of D30's
  canonicalize family. It also corrected the measured statuses above, which an earlier draft
  reported as `0` by reading the script's exit status rather than the builtin's.

  What is still **not** proved, stated rather than implied: a name scan bans five *named*
  constructs, so an unnamed post-3.2 feature is invisible to it. `CLAUDE.md`, `CONTRIBUTING.md` and
  the mode's own header now say that narrower thing instead of the wider claim they used to, and
  D54 is amended rather than rewritten.

- **`baseline repo reconcile` — the drift detector finally has a repair (#333).**

  `required-drift` has detected a newly added CI job staying non-required since #122, and it works:
  it fired correctly, twice, and named the job. Nothing consumed the report. `6499dfe` added the
  `adopt` job and `main` then declared 27 required contexts against 28 discovered jobs for **~21
  hours**, during which PRs #329 and #330 both merged gated by a check set that did not include
  `adopt` — the exact hole #122 exists to close, reopened because a signal is not a repair.

  **#333's own preferred fix was refuted rather than built.** Its option 2 assumed the CI step
  "already holds admin permission in CI". It does not: `ci.yml` grants `contents: read`, no workflow
  references a secret, and `administration` is not a grantable workflow permission — so
  `PATCH …/required_status_checks` is impossible from `GITHUB_TOKEN` without an admin PAT or App key
  stored in CI. That is a security decision, so it went to the owner instead of being taken, and the
  repair now runs where admin rights already exist: a local workflow run.

  `/implement-issue` preflight calls it right after the post-merge auto-sync — the first moment the
  repair is both legal and credentialed — and treats every exit code as non-fatal.

  These properties make an unattended branch-protection write defensible, and each is pinned by a
  test **observed going red** when its rule is deleted:

  - **Opt-in, default off.** `[repo] reconcile-required-checks`, read from the repo's own
    `agents.toml` and never the global one, checked *before any network call*. Only the bare TOML
    boolean `true` enables it — the string `"true"` does not.
  - **The tree must BE the default-branch tip.** `HEAD` must equal the branch's *remote* tip **and**
    the workflow directory must be clean, because the commit is not the tree: discovery reads
    working files, so an uncommitted workflow would require a context that exists on no branch.
    Re-proved immediately before the write, since the branch can advance while the run prepares.
  - **Additions only, and not redirectable.** `--prune` is refused by name; so are `--branch` and
    `--workflow-dir`, which would move the target or the discovery source off the gated tree. An
    unprotected branch is refused too — standing protection up writes PR-review policy, not just
    contexts.
  - **Verified by re-reading**, against the whole intended set rather than only the additions, so a
    write that adds the new jobs and drops a preserved external context is caught.

  **What this does not do, said plainly:** nothing fires at merge time, so #333's literal criterion
  ("reconcile with no human command") is not met and was not faked. The drift's lifetime drops from
  "until a human reads a red check" to "until the next entry into the loop" — an improvement, not a
  time bound, since nothing schedules that next run. See D63.

  A second independent review pass found four more ways to write unsafely, all fixed: the repository
  `gh` resolves is now required to be the checkout's own (`$GH_REPO`, or a fork sharing the upstream
  tip, could otherwise redirect the write); a **symlinked** workflow path is refused (git reports a
  committed link as clean while discovery reads its target); `strict` is seeded from the live value
  so adding a context cannot silently switch off "require branches to be up to date"; and a
  required-set that changes mid-run aborts, because the complete-array PATCH would delete whatever
  was added concurrently — which the subset read-back could never notice.

  Thirteen mutations pin the rules, including one that deletes the preflight **call** — the only one
  that reproduces #333's actual failure, a detector nothing consumes. The exercise earned its keep twice
  over: the mutant copy was first written to a bare temp dir, where `repo-settings.sh` cannot find
  `common.sh` beside it and exits 1 having run nothing, so every assertion passed because `1 != 16`;
  and four witnesses were merely "not the expected code", which any incidental failure satisfies.
  Neither was visible from a green run — both surfaced only by neutering the mutator and checking the
  assertions went red, which they did not.

### Fixed

- **A `$HOME` containing a tab or newline made the installer move a real directory into backup and
  symlink over it — and every consumer discarded the status that said so** (#324, D64).

  `adb_agent_manifest` emitted `<src>TAB<dest>` with both paths unescaped. A newline in `$HOME` does
  not produce a record a reader rejects; it produces **two** records, and the first one's `<dest>` is
  a *shorter path that frequently exists*. Reproduced against the real primitives: with
  `$HOME` = `<dir><NL>shadow`, `adb_link_manifest` moved `<dir>` — a real directory holding real
  content — into the backup tree, replaced it with a symlink, and *then* returned non-zero. The
  status was never wrong. It was too late to matter.

  D59 declined to fix this inside #278 and named the obstacle exactly: the consumers parse three
  different ways and all of them swallow the producer's status inside a heredoc command
  substitution, so `return 1` alone changes nothing.

  - **The producer refuses atomically.** An unrepresentable `<repo>`, `<home>`, or skill directory
    name yields **no records at all**, one stderr line *per offending value*, and a non-zero status.
    Deliberately *not* `adb_repo_shape`'s `warning` record: that function's consumer branches on a
    named field, while this one **links** every record it reads.
  - **The status is now captured at nine call sites** — `install.sh`, `uninstall.sh`, each adapter's
    install *and* uninstall arm (four), `bin/baseline` (twice), and `scripts/lib/adopt-lib.sh`.
    **Two of those the issue's own inventory missed, and they fail worst.** `bin/baseline` swallowed it twice over — a pipeline
    reporting `cut`'s status, then a heredoc around the function that wrapped it — so a refused
    enumeration became an empty destination list, a verify loop that ran zero times, and a return of
    **0**: *healthy*, asserted about an install nothing had looked at. In `adopt-lib.sh` an empty
    shipped set does not read as an error to `classify`; it reads as "the baseline ships nothing",
    which makes every artifact in a scanned project look project-specific.
  - **`adb_link_manifest` validates the whole manifest before the first link**, and
    `adb_unlink_manifest` gained the mirror pass plus an explicit, defined return contract (it always
    returned *something* — whatever its loop last evaluated; now it returns non-zero iff the manifest
    was malformed).
    The refusal is **not** in `adb_link`, which #324 proposed: by then the record has already been
    split, so it receives two safe-looking fragments and cannot see that anything happened. A
    missing source stays per-record, as it always was.
  - **An entry-local fault is still entry-local.** A missing source links the good entries and
    reports the bad one, exactly as before — that contract is pinned, and only *representability*
    faults refuse the whole map.
  - **An install made from an unrepresentable pair is unsupported, loudly.** Its links are at
    truncated paths, so there is no correct removal set: `uninstall.sh` removes nothing, says so,
    prints the backup directory, and no longer reports "Uninstalled" over a failure.
  - **The guards are observed failing by a STANDING harness, not a one-time claim.**
    `check-common-lib.sh --mutation` injects each of the **eight** primitive rules with its own
    defect and requires the suite to go red *on that rule's own named witness* — red for the wrong
    reason is not evidence. Its applied-check is `cmp` against a pristine copy, because the failure
    that actually bit during development was a mutation whose pattern silently matched nothing: the
    suite came back green and reported the guard observed while checking nothing. The three
    consumer-level mutations (restoring each swallowing heredoc in `install.sh`, `bin/baseline` and
    `adopt-lib.sh`) were verified once by hand and are **not** in the harness; the end-to-end tests
    are what stand in for them.
  - **The decisive mutation leaves the exit status correct.** Neutering only the pre-write pass —
    so it still buffers, still diagnoses, still returns non-zero — turns three assertions red and
    the status assertion is **not** among them. That is why every fixture checks the filesystem
    (`cmp`-identical content, no backup, no link), and the harness pins it: delete those filesystem
    assertions and that mutation stops going red, which the harness reports.
  - **What this does not cover, said in the code rather than implied:** a clone directory whose name
    *ends* in a newline is truncated by the top-level entry points' own `$(cd … && pwd)` bootstrap
    before the producer is reached (the adapters resolve `agents/<token>`, so the newline is
    *internal* to them and IS refused — but they are handed an already-truncated root by
    `install.sh`, so an ordinary install is still affected). `$HOME` and every *internal* delimiter do reach it and are refused. Filed
    as #343 rather than folded in — it needs either 20 duplicated lines or a shared bootstrap
    primitive with a chicken-and-egg, which is a second cross-library decision.

- **`/adopt`'s mutation harness reported a false negative once its subject's output outgrew the pipe
  buffer** (#324).

  `check-adopt.sh --mutation` decided each verdict with `printf '%s' "$out" | grep -Fq -- "$witness"`,
  in a file that sets `pipefail`. `grep -q` exits the instant it matches, closing the pipe while
  `printf` still has the rest of a large `$out` queued; `printf` dies of **SIGPIPE**, and `pipefail`
  promotes that to the pipeline's status. So the check returned non-zero for exactly the outputs where
  the witness *was* found — and the harness then blamed the suite, reporting "went red, but NOT on its
  witness" about a mutation whose witness was sitting in `$out`.

  Measured: a 348906-byte buffer with the witness on line 1 gives **rc=141** under `pipefail` and
  **rc=0** without it. Latent rather than new — it needs `$out` to outgrow the 64 KiB pipe buffer with
  an early match, which is why it surfaced only when this release grew the adopt suite's output, and
  only on CI's Linux runner. Both checks now match with `case`: no second process, no pipe, no signal,
  and nothing for `pipefail` to promote.

  It is worth its own entry because of the *direction* it failed in: a guard that accuses the code it
  is checking, rather than itself, is the kind of red a reader fixes in the wrong place.

- **The shipped global Stop-hook gate exited 1 — a non-blocking notice — instead of its blocking 2,
  whenever `common.sh` carried a top-level unbound expansion (#317).**

  `agents/claude/scripts/precommit-gate.sh` sets `set -u` and then sources its shared library twice:
  the conditional bash-floor bootstrap, and `require_lib`. An unbound expansion at a library's **top
  level** is fatal under `set -u` — it kills the shell outright — so the gate exited **1** and
  `require_lib`'s `fail_loud` never ran. **Exit 1 from a Stop hook is a non-blocking error notice**,
  so the turn ended *ungated* while looking like a hook glitch: the "enforcement secretly off"
  inversion #35 exists to prevent, arriving through the one door `fail_loud` cannot cover, because
  no `||` catches it — the shell is gone before the next word is read. #299 repaired exactly this in
  this repo's *own* project gate and put the shipped one out of scope; this is that repair, applied
  where it reaches every adopting repo.

  Two further defects were **measured on the same two source sites** while fixing it, so they are
  repaired here rather than filed:

  - **A library truncated *after* the double-source guard made the gate silently PASS.** `common.sh`
    opens with `_ADB_COMMON_SH_LOADED`, so once the bootstrap has loaded it `require_lib`'s `.`
    returns 0 **through the guard** without reading the file — and the bootstrap runs on every
    ordinary invocation, so that is the normal path, not a corner. Both of `require_lib`'s checks
    then passed on functions the partial load had already defined. Measured at **rc 0 with the
    configured gates observed executing** on a partially-loaded library. The bootstrap's status is
    now captured on its own line (before `set -u` restores it, since `set -u` succeeds and would
    overwrite `$?` with 0) and passed to `require_lib` as an optional third argument that overrides
    a zero. Same defect an independent review found on #299's PR.
  - **The bootstrap called `adb_require_bash` as an undefined command** on a truncated library,
    printing `command not found` — a misleading cause ahead of the real one — with its 127 discarded
    and the bash floor left unenforced. It now probes for the function first, keeping the top-level
    call in the command position `check-bash-floor.sh --entrypoints` requires.

  **Nine new cases carrying twenty-four assertions in `scripts/check-precommit-gate.sh` (7a-7k,
  taking the suite from 122 to 146),
  each behavioural one observed failing on the real superseded input** — the suite run against a
  tree carrying `origin/main`'s gate reports `got [1] want [2]` for the unbound expansion, "the gate
  RAN on a partially-loaded library" for the truncated tail, and the `command not found` for the
  bootstrap. 7a is a precondition and correctly stays green there; two of the mutation harnesses
  *refuse* against that tree, because their anchors do not exist in the pre-fix file — which is
  `check_mutate_line` doing its job rather than a gap.

  **Two of those nine exist because an independent review found the `require_lib` half of the fix
  could not fail.** Every broken-`common.sh` fixture reaches the *bootstrap's* relaxation and never
  `require_lib`'s, because the double-source guard means `require_lib` never reads that file — so
  both its `set +u` and its `rc=$?` could be deleted outright with the suite staying green.
  `project-gates.sh` carries no such guard and is a real load, so the new cases break *it*: a
  top-level unbound expansion ahead of that library's own `set -u`, and an appended truncation that
  defines `adb_run_gates` before failing to parse (which the function probe cannot catch, leaving
  the captured status as the only thing that can). Each of the four repaired lines is now pinned by
  a mutation *and* verified independently by deleting it: 2, 2, 3 and 2 assertions go red.
  Cases 5-7 only ever covered an *absent* library; these cover a **present and broken** one.
  Each case configures a gate that touches a marker and then fails, because the exit code alone
  cannot carry the claim: 2 is both "the gate ran and blocked" and "the library was refused", and 0
  is both "everything passed" and "the gate no-opped in an unfamiliar repo". Three in-suite
  mutations pin them, one per repaired line — and none anchors on `  set +u`, which now appears
  **twice**, so `check_mutate_line`'s exactly-one precondition would refuse rather than prove
  anything.

  **One door stays open, and it is named rather than glossed: #342.** `project-gates.sh` runs
  `set -u` at its own line 88, mid-file, so this relaxation is cancelled *from inside the library*
  partway through the load — an unbound expansion below that line is fatal again and the gate exits 1
  exactly as before. Found by the reviewer on this PR and reproduced. A caller cannot stop a sourced
  file from re-enabling the option, so the fix is that library's dual-role `set -u`, not a stronger
  relaxation here. #317's own scope excluded `project-gates.sh` for want of a reproduction; that
  reason is now discharged, which is what makes #342 filable rather than a shape.

- **`publish` decided its exit code from the HOST rather than from the command line.**

  `cmd_publish` ran `have_gh || die` and the `jq` check *before* parsing its arguments. `die` exits
  1 and a usage error exits 2, so on a box with no `gh` a malformed command line reported
  "gh not found" and exit 1 — and the caller could not tell a typo from a missing dependency. The
  two dependency checks now run immediately after the argument loop, matching `cmd_tag`,
  `cmd_version_guard` and `cmd_record_pr`, which all validated arguments first. `cmd_publish` was
  the only inverted subcommand and the newest of them (#284).

  **The assertions that catch this already existed, and could not fire where `gh` is installed.**
  `publish rejects an unknown flag` and `publish --version requires a value` return 2 on any host
  with `gh` whether the ordering is right or wrong, so they were green on macOS and on both Ubuntu
  runners. The only job that could see them fail is the WSL smoke, which installs
  `git jq shellcheck nodejs npm ca-certificates` and no `gh` — and it is not a required context and
  runs on push, so it reported `got [1] want [2]` twice at `044adc7`, *after* v2.2.0 was tagged.

  So the ordering is now pinned **structurally** in `check-release-skill.sh`: it reads the line
  numbers from inside `cmd_publish` and fails on every host regardless of what is installed.

  **The pin anchors BOTH dependency checks, not just `have_gh`** — review caught that the first
  version watched one of a pair, which is this same defect one rung up. `cmd_publish` moved two
  checks; with only the `have_gh` anchor, moving `command -v jq` back above the argument loop would
  restore exit 1 on a host that has `gh` but not `jq`, while the guard stayed green because the
  anchor it watched had not moved — and the ordinary rc assertions would stay green too, since
  every CI host here has `jq`. The comparison is now against the earliest of the two.

  Observed failing on all three superseded orderings, each naming the anchor that moved, per
  `self-review.md`'s rule that a new guard is not done until it has been seen going red:

  ```
  have_gh moved back → FAIL: … (arg loop line 665, have_gh line 635)
  jq moved back      → FAIL: … (arg loop line 665, command -v jq line 635)
  both moved back    → FAIL: … (arg loop line 666, have_gh line 635)
  ```

  Verified on a gh-less host that usage errors now return 2 while valid arguments still return 1
  when `gh` is genuinely absent, so the dependency checks are reordered rather than weakened.

## [2.2.0] - 2026-08-13

Twelve issues, composed as one frozen set and delivered in full — nine bugs and three larger riders,
with no re-composition and no promotions after the freeze. The riders are the headline: `/adopt`
brings the baseline into a project that already has its own config, an adoption completion contract
answers whether that project is ready to *run* the loop, and `/release` now publishes an actual
GitHub Release instead of leaving a bare tag nobody can read notes from. The bug floor is mostly
guards that could not fail — a sub-floor check that never executed, a Stop-hook gate that was
fail-open, and a CI-health model that read an unprotected branch with external CI as having no CI
at all.

### Added

- **`/release` publishes an actual GitHub Release, reversing the tag-only decision** (#284; D62).

  Four tags existed and `gh release list` returned nothing. `SKILL.md` said so on purpose — twice —
  and called adding a publish step "a decision change". This is that decision change. Be precise
  about what a tag does *not* give you, because it does give you some of this: GitHub serves a
  source archive for any tag, and a tag is itself a pin. What it has no place for is **notes a
  human reads** and a **checksummed artifact this project vouches for** — so the release-pinned
  install slice (#285) had nothing project-owned to install *from*, and the documented install path
  stayed what it is today: a live clone of the development repo tracking `main`.

  `release.sh publish` is step 11; `roll` renumbers to 12 and now **refuses without the publish
  receipt**, because `roll` deletes the run state as its last act — a release rolled before it was
  published can only ever be published through the backfill path afterwards.

  - **The notes are the tag's own message, byte for byte.** Not the changelog and not a regenerated
    summary: `publish` reads the annotation off the tag object, which is the one place that prose
    durably lives and the only one that still exists for a backfill years later.
  - **`git tag -a` now passes `--cleanup=verbatim`, and that fixes a live defect.** Git's default
    cleanup treats a `#`-leading line as commentary and **deletes it** — in Markdown that is a
    heading. Measured on a throwaway repo: an 80-byte message containing one
    `# A markdown heading line` was stored as **54 bytes**, with the line simply gone and nothing
    said. Every annotated tag this repo has cut was written under that default. (Whether any of
    them actually lost a line is unknowable — the message files are gone, which is part of the
    point: nothing recorded what was dropped.)
  - **Two assets, and "reproducible" is claimed exactly as far as it holds.** A `git archive` of the
    tagged tree plus `SHA256SUMS`. `git archive` fixes every entry's mtime/uid/gid/mode from the
    commit and `gzip -n` drops the name and timestamp, so runs of the same gzip agree — measured,
    byte-identical. Across *other* gzip implementations they may not, which is why the digest is
    published rather than the property merely asserted. What goes *in* the artifact is #285's
    decision; this owns only that a checksummed, regenerable one is published at all.
  - **Idempotent in the three states a release can be in.** `gh release create` with assets
    internally creates a draft, uploads, then publishes — so an interrupted upload leaves a **draft**,
    and that is the state that must converge rather than produce a second release. absent → create;
    draft → upload only what is missing, verify, publish; published → verify only. A published
    release that does not match is a **refusal, not a repair**: `--clobber` deletes an asset before
    replacing it, so "fixing it up" has a window with neither.
  - **It verifies by reading back**, because a create that exits 0 is not evidence the release says
    the right thing. It re-reads the release, compares the body against the tag message byte for
    byte, requires the asset set to match exactly, and re-downloads both assets to re-hash them.
  - **A tag git signed on its own is caught before the push.** `git tag -a` signs automatically
    under `tag.gpgSign = true` — no flag is passed and nothing asked for it — and `publish` refuses
    a signed tag, so that version would be permanently locked out of the Release path, because a
    pushed tag never moves. The created tag is now validated with the same predicate `publish` will
    run, and deleted locally if it fails; nothing is pushed. Not `--no-sign`, which would silently
    override a maintainer's security policy to get past a limitation of ours.
  - **`preflight` checks `gzip` and a SHA-256 utility at step 1**, not at step 11 — the first
    failure used to arrive *after* step 10 had permanently pushed the tag.
  - **It can never create a tag.** `--verify-tag` is the backstop under a `git ls-remote` guard:
    `gh release create <tag>` with no such tag on the remote mints one from the default branch's
    head, which is a permanent object this skill's own rules forbid moving.
  - **Backfilling** (`publish --version vX.Y.Z`) pins on the peeled remote tag rather than run state,
    defaults to **not** Latest, and writes nothing back — a backfill run in a checkout with a release
    in flight must not stamp `PUBLISHED` over that release's state. `v2.1.0` and `v2.0.0` are
    backfilled — both are live, verified, and `v2.1.0` holds Latest. `v1.0.0` is a **lightweight**
    tag, so it carries no message and is refused by the same rule that protects every other caller;
    `v1.1.0` is annotated but left unpublished, as the issue's own "cosmetic" call.

  `scripts/check-release-skill.sh` grows from **165 assertions to 315**, over a fixture that stands
  up a real repo, a real bare `origin`, a tag created **by the driver**, and a *simulating* `gh` that
  keeps release state on disk. That last part is what makes "re-running changes nothing" an assertion
  rather than a hope. **27 mutations were each observed going red on their own witness**, and several
  of them were guards that could not fail until the fixture or the assertion was fixed:

  - the fixture originally created the tag itself, which made every byte-identity assertion a
    statement about the *fixture* rather than about `cmd_tag` — deleting `--cleanup=verbatim` left
    the suite fully green. Driving `release.sh tag` put the flag under test;
  - two structural pins (`tar.umask`, `--verify-tag`) were satisfied by the **comments explaining
    them**, so deleting the real flag stayed green. They now scan comment-stripped source, the same
    way the `$(slug)` and `need` scanners already do;
  - the two new preflight checks **covered for each other** — a single shadow `PATH` missing both
    tools stayed green when either check was deleted, because the other one still refused with a
    message the assertion matched. There are now two shadow paths, one per tool;
  - the fixture read the developer's **global git config**. `check_git` passes an identity to the
    commands the suite runs, but the *driver* runs its own `git tag -a`, so the identity came from
    whatever the host had — and a runner has none and cannot auto-detect one (unqualified hostname).
    Green on every workstation, red only on CI. The fixture now runs with `GIT_CONFIG_GLOBAL` and
    `GIT_CONFIG_SYSTEM` pointed at a file that sets `user.useConfigOnly = true`, which forbids the
    auto-detection a workstation silently relies on: deleting the fixture's own identity now fails
    **locally**, with the runner's exact error. The build also reports *which* of eighteen steps
    failed — one opaque line had cost a full CI round-trip that bought no information;
  - the shadow-`PATH` fixture `cp`d its `gh` stub over a symlink to the **real** `gh`, and `cp`
    writes *through* a symlink. Homebrew's Cellar binary is `-r-xr-xr-x`, so the write failed with
    EACCES, `2>/dev/null || true` swallowed it, and the shadow `PATH` silently kept the real `gh` —
    which is authenticated on a workstation and not on a runner, so the case passed locally for the
    wrong reason and failed on CI. `gh` is now always omitted from the mirror and the stub's
    placement is checked;
  - the auto-signed-tag case is driven with a **real SSH signature** (`gpg.format=ssh`, so it needs
    only `ssh-keygen` and no keyring), with the capability probed and a stated SKIP where signing is
    unavailable — an asserted success path would have proved nothing about the refusal.

- **The adoption completion contract, and a verifier that fails closed** (#81; D61).

  `/adopt` (#20) answers *"what does this project already have, and what must be reconciled"*. It
  never answered *"is this project now ready to **run** the loop"*, and the gap has a measured
  failure mode rather than a theoretical one: one surveyed repo came out of adoption with a
  `Next release` milestone holding **zero issues**, so `/roadmap` correctly emitted nothing and
  adoption "succeeded" having produced a dead flow.

  `scripts/lib/adopt-readiness.sh` is the contract and the verifier — twelve rungs, each a line
  item from the issue's own checklist, each carrying the **owner** who must act on it (`agent` or
  `owner`). That column is the half of *"names precisely what remains **and who must decide it**"*
  a pass/fail cannot express, and it is why a read-only verifier is sufficient: a verdict that
  repaired the `agent` rungs would still have to hand back the `owner` ones.

  - **It fails closed.** A rung nobody reported is `unknown`, and `unknown` is never green —
    `verdict` reads the *contract* rather than only its stdin, so a caller that forgets a fact
    cannot shrink the contract to whatever it remembered (a shrunken contract is trivially green).
    Every report states how many rungs it evaluated, because a verifier's failure mode is silence
    and `0 of 12` must not read like a clean run. `red` (something remains) and `indeterminate`
    (a fact could not be established) are separate verdicts with separate exit codes, because
    they need different next moves.
  - **It reports; it never repairs.** D60 bounds `/adopt` to a scan and #326 owns executing the
    migration plan, so a verifier that fixed what it found would be that executor under another
    name. The tracker writes the issue describes are already shipped — `/roadmap`'s step 4b sweeps
    unmilestoned issues to `Backlog` idempotently — and this verifies them rather than
    re-implementing them.
  - **Detection is not working.** The gate rung is met only against a **receipt** that the gates
    were executed at this commit, with this gate configuration, and passed; all three key it,
    because each invalidates it for a different reason. `receipt run` is the only producer — a bare
    `write` would have let a caller satisfy the rung by creating a file — and a *failing* run still
    writes one, because "ran and went red" and "never ran" are different facts. A project with **no
    detectable gate** is red and loud, deliberately inverting `project-gates.sh`'s own
    emit-nothing-on-an-unknown-ecosystem contract: right for a gate runner, wrong for an adoption
    that would otherwise finish with enforcement silently off.
  - **A pre-existing milestone gets an answer, not a reclassification.** `Audit Results` appeared
    in 3 of the 4 surveyed repos; GitHub's one-milestone rule makes issues parked there invisible
    to release composition (80 in one repo). Each such milestone now needs a `milestone:<title>`
    row in the roadmap artifact's `## Decisions` — the shipped, owner-authoritative table
    `/roadmap` never rewrites. The rung checks that an answer **exists**, not which answer it is:
    classifying the prose would add a grammar that can drift and buy nothing a read-only reporter
    can act on. The one-milestone tension is not resolved; it is made *visible*, with each
    milestone's open-issue count named.
  - **Split for testability**, the same way `release-counts` / `release-ready` already are:
    `probe` (filesystem only) and `tracker` (a JSON object in, rung records out) hold every rule
    and are hermetic; `facts` is the one thin subcommand that touches the network and classifies
    nothing. `status` composes all four and is the re-runnable entry point, reachable as
    `baseline adopt status`.

  **Every guard was observed failing** — 38 mutations against a tree copy, each required to make
  the suite red on its *own* named witness. Writing the negative half first caught three defects
  the positive half never would have, and two of them would have reported a broken project as
  fine: a gate count that grepped a human-readable table for `run:` (which it prints *without* a
  colon), so a repo with a real gate counted zero and the axis reported N/A; a jq filter that
  dereferenced `.title` inside `$d | index(…)` where jq has rebound `.`, whose abort a
  `2>/dev/null` swallowed into "every milestone is dispositioned" for a project with 44 issues in
  an undispositioned one; and a `while read` that dropped the final record of every
  `$(…)`-captured record set.

  The self-review pass caught three more of the same family — a decision resting on something with
  no contract: an equality against the gate table's *"no gates configured or detected"* sentence
  (re-word it and a project with no gates reports as deliberately disabled); a `// ""` that read an
  unreachable roadmap artifact exactly like one carrying no release-command marker, telling the
  owner to add a marker they may already have; and a milestone title carrying a newline, which
  forged a record boundary and killed the run on a "rung" nobody wrote.

  **The independent review then found more of the class than either pass had**, and its findings
  are why the mutation count went 21 → 29 and the assertion count 124 → 169. Three further false
  greens came from unvalidated JSON types — `"blocker_label":"true"` (the *string*),
  `"milestones":null`, `"release_command":false` — each a malformed fact reading as a satisfied
  rung. The receipt stayed valid across **uncommitted** edits to the very tree it certified, and
  `receipt run` skipped `turn-end` gates while claiming every detected gate had run. The milestone
  rung asserted the milestone *names* instead of observing them, so a repo with the label and
  neither milestone passed. The armed count included the roadmap artifact that
  `roadmap-lib.sh release-counts` excludes, so this verifier and `/roadmap` could disagree about
  one milestone. `head -n1` discarded the release-command ambiguity its reader deliberately
  surfaces. A milestone title reached a GitHub search query unescaped. And a gate detector that
  *failed* was classified as a deliberate N/A. Every one is fixed and pinned by a mutation.

  One checklist item is deliberately **absent**: the contract's *"project knowledge map (#33)"*  <!-- adb-claim-ok: #33 was closed NOT_PLANNED — the reference records why a checklist item was DROPPED; it tracks nothing -->
  cannot be a rung, because that issue was closed `NOT_PLANNED` and requiring it would make the
  contract permanently red for every project. The reason is recorded in the contract itself.

- **PHP quality gates, and an ecosystem set that grows by addition** (#81).

  `project-gates.sh` detected Node, Rust, Go and Python only, so a PHP project was a *recognised*
  project root with **zero gates** — `detect` printed nothing and exited 0, exactly as it does for
  a directory containing no project at all. `adopt-lib.sh stack` already answered `php` for the
  same tree, so the two libraries disagreed about whether the repo was even known. One of the four
  surveyed adoption targets is a 139-issue PHP repo.

  Detection is now an ordered **adapter registry** — the issue's *"extensible, not a fixed list"*.
  The **next** ecosystem after these five is one `_adb_eco_<name>` function plus one token in
  `_ADB_ECOSYSTEMS`. The existing four adapters were restructured into functions — not moved
  verbatim — but every command string they resolve is unchanged, and single-primary first-wins is
  preserved.
  The PHP adapter prefers a declared `composer.json` script over an inferred binary and a
  Composer-pinned `vendor/bin/<tool>` over the same tool on `PATH`, resolving `typecheck` to
  PHPStan or Psalm, `test` to PHPUnit, `lint` to PHP_CodeSniffer, and `format` to
  `php-cs-fixer --dry-run` — never an in-place fixer, because a gate that rewrites the tree is a
  mutation wearing a verification's clothes.

  **PHP is last, and that is the polyglot answer.** A WordPress plugin routinely carries both a
  `composer.json` and a `package.json`; such a repo keeps its **Node** gates, because those are
  commands the project itself declared, and layers PHP through the open-set `[gates]` override.
  Putting PHP first — as `adopt-lib.sh stack` does, for a different question — would silently
  replace declared gates with inferred ones for every already-adopted mixed repo. A repo with only
  `composer.json` now gets gates instead of silence. `_adb_json_script_has` is extracted from
  `_adb_pkg_has` so `composer.json` reuses that thrice-corrected parser rather than starting a
  second copy of it.

- **`/adopt` — bringing the baseline into a project that already has its own config** (#20,
  consolidating #21 and #29; D60).  <!-- adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work / #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work -->

  There was no path for adopting the baseline into an **existing** project. Every real repo
  already has a `.claude/`, root docs, forked skills and hooks, so adoption means working out what
  now duplicates the baseline, what carries a delta that must be kept, and in what order to
  reconcile them. A read-only sweep of four projects had produced that inventory by hand; this is
  the workflow that produces it.

  - **It never deletes, moves, or edits a file in the project it scans** — not with `--apply`, not
    with confirmation. `remove` and `move` are words in a plan a human executes. The only writes in
    the project are the two artifacts that do not yet exist (`agents.toml`,
    `.ai-dev-baseline/upstream.toml`); each is created with `set -o noclobber` (atomic create-or-fail,
    not check-then-copy) and refuses a symlink target, so neither a race nor a **dangling** symlink
    can turn the write into an overwrite of something outside the project. The remaining write is
    the already-shipped consent-gated `baseline repo apply`, run inside the target repo rather than
    the caller's. `check-adopt.sh` asserts byte-for-byte that no read-only subcommand alters the
    scanned project, and **executes the workflow's own `apply` block** against fixtures to prove it
    refuses. (The run does rewrite its own gitignored `{{STATE_DIR}}` scratch every invocation; the
    boundary is about the project's files, and saying otherwise was an overclaim.)
  - **"Duplicates the baseline" has exactly one proof: byte-identity of the whole artifact**
    against `adb_agent_manifest`'s own shipped set — never a second hardcoded list, never
    similarity, and for a skill never `SKILL.md` alone: a project skill with an identical `SKILL.md`
    plus its own helper must not be recommended for removal. `cmp`'s third status (the comparison
    *failed*) is `unknown`, not `differs`. A colliding artifact that *differs* classifies as `move`
    (re-home the delta), never `remove`; that difference is the project's forked behavior. A
    **prescribed home** is tested *before* collision, because `.claude/scripts/precommit-gate.sh`
    collides with a shipped script by name and *is* the one legal home for custom gate policy —
    reverse those two arms and every adopting project is told to delete its own gate. Both
    orderings are pinned as regressions.
  - **Four adoption-hygiene axes** (#29): the product-code boundary (`src/**` referencing an agent  <!-- adb-claim-ok: #29 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work -->
    CLI is the *product*), tracked config that ships to end users, layered statusLine/hook
    precedence, and a broad ignore rule that reaches the runtime state dir only by accident. The
    credential probe matches a closed prefix list and prints the **prefix only** — never the value.
  - **An upstream pin** (#21) at `.ai-dev-baseline/upstream.toml`, recording version, commit,  <!-- adb-claim-ok: #21 was consolidated INTO #20 and closed NOT_PLANNED (2026-08-10, "the work is not dropped, it moved") — the reference is this change's provenance, not tracked work -->
    adoption date, stack and agents. Deliberately a **commit rather than a copied `.upstream`
    tree**: the install is a symlink into a git clone, so one 40-byte field recovers the inherited
    tree exactly and forever, while a snapshot doubles every file and goes stale silently.
  - **Role inference that refuses to guess.** A signal naming two agents for one role yields
    `ambiguous`; no signal yields `none`. Neither is ever filled in from the baseline's own
    defaults — an operator reads `agents.toml` later as a record of what *they* decided, so a
    guessed line is indistinguishable from a chosen one. Uninferred roles are emitted commented out.
  - `delete_branch_on_merge` (#56, folded into #20) is **not** implemented: it contradicts D9's  <!-- adb-claim-ok: #56 was folded INTO #20 and closed NOT_PLANNED — the reference records why delete_branch_on_merge is deliberately NOT implemented, not tracked work -->
    two-setting bound, and widening that needs its own decision rather than a drive-by field in an
    adoption run. `adopt.md` carries the instruction not to add it.
  - **Executing** the plan — re-homing forks, deleting duplicates — is deliberately not in this
    slice and is tracked as #326: it needs a general backup primitive that does not exist yet
    (`install.sh`'s pattern is `adb_link`'s, and is symlink-shaped).

  A `--apply` run refuses a **symlinked ancestor** as well as a symlinked target: `mkdir -p` accepts
  an existing symlink as the directory, so a repository shipping `.ai-dev-baseline` as one could
  otherwise make an approved write land outside the project without winning any race. The content
  write itself happens under `noclobber` rather than into a placeholder that is then reopened.

  Whole-artifact comparison includes **symlinks and their targets**, not just regular files — a
  project skill carrying the baseline's files plus its own symlink must not be recommended for
  removal. A vendored `.<agent>/scripts/lib` is recognised as the single `lib` artifact the
  manifest ships rather than fragmenting into a dozen escalations. The catch-all scan is
  NUL-delimited, so a newline-bearing filename reaches the record-safety check whole instead of
  being split into invented paths. The plan renders untrusted paths through `adb_display_value`,
  since a legal filename may carry terminal control bytes. `pin-drift` revalidates a commit it
  **read** — `pin-render`'s validation governs what this tool writes and says nothing about a
  hand-edited pin, and one carrying `HEAD` produced an empty `HEAD..HEAD` range that reports no
  drift at all.

  Every load-bearing decision carries a mutation in `check-adopt.sh`'s `--mutation` harness that
  must make the suite go red **on its own named assertion** — the standing-test form of "observed
  failing", rather than a claim in a commit message that nothing can re-run.

  New: `scripts/lib/adopt-lib.sh`, `scripts/check-adopt.sh` (registered as the `adopt` selfcheck
  step), `base/workflows/adopt.md` rendered to all three agents, and an `{{ADOPT_LIB}}` placeholder.
  `/adopt` also joins the untrusted-content registry as the first workflow whose third-party text
  arrives from the filesystem rather than the network — what it reads is other projects' `SKILL.md`
  bodies, which are instructions to an agent by construction.

- **A CI failure has a third class — the job never ran — and it is now a tested command, not a
  paragraph** (#300, D58).

  `base/practices/ci-discipline.md` modelled every CI failure as exactly one of two things. During
  the GitHub Actions `major_outage` of 2026-08-06 a run concluded `failure` after 1h46m having
  executed **zero steps**, annotated *"The job was not acquired by Runner of type hosted even after
  multiple attempts"*. That protocol's "read the failure log" step was unexecutable, and its
  "classify" step offered two boxes, neither of which fits. Worse, the closer of the two routes to
  "file a de-flake issue", which `issues-and-scope.md` forbids on both of its questions: nobody does
  it, and nothing in the repo breaks if nobody ever does. Two practices, opposite instructions, one
  event.

  - **`scripts/lib/ci-health.sh classify --run <id>`** answers it: `0` green · `22` a real failure
    (a non-passing job executed steps, so there is a log) · `23` **never-ran** · `24` queued past a
    threshold · `25` still pending · `20` unreadable · `2` usage. A pure `classify-doc` arm takes the
    assembled document on stdin, so the decision is hermetically testable and the live path cannot
    drift from it.
  - **It decides on step counts, not on the annotation.** An empty `steps` array is structural; the
    annotation is vendor wording that costs an API call per job. Annotations are read only for the
    jobs that executed nothing, and a failure there degrades the reason line, never the verdict.
  - **It fails closed in the direction that matters.** `never-ran` is the flattering answer — it says
    the red is not your fault — so it is returned only from positive evidence that *every*
    non-passing job executed nothing. A truncated job list, a run with no jobs, a failure nothing
    can be attributed to, and every malformed response resolve to `20`, never to "probably the
    platform".
  - **A mixed matrix is a REAL failure.** A shard failing an assertion beside one that never
    acquired a runner is `22`, with the idle shard still named — reporting it as infrastructure
    would bury a genuine failure behind "not your fault".
  - **`startup_failure` is the diff, not the platform** — a workflow that could not start produces
    no jobs at all, and without its own arm it would have been reported as unreadable.
  - **The practice now scopes green-by-retry to results that exist.** "Never merge on a flaky re-run
    alone" is right for a job that ran and flapped; for one that executed zero steps the re-run is
    the *first* run, and there is no earlier verdict being overridden.

### Fixed

- **A repo path containing a tab or newline made `agent-init` initialize a different, existing
  directory — silently** (#278, D59).

  `adb_repo_shape` emitted `<key>TAB<value>` records with the path unescaped, and `adb_shape_val`
  read them back with `awk -F'\t'`. A directory name may legally contain a newline, so the `root`
  record split and the accessor returned a **truncated** path — not a missing answer, but a
  *different directory that frequently exists*. `bin/agent-init` uses that value as its write root.
  Measured before the fix: run inside `…/project<NL>shadow`, `agent-init` exited **0**, printed
  "wrote agents.toml", and left `agents.toml` plus three `.gitignore` rules in the innocent
  `…/project` repository next door. The function's own comment called such paths "unsupported",
  which is a declaration; the behaviour was a confident wrong answer.

  - **The producer refuses instead of guessing.** An unrepresentable root yields exactly one
    `warning` record and **nothing else** — no `in_git`, no `root`. The refusal is atomic because
    every other fact is derived from that path, so a partial shape would describe a directory the
    caller never named. Same call D41 made for `state-scan`'s state directory.
  - **The check runs before canonicalization as well as after.** `$(cd … && pwd -P)` strips every
    trailing newline, so a repo named `project<NL>` resolves to `project` — a *different, existing*
    repo — before any check can see it. The capture in between now carries an `X` sentinel so the
    trailing byte survives, and a safe-named symlink onto an unsafe physical target is caught by
    the second check rather than silently accepted.
  - **Every path is checked where it is emitted, because "an ancestor of a safe path is safe" is
    false.** Self-review tried to break that shortcut and succeeded twice: `GIT_DIR`/`GIT_WORK_TREE`
    redirect `--show-toplevel` to a tree that need not contain the start dir, so a *safe* working
    directory yields an *unsafe* `root`; and `core.worktree` on an enclosing repo does the same to
    `nested_in` while this repo's own root stays clean. Both are reproduced and pinned. The resolved
    root refuses atomically; `nested_in` is dropped with a `warning` (it is a note about a
    neighbour, and `parent_in_git` is still truthfully `1`).
  - **`extra_doc` is suppressed per field, and the drop is announced.** Its path comes from
    `git ls-files`, so it is an arbitrary tracked filename. A repo at a clean path could track
    `packages/we<NL>ird/CLAUDE.md` and forge a record from inside an otherwise sound shape.
    Refusing the whole shape for one bad doc would delete real facts, so the doc is dropped with a
    `warning` instead of vanishing.
  - **`bin/agent-init` refuses an absent `root` explicitly, and before the `in_git` test.** The
    `cd "$ROOT"` below it only *looks* like it covers this: bash **5.3** rejects `cd ""` — that
    specific release, not 5.x generally — while bash 3.2, still `/bin/bash` on every macOS,
    succeeds and stays put. The 5.3 floor means today's fallback does refuse, for a reason
    unrelated to the check it stands in for and with an empty path in its message. Checked before
    `in_git` because an absent `in_git` is not `0`, and the old ordering reported "not inside a git
    repo" about a perfectly good git repo.
  - **The delimiter predicate now has one home.** `_adb_cl_tsv_safe` is promoted to
    **`adb_tsv_field_safe`** in `common.sh` (with `adb_tsv_field_display` beside it), and
    `cleanup-lib.sh` delegates to it while keeping its own state-record policy. D41 kept it private
    on the explicit ground that `adb_repo_shape` had abstained; this is the change that spends that
    premise.
  - **`adb_agent_manifest` is deliberately not fixed here** (#324). It shares the record format,
    but its consumers swallow the producer's status in heredoc command substitutions, and
    `adb_link_manifest` was reproduced moving a real directory into backup *before* returning
    non-zero. That needs status propagation through `install.sh`, `uninstall.sh`, every adapter and
    `bin/baseline` — a second cross-library decision, which D59 declines to take silently.
  - **Every new guard was observed failing.** Eleven mutations against a copy of the tree, each
    verified applied and each required to turn red only the assertions that cover it. Three earned
    their keep by exposing gaps rather than confirming coverage: disabling the pre-canonicalization
    check surfaced a missing case (an unsafe path that does not *exist* forges records out of the
    unreadable-start branch); removing the sentinel from the `git rev-parse` capture is caught by
    exactly one assertion, a work tree whose name ends in a newline; and the independent review
    replaced `adb_tsv_field_display`'s entire body with `:` and watched all 669 assertions **still
    pass** — "one line", "no newline byte" and "passes the predicate" are all satisfied by the empty
    string, so the renderer now has non-empty, escaped-content and driven-fallback assertions too.

- **An outage and a permanent configuration gap no longer get the same words** (#300, D58).

  The issue reported that `repo-settings.sh automerge-ok` returns `13` for both. **That premise is
  false**, and it is refuted rather than implemented: code `13` is `phantom_contexts` — job names
  discovered *statically* from `.github/workflows` against the branch's *configured* required
  contexts — so it reads no run, job or check, and no incident can cause it or clear it. Teaching a
  settings predicate to read run health would have been the charter violation `pr-review.sh` exists
  to avoid, in order to distinguish a state that predicate cannot enter.

  - **The arm an outage actually reaches is `20`** (an API read failed), and it now says so: if the
    API itself is degraded this clears on its own, and nothing in the repo needs changing. The
    exit-code table and `docs/repo-settings.md` state which codes an incident can and cannot produce.
  - **An unacquired job reads as a RED branch, not an unreported one — so `/roadmap`'s `not-green`
    arm is where the guidance went.** The intuition is backwards: GitHub creates the check run
    anyway and concludes it `cancelled`, which `branch-health` scores as failing. Verified against
    the cited commit `03486b7` — check runs `ci` (cancelled) and `quality` (success), predicate
    answers `not-green / failing: ci`. That arm now tells the agent to ask whether the failing check
    **executed** before calling it a broken build, because reporting a never-ran job as a red build
    sends someone to bisect a commit that was never compiled. `branch-health` keeps its verdict set:
    an unverified branch must not cut either way, and a transient claim that cannot be checked from
    a commit does not belong in the enum `release-ready` maps to `met`.
  - `/debug` and `docs/philosophy.md` restated the binary model and now carry the three-class one; a
    negative `fact-drift` pin with all three real superseded spellings keeps it from coming back.

- **`no-ci` is now DECLARED, never inferred — an unprotected branch with external CI no longer
  fabricates a release cut** (#293, D57).

  `branch-health` treated "both existence probes found nothing" as positive evidence that a repo has
  no CI. It is not: an **unprotected** default branch has nowhere to declare a required status
  context, so a CircleCI/Buildkite/Jenkins repo with no branch protection produced the *identical*
  empty answer as a repo with no CI at all — and `/roadmap` emitted the cut either way, reported as
  `no CI configured`, which is a statement about the repo that is false. This is #115's original
  defect surviving for a narrower repo shape, shipped knowingly and recorded in D45's residue list.

  No non-admin read can separate the two: there is nothing to protect on an unprotected branch, and
  a check-suites probe is blind to the legacy status providers, which is exactly the population. So
  the default **inverts** — nothing found and nothing declared is now `indeterminate`, and the
  refusal names the marker that settles it.

  - **A second `release-health` value, `no-ci`**, declares that a repo genuinely has none. It
    resolves to the `no-ci` verdict → `met`, with a banner naming the declaration. **#24 still
    holds**: a repo that never adopted CI is not deadlocked, it adds one line, and the run prints
    which line.
  - **`no-ci` cannot excuse positive evidence that CI exists** — an unreported Actions workflow or
    an unreported required context still refuses. A declaration may stand in for absent evidence and
    never overrule present evidence, which is what makes a stale marker stop applying by itself once
    the repo declares an **Actions** workflow or a required context, or once anything reports on the
    commit. It does *not* self-limit on merely adding an external provider that is neither required
    nor reporting there — that repo is back in the ambiguous state the declaration exists to answer.
  - **`skip-unreported` now reaches the no-evidence arm too**, printing `unreported-ok`. A PR-only
    CircleCI repo on an unprotected branch lands there rather than on the two unreported arms, and
    answering `indeterminate` would have deadlocked the exact population #115's hatch was built for.
  - **`branch-health`'s third argument is a word, not a boolean**:
    `<health-decl off|skip-unreported|no-ci>`. The retired `0`/`1` are a hard error rather than a
    compatibility alias — mapping them back would let a stale caller reach the new arm carrying a
    value it never chose.
  - **The authority rule moved into `roadmap-lib.sh health-decl`**, a pure predicate over the marker
    value and the artifact author's repo permission. It grew a second caller: with `no-ci` declared,
    `.claude/skills/release/release.sh` must consult the marker or refuse to ever tag a CI-less
    repo. It honours `no-ci` and still refuses `skip-unreported`, which describes a repo that cannot
    give `verify-merge` the evidence it is built on.

  The residue this closes is **removed** from `branch-health`'s header and
  `docs/release-goal-convention.md` rather than narrowed — no arm reaches `no-ci` on evidence alone
  any more. Every boundary is pinned in `check-roadmap.sh` (2j-quater, 5b-bis, 5c) and driven end to
  end in `check-roadmap-e2e.sh`; four mutations of a throwaway tree copy were each observed going red.

- **The shared workflow reader reads flow collections across physical lines, and reports merge keys
  instead of ignoring them** (#291).

  `adb_wf_on` / `adb_wf_jobs` (`scripts/lib/common.sh`) read one physical line per value, so two YAML
  shapes went unread. Both were deferred from the #262/#102 run, where independent review found them.
  Only the first is valid GitHub Actions YAML; the second is syntax Actions rejects, which is what
  decides how it must be handled.

  - **A flow collection spanning several lines** — `branches: [` / `main` / `]`, a wrapped `on: [`,
    a `pull_request: {` filter, or an inline job mapping — is valid YAML that GitHub runs, and is
    now joined before it is parsed by a new `adb_wf_flowspan`. The join is quote-, escape- and
    comment-aware, and **all-or-nothing**: an unterminated collection is read from its opening line
    alone, because a *partial* list is worse than none (half a `branches:` list is indistinguishable
    from one that genuinely excludes the target). The record grammar's no-newline invariant is
    unchanged; what changed is why it holds — each line break becomes one space, except a break
    escaped by a trailing backslash inside a double-quoted scalar, which folds to nothing. Both are
    YAML's own rules.
  - **Merge keys (`<<:`) are reported, never resolved.** GitHub Actions supports anchors and aliases
    but implements YAML **1.2**, which has no merge key — GitHub's own position is that they shipped
    "what's in the yaml 1.2 spec and merge keys aren't in there" — so a workflow carrying one is a
    syntax error there and never runs. The issue asked for them to be *resolved*; that is the worse
    bug, because a resolved job gains a readable `name:` and no disqualifier, so discovery would
    require a context from a file GitHub refuses to run. Reported at **two locations × two
    spellings** — a job property and a `pull_request:` filter key, each in block and inline flow
    form — with the inline pair tested depth-aware rather than by substring.
  - **The discovery verdict is file-wide, and getting that wrong recreated the bug one job over.**
    The reader reports `merge` per job, because the floor lint needs to know *which* job it cannot
    read a runner for. Discovery must not: one merge key stops the whole workflow, so skipping only
    the merging job left its siblings required from a file that never runs. The first cut did
    exactly that, and its fixture asserted the phantom (`Base Name`) as the correct answer.
  - **The issue's premise was half wrong, and the wrong half is the expensive one.** It records both
    shapes as failing toward *under*-reporting, "the recoverable one". True of the reader; false of
    the verdict. Reproduced before any code changed: a `<<:` job was required as `CHECK alt` — a
    context whose real check name is the anchor's and which may never run at all — and a wrapped
    inline job mapping emitted `keyed` from an opening brace, requiring `hidden` when the check
    reports as `Real Name`. Both are phantom required contexts, which deadlock every PR.
  - **Consumer verdicts move in both directions**, each pinned by its own fixture: discovery now
    keeps a job whose `branches:` list wraps (it used to drop every job in the file) and skips the
    two phantom cases above. The floor lint keeps the opposite filter — it still reports such a job
    rather than skipping it — and now names the cause, `runs on '<merge key>'` instead of an
    uninformative `'<none>'`, but only where `<none>` would have gone: a merging job that declares
    its own `runs-on:` is still judged on that label.
  - **The new guards were observed failing**, and the ones that could not be were rewritten. The
    assertions encoding the fix were driven red against a copy of the pre-fix tree; their failure
    output is the reproduction record (`JOB|2|runs-on` for the phantom job, `NAME|1|Real Name,` for
    the flow-syntax fragment, `got [Base Name|alt|]` for the phantom context). The rest are invariant
    guards that pass both ways by design — `RANGE`/`STEP` line numbers, the anchor job, and the floor
    lint's verdict, which was already correctly red and gained only a better diagnosis.

    Where no pre-fix run exercises a guard, a **targeted mutation of the single line it pins** stands
    in; ten are driven red that way. Independent review found four assertions that pinned nothing —
    a `m = WFFLOWEND` claim the loop satisfied on indent anyway, a `hasnt` whose substring could not
    match the un-stripped comment it was meant to catch, a dedup guard whose fixture had only one key
    to deduplicate, and a job-count guard whose fixture body was indented clear of the job column.
    Each was rewritten until its mutation went red.
  - **Also corrects the record grammar** in `common.sh`'s header, which had drifted: `STEP` and the
    `keyed` / `alias` / `blockname` / `blockrunner` flags were emitted by the code and absent from the
    only place a consumer author could learn they exist.

- **`/cleanup` deletes state artifacts by identity, not by pathname, so a run that recreates the
  same name between the pre-delete scan and the `rm` keeps its files** (#305).

  The state sweep reached a verdict for a *record* and then handed that record's **path** to `rm`.
  A fresh `/implement-issue` preflight clears the previous run's artifacts and writes its own at
  the same fixed names, so a path judged stale could be occupied by a **live** run's file by the
  time the delete loop reached it. The `marker` arm never had this — it re-captures the file's
  identity immediately before deleting — but the `gaps`, `review`, `issue` (#250) and `threads`
  arms did.

  - **The window is not instantaneous.** The delete loop makes a live `pr_state` round trip per
    `threads` record, so a later record's `rm` can run seconds behind the scan that judged it.
    Reproduced against the workflow block itself: a swept `issue-<n>.json` was the one a live run
    had just written.
  - **A content digest cannot see it, so `file-identity` is a new primitive rather than a
    strengthened `marker-identity`.** These replacements are routinely *byte-identical* —
    `gh issue view` returns the same JSON for an unchanged issue, an `.assoc` holds one word, and
    `gap-prompt.txt` is rebuilt deterministically from both — so `cksum` compares equal and the
    file is deleted anyway. `file-identity` composes `<inode>-<mtime>-<crc>-<size>` and is
    documented as best-effort. `marker-identity` is unchanged on purpose: `implement-lib.sh`
    derives the claim's identity from a *single* read of its bytes, and a `stat` component cannot
    come out of one read.
  - **The identity comes FROM the scan.** `state-scan --with-identity` appends it as a fourth
    field, computed in the same loop iteration that classified the file, because only that loop can
    bind the two facts to one observation. Building the set in the caller — walk the finished
    records, fingerprint each path — reads whatever occupies the path *afterwards*, so the
    delete-time comparison compares a replacement against itself and matches; that was the first
    implementation of this fix and the independent review was right to reject it. The flag is
    opt-in so the three-variable readers are untouched: `read` folds every surplus field into the
    last variable, which here is a marker's branch name and a thread cache's PR number.
  - **What it does not close, stated rather than implied.** Two syscalls still separate the
    re-capture from the `rm`, as in the marker arm; and `state-scan`'s glob expands before its
    per-file loop, so a file replaced between the two is outside this. Both residuals are
    microseconds wide, and neither is what keeps the sweep safe alone — the `lock` and `marker`
    records in the same scan are. Moving the file aside and verifying the operand (what
    `implement-lib.sh` does to break a claim) was rejected: it unlinks, however briefly, a file
    just decided to belong to somebody else, and a crash mid-way strands a sidecar the sweep
    classifies `other` and never removes.
  - **A kept file is reported** in the existing `SKIPPED … kept` shape, which stays distinct from
    `REFUSED … left in place` (an `rm` that genuinely failed).
  - **The regression executes the real workflow block** via a new `ADB-SNIPPET: state-sweep`
    marker, not a mirrored copy, with the race made deterministic by a library wrapper; a control
    drives the same fixture through the pre-fix loop and requires it to lose the files. Reverses
    the carve-out recorded in D40; see D55.
  - **Also fixed in `marker-identity`, a confirmed sibling**: `cksum < "$f" 2>/dev/null` silences
    *cksum*, but a failed redirection is the **shell's** diagnostic and is emitted before cksum
    runs — so an unreadable-but-present file printed `…: Permission denied` into a sweep whose
    output contract is terse, from inside a command substitution where it reads as a failed step.
    Both spellings now redirect the whole pipeline, as `implement-lib.sh`'s `_il_file_identity`
    already did.

- **`/release`'s run-state guards can stop the release, and every one of them is now driven by a
  test** (#313).

  `.claude/skills/release/release.sh` guards every out-of-order step with `need`, and `need` used
  to **print** its value — so all eleven call sites captured it in a command substitution
  (schematically `x="$(need KEY hint)"`, over six destinations: `v`, `pr`, `sha`, `msha`, `exp`,
  `pinned_m`). A command substitution is a subshell, so `die`'s `exit 1` left only the subshell: the
  message reached stderr, the assignment took the **empty string**, and the step carried on as
  though the value were there. A guard whose failure mode is "print a line and continue" is worse
  than no guard, because everything downstream then runs on empty inputs.

  - **Measured, cutting v2.1.0.** `await-review` exited `10` and the PR was merged from the web UI,
    so neither `EXPECTED_CHECKS` nor `MERGE_SHA` was ever recorded. `verify-merge` did not stop:
    both values came back empty, `await_checks "" ""` polled `repos/<slug>/commits//check-runs`
    **90 times at 10s intervals**, and reported `never reached a settled set of >= ` after
    **fifteen minutes**. The real cause — *you skipped a step* — had been printed to stderr in the
    first 20ms and buried. Same shape `slug()`'s header documents from #218, reached by a different
    route.
  - **`need` now writes through a nameref and is called as a plain command**, so `die` runs in the
    caller's own shell and `exit 1` ends the run. The value has to reach the caller some way other
    than stdout, because stdout is what forced the subshell. The private ref is `_need_dest` (a
    nameref whose name equals its target is a circular reference bash refuses, and four sites are
    legitimately named `v`; `_need_dest` is in turn refused by name, so the one destination the
    helper cannot serve fails with a message instead of an unbound-variable trap), and each caller
    declares its destination `local`. That last part is not decoration: ShellCheck cannot see through
    a nameref, and with the seven declarations removed it reports **4 SC2154 diagnostics** over
    `pr`, `exp`, `pinned_m` and `pinned_ms`. `v`, `sha` and `msha` escape
    only because some *other* function in the file happens to assign those names — an accident of
    naming rather than a property to build on, so all seven are declared uniformly.
  - **`cmd_roll`'s milestone pin-revalidation was defeated by its own empty inputs**, and that is
    the twelfth guard, newly added. `MS_NAME` was read with a bare `rs`, so an unpinned run made the
    `jq` select milestones titled `""`, find none, and compare `[ "" = "" ]` — which **passes**. The
    check written specifically so a changed marker cannot rename, drain and close a *different*
    milestone than the one the release was cut for would have waved the roll through, having
    verified nothing. (Contained only downstream: `bin/baseline release roll --version ""` refuses,
    so no milestone was harmed.)
  - **`scripts/check-release-skill.sh` now drives the driver**, in a throwaway checkout rooted in
    its own `git init` — because `release.sh` derives its run-state path from
    `git rev-parse --show-toplevel`, so testing the tracked script would read, and these failure
    cases would overwrite, a real in-progress release's state. All **twelve** guard positions are
    exercised in order, with partial state supplied to reach the later guard in each function, plus
    a key recorded with an empty value and a key emptied by a later duplicate line.
  - **Exit status alone proves almost nothing here, so the oracle is stricter.** Against the pre-fix
    driver **11 of the 14** refusal cases still exit `1` — a later `die`, on a later line, for a
    different reason — so a status assertion would have been green for all eleven. Each case now
    requires exit exactly `1`, **empty stdout**, stderr equal to the guard's own single line, **no
    `gh` request issued at all**, and no rollover; the last two separate "stopped at the guard" from
    "stopped at a convenient downstream failure". Runs under `adb_run_bounded`, because a
    regression's signature here is a *wait* (90x10s in `await_checks`, 30 minutes in `pr-watch`) and
    a timeout must never score as a refusal.
  - **One present-value case, because fourteen refusals cannot tell a working guard from a broken
    one.** A `need` that refused unconditionally, or never assigned, would satisfy every case above.
    `roll-preflight` with `VERSION` recorded interpolates what it read into the rollover's
    `--version`, so the recorded argv — captured one argument per line, so it cannot be satisfied by
    a substring — is proof the value reached the caller through the nameref.
  - **Observed failing on the real superseded input.** Run against a copy of the tree carrying the
    pre-fix driver, the new suite reports **30 failures**; the same copy with the fix reports **0**.
    Three in-suite mutations then pin it permanently, and each states what it covers rather than
    implying more: **M1** restores one call site to `$(need …)` — keeping the three-argument shape,
    so it reproduces the subshell rather than an argument-contract error — and must redden both
    structural rules *and* `verify-merge`'s behaviour; **M2** deletes the emptiness test so `need`
    cannot refuse, and **replays the whole matrix**, requiring each of the fourteen positions to
    stop satisfying the oracle; **M3** makes `need` never assign, which only the present-value case
    can catch. Each refuses to prove anything rather than passing silently when its needle stops
    matching.
  - **A structural pin, honest about its reach.** Two rules ban the `$(need …)` spelling and require
    every `need` in a recognized command position to be one of the direct call sites — including
    after a reserved word, without which `if need …; then :; fi` lowered both counts equally and
    stayed green. Both rules report what they counted, and both name what a lexical line scan cannot
    see (quoted text, trailing comments, a substitution split across lines), because that is what
    the driven cases are for.

- **This repo's own Stop-hook gate fails loud on a broken library, and the real script is now
  tested** (#299).

  `.claude/scripts/precommit-gate.sh` — the turn-end gate D25 ships for this repository — loaded its
  shared library with `. … || exit 0` and `command -v adb_default_branch … || exit 0`. A missing or
  truncated `scripts/lib/common.sh` therefore made it **silently pass**, in exactly the words a clean
  run uses, at the end of every turn. That is the inversion `agents/claude/scripts/precommit-gate.sh`
  carries `fail_loud` for (#35) and the one §5 of `docs/design-principles.md` names outright: "no
  gates detected" and "my own library is gone" must never look the same to a caller. The global
  gate's fail-loud does **not** cover it — that gate `exec`s the project gate *before* reaching its
  own library checks, and the project gate resolves this repo's copy rather than the installed one.

  - **Three load failures, one blocking exit 2** — absent, unsourceable, and sourceable-but-empty —
    each with a message naming which one it was and a remedy appropriate to a **tracked** file
    (restore it) rather than to an installed symlink (`baseline update`). The source's status is
    checked *and is not sufficient*: a sourced file returns its LAST command's status, so a zero
    says only that the last thing in the file worked. A **function probe** is what catches the
    truncated library that sources cleanly, exits 0, and defines nothing.
  - **A second site, the same missing-vs-corrupt bug.** The conditional bash-floor bootstrap tested
    only that `common.sh` *exists*, so against a truncated one it called `adb_require_bash` as an
    undefined command — `command not found`, its 127 discarded, and the floor left unenforced. It now
    probes for the function too, keeping the top-level call `check-bash-floor.sh --entrypoints`
    requires.
  - **`set -u` is relaxed across the source, and that is a fix rather than a loosening.** An unbound
    expansion while a library loads is fatal under `set -u` and kills the shell **outright** —
    measured at **rc 1**, which is neither a pass nor this gate's blocking 2, and which no `||` can
    catch because the shell is gone before the next word is read. The function probe decides instead.
  - **The real script now has a fixture** (`scripts/check-precommit-gate.sh`, cases 17a-17m). Every
    project-gate case before this substituted a purpose-built stub — right for measuring the
    hand-off, and never this repository's gate — so the fast subset D25 actually ships had no
    coverage at all. The fixture is a throwaway copy of the worktree re-`git init`ed as
    `main`, so the gate shells out to the real `build.sh` and the three real `check-*.sh`: a clean
    tree on a feature branch carrying a **committed** delta exits 0 with all four checks observed
    *PASSing* (the exit code alone cannot tell that from a gate that ran nothing), an edited practice
    file reddens the real `build-drift` and exits 2 naming it, and the global gate's hand-off is
    proven by output only the project gate can produce.
  - **Observed failing on the real superseded input**, not on a convenient one: run against a copy of
    the tree carrying the pre-fix gate, the new cases report **0** where they require 2 for both the
    missing and the truncated library, **1** for the unbound expansion — and every mutation harness
    refuses to prove anything rather than passing silently. **Five** in-suite mutations pin that
    permanently, one per repaired bypass, so no single blanket edit can make them all vacuous. Two
    of the five exist because an independent review found the corresponding assertions could not
    fail: the source-status guard and the bootstrap's function probe are each invisible to the exit
    code, since the load below supplies the same 2 either way.
  - The mutation harness itself moved to `scripts/check-lib.sh` as `check_mutate_line`, the home
    this repo's own law gives it, with `check-build-atomic.sh` — which established the discipline —
    now delegating to it rather than carrying a second copy.

- **The bash-floor carve-out is now executed instead of asserted: `check-bash-floor.sh --sub-floor`**
  (#310).

  D30 makes `scripts/lib/common.sh` permanently exempt from the bash 5.3 floor — it holds
  `adb_require_bash`, and a caller cannot reach that function until sourcing has finished — and D35
  extends that to `check-bash-floor.sh` and `check-lib.sh`. **Nothing executed that claim.** What
  existed was a `check-fact-drift.sh` rule asserting the *word* "parseable" still appears in the four
  documents explaining the carve-out and — stated precisely, because #310's own body omits it — a
  source scan in `check-bash-floor-guard.sh` for ONE construct (`${ command; }`) across all three
  files, with its own negative fixtures. That scan was real and is kept; what neither it nor the word
  pin could do is run the files under an old interpreter. Every CI job *launches* on a bash at or
  above the floor, so nothing ever did — and a 5.3-only construct outside that one spelling would
  have passed every job and then killed every entry point on a stock macOS with a syntax error
  instead of the gate's actionable message.

  - **Two rules, because the issue's own sketch is not sufficient — and that was measured, not
    assumed.** Against a real `/bin/bash` 3.2.57 and a real 5.3.15, `bash -n` rejects post-3.2
    grammar (`coproc NAME { … }`, `;&`, `;;&`, `|&`) anywhere in a file, but **accepts every
    construct D30 names**: `${ command; }`, `mapfile`, `declare -A`, `local -n`. So the mode also
    carries the source scan for 5.3 command substitutions (relocated from the guard, D54) and a
    **evaluation probe** that loads each of the three files under the old interpreter and requires
    it to come back silent — plus, for `common.sh`, `adb_require_bash` still reachable. The silence
    half is load-bearing:
    `declare -A` at the top level prints `invalid option` on 3.2 and still leaves the source status
    at **0**.
  - **The subject is the numerically oldest interpreter below the floor**, taken from the existing
    `adb_bash_candidates` / `adb_bash_version_at` / `adb_version_ge` primitives — not a hardcoded
    `/bin/bash`, not the first-listed hit (that list is ordered for finding a modern re-exec
    *target*, the opposite question), and not `sort -V`.
  - **It rides the bare invocation**, which is what makes it run: `selfcheck-macos` is the only
    per-PR job with a real 3.2.57, and the probes genuinely run under it there. Where a host has no
    interpreter below the floor — this repo's Ubuntu runner, though that is not a fact about Linux
    in general — the mode states a **SKIP**, names every candidate it probed with each version, and
    says outright in its PASS line that no parse happened. A stated skip beats a pass that did not
    check.
  - **What it does not claim, said in its own header:** a 5.3-only construct inside a *function
    body* that is neither new grammar nor a command substitution stays invisible to both rules.
    This proves parseability and gate reachability, not that every function behaves on 3.2.
  - **The workflow seam rule now covers both seams.** The static lint already failed a workflow that
    set `ADB_BASH_FLOOR`; `ADB_SUB_FLOOR_CANDIDATES` is the same class of bypass and is the sneakier
    one — pointed at a path that does not exist it leaves nothing below the floor, so the new half
    reports a SKIP and the job goes green with rule B disabled everywhere. It is not a substring of
    `ADB_BASH_FLOOR`, so the single-token grep would never have matched it.
  - **Observed failing**, per this repo's rule for new guards: **twenty** mutations of the
    shipped rules — including selection taking the first-listed candidate, the probe ignoring
    stderr or accepting a forgeable marker, candidate-version validation removed, the source scan
    narrowed back so the multiline spelling escapes, the SKIP claiming a parse it did not do, a
    broken interpreter reported as an absent one, and the fixture fence reduced to the lexical
    prefix test `..` walks through — each applied to a **copy** of the tree and each required to
    make `check-bash-floor-guard.sh` go red. Three of them exposed assertions that did not exist
    yet, which is the point of running them. The last three cover the async reviewer's findings on
    the PR: a usage-line strip that swallowed anything appended after it, `--sub-floor /` aliasing
    to the repo root, and an unencodable candidate path silently disabling both rules.

- **`check-gates.sh`'s elapsed assertion now tests the property it names, instead of a literal that
  was only ever true by luck** (#308).

  `scripts/check-gates.sh` pinned the exact string `gate "bfast": ok (0s)`. That value comes from
  `BASH_MONOSECONDS`, which counts **whole seconds**, so two samples straddling a tick differ by 1
  however little happened between them — and a gate of `true` legitimately reported `1s`. The
  assertion went red at random in a job that runs on every PR and on both hosted runners, on a claim
  it was not testing; under this repo's own CI-discipline rule every occurrence costs a diagnosis
  rather than a re-run.

  **Measured, not estimated.** Instrumenting a copy of the runner with `EPOCHREALTIME` puts the fast
  gate's timed window at **4-18 ms** (mean ~8 ms), and 16 busy spinners on a 10-core box moved the
  mean only to ~9.5 ms. Over a uniformly distributed clock phase that mean implies a straddle in
  ~0.8% of runs, about one in 125; #308 observed one in 400 by sampling. Sweeping the run's phase
  against the clock reproduces the failure on demand rather than waiting for either rate.

  - **The assertion is relational**: the fast gate's elapsed must be strictly less than the slow
    gate's in the same run, which is what *"timed independently, not cumulatively"* means. Detection
    is structural rather than probabilistic — with one shared `t0` the fast gate's window *contains*
    the slow gate's, so its figure comes back `>=` every time, for any sleep length.
  - **The fixture's slow gate sleeps 2.2s, not 1.2s, and that is load-bearing.** At 1.2s a
    cumulative timer reports `1s` for the fast gate — the same reading a legitimate straddle
    produces — so the bug and the flake are indistinguishable and no tolerant form of the assertion
    can separate them. A sanity pin requires the slow gate's own figure to read at least 2s, and an
    ordering pin requires the slow gate to run first — without the second, a reversed order would
    leave the fixture passing while testing nothing. The sanity pin never fires spuriously at 2.2s,
    but as a tripwire against a future edit shortening the sleep it is only probable (~80%), and the
    comment says so rather than claiming a proof.
  - **Determinism is bounded, not claimed.** A spurious failure now needs that ~10 ms window to
    inflate past a full second, >55x the worst observed under deliberate CPU oversubscription.

  All four assertions were **observed going red** against a `mktemp -d` copy of the tree: the real
  cumulative-timer hoist, a shortened fixture, an unreadable elapsed format, and a reversed gate
  order — which would otherwise leave the fixture passing while blind.

  `scripts/lib/project-gates.sh` is unchanged. Second resolution is adequate for a human-facing
  progress hint, and widening the clock to fix a test would be the wrong altitude.

## [2.1.0] - 2026-08-10

The release that made this framework's own guards answer correctly. Most of what it fixes is a check
that reported success without having checked: a release cut against an unverified branch, a build
published by truncating the file it replaced, an ownership decode a newline could re-aim. The rest
hardens the paths untrusted text travels — every API-supplied slug refused at its producer, a git ref
encoded into one path segment, the issue snapshot moved out of the world-writable temp directory.
New: `[gates.cadence]`, and an escape hatch for a repo whose CI never reports on the default branch.

### Fixed

- **A branch name containing `/` now reaches the endpoint it names — one shared builder encodes the
  ref, and the answer was measured rather than guessed** (#103, D53).

  `scripts/lib/repo-settings.sh` interpolated the branch straight into six API paths, so
  `release/v1` produced `branches/release/v1/protection` instead of one encoded path segment. #103
  deliberately blocked on an experiment, because the plausible guesses point both ways and shipping
  an encoding change verified only by reading docs risks breaking the path that already works.

  **The experiment, run read-only against branches that already existed** — no branch was created
  or pushed to learn this. On 2026-08-09 with `gh` 2.95.0, GitHub accepted **both** spellings on
  every endpoint this library reads — the ordinary branch GET (at one and two slashes, returning the
  same `.name` and sha for each spelling), `commits/{ref}/check-runs`, and both admin-only
  protection reads (the second of those at four slashes). The discriminator for the admin-only pair
  is the 404 *body*: a real slashed branch answers `Branch not protected`, a nonexistent control
  answers `Branch not found`. `GH_DEBUG=api` confirms `gh` normalizes nothing, so the answer is
  GitHub's. The three write verbs share those routes and were **not** exercised live — issuing a
  write to prove a route is not worth a mutation on someone's repository.

  **Both work, so encoding is a choice — and the slash is not the reason to make it.** Git forbids
  space, `~^:?*[` and `\` in a ref but allows `#`, `%`, `+`, `=`, `;`, `&` and any UTF-8. A raw `#`
  opens a URI fragment: `gh` was observed dropping it and everything after it, so
  `branches/feat/#42/protection` silently asks about `branches/feat/` — a wrong answer carrying a
  200, which is worse than the 404 a slash produced.

  - **`adb_url_path_segment` (new, `scripts/lib/common.sh`)** — percent-encodes one path segment via
    `jq @uri`. Not a shell character loop, and that is correctness rather than taste: bash's
    `printf '%02X' "'é"` yields the codepoint (`E9`, an invalid UTF-8 escape) in a UTF-8 locale and
    the first byte (`C3`) under `LC_ALL=C`, so a hand-rolled encoder is right on one runner and
    wrong on another. Deliberately **not** idempotent — a literal `release%2Fv1` is itself a legal
    git ref, so re-encoding it is the correct answer and a "don't double-encode" guard would quietly
    address a different branch. It fails closed: an empty return spliced into
    `branches/<here>/protection` yields not a broken URL but a *different valid one*. It also
    **checks its own fidelity**, because `@uri`'s input is not guaranteed to survive it — a git ref
    is a byte string while jq's `--arg` is a JSON string, so `rel\xffv1` would otherwise come back
    as `rel%EF%BF%BDv1`, a different unreachable branch, with a zero status. jq emits the round trip
    on a second line and a mismatch refuses.
  - **`_adb_rs_ref_path` (new, `scripts/lib/repo-settings.sh`)** — the one place a ref joins a path.
    Not `_adb_rs_branch_path`: one of the six sites is `commits/{ref}/check-runs`, a different
    collection, and a branch-only helper would have left exactly that one raw. The query string
    rides in an unencoded suffix, so pagination survives. The two printed `gh api` commands the
    non-admin path hands the operator carry the encoded path too.
  - **`--branch` takes a raw git branch name.** Encoding is the library's job; supplying `%2F`
    yourself now names a different branch.
  - **An exact `.` or `..` segment is neutralized.** `@uri` leaves dots alone, so `--branch ..` built
    `repos/o/r/branches/../protection` and resolved one level up — the traversal #218 refused for
    slugs, arriving through the ref door. A name that merely *contains* dots (`v1..v2`) is untouched.

  **What did and did not change on the wire.** A branch name made only of unreserved characters —
  every default branch this tool has ever been pointed at — is **byte-identical** through the
  encoder, pinned by a control that compares whole request lines and asserts no `%` appears in an
  ordinary run. A *slashed* name's request spelling does change, from `release/v1` to
  `release%2Fv1`; the measurement above is what makes that safe rather than a leap, since both
  address the same branch. So the honest claim is not "nothing changed" — it is that nothing an
  existing caller sends changed, and the one spelling that did was measured first.

- **`scripts/build.sh` publishes a generated file by rename, so an interrupted build can no longer
  leave a truncated tracked one** (#268, D52).

  `render()` wrote the three root docs with a plain `} > "$outfile"`, which truncates the
  destination before the first byte is written. `^C`, a full disk or an OOM kill therefore left
  `agents/claude/CLAUDE.md` half-rendered in the working tree — and nothing announced it: the next
  `build-drift` reports *drift*, not corruption, so a contributor who commits before noticing ships
  a half-rendered root doc. The skill renderer in the same file had done temp-then-`mv` since it was
  written, with a comment explaining exactly why. That asymmetry is what this closes. It also
  matters live: `install.sh` symlinks each agent's own root doc at that path —
  `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md` — so the truncate window was
  visible to a running agent session reading its own root doc.

  **A rename needs three things the truncate did not**, and all three are in the diff rather than
  inherited silently. Both renderers now call one shared `build_stage` / `build_publish` pair, so
  there is one write rule rather than two copies of one:

  - **a unique per-process temp** (`mktemp "$dest.tmp.XXXXXX"`), not a fixed `$dest.tmp`. A fixed
    sibling name is not merely untidy: two builds over one checkout — a contributor running
    `build.sh` while selfcheck's `build-drift` step runs one — share it, and the interleaving
    *publishes* a torn file rather than preventing one (A stages, B clears the name and stages its
    own, A renames B's half-written file over the destination). `mktemp` also closes a hole a fixed
    name cannot: clearing a path and opening it are two operations, so anything installing a symlink
    in between is followed by the redirect and then renamed over the tracked file. O_EXCL under an
    unpredictable name leaves no window and no symlink to follow.
  - **an `EXIT` trap**, because publishing through a temp means an abort leaves one — and
    `.gitignore` does not cover it, `build-drift`'s untracked scan looks only under the skill trees,
    and `check-tmp-paths.sh` is a content scan a well-formed render fragment passes. A **bare** EXIT
    trap is enough, and that is measured, not assumed: on bash 5.3.15 it runs for SIGINT delivered
    the way a terminal delivers it (to the process group), for SIGTERM and for SIGHUP, and the
    script still exits 130 / 143 / 129 by itself — so the hand-written INT/TERM/HUP handlers that
    would have re-raised to preserve that status were declined as a way to get it wrong. SIGKILL
    stays untrappable, and there the residue is the correct outcome: the tracked file is intact.
  - **an explicitly chosen mode.** `mktemp` creates 0600 and the truncate-and-write it replaces
    inherited the destination's, so publishing straight from the temp would silently narrow every
    generated doc — while taking the umask instead lets a permissive one produce group- or
    world-writable *instruction* files. That is demonstrated, not hypothetical: the new suite run
    against the pre-#268 code reports `-rw-rw-rw-` under `umask 000`. Git records no difference
    among non-executable modes, so nothing here would ever have noticed. `chmod 644` is the only
    value that does not depend on ambient state.

  All three reach the skill renderer too, because #268's stated aim is that the two write paths stop
  disagreeing about a hazard they both face; hardening one would have re-created the asymmetry
  pointing the other way.

  **What this does NOT do: retire `build-drift`'s serial prologue.** Each file is now unobservable
  half-written; the transition *across* files is still not atomic, so a reader that starts mid-build
  sees a **mixed generation**. `scripts/selfcheck.sh`'s concurrency-contract header said the
  opposite of the new code and is corrected in place; D37 and this file's #260 entry are dated
  records of what was true then and are left alone.

- **`scripts/check-build-atomic.sh`** (#268) — the guard for the above, and it is observed failing:
  run against the pre-#268 `build.sh` the suite goes red, and what it prints is the truncated root
  doc itself. `build-drift` could never have caught this — a *successful* build is exactly where the
  two write shapes are indistinguishable, and it runs against the tracked tree, so it cannot inject
  a failure without damaging the checkout it is checking. This faults a copied `build.sh` mid-render
  inside a `mktemp -d` fixture (a directory named like a practice, so the fault fires as any uid —
  a `chmod 000` file would be readable by root and silently not fire) and requires the destination
  to survive **byte-exact**, compared with `cmp` rather than `[ "$(cat f)" = … ]`, which strips
  trailing newlines and so cannot see a dropped final one. Three mutations — the naive publish, a
  fixed temp name, the trap removed — each required to make the assertion above it go red, and each
  verifying its own edit applied so a sed that stopped matching fails loud rather than turning three
  proofs into assertions about unmodified code. Pooled in
  `selfcheck.sh`, a step on CI's existing `build-drift` job — not a new job, which would be a
  branch-protection context `required-drift` then reports as gating nothing.

- **Every API-supplied slug is refused at its producer before it can reach a request path — and
  there were four producers, not one** (#218, D51).

  #175 added `adb_is_path_safe_repo_slug` because `adb_is_repo_slug` answers a *shape* question
  that is necessary and not sufficient once a slug is concatenated into a path: `a/..` is a
  well-formed `owner/repo` pair **and** a path traversal. Only `pr-watch.sh head_anchor` used it.
  `repo-settings.sh` built seven `repos/$REPO_SLUG/...` paths and `release-convention.sh` ten, none
  validated — and four of `repo-settings.sh`'s are **writes**.

  The issue proposed one chokepoint, `adb_repo_slug`. That is right for `release-convention.sh`,
  whose ten sites all descend from the single checked assignment in `require_gh` — and it reaches
  `repo-settings.sh` not at all: to save a round trip that module takes its slug from the
  `.full_name` of the repo object it already fetches, so it needs its own boundary in `repo_json`.
  Hardening only the shared getter would have left the module that decides whether **auto-merge may
  be armed** exactly as it was, while looking like the fix.

  **Two more producers sit outside `scripts/lib/`, which is why a sweep of that directory reported
  none.** `.claude/skills/release/release.sh` has its own `slug()` — now validating, with its three
  `sl="$(slug)"` consumers checking the result instead of inheriting an empty one. And
  `base/workflows/roadmap.md` resolves `nameWithOwner` at **six** places and interpolates it into
  `repos/$REPO/...`; that one is prose an agent pastes into a shell, so it cannot source a library
  and the rule reaches it as `roadmap-lib.sh slug-ok` — a thin delegate to the same predicate,
  never a restatement of the charset rule in Markdown. `check-roadmap.sh` pins that it agrees with
  `adb_is_path_safe_repo_slug` case-for-case, and that the guard count still equals the read count.

  **Each module keeps its own exit code**, because "fail closed with code 20" is not a rule this
  repo has: `automerge-ok`, `merge-flag` and `required-drift` map a `repo_json` failure to 20,
  while `apply` and `status` map it to 1. In `release-convention.sh` the slug is resolved by
  `require_gh`, so all three subcommands surface it as that function's `exit 1` — the module
  reserves 2 for usage and argument errors, and this path is not one. Both new guards therefore
  return the module's *existing* failure, and emitting a uniform 20 would have given `apply` a code
  its contract does not define.

  **Validated before the cache is committed, in both.** Each getter is memoized behind `[ -z … ]`,
  so assigning first and rejecting after would fail the first call and then return **0** with the
  rejected slug on the second. The diagnostic renders the value through the new
  `adb_display_value` (`%q`) rather than echoing it: the values this guard rejects are by
  construction the ones that may carry a newline, and printing one raw lets it forge the log line
  after it — re-opening in the operator's output the hole the check just closed.

  Regression tests per module in #175's style, plus the two assertions that catch the plausible
  wrong fixes: that a rejected slug is **not** cached, and that **exactly one** request was issued
  (the read the slug itself came from) with none built from the bad value. All six mutations —
  removing each guard, reordering each cache, and disabling the escaping — were **observed going
  red** against a throwaway copy, each on its own assertion. `repo_json`'s ordering is pinned
  **structurally**, because no caller can observe it today (verified: that reorder leaves the suite
  green at 380/380) and a property whose inversion is silent is exactly the one that rots.

- **The issue snapshot leaves the shared temp directory for `{{STATE_DIR}}`, and a lint keeps it
  there** (#250, D50).

  `/implement-issue` step 2 wrote `gh issue view` and the `author_association` label #214 added to
  `/tmp/issue-<n>.json` and `/tmp/issue-<n>.assoc`, then read them back in step 3 and again in step
  8. That directory is world-writable, shared by every checkout and every worktree on the host, and
  both names were fully determined by a **public issue number**. So two runs on one issue — two
  clones, two worktrees, two agents — shared both files and the second run's `>` truncated the
  first's snapshot mid-run, with **no attacker required**. The minutes between the write and the
  read were also a TOCTOU window on a **trust signal**: replace the `.assoc` and the dispatched
  agent is told a stranger's text carries maintainer standing.

  Both files now live in `{{STATE_DIR}}` — repo-relative and per-agent (`.<agent>/state`), which is
  exactly the boundary `implement-lib.sh admit` already enforces (#202). **Flat, never a
  subdirectory**: `state-scan` enumerates only regular files directly under the state directory, so
  a tidy `issues/` would have been invisible to `/cleanup` and to `admit` alike.

  **Moving it meant giving it a lifecycle, not just a new path.** `cleanup-lib.sh state-scan` gains
  an `issue` kind (`issue-<digits>.{json,assoc}`, digit-only for the same allowlist reason the
  `threads` arm is), `state-verdict` gains an `issue` name that **shares the `gaps` arm** because
  the same two liveness signals decide both — a pre-marker run holding the claim, and a marker
  describing a live run — and `implement-lib.sh`'s clear takes the family so the containment
  invariant holds. `base/workflows/cleanup.md` sweeps it. Registering the scan arm without the
  clear would have recreated the #264 trap; registering neither would have left private issue
  bodies as permanent `other` debris.

  The two are **not** interchangeable, and the difference is load-bearing in two places. The
  snapshot is read again in step 8 while the gap artifacts are finished with after step 4, so the
  sweep asks with `$RUN_NOW` — the fresh re-scan — where `gaps` asks with `$RUN`, or a run that
  reached step 5 mid-sweep would have its issue text deleted from under its own review dispatch.
  And the clear matches the scan arm's digit rule **exactly** rather than widening to `issue-*`:
  this state directory is shared (`new-release.json`, `threads-<N>.json` live there too) and
  `issue-` is a prefix any future skill might pick, so the "widening is always safe" rule that
  holds for `gaps-*`/`review-*` does not hold here.

  A **latent bug on the read path** is fixed in the same change: both `.assoc` reads nested
  `$(cat …)` inside a `jq --arg`, and a command substitution in argument position discards its
  status — so a missing or unreadable label left `--arg assoc ""`, `jq` succeeded, and the
  surrounding `||` never fired. The provenance annotation went out silently blank. It is its own
  statement now, and an empty value is refused.

  `scripts/check-tmp-paths.sh` is what stops the drift. Every snapshot path is read **out of the
  real markdown** — source and every rendered skill — and required to sit under that file's own
  state directory, with both halves present in each; then two simulated checkouts write a sentinel
  through the path the skill actually specifies and each must read its own back, which is #250's
  acceptance criterion executed rather than described. A third part forbids any fixed shared-temp
  literal without per-run entropy under `base/`, `scripts/`, `docs/` or `agents/`, and thirteen
  mutations against a copy of the tree require every one of those to go red.

  **That last part is lexical, and its limits are written into its header rather than left to be
  discovered**: it cannot see a path built through a variable, cannot tell an unexpanded `$$` in
  single quotes from a real one, and flags reads as well as writes on purpose — `adb-tmp-ok:
  <reason>` is the intended answer for a legitimate fixed path, not a grudging exception. Within
  those limits the entropy rules are a parse rather than a substring test: `$RANDOM` counts only as
  a whole parameter (so `$RANDOM_SUFFIX`, which the shell reads as a different and probably-unset
  name, does not), and `XXXXXX` counts only where a real `mktemp` precedes it on the
  comment-stripped line.

  **Moving the snapshot into the repo needed a matching `.gitignore` change**, which is the one
  exposure the move itself created — in a shared temp directory the file could never be committed.
  `bin/agent-init` ignored `.claude/state/` alone, so a Codex or Gemini run left the untrusted issue
  body untracked in the working tree, one `git add -A` from being committed. It now derives the set
  from `agents/<token>/` and ignores every rendered state directory; and because that only helps
  repos initialized from now on, step 2 **refuses to write** unless `git check-ignore` confirms the
  exact file shapes it is about to create are ignored.

  It also fixes the remaining instances of the class it defines: `create-issue.md`'s issue-body
  scratch, `git-and-prs.md`'s recommended `.patch` copy (a fixed name for the one file git cannot
  get back — and it now **prints** the path, since a backup you cannot name is a backup you do not
  have), `docs/roadmap-acceptance.md`'s determinism procedure, and `check-injection.sh`'s coupled
  fixture. The two prose fixes also stopped masking their own exit status behind their cleanup.

  **What is claimed is collision isolation, and no more.** A process that can already write the
  run's state directory can still replace the label; leaving the shared namespace removes reach,
  not the need for integrity. `check-release-skill.sh`'s `$$`-suffixed files were surveyed and
  **left alone** — the acceptance criterion names `$$` as a valid per-run spelling, so they were
  never the defect, and `selfcheck.sh`'s note saying otherwise is corrected rather than acted on.

- **The wall-clock bound reaps the whole process group on both paths, and a dispatched agent's log
  is capped at the source** (#141, supersedes #123, D49).  <!-- adb-claim-ok: #123 was closed NOT_PLANNED as SUPERSEDED by #141, which consolidated it; the reference is this change's provenance, not tracked work -->

  `adb_run_bounded` (`scripts/lib/common.sh`) had two paths that agreed on **status** and diverged
  on process **cleanup**. GNU `timeout` puts the child in its own process group and signals the
  group; the portable watchdog signalled a single PID. So on a stock Mac — no `timeout`/`gtimeout`
  on a non-interactive PATH, i.e. the exact host the fallback exists for — a **grandchild outlived
  the bound**: `wait` returned, the caller got its 124, and the orphan kept running. Reproduced
  with a child that traps TERM and blocks on a grandchild: watchdog `alive`, timeout binary `dead`,
  both rc 124, so no caller could tell them apart. At `currency-lib.sh`'s 120 s bound on a
  `git fetch`/`git pull` that orphan went on mutating a clone *after* the update was reported
  failed — able to move HEAD or hold `.git/index.lock`.

  **Both paths own that guarantee now, rather than trusting `timeout` for it.** The first cut
  asserted the two agreed about grandchildren because they did on macOS — and CI disagreed: on
  `ubuntu-26.04` the identical probe left the grandchild **alive** on the `timeout`-binary path.
  Rather than reverse-engineer which coreutils build reaps what, that path also runs under `set -m`
  (so `$!` is a real pgid) and sweeps the group with SIGKILL after the wait. The sweep is
  **conditional on the bound having fired**: a command that finished on its own may have
  deliberately left something running, and killing that would turn a bound into a reaper of
  successful work — a property with its own regression case.

  The watchdog now borrows job control for exactly one command — `set -m`, the `&`, then restore
  whatever `$-` said the caller had — so the child leads its own group, and both the deadline and
  `_adb_bounded_reap` signal the **group** and then the bare pid. `setsid` is not the mechanism; it
  is absent from stock macOS. This is `scripts/selfcheck.sh`'s existing `_cleanup` rule, `-0` guard
  included (`kill -- -0` would signal the operator's own shell); that pool solved the same problem
  one level up and its header had cited #141 as the open case.

  One consequence needed its own fix. Under a caller that already has job control, plain `wait`
  returns when a job merely **changes status** — measured returning **145 in 0 s with the child
  alive and running** — and a naive re-wait loop **spins** (51 iterations in 0 s). Putting the
  child in its own group makes that reachable without an operator `^Z`, since a background group
  reading the terminal takes SIGTTIN. `wait -f` answers it, on **both** paths (with job control on,
  bash puts the `timeout` binary in its own group too, so it was never watchdog-only).

  `-f` is gated on **two** conditions, and the second is not redundant: the caller had job control
  on, **and** the interpreter is bash 5.1+. The tempting single condition — "anything old enough to
  lack `-f` has job control off" — is simply false. Bash 3.2 supports `set -m`, so a 3.2 caller
  reaches that line with job control on, and an unguarded `wait -f` there fails with
  `invalid option` and status **2**, which would be returned as the child's status while the child
  ran on. Verified on Apple's `/bin/bash` 3.2.57. Below 5.1 the caller keeps the pre-#141 behaviour
  rather than a broken one, and D30's "`common.sh` stays usable below the floor" holds because the
  capability is *checked*, not assumed.

  On top of that, `role-dispatch.sh` now caps the log stream it captures from a dispatched agent.
  Nothing bounded it: one gap-analysis run wrote 674 KB, the run that implemented #84/#106 wrote
  428 KB, and the run that implemented *this* issue wrote **766,399 bytes**. `/cleanup` sweeps those
  artifacts *between* runs (#84); a single run's stream was still unbounded.

  ```
  ADB_DISPATCH_LOG_MAX_BYTES   default 262144 (256 KiB) · 0 disables · invalid warns and falls back
  ```

  Four choices the issue deliberately left open, and how they were settled:

  - **Every agent and every role.** `review.err` is the same stream from the same code path with
    the same growth, and a review slot is dispatched by bare *token*, which carries no role to key
    a policy off. It lives in `role-dispatch.sh` — one consumer, and `common.sh` must stay
    parseable below the floor (the `cpu_count` precedent).
  - **A head cap, on evidence.** Keeping the tail was the recommendation; measurement rejected it.
    codex's final message is captured separately by `--output-last-message`, and on the 766 KB
    stream that message was found duplicated at byte 758,388 — the tail is the one part already
    preserved in full elsewhere, while the head carries the CLI version, model, reasoning effort
    and session id that nothing else records.
  - **The cap bounds the agent's stream, not this helper's own lines.** `/implement-issue` is told
    to read the classified `role-dispatch:` line at the *tail* of `gaps.err`; a cap that included
    it would bound the file by deleting the one line saying why the dispatch failed. Those lines
    are O(1), so the file is bounded by `cap + a small constant`.

    Stated plainly because it is a **deliberate deviation from the issue's wording**: the
    acceptance criterion says "`gaps.err` cannot exceed the cap", and by this reading it can, by a
    few hundred bytes of our own diagnostics. Bounding the *unbounded* thing is what the change is
    for; deleting the diagnosis to satisfy the letter would make the artifact smaller and useless.
    (One place where "small constant" was not true has been fixed: the invalid-value warning echoed
    the rejected environment value in full, so a 5 KB `ADB_DISPATCH_LOG_MAX_BYTES` put 5 KB into the
    artifact the knob exists to bound. It is truncated now.)
  - **A process substitution, not a pipeline.** A pipeline puts the left side in a subshell, and
    `adb_run_bounded` installs its reap trap on the *calling* shell — the trap would guard a
    subshell that is not the one being signalled. The filter also **drains** past the cap rather
    than exiting, or the agent's next write takes SIGPIPE and capping a log would kill the
    dispatch it was only meant to trim.

  The filter is **`dd bs=1` plus `wc -c`**, and both alternatives were tried and rejected. `head -c`
  over-reads into its buffer, so it loses an unknown number of bytes and can swallow the whole
  remainder — leaving the drain to see EOF and report a clean pass on a stream it silently
  truncated. **`awk` shipped here first and was replaced after review**: being record-oriented it
  does not act until it sees a newline, so a newline-free stream (a `\r` progress feed, one very
  long line) buffered whole — emitting none of the promised head bytes while the agent ran, and
  growing without bound, so an indefinitely noisy stream could OOM the filter and SIGPIPE the very
  agent it was meant to protect. It was also not binary-safe: BSD awk on macOS treats a NUL as
  end-of-string, so `ab\0cdef…` emitted `ab`, dropped the remainder, and printed *no* cap notice —
  on macOS only.

  `dd bs=1` has none of those properties. It reads exactly `max` bytes (so the drain's count is
  exact, not approximate), holds one byte at a time (flat memory on any input), writes as it reads
  (the head streams live), and is byte-transparent (a NUL passes through instead of ending the
  stream). Measured: **0.21 s** for a 256 KiB cap, and a 5 MB newline-free stream in **0.23 s**
  with flat memory. `wc -c` is both the drain and the count, so "was anything discarded" and "how
  much" are one read and cannot disagree. A NUL, a CRLF line and a newline-free stream are all
  fixtures in the suite.

  One more hang had to be closed, and it was one the cap itself **introduced**. Closing our write
  end is not the same as closing the pipe: if the agent leaves a background descendant that
  inherited its stdout/stderr, that descendant still holds the write end, the filter never sees
  EOF, and waiting for it blocks **forever** — after `adb_run_bounded` has already returned, so its
  bound no longer applies and nothing else would ever stop it. An agent that starts a dev server
  would wedge the dispatch. The drain is now bounded (`ADB_DISPATCH_LOG_DRAIN_SECS`, 10 s), ticked
  rather than slept in one go so it leaks no orphan, and it says why the log ended early instead of
  truncating in silence.

  Coverage was **observed failing** against a copy of the pre-fix tree: the watchdog grandchild
  (`alive`→`dead`), the stopped child (`rc=145`→`rc=0`), and ten cap assertions. The
  timeout-binary grandchild case is green on both sides and is labelled an agreement pin rather
  than a regression detector.

  Self-review then found four defects in the above, all fixed here and worth naming because three
  of them are the failure mode this repo keeps paying for — a guard that cannot answer wrong:

  - **The `-0` guard did not stop `-00`.** `case "$p" in ''|0|*[!0-9]*)` rejects the string `0` and
    not the string `00`, and `kill -- -00` resolves to process group **0** — the caller's own shell
    and everything in it, i.e. exactly what the guard exists to prevent. Both are now arithmetic
    tests. `common.sh` had already been bitten twice by zero-padding defeating a literal arm (the
    `secs` and `grace` clamps each say so); this is the same class where the cost is the session.
    **`scripts/selfcheck.sh`'s `_cleanup` carried the identical gap in both of its loops** — it is
    where the rule was copied from — and is fixed in the same change rather than filed.
  - **The `timeout`-binary path shared the stopped-child exposure.** With a caller's job control
    on, bash puts `timeout` in its own process group too, so `wait` could return early there as
    well. `had_m` is now read once at the top of the function and both `wait`s use it.
  - **The awk cap could pass through nothing.** A stream that emits no newline before the cap — a
    `\r` progress spinner, or one very long line — hit the cap on record 1 and emitted zero bytes,
    discarding the provenance header the head cap exists to keep. It now cuts that first line with
    `substr`, so the knob is a byte cap as its name says.
  - **Two test defects.** `rd_var` did not `env -u ADB_DISPATCH_LOG_MAX_BYTES`, so the
    default-pin assertion could be defeated by the operator's own environment — the exact bug the
    comment two lines above it warns about. And the "`0` disables" assertion compared a file
    against a variable read from that same file, which is a tautology; rewritten against the capped
    run, it now goes red pre-fix (`176022 vs capped 176022`) where before it passed.

### Changed

- **CI runs every job once per ordinary branch update, and required-check drift hard-fails only
  where it is a fact** (#165, supersedes #99, D48). <!-- adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work --> (Once per *update* rather than "once per head
  SHA" — reopening a PR or re-running a workflow can still produce a second run of the same SHA;
  what is gone is the automatic duplicate from two triggers firing on one push.)
  `.github/workflows/ci.yml` triggered on unfiltered `push:`
  *and* `pull_request:`, so a same-repo branch fired both events and every job ran twice — measured
  live on PR #296 as `total=54 distinct=27`. Branch protection matched by context name so it still
  gated correctly; the cost was a straight doubling of CI minutes on every push.

  ```yaml
  on:
    push:
      branches: [main]
    pull_request:
  ```

  Narrowing `push:` does **not** perturb check discovery — `_adb_rs_file_verdict` inspects only
  `pull_request`/`pull_request_target` triggers — and this was verified rather than assumed by
  running the real discovery over a before/after pair: 27 contexts either way, byte-identical.

  That filter is what let the `required-drift` step be **split by event** instead of patched.
  `required-drift` discovers jobs from the checked-out tree and reads required contexts from the
  default branch, so on a push to `main` its answer is a **fact** and on a PR it is a **prediction**
  about a merge that has not happened. #122 hard-failed on both, and the only way to make the
  introducing PR green was `baseline repo apply` from the PR branch — which requires the context on
  `main` before the job exists there. Abandon that PR and `main` is left requiring a context nothing
  will ever report, blocking every merge until an admin prunes it. So the `push` arm keeps the hard
  failure and the `pull_request` arm now **advises**, via a `::warning` and a job summary.

  **This gives something up, and it is not a wash:** a PR can now add a red, non-required job and
  merge. The backstop is the push arm going red the moment it lands, so the exposure is "merged but
  not yet applied" rather than "never caught" — #165's explicit acceptance criterion, not an
  oversight. **Only a proven `14` is softened**; a `20` (unreadable live state, or a workflow file
  #102's parser could not read) still fails the PR.

  The old `github.ref == refs/heads/<default>` disjunct in that step's `if:` is deleted, since
  `event_name == 'push'` now already means the default branch. **Deleting it alone would have been a
  bug** — it leaves one PR-only step and removes every hard failure in the file — which is why this
  shipped as a split rather than the deletion the issue described.

  One consequence worth stating: `branches:` excludes **tag** pushes, so a `v*` tag no longer runs
  `ci.yml`. Nothing depended on it — `wsl-smoke.yml` carries its own `push: tags: ['v*']`, and
  `/release` verifies the merge commit is green *before* it pushes the tag.

### Added

- **`repo-settings.sh required-drift --porcelain`** (#165, D48) — same exit codes, but stdout
  carries only the drifted context names, one per line, with no prose and deliberately **no
  remedy**. The advisory CI arm needs the names; what it must not do is echo the human code-`14`
  text, which ends in `baseline repo apply` — right on the default branch, and exactly the
  instruction that strands a phantom context when followed from a PR branch. The four other read
  subcommands **reject** the flag rather than accept it inert.

  The library stays read-only: the advisory surface (`$GITHUB_STEP_SUMMARY`, a `::warning`) is
  written by the workflow *step*, and neither needs any permission beyond the `contents: read` the
  workflow already declares. `check-repo-settings.sh` pins the wiring **structurally** — it counts
  the call sites, compares each arm's `if:` for equality, and parses the `push:` branch filter into
  entries — because swapping the two `if:` conditions leaves every pinned literal in place while
  inverting the entire design. It then **executes** the advisory step's shell under `bash -e`,
  which is the only check that could catch the arm shipping as `…; rc=$?`: GitHub runs a Linux
  `run:` step as `bash -e {0}`, and `set -uo pipefail` does not clear errexit, so the step would
  have died at the capture with exit 14 — hard-failing the PR while every static assertion passed.

  A job `name:` is branch-authored free text and reaches two surfaces that interpret it, so both
  are escaped: the annotation applies the `actions/toolkit` `escapeData` rules (`%`, CR, LF), and
  the job summary emits names in an **indented** code block rather than backtick spans, which a
  name containing a backtick can close to inject rendered Markdown into a page a maintainer reads.


- **`[gates.cadence]` — a gate can declare WHICH CALLER it runs for** (#240, D47). The Stop hook
  fires at the end of every turn, including turns that edit nothing, so a `test` gate pointed at a
  repo-wide CI mirror re-ran CI after every message. `[gates.scope]` could not express the
  difference — a repo-wide suite legitimately matches almost any changed path — and the only
  documented escape was forking a whole gate script to state one scheduling fact.

  ```toml
  [gates.cadence]
  test = "full"      # always (default) | full | turn-end
  ```

  `adb_run_gates` now takes a context (`turn-end` | `full`, default `full`); a gate runs iff its
  cadence is `always` or matches the context. **A repo with no `[gates.cadence]` table runs the
  same gates and exits the same way in both contexts** — the output does change, since a passing
  gate now prints an elapsed line where it printed nothing before. An *unrecognized* value warns
  and **runs** the gate: a typo must never quietly disable enforcement, since a gate that stops
  running looks exactly like one that passed (#35).

  **One of #240's acceptance criteria is deliberately not met**, and is called out rather than
  quietly dropped: *"a gate that exceeds the hook timeout → the hook terminates it, exits with a
  classified status, and the operator sees which gate was killed."* That cannot be built as
  written — the 240s bound belongs to the Claude harness, which cancels the hook, and a cancelled
  process cannot then report its own status. A separate **inner** deadline is a different feature
  (it could not reuse `adb_run_bounded` unchanged, whose macOS grandchild limitation an arbitrary
  `sh -c` gate would hit, and per-gate bounds leave the total unbounded anyway). The issue's own
  open question asks for that to be split out once diagnosed; it is now diagnosed and split out.
  The 18m55s that motivated it does not reproduce (#260/D37), so cadence answers the cost and
  elapsed reporting answers attribution.

  The value is `full` rather than `pre-push` on purpose: nothing in this framework wires an
  automatic pre-push hook, so `pre-push` would have named a guarantee the gate model cannot make.
  It means "excluded from the per-turn Stop hook, included in a full run".

  Every gate that runs now also reports its **elapsed seconds**, and every skip reports its
  reason, so a slow or absent gate is attributable without a stopwatch.

### Fixed

- **A Stop-hook gate blocked one session's turn on another session's tree** (#241, D47).
  `precommit-gate.sh` decided whether to gate purely from git state, which carries no session
  identity. Two sessions sharing a checkout is routine, and the session that was merely *talking*
  ran the full suite over the other's mid-edit work at every turn-end — and, because a red gate
  exits 2, **could be blocked from ending its turn by code it did not write**. Observed twice on
  2026-07-31; the second time the bystander was instructed to rebuild and commit nine generated
  files belonging to another session.

  The gate now no-ops when a run marker **for the current branch** is owned by a **different**
  session, reusing the promoted `adb_owners_compatible` in `common.sh` rather than growing a
  second comparator. Two details are load-bearing:

  - **The check runs before the project-gate `exec`.** That second incident reported
    `build-drift FAIL` — a check name in this repo's *own* project gate — so a check placed after
    the delegation would have missed the exact case the issue documents.
  - **Identity comes from `$CLAUDE_CODE_SESSION_ID` only, never the hook payload on stdin**, because
    the `exec`'d project gate inherits that fd and the docs promise it does.

  **Every unknown keeps blocking**: no marker, a marker for another branch, a malformed or
  ownerless marker, no `jq`, or no session id. Suppressing on unknown ownership was the issue's
  own suggested direction and is not what shipped — it would make the gate advisory for nearly
  every ordinary dirty tree. Mutating the implementation that way turns seven pre-existing
  fail-loud assertions red, including the #35 regression tests.

  Narrower than the issue title, and stated plainly: this covers a foreign tree whose writer is
  running `/implement-issue` on that branch. A session editing the tree without a tracked run
  leaves no ownership evidence anywhere in git, so a bystander is still gated there. **A marker
  also stops being evidence after 2h30m** (`ADB_MARKER_STALE_SECS`), because a crashed run would
  otherwise leave its branch un-gated for every later session indefinitely — and a repo that also
  declares its gates `full` would then have no turn-end enforcement at all. A long-running run
  that goes that long without a phase change simply stops sparing bystanders, which is the
  enforcing direction. The marker records who *started* a run, never who wrote the changes now in
  the tree, so the skip message says only that.

- **A newline inside a marker field re-aimed the ownership decode, toward switching the gate off.**
  Found in self-review, before the new check ever shipped. Reading `.branch` and `.owner` as two
  newline-separated values means a newline *inside* either one shifts the decode — and both
  directions failed toward suppression: an owner of `<my-id>\nBBBB` decoded to a truncated
  `<my-id>` that no longer matched me, and a branch of `feat\nevil` still matched `feat` on its
  first line while replacing the real owner with `evil`. The decode now goes through `@tsv`, which
  escapes both delimiters so no field can shift, and a decoded owner is additionally required to
  *look* like a session id — corruption is evidence of a broken marker, not proof of a second
  session, and only proof may suppress. Same class `implement-issue-gate.sh` already pins for its
  own decode (#180).

- **An empty middle field silently shifted every gate record** — found while adding cadence, and
  worth recording because the failure was invisible. Tab is an IFS *whitespace* character, so
  `IFS=<tab> read` collapses runs of tabs and drops empty middle fields. That was harmless while
  `scope` was the last field; the moment `cadence` was appended, a gate with no `[gates.scope]`
  parsed as `scope=<cadence>, cadence=<empty>` — and an empty cadence matches no context, so
  **every gate was skipped in every context**. `awk -F` does not collapse, so `status` kept
  printing the right answer while `run` ran nothing. Records are now split by explicit parameter
  expansion (`_adb_rec_split`), which cannot collapse regardless of which fields are empty.

- **The closing-keyword verification added in #295 could never succeed, so it halted every
  `/implement-issue` run at its last step.** `gh pr view --json closingIssuesReferences` returns a
  nested repository object shaped `{id, name, owner:{id, login}}` — `--json` selects *top-level* PR
  fields, and `nameWithOwner` is not among the nested ones. The guard's
  `select(.repository.nameWithOwner == $slug)` therefore compared `null` against the slug for every
  entry, produced an empty link set, and reported *"the closing keywords did not register"* on a PR
  whose body was perfectly correct.

  Found by running it: this PR's own step 10 failed the check while GitHub had already computed the
  link set as `[202]`. The slug is now rebuilt from `owner.login + "/" + name` — which is exactly
  what `roadmap-lib.sh pr-targets-issue` has always done with the same field
  (`scripts/lib/roadmap-lib.sh:206`), and which the snippet's own comment cites as its precedent. The
  guard had the right idea and the wrong spelling, one module away from the correct one.

  The same run surfaced a second cause of a false empty: **GitHub computes the link set
  asynchronously**, so a read issued immediately after `gh pr create` legitimately comes back empty.
  The guard now retries briefly before believing an empty answer — a body that really is wrong stays
  empty through all of them.

- **A second `/implement-issue` run in one checkout deleted the first run's live state before any
  ownership check could see it** (#202, D46). Preflight `rm -f`'d the run marker, the blocked
  marker and the gap-analysis lock **unconditionally**, so *starting* a run was itself the
  destructive act: session B's preflight removed session A's live marker, after which A's Stop hook
  found nothing and exited 0 — the no-stop-until-PR invariant silently off for a run that still
  needed it. The same clear released A's live `gap-analysis.lock`, and a concurrent `/cleanup` then
  classified A's `gaps.md` and `gap-prompt.txt` as a finished run's leftovers and deleted them
  **mid-dispatch**, losing the findings of a 10-minute pass. #180 gave the marker an `owner` so the
  hook refuses to act on a foreign one; it never gets the chance if the marker is already gone.

  **The decision is to refuse a second run, not to accommodate one.** Two runs in one checkout share
  ONE HEAD — they fight over the checked-out branch whether or not their state files collide — so
  the per-run-path sketch in the issue would have made the state layer safe for a configuration that
  still cannot work. Preflight now calls the new **`scripts/lib/implement-lib.sh admit`**, which
  refuses unless the existing marker is *provably stale*, and the run holds a **claim** until step 5
  writes the marker that supersedes it.

  Three properties are what make it a fix rather than a different failure:

  - **Admission is single-threaded**, inside a `mkdir` lock on the state directory: one contender
    decides, every other is refused having touched nothing. That replaced three rounds of making
    each individual step safe, each of which looked sufficient — `rm -f` + re-create let two
    breakers win; a `rename` made the move exclusive but not its *operand*, so a delayed breaker
    took a successor's brand-new claim (three winners); verifying the operand and re-reading our own
    token after acquiring still left the real hole, which **macOS CI found**: a losing breaker
    *moves* the claim before it can know whose it is, and a third contender acquires in the few
    syscalls while the path is free — after the first run has already passed its re-read. A window
    that opens behind you cannot be closed by checking afterwards.

    The lock is held for the duration of `admit` only (sub-second plus at most one `gh` call), never
    for the run, and is **broken on age at 5 minutes** so a killed admission cannot block a
    checkout. The per-step guards are kept as defence in depth, because `release` runs outside the
    lock from another process: the claim is still published create-or-fail as a *complete* file
    (`link`, not `set -C` + `>`, which leaves a window where it exists and is empty), and removals
    still verify identity rather than trusting a pathname.
    The marker is also re-identified immediately before the clear (`cleanup-lib.sh marker-identity`,
    the rule `/cleanup` already applies at its own delete), which **narrows** the replacement
    window rather than closing it — the read and the unlink are still two operations.
  - **It never consults `owner`.** A session is an *actor*, not a run: ownership is transferable,
    one session may invoke the workflow twice, and an absent `owner` reads as "compatible" — correct
    for a hook deciding whether to speak, wrong for a starter deciding whether to delete. A live
    marker refuses even the session that wrote it. `owner` governs enforcement; **staleness**
    governs deletion, asked of `cleanup-lib.sh state-verdict marker` rather than re-derived.
  - **No refusal blocks a checkout without saying what will clear it.** `/cleanup` never deletes a
    `lock` record and preflight no longer clears one unconditionally, so the claim carries a
    **lease** (9000s / 2h30m; a flat constant, not derived from `ADB_DISPATCH_TIMEOUT_SECS`, which
    `role-dispatch.sh` already owns and validates differently) and the next run breaks an expired
    one with a reported `NOTE`. A pre-#202 empty lock has no lease and is broken the same way — the
    migration path. `release` drops only the claim its caller holds, compared by a per-acquire
    token that `admit` prints and the workflow threads to every release site (without one it can
    only compare session ids, which cannot tell a same-owner or ownerless successor apart — a limit
    recorded rather than papered over). Every unknown (no
    `jq`, an unreadable marker, a `gh` that errors, an unreadable state directory) **refuses without
    deleting**: a starter that cannot read must not delete.

    The lease is a **trade, not a free fix** — a run that outlives it can have its claim broken
    while alive. The exposure is pre-marker only (after step 5 the marker refuses a second run
    regardless), and 2h30m is far longer than that window can legitimately be. And some refusals do
    **not** clear themselves: an abandoned marker whose branch ref survives is kept by `admit` and
    by `/cleanup` alike, as are a malformed marker, a persistent `gh` failure, or wrong directory
    permissions. Each prints the recovery — the branch to finish, `/cleanup`, or the file to
    delete.

  Three further defects came from the PR review, and all three were the same shape — a guard that
  refuses forever rather than one that lets two runs through. A **dangling symlink** at the claim
  path read as *absent* to `-e` while still making `ln` fail with `EEXIST`, so admission reported
  "not writable" and never reached the break path — blocked until someone removed the link by hand.
  A failed `git switch -c` (the branch already exists) **kept** the claim, refusing every later run
  for the rest of the lease over an invocation that started nothing. And the claim token lived only
  in a shell variable, while the releases that need it sit in *later* fenced blocks the workflow
  itself says may run as separate shells — so every release degraded to `--token ""`, and for an
  agent whose harness exposes no session id the fallback compares nothing.

  Scope, stated rather than implied: `{{STATE_DIR}}` is per-agent, so this excludes a second run of
  the **same** agent and nothing more. A Claude run and a Codex run never collide on these paths at
  all; they collide on HEAD, and only partially — the branch check hard-errors once one of them has
  switched away from the default branch, but two agents starting *concurrently* while both are
  still on it both pass. This is not checkout-wide exclusion, and is not described as such.

  Covered by a new `scripts/check-implement-lib.sh` — including eight real concurrent processes
  racing for one claim — an end-to-end case in `scripts/check-implement-gate.sh` (run A's state
  live, session B admits, and **A's continuation gate must still fire** over a byte-identical state
  directory), and a rewritten containment guard in `check-cleanup.sh` that now *runs* the clear
  against filenames derived from `state-scan`'s own arms instead of grepping the workflow prose.
  All three were driven red on mutation before being called done.

- **A closing keyword in a PR body fires only from PROSE — a code span silently suppressed it, and
  the practice said otherwise.** `git-and-prs.md` claimed `Closes #N` closes an issue "**anywhere**
  in a PR body (prose, checklist, table)". That is false for a code span or a fenced block, and it
  is the sentence that made a backticked keyword look safe. Measured, not inferred: PR #294 merged
  with both keywords written as `` `Closes #115` ``, GitHub's own `closingIssuesReferences` for it
  came back **empty**, and the control (#292, bare prose) shows `[102, 262]`. Two delivered
  `release-blocker` issues stayed open — which on a repo using the release-goal convention means
  `/roadmap` reports the release **unmet** on blockers whose work is already on the default branch,
  and readiness never converges until a human notices.

  This is the same **"only prose declares"** rule the roadmap markers live by (#117/#136), biting
  the other way: there, quoting an example protects you; here, quoting the keyword loses the close
  and nothing anywhere says so.

  **The fix is a verification, not a warning.** `/implement-issue` step 10 now reads
  `closingIssuesReferences` back after `gh pr create` and compares it against the issues the run
  meant to close, **before** the merge — because afterwards the auto-close can never fire. It
  catches every cause, not just the backtick: a typo, a cross-repo qualifier, a keyword GitHub does
  not accept. The comparison is **repository-scoped**, because `closingIssuesReferences` can carry
  a cross-repo issue and a bare-number match would call `someone/other#115` a match for this repo's
  `#115` — the distinction `pr-targets-issue` already pins. A mismatch **exits non-zero**, so the
  run cannot walk into the auto-merge step having proved nothing. Both facts are pinned across
  their two homes in `check-fact-drift.sh`.

- **`/roadmap` emitted a release cut against a branch nobody had checked, on any repo whose CI is
  not GitHub Actions** (#115, consolidating #113, D45). `branch-health` distinguishes *"this repo  <!-- adb-claim-ok: #113 was consolidated INTO #115 and closed NOT_PLANNED as superseded; the reference is the history of this change, not tracked work -->
  has no CI"* (skip the gate and cut, the #24 degradation) from *"CI exists but has not reported"*
  (fail closed) — and the only discriminator was `gh api repos/OWNER/REPO/actions/workflows`, which
  enumerates **GitHub Actions and nothing else**. A CircleCI, Buildkite, Jenkins or Vercel repo has
  zero Actions workflows, so it read as `no-ci`, the health condition was **skipped**, and the cut
  was emitted. The change's own reasoning had applied exactly this argument to the *results* read
  (it reads both the Checks API and the legacy commit-status API, because reading one "silently
  ignores whole CI providers"); the **existence** probe still had the flaw that read was written to
  avoid.

  **`no-ci` now requires both probes to say no**: zero active Actions workflows **and** an
  authoritative empty **required-status-context** set on the default branch. Required contexts are
  provider-agnostic by construction — GitHub does not care who reports one — and they are read
  through the ordinary contents-read branch endpoint, classified by the same reader `required-drift`
  uses (#122), so the two can never disagree about a branch. The 200-body model is now one pure
  classifier with two consumers: `read_branch`, and a new `repo-settings.sh
  branch-required-contexts` subcommand that serves `/roadmap` from a body the workflow already
  fetched.

  **The names are carried, not a count**, and that is what closes the masking direction: a bare
  "some contexts are required" flag would let one unrelated passing result satisfy "somebody
  reported" and reach `green` while the declared provider had reported nothing — the same false-cut
  class the Actions arm already prevents, re-entered through another door. A declared context that
  has not reported is `indeterminate`, naming it.

  **Four fail-closed edges are pinned.** A **ruleset**-protected branch reports a *real* empty
  `contexts` array through this endpoint, so it is classified **unreadable** rather than "requires
  nothing" — read the other way it would reach `no-ci` and cut. A `contexts` array whose members are
  not all non-empty strings is **also** unreadable: checking only the container let `[null, 5]` be
  stringified into the plausible contexts `"null"` and `"5"`, and `[""]` be dropped to the
  authoritative empty set (independent-review find). A failing required context is `not-green`, not
  merely unreported. And partial reporting (one of two required contexts) is still unreported.

  The context set crosses between the two consumers as **JSON**, not newline-delimited text: the
  first cut split a context legitimately containing a newline into two required contexts, one of
  which nothing could ever report — a phantom, and a permanent `indeterminate`.

  **What this still cannot see, stated rather than implied.** An **unprotected** branch declares no
  contexts, so a repo with external CI and no branch protection still reads `no-ci` when nothing has
  ever reported; no non-admin endpoint answers that shape. #115's acceptance says "a non-Actions CI
  repo does not resolve to `no-ci`" — that now holds for a repo which **declares required contexts**
  (the case its own reproduction describes) and does **not** hold for an unprotected one, which is
  knowingly unmet rather than overlooked and is tracked in #293. Separately, required checks are matched by **context
  name**, and GitHub's newer `checks` array can bind a context to an expected `app_id`, which this
  discards; that matches what `read_branch`, `live_contexts` and `required-drift` have always read,
  so it is the established model rather than a new gap, and not a regression — before this change
  the names were not consulted at all. This is strictly narrower than the Actions-only probe it
  replaces, not a complete answer.

### Added

- **An owner-visible escape hatch for a repo whose CI never reports on the default branch** (#115,
  absorbing #113, D45). Correcting the existence probe above **increases** the deadlock population:  <!-- adb-claim-ok: #113 was consolidated INTO #115 and closed NOT_PLANNED as superseded; the reference is the history of this change, not tracked work -->
  a repo whose workflows are `pull_request`-only has a non-empty required set and nothing on
  default-branch HEAD, so it lands on an unreported arm every run, forever — requirements met, cut
  never emitted, and no way to say so. Shipping the fix without the hatch would have made more repos
  un-cuttable, not fewer, which is why they are one change.

  `<!-- release-health: skip-unreported -->` in the roadmap artifact declares it. Health then
  resolves to a new verdict, **`unreported-ok`**, which reaches `met` and emits the cut with a
  banner that **names the declaration** instead of claiming the branch is green.

  It is deliberately narrow, and every boundary is regression-tested: it applies **only** to the two
  "declared but unreported" arms; it is evaluated **after** failing, still-running and wrong-commit
  checks, so it can never excuse a red branch, a mid-CI run or stale evidence; and it can **never**
  excuse a branch whose required checks could not be **read** — an owner declaration about
  *unreported* CI is not evidence about *unreadable* CI. `skip-unreported` is the only valid value;
  anything else (including a near-miss like `skip`, or two different values) is **reported and
  ignored** rather than silently treated as off, because an owner who wrote it wrong would otherwise
  face a permanent `indeterminate` with nothing explaining it.

  That last boundary took two attempts, and independent review found the first one open: both
  unreported arms are gated on the context list being readable, because with an **unreadable** list
  *and* active Actions workflows the **Actions** arm matches first — so gating only the later
  unreadable arm let the opt-out excuse exactly what it was documented never to excuse. Both arms
  now refuse, and the regression is pinned with active workflows present, the only fixture shape
  that can see it.

  **Its authority is re-validated where it is used, and it is the repository PERMISSION.** An
  issue's author can keep editing its body forever regardless of repo permissions, and this marker
  bypasses a release-safety refusal — so `/roadmap` checks the author's access at the moment it acts
  on the marker, rather than trusting the check made when the artifact was adopted. It reads
  `collaborators/{user}/permission` and honours only `admin` or `write`. Deliberately **not**
  `author_association`, which is what artifact *adoption* uses and does not mean what it looks like:
  an organization `MEMBER` can hold read-only access to a repo, and `COLLABORATOR` covers the read
  and triage roles — so that set admits accounts which could never push a line of code but could arm
  a release cut by editing an issue body (independent-review find). An unreadable permission fails
  **closed**: the endpoint needs push access itself, so a 403 means authority could not be
  established, which is not a licence to assume it.

  It produces its own word rather than reusing `skipped`: `skipped` is the **caller's** opt-out for
  a decision that is not about shippable code (`baseline release roll`, which runs *after* the cut),
  this is the **owner's**, about a decision that is. One word for both would leave a reader unable
  to tell which authority let a release through.

### Changed

- **BREAKING (installed copies): `roadmap-lib.sh branch-health` takes three arguments and a third
  stdin key** (#115). Symlinked installs pick this up on their next `git pull`, so a direct caller
  that was not updated in the same change fails **loudly** — the arity check `die`s rather than
  computing a verdict from a partial input.

  | | before | after |
  |---|---|---|
  | arguments | `branch-health <sha> <active-workflows>` | `branch-health <sha> <active-workflows> <health-optout 0\|1>` |
  | stdin | `{check_runs, statuses}` | `{check_runs, statuses, required_contexts}` |
  | `required_contexts` | — | `[…]` declared · `[]` authoritatively none · `null` unreadable (fail closed) |
  | verdicts | `green` · `not-green` · `indeterminate` · `no-ci` | …plus `unreported-ok` |

  **Migration.** Get `required_contexts` from `repo-settings.sh branch-required-contexts` (pipe it
  the ordinary `repos/{slug}/branches/{branch}` body) and splice it in with `--argjson`; pass `0`
  for `<health-optout>` unless you are honouring the artifact marker. A missing key is an **error**,
  never an empty collection — defaulting it would answer as though the branch authoritatively
  declares nothing, which is a step on the path to `no-ci`. `release-ready` is unchanged apart from
  accepting `unreported-ok` as a sixth health value.

  Both in-tree callers moved with it: `/roadmap`'s readiness snippet, and this project's own
  `.claude/skills/release/release.sh`. The release driver makes the same branch read so the run that
  *emits* a cut and the run that *tags* it cannot disagree about a commit — but it passes `0` and
  still accepts only `green|no-ci`, a deliberately **stricter** policy than `/roadmap`'s: it decides
  whether to tag, having just watched the merge commit's checks settle, and a repo whose CI cannot
  give it that evidence needs its own release skill (D14) rather than a hatch that lets this one tag
  an unverified commit.

- **The `/roadmap` workflow body derives the GitHub Actions app slug instead of restating it**
  (#183). The body carried `github-actions` inline — it is prose an agent pastes into a shell, so it
  can carry a value but can never source `common.sh` — and the only thing keeping that copy honest
  was an assertion in `check-roadmap.sh` matching the rendered jq **character for character**.
  That pinned *formatting*, not the value: dropping a space around `==`, writing `// ""`
  differently, wrapping the line or renaming a jq variable failed the test for a reason unrelated to
  correctness, and the natural repair was to edit the assertion — which is how a guard rots into a
  rubber stamp.

  `scripts/build.sh` now substitutes an agent-invariant `{{ACTIONS_APP_SLUG}}` token (the shape
  `{{ARGS}}` already established), resolved from `adb_actions_app_slug` — the one home — and
  **refuses to render an empty value**, which would emit `(.app.slug // "") == ""` and match exactly
  the check runs whose app cannot be identified. The formatting assertion is **deleted**; what
  replaces it pins the token in the source and the real slug in all three rendered skills, so the
  value is checked where it actually lands — as the QUOTED VALUE alone, carrying no `==` and no
  operator spacing, so nothing about jq's formatting can fail it. #183 costed this against
  "`build.sh` does not source `common.sh` today" — that stopped being true in #256, which added the
  bash-floor gate, so the token adds no coupling the interpreter gate has not already paid for. The
  empty-value refusal is itself **observed failing**, against fixtures whose `adb_actions_app_slug`
  returns empty and fails outright.

  `.claude/skills/release/release.sh` carried a fourth copy of the literal, kept in sync by nothing
  at all; it already sources `common.sh`, so it now reads the accessor too. `check-fact-drift.sh`
  gains an `absent:` rule — proven able to fail under `--mutation` — rejecting a hard-coded copy
  reappearing beside the accessor.

### Fixed

- **A 4-space-indented workflow was invisible to check discovery, and nothing reported it**
  (#102, #262, D44). Both readers of `.github/workflows` treated indentation as the grammar — job
  keys at exactly 2 spaces, job properties at 4, steps at 6 — so a uniform 4-space workflow, which
  is valid YAML that GitHub runs happily, went unread.
  - **In `repo-settings.sh` this was fail-OPEN.** Discovery reported
    `skipping ci.yml — no pull_request trigger`, contributed **zero** contexts, and exited **0**.
    The `required-drift` backstop could not catch the under-requirement because it derives its
    desired set from the same discovery, so `apply` reported success while gating nothing. The
    symptom came from the *trigger* parser, which is why fixing only the job enumerator would have
    left the reported case unfixed.
  - **The two scanners had also already drifted** by the time the second was written — the
    demonstration #262 was filed on. `runs-on: "ubuntu-26.04 # not-the-label"` was read correctly by
    `repo-settings.sh` (a quoted value ends at its closing quote) and reduced to the approved label
    `ubuntu-26.04` by `check-bash-floor.sh`, which would have accepted a job whose real runner label
    is the whole quoted string and which GitHub would never schedule. Review caught that one before
    #257 merged; nothing prevented the next divergence.

  The YAML reading now lives in **one** place — `_ADB_WF_AWK` + `adb_wf_on` / `adb_wf_jobs` in
  `scripts/lib/common.sh`, the shape #136 chose for the shared prose filter and D43 affirmed — and both
  consumers apply their own opposite filters on top of it (`repo-settings.sh` skips matrix / `if:`
  / reusable / dynamic-name jobs; `check-bash-floor.sh` must see precisely those). The reader
  hands over each job's line range and step boundaries, so the floor lint's step-level rules stay
  scoped without re-deriving job boundaries.

  It tracks **relative depth** rather than detecting an indent unit, so 2-space, 4-space, and files
  that **mix** the two all read — the mixed case being the one an indent-unit heuristic gets wrong,
  because such a file has no single unit. Independent review then found six more valid YAML forms
  the first cut still could not read, each fixed with a fixture: **block-sequence** `on:` triggers
  and `branches:`/`types:` filters at *both* spellings (indented, and at the key's own column),
  **YAML anchors** (`build: &base_job` is an ordinary job, not an inline mapping — treating it as
  one skipped a readable job and failed the floor lint on a valid workflow), **aliases**, quoted
  scalars carrying **escaped quotes** (`"Build \"quoted\""`, `'it''s'`), **block/folded scalars**
  (`name: >-` used to become the required context `>-`, a phantom nothing ever reports), and flow
  sequences whose entries **contain a comma**. `check-fact-drift.sh` now pins that both consumers call
  the shared reader, with an `absent:` rule (proven able to fail under `--mutation`) rejecting the
  retired local `yaml_scalar` / `flush_job` definitions coming back beside it.

  **Discovery also stops reporting a clean empty scan when it cannot read a file.** Every workflow
  has an `on:` key and a `jobs:` block with at least one job in it, so a file violating any of
  those is a parse failure, never a legitimate shape — checked on **every** file, including ones
  the trigger verdict skipped, since a blind trigger parse looks exactly like "no `pull_request`
  trigger". A repo with no workflow directory, no workflow files, or only legitimately-skipped
  ones still exits 0 (#24). Downstream the failure is mapped fail-closed: `apply` refuses to write
  (and under `--prune` refuses to *delete* the contexts still gating the branch), while
  `automerge-ok` and `required-drift` return **20** — never `12` ("this repo has no CI") or `0`
  ("in sync"). This means `repo-settings.sh` can now exit non-zero where it always exited 0.

  A second review round found three more, all in that same first round's fixes: the block-scalar
  skip anchored on a sequence **dash** rather than on its key, so a valid `- name: |` step had its
  sibling `run:` swallowed and the lint failed a workflow that is fine; the inline-mapping
  `name:` test was a substring search, so a nested `environment: {name: …}` suppressed the job
  key's context and left a real PR job ungated; and an inline job carrying `if:` / `uses:` /
  `strategy:` was required under its key even though the block-form path skips exactly those — a
  phantom context that never reports. The inline test is depth- and quote-aware now, and all four
  keys disqualify.

  Two fail-opens **in the guards themselves** were found by that same review and closed. A `run: |`
  block whose *content* merely printed `run: bash scripts/check-bash-floor.sh --runtime` satisfied
  the floor lint's guard-wiring and first-step-logging rules without the guard ever running — the
  same "appearing, not executing" species the lint had already closed twice — so block-scalar
  content is now skipped as data. And a tab inside a quoted `runs-on:` shifted the floor lint's
  eight-field record, letting a job with a nonexistent runner report as guarded; that record cannot
  be value-last, so it now **refuses** a value it cannot encode rather than mis-splitting it.

- **The two LINT consumers of the shared prose filter were still running their own parsers**
  (#251, D43). #136 landed one paragraph-aware CommonMark filter (`_ADB_MD_AWK` / `adb_md_prose`
  in `scripts/lib/common.sh`) and moved five consumers onto it. Two more *declared themselves
  consumers in their own source* and were never converted, so both sentences asserted a
  consolidation that had happened for everyone except the file making the claim. Each copy was
  also carrying a live defect:
  - **`check-claims.sh` could not strip a multi-line HTML comment.** `cc_prose` was `sed`, and
    `sed` is line-based: a comment that opened and closed on one line was stripped, and one that
    spanned lines was not. A `#N` quoted inside such a comment was therefore collected as a live
    citation, and `--live` would resolve it and fail CI on text that is not a claim. **Reachable,
    not theoretical** — `base/workflows/roadmap.md` carries a multi-line schema comment quoting the
    dependency vocabulary by example; it was latent only because the numbers it happens to quote
    all resolve. Measured on a throwaway fixture: `refs=1/1` before, `refs=0/0` after.
  - **`state-assert.sh lint` fired on a code span.** It collapsed every run of 2+ backticks to one
    and then matched `` `[^`]*` ``, so a CommonMark span fenced by **two** ticks whose body held a
    lone tick was cut at the *inner* tick, leaving a fragment of the quoted status exposed as
    prose. `` The docs show ``PR ` #1 is still open`` as an example. `` was a violation — a Stop
    hook blocking a turn for quoting a status the way this repo documents one. #251 filed this half
    as an approximation that "repeated probing did not produce a false fire from"; it reproduces.
  - **Both now consume the shared filter**, and the raw-vs-prose separation `check-claims.sh`
    documents is **asserted** rather than assumed: the exemption marker is still read from the RAW
    line (it is normally a trailing comment, which in markdown may sit inside a span) while the
    rules read the masked prose view. That fixture passes on the parent, so it was driven RED
    against a deliberately collapsed-view copy of the tree.
  - **Two semantic changes come with the shared filter and are deliberate** (D43). An HTML comment
    is *zero-width* in CommonMark, so its bytes are deleted rather than replaced by a space:
    `D<!--x-->99` now reads as the `D99` a reader actually sees. And a code span becomes `\x01`
    rather than one space, so `` PR`x`#7 `` no longer reads as the phrase `PR #7` *across* a span —
    the reference is still existence-checked, only the fabricated *kind* claim goes away.
  - **Two fail-opens closed on the way past.** `adb_md_prose` is fail-closed, and `check-claims.sh`
    now exits 3 rather than treating an empty prose view as a clean file; and `cc_scan_file`'s exit
    status is no longer discarded by a process substitution, where an awk that died mid-file arrived
    as zero added lines and reported in the same words a clean file uses. A new `md-structural=`
    count — non-exempt added markdown lines whose prose view is empty — makes the stripping visible
    in the log instead of indistinguishable from a range with fewer claims in it.

- **A fenced block indented to a list item's content column was scanned as prose** (#252, D42).
  `adb_md_content_at` (`scripts/lib/common.sh`) computed a line's container content column from
  **that line alone**, so everything past column 3 was indented-block territory no matter which
  container it sat in. Putting an example inside a list item — one of the most ordinary shapes an
  issue takes — therefore hid the fence and handed its contents to the scan:
  `- item` / `    ~~~` / `    Depends on #5` / `    ~~~` declared **#5**. That is #69's over-match
  class, and its cost is open-ended: one fabricated edge holds a ready bundle out of every bundle
  `/roadmap` emits until somebody edits the body. #135 had fixed only the delimiter written
  straight after the marker (`- ```console`).
  - **The filter now carries one integer**, `md_list_at` — the innermost open list item's content
    column — and the indent cutoff becomes `i - base > 3` where it read `i > 3`. That is not the
    only behavioural change, which an earlier draft of this entry claimed: the closer bound below
    moved independently, and it moved for every caller.
    `base` moves where indented-block territory *starts* and never changes the column the function
    returns, so a container column deeper than the true one can still admit structure written
    further left but can never hide it. That one-directional failure mode is why a single integer
    is enough where D27 priced a container stack — this buys the content column and nothing else:
    no depth, no pop on a markerless dedent, no laziness tracking.
  - **It REPLACES the `md_list` boolean rather than joining it**, the same way `md_fence_len` is
    itself the in-a-fence flag: a marker's content column is always ≥ 2, so a non-zero `md_list_at`
    *is* "a list is open" and a second variable that could drift out of step no longer exists.
  - **A fence's closer is now bound to its container's column, not the delimiter's own.** Those
    were the same number until a fence could open at an item's content, and the difference was not
    cosmetic: the old bound accepted a closer 4 past the container (CommonMark fence *content*),
    which failed both ways in one body — fabricating an edge from the quoted line after the early
    close, *and* dropping every edge after the real closer, which then read as a fresh opener. It
    also settles the top-level case that was always reachable: an opener indented 3 no longer
    accepts a closer at 4–6.
  - **D27's guard is unmoved, deliberately.** At the item's content column + 4 the line is indented
    *code* relative to the item, and stripping it would delete a list continuation — the direction
    that marks a genuinely blocked bundle `ready`. A fixture pins that boundary as a decision
    rather than leaving it looking like an oversight.
  - **Staleness is bounded in both directions**, and the state is one integer rather than a stack.
    A markerless dedent leaves the column *too deep*: harmless for the indent cutoff (a too-deep
    column still admits structure written further left) but not for the closer bound, where
    self-review caught it closing a fence early and losing an edge the parent got right — so the
    bound is clamped to the delimiter's own column, which a container can never begin to the right
    of. A lazy continuation left it *too shallow*: `- item` / `lazy continuation` at column 0 used
    to clear the column while the item was still open, so a fence at column 2 stored a bound of 3,
    **rejected its own valid closer** and ran to end-of-body eating every edge after it. That one
    was found by independent review; a column-0 line now closes the container only when no
    paragraph is open, which is CommonMark's own laziness rule and reuses state the filter already
    had.
  - **A fence opened inside a list item ends when the item does** — a non-blank line written to the
    *left of the fence's own container column*, not merely at column 0: an indented item ends well
    before column 0, and testing `== 0` swallowed a real edge there. Without this rule the
    container-relative closer bound is a net loss: it correctly refuses an over-indented closer, and
    the fence then takes every edge after it. The fence's own closer is tried first, because a
    list-nested fence is usually closed by a delimiter written back at column 0 and ending the
    container first re-read that line as a fresh opener. A **top-level** unterminated fence still
    swallows to end-of-body, exactly as before.
  - **A column-0 block starter is not a lazy continuation.** Laziness covers continuation *text*, so
    a heading, blockquote, fence or HTML block at column 0 ends the item even mid-paragraph. Without
    that qualifier `- item` / `# Repro` / `    Depends on #5` fabricated an edge the previous rule
    read correctly as top-level indented code — the over-match this whole change removes,
    reintroduced one rule later. A *marker* line is excluded: it opens an item rather than ending one.
  - **Measured against a CommonMark reference parser**, not argued: 1888 generated container shapes
    classified by `markdown-it-py` in strict mode, each candidate line carrying a unique issue
    number. Over-match **526 → 389**, under-match **46 → 2**, and **zero** shapes where this drops
    an edge the parent declared. Both remaining under-matches are oracle artifacts (inline code
    spans, which the block-level oracle does not model). Two intermediate designs were rejected on
    those numbers rather than on taste. **The sweep did not find everything**: both defects the
    third review round caught sit in shapes the generator never produces, so those figures were
    identical before and after fixing them.
  - **The two consumers that call the fence predicate directly** (`skill-compose.sh`,
    `check-release-skill.sh`) keep the top-level-only rule and now pass their container column
    explicitly instead of relying on awk's uninitialized-parameter semantics. Their behaviour is
    unchanged in every case but one, said plainly rather than rounded off: the closer bound became
    container-relative for everyone, so a fence they open at indent 1–3 now needs its closer at
    indent ≤ 3. Every indented opener in the tree today pairs with a closer at the same indent, so
    no file's reading moves.
  - **Pre-existing, not a regression** — the same body yields the same two numbers before #136 —
    and **latent rather than live**: `deps-from-body` over all 210 issue bodies in this tracker
    produces an identical 30-edge set before and after, so no body's reading moved. The corpus run
    is the evidence of safety; the fixtures are the evidence of the fix.
  - `scripts/check-roadmap.sh` § 6i gains fixtures for both delimiters, blockquotes, ordered and
    nested markers, the closer-bound pair, the stale-dedent shape, CRLF, and the D27 boundary;
    `check-common-lib.sh` pins the rule at the primitive. **Nineteen of the new assertions were
    observed red** against the parent's library in a throwaway copy, while the ones pinning
    deliberately-unchanged behaviour stayed green. Others could not be witnessed that way — the
    parent reads those bodies correctly — so each was driven red against a deliberately wrong build
    instead: the closer-bound fixture against one carrying the container column without the clamp,
    and both laziness fixtures against one whose column-0 rule drops the `md_para` qualifier.

- **`/cleanup` could be made to delete a file nobody asked it to touch** (#273, D41).
  `cleanup-lib.sh state-scan` serialized one record per state file as `<kind>TAB<path>TAB<key>`
  with **no escaping**, and the sweep parses that with `IFS=<tab> read -r kind sfile key` before
  handing `$sfile` to `rm -f`. A filename may legally contain a tab or a newline, so a file in the
  state dir could inject a **second, forged record** — and the forged `kind` is attacker-chosen
  text, so it could name `gaps` and reach the delete. `state-scan` now refuses to serialize a name
  it cannot encode, reporting it as a new `unsafe` kind whose path field is a `%q`-encoded
  rendering rather than a usable path.
  - **Classifying the carrier `other` would not have fixed it**, which is the part worth stating.
    The file that reproduced this *was* `other` — the kind that is never swept — because the defect
    is in the record format, not in which arm matched. `other` is still emitted, so the raw name
    still reached stdout and the forged line survived the safest classification in the file. The
    refusal therefore sits ahead of the classification, not inside it.
  - **The marker's `.branch` was the same bug through a second door, and a worse one.** A filename
    cannot contain `/`, so that carrier was confined to names in the repo root (`CHANGELOG.md`,
    `install.sh`, `CLAUDE.md`); a marker's `.branch` is a JSON string that **can**, so it reached an
    **absolute** path. A value carrying any ASCII control character — codepoint `< 0x20` **or**
    `0x7f` — is now treated as unreadable, which is honest rather than a euphemism: `git
    check-ref-format` rejects control characters, so such a value was never a branch name and every
    ref query built from it was guaranteed to miss. The key falls to `-`, then `unknown`, then keep.
    (This is deliberately the control class and **not** a reimplementation of git's ref grammar —
    git also rejects spaces, `~^:?*[` and more, but those merely fail to match a ref, which the
    existing no-such-ref path already handles.)
  - **That rejection happens inside `jq`, because the shell could not be trusted to see the value
    it was judging.** Checking after `b="$(jq …)"` judges a string command substitution has already
    *mutated*: it strips every trailing newline, so `"dead-branch\n"` arrived as the ordinary
    `dead-branch` and — with no matching ref and no PR — would be classified **stale and deleted**;
    and bash silently drops a JSON `\u0000` from a substitution while warning on stderr, both
    corrupting the value and breaking the reader's quiet contract. Both were found by the
    independent review and are covered by regressions, including one asserting the read stays
    silent.
  - **But the marker RECORD survives that refusal**, and a fix that dropped it would have traded
    one bug for a worse one: `/cleanup` reads run liveness from the presence of a marker record, so
    dropping it reports "no run in flight" — the verdict that lets a **live** `/implement-issue`
    run's gap and review artifacts be swept out from under it.
  - **A state directory whose own path is unserializable is fatal** (exit 2, no output) rather than
    skipped file-by-file: every record would be refused, and a scan that silently returns nothing
    looks exactly like a clean, empty state dir — a sweep reporting success while doing nothing,
    which is the #106 class this library exists to remove. `/cleanup` captures that status instead
    of letting it fall through, and reports skipped files through its existing `NOTES` contract.
  - **NUL-delimited records were considered and rejected**: bash strips NUL bytes from `$(…)` while
    zsh preserves them, and macOS runs zsh — so the record format would have behaved differently on
    the two platforms CI covers.
  - `scripts/check-cleanup.sh` carries fixtures for **both** carriers plus an end-to-end sweep in a
    throwaway root, with a sentinel that must be deleted so a no-op cannot pass. Thirteen of the new
    assertions were observed red against the unfixed library, and the marker-liveness one — which
    *cannot* fail against the old code, only against a naive fix — was observed red against a
    deliberately naive one.

## [2.0.0] - 2026-08-04

**The runtime floor moves to bash 5.3, and this is the release that makes it binding.** An entry
point that gets an older interpreter now re-execs into a good one or stops with the platform's
install command — so a host that installed and ran on macOS's 3.2.57 or on Ubuntu LTS's 5.2.21
will refuse until it has a 5.3, and Debian/Ubuntu ≤ 25.10 have no such package at all. That is the
breaking change, and it is deliberate: it buys `mapfile`, associative arrays, namerefs and
`${ …; }` everywhere, and it deletes the ~20 accommodation sites that existed only for 2006's
shell. Windows support is answered in the same breath — **WSL2 only**, proven by a smoke job that
was watched running green rather than asserted. Alongside it: `selfcheck.sh` is ~4x faster on a
bounded `wait -n` pool, `/roadmap` now says when it cannot parse a dependency edge instead of
silently dropping it, and `/implement-issue`'s review artifacts finally get swept.

### Added

- **`/implement-issue`'s review artifacts now have a lifecycle, on both ends** (#264, D40).
  `review-prompt.txt`, `review.md` and `review.err` were written by step 8 of every run that
  dispatches an in-session reviewer, and removed by nothing — a run whose slot is deferred or
  absent writes none of them, which is half of why the staleness below bites. Preflight cleared the
  *gap* set and not these, and `cleanup-lib.sh state-scan`
  classified them `other`, which `/cleanup` never sweeps — correctly, since sweeping what it cannot
  classify is how a sweep starts eating files. They were therefore permanent. Preflight now clears
  them, and a `review` arm classifies them beside the `gaps` one.
  - **The defect is residue and staleness, not disk growth.** Each dispatch redirects with `>`, so
    a run truncates the previous run's files rather than appending to them. What was wrong is that
    `review-prompt.txt` — the full diff *plus* the issue body and every comment — and `review.err`,
    the reviewer's whole exploration stream, sat indefinitely in a directory whose stated purpose is
    swept scratch; and that a run whose `review` slot is unset, deferred or absent (step 8's rungs
    2–3) never overwrites `review.md`, so the *previous* run's findings read as the current one's.
    Bounding a single dispatch's stream *within* a run is separate, and stays #141.
  - **No review lock, and that asymmetry with the gap artifacts is the decision the issue asked
    for.** `gap-analysis.lock` exists for one window — gap analysis runs in step 3, before the
    branch and marker exist, so a live dispatch has nothing to prove its liveness with. Review is
    written in step 8, *after* step 5's marker and while the run's branch still exists, so within
    the **one-active-run-per-checkout** boundary `/implement-issue` already declares, the marker
    already is that signal. Outside it a second run's preflight can delete a live marker (#202) —
    and a review lock would be cleared by that same preflight, so it would not help either.
  - **But `/cleanup` reads it from the re-scan, never from the `$RUN` it computed earlier.** That
    is the same rule the lock already follows: the signal governing a destructive delete must be
    true *at* the delete, and `$RUN` predates a marker pass that makes live PR round trips. Any
    marker still present in the fresh scan is one the sweep just kept, or one a run created since.
  - **The `LARGE …` report covers the review stream too**, gated on its own verdict rather than the
    gap one. The run #264 recorded left a `review.err` of 389 KB — already past the 256 KB
    threshold — so this was a warning the operator could not get for a file that had crossed it.
    That arm now also enumerates from the scan instead of a `"$STATE"/*.err` glob, which zsh's
    default `nomatch` aborts.
  - **`pr-body.md` deliberately stays `other`** (the issue scopes it out: the shipped workflow does
    not name that file, an agent chose it), and a test now pins that it was not made sweepable in
    passing.
- **A WSL2 smoke job, so the Windows support claim becomes checkable** (#2, D38).
  `.github/workflows/wsl-smoke.yml` installs **`Ubuntu-26.04`** into WSL2 on `windows-latest`, clones
  onto the Linux filesystem, and runs the real installer plus the full `selfcheck.sh` there. It
  implements the last item of #2 — the CI shape.
  - **It does not yet *prove* anything, and the distinction is the point.** A workflow that has
    never run is a plan, not evidence. The proof arrives on the first dispatch (see the last bullet);
    until that is observed green, this entry claims only that the leg exists and that everything
    checkable offline was checked.
  - **Weekly `schedule` + `workflow_dispatch` + `push: tags`, never per-PR**, and in its **own
    file**. Both halves are structural. `ci.yml` has only unfiltered `push:`/`pull_request:`
    triggers, so a `schedule:` added there would run all 27 of its jobs weekly to gain one; and
    `repo-settings.sh` discovery skips a workflow with **no `pull_request` trigger**, so this repo's
    own tooling can never *discover or add* it as a required context that then reports on no PR. (An
    administrator or a ruleset can still require any context by hand — that is outside what
    `repo-settings.sh` governs, and the claim is scoped to what it does.)
  - **Not `release:`** — this repo versions by pushed git tag and never publishes a GitHub Release
    object, so that trigger would have fired zero times. A leg that never runs is the silent-guard
    failure mode, not a leg.
  - **The lint gained a WSL-host class, and the reason is the interesting part.** `windows-latest`
    ships Git-Bash **5.3.15**, which *clears this repo's floor* — so the ordinary
    `run: bash scripts/check-bash-floor.sh --runtime` **passes there without ever entering WSL**,
    proving the floor for native MSYS2, a userland #2 ruled out of scope. Adding the label to
    `APPROVED_RUNNERS` and stopping would have manufactured a green that nothing else in the suite
    could see. A WSL-host job is therefore approved only when it reaches the guard through
    `wsl -d <distro> -- …`, names a distro (a bare `wsl --` runs the image's *default* one), and logs
    that distro's `bash --version` **before** the guard rather than after.
  - **The converse is enforced too**: the `wsl` form does not satisfy a Linux or macOS job, so the
    widening gave no existing job a second way to look compliant.
  - **No `shell:` carve-out was needed.** The job runs under the runner's default pwsh and invokes
    `wsl.exe` explicitly, **one native command per step** — the runner appends an exit on
    `$LASTEXITCODE`, so a multi-line block propagates only its *last* native exit code, which is a
    fail-open. (The assertion steps are multi-line pwsh, but each makes a single native call and
    fails via `throw`, which is terminating.) Where two commands genuinely belong together they go
    inside one `bash -c "set -eu; …"`. So #257's blanket `shell:` rejection is untouched.
  - **`Vampire/setup-wsl` is not used**: its distribution list stops at Ubuntu-24.04 (bash 5.2.21,
    below the floor), so it cannot express the only distro this floor permits. `wsl --install
    --distribution Ubuntu-26.04` is Microsoft's own documented mechanism and one fewer third party.
  - **Fail-closed on the one thing that cannot be checked offline.** Whether that install completes
    unattended on a hosted runner is not knowable from a workstation, so the job *asserts* rather
    than assumes: distro registration, WSL version 2, `VERSION_ID="26.04"`, that the clone is not on
    DrvFs, and the floor itself. A mechanism that does not work yields a red job, never a green one
    that proved nothing.
  - **The clone is made from the canonical remote, inside WSL** — which is precisely what
    `docs/installation.md` tells a Windows user to do, so the job executes the documented topology
    rather than approximating it. Independent review reproduced the alternative and it failed two
    ways: cloning the Actions workspace records the `/mnt/<drive>` mount as `origin`, which is not a
    GitHub-shaped remote, so `adb_git_origin_slug` cannot resolve it and `check-state-assert.sh`
    fails 14 assertions; and on the `push: tags` leg `actions/checkout` leaves HEAD **detached**, so
    that clone carries the tags but **no `origin/<default>`** and `check-claims.sh` exits 2 with
    "cannot resolve a default-branch base". Cloning from the URL and checking out `github.sha` fixes
    the remote, the missing branch ref and the commit pinning together. `actions/checkout` is gone.
  - **Node/npm is installed too, not just ShellCheck.** `check-gates.sh` skips its two gate-detection
    integration cases with `SKIP: npm or jq missing`, which is the same silent-skip the ShellCheck
    install exists to prevent — so "the full offline suite" would have been quietly false.
  - **Existence is enforced by `check-fact-drift.sh`, not by the floor lint.** Printing `0 WSL-host`
    is visibility, not enforcement: delete the workflow and the floor lint still exits 0 while the
    docs go on describing a Windows leg. An "at least one WSL job" aggregate rule was the wrong home
    — every fixture in `check-bash-floor-guard.sh` would then go red for a reason other than the rule
    under test. `fact` rules pin the fields that actually **run** — `runs-on: windows-latest` and the
    floor-guard line naming `Ubuntu-26.04`, each anchored to the start of a YAML line — plus the
    `schedule:` trigger and the two docs that assert the claim, so the job and the claim cannot drift
    apart in either direction.
    - **The anchoring is the correction, and it took two rounds of negative testing.** Pinning the
      bare tokens anywhere in the file was satisfied by the workflow's own explanatory *comments*:
      repointing `runs-on:` at `ubuntu-26.04` and restoring the bare floor step deleted the Windows
      leg while every rule stayed green and the floor lint reported `0 WSL-host … PASS` — the same
      "a note about the thing read as the thing" fail-open the floor lint has been bitten by twice.
      Negative-testing the replacement then found a narrower one: pinning "some `run:` step names the
      distro" was still satisfied by the `wsl --install` line after every `-d` invocation had been
      repointed at Ubuntu-24.04, *below the floor*. The pin now sits on the floor-guard line, and
      each of the five mutation vectors was observed firing its own named rule.
  - **What this PR could not do, stated plainly:** run it. A `schedule`/`workflow_dispatch` workflow
    must already be on the default branch before it can fire, so #2's "seen green at least once" is
    discharged by a manual dispatch **after** merge, and #2 stays open until that is observed. Every
    offline half was verified, including each new lint rule observed rejecting its own violation.

- **`scripts/selfcheck.sh` runs its steps in parallel** (#260, D37). The 40 steps are now a
  **registry** — an ordered name list plus a name → command map — dispatched through a `wait -n`
  job pool bounded at `min(cpu, 8)`, instead of 39 inline steps run strictly one after another.
  - **Measured, and the issue's premise corrected rather than repeated.** On the maintainer's
    10-core machine (bash 5.3.15, macOS): **272.6s / 279.5s** at the pre-change commit,
    **66.2s / 69.7s / 72.0s** after — a **~4x** improvement. `--serial` on the new code is
    **283.6s / 298.1s**: the pre-change wall clock, the ~9.8s the newly added guard step costs, and
    run-to-run variance.
    The issue's stated target ("under 6 minutes on an 8-core machine") was **already met before the
    change**, so it could not discriminate success from doing nothing; the 18m55s figure it and
    `CLAUDE.md` cite **did not reproduce** in any deliberate measurement. What was demonstrated is
    non-reproduction, not a cause: that run was not instrumented, so contention is a guess and is
    not asserted. Both restatements of it are corrected in place.
  - **Output is atomic and attributable.** Each step's stdout and stderr go to one file and the
    *parent* emits the banner, the body and the verdict together once the step is reaped, so eight
    concurrent steps never interleave. Results arrive in completion order — a failure surfaces as
    soon as it happens — and the `result` block's last two lines are `FAILED: <names>` and the
    verdict, because the Stop-hook gate runner tails only the final few KB on failure.
  - **Exit semantics are unchanged**: collect-all, not fail-fast. Every step runs and is reported;
    any red exits 1.
  - **`build-drift` is the one step pinned to a serial prologue**, because it runs `build.sh`,
    which rewrites tracked generated files in place — and the root-doc render is a plain
    truncate-and-write, so a concurrent reader can see a half-written file. What is deliberately
    *not* serialized, and why, is stated in the script's "concurrency contract" header.
  - **New flags**: `--serial` (declaration order, output streaming live — the debugging mode),
    `--jobs N`, `--only a,b`, `--list`. A filter naming an unknown step is an **error**, never a
    quiet run of nothing.
  - **Cancellation reaps the workers.** `set -m` puts each worker in its own process group so
    `_cleanup` signals the group; without it a `^C` killed the parent and reparented up to `$JOBS`
    check suites to init, which is the divergence `adb_run_bounded` documents for its own watchdog
    path (#141). Found by the new guard suite, not by inspection.

- **`scripts/check-selfcheck.sh`** (#260) — the runner is a guard now, so it gets what guards get
  here. A job pool's failure mode is **silence**: a dispatcher that drops a worker's exit status, or
  reaps a job and blames the wrong step, prints exactly what a clean run prints, and every existing
  `check-*.sh` still passes. So the real `selfcheck.sh` is driven over a throwaway fixture of stub
  steps and required to fail on a red one, name it, and carry its actual exit code. 53 assertions
  covering collect-all, output atomicity, the concurrency bound (both respected *and* genuinely
  concurrent — a pool of one would otherwise pass everything else), `--serial` ordering, the
  prologue running alone, filters that select nothing or widen, large output, and cancellation.
  The suite was **observed going red** against five deliberately broken copies of the runner — a
  dropped exit status, a misattributed pid, unbuffered output, a pool of one, and the pre-fix empty
  `--only` — each firing the rules that name it; the tracked tree is never mutated. `check-claims-guard.sh`'s wiring pins move from grepping `if bash …; then` lines to
  reading `selfcheck.sh --list` — asking the dispatcher what it runs, which a string match cannot do.

- **The bash 5.3 floor is now ENFORCED at runtime, not just observed in CI** (#256, #261, #2;
  D30, D31, D32). #257 made every CI job prove which interpreter it got; this makes an entry
  point that got the wrong one repair itself or stop.
  - **`adb_require_bash`** in `scripts/lib/common.sh`, reusing the existing `adb_version_ge`.
    Below the floor it **re-execs** into a >= 5.3 interpreter found at a fixed candidate list, and
    only then fails — with the running version, the floor, and the **platform's** install command
    (macOS `brew install bash`; Fedora/Arch/Alpine's package; and for Debian/Ubuntu <= 25.10 the
    honest answer that *no 5.3 package exists*, so "install bash" would be unfollowable advice).
  - **Re-exec is the mechanism, not belt-and-braces.** On macOS `/bin/bash` is 3.2.57 and has been
    for the whole bash-4-and-later era,
    so 5.3 is reachable only through `PATH` — and `PATH` is exactly what a Stop hook, a gate script
    or another agent's CLI does not reliably carry. Reported live on the owner's machine: a
    defensive `~/.zshrc` line ordering `/usr/bin:/bin` ahead of `/opt/homebrew/bin` left `env bash`
    on 3.2.57 after a *successful* `brew install bash`. That is now a regression fixture.
  - **Every entry point is classified, and the set is closed.** 55 **gate** · 3 **advisory** ·
    1 **exempt**. `check-bash-floor.sh --entrypoints` fails the build on a shebang-bearing file
    that is unclassified, uses the wrong form for its class, calls the gate in a comment, or calls
    it after a `cd` or a stdin read — because `$0` is frozen at invocation and a drained hook
    payload is not restored by the re-exec.
  - **Two carve-outs, both load-bearing and both pinned.** `common.sh` stays parseable *below* the
    floor forever (D30) — it holds the gate, and a caller cannot reach a function until sourcing
    finishes, so a 5.3-only construct there would make the gate unreachable on exactly the hosts it
    exists for; it is the one file #258/#259 must skip. And `check-bash-floor.sh` does not call the
    gate (D31) — it is the observer, and its own negative test runs it under an old `/bin/bash`
    expecting red.
  - **The installer sources the gate rather than copying it.** Both issues asked for a standalone
    copy on the premise that `install.sh` "cannot source what it installs". It already does
    (`install.sh:24`) — it runs *from* the clone it installs — so the copy was not written; it
    would have duplicated candidate resolution, version comparison and diagnostics for nothing.
  - **Windows via WSL2** (#2): `docs/installation.md` states the WSL2 + Ubuntu 26.04 requirement and
    the clone-inside-WSL rule; `install.sh` preflights for **CRLF** and warns (never fails) on a
    `/mnt/<drive>/` checkout; `.gitattributes` pins `*.sh` **and the extensionless `bin/` commands**
    to LF. The remedy deliberately does **not** suggest `git checkout .`, which destroys
    uncommitted work. The WSL smoke CI job was sliced out of that PR and **ships here** (see the
    `wsl-smoke` entry above); the "seen green" half is still unreachable from the PR that
    introduces a `schedule`/`workflow_dispatch` workflow, because it cannot run until it is on the
    default branch.
  - **`adb_version_ge` grew the fork-free path itself**, rather than a floor-specific helper beside
    it. A separate comparator would have answered the real floor outright, leaving the canonical one
    reached only for shapes nobody passes — reuse in name only. The two paths are differentially
    tested against each other over 144 operand pairs in `check-common-lib.sh`, and awk's documented
    quirks (`5abc` reads as 5, `x` as 0) stay awk's, because any strictly-non-numeric operand falls
    through to it.
  - **Independent review found 12 more, all fixed.** The ones worth naming: the three **advisory**
    entry points *continued* under a sub-floor interpreter instead of taking their documented no-op
    — the exact deep failure the floor exists to prevent; `session-currency.sh`'s always-exit-0 trap
    was installed *after* the library source it was supposed to protect; both **release** scripts
    defined functions before the gate, so 5.3-only grammar in any of them would fail to *parse*
    under 3.2 before the gate could rescue it; the CRLF preflight could not protect `install.sh`
    from a CRLF `common.sh`, because the source runs first and the scanner selected files by
    shebang, which a sourced library has none of; the entry-point lint accepted a token inside a
    `printf`, an assignment or a heredoc, and its lateness rule knew only `cd`, missing the whole
    `read`/`mapfile`/`dd` family; and three assertions passed for the wrong reason (one searched
    output for a version string the fixture never printed, one used a fixture the scanner skipped).
    Platform facts were corrected too — **RHEL was grouped with Fedora**, so its `dnf install bash`
    advice could not reach the floor.
  - **Found by the guard harness, before review:** the loop sentinel `_ADB_BASH_REEXEC` is
    exported, so a re-exec'd parent handed it to every child and a child starting on the old
    interpreter failed closed instead of repairing itself. `selfcheck.sh` is exactly that shape —
    re-exec, then ~30 `bash scripts/check-*.sh` children — so all of them would have died on a
    machine with a shadowed Homebrew prefix. Fixed by clearing the sentinel once the version check
    has passed, which keeps it a loop guard; pinned by a fixture watched failing without the fix.

- **An edge `/roadmap` could not parse is now SAID, instead of silently dropped** (#132, D28).
  Every fix in this family (#69, #108, #112, #117, #136) resolved an ambiguity by picking a side
  silently, so "this body declares no edge" and "this body declares an edge I could not parse"
  produced byte-identical output — opposite facts, one answer. `Depends on #5 (the gate) and #6`
  yielded `5` and dropped `6` without a word; `Depends on issue 5` was indistinguishable from
  `Refs #5`.
  - **`roadmap-lib.sh deps-ambiguous`** is the second view of the *same* awk scan, selected by a
    mode flag. Sharing it is the load-bearing part, not an optimization: a report computed by a
    second parser drifts from the grammar it reports on at the first change to either. It emits
    TSV — `partial` (a chain declared an edge and dropped a later reference), `unparsed` (a
    reference in the clause, no edge out), or `no-hash` (`issue <N>` written without a `#`).
  - **A sibling subcommand, because the issue's own constraints eliminate the alternatives.** A
    `?`-prefixed line corrupts a stdout every consumer reads as bare numbers; a non-zero exit
    collides with the callers that *do* preserve the status; stderr is outside the output contract.
    What is purely additive is the **stdout contract** — `deps-from-body`'s output is byte-identical,
    verified over all 37 open bodies in this tracker, so nothing changes on account of the new
    subcommand. (The issue's own "every caller treats non-zero as a hard stop" is not quite true:
    two composition sites discarded it, which is fixed below.)
  - **It warns; it does not gate.** A report renders as a `dep-ambiguous` Reconcile-flags row and a
    retirable `dep-ambiguous:#N` question — the posture #78 chose when it picked `WARN:` over
    `HOLD`. Blocking on *uncertainty* would let one false positive stall a ready bundle forever.
  - **The false-positive budget was measured, not argued.** A first cut reported 13 sites across
    those 37 bodies and all 13 were one shape: a reference past a clause boundary — commentary, not
    a dropped edge (`- #81 depends on #79 — **satisfied**, #79 closed COMPLETED (PR #111)` reported
    both the edge it had just declared and a PR number). Bounding the window at the clause
    boundaries the negation scoping already used took the corpus to **zero** reports with both
    documented witnesses still firing. A qualified `owner/repo#5` stays silent on purpose: that is
    a confident answer, and reporting confident answers is what makes noise.
  - **No author-controlled byte reaches the artifact.** All three fields come from closed sets — a
    kind, a line number, an issue number — so a third-party body cannot push markup, a table
    delimiter or a directive into a tracked document, even though describing author text is the
    whole job.
  - **Observed failing before being called done.** Eight mutations against a throwaway copy of the
    tree each turned exactly the fixtures written for them red. One run earned its keep at once:
    the two self-reference fixtures passed with the guard *removed*, because a resolvable self
    reference is consumed by the chain and never reaches the window — they were vacuous, and only
    the mutation said so.

- **The bash-3.2 accommodations are gone from the libraries, adapters and hook scripts** (#258;
  D33, D34). The floor is 5.3 and enforced (#256/#257), so code shaped by a 2006 interpreter is
  code shaped by nothing.
  - **`adb_sc_paths` returns through namerefs**, not three shared `_sc_*` globals, and it
    **validates its output names** — a plain identifier, none colliding with its own locals, all
    three distinct — returning 2 rather than warning. That is a security boundary, not tidiness:
    `declare -n ref=$x` *evaluates an array subscript inside `$x`*, so an unvalidated output name is
    an arbitrary-command-execution seam in a library `install.sh` symlinks into every consumer's
    runtime. The other two rejections cover the nameref failures that are **silent** — a circular
    reference leaves the caller's variable unset, and three names that are really one variable make
    all three paths equal to the last assignment. Sixteen fixtures call the function directly, because
    every pre-existing assertion reaches it through the CLI and can only see the file it eventually
    wrote — never a return convention.
  - **`pr-watch.sh` bounds its watch with `BASH_MONOSECONDS`.** `$SECONDS` is `time(NULL)` minus the
    shell's start, so it moves with the wall clock; an ntp step during the half-hour wait this loop
    exists for either expires the bound early or extends it indefinitely.
  - **Retired rationale is rewritten, not deleted.** Where a 3.2 constraint no longer applies but
    the shape is still right — `read -r -d ''` over `$(cat <<…)`, a `case` glob over a fork — the
    comment now gives the reason that actually holds. The past tense is kept deliberately, so the
    next reader does not re-derive why the code looks as it does.
  - **What #258 asked for that was NOT done, and why** (D33): `common.sh` is untouched — D30 exempts
    it permanently, which narrows the "zero workaround comments" criterion and refuses the
    `adb_run_bounded` half of the `BASH_MONOSECONDS` one. The `declare -A` criterion is **vacuous**:
    no temp-dir-as-map or parallel-array pattern exists in the eligible files, and the ordered lists
    that do exist would lose ordering their callers depend on. "All three platforms" was met for
    **two** at the time; the WSL2 leg (**#2**) ships in this same unreleased set, on a weekly
    schedule rather than per-PR.

### Fixed

- **The WSL smoke job ran the suite as root, which inverted a permission fixture** (#271, D39).
  `.github/workflows/wsl-smoke.yml` passed `--user root` to every in-distro command, and root holds
  `CAP_DAC_OVERRIDE` — so a POSIX mode bit cannot deny it a write. `scripts/check-skill-compose.sh`
  chmods a skill directory `555` and requires the next compose to **fail**; under root the write
  succeeded, the assertion inverted, and the weekly job went red on `skill-compose: 123 passed, 1
  failed` — an assertion that passes on `ubuntu-26.04` and on a maintainer's macOS workstation
  alike. The defect was the workflow's, not the check's: weakening an assertion that is correct
  everywhere a normal user runs it would have deleted real coverage to accommodate a CI choice.
  - **The job now creates an ordinary user and hands it everything the framework touches** — the
    clone, the distro's `bash --version` log, the floor guard, `install.sh`, `selfcheck.sh` and
    `uninstall.sh`. Exactly three in-distro invocations still pass `--user root`, and each has a
    reason: the `/etc/os-release` read (it runs before the account exists), the `apt-get` bootstrap,
    and `useradd` itself. The host-side steps — `wsl --install`, `wsl --list --verbose`, and the
    runner's own `bash --version` — take no `--user` at all.
  - **It raises fidelity rather than merely turning the job green.** `docs/installation.md` tells a
    Windows user to clone and install inside WSL **as themselves**, so running as root was proving a
    setup no real user has.
  - **The clone is made *as* that user, not handed to it.** A root-owned tree given to a non-root
    user fails later and confusingly — git refuses it outright with "detected dubious ownership" —
    rather than at the step that caused it. A new assertion proves the working clone's owner, and
    the effective uid is now asserted (not merely printed) in its own step, so a future inversion of
    this kind fails at the cause instead of surfacing as one baffling fixture 30 steps downstream.
  - **The regression guard is the interesting part, because the obvious form of it does not work.**
    A weekly job is far too slow to be the only thing standing between an edit and this state, so
    the pin lives in `scripts/check-fact-drift.sh` — but `fact` applies one pattern to a whole file
    with no step selector, so a bare `absent:--user root` would be tripped by the three invocations
    that must *stay* root and by the workflow's own comments, failing on a correct file. The pattern
    is therefore **contextual**: root *and* reaching a framework command. It covers `-u root`, which
    is genuinely the same instruction spelled short, and a numeric uid for a weaker and separately
    stated reason — `wsl --user` resolves a *name* through `getpwnam`, so `--user 0` names a user
    that does not exist and errors rather than running as root. That branch is defence against a
    future `wsl.exe` that accepts a uid, not a spelling that works today.
  - **Both directions are pinned, and here the negative genuinely is not enough.** The regression is
    "the job silently returns to root", and **dropping `--user` entirely does that without ever
    spelling the word** — `wsl --install --no-launch` provisions no user, so an invocation with no
    `--user` runs as the image's default, which is root. No negative pattern can catch an absent
    flag. So each framework command carries a positive pin naming `adb`, including the distro's
    `bash --version` log, which has neither a `--cd` nor a script name and was therefore the one
    framework line the first cut of the negative rule missed entirely.
  - **Independent review found four holes in the first cut of that guard, and each is closed and
    re-proven.** Anchoring on `run:` excluded a whole-line comment but not a *trailing* one, so an
    unbounded `.*` read straight through a `#` — which made the negative rule falsely fire on a
    comment, and made every positive rule satisfiable *by* one (`run: wsl --help # --user adb …`
    passed while executing `wsl --help`). The patterns now use `[^#]*`, and the clone pin matches
    only inside the first quoted string. The uid rule pinned the `id -u` *read* but not the
    comparison, so neutering `if ($uid -eq '0')` left the lint green; it is now two rules. And the
    filesystem assertion could pass on a `df` that never ran, since an absent match is not a match.
  - Every rule was observed going red against the real pre-fix file, and each regression vector was
    driven to red individually on a throwaway copy: dropping the flag, `-u root`, `--user 0`,
    `--user root`, a root clone, root on the distro bash log, a neutered uid comparison, and both
    comment-based fail-open attacks. Three legitimate variants — a trailing comment naming the old
    form, the `-u adb` shorthand, and `--distribution` spelled out — were confirmed *not* to fire.
  - **What this PR does *not* claim.** The job has still not been observed green: a `schedule` /
    `workflow_dispatch` workflow runs the version on the ref it is dispatched against, and the
    Windows leg's live half is discharged by a dispatch, not by the diff that fixes it — the same
    boundary D38 drew for #2's "seen green at least once" criterion. Everything checkable offline
    was checked.

- **The 5.3 floor made a Stop hook adopt a session id off a stream it never finished reading**
  (found while implementing #258; the exposure predates this PR). The reliance arrived with #180;
  until #256 the shebang was a bare `#!/usr/bin/env bash`, so which behaviour you got depended on
  which interpreter `PATH` resolved — stock macOS gave 3.2 and the safe discard, a Homebrew-first
  `PATH` gave 4.2+ and the retention. **#256's re-exec made >= 5.3, and therefore the retention,
  universal.** `this_session()` in
  `implement-issue-gate.sh` relied on bash 3.2 **discarding** partial input when `read -t` fires,
  and its comment said so. bash >= 4.2 **keeps** it — measured: 3.2 returns status 1 with an empty
  variable, 5.3 returns 142 with the bytes. So a writer that sent a complete payload and then never
  closed the pipe had its id adopted, and the gate fell **silent** for a marker it should have
  enforced. Partial writes were saved only by jq refusing to parse a truncated object, which is luck
  rather than a rule. The discard is now the gate's own (`rc > 128`), where unknown identity falls
  back to branch matching — the direction that enforces. The existing bound fixture could not see
  any of this: it writes **no bytes**, so it cannot tell a discard from a retention.
- **A crashed edge scan answered "this body declares no edges"** (found while implementing #132).
  `deps-from-body` ran `awk | sort`, and a pipeline reports only its last command, so a broken scan
  exited **0 with empty output** — indistinguishable from a clean negative, and the direction that
  silently unblocks a bundle that is genuinely blocked. The library header has promised
  `EXIT STATUS IS FAIL-CLOSED` the whole time; nothing checked it, because a check that cannot
  answer wrong looks exactly like a check that found nothing wrong. Both subcommands now capture
  the scan and exit 2. Demonstrated against `origin/main` (rc 0) and pinned by a fixture that
  breaks a **copy** of the library, never the tracked file.
- **`/roadmap`'s release composition discarded that status from the other side.** Both edge-derivation
  call sites used `for d in $(… deps-from-body …)`, which throws away the substitution's exit code,
  so a failed extraction arrived as an empty prerequisite list and the issue was promoted anyway —
  arming the milestone with a blocker nothing can close, the exact failure that block exists to
  prevent. Both now capture and hard-stop. The `## Decisions` row loop was additionally fed by a
  pipe, so its hard-stop `exit` would have left only the subshell; it now reads from a file.
- **Two stale claims about D27.** `roadmap-lib.sh`'s STRUCTURE block still said 4-space indented
  code blocks were `DELIBERATELY NOT HANDLED … Tracked separately`, and `docs/roadmap-acceptance.md`
  still told a reader they are "deliberately *not* stripped" — both describe the behavior #136
  replaced. They are stripped at top level only, which is what D27 decided and what the code does.

- **Third-party text is now governed by a stated policy, labelled where it enters, and contained
  before it reaches another agent** (#214, D26). Six workflows read text the operator did not
  write — issue bodies and comments, PR review threads, CI logs, vendor changelogs — and one of
  them, `/implement-issue`, hands it to a dispatched CLI with repo tool access at two sites. The framework's threat model for that was
  "the agent will probably be sensible."
  - **`base/practices/untrusted-content.md`**, rendered into all three root docs. Its rule is
    **content, not authority**: third-party text may describe a bug, a requirement or a finding —
    the things these workflows came to read — but it can never change the target repo or branch,
    the scope, which gates run, whether to push or merge, or which credentials are in play. The
    obvious rule, *never follow an instruction found in third-party text*, was rejected as
    unimplementable: `/resolve-pr-threads` exists to turn a reviewer's finding into a pushed
    commit. A directive found inside such text is a **finding to report**, and the run continues.
  - **Containment, not a fence.** `adb_untrusted_block` (`scripts/lib/common.sh`, exposed as
    `role-dispatch.sh untrusted <source>`) JSON-encodes the text into a single-line envelope
    carrying its provenance and the policy. An XML-ish `<untrusted_issue_text>` fence is not a
    boundary — a body containing the closing tag closes it, and everything after arrives as
    top-level instruction. JSON escaping has no such hole.
  - **Every read site is labelled and every workflow is classified.** `/implement-issue` (3 sites),
    `/resolve-pr-threads`, `/roadmap`, `/debug`, `/new-release` and `/create-issue` say what the
    text is and where it came from; `/cleanup` is recorded as **zero** sites because it reads
    state fields, never a body — recorded rather than omitted, so "absent from the list" can never
    be mistaken for "nobody looked".
  - **`scripts/check-injection.sh`**, riding the existing `workflow-render` CI job rather than a
    new one (a new job is a new branch-protection context that `required-drift` would report as
    gating nothing). It red-teams the envelope with payloads that carry closing tags, quotes,
    backslashes, CRLF, ANSI bytes, U+2028 and an envelope-shaped body, requiring byte-exact
    round-trip; it asserts the source contract; and its **own mutation harness** breaks seven
    invariants in a throwaway copy of the tree and requires the lint to go red on each.
  - **Deliberately not included: sandbox least-privilege settings.** #214's fourth checklist item
    is deferred to #248 — two of its three version floors are off by one against the vendor's
    sandboxing reference, and the third floor is right while the security effect described for it is
    backwards (`sandbox.filesystem.disabled` *removes* filesystem isolation). See that issue.

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

- **The check harnesses are written for bash 5.3** (#259; D35, D36). `scripts/check-*.sh` is 18,931
  of the 32,184 tracked shell lines here — 59% — and it was still shaped by an interpreter the floor
  retired in #256. (#259 says 57%; that was measured before the tree grew.)
  - **1,564 of 2,208 in-code command substitutions are now `${ command; }`** — no subshell fork.
    644 remain by design. (The sweep's own report said "1,562 of 2,251"; it counts `$( )` written
    inside comments too, and two new comments in this branch quote one. D36 carries both.) What was
    excluded is enumerated in D36; the short version is that the issue's criterion is a lexical
    test on the first word, and the safe set is smaller because `${ ; }` also stops *containing*
    what the body does. A helper that assigns a global, `cd`s outside a subshell, or calls `exit`
    stays on `$( )` — an `exit` inside a funsub kills the whole harness.
  - **Two latent hazards fixed rather than excluded.** `rc_snip` and `runs` assigned bare globals
    (`body`, `i`, `sep`) that collide with names their own files use elsewhere. Nothing was wrong
    only because every call site happened to wrap them in a subshell. Both declare their locals now.
  - **`check-claims.sh` caches gh lookups in a `declare -A`**, not a directory of one-line files —
    no mkdir, no temp file per number, no `cat` fork per read. `check-fact-drift.sh`'s `fires:`
    witnesses are a real array instead of a newline-delimited string, and its duplicate-file check
    is a map lookup instead of a quadratic self-join. Nine heredoc-fed `while read` loops are gone:
    five became `mapfile` and the rest `for` loops over an array the `mapfile` already built. Each
    retires the `[ -n "$x" ] || continue` guard it carried — that empty element was the heredoc's
    own trailing newline, never data — and gains a `check_enumerated` call in its place, which
    rejects both an empty list AND a single blank entry (the case a bare count test waves through).
  - **A third below-floor carve-out, pinned (D35).** `scripts/check-bash-floor.sh` is the floor
    OBSERVER: D31 exempts it from the runtime gate so it can run on an interpreter that does not
    clear the floor, and its guard executes it under `/bin/bash`. bash 3.2 *parses* `${ …; }` and
    dies at expansion, so converting it would replace the entire diagnostic with one
    `bad substitution` line **while still exiting 1** — invisible to an rc-only test. It and
    `scripts/check-lib.sh` (which it sources) are excluded, and `check-bash-floor-guard.sh` now
    asserts so, with the assertion observed going red on a copy carrying an injected funsub.
  - **Two stale rationales corrected, not deleted.** The `adb_run_bounded` fallback was never a
    "bash-3.2 watchdog" — `timeout` is GNU coreutils, which macOS does not ship, so a stock Mac
    takes that path on 5.3 too. And the `sort -V` ban keeps its gate but loses its reasoning:
    measured on macOS 26, Apple's `/usr/bin/sort` is `2.3-Apple (199)` and **does** accept `-V`.
    It stays banned because `-V` is not POSIX, CI deliberately keeps `gnubin` off PATH, and an
    unsupported flag inside a command substitution is masked into an empty previous tag.

- **Reasoning effort is declared per role instead of inherited** (`Refs #225`). `role-dispatch.sh`
  passed no effort override, so every cross-agent dispatch ran at whatever the agent's own config
  said. A workstation carrying `model_reasoning_effort = "xhigh"` in `~/.codex/config.toml` applied
  it to `gap_analysis` and `review` alike; one measured review took **37m57s of a 2h28m run**.
  - **New `[roles.effort]` table in `agents.toml`**, resolved repo → global → built-in. **Only
    `review` has a built-in default (`medium`)** — every other role passes no flag, so nothing
    changes for them until someone declares one. Unset, or an explicit `""`, means inherit.
  - **BEHAVIOUR CHANGE ON UPGRADE:** a repo that declares nothing now runs its `review` dispatch at
    `medium` rather than at the workstation's setting. Installs are symlinks, so this arrives on
    the next `git pull`. Declare `[roles.effort] review = "…"` to keep a different level.
  - `codex exec` receives `-c model_reasoning_effort=…`; `agy` has no equivalent, so the setting is
    accepted and ignored for `gemini` slots rather than pretending to bound them.
  - Values are validated against the CLI's own catalog (`codex debug models --bundled`):
    `low|medium|high|xhigh|max|ultra`. Validation exists **because the CLI does not have it** —
    `codex exec -c model_reasoning_effort=<nonsense>` prints the value and runs anyway.
  - **Effort is not a time cap.** The 45-minute hang backstop is unchanged and still exists only to
    stop a wedged process.

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

- **One paragraph-aware CommonMark prose filter, in one home** (#136, D27; supersedes #128/#129/#130/#131). <!-- adb-claim-ok: those four were closed NOT_PLANNED precisely BECAUSE this issue absorbed them -->

  "Is this a declaration or is it documentation?" was answered by four private parsers, each wrong
  in a different way. They are now `_ADB_MD_AWK` + `adb_md_prose` in `scripts/lib/common.sh`,
  consumed by `deps-from-body`, `decisions`, `release-command`, `marker-title`, `pr-targets-issue`,
  `skill-compose.sh` and `check-release-skill.sh`. **Two consumers are not migrated** —
  `state-assert.sh lint` and `check-claims.sh`, both of which name themselves #136 consumers in
  their own source — and they are tracked in #251 rather than left implied.
  - **A code span that crosses a line ending is now resolved.** `` `Depends on #5 `` / ``
    `still example` `` renders entirely as code and declares nothing; the line-at-a-time filter
    copied the unmatched opening backtick as literal text and read the clause as prose, recreating
    the exact false dependency #117 exists to prevent. The obvious streaming fix — an "am I inside
    a span?" flag — was refused: one stray backtick (`` it`s fine ``) would swallow every edge
    after it, which is the under-match direction. Span resolution is bounded to the **block** — a
    blank line, a fence, a heading, a thematic break or a **list marker** all end one — so an
    unmatched tick cannot reach past it. Setext headings are not detected and are named as the one
    remaining unrecognized boundary rather than implied away.
  - **A `<!--` quoted *as text* no longer swallows the body.** Comment stripping ran before
    anything knew about code spans, so the opener armed the cross-line comment state and every
    following line disappeared — including, in the `## Decisions` section, real owner decisions
    (#108's failure mode, by another route). Comments and spans are now resolved in **one
    left-to-right pass in which whichever opens first wins**, which is CommonMark's own
    precedence and the only ordering that satisfies both repros at once.
  - **`pr-targets-issue` has a structure filter at last.** `Closes #42` inside a fenced block, an
    HTML comment, a blockquote, a code span or an indented block all read as "this PR targets
    #42" — verified in all five shapes — so `/roadmap` withheld a ready issue from every bundle.
    Each PR body is filtered **on its own** (cross-line state means one PR's stray ``` would
    otherwise blind the scan for every PR after it), and the predicate stays **fail-closed**: a
    filter that cannot run, or that is cut short, is rc 2, never a clean "not targeted" — and so
    is a **malformed PR object** (a numeric body, a non-array reference set), which `jq` used to
    stringify or treat as an empty generator and answer 1 to. The filter emits a completion trailer
    carrying a **per-invocation nonce** so a truncated run cannot pass as a short clean result; a
    fixed marker would have been satisfied by any output that happened to end in it, which is what
    the first cut shipped and review caught.
  - **A quoted example is masked, never deleted.** Dropping a span lets the text on either side
    **fuse** into a keyword nobody wrote — `` clo`x`ses #42 `` collapses to `closes #42`, freezing
    a ready issue. The shared filter replaces span bytes with `\x01`, the same byte and the same
    reason `deps-from-body` was already built with, so every word-scanning consumer inherits the
    boundary instead of rediscovering the hazard.
  - **The two fence detectors are one.** `skill-compose.sh` toggled a boolean on any ``` after 0-3
    spaces, and had already drifted from `roadmap-lib`'s: a `~~~`-fenced `### ` line was
    **advertised** as a composable anchor, and a ``` closing a longer run left the toggle inverted
    for the whole rest of the file, **hiding** every real step after it. Both directions are now
    pinned by `check-skill-compose.sh`. Its new cases were **observed failing against the
    pre-change implementation** — 8 of them — which is the checkable form of that claim; tests and
    implementation land in the same commit, so no ordering is asserted from history.
    `check-release-skill.sh` carried a third toggle and now consumes the same predicate.
  - **Indented code blocks are recognized at top level only** (D27 — #136 §5's fork). Four or more
    spaces, no paragraph open, no list container open. Both guards are the safety argument:
    `    Depends on #52` is byte-identical at top level and as a continuation under a `- ` bullet,
    where CommonMark puts content at column 2 and code needs six — so a bare `^ {4}` rule deletes
    real edges. `#136`'s acceptance list named one existing fixture as the one that must *flip*;
    it cannot, because its middle line sits at column 0 and an indented block ends at the first
    non-blank line indented ≤ 3. Its **rationale** is rewritten and the actual §5 repros are new
    fixtures instead — the same correction the issue's own author had already had to make once.
  - **Two more comment-shaped consumers joined.** `release-command` had a fourth private detector;
    `marker-title` had **none**, so a fenced or code-spanned example of `<!-- release-milestone: …
    -->` read as a real declaration and could refuse a perfectly good artifact as ambiguous. Both
    now run the shared filter with `--keep-comments`, which is why that flag exists.
  - Verified byte-identical on the live corpus: the same edge set over all 193 issue bodies in
    this tracker, and the same anchor set over every shipped skill.
  - **Still wrong, and named rather than implied:** a fence indented to a *list item's content
    column* is scanned as prose, because the container column is computed per line. Pre-existing
    at `main`, over-match direction, and it needs the cross-line container state D27 declined —
    tracked in #252.

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

[Unreleased]: https://github.com/BWBama85/ai-dev-baseline/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/BWBama85/ai-dev-baseline/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/BWBama85/ai-dev-baseline/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/BWBama85/ai-dev-baseline/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/BWBama85/ai-dev-baseline/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BWBama85/ai-dev-baseline/releases/tag/v1.0.0
