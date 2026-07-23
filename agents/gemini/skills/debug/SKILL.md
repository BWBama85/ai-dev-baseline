---
# GENERATED FILE — do not edit by hand.
# Source: base/workflows/debug.md · Regenerate: scripts/build.sh
# Edits here are overwritten on the next build.
# $ARGUMENTS below marks where THIS skill's invocation arguments go (e.g. the issue/PR
# number). This surface loads the body as instructions, NOT as a macro-expanded prompt,
# so $ARGUMENTS is a placeholder you substitute with the real values, not a live shell
# variable — fill it in when you run a step. Some other refs (Stop-hook gating,
# /code-review, .claude paths) are Claude-specific; per-agent equivalents ride #14/#25.
name: debug
description: Root-cause a bug or production incident with evidence — reproduce it, prove the cause (logs / queries / a failing regression test), rule out your own stale state, fix the cause, and ship through the normal PR + gates path. Never guesses; never re-runs flaky CI to make red go green.
---

# /debug

Trace **$ARGUMENTS** to a definitive, evidence-backed root cause and fix the cause —
not the symptom. Implements `base/practices/debugging.md` as a repeatable flow. The
bar: you can point at the exact line/commit/row/log that proves the cause before you
change anything, and you leave behind a regression test that would have caught it.

## Anti-patterns this skill refuses

- **Guessing.** "Probably X" is a hypothesis to test, not a diagnosis to ship.
- **Symptom-patching.** The line that throws is often not the line that's wrong.
- **Flaky-CI gambling.** Never re-run a red job to get a lucky green
  (`base/practices/ci-discipline.md`). Classify flaky vs real with evidence first.

## Steps

### 1. Frame the failure

State precisely: what is observed, where, expected vs actual, and how you know it's
happening (the error string, the alert, the failing test, the user report). Grep the
codebase for the exact error/log string and cite the emitting `file:line` — a symptom
you can't locate in source you can't yet explain.

### 2. Reproduce

Get the failure to happen on demand: a failing unit/integration test, a query, a
script, or a captured log slice. If you cannot reproduce it, say so and gather more
signal (logs, metrics, state) before proposing any fix — you cannot prove a fix for a
failure you can't trigger.

**Looking at logs / live state** (use whatever the project provides):
- App/CI logs, structured log search, error trackers.
- Datastore queries for the suspect rows/keys.
- Platform observability where wired (e.g. a Cloudflare Worker's tail/analytics, a
  queue's dead-letter contents) — read-only queries only; never mutate production to
  reproduce.
Filter aggressively (grep/pattern) so you read signal, not noise.

### 3. Prove the cause

Nail it with evidence, not narrative:
- A **failing regression test written before the fix** is the gold standard — it
  reproduces the bug and becomes its guard.
- Otherwise cite concrete proof: a diff, a timestamp ordering, a row value, a hash, a
  specific log line. "This value is 57 bytes and the real one is 4KB" beats "seems
  wrong."
- **Symptom location ≠ cause location.** Grep for the *class* of the bug — if one
  helper has it, its siblings likely do. Name them (fix or scope out).

### 4. Rule out your own / stale state first

Before blaming a platform or library:
- **Is the deployed build behind source?** A live environment can lag the default
  branch behind a release gate — check the deployed version vs. the latest tag before
  filing a "platform bug." A prod error from an old build is not a code bug.
- **Stale fixture / cache / local migration** masking real behavior?
- **Test time-bombs:** fixed seed dates aging past a now-relative filter, order
  dependence, timezone/locale — these masquerade as flakiness.

### 5. Fix the cause + add the regression test

Implement the minimal fix at the cause. Keep the step-3 failing test (or add one) so
the bug can't silently return. Run the project's gates until green
(`bash "$HOME/.gemini/scripts/lib/project-gates.sh" run`). If the fix is more than a
one-liner, hand off to `/implement-issue` on a tracked issue rather than shipping a
large change straight from a debug session.

### 6. Ship + file follow-ups

- Ship via the normal feature-branch + PR + gates path (never push to the default
  branch, never `--no-verify`).
- If the investigation surfaced a broader class, a systemic gap, or work you're
  deferring, file a tracked issue (`base/practices/issues-and-scope.md`) — evidence,
  root cause, and the concrete follow-up. Cross-link it.
- If the fix needs something the baseline doesn't model (a project-specific gate,
  convention, or a general gap), place it deterministically per
  `base/practices/handling-the-unknown.md` — its one prescribed home, recorded — rather
  than a bespoke local patch.

## Output

An evidence-backed root-cause writeup: the symptom, the reproduction, the **proof**
of the cause (the line/commit/row/log), the fix, the regression test, and any
follow-up issues filed. If the cause is genuinely not yet proven, say exactly what
evidence is still missing — never present a guess as a conclusion.
