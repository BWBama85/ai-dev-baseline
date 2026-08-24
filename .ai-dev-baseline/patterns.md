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
<!-- adb:hits:end -->
