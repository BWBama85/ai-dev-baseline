#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for implement-lib.sh's RUN ADMISSION (#202).
#
# The decision under test: **may a new /implement-issue run start in this checkout?** Preflight used
# to answer by not asking — an unconditional `rm -f` of the run marker, the blocked marker and the
# gap lock — so a second session deleted a first session's LIVE state before #180's ownership check
# could see it. `admit` refuses instead, and only clears once it has proved the previous run is dead
# AND taken this run's claim.
#
# WHY THE REFUSAL CASES ASSERT TWO THINGS. A guard's failure mode is silence, and this one's silence
# is *deleting something*: an `admit` that wrongly returns 0 looks exactly like a healthy start. So
# every case that expects a REFUSAL also asserts what survived — a refusal that returns 10 and still
# cleared the artifacts is the bug wearing the fix's exit code. (Cases asserting an ADMIT check what
# was cleared instead, which is the same question from the other side.)
#
# `gh` is stubbed by a shim on PATH driven by SHIM_* env vars, so the PR half of the staleness
# question runs offline and deterministically. Every case builds its own fixture repo; the tracked
# tree is never touched.
#
# Usage: bash scripts/check-implement-lib.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd. Before
# the cd because $0 is frozen at invocation; before `set -u` because an unbound expansion while a
# library loads is fatal under it, and would kill the suite with a message about a variable rather
# than about the library. The load is confirmed by PROBING FOR THE FUNCTION, never by the source's
# exit status — a sourced file returns its LAST command's status, which says nothing about loading.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
IL="$ROOT/scripts/lib/implement-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "check-implement-lib: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "implement-lib"

work="$(mktemp -d)"
# `chmod` first: a read-only fixture directory is one of the cases, and `rm -rf` cannot descend
# into it. Without this the suite leaks a directory on every run and the trap looks like it worked.
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT

# --- gh shim ----------------------------------------------------------------------------------
shimbin="$work/bin"; mkdir -p "$shimbin"
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_STATE:-}" ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"
PATH="$shimbin:$PATH"
export PATH

# --- PATHs with exactly ONE tool missing -------------------------------------------------------
# Shadowing a tool with a stub cannot express absence: `command -v jq` would still succeed, which is
# the very test `admit` performs. And a hand-rolled minimal PATH is worse — it removes `dirname`
# too, so the library's own resolution fails and the case reports a broken install instead of the
# behaviour under test (observed: rc 1, not 12). So mirror EVERY reachable command as a symlink and
# omit exactly one. The suite's own interpreter is passed explicitly, because `bash` resolved from a
# reduced PATH on macOS is the 3.2 build and the floor gate would fire instead of the case.
mirror_without() {   # <tool> <dest-dir>
  local drop="$1" dest="$2" pd exe base
  local -a pdirs=()
  mkdir -p "$dest"
  IFS=: read -r -a pdirs <<< "$PATH"
  for pd in "${pdirs[@]}"; do
    [ -d "$pd" ] || continue
    for exe in "$pd"/*; do
      base="${exe##*/}"
      [ "$base" = "$drop" ] && continue
      [ -x "$exe" ] || continue
      [ -e "$dest/$base" ] || ln -s "$exe" "$dest/$base" 2>/dev/null
    done
  done
  # A mirror that dropped the wrong thing, or nothing, makes its case vacuous — so say so here
  # rather than letting the case pass for the wrong reason.
  if [ -e "$dest/$drop" ] || ! [ -x "$dest/git" ]; then
    bad "0 the no-$drop PATH mirror is broken ($drop present, or git missing) — that case would assert nothing"
  fi
}
nojq="$work/nojq"; mirror_without jq "$nojq"
nogh="$work/nogh"; mirror_without gh "$nogh"

# --- fixtures -----------------------------------------------------------------------------------
# new_repo — a throwaway repo with one commit and an empty state dir. Prints its path, and NOTHING
# else: the whole function runs inside a command substitution, so any stray git chatter on stdout
# becomes part of the path the caller then tries to `cd` into. `mktemp -d` rather than a counter
# for the same reason — a `n=$((n+1))` inside the substitution increments a copy, so every call
# would hand back the same directory and each later fixture would inherit the previous one's state.
new_repo() {
  local d
  d="$(mktemp -d "$work/r.XXXXXX")"
  mkdir -p "$d/.claude/state"
  {
    git init -q "$d"
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name  t
    : > "$d/seed"; git -C "$d" add seed; git -C "$d" commit -qm seed
  } >/dev/null 2>&1
  printf '%s' "$d"
}
# marker <repo> <branch> [prUrl] — write an active marker.
marker() {
  jq -n --arg b "$2" --arg u "${3:-}" \
     '{branch:$b, issue:"99", phase:"branched"} + (if $u == "" then {} else {prUrl:$u} end)' \
     > "$1/.claude/state/implement-issue-active.json"
}
# admit <repo> [env…] — run admission from INSIDE the repo (the git reads are CWD-relative).
# Sets AD_RC and AD_OUT.
admit() {
  local d="$1"; shift
  AD_OUT="$( cd "$d" && env "$@" bash "$IL" admit .claude/state 2>&1 )"; AD_RC=$?
}
# state_digest <repo> — a stable fingerprint of the whole state directory: every name, and every
# byte of every file. This is what "neither run loses its state" is actually asserted against.
state_digest() {
  ( cd "$1/.claude/state" 2>/dev/null || exit 0
    find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s:%s\n' "$f" "$(cksum < "$f" 2>/dev/null | awk '{print $1"-"$2}')"
    done )
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }
# A claim whose lease ran out long ago. The suite used to drive this with
# `ADB_RUN_CLAIM_LEASE_SECS=0`, which the module now REJECTS as invalid — a sub-minute lease
# disables the exclusion it exists to provide, so leaving that lever in place would have meant
# shipping a footgun purely to make a test convenient. Forging the file is both more honest (it is
# the state a killed run really leaves) and independent of the lease policy.
expired_claim() {   # <repo> [token] [owner]
  jq -n --arg t "${2:-forged-token}" --arg o "${3:-sess-dead}" \
     '{startedAt:1, expiresAt:2, token:$t, owner:$o}' > "$1/.claude/state/gap-analysis.lock"
}

# ================= 1. the happy path ============================================================
d="$(new_repo)"
admit "$d"
eq "$AD_RC" "0" "1 an empty state directory admits the run"
if exists "$d/.claude/state/gap-analysis.lock"; then ok; else bad "1 …and the claim is taken"; fi
eq "$(jq -r 'if (.expiresAt|type)=="number" and (.startedAt|type)=="number" then "ok" else "bad" end' \
      "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "ok" \
   "1 …carrying a numeric lease, which is what makes a stranded claim recoverable"
# The claim's owner is written when the harness exposes a session id, and OMITTED when it does not —
# never invented. `admit` does not USE it (see case 8), but a claim nobody can attribute is worse
# than no field at all when an operator has to decide whether to break one.
d="$(new_repo)"; admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
eq "$(jq -r '.owner // "absent"' "$d/.claude/state/gap-analysis.lock")" "sess-A" \
   "1 the claim records the session that took it"
d="$(new_repo)"; admit "$d" CLAUDE_CODE_SESSION_ID=
eq "$(jq -r '.owner // "absent"' "$d/.claude/state/gap-analysis.lock")" "absent" \
   "1 …and omits the key entirely when the harness exposes no id, rather than writing an empty one"

# ================= 2. concurrency: the acquire is atomic ========================================
d="$(new_repo)"
admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
eq "$AD_RC" "0" "2 session A is admitted"
before="$(state_digest "$d")"
admit "$d" CLAUDE_CODE_SESSION_ID=sess-B
eq "$AD_RC" "13" "2 session B is REFUSED while A holds the claim"
eq "$(state_digest "$d")" "$before" "2 …and B changed nothing at all — the claim is still A's, byte for byte"
has "$AD_OUT" "holds the run claim" "2 …and the refusal says what is holding it"
# A LOSER MUST NOT INHERIT. The claim B failed to take is still A's, so B's own session id must not
# appear in it — that would make a later break-decision attribute the run to the wrong session.
eq "$(jq -r '.owner' "$d/.claude/state/gap-analysis.lock")" "sess-A" \
   "2 …and the claim still names A, not the session that lost the race"

# ================= 3. THE ACCEPTANCE CASE: two live runs, one tree ==============================
# The issue asks for "two live runs, one tree, neither losing its marker". Under a refusal design
# there are never two markers — so the property to assert is the one that actually protects run A:
# B is refused, and every byte of A's state survives. This is the exact scenario that used to
# silently disarm A's continuation gate.
d="$(new_repo)"
git -C "$d" branch issue-99-live
marker "$d" issue-99-live
printf '{"reason":"gate","branch":"issue-99-live","issue":"99"}' > "$d/.claude/state/implement-issue-blocked.json"
printf 'A findings\n'   > "$d/.claude/state/gaps.md"
printf 'A stream\n'     > "$d/.claude/state/gaps.err"
printf 'A prompt\n'     > "$d/.claude/state/gap-prompt.txt"
printf 'A review\n'     > "$d/.claude/state/review.md"
printf 'A slot\n'       > "$d/.claude/state/review-codex.md"
# The issue SNAPSHOT (#250). It is the most sensitive thing run A holds — the untrusted issue body
# and the `author_association` label that tells a dispatched agent whether the task came from a
# maintainer — and step 8 reads it back long after the marker exists, so B destroying it would
# corrupt A's review dispatch, not merely lose a re-derivable artifact.
printf '{"state":"OPEN"}\n' > "$d/.claude/state/issue-99.json"
printf 'OWNER\n'           > "$d/.claude/state/issue-99.assoc"
before="$(state_digest "$d")"
admit "$d" CLAUDE_CODE_SESSION_ID=sess-B
eq "$AD_RC" "10" "3 a second run is REFUSED while run A's marker is live"
eq "$(state_digest "$d")" "$before" \
   "3 …and A keeps EVERY file byte-for-byte: marker, blocked marker, gap findings, review findings, issue snapshot"
has "$AD_OUT" "already in flight" "3 …and the refusal names the condition"
has "$AD_OUT" "issue-99-live"     "3 …and the branch the operator has to go finish"
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "3 …and B took no claim, so it cannot strand one on its way out"
else ok; fi

# ================= 4. what counts as LIVE ======================================================
# Each of these seeds an artifact and asserts the WHOLE state directory is byte-identical
# afterwards, not just that the exit code was 10. A refusal that returns the right code and still
# clears the previous run's findings is the defect wearing the fix's signature, and only the digest
# can see it.
live_case() {   # <label> <setup-fn-body-already-run> ; expects $d seeded, runs admit with $@ env
  local label="$1"; shift
  printf 'seed\n' > "$d/.claude/state/gaps.md"
  local before; before="$(state_digest "$d")"
  admit "$d" "$@"
  eq "$AD_RC" "10" "4 $label"
  eq "$(state_digest "$d")" "$before" "4 …and nothing in the state dir was touched ($label)"
}
# Local ref only.
d="$(new_repo)"; git -C "$d" branch issue-1-x; marker "$d" issue-1-x
live_case "a marker whose LOCAL branch still exists is live"
# Remote-tracking ref only (the branch was pushed, then deleted locally).
d="$(new_repo)"
git -C "$d" update-ref refs/remotes/origin/issue-2-x "$(git -C "$d" rev-parse HEAD)"
marker "$d" issue-2-x
live_case "a marker whose REMOTE ref still exists is live"
# Both refs gone, but the PR is OPEN — an open PR outranks branch absence, because the branch may
# have been tidied while the run is still going.
d="$(new_repo)"; marker "$d" issue-3-x "https://github.com/o/r/pull/3"
live_case "both refs gone but the PR is OPEN → still live" SHIM_PR_STATE=open

# ================= 5. what counts as STALE (and is therefore cleared) ==========================
d="$(new_repo)"; marker "$d" issue-4-x "https://github.com/o/r/pull/4"
printf 'old\n' > "$d/.claude/state/gaps.md"
printf 'old\n' > "$d/.claude/state/review-codex.err"
printf '{}\n'  > "$d/.claude/state/implement-issue-blocked.json"
printf 'old\n' > "$d/.claude/state/issue-4.json"
printf 'NONE\n' > "$d/.claude/state/issue-4.assoc"
# A name state-scan classifies `other`, which this clear must therefore LEAVE ALONE. The state
# directory is shared — `/new-release` keeps `new-release.json` there, `/resolve-pr-threads` keeps
# `threads-<N>.json` — and `issue-` is a prefix any future skill might pick, so a bare `issue-*`
# glob would have /implement-issue's preflight silently delete a neighbour's file. Containment is
# satisfied by equality; this pins the side of it that can destroy data.
printf 'keepme\n' > "$d/.claude/state/issue-cache.json"
printf 'keepme\n' > "$d/.claude/state/issue-notanumber.json"
admit "$d" SHIM_PR_STATE=merged
eq "$AD_RC" "0" "5 both refs gone and the PR MERGED → the previous run is finished, so admit"
if exists "$d/.claude/state/implement-issue-active.json"; then bad "5 …and its marker is cleared"; else ok; fi
if exists "$d/.claude/state/implement-issue-blocked.json"; then bad "5 …and its blocked marker with it"; else ok; fi
if exists "$d/.claude/state/gaps.md"; then bad "5 …and its gap findings"; else ok; fi
if exists "$d/.claude/state/review-codex.err"; then bad "5 …and its per-slot review stream"; else ok; fi
if exists "$d/.claude/state/issue-4.json"; then bad "5 …and the issue snapshot it fetched (#250)"; else ok; fi
if exists "$d/.claude/state/issue-4.assoc"; then bad "5 …and the provenance label beside it"; else ok; fi
if exists "$d/.claude/state/issue-notanumber.json"; then ok; else
  bad "5 …but NOT a snapshot-shaped name the scan arm does not claim — that is another workflow's file"; fi
if exists "$d/.claude/state/issue-cache.json"; then ok; else
  bad "5 …nor a plausible neighbouring skill's cache under the same prefix"; fi
# A run that never opened a PR and whose branch is gone is equally finished.
d="$(new_repo)"; marker "$d" issue-5-x
admit "$d"; eq "$AD_RC" "0" "5 no PR was ever recorded and both refs are gone → finished, so admit"

# ================= 6. every unknown REFUSES, and refusing never deletes ========================
# A `gh` that errors cannot establish the PR state, so the marker cannot be proven dead.
d="$(new_repo)"; marker "$d" issue-6-x "https://github.com/o/r/pull/6"
printf 'keepme\n' > "$d/.claude/state/gaps.md"
before="$(state_digest "$d")"
admit "$d" SHIM_PR_VIEW_FAIL=1
eq "$AD_RC" "10" "6 a PR state that cannot be READ fails closed to live"
eq "$(state_digest "$d")" "$before" "6 …and nothing was deleted on that path"
# No `gh` at all is the same answer for the same reason.
d="$(new_repo)"; marker "$d" issue-7-x "https://github.com/o/r/pull/7"
AD_OUT="$( cd "$d" && PATH="$nogh" "$BASH" "$IL" admit .claude/state 2>&1 )"; AD_RC=$?
eq "$AD_RC" "10" "6 no gh on PATH is 'unknown', never 'no PR'"
# A marker that is not JSON at all.
d="$(new_repo)"; printf 'not json' > "$d/.claude/state/implement-issue-active.json"
printf 'keepme\n' > "$d/.claude/state/gaps.md"
before="$(state_digest "$d")"
admit "$d"
eq "$AD_RC" "11" "6 an unreadable marker refuses with its own code"
eq "$(state_digest "$d")" "$before" "6 …and deletes nothing, because its identity cannot be established"
has "$AD_OUT" "could not be read" "6 …and says so, rather than sending the operator to look for a live run"
# A `.branch` carrying a control character is not a branch name, and cleanup-lib's one reader
# refuses it — so this lands on the same unreadable path rather than being normalised into a
# well-formed-looking name that no ref matches (which would classify STALE and delete).
d="$(new_repo)"
printf '{"branch":"dead\\u0000branch","issue":"9","phase":"branched"}' > "$d/.claude/state/implement-issue-active.json"
printf 'keepme\n' > "$d/.claude/state/gaps.md"
before="$(state_digest "$d")"
admit "$d"
eq "$AD_RC" "11" "6 a .branch holding a control character is unreadable, not a stale run"
eq "$(state_digest "$d")" "$before" "6 …and nothing was deleted on that path either"
# No jq: nothing can be read, so nothing may be deleted.
d="$(new_repo)"; marker "$d" issue-8-x
printf 'keepme\n' > "$d/.claude/state/gaps.md"
before="$(state_digest "$d")"
AD_OUT="$( cd "$d" && PATH="$nojq" "$BASH" "$IL" admit .claude/state 2>&1 )"; AD_RC=$?
eq "$AD_RC" "12" "6 no jq → refuse; a starter that cannot read must not delete"
eq "$(state_digest "$d")" "$before" "6 …and it did not"
# Outside a git repository the refs are UNKNOWN, not absent. Collapsing those would read a live
# marker as a dead run — two absent refs plus no PR is exactly the verdict that authorizes deletion.
d="$work/notarepo"; mkdir -p "$d/.claude/state"
marker "$d" issue-10-x
before="$(state_digest "$d")"
admit "$d"
eq "$AD_RC" "10" "6 outside a git repo the refs are unknown, so the marker is not provably stale"
eq "$(state_digest "$d")" "$before" "6 …and it survives"

# ================= 7. the lease is what makes a stranded claim recoverable =====================
d="$(new_repo)"; expired_claim "$d"
admit "$d"
eq "$AD_RC" "0" "7 an expired claim is BROKEN, not refused forever"
has "$AD_OUT" "EXPIRED run claim" "7 …reporting the break rather than taking it silently"
# A pre-#202 lock is an empty file with no lease. It must not block the checkout permanently: the
# old behaviour for it was an unconditional clear, so breaking it is the migration path.
d="$(new_repo)"; : > "$d/.claude/state/gap-analysis.lock"
admit "$d"
eq "$AD_RC" "0" "7 a legacy lock with no lease is broken, not treated as an eternal claim"
has "$AD_OUT" "no readable lease" "7 …and named as such, so the operator sees a migration not a race"
# An UNEXPIRED claim is never broken — that is the whole guarantee.
d="$(new_repo)"; admit "$d"; admit "$d"
eq "$AD_RC" "13" "7 an unexpired claim is refused, never broken"

# ================= 7b. the marker is re-verified AT the delete =================================
# Step 1's verdict describes the marker as it was READ; the acquire sits between that read and the
# clear. Holding the claim keeps the window small — a competing run cannot get past admit — but the
# failure it would cause is precisely the one this module exists to prevent, so the file is proven
# to still be the one that was judged. Driven by a `gh` stub that REPLACES the marker mid-read,
# which is the only way to land inside that window deterministically.
d="$(new_repo)"; marker "$d" issue-12-x "https://github.com/o/r/pull/12"
cat > "$shimbin/gh" <<SH
#!/usr/bin/env bash
# Simulate another run replacing the marker while this admit is asking about the PR.
jq -n '{branch:"issue-12-x", issue:"12", phase:"branched", startedAt:"later"}' \\
  > "$d/.claude/state/implement-issue-active.json"
printf 'merged\n'
SH
chmod +x "$shimbin/gh"
admit "$d"
eq "$AD_RC" "10" "7b a marker replaced between the verdict and the delete is NOT cleared"
if exists "$d/.claude/state/implement-issue-active.json"; then ok; else
  bad "7b …the replacement marker survives, because it belongs to a different run"
fi
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "7b …and the claim taken on the way there is released, not stranded"
else ok; fi
# Restore the ordinary shim for the cases below.
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_STATE:-}" ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"

# ================= 7c. a marker that APPEARS mid-admission is not this run's to delete =========
# The mirror of 7b, and the easy one to miss: with NO marker at step 1 there is no identity to
# compare, yet the clear deletes the marker path unconditionally, so a marker written in between
# would be destroyed by a run that never judged it. `admit` guards it with an absence re-check.
#
# NOT COVERED BY A DETERMINISTIC CASE HERE, and saying so is better than a test that pretends.
# 7b can be driven exactly because a marker with a `prUrl` makes `admit` call `gh`, which the shim
# controls — that is a whole subprocess of window to plant a replacement in. The absence path calls
# NOTHING external between the marker read and the clear (no marker means no branch read, no ref
# lookup, no `gh`), so the window is a few instructions wide and a shell harness cannot land in it
# reliably. A best-effort racer was written and discarded: it passed whether or not it won, which
# is a test asserting nothing.
#
# What IS pinned deterministically is the guard's other half — that a marker present at step 1 and
# changed by the clear is refused (7b) — and the same `_il_drop`/return-10 path serves both. The
# residual is named in implement-lib.sh's own comment rather than claimed closed.

# ================= 8. ownership does NOT authorize deletion ====================================
# A session is an ACTOR, not a run: ownership is transferable, one session can invoke the workflow
# twice, and an absent owner reads as "compatible". So `admit` must not consult it — a live marker
# refuses the SAME session that wrote it. Getting this wrong lets one session delete its own live
# run's state and call it a resume.
d="$(new_repo)"; git -C "$d" branch issue-11-x
jq -n '{branch:"issue-11-x", issue:"11", phase:"branched", owner:"sess-A"}' \
   > "$d/.claude/state/implement-issue-active.json"
before="$(state_digest "$d")"
admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
eq "$AD_RC" "10" "8 a live marker refuses even the session that OWNS it — staleness decides, not ownership"
eq "$(state_digest "$d")" "$before" "8 …and its state is untouched"

# ================= 9. a clear that cannot finish must not report a clean start =================
d="$(new_repo)"; printf 'x\n' > "$d/.claude/state/review.md"
chmod 500 "$d/.claude/state"
admit "$d"
chmod 700 "$d/.claude/state"
eq "$AD_RC" "14" "9 an unwritable state dir REFUSES instead of starting over artifacts it did not clear"
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "9 …and leaves no claim behind, so the checkout is not blocked by a run that never started"
else ok; fi

# ================= 10. release ==================================================================
d="$(new_repo)"; admit "$d"
( cd "$d" && bash "$IL" release .claude/state ); eq "$?" "0" "10 release drops the claim"
if exists "$d/.claude/state/gap-analysis.lock"; then bad "10 …and it is really gone"; else ok; fi
( cd "$d" && bash "$IL" release .claude/state ); eq "$?" "0" \
   "10 …and is idempotent, because every caller is a stop path already reporting something else"
# Release must not touch anything else: a stop path still owes /cleanup the artifacts to sweep.
d="$(new_repo)"; admit "$d"; printf 'f\n' > "$d/.claude/state/gaps.md"
( cd "$d" && bash "$IL" release .claude/state )
if exists "$d/.claude/state/gaps.md"; then ok; else bad "10 release must drop only the claim, not the findings"; fi

# ================= 12. REAL concurrency, not two sequential calls ==============================
# The sequential case in section 2 proves only that a COMPLETED, unexpired claim blocks a later
# call — which a plain check-then-act acquire also satisfies. What has to be true is that N
# processes starting against the SAME EMPTY directory produce exactly one winner.
#
# WHAT THIS DOES AND DOES NOT OBSERVE, because a test that overstates its reach is the thing this
# suite exists to prevent elsewhere. The empty-directory race is caught by create-or-fail alone, so
# it does NOT by itself distinguish `link`-a-complete-file from create-then-write; the window in
# which a create-then-write claim exists but is empty is a few instructions wide and is not
# reliably reachable from a shell harness. The EXPIRED-claim race below is what actually fails
# under both regressions — reverted to `set -C` + `>` it produced two winners, and reverted to an
# `rm -f` break it produced two winners — because there a contender is already reading the file's
# contents to decide whether to break it. The complete-payload assertion after this case pins the
# structural property directly.
# A START BARRIER, not just N background jobs. Without one the workers are staggered by however long
# bash takes to fork each of them, which is comfortably longer than the window under test, and the
# race degenerates into N sequential calls. Every worker spins until the gate file appears, so they
# enter the acquire together.
race_winners() {   # <state-dir> <n>  -> prints the number of admits that returned 0
  local sd="$1" n="$2" i wins=0
  local rdir="$sd/.race"; rm -rf "$rdir"; mkdir -p "$rdir"
  for (( i = 0; i < n; i++ )); do
    ( while [ ! -e "$rdir/go" ]; do :; done
      cd "$sd/.." >/dev/null 2>&1 || exit 1
      if bash "$IL" admit "$sd" >"$rdir/out.$i" 2>&1; then : > "$rdir/win.$i"; fi ) &
  done
  : > "$rdir/go"
  wait
  for i in "$rdir"/win.*; do [ -e "$i" ] && wins=$((wins + 1)); done
  rm -rf "$rdir"
  printf '%s' "$wins"
}
d="$(new_repo)"
eq "$(race_winners "$d/.claude/state" 12)" "1" \
   "12 twelve simultaneous admits against an EMPTY state dir produce exactly ONE winner"
eq "$(jq -r 'if (.token|type)=="string" and (.token|length) > 0 then "ok" else "bad" end' \
      "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "ok" \
   "12 …and the surviving claim is complete, never a half-written file another run could break"

# The same contest over an EXPIRED claim, where the property is SAFETY and the assertion says so.
#
# At most one winner is the invariant: two runs proceeding is the bug, and `rm -f` + re-create
# produced exactly that (2-3 winners, reproducibly). Breaking is a rename whose operand is verified,
# plus a re-read of our own token after acquiring — together those make two winners unobservable.
#
# WHAT MAKES THIS DETERMINISTIC. Admission runs inside a `mkdir` lock, so the whole
# read-judge-break-acquire-clear sequence is single-threaded per state directory: one contender
# takes the lock and admits, every other is refused outright without touching anything. That is why
# the assertion is EXACTLY one and holds under load — an earlier design, which tried to make each
# individual step safe, could not say that. Its losing breaker moved the claim before it could know
# whose it was, and a third contender acquired in the few syscalls while the path was free; macOS CI
# found two winners.
d="$(new_repo)"
eq "$(race_winners "$d/.claude/state" 12)" "1" \
   "12 twelve simultaneous admits against an EMPTY state dir produce exactly ONE winner"
eq "$(jq -r 'if (.token|type)=="string" and (.token|length) > 0 then "ok" else "bad" end' \
      "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "ok" \
   "12 …and the surviving claim is complete, never a half-written file another run could break"

# The same contest over an EXPIRED claim, which is the one that used to produce 2-3 winners: two
# breakers both unlinking and both re-creating, then — after that was made a verified rename — a
# third contender slipping into the window a losing breaker opens.
d="$(new_repo)"; expired_claim "$d"
eq "$(race_winners "$d/.claude/state" 12)" "1" \
   "12 twelve simultaneous breakers of one EXPIRED claim also produce exactly ONE winner"

# THE LOCK IS RELEASED ON EVERY PATH, or the second run in any checkout would be refused forever.
# Driven across a refusal (a live marker) as well as a success, because a `return` that skips the
# unlock is exactly the shape that would only show up on the error path.
d="$(new_repo)"; git -C "$d" branch issue-20-x; marker "$d" issue-20-x
admit "$d"; eq "$AD_RC" "10" "12 a refused admission still happens"
if [ -d "$d/.claude/state/.admit.lock" ]; then
  bad "12 …and releases the admission lock on the way out"
else ok; fi
rm -f "$d/.claude/state/implement-issue-active.json"
admit "$d"; eq "$AD_RC" "0" "12 …so the next admission in that directory is not blocked"
if [ -d "$d/.claude/state/.admit.lock" ]; then
  bad "12 …and the successful path releases it too"
else ok; fi

# An ABANDONED lock (a killed admission) is broken on age, so it cannot block a checkout forever —
# the same permanent-block failure the claim's lease exists to prevent. Backdated rather than waited
# for; the threshold is 5 minutes and no admission takes that long.
d="$(new_repo)"
mkdir -p "$d/.claude/state/.admit.lock"
touch -t 202001010000 "$d/.claude/state/.admit.lock"
admit "$d"
eq "$AD_RC" "0" "12 an abandoned admission lock is broken on age, not honoured forever"
has "$AD_OUT" "abandoned admission lock" "12 …and the break is reported, not silent"
# A FRESH one is honoured, or the age rule would be no rule at all.
d="$(new_repo)"; mkdir -p "$d/.claude/state/.admit.lock"
admit "$d"
eq "$AD_RC" "13" "12 …while a fresh lock is honoured"
rm -rf "$d/.claude/state/.admit.lock"

# ================= 13. release drops only what THIS run holds ==================================
# An unconditional `rm` was a real hole: if this run's lease expires and another run legitimately
# breaks and re-takes the claim, this run's later stop path deletes the SUCCESSOR's claim and a
# third run walks in behind it.
d="$(new_repo)"; admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
eq "$AD_RC" "0" "13 run A takes the claim"
tokA="$(jq -r .token "$d/.claude/state/gap-analysis.lock")"
# B takes over (as it would after an expiry break).
jq -n --arg t "tok-B" '{startedAt:1, expiresAt:9999999999, token:$t, owner:"sess-B"}' \
   > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" release --token "$tokA" .claude/state ) >/dev/null 2>&1
if exists "$d/.claude/state/gap-analysis.lock"; then ok; else
  bad "13 …and A's release must NOT delete B's claim (token mismatch)"
fi
eq "$(jq -r .token "$d/.claude/state/gap-analysis.lock")" "tok-B" "13 …B's claim is untouched"
# Without a token, the session id answers the same question for the case that matters: a DIFFERENT
# session took over.
( cd "$d" && env CLAUDE_CODE_SESSION_ID=sess-A bash "$IL" release .claude/state ) >/dev/null 2>&1
if exists "$d/.claude/state/gap-analysis.lock"; then ok; else
  bad "13 …and the tokenless form falls back to the session id, which also refuses B's claim"
fi
# And it still releases what it really does hold.
( cd "$d" && env CLAUDE_CODE_SESSION_ID=sess-B bash "$IL" release .claude/state ) >/dev/null 2>&1
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "13 …while B's own release DOES drop it"
else ok; fi

# WHAT THE TOKENLESS FORM CANNOT DO, pinned as the limit it is rather than left to be discovered.
# `release` is a FRESH PROCESS: it has no memory of the claim its run took, so the only thing it can
# compare is what the file says. A successor written by a DIFFERENT session is caught by the owner
# fallback (above). A successor whose claim carries the SAME owner, or no owner at all, is
# genuinely indistinguishable from the caller's own claim — and is therefore released.
#
# That is not a defect to route around in the library; it is why the WORKFLOW passes `--token`, and
# why the pin below asserts it does. Recording the limit here keeps a future reader from "fixing"
# the fallback into refusing, which would strand a claim on every stop path for any harness that
# exposes no session id.
d="$(new_repo)"; admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
jq -n '{startedAt:1, expiresAt:9999999999, token:"tok-successor", owner:"sess-A"}' \
   > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && env CLAUDE_CODE_SESSION_ID=sess-A bash "$IL" release .claude/state ) >/dev/null 2>&1
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "13 a same-owner successor is NOT distinguishable tokenlessly — if this now passes, the fallback changed and the limit note above is stale"
else ok; fi
# …and the token IS what tells them apart, on exactly that fixture.
d="$(new_repo)"; admit "$d" CLAUDE_CODE_SESSION_ID=sess-A
mine="$(jq -r .token "$d/.claude/state/gap-analysis.lock")"
jq -n '{startedAt:1, expiresAt:9999999999, token:"tok-successor", owner:"sess-A"}' \
   > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && env CLAUDE_CODE_SESSION_ID=sess-A bash "$IL" release --token "$mine" .claude/state ) >/dev/null 2>&1
eq "$(jq -r .token "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "tok-successor" \
   "13 …while --token distinguishes them on the SAME fixture, which is why the workflow passes it"

# THE CALL SITES, pinned. A token the workflow never threads is a token that protects nothing, and
# that was the review's finding: `admit` printed one and every release ignored it.
WF="$ROOT/base/workflows/implement-issue.md"
if [ ! -f "$WF" ]; then
  bad "13 base/workflows/implement-issue.md not found — the call-site pin asserted NOTHING"
else
  wfexec="${ awk '/^```bash$/ { inb = 1; next } /^```$/ { inb = 0; next } inb' "$WF" \
             | sed 's/[[:space:]]*#.*$//'; }"
  has "$wfexec" 'ADMIT_OUT="$({{IMPLEMENT_LIB}} admit {{STATE_DIR}})"' \
     "13 the workflow captures admit's stdout, not just its status"
  # Matched against the RAW workflow, not the comment-stripped copy: `${ADMIT_OUT##* }` contains
  # `##`, and the `sed 's/#.*$//'` that strips shell comments eats the parameter expansion with it.
  # The pin was observed failing for exactly that reason, on a workflow that had the line.
  has "$(cat "$WF")" 'RUN_CLAIM_TOKEN="${ADMIT_OUT##* }"' "13 …and extracts the token from it"
  # The token must survive a BLOCK BOUNDARY, not just the block that captured it: the releases sit in
  # later fenced blocks, which this workflow itself says may run as separate shells. A shell variable
  # alone therefore degrades every call to `release --token ""`. The block must PRINT the token, and
  # the prose must tell the agent to substitute the literal.
  has "$(cat "$WF")" 'echo "RUN_CLAIM_TOKEN=$RUN_CLAIM_TOKEN"' \
     "13 …and PRINTS it, so it survives a block boundary the shell variable does not"
  has "$(cat "$WF")" 'substitute its LITERAL value into every' \
     "13 …and says to substitute the literal, since the agent is what carries it between blocks"
  # A failed `git switch -c` never started a run, so it must RELEASE — holding the claim there
  # refuses every later run for the rest of the lease over an invocation that did nothing.
  ii5b="${ awk '/^### 5\. /{ inb = 1; next } inb && /^### /{ exit } inb' "$WF"; }"
  has "$ii5b" 'git switch -c "$BRANCH" || {
  {{IMPLEMENT_LIB}} release --token "$RUN_CLAIM_TOKEN" {{STATE_DIR}}' \
     "13 …and a failed branch creation releases the claim rather than stranding it"
  nrel="${ printf '%s\n' "$wfexec" | grep -c '{{IMPLEMENT_LIB}} release'; }"
  ntok="${ printf '%s\n' "$wfexec" | grep -c '{{IMPLEMENT_LIB}} release --token "\$RUN_CLAIM_TOKEN"'; }"
  eq "$ntok" "$nrel" "13 …and EVERY release site passes it ($ntok of $nrel)"
  case "$nrel" in 0) bad "13 …but no release site was found at all, so that count proved nothing" ;; *) ok ;; esac
fi

# ================= 14. lease validation is an ERROR, never a silent default ====================
# A lease the operator believes they set and did not is the quiet disagreement this validation
# exists to remove — and one of these values used to be an arithmetic ERROR that still admitted.
for badlease in 0 30 abc -5 08x 12345678901234567890; do
  d="$(new_repo)"
  admit "$d" "ADB_RUN_CLAIM_LEASE_SECS=$badlease"
  eq "$AD_RC" "12" "14 an invalid lease '$badlease' is refused, not silently defaulted"
  if exists "$d/.claude/state/gap-analysis.lock"; then
    bad "14 …and no claim is taken on that path ('$badlease')"
  else ok; fi
done
# UNSET AND EMPTY BOTH MEAN "use the default", which is the shell's own convention for an override
# and what `VAR=` in a wrapper means. Pinned because the module's docs used to claim that anything
# not matching the grammar errors, which was false for the empty string.
d="$(new_repo)"; admit "$d" ADB_RUN_CLAIM_LEASE_SECS=
eq "$AD_RC" "0" "14 an EMPTY override means 'use the default', not 'invalid'"
eq "$(jq -r 'if (.expiresAt - .startedAt) == 9000 then "9000" else "other" end' \
      "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "9000" \
   "14 …and the default really is 9000s, which is what every doc says"
# A zero-PADDED value is decimal, not octal: `08` used to be an arithmetic error.
d="$(new_repo)"; admit "$d" ADB_RUN_CLAIM_LEASE_SECS=0090
eq "$AD_RC" "0" "14 a zero-padded lease is read as decimal, not octal"
# An expiry too large to compare safely reads as NO readable lease, so it is broken with a note
# rather than trusted into the far future (or wrapped into the past).
d="$(new_repo)"
jq -n '{startedAt:1, expiresAt:999999999999999999999, token:"t"}' > "$d/.claude/state/gap-analysis.lock"
admit "$d"
eq "$AD_RC" "0" "14 an out-of-range expiresAt is not trusted as a valid lease"
has "$AD_OUT" "no readable lease" "14 …it is reported as unreadable and broken"

# ================= 15. a write-only state directory cannot be enumerated ======================
# Mode `wx` — writable and searchable, NOT readable. Every FIXED path can still be created and
# unlinked while glob expansion enumerates nothing, so `_il_clear` used to delete the names it knew,
# return success, and report a clean start over a `review-slot.md` it never saw. Reproduced at 300.
d="$(new_repo)"
: > "$d/.claude/state/review-slot.md"
chmod 300 "$d/.claude/state"
admit "$d"
chmod 700 "$d/.claude/state"
eq "$AD_RC" "14" "15 an unreadable state dir REFUSES rather than clearing what it cannot enumerate"
if exists "$d/.claude/state/review-slot.md"; then ok; else
  bad "15 …and the file it could not see is still there, not silently half-cleared"
fi
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "15 …and no claim was taken, so the checkout is not left blocked"
else ok; fi

# ================= 16. a DANGLING SYMLINK at the claim path ====================================
# `-e` follows a symlink, so a dangling one reads as ABSENT while still occupying the path and still
# making `ln` fail with EEXIST. Admission therefore reported "not writable" (14) and never reached
# the break path — and every retry repeated it, so the checkout was blocked until someone removed
# the link by hand. `release` had the same `-e`-only early return.
d="$(new_repo)"
ln -s /nonexistent/target "$d/.claude/state/gap-analysis.lock"
admit "$d"
eq "$AD_RC" "0" "16 a dangling-symlink claim is reaped, not reported as an unwritable directory"
has "$AD_OUT" "no readable lease" "16 …and reported as the corrupt claim it is"
if [ -L "$d/.claude/state/gap-analysis.lock" ]; then
  bad "16 …and the link itself is gone, replaced by a real claim"
else ok; fi
eq "$(jq -r 'if (.token|type)=="string" then "ok" else "bad" end' \
      "$d/.claude/state/gap-analysis.lock" 2>/dev/null)" "ok" "16 …which is a well-formed claim"
# NOTHING on stderr but the NOTE: a failed `< "$file"` is reported by the SHELL, not by `cksum`, so
# a `cksum … 2>/dev/null` left a stray "No such file or directory" whenever the claim was dangling.
eq "$(printf '%s\n' "$AD_OUT" | grep -c 'No such file or directory')" "0" \
   "16 …with no stray shell error leaking from the identity read"
# `release` must see it too, or a dangling link left by a crash would survive every stop path.
d="$(new_repo)"
ln -s /nonexistent/target "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" release .claude/state ) >/dev/null 2>&1
if [ -L "$d/.claude/state/gap-analysis.lock" ]; then
  bad "16 release also removes a dangling-symlink claim rather than returning early on -e"
else ok; fi

# ================= 11. argument handling ========================================================
bash "$IL" >/dev/null 2>&1;                 eq "$?" "2" "11 no subcommand is a usage error"
bash "$IL" bogus x >/dev/null 2>&1;         eq "$?" "2" "11 an unknown subcommand is a usage error"
bash "$IL" admit >/dev/null 2>&1;           eq "$?" "2" "11 admit needs its state-dir argument"
bash "$IL" admit a b >/dev/null 2>&1;       eq "$?" "2" "11 …exactly one of them"
bash "$IL" release >/dev/null 2>&1;         eq "$?" "2" "11 release needs its state-dir argument"
bash "$IL" --help >/dev/null 2>&1;          eq "$?" "0" "11 --help is not an error"

check_summary "check-implement-lib"
