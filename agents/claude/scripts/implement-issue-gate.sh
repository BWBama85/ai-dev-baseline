#!/usr/bin/env bash
# ai-dev-baseline — Stop-hook workflow-completion gate for implement-issue runs.
#
# Keeps the turn going when an implement-issue run is in progress AND its PR has
# not been opened yet AND the run has not declared itself blocked. This is the
# hard backstop for the "no-stop-until-PR" invariant; soft guardrails (skill
# prose, memory) have proven insufficient alone.
#
# Delivery of the "keep going" cue (a SOFT signal, not a failure):
#   - Claude Code >= 2.1.163: hookSpecificOutput.additionalContext on stdout +
#     exit 0 — the turn continues with plain feedback, no red hook-error block.
#   - Older builds: legacy stderr + exit 2 (still blocks, renders as an error).
#   The running version is read from CLAUDE_CODE_EXECPATH (the exact binary), NOT
#   `claude --version` (which reports the newest INSTALLED build).
#
# No-op (exit 0) when: not in a git repo; the repo ships its own copy of this
# gate; there is no active marker; the marker is malformed; the marker's branch
# isn't the checked-out branch; a matching blocked file exists; the run's PR is
# confirmed LIVE (this run's PR, still OPEN or MERGED — a stored prUrl is re-verified
# with gh, never trusted on its own, #44); or there are uncommitted changes (defer to
# precommit-gate so the two hooks never stack contradictory messages).
#
# State files (written by the implement-issue skill), both gitignored:
#   .claude/state/implement-issue-active.json    — in-flight run marker
#   .claude/state/implement-issue-blocked.json   — legitimate-stop escape hatch

set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Defer to a project-local copy of this gate if one exists and isn't this file.
proj_gate="$repo_root/.claude/scripts/implement-issue-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  exit 0
fi

# Shared shell primitives live in the sibling lib/ (installed as ~/.claude/scripts/lib).
# Sourced when present; absent (incomplete install) → the version check below falls back
# to the legacy exit-2 path, so the gate still FUNCTIONS (it blocks harder, never silently
# passes — so this is enforcement-preserving, not fail-silent). But an incomplete install
# is still worth surfacing (#35: a Stop hook that can't load its dependency must not be
# silent about it), so we note it loudly rather than swallowing it.
_adb_lib="$(dirname "$0")/lib/common.sh"
if [ -f "$_adb_lib" ]; then
  # shellcheck source=/dev/null
  . "$_adb_lib"
else
  printf 'implement-issue-gate: shared library missing (%s) — incomplete install; using the legacy block path. Re-run install.sh or `baseline update`.\n' "$_adb_lib" >&2
fi

# True when the RUNNING Claude Code honors additionalContext on Stop (>= 2.1.163).
stop_hook_additional_context_supported() {
  local execpath="${CLAUDE_CODE_EXECPATH:-}"
  [ -n "$execpath" ] || return 1
  local -a parts
  IFS='/' read -r -a parts <<< "$execpath"
  local ver="" prev="" seg
  for seg in "${parts[@]}"; do
    if [ "$prev" = "versions" ]; then ver="$seg"; break; fi
    prev="$seg"
  done
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) return 1 ;;
  esac
  # Shared semver compare; if common.sh wasn't loaded, treat as unsupported (legacy path).
  command -v adb_version_ge >/dev/null 2>&1 || return 1
  adb_version_ge "$ver" "2.1.163"
}

# Verify a STORED PR reference against LIVE GitHub state (verify-before-asserting.md, #44):
# a recorded prUrl proves a PR was OPENED, not that it still stands. Echoes exactly one word:
#   satisfied  — the stored PR is this run's PR (this repo + this branch) AND is OPEN or MERGED
#   closed     — the stored PR is this run's PR but CLOSED without merging (invariant NOT met)
#   unverified — cannot prove it: no gh, gh/network error, PR not found, or it isn't this run's
#                PR (another repo's same-numbered PR, or a stale URL from a different branch)
# Fail-CLOSED by contract: the caller MUST NOT treat `unverified` as satisfied — doing so
# would re-introduce the exact stale-state trust #44 removes. Args: <current-branch> <pr-url>.
pr_stored_state() {
  local branch="$1" url="$2" repo_url pr_json state merged head pr_url err
  [ -n "$url" ] || { printf 'unverified\n'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'unverified\n'; return 0; }
  err="$(mktemp .claude/state/gh-err.XXXXXX 2>/dev/null || echo ".claude/state/gh-err.$$")"
  # A full PR URL targets its OWN repo (GitHub.com or Enterprise), so `gh pr view "$url"`
  # reads that PR regardless of CWD. Require it to belong to THIS repo AND this run's branch
  # before trusting its state — otherwise a same-numbered PR elsewhere, or a stale URL from a
  # different branch, could falsely satisfy the invariant.
  repo_url="$(gh repo view --json url --jq '.url' 2>"$err" || true)"
  pr_json="$(gh pr view "$url" --json state,mergedAt,url,headRefName 2>>"$err" || true)"
  if [ -z "$repo_url" ] || [ -z "$pr_json" ]; then
    [ -s "$err" ] && printf 'implement-issue-gate: gh PR-state check failed: %s\n' "$(head -c 300 "$err")" >&2
    rm -f "$err"; printf 'unverified\n'; return 0
  fi
  rm -f "$err"
  # One jq pass emits the four fields, one per line (an empty field stays an empty line, so an
  # absent mergedAt can't shift the others) — 1 jq spawn instead of 4 on every gated turn-end.
  { read -r state; read -r merged; read -r head; read -r pr_url; } <<EOF
$(printf '%s' "$pr_json" | jq -r '.state // "", .mergedAt // "", .headRefName // "", .url // ""')
EOF
  case "$pr_url" in
    "$repo_url"/pull/*) : ;;                            # belongs to this repo
    *) printf 'unverified\n'; return 0 ;;               # different repo → not this run's PR
  esac
  [ "$head" = "$branch" ] || { printf 'unverified\n'; return 0; }   # different branch
  if [ "$state" = "OPEN" ] || [ -n "$merged" ]; then printf 'satisfied\n'; return 0; fi
  if [ "$state" = "CLOSED" ]; then printf 'closed\n'; return 0; fi
  printf 'unverified\n'
}

marker=".claude/state/implement-issue-active.json"
blocked=".claude/state/implement-issue-blocked.json"

[ -f "$marker" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  printf 'implement-issue-gate: jq not on PATH; cannot parse %s — passing\n' "$marker" >&2
  exit 0
fi
if ! jq -e . "$marker" >/dev/null 2>&1; then
  printf 'implement-issue-gate: %s is not valid JSON — passing; delete it if stale\n' "$marker" >&2
  exit 0
fi

marker_branch="$(jq -r '.branch // ""' "$marker")"
marker_issue="$(jq -r '.issue // ""' "$marker")"
marker_phase="$(jq -r '.phase // "unknown"' "$marker")"
marker_pr_url="$(jq -r '.prUrl // ""' "$marker")"
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

# Unrelated turn — leave the marker so the original run can resume on its branch.
if [ -n "$marker_branch" ] && [ "$marker_branch" != "$current_branch" ]; then
  exit 0
fi

# Legitimate stop — but only if the blocked file references THIS run (a stale
# blocked file from an aborted prior run must not grant a free pass).
if [ -f "$blocked" ]; then
  blocked_legit="no"
  if jq -e . "$blocked" >/dev/null 2>&1; then
    blocked_branch="$(jq -r '.branch // ""' "$blocked")"
    blocked_issue="$(jq -r '.issue // ""' "$blocked")"
    if { [ -n "$blocked_branch" ] && [ "$blocked_branch" = "$marker_branch" ]; } \
       || { [ -n "$blocked_issue" ] && [ "$blocked_issue" = "$marker_issue" ]; }; then
      blocked_legit="yes"
    fi
  fi
  if [ "$blocked_legit" = "yes" ]; then exit 0; fi
  printf 'implement-issue-gate: ignoring stale %s (branch/issue does not match marker)\n' "$blocked" >&2
fi

# A recorded prUrl (or phase=complete) means the run BELIEVES a PR was opened — but that is
# STORED, mutable state. Re-verify it live before letting the turn stop (#44): only a stored
# PR that is this run's AND still OPEN or MERGED passes here. A CLOSED-unmerged or unverifiable
# stored PR does NOT pass — control falls through to the live branch lookup (which also catches
# a replacement PR opened for the same branch after the stored one was closed), then to the
# keep-going hint. `stored_pr` records what we observed so the hint can name it. phase=complete
# is NO LONGER trusted on its own: it must be backed by a live-verified PR, or the run keeps
# going (a "complete" marker over a closed-without-merge PR is exactly the #44 failure).
stored_pr="none"
if [ -n "$marker_pr_url" ]; then
  case "$(pr_stored_state "$current_branch" "$marker_pr_url")" in
    satisfied) rm -f "$marker" 2>/dev/null || true; exit 0 ;;
    closed)    stored_pr="closed" ;;
    *)         stored_pr="unverified" ;;
  esac
fi

# Live branch lookup: is there an OPEN PR for this branch right now? Catches the normal case
# (a PR was opened but the marker's prUrl isn't written yet) AND a replacement PR opened after
# the stored one was closed. Authoritative source, queried at the moment of use. Only OPEN is
# accepted here (a merged PR for a reused branch name must not falsely satisfy — the stored-URL
# path above already credits a legitimately merged PR for THIS run).
if command -v gh >/dev/null 2>&1; then
  gh_err="$(mktemp .claude/state/gh-err.XXXXXX 2>/dev/null || echo ".claude/state/gh-err.$$")"
  # Filter to SAME-REPO PRs (isCrossRepository==false): --head matches by branch NAME only, so
  # in a fork-accepting repo an unrelated fork PR with the same branch name would otherwise be
  # taken as this run's replacement PR and wrongly satisfy the invariant. This mirrors the
  # this-repo check the stored-URL path enforces.
  pr_url="$(gh pr list --head "$current_branch" --state open --json url,isCrossRepository --jq '[.[] | select(.isCrossRepository==false)][0].url // ""' 2>"$gh_err" || true)"
  if [ -n "$pr_url" ]; then
    rm -f "$marker" "$gh_err" 2>/dev/null || true
    exit 0
  fi
  if [ -s "$gh_err" ]; then
    printf 'implement-issue-gate: gh branch lookup failed: %s\n' "$(head -c 500 "$gh_err")" >&2
  fi
  rm -f "$gh_err" 2>/dev/null || true
fi

# Defer to precommit-gate when there are uncommitted changes AND no PR was ever recorded —
# precommit-gate has authority over red gates, and stacking two messages confuses the resume
# hint. But when a PR WAS recorded and is now closed/unverified (a #44 fail-closed signal), the
# problem is the invalid PR — which precommit-gate cannot see — so do NOT defer: fall through to
# the state-specific resume hint even on a dirty tree, or the turn could stop on a stale PR in a
# repo with no (or passing) quality gates.
if [ "$stored_pr" = "none" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  printf 'implement-issue-gate: deferring to precommit-gate (uncommitted changes)\n' >&2
  exit 0
fi

# Invariant unmet: no PR, not blocked, tree clean. Emit the resume hint. Built as
# a function (not inline command-substitution) to dodge macOS bash 3.2's heredoc
# apostrophe-parsing bug.
emit_resume_hint() {
  local lead
  case "$stored_pr" in
    closed)
      lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} recorded a PR that is now CLOSED without merging — the run is NOT complete. Reopen it or open a replacement PR; do not stop here." ;;
    unverified)
      lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} recorded a PR whose live state could not be verified (gh offline/error, PR not found, or it isn't this run's PR) — not proven complete, so do not stop here. Verify with 'gh pr view' or open a PR. Only a genuine, prolonged GitHub outage is a legitimate stop: retry, then write .claude/state/implement-issue-blocked.json." ;;
    *)
      lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} has not opened a PR yet — keep going, don't stop here." ;;
  esac
  cat <<EOF
implement-issue-gate: ${lead}

  Current phase: ${marker_phase}
  Marker:        ${marker}

Resume the playbook (phase → next step):
  - branched         → Implement (write code + tests)
  - implemented      → Run the project's gates until green
  - gates_green      → First commit
  - committed        → Review pass (self-review + configured 'review' agent)
  - code_reviewed    → Triage + fix findings
  - triaged          → Push the branch
  - pushed           → gh pr create  (write prUrl into the marker)

Legitimate stops only: write .claude/state/implement-issue-blocked.json with the
reason AND a .branch field matching '${marker_branch}' if (a) the gate escape
clause tripped, (b) the branch already exists on remote, or (c) a required review
step cannot complete after retry + fallback. (A BLOCKING gap-analysis finding is a
pre-branch stop with no active marker, so it never applies once this hook fires.)
Otherwise, keep going.
EOF
}
resume_hint="$(emit_resume_hint)"

if stop_hook_additional_context_supported; then
  jq -cn --arg ctx "$resume_hint" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  exit 0
fi

printf '\n%s\n' "$resume_hint" >&2
exit 2
