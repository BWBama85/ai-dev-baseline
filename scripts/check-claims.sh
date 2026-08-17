#!/usr/bin/env bash
# ai-dev-baseline — claim lint (issue #212, narrowed by #374).
#
# ONE RULE: an issue/PR number cited by an added line of SHIPPED PROSE must resolve, and must be
# the kind of entity it is cited as. The #173 run (PR #210) shipped a `#207` citation for an issue
# that DID NOT EXIST, and it rendered into all three agents' skills; two pre-existing citations
# pointed at issue #150, closed NOT_PLANNED — abandoned work reading as delivered.  adb-claim-ok:
# that citation is deliberately historical, and the marker must sit on the SAME line as the
# reference because the exemption is per-line. This is the escape's first real use, on the very
# example the lint exists for.
#
# base/practices/verify-before-asserting.md already forbids exactly this for PR/issue STATUS, and
# D16 is the precedent for why it is a gate rather than another paragraph: the prose version failed
# twice with the practice loaded in context. An issue NUMBER is the same kind of claim, and a `gh`
# call plus a `grep` is all "find a supporting quote" means for an identifier — so it can be a lint
# instead of an instruction.
#
# WHAT #374 REMOVED, and why it is a removal rather than a move. This file also carried a
# `D<N>`-resolution rule and a decision-date rule. Both read `.ai-dev-baseline/decisions.md` and
# `CHANGELOG.md`; `install.sh` ships neither, and no `base/workflows/*.md` reads either — they
# protected one maintainer from a D-number mix-up, which is documentation hygiene rather than a loop
# invariant. The owner decided on 2026-08-15 to DROP them rather than migrate them into
# `check-fact-drift.sh`'s grammar (D72). The `#N` rule stays because it has a shipped artifact
# behind it: workflow and practice prose renders into all three agents' root docs and skills and
# symlinks into every adopter's tree, and `templates/agents.toml` is copied into an adopting repo.
#
# SCOPED TO THE ADDED LINES OF A RANGE, and within that to the SHIPPED-PROSE roots — never the
# whole tree. The range scoping is what makes the check adoptable: measured on `origin/main` at the
# time this landed, the tree carried 2450 numeric references over 157 distinct numbers, of which 11
# cite issues legitimately closed NOT_PLANNED and 39 are not issues at all. (Those figures are a
# dated baseline, not a live property of the checkout — they drift the moment anyone writes a
# reference, and quoting them as current would be the same stale-claim defect this file exists to
# catch.) The PATH scoping is what keeps the rule pointed at the artifact that justifies it; a
# citation in a script comment or a decision record misinforms one reader of one repo, while a
# citation in shipped prose is rendered, installed and read by every adopter. The run REPORTS how
# many changed files it skipped for being out of scope, so the narrowing is visible in the log
# rather than looking like a range with nothing in it.
#
# Usage:
#   bash scripts/check-claims.sh [--range <base>..<head>] [--live]
#   bash scripts/check-claims.sh --self-test
#
#   --range      what to scan. Default: origin/<default>...HEAD (three-dot: from the merge base,
#                i.e. this branch's own added lines). Two-dot is accepted and passed through.
#   --live       ALSO run the issue/PR-reference check, which needs gh and the network.
#   --self-test  drive every rule this file owns to RED against fixtures in a throwaway git repo
#                with a stubbed gh. Takes no other argument. It was `check-claims-guard.sh` until
#                #374, folded here the way #377 folded the fact-drift guard.
#
# Exit codes:
#   0  no claim violations
#   1  at least one claim violation (diagnostics on stderr)
#   2  usage error
#   3  a required half of the check could NOT be run (fail closed — never a pass): --live was
#      requested and gh/jq is unavailable, or the shared markdown filter failed on a .md file.
#      Both are "I could not tell", which is never the same answer as "nothing is wrong" — a
#      filter that returns nothing looks exactly like a file with no claims in it.
#
# WHAT AN OFFLINE RUN CAN AND CANNOT RETURN, stated plainly because the answer changed with #374.
# Every VIOLATION this file can report now needs the network, so without `--live` it exits 1 for
# nothing — it is a reporter (how many references it collected and left unverified) plus a
# fail-closed scan (2 on a bad range, 3 on a broken filter or scanner). That is exactly why
# `selfcheck` still runs it: those two are the shapes that would otherwise turn the CI-only half
# into a silent no-op. `--self-test` is what proves both can still go red.
#
# KNOWN LIMIT OF THE REFERENCE GRAMMAR: a six-digit CSS colour is shaped exactly like an issue
# number, so a value such as #123456 in a stylesheet would be looked up.  adb-claim-ok: that is a
# colour literal, not a citation — and the lint flagging this very sentence when it was first
# written is the limit demonstrating itself. This repo tracks no stylesheet, and the grammar is
# left permissive rather than guessing at file types, but it is a real edge for the generalization
# tracked in #233 and is named here rather than discovered there.
#
# WHAT THIS GUARANTEES, STATED NARROWLY. It checks that a reference RESOLVES; it does not and
# cannot check that a reference is APT. That an issue exists is provable; that it is the issue you
# meant is not — that judgement is the review step's, and claiming otherwise here would be the same
# overreach this repo refused when it kept the state-claim grammar small rather than building a
# classifier over arbitrary English.
#
# WHY THERE IS NO PATH-CLAIM CHECK HERE, though #212 asked for one and called it the highest-value
# check. It was built, measured, and removed on the evidence:
#
#   * It cannot catch the defect #212 cites as its justification. That sentence named
#     `base/roles.md`, and `git show --name-only 9e61dfd` lists that file. The path WAS in the
#     diff; what was false was the KIND of change claimed of it. No "is this path in the diff?"
#     predicate sees that, in any formulation.
#   * Measured over the last five merges it scored SEVEN false positives and ZERO true positives —
#     in the verb-free form AND the change-verb form alike. The reason is structural: a changelog
#     is a HISTORICAL document, so any commit that reflows or amends an older entry re-adds prose
#     making true change claims about a different commit. b13a8f8 reflowed CHANGELOG lines 139-171
#     and thereby "claimed" `templates/agents.toml`, `install.sh` and `agents.toml`, none of which
#     it touched. Five of the seven carried a change verb, so a verb grammar does not rescue it.
#   * This repo's own law says a gate that fires on ordinary prose gets worked around, and then it
#     protects nothing at all. That is the trade the state-claim grammar was kept small to avoid.
#
# So the path-claim check lives where the judgement is: a named claim-integrity lens in the review
# prompt of base/workflows/implement-issue.md, which is where #212's own follow-up comment puts
# judgement-heavy claim validation. A controlled opt-in syntax is tracked separately.
#
# Regression-tested by `--self-test` below, which drives every rule to RED against fixtures in a
# throwaway git repo with a stubbed gh. The working tree is never mutated.

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
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "check-claims"

# --- shared primitives (source, never copy — docs/design-principles.md) ------------------------
_cc_common="scripts/lib/common.sh"
[ -f "$_cc_common" ] || { echo "check-claims: FATAL — $_cc_common not found" >&2; exit 2; }
# shellcheck source=/dev/null
. "$_cc_common"
# THE PROSE FILTER IS NOT OPTIONAL (#251). Without it the `.md` rules below would scan raw markdown
# — every fenced, quoted and commented number in the range read as a live citation. Probed for the
# same reason roadmap-lib.sh and skill-compose.sh probe: a common.sh that predates the filter loads
# perfectly well and simply has no `adb_md_prose` in it, and under `set -u` the first use would be
# an unbound-variable abort naming a variable rather than the real problem.
command -v adb_md_prose >/dev/null 2>&1 \
  || { echo "check-claims: FATAL — $_cc_common is missing the shared markdown filter (adb_md_prose)" >&2; exit 2; }

RANGE=""
LIVE=0
SELFTEST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      [ "$#" -ge 2 ] || { echo "check-claims: --range needs a value" >&2; exit 2; }
      RANGE="$2"; shift 2 ;;
    --range=*) RANGE="${1#--range=}"; shift ;;
    --live)    LIVE=1; shift ;;
    # EXCLUSIVE, and rejected here rather than quietly ignored. `--self-test --live` reads like a
    # request for a live self-test; there is no such thing (every case drives a stub), and silently
    # dropping the flag would be a mode doing something other than what it was asked for.
    --self-test)
      [ "$#" -eq 1 ] || { echo "check-claims: --self-test takes no other argument" >&2; exit 2; }
      SELFTEST=1; shift ;;
    -h|--help) adb_usage "$0"; exit 0 ;;
    *) echo "check-claims: unknown option '$1'" >&2; exit 2 ;;
  esac
done
if [ "$SELFTEST" -eq 1 ] && { [ -n "$RANGE" ] || [ "$LIVE" -eq 1 ]; }; then
  echo "check-claims: --self-test takes no other argument" >&2; exit 2
fi

# ================================ --self-test ===================================================
#
# A GUARD'S FAILURE MODE IS SILENCE. Ordinary code that breaks throws; a guard that breaks PASSES —
# it scans zero files, matches zero lines, and prints exactly what a clean run prints. So every rule
# below is driven to RED here against an input it is supposed to reject, and the assertion is on the
# DESIGNATED exit code and diagnostic, never on "some non-zero" (a crash also exits non-zero, and
# would otherwise be indistinguishable from a working rule).
#
# That is not hypothetical for this file's own subject. While it was being written, its markdown
# stripper removed inline code spans before the path-claim rule looked for backticked paths, so that
# rule was structurally incapable of firing. It reported `path-claims=0` on a commit carrying nine of
# them and no assertion anywhere went red.
#
# It was `scripts/check-claims-guard.sh` (950 lines) until #374, and folding it here follows #377's
# fact-drift fold rather than inventing a second shape: one preamble, one bash-floor gate, one
# `cd`, and a mode word. The cases that tested the `D<N>` and decision-date rules are GONE with
# those rules; what remains is the `#N` rule, the shared scan machinery it rests on, and the new
# path scope.
#
# Fixtures live in a throwaway git repo under mktemp, never in the working tree. Editing a tracked
# file to test a check that reads tracked files is how ~40 minutes of uncommitted work was destroyed
# once already (base/practices/self-review.md).
if [ "$SELFTEST" -eq 1 ]; then
  check_init "check-claims --self-test"
  st_work="$(mktemp -d)" || { echo "check-claims --self-test: cannot create a temp dir" >&2; exit 1; }
  ST_JOB="$st_work/ci-job"
  check_exit_guard "check-claims --self-test" "rm -rf \"$st_work\""

  # A throwaway repo that LOOKS like a baseline checkout: this script resolves its own root with
  # `cd "$(dirname "$0")/.."` and sources scripts/check-lib.sh + scripts/lib/common.sh from there,
  # so the fixture needs that shape rather than a bare directory. And the SHIPPED-PROSE roots have
  # to exist in it, because since #374 a fixture written anywhere else is out of scope by design.
  REPO="$st_work/repo"
  mkdir -p "$REPO/scripts/lib" "$REPO/base/workflows" "$REPO/base/practices" "$REPO/templates"
  cp "$ROOT/scripts/check-claims.sh" "$REPO/scripts/"
  cp "$ROOT/scripts/check-lib.sh"    "$REPO/scripts/"
  cp "$ROOT/scripts/lib/common.sh"   "$REPO/scripts/lib/"

  # The throwaway repo + its `origin` URL come from check-lib.sh — the same scaffold the PR suites
  # build. The remote is load-bearing: every read is anchored to the checkout's git origin, so the
  # slug must agree with what the gh stub answers for.
  check_make_stub_repo "$REPO" https://github.com/acme/widget.git || {
    echo "check-claims --self-test: FATAL — could not build the fixture repo" >&2; exit 1; }

  # A TRACKED seed in EVERY in-scope root, committed at BASE. Git prunes a directory that becomes
  # empty when it removes the last tracked file in it, so `reset_branch` between cases would
  # otherwise delete `base/practices/` and `templates/` the first time a case wrote and dropped a
  # fixture there — and the NEXT case's `printf > …` would fail with "No such file or directory",
  # leaving that case asserting against an empty range instead of the input it names. Observed
  # exactly that before this line existed.
  printf 'seed\n'   > "$REPO/README.md"
  printf 'seed\n'   > "$REPO/base/workflows/seed.md"
  printf 'seed\n'   > "$REPO/base/practices/seed.md"
  printf '# seed\n' > "$REPO/templates/seed.toml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm base
  BASE="$(git -C "$REPO" rev-parse HEAD)"

  # A recording gh stub. It answers `gh issue view <n> --repo <slug> --json …` from a table, so every
  # entity SHAPE the live rule must distinguish is reproducible offline:
  #   4242 -> unresolvable        150 -> issue CLOSED/NOT_PLANNED
  #   7,21 -> issue OPEN          210 -> PULL REQUEST (the shared number space; 21 is a
  #                                     deliberate PREFIX of 210, for the hint-boundary test)
  #   9    -> issue CLOSED/COMPLETED
  BIN="$st_work/bin"; mkdir -p "$BIN"
  check_write_stub "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# `auth status` must succeed or adb_require_gh refuses before any read happens.
[ "${1:-}" = "auth" ] && exit 0
# The repository IS reachable. adb_gh_entity asks this to tell "no such issue" apart from "the
# network is gone", so a stub that failed here would make every absent number look unreadable.
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then echo '{"name":"widget"}'; exit 0; fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  n="$3"
  printf '%s\n' "$*" >> "$GH_CALLS"
  case "$n" in
    7)    echo '{"state":"OPEN","stateReason":"","url":"https://github.com/acme/widget/issues/7"}' ;;
    21)   echo '{"state":"OPEN","stateReason":"","url":"https://github.com/acme/widget/issues/21"}' ;;
    9)    echo '{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/acme/widget/issues/9"}' ;;
    150)  echo '{"state":"CLOSED","stateReason":"NOT_PLANNED","url":"https://github.com/acme/widget/issues/150"}' ;;
    210)  echo '{"state":"MERGED","stateReason":"","url":"https://github.com/acme/widget/pull/210"}' ;;
    *)    echo 'GraphQL: Could not resolve to an issue or pull request with the number of '"$n"'. (repository.issue)' >&2
          exit 1 ;;
  esac
  exit 0
fi
exit 1
STUB

  GH_CALLS="$st_work/gh-calls"; export GH_CALLS

  reset_branch() { git -C "$REPO" checkout -q -B probe "$BASE"; }

  # An UNAUTHENTICATED gh, for the fail-closed path. Emptying PATH would not test what it looks like
  # it tests: adb_require_gh reacts to a missing gh by prepending /opt/homebrew/bin, so on a
  # developer machine the real, authenticated gh would be found and the assertion would silently
  # pass for the wrong reason. An `auth status` that fails is both immune to that and the likelier
  # real condition.
  NOAUTH="$st_work/noauth"; mkdir -p "$NOAUTH"
  check_write_stub "$NOAUTH/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 1     # not logged in
exit 1
STUB

  # A gh that authenticates but whose READS all fail — a transport failure mid-run. The distinction
  # matters: collapsing it into "this issue does not exist" would make a network blip accuse a real
  # issue of being fabricated, which is a wrong claim produced by the tool built to stop wrong claims.
  GONE="$st_work/gone"; mkdir -p "$GONE"
  check_write_stub "$GONE/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 0
exit 1
STUB

  # A gh that authenticates, whose REPOSITORY read succeeds, and whose ENTITY read fails for a
  # query-specific reason (insufficient issue permissions, a transient GraphQL error, an unsupported
  # field). Repository reachability proves connectivity and nothing more, so this must NOT be read as
  # "the number does not exist".
  DENIED="$st_work/denied"; mkdir -p "$DENIED"
  check_write_stub "$DENIED/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 0
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then echo '{"name":"widget"}'; exit 0; fi
echo 'error: Resource not accessible by integration' >&2
exit 1
STUB

  # cc <args…> — run the lint inside the fixture repo, capturing stdout+stderr and the real status.
  cc()        { OUT="$(cd "$REPO" && PATH="$BIN:$PATH"    bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }
  cc_noauth() { OUT="$(cd "$REPO" && PATH="$NOAUTH:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }
  cc_gone()   { OUT="$(cd "$REPO" && PATH="$GONE:$PATH"   bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }
  cc_denied() { OUT="$(cd "$REPO" && PATH="$DENIED:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }

  commit() { git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1"; }

  # ------------------------------ usage / dispatch -----------------------------
  cc --help;          yes "$RC_" "--help exits 0";      has "$OUT" "claim lint" "--help prints the header"
  cc --bogus;         eq  "$RC_" 2 "unknown option exits 2"
  cc --range;         eq  "$RC_" 2 "--range without a value exits 2"
  cc --range HEAD;    eq  "$RC_" 2 "a range with no .. exits 2"
  cc --range "deadbeefdeadbeef..HEAD"; eq "$RC_" 2 "an unresolvable BASE revision exits 2"
  cc --self-test --live;              eq "$RC_" 2 "--self-test with another flag exits 2"
  cc --live --self-test;              eq "$RC_" 2 "...in either order"

  # THE REFERENCE TOKENS ARE BUILT, NEVER WRITTEN LITERALLY. These numbers are meaningful in THIS
  # repository too (150 really is closed NOT_PLANNED here, 210 really is a pull request), so a
  # literal fixture would be a claim about them. #374's path scope now also puts this file out of
  # the rule's reach — but the split stays, because a scope is a decision that can be widened and
  # this hazard would come back silently if it were. Split so no digit follows the `#`.
  REF_GONE="#""4242"
  REF_NP="#""150"
  REF_PR="#""210"
  REF_OPEN="#""7"
  REF_DONE="#""9"
  REF_ZERO="#""0"
  REF_PREFIX="#""21"      # a genuine prefix of REF_PR (210)
  D_MISSING="D""99"       # for the DROPPED decision rule, below

  # ------------------- the path scope, which is what #374 added ----------------
  # A citation in a file OUTSIDE the shipped-prose roots is not scanned, and the run SAYS how many
  # changed files it dropped for that reason — the narrowing must be visible in the log, or it is
  # indistinguishable from a range that had nothing in it.
  : > "$GH_CALLS"
  reset_branch
  printf 'Tracked in %s, which does not exist.\n' "$REF_GONE" > "$REPO/notes.md"
  printf '# Tracked in %s, which does not exist.\n' "$REF_GONE" > "$REPO/scripts/thing.sh"
  commit "a dangling citation OUTSIDE the shipped-prose roots"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "scope: a citation outside base/workflows, base/practices and templates is not scanned"
  has "$OUT" "out-of-scope=2" "scope: ...and the skipped files are COUNTED, so the narrowing is visible"
  eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 0 "scope: ...so nothing out of scope reaches the network"

  # ...and the SAME citation inside each shipped root IS caught. Three roots, three cases: a scope
  # is a list, and a list is where an entry goes missing without anything noticing.
  for root in base/workflows base/practices templates; do
    : > "$GH_CALLS"
    reset_branch
    printf 'Tracked in %s, which does not exist.\n' "$REF_GONE" > "$REPO/$root/notes.md"
    commit "a dangling citation in $root"
    cc --range "$BASE..probe" --live
    eq "$RC_" 1 "scope: the same citation in $root/ IS scanned"
    has "$OUT" "$root/notes.md:1" "scope: ...and blamed at file:line"
    rm -f "$REPO/$root/notes.md"
  done
  reset_branch

  # ------------------- the rules #374 DELIBERATELY REMOVED ---------------------
  # The owner decided on 2026-08-15 to DROP the `D<N>`-resolution and decision-date rules rather
  # than migrate them (D72). Asserted rather than merely deleted: a dangling D-reference in shipped
  # prose is now a PASS, so re-adding either rule is a deliberate act with a test to change, not a
  # silent restoration. The token is assembled from halves for the same reason as the ones above.
  reset_branch
  printf 'This paragraph cites %s, which has no heading anywhere.\n' "$D_MISSING" \
    > "$REPO/base/practices/notes.md"
  commit "a dangling decision reference"
  cc --range "$BASE..probe"
  eq "$RC_" 0 "dropped: a dangling D-reference is no longer a violation (owner decision, D72)"
  hasnt "$OUT" "d-refs=" "dropped: ...and the decision counter is gone from the report"
  hasnt "$OUT" "dates=" "dropped: ...as is the decision-date counter"
  rm -f "$REPO/base/practices/notes.md"

  # ------------------------ C1 — live issue/PR references ----------------------
  : > "$GH_CALLS"
  reset_branch
  printf 'Tracked in %s, which does not exist.\n' "$REF_GONE" > "$REPO/base/workflows/notes.md"
  commit "nonexistent reference"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "C1: a reference that does not resolve exits 1"
  has "$OUT" "$REF_GONE does not resolve" "C1: the diagnostic names the dangling number"
  has "$OUT" "acme/widget" "C1: the diagnostic names the repo the read was pinned to"

  : > "$GH_CALLS"
  reset_branch
  printf 'Superseded by %s, which tracks this work.\n' "$REF_NP" > "$REPO/base/workflows/notes.md"
  commit "not-planned reference"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "C1: a NOT_PLANNED reference exits 1"
  has "$OUT" "closed NOT_PLANNED" "C1: the diagnostic says the issue tracks nothing"
  has "$OUT" "adb-claim-ok" "C1: the diagnostic names the escape, so the remedy is discoverable"

  : > "$GH_CALLS"
  reset_branch
  printf 'See issue %s for the rationale.\n' "$REF_PR" > "$REPO/base/workflows/notes.md"
  commit "kind mismatch"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "C1: an issue-cited number resolving to a PULL REQUEST exits 1"
  has "$OUT" "resolves to a pull request" "C1: the kind mismatch is named"
  has "$OUT" "base/workflows/notes.md:1" "C1: the kind mismatch names the offending SITE"

  # BLAME IS PER SITE. A number cited correctly on one line and incorrectly on another must flag only
  # the incorrect line. The first draft aggregated every site of a mismatched number, so a correctly
  # written `PR #<n>` was accused of a neighbour's error — observed on this file's own header.
  : > "$GH_CALLS"
  reset_branch
  {
    printf 'Landed in PR %s, which is correct.\n' "$REF_PR"
    printf 'But see issue %s, which is not.\n'    "$REF_PR"
  } > "$REPO/base/workflows/notes.md"
  commit "one number, one good site and one bad"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "C1: a per-site mismatch still exits 1"
  has  "$OUT" "base/workflows/notes.md:2" "C1: blame lands on the INCORRECT line"
  hasnt "$OUT" "base/workflows/notes.md:1" "C1: the correctly-written line is NOT accused"

  # A bare number that resolves to a PR is fine — PRs are legitimate references.
  : > "$GH_CALLS"
  reset_branch
  printf 'Landed in %s and tracked by %s, and %s is done.\n' "$REF_PR" "$REF_OPEN" "$REF_DONE" \
    > "$REPO/base/workflows/notes.md"
  commit "legitimate references"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "C1: bare PR, open issue and COMPLETED issue references all pass"
  has "$OUT" "live-lookups=3" "C1: three distinct numbers cost exactly three lookups"

  # Deduplication: the same number many times is ONE network call.
  : > "$GH_CALLS"
  reset_branch
  printf '%s and %s and %s again, plus %s once more.\n' "$REF_OPEN" "$REF_OPEN" "$REF_OPEN" "$REF_OPEN" \
    > "$REPO/base/workflows/notes.md"
  commit "repeated reference"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "C1: repeated references pass"
  has "$OUT" "live-lookups=1" "C1: four occurrences of one number cost ONE lookup (dedup)"
  eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 1 "C1: the stub recorded exactly one read"

  # ------------------------------- C1 precision --------------------------------
  : > "$GH_CALLS"
  reset_branch
  {
    printf 'A fenced block declares nothing:\n\n'
    printf '```\n'
    printf 'Tracked in %s.\n' "$REF_GONE"
    printf '```\n\n'
    printf 'Nor does `%s` in a code span.\n' "$REF_GONE"
    printf 'A cross-repo reference acme/other%s belongs to a different number space.\n' "$REF_GONE"
    printf 'Neither %s nor SC1091 is an entity reference.\n' "$REF_ZERO"
  } > "$REPO/base/workflows/notes.md"
  commit "precision corpus"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "C1: fences, code spans, cross-repo forms and #0 are all excluded"
  eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 0 "C1: nothing in the precision corpus reached the network"

  # A TRANSPORT FAILURE IS NOT A MISSING ISSUE. Same fixture, same number, different gh: the entity
  # read fails AND the repository read fails, so the honest answer is "unreadable" (3), never a
  # violation claiming the reference is fabricated.
  : > "$GH_CALLS"
  reset_branch
  printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/base/workflows/notes.md"
  commit "transport failure"
  cc_gone --range "$BASE..probe" --live
  eq "$RC_" 3 "C1: a transport failure exits 3 (unreadable), NOT 1 (does not resolve)"
  hasnt "$OUT" "does not resolve" "C1: a transport failure is never reported as a fabricated number"

  # ------------------------------- fail closed ---------------------------------
  reset_branch
  printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/base/workflows/notes.md"
  commit "live without gh"
  cc_noauth --range "$BASE..probe" --live
  eq "$RC_" 3 "--live with an unauthenticated gh exits 3 (fail closed), NOT 0"
  has "$OUT" "This is NOT a pass" "the fail-closed message refuses to be read as a pass"

  # ...while the OFFLINE run over the same tree is a legitimate pass that SAYS what it skipped.
  cc_noauth --range "$BASE..probe"
  eq "$RC_" 0 "the offline run passes"
  has "$OUT" "did NOT run" "offline: the unrun half is stated, never silently skipped"
  has "$OUT" "refs=1/1" "offline: the count of unverified references is reported"

  # --------------------------- the scan is non-empty ---------------------------
  # A correctly written checker wired to an EMPTY range scans nothing and prints a clean PASS. That
  # is the silent-guard shape, so a normal invocation must be shown to have looked at real lines.
  reset_branch
  printf 'Plain prose with no citations.\n' > "$REPO/base/workflows/notes.md"
  commit "non-empty scan"
  cc --range "$BASE..probe"
  eq "$RC_" 0 "a clean range passes"
  hasnt "$OUT" "added-lines=0" "a normal run scans a NON-ZERO number of added lines"
  has "$OUT" "files=1" "the file count is reported"

  # An empty range is reported as empty rather than looking like a clean scan.
  cc --range "$BASE..$BASE"
  eq "$RC_" 0 "an empty range exits 0"
  has "$OUT" "added-lines=0" "an empty range REPORTS zero rather than hiding it"

  # ----------------------- the audited escape ----------------------------------
  reset_branch
  printf 'Tracked in %s deliberately. adb-claim-ok: a number that does not resolve.\n' "$REF_GONE" \
    > "$REPO/base/workflows/notes.md"
  commit "exempt line"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "escape: a line carrying the marker is exempt"
  has "$OUT" "exempt=1" "escape: the exemption is COUNTED, so a waiver is visible in the log"

  # A bare mention of the token waived every rule on the line, so a typo — or prose ABOUT the escape
  # — silently disabled checks it was never meant to touch. D24 states the contract; this enforces it.
  reset_branch
  printf 'Tracked in %s. adb-claim-ok\n' "$REF_GONE" > "$REPO/base/workflows/notes.md"
  commit "escape without a reason"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "escape: a bare marker with no reason does NOT waive the rule"

  # ------------------------ a non-ASCII filename must be SCANNED ---------------
  # git quotes a non-ASCII path by default while the diff yields raw bytes, so the membership test
  # failed and the file was skipped WITHOUT a word — a file the lint never looked at, reported clean.
  reset_branch
  rm -f "$REPO/base/workflows/notes.md"
  # A REAL non-ASCII name. An earlier version wrote "na\xc3\xafve.md" inside double quotes, which
  # bash does not interpret — the file was named with literal backslashes and the test exercised
  # nothing.
  printf 'Tracked in %s from a non-ASCII filename.\n' "$REF_GONE" > "$REPO/base/workflows/naïve.md"
  commit "non-ascii filename"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "path: a non-ASCII filename is SCANNED, not silently skipped"
  hasnt "$OUT" "files=0" "path: the non-ASCII file is counted as scanned"
  rm -f "$REPO/base/workflows/naïve.md"

  # ---------------------- a pure rename re-litigates nothing -------------------
  # --no-renames turned a move into a whole-file addition, so every historical line in the moved file
  # was re-checked as new — contradicting the promise never to re-litigate history.
  reset_branch
  printf 'Tracked in %s and has always been.\n' "$REF_GONE" > "$REPO/base/workflows/old-name.md"
  commit "pre-existing bad ref"
  RENBASE="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" mv base/workflows/old-name.md base/workflows/new-name.md
  commit "pure rename"
  cc --range "$RENBASE..probe" --live
  eq "$RC_" 0 "rename: a pure rename adds no lines, so old references are not re-litigated"
  reset_branch

  # --------------------------- markdown stripping edges ------------------------
  # A greedy HTML-comment strip deleted the prose BETWEEN two comments — hiding a real citation, the
  # dangerous direction. And a 4-space-indented fence is an indented code block, not a fence:
  # toggling on it hid every following line of the file.
  reset_branch
  {
    printf 'Intro.\n\n'
    printf '<!-- a --> this cites %s <!-- b -->\n' "$REF_GONE"
  } > "$REPO/base/workflows/notes.md"
  commit "two comments on one line"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "md: prose BETWEEN two HTML comments is still scanned (non-greedy strip)"

  reset_branch
  {
    printf 'Intro.\n\n'
    printf '    ```\n'
    printf '\n'
    printf 'This cites %s in ordinary prose after an INDENTED code block.\n' "$REF_GONE"
  } > "$REPO/base/workflows/notes.md"
  commit "indented fence"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "md: a 4-space-indented fence does not toggle fence state and hide the rest"

  # --------------------- the MULTI-LINE HTML comment (#251) --------------------
  # THE DEFECT #251 FILED. `cc_prose` was `sed`, and `sed` is line-based, so it could strip a comment
  # that opened and closed on ONE line and nothing else. A `#N` quoted inside a MULTI-LINE comment
  # was therefore scanned as a live citation, and `--live` would resolve it and fail CI on text that
  # is not a claim at all.
  #
  # NOT THEORETICAL: this repo writes exactly that shape. base/workflows/roadmap.md carries a
  # multi-line schema comment quoting the dependency vocabulary by example, and it was latent only
  # because the numbers it happens to quote all resolve.
  #
  # The OPENER AND CLOSER ARE IN THE BASE COMMIT and only the middle line is ADDED, which is the
  # fixture that actually pins the fix: the scan sees an added line whose containing block was opened
  # by a line it never looks at, so it can only be right if the WHOLE file is fed to the
  # paragraph-aware filter and the added-line set applied afterwards. A fixture that added the whole
  # comment at once would pass under a naive per-added-line filter too, and prove nothing.
  reset_branch
  {
    printf 'Intro.\n\n'
    printf '<!-- schema notes\n'
    printf '     PLACEHOLDER\n'
    printf '     -->\n\n'
    printf 'Ordinary prose.\n'
  } > "$REPO/base/workflows/notes.md"
  commit "a multi-line comment whose body is not yet a citation"
  MLBASE="$(git -C "$REPO" rev-parse HEAD)"
  sed "s/PLACEHOLDER/it may cite $REF_GONE as example vocabulary/" "$REPO/base/workflows/notes.md" \
    > "$REPO/base/workflows/notes.md.new"
  mv "$REPO/base/workflows/notes.md.new" "$REPO/base/workflows/notes.md"
  commit "quote a dangling number INSIDE the multi-line comment"
  : > "$GH_CALLS"
  cc --range "$MLBASE..probe" --live
  eq "$RC_" 0 "md: a #N inside a MULTI-LINE HTML comment is NOT a citation"
  has "$OUT" "refs=0/0" "md: ...it is not even collected as a reference"
  eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 0 "md: ...so --live makes no entity read at all"

  # ...and the inverse, so the fix is a STRIP and not a blanket "stop scanning after a `<!--`":
  # a real dangling reference AFTER the closer is still caught, at the right file:line.
  reset_branch
  {
    printf 'Intro.\n\n'
    printf '<!-- schema notes\n'
    printf '     spanning two lines\n'
    printf '     -->\n\n'
    printf 'This cites %s in ordinary prose after the comment.\n' "$REF_GONE"
  } > "$REPO/base/workflows/notes.md"
  commit "a dangling reference AFTER a multi-line comment"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "md: a real citation AFTER the closer is still caught"
  has "$OUT" "base/workflows/notes.md:7" "md: ...at the correct line, so the filter did not renumber the file"

  # ---------------------- RAW vs PROSE stay two views (#251) -------------------
  # check-claims deliberately keeps TWO views of every added line: the RULES read prose (a number
  # quoted in a code span is not a citation), while the EXEMPTION reads the RAW line (the marker is
  # normally a trailing comment, which in markdown may well sit inside a span). A single shared
  # stripper is how a rule was once silently disabled here — it deleted exactly the tokens that rule
  # searched for, reported zero on a commit carrying nine, and no assertion went red.
  #
  # ONE LINE carries both halves — a dangling citation OUTSIDE any span, and a valid `adb-claim-ok:`
  # marker INSIDE one. Only the two-view reading is green: collapse them and the marker vanishes with
  # the span, the exemption never fires, and the dangling number is a violation.
  reset_branch
  printf 'Tracked in %s and shows the escape as `adb-claim-ok: a quoted example`.\n' \
    "$REF_GONE" > "$REPO/base/workflows/notes.md"
  commit "the escape marker inside a code span, beside a real dangling reference"
  cc --range "$BASE..probe" --live
  eq "$RC_" 0 "views: the exemption is read from the RAW line, so a marker inside a span still waives"
  has "$OUT" "exempt=1" "views: ...and the line is reported as exempt, not merely unscanned"

  # The mirror image: with no marker anywhere, the SAME line is a violation — so the case above is
  # passing because of the exemption, not because the prose view happened to drop the reference.
  reset_branch
  printf 'Tracked in %s and shows the escape as `a quoted example`.\n' \
    "$REF_GONE" > "$REPO/base/workflows/notes.md"
  commit "the same line WITHOUT the marker"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "views: ...while the same line with no marker IS a violation"

  # --------------------- the filter is NOT optional (#251) ---------------------
  # Since the conversion the `.md` rules have no structure model of their own. A common.sh that
  # PREDATES the filter loads perfectly well and simply has no `adb_md_prose` in it.
  #
  # WHAT THE PROBE IS AND IS NOT WORTH, measured rather than asserted: removing it does NOT open a
  # raw-markdown scan — the missing function makes the filter pipeline exit 127, so the run still
  # fails closed, at 3. What the probe buys is WHERE and WHEN: exit 2 before a single file is read,
  # naming a stale library, instead of exit 3 partway through blaming "the filter failed on
  # notes.md". This fixture therefore pins the CODE, and it was witnessed going red (2 -> 3) against
  # a copy with the probe deleted. Stated exactly, because a guard whose value is a better
  # diagnostic is worth having and is not worth overclaiming.
  #
  # 2 (a broken invocation) rather than 1 (a claim is wrong), because nothing has been judged.
  reset_branch
  printf 'Plain prose with no claims.\n' > "$REPO/base/workflows/notes.md"
  commit "a benign range, to isolate the library probe"
  cp "$REPO/scripts/lib/common.sh" "$st_work/common.sh.bak"
  printf '\nunset -f adb_md_prose\n' >> "$REPO/scripts/lib/common.sh"
  cc --range "$BASE..probe"
  eq "$RC_" 2 "filter: a common.sh with no adb_md_prose is a hard failure, not a silent raw scan"
  has "$OUT" "adb_md_prose" "filter: ...and the diagnostic names the missing primitive"
  cp "$st_work/common.sh.bak" "$REPO/scripts/lib/common.sh"
  cc --range "$BASE..probe"
  eq "$RC_" 0 "filter: ...and the same range is clean once the library is whole again"

  # THE 1:1 LINE INVARIANT, which every `CC_MASK[lno - 1]` lookup rests on. Its failure mode is
  # silence: a prose view one line short reads the WRONG line for everything after it, and an empty
  # one reads "" for every line — zero references and a confident PASS.
  #
  # It cannot be driven red from an input, because the invariant holds (check-common-lib.sh pins it).
  # So it is witnessed the way this repo witnesses a forward guard: a deliberately broken filter that
  # drops a line, in the throwaway copy. Without the check, the run below PASSES while scanning the
  # wrong lines; with it, it is a named failure.
  reset_branch
  {
    printf 'Intro.\n\n'
    printf 'This cites %s in ordinary prose.\n' "$REF_GONE"
  } > "$REPO/base/workflows/notes.md"
  commit "a real violation, to prove the broken filter would HIDE it"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "1:1: the range is genuinely a violation with the filter intact"
  cp "$REPO/scripts/lib/common.sh" "$st_work/common.sh.bak"
  # Drop the LAST line of the filter's output — a renumbering no input can produce.
  printf '\nadb_md_prose() { LC_ALL=C awk "{ print \\"\\" }" | sed \x27$d\x27; }\n' \
    >> "$REPO/scripts/lib/common.sh"
  cc --range "$BASE..probe" --live
  eq "$RC_" 3 "1:1: a filter whose output is SHORT is caught, not silently scanned as empty"
  has "$OUT" "line count" "1:1: ...and the diagnostic says what is wrong"
  cp "$st_work/common.sh.bak" "$REPO/scripts/lib/common.sh"

  # A FILTER THAT FAILS OUTRIGHT is the third arm, and it is the one `adb_md_prose`'s nonce trailer
  # exists for: a killed or truncated run returns non-zero rather than a short clean result. The two
  # fixtures above cover a MISSING function and a SHORT one; this covers a present one that FAILS,
  # which is a different branch of the same `case`.
  cp "$REPO/scripts/lib/common.sh" "$st_work/common.sh.bak"
  printf '\nadb_md_prose() { return 1; }\n' >> "$REPO/scripts/lib/common.sh"
  cc --range "$BASE..probe" --live
  eq "$RC_" 3 "filter: a filter that FAILS is exit 3, not an empty prose view scanned as clean"
  has "$OUT" "markdown filter failed" "filter: ...and the diagnostic names the filter and the file"
  cp "$st_work/common.sh.bak" "$REPO/scripts/lib/common.sh"

  # AND THE ADDED-LINE SCANNER ITSELF. Its status used to be discarded by a process substitution, so
  # an awk that died mid-file arrived as zero added lines — a file never read, reported in the words
  # of a clean one. Driven here with a shim that fails ONLY `cc_scan_file`'s second awk (the one
  # invoked with a leading `-v want=`), over a NON-markdown file so the prose filter — whose own awk
  # also leads with `-v` — is never reached and cannot be what fails. `templates/` is in scope and
  # carries a non-markdown file in the real tree too, which is why the fixture lives there.
  reset_branch
  rm -f "$REPO/base/workflows/notes.md"
  printf 'Tracked in %s from a non-markdown file.\n' "$REF_GONE" > "$REPO/templates/notes.txt"
  commit "a real violation in a non-markdown file"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "scanner: the range is genuinely a violation with the scanner intact"
  cp "$REPO/scripts/lib/common.sh" "$st_work/common.sh.bak"
  printf '\nawk() { case "$1" in -v) return 3 ;; esac; command awk "$@"; }\n' \
    >> "$REPO/scripts/lib/common.sh"
  cc --range "$BASE..probe" --live
  eq "$RC_" 3 "scanner: an added-line reader that DIES is exit 3, not zero added lines reported clean"
  has "$OUT" "could not scan" "scanner: ...and the diagnostic names the file it failed on"
  cp "$st_work/common.sh.bak" "$REPO/scripts/lib/common.sh"
  rm -f "$REPO/templates/notes.txt"

  # --------------------- a kind hint needs a digit boundary --------------------
  # A short number must not be found INSIDE a longer one: with a pull-request citation for 210 on
  # the line, a bare 21 was handed 210's hint and a correct citation was reported as a kind
  # mismatch.
  : > "$GH_CALLS"
  reset_branch
  printf 'Landed in PR %s, and also see %s.\n' "$REF_PR" "$REF_PREFIX" > "$REPO/base/workflows/notes.md"
  commit "prefix hint"
  cc --range "$BASE..probe" --live
  # NOTE the quoting: this label must not contain backticks. An earlier version read a label naming
  # both numbers with backticks around one of them, inside a double-quoted string, which bash expands
  # as COMMAND SUBSTITUTION — it ran a command named PR and then blocked reading stdin. Standalone
  # the suite still passed (stdin was /dev/null); under selfcheck, whose stdin is an open pipe, it
  # hung for ten minutes. A test label is a value crossing a syntax boundary like any other.
  eq "$RC_" 0 "hint: a bare 21 beside a PR 210 citation is not given the PR hint (digit boundary)"

  # ------ review #239: a query-specific failure is UNREADABLE, not "does not exist" ------
  # An earlier version asked whether the REPOSITORY was reachable and treated success as proof the
  # number was absent. Every query-specific failure with a readable repo then became a confident
  # "does not resolve" — a tool built to stop fabricated references, fabricating them.
  : > "$GH_CALLS"
  reset_branch
  printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/base/workflows/notes.md"
  commit "entity denied, repo readable"
  cc_denied --range "$BASE..probe" --live
  eq "$RC_" 3 "C1: a query-specific read failure with a READABLE repo exits 3, not 1"
  hasnt "$OUT" "does not resolve" "C1: a permissions/transient failure is never called a missing issue"

  # ------------- review #239: the pull hint is CASE-INSENSITIVE ----------------
  # The issue hint used -i and the pull hint did not, so `Pull request #N` and `pr #N` were recorded
  # as `bare` — and a bare reference is only existence-checked, so a sentence naming the wrong entity
  # kind passed the live check outright.
  for spelling in "Pull request" "pull request" "pr" "PR"; do
    : > "$GH_CALLS"
    reset_branch
    printf 'See %s %s for context.\n' "$spelling" "$REF_OPEN" > "$REPO/base/workflows/notes.md"
    commit "hint spelling $spelling"
    cc --range "$BASE..probe" --live
    eq "$RC_" 1 "C1: '$spelling' is recognized as a pull-request hint (and 7 is an issue)"
  done

  # ------------------------------ the wiring is pinned -------------------------
  # A perfectly correct lint that nothing invokes is a lint that checks nothing, and it fails exactly
  # the way this whole mode exists to prevent: silently. So the ACTIVE invocation sites are asserted,
  # not merely the presence of the filename somewhere in the tree.
  SELFCHECK="$ROOT/scripts/selfcheck.sh"
  CI="$ROOT/.github/workflows/ci.yml"

  # ASK THE RUNNER, do not grep it (#260). selfcheck.sh no longer carries `if bash …; then` lines:
  # its steps are a REGISTRY dispatched through a `wait -n` job pool. A grep for the old shape would
  # now report "not wired" for a perfectly wired suite, and a grep for the new shape would prove only
  # that a string exists somewhere in a file — a weaker claim than the one this section is making.
  registry="$(bash "$SELFCHECK" --list 2>/dev/null)" || registry=""
  if [ -n "$registry" ]; then ok; else bad "selfcheck.sh --list produced no registry to check"; fi
  eq "$(printf '%s\n' "$registry" | awk -F'\t' '$1 == "claims" {print $2}')" \
     "bash scripts/check-claims.sh" "selfcheck.sh's registry ACTIVELY invokes check-claims.sh"
  eq "$(printf '%s\n' "$registry" | awk -F'\t' '$1 == "claims-self-test" {print $2}')" \
     "bash scripts/check-claims.sh --self-test" "selfcheck.sh's registry ACTIVELY invokes the self-test"

  # The local mirror must NOT run the live half: D13 keeps selfcheck hermetic, and a
  # network-dependent step there would make a local green stop predicting CI for every other step
  # too. Asserted on the registry AND on the file: the registry is what runs, and the file grep still
  # catches a `--live` reintroduced somewhere the registry does not reach.
  if printf '%s\n' "$registry" | grep -q -- '--live'; then
    bad "selfcheck.sh's registry runs the LIVE claim half — that breaks the hermetic-mirror promise (D13)"
  else ok; fi
  if grep -qE '^[^#]*check-claims\.sh[^#]*--live' "$SELFCHECK"; then
    bad "selfcheck.sh runs the LIVE claim half — that breaks the hermetic-mirror promise (D13)"
  else ok; fi

  # THE CI ASSERTIONS ARE SCOPED TO ONE JOB, not to the file. A whole-file `grep` for
  # `fetch-depth: 0` was VACUOUS: another job (install-migration) already carries one, so deleting it
  # from the job that actually runs the claim lint would have left this guard green while the lint
  # failed on every shallow clone. The same argument applies to the permissions and the token — they
  # only mean anything if they belong to the SAME job as the run steps.
  awk '/^  [a-z][a-z0-9_-]*:/ { injob = ($0 ~ /^  fact-drift:/) } injob { print }' "$CI" > "$ST_JOB"

  if [ -s "$ST_JOB" ]; then ok; else bad "ci.yml has no fact-drift job — the claim wiring has no home"; fi
  if grep -qE '^ *run: bash scripts/check-claims\.sh --range ' "$ST_JOB"; then ok; else
    bad "the claim-lint job does not run the offline claim lint over a range"; fi
  if grep -qE '^ *run: bash scripts/check-claims\.sh --live --range ' "$ST_JOB"; then ok; else
    bad "the claim-lint job does not run the LIVE half — the network half would run NOWHERE"; fi
  if grep -qE '^ *run: bash scripts/check-claims\.sh --self-test' "$ST_JOB"; then ok; else
    bad "the claim-lint job does not run the self-test"; fi

  # The live step needs a token and issue/PR read scope; without either it exits 3 on every run,
  # which is a red build rather than a silent pass — but a red build nobody can fix from the diff.
  # Anchored to the real YAML key. A bare substring grep also matched the COMMENT that mentions the
  # setting, so deleting the setting itself left the guard green — a pin made vacuous by the very
  # prose written to explain it.
  if grep -qE '^ +issues: read$' "$ST_JOB"; then ok; else
    bad "the claim-lint job grants no 'issues: read' — the live half cannot resolve anything"; fi
  if grep -qE '^ +pull-requests: read$' "$ST_JOB"; then ok; else
    bad "the claim-lint job grants no 'pull-requests: read' — a PR number cannot resolve"; fi
  if grep -qE '^ +GH_TOKEN:' "$ST_JOB"; then ok; else
    bad "the claim-lint job passes no GH_TOKEN — the live half would exit 3 on every run"; fi
  if grep -qE '^ +fetch-depth: 0$' "$ST_JOB"; then ok; else
    bad "the claim-lint job has no full-history checkout — base..head cannot resolve when shallow"; fi

  check_summary "check-claims --self-test"
  exit 0
fi

# --- resolve the range --------------------------------------------------------------------------
if [ -z "$RANGE" ]; then
  _cc_def="$(adb_default_branch .)"
  if git rev-parse --verify --quiet "origin/$_cc_def" >/dev/null 2>&1; then
    RANGE="origin/$_cc_def...HEAD"
  elif git rev-parse --verify --quiet "$_cc_def" >/dev/null 2>&1; then
    RANGE="$_cc_def...HEAD"
  else
    echo "check-claims: cannot resolve a default-branch base; pass --range explicitly" >&2; exit 2
  fi
fi
case "$RANGE" in
  *...*) BASEREV="${RANGE%%...*}"; HEADREV="${RANGE#*...}" ;;
  *..*)  BASEREV="${RANGE%%..*}";  HEADREV="${RANGE#*..}" ;;
  *) echo "check-claims: --range must be <base>..<head> or <base>...<head>" >&2; exit 2 ;;
esac
[ -n "$HEADREV" ] || HEADREV="HEAD"
[ -n "$BASEREV" ] || BASEREV="HEAD"
# BOTH ends are verified, and that is not symmetry for its own sake. Only the head was checked at
# first, so an unresolvable BASE — a typo, a branch that was never fetched — made every `git diff`
# below fail into a `2>/dev/null`, leaving an empty change set: zero files scanned, zero rules
# evaluated, and a confident PASS. A mistyped --range silently converted the whole gate into a
# no-op that looked exactly like a clean run. Caught by its own guard suite.
for _cc_rev in "$BASEREV" "$HEADREV"; do
  git rev-parse --verify --quiet "$_cc_rev" >/dev/null 2>&1 \
    || { echo "check-claims: unresolvable revision '$_cc_rev' in range '$RANGE'" >&2; exit 2; }
done
# And the diff itself must actually work: a range whose ends both resolve can still be rejected
# (unrelated histories, a missing merge base), which would otherwise degrade to the same silent zero.
git diff --name-only "$RANGE" >/dev/null 2>&1 \
  || { echo "check-claims: git cannot diff range '$RANGE'" >&2; exit 2; }

# THE COMMIT WALK IS GONE with the decision-date rule (#374). It needed its own range, because
# `A...B` means two different things to the two commands this script used: to `git diff` it is "from
# the merge base to B" — the branch's own added lines, which is what every line-scanning rule wants
# — while to `git rev-list` it is the SYMMETRIC DIFFERENCE, i.e. the BASE branch's commits as well.
# Nothing walks commits any more, so the distinction has no consumer left; recorded here rather than
# deleted silently, because a future rule that walks commits has to re-learn it.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
_CC_NL=$'\n'

# THE SHIPPED-PROSE SCOPE (#374). Prefixes, matched against the repo-relative path, and a trailing
# slash on each so `templates/` cannot also select a top-level `templates-old.md`. These are exactly
# the roots whose content leaves this repository: `base/practices/` renders into all three agents'
# root docs, `base/workflows/` into all three agents' skills (and symlinks into every adopter's skill
# dir), and `templates/agents.toml` is COPIED into an adopting project by `install.sh`. A citation
# anywhere else misinforms one reader of one repo; a citation here is installed everywhere.
#
# A LIST IS WHERE AN ENTRY GOES MISSING without anything noticing, so `--self-test` asserts each root
# separately rather than asserting "some in-scope file is scanned".
CC_SCOPE_ROOTS="base/workflows/ base/practices/ templates/"
cc_in_scope() {   # <path>
  local pre
  for pre in $CC_SCOPE_ROOTS; do
    case "$1" in "$pre"*) return 0 ;; esac
  done
  return 1
}

# What the run actually evaluated, REPORTED rather than inferred. A guard's failure mode is
# silence: a checker wired to an empty range scans nothing and prints exactly what a clean run
# prints. D22 is this repo paying for that once already, so every axis carries a count and a zero
# is visible in the log. `out-of-scope` is here for the same reason and is new with #374: a narrowed
# rule that never says what it narrowed away is indistinguishable from a rule that found nothing.
N_FILES=0; N_ADDED=0; N_SKIP_BIN=0; N_SKIP_PATH=0; N_SKIP_SCOPE=0
N_REF_OCC=0; N_REF_DISTINCT=0; N_REF_LOOKUPS=0
N_EXEMPT=0; N_MD_STRUCT=0

cc_violation() { check_note "$1"; check_fail; }

# --- the range's changed paths, resolved once ---------------------------------------------------
# --no-renames so a moved file surfaces BOTH paths: a claim about the path a file moved OUT of is a
# claim about this diff. -z because a tracked path may carry a space or a non-ASCII byte, which git
# would otherwise quote into a different string than the one the prose names.
CHANGED="$WORK/changed"; : > "$CHANGED"
N_SKIP_PATH=0
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  # A path containing a NEWLINE cannot survive the newline-delimited storage below, and silently
  # dropping it would be a file this lint never scanned while reporting a clean run. Counted and
  # reported instead. (No such path exists here; the point is that a zero is EARNED, not assumed.)
  case "$p" in *"$_CC_NL"*) N_SKIP_PATH=$((N_SKIP_PATH + 1)); continue ;; esac
  printf '%s\n' "$p" >> "$CHANGED"
done < <(git diff --name-only -z --diff-filter=ACMRD "$RANGE" 2>/dev/null)

# The candidate tree's file list, read once rather than per-reference.
#
# `core.quotePath=false` is load-bearing, not cosmetic. git QUOTES a non-ASCII path by default
# (`"na\303\257ve.md"`), while the diff above yields the raw bytes — so the membership test below
# failed for every such file and it was skipped WITHOUT a word. A fixture named `naïve.md` reported
# `files=0`, which is the silent-guard shape: a file the lint never looked at, reported as clean.
TREEFILES="$WORK/treefiles"
git -c core.quotePath=false ls-tree -r --name-only "$HEADREV" > "$TREEFILES" 2>/dev/null \
  || : > "$TREEFILES"

# --- files to scan (text only, git's own binary verdict is unavailable per-blob, so test it) ----
SCANLIST="$WORK/scan"; : > "$SCANLIST"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # OUT OF SCOPE is counted BEFORE the tree-membership test, deliberately: a deleted path is not a
  # skip anybody needs told about, but a file this rule declines to judge is, and counting it here
  # means the figure covers every changed path the range carried rather than only the surviving ones.
  if ! cc_in_scope "$p"; then N_SKIP_SCOPE=$((N_SKIP_SCOPE + 1)); continue; fi
  # Present in the candidate tree? A deleted path has no content to scan.
  grep -qxF "$p" "$TREEFILES" || continue
  # Binary test: a NUL byte in the first 8 KiB. Portable, and it needs no awk RS="\0" support
  # (which BWK awk on macOS does not reliably provide).
  raw="$(git show "$HEADREV:$p" 2>/dev/null | head -c 8192 | wc -c | tr -d ' ')"
  txt="$(git show "$HEADREV:$p" 2>/dev/null | head -c 8192 | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')"
  if [ "$raw" != "$txt" ]; then N_SKIP_BIN=$((N_SKIP_BIN + 1)); continue; fi
  printf '%s\n' "$p" >> "$SCANLIST"
done < "$CHANGED"

# --- every added line in the range, mapped to its file, in ONE diff ------------------------------
# ONE unrestricted diff rather than one per file, and that is a CORRECTNESS requirement rather than
# a speed one. Restricting a diff with a pathspec DESTROYS rename detection: asked only about the
# destination path, git cannot see where the content came from and reports the whole file as newly
# added. A pure `git mv` then re-presented every historical line as this branch's own work, and the
# lint re-litigated references it had no business judging — the exact whole-tree behaviour the
# added-lines scoping exists to prevent. Verified against a fixture: the unrestricted diff prints
# `rename from/to` with no hunks, the pathspec-restricted one prints `new file` and the entire body.
#
# core.quotePath=false so the paths here are the same bytes as the ones in $CHANGED and $TREEFILES.
ADDEDMAP="$WORK/added"
git -c core.quotePath=false diff --unified=0 "$RANGE" 2>/dev/null | awk '
  /^\+\+\+ / {
    line = $0; sub(/^\+\+\+ /, "", line)
    if (line == "/dev/null") { p = ""; next }
    sub(/^b\//, "", line)
    p = line; next
  }
  /^@@/ && p != "" {
    m = $3; sub(/^\+/, "", m)
    n = split(m, P, ",")
    start = P[1] + 0; cnt = (n > 1 ? P[2] + 0 : 1)
    for (i = 0; i < cnt; i++) printf "%s\t%d\n", p, start + i
  }' > "$ADDEDMAP"

# --- gh entity resolution (LIVE half) -----------------------------------------------------------
# One lookup per DISTINCT number per run, cached in a `declare -A` map. It was a directory of
# one-line files only because bash 3.2 had no associative arrays; the floor is 5.3 (#256), so the
# map is now just a map — no mkdir, no temp file per number, and no `cat` fork per read.
#
# Cached WITHIN the run only: a close reason is mutable external state, so a cache that outlived
# the invocation would be exactly the stale-state trust verify-before-asserting.md exists to
# remove. The map is a shell variable, so that property is now structural rather than a promise
# about a directory.
#
# Pinned to the checkout's own repo via git's remote, NOT gh's notion of it: GH_REPO silently
# redirects an unqualified read, and the answer is then confidently about a different project.
# adb_git_origin_slug is the one home for that anchor.
CC_SLUG=""
cc_live_init() {
  adb_require_gh jq >/dev/null 2>&1 || return 1
  CC_SLUG="$(adb_git_origin_slug)" || return 1
  [ -n "$CC_SLUG" ] || return 1
}

# cc_entity <n> — populates CC_ENT[<n>] with "<kind>\t<state>\t<extra>\t<number>", or one of the
# two sentinels `MISSING` / `UNREADABLE`.
#
# STILL CALLED BARE, never captured, and that has not changed with the map: it increments
# N_REF_LOOKUPS, and a `$( )` capture would run it in a subshell where the increment is discarded
# and the reported count is a permanent zero. `${ cc_entity "$n"; }` would in fact keep it now —
# but "populate the map, then read the map" needs no capture at all, so the safer shape is also
# the simpler one.
#
# THE READ ITSELF IS NOT HERE. It is `adb_gh_entity` in common.sh, shared with state-assert.sh —
# this file's first draft carried its own copy and had already drifted from it in three ways a
# reviewer could name: a transport failure was reported as "does not resolve", a malformed payload
# was flattened into a nonexistent entity, and the returned URL's number was never checked against
# the number asked for. That is precisely the copy-instead-of-source failure this repo treats as a
# blocking review finding, so the primitive was generalized rather than the copy patched.
declare -A CC_ENT=()
cc_entity() {
  local n="$1" rec rc
  # `+set` rather than a truth test: a cached value is never empty, but keying on emptiness would
  # re-look-up anything that ever was, which is the bug the file cache could not have.
  [ -n "${CC_ENT[$n]+set}" ] && return 0
  N_REF_LOOKUPS=$((N_REF_LOOKUPS + 1))
  rec="$(adb_gh_entity "$CC_SLUG" "$n" issue stateReason)"; rc=$?
  case "$rc" in
    0)
      # The response must be ABOUT the number that was asked for. Real gh always is, so this only
      # fires on a misbehaving or redirected read — but reporting on #9 from a payload describing
      # #146 is a wrong answer, and a wrong answer is worse than no answer.
      if [ "${ printf '%s' "$rec" | cut -f4; }" -ne "$n" ] 2>/dev/null; then
        CC_ENT["$n"]=UNREADABLE
      else
        CC_ENT["$n"]="$rec"
      fi ;;
    1) CC_ENT["$n"]=MISSING ;;
    *) CC_ENT["$n"]=UNREADABLE ;;
  esac
}

# ONLY PROSE DECLARES, and the boundary is per-file-kind rather than universal:
#   * .md — markdown fences and inline code spans are stripped. Quoting a number while documenting
#     a grammar is not a citation, and a lint that could not tell them apart would fire on this
#     repo's own docs about this repo's own checks.
#   * everything else — EVERY added line is scanned, comments INCLUDED. That is deliberate: a
#     citation written in a comment is as installed as one written in a paragraph, and `templates/`
#     is in scope precisely because a shipped config file is mostly comments.
#
# This emits the RAW line and lets each rule strip what IT should not see. The reference rule must
# not see inside a code span (quoting a number while documenting a grammar is not a citation),
# while the exemption marker must be read from the raw line because it is normally written as a
# trailing comment.
#
# The separation is kept even though the rule that most needed it — the path check, which looked
# for BACKTICKED paths — no longer ships. A single shared stripper is how that rule was silently
# disabled: it deleted exactly the tokens the rule searched for, reported `path-claims=0` on a
# commit carrying nine of them, and no assertion anywhere went red. Collapsing these two views
# again would re-create that failure for whichever rule needs the raw text next.
#
# Content comes from the range's HEAD revision, never the working tree, so an explicit --range
# scans what it names rather than whatever happens to be checked out.
cc_scan_file() {   # <file> -> "<lineno>\t<raw text>" per scannable added line
  local f="$1" lines="$WORK/ln"
  awk -F'\t' -v want="$f" '$1 == want { print $2 }' "$ADDEDMAP" | sort -n -u > "$lines"
  [ -s "$lines" ] || return 0
  # NO MARKDOWN MODEL HERE ANY MORE (#251). This used to carry a whole-file fence toggle — a
  # private parser, and a worse one than the shared filter it sat next to: it knew nothing of
  # blockquotes, HTML comments, list containers, or a closer shorter than its opener. Structure is
  # now decided once, by `cc_prose_view` below, and this function is back to what its name says.
  #
  # A STRUCTURAL LINE IS STILL EMITTED, rather than dropped as the toggle dropped a fenced one.
  # That is deliberate: the EXEMPTION is read from the raw line, so a line this function silently
  # swallowed could never be reported as exempt, and `added-lines` would quietly mean "added lines
  # that survived a parser" while reading like "added lines". Its prose view is empty, so no rule
  # can fire on it; `md-structural` below counts them.
  git show "$HEADREV:$f" 2>/dev/null | awk -v want="$lines" '
    BEGIN { while ((getline l < want) > 0) W[l + 0] = 1 }
    { if (NR in W) printf "%d\t%s\n", NR, $0 }'
}

# cc_prose_view <file> — populate CC_MASK with the shared filter`s MASK view of the WHOLE file, one
# element per line (CC_MASK[n-1] is line n). Returns non-zero if the filter could not be run.
#
# THE WHOLE FILE, NEVER THE ADDED LINES ALONE, and that is the property the multi-line-comment
# fixture actually pins. A block is opened by a line the diff may not contain: feeding only added
# lines to a paragraph-aware parser asks it to decide containment from a body with its openers cut
# out, which is the same line-at-a-time mistake in a new costume. So the file is filtered whole and
# the added-line set is applied afterwards — the ordering `cc_scan_file` already used.
#
# MASK, NOT TEXT. `MD_TEXT` leaves inline spans INTACT by design; the reference rule must not see
# inside one, so it gets the view where a resolved span is \x01. Masking rather than
# deleting is also what stops `clo`x`ses #42` collapsing into a keyword nobody wrote.
#
# FAIL LOUD, because the failure mode here is a clean-looking pass. `adb_md_prose` is fail-closed —
# its awk prints a per-invocation nonce trailer and the wrapper returns non-zero without it — so a
# killed or truncated run is a status, not a short result. Swallowing that would give every line of
# the file an empty prose view: zero references and a confident PASS. That is
# precisely the silently-disabled rule this file`s own header is about.
CC_MASK=()
cc_prose_view() {   # <file>
  local f="$1" nraw nprose
  CC_MASK=()
  # The pipeline`s status IS adb_md_prose`s (it is last), which is the one that can fail closed.
  git show "$HEADREV:$f" 2>/dev/null | adb_md_prose mask > "$WORK/prose" || return 1
  mapfile -t CC_MASK < "$WORK/prose"
  # ONE OUTPUT LINE PER INPUT LINE, ASSERTED RATHER THAN TRUSTED. Every lookup below is
  # `CC_MASK[lno - 1]`, so the whole conversion rests on that alignment — and its failure mode is
  # SILENCE, not a crash: a prose view one line short makes every subsequent lookup read the wrong
  # line, and a view that is EMPTY makes every line read "", which is zero references and a
  # confident PASS. That is indistinguishable in the log from a range with no
  # claims in it, which is the exact shape this file`s header was written about.
  #
  # The filter documents the 1:1 invariant and check-common-lib.sh pins it, so this is a FORWARD
  # guard on a contract that holds today, not a workaround for a known break — said plainly rather
  # than implying it caught something. It cost one awk and it turns a future renumbering from a
  # silent pass into a named failure.
  #
  # `awk END { print NR }` rather than `wc -l`, because a file whose last line carries no newline
  # is one line short by wc`s counting and would fail this check spuriously.
  nraw="$(git show "$HEADREV:$f" 2>/dev/null | awk 'END { print NR }')"
  nprose="${#CC_MASK[@]}"
  [ "$nraw" = "$nprose" ] || return 2
  return 0
}

# The audited escape. A line carrying this token is exempt from every rule below — greppable, so
# "what did we wave through?" is one command. It exists because a blanket NOT_PLANNED rejection is
# semantically wrong: this repo legitimately writes prose ABOUT abandoned issues, and a gate with
# no way to say so gets worked around instead of obeyed.
# The contract is `adb-claim-ok: <reason>`, and it is ENFORCED rather than described. A bare
# mention of the token waived every rule on the line, so a typo — or the word appearing in prose
# about the escape — silently disabled the checks it was never meant to touch.
CC_EXEMPT_RE='adb-claim-ok:[[:space:]]*[^[:space:]]'

# ================================ scan ==========================================================
REFS="$WORK/refs"; : > "$REFS"    # "<n>\t<file>:<line>\t<kind-hint>"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  N_FILES=$((N_FILES + 1))
  # The prose view is resolved ONCE PER FILE, before any line of it is read — the filter is
  # paragraph-aware and needs the whole body.
  CC_IS_MD=0
  case "$f" in
    *.md)
      CC_IS_MD=1
      cc_prose_view "$f"; _cc_pv=$?
      case "$_cc_pv" in
        0) : ;;
        2) echo "check-claims: FATAL — the prose view of '$f' has a different line count than the file." >&2
           echo "              Every lookup is by line number, so this is NOT a pass: it would silently" >&2
           echo "              scan the wrong lines, or none at all." >&2
           exit 3 ;;
        *) echo "check-claims: FATAL — the shared markdown filter failed on '$f'. This is NOT a pass:" >&2
           echo "              with no prose view every rule below would scan nothing and report clean." >&2
           exit 3 ;;
      esac ;;
  esac
  # MATERIALIZED, not piped. `done < <(cc_scan_file "$f")` discards the scanner`s exit status, so an
  # awk that died mid-file arrived as zero added lines — a file this lint never read, reported in
  # the same words a clean file uses. Same fail-open shape as the filter guard above, one line up
  # the pipe, and it is fixed here because this conversion is what made the scan path load-bearing.
  cc_scan_file "$f" > "$WORK/scanned" || {
    echo "check-claims: FATAL — could not scan '$f' (the added-line reader failed). This is NOT a pass." >&2
    exit 3
  }
  while IFS=$'\t' read -r lno raw; do
    [ -n "$lno" ] || continue
    N_ADDED=$((N_ADDED + 1))
    # The exemption is read from the RAW line: the marker is normally written as a trailing
    # comment, which for a markdown file may well sit inside a code span.
    if printf '%s' "$raw" | grep -qE "$CC_EXEMPT_RE"; then
      N_EXEMPT=$((N_EXEMPT + 1)); continue
    fi
    # THE TWO VIEWS, and the separation is the point (see cc_prose_view). The rules read the
    # filter`s MASK view of this line; the exemption above read the RAW one.
    #
    # NO `-` DEFAULT ON THIS LOOKUP, deliberately. An earlier cut wrote `${CC_MASK[lno - 1]-}` and
    # justified it as "correct for a trailing structural line" — which is simply false: the filter
    # emits an EMPTY RECORD for every structural line, at its own index, and `mapfile` keeps it.
    # So an out-of-range index cannot happen while the 1:1 invariant holds, and cannot mean
    # anything good if it ever does. The default would have turned that into "" — silently
    # scanning nothing, which is this file`s signature failure. Bare, `set -u` makes it an
    # unbound-variable abort instead: loud, at the exact index that broke.
    if [ "$CC_IS_MD" -eq 1 ]; then
      text="${CC_MASK[lno - 1]}"
      [ -n "$text" ] || N_MD_STRUCT=$((N_MD_STRUCT + 1))
    else
      text="$raw"
    fi

    # --- C1: collect issue/PR references (resolved later, in one deduplicated live pass) --------
    # `#` must not be preceded by a word character or `/`, which excludes `owner/repo#123` — a
    # DIFFERENT repository's number space, where resolving against this origin would confidently
    # validate the wrong entity. `[1-9][0-9]*` excludes `#0`.
    for n in $(printf '%s\n' "$text" | grep -oE '(^|[^A-Za-z0-9_/#])#[1-9][0-9]*' | grep -oE '[0-9]+$'); do
      N_REF_OCC=$((N_REF_OCC + 1))
      # The kind hint needs a DIGIT BOUNDARY after the number, which a glob cannot express: a glob
      # found the shorter number inside the longer one and handed it the wrong hint. Numbers are
      # safe to interpolate into the pattern — the extraction above guarantees digits only.
      #
      # BOTH spellings are recorded when both appear, rather than the first one winning. One line
      # can carry a correct citation and an incorrect one for the SAME number, and an if/elif gave
      # them a single verdict — so the wrong half was covered by the right half and passed.
      # Emitting one record per spelling lets the resolver flag exactly the spelling that is wrong.
      #
      # BOTH hints are matched CASE-INSENSITIVELY, and the asymmetry that existed here was a real
      # hole rather than a cosmetic one: the issue hint used -i and the pull hint did not, so
      # `Pull request #N` and `pr #N` were recorded as `bare`. A bare reference is only checked for
      # EXISTENCE, so a sentence explicitly naming the wrong entity kind passed the live check.
      got=0
      if printf '%s' "$text" | grep -qiE "(PR|pull request) ?#$n([^0-9]|$)"; then
        printf '%s\t%s:%s\tpull\n' "$n" "$f" "$lno" >> "$REFS"; got=1
      fi
      if printf '%s' "$text" | grep -qiE "issue #$n([^0-9]|$)"; then
        printf '%s\t%s:%s\tissue\n' "$n" "$f" "$lno" >> "$REFS"; got=1
      fi
      [ "$got" -eq 1 ] || printf '%s\t%s:%s\tbare\n' "$n" "$f" "$lno" >> "$REFS"
    done

    # --- (the D<N> rule was DROPPED by #374, and the path-claim check never lived here) ---------
    # The decision-reference rule read `.ai-dev-baseline/decisions.md`, which `install.sh` does not
    # ship and no workflow reads: it protected one maintainer from a D-number mix-up. The owner
    # decided on 2026-08-15 to drop rather than migrate it (D72). `--self-test` asserts the absence,
    # so restoring it is a deliberate act with a test to change.
  done < "$WORK/scanned"
done < "$SCANLIST"

# --- C1, resolved in one deduplicated pass ------------------------------------------------------
N_REF_DISTINCT="$(awk -F'\t' '{print $1}' "$REFS" 2>/dev/null | sort -u | grep -c . || true)"
if [ "$LIVE" -eq 1 ] && [ "$N_REF_DISTINCT" -eq 0 ]; then
  check_note "NOTE: --live had no references to resolve in this range."
elif [ "$LIVE" -eq 1 ]; then
  if ! cc_live_init; then
    # FAIL CLOSED. --live was asked for and could not be delivered; reporting a pass here would be
    # the silent no-op that design-principles separates from a legitimate degrade.
    echo "check-claims: FATAL — --live requested but gh/jq is unavailable, unauthenticated, or the" >&2
    echo "              origin repository could not be resolved. This is NOT a pass." >&2
    exit 3
  fi
  for n in $(awk -F'\t' '{print $1}' "$REFS" | sort -un); do
    cc_entity "$n"
    ent="${CC_ENT[$n]}"
    kind="${ printf '%s' "$ent" | cut -f1; }"
    st="${ printf '%s' "$ent" | cut -f2; }"
    rs="${ printf '%s' "$ent" | cut -f3; }"
    sites="$(awk -F'\t' -v k="$n" '$1==k{print $2}' "$REFS" | sort -u | tr '\n' ' ')"
    # "DOES NOT EXIST" AND "COULD NOT BE READ" ARE DIFFERENT ANSWERS and are reported as such. The
    # first draft collapsed them, so a transport failure mid-run accused a perfectly real issue of
    # being fabricated — a wrong claim produced by the tool built to stop wrong claims. Unreadable
    # is fatal (exit 3) rather than a violation, because the honest state is "I could not tell".
    case "$ent" in
      UNREADABLE)
        echo "check-claims: FATAL — #$n could not be read from $CC_SLUG (transport, auth or a" >&2
        echo "              malformed response). This is NOT a pass, and NOT a missing issue." >&2
        exit 3 ;;
      MISSING)
        cc_violation "#$n does not resolve in $CC_SLUG (cited at: $sites)"
        continue ;;
    esac
    # A citation that DECLARES its kind must match it. `gh issue view` answers for a PR number too,
    # so naming a pull request as an issue is a wrong claim that bare existence waves through.
    # adb-claim-ok: the comment above describes the rule; it is not itself a citation.
    #
    # Blame is per SITE, not per number. An earlier draft reported every site of a number whose
    # hint mismatched anywhere, which accused correctly-written lines of a neighbour's error — it
    # flagged this file's own correctly-written pull-request citation because a DIFFERENT line
    # quoted the wrong spelling as an example. A diagnostic that names an innocent line is one
    # the reader learns to distrust.
    awk -F'\t' -v k="$n" '$1==k && $3!="bare" {print $3 "\t" $2}' "$REFS" | sort -u \
      | while IFS=$'\t' read -r hint site; do
          [ "$hint" = "$kind" ] && continue
          case "$hint" in
            issue) printf 'ISSUE\t%s\n' "$site" ;;
            pull)  printf 'PULL\t%s\n'  "$site" ;;
          esac
        done > "$WORK/kindbad"
  while IFS=$'\t' read -r want site; do
      [ -n "$site" ] || continue
      case "$want" in
        ISSUE) cc_violation "#$n is cited as an issue at $site, but it resolves to a pull request" ;;
        PULL)  cc_violation "#$n is cited as a PR at $site, but it resolves to an issue" ;;
      esac
    done < "$WORK/kindbad"
    # NOT_PLANNED means the work was ABANDONED. Citing it as tracking reads a cancelled requirement
    # as a satisfied one. Legitimate historical prose about such an issue carries the audited
    # marker instead of being silently allowed.
    if [ "$kind" = "issue" ] && [ "$st" = "CLOSED" ] && [ "$rs" = "NOT_PLANNED" ]; then
      cc_violation "#$n was closed NOT_PLANNED — it tracks nothing (at: $sites). If the reference is deliberately historical, mark the line 'adb-claim-ok: <reason>'."
    fi
  done
else
  check_note "NOTE: the issue/PR-reference check did NOT run ($N_REF_DISTINCT distinct reference(s) unverified)."
  check_note "NOTE: it needs the network, so it is a CI-only step — selfcheck stays hermetic (D13)."
  check_note "NOTE: run 'bash scripts/check-claims.sh --live' to resolve them by hand."
fi

# --- what this run actually evaluated -----------------------------------------------------------
# `md-structural` is new with #251 and is not decoration: it is the count of NON-EXEMPT added
# markdown lines whose PROSE VIEW IS EMPTY — a fence body, a blockquote, indented code, an HTML
# comment, and also an ordinary BLANK line, which resolves to nothing for the same reason and is
# not worth a second counter to separate. "Non-exempt" is exact rather than incidental: an
# `adb-claim-ok:` line returns above this point and is counted by `exempt` alone, so the two
# figures never double-count the same line.
# Before the conversion the fenced ones were dropped inside the scanner, so
# `added-lines` read like "added lines" while meaning "added lines a private parser let through".
# Reporting both keeps D22's rule honest: a run that suddenly strips far more than it used to is
# now visible in the log rather than indistinguishable from a range with fewer claims in it.
#
# `out-of-scope` is #374's addition and carries that duty one level up: this rule now declines to
# judge most of the tree, and a narrowed rule that never says what it narrowed away reads exactly
# like a rule that found nothing. `d-refs` and `dates` are gone with the rules that produced them.
printf 'check-claims: range=%s files=%d added-lines=%d md-structural=%d refs=%s/%d live-lookups=%d exempt=%d binary-skipped=%d path-skipped=%d out-of-scope=%d\n' \
  "$RANGE" "$N_FILES" "$N_ADDED" "$N_MD_STRUCT" "$N_REF_DISTINCT" "$N_REF_OCC" "$N_REF_LOOKUPS" \
  "$N_EXEMPT" "$N_SKIP_BIN" "$N_SKIP_PATH" "$N_SKIP_SCOPE"

check_result "no unverified claims in the range"
