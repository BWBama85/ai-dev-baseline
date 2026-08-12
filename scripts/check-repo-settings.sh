#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the repo-settings helper (scripts/lib/repo-settings.sh, #87).
# OFFLINE: no network, no gh auth, no real repo is touched.
#
# Two halves, both of which are where this library can go wrong in ways nothing else would catch:
#
#   1. CHECK DISCOVERY — pure file parsing, so it is fully testable. The headline regression is
#      the `on:` false positive: `push:` and `pull_request:` sit at the SAME 2-space indent as job
#      keys, so a whole-file indent scan requires two contexts that can never report and blocks
#      every PR forever. This repo's own ci.yml is that exact shape, so the fixture below mirrors
#      it. Every "cannot prove it runs on every PR" skip is pinned too, because each one, if it
#      leaked into the required set, is a permanent PR deadlock.
#   2. WRITE ORDERING + ENDPOINT SELECTION — driven by a recording gh stub (the technique
#      check-release-convention.sh uses for `roll`). Two invariants matter more than the writes
#      themselves: required checks are written STRICTLY BEFORE allow_auto_merge (reversed, PRs
#      merge with nothing gating them), and a failed checks write means auto-merge is NOT enabled.
#      The endpoint choice is pinned because the wide one is destructive — a full protection PUT
#      REPLACES the object, so a naive body silently drops required_conversation_resolution and
#      the "require a PR before merging" guardrail.
#
# What genuinely CANNOT be tested here (needs the mocked-gh harness of #75, or a live run):
# that GitHub accepts the contexts, that auto-merge actually fires, real 403/404 bodies, and
# whether a `skipped` job satisfies a required context.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-repo-settings.sh   (exit 0 = all pass, 1 = a failure)

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
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RS="$ROOT/scripts/lib/repo-settings.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# rsx <args...> : run the helper with the REAL PATH — for the paths that refuse before any gh
# call (usage, dispatch, arg parsing) and for pure-discovery runs.
rsx() { OUT="$(bash "$RS" "$@" 2>&1)"; RC_=$?; }

# ============================ usage / dispatch ============================
rsx -h;      yes "$RC_" "-h exits 0";     has "$OUT" "hand PR merges to GitHub" "-h prints the usage header"
rsx --help;  yes "$RC_" "--help exits 0"
rsx;         no  "$RC_" "no subcommand exits nonzero"
rsx bogus;   no  "$RC_" "unknown subcommand exits nonzero"
has "$OUT" "unknown subcommand 'bogus'" "unknown subcommand names itself"
has "$OUT" "'checks', 'status', 'apply', 'automerge-ok', 'required-drift', 'merge-flag', or 'branch-required-contexts'" "unknown subcommand lists every subcommand"

# ============================ branch-required-contexts (#115) ============================
# The provider-agnostic CI-existence evidence /roadmap's health gate reads. PURE — jq only, body on
# stdin, no gh — so it is driven here with the SAME fixtures `read_branch` uses, which is the point
# of factoring the 200-body model into one classifier: the two consumers cannot disagree about what
# a ruleset-protected branch means.
#
# The distinction that carries the safety property is `[]` vs `null`. `[]` is an AUTHORITATIVE
# "this branch declares nothing", and combined with zero Actions workflows it is what lets a
# genuinely CI-less repo release (#24). `null` is "we could not tell", and it must never reach that
# arm — a ruleset-protected branch reports a REAL empty `contexts` array, so a classifier that
# answered `[]` there would let /roadmap cut on a branch whose protection it could not read.
brc() { OUT="$(printf '%s' "$1" | bash "$RS" branch-required-contexts 2>&1)"; RC_=$?; }

brc '{"protected":false}'
eq "$OUT" '[]' "an UNPROTECTED branch authoritatively declares no contexts"; yes "$RC_" "...and exits 0"
brc '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":[]}}}'
eq "$OUT" '[]' "classic protection with required checks OFF is an authoritative empty set"
brc '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["ci"]}}}'
eq "$OUT" '["ci"]' "a declared context comes back as a JSON array"
# SORTED and de-quoted the same way `read_branch` produces BR_CONTEXTS, so the two consumers of the
# one classifier cannot report different sets for the same branch.
brc '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["zeta","alpha"]}}}'
eq "$OUT" '["alpha","zeta"]' "...LC_ALL=C-sorted, matching read_branch's own contract"
# A context name legitimately contains spaces, `/` and `:` — and may contain a quote or a tab. The
# output is built with jq from raw lines, never interpolated, so none of those can break the JSON
# the caller is about to splice into a health document with --argjson.
brc '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["ci/circleci: build"]}}}'
eq "$OUT" '["ci/circleci: build"]' "a context with a slash, colon and space survives intact"
brc "$(jq -nc '{protected:true,protection:{enabled:true,required_status_checks:{contexts:["say \"hi\""]}}}')"
eq "$OUT" '["say \"hi\""]' "...and one carrying a double quote is escaped, not broken out of"
# THE THREE UNREADABLE SHAPES, all `null`. A ruleset-protected branch is the one that matters most:
# `contexts` IS an array there, so an array-only test accepts it as "requires nothing".
brc '{"protected":true,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[]}}}'
eq "$OUT" 'null' "a RULESET-protected branch is null (unknown), never an empty set"
brc '{"protected":true,"protection":{"enabled":true}}'
eq "$OUT" 'null' "protected with no readable context list is null"
brc 'not json at all'
eq "$OUT" 'null' "an unparseable body is null, never an empty set"
# A CONTEXTS ARRAY WE CANNOT MAKE SENSE OF IS `opaque`, NOT AN EMPTY SET (independent-review find).
# Checking only that `contexts` is an ARRAY let three shapes through, each of which then looked
# authoritative downstream: `[null,5]` was stringified by `jq -r` into the plausible contexts
# "null" and "5"; `[""]` was dropped to `[]`, which IS the authoritative "declares nothing" and can
# reach `no-ci`; and neither could be caught later, because by then they were ordinary strings.
for junk in '[null]' '[5]' '[null,5]' '["ci",5]' '[true]' '[["ci"]]' '[{"context":"ci"}]' '[""]' '["  "]' '["ci",""]'; do
  brc "$(printf '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":%s}}}' "$junk")"
  eq "$OUT" 'null' "a contexts array containing $junk is unreadable (null), never a set to act on"
done
# A context name CONTAINING A NEWLINE must round-trip as ONE context. The first cut serialized the
# set as newline-delimited text, so `["a\nb"]` came back out as TWO required contexts, one of which
# nothing can ever report — a phantom, and a permanent `indeterminate`.
brc "$(jq -nc '{protected:true,protection:{enabled:true,required_status_checks:{contexts:["a\nb"]}}}')"
eq "$OUT" '["a\nb"]' "a context containing a newline stays ONE context, escaped"
eq "$(printf '%s' "$OUT" | jq -c 'length')" '1' "...and really is a single-element array"
# Duplicates collapse, so the two consumers of the one classifier cannot disagree about the set.
brc '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["ci","ci"]}}}'
eq "$OUT" '["ci"]' "a duplicated context is emitted once"
# Whatever the answer, it must be ONE line of valid JSON: the caller feeds it straight to --argjson.
for shape in '{"protected":false}' '{"protected":true,"protection":{"enabled":true,"required_status_checks":{"contexts":["a","b"]}}}' 'garbage'; do
  brc "$shape"
  # `jq .`, NOT `jq -e .`: with -e a valid JSON `null` exits 1, so the null answer — the one that
  # carries the fail-closed property — would read as "not JSON". The question here is parseability,
  # not truthiness.
  if printf '%s' "$OUT" | jq . >/dev/null 2>&1; then ok; else bad "branch-required-contexts emitted non-JSON for [$shape]: $OUT"; fi
done
rsx branch-required-contexts --branch main </dev/null
no "$RC_" "branch-required-contexts takes no options (the caller already chose the branch when it read)"
rsx branch-required-contexts extra </dev/null
no "$RC_" "...and no positional arguments"

# ============================ arg parsing (per-subcommand on purpose) ============================
# A shared parser would make `status --dry-run` and `checks --strict` silently valid, so both
# directions are pinned: apply-only flags are rejected by the read subcommands, and every
# subcommand rejects an unknown option rather than ignoring it.
rsx apply --branch;        no "$RC_" "apply --branch w/o value exits nonzero"; has "$OUT" "needs a value" "missing --branch value is named"
rsx apply --branch '';     no "$RC_" "apply --branch '' exits nonzero";        has "$OUT" "must not be empty" "empty branch is rejected"
rsx apply --branch '   ';  no "$RC_" "apply --branch whitespace exits nonzero"
rsx apply --bogus;         no "$RC_" "apply unknown option exits nonzero";     has "$OUT" "unknown option" "apply names an unknown option"
rsx status --dry-run;      no "$RC_" "status rejects the apply-only --dry-run"
rsx status --strict;       no "$RC_" "status rejects the apply-only --strict"
rsx checks --enforce-admins; no "$RC_" "checks rejects the apply-only --enforce-admins"
rsx automerge-ok --dry-run;  no "$RC_" "automerge-ok rejects the apply-only --dry-run"
rsx required-drift --dry-run; no "$RC_" "required-drift rejects the apply-only --dry-run"
rsx required-drift --prune;   no "$RC_" "required-drift rejects the apply-only --prune"
rsx checks --branch;       no "$RC_" "checks --branch w/o value exits nonzero"

# ============================ check discovery (pure file parsing) ============================
WF="$work/wf"; mkdir -p "$WF"
# wf_reset : drop every fixture workflow. One home — the 8 scenarios below each start from it.
wf_reset() { rm -f "$WF"/*.yml "$WF"/*.yaml; }

# disco <branch> : run `checks` against the fixture workflow dir; stdout in OUT, stderr in ERR.
disco() {
  OUT="$(bash "$RS" checks --branch "${1:-main}" --workflow-dir "$WF" 2>"$work/err")"
  RC_=$?
  ERR="$(cat "$work/err")"
}
# ctx : the discovered contexts as one pipe-joined, sorted string, so ORDER-INDEPENDENT set
# equality is a single eq assertion.
ctx() { printf '%s\n' "$OUT" | sed '/^$/d' | LC_ALL=C sort | tr '\n' '|'; }

# --- the headline regression: `on:` keys sit at the same indent as job keys -------------------
# Mirrors this repo's own .github/workflows/ci.yml. A whole-file 2-space indent scan yields 22
# "jobs" here (push, pull_request, and the two real ones); scoping to the `jobs:` block yields 2.
wf_reset
cat > "$WF/ci.yml" <<'EOF'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck
  build-drift:
    name: build-drift
    runs-on: ubuntu-latest
    steps:
      - name: Rebuild
        run: bash scripts/build.sh
EOF
disco main
yes "$RC_" "discovery over a ci.yml-shaped file exits 0"
eq "${ ctx; }" 'build-drift|shellcheck|' "only real jobs are contexts — the on: block's push/pull_request are NOT harvested"
hasnt "$OUT" "push"          "the push: trigger never becomes a required context"
hasnt "$OUT" "pull_request"  "the pull_request: trigger never becomes a required context"
hasnt "$OUT" "Checkout"      "a step-level '- name:' is never mistaken for a job name"
hasnt "$OUT" "Install shellcheck" "a second step-level '- name:' is never harvested either"

# --- name vs key, and every "cannot prove it runs" skip --------------------------------------
wf_reset
cat > "$WF/a.yml" <<'EOF'
name: A
on:
  pull_request:
jobs:
  keyed:
    runs-on: ubuntu-latest
  named:
    name: Human Name
    runs-on: ubuntu-latest
  quoted:
    name: "quoted name"
    runs-on: ubuntu-latest
  conditional:
    name: cond
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
  matrixed:
    name: mat
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
  bare-strategy:
    name: bare
    strategy:
      fail-fast: false
    runs-on: ubuntu-latest
  reusable:
    uses: ./.github/workflows/other.yml
  dynamic:
    name: dyn-${{ github.event_name }}
    runs-on: ubuntu-latest
EOF
disco main
eq "${ ctx; }" 'Human Name|bare|keyed|quoted name|' "name: wins over the job key; a keyless job falls back to its key; quotes stripped"
has "$ERR" "skipping job conditional" "a job-level if: is skipped (it may never report)"
has "$ERR" "skipping job matrixed"    "a matrix job is skipped (its check name carries a suffix)"
has "$ERR" "skipping job reusable"    "a reusable-workflow job is skipped (names come from the callee)"
has "$ERR" "skipping job dynamic"     "a \${{ }} job name is skipped (not statically knowable)"
has "$ERR" "blocks the PR forever"    "the skip reason states WHY a phantom context is dangerous"
hasnt "${ ctx; }" 'mat|'  "a matrix job never reaches the required set"
hasnt "${ ctx; }" 'cond|' "a conditional job never reaches the required set"

# --- file-level triggers ----------------------------------------------------------------------
wf_reset
printf 'name: P\non: push\njobs:\n  never-on-pr:\n    runs-on: ubuntu-latest\n' > "$WF/push-only.yml"
disco main
eq "${ ctx; }" '' "a workflow with no pull_request trigger contributes nothing"
has "$ERR" "no pull_request trigger" "the file skip names the missing trigger"

wf_reset
printf 'name: I\non: [push, pull_request]\njobs:\n  inline:\n    runs-on: ubuntu-latest\n' > "$WF/inline.yml"
disco main
eq "${ ctx; }" 'inline|' "an inline flow-sequence 'on: [push, pull_request]' is recognized"

wf_reset
printf 'name: S\non: pull_request\njobs:\n  scalar:\n    runs-on: ubuntu-latest\n' > "$WF/scalar.yml"
disco main
eq "${ ctx; }" 'scalar|' "an inline scalar 'on: pull_request' is recognized"

wf_reset
printf 'name: Pa\non:\n  pull_request:\n    paths:\n      - "src/**"\njobs:\n  scoped:\n    runs-on: ubuntu-latest\n' > "$WF/paths.yml"
disco main
eq "${ ctx; }" '' "a paths-filtered pull_request contributes nothing (it does not run for every PR)"
has "$ERR" "paths/paths-ignore filter" "the file skip names the paths filter"

# branches: filters — provably-includes vs not. Both directions matter: over-skipping silently
# leaves a repo ungated, under-skipping deadlocks every PR.
wf_reset
printf 'name: B\non:\n  pull_request:\n    branches: [main]\njobs:\n  ok-inline:\n    runs-on: ubuntu-latest\n' > "$WF/b1.yml"
printf 'name: C\non:\n  pull_request:\n    branches:\n      - main\njobs:\n  ok-block:\n    runs-on: ubuntu-latest\n' > "$WF/b2.yml"
printf 'name: D\non:\n  pull_request:\n    branches:\n      - develop\njobs:\n  wrong-base:\n    runs-on: ubuntu-latest\n' > "$WF/b3.yml"
printf 'name: E\non:\n  pull_request:\n    branches: ["*"]\njobs:\n  star:\n    runs-on: ubuntu-latest\n' > "$WF/b4.yml"
disco main
eq "${ ctx; }" 'ok-block|ok-inline|star|' "branches: including the target (inline, block, or '*') keeps the job; another base drops it"
has "$ERR" "does not provably include main" "the branches skip names the target branch"
disco develop
has "${ ctx; }" 'wrong-base|' "the same fixture keeps the develop-only job when develop IS the target"

# --- multiple files aggregate; a missing dir is 'no CI', not an error -------------------------
wf_reset
printf 'name: One\non:\n  pull_request:\njobs:\n  one:\n    runs-on: ubuntu-latest\n' > "$WF/one.yml"
printf 'name: Two\non:\n  pull_request:\njobs:\n  two:\n    runs-on: ubuntu-latest\n' > "$WF/two.yaml"
disco main
eq "${ ctx; }" 'one|two|' "contexts aggregate across .yml and .yaml files"

OUT="$(bash "$RS" checks --branch main --workflow-dir "$work/nonexistent" 2>"$work/err")"; RC_=$?
yes "$RC_" "a repo with no .github/workflows exits 0 (no CI is a legitimate state, not an error)"
eq "$OUT" "" "a repo with no CI discovers no contexts"
has "$(cat "$work/err")" "no CI" "the no-CI case says so on stderr"

wf_reset
mkdir -p "$WF"
printf 'name: E\non:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/keep.yml"
OUT="$(bash "$RS" checks --branch main --workflow-dir "$WF" 2>"$work/err")"; RC_=$?
yes "$RC_" "a directory with only readable workflows still exits 0"

# ============================ #102: indentation is not the grammar ============================
# THE REPRODUCTION. A uniform 4-space workflow is valid YAML that GitHub runs happily. Before this,
# discovery reported `skipping ci.yml — no pull_request trigger`, contributed ZERO contexts, and
# EXITED 0 — the parser going blind with nothing to report it. `required-drift`, the backstop that
# was supposed to catch the under-requirement, could not (it derives its desired set from this same
# discovery), so `apply` reported success while gating nothing.
wf_reset
cat > "$WF/ci.yml" <<'EOF'
name: CI
on:
    push:
    pull_request:
        branches:
            - main
jobs:
    shellcheck:
        name: shellcheck
        runs-on: ubuntu-26.04
        steps:
            - name: Checkout
              uses: actions/checkout@v4
    build-drift:
        name: build-drift
        runs-on: ubuntu-26.04
        steps:
            - name: Rebuild
              run: bash scripts/build.sh
EOF
disco main
yes "$RC_" "4-space: discovery exits 0"
eq "${ ctx; }" 'build-drift|shellcheck|' "4-space: both jobs are discovered (they used to be invisible)"
hasnt "$ERR" "no pull_request trigger" "4-space: the trigger block is read, not reported missing"
hasnt "$OUT" "push" "4-space: the push: trigger still never becomes a context"
hasnt "$OUT" "Checkout" "4-space: a step-level '- name:' is still never mistaken for a job name"

# THE SAME FILTERS MUST STILL APPLY at 4 spaces. Reading the file is only half of it — a skip rule
# that silently stopped firing at the new indent would require a context that can never report.
wf_reset
cat > "$WF/skips.yml" <<'EOF'
name: S
on:
    pull_request:
jobs:
    keyed:
        runs-on: ubuntu-26.04
    conditional:
        if: github.event_name == 'push'
        runs-on: ubuntu-26.04
    matrixed:
        strategy:
            matrix:
                os: [a, b]
        runs-on: ${{ matrix.os }}
    reusable:
        uses: ./.github/workflows/other.yml
    dynamic:
        name: dyn-${{ github.event_name }}
        runs-on: ubuntu-26.04
EOF
disco main
eq "${ ctx; }" 'keyed|' "4-space: every 'cannot prove it reports' skip still fires"
has "$ERR" "skipping job conditional" "4-space: a job-level if: is still skipped"
has "$ERR" "skipping job matrixed"    "4-space: a matrix job is still skipped"
has "$ERR" "skipping job reusable"    "4-space: a reusable-workflow job is still skipped"
has "$ERR" "skipping job dynamic"     "4-space: a \${{ }} job name is still skipped"

# 4-space FILE-LEVEL filters, at their own relative depths.
wf_reset
printf 'on:\n    pull_request:\n        paths:\n            - "src/**"\njobs:\n    a:\n        runs-on: ubuntu-26.04\n' > "$WF/p.yml"
disco main
eq "${ ctx; }" '' "4-space: a paths-filtered pull_request contributes nothing"
has "$ERR" "paths/paths-ignore filter" "4-space: the paths skip is named"
wf_reset
printf 'on:\n    pull_request:\n        branches:\n            - develop\njobs:\n    a:\n        runs-on: ubuntu-26.04\n' > "$WF/b.yml"
disco main
eq "${ ctx; }" '' "4-space: a branches: filter naming another base is honoured"
has "$ERR" "does not provably include main" "4-space: the branches skip names the target"
disco develop
eq "${ ctx; }" 'a|' "4-space: ...and the same file keeps the job when develop IS the target"
wf_reset
printf 'on:\n    pull_request:\n        types:\n            - closed\njobs:\n    a:\n        runs-on: ubuntu-26.04\n' > "$WF/t.yml"
disco main
eq "${ ctx; }" '' "4-space: a narrowed types: is honoured (the merge-cleanup trap)"
has "$ERR" "needs both opened and synchronize" "4-space: the types skip says what is missing"

# A MIXED REPOSITORY: one 2-space file and one 4-space file, each detected independently. This is
# the case an "detect the file's indent unit" heuristic gets wrong — there is no single unit — and
# a per-file unit would still miss a file that mixes units WITHIN itself, which the next case is.
wf_reset
printf 'name: Two\non:\n  pull_request:\njobs:\n  two-space:\n    runs-on: ubuntu-26.04\n' > "$WF/two.yml"
printf 'name: Four\non:\n    pull_request:\njobs:\n    four-space:\n        runs-on: ubuntu-26.04\n' > "$WF/four.yml"
disco main
eq "${ ctx; }" 'four-space|two-space|' "a repo mixing 2-space and 4-space FILES discovers both"
wf_reset
printf 'name: M\non:\n  pull_request:\njobs:\n    inner-four:\n        runs-on: ubuntu-26.04\n' > "$WF/m.yml"
disco main
eq "${ ctx; }" 'inner-four|' "a SINGLE file mixing units between its on: and jobs: blocks reads too"

# --- the two DELIBERATE behaviour changes, pinned so neither drifts back silently ----------------
# Both were verified against origin/main and both turned out to be fixes rather than trade-offs.

# (a) NEGATION IS SCOPED TO BRANCH PATTERNS. The awk predecessor set the flag from ANY flow list it
#     parsed, `types:` included, so an ordinary `branches: [main]` beside a negated types entry was
#     refused and the job stopped being required — a silent under-requirement with no message
#     naming the real cause.
wf_reset
printf 'on:\n  pull_request:\n    types: [opened, synchronize, "!weird"]\n    branches: [main]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/negtypes.yml"
disco main
eq "${ ctx; }" 'a|' "a negated TYPES entry does not trip the branch-negation rule"
# ...and the rule it was scoped away from must still fire on a real branch negation, or the fix
# would have simply deleted the guard.
wf_reset
printf 'on:\n  pull_request:\n    branches: ["*", "!main"]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/negbr.yml"
disco main
eq "${ ctx; }" '' "a negated BRANCH pattern still refuses the file"
has "$ERR" "negative patterns" "...naming the ordered-precedence reason"

# (b) AN INLINE FLOW-MAPPING JOB. With a `name:` inside, the context is that name and requiring the
#     KEY would be a phantom that never reports. With NO `name:`, the context provably IS the key,
#     and skipping it would leave valid PR CI ungated — the opposite error, equally real.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  plain: {runs-on: ubuntu-26.04}\n  named: {runs-on: ubuntu-26.04, name: Real Name}\n' > "$WF/inline.yml"
disco main
eq "${ ctx; }" 'plain|' "an inline job with NO name: is required under its key"
has "$ERR" "skipping job named" "...while one carrying a name: is skipped"
has "$ERR" "cannot prove a check name" "...for the stated reason"

#     An inline job is required under its key ONLY when that key is provably the context. A NESTED
#     `environment: {name: …}` must not suppress it (a substring test did, leaving a real job
#     ungated), and `if:`/`uses:`/`strategy:` inside the mapping must disqualify it exactly as the
#     block-form arms do — requiring one of those under its key is a phantom that never reports.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  deploy: {runs-on: ubuntu-26.04, environment: {name: production}, steps: [x]}\n' > "$WF/nested.yml"
disco main
eq "${ ctx; }" 'deploy|' "an inline job whose only name: is NESTED is still required under its key"
wf_reset
printf 'on:\n  pull_request:\njobs:\n  conditional: {runs-on: x, if: false, steps: [y]}\n  matrixed: {runs-on: x, strategy: {matrix: {os: [p]}}, steps: [y]}\n  reusable: {uses: ./.github/workflows/o.yml}\n  plain: {runs-on: x, steps: [y]}\n' > "$WF/inlmeta.yml"
disco main
eq "${ ctx; }" 'plain|' "inline jobs carrying if:/strategy:/uses: are NOT required under their keys"
has "$ERR" "skipping job conditional" "...and each is skipped by name"
has "$ERR" "skipping job matrixed"    "...matrix too"
has "$ERR" "skipping job reusable"    "...and the reusable one"

# (c) YAML ANCHORS are ordinary jobs; ALIASES are not. Anchoring a job configuration is documented
#     GitHub behaviour, and treating the anchor token as an inline mapping skipped a readable job.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  build: &base\n    runs-on: ubuntu-26.04\n  alt: *base\n' > "$WF/anchor.yml"
disco main
eq "${ ctx; }" 'build|' "an ANCHORED job is required; its ALIAS is skipped"
has "$ERR" "YAML alias" "...and the alias skip names why"

# (d) A BLOCK-SCALAR name: must never become a required context. `>-` reports for nothing and needs
#     an admin token to clear.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  a:\n    name: >-\n      Build and test\n    runs-on: ubuntu-26.04\n' > "$WF/blockname.yml"
disco main
eq "${ ctx; }" '' "a block-scalar name: is skipped, not required"
hasnt "$OUT" ">-" "...and the scalar HEADER never reaches the required set"

# (e) BLOCK-SEQUENCE TRIGGERS, both spellings — valid YAML that used to read as 'no pull_request
#     trigger', which is #102's failure wearing a different costume.
wf_reset
printf 'on:\n  - push\n  - pull_request\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/seqin.yml"
disco main
eq "${ ctx; }" 'a|' "an indented block-sequence 'on:' is recognized"
wf_reset
printf 'on:\n- push\n- pull_request\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/seqflat.yml"
disco main
eq "${ ctx; }" 'a|' "an indentationless block-sequence 'on:' is recognized"

# ==================== #291: multi-line flow collections, and merge keys ====================
# The reader's own contract is asserted in check-common-lib.sh. What is asserted HERE is the half
# that check cannot show: that discovery's VERDICT moves, and in which direction. These fail in
# BOTH directions, which is why each gets its own fixture rather than one representative case.

# (a) UNDER-REQUIRING. A `branches:`/`types:` list wrapped across lines yielded the filter record
#     with NO entries, so the filter "did not provably include main" and every job in the file
#     stopped being required — `apply` reporting success while gating nothing, which is the failure
#     `required-drift` exists to catch arriving through the one input it cannot see.
wf_reset
printf 'name: A\non:\n  pull_request:\n    branches: [\n      main\n    ]\njobs:\n  wrapped:\n    runs-on: ubuntu-26.04\n' > "$WF/mlbranch.yml"
disco main
eq "${ ctx; }" 'wrapped|' "a branches: list wrapped across lines proves the target and KEEPS the job"
hasnt "$ERR" "does not provably include" "...so the file is no longer skipped for a filter it could not read"

wf_reset
printf 'name: B\non:\n  pull_request:\n    types: [\n      opened,\n      synchronize\n    ]\njobs:\n  wrapped:\n    runs-on: ubuntu-26.04\n' > "$WF/mltypes.yml"
disco main
eq "${ ctx; }" 'wrapped|' "a types: list wrapped across lines proves opened+synchronize and keeps the job"

#     The top-level trigger list, whose closing bracket sits at column 0.
wf_reset
printf 'name: C\non: [\n  push,\n  pull_request\n]\njobs:\n  wrapped:\n    runs-on: ubuntu-26.04\n' > "$WF/mlon.yml"
disco main
eq "${ ctx; }" 'wrapped|' "a top-level 'on: [' wrapped across lines is recognized as a PR trigger"
hasnt "$ERR" "no pull_request trigger" "...rather than reported as having none"

# (b) OVER-REQUIRING, which is the expensive direction and the one the issue did not predict. An
#     inline flow-mapping filter spanning lines carried no filter word on its opening line, so the
#     trigger read as UNFILTERED and its jobs were required — from a workflow that runs only on
#     `closed`, i.e. contexts that sit "expected — waiting" on every open PR forever.
wf_reset
printf 'name: D\non:\n  pull_request: {\n    types: [closed]\n  }\njobs:\n  never-on-open:\n    runs-on: ubuntu-26.04\n' > "$WF/mlinlinemap.yml"
disco main
eq "${ ctx; }" '' "a wrapped inline flow-mapping filter is refused, not read as an unfiltered trigger"
has "$ERR" "inline flow-mapping filter" "...naming the shape it cannot prove"

#     And an inline JOB mapping spanning lines: `keyed` was decided from the opening brace, so a
#     mapping whose `name:` sat one line down was required under its KEY while the check reports
#     under its NAME.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  named: {\n    name: Real Name,\n    runs-on: ubuntu-26.04\n  }\n' > "$WF/mljob.yml"
disco main
eq "${ ctx; }" '' "a wrapped inline job carrying a name: is skipped, not required under its key"
has "$ERR" "skipping job named" "...by name"

# (c) MERGE KEYS. GitHub Actions ships YAML 1.2, which has no `<<:`, so a workflow carrying one is a
#     syntax error there and never runs. `<<:` was read as an ordinary property and ignored, so the
#     job was required under its key — a context that never reports, from a file that never runs.
#     RESOLVING the merge would have been worse: the job gains a readable `name:` and no
#     disqualifier, so discovery would require it MORE confidently.
#     THE VERDICT IS FILE-WIDE, NOT PER-JOB, and the first cut of this fixture asserted the bug as
#     correct: it required `Base Name` — the ANCHOR job — from a file GitHub cannot parse. One merge
#     key stops the WHOLE workflow running, so every job in it is unreportable; skipping only the
#     merging job recreates the phantom one job over. Found by independent review.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  base: &base\n    name: Base Name\n    runs-on: ubuntu-26.04\n  alt:\n    <<: *base\n' > "$WF/mergekey.yml"
disco main
eq "${ ctx; }" '' "ONE merge key disqualifies EVERY job in the file, including the anchor job"
hasnt "${ ctx; }" 'Base Name' "...so the anchor's name never becomes a required context"
hasnt "${ ctx; }" 'alt'       "...and neither does the merging job's key"
has "$ERR" "skipping job base" "both jobs are skipped by name..."
has "$ERR" "skipping job alt"  "...the merging one included"
has "$ERR" "the whole file does not run" "...naming the file-wide reason"

#     A file with a merge key must not poison a DIFFERENT file. The verdict is per workflow file, so
#     a sibling workflow with no merge key keeps its contexts.
printf 'name: Clean\non:\n  pull_request:\njobs:\n  untouched:\n    runs-on: ubuntu-26.04\n' > "$WF/clean.yml"
disco main
eq "${ ctx; }" 'untouched|' "a merge key in ONE file leaves a sibling workflow's jobs required"

#     The INLINE spellings, which the block arms missed entirely.
wf_reset
printf 'on:\n  pull_request:\njobs:\n  alt: {<<: *base, runs-on: ubuntu-26.04}\n' > "$WF/mergeinline.yml"
disco main
eq "${ ctx; }" '' "an INLINE job mapping carrying <<: is not required under its key"
wf_reset
printf 'on:\n  pull_request: {<<: *filters}\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/mergeoninline.yml"
disco main
eq "${ ctx; }" '' "an INLINE trigger mapping carrying <<: refuses the file, not reads as unfiltered"

#     The trigger-level spelling: ignored, it left the trigger looking unfiltered, which is what
#     made every job in the file required.
wf_reset
printf 'on:\n  pull_request:\n    <<: *filters\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/mergeon.yml"
disco main
eq "${ ctx; }" '' "a <<: under pull_request refuses the whole file rather than reading as unfiltered"
has "$ERR" "does not support" "...naming the unsupported syntax"

# ============================ #102: fail loud, never a silent clean scan ============================
# "This repo has no CI" (#24, legitimate, exit 0) and "this parser went blind" (a failure) used to
# be the same observable. Every workflow has an `on:` key and a `jobs:` block with at least one job
# in it — those facts are what make the file a workflow — so a violation is never a legitimate
# shape, only a read that failed.
wf_reset
printf 'name: CI\non:\n  pull_request:\njobs:\n' > "$WF/empty.yml"
disco main
no "$RC_" "a jobs: block that yielded NO jobs is a hard failure, not an empty scan"
has "$ERR" "always a parse failure" "...and the diagnostic says why that combination can never be legitimate"
has "$ERR" "empty.yml" "...and names WHICH file"
eq "${ ctx; }" '' "a failed scan contributes no contexts"

wf_reset
printf 'name: CI\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/noon.yml"
disco main
no "$RC_" "a file with no on: block at all is a hard failure"
has "$ERR" "no on: block" "...and the diagnostic names the missing block"

# PER FILE, not just in total — the same fail-open shape the floor lint's rule 4 closes. A second
# file going blind is free the moment a first one still parses.
wf_reset
printf 'name: Good\non:\n  pull_request:\njobs:\n  good:\n    runs-on: ubuntu-26.04\n' > "$WF/good.yml"
printf 'name: Bad\non:\n  pull_request:\njobs:\n' > "$WF/bad.yml"
disco main
no "$RC_" "a jobless SECOND file fails the run even though the first file parsed fine"
has "$ERR" "bad.yml" "...and names the file that failed"
has "${ ctx; }" 'good|' "...while the file that DID parse still contributes its context"

# THE STRUCTURAL CHECK RUNS ON SKIPPED FILES TOO. A file skipped as "no pull_request trigger" is
# exactly what a blind trigger parse looks like, so checking only the files that PASSED would leave
# #102's own shape unexamined — the check would be absent from precisely the case it exists for.
wf_reset
printf 'name: P\non: push\njobs:\n' > "$WF/pushonly.yml"
disco main
no "$RC_" "a file the verdict SKIPS is still structurally checked"

# ...and a legitimately skipped file that IS well-formed still exits 0, or the rule above would
# fail every repo carrying a schedule-only or push-only workflow.
wf_reset
printf 'name: P\non: push\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$WF/pushok.yml"
disco main
yes "$RC_" "a well-formed push-only workflow is skipped WITHOUT failing the run"
eq "${ ctx; }" '' "...and contributes nothing"
has "$ERR" "no pull_request trigger" "...for the documented reason"

# ============================ gh-backed behavior (recording stub) ============================
S="$work/stub"; mkdir -p "$S"
SBIN="$work/sbin"; mkdir -p "$SBIN"

cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Recording gh stub: answers reads from $S fixtures, appends every mutation to $STUB_CALLS, and
# captures a --input body to $S/body.json. STUB_AUTH_FAIL=1 turns it into the unauthenticated
# stub; STUB_FAIL_WRITE=<substring> makes a matching mutation fail (to prove the load-bearing
# order: a failed checks write must NOT be followed by the auto-merge write).
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
case "${1:-}" in
  auth) exit 0 ;;
  repo) printf '%s\n' "acme/widget"; exit 0 ;;
  api)  ;;
  *)    exit 0 ;;
esac
url=""; method="GET"; has_input=0; want_headers=0; prev=""
for a in "$@"; do
  case "$a" in
    repos/*)              [ -z "$url" ] && url="$a" ;;
    PATCH|PUT|POST|DELETE) [ "$prev" = "-X" ] && method="$a" ;;
    -i|--include)         want_headers=1 ;;
    -)                    [ "$prev" = "--input" ] && has_input=1 ;;
  esac
  prev="$a"
done
# EVERY api call is recorded here, reads included — $STUB_CALLS deliberately records only
# mutations, and #218 needs to assert that a REQUEST was never issued at all. Separate file, opt-in
# via the env var, so no existing `calls_of` assertion changes.
[ -n "${STUB_READS:-}" ] && printf '%s %s\n' "$method" "$url" >> "$STUB_READS"
# `gh api -i` prefixes the response with its status line + headers, then a blank line. The library
# parses that status to tell a real 404 from a transient failure, so the stub must reproduce it.
emit() {   # <status-line> [<file>]
  if [ "$want_headers" = "1" ]; then printf '%s\r\n' "$1"; printf 'Content-Type: application/json\r\n'; printf '\r\n'; fi
  [ -n "${2:-}" ] && cat "$2"
  return 0
}
if [ "$method" = "GET" ]; then
  case "$url" in
    */protection)
      if [ -f "$S/protection.json" ]; then emit "HTTP/2.0 200 OK" "$S/protection.json"
      else emit "HTTP/2.0 404 Not Found"; [ "$want_headers" = "1" ] || exit 1; fi ;;
    # Check runs on a ref (#122): who PRODUCED each required context. Must precede `repos/*` for
    # the same reason as the branch arm. An absent fixture answers with an empty check_runs list,
    # which is a legitimate state ("Actions reported nothing here"), not an error.
    */check-runs*)
      if [ "${STUB_CHECKRUNS_STATUS:-200}" != "200" ]; then
        emit "HTTP/2.0 ${STUB_CHECKRUNS_STATUS} Error"; exit 1
      elif [ -f "$S/checkruns.json" ]; then emit "HTTP/2.0 200 OK" "$S/checkruns.json"
      else emit "HTTP/2.0 200 OK" /dev/null; printf '{"check_runs":[]}'; fi ;;
    # The ordinary branch endpoint (#122) — must be matched BEFORE the generic `repos/*` arm, or
    # it would be answered with the REPO object and every drift assertion would read nonsense.
    # It sits after */protection so the more specific protection URL still wins.
    */branches/*)
      if [ "${STUB_BRANCH_STATUS:-200}" != "200" ]; then
        emit "HTTP/2.0 ${STUB_BRANCH_STATUS} Error"; [ "$want_headers" = "1" ] || exit 1
      elif [ -f "$S/branch.json" ]; then emit "HTTP/2.0 200 OK" "$S/branch.json"
      else emit "HTTP/2.0 404 Not Found"; [ "$want_headers" = "1" ] || exit 1; fi ;;
    repos/*)
      if [ -f "$S/repo.json" ]; then emit "HTTP/2.0 200 OK" "$S/repo.json"
      else emit "HTTP/2.0 404 Not Found"; [ "$want_headers" = "1" ] || exit 1; fi ;;
  esac
  exit 0
fi
# Always DRAIN a piped body before deciding anything, so the writer never takes SIGPIPE and the
# recorded outcome reflects the library's intent rather than a broken pipe.
[ "$has_input" = "1" ] && cat > "$S/body.json"
if [ -n "${STUB_FAIL_WRITE:-}" ]; then
  case "$url" in *"$STUB_FAIL_WRITE"*) printf '%s %s FAILED\n' "$method" "$url" >> "$STUB_CALLS"; exit 1 ;; esac
fi
printf '%s %s\n' "$method" "$url" >> "$STUB_CALLS"
exit 0
STUB
chmod +x "$SBIN/gh"

# Fixture writers. Every scenario calls one of these, and each scenario re-writes what it needs,
# so no test inherits a previous test's fixture.
repo_fx() {   # <admin> <allow_auto_merge>
  printf '{"full_name":"acme/widget","default_branch":"main","allow_auto_merge":%s,"permissions":{"admin":%s}}\n' "$2" "$1" > "$S/repo.json"
}
repo_fx_noperms() { printf '{"full_name":"acme/widget","default_branch":"main","allow_auto_merge":false}\n' > "$S/repo.json"; }
prot_none()  { rm -f "$S/protection.json"; }
prot_checks() {   # protected, WITH required_status_checks (one arg per context)
  # --args, not word-splitting: a context name legitimately contains "/" and spaces.
  jq -n --args '{required_status_checks:{strict:false,contexts:$ARGS.positional},
                 required_conversation_resolution:{enabled:true}}' "$@" > "$S/protection.json"
}
prot_nochecks() {   # protected, NO required_status_checks — this repo's real starting state
  cat > "$S/protection.json" <<'JSON'
{"required_pull_request_reviews":{"dismiss_stale_reviews":false,"require_code_owner_reviews":false,
 "require_last_push_approval":false,"required_approving_review_count":0},
 "enforce_admins":{"enabled":false},"required_linear_history":{"enabled":false},
 "allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},
 "block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":true},
 "lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}
JSON
}

# One PR-triggered job, so discovery yields exactly one context in the gh-backed scenarios.
wf_one() { wf_reset; printf 'name: One\non:\n  pull_request:\njobs:\n  one:\n    runs-on: ubuntu-latest\n' > "$WF/one.yml"; }
wf_none() { wf_reset; }
wf_two() { wf_one; printf 'name: Two\non:\n  pull_request:\njobs:\n  two:\n    runs-on: ubuntu-latest\n' > "$WF/two.yml"; }

rsx_stub() {   # run against the stub with a fresh call log
  STUB_CALLS="$work/calls.txt"; : > "$STUB_CALLS"
  STUB_READS="$work/reads.txt"; : > "$STUB_READS"
  rm -f "$S/body.json"
  OUT="$(S="$S" STUB_CALLS="$STUB_CALLS" STUB_READS="$STUB_READS" STUB_FAIL_WRITE="${STUB_FAIL_WRITE:-}" \
         STUB_BRANCH_STATUS="${STUB_BRANCH_STATUS:-}" \
         STUB_CHECKRUNS_STATUS="${STUB_CHECKRUNS_STATUS:-}" \
         PATH="$SBIN:$PATH" bash "$RS" "$@" --workflow-dir "$WF" 2>&1)"; RC_=$?
}

# --- branch-endpoint fixtures (#122) ----------------------------------------------------------
# The ordinary endpoint's shape is NOT the protection endpoint's: contexts hang off
# `.protection.required_status_checks`, and it reports `.protected` for the branch as a whole.
branch_checks() {   # protected, contexts readable (one arg per context)
  jq -n --args '{protected:true,
                 protection:{enabled:true,
                             required_status_checks:{enforcement_level:"non_admins",
                                                     contexts:$ARGS.positional}}}' "$@" > "$S/branch.json"
}
branch_unprotected() { printf '{"protected":false}\n' > "$S/branch.json"; }
# A RULESET-protected branch, verbatim from the live shape github/docs and vercel/next.js return.
# `contexts` is a real (empty) array, so an array-only test would accept it as "requires nothing"
# and name every discovered job — a repo-wide false 14, and a deadlock when the job printing it is
# itself required. `enabled:false` is the discriminator.
branch_ruleset()     { printf '{"protected":true,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' > "$S/branch.json"; }
# The DANGEROUS shape: protected, but the protection block carries no readable context list (a
# redacted response, or an API shape change). Misread as "zero required" it names every discovered
# job as drifted — a repo-wide false positive. It must fail closed instead.
branch_opaque()      { printf '{"protected":true,"protection":{"enabled":true}}\n' > "$S/branch.json"; }
branch_malformed()   { printf 'not json at all\n' > "$S/branch.json"; }

# Check-run fixtures: `app.slug` is the provenance discriminator, and it is TRI-state (#179).
# `github-actions` IS GitHub Actions — read from its one home rather than restated, because the
# hard-coded `github` that used to sit here matched the library's equally wrong literal, so these
# tests passed while `_adb_rs_actions_contexts` returned nothing on every real repo. Any other
# non-empty slug is an external provider whose contexts this lint disclaims; a NULL app is
# unattributable, which is neither, and must fail closed rather than pass as "somebody else's".
check_actions_slug
checkruns_none()     { rm -f "$S/checkruns.json"; }
# checkruns_slug <slug> <name…> — the one builder; the named wrappers below just fix the slug, so
# the envelope and the fixture path are spelled once.
checkruns_slug()     { local s="$1"; shift; jq -n --args --arg s "$s" '{check_runs: [$ARGS.positional[] | {name: ., app: {slug: $s}}]}' "$@" > "$S/checkruns.json"; }
checkruns_actions()  { checkruns_slug "$ACTIONS_SLUG" "$@"; }
checkruns_external() { checkruns_slug circleci "$@"; }
# `app` is required-but-NULLABLE in the GitHub REST schema, so this is a real response shape.
checkruns_noapp()    { jq -n --args '{check_runs: [$ARGS.positional[] | {name: ., app: null}]}' "$@" > "$S/checkruns.json"; }
rsx_auth() {   # the SAME stub, auth knob flipped — one stub, two behaviors
  OUT="$(S="$S" STUB_AUTH_FAIL=1 PATH="$SBIN:$PATH" bash "$RS" "$@" --workflow-dir "$WF" 2>&1)"; RC_=$?
}
# `LC_ALL=C` for the same reason `reads_of` carries it (see its note near the #103 section): a log
# line can hold bytes that are not valid UTF-8, and `tr` then fails and truncates rather than
# passing them through — quietly weakening every assertion that reads the result.
calls_of() { LC_ALL=C tr '\n' '|' < "$STUB_CALLS"; }

# --- fail-loud gh guard -----------------------------------------------------------------------
wf_one; repo_fx true false; prot_nochecks
rsx_auth apply;        no "$RC_" "apply with unauthenticated gh exits nonzero";        has "$OUT" "not authenticated" "apply surfaces the auth failure"
rsx_auth status;       no "$RC_" "status with unauthenticated gh exits nonzero";       has "$OUT" "not authenticated" "status surfaces the auth failure"
rsx_auth automerge-ok; no "$RC_" "automerge-ok with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "automerge-ok surfaces the auth failure"
rsx_auth required-drift; no "$RC_" "required-drift with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "required-drift surfaces the auth failure"

# --- endpoint selection: the narrow PATCH when a status-check sub-resource exists --------------
wf_one; repo_fx true false; prot_checks "stale-name"
rsx_stub apply
yes "$RC_" "apply succeeds against a branch that already has required checks"
eq "${ calls_of; }" 'PATCH repos/acme/widget/branches/main/protection/required_status_checks|PATCH repos/acme/widget|' \
  "protected-with-checks -> narrow PATCH on the sub-resource, THEN the auto-merge PATCH"
has "$OUT" "nothing else touched" "the narrow path says it cannot lose other settings"
eq "$(jq -r '.contexts|sort|join(",")' "$S/body.json")" "one,stale-name" \
  "the PATCH body ADDS the discovered context and keeps the undiscovered one (see --prune below)"
eq "$(jq -r '.strict' "$S/body.json")" "false" "strict defaults off (see D9)"

# --- endpoint selection: read-modify-write PUT when protection exists WITHOUT checks -----------
# This is the destructive-endpoint case. A naive PUT drops required_conversation_resolution and
# required_pull_request_reviews; both must survive, rebuilt from the live object.
wf_one; repo_fx true false; prot_nochecks
rsx_stub apply
yes "$RC_" "apply succeeds against a protected branch that has no required checks"
eq "${ calls_of; }" 'PUT repos/acme/widget/branches/main/protection|PATCH repos/acme/widget|' \
  "protected-no-checks -> full protection PUT, THEN the auto-merge PATCH"
has "$OUT" "read-modify-write" "the wide path says it is preserving the existing object"
eq "$(jq -r '.required_conversation_resolution' "$S/body.json")" "true" \
  "the PUT body PRESERVES required_conversation_resolution (a naive PUT would reset it to false)"
eq "$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$S/body.json")" "0" \
  "the PUT body PRESERVES 'require a PR before merging' (omitting it removes the guardrail)"
eq "$(jq -r '.allow_force_pushes' "$S/body.json")" "false" "the PUT body preserves allow_force_pushes"
eq "$(jq -r '.allow_deletions' "$S/body.json")"    "false" "the PUT body preserves allow_deletions"
eq "$(jq -r '.enforce_admins' "$S/body.json")"     "false" "enforce_admins is preserved, never silently flipped"
eq "$(jq -r '.required_status_checks.contexts|join(",")' "$S/body.json")" "one" "the PUT body carries the discovered contexts"

# An external provider's required context must SURVIVE apply — deleting it is silent damage, and
# this tool only ever discovers GitHub Actions jobs.
wf_one; repo_fx true false; prot_checks "one" "codecov/patch"
rsx_stub apply
eq "$(jq -r '.contexts|sort|join(",")' "$S/body.json")" "codecov/patch,one" \
  "apply KEEPS a required context it did not discover (an external provider is not deleted)"
has "$OUT" "did not discover" "apply reports the contexts it kept"

# --prune is the remedy for a genuinely stale context (a renamed or deleted job).
wf_one; repo_fx true false; prot_checks "one" "stale-name"
rsx_stub apply --prune
eq "$(jq -r '.contexts|sort|join(",")' "$S/body.json")" "one" "--prune drops an undiscovered context"
has "$OUT" "dropping" "--prune says what it removed"

# --enforce-admins must not be a silent no-op on the narrow PATCH path — the state a repo is in
# after its first successful apply.
wf_one; repo_fx true false; prot_checks "one"
rsx_stub apply --enforce-admins
has "${ calls_of; }" "POST repos/acme/widget/branches/main/protection/enforce_admins" \
  "--enforce-admins is honored on the PATCH path via its own endpoint"

# The read-modify-write PUT must preserve EVERY protection sub-object. Dropping
# dismissal_restrictions silently turns off "restrict who can dismiss reviews".
wf_one; repo_fx true false
cat > "$S/protection.json" <<'JSON'
{"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":false,
  "require_last_push_approval":false,"required_approving_review_count":1,
  "dismissal_restrictions":{"users":[{"login":"octocat"}],"teams":[{"slug":"core"}],"apps":[]},
  "bypass_pull_request_allowances":{"users":[],"teams":[],"apps":[{"slug":"dependabot"}]}},
 "enforce_admins":{"enabled":false},"required_conversation_resolution":{"enabled":true},
 "allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}
JSON
rsx_stub apply
eq "$(jq -r '.required_pull_request_reviews.dismissal_restrictions.users|join(",")' "$S/body.json")" "octocat" \
  "the PUT preserves dismissal_restrictions.users (dropping it would let anyone dismiss reviews)"
eq "$(jq -r '.required_pull_request_reviews.dismissal_restrictions.teams|join(",")' "$S/body.json")" "core" \
  "the PUT preserves dismissal_restrictions.teams"
eq "$(jq -r '.required_pull_request_reviews.bypass_pull_request_allowances.apps|join(",")' "$S/body.json")" "dependabot" \
  "the PUT preserves bypass_pull_request_allowances (dropping it breaks release automation)"
eq "$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$S/body.json")" "1" \
  "the PUT preserves a non-default approving-review count"

# --strict is the explicit opt-in for "require branches up to date" (D9 defaults it off).
rsx_stub apply --strict
eq "$(jq -r '.required_status_checks.strict' "$S/body.json")" "true" "--strict opts in explicitly"

# --enforce-admins is the explicit opt-in for removing the owner's break-glass.
rsx_stub apply --enforce-admins
eq "$(jq -r '.enforce_admins' "$S/body.json")" "true" "--enforce-admins opts in explicitly"

# --- endpoint selection: standing protection up from scratch ----------------------------------
wf_one; repo_fx true false; prot_none
rsx_stub apply
yes "$RC_" "apply succeeds on an unprotected branch (admin can see it is genuinely unprotected)"
eq "${ calls_of; }" 'PUT repos/acme/widget/branches/main/protection|PATCH repos/acme/widget|' \
  "unprotected -> PUT standing protection up, THEN the auto-merge PATCH"
eq "$(jq -r '.required_conversation_resolution' "$S/body.json")" "true" "a fresh stand-up turns thread resolution on"
eq "$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$S/body.json")" "0" \
  "a fresh stand-up requires a PR but invents no approval requirement"

# --- THE load-bearing order: a failed checks write must not enable auto-merge ------------------
wf_one; repo_fx true false; prot_nochecks
STUB_FAIL_WRITE="protection" rsx_stub apply
no "$RC_" "a failed required-checks write makes apply exit nonzero"
eq "${ calls_of; }" 'PUT repos/acme/widget/branches/main/protection FAILED|' \
  "the auto-merge write is NEVER reached when the checks write fails (order is load-bearing)"
has "$OUT" "refusing to enable auto-merge" "the refusal says why"
STUB_FAIL_WRITE=""

# --- non-admin degrades to instructions, and writes NOTHING -----------------------------------
wf_one; repo_fx false false; prot_nochecks
rsx_stub apply
no "$RC_" "a non-admin apply exits nonzero"
eq "${ calls_of; }" "" "a non-admin apply performs NO writes (the permission probe runs before any write)"
has "$OUT" "No admin permission" "the non-admin path names the problem"
has "$OUT" "required checks FIRST" "the manual instructions state the load-bearing order"

# --- dry-run changes nothing ------------------------------------------------------------------
wf_one; repo_fx true false; prot_nochecks
rsx_stub apply --dry-run
yes "$RC_" "apply --dry-run exits 0"
eq "${ calls_of; }" "" "apply --dry-run performs NO mutations"
has "$OUT" "would set required checks" "dry-run prints the write it would do"
has "$OUT" "Dry run — nothing was changed" "dry-run says it changed nothing"

# --- no CI: skip the checks write, do NOT block (#24) -----------------------------------------
wf_none; repo_fx true false; prot_none
rsx_stub apply
yes "$RC_" "apply on a repo with no CI still succeeds (it must not block)"
eq "${ calls_of; }" 'PATCH repos/acme/widget|' "no CI -> the checks write is skipped, auto-merge is still enabled"
has "$OUT" "SKIPPED (no PR-triggered CI" "the no-CI path says the checks write was skipped"

# --- already-enabled auto-merge is not re-written ---------------------------------------------
wf_one; repo_fx true true; prot_checks "one"
rsx_stub apply
eq "${ calls_of; }" 'PATCH repos/acme/widget/branches/main/protection/required_status_checks|' \
  "an already-enabled allow_auto_merge is not written again"
has "$OUT" "already enabled" "apply reports auto-merge was already on"

# ============================ status: drift, both directions ============================
wf_one; repo_fx true true; prot_checks "one"
rsx_stub status
yes "$RC_" "status exits 0 when live == discovered and auto-merge is on"
has "$OUT" "in sync" "an in-sync repo says so"

wf_one; repo_fx true true; prot_checks "stale-name"
rsx_stub status
no "$RC_" "status exits nonzero on drift"
has "$OUT" "discovered but NOT required" "status names the ungated job"
has "$OUT" "required but NOT discovered" "status names the phantom context"
has "$OUT" "block every PR" "status explains that a phantom context deadlocks every PR"
has "$OUT" "stale-name" "status names the stale context by name"

# The renamed-job case the issue calls out: discovery follows the rename, the live set does not.
wf_one; repo_fx true true; prot_none
rsx_stub status
no "$RC_" "status exits nonzero when nothing is required at all"

wf_one; repo_fx true false; prot_checks "one"
rsx_stub status
no "$RC_" "status exits nonzero when allow_auto_merge is off"
has "$OUT" "allow_auto_merge is off" "status names the disabled auto-merge"

# ============================ automerge-ok: the decision table ============================
# Exit codes are a machine contract consumed by the workflow's step 10, so each is pinned.
wf_one; repo_fx true true; prot_checks "one"
rsx_stub automerge-ok
eq "$RC_" "0" "automerge-ok = 0 when auto-merge is on AND the required checks are satisfiable"

# The guard must be no shallower than `status`, in BOTH drift directions — `status` reports both,
# so a guard that checked only one would contradict it.
#
# 13: a required context nothing reports (the renamed-job case). The live set is a SUPERSET of
# discovery, so this direction is isolated from 14 below.
wf_one; repo_fx true true; prot_checks "one" "stale-name"
rsx_stub automerge-ok
eq "$RC_" "13" "automerge-ok = 13 when a required context no workflow reports (renamed job)"
has "$OUT" "wait for them forever" "code 13 explains that an armed PR would hang"
has "$OUT" "stale-name" "code 13 names the phantom context"

# 14: a discovered job that is NOT required gates nothing, so auto-merge could land a red build —
# the exact hole #87 exists to close. Live is a SUBSET of discovery here.
wf_two; repo_fx true true; prot_checks "one"
rsx_stub automerge-ok
eq "$RC_" "14" "automerge-ok = 14 when a discovered job is not required (auto-merge could land red)"
has "$OUT" "NOT required" "code 14 explains the ungated direction"
has "$OUT" "two" "code 14 names the ungated job"

wf_one; repo_fx true false; prot_checks "one"
rsx_stub automerge-ok
eq "$RC_" "10" "automerge-ok = 10 when allow_auto_merge is off"
has "$OUT" "allow_auto_merge is off" "code 10 explains itself"

wf_one; repo_fx true true; prot_nochecks
rsx_stub automerge-ok
eq "$RC_" "11" "automerge-ok = 11 when CI exists but nothing is required"
has "$OUT" "would gate nothing" "code 11 explains that arming would gate nothing"

wf_none; repo_fx true true; prot_nochecks
rsx_stub automerge-ok
eq "$RC_" "12" "automerge-ok = 12 when the repo has no PR-triggered CI"
has "$OUT" "merge immediately" "code 12 explains that --auto would merge immediately"

# Fail CLOSED: an unreadable protection state is 20, never 0. `permissions` absent from the repo
# object makes the 404 ambiguous — exactly the case that must not be read as "unprotected".
wf_one; repo_fx_noperms; prot_none
rsx_stub automerge-ok
eq "$RC_" "20" "automerge-ok = 20 (fail closed) when protection cannot be read"
has "$OUT" "refusing to arm" "code 20 refuses rather than assuming safe"

# ============================ required-drift: the EARLY half of code 14 (#122) ============
# `automerge-ok` learns this at merge time; this learns it as soon as the job reaches the default
# branch. (Until #165 it learned it on the PR that introduced the job — earlier, but only greenable
# by requiring a context before the job existed anywhere, which is the trap D48 removes. The PR now
# gets the same finding as advice; see the wiring assertions at the end of this file.) The
# assertions below are grouped by the two ways it can be wrong, because they are NOT symmetric:
# missing a real drift costs one ungated job, while a FALSE drift fails every PR in the repo and
# teaches the operator to ignore the lint.

# --- the happy paths ---------------------------------------------------------------------------
wf_one; repo_fx true true; branch_checks "one"
rsx_stub required-drift
eq "$RC_" "0" "required-drift = 0 when every discovered job is required"
has "$OUT" "no drift" "the in-sync run says so plainly"

# It must NOT need admin: its home is a CI job running as GITHUB_TOKEN, which cannot hold admin.
# `repo_fx_noperms` has no `.permissions` key at all — the shape a non-admin token sees.
wf_one; repo_fx_noperms; branch_checks "one"
rsx_stub required-drift
eq "$RC_" "0" "required-drift = 0 without admin permission (it reads the contents-scoped endpoint)"

# #24: a repo with no discoverable CI has nothing to require. It must pass, not deadlock.
wf_none; repo_fx true true; branch_unprotected
rsx_stub required-drift
eq "$RC_" "0" "required-drift = 0 on a repo with no discoverable CI (#24)"
has "$OUT" "nothing to require" "the no-CI run names why it passed"

# Entirely-external CI: no workflow files at all, but the branch requires contexts (CircleCI,
# Vercel, a DCO check). No files means no claim to contradict, so this must PASS — it is the case
# that keeps the contradiction check below from firing on a legitimate configuration.
wf_none; repo_fx true true; branch_checks "ci/circleci: build" "vercel"
rsx_stub required-drift
eq "$RC_" "0" "required-drift = 0 when CI is entirely external (no workflow files)"
has "$OUT" "nothing to require" "the external-CI run passes for the no-files reason"

# #24, pinned structurally rather than by message: with no workflow files the branch is never
# read, so even an outright HTTP 500 cannot deadlock a repo that has no CI to check. If this ever
# returns 20, the short-circuit moved below the live read.
wf_none; repo_fx true true; branch_checks "one"
STUB_BRANCH_STATUS=500 rsx_stub required-drift
eq "$RC_" "0" "a no-CI repo is not deadlocked by an unreadable branch (the read is skipped)"

# Context names legitimately carry spaces and slashes (a job `name:` is free text). Comparing them
# as whole lines is what keeps that from splitting into phantom drift.
wf_reset
printf 'name: Odd\non:\n  pull_request:\njobs:\n  a:\n    name: build / unit (fast)\n    runs-on: ubuntu-latest\n' > "$WF/odd.yml"
repo_fx true true; branch_checks "build / unit (fast)"
rsx_stub required-drift
eq "$RC_" "0" "a context with spaces and slashes matches exactly, not as split words"
# rc 0 alone would ALSO pass if discovery stopped emitting the job entirely (the no-CI arm returns
# 0 too), so pin the reason — otherwise this assertion survives the very regression it guards.
has "$OUT" "no drift" "...and it passed by MATCHING, not by discovering nothing"

# --- real drift --------------------------------------------------------------------------------
wf_two; repo_fx true true; branch_checks "one"
rsx_stub required-drift
eq "$RC_" "14" "required-drift = 14 when a discovered job is not required"
has "$OUT" "  - two"  "the drifted job is NAMED"
hasnt "$OUT" "  - one" "a job that IS required is not reported as drifted"
has "$OUT" "baseline repo apply" "the message carries the one-command remedy"
has "$OUT" "RENAMED" "the message distinguishes an addition from a rename (--prune is a different fix)"
has "$OUT" "RE-RUN" "the message says to re-run after applying — live state, not a flaky retry"

# Every discovered job ungated at once: a protected branch whose context list is genuinely empty.
wf_two; repo_fx true true; branch_checks
rsx_stub required-drift
eq "$RC_" "14" "required-drift = 14 when a protected branch requires nothing at all"
has "$OUT" "  - one" "both drifted jobs are named (1/2)"
has "$OUT" "  - two" "both drifted jobs are named (2/2)"

# An unprotected branch is an AUTHORITATIVE "nothing gates this" — real drift, not an unknown.
wf_one; repo_fx true true; branch_unprotected
rsx_stub required-drift
eq "$RC_" "14" "required-drift = 14 when the branch has no protection at all"
has "$OUT" "NO protection" "the unprotected case says the branch itself is unprotected"

# --- fail closed: an unreadable answer is 20, and NEVER 'everything drifted' -------------------
# The headline false-positive guard. Protected + no readable context list must not be read as
# "zero required" — that would name every discovered job and fail every PR in the repo.
wf_two; repo_fx true true; branch_opaque
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 when protection is present but its context list is unreadable"
hasnt "$OUT" "  - one" "an opaque read does NOT label a required job as drifted (1/2)"
hasnt "$OUT" "  - two" "an opaque read does NOT label a required job as drifted (2/2)"
has "$OUT" "NOT an empty one" "the opaque case explains why it refuses to guess"

wf_two; repo_fx true true; branch_malformed
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 on a malformed response body"
hasnt "$OUT" "  - two" "a malformed body does not manufacture drift"

# The RULESET regression. `contexts` is a real empty array here, so the array-only test this
# replaced accepted it as "requires nothing" and named every discovered job — on a repo whose own
# required `repo-settings` job prints that, an unbreakable deadlock. Must be opaque -> 20.
wf_two; repo_fx true true; branch_ruleset
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 on a ruleset-protected branch (legacy block disabled)"
hasnt "$OUT" "  - one" "a ruleset branch does NOT report every job as ungated (1/2)"
hasnt "$OUT" "  - two" "a ruleset branch does NOT report every job as ungated (2/2)"

# Files present + discovery empty + contexts required is only a contradiction when PROVENANCE
# says so. These three cases are the whole rule, and the middle one is the regression that
# matters: a schedule-only workflow beside external CI is a legitimate configuration, and failing
# it would contradict this command's own documented exclusion of external-provider contexts —
# permanently red, on a repo with no drift at all.
wf_reset
printf 'name: Sched\non:\n  schedule:\n    - cron: "0 0 * * *"\njobs:\n  nightly:\n    runs-on: ubuntu-latest\n' > "$WF/sched.yml"

# (a) the required contexts ARE Actions-reported -> they came from a workflow in this tree, so
#     discovery finding none of them means the parser went blind. Fail closed.
repo_fx true true; branch_checks "one" "two"; checkruns_actions "one" "two"
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 when discovery is empty but Actions reported the required contexts"
has "$OUT" "cannot both be right" "the contradiction is named, not silently passed"
has "$OUT" "  - one" "the Actions-reported context is named"

# (b) the required contexts are EXTERNAL (CircleCI) -> none of this lint's business. Must pass,
#     or a legitimate schedule-only + external-CI repo is red forever.
repo_fx true true; branch_checks "ci/circleci: build"; checkruns_external "ci/circleci: build"
rsx_stub required-drift
eq "$RC_" "0" "required-drift = 0 when the required contexts are external-provider, not Actions"
has "$OUT" "external CI" "the pass names WHY it passed (provenance), not just that it passed"

# (c) provenance cannot be read at all -> refuse to pick a side.
repo_fx true true; branch_checks "one"; checkruns_actions "one"
STUB_CHECKRUNS_STATUS=500 rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 when the check runs that establish provenance cannot be read"
has "$OUT" "could not be read" "the unreadable-provenance case says so"
checkruns_none

# (c2) THE OTHER unreadable shape: `gh` exits 0 but the BODY is not JSON — a proxy or GHES error
# page served as 200, or a truncated --paginate stream. Case (c) only covers an HTTP failure, so
# nothing caught this: an unparseable body classifies as nothing at all, which is indistinguishable
# from "no Actions contexts" and lands on the fail-OPEN external-CI pass. Both the read AND the
# parse have to be checked, which is why the call site tests two statuses rather than one.
repo_fx true true; branch_checks "one"
printf 'not json at all\n' > "$S/checkruns.json"
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 when gh succeeds but the check-runs BODY is unparseable"
has "$OUT" "could not be read" "...and it reports unreadable provenance, not a clean external-CI pass"
hasnt "$OUT" "external CI" "...never the fail-open pass"

# A well-formed document of the WRONG SHAPE is the same class: `check_runs` absent or not an array
# means the response is not what this code models, so it cannot be reasoned about.
repo_fx true true; branch_checks "one"
printf '{"message":"Not Found"}\n' > "$S/checkruns.json"
rsx_stub required-drift
eq "$RC_" "20" "required-drift = 20 when the response carries no check_runs array"
checkruns_none

# The CONSISTENT version of that same state — files present, none PR-triggered, nothing required —
# is not a contradiction and must still pass. Without this, the check above could be over-broad.
repo_fx true true; branch_checks
rsx_stub required-drift
eq "$RC_" "0" "files present + discovery empty + nothing required is consistent, so it passes"

# (d) THE ATTRIBUTION ITSELF (#179). Case (a) above proves the contradiction is caught *given* that
#     Actions check runs are recognized — but it drove `checkruns_actions`, and both the fixture and
#     the library said `github`, a slug GitHub never stamps. Two wrongs agreeing is a green suite
#     over a helper that returned NOTHING on every real repo, so case (a) silently degraded into
#     case (b): the fail-OPEN "external CI, nothing to require" pass, issued by the lint whose whole
#     job is catching a gate that stopped gating. Pin the real value here, once, explicitly.
repo_fx true true; branch_checks "one"
jq -n '{check_runs: [{name: "one", app: {slug: "github-actions"}}]}' > "$S/checkruns.json"
rsx_stub required-drift
eq "$RC_" "20" "an API-shaped Actions check run (slug github-actions) IS attributed to Actions (#179)"
has "$OUT" "cannot both be right" "...so the contradiction is still named, not passed over"

# The RETIRED literal must be treated as just another foreign app, or the bug returns by the door
# it left through.
repo_fx true true; branch_checks "one"
jq -n '{check_runs: [{name: "one", app: {slug: "github"}}]}' > "$S/checkruns.json"
rsx_stub required-drift
eq "$RC_" "0" "the retired literal 'github' is an external provider, not Actions"

# UNKNOWN provenance is the third state, and folding it into "external" is the fail-open this
# issue exists to close: `app` is nullable, so a required context nobody can attribute must hold
# the verdict rather than pass as somebody else's CI.
repo_fx true true; branch_checks "one"; checkruns_noapp "one"
rsx_stub required-drift
eq "$RC_" "20" "a required context whose producing app is NULL fails closed, never 'external CI'"
has "$OUT" "did not identify" "...and the unattributable context is named"

# ...but an unattributable check run that is NOT required is nobody's problem — the fail-closed arm
# must be scoped to the required set, or any stray null-app check would wedge every repo.
repo_fx true true; branch_checks "ci/circleci: build"
jq -n '{check_runs: [{name: "ci/circleci: build", app: {slug: "circleci"}}, {name: "stray", app: null}]}' > "$S/checkruns.json"
rsx_stub required-drift
eq "$RC_" "0" "an unattributable check run outside the required set does not hold the verdict"
checkruns_none

wf_two; repo_fx true true; branch_checks "one"
for st in 401 403 404 500; do
  STUB_BRANCH_STATUS="$st" rsx_stub required-drift
  eq "$RC_" "20" "required-drift = 20 on HTTP $st (fail closed)"
  hasnt "$OUT" "  - two" "HTTP $st does not manufacture drift"
done

# ============================ required-drift --porcelain (#165) ============
# The PR arm of the drift step softens code 14 into an advisory, and it needs the drifted NAMES
# without the code-14 prose — because that prose ends in `baseline repo apply`, which is the right
# remedy on the default branch and the WRONG one from a PR branch: applying there makes the context
# required before the job exists on the default branch, and an abandoned PR then leaves the branch
# requiring something nothing will ever report. An advisory that repeated it would hand the operator
# the exact hazard #165 removes. So the contract under test is "stdout is names, nothing else".
#
# STDOUT AND STDERR MUST BE READ SEPARATELY HERE, which `rsx_stub` cannot do — it merges them with
# `2>&1`, so under it a remedy line leaking onto stdout is indistinguishable from the same line on
# stderr, and this whole section would pass over the one defect it exists to catch.
rsx_stub_split() {   # like rsx_stub, but OUT = stdout only and ERR_ = stderr only
  STUB_CALLS="$work/calls.txt"; : > "$STUB_CALLS"
  rm -f "$S/body.json"
  OUT="$(S="$S" STUB_CALLS="$STUB_CALLS" STUB_FAIL_WRITE="${STUB_FAIL_WRITE:-}" \
         STUB_BRANCH_STATUS="${STUB_BRANCH_STATUS:-}" \
         STUB_CHECKRUNS_STATUS="${STUB_CHECKRUNS_STATUS:-}" \
         PATH="$SBIN:$PATH" bash "$RS" "$@" --workflow-dir "$WF" 2>"$work/err.txt")"; RC_=$?
  ERR_="$(cat "$work/err.txt")"
}

# The verdict is UNCHANGED — a different rendering, never a different answer. If porcelain ever
# returned 0 here, the advisory arm would report "no prospective drift" on a drifted tree.
wf_two; repo_fx true true; branch_checks "one"
rsx_stub_split required-drift --porcelain
eq "$RC_" "14" "--porcelain keeps the 14 verdict (a rendering, not a softer answer)"
eq "$OUT" "two" "--porcelain puts ONLY the drifted context name on stdout"
hasnt "$OUT" "repo-settings:" "no prose reaches stdout — a sentence there would arrive as a context name"
hasnt "$OUT" "baseline repo apply" "the branch-wrong remedy is NOT on stdout for a caller to echo"

# The remedy must not merely move to stderr in this mode either: CI logs stderr, so an advisory run
# that printed it would still tell the operator to apply from the PR branch.
hasnt "$ERR_" "baseline repo apply" "...and it is withheld from stderr too, not just from stdout"

# Two drifted jobs must arrive as two LINES, because the caller splices them into a list. A single
# joined line would render one bullet naming two jobs.
wf_two; repo_fx true true; branch_checks
rsx_stub_split required-drift --porcelain
eq "$RC_" "14" "--porcelain reports drift when the branch requires nothing at all"
eq "$OUT" "$(printf 'one\ntwo')" "every drifted job is its own line"

# THE IN-SYNC CASE IS THE ONE THAT SILENTLY BREAKS. `adb_info` prints to STDOUT, so without
# suppression the clean run emits "…no drift" there and the caller reads a context literally named
# `repo-settings: all 1 discovered job(s) are required…`. Empty stdout is the whole contract.
wf_one; repo_fx true true; branch_checks "one"
rsx_stub_split required-drift --porcelain
eq "$RC_" "0" "--porcelain still passes an in-sync repo"
eq "$OUT" "" "an in-sync run prints NOTHING on stdout (the info line would read as a context name)"

# Same trap, second door: the #24 no-CI arm has its own info line on the same stream.
wf_none; repo_fx true true; branch_unprotected
rsx_stub_split required-drift --porcelain
eq "$RC_" "0" "--porcelain still passes a repo with no discoverable CI (#24)"
eq "$OUT" "" "the no-CI info line is suppressed too"

# FAIL-CLOSED IS NOT SOFTENED. Only a proven 14 is a rendering choice; 20 means the state could not
# be read or contradicts itself, and porcelain must not turn that into an empty, reassuring list.
wf_two; repo_fx true true; branch_checks "one"
STUB_BRANCH_STATUS=500 rsx_stub_split required-drift --porcelain
eq "$RC_" "20" "--porcelain does NOT soften the fail-closed 20"
eq "$OUT" "" "a fail-closed run emits no names (an empty list must not read as 'no drift')"

# Without the flag, nothing changes — the human path is untouched by this feature.
wf_two; repo_fx true true; branch_checks "one"
rsx_stub required-drift
has "$OUT" "baseline repo apply" "the NON-porcelain path still carries the human remedy"

# SCOPED TO ONE SUBCOMMAND. An accepted-but-inert flag promises the output changed when it did not,
# which is the same "knob that does nothing" this file refuses for `branch-required-contexts
# --branch`. Symmetric with the apply-only options rejected above.
for sub in checks status automerge-ok merge-flag; do
  rsx_stub "$sub" --porcelain
  no "$RC_" "$sub rejects the drift-only --porcelain"
  has "$OUT" "only meaningful for 'required-drift'" "$sub says WHY --porcelain was rejected"
done

# ============================ merge-flag: the repo decides the method ============
# A hardcoded --squash is REJECTED wherever squash merging is disabled, so the guard would say
# "safe" and the merge command would still fail. Each method is independently configurable.
merge_fx() {   # <squash> <merge> <rebase>
  printf '{"full_name":"acme/widget","default_branch":"main","allow_auto_merge":true,
           "permissions":{"admin":true},"allow_squash_merge":%s,"allow_merge_commit":%s,
           "allow_rebase_merge":%s}\n' "$1" "$2" "$3" > "$S/repo.json"
}
merge_fx true true true;    rsx_stub merge-flag; eq "$OUT" "--squash" "merge-flag prefers --squash when it is enabled"
merge_fx false true true;   rsx_stub merge-flag; eq "$OUT" "--merge"  "merge-flag falls back to --merge when squash is disabled"
merge_fx false false true;  rsx_stub merge-flag; eq "$OUT" "--rebase" "merge-flag falls back to --rebase"
merge_fx false false false; rsx_stub merge-flag
eq "$RC_" "15" "merge-flag exits 15 when NO merge method is enabled"
has "$OUT" "cannot be merged at all" "the no-method case explains itself"

# ============ an API-supplied slug is refused before it reaches a request path (#218) ============
# THIS MODULE HAS ITS OWN PRODUCER BOUNDARY, which is the whole reason #218 was not a one-place
# fix. `adb_repo_slug` is the obvious chokepoint and this library does not use it: to save a round
# trip it takes the slug from `.full_name` of the repo object it already fetches, so hardening the
# shared getter reaches release-convention.sh and NOTHING here. Seven `repos/$REPO_SLUG/...` paths
# are built downstream and four of them are WRITES.
#
# `.full_name` is the injection seam, so that is where the bad value goes in — not into a
# hand-called predicate, which would prove only that the predicate works.
slug_fx() {   # <full_name> — an otherwise perfectly healthy repo object
  printf '{"full_name":"%s","default_branch":"main","allow_auto_merge":true,
           "permissions":{"admin":true},"allow_squash_merge":true}\n' "$1" > "$S/repo.json"
}
reads_for() { grep -c . < "$STUB_READS"; }

wf_one
for bad in 'acme/..' '../widget' 'acme/.' './widget' 'acme/widget/extra' 'acme' 'acme/wid get' 'acme/wid?et'; do
  slug_fx "$bad"
  prot_checks "one"
  rsx_stub automerge-ok
  # 20 SPECIFICALLY, not merely non-zero: this guard's codes are a machine contract that
  # /implement-issue step 10 switches on, and 20 is the one arm that means "unreadable, do not
  # arm". Any of 10-14 would send the operator to a remedy for a problem they do not have.
  eq "$RC_" "20" "automerge-ok = 20 (fail closed) when the API reports the slug '$bad'"
  has "$OUT" "malformed repository slug" "...saying why, for '$bad'"
  # THE GUARD PRECEDES THE REQUEST, and this is the assertion that proves it. A validation placed
  # AFTER the interpolation would satisfy every exit-code check above while the traversal had
  # already been sent. Exactly ONE api call is legitimate — the `repos/{owner}/{repo}` read the
  # slug itself comes from, whose path gh expands locally and which carries no slug of ours.
  eq "${ reads_for; }" "1" "...after exactly one request: the read the slug came from"
  hasnt "$(cat "$STUB_READS")" "$bad" "...and no request was built from '$bad'"
  eq "$(cat "$STUB_CALLS")" "" "...and nothing was mutated"
done

# The diagnostic NAMES the value, or the operator cannot act on it.
slug_fx 'acme/..'; prot_checks "one"; rsx_stub automerge-ok
has "$OUT" 'acme/..' "the diagnostic names the rejected slug"

# EACH SUBCOMMAND KEEPS ITS OWN MAPPING. `repo_json` returns 1 like every other failure there, so
# the guard commands turn it into 20 and the human-facing ones into 1 — the codes their contracts
# already define. A shared "return 20" in the producer would have given `apply` and `status` an
# exit code neither documents.
slug_fx 'acme/..'; prot_checks "one"
rsx_stub merge-flag;      eq "$RC_" "20" "merge-flag = 20 on a malformed slug (fail closed)"
has "$OUT" "malformed repository slug" "...for the slug, not some other unreadable state"
rsx_stub required-drift;  eq "$RC_" "20" "required-drift = 20 on a malformed slug (fail closed)"
has "$OUT" "malformed repository slug" "...for the slug, not some other unreadable state"
# The `has` on each of these two matters more than the code: 1 is also what a usage error exits
# with, so a bare `eq "$RC_" "1"` would stay green if the run never got as far as the slug.
rsx_stub status;          eq "$RC_" "1"  "status = 1 on a malformed slug — its own contract, not 20"
has "$OUT" "malformed repository slug" "...and status stopped BECAUSE of the slug"
rsx_stub apply;           eq "$RC_" "1"  "apply = 1 on a malformed slug — its own contract, not 20"
has "$OUT" "malformed repository slug" "...and apply stopped BECAUSE of the slug"
eq "$(cat "$STUB_CALLS")" "" "...and the WRITE path mutated nothing"

# ...but a repository whose NAME merely contains dots is a name, not a traversal. Over-rejecting it
# would make auto-merge permanently unarmable for a repo that was never dangerous — failure by
# availability rather than by safety, which is the kind that ships unnoticed.
slug_fx 'acme/api..client'; prot_checks "one"; wf_one
rsx_stub automerge-ok
eq "$RC_" "0" "a repository named 'api..client' still arms — dots are a name, not a traversal"

# THE CACHE ORDERING INSIDE repo_json IS PINNED STRUCTURALLY, and this test is deliberately a
# different KIND from the ones above — it reads source text, not behaviour. It has to be: every
# subcommand checks `repo_json`'s status on its FIRST call and bails, so a version that committed
# `REPO_JSON`/`REPO_SLUG` and validated afterwards passes every behavioural assertion in this file.
# Verified, not assumed: that exact reordering was run against this whole suite and it stayed green
# at 380/380.
#
# That is what makes the order worth pinning rather than worth dropping. Both globals are read
# through `[ -z … ]`, so the wrong order is a latent fail-open that arms the moment any caller
# re-calls after a failure — a change no reviewer would connect back to this function. A source pin
# is a weak test and is the only one available here, which is the honest reason to write it down.
rj="$(awk '/^repo_json\(\) \{/,/^\}/' "$RS")"
# ANCHORED, so only a real CALL counts. An unanchored match would also find the predicate's name in
# a comment, and a comment sitting above the assignments would let the pin pass while the actual
# call had moved below them — a guard defeated by prose, which is the failure mode a structural
# test is most prone to.
v_at="$(printf '%s\n' "$rj" | grep -nE '^[[:space:]]*adb_is_path_safe_repo_slug' | head -1 | cut -d: -f1)"
j_at="$(printf '%s\n' "$rj" | grep -nE '^[[:space:]]*REPO_JSON="' | head -1 | cut -d: -f1)"
s_at="$(printf '%s\n' "$rj" | grep -nE '^[[:space:]]*REPO_SLUG="' | head -1 | cut -d: -f1)"
if [ -n "$v_at" ] && [ -n "$j_at" ] && [ -n "$s_at" ] && [ "$v_at" -lt "$j_at" ] && [ "$v_at" -lt "$s_at" ]; then ok
else bad "repo_json must validate the slug BEFORE committing REPO_JSON/REPO_SLUG (validate@${v_at:-none} REPO_JSON@${j_at:-none} REPO_SLUG@${s_at:-none})"; fi

# ============================ drift guard: the workflow still calls the guard ============
# The same species of guard check-roadmap.sh applies to /roadmap: if step 10 stops consulting
# automerge-ok, the library is still green while the workflow arms auto-merge blind.
WFSRC="$ROOT/base/workflows/implement-issue.md"
if grep -q '{{REPO_SETTINGS_LIB}} automerge-ok' "$WFSRC"; then ok; else
  bad "base/workflows/implement-issue.md no longer calls {{REPO_SETTINGS_LIB}} automerge-ok before arming auto-merge"
fi
if grep -q 'gh pr merge .*--auto' "$WFSRC"; then ok; else
  bad "base/workflows/implement-issue.md no longer arms auto-merge at all"
fi
# The workflow must ASK which merge flag the repo allows, never hardcode one.
if grep -q '{{REPO_SETTINGS_LIB}} merge-flag' "$WFSRC"; then ok; else
  bad "base/workflows/implement-issue.md no longer asks merge-flag — a hardcoded flag breaks any repo with that method disabled"
fi
if grep -q 'gh pr merge .*--auto --squash' "$WFSRC"; then
  bad "base/workflows/implement-issue.md hardcodes --squash again"
else ok; fi

# ============ #102: a blind parse must not reach a WRITE, or a fail-OPEN guard code ============
# The parse-failure mapping, driven through the recording stub. These are the four consumers of
# discovery, and each one's dangerous behaviour on an unreadable desired set is different:
#
#   apply          would write required checks from an incomplete scan — reporting success while
#                  gating nothing, and with --prune DELETING the contexts still gating the repo.
#   automerge-ok   would see nwant=0 and return 12 ("no CI at all"), a confident claim about a repo
#                  whose CI it could not read, sending the operator to the wrong remedy.
#   required-drift would see nwant=0 and return 0 — "in sync" about a comparison it never made.
#                  That is #102's own shape one level up, and it is precisely why the backstop that
#                  was supposed to catch #102 could not.
#   status         would print "discovered contexts (desired): 0", which reads identically to a
#                  repo that legitimately has no CI.
wf_blind() { wf_reset; printf 'name: CI\non:\n  pull_request:\njobs:\n' > "$WF/blind.yml"; }

wf_blind; repo_fx true true; branch_checks "one"
rsx_stub required-drift
eq "$RC_" "20" "required-drift maps a failed discovery to 20 — NOT 0, and NOT 14"
has "$OUT" "check discovery failed" "...and says discovery is what failed"

wf_blind; repo_fx true true; branch_checks "one"
rsx_stub automerge-ok
eq "$RC_" "20" "automerge-ok maps a failed discovery to 20 — NOT 12 ('this repo has no CI')"
has "$OUT" "refusing to arm auto-merge" "...and refuses to arm"

wf_blind; repo_fx true true; branch_checks "one"
rsx_stub status
no "$RC_" "status reports drift when discovery failed"
has "$OUT" "check discovery FAILED" "...naming discovery rather than showing a bare 0 desired contexts"

# THE WRITE MUST NOT HAPPEN. rc alone is not enough here: `apply` could fail AFTER mutating, which
# is the half-configured state this module exists to prevent. Assert the call log is empty of
# writes — that is the property, and it is checked structurally rather than inferred from a message.
wf_blind; repo_fx true true; branch_checks "one"
rsx_stub apply
no "$RC_" "apply refuses when discovery failed"
has "$OUT" "refusing to write required checks" "...and says so"
hasnt "$(cat "$STUB_CALLS")" "required_status_checks" "apply wrote NO required checks after a failed scan"
hasnt "$(cat "$STUB_CALLS")" "allow_auto_merge" "apply did NOT enable auto-merge after a failed scan"

# --prune is the destructive arm: it DELETES required contexts this tool did not discover. A blind
# scan discovers nothing, so an unguarded --prune would clear the branch's entire required set —
# turning a parse failure into the repo losing its gating. Pinned separately from plain apply.
wf_blind; repo_fx true true; branch_checks "one" "two"
rsx_stub apply --prune
no "$RC_" "apply --prune refuses when discovery failed"
eq "$(cat "$STUB_CALLS")" "" "...and made NO API call at all — a blind --prune would have cleared the required set"

# The 4-space repo that used to be invisible now applies normally, which is the other half of the
# claim: fail-loud must not have been bought by failing on files that are simply fine.
wf_reset
printf 'name: CI\non:\n    pull_request:\njobs:\n    one:\n        runs-on: ubuntu-26.04\n' > "$WF/four.yml"
repo_fx true true; branch_checks "one"
rsx_stub required-drift
eq "$RC_" "0" "a 4-space repo whose job IS required reports no drift (it used to report nwant=0)"
has "$OUT" "no drift" "...by matching, not by discovering nothing"

# ============================ the CI WIRING of required-drift (#165) ============
# Everything above proves the PREDICATE. This proves the two CALL SITES, and it exists because the
# predicate being perfect is worth nothing if the workflow asks it the wrong question on the wrong
# event — a failure mode that prints exactly what a healthy run prints.
#
# The `required-drift-wired` fact pin (check-fact-drift.sh) already catches the step being DELETED,
# by pinning the literal invocation. It cannot catch the step being MIS-GATED: swap the two `if:`
# conditions and both literals are still there, both steps still run, and the default branch is now
# merely advised while pull requests are hard-failed — the exact inversion #165 shipped to fix, with
# a green lint over it. Only structure catches that, so structure is what this asserts.
#
# COMMENTS ARE STRIPPED FIRST. The claim is about the YAML, and the prose above those steps
# deliberately quotes both event names AND the retired `github.ref` disjunct in order to explain why
# it went — so a grep that reads comments would report the retired form as still present and the
# arms as both-events, failing on the documentation that exists to prevent the bug.
# Emits, per step that invokes required-drift: <porcelain|plain> TAB <the WHOLE `if:` expression,
# whitespace-normalized>. The condition is compared for EQUALITY by the callers below, not searched
# for a token, because a token test answers the wrong question: `github.event_name == 'push' &&
# false` contains the token and governs nothing, and a token test would report the arm as correctly
# gated while it never runs. Equality also makes an ADDED disjunct a failure by construction, so the
# retired `github.ref` clause cannot creep back under a passing grep.
drift_wiring() {   # <ci.yml path> -> <porcelain|plain>\t<normalized if:>
  awk '
    /^[[:space:]]*#/ { next }                      # prose is not wiring
    /^      - name:/ { flush(); block = ""; inif = 0 }
    /^        [a-z]/ { inif = 0 }                  # any sibling key ends the if: block
    /^        if:/   { inif = 1; cond = ""; sub(/^[[:space:]]*if:[[:space:]]*>?-?[[:space:]]*/, ""); if ($0 != "") cond = $0; next }
    inif && /^          / { line = $0; sub(/^[[:space:]]+/, "", line); cond = (cond == "" ? line : cond " " line); next }
    { block = block "\n" $0 }
    END { flush() }
    function flush(   p) {
      if (block !~ /repo-settings\.sh required-drift/) return
      p = (block ~ /required-drift --porcelain/) ? "porcelain" : "plain"
      printf "%s\t%s\n", p, cond
    }
  ' "$1"
}
CI_YML="$ROOT/.github/workflows/ci.yml"

# The `on:` block must FILTER push, or every job runs twice per head SHA again (#99/#165). Scoped to  adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work
# the `on:` block: `branches:` also appears under `pull_request:` filters in other repos' workflows,
# and a bare file-wide grep would accept a filter on the wrong trigger entirely.
#
# Emits the push trigger's branch filter as ONE ENTRY PER LINE, handling both legal spellings:
#
#     push:                 push:
#       branches: [main]      branches:
#                               - main
#
# Accepting only the first would be a guard that fails on reformatting, and those get deleted rather
# than fixed. But the entries are PARSED rather than grepped, which matters more: a substring test
# for "main" is satisfied by `branches: [not-main]`, and one that does not strip comments is
# satisfied by a `# branches: [main]` sitting above an unfiltered `push:`. Both leave every job
# running twice while the guard reports success — the silent pass this section exists to prevent.
# (A flow-style `on: {push: {...}}` one-liner would defeat this; this repo writes block YAML, and
# rewriting it that way is a deliberate act that should revisit this check.)
push_branch_entries() {
  awk '
    /^[[:space:]]*#/ { next }                       # a commented-out filter filters nothing
    /^on:/           { inon = 1; next }
    /^[^[:space:]]/  { inon = 0; inpush = 0; inbr = 0 }
    inon && /^  push:/ { inpush = 1; next }
    inon && /^  [^ ]/  { inpush = 0; inbr = 0 }
    inpush && /^    branches:/ {
      inbr = 1
      rest = $0
      sub(/^[[:space:]]*branches:[[:space:]]*/, "", rest)
      if (rest ~ /^\[/) {                           # flow sequence: [a, b]
        gsub(/^\[|\][[:space:]]*$/, "", rest)
        k = split(rest, parts, /,/)
        for (i = 1; i <= k; i++) {
          gsub(/^[[:space:]\047"]+|[[:space:]\047"]+$/, "", parts[i])
          if (parts[i] != "") print parts[i]
        }
      }
      next
    }
    inbr && /^      -/ {                            # block sequence: - a
      rest = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", rest)
      gsub(/^[[:space:]\047"]+|[[:space:]\047"]+$/, "", rest)
      if (rest != "") print rest
      next
    }
    inbr && /^    [^ ]/ { inbr = 0 }
  ' "$1"
}
# EXACT, not "contains". The filter this repo needs is precisely `[main]`; widening it is a
# deliberate act that should come back through this assertion rather than slip past a substring
# test. An unfiltered `push:` yields empty output, which is not "main" either.
eq "$(push_branch_entries "$CI_YML")" "main" \
   "ci.yml's push: is filtered to exactly the default branch, so a PR head gets ONE run of each job (#99)"  # adb-claim-ok: #99 was closed NOT_PLANNED as SUPERSEDED by #165, which absorbed it; the reference is this change's provenance, not tracked work

# Exactly two call sites, one per arm. A third would mean an ungoverned copy; one means an arm was
# lost, and losing the PUSH arm is silent — nothing else in this repo would fail.
eq "$(drift_wiring "$CI_YML" | wc -l | tr -d ' ')" "2" "ci.yml wires required-drift exactly twice (one enforcing arm, one advisory)"

# THE ENFORCING ARM IS THE PUSH ARM, and the condition must be EXACTLY this. Equality rather than a
# token search: `… == 'push' && false` contains the token and governs nothing, and an extra disjunct
# (the retired `github.ref` clause creeping back) would also pass a search. Both are caught here.
_RS_GUARD="github.repository == 'BWBama85/ai-dev-baseline'"
eq "$(drift_wiring "$CI_YML" | grep '^plain' | cut -f2)" "$_RS_GUARD && github.event_name == 'push'" \
   "the hard-failing arm's if: is EXACTLY the repo guard AND event_name == push (nothing more, nothing less)"

# THE ADVISORY ARM IS THE PR ARM, and it must ask for --porcelain: without it the step would have to
# parse the human code-14 text, whose remedy (`baseline repo apply`) is wrong from a PR branch.
eq "$(drift_wiring "$CI_YML" | grep '^porcelain' | cut -f2)" "$_RS_GUARD && github.event_name == 'pull_request'" \
   "the advisory arm's if: is EXACTLY the repo guard AND event_name == pull_request"

# The retired disjunct is excluded by the equalities above (an extra clause changes the string), but
# assert its absence from the whole wiring too — it must be GONE, not merely unused. Left in place it
# reads as load-bearing, and it is the clause whose deletion-in-isolation would have turned this step
# PR-only and removed every hard failure in the file (gap analysis, BLOCKING 1).
hasnt "$(drift_wiring "$CI_YML")" "github.ref" "the 'github.ref == refs/heads/<default>' disjunct is gone (push: is filtered now)"

# The enforcing arm must actually INVOKE the library, not merely mention it. `run: echo bash
# scripts/lib/repo-settings.sh required-drift` satisfies every containment test above while gating
# nothing at all — the same shape as a guard that scans zero files.
has "$(awk '/^      - name: Required-check drift on the default branch/ { g = 1 } g && /^        run:/ { print; exit }' "$CI_YML")" \
    "run: bash scripts/lib/repo-settings.sh required-drift" \
    "...and its run: line invokes the library directly, rather than merely naming it"

# The advisory arm must not be able to fail the job on drift: it converts 14 into 0 and re-raises
# everything else. Asserted on the extracted step text so a future edit that "simplifies" it back
# into `set -e` + a plain call is caught.
#
# BOTH EXTRACTORS KEY OFF THE `--porcelain` INVOCATION, never off the step's NAME. Anchoring on the
# word "advisory" in a `name:` makes a RENAME of a perfectly correct step fail this suite, and a
# guard that fails on cosmetic edits gets deleted rather than fixed. The invocation is the thing
# being asserted about, so it is also the right thing to find it by. The extraction is still
# indentation-sensitive — a `run: |` body has to be de-indented to run — but that is checked rather
# than assumed: an empty extraction FAILS loudly below instead of vacuously passing.
adv_step="$(awk '/^      - name:/ { buf = ""; grab = 1 }
                 grab { buf = buf $0 "\n" }
                 /required-drift --porcelain/ { found = 1 }
                 found && /GITHUB_STEP_SUMMARY"$/ { printf "%s", buf; exit }' "$CI_YML")"
has "$adv_step" 'rc" -ne 14'      "the advisory arm re-raises every code EXCEPT 14 (20 stays fail-closed)"
has "$adv_step" "GITHUB_STEP_SUMMARY" "...and writes its advisory from the STEP, keeping the library read-only"

# ...and then RUN IT, under the shell GitHub actually uses. Everything above is a grep, and a grep
# could not have caught the defect this exists for: the block once read `drifted="$(…)"; rc=$?`,
# which is correct under `bash file` and FATAL under `bash -e file`. GitHub runs a Linux `run:` step
# as `bash -e {0}`, and `set -uo pipefail` does not clear errexit — so on the drift path the
# assignment tripped errexit and the step died at that line with exit 14, writing no advisory and
# hard-failing the PR. That is the exact behaviour #165 removed, reintroduced by a semicolon, and
# every static assertion above still passed.
#
# So the contract is executed, not described: extract the block verbatim, stub the library at each
# exit code, and require the advisory path to exit 0 AND produce a summary — under `bash -e`.
adv_body="$(printf '%s\n' "$adv_step" | awk '
                 /^          set -uo pipefail$/ { emit = 1 }
                 emit { sub(/^          /, ""); print }
                 emit && /GITHUB_STEP_SUMMARY"$/ { exit }')"
if [ -z "$adv_body" ]; then
  check_note "could not extract the advisory step's shell body from ci.yml — the assertions below would vacuously pass."
  check_note "  Look for: a step whose run: block calls 'required-drift --porcelain', opens with 'set -uo pipefail'"
  check_note "  at 10-space indent, and closes with a line ending '} >> \"\$GITHUB_STEP_SUMMARY\"'."
  check_fail
else
  adv_dir="$work/advisory"; mkdir -p "$adv_dir/scripts/lib"
  printf '%s\n' "$adv_body" > "$adv_dir/adv.sh"
  cat > "$adv_dir/scripts/lib/repo-settings.sh" <<'ADVSTUB'
#!/usr/bin/env bash
case "${STUB_MODE:-}" in
  clean)      exit 0 ;;
  drift)      printf '%s\n' "job one" "b,c" "three"; exit 14 ;;
  hostile)    printf '%s\n' 'ev`il [x](http://example.invalid) `y' 'pct%25name' 'nl%0Aname'; exit 14 ;;
  unreadable) echo "repo-settings: cannot read branch" >&2; exit 20 ;;
  usage)      echo "repo-settings: unknown option" >&2; exit 2 ;;
esac
ADVSTUB
  adv_run() {   # <mode> -> RC_ = the STEP's exit code, OUT = its stdout, with a fresh summary file
    : > "$adv_dir/summary.md"
    OUT="$(cd "$adv_dir" && STUB_MODE="$1" GITHUB_STEP_SUMMARY="$adv_dir/summary.md" \
             bash -e adv.sh 2>&1)"; RC_=$?
  }

  # THE REGRESSION ITSELF. Under `bash -e`, drift must still exit 0 and still write the advisory.
  adv_run drift
  eq "$RC_" "0" "under 'bash -e' (GitHub's default shell) the advisory arm exits 0 on drift"
  ok "[ -s '$adv_dir/summary.md' ]" "...and actually wrote the job summary rather than dying at the capture"
  has "$OUT" "::warning" "...and emitted a warning annotation, not an error"
  # The names must survive intact: one carries a space, one carries a comma. A `paste -sd ', '`
  # join would render these three as `job one,b,c three`.
  has "$OUT" "job one, b,c, three" "every drifted name is joined correctly (a comma IN a name is not a separator)"
  has "$(cat "$adv_dir/summary.md")" '    b,c' "...and each is its own line of an INDENTED code block"

  # BRANCH-AUTHORED TEXT REACHES BOTH SURFACES, and both interpret their input. A job `name:` is
  # free text from the PR's own tree — on a fork PR, from a stranger — so the two escapes are
  # asserted on the values that actually break them, not on well-behaved names.
  adv_run hostile
  eq "$RC_" "0" "a hostile job name is still only advice (it must not fail the PR either)"
  # A backtick span is closed by the first matching run, so `a` [x](url) `b` would inject a RENDERED
  # link into a page a maintainer reads. An indented code block has no delimiter to forge.
  has "$(cat "$adv_dir/summary.md")" '    ev`il [x](http://example.invalid) `y' \
      "a name carrying backticks + a markdown link is emitted VERBATIM, not rendered"
  hasnt "$(cat "$adv_dir/summary.md")" '- `ev`' "...and is not wrapped in a code span it could close"
  # The runner DECODES %25/%0A/%0D in a workflow command, so a literal `%25` in a name would come
  # back as `%` and a `%0A` would split the annotation across lines.
  has "$OUT" 'pct%2525name' "a literal %25 in a name is escaped, so the runner decodes it back to %25"
  has "$OUT" 'nl%250Aname'  "...and a literal %0A cannot break the annotation across lines"

  adv_run clean
  eq "$RC_" "0" "an in-sync PR exits 0"
  hasnt "$OUT" "::warning" "...with no annotation at all"

  # FAIL-CLOSED SURVIVES. Only 14 is softened; everything else must still fail the PR.
  adv_run unreadable
  eq "$RC_" "20" "an unreadable live read still FAILS the PR (20 is not advice)"
  has "$OUT" "::error" "...and says so as an error"
  adv_run usage
  eq "$RC_" "2" "a usage error still fails the PR (a renamed flag must not pass silently)"
fi
# Pinned as PRESENCE of the caution, not absence of the command — the advisory names
# `baseline repo apply` on purpose, to say DON'T. Asserting the string were absent would fail on the
# warning itself and, worse, would be satisfied by an advisory that simply said nothing about the
# trap. What must survive an edit is the negation.
has "$adv_step" 'Do _not_ run' "...and warns AGAINST applying from the PR branch (that is what strands a phantom context)"

# ====================== #103: a slashed branch name reaches the right endpoint ==================
#
# `release/v1` is a perfectly ordinary git branch name, and six sites here used to interpolate it
# raw — building `branches/release/v1/protection` rather than one encoded path segment. The
# measurement recorded in D53 says GitHub accepts BOTH spellings, so this is not a repair of a
# broken path; it is the encoded form being chosen, once, in one builder, because `/` is merely the
# most common of the characters git permits and a URI path does not.
#
# THESE ASSERTIONS READ THE REQUEST LOG, NOT THE EXIT CODE, and that is the whole reason they can
# fail. The stub answers `*/branches/*` from one fixture, so a slashed branch produces exactly the
# same status, body and exit code whether the library encoded it or not: an outcome-shaped test
# here is green against both implementations and proves nothing. What distinguishes them is the URL
# that was requested, so that is what is asserted — exactly, and by absence as well as presence.
# `LC_ALL=C`, because a request log can legitimately contain bytes that are not valid UTF-8 — the
# invalid-UTF-8 ref in group (8) is exactly such a case, and in a UTF-8 locale `tr` fails with
# "Illegal byte sequence" and emits a TRUNCATED log, which silently weakens every assertion reading
# it. Observed while negative-testing group (8) against a deliberately broken build.
reads_of() { LC_ALL=C tr '\n' '|' < "$STUB_READS"; }
# EXACT-LINE MATCHERS, because `has` is substring containment and that is not what these assertions
# claim (independent-review find). `has "$(reads_of)" ".../branches/release%2Fv1"` is satisfied by a
# request for `.../branches/release%2Fv1/protection` — a DIFFERENT endpoint — and the stub answers
# both from one fixture, so no outcome check would expose the difference either. Both logs are
# newline-delimited records, so joining with `|` and looking for a `|`-fenced whole record is exact
# equality on one line while still tolerating any other lines in the log.
#
# THE QUOTES AROUND `$1` IN THE PATTERN ARE LOAD-BEARING, and they are the reason the predicate is
# split out below rather than inlined twice. `case … in *"|$1|"*)` matches the EXPANSION literally;
# written unquoted as `*|$1|*` the same line turns every glob metacharacter in the expected record
# live, and the check-runs URL contains a `?` — so a logged `…check-runsXper_page=100` would pass an
# assertion that reads as exact. Verified literal on bash 5.3.15 and 3.2.57 for `?`, `*` and `[…]`;
# the self-test immediately below is what keeps it that way, because removing the quotes changes
# nothing that any other assertion here could see. (Raised by the independent reviewer as a live
# defect; it is not one as written, but the fragility it names is real and now has a guard.)
log_has_record() {   # <expected whole record> <joined log> -> 0 when the log holds that record
  case "|$2" in *"|$1|"*) return 0 ;; *) return 1 ;; esac
}
read_is() { if log_has_record "$1" "$( reads_of )"; then ok; else bad "$2 — request log: [$( reads_of )]"; fi; }
call_is() { if log_has_record "$1" "$( calls_of )"; then ok; else bad "$2 — call log: [$( calls_of )]"; fi; }

# Self-test the matcher before relying on it for 20 assertions. A matcher that silently degrades to
# a glob is the classic guard-that-cannot-answer-wrong: every assertion still passes, and passes
# MORE often, which is invisible.
if log_has_record 'GET a?b'     '|GET a?b|';    then ok; else bad "log_has_record must match an exact record"; fi
if log_has_record 'GET a?b'     '|GET aXb|';    then bad "log_has_record treats '?' as a glob — the pattern quoting was lost"; else ok; fi
if log_has_record 'GET a*b'     '|GET aZZb|';   then bad "log_has_record treats '*' as a glob — the pattern quoting was lost"; else ok; fi
if log_has_record 'GET a[xy]b'  '|GET axb|';    then bad "log_has_record treats '[…]' as a glob — the pattern quoting was lost"; else ok; fi
# ...and it must anchor on WHOLE records, or a prefix of a longer URL would satisfy it — the exact
# weakness that made the previous substring `has` unusable here.
if log_has_record 'GET a/b'     '|GET a/b/c|';  then bad "log_has_record matched a PREFIX of a longer record"; else ok; fi
if log_has_record 'GET a/b'     '|X|GET a/b|Y|'; then ok; else bad "log_has_record must find a record among others"; fi
SL_ENC='branches/release%2Fv1'
SL_RAW='branches/release/v1'

# (1) protected-with-checks + --enforce-admins — three of the six sites in one run: the protection
#     GET, the narrow required_status_checks PATCH, and the enforce_admins POST.
wf_one; repo_fx true true; prot_checks "two"
rsx_stub apply --branch release/v1 --enforce-admins
read_is "GET repos/acme/widget/$SL_ENC/protection"     "apply GETs the ENCODED protection path for 'release/v1'"
call_is "PATCH repos/acme/widget/$SL_ENC/protection/required_status_checks" \
    "...PATCHes the encoded required_status_checks sub-resource"
call_is "POST repos/acme/widget/$SL_ENC/protection/enforce_admins" \
    "...and POSTs the encoded enforce_admins sub-resource"
# ABSENCE MATTERS AS MUCH AS PRESENCE. A builder that emitted BOTH spellings — or one that encoded
# the read and left a write raw — would satisfy every `has` above.
hasnt "${ reads_of; }$( calls_of; )" "$SL_RAW" "...and NO request anywhere used the raw 'release/v1' spelling"
hasnt "${ reads_of; }$( calls_of; )" '%252F'   "...and none double-encoded it either"

# (2) protected-no-checks — the fourth site, the destructive full PUT. Its own scenario because
#     PROT_STATE selects a different endpoint, and the wide one is the one that replaces the object.
wf_one; repo_fx true true; prot_nochecks
rsx_stub apply --branch release/v1
call_is "PUT repos/acme/widget/$SL_ENC/protection" "the full protection PUT uses the encoded path"
hasnt "${ calls_of; }" "PUT repos/acme/widget/$SL_RAW/protection" "...and not the raw one"

# (3) the fifth site: the ordinary contents-read branch endpoint, which `required-drift` uses
#     because a CI token can never call the admin-only one.
wf_one; repo_fx true true; branch_checks "one"
rsx_stub required-drift --branch release/v1
# EXACT, not substring: this is the endpoint whose path is a strict PREFIX of the protection one, so
# a `has` here would be satisfied by a request for `.../protection` — a different endpoint entirely.
read_is "GET repos/acme/widget/$SL_ENC" "required-drift reads the encoded ordinary branch endpoint"
hasnt "${ reads_of; }" "GET repos/acme/widget/$SL_RAW" "...and not the raw one"

# (4) the sixth site: `commits/{ref}/check-runs`. A DIFFERENT collection whose segment is a ref
#     rather than a branch — which is why the shared builder is ref-shaped, and why a
#     branch-only helper would have left exactly this site (the newest of the six) raw.
#     Reached the way the provenance tests reach it: workflow files present, discovery empty,
#     contexts required.
wf_reset
printf 'name: Sched\non:\n  schedule:\n    - cron: "0 0 * * *"\njobs:\n  nightly:\n    runs-on: ubuntu-latest\n' > "$WF/sched.yml"
repo_fx true true; branch_checks "ci/circleci: build"; checkruns_external "ci/circleci: build"
rsx_stub required-drift --branch release/v1
eq "$RC_" "0" "the check-runs scenario still reaches its documented external-CI pass"
read_is 'GET repos/acme/widget/commits/release%2Fv1/check-runs?per_page=100' \
    "the check-runs read encodes the REF and leaves the query string alone"
# THE QUERY STRING IS THE TRAP HERE: encoding the whole endpoint instead of the segment turns
# `?per_page=100` into part of one absurd path, and pagination breaks silently.
hasnt "${ reads_of; }" '%3Fper_page' "...the '?' is NOT encoded — that would break pagination, silently"
checkruns_none

# (5) the two PRINTED commands. `manual_commands` degrades to instructions when the token lacks
#     admin, and those lines are meant to be pasted — handing an operator the raw spelling would
#     relocate the hazard into their terminal, where nothing here can fail closed on it.
wf_one; repo_fx false false; prot_checks "one"
rsx_stub apply --branch release/v1
has "$OUT" "$SL_ENC/protection/required_status_checks" "the non-admin PATCH instruction carries the encoded path"
has "$OUT" "gh api -X PUT repos/acme/widget/$SL_ENC/protection" "...and so does the PUT instruction"
eq "$(cat "$STUB_CALLS")" "" "...while the non-admin run still mutates nothing"

# (6) THE CONTROL, and the most important assertion in this section: an ordinary branch name must
#     come out BYTE-IDENTICAL. Every existing caller passes a default branch, so an encoder that
#     perturbed one would have broken the path that works today in order to fix one that already
#     worked — the exact trade the issue said not to make. `main` is unreserved end to end.
wf_one; repo_fx true true; prot_checks "two"
rsx_stub apply --enforce-admins
# EXACT records, so "byte-identical" is what is actually asserted. A substring `has` would accept an
# appended or altered unescaped suffix and still pass, which makes the control weaker than its name
# (independent-review find). The `%` check below stays, but as what it really is — the narrower
# over-encoding guard — rather than as the proof of byte identity.
read_is 'GET repos/acme/widget/branches/main/protection' "the default branch path is byte-identical: 'main'"
call_is 'PATCH repos/acme/widget/branches/main/protection/required_status_checks' "...on the write path too"
call_is 'POST repos/acme/widget/branches/main/protection/enforce_admins' "...and on the enforce_admins POST"
hasnt "${ reads_of; }$( calls_of; )" '%' "...and no request in an ordinary run is percent-encoded at all"

# (7) NO TRAVERSING PATH. The encoder neutralizes an exact `..` segment, because
#     `branches/../protection` resolves one level up — the traversal `adb_is_path_safe_repo_slug`
#     refuses for slugs, arriving through the ref door. `--branch ..` must therefore reach the
#     endpoint for a branch NAMED `..` (which cannot exist) and never the repo root.
#
#     NOTE WHAT THIS IS NOT: `..` ENCODES SUCCESSFULLY, so this exercises the dot arm, not the
#     failure path. An earlier draft of this section was labelled "fail closed when the path cannot
#     be built" and asserted only these two lines — a section that could not have caught a caller
#     ignoring a real encoder failure, because it never produced one (independent-review find).
#     Group (8) below is the actual failure case.
wf_one; repo_fx true true; prot_checks "one"
rsx_stub automerge-ok --branch ..
hasnt "${ reads_of; }" 'branches/../protection' "an exact '..' branch never builds a traversing path"
read_is 'GET repos/acme/widget/branches/%2E%2E/protection' "...it addresses a branch literally named '..' instead"

# (8) A GENUINELY UNBUILDABLE PATH — the failure case, which needs an input the encoder really
#     REFUSES. A git ref is a byte string, so a ref carrying invalid UTF-8 is the reachable one:
#     jq's `--arg` would rewrite it to U+FFFD, and the fidelity round trip refuses instead.
#
#     Every caller must then fail closed, and "fail closed" here has FOUR distinct obligations, all
#     of which a wrong implementation can violate independently — so all four are asserted:
#     a non-zero exit, NO request issued, NO mutation performed, and NO runnable raw path printed.
#     The last two are the regressions this group exists for: `apply`'s no-CI arm used to skip the
#     checks write and fall through to the `allow_auto_merge` PATCH (an outward mutation on a repo
#     whose protection it could not read), and `manual_commands` used to degrade to
#     `branches/<raw>/protection` — printing, for an operator to paste, the exact interpolation this
#     whole change refuses to build.
BAD_REF="$(printf 'rel\xffv1')"

wf_one; repo_fx true true; prot_checks "one"
rsx_stub automerge-ok --branch "$BAD_REF"
eq "$RC_" "20" "automerge-ok = 20 (fail closed) when the ref has no request-path encoding"
has "$OUT" "cannot read branch protection" "...saying the protection state is unreadable"

# `apply` with admin and NO discovered CI — the arm that skips the checks write entirely.
#
# `repo_fx true false`, NOT `true true`, and the fixture is the whole test. With auto-merge already
# ENABLED there is no PATCH to make, so "mutates NOTHING" holds no matter what the code does — the
# assertion passes against the broken implementation and proves nothing. Verified by reverting the
# guard on a copy: with `true true` the suite stayed green on this line, with `true false` it fires.
# (That is the review's own lesson about outcome-shaped assertions, applied to the fix for it.)
wf_none; repo_fx true false; prot_checks "one"
rsx_stub apply --branch "$BAD_REF"
eq "$RC_" "1" "apply = 1 (its own contract) on a ref with no request-path encoding"
has "$OUT" "refusing to change any setting" "...saying it refused BEFORE any write, not after one failed"
eq "$(cat "$STUB_CALLS")" "" "...and mutates NOTHING — not even allow_auto_merge, which needs no branch"
hasnt "$(cat "$STUB_READS")" 'branches/rel' "...and never issued a request built from the raw bytes"

# The non-admin path, which PRINTS commands rather than issuing them.
wf_one; repo_fx false false; prot_checks "one"
rsx_stub apply --branch "$BAD_REF"
hasnt "$OUT" 'gh api -X PATCH repos/acme/widget/branches/rel' \
    "the non-admin path prints NO runnable command built from an unencodable ref"
hasnt "$OUT" 'gh api -X PUT repos/acme/widget/branches/rel' "...for either endpoint"
has "$OUT" "no valid request-path encoding" "...and says why the commands are withheld"
eq "$(cat "$STUB_CALLS")" "" "...while still mutating nothing"

check_summary "repo-settings"
