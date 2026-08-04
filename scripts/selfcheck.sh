#!/usr/bin/env bash
# ai-dev-baseline — local CI mirror. Run before every push.
#
# Runs the checks CI runs, with the two documented exceptions below: shellcheck, build-drift,
# skill-frontmatter, workflow-render,
# gate-detector/gates, common-lib, agent-init, cleanup-enum, repo-settings, bash-floor,
# bash-floor-guard, baseline, session-currency, precommit-gate, implement-gate, install-migration,
# install-guard, fact-drift, fact-mutation, fact-guard, practice-index, release-role,
# release-skill, selfcheck-guard, and an install→uninstall dry-run into a throwaway HOME.
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
#   3. `check-bash-floor.sh --runtime` — which IS offline, and runs in all 28 CI jobs (the 27 per-PR
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
#   * the root-doc render is a plain `> "$outfile"` truncate-and-write (scripts/build.sh:52), not
#     a temp-then-rename — unlike the skill render in the same file, which does temp-then-mv. That
#     asymmetry is a defect in its own right (an interrupted build leaves a truncated tracked file)
#     and is tracked in #268; fixing it removes the torn-single-file case but NOT this pin, because
#     the three root docs still do not update atomically with respect to each other.
#
# So while it runs, `agents/claude/CLAUDE.md` and its two siblings can be observed half-written —
# by `workflow-map` and `skill-frontmatter` here, and by `fact-drift`, `injection`, `bash-floor`,
# `roadmap`, `release-role`, `install-guard` and `install-dry-run`, all of which read that tree.
# Running it alone, first, removes the whole class rather than one instance of it.
#
# What is deliberately NOT serialized, so the reasoning is auditable rather than re-derived:
#
#   * `check-release-skill.sh`'s `/tmp/adb-cl-*.$$` files. `$$` differs per check process, so
#     siblings in this pool cannot collide. Replacing them with `mktemp` belongs to #250.
#   * `check-role-dispatch.sh`'s system-wide `pgrep -f 'sleep 31337'`. Only that one step ever
#     stages such a process, and only one copy of it runs.
#   * the destructive-git fixtures (`check-cleanup.sh`, `check-cleanup-enum.sh`): every one of
#     them operates inside its own `mktemp -d` repo, never this one.
#
# TWO CONCURRENT SELFCHECK RUNS in one checkout are still not supported, and this change does not
# make them so: they would both drive `build.sh` over the same tree. That is #250's territory and
# is called out here so the omission is a decision rather than an oversight.
PINNED_STEPS=(build-drift)

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
  HOME="$FAKE" bash uninstall.sh --agent claude --agent codex --agent gemini >>"$log" 2>&1 || ok=0
  [ ! -L "$FAKE/.claude/CLAUDE.md" ] || ok=0
  [ ! -L "$FAKE/.claude/scripts/session-currency.sh" ] || ok=0
  # A leftover SessionStart entry pointing at a removed script would error on EVERY future session.
  grep -q 'session-currency.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok=0
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

add workflow-map        step_workflow_map

add skill-frontmatter   step_skill_frontmatter

# The body-placeholder substitution behind the Claude skill render (#16): every neutral
# {{PLACEHOLDER}} maps to its Claude token, substitution is body-only, an unmapped token
# fails loud, and no committed skill ships an unresolved placeholder.
add workflow-render     bash scripts/check-workflow-render.sh

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

add gate-detector       step_gate_detector

# Full behavior tests for the gate model (detection, open set, N/A, path scope).
add gates               bash scripts/check-gates.sh

# Unit tests for the shared shell primitives (scripts/lib/common.sh), incl. adb_repo_shape (#23).
add common-lib          bash scripts/check-common-lib.sh

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

# Unit tests for the atomic observe-and-render helper (scripts/lib/state-assert.sh, #138):
# mergedAt-over-state, NOT_PLANNED kept distinct, every unverifiable path rendering NO sentence,
# argument validation, and the three narrating workflows' wiring to it.
add state-assert        bash scripts/check-state-assert.sh

# Unit tests for the partial skill override composer (scripts/lib/skill-compose.sh, #22):
# ops, anchor slugging, inherit-on-recompose, byte-exact currency check, and the safety guards.
add skill-compose       bash scripts/check-skill-compose.sh

# Regression test for /cleanup's remote enumeration excluding the origin/HEAD symref (#38).
add cleanup-enum        bash scripts/check-cleanup-enum.sh

# Behavioral tests for the /cleanup decision predicates (scripts/lib/cleanup-lib.sh): squash-merge
# detection against a real fixture (#106 — `--merged` alone is blind to it, so the sweep was a
# permanent no-op), the destructive refusals (a branch that gained commits after its merge; state
# for an open PR or an in-flight run), and the terse output contract (#84). Offline.
add cleanup             bash scripts/check-cleanup.sh

# Behavioral tests for the /roadmap decision predicates (scripts/lib/roadmap-lib.sh): in-flight
# targeting (#69 — a bare `Refs #N` must never freeze a ready member) and release readiness
# (#71), plus a drift guard that the workflow still delegates to them (#45). Offline.
add roadmap             bash scripts/check-roadmap.sh

# Mocked-gh harness (#75): EXECUTES the workflow's documented snippets against a stub gh, so a
# fenced command that no longer runs is a test failure rather than a surprise at /roadmap time.
# Covers artifact location, the paginated adopt scan, the completeness + in-flight fresh read,
# the readiness pipeline, the gauge, and decision durability. Offline.
add roadmap-e2e         bash scripts/check-roadmap-e2e.sh

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
# stored prUrl over a PR that was closed without merging (#44).
add implement-gate      bash scripts/check-implement-gate.sh

# A plain `git pull` must never dangle an installed symlink: install the merge-base, simulate
# a pull to HEAD, and require every installed link to still resolve (#35).
add install-migration   bash scripts/check-install-migration.sh

# adb_link's fail-loud source guard must thread through install.sh: a missing manifest source
# makes the real installer exit non-zero, never dangling a link or disturbing a real dest (#48).
add install-guard       bash scripts/check-install-guard.sh

# Canonical facts (gate axes, cross-agent invocations, codex timeout, resolution order)
# must stay consistent across their consumer docs.
add fact-drift          bash scripts/check-fact-drift.sh

# The negative half of that lint has a failure mode the positive half does not: SILENCE. An
# `absent:` pattern that matches nothing passes forever while checking nothing — which is exactly
# what shipped in #173 and is why #213 exists. Each rule's declared `fires:` witnesses are injected
# into a COPY of every file it pins and the real lint must come back red. Runs ~22 sub-lints
# against a throwaway tree; the working tree is never touched.
add fact-mutation       bash scripts/check-fact-drift.sh --mutation

# ...and the guard rails above are themselves guards, so they get the same treatment (#213): the
# witness contract and the mutation harness are each driven against deliberately broken rules in a
# tree copy and must be seen going red. Carries the direct regression test for #173's defect — the
# exact `absent:\[bot\]\$` pattern that could not match either real idiom.
add fact-guard          bash scripts/check-fact-guard.sh

# The OFFLINE half of the claim lint (#212): every D<N> an added line cites resolves to a heading in
# the decision log, and every added decision date is within a day of the commit that introduced it.
#
# The issue/PR-reference half is NOT run here, and that is deliberate rather than an omission. It
# needs the network, and D13 keeps selfcheck hermetic precisely so a local green is a DETERMINISTIC
# predictor of CI — a step whose verdict depends on network, auth and externally-mutable issue state
# would break that promise for every other step too. It rides CI instead, exactly as the one other
# live assertion (`repo-settings.sh required-drift`) does. The check SAYS which half it skipped and
# how many references went unverified, so the gap is visible rather than silent.
add claims              bash scripts/check-claims.sh

# ...and the lint above is a guard, so it gets the treatment guards get here (D22): every rule is
# driven to RED against fixtures in a throwaway repo with a stubbed gh, asserting the DESIGNATED
# exit code and diagnostic rather than "some non-zero". This suite has already earned its place
# twice — it caught a markdown stripper that made one rule structurally unable to fire, and an
# unresolvable --range that silently turned the whole check into a no-op reporting PASS.
add claims-guard        bash scripts/check-claims-guard.sh

# Every base/practices/*.md is listed in 00-index.md exactly once (no missing/stale rows).
add practice-index      bash scripts/check-practice-index.sh

# #3's decision: release execution stays project-owned and no /release skill ships. A NEGATIVE
# invariant no other check can express — build-drift/workflow-map would happily green-light a
# newly added base/workflows/release.md.
add release-role        bash scripts/check-release-role.sh

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

add install-dry-run     step_install_dry_run

# ======================================== the runner ===========================================

JOBS=0
SERIAL=0
ONLY=""
ONLY_GIVEN=0   # distinct from ONLY="" — see the --only handling below

usage() {
  cat <<'USAGE'
usage: bash scripts/selfcheck.sh [--serial] [--jobs N] [--only a,b,...] [--list]

  --serial      Run every step sequentially, in declaration order, with output streaming
                live. Reach for this when a parallel failure is hard to attribute.
  --jobs N      Cap concurrency at N (default: min(cpu, 8)). --jobs 1 still buffers;
                --serial is the mode that does not.
  --only a,b    Run only the named steps (still honouring the serial prologue). An unknown
                name is an error — a filter that silently selects nothing is not a pass.
  --list        Print the registry as "<name><TAB><command><TAB>pool|serial" and exit. This is
                the runner's own answer to "what does it run", so a guard can ask instead of
                grepping. The third field says whether the step runs in the serial prologue.
USAGE
}

# min(cpu, 8), portably. `nproc` is GNU coreutils and is absent from a stock macOS, where CI and
# the maintainer both run; `getconf _NPROCESSORS_ONLN` is the one spelling both platforms carry,
# with the other two as fallbacks. Deliberately NOT promoted to scripts/lib/common.sh: it has one
# consumer, and that library is installed into every agent home and must stay parseable below the
# 5.3 floor (D30). If a second consumer appears, promote it then — the `adb_run_bounded` path.
cpu_count() {
  local n=""
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  [ -n "$n" ] || n="$(sysctl -n hw.ncpu 2>/dev/null)" || n=""
  [ -n "$n" ] || n="$(nproc 2>/dev/null)" || n=""
  # Trim surrounding whitespace before the digit test. A probe that answered " 10" would otherwise
  # fail it and fall back to 1 — a pool of one, which is this whole change silently not happening.
  # (The run header prints the job count, so it would be visible; it should also not occur.)
  n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || n=1
  printf '%s' "$n"
}

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
    # A terminal mode is RECORDED here and acted on after the loop, not executed mid-parse.
    # Exiting inside the loop made rejection depend on argument ORDER: `--list --nonsense` printed
    # the registry and exited 0 while `--nonsense --list` errored. An unknown flag is an error
    # wherever it appears.
    --list) LIST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "selfcheck: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$LIST" -eq 1 ]; then
  # Three TAB-separated fields: name, command, and whether it runs in the serial prologue.
  # The third is here so a guard can ask the runner which steps are pinned instead of grepping
  # PINNED_STEPS out of this file — and, unlike a grep, asking cannot pass while the array it
  # read has stopped being the one the dispatcher consults.
  for _s in "${STEP_ORDER[@]}"; do
    _where=pool
    for _p in "${PINNED_STEPS[@]}"; do [ "$_s" = "$_p" ] && _where=serial; done
    printf '%s\t%s\t%s\n' "$_s" "${STEP_CMD[$_s]}" "$_where"
  done
  exit 0
fi

[ "$JOBS" -gt 0 ] || { JOBS="$(cpu_count)"; [ "$JOBS" -le 8 ] || JOBS=8; }

# --only, applied to the declared order so the selection keeps it. An unknown name EXITS rather
# than being skipped: a filter that quietly matches nothing runs zero checks and reports the same
# clean verdict a full green run reports (base/practices/self-review.md).
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

WORK="$(mktemp -d)" || { echo "selfcheck: FATAL — cannot create a scratch directory" >&2; exit 2; }
declare -A LIVE=()          # pid -> 1, for the signal path
declare -a FAILED=()        # step names, in emission order
declare -a SLOW=()          # "secs name", for the summary

# Terminate every live worker — the whole PROCESS GROUP, not the pid.
#
# The worker is a subshell that forks `bash scripts/check-<x>.sh`, so signalling the pid alone
# kills the subshell and REPARENTS the check to init, where it runs on unattended: a cancelled run
# that leaves up to $JOBS suites still executing. That is the same divergence `adb_run_bounded`
# documents for its watchdog path (#141), and the pool is where it is cheap to close: `set -m`
# makes each worker its own process-group leader, so `kill -- -$pid` reaches the grandchildren too.
#
# TERM, then grace, then KILL, matching `_adb_bounded_reap`: a bound that only sends TERM is not a
# backstop, because anything that traps or ignores it survives.
_cleanup() {
  local p had=0
  for p in "${!LIVE[@]}"; do
    # GUARD THE SUBSCRIPT BEFORE NEGATING IT. `kill -- -0` signals the CALLER'S OWN process group —
    # i.e. the operator's shell and everything in it — so a key that is not a positive integer must
    # never reach the `-$p` form. `$!` cannot be 0 today; the cost of being wrong is the whole
    # session, which is worth one test.
    case "$p" in ''|0|*[!0-9]*) continue ;; esac
    kill -TERM -- "-$p" 2>/dev/null && had=1
    # ...and the bare pid too, because the group form only reaches a group if `set -m` actually
    # took effect. Where it did, the worker is already gone and this is a harmless ESRCH; where it
    # did not, this is the only signal that lands. (A worker surviving cancellation is what
    # check-selfcheck.sh's heartbeat case detects, so the two halves are not redundant claims.)
    kill -TERM "$p" 2>/dev/null && had=1
  done
  if [ "$had" -eq 1 ]; then
    sleep 1
    for p in "${!LIVE[@]}"; do
      case "$p" in ''|0|*[!0-9]*) continue ;; esac
      kill -KILL -- "-$p" 2>/dev/null
      kill -KILL "$p" 2>/dev/null
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
# (scripts/check-claims-guard.sh, the note above its digit-boundary case).
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
    # (The mirror-image window, between `&` and the assignment below, cannot be closed in shell:
    # there is no way to fork and record atomically. It is one statement wide and is stated here
    # rather than papered over.)
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
  _pinned=0
  for _p in "${PINNED_STEPS[@]}"; do [ "$_s" = "$_p" ] && _pinned=1; done
  if [ "$_pinned" -eq 1 ]; then PROLOGUE+=("$_s"); else POOLED+=("$_s"); fi
done

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
