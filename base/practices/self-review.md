# Self-review before shipping

Before opening a PR, run a **dedicated self-review pass focused on real bugs** —
separate from writing the code, and separate from any independent reviewer.

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

## How

List each finding explicitly and either fix it or consciously disposition it with
a reason — before proceeding to push. "I read it over and it looks fine" is not a
self-review; naming what you checked is.

## Why

An explicit self-review pass has repeatedly caught real bugs — a cascade-cancel
guard bug, a JS-escaping bug, NUL-byte-corrupted generated files — that a casual
read missed. Making it a fixed step means it never gets skipped when a task runs
long or gets interrupted.
