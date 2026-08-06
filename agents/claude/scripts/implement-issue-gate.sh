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
# bash 5.3 runtime floor (#256) — FIRST, before the cd and before ANY read of the hook payload on
# stdin: the re-exec inherits that fd and restarts this script from the top, so anything already
# consumed would be lost.
#
# The source is CONDITIONAL on purpose. This file has a deliberate broken-install posture of its
# own a few lines below, and the floor gate is not entitled to override it — if the shared library
# is missing, that decision stays with the machinery that already owns it.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh"
  adb_require_bash "$@"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# Defer to a project-local copy of this gate by RUNNING it, not by stepping aside (#240). `exit 0`
# here was enforcement silently OFF: nothing else invokes a project gate — no project-level Stop
# hook is wired by install.sh, the adapter, or bin/baseline — so a repo that shipped its own copy
# ended up with a script nothing ran AND this gate standing down. `exec` inherits stdin (the hook
# payload) and propagates the status, so a project gate can still block with 2; the `-ef` inode
# test is what stops this re-entering itself.
proj_gate="$repo_root/.claude/scripts/implement-issue-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  [ -x "$proj_gate" ] && exec "$proj_gate" "$@"
  exec bash "$proj_gate" "$@"
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
  # `-d ''` reads to EOF (the payload carries no NUL); the non-zero status on EOF is expected and
  # the variable holds what arrived. THE TIMEOUT IS THE INTERESTING CASE, and it changed under this
  # repo's 5.3 floor (#258).
  #
  # This used to rely on bash 3.2 DISCARDING whatever it had collected when `-t` fired. bash >= 4.2
  # KEEPS it, so on the floor interpreter the discard is ours to perform, not the shell's. Measured
  # on both, writing a partial object into a pipe that never closes:
  #   bash 3.2  -> status 1,   variable empty
  #   bash 5.3  -> status 142, variable holds the bytes  (128 + SIGALRM)
  # so the bound is detectable as `> 128`, which EOF (1) never is.
  #
  # Left unhandled, that is not merely a stale comment. A writer that sends a COMPLETE object and
  # then never closes the pipe would have its session id adopted here — an identity taken off a
  # stream this function could not finish reading — and the gate would fall silent for a marker it
  # should have enforced. Only jq's refusal to parse a TRUNCATED object was preventing the same
  # thing for partial writes, which is luck, not a rule. Fixture: check-implement-gate.sh U2.
  #
  # Unknown identity is the safe direction: it falls back to branch-name matching, which ENFORCES.
  # The bound's job is to keep the hook alive, not to salvage the read. jq is guaranteed — the
  # caller runs only after this script's own jq check.
  #
  # `rc` is captured on its own line rather than tested inside `if ! read …; then`, where `$?` would
  # be the status of the negation (always 0) and the discard would silently never happen.
  #
  # `> 128` IS NOT EXCLUSIVE TO THE TIMEOUT, and that is deliberate rather than overlooked (raised
  # in review). A `read` interrupted by a trapped signal also returns 128 + signum, so an intact
  # payload arriving at that instant would be discarded too. Two reasons that is the right trade:
  # this script installs no trap before `this_session` runs, so the case is presently unreachable;
  # and if it ever became reachable, discarding yields "cannot identify myself", which falls back to
  # branch matching and ENFORCES. The failure direction is toward the gate doing its job.
  local rc=0
  IFS= read -r -d '' -t 5 payload || rc=$?
  if [ "$rc" -gt 128 ]; then payload=""; fi
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null || true
}

# Do two session ids permit acting? Usage: owners_compatible <id-a> <id-b>
#
# THE RULE AND ITS RATIONALE NOW LIVE IN ONE PLACE — adb_owners_compatible in common.sh —
# because precommit-gate.sh needs the identical question answered the identical way (#241), and
# two hand-rolled three-way comparisons are exactly the drift CLAUDE.md golden rule 4 forbids.
# This is a thin alias, NOT a second implementation: `grep` for the logic finds it once.
#
# Two callers here, one rule: "is the active marker mine?" and "was this blocked file written by
# the session that owns the marker?". Both are the same question about two ids.
#
# The fallback below is the reason this wrapper exists at all. When common.sh is absent — the
# incomplete-install path this file deliberately survives (see the loader above) — the shared
# function is undefined, and calling a missing command returns 127, which `if owners_compatible
# …` would read as "NOT compatible", i.e. FOREIGN. That inverts the failure direction: every
# marker would look like someone else's and this gate would fall silent exactly when its install
# is broken. Answering "compatible" instead falls back to the branch-name behavior this gate had
# before #180, which ENFORCES.
if command -v adb_owners_compatible >/dev/null 2>&1; then
  owners_compatible() { adb_owners_compatible "$1" "$2"; }
else
  owners_compatible() { return 0; }
fi

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
  # Pre-initialised for the reason spelled out at the marker parse below (trailing-newline
  # stripping + `set -u`).
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
#
# `$(<file)` not `$(cat file)`: a builtin read costs no fork, and this runs at EVERY turn-end.
# The braces carry the redirection because bash reports a missing file itself; the result is
# empty either way, which is the case the line below wants.
{ marker_snap="$(<"$marker")"; } 2>/dev/null
[ -n "$marker_snap" ] || exit 0

# ONE jq pass validates AND extracts, and it has to do three jobs that a bare
# `.branch // "", …` list does not:
#
#   1. REJECT A NON-OBJECT. `jq -r` exits 0 on a top-level `null` (`null.branch` is `null`), on a
#      bare number and on whitespace-only input (zero values read, so the program never runs). Each
#      would yield five empty fields, and empty fields skip both the owner check and the
#      branch-match guard below — so a `null` marker used to emit a keep-going hint naming issue
#      `#` on branch `` in EVERY session and on every branch in the checkout. `jq -e .` used to
#      catch this; folding validation into the extract silently dropped it.
#   2. REJECT A NEWLINE IN A DECISION FIELD. The five values are decoded BY POSITION from
#      newline-separated output, so one embedded newline shifts every later field — and `owner` is
#      last. A `prUrl` carrying a warning line above the URL therefore made `owner` read as the URL
#      and the run's OWN marker look foreign (invariant silently off); a newline in `branch` shifted
#      `owner` off the end entirely and made a FOREIGN marker read as unowned, which is the #180
#      defect returning. Neither is hypothetical: nothing validates what the run writes there.
#   3. TOLERATE A NEWLINE IN `prUrl` SPECIFICALLY, by dropping it to empty rather than failing the
#      whole marker. `prUrl` gates no comparison — the live branch lookup below is authoritative —
#      so a malformed one costs nothing, and rejecting the marker over it would switch enforcement
#      off for a run that is otherwise perfectly readable.
#
# `s` coerces null to "" and keeps a numeric `issue` as its digits (a hand-written marker may write
# `"issue": 180` unquoted), so the coercion cannot itself become a silent field change.
_marker_jq='
  def s: if . == null then "" elif type == "string" then . else tostring end;
  if type != "object" then error("not an object") else . end
  | { b: (.branch|s), i: (.issue|s), p: (.phase|s), u: (.prUrl|s), o: (.owner|s) }
  | if ([.b, .i, .p, .o] | map(test("\n")) | any) then error("newline in a decision field") else . end
  | [ .b, .i, (if .p == "" then "unknown" else .p end),
      (if (.u | test("\n")) then "" else .u end), .o ]
  | .[]'
marker_fields="$(printf '%s' "$marker_snap" | jq -r "$_marker_jq" 2>/dev/null)" || marker_fields=""
if [ -z "$marker_fields" ]; then
  printf 'implement-issue-gate: %s is not a usable marker (malformed JSON, not an object, or a newline in branch/issue/phase/owner) — passing; delete it if stale\n' "$marker" >&2
  exit 0
fi

# Pre-initialised because `$(…)` strips TRAILING newlines: with an empty prUrl and owner the
# substitution yields three lines, the last two `read`s hit EOF, and under `set -u` the first
# reference to an unset var would abort the hook — i.e. an ordinary ownerless marker would crash
# the gate rather than enforce it. Seeding the names makes a short read mean "empty", which is
# exactly what jq emitted, and keeps the block safe against a future field reorder.
#
# `IFS=` on every read so a value is taken byte-exact: under the default IFS, `"owner": "abc "`
# would be trimmed to `abc` and compare EQUAL to session `abc`. That direction happens to favour
# enforcement, but an ownership test that quietly ignores bytes is not one worth reasoning about.
marker_branch=""; marker_issue=""; marker_phase="unknown"; marker_pr_url=""; marker_owner=""
{ IFS= read -r marker_branch; IFS= read -r marker_issue; IFS= read -r marker_phase
  IFS= read -r marker_pr_url; IFS= read -r marker_owner; } <<EOF
$marker_fields
EOF

# The marker as it stands RIGHT NOW, versus what we parsed. Everything below acts on a read that
# is already seconds old — old enough for two `gh` round-trips, and therefore old enough for the
# owning session to open its PR, clear the marker, and for a NEXT run to write a different one in
# its place. Re-ask before every irreversible act (emitting a hint, deleting the file).
#
# WHAT THIS DOES AND DOES NOT GUARANTEE. It closes the wide window — the seconds spanning the `gh`
# calls, which is the one that actually fired. It is still check-then-act: a successor marker
# written between this returning true and the `rm -f` on the next line would be deleted, because
# `rm` resolves the PATH and not the file this compared. Shrinking the window from a network
# round-trip to a few instructions is the whole of the improvement; it is not atomicity, and the
# residual race is real rather than theoretical-in-principle.
#
# Not fixed here because the fix is not local: `cleanup-lib.sh marker-identity` re-captures at the
# moment of deletion for the same file under the same assumption, so the correct shape is ONE
# shared atomic release (claim by rename, verify, then delete or hand back) used by both consumers
# — and a claim file in the state dir also owes `/cleanup`'s `state-scan` a classification. Tracked
# in #206.
#
# Deliberately a raw byte compare rather than cleanup-lib.sh's `marker-identity` digest, which
# models this same re-verify-at-the-moment-you-act rule for this same file. That one compares
# across two PROCESSES and so needs a portable digest; both comparison points here are in one
# process holding the bytes already, so comparing them is stronger than a 32-bit checksum, needs
# no subprocess, and keeps this hook working when `lib/` is missing. If you change the rule in
# one place, the twin is `cleanup-lib.sh`'s `cmd_marker_identity`.
marker_unchanged() {
  local now=""
  { now="$(<"$marker")"; } 2>/dev/null
  [ -n "$now" ] && [ "$now" = "$marker_snap" ]
}

# Whose marker is this? The id is only consulted when the marker actually claims an owner, so an
# ownerless marker never pays for the lookup — and, on the stdin-fallback path, never risks the
# bounded read's worst case.
this_sid=""
[ -n "$marker_owner" ] && this_sid="$(this_session)"
if ! owners_compatible "$marker_owner" "$this_sid"; then
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
# silently switched off another agent's healthy run. `owners_compatible` compares them only when
# BOTH files carry an owner, so a mixed-vintage pair (one written before this field existed, one
# after) falls back to branch/issue rather than being rejected. That INVERTS the direction chosen
# for the active marker, on purpose: this is the escape hatch, not the enforcement, and the
# failure modes are not symmetric — a wrongly-REFUSED escape is an UNSTOPPABLE turn, while a
# wrongly-granted one merely ends a turn early.
#
# Read once, for the same reason the marker is: the file can be replaced between the validity
# check and the field reads.
if [ -f "$blocked" ]; then
  blocked_why="unreadable, empty, or not a JSON object"
  blocked_snap=""
  { blocked_snap="$(<"$blocked")"; } 2>/dev/null
  # Same non-object / empty-output guard as the marker: `jq -r` exits 0 on `null` and on
  # whitespace-only input, so status alone would report an unreadable file as a branch mismatch.
  blocked_fields="$(printf '%s' "$blocked_snap" | jq -r 'if type != "object" then error("not an object") else . end | .branch // "", .issue // "", .owner // ""' 2>/dev/null)" || blocked_fields=""
  if [ -n "$blocked_fields" ]; then
    blocked_branch=""; blocked_issue=""; blocked_owner=""
    { IFS= read -r blocked_branch; IFS= read -r blocked_issue; IFS= read -r blocked_owner; } <<EOF
$blocked_fields
EOF
    if ! owners_compatible "$blocked_owner" "$marker_owner"; then
      blocked_why="written by another session"
    elif { [ -n "$blocked_branch" ] && [ "$blocked_branch" = "$marker_branch" ]; } \
      || { [ -n "$blocked_issue" ] && [ "$blocked_issue" = "$marker_issue" ]; }; then
      exit 0
    else
      blocked_why="branch/issue does not match marker"
    fi
  fi
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
# the first is precisely the unsourced status claim verify-before-asserting.md forbids.
#
# Keyed on gh's EXIT STATUS, never on whether it wrote to stderr. Keying on stderr looked
# equivalent and was not: a `gh` that failed silently, and — worse — a temp file that could not be
# created at all (a read-only `.claude/state`, which made the `2>` redirection fail so gh NEVER
# RAN), both left `live_pr=none` and produced the confident "has not opened a PR yet". The stderr
# capture is now only ever a diagnostic; the temp file lives in TMPDIR because the repo directory
# is not guaranteed writable, and losing it must not cost us the lookup.
live_pr="none"

# Filter to SAME-REPO PRs (isCrossRepository==false): --head matches by branch NAME only, so in a
# fork-accepting repo an unrelated fork PR with the same branch name would otherwise be taken as
# this run's replacement PR and wrongly satisfy the invariant. This mirrors the this-repo check the
# stored-URL path enforces. Wrapped in a function so the fallback path below can reuse it verbatim
# rather than restating the query. Status is gh's own.
gh_open_pr_url() {  # <branch> <stderr-path>
  gh pr list --head "$1" --state open --json url,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository==false)][0].url // ""' 2>"$2"
}

if command -v gh >/dev/null 2>&1; then
  gh_err="$(mktemp "${TMPDIR:-/tmp}/adb-gh-err.XXXXXX" 2>/dev/null)" || gh_err=""
  if [ -n "$gh_err" ]; then
    pr_url="$(gh_open_pr_url "$run_branch" "$gh_err")" || live_pr="unchecked"
    if [ -s "$gh_err" ]; then
      printf 'implement-issue-gate: gh branch lookup failed: %s\n' "$(head -c 500 "$gh_err")" >&2
      live_pr="unchecked"
    fi
    rm -f "$gh_err" 2>/dev/null || true
  else
    pr_url="$(gh_open_pr_url "$run_branch" /dev/null)" || live_pr="unchecked"
  fi
  if [ -n "$pr_url" ] && [ "$live_pr" != "unchecked" ]; then
    marker_unchanged && { rm -f "$marker" 2>/dev/null || true; }
    exit 0
  fi
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
# round-trips, and in a shared checkout the owning session can finish inside that window. Gone or
# replaced → say NOTHING. Silence is the correct failure here: a run that needs pushing along will
# still have its marker at the next turn-end, so the only thing lost is one turn of enforcement,
# whereas a wrong instruction is acted on immediately.
if ! marker_unchanged; then
  exit 0
fi

# Invariant unmet: no PR, not blocked, tree clean. Emit the resume hint.
#
# Built as a function rather than an inline command-substitution. The original reason was a macOS
# bash 3.2 heredoc apostrophe-parsing bug, which the 5.3 floor retires (#258) — but the shape is
# kept on its own merits: the `case` below selects one of three `lead` strings before the heredoc
# renders, and a function is where that fits without nesting a multi-branch statement inside a
# substitution. No apostrophe in the body needs escaping either way now.
emit_resume_hint() {
  local lead unchecked=""
  # Every arm below has to survive a FAILED replacement lookup, not just the no-stored-PR one: the
  # closed/unverified arms tell the agent to open a replacement PR, and if the branch lookup errored
  # we have no idea whether one already exists. Saying so is the difference between a hint and an
  # unsourced claim.
  [ "$live_pr" = "unchecked" ] && unchecked=" NOTE: the live check for an existing PR on this branch could not be run (gh missing, offline, or the lookup errored), so nothing here proves one does not already exist — confirm with 'gh pr list --head ${marker_branch}' before opening anything."
  case "$stored_pr" in
    closed)
      lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} recorded a PR that is now CLOSED without merging — the run is NOT complete. Reopen it or open a replacement PR; do not stop here.${unchecked}" ;;
    unverified)
      lead="the implement-issue run for #${marker_issue} on branch ${marker_branch} recorded a PR whose live state could not be verified (gh offline/error, PR not found, or it isn't this run's PR) — not proven complete, so do not stop here. Verify with 'gh pr view' or open a PR. Only a genuine, prolonged GitHub outage is a legitimate stop: retry, then write .claude/state/implement-issue-blocked.json.${unchecked}" ;;
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
