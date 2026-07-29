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
# gate; there is no active marker; the marker is malformed; the marker belongs to
# ANOTHER session sharing this checkout (#180); the marker's branch isn't the
# checked-out branch; the marker vanished or was replaced while this hook was
# running (#180); a matching blocked file exists; the run's PR is
# confirmed LIVE (this run's PR, still OPEN or MERGED — a stored prUrl is re-verified
# with gh, never trusted on its own, #44); or there are uncommitted changes (defer to
# precommit-gate so the two hooks never stack contradictory messages).
#
# OWNERSHIP (#180). A checkout is a working-tree property, not a session property: every
# session in one clone sees the same `git branch --show-current`, so matching a marker on
# branch name alone made EVERY session match the SAME marker. That is not hypothetical —
# a tracker-only session that had never run /implement-issue was told to `gh pr create`
# on another session's branch that already had an open PR. The marker therefore carries
# an `owner` (the writing session's id) and this gate compares it against its own session
# before reading the marker as its own. A marker that is not ours is left strictly alone:
# not acted on, not deleted, and never overwritten with a blocked file.
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

# Identify the session this hook is firing for (#180). Claude Code publishes the session id two
# ways — as CLAUDE_CODE_SESSION_ID in every subprocess it spawns, and as `.session_id` in the JSON
# payload it pipes to a hook's stdin (the same value that names the transcript). Prefer the ENV
# var: it is free, and unlike the payload it does not consume stdin. The payload is the fallback
# for a host that supplies only that, and the read is BOUNDED — a pipe that is open but never
# closed would otherwise burn this hook's whole 30s budget, and a hook killed by its timeout
# enforces nothing. `[ -t 0 ]` alone does not cover that case, which is why the bound is here too.
#
# Prints the id, or NOTHING when this host offers neither. Empty is a real answer meaning "I
# cannot identify myself" — never a mismatch. See marker_is_mine.
this_session() {
  local payload=""
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID"
    return 0
  fi
  [ -t 0 ] && return 0
  # `-d ''` reads to EOF (the payload carries no NUL); the non-zero status on EOF/timeout is
  # expected and the variable still holds whatever arrived.
  IFS= read -r -d '' -t 5 payload || true
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null || true
}

# Is a marker's owner this session? Usage: marker_is_mine <marker-owner> <this-session>
#
# Returns 1 ONLY when BOTH ids are known and they differ — the one case that proves the marker
# belongs to a sibling session in this same checkout. Every other combination returns 0 (act on
# it), and that direction is deliberate:
#
#   - The marker carries no owner. Either it predates #180 or the driving agent's harness exposes
#     no session id. Fall back to the branch-name behavior this gate has always had.
#   - This host cannot identify its own session. Same fallback, same reason.
#
# Failing toward ENFORCEMENT rather than toward inert is the whole point: a false "mine" costs one
# misdirected hint, while a false "not mine" silently switches the no-stop-until-PR invariant off
# for a run that still needs it. Note there is deliberately no pid fallback — the marker's writer
# (a tool-call shell) and this hook cannot derive the same pid, so a pid would manufacture
# mismatches rather than resolve them.
marker_is_mine() {
  local owner="$1" me="$2"
  [ -n "$owner" ] || return 0
  [ -n "$me" ] || return 0
  [ "$owner" = "$me" ]
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
  # Pre-initialised for the same reason as the marker parse below: `$(…)` strips trailing
  # newlines, so a payload whose LAST field is empty would leave a name unset and `set -u` would
  # abort the hook instead of reporting `unverified`.
  state=""; merged=""; head=""; pr_url=""
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

# Read the marker ONCE, into a snapshot (#180). Four separate `jq … "$marker"` reads meant a
# concurrent delete could hand back a mix of populated and empty fields — a half-read marker that
# still looked well-formed enough to nag about. One read makes the parse atomic with respect to
# the file, and keeping the raw bytes gives every later step something to re-verify against.
# An absent or empty read is SILENCE, never a nag: the file vanishing between `-f` and here means
# the owning run just finished, which is the opposite of a run that needs pushing along.
marker_snap="$(cat "$marker" 2>/dev/null || true)"
[ -n "$marker_snap" ] || exit 0

if ! printf '%s' "$marker_snap" | jq -e . >/dev/null 2>&1; then
  printf 'implement-issue-gate: %s is not valid JSON — passing; delete it if stale\n' "$marker" >&2
  exit 0
fi

# One jq pass emits the five fields, one per line (an empty field stays an empty line, so an
# absent owner or prUrl cannot shift the others).
#
# Pre-initialised because `$(…)` strips TRAILING newlines: with an empty prUrl and owner the
# substitution yields three lines, the last two `read`s hit EOF, and under `set -u` the first
# reference to an unset var would abort the hook — i.e. an ordinary ownerless marker would crash
# the gate rather than enforce it. Seeding the names makes a short read mean "empty", which is
# exactly what jq emitted, and keeps the block safe against a future field reorder.
marker_branch=""; marker_issue=""; marker_phase="unknown"; marker_pr_url=""; marker_owner=""
{ read -r marker_branch; read -r marker_issue; read -r marker_phase; read -r marker_pr_url; read -r marker_owner; } <<EOF
$(printf '%s' "$marker_snap" | jq -r '.branch // "", .issue // "", (.phase // "unknown"), .prUrl // "", .owner // ""')
EOF

# The marker as it stands RIGHT NOW, versus what we parsed. Everything below acts on a read that
# is already seconds old — old enough for two `gh` round-trips, and therefore old enough for the
# owning session to open its PR, clear the marker, and for a NEXT run to write a different one in
# its place. Re-ask before every irreversible act (emitting a hint, deleting the file) so the gate
# can never speak for, or delete, a marker that is no longer the one it read.
marker_unchanged() {
  local now
  now="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$now" ] && [ "$now" = "$marker_snap" ]
}

# Whose marker is this? Resolved only now, so a turn with no marker at all never touches stdin.
this_sid="$(this_session)"
if ! marker_is_mine "$marker_owner" "$this_sid"; then
  exit 0
fi

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

# Unrelated turn — leave the marker so the original run can resume on its branch.
if [ -n "$marker_branch" ] && [ "$marker_branch" != "$current_branch" ]; then
  exit 0
fi

# From here on the marker is ours AND its branch is the checked-out one, so the two names are
# interchangeable. Use the marker's own branch for the live lookups anyway: it is the RUN's
# branch, which is what the PR question is actually about, and it keeps the lookups correct if
# the guard above is ever relaxed.
run_branch="${marker_branch:-$current_branch}"

# Legitimate stop — but only if the blocked file references THIS run (a stale
# blocked file from an aborted prior run must not grant a free pass).
#
# Owner-aware too (#180): the blocked escape was keyed to branch/issue alone, so in a shared
# checkout ONE session's give-up handed EVERY session a free pass — one agent's "I'm stuck"
# silently switched off another agent's healthy run. Owners are compared only when BOTH files
# carry one. A mixed-vintage pair (one written before this field existed, one after) falls back
# to branch/issue rather than being rejected, because the failure directions are not symmetric:
# a wrongly-refused escape is an UNSTOPPABLE turn, while a wrongly-granted one merely ends a turn
# early. An escape hatch has to degrade permissive.
#
# Read once, for the same reason the marker is: the file can be replaced between the validity
# check and the field reads.
if [ -f "$blocked" ]; then
  blocked_legit="no"
  blocked_why="branch/issue does not match marker"
  blocked_snap="$(cat "$blocked" 2>/dev/null || true)"
  if [ -n "$blocked_snap" ] && printf '%s' "$blocked_snap" | jq -e . >/dev/null 2>&1; then
    blocked_branch=""; blocked_issue=""; blocked_owner=""
    { read -r blocked_branch; read -r blocked_issue; read -r blocked_owner; } <<EOF
$(printf '%s' "$blocked_snap" | jq -r '.branch // "", .issue // "", .owner // ""')
EOF
    if { [ -n "$blocked_branch" ] && [ "$blocked_branch" = "$marker_branch" ]; } \
       || { [ -n "$blocked_issue" ] && [ "$blocked_issue" = "$marker_issue" ]; }; then
      blocked_legit="yes"
    fi
    # Both owners known and different → this escape belongs to another session's run.
    if [ -n "$blocked_owner" ] && [ -n "$marker_owner" ] && [ "$blocked_owner" != "$marker_owner" ]; then
      blocked_legit="no"
      blocked_why="written by another session"
    fi
  fi
  if [ "$blocked_legit" = "yes" ]; then exit 0; fi
  printf 'implement-issue-gate: ignoring stale %s (%s)\n' "$blocked" "$blocked_why" >&2
fi

# A recorded prUrl (or phase=complete) means the run BELIEVES a PR was opened — but that is
# STORED, mutable state. Re-verify it live before letting the turn stop (#44): only a stored
# PR that is this run's AND still OPEN or MERGED passes here. A CLOSED-unmerged or unverifiable
# stored PR does NOT pass — control falls through to the live branch lookup (which also catches
# a replacement PR opened for the same branch after the stored one was closed), then to the
# keep-going hint. `stored_pr` records what we observed so the hint can name it. phase=complete
# is NO LONGER trusted on its own: it must be backed by a live-verified PR, or the run keeps
# going (a "complete" marker over a closed-without-merge PR is exactly the #44 failure).
#
# The satisfied path CLEARS the marker, so it re-verifies the snapshot first (#180): the `gh`
# round-trip above is long enough for this run to finish and the NEXT run to write its own marker
# here, and deleting that one would silently disarm a run that never even started when we read.
# A changed marker is somebody else's business — leave it and stop quietly.
stored_pr="none"
if [ -n "$marker_pr_url" ]; then
  case "$(pr_stored_state "$run_branch" "$marker_pr_url")" in
    satisfied) marker_unchanged && { rm -f "$marker" 2>/dev/null || true; }; exit 0 ;;
    closed)    stored_pr="closed" ;;
    *)         stored_pr="unverified" ;;
  esac
fi

# Live branch lookup: is there an OPEN PR for this branch right now? Catches the normal case
# (a PR was opened but the marker's prUrl isn't written yet) AND a replacement PR opened after
# the stored one was closed. Authoritative source, queried at the moment of use. Only OPEN is
# accepted here (a merged PR for a reused branch name must not falsely satisfy — the stored-URL
# path above already credits a legitimately merged PR for THIS run).
#
# `live_pr` records whether this lookup actually RAN, which the hint below needs. Absent `gh`, or
# a lookup that errored, is "I could not check" — not "there is no PR". Reporting the second from
# the first is precisely the unsourced status claim verify-before-asserting.md forbids, and it is
# how a session gets told to open a PR that already exists.
live_pr="none"
if command -v gh >/dev/null 2>&1; then
  gh_err="$(mktemp .claude/state/gh-err.XXXXXX 2>/dev/null || echo ".claude/state/gh-err.$$")"
  # Filter to SAME-REPO PRs (isCrossRepository==false): --head matches by branch NAME only, so
  # in a fork-accepting repo an unrelated fork PR with the same branch name would otherwise be
  # taken as this run's replacement PR and wrongly satisfy the invariant. This mirrors the
  # this-repo check the stored-URL path enforces.
  pr_url="$(gh pr list --head "$run_branch" --state open --json url,isCrossRepository --jq '[.[] | select(.isCrossRepository==false)][0].url // ""' 2>"$gh_err" || true)"
  if [ -n "$pr_url" ]; then
    rm -f "$gh_err" 2>/dev/null || true
    marker_unchanged && { rm -f "$marker" 2>/dev/null || true; }
    exit 0
  fi
  if [ -s "$gh_err" ]; then
    printf 'implement-issue-gate: gh branch lookup failed: %s\n' "$(head -c 500 "$gh_err")" >&2
    live_pr="unchecked"
  fi
  rm -f "$gh_err" 2>/dev/null || true
else
  printf 'implement-issue-gate: gh not on PATH — cannot confirm whether a PR exists for %s\n' "$run_branch" >&2
  live_pr="unchecked"
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

# LAST look before speaking (#180). Everything above is derived from a marker read before two `gh`
# round-trips; in a shared checkout the owning session can have opened its PR and cleared the
# marker in that window, and a hint built from those stale fields is exactly the instruction that
# sent a session to `gh pr create` against a branch that already had an open PR. Gone or replaced
# → say NOTHING. Silence is the correct failure here: a run that needs pushing along will still
# have its marker on the next turn-end, so the only thing lost is one turn of enforcement, whereas
# a wrong instruction is acted on immediately.
if ! marker_unchanged; then
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
      if [ "$live_pr" = "unchecked" ]; then
        lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} could not be checked for an open PR (gh missing, offline, or the lookup errored) — that is NOT proof no PR exists, so do not stop on it. Confirm with 'gh pr list --head ${marker_branch}' before deciding, and open the PR if there really isn't one."
      else
        lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} has not opened a PR yet — keep going, don't stop here."
      fi ;;
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
