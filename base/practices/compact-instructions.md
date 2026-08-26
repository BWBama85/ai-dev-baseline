# Compact instructions

When this conversation is compacted, the summary is the only memory the next context has of a run
that is still in flight. Preserve the following **verbatim** — never paraphrased, never "see
above":

- **The workflow in progress and its current step** — which command was invoked (`/implement-issue`,
  `/roadmap`, `/resolve-pr-threads`, …), the step it is on, and the run marker's current phase.
- **The run's state-directory path** (`.claude/state` or the agent's equivalent) and the paths of
  every run artifact under it that has been read this session: the gap-analysis prompt and
  findings, the review prompt and findings, the documentation-duty record.
- **The list of files modified in this session**, by path, and which of them are committed.
- **The gate command that was run and its last result**, and any gate that is still red.
- **Every review finding marked REQUIRED, with its disposition** — fixed (naming the commit),
  deferred (naming the issue), or disputed (one line of why). An open REQUIRED finding that the
  summary drops is a defect that ships.
- **The branch and the issue numbers** the run is working, and the PR number once one exists.
- **Every decision the operator made this session** and the reasoning recorded for it.

Drop freely: tool output that has already been acted on, exploration that led nowhere, and the
text of documents that can be re-read from disk.

This block is guidance to the summarizer, not a mechanism. The facts the run itself wrote — phase,
phase history, branch, issue numbers, artifact paths — can be read back from the state directory
after the fact (`run-state.sh summary`), and where the agent wires a post-compaction hook to do so
(Claude's `session-context.sh` on `SessionStart` `compact|resume`; other agents' equivalents ride
their enforcement-hook work) they are restored regardless of what the summary kept. What no hook
can restore is what only the conversation held: the modified-file list, the gate result, and each
finding's disposition. That is what this block exists to keep.
