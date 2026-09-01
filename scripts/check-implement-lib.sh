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
write_gh_shim() {
cat > "$shimbin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    # open-pr reads the closing-link set through the same verb the marker path reads state through,
    # and the adopt-on-rerun read asks for the url by branch.
    case "$*" in
      *closingIssuesReferences*) printf '%s\n' "${SHIM_CLOSING_JSON:-}"; exit 0 ;;
      *--json\ url,state*)
        if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
        printf '{"url":"%s","state":"%s"}\n' "${SHIM_PR_URL:-https://github.com/o/r/pull/1}" "${SHIM_ADOPT_STATE:-OPEN}"; exit 0 ;;
    esac
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_STATE:-}" ;;
  "issue view")
    if [ "${SHIM_ISSUE_FAIL:-0}" = "1" ]; then echo "gh: issue not found" >&2; exit 1; fi
    printf '%s\n' "${SHIM_ISSUE_JSON:-}" ;;
  "api repos/{owner}/{repo}/issues/7")
    printf '%s\n' "${SHIM_ASSOC:-OWNER}" ;;
  "repo view")
    printf '%s\n' "${SHIM_SLUG:-o/r}" ;;
  "pr create")
    if [ "${SHIM_CREATE_FAIL:-0}" = "1" ]; then echo "a pull request for branch already exists" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_URL:-https://github.com/o/r/pull/1}" ;;
  "pr list")
    printf '' ;;
  "pr merge")
    exit "${SHIM_MERGE_RC:-1}" ;;
  *) echo "gh-shim: unhandled args: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$shimbin/gh"
}
write_gh_shim
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
# Below-default values (8999, 90) are refused too: the default IS the pre-marker retry budget
# (2x1500 survey + 2x2700 gap + 600 margin), so a shorter lease provably expires under a live
# run and a concurrent admission then clears its state. The override may only lengthen.
for badlease in 0 30 90 8999 abc -5 08x 12345678901234567890; do
  d="$(new_repo)"
  admit "$d" "ADB_RUN_CLAIM_LEASE_SECS=$badlease"
  eq "$AD_RC" "12" "14 an invalid lease '$badlease' is refused, not silently defaulted"
  has "$AD_OUT" "between 9000" "14 …and the message names the real floor ('$badlease')"
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
d="$(new_repo)"; admit "$d" ADB_RUN_CLAIM_LEASE_SECS=0009000
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

# ================= 17. sync-default (#433) ======================================================
# The mid-suite fixtures above overwrite the gh shim with narrower ones; restore the full shim
# for everything from here on.
write_gh_shim
# The preflight sync as code: refuses where work could be lost, fast-forwards where provably safe.
remote_pair() {   # prints "<origin-bare> <clone>"
  local bare clone
  bare="$(mktemp -d "$work/o.XXXXXX")"; clone="$(mktemp -d "$work/c.XXXXXX")"
  {
    git init -q --bare --initial-branch=main "$bare"
    git clone -q "$bare" "$clone/r"
    git -C "$clone/r" config user.email t@example.com
    git -C "$clone/r" config user.name  t
    : > "$clone/r/seed"; git -C "$clone/r" add seed; git -C "$clone/r" commit -qm seed
    git -C "$clone/r" push -q origin main
  } >/dev/null 2>&1
  printf '%s %s' "$bare" "$clone/r"
}
read -r _ CLONE <<EOF
${ remote_pair; }
EOF
sync() { ( cd "$1" && bash "$IL" sync-default 2>&1 ); SY_RC=$?; }
: > "$CLONE/dirty"; SY_OUT="${ sync "$CLONE"; }"
eq "$SY_RC" "30" "17 a dirty tree is refused (30), never repaired"
rm -f "$CLONE/dirty"
( cd "$CLONE" && git commit -q --allow-empty -m local ) >/dev/null 2>&1
SY_OUT="${ sync "$CLONE"; }"
eq "$SY_RC" "31" "17 local commits on the default branch are refused (31)"
( cd "$CLONE" && git push -q origin main ) >/dev/null 2>&1
( cd "$CLONE" && git switch -q -c issue-9-x && git commit -q --allow-empty -m wip ) >/dev/null 2>&1
SY_OUT="${ sync "$CLONE"; }"
eq "$SY_RC" "32" "17 an unmerged branch is refused (32) — never switched away from"
eq "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" "issue-9-x" "17 …and HEAD is untouched"
( cd "$CLONE" && git switch -q main && git merge -q --ff-only issue-9-x && git push -q origin main && git switch -q issue-9-x ) >/dev/null 2>&1
SY_OUT="${ sync "$CLONE"; }"
eq "$SY_RC" "0" "17 a provably merged branch is switched away from (0)"
eq "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" "main" "17 …landing on the default branch"
has "$SY_OUT" "synced main at" "17 …and the record line names the branch and sha"
# STDOUT IS THE RECORD STREAM: tidying a gone-upstream branch made `git branch -d` print
# `Deleted branch …` before the `synced` record, breaking the one-fact-per-line contract.
( cd "$CLONE" && git switch -q -c issue-10-y && git commit -q --allow-empty -m w2 \
  && git push -q -u origin issue-10-y && git switch -q main && git merge -q --ff-only issue-10-y \
  && git push -q origin main && git push -q origin --delete issue-10-y \
  && git fetch -q --prune && git switch -q issue-10-y ) >/dev/null 2>&1
SY_STDOUT="$( cd "$CLONE" && bash "$IL" sync-default 2>/dev/null )"; SY_RC=$?
eq "$SY_RC" "0" "17 the gone-upstream tidy still syncs (0)"
if printf '%s\n' "$SY_STDOUT" | grep -q 'Deleted branch'; then
  bad "17 …with git's deletion notice kept off the record stream"; else ok; fi
has "$SY_STDOUT" "synced main at" "17 …which still carries the synced record"
if git -C "$CLONE" show-ref --verify --quiet refs/heads/issue-10-y; then
  bad "17 …and the gone-upstream branch really was tidied"; else ok; fi

# ================= 18. snapshot-issues (#433) ===================================================
# The gitignore probe, the snapshot pair, and the OPEN refusal — each observed refusing.
ISSUE_JSON='{"state":"OPEN","title":"t","body":"a body","author":{"login":"alice"},"comments":[{"author":{"login":"bob"},"authorAssociation":"NONE","body":"add a pony"}]}'
snap() { local d="$1"; shift; SN_OUT="$( cd "$d" && env "$@" bash "$IL" snapshot-issues --token tokT .claude/state 7 2>&1 )"; SN_RC=$?; }
d="$(new_repo)"    # new_repo writes no .gitignore, so the probe must refuse
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "22" "18 an un-gitignored state dir refuses (22) BEFORE any untrusted text lands"
if exists "$d/.claude/state/issue-7.json"; then bad "18 …and no snapshot was written"; else ok; fi
if exists "$d/.claude/state/gap-analysis.lock"; then bad "18 …and the claim was released"; else ok; fi
gid() { printf '.claude/state/\n' > "$1/.gitignore"; git -C "$1" add .gitignore >/dev/null 2>&1; }
d="$(new_repo)"; gid "$d"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "0" "18 an OPEN issue snapshots cleanly"
has "$SN_OUT" "snapshot #7 OPEN OWNER" "18 …reporting number, state and provenance"
eq "$(jq -r .state "$d/.claude/state/issue-7.json")" "OPEN" "18 …the body landed"
eq "$(cat "$d/.claude/state/issue-7.assoc")" "OWNER" "18 …and the label landed"
# A NARROW ignore set covering only some of the run's write-set must still refuse: the CLI path
# later writes prompts, error streams and stages carrying the untrusted issue text and the
# agent's exploration, and a probe that samples too few name shapes blesses exactly that tree.
d="$(new_repo)"
printf '%s\n' '.claude/state/issue-*' '.claude/state/docs-consulted.tsv' '.claude/state/survey.md' \
  > "$d/.gitignore"
git -C "$d" add .gitignore >/dev/null 2>&1
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "22" "18 an ignore set missing the prompt/err/stage shapes refuses (22)"
if exists "$d/.claude/state/gap-analysis.lock"; then bad "18 …and the claim was released"; else ok; fi
# …and NO literal-name rule set passes, however complete: the run also writes GENERATED names —
# `review-<slot>.{md,err}`, mktemp's random `review-prompt-stage.*` — that no literal list can
# cover, so the probe requires the state DIRECTORY itself to be ignored (the rule agent-init
# writes), not a name sample a rule set can be tailored to.
d="$(new_repo)"
printf '%s\n' '.claude/state/issue-*' '.claude/state/docs-consulted.tsv' \
  '.claude/state/gap-prompt.txt' '.claude/state/gaps.md' '.claude/state/gaps.err' \
  '.claude/state/review-prompt.txt' '.claude/state/review-prompt-stage.probe' \
  '.claude/state/review-0.md' '.claude/state/review-0.err' \
  '.claude/state/survey-prompt.txt' '.claude/state/survey.md' '.claude/state/survey-stage.md' \
  '.claude/state/survey-overflow.md' '.claude/state/survey-trace.md' '.claude/state/survey.err' \
  > "$d/.gitignore"
git -C "$d" add .gitignore >/dev/null 2>&1
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "22" "18 a literal-name rule set (generated names uncoverable) still refuses (22)"
d="$(new_repo)"; gid "$d"
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$(printf '%s' "$ISSUE_JSON" | jq -c '.state = "CLOSED"')"
eq "$SN_RC" "21" "18 a CLOSED issue refuses (21) — never silently reopened"
if exists "$d/.claude/state/gap-analysis.lock"; then bad "18 …and the claim was released on that path too"; else ok; fi
d="$(new_repo)"; gid "$d"
snap "$d" SHIM_ISSUE_FAIL=1
eq "$SN_RC" "20" "18 a failed gh read is 20 (verify repo scope), not a silent pass"
( cd "$d" && bash "$IL" snapshot-issues .claude/state 7x ) >/dev/null 2>&1
eq "$?" "2" "18 a non-numeric issue argument is a usage error"

# ================= 19. dispatch prompts are BUILT CONTAINED (#433/#435) =========================
# --prompt-only exercises assembly without any agent CLI; the envelope is structural.
seed_snap() { printf '%s' "$ISSUE_JSON" > "$1/.claude/state/issue-7.json"; printf 'OWNER' > "$1/.claude/state/issue-7.assoc"; }
d="$(new_repo)"; seed_snap "$d"
OUT="$( cd "$d" && bash "$IL" dispatch-survey --prompt-only .claude/state 7 2>&1 )"; RC=$?
eq "$RC" "0" "19 dispatch-survey --prompt-only builds"
has "$OUT" "prompt-ready" "19 …and says where"
P="$d/.claude/state/survey-prompt.txt"
has "$(cat "$P")" 'github-issue #7' "19 the survey prompt carries the contained issue envelope"
# --prompt-only feeds a NATIVE READ-ONLY subagent (implement-issue.md: the harness transcript is
# the trace, no file is fabricated) — so the trace-file command must be absent on this path only.
if grep -q 'survey-trace.md' "$P"; then
  bad "19 a --prompt-only prompt must NOT command a trace file the read-only subagent cannot write"
else ok; fi
has "$(cat "$P")" 'ONLY the bounded summary' "19 …while the reply is still bound to the summary alone"
has "$(cat "$P")" '1500 words' "19 …and the size bound"
d="$(new_repo)"; seed_snap "$d"; rm "$d/.claude/state/issue-7.assoc"
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "20" "19 a missing provenance label refuses (20) — an unattributed body is never dispatched"
# THE CLAIM IS KEPT: a dispatch fault is "fix and re-run the subcommand" (dispatch-failures.md),
# and the re-run happens under the SAME admission — a release here left the retry unprotected
# against a concurrent admit or /cleanup. Release belongs to step 2, step 4 and the marker
# takeover (state-protocol.md: "released at exactly three places").
if exists "$d/.claude/state/gap-analysis.lock"; then ok; else bad "19 …and the claim is KEPT for the re-run"; fi
d="$(new_repo)"; seed_snap "$d"
printf 'survey says X' > "$d/.claude/state/survey.md"
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
has "$(cat "$d/.claude/state/gap-prompt.txt")" 'survey summary' "19 the gap prompt embeds the survey CONTAINED"
has "$(cat "$d/.claude/state/gap-prompt.txt")" 'BLOCKING' "19 …and the three-heading contract"
dd if=/dev/zero bs=1024 count=32 2>/dev/null | tr '\0' 'x' > "$d/.claude/state/survey.md"
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
has "$(cat "$d/.claude/state/gap-prompt.txt")" 'only the first 16384' "19 an oversize survey is truncated AND says so"
# That fixture is a single NEWLINE-FREE 32 KiB line: the cap must bind on the first record too,
# not only from line 2 on — unbounded, the whole line rode into the prompt past the stated bound.
GP_BYTES="$(wc -c < "$d/.claude/state/gap-prompt.txt" | tr -d ' ')"
if [ "$GP_BYTES" -lt 24576 ]; then ok; else
  bad "19 a newline-free oversize survey must still be capped (gap-prompt.txt is $GP_BYTES bytes)"; fi
# …and a first line crossing the cap MID-CHARACTER is trimmed to a UTF-8 boundary: the JSON
# containment refuses an invalid sequence, so an unlucky cut would fail the whole prompt build.
{ printf '%16383s' '' | tr ' ' 'x'; printf '\303\251\n'; } > "$d/.claude/state/survey.md"
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19 a survey crossing the cap mid-character still builds"
if LC_ALL=C grep -q "$(printf '\303')" "$d/.claude/state/gap-prompt.txt"; then
  bad "19 …with the dangling UTF-8 lead byte trimmed, not emitted"; else ok; fi
# survey = "" is the documented skip (rc 3), decided before any CLI is needed
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = ""\n' > "$d/agents.toml"
OUT="$( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 2>&1 )"; RC=$?
eq "$RC" "3" '19 survey = "" skips with rc 3'
has "$OUT" "survey skipped (unassigned)" "19 …and says so"

# ================= 20. dispatch-review builds diff + criteria (#433) ============================
read -r _ RCLONE <<EOF
${ remote_pair; }
EOF
mkdir -p "$RCLONE/.claude/state"; seed_snap "$RCLONE"
( cd "$RCLONE" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
OUT="$( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; RC=$?
eq "$RC" "0" "20 dispatch-review --prompt-only builds"
RP="$RCLONE/.claude/state/review-prompt.txt"
has "$(cat "$RP")" 'REQUIRED or OPTIONAL' "20 the review prompt carries the required/optional contract"
has "$(cat "$RP")" 'diff --git a/seed' "20 …the real diff against origin/<default>"
has "$(cat "$RP")" 'github-issue #7 — acceptance criteria' "20 …and the contained criteria"
# WORKTREE-INCLUSIVE: the Claude review path dispatches after /simplify may have edited but
# before the next commit, so a committed-range diff hands the reviewer the pre-edit code.
printf 'uncommitted-simplify-edit\n' >> "$RCLONE/seed"
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
has "$(cat "$RP")" 'uncommitted-simplify-edit' "20 …and uncommitted working-tree edits reach the reviewer"
( cd "$RCLONE" && git checkout -q -- seed ) >/dev/null 2>&1   # a fixture file this test appended to; no untracked work at risk
# …UNTRACKED files too: a tree-ish diff shows nothing for a brand-new helper, so a file
# /simplify created before this dispatch would be committed without independent review.
printf 'brand-new-untracked-helper\n' > "$RCLONE/newhelper.txt"
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
has "$(cat "$RP")" 'brand-new-untracked-helper' "20 …and a new untracked file reaches the reviewer"
rm -f "$RCLONE/newhelper.txt"
# An untracked EMBEDDED REPO surfaces as a directory entry `sub/` that --no-index cannot diff
# (exit 1, same as an ordinary differ) — it would land as an unreviewed gitlink, so it refuses.
( cd "$RCLONE" && mkdir -p subrepo && git -C subrepo init -q && printf 'x\n' > subrepo/f ) >/dev/null 2>&1
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 an untracked embedded repo refuses (20), never a silent skip"
rm -rf "$RCLONE/subrepo"
# An UNREADABLE directory makes ls-files warn and exit 0 over a partial listing — accepting it
# publishes a review prompt missing whatever sat beneath, which is then committable unreviewed.
( cd "$RCLONE" && mkdir -p noperm && printf 'hidden\n' > noperm/f && chmod 000 noperm ) >/dev/null 2>&1
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
RK=$?
chmod 755 "$RCLONE/noperm" 2>/dev/null; rm -rf "$RCLONE/noperm"
eq "$RK" "20" "20 an unreadable directory refuses (20) — a partial untracked listing is never accepted"
# A master-default clone WITHOUT origin/HEAD: the narrow inline resolver fell back to a
# nonexistent `main`; the shared adb_default_branch checks local main/master and is the one home.
mrem="$work/master-rem"; git init -q --bare "$mrem"
mcl="$work/master-clone"; git init -q -b master "$mcl"
( cd "$mcl" && printf 'seed\n' > seed && git add seed && git commit -qm seed \
  && git remote add origin "$mrem" && git push -qu origin master ) >/dev/null 2>&1
git -C "$mcl" remote set-head origin -d >/dev/null 2>&1
mkdir -p "$mcl/.claude/state"
MS_OUT="$( cd "$mcl" && bash "$IL" sync-default 2>&1 )"; MS_RC=$?
eq "$MS_RC" "0" "20 a master-default clone without origin/HEAD syncs (0)"
has "$MS_OUT" "synced master at" "20 …naming master via the shared resolver"
( cd "$mcl" && git switch -q -c issue-7-m && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
seed_snap "$mcl"
( cd "$mcl" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "20 …and the review prompt builds against origin/master"
( cd "$RCLONE" && bash "$IL" dispatch-review --slot abc .claude/state codex ) >/dev/null 2>&1
eq "$?" "2" "20 a non-numeric --slot is a usage error (the review-N family grammar)"
if compgen -G "$RCLONE/.claude/state/review-prompt-stage.*" >/dev/null; then
  bad "20 a successful build leaves no prompt temp behind"; else ok; fi
# THE MARKER IS AUTHORITATIVE ONCE IT EXISTS: a malformed .issue must refuse, never silently
# narrow the scope to its parseable half ("7,x" reviewing only #7) or widen it to every stray
# numeric snapshot. The glob fallback is for the PRE-marker window only.
jq -n '{branch:"issue-7-t", issue:"7,x", phase:"committed"}' > "$RCLONE/.claude/state/implement-issue-active.json"
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 a marker .issue with a non-numeric entry refuses (20), never half-reviews"
jq -n '{branch:"issue-7-t", issue:"", phase:"committed"}' > "$RCLONE/.claude/state/implement-issue-active.json"
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 …and an empty marker .issue refuses too, never falls back past the marker"
# …and EMPTY FIELDS refuse: word splitting silently discarded them, so "7," — a marker whose
# second issue was lost to corruption — reviewed only #7 while the contract promises a refusal.
for badissue in '7,' ',7' '7,,8'; do
  jq -n --arg i "$badissue" '{branch:"issue-7-t", issue:$i, phase:"committed"}' > "$RCLONE/.claude/state/implement-issue-active.json"
  ( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
  eq "$?" "20" "20 a marker .issue with an empty field ('$badissue') refuses (20)"
done
rm -f "$RCLONE/.claude/state/implement-issue-active.json"
d="$(new_repo)"
( cd "$d" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 no snapshots -> 20 (run snapshot-issues first), never an empty prompt"
# The prompt is PUBLISHED BY RENAME, never truncated in place: concurrent review slots each
# rebuild this one path, so a truncate-then-append build hands another slot's dispatch a
# half-written prompt — and a build that fails partway used to leave that torn file published.
read -r _ R2 <<EOF
${ remote_pair; }
EOF
mkdir -p "$R2/.claude/state"
printf '%s' "$ISSUE_JSON" > "$R2/.claude/state/issue-7.json"   # no .assoc: the envelope step fails
( cd "$R2" && git switch -q -c issue-7-t && printf 'y\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
( cd "$R2" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 a build failing at the envelope refuses (20)"
if exists "$R2/.claude/state/review-prompt.txt"; then
  bad "20 …and publishes NO torn review-prompt.txt from the failed build"; else ok; fi
if compgen -G "$R2/.claude/state/review-prompt-stage.*" >/dev/null; then
  bad "20 …and leaves no prompt temp behind on the failure path"; else ok; fi

# ================= 21. open-pr: push, prove, guard (#433) =======================================
read -r _ PCLONE <<EOF
${ remote_pair; }
EOF
mkdir -p "$PCLONE/.claude/state"
( cd "$PCLONE" && git switch -q -c issue-9-x && git commit -q --allow-empty -m wip ) >/dev/null 2>&1
jq -n '{branch:"issue-9-x", issue:"9", phase:"triaged", startedAt:"2026-08-30T00:00:00Z",
        phaseHistory:[{phase:"triaged", at:"2026-08-30T00:00:00Z"}]}' \
  > "$PCLONE/.claude/state/implement-issue-active.json"
printf 'body\n\nCloses #9\n' > "$PCLONE/body.md"
GOODREFS='{"closingIssuesReferences":[{"number":9,"repository":{"name":"r","owner":{"login":"o"}}}]}'
openpr() { OP_OUT="$( cd "$PCLONE" && env "$@" bash "$IL" open-pr .claude/state --title t --body-file body.md --closes 9 2>&1 )"; OP_RC=$?; }
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 the happy path exits 0"
has "$OP_OUT" "pushed issue-9-x" "21 …pushed"
has "$OP_OUT" "pr https://github.com/o/r/pull/5" "21 …opened"
has "$OP_OUT" "closing-refs ok [9]" "21 …and PROVED the closing link registered"
has "$OP_OUT" "automerge-ok rc=" "21 …and reported the guard disposition instead of arming blind"
M="$PCLONE/.claude/state/implement-issue-active.json"
eq "$(jq -r .prUrl "$M")" "https://github.com/o/r/pull/5" "21 the marker carries prUrl"
eq "$(jq -r .phase "$M")" "pr_opened" "21 …and phase pr_opened"
eq "$(jq -r '[.phaseHistory[].phase] | join(",")' "$M")" "triaged,pushed,pr_opened" "21 …with the history appended in order"
# RE-RUN IDEMPOTENCE: create fails ("already exists") -> the open PR is adopted and the
# verification still runs, because the 23 arm's own message says to re-run it.
openpr SHIM_SLUG="o/r" SHIM_CREATE_FAIL=1 SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 a re-run with an existing PR adopts it (create failure is not terminal)"
has "$OP_OUT" "closing-refs ok [9]" "21 …and still re-proves the closing links"
# …but ONLY an OPEN one: `gh pr view <branch>` resolves the branch's most recent PR including a
# closed or merged historical one, and adopting that aims every guard below at the wrong PR.
openpr SHIM_SLUG="o/r" SHIM_CREATE_FAIL=1 SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_ADOPT_STATE=MERGED SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "21 create-failure with only a MERGED PR for the branch refuses (25), never adopts"
has "$OP_OUT" "not OPEN" "21 …and names the state it found"
# create fails AND nothing resolves for the branch: the documented rc 25 with the captured create
# failure — never an unbound-variable abort (set -u; `pr` is only assigned when a PR resolves)
openpr SHIM_SLUG="o/r" SHIM_CREATE_FAIL=1 SHIM_PR_VIEW_FAIL=1 SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "21 create-failure with NO resolvable PR refuses (25), not an unbound abort"
has "$OP_OUT" "gh pr create failed" "21 …reporting the captured create failure"
# GitHub's closingIssuesReferences is a CANONICAL numeric set, so the comparison side must be
# too: a duplicate or leading-zero spelling otherwise mismatches forever (23) with the links
# correctly registered.
openpr2() { local cl="$1"; shift; OP_OUT="$( cd "$PCLONE" && env "$@" bash "$IL" open-pr .claude/state --title t --body-file body.md --closes "$cl" 2>&1 )"; OP_RC=$?; }
openpr2 "9,9" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 a duplicated --closes entry canonicalizes and verifies"
openpr2 "009" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 …and a leading-zero spelling compares as its number"
openpr2 "9,x" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "2" "21 a non-numeric --closes entry is a usage error"
openpr2 "0" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "2" "21 …and 0 is not an issue number"
# STDOUT IS THE RECORD STREAM: on a branch's FIRST push, `git push -u` writes its
# upstream-registration message to stdout, which would ride between the closed one-fact-per-line
# records and break any consumer that parses them.
read -r _ P3CLONE <<EOF
${ remote_pair; }
EOF
mkdir -p "$P3CLONE/.claude/state"
( cd "$P3CLONE" && git switch -q -c issue-3-y && git commit -q --allow-empty -m wip ) >/dev/null 2>&1
jq -n '{branch:"issue-3-y", issue:"3", phase:"triaged", startedAt:"2026-08-30T00:00:00Z",
        phaseHistory:[{phase:"triaged", at:"2026-08-30T00:00:00Z"}]}' \
  > "$P3CLONE/.claude/state/implement-issue-active.json"
printf 'body\n\nCloses #3\n' > "$P3CLONE/body.md"
OP_STDOUT="$( cd "$P3CLONE" && env SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/3" \
  SHIM_CLOSING_JSON='{"closingIssuesReferences":[{"number":3,"repository":{"name":"r","owner":{"login":"o"}}}]}' \
  bash "$IL" open-pr .claude/state --title t --body-file body.md --closes 3 2>/dev/null )"
if printf '%s\n' "$OP_STDOUT" | grep -q 'set up to track'; then
  bad "21 a first push must keep git's upstream message off the record stream"; else ok; fi
has "$OP_STDOUT" "pushed issue-3-y" "21 …while the pushed record itself still lands on stdout"

# the closing-link mismatch is a REFUSAL with the fix named, not a note
( cd "$PCLONE" && git commit -q --allow-empty -m more ) >/dev/null 2>&1
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/6" SHIM_CLOSING_JSON='{"closingIssuesReferences":[]}'
eq "$OP_RC" "23" "21 an empty link set refuses (23) — the auto-close would never fire"
has "$OP_OUT" "did NOT register" "21 …and says why"
# a marker/HEAD mismatch never pushes
( cd "$PCLONE" && git switch -q main ) >/dev/null 2>&1
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/7" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "26" "21 HEAD off the marker branch refuses (26) before any push"
( cd "$PCLONE" && git switch -q issue-9-x ) >/dev/null 2>&1
# a blocked marker for THIS run skips the arm entirely
jq -n '{reason:"r", phase:"triaged", branch:"issue-9-x", issue:"9"}' > "$PCLONE/.claude/state/implement-issue-blocked.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 a blocked run still opens its PR"
has "$OP_OUT" "arm-skipped blocked-marker" "21 …but never arms auto-merge"
# …ACROSS AN OWNERSHIP TRANSFER TOO: a resumed session re-stamps the ACTIVE marker's owner while
# the blocked file keeps the owner it copied at write time — branch+issue identify the run, and
# the safe failure direction is withholding the arm, never arming past a matching block.
jq -n '{reason:"r", phase:"triaged", branch:"issue-9-x", issue:"9", owner:"session-elsewhere"}' \
  > "$PCLONE/.claude/state/implement-issue-blocked.json"
openpr CLAUDE_CODE_SESSION_ID=session-here SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 a blocked run resumed by another session still opens its PR"
has "$OP_OUT" "arm-skipped blocked-marker" "21 …and the transferred run's block still withholds the arm"
# A blocked marker that EXISTS but cannot be validated fails CLOSED: a truncated or wrongly
# typed record used to read as "unrelated" and fall through to arming a run its own block marks.
printf '{"bra' > "$PCLONE/.claude/state/implement-issue-blocked.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 an unreadable blocked marker still opens the PR"
has "$OP_OUT" "arm-skipped blocked-marker-unreadable" "21 …but withholds the arm rather than proving the marker unrelated"
rm -f "$PCLONE/.claude/state/implement-issue-blocked.json"

# ================= 19b. the survey is non-blocking: 124 twice, then the run CONTINUES (#435) ====
# The codex CLI is shimmed to die at the backstop code; two consecutive dispatches fail with the
# classified rc, and the gap prompt still builds WITHOUT a survey — the accelerator-not-gate
# contract, exercised end to end rather than stated.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
exit 124
SH
chmod +x "$shimbin/codex"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "codex"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "124" "19b a wedged surveyor returns the classified backstop code"
has "$(cat "$d/.claude/state/survey-prompt.txt")" 'survey-trace.md' "19b …and the CLI-path prompt DOES command the trace file"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "124" "19b …and the retry returns it again (no silent agent swap)"
if [ -s "$d/.claude/state/survey.md" ]; then bad "19b …and no phantom summary was written"; else ok; fi
if exists "$d/.claude/state/survey-stage.md"; then bad "19b …and no staging residue was left behind"; else ok; fi
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19b …and the gap prompt still builds — the run continues without the survey"
if grep -q 'survey summary' "$d/.claude/state/gap-prompt.txt"; then
  bad "19b …with no survey section fabricated"; else ok; fi
rm -f "$shimbin/codex"

# ================= 19c. a clean CLI dispatch PUBLISHES the summary (#435) =======================
# claude, because for that agent stdout IS the final message and passes straight through — the
# publish path under test is the redirect itself, with no last-message protocol in the way.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'surveyed fine\n'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
OUT="$( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 2>&1 )"; RC=$?
eq "$RC" "0" "19c a successful CLI dispatch exits 0"
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "surveyed fine" "19c …and publishes the surveyor's stdout as survey.md"
has "$OUT" "survey ok 2 words" "19c …reporting the word count"
if exists "$d/.claude/state/survey-stage.md"; then bad "19c …with no staging residue"; else ok; fi

# ================= 19f. a malformed role declaration is 18, not an agent error (#435) ===========
# role-dispatch refuses bad config with rc 2 — but the dispatched CLI can also exit 2, so the
# subcommand resolves the role FIRST and translates that refusal to the contract's 18. Left at 2,
# the workflow retries a manifest typo as an "agent error" and then applies the failure policy —
# for survey, continuing as though the optional accelerator merely failed.
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "bogus-agent"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "18" "19f an unknown [roles].survey agent is 18 (fix agents.toml), not a retryable 2"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "bogus-agent"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
eq "$?" "18" "19f …and the same for [roles].gap_analysis"

# ================= 19e. the survey bound ignores the GENERIC timeout override (#435) ============
# The pre-marker lease arithmetic (2x1200 survey + 2x2700 gap < the 9000 s claim lease) holds only
# if ADB_DISPATCH_TIMEOUT_SECS cannot widen the survey's bound; the shim echoes what it was handed.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${ADB_DISPATCH_TIMEOUT_SECS:-unset}"
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_TIMEOUT_SECS=2700 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "1200" "19e the generic override does not widen the survey bound"
( cd "$d" && env ADB_DISPATCH_TIMEOUT_SECS=2700 ADB_SURVEY_TIMEOUT_SECS=900 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "900" "19e …while the survey's own variable still governs"
( cd "$d" && env ADB_SURVEY_TIMEOUT_SECS=0900 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "900" "19e …and a zero-padded value is its number, not the default"
# …and that variable is CLAMPED under the lease share WITH margin: 2 surveys + 2 gap dispatches
# (2700 s each) plus prompt builds, findings reads and kill grace must fit the fixed 9000 s claim,
# so the cap is 1500 (600 s of margin), not the zero-margin 1800.
( cd "$d" && env ADB_SURVEY_TIMEOUT_SECS=5000 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "1500" "19e an override past the lease share is clamped to 1500"
( cd "$d" && env ADB_SURVEY_TIMEOUT_SECS=99999999999999999999 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "1500" "19e …including one too wide for shell arithmetic"
( cd "$d" && env ADB_SURVEY_TIMEOUT_SECS=abc bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "1200" "19e …and a non-numeric value falls to the survey's own 1200, never role-dispatch's 2700"
rm -f "$shimbin/claude"

# ================= 19g. an oversized reply publishes BOUNDED, full copy set aside (#435) ========
# The workflow tells the primary to READ survey.md, so an agent that ignores the word ask — or
# emits one enormous newline-free record — must not land whole in that reader's context.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=32 2>/dev/null | tr '\0' 'y'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19g an oversized reply still completes rc 0"
SV_BYTES="$(wc -c < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
if [ -n "$SV_BYTES" ] && [ "$SV_BYTES" -le 16385 ]; then ok; else
  bad "19g …but survey.md is published BOUNDED (got ${SV_BYTES:-none} bytes)"; fi
eq "$(wc -c < "$d/.claude/state/survey-overflow.md" 2>/dev/null | tr -d ' ')" "32768" \
  "19g …with the full reply kept at survey-overflow.md"
rm -f "$shimbin/claude"

# ================= 19h. the agent-written trace is CAPPED after dispatch (#435) =================
# The CLI surveyor writes survey-trace.md itself, outside role-dispatch's capped streams — so a
# verbose agent could grow it without limit while state-protocol promises bounded run growth.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=8 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md
printf 'traced fine\n'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_LOG_MAX_BYTES=1024 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19h the dispatch still completes rc 0"
TR_BYTES="$(wc -c < "$d/.claude/state/survey-trace.md" 2>/dev/null | tr -d ' ')"
if [ -n "$TR_BYTES" ] && [ "$TR_BYTES" -le 1300 ]; then ok; else
  bad "19h …but the trace is capped at the log bound (got ${TR_BYTES:-none} bytes)"; fi
has "$(cat "$d/.claude/state/survey-trace.md" 2>/dev/null)" 'HEAD cap' "19h …and says the END is the part missing"
# The override mirrors role-dispatch's reading: an all-digit value too wide for shell arithmetic
# falls back to the 262144 default (a bare -gt on it errors and evaluates FALSE — uncapped), and
# 0 disables the cap entirely.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md
printf 'traced fine\n'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_LOG_MAX_BYTES=999999999999999999999999 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
TR_BYTES="$(wc -c < "$d/.claude/state/survey-trace.md" 2>/dev/null | tr -d ' ')"
if [ -n "$TR_BYTES" ] && [ "$TR_BYTES" -le 262500 ]; then ok; else
  bad "19h an over-wide override falls back to the default cap (got ${TR_BYTES:-none} bytes)"; fi
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_LOG_MAX_BYTES=0 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(wc -c < "$d/.claude/state/survey-trace.md" 2>/dev/null | tr -d ' ')" "307200" \
  "19h …and 0 disables the trace cap, as it does role-dispatch's"
rm -f "$shimbin/claude"

# ================= 19i. the NATIVE path publishes through the same bounded publisher (#435) =====
# The driving agent pipes the subagent's reply to publish-survey instead of writing survey.md
# itself — otherwise the 16 KiB publication bound was CLI-only, and a native reply landed whole
# in the primary's context when step 6 read it back.
d="$(new_repo)"
printf 'native survey reply\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ); RC=$?
eq "$RC" "0" "19i a small native reply publishes rc 0"
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "native survey reply" "19i …verbatim"
dd if=/dev/zero bs=1024 count=32 2>/dev/null | tr '\0' 'n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ); RC=$?
eq "$RC" "0" "19i an oversized native reply still publishes rc 0"
SV_BYTES="$(wc -c < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
if [ -n "$SV_BYTES" ] && [ "$SV_BYTES" -le 16385 ]; then ok; else
  bad "19i …but bounded (got ${SV_BYTES:-none} bytes)"; fi
eq "$(wc -c < "$d/.claude/state/survey-overflow.md" 2>/dev/null | tr -d ' ')" "32768" \
  "19i …with the full reply kept at survey-overflow.md"
( bash "$IL" publish-survey ) >/dev/null 2>&1
eq "$?" "2" "19i publish-survey without its state-dir is a usage error"

# ================= 19l. every pre-marker subcommand RENEWS the claim lease (#435) ===============
# The lease used to run from admit alone, so snapshot's unbounded gh reads and the agent's triage
# between dispatches ate the fixed margin — a live run could outlive its claim and be reaped.
# Renewal at each subcommand start makes the lease bound each step and the gap to the next.
renew_exp() { jq -r '.expiresAt' "$1/.claude/state/gap-analysis.lock" 2>/dev/null; }
d="$(new_repo)"; seed_snap "$d"
NOWS="$(date +%s)"
jq -n --argjson e "$((NOWS + 50))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
if [ "$(renew_exp "$d")" -ge "$((NOWS + 8000))" ] 2>/dev/null; then ok; else
  bad "19l dispatch-gaps renews the claim lease (expiresAt stayed $(renew_exp "$d"))"; fi
d="$(new_repo)"; gid "$d"
jq -n --argjson e "$((NOWS + 50))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
if [ "$(renew_exp "$d")" -ge "$((NOWS + 8000))" ] 2>/dev/null; then ok; else
  bad "19l snapshot-issues renews the claim lease too (expiresAt stayed $(renew_exp "$d"))"; fi
# …and a SUCCESSOR'S claim is never renewed: after a reap-and-readmit, the stale run's token no
# longer matches — renewing anyway would rewrite the live run's claim and race its artifacts.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokB"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokA --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l a successor's claim refuses the stale run (13), never renews past it"
eq "$(jq -r .token "$d/.claude/state/gap-analysis.lock")" "tokB" "19l …with the successor's token untouched"
eq "$(renew_exp "$d")" "$((NOWS + 9000))" "19l …and its lease untouched"
d="$(new_repo)"; gid "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokB"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "13" "19l snapshot-issues refuses a successor's claim too (13)"
if exists "$d/.claude/state/issue-7.json"; then bad "19l …and wrote no snapshot over the live run's"; else ok; fi

# ================= 19j. the gap bound cannot outgrow ITS lease share either (#435) ==============
# The lease floor assumes 2x2700 gap attempts; an unclamped generic override (4000) let the
# pre-marker window reach 2x1200 + 2x4000 = 10400 s past the 9000 s claim.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${ADB_DISPATCH_TIMEOUT_SECS:-unset}"
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_TIMEOUT_SECS=4000 bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/gaps.md" 2>/dev/null)" "2700" "19j a generic override past the gap share is clamped to 2700"
( cd "$d" && env ADB_DISPATCH_TIMEOUT_SECS=1000 bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/gaps.md" 2>/dev/null)" "1000" "19j …while tightening below it still governs"
( cd "$d" && env ADB_DISPATCH_TIMEOUT_SECS=060 bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/gaps.md" 2>/dev/null)" "60" "19j …and a zero-padded value is its number, never silently LENGTHENED to the default"
rm -f "$shimbin/claude"

# ================= 19k. a RUNAWAY stream is capped WHILE it is written (#435) ===================
# role-dispatch deliberately leaves a passthrough agent's final stdout uncapped, so a
# malfunctioning CLI could fill the checkout's filesystem during the dispatch — before any
# post-exit publisher can truncate. The stage write itself is bounded at 8 MiB; hitting it kills
# the writer (SIGPIPE), which is a failed dispatch, not a published reply.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=9216 2>/dev/null | tr '\0' 'r'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
RK_RC=$?
if [ "$RK_RC" -ne 0 ]; then ok; else bad "19k a 9 MiB runaway reply is a FAILED dispatch (got rc 0)"; fi
if [ -s "$d/.claude/state/survey.md" ]; then bad "19k …and publishes no survey.md"; else ok; fi
if exists "$d/.claude/state/survey-stage.md"; then bad "19k …and leaves no stage behind"; else ok; fi
rm -f "$shimbin/claude"
# publish-survey's stdin gets the same runaway bound: the stage never exceeds 8 MiB, and the
# ordinary 16 KiB publication bound still applies on top.
d="$(new_repo)"
dd if=/dev/zero bs=1024 count=9216 2>/dev/null | tr '\0' 'n' | ( cd "$d" && bash "$IL" publish-survey .claude/state )
SV_BYTES="$(wc -c < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
if [ -n "$SV_BYTES" ] && [ "$SV_BYTES" -le 16385 ]; then ok; else
  bad "19k a runaway native reply still publishes bounded (got ${SV_BYTES:-none} bytes)"; fi
eq "$(wc -c < "$d/.claude/state/survey-overflow.md" 2>/dev/null | tr -d ' ')" "8388608" \
  "19k …with the overflow capped at the 8 MiB runaway bound"

# ================= 19d. a dispatch that dies mid-write publishes NOTHING (#435) =================
# Same passthrough agent, now emitting partial conclusions before failing. Unstaged, that partial
# stdout used to land in survey.md — and dispatch-gaps includes every nonempty survey.md as if it
# were a completed summary, so truncated conclusions reached gap analysis wearing the survey's
# authority.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'partial conclusions that must never be published\n'
exit 1
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "1" "19d a failing passthrough surveyor returns its own rc"
if [ -s "$d/.claude/state/survey.md" ]; then bad "19d …and its partial stdout was NOT published as survey.md"; else ok; fi
if exists "$d/.claude/state/survey-stage.md"; then bad "19d …and no staging residue was left behind"; else ok; fi
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19d …and the gap prompt still builds"
if grep -q 'survey summary' "$d/.claude/state/gap-prompt.txt"; then
  bad "19d …with no survey section built from the discarded partial output"; else ok; fi
rm -f "$shimbin/claude"

# ================= 22. the survey family is CLEARED by admit (#435) =============================
d="$(new_repo)"
for f in survey-prompt.txt survey.md survey-trace.md survey.err survey-retry.md; do
  : > "$d/.claude/state/$f"
done
: > "$d/.claude/state/review-prompt-stage.aB3xYz"   # a stage orphaned by a killed dispatch-review
admit "$d"
eq "$AD_RC" "0" "22 admit succeeds over a finished run's survey artifacts"
for f in survey-prompt.txt survey.md survey-trace.md survey.err survey-retry.md review-prompt-stage.aB3xYz; do
  if exists "$d/.claude/state/$f"; then bad "22 …but left $f behind (the containment rule broken toward /cleanup)"; else ok; fi
done

# ================= 23. resolve-surfaces keeps the record grammar (#422) =========================
# One `mcp-required <name>` record PER declared server: docs-lib returns one name per line, and
# interpolating the whole list into a single printf left every server after the first as a bare
# unprefixed line no record consumer would select. HOME is pinned so a workstation's global
# manifest cannot leak into the layered read.
d="$(new_repo)"
printf '[mcp]\nrequired = ["ctx7", "grafana"]\n' > "$d/agents.toml"
OUT="$( cd "$d" && env HOME="$work" bash "$IL" resolve-surfaces .claude/state 2>/dev/null )"; RC=$?
eq "$RC" "0" "23 two declared servers resolve rc 0"
eq "$(printf '%s\n' "$OUT" | grep -c '^mcp-required ')" "2" "23 …as one prefixed record per server"
has "$OUT" "mcp-required ctx7" "23 …naming the first"
has "$OUT" "mcp-required grafana" "23 …and the second"
if printf '%s\n' "$OUT" | grep -qv '^mcp-required '; then
  bad "23 …with no bare unprefixed line in the output"; else ok; fi
d="$(new_repo)"
OUT="$( cd "$d" && env HOME="$work" bash "$IL" resolve-surfaces .claude/state 2>/dev/null )"; RC=$?
eq "$RC" "1" "23 no [mcp] declared is rc 1"
eq "$OUT" "mcp-required none" "23 …spelled mcp-required none"

# ================= 11. argument handling ========================================================
bash "$IL" >/dev/null 2>&1;                 eq "$?" "2" "11 no subcommand is a usage error"
bash "$IL" bogus x >/dev/null 2>&1;         eq "$?" "2" "11 an unknown subcommand is a usage error"
bash "$IL" admit >/dev/null 2>&1;           eq "$?" "2" "11 admit needs its state-dir argument"
bash "$IL" admit a b >/dev/null 2>&1;       eq "$?" "2" "11 …exactly one of them"
bash "$IL" release >/dev/null 2>&1;         eq "$?" "2" "11 release needs its state-dir argument"
bash "$IL" --help >/dev/null 2>&1;          eq "$?" "0" "11 --help is not an error"

check_summary "check-implement-lib"
