# CI runners — proving the bash 5.3 floor on both platforms

This repo's runtime floor is **bash 5.3** (owner decision, 2026-08-01 — epic #255). A floor that
CI does not execute is a claim, not a floor, so every CI job runs on a runner image this document
records evidence for, and every job proves at runtime which interpreter it actually got.

`scripts/check-bash-floor.sh` is the one home for both halves. This file is the *why*; the script
is the *enforcement*.

## The choice, and the evidence

| Platform | Label | bash | Evidence |
|---|---|---|---|
| Linux | **`ubuntu-26.04`** | **5.3.9(1)-release** | [`actions/runner-images` Ubuntu2604 inventory][u26] — also jq 1.8.1, ShellCheck 0.11.0-2, Git 2.53.0, all preinstalled |
| macOS | **`macos-latest`** (= macOS 26 arm64) | 3.2.57 at `/bin/bash` → **Homebrew 5.3** after `brew install bash` | [`actions/runner-images` macos-26-arm64 inventory][m26] — Homebrew 6.0.13, jq 1.8.2, Git 2.55.0; **no ShellCheck** |

Rejected, and why it matters that it is written down:

- **`ubuntu-latest` is the trap.** It resolves to `ubuntu-24.04` today, whose bash is **5.2.21** —
  *below* the floor. A repo that "adopted 5.3" while running CI on `ubuntu-latest` would be
  validating every PR against an interpreter older than the maintainer's own (which moved to
  Homebrew 5.3.15 on 2026-08-01). The failure direction is the dangerous one: local passes, CI
  fails, and only for constructs nobody has written yet.
- **`ubuntu-25.10`, Debian stable/testing** — 5.2.x, below the floor (#255's platform table).
- **Windows** — not a job here at all. Windows is supported **via WSL2 only** (owner decision on
  #2), and WSL2 on Ubuntu 26.04 runs a bash and userland identical to the Linux job, so a Windows
  runner would re-prove it at several times the cost. #2 owns the genuine WSL delta (CRLF from a
  Windows-side clone, `/mnt/c` DrvFs semantics) plus a release/weekly smoke job.

[u26]: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md
[m26]: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md

## `ubuntu-26.04` is a public-preview image

GitHub ships it as **public preview**: supplied as-is, no SLA, and longer queue times than a GA
image. That is a real cost and it is accepted deliberately — it is the only GitHub-hosted Linux
label that clears the floor, and #255 chose the floor knowing this.

**The fallback threshold, so "if it proves unstable" is not left to taste.** Fall back only for
**image or provisioning** failures — queue times that block merges, image pulls that fail, a
runner that never starts. Do **not** fall back for a *reproducible test failure* caused by the
newer bash, Git, jq, ShellCheck or coreutils on that image: that is a real portability finding on
the platform this repo is moving to, and `base/practices/debugging.md` applies — diagnose it,
don't route around it. The distinction is whether the suite got to run.

The fallback itself is `ubuntu-24.04` plus a per-job bash install (every job gets a fresh VM, so
it is per-job, not once):

```yaml
    runs-on: ubuntu-24.04
    steps:
      - name: Install bash 5.3
        run: |
          set -uo pipefail
          brew=/home/linuxbrew/.linuxbrew/bin/brew    # present on the 24.04 image, off PATH
          "$brew" install bash || exit 1
          echo "$("$brew" --prefix bash)/bin" >> "$GITHUB_PATH"
```

That is 26 Homebrew installs per CI run, which is why it is the fallback and not the design. If it
is ever taken, add `ubuntu-24.04` to `APPROVED_LINUX` in `scripts/check-bash-floor.sh` — the lint
is the thing that has to agree, and it will fail loudly until it does.

## macOS: the floor is reachable only through `PATH`

Apple pins `/bin/bash` at **3.2.57** — a 2006 release — permanently, for GPLv3 reasons, and system
integrity protection keeps it there. Homebrew installs 5.3 alongside it at
`$(brew --prefix bash)/bin/bash`, so **every** macOS install of this framework resolves its
interpreter through `PATH`. That is exactly the surface `base/practices/shell-discipline.md` warns
is absent in non-interactive shells — the shells that hooks and gate scripts run in — which is why
macOS is the platform worth spending a CI job on, and why #256 exists.

The job therefore does three things in order:

1. `brew install bash shellcheck` — under Apple's 3.2, because that is all there is yet.
2. `echo "$(brew --prefix bash)/bin" >> "$GITHUB_PATH"` — `GITHUB_PATH` **prepends**, and applies
   to **subsequent steps only**, which is why the proof cannot live in this step.
3. `bash scripts/check-bash-floor.sh --runtime` — the proof, in its own step.

**ShellCheck is installed on purpose.** `scripts/selfcheck.sh` *SKIPs* its shellcheck step when the
binary is absent, and the macOS image does not ship one. Without that install, "the full suite runs
on macOS" would be false in precisely the silent way this repo keeps writing guards against.

### `$BASH`, not `command -v bash`

The runtime guard asserts on **both** the interpreter executing it (`$BASH`) and the one `PATH`
resolves (`command -v bash`), because on macOS they diverge exactly when it matters. Run a script
under `/bin/bash` 3.2 with Homebrew first on `PATH` and `command -v bash` reports the 5.3 while the
code runs on the 3.2 — verified locally, same script, two invocations:

```
running interpreter /bin/bash (3.2.57)          <- what is executing
PATH-resolved bash  /opt/homebrew/bin/bash (5.3.15)   <- what `command -v bash` reports
```

A guard reading only the second line passes while running on the 2006 interpreter. Both are
asserted, and both are printed, so the log says what was checked rather than only that it passed.

## Why not a `strategy.matrix`

Because it would deadlock every merge in the repo.

`scripts/lib/repo-settings.sh` discovery **skips matrix jobs** — their check-run names gain a
matrix suffix, so a statically-required context name can never match (`docs/repo-settings.md`).
Converting the 26 Linux jobs to a two-platform matrix would leave 26 required contexts reporting
nothing at all, while the 52 suffixed replacements stayed undiscoverable. Required-but-never-
reported is the phantom deadlock `automerge-ok` code `13` names, and clearing it needs an admin
token.

So the Linux jobs stay statically named, and macOS is **one aggregate job** —
`selfcheck-macos`, running `scripts/selfcheck.sh`, which *is* the full offline suite by
construction (CLAUDE.md golden rule 3 keeps it in lockstep with the jobs). Mirroring the jobs
individually would need a 27th hand-added job every time a `check-*.sh` lands, and the forgotten
one would be invisible.

The two CI-only steps are deliberately not duplicated on macOS: `required-drift` and the live claim
lint assert facts about this repo's *settings and tracker*, which are platform-independent.

## Adding a job

`scripts/check-bash-floor.sh` (offline, in `selfcheck`) will fail the PR unless the new job:

- runs on a label in `APPROVED_LINUX` / `APPROVED_MACOS`;
- runs `bash scripts/check-bash-floor.sh --runtime` as a step;
- sets no `shell:` override, which would route around that guard.

It also requires at least one job on each platform, so the macOS job cannot be quietly deleted.
`scripts/check-bash-floor-guard.sh` drives every one of those rules to red against throwaway
fixtures, because a workflow scanner that stops recognizing job keys reports exactly what a clean
repo reports.

**And then run `baseline repo apply`.** A new job is a new check context that branch protection
does not require until someone with an admin token says so — see `docs/repo-settings.md`, including
the hazard that applying from an unmerged PR branch leaves a phantom required context if the PR is
abandoned.

## What this does not prove

Stated plainly, because a CI claim that overstates itself is worse than none:

- **The suite is not yet proven to FAIL below the floor.** Every job here proves the runner *has*
  5.3; none proves the code *needs* it. That negative job lands with **#256**, which owns the
  runtime gate — and until it exists, "the floor is enforced" is an overstatement.
- **No 5.3-only syntax has been written yet.** #258/#259 do that. This issue's job is to make the
  interpreter correct *before* the first such line lands, so the CI mirror never silently stops
  mirroring.
- **`scripts/selfcheck.sh` predicts one platform.** It runs the offline checks on whichever OS you
  are sitting at. It cannot speak for the other hosted platform's image, its Homebrew bootstrap, or
  preview-runner availability.
