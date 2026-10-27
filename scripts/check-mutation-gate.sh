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
#      input does not match a sibling that merely shares its prefix; a path git would QUOTE and a
#      declared file RENAMED away both count as touched;
#   2. every SKIP names the base, the merge-base, the count compared and the inputs — a skip that
#      says nothing is the failure this gate exists to prevent;
#   3. fail-closed: not a repository, a base that does not resolve, no merge-base → RUN, with the
#      reason on the line; ADB_MUTATION_RUN_ALL → RUN, saying the override fired;
#   4. `run`: an unknown step, a step with no inputs, and a command that is not the registry's own
#      are each REFUSED (2) — never silently run and never silently skipped; a command that runs
#      passes its exit status through; a SKIP exits 0 and lands in GITHUB_STEP_SUMMARY when set;
#   4b. `rows` (#470): the same decision one axis finer. An untouched tree gates every row; a change
#      on one target runs exactly the rows that mutate it and gates the rest; a change to an input
#      NO row targets gates nothing. Every fail-closed shape — an unregistered suite, a row target
#      the step does not declare, no repository, an unresolvable base — runs the whole table and
#      says why, and empty stdin is usage rather than a decision. Every row gets a decision line on
#      every path, so a caller can never read a missing line as an answer;
#   5. the shipped registry: every `*-mutation` step declares inputs, and each declares its own
#      harness script, `scripts/check-lib.sh` and `scripts/lib/common.sh` — the two files every
#      harness sources — so a change to the shared scaffold can never be gated away; a step whose
#      suite runs `check_shmutant_pool` also declares the vendored `scripts/shmutant.sh` (#519);
#   6. the wiring (#456): `.github/workflows/ci.yml` carries no `--mutation` invocation, direct or
#      gated, and its macOS leg skips the registry's `*-mutation` set read at run time; the
#      scheduled workflow's matrix is read from the registry by its plan job, a dispatched `step`
#      is validated there, and its label trigger adds no required context (asked of discovery);
#   7. `steps` and `touched` (#456): the registry's harness list in every format and its refusals,
#      and the per-change answer of which harnesses to dispatch;
#   8. `scripts/mutation-nightly-status.sh` (#456): every shape of the last nightly's verdict is
#      stated, none gates, and nothing unvalidated reaches the Markdown summary.
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
  # Built ONCE per pool; shmutant clones it for every row, and `shmutant_target` names the file a
  # row mutates — the gate, ci.yml, the scheduled workflow or the last-nightly reporter, one pool
  # each (#519).
  mut_prepare() {
    check_copy_subtrees "$ROOT" "$1" scripts .github bin agents .claude base templates >/dev/null 2>&1 || return 1
    cp "$ROOT/install.sh" "$ROOT/uninstall.sh" "$1/" 2>/dev/null || return 1
  }
  mkdir -p "$work/gate" "$work/ci" "$work/nightly" "$work/status" "$work/registry"
  mut_run() {
    local d="$1"
    bash -n "$d/scripts/mutation-gate.sh" 2>/dev/null \
      || { printf 'the mutated mutation-gate.sh no longer PARSES\n'; return 9; }
    bash "$d/scripts/check-mutation-gate.sh" 2>&1
  }

  # THE CONTROL, first: an unmutated copy must pass, or every row below is red for the wrong reason.
  mut_ctl="$work/control"
  if mut_prepare "$mut_ctl"; then
    mut_out="$(mut_run "$mut_ctl" 2>&1)"; mut_rc=$?
    yes "$mut_rc" "control: an UNMUTATED copy passes (else every row below is red for the wrong reason)"
    has "$mut_out" "check-mutation-gate: PASS" "control: …and says PASS"
  else
    bad "control: could not build the tree copy"
  fi

  # shellcheck source=/dev/null
  . "$ROOT/scripts/shmutant.sh" || bad "check-mutation-gate: scripts/shmutant.sh could not be sourced"
  shmutant_target scripts/mutation-gate.sh
  # Four witnesses below begin with `…`, as their assertion labels do. shmutant matches a witness as a
  # whole TOKEN, and a non-ASCII neighbour extends one, so a witness starting at the letter after the
  # ellipsis is not carried by the label's FAIL: line (D125).
  shmutant_mut always-skip \
    'if [ "$nhits" -gt 0 ]; then' \
    'if [ "$nhits" -gt 999999 ]; then' \
    'a COMMITTED change to an input since the base: exit 0 (run)'
  # A literal is matched within ONE line, and shmutant refuses one that starts at more than one
  # position (its rewrite takes the first, which may not be the copy a row means). `gate_decide`'s
  # merge-base `return 11` is a whole line that recurs below it, and its override test is a prefix
  # of `rows`' own, so each of those two sites carries a `# row-*` marker the literal includes.
  shmutant_mut always-run \
    '  return 10' \
    '  return 0' \
    'untouched inputs: exit 10 (skip)'
  shmutant_mut unresolvable-base-skips \
    '    return 11   # row-mb-unresolved' \
    '    return 10   # row-mb-unresolved' \
    'a base that does not resolve: RUN on the fail-closed code (11), never skip'
  shmutant_mut override-ignored \
    'if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then   # row-step-override' \
    'if [ -n "${ADB_MUTATION_RUN_ALL_NEVER:-}" ]; then   # row-step-override' \
    'ADB_MUTATION_RUN_ALL=1: run, on its own distinct code (12)'
  shmutant_mut skip-line-unstated-base \
    '"$step" "$base" "${mb:0:12}" "$nchanged" "$inputs"' \
    '"$step" "(unstated)" "${mb:0:12}" "$nchanged" "$inputs"' \
    '…and names the base it compared against'
  shmutant_mut untracked-ignored \
    'for f in "${tracked[@]}" "${untracked[@]}"; do' \
    'for f in "${tracked[@]}"; do' \
    'an UNTRACKED file under a directory input: run'
  shmutant_mut run-accepts-foreign-command \
    '[ "$regcmd" = "$want" ] || {' \
    '[ "$regcmd" = "$regcmd" ] || {' \
    'a command that is not the registry'"'"'s own for that step is REFUSED'
  shmutant_mut run-swallows-harness-status \
    '    exec $regcmd ;;' \
    '    $regcmd; exit 0 ;;' \
    'passes its OWN exit status through (7)'

  shmutant_mut rename-collapsed \
    'diff --name-only -z --no-renames' \
    'diff --name-only -z' \
    'a RENAMED file input counts as touched'
  shmutant_mut quoted-path \
    'diff --name-only -z --no-renames' \
    'diff --name-only --no-renames' \
    'a tracked NON-ASCII file input, modified: run'
  shmutant_mut directory-boundary \
    '"$p"|"$p"/*) printf' \
    '"$p"|"$p"*) printf' \
    'a sibling that merely shares a FILE input'"'"'s prefix'

  # --- the PER-ROW decision (#470). Every one of these is a wrong SKIP or a lost fail-closed
  # answer — the direction that costs coverage rather than minutes — and each is anchored on a
  # `# row-*` marker so it names one site regardless of what is added above it.
  shmutant_mut rows-gate-everything \
    'then decisions+=(run); run=$((run + 1))   # row-match' \
    'then decisions+=(skip); run=$((run + 1))   # row-match' \
    '…the rows that mutate the changed file run'
  shmutant_mut rows-never-gate \
    'else decisions+=(skip); skip=$((skip + 1)); fi' \
    'else decisions+=(run); skip=$((skip + 1)); fi' \
    '…and a row mutating an untouched file is gated'
  shmutant_mut rows-shared-input-ignored \
    'if [ -n "$hits" ]; then   # row-shared' \
    'if false; then   # row-shared' \
    'names the shared input that forced it'
  shmutant_mut rows-undeclared-target-allowed \
    'if [ "$is_target" -eq 0 ]; then   # row-target-undeclared' \
    'if false; then   # row-target-undeclared' \
    'a row target outside the declared inputs fails closed'
  shmutant_mut rows-unregistered-suite-gated \
    'if ! inputs="$(gate_registry_inputs "$suite" suite 2>&1)"; then   # row-registry' \
    'if inputs="$(gate_registry_inputs "$suite" suite 2>&1)"; then   # row-registry' \
    '…naming the registry as the reason'
  shmutant_mut rows-override-ignored \
    'if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then   # row-override' \
    'if false; then   # row-override' \
    'ADB_MUTATION_RUN_ALL → exit 12'
  shmutant_mut rows-empty-stdin-decides \
    'if [ "$n" -eq 0 ]; then   # row-usage' \
    'if false; then   # row-usage' \
    'no rows on stdin is USAGE (2), never a decision'
  # --- `steps` and `touched` (#456): a wrong answer here is a dispatch typo that runs nothing, or a
  # change whose harnesses the close-out never dispatches.
  shmutant_mut steps-only-unvalidated \
    '      [ -n "$found" ] || {' \
    '      [ -n "$found" ] || [ -n "$only" ] || {' \
    'steps --only <unknown>: refused (2)'
  shmutant_mut touched-failclosed-lists-none \
    '        11|12) printf '"'"'%s\n'"'"' "$step"; [ "$rc" -gt "$worst" ] && worst="$rc" ;;' \
    '        11|12) [ "$rc" -gt "$worst" ] && worst="$rc" ;;' \
    '…and lists EVERY harness, never none'
  shmutant_mut steps-narrow-name-grammar \
    "awk -F'\\t' '\$1 ~ /^[A-Za-z0-9_-]*-mutation\$/'" \
    "awk -F'\\t' '\$1 ~ /^[a-z0-9-]+-mutation\$/'" \
    'is listed, not dropped'
  # --- `steps --matrix --shards` (#532): a wrong answer here is a row no job scores, or two jobs
  # scoring one row while another goes unscored.
  shmutant_mut matrix-last-shard-dropped \
    'for (( k = 1; k <= of; k++ )); do' \
    'for (( k = 1; k < of; k++ )); do' \
    'carries every shard 1..K'
  shmutant_mut shards-unknown-step-accepted \
    '        if [ -z "$found" ]; then' \
    '        if false; then' \
    "steps --matrix --shards 'no-such-mutation=2': refused (2)"
  shmutant_mut shards-step-named-twice \
    '[ -z "${shard_of[$sname]:-}" ] || {' \
    'true || {' \
    'a step named twice is named'
  shmutant_mut shards-count-unbounded \
    'if [ "$scount" -lt 1 ] || [ "$scount" -gt "$MATRIX_MAX" ]; then' \
    'if false; then' \
    'a count out of range is named'
  shmutant_mut shards-list-split-unread \
    '*[!A-Za-z0-9_=,-]*|,*|*,|*,,*)' \
    '__never__)' \
    'not one comma-separated line is named'
  shmutant_mut matrix-limit-unchecked \
    'if [ "$total" -gt "$MATRIX_MAX" ]; then' \
    'if false; then' \
    'a matrix of 257 jobs is refused (2)'
  shmutant_mut shards-outside-matrix \
    '[ -z "$shards_set" ] || [ "$fmt" = matrix ] || usage' \
    ': || usage' \
    'shard counts mean nothing outside --matrix'
  shmutant_mut steps-filter-status-dropped \
    '|| { printf '"'"'the registry filter failed — refusing a list it may have cut short\n'"'"' >&2; return 1; }   # row-filter' \
    '|| true   # row-filter' \
    'a registry filter that fails part-way'
  shmutant_mut steps-empty-only-widens \
    '--only) [ "$#" -ge 2 ] && [ -n "$2" ] || usage;' \
    '--only) [ "$#" -ge 2 ] || usage;' \
    'never widened to every harness'
  check_shmutant_pool "check-mutation-gate (gate)" "$work/gate" mut_prepare mut_run 4

  # THE WIRING PINS are observed failing too, against mutated copies of the two workflow files —
  # the same suite, a different target per pool. A pin that cannot go red on the exact edit it
  # exists to refuse is the silent guard `self-review.md` warns about.
  shmutant_reset
  shmutant_target .github/workflows/ci.yml
  # A harness back on the per-PR path, in each of the three spellings the pins refuse.
  shmutant_mut ci-gated-harness-restored \
    '        run: bash scripts/mutation-nightly-status.sh' \
    '        run: bash scripts/mutation-gate.sh run common-lib-mutation -- bash scripts/check-common-lib.sh --mutation' \
    'runs a mutation harness through the per-PR gate'
  shmutant_mut ci-direct-harness-restored \
    '        run: bash scripts/mutation-nightly-status.sh' \
    '        run: bash scripts/check-common-lib.sh --mutation' \
    'invokes a mutation harness directly'
  shmutant_mut ci-macos-hand-listed-skip \
    '          bash scripts/selfcheck.sh --skip "$skip" 2>&1 | tee "$RUNNER_TEMP/selfcheck.log"' \
    '          bash scripts/selfcheck.sh --skip adopt-mutation 2>&1 | tee "$RUNNER_TEMP/selfcheck.log"' \
    'without skipping the registry'
  shmutant_mut ci-macos-skip-overwritten \
    'echo "skipping the mutation harnesses (they run in mutation-nightly.yml): $skip"' \
    'read -r skip <<< "adopt-mutation"' \
    'HANDS selfcheck exactly'
  shmutant_mut ci-status-condition-moved \
    "        if: \${{ !cancelled() && steps.checkout.outcome == 'success' }}" \
    '        # condition removed' \
    'does not run past an earlier red step'
  shmutant_mut ci-checkout-id-dropped \
    '        id: checkout' \
    '        # id removed' \
    "carries no 'id: checkout'"
  shmutant_mut ci-status-permission-dropped \
    '      actions: read' \
    '      actions: none' \
    "does not grant 'actions: read'"
  shmutant_mut ci-selfcheck-only-harness \
    '        run: bash scripts/mutation-nightly-status.sh' \
    '        run: bash scripts/selfcheck.sh --only fact-mutation' \
    'through selfcheck --only'
  shmutant_mut ci-status-line-unwired \
    '        run: bash scripts/mutation-nightly-status.sh' \
    '        run: "true"' \
    'no longer runs scripts/mutation-nightly-status.sh'
  shmutant_mut ci-macos-skip-unread \
    'skip="$(bash scripts/mutation-gate.sh steps --csv)" ||' \
    'skip="adopt-mutation" ||' \
    'does not build its --skip'
  check_shmutant_pool "check-mutation-gate (ci.yml)" "$work/ci" mut_prepare mut_run 4

  shmutant_reset
  shmutant_target .github/workflows/mutation-nightly.yml
  shmutant_mut nightly-static-matrix \
    'matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}' \
    'matrix: { step: [fact-mutation] }' \
    'matrix is not read from the plan job'
  shmutant_mut nightly-plan-output-constant \
    '      matrix: ${{ steps.plan.outputs.matrix }}' \
    '      matrix: '"'"'{"include":[]}'"'"'' \
    'does not export its'
  shmutant_mut nightly-plan-not-published \
    'printf '"'"'matrix=%s\n'"'"' "$matrix" >> "$GITHUB_OUTPUT"' \
    'printf '"'"'matrix=%s\n'"'"' "$matrix" >> /dev/null' \
    'does not publish the list'
  shmutant_mut nightly-plan-overwritten \
    'matrix="$(bash scripts/mutation-gate.sh steps --matrix --shards "$SHARDS")" || exit 1' \
    "matrix='{\"include\":[{\"step\":\"fact-mutation\",\"shard\":1,\"shards\":1}]}'" \
    'PUBLISHES exactly'
  shmutant_mut nightly-shards-dropped \
    "SHARDS: 'settings-fragment-mutation=3'" \
    "SHARDS: 'fact-mutation=1'" \
    'splits settings-fragment-mutation into more than one shard'
  shmutant_mut nightly-shard-unwired \
    'ADB_MUTATION_SHARD: ${{ matrix.shard }}/${{ matrix.shards }}' \
    'ADB_MUTATION_SHARD: 1/1' \
    "hand its job's shard to the harness"
  shmutant_mut nightly-artifact-collides \
    'name: mutation-artifacts-${{ matrix.step }}-shard-${{ matrix.shard }}-of-${{ matrix.shards }}' \
    'name: mutation-artifacts-${{ matrix.step }}' \
    'artifact name does not carry the shard'
  shmutant_mut nightly-plan-merge-commit \
    "ref: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || '' }}   # row-plan-ref" \
    "ref: ''   # row-plan-ref" \
    "labelled PR's HEAD commit"
  shmutant_mut nightly-harness-merge-commit \
    "ref: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || '' }}   # row-harness-ref" \
    "ref: ''   # row-harness-ref" \
    "labelled PR's HEAD commit"
  shmutant_mut nightly-plan-not-needed \
    '    needs: plan' \
    '    needs: []' \
    'does not need the plan job'
  shmutant_mut nightly-dispatch-input-dropped \
    "ONLY: \${{ github.event_name == 'workflow_dispatch' && inputs.step || '' }}" \
    "ONLY: ''" \
    'does not bind ONLY'
  shmutant_mut nightly-runner-constant-step \
    'bash scripts/selfcheck.sh --only "${{ matrix.step }}"' \
    'bash scripts/selfcheck.sh --only "fact-mutation"' \
    'does not run its own'
  shmutant_mut nightly-dispatch-unvalidated \
    'matrix="$(bash scripts/mutation-gate.sh steps --matrix --shards "$SHARDS" --only "$ONLY")" || exit 1' \
    'matrix="{\"include\":[{\"step\":\"$ONLY\",\"shard\":1,\"shards\":1}]}"' \
    'does not validate a dispatched step'
  shmutant_mut nightly-label-widened \
    '    types: [labeled]' \
    '    types: [labeled, opened, synchronize]' \
    'narrowed to'
  shmutant_mut nightly-pull-request-target \
    '  pull_request:' \
    '  pull_request_target:' \
    'must not use pull_request_target'
  shmutant_mut nightly-any-label \
    "github.event.label.name == 'run-mutations')" \
    "github.event.label.name != '')" \
    'only for the run-mutations label'
  shmutant_mut nightly-override-off \
    "ADB_MUTATION_RUN_ALL: '1'" \
    "ADB_MUTATION_RUN_ALL: '0'" \
    'forces every harness'
  shmutant_mut nightly-per-block \
    "ADB_MUTATION_FULL_SUITE: '1'" \
    "ADB_MUTATION_FULL_SUITE: '0'" \
    'runs every mutant against the full suite'
  # Two leading spaces: the header comment mentions `schedule:` too, and only the trigger line is
  # indented exactly so.
  shmutant_mut nightly-unscheduled \
    '  schedule:' \
    '  schedul3:' \
    'has no schedule'
  check_shmutant_pool "check-mutation-gate (nightly)" "$work/nightly" mut_prepare mut_run 4

  # THE LAST-NIGHTLY LINE (#456): each rule whose failure is a misleading line on every PR.
  shmutant_reset
  shmutant_target scripts/mutation-nightly-status.sh
  shmutant_mut status-any-event \
    '--branch "$branch" --event schedule --limit 1' \
    '--branch "$branch" --limit 1' \
    'SCHEDULED runs only'
  shmutant_mut status-never-stale \
    '[ "$age" -le "$STALE_SECS" ] || stale=' \
    '[ "$age" -le 999999999 ] || stale=' \
    'one second past 48h is STALE'
  shmutant_mut status-gh-failure-as-absence \
    'unreadable (gh run list failed' \
    'no nightly result found (gh run list failed' \
    'as unreadable, distinct from absence'
  shmutant_mut status-parse-status-dropped \
    '|| emit "last nightly on $branch_md: unreadable (gh returned a document that does not parse)"' \
    '|| :' \
    'parses part-way is unreadable'
  shmutant_mut status-url-unvalidated \
    '[[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$ ]]' \
    '[[ "$url" =~ ^https:// ]]' \
    'a URL carrying Markdown is refused'
  check_shmutant_pool "check-mutation-gate (nightly-status)" "$work/status" mut_prepare mut_run 4

  # SECTION 5's shmutant pin, against a copy of the registry: a ported step that stops declaring the
  # vendored harness it runs would be gated off a change to it, which only this pin reports.
  shmutant_reset
  shmutant_target scripts/selfcheck.sh
  shmutant_mut registry-drops-shmutant \
    'inputs adopt-mutation           scripts/check-adopt.sh scripts/check-lib.sh scripts/shmutant.sh ' \
    'inputs adopt-mutation           scripts/check-adopt.sh scripts/check-lib.sh ' \
    'adopt-mutation runs check_shmutant_pool, so its verdict depends on scripts/shmutant.sh'
  check_shmutant_pool "check-mutation-gate (registry)" "$work/registry" mut_prepare mut_run 4
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

# A path git would QUOTE. With core.quotePath at its default, `git diff --name-only` prints a
# non-ASCII name as "scripts/lib/caf\303\251.sh" — a string that equals no declared input and lies
# under no declared directory as far as a byte comparison can tell. Reported by the declared
# reviewer with exactly this probe; both reads are NUL-delimited now.
printf 'q\n' > "$R/scripts/lib/café.sh"
gate "$R" should-run stub-mutation -- scripts/check-stub.sh scripts/lib
eq "$RC_" "0" "an UNTRACKED non-ASCII path under a directory input: run (git quoting must not hide it)"
has "$OUT" "scripts/lib/café.sh" "…naming the file as itself, unquoted"
check_git "$R" add -A >/dev/null 2>&1 && check_git "$R" commit -q -m "add café" >/dev/null 2>&1
check_git "$R" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
printf 'changed\n' >> "$R/scripts/lib/café.sh"
gate "$R" should-run stub-mutation -- scripts/lib/café.sh
eq "$RC_" "0" "a tracked NON-ASCII file input, modified: run"
has "$OUT" "1 changed file(s) touch its inputs: scripts/lib/café.sh" "…and the line names it"
check_git "$R" checkout -q -- scripts/lib/café.sh

# A RENAMED file input. Git's default rename detection folds `stub.sh -> renamed.sh` into one
# record naming only the destination, so the declared path `scripts/lib/stub.sh` would not appear
# in the diff at all — a declared file's removal must count as touching it. Same reviewer probe.
check_git "$R" mv scripts/lib/stub.sh scripts/lib/renamed.sh >/dev/null 2>&1
gate "$R" should-run stub-mutation -- "${INPUTS[@]}"
eq "$RC_" "0" "a RENAMED file input counts as touched: run (rename detection must not fold it away)"
has "$OUT" "scripts/lib/stub.sh" "…naming the declared path that went away"
check_git "$R" reset -q --hard HEAD >/dev/null 2>&1

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

# The fixture's history moved (the café commit above advanced origin/main), so the merge-base is
# re-read here rather than carried from the first section.
mb="$(git -C "$R" rev-parse origin/main)"
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
# A ROW HARNESS too (#470): its rows mutate stub.sh and other.sh, so `check-rows.sh`,
# `check-lib.sh` and `common.sh` are the inputs no row targets — the shared set.
printf '#!/usr/bin/env bash\necho rows-ran\n' > "$R/scripts/check-rows.sh"
{ printf '\n'
  printf 'add gated-mutation      bash scripts/check-gated.sh --mutation\n'
  printf 'inputs gated-mutation   scripts/check-gated.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/stub.sh\n'
  printf 'add rows-mutation       bash scripts/check-rows.sh --mutation\n'
  printf 'inputs rows-mutation    scripts/check-rows.sh scripts/check-lib.sh scripts/lib/common.sh scripts/lib/stub.sh scripts/lib/other.sh\n'
  printf 'add bare                bash scripts/check-bare.sh\n'
  # A name the registry's grammar allows and a lowercase-only reader would drop (#456 review).
  printf 'add New_guard-mutation  bash scripts/check-bare.sh --mutation\n'
  printf 'inputs New_guard-mutation scripts/check-bare.sh scripts/check-lib.sh scripts/lib/common.sh\n'
  # …and the shortest name it allows, a bare `-mutation`, which a `+` in the reader's regex dropped.
  printf 'add -mutation           bash scripts/check-bare.sh --mutation-bare\n'
  printf 'inputs -mutation        scripts/check-bare.sh scripts/check-lib.sh scripts/lib/common.sh\n'; } > "$work/reg.frag"
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

# ============================== 4b. `rows` — the per-row decision (#470) ========================
# One axis finer than `should-run`, and the same failure mode: a row wrongly gated is invisible,
# because the step is green, the harness is green, and the mutant that would have gone red never
# ran. So every path is driven to its answer, and every fail-closed shape is required to RUN.
#
# The fixture's row table mutates `scripts/lib/stub.sh` and `scripts/lib/other.sh`; the step also
# declares `check-rows.sh`, `check-lib.sh` and `common.sh`, which NO row targets — that is the
# shared set a change to which can gate nothing.
ROWS_IN="$(printf 'r0\tscripts/lib/stub.sh\nr1\tscripts/lib/other.sh\nr2\tscripts/lib/stub.sh\n')"
rowsgate() {   # <repo> [ENV=v…] — feed the row table to the COPIED gate; sets OUT/RC_
  local d="$1"; shift
  OUT="$(cd "$d" && printf '%s\n' "$ROWS_IN" | env "$@" bash scripts/mutation-gate.sh rows scripts/check-rows.sh 2>&1)"; RC_=$?
}
dec() { printf '%s\n' "$OUT" | awk -F'\t' -v r="$1" '$1 == r { print $2; exit }'; }

rowsgate "$R"
eq "$RC_" "0" "rows: an untouched tree decides, and says so"
has "$OUT" "GATED: scripts/check-rows.sh — 0 of 3 row(s) run, 3 gated against origin/main" "…naming how many ran and how many were gated"
has "$OUT" "shared inputs: scripts/check-rows.sh, scripts/check-lib.sh, scripts/lib/common.sh" \
  "…and naming the inputs no row targets, which is what makes a gate possible at all"
has "$OUT" "changed file(s) compared" "…and saying what it compared"
eq "$(dec r0)" "skip" "…row r0 is gated"
eq "$(dec r1)" "skip" "…row r1 is gated"
eq "$(dec r2)" "skip" "…row r2 is gated"

# A change on ONE target runs exactly the rows that mutate it. This is #470's whole acceptance.
printf 'dirty\n' >> "$R/scripts/lib/stub.sh"
rowsgate "$R"
eq "$RC_" "0" "rows: a change on one target decides"
has "$OUT" "2 of 3 row(s) run, 1 gated" "…and the tally names both halves"
eq "$(dec r0)" "run"  "…the rows that mutate the changed file run"
eq "$(dec r2)" "run"  "…all of them, not just the first"
eq "$(dec r1)" "skip" "…and a row mutating an untouched file is gated"
check_git "$R" checkout -q -- scripts/lib/stub.sh

# An UNTRACKED file on a target path counts as touching it, exactly as the step-level gate reads it.
printf 'new\n' > "$R/scripts/lib/other.sh.new"
rowsgate "$R"
eq "$(dec r1)" "skip" "rows: an untracked SIBLING of a target does not touch it"
rm -f "$R/scripts/lib/other.sh.new"

# A shared input changed — nothing can be gated, and the line says which file decided it.
printf 'dirty\n' >> "$R/scripts/check-lib.sh"
rowsgate "$R"
eq "$RC_" "0" "rows: a shared-input change decides"
has "$OUT" "RUN-ALL: scripts/check-rows.sh — no row can be gated; the change touches 1 shared input(s) of every row: scripts/check-lib.sh" \
  "…and names the shared input that forced it, and how many there were"
eq "$(dec r0)$(dec r1)$(dec r2)" "runrunrun" "…and every row runs"
check_git "$R" checkout -q -- scripts/check-lib.sh

# The override.
rowsgate "$R" ADB_MUTATION_RUN_ALL=1
eq "$RC_" "12" "rows: ADB_MUTATION_RUN_ALL → exit 12"
has "$OUT" "RUN-ALL: scripts/check-rows.sh — ADB_MUTATION_RUN_ALL is set" "…saying the override fired"
eq "$(dec r0)$(dec r1)$(dec r2)" "runrunrun" "…and every row runs"

# FAIL CLOSED. Each of these must RUN the whole table and say why — the cost of a wrong gate is
# minutes of CI, and the cost of a wrong SKIP is a defect that ships.
OUT="$(cd "$R" && printf '%s\n' "$ROWS_IN" | bash scripts/mutation-gate.sh rows scripts/check-nope.sh 2>&1)"; RC_=$?
eq "$RC_" "11" "rows: an UNREGISTERED suite fails closed"
has "$OUT" "not a registered selfcheck step" "…naming the registry as the reason"
eq "$(dec r0)$(dec r1)$(dec r2)" "runrunrun" "…and every row runs"

# A row whose target the step does not declare: the declaration is narrower than the harness
# (`declared-inputs-incomplete`), so gating is refused for the WHOLE step, not just that row.
OUT="$(cd "$R" && printf 'r0\tscripts/lib/stub.sh\nr1\tREADME.md\n' | bash scripts/mutation-gate.sh rows scripts/check-rows.sh 2>&1)"; RC_=$?
eq "$RC_" "11" "rows: a row target outside the declared inputs fails closed"
has "$OUT" "a row mutates 'README.md', which the step does not declare as an input" "…naming the undeclared target"
eq "$(dec r0)$(dec r1)" "runrun" "…and EVERY row runs, not merely the undeclared one"

# A tree with the registry but NO git: the registry lookup must succeed so that the *repository*
# is what this case actually tests — a copy without one fails closed a step earlier, for a
# different reason, and would pass this assertion while proving nothing about git.
NR="$work/rows-norepo"; mkdir -p "$NR/scripts/lib"
cp "$R/scripts/mutation-gate.sh" "$R/scripts/selfcheck.sh" "$R/scripts/check-rows.sh" "$NR/scripts/"
cp "$R/scripts/lib/common.sh" "$NR/scripts/lib/"
OUT="$(cd "$NR" && printf '%s\n' "$ROWS_IN" | bash scripts/mutation-gate.sh rows scripts/check-rows.sh 2>&1)"; RC_=$?
eq "$RC_" "11" "rows: outside a repository fails closed"
has "$OUT" "not a git repository" "…naming the reason, not some earlier refusal"
eq "$(dec r0)$(dec r1)$(dec r2)" "runrunrun" "…and every row runs"

OUT="$(cd "$R" && printf '%s\n' "$ROWS_IN" | bash scripts/mutation-gate.sh rows scripts/check-rows.sh --base no/such/ref 2>&1)"; RC_=$?
eq "$RC_" "11" "rows: a base that does not resolve fails closed"
has "$OUT" "does not resolve to a commit" "…naming the unresolvable base"
eq "$(dec r0)$(dec r1)$(dec r2)" "runrunrun" "…and every row runs"

OUT="$(cd "$R" && printf '' | bash scripts/mutation-gate.sh rows scripts/check-rows.sh 2>&1)"; RC_=$?
eq "$RC_" "2" "rows: no rows on stdin is USAGE (2), never a decision"

OUT="$(cd "$R" && printf '%s\n' "$ROWS_IN" | bash scripts/mutation-gate.sh rows 2>&1)"; RC_=$?
eq "$RC_" "2" "rows: a missing suite argument is usage"

# EVERY DISPATCH ARM IS IN THE USAGE TEXT. `rows` was not: an invocation with no suite, or with a
# bad option, called `usage` — and the text it printed listed only the three older subcommands, so
# the one message whose whole job is to show the correct syntax omitted the syntax being corrected.
# Derived from the `case` arms rather than from a list here, so a fifth subcommand is covered the
# day it is added.
USAGE_TEXT="$(cd "$ROOT" && bash scripts/mutation-gate.sh 2>&1)"
ARMS="$(awk '/^case "\$sub" in/,/^esac/' "$ROOT/scripts/mutation-gate.sh" | grep -oE '^  [a-z-]+\)' | tr -d ' )')"
[ -n "$ARMS" ] && ok || bad "the dispatch-arm scan matched nothing — this pin would check no subcommand at all"
n_arms=0
while IFS= read -r _arm; do
  [ -n "$_arm" ] || continue
  n_arms=$((n_arms + 1))
  case "$USAGE_TEXT" in
    *"mutation-gate.sh $_arm"*) ok ;;
    *) bad "the '$_arm' subcommand is missing from the usage text — an invalid invocation of it prints help that omits the syntax needed to fix it" ;;
  esac
done <<ARMSEOF
$ARMS
ARMSEOF
[ "$n_arms" -ge 4 ] && ok || bad "only $n_arms dispatch arm(s) were checked against the usage text — the scan is reading the wrong block"

# ============================== 7. `steps` and `touched` (#456) ==================================
# `steps` is the ONE list both workflows read; `touched` is the close-out's question "which harnesses
# does this change give something new to say?". Asked of the registry fixture built in section 4.
gate "$R" steps
eq "$RC_" "0" "steps: reads the registry"
has "$OUT" "gated-mutation" "steps: …lists a registered *-mutation step"
hasnt "$OUT" "bare" "steps: …and never a step that is not a *-mutation step"
gate "$R" steps --json --only gated-mutation
eq "$OUT" '["gated-mutation"]' "steps --json --only <step>: exactly that one, as a JSON array"
gate "$R" steps
has "$OUT" "New_guard-mutation" "steps: a harness name with an underscore and a capital — the registry's grammar — is listed, not dropped"
printf '%s\n' "$OUT" | grep -qx -- '-mutation' && ok || bad "steps: the bare name '-mutation' the registry allows is listed, not dropped"
gate "$R" steps --only no-such-mutation
eq "$RC_" "2" "steps --only <unknown>: refused (2), so a dispatch typo fails before any job starts"
has "$OUT" "is not a registered *-mutation step" "…and says why"
gate "$R" steps --only bare
eq "$RC_" "2" "steps --only <a step that is not a harness>: refused too"
gate "$R" steps --csv
case "$OUT" in *gated-mutation*rows-mutation*|*rows-mutation*gated-mutation*) ok ;; *) bad "steps --csv: want both fixture harnesses comma-joined, got: $OUT" ;; esac
[[ "$OUT" =~ ^[A-Za-z0-9_,-]+$ ]] && ok || bad "steps --csv: one line, names and commas only — got: $OUT"
gate "$R" steps --bogus
eq "$RC_" "2" "steps --bogus: usage"
gate "$R" steps --json --only ''
eq "$RC_" "2" "steps --only '': usage, never widened to every harness"
# --matrix (#532): one entry per (step, shard), and a step's shards are exactly 1..K, so its jobs
# partition its rows. Asked of the parsed JSON, not of its spelling.
gate "$R" steps --matrix --only gated-mutation
eq "$OUT" '{"include":[{"step":"gated-mutation","shard":1,"shards":1}]}' "steps --matrix: an unsharded step is one shard of one"
gate "$R" steps --matrix --only gated-mutation --shards gated-mutation=3
eq "$(printf '%s' "$OUT" | jq -c '[.include[] | [.step, .shard, .shards]]')" '[["gated-mutation",1,3],["gated-mutation",2,3],["gated-mutation",3,3]]' \
   "steps --matrix --shards: a one-step dispatch of a sharded step carries every shard 1..K"
gate "$R" steps --matrix --only rows-mutation --shards gated-mutation=3
eq "$OUT" '{"include":[{"step":"rows-mutation","shard":1,"shards":1}]}' "steps --matrix: another step's shard entry does not leak into this one"
gate "$R" steps --matrix --shards gated-mutation=2,rows-mutation=5
eq "$RC_" "0" "steps --matrix --shards: two entries are read"
eq "$(printf '%s' "$OUT" | jq -r '[.include[].step] | unique | .[]' | LC_ALL=C sort | tr '\n' ' ')" \
   "$(cd "$R" && bash scripts/mutation-gate.sh steps --lines | LC_ALL=C sort | tr '\n' ' ')" \
   "steps --matrix: every registered harness is in the matrix, sharded or not"
eq "$(printf '%s' "$OUT" | jq -c '[.include | group_by(.step)[] | select(([.[].shard] | sort) != [range(1; (.[0].shards) + 1)] or ([.[].shards] | unique | length) != 1)] | length')" "0" \
   "steps --matrix: every step's shards are exactly 1..K with one K — each row has exactly one job"
eq "$(printf '%s' "$OUT" | jq -c '[.include[] | select(.step == "gated-mutation" or .step == "rows-mutation") | .shards] | unique')" '[2,5]' \
   "steps --matrix --shards: each step takes its own count"
for _bad in no-such-mutation=2 bare=2 gated-mutation=0 gated-mutation=257 gated-mutation=03 gated-mutation=x gated-mutation= gated-mutation =2 \
            gated-mutation=2,gated-mutation=3 gated-mutation=2,,rows-mutation=2 'gated-mutation=2,' ',gated-mutation=2' \
            $'\ngated-mutation=2' $'gated-mutation=2\nno-such-mutation=2'; do
  gate "$R" steps --matrix --shards "$_bad"
  eq "$RC_" "2" "steps --matrix --shards '$_bad': refused (2)"
  eq "$(printf '%s' "$OUT" | grep -c '"include"')" "0" "steps --matrix --shards '$_bad': …and no matrix is printed"
done
gate "$R" steps --matrix --shards gated-mutation=2,gated-mutation=3
has "$OUT" "given a shard count twice" "steps --matrix --shards: a step named twice is named"
gate "$R" steps --matrix --shards gated-mutation=257
has "$OUT" "must be an integer from 1 to 256" "steps --matrix --shards: a count out of range is named"
# THE WHOLE ARGUMENT is read: an entry after a newline or a stray comma is refused, never dropped.
gate "$R" steps --matrix --shards $'gated-mutation=2\nno-such-mutation=2'
has "$OUT" "no empty entry" "steps --matrix --shards: a list that is not one comma-separated line is named"
# GitHub runs at most 256 jobs from one matrix: the fixture's other harnesses take one job each, so
# gated-mutation at 256 minus their count fits exactly, and one more job is refused.
_others=$(( $(cd "$R" && bash scripts/mutation-gate.sh steps --lines | wc -l) - 1 ))
gate "$R" steps --matrix --shards "gated-mutation=$(( 256 - _others ))"
eq "$RC_" "0" "steps --matrix: a matrix of exactly 256 jobs is accepted"
eq "$(printf '%s' "$OUT" | jq '.include | length')" "256" "…and carries 256 entries"
gate "$R" steps --matrix --shards "gated-mutation=$(( 257 - _others ))"
eq "$RC_" "2" "steps --matrix: a matrix of 257 jobs is refused (2)"
has "$OUT" "GitHub runs at most 256" "…and says why"
gate "$R" steps --matrix --only gated-mutation --shards gated-mutation=256
eq "$RC_" "0" "steps --matrix: the limit is counted on the matrix as emitted, after --only"
gate "$R" steps --matrix --only rows-mutation --shards no-such-mutation=2
eq "$RC_" "2" "steps --matrix --shards: a typo is refused even when --only selects another step"
gate "$R" steps --json --shards gated-mutation=2
eq "$RC_" "2" "steps --json --shards: usage — shard counts mean nothing outside --matrix"
gate "$R" steps --matrix --shards ''
eq "$RC_" "2" "steps --matrix --shards '': usage"
# A registry that cannot be read is exit 3, never an empty list — a matrix of nothing is green.
NR="$work/noreg"; mkrepo "$NR" || bad "fixture setup: could not build the registry-less repository"
gate "$NR" steps --json
eq "$RC_" "3" "steps: an unreadable registry → exit 3, never an empty list"
gate "$NR" touched
eq "$RC_" "3" "touched: an unreadable registry → exit 3"
# A registry FILTER that fails part-way is exit 3 too, never the rows it managed to print: an awk
# that emits its output and then fails stands in for it (#456 review).
awkfail="$work/awkfail"; mkdir -p "$awkfail"; realawk="$(command -v awk)"
printf '#!/usr/bin/env bash\ncase "$*" in *"-mutation\$/"*) %q "$@"; exit 2 ;; esac\nexec %q "$@"\n' "$realawk" "$realawk" > "$awkfail/awk"
chmod +x "$awkfail/awk"
OUT="$(cd "$R" && PATH="$awkfail:$PATH" bash scripts/mutation-gate.sh steps --json 2>&1)"; RC_=$?
eq "$RC_" "3" "steps: a registry filter that fails part-way → exit 3, never the partial list"
has "$OUT" "refusing a list it may have cut short" "steps: …and says why"

# touched: clean against the base → nothing listed, every decision line on stderr.
T_OUT="$(cd "$R" && bash scripts/mutation-gate.sh touched 2>/dev/null)"; T_RC=$?
eq "$T_RC" "0" "touched: a clean change → exit 0 (decided)"
eq "$T_OUT" "" "touched: …and lists no harness"
T_ERR="$(cd "$R" && bash scripts/mutation-gate.sh touched 2>&1 >/dev/null)"
has "$T_ERR" "SKIP: gated-mutation" "touched: …stating each step's decision on stderr"
# A change on one input lists exactly the harnesses that declare it.
printf 'dirty\n' >> "$R/scripts/check-gated.sh"
T_OUT="$(cd "$R" && bash scripts/mutation-gate.sh touched 2>/dev/null)"; T_RC=$?
eq "$T_RC" "0" "touched: a change on one harness's input → exit 0"
eq "$T_OUT" "gated-mutation" "touched: …lists exactly that harness"
check_git "$R" checkout -q -- scripts/check-gated.sh
# Fail-closed and override: every harness listed, each on its own code.
T_OUT="$(cd "$R" && bash scripts/mutation-gate.sh touched --base no-such-ref 2>/dev/null)"; T_RC=$?
eq "$T_RC" "11" "touched: an unresolvable base → exit 11 (fail-closed)"
eq "$(printf '%s\n' "$T_OUT" | LC_ALL=C sort | tr '\n' ' ')" "$(cd "$R" && bash scripts/mutation-gate.sh steps | LC_ALL=C sort | tr '\n' ' ')" \
   "touched: …and lists EVERY harness, never none"
T_OUT="$(cd "$R" && ADB_MUTATION_RUN_ALL=1 bash scripts/mutation-gate.sh touched 2>/dev/null)"; T_RC=$?
eq "$T_RC" "12" "touched: ADB_MUTATION_RUN_ALL → exit 12"
eq "$(printf '%s\n' "$T_OUT" | grep -c .)" "$(cd "$R" && bash scripts/mutation-gate.sh steps | grep -c .)" "touched: …listing every harness"

# ============================== 8. mutation-nightly-status.sh (#456) =============================
# Driven through a stub `gh` on PATH; the clock is pinned with ADB_NIGHTLY_NOW. The script runs from
# the shipped tree (it reads nothing there but the default branch).
NS="$ROOT/scripts/mutation-nightly-status.sh"
ghs="$work/ghstub"; mkdir -p "$ghs"
cat > "$ghs/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${GH_STUB_ARGS:?}"
[ "${GH_STUB_RC:-0}" -eq 0 ] || { echo "gh: HTTP 401" >&2; exit "$GH_STUB_RC"; }
printf '%s\n' "${GH_STUB_JSON:-[]}"
STUB
chmod +x "$ghs/gh"
T0=1760000000   # 2025-10-09T08:53:20Z
created="$(jq -rn --argjson t "$T0" '$t | todateiso8601')"
URL="https://github.com/BWBama85/ai-dev-baseline/actions/runs/123456"
rec() { jq -cn --arg u "$1" --arg s "$2" --arg c "$3" --arg t "$created" --arg h "$4" \
          '[{url:$u, status:$s, conclusion:$c, createdAt:$t, headSha:$h}]'; }
ns() {  # ns <now-offset-secs> <json> [gh-rc] → NOUT/NRC; summary to $work/ns-summary
  : > "$work/ns-summary"
  NOUT="$(GH_STUB_ARGS="$work/ns-args" GH_STUB_JSON="$2" GH_STUB_RC="${3:-0}" ADB_NIGHTLY_NOW=$(( T0 + $1 )) \
          GITHUB_STEP_SUMMARY="$work/ns-summary" PATH="$ghs:$PATH" bash "$NS" 2>&1)"; NRC=$?
}
SHA=0123456789abcdef0123456789abcdef01234567
ns $(( 5 * 3600 )) "$(rec "$URL" completed success "$SHA")"
eq "$NRC" "0" "nightly-status: a green nightly → exit 0"
eq "$NOUT" "mutation harnesses: not run per-PR (nightly + on demand); last nightly on main: $URL success 5h ago at 0123456789ab" \
   "nightly-status: the line names the URL, conclusion, age and commit"
eq "$(cat "$work/ns-summary")" "- $NOUT" "nightly-status: …and the same line lands in the job summary"
has "$(cat "$work/ns-args")" "--workflow mutation-nightly.yml" "nightly-status: asks for the nightly workflow"
has "$(cat "$work/ns-args")" "--event schedule" "nightly-status: …its SCHEDULED runs only, never a dispatch or a label run"
has "$(cat "$work/ns-args")" "--branch main" "nightly-status: …on the default branch"
ns 172800 "$(rec "$URL" completed failure "$SHA")"
eq "$NRC" "0" "nightly-status: a RED nightly still exits 0 (it reports, it does not gate)"
has "$NOUT" "$URL failure 48h ago" "nightly-status: …and says failure"
hasnt "$NOUT" "STALE" "nightly-status: exactly 48h is not stale"
ns 172801 "$(rec "$URL" completed success "$SHA")"
has "$NOUT" "STALE (older than 48h" "nightly-status: one second past 48h is STALE"
ns 600 "$(rec "$URL" in_progress "" "$SHA")"
has "$NOUT" "in_progress (not finished) 10m ago" "nightly-status: an unfinished run is named as such, never as a verdict"
ns 0 '[]'
eq "$NRC" "0" "nightly-status: no scheduled run → exit 0"
has "$NOUT" "last nightly on main: no nightly result found" "nightly-status: …and says so"
ns 0 '' 1
eq "$NRC" "0" "nightly-status: gh failing → still exit 0"
has "$NOUT" "unreadable (gh run list failed" "nightly-status: …reported as unreadable, distinct from absence"
hasnt "$NOUT" "no nightly result found" "nightly-status: …never as 'no nightly'"
ns 0 '[] INVALID'
has "$NOUT" "unreadable (gh returned a document that does not parse)" "nightly-status: a document that parses part-way is unreadable, never 'no nightly'"
hasnt "$NOUT" "no nightly result found" "nightly-status: …and never reported as absence"
ns 0 '{"not":"an array"}'
has "$NOUT" "unreadable (gh returned an unexpected document)" "nightly-status: a non-array document is unreadable"
# NOTHING UNVALIDATED REACHES MARKDOWN.
ns 0 "$(rec 'https://github.com/a/b/actions/runs/1) [click](https://evil.example' completed success "$SHA")"
has "$NOUT" "unreadable (the run URL has an unexpected shape)" "nightly-status: a URL carrying Markdown is refused"
hasnt "$(cat "$work/ns-summary")" "evil.example" "nightly-status: …and none of it reaches the summary"
ns 0 "$(rec "$URL" completed 'success**' "$SHA")"
has "$NOUT" "unreadable (the run conclusion has an unexpected shape)" "nightly-status: a conclusion of an unexpected shape is refused"
ns 0 "$(rec "$URL" completed success '0123456')"
has "$NOUT" "unreadable (the run's commit has an unexpected shape)" "nightly-status: an abbreviated commit is refused (GitHub reports the full 40 hex)"
ns 0 "$(rec "$URL" completed bogus "$SHA")"
has "$NOUT" "unreadable (the run conclusion has an unexpected shape)" "nightly-status: a conclusion outside GitHub's vocabulary is refused"
ns 0 '[{"url":"'"$URL"'","status":"completed","conclusion":"success","createdAt":"'"$created"'","headSha":12345}]'
has "$NOUT" "unreadable (the run record did not parse)" "nightly-status: a field of the wrong JSON type is refused"
# A timestamp that only PARSES is not valid: `fromdateiso8601` normalizes Feb 30 to Mar 2.
created_ok="$created"; created='2025-02-30T08:53:20Z'
ns 0 "$(rec "$URL" completed success "$SHA")"
has "$NOUT" "unreadable (the run record did not parse)" "nightly-status: an impossible date (Feb 30) is refused, not normalized"
created='2025-10-9T08:53:20Z'
ns 0 "$(rec "$URL" completed success "$SHA")"
has "$NOUT" "unreadable (the run record did not parse)" "nightly-status: an unpadded timestamp is refused"
created="$created_ok"
ns 0 "$(rec "$URL" completed success 'not-a-sha')"
has "$NOUT" "unreadable (the run's commit has an unexpected shape)" "nightly-status: a commit of an unexpected shape is refused"
NOUT="$(bash "$NS" extra 2>&1)"; NRC=$?
eq "$NRC" "2" "nightly-status: an argument is usage (2)"

# ============================== 5. the shipped registry =========================================
LIST="$(bash "$ROOT/scripts/selfcheck.sh" --list)" || bad "the shipped registry could not be listed"
# A suite that drives `check_mutation_rows` EXECUTES `scripts/mutation-gate.sh` (#470), which in
# turn reads `scripts/selfcheck.sh --list`. Both therefore belong in that step's declared inputs —
# a harness gated on a set that omits its own gate skips exactly the run that would have caught a
# change to it (`declared-inputs-incomplete`). Derived from the suites, never from a list here.
_rowsteps=0
while IFS="$(printf '\t')" read -r _s _cmd _ _ _in; do
  [ -n "$_s" ] || continue
  [ "$_in" != "-" ] || continue
  _suite="$(printf '%s' "$_cmd" | awk '{print $2}')"
  [ -f "$ROOT/$_suite" ] || continue
  grep -q '^[[:space:]]*check_mutation_rows ' "$ROOT/$_suite" || continue
  _rowsteps=$((_rowsteps + 1))
  case ",$_in," in *,scripts/mutation-gate.sh,*) ok ;; *) bad "$_s drives check_mutation_rows, so its verdict depends on scripts/mutation-gate.sh — it must declare it as an input" ;; esac
  case ",$_in," in *,scripts/selfcheck.sh,*) ok ;; *) bad "$_s drives check_mutation_rows, whose gate reads the registry — it must declare scripts/selfcheck.sh as an input" ;; esac
done <<< "$LIST"
# SAY WHAT IT CHECKED. With no matching step this loop asserts nothing and prints what a clean run
# prints — the silent-guard shape. One row-driving suite exists today; zero means the grep stopped
# matching, not that the rule stopped applying.
[ "$_rowsteps" -ge 1 ] && ok   || bad "no registered step was found driving check_mutation_rows — this pin scanned nothing, which is indistinguishable from it passing"

# …and the same rule for the vendored harness (#519): a suite that runs its whole-suite pool through
# `check_shmutant_pool` EXECUTES `scripts/shmutant.sh`, so a step gated on inputs that omit it would
# skip exactly the run that proves a new pin of it still kills every row. Derived from the suites.
_shmsteps=0
while IFS="$(printf '\t')" read -r _s _cmd _ _ _in; do
  [ -n "$_s" ] || continue
  [ "$_in" != "-" ] || continue
  _suite="$(printf '%s' "$_cmd" | awk '{print $2}')"
  [ -f "$ROOT/$_suite" ] || continue
  grep -q '^[[:space:]]*check_shmutant_pool ' "$ROOT/$_suite" || continue
  _shmsteps=$((_shmsteps + 1))
  case ",$_in," in *,scripts/shmutant.sh,*) ok ;; *) bad "$_s runs check_shmutant_pool, so its verdict depends on scripts/shmutant.sh — it must declare it as an input" ;; esac
done <<< "$LIST"
[ "$_shmsteps" -ge 1 ] && ok || bad "no registered step was found running check_shmutant_pool — this pin scanned nothing, which is indistinguishable from it passing"

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
# SINCE #456 (D126) NO HARNESS RUNS PER PULL REQUEST. The per-PR gate's wiring (#441) is retired on
# the CI side: ci.yml carries NO `--mutation` invocation, direct or gated, and the macOS leg skips
# every `*-mutation` step by a list it reads from the registry. The harnesses run in
# `mutation-nightly.yml` — scheduled, dispatched, or on a labelled PR — whose matrix IS the registry.
#
# The rule is about the INVOCATION, whatever YAML shape carries it: `run: bash …`, a `run: |`
# block's own line, a folded scalar — any non-comment line that invokes a harness's --mutation mode.
CI="$ROOT/.github/workflows/ci.yml"
direct="$(grep -nE 'bash scripts/check-[a-z-]+\.sh --mutation' "$CI" \
           | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'mutation-gate\.sh run ' || true)"
[ -z "$direct" ] && ok || bad "ci.yml invokes a mutation harness directly — harnesses run in mutation-nightly.yml since #456:$direct"
gated="$(grep -nE '^[^#]*mutation-gate\.sh run [a-z-]+-mutation' "$CI" || true)"
[ -z "$gated" ] && ok || bad "ci.yml runs a mutation harness through the per-PR gate — harnesses run in mutation-nightly.yml since #456:$gated"
# …and a `selfcheck.sh --only <x>-mutation` would be the same harness by a third spelling.
only="$(grep -nE '^[^#]*selfcheck\.sh .*--only[ =][^ ]*-mutation' "$CI" || true)"
[ -z "$only" ] && ok || bad "ci.yml runs a mutation harness through selfcheck --only:$only"
n_inv=$(( $(printf '%s' "$direct" | grep -c . || true) + $(printf '%s' "$gated" | grep -c . || true) + $(printf '%s' "$only" | grep -c . || true) ))
printf 'check-mutation-gate: %s harness invocation(s) in ci.yml\n' "$n_inv"

# THE macOS LEG runs the whole registry less every `*-mutation` step, and the list it skips is READ
# from the registry at run time — never hand-copied, so a new harness cannot land unskipped. Every
# active `selfcheck.sh` line there that runs steps (not `--summarize`/`--list`) must skip that list.
# …and WHAT THE CONSUMER RECEIVES is checked by RUNNING the step's own script, not by reading its
# spelling: a later `skip=`, a `read -r skip`, any reassignment between the read and the call would
# pass a pin on the text. Its `run: |` body is extracted, its `bash scripts/selfcheck.sh` replaced by
# a recorder of the arguments it was given, and the `--skip` value must equal the registry's set.
# WORKFLOW STRUCTURE COMES FROM THE SHARED READER, `adb_wf_jobs` (common.sh) — its JOB/RANGE/STEP
# records — never from a second boundary parser here. A job is its RANGE; a step runs from its STEP
# line to the line before the next one (or the job's end).
wf_job_text() {  # wf_job_text <file> <job-key> — the job's lines; 1 when it is not found
  local recs n start end
  recs="$(adb_wf_jobs "$1")" || return 1
  n="$(printf '%s\n' "$recs" | awk -F'\t' -v k="$2" '$1 == "JOB" && $3 == k { print $2; exit }')"
  [ -n "$n" ] || return 1
  read -r start end < <(printf '%s\n' "$recs" | awk -F'\t' -v n="$n" '$1 == "RANGE" && $2 == n { print $3, $4; exit }')
  [ -n "${start:-}" ] && [ -n "${end:-}" ] || return 1
  sed -n "${start},${end}p" "$1"
}
wf_step_text() {  # wf_step_text <file> <job-key> <ERE> — the step of that job holding a matching line
  local recs n end i s e
  local -a at=()
  recs="$(adb_wf_jobs "$1")" || return 1
  n="$(printf '%s\n' "$recs" | awk -F'\t' -v k="$2" '$1 == "JOB" && $3 == k { print $2; exit }')"
  [ -n "$n" ] || return 1
  end="$(printf '%s\n' "$recs" | awk -F'\t' -v n="$n" '$1 == "RANGE" && $2 == n { print $4; exit }')"
  mapfile -t at < <(printf '%s\n' "$recs" | awk -F'\t' -v n="$n" '$1 == "STEP" && $2 == n { print $4 }')
  for (( i = 0; i < ${#at[@]}; i++ )); do
    s="${at[i]}"
    if (( i + 1 < ${#at[@]} )); then e=$(( at[i+1] - 1 )); else e="$end"; fi
    if sed -n "${s},${e}p" "$1" | grep -qE -- "$3"; then sed -n "${s},${e}p" "$1"; return 0; fi
  done
  return 1
}
wf_run_body() {  # stdin: one step's text — prints its `run: |` body, de-indented by its own depth
  awk '
    !b && /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ { match($0, /^ */); ind = RLENGTH + 2; b = 1; next }
    b { if ($0 ~ /^[[:space:]]*$/) { print ""; next }
        match($0, /^ */); if (RLENGTH < ind) exit
        print substr($0, ind + 1) }'
}
macos_body="$(wf_step_text "$CI" selfcheck-macos '^[[:space:]]*- name: The offline suite on Homebrew bash' | wf_run_body)"
[ -n "$macos_body" ] && ok || bad "could not extract the macOS suite step's run block from ci.yml (the scan matched nothing)"
recv="$(cd "$ROOT" && RUNNER_TEMP="$work" bash -c "$(printf '%s\n' "$macos_body" | sed 's#bash scripts/selfcheck\.sh#printf "SELFCHECK-ARG:%s\\n"#')" 2>/dev/null | awk '/^SELFCHECK-ARG:/{sub(/^SELFCHECK-ARG:/,""); print}')"
eq "$(printf '%s\n' "$recv" | head -1)" "--skip" "the macOS suite step calls selfcheck with --skip"
eq "$(printf '%s\n' "$recv" | sed -n 2p | tr ',' '\n' | LC_ALL=C sort | tr '\n' ' ')" \
   "$(printf '%s\n' "$MUT_STEPS" | LC_ALL=C sort | tr '\n' ' ')" \
   "the macOS suite step HANDS selfcheck exactly the registry's *-mutation steps to skip"
grep -qE '^[[:space:]]*skip="\$\(bash scripts/mutation-gate\.sh steps --csv\)" \|\| ' "$CI" && ok \
  || bad "ci.yml's selfcheck-macos does not build its --skip from 'bash scripts/mutation-gate.sh steps --csv' (with a failure branch)"
runs_all="$(grep -nE '^[^#]*bash scripts/selfcheck\.sh( |$)' "$CI" | grep -vE 'selfcheck\.sh --(summarize|list)' || true)"
[ -n "$runs_all" ] && ok || bad "ci.yml carries no selfcheck.sh invocation that runs the registry (the scan matched nothing)"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *'selfcheck.sh --skip "$skip"'*) ok ;; *) bad "ci.yml runs selfcheck.sh without skipping the registry's *-mutation steps: $line" ;; esac
done <<< "$runs_all"
# THE LAST-NIGHTLY LINE is wired into a PR job, survives an earlier red step, and may read runs —
# each asked of THAT JOB's block, so a permission or condition elsewhere in the file cannot stand in.
cl_job="$(wf_job_text "$CI" common-lib)"
[ -n "$cl_job" ] && ok || bad "could not extract the common-lib job from ci.yml (the scan matched nothing)"
printf '%s\n' "$cl_job" | grep -qE '^        run: bash scripts/mutation-nightly-status\.sh$' && ok \
  || bad "the common-lib job no longer runs scripts/mutation-nightly-status.sh — the PR's line about the harnesses is gone"
# …and the condition and the checkout id belong to THEIR STEPS, not merely to the job: a condition
# moved onto another step leaves the reporter on the default `success()`, and an id on the wrong step
# makes the condition read an unknown outcome. Each step is asked of `wf_step_text`.
rep_step="$(wf_step_text "$CI" common-lib '^[[:space:]]*run: bash scripts/mutation-nightly-status\.sh$')"
printf '%s\n' "$rep_step" | grep -qF "        if: \${{ !cancelled() && steps.checkout.outcome == 'success' }}" && ok \
  || bad "the last-nightly step does not run past an earlier red step (!cancelled() and a successful checkout)"
co_step="$(wf_step_text "$CI" common-lib '^[[:space:]]*uses: actions/checkout@')"
printf '%s\n' "$co_step" | grep -qE '^        id: checkout$' && ok \
  || bad "the common-lib job's checkout carries no 'id: checkout', so the last-nightly condition reads an unknown step"
printf '%s\n' "$cl_job" | grep -qE '^      actions: read$' && ok \
  || bad "the common-lib job does not grant 'actions: read', which the last-nightly line needs to list runs"
# The list it reads is exactly the registry's set — the subcommand is the one home, asserted here.
eq "$(bash "$ROOT/scripts/mutation-gate.sh" steps --csv | tr ',' '\n' | LC_ALL=C sort | tr '\n' ' ')" \
   "$(printf '%s\n' "$MUT_STEPS" | LC_ALL=C sort | tr '\n' ' ')" \
   "mutation-gate.sh steps --csv is exactly the registry's *-mutation steps (the macOS skip list)"

# THE SCHEDULED WORKFLOW runs every *-mutation step unconditionally, and its matrix is READ from the
# registry by its plan job — so a harness cannot exist in the registry and be absent from the
# schedule. What is pinned is that wiring; the list itself has no copy in the file to drift.
NIGHTLY="$ROOT/.github/workflows/mutation-nightly.yml"
[ -f "$NIGHTLY" ] && ok || bad "the scheduled workflow $NIGHTLY is missing"
if [ -f "$NIGHTLY" ]; then
  nt="$(cat "$NIGHTLY")"
  has "$nt" "ADB_MUTATION_RUN_ALL: '1'" "the scheduled workflow forces every harness (ADB_MUTATION_RUN_ALL)"
  # Per-block runs score a per-test row against its own block (#468); this workflow scores every row
  # against the whole suite, which is what catches a block that under-declares.
  has "$nt" "ADB_MUTATION_FULL_SUITE: '1'" "the scheduled workflow runs every mutant against the full suite (ADB_MUTATION_FULL_SUITE)"
  grep -qE '^  schedule:' "$NIGHTLY" && ok || bad "the scheduled workflow has no schedule: trigger"
  grep -qE '^      step:$' "$NIGHTLY" && ok || bad "the scheduled workflow's workflow_dispatch has no 'step' input (#456)"
  grep -qE '^      matrix: \$\{\{ fromJSON\(needs\.plan\.outputs\.matrix\) \}\}$' "$NIGHTLY" && ok \
    || bad "the scheduled workflow's matrix is not read from the plan job (matrix: \${{ fromJSON(needs.plan.outputs.matrix) }})"
  # …and the WHOLE connection behind it, link by link: the plan step publishes the list it read, the
  # job exports that step's output, and the matrix job needs the plan. A constant at any link would
  # pass a pin that checked only the two ends (review finding).
  grep -qE '^      - name: Read the harness list from the registry$' "$NIGHTLY" \
    && grep -qE '^        id: plan$' "$NIGHTLY" && ok || bad "the plan job's registry step is not 'id: plan'"
  grep -qE '^          printf .matrix=%s\\n. "\$matrix" >> "\$GITHUB_OUTPUT"$' "$NIGHTLY" && ok \
    || bad "the plan step does not publish the list it read to GITHUB_OUTPUT"
  grep -qE '^      matrix: \$\{\{ steps\.plan\.outputs\.matrix \}\}$' "$NIGHTLY" && ok \
    || bad "the plan job does not export its step's output (outputs.matrix: \${{ steps.plan.outputs.matrix }})"
  grep -qE '^    needs: plan$' "$NIGHTLY" && ok || bad "the matrix job does not need the plan job"
  # …and the two CONSUMER links: the dispatch input reaches the plan through `ONLY`, and each matrix
  # job runs ITS OWN step. A constant at either would run every harness for a one-step dispatch, or
  # one harness in every matrix job (review finding).
  grep -qE "^          ONLY: \\$\\{\\{ github\\.event_name == 'workflow_dispatch' && inputs\\.step \\|\\| '' \\}\\}$" "$NIGHTLY" && ok \
    || bad "the plan step does not bind ONLY to the dispatch input"
  grep -qE '^          bash scripts/selfcheck\.sh --only "\$\{\{ matrix\.step \}\}" 2>&1 \| tee ' "$NIGHTLY" && ok \
    || bad "the matrix job does not run its own matrix.step"
  # SHARDS (#532): the harness step hands the job's own shard to the harness, and each job's
  # failure evidence and name carry it — two shards of one step would otherwise collide on the
  # artifact name (an upload-artifact v4+ error) and be indistinguishable in the run.
  run_step="$(wf_step_text "$NIGHTLY" mutation-nightly '^[[:space:]]*- name: Run the harness unconditionally$')"
  printf '%s\n' "$run_step" | grep -qE '^          ADB_MUTATION_SHARD: \$\{\{ matrix\.shard \}\}/\$\{\{ matrix\.shards \}\}$' && ok \
    || bad "the harness step does not hand its job's shard to the harness (ADB_MUTATION_SHARD: \${{ matrix.shard }}/\${{ matrix.shards }})"
  grep -qE '^          name: mutation-artifacts-\$\{\{ matrix\.step \}\}-shard-\$\{\{ matrix\.shard \}\}-of-\$\{\{ matrix\.shards \}\}$' "$NIGHTLY" && ok \
    || bad "the failed-pool artifact name does not carry the shard, so two shards of one step collide"
  has "$nt" "    name: mutation-nightly (\${{ matrix.step }}\${{ matrix.shards > 1 && format(', shard {0} of {1}', matrix.shard, matrix.shards) || '' }})" \
    "the matrix job's name keeps the plain step name unsharded and names the shard otherwise"
  # WHAT THE PLAN PUBLISHES, by RUNNING its script: the plan step's `run: |` body is executed with a
  # scratch GITHUB_OUTPUT, for no input, a one-step input and an unregistered one. A reassignment
  # between the registry read and the publish would pass every spelling check above.
  plan_body="$(wf_step_text "$NIGHTLY" plan '^[[:space:]]*- name: Read the harness list from the registry$' | wf_run_body)"
  [ -n "$plan_body" ] && ok || bad "could not extract the plan step's run block from the scheduled workflow (the scan matched nothing)"
  # The shard list is the plan step's own `SHARDS` env, read from the file and handed to the body as
  # the runner would.
  plan_shards="$(sed -n "s/^          SHARDS: '\(.*\)'\$/\1/p" "$NIGHTLY")"
  [ -n "$plan_shards" ] && ok || bad "could not read the plan step's SHARDS list from the scheduled workflow"
  run_plan() {  # run_plan <ONLY> — sets PLAN_RC and PLAN_OUT (the published `matrix=` value)
    : > "$work/plan-output"
    (cd "$ROOT" && ONLY="$1" SHARDS="$plan_shards" GITHUB_OUTPUT="$work/plan-output" bash -c "$plan_body") >/dev/null 2>&1; PLAN_RC=$?
    PLAN_OUT="$(sed -n 's/^matrix=//p' "$work/plan-output")"
  }
  run_plan ""
  eq "$PLAN_RC" "0" "the plan step succeeds with no dispatch input"
  eq "$PLAN_OUT" "$(bash "$ROOT/scripts/mutation-gate.sh" steps --matrix --shards "$plan_shards")" "the plan PUBLISHES exactly the registry's *-mutation steps as the matrix"
  eq "$(printf '%s' "$PLAN_OUT" | jq -r '[.include[].step] | unique | .[]' | LC_ALL=C sort | tr '\n' ' ')" \
     "$(printf '%s\n' "$MUT_STEPS" | LC_ALL=C sort | tr '\n' ' ')" "the published matrix carries every registered harness"
  # THE HARNESS THAT OUTGREW ONE JOB (#532) is split: a plan that dropped its entry would put the
  # whole table back in one job, which took up to 316 of the 360 minutes a hosted job may run.
  eq "$(printf '%s' "$PLAN_OUT" | jq '[.include[] | select(.step == "settings-fragment-mutation") | .shard] | length > 1')" "true" \
     "the published matrix splits settings-fragment-mutation into more than one shard"
  run_plan fact-mutation
  eq "$PLAN_OUT" '{"include":[{"step":"fact-mutation","shard":1,"shards":1}]}' "the plan PUBLISHES exactly the one dispatched step"
  run_plan settings-fragment-mutation
  eq "$(printf '%s' "$PLAN_OUT" | jq -c '[.include[] | .step] | unique')" '["settings-fragment-mutation"]' "a dispatch of a sharded step publishes only that step"
  eq "$(printf '%s' "$PLAN_OUT" | jq -c '[.include[].shard] == [range(1; (.include[0].shards) + 1)]')" "true" \
     "a dispatch of a sharded step publishes every one of its shards"
  run_plan no-such-mutation
  no "$PLAN_RC" "the plan step FAILS on an unregistered dispatch input rather than publishing a matrix"
  eq "$PLAN_OUT" "" "…and publishes nothing for it"
  grep -qE '^[[:space:]]*matrix="\$\(bash scripts/mutation-gate\.sh steps --matrix --shards "\$SHARDS" --only "\$ONLY"\)" \|\| exit 1$' "$NIGHTLY" && ok \
    || bad "the plan job does not validate a dispatched step through 'mutation-gate.sh steps --matrix --only' (with a failure exit)"
  grep -qE '^[[:space:]]*matrix="\$\(bash scripts/mutation-gate\.sh steps --matrix --shards "\$SHARDS"\)" \|\| exit 1$' "$NIGHTLY" && ok \
    || bad "the plan job does not read the full matrix through 'mutation-gate.sh steps --matrix' (with a failure exit)"
  # The input reaches the shell through env, never interpolated into the script body.
  if grep -nE '^[[:space:]]*(run:|[a-z]).*\$\{\{ *(inputs|github\.event\.inputs)\.step' "$NIGHTLY" | grep -vE '^[0-9]+:[[:space:]]*ONLY:' | grep -q .; then
    bad "the dispatch input is interpolated outside the plan step's env (script injection)"
  else ok; fi
  # THE LABEL TRIGGER (#456): `pull_request` narrowed to `labeled` alone — never
  # `pull_request_target`, never `opened`/`synchronize` — and the plan runs only for `run-mutations`.
  grep -qE '^[^#]*pull_request_target' "$NIGHTLY" && bad "the scheduled workflow must not use pull_request_target (it would run a fork's code with a write token)" || ok
  eq "$(awk '/^  pull_request:/{f=1; next} f && /^    types:/{print; exit} f && /^  [a-z]/{exit}' "$NIGHTLY")" \
     "    types: [labeled]" "the scheduled workflow's pull_request trigger is narrowed to 'types: [labeled]'"
  has "$nt" "github.event.label.name == 'run-mutations'" "the plan job runs on a pull_request only for the run-mutations label"
  eq "$(grep -cE "ref: \\\$\{\{ github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| '' \}\}" "$NIGHTLY")" "2" \
     "both jobs check out a labelled PR's HEAD commit, not its merge commit"
  # …and DISCOVERY ITSELF agrees nothing here is a required context, asked of repo-settings.sh
  # rather than inferred from the trigger's spelling: zero contexts on stdout.
  dd="$work/nightly-discovery"; mkdir -p "$dd"; cp "$NIGHTLY" "$dd/"
  disc="$(bash "$ROOT/scripts/lib/repo-settings.sh" checks --workflow-dir "$dd" 2>/dev/null)"; drc=$?
  eq "$drc" "0" "repo-settings discovery reads the scheduled workflow"
  eq "$disc" "" "repo-settings discovery finds no required context in the scheduled workflow"
fi

check_summary "check-mutation-gate"
