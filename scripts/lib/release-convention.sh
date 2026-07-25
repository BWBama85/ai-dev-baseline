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
#   release-convention.sh roll --version VERSION [--dry-run] [--force] [--release-name NAME]
#                                         # roll the milestone AFTER a release is cut (#74)
#   release-convention.sh -h | --help
#
# `roll` is the rollover half of the convention: once your project-owned release action has cut
# the release, `roll` archives the release milestone under the version, opens a fresh empty one
# under the rolling title, and sends the leftover non-blocker issues to Backlog. It is milestone
# BOOKKEEPING ONLY — it never bumps a version, writes a changelog, tags, packages, publishes, or
# deploys. Those stay project-owned (#3), and this file must never grow them.
#
# Requires: gh (authenticated for this repo's remote).

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way the sibling scripts/lib modules
# do (skill-compose.sh, project-gates.sh) — not bin/baseline's PATH-symlink walk, which is inert
# here. adb_usage / adb_info vanish without it, so a missing library FAILS LOUD.
_adb_rc_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
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
  command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)" >&2; exit 1; }
  REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; exit 1; }
  [ -n "$REPO_SLUG" ] || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; exit 1; }
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

# label_exists <name> -> 0 if the label exists in the repo, 1 otherwise (exact match).
label_exists() {
  gh label list --limit 500 --json name --jq '.[].name' 2>/dev/null | grep -qx "$1"
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
  nums="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number' 2>/dev/null)"
  count="$(printf '%s\n' "$nums" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" = "1" ]; then
    num="$(printf '%s\n' "$nums" | sed '/^$/d' | head -n1)"
    adb_info "  marker   activate /roadmap release-readiness by adding this line to roadmap issue #$num:"
  elif [ "$count" = "0" ]; then
    adb_info "  marker   activate /roadmap release-readiness — run /roadmap once, then add to its body:"
  else
    adb_info "  marker   activate /roadmap release-readiness — add to the right roadmap issue ($count found):"
  fi
  adb_info "             <!-- release-milestone: $RELEASE_MILESTONE -->"
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
  if [ -n "$rnum" ]; then
    adb_info "Primitives present. /roadmap runs in release-readiness mode once its artifact carries"
    adb_info "the marker:  <!-- release-milestone: $RELEASE_MILESTONE -->"
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
RELEASE_NAME_SET=0   # 1 when --release-name was passed explicitly

# marker_titles — print the distinct rolling-milestone titles named by the roadmap artifact's
# `<!-- release-milestone: NAME -->` marker (usually exactly one line). Empty output = could not
# resolve, which `roll` treats as a refusal, never as "use the default".
#
# The default title is NOT an acceptable fallback here: `--release-name` is a per-invocation flag
# that `init` never persisted anywhere, so a repo that opted in with
# `baseline release init --release-name "v2.0"` has no "Next release" milestone at all — rolling
# the default would target a milestone that does not exist, or (worse, in a repo that has both)
# roll the wrong one. The artifact marker is the only authoritative record of the rolling title,
# and it is the same value /roadmap itself resolves, so roll and roadmap can never disagree.
#
# Placeholder carve-out mirrors base/workflows/roadmap.md: an empty value or the literal `NAME`
# is the schema's own example token (bootstrap can copy it verbatim), never a real milestone.
marker_titles() {
  local nums count num body
  nums="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number' 2>/dev/null)"
  count="$(printf '%s\n' "$nums" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || return 1
  num="$(printf '%s\n' "$nums" | sed '/^$/d' | head -n1)"
  body="$(gh issue view "$num" --json body --jq .body 2>/dev/null)" || return 1
  printf '%s\n' "$body" \
    | sed -n 's/.*<!--[[:space:]]*release-milestone:[[:space:]]*\(.*\)-->.*/\1/p' \
    | sed 's/[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' | grep -vx 'NAME' | sort -u
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

# milestone_rows <number> [state] — TSV of the milestone's issues: number, state, state_reason,
# comma-joined labels. ONE paginated read (`--paginate`, never a `--limit` page cap — cf. #79)
# and PRs are excluded: `repos/.../issues` returns pull requests too, and re-milestoning a PR
# would both corrupt that PR and make roll's count disagree with the readiness predicate, which
# counts issues only.
#
# `state_reason` is emitted as "-" when null, never as "". Tab is an IFS *whitespace* character, so
# `read` collapses a run of them into ONE delimiter — an empty third field would silently shift the
# label list into the state_reason variable and make every open issue look unlabelled.
milestone_rows() {
  gh api --paginate "repos/$(repo_slug)/issues?milestone=$1&state=${2:-all}&per_page=100" \
    --jq '.[] | select(has("pull_request")|not)
          | [(.number|tostring), .state, (.state_reason // "-"), ([.labels[].name]|join(","))] | @tsv' 2>/dev/null
}

# has_label <comma-joined-labels> <name> -> 0 when present (exact element match, so `release` never
# matches `release-blocker`).
has_label() {
  printf '%s' "$1" | tr ',' '\n' | grep -qx "$2"
}

# roll_counts <rows> — echo "<armed> <open_blockers> <open_issues> <canceled>", the four inputs
# roadmap-lib.sh's release-ready predicate takes. Excludes the roadmap artifact itself, exactly as
# the /roadmap predicate does (`-label:roadmap`), so the verdict computed here is the same verdict
# /roadmap computed when it emitted the cut.
roll_counts() {
  printf '%s\n' "$1" | awk -F'\t' -v blk="$BLOCKER_LABEL" '
    function haslabel(l, name,   n, i, a) { n = split(l, a, ","); for (i = 1; i <= n; i++) if (a[i] == name) return 1; return 0 }
    $1 == "" { next }
    haslabel($4, "roadmap") { next }
    { armed = 1 }
    $2 == "open"   { oi++; if (haslabel($4, blk)) ob++ }
    $2 == "closed" && $3 == "not_planned" && haslabel($4, blk) { canceled = 1 }
    END { printf "%d %d %d %d", armed + 0, ob + 0, oi + 0, canceled + 0 }
  '
}

# roll_plan_line — every planned mutation prints through here, in execution order, BEFORE it runs
# (and instead of running, under --dry-run). One stable line per operation is what makes the
# ordering assertable offline in scripts/check-release-convention.sh without a live GitHub.
roll_plan_line() { adb_info "plan: $*"; }

cmd_roll() {
  require_gh

  [ -n "$ROLL_VERSION" ] \
    || { echo "ERROR: roll needs --version (the version you just cut, e.g. --version v1.2.0)" >&2; return 2; }

  # --- 1. Resolve the rolling title (authoritative: the artifact marker) --------------------
  local rolling
  if [ "$RELEASE_NAME_SET" -eq 1 ]; then
    rolling="$RELEASE_MILESTONE"
  else
    local titles tcount
    titles="$(marker_titles)" || true
    tcount="$(printf '%s\n' "$titles" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$tcount" = "1" ]; then
      rolling="$(printf '%s\n' "$titles" | sed '/^$/d' | head -n1)"
    elif [ "$tcount" = "0" ]; then
      echo "ERROR: could not resolve the rolling milestone title from the roadmap artifact's" >&2
      echo "       <!-- release-milestone: NAME --> marker (no marker, a placeholder value, or" >&2
      echo "       not exactly one open 'roadmap'-labelled issue). Pass --release-name NAME to" >&2
      echo "       name it explicitly, or run 'baseline release init' to stand the convention up." >&2
      return 1
    else
      echo "ERROR: the roadmap artifact names $tcount different release-milestone titles:" >&2
      printf '%s\n' "$titles" | sed '/^$/d' | sed 's/^/         /' >&2
      echo "       Fix the artifact so exactly one is named, or pass --release-name NAME." >&2
      return 1
    fi
  fi

  # --- 2. Preflight reads + refusals (ALL before any mutation) -----------------------------
  printf '%s' "$ROLL_VERSION" | grep -q '[^[:space:]]' \
    || { echo "ERROR: --version must not be empty" >&2; return 2; }
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

  local cut_num ver_num ver_state backlog_num
  cut_num="$(milestone_field "$rolling" open number)"
  ver_num="$(milestone_field "$ROLL_VERSION" all number)"
  ver_state="$(milestone_field "$ROLL_VERSION" all state)"
  backlog_num="$(milestone_field "$BACKLOG_MILESTONE" open number)"

  # Backlog is the disposition target — resolve it up front so a missing one is a refusal, never
  # issues left milestone-less halfway through.
  [ -n "$backlog_num" ] \
    || { echo "ERROR: no OPEN milestone titled '$BACKLOG_MILESTONE' — run 'baseline release init' first" >&2; return 1; }

  # --- 3. Classify the state so a re-run RESUMES instead of corrupting -----------------------
  # GitHub has no transaction, so roll is designed to be re-run after an interruption at any
  # step. The four reachable states, from (rolling open?, version milestone state):
  local do_rename=1 do_create=1
  if [ -n "$cut_num" ] && [ -z "$ver_num" ]; then
    :                                   # (a) fresh roll — nothing done yet
  elif [ -z "$cut_num" ] && [ "$ver_state" = "open" ]; then
    do_rename=0; cut_num="$ver_num"     # (b) resumed after rename: archive exists, rolling freed
    adb_info "note: resuming an interrupted roll (milestone #$ver_num already renamed to '$ROLL_VERSION')"
  elif [ -n "$cut_num" ] && [ "$ver_state" = "open" ]; then
    # (c) resumed after create: both open. Distinguish a genuine resume (the fresh rolling
    # milestone is empty) from a pre-existing version-named milestone (a real collision).
    if [ -n "$(milestone_rows "$cut_num" all)" ]; then
      echo "ERROR: '$ROLL_VERSION' already exists as an OPEN milestone (#$ver_num) and '$rolling'" >&2
      echo "       (#$cut_num) is not empty — this is not an interrupted roll. Rename or close the" >&2
      echo "       existing '$ROLL_VERSION' milestone, or pick a different --version." >&2
      return 1
    fi
    do_rename=0; do_create=0; cut_num="$ver_num"
    adb_info "note: resuming an interrupted roll (archive #$ver_num renamed, '$rolling' recreated)"
  elif [ "$ver_state" = "closed" ]; then
    if [ -n "$cut_num" ]; then
      echo "ERROR: already rolled — '$ROLL_VERSION' is a closed milestone (#$ver_num) and '$rolling'" >&2
      echo "       (#$cut_num) is open. Nothing to do." >&2
      return 1
    fi
    echo "ERROR: '$ROLL_VERSION' is closed (#$ver_num) but no open '$rolling' milestone exists —" >&2
    echo "       the roll completed and the rolling milestone was removed. Run 'baseline release" >&2
    echo "       init' to recreate it." >&2
    return 1
  else
    echo "ERROR: no OPEN milestone titled '$rolling' to roll" >&2
    return 1
  fi

  # --- 4. Re-verify readiness LIVE, and fail closed ------------------------------------------
  # roll is an outward-facing mutation gated on volatile tracker state, so it re-checks that state
  # at the moment it acts rather than trusting the /roadmap run that emitted the cut
  # (base/practices/verify-before-asserting.md — automated actors are in scope too). The verdict
  # comes from the SHARED predicate in roadmap-lib.sh, never re-derived here, so roll and /roadmap
  # can never drift apart (docs/design-principles.md: source the primitive, never copy it).
  local rows counts armed ob oi canceled blk_exists verdict lib
  rows="$(milestone_rows "$cut_num" all)"
  counts="$(roll_counts "$rows")"
  armed="$(printf '%s' "$counts" | awk '{print $1}')"
  ob="$(printf '%s' "$counts" | awk '{print $2}')"
  oi="$(printf '%s' "$counts" | awk '{print $3}')"
  canceled="$(printf '%s' "$counts" | awk '{print $4}')"
  # Mode is keyed off label EXISTENCE, never a live count — closing the last blocker must not
  # silently raise the bar from "no blockers left" to "no issues left" (roadmap-lib.sh:153).
  blk_exists=0; label_exists "$BLOCKER_LABEL" && blk_exists=1

  lib="$(dirname "${BASH_SOURCE[0]:-$0}")/roadmap-lib.sh"
  if [ "$ROLL_FORCE" -eq 1 ]; then
    adb_info "note: --force — skipping the readiness re-check"
  elif [ ! -f "$lib" ]; then
    echo "ERROR: required library not found: $lib (broken/incomplete install)" >&2
    return 1
  else
    verdict="$(bash "$lib" release-ready "$blk_exists" "$armed" "$ob" "$oi" "$canceled")" \
      || { echo "ERROR: readiness predicate failed — refusing to roll" >&2; return 1; }
    if [ "$verdict" != "met" ]; then
      echo "ERROR: '$rolling' (#$cut_num) is not released — readiness verdict is '$verdict', not 'met'." >&2
      case "$verdict" in
        unarmed) echo "       The milestone holds no issues; there is nothing to archive." >&2 ;;
        unmet)   echo "       $ob open '$BLOCKER_LABEL' issue(s) / $oi open issue(s) remain." >&2 ;;
        held)    echo "       A '$BLOCKER_LABEL' was closed NOT_PLANNED — an abandoned must-have is an" >&2
                 echo "       owner decision. Reopen it, unlabel it, or drop it from the milestone." >&2 ;;
      esac
      echo "       Re-run with --force only if you are deliberately rolling an unreleased milestone." >&2
      return 1
    fi
  fi

  # --- 5. Enumerate the leftovers, refusing to silently demote a must-have -------------------
  # Disposition is BACKLOG, never "roll forward into the fresh milestone". Rolling them forward
  # would arm the new milestone (armed = >=1 issue, open OR closed) with zero open blockers, so the
  # readiness predicate returns `met` on the very next /roadmap run and re-emits a cut for a
  # release that contains nothing. Backlog leaves the fresh milestone genuinely empty -> `unarmed`
  # -> "no requirements yet", and matches the convention's frozen-set rule (new work defaults to
  # Backlog; slating into a release is always a deliberate act).
  local movers="" n labels blockers=""
  while IFS="$(printf '\t')" read -r n _st _sr labels; do
    [ -n "$n" ] || continue
    has_label "$labels" roadmap && continue          # the artifact is never a backlog item
    if has_label "$labels" "$BLOCKER_LABEL"; then
      blockers="$blockers $n"
    else
      movers="$movers $n"
    fi
  done <<EOF
$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "open"')
EOF

  # An OPEN must-have is a refusal even under --force: moving it to Backlog would silently demote
  # a release requirement, which is an owner decision, not a bookkeeping side effect.
  if [ -n "$blockers" ]; then
    echo "ERROR: open '$BLOCKER_LABEL' issue(s) in '$rolling':$blockers" >&2
    echo "       roll will not demote a must-have to '$BACKLOG_MILESTONE'. Close them, remove the" >&2
    echo "       label, or move them out of the milestone yourself, then re-run." >&2
    return 1
  fi

  # --- 6. Print the plan, in execution order ------------------------------------------------
  # ORDERING IS LOAD-BEARING. Milestone titles are unique repo-wide across states, so the archive
  # rename must FREE the rolling title before the create (create-first 422s). Between the rename
  # and the create there is exactly one API call during which zero open milestones carry the
  # rolling title and /roadmap would hard-stop; that window is unavoidable, which is why step 3
  # classifies and resumes rather than pretending it away. The close comes LAST so an interruption
  # always leaves the archive open and therefore still resumable.
  [ "$do_rename" -eq 1 ] && roll_plan_line "rename milestone #$cut_num \"$rolling\" -> \"$ROLL_VERSION\""
  [ "$do_create" -eq 1 ] && roll_plan_line "create milestone \"$rolling\""
  for n in $movers; do roll_plan_line "move issue #$n -> \"$BACKLOG_MILESTONE\""; done
  roll_plan_line "close milestone #$cut_num (\"$ROLL_VERSION\")"

  if [ "$ROLL_DRY_RUN" -eq 1 ]; then
    adb_info ""
    adb_info "dry-run: no changes made."
    return 0
  fi

  # --- 7. Execute, in that order -------------------------------------------------------------
  if [ "$do_rename" -eq 1 ]; then
    gh api -X PATCH "repos/$(repo_slug)/milestones/$cut_num" -f title="$ROLL_VERSION" >/dev/null \
      || { echo "ERROR: could not rename milestone #$cut_num to '$ROLL_VERSION'" >&2; return 1; }
  fi
  if [ "$do_create" -eq 1 ]; then
    create_milestone_strict "$rolling" || {
      echo "ERROR: the rolling title '$rolling' is now free but could not be recreated — /roadmap" >&2
      echo "       will hard-stop until it exists. Re-run this command to resume." >&2
      return 1
    }
  fi
  for n in $movers; do
    gh issue edit "$n" --milestone "$BACKLOG_MILESTONE" >/dev/null \
      || { echo "ERROR: could not move issue #$n to '$BACKLOG_MILESTONE' — re-run to resume" >&2; return 1; }
  done
  gh api -X PATCH "repos/$(repo_slug)/milestones/$cut_num" -f state=closed >/dev/null \
    || { echo "ERROR: could not close milestone #$cut_num — re-run to resume" >&2; return 1; }

  # One audit line per owner-visible mutation (base/practices/logging-and-secrets.md).
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
      --dry-run) ROLL_DRY_RUN=1; shift ;;
      --force)   ROLL_FORCE=1; shift ;;
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
