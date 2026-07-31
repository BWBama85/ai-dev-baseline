# ai-dev-baseline — for Codex (and other agents) working on this repo

You are developing the **framework itself**. The full guide is in
[`CLAUDE.md`](CLAUDE.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md) — read them. The
non-negotiables:

- **Never edit generated root docs** — `agents/codex/AGENTS.md`,
  `agents/claude/CLAUDE.md`, `agents/gemini/GEMINI.md` are generated from
  `base/practices/*.md`. Edit the practices, then run `bash scripts/build.sh`.
  (This repo-root `AGENTS.md` is hand-written and is not one of the generated docs.)
- **Run `bash scripts/selfcheck.sh` before pushing** — it mirrors every *offline* check CI
  runs. One CI step is deliberately not mirrored (the `repo-settings` job's live
  `required-drift` read, #122), so a local green does not predict that one. See Golden Rule
  #3 in [`CLAUDE.md`](CLAUDE.md) and D13 in `.ai-dev-baseline/decisions.md`.
- **Portable, shellcheck-clean shell** (macOS bash 3.2 safe); **feature branch + PR
  only**; **file a tracked issue for deferred work that clears the bar** — name who does
  it and what breaks if nobody does (`base/practices/issues-and-scope.md`); either
  unanswerable, file nothing.
