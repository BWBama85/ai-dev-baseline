<!-- GENERATED FILE — do not edit by hand.
     Source: base/practices/asking-the-operator.md · Regenerate: scripts/build.sh
     Edits here are overwritten on the next build. -->

# Questions to the operator — procedure

## Which tool, and when it is there

The tool belongs to the harness, so read what this turn lists rather than assuming:

| Harness | Structured question tool | Not offered when |
|---|---|---|
| Claude Code — the CLI, the desktop app, or a host such as T3 Code | `AskUserQuestion` | you are a subagent; or the run is non-interactive and nothing is attached to receive the prompt |
| Codex CLI | `request_user_input` | the turn's mode does not list it |
| any other harness | whichever question tool the turn lists | none is listed |

A tool the turn does not list is the answer "no tool this turn": ask in prose. So is a tool that
is listed but whose own description rules out this use — a mode it may not be called in, a kind
of question it is not for. Do not call a tool that is not listed or not permitted, and do not
treat its absence as a reason to drop the recommendation.

## The shape of a structured question

- **The recommended option is first**, its label ends `(Recommended)`, and its description carries
  the one-line reason.
- **One decision per question**, with options that exclude each other. Several independent
  decisions go in one call, up to the tool's own limit, rather than one turn each.
- **Each question is self-contained**: text you wrote earlier in the turn may not be on screen
  while the dialog is open.
- **The dialog is not a record.** When the workflow names where an answer is kept — a
  `## Decisions` row, a decision-log entry — write it there after the answer comes back.

## Before a turn ends

Check the last thing the turn says. If it is a question to the operator: was it asked through the
structured question tool (when the turn has one), does it carry a recommendation, and does it
stand alone? A trailing "want me to do X or Y?" in prose fails all three.

A hand-back that only *reports* — a wait that timed out, a read that failed, a blocked run and its
reason — is not a question and needs no dialog. Do not invent a question to end on.

## Why

Questions written as trailing prose were being missed: the operator had to notice the question,
type an answer and restart the flow, and often had to ask for a recommendation first. A structured
dialog is answered in one action, and a recommendation is the part of the decision the agent can
do in advance.
