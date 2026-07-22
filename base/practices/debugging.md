# Root-cause debugging

**Trace to a definitive root cause with evidence — never ship a guess.**

"Probably X" is a hypothesis, not a diagnosis. A fix built on an unproven cause
is a coin flip.

## Protocol

1. **Reproduce.** Get the failure to happen on demand — a failing test, a query,
   a log slice, a repro script. If you can't reproduce it, you can't prove you
   fixed it.
2. **Prove the cause.** Use logs, DB/state queries, diffs, timestamps, and where
   possible a **failing regression test written before the fix.** Cite concrete
   evidence (`file:line`, a log line, a row, a hash) — not a narrative.
3. **Symptom location ≠ cause location.** The line that throws is often not the
   line that's wrong. Grep for the *class* of the bug, not just the one instance —
   if one helper has it, its siblings may too.
4. **Rule out your own state first.** Before blaming a platform or library:
   - Is the running/deployed build behind the source? A deployed environment can
     lag the default branch behind a release gate — check the deployed version vs.
     the latest tag before filing a "platform bug."
   - Is a stale fixture, cache, or local migration masking the real behavior?
5. **Fix the cause, add the regression test, ship via the normal PR + gates path.**
   The test that reproduced the bug in step 2 is now the test that guards it.
6. **File follow-ups.** If the investigation surfaces a broader class or a
   systemic gap, file a tracked issue (see `issues-and-scope.md`).

## Why

The strongest debugging sessions trace incidents to a provable root cause —
dead-letter queues to an overload source, a poisoned value to the exact commit
that leaked it. The weak ones guess and patch. Make evidence the default and the
fix follows cleanly.
