#!/usr/bin/env bash
# ai-dev-baseline — /implement-issue's RUN-ADMISSION decision (issue #202).
#
# One question, asked once, at the top of a run: **may a new /implement-issue run start in this
# checkout right now?** Preflight used to answer it by not asking — it `rm -f`'d the run marker,
# the blocked marker and the gap-analysis lock unconditionally — so a second session starting a
# run deleted a first session's LIVE state before any ownership check could see it. #180 gave the
# marker an `owner` and made the Stop hook refuse to act on a foreign one; it never gets the
# chance if the marker was already gone. That is the half ownership cannot fix, and this module is
# where it is fixed.
#
# THE DECISION IS "REFUSE", NOT "SUPPORT" (D46). Two /implement-issue runs in one checkout share
# ONE HEAD: they fight over the checked-out branch whether or not their state files collide, so
# per-run state paths would make the state layer safe for a configuration that still cannot work.
# `/implement-issue` has always DECLARED a one-active-run-per-checkout boundary (cited by D40 and
# by base/workflows/cleanup.md); this enforces it.
#
# WHAT "ONE CHECKOUT" MEANS HERE, EXACTLY. The state directory is per-agent — `.claude/state`,
# `.codex/state`, `.gemini/state` — so this excludes a second run of the SAME agent. A Claude run
# and a Codex run in one checkout never collide on these paths at all; they collide on HEAD, and
# the second one's preflight already hard-errors ("not on <default> and '<branch>' is not provably
# merged"). Cross-agent exclusion would need a new shared state home and is deliberately NOT
# invented here — see D46.
#
# NO OWNERSHIP TEST, AND THAT IS THE POINT. `owner` names a SESSION, not a run: ownership is
# explicitly transferable (D17c), one session can legitimately invoke the workflow twice, and
# `owners_compatible` treats an ABSENT owner as compatible — correct for enforcement, unsafe for
# authorizing a delete. So admission never asks whose marker it is. A marker that is not provably
# STALE refuses the new run, full stop; a marker that IS provably stale is cleared regardless of
# who wrote it. Ownership stays where it works: telling the Stop hook whether to speak.
#
# STALENESS IS NOT RE-DERIVED HERE. `cleanup-lib.sh state-verdict marker` is already the ONE home
# for "is this run marker dead?" — PR state plus local and remote branch refs, every unknown
# failing closed to `keep` — and `/cleanup` reaps a crashed run's marker with it today. This module
# gathers the same three facts the same way `base/workflows/cleanup.md` does and asks that
# predicate. It does NOT contain a second staleness rule, and must not grow one.
#
# ACQUIRE BEFORE YOU CLEAR. The check and the clear used to be two steps with a window between
# them, so two sessions could both observe an empty state directory and both proceed. The claim is
# therefore taken with O_EXCL (`set -C` + `>`) BEFORE anything is deleted: the session that loses
# the race mutates NOTHING and is refused. This is check-then-act only in the sense that every
# lock is — the winner is decided by the kernel, not by the order of two reads.
#
# THE CLAIM IS `gap-analysis.lock`, WIDENED — not a second signal beside it. The file already
# exists to mean "a run is in flight and has not written its marker yet" (the step-3 window, where
# no marker exists because step 5 has not run). Admission moves its acquisition EARLIER, to
# preflight, so it covers that whole pre-marker window instead of just the dispatch. `/cleanup`
# reads it exactly as before (`state-scan` classifies it `lock`; `state-verdict gaps` lets it
# outrank everything), and holding it longer only ever PRESERVES more. A second lock file would be
# a second liveness signal that can leak, be cleared late, and disagree with the first — which is
# the trap D40 declined for review artifacts.
#
# THE CLAIM CARRIES A LEASE, because nothing else can reap it. `/cleanup` never deletes a `lock`
# record (base/workflows/cleanup.md's sweep handles only `gaps`, `review` and `threads`), and this
# module no longer clears it unconditionally — so without an expiry, one killed run would refuse
# every later run in that checkout forever. That is the permanent block #202 explicitly warns
# against. The lease is derived from the dispatch backstop the pre-marker window is actually
# bounded by (`ADB_DISPATCH_TIMEOUT_SECS`, default 2700s): two dispatches plus an hour of reading.
# This is NOT "mtime as liveness" — the file's age is not evidence about a PR or a branch, it is an
# expiry on a lease this framework's own timeout already bounds.
#
# EVERY UNKNOWN REFUSES, AND REFUSING NEVER DELETES. Missing jq, an unreadable marker, a `gh` that
# errors: none of them can establish that the state belongs to a dead run, so none of them may
# authorize clearing it. Each prints what it could not establish and the recovery for it. This is
# the opposite direction from implement-issue-gate.sh, which no-ops when it cannot parse — correct
# there (a hook that cannot read must not nag) and wrong here (a starter that cannot read must not
# delete).
#
# Exit status — the caller MUST branch on it, never on stdout:
#   0   admitted. The claim is held and stale state has been cleared.
#   10  REFUSED — an active run marker is not provably stale (a run is in flight, or unfinished).
#   11  REFUSED — a marker exists but could not be read, so its identity cannot be established.
#   12  REFUSED — a required tool (jq) is missing, so no fact can be established.
#   13  REFUSED — another run holds the claim and its lease has not expired.
#   14  REFUSED — the claim was taken but stale state could not be cleared; the claim was released.
#   2   usage error.
#
# Usage:
#   implement-lib.sh admit   <state-dir>    # may a run start? acquire + clear when yes
#   implement-lib.sh release <state-dir>    # drop this run's claim (idempotent)
#   implement-lib.sh -h | --help
#
# Requires: jq. `gh` and `git` are used when present; their absence fails CLOSED (refuse), never
# open. Deliberately NOT part of cleanup-lib.sh, whose charter is /cleanup's predicates and whose
# header promises network purity — this module makes live PR reads by design.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_il_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_il_common="$_adb_il_libdir/common.sh"
if [ ! -f "$_adb_il_common" ]; then
  printf 'implement-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_il_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_il_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

# The staleness predicate lives next door and is asked, never copied. install.sh symlinks the whole
# scripts/lib directory, so the two always ship together.
_ADB_IL_CLEANUP_LIB="$_adb_il_libdir/cleanup-lib.sh"

usage() { adb_usage "$0"; }

# --- names ------------------------------------------------------------------------------------
# The ONE home for every filename this module touches. `/cleanup`'s classifier (`state-scan`) owns
# the same set from the other side, and the invariant between them is CONTAINMENT in one direction:
# everything /cleanup can sweep, this can clear. Widening the clear is always safe; narrowing it
# strands an artifact that a fresh run's marker then makes read as live (the #264 trap).
_IL_MARKER=implement-issue-active.json
_IL_BLOCKED=implement-issue-blocked.json
_IL_CLAIM=gap-analysis.lock

# --- the lease ----------------------------------------------------------------------------------
# Seconds a claim stays valid. Derived from the bound the pre-marker window is ACTUALLY limited by:
# role-dispatch.sh kills a hung dispatch at ADB_DISPATCH_TIMEOUT_SECS (default 2700), gap analysis
# is at most one dispatch plus one retry, and the agent then reads the findings. Two dispatches plus
# an hour is generous without being unbounded.
#
# ADB_RUN_CLAIM_LEASE_SECS overrides it outright, including with 0 — which makes every claim
# instantly expired and is how the test suite drives the break-and-reacquire path.
_il_lease_secs() {
  local o="${ADB_RUN_CLAIM_LEASE_SECS:-}" d="${ADB_DISPATCH_TIMEOUT_SECS:-2700}"
  case "$o" in '') : ;; *[!0-9]*) : ;; *) printf '%s' "$o"; return 0 ;; esac
  case "$d" in ''|*[!0-9]*) d=2700 ;; esac
  printf '%s' "$(( d * 2 + 3600 ))"
}

# The claim's expiry as an epoch integer, or NOTHING when it cannot be read.
#
# Nothing means EXPIRED, deliberately, and it is the migration path as well as the corruption path:
# a lock written by an install predating this module is an empty file (`: > lock`), carries no
# lease, and would otherwise block that checkout permanently the first time it was left behind. The
# old behaviour for such a file was an unconditional clear, so treating it as expired is not a
# regression — but it IS reported, so the operator sees a claim being broken rather than silently
# taken.
_il_claim_expiry() {
  jq -r 'if type == "object" and (.expiresAt | type) == "number"
         then (.expiresAt | floor | tostring) else empty end' "$1" 2>/dev/null
}

# Take the claim, or fail because someone else holds it. O_EXCL via bash's noclobber, in a SUBSHELL
# so `set -C` cannot leak into the caller's shell. The payload is written by the same redirection
# that creates the file, so a winner never publishes an empty claim.
_il_acquire() {   # <claim-path> <payload>
  ( set -C; printf '%s\n' "$2" > "$1" ) 2>/dev/null
}

# --- admit --------------------------------------------------------------------------------------
cmd_admit() {
  [ "$#" -eq 1 ] || { echo "implement-lib: admit needs exactly 1 arg: <state-dir>" >&2; exit 2; }
  local dir="$1" marker="$1/$_IL_MARKER" claim="$1/$_IL_CLAIM" ident=""

  # jq FIRST, and fatal. Every fact below is read through it; without it the marker is unreadable,
  # and an unreadable marker must never authorize its own deletion.
  command -v jq >/dev/null 2>&1 || {
    echo "implement-lib: REFUSED — jq is not on PATH, so no run state can be read." >&2
    echo "               Install jq and re-run; nothing was deleted." >&2
    return 12
  }

  mkdir -p "$dir" 2>/dev/null || {
    echo "implement-lib: REFUSED — cannot create the state directory: $dir" >&2
    return 14
  }

  # --- 1. is a run already in flight? ------------------------------------------------------------
  # Asked BEFORE the claim is taken and before anything is deleted, so a refusal here leaves the
  # checkout exactly as it was found.
  if [ -f "$marker" ]; then
    local key lref rref prstate url verdict
    # THE IDENTITY OF THE FILE AS JUDGED, captured FIRST — before the branch read, the ref lookups
    # and the `gh` round trip, all of which take time the marker can be replaced in. Capturing it
    # after those reads fingerprints whatever arrived DURING them, so the delete-time comparison
    # below would compare a replacement against itself and always match (observed: the mid-read
    # replacement case passed with the capture one step later).
    #
    # A content digest and not `.branch`: retrying an issue whose branch was already swept writes
    # the identical deterministic `issue-NN-slug`, so a branch-only comparison reports "unchanged"
    # for a different, live run's marker. Same primitive and same reasoning as /cleanup's own
    # delete-time re-read.
    ident="$(bash "$_ADB_IL_CLEANUP_LIB" marker-identity "$marker" 2>/dev/null)" || ident=""
    # ONE reader for the marker's branch, shared with /cleanup's scan and its delete-time re-read.
    # An empty key means unreadable, which the fact-gathering below turns into `unknown` and the
    # predicate turns into `keep` — the same fail-closed path cleanup.md takes.
    key="$(bash "$_ADB_IL_CLEANUP_LIB" marker-branch "$marker" 2>/dev/null)" || key=""
    # NOT IN A GIT REPOSITORY IS `unknown`, NOT "the refs are absent". `git show-ref` exits non-zero
    # for both, and collapsing them would read a perfectly live marker as a dead run's — two absent
    # refs plus no PR is precisely the `stale` verdict that authorizes deleting it. Preflight always
    # calls this from inside the repo, so the case is unreachable today; it is written this way
    # because the cost of being wrong is deleting the state of a run that is still going.
    if [ -z "$key" ] || ! git rev-parse --show-toplevel >/dev/null 2>&1; then
      lref=unknown; rref=unknown
    else
      lref=0; git show-ref --verify --quiet "refs/heads/$key" 2>/dev/null && lref=1
      rref=0; git show-ref --verify --quiet "refs/remotes/origin/$key" 2>/dev/null && rref=1
    fi

    # An OPEN PR outranks branch absence — the branch may have been tidied while the run is live —
    # so the PR is consulted only when both refs are already gone. Same ordering, same fields and
    # same source as base/workflows/cleanup.md's marker pass; a `gh` that is absent or errors
    # yields `unknown`, which the predicate fails closed on.
    prstate=none
    if [ "$lref" = 0 ] && [ "$rref" = 0 ]; then
      url="$(jq -r '.prUrl // empty' "$marker" 2>/dev/null || true)"
      if [ -n "$url" ]; then
        prstate=unknown
        if command -v gh >/dev/null 2>&1; then
          local s=""
          s="$(gh pr view "$url" --json state --jq '.state | ascii_downcase' 2>/dev/null)" || s=""
          [ -n "$s" ] && prstate="$s"
        fi
      fi
    fi

    if ! verdict="$(bash "$_ADB_IL_CLEANUP_LIB" state-verdict marker "$prstate" "$lref" "$rref" 2>/dev/null)"; then
      echo "implement-lib: REFUSED — the run marker at $marker could not be classified." >&2
      echo "               Nothing was deleted. Inspect it, or remove it once you are sure no run is live." >&2
      return 11
    fi

    if [ "$verdict" = keep ]; then
      # An unreadable marker gets its OWN code and its own sentence. The verdict is the same `keep`,
      # but the operator's next move is not: there is no branch to switch to and no PR to look up —
      # the file itself is what needs looking at. Collapsing the two would send them hunting for a
      # run that the marker never named.
      if [ -z "$key" ]; then
        echo "implement-lib: REFUSED — a run marker exists but its branch could not be read: $marker" >&2
        echo "               Its identity cannot be established, so it cannot be proven dead and" >&2
        echo "               will not be deleted. Nothing was changed. Inspect the file, then remove" >&2
        echo "               it once you are sure no run is live." >&2
        return 11
      fi
      local issue phase
      issue="$(jq -r '.issue // "?"' "$marker" 2>/dev/null || echo '?')"
      phase="$(jq -r '.phase // "?"' "$marker" 2>/dev/null || echo '?')"
      echo "implement-lib: REFUSED — an /implement-issue run is already in flight in this checkout." >&2
      echo "               issue #$issue · branch $key · phase $phase · $marker" >&2
      echo "               Two runs in one checkout share one HEAD and cannot both work, so this run" >&2
      echo "               will not start. Finish or abandon that run first:" >&2
      echo "                 - still working it?  switch to $key and continue it." >&2
      echo "                 - finished with it?  run /cleanup — it removes the marker once the" >&2
      echo "                   branch is gone and the PR is not open." >&2
      echo "                 - certain it is dead? delete $marker." >&2
      return 10
    fi
  fi

  # --- 2. take the claim, atomically, BEFORE deleting anything ----------------------------------
  # The session that loses this race has mutated nothing at all.
  local lease payload now expiry
  lease="$(_il_lease_secs)"
  now="$(date -u +%s)"
  payload="$(jq -cn --arg owner "${CLAUDE_CODE_SESSION_ID:-}" \
                    --argjson startedAt "$now" --argjson expiresAt "$(( now + lease ))" \
                 '{startedAt:$startedAt, expiresAt:$expiresAt}
                  + (if $owner == "" then {} else {owner:$owner} end)')" || payload=""
  [ -n "$payload" ] || {
    echo "implement-lib: REFUSED — could not compose the run claim (jq failed); nothing was deleted." >&2
    return 12
  }

  if ! _il_acquire "$claim" "$payload"; then
    # A FAILED CREATE IS NOT A CONTENDED CLAIM. `set -C` refuses because the file exists; the same
    # redirection also fails when the directory is not writable, and nothing else distinguishes the
    # two. Reporting an unwritable state dir as "another run holds the claim" sends the operator
    # hunting for a run that does not exist — and, worse, invites them to delete a claim file that
    # is not there. Ask whether anything is actually holding it.
    if [ ! -e "$claim" ]; then
      echo "implement-lib: REFUSED — could not create the run claim at $claim." >&2
      echo "               Nothing is holding it; the state directory is not writable. Nothing was deleted." >&2
      return 14
    fi
    expiry="$(_il_claim_expiry "$claim")"
    if [ -n "$expiry" ] && [ "$now" -lt "$expiry" ]; then
      echo "implement-lib: REFUSED — another /implement-issue run holds the run claim." >&2
      echo "               $claim (lease expires in $(( expiry - now ))s)" >&2
      echo "               That run is between preflight and its first commit — it has no marker yet," >&2
      echo "               and clearing its claim is what deletes its gap-analysis findings mid-dispatch." >&2
      echo "               Wait for it, or delete $claim if you are certain it is dead." >&2
      return 13
    fi
    # Expired, or unreadable (an empty pre-#202 lock). Break it — loudly — and re-take. The re-take
    # is O_EXCL too, so if a third session broke it first, this one is refused rather than sharing.
    if [ -n "$expiry" ]; then
      echo "implement-lib: NOTE — breaking an EXPIRED run claim ($(( now - expiry ))s past its lease): $claim" >&2
    else
      echo "implement-lib: NOTE — breaking a run claim with no readable lease (pre-#202 or corrupt): $claim" >&2
    fi
    rm -f "$claim" 2>/dev/null
    if ! _il_acquire "$claim" "$payload"; then
      # Same split as above: the break may have failed because the directory is read-only, in which
      # case the stale claim is still sitting there and no third run was ever involved.
      if [ -e "$claim" ] && [ -n "$(_il_claim_expiry "$claim")" ]; then
        echo "implement-lib: REFUSED — the run claim was re-taken by another run while this one was breaking it." >&2
        return 13
      fi
      echo "implement-lib: REFUSED — could not replace the stale run claim at $claim (state directory not writable?)." >&2
      return 14
    fi
  fi

  # --- 3. holding the claim: clear what the previous run left behind ----------------------------
  # RE-VERIFY THE MARKER AT THE MOMENT OF THE DELETE. Step 1's verdict describes the file as it was
  # read, and the acquire (plus a possible `gh` round trip) sits between that read and this delete.
  # Holding the claim is what makes the window small — a competing run cannot get past `admit` while
  # this claim is held, so it cannot reach step 5 and write a marker — but "small" is not "closed",
  # and the failure it would cause is the exact one this module exists to prevent: deleting a live
  # run's marker. So the rule /cleanup already follows applies here too, and for the same reason:
  # a marker that is no longer the one that was judged is somebody else's, and this run stands down.
  #
  # An EMPTY identity is a mismatch, not a pass: an identity that cannot be established is not one
  # that matches.
  if [ -n "$ident" ]; then
    local ident_now
    ident_now="$(bash "$_ADB_IL_CLEANUP_LIB" marker-identity "$marker" 2>/dev/null)" || ident_now=""
    if [ "$ident_now" != "$ident" ]; then
      rm -f "$claim" 2>/dev/null
      echo "implement-lib: REFUSED — the run marker changed between being judged stale and being cleared." >&2
      echo "               It belongs to a different run now, so nothing was deleted and the claim was released." >&2
      return 10
    fi
  fi

  # Reached only when no live run was found, so everything below is a FINISHED run's leftovers.
  # A failure to clear is reported and RELEASES the claim: proceeding would leave a stale marker
  # that the Stop hook reads as this run's, and holding a claim for a run that never starts is the
  # permanent block this module exists to avoid.
  local rc=0
  _il_clear "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$claim" 2>/dev/null
    echo "implement-lib: REFUSED — could not clear stale run state from $dir (directory not writable?)." >&2
    echo "               The run claim was released; nothing is holding this checkout." >&2
    return 14
  fi

  printf 'admitted\n'
  return 0
}

# Remove every artifact a FINISHED run leaves behind, except the claim this run is holding.
#
# `nullglob` in a subshell, not `find`: the prose version had to use `find` because an unmatched
# glob ABORTS the command under zsh's default `nomatch` and macOS runs zsh — but this is a real
# bash script with a 5.3 floor, so the shell option that makes globs safe is simply available.
# `-e` rather than `-f` so a symlink is removed too: `state-scan` selects with `[ -f ]`, which
# FOLLOWS a link to a regular file and classifies it — a name /cleanup can sweep but this cannot
# clear is exactly the stale-reads-as-current file the containment invariant forbids.
#
# The gap FAMILY (`gaps-*.md`, `gaps-*.err`) is cleared, not just the three fixed names. `state-scan`
# has swept that family since #84 recorded a real run leaving `gaps-retry.{md,err}` behind, so the
# fixed-name-only clear the workflow prose carried was on the wrong side of the containment rule.
_il_clear() {   # <state-dir>
  local dir="$1" f rc=0 had_nullglob=0
  local -a targets=(
    "$dir/$_IL_MARKER"        "$dir/$_IL_BLOCKED"
    "$dir/gap-prompt.txt"     "$dir/gaps.md"    "$dir/gaps.err"
    "$dir/review-prompt.txt"  "$dir/review.md"  "$dir/review.err"
  )
  # The family globs, expanded with `nullglob` so an unmatched pattern contributes NOTHING rather
  # than arriving as a literal path that the loop below would then try to `rm`. The option is saved
  # and restored: this file may be sourced, and silently flipping a caller's globbing is the kind of
  # action-at-a-distance that surfaces somewhere else entirely.
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  targets+=( "$dir"/gaps-*.md "$dir"/gaps-*.err "$dir"/review-*.md "$dir"/review-*.err )
  [ "$had_nullglob" -eq 1 ] || shopt -u nullglob
  for f in "${targets[@]}"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -f "$f" 2>/dev/null
    # Verified, never assumed: `rm -f` on an unlinkable path in a read-only directory returns
    # non-zero on some platforms and 0 on others, so the observable is whether the file is gone.
    if [ -e "$f" ] || [ -L "$f" ]; then rc=1; fi
  done
  return "$rc"
}

# --- release --------------------------------------------------------------------------------------
# Idempotent by contract: every caller is a stop path, and a stop path that fails because there was
# nothing to release is a worse failure than the one it is reporting.
cmd_release() {
  [ "$#" -eq 1 ] || { echo "implement-lib: release needs exactly 1 arg: <state-dir>" >&2; exit 2; }
  rm -f "$1/$_IL_CLAIM" 2>/dev/null
  if [ -e "$1/$_IL_CLAIM" ]; then
    echo "implement-lib: could not release the run claim: $1/$_IL_CLAIM" >&2
    return 14
  fi
  return 0
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  admit)     cmd_admit "$@" ;;
  release)   cmd_release "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "implement-lib: unknown subcommand '$SUB' (expected 'admit' or 'release')" >&2; usage >&2; exit 2 ;;
esac
