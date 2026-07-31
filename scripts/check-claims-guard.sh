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

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary + check_exit_guard

work="$(mktemp -d)"
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

git init -q "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" remote add origin https://github.com/acme/widget.git

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
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# `auth status` must succeed or adb_require_gh refuses before any read happens.
[ "${1:-}" = "auth" ] && exit 0
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  n="$3"
  printf '%s\n' "$*" >> "$GH_CALLS"
  case "$n" in
    7)    echo '{"state":"OPEN","stateReason":"","url":"https://github.com/acme/widget/issues/7"}' ;;
    21)   echo '{"state":"OPEN","stateReason":"","url":"https://github.com/acme/widget/issues/21"}' ;;
    9)    echo '{"state":"CLOSED","stateReason":"COMPLETED","url":"https://github.com/acme/widget/issues/9"}' ;;
    150)  echo '{"state":"CLOSED","stateReason":"NOT_PLANNED","url":"https://github.com/acme/widget/issues/150"}' ;;
    210)  echo '{"state":"MERGED","stateReason":"","url":"https://github.com/acme/widget/pull/210"}' ;;
    *)    exit 1 ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$BIN/gh"

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
cat > "$NOAUTH/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "auth" ] && exit 1     # not logged in
exit 1
STUB
chmod +x "$NOAUTH/gh"

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
cc --range "deadbeefdeadbeef..HEAD"; eq "$RC_" 2 "an unresolvable head revision exits 2"

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

# Whole-token matching: D1 must not be satisfied by D18, nor D3 by a bare 'D3X'.
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
# `PR #21` must not be found inside `PR #212`. The glob form matched the prefix and handed the
# shorter number the longer one's hint, reporting a correct citation as a kind mismatch.
: > "$GH_CALLS"
reset_branch
printf 'Landed in PR %s, and also see %s.\n' "$REF_PR" "$REF_PREFIX" > "$REPO/notes.md"
commit "prefix hint"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "hint: #21 beside `PR #210` is not given #210's hint (digit boundary)"

# =============================== the wiring is pinned ==========================================
# A perfectly correct lint that nothing invokes is a lint that checks nothing, and it fails exactly
# the way this whole file exists to prevent: silently. So the ACTIVE invocation sites are asserted,
# not merely the presence of the filename somewhere in the tree — commenting a call out must break
# a test. D22 records the same lesson for the other enforcement wiring.
SELFCHECK="$ROOT/scripts/selfcheck.sh"
CI="$ROOT/.github/workflows/ci.yml"

if grep -qE '^if bash scripts/check-claims\.sh; then' "$SELFCHECK"; then ok; else
  bad "selfcheck.sh does not ACTIVELY invoke check-claims.sh"; fi
if grep -qE '^if bash scripts/check-claims-guard\.sh; then' "$SELFCHECK"; then ok; else
  bad "selfcheck.sh does not ACTIVELY invoke check-claims-guard.sh"; fi

# The local mirror must NOT run the live half: D13 keeps selfcheck hermetic, and a network-dependent
# step there would make a local green stop predicting CI for every other step too.
if grep -qE '^[^#]*check-claims\.sh[^#]*--live' "$SELFCHECK"; then
  bad "selfcheck.sh runs the LIVE claim half — that breaks the hermetic-mirror promise (D13)"
else ok; fi

if grep -qE '^ *run: bash scripts/check-claims\.sh --range ' "$CI"; then ok; else
  bad "ci.yml does not run the offline claim lint over a range"; fi
if grep -qE '^ *run: bash scripts/check-claims\.sh --live --range ' "$CI"; then ok; else
  bad "ci.yml does not run the LIVE claim half — the network half would then run NOWHERE"; fi
if grep -qE '^ *run: bash scripts/check-claims-guard\.sh' "$CI"; then ok; else
  bad "ci.yml does not run the claim lint's guard suite"; fi

# The live step needs a token and issue/PR read scope; without either it exits 3 on every run, which
# is a red build rather than a silent pass — but a red build nobody can fix from the diff.
if grep -q 'issues: read' "$CI"; then ok; else
  bad "ci.yml grants no 'issues: read' — the live claim half cannot resolve anything"; fi
if grep -q 'pull-requests: read' "$CI"; then ok; else
  bad "ci.yml grants no 'pull-requests: read' — the live claim half cannot resolve a PR number"; fi
if grep -q 'fetch-depth: 0' "$CI"; then ok; else
  bad "ci.yml has no full-history checkout — base..head cannot resolve on a shallow clone"; fi

check_summary "check-claims-guard"
