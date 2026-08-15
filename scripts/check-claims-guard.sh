#!/usr/bin/env bash
# ai-dev-baseline — the negative suite for the claim lint (issue #212).
# OFFLINE: no network, no gh auth, no real repository is touched.
#
# A GUARD'S FAILURE MODE IS SILENCE. Ordinary code that breaks throws; a guard that breaks PASSES —
# it scans zero files, matches zero lines, and prints exactly what a clean run prints. So every rule
# in check-claims.sh is driven to RED here against an input it is supposed to reject, and the
# assertion is on the DESIGNATED exit code and diagnostic, never on "some non-zero" (a crash also
# exits non-zero, and would otherwise be indistinguishable from a working rule).
#
# This is not hypothetical for this very file's subject. While check-claims.sh was being written,
# its markdown stripper removed inline code spans before the path-claim rule looked for backticked
# paths, so that rule was structurally incapable of firing. It reported `path-claims=0` on a commit
# carrying nine of them and no assertion anywhere went red. It was found by RUNNING it against real
# history and disbelieving a zero — which is exactly what D22 says to build a harness for.
#
# Fixtures are built in a throwaway git repo under mktemp, never in the working tree. Editing a
# tracked file to test a check that reads tracked files is how ~40 minutes of uncommitted work was
# destroyed once already (base/practices/self-review.md).
#
# Usage: bash scripts/check-claims-guard.sh   (exit 0 = all pass, 1 = a failure)

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
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary + check_exit_guard

work="$(mktemp -d)"
WORK_JOB="$work/ci-job"
check_exit_guard "check-claims-guard" "rm -rf \"$work\""

# ---------------------------------------------------------------------------------------------
# A throwaway repo that LOOKS like a baseline checkout: check-claims.sh resolves its own root with
# `cd "$(dirname "$0")/.."` and sources scripts/check-lib.sh + scripts/lib/common.sh from there, so
# the fixture needs that shape rather than a bare directory.
# ---------------------------------------------------------------------------------------------
REPO="$work/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/.ai-dev-baseline"
cp "$ROOT/scripts/check-claims.sh" "$REPO/scripts/"
cp "$ROOT/scripts/check-lib.sh"    "$REPO/scripts/"
cp "$ROOT/scripts/lib/common.sh"   "$REPO/scripts/lib/"

# The throwaway repo + its `origin` URL come from check-lib.sh — the same scaffold the PR suites build.
check_make_stub_repo "$REPO" https://github.com/acme/widget.git || {
  echo "check-claims-guard: FATAL — could not build the fixture repo" >&2; exit 1; }

# The decision log the D-reference rule resolves against. D1 and D2 exist; nothing else does.
cat > "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'
# Decision log

## D1 — the first decision
- date:      2026-01-01

## D2 — the second decision
- date:      2026-01-02
EOF
printf 'seed\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

# ---------------------------------------------------------------------------------------------
# A recording gh stub. It answers `gh issue view <n> --repo <slug> --json …` from a table, so every
# entity SHAPE the live rule must distinguish is reproducible offline:
#   4242 -> unresolvable        150 -> issue CLOSED/NOT_PLANNED
#   7,21 -> issue OPEN          210 -> PULL REQUEST (the shared number space; 21 is a
#                                     deliberate PREFIX of 210, for the hint-boundary test)
#   9    -> issue CLOSED/COMPLETED
# ---------------------------------------------------------------------------------------------
BIN="$work/bin"; mkdir -p "$BIN"
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

GH_CALLS="$work/gh-calls"; export GH_CALLS

# commit_fixture <file> <<'EOF' … — replace the branch with one commit adding <content> to <file>,
# so each scenario is an isolated one-commit range. `--date` is left to git: C4's own scenarios set
# the commit date explicitly.
reset_branch() {
  git -C "$REPO" checkout -q -B probe "$BASE"
}

# An UNAUTHENTICATED gh, for the fail-closed path. Emptying PATH would not test what it looks like
# it tests: adb_require_gh reacts to a missing gh by prepending /opt/homebrew/bin, so on a developer
# machine the real, authenticated gh would be found and the assertion would silently pass for the
# wrong reason. An `auth status` that fails is both immune to that and the likelier real condition.
NOAUTH="$work/noauth"; mkdir -p "$NOAUTH"
check_write_stub "$NOAUTH/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 1     # not logged in
exit 1
STUB

# A gh that authenticates but whose READS all fail — a transport failure mid-run. The distinction
# matters: collapsing it into "this issue does not exist" would make a network blip accuse a real
# issue of being fabricated, which is a wrong claim produced by the tool built to stop wrong claims.
GONE="$work/gone"; mkdir -p "$GONE"
check_write_stub "$GONE/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 0
exit 1
STUB
cc_gone() { OUT="$(cd "$REPO" && PATH="$GONE:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }

# A gh that authenticates, whose REPOSITORY read succeeds, and whose ENTITY read fails for a
# query-specific reason (insufficient issue permissions, a transient GraphQL error, an unsupported
# field). Repository reachability proves connectivity and nothing more, so this must NOT be read as
# "the number does not exist".
DENIED="$work/denied"; mkdir -p "$DENIED"
check_write_stub "$DENIED/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 0
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then echo '{"name":"widget"}'; exit 0; fi
echo 'error: Resource not accessible by integration' >&2
exit 1
STUB
cc_denied() { OUT="$(cd "$REPO" && PATH="$DENIED:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }

# cc <args…> — run the lint inside the fixture repo, capturing stdout+stderr and the real status.
cc() { OUT="$(cd "$REPO" && PATH="$BIN:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }
# cc_noauth — same, with a gh that is present but not authenticated.
cc_noauth() { OUT="$(cd "$REPO" && PATH="$NOAUTH:$PATH" bash scripts/check-claims.sh "$@" 2>&1)"; RC_=$?; }

commit() { git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1"; }

# =============================== usage / dispatch ==============================================
cc --help;          yes "$RC_" "--help exits 0";      has "$OUT" "claim lint" "--help prints the header"
cc --bogus;         eq  "$RC_" 2 "unknown option exits 2"
cc --range;         eq  "$RC_" 2 "--range without a value exits 2"
cc --range HEAD;    eq  "$RC_" 2 "a range with no .. exits 2"
cc --range "deadbeefdeadbeef..HEAD"; eq "$RC_" 2 "an unresolvable BASE revision exits 2"

# ---------------------------------------------------------------------------------------------
# THE DANGLING TOKENS ARE BUILT, NEVER WRITTEN LITERALLY — and this file is the reason the rule
# exists. check-claims.sh scans the added lines of tracked files, and this suite IS a tracked file,
# so a literal dangling `D`+`99` in a fixture below is a dangling reference in the repository and
# the lint rightly fails its own introducing commit. That is the bootstrap hazard, and it has
# exactly one correct fix.
#
# The obvious one is wrong: putting the `adb-claim-ok` marker on the fixture line would ALSO put it
# into the fixture file the line writes, exempting the very line under test and turning the
# assertion green while checking nothing. Broadly excluding this file is worse — it would blind the
# lint to every real claim the suite ever grows.
#
# So the token is assembled from halves. `"D""99"` reads as D-99 to a human and matches nothing:
# the grammar needs a digit immediately after the D, and here a quote sits there. The fixtures are
# then written with printf rather than a quoted heredoc, which is what lets the value expand.
# ---------------------------------------------------------------------------------------------
D_MISSING="D""99"
D_MISSING2="D""77"
D_MISSING3="D""98"

# =============================== C2 — decision references ======================================
reset_branch
printf 'This paragraph cites %s, which has no heading anywhere.\n' "$D_MISSING" > "$REPO/notes.md"
commit "cite a missing decision"
cc --range "$BASE..probe"
eq "$RC_" 1 "C2: a dangling D-reference exits 1 (the designated violation code)"
has "$OUT" "cites $D_MISSING" "C2: the diagnostic names the dangling decision"
has "$OUT" "notes.md:1" "C2: the diagnostic names file:line"

# ...and the SAME defect in a SHELL COMMENT, which is where the real one was. A rule that discarded
# comments would be green here, and that is one of the four claims this lint exists for.
reset_branch
{
  printf '#!/usr/bin/env bash\n'
  printf '# The reviewer-identity rule (recorded as %s) is applied here.\n' "$D_MISSING2"
  printf 'echo hi\n'
} > "$REPO/lib.sh"
commit "cite a missing decision in a shell comment"
cc --range "$BASE..probe"
eq "$RC_" 1 "C2: a dangling D-reference inside a SHELL COMMENT still exits 1"
has "$OUT" "cites $D_MISSING2" "C2: the shell-comment diagnostic names the decision"

# A decision ADDED BY THE SAME RANGE resolves: the candidate tree is the authority, not the base.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — a decision added by this very range
- date:      2026-01-03
EOF
cat > "$REPO/notes.md" <<'EOF'
This cites D3, which this range adds.
EOF
commit "add D3 and cite it"
GIT_COMMITTER_DATE="2026-01-03T12:00:00Z" git -C "$REPO" commit -q --amend --no-edit --date="2026-01-03T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 0 "C2: a decision added by the same range resolves (exit 0)"

# Whole-token matching: an existing D1 heading must not satisfy a citation of D18.
reset_branch
cat > "$REPO/notes.md" <<'EOF'
This cites D18 while only D1 and D2 exist.
EOF
commit "prefix must not satisfy"
cc --range "$BASE..probe"
eq "$RC_" 1 "C2: D18 is not satisfied by the existing D1 heading"

# =============================== C2 precision — only prose declares ============================
reset_branch
{
  printf 'Inside a fence, nothing declares:\n\n'
  printf '```\n'
  printf '%s appears here and must not be checked.\n' "$D_MISSING"
  printf '```\n\n'
  printf 'And `%s` in a code span must not be checked either.\n' "$D_MISSING3"
} > "$REPO/notes.md"
commit "fenced and code-span D-refs"
cc --range "$BASE..probe"
eq "$RC_" 0 "C2: a D-reference inside a fence or a code span does not fire"

# =============================== the audited escape ============================================
reset_branch
printf 'This cites %s deliberately. adb-claim-ok: a decision id that does not exist.\n' \
  "$D_MISSING" > "$REPO/notes.md"
commit "exempt line"
cc --range "$BASE..probe"
eq "$RC_" 0 "escape: a line carrying the marker is exempt"
has "$OUT" "exempt=1" "escape: the exemption is COUNTED, so a waiver is visible in the log"

# =============================== C4 — decision dates ===========================================
# Two days behind its own commit.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — stale stamp
- date:      2026-03-01
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-03T12:00:00Z" git -C "$REPO" commit -q -m "stale date" --date="2026-03-03T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: a date two days behind its commit exits 1"
has "$OUT" "is 2 days from its commit date" "C4: the diagnostic states the distance"

# A day AHEAD of its own commit — the #173 shape, and the direction a one-sided rule would miss.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — future stamp
- date:      2026-03-05
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-01T12:00:00Z" git -C "$REPO" commit -q -m "future date" --date="2026-03-01T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: a date FOUR days in the future exits 1 (the tolerance is absolute, not one-sided)"

# Exactly one day either side is within tolerance.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — one day early
- date:      2026-03-02
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-03T12:00:00Z" git -C "$REPO" commit -q -m "one day" --date="2026-03-03T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 0 "C4: one day of slack is allowed (boundary)"
has "$OUT" "dates=1" "C4: the date actually scanned is counted"

# A month boundary must not read as a 27-day gap. 2026 is not a leap year, so 2026-02-28 is
# exactly ONE day before 2026-03-01 — while a naive day-of-month subtraction gives |1 - 28| = 27
# and would reject a perfectly ordinary end-of-month entry. This is the civil-day conversion
# earning its place.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — across a month boundary
- date:      2026-02-28
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-01T12:00:00Z" git -C "$REPO" commit -q -m "month boundary" --date="2026-03-01T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 0 "C4: 2026-02-28 is one day before 2026-03-01, not 27 (month-boundary arithmetic)"
hasnt "$OUT" "days from its commit date" "C4: no violation is reported across the month boundary"

# The SAME construction as the D-tokens above, for the same reason: these numbers are meaningful in
# THIS repository too (150 really is closed NOT_PLANNED here, 210 really is a pull request), so a
# literal fixture would make the live half fail on its own suite. Split so no digit follows the `#`.
REF_GONE="#""4242"
REF_NP="#""150"
REF_PR="#""210"
REF_OPEN="#""7"
REF_DONE="#""9"
REF_ZERO="#""0"
REF_PREFIX="#""21"      # a genuine prefix of REF_PR (210)

# =============================== C1 — live issue/PR references =================================
: > "$GH_CALLS"
reset_branch
printf 'Tracked in %s, which does not exist.\n' "$REF_GONE" > "$REPO/notes.md"
commit "nonexistent reference"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: a reference that does not resolve exits 1"
has "$OUT" "$REF_GONE does not resolve" "C1: the diagnostic names the dangling number"
has "$OUT" "acme/widget" "C1: the diagnostic names the repo the read was pinned to"

: > "$GH_CALLS"
reset_branch
printf 'Superseded by %s, which tracks this work.\n' "$REF_NP" > "$REPO/notes.md"
commit "not-planned reference"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: a NOT_PLANNED reference exits 1"
has "$OUT" "closed NOT_PLANNED" "C1: the diagnostic says the issue tracks nothing"
has "$OUT" "adb-claim-ok" "C1: the diagnostic names the escape, so the remedy is discoverable"

: > "$GH_CALLS"
reset_branch
printf 'See issue %s for the rationale.\n' "$REF_PR" > "$REPO/notes.md"
commit "kind mismatch"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: an issue-cited number resolving to a PULL REQUEST exits 1"
has "$OUT" "resolves to a pull request" "C1: the kind mismatch is named"
has "$OUT" "notes.md:1" "C1: the kind mismatch names the offending SITE"

# BLAME IS PER SITE. A number cited correctly on one line and incorrectly on another must flag only
# the incorrect line. The first draft aggregated every site of a mismatched number, so a correctly
# written `PR #<n>` was accused of a neighbour's error — observed on check-claims.sh's own header.
: > "$GH_CALLS"
reset_branch
{
  printf 'Landed in PR %s, which is correct.\n' "$REF_PR"
  printf 'But see issue %s, which is not.\n'    "$REF_PR"
} > "$REPO/notes.md"
commit "one number, one good site and one bad"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: a per-site mismatch still exits 1"
has  "$OUT" "notes.md:2" "C1: blame lands on the INCORRECT line"
hasnt "$OUT" "notes.md:1" "C1: the correctly-written line is NOT accused"

# A bare number that resolves to a PR is fine — PRs are legitimate references.
: > "$GH_CALLS"
reset_branch
printf 'Landed in %s and tracked by %s, and %s is done.\n' "$REF_PR" "$REF_OPEN" "$REF_DONE" > "$REPO/notes.md"
commit "legitimate references"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: bare PR, open issue and COMPLETED issue references all pass"
has "$OUT" "live-lookups=3" "C1: three distinct numbers cost exactly three lookups"

# Deduplication: the same number many times is ONE network call.
: > "$GH_CALLS"
reset_branch
printf '%s and %s and %s again, plus %s once more.\n' "$REF_OPEN" "$REF_OPEN" "$REF_OPEN" "$REF_OPEN" > "$REPO/notes.md"
commit "repeated reference"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: repeated references pass"
has "$OUT" "live-lookups=1" "C1: four occurrences of one number cost ONE lookup (dedup)"
eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 1 "C1: the stub recorded exactly one read"

# =============================== C1 precision ==================================================
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
} > "$REPO/notes.md"
commit "precision corpus"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: fences, code spans, cross-repo forms and #0 are all excluded"
eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 0 "C1: nothing in the precision corpus reached the network"

# A TRANSPORT FAILURE IS NOT A MISSING ISSUE. Same fixture, same number, different gh: the entity
# read fails AND the repository read fails, so the honest answer is "unreadable" (3), never a
# violation claiming the reference is fabricated.
: > "$GH_CALLS"
reset_branch
printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/notes.md"
commit "transport failure"
cc_gone --range "$BASE..probe" --live
eq "$RC_" 3 "C1: a transport failure exits 3 (unreadable), NOT 1 (does not resolve)"
hasnt "$OUT" "does not resolve" "C1: a transport failure is never reported as a fabricated number"

# =============================== fail closed ===================================================
reset_branch
printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/notes.md"
commit "live without gh"
cc_noauth --range "$BASE..probe" --live
eq "$RC_" 3 "--live with an unauthenticated gh exits 3 (fail closed), NOT 0"
has "$OUT" "This is NOT a pass" "the fail-closed message refuses to be read as a pass"

# ...while the OFFLINE run over the same tree is a legitimate pass that SAYS what it skipped.
cc_noauth --range "$BASE..probe"
eq "$RC_" 0 "the offline run passes"
has "$OUT" "did NOT run" "offline: the unrun half is stated, never silently skipped"
has "$OUT" "refs=1/1" "offline: the count of unverified references is reported"

# =============================== the scan is non-empty =========================================
# A correctly written checker wired to an EMPTY range scans nothing and prints a clean PASS. That
# is the silent-guard shape, so a normal invocation must be shown to have looked at real lines.
reset_branch
cat > "$REPO/notes.md" <<'EOF'
Plain prose citing D1.
EOF
commit "non-empty scan"
cc --range "$BASE..probe"
eq "$RC_" 0 "a clean range passes"
hasnt "$OUT" "added-lines=0" "a normal run scans a NON-ZERO number of added lines"
has "$OUT" "files=1" "the file count is reported"

# An empty range is reported as empty rather than looking like a clean scan.
cc --range "$BASE..$BASE"
eq "$RC_" 0 "an empty range exits 0"
has "$OUT" "added-lines=0" "an empty range REPORTS zero rather than hiding it"

# =============================== C4: the field must be a REAL date ==============================
# `- date: TBD` used to be skipped by a `[ -n "$d" ] || continue`, so a decision with no date at all
# passed with `dates=0` — a rule reporting that it checked nothing, in the words of a clean run.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — no date at all
- date:      TBD
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-05-01T12:00:00Z" git -C "$REPO" commit -q -m "no date" --date="2026-05-01T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: a date: field with no YYYY-MM-DD value exits 1"
has "$OUT" "carries no YYYY-MM-DD" "C4: the diagnostic says the field has no date"
hasnt "$OUT" "dates=0" "C4: the unparseable field is COUNTED, not silently skipped"

# An impossible date matches the pattern and is normalized by the civil-day arithmetic: 2026-02-30
# becomes March 2 and would pass against a March commit. It must be rejected as a date, not scored.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — impossible date
- date:      2026-02-30
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-02T12:00:00Z" git -C "$REPO" commit -q -m "impossible" --date="2026-03-02T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: an impossible calendar date exits 1 even when normalization would pass it"
has "$OUT" "not a real calendar date" "C4: the diagnostic names the impossibility"

# =============================== C4: a MERGE commit can introduce a line =======================
# --no-merges looks obviously right and is wrong: this project merges the default branch INTO a
# feature branch, and a conflict resolution inside that merge can introduce a date line present in
# no parent. Skipping merges left it checked by nothing.
git -C "$REPO" checkout -q -B mergeside "$BASE"
printf 'side\n' > "$REPO/side.md"
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-06-01T12:00:00Z" git -C "$REPO" commit -q -m "side" --date="2026-06-01T12:00:00Z"
git -C "$REPO" checkout -q -B probe "$BASE"
printf 'trunk\n' > "$REPO/trunk.md"
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-06-01T12:00:00Z" git -C "$REPO" commit -q -m "trunk" --date="2026-06-01T12:00:00Z"
git -C "$REPO" merge -q --no-ff --no-commit mergeside >/dev/null 2>&1 || true
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — introduced by the merge itself
- date:      2026-12-25
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-06-01T12:00:00Z" git -C "$REPO" commit -q -m "merge" --date="2026-06-01T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: a date introduced BY a merge commit is still checked"
has "$OUT" "2026-12-25" "C4: the merge-introduced date is named"
git -C "$REPO" checkout -q -B probe "$BASE"

# =============================== a non-ASCII filename must be SCANNED ==========================
# git quotes a non-ASCII path by default while the diff yields raw bytes, so the membership test
# failed and the file was skipped WITHOUT a word — a file the lint never looked at, reported clean.
reset_branch
# A REAL non-ASCII name. An earlier version wrote "na\xc3\xafve.md" inside double quotes, which bash
# does not interpret — the file was named with literal backslashes and the test exercised nothing.
printf 'This cites %s from a non-ASCII filename.\n' "$D_MISSING" > "$REPO/naïve.md"
commit "non-ascii filename"
cc --range "$BASE..probe"
eq "$RC_" 1 "path: a non-ASCII filename is SCANNED, not silently skipped"
hasnt "$OUT" "files=0" "path: the non-ASCII file is counted as scanned"

# =============================== a pure rename re-litigates nothing ============================
# --no-renames turned a move into a whole-file addition, so every historical line in the moved file
# was re-checked as new — contradicting the promise never to re-litigate history.
reset_branch
printf 'This cites %s and has always done so.\n' "$D_MISSING" > "$REPO/old-name.md"
GIT_COMMITTER_DATE="2026-04-01T12:00:00Z" git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-04-01T12:00:00Z" git -C "$REPO" commit -q -m "pre-existing bad ref" --date="2026-04-01T12:00:00Z"
RENBASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" mv old-name.md new-name.md
commit "pure rename"
cc --range "$RENBASE..probe"
eq "$RC_" 0 "rename: a pure rename adds no lines, so old references are not re-litigated"
git -C "$REPO" checkout -q -B probe "$BASE"

# =============================== the escape must carry a REASON ================================
# A bare mention of the token waived every rule on the line, so a typo — or prose ABOUT the escape —
# silently disabled checks it was never meant to touch. D24 states the contract; this enforces it.
reset_branch
printf 'This cites %s. adb-claim-ok\n' "$D_MISSING" > "$REPO/notes.md"
commit "escape without a reason"
cc --range "$BASE..probe"
eq "$RC_" 1 "escape: a bare marker with no reason does NOT waive the rule"

reset_branch
printf 'This cites %s. adb-claim-ok: a stated reason.\n' "$D_MISSING" > "$REPO/notes.md"
commit "escape with a reason"
cc --range "$BASE..probe"
eq "$RC_" 0 "escape: the marker WITH a reason does waive it"

# =============================== markdown stripping edges ======================================
# A greedy HTML-comment strip deleted the prose BETWEEN two comments — hiding a real citation, the
# dangerous direction. And a 4-space-indented fence is an indented code block, not a fence: toggling
# on it hid every following line of the file.
reset_branch
{
  printf 'Intro.\n\n'
  printf '<!-- a --> this cites %s <!-- b -->\n' "$D_MISSING"
} > "$REPO/notes.md"
commit "two comments on one line"
cc --range "$BASE..probe"
eq "$RC_" 1 "md: prose BETWEEN two HTML comments is still scanned (non-greedy strip)"

reset_branch
{
  printf 'Intro.\n\n'
  printf '    ```\n'
  printf '\n'
  printf 'This cites %s in ordinary prose after an INDENTED code block.\n' "$D_MISSING"
} > "$REPO/notes.md"
commit "indented fence"
cc --range "$BASE..probe"
eq "$RC_" 1 "md: a 4-space-indented fence does not toggle fence state and hide the rest"

# =============================== the MULTI-LINE HTML comment (#251) ============================
# THE DEFECT #251 FILED. `cc_prose` was `sed`, and `sed` is line-based, so it could strip a comment
# that opened and closed on ONE line and nothing else. A `#N` quoted inside a MULTI-LINE comment was
# therefore scanned as a live citation, and `--live` would resolve it and fail CI on text that is
# not a claim at all.
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
} > "$REPO/notes.md"
commit "a multi-line comment whose body is not yet a citation"
MLBASE="$(git -C "$REPO" rev-parse HEAD)"
sed "s/PLACEHOLDER/it may cite $REF_GONE as example vocabulary/" "$REPO/notes.md" > "$REPO/notes.md.new"
mv "$REPO/notes.md.new" "$REPO/notes.md"
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
} > "$REPO/notes.md"
commit "a dangling reference AFTER a multi-line comment"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "md: a real citation AFTER the closer is still caught"
has "$OUT" "notes.md:7" "md: ...at the correct line, so the filter did not renumber the file"

# =============================== RAW vs PROSE stay two views (#251) ============================
# THE FAILURE THIS FILE ALREADY DOCUMENTS, asserted instead of assumed. check-claims deliberately
# keeps TWO views of every added line: the RULES read prose (a number quoted in a code span is not
# a citation), while the EXEMPTION reads the RAW line (the marker is normally a trailing comment,
# which in markdown may well sit inside a span). A single shared stripper is how a rule was once
# silently disabled here — it deleted exactly the tokens that rule searched for, reported zero on a
# commit carrying nine, and no assertion went red.
#
# The conversion to the shared filter is what makes this worth pinning: it would be natural to feed
# the prose view to everything, and nothing else in this suite would notice.
#
# ONE LINE carries both halves — a dangling decision reference OUTSIDE any span, and a valid
# `adb-claim-ok:` marker INSIDE one. Only the two-view reading is green: collapse them and the
# marker vanishes with the span, the exemption never fires, and the dangling D is a violation.
#
# It passes on the parent too, because the separation predates this change — so it was driven RED
# against a deliberately COLLAPSED-view copy of the tree (exemption read from prose instead of raw)
# rather than left as an unwitnessed assertion. See base/practices/self-review.md.
reset_branch
printf 'This cites %s and shows the escape as `adb-claim-ok: a quoted example`.\n' \
  "$D_MISSING" > "$REPO/notes.md"
commit "the escape marker inside a code span, beside a real dangling D-ref"
cc --range "$BASE..probe"
eq "$RC_" 0 "views: the exemption is read from the RAW line, so a marker inside a span still waives"
has "$OUT" "exempt=1" "views: ...and the line is reported as exempt, not merely unscanned"

# The mirror image: with no marker anywhere, the SAME line is a violation — so the case above is
# passing because of the exemption, not because the prose view happened to drop the reference.
reset_branch
printf 'This cites %s and shows the escape as `a quoted example`.\n' \
  "$D_MISSING" > "$REPO/notes.md"
commit "the same line WITHOUT the marker"
cc --range "$BASE..probe"
eq "$RC_" 1 "views: ...while the same line with no marker IS a violation"

# =============================== the filter is NOT optional (#251) =============================
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
#
# Doctored in the throwaway repo`s COPY of common.sh and restored immediately. The lint reads FILE
# CONTENT from git objects, so a working-tree edit here changes only the library it sources — which
# is exactly the surface under test.
reset_branch
printf 'Plain prose with no claims.\n' > "$REPO/notes.md"
commit "a benign range, to isolate the library probe"
cp "$REPO/scripts/lib/common.sh" "$work/common.sh.bak"
printf '\nunset -f adb_md_prose\n' >> "$REPO/scripts/lib/common.sh"
cc --range "$BASE..probe"
eq "$RC_" 2 "filter: a common.sh with no adb_md_prose is a hard failure, not a silent raw scan"
has "$OUT" "adb_md_prose" "filter: ...and the diagnostic names the missing primitive"
cp "$work/common.sh.bak" "$REPO/scripts/lib/common.sh"
cc --range "$BASE..probe"
eq "$RC_" 0 "filter: ...and the same range is clean once the library is whole again"

# THE 1:1 LINE INVARIANT, which every `CC_MASK[lno - 1]` lookup rests on. Its failure mode is
# silence: a prose view one line short reads the WRONG line for everything after it, and an empty
# one reads "" for every line — zero references, zero decision refs, and a confident PASS.
#
# It cannot be driven red from an input, because the invariant holds (check-common-lib.sh pins it).
# So it is witnessed the way this repo witnesses a forward guard: a deliberately broken filter that
# drops a line, in the throwaway copy. Without the check, the run below PASSES while scanning the
# wrong lines; with it, it is a named failure.
reset_branch
{
  printf 'Intro.\n\n'
  printf 'This cites %s in ordinary prose.\n' "$D_MISSING"
} > "$REPO/notes.md"
commit "a real violation, to prove the broken filter would HIDE it"
cc --range "$BASE..probe"
eq "$RC_" 1 "1:1: the range is genuinely a violation with the filter intact"
cp "$REPO/scripts/lib/common.sh" "$work/common.sh.bak"
# Drop the LAST line of the filter`s output — a renumbering no input can produce.
printf '\nadb_md_prose() { LC_ALL=C awk "{ print \\"\\" }" | sed \x27$d\x27; }\n' \
  >> "$REPO/scripts/lib/common.sh"
cc --range "$BASE..probe"
eq "$RC_" 3 "1:1: a filter whose output is SHORT is caught, not silently scanned as empty"
has "$OUT" "line count" "1:1: ...and the diagnostic says what is wrong"
cp "$work/common.sh.bak" "$REPO/scripts/lib/common.sh"

# A FILTER THAT FAILS OUTRIGHT is the third arm, and it is the one `adb_md_prose`'s nonce trailer
# exists for: a killed or truncated run returns non-zero rather than a short clean result. The two
# fixtures above cover a MISSING function and a SHORT one; this covers a present one that FAILS,
# which is a different branch of the same `case` and was unwitnessed until review said so.
reset_branch
{
  printf 'Intro.\n\n'
  printf 'This cites %s in ordinary prose.\n' "$D_MISSING"
} > "$REPO/notes.md"
commit "a real violation the failing filter must not hide"
cp "$REPO/scripts/lib/common.sh" "$work/common.sh.bak"
printf '\nadb_md_prose() { return 1; }\n' >> "$REPO/scripts/lib/common.sh"
cc --range "$BASE..probe"
eq "$RC_" 3 "filter: a filter that FAILS is exit 3, not an empty prose view scanned as clean"
has "$OUT" "markdown filter failed" "filter: ...and the diagnostic names the filter and the file"
cp "$work/common.sh.bak" "$REPO/scripts/lib/common.sh"

# AND THE ADDED-LINE SCANNER ITSELF. Its status used to be discarded by a process substitution, so
# an awk that died mid-file arrived as zero added lines — a file never read, reported in the words
# of a clean one. Driven here with a shim that fails ONLY `cc_scan_file`'s second awk (the one
# invoked with a leading `-v want=`), over a NON-markdown file so the prose filter — whose own awk
# also leads with `-v` — is never reached and cannot be what fails.
reset_branch
printf 'This cites %s from a shell file.\n' "$D_MISSING" > "$REPO/notes.txt"
commit "a real violation in a non-markdown file"
cc --range "$BASE..probe"
eq "$RC_" 1 "scanner: the range is genuinely a violation with the scanner intact"
cp "$REPO/scripts/lib/common.sh" "$work/common.sh.bak"
printf '\nawk() { case "$1" in -v) return 3 ;; esac; command awk "$@"; }\n' \
  >> "$REPO/scripts/lib/common.sh"
cc --range "$BASE..probe"
eq "$RC_" 3 "scanner: an added-line reader that DIES is exit 3, not zero added lines reported clean"
has "$OUT" "could not scan" "scanner: ...and the diagnostic names the file it failed on"
cp "$work/common.sh.bak" "$REPO/scripts/lib/common.sh"
rm -f "$REPO/notes.txt"

# =============================== the commit walk must not stray onto the base ==================
# `A...B` means two DIFFERENT things to the two git commands this lint uses: to `git diff` it is
# "from the merge base to B", but to `git rev-list` it is the SYMMETRIC DIFFERENCE — which drags in
# the BASE branch's commits. The date rule walks commits, so a three-dot range once made it report
# on history the branch is not asserting anything about.
#
# The fixture diverges for real: a bad date lands on the BASE branch, and the probe branch is clean.
# A three-dot scan of the probe must stay green.
git -C "$REPO" checkout -q -B probe "$BASE"
printf 'clean\n' > "$REPO/notes.md"
GIT_COMMITTER_DATE="2026-05-01T12:00:00Z" git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-05-01T12:00:00Z" git -C "$REPO" commit -q -m "clean probe" --date="2026-05-01T12:00:00Z"
PROBE="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -q -B basework "$BASE"
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — a badly dated entry that lives on the BASE branch
- date:      2026-09-09
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-05-01T12:00:00Z" git -C "$REPO" commit -q -m "bad date on base" --date="2026-05-01T12:00:00Z"
git -C "$REPO" checkout -q probe

cc --range "basework...$PROBE"
eq "$RC_" 0 "range: a three-dot scan does NOT walk the BASE branch's commits"
hasnt "$OUT" "2026-09-09" "range: the base branch's bad date is not reported"

# ...and the same bad commit IS caught when it is genuinely in the scanned range.
cc --range "$BASE..basework"
eq "$RC_" 1 "range: the same bad date IS caught when the range really contains it"
has "$OUT" "2026-09-09" "range: the in-range bad date is named"
git -C "$REPO" checkout -q -B probe "$BASE"

# =============================== a kind hint needs a digit boundary ============================
# A short number must not be found INSIDE a longer one: with a pull-request citation for 210 on
# the line, a bare 21 was handed 210's hint and a correct citation was reported as a kind
# mismatch. Written with placeholders rather than a literal citation on purpose — this file is
# scanned by the very lint it tests, so spelling the example out would BE a claim about 21.
: > "$GH_CALLS"
reset_branch
printf 'Landed in PR %s, and also see %s.\n' "$REF_PR" "$REF_PREFIX" > "$REPO/notes.md"
commit "prefix hint"
cc --range "$BASE..probe" --live
# NOTE the quoting: this label must not contain backticks. An earlier version read
# a label naming both numbers with backticks around one of them, inside a double-quoted string,
# which bash expands as
# COMMAND SUBSTITUTION — it ran a command named PR and then blocked reading stdin. Standalone the
# suite still passed (stdin was /dev/null); under selfcheck, whose stdin is an open pipe, it hung
# for ten minutes. A test label is a value crossing a syntax boundary like any other.
eq "$RC_" 0 "hint: a bare 21 beside a PR 210 citation is not given the PR hint (digit boundary)"

# ============ review #239: a query-specific failure is UNREADABLE, not "does not exist" ========
# An earlier version asked whether the REPOSITORY was reachable and treated success as proof the
# number was absent. Every query-specific failure with a readable repo then became a confident
# "does not resolve" — a tool built to stop fabricated references, fabricating them.
: > "$GH_CALLS"
reset_branch
printf 'Tracked in %s.\n' "$REF_OPEN" > "$REPO/notes.md"
commit "entity denied, repo readable"
cc_denied --range "$BASE..probe" --live
eq "$RC_" 3 "C1: a query-specific read failure with a READABLE repo exits 3, not 1"
hasnt "$OUT" "does not resolve" "C1: a permissions/transient failure is never called a missing issue"

# ============ review #239: the pull hint is CASE-INSENSITIVE ===================================
# The issue hint used -i and the pull hint did not, so `Pull request #N` and `pr #N` were recorded
# as `bare` — and a bare reference is only existence-checked, so a sentence naming the wrong entity
# kind passed the live check outright.
for spelling in "Pull request" "pull request" "pr" "PR"; do
  : > "$GH_CALLS"
  reset_branch
  printf 'See %s %s for context.\n' "$spelling" "$REF_OPEN" > "$REPO/notes.md"
  commit "hint spelling $spelling"
  cc --range "$BASE..probe" --live
  eq "$RC_" 1 "C1: '$spelling' is recognized as a pull-request hint (and 7 is an issue)"
done

# ============ review #239: the date must come from the FIELD ==================================
# The extractor took the first date-shaped substring anywhere on the line, so trailing prose
# satisfied the rule while the field itself carried no date.
reset_branch
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D3 — a date only in the trailing prose
- date:      TBD # expected around 2026-03-03
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-03-03T12:00:00Z" git -C "$REPO" commit -q -m "date in prose" --date="2026-03-03T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 1 "C4: a date in trailing prose does NOT satisfy a field whose value is TBD"
has "$OUT" "carries no YYYY-MM-DD" "C4: the diagnostic says the FIELD has no date"

# ============ review #239: a merge must not inherit its parents' dates ========================
# `git show -m` diffs a merge against EACH parent, so a line from ONE parent reads as an addition
# relative to the other. A feature branch that merges the default branch and resolves a conflict in
# the decision log therefore re-attributed every accumulated decision to the merge commit and
# compared it against the merge's own date — a guaranteed red build on correctly-dated entries.
git -C "$REPO" checkout -q -B trunkside "$BASE"
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D9 — written long ago, on the default branch
- date:      2026-01-01
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-01-01T12:00:00Z" git -C "$REPO" commit -q -m "old decision on trunk" --date="2026-01-01T12:00:00Z"
git -C "$REPO" checkout -q -B probe "$BASE"
cat >> "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'

## D8 — written on the feature branch
- date:      2026-01-20
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-01-20T12:00:00Z" git -C "$REPO" commit -q -m "feature decision" --date="2026-01-20T12:00:00Z"
git -C "$REPO" merge --no-ff -q trunkside >/dev/null 2>&1 || true
# Resolve the conflict the way a human would: keep both entries, unchanged.
cat > "$REPO/.ai-dev-baseline/decisions.md" <<'EOF'
# Decision log

## D1 — the first decision
- date:      2026-01-01

## D2 — the second decision
- date:      2026-01-02

## D8 — written on the feature branch
- date:      2026-01-20

## D9 — written long ago, on the default branch
- date:      2026-01-01
EOF
git -C "$REPO" add -A
GIT_COMMITTER_DATE="2026-01-21T12:00:00Z" git -C "$REPO" commit -q -m "merge trunk" --date="2026-01-21T12:00:00Z"
cc --range "$BASE..probe"
eq "$RC_" 0 "C4: a merge does NOT inherit its parents' dates as its own additions"
hasnt "$OUT" "2026-01-01" "C4: the default branch's old date is not re-attributed to the merge"
git -C "$REPO" checkout -q -B probe "$BASE"

# =============================== the wiring is pinned ==========================================
# A perfectly correct lint that nothing invokes is a lint that checks nothing, and it fails exactly
# the way this whole file exists to prevent: silently. So the ACTIVE invocation sites are asserted,
# not merely the presence of the filename somewhere in the tree — commenting a call out must break
# a test. D22 records the same lesson for the other enforcement wiring.
SELFCHECK="$ROOT/scripts/selfcheck.sh"
CI="$ROOT/.github/workflows/ci.yml"

# ASK THE RUNNER, do not grep it (#260). selfcheck.sh no longer carries `if bash …; then` lines:
# its steps are a REGISTRY dispatched through a `wait -n` job pool. A grep for the old shape would
# now report "not wired" for a perfectly wired suite, and a grep for the new shape would prove only
# that a string exists somewhere in a file — a weaker claim than the one this section is making.
#
# `--list` is the dispatcher's own answer to "what do you run", so it cannot pass while the array it
# read has stopped being the one the pool consults; and `scripts/check-selfcheck.sh` is what proves
# every listed step is actually EXECUTED and that its exit status reaches the run's exit code. The
# pair is strictly stronger than the line match it replaces, which is why the replacement is this
# and not a re-spelled regex.
registry="$(bash "$SELFCHECK" --list 2>/dev/null)" || registry=""
if [ -n "$registry" ]; then ok; else bad "selfcheck.sh --list produced no registry to check"; fi
eq "$(printf '%s\n' "$registry" | awk -F'\t' '$1 == "claims" {print $2}')" \
   "bash scripts/check-claims.sh" "selfcheck.sh's registry ACTIVELY invokes check-claims.sh"
eq "$(printf '%s\n' "$registry" | awk -F'\t' '$1 == "claims-guard" {print $2}')" \
   "bash scripts/check-claims-guard.sh" "selfcheck.sh's registry ACTIVELY invokes check-claims-guard.sh"

# The local mirror must NOT run the live half: D13 keeps selfcheck hermetic, and a network-dependent
# step there would make a local green stop predicting CI for every other step too. Asserted on the
# registry AND on the file: the registry is what runs, and the file grep still catches a `--live`
# reintroduced somewhere the registry does not reach.
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
CI_JOB="$WORK_JOB"
awk '/^  [a-z][a-z0-9_-]*:/ { injob = ($0 ~ /^  fact-drift:/) } injob { print }' "$CI" > "$CI_JOB"

if [ -s "$CI_JOB" ]; then ok; else bad "ci.yml has no fact-drift job — the claim wiring has no home"; fi
if grep -qE '^ *run: bash scripts/check-claims\.sh --range ' "$CI_JOB"; then ok; else
  bad "the claim-lint job does not run the offline claim lint over a range"; fi
if grep -qE '^ *run: bash scripts/check-claims\.sh --live --range ' "$CI_JOB"; then ok; else
  bad "the claim-lint job does not run the LIVE half — the network half would run NOWHERE"; fi
if grep -qE '^ *run: bash scripts/check-claims-guard\.sh' "$CI_JOB"; then ok; else
  bad "the claim-lint job does not run the guard suite"; fi

# The live step needs a token and issue/PR read scope; without either it exits 3 on every run, which
# is a red build rather than a silent pass — but a red build nobody can fix from the diff.
# Anchored to the real YAML key. A bare substring grep also matched the COMMENT that mentions
# the setting, so deleting the setting itself left the guard green — a pin made vacuous by the
# very prose written to explain it.
if grep -qE '^ +issues: read$' "$CI_JOB"; then ok; else
  bad "the claim-lint job grants no 'issues: read' — the live half cannot resolve anything"; fi
if grep -qE '^ +pull-requests: read$' "$CI_JOB"; then ok; else
  bad "the claim-lint job grants no 'pull-requests: read' — a PR number cannot resolve"; fi
if grep -qE '^ +GH_TOKEN:' "$CI_JOB"; then ok; else
  bad "the claim-lint job passes no GH_TOKEN — the live half would exit 3 on every run"; fi
if grep -qE '^ +fetch-depth: 0$' "$CI_JOB"; then ok; else
  bad "the claim-lint job has no full-history checkout — base..head cannot resolve when shallow"; fi

check_summary "check-claims-guard"
