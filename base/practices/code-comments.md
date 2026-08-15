# Code comments

**A comment is part of the code's interface, not the project's memory.** It states
what a reader cannot derive from the code in front of them: a contract, a
constraint, a non-obvious reason. Everything else has a home elsewhere, and keeping
it here charges every future reader — human or model — the tokens to skip it.

The rule covers **CI and workflow YAML** exactly as it covers `*.sh`, `*.ts`,
`*.py`. A pipeline definition is code.

## The four classes

Every comment you write, and every comment you touch while editing, is one of
these. Classify it, then dispose of it:

| Class | Disposition |
|---|---|
| **1 — Operative contract**: usage, arguments, exit codes, output format, globals read or written, a non-obvious constraint or invariant | **Keep**, in the form below. |
| **2 — Incident history**: "PR #N shipped this bug, which is why…", a dated outage, a narrative of what broke | **Relocate** to `.ai-dev-baseline/decisions.md` (`handling-the-unknown.md`). Leave behind the one-line rule the incident proved, and cite the decision id — never retell the incident. |
| **3 — Design alternatives**: "X and Y were considered; Y loses because…", benchmark tables, a rejected approach argued out | **Relocate** to the decision log, or delete. A rejected alternative is a decision, not an interface. |
| **4 — Restated policy**: text duplicating a `base/practices/` rule, a root doc, or a workflow step | **Delete.** The law has one home. A copy in code is a second home that drifts, and the drifted copy is the one being read at the moment it matters. |

When a comment mixes classes — most long ones do — split it. The class-1 sentence
stays; the rest goes to its home or goes away.

## The form: Google Shell Style Guide

Fetch the guide at implementation time via context7, library id
`/websites/google_github_io_styleguide` — never from recall
(`third-party-claims.md`). Its shape, as fetched:

- **File header** — one top-level comment describing the file's contents. One line
  of purpose; copyright and author optional.
- **Function comments** — only for functions that are not both obvious *and* short;
  in a library, that is all of them. Written as API behavior: description,
  `Globals:`, `Arguments:`, `Outputs:`, `Returns:`. Terse.
- **Implementation comments** — only for tricky, non-obvious, or important parts.
  Not every line, and never the code restated in English.
- **`TODO:`** — for a temporary, short-term or knowingly imperfect solution,
  carrying the identifier that gives it context.

Other languages: same three-part shape, that language's idiom (docstring, JSDoc,
doc comment).

The guide stops there; this baseline adds one rule on top of its `TODO:`. Where the
project tracks work, a TODO that clears `issues-and-scope.md`'s bar is an **issue**
and not a comment — and one that answers neither of that file's two questions is
neither, so it is deleted.

## What explicitly stays

- **A guard's contract header.** `self-review.md` requires a guard to say what it
  checked and to be observed failing; the header naming its rejectable inputs, its
  exit codes and its output contract is class 1 and is load-bearing. Keep it terse.
  Do not mistake it for class 2 because it mentions the defect it rejects.
- **The one-line residue of a relocated incident.** State the rule, not the story —
  "published by rename; a truncate is observable to a live reader" — and point at
  the decision-log entry that carries the evidence.
- **A constraint whose reason is invisible at the call site.** An ordering
  requirement, a fail-closed choice, an interpreter floor, a deliberate
  non-obvious spelling. One or two lines: what breaks if you change it.

## No numeric cap

There is no target ratio and no maximum length. A forty-line contract header for a
library with forty lines of contract is correct; a three-line comment restating a
practice is not, at any ratio. **The classes are the rule.** A density target would
license deleting class 1 to reach a number, and class 1 is the one class that must
survive.

Measured on this framework's own repo, 2026-08-15: 26,015 of 59,681 shell lines —
44% — were comment lines, with one library at 67% and a single 197-line comment run.
A 197-line run is not a contract.

## What this does NOT enforce

- **Prose, no lint.** Nothing counts comment lines, classifies one, or blocks a
  commit on this. The classes are not decidable from the text by a matcher, and a
  density check would fire hardest on the class worth keeping.
- **Enforcement is review-side.** The self-review pass and the reviewer name the
  class and the disposition, or nobody does. "Comment density" is not a finding;
  "this is class 3, move it to the decision log or drop it" is.
- **It stops at the comment character.** Instruction prose — practices, workflows,
  root docs — is out of scope here, and no claim is made that anything else governs
  it.
