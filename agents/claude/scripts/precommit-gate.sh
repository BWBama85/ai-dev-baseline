#!/usr/bin/env bash
# ai-dev-baseline — global Stop-hook quality gate.
#
# Claude Code runs this when the agent tries to end its turn. It blocks the stop
# (exit 2) if the repo's auto-detected quality gates (typecheck / lint / test /
# format) would fail on the current feature branch — so an autonomous run can't
# finalize work while CI-critical checks are red.
#
# No-op (exit 0) when:
#   - not in a git repo;
#   - the repo ships its OWN precommit gate at .claude/scripts/precommit-gate.sh
#     (project owns its gates — we defer to it, so nothing double-runs);
#   - HEAD is the default branch, detached, or unknown;
#   - there are zero changes on the branch (nothing to check);
#   - no supported ecosystem/gates are detected (safe in unfamiliar repos).
#
# FAIL LOUD (exit 2), never silently — when this gate's OWN required libraries
# (lib/common.sh, lib/project-gates.sh) are missing or corrupt. That is a broken /
# incomplete install, NOT an unfamiliar repo: a gate that silently no-ops then is
# enforcement secretly OFF, which is worse than a hard error (#35). This is distinct
# from "no gates detected" (a legitimate no-op decided INSIDE adb_run_gates).
#
# A red gate is genuinely wrong-until-fixed, so this stays a hard exit-2 block
# (unlike the soft "keep going" cue in implement-issue-gate.sh). See
# base/practices/ci-discipline.md for the diagnose-before-rerun philosophy.

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

# --- whose tree is this? (#241) ----------------------------------------------
# A checkout is a directory, and nothing stops two sessions opening the same one. This gate's
# inputs were purely git state, which carries no session identity, so a session that was merely
# TALKING ran the full suite over another session's mid-edit tree at every turn-end — and, because
# a red gate exits 2, could be blocked from ending its turn by work it did not write and must not
# touch. Observed twice on 2026-07-31; the second time the bystander was told to rebuild and commit
# nine generated files belonging to another session.
#
# THIS SITS BEFORE THE PROJECT-GATE `exec` DELIBERATELY. That second observation reported
# `build-drift FAIL`, which is a check name in THIS repo's own .claude/scripts/precommit-gate.sh —
# the project gate, not the global one. A check placed after the delegation would therefore miss
# the very incident it is here to prevent, and would silently do nothing in every repo that uses
# the documented escape hatch.
#
# IDENTITY COMES FROM THE ENVIRONMENT ONLY — never from the hook payload on stdin. Claude Code
# publishes the session id both ways, and the sibling implement-issue-gate.sh reads the payload as
# a fallback, but this gate must not: it `exec`s a project gate a few lines below, that child
# INHERITS stdin, and docs/per-project-overrides.md documents the inherited payload as part of the
# contract. Consuming it here to answer an optional question would leave every project gate at EOF
# to buy an identity we can do without. A host that exposes no CLAUDE_CODE_SESSION_ID simply gets
# "unknown", which is a documented, enforcing degradation — one rung shorter than the sibling
# gate's, and stated rather than implied.
#
# EVERY UNKNOWN KEEPS TODAY'S BEHAVIOR (run the gates, block on red). The dangerous direction here
# is not "gated once too often", it is "silently stopped gating": suppressing on unknown ownership
# would make the gate advisory for virtually every ordinary dirty tree, since a marker exists only
# during an /implement-issue run. That is the fail-silent class of #35 and docs/design-principles.md
# §5, so the suppression is deliberately narrow — it fires only on POSITIVE proof that another
# session owns this branch's run.
#
# NARROWER THAN THE ISSUE TITLE, and said plainly: this covers a foreign tree whose writer is
# running /implement-issue on THIS branch. A session editing the tree without a tracked run leaves
# no ownership evidence anywhere in git, so the bystander is still gated. Closing that gap needs
# per-session tree baselines, which is a different and much larger design.
foreign_run_marker() {
  local marker=".claude/state/implement-issue-active.json" raw m_branch="" m_owner="" mine
  [ -f "$marker" ] || return 1                       # no marker: the overwhelmingly common case
  mine="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$mine" ] || return 1                         # cannot identify myself -> unknown -> enforce
  command -v jq >/dev/null 2>&1 || return 1          # cannot read it -> unknown -> enforce
  command -v adb_owners_compatible >/dev/null 2>&1 || return 1   # no shared predicate -> enforce
  # ONE jq pass into a snapshot, so a concurrent write cannot hand back a mix of old and new
  # fields — and @tsv rather than two newline-separated values, because a NEWLINE INSIDE A FIELD
  # otherwise re-aims the whole decode. Measured on this implementation before the fix, and both
  # directions failed toward SUPPRESSION, i.e. toward the gate switching itself off:
  #
  #   owner  = "AAAA\nBBBB"  ->  decoded owner "AAAA"   — a truncation that is not my id
  #   branch = "feat\nevil"  ->  branch "feat" MATCHED, and the real owner was discarded in
  #                             favour of "evil", the second line of the branch
  #
  # @tsv escapes tab and newline inside values, so no field can contain the delimiter and no
  # field can shift. This is the same failure implement-issue-gate.sh pins for its own five-field
  # decode; the sibling learned it first (#180), and this decode is now held to the same bar.
  #
  # A non-string .branch/.owner makes @tsv error, jq exits non-zero, and we enforce.
  local tab; tab="$(printf '\t')"
  raw="$(jq -r '[(.branch // ""), (.owner // "")] | @tsv' "$marker" 2>/dev/null)" || return 1
  case "$raw" in *"$tab"*) : ;; *) return 1 ;; esac   # no delimiter -> cannot trust the decode
  m_branch="${raw%%"$tab"*}"
  m_owner="${raw#*"$tab"}"
  # POSITIVE PROOF MEANS A PLAUSIBLE ID, not merely a non-empty string. @tsv stops a field from
  # shifting, but it faithfully preserves a CORRUPT one — an owner of "<my-id>\nBBBB" survives as
  # a value that is genuinely not my id, and would therefore read as another session and suppress
  # the gate. Corruption is not evidence of a second session; it is evidence of a broken marker,
  # and this whole check exists to fire only on proof. A session id is an opaque token from the
  # harness (Claude Code's is a UUID), so anything carrying whitespace, a control character or a
  # backslash escape is not one, and the honest answer is "unknown" -> enforce.
  case "$m_owner" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  # The marker must be about THE BRANCH THIS TURN IS ON. A foreign run parked on some other
  # branch says nothing about the changes in front of us, and treating it as a blanket
  # suppression would turn one unrelated run into a checkout-wide gate bypass.
  [ -n "$m_branch" ] && [ "$m_branch" = "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" ] || return 1
  adb_owners_compatible "$m_owner" "$mine" && return 1
  printf 'precommit-gate: skipped — an /implement-issue run owned by another session (%.8s…) holds this branch.\n' "$m_owner" >&2
  printf 'precommit-gate: its own turn-end gates that work; this session is not blocked by a tree it did not write (#241).\n' >&2
  return 0
}
foreign_run_marker && exit 0

# Defer to a project-local gate if one exists and it isn't this very file — by RUNNING it, not by
# stepping aside. `exit 0` here was enforcement silently OFF (#240): nothing else invokes a project
# gate. No project-level Stop hook is wired by install.sh, the adapter, or bin/baseline, so a repo
# that followed the documented escape hatch ("ship a full replacement script at that exact path")
# ended up with a gate script nothing ran AND the global gate standing down — strictly worse than
# before, and the exact fail-silent class #35 made this file fail loud about.
#
# `exec` is what makes the project's script genuinely BE the gate: it inherits stdin (the hook
# payload), and its exit status becomes this hook's, so a project gate can still block a stop with
# 2. The `-ef` inode test above is what keeps this from re-entering itself when the global copy IS
# the project copy. A non-executable script is run via bash rather than failing the hook, since
# `chmod +x` is easy to forget in a repo that ships one.
proj_gate="$repo_root/.claude/scripts/precommit-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  [ -x "$proj_gate" ] && exec "$proj_gate" "$@"
  exec bash "$proj_gate" "$@"
fi

# --- fail-loud dependency loading (#35) --------------------------------------
# This gate's shared libraries live in the sibling lib/ (installed as ~/.<agent>/scripts/lib).
# They are REQUIRED, not optional. A missing/corrupt library is a broken install, and a gate
# that silently no-ops then is enforcement secretly OFF — so it FAILS LOUD (exit 2, blocking),
# never exit 0. Resolving the default branch and the change set needs common.sh's
# adb_default_branch (single-source: never re-implement it here, per docs/design-principles.md),
# so common.sh is required up front — before the branch/changes no-op checks below.
lib_dir="$(dirname "$0")/lib"
fail_loud() {
  printf '\nprecommit-gate: FATAL — %s\n' "$1" >&2
  printf 'This is NOT a pass. The quality gates cannot run, so the turn is BLOCKED. The baseline\n' >&2
  printf "install is incomplete or an installed path moved — repair it with 'baseline update'\n" >&2
  printf '(or re-run install.sh from your baseline clone), then retry.\n' >&2
  exit 2
}
# Source a REQUIRED sibling library or fail loud: a missing file, an un-sourceable one, or one
# sourced but missing its expected function (a corrupt/truncated library) each block the turn.
require_lib() {  # <path> <expected-fn>
  [ -f "$1" ] || fail_loud "shared library not found: $1"
  # shellcheck source=/dev/null
  . "$1" || fail_loud "shared library failed to source: $1"
  command -v "$2" >/dev/null 2>&1 || fail_loud "$1 did not define $2 (corrupt library)"
}
require_lib "$lib_dir/common.sh" adb_default_branch

# Resolve the default branch (origin/HEAD → main → master → "main").
default_branch="$(adb_default_branch "$repo_root")"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  exit 0
fi

# Are there any changes at all on this branch? (committed vs base + working tree)
# `--no-renames` so a moved file surfaces BOTH its old and new path — a gate scoped to
# the area a file moved OUT of must still see the change (see project-gates.sh scope).
base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
committed=""
if git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
  committed="$(git diff --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null || true)"
fi
staged="$(git diff --no-renames --name-only --cached 2>/dev/null || true)"
unstaged="$(git diff --no-renames --name-only 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
changed="$(printf '%s\n%s\n%s\n%s\n' "$committed" "$staged" "$unstaged" "$untracked" | sort -u | sed '/^$/d')"
[ -z "$changed" ] && exit 0

# We are on a feature branch WITH changes: the gate WILL run. The gate library is required
# here too — a missing/corrupt one is the same broken-install fail-loud condition as common.sh
# above (a silent skip here was the old fail-silent bug #35 fixes), never a silent skip.
require_lib "$lib_dir/project-gates.sh" adb_run_gates

# Pass the branch change set so a path-scoped gate ([gates.scope] in agents.toml) runs
# only when it touches a matching file — the escape hatch that lets a repo express
# apps/**-style scoping without forking this whole script.
#
# And declare the CONTEXT: this is the per-turn caller (#240). A gate declared
# `[gates.cadence] <label> = "full"` is skipped here and reported, so a repo whose `test` gate is
# its own CI mirror no longer re-runs CI at the end of every turn. Nothing else changes: a repo
# with no [gates.cadence] table has every gate at the default `always` and behaves exactly as
# before. This is the ONLY caller that passes `turn-end` — the workflows' in-loop
# `project-gates.sh run` is a full run and still runs everything.
if adb_run_gates "$repo_root" "$changed" turn-end; then
  exit 0
fi

printf '\nprecommit-gate: blocking stop — fix the failing gate(s) above before ending the turn.\n' >&2
exit 2
