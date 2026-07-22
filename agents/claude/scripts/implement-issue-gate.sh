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
# isn't the checked-out branch; a matching blocked file exists; the PR is open
# (per marker or a live gh check); or there are uncommitted changes (defer to
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
  awk -v v="$ver" -v min="2.1.163" '
    BEGIN {
      nv = split(v, V, "."); nm = split(min, M, ".");
      n = (nv > nm) ? nv : nm;
      for (i = 1; i <= n; i++) {
        a = (i <= nv) ? V[i] + 0 : 0; b = (i <= nm) ? M[i] + 0 : 0;
        if (a > b) exit 0; if (a < b) exit 1;
      }
      exit 0;
    }'
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

# PR opened, or run explicitly complete — past the invariant threshold.
if [ -n "$marker_pr_url" ] || [ "$marker_phase" = "complete" ]; then
  rm -f "$marker" 2>/dev/null || true
  exit 0
fi

# Last guard: even if prUrl was never written, ask GitHub directly.
if command -v gh >/dev/null 2>&1; then
  gh_err="$(mktemp .claude/state/gh-err.XXXXXX 2>/dev/null || echo ".claude/state/gh-err.$$")"
  pr_url="$(gh pr list --head "$current_branch" --state open --json url --jq '.[0].url // ""' 2>"$gh_err" || true)"
  if [ -n "$pr_url" ]; then
    rm -f "$marker" "$gh_err" 2>/dev/null || true
    exit 0
  fi
  if [ -s "$gh_err" ]; then
    printf 'implement-issue-gate: gh fallback failed: %s\n' "$(head -c 500 "$gh_err")" >&2
  fi
  rm -f "$gh_err" 2>/dev/null || true
fi

# Defer to precommit-gate when there are uncommitted changes — it has authority
# over red gates, and stacking two messages confuses the resume hint.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  printf 'implement-issue-gate: deferring to precommit-gate (uncommitted changes)\n' >&2
  exit 0
fi

# Invariant unmet: no PR, not blocked, tree clean. Emit the resume hint. Built as
# a function (not inline command-substitution) to dodge macOS bash 3.2's heredoc
# apostrophe-parsing bug.
emit_resume_hint() {
  cat <<EOF
implement-issue-gate: the implement-issue run for #${marker_issue} on branch ${marker_branch} has not opened a PR yet — keep going, don't stop here.

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
reason AND a .branch field matching '${marker_branch}' if (a) a BLOCKING
gap-analysis finding you cannot resolve, (b) the gate escape clause tripped, or
(c) the branch already exists on remote. Otherwise, keep going.
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
