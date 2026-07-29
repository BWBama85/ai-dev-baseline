#!/usr/bin/env bash
# ai-dev-baseline — release-goal convention setup (the OPTIONAL module of issue #27).
#
# Some projects run a rolling release convention: a "Next release" milestone holds the
# issues that are the next release's scope, a standing "Backlog" milestone holds everything
# not slated for it, and a `release-blocker` label marks the must-haves. The `/roadmap`
# skill reads this live every run to decide when a release is READY (0 open release-blockers
# in the active release milestone) and emits the release command — turning a divergent
# backlog into a terminating loop (issue #71). See docs/release-goal-convention.md.
#
# The convention is OPT-IN and detected, never assumed: a repo that never sets the
# `<!-- release-milestone: NAME -->` marker on its roadmap artifact keeps the classic
# backlog-wide behavior. This helper stands the convention up in the CURRENT repo (resolved
# from your gh remote, not the install-source clone) with one command, idempotently — `init`
# creates only what is absent and never deletes or renames anything. `roll` (below) is the one
# subcommand that mutates existing milestones, and only after a release is cut: it renames the
# release milestone to the version and closes it. It never deletes anything either.
#
# It lives in scripts/lib/ and so installs transitively into every ~/.<agent>/scripts/lib
# (the whole dir is symlinked, like skill-compose.sh); `baseline release …` dispatches here.
#
# Usage:
#   release-convention.sh init            # create the milestones + labels; seed the marker
#   release-convention.sh init --release-name NAME   # use a custom release-milestone name
#   release-convention.sh status          # report which pieces are present (no changes)
#   release-convention.sh roll --version VERSION [--dry-run] [--force] [--resume]
#                              [--release-name NAME] [--backlog-name NAME]
#                                         # roll the milestone AFTER a release is cut (#74)
#   release-convention.sh -h | --help
#
# `roll` is the rollover half of the convention: once your project-owned release action has cut
# the release, `roll` archives the release milestone under the version, opens a fresh empty one
# under the rolling title, and sends the leftover non-blocker issues to Backlog. It is
# milestone bookkeeping only — it never bumps a version, writes a changelog, tags, packages,
# publishes, or deploys. Those stay project-owned (#3), and this file must never grow them.
#
# Requires: gh (authenticated for this repo's remote).

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way the sibling scripts/lib modules
# do (skill-compose.sh, project-gates.sh) — not bin/baseline's PATH-symlink walk, which is inert
# here. adb_usage / adb_info vanish without it, so a missing library FAILS LOUD.
# Resolved ONCE: `roll` also needs the sibling roadmap-lib.sh, and two copies of this dirname
# expression are two things to keep in step if the install layout ever changes.
_adb_rc_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_rc_common="$_adb_rc_libdir/common.sh"
if [ ! -f "$_adb_rc_common" ]; then
  printf 'release-convention: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_rc_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_rc_common"

usage() { adb_usage "$0"; }

# Defaults — the convention's canonical names. --release-name overrides the milestone only.
RELEASE_MILESTONE="Next release"
BACKLOG_MILESTONE="Backlog"
BLOCKER_LABEL="release-blocker"
POSTDEPLOY_LABEL="post-deploy"

# --- gh helpers --------------------------------------------------------------------------
REPO_SLUG=""

# Fail loud on a missing/unauthenticated gh or a repo with no resolvable remote (a hard stop,
# like the roadmap skill) — never a silent no-op. Runs in the PARENT shell (top of each
# subcommand), so it also caches REPO_SLUG once here — the resolve doubles as the remote check,
# and every later `$(repo_slug)` subshell inherits it instead of re-running `gh repo view`.
require_gh() {
  adb_require_gh || exit 1
  REPO_SLUG="$(adb_repo_slug)" || exit 1
}

repo_slug() { printf '%s' "$REPO_SLUG"; }

# milestone_field <title> <state:all|open> <field:state|number> -> the field of the first
# milestone with that EXACT title in the given state set, or empty. One query for both callers.
# The title is matched in awk (not interpolated into the jq filter, which stays FIXED), so a
# title containing quotes or jq metacharacters can never break or inject into the query.
# `state=all` is used to detect a closed same-name milestone so it is never silently duplicated.
milestone_field() {
  local title="$1" state="$2" field="$3"
  gh api --paginate "repos/$(repo_slug)/milestones?state=$state&per_page=100" \
    --jq '.[] | [.title, .state, (.number|tostring)] | @tsv' 2>/dev/null \
    | awk -F'\t' -v t="$title" -v f="$field" '$1==t { print (f=="state" ? $2 : $3); exit }'
}

# ensure_milestone <title> — guarantee an OPEN milestone with this title exists. GitHub has no
# upsert. Check OPEN first (so an open one is never misreported when a same-title closed one is
# listed ahead of it). A CLOSED same-title milestone must be REOPENED, not left as-is: the whole
# point of init is a usable OPEN milestone, and a duplicate title can't be re-created anyway
# (GitHub 422s it), so reopening is the only path to an open milestone with this title — leaving
# it "closed but ok" would let init print Done while /roadmap then hard-stops on zero open matches.
# Else POST; swallow ONLY the duplicate 422 (already_exists), hard-fail every other error.
ensure_milestone() {
  local title="$1" num out rc
  if [ -n "$(milestone_field "$title" open number)" ]; then
    adb_info "  ok       milestone '$title' (already open)"; return 0
  fi
  num="$(milestone_field "$title" all number)"
  if [ -n "$num" ]; then
    if gh api -X PATCH "repos/$(repo_slug)/milestones/$num" -f state=open >/dev/null 2>&1; then
      adb_info "  reopened milestone '$title' (was closed)"; return 0
    fi
    echo "ERROR: milestone '$title' exists but is closed (#$num) and could not be reopened — reopen it manually" >&2
    return 1
  fi
  out="$(gh api -X POST "repos/$(repo_slug)/milestones" -f title="$title" -f state=open 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    adb_info "  created  milestone '$title'"
  elif printf '%s' "$out" | grep -q 'already_exists'; then
    adb_info "  ok       milestone '$title' (already exists — created concurrently)"
  else
    echo "ERROR: could not create milestone '$title': $out" >&2
    return 1
  fi
}

# label_exists <name> -> 0 if the label exists in the repo, 1 otherwise.
#
# A direct 200/404 probe on the label endpoint, which is exact at any repo size and is the SAME
# mechanism base/workflows/roadmap.md specifies for the readiness mode switch. Listing labels and
# grepping would silently disagree with the workflow in a repo carrying more labels than the page
# cap — and mode selection turning on a page cap is precisely the class of bug #79 is about.
label_exists() {
  gh api "repos/$(repo_slug)/labels/$1" >/dev/null 2>&1
}

# ensure_label <name> <color> <desc> — create it if absent; report if present.
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if label_exists "$name"; then
    adb_info "  ok       label '$name' (already exists)"
    return 0
  fi
  if gh label create "$name" --color "$color" --description "$desc" >/dev/null 2>&1; then
    adb_info "  created  label '$name'"
  else
    echo "ERROR: could not create label '$name'" >&2
    return 1
  fi
}

# announce_marker — print the ONE activation step: add the release-milestone marker to the
# roadmap artifact. We deliberately do NOT edit the artifact: /roadmap is its sole writer, and a
# blind body rewrite risks clobbering the one artifact the whole loop depends on (and a bare
# marker-presence grep would be fooled by the schema's own example comment). Read-only; names the
# roadmap issue when exactly one exists.
announce_marker() {
  local nums count num
  nums="$(roadmap_issue_nums)"
  count="$(printf '%s\n' "$nums" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = "1" ] && ROADMAP_NUM="$(printf '%s\n' "$nums" | head -n1)"
  if [ "$count" = "1" ]; then
    num="$(printf '%s\n' "$nums" | head -n1)"
    adb_info "  marker   activate /roadmap release-readiness by adding this line to roadmap issue #$num:"
  elif [ "$count" = "0" ]; then
    adb_info "  marker   activate /roadmap release-readiness — run /roadmap once, then add to its body:"
  else
    adb_info "  marker   activate /roadmap release-readiness — add to the right roadmap issue ($count found):"
  fi
  adb_info "             <!-- release-milestone: $RELEASE_MILESTONE -->"
  # BOTH markers, because both are required to reach a cut. `release-milestone` arms readiness;
  # `release-command` is what a met verdict emits — and it has NO default, deliberately: an
  # unresolvable slash command fuzzy-matches an unrelated built-in rather than failing (#188), and
  # #3/D7 guarantees the baseline ships no `/release` to fall back on. Announcing only the first
  # marker sends a project through the prescribed one-command setup into release-readiness mode
  # with no way to cut, discovering it only at `Next: none` when the release is finally ready.
  # AGENT-NEUTRAL on purpose. This helper installs into every agent and cannot know which one will
  # read the artifact, and the invocation prefix differs (Claude/Antigravity `/skill`, Codex
  # `$skill`). Printing one agent's form would hand a Codex adopter the exact value its resolver
  # rejects — the failure this marker exists to prevent, introduced by the initializer.
  adb_info "             <!-- release-command: <your-release-skill> -->"
  adb_info "  note     use YOUR agent's invocation syntax for the value (Claude/Antigravity"
  adb_info "           /your-release-skill, Codex \$your-release-skill). The release command is"
  adb_info "           REQUIRED and has no default; /roadmap emits it only if it resolves to an"
  adb_info "           installed skill. Release execution is project-owned (#3)."
}

cmd_init() {
  require_gh
  adb_info "Setting up the release-goal convention in $(repo_slug):"
  local rc=0
  ensure_milestone "$RELEASE_MILESTONE" || rc=1
  ensure_milestone "$BACKLOG_MILESTONE" || rc=1
  ensure_label "$BLOCKER_LABEL"    "b60205" "Must-ship for the active release milestone (/roadmap readiness gate)" || rc=1
  ensure_label "$POSTDEPLOY_LABEL" "5319e7" "Can only happen after a release ships" || rc=1
  announce_marker
  adb_info ""
  if [ "$rc" -ne 0 ]; then
    echo "release-convention: init finished with errors (see above)." >&2
    return 1
  fi
  adb_info "Done. Next steps:"
  adb_info "  1. Put the issues that are this release's scope into '$RELEASE_MILESTONE';"
  adb_info "     label the must-haves '$BLOCKER_LABEL'. Everything else goes to '$BACKLOG_MILESTONE'."
  adb_info "  2. New discoveries default to '$BACKLOG_MILESTONE' so the release set stays frozen."
  adb_info "  3. (optional) Point /roadmap's destination-label marker at '$BLOCKER_LABEL' for a live"
  adb_info "     distance-to-cut each run:  <!-- destination-label: $BLOCKER_LABEL -->"
  adb_info ""
  adb_info "/roadmap now computes release readiness live and emits the release command when 0"
  adb_info "'$BLOCKER_LABEL' issues remain open in '$RELEASE_MILESTONE'. See docs/release-goal-convention.md."
}

cmd_status() {
  require_gh
  local rnum bnum
  rnum="$(milestone_field "$RELEASE_MILESTONE" open number)"
  bnum="$(milestone_field "$BACKLOG_MILESTONE" open number)"
  adb_info "Release-goal convention in $(repo_slug):"
  adb_info "  release milestone '$RELEASE_MILESTONE': $([ -n "$rnum" ] && echo "present (#$rnum)" || echo "ABSENT")"
  adb_info "  backlog milestone '$BACKLOG_MILESTONE': $([ -n "$bnum" ] && echo "present (#$bnum)" || echo "ABSENT")"
  adb_info "  label '$BLOCKER_LABEL': $(label_exists "$BLOCKER_LABEL" && echo present || echo ABSENT)"
  adb_info "  label '$POSTDEPLOY_LABEL': $(label_exists "$POSTDEPLOY_LABEL" && echo present || echo ABSENT)"
  adb_info ""
  # BOTH markers are reported, because both are required to reach a cut. Reporting only the
  # milestone let a user run the documented status check, see nothing missing, and discover the
  # incomplete convention at `Next: none` when the release was finally ready (#188).
  # EXACTLY ONE artifact, like /roadmap. `head -n1` over a split brain would report the marker as
  # declared or absent based on an arbitrary issue, while the convention cannot run at all.
  local rc_body rc_vals rc_n rnums rcount
  rc_body=""; rc_vals=""; rc_n=0
  rnums="$(roadmap_issue_nums)"
  rcount="$(printf '%s\n' "$rnums" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$rcount" = "1" ]; then
    rc_body="$(gh issue view "$(printf '%s\n' "$rnums" | sed '/^$/d' | head -n1)" --json body --jq .body 2>/dev/null || true)"
    if [ -n "$rc_body" ]; then
      rc_vals="$(printf '%s' "$rc_body" | bash "$(dirname "${BASH_SOURCE[0]}")/roadmap-lib.sh" release-command 2>/dev/null || true)"
      rc_n="$(printf '%s\n' "$rc_vals" | sed '/^$/d' | wc -l | tr -d ' ')"
    fi
  fi
  if [ "$rcount" = "1" ]; then
    case "$rc_n" in
      0) adb_info "  release-command marker: ABSENT — REQUIRED, and it has no default" ;;
      1) adb_info "  release-command marker: declared ($(printf '%s\n' "$rc_vals" | head -n1))" ;;
      *) adb_info "  release-command marker: AMBIGUOUS ($rc_n values declared — need exactly 1)" ;;
    esac
  elif [ "$rcount" = "0" ]; then
    adb_info "  release-command marker: UNKNOWN — no open roadmap-labelled issue to read"
  else
    adb_info "  release-command marker: UNKNOWN — $rcount roadmap-labelled issues (split brain);"
    adb_info "                          /roadmap hard-stops on this. Retire all but one."
  fi
  adb_info ""
  if [ -n "$rnum" ]; then
    adb_info "Primitives present. /roadmap runs in release-readiness mode once its artifact carries"
    adb_info "the marker:  <!-- release-milestone: $RELEASE_MILESTONE -->"
    if [ "$rcount" = "1" ] && [ "$rc_n" != "1" ]; then
      adb_info "It will still stop at 'Next: none' when the release is ready until the artifact also"
      adb_info "declares:    <!-- release-command: <your-release-skill> -->"
      adb_info "using YOUR agent's invocation syntax. /roadmap emits it only if it resolves."
    fi
  else
    adb_info "Convention INACTIVE — /roadmap uses classic backlog-wide mode. Run 'init' to opt in."
  fi
}

# === roll — the release rollover contract (#74) ===========================================
#
# WHY THIS LIVES IN THE BASELINE AND NOT IN A PROJECT'S /release (#3):
# #3 decided release EXECUTION is permanently project-owned because the four surveyed projects
# cut releases four incompatible ways (SemVer+git-cliff, SemVer+GHCR+cosign, CalVer, WP-plugin
# zip). Milestone rollover is the opposite: it has exactly ONE correct shape, because it is
# bookkeeping on primitives THIS FILE ALREADY CREATES in `init`. Leaving it to each project meant
# every project re-derived it, and getting it wrong strands the loop (see the `met` trap below).
# The boundary this file must never cross: no version bump, no changelog, no tag, no package, no
# publish, no deploy. `scripts/check-release-role.sh` pins that.

ROLL_VERSION=""
ROLL_DRY_RUN=0
ROLL_FORCE=0
ROLL_RESUME=0
ROADMAP_NUM=0   # the canonical roadmap artifact, excluded from the milestone tabulation
RELEASE_NAME_SET=0   # 1 when --release-name was passed explicitly

# roadmap_issue_nums — the open `roadmap`-labelled issue numbers, blanks stripped, one per line.
# ONE home for "where is the roadmap artifact", shared with announce_marker: the exactly-one rule
# is a contract (a second labelled issue is the split brain /roadmap hard-stops on), and a
# contract stated twice is a contract that drifts.
roadmap_issue_nums() {
  gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number' 2>/dev/null \
    | sed '/^$/d'
}

# create_milestone_strict <title> — POST a NEW open milestone. Deliberately NOT ensure_milestone():
# that helper REOPENS a closed same-title milestone, which is right for `init` and catastrophic
# here — it would resurrect the freshly-archived version milestone as a second open one. It also
# swallows the `already_exists` 422 as success, which during a roll means the tracker is not in
# the state the plan was computed from. Create-only; every failure is hard.
create_milestone_strict() {
  local title="$1" out rc
  out="$(gh api -X POST "repos/$(repo_slug)/milestones" -f title="$title" -f state=open 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "ERROR: could not create milestone '$title': $out" >&2
  return 1
}

# milestone_table — every milestone in the repo as `title<TAB>state<TAB>number`, fetched ONCE.
# The roll preflight needs four facts about three titles; asking milestone_field for each is four
# full paginated sweeps of the same list (and on a milestone-heavy repo, four multi-page walks).
# All four reads happen before any mutation, so a single snapshot cannot go stale between them.
milestone_table() {
  gh api --paginate "repos/$(repo_slug)/milestones?state=all&per_page=100" \
    --jq '.[] | [.title, .state, (.number|tostring)] | @tsv' 2>/dev/null
}

# table_field <table> <title> <field:state|number> [state-filter] — look up one milestone in an
# already-fetched table. The title is matched in awk (never interpolated into a jq filter), so a
# title carrying quotes or jq metacharacters can neither break nor inject into the query.
table_field() {
  printf '%s\n' "$1" | awk -F'\t' -v t="$2" -v f="$3" -v want="${4:-}" '
    $1 == t && (want == "" || $2 == want) { print (f == "state" ? $2 : $3); exit }'
}

# milestone_issues_json <number> — the milestone's issues (open AND closed) as raw JSON, for
# roadmap-lib.sh's release-counts. `--paginate`, never a `--limit` page cap (cf. #79). No `--jq`
# here on purpose: the tabulation rules live in the shared lib, so this only fetches.
milestone_issues_json() {
  gh api --paginate "repos/$(repo_slug)/issues?milestone=$1&state=all&per_page=100" 2>/dev/null
}

# roll_plan — the ordered list of mutations, ONE record per line: `op<TAB>arg…`. Building it as a
# VALUE rather than printing it means the order has a single source: step 6 renders these records
# and step 7 executes the same records. A print-then-do split would state the order twice, with a
# test as the only thing forcing the two copies to agree.
ROLL_PLAN=""
roll_plan_add() { ROLL_PLAN="${ROLL_PLAN}$1"$'\n'; }

# roll_plan_render — the human-readable plan, in execution order. Also what --dry-run prints and
# what the offline checks assert, so the order is pinned by the same string the operator reads.
roll_plan_render() {
  printf '%s' "$ROLL_PLAN" | while IFS="$(printf '\t')" read -r op a b; do
    [ -n "$op" ] || continue
    case "$op" in
      rename) adb_info "plan: rename milestone #$a \"$b\" -> \"$ROLL_VERSION\"" ;;
      create) adb_info "plan: create milestone \"$a\"" ;;
      move)   adb_info "plan: move issue #$a -> \"$b\"" ;;
      close)  adb_info "plan: close milestone #$a (\"$ROLL_VERSION\")" ;;
    esac
  done
}

# resolve_rolling_title — print the rolling milestone's title, or refuse.
#
# The built-in default is NOT an acceptable fallback: `--release-name` is a per-invocation flag
# that `init` never persisted anywhere, so a repo that opted in with
# `baseline release init --release-name "v2.0"` has no "Next release" milestone at all — rolling
# the default would target a milestone that does not exist, or (worse, in a repo that has both)
# roll the wrong one. The artifact marker is the only authoritative record of the rolling title,
# and it is the same value /roadmap resolves, so roll and /roadmap can never disagree.
#
# The marker GRAMMAR (and the placeholder carve-out) lives in roadmap-lib.sh, not here — it is a
# /roadmap decision, and a third dialect of it is how the three copies drift apart.

# Takes the already-fetched artifact numbers as an argument and is otherwise PURE: its caller
# reads it through `$( )`, i.e. a subshell, so anything it assigned would be discarded on return.
resolve_rolling_title() {
  local nums="$1" count num body titles tcount lib
  if [ "$RELEASE_NAME_SET" -eq 1 ]; then
    printf '%s\n' "$RELEASE_MILESTONE"; return 0
  fi

  lib="$_adb_rc_libdir/roadmap-lib.sh"
  [ -f "$lib" ] || { echo "ERROR: required library not found: $lib (broken/incomplete install)" >&2; return 1; }

  count="$(printf '%s\n' "$nums" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" != "1" ]; then
    echo "ERROR: expected exactly one open 'roadmap'-labelled issue to read the rolling milestone" >&2
    echo "       title from; found $count. Pass --release-name NAME to name it explicitly." >&2
    return 1
  fi
  num="$(printf '%s\n' "$nums" | head -n1)"
  body="$(gh issue view "$num" --json body --jq .body 2>/dev/null)" \
    || { echo "ERROR: could not read roadmap issue #$num" >&2; return 1; }

  titles="$(printf '%s\n' "$body" | bash "$lib" marker-title)"
  tcount="$(printf '%s\n' "$titles" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$tcount" = "1" ]; then
    printf '%s\n' "$titles"; return 0
  fi
  if [ "$tcount" = "0" ]; then
    echo "ERROR: roadmap issue #$num carries no usable <!-- release-milestone: NAME --> marker" >&2
    echo "       (absent, empty, or the literal placeholder 'NAME'), so this repo is not running" >&2
    echo "       the release-goal convention. Pass --release-name NAME to name the milestone" >&2
    echo "       explicitly, or run 'baseline release init' to opt in." >&2
    return 1
  fi
  echo "ERROR: roadmap issue #$num names $tcount different release-milestone titles:" >&2
  printf '%s\n' "$titles" | sed '/^$/d' | sed 's/^/         /' >&2
  echo "       Fix the artifact so exactly one is named, or pass --release-name NAME." >&2
  return 1
}

cmd_roll() {
  # Argument validation BEFORE require_gh: a usage error must report itself as a usage error
  # regardless of whether gh happens to be authenticated in this environment.
  [ -n "$ROLL_VERSION" ] \
    || { echo "ERROR: roll needs --version (the version you just cut, e.g. --version v1.2.0)" >&2; return 2; }

  require_gh

  # --- 1. Resolve the rolling title (authoritative: the artifact marker) --------------------
  # Fetch the artifact numbers HERE, in this shell. resolve_rolling_title is read through `$( )`,
  # so anything it assigned would die with its subshell — and a lost ROADMAP_NUM means the artifact
  # is not excluded from the tabulation and gets swept into Backlog as a "leftover".
  local rolling roadmap_nums
  roadmap_nums="$(roadmap_issue_nums)"
  if [ "$(printf '%s\n' "$roadmap_nums" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ]; then
    ROADMAP_NUM="$(printf '%s\n' "$roadmap_nums" | head -n1)"
  fi
  rolling="$(resolve_rolling_title "$roadmap_nums")" || return 1

  # --- 2. Preflight reads + refusals (ALL before any mutation) -----------------------------
  # (--version is validated non-empty by parse_roll_opts; the only reachable miss is its absence,
  #  caught above.)
  if [ "$ROLL_VERSION" = "$rolling" ]; then
    echo "ERROR: --version '$ROLL_VERSION' is the rolling title itself — the archive would collide" >&2
    echo "       with the milestone it archives, leaving zero open milestones under that title and" >&2
    echo "       hard-stopping /roadmap. Name the version you cut (e.g. v1.2.0)." >&2
    return 1
  fi
  if [ "$ROLL_VERSION" = "$BACKLOG_MILESTONE" ]; then
    echo "ERROR: --version must not be the backlog milestone title ('$BACKLOG_MILESTONE')" >&2
    return 1
  fi
  # The disposition target must not be the milestone being rolled. Leftovers are moved BY TITLE,
  # after the fresh milestone is created — so a backlog named the same as the rolling title would
  # move every leftover straight into the NEW release milestone, arming it with zero open blockers
  # and making /roadmap emit another cut immediately: the exact trap the Backlog rule prevents.
  if [ "$BACKLOG_MILESTONE" = "$rolling" ]; then
    echo "ERROR: the backlog milestone and the rolling milestone are both '$rolling'. Leftovers" >&2
    echo "       would be moved into the freshly-created release milestone, arming it with zero" >&2
    echo "       open blockers — /roadmap would emit another cut on its next run. Pass a" >&2
    echo "       --backlog-name that differs from the rolling title." >&2
    return 1
  fi

  local table cut_num ver_num ver_state backlog_num
  table="$(milestone_table)"
  cut_num="$(table_field "$table" "$rolling" number open)"
  ver_num="$(table_field "$table" "$ROLL_VERSION" number)"
  ver_state="$(table_field "$table" "$ROLL_VERSION" state)"
  backlog_num="$(table_field "$table" "$BACKLOG_MILESTONE" number open)"

  # Backlog is the disposition target — resolve it up front so a missing one is a refusal, never
  # issues left milestone-less halfway through. Do NOT advise `init` here: in a repo that renamed
  # its backlog, init would create a SECOND one rather than find the existing one.
  [ -n "$backlog_num" ] || {
    echo "ERROR: no OPEN milestone titled '$BACKLOG_MILESTONE' to disposition leftovers into." >&2
    echo "       Pass --backlog-name NAME if this repo's backlog milestone is named differently," >&2
    echo "       or create/reopen that milestone first." >&2
    return 1
  }

  # --- 3. Classify the tracker state so a re-run RESUMES instead of corrupting ---------------
  # GitHub has no transaction, so roll is built to be re-run after an interruption at any step.
  # The state is fully described by (version-milestone state) x (rolling milestone open?), and
  # every cell is reachable and distinct — hence a table, not a flat if-chain:
  #
  #   ver_state | rolling open | meaning                        | action
  #   ----------|--------------|--------------------------------|------------------------------
  #   absent    | yes          | fresh roll, nothing done       | rename + create + move + close
  #   absent    | no           | nothing to roll                | refuse
  #   open      | no           | interrupted after rename       | RESUME (unambiguous, and urgent)
  #   open      | yes          | interrupted after create, OR a pre-existing version-named
  #                              milestone — indistinguishable from tracker state | refuse unless --resume
  #   closed    | yes          | already rolled                 | refuse (nothing to do)
  #   closed    | no           | rolled, then rolling deleted   | refuse (tell them to re-init)
  #
  # `resume` means "this roll was already authorized and partially executed", which changes what
  # the gates in step 4 may do.
  local do_rename=0 do_create=0 resume=0 repair_pending=0
  case "$ver_state" in
    "")
      [ -n "$cut_num" ] || { echo "ERROR: no OPEN milestone titled '$rolling' to roll" >&2; return 1; }
      do_rename=1; do_create=1 ;;
    open)
      if [ -z "$cut_num" ]; then
        # A missing rolling title does NOT prove the rename took it — it could have been deleted,
        # renamed by hand, or never created, while an UNRELATED open milestone happens to carry the
        # version name (real repos do keep version-named milestones for planning). So split the two
        # things this state needs:
        #   * RECREATING the rolling title is safe under either explanation. It touches nothing
        #     else, and it is what un-blocks /roadmap, which hard-stops while no open milestone
        #     carries the marker's title. Always allowed.
        #   * TREATING #ver_num AS THIS ROLL'S ARCHIVE is destructive — it moves that milestone's
        #     issues out and closes it. That requires --resume, exactly like the both-open case.
        do_create=1; resume=1; cut_num="$ver_num"
        if [ "$ROLL_RESUME" -eq 1 ]; then
          adb_info "note: --resume — treating open milestone #$ver_num ('$ROLL_VERSION') as this roll's archive"
        else
          repair_pending=1
          adb_info "note: no open milestone titled '$rolling' — /roadmap is hard-stopped until one exists."
          adb_info "      Recreating it (safe: touches nothing else). Milestone #$ver_num ('$ROLL_VERSION')"
          adb_info "      is NOT assumed to be this roll's archive — it could be an unrelated"
          adb_info "      version-named milestone — so it is left untouched."
        fi
      elif [ "$ROLL_RESUME" -eq 1 ]; then
        resume=1; cut_num="$ver_num"
        adb_info "note: --resume — treating open milestone #$ver_num ('$ROLL_VERSION') as this roll's archive"
      else
        # Do NOT guess from "is the rolling milestone empty?". That signal is wrong in BOTH
        # directions: roll's own success banner tells the operator to slate the next release into
        # the fresh milestone, so a real interrupted roll stops looking empty almost immediately;
        # and a genuinely pre-existing version-named milestone alongside a not-yet-slated rolling
        # one looks empty, which would archive and close a milestone that was never ours.
        echo "ERROR: '$ROLL_VERSION' already exists as an OPEN milestone (#$ver_num), alongside an open" >&2
        echo "       '$rolling' (#$cut_num). That is either an interrupted roll (this command was" >&2
        echo "       killed between creating '$rolling' and closing the archive) or a pre-existing" >&2
        echo "       milestone that happens to carry the version name — the tracker cannot tell them" >&2
        echo "       apart, and guessing wrong would close a milestone that was never part of a roll." >&2
        echo "       If #$ver_num IS this roll's archive, re-run with --resume." >&2
        echo "       If it is not, pick a different --version, or rename/close #$ver_num first." >&2
        return 1
      fi ;;
    closed)
      if [ -n "$cut_num" ]; then
        echo "ERROR: already rolled — '$ROLL_VERSION' is a closed milestone (#$ver_num) and '$rolling'" >&2
        echo "       (#$cut_num) is open. Nothing to do." >&2
      else
        echo "ERROR: '$ROLL_VERSION' is closed (#$ver_num) but no open '$rolling' milestone exists —" >&2
        echo "       the roll completed and the rolling milestone was removed. Run 'baseline release" >&2
        echo "       init' to recreate it." >&2
      fi
      return 1 ;;
  esac

  # --- 4. Tabulate the milestone, then re-verify readiness LIVE and fail closed ---------------
  # roll is an outward-facing mutation gated on volatile tracker state, so it re-checks that state
  # at the moment it acts rather than trusting the /roadmap run that emitted the cut
  # (base/practices/verify-before-asserting.md — automated actors are in scope too). BOTH halves of
  # that check come from the shared lib: `release-counts` derives the five inputs and
  # `release-ready` decides. Re-deriving either here is how roll and /roadmap drift into
  # disagreeing about the same tracker (docs/design-principles.md: source the primitive, copy it never).
  local counts armed ob oi canceled movers blockers blk_exists verdict lib
  lib="$_adb_rc_libdir/roadmap-lib.sh"
  [ -f "$lib" ] || { echo "ERROR: required library not found: $lib (broken/incomplete install)" >&2; return 1; }

  counts="$(milestone_issues_json "$cut_num" | bash "$lib" release-counts "$BLOCKER_LABEL" "$ROADMAP_NUM")" \
    || { echo "ERROR: could not tabulate milestone #$cut_num — refusing to roll" >&2; return 1; }
  {
    read -r armed ob oi canceled
    read -r movers
    read -r blockers
  } <<EOF
$counts
EOF

  # A RESUME is not a fresh authorization. The decision to roll was made — and half executed —
  # against the tracker as it stood then; re-deciding it against a tracker that has changed since
  # is how a half-rolled repo becomes an unfinishable one. Concretely: after the rename the rolling
  # title does not exist, so /roadmap is hard-stopped; if a blocker were reopened in the archive at
  # that moment, re-running the readiness gate would refuse, --force could not get past the
  # demotion guard below, and there would be no in-tool way to restore the title at all.
  if [ "$resume" -eq 1 ]; then
    adb_info "note: resuming — the readiness re-check is skipped (this roll was already authorized)"
  elif [ "$ROLL_FORCE" -eq 1 ]; then
    adb_info "note: --force — skipping the readiness re-check"
  else
    # Mode is keyed off label EXISTENCE, never a live count — closing the last blocker must not
    # silently raise the bar from "no blockers left" to "no issues left" (roadmap-lib.sh).
    blk_exists=0; label_exists "$BLOCKER_LABEL" && blk_exists=1
    # `skipped` is an EXPLICIT, deliberate opt-out of #78's green-branch gate, not an oversight —
    # which is exactly why `release-ready` makes the argument REQUIRED rather than defaulted: the
    # decision is written here, at the call site, where a reviewer sees it.
    #
    # Rationale: this gate asks "are this milestone's REQUIREMENTS met", and roll is post-cut
    # BOOKKEEPING — it archives the milestone the operator already released; it ships nothing and
    # deploys nothing. Gating it on live CI would strand the repo in the failure #74 exists to
    # prevent: a branch that goes red after the tag would block the roll, leaving the milestone
    # open with zero open blockers, so /roadmap re-emits the same cut on every subsequent run and
    # the loop stops terminating. The green-branch gate belongs where the cut is DECIDED
    # (/roadmap's emission), which is where #78 put it.
    verdict="$(bash "$lib" release-ready "$blk_exists" "$armed" "$ob" "$oi" "$canceled" skipped)" \
      || { echo "ERROR: readiness predicate failed — refusing to roll" >&2; return 1; }
    if [ "$verdict" != "met" ]; then
      echo "ERROR: '$rolling' (#$cut_num) is not released — readiness verdict is '$verdict', not 'met'." >&2
      case "$verdict" in
        unarmed) echo "       The milestone holds no issues; there is nothing to archive." >&2 ;;
        unmet)   echo "       $ob open '$BLOCKER_LABEL' issue(s) / $oi open issue(s) remain." >&2 ;;
        held)    echo "       A '$BLOCKER_LABEL' was closed NOT_PLANNED — an abandoned must-have is an" >&2
                 echo "       owner decision. Reopen it, unlabel it, or drop it from the milestone." >&2 ;;
        # No arms for `not-green`/`indeterminate`: roll passes health=skipped, so they cannot
        # arise from this call, and a message asserting "health is gated elsewhere" would be
        # guaranteed WRONG in the only future that makes them reachable. The catch-all below
        # already reports any verdict this version does not know, which is the honest answer.
        *)       echo "       Unrecognised verdict '$verdict' — refusing to roll on an answer this version does not know." >&2 ;;
      esac
      echo "       Re-run with --force only if you are deliberately rolling an unreleased milestone." >&2
      return 1
    fi
  fi

  # An OPEN must-have is a refusal even under --force: --force waives the readiness VERDICT, not
  # the demotion. Moving a must-have to the backlog is an owner decision, never a bookkeeping
  # side effect — so this guard sits outside the --force branch on purpose.
  #
  # But it must not strand a half-rolled repo either. When a resume still owes the `create` that
  # restores the rolling title, that one step is REPAIR, not rollover: /roadmap is hard-stopped
  # until it runs, and it moves nothing and closes nothing. So do the repair, then stop short of
  # the steps the blockers actually forbid, and say exactly what is left.
  local repair_only="$repair_pending"
  if [ -n "$blockers" ]; then
    # Name the milestone by its CURRENT title — after a rename it is no longer called "$rolling",
    # and pointing the operator at a milestone that no longer exists is its own bug.
    local cut_title="$rolling"; [ "$do_rename" -eq 0 ] && cut_title="$ROLL_VERSION"
    if [ "$resume" -eq 1 ] && [ "$do_create" -eq 1 ]; then
      repair_only=1
      adb_info "note: open '$BLOCKER_LABEL' issue(s) in #$cut_num ('$cut_title'):$blockers"
      adb_info "      Recreating '$rolling' anyway — that step is repair (it un-blocks /roadmap and"
      adb_info "      moves nothing), then stopping before the move/close that would demote them."
    else
      echo "ERROR: open '$BLOCKER_LABEL' issue(s) in #$cut_num ('$cut_title'):$blockers" >&2
      echo "       roll will not demote a must-have to '$BACKLOG_MILESTONE'. Close them, remove the" >&2
      echo "       label, or move them out of the milestone yourself, then re-run." >&2
      return 1
    fi
  fi

  # --- 5. Build the plan, in execution order -------------------------------------------------
  # ORDERING IS LOAD-BEARING. Milestone titles are unique repo-wide across states, so the archive
  # rename must FREE the rolling title before the create (create-first 422s). Between the rename
  # and the create there is exactly one API call during which zero open milestones carry the
  # rolling title and /roadmap would hard-stop; that window is unavoidable, which is why step 3
  # classifies and resumes rather than pretending it away. The close comes LAST so an interruption
  # always leaves the archive open and therefore still resumable.
  #
  # Disposition is BACKLOG, never "roll forward into the fresh milestone". Rolling them forward
  # would arm the new milestone (armed = >=1 issue, open OR closed) with zero open blockers, so the
  # readiness predicate returns `met` on the very next /roadmap run and re-emits a cut for a
  # release that contains nothing. Backlog leaves the fresh milestone genuinely empty -> `unarmed`
  # -> "no requirements yet", and matches the convention's frozen-set rule (new work defaults to
  # Backlog; slating into a release is always a deliberate act).
  local n
  [ "$do_rename" -eq 1 ] && roll_plan_add "rename$(printf '\t')$cut_num$(printf '\t')$rolling"
  [ "$do_create" -eq 1 ] && roll_plan_add "create$(printf '\t')$rolling"
  if [ "$repair_only" -eq 0 ]; then
    for n in $movers; do roll_plan_add "move$(printf '\t')$n$(printf '\t')$BACKLOG_MILESTONE"; done
    roll_plan_add "close$(printf '\t')$cut_num"
  fi

  roll_plan_render

  if [ "$ROLL_DRY_RUN" -eq 1 ]; then
    adb_info ""
    adb_info "dry-run: no changes made."
    return 0
  fi

  # --- 6. Execute the SAME plan, record by record --------------------------------------------
  local op a b mv_labels final final_blockers
  while IFS="$(printf '\t')" read -r op a b; do
    [ -n "$op" ] || continue
    case "$op" in
      rename)
        gh api -X PATCH "repos/$(repo_slug)/milestones/$a" -f title="$ROLL_VERSION" >/dev/null \
          || { echo "ERROR: could not rename milestone #$a to '$ROLL_VERSION'" >&2; return 1; } ;;
      create)
        create_milestone_strict "$a" || {
          echo "ERROR: the rolling title '$a' is now free but could not be recreated — /roadmap" >&2
          echo "       will hard-stop until it exists. Re-run this command to resume." >&2
          return 1; } ;;
      move)
        # RE-READ this issue at the moment of the move. The plan was built from ONE snapshot, and a
        # milestone with many leftovers can take a while to drain — long enough for an issue to gain
        # the blocker label, or a closed blocker to be reopened. The guarantee "not even --force
        # demotes an open must-have" has to hold at mutation time, not just at planning time
        # (base/practices/verify-before-asserting.md), so a stale plan must never carry one through.
        mv_labels="$(gh api "repos/$(repo_slug)/issues/$a" --jq '[.labels[].name] | join(",")' 2>/dev/null)" \
          || { echo "ERROR: could not re-verify issue #$a before moving it — refusing (re-run to resume)" >&2; return 1; }
        if printf '%s' "$mv_labels" | tr ',' '\n' | grep -Fqx "$BLOCKER_LABEL"; then
          echo "ERROR: issue #$a gained the '$BLOCKER_LABEL' label since the plan was built —" >&2
          echo "       refusing to demote a must-have to '$b'. Nothing further was changed;" >&2
          echo "       resolve it and re-run (--resume if the archive is already renamed)." >&2
          return 1
        fi
        gh issue edit "$a" --milestone "$b" >/dev/null \
          || { echo "ERROR: could not move issue #$a to '$b' — re-run to resume" >&2; return 1; } ;;
      close)
        # FINAL check before the archive is sealed: re-tabulate and refuse if any must-have is open
        # in it now. Closing a milestone that still contains an open blocker is the outcome this
        # command promises can never happen.
        final="$(milestone_issues_json "$a" | bash "$lib" release-counts "$BLOCKER_LABEL" "$ROADMAP_NUM")" \
          || { echo "ERROR: could not re-verify milestone #$a before closing — refusing (re-run to resume)" >&2; return 1; }
        final_blockers="$(printf '%s\n' "$final" | sed -n '3p')"
        if [ -n "$final_blockers" ]; then
          echo "ERROR: milestone #$a now holds open '$BLOCKER_LABEL' issue(s):$final_blockers" >&2
          echo "       refusing to close an archive containing an open must-have. The leftovers were" >&2
          echo "       already moved; resolve these and re-run with --resume to finish." >&2
          return 1
        fi
        gh api -X PATCH "repos/$(repo_slug)/milestones/$a" -f state=closed >/dev/null \
          || { echo "ERROR: could not close milestone #$a — re-run to resume" >&2; return 1; } ;;
    esac
  done <<EOF
$ROLL_PLAN
EOF

  # One audit line per owner-visible mutation (base/practices/logging-and-secrets.md).
  if [ "$repair_only" -eq 1 ]; then
    adb_info ""
    adb_info "repaired: '$rolling' recreated in $(repo_slug); milestone #$cut_num ('$ROLL_VERSION') is"
    adb_info "          still OPEN and NOT rolled — /roadmap works again, but the roll is unfinished."
    if [ -n "$blockers" ]; then
      adb_info "Next: resolve the open '$BLOCKER_LABEL' issue(s) above, then re-run with --resume to"
      adb_info "      finish (move the leftovers to '$BACKLOG_MILESTONE' and close the archive)."
    else
      adb_info "Next: confirm #$cut_num really is this roll's archive, then re-run with --resume to"
      adb_info "      finish (move the leftovers to '$BACKLOG_MILESTONE' and close the archive)."
    fi
    return 1
  fi
  local moved_count; moved_count="$(printf '%s' "$movers" | wc -w | tr -d ' ')"
  adb_info ""
  adb_info "rolled: '$rolling' -> '$ROLL_VERSION' (milestone #$cut_num, closed); fresh '$rolling' open;" \
           "$moved_count issue(s) moved to '$BACKLOG_MILESTONE' in $(repo_slug)"
  adb_info ""
  adb_info "The roadmap artifact's <!-- release-milestone: $rolling --> marker is unchanged and still"
  adb_info "correct — the rolling TITLE was recreated, so the marker never needed editing."
  adb_info "Next: slate the next release's issues into '$rolling' and label the must-haves"
  adb_info "'$BLOCKER_LABEL'. Until then /roadmap reports 'no requirements yet' (unarmed)."
}

# --- arg parsing + dispatch --------------------------------------------------------------
# Parsing is PER-SUBCOMMAND: a shared parser would make `status --version v1` and `init --dry-run`
# silently valid, loosening a contract the checks pin. --release-name is shared (init names the
# milestone it creates; roll overrides the marker-resolved title); everything else is roll-only.
parse_release_name() {   # <value> — validate + assign; used by every subcommand that takes it
  # Reject an empty/whitespace-only title up front — GitHub would 422 the create, and an
  # empty milestone name can never resolve a live `release-milestone` marker.
  printf '%s' "$1" | grep -q '[^[:space:]]' || { echo "ERROR: --release-name must not be empty" >&2; exit 2; }
  RELEASE_MILESTONE="$1"; RELEASE_NAME_SET=1
}

parse_opts() {   # init / status: --release-name and --help only
  while [ "$#" -ge 1 ]; do
    case "$1" in
      --release-name)
        shift; [ "$#" -ge 1 ] || { echo "ERROR: --release-name needs a value" >&2; exit 2; }
        parse_release_name "$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "release-convention: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
}

parse_roll_opts() {
  while [ "$#" -ge 1 ]; do
    case "$1" in
      --version)
        shift; [ "$#" -ge 1 ] || { echo "ERROR: --version needs a value" >&2; exit 2; }
        printf '%s' "$1" | grep -q '[^[:space:]]' || { echo "ERROR: --version must not be empty" >&2; exit 2; }
        ROLL_VERSION="$1"; shift ;;
      --release-name)
        shift; [ "$#" -ge 1 ] || { echo "ERROR: --release-name needs a value" >&2; exit 2; }
        parse_release_name "$1"; shift ;;
      --backlog-name)
        # The disposition target is as unpersisted as the release title, so a repo that renamed
        # its backlog needs a way to name it. (Carrying all of the convention's names on one
        # resolvable surface is the deeper fix — tracked separately.)
        shift; [ "$#" -ge 1 ] || { echo "ERROR: --backlog-name needs a value" >&2; exit 2; }
        printf '%s' "$1" | grep -q '[^[:space:]]' || { echo "ERROR: --backlog-name must not be empty" >&2; exit 2; }
        BACKLOG_MILESTONE="$1"; shift ;;
      --dry-run) ROLL_DRY_RUN=1; shift ;;
      --force)   ROLL_FORCE=1; shift ;;
      --resume)  ROLL_RESUME=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "release-convention: unknown option '$1'" >&2; exit 2 ;;
    esac
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  init)   parse_opts "$@"; cmd_init ;;
  status) parse_opts "$@"; cmd_status ;;
  roll)   parse_roll_opts "$@"; cmd_roll ;;
  -h|--help) usage; exit 0 ;;
  *) echo "release-convention: unknown subcommand '$SUB' (expected 'init', 'status', or 'roll')" >&2; usage >&2; exit 2 ;;
esac
