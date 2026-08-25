# Pattern ledger

**What this project has already learned from its own review threads.** Every entry below was a
review finding somebody fixed: the class of defect, where it was found, and the commit that closed
it. It is written automatically by `/resolve-pr-threads` as each thread is resolved, and read
automatically by `/implement-issue` — the gap-analysis dispatch and the pre-PR self-review sweep
both receive the promoted checklist.

**The checklist is the operative half.** A class seen more than once is a pattern rather than an
incident, and is owed a rule: a sweep to run before the next pull request opens. Rules land here
through the normal pull-request path, so a rule only takes effect once a change carrying it has
been merged — which takes repository write access, and is reviewable in the diff like any other
change. (Write access is what the guarantee actually rests on; whether a human read the diff is up
to the project's own review settings.)

**Editing by hand is fine.** Reword a rule that reads badly, delete one that stopped being true.
The only lines with a machine-read grammar are the ones between the markers below; the prose
around them is yours.

**Two branches can both append here, and that is handled by ordinary means.** Git may report a
conflict when two pull requests add hits at the same point — take both sides; the entries are
independent and are keyed on their review-thread ids, so nothing is lost by keeping them. Promotion
is decided by *reading this file*, never by a counter carried in a branch: two branches that each
recorded a class's first hit merge into a file holding two, and the next run promotes it. The
mechanism converges rather than missing the class permanently.

## Promoted checklist

Sweep each of these before opening a pull request.

<!-- adb:checklist:begin -->
- `partial-validation` — For every validator, name what the CONSUMER actually reads and check exactly that: the final byte as well as the line count, every field the record grammar requires rather than the ones that happen to be present, and the spec grammar rather than what a permissive parser tolerates. Grep the siblings — this class has never appeared alone.
- `stale-doc-claim` — When a diff changes what a surface DOES, grep the shipped prose that describes it — templates/, base/workflows/, base/practices/, README — and check every command name you write actually resolves. A doc that describes the old behaviour is read by adopters who have no other source.
- `metric-scope-mismatch` — Before reporting a number, state the claim it must support and check the number can support it: a lifetime count over an append-only file cannot show a per-round trend, and a figure the command does not emit cannot be filled from one that sounds similar.
- `evidence-discarded` — When a field is mandatory because a reader needs it, find every place that reader is served and check each one renders it. Run-state files are swept, so a report is often the only surviving copy — and a fix applied to the success path leaves the failure path, where the evidence matters most.
- `toctou` — When a command checks a precondition and then acts on it, the lock must span BOTH — locking only the write leaves the decision racing. And never reclaim a lock by deleting the directory you observed: rename it to a unique name first, so exactly one recoverer wins and nobody deletes a lock somebody else just took.
- `ledger-coverage-gap` — A signal this loop captures must reach the consumer that needs it: record every legitimate finding including one an earlier commit already fixed, and treat a failed record as terminal rather than resolving threads whose history was never stored.
- `false-guarantee` — A comment asserting a safety property is a claim, not a mechanism. Name what enforces it in the same breath — a lock, a bound, a validator — and if the answer is "the caller is sequential" or "the lines are short", check that something makes it so. Both instances of this class were headers arguing a guarantee the code did not provide.
- `markup-injection` — Stored text that later lands in a structured artifact must be neutralized against THAT artifact's structure, not against structure in general: escape `&<>` for anything rendered as Markdown or HTML, and refuse the region markers that delimit a file whose sections are machine-managed. Both instances were text kept as evidence that could forge the frame it was displayed in — ask, for every stored field, which document it is written into and what characters mean something there.
<!-- adb:checklist:end -->

## Hits

One line per resolved review thread, newest last.

<!-- adb:hits:begin -->
- `partial-validation` `scripts/lib/docs-lib.sh:192` `a119e75` `PRRT_kwDOTfywrM6b1wrA` PR #429 2026-08-24 — checked that a newline existed, not that the FINAL byte was one; read dropped the last line, awk read it
- `partial-validation` `scripts/lib/docs-lib.sh:220` `a119e75` `PRRT_kwDOTfywrM6b1wrG` PR #429 2026-08-24 — outer-bracket check accepted an unquoted TOML array element the spec has no grammar for
- `partial-validation` `scripts/lib/pattern-ledger.sh:333` `a119e75` `PRRT_kwDOTfywrM6b1wrQ` PR #429 2026-08-24 — an empty PR field was permitted, so a record the writer could not produce still counted
- `partial-validation` `scripts/lib/pattern-ledger.sh:353` `a119e75` `PRRT_kwDOTfywrM6b1wrS` PR #429 2026-08-24 — a field-count test accepted a checklist rule whose instruction text was empty
- `stale-doc-claim` `base/workflows/implement-issue.md:530` `a119e75` `PRRT_kwDOTfywrM6b1wrW` PR #429 2026-08-24 — recovery hint named baseline patterns verify, which no dispatcher implements
- `stale-doc-claim` `templates/agents.toml:166` `a119e75` `PRRT_kwDOTfywrM6b1wra` PR #429 2026-08-24 — template still described [mcp] required as inert after it gained a consumer
- `metric-scope-mismatch` `scripts/lib/pattern-ledger.sh:639` `a119e75` `PRRT_kwDOTfywrM6b1wrI` PR #429 2026-08-24 — reported a lifetime count where the claim made about it needed a per-round one
- `batch-attribution` `base/workflows/resolve-pr-threads.md:564` `a119e75` `PRRT_kwDOTfywrM6b1wrO` PR #429 2026-08-24 — one sha captured after the batch was applied to every item, though each had its own
- `partial-validation` `scripts/lib/docs-lib.sh:241` `9e91aaf` `PRRT_kwDOTfywrM6b21ax` PR #429 2026-08-24 — every empty split element was treated as legal; only the empty array and one trailing comma are
- `partial-validation` `scripts/lib/pattern-ledger.sh:498` `9e91aaf` `PRRT_kwDOTfywrM6b21a1` PR #429 2026-08-24 — record validated only the hits region, then appended into a ledger every reader refuses
- `partial-validation` `scripts/lib/pattern-ledger.sh:709` `9e91aaf` `PRRT_kwDOTfywrM6b21au` PR #429 2026-08-24 — verify accepted a duplicated checklist class that every operational reader rejects
- `metric-scope-mismatch` `scripts/lib/pattern-ledger.sh:673` `9e91aaf` `PRRT_kwDOTfywrM6b21aq` PR #429 2026-08-24 — the summary asked for four round figures where the command supplied two
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:559` `9e91aaf` `PRRT_kwDOTfywrM6b21ah` PR #429 2026-08-24 — an already-addressed legitimate finding was resolved without a ledger hit, understating recurrence
- `durable-reference` `base/workflows/resolve-pr-threads.md:580` `9e91aaf` `PRRT_kwDOTfywrM6b21a5` PR #429 2026-08-24 — a sha recorded as an audit link stops resolving once the branch is squash-merged and deleted
- `awk-v-escaping` `scripts/lib/pattern-ledger.sh:441` `9e91aaf` `selffound-classes-awk-v` PR #429 2026-08-24 — multi-line list passed via awk -v, which cannot carry a newline; ENVIRON is the documented fix in this same file
- `partial-validation` `scripts/lib/docs-lib.sh:266` `e99acc6` `PRRT_kwDOTfywrM6b3iU7` PR #429 2026-08-24 — an empty quoted array element passed the grammar, then vanished in the parser
- `third-party-default` `base/workflows/resolve-pr-threads.md:592` `e99acc6` `PRRT_kwDOTfywrM6b3iVA` PR #429 2026-08-24 — git rev-parse --short follows core.abbrev, whose minimum is below the grammar we require
- `rerun-not-idempotent` `base/workflows/resolve-pr-threads.md:642` `e99acc6` `PRRT_kwDOTfywrM6b3iVF` PR #429 2026-08-24 — an unconditional commit aborted the documented crash-recovery rerun when nothing had changed
- `evidence-discarded` `scripts/lib/docs-lib.sh:425` `e99acc6` `PRRT_kwDOTfywrM6b3iVH` PR #429 2026-08-24 — a field made mandatory for the reader was collected and never rendered to them
- `partial-validation` `scripts/lib/docs-lib.sh:220` `26c9f5a` `PRRT_kwDOTfywrM6b37La` PR #429 2026-08-24 — a present-but-empty declaration answered with the code an ABSENT one gets
- `evidence-discarded` `scripts/lib/docs-lib.sh:446` `26c9f5a` `PRRT_kwDOTfywrM6b37Ld` PR #429 2026-08-24 — fixed the clean arm last round and left the degraded arm dropping the same evidence
- `false-guarantee` `scripts/lib/pattern-ledger.sh:459` `26c9f5a` `PRRT_kwDOTfywrM6b37Lf` PR #429 2026-08-24 — a header asserted serialization from a mechanism the actual writer never invokes
- `partial-validation` `scripts/lib/pattern-ledger.sh:601` `26c9f5a` `PRRT_kwDOTfywrM6b37Lj` PR #429 2026-08-24 — an early return exited before the validation every other path performs
- `metric-scope-mismatch` `base/workflows/resolve-pr-threads.md:751` `26c9f5a` `PRRT_kwDOTfywrM6b37Lk` PR #429 2026-08-24 — absent and zero were reported identically though the workflow calls them different facts
- `toctou` `scripts/lib/pattern-ledger.sh:495` `fee323a` `PRRT_kwDOTfywrM6b4VjH` PR #429 2026-08-24 — the lock covered the write but not the check that decided whether to write
- `toctou` `scripts/lib/pattern-ledger.sh:474` `fee323a` `PRRT_kwDOTfywrM6b4VjN` PR #429 2026-08-24 — stale-lock recovery could delete a lock another writer had just acquired
- `partial-validation` `scripts/lib/pattern-ledger.sh:320` `fee323a` `PRRT_kwDOTfywrM6b4VjP` PR #429 2026-08-24 — a substring search stood in for the record grammar, so junk parsed and mis-attributed
- `partial-validation` `scripts/lib/docs-lib.sh:280` `fee323a` `PRRT_kwDOTfywrM6b4VjS` PR #429 2026-08-24 — validated the parser output instead of the value the operator actually wrote
- `toctou` `scripts/lib/pattern-ledger.sh:571` `75572cd` `PRRT_kwDOTfywrM6b4xm_` PR #429 2026-08-25 — the file was created before the lock that protects deciding whether to create it
- `partial-validation` `scripts/lib/pattern-ledger.sh:394` `75572cd` `PRRT_kwDOTfywrM6b4xnC` PR #429 2026-08-25 — the parser checked the rule was non-empty but not that it obeyed the writer grammar
- `shell-injection` `scripts/lib/pattern-ledger.sh:587` `75572cd` `PRRT_kwDOTfywrM6b4xnF` PR #429 2026-08-25 — a path was interpolated into trap text, which is shell source evaluated later
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:629` `75572cd` `PRRT_kwDOTfywrM6b4xnJ` PR #429 2026-08-25 — a failed record only warned, so the round resolved the threads and lost the findings
- `status-swallowed` `scripts/lib/docs-lib.sh:485` `e8c112c` `PRRT_kwDOTfywrM6b5N3t` PR #429 2026-08-25 — a diagnostic was printed and the failing status was not returned with it
- `partial-validation` `scripts/lib/docs-lib.sh:218` `e8c112c` `PRRT_kwDOTfywrM6b5N3v` PR #429 2026-08-25 — accepted the first of a duplicated key because the reader stops at the first match
- `false-guarantee` `scripts/lib/docs-lib.sh:152` `e8c112c` `PRRT_kwDOTfywrM6b5N31` PR #429 2026-08-25 — a header asserted append safety for short lines while nothing enforced shortness
- `silent-permission-change` `scripts/lib/pattern-ledger.sh:536` `e8c112c` `PRRT_kwDOTfywrM6b5N3y` PR #429 2026-08-25 — a temp file mode was installed over a tracked file, invisible to git
- `metric-scope-mismatch` `scripts/lib/pattern-ledger.sh:824` `d2b2a2d` `PRRT_kwDOTfywrM6b6l6S` PR #429 2026-08-25 — PR scope was used as round scope, so every cumulative figure was reported as this rounds
- `toctou` `scripts/lib/pattern-ledger.sh:521` `d2b2a2d` `PRRT_kwDOTfywrM6b6l6W` PR #429 2026-08-25 — reclamation gained an ownership check and release did not, so a stale writer could unlock a successor
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:618` `d2b2a2d` `PRRT_kwDOTfywrM6b6l6c` PR #429 2026-08-25 — only one failure code was terminal, so other write failures still let the round resolve
- `metric-scope-mismatch` `base/workflows/resolve-pr-threads.md:808` `d0d2042` `PRRT_kwDOTfywrM6b695y` PR #429 2026-08-25 — a delta of a cumulative figure counted retroactive reclassification as this rounds work
- `partial-validation` `base/workflows/resolve-pr-threads.md:793` `d0d2042` `PRRT_kwDOTfywrM6b6950` PR #429 2026-08-25 — a variable was read that nothing assigned, so every figure was empty or the block aborted
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:658` `d0d2042` `PRRT_kwDOTfywrM6b6952` PR #429 2026-08-25 — a wildcard treated a hard configuration error as success and let the round continue
- `partial-validation` `scripts/lib/docs-lib.sh:181` `d0d2042` `PRRT_kwDOTfywrM6b6955` PR #429 2026-08-25 — IFS folding meant the field-count test could not enforce the arity it claimed to
- `partial-validation` `scripts/lib/pattern-ledger.sh:461` `d0d2042` `PRRT_kwDOTfywrM6b6956` PR #429 2026-08-25 — a reconstructed scalar was validated instead of the incomplete one the operator wrote
- `toctou` `scripts/lib/pattern-ledger.sh:566` `630ac96` `PRRT_kwDOTfywrM6b7dvJ` PR #429 2026-08-25 — verification and deletion were separate filesystem operations with a window between them
- `metric-scope-mismatch` `base/workflows/resolve-pr-threads.md:572` `630ac96` `PRRT_kwDOTfywrM6b7dvK` PR #429 2026-08-25 — a side accumulator counted the idempotent no-op that the snapshots correctly ignored
- `false-guarantee` `scripts/lib/docs-lib.sh:125` `630ac96` `PRRT_kwDOTfywrM6b7dvN` PR #429 2026-08-25 — a byte bound was measured in characters, so the guarantee it named did not hold
- `partial-validation` `scripts/lib/pattern-ledger.sh:480` `630ac96` `PRRT_kwDOTfywrM6b7dvQ` PR #429 2026-08-25 — the duplicate-key rule was applied to one manifest table and not its sibling
- `toctou` `scripts/lib/pattern-ledger.sh:542` `b5306a6` `PRRT_kwDOTfywrM6b8GSs` PR #429 2026-08-25 — reclamation used age as a proxy for death, so a live writer could still land its prepared write
- `partial-validation` `scripts/lib/docs-lib.sh:286` `631b8db` `PRRT_kwDOTfywrM6b8wnx` PR #429 2026-08-25 — the duplicate rule counted keys but not repeated table headers
- `partial-validation` `scripts/lib/pattern-ledger.sh:940` `631b8db` `PRRT_kwDOTfywrM6b8wn2` PR #429 2026-08-25 — a filter argument was never validated, so a typo read as a real PR with no findings
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:804` `631b8db` `PRRT_kwDOTfywrM6b8wn3` PR #429 2026-08-25 — a failure arm promised no counts and then fell through to the arithmetic
- `partial-validation` `scripts/lib/pattern-ledger.sh:482` `631b8db` `PRRT_kwDOTfywrM6b8wn6` PR #429 2026-08-25 — a scalar grammar accepted literals the spec forbids
- `partial-validation` `scripts/lib/pattern-ledger.sh:317` `c0f39e4` `PRRT_kwDOTfywrM6b9jGx` PR #429 2026-08-25 — the record grammar checked the span count and tail but never the prefix
- `partial-validation` `scripts/lib/pattern-ledger.sh:480` `c0f39e4` `PRRT_kwDOTfywrM6b9jG5` PR #429 2026-08-25 — the repeated-table rule was fixed in one reader and not its sibling
- `toctou` `scripts/lib/pattern-ledger.sh:538` `c0f39e4` `PRRT_kwDOTfywrM6b9jG7` PR #429 2026-08-25 — liveness was read from a signal permission, so EPERM was mistaken for death
- `partial-validation` `scripts/lib/pattern-ledger.sh:740` `c0f39e4` `PRRT_kwDOTfywrM6b9jG-` PR #429 2026-08-25 — the one write that had no prior file was the one not published by rename
- `metric-scope-mismatch` `base/workflows/resolve-pr-threads.md:565` `c0f39e4` `PRRT_kwDOTfywrM6b9jHC` PR #429 2026-08-25 — per-round figures were overwritten each round, so only the last survived to the summary
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:687` `55d200e` `PRRT_kwDOTfywrM6b-wZB` PR #429 2026-08-25 — a library call with a documented failure code was invoked with no status branch
- `metric-scope-mismatch` `base/workflows/resolve-pr-threads.md:853` `55d200e` `PRRT_kwDOTfywrM6b-wZE` PR #429 2026-08-25 — round figures were subtracted from a scope another invocation also writes to
- `partial-validation` `scripts/lib/common.sh:2970` `55d200e` `PRRT_kwDOTfywrM6b-wZF` PR #429 2026-08-25 — a table header was compared literally, so a legal trailing comment hid every key in it
- `toctou` `scripts/lib/docs-lib.sh:527` `55d200e` `PRRT_kwDOTfywrM6b-wZI` PR #429 2026-08-25 — a verdict and the evidence behind it were read from two different file versions
- `ledger-coverage-gap` `base/workflows/implement-issue.md:745` `55d200e` `PRRT_kwDOTfywrM6b-wZP` PR #429 2026-08-25 — a preflight probed the names one step writes and not the names another does
- `stale-doc-claim` `scripts/selfcheck.sh:526` `55d200e` `PRRT_kwDOTfywrM6b-wZR` PR #429 2026-08-25 — comments quoted mutation totals that the suites had long since outgrown
- `stale-doc-claim` `scripts/selfcheck.sh:533` `55d200e` `PRRT_kwDOTfywrM6b-wZT` PR #429 2026-08-25 — a comment restated a claim the decision log had explicitly retired
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:588` `8c7d788` `PRRT_kwDOTfywrM6cIxmw` PR #429 2026-08-25 — an if-branch consumed a status the round was required to stop on
- `partial-validation` `scripts/lib/docs-lib.sh:290` `8c7d788` `PRRT_kwDOTfywrM6cIxmz` PR #429 2026-08-25 — a normalization taught to one reader and not to its sibling scanner
- `partial-validation` `scripts/lib/pattern-ledger.sh:486` `8c7d788` `PRRT_kwDOTfywrM6cIxm2` PR #429 2026-08-25 — the same normalization missing from the second sibling scanner
- `toctou` `scripts/lib/pattern-ledger.sh:588` `8c7d788` `PRRT_kwDOTfywrM6cIxm9` PR #429 2026-08-25 — a retry path skipped the sleep and the counter, so the bound never applied
- `false-guarantee` `scripts/lib/pattern-ledger.sh:269` `8c7d788` `PRRT_kwDOTfywrM6cIxnC` PR #429 2026-08-25 — a template claimed convergence on a path that exits before the check that would converge it
- `markup-injection` `scripts/lib/docs-lib.sh:520` `8c7d788` `PRRT_kwDOTfywrM6cIxnF` PR #429 2026-08-25 — stored text was rendered into markup unescaped, hiding the evidence it was kept for
- `precondition-ordering` `base/workflows/resolve-pr-threads.md:288` `3134b4b` `PRRT_kwDOTfywrM6cKc4w` PR #429 2026-08-25 — a step that reads and commits ran before the switch that makes its target legal
- `ledger-coverage-gap` `base/workflows/resolve-pr-threads.md:297` `3134b4b` `PRRT_kwDOTfywrM6cKc40` PR #429 2026-08-25 — a wildcard arm only warned, so an earned promotion stayed unwritten on a clean pass
- `partial-validation` `scripts/lib/common.sh:2990` `3134b4b` `PRRT_kwDOTfywrM6cKc43` PR #429 2026-08-25 — a table header was accepted without the closing bracket its grammar requires
- `markup-injection` `scripts/lib/pattern-ledger.sh:220` `3134b4b` `PRRT_kwDOTfywrM6cKc46` PR #429 2026-08-25 — a stored summary could carry the region markers that delimit the file it is written into
- `partial-validation` `scripts/lib/docs-lib.sh:216` `3134b4b` `PRRT_kwDOTfywrM6cKc4_` PR #429 2026-08-25 — a NUL byte was parsed rather than refused, normalizing a record the writer could not produce
- `partial-validation` `scripts/lib/pattern-ledger.sh:563` `3134b4b` `PRRT_kwDOTfywrM6cKc5D` PR #429 2026-08-25 — an override was checked for positivity but not for a width the shell can compare
- `toctou` `scripts/lib/docs-lib.sh:472` `3134b4b` `PRRT_kwDOTfywrM6cKc5J` PR #429 2026-08-25 — a declaration was re-read per call, so a verdict and its evidence could disagree
<!-- adb:hits:end -->
