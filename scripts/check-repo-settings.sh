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
has "$OUT" "'checks', 'status', 'apply', or 'automerge-ok'" "unknown subcommand lists every subcommand"

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
eq "$(ctx)" 'build-drift|shellcheck|' "only real jobs are contexts — the on: block's push/pull_request are NOT harvested"
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
eq "$(ctx)" 'Human Name|bare|keyed|quoted name|' "name: wins over the job key; a keyless job falls back to its key; quotes stripped"
has "$ERR" "skipping job conditional" "a job-level if: is skipped (it may never report)"
has "$ERR" "skipping job matrixed"    "a matrix job is skipped (its check name carries a suffix)"
has "$ERR" "skipping job reusable"    "a reusable-workflow job is skipped (names come from the callee)"
has "$ERR" "skipping job dynamic"     "a \${{ }} job name is skipped (not statically knowable)"
has "$ERR" "blocks the PR forever"    "the skip reason states WHY a phantom context is dangerous"
hasnt "$(ctx)" 'mat|'  "a matrix job never reaches the required set"
hasnt "$(ctx)" 'cond|' "a conditional job never reaches the required set"

# --- file-level triggers ----------------------------------------------------------------------
wf_reset
printf 'name: P\non: push\njobs:\n  never-on-pr:\n    runs-on: ubuntu-latest\n' > "$WF/push-only.yml"
disco main
eq "$(ctx)" '' "a workflow with no pull_request trigger contributes nothing"
has "$ERR" "no pull_request trigger" "the file skip names the missing trigger"

wf_reset
printf 'name: I\non: [push, pull_request]\njobs:\n  inline:\n    runs-on: ubuntu-latest\n' > "$WF/inline.yml"
disco main
eq "$(ctx)" 'inline|' "an inline flow-sequence 'on: [push, pull_request]' is recognized"

wf_reset
printf 'name: S\non: pull_request\njobs:\n  scalar:\n    runs-on: ubuntu-latest\n' > "$WF/scalar.yml"
disco main
eq "$(ctx)" 'scalar|' "an inline scalar 'on: pull_request' is recognized"

wf_reset
printf 'name: Pa\non:\n  pull_request:\n    paths:\n      - "src/**"\njobs:\n  scoped:\n    runs-on: ubuntu-latest\n' > "$WF/paths.yml"
disco main
eq "$(ctx)" '' "a paths-filtered pull_request contributes nothing (it does not run for every PR)"
has "$ERR" "paths/paths-ignore filter" "the file skip names the paths filter"

# branches: filters — provably-includes vs not. Both directions matter: over-skipping silently
# leaves a repo ungated, under-skipping deadlocks every PR.
wf_reset
printf 'name: B\non:\n  pull_request:\n    branches: [main]\njobs:\n  ok-inline:\n    runs-on: ubuntu-latest\n' > "$WF/b1.yml"
printf 'name: C\non:\n  pull_request:\n    branches:\n      - main\njobs:\n  ok-block:\n    runs-on: ubuntu-latest\n' > "$WF/b2.yml"
printf 'name: D\non:\n  pull_request:\n    branches:\n      - develop\njobs:\n  wrong-base:\n    runs-on: ubuntu-latest\n' > "$WF/b3.yml"
printf 'name: E\non:\n  pull_request:\n    branches: ["*"]\njobs:\n  star:\n    runs-on: ubuntu-latest\n' > "$WF/b4.yml"
disco main
eq "$(ctx)" 'ok-block|ok-inline|star|' "branches: including the target (inline, block, or '*') keeps the job; another base drops it"
has "$ERR" "does not provably include main" "the branches skip names the target branch"
disco develop
has "$(ctx)" 'wrong-base|' "the same fixture keeps the develop-only job when develop IS the target"

# --- multiple files aggregate; a missing dir is 'no CI', not an error -------------------------
wf_reset
printf 'name: One\non:\n  pull_request:\njobs:\n  one:\n    runs-on: ubuntu-latest\n' > "$WF/one.yml"
printf 'name: Two\non:\n  pull_request:\njobs:\n  two:\n    runs-on: ubuntu-latest\n' > "$WF/two.yaml"
disco main
eq "$(ctx)" 'one|two|' "contexts aggregate across .yml and .yaml files"

OUT="$(bash "$RS" checks --branch main --workflow-dir "$work/nonexistent" 2>"$work/err")"; RC_=$?
yes "$RC_" "a repo with no .github/workflows exits 0 (no CI is a legitimate state, not an error)"
eq "$OUT" "" "a repo with no CI discovers no contexts"
has "$(cat "$work/err")" "no CI" "the no-CI case says so on stderr"

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
url=""; method="GET"; has_input=0; prev=""
for a in "$@"; do
  case "$a" in
    repos/*)              [ -z "$url" ] && url="$a" ;;
    PATCH|PUT|POST|DELETE) [ "$prev" = "-X" ] && method="$a" ;;
    -)                    [ "$prev" = "--input" ] && has_input=1 ;;
  esac
  prev="$a"
done
if [ "$method" = "GET" ]; then
  case "$url" in
    */protection) [ -f "$S/protection.json" ] || exit 1; cat "$S/protection.json" ;;
    repos/*)      [ -f "$S/repo.json" ] || exit 1;       cat "$S/repo.json" ;;
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

rsx_stub() {   # run against the stub with a fresh call log
  STUB_CALLS="$work/calls.txt"; : > "$STUB_CALLS"
  rm -f "$S/body.json"
  OUT="$(S="$S" STUB_CALLS="$STUB_CALLS" STUB_FAIL_WRITE="${STUB_FAIL_WRITE:-}" \
         PATH="$SBIN:$PATH" bash "$RS" "$@" --workflow-dir "$WF" 2>&1)"; RC_=$?
}
rsx_auth() {   # the SAME stub, auth knob flipped — one stub, two behaviors
  OUT="$(S="$S" STUB_AUTH_FAIL=1 PATH="$SBIN:$PATH" bash "$RS" "$@" --workflow-dir "$WF" 2>&1)"; RC_=$?
}
calls_of() { tr '\n' '|' < "$STUB_CALLS"; }

# --- fail-loud gh guard -----------------------------------------------------------------------
wf_one; repo_fx true false; prot_nochecks
rsx_auth apply;        no "$RC_" "apply with unauthenticated gh exits nonzero";        has "$OUT" "not authenticated" "apply surfaces the auth failure"
rsx_auth status;       no "$RC_" "status with unauthenticated gh exits nonzero";       has "$OUT" "not authenticated" "status surfaces the auth failure"
rsx_auth automerge-ok; no "$RC_" "automerge-ok with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "automerge-ok surfaces the auth failure"

# --- endpoint selection: the narrow PATCH when a status-check sub-resource exists --------------
wf_one; repo_fx true false; prot_checks "stale-name"
rsx_stub apply
yes "$RC_" "apply succeeds against a branch that already has required checks"
eq "$(calls_of)" 'PATCH repos/acme/widget/branches/main/protection/required_status_checks|PATCH repos/acme/widget|' \
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
eq "$(calls_of)" 'PUT repos/acme/widget/branches/main/protection|PATCH repos/acme/widget|' \
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
has "$(calls_of)" "POST repos/acme/widget/branches/main/protection/enforce_admins" \
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
eq "$(calls_of)" 'PUT repos/acme/widget/branches/main/protection|PATCH repos/acme/widget|' \
  "unprotected -> PUT standing protection up, THEN the auto-merge PATCH"
eq "$(jq -r '.required_conversation_resolution' "$S/body.json")" "true" "a fresh stand-up turns thread resolution on"
eq "$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$S/body.json")" "0" \
  "a fresh stand-up requires a PR but invents no approval requirement"

# --- THE load-bearing order: a failed checks write must not enable auto-merge ------------------
wf_one; repo_fx true false; prot_nochecks
STUB_FAIL_WRITE="protection" rsx_stub apply
no "$RC_" "a failed required-checks write makes apply exit nonzero"
eq "$(calls_of)" 'PUT repos/acme/widget/branches/main/protection FAILED|' \
  "the auto-merge write is NEVER reached when the checks write fails (order is load-bearing)"
has "$OUT" "refusing to enable auto-merge" "the refusal says why"
STUB_FAIL_WRITE=""

# --- non-admin degrades to instructions, and writes NOTHING -----------------------------------
wf_one; repo_fx false false; prot_nochecks
rsx_stub apply
no "$RC_" "a non-admin apply exits nonzero"
eq "$(calls_of)" "" "a non-admin apply performs NO writes (the permission probe runs before any write)"
has "$OUT" "No admin permission" "the non-admin path names the problem"
has "$OUT" "required checks FIRST" "the manual instructions state the load-bearing order"

# --- dry-run changes nothing ------------------------------------------------------------------
wf_one; repo_fx true false; prot_nochecks
rsx_stub apply --dry-run
yes "$RC_" "apply --dry-run exits 0"
eq "$(calls_of)" "" "apply --dry-run performs NO mutations"
has "$OUT" "would set required checks" "dry-run prints the write it would do"
has "$OUT" "Dry run — nothing was changed" "dry-run says it changed nothing"

# --- no CI: skip the checks write, do NOT block (#24) -----------------------------------------
wf_none; repo_fx true false; prot_none
rsx_stub apply
yes "$RC_" "apply on a repo with no CI still succeeds (it must not block)"
eq "$(calls_of)" 'PATCH repos/acme/widget|' "no CI -> the checks write is skipped, auto-merge is still enabled"
has "$OUT" "SKIPPED (no PR-triggered CI" "the no-CI path says the checks write was skipped"

# --- already-enabled auto-merge is not re-written ---------------------------------------------
wf_one; repo_fx true true; prot_checks "one"
rsx_stub apply
eq "$(calls_of)" 'PATCH repos/acme/widget/branches/main/protection/required_status_checks|' \
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

# The guard must be no shallower than `status`: a renamed CI job leaves the OLD context required
# and never reported, so an armed PR would wait forever. Non-empty contexts are NOT sufficient.
wf_one; repo_fx true true; prot_checks "stale-name"
rsx_stub automerge-ok
eq "$RC_" "13" "automerge-ok = 13 when a required context no workflow reports (renamed job)"
has "$OUT" "wait for them forever" "code 13 explains that an armed PR would hang"
has "$OUT" "stale-name" "code 13 names the phantom context"

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

check_summary "repo-settings"
