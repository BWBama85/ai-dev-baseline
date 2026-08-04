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
| Windows/WSL2 | **`windows-latest`** (= Windows Server 2025) | host Git-Bash **5.3.15**; the one that counts is **Ubuntu 26.04's inside WSL2** | [`actions/runner-images` Windows2025 inventory][w25] — WSLv2 **2.7.10.0** as the default; Ubuntu-26.04 is in [Microsoft's WSL distribution manifest][wsld] |

Rejected, and why it matters that it is written down:

- **`ubuntu-latest` is the trap.** It resolves to `ubuntu-24.04` today, whose bash is **5.2.21** —
  *below* the floor. A repo that "adopted 5.3" while running CI on `ubuntu-latest` would be
  validating every PR against an interpreter older than the maintainer's own (which moved to
  Homebrew 5.3.15 on 2026-08-01). The failure direction is the dangerous one: local passes, CI
  fails, and only for constructs nobody has written yet.
- **`ubuntu-25.10`, Debian stable/testing** — 5.2.x, below the floor (#255's platform table).
- **Windows *per-PR*** — still rejected. WSL2 on Ubuntu 26.04 runs the same bash and the same Ubuntu
  release as the Linux job, so a per-PR Windows runner would largely re-prove it at several times the
  cost and with the flakiness a distro download adds. (Not an *identical* userland: the WSL image is
  bare, so git, jq, ShellCheck and Node have to be installed, where the Linux Actions image ships
  them. The overlap is the release and the interpreter, which is what the floor is about.) What ships
  instead is **one scheduled smoke job** (below).
- **`Vampire/setup-wsl`** — its supported-distribution list stops at **Ubuntu-24.04**, whose bash is
  5.2.21, so the action cannot express the only distro this floor permits. `wsl --install
  --distribution Ubuntu-26.04` is used directly instead, which is also one fewer third party in the
  chain.

[u26]: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md
[m26]: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md
[w25]: https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md
[wsld]: https://github.com/microsoft/WSL/blob/master/distributions/DistributionInfo.json

## `ubuntu-26.04` is a public-preview image

GitHub ships it as **public preview**: supplied as-is, no SLA, and longer queue times than a GA
image. That is a real cost and it is accepted deliberately — it is the only **x64** GitHub-hosted
Linux label that clears the floor, and #255 chose the floor knowing this. (`ubuntu-26.04-arm` is the
same release on arm64 and clears it too; it is preview on the same terms, and this repo has no
reason to prefer arm64 — every job here is architecture-independent shell.)

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
          # Capture and validate BEFORE writing, exactly as the macOS job does. Inlining the
          # substitution writes a bare "/bin" on failure — prepending the directory that holds the
          # OLD interpreter, which is the opposite of the intent.
          prefix="$("$brew" --prefix bash)" || exit 1
          [ -n "$prefix" ] && [ -x "$prefix/bin/bash" ] || exit 1
          echo "$prefix/bin" >> "$GITHUB_PATH"
```

That is 26 Homebrew installs per CI run, which is why it is the fallback and not the design. If it
is ever taken, add `ubuntu-24.04` to `APPROVED_LINUX` in `scripts/check-bash-floor.sh` — the lint
is the thing that has to agree, and it will fail loudly until it does.

## macOS: the floor is reachable only through `PATH`

macOS ships `/bin/bash` **3.2.57** — a 2006 release — and has for the whole bash-4-and-later era;
the runner inventory above confirms it is still 3.2.57 on macOS 26 today. (The reason usually given
is bash's move to GPLv3, and #255 records the expectation that Apple will not ship a newer one. That
expectation is what the floor is *planned* around; the **observed** fact, and all this document
asserts, is the version above.) Homebrew installs 5.3 alongside it, so **every** macOS install of
this framework resolves its interpreter through `PATH`. That is exactly the surface
`base/practices/shell.md` warns is absent in non-interactive shells — the shells that
hooks and gate scripts run in — which is why macOS is the platform worth spending a CI job on, and
why #256 exists.

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

## Windows: the host clears the floor, and that is the problem

Windows is supported **via WSL2 only** (owner decision on #2). The delta WSL actually introduces is
the *checkout* — CRLF from a Windows-side clone, `/mnt/c` DrvFs semantics — and that half shipped in
#265. This section is the CI half.

`.github/workflows/wsl-smoke.yml` is **one job, in its own file**, on a weekly `schedule` plus
`workflow_dispatch` plus `push: tags`. Two structural reasons it is not a job in `ci.yml`:

1. `ci.yml` has only unfiltered `push:` and `pull_request:` triggers, so a `schedule:` there would
   run **all 27** of its jobs weekly to gain this one.
2. `repo-settings.sh` discovery skips any workflow with **no `pull_request` trigger**, so this
   repo's own tooling can never *discover or add* a schedule-only file as a required context. Put
   the same job in `ci.yml` and it becomes both a per-PR cost *and* a discovered required context.
   (An administrator or a ruleset can still require any context by hand; what is ruled out is
   `baseline repo apply` doing it for you.)

**The suite runs from a clone made inside WSL, from the canonical remote** — which is exactly what
`docs/installation.md` tells a Windows user to do, so the job executes the documented topology
rather than approximating it. There is deliberately **no `actions/checkout`**, because cloning the
Actions workspace instead fails two ways that review reproduced: the `/mnt/<drive>` mount becomes
`origin`, which is not GitHub-shaped, so `adb_git_origin_slug` cannot resolve it and
`check-state-assert.sh` fails; and on a tag ref `actions/checkout` leaves HEAD **detached**, so the
clone carries tags but no `origin/<default>` and `check-claims.sh` exits 2 with "cannot resolve a
default-branch base".

**Not `release:`.** This repo versions by pushed git tag and never publishes a GitHub Release object,
so a `release:` trigger would fire zero times — a leg that never runs is the silent-guard failure
mode, not a leg.

### Why the lint needed a third class

`windows-latest` ships **Git-Bash 5.3.15**, which *clears this repo's floor*. So the ordinary rule —
`run: bash scripts/check-bash-floor.sh --runtime` — **passes on that runner without ever entering
WSL**, proving the floor for native MSYS2: a userland #2 explicitly ruled out of scope. A widening
that merely added the label to `APPROVED_RUNNERS` would therefore have manufactured a green, and
nothing else in the suite would have noticed.

So `check-bash-floor.sh` has a **WSL-host class**, and a job on it is approved only when it:

- reaches the guard through **`wsl -d <distro> -- …`** (the bare form does not satisfy it, and the
  `wsl` form does not satisfy a Linux/macOS job either);
- **names a distro** — a bare `wsl --` runs whatever is *default* on the image, not what the job
  installed;
- logs `wsl -d <distro> -- bash --version` **before** the guard step, because a version logged after
  the proof describes a run already asserted about;
- names the **same** distro in both — otherwise a job could log image A's interpreter and prove the
  floor in image B, which is the claim this whole class exists to make true. An empty `-d ""` is
  rejected for the same reason `-d` is required at all.

`check-bash-floor-guard.sh` drives each of those to red, including the false-proof fixture (a WSL
job satisfying its guard with the bare host invocation) and the converse (a Linux job trying the
`wsl` form).

### What the lint does *not* do, and where that half lives instead

**It does not prove the distro is Ubuntu 26.04.** It reads YAML, so it can prove the guard runs
inside *some* consistently-named distro. That the distro really is 26.04, that WSL reports version 2,
and that its bash clears the floor are **runtime** assertions in the workflow — `wsl --list
--verbose`, `/etc/os-release`, and the floor guard — each failing the job closed. A lint that
pattern-matched a distro name in YAML would be asserting a label, not a fact.

**It does not require a WSL job to exist.** The count is printed, so a zero is visible; but printing
is visibility, not enforcement. Enforcement lives in `check-fact-drift.sh`, and it is pinned on the
fields that actually **run** — `runs-on: windows-latest`, and the floor-guard line naming
`Ubuntu-26.04` — each anchored to the start of a YAML line, plus the `schedule:` trigger, plus the
two docs that assert the claim to a reader.

**The anchoring is the whole point, and the first cut got it wrong.** Pinning the bare tokens
`windows-latest` / `Ubuntu-26.04` anywhere in the workflow was satisfied by this file's own
explanatory *comments*: repointing `runs-on:` at `ubuntu-26.04` and swapping the floor step for the
ordinary host invocation deleted the Windows leg while every rule stayed green and the floor lint
reported `0 WSL-host … PASS`. Negative-testing the *replacement* then found a second, narrower hole
— pinning "some `run:` step names the distro" was satisfied by the `wsl --install` line even after
every `-d` invocation had been repointed at Ubuntu-24.04, a distro *below the floor*. Hence the pin
sits on the **floor-guard line**: the line whose interpreter is the claim.

That home was chosen over an aggregate "at least one WSL job" rule in the floor lint because the
aggregate would turn every fixture in `check-bash-floor-guard.sh` red for a reason other than the
rule under test, letting the test harness shape the production invariant.

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

- runs on a label in `APPROVED_LINUX` / `APPROVED_MACOS` / `APPROVED_WSL_HOST`;
- runs `bash scripts/check-bash-floor.sh --runtime` as a step — or, on the WSL host, reaches it
  through `wsl -d <distro> -- …` (see the Windows section above);
- sets no `shell:` override, which would route around that guard. **The WSL job needs no exception
  here** — it runs under the runner's default pwsh and invokes `wsl.exe` explicitly, **one native
  command per step** so each exit code is checked individually. The runner appends an exit on
  `$LASTEXITCODE`, so a multi-line block propagates only its *last* native exit code — a fail-open.
  (The assertion steps *are* multi-line pwsh, but each makes a single native call and fails via
  `throw`, which is terminating and reliably exits the step non-zero. Where two commands genuinely
  belong together, they go inside one `bash -c "set -eu; …"` so bash decides the outcome.)

It also requires at least one job on each of Linux and macOS, so the macOS job cannot be quietly
deleted, and that the job's **first** step logs `bash --version` — before checkout or any bootstrap,
so an image that changed its bash is readable in the log even when a later step is what fails. There
is deliberately **no** matching "a WSL job must exist" rule: the WSL count is *printed* instead, so a
zero is visible in the log. Requiring one would turn every fixture in `check-bash-floor-guard.sh` red
for a reason other than the rule under test, which is the isolation failure that file exists to avoid.

`scripts/check-bash-floor-guard.sh` drives each of those rules to red against throwaway fixtures,
because a workflow scanner that stops recognizing job keys reports exactly what a clean repo
reports. Where a rule can be **isolated** it is: a fixture that only goes red through some *other*
rule proves nothing about the one it is named for.

**Reusable-workflow jobs (`uses:` at job level) are not supported here, and fail closed.** Such a
job has no `runs-on` and no caller steps, so it trips both the label and the guard rules. That is
deliberate rather than an oversight — the callee owns its runners, and this lint cannot see them.
If one is ever needed, the callee has to carry its own floor guard and this lint has to learn how to
say so.

### The one dependency this accepts knowingly

Ten Linux jobs run `sudo apt-get install -y <pkg>` with **no preceding `apt-get update`**, relying
on the image's baked package index. Both packages (jq, ShellCheck) are already preinstalled on
`ubuntu-26.04`, so these are confirmations rather than real installs — but on image churn a cached
index can reference a replaced artifact and the install fails. Accepted as-is: it predates this
change, it fails loudly rather than silently, and adding `apt-get update` to ten jobs to guard a
no-op is the worse trade. If it starts firing, that is a real diagnosis (`base/practices/ci-discipline.md`),
not a retry.

**And then run `baseline repo apply`.** A new job is a new check context that branch protection
does not require until someone with an admin token says so — see `docs/repo-settings.md`, including
the hazard that applying from an unmerged PR branch leaves a phantom required context if the PR is
abandoned.

## What this does not prove

Stated plainly, because a CI claim that overstates itself is worse than none:

- ~~**The suite is not yet proven to FAIL below the floor.**~~ **Closed by #256.** Every job here
  proves the runner *has* 5.3; the negative half now lives in `check-bash-floor-guard.sh`, which
  runs a real entry point under Apple's `/bin/bash` 3.2.57 with the re-exec sentinel pre-set and
  requires a non-zero exit and an unexecuted body. It runs on the **macOS** job, which is the only
  place a real sub-floor interpreter exists — the assertion is guarded on `/bin/bash` genuinely
  being 3.2, so on Linux (where `/bin/bash` *is* 5.3) it skips rather than asserting something
  false. It is a **step**, not a new job, so the required-context count is unchanged.

  What that negative half still does **not** have is a real **5.2** interpreter. #256's acceptance
  asked for one; no hosted runner or workstation here has a 5.2 binary and obtaining one
  hermetically is out of reach, so 5.2 is covered by a **stub** that reports `5.2.21` when probed,
  plus a direct comparison against the floor constant. Said plainly rather than implied: the
  observation against 3.2 is real, the one against 5.2 is synthetic.
- **No 5.3-only syntax has been written yet.** #258/#259 do that. This issue's job is to make the
  interpreter correct *before* the first such line lands, so the CI mirror never silently stops
  mirroring.
- **`scripts/selfcheck.sh` predicts one platform.** It runs the offline checks on whichever OS you
  are sitting at. It cannot speak for the other hosted platform's image, its Homebrew bootstrap, or
  preview-runner availability.
- **The WSL smoke job had not been observed green when it was written.** A `schedule` /
  `workflow_dispatch` workflow must already exist on the **default branch** before it can run, so the
  PR that introduced it structurally could not run it — which is why #2's acceptance criterion
  "has been seen green at least once" is discharged by a `workflow_dispatch` **after** merge, not by
  that PR. Every offline half *was* verified: the YAML parses, the lint accepts the job, and each new
  lint rule was observed rejecting its own violation. What no local run can settle is whether
  `wsl --install --distribution Ubuntu-26.04` completes unattended on a hosted runner. The job is
  built to **fail closed** on that question rather than to assume it: the registration, the WSL
  version, the `VERSION_ID`, and the floor are each asserted, so a mechanism that does not work
  produces a red job, never a green one that proved nothing.
