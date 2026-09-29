<!-- GENERATED FILE — do not edit by hand.
     Source: base/practices/shell.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->

# Shell discipline — procedure

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

**But a cheap wait is only cheap if it is DISPATCHED cheaply, and that is the
caller's half.** The command spends nothing while waiting; re-entering the model
to start its next stretch costs a full turn, and an agent harness that caps a
foreground shell call well under the bound forces exactly that. Measured on an
adopting project: dozens of consecutive turns of *"Waiting."* — *ran 2 shell
commands* — *"Waiting."*, one per interval. So where the harness runs a command
detached and re-invokes on completion, **dispatch a long wait as a background
task and let the notification be the wake signal** — that is the same rule as
*never poll what already notifies*, applied to a wait you started yourself.

**Where it does not, take the SHORT wait rather than faking a long one.** Size the
bound to fit under the harness ceiling, run it once, and treat expiry as terminal.
Do **not** chunk it across repeated foreground calls to synthesize a longer wait:
the overall deadline is then held by the driver, a re-entry restarts it silently,
and a bound that can be silently restarted is not a bound — the rule two lines up.
Report once when the wait starts and once when it resolves or expires; never one
line per interval.

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
