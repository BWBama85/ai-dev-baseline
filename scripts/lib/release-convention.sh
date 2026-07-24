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

# ensure_milestone <title> — create it if absent. GitHub has no upsert. Check OPEN first (so an
# open milestone is never misreported as closed when a same-title closed one is listed ahead of
# it), then a closed same-title one, else POST. Treat an HTTP 422 (duplicate title) as success,
# hard-fail anything else.
ensure_milestone() {
  local title="$1"
  if [ -n "$(milestone_field "$title" open number)" ]; then
    adb_info "  ok       milestone '$title' (already open)"; return 0
  fi
  if [ "$(milestone_field "$title" all state)" = "closed" ]; then
    adb_info "  note     milestone '$title' exists but is CLOSED — reopen it to use it"; return 0
  fi
  local out rc
  out="$(gh api -X POST "repos/$(repo_slug)/milestones" -f title="$title" -f state=open 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    adb_info "  created  milestone '$title'"
  elif printf '%s' "$out" | grep -q 'HTTP 422'; then
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
