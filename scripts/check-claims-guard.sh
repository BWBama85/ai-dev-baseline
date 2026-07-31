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
#   7    -> issue OPEN          210 -> PULL REQUEST (the shared number space)
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

# =============================== C2 — decision references ======================================
reset_branch
cat > "$REPO/notes.md" <<'EOF'
This paragraph cites D99, which has no heading anywhere.
EOF
commit "cite a missing decision"
cc --range "$BASE..probe"
eq "$RC_" 1 "C2: a dangling D-reference exits 1 (the designated violation code)"
has "$OUT" "cites D99" "C2: the diagnostic names the dangling decision"
has "$OUT" "notes.md:1" "C2: the diagnostic names file:line"

# ...and the SAME defect in a SHELL COMMENT, which is where the real one was. A rule that discarded
# comments would be green here, and that is one of the four claims this lint exists for.
reset_branch
cat > "$REPO/lib.sh" <<'EOF'
#!/usr/bin/env bash
# The reviewer-identity rule (recorded as D77) is applied here.
echo hi
EOF
commit "cite a missing decision in a shell comment"
cc --range "$BASE..probe"
eq "$RC_" 1 "C2: a dangling D-reference inside a SHELL COMMENT still exits 1"
has "$OUT" "cites D77" "C2: the shell-comment diagnostic names the decision"

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
cat > "$REPO/notes.md" <<'EOF'
Inside a fence, nothing declares:

```
D99 appears here and must not be checked.
```

And `D98` in a code span must not be checked either.
EOF
commit "fenced and code-span D-refs"
cc --range "$BASE..probe"
eq "$RC_" 0 "C2: a D-reference inside a fence or a code span does not fire"

# =============================== the audited escape ============================================
reset_branch
cat > "$REPO/notes.md" <<'EOF'
This cites D99 deliberately. adb-claim-ok: documenting a decision id that does not exist.
EOF
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

# =============================== C1 — live issue/PR references =================================
: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
Tracked in #4242, which does not exist.
EOF
commit "nonexistent reference"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: a reference that does not resolve exits 1"
has "$OUT" "#4242 does not resolve" "C1: the diagnostic names the dangling number"
has "$OUT" "acme/widget" "C1: the diagnostic names the repo the read was pinned to"

: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
Superseded by #150, which tracks this work.
EOF
commit "not-planned reference"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: a NOT_PLANNED reference exits 1"
has "$OUT" "closed NOT_PLANNED" "C1: the diagnostic says the issue tracks nothing"
has "$OUT" "adb-claim-ok" "C1: the diagnostic names the escape, so the remedy is discoverable"

: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
See issue #210 for the rationale.
EOF
commit "kind mismatch"
cc --range "$BASE..probe" --live
eq "$RC_" 1 "C1: 'issue #210' resolving to a PULL REQUEST exits 1"
has "$OUT" "cited as an issue but resolves to a pull request" "C1: the kind mismatch is named"

# A bare number that resolves to a PR is fine — PRs are legitimate references.
: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
Landed in #210 and tracked by #7, and #9 is done.
EOF
commit "legitimate references"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: bare PR, open issue and COMPLETED issue references all pass"
has "$OUT" "live-lookups=3" "C1: three distinct numbers cost exactly three lookups"

# Deduplication: the same number many times is ONE network call.
: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
#7 and #7 and #7 again, plus #7 once more.
EOF
commit "repeated reference"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: repeated references pass"
has "$OUT" "live-lookups=1" "C1: four occurrences of one number cost ONE lookup (dedup)"
eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 1 "C1: the stub recorded exactly one read"

# =============================== C1 precision ==================================================
: > "$GH_CALLS"
reset_branch
cat > "$REPO/notes.md" <<'EOF'
A fenced block declares nothing:

```
Tracked in #4242.
```

Nor does `#4242` in a code span.
A cross-repo reference acme/other#4242 belongs to a different number space.
Neither #0 nor SC1091 is an entity reference.
EOF
commit "precision corpus"
cc --range "$BASE..probe" --live
eq "$RC_" 0 "C1: fences, code spans, cross-repo forms and #0 are all excluded"
eq "$(grep -c 'issue view' "$GH_CALLS" | tr -d ' ')" 0 "C1: nothing in the precision corpus reached the network"

# =============================== fail closed ===================================================
reset_branch
cat > "$REPO/notes.md" <<'EOF'
Tracked in #7.
EOF
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

check_summary "check-claims-guard"
