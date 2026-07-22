# ai-dev-baseline — for Codex (and other agents) working on this repo

You are developing the **framework itself**. The full guide is in
[`CLAUDE.md`](CLAUDE.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md) — read them. The
non-negotiables:

- **Never edit generated root docs** — `agents/codex/AGENTS.md`,
  `agents/claude/CLAUDE.md`, `agents/gemini/GEMINI.md` are generated from
  `base/practices/*.md`. Edit the practices, then run `bash scripts/build.sh`.
  (This repo-root `AGENTS.md` is hand-written and is not one of the generated docs.)
- **Run `bash scripts/selfcheck.sh` before pushing** — it mirrors CI.
- **Portable, shellcheck-clean shell** (macOS bash 3.2 safe); **feature branch + PR
  only**; **file a tracked issue for anything deferred**.
