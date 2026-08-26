#!/usr/bin/env bash
# ai-dev-baseline — the mutation-harness gate is a guard, so it is observed failing (#441).
#
# `scripts/mutation-gate.sh` decides whether a `--mutation` harness has anything new to say about a
# change, and a gate that decides wrong in the SKIP direction is invisible: the step is green, the
# job is green, and the harness that would have gone red never ran. So every rule that can produce
# a SKIP is driven to both answers here against throwaway git repositories, and the shapes that
# must FAIL CLOSED — no repository, an unresolvable base, a shallow clone with no merge-base — are
# each required to answer RUN and to say why.
#
# What is asserted:
#   1. the decision: untouched inputs SKIP; a committed, an uncommitted, and an untracked change on
#      an input each RUN; a change elsewhere SKIPs; a directory input covers its subtree; a file
#      input does not match a sibling that merely shares its prefix;
#   2. every SKIP names the base, the merge-base, the count compared and the inputs — a skip that
#      says nothing is the failure this gate exists to prevent;
#   3. fail-closed: not a repository, a base that does not resolve, no merge-base → RUN, with the
#      reason on the line; ADB_MUTATION_RUN_ALL → RUN, saying the override fired;
#   4. `run`: an unknown step, a step with no inputs, and a command that is not the registry's own
#      are each REFUSED (2) — never silently run and never silently skipped; a command that runs
#      passes its exit status through; a SKIP exits 0 and lands in GITHUB_STEP_SUMMARY when set;
#   5. the shipped registry: every `*-mutation` step declares inputs, and each declares its own
#      harness script, `scripts/check-lib.sh` and `scripts/lib/common.sh` — the two files every
#      harness sources — so a change to the shared scaffold can never be gated away;
#   6. the wiring: every `--mutation` invocation in `.github/workflows/ci.yml` goes through the
#      gate, and the scheduled workflow's matrix names every `*-mutation` step in the registry, so a
#      harness cannot be gated per-PR without also being run unconditionally on the schedule.
#
# Never mutates the tracked tree. Usage: bash scripts/check-mutation-gate.sh (0 = pass, 1 = fail)

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and the cd.
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
# shellcheck source=/dev/null
. "$ROOT/scripts/check-lib.sh"   # ok/bad/eq/has/hasnt/yes/no + check_summary + check_exit_guard

MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *) echo "usage: check-mutation-gate.sh [--mutation]" >&2; exit 2 ;;
esac
[ "$#" -gt 1 ] && { echo "usage: check-mutation-gate.sh [--mutation]" >&2; exit 2; }

# THE GATE'S ENVIRONMENT IS THIS SUITE'S TO SET, never inherited. The scheduled workflow runs the
# registry with ADB_MUTATION_RUN_ALL=1, and this suite is a registered step there — so the override
# reached the fixture cases that expect a SKIP and turned every row red for the wrong reason, on
# the very run that exists to catch a wrong input set (#441). Each case below sets exactly the
# variables it means to test.
unset ADB_MUTATION_RUN_ALL ADB_MUTATION_BASE

work="$(mktemp -d)" || { echo "check-mutation-gate: cannot create a scratch dir" >&2; exit 1; }
check_exit_guard "check-mutation-gate" "rm -rf \"$work\""

# ====================== --mutation: the gate's rules must be observed going red ==================
# Each row breaks ONE rule of `scripts/mutation-gate.sh` in a COPY of the tree and runs this whole
# suite against it, requiring exit 1 on the row's OWN witness. The two rows that matter most are the
# first two: a gate that always skips is invisible (every step green, every job green, the harness
# that would have caught the defect never ran), and a gate that always runs is #441 undone with the
# gate's own line saying otherwise.
#
# The copy carries every top-level path the shipped registry's inputs name (section 5 asserts each
# exists), plus `.github` for the wiring pins — small trees, all of them; `.git` is not copied.
if [ "$MODE" = mutation ]; then
  mut_prepare() {
    local d="$1"
    check_copy_subtrees "$ROOT" "$d" scripts .github bin agents .claude >/dev/null 2>&1 || return 1
    cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$d/" 2>/dev/null || return 1
    printf '%s' "$d/scripts/mutation-gate.sh"
  }
  mut_run() {
    local d="$1"
    bash -n "$d/scripts/mutation-gate.sh" 2>/dev/null \
      || { printf 'the mutated mutation-gate.sh no longer PARSES\n'; return 9; }
    bash "$d/scripts/check-mutation-gate.sh" 2>&1
  }

  # THE CONTROL, first: an unmutated copy must pass, or every row below is red for the wrong reason.
  mut_ctl="$work/control"
  if mut_prepare "$mut_ctl" >/dev/null; then
    mut_out="$(mut_run "$mut_ctl" 2>&1)"; mut_rc=$?
    yes "$mut_rc" "control: an UNMUTATED copy passes (else every row below is red for the wrong reason)"
    has "$mut_out" "check-mutation-gate: PASS" "control: …and says PASS"
  else
    bad "control: could not build the tree copy"
  fi

  check_mut always-skip \
    'if [ "$nhits" -gt 0 ]; then' \
    'if [ "$nhits" -gt 999999 ]; then' \
    'a COMMITTED change to an input since the base: exit 0 (run)'
  # `check_mutate_literal` matches within ONE line and replaces the FIRST hit, so each row is a
  # single-line literal, and the two `return 11` sites are told apart by order: the merge-base
  # branch comes first in `gate_decide`, so the first hit is the one this row is about.
  check_mut always-run \
    '  return 10' \
    '  return 0' \
    'untouched inputs: exit 10 (skip)'
  check_mut unresolvable-base-skips \
    '    return 11' \
    '    return 10' \
    'a base that does not resolve: RUN on the fail-closed code (11), never skip'
  check_mut override-ignored \
    'if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then' \
    'if [ -n "${ADB_MUTATION_RUN_ALL_NEVER:-}" ]; then' \
    'ADB_MUTATION_RUN_ALL=1: run, on its own distinct code (12)'
  check_mut skip-line-unstated-base \
    '"$step" "$base" "${mb:0:12}" "$nchanged" "$inputs"' \
    '"$step" "(unstated)" "${mb:0:12}" "$nchanged" "$inputs"' \
    'and names the base it compared against'
  check_mut untracked-ignored \
    'printf '"'"'%s\n%s\n'"'"' "$tracked" "$untracked"' \
    'printf '"'"'%s\n%s\n'"'"' "$tracked" ""' \
    'an UNTRACKED file under a directory input: run'
  check_mut run-accepts-foreign-command \
    '[ "$regcmd" = "$want" ] || {' \
    '[ "$regcmd" = "$regcmd" ] || {' \
    'a command that is not the registry'"'"'s own for that step is REFUSED'
  check_mut run-swallows-harness-status \
    '    exec $regcmd ;;' \
    '    $regcmd; exit 0 ;;' \
    'passes its OWN exit status through (7)'

  check_mutation_pool "check-mutation-gate" "$work" mut_prepare mut_run 4
  check_summary "check-mutation-gate-mutation"
fi

# mkrepo <dir> — a throwaway repository carrying the gate itself (it resolves scripts/lib/common.sh
# relative to its own location), a stub library and suite under the shape the registry uses, and
# an `origin/main` that is one commit BEHIND the branch we test on — so "against the base" and
# "against HEAD" are different questions, and the test can tell which one the gate asked.
#
# History:  base ── (touch scripts/lib/other.sh) ── HEAD        origin/main = base
mkrepo() {
  local d="$1"
  mkdir -p "$d/scripts/lib" || return 1
  cp "$ROOT/scripts/mutation-gate.sh" "$d/scripts/mutation-gate.sh" || return 1
  cp "$ROOT/scripts/lib/common.sh" "$d/scripts/lib/common.sh" || return 1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/lib/stub.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/check-stub.sh"
  printf 'x\n' > "$d/scripts/check-lib.sh"
  printf 'unrelated\n' > "$d/README.md"
  mkdir -p "$d/base/practices" && printf 'p\n' > "$d/base/practices/a.md"
  check_git "$d" init -q -b main >/dev/null 2>&1 || return 1
  check_git "$d" add -A >/dev/null 2>&1 || return 1
  check_git "$d" commit -q -m base >/dev/null 2>&1 || return 1
  # `origin/main` is a plain remote-tracking ref here: the gate only ever asks git to resolve it.
  check_git "$d" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || return 1
  printf 'o\n' > "$d/scripts/lib/other.sh"
  check_git "$d" add -A >/dev/null 2>&1 || return 1
  check_git "$d" commit -q -m "touch other" >/dev/null 2>&1 || return 1
}

# gate <repo> <args…> — run the COPIED gate from inside <repo>, capturing output and status.
OUT=""; RC_=0
gate() {
  local d="$1"; shift
  OUT="$(cd "$d" && bash scripts/mutation-gate.sh "$@" 2>&1)"; RC_=$?
}

R="$work/r"
mkrepo "$R" || { echo "check-mutation-gate: cannot build the fixture repository" >&2; exit 1; }
INPUTS=(scripts/check-stub.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/stub.sh)

# ============================== 1. the decision =================================================
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "10" "untouched inputs: exit 10 (skip)"
has "$OUT" "SKIP: stub-mutation" "…and the line says SKIP and names the step"
has "$OUT" "against origin/main" "…and names the base it compared against (the default: origin/<default>)"
has "$OUT" "1 changed file(s) compared" "…and counts what it compared (the one commit past the base)"
has "$OUT" "inputs: scripts/check-stub.sh, scripts/check-lib.sh, scripts/lib/common.sh, scripts/lib/stub.sh" \
  "…and lists every input it checked"
mb="$(git -C "$R" rev-parse origin/main)"
has "$OUT" "merge-base ${mb:0:12}" "…and names the merge-base sha"

# A committed change on an input, past the base.
printf 'changed\n' >> "$R/scripts/lib/stub.sh"
check_git "$R" commit -q -am "touch stub" >/dev/null 2>&1
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "0" "a COMMITTED change to an input since the base: exit 0 (run)"
has "$OUT" "RUN: stub-mutation — 1 changed file(s) touch its inputs: scripts/lib/stub.sh" \
  "…and the line names the file that decided it"
check_git "$R" reset -q --hard HEAD~1 >/dev/null 2>&1

# An UNCOMMITTED change on an input: the working tree is what is compared, not HEAD.
printf 'dirty\n' >> "$R/scripts/check-stub.sh"
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "0" "an UNCOMMITTED change to an input: exit 0 (run) — the working tree is what is compared"
has "$OUT" "scripts/check-stub.sh" "…naming the dirty file"
check_git "$R" checkout -q -- scripts/check-stub.sh

# A DIRECTORY input covers its subtree — and `scripts/lib` is deliberately NOT the one used here:
# the fixture's history already touches `scripts/lib/other.sh` past the base, so that directory is
# a hit by construction (asserted, because it is what makes the file-vs-directory distinction real).
gate "$R" should-run stub-mutation -- scripts/check-stub.sh scripts/lib
eq "$RC_" "0" "a directory input whose subtree carries the committed change (scripts/lib/other.sh): run"
has "$OUT" "scripts/lib/other.sh" "…naming the file under it"
gate "$R" should-run stub-mutation -- scripts/check-stub.sh base/practices
eq "$RC_" "10" "a directory input with nothing new under it: skip"
printf 'new\n' > "$R/base/practices/brand-new.md"
gate "$R" should-run stub-mutation -- scripts/check-stub.sh base/practices
eq "$RC_" "0" "an UNTRACKED file under a directory input: run"
has "$OUT" "base/practices/brand-new.md" "…naming the untracked file"
gate "$R" should-run stub-mutation -- scripts/check-stub.sh base/practices/
eq "$RC_" "0" "a directory input written WITH a trailing slash matches the same subtree"
rm -f "$R/base/practices/brand-new.md"

# A change ELSEWHERE is not a hit — and a sibling sharing a file input's PREFIX is not either.
printf 'more\n' >> "$R/README.md"
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "10" "a change outside every input: skip"
has "$OUT" "2 changed file(s) compared" "…and the compared count includes it (it was seen, not matched)"
check_git "$R" checkout -q -- README.md
printf 'sib\n' > "$R/scripts/lib/stub.sh.bak"
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "10" "a sibling that merely shares a FILE input's prefix (stub.sh.bak vs stub.sh) is not a match"
rm -f "$R/scripts/lib/stub.sh.bak"

# --base outranks ADB_MUTATION_BASE, which outranks the default.
gate "$R" should-run stub-mutation --base HEAD -- "${INPUTS[@]}"
eq "$RC_" "10" "--base HEAD: nothing past HEAD, skip"
has "$OUT" "against HEAD" "…and the line names the base that was actually used"
OUT="$(cd "$R" && ADB_MUTATION_BASE=HEAD~1 bash scripts/mutation-gate.sh should-run stub-mutation -- "${INPUTS[@]}" 2>&1)"; RC_=$?
has "$OUT" "against HEAD~1" "ADB_MUTATION_BASE is honoured when --base is absent"
OUT="$(cd "$R" && ADB_MUTATION_BASE=HEAD~1 bash scripts/mutation-gate.sh should-run stub-mutation --base HEAD -- "${INPUTS[@]}" 2>&1)"; RC_=$?
has "$OUT" "against HEAD" "…and --base outranks it"
hasnt "$OUT" "HEAD~1" "…(the env value does not leak into the line)"

# ============================== 2. fail-closed ==================================================
OUT="$(cd "$R" && ADB_MUTATION_RUN_ALL=1 bash scripts/mutation-gate.sh should-run stub-mutation -- "${INPUTS[@]}" 2>&1)"; RC_=$?
eq "$RC_" "12" "ADB_MUTATION_RUN_ALL=1: run, on its own distinct code (12)"
has "$OUT" "ADB_MUTATION_RUN_ALL is set" "…and the line says the override fired, not that inputs changed"

gate "$R" should-run stub-mutation --base no-such-ref -- "${INPUTS[@]}"
eq "$RC_" "11" "a base that does not resolve: RUN on the fail-closed code (11), never skip"
has "$OUT" "does not resolve" "…and the line says why"
has "$OUT" "fail-closed" "…and says it is the fail-closed path"

# No merge-base: an unrelated root, which is what a shallow clone looks like to merge-base.
check_git "$R" checkout -q --orphan lonely >/dev/null 2>&1
check_git "$R" commit -q --allow-empty -m lonely >/dev/null 2>&1
gate "$R" should-run stub-mutation --base main -- "${INPUTS[@]}"
eq "$RC_" "11" "no merge-base with the base: RUN on the fail-closed code (11)"
has "$OUT" "no merge-base" "…and says so"
check_git "$R" checkout -q main >/dev/null 2>&1
check_git "$R" branch -q -D lonely >/dev/null 2>&1

N="$work/norepo"; mkdir -p "$N/scripts/lib"
cp "$ROOT/scripts/mutation-gate.sh" "$N/scripts/" && cp "$ROOT/scripts/lib/common.sh" "$N/scripts/lib/"
gate "$N" should-run stub-mutation -- scripts/x.sh
eq "$RC_" "11" "not a git repository at all: RUN on the fail-closed code (11)"
has "$OUT" "not a git repository" "…and says so"

gate "$R" base
eq "$RC_" "0" "base: resolves on the fixture"
has "$OUT" "origin/main (merge-base $mb)" "…printing the ref and the merge-base"
gate "$R" base --base no-such-ref
eq "$RC_" "3" "base: an unresolvable ref exits 3"

# ============================== 3. usage refusals ===============================================
gate "$R" should-run stub-mutation
eq "$RC_" "2" "should-run with no inputs after -- is a usage error"
gate "$R" should-run stub-mutation --
eq "$RC_" "2" "should-run with an empty input list is a usage error"
gate "$R" should-run 'bad name' -- scripts/x
eq "$RC_" "2" "a step name outside the slug grammar is refused"
gate "$R" nonsense
eq "$RC_" "2" "an unknown subcommand is a usage error"
gate "$R"
eq "$RC_" "2" "no subcommand is a usage error"

# ============================== 4. `run` — the CI form ==========================================
# A registry is needed for `run`, and the fixture's has to be a real `selfcheck.sh --list`: copy the
# shipped runner in, so the lookup path is the one CI exercises. Its registry names steps whose
# scripts do not exist in the fixture; only the row lookup runs, never the steps.
cp "$ROOT/scripts/selfcheck.sh" "$R/scripts/selfcheck.sh"
# Register a stub step WITH inputs and one WITHOUT, by editing the COPY.
printf '#!/usr/bin/env bash\necho gated-ran; exit "${STUB_RC:-0}"\n' > "$R/scripts/check-gated.sh"
printf '#!/usr/bin/env bash\necho bare-ran\n' > "$R/scripts/check-bare.sh"
{ printf '\n'
  printf 'add gated-mutation      bash scripts/check-gated.sh --mutation\n'
  printf 'inputs gated-mutation   scripts/check-gated.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/stub.sh\n'
  printf 'add bare                bash scripts/check-bare.sh\n'; } > "$work/reg.frag"
awk -v frag="$work/reg.frag" '
  /^add install-dry-run/ { while ((getline l < frag) > 0) print l }
  { print }
  ' "$R/scripts/selfcheck.sh" > "$work/sc.tmp" && mv "$work/sc.tmp" "$R/scripts/selfcheck.sh"
grep -q '^inputs gated-mutation ' "$R/scripts/selfcheck.sh" && ok \
  || bad "fixture setup: could not register the gated step in the copied runner"
# The fixture's own additions are COMMITTED and the base advanced to them, so the only changes the
# gate can see from here on are the ones each case makes on purpose.
check_git "$R" add -A >/dev/null 2>&1 && check_git "$R" commit -q -m "registry" >/dev/null 2>&1 \
  && check_git "$R" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 \
  || bad "fixture setup: could not commit the registry fixture"
row="$(cd "$R" && bash scripts/selfcheck.sh --list | awk -F'\t' '$1 == "gated-mutation"')"
eq "$(printf '%s' "$row" | cut -f5)" "scripts/check-gated.sh,scripts/check-lib.sh,scripts/lib/common.sh,scripts/lib/stub.sh" \
  "--list carries the declared inputs as its fifth field, comma-joined"
eq "$(cd "$R" && bash scripts/selfcheck.sh --list | awk -F'\t' '$1 == "bare" {print $5}')" "-" \
  "…and a step with no inputs shows '-' there"

gate "$R" run gated-mutation -- bash scripts/check-gated.sh --mutation
eq "$RC_" "0" "run: untouched inputs → exit 0"
has "$OUT" "SKIP: gated-mutation" "…printing the SKIP line"
hasnt "$OUT" "gated-ran" "…and the harness did NOT run"

printf 'dirty\n' >> "$R/scripts/lib/stub.sh"
gate "$R" run gated-mutation -- bash scripts/check-gated.sh --mutation
eq "$RC_" "0" "run: a touched input → the harness runs and its 0 is the exit status"
has "$OUT" "RUN: gated-mutation" "…printing the RUN line first"
has "$OUT" "gated-ran" "…and the harness's own output follows"
OUT="$(cd "$R" && STUB_RC=7 bash scripts/mutation-gate.sh run gated-mutation -- bash scripts/check-gated.sh --mutation 2>&1)"; RC_=$?
eq "$RC_" "7" "run: a harness that fails passes its OWN exit status through (7), not the gate's"
check_git "$R" checkout -q -- scripts/lib/stub.sh

gate "$R" run no-such-step -- bash scripts/check-gated.sh --mutation
eq "$RC_" "2" "run: an unregistered step is REFUSED, not run"
has "$OUT" "not a registered selfcheck step" "…and says so"
gate "$R" run gated-mutation -- bash scripts/check-bare.sh
eq "$RC_" "2" "run: a command that is not the registry's own for that step is REFUSED"
has "$OUT" "disagree" "…naming the disagreement between the workflow line and the registry"
hasnt "$OUT" "bare-ran" "…and nothing ran"
gate "$R" run bare -- bash scripts/check-bare.sh
eq "$RC_" "2" "run: a step that declares no inputs is REFUSED — nothing can be skipped on their strength"
has "$OUT" "declares no inputs" "…and says so"
gate "$R" run gated-mutation
eq "$RC_" "2" "run: no command after the step is a usage error"

# The job summary: a SKIP lands there when the variable names a file; absence is fine.
: > "$work/summary.md"
OUT="$(cd "$R" && GITHUB_STEP_SUMMARY="$work/summary.md" bash scripts/mutation-gate.sh run gated-mutation -- bash scripts/check-gated.sh --mutation 2>&1)"; RC_=$?
has "$(cat "$work/summary.md")" "SKIP: gated-mutation" "a SKIP is appended to GITHUB_STEP_SUMMARY when it is set"
printf 'dirty\n' >> "$R/scripts/lib/stub.sh"
: > "$work/summary.md"
OUT="$(cd "$R" && GITHUB_STEP_SUMMARY="$work/summary.md" bash scripts/mutation-gate.sh run gated-mutation -- bash scripts/check-gated.sh --mutation 2>&1)"; RC_=$?
eq "$(cat "$work/summary.md")" "" "…and a RUN is NOT (its line names files from the diff, which is text a PR author chose)"
has "$OUT" "RUN: gated-mutation" "…while the RUN line still reaches the log"
check_git "$R" checkout -q -- scripts/lib/stub.sh

# ============================== 5. the shipped registry =========================================
LIST="$(bash "$ROOT/scripts/selfcheck.sh" --list)" || bad "the shipped registry could not be listed"
MUT_STEPS="$(printf '%s\n' "$LIST" | awk -F'\t' '$1 ~ /-mutation$/ {print $1}')"
[ -n "$MUT_STEPS" ] && ok || bad "the shipped registry names no *-mutation step (the scan matched nothing)"
n_mut=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  n_mut=$((n_mut + 1))
  inputs="$(printf '%s\n' "$LIST" | awk -F'\t' -v s="$s" '$1 == s {print $5}')"
  cmd="$(printf '%s\n' "$LIST" | awk -F'\t' -v s="$s" '$1 == s {print $2}')"
  harness="$(printf '%s' "$cmd" | awk '{print $2}')"
  [ -n "$inputs" ] && [ "$inputs" != "-" ] && ok || bad "$s declares no inputs — it would be run unconditionally AND refused by the gate"
  case ",$inputs," in *",$harness,"*) ok ;; *) bad "$s: its inputs do not name its own harness ($harness)" ;; esac
  case ",$inputs," in *",scripts/check-lib.sh,"*) ok ;; *) bad "$s: its inputs do not name scripts/check-lib.sh, which every harness sources" ;; esac
  case ",$inputs," in *",scripts/lib/common.sh,"*) ok ;; *) bad "$s: its inputs do not name scripts/lib/common.sh, which every harness sources" ;; esac
  # Every declared input must EXIST in the tree: a typo'd path is an input that can never match,
  # i.e. a harness silently gated off a file that does change.
  IFS=',' read -r -a arr <<< "$inputs"
  for p in "${arr[@]}"; do
    [ -e "$ROOT/${p%/}" ] && ok || bad "$s: declared input '$p' does not exist in the tree — it can never match a change"
  done
done <<EOF
$MUT_STEPS
EOF
printf 'check-mutation-gate: %s *-mutation step(s) in the shipped registry checked\n' "$n_mut"

# ============================== 6. the wiring ===================================================
# Every `--mutation` invocation in ci.yml goes through the gate. A `run:` line invoking a harness's
# --mutation mode directly is the pre-#441 shape: unconditional, ~40 minutes of critical path.
direct="$(grep -nE '^[^#]*run: *bash scripts/check-[a-z-]+\.sh --mutation' "$ROOT/.github/workflows/ci.yml" || true)"
[ -z "$direct" ] && ok || bad "ci.yml still invokes a mutation harness directly, outside the gate:$direct"
wired="$(grep -cE '^[^#]*mutation-gate\.sh run [a-z-]+-mutation -- bash scripts/check-[a-z-]+\.sh --mutation' "$ROOT/.github/workflows/ci.yml" || true)"
[ "${wired:-0}" -gt 0 ] && ok || bad "ci.yml carries no gated mutation invocation at all (the scan matched nothing)"
printf 'check-mutation-gate: %s gated invocation(s) in ci.yml\n' "$wired"
# …and every gated line names a step the registry knows, with the registry's own command — the
# same refusal the gate makes at run time, asked here so a typo fails the PR rather than the job.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  s="$(printf '%s' "$line" | sed -E 's/.*mutation-gate\.sh run ([a-z-]+-mutation) -- (.*)$/\1/')"
  c="$(printf '%s' "$line" | sed -E 's/.*mutation-gate\.sh run ([a-z-]+-mutation) -- (.*)$/\2/')"
  regc="$(printf '%s\n' "$LIST" | awk -F'\t' -v s="$s" '$1 == s {print $2}')"
  eq "$regc" "$c" "ci.yml's gated line for $s runs the registry's own command"
done <<EOF
$(grep -E '^[^#]*mutation-gate\.sh run [a-z-]+-mutation -- ' "$ROOT/.github/workflows/ci.yml")
EOF

# The scheduled workflow runs EVERY *-mutation step unconditionally: its matrix is the registry's
# list, and the run sets the override. A step gated per-PR and absent here would be a harness that
# never runs anywhere until its inputs change — which is exactly "never" for a shared-helper
# regression the filter cannot see.
NIGHTLY="$ROOT/.github/workflows/mutation-nightly.yml"
[ -f "$NIGHTLY" ] && ok || bad "the scheduled workflow $NIGHTLY is missing"
if [ -f "$NIGHTLY" ]; then
  has "$(cat "$NIGHTLY")" "ADB_MUTATION_RUN_ALL: '1'" "the scheduled workflow forces every harness (ADB_MUTATION_RUN_ALL)"
  grep -qE '^[[:space:]]*schedule:' "$NIGHTLY" && ok || bad "the scheduled workflow has no schedule: trigger"
  grep -qE '^[[:space:]]*pull_request' "$NIGHTLY" && bad "the scheduled workflow must not carry a pull_request trigger (it would become a discoverable required context)" || ok
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qE "^[[:space:]]*- $s\$" "$NIGHTLY" && ok || bad "the scheduled workflow's matrix does not name $s"
  done <<EOF
$MUT_STEPS
EOF
  # …and nothing in the matrix that the registry does not know, or the schedule fails on a name
  # `--only` refuses.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s\n' "$MUT_STEPS" | grep -qx "$m" && ok || bad "the scheduled workflow's matrix names '$m', which is not a *-mutation step in the registry"
  done <<EOF
$(sed -n 's/^[[:space:]]*- \([a-z-]*-mutation\)$/\1/p' "$NIGHTLY")
EOF
fi

check_summary "check-mutation-gate"
