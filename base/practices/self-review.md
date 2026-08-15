# Self-review before shipping

Before opening a PR, run a **dedicated self-review pass focused on real bugs** —
separate from writing the code, and separate from any independent reviewer.
<!-- adb:except claude -->

This is a **mandatory gate**, not a victory lap. It repeatedly catches genuine
landmines in freshly generated code before they reach a reviewer or production.

## What to look for

- **Edge cases:** empty input, single element, zero, negative, max, unicode.
- **Escaping / encoding:** shell, SQL, JSON, HTML, regex — anywhere a value
  crosses a syntax boundary. JS string-escaping bugs are common.
- **Binary / encoding corruption:** generated files with stray NUL bytes, wrong
  line endings, missing final newline, or a dropped pragma/shebang.
- **Cascade / cancellation effects:** does one change trigger a chain (a cancel
  guard, a cascading delete, a retry storm)? Trace it.
- **Off-by-one and boundary conditions** in loops, slices, ranges, pagination.
- **Idempotency:** can this run twice without corrupting state? (Queue consumers,
  migrations, cron, scripts especially.)
- **Resource leaks:** unclosed handles, unbounded growth, missing timeouts.
<!-- adb:end -->

## How

List each finding explicitly and either fix it or consciously disposition it with
a reason — before proceeding to push. "I read it over and it looks fine" is not a
self-review; naming what you checked is.

## A new guard is not done until it has been observed failing

This is not "test your code." It is the narrower claim that a **check** — a lint,
a gate, an assertion, a CI step — must be **seen going red** before you call it
done, on an input it is supposed to reject.

A guard's failure mode is **silence**. Ordinary code that breaks throws, returns
the wrong value, fails a test. A guard that breaks *passes*: it scans zero files,
matches zero lines, evaluates zero rules, and reports exactly what a clean run
reports. No existing test catches it, because every assertion still passes. So a
guard that cannot answer wrong is strictly worse than no guard — it costs CI time
and reports safety it never checked.

- **Prove it on the real superseded input**, not on a convenient one. A pattern
  that catches three of four spellings is green on the fourth. A negative pin
  written for a contiguous `[bot]$` matched neither of the two real idioms
  (`sed 's/\[bot\]$//'` and `sub("\\[bot\\]$"; "")`, where the bracket is always
  backslash-escaped) and shipped green while checking nothing.
- **Make the guard say what it checked**, not only whether it passed — the count
  of rules evaluated, files scanned, cases run. A zero is then visible in the log
  instead of indistinguishable from success.
- **Automate the observation where the set is closed.** If the guard's rules are
  enumerable, a harness that injects each rejectable input and asserts the guard
  goes red turns "I checked once" into a standing test. Where the set is open —
  an arbitrary future gate — this stays a discipline, not a mechanism, and saying
  so plainly is better than implying coverage that does not exist.

### Negative-test against a copy, never the live tree

To watch a check reject something, it needs a rejectable input — and the
temptation is to edit the real file, run the check, then put it back.

**Don't.** Copy the target into a temp dir and run the check against the copy.

Editing a tracked file to test a check that reads tracked files ends in `git
checkout -- <path>` or `git restore <path>` to "put it back", and if that file
also held uncommitted work, the work is gone with no reflog to recover it (see
`git-and-prs.md`). That exact sequence cost ~40 minutes of unsaved work. It is
also unnecessary: build the fixture — a temp dir, a throwaway git repo under
`mktemp -d`, a copy of the tree — and mutate that.

## Why

An explicit self-review pass has repeatedly caught real bugs — a cascade-cancel
guard bug, a JS-escaping bug, NUL-byte-corrupted generated files — that a casual
read missed. Making it a fixed step means it never gets skipped when a task runs
long or gets interrupted.

The guard rules are here for the same reason. Two guards shipped in one run
unable to fire — one negative pin that matched neither real spelling, one
identity predicate that normalized its two sides differently — and both were
caught only because the agent *chose* to negative-test. Nothing required it, and
nothing else would have noticed: a check that matches nothing is
indistinguishable from a check that found nothing wrong. The way that pin was
tested is why the copy rule sits beside it.
