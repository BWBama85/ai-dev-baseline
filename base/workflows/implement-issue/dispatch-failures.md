# /implement-issue — dispatch failures, exit codes, and every documented stop

Read on demand when a subcommand or a dispatched agent returns non-zero. The one-line rule:
**branch on the exit code, read the classified line at the tail of the `.err` file, and never
infer liveness from output sizes.**

## The completion contract

`gap_analysis`, `survey`, `review`, and any cross-agent or subagent dispatch must reach a
terminal, *completed* state; "advisory" is the standing of completed findings, never a license to
skip the **step**. Run each as a **single bounded call and wait for it to return** (process exit
for `codex exec` / `agy -p` / `claude -p`; the tool result for an Agent subagent). Never poll a
background agent's output to infer whether it is hung — `gaps.err` grows steadily during healthy
exploration, so its size tells you nothing; the outcome is the call returning.

**Dispatch long calls through your harness's detached-execution facility** — whichever mechanism
runs a command off the foreground path and reports its terminal status back to you. A shell `&`
is not it, on any harness: `&` inside one foreground call is still inside that call's cap, and a
later shell cannot `wait` on an earlier shell's child (#93). The prompt lives in a file for
exactly this reason.

`{{ROLE_DISPATCH}} invoke` runs the resolved agent's CLI under a **45-minute (2700 s) hang
backstop** — it stops a wedged process and otherwise stays out of the way, escalating TERM →
grace → KILL so it always terminates. `ADB_DISPATCH_TIMEOUT_SECS` overrides it — clamped at 2700 s
for the gap dispatch, its share of the claim lease; the survey
dispatch tightens its own default to `ADB_SURVEY_TIMEOUT_SECS` (1200 s, clamped at 1500 s — its
share of the same lease, with margin) because a survey that
needs 45 minutes has defeated its purpose. Do not re-derive a millisecond ceiling for the
surrounding call — capping the *foreground* call is the bug the background rule exists to
prevent.

## The dispatch rc classification (all `dispatch-*` subcommands pass it through)

| rc | What it means | Response |
|---|---|---|
| `0` | completed | read the output file; findings are inputs to the next step |
| `3` | the role is unassigned (`gap_analysis` unset/`""`, `survey = ""`) | the documented skip — note it for the PR and continue |
| `124` | our backstop fired | retry once, then treat per the role's failure policy below |
| `143` | an *outer* bound killed it first | re-dispatch in the background, or raise that outer bound — not ours |
| `137` | external SIGKILL (OOM killer or the harness) | a memory/environment problem, not the agent; investigate before re-running |
| `18`/`20` | the manifest, a read, a write, or prompt assembly failed | the stderr line names it; fix and re-run the subcommand |
| other non-zero | a real agent error | retry once, then per the role's failure policy |

**Empty stdout beside a huge `.err` is not a diagnostic signal.** `codex exec` returns its result
as a final message, not a stream, so a bound-killed run yields empty stdout whether or not it was
progressing, and the large `.err` is evidence of *active work*. Read the classified rc instead.

## Per-role failure policy — three different shapes

- **`gap_analysis` never substitutes another agent.** Retry once; if the retry also fails, report
  the classified incompleteness and stop cleanly (pre-branch: release the claim, write no blocked
  file). Quietly running one model while `agents.toml` names another is what makes the role
  assignment fiction; a bound that is too small must surface as a bound problem, not as a silent
  agent swap.
- **`survey` is an accelerator, not a gate (#435).** Retry once; if the retry also fails,
  **continue without it** and say so — a `NOTE` in the run and one line in the PR body naming the
  rc. Blocking on the survey would make the loop slower than before it existed. The asymmetry
  with `gap_analysis` is deliberate and stated.
- **`review` slots retry once, then fall back cross-model only.** A fallback must be an agent the
  role lists whose CLI `available` reports usable, and never a subagent of the model that wrote
  the diff — that reports as coverage while supplying none. When no cross-model stand-in is
  usable, the slot has **failed** and the run blocks (write the blocked marker, `phase` stays
  `committed`). A reviewer whose CLI was **absent** before dispatch never ran at all: that is
  rung 2 or 3, reported, never a blocked run.

## The subcommand exit codes (beyond the dispatch classification)

| rc | Subcommand | Meaning |
|---|---|---|
| `10`–`14` | `admit` | refused — another run's marker (10), unreadable marker (11), no jq / bad lease (12), claim held (13), state dir unusable (14). Never delete the other run's state to get past it. |
| `13` | `snapshot-issues` / `dispatch-survey` / `dispatch-gaps` | the run claim now belongs to a SUCCESSOR run (this run was reaped after its lease expired) — stop; never write artifacts the live run owns |
| `20` | any | a required read/write failed (gh, jq, git, the state dir, prompt assembly) |
| `21` | `snapshot-issues` | an issue in the set is not OPEN — stop and confirm with the owner; never silently reopen shipped work |
| `22` | `snapshot-issues` | the state dir would not be gitignored — fix `.gitignore` (or re-run `bin/agent-init`) first |
| `23` | `open-pr` | the closing keywords did not register: GitHub's link set ≠ `--closes`. Fix the body with `gh pr edit` NOW — after the merge the auto-close can never fire |
| `24` / `25` | `open-pr` | the push / `gh pr create` failed |
| `26` | `open-pr` | the run marker is unreadable, or HEAD is not on its branch |
| `27` | `open-pr` | the worktree is not clean — an uncommitted or untracked change would be pushed around, so the reviewed tree is not the tip; commit it (or gitignore what is not part of the change) and re-run |

## Every documented stop, in one place

- **`admit` 10/13** → another run is live in this checkout (its marker; its pre-marker claim).
  Pre-branch stop: no blocked file, nothing deleted. Finish that run or `/cleanup` it.
- **`admit` 11/12** → a fact could not be established, so nothing was deleted. Fix the file (or
  install jq) rather than re-running and hoping.
- **A claim survives a killed run** → its lease (9000s) expires and the next run breaks it with a
  NOTE. Waiting is correct; deleting `{{STATE_DIR}}/gap-analysis.lock` is the documented escape
  when you are certain the run is dead.
- **A refusal that does NOT clear itself** → an abandoned marker whose branch ref survives, a
  malformed marker, a persistent `gh` failure, wrong permissions on `{{STATE_DIR}}`. Each refusal
  prints its recovery; act on what it printed.
- **Gates fail the same way three consecutive times after fixes** → write the blocked marker and
  stop. Never push red.
- **Branch already exists on remote** → blocked marker; ask the user; never force-push.
- **The Stop hook keeps blocking** → you are trying to end before the PR is open; open it or
  write the blocked marker. Don't fight the hook.
- **The Stop hook nags about a run you never started** → it is reading a marker owned by another
  session sharing this checkout. Do not obey it, and do not delete that marker. Confirm with
  `jq -r '.owner, .branch' {{STATE_DIR}}/implement-issue-active.json`: an `owner` that is not
  your session id means the marker is not yours. A gate that still nags after that is running
  without an owner on either side, which falls back to branch-name matching by design.
- **`/code-review` errors with `disable-model-invocation`** → expected: it is user-only by design
  (it can launch a billed cloud review). The Claude review slot never invokes it; do not file a
  toolchain issue.
- **`gh pr merge --auto` errors with "Pull request is in clean status"** → expected: GitHub
  refuses to *queue* a PR that could merge right now (the no-required-checks case; `automerge-ok`
  returns 11/12 precisely so `open-pr` never reaches the arm). Do **not** retry as a plain
  `gh pr merge` — that merges unreviewed code immediately. Report and leave the PR open.
