#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the release-goal convention helper
# (scripts/lib/release-convention.sh, #27). OFFLINE: it exercises the dispatch, arg-parsing,
# usage, and the fail-loud gh guard WITHOUT touching a real GitHub repo. The gh-mutating paths
# (milestone/label creation, marker seeding) are behavioral and belong to the /roadmap +
# release-readiness e2e coverage tracked in #45 — this check guards the surface that runs before
# any gh call.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-release-convention.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RC="$ROOT/scripts/lib/release-convention.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stub `gh` whose `auth status` fails, to prove require_gh fails loud (never a silent no-op).
BIN="$work/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 1 ;;   # simulate: not authenticated
esac
exit 0
EOF
chmod +x "$BIN/gh"

# rcx <args...> : run the helper, capture combined output + rc via globals OUT/RC_.
rcx() { OUT="$(bash "$RC" "$@" 2>&1)"; RC_=$?; }
# rcx_auth <args...> : same, but with the failing-auth stub gh first on PATH.
rcx_auth() { OUT="$(PATH="$BIN:$PATH" bash "$RC" "$@" 2>&1)"; RC_=$?; }

# ============================ usage / dispatch ============================
rcx -h;            yes "$RC_" "-h exits 0";            has "$OUT" "release-goal convention" "-h prints the usage header"
rcx --help;        yes "$RC_" "--help exits 0"
rcx;               no  "$RC_" "no subcommand exits nonzero"
rcx bogus;         no  "$RC_" "unknown subcommand exits nonzero"; has "$OUT" "unknown subcommand" "unknown subcommand names itself"
rcx init -h;       yes "$RC_" "init -h exits 0";       has "$OUT" "release-goal convention" "init -h prints usage"

# ============================ arg parsing ============================
rcx init --release-name;   no "$RC_" "init --release-name w/o value exits nonzero"; has "$OUT" "needs a value" "missing value is named"
rcx init --release-name '';   no "$RC_" "init --release-name '' exits nonzero";     has "$OUT" "must not be empty" "empty release name is rejected"
rcx init --release-name '   '; no "$RC_" "init --release-name whitespace exits nonzero"; has "$OUT" "must not be empty" "whitespace release name is rejected"
rcx init --bogus;          no "$RC_" "init unknown option exits nonzero";            has "$OUT" "unknown option" "unknown option is named"
rcx status --bogus;        no "$RC_" "status unknown option exits nonzero"

# ============================ fail-loud gh guard ============================
rcx_auth init;    no "$RC_" "init with unauthenticated gh exits nonzero";   has "$OUT" "not authenticated" "init surfaces the auth failure"
rcx_auth status;  no "$RC_" "status with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "status surfaces the auth failure"
rcx_auth roll --version v1;  no "$RC_" "roll with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "roll surfaces the auth failure"

# ============================ roll: dispatch + per-subcommand arg parsing (#74) ============
# Parsing is per-subcommand ON PURPOSE: a shared parser would make `status --version v1` and
# `init --dry-run` silently valid, so both directions are pinned here.
rcx bogus;                     has "$OUT" "'init', 'status', or 'roll'" "unknown subcommand lists roll"
rcx roll -h;                   yes "$RC_" "roll -h exits 0";  has "$OUT" "roll --version" "usage documents roll"
rcx roll;                      no "$RC_" "roll without --version exits nonzero"; has "$OUT" "needs --version" "missing --version is named"
rcx roll --version;            no "$RC_" "roll --version w/o value exits nonzero"; has "$OUT" "needs a value" "missing --version value is named"
rcx roll --version '';         no "$RC_" "roll --version '' exits nonzero";       has "$OUT" "must not be empty" "empty version is rejected"
rcx roll --version '  ';       no "$RC_" "roll --version whitespace exits nonzero"
rcx roll --version v1 --bogus; no "$RC_" "roll unknown option exits nonzero";     has "$OUT" "unknown option" "roll names an unknown option"
rcx status --version v1;       no "$RC_" "status rejects the roll-only --version"
rcx status --dry-run;          no "$RC_" "status rejects the roll-only --dry-run"
rcx init --dry-run;            no "$RC_" "init rejects the roll-only --dry-run"
rcx init --force;              no "$RC_" "init rejects the roll-only --force"

# ============================ roll: behavior against a read-only gh stub ==================
# The ORDERING is the correctness-critical part of roll and it is fully testable offline: the
# archive rename must FREE the rolling title before the create (GitHub rejects a duplicate
# milestone title), and the close must come LAST so an interruption always leaves a resumable
# state. A stub gh that answers the read calls from fixtures and RECORDS the mutations lets both
# the planned order (--dry-run) and the executed order be asserted with no network. Real 422/403
# handling and true resume-after-interruption still belong to the mocked-gh harness (#75).
S="$work/stub"; mkdir -p "$S/issues"
cat > "$S/milestones.tsv" <<EOF
Next release	open	9
Backlog	open	8
EOF
printf 'release-blocker\npost-deploy\n' > "$S/labels.txt"
printf '31\n' > "$S/roadmap-nums.txt"
printf '<!-- ai-dev-baseline:roadmap:v1 -->\n<!-- release-milestone: Next release -->\n' > "$S/roadmap-body.txt"
# Milestone 9: one CLOSED-completed blocker (the shipped requirement) + one OPEN non-blocker
# leftover. armed=1, open-blockers=0, canceled=0 -> the shared predicate returns `met`.
printf '74\tclosed\tcompleted\tenhancement,release-blocker\n99\topen\t-\tenhancement\n' > "$S/issues/9.tsv"

SBIN="$work/sbin"; mkdir -p "$SBIN"
cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Read-only gh stub: answers reads from $S fixtures, appends every mutation to $STUB_CALLS.
url=""; method="GET"
for a in "$@"; do
  case "$a" in
    repos/*) [ -z "$url" ] && url="$a" ;;
    PATCH|POST|DELETE) method="$a" ;;
  esac
done
case "${1:-}" in
  auth) exit 0 ;;
  repo) printf '%s\n' "acme/widget"; exit 0 ;;
  label) cat "$S/labels.txt"; exit 0 ;;
  issue)
    case "${2:-}" in
      list) cat "$S/roadmap-nums.txt" ;;
      view) cat "$S/roadmap-body.txt" ;;
      edit) printf 'move %s\n' "$3" >> "$STUB_CALLS" ;;
    esac
    exit 0 ;;
  api)
    if [ "$method" != "GET" ]; then printf '%s %s\n' "$method" "$url" >> "$STUB_CALLS"; exit 0; fi
    case "$url" in
      *"/milestones?state=open"*) awk -F'\t' '$2=="open"' "$S/milestones.tsv" ;;
      *"/milestones?state=all"*)  cat "$S/milestones.tsv" ;;
      *"/issues?milestone="*)
        n="${url#*milestone=}"; n="${n%%&*}"
        [ -f "$S/issues/$n.tsv" ] && cat "$S/issues/$n.tsv" ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$SBIN/gh"

# rcx_stub <args...> : run with the fixture-backed stub gh, fresh call log each time.
rcx_stub() {
  STUB_CALLS="$work/calls.txt"; : > "$STUB_CALLS"
  OUT="$(S="$S" STUB_CALLS="$STUB_CALLS" PATH="$SBIN:$PATH" bash "$RC" "$@" 2>&1)"; RC_=$?
}
# plan_of : the emitted plan lines, pipe-joined, so the ORDER is one comparable string.
plan_of() { printf '%s\n' "$OUT" | sed -n 's/^plan: //p' | tr '\n' '|'; }
calls_of() { tr '\n' '|' < "$STUB_CALLS"; }

WANT='rename milestone #9 "Next release" -> "v1.1.0"|create milestone "Next release"|move issue #99 -> "Backlog"|close milestone #9 ("v1.1.0")|'

rcx_stub roll --version v1.1.0 --dry-run
yes "$RC_" "roll --dry-run on a met milestone exits 0"
eq "$(plan_of)" "$WANT" "dry-run plan is rename -> create -> move -> close"
has "$OUT" "dry-run: no changes made" "dry-run says it changed nothing"
eq "$(calls_of)" "" "dry-run performs NO mutations"
# The rolling title came from the artifact marker, not the built-in default.
has "$OUT" '"Next release" -> "v1.1.0"' "rolling title resolved from the marker"

rcx_stub roll --version v1.1.0
yes "$RC_" "roll on a met milestone exits 0"
eq "$(calls_of)" 'PATCH repos/acme/widget/milestones/9|POST repos/acme/widget/milestones|move 99|PATCH repos/acme/widget/milestones/9|' \
  "executed order is rename -> create -> move -> close"
has "$OUT" "rolled: 'Next release' -> 'v1.1.0'" "success emits one audit line"
has "$OUT" "marker is unchanged" "success states the marker needed no edit"

# The artifact is never a backlog item, and it is excluded from the counts -- add it to the
# milestone and nothing about the plan may change.
printf '74\tclosed\tcompleted\tenhancement,release-blocker\n99\topen\t-\tenhancement\n31\topen\t-\tdocumentation,roadmap\n' > "$S/issues/9.tsv"
rcx_stub roll --version v1.1.0 --dry-run
eq "$(plan_of)" "$WANT" "the roadmap artifact is never moved and never counted"
printf '74\tclosed\tcompleted\tenhancement,release-blocker\n99\topen\t-\tenhancement\n' > "$S/issues/9.tsv"

# --- refusals: every one is checked BEFORE any mutation --------------------------------------
rcx_stub roll --version "Next release"
no "$RC_" "roll refuses when --version is the rolling title itself"
has "$OUT" "is the rolling title itself" "the collision is named"
eq "$(calls_of)" "" "no mutation before the rolling-title refusal"

rcx_stub roll --version Backlog
no "$RC_" "roll refuses when --version is the backlog title"
eq "$(calls_of)" "" "no mutation before the backlog-title refusal"

# An OPEN must-have blocks on TWO independent guards, and both are asserted because they fail at
# different layers: the readiness verdict catches it first, and if that is waived, the demotion
# refusal catches it again. Losing either one silently demotes a release requirement to Backlog.
printf '74\tclosed\tcompleted\tenhancement,release-blocker\n99\topen\t-\trelease-blocker\n' > "$S/issues/9.tsv"
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses while an open release-blocker remains"
has "$OUT" "verdict is 'unmet'" "the readiness guard fires first"
eq "$(calls_of)" "" "no mutation before the open-blocker refusal"
# ...and --force does NOT override it: --force waives the readiness VERDICT, not the demotion.
rcx_stub roll --version v1.1.0 --force
no "$RC_" "--force still refuses to demote an open must-have"
has "$OUT" "will not demote a must-have" "the demotion guard survives --force"
eq "$(calls_of)" "" "no mutation under --force with an open blocker"

# A NOT_PLANNED blocker -> predicate `held` -> withheld, and the message names the owner's options.
printf '74\tclosed\tnot_planned\tenhancement,release-blocker\n' > "$S/issues/9.tsv"
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses on the held verdict"
has "$OUT" "held" "the held verdict is named"
eq "$(calls_of)" "" "no mutation before the held refusal"
# --force is exactly the documented override for `held` (nothing is OPEN, so nothing is demoted).
rcx_stub roll --version v1.1.0 --force
yes "$RC_" "--force overrides the held verdict"
has "$OUT" "skipping the readiness re-check" "--force says what it waived"

# An empty milestone is `unarmed` -- there is nothing to archive.
: > "$S/issues/9.tsv"
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses an unarmed (empty) milestone"
has "$OUT" "nothing to archive" "the unarmed refusal explains itself"
printf '74\tclosed\tcompleted\tenhancement,release-blocker\n99\topen\t-\tenhancement\n' > "$S/issues/9.tsv"

# --- marker resolution refusals ---------------------------------------------------------------
# The default title is never a fallback: a repo that opted in under a custom name has no
# "Next release" milestone at all, so guessing it would roll the wrong thing.
printf '<!-- ai-dev-baseline:roadmap:v1 -->\n' > "$S/roadmap-body.txt"
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the artifact carries no marker"
has "$OUT" "could not resolve the rolling milestone title" "the marker failure is named"
eq "$(calls_of)" "" "no mutation when the marker cannot be resolved"

# The schema's own example token is a placeholder, not a milestone (same carve-out /roadmap uses).
printf '<!-- release-milestone: NAME -->\n' > "$S/roadmap-body.txt"
rcx_stub roll --version v1.1.0
no "$RC_" "the literal placeholder NAME is not treated as a title"

# Two different marker values is ambiguous -- never guess.
printf '<!-- release-milestone: Next release -->\n<!-- release-milestone: Other -->\n' > "$S/roadmap-body.txt"
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the artifact names two different titles"
has "$OUT" "names 2 different release-milestone titles" "the ambiguity is quantified"

# --release-name is the explicit override when there is no usable marker.
rcx_stub roll --version v1.1.0 --release-name "Next release" --dry-run
yes "$RC_" "--release-name overrides marker resolution"
eq "$(plan_of)" "$WANT" "the override produces the same plan"
printf '<!-- ai-dev-baseline:roadmap:v1 -->\n<!-- release-milestone: Next release -->\n' > "$S/roadmap-body.txt"

# --- state classification: already-rolled is a clean refusal, not a second rename -------------
cat > "$S/milestones.tsv" <<EOF
v1.1.0	closed	9
Next release	open	12
Backlog	open	8
EOF
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the version milestone is already closed"
has "$OUT" "already rolled" "the already-rolled state is named"
eq "$(calls_of)" "" "no mutation when already rolled"

# Interrupted after the rename (archive open, rolling title free) -> RESUME, skipping the rename.
cat > "$S/milestones.tsv" <<EOF
v1.1.0	open	9
Backlog	open	8
EOF
rcx_stub roll --version v1.1.0 --dry-run
yes "$RC_" "roll resumes an interrupted roll"
has "$OUT" "resuming an interrupted roll" "the resume is announced"
eq "$(plan_of)" 'create milestone "Next release"|move issue #99 -> "Backlog"|close milestone #9 ("v1.1.0")|' \
  "the resume skips the already-done rename"

# Missing Backlog is a refusal -- never leave issues milestone-less halfway through.
cat > "$S/milestones.tsv" <<EOF
Next release	open	9
EOF
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the Backlog milestone is absent"
has "$OUT" "no OPEN milestone titled 'Backlog'" "the missing disposition target is named"

check_summary "release-convention"
