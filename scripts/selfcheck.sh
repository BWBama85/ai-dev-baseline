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
# script, the two shared files, every `scripts/lib/*.sh` the suite exercises, and — for
# `bootstrap-mutation` — the entry-point site set it reverts one at a time. Wrong in the direction
# of listing too much costs minutes; wrong in the other direction costs a day, because the
# scheduled workflow (`.github/workflows/mutation-nightly.yml`) runs every harness unconditionally.
#
# ONE HOME. `scripts/mutation-gate.sh` reads this through `--list` (field 5); `scripts/check-mutation-gate.sh`
# pins that every `*-mutation` step declares inputs naming its own harness plus the two shared
# files, that every declared path exists, and that the nightly matrix names every step here.
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
  # Enumerate tracked shell files (+ the extensionless bin/ commands).
  local files
  files="$(git ls-files '*.sh' 'bin/agent-init' 'bin/baseline')"
  # shellcheck disable=SC2086
  shellcheck --severity=warning -e SC1091 $files
}

step_build_drift() {
  local bd=0 tree
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

# What the rendered artifacts COST to load (#359). A report, not a gate: it fails only on
# mechanics — an expected artifact missing, unreadable or zero-byte — and never on size, because
# the owner rejected caps (2026-08-15). Registered so the numbers land in every run's log, which is
# what gives the AI-optimization epic (#358) a before/after per PR.
add render-size         bash scripts/render-size.sh

# ...and its one failing arm is a guard, so it gets what guards get here: the mechanical rules
# driven RED against fixture trees under a `mktemp -d`, plus the direction it must never fail in —
# an arbitrarily large artifact still exits 0.
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
# unreadable path failing closed, and the bounded wait actually honouring its bound.
add pr-watch            bash scripts/check-pr-watch.sh

# The negative half of the step above, for the bounded-wait cases only (#394). Those cases are the
# ones whose green means nothing on its own: the reported defect was a case that reached its `rc`
# assertion after one poll, with the message it exists to assert never printed. Seven mutations —
# five of the wait loop, two of the staleness rule it delegates to — plus an unmutated control, each
# row required back RED on ITS OWN named witness, so "these cases can fire" is re-runnable rather
# than a claim in a PR body.
add pr-watch-mutation   bash scripts/check-pr-watch.sh --mutation
inputs pr-watch-mutation        scripts/check-pr-watch.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/pr-watch.sh

# Unit tests for the /resolve-pr-threads decision predicates (scripts/lib/pr-threads.sh, #416/#418):
# argument-less PR inference refusing rather than guessing, the COMPLETE thread enumeration across a
# cursor, and the completeness proof that makes a short read loud instead of letting it report
# "0 remaining".
add pr-threads          bash scripts/check-pr-threads.sh

# The negative half of the step above (#418). Its cases are guards, and a guard's failure mode is
# silence: the shipped defect was a `first:50` read whose own remaining-count check shared the
# truncating window, so it printed exactly what a clean run prints. Six mutations — the cursor loop
# stopped, the cursor never sent, the count proof disabled, the count proof disabled against #418's
# OWN resolved-page/unresolved-overflow shape, the distinct-id proof disabled, and the per-node type
# check disabled — plus an unmutated control, each required back RED on ITS OWN named witness.
add pr-threads-mutation bash scripts/check-pr-threads.sh --mutation
inputs pr-threads-mutation      scripts/check-pr-threads.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/pr-threads.sh

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
inputs pattern-ledger-mutation  scripts/check-pattern-ledger.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/pattern-ledger.sh scripts/lib/adopt-lib.sh

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
inputs docs-lib-mutation        scripts/check-docs-lib.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/docs-lib.sh scripts/lib/cleanup-lib.sh scripts/lib/implement-lib.sh

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
# DIFFERS must be `move`, never `remove`. Plus the four hygiene axes, the role-inference "cannot
# infer" result, the pin's validation and round-trip, and a byte-level assertion that no read-only
# subcommand alters the project it scanned. Offline; every fixture is a mktemp -d tree.
add adopt               bash scripts/check-adopt.sh

# ...and that suite is a guard, so it gets what guards get here: every load-bearing decision in
# adopt-lib.sh is injected with its own defect in a TREE COPY, and the suite must come back red ON
# ITS OWN NAMED ASSERTION. A mutation that goes red for the wrong reason is not evidence, so the
# witness is matched against the failure text (#213's `fires:` contract). This replaces a commit
# message's claim that mutations "were observed" with something the repo can re-run.
add adopt-mutation      bash scripts/check-adopt.sh --mutation
inputs adopt-mutation           scripts/check-adopt.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/adopt-lib.sh install.sh uninstall.sh

# The ADOPTION COMPLETION CONTRACT and its verifier (scripts/lib/adopt-readiness.sh, #81) — the
# question /adopt's scan does not answer: is this project now ready to RUN the loop? A verifier's
# failure mode is silence (it passes green having checked nothing), so the suite drives every one
# of the twelve rungs to every result class and asserts a NAMED verdict word and exit code for
# each, plus the fail-closed core: empty stdin, a rung nobody reported, an unknown status, a
# duplicate and a malformed fact must every one of them be NON-green. Offline — `probe` reads the
# filesystem and `tracker` reads a JSON object the caller assembled, which is exactly why the gh
# reads live in the workflow instead.
add adopt-readiness     bash scripts/check-adopt-readiness.sh

# ...and the same guards-get-mutated rule, for the same reason: thirty-eight defects, each injected
# into a TREE COPY, each required to make the suite red ON ITS OWN NAMED ASSERTION. Two of them
# are regressions of real fail-OPEN bugs this suite caught while it was being written (a gate
# count that grepped a display string, and a jq filter whose failure was swallowed into "every
# milestone is dispositioned").
add adopt-readiness-mutation bash scripts/check-adopt-readiness.sh --mutation
inputs adopt-readiness-mutation scripts/check-adopt-readiness.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/adopt-readiness.sh scripts/lib/project-gates.sh bin/baseline

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

# The SessionStart run-state hook and its library (#431): a compacted or resumed session gets the
# in-flight run's facts read back — phase, phase history, branch, issue numbers, artifact paths,
# REQUIRED-mark count — and NEVER an issue's or a finding's text. Owner-scoped exactly as the Stop
# gate is; acts on `compact` and `resume` only; exits 0 on every path. Also executes the workflow's
# real phase-update snippet against a fixture marker (#243's append-only phaseHistory).
add session-context     bash scripts/check-session-context.sh

# ...and the guards in it are guards, so each is injected with its own defect and required RED on
# its own witness: the owner check, the source gate, the whole-record refusal, the containment of
# the injected fields, the REQUIRED count, and the workflow snippet's history append.
add session-context-mutation bash scripts/check-session-context.sh --mutation
inputs session-context-mutation scripts/check-session-context.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/run-state.sh agents/claude/scripts/session-context.sh agents/claude/settings.hooks.json base/workflows/implement-issue.md

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
inputs fact-mutation            scripts/check-fact-drift.sh scripts/check-lib.sh scripts/lib/common.sh

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
inputs selfcheck-guard-mutation scripts/check-selfcheck.sh scripts/check-lib.sh scripts/lib/common.sh scripts/selfcheck.sh scripts/mutation-gate.sh

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
inputs mutation-gate-mutation scripts/check-mutation-gate.sh scripts/check-lib.sh scripts/lib/common.sh scripts/mutation-gate.sh scripts/selfcheck.sh .github/workflows/ci.yml .github/workflows/mutation-nightly.yml

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
USAGE
}

# min(cpu, 8) is `adb_pool_size` in scripts/lib/common.sh now (#335). The note that used to sit here
# is why: it said this probe was deliberately NOT promoted "because it has one consumer — if a
# second appears, promote it then". Two more appeared — `check-adopt.sh` wrote its own copy of the
# chain, and `check-adopt-readiness.sh` skipped the probe and hardcoded 4 — so the third spelling
# was the one that got the number wrong. Sourced, never copied (docs/design-principles.md).

LIST=0
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
    return 0
  fi
  printf '### `selfcheck` failed\n\n'
  if [ -n "$failed" ]; then
    printf '**Failed step(s):**'
    # EVERY TOKEN IS RE-VALIDATED before it enters a code span. `add` constrains what may be
    # REGISTERED; it says nothing about a line read back out of a log, which any step's own output
    # can forge by printing `FAILED: ` at the start of a line. A name carrying a backtick would
    # close the span and render the rest as markup in a page a maintainer reads. A token that is
    # not a [A-Za-z0-9_-] slug is reported as unparsable rather than rendered.
    # shellcheck disable=SC2086  # deliberate word-split of a space-joined name list
    for _f in $failed; do
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

[ "$JOBS" -gt 0 ] || JOBS="$(adb_pool_size)"

# --only, applied to the declared order so the selection keeps it. An unknown name EXITS rather
# than being skipped: a filter that quietly matches nothing runs zero checks and reports the same
# clean verdict a full green run reports (base/practices/self-review.md).
WORK="$(mktemp -d)" || { echo "selfcheck: FATAL — cannot create a scratch directory" >&2; exit 2; }
declare -A LIVE=()          # pid -> 1, for the signal path
declare -a FAILED=()        # step names, in emission order
declare -a SLOW=()          # "secs name", for the summary

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
_cleanup() {
  local p had=0 j
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
  for p in "${!LIVE[@]}"; do
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
    sleep 1
    for p in "${!LIVE[@]}"; do
      _adb_bounded_signal KILL "$p"      # guards the pid itself; see the TERM loop
    done
  fi
  LIVE=()
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}
# Operator cancellation is NOT an ordinary red result: it stops dispatch, terminates the live
# workers and exits with the signal-derived status, rather than draining the pool. Without this a
# ^C is worse than useless — bash gives an asynchronous command SIGINT-ignore when job control is
# off, so the parent would die and leave up to $JOBS check suites running unattended.
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP
trap '_cleanup' EXIT

banner() { printf '\n=== %s ===\n' "$1"; }

# Run one step and return its status. Stdin is /dev/null in BOTH modes, deliberately: no check
# reads it, and inheriting selfcheck's own open stdin is what once turned an accidental command
# substitution inside a test label into a ten-minute hang instead of an instant failure
# (scripts/check-claims.sh --self-test, the note above its digit-boundary case).
run_step() {
  local name="$1" rc=0
  # shellcheck disable=SC2086  # deliberate word-split of a value `add` validated at registration
  ${STEP_CMD[$name]} </dev/null || rc=$?
  return "$rc"
}

record() {   # name rc secs
  SLOW+=("$(printf '%06d %s' "$3" "$1")")
  if [ "$2" -eq 0 ]; then
    printf 'PASS (%ss)\n' "$3"
  else
    printf 'FAIL (exit %s, %ss)\n' "$2" "$3"
    FAILED+=("$1"); fail=1
  fi
}

run_serial() {   # names...
  local name t0 rc pid
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
    wait "$pid" || rc=$?
    unset "LIVE[$pid]"
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
  local running=0 next=0 rc pid name out
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
    pid=""
    if wait -f -n -p pid; then rc=0; else rc=$?; fi
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
    unset "LIVE[$pid]"
    running=$(( running - 1 ))
    name="${pid_name[$pid]}"; out="${pid_out[$pid]}"
    banner "$name"
    [ -s "$out" ] && cat "$out"
    record "$name" "$rc" "$(( EPOCHSECONDS - ${pid_t0[$pid]} ))"
    rm -f "$out"
  done
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
# DECISION is `scripts/mutation-gate.sh`'s — one home, the same one CI's per-job steps ask — and
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
