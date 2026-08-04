#!/usr/bin/env bash
# ai-dev-baseline — the bash 5.3 runtime floor, proven on every CI job (#257).
#
# Two halves, one home:
#
#   --runtime            Assert the interpreter RUNNING THIS SCRIPT clears the floor, and SAY what
#                        it checked. Every CI job calls this immediately after checkout, so a
#                        runner image that quietly changes its bash — or a job left behind on an
#                        older runner label — surfaces as a named failure here instead of as a
#                        mystery syntax error twenty steps later.
#
#   (default)            Static lint over .github/workflows/*.yml, offline: every job runs on a
#   --workflow-dir DIR   runner label PROVEN to carry bash >= the floor, every job wires the
#                        runtime half, no step escapes the guard through a `shell:` override, and
#                        both platforms the floor must hold on are actually represented.
#
# THE WSL-HOST CLASS (#2). Windows is supported via WSL2 only, so a Windows job proves the floor for
# the interpreter INSIDE WSL — never the host's. That distinction is the whole rule, because the
# host clears the floor on its own: `windows-latest` (Windows Server 2025) ships Git-Bash
# **5.3.15**, so the ordinary `run: bash scripts/check-bash-floor.sh --runtime` PASSES there without
# ever entering WSL. A generic widening — add the label to the allowlist and move on — would
# therefore manufacture a green that proves the floor on an explicitly UNSUPPORTED runtime (native
# MSYS2/Git-Bash, whose userland #2 ruled out of scope). So a WSL-host job is approved only when it
# reaches the guard through `wsl -d <distro> -- …`, and the bare form does not satisfy it.
#
# `-d <distro>` is required rather than cosmetic: a bare `wsl -- …` runs in whatever distro happens
# to be DEFAULT on the image, which is not the one the job installed.
#
# Usage: bash scripts/check-bash-floor.sh [--runtime | --workflow-dir DIR]
#        exit 0 = clear · 1 = below the floor / workflow drift · 2 = usage
#
# WHY A LINT AND NOT JUST 26 EDITS: the edits are today; the lint is job 27. Nothing else in this
# repo reads .github/workflows/ci.yml for runner labels (check-fact-drift.sh pins invocation TEXT
# and says outright that it cannot prove a step belongs to a runnable job), so a new job added on
# `ubuntu-latest` would run the whole suite on bash 5.2.21 and report green.
#
# ADB_BASH_FLOOR overrides the floor (default 5.3). It exists so the negative half of this guard
# can be OBSERVED failing on a runner that is ABOVE the floor — see check-bash-floor-guard.sh —
# and so the runtime half stays testable on any interpreter without preempting #256, which owns
# making an old bash fail at the entry points. Every run PRINTS the floor it enforced, so a
# lowered floor is visible in the log rather than a silent bypass (base/practices/self-review.md:
# make the guard say what it checked, not merely whether it passed).

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
# common.sh owns adb_version_ge — this repo's law is to source the shared primitive, never copy
# it, and a hand-rolled comparison here is exactly the drift that law exists to stop.
# shellcheck source=/dev/null
. scripts/lib/common.sh >/dev/null 2>&1 || {
  echo "bash-floor: FATAL — scripts/lib/common.sh is unavailable, so adb_version_ge cannot be reached" >&2
  exit 1
}
check_init "bash-floor"

FLOOR_DEFAULT="5.3"
FLOOR="${ADB_BASH_FLOOR:-$FLOOR_DEFAULT}"

# VALIDATE THE SEAM. `adb_version_ge` reads a non-numeric component as 0, so an unvalidated override
# is a bypass wearing a typo's clothes: `ADB_BASH_FLOOR=x`, `-1` and the Arabic-Indic `٥.٣` each
# compare as 0 and wave bash 3.2.57 straight through. All three were reproduced by review. A test
# seam that can silently disable the assertion is worse than no seam, so anything that is not a
# dotted run of ASCII digits is a hard error rather than a floor.
case "$FLOOR" in
  ''|*[!0-9.]*|.*|*.|*..*)
    echo "bash-floor: FATAL — ADB_BASH_FLOOR='$FLOOR' is not a dotted numeric version (e.g. 5.3)" >&2
    exit 2 ;;
esac

# Runner labels this repo has PROVEN carry bash >= 5.3, with the evidence recorded in
# docs/ci-runners.md. Deliberately an allowlist, not a denylist of known-old labels: `ubuntu-latest`
# is the trap (it is ubuntu-24.04 / bash 5.2.21 today and silently becomes something else later),
# and a denylist waves through every label nobody thought to name.
APPROVED_LINUX="ubuntu-26.04"
APPROVED_MACOS="macos-latest"
# The WSL HOST. Approved only as a launcher — see the header. A job here proves the floor for the
# distro it starts, and nothing about the Windows userland, which #2 placed out of scope.
APPROVED_WSL_HOST="windows-latest"
APPROVED_RUNNERS="$APPROVED_LINUX $APPROVED_MACOS $APPROVED_WSL_HOST"

# --- runtime half ------------------------------------------------------------------------------

# Print "<major>.<minor>.<patch>" for the bash at $1, or nothing if it cannot be run.
bash_version_at() {
  [ -x "$1" ] || return 1
  "$1" -c 'printf "%s.%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"' 2>/dev/null
}

runtime_check() {
  # TWO interpreters are in play and they are NOT always the same one, which is the whole trap this
  # half exists to catch:
  #
  #   $BASH           — the interpreter executing THIS script.
  #   command -v bash — what the next `bash foo.sh` resolves from PATH, and therefore what every
  #                     `#!/usr/bin/env bash` entry point in this repo runs under, selfcheck included.
  #
  # On macOS they diverge exactly when it matters. Run this under /bin/bash 3.2 with Homebrew's 5.3
  # first on PATH and `command -v bash` reports /opt/homebrew/bin/bash: a guard asserting only on
  # that passes while executing on the 2006 interpreter. Verified locally — same script, two
  # invocations, `command -v bash` identical, `$BASH` 3.2.57 vs 5.3.15. So assert BOTH.
  self_v="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
  self_p="${BASH:-<unknown>}"
  path_p="$(command -v bash 2>/dev/null || true)"
  path_v=""
  [ -n "$path_p" ] && path_v="$(bash_version_at "$path_p" || true)"

  printf 'bash-floor: floor enforced      %s\n' "$FLOOR"
  printf 'bash-floor: running interpreter %s (%s)\n' "$self_p" "$self_v"
  printf 'bash-floor: PATH-resolved bash  %s (%s)\n' "${path_p:-<none>}" "${path_v:-unknown}"
  # The literal `bash --version` line #257 asks every job to log, taken from the interpreter the
  # suite will actually run under rather than from whatever happens to be executing this guard.
  [ -n "$path_p" ] && "$path_p" --version 2>/dev/null | head -n 1

  # Name the system bash wherever one exists. On macOS this is the 3.2.57 Apple pins at /bin/bash
  # permanently for GPLv3 reasons, and printing it beside the two lines above is what makes "this
  # job is running Homebrew's bash, not /bin/bash" READABLE in the log instead of inferred from a
  # version number the reader has to know the significance of.
  if [ -x /bin/bash ]; then
    sys_v="$(bash_version_at /bin/bash || echo unknown)"
    if [ "$self_p" = "/bin/bash" ]; then
      printf 'bash-floor: system bash         /bin/bash (%s) — IN USE\n' "$sys_v"
    else
      printf 'bash-floor: system bash         /bin/bash (%s) — not used\n' "$sys_v"
    fi
  fi

  if ! adb_version_ge "$self_v" "$FLOOR"; then
    check_note "the interpreter running this guard is $self_v at $self_p — below the $FLOOR floor"
    check_fail
  fi
  if [ -z "$path_p" ] || [ -z "$path_v" ]; then
    check_note "no usable bash on PATH — every '#!/usr/bin/env bash' entry point in this repo would fail"
    check_fail
  elif ! adb_version_ge "$path_v" "$FLOOR"; then
    check_note "PATH resolves bash to $path_p ($path_v) — below the $FLOOR floor, and the suite runs on THAT one"
    check_fail
  fi
}

# --- static half -------------------------------------------------------------------------------

# Emit "<job>\t<runs-on>\t<wires-guard 0|1>" for every job in the workflow file at $1.
#
# Deliberately NOT repo-settings.sh's discovery, which reads the same file. That one exists to emit
# provable check CONTEXTS and therefore SKIPS jobs on purpose — matrix, `if:`, an interpolated
# `name:`. A floor lint must see every job precisely INCLUDING the ones discovery declines to
# require: a matrix job left on ubuntu-latest is still a job running below the floor. Same file,
# opposite requirement, so this is a second reader rather than a copy of the first.
scan_jobs() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    # A plain YAML scalar as GitHub reads it. QUOTE FIRST, THEN COMMENT — the order is the whole
    # point. Stripping `#` first turns `runs-on: "ubuntu-26.04 # not-the-label"` into the approved
    # label `ubuntu-26.04`, accepting a job whose real label is the entire quoted string and which
    # would never run. Same semantics as yaml_scalar in scripts/lib/repo-settings.sh; that the two
    # had DIFFERENT semantics until review caught it is the argument for the shared enumerator
    # follow-up, not an argument that this file may guess.
    function yaml_scalar(s) {
      s = trim(s)
      if (s ~ /^"/)  { sub(/^"/,  "", s); sub(/".*$/,  "", s); return s }
      if (s ~ /^'"'"'/) { sub(/^'"'"'/, "", s); sub(/'"'"'.*$/, "", s); return s }
      sub(/[[:space:]]+#.*$/, "", s)
      return trim(s)
    }
    # The distro token a `wsl -d <name>` / `--distribution <name>` invocation names, unquoted, or
    # empty. Captured rather than merely matched because the two WSL steps must name the SAME
    # distro: without this the lint accepts a `bash --version` logged in distro A followed by the
    # floor proved in distro B, while the job claims to have logged the interpreter it proved.
    function wsl_distro(s,   t) {
      if (match(s, /(-d|--distribution)[[:space:]]+[^[:space:]]+/)) {
        t = substr(s, RSTART, RLENGTH)
        sub(/^(-d|--distribution)[[:space:]]+/, "", t)
        return unquote(t)
      }
      return ""
    }
    function flush() {
      if (job != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", job, (runson == "" ? "<none>" : runson), \
                            guard, firstlog, wslguard, wsllog, wsllogd, wslguardd
    }
    # Job keys sit at exactly two spaces under `jobs:`. `on:` puts push/pull_request at that SAME
    # indent, so track whether we are inside the jobs: block rather than scanning the whole file —
    # the trap docs/repo-settings.md records this repo'"'"'s own ci.yml falling into.
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[^[:space:]#]/      { in_jobs = 0 }
    !in_jobs { next }
    /^[[:space:]]*#/ { next }
    # ANY two-space key inside jobs: is a job — including `hidden: {runs-on: …, steps: […]}`, the
    # inline flow mapping that a `:[[:space:]]*$` anchor renders INVISIBLE. Invisible is the one
    # outcome a floor lint may never produce, so an inline job is captured with its raw value as
    # the label: it matches no approved label and fails LOUDLY rather than silently not existing.
    # QUOTED job IDs count too. YAML permits `"hidden":`, and a key rule accepting only bare
    # [A-Za-z0-9_-] skips straight past it — every line of that job then reads as belonging to the
    # PREVIOUS one, so it is not merely unchecked, it does not exist. With a compliant Linux and
    # macOS job elsewhere in the file the aggregate rules are satisfied and the lint reports PASS.
    /^  ("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z0-9_-]+):/ {
      flush()
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job); job = unquote(job)
      rest = $0; sub(/^  ("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z0-9_-]+):/, "", rest); rest = trim(rest)
      runson = ""; guard = 0; firstlog = 0; step = 0; wslguard = 0; wsllog = 0
      wsllogd = ""; wslguardd = ""
      if (rest != "" && rest !~ /^#/) runson = "<inline mapping: " rest ">"
      next
    }
    job == "" { next }
    /^    runs-on:/ { v = $0; sub(/^    runs-on:[[:space:]]*/, "", v); runson = yaml_scalar(v); next }
    # Step boundaries, so "the FIRST step" is a question this can answer at all.
    /^      - / { step++ }
    # `bash --version` must be logged by the job'"'"'s FIRST step (#257 acceptance criterion 2), before
    # checkout or any bootstrap — so a runner image that quietly changed its bash is visible in the
    # log even when a later step is what fails.
    step == 1 && /run:.*bash --version/ { firstlog = 1 }
    # EXECUTING, not merely APPEARING. The invocation must be the WHOLE run value — `run: bash
    # scripts/check-bash-floor.sh --runtime` and nothing else on the line. Anything looser passes
    # for a step that only talks about it: an `env:` value, a step `name:`, and (the one that
    # survived the first tightening) `run: echo '"'"'bash scripts/check-bash-floor.sh --runtime'"'"'`,
    # which runs the guard exactly zero times while satisfying a substring test.
    # A `run: |` BLOCK carrying it on a later line is not recognized either, and reports unguarded:
    # fail-closed, and no job here uses that form.
    /^[[:space:]]*run:[[:space:]]*bash[[:space:]]+scripts\/check-bash-floor\.sh[[:space:]]+--runtime[[:space:]]*$/ { guard = 1 }
    # THE WSL FORMS (#2), recorded as STEP NUMBERS rather than booleans, because for a WSL-host job
    # the interesting question is ORDER: the distro must be named before the guard runs in it, so a
    # log emitted after the proof documents nothing about the run that was proved.
    #
    # The shape is deliberately narrow — `wsl -d <distro> [flags…] -- bash …` and nothing else on
    # the line. `-d` is required (a bare `wsl --` takes the images default distro, not the one the
    # job installed), the middle may not carry a pipe or a command separator, and the invocation
    # must be the WHOLE run value, so an echoed or `-c`-wrapped mention matches nothing. That is the
    # same standard the bare form above already holds, transplanted rather than reinvented.
    /^[[:space:]]*run:[[:space:]]*wsl(\.exe)?[[:space:]]+(-d|--distribution)[[:space:]]+[^[:space:]]+[^|;&]*--[[:space:]]+bash[[:space:]]+--version[[:space:]]*$/ {
      if (wsllog == 0) { wsllog = step; wsllogd = wsl_distro($0) }
    }
    /^[[:space:]]*run:[[:space:]]*wsl(\.exe)?[[:space:]]+(-d|--distribution)[[:space:]]+[^[:space:]]+[^|;&]*--[[:space:]]+bash[[:space:]]+scripts\/check-bash-floor\.sh[[:space:]]+--runtime[[:space:]]*$/ {
      if (wslguard == 0) { wslguard = step; wslguardd = wsl_distro($0) }
    }
    END { flush() }
  ' "$1"
}

static_lint() {
  dir="$1"
  files=0 jobs=0 linux_jobs=0 macos_jobs=0 wsl_jobs=0

  for wf in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$wf" ] || continue
    files=$((files + 1))

    # No step may pick its own interpreter. The runtime guard proves the bash a `run:` step gets by
    # default; a `shell:` override routes around it silently, and nothing in this bash-only repo
    # needs one. DELIBERATELY UNANCHORED: `defaults: {run: {shell: sh}}` on one line routes EVERY
    # step in the workflow around bash, and a `^[[:space:]]*shell:` anchor never sees it. The cost
    # is that an action input legitimately named `shell` under `with:` would also trip this — which
    # is a loud, one-line fix to this lint, where the anchored version's cost was silence.
    # The QUOTED spelling counts: `defaults: {run: {"shell": sh}}` is the same override in valid
    # YAML, and a pattern that only knows the bare key waves it through while every `run:` step in
    # the workflow is routed via sh.
    if grep -Eq '(^|[[:space:]{,])"?'"'"'?shell'"'"'?"?[[:space:]]*:' "$wf"; then
      check_note "$wf names a 'shell' key, which can route steps around the floor guard:"
      grep -En '(^|[[:space:]{,])"?'"'"'?shell'"'"'?"?[[:space:]]*:' "$wf" | sed 's/^/    /' >&2
      check_fail
    fi

    # The floor override is a TEST seam (see the header). A workflow that sets it — at workflow, job
    # or step level — turns every runtime assertion in that scope into a formality while this lint
    # stays green, which is the one bypass the validation above cannot see from inside the guard.
    if grep -q 'ADB_BASH_FLOOR' "$wf"; then
      check_note "$wf sets ADB_BASH_FLOOR, which overrides the floor every runtime guard enforces:"
      grep -n 'ADB_BASH_FLOOR' "$wf" | sed 's/^/    /' >&2
      check_fail
    fi

    # Capture the scan BEFORE consuming it, and check its status. Piping or here-doc'ing a command
    # substitution straight into the loop discards awk's exit code, so a CRASHED scan reads as "this
    # file declares no jobs" — and a file contributing zero jobs is invisible as long as some OTHER
    # file contributed some. That is the same fail-open shape D28 fixed in the roadmap library.
    scanned="$(scan_jobs "$wf")" || {
      check_note "$wf: the job scanner failed outright — refusing to report a clean scan"
      check_fail
      continue
    }

    file_jobs=0
    while IFS=$'\t' read -r job runson guard firstlog wslguard wsllog wsllogd wslguardd; do
      [ -n "$job" ] || continue
      jobs=$((jobs + 1))
      file_jobs=$((file_jobs + 1))
      case " $APPROVED_RUNNERS " in
        *" $runson "*) ;;
        *) check_note "$wf: job '$job' runs on '$runson' — not a runner this repo has proven carries bash >= $FLOOR (allowed: $APPROVED_RUNNERS; see docs/ci-runners.md)"
           check_fail ;;
      esac
      case " $APPROVED_LINUX " in *" $runson "*) linux_jobs=$((linux_jobs + 1)) ;; esac
      case " $APPROVED_MACOS " in *" $runson "*) macos_jobs=$((macos_jobs + 1)) ;; esac
      is_wsl=0
      case " $APPROVED_WSL_HOST " in *" $runson "*) is_wsl=1; wsl_jobs=$((wsl_jobs + 1)) ;; esac

      if [ "$is_wsl" = "1" ]; then
        # NORMALIZE BEFORE COMPARING. These two arrive as fields from `read`, and the ordering rule
        # below is a NUMERIC test: `[ "" -ge 3 ]` is not false, it is an ERROR, which `if` then reads
        # as "the ordering is fine". A scanner that emitted an empty field for any reason would
        # therefore turn the rule off rather than trip it. Anything that is not a run of digits is
        # forced to 0 — i.e. treated as ABSENT — so every degenerate value lands on the fail-closed
        # side of the two rules that follow.
        case "$wslguard" in ''|*[!0-9]*) wslguard=0 ;; esac
        case "$wsllog"   in ''|*[!0-9]*) wsllog=0   ;; esac

        # THE WHOLE POINT OF THE CLASS: the bare form is NOT accepted here. `windows-latest` carries
        # its own bash 5.3.15, so a job satisfying the ordinary rule would prove the floor for
        # native Git-Bash — a userland #2 explicitly ruled unsupported — and report it as Windows
        # coverage. Only the interpreter inside the distro counts.
        if [ "$wslguard" = "0" ]; then
          check_note "$wf: job '$job' is on the WSL host '$runson' but never runs 'wsl -d <distro> -- bash scripts/check-bash-floor.sh --runtime' — the host's own bash clears the floor, so a bare invocation here would prove the floor for native Git-Bash, which is NOT a supported runtime (#2)"
          check_fail
        fi
        if [ "$wsllog" = "0" ]; then
          check_note "$wf: job '$job' never logs 'wsl -d <distro> -- bash --version', so the log never says which interpreter the distro actually supplied"
          check_fail
        elif [ "$wslguard" != "0" ] && [ "$wsllog" -ge "$wslguard" ]; then
          check_note "$wf: job '$job' logs the WSL bash at step $wsllog, at or AFTER the guard step $wslguard — a version logged after the proof documents nothing about the run that was proved"
          check_fail
        fi

        # SAME DISTRO, not merely some distro at each step. Two invocations naming different distros
        # let a job log the interpreter of one image and prove the floor in another, which is the
        # claim this class exists to make true. An EMPTY name (`-d ""`) is rejected outright: it is
        # syntactically a token but names nothing, so `wsl` would fall back to the default distro —
        # the exact hole requiring `-d` was meant to close.
        if [ "$wslguard" != "0" ] && [ -z "$wslguardd" ]; then
          check_note "$wf: job '$job' passes an empty distro name to the floor guard — 'wsl -d \"\"' names nothing and falls back to the image's default distro"
          check_fail
        elif [ "$wslguard" != "0" ] && [ "$wsllog" != "0" ] && [ "$wsllogd" != "$wslguardd" ]; then
          check_note "$wf: job '$job' logs the bash of distro '$wsllogd' but proves the floor in distro '$wslguardd' — the logged interpreter is not the one that was asserted about"
          check_fail
        fi
      elif [ "$guard" != "1" ]; then
        check_note "$wf: job '$job' has no 'run:' step invoking 'scripts/check-bash-floor.sh --runtime', so nothing proves the bash it actually got"
        check_fail
      fi
      if [ "$firstlog" != "1" ]; then
        check_note "$wf: job '$job' does not log 'bash --version' in its FIRST step — a runner image that changed its bash must be visible in the log even when a later step is what fails (#257)"
        check_fail
      fi
    done <<EOF
$scanned
EOF

    # PER FILE, not just in total. A workflow file with no jobs is malformed, and checking only the
    # grand total lets a second file go blind for free the moment a first one still parses.
    if [ "$file_jobs" -eq 0 ]; then
      check_note "$wf declares no jobs the scanner can see — malformed, or the scanner has gone blind on it"
      check_fail
    fi
  done

  if [ "$files" -eq 0 ]; then
    check_note "no workflow files under $dir — this lint scanned nothing, which is not a pass"
    check_fail
    return
  fi
  # No grand-total zero-jobs check: the per-file rule above already implies it whenever files > 0,
  # and a second assertion that can only fire when the first one already has is a test that passes
  # for the wrong reason. Review caught exactly that — the harness's zero-total fixture stayed green
  # with this block's predecessor deleted, because the per-file rule was catching it.
  [ "$jobs" -gt 0 ] || return

  # #257's first acceptance criterion is that the suite runs on BOTH platforms. Without this, the
  # macOS job can be deleted and every remaining rule still passes: the floor would be proven on
  # the one platform where it was never in doubt.
  [ "$linux_jobs" -gt 0 ] || { check_note "no job runs on a proven Linux runner ($APPROVED_LINUX) — the floor is unproven on Linux"; check_fail; }
  [ "$macos_jobs" -gt 0 ] || { check_note "no job runs on a proven macOS runner ($APPROVED_MACOS) — the floor is unproven on the platform where it is hardest to reach"; check_fail; }

  # The WSL count is PRINTED but not required, and the asymmetry with Linux/macOS is deliberate.
  # Those two are per-PR jobs whose absence would silently unprove the floor on a platform this repo
  # ships to. The WSL smoke job is scheduled-only and lives in its own file; requiring one would
  # make every fixture in check-bash-floor-guard.sh red for a reason other than the rule it tests,
  # which is the isolation failure that file's own header warns against. So a zero is made VISIBLE
  # in the log rather than fatal — base/practices/self-review.md, "make the guard say what it
  # checked". What is NOT claimed: that the distro is Ubuntu 26.04. The lint reads YAML, so it can
  # prove the guard runs inside SOME named distro; that the distro clears the floor is proved at
  # runtime by the guard itself, which goes red on a 5.2 image.
  printf 'bash-floor: %d job(s) across %d file(s) — %d Linux, %d macOS, %d WSL-host, floor %s\n' \
    "$jobs" "$files" "$linux_jobs" "$macos_jobs" "$wsl_jobs" "$FLOOR"
}

# --- entry-point half (#256) ---------------------------------------------------------------------
#
# The runtime gate is only a floor if EVERY process entry point calls it, and "every" is not a
# thing prose can hold: a new check-*.sh lands without the stanza and the suite it joins runs on
# whatever interpreter it got, reporting green. So the set is closed here, mechanically.
#
# CLASSIFICATION IS FORCED, NOT OPTIONAL. Every shebang-bearing file is exactly one of:
#
#   gate      — calls adb_require_bash: re-exec, else exit non-zero. The default, and the
#               overwhelming majority.
#   advisory  — calls adb_require_bash_advisory: same re-exec, but RETURNS instead of exiting,
#               for the three files whose own contract forbids a non-zero exit. Naming them here
#               is what stops "advisory" becoming a dial a future script can quietly pick.
#   exempt    — must NOT call it at all, and there is exactly one.
#
# Matched on the path RELATIVE to the scanned root, so the guard can build a fixture tree at the
# same paths and drive each rule red.
ADVISORY_ENTRYPOINTS="
agents/claude/scripts/statusline.sh
agents/claude/scripts/session-currency.sh
agents/claude/scripts/state-claim-gate.sh
"
# check-bash-floor.sh is the OBSERVER, and an observer that upgrades its own interpreter has
# destroyed the observation. Its whole --runtime job is to report which bash this job actually
# got, and check-bash-floor-guard.sh proves that assertion fires by running this file under an old
# /bin/bash and requiring red. Wire the gate in here and that test silently stops testing: the
# script would re-exec to 5.3 and report a clean floor on a machine that has none on PATH.
EXEMPT_ENTRYPOINTS="
scripts/check-bash-floor.sh
"

# Print every file under $1 whose first line is a bash shebang, as a path relative to $1.
#
# TRACKED files when $1 is a git worktree, `find` otherwise. Both halves are load-bearing:
#
#   - tracked, because `selfcheck` promises to predict CI, and CI only ever sees tracked files. A
#     `find` scan fails on a contributor's untracked scratch script while CI passes — a local red
#     that CI cannot reproduce is worse than no check, and it teaches people to ignore this one.
#   - `find`, because check-bash-floor-guard.sh drives every rule below against throwaway fixture
#     trees, and check_copy_worktree drops `.git`, so there is nothing to list there.
#
# The emptiness test is what makes the choice safe: a fixture dir that happens to sit INSIDE some
# repo yields no tracked files under itself, so it falls through to `find` rather than silently
# scanning zero files and reporting a clean tree.
scan_entrypoints() {
  root="$1" listing=""
  listing="$(git -C "$root" ls-files 2>/dev/null)"
  if [ -z "$listing" ]; then
    listing="$(find "$root" -name .git -prune -o -type f -print 2>/dev/null | sed "s|^$root/||")"
  fi
  printf '%s\n' "$listing" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    head -n 1 "$root/$rel" 2>/dev/null | grep -q '^#!.*bash' || continue
    printf '%s\n' "$rel"
  done | LC_ALL=C sort
}

# The path of the scanned root RELATIVE TO ITS REPOSITORY ROOT, with a trailing `/`, or empty.
#
# The classification lists below are repository-relative, but scan_entrypoints yields paths relative
# to whatever directory was scanned. Scanning a SUBDIRECTORY therefore matched nothing:
# `--entrypoints agents/claude` sees `scripts/statusline.sh`, not
# `agents/claude/scripts/statusline.sh`, so all three advisory hooks were classified as hard gates
# and a perfectly valid tree exited 1 — and `--entrypoints scripts` lost the observer exemption the
# same way. Review found it in the advertised `[DIR]` form.
#
# `--show-prefix` answers exactly this and answers it empty at a repository root, so the common case
# costs nothing. A fixture tree that is not a repository at all yields empty too, which is right:
# its paths are already relative to the thing being scanned.
scan_prefix() {
  git -C "$1" rev-parse --show-prefix 2>/dev/null || true
}

# The line number of the first occurrence of a pattern in TOP-LEVEL ACTIVE CODE, or empty.
#
# "Top-level" is load-bearing and is why this stops at the first function definition: a match
# inside a function body proves the text exists, not that the process ever runs it.
#
# Comments are blanked before matching — both a whole-line `# adb_require_bash "$@"` and a TRAILING
# `x=1  # TODO: adb_require_bash "$@"`. The trailing form is the one that matters: a note about
# doing the thing read as the thing is exactly the fail-open #257's guard caught twice in the
# workflow scanner, and a first cut of THIS lint reproduced it — an entry point with nothing but a
# trailing-comment mention was reported compliant.
#
# `sed` blanks rather than deletes, so line numbering still matches the real file, which is what
# lets the position rule below cite a usable line. The trailing pattern requires whitespace before
# the `#` so a `${0##*/}` expansion is not mistaken for a comment.
first_code_line() {
  ADB_BF_PAT="$2" awk '
    BEGIN { pat = ENVIRON["ADB_BF_PAT"] }
    # HEREDOC BODIES ARE DATA. `cat <<EOF … adb_require_bash "$@" … EOF` is text this script
    # PRINTS, not a call it makes, and a line-at-a-time matcher reads the two identically — the
    # same species as the printf and quoted-assignment bypasses, and the one that survived the
    # first tightening. Tracking the region needs state, which is why this is awk and not sed.
    hd != "" {
      probe = $0; sub(/^[[:space:]]+/, "", probe)   # <<- allows an indented terminator
      if (probe == hd) hd = ""
      next
    }
    {
      line = $0
      sub(/[[:space:]]#.*$/, "", line)      # a trailing comment
      sub(/^[[:space:]]*#.*$/, "", line)    # a whole-line comment
      # A FUNCTION DEFINITION ENDS THE TOP LEVEL for the purposes of this scan. Everything after
      # the first one may never execute: an entry point can define an uninvoked function whose body
      # holds the gate call, run its real body, and stay on the sub-floor interpreter while a
      # command-position match reported PASS. Review found it; stopping here is also exactly the
      # invariant the release scripts already had to satisfy by hand — the bootstrap precedes every
      # definition, because bash parses a function body when it reaches it, so 5.3-only grammar in
      # any of them fails to PARSE under 3.2 before the gate can rescue it.
      # (No apostrophes in this block: it is a single-quoted shell string, and one would end it.)
      if (line ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)|function[[:space:]]+[A-Za-z_])/) exit
      if (line ~ pat) { print NR; exit }
      # Open a heredoc only AFTER testing this line: the redirection line is itself code, and a
      # gate call could legitimately share it. `<<<` is a herestring, not a heredoc — excluded, or
      # its first word would be mistaken for a terminator and swallow the rest of the file.
      if (line !~ /<<</ && match(line, /<<-?[[:space:]]*["\x27]?[A-Za-z_][A-Za-z0-9_]*/)) {
        w = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[^A-Za-z_]*/, "", w)      # eat the operator, spaces and any opening quote
        hd = w
      }
    }
  ' "$1" 2>/dev/null
}

entrypoint_lint() {
  root="${1%/}"
  eps=0 gates=0 advisories=0 exempts=0
  prefix="$(scan_prefix "$root")"

  scanned="$(scan_entrypoints "$root")" || {
    check_note "the entry-point scanner failed outright under $root — refusing to report a clean scan"
    check_fail
    return
  }

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$root/$rel"
    # Classify on the REPOSITORY-relative path; report on it too, so a diagnostic from a
    # subdirectory scan names a path the reader can actually open from the repo root.
    key="$prefix$rel"
    eps=$((eps + 1))

    kind=gate
    case "
$ADVISORY_ENTRYPOINTS" in *"
$key
"*) kind=advisory ;; esac
    case "
$EXEMPT_ENTRYPOINTS" in *"
$key
"*) kind=exempt ;; esac

    # COMMAND POSITION, not "appears somewhere". A bare token search accepts the call inside a
    # string — a fixture whose only content was `printf 'adb_require_bash "$@"'` was classified
    # compliant, which is the whole lint failing open. So the token must be preceded only by start
    # of line, or by a shell operator that actually begins a command: `;`, `&&`, `||`, `|`, `&`, or
    # a `then`/`do`/`else` keyword. `printf '` does not qualify; the three real stanza shapes do
    # (bare, `&& adb_require_bash_advisory`, and `; then adb_require_bash`).
    _CMDPOS='(^|[;&|]|[[:space:]](then|do|else))[[:space:]]*'
    call_gate="$(first_code_line "$f" "${_CMDPOS}adb_require_bash \"\\\$@\"")"
    call_adv="$(first_code_line "$f" "${_CMDPOS}adb_require_bash_advisory \"\\\$@\"")"

    if [ "$kind" = exempt ]; then
      exempts=$((exempts + 1))
      if [ -n "$call_gate" ] || [ -n "$call_adv" ]; then
        check_note "$key is the EXEMPT observer but calls the floor gate (line ${call_gate:-$call_adv}) — re-exec'ing here would make its own negative test stop testing"
        check_fail
      fi
      continue
    fi

    if [ "$kind" = advisory ]; then
      advisories=$((advisories + 1))
      call="$call_adv"
      want="adb_require_bash_advisory \"\$@\""
      if [ -n "$call_gate" ]; then
        check_note "$key is classified ADVISORY (its own contract forbids a non-zero exit) but calls the hard-failing adb_require_bash at line $call_gate"
        check_fail
        # One defect, one line. Falling through would also report "never calls the advisory form",
        # which is true but is the same finding wearing a second hat.
        continue
      fi
    else
      gates=$((gates + 1))
      call="$call_gate"
      want="adb_require_bash \"\$@\""
      if [ -z "$call_gate" ] && [ -n "$call_adv" ]; then
        check_note "$key is classified GATE but calls the advisory form at line $call_adv — a gate that lets its caller carry on under a sub-$FLOOR interpreter is not a gate"
        check_fail
        continue
      fi
    fi

    if [ -z "$call" ]; then
      check_note "$key has a bash shebang but never calls $want — it would run under whatever interpreter PATH resolved (add the stanza, or classify it in $0)"
      check_fail
      continue
    fi

    # TOO LATE IS AS BAD AS ABSENT, and this is the half a presence test cannot see. `$0` is frozen
    # at invocation and is relative when invoked relatively, so a script that has already `cd`'d may
    # be unable to name itself for the re-exec; and a hook that has already drained its payload from
    # stdin loses it, because the re-exec restarts the script from the top with that fd inherited.
    # The stdin-consumer set is the `read` FAMILY, not just `$(cat)`. `IFS= read -r payload` before
    # the gate drained a hook's payload and passed the first version of this rule — same defect as
    # the narrow `cd` test, found by review. `mapfile`/`readarray` are bash 4+ spellings of the
    # same thing, and `dd`/`</dev/stdin` are the two other ways a prologue eats the payload.
    late="$(first_code_line "$f" \
      '(^|[;&|]|[[:space:]](then|do|else))[[:space:]]*(cd|read|mapfile|readarray|dd)([[:space:]]|$)|\$\(cat\)|<[[:space:]]*/dev/stdin|(^|[[:space:]])(IFS=[^[:space:]]*[[:space:]]+)?read[[:space:]]+-')"
    if [ -n "$late" ] && [ "$late" -lt "$call" ]; then
      check_note "$key calls the floor gate at line $call, AFTER a cd or a stdin read at line $late — move it earlier (\$0 may no longer resolve, and a consumed stdin is not restored by the re-exec)"
      check_fail
    fi
  done <<EOF
$scanned
EOF

  if [ "$eps" -eq 0 ]; then
    check_note "no shebang-bearing files found under $root — this lint scanned nothing, which is not a pass"
    check_fail
    return
  fi
  # SAY WHAT IT CHECKED, not merely that it passed: a scanner that goes blind reports the same
  # clean verdict as a clean repo, and a count is what makes the difference readable in a log.
  printf 'bash-floor: %d entry point(s) — %d gate, %d advisory, %d exempt\n' \
    "$eps" "$gates" "$advisories" "$exempts"
}

case "${1:-}" in
  --runtime)
    runtime_check
    check_result "interpreter clears the $FLOOR floor"
    ;;
  --workflow-dir)
    [ "$#" -ge 2 ] && [ -n "${2:-}" ] || { echo "usage: bash scripts/check-bash-floor.sh --workflow-dir DIR" >&2; exit 2; }
    static_lint "$2"
    check_result "every CI job is on a proven bash >= $FLOOR runner and wires the runtime guard"
    ;;
  --entrypoints)
    entrypoint_lint "${2:-.}"
    check_result "every entry point calls the bash >= $FLOOR runtime gate"
    ;;
  "")
    static_lint ".github/workflows"
    entrypoint_lint "."
    check_result "every CI job is on a proven bash >= $FLOOR runner, and every entry point gates its interpreter"
    ;;
  *)
    echo "usage: bash scripts/check-bash-floor.sh [--runtime | --workflow-dir DIR | --entrypoints [DIR]]" >&2
    exit 2
    ;;
esac
