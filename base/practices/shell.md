# Shell discipline

The interactive shell is commonly **zsh** (macOS default) and **bash** on Linux
CI. Write commands that work in both, and default to POSIX `sh` semantics unless
you are running a script with an explicit `#!/usr/bin/env bash` shebang.

## Rules

- **One command, one purpose.** Prefer several simple calls over a long
  `A && B && C && D` chain. Compound chains are harder to permission-approve,
  harder to attribute when one link fails, and more likely to be denied outright
  by command-safety gating. Run steps separately unless they are genuinely one
  atomic operation.
- **No bashisms in `sh`/inline contexts.** Bash arrays, `[[ … ]]` where `[ … ]`
  works, `<(…)` process substitution, `${var^^}` case tricks, and `source`-ing
  interactive rc idioms all break or behave differently under zsh/sh. If you need
  bash features, put them in a real `bash` script, not a one-liner.
- **Quote every expansion.** `"$file"`, `"${arr[@]}"`. An unquoted variable
  containing a space or a glob char (`* ? [`) will word-split or glob-expand and
  silently do the wrong thing.
- **Never assign to a zsh-special name.** `path`, `fpath`, `cdpath`, `manpath`,
  `module_path` and `argv` are **bound to shell state** in zsh — `path` *is*
  `$PATH`. A loop like `read -r kind path key` therefore empties the search path
  on its first iteration, and every external command after it fails with
  "command not found". Under bash the same line is harmless, so this survives
  review and every bash-based test, then breaks on the default macOS shell. Pick
  a neutral name (`file`, `sfile`, `entry`) — and remember the rule applies to
  any snippet an agent executes, not just to `.sh` files.
- **Don't assume PATH — and know that `bash` itself is one of the things it
  decides.** Non-interactive shells may not have your rc's PATH. If a
  brew/user-installed tool might be missing, export the prefix explicitly once
  (e.g. `export PATH="/opt/homebrew/bin:$PATH"`) rather than relying on login
  shell setup.

  On macOS this reaches the **interpreter**, not just the tools. `/bin/bash` is
  **3.2.57** and Apple has pinned it there for the whole bash-4-and-later era, so
  a modern bash is a Homebrew install at `/opt/homebrew/bin` (Apple Silicon) or
  `/usr/local/bin` (Intel) — reachable *only* through `PATH`. A
  `#!/usr/bin/env bash` script therefore runs whichever bash `PATH` happens to
  resolve, and the shells least likely to carry the Homebrew prefix are exactly
  the ones with no human watching: hooks, gate scripts, anything spawned by
  another agent's CLI.

  Two consequences worth stating separately:
  - **Ordering matters, not just membership.** A `PATH` that contains the
    Homebrew prefix *after* `/usr/bin:/bin` still resolves the 2006 interpreter.
    A defensive rc line written to make non-interactive shells work is a common
    way to end up there.
  - **A project with a bash floor should enforce it at the entry point**, by
    re-exec'ing into a known-good interpreter rather than trusting `PATH` — and
    failing loudly with the platform's install command when there is none. By the
    time your code runs, `PATH` has already given its answer.
- **Globs and `find`:** when a glob may match nothing, guard it (`shopt -s
  nullglob` in bash, or iterate `find … -print0 | while IFS= read -r -d ''`).
  Don't let an unmatched glob leak through as a literal argument.

## Background processes

A wait is a guard, and a guard whose predicate cannot match is indistinguishable
from one that is still waiting.

- **Never poll what already notifies.** A harness-tracked background task signals
  its own completion, and that signal *is* the wait. Hand-rolled polling is for
  external state the harness cannot see, and for nothing else.
- **Prove the predicate before a loop depends on it.** Match it against one real
  instance of the completed output first — `self-review.md`'s rule that a check is
  not done until it has been observed answering. A pattern written against a
  remembered log format is a guess.
- **Every poll loop carries a hard deadline** — a timeout, or a maximum iteration
  count. A wrong predicate must expire loudly; it must never spin silently.
- **One waiter per event.** A second, belt-and-braces waiter on the same event is
  how orphans are made: it outlives the answer, and nothing reports it.
- **Inventory before ending the turn.** List the running shells and tasks, stop
  every one you own that is no longer needed, and state what remains and why.

`scripts/lib/pr-watch.sh`'s `wait` is the worked example: bounded, in-shell, one
waiter for one event, so a long wait costs no model tokens.

Measured on 2026-08-15 in this repo: two orphaned loops — one whose completion
pattern matched no line the log could produce, the second chained to the first —
spun unbounded and redundant to a task notification the session already had, until
a human asked why the shells were open.

No hook enforces this. Background tasks are harness-managed and not enumerable
from a Stop hook, so the practice and the turn's own report are the whole
mechanism.

## Why

Shell-environment friction — bash array expansions and globs failing under zsh,
exit-127 sourcing errors, and blocked compound commands — is a recurring source
of wasted retries. Defaulting to portable, single-purpose commands eliminates it
before it starts.
