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
RC="$ROOT/scripts/lib/release-convention.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# rcx <args...> : run the helper with the REAL PATH, capture combined output + rc in OUT/RC_.
# Used for the paths that refuse before any gh call (usage, dispatch, arg parsing).
rcx() { OUT="$(bash "$RC" "$@" 2>&1)"; RC_=$?; }

# ============================ usage / dispatch ============================
rcx -h;            yes "$RC_" "-h exits 0";            has "$OUT" "release-goal convention" "-h prints the usage header"
rcx --help;        yes "$RC_" "--help exits 0"
rcx;               no  "$RC_" "no subcommand exits nonzero"
rcx bogus;         no  "$RC_" "unknown subcommand exits nonzero"; has "$OUT" "unknown subcommand" "unknown subcommand names itself"; has "$OUT" "'init', 'status', or 'roll'" "unknown subcommand lists every subcommand"
rcx init -h;       yes "$RC_" "init -h exits 0";       has "$OUT" "release-goal convention" "init -h prints usage"

# ============================ arg parsing ============================
rcx init --release-name;   no "$RC_" "init --release-name w/o value exits nonzero"; has "$OUT" "needs a value" "missing value is named"
rcx init --release-name '';   no "$RC_" "init --release-name '' exits nonzero";     has "$OUT" "must not be empty" "empty release name is rejected"
rcx init --release-name '   '; no "$RC_" "init --release-name whitespace exits nonzero"; has "$OUT" "must not be empty" "whitespace release name is rejected"
rcx init --bogus;          no "$RC_" "init unknown option exits nonzero";            has "$OUT" "unknown option" "unknown option is named"
rcx status --bogus;        no "$RC_" "status unknown option exits nonzero"

# ============================ roll: dispatch + per-subcommand arg parsing (#74) ============
# Parsing is per-subcommand ON PURPOSE: a shared parser would make `status --version v1` and
# `init --dry-run` silently valid, so both directions are pinned here.
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

# Fixture writers. Every scenario is expressed as a call to one of these, and every test starts
# from fix_default, so no test inherits the previous test's fixture edits.
ms()     { printf '%b' "$*" > "$S/milestones.tsv"; }
iss()    { printf '%s' "$*" > "$S/issues/9.json"; }
marker() { printf '%b' "$*" > "$S/roadmap-body.txt"; }

# The milestone under test: one CLOSED-completed blocker (the shipped requirement) plus one OPEN
# non-blocker leftover. armed=1, open-blockers=0, canceled=0 -> the shared predicate returns `met`.
ISS_MET='[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"enhancement"},{"name":"release-blocker"}]},
          {"number":99,"state":"open","state_reason":null,"labels":[{"name":"enhancement"}]}]'

fix_default() {
  ms 'Next release\topen\t9\nBacklog\topen\t8\n'
  iss "$ISS_MET"
  marker '<!-- ai-dev-baseline:roadmap:v1 -->\n<!-- release-milestone: Next release -->\n'
  printf 'release-blocker\npost-deploy\n' > "$S/labels.txt"
}

SBIN="$work/sbin"; mkdir -p "$SBIN"
cat > "$SBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Read-only gh stub: answers reads from $S fixtures, appends every mutation to $STUB_CALLS.
# STUB_AUTH_FAIL=1 turns it into the unauthenticated stub, so one stub covers both suites.
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
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
  issue)
    case "${2:-}" in
      list) sed -n 's/^\([0-9]*\)$/\1/p' "$S/roadmap-nums.txt" 2>/dev/null || printf '31\n' ;;
      view) cat "$S/roadmap-body.txt" ;;
      edit) printf 'move %s\n' "$3" >> "$STUB_CALLS" ;;
    esac
    exit 0 ;;
  api)
    if [ "$method" != "GET" ]; then printf '%s %s\n' "$method" "$url" >> "$STUB_CALLS"; exit 0; fi
    case "$url" in
      */labels/*) grep -Fqx "${url##*/labels/}" "$S/labels.txt" ;;
      */issues/[0-9]*)
        # per-issue re-read before a move (thread 5). Fixture: $S/issue-<n>-labels.txt, else none.
        n="${url##*/issues/}"
        if [ -f "$S/issue-$n-labels.txt" ]; then cat "$S/issue-$n-labels.txt"; else printf '\n'; fi ;;
      *"/milestones?"*) cat "$S/milestones.tsv" ;;
      *"/issues?milestone="*)
        n="${url#*milestone=}"; n="${n%%&*}"
        if [ -f "$S/issues/$n.json" ]; then cat "$S/issues/$n.json"; else printf '[]\n'; fi ;;
    esac
    exit $? ;;
esac
exit 0
STUB
chmod +x "$SBIN/gh"
printf '31\n' > "$S/roadmap-nums.txt"

# rcx_stub <args...> : run with the fixture-backed stub gh, fresh call log each time.
rcx_stub() {
  STUB_CALLS="$work/calls.txt"; : > "$STUB_CALLS"
  OUT="$(S="$S" STUB_CALLS="$STUB_CALLS" PATH="$SBIN:$PATH" bash "$RC" "$@" 2>&1)"; RC_=$?
}
# rcx_auth <args...> : the SAME stub with its auth knob flipped, proving require_gh fails loud
# (never a silent no-op). One stub, two behaviors — a second near-identical stub would be the
# thing that drifts.
rcx_auth() { OUT="$(S="$S" STUB_AUTH_FAIL=1 PATH="$SBIN:$PATH" bash "$RC" "$@" 2>&1)"; RC_=$?; }

# ============================ fail-loud gh guard ============================
rcx_auth init;    no "$RC_" "init with unauthenticated gh exits nonzero";   has "$OUT" "not authenticated" "init surfaces the auth failure"
rcx_auth status;  no "$RC_" "status with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "status surfaces the auth failure"
rcx_auth roll --version v1;  no "$RC_" "roll with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "roll surfaces the auth failure"

# plan_of / calls_of : the emitted plan and the recorded mutations, pipe-joined so ORDER is one
# comparable string.
plan_of()  { printf '%s\n' "$OUT" | sed -n 's/^plan: //p' | tr '\n' '|'; }
calls_of() { tr '\n' '|' < "$STUB_CALLS"; }

WANT='rename milestone #9 "Next release" -> "v1.1.0"|create milestone "Next release"|move issue #99 -> "Backlog"|close milestone #9 ("v1.1.0")|'

fix_default
rcx_stub roll --version v1.1.0 --dry-run
yes "$RC_" "roll --dry-run on a met milestone exits 0"
eq "$(plan_of)" "$WANT" "dry-run plan is rename -> create -> move -> close"
has "$OUT" "dry-run: no changes made" "dry-run says it changed nothing"
eq "$(calls_of)" "" "dry-run performs NO mutations"
has "$OUT" '"Next release" -> "v1.1.0"' "rolling title resolved from the artifact marker"

fix_default
rcx_stub roll --version v1.1.0
yes "$RC_" "roll on a met milestone exits 0"
eq "$(calls_of)" 'PATCH repos/acme/widget/milestones/9|POST repos/acme/widget/milestones|move 99|PATCH repos/acme/widget/milestones/9|' \
  "executed order is rename -> create -> move -> close"
has "$OUT" "rolled: 'Next release' -> 'v1.1.0'" "success emits one audit line"
has "$OUT" "marker is unchanged" "success states the marker needed no edit"

# The plan the operator READ and the mutations that RAN come from one record list, so a dry-run
# and a real run must describe the same operations in the same order.
fix_default; rcx_stub roll --version v1.1.0 --dry-run; PLAN_DRY="$(plan_of)"
fix_default; rcx_stub roll --version v1.1.0;           PLAN_RUN="$(plan_of)"
eq "$PLAN_RUN" "$PLAN_DRY" "the executed run prints the same plan the dry-run did"

# A fully-drained milestone (nothing open to disposition) still rolls -- just with no move step.
fix_default
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]}]'
rcx_stub roll --version v1.1.0 --dry-run
yes "$RC_" "roll works when there are no leftovers to move"
eq "$(plan_of)" 'rename milestone #9 "Next release" -> "v1.1.0"|create milestone "Next release"|close milestone #9 ("v1.1.0")|' \
  "no leftovers -> no move step"

# An unlabelled leftover is still a leftover.
fix_default
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
      {"number":99,"state":"open","state_reason":null,"labels":[]}]'
rcx_stub roll --version v1.1.0 --dry-run
eq "$(plan_of)" "$WANT" "an issue with no labels is moved like any other leftover"

# The artifact is never a backlog item and never counted; a PR carrying the milestone is neither.
# (`repos/.../issues` returns PRs too -- re-milestoning one would corrupt it and make roll's count
# disagree with the `is:issue` readiness query.)
fix_default
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
      {"number":99,"state":"open","state_reason":null,"labels":[{"name":"enhancement"}]},
      {"number":31,"state":"open","state_reason":null,"labels":[{"name":"roadmap"}]},
      {"number":50,"state":"open","state_reason":null,"labels":[],"pull_request":{"url":"x"}}]'
rcx_stub roll --version v1.1.0 --dry-run
eq "$(plan_of)" "$WANT" "the roadmap artifact and open PRs are never moved and never counted"

# --- refusals: every one is checked BEFORE any mutation --------------------------------------
fix_default
rcx_stub roll --version "Next release"
no "$RC_" "roll refuses when --version is the rolling title itself"
has "$OUT" "is the rolling title itself" "the collision is named"
eq "$(calls_of)" "" "no mutation before the rolling-title refusal"

fix_default
rcx_stub roll --version Backlog
no "$RC_" "roll refuses when --version is the backlog title"
eq "$(calls_of)" "" "no mutation before the backlog-title refusal"

# An OPEN must-have blocks on TWO independent guards, and both are asserted because they fail at
# different layers: the readiness verdict catches it first, and if that is waived, the demotion
# refusal catches it again. Losing either one silently demotes a release requirement to Backlog.
fix_default
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
      {"number":99,"state":"open","state_reason":null,"labels":[{"name":"release-blocker"}]}]'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses while an open release-blocker remains"
has "$OUT" "verdict is 'unmet'" "the readiness guard fires first"
eq "$(calls_of)" "" "no mutation before the open-blocker refusal"
rcx_stub roll --version v1.1.0 --force
no "$RC_" "--force still refuses to demote an open must-have"
has "$OUT" "will not demote a must-have" "the demotion guard survives --force"
eq "$(calls_of)" "" "no mutation under --force with an open blocker"

# A NOT_PLANNED blocker -> predicate `held` -> withheld, and the message names the owner's options.
fix_default
iss '[{"number":74,"state":"closed","state_reason":"not_planned","labels":[{"name":"release-blocker"}]}]'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses on the held verdict"
has "$OUT" "held" "the held verdict is named"
eq "$(calls_of)" "" "no mutation before the held refusal"
# --force is exactly the documented override for `held` (nothing is OPEN, so nothing is demoted).
rcx_stub roll --version v1.1.0 --force
yes "$RC_" "--force overrides the held verdict"
has "$OUT" "skipping the readiness re-check" "--force says what it waived"

# An empty milestone is `unarmed` -- there is nothing to archive.
fix_default; iss '[]'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses an unarmed (empty) milestone"
has "$OUT" "nothing to archive" "the unarmed refusal explains itself"

# Mode selection is keyed off label EXISTENCE: with no `release-blocker` label the bar is
# "no open issues at all", so the same fixture that is `met` in blocker-mode is `unmet` here.
fix_default; printf 'post-deploy\n' > "$S/labels.txt"
rcx_stub roll --version v1.1.0
no "$RC_" "with no release-blocker label the fallback bar applies"
has "$OUT" "verdict is 'unmet'" "fallback mode counts every open issue"

# --- marker resolution refusals ---------------------------------------------------------------
# The default title is never a fallback: a repo that opted in under a custom name has no
# "Next release" milestone at all, so guessing it would roll the wrong thing.
fix_default; marker '<!-- ai-dev-baseline:roadmap:v1 -->\n'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the artifact carries no marker"
has "$OUT" "no usable" "the marker failure is named"
eq "$(calls_of)" "" "no mutation when the marker cannot be resolved"

# The schema's own example token is a placeholder, not a milestone (same carve-out /roadmap uses).
fix_default; marker '<!-- release-milestone: NAME -->\n'
rcx_stub roll --version v1.1.0
no "$RC_" "the literal placeholder NAME is not treated as a title"

# Two different marker values is ambiguous -- never guess.
fix_default; marker '<!-- release-milestone: Next release -->\n<!-- release-milestone: Other -->\n'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the artifact names two different titles"
has "$OUT" "names 2 different release-milestone titles" "the ambiguity is quantified"

# ...including two on the SAME line, which a greedy match would silently collapse to one.
fix_default; marker '<!-- release-milestone: Next release --> x <!-- release-milestone: Other -->\n'
rcx_stub roll --version v1.1.0
no "$RC_" "two markers on one line are still ambiguous"

# --release-name is the explicit override when there is no usable marker.
fix_default; marker '<!-- ai-dev-baseline:roadmap:v1 -->\n'
rcx_stub roll --version v1.1.0 --release-name "Next release" --dry-run
yes "$RC_" "--release-name overrides marker resolution"
eq "$(plan_of)" "$WANT" "the override produces the same plan"

# --- state classification: already-rolled is a clean refusal, not a second rename -------------
fix_default; ms 'v1.1.0\tclosed\t9\nNext release\topen\t12\nBacklog\topen\t8\n'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the version milestone is already closed"
has "$OUT" "already rolled" "the already-rolled state is named"
eq "$(calls_of)" "" "no mutation when already rolled"

# A missing rolling title does NOT prove a rename happened -- an unrelated open milestone can
# carry the version name (real repos keep version-named planning milestones). So the two halves
# split: RECREATING the rolling title is safe under either explanation and always runs (it is what
# un-blocks /roadmap); treating #9 as this roll's ARCHIVE is destructive and needs --resume.
fix_default; ms 'v1.1.0\topen\t9\nBacklog\topen\t8\n'
rcx_stub roll --version v1.1.0 --dry-run
yes "$RC_" "a missing rolling title still produces a plan"
eq "$(plan_of)" 'create milestone "Next release"|' \
  "only the safe repair is planned without --resume -- no move, no close"
has "$OUT" "is NOT assumed to be this roll's archive" "it says why it stopped short"
rcx_stub roll --version v1.1.0 --resume --dry-run
yes "$RC_" "--resume finishes an interrupted roll"
eq "$(plan_of)" 'create milestone "Next release"|move issue #99 -> "Backlog"|close milestone #9 ("v1.1.0")|' \
  "--resume skips the done rename and finishes the tail"

# Both milestones open = interrupted-after-create OR a pre-existing version-named milestone. The
# tracker cannot tell them apart, so roll refuses and asks. Emptiness of the rolling milestone is
# deliberately NOT the discriminator: roll's own success banner tells the operator to slate the
# next release into it, so a real interrupted roll stops looking empty almost immediately -- and a
# genuinely pre-existing milestone alongside a not-yet-slated rolling one looks empty, which would
# archive and close a milestone that was never part of any roll.
for rolling_fixture in EMPTY SLATED; do
  fix_default; ms 'v1.1.0\topen\t9\nNext release\topen\t12\nBacklog\topen\t8\n'
  [ "$rolling_fixture" = SLATED ] && printf '%s' "$ISS_MET" > "$S/issues/12.json"
  rcx_stub roll --version v1.1.0
  no "$RC_" "two open milestones ($rolling_fixture rolling) refuse without --resume"
  has "$OUT" "re-run with --resume" "the refusal names the way forward ($rolling_fixture)"
  eq "$(calls_of)" "" "no mutation before the ambiguity refusal ($rolling_fixture)"

  rcx_stub roll --version v1.1.0 --resume --dry-run
  yes "$RC_" "--resume finishes the tail ($rolling_fixture)"
  eq "$(plan_of)" 'move issue #99 -> "Backlog"|close milestone #9 ("v1.1.0")|' \
    "--resume skips the done rename and create ($rolling_fixture)"
  rm -f "$S/issues/12.json"
done

# A resume must NOT be re-authorized against a tracker that has changed since. After the rename the
# rolling title does not exist, so /roadmap is hard-stopped; re-running the readiness gate there
# would refuse and leave no in-tool way to restore the title.
fix_default; ms 'v1.1.0\topen\t9\nBacklog\topen\t8\n'
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
      {"number":88,"state":"open","state_reason":null,"labels":[{"name":"release-blocker"}]}]'
rcx_stub roll --version v1.1.0
has "$OUT" "readiness re-check is skipped" "a resume does not re-run the readiness gate"
# ...but it still must not demote the reopened must-have. It does the REPAIR (recreate the rolling
# title, which un-blocks /roadmap and moves nothing) and stops before the move/close.
has "$OUT" "Recreating 'Next release' anyway" "the repair step runs despite the open blocker"
eq "$(calls_of)" 'POST repos/acme/widget/milestones|' "repair creates the rolling milestone and nothing else"
has "$OUT" "still OPEN and NOT rolled" "the partial state is reported honestly"
no "$RC_" "an unfinished roll exits nonzero"
# The archive has been renamed, so the blocker report must name it by its CURRENT title.
has "$OUT" "('v1.1.0')" "the blocker report names the milestone's current title, not the old one"

# Missing Backlog is a refusal -- never leave issues milestone-less halfway through. The advice
# must NOT be "run init": in a renamed-backlog repo that would create a SECOND backlog.
fix_default; ms 'Next release\topen\t9\n'
rcx_stub roll --version v1.1.0
no "$RC_" "roll refuses when the Backlog milestone is absent"
has "$OUT" "--backlog-name" "the refusal points at the override, not at init"
hasnt "$OUT" "baseline release init" "the refusal never advises init, which would create a SECOND backlog"

# ...and --backlog-name makes a renamed backlog work.
fix_default; ms 'Next release\topen\t9\nIcebox\topen\t8\n'
rcx_stub roll --version v1.1.0 --backlog-name Icebox --dry-run
yes "$RC_" "--backlog-name names a renamed backlog milestone"
has "$(plan_of)" 'move issue #99 -> "Icebox"' "leftovers go to the named backlog"
rcx_stub roll --version v1.1.0 --backlog-name ''
no "$RC_" "--backlog-name rejects an empty value"

fix_default

# --- bot-review findings on PR #91 -----------------------------------------------------------

# The backlog target must not be the milestone being rolled. Leftovers move BY TITLE after the
# fresh milestone exists, so a backlog named the same as the rolling title would move every
# leftover into the NEW release milestone -- arming it with zero open blockers, which makes
# /roadmap emit another cut immediately. Exactly the trap the Backlog rule exists to prevent.
fix_default
rcx_stub roll --version v1.1.0 --backlog-name "Next release"
no "$RC_" "roll refuses a backlog target equal to the rolling title"
has "$OUT" "arming it with zero" "the refusal explains the trap"
eq "$(calls_of)" "" "no mutation before the backlog==rolling refusal"

# The roadmap artifact is excluded BY NUMBER, and that number is resolved in the CALLER's shell --
# resolve_rolling_title is read through $( ), so a value it assigned would die with the subshell
# and the artifact would be swept into Backlog as a "leftover".
fix_default
iss '[{"number":74,"state":"closed","state_reason":"completed","labels":[{"name":"release-blocker"}]},
      {"number":31,"state":"open","state_reason":null,"labels":[{"name":"roadmap"}]}]'
rcx_stub roll --version v1.1.0 --dry-run
eq "$(plan_of)" 'rename milestone #9 "Next release" -> "v1.1.0"|create milestone "Next release"|close milestone #9 ("v1.1.0")|' \
  "the artifact is excluded by number and never moved"

# Thread 5: the plan is built from ONE snapshot, but the guarantee "not even --force demotes an
# open must-have" has to hold at MUTATION time. An issue that gains the label after planning must
# stop the move -- and the archive must not be closed with an open blocker in it.
fix_default
printf 'enhancement\nrelease-blocker\n' > "$S/issue-99-labels.txt"
rcx_stub roll --version v1.1.0
no "$RC_" "a leftover that gained the blocker label mid-run stops the move"
has "$OUT" "since the plan was built" "the mid-run label change is named as the reason"
# The rename+create already ran; the MOVE must not have.
hasnt "$(calls_of)" "move 99" "the must-have is never moved once it is re-read as a blocker"
rm -f "$S/issue-99-labels.txt"

# ...and the final pre-close check refuses to seal an archive that now holds an open must-have.
fix_default
printf 'enhancement\n' > "$S/issue-99-labels.txt"
cat > "$SBIN/gh.close-race" <<'RACE'
RACE
rcx_stub roll --version v1.1.0
yes "$RC_" "the ordinary path still completes when nothing changed mid-run"
has "$(calls_of)" "move 99" "the leftover is moved when it is still a non-blocker at mutation time"
rm -f "$S/issue-99-labels.txt" "$SBIN/gh.close-race"

check_summary "release-convention"
