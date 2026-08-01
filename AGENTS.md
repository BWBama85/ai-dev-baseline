# ai-dev-baseline — for Codex (and other agents) working on this repo

You are developing the **framework itself**. The full guide is in
[`CLAUDE.md`](CLAUDE.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md) — read them. The
non-negotiables:

- **Never edit generated root docs** — `agents/codex/AGENTS.md`,
  `agents/claude/CLAUDE.md`, `agents/gemini/GEMINI.md` are generated from
  `base/practices/*.md`. Edit the practices, then run `bash scripts/build.sh`.
  (This repo-root `AGENTS.md` is hand-written and is not one of the generated docs.)
- **Run `bash scripts/selfcheck.sh` before pushing** — it mirrors most of CI's *offline* checks.
  Three things a local green does **not** predict: the two **live** steps (the `repo-settings`
  job's `required-drift` read, #122, and the claim lint's `--live` half, #212); the **other
  platform** (CI runs the offline suite on `ubuntu-26.04` *and* `macos-latest`, #257); and
  `check-bash-floor.sh --runtime`, which is offline and runs in every CI job but is omitted
  locally on purpose — what it adds beyond #256's entry gate is an assertion about the machine and
  about `command -v bash`, i.e. a CI-image question. See Golden Rule #3 in [`CLAUDE.md`](CLAUDE.md), D13/D24/D29 in
  `.ai-dev-baseline/decisions.md`, and [`docs/ci-runners.md`](docs/ci-runners.md).
- **Shellcheck-clean shell on bash >= 5.3** (the runtime floor, #255 — every entry point
  calls `adb_require_bash`; `scripts/lib/common.sh` and `check-bash-floor.sh` are the two
  documented exemptions, D30/D31); **feature branch + PR
  only**; **file a tracked issue for deferred work that clears the bar** — name who does
  it and what breaks if nobody does (`base/practices/issues-and-scope.md`); either
  unanswerable, file nothing.
