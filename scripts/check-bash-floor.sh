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
#   --sub-floor [DIR]    The BOOTSTRAP carve-out (#310) — the mirror image of --runtime. That half
#                        asserts the interpreter is NEW enough; this one asserts the three files
#                        that have to run on an OLD one still can. See its own section below.
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
# Usage: bash scripts/check-bash-floor.sh [--runtime | --workflow-dir DIR | --entrypoints [DIR]
#                                          | --sub-floor [DIR]]
#        exit 0 = clear (a stated SKIP is still clear) · 1 = below the floor / drift / carve-out
#        violation · 2 = usage
#
# THE EXIT CODES ARE THIS SCRIPT'S, never a subprocess's. An old bash reports a syntax error as
# status **2**, which is this script's USAGE code — so --sub-floor captures that status and
# translates it into a check failure rather than letting it leak out and read as "you invoked the
# lint wrongly" on a run that found a real defect.
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


# Emit "<job>\t<runs-on>\t<guard>\t<firstlog>\t<wslguard>\t<wsllog>\t<wsllogd>\t<wslguardd>" for
# every job in the workflow file at $1. Returns non-zero if the file could not be read.
#
# THE OPPOSITE FILTER FROM repo-settings.sh, AND THAT PART IS THE POINT. That module emits provable
# check CONTEXTS and therefore SKIPs jobs on purpose — matrix, `if:`, an interpolated `name:`. A
# floor lint must see every job precisely INCLUDING the ones discovery declines to require: a
# matrix job left on ubuntu-latest is still a job running below the floor.
#
# What is NO LONGER duplicated is how those jobs are FOUND (#262). Both files used to carry their
# own job-boundary detection and their own YAML scalar parser, and the two had already drifted by
# the time THIS one was written: `runs-on: "ubuntu-26.04 # not-the-label"` was read correctly by
# repo-settings.sh and reduced to the approved label `ubuntu-26.04` here, which would have accepted
# a job GitHub would never schedule. Review caught it before #257 merged. Enumeration now comes from `adb_wf_jobs` in scripts/lib/common.sh — one reader, two
# opposite filters — and it hands over each job's LINE RANGE and STEP boundaries so the rules below
# stay scoped without re-answering "where does this job start" in a second dialect.
#
# WHAT STAYS HERE is this lint's own grammar: which `run:` invocations count as wiring the guard,
# and the WSL forms. That is a question about THIS repo's CI contract, not about YAML.
scan_jobs() {
  local records
  records="$(adb_wf_jobs "$1")" || return 1
  # Passed through the ENVIRONMENT, not `awk -v`: -v processes backslash escapes in the value, so a
  # job key or a runner label containing a backslash would arrive mangled. ENVIRON does not.
  #
  # The ceiling this accepts, stated rather than discovered: the records ride `execve`'s ARG_MAX
  # alongside the inherited environment (1 MiB on this macOS host). A workflow large enough to cross
  # it cannot start awk — which fails CLOSED, through the `|| return 1` below, so the lint refuses
  # rather than reporting a clean scan. Reaching it needs thousands of jobs in one file; the two in
  # this repo produce a few KB.
  ADB_WF_RECORDS="$records" awk "$_ADB_WF_AWK"'
    # The distro token a `wsl -d <name>` / `--distribution <name>` invocation names, unquoted, or
    # empty. Captured rather than merely matched because the two WSL steps must name the SAME
    # distro: without this the lint accepts a `bash --version` logged in distro A followed by the
    # floor proved in distro B, while the job claims to have logged the interpreter it proved.
    function wsl_distro(s,   t) {
      if (match(s, /(-d|--distribution)[[:space:]]+[^[:space:]]+/)) {
        t = substr(s, RSTART, RLENGTH)
        sub(/^(-d|--distribution)[[:space:]]+/, "", t)
        return adb_wf_unquote(t)
      }
      return ""
    }
    BEGIN {
      n = split(ENVIRON["ADB_WF_RECORDS"], REC, "\n")
      njobs = 0
      for (r = 1; r <= n; r++) {
        if (REC[r] == "") continue
        # Split on the FIRST tabs only, keeping the free-text value whole: every record in this
        # grammar carries at most one such value and carries it LAST (see common.sh).
        tag = REC[r]; sub(/\t.*$/, "", tag)
        body = REC[r]; sub(/^[^\t]*\t/, "", body)
        if (tag == "JOB") {
          j = body; sub(/\t.*$/, "", j); v = body; sub(/^[^\t]*\t/, "", v)
          KEY[j + 0] = v; if (j + 0 > njobs) njobs = j + 0
        } else if (tag == "RANGE") {
          j = body; sub(/\t.*$/, "", j); v = body; sub(/^[^\t]*\t/, "", v)
          s = v; sub(/\t.*$/, "", s); e = v; sub(/^[^\t]*\t/, "", e)
          for (i = s + 0; i <= e + 0; i++) OWNER[i] = j + 0
        } else if (tag == "RUNSON") {
          j = body; sub(/\t.*$/, "", j); v = body; sub(/^[^\t]*\t/, "", v)
          RUNSON[j + 0] = v
        } else if (tag == "STEP") {
          j = body; sub(/\t.*$/, "", j); v = body; sub(/^[^\t]*\t/, "", v)
          k = v; sub(/\t.*$/, "", k); ln = v; sub(/^[^\t]*\t/, "", ln)
          STEPAT[ln + 0] = k + 0
        } else if (tag == "FLAG") {
          j = body; sub(/\t.*$/, "", j); v = body; sub(/^[^\t]*\t/, "", v)
          if (v == "inline") INLINE[j + 0] = 1
          else if (v == "merge") MERGE[j + 0] = 1
        }
      }
    }
    # A step BEGINS at the line the shared reader assigned it; every line after it belongs to that
    # step until the next one starts. Tracked per job so a job with no steps at all leaves `step`
    # at 0 rather than inheriting the previous job'"'"'s count.
    {
      j = OWNER[FNR] + 0
      if (j != cur) { cur = j; step = 0 }
      if (j > 0 && STEPAT[FNR] > 0) step = STEPAT[FNR]
    }
    j == 0 { next }
    # BLOCK-SCALAR CONTENT IS DATA, NOT STRUCTURE, and skipping it here closes a fail-open that
    # every rule below shared. The `run:` patterns are deliberately unanchored (a step key can sit
    # at any depth), so a `run: |` block whose CONTENT happened to contain the literal line
    #     run: bash scripts/check-bash-floor.sh --runtime
    # set GUARD without the guard running even once — a here-document that merely PRINTS the
    # command satisfied it. That is the same species as the `echo` bypass this file already closed,
    # and the whole point of the surrounding rules is EXECUTING, not APPEARING.
    #
    # A block scalar opens on a `<key>: |` / `<key>: >` line and owns every following line indented
    # MORE than THAT KEY, which is YAML'"'"'s own rule and needs no indent unit to apply.
    #
    # THE KEY'"'"'S COLUMN, NOT THE DASH'"'"'S. On a sequence-entry line the two differ, and using the dash
    # swallowed the entry'"'"'s SIBLING KEYS: for
    #     - name: |
    #         some multi-line name
    #       run: bash --version
    # the dash sits at 6 and `run:` at 8, so everything deeper than 6 was skipped as scalar text and
    # the real `run:` went unseen — the lint then reported a VALID workflow as not logging
    # `bash --version`. Sibling keys sit at the key'"'"'s own column, so anchoring there ends the scalar
    # exactly where YAML does.
    {
      lead = match($0, /[^ ]/) ? RSTART - 1 : 0
      if (inblock) { if ($0 ~ /^[[:space:]]*$/ || lead > blockcol) next; inblock = 0 }
      # THE DASH FORM IS TESTED FIRST, and that ordering is load-bearing rather than stylistic: the
      # plain-key pattern below ALSO matches a sequence entry (its `[^:[:space:]]` happily consumes
      # the `-`), so with the arms the other way round the dash branch was unreachable and blockcol
      # kept taking the dash'"'"'s column — which is the whole defect this is fixing.
      if ($0 ~ /^[[:space:]]*-[[:space:]]+[^:[:space:]][^:]*:[[:space:]]*[|>][0-9]*[-+]?[[:space:]]*$/) {
        match($0, /^[[:space:]]*-[[:space:]]+/)
        inblock = 1; blockcol = RLENGTH
      } else if ($0 ~ /^[[:space:]]*[^:[:space:]][^:]*:[[:space:]]*[|>][0-9]*[-+]?[[:space:]]*$/) {
        inblock = 1; blockcol = lead
      }
    }
    # `bash --version` must be logged by the job'"'"'s FIRST step (#257 acceptance criterion 2), before
    # checkout or any bootstrap — so a runner image that quietly changed its bash is visible in the
    # log even when a later step is what fails.
    step == 1 && /run:.*bash --version/ { FIRSTLOG[j] = 1 }
    # EXECUTING, not merely APPEARING. The invocation must be the WHOLE run value — `run: bash
    # scripts/check-bash-floor.sh --runtime` and nothing else on the line. Anything looser passes
    # for a step that only talks about it: an `env:` value, a step `name:`, and (the one that
    # survived the first tightening) `run: echo '"'"'bash scripts/check-bash-floor.sh --runtime'"'"'`,
    # which runs the guard exactly zero times while satisfying a substring test.
    # A `run: |` BLOCK carrying it on a later line is not recognized either, and reports unguarded:
    # fail-closed, and no job here uses that form.
    /^[[:space:]]*run:[[:space:]]*bash[[:space:]]+scripts\/check-bash-floor\.sh[[:space:]]+--runtime[[:space:]]*$/ { GUARD[j] = 1 }
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
      if (WSLLOG[j] == 0) { WSLLOG[j] = step; WSLLOGD[j] = wsl_distro($0) }
    }
    /^[[:space:]]*run:[[:space:]]*wsl(\.exe)?[[:space:]]+(-d|--distribution)[[:space:]]+[^[:space:]]+[^|;&]*--[[:space:]]+bash[[:space:]]+scripts\/check-bash-floor\.sh[[:space:]]+--runtime[[:space:]]*$/ {
      if (WSLGUARD[j] == 0) { WSLGUARD[j] = step; WSLGUARDD[j] = wsl_distro($0) }
    }
    END {
      for (j = 1; j <= njobs; j++) {
        ro = RUNSON[j]
        # An inline flow-mapping job (`hidden: {runs-on: …, steps: […]}`) is a real job the shared
        # reader does not decompose. Reported with an unmatchable label rather than omitted:
        # INVISIBLE is the one outcome a floor lint may never produce, so this fails LOUDLY on a
        # form it cannot verify instead of silently not seeing the job at all.
        if (INLINE[j]) ro = "<inline mapping>"
        # A JOB WHOSE CONFIGURATION ARRIVES THROUGH A MERGE KEY (#291) names the cause instead of
        # reporting a bare `<none>`, which is the same courtesy `<inline mapping>` already gets: the
        # label is still unmatchable, so this job still FAILS loudly — invisible is the one outcome
        # a floor lint may never produce — but the operator is told WHY the runner was unreadable
        # rather than left to guess which of half a dozen shapes emitted nothing.
        #
        # ONLY WHERE `<none>` WOULD HAVE GONE. A job that merges a `<<:` AND declares its own
        # `runs-on:` has a runner this lint can read, and reading it is the whole question here —
        # whether GitHub accepts the syntax of the file is a verdict repo-settings.sh makes, not a
        # reason to fail a proven runner in this lint.
        if (ro == "" && MERGE[j]) ro = "<merge key>"
        if (ro == "") ro = "<none>"
        # REFUSE TO SERIALIZE A VALUE THIS RECORD CANNOT ENCODE. Unlike the shared reader'"'"'s grammar,
        # this record carries EIGHT fields and its consumer splits them field-by-field, so its free
        # text cannot be value-last. A tab inside a quoted `runs-on:` therefore shifted `guard` and
        # `firstlog` into the label'"'"'s own bytes: `runs-on: "ubuntu-26.04<TAB>1<TAB>1"` produced a job
        # with a nonexistent runner that the lint reported as guarded and logging — a fail-OPEN in a
        # guard, which is the one outcome this file exists to prevent.
        #
        # A tab cannot appear in a real GitHub job id or runner label, so this is unreachable for a
        # valid workflow; it is refused rather than escaped because a guard must not quietly
        # normalize an input it cannot represent (the same rule state-scan applies in D41).
        if (KEY[j] ~ /\t/ || ro ~ /\t/) {
          printf "bash-floor: FATAL — job %d carries a TAB in its key or runs-on value, which this record cannot encode\n", j > "/dev/stderr"
          bad = 1
          continue
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", KEY[j], ro, \
               GUARD[j] + 0, FIRSTLOG[j] + 0, WSLGUARD[j] + 0, WSLLOG[j] + 0, WSLLOGD[j], WSLGUARDD[j]
      }
      if (bad) exit 1
    }
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

    # BOTH TEST SEAMS, not just the floor (see the header). A workflow that sets one — at workflow,
    # job or step level — turns the assertions in that scope into a formality while this lint stays
    # green, which is the one bypass the validation above cannot see from inside the guard.
    #
    # ADB_SUB_FLOOR_CANDIDATES belongs here for exactly the same reason and is the sneakier of the
    # two: pointing it at a path that does not exist leaves NO candidate below the floor, so the
    # sub-floor half reports a SKIP and the job is green — rule B disabled everywhere, by one `env:`
    # line, on a lint whose whole subject is bypasses of this shape. It is NOT a substring of
    # ADB_BASH_FLOOR, so the old single-token grep would never have seen it.
    if grep -Eq 'ADB_BASH_FLOOR|ADB_SUB_FLOOR_CANDIDATES' "$wf"; then
      check_note "$wf sets a bash-floor TEST SEAM, which turns the guards in that scope into a formality:"
      grep -En 'ADB_BASH_FLOOR|ADB_SUB_FLOOR_CANDIDATES' "$wf" | sed 's/^/    /' >&2
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

# --- sub-floor half (#310) -----------------------------------------------------------------------
#
# THE MIRROR IMAGE OF --runtime. That half proves the interpreter a job GOT is new enough. This one
# proves the handful of files that must run on an OLD one still can — because they are what TELLS
# you the interpreter is too old.
#
# D30 makes `scripts/lib/common.sh` permanently exempt from the 5.3 floor: it holds
# `adb_require_bash`, and a caller cannot reach that function until sourcing has FINISHED, so a
# 5.3-only construct there makes the gate unreachable on exactly the hosts it exists for. D35
# widened the set to three files on the rule *"does this code have to run in order to REPORT that
# the interpreter is too old"* — `common.sh`, this observer, and the `check-lib.sh` the observer
# sources at its top.
#
# NOTHING EXECUTED THAT CLAIM, which is #310. `check-fact-drift.sh`'s `bash-floor-bootstrap-carveout`
# rule asserts the WORD "parseable" still appears in the four documents that explain the carve-out;
# it says nothing about whether any of them parses. And CI never takes the sub-floor path, because
# both hosted runners resolve a bash at or above the floor — which is precisely the situation
# `adb_require_bash` exists for. So a 5.3-only construct added here passes every job, and then, on
# a stock macOS, every entry point that sources `common.sh` dies with a SYNTAX ERROR instead of the
# actionable "install bash 5.3" message. The gate does not fail; it never runs.
#
# THREE RULES, because no one of them covers the constructs D30 names. Measured against a real
# /bin/bash 3.2.57 and a real 5.3.15 rather than assumed:
#
#   RULE A — THE SOURCE SCAN, interpreter-independent, so it runs on every host including the Linux
#            runners that have no sub-floor bash at all. A 5.3 command substitution (the expansion
#            that opens with a brace followed by a space, or by a pipe) PARSES under 3.2 — `bash -n`
#            is clean — and dies at EXPANSION, so rule B cannot see it; and an expansion inside a
#            FUNCTION BODY is never reached by merely sourcing the file, which is where nearly all
#            of these three files' code lives.
#
#            This is D35's predicate, MOVED HERE from check-bash-floor-guard.sh (D54). Nothing about
#            it changed and nothing it caught is now uncaught — but the guard's job is to drive a
#            rule red, and a rule living only in the guard is a rule this lint does not own. It also
#            removes the second copy of the below-floor file list, which is the drift this repo's
#            own law forbids (docs/design-principles.md).
#
#   RULE B — THE PARSE + BOOTSTRAP PROBE, under the OLDEST interpreter on this host that is BELOW
#            the floor. `bash -n` catches the grammar bash grew after 3.2 — `coproc NAME { … }`,
#            `;&`, `;;&`, `|&` — anywhere in the file, function bodies included, which rule A
#            cannot. The probe then SOURCES `common.sh` under that interpreter and requires
#            `adb_require_bash` to come back reachable with NOTHING on stderr. That is D30's claim
#            in its own words, and it is the only rule here that would notice a TOP-LEVEL expansion
#            failure — `common.sh` has real source-time behaviour (a double-source sentinel, two
#            `read -r -d ''` heredoc loads, a `printf` substitution), so the probe runs in an
#            isolated subprocess and never in this shell.
#
#   RULE C — THE CONSTRUCT SCAN BY NAME (#315), interpreter-independent like rule A, and for the
#            same reason: rule B needs a sub-floor subject, which only `selfcheck-macos` has, and
#            the failure this rule catches is precisely one that passes every job on both runners
#            and then breaks on a stock macOS.
#
#            D30 forbids FIVE constructs in these files. Rule A owns `${ command; }`; this one owns
#            the other four — `mapfile`/`readarray`, associative arrays, namerefs and `readlink -f`
#            — which sat unenforced because neither existing rule can see them INSIDE A FUNCTION
#            BODY. Measured against the real /bin/bash 3.2.57, not assumed, and the measurement is
#            the argument for the rule: bash 3.2 `bash -n`-ACCEPTS all four, sourcing a file never
#            runs a body, and at call time NONE OF THEM STOPS THE SHELL —
#
#              `mapfile -t a`           `command not found` (status 127), the array left EMPTY
#              `declare -A m; m[x]=1`   `invalid option` (status 2), and `m[x]=1` then writes index
#                                       0 of an INDEXED array, so `${m[x]}` reads back correctly by
#                                       accident
#              `local -n r=$1`          `invalid option` (status 2), the ref left empty
#              `readlink -f`            works on current macOS; D30 carries it as a COREUTILS
#                                       portability rule, not a bash-version one
#
#            NONE OF THEM STOPS THE SHELL, which is the load-bearing part: these files set no
#            `set -e`, so the function runs on past the failed builtin with the wrong data and the
#            script still exits 0. (Review corrected an earlier draft here that reported those
#            statuses as 0 — that was the SCRIPT's exit status, not the builtin's. The distinction
#            matters: the builtin does report a failure, and nothing reads it.) A gate whose repair
#            path silently computes the WRONG answer is worse than one that dies, because the caller
#            carries on. That is why a name scan earns its place even though it is a blunt
#            instrument.
#
#            WHOLE-FILE, not a declared call-path. #315 names the gate's call graph and asks for
#            "at least" that; a hand-declared function list is the second copy D54 removed, one
#            level down — add a helper to the repair path, forget the list, and the rule silently
#            stops covering what it names. Whole-file needs no declaration, and it is already what
#            these files say about THEMSELVES: `common.sh`'s header states the ban for the file,
#            `check-lib.sh` says its own `check_enumerated` "must stay evaluable on bash 3.2 (D35),
#            which has no namerefs" about a helper that is NOT on the observer's path, and D31
#            exempts this observer from the gate — so it never re-execs and EVERY line of it runs
#            on whatever PATH resolved. Measured cost of the wider scope: zero findings. The tracked
#            tree carries TWO matching lines and both are sanctioned: the entry-point lint's
#            stdin-consumer regex, and this table's own `mapfile` row, which matches its own pattern.
#
#            DECLARATIONS AND INVOCATIONS, never "associative-array semantics". There is no lexical
#            signature for the latter: `${BASH_VERSINFO[0]}` and `${assoc[key]}` are the same three
#            tokens, and this repo has six of the former in the scanned set. A usage scan would
#            report all six. So the rule bans the spellings that CREATE the hazard and says so.
#
#            WHERE THE MARKER DOES NOT REACH, stated because an escape that is advertised and then
#            unusable is worse than one that is scoped honestly: a construct NAMED INSIDE A HEREDOC
#            BODY is scanned like any other line, and a heredoc body is DATA — appending a marker to
#            it changes the text the script emits. So the escape there is to restructure (name the
#            construct outside the heredoc, or split the line), not to mark it. Same for a construct
#            spelled inside a multi-line string. This is the price of the line-oriented, quote-
#            unaware scan D35 chose for rule A, paid in the same currency: a loud false positive
#            rather than a silent miss. Neither case occurs in the tracked set today.
#
# A SKIP IS LOUD, NEVER SILENT, and it is the honest answer rather than a workaround. Where no
# interpreter below the floor exists — every Linux runner, and any WSL distro on 26.04 — rule B has
# no subject, and running `bash -n` under a 5.3 would prove nothing about D30 while looking exactly
# like a pass. So it says so and names every candidate it probed with the version each reported.
# Installing or compiling an old bash to manufacture a subject is deliberately NOT done: macOS
# already supplies a real one, and `selfcheck-macos` runs this whole suite there on every PR.
#
# WHAT IS NOT COVERED, stated rather than implied, because a check that overstates itself is worse
# than none. RULE C below bans the four constructs D30 NAMES, so what remains is the OPEN set: a
# post-3.2 feature nobody has named — `${var^^}`, a builtin's newer flag, a behavioural difference
# with no distinctive spelling at all — is invisible to every rule here, and so is an associative
# array whose DECLARATION lives outside the scanned set. This half proves PARSEABILITY, BOOTSTRAP
# REACHABILITY, and the ABSENCE OF FIVE NAMED CONSTRUCTS. It does not prove that every function in
# `common.sh` BEHAVES under 3.2 — four different claims, and only the first three are made here.

# The below-floor set (D30, D35). THE one home: check-bash-floor-guard.sh drives these rules red
# against fixture copies rather than keeping a second copy of the list, so adding a fourth file here
# cannot leave a stale list somewhere else.
SUB_FLOOR_FILES="
scripts/lib/common.sh
scripts/check-bash-floor.sh
scripts/check-lib.sh
"

# THE PER-LINE EXEMPTION MARKER for rule C, in the shape check-fact-drift.sh already uses for its
# own `req_absent` ban rather than a second idiom invented here.
#
# PER LINE, NEVER PER FILE, and that constraint is inherited rather than re-derived: excluding whole
# files made the `req_absent` invariant FALSE — a real call added to an excluded file passed
# undetected — and here it would be worse, because the three excludable files are exactly the ones
# the rule exists to protect. A sanctioned line carries the marker; everything else is a finding.
#
# The marker names the CLASS, so it cannot over-sanction: a line exempt from the `mapfile` rule
# still goes red the moment a `declare -A` is added to it.
_ADB_SF_ALLOW="adb-allow: sub-floor-"

# The four constructs D30 names besides `${ command; }` (rule A owns that one), as
# "<class> <ERE> <rest…>". ONE record per class, and the class name is what a sanctioned line
# spells in its marker — so the ban and its escape hatch are declared in the same place and cannot
# drift apart. The guard drives each row red against fixture copies rather than keeping a second
# construct list, which is the same law that put the FILE list here (D54).
#
# Fields are SPACE-separated and every pattern is written with `[[:space:]]` rather than a literal
# space, which is what lets `read -r class pattern rest` split a row. `rest` is discarded; it is
# where a row carries its own marker for the one case where a row's text matches its own pattern.
#
# A CLASS NAME MUST BE REGEX-SAFE, because it is interpolated into the marker pattern below
# (`#[[:space:]]*<marker><class>[[:space:]]*$`). The four here are `[a-z-]` only. A future class
# carrying `.`, `+`, `*` or a bracket would need escaping at that site rather than a wider match.
#
# THE SPELLINGS ARE DELIBERATELY WIDE WITHIN EACH CLASS, since a pattern that catches three of four
# spellings is green on the fourth (base/practices/self-review.md). `readarray` counts as `mapfile`;
# `typeset` and `readonly` count alongside `declare` and `local`; and the flag is matched inside a
# CLUSTER (`-gA`, `-Ag`, `-An`) and across SEPARATED option words (`declare -g -A m`,
# `local -g -n r`), which review reproduced as a live bypass of the first cut — the earlier pattern
# only ever examined the option word immediately after the builtin.
#
# `readlink` IS NARROWER THAN "any flag", and the first cut had that wrong. D30 bans `readlink -f`,
# meaning the CANONICALIZE family — `-f`, `-e`, `-m` and `--canonicalize*`, whose letters no other
# readlink option carries. `readlink -n` is portable (verified on macOS and GNU alike), so refusing
# every option banned working, portable shell and contradicted this file's own claim that it bans
# five NAMED constructs.
SUB_FLOOR_CONSTRUCTS='
mapfile (^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$) # adb-allow: sub-floor-mapfile
associative-array (^|[^[:alnum:]_])(declare|local|typeset|readonly)([[:space:]]+[-+][[:alnum:]]+)*[[:space:]]+-[[:alnum:]]*A
nameref (^|[^[:alnum:]_])(declare|local|typeset)([[:space:]]+[-+][[:alnum:]]+)*[[:space:]]+-[[:alnum:]]*n
readlink-f (^|[^[:alnum:]_])readlink([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+(-[[:alnum:]]*[fem]|--canonicalize)
'

# A literal tab, built rather than typed: the two places that need one are a `case` pattern and a
# parameter-expansion suffix, and a raw tab in either is invisible to a reader and easily eaten by
# an editor.
_ADB_SF_TAB="$(printf '\t')"
# A literal newline, built the only way a command substitution allows: the substitution strips
# trailing newlines, so the sentinel character is appended and then removed.
_ADB_SF_NL="$(printf '\nx')"; _ADB_SF_NL="${_ADB_SF_NL%x}"

# THE CANDIDATE SEAM, and it exists for the same reason ADB_BASH_FLOOR does: so the negative half of
# this rule can be OBSERVED failing on a host that has no sub-floor bash. Newline-separated
# interpreter paths replacing adb_bash_candidates. Without it, "the oldest candidate is selected,
# not the first-listed or the lexically smallest" is untestable on Linux — and selection is real
# logic that fails silently, since picking the WRONG interpreter still produces a green run.
#
# It widens nothing a caller could not already do: every path is probed by EXECUTING it, and anyone
# who can set this variable can run that binary directly.
sub_floor_candidates() {
  if [ -n "${ADB_SUB_FLOOR_CANDIDATES:-}" ]; then
    printf '%s\n' "$ADB_SUB_FLOOR_CANDIDATES"
    return 0
  fi
  adb_bash_candidates
}

# The OLDEST interpreter on this host that is strictly BELOW the floor, as "<path><TAB><version>",
# or nothing (status 1).
#
# OLDEST, not first-listed: adb_bash_candidates is ordered for finding a modern re-exec TARGET —
# fixed prefixes first, `command -v` last — which is the opposite question. Taking its first
# sub-floor hit would pick whichever old bash happened to sit earliest in an ordering built for
# something else, and the strongest available subject is the oldest one.
#
# Numerically, through adb_version_ge, never lexically: "10.0" sorts below "3.2" as a string. And
# never `sort -V`, which this repo bans outright.
sub_floor_subject() {
  _sf_cands="$(sub_floor_candidates)"
  _sf_seen="" _sf_best="" _sf_bestv="" _sf_c="" _sf_v="" _sf_refused=0
  while IFS= read -r _sf_c; do
    [ -n "$_sf_c" ] || continue
    # Duplicates are ordinary, not exceptional: `command -v bash` routinely repeats a fixed prefix
    # already listed above it. Skipping them keeps the SKIP diagnostic readable and saves an exec.
    # REFUSE A PATH THIS RECORD CANNOT ENCODE, rather than mangling it — the same rule scan_jobs
    # applies above and D41 applies to state-scan. The verdict travels as "<path><TAB><version>" and
    # the dedupe key is `|`-delimited, so a tab would truncate the chosen path at the split and a
    # newline would forge a second record: either one selects or EXECUTES an interpreter other than
    # the one that was probed. Unreachable for a real bash, refused rather than escaped because a
    # guard must not quietly normalize an input it cannot represent.
    case "$_sf_c" in
      *"$_ADB_SF_TAB"*|*"|"*)
        # REFUSED, AND REMEMBERED. Skipping alone is a fail-OPEN when this is the only sub-floor
        # interpreter on the host: the run then reports "no interpreter below the floor exists",
        # SKIPs both rules and exits 0, while a usable subject was sitting right there. The status
        # below turns that case into a hard failure; a refusal alongside some other usable candidate
        # stays a note, because the check still ran.
        _sf_refused=1
        printf 'bash-floor: refusing candidate path containing a TAB or a "|" — it cannot be encoded here\n' >&2
        continue ;;
    esac
    case "$_sf_seen" in *"|$_sf_c|"*) continue ;; esac
    _sf_seen="$_sf_seen|$_sf_c|"
    _sf_v="$(adb_bash_version_at "$_sf_c" 2>/dev/null || true)"
    # Unusable candidate — absent, not executable, or it could not report a version. Not a subject,
    # and not a failure either: this list is a superset of what any one host carries.
    [ -n "$_sf_v" ] || continue
    # VALIDATE THE REPORTED VERSION, for the same reason ADB_BASH_FLOOR is validated at the top of
    # this file: `adb_version_ge` reads a non-numeric component as 0, so a candidate reporting `x`
    # compares as 0.0.0, is judged BELOW the floor, and is chosen — while it may in fact deliver a
    # 5.3. Review reproduced exactly that: the mode announced it had tested under an interpreter
    # `(x)` and passed without any old bash being involved. A seam that can silently disable the
    # assertion is worse than no seam, so an unparseable version makes the candidate UNUSABLE.
    case "$_sf_v" in
      ''|*[!0-9.]*|.*|*.|*..*)
        printf 'bash-floor: candidate %s reported a non-numeric version %s — not usable as a sub-floor subject\n' \
          "$_sf_c" "$(adb_display_value "$_sf_v")" >&2
        continue ;;
    esac
    adb_version_ge "$_sf_v" "$FLOOR" && continue
    if [ -z "$_sf_best" ] || adb_version_ge "$_sf_bestv" "$_sf_v"; then
      _sf_best="$_sf_c"; _sf_bestv="$_sf_v"
    fi
  done <<EOF
$_sf_cands
EOF
  # THREE answers, not two: 0 = a subject, 1 = genuinely nothing below the floor, 3 = nothing
  # USABLE but a candidate was refused as unencodable. The caller must tell 1 from 3 — the first is
  # an honest SKIP, the second is a check that did not run and must not report success.
  if [ -z "$_sf_best" ]; then
    [ "$_sf_refused" -eq 0 ] || return 3
    return 1
  fi
  printf '%s\t%s\n' "$_sf_best" "$_sf_bestv"
}

# Every candidate and the version it reported, indented, for the SKIP diagnostic. A skip that does
# not say what it looked at is indistinguishable from a skip that looked at nothing.
sub_floor_candidate_report() {
  _sf_cands="$(sub_floor_candidates)"
  _sf_seen="" _sf_c="" _sf_v=""
  while IFS= read -r _sf_c; do
    [ -n "$_sf_c" ] || continue
    case "$_sf_seen" in *"|$_sf_c|"*) continue ;; esac
    _sf_seen="$_sf_seen|$_sf_c|"
    _sf_v="$(adb_bash_version_at "$_sf_c" 2>/dev/null || true)"
    printf '    %s (%s)\n' "$_sf_c" "${_sf_v:-not usable}"
  done <<EOF
$_sf_cands
EOF
}

# Print "    <line>: <text>" for every line carrying a 5.3 command substitution; exit 0 when any was
# found, 1 when the file is clean. Predicate and report are ONE grammar deliberately — a scan whose
# diagnostic is derived separately can name lines it did not match on, or miss the one it did.
#
# ONLY WHOLE-LINE COMMENTS ARE DROPPED, not everything after the first `#`. `sed 's/#.*//'` — the
# idiom the `sort -V` ban uses — does not understand quoting, so a line like
# `printf '#'; x=<funsub>` is truncated at the QUOTED hash and the construct after it becomes
# invisible. That is a guard blinded by ordinary code rather than by a hostile input, so only lines
# that are ENTIRELY a comment are dropped, and one sharing a line with a trailing comment is still
# seen. The cost is that writing the construct inside a trailing comment — or inside a STRING
# LITERAL, which review reproduced — false-positives, loudly, which is the safe direction. Telling
# the two apart needs a quote-aware parser, and D35 weighed exactly that trade and took the loud
# one; a scan that can be blinded by ordinary code is the worse failure.
#
# THE OPENING BRACE MAY END THE LINE, and missing that was a real hole review found: bash 5.3
# accepts
#     value=${
#       printf hi
#     }
# and a pattern requiring a space or a pipe AFTER the brace sees nothing on any line of it. Matching
# end-of-line too is safe rather than merely convenient — a `${` that ends a line is an unterminated
# expansion in every bash before 5.3, so there is no older spelling for it to collide with.
#
# (The awk pattern is written with the brace escaped so this file, which is itself in the scanned
# set, does not match on its own source.)
#
# A LINE IS NOT A STATEMENT, which is why both source scans read LOGICAL lines (#315). A
# backslash-newline is a line SPLICE in shell — the two characters are removed and what remains is
# one line — so a construct written across one is invisible to a matcher that reads physical lines.
# That is a fail-open, and it was measured on both rules rather than reasoned about: a real bash
# 5.3 expands
#     X=$\
#     { printf hi; }
# to `hi`, and rule A reported the file CLEAN. Rule C had the same hole for `declare \` + `-A m`.
# Splicing before matching closes both, and it does so in the direction that also STRENGTHENS the
# patterns: a continuation splitting a word (`map\` + `file -t`) is rejoined and then caught.
#
# THE BACKSLASH IS REMOVED, NOT REPLACED BY A SPACE. A space is what a careless join inserts, and
# it silently reintroduces the very hole: `X=$\` + `{ …` would splice to `X=$ {` — which no longer
# matches — instead of the `X=${` that bash actually sees. Removal is both correct per the shell
# grammar and the only spelling that works.
#
# The comment rule runs BEFORE the splice, deliberately: a trailing backslash in a `#` comment does
# NOT continue it in shell, so a joiner that ran first would swallow the following line of real code.
# AN ODD NUMBER OF TRAILING BACKSLASHES CONTINUES; AN EVEN NUMBER DOES NOT. The second one is an
# ESCAPED backslash and the line ends there — verified against a real bash, which runs the next line
# as its own command. A naive `~ /\\$/` splices both, which merges two independent statements into
# one logical line: the reported line number is then wrong, and — worse — a marker on the second
# statement would sanction a construct on the first. Counting the run is what makes the splice agree
# with the grammar it is modelling.
#
# AND A LINE WHOSE LAST TOKEN IS A COMMENT NEVER CONTINUES. That is not a heuristic — you cannot
# resume a statement after a `#` comment in shell — but it has to be tested for, because only
# WHOLE-line comments are skipped before the splice. Review reproduced the miss: `code # note \`
# spliced the following line onto it, which merges two independent statements and lets a marker on
# the second sanction a construct on the first. The probe strips a trailing comment and the splice
# runs only when that changed nothing, i.e. when the backslash really is the last thing on the line.
# The residual is the same quote-unawareness rule A already documents: a `#` inside a quoted string
# on a genuinely continued line suppresses the splice, which loses a splice rather than forging one.
#
# A COMMENT ALSO STARTS RIGHT AFTER A CONTROL OPERATOR, not only after whitespace, and missing that
# left the same hole one character narrower: `probe() { declare -A x; };# note \` is two independent
# shell lines, and a probe keyed on `[[:space:]]#` did not see the comment, spliced the next line
# onto it, and let THAT line's marker exempt the declaration above — a green run over a real
# construct (review reproduced it). The separator set is bash's own word-start rule: start of line,
# whitespace, or one of `; & | ( )`.
_ADB_SF_JOIN='
  {
    logical = $0; logical_at = NR
    while (1) {
      probe = logical
      sub(/(^|[[:space:]]|[;&|()])#.*$/, "", probe)
      if (probe != logical) break
      if (!(match(logical, /\\+$/) && RLENGTH % 2 == 1)) break
      if ((getline nxt) <= 0) break
      sub(/\\$/, "", logical)
      logical = logical nxt
    }
  }'

sub_floor_funsubs() {
  awk '/^[[:space:]]*#/ { next }'"$_ADB_SF_JOIN"'
       logical ~ /\$\{([[:space:]|]|$)/ { printf "    %d: %s\n", logical_at, logical; n++ }
       END { exit (n > 0 ? 0 : 1) }' "$1"
}

# RULE C's predicate. Print "    <line>: <text>" for every line of $1 carrying construct class $2
# (ERE $3) in code; exit 0 when any was found, 1 when clean. Same three-outcome contract as rule A,
# so a scan that FAILS cannot arrive as "clean" — the caller treats any other status as a broken
# scan, because a scanner that goes blind reports exactly what a clean file reports.
#
# THE PATTERN TRAVELS THROUGH THE ENVIRONMENT, not `-v`. awk's `-v` processes escape sequences in
# the value, so a future row containing a backslash would be silently rewritten before it ever
# reached the matcher. `first_code_line` in this same file already passes its pattern this way.
#
# ONLY WHOLE-LINE COMMENTS ARE DROPPED, exactly as in rule A and for exactly the reason recorded
# there: a quote-unaware `sed 's/#.*//'` is blinded by ordinary code. The cost is the same too — a
# construct named in a TRAILING comment or inside a string literal false-positives, loudly — and
# that cost is what the marker exists to pay. This is the trade D35 weighed and took for rule A;
# #315 asks for the same instrument, so it inherits the same answer rather than inventing a
# quote-aware parser the earlier decision declined.
#
# TWO QUESTIONS, ONE GRAMMAR. A fourth argument of `1` makes it print the number of lines this
# class EXEMPTED instead of the hits. That mode exists because the obvious way to count exemptions
# — `grep -c` for the marker string over the file — counts every MENTION of it: the definition of
# `_ADB_SF_ALLOW`, the row in `SUB_FLOOR_CONSTRUCTS` that carries its own, and every comment
# discussing the mechanism. The first spelling of the summary line did exactly that and reported
# "3 sanctioned marker(s)" for a tree with ONE exempted line — a number that reads like coverage
# and is not. Both answers now come from the same program, so "what counts as a hit" cannot change
# one and not the other.
sub_floor_construct_hits() {
  ADB_SF_PAT="$3" ADB_SF_ALLOW="$_ADB_SF_ALLOW$2" awk -v count_only="${4:-0}" '
    BEGIN { pat = ENVIRON["ADB_SF_PAT"]; allow = ENVIRON["ADB_SF_ALLOW"] }
    /^[[:space:]]*#/ { next }'"$_ADB_SF_JOIN"'
    logical ~ pat {
      # THE MARKER MUST BE IN TRAILING-COMMENT POSITION — a `#`, then only the marker, then the end
      # of the line. A bare substring test is what the first cut used, and review laundered a real
      # construct straight through it with `: <single-quoted marker text>`: ordinary string DATA
      # sanctioning executable code, and silently incrementing the exemption count while doing it.
      #
      # Anchoring to end-of-line is what closes it, and it costs nothing: the documented shape is a
      # trailing comment, which by definition ends the line. A quoted spelling now has to be the
      # last thing on the line with no closing quote after it, which is no longer shell.
      #
      # Matched against the SPLICED line, so a marker riding the LAST physical line of a continued
      # statement still sanctions it — the only place it can legally sit, since a trailing comment
      # on an earlier half would end the statement there.
      if (logical ~ ("(^|[[:space:]]|[;&|()])#[[:space:]]*" allow "[[:space:]]*$")) { x++; next }
      if (!count_only) printf "    %d: %s\n", logical_at, logical
      n++
    }
    END { if (count_only) print x + 0; exit (n > 0 ? 0 : 1) }
  ' "$1"
}

# Set by sub_floor_lint so the terminal PASS line can state which claim it actually established. A
# PASS reading "parses below the floor" on a run that skipped the parse would be exactly the
# overstatement this half exists to remove.
SUB_FLOOR_NOTE="the below-floor carve-out (D30/D35) holds"

sub_floor_lint() {
  # `/` IS A TARGET, not a trailing slash to strip. `${root%/}` empties it, the emptiness guard
  # then rewrites it to `.` — and since this script has already cd'd to the repo root, `--sub-floor /`
  # would report a clean scan OF THE CHECKOUT while the caller believes it scanned the filesystem
  # root. A silently-wrong scope is the one result a scan may never produce.
  root="${1:-.}"
  case "$root" in
    /)  : ;;
    */) root="${root%/}" ;;
  esac
  [ -n "$root" ] || root="."
  sf_files=0 sf_parsed=0 sf_probed=0 sf_subj="" sf_subjv="" sf_pick="" sf_unparsed="" sf_subj_dead=0 sf_unencodable=0
  sf_rules=0 sf_exempt=0

  # THE RULE SET IS COUNTED BEFORE IT IS USED, and an empty one is a FAILURE rather than a clean
  # sweep. Rule C's failure mode is silence in the most literal way available: a table sliced away
  # by an edit, or a row whose class field went blank, scans nothing and prints exactly what four
  # clean rows print. The file-set guard below exists for the same reason; a rule set deserves it
  # as much as a file set does.
  # `sf_rest` absorbs the remainder so `sf_pat` cannot swallow a row's trailing marker — the same
  # three-field split the scan loop below uses, deliberately, so one table is never read two ways.
  # shellcheck disable=SC2034  # deliberate: sf_rest exists to bound sf_pat, not to be read
  while read -r sf_class sf_pat sf_rest; do
    [ -n "$sf_class" ] && [ -n "$sf_pat" ] && sf_rules=$((sf_rules + 1))
  done <<EOF
$SUB_FLOOR_CONSTRUCTS
EOF
  if [ "$sf_rules" -eq 0 ]; then
    check_note "the below-floor CONSTRUCT set is EMPTY — rule C evaluated nothing, which is not a pass"
    check_fail
  fi

  # Resolved ONCE, before the loop: probing the candidate list per file would multiply the execs and
  # could, on a host being reconfigured underneath the run, parse two files under two interpreters
  # and report one.
  sf_pick="$(sub_floor_subject)"; sf_srv=$?
  case "$sf_srv" in
    0) sf_subj="${sf_pick%%	*}"
       sf_subjv="${sf_pick#*	}" ;;
    3) check_note "the only interpreter(s) below the $FLOOR floor sit at paths this check cannot encode (a TAB or a '|'), so the parse and evaluation rules could not run — refusing to report a clean scan"
       check_fail
       sf_unencodable=1 ;;
    *) : ;;
  esac

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    f="$root/$rel"
    sf_files=$((sf_files + 1))

    # A NAMED FILE THAT IS NOT THERE IS A FAILURE, not something to skip past. The set above is the
    # carve-out itself; a stale entry means the lint is silently checking fewer files than it claims.
    if [ ! -f "$f" ]; then
      check_note "the below-floor set names $rel, which is not a file under $root — the list in $0 is stale (D30/D35)"
      check_fail
      continue
    fi

    # RULE A — interpreter-independent, so it runs even when rule B has no subject.
    #
    # THREE outcomes, not two. The predicate answers 0 (found) / 1 (clean), so ANY other status is
    # the scan itself having failed — a broken or absent awk, an unreadable file — and that must not
    # arrive as "clean". A scanner that goes blind reports exactly what a clean file reports, which
    # is the fail-open `scan_jobs` above already refuses for the same reason.
    sf_hits="$(sub_floor_funsubs "$f")"; sf_arc=$?
    case "$sf_arc" in
      0)
        check_note "$rel uses a 5.3 command substitution, which bash 3.2 PARSES and then fails to EXPAND — and this file has to be evaluable below the $FLOOR floor, because it is what reports that the interpreter is too old (D30/D35):"
        printf '%s\n' "$sf_hits" >&2
        check_fail ;;
      1) : ;;
      *)
        check_note "the source scan over $rel failed outright (status $sf_arc) — refusing to report it clean"
        check_fail ;;
    esac

    # RULE C — the construct scan, one pass per class, interpreter-independent like rule A.
    #
    # PER CLASS rather than one fused pattern, and that is what makes the marker safe: the
    # exemption is keyed to the class that matched, so a line sanctioned for `mapfile` is still
    # reported when a `declare -A` is added to it. A single alternation would have one name for
    # four hazards and could only be exempted wholesale.
    # shellcheck disable=SC2034  # deliberate: sf_rest exists to bound sf_pat, not to be read
    while read -r sf_class sf_pat sf_rest; do
      [ -n "$sf_class" ] && [ -n "$sf_pat" ] || continue

      # Sanctioned lines are COUNTED and reported, never merely honoured. An exemption nobody can
      # see is how a per-line escape becomes a per-file one by accretion: the count is what makes
      # an unexpectedly broad marker visible in an ordinary CI log. Read BEFORE the hit scan so a
      # file that fails the scan still contributes its exemptions to the total.
      sf_ec="$(sub_floor_construct_hits "$f" "$sf_class" "$sf_pat" 1)"
      case "$sf_ec" in ''|*[!0-9]*) sf_ec=0 ;; esac
      sf_exempt=$((sf_exempt + sf_ec))

      sf_chits="$(sub_floor_construct_hits "$f" "$sf_class" "$sf_pat")"; sf_crc=$?
      case "$sf_crc" in
        0)
          # ONE MESSAGE FOR FOUR CLASSES, so it states what is true of ALL of them and points at
          # the per-class reasoning rather than asserting a single failure mode. The first cut said
          # every hit "fails at CALL time", which is false for `readlink -f` — that one works on a
          # current macOS and is banned as a COREUTILS portability rule, exactly as this file's own
          # rule C section and D65 say. A diagnostic that contradicts its own decision record is a
          # claim the reader has to go and disprove.
          check_note "$rel uses $sf_class, which D30 forbids in the below-floor set — this file has to run below the $FLOOR floor, because it is what reports that the interpreter is too old (D30/D35/#315). See the RULE C section of $0 for what each construct does there. Sanction a deliberate mention with a trailing '# ${_ADB_SF_ALLOW}$sf_class' as the last thing on the line:"
          printf '%s\n' "$sf_chits" >&2
          check_fail ;;
        1) : ;;
        *)
          check_note "the $sf_class scan over $rel failed outright (status $sf_crc) — refusing to report it clean"
          check_fail ;;
      esac
    done <<EOF
$SUB_FLOOR_CONSTRUCTS
EOF

    # RULE B, first half — the parse. Skipped file-by-file rather than wholesale so rule A's
    # accounting stays honest either way.
    if [ -n "$sf_subj" ] && [ "$sf_subj_dead" -eq 0 ]; then
      if sf_perr="$("$sf_subj" -n "$f" 2>&1)"; then
        sf_parsed=$((sf_parsed + 1))
      else
        sf_prc=$?
        # A CANDIDATE THAT PROBED FINE BUT CANNOT BE RUN FAILS CLOSED. 126/127 are the shell's
        # "found it, could not execute it" / "not found" codes, and they say nothing about the file
        # under test — treating them as a parse failure would blame the wrong thing, and treating
        # them as a skip would turn a broken subject into a green run.
        #
        # RECORDED AS *DEAD*, not erased. Clearing $sf_subj would silence rule B correctly and then
        # make the summary below take the no-interpreter branch — announcing "no interpreter below
        # the floor exists on this host" about a host that has one and cannot run it. The verdict
        # would still be FAIL, but the explanation would send the reader after the wrong problem,
        # which is the only thing a summary line is for.
        case "$sf_prc" in
          126|127)
            check_note "the chosen sub-$FLOOR interpreter $sf_subj ($sf_subjv) probed a version but cannot be executed (status $sf_prc) — refusing to report a clean scan"
            check_fail
            sf_subj_dead=1
            continue ;;
        esac
        check_note "$rel does not PARSE under $sf_subj ($sf_subjv), the oldest sub-$FLOOR interpreter on this host — every entry point that loads it would die with a syntax error instead of the floor gate's actionable message (D30/D35):"
        printf '%s\n' "$sf_perr" | sed 's/^/    /' >&2
        check_fail
        # ONE DEFECT, ONE LINE — the same rule entrypoint_lint applies below. A file that will not
        # parse obviously will not source either, so letting the bootstrap probe also fire would
        # report the identical defect a second time wearing a different hat. Recorded rather than
        # inferred from the fail count, because the probe must still run when common.sh PARSES and
        # fails at EXPANSION, which is the case rule B exists for.
        sf_unparsed="$sf_unparsed|$rel|"
      fi
    fi
  done <<EOF
$SUB_FLOOR_FILES
EOF

  # RULE B, second half — the EVALUATION PROBE, and it is the whole point of D30 rather than a
  # bonus: parsing proves a file is readable, this proves its top level actually RUNS on the old
  # interpreter, and for common.sh that the gate inside it is REACHABLE afterwards.
  #
  # ALL THREE FILES, not just common.sh. Review found the gap: a top-level `declare -A` in
  # check-lib.sh or in this observer parses fine on 3.2 and then emits `invalid option` when the
  # file is evaluated, and a probe wired to common.sh alone reports PASS. D35's property is about
  # all three, so the probe has to be too.
  #
  # HOW each file is loaded differs, and it has to: the two libraries are SOURCED (that is how they
  # are used), while this observer is EXECUTED and sourcing it would run a lint inside the lint. Its
  # top level is reached instead through the usage path — an unrecognized flag evaluates every
  # top-level statement and every function definition, then exits 2 — so the same question ("does
  # the top level survive this interpreter") is asked of it in the way it is actually used.
  #
  # TWO INDEPENDENT CHANNELS, not one marker string. The first cut carried the verdict in a magic
  # word on stdout with stderr folded in, and review showed the file under test could FORGE it: a
  # copy ending `unset -f adb_require_bash; printf ADB_BOOTSTRAP_REACHABLE` passed with the gate
  # absent. Reachability now rides the EXIT STATUS and silence rides output-emptiness, so producing
  # the right status and no output is the only way through — and printing anything at all, which is
  # what `declare -A` does on 3.2 while leaving the status at 0, still fails.
  if [ -n "$sf_subj" ] && [ "$sf_subj_dead" -eq 0 ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      f="$root/$rel"
      # Skipped for the two reasons that would otherwise report ONE defect twice: the file is
      # missing (the loop above already said so), or it did not parse (so of course it will not run).
      [ -f "$f" ] || continue
      case "$sf_unparsed" in *"|$rel|"*) continue ;; esac

      case "$rel" in
        scripts/lib/common.sh)
          sf_pout="$("$sf_subj" -c '. "$1"; command -v adb_require_bash >/dev/null; exit $?' _ "$f" 2>&1)"
          sf_prc=$?
          sf_what="leave adb_require_bash reachable"
          ;;
        scripts/check-bash-floor.sh)
          # The usage arm: it evaluates the whole top level and exits 2 by design, so 2 is success
          # here and the expected usage line is the only output allowed.
          sf_pout="$("$sf_subj" "$f" --adb-sub-floor-probe 2>&1)"
          [ "$?" -eq 2 ] && sf_prc=0 || sf_prc=1
          # STRIP THE USAGE LINE ONLY WHEN IT IS THE WHOLE OUTPUT. A bare `usage:…*` wildcard
          # clears the entire capture the moment it matches the PREFIX, so anything the observer
          # printed AFTER it — an EXIT-trap warning, a shutdown diagnostic — is discarded and the
          # evaluation is counted clean. The usage arm prints exactly one line, and command
          # substitution strips trailing newlines, so a capture that is just that line contains NO
          # newline at all: the presence of one means there is more, and the more is what matters.
          case "$sf_pout" in
            "usage: bash scripts/check-bash-floor.sh"*)
              case "$sf_pout" in
                *"$_ADB_SF_NL"*) : ;;
                *) sf_pout="" ;;
              esac ;;
          esac
          sf_what="evaluate its top level"
          ;;
        *)
          sf_pout="$("$sf_subj" -c '. "$1"' _ "$f" 2>&1)"
          sf_prc=$?
          sf_what="load"
          ;;
      esac

      if [ "$sf_prc" -ne 0 ] || [ -n "$sf_pout" ]; then
        check_note "$rel does not $sf_what cleanly under $sf_subj ($sf_subjv) — it must be EVALUABLE below the $FLOOR floor, because it is what reports that the interpreter is too old (D30/D35). Status $sf_prc, and it emitted:"
        printf '%s\n' "${sf_pout:-<nothing at all>}" | sed 's/^/    /' >&2
        check_fail
      else
        sf_probed=$((sf_probed + 1))
      fi
    done <<EOF
$SUB_FLOOR_FILES
EOF
  fi

  if [ "$sf_files" -eq 0 ]; then
    check_note "the below-floor set is EMPTY — this half scanned nothing, which is not a pass"
    check_fail
    SUB_FLOOR_NOTE="the below-floor carve-out set was EMPTY"
    return
  fi

  # RULE C's OWN LINE, printed on EVERY branch because rule C runs on every branch — it needs no
  # interpreter, so unlike the parse and the probe it is never skipped. It is a separate line rather
  # than a clause inside the four below precisely so it cannot become platform-dependent the way a
  # phrase pinned to one branch already did once.
  #
  # THE EXEMPTION COUNT IS PART OF THE VERDICT, not trivia: rules-evaluated shows a table that went
  # empty, and markers-honoured shows a per-line escape quietly spreading. A zero in either is then
  # visible in the log instead of indistinguishable from success.
  printf 'bash-floor: sub-floor  rule C evaluated %d construct rule(s) over %d file(s), honouring %d sanctioned marker(s)\n' \
    "$sf_rules" "$sf_files" "$sf_exempt"

  # SAY WHAT IT CHECKED, not merely whether it passed — and say which of the four situations this
  # run was actually in, since "there was no old bash", "the old bash is broken", "its path cannot
  # be encoded" and "it all ran" send a reader four different places.
  #
  # EVERY BRANCH OPENS WITH THE SAME `%d file(s) named`, and that is not cosmetic. The count means
  # one thing — how many files the carve-out set names — so spelling it two ways made it a
  # PLATFORM-DEPENDENT string: macOS has a sub-floor bash and took the "ran" branch, Linux has none
  # and took the SKIP branch, and a guard assertion pinned to one of them passed locally and failed
  # in CI on the other. One fact, one spelling.
  if [ "$sf_subj_dead" -eq 1 ]; then
    printf 'bash-floor: sub-floor  %d file(s) named; the source scans (rules A and C) ran on all of them; the PARSE and EVALUATION PROBE could NOT be run — %s (%s) is the oldest sub-%s interpreter here and it cannot be executed\n' \
      "$sf_files" "$sf_subj" "$sf_subjv" "$FLOOR"
    SUB_FLOOR_NOTE="the below-floor set carries none of the five banned constructs, but its sub-$FLOOR interpreter $sf_subj could not be run"
  elif [ -n "$sf_subj" ]; then
    # The probe is named as RUN or as NOT RUN, never elided: "3 parsed" beside a silent probe reads
    # as a bootstrap that was proved, on the one run where it was not.
    printf 'bash-floor: sub-floor  %d file(s) named; %d parsed and %d evaluated under %s (%s), the oldest sub-%s interpreter here\n' \
      "$sf_files" "$sf_parsed" "$sf_probed" "$sf_subj" "$sf_subjv" "$FLOOR"
    SUB_FLOOR_NOTE="the below-floor carve-out carries none of the five banned constructs and parses and bootstraps under $sf_subj ($sf_subjv)"
  elif [ "$sf_unencodable" -eq 1 ]; then
    # NOT a SKIP, and it must not read like one. A sub-floor interpreter DOES exist here; this
    # check simply cannot name it safely. Printing the ordinary "none exists on this host" line
    # would contradict the candidate list directly below it, which re-probes and shows the very
    # version that was refused.
    printf 'bash-floor: sub-floor  %d file(s) named; the source scans (rules A and C) ran on all of them; the PARSE and EVALUATION PROBE could NOT run — every interpreter below the %s floor sits at a path this check cannot encode. Candidates probed:\n' \
      "$sf_files" "$FLOOR"
    sub_floor_candidate_report
    SUB_FLOOR_NOTE="the below-floor set carries none of the five banned constructs, but no sub-$FLOOR interpreter could be named safely"
  else
    printf 'bash-floor: sub-floor  %d file(s) named; the source scans (rules A and C) ran on all of them; the PARSE and EVALUATION PROBE were **SKIPPED** — no interpreter below the %s floor exists on this host, and running them under a >= %s bash would prove nothing about D30. Candidates probed:\n' \
      "$sf_files" "$FLOOR" "$FLOOR"
    sub_floor_candidate_report
    SUB_FLOOR_NOTE="none of the five banned constructs in the below-floor set (parse + evaluation probe SKIPPED — no sub-$FLOOR interpreter on this host)"
  fi
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
#               for the two files whose own contract forbids a non-zero exit. Naming them here
#               is what stops "advisory" becoming a dial a future script can quietly pick.
#   exempt    — must NOT call it at all, and there is exactly one.
#
# Matched on the path RELATIVE to the scanned root, so the guard can build a fixture tree at the
# same paths and drive each rule red.
ADVISORY_ENTRYPOINTS="
agents/claude/scripts/session-currency.sh
agents/claude/scripts/state-claim-gate.sh
agents/claude/scripts/session-context.sh
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
# `--entrypoints agents/claude` sees `scripts/session-currency.sh`, not
# `agents/claude/scripts/session-currency.sh`, so every advisory hook was classified as a hard gate
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
    #
    # THE PATTERN BELOW CARRIES RULE C's MARKER (#315). It is one of exactly two sanctioned lines
    # in the below-floor set; the other is the `mapfile` row of `SUB_FLOOR_CONSTRUCTS`, which
    # matches its own pattern. Those two words are DATA here — a regex this lint matches other files
    # against — not a builtin this file calls. Rule C is line-oriented and quote-unaware by the same
    # deliberate choice D35 made for rule A, and requiring command position would not help: the `|`
    # alternation puts each word in command position as far as any line matcher can tell. So the
    # answer is the marker, NOT deleting the spellings (which would reopen the exact fail-open
    # review found here) and NOT loosening rule C until it matches nothing.
    late="$(first_code_line "$f" \
      '(^|[;&|]|[[:space:]](then|do|else))[[:space:]]*(cd|read|mapfile|readarray|dd)([[:space:]]|$)|\$\(cat\)|<[[:space:]]*/dev/stdin|(^|[[:space:]])(IFS=[^[:space:]]*[[:space:]]+)?read[[:space:]]+-')"   # adb-allow: sub-floor-mapfile
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
  --sub-floor)
    # EXTRA ARGUMENTS ARE A USAGE ERROR, not something to ignore. This mode's one argument selects
    # the tree it checks, so `--sub-floor . typo` silently checking a different scope than the
    # caller meant is the worst kind of quiet: a green run over the wrong tree.
    [ "$#" -le 2 ] || { echo "usage: bash scripts/check-bash-floor.sh --sub-floor [DIR]" >&2; exit 2; }
    sub_floor_lint "${2:-.}"
    check_result "$SUB_FLOOR_NOTE"
    ;;
  "")
    static_lint ".github/workflows"
    entrypoint_lint "."
    # RIDES THE BARE INVOCATION rather than taking a step or a job of its own, and that is what
    # makes it run at all. `selfcheck-macos` runs this whole suite on macos-latest — the only
    # per-PR environment carrying a real sub-floor bash — so folding it in here is what puts the
    # rule in front of an interpreter that can actually fail it. A separately registered mode
    # nobody invokes would skip on Linux and never run on macOS, leaving #310's defect in place;
    # a new CI job would add a branch-protection context, which this file's own header explains is
    # the thing to avoid. It also inherits `check-fact-drift.sh`'s `bash-entrypoint-lint-wired`
    # pin, which requires this bare form to END the command in both selfcheck and ci.yml.
    sub_floor_lint "."
    check_result "every CI job is on a proven bash >= $FLOOR runner, every entry point gates its interpreter, and $SUB_FLOOR_NOTE"
    ;;
  *)
    echo "usage: bash scripts/check-bash-floor.sh [--runtime | --workflow-dir DIR | --entrypoints [DIR] | --sub-floor [DIR]]" >&2
    exit 2
    ;;
esac
