#!/usr/bin/env bash
# ai-dev-baseline — behavioral tests for the /adopt decision predicates (#20, consolidating
# #21 and #29), plus a source-drift guard on the workflow that consumes them.
#
# WHY THIS EXISTS. /adopt is prose an agent executes against somebody else's repository, and its
# output is a recommendation a human then acts on. That is a different failure mode from
# /cleanup's — nothing here deletes anything — and it is not a milder one: an inventory that says
# `remove` about a file carrying behavior the project still needs gets that behavior deleted by
# the operator, with the plan as justification. So every classifier arm is tested from the side
# that costs something:
#
#   - a PRESCRIBED HOME that collides with a baseline artifact must be `keep`, never `remove`
#     (`.claude/scripts/precommit-gate.sh` is the real case: it collides by name AND is
#     handling-the-unknown.md's one legal home for custom gate policy);
#   - a colliding artifact that DIFFERS must be `move`, never `remove` — that is what the issue
#     means by a parity caveat, and the difference between the two verdicts is the project's
#     forked skill;
#   - anything whose delta cannot be established must be `escalate`, never a guess;
#   - every bad argument must exit 2, never 0-with-a-plausible-word.
#
# AND EVERY GUARD IS OBSERVED FAILING. base/practices/self-review.md's rule is that a check is not
# done until it has been seen going red on an input it is supposed to reject, because a guard's
# failure mode is SILENCE. That rule earned its place here twice while this file was being
# written: `hygiene`'s broad-ignore axis could not fire at all (it matched the pathname column of
# `git check-ignore -v`, which always contains the path being asked about), and the first
# credential probe embedded a tab and made its own finding unreadable. Neither was visible by
# reading; both showed up the moment a fixture was run. So the ignore axis below asserts the
# BROAD case fires, the EXPLICIT case stays silent, and the ABSENT case fires differently — three
# distinguishable answers, because two of them would let a stuck predicate pass.
#
# OFFLINE and HERMETIC. The library never calls gh; the only git it runs is `check-ignore`, which
# needs a repo but no remote. Every fixture is a `mktemp -d` tree. THE TRACKED WORKING TREE IS
# NEVER MUTATED — not to build a fixture, not to negative-test a lint (self-review.md's copy
# rule: editing a tracked file to watch a check reject it is what ends in `git checkout --` and
# ~40 minutes of lost work).
#
# WHAT THIS SUITE CANNOT PROVE, stated plainly rather than implied away:
#   - that the four surveyed repositories (getrich, unraid-cache-cleaner, support-workstation,
#     bama-politics) still have the shapes these fixtures model. They are not in this repository
#     and CI cannot see them. The fixtures reproduce the shapes those repos were DOCUMENTED to
#     have in #20/#29; the live acceptance run is manual and is recorded in the PR, not here.
#   - semantic parity between two differing files. `differs` is byte-inequality, deliberately, and
#     no assertion here claims more.
#   - that the credential axis catches an unfamiliar secret format. Its prefix list is closed.
#
# Usage: bash scripts/check-adopt.sh   (exit 0 = all pass, 1 = a failure)

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
# happened to be and says nothing about whether the file loaded.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
AD="$ROOT/scripts/lib/adopt-lib.sh"
WF="$ROOT/base/workflows/adopt.md"
PRACTICE="$ROOT/base/practices/handling-the-unknown.md"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary
check_init "check-adopt"

TAB="$(printf '\t')"
WORK="$(mktemp -d)" || { echo "check-adopt: FATAL — cannot create a scratch dir" >&2; exit 1; }
# check_exit_guard, NOT a bare `trap … EXIT`. A suite's exit status is its last command's, and
# only check_summary consults the failure counter — so losing that final line prints the FAIL
# diagnostics and still exits 0, reported as PASSING by selfcheck and CI. The guard fails closed
# on that, and it takes the cleanup as an argument precisely so a suite's own trap cannot silently
# replace it.
check_exit_guard "check-adopt" "rm -rf \"$WORK\""

# --- 1. classify: the four verdicts, and the order of the arms ----------------------------------
# The verdict is the first TSV field; the reason is prose and is not asserted on (asserting the
# sentence would make every wording improvement a test failure, which trains people to stop
# improving wording).
verdict() { bash "$AD" classify "$@" | cut -f1; }

eq "$(verdict skill  no  same    no)"  keep     "no baseline artifact of this identity -> keep"
eq "$(verdict skill  no  differs no)"  keep     "no collision -> keep regardless of delta"
eq "$(verdict skill  yes same    no)"  remove   "byte-identical duplicate -> remove"
eq "$(verdict skill  yes differs no)"  move     "collides but DIFFERS -> move, never remove"
eq "$(verdict skill  yes unknown no)"  escalate "delta unknown -> escalate, never a guess"

# THE ORDER OF THE ARMS, pinned as its own case. `prescribed` is tested BEFORE collision, and
# reversing them is not a stylistic difference: `.claude/scripts/precommit-gate.sh` collides with
# a shipped script by name and IS the practice's home for gate policy, so a collision-first
# classifier tells every adopting project to delete its own gate policy. Both delta values are
# asserted, because a rule that only held for `same` would still ship the bug for `differs`.
eq "$(verdict script yes same    yes)" keep "a PRESCRIBED HOME that collides is keep (identical)"
eq "$(verdict script yes differs yes)" keep "a PRESCRIBED HOME that collides is keep (differing)"

# An unmodelled kind is escalate, not an error and not a guess.
eq "$(verdict frobnicator yes same no)" escalate "an unmodelled kind -> escalate"

# --- 1b. classify: every rejectable argument is observed being REJECTED --------------------------
# The enum is closed, so the harness injects each invalid form rather than spot-checking one. A
# predicate that accepted a typo'd enum would answer a question nobody asked: `delta=diffres`
# silently taking the `unknown` arm reads as caution and is actually a parse bug.
# NOT named `bad`: that is check-lib.sh's own failure-assertion FUNCTION. Bash keeps variables and
# functions in separate namespaces so a loop variable of that name happens to work, but a name that
# reads as a call to the suite's own reporter is one edit away from becoming one.
for badargs in "skill maybe same no" "skill yes sometimes no" "skill yes same perhaps" \
               "skill yes same" "skill yes same no extra"; do
  # shellcheck disable=SC2086  # deliberate word splitting: each case is an argv, not one string
  out="$(bash "$AD" classify $badargs 2>&1)"; rc=$?
  eq "$rc" 2 "classify [$badargs] must exit 2"
  has "$out" "adopt-lib:" "classify [$badargs] must say which argument was wrong"
done

# --- 2. prescribed: the table matches the practice it transcribes --------------------------------
# The table in adopt-lib.sh is a TRANSCRIPTION of handling-the-unknown.md's prescribed-home list,
# and a transcription drifts. This is the guard against the drift that would matter: a home
# deleted from the practice while the classifier still calls it one. It is a PRESENCE check on the
# practice, which is all a text check can honestly be — it catches a removal or a rename, not a
# change of meaning.
yes "$(bash "$AD" prescribed script  precommit-gate.sh; echo $?)" "precommit-gate.sh IS a prescribed home"
yes "$(bash "$AD" prescribed rootdoc CLAUDE.md;         echo $?)" "the repo root doc IS a prescribed home"
yes "$(bash "$AD" prescribed manifest agents.toml;      echo $?)" "agents.toml IS a prescribed home"
yes "$(bash "$AD" prescribed override overrides.md;     echo $?)" "a compose-override IS a prescribed home"
no  "$(bash "$AD" prescribed script  statusline.sh;     echo $?)" "statusline.sh is NOT a prescribed home"
no  "$(bash "$AD" prescribed skill   implement-issue;   echo $?)" "a whole forked skill is NOT a prescribed home"
eq  "$(bash "$AD" prescribed nonsense x >/dev/null 2>&1; echo $?)" 2 "an unknown kind exits 2"

if [ -f "$PRACTICE" ]; then
  for token in 'agents.toml [gates]' 'agents.toml [roles]' 'precommit-gate.sh' \
               'project-scoped skill' '.ai-dev-baseline/decisions.md'; do
    if grep -Fq -- "$token" "$PRACTICE"; then ok
    else bad "handling-the-unknown.md no longer names the prescribed home '$token' that adopt-lib.sh transcribes"; fi
  done
else
  bad "base/practices/handling-the-unknown.md is missing — adopt-lib.sh's prescribed-home table has no source"
fi

# --- 2b. delta: the skill-is-a-directory trap, and unknown as a reachable answer ----------------
# `delta` exists because the obvious inline `cmp -s` is WRONG for the commonest case. A skill's
# shipped source is a directory; `cmp` on a directory returns non-zero, a workflow reads that as
# "differs", and every project's every skill is then reported as a fork carrying a delta. So the
# directory case is asserted first and against the REAL shipped tree, not a fixture — a fixture
# could accidentally be a file and prove nothing.
S1="$ROOT/agents/claude/skills/cleanup"
S2="$ROOT/agents/claude/skills/debug"
eq "$(bash "$AD" delta skill "$S1" "$S1")" same    "a skill compared with itself is same (via SKILL.md, not cmp on a dir)"
eq "$(bash "$AD" delta skill "$S1" "$S2")" differs "two different skills are differs"

# `unknown` must be REACHABLE on every way of failing to establish equality — a missing project
# copy, a missing baseline copy, and a path that is not a file at all. If any of these collapsed
# into `differs`, an unreadable install would produce a confident `move` recommendation.
eq "$(bash "$AD" delta skill "$S1" "$WORK/nope")"      unknown "a missing baseline copy is unknown, NOT differs"
eq "$(bash "$AD" delta skill "$WORK/nope" "$S1")"      unknown "a missing project copy is unknown"
eq "$(bash "$AD" delta script "$WORK" "$ROOT/install.sh")" unknown "a directory where a file is expected is unknown"
eq "$(bash "$AD" delta script "$ROOT/install.sh" "$ROOT/install.sh")" same "a plain file compares byte-wise"
eq "$(bash "$AD" delta script "$ROOT/install.sh" "$ROOT/uninstall.sh")" differs "two different files are differs"
eq "$(bash "$AD" delta skill "$S1" >/dev/null 2>&1; echo $?)" 2 "delta with too few arguments exits 2"

# AND THE PAIRING WITH classify, which is what actually ships the bug if it breaks: an `unknown`
# delta must reach `escalate`, never a verdict.
eq "$(verdict skill yes "$(bash "$AD" delta skill "$S1" "$WORK/nope")" no)" escalate \
   "an unreadable baseline copy escalates rather than recommending anything"

# --- 3. shipped: derived from the real manifest, never a second list -----------------------------
# The value of `shipped` is that it cannot disagree with install.sh about what the baseline
# installs. Asserting a hardcoded expected list here would recreate exactly the second list the
# subcommand exists to avoid, so the assertions are STRUCTURAL: every skill directory that exists
# in the tree is reported, and the kinds are the ones the classifier consumes.
shipped="$(bash "$AD" shipped "$ROOT" claude)"
for d in "$ROOT"/agents/claude/skills/*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##*/}"
  has "$shipped" "skill${TAB}${n}${TAB}claude" "shipped must report the real skill '$n'"
done
has "$shipped" "script${TAB}precommit-gate.sh${TAB}claude" "shipped must report the hook scripts"
has "$shipped" "rootdoc${TAB}CLAUDE.md${TAB}claude"        "shipped must report the root doc"
hasnt "$shipped" "gemini" "shipped <agent> must filter to that agent"
eq "$(bash "$AD" shipped "$WORK" >/dev/null 2>&1; echo $?)" 2 "shipped on a non-baseline dir exits 2"

# --- 4. scan: the surface, the boundary, and the record format ----------------------------------
# A fixture modelling getrich's documented shape: forked skills (one colliding with a baseline
# skill, one not), duplicate hook scripts, a project statusLine, a stack root doc, no agents.toml,
# and a prior framework's pin. Plus a `src/` tree that references an agent CLI — which the scan
# must NOT descend into (#29 axis 1).
FX="$WORK/getrich-shape"
mkdir -p "$FX"/.claude/{skills/{implement-issue,release},scripts,state} "$FX/src/lib/cli"
printf 'gap analysis is run by codex exec\n' > "$FX/.claude/skills/implement-issue/SKILL.md"
printf 'project release skill\n'             > "$FX/.claude/skills/release/SKILL.md"
printf '#!/bin/sh\n# apps/ packages/ scope\n' > "$FX/.claude/scripts/precommit-gate.sh"
printf '#!/bin/sh\n'                          > "$FX/.claude/scripts/statusline.sh"
printf '{"statusLine":{"type":"command","command":".claude/scripts/statusline.sh"}}\n' > "$FX/.claude/settings.json"
printf '# Cloudflare + stack conventions\n'   > "$FX/CLAUDE.md"
printf 'v1.2.3\n'                             > "$FX/.claude/UPSTREAM_VERSION"
printf 'const x = "codex exec"\n'             > "$FX/src/lib/cli/run.ts"
scan="$(bash "$AD" scan "$FX" --agents claude)"

has "$scan" "rootdoc${TAB}CLAUDE.md"                          "scan finds the root doc"
has "$scan" "skill${TAB}.claude/skills/implement-issue"       "scan finds a colliding forked skill"
has "$scan" "skill${TAB}.claude/skills/release"               "scan finds a project-only skill"
has "$scan" "script${TAB}.claude/scripts/precommit-gate.sh"   "scan finds the gate script"
has "$scan" "settings${TAB}.claude/settings.json"             "scan finds settings.json"
has "$scan" "foreign-pin${TAB}.claude/UPSTREAM_VERSION"       "scan finds a prior framework's pin"
hasnt "$scan" "src/"        "scan must NOT descend into product code (#29 axis 1)"
hasnt "$scan" "agents.toml" "scan must not invent a manifest that does not exist"

# THE HARNESS-VS-PRODUCT BOUNDARY, asserted as its own case rather than inferred from the `hasnt`
# above: a scan that found nothing at all would satisfy that assertion too.
n_skills="$(printf '%s\n' "$scan" | grep -c "^skill${TAB}")"
eq "$n_skills" 2 "scan reports exactly the two skills in the fixture"

# The record format refuses a field it cannot represent (D41/D59's rule, applied here). A file
# whose NAME carries a newline forges a record whose leading field is attacker-chosen text.
# Guarded, because some filesystems refuse the name outright — a skipped case is honest, a
# silently-passing one is not.
ODD="$FX/.claude/scripts/$(printf 'a\nb')"
if printf '#!/bin/sh\n' > "$ODD" 2>/dev/null && [ -f "$ODD" ]; then
  odd_scan="$(bash "$AD" scan "$FX" --agents claude)"
  has "$odd_scan" "warning${TAB}" "a name carrying a newline yields a warning, not a forged record"
  # And the REST of the inventory survives — refusing per field, not per scan.
  has "$odd_scan" "rootdoc${TAB}CLAUDE.md" "one unrepresentable name must not drop the other facts"
  rm -f "$ODD"
else
  check_note "SKIP: this filesystem refuses a newline in a filename; the record-format refusal is unexercised"
fi

eq "$(bash "$AD" scan "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "scan of a missing dir exits 2"
eq "$(bash "$AD" scan "$FX" --agents >/dev/null 2>&1; echo $?)" 2 "scan --agents with no value exits 2"

# --- 5. the getrich inventory, end to end --------------------------------------------------------
# #20's acceptance criterion, discharged against the SHAPE rather than the live repo (see the
# header): remove the duplicate statusline/gate hook, keep the stack CLAUDE.md, keep the
# path-scoped precommit-gate, and propose gap_analysis = codex.
#
# The `same`/`differs` inputs are computed by comparing against the real shipped artifact, so this
# exercises the pipeline the workflow actually runs rather than a hand-written verdict.
cp "$ROOT/agents/claude/scripts/statusline.sh" "$FX/.claude/scripts/statusline.sh"   # a true duplicate
delta_of() {  # <project-file> <baseline-file>
  if [ ! -f "$2" ]; then printf 'unknown\n'
  elif cmp -s "$1" "$2"; then printf 'same\n'
  else printf 'differs\n'; fi
}
eq "$(delta_of "$FX/.claude/scripts/statusline.sh" "$ROOT/agents/claude/scripts/statusline.sh")" same \
   "the copied statusline is byte-identical"
eq "$(verdict script yes "$(delta_of "$FX/.claude/scripts/statusline.sh" "$ROOT/agents/claude/scripts/statusline.sh")" \
        "$(bash "$AD" prescribed script statusline.sh >/dev/null 2>&1 && echo yes || echo no)")" remove \
   "getrich: the duplicated statusline script is REMOVE"
eq "$(verdict script yes "$(delta_of "$FX/.claude/scripts/precommit-gate.sh" "$ROOT/agents/claude/scripts/precommit-gate.sh")" \
        "$(bash "$AD" prescribed script precommit-gate.sh >/dev/null 2>&1 && echo yes || echo no)")" keep \
   "getrich: the path-scoped precommit-gate is KEEP (removing it would lose apps/packages scoping)"
eq "$(verdict rootdoc no unknown \
        "$(bash "$AD" prescribed rootdoc CLAUDE.md >/dev/null 2>&1 && echo yes || echo no)")" keep \
   "getrich: the stack CLAUDE.md is KEEP"
eq "$(bash "$AD" roles-infer "$FX" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" codex \
   "getrich: gap_analysis = codex is inferred from the inline codex exec"

# --- 6. roles-infer: no signal means NO PROPOSAL, and two signals mean AMBIGUOUS -----------------
# The dangerous direction here is inventing intent. A project that says nothing must produce
# `none` — never the baseline's own default wearing the project's name.
EMPTY="$WORK/empty"; mkdir -p "$EMPTY/.claude"
eq "$(bash "$AD" roles-infer "$EMPTY" | awk -F"$TAB" '$1=="gap_analysis"{print $2}')" none \
   "a project with no signal proposes NOTHING for gap_analysis"
eq "$(bash "$AD" roles-infer "$EMPTY" | awk -F"$TAB" '$1=="review"{print $2}')" none \
   "...and nothing for review either"

AMB="$WORK/ambiguous"; mkdir -p "$AMB/.claude/skills/x"
printf 'the code-review pass runs codex exec\nthe code-review pass also runs gemini\n' > "$AMB/.claude/skills/x/SKILL.md"
eq "$(bash "$AD" roles-infer "$AMB" | awk -F"$TAB" '$1=="review"{print $2}')" ambiguous \
   "two agents named for one role -> ambiguous, not a coin flip"

# --- 7. propose: an uninferred role is COMMENTED, and the output is a real manifest --------------
prop="$(bash "$AD" roles-infer "$FX" | bash "$AD" propose)"
printf '%s\n' "$prop" > "$WORK/proposed.toml"
has "$prop" 'gap_analysis' "the inferred role is present"
# The load-bearing assertion: read it back through the REAL reader, not by grepping the text this
# suite just produced. A proposal that renders prettily and parses to nothing is the failure that
# matters, and only the consumer can see it.
eq "$(adb_toml_get "$WORK/proposed.toml" roles gap_analysis)" '"codex"' \
   "the proposed manifest parses through adb_toml_get"
eq "$(adb_toml_get "$WORK/proposed.toml" roles review >/dev/null 2>&1; echo $?)" 1 \
   "an UNINFERRED role must be absent to the reader (commented), not set to a guess"
eq "$(adb_toml_get "$WORK/proposed.toml" roles primary >/dev/null 2>&1; echo $?)" 1 \
   "primary is never inferred — it is a fact about the operator, not the repo"

# --- 8. stack: every label the pin accepts is reachable, and unknown is a real answer ------------
mk() { mkdir -p "$WORK/stack-$1" && printf '%s' "${2:-}" > "$WORK/stack-$1/${3:-x}"; printf '%s' "$WORK/stack-$1"; }
eq "$(bash "$AD" stack "$(mk node '{}' package.json)")"        node   "package.json -> node"
mkdir -p "$WORK/stack-mono"; printf '{}' > "$WORK/stack-mono/package.json"; printf '' > "$WORK/stack-mono/pnpm-workspace.yaml"
eq "$(bash "$AD" stack "$WORK/stack-mono")"                    node-monorepo "a workspace file -> node-monorepo"
eq "$(bash "$AD" stack "$(mk rust '' Cargo.toml)")"            rust   "Cargo.toml -> rust"
eq "$(bash "$AD" stack "$(mk go 'module x' go.mod)")"          go     "go.mod -> go"
eq "$(bash "$AD" stack "$(mk py '' pyproject.toml)")"          python "pyproject.toml -> python"
eq "$(bash "$AD" stack "$(mk sh '#!/bin/sh' a.sh)")"           shell  "a bare shell repo -> shell"
mkdir -p "$WORK/stack-none"
eq "$(bash "$AD" stack "$WORK/stack-none")"                    unknown "an unrecognised project -> unknown, which is an ANSWER"
eq "$(bash "$AD" stack "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "stack of a missing dir exits 2"

# EVERY label `stack` can print must be a label `pin-render` accepts. These are two enums in two
# functions, and a stack the pin rejects would fail the run at the last step with a value the
# scan itself produced.
for s in node node-monorepo rust go python php php-wordpress shell unknown; do
  yes "$(bash "$AD" pin-render v1 abcdef1234 2026-08-12 "$s" >/dev/null 2>&1; echo $?)" \
      "pin-render accepts the stack label '$s' that stack can emit"
done

# --- 9. the pin: validation, round-trip, and the drift command ----------------------------------
bash "$AD" pin-render "v0.5.0" "b6158eff2604875e1e522a57df71d7dfced7ace5" "2026-08-12" shell "claude,codex" \
  > "$WORK/upstream.toml"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" commit)"  "b6158eff2604875e1e522a57df71d7dfced7ace5" "pin round-trips the commit"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" stack)"   shell    "pin round-trips the stack"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" version)" "v0.5.0" "pin round-trips the version"
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" agents | tr '\n' ',')" "claude,codex," "pin round-trips the agent list"

# The commit is the load-bearing field — `pin-drift` feeds it to git — so every unusable form is
# observed being refused. A pin that accepted "HEAD" or an empty string would produce a drift
# command that silently compares the wrong thing.
for badpin in "v1 zzzz 2026-08-12 shell" "v1 HEAD 2026-08-12 shell" "v1 '' 2026-08-12 shell" \
              "v1 abc 2026-08-12 shell" "v1 abcdef1234 12-08-2026 shell" \
              "v1 abcdef1234 2026-8-12 shell" "v1 abcdef1234 2026-08-12 cobol"; do
  # shellcheck disable=SC2086  # deliberate word splitting: each case is an argv
  eq "$(eval bash \"\$AD\" pin-render $badpin >/dev/null 2>&1; echo $?)" 2 "pin-render rejects [$badpin]"
done
eq "$(bash "$AD" pin-read "$WORK/upstream.toml" nope >/dev/null 2>&1; echo $?)" 2 "pin-read rejects an unknown key"
eq "$(bash "$AD" pin-read "$WORK/missing.toml" commit >/dev/null 2>&1; echo $?)" 2 "pin-read on a missing file exits 2"

drift="$(bash "$AD" pin-drift "$WORK/upstream.toml" "$ROOT")"
has "$drift" "b6158eff2604875e1e522a57df71d7dfced7ace5..HEAD" "pin-drift names the pinned commit"
has "$drift" "git -C $ROOT" "pin-drift targets the baseline clone"
eq "$(bash "$AD" pin-drift "$WORK/upstream.toml" "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "pin-drift on a missing baseline exits 2"

# --- 10. hygiene: each axis fires, and the ignore axis is proven able to STAY SILENT ------------
HY="$WORK/hygiene"; mkdir -p "$HY/.claude/state" "$HY/src"
git -C "$HY" init -q >/dev/null 2>&1
printf 'const x = "codex exec"\n' > "$HY/src/run.ts"
printf '{"statusLine":{"type":"command","command":"x"},"hooks":{}}\n' > "$HY/.claude/settings.json"
printf 'home is /Users/someone/Code/thing\n' > "$HY/.claude/machine.md"
printf 'token: ghp_abcdefghijklmnopqrstuvwxyz\n' > "$HY/.claude/leak.md"
printf '.claude/state/\n' > "$HY/.gitignore"
git -C "$HY" add -A >/dev/null 2>&1
hy="$(bash "$AD" hygiene "$HY" --agents claude)"
has "$hy" "product-code${TAB}note${TAB}src/"   "axis 1: product code is reported, not classified"
has "$hy" "distributable${TAB}warn"            "axis 2: a machine-local path in a TRACKED file is reported"
has "$hy" "precedence${TAB}note"               "axis 3: a layered statusLine is reported"

# axis 1 fires ONCE for a three-agent scan, not once per agent.
eq "$(bash "$AD" hygiene "$HY" | grep -c "^product-code${TAB}")" 1 \
   "axis 1 reports the product-code boundary once, not once per agent"

# THE SECRET IS NEVER ECHOED. This is the assertion that matters most in this block:
# base/practices/logging-and-secrets.md forbids emitting a credential, and a diagnostic pasted
# into a PR body is exactly the durable, indexed place it must not land.
has  "$hy" "prefix 'ghp_'"                       "axis 2 names the credential PREFIX so it can be found"
hasnt "$hy" "ghp_abcdefghijklmnopqrstuvwxyz"     "axis 2 must NEVER echo the credential itself"

# The ignore axis: three inputs, three DISTINGUISHABLE answers. Two would let a stuck predicate
# pass, and a stuck predicate is exactly what shipped here first (it matched the pathname column
# of `git check-ignore -v`, so every input looked explicit and the axis was a permanent no-op).
ig() { printf '%s\n' "$1" > "$HY/.gitignore"; bash "$AD" hygiene "$HY" --agents claude | grep "^ignore-risk" || true; }
has   "$(ig '*.json')"        "BROAD ignore rule"   "a blanket *.json IS reported (the unraid shape)"
eq    "$(ig '.claude/state/')" ""                   "an explicit state rule is SILENT"
has   "$(ig '')"              "is NOT gitignored"   "no rule at all is reported, and differently"

eq "$(bash "$AD" hygiene "$WORK/nope" >/dev/null 2>&1; echo $?)" 2 "hygiene of a missing dir exits 2"

# --- 11. plan: the ORDERING is the decision ------------------------------------------------------
# move strictly before remove is the assertion with teeth. Reversed, the plan has the operator
# delete a forked skill before its delta has been re-homed, and a run that stops in between has
# silently cost the project a capability.
plan="$(printf 'keep\trootdoc\tCLAUDE.md\tr\nremove\tscript\tdup.sh\tr\nmove\tskill\tfork\tr\nescalate\tother\t?\tr\n' \
        | bash "$AD" plan)"
i_esc="$(printf '%s\n' "$plan" | grep -n '^## escalate' | cut -d: -f1)"
i_mov="$(printf '%s\n' "$plan" | grep -n '^## move'     | cut -d: -f1)"
i_rem="$(printf '%s\n' "$plan" | grep -n '^## remove'   | cut -d: -f1)"
i_kep="$(printf '%s\n' "$plan" | grep -n '^## keep'     | cut -d: -f1)"
if [ "$i_esc" -lt "$i_mov" ] && [ "$i_mov" -lt "$i_rem" ] && [ "$i_rem" -lt "$i_kep" ]; then ok
else bad "plan ordering must be escalate < move < remove < keep (got $i_esc/$i_mov/$i_rem/$i_kep)"; fi

# A verdict with no members prints no heading (rather than an empty section the reader must parse).
hasnt "$(printf 'keep\trootdoc\tCLAUDE.md\tr\n' | bash "$AD" plan)" "## remove" \
      "an empty verdict prints no heading"
eq "$(printf '' | bash "$AD" plan)" "" "an empty inventory yields an empty plan, not an error"
eq "$(bash "$AD" plan extra </dev/null >/dev/null 2>&1; echo $?)" 2 "plan takes no arguments"

# --- 12. no subcommand mutates the project it is given ------------------------------------------
# THE BOUNDARY, asserted mechanically rather than trusted to review. /adopt v1 never deletes,
# moves or edits a file in the scanned project — so every read-only subcommand is run against a
# fixture whose complete state is hashed before and after. This is the assertion that would catch
# a future `remove` arm growing an actual `rm`.
snapshot() { ( cd "$1" && find . -type f -not -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do
                 printf '%s ' "$f"; cksum < "$f"; done ); }
before="$(snapshot "$FX")"
bash "$AD" scan "$FX" >/dev/null 2>&1
bash "$AD" hygiene "$FX" >/dev/null 2>&1
bash "$AD" roles-infer "$FX" >/dev/null 2>&1
bash "$AD" stack "$FX" >/dev/null 2>&1
after="$(snapshot "$FX")"
eq "$after" "$before" "no read-only subcommand may alter one byte of the scanned project"

# --- 13. the workflow still delegates to this library -------------------------------------------
# The drift guard the sibling suites carry: a workflow that quietly stopped calling a predicate
# and started restating it inline would pass every assertion above while shipping the untested
# copy this whole split exists to prevent.
if [ -f "$WF" ]; then
  for sub in scan classify prescribed delta roles-infer propose hygiene pin-render plan; do
    if grep -Fq -- "adopt-lib.sh $sub" "$WF" || grep -Fq -- "ADOPT_LIB}} $sub" "$WF"; then ok
    else bad "base/workflows/adopt.md no longer delegates '$sub' to adopt-lib.sh"; fi
  done
  # The v1 boundary is a PROMISE THE WORKFLOW MAKES, so it is pinned in the workflow text too.
  grep -Fq 'never deletes' "$WF" || bad "adopt.md must state the v1 boundary (it never deletes or moves)"
else
  bad "base/workflows/adopt.md is missing"
fi

check_summary "check-adopt"
