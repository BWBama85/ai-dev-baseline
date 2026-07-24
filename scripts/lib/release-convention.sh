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
# from your gh remote, not the install-source clone) with one command, idempotently — it
# creates only what is absent and never deletes or renames anything.
#
# It lives in scripts/lib/ and so installs transitively into every ~/.<agent>/scripts/lib
# (the whole dir is symlinked, like skill-compose.sh); `baseline release …` dispatches here.
#
# Usage:
#   release-convention.sh init            # create the milestones + labels; seed the marker
#   release-convention.sh init --release-name NAME   # use a custom release-milestone name
#   release-convention.sh status          # report which pieces are present (no changes)
#   release-convention.sh -h | --help
#
# Requires: gh (authenticated for this repo's remote).

set -uo pipefail

# Resolve our own location through symlinks, then find scripts/lib to source common.sh.
self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in
    /*) self="$link" ;;
    *)  self="$(dirname "$self")/$link" ;;
  esac
done
LIBDIR="$(cd "$(dirname "$self")" && pwd)"
# Shared shell primitives (adb_usage / adb_info) — the ONE home, sourced not copied.
# shellcheck source=/dev/null
. "$LIBDIR/common.sh"

usage() { adb_usage "$0"; }

# Defaults — the convention's canonical names. --release-name overrides the milestone only.
RELEASE_MILESTONE="Next release"
BACKLOG_MILESTONE="Backlog"
BLOCKER_LABEL="release-blocker"
POSTDEPLOY_LABEL="post-deploy"

# --- gh helpers --------------------------------------------------------------------------
# Fail loud on a missing/unauthenticated gh or a repo with no resolvable remote (a hard stop,
# like the roadmap skill) — never a silent no-op.
require_gh() {
  command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)" >&2; exit 1; }
  gh repo view --json nameWithOwner >/dev/null 2>&1 \
    || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; exit 1; }
}

REPO_SLUG=""
repo_slug() {
  [ -n "$REPO_SLUG" ] || REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  printf '%s' "$REPO_SLUG"
}

# milestone_state <title> -> prints "open" | "closed" | "" for a milestone with that EXACT
# title, checking ALL states (so a closed same-name milestone is not silently duplicated).
milestone_state() {
  local title="$1"
  gh api --paginate "repos/$(repo_slug)/milestones?state=all&per_page=100" \
    --jq ".[] | select(.title == \"$title\") | .state" 2>/dev/null | head -n1
}

# open_milestone_number <title> -> the number of an OPEN milestone with that exact title.
open_milestone_number() {
  local title="$1"
  gh api --paginate "repos/$(repo_slug)/milestones?state=open&per_page=100" \
    --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null | head -n1
}

# ensure_milestone <title> — create it if absent. GitHub has no upsert: GET all states, POST
# only a missing title, treat 422 (duplicate) as success, hard-fail anything else.
ensure_milestone() {
  local title="$1" st
  st="$(milestone_state "$title")"
  case "$st" in
    open)   adb_info "  ok       milestone '$title' (already open)"; return 0 ;;
    closed) adb_info "  note     milestone '$title' exists but is CLOSED — reopen it to use it"; return 0 ;;
  esac
  local out rc
  out="$(gh api -X POST "repos/$(repo_slug)/milestones" -f title="$title" -f state=open 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    adb_info "  created  milestone '$title'"
  elif printf '%s' "$out" | grep -q '422'; then
    adb_info "  ok       milestone '$title' (already exists)"
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

# seed_marker — if exactly one open roadmap-labelled issue exists and it lacks the
# release-milestone marker, insert it after the artifact's first line. Explicit owner opt-in
# (distinct from /roadmap bootstrap, which never writes it). Reports what it did; never a
# hard failure (the marker can always be added by hand).
seed_marker() {
  local nums count num body
  nums="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number' 2>/dev/null)"
  count="$(printf '%s\n' "$nums" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" = "0" ]; then
    adb_info "  marker   no roadmap artifact yet — run /roadmap once, then add to its body:"
    adb_info "             <!-- release-milestone: $RELEASE_MILESTONE -->"
    return 0
  fi
  if [ "$count" != "1" ]; then
    adb_info "  marker   $count roadmap-labelled issues found (ambiguous) — add by hand to the right one:"
    adb_info "             <!-- release-milestone: $RELEASE_MILESTONE -->"
    return 0
  fi
  num="$(printf '%s\n' "$nums" | sed '/^$/d' | head -n1)"
  body="$(gh issue view "$num" --json body --jq .body 2>/dev/null)"
  if printf '%s' "$body" | grep -q 'release-milestone:'; then
    adb_info "  ok       marker already present on roadmap issue #$num"
    return 0
  fi
  local tmp
  tmp="$(mktemp -t roadmap-marker.XXXXXX)"
  printf '%s\n' "$body" | awk -v m="<!-- release-milestone: $RELEASE_MILESTONE -->" \
    'NR==1{print; print m; next} {print}' > "$tmp"
  if gh issue edit "$num" --body-file "$tmp" >/dev/null 2>&1; then
    adb_info "  seeded   release-milestone marker into roadmap issue #$num"
  else
    adb_info "  marker   could not edit roadmap issue #$num — add by hand:"
    adb_info "             <!-- release-milestone: $RELEASE_MILESTONE -->"
  fi
  rm -f "$tmp"
}

cmd_init() {
  require_gh
  adb_info "Setting up the release-goal convention in $(repo_slug):"
  local rc=0
  ensure_milestone "$RELEASE_MILESTONE" || rc=1
  ensure_milestone "$BACKLOG_MILESTONE" || rc=1
  ensure_label "$BLOCKER_LABEL"    "b60205" "Must-ship for the active release milestone (/roadmap readiness gate)" || rc=1
  ensure_label "$POSTDEPLOY_LABEL" "5319e7" "Can only happen after a release ships" || rc=1
  seed_marker
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
  rnum="$(open_milestone_number "$RELEASE_MILESTONE")"
  bnum="$(open_milestone_number "$BACKLOG_MILESTONE")"
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

# --- arg parsing + dispatch --------------------------------------------------------------
# Parse a shared option (--release-name) for either subcommand, then dispatch.
parse_opts() {
  while [ "$#" -ge 1 ]; do
    case "$1" in
      --release-name) shift; [ "$#" -ge 1 ] || { echo "ERROR: --release-name needs a value" >&2; exit 2; }; RELEASE_MILESTONE="$1"; shift ;;
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
  -h|--help) usage; exit 0 ;;
  *) echo "release-convention: unknown subcommand '$SUB' (expected 'init' or 'status')" >&2; usage >&2; exit 2 ;;
esac
