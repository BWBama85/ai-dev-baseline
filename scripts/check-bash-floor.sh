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

FLOOR="${ADB_BASH_FLOOR:-5.3}"

# Runner labels this repo has PROVEN carry bash >= 5.3, with the evidence recorded in
# docs/ci-runners.md. Deliberately an allowlist, not a denylist of known-old labels: `ubuntu-latest`
# is the trap (it is ubuntu-24.04 / bash 5.2.21 today and silently becomes something else later),
# and a denylist waves through every label nobody thought to name.
APPROVED_LINUX="ubuntu-26.04"
APPROVED_MACOS="macos-latest"
APPROVED_RUNNERS="$APPROVED_LINUX $APPROVED_MACOS"

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
    # Job keys sit at exactly two spaces under `jobs:`. `on:` puts push/pull_request at that SAME
    # indent, so track whether we are inside the jobs: block rather than scanning the whole file —
    # the trap docs/repo-settings.md records this repo'"'"'s own ci.yml falling into.
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[^[:space:]#]/      { in_jobs = 0 }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      if (job != "") printf "%s\t%s\t%s\n", job, (runson == "" ? "<none>" : runson), guard
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
      runson = ""; guard = 0
      next
    }
    job == "" { next }
    /^    runs-on:/ {
      v = $0; sub(/^    runs-on:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v); runson = v; next
    }
    # A COMMENT mentioning the invocation must not count as wiring it. Without this exclusion a
    # job could carry `# TODO: add check-bash-floor.sh --runtime` and be recorded as guarded —
    # a lint that reads a note about doing the thing as the thing.
    /check-bash-floor\.sh --runtime/ { if ($0 !~ /^[[:space:]]*#/) guard = 1 }
    END { if (job != "") printf "%s\t%s\t%s\n", job, (runson == "" ? "<none>" : runson), guard }
  ' "$1"
}

static_lint() {
  dir="$1"
  files=0 jobs=0 linux_jobs=0 macos_jobs=0

  for wf in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$wf" ] || continue
    files=$((files + 1))

    # No step may pick its own interpreter. The runtime guard proves the bash a `run:` step gets by
    # default; a `shell:` override routes around it silently, and nothing in this bash-only repo
    # needs one. A step that legitimately does should update this lint, not slip past it.
    if grep -Eq '^[[:space:]]*shell:' "$wf"; then
      check_note "$wf sets a 'shell:' override, which escapes the floor guard:"
      grep -En '^[[:space:]]*shell:' "$wf" | sed 's/^/    /' >&2
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
    while IFS="$(printf '\t')" read -r job runson guard; do
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
      if [ "$guard" != "1" ]; then
        check_note "$wf: job '$job' never runs 'scripts/check-bash-floor.sh --runtime', so nothing proves the bash it actually got"
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
  # ZERO JOBS IS NOT A PASS. A scanner that has gone blind — a reindented file, a changed job-key
  # shape — reports exactly what a clean repo reports, which is the silent-guard failure this repo
  # keeps paying for (#213, and check_summary's own zero-assertion rule).
  if [ "$jobs" -eq 0 ]; then
    check_note "scanned $files workflow file(s) and found ZERO jobs — the scanner has gone blind"
    check_fail
    return
  fi

  # #257's first acceptance criterion is that the suite runs on BOTH platforms. Without this, the
  # macOS job can be deleted and every remaining rule still passes: the floor would be proven on
  # the one platform where it was never in doubt.
  [ "$linux_jobs" -gt 0 ] || { check_note "no job runs on a proven Linux runner ($APPROVED_LINUX) — the floor is unproven on Linux"; check_fail; }
  [ "$macos_jobs" -gt 0 ] || { check_note "no job runs on a proven macOS runner ($APPROVED_MACOS) — the floor is unproven on the platform where it is hardest to reach"; check_fail; }

  printf 'bash-floor: %d job(s) across %d file(s) — %d Linux, %d macOS, floor %s\n' \
    "$jobs" "$files" "$linux_jobs" "$macos_jobs" "$FLOOR"
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
  "")
    static_lint ".github/workflows"
    check_result "every CI job is on a proven bash >= $FLOOR runner and wires the runtime guard"
    ;;
  *)
    echo "usage: bash scripts/check-bash-floor.sh [--runtime | --workflow-dir DIR]" >&2
    exit 2
    ;;
esac
