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
<!-- adb:hits:end -->
