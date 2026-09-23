<!-- GENERATED FILE — do not edit by hand.
     Source: base/workflows/implement-issue/review-prompt.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->
# /implement-issue — the review prompt, the rung ladder, and the effort knob

Read on demand from step 8. The prompt itself is **built by `bash "$HOME/.codex/scripts/lib/implement-lib.sh" dispatch-review`**
— the six lenses, the REQUIRED/OPTIONAL contract and the final check are code, so a slot cannot
be dispatched without them. This file explains what the prompt asks and how to read the ladder.

## What the built prompt asks, and why that shape

An ordered checklist with named categories, an explicit required-vs-optional split, and a final
check — the shape Codex's published guidance asks for (it is the shipped default reviewer), and
independently what makes a reply triageable in step 9 rather than a wall of prose. The same
prompt goes to whichever agent fills the slot. Every finding carries a `file:line` and a
REQUIRED/OPTIONAL mark. The six lenses:

1. **Correctness / edge cases** — empty, single, zero, negative, max, unicode; escaping wherever
   a value crosses a syntax boundary; off-by-one; idempotency; resource leaks.
2. **Reuse** — does this re-implement a primitive that already exists? Name the existing home.
3. **Altitude** — is the fix at the right depth, or a bandaid on shared infrastructure?
4. **Can a new guard actually fail?** — a check added by this diff must be shown capable of going
   red. A gate that cannot answer wrong is worse than no gate.
5. **Documentation conformance (#422)** — where the diff uses somebody else's API, is it used the
   way that vendor documents? A finding here is either a surface that should have been resolved
   and was not, or one that was resolved and then coded against differently.
6. **Claim integrity** — does every factual assertion the diff *adds* hold? A lint can prove
   `#N` resolves; only reading the diff proves the reference is *apt*.

Since #487 the prompt also carries **the pattern ledger's promoted checklist** — the classes this
project has already paid a review round for. It reaches the survey and the gap analysis through
`_il_append_checklist`, and the reviewer was the one dispatched agent that never saw it: the one
whose whole job is finding those classes. Same helper, same NOTE-never-fatal contract (a ledger
that does not parse, or a checklist over budget, notes and proceeds — a ledger problem never fails
a dispatch).

## The verdict trailer (#488)

A review reply must **end** with one machine-readable line:

```
ADB-REVIEW-VERDICT v1 required=<N> optional=<M>
```

It is the last non-blank line and the only line in the reply that begins with the sentinel;
`<N>`/`<M>` are plain integers with no leading zeros, and an explicit `0` is required rather than
omitted. `bash "$HOME/.codex/scripts/lib/implement-lib.sh" review-verdict <file>` is the one reader; `dispatch-review` calls it
after every dispatch and returns **28** when it refuses.

**Why a grammar rather than counting the word REQUIRED.** That count misreads at least three ways
— a finding that *quotes* an earlier one, a reply *truncated* mid-file, and the sentence "no
REQUIRED findings" which contains the token it denies — and every one errs toward **fewer**
findings, i.e. toward a false clean pass that pushes fix code no review ever read.

**What it does not prove**, so nobody reads more into it: a terminal trailer detects *suffix*
truncation, because truncation removes or damages it. It cannot prove the prose above it is
complete, nor that the declared counts match the findings actually written. Proving either needs
the prose parser this grammar exists to replace.

**The prompt asks for everything and filters nothing** — no "only high-severity", no "be
conservative": asked to be conservative, a model reports less, and the misses are silent.
Severity filtering has a home — step 9 triages. A finding you discard costs one line of reading;
a finding the reviewer withheld costs a defect.

The diff needs no envelope (it is your own work); the acceptance criteria are issue text and are
**contained** by the subcommand, with per-segment author attribution. The reviewer's *reply* is
not third-party text — it comes from an agent this repo declared — but it is still only advisory:
step 9 triages it, and no finding may widen the run's scope on its own say-so.

## The rung ladder, in full

`bash "$HOME/.codex/scripts/lib/role-dispatch.sh" review-rung codex` decides it once, over three readers
(`resolve review`, `available`, `bots --comparable`); `bin/agent-init` reads the same predicate,
so the setup report and step 8 cannot describe different rungs. Pass your own agent token: a run
driven by an agent that is not `primary` would otherwise be told `independent` about the very
model doing the writing.

- **`independent <token>`** — a usable CLI that is not the driving agent. The real thing.
- **`same-model <token>`** — the only usable reviewer *is* the driving agent. Run it, and label
  the slot *same-model (not independent)* in the close-out: it is rung 1 in mechanism only.
- **`deferred <logins>`** — nothing usable in-session, but an async reviewer is declared. Mark
  the slot deferred and proceed to the PR. **Narrower than it sounds:** the async reviewer gates
  *step 10's auto-merge arm* and nothing else — GitHub does not enforce the declaration, an owner
  can still merge by hand, and it never resolves a thread. Decided by `bots --comparable` (the
  reader the merge guard itself uses), not `--declared`, which accepts an allowlist no reviewer
  can ever match — a deferred rung the gate will not honour is a lie.
- **`none`** — nothing in-session, nothing declared. Proceed, and say plainly that nothing
  independent reviewed this diff. **Do not** manufacture a same-model subagent to fill the slot:
  a second opinion from the model that wrote the diff is not a second opinion, and it reads as
  coverage in the close-out. This is the one terminal state that is *not* a completed review, and
  it is distinct from a reviewer that ran and failed — "nobody was available" and "somebody
  broke" must not collapse into one outcome.
- **`unknown <why>` (rc 2)** — a reader failed (invalid `review` token, malformed
  `[reviewers] bots`, unresolvable `primary`). Fix the manifest; never guess past it — every one
  of those failures otherwise resolves to the flattering rung.

**A trailing `missing=<tokens>` can appear on any rung**, and every token in it is a slot that
did not run. `independent codex missing=gemini` means the diff *was* independently reviewed
**and** a reviewer the operator configured reviewed nothing. Report both.

## Effort (#225)

Resolve once — `bash "$HOME/.codex/scripts/lib/role-dispatch.sh" effort review` — and pass `--effort` to every slot, because
slots are dispatched by token and a bare token carries no role. Branch on the rc: **1** means
nothing declares one (inherit the CLI's own config — legitimate); **2** means the manifest
declares an *invalid* one, and mapping that to "" would dispatch at the workstation's setting
while `agents.toml` claims a bound. The backstop is not the budget: effort is what drives cost
(the shipped default for `review` is `medium`). Effort is not plumbed for `agy` — the flag is
accepted and ignored for a `gemini` slot rather than silently pretending to bound it.

## The Claude slot (when the manifest names `claude` and Claude is driving)

An in-process, two-part pass, both model-invokable — supported because a manifest may
legitimately name it (an unre-pointed `review`, or a Codex-primary repo where Claude *is* the
independent reviewer):

1. **`/simplify` first** — quality / reuse / simplification. It may edit code; if it does,
   re-run gates and refresh the diff before part 2, or the bug review inspects stale code. Never
   let it hand-edit a generated file (anything carrying a `GENERATED FILE` marker): revert, edit
   the `base/` source, rebuild. `/simplify` does not hunt bugs, so it does not by itself satisfy
   the slot.
2. **Adversarial bug review** — a Claude subagent (Agent tool, `general-purpose`) over the fresh
   diff (`dispatch-review --prompt-only` builds the same contained prompt for it), run
   synchronously. Hand the subagent the path the subcommand's `prompt-ready` line prints — this
   invocation's own kept stage — never the shared `review-prompt.txt`, which a concurrent slot's
   publish can remove or replace before the subagent opens it.

   **Then publish its reply — do not consume it directly** (#488):

   ```bash
   bash "$HOME/.codex/scripts/lib/implement-lib.sh" publish-review [--slot N] .codex/state   # the subagent's reply on stdin
   ```

   **Pass `--slot N` whenever this is not the first review slot** — the same number the dispatched
   path writes `review-N.md` under. Without it the publisher writes `review.md`, and a refused
   or later publication at that name removes the first slot's result.

   `--prompt-only` returns *before* any dispatch, so this path produces no `review.md` at all and
   a trailer required in the prompt would be validated nowhere — the grammar would cover dispatched
   slots only, which is the unvalidated second shape #488 exists to close. The publisher validates
   the reply whole and its trailer, then publishes `review[-N].md` through the same bounded path
   the dispatched slots write, so both paths produce one artifact with one contract. It is
   architecturally `publish-survey`; it deliberately does **not** truncate the way that one does —
   a review keeps its trailer through the full 8 MiB, and an oversize reply is refused instead.

   **The slot is not complete until `publish-review` accepts the reply.** A refusal (18/19) is the
   same terminal state as a refused dispatched slot, and it **removes** any earlier result at that
   slot: a previous pass's `required=0` left readable as this pass's verdict is exactly the false
   clean pass the grammar exists to prevent.

**Never model-invoke `/code-review`** (user-only, `disable-model-invocation`) — it is an optional
step the owner runs after the PR.
