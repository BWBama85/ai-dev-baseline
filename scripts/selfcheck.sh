#!/usr/bin/env bash
# ai-dev-baseline — local CI mirror. Run before every push.
#
# Runs the checks CI runs, with the two documented exceptions below: shellcheck, build-drift,
# skill-frontmatter, workflow-render,
# gate-detector/gates, common-lib, agent-init, cleanup, repo-settings, bash-floor,
# bash-floor-guard, baseline, session-currency, precommit-gate, implement-gate, install-migration,
# install-guard, fact-drift, fact-mutation, fact-self-test, practice-index, release-skill,
# selfcheck-guard, mutation-gate, and an install→uninstall dry-run into a throwaway HOME.
# Every `*-mutation` step is GATED on its declared inputs (#441) — see "the gate" below.
# "Green here" should mean "green in CI". Requires: git, jq. shellcheck is
# optional (the step SKIPs if it's missing, matching a dev box without it).
#
# HOW IT RUNS (#260): the steps are a REGISTRY — an ordered list of names plus a name → command
# map — dispatched through a `wait -n` job pool bounded at min(cpu, 8). Each step's stdout and
# stderr go to its own file and the PARENT emits the banner, the body and the verdict together
# once the step is reaped, so 8 concurrent steps never interleave into mush. `--serial` runs the
# registry in declaration order with output streaming live, which is what to reach for when a
# parallel failure is hard to attribute. See "the concurrency contract" below for what may run
# concurrently and what may not.
#
# WHAT A GREEN HERE DOES NOT COVER — three things, stated so the promise is the true one (#257):
#
#   1. The two LIVE CI steps (`required-drift`, the claim lint's `--live` half). Deliberate: D13/D24
#      keep this gate hermetic, so a verdict depending on network and auth stays CI-only.
#   2. The OTHER PLATFORM. CI runs this same offline suite on ubuntu-26.04 AND macos-latest, and a
#      workstation is one of them. Nothing here speaks for the other runner's image or its Homebrew
#      bootstrap.
#   3. `check-bash-floor.sh --runtime` — which IS offline, and runs in all 31 CI jobs (the 30 per-PR
#      jobs, plus the scheduled WSL smoke #2 added, which reaches it through `wsl -d …`). Still omitted
#      here, but the reason CHANGED when #256 landed. It is no longer "so a contributor on 5.2 can
#      run selfcheck": they cannot, because line 1 of this script now gates its own interpreter and
#      would have re-exec'd or exited long before any step ran. What --runtime adds beyond that is
#      an assertion about the MACHINE and about `command -v bash` — a CI-image question. The STATIC
#      half, plus the entry-point half #256 added, do run below.

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

# ================================ the concurrency contract ====================================
#
# The default is CONCURRENT, so the exceptions are what need stating. A step is safe to run in the
# pool when it touches only its own `mktemp -d` and reads the working tree read-only. That is the
# case for all but one of them, and it is not an accident: every check-*.sh builds its fixtures
# under a throwaway directory, and the `gh`-shaped suites drive a stub on PATH rather than the
# network (D13 keeps this gate hermetic, which is also why there is no rate limit to serialize on).
#
# `build-drift` is the ONE exception, and it earns the serial prologue:
#
#   * it runs `scripts/build.sh`, which REWRITES tracked generated files in the working tree, and
#   * those files are rewritten one at a time. Each individual file is now published by RENAME
#     (#268) — both renderers stage a uniquely-named sibling temp and `mv` it into place — so no
#     single file is ever observable half-written. What #268 did NOT make atomic, and deliberately
#     so, is the TRANSITION ACROSS FILES: a reader that starts while build.sh is part-way through
#     sees a MIXED GENERATION — some of `agents/{claude,codex,gemini}/*` already renamed and
#     the rest still carrying the old one. That is why fixing the torn-file defect did not retire
#     this pin, and why it must not be read as having done so.
#
# So while it runs, `agents/claude/CLAUDE.md` and its two siblings can be observed out of step with
# each other and with the skills trees — by `workflow-map` and `skill-frontmatter` here, and by
# `fact-drift`, `injection`, `bash-floor`, `roadmap`, `release-skill`, `install-guard` and
# `install-dry-run`, all of which read that tree. Running it alone, first, removes the whole class
# rather than one instance of it.
#
# What is deliberately NOT serialized, so the reasoning is auditable rather than re-derived:
#
#   * `check-release-skill.sh`'s `/tmp/adb-cl-*.$$` files. `$$` differs per check process, so
#     siblings in this pool cannot collide. #250 SETTLED this rather than changed it: its
#     acceptance criterion names `$$` as an acceptable per-run spelling alongside `mktemp`, so
#     these files were never the defect — replacing them would be tidying, not a collision fix,
#     and `scripts/check-tmp-paths.sh` accepts `$$` for exactly this reason.
#   * `check-role-dispatch.sh`'s system-wide `pgrep -f 'sleep 31337'`. Only that one step ever
#     stages such a process, and only one copy of it runs.
#   * the destructive-git fixtures (`check-cleanup.sh`): every one of them operates inside its
#     own `mktemp -d` repo, never this one.
#
# TWO CONCURRENT SELFCHECK RUNS in one checkout are still not supported, and neither #260 nor #250
# made them so: they would both drive `build.sh` over the same TRACKED tree, which no temp-path
# rule can separate. #250 was about run data landing on shared, guessable paths; a tracked working
# tree is neither, so the two never met. Stated here so the omission stays a decision.
PINNED_STEPS=(build-drift)

# THE SECOND SERIAL LANE (#423). `PINNED_STEPS` is a CORRECTNESS rule — build-drift rewrites
# tracked files other steps read. This one is a RELIABILITY rule: these steps assert on signal
# delivery, worker reaping and installer writes, and they fail under pool contention on a
# small-core runner while passing unloaded and on Linux. Two arrays, not one, because a new step
# has to answer a different question to join each. Evidence, alternatives and why `pinned-install`
# is excluded: D87.
ISOLATED_STEPS=(session-currency install-migration install-guard selfcheck-guard selfcheck-guard-mutation install-dry-run)

# lane_of <step> — `serial` if the step runs in the serial prologue, else `pool`. THE one home for
# that decision: the dispatcher's split and `--list`'s third field both call it, so a step can
# never be REPORTED in one lane and DISPATCHED in the other. Two arrays, one answer.
lane_of() {
  local _p
  for _p in "${PINNED_STEPS[@]}" "${ISOLATED_STEPS[@]}"; do
    [ "$1" = "$_p" ] && { printf 'serial\n'; return 0; }
  done
  printf 'pool\n'
}

# lane_reason <step> — WHY it is in that lane: `mutates-tree` (it rewrites tracked files other
# steps read), `load-sensitive` (it asserts on signal timing or installer writes and flaps under
# contention), or `concurrent`. A separate answer from lane_of because the two are separate
# questions, and the one a reader needs when deciding where a NEW step belongs is this one.
lane_reason() {
  local _p
  for _p in "${PINNED_STEPS[@]}";   do [ "$1" = "$_p" ] && { printf 'mutates-tree\n';   return 0; }; done
  for _p in "${ISOLATED_STEPS[@]}"; do [ "$1" = "$_p" ] && { printf 'load-sensitive\n'; return 0; }; done
  printf 'concurrent\n'
}

# Concurrent git against ONE repo, made safe the documented way rather than by hoping. `git diff`
# and friends opportunistically write back a refreshed index, and two of them racing produce
# "Unable to create '.git/index.lock'" — a failure that looks like a broken check and is not.
# GIT_OPTIONAL_LOCKS=0 tells git to skip exactly those optional sub-operations; commands that
# genuinely need the lock (the `git commit`/`git checkout` inside each check's throwaway fixture)
# still take it. Applied per worker, not exported globally, so `--serial` is untouched.

# ==================================== the step registry =======================================
#
# An ordered NAME list plus a name → command map. Both, because an associative array does not
# preserve insertion order and `--serial` must reproduce the declared sequence.
#
# The command is a small word list, run by word-splitting — never `eval`. `add` rejects anything
# carrying shell metacharacters, so the split cannot be surprised by a value this file did not
# write. Multi-statement steps are FUNCTIONS (`step_*` below) and register as a single word.
#
# LINE SHAPE IS LOAD-BEARING, and not for tidiness. `check-fact-drift.sh` pins three of these
# invocations against silent un-wiring, and the bash-floor pin requires the invocation to END the
# command — end of line or a `;`. So the command is written unquoted and last on its line. Quoting
# it ("bash scripts/check-bash-floor.sh") would end the line with a quote and the pin would match
# nothing, which is the failure mode that whole family of rules exists to prevent.
#
# That a record EXISTS is a weaker claim than that it RUNS, and the difference is the point of
# `scripts/check-selfcheck.sh`: it drives this dispatcher over a fixture and proves every
# registered step is executed and that its status reaches the exit code. `--list` exposes the
# registry so a guard can ask the runner rather than grep this file.
declare -a STEP_ORDER=()
declare -A STEP_CMD=()

add() {
  local name="$1"; shift
  # The NAME is a slug, and that is not cosmetic. `--only` splits on commas and `--list` is
  # TAB-delimited, so a name carrying either is unselectable or corrupts the format other guards
  # parse; whitespace and newlines additionally let a name forge an output boundary.
  case "$name" in
    ''|*[!A-Za-z0-9_-]*)
      printf 'selfcheck: FATAL — step name %s is not a [A-Za-z0-9_-] slug\n' "${name:-<empty>}" >&2
      exit 2 ;;
  esac
  [ "$#" -ge 1 ] || { printf 'selfcheck: FATAL — step %s registered with no command\n' "$name" >&2; exit 2; }
  [ -z "${STEP_CMD[$name]+x}" ] || { printf 'selfcheck: FATAL — step %s registered twice\n' "$name" >&2; exit 2; }
  # The values are authored in this file and split on whitespace, so a metacharacter would either
  # glob against the tree or change the command's meaning. Refuse at registration, where the
  # diagnostic names the step, rather than at dispatch, where it would be a mystery. Written as an
  # ALLOWLIST — strip every character a command here may legitimately contain and require nothing
  # to be left — because a denylist of shell metacharacters is exactly the kind of enumeration that
  # ships one character short.
  #
  # JOIN FIRST, then strip. `${*//…}` substitutes into each positional parameter SEPARATELY and
  # joins afterwards, so an element consumed down to nothing leaves bash's internal empty-element
  # marker (0x7F) in the result — every command here would have "failed" validation on a byte that
  # is not in the source. Assigning `$*` to a scalar first makes it one ordinary string.
  local _cmd="$*"
  # An argument COUNT is not a command. `add foo ""` passes the count test, registers, and then
  # `run_step` executes nothing at all and returns 0 — a step that reports PASS having run nothing,
  # which is precisely the silent-no-op this suite exists to make impossible.
  case "$_cmd" in
    *[![:space:]]*) : ;;
    *) printf 'selfcheck: FATAL — step %s registered with an empty command\n' "$name" >&2; exit 2 ;;
  esac
  local _rest="${_cmd//[A-Za-z0-9_.\/ -]/}"
  [ -z "$_rest" ] || {
    printf 'selfcheck: FATAL — step %s: command carries %s outside [A-Za-z0-9_./ -] (%s)\n' \
      "$name" "$_rest" "$_cmd" >&2
    exit 2
  }
  STEP_ORDER+=("$name")
  STEP_CMD["$name"]="$_cmd"
}

# THE INPUT SET OF A STEP (#441) — the paths its VERDICT is a function of. Declared for every
# `*-mutation` step and for nothing else today: a mutation harness re-runs a whole suite once per
# injected defect to prove that suite can go red, and the answer depends on the library it mutates,
# that library's suite, the shared harness (`scripts/check-lib.sh`) and `scripts/lib/common.sh` —
# not on the rest of the tree. A step WITH inputs is dispatched only when the change under test
# touches one of them (see "the gate" below); a step without inputs always runs.
#
# WHAT COUNTS AS AN INPUT is the mutation-specific closure, not everything the suite reads. Several
# suites read `base/` or `agents/` files as fixtures; a change there that breaks the suite breaks
# its PLAIN step, which is never gated. What the mutation harness adds is "can the guard fail?",
# and that is decided by the code it mutates and the code that judges the mutation. So: the harness
# script, the two shared files, every `scripts/lib/*.sh` the suite exercises, the vendored
# `scripts/shmutant.sh` for a suite whose whole-suite pool runs through it (#519), and — for
# `bootstrap-mutation` — the entry-point site set it reverts one at a time. Wrong in the direction
# of listing too much costs minutes; wrong in the other direction costs a day, because the
# scheduled workflow (`.github/workflows/mutation-nightly.yml`) runs every harness unconditionally.
#
# ONE HOME. `scripts/mutation-gate.sh` reads this through `--list` (field 5); `scripts/check-mutation-gate.sh`
# pins that every `*-mutation` step declares inputs naming its own harness plus the two shared
# files (and `scripts/shmutant.sh` where its suite runs `check_shmutant_pool`), that every declared
# path exists, and that the nightly matrix names every step here.
#
# AND ONE HOME FOR THE PER-ROW GATE TOO (#470, D108). A harness built on per-test rows asks the
# same question once more per row, and it asks it of THIS set: a row's inputs are the file that
# row mutates plus every declared input NO row targets. Nothing new is declared here for that —
# adding a sixth `--list` field would break the pin that `--list` carries exactly five — so a step
# whose rows mutate a file it does not declare here refuses gating altogether and names the file,
# which is what keeps this list, rather than the row table, the place the answer comes from.
declare -A STEP_INPUTS=()

inputs() {
  local name="$1" p
  shift
  [ -n "${STEP_CMD[$name]+x}" ] || { printf 'selfcheck: FATAL — inputs for unregistered step %s\n' "$name" >&2; exit 2; }
  [ "$#" -ge 1 ] || { printf 'selfcheck: FATAL — step %s declares an empty input set\n' "$name" >&2; exit 2; }
  [ -z "${STEP_INPUTS[$name]+x}" ] || { printf 'selfcheck: FATAL — inputs for %s declared twice\n' "$name" >&2; exit 2; }
  # Paths only, in the same allowlist the commands use MINUS the space, because `--list` joins
  # them with commas and the gate splits on exactly that: a path carrying a comma, a tab or a
  # space would forge a field boundary or split into two paths that match nothing.
  for p in "$@"; do
    case "$p" in
      ''|*[!A-Za-z0-9_./-]*)
        printf 'selfcheck: FATAL — step %s: input %s is not a [A-Za-z0-9_./-] path\n' "$name" "${p:-<empty>}" >&2
        exit 2 ;;
    esac
  done
  STEP_INPUTS["$name"]="$(IFS=,; printf '%s' "$*")"
}

# ================================ multi-statement steps ========================================
# Everything a step prints is DIAGNOSTIC. The runner owns the `=== name ===` banner and the single
# trailing PASS/FAIL, so these return a status and never print a verdict of their own.

step_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || { echo "SKIP (shellcheck not installed)"; return 0; }
  # Enumerate tracked shell files (+ the extensionless bin/ commands), NUL-delimited end to end, and
  # lint them through the pool the turn-end gate and CI also call (#455): one process per file across
  # `adb_pool_size` workers instead of one process over the whole tree. Its last line names how many
  # files and workers it used.
  git ls-files -z '*.sh' 'bin/agent-init' 'bin/baseline' | bash scripts/shellcheck-pool.sh -0
}

step_build_drift() {
  local bd=0 tree pf
  # Capture the build exit: a malformed source makes build.sh exit non-zero WITHOUT
  # rewriting the already-tracked skill, so the diff-only checks below would still see
  # a clean tree and print PASS. CI's rebuild step fails on that non-zero exit; the
  # local mirror must too, or a broken source passes selfcheck and only fails in CI.
  if ! bash scripts/build.sh >/dev/null; then
    echo "  scripts/build.sh failed — a base/practices or base/workflows source is malformed (see its error above)"
    bd=1
  fi
  # Compare the freshly-built tree against HEAD (committed), not the index — so a
  # partial stage (e.g. staging a generated skill but not its edited source) can't
  # false-pass locally and then fail only in remote CI. This mirrors what CI does
  # (it checks out HEAD, builds, and diffs).
  if ! git diff --quiet HEAD -- agents/claude/CLAUDE.md agents/codex/AGENTS.md agents/gemini/GEMINI.md; then
    echo "  root docs stale — base/practices changed; run scripts/build.sh and commit them"
    bd=1
  fi
  # The procedure trees (#434) render from the same sources as the root docs.
  for tree in agents/claude/rules agents/claude/reference agents/codex/reference agents/gemini/reference; do
    if ! git diff --quiet HEAD -- "$tree"; then
      echo "  procedures stale ($tree) — base/practices changed; run scripts/build.sh and commit them"
      bd=1
    fi
    if [ -n "$(git ls-files --others --exclude-standard -- "$tree")" ]; then
      echo "  rendered procedure(s) not committed ($tree) — run scripts/build.sh and 'git add' the result:"
      git ls-files --others --exclude-standard -- "$tree" | sed 's/^/    /'
      bd=1
    fi
    # Gitignore-immune: `--others` respects .gitignore, so an ignored rendered procedure needs this.
    for pf in "$tree"/*.md; do
      [ -e "$pf" ] || continue
      if ! git ls-files --error-unmatch -- "$pf" >/dev/null 2>&1; then
        echo "  $pf exists but is not git-tracked (untracked or gitignored) — run scripts/build.sh and commit it"
        bd=1
      fi
    done
  done
  # Every agent's rendered skills tree (Claude, Codex, Gemini) is regenerated from the
  # same base/workflows sources, so a stale/uncommitted render in ANY of them is drift.
  for tree in agents/claude/skills agents/codex/skills agents/gemini/skills; do
    if ! git diff --quiet HEAD -- "$tree"; then
      echo "  generated skills stale ($tree) — base/workflows changed; run scripts/build.sh and commit them"
      bd=1
    fi
    # git diff HEAD is blind to untracked files; catch a rendered-but-uncommitted skill.
    # (An ignored one won't show here — the workflow-map tracked-check covers that.)
    if [ -n "$(git ls-files --others --exclude-standard -- "$tree")" ]; then
      echo "  rendered skill(s) not committed ($tree) — run scripts/build.sh and 'git add' the result:"
      git ls-files --others --exclude-standard -- "$tree" | sed 's/^/    /'
      bd=1
    fi
  done
  return "$bd"
}

step_workflow_map() {
  # 1:1 between base/workflows/<name>.md (the source) and its rendered skill FOR EVERY AGENT,
  # so a workflow can't lose a skill and a skill can't orphan when its source is removed.
  local wm=0 agent wf n sk
  for agent in claude codex gemini; do
    for wf in base/workflows/*.md; do
      [ -f "$wf" ] || continue
      n="$(basename "$wf" .md)"
      [ "$n" = README ] && continue
      sk="agents/$agent/skills/$n/SKILL.md"
      if [ ! -f "$sk" ]; then
        echo "  base/workflows/$n.md → no rendered $agent skill"; wm=1
      elif ! git ls-files --error-unmatch "$sk" >/dev/null 2>&1; then
        # Tracked-check is gitignore-immune: git ls-files --others (above) respects
        # .gitignore, so a rendered skill under an ignored path would slip past it.
        echo "  $sk is not git-tracked (untracked or gitignored) — run scripts/build.sh and 'git add' it"; wm=1
      fi
    done
    for sk in agents/"$agent"/skills/*/SKILL.md; do
      [ -f "$sk" ] || continue
      n="$(basename "$(dirname "$sk")")"
      [ -f "base/workflows/$n.md" ] || { echo "  $agent skill '$n' → no base/workflows/$n.md source (orphan)"; wm=1; }
    done
    # Supporting files (#433): base/workflows/<n>/<f>.md ↔ agents/<agent>/skills/<n>/<f>, both
    # directions, tracked — the same 1:1 the SKILL.md halves above get, or a reference file can
    # silently stop rendering (forward) or orphan when its source is removed (reverse).
    for wf in base/workflows/*/*.md; do
      [ -f "$wf" ] || continue
      n="$(basename "$(dirname "$wf")")"
      sk="agents/$agent/skills/$n/$(basename "$wf")"
      if [ ! -f "$sk" ]; then
        echo "  $wf → no rendered $agent supporting file"; wm=1
      elif ! git ls-files --error-unmatch "$sk" >/dev/null 2>&1; then
        echo "  $sk is not git-tracked (untracked or gitignored) — run scripts/build.sh and 'git add' it"; wm=1
      fi
    done
    for sk in agents/"$agent"/skills/*/*.md; do
      [ -f "$sk" ] || continue
      case "$(basename "$sk")" in SKILL.md) continue ;; esac
      n="$(basename "$(dirname "$sk")")"
      [ -f "base/workflows/$n/$(basename "$sk")" ] \
        || { echo "  $agent supporting file '$n/$(basename "$sk")' → no base/workflows source (orphan)"; wm=1; }
    done
  done
  return "$wm"
}

step_skill_frontmatter() {
  # Required frontmatter keys are agent-specific: every SKILL.md needs name + description;
  # only Claude's skill loader also requires user-invocable (Codex/Antigravity honor only
  # name + description — see base/workflows/README.md).
  local ff=0 agent keys f k
  for agent in claude codex gemini; do
    case "$agent" in
      claude) keys='name: description: user-invocable:' ;;
      *)      keys='name: description:' ;;
    esac
    for f in agents/"$agent"/skills/*/SKILL.md; do
      [ -f "$f" ] || continue
      head -n1 "$f" | grep -q '^---$' || { echo "  ${f}: no frontmatter"; ff=1; continue; }
      for k in $keys; do
        head -n 20 "$f" | grep -q "^${k}" || { echo "  ${f}: missing ${k}"; ff=1; }
      done
    done
  done
  return "$ff"
}

step_gate_detector() {
  # The empty-ecosystem no-op (detect on a dir with no toolchain and no agents.toml emits
  # nothing) is covered generically by check-gates.sh — run in the "gates" step below — so it
  # isn't repeated here. This step asserts only what is specific to THIS repo: repo-root
  # detection surfaces the committed agents.toml [gates] override (#7), so CI keeps exercising
  # the dogfooded manifest. Records are TAB-delimited "<label>\t<command>".
  local gd=0 want_gate got_gate
  want_gate="$(printf 'test\tbash scripts/selfcheck.sh')"
  got_gate="$(bash scripts/lib/project-gates.sh detect . 2>/dev/null)"   # compare stdout only
  if [ "$got_gate" = "$want_gate" ]; then
    echo "  repo-root detect emits the committed test gate"
  else
    echo "  repo-root detect: got '$got_gate' want '$want_gate'"; gd=1
  fi
  if bash scripts/lib/project-gates.sh badcmd >/dev/null 2>&1; then
    echo "  badcmd exited 0"; gd=1
  else
    echo "  badcmd errors"
  fi
  return "$gd"
}

step_install_dry_run() {
  local FAKE ok=1 log
  # UNDER THE RUNNER'S SCRATCH DIR, not a free-standing mktemp. This step is the only one that
  # builds a whole fake HOME, and cancellation kills the worker outright — `rm -rf "$FAKE"` at the
  # bottom never runs, so an independent temp dir survives the run that made it. Rooting it in
  # $WORK hands it to the EXIT trap, which removes the tree whatever happens. The fallback keeps
  # the function callable outside the runner.
  FAKE="$(mktemp -d "${WORK:-${TMPDIR:-/tmp}}/dryrun.XXXXXX")" || return 1
  # The log lives in this run's own scratch dir, not at a fixed /tmp path, and its contents are
  # printed INTO this step's output on failure. A fixed path was two problems: a second selfcheck
  # in another checkout clobbered it (#250's class), and "see /tmp/adb-selfcheck.log" is not an
  # attributable failure — it is a pointer to a file the reader has to go find, and under the pool
  # it would be the one part of the step's story that did not arrive with the rest of it.
  log="$FAKE/install.log"
  # Install all three agents so codex/gemini adapter paths (which now source common.sh)
  # are exercised too, not just Claude's inline install path.
  HOME="$FAKE" bash install.sh --agent claude --agent codex --agent gemini >"$log" 2>&1 || ok=0
  [ -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
  [ -L "$FAKE/.claude/skills/implement-issue" ] || ok=0
  [ -e "$FAKE/.claude/scripts/lib/project-gates.sh" ] || ok=0
  [ -e "$FAKE/.claude/scripts/lib/common.sh" ] || ok=0
  # The role-dispatch helper rides the same scripts/lib symlink into every agent home (#15).
  [ -e "$FAKE/.claude/scripts/lib/role-dispatch.sh" ] || ok=0
  [ -e "$FAKE/.codex/scripts/lib/role-dispatch.sh" ] || ok=0
  [ -e "$FAKE/.gemini/scripts/lib/role-dispatch.sh" ] || ok=0
  # The skill-override composer rides the same scripts/lib symlink (#22).
  [ -e "$FAKE/.claude/scripts/lib/skill-compose.sh" ] || ok=0
  # /cleanup's predicates ride it too — and must resolve for EVERY agent, since the rendered
  # {{CLEANUP_LIB}} step points each agent's skill at its own copy of the path (#106/#84).
  [ -e "$FAKE/.claude/scripts/lib/cleanup-lib.sh" ] || ok=0
  [ -e "$FAKE/.codex/scripts/lib/cleanup-lib.sh" ] || ok=0
  [ -e "$FAKE/.gemini/scripts/lib/cleanup-lib.sh" ] || ok=0
  [ -L "$FAKE/.codex/AGENTS.md" ] || ok=0
  # Codex + Gemini now also install rendered workflow skills and the shared gate runner
  # (Gemini's skills under its ~/.gemini/config/ customization root).
  [ -L "$FAKE/.codex/skills/implement-issue" ] || ok=0
  [ -e "$FAKE/.codex/scripts/lib/project-gates.sh" ] || ok=0
  [ -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
  [ -L "$FAKE/.gemini/config/skills/implement-issue" ] || ok=0
  [ -e "$FAKE/.gemini/scripts/lib/project-gates.sh" ] || ok=0
  grep -q 'precommit-gate.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
  # The SessionStart currency hook is both LINKED and WIRED (#36) — a manifest entry with no
  # settings entry (or the reverse) would leave the feature silently inert.
  [ -L "$FAKE/.claude/scripts/session-currency.sh" ] || ok=0
  grep -q 'session-currency.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
  # ...and so is the SessionStart run-state hook (#431), plus the library it reads through.
  [ -L "$FAKE/.claude/scripts/session-context.sh" ] || ok=0
  grep -q 'session-context.sh' "$FAKE/.claude/settings.json" 2>/dev/null || ok=0
  [ -e "$FAKE/.claude/scripts/lib/run-state.sh" ] || ok=0
  # Every agent's procedure bundle, and Claude's path-scoped rules (#434) — each a directory link.
  [ -L "$FAKE/.claude/rules/ai-dev-baseline" ] || ok=0
  [ -e "$FAKE/.claude/rules/ai-dev-baseline/shell.md" ] || ok=0
  [ -e "$FAKE/.claude/ai-dev-baseline/reference/git-and-prs.md" ] || ok=0
  [ -e "$FAKE/.codex/ai-dev-baseline/reference/shell.md" ] || ok=0
  [ -e "$FAKE/.gemini/ai-dev-baseline/reference/shell.md" ] || ok=0
  HOME="$FAKE" bash uninstall.sh --agent claude --agent codex --agent gemini >>"$log" 2>&1 || ok=0
  [ ! -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
  [ ! -L "$FAKE/.claude/scripts/session-currency.sh" ] || ok=0
  # A leftover SessionStart entry pointing at a removed script would error on EVERY future session.
  grep -q 'session-currency.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok=0
  [ ! -L "$FAKE/.claude/scripts/session-context.sh" ] || ok=0
  grep -q 'session-context.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok=0
  [ ! -L "$FAKE/.codex/AGENTS.md" ] || ok=0
  [ ! -L "$FAKE/.codex/skills/implement-issue" ] || ok=0
  [ ! -L "$FAKE/.gemini/GEMINI.md" ] || ok=0
  [ ! -L "$FAKE/.gemini/config/skills/implement-issue" ] || ok=0
  [ ! -L "$FAKE/.claude/rules/ai-dev-baseline" ] || ok=0
  [ ! -L "$FAKE/.claude/ai-dev-baseline/reference" ] || ok=0
  [ ! -L "$FAKE/.codex/ai-dev-baseline/reference" ] || ok=0
  [ ! -L "$FAKE/.gemini/ai-dev-baseline/reference" ] || ok=0
  [ "$ok" -eq 1 ] || { echo "  installer log:"; sed 's/^/    /' "$log"; }
  rm -rf "$FAKE"
  [ "$ok" -eq 1 ]
}

# ===================================== the registry ============================================
# Declaration order. `--serial` runs exactly this sequence; the pool dispatches in it and emits in
# completion order (see `run_pool`).

add shellcheck          step_shellcheck

add build-drift         step_build_drift

# `build-drift` proves the generated artifacts MATCH what build.sh renders; it says nothing about
# HOW they are written, because a successful build is exactly where the two write shapes are
# indistinguishable — and it cannot inject a failure, since it runs against the tracked tree it is
# checking. This runs a copied build.sh in a `mktemp -d` fixture, faults it mid-render, and requires
# the destination to survive byte-exact (#268). POOLED: it never touches this checkout.
add build-atomic        bash scripts/check-build-atomic.sh

add workflow-map        step_workflow_map

add skill-frontmatter   step_skill_frontmatter

# The body-placeholder substitution behind the Claude skill render (#16): every neutral
# {{PLACEHOLDER}} maps to its Claude token, substitution is body-only, an unmapped token
# fails loud, and no committed skill ships an unresolved placeholder.
add workflow-render     bash scripts/check-workflow-render.sh

# The OTHER thing the renderers now do per agent (#304): resolve `<!-- adb:except … -->` blocks, so
# one source can carry a different verification-instruction DENSITY for each agent. Its own suite
# because build-drift structurally cannot see this class — it agrees with whatever was committed,
# so a facility that silently varies nothing, and a shared paragraph reworded in one render only,
# both look exactly like a clean build. Three hand-written oracle sources make "differs there,
# byte-identical everywhere else" a `cmp`, on BOTH render paths, and five mutations of a copied
# build.sh are each required to make a named assertion go red.
add agent-blocks        bash scripts/check-agent-blocks.sh

# A practice's two render classes (#434): its rule lines are exactly its root-doc section, its
# procedure lines exactly one procedure file per agent, and each pointer names the path the install
# manifest links. build-drift agrees with whatever was committed, so a split that lost or doubled a
# paragraph would pass it. `--self-test` drives the marker grammar red and mutates copies of the
# outputs, requiring the verifier red on each.
add practice-split      bash scripts/check-practice-split.sh --self-test

# What the rendered artifacts COST to load (#359). A report, not a gate: it fails only on
# mechanics — an expected artifact missing, unreadable or zero-byte — and never on size, because
# the owner rejected caps (2026-08-15). Registered so the numbers land in every run's log; the
# per-PR DELTA (#432, `--since` the merge-base) is the `render-size` CI job's summary step, and this
# row stays ref-free so it never depends on history a checkout may lack.
add render-size         bash scripts/render-size.sh

# ...and its one failing arm is a guard, so it gets what guards get here: the mechanical rules
# driven RED against fixture trees under a `mktemp -d`, plus the direction it must never fail in —
# an arbitrarily large artifact still exits 0 — and, since #432, both new measurements observed
# failing on a mutated copy, in throwaway git repositories of its own.
add render-size-guard   bash scripts/check-render-size.sh

# A fenced ```bash block in base/workflows/*.md is executed for real, but the linter above only
# sees tracked *.sh files — never a workflow body. This catches the one class that is both
# invisible there and destructive: assigning a zsh-special name. `path` IS $PATH, so
# `read -r kind path key` emptied the search path mid-sweep and made /cleanup a silent no-op on
# macOS (#126). (This comment deliberately does not start a line with the linter's own name —
# that reads as a directive and fails the parse.)
add workflow-shell      bash scripts/check-workflow-shell.sh

# Third-party text (issue bodies, review threads, CI logs, vendor changelogs) drives these
# workflows, and one of them hands it to a second agent with repo tool access at two sites
# (#214 — /implement-issue steps 3 and 8). Two halves:
# a red-team over the containment envelope (a body carrying a closing tag, a quote or a newline
# must round-trip as one JSON value and cannot break out), and a source contract asserting every
# workflow that reads such text labels the read and that every workflow is classified. Its own
# mutation harness proves the lint can go red rather than matching nothing.
add injection           bash scripts/check-injection.sh

# Run data may not land on a fixed, host-shared path (#250). /implement-issue's issue snapshot —
# the untrusted body plus the `author_association` trust label — sat at a name derived from a
# public issue number in a world-writable directory, written in step 2 and read back in steps 3
# and 8. Two halves, each with a mutation harness: the snapshot's path resolves per CHECKOUT
# (asserted by resolving the real markdown expression under two roots, in the source and in every
# render), and no fixed shared-temp literal survives anywhere the four scanned roots reach.
add tmp-paths           bash scripts/check-tmp-paths.sh

add gate-detector       step_gate_detector

# Full behavior tests for the gate model (detection, open set, N/A, path scope).
add gates               bash scripts/check-gates.sh

# Unit tests for the shared shell primitives (scripts/lib/common.sh), incl. adb_repo_shape (#23).
add common-lib          bash scripts/check-common-lib.sh

# ...and the install-manifest guards are guards, so each is injected with its own defect and must go
# red ON ITS OWN NAMED WITNESS (#324). Red for the wrong reason is not evidence, and a mutation whose
# edit silently fails to apply reports itself observed while checking nothing.
add common-lib-mutation bash scripts/check-common-lib.sh --mutation
inputs common-lib-mutation      scripts/check-common-lib.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/role-dispatch.sh install.sh uninstall.sh bin/agent-init bin/baseline

# The shared mutation harness's blocks and per-test rows (#468): selection and its dependency closure,
# every declaration refusal, preflight before any copy is built, each block's unmutated control, and
# the verdict taxonomy, all driven over a throwaway fixture suite.
add block-rows          bash scripts/check-block-rows.sh

# Integration tests for bin/agent-init's repo-shape tolerance: subdir resolution, bama-style
# untracked-parent + out-of-repo doc surfacing, nested repos, non-git refusal (#23).
add agent-init          bash scripts/check-agent-init.sh

# Unit tests for the runtime role-dispatch helper (resolve/bots/invoke + validation, #15).
add role-dispatch       bash scripts/check-role-dispatch.sh

# Unit tests for the pre-arm review guard (scripts/lib/pr-review.sh, #134): reviewer-identity
# matching across the REST/GraphQL `[bot]` spelling split, head-SHA freshness, the declaration
# tri-state, and every unreadable path failing closed.
add pr-review           bash scripts/check-pr-review.sh

# Unit tests for the async-reviewer status detector (scripts/lib/pr-watch.sh, #49): the two
# terminal signals (a `+1` reaction = clean, a review at head = findings), the staleness rule that
# stops a reaction left on an earlier head from reading as a pass, the declaration tri-state, every
# unreadable path failing closed, the bounded wait actually honouring its bound, and the head's CI
# read (#448) — never green on doubt, and never moving the reviewer verdict.
add pr-watch            bash scripts/check-pr-watch.sh

# The negative half of the step above, for the bounded-wait cases (#394), #447's pair rule and the
# head-CI read (#448). The wait cases are the ones whose green means nothing on its own: the
# reported defect was a case that reached its `rc` assertion after one poll, with the message it
# exists to assert never printed. Whole-suite pools for the wait loop, the staleness rule it
# delegates to and the `+1`/comment pairing, then per-test rows (#468) for the CI read, each
# running only its block — every row required back RED on ITS OWN named witness, so "these cases
# can fire" is re-runnable rather than a claim in a PR body. The count is printed by the run.
add pr-watch-mutation   bash scripts/check-pr-watch.sh --mutation
inputs pr-watch-mutation        scripts/check-pr-watch.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/pr-watch.sh scripts/lib/role-dispatch.sh scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh scripts/mutation-gate.sh scripts/selfcheck.sh

# Unit tests for the /resolve-pr-threads decision predicates (scripts/lib/pr-threads.sh, #416/#418):
# argument-less PR inference refusing rather than guessing, the COMPLETE thread enumeration across a
# cursor, and the completeness proof that makes a short read loud instead of letting it report
# "0 remaining".
add pr-threads          bash scripts/check-pr-threads.sh

# The negative half of the step above (#418). Its cases are guards, and a guard's failure mode is
# silence: the shipped defect was a `first:50` read whose own remaining-count check shared the
# truncating window, so it printed exactly what a clean run prints. The mutations — the cursor loop
# stopped, the cursor never sent, the count proof disabled, the count proof disabled against #418's
# OWN resolved-page/unresolved-overflow shape, the distinct-id proof disabled, the per-node type
# check disabled, and (#437) `list` printing the whole document by default, an unwritable `--out`
# falling back to stdout, `--out` publishing without `--strict`, its stage written by path rather
# than through the held descriptor, and `--verbose`'s write status dropped — plus an unmutated
# control, each required back RED on ITS OWN witness.
add pr-threads-mutation bash scripts/check-pr-threads.sh --mutation
inputs pr-threads-mutation      scripts/check-pr-threads.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/pr-threads.sh scripts/lib/role-dispatch.sh base/workflows/resolve-pr-threads.md

# Unit tests for the atomic observe-and-render helper (scripts/lib/state-assert.sh, #138):
# mergedAt-over-state, NOT_PLANNED kept distinct, every unverifiable path rendering NO sentence,
# argument validation, and the three narrating workflows' wiring to it.
add state-assert        bash scripts/check-state-assert.sh

# Unit tests for the partial skill override composer (scripts/lib/skill-compose.sh, #22):
# ops, anchor slugging, inherit-on-recompose, byte-exact currency check, and the safety guards.
add skill-compose       bash scripts/check-skill-compose.sh

# Unit tests for the pattern ledger (scripts/lib/pattern-ledger.sh, #421): the threshold boundary
# from both sides, exactly-once keyed on the review thread, and a damaged ledger refused WHOLE by
# every reader — including `checklist`, whose own region can be intact while the hits region is
# not. Also pins the containment property that makes the ledger safe to feed forward: the one
# subcommand whose output reaches a prompt emits maintainer-merged rules and no reviewer text.
add pattern-ledger      bash scripts/check-pattern-ledger.sh

# The negative half of the step above. The ledger's dangerous direction is reporting a class as
# RARER than it is — a count too low leaves a recurring defect unpromoted and looks exactly like a
# class nobody hit twice. Every row is required back RED on its OWN witness, covering the counting
# rules (the threshold comparison, dedupe, the record and checklist grammars, the region-
# completeness proof), the containment of reviewer text at the prompt surface, and the write lock
# (its ordering, its ownership on release, and its refusal to reclaim from a live owner).
#
# NO TOTAL IS QUOTED HERE, deliberately. This comment named eight while the suite registered
# twenty-nine — a number that drifts every time a witness is added, and which understates the
# coverage it claims to describe. `--mutation` prints the live count on every run; that output is
# current where a number written here is only as current as its last edit.
add pattern-ledger-mutation bash scripts/check-pattern-ledger.sh --mutation
inputs pattern-ledger-mutation  scripts/check-pattern-ledger.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/pattern-ledger.sh scripts/lib/adopt-lib.sh scripts/lib/implement-lib.sh scripts/lib/cleanup-lib.sh scripts/lib/run-state.sh base/workflows/implement-issue.md base/workflows/resolve-pr-threads.md base/practices/issues-and-scope.md scripts/mutation-gate.sh scripts/selfcheck.sh

# Unit tests for the vendor-documentation duty (scripts/lib/docs-lib.sh, #422): `[mcp] required`
# finally has a consumer, and its dangerous direction is a CLEAN verdict nobody earned. Drives the
# degraded-server case from three directions and asserts the fail-closed rule that silence
# adjudicates exactly as failure. What it deliberately does NOT claim to test is that the agent
# really issued the query. A shell CAN reach MCP indirectly — `claude -p` takes `--mcp-config`, so a
# headless agent can be launched to test a server's PRESENT usability — and D90 says so explicitly.
# What no gate can do is authenticate the HISTORICAL action another agent recorded, which is the
# boundary this suite tests up to. The retired stronger claim is not restated here, because reading
# it as current would misdirect the next attempt at a preflight.
add docs-lib            bash scripts/check-docs-lib.sh

# The negative half. Every row required back RED on its own witness; the two that matter most are
# silence adjudicating as clean, and a degraded probe ignored — both would restore the silent
# fall-back to training-data recall that the declaration exists to end. The live count is printed by
# `--mutation` itself rather than written here, for the reason the step above gives.
add docs-lib-mutation   bash scripts/check-docs-lib.sh --mutation
inputs docs-lib-mutation        scripts/check-docs-lib.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/docs-lib.sh scripts/lib/cleanup-lib.sh scripts/lib/implement-lib.sh base/workflows/implement-issue.md base/practices/third-party-claims.md templates/agents.toml

# Behavioral tests for the /cleanup decision predicates (scripts/lib/cleanup-lib.sh): squash-merge
# detection against a real fixture (#106 — `--merged` alone is blind to it, so the sweep was a
# permanent no-op), the destructive refusals (a branch that gained commits after its merge; state
# for an open PR or an in-flight run), and the terse output contract (#84). Also home of the #38
# remote-enumeration regression since #372 retired check-cleanup-enum.sh. Offline.
add cleanup             bash scripts/check-cleanup.sh

# Behavioral tests for the /adopt decision predicates (scripts/lib/adopt-lib.sh, #20): the
# keep/remove/move/escalate classifier, tested from the side that costs something — a prescribed
# home that COLLIDES with a baseline artifact must be `keep` (reverse those two arms and every
# adopting project is told to delete its own precommit-gate policy), and a colliding artifact that
# DIFFERS must be `move`, never `remove`. Plus the six hygiene axes, the role-inference "cannot
# infer" result, a proposal that renders every template section and infers `[reviewers]` only from
# a READ history (#459), the interview's answers, `pin-describe`'s one-object version (#464), the
# pin's validation and round-trip, the workflow's own propose/interview/hygiene/pin blocks EXECUTED,
# and a byte-level assertion that no read-only subcommand alters the project it scanned. Offline;
# every fixture is a mktemp -d tree.
add adopt               bash scripts/check-adopt.sh

# ...and that suite is a guard, so it gets what guards get here: every load-bearing decision in
# adopt-lib.sh is injected with its own defect in a TREE COPY, and the suite must come back red ON
# ITS OWN NAMED ASSERTION. A mutation that goes red for the wrong reason is not evidence, so the
# witness is matched against the failure text (#213's `fires:` contract). This replaces a commit
# message's claim that mutations "were observed" with something the repo can re-run.
add adopt-mutation      bash scripts/check-adopt.sh --mutation
inputs adopt-mutation           scripts/check-adopt.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/adopt-lib.sh scripts/lib/role-dispatch.sh scripts/lib/project-gates.sh base/workflows/adopt.md base/practices/handling-the-unknown.md templates/agents.toml agents install.sh uninstall.sh

# The ADOPTION COMPLETION CONTRACT and its verifier (scripts/lib/adopt-readiness.sh, #81) — the
# question /adopt's scan does not answer: is this project now ready to RUN the loop? A verifier's
# failure mode is silence (it passes green having checked nothing), so the suite drives every one
# of the contract's rungs to every result class and asserts a NAMED verdict word and exit code for
# each, plus the fail-closed core: empty stdin, a rung nobody reported, an unknown status, a
# duplicate and a malformed fact must every one of them be NON-green. Offline — `probe` reads the
# filesystem and `tracker` reads a JSON object the caller assembled, which is exactly why the two
# live reads (`facts`, `observe`) are subcommands of their own, driven here through a stubbed gh.
add adopt-readiness     bash scripts/check-adopt-readiness.sh

# ...and the same guards-get-mutated rule, for the same reason: every defect in its table (the count
# is printed by `--mutation`, never quoted here, because a quoted count goes stale), each injected
# into a TREE COPY, each required to make the suite red ON ITS OWN NAMED ASSERTION. Two of them
# are regressions of real fail-OPEN bugs this suite caught while it was being written (a gate
# count that grepped a display string, and a jq filter whose failure was swallowed into "every
# milestone is dispositioned").
add adopt-readiness-mutation bash scripts/check-adopt-readiness.sh --mutation
inputs adopt-readiness-mutation scripts/check-adopt-readiness.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/adopt-readiness.sh scripts/lib/adopt-lib.sh scripts/lib/project-gates.sh scripts/lib/role-dispatch.sh scripts/lib/repo-settings.sh scripts/lib/roadmap-lib.sh base/workflows/adopt.md bin/baseline agents/claude/settings.hooks.json

# Behavioral tests for the /roadmap decision predicates (scripts/lib/roadmap-lib.sh): in-flight
# targeting (#69 — a bare `Refs #N` must never freeze a ready member) and release readiness
# (#71), plus a drift guard that the workflow still delegates to them (#45). Offline.
add roadmap             bash scripts/check-roadmap.sh

# Mocked-gh harness (#75): EXECUTES the workflow's documented snippets against a stub gh, so a
# fenced command that no longer runs is a test failure rather than a surprise at /roadmap time.
# Covers artifact location, the paginated adopt scan, the completeness + in-flight fresh read,
# the readiness pipeline, the gauge, and decision durability. Offline.
add roadmap-e2e         bash scripts/check-roadmap-e2e.sh

# Offline tests for the CI-run classifier (scripts/lib/ci-health.sh, #300): did this run actually
# EXECUTE? Drives the guard over the RECORDED payloads of the real 2026-08-06 outage run and of a
# real red run of this repo's own CI, exhausts the truth table through the pure arm, exercises the
# live arm against a stub gh, and applies three mutations to a COPY of scripts/lib that each have
# to make an assertion go red. Offline: every payload is frozen, so no live run and no provider
# status page is contacted.
add ci-health           bash scripts/check-ci-health.sh

# Offline unit tests for the release-goal convention helper (scripts/lib/release-convention.sh,
# #27): dispatch, arg-parsing, usage, and the fail-loud gh guard before any gh call.
add release-convention  bash scripts/check-release-convention.sh

# Offline tests for the repo-settings contract (scripts/lib/repo-settings.sh, #87): CI-check
# discovery (the `on:` block sits at the same indent as job keys — harvesting it would require
# contexts that can never report and deadlock every PR), the load-bearing write order (required
# checks strictly before allow_auto_merge), the narrow-vs-destructive endpoint choice, and the
# automerge-ok exit-code table the workflow's step 10 consumes.
add repo-settings       bash scripts/check-repo-settings.sh

# Two static halves in one invocation. Every CI job must sit on a runner PROVEN to carry bash >=
# 5.3 and must wire the runtime guard that says which interpreter it actually got (#257); and
# every shebang-bearing entry point must call adb_require_bash, so a new script cannot join the
# suite without gating its own interpreter (#256). Rides beside repo-settings here because it
# rides that job in CI, and for the same reason: it is the other lint that reads
# .github/workflows/ci.yml.
#
# The RUNTIME half is still not run here, and the reason has changed since #256 landed. It is no
# longer "so a contributor on 5.2 can run selfcheck" — they cannot, because this very script now
# gates its own interpreter on line 1 and would have exited before reaching any step. It is that
# --runtime asserts on the machine and on `command -v bash`, which is a CI-image question; the
# entry gate has already settled the only part that governs whether this suite may run at all.
#
# Since #310 the bare form carries a THIRD half — `--sub-floor`, which proves the three files that
# must stay evaluable BELOW the floor (D30/D35) actually do. It rides here rather than taking a step
# of its own precisely so it reaches macOS: this suite is what `selfcheck-macos` runs, and that job
# is the only per-PR environment with a real 3.2.57 to parse against. On Linux it states a SKIP.
#
# The SKIP covers the parse and the evaluation probe ONLY. Since #315 that half carries two source
# scans — one for 5.3 command substitutions, one for D30's other four named constructs — and neither
# needs an interpreter, so both run here on every platform.
#
# The bare invocation, ENDING the line, is what check-fact-drift.sh's `bash-entrypoint-lint-wired`
# pin requires — see the registry header above on why these lines are unquoted.
add bash-floor          bash scripts/check-bash-floor.sh

# ...and that lint is a guard, so it gets the treatment guards get here: every rule driven to RED
# against throwaway fixtures. A workflow scanner that quietly stops recognizing job keys reports
# exactly what a clean repo reports, and no other check in this suite would notice.
add bash-floor-guard    bash scripts/check-bash-floor-guard.sh

# The vendored mutation harness (#519, D125) is a third-party file pinned by digest and never edited
# here: this fails when scripts/shmutant.sh stops matching scripts/shmutant.sh.sha256, and drives each
# rule of that check red on copies (a one-byte edit among them). Seconds, in one `mktemp -d`.
add shmutant-pin        bash scripts/check-shmutant-pin.sh --self-test

# End-to-end tests for bin/baseline's currency classification (safety-critical: it
# must never fast-forward over dirty/ahead/diverged/detached/non-default state).
add baseline            bash scripts/check-baseline.sh

# The SessionStart currency hook (#36) must act ONLY on a genuinely new session, never touch the
# clone the session is working in, refuse unsafe clone state by name, and always exit 0 — a
# non-zero SessionStart hook renders an error notice on every start.
add session-currency    bash scripts/check-session-currency.sh

# The Stop-hook quality gate must FAIL LOUD (never silently no-op) when its own shared
# library is missing — a broken install is enforcement secretly off (#35).
add precommit-gate      bash scripts/check-precommit-gate.sh

# The implement-issue Stop hook must re-verify PR state LIVE and fail closed — never trust a
# stored prUrl over a PR that was closed without merging (#44). Since #202 it also owns the
# end-to-end case: a second session's admission attempt must leave run A's marker enforcing.
add implement-gate      bash scripts/check-implement-gate.sh

# Run admission (#202): a second /implement-issue run in one checkout is REFUSED, the claim is
# acquired with O_EXCL before anything is deleted, and every unknown fails closed WITHOUT
# deleting. The failure mode is a wrongly-successful start, so every case asserts what survived,
# not just the exit code.
add implement-lib       bash scripts/check-implement-lib.sh

# The local convergence loop (#491): `implement-lib.sh review-loop`, the `local-passes` budget
# reader, `dispatch-review --local-head`, and the prose that drives them. Its dangerous direction is
# a FALSE CONVERGED — fix code pushed as reviewed when no review read it — so a failed pass, a moved
# tree, an edit after a clean pass, a reused reply and an under-carried exhaustion must each refuse.
add review-loop         bash scripts/check-review-loop.sh

# ...and each of those refusals is injected with its own defect and required RED on its own witness.
add review-loop-mutation bash scripts/check-review-loop.sh --mutation
inputs review-loop-mutation     scripts/check-review-loop.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/lib/implement-lib.sh scripts/lib/role-dispatch.sh scripts/lib/cleanup-lib.sh scripts/lib/run-state.sh base/workflows/implement-issue.md base/workflows/resolve-pr-threads.md templates/agents.toml

# The SessionStart run-state hook and its library (#431): a compacted or resumed session gets the
# in-flight run's facts read back — phase, phase history, branch, issue numbers, artifact paths,
# REQUIRED-mark count — and NEVER an issue's or a finding's text. Owner-scoped exactly as the Stop
# gate is; acts on `compact` and `resume` only; exits 0 on every path. Also executes the workflow's
# real phase-update snippet against a fixture marker (#243's append-only phaseHistory).
add session-context     bash scripts/check-session-context.sh

# ...and the guards in it are guards, so each is injected with its own defect and required RED on
# its own witness: the owner check, the source gate, the whole-record refusal, the containment of
# the injected fields, the REQUIRED count, and the workflow snippet's history append. Per-block
# since #445: each row runs only the block that holds its witness (D103), and is gated on its own
# target (D108).
add session-context-mutation bash scripts/check-session-context.sh --mutation
inputs session-context-mutation scripts/check-session-context.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/cleanup-lib.sh scripts/lib/implement-lib.sh scripts/lib/run-state.sh agents/claude/scripts/session-context.sh agents/claude/scripts/implement-issue-gate.sh agents/claude/settings.hooks.json base/workflows/implement-issue.md scripts/mutation-gate.sh scripts/selfcheck.sh

# The installer's SECOND settings surface (#248): which leaves of ~/.claude/settings.json does it
# own, and what does it do to one it does not? Drives the merge's five verdicts, the receipt's four
# dispositions, the version probe against a stub CLI, and the real install.sh/uninstall.sh over a
# fake HOME.
add settings-fragment   bash scripts/check-settings-fragment.sh

# ...and every one of those rules is a guard over a file the operator also writes, so the failure
# mode is a settings.json that looks right and has quietly eaten somebody's own key. Each rule is
# broken in a COPY — of the library, of the payload, of install.sh — and required RED on its own
# witness.
add settings-fragment-mutation bash scripts/check-settings-fragment.sh --mutation
inputs settings-fragment-mutation scripts/check-settings-fragment.sh scripts/check-lib.sh scripts/lib/common.sh agents/claude/settings.fragment.json install.sh uninstall.sh bin/baseline scripts/lib/pinned-install.sh scripts/lib/currency-lib.sh scripts/mutation-gate.sh scripts/selfcheck.sh

# A plain `git pull` must never dangle an installed symlink: install the merge-base, simulate
# a pull to HEAD, and require every installed link to still resolve (#35).
add install-migration   bash scripts/check-install-migration.sh

# adb_link's fail-loud source guard must thread through install.sh: a missing manifest source
# makes the real installer exit non-zero, never dangling a link or disturbing a real dest (#48).
add install-guard       bash scripts/check-install-guard.sh

# Every entry point locates its own clone root BEFORE it can source common.sh, and `$(…)` strips
# every trailing newline — so an unsentinelled capture shortens a clone named `clone<NL>` onto an
# existing sibling, and the entry point sources, links and verifies against the WRONG tree (#343,
# D82). This pins the declared site set plus an open-world scan for the defect in UNdeclared files,
# the byte-identity of the shared block (a bootstrap cannot source the library whose location it is
# computing, so identity stands in for reuse), the post-block wiring, and the resolution itself
# against a real trailing-newline clone beside a real sibling.
add bootstrap           bash scripts/check-bootstrap.sh

# ...and that is a guard, whose failure mode is silence: a resolution check that resolves nothing
# prints what a clean run prints. Each site's block is reverted to the superseded spelling ONE AT A
# TIME and the fixture must come back red on that site's own witness; the STATIC rules, which read
# the tracked tree and so cannot be driven by a fixture, are each driven red against a mutated COPY
# of the repo. Every revert is verified to have applied first. The four depth-safe sites are
# SKIPPED with a printed reason rather than counted as passing (D64's correction, which #343's
# evidence list did not carry over).
add bootstrap-mutation  bash scripts/check-bootstrap.sh --mutation
inputs bootstrap-mutation       scripts/check-bootstrap.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/adopt-readiness.sh install.sh uninstall.sh bin/baseline bin/agent-init agents/codex/adapter.sh agents/gemini/adapter.sh scripts/build.sh .claude/skills/release/release.sh .claude/skills/release/release-lib.sh

# The SECOND install model writes into somebody else's repository (#285), so its refusals are the
# load-bearing part: an unverified or escaping archive, a re-anchor that silently did nothing, an
# uninstall that deletes an operator's edits or leaves orphans. Every one is driven red against
# fixtures under `mktemp -d`; the tracked tree is never mutated.
add pinned-install      bash scripts/check-pinned-install.sh

# Canonical facts (gate axes, cross-agent invocations, codex timeout, resolution order)
# must stay consistent across their consumer docs.
add fact-drift          bash scripts/check-fact-drift.sh

# The negative half of that lint has a failure mode the positive half does not: SILENCE. An
# `absent:` pattern that matches nothing passes forever while checking nothing — which is exactly
# what shipped in #173 and is why #213 exists. Each rule's declared `fires:` witnesses are injected
# into a COPY of every file it pins and the real lint must come back red. Runs ~22 sub-lints
# against a throwaway tree; the working tree is never touched.
add fact-mutation       bash scripts/check-fact-drift.sh --mutation
inputs fact-mutation            scripts/check-fact-drift.sh scripts/check-lib.sh scripts/lib/common.sh scripts/selfcheck.sh

# ...and the guard rails above are themselves guards, so they get the same treatment (#213): the
# witness contract and the mutation harness are each driven against deliberately broken rules in a
# tree copy and must be seen going red. Carries the direct regression test for #173's defect — the
# exact `absent:\[bot\]\$` pattern that could not match either real idiom. A MODE of the lint since
# #377, not a separate file: it used the same copy-and-mutate scaffold `--mutation` already carries.
add fact-self-test      bash scripts/check-fact-drift.sh --self-test

# The OFFLINE half of the claim lint (#212, narrowed by #374). Since the `D<N>` and decision-date
# rules were dropped (D72), every VIOLATION the lint can report needs the network — so what this
# step contributes is the other two answers, and both are the ones that would otherwise turn the
# CI-only half into a silent no-op: it FAILS CLOSED on an unresolvable range (2) or a broken
# markdown filter / added-line scanner (3), and it REPORTS how many references it collected and
# left unverified, plus how many changed files fell outside the shipped-prose scope.
#
# The issue/PR-reference half is NOT run here, and that is deliberate rather than an omission. It
# needs the network, and D13 keeps selfcheck hermetic precisely so a local green is a DETERMINISTIC
# predictor of CI — a step whose verdict depends on network, auth and externally-mutable issue state
# would break that promise for every other step too. It rides CI instead, exactly as the one other
# live assertion (`repo-settings.sh required-drift`) does.
add claims              bash scripts/check-claims.sh

# ...and the lint above is a guard, so it gets the treatment guards get here (D22): every rule is
# driven to RED against fixtures in a throwaway repo with a stubbed gh, asserting the DESIGNATED
# exit code and diagnostic rather than "some non-zero". This has already earned its place twice —
# it caught a markdown stripper that made one rule structurally unable to fire, and an unresolvable
# --range that silently turned the whole check into a no-op reporting PASS. A MODE of the lint since
# #374, following the fact-drift fold (#377) rather than inventing a second shape.
add claims-self-test    bash scripts/check-claims.sh --self-test

# Every base/practices/*.md is listed in 00-index.md exactly once (no missing/stale rows).
add practice-index      bash scripts/check-practice-index.sh

# #3's decision — release execution stays project-owned and no /release skill ships — is no longer
# a step of its own. Since #375 it is a section of `check-fact-drift.sh`: three of its five groups
# were already that file's `fact` grammar, and the `roll` boundary needed the `fires:` witnesses and
# the `--mutation` proof only that file can give it. `fact-drift` and `fact-mutation` above run it.

# The other half of #3: the project supplies its OWN release skill, so this repo's copy needs a
# gate. Offline unit tests for .claude/skills/release/release-lib.sh (version-ok, changelog-verify,
# checks-settled) plus the boundary invariants — no {{PLACEHOLDER}} inside a runnable block, no
# release predicate in the installed scripts/lib, and the skill still delegating to the tested
# predicates rather than re-deriving them (D14). Nothing else here reads .claude/skills/.
add release-skill       bash scripts/check-release-skill.sh

# ...and THIS runner is now a guard too (#260), so it gets the treatment guards get here. The job
# pool's failure mode is the silent one: a dispatcher that loses a step's exit status, or reaps a
# job and attributes it to the wrong name, reports exactly what a clean run reports. Every rule is
# driven to RED against a throwaway fixture tree — a deliberately failing step under parallelism,
# a wrong-attribution probe, the concurrency bound, output atomicity — and never by mutating a
# tracked file.
add selfcheck-guard     bash scripts/check-selfcheck.sh

# ...and the cancellation cases owe the harder half of that, which cannot be paid from inside the
# same run: each one is required to come back RED against a copy of THIS file whose reaping is
# broken in the one way that case exists to catch. Every row runs the whole suite against its
# mutated copy and reads its exit status and its FAIL line, so a case whose assertion was deleted
# fails here instead of quietly covering nothing (#387).
add selfcheck-guard-mutation bash scripts/check-selfcheck.sh --mutation
inputs selfcheck-guard-mutation scripts/check-selfcheck.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/selfcheck.sh scripts/mutation-gate.sh

# THE MUTATION-HARNESS GATE is a guard (#441): a gate that answers SKIP wrongly is invisible, since
# the step it skipped is green either way. Its suite drives every rule to both answers against
# throwaway repositories, requires the fail-closed shapes (no repository, unresolvable base, no
# merge-base) to answer RUN and say why, and pins the wiring — every `--mutation` line in ci.yml
# goes through the gate, every `*-mutation` step here declares inputs, and the nightly matrix names
# every one of them. POOLED and cheap: seconds, in `mktemp -d` fixtures.
add mutation-gate       bash scripts/check-mutation-gate.sh

# ...and the gate's own suite is a guard whose failure mode is SILENCE, so every rule of the gate
# whose failure is a WRONG SKIP is broken in ONE way in a COPY — always skip, always run, an
# unresolvable base folded into a skip, the override ignored, a SKIP that no longer says what it
# compared, untracked files ignored, renames folded away, quoting hiding a name, the directory
# boundary blurred, a foreign command accepted, a harness status swallowed — and each workflow
# file is un-gated in a copy too; the suite must come back red on each row's own witness.
# BOTH WORKFLOW FILES ARE INPUTS: the rows that un-gate them are literal edits to copies of those
# files, so a workflow refactor can stop a row applying — a red only this harness would show.
add mutation-gate-mutation bash scripts/check-mutation-gate.sh --mutation
inputs mutation-gate-mutation scripts/check-mutation-gate.sh scripts/check-lib.sh scripts/shmutant.sh scripts/lib/common.sh scripts/mutation-gate.sh scripts/selfcheck.sh .github/workflows/ci.yml .github/workflows/mutation-nightly.yml scripts/mutation-nightly-status.sh scripts/lib/repo-settings.sh

add install-dry-run     step_install_dry_run

# ======================================== the runner ===========================================

JOBS=0
SERIAL=0
ONLY=""
ONLY_GIVEN=0   # distinct from ONLY="" — see the --only handling below
SKIP=""
SKIP_GIVEN=0   # same distinction, same reason (#339)
SUMMARIZE=""
SUMMARIZE_GIVEN=0   # same distinction as --only/--skip: `--summarize ""` must not fall through

usage() {
  cat <<'USAGE'
usage: bash scripts/selfcheck.sh [--serial] [--jobs N] [--only a,b,...] [--skip a,b,...]
                                 [--list] [--summarize FILE]
       bash scripts/selfcheck.sh --stop

  --serial      Run every step sequentially, in declaration order, with output streaming
                live. Reach for this when a parallel failure is hard to attribute.
  --jobs N      Cap concurrency at N (default: min(cpu, 8)). --jobs 1 still buffers;
                --serial is the mode that does not.
  --only a,b    Run only the named steps (still honouring the serial prologue). An unknown
                name is an error — a filter that silently selects nothing is not a pass.
  --skip a,b    Run everything EXCEPT the named steps. Same unknown-name contract as --only,
                and the skipped names are printed — a step dropped silently is indistinguishable
                from one that passed. Composes with --only: --only selects, --skip subtracts.
                This is a per-invocation choice for a caller that runs the suite twice on two
                platforms; a plain run selects the whole registry (and then applies the gate).
  --list        Print the registry as
                "<name><TAB><command><TAB>pool|serial<TAB>concurrent|mutates-tree|load-sensitive<TAB><inputs>"
                and exit. This is the runner's own answer to "what does it run", so a guard can
                ask instead of grepping. The third field says whether the step runs in the serial
                prologue; the fourth says why; the fifth is the comma-joined input set the step's
                verdict depends on (#441), or "-" for a step that always runs.

  The mutation gate (#441): a step that declares inputs is dispatched only when the change under
  test — the working tree plus untracked files, against the merge-base with origin/<default> —
  touches one of them; otherwise it is SKIPPED, by name, with the base it was compared against.
  ADB_MUTATION_RUN_ALL=1 runs every step regardless; ADB_MUTATION_BASE=<ref> changes the base.
  The decision is scripts/mutation-gate.sh's, and a gate that cannot decide fails CLOSED: the
  step runs, and the line says why.
  --summarize F Read a captured run of this suite from F and print a Markdown digest of what
                failed — the step names and their FAIL: witness lines — then exit 0. For a CI job
                summary, so a recurring red is readable without opening the log. A reporter, never
                a gate: it does not re-run anything and its status describes only itself.

  The overrun warning (#445): a step still running past ADB_SELFCHECK_OVERRUN_SECS (default 1800)
  is named live, once per multiple of that ceiling, and again in the result block. It is a report,
  never a kill: the step runs on and its own status is its verdict.

  --stop        Stop the run recorded in this checkout (.selfcheck-run) — THE supported way to stop
                a running selfcheck (#551). Sends TERM to the runner, waits up to
                ADB_SELFCHECK_STOP_SECS (default 40; never less than the run's recorded
                preparation allowance plus its grace plus 5s) for it and everything it owns to
                finish, then names every process the run owns that is still there, stopped ones
                included, and KILLs them. What the run owns: anything working under its private
                temp root (exported to every step as TMPDIR) or under a pool directory a harness
                registered, those processes' groups, the groups the run recorded, and every
                descendant of the runner or of any of those. A process that only works in the
                checkout is named and never signalled. Each inspection is bounded by
                ADB_SELFCHECK_STOP_INSPECT_SECS (default 20); a cancelled runner's own recording
                uses a fifth of it per inspection. Exit: 0 stopped clean · 1 survivors, named
                and removed · 3 some could not be removed · 4 could not inspect (e.g. inside a
                sandbox), or the record is incomplete — its marker counts even with no record ·
                5 no run is recorded · 6 nothing provably the run's is left, but processes that
                started during it still work in the checkout (named, never signalled). Needs an
                unsandboxed shell. Still useful after the runner died: it sweeps what that run
                left.

  The grace (#551): on TERM, INT or HUP the runner waits up to ADB_SELFCHECK_STOP_GRACE_SECS
  (default 10) for its workers' process groups to finish their own cleanup before it KILLs what is
  left, and records that grace for --stop.
USAGE
}

# min(cpu, 8) is `adb_pool_size` in scripts/lib/common.sh now (#335). The note that used to sit here
# is why: it said this probe was deliberately NOT promoted "because it has one consumer — if a
# second appears, promote it then". Two more appeared — `check-adopt.sh` wrote its own copy of the
# chain, and `check-adopt-readiness.sh` skipped the probe and hardcoded 4 — so the third spelling
# was the one that got the number wrong. Sourced, never copied (docs/design-principles.md).

LIST=0
STOP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial) SERIAL=1 ;;
    --jobs)
      [ "$#" -ge 2 ] || { echo "selfcheck: --jobs needs a value" >&2; exit 2; }
      # `0` alone is not the test. `000` is not the literal 0 and passes a pattern check, then
      # evaluates to 0 arithmetically and falls through to the automatic default — an explicit
      # `--jobs 000` silently becoming an 8-job run. So does a value too large for bash arithmetic,
      # which makes the later comparison error instead of returning false. Decide it HERE, once,
      # arithmetically, and never fall back on a value the operator actually supplied.
      case "$2" in ''|*[!0-9]*) echo "selfcheck: --jobs needs a positive integer, got '$2'" >&2; exit 2 ;; esac
      [ "$2" -ge 1 ] 2>/dev/null \
        || { echo "selfcheck: --jobs needs a positive integer, got '$2'" >&2; exit 2; }
      JOBS="$2"; shift ;;
    --only)
      [ "$#" -ge 2 ] || { echo "selfcheck: --only needs a value" >&2; exit 2; }
      # The FLAG is recorded separately from its VALUE. Keying the filter on a non-empty $ONLY
      # would make `--only ""` — which is what `--only "$LIST"` becomes when LIST is empty — run
      # the entire suite instead of erroring: a filter silently doing the opposite of narrowing.
      ONLY="$2"; ONLY_GIVEN=1; shift ;;
    --skip)
      [ "$#" -ge 2 ] || { echo "selfcheck: --skip needs a value" >&2; exit 2; }
      # Recorded separately from its value for the SAME reason as --only, and the failure it
      # prevents is the mirror image: `--skip "$LIST"` with an empty LIST is a flag that skips
      # NOTHING while its author believes it skipped something. --only silently widening and
      # --skip silently not-narrowing are one bug with two spellings; both are errors.
      SKIP="$2"; SKIP_GIVEN=1; shift ;;
    # A terminal mode is RECORDED here and acted on after the loop, not executed mid-parse.
    # Exiting inside the loop made rejection depend on argument ORDER: `--list --nonsense` printed
    # the registry and exited 0 while `--nonsense --list` errored. An unknown flag is an error
    # wherever it appears.
    --list) LIST=1 ;;
    --stop) STOP=1 ;;
    --summarize)
      [ "$#" -ge 2 ] || { echo "selfcheck: --summarize needs a file" >&2; exit 2; }
      # Keyed on the FLAG, not on a non-empty value. Without the bit, `--summarize ""` fell through
      # to the ordinary path and RAN THE SUITE — a reporting flag silently becoming a 20-minute run.
      SUMMARIZE="$2"; SUMMARIZE_GIVEN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "selfcheck: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --summarize: a Markdown digest of a captured run, for a CI job summary (#423).
#
# THREE CONSTRAINTS, each of which breaks something if changed:
#   * it parses `=== <name> ===`, `FAIL: <witness>` and the terminal `FAILED: <names>` — all three
#     written by this file, which is why the reader lives beside the writer rather than in YAML;
#   * every branch PRINTS. A digest that quietly extracted nothing reads exactly like a clean run;
#   * witnesses go in an INDENTED block, never a fence or a span. Witness text is arbitrary and a
#     backtick run in it would close a fence and render assertion text as markup in a page a
#     maintainer reads. Step names are validated against the slug pattern before they enter a span,
#     for the same reason — the `FAILED:` line is text from a log, not a value `add` vouched for.
# Rationale: D87.
summarize_run() {   # <captured-log>
  local log="$1" failed witnesses _f
  local -a _names
  # `-f` before `-r`: `-r` alone is true for a readable DIRECTORY, which then parsed as a log with
  # no markers in it and rendered an invented "the run was cancelled" report. A FIFO would have
  # been worse — `sed` on it blocks until someone writes, with the job's timeout as the only bound.
  if [ ! -f "$log" ] || [ ! -r "$log" ]; then
    printf 'selfcheck: --summarize needs a readable regular file, got %s\n' "$log" >&2
    return 2
  fi
  # The LAST such line. ONE captured run is the contract: the caller truncates its log per run, and
  # a file holding two APPENDED runs is NOT supported — this would take the later verdict while the
  # witness scan below gathered both runs' lines. Said plainly rather than claimed to work.
  failed="$(sed -n 's/^FAILED: //p' "$log" | tail -1)"
  # A GREEN log gets an honest heading, not the red one. The CI step only calls this on a failure,
  # so this branch is not on that path — but a reporter that says "failed" over a passing run is
  # one somebody eventually quotes, and the cost of being right here is three lines.
  if [ -z "$failed" ] && grep -q '^ALL CHECKS PASSED$' "$log" 2>/dev/null; then
    printf '### `selfcheck` passed\n\nNo failing steps in the captured run.\n'
    summarize_overran "$log"
    return 0
  fi
  printf '### `selfcheck` failed\n\n'
  summarize_overran "$log"
  if [ -n "$failed" ]; then
    printf '**Failed step(s):**'
    # EVERY TOKEN IS RE-VALIDATED before it enters a code span. `add` constrains what may be
    # REGISTERED; it says nothing about a line read back out of a log, which any step's own output
    # can forge by printing `FAILED: ` at the start of a line. A name carrying a backtick would
    # close the span and render the rest as markup in a page a maintainer reads. A token that is
    # not a [A-Za-z0-9_-] slug is reported as unparsable rather than rendered.
    # SPLIT INTO AN ARRAY, never by an unquoted expansion, which would also GLOB a forged token
    # against the checkout (D122).
    read -r -a _names <<< "$failed"
    for _f in "${_names[@]}"; do
      case "$_f" in
        *[!A-Za-z0-9_-]*|'') printf ' (one unparsable name omitted)' ;;
        *) printf ' `%s`' "$_f" ;;
      esac
    done
    printf '\n\n'
  else
    printf 'The run emitted no `FAILED:` line — it did not reach its `result` block, so it was\n'
    printf 'cancelled, killed, or died before finishing. Nothing below is a step verdict.\n\n'
  fi
  # `if cmd; then` and NOT `cmd && … || …`: in the latter, a non-zero from the SUCCESS branch's
  # last command falls through into the failure branch, so the digest would print both stories.
  # awk exits 1 when it matched nothing, which is the whole signal here.
  if witnesses="$(awk '
      /^=== / { step = $0; sub(/^=== /, "", step); sub(/ ===$/, "", step); next }
      /^FAIL: / { if (step != "") { printf "    %s: %s\n", step, substr($0, 7); c++ } }
      END { exit (c ? 0 : 1) }
    ' "$log")"; then
    printf 'Witness lines, verbatim:\n\n%s\n\n' "$witnesses"
  else
    printf 'No `FAIL:` witness lines were found in the captured output. Either the failing step\n'
    printf 'reported some other way, or this digest stopped matching what the suite prints —\n'
    printf 'open the job log rather than reading this as "nothing was wrong".\n\n'
  fi
  printf 'Full output is in the job log for this step.\n'
  return 0
}

# summarize_overran <captured-log> — the digest's paragraph for steps that ran past the overrun
# ceiling (#445), or nothing. From the result block's `overran` line when the run reached it, else
# from the LIVE warnings — a run cancelled while a step hung has only those, and it is exactly the
# run whose reader most needs the name. Every name is re-validated as `FAILED:`'s are, for the same
# reason: a step's own output can forge either line.
summarize_overran() {   # <captured-log>
  local names _n
  local -a _names
  names="$(sed -n 's/^overran (past [0-9]*s): //p' "$1" | tail -1)"
  [ -n "$names" ] || names="$(sed -n 's/^selfcheck: still running past [0-9]*s: \([^ ]*\) (.*/\1/p' "$1" | awk '!seen[$0]++' | tr '\n' ' ')"
  [ -n "${names// /}" ] || return 0
  printf '\n**Ran past the overrun warning:**'
  read -r -a _names <<< "$names"   # an array, never an unquoted expansion — see summarize_run
  for _n in "${_names[@]}"; do
    case "$_n" in
      *[!A-Za-z0-9_-]*|'') printf ' (one unparsable name omitted)' ;;
      *) printf ' `%s`' "$_n" ;;
    esac
  done
  printf '\n\n'
}

# ======================================== the stop (#551) ======================================
#
# `--stop` is the ONE supported way to stop a running selfcheck, and this block is all of it. D135
# has the reasoning; the contract is here.
#
# WHAT IT DOES, in order:
#   1. reads the run's record (`.selfcheck-run`, written by the runner below) and validates it WHOLE;
#   2. takes one inventory of the process table before signalling anything. A stop that cannot see
#      the WHOLE table says so (4) and signals nothing: "nothing left" is what it could not know;
#   3. sends TERM to the runner by pid, never by group: a runner started without job control shares
#      its caller's group. If the runner has already gone, the TERM goes to every group holding
#      something the run owns instead, through `_stop_signal`'s one rule for whole groups;
#   4. waits, re-reading the record and taking a FRESH inventory each time, until nothing the run
#      owns is left or the bound expires: ADB_SELFCHECK_STOP_SECS (default 40), raised to the run's
#      recorded preparation allowance plus its grace plus 5s when it is shorter, so nothing is
#      KILLed while the runner's cleanup is still inside the grace it was given;
#   5. names every survivor from an inventory taken AFTER the bound, stopped ones and zombies
#      included, each with its state, KILLs them through the same rule in one pass, so a frozen tree
#      dies with whatever froze it, then takes another fresh inventory to confirm what is gone.
# Every inspection (`ps`, `find`, `lsof`) is bounded by ADB_SELFCHECK_STOP_INSPECT_SECS (default
# 20) through `adb_run_bounded`; one that runs out is an inspection failure (4), never a wait.
#
# WHAT THE RUN OWNS — the only processes this signals (the owner's decision on #551):
#   * every process whose working directory lies under the run's private temp root (exported to
#     every step as TMPDIR) or under a pool directory a harness registered (`check_register_pool`,
#     scripts/check-lib.sh). Pools register because macOS's `mktemp` prefers its per-user temp
#     directory over TMPDIR whenever no template is given, and no suite's `mktemp -d` gives one;
#   * every member of those processes' groups — what reaches a shmutant holder, whose cwd is the
#     checkout but whose group is its pool's;
#   * every member of a process group the run recorded — a worker it forked, or a group it found
#     among its own descendants when it was cancelled — while that group is provably the one
#     recorded (`_stop_rec_member`);
#   * every descendant of the runner or of anything above, as the process table shows it — which
#     is what reaches a nested pool's worker: a subshell of its harness, working in the checkout,
#     in a group of its own (#547). Ownership is first taken BEFORE anything is signalled, while
#     those workers are still their harness's children;
#   * anything this stop has already found to be the run's, for as long as it is the same process
#     (same pid, same start): a worker does not stop being the run's when the TERM reparents it, nor
#     a holder when its pool process exits;
#   * the runner itself, if it outlives the bound.
# A process whose cwd is merely the CHECKOUT is NOT owned: so is the operator's shell, their editor,
# this agent session, a review dispatched beside the run. Those started during the run are NAMED —
# by the first word of the command line only, since an argument can carry a credential — and never
# signalled. The stopper, its
# ancestors and its descendants are never signalled; their groups, and groups 0 and 1, never as
# groups.
#
# THE INVENTORY IS PROVED WHOLE, not trusted. `ps` must exit 0 and list this process. The cwd
# listing must name a directory for every process of this user that started during the run and is
# still alive (asked of the kernel: `adb_pid_gone`); one it cannot read is an inspection failure,
# because that process could be the run's. macOS's lsof escapes a name (under `LC_ALL=C`: `\\`,
# `\n` `\r` `\t` `\b` `\f`, `^X` for another control byte, `\xNN` from 0x7f up — observed, D135),
# so the record's paths are compared in the same encoding. `^X` is ambiguous — a literal `^A` reads
# the same as byte 0x01 — so no record may hold a path with a `^` or a control byte
# (`_stop_path_ok`): every remaining escape decodes one way only.
#
# AN INCOMPLETE RECORD IS NEVER CLEAN. A worker or pool that could not be recorded leaves
# `.selfcheck-run.incomplete` beside the record; a stop that sees it answers 4 where it would have
# answered 0, since what it could not attribute it could not check.
#
# EXIT: 0 nothing the run owns outlived the bound, and nothing unattributed is left in its checkout
# · 1 survivors outlived it, named and removed · 2 usage · 3 survivors that could not be removed,
# named · 4 could not inspect, or the record is incomplete or invalid — never read as "nothing
# left" · 5 no run is recorded in this checkout · 6 nothing provably the run's is left, but
# processes that started during the run still work in its checkout, named and not signalled.
# NEEDS AN UNSANDBOXED SHELL: inside an agent's sandbox `ps` is refused (D132), which answers 4.

RUN_RECORD=".selfcheck-run"
STOP_SETTLE_SECS=5    # how long removal is given before what is left is reported as unremovable
STOP_MARGIN_SECS=5    # past the run's own grace, the least the stop waits

declare -A INV_PGID=() INV_PPID=() INV_UID=() INV_STAT=() INV_START=() INV_LST=() INV_CMD=() INV_CWD=()
declare -A STOP_SHIELD_PID=() STOP_SHIELD_PGID=() STOP_DESC=() REC_GROUPS=() OWNED=() OWN_GROUPS=()
declare -A OWN_EVER=() ENC_CACHE=() STOP_NAMED=()
declare -a REC_POOLS=()
INV_ERR=""; OWN_ERR=""; STOP_WHY=""; STOP_DIR=""; RUNNER_STATE=""; OWN_ALIVE=0; _ETS=""; _ENC=""; STOP_ENC=0
STOP_SKEW=0   # the longest any inventory's ps took: every start ESTIMATE is within it of the truth
REC_PID=""; REC_PGID=""; REC_EPOCH=""; REC_ROOT=""; REC_TMP=""; REC_GRACE=""; REC_PREP=""; REC_MTIME=""
STOP_RUNNER_PGID=""; UNATTRIBUTED=0

# _stop_num <value> [digits] — a plain decimal above zero, no leading zero, at most <digits> digits
# (12 when not given: an epoch fits, and so does any pid). A record's grace and prep get 9, the
# bound the runner's own knobs pass through (`_adb_pos_int`), so a record can say nothing the
# runner could not have written.
_stop_num() { case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le "${2:-12}" ]; }

# _stop_path_ok <path> — a path a record may hold: absolute, with no control byte and no `^`. lsof
# writes a control byte as `^X`, which is also how it writes a literal `^` followed by that
# character, so a path holding either could be matched in its output by a DIFFERENT directory.
# Without them, every escape decodes one way only (a literal backslash is always doubled), and a
# prefix match in lsof's spelling is a match of the real bytes. Refused on every platform, so the
# rule and its proof do not depend on which listing a machine has.
_stop_path_ok() {
  local LC_ALL=C
  case "$1" in /?*) ;; *) return 1 ;; esac
  case "$1" in *[[:cntrl:]]*|*'^'*) return 1 ;; esac   # row-path-ok
  return 0
}

# _stop_under <path> <root> — <path> is <root> or lies inside it, on a `/` boundary.
_stop_under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

# _stop_clean <text> — printable ASCII only, at most 300 bytes. A survivor line carries a command
# and a path, both arbitrary bytes, into a log `--summarize` parses: a newline in either could start
# a line that forges `=== name ===`, `FAIL:` or `FAILED:`. Every line this block prints also starts
# `selfcheck --stop:`.
_stop_clean() {
  local LC_ALL=C s="$1"
  s="${s//[^[:print:]]/?}"
  printf '%s' "${s:0:300}"
}

# _stop_enc <path> — set _ENC to <path> as the cwd listing spells it: unchanged where the listing is
# /proc (raw bytes), lsof's C-locale escaping where it is lsof (see the header). Cached per path.
_stop_enc() {
  local LC_ALL=C s="$1" out="" c h n i
  if [ "$STOP_ENC" -ne 1 ]; then _ENC="$1"; return 0; fi
  if [ -n "${ENC_CACHE[$1]+x}" ]; then _ENC="${ENC_CACHE[$1]}"; return 0; fi
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '\') out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      [[:print:]]) out+="$c" ;;
      *) printf -v n '%d' "'$c"
         [ "$n" -lt 0 ] && n=$(( n + 256 ))
         if [ "$n" -lt 32 ]; then printf -v h '%02x' $(( n + 64 )); printf -v c "\\x$h"; out+="^$c"
         else printf -v h '%02x' "$n"; out+="\\x$h"; fi ;;
    esac
  done
  ENC_CACHE["$1"]="$out"
  _ENC="$out"
}

# _stop_etime <etime> — set _ETS to ps's `[[dd-]hh:]mm:ss` in whole seconds, or fail. A global
# rather than printed: it runs once per process per poll, and a substitution would fork once each.
_stop_etime() {
  local e="$1" d=0 h=0 m s
  _ETS=""
  case "$e" in *:*) ;; *) return 1 ;; esac
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  s="${e##*:}"; e="${e%:*}"
  case "$e" in *:*) h="${e%%:*}"; m="${e#*:}" ;; *) m="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  # In range, and short enough for arithmetic: anything else is not ps's grammar, and refused.
  [ "${#d}" -le 6 ] && [ "${#h}" -le 2 ] && [ "${#m}" -le 2 ] && [ "${#s}" -le 2 ] || return 1
  [ "$(( 10#$h ))" -lt 24 ] && [ "$(( 10#$m ))" -lt 60 ] && [ "$(( 10#$s ))" -lt 60 ] || return 1
  _ETS=$(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# _stop_first_line <file> — its first line, cleaned, for a diagnostic.
_stop_first_line() { local l=""; IFS= read -r l < "$1" 2>/dev/null; _stop_clean "$l"; }

# _stop_bound — set _SB to the bound for the next read: STOP_INSPECT, cut to what is left of
# STOP_DEADLINE when one is set (a cancelled runner's `prep`); fails, with INV_ERR, when nothing is.
# Every read goes through it, and the recording checks it again before each group it writes, so the
# allowance a record promises is a deadline the recording cannot outrun.
_stop_bound() {
  _SB="$STOP_INSPECT"
  [ -n "${STOP_DEADLINE:-}" ] || return 0
  local left=$(( STOP_DEADLINE - BASH_MONOSECONDS ))
  if [ "$left" -le 0 ]; then INV_ERR="the inspection ran past its deadline"; return 1; fi   # row-deadline-reads
  [ "$left" -lt "$_SB" ] && _SB="$left"
  return 0
}

# _stop_cwd_decides <path> — <path> is, or lies under, a directory some verdict is decided by: the
# checkout, the run's temp root or a pool it registered. Those are the only directories the stop
# compares a working directory with. An empty one holds every path, so a field left unset refuses.
_stop_cwd_decides() {
  local d
  for d in "$REC_ROOT" "$REC_TMP" "${REC_POOLS[@]}"; do
    _stop_under "$1" "$d" && return 0
  done
  return 1
}

# _stop_cwds — fill INV_CWD (pid -> cwd as the listing spells it), each listing bounded.
#
# Linux: one `find` over /proc, NUL-terminated records split at their FIRST tab, so no byte of a
# path — a newline, a trailing tab — can forge or truncate a record. The kernel appends ` (deleted)`
# to a removed directory; it is stripped only when no directory of that full name exists, so a real
# directory whose name ends that way keeps it. Where one does exist, the listing is refused only if
# either reading lies under a directory the stop decides by (`_stop_cwd_decides`): anywhere else
# both readings give the same answer. The runner removes its temp root on the way out, and a
# survivor still inside it is still the run's.
# Elsewhere (macOS): one `lsof` under LC_ALL=C, which names a removed directory by its last path.
# Neither status is the verdict — `find` fails on any unreadable process, and both can list less
# than they should — so completeness is proved afterwards, process by process (`_stop_inventory`).
_stop_cwds() {
  local rec p c lsof_bin="" rc=0
  INV_CWD=()
  : > "$STOP_DIR/cwd"
  if [ -e "/proc/$$/cwd" ]; then
    STOP_ENC=0
    _stop_bound || return 1
    adb_run_bounded "$_SB" 1 find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%h\t%l\0' \
      > "$STOP_DIR/cwd" 2>/dev/null || rc=$?
    case "$rc" in 124|126|127) INV_ERR="the /proc walk did not finish (rc $rc)"; return 1 ;; esac
    while IFS= read -r -d '' rec; do
      case "$rec" in *$'\t'*) ;; *) continue ;; esac
      p="${rec%%$'\t'*}"; c="${rec#*$'\t'}"; p="${p#/proc/}"
      case "$p" in ''|*[!0-9]*) continue ;; esac
      [ -n "$c" ] || continue
      # The kernel's ` (deleted)` cannot be told from a name that really ends that way when a directory
      # of the full name exists: refused, never guessed — either guess can hide a survivor. Not for a
      # directory outside the checkout, the temp root and the pools, which hides nothing: refusing it
      # let any process on the machine make every stop answer 4.
      case "$c" in
        *' (deleted)')
          if [ -e "$c" ] && { _stop_cwd_decides "$c" || _stop_cwd_decides "${c% (deleted)}"; }; then   # row-deleted-ambiguous
            INV_ERR="pid $p works in $(_stop_clean "$c"), which is either a removed directory or one really named so — it cannot be told"
            return 1
          fi
          c="${c% (deleted)}" ;;
      esac
      INV_CWD["$p"]="$c"
    done < "$STOP_DIR/cwd"
  else
    STOP_ENC=1
    lsof_bin="$(command -v lsof 2>/dev/null)" || lsof_bin=""
    [ -n "$lsof_bin" ] || { [ -x /usr/sbin/lsof ] && lsof_bin=/usr/sbin/lsof; }
    [ -n "$lsof_bin" ] || { INV_ERR="there is no /proc and no lsof to read working directories with"; return 1; }
    _stop_bound || return 1
    adb_run_bounded "$_SB" 1 env LC_ALL=C "$lsof_bin" -w -a -d cwd -Fpn > "$STOP_DIR/cwd" 2>/dev/null || rc=$?
    case "$rc" in 124|126|127) INV_ERR="lsof did not finish (rc $rc)"; return 1 ;; esac
    p=""
    while IFS= read -r rec; do
      case "$rec" in
        p*) p="${rec#p}" ;;
        n*) case "$p" in ''|*[!0-9]*) ;; *) INV_CWD["$p"]="${rec#n}" ;; esac ;;
      esac
    done < "$STOP_DIR/cwd"
  fi
  return 0
}

# _stop_inventory — one snapshot: pgid, ppid, uid, state, an estimated start (now minus elapsed),
# command and cwd per pid; 1 with INV_ERR when it is not provably the whole table (see the header).
# _stop_inventory — the snapshot, retried while it is only INCONSISTENT. A process the stop sent a
# TERM a moment ago can be past the point where ps lists it while the kernel still answers for it —
# exiting, not hidden. So an inventory in which a process that must be listed is missing yet still
# exists is taken again, up to four times 0.3s apart, before it counts as partial; a listing that
# really is partial stays so and is refused. 0 · 1 (INV_ERR says why).
_stop_inventory() {
  local n=0 rc
  while :; do
    _stop_inventory_once; rc=$?
    [ "$rc" -eq 2 ] || return "$rc"
    n=$(( n + 1 )); [ "$n" -lt 4 ] || return 1   # row-inventory-retry
    sleep 0.3
  done
}

_stop_inventory_once() {
  local pid pgid ppid uid stat etime l1 l2 l3 l4 l5 cmd t0 now rc=0 p e irc=0
  local -a idp=()
  local -A cwd_before=()
  INV_PGID=(); INV_PPID=(); INV_UID=(); INV_STAT=(); INV_START=(); INV_LST=(); INV_CMD=(); INV_CWD=(); INV_ERR=""
  # THE ORDER IS THE PROOF: working directories, then processes, then working directories again. A
  # process the FIRST cwd listing saw already existed when ps ran, so ps must list it unless the
  # kernel says it has gone; a process ps listed already existed when the SECOND cwd listing ran, so
  # that one must give its directory unless it has gone (`_stop_whole`). Neither needs a start time
  # to tell "omitted" from "newer", which is the guess that had a blind second.
  _stop_cwds || return 1
  for p in "${!INV_CWD[@]}"; do cwd_before["$p"]=1; done
  t0="$EPOCHSECONDS"
  _stop_bound || return 1
  adb_run_bounded "$_SB" 1 env LC_ALL=C ps -A -o pid=,pgid=,ppid=,uid=,stat=,etime=,lstart=,command= \
    > "$STOP_DIR/ps" 2> "$STOP_DIR/ps.err" || rc=$?
  if [ "$rc" -ne 0 ]; then   # row-ps-status
    INV_ERR="ps could not list processes (rc $rc: $(_stop_first_line "$STOP_DIR/ps.err"))"
    return 1
  fi
  # Elapsed times are read while ps runs — after t0, before now — so a start is dated from NOW and
  # is within the read's own duration of the truth: an ESTIMATE, which the windows against the
  # record's own times allow for (STOP_SKEW). IDENTITY is never an estimate: `lstart` is the absolute
  # start to the second, the same however long the listing took, and "the same process" means the
  # same pid with the same `lstart` (`_stop_same`).
  now="$EPOCHSECONDS"   # row-ps-now
  [ $(( now - t0 )) -le "$STOP_SKEW" ] || STOP_SKEW=$(( now - t0 ))
  while read -r pid pgid ppid uid stat etime l1 l2 l3 l4 l5 cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$pgid" in ''|*[!0-9]*) continue ;; esac
    case "$ppid" in ''|*[!0-9]*) continue ;; esac
    INV_PGID["$pid"]="$pgid"; INV_PPID["$pid"]="$ppid"; INV_UID["$pid"]="$uid"
    INV_STAT["$pid"]="$stat"; INV_CMD["$pid"]="$cmd"
    if _stop_etime "$etime"; then INV_START["$pid"]=$(( now - _ETS )); fi
    [ -n "$l5" ] && INV_LST["$pid"]="$l1 $l2 $l3 $l4 $l5"
  done < "$STOP_DIR/ps"
  [ -n "${INV_PGID[$$]+x}" ] \
    || { INV_ERR="ps answered without this process ($$) in its listing, so it is not the whole table"; return 1; }   # row-ps-control
  # Every process of this user is in the first cwd listing — the runner, a recorded group's leader,
  # anything found to be the run's among them — so a pid ps did NOT list must be gone. Absence is
  # never read as an exit: if the kernel says it still exists, the listing is not the whole table.
  for p in "${!cwd_before[@]}"; do   # row-both-ways
    [ -n "${INV_PGID[$p]+x}" ] && continue
    adb_pid_gone "$p" && continue
    INV_ERR="pid $p was in the working-directory listing taken before ps ran, and still exists, but ps did not list it — the listing is not the whole table"
    return 2
  done
  # …and a process this stop already DEPENDS on — the runner, a recorded group's leader, anything it
  # has found to be the run's — missing from BOTH listings is asked of the kernel too: two listings
  # that agree on leaving it out prove nothing about it.
  for p in "$REC_PID" "${!REC_GROUPS[@]}" "${!OWN_EVER[@]}"; do   # row-ps-known
    [ -n "${INV_PGID[$p]+x}" ] || [ -n "${cwd_before[$p]+x}" ] && continue
    adb_pid_gone "$p" && continue
    INV_ERR="pid $p, which this stop depends on, is in neither listing yet still exists — the listings are not the whole table"
    return 2
  done
  _stop_mark_desc
  _stop_cwds || return 1
  # …and the directories must still belong to the processes `ps` described. A pid that ended and was
  # REUSED between the two would pair the old process's group and start with the new one's directory,
  # and ownership by directory would then claim the old process's group. So every listed start is read
  # again after the second listing (one short, targeted, bounded read): a pid that started again
  # makes the snapshot inconsistent, and it is taken again like any other.
  for p in "${!INV_CWD[@]}"; do [ -n "${INV_LST[$p]:-}" ] && idp+=("$p"); done
  if [ "${#idp[@]}" -gt 0 ]; then
    _stop_bound || return 1
    e="$(IFS=,; adb_run_bounded "$_SB" 1 env LC_ALL=C ps -o pid=,lstart= -p "${idp[*]}" 2>/dev/null)" || irc=$?
    # 1 with nothing printed is every one of them gone, which is no inconsistency; anything else that
    # is not 0 is a read that cannot vouch for the rows it printed.
    case "$irc" in
      0) ;;
      1) [ -z "$e" ] || { INV_ERR="the processes' starts could not be read again (ps rc 1)"; return 1; } ;;
      *) INV_ERR="the processes' starts could not be read again (rc $irc)"; return 1 ;;
    esac
    local -A seen=()
    while read -r p l1 l2 l3 l4 l5; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      seen["$p"]=1
      [ "$l1 $l2 $l3 $l4 $l5" = "${INV_LST[$p]:-}" ] && continue
      INV_ERR="pid $p started again between the process listing and the working-directory listing"
      return 2   # row-cwd-identity
    done <<< "$e"
    # A pid the read left out vouches for nothing: it is gone (the kernel's ESRCH), or the snapshot is
    # not consistent.
    for p in "${idp[@]}"; do
      [ -n "${seen[$p]+x}" ] && continue
      adb_pid_gone "$p" && continue
      INV_ERR="pid $p was left out of the second read of starts, yet still exists"
      return 2   # row-cwd-omitted
    done
  fi
  _stop_whole
}

# _stop_whole — the cwd listing names a directory for this process and for every process of this
# user that started during the run and is still alive, or the inventory is refused.
_stop_whole() {
  local p st rc
  [ -n "${INV_CWD[$$]:-}" ] \
    || { INV_ERR="the working-directory listing did not include this process ($$)"; return 1; }
  for p in "${!INV_PGID[@]}"; do   # row-cwd-whole
    [ -n "${INV_CWD[$p]:-}" ] && continue
    [ "${INV_UID[$p]}" = "$UID" ] || continue
    case "${INV_STAT[$p]}" in Z*) continue ;; esac
    # The stopper's own children are skipped; the RUNNER's are exactly what its own recording is for.
    [ "${STOP_FOR_RUNNER:-0}" -eq 1 ] || { [ -n "${STOP_DESC[$p]+x}" ] && continue; }
    [ -n "${INV_START[$p]:-}" ] && [ "${INV_START[$p]}" -lt $(( REC_EPOCH - 2 - STOP_SKEW )) ] && continue
    # It may have ended between the two listings: gone (the kernel's ESRCH), or a zombie, which has
    # no directory left to read and which `kill -0` still answers for. Asked of the kernel and of a
    # bounded ps NOW, never inferred from the earlier snapshot — and a ps that cannot answer is no
    # answer: only a state it READ, or the kernel's ESRCH after it, excuses the missing directory.
    adb_pid_gone "$p" && continue
    _stop_bound || return 1
    st=""; rc=0
    st="$(adb_run_bounded "$_SB" 1 ps -o stat= -p "$p" 2>/dev/null)" || rc=$?
    st="${st//[[:space:]]/}"
    if [ "$rc" -eq 0 ] && [ -n "$st" ]; then   # row-cwd-recheck
      case "$st" in Z*) continue ;; esac
    elif adb_pid_gone "$p"; then
      continue
    fi
    INV_ERR="the working directory of pid $p ($(_stop_clean "${INV_CMD[$p]%% *}")), which started during the run, could not be read"
    return 2
  done
  return 0
}

# _stop_mark_desc — STOP_DESC: every process descended from this one. The `ps`, `find` and `lsof`
# this stop runs are in the table it reads, working in the checkout and started during the run, and
# must never be counted, named or signalled. Each chain is walked once.
_stop_mark_desc() {
  local p q n chain res
  local -A memo=()
  STOP_DESC=()
  for p in "${!INV_PPID[@]}"; do
    q="$p"; n=0; chain=""
    while :; do
      [ "$q" = "$$" ] && { res=1; break; }
      _stop_num "$q" && [ "$q" -gt 1 ] && [ "$n" -lt 4096 ] || { res=0; break; }
      [ -n "${memo[$q]+x}" ] && { res="${memo[$q]}"; break; }
      chain="$chain $q"; q="${INV_PPID[$q]:-}"; n=$(( n + 1 ))
    done
    for q in $chain; do memo["$q"]="$res"; done
    [ "$res" -eq 1 ] && [ "$p" != "$$" ] && STOP_DESC["$p"]=1
  done
  return 0
}

# _stop_shield — from the first inventory: the stopper and every ancestor, which are never signalled,
# and their process groups, which are never signalled AS GROUPS. A process merely sharing the
# stopper's group is still signalled by pid when it is the run's: a runner started without job
# control shares its caller's group, and so does a stop started from the same shell.
_stop_shield() {
  local p="$$" n=0
  STOP_SHIELD_PID=(); STOP_SHIELD_PGID=([0]=1 [1]=1)
  while _stop_num "$p" && [ "$p" -gt 1 ] && [ "$n" -lt 4096 ]; do
    STOP_SHIELD_PID["$p"]=1
    [ -n "${INV_PGID[$p]:-}" ] && STOP_SHIELD_PGID["${INV_PGID[$p]}"]=1
    p="${INV_PPID[$p]:-}"; n=$(( n + 1 ))
  done
}

_stop_shielded() { [ -n "${STOP_SHIELD_PID[$1]+x}" ] || [ -n "${STOP_DESC[$1]+x}" ]; }

# _stop_where <pid> — the process works under the run's temp root or a registered pool.
_stop_where() {
  local c="${INV_CWD[$1]:-}" d
  [ -n "$c" ] || return 1
  _stop_enc "$REC_TMP"   # row-where-tmp
  if _stop_under "$c" "$_ENC"; then WHY="works in the run's temp root"; return 0; fi   # row-own-tmp
  for d in "${REC_POOLS[@]}"; do   # row-own-pool
    _stop_enc "$d"
    if _stop_under "$c" "$_ENC"; then WHY="works in a pool directory the run registered"; return 0; fi
  done
  return 1
}

# _stop_same <pid> <lstart> — <pid> is still the process that started at <lstart> (`ps lstart`, words
# joined by single spaces). Exact, never a window: a window wide enough for ps's rounding and a slow
# listing is wide enough for a reused pid too.
_stop_same() {
  [ -n "${INV_LST[$1]:-}" ] && [ "${INV_LST[$1]}" = "$2" ]   # row-same-exact
}

# _stop_rec_member <pid> <pgid> — is <pid>, in a group the runner recorded forking at REC_GROUPS[g],
# the run's? POSIX's process-ID reuse rule keeps a group's id from being reused while the group has
# a member, so the only question is whether this group is a NEWER one with the same number. While
# its leader lives, the leader's start answers it for the whole group. With the leader gone, a
# member counts only if it started no earlier than the fork and works in the checkout or the temp
# root. Starts are ps's elapsed time read back as a date, so the windows allow its rounding.
_stop_rec_member() {
  local p="$1" g="$2" fork="${REC_GROUPS[$2]}" st
  if [ -n "${INV_PGID[$g]+x}" ] && [ "${INV_PGID[$g]}" = "$g" ]; then
    st="${INV_START[$g]:-}"
    [ -n "$st" ] && [ "$st" -ge $(( fork - 60 - STOP_SKEW )) ] && [ "$st" -le $(( fork + 2 + STOP_SKEW )) ]
    return
  fi
  st="${INV_START[$p]:-}"
  [ -n "$st" ] && [ "$st" -ge $(( fork - 2 - STOP_SKEW )) ] && [ -n "${INV_CWD[$p]:-}" ] || return 1
  # …and no LATER than the run was last heard from (the record's last write, plus a minute): a group
  # whose number was reused after the run, and whose new leader has gone, holds only newer members.
  [ -n "$REC_MTIME" ] && [ "$st" -le $(( REC_MTIME + 60 + STOP_SKEW )) ] || return 1   # row-rec-upper
  _stop_enc "$REC_ROOT"
  _stop_under "${INV_CWD[$p]}" "$_ENC" && return 0
  _stop_enc "$REC_TMP"
  _stop_under "${INV_CWD[$p]}" "$_ENC"
}

# _stop_runner — RUNNER_STATE: `live` while REC_PID is the recorded runner (present, not a zombie,
# started when the record says), `gone` when it provably is not, `unknown` when ps cannot date it.
_stop_runner() {
  local p="$REC_PID" st
  RUNNER_STATE=gone
  # Not listed: `_stop_inventory` has already required the kernel to agree it is gone — a pid the
  # stop depends on that a listing leaves out is asked of the kernel, never read as an exit.
  [ -n "${INV_PGID[$p]+x}" ] || return 0
  case "${INV_STAT[$p]}" in Z*) return 0 ;; esac
  _stop_shielded "$p" && return 0
  st="${INV_START[$p]:-}"
  [ -n "$st" ] || { RUNNER_STATE=unknown; return 0; }
  [ "$st" -ge $(( REC_EPOCH - 60 - STOP_SKEW )) ] && [ "$st" -le $(( REC_EPOCH + 2 + STOP_SKEW )) ] && RUNNER_STATE=live
  return 0
}

# _stop_owned — OWNED (pid -> why) from the current inventory, by the rules in this block's header.
# OWN_ALIVE counts the owned processes that are not zombies. Everything owned is remembered with its
# `lstart` in OWN_EVER, so it stays owned on later passes while it is the same process.
#
# THE RUNNER'S OWN GROUP NEVER SPREADS OWNERSHIP, and neither does a shielded one. A runner started
# without job control is in its CALLER's group — the shell or agent that launched it — so treating
# that group as the run's would KILL the caller. Its id comes from the record, or from the table
# while the runner lives; the runner's descendants are reached by descent instead.
#
# And when NEITHER is known — a runner that could not read its own group (a sandbox refuses ps) and
# has since exited — no group spreads ownership at all: any of them might be the caller's.
_stop_closable() {
  [ -n "${REC_PGID:-}${STOP_RUNNER_PGID:-}" ] || return 1   # row-closable-unknown
  [ -z "${STOP_SHIELD_PGID[$1]+x}" ] && [ "$1" != "${REC_PGID:-}" ] && [ "$1" != "${STOP_RUNNER_PGID:-}" ]
}

_stop_owned() {
  local p g WHY
  OWNED=(); OWN_GROUPS=(); OWN_ALIVE=0
  for p in "${!INV_PGID[@]}"; do
    _stop_shielded "$p" && continue
    if _stop_where "$p"; then
      OWNED["$p"]="$WHY"
    elif [ -n "${OWN_EVER[$p]+x}" ] && _stop_same "$p" "${OWN_EVER[$p]}"; then   # row-own-sticky
      OWNED["$p"]="was the run's earlier in this stop"
    else
      continue
    fi
    _stop_closable "${INV_PGID[$p]}" && OWN_GROUPS["${INV_PGID[$p]}"]=1
  done
  if [ "$RUNNER_STATE" = live ]; then OWNED["$REC_PID"]="the run itself"; fi
  # Groups and descent feed each other — a descendant's group holds more of the run, and a group
  # member's children are the run's too — so the passes repeat until a whole pass adds nothing.
  # No round cap: every pass that changes anything adds at least one process, so this ends. An
  # ancestry walk that does not reach the top within 4096 steps is a cycle in a racing snapshot,
  # and refuses the inventory rather than guess.
  local changed=1 q n
  OWN_ERR=""
  while [ "$changed" -eq 1 ]; do   # row-own-converge
    changed=0
    for p in "${!INV_PGID[@]}"; do
      [ -n "${OWNED[$p]+x}" ] && continue
      _stop_shielded "$p" && continue
      g="${INV_PGID[$p]}"
      if [ -n "${OWN_GROUPS[$g]+x}" ]; then   # row-own-closure
        OWNED["$p"]="in process group $g, beside a process that is the run's"
      elif [ -n "${REC_GROUPS[$g]+x}" ] && _stop_rec_member "$p" "$g"; then   # row-own-recorded
        OWNED["$p"]="in process group $g, which the run recorded"
      else
        # Descent: walk up to the first ancestor this pass knows about.
        q="${INV_PPID[$p]:-}"; n=0
        while _stop_num "$q" && [ "$q" -gt 1 ]; do
          if [ -n "${OWNED[$q]+x}" ]; then   # row-own-descent
            OWNED["$p"]="descended from pid $q, which is the run's"; break
          fi
          q="${INV_PPID[$q]:-}"; n=$(( n + 1 ))
          [ "$n" -lt 4096 ] || { OWN_ERR="the parent chain of pid $p does not end — the process table changed under the listing"; return 1; }
        done
        [ -n "${OWNED[$p]+x}" ] || continue
      fi
      _stop_closable "$g" && OWN_GROUPS["$g"]=1   # row-own-closable
      changed=1
    done
  done
  # A zombie has already exited and waits only for its parent to reap it: it is named, and it does
  # not keep a stop from being clean.
  for p in "${!OWNED[@]}"; do
    [ -n "${INV_LST[$p]:-}" ] && OWN_EVER["$p"]="${INV_LST[$p]}"
    case "${INV_STAT[$p]:-}" in Z*) ;; *) OWN_ALIVE=$(( OWN_ALIVE + 1 )) ;; esac
  done
  return 0
}

# _stop_signal <SIG> <pgid...> — send <SIG> to what the run owns in each group: the GROUP when every
# current member is the run's and verified and the group may spread ownership (`_stop_closable`),
# otherwise each owned member by pid. The one rule both the TERM to a dead runner's groups and the
# KILL of survivors go through.
#
# EVERY TARGET IS RE-VERIFIED FIRST. The inventory is a snapshot, and by the time a signal goes out a
# process may have ended and its number been reused. So one bounded ps re-reads every owned process
# in these groups immediately before the signal, and only those still in the same group with the
# same start are signalled. What remains is the instant between that read and kill(2) — the residue
# of any stop without process handles, which macOS does not offer; stated in D135.
_stop_signal() {
  local sig="$1" g p whole pid pgid l1 l2 l3 l4 l5 e; shift
  local -a cand=()
  local -A ok=()
  for g in "$@"; do
    for p in "${!OWNED[@]}"; do [ "${INV_PGID[$p]:-}" = "$g" ] && cand+=("$p"); done
  done
  [ "${#cand[@]}" -gt 0 ] || return 0
  # A group goes WHOLE only on its CURRENT membership: one more bounded read, of every process's
  # group and state. It needs at least one member that is the run's and was just verified, and no
  # other: a member the inventory never saw, an unverified one, or a read that failed makes it
  # pid-by-pid — and so does a group the read shows empty, since a group nobody was verified in is a
  # number, and a number can be reused. And never a group that may not spread ownership
  # (`_stop_closable`): the runner's, its caller's, a shielded one. That read comes FIRST: it is of
  # the whole table and can take the whole inspection bound, and nothing slow may stand between the
  # identity read below and the signals it authorizes.
  local -A live=() lstat=()
  local lrc=0 lp lg ls
  e="$(adb_run_bounded "$STOP_INSPECT" 1 env LC_ALL=C ps -A -o pid=,pgid=,stat= 2>/dev/null)" || lrc=$?
  while read -r lp lg ls; do
    case "$lp$lg" in ''|*[!0-9]*) continue ;; esac
    live["$lp"]="$lg"; lstat["$lp"]="$ls"
  done <<< "$e"
  # A read that did not SUCCEED authorizes nothing, whatever rows it printed before it failed. (ps
  # also fails when none of the pids exists any more, and then there is nothing to signal anyway.)
  local vrc=0
  e="$(IFS=,; adb_run_bounded "$STOP_INSPECT" 1 env LC_ALL=C ps -o pid=,pgid=,lstart= -p "${cand[*]}" 2>/dev/null)" || vrc=$?
  [ "$vrc" -eq 0 ] || e=""   # row-signal-status
  while read -r pid pgid l1 l2 l3 l4 l5; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pgid" = "${INV_PGID[$pid]:-}" ] || continue
    _stop_same "$pid" "$l1 $l2 $l3 $l4 $l5" || continue   # row-signal-verify
    ok["$pid"]=1
  done <<< "$e"
  for g in "$@"; do
    whole=0   # row-whole-needs-member
    if [ "$lrc" -eq 0 ] && _stop_closable "$g"; then   # row-signal-closable
      for p in "${!live[@]}"; do
        [ "${live[$p]}" = "$g" ] || continue
        case "${lstat[$p]:-}" in Z*) continue ;; esac   # its state NOW: an old zombie's number may be reused
        if [ -n "${OWNED[$p]+x}" ] && [ "$p" != "$REC_PID" ] && [ -n "${ok[$p]+x}" ]; then whole=1; continue; fi
        whole=0; break   # row-signal-live
      done
    fi
    if [ "$whole" -eq 1 ]; then
      kill -"$sig" -- "-$g" 2>/dev/null   # row-stop-group
    else
      for p in "${!OWNED[@]}"; do
        [ "${INV_PGID[$p]:-}" = "$g" ] && [ -n "${ok[$p]+x}" ] || continue
        case "${INV_STAT[$p]:-}" in Z*) continue ;; esac
        kill -"$sig" "$p" 2>/dev/null
      done
    fi
  done
  return 0
}

# _stop_read_record — the run record, from ONE bounded snapshot validated whole before any field is
# used: 0 · 5 there is none · 4 refused, with STOP_WHY naming the rule. A key the writer never
# writes, a key twice, an unterminated last line, or a root other than this checkout's is a refusal,
# never a partial read, and nothing is committed to REC_* until the whole record has passed. A
# `group` repeated with a later fork is a pid the kernel reused for a later worker, so the latest
# fork is the one that can still be alive.
_stop_read_record() {
  local line k v g e d n=0 got=" " r_pid="" r_pgid="" r_epoch="" r_root="" r_tmp="" r_grace="" r_prep="" r_mtime
  local -A r_groups=()
  local -a r_pools=()
  if [ ! -e "$RUN_RECORD" ] && [ ! -L "$RUN_RECORD" ]; then return 5; fi
  if [ -L "$RUN_RECORD" ] || [ ! -f "$RUN_RECORD" ] || [ ! -O "$RUN_RECORD" ]; then
    STOP_WHY="$RUN_RECORD is not a regular file this user owns"; return 4
  fi
  # The last write's time is read BEFORE the bytes: an append landing between the two then makes it
  # older than what was read, never newer, and "last heard from" can only err narrow.
  r_mtime="$(adb_mtime "$RUN_RECORD")"
  adb_run_bounded "$STOP_INSPECT" 1 head -c 1048577 "$RUN_RECORD" > "$STOP_DIR/record" 2>/dev/null \
    || { STOP_WHY="$RUN_RECORD could not be read (in time)"; return 4; }
  adb_bytes_whole "$STOP_DIR/record" 1048576 \
    || { STOP_WHY="$RUN_RECORD is not whole (empty, past 1 MiB, a NUL byte, or no final newline)"; return 4; }
  while IFS= read -r line; do
    n=$(( n + 1 ))
    if [ "$n" -eq 1 ]; then
      [ "$line" = "adb-selfcheck-run 1" ] || { STOP_WHY="$RUN_RECORD is not a version-1 run record"; return 4; }
      continue
    fi
    k="${line%% *}"; v="${line#* }"
    [ "$k" != "$line" ] || { STOP_WHY="line $n of $RUN_RECORD has no value"; return 4; }
    case "$k" in
      pid|pgid|epoch|grace|prep|root|tmp)
        case "$got" in *" $k "*) STOP_WHY="$RUN_RECORD names its $k twice"; return 4 ;; esac
        got="$got$k " ;;
    esac
    case "$k" in
      pid)   _stop_num "$v" || { STOP_WHY="$RUN_RECORD's pid is not a number"; return 4; }; r_pid="$v" ;;
      pgid)  _stop_num "$v" || { STOP_WHY="$RUN_RECORD's pgid is not a number"; return 4; }; r_pgid="$v" ;;
      epoch) _stop_num "$v" || { STOP_WHY="$RUN_RECORD's epoch is not a number"; return 4; }; r_epoch="$v" ;;
      grace) _stop_num "$v" 9 || { STOP_WHY="$RUN_RECORD's grace is not a number the runner could write"; return 4; }; r_grace="$v" ;;
      prep)  _stop_num "$v" 9 || { STOP_WHY="$RUN_RECORD's prep is not a number the runner could write"; return 4; }; r_prep="$v" ;;
      root)  _stop_path_ok "$v" && r_root="$v" \
               || { STOP_WHY="$RUN_RECORD's root is not an absolute path free of control bytes and ^"; return 4; } ;;
      tmp)   _stop_path_ok "$v" && r_tmp="$v" \
               || { STOP_WHY="$RUN_RECORD's tmp is not an absolute path free of control bytes and ^"; return 4; } ;;
      group)
        g="${v%% *}"; e="${v#* }"
        { [ "$e" != "$v" ] && _stop_num "$g" && _stop_num "$e"; } \
          || { STOP_WHY="line $n of $RUN_RECORD is not 'group <pgid> <epoch>'"; return 4; }
        if [ -z "${r_groups[$g]+x}" ] || [ "$e" -gt "${r_groups[$g]}" ]; then r_groups["$g"]="$e"; fi ;;
      pool)  _stop_path_ok "$v" && r_pools+=("$v") \
               || { STOP_WHY="line $n of $RUN_RECORD names a pool that is not an absolute path free of control bytes and ^"; return 4; } ;;
      *) STOP_WHY="line $n of $RUN_RECORD has a key no run record carries"; return 4 ;;
    esac
  done < "$STOP_DIR/record"
  for k in pid epoch grace prep root tmp; do
    case "$got" in *" $k "*) ;; *) STOP_WHY="$RUN_RECORD has no $k"; return 4 ;; esac
  done
  [ "$r_root" = "$STOP_ROOT" ] \
    || { STOP_WHY="$RUN_RECORD is for $(_stop_clean "$r_root"), not this checkout"; return 4; }
  # A temp root that IS the checkout, or holds it, would make every process in the checkout the run's;
  # so would a pool that holds it. A pool that holds the temp root is not a pool either: the root
  # existed before any step ran, and every pool is a directory made after it.
  if _stop_under "$r_root" "$r_tmp"; then
    STOP_WHY="$RUN_RECORD's temp root $(_stop_clean "$r_tmp") is or contains the checkout"; return 4
  fi
  for d in "${r_pools[@]}"; do
    if _stop_under "$r_root" "$d" || _stop_under "$r_tmp" "$d"; then
      STOP_WHY="$RUN_RECORD registers a pool, $(_stop_clean "$d"), that is or contains the checkout or the run's temp root"; return 4
    fi
  done
  REC_MTIME="$r_mtime"
  REC_PID="$r_pid"; REC_PGID="$r_pgid"; REC_EPOCH="$r_epoch"; REC_GRACE="$r_grace"; REC_PREP="$r_prep"
  REC_ROOT="$r_root"; REC_TMP="$r_tmp"
  REC_GROUPS=()
  for g in "${!r_groups[@]}"; do REC_GROUPS["$g"]="${r_groups[$g]}"; done
  REC_POOLS=("${r_pools[@]}")
  return 0
}

# _stop_reread <pid> <epoch> — the record again, mid-stop: the runner records a worker it forked
# after the stop's first read, and a harness a pool it opened. The same run, or a refusal: a record
# now naming another run means one started in this checkout during the stop (two runs in one checkout
# are unsupported; see the concurrency contract above). A record the
# runner removed on a clean exit leaves the last good read in force.
_stop_reread() {
  local rc n=0
  # An append caught half-written fails the whole-record rule for an instant: read again, briefly,
  # before that counts as a refusal.
  while :; do
    _stop_read_record; rc=$?
    [ "$rc" -eq 4 ] && [ "$n" -lt 5 ] || break
    n=$(( n + 1 )); sleep 0.1
  done
  [ "$rc" -eq 5 ] && return 0
  [ "$rc" -eq 0 ] || return 1
  [ "$REC_PID" = "$1" ] && [ "$REC_EPOCH" = "$2" ] && return 0
  STOP_WHY="$RUN_RECORD now names another run (pid $REC_PID) — one started in this checkout during the stop"
  return 1
}

# _stop_pass — one fresh look, the same in every loop of the stop: the inventory, the runner's state,
# and what the run owns. 0, or 1 with the refusal already printed (the caller answers 4): a runner ps
# can no longer date is lost track of, never dropped from what the run owns.
_stop_pass() {
  _stop_inventory || { _stop_blind; return 1; }   # row-stop-fresh
  _stop_runner
  [ "$RUNNER_STATE" = unknown ] && { printf 'selfcheck --stop: lost track of the run (pid %s): ps gave it no start time\n' "$REC_PID"; return 1; }
  _stop_owned || { INV_ERR="$OWN_ERR"; _stop_blind; return 1; }
}

_stop_blind() {
  printf 'selfcheck --stop: cannot inspect this machine'"'"'s processes: %s. Nothing further is signalled, and nothing here says the run left nothing behind. Run the stop from an unsandboxed shell.\n' "$INV_ERR"
}

# _stop_line <pid> — one survivor, by what the inventory says of it.
_stop_line() {
  local p="$1" st="${INV_STAT[$1]:-?}" tag=""
  case "$st" in T*|t*) tag=' (STOPPED)' ;; esac
  case "$st" in
    Z*) printf 'selfcheck --stop: zombie   pid=%s pgid=%s ppid=%s state=%s — exited; it goes when pid %s reaps it (%s)\n' \
          "$p" "${INV_PGID[$p]:-?}" "${INV_PPID[$p]:-?}" "$(_stop_clean "$st")" "${INV_PPID[$p]:-?}" "${OWNED[$p]:-}" ;;
    # The first word of the command line only, never the arguments: an argv can carry a credential,
    # and a process being the run's does not make what it was handed safe to print.
    *)  printf 'selfcheck --stop: survivor pid=%s pgid=%s ppid=%s state=%s%s — %s; cwd %s; %s\n' \
          "$p" "${INV_PGID[$p]:-?}" "${INV_PPID[$p]:-?}" "$(_stop_clean "$st")" "$tag" "${OWNED[$p]:-}" \
          "$(_stop_clean "${INV_CWD[$p]:-?}")" "$(_stop_clean "${INV_CMD[$p]%% *}")" ;;
  esac
}

# _stop_drop — remove the record once nothing it describes is left, unless it is no longer the bytes
# last read: a record that changed belongs to whatever changed it. The comparison is made under the
# lock the removal holds (`adb_record_remove --if`), the lock every append takes, so nothing lands
# between them. The incomplete marker is never removed here: the stop gets here only when there was
# none, and one written since stays — on its own it still answers 4 (`stop_run`).
#
# Nothing the record NAMES is ever deleted — not the run's temp root either: a path read from a file
# is not proof of what it resolves to, and a runner that was KILLed leaves its scratch directories to
# the system's temp cleaner rather than to an `rm -rf` this stop would have to trust.
#
# 0 removed · 3 kept, because it changed after the stop last read it: something was recorded that
# this stop never looked at, so its caller may not call the run clean · 4 kept, because it could not
# be compared · 1 kept, because the removal failed (said here).
_stop_drop() {
  local rc=0
  adb_record_remove --if _stop_unchanged "$RUN_RECORD" || rc=$?   # row-drop-locked
  case "$rc" in
    0|3|4) return "$rc" ;;
  esac
  printf 'selfcheck --stop: NOTE — could not remove %s; a later --stop will find this run again\n' "$RUN_RECORD"
  return 1
}
# _stop_unchanged <file> — still the bytes this stop read. A record that is GONE counts as unchanged:
# its runner removes it on a clean exit (`_rec_drop`), and there is then nothing to keep. The
# comparison is bounded, since it runs under the lock: a FIFO put where the record was would hold
# that lock for as long as nothing wrote to it.
_stop_unchanged() {
  [ -e "$1" ] || [ -L "$1" ] || return 0   # row-drop-gone
  adb_run_bounded "$STOP_INSPECT" 1 cmp -s "$STOP_DIR/record" "$1" 2>/dev/null   # row-drop-bounded
}

# _stop_marked — the incomplete marker is here, in ANY shape: a directory, a FIFO or a dangling link
# at its name is not a regular file, but it is not an absent marker either.
_stop_marked() { [ -e "$RUN_RECORD.incomplete" ] || [ -L "$RUN_RECORD.incomplete" ]; }   # row-marker-any-shape

# _stop_unattributed [print] — UNATTRIBUTED: the processes of the current inventory that are not the
# run's but work in its checkout and started during it; with `print`, each is named — by the first
# word of its command line only — as never signalled. Asked again of the FINAL inventory before the record is disposed of, so
# a process that only became unattributed during removal still keeps the record.
_stop_unattributed() {
  local p
  _stop_enc "$REC_ROOT"
  UNATTRIBUTED=0
  for p in $(printf '%s\n' "${!INV_PGID[@]}" | sort -n); do
    [ -n "${OWNED[$p]+x}" ] && continue
    _stop_shielded "$p" && continue
    case "${INV_STAT[$p]}" in Z*) continue ;; esac
    [ -n "${INV_START[$p]:-}" ] && [ "${INV_START[$p]}" -ge $(( REC_EPOCH - 2 - STOP_SKEW )) ] || continue
    _stop_under "${INV_CWD[$p]:-}" "$_ENC" || continue
    # Named once per PROCESS, pid and start together: a pid reused by another process is a new one.
    if [ "${1:-}" = print ] && [ -z "${STOP_NAMED[$p ${INV_LST[$p]:-}]+x}" ]; then
      printf 'selfcheck --stop: NOTE — pid=%s pgid=%s works in this checkout and started during the run, but nothing ties it to the run; NOT signalled: %s\n' \
        "$p" "${INV_PGID[$p]}" "$(_stop_clean "${INV_CMD[$p]%% *}")"
      STOP_NAMED["$p ${INV_LST[$p]:-}"]=1
    fi
    UNATTRIBUTED=$(( UNATTRIBUTED + 1 ))
  done
  return 0
}

# _stop_verify_runner — REC_PID is, this instant, the process the inventory dated as the runner.
_stop_verify_runner() {
  local e l1 l2 l3 l4 l5
  e="$(adb_run_bounded "$STOP_INSPECT" 1 env LC_ALL=C ps -o lstart= -p "$REC_PID" 2>/dev/null)" || return 1
  read -r l1 l2 l3 l4 l5 <<< "$e"
  _stop_same "$REC_PID" "$l1 $l2 $l3 $l4 $l5"
}

stop_run() {
  local rc p g dl n first_pid first_epoch bound incomplete=0
  local -a groups=()
  STOP_ROOT="$(pwd -P; printf x)"; STOP_ROOT="${STOP_ROOT%$'\n'x}"
  STOP_DIR="$(mktemp -d)" || { printf 'selfcheck --stop: cannot create a scratch directory\n'; return 4; }
  trap 'rm -rf "$STOP_DIR"' EXIT
  _stop_read_record; rc=$?
  case "$rc" in
    0) ;;
    5) # …unless its incomplete marker is here: something of the last run could not be recorded, so
       # "no run" is not "nothing left" (the marker outlives a record removed after it was written).
       if _stop_marked; then   # row-incomplete-alone
         printf 'selfcheck --stop: cannot call this clean — no run is recorded, but %s.incomplete is here: something of the last run could not be recorded, so nothing says it left nothing behind. Look for what it left, then remove the marker.\n' "$RUN_RECORD"
         return 4
       fi
       printf 'selfcheck --stop: no run is recorded in this checkout (%s is absent) — nothing was stopped or checked\n' "$RUN_RECORD"
       return 5 ;;
    *) printf 'selfcheck --stop: cannot stop — %s. Nothing was signalled.\n' "$STOP_WHY"; return 4 ;;
  esac
  first_pid="$REC_PID"; first_epoch="$REC_EPOCH"
  # The bound is the operator's, but never shorter than what the RUN was promised: a cancelled runner
  # may spend up to its recorded `prep` recording what it owns before its workers even get the TERM,
  # then gives them its recorded grace, then exits — so a stop started from another shell waits at
  # least prep + grace + the margin, and never KILLs into a cleanup still inside its allowance.
  bound="$STOP_SECS"
  if [ "$bound" -lt $(( REC_PREP + REC_GRACE + STOP_MARGIN_SECS )) ]; then   # row-run-grace
    bound=$(( REC_PREP + REC_GRACE + STOP_MARGIN_SECS ))
    printf 'selfcheck --stop: the run may take %ss to record what it owns and gives its workers %ss to clean up, so the bound is %ss rather than ADB_SELFCHECK_STOP_SECS=%s\n' \
      "$REC_PREP" "$REC_GRACE" "$bound" "$STOP_SECS"
  fi
  _stop_inventory || { _stop_blind; return 4; }
  _stop_shield
  _stop_runner
  [ "$RUNNER_STATE" = live ] && STOP_RUNNER_PGID="${INV_PGID[$REC_PID]}"
  # WHAT THE RUN OWNS IS TAKEN NOW, before anything is signalled: the TERM is what reparents a nested
  # pool's workers and makes a pool process exit, and after it only this stop's memory ties them to
  # the run.
  _stop_owned || { INV_ERR="$OWN_ERR"; _stop_blind; return 4; }   # row-own-first
  case "$RUNNER_STATE" in
    live)
      # Its group is the caller's whenever it ran without job control: never signal it as a group.
      STOP_SHIELD_PGID["${INV_PGID[$REC_PID]}"]=1
      if _stop_verify_runner && kill -TERM "$REC_PID" 2>/dev/null; then
        printf 'selfcheck --stop: sent TERM to the run (pid %s); waiting up to %ss for it and everything it owns to finish\n' \
          "$REC_PID" "$bound"
      elif adb_pid_gone "$REC_PID"; then
        # It ended between the inventory and the signal, so it ran its own cleanup: just wait.
        printf 'selfcheck --stop: the run (pid %s) exited as it was being stopped; waiting up to %ss for what it owns\n' \
          "$REC_PID" "$bound"
      else
        printf 'selfcheck --stop: the run (pid %s) is alive but could not be sent TERM — nothing was signalled\n' "$REC_PID"
        return 4
      fi ;;
    gone)
      # The TERM its own `_cleanup` would have sent — and more: to EVERY group holding something the
      # run owns, recorded or not, so a pool's workers get their cleanup before any KILL comes.
      groups=()
      for p in "${!OWNED[@]}"; do
        [ "$p" = "$REC_PID" ] && continue
        case "${INV_STAT[$p]:-}" in Z*) continue ;; esac
        groups+=("${INV_PGID[$p]}")   # row-term-owned
      done
      [ "${#groups[@]}" -eq 0 ] || mapfile -t groups < <(printf '%s\n' "${groups[@]}" | sort -un)
      printf 'selfcheck --stop: the run (pid %s) has already exited; sending TERM to what it owns in %s process group(s), then waiting up to %ss\n' \
        "$REC_PID" "${#groups[@]}" "$bound"
      [ "${#groups[@]}" -eq 0 ] || _stop_signal TERM "${groups[@]}" ;;
    *)
      printf 'selfcheck --stop: cannot tell whether pid %s is still the run — ps gave it no start time. Nothing was signalled.\n' "$REC_PID"
      return 4 ;;
  esac

  # THE BOUND. Every pass re-reads the record and takes a fresh inventory: a process started, or
  # reparented, after the TERM is on the next pass's list and no earlier one's.
  dl=$(( BASH_MONOSECONDS + bound ))
  while :; do
    _stop_reread "$first_pid" "$first_epoch" \
      || { printf 'selfcheck --stop: cannot finish — %s\n' "$STOP_WHY"; return 4; }
    _stop_pass || return 4
    [ "$OWN_ALIVE" -eq 0 ] && break
    [ "$BASH_MONOSECONDS" -ge "$dl" ] && break
    sleep 0.5
  done
  _stop_marked && incomplete=1

  _stop_unattributed print

  if [ "$OWN_ALIVE" -eq 0 ]; then
    for p in $(printf '%s\n' "${!OWNED[@]}" | sort -n); do _stop_line "$p"; done
    if [ "$incomplete" -eq 1 ]; then   # row-incomplete
      printf 'selfcheck --stop: cannot call this clean — %s.incomplete says a worker or a pool of this run could not be recorded, so what the stop could not attribute it could not check\n' "$RUN_RECORD"
      return 4
    fi
    # NOT CLEAN EITHER, when processes that started during the run still work in its checkout and
    # nothing ties them to it (the owner's call on #551): they are named above and never signalled,
    # and a worker started in a cleanup trap can look exactly like that. The record is kept.
    if [ "$UNATTRIBUTED" -gt 0 ]; then   # row-unattributed
      printf 'selfcheck --stop: NOT CLEAN — nothing provably the run'"'"'s outlived the %ss bound, but %s process(es) named above started during the run and still work in this checkout; they were not signalled, and the record is kept\n' \
        "$bound" "$UNATTRIBUTED"
      return 6
    fi
    # The verdict follows the removal: a registration that failed while it was made marks the run
    # incomplete then, and one that succeeded changed the record; a stop that answered first would
    # have called either clean.
    _stop_drop; rc=$?
    case "$rc" in
      3) printf 'selfcheck --stop: cannot call this clean — %s changed after this stop last read it: something was recorded that it never looked at. The record is kept; run --stop again.\n' "$RUN_RECORD"
         return 4 ;;   # row-clean-changed
      4) printf 'selfcheck --stop: cannot call this clean — %s could not be compared with what this stop read, so it is kept; run --stop again.\n' "$RUN_RECORD"
         return 4 ;;
      1) printf 'selfcheck --stop: cannot call this clean — %s could not be locked, compared or removed; it may still be there, so run --stop again.\n' "$RUN_RECORD"
         return 4 ;;   # row-clean-unlocked
    esac
    if _stop_marked; then   # row-clean-after-drop
      printf 'selfcheck --stop: cannot call this clean — %s.incomplete appeared while the record was being removed: something of this run could not be recorded\n' "$RUN_RECORD"
      return 4
    fi
    printf 'selfcheck --stop: stopped clean — nothing the run owns outlived the %ss bound\n' "$bound"
    return 0
  fi

  printf 'selfcheck --stop: %s process(es) the run owns outlived the %ss bound:\n' "$OWN_ALIVE" "$bound"
  for p in $(printf '%s\n' "${!OWNED[@]}" | sort -n); do _stop_line "$p"; done
  [ "$incomplete" -eq 1 ] && printf 'selfcheck --stop: NOTE — %s.incomplete says something of this run could not be recorded; there may be more than these\n' "$RUN_RECORD"

  # REMOVAL, through the one rule in `_stop_signal`. KILL reaches a stopped process (a TERM would sit
  # pending until it was continued). The runner, and anything in a shielded group, goes by pid.
  groups=()
  for p in "${!OWNED[@]}"; do
    case "${INV_STAT[$p]:-}" in Z*) continue ;; esac
    if [ "$p" = "$REC_PID" ]; then _stop_verify_runner && kill -KILL "$p" 2>/dev/null; continue; fi
    groups+=("${INV_PGID[$p]}")
  done
  if [ "${#groups[@]}" -gt 0 ]; then
    mapfile -t groups < <(printf '%s\n' "${groups[@]}" | sort -un)
    _stop_signal KILL "${groups[@]}"
  fi

  # …and a FRESH inventory says whether it worked — never the list the KILLs were sent from.
  n="$OWN_ALIVE"
  dl=$(( BASH_MONOSECONDS + STOP_SETTLE_SECS ))
  while :; do
    sleep 0.2
    _stop_pass || return 4
    [ "$OWN_ALIVE" -eq 0 ] && break
    [ "$BASH_MONOSECONDS" -ge "$dl" ] && break
  done
  if [ "$OWN_ALIVE" -gt 0 ]; then
    printf 'selfcheck --stop: RED — %s process(es) the run owns are still alive %ss after KILL:\n' "$OWN_ALIVE" "$STOP_SETTLE_SECS"
    for p in $(printf '%s\n' "${!OWNED[@]}" | sort -n); do _stop_line "$p"; done
    return 3
  fi
  printf 'selfcheck --stop: RED — %s process(es) the run owns outlived the %ss bound; named above, and now removed\n' "$n" "$bound"
  # The disposition is decided on what is true NOW, not on what was true before the KILLs: the
  # marker may have appeared, and a process may have become unattributed, while they went out.
  _stop_marked && incomplete=1   # row-final-refresh
  _stop_unattributed print
  # An INCOMPLETE record outlives the stop: what it could not attribute may still be running, and
  # removing the record would turn the next stop's answer into "no run recorded".
  if [ "$incomplete" -eq 1 ]; then   # row-incomplete-kept
    printf 'selfcheck --stop: the record is incomplete, so it is KEPT — something of this run could not be recorded and may still be running\n'
  elif [ "$UNATTRIBUTED" -gt 0 ]; then
    printf 'selfcheck --stop: the record is KEPT — the processes named as not tied to the run may still be its own\n'
  else
    _stop_drop; rc=$?
    [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ] \
      && printf 'selfcheck --stop: the record is KEPT — it changed, or could not be compared, after this stop last read it; what was recorded since was never checked, so run --stop again\n'
  fi
  return 1   # row-stop-red
}

# SELECTION IS VALIDATED BEFORE THE TERMINAL MODES, and the order is the fix for a real hole
# (found in review). With the modes first, `--skip does-not-exist --list` and
# `--skip does-not-exist --summarize f` both exited 0: the unknown name was never looked at,
# because the code that looks at it ran after the exit. A contract that holds only when no other
# flag is present is not the contract these flags document.
declare -a SELECTED=()
if [ "$ONLY_GIVEN" -eq 1 ]; then
  declare -A _want=()
  IFS=, read -r -a _only_names <<< "$ONLY"
  for _n in "${_only_names[@]}"; do
    [ -n "$_n" ] || continue
    [ -n "${STEP_CMD[$_n]+x}" ] || { printf 'selfcheck: --only names an unknown step: %s\n' "$_n" >&2; exit 2; }
    _want["$_n"]=1
  done
  for _s in "${STEP_ORDER[@]}"; do [ -n "${_want[$_s]+x}" ] && SELECTED+=("$_s"); done
  [ "${#SELECTED[@]}" -gt 0 ] || { echo "selfcheck: --only selected no steps" >&2; exit 2; }
else
  SELECTED=("${STEP_ORDER[@]}")
fi

# --skip, subtracted from whatever the selection is by now, so `--only` and `--skip` compose in the
# obvious order: select, then remove. An unknown name EXITS for the same reason `--only`'s does —
# a filter naming a step that no longer exists is a stale invocation, and silently honouring it
# would drop the guard the caller thought it was keeping.
#
# A name that IS registered but is not in the current selection is NOT an error: `--only a --skip b`
# asked for a to run and b not to, and b is not running. That composes; it does not silently
# no-op.
declare -a SKIPPED=()
if [ "$SKIP_GIVEN" -eq 1 ]; then
  declare -A _drop=()
  IFS=, read -r -a _skip_names <<< "$SKIP"
  for _n in "${_skip_names[@]}"; do
    [ -n "$_n" ] || continue
    [ -n "${STEP_CMD[$_n]+x}" ] || { printf 'selfcheck: --skip names an unknown step: %s\n' "$_n" >&2; exit 2; }
    _drop["$_n"]=1
  done
  # `--skip ""` and `--skip ,,` both land here having named nothing. See the parser's note: a skip
  # flag that skips nothing is the mirror of `--only ""` running everything, and neither may pass.
  [ "${#_drop[@]}" -gt 0 ] || { echo "selfcheck: --skip named no steps" >&2; exit 2; }
  declare -a _kept=()
  for _s in "${SELECTED[@]}"; do
    if [ -n "${_drop[$_s]+x}" ]; then SKIPPED+=("$_s"); else _kept+=("$_s"); fi
  done
  [ "${#_kept[@]}" -gt 0 ] || { echo "selfcheck: --skip removed every step" >&2; exit 2; }
  SELECTED=("${_kept[@]}")
fi


# --stop is the third terminal mode, and like the other two it composes with neither.
if [ "$STOP" -eq 1 ] && { [ "$LIST" -eq 1 ] || [ "$SUMMARIZE_GIVEN" -eq 1 ]; }; then
  echo "selfcheck: --stop, --list and --summarize are terminal modes; pick one" >&2; exit 2
fi

if [ "$SUMMARIZE_GIVEN" -eq 1 ]; then
  [ "$LIST" -eq 0 ] || { echo "selfcheck: --list and --summarize are both terminal modes; pick one" >&2; exit 2; }
  [ -n "$SUMMARIZE" ] || { echo "selfcheck: --summarize needs a file, got an empty path" >&2; exit 2; }
  summarize_run "$SUMMARIZE"
  exit $?
fi

if [ "$LIST" -eq 1 ]; then
  # FIVE TAB-separated fields: name, command, whether it runs in the serial prologue, WHY, and the
  # step's input set.
  #
  # The third is here so a guard can ask the runner which steps are pinned instead of grepping the
  # arrays out of this file — and, unlike a grep, asking cannot pass while the array it read has
  # stopped being the one the dispatcher consults.
  #
  # The fourth arrived with the second lane (#423) and the split matters: field 3 keeps its exact
  # original meaning, so `$3 == "serial"` still answers "does this run in the prologue" correctly
  # rather than silently answering it for only one of the two lanes. Widening field 3 into a
  # three-valued lane name would have made every existing correct query wrong without erroring,
  # which is the silent-wrong-answer shape this suite exists to prevent. The REASON goes in a new
  # field instead: `concurrent` | `mutates-tree` | `load-sensitive`.
  #
  # The FIFTH is the step's declared input set (#441), comma-joined, or `-` when the step declares
  # none. Appended rather than folded into an existing field for the reason the fourth was: every
  # consumer asking `$3`/`$4` keeps its answer, and a consumer that wants the inputs asks `$5`.
  for _s in "${STEP_ORDER[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$_s" "${STEP_CMD[$_s]}" "$(lane_of "$_s")" "$(lane_reason "$_s")" \
      "${STEP_INPUTS[$_s]:--}"
  done
  exit 0
fi

# THE GRACE, THE STOP'S BOUND AND ITS INSPECTION BOUND (#551), validated after --list and
# --summarize, which use none of them. The grace is how long `_cleanup` lets the workers' own
# cleanup run before it KILLs what is left, and the run records it. The bound is how long `--stop`
# waits before it names survivors — never less than the RUN's recorded grace plus a margin, which
# `stop_run` enforces against the record, since the stopper's environment is not the run's. The
# inspection bound caps each `ps`, `find` or `lsof` the stop runs.
STOP_GRACE="$(_adb_pos_int "${ADB_SELFCHECK_STOP_GRACE_SECS:-10}")" || {
  echo "selfcheck: ADB_SELFCHECK_STOP_GRACE_SECS must be a positive integer of seconds, got '${ADB_SELFCHECK_STOP_GRACE_SECS:-}'" >&2
  exit 2
}
STOP_SECS="$(_adb_pos_int "${ADB_SELFCHECK_STOP_SECS:-40}")" || {
  echo "selfcheck: ADB_SELFCHECK_STOP_SECS must be a positive integer of seconds, got '${ADB_SELFCHECK_STOP_SECS:-}'" >&2
  exit 2
}
STOP_INSPECT="$(_adb_pos_int "${ADB_SELFCHECK_STOP_INSPECT_SECS:-20}")" || {
  echo "selfcheck: ADB_SELFCHECK_STOP_INSPECT_SECS must be a positive integer of seconds, got '${ADB_SELFCHECK_STOP_INSPECT_SECS:-}'" >&2
  exit 2
}

if [ "$STOP" -eq 1 ]; then
  stop_run
  exit $?
fi

[ "$JOBS" -gt 0 ] || JOBS="$(adb_pool_size)"

# THE OVERRUN CEILING (#445). `wait -n` has no timeout and the result block prints only once every
# step has finished, so neither can say that a step has hung. A TICKER does: a `sleep` job the
# dispatcher reaps like any worker, after which it names every step past the ceiling and starts the
# next tick. It reports and never kills — the per-row deadline in check-lib.sh is what turns a hung
# mutant into a verdict, and a step killed here would trade a hang for a red the step did not earn.
# Validated here, after the terminal modes, so `--list` and `--summarize` never depend on it.
OVERRUN="$(_adb_pos_int "${ADB_SELFCHECK_OVERRUN_SECS:-1800}")" || {
  echo "selfcheck: ADB_SELFCHECK_OVERRUN_SECS must be a positive integer of seconds, got '${ADB_SELFCHECK_OVERRUN_SECS:-}'" >&2
  exit 2
}
# A minute between looks, or the ceiling itself when it is shorter: a hung step is named within a
# minute of crossing it, and a short ceiling (the guard's fixtures) is still observed on time.
OVERRUN_TICK=60
[ "$OVERRUN" -lt "$OVERRUN_TICK" ] && OVERRUN_TICK="$OVERRUN"

# --only, applied to the declared order so the selection keeps it. An unknown name EXITS rather
# than being skipped: a filter that quietly matches nothing runs zero checks and reports the same
# clean verdict a full green run reports (base/practices/self-review.md).
WORK="$(mktemp -d)" || { echo "selfcheck: FATAL — cannot create a scratch directory" >&2; exit 2; }

# THE RUN'S PRIVATE TEMP ROOT (#551), exported to every step as TMPDIR. A `mktemp` that honours
# TMPDIR — GNU's always, macOS's only when given a template — lands under one directory whose random
# name is unique to this run, which lets `--stop` say a process is the run's by where it works. A
# template-less `mktemp -d` on macOS does NOT land here (it prefers the per-user temp directory), so
# the harness pools register their directories as well (`check_register_pool`). It is PHYSICAL
# because the cwd listings report physical paths: macOS's /var/folders is /private/var/folders to
# lsof. Removed with WORK on the way out; a process still working in it is still the run's.
#
# Both paths are captured with a sentinel, so a trailing newline is kept and refused, not stripped
# into a different name.
_tmp_raw="$(mktemp -d "${TMPDIR:-/tmp}/adb-selfcheck.XXXXXX")" \
  || { echo "selfcheck: FATAL — cannot create the run's private temp root" >&2; rm -rf "$WORK"; exit 2; }
TMPROOT="$(cd -P "$_tmp_raw" && pwd -P && printf x)" \
  || { echo "selfcheck: FATAL — cannot resolve the run's private temp root" >&2; rm -rf "$WORK" "$_tmp_raw"; exit 2; }
TMPROOT="${TMPROOT%$'\n'x}"
export TMPDIR="$TMPROOT"
RUN_ROOT="$(pwd -P; printf x)"; RUN_ROOT="${RUN_ROOT%$'\n'x}"
RUN_EPOCH="$EPOCHSECONDS"
REC_OK=0
REC_WHY=""
REC_CANCEL_DONE=0
REC_HOLD=0; REC_SIG=""   # inside an append to the record, and the signal that arrived meanwhile
# A cancelled runner records what it owns before it signals (`_rec_descendants`), under one deadline
# (REC_PREP_DL) of REC_PREP_SECS: the stop's own inventory — three reads, each bounded at
# REC_INSPECT_SECS (a fifth of ADB_SELFCHECK_STOP_INSPECT_SECS, 4s at its default 20) plus the 1s
# kill grace — and 3s for what it then computes and writes. The record carries that allowance, and
# `--stop` waits it out before the grace, so it never KILLs a cleanup that has not started yet.
REC_INSPECT_SECS=$(( STOP_INSPECT / 5 )); [ "$REC_INSPECT_SECS" -ge 1 ] || REC_INSPECT_SECS=1
REC_PREP_SECS=$(( 3 * (REC_INSPECT_SECS + 1) + 3 ))
REC_PREP_DL=""
declare -A REC_DONE=()   # pid -> 1 once its `group` line is written, until that pid is reaped: a
                         # reaped number can be reused by a group that is not recorded yet

# _rec_append <line> — one line onto the record through `adb_record_append` (common.sh), the ONE
# locked writer this record has: the runner's lines and every harness's `pool` line go through it.
# Its lock wait is 5s, cut to what is left of a cancelled runner's `prep` (REC_PREP_DL) while one is
# running, so recording can never eat into the grace a stop has promised its workers.
_rec_append() {
  local tries=100 left rc=0
  if [ -n "${REC_PREP_DL:-}" ]; then
    left=$(( REC_PREP_DL - BASH_MONOSECONDS ))
    [ "$left" -gt 0 ] || return 1
    [ $(( left * 20 )) -lt "$tries" ] && tries=$(( left * 20 ))
  fi
  _rec_held adb_record_append "$RUN_ROOT/$RUN_RECORD" "$1" "$tries" "${REC_PREP_DL:-}" || rc=$?   # non-zero (2 included) is a failure here
  return "$rc"
}

# _rec_held <command…> — run <command> as one critical section of the record's lock. A cancellation
# landing meanwhile waits for it (`_on_signal`): handled at once, its own recording would wait on the
# lock this very process holds, give up and mark the whole record incomplete, and its `exit` would
# leave the lock held for every later writer.
_rec_held() {
  local rc=0 sig
  REC_HOLD=1
  "$@" || rc=$?
  REC_HOLD=0
  if [ -n "$REC_SIG" ]; then sig="$REC_SIG"; REC_SIG=""; _on_signal "$sig"; fi
  return "$rc"
}

# _rec_mark_incomplete <why> — leave `.selfcheck-run.incomplete`, and SAY whether that worked: a
# marker that could not be written is a record that still looks complete, which the operator must
# be told in so many words.
_rec_mark_incomplete() {
  if adb_mark_present "$RUN_ROOT/$RUN_RECORD.incomplete"; then
    printf 'selfcheck: NOTE — %s; the run record is marked incomplete, so `--stop` will not call this run clean\n' "$1"
  else
    printf 'selfcheck: WARN — %s, AND the run record could not be marked incomplete: a later `--stop` may call this run clean without having seen all of it\n' "$1"
  fi
}

# _rec_write — publish the run record (#551) by rename, owner-only, so `--stop` never reads half of
# one. Fields: the runner's pid and start, the checkout, the temp root; `group` lines follow as
# workers fork, and `pool` lines as harnesses register theirs. A path holding a newline cannot be
# one line, so it is refused rather than written.
#
# A RECORD ALREADY HERE is another run's, and it is replaced only once that run has provably exited
# (`adb_pid_gone`: the kernel's ESRCH, never a failed read). The case that is not hypothetical is
# the turn-end gate (`.claude/scripts/precommit-gate.sh`), which runs a short `--only` selfcheck in
# this checkout while a long one may be running in the background: replacing the long run's record,
# and then removing it on the way out, would leave that run with no record for `--stop` to find.
# Two runs in one checkout stay unsupported (the concurrency contract above); this keeps the second
# from erasing the first.
# A record whose runner HAS exited was left by a run that did not end on its own; replacing it is
# said, because what that run left is now only findable by working directory.
#
# The decision about a record already here and the publication that replaces it hold the record's
# lock, the one every removal takes: a stop comparing the record it read before removing it must
# never remove one this run has just published in between.
_rec_write() {
  REC_WHY=""
  _rec_held _rec_write_locked
}
_rec_write_locked() {
  local rc=0
  adb_record_lock "$RUN_ROOT/$RUN_RECORD" 200 || { REC_WHY="its lock could not be had in 10s"; return 1; }   # row-write-locked
  _rec_publish || rc=$?
  if ! adb_record_unlock "$RUN_ROOT/$RUN_RECORD"; then   # row-write-unlock
    printf 'selfcheck: WARN — the run record'"'"'s lock could not be released, so every later write to the record waits until this run has exited and the lock is taken over\n'
  fi
  return "$rc"
}
_rec_publish() {
  local t old="" own_pg
  _stop_path_ok "$RUN_ROOT" && _stop_path_ok "$TMPROOT" \
    || { REC_WHY="the checkout or the temp root holds a control byte or a ^, which no record may"; return 1; }
  # A DIRECTORY, a symlink, a FIFO — anything but a regular file — at the record's name is refused
  # BEFORE it is opened: `mv` would publish INTO a directory, and reading a FIFO would block the run.
  if [ -L "$RUN_ROOT/$RUN_RECORD" ] || { [ -e "$RUN_ROOT/$RUN_RECORD" ] && [ ! -f "$RUN_ROOT/$RUN_RECORD" ]; }; then   # row-record-dir
    REC_WHY="$RUN_RECORD is not a regular file (a directory, a symlink or a FIFO)"; return 1
  fi
  if [ -e "$RUN_ROOT/$RUN_RECORD" ]; then
    # Its runner must be IDENTIFIED before anything replaces it: a record that cannot be read, or
    # whose second line is not `pid N`, is refused rather than taken for absent.
    # A read that FAILED says nothing, whatever it printed first: "pid 123" cut short is "pid 12".
    old="$(head -c 4096 "$RUN_ROOT/$RUN_RECORD" 2>/dev/null)" || old=""   # row-old-read
    old="${old#*$'\n'}"; old="${old%%$'\n'*}"
    case "$old" in pid\ [1-9]*) old="${old#pid }" ;; *) old="" ;; esac
    if ! _stop_num "$old"; then   # row-old-record
      REC_WHY="an existing $RUN_RECORD could not be read, so the run it names could not be shown to have exited — \`--stop\` sweeps and removes it"
      return 1
    fi
    if [ -n "$old" ] && [ "$old" != "$$" ] && ! adb_pid_gone "$old"; then
      REC_WHY="another run (pid $old) is recorded in this checkout and has not provably exited, so this run is not recorded and \`--stop\` cannot find it (two runs in one checkout are not supported)"
      return 1
    fi
    [ -n "$old" ] && [ "$old" != "$$" ] \
      && printf 'selfcheck: NOTE — replacing the record of an earlier run (pid %s) that did not end on its own; `--stop` before a new run is what sweeps what such a run left\n' "$old"
  fi
  # The runner's own GROUP, when ps can say (a sandbox refuses it): `--stop` never lets that group
  # spread ownership, since without job control it is the caller's (`_stop_closable`).
  own_pg="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')" || own_pg=""
  _stop_num "$own_pg" || own_pg=""
  t="$(mktemp "$RUN_ROOT/$RUN_RECORD.XXXXXX" 2>/dev/null)" || { REC_WHY="its staging file could not be created"; return 1; }
  if { printf 'adb-selfcheck-run 1\npid %s\nepoch %s\ngrace %s\nprep %s\nroot %s\ntmp %s\n' \
         "$$" "$RUN_EPOCH" "$STOP_GRACE" "$REC_PREP_SECS" "$RUN_ROOT" "$TMPROOT" \
       && { [ -z "$own_pg" ] || printf 'pgid %s\n' "$own_pg"; }; } > "$t" 2>/dev/null \
     && chmod 600 "$t" 2>/dev/null \
     && mv -f "$t" "$RUN_ROOT/$RUN_RECORD" 2>/dev/null; then   # row-publish-first
    # An earlier run's incomplete marker goes only once this record has replaced that run's: removed
    # first, a publication that then failed would leave the earlier record looking complete.
    rm -f "$RUN_ROOT/$RUN_RECORD.incomplete" 2>/dev/null
    if [ -e "$RUN_ROOT/$RUN_RECORD.incomplete" ] || [ -L "$RUN_ROOT/$RUN_RECORD.incomplete" ]; then
      printf 'selfcheck: NOTE — an earlier run'"'"'s %s.incomplete could not be removed, so `--stop` will not call this run clean\n' "$RUN_RECORD"
    fi
    REC_OK=1; return 0
  fi
  rm -f "$t" 2>/dev/null
  REC_WHY="it could not be written"
  return 1
}

# _rec_group <pid> — record a worker the runner forked: under `set -m` its pid is its process group.
# The fork's time travels with it, which is how `--stop` tells this group from a newer one that
# later took the same number. Appends are serialized (`_rec_append`), so every line is one writer's.
#
# A worker this cannot record leaves `.selfcheck-run.incomplete`, so a later `--stop` never calls
# the run clean over a group it was never told about; REC_DONE is set only for a line written.
_rec_group() {
  [ "$REC_OK" -eq 1 ] || return 0
  if [ -n "$REC_PREP_DL" ] && [ "$BASH_MONOSECONDS" -ge "$REC_PREP_DL" ]; then
    REC_OK=0
    _rec_mark_incomplete "recording ran past the ${REC_PREP_SECS}s allowance a cancelled run promises, so worker $1 is not in the record"
    return 0
  fi
  if _rec_append "group $1 $EPOCHSECONDS"; then
    REC_DONE["$1"]=1; return 0
  fi
  REC_OK=0
  _rec_mark_incomplete "could not append to the run record $RUN_RECORD, so workers forked from here on are not in it"
}

# _rec_descendants — on CANCELLATION, before anything is signalled: record every process group that
# holds one of this run's processes and is not recorded yet. "This run's" is the stop's own evidence,
# taken while it is still true: a DESCENDANT of the runner — a nested pool's worker, which the TERM
# below will reparent (#547) — or a process WORKING under the run's temp root or a registered pool,
# whose group may hold a holder that was reparented at birth and works in the checkout. After a
# plain ^C nothing else would tie either to the run. Each group goes in with the earliest start
# among its members — the identity `--stop` checks it by. The runner's own group is skipped
# (without job control it is the caller's). A table that cannot be read, or a cwd listing that is
# not whole, marks the record incomplete.
_rec_descendants() {
  [ "$REC_OK" -eq 1 ] && [ "$REC_CANCEL_DONE" -eq 0 ] || return 0
  REC_CANCEL_DONE=1   # once: the signal trap's `_cleanup` and the EXIT trap's both reach here
  local pid g WHY
  local -A seeds=() first=()
  local -a pools=()
  local line rrc=0 snap="$WORK/record.cancel"
  if [ -f "$RUN_ROOT/$RUN_RECORD" ] && [ ! -L "$RUN_ROOT/$RUN_RECORD" ]; then
    adb_run_bounded "$REC_INSPECT_SECS" 1 head -c 1048577 "$RUN_ROOT/$RUN_RECORD" > "$snap" 2>/dev/null || rrc=$?
    # The pools are read from a snapshot that is WHOLE (`adb_bytes_whole`: within the 1 MiB a stop
    # reads, final newline, no NUL) or not at all: a read that failed, ran long or was cut mid-line
    # may have stopped short of a `pool` line, or cut one into a shorter path — a broader directory,
    # whose unrelated processes would then be seeded as the run's.
    if [ "$rrc" -ne 0 ] || ! adb_bytes_whole "$snap" 1048576; then   # row-pool-read
      _rec_mark_incomplete "the run record could not be read whole as the run was cancelled, so the pools it names were not used"
    else   # row-pool-read-discard
      while IFS= read -r line; do
        case "$line" in 'pool '*) pools+=("${line#pool }") ;; esac
      done < "$snap"
    fi
  fi
  # THE STOP'S OWN INVENTORY, taken from the runner's side: the same three bounded reads and the same
  # proof that they are whole, never a weaker copy of it. The record's fields are this run's; the
  # runner's descendants are what is looked for rather than skipped; the reads are bounded tighter
  # and the whole of it by the deadline in REC_PREP_DL.
  local STOP_INSPECT="$REC_INSPECT_SECS" STOP_DIR="$WORK" STOP_FOR_RUNNER=1 STOP_DEADLINE="$REC_PREP_DL"
  local REC_PID="$$" REC_EPOCH="$RUN_EPOCH" REC_ROOT="$RUN_ROOT" REC_TMP="$TMPROOT"
  local -A REC_GROUPS=() OWN_EVER=()
  local -a REC_POOLS=("${pools[@]}")
  local whole=1
  if ! _stop_inventory; then   # row-cancel-whole
    _rec_mark_incomplete "the run's processes could not all be seen as it was cancelled ($INV_ERR)"
    [ -n "${INV_PGID[$$]+x}" ] || return 0
    whole=0
  fi
  # A DESCENDANT of the runner — a nested pool's worker, which the TERM below will reparent (#547) —
  # or a process WORKING under the run's temp root or a registered pool, whose group may hold a holder
  # reparented at birth that works in the checkout. Directories count only from an inventory that was
  # whole: a refused one may pair one process's group with another's directory, while descent comes
  # from the process listing alone.
  for pid in "${!INV_PGID[@]}"; do
    [ "$pid" != "$$" ] || continue
    if [ -n "${STOP_DESC[$pid]+x}" ] || { [ "$whole" -eq 1 ] && _stop_where "$pid"; }; then seeds["${INV_PGID[$pid]}"]=1; fi   # row-cancel-seeds
  done
  # Each seeded group, with the earliest start of ANY of its members, so the leader's start — the
  # identity the stop checks — always falls inside the window it allows. Never the runner's own
  # group, which without job control is its caller's.
  for pid in "${!INV_PGID[@]}"; do
    g="${INV_PGID[$pid]}"
    [ -n "${seeds[$g]+x}" ] && [ "$g" != "${INV_PGID[$$]}" ] && [ -z "${REC_DONE[$g]+x}" ] && [ -n "${INV_START[$pid]:-}" ] || continue
    if [ -z "${first[$g]+x}" ] || [ "${INV_START[$pid]}" -lt "${first[$g]}" ]; then first["$g"]="${INV_START[$pid]}"; fi
  done
  for g in "${!first[@]}"; do   # row-rec-descendants
    if [ "$BASH_MONOSECONDS" -ge "$REC_PREP_DL" ]; then   # row-prep-deadline
      _rec_mark_incomplete "recording the run's process groups ran past its ${REC_PREP_SECS}s allowance"
      return 0
    fi
    if _rec_append "group $g ${first[$g]}"; then
      REC_DONE["$g"]=1
    else
      _rec_mark_incomplete "could not record the run's process groups as it was cancelled"
      return 0
    fi
  done
  return 0
}

# _rec_drop — remove the record on a clean exit, if it is still this run's. A CANCELLED run keeps
# it: whatever it left behind is what a later `--stop` sweeps.
_rec_drop() {
  local rc=0
  [ -f "$RUN_ROOT/$RUN_RECORD" ] && [ ! -L "$RUN_ROOT/$RUN_RECORD" ] || return 0
  _rec_held adb_record_remove --if _rec_ours "$RUN_ROOT/$RUN_RECORD" || rc=$?   # row-rec-drop-locked
  # 3 is a record that is no longer this run's, left to whoever wrote it; anything else (a record it
  # could not read, a removal that failed) leaves a record nothing is running behind.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] \
    || printf 'selfcheck: NOTE — the run record %s could not be removed on the way out; `--stop` will find it and sweep what is left\n' "$RUN_RECORD"
  return 0
}
# _rec_ours <file> — <file> is still this run's record: a regular file whose first three lines name
# this runner. Asked under the record's lock (`adb_record_remove --if`), so a record that replaced
# this one after the check is never removed on the strength of it.
_rec_ours() {
  local l1="" l2="" l3="" h
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  h="$(head -c 4096 "$1" 2>/dev/null)" || return 2   # unread is not "not ours"
  { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; } <<< "$h"
  [ "$l1" = "adb-selfcheck-run 1" ] && [ "$l2" = "pid $$" ] && [ "$l3" = "epoch $RUN_EPOCH" ]
}
declare -A LIVE=()          # pid -> 1, for the signal path
declare -a FAILED=()        # step names, in emission order
declare -a SLOW=()          # "secs name", for the summary
declare -a OVERRAN=()       # step names past the overrun ceiling, in the order the runner noticed them
declare -A OVER_LAST=()     # name -> the last multiple of the ceiling already reported

# Terminate every live worker — the whole PROCESS GROUP, not the pid.
#
# The worker is a subshell that forks `bash scripts/check-<x>.sh`, so signalling the pid alone
# kills the subshell and REPARENTS the check to init, where it runs on unattended: a cancelled run
# that leaves up to $JOBS suites still executing. That is the same orphaning `adb_run_bounded`'s
# watchdog path had until #141, and the pool is where it is cheap to close: `set -m` makes each
# worker its own process-group leader, so `kill -- -$pid` reaches the grandchildren too. This
# pool solved it first; `adb_run_bounded` now reaps the same way, by the same rule.
#
# TERM, then grace, then KILL, matching `_adb_bounded_reap`: a bound that only sends TERM is not a
# backstop, because anything that traps or ignores it survives.
#
# THE GRACE IS A BOUND, NOT A SLEEP (#551). It was a fixed `sleep 1`, so a harness whose own TERM
# cleanup took longer than a second was KILLed in the middle of it — and a vendored-shmutant shell
# KILLed between freezing a mutant's tree and killing it leaves that tree stopped for good
# (BWBama85/shmutant#47). Now the KILL waits until every worker group is gone or
# ADB_SELFCHECK_STOP_GRACE_SECS has passed, whichever is first: a pool that cleans up in 200ms costs
# 200ms, and one that ignores TERM costs the grace. What still outlives the KILL — a nested pool in a
# group of its own (#547) — is what `--stop` exists to find.
_workers_remain() {
  local p
  for p in "${!LIVE[@]}"; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" -gt 0 ] 2>/dev/null || continue
    kill -0 -- "-$p" 2>/dev/null && return 0
    kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}

_cleanup() {
  local p had=0 j _gdl
  # A CANCELLED run first records the process groups among its descendants, while they still ARE
  # its descendants: the TERM below is what reparents a nested pool's workers (#547, #551).
  if [ "${CANCELLED:-0}" -eq 1 ] && [ -z "$REC_PREP_DL" ]; then
    REC_PREP_DL=$(( BASH_MONOSECONDS + REC_PREP_SECS ))
    _rec_descendants
  fi
  # `LIVE` IS NOT THE WHOLE TRUTH, and the gap between it and the truth is where a worker is lost.
  # A worker is forked by `( … ) &` and recorded by `LIVE["$pid"]=1` on the NEXT statement; a
  # cancellation landing between the two finds a running worker this loop cannot see, never
  # signals it, and orphans it — the exact failure `LIVE` exists to prevent, one statement early.
  # The window widens with CPU starvation, which is why it surfaced on a 3-core runner (#387).
  #
  # The shell's own job table has no such gap: bash records the job AT fork. `-r` restricts it to
  # RUNNING jobs, so a pid bash has ALREADY reaped — whose number the kernel may since have handed
  # to an unrelated process — is not listed. That NARROWS the reaped-pid hazard `run_pool`'s own
  # note describes; it does not abolish it, because this is a snapshot: a job may exit and be
  # reaped between the enumeration here and the signal below. That residue is the one `LIVE`
  # already carries, and reading a fresher source does not widen it.
  for j in $(jobs -rp 2>/dev/null); do
    case "$j" in ''|*[!0-9]*) continue ;; esac
    LIVE["$j"]=1
  done
  # EVERY worker not yet RECORDED is recorded now — not merely every one missing from LIVE: dispatch
  # sets LIVE a statement before it records, and a cancel landing between the two would otherwise
  # leave that worker in no record at all.
  for j in "${!LIVE[@]}"; do
    [ -n "${REC_DONE[$j]+x}" ] || _rec_group "$j"   # row-rec-done
  done
  for p in "${!LIVE[@]}"; do   # row-term-loop
    # `_adb_bounded_signal` (scripts/lib/common.sh, sourced above) IS this rule: guard the pid,
    # signal the GROUP, then the bare pid as the fallback for a worker whose `set -m` did not take.
    # It used to be restated here, and the restatement is exactly what the one-home law is for —
    # both copies shipped the same defect (`''|0|*[!0-9]*` lets `00` through, and `kill -- -00`
    # resolves to group 0, the caller's own), and fixing one would have left the other. #141 gave
    # `adb_run_bounded` the same reaping need, so the primitive now has two consumers and lives
    # where the repo's law says: once, in common.sh.
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" -gt 0 ] 2>/dev/null || continue
    # `had` gates the escalation below, so it must mean "we signalled something that existed".
    # `_adb_bounded_signal` always returns 0 (it is a best-effort reaper), so liveness is asked
    # here rather than read out of its status.
    kill -0 "$p" 2>/dev/null && had=1
    _adb_bounded_signal TERM "$p"
  done
  if [ "$had" -eq 1 ]; then
    _gdl=$(( BASH_MONOSECONDS + STOP_GRACE ))
    while _workers_remain && [ "$BASH_MONOSECONDS" -lt "$_gdl" ]; do sleep 0.1; done   # row-grace-wait
    for p in "${!LIVE[@]}"; do
      _adb_bounded_signal KILL "$p"      # guards the pid itself; see the TERM loop
    done
  fi
  LIVE=()
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  [ -n "${TMPROOT:-}" ] && rm -rf "$TMPROOT"
  return 0
}
# Operator cancellation is NOT an ordinary red result: it stops dispatch, terminates the live
# workers and exits with the signal-derived status, rather than draining the pool. Without this a
# ^C is worse than useless — bash gives an asynchronous command SIGINT-ignore when job control is
# off, so the parent would die and leave up to $JOBS check suites running unattended.
#
# A CANCELLED run keeps its record (#551): it is how a later `--stop` finds what the run left. Only
# a run that ends on its own removes it.
CANCELLED=0
# _on_signal <status> — cancel the run, unless it is in the middle of an append to its record
# (`_rec_append`), which then finishes first and hands the signal back here.
# A run already on its way out has nothing left to cancel: its workers are gone and its scratch
# directory may be, so a signal then only sets the status it exits with.
RUN_EXITING=0
_on_signal() {
  if [ "$REC_HOLD" -eq 1 ]; then REC_SIG="$1"; return 0; fi   # row-sig-deferred
  [ "$RUN_EXITING" -eq 0 ] || exit "$1"
  CANCELLED=1; _cleanup; exit "$1"
}
trap '_on_signal 130' INT
trap '_on_signal 143' TERM
trap '_on_signal 129' HUP
trap 'RUN_EXITING=1; _cleanup; [ "$CANCELLED" -eq 1 ] || _rec_drop' EXIT
# The record's path is exported once it exists, so a harness can register its pool in it
# (`check_register_pool`). An INHERITED path is dropped first: a run that is not recorded must not
# have its pools land in another run's record.
unset ADB_SELFCHECK_RECORD
if _rec_write; then
  export ADB_SELFCHECK_RECORD="$RUN_ROOT/$RUN_RECORD"
else
  printf 'selfcheck: NOTE — no run record (%s): %s\n' "$RUN_RECORD" "$REC_WHY"
fi

banner() { printf '\n=== %s ===\n' "$1"; }

# Run one step and return its status. Stdin is /dev/null in BOTH modes, deliberately: no check
# reads it, and inheriting selfcheck's own open stdin is what once turned an accidental command
# substitution inside a test label into a ten-minute hang instead of an instant failure
# (scripts/check-claims.sh --self-test, the note above its digit-boundary case).
run_step() {
  local name="$1" rc=0
  # WHEN IT STARTED AND ENDED, both stamped from inside the step: the dispatcher records a start only
  # after the fork and reaps one job per wait, so either clock can be late, and an overrun is a fact
  # about the step, not about its dispatch or its reaping (D122). A stamp that cannot be written is
  # SAID, in the step's own output, because the runner then falls back to those later clocks.
  printf '%s\n' "$EPOCHSECONDS" > "$WORK/started.$name" 2>/dev/null \
    || printf 'selfcheck: NOTE — could not record when %s started; any overrun named for it is judged by when it was dispatched\n' "$name" >&2
  # shellcheck disable=SC2086  # deliberate word-split of a value `add` validated at registration
  ${STEP_CMD[$name]} </dev/null || rc=$?
  printf '%s\n' "$EPOCHSECONDS" > "$WORK/ended.$name" 2>/dev/null \
    || printf 'selfcheck: NOTE — could not record when %s ended; any overrun named for it is judged by when it was reaped\n' "$name" >&2
  return "$rc"
}

# stamp_of <started|ended> <name> — a step's own stamp, or nothing (status 1) while there is none.
stamp_of() {
  local e
  e="$(cat "$WORK/$1.$2" 2>/dev/null)" || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$e"
}

# running_for <name> <dispatched-at> — how long a step that has not ended has run, by its own start
# stamp when it has one.
running_for() {
  local s
  s="$(stamp_of started "$1")" || s="$2"
  printf '%s' "$(( EPOCHSECONDS - s ))"
}

# note_overrun <name> <elapsed-secs> [live] — remember a step that ran past the ceiling, and with
# `live` say so now: once per multiple of the ceiling, so a step that never ends keeps saying so
# instead of going quiet after one line. Without `live` it only records, which is how a step that
# crossed the ceiling and finished between two ticks still reaches the result block.
note_overrun() {
  local name="$1" el="$2" k
  k=$(( el / OVERRUN ))
  [ "$k" -ge 1 ] || return 0
  [ -n "${OVER_LAST[$name]+x}" ] || { OVERRAN+=("$name"); OVER_LAST["$name"]=0; }
  [ "${3:-}" = live ] || return 0
  [ "${OVER_LAST[$name]}" -lt "$k" ] || return 0
  OVER_LAST["$name"]="$k"
  printf 'selfcheck: still running past %ss: %s (%ss so far)\n' "$OVERRUN" "$name" "$el"
}

record() {   # name rc secs — the overrun is judged by the step's own stamps when it has both
  local el="$3" s e
  if s="$(stamp_of started "$1")" && e="$(stamp_of ended "$1")"; then el=$(( e - s )); fi
  note_overrun "$1" "$el"
  SLOW+=("$(printf '%06d %s' "$3" "$1")")
  if [ "$2" -eq 0 ]; then
    printf 'PASS (%ss)\n' "$3"
  else
    printf 'FAIL (exit %s, %ss)\n' "$2" "$3"
    FAILED+=("$1"); fail=1
  fi
}

run_serial() {   # names...
  local name t0 rc pid tick got
  # Job control here for the same reason `run_pool` uses it, and it is not optional: without it the
  # backgrounded step shares THIS shell's process group, so `_cleanup` can only signal the worker
  # subshell — and the `bash scripts/check-*.sh` it forked is orphaned and runs on. The step being
  # cancelled in this path is usually `build-drift`, i.e. a `scripts/build.sh` still rewriting the
  # working tree after the runner has exited.
  set -m
  for name in "$@"; do
    banner "$name"
    t0="$EPOCHSECONDS"; rc=0
    # Backgrounded and tracked, then waited on — NOT run in the foreground. Output still streams
    # live (stdout and stderr are inherited, not redirected), so this is the same experience; what
    # it buys is that the serial prologue and every `--serial` step land in `LIVE` and are therefore
    # reachable by `_cleanup`. A foreground child does not receive a TERM aimed at this shell, so
    # cancelling during `build-drift` used to leave a `scripts/build.sh` rewriting the working tree
    # after the runner had already exited — the one step where that matters most.
    run_step "$name" &
    pid=$!
    LIVE["$pid"]=1
    _rec_group "$pid"
    # The step OR the ticker, whichever ends first: a tick names the step if it is past the ceiling
    # and starts the next one. `-f` for the reason run_pool gives — job control is on here too.
    while :; do
      sleep "$OVERRUN_TICK" &
      tick=$!
      _rec_group "$tick"   # the run's too: a KILLed runner leaves it in a group of its own
      got=""
      if wait -f -n -p got "$pid" "$tick"; then rc=0; else rc=$?; fi
      if [ "${got:-}" = "$tick" ]; then
        unset "REC_DONE[$tick]"
        # Only a step that has not ENDED is still running; one the ticker beat to the reap is not.
        stamp_of ended "$name" >/dev/null || note_overrun "$name" "$(running_for "$name" "$t0")" live
        rc=0; continue
      fi
      kill "$tick" 2>/dev/null; wait "$tick" 2>/dev/null; unset "REC_DONE[$tick]"
      # Nothing reaped: a trapped signal interrupted the wait. The traps exit; loop rather than
      # attribute a status the step did not return.
      [ -n "${got:-}" ] || { rc=0; continue; }
      break
    done
    unset "LIVE[$pid]" "REC_DONE[$pid]"
    record "$name" "$rc" "$(( EPOCHSECONDS - t0 ))"
  done
  set +m
}

# The pool. Dispatch in declaration order, block until ANY worker finishes, emit that worker's
# whole block, dispatch the next. Emission is COMPLETION order — a failure surfaces as soon as it
# happens rather than waiting behind a straggler — and the parent is single-threaded, so a block is
# atomic by construction: nothing else can write between the banner, the body and the verdict.
run_pool() {   # names...
  local -a queue=("$@")
  local -A pid_name=() pid_out=() pid_t0=()
  local running=0 next=0 rc pid name out tick="" p
  # Job control, ON, for the pool only — and it is not cosmetic. It is what puts each worker in its
  # own process group, which is the only portable way `_cleanup` can reach a worker's grandchildren
  # (see its header). Restored on the way out so nothing after this function inherits it.
  set -m
  while [ "$next" -lt "${#queue[@]}" ] || [ "$running" -gt 0 ]; do
    while [ "$running" -lt "$JOBS" ] && [ "$next" -lt "${#queue[@]}" ]; do
      name="${queue[next]}"
      out="$WORK/step.$next.out"
      # Merged stdout+stderr into ONE file: separate files lose their relative order, and a
      # variable cannot hold the output anyway (command substitution strips trailing newlines and
      # NUL bytes). GIT_OPTIONAL_LOCKS is per-worker; see the concurrency contract above.
      ( export GIT_OPTIONAL_LOCKS=0; run_step "$name" ) >"$out" 2>&1 &
      pid=$!
      pid_name["$pid"]="$name"; pid_out["$pid"]="$out"; pid_t0["$pid"]="$EPOCHSECONDS"
      LIVE["$pid"]=1
      _rec_group "$pid"
      running=$(( running + 1 )); next=$(( next + 1 ))
    done

    # `if wait …; then` rather than a bare call: a failed worker's status must be CAPTURED, not
    # allowed to propagate. `-p` (bash 5.1+, and the floor is 5.3) names the pid that was reaped,
    # which is the only way to attribute the status to a step — without it a pool can only report
    # "something failed". The variable is unset before assignment, hence `${pid:-}`.
    #
    # `-f` is required BECAUSE of the `set -m` above: with job control enabled, plain `wait` returns
    # when a job CHANGES STATUS, which includes being stopped. Without `-f` a stopped worker would
    # be reaped as if it had finished and its half-written buffer emitted as a result.
    # THE TICKER is one more job in the same `wait -n`, so the dispatcher wakes at least once per
    # tick even when no step finishes. It is never in `pid_name`, so it can never be reported as a
    # step; `_cleanup` reaches it through the shell's job table like any other job.
    if [ -z "$tick" ]; then sleep "$OVERRUN_TICK" & tick=$!; _rec_group "$tick"; fi
    pid=""
    if wait -f -n -p pid; then rc=0; else rc=$?; fi
    if [ -n "${pid:-}" ] && [ "$pid" = "$tick" ]; then
      unset "REC_DONE[$tick]"; tick=""
      # An entry is not yet REAPED; only one with no end stamp is still RUNNING.
      for p in "${!pid_name[@]}"; do
        stamp_of ended "${pid_name[$p]}" >/dev/null || note_overrun "${pid_name[$p]}" "$(running_for "${pid_name[$p]}" "${pid_t0[$p]}")" live
      done
      continue
    fi
    if [ -z "${pid:-}" ]; then
      # A trapped signal interrupted the wait and nothing was reaped. The traps above exit, so
      # this is belt-and-braces; loop rather than mis-attribute a status to an arbitrary step.
      [ "$rc" -gt 128 ] && continue
      # Unreachable: `wait -n` only reports 127 with no children, and we hold $running > 0. Fail
      # loud rather than spin.
      printf 'selfcheck: FATAL — wait -n returned %s with %s job(s) outstanding and no pid\n' \
        "$rc" "$running" >&2
      fail=1
      break
    fi
    # DROP IT FROM `LIVE` FIRST, before anything that can be interrupted. This pid has been reaped,
    # so the kernel may hand the number to an unrelated process; a signal arriving while it was
    # still listed would have `_cleanup` TERM a pid — and a process GROUP — that is no longer ours.
    # (The mirror-image window, between `&` and the assignment below, is real and CANNOT be closed
    # in `LIVE` — there is no way to fork and record atomically. It is closed in `_cleanup`
    # instead, from the shell's own job table, which bash populates at fork; see its header. That
    # window orphaned a worker on a loaded runner for as long as it went uncovered, #387.)
    unset "LIVE[$pid]" "REC_DONE[$pid]"
    running=$(( running - 1 ))
    name="${pid_name[$pid]}"; out="${pid_out[$pid]}"
    banner "$name"
    [ -s "$out" ] && cat "$out"
    record "$name" "$rc" "$(( EPOCHSECONDS - ${pid_t0[$pid]} ))"
    rm -f "$out"
    # Forgotten once reaped, so the ticker's walk over `pid_name` is a walk over RUNNING steps.
    unset "pid_name[$pid]" "pid_out[$pid]" "pid_t0[$pid]"
  done
  if [ -n "$tick" ]; then kill "$tick" 2>/dev/null; wait "$tick" 2>/dev/null; unset "REC_DONE[$tick]"; fi
  set +m
}

# The serial prologue: whatever the selection contains of PINNED_STEPS, alone and first. See the
# concurrency contract at the top of this file for why each one is there.
declare -a PROLOGUE=() POOLED=()
for _s in "${SELECTED[@]}"; do
  if [ "$(lane_of "$_s")" = serial ]; then PROLOGUE+=("$_s"); else POOLED+=("$_s"); fi
done

# SAY WHAT WAS SKIPPED, BY NAME, BEFORE ANYTHING RUNS. A step dropped from the selection produces
# exactly what a step that passed produces: nothing. This line and its twin in the `result` block
# are the whole difference between "the caller chose not to run this" and "this silently stopped
# running" — and the second is the failure this suite exists to make impossible. Printed in BOTH
# modes, and repeated at the end because a 20-minute log's header is not where a reader looks.
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'selfcheck: SKIPPED %s step(s) by request: %s\n' \
  "${#SKIPPED[@]}" "${SKIPPED[*]}"

# ======================================= the gate (#441) =======================================
# A step that declares inputs runs only when the change under test touches one of them. The
# DECISION is `scripts/mutation-gate.sh`'s — one home (CI asked it per job until #456 took the
# harnesses off the per-PR path) — and
# this runner only relays it: the gate's own line is printed for every step it skips, so a reader
# sees what was compared and against what, never a bare name.
#
# THE STATUS IS READ, NOT FOLDED. 10 is the only skip. 0/11/12 are the three stated reasons to run
# (inputs changed · fail-closed, no diff · ADB_MUTATION_RUN_ALL). Anything else is the gate itself
# failing, and that is neither a skip nor a clean run: the step runs, the line says the gate broke,
# and the run's exit status is NOT affected — a broken gate must cost minutes, never coverage, and
# must never hide behind a red it did not earn.
#
# Applied to the SELECTION, after --only and --skip, so `--only x-mutation` on an untouched tree
# says "gated (inputs unchanged): x-mutation" and runs nothing — honest, and the override is one
# environment variable away. Runs BEFORE the dispatch header so the counts below describe what
# actually ran.
#
# EVERY DECISION THAT IS NOT "inputs changed" IS RELAYED, not only the skips. A fail-closed RUN
# (11) is a gate that could not decide — no merge-base, an unresolvable base — and a reader who
# sees the harness run without that line cannot tell "the inputs changed" from "the gate gave up",
# which is the difference between a filter that works and one that silently never does. The
# override (12) is said once, not once per step.
declare -a GATED=() GATE_LINES=()
if [ ! -f scripts/mutation-gate.sh ]; then
  _any_inputs=0
  for _s in "${SELECTED[@]}"; do [ -n "${STEP_INPUTS[$_s]+x}" ] && _any_inputs=1; done
  [ "$_any_inputs" -eq 0 ] || printf 'selfcheck: WARN — scripts/mutation-gate.sh is missing; every gated step runs\n'
else
  declare -a _ungated=()
  _overridden=0
  for _s in "${SELECTED[@]}"; do
    if [ -z "${STEP_INPUTS[$_s]+x}" ]; then _ungated+=("$_s"); continue; fi
    IFS=',' read -r -a _in <<< "${STEP_INPUTS[$_s]}"
    _line="$(bash scripts/mutation-gate.sh should-run "$_s" -- "${_in[@]}" 2>&1)"; _grc=$?
    case "$_grc" in
      10) GATED+=("$_s"); GATE_LINES+=("$_line") ;;
      0)  _ungated+=("$_s") ;;
      11) printf 'selfcheck: NOTE — %s\n' "$_line"; _ungated+=("$_s") ;;
      12) _overridden=$((_overridden + 1)); _ungated+=("$_s") ;;
      *) printf 'selfcheck: WARN — the mutation gate failed for %s (rc %s); running it: %s\n' "$_s" "$_grc" "$_line"
         _ungated+=("$_s") ;;
    esac
  done
  [ "$_overridden" -eq 0 ] || printf 'selfcheck: ADB_MUTATION_RUN_ALL is set — the mutation gate is overridden; %s gated step(s) run regardless\n' "$_overridden"
  SELECTED=("${_ungated[@]}")
  if [ "${#GATED[@]}" -gt 0 ]; then
    printf 'selfcheck: GATED %s step(s) — inputs unchanged (ADB_MUTATION_RUN_ALL=1 runs them): %s\n' \
      "${#GATED[@]}" "${GATED[*]}"
    printf '  %s\n' "${GATE_LINES[@]}"
  fi
  # The prologue split was computed from the pre-gate selection; recompute from what survived.
  PROLOGUE=(); POOLED=()
  for _s in "${SELECTED[@]}"; do
    if [ "$(lane_of "$_s")" = serial ]; then PROLOGUE+=("$_s"); else POOLED+=("$_s"); fi
  done
fi

RUN_T0="$EPOCHSECONDS"
if [ "$SERIAL" -eq 1 ]; then
  printf 'selfcheck: %s step(s), serial (--serial)\n' "${#SELECTED[@]}"
  run_serial "${SELECTED[@]}"
else
  printf 'selfcheck: %s step(s), %s parallel job(s)' "${#SELECTED[@]}" "$JOBS"
  [ "${#PROLOGUE[@]}" -gt 0 ] && printf ', serial prologue: %s' "${PROLOGUE[*]}"
  printf '\n'
  [ "${#PROLOGUE[@]}" -gt 0 ] && run_serial "${PROLOGUE[@]}"
  [ "${#POOLED[@]}" -gt 0 ] && run_pool "${POOLED[@]}"
fi
RUN_SECS=$(( EPOCHSECONDS - RUN_T0 ))

banner "result"
# SAY WHAT IT RAN, not merely whether it passed. A pool that dispatched nothing reports the same
# clean verdict as a full green run, and a count is what makes that readable in a log.
printf '%s step(s) in %sm%02ds — %s passed, %s failed\n' \
  "${#SELECTED[@]}" "$(( RUN_SECS / 60 ))" "$(( RUN_SECS % 60 ))" \
  "$(( ${#SELECTED[@]} - ${#FAILED[@]} ))" "${#FAILED[@]}"
# The count above is of what RAN, so on its own it cannot distinguish a smaller registry from a
# filtered one. Naming the skipped steps here is what keeps `57 step(s)` and `56 step(s)` from
# being the same sentence to a reader.
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'skipped: %s\n' "${SKIPPED[*]}"
# …and the gated ones, for the same reason: a step the gate held back produced exactly what a
# step that passed produced, and the header of a long log is not where a reader looks.
[ "${#GATED[@]}" -gt 0 ] && printf 'gated (inputs unchanged): %s\n' "${GATED[*]}"
# …and every step that ran past the overrun ceiling, finished or not. A run cancelled while a step
# hung never reaches this block, which is why each one was also named live when it crossed.
[ "${#OVERRAN[@]}" -gt 0 ] && printf 'overran (past %ss): %s\n' "$OVERRUN" "${OVERRAN[*]}"
# The slowest few, because under a pool the wall clock is the longest single step and knowing
# which one that is turns "make it faster" into a specific question.
if [ "${#SLOW[@]}" -gt 0 ]; then
  printf 'slowest:'
  printf '%s\n' "${SLOW[@]}" | sort -rn | head -3 | while read -r _secs _name; do
    printf ' %s %ss' "$_name" "$(( 10#$_secs ))"
  done
  printf '\n'
fi
# The failing names in the LAST TWO LINES — immediately before the verdict, which stays last
# because it is the recognisable terminal contract. The placement is load-bearing either way: the
# Stop-hook gate runner tails only the final few KB of this output on failure
# (scripts/lib/project-gates.sh), and under completion order the failing step's own block can be
# anywhere in the run.
[ "${#FAILED[@]}" -gt 0 ] && printf 'FAILED: %s\n' "${FAILED[*]}"
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0; else echo "SOME CHECKS FAILED"; exit 1; fi
