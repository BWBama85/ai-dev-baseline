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
        printf '{"url":"%s","state":"%s","baseRefName":"%s"}\n' "${SHIM_PR_URL:-https://github.com/o/r/pull/1}" "${SHIM_ADOPT_STATE:-OPEN}" "${SHIM_ADOPT_BASE:-${SHIM_DEFAULT_BASE:-main}}"; exit 0 ;;
      *headRefName*) printf '{"headRefName":"%s","headRefOid":"%s"}\n' "${SHIM_HEAD_REF:-issue-9-x}" "${SHIM_HEAD_OID:-$(git rev-parse HEAD 2>/dev/null)}"; exit 0 ;;
    esac
    if [ "${SHIM_PR_VIEW_FAIL:-0}" = "1" ]; then echo "gh: could not resolve to a PullRequest" >&2; exit 1; fi
    printf '%s\n' "${SHIM_PR_STATE:-}" ;;
  "issue view")
    [ -n "${SHIM_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$SHIM_ARGS_LOG"
    [ -n "${SHIM_ISSUE_SLEEP:-}" ] && sleep "$SHIM_ISSUE_SLEEP"
    if [ "${SHIM_ISSUE_FAIL:-0}" = "1" ]; then echo "gh: issue not found" >&2; exit 1; fi
    if [ -n "${SHIM_LOCK_SWAP:-}" ] && [ -f "$SHIM_LOCK_SWAP" ]; then
      jq '.token = "tokB"' "$SHIM_LOCK_SWAP" > "$SHIM_LOCK_SWAP.t" && mv "$SHIM_LOCK_SWAP.t" "$SHIM_LOCK_SWAP"
    fi
    printf '%s\n' "${SHIM_ISSUE_JSON:-}" ;;
  "api repos/{owner}/{repo}/issues/7")
    # SHIM_SNAP_SWAP: a descendant REPLACING the fetched snapshot (a new inode at the name, not
    # a rewrite of the held one) between the two gh reads.
    if [ -n "${SHIM_SNAP_SWAP:-}" ]; then rm -f "$SHIM_SNAP_SWAP"; printf '{"state":"CLOSED"}\n' > "$SHIM_SNAP_SWAP"; fi
    printf '%s\n' "${SHIM_ASSOC:-OWNER}" ;;
  "api --hostname")
    [ -n "${SHIM_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$SHIM_ARGS_LOG"
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

# The merged-PR lookup is pinned to ORIGIN like open-pr's create: unqualified, gh answers for
# GH_REPO or its configured default (gh repo set-default), and a fork's merged PR at the same head
# would read an unmerged local branch as merged and switch away from it.
if grep -q 'gh pr list "\${_mrflag\[@\]}" --head "\$cur" --state merged' "$IL"; then ok; else
  bad "17 sync-default's merged-PR lookup is not pinned to the origin-derived slug"; fi
slugfn="$(sed -n '/^_il_origin_slug()/,/^}/p' "$IL")"
for pair in 'git@github.com:o/r.git|github.com/o/r' 'ssh://git@github.com/o/r.git|github.com/o/r' \
            'https://github.com/o/r|github.com/o/r' 'https://ghe.example.com/o/r.git|ghe.example.com/o/r' \
            'http://ghe.example.com/o/r/|ghe.example.com/o/r'; do
  d="$(new_repo)"
  ( cd "$d" && git remote remove origin 2>/dev/null; git remote add origin "${pair%%|*}" ) >/dev/null 2>&1
  eq "$( cd "$d" && eval "$slugfn" && _il_origin_slug )" "${pair##*|}" "17 the origin slug for ${pair%%|*}"
done
d="$(new_repo)"
( cd "$d" && git remote remove origin 2>/dev/null; git remote add origin "$work/not-a-forge" ) >/dev/null 2>&1
if ( cd "$d" && eval "$slugfn" && _il_origin_slug ) >/dev/null 2>&1; then
  bad "17 a local-path origin must yield no slug (the stated fallback)"; else ok; fi

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
# A live run always holds a claim during step 2 (admit precedes) — the fixtures carry one, since
# a token-bearing call over an ABSENT claim now refuses (a successor may have superseded it).
clm() { jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$1/.claude/state/gap-analysis.lock"; }
d="$(new_repo)"; gid "$d"; clm "$d"
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
clm "$d"
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
clm "$d"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "22" "18 a literal-name rule set (generated names uncoverable) still refuses (22)"
d="$(new_repo)"; gid "$d"
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
snap "$d" SHIM_ISSUE_JSON="$(printf '%s' "$ISSUE_JSON" | jq -c '.state = "CLOSED"')"
eq "$SN_RC" "21" "18 a CLOSED issue refuses (21) — never silently reopened"
if exists "$d/.claude/state/gap-analysis.lock"; then bad "18 …and the claim was released on that path too"; else ok; fi
d="$(new_repo)"; gid "$d"; clm "$d"
snap "$d" SHIM_ISSUE_FAIL=1
eq "$SN_RC" "20" "18 a failed gh read is 20 (verify repo scope), not a silent pass"
( cd "$d" && bash "$IL" snapshot-issues .claude/state 7x ) >/dev/null 2>&1
eq "$?" "2" "18 a non-numeric issue argument is a usage error"
# …and a usage error must not have RENEWED the claim first: the documented release contract for
# this path would then leave a corrected fresh start refused until the extended lease expires.
d="$(new_repo)"; gid "$d"
jq -n --argjson e "$(($(date +%s) + 100))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
cp "$d/.claude/state/gap-analysis.lock" "$d/lock-b4"
( cd "$d" && bash "$IL" snapshot-issues --token tokT .claude/state 7x ) >/dev/null 2>&1
eq "$?" "2" "18 a token-bearing usage error is still 2"
if cmp -s "$d/.claude/state/gap-analysis.lock" "$d/lock-b4"; then ok; else
  bad "18 …and the claim was NOT renewed before the arguments were even valid"; fi

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
# Since the publisher bounds survey.md itself, the on-disk file can never exceed the size test —
# the notice must key on the OVERFLOW artifact, or the gap agent reads a partial survey
# presented as complete.
printf 'bounded head\n' > "$d/.claude/state/survey.md"
printf 'the whole reply\n' > "$d/.claude/state/survey-overflow.md"
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
has "$(cat "$d/.claude/state/gap-prompt.txt")" 'survey-overflow.md' "19 a bounded-published survey still tells the gap agent about its overflow"
rm -f "$d/.claude/state/survey-overflow.md"
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
has "$(cat "$RP")" 'b/newhelper.txt' "20 …with a repository-relative header a finding can cite"
if grep -q "b$RCLONE/newhelper.txt" "$RP"; then
  bad "20 …never the checkout's absolute host path"; else ok; fi
rm -f "$RCLONE/newhelper.txt"
# An untracked EMBEDDED REPO surfaces as a directory entry `sub/` that --no-index cannot diff
# (exit 1, same as an ordinary differ) — it would land as an unreviewed gitlink, so it refuses.
( cd "$RCLONE" && mkdir -p subrepo && git -C subrepo init -q && printf 'x\n' > subrepo/f ) >/dev/null 2>&1
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 an untracked embedded repo refuses (20), never a silent skip"
rm -rf "$RCLONE/subrepo"
# A SYMLINK is diffable even when its target is a directory or missing — --no-index emits the
# mode-120000 patch with the link target — so it passes review rather than being refused as a
# directory.
( cd "$RCLONE" && ln -s /nonexistent-target danglink ) >/dev/null 2>&1
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "20 an untracked symlink (dangling included) is diffable and accepted"
has "$(cat "$RP")" 'nonexistent-target' "20 …and its target reaches the reviewer"
rm -f "$RCLONE/danglink"
# The enumeration runs from the GIT TOP-LEVEL: invoked from a subdirectory, a cwd-relative
# ls-files silently omits root-level and sibling untracked files from the review prompt.
mkdir -p "$RCLONE/subdir"
printf 'root-level-untracked-content\n' > "$RCLONE/rootfile.txt"
( cd "$RCLONE/subdir" && bash "$IL" dispatch-review --prompt-only ../.claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "20 a below-root invocation still builds"
has "$(cat "$RP")" 'root-level-untracked-content' "20 …and root-level untracked files still reach the reviewer"
rm -rf "$RCLONE/subdir" "$RCLONE/rootfile.txt"
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
stage_count() { local n=0 f; for f in "$1"/review-prompt-stage.*; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }
STG_BEFORE="$(stage_count "$RCLONE/.claude/state")"
( cd "$RCLONE" && bash "$IL" dispatch-review --slot abc .claude/state codex ) >/dev/null 2>&1
eq "$?" "2" "20 a non-numeric --slot is a usage error (the review-N family grammar)"
# A --prompt-only build KEEPS its own stage as the consumer's per-invocation file (section 40);
# a refused invocation must add none.
eq "$(stage_count "$RCLONE/.claude/state")" "$STG_BEFORE" "20 a refused invocation leaves no prompt temp behind"
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
jq -n '{branch:"issue-7-t", issue:7, phase:"committed"}' > "$RCLONE/.claude/state/implement-issue-active.json"
( cd "$RCLONE" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "20" "20 a NUMBER-typed marker .issue refuses (20) — jq -r must not silently stringify it"
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
# The state dir and the body file are ignored, as a real checkout's are: open-pr refuses (27) a
# worktree with anything uncommitted or untracked, because the reviewed tree must be the tip.
printf '.claude/\nbody.md\n' > "$PCLONE/.gitignore"
( cd "$PCLONE" && git add .gitignore && git commit -qm ignore ) >/dev/null 2>&1
( cd "$PCLONE" && git switch -q -c issue-9-x && git commit -q --allow-empty -m wip ) >/dev/null 2>&1
jq -n '{branch:"issue-9-x", issue:"9", phase:"triaged", startedAt:"2026-08-30T00:00:00Z",
        phaseHistory:[{phase:"triaged", at:"2026-08-30T00:00:00Z"}]}' \
  > "$PCLONE/.claude/state/implement-issue-active.json"
printf 'body\n\nCloses #9\n' > "$PCLONE/body.md"
# The adopt-path base gate compares against the fixture's REAL default branch — exported so the
# gh shim's baseRefName fallback always matches it unless a case overrides SHIM_ADOPT_BASE.
SHIM_DEFAULT_BASE="$(cd "$PCLONE" && adb_default_branch)"
export SHIM_DEFAULT_BASE
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
# The 23 arm says "fix the body and re-run" — and the re-run arrives with phase=pr_opened
# already recorded. An unconditional phase write appended a false BACKWARD
# pr_opened→pushed→pr_opened lifecycle to the history a resumed session reads.
eq "$(jq -r '[.phaseHistory[].phase] | join(",")' "$M")" "triaged,pushed,pr_opened" \
  "21 …and the re-run never regresses the phase history"
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
# EMPTY FIELDS refuse before splitting can discard them: "9," may be a lost second issue, and
# certifying only the survivors would prove closing links for a narrowed set.
for badcl in "9," ",9" "9,,7"; do
  openpr2 "$badcl" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
  eq "$OP_RC" "2" "21 a --closes with an empty field ('$badcl') is a usage error"
done
# STDOUT IS THE RECORD STREAM: on a branch's FIRST push, `git push -u` writes its
# upstream-registration message to stdout, which would ride between the closed one-fact-per-line
# records and break any consumer that parses them.
read -r _ P3CLONE <<EOF
${ remote_pair; }
EOF
mkdir -p "$P3CLONE/.claude/state"
printf '.claude/\nbody.md\n' > "$P3CLONE/.gitignore"
( cd "$P3CLONE" && git add .gitignore && git commit -qm ignore ) >/dev/null 2>&1
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
# a NUMBER-typed marker branch must refuse even when a branch of that name exists: jq -r would
# stringify it and the equality would pass, pushing from malformed run state.
cp "$PCLONE/.claude/state/implement-issue-active.json" "$PCLONE/.claude/state/active-sv.json"
( cd "$PCLONE" && git switch -q -c 7 ) >/dev/null 2>&1
jq '.branch = 7' "$PCLONE/.claude/state/active-sv.json" > "$PCLONE/.claude/state/implement-issue-active.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "26" "21 a number-typed marker branch refuses (26) even when a branch of that name is checked out"
( cd "$PCLONE" && git switch -q issue-9-x && git branch -D 7 ) >/dev/null 2>&1
mv "$PCLONE/.claude/state/active-sv.json" "$PCLONE/.claude/state/implement-issue-active.json"
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
# A DIRECTORY at the blocked name is a marker that exists and cannot be read: `-f` used to skip
# the whole guard and arm past it; presence is -e/-L now and the bounded read fails closed.
mkdir "$PCLONE/.claude/state/implement-issue-blocked.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 a directory at the blocked-marker name still opens the PR"
has "$OP_OUT" "arm-skipped blocked-marker-unreadable" "21 …and withholds the arm instead of reading as no block"
rmdir "$PCLONE/.claude/state/implement-issue-blocked.json"
# ONE READ, validated and compared from the same bytes. A validate-by-name followed by a second
# bounded copy was two moments: this jq shim empties the marker right after a validation read of
# it by NAME, so the old code compared empty fields as "unrelated" and armed past its own block.
jq -n '{reason:"r", phase:"triaged", branch:"issue-9-x", issue:"9"}' > "$PCLONE/.claude/state/implement-issue-blocked.json"
mkdir -p "$work/jqswap"
REALJQ="$(command -v jq)"
cat > "$work/jqswap/jq" <<SH
#!/usr/bin/env bash
"$REALJQ" "\$@"; rc=\$?
for a in "\$@"; do case "\$a" in */implement-issue-blocked.json) : > "\$a" ;; esac; done
exit \$rc
SH
chmod +x "$work/jqswap/jq"
openpr PATH="$work/jqswap:$PATH" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "21 with the marker read once, the PR still opens"
has "$OP_OUT" "arm-skipped blocked-marker" "21 …and a marker emptied right after a by-name validation read still withholds the arm"
rm -f "$PCLONE/.claude/state/implement-issue-blocked.json"
# …and the ACTIVE side too: a valid block cannot be proved unrelated against a marker whose
# .issue cannot be read — that comparison's other half is missing, so the arm is withheld.
cp "$PCLONE/.claude/state/implement-issue-active.json" "$PCLONE/.claude/state/active-save.json"
jq 'del(.issue)' "$PCLONE/.claude/state/active-save.json" > "$PCLONE/.claude/state/implement-issue-active.json"
jq -n '{reason:"r", phase:"triaged", branch:"issue-9-x", issue:"9"}' > "$PCLONE/.claude/state/implement-issue-blocked.json"
# REVISED (round 37): with --closes present, an unreadable .issue now refuses BEFORE the push —
# the membership gate cannot run without its set, and the auto-close a mistyped number carries
# fires on ANY merge, armed or not, so open-but-unarmed was not actually safe. The
# open-with-arm-withheld contract this case used to pin survives on the no---closes path.
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "26" "21 an active marker without a readable .issue refuses while --closes is present"
has "$OP_OUT" "no readable string .issue" "21 …naming the marker fault before anything is pushed"
OP_OUT="$( cd "$PCLONE" && env SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/8" SHIM_CLOSING_JSON='{"closingIssuesReferences":[]}' \
  bash "$IL" open-pr .claude/state --title t --body-file body.md 2>&1 )"; OP_RC=$?
eq "$OP_RC" "0" "21 …while WITHOUT --closes the same marker still opens the PR"
has "$OP_OUT" "arm-skipped blocked-marker-unreadable" "21 …and withholds the arm — the comparison's other half is missing"
mv "$PCLONE/.claude/state/active-save.json" "$PCLONE/.claude/state/implement-issue-active.json"
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
has "$(cat "$d/.claude/state/survey-trace.md" 2>/dev/null)" 'survey-trace-full.md' "19h …and the note names where the whole trace went"
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
# The native publisher is a pre-marker WRITER like the dispatchers, so it takes the same
# fail-closed renewal check: a stale run resumed after a successor admitted must not replace
# the live run's survey.md.
d="$(new_repo)"
jq -n '{startedAt:1, expiresAt:9999999999, token:"tokB"}' > "$d/.claude/state/gap-analysis.lock"
printf 'stale native reply\n' | ( cd "$d" && bash "$IL" publish-survey --token tokA .claude/state ); RC=$?
eq "$RC" "13" "19i a successor's claim refuses the native publisher (13)"
if exists "$d/.claude/state/survey.md"; then bad "19i …and nothing was published over the live run's"; else ok; fi
d="$(new_repo)"
jq -n --argjson e "$(($(date +%s) + 9000))" '{startedAt:1, expiresAt:$e, token:"tokA"}' > "$d/.claude/state/gap-analysis.lock"
printf 'live native reply\n' | ( cd "$d" && bash "$IL" publish-survey --token tokA .claude/state ); RC=$?
eq "$RC" "0" "19i …while the claim holder publishes and renews"
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "live native reply" "19i …verbatim"

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
# A TOKENLESS (or unreadable) claim fails CLOSED for a token-bearing caller: the same damage
# that loses .token loses the lease, which admit reads as immediately breakable — proceeding
# would let a concurrent admission reap the claim mid-work. The file is left byte-identical.
d="$(new_repo)"; seed_snap "$d"
jq -n '{startedAt:1, expiresAt:9999999999}' > "$d/.claude/state/gap-analysis.lock"
cp "$d/.claude/state/gap-analysis.lock" "$d/lock-before"
( cd "$d" && bash "$IL" dispatch-gaps --token tokA --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l a tokenless claim refuses a token-bearing caller (13) — admit would break that claim"
if cmp -s "$d/.claude/state/gap-analysis.lock" "$d/lock-before"; then ok; else
  bad "19l …and the claim is left byte-identical"; fi
# A run whose OWN lease has lapsed is reaped-eligible: it refuses (13) rather than self-reviving —
# a successor may already hold or be taking the path — and the claim file is left untouched. This
# is also what makes the non-vacating publish safe: only an EXPIRED claim can be broken by admit,
# and an unexpired one is renewed in a milliseconds window it cannot expire inside.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS - 100))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
cp "$d/.claude/state/gap-analysis.lock" "$d/lock-exp"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l an already-lapsed own lease refuses (13) instead of self-reviving"
if cmp -s "$d/.claude/state/gap-analysis.lock" "$d/lock-exp"; then ok; else
  bad "19l …with the lapsed claim left untouched"; fi
# An ABSENT claim refuses a token-bearing caller: a successor can have completed admission,
# reached its marker and released — the old no-op let the stale run overwrite its artifacts.
d="$(new_repo)"; seed_snap "$d"
( cd "$d" && bash "$IL" dispatch-gaps --token tokA --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l an absent claim refuses a token-bearing caller (13) — the pre-marker window is over"
# Mutex hygiene: renewal leaves none behind, and a STALE one (dead holder) is broken through.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
mkdir "$d/.claude/state/.claim-mutex"
touch -t 202001010000 "$d/.claude/state/.claim-mutex" 2>/dev/null
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19l a stale claim mutex is broken through, not honored forever"
if [ -d "$d/.claude/state/.claim-mutex" ]; then bad "19l …and no mutex is left behind"; else ok; fi
# …ON GNU TOO: GNU stat reads -f as a filesystem report and can print before failing, so an
# inline `stat -f || stat -c` chain concatenated garbage and honored a stale mutex forever on
# Ubuntu. A GNU-flavored stat shim proves the portable helper survives it.
cat > "$shimbin/stat" <<'SH'
#!/usr/bin/env bash
# GNU stat: -L is accepted anywhere, -f is the filesystem report, -c takes a format.
[ "$1" = "-L" ] && shift
case "$1" in
  -f) echo "  File: \"$3\" ID: 100 Namelen: 255"; exit 1 ;;
  -c) perl -e '@s = stat($ARGV[1]) or exit 1; print $ARGV[0] eq "%s" ? $s[7] : $ARGV[0] eq "%i" ? $s[1] : $s[9]' "$2" "$3" ;;
  *)  exit 1 ;;
esac
SH
chmod +x "$shimbin/stat"
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
mkdir "$d/.claude/state/.claim-mutex"
touch -t 202001010000 "$d/.claude/state/.claim-mutex" 2>/dev/null
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19l a stale mutex is broken under a GNU-flavored stat too"
rm -f "$shimbin/stat"
# A FRESH mutex is honored, and honored WITHOUT being reaped: the stale-reaper renames the
# instance it judged and re-verifies its age before deleting — a pathname-only rmdir let two
# contenders both judge one stale mutex and the slower one delete the winner's FRESH mutex.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
mkdir "$d/.claude/state/.claim-mutex"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l a FRESH foreign mutex refuses after the bounded wait (13)"
if [ -d "$d/.claude/state/.claim-mutex" ]; then ok; else
  bad "19l …and the fresh mutex survives — it was never reaped"; fi
rmdir "$d/.claude/state/.claim-mutex" 2>/dev/null
# A renewal that could NOT be published refuses (20): silently proceeding leaves the caller on a
# near-expiry lease a concurrent admission can reap mid-work. The stage is now created
# EXCLUSIVELY at .claim.w<pid>, so the inducement plants a directory at that exact name —
# `exec` keeps the pre-exec shell's pid, which is how the test knows it — and the O_EXCL create
# must fail loudly rather than write anywhere.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
SN_OUT="$( cd "$d" && bash -c 'mkdir -p ".claude/state/.claim.w$$"; exec bash "$1" dispatch-gaps --token tokT --prompt-only .claude/state 7' _ "$IL" 2>&1 )"; RN_RC=$?
eq "$RN_RC" "20" "19l an unpublishable renewal refuses (20), never proceeds on the old lease"
has "$SN_OUT" "could not create the renewal stage exclusively" "19l …named as the renewal itself"
# The lease is renewed BETWEEN issues, not only at the subcommand's start: a large set or slow
# gh reads outlive a single lease, and a successor arriving mid-set must refuse the remainder.
# The shim swaps the claim's token on the first gh call, so iteration two's renewal sees it.
d="$(new_repo)"; gid "$d"; clm "$d"
SN_OUT="$( cd "$d" && env SHIM_ISSUE_JSON="$ISSUE_JSON" SHIM_LOCK_SWAP="$d/.claude/state/gap-analysis.lock" \
  bash "$IL" snapshot-issues --token tokT .claude/state 7 8 2>&1 )"; SN_RC=$?
eq "$SN_RC" "13" "19l a successor arriving mid-set refuses the remaining issues (13)"
# OUR token + an UNREADABLE lease fails closed: admit reads that same shape as immediately
# breakable, so proceeding lets a concurrent admission reap the claim mid-work.
d="$(new_repo)"; seed_snap "$d"
jq -n '{startedAt:1, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l our token over an unreadable lease refuses (13) — admit would break that claim"
d="$(new_repo)"; seed_snap "$d"
jq -n '{startedAt:1, expiresAt:"soon", token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "19l …and a wrongly typed lease refuses the same way"
# An INVALID lease override mid-run refuses too: silently skipping the renewal leaves the run on
# a lease that may be near expiry — the configuration error is reported, not worked around.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && env ADB_RUN_CLAIM_LEASE_SECS=abc bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "12" "19l an invalid lease override refuses (12) instead of proceeding unrenewed"
# An unreadable CLOCK fails closed too: without now, neither the lease nor the margin can be
# validated, and proceeding is the same near-expiry exposure.
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
mkdir -p "$d/fakebin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$d/fakebin/date"; chmod +x "$d/fakebin/date"
( cd "$d" && env PATH="$d/fakebin:$PATH" bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "20" "19l an unreadable clock refuses (20) — the lease cannot be validated without it"
# Each fetch is BOUNDED under the lease: one stalled gh call used to hold the loop past 9000s
# with the claim expiring under it. The bound is adb_run_bounded's; the knob exists for tests.
d="$(new_repo)"; gid "$d"; clm "$d"
SN_OUT="$( cd "$d" && env SHIM_ISSUE_JSON="$ISSUE_JSON" SHIM_ISSUE_SLEEP=5 ADB_SNAPSHOT_FETCH_TIMEOUT_SECS=1 \
  bash "$IL" snapshot-issues --token tokT .claude/state 7 2>&1 )"; SN_RC=$?
eq "$SN_RC" "20" "19l a stalled issue fetch is killed at the bound (20), never held past the lease"

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
# publish-survey's stdin gets the same runaway treatment as the CLI path: a reply past 8 MiB is
# a FAILED publication, never a truncated prefix labelled full and reported "survey ok".
d="$(new_repo)"
dd if=/dev/zero bs=1024 count=9216 2>/dev/null | tr '\0' 'n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
NK_RC=$?
if [ "$NK_RC" -ne 0 ]; then ok; else bad "19k a 9 MiB native reply is a FAILED publication (got rc 0)"; fi
if [ -s "$d/.claude/state/survey.md" ]; then bad "19k …and publishes no truncated survey.md"; else ok; fi
if exists "$d/.claude/state/survey-overflow.md"; then bad "19k …and labels nothing as the full reply"; else ok; fi
# A shorter REPUBLICATION removes the stale overflow: the navigator describes that file as the
# full reply behind the bounded summary, and a previous attempt's copy must not wear that label.
dd if=/dev/zero bs=1024 count=32 2>/dev/null | tr '\0' 'n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$?" "0" "19k a 32 KiB native reply publishes with its overflow"
if exists "$d/.claude/state/survey-overflow.md"; then ok; else bad "19k …which exists"; fi
printf 'short retry\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$?" "0" "19k a shorter republication publishes"
if exists "$d/.claude/state/survey-overflow.md"; then
  bad "19k …and removes the previous attempt's overflow"; else ok; fi

# ================= 19m. the trace is bounded AFTER the dispatch — race-free by design (#435) ====
# An in-flight watcher was tried and retired: five review rounds each found the next hole in a
# shell process fighting a live adversarial writer over an agent-owned pathname (symlink swaps,
# held-name discovery, vacancy windows). The in-flight bound is therefore the dispatch timeout
# itself; the post-exit cap runs with the adversary dead, where the pathname dance cannot race.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md
printf 'ok\n'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_LOG_MAX_BYTES=1024 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19m the dispatch completes rc 0"
TR_FINAL="$(wc -c < "$d/.claude/state/survey-trace.md" 2>/dev/null | tr -d ' ')"
if [ -n "$TR_FINAL" ] && [ "$TR_FINAL" -le 1400 ]; then ok; else
  bad "19m …and the trace name holds a small note post-dispatch (got ${TR_FINAL:-none} bytes)"; fi
eq "$(wc -c < "$d/.claude/state/survey-trace-full.md" 2>/dev/null | tr -d ' ')" "307200" \
  "19m …with the full trace preserved WHOLE — nothing was ever truncated"
rm -f "$shimbin/claude"
# A zero-padded cap is its number: "08" used to start the watcher and then abort the final cap
# with bash's octal "value too great for base".
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1024 count=2 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md
printf 'ok\n'
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_DISPATCH_LOG_MAX_BYTES=08 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19m a zero-padded cap is decimal — the dispatch completes"
TR_B="$(wc -c < "$d/.claude/state/survey-trace.md" 2>/dev/null | tr -d ' ')"
if [ -n "$TR_B" ] && [ "$TR_B" -le 400 ]; then ok; else
  bad "19m …and the 8-byte cap moved the trace aside (got ${TR_B:-none} bytes at the name)"; fi
rm -f "$shimbin/claude"

# ================= 19n. the cap constrains the inode the writer HOLDS (#435) ====================
# A rename-based cap replaced the pathname and left the surveyor's open descriptor on a hidden
# unlinked inode that kept growing unseen. In-place truncation keeps the writer on the capped
# inode, so its next append lands where the next pass (and the path's size) can see it.
capfn="$(sed -n '/^_il_wc_bounded()/,/^}/p' "$IL"; sed -n '/^_il_excl_create()/,/^}/p' "$IL"; sed -n '/^_il_cap_trace()/,/^}/p' "$IL")"
CAP_D="$(new_repo)"
( cd "$CAP_D" && eval "$capfn" \
  && dd if=/dev/zero bs=1024 count=4 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md \
  && exec 3>> .claude/state/survey-trace.md \
  && _il_cap_trace .claude/state 1024 quiet \
  && printf 'POST-CAP-WRITE' >&3 ) || bad "19n the cap probe did not run"
# The no-truncate design preserves the writer's inode WHOLE at survey-trace-full.md — a post-cap
# write through the held fd lands there, never lost and never on a hidden unlinked inode.
if grep -aq 'POST-CAP-WRITE' "$CAP_D/.claude/state/survey-trace-full.md"; then ok; else
  bad "19n a post-cap write through the held fd lands in the preserved full trace, never a hidden inode"; fi
# The trace path is AGENT-WRITABLE and the issue text is third-party: a surveyor can plant it
# as a symlink at any writable repo file, and a following truncate would erase that target.
CAP_D="$(new_repo)"
printf 'precious repo content\n' > "$CAP_D/target.txt"
( cd "$CAP_D" && eval "$capfn" \
  && ln -s ../../target.txt .claude/state/survey-trace.md \
  && dd if=/dev/zero bs=1024 count=4 2>/dev/null | tr '\0' 't' >> target.txt \
  && _il_cap_trace .claude/state 1024 quiet )
T_SZ="$(wc -c < "$CAP_D/target.txt" 2>/dev/null | tr -d ' ')"
if [ -n "$T_SZ" ] && [ "$T_SZ" -gt 4000 ]; then ok; else
  bad "19n a symlinked trace never truncates its target (target is ${T_SZ:-unreadable} bytes)"; fi
if [ -L "$CAP_D/.claude/state/survey-trace.md" ]; then
  bad "19n …and the planted link itself is removed"; else ok; fi
# The stage the publishers write is plantable the same way.
d="$(new_repo)"
printf 'precious repo content\n' > "$d/target2.txt"
( cd "$d" && ln -s ../../target2.txt .claude/state/survey-stage.md ) >/dev/null 2>&1
printf 'native reply\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$(cat "$d/target2.txt" 2>/dev/null)" "precious repo content" \
  "19n a symlinked stage never writes through to its target"
# The renewal stage is plantable the same way: a planted .claim.tmp must neither be written
# through nor become the canonical claim.
d="$(new_repo)"; seed_snap "$d"
printf 'precious repo content\n' > "$d/target3.txt"
jq -n --argjson e "$(($(date +%s) + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && ln -s ../../target3.txt .claude/state/.claim.tmp ) >/dev/null 2>&1
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19n a planted renewal stage does not break the renewal"
eq "$(cat "$d/target3.txt" 2>/dev/null)" "precious repo content" \
  "19n …and never writes claim JSON through to its target"
if [ -L "$d/.claude/state/gap-analysis.lock" ]; then
  bad "19n …and the canonical claim never becomes the planted symlink"; else ok; fi
# The gap prompt (and every fixed name a dispatched agent can pre-plant) is unlinked before its
# redirect — the surveyor runs FIRST with repo access and third-party text, so a later builder
# following a planted link would truncate any writable repo file.
d="$(new_repo)"; seed_snap "$d"
printf 'precious repo content\n' > "$d/target4.txt"
( cd "$d" && ln -s ../../target4.txt .claude/state/gap-prompt.txt ) >/dev/null 2>&1
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "0" "19n a planted gap prompt does not break the build"
eq "$(head -n1 "$d/target4.txt" 2>/dev/null)" "precious repo content" \
  "19n …and the prompt build never writes through it"
if [ -L "$d/.claude/state/gap-prompt.txt" ]; then
  bad "19n …and the built prompt is a regular file, not the planted link"; else ok; fi
# Review OUTPUTS are plantable the same way — the reviewer's redirect must not write through.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
[ -n "$last" ] && printf 'review says fine\n' > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
read -r _ RVC <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVC/.claude/state"; seed_snap "$RVC"
( cd "$RVC" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
printf 'precious repo content\n' > "$RVC/target5.txt"
( cd "$RVC" && ln -s ../../target5.txt .claude/state/review.md ) >/dev/null 2>&1
( cd "$RVC" && bash "$IL" dispatch-review .claude/state codex ) >/dev/null 2>&1
eq "$(cat "$RVC/target5.txt" 2>/dev/null)" "precious repo content" \
  "19n a planted review output never writes through to its target"
rm -f "$shimbin/codex"
# …and a reviewer that SWAPS its output for a symlink after writing cannot have a foreign file
# read back as findings: the result path must still be a regular file when the dispatch returns.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
[ -n "$last" ] && printf 'benign findings\n' > "$last"
rm -f .claude/state/review.md
ln -s ../../secret-r.txt .claude/state/review.md
exit 0
SH
chmod +x "$shimbin/codex"
printf 'REVIEW-SECRET\n' > "$RVC/secret-r.txt"
( cd "$RVC" && bash "$IL" dispatch-review .claude/state codex ) >/dev/null 2>&1
RS_RC=$?
if [ "$RS_RC" -ne 0 ]; then ok; else bad "19n a swapped review output is a FAILED slot (got rc 0)"; fi
if [ -L "$RVC/.claude/state/review.md" ]; then
  bad "19n …and the planted link does not survive as the result path"; else ok; fi
rm -f "$shimbin/codex"
# …and the shared phase writer's .marker.tmp stage: the FIRST post-push phase write follows a
# planted link unless the stage is unlinked every time, not only at the prUrl write.
printf 'precious repo content\n' > "$PCLONE/target6.txt"
( cd "$PCLONE" && ln -s ../../target6.txt .claude/state/.marker.tmp ) >/dev/null 2>&1
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$(cat "$PCLONE/target6.txt" 2>/dev/null)" "precious repo content" \
  "19n a planted phase stage never writes through to its target"
rm -f "$PCLONE/target6.txt"

# ================= 19p. no background capper exists at all (#435) ===============================
# The in-flight watcher is retired (see 19m); this pins that the lib carries no background
# capper call site to orphan — process archaeology via pgrep matched the test harness's own
# wrapper cmdline and is not a usable witness.
if grep -q '_il_cap_trace "\$dir" "\$_tmax" quiet' "$IL"; then
  bad "19p a background (quiet) capper call site reappeared in the lib"; else ok; fi

# ================= 19o. an oversized CODEX reply is a failed dispatch too (#435) ================
# The codex arm emits its result with `cat` after the bounded call; the stage's 8 MiB head cap
# closes the pipe, and a masked SIGPIPE published the truncated result as a clean survey.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && last="$a"
  prev="$a"
done
[ -n "$last" ] && dd if=/dev/zero bs=1024 count=9216 2>/dev/null | tr '\0' 'c' > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "codex"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
OC_RC=$?
if [ "$OC_RC" -ne 0 ]; then ok; else bad "19o a 9 MiB codex reply is a FAILED dispatch (got rc 0)"; fi
if [ -s "$d/.claude/state/survey.md" ]; then bad "19o …and publishes no truncated survey.md"; else ok; fi
rm -f "$shimbin/codex"

# ================= 19q. the stage must be a nonempty REGULAR file to publish (#435) =============
# A surveyor can unlink the stage mid-pipe (its stdout stays on the old inode) and leave a
# symlink at the name — publishing would then hand an arbitrary repo or host file to the primary
# and the gap agent as "the survey". And an empty reply is a failed survey, never "ok 0 words".
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'decoy\n'
rm -f .claude/state/survey-stage.md
ln -s ../../secret.txt .claude/state/survey-stage.md
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf 'HOST-SECRET-CONTENT\n' > "$d/secret.txt"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
SW_RC=$?
if [ "$SW_RC" -ne 0 ]; then ok; else bad "19q a swapped stage is a FAILED publication (got rc 0)"; fi
if grep -q HOST-SECRET-CONTENT "$d/.claude/state/survey.md" 2>/dev/null; then
  bad "19q …and no foreign file is published as the survey"; else ok; fi
rm -f "$shimbin/claude"
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok; else bad "19q an EMPTY reply is a failed survey, never ok-0-words"; fi
if exists "$d/.claude/state/survey.md"; then bad "19q …and publishes nothing"; else ok; fi
rm -f "$shimbin/claude"
d="$(new_repo)"
printf '' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok; else bad "19q an empty native reply fails publication too"; fi

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
: > "$d/.claude/state/survey-trace-cap.md"           # the capper's scratch, orphaned by a kill
admit "$d"
eq "$AD_RC" "0" "22 admit succeeds over a finished run's survey artifacts"
for f in survey-prompt.txt survey.md survey-trace.md survey.err survey-retry.md review-prompt-stage.aB3xYz survey-trace-cap.md; do
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

# ================= 24. planted non-regular files at fixed state names (#435) ====================
# The surveyor/gap/review agents run with repo tools on third-party text, so every fixed name a
# later step opens or moves onto is plantable — not only as a symlink (19n) but as a FIFO (an
# open that blocks forever) or a DIRECTORY (an mv that moves INSIDE instead of replacing, and an
# rm -f that cannot remove it, stranding the next admission).

# A FIFO at the trace name must be refused UNREAD: the cap runs post-dispatch, outside every
# bounded-runner timeout, and `wc -c <` on a pipe with no writer blocks indefinitely.
CAP_D="$(new_repo)"
mkfifo "$CAP_D/.claude/state/survey-trace.md"
( cd "$CAP_D" && eval "$capfn" && _il_cap_trace .claude/state 1024 quiet ) &
CAP_PID=$!
i=0; while kill -0 "$CAP_PID" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i+1)); done
if kill -0 "$CAP_PID" 2>/dev/null; then
  bad "24 a FIFO at the trace name hangs the cap"
  # Pair the blocked open so the orphan exits before the suite moves on.
  : > "$CAP_D/.claude/state/survey-trace.md" 2>/dev/null
  wait "$CAP_PID" 2>/dev/null
else
  wait "$CAP_PID" 2>/dev/null; ok
fi
if [ -e "$CAP_D/.claude/state/survey-trace.md" ] || [ -L "$CAP_D/.claude/state/survey-trace.md" ]; then
  bad "24 …and the FIFO is removed, not left as a trap for the next reader"; else ok; fi

# A DIRECTORY at the trace name: `wc -c <` fails, the old code returned 0 and left it standing.
CAP_D="$(new_repo)"
mkdir "$CAP_D/.claude/state/survey-trace.md"
( cd "$CAP_D" && eval "$capfn" && _il_cap_trace .claude/state 1024 quiet )
if [ -e "$CAP_D/.claude/state/survey-trace.md" ]; then
  bad "24 a directory at the trace name is removed, not left to strand the clear"; else ok; fi

# A directory planted at survey-trace-full.md swallows the oversize trace: `mv -f` onto a
# directory moves the source INSIDE it, and the note then names an artifact that is not there.
CAP_D="$(new_repo)"
mkdir "$CAP_D/.claude/state/survey-trace-full.md"
( cd "$CAP_D" && eval "$capfn" \
  && dd if=/dev/zero bs=1024 count=4 2>/dev/null | tr '\0' 't' > .claude/state/survey-trace.md \
  && _il_cap_trace .claude/state 1024 quiet )
if [ -f "$CAP_D/.claude/state/survey-trace-full.md" ] && [ ! -L "$CAP_D/.claude/state/survey-trace-full.md" ]; then
  ok; else bad "24 a planted directory at survey-trace-full.md swallows the preserved trace (mv-inside)"; fi

# The same mv-inside at survey-overflow.md, and it is WORSE: the validated stage vanishes into
# the directory, _il_survey_head cannot read a directory, and the old unconditional return 0
# published the resulting EMPTY head as a successful survey.
d="$(new_repo)"
mkdir "$d/.claude/state/survey-overflow.md"
awk 'BEGIN{for(i=0;i<2000;i++)print "survey line " i}' \
  | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
OV_RC=$?
SV_B="$(wc -c < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
if [ "$OV_RC" -eq 0 ] && [ -f "$d/.claude/state/survey.md" ] && [ "${SV_B:-0}" -gt 0 ]; then
  ok; else bad "24 a planted overflow directory must not turn an oversize survey into an empty one (rc=$OV_RC, ${SV_B:-0} bytes)"; fi
if [ -f "$d/.claude/state/survey-overflow.md" ] && [ ! -L "$d/.claude/state/survey-overflow.md" ]; then
  ok; else bad "24 …and the full reply lands at survey-overflow.md as a regular file"; fi

# The small-reply branch removes a stale overflow so it cannot wear the "full reply" label — a
# planted DIRECTORY there survived the old `rm -f`.
d="$(new_repo)"
mkdir "$d/.claude/state/survey-overflow.md"
printf 'short survey\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$?" "0" "24 a short reply still publishes over a planted overflow directory"
if [ -e "$d/.claude/state/survey-overflow.md" ]; then
  bad "24 …and the planted directory does not survive wearing the full-reply label"; else ok; fi

# And at survey.md itself: mv-inside would report "survey ok" while the published name is a
# directory no reader can open.
d="$(new_repo)"
mkdir "$d/.claude/state/survey.md"
printf 'short survey\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$?" "0" "24 a planted directory at survey.md does not fail the publish"
if [ -f "$d/.claude/state/survey.md" ] && [ ! -L "$d/.claude/state/survey.md" ]; then
  ok; else bad "24 …and survey.md is the published regular file, not the planted directory"; fi

# _il_survey_head must REFUSE an unreadable input, not die on it: its `local … line` is declared
# unset, a read error (EISDIR) skips the assignment, and `[ -n "$line" ]` under the lib's set -u
# is then a FATAL unbound-variable exit that takes the calling process with it — skipping every
# cleanup after the call site. The witness is caller survival, not the rc alone.
headfn="$(sed -n '/^_il_survey_head()/,/^}/p' "$IL")"
HD_D="$(new_repo)"
HD_OUT="$( set -u; eval "$headfn"; _il_survey_head "$HD_D/.claude/state" >/dev/null 2>/dev/null
           printf 'SURVIVED=%s\n' "$?" )"
eq "$HD_OUT" "SURVIVED=1" "24 _il_survey_head refuses an unopenable input and its caller survives"

# The gap RESULT path after dispatch: a gap agent can swap gaps.md for a symlink (its stdout
# stays on the opened inode), and step 4 then reads the replacement pathname as findings.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'gap findings\n'
rm -f .claude/state/gaps.md
ln -s ../../gsecret.txt .claude/state/gaps.md
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
printf 'GAP-SECRET\n' > "$d/gsecret.txt"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GS_RC=$?
if [ "$GS_RC" -ne 0 ]; then ok; else bad "24 a swapped gap output is a FAILED dispatch (got rc 0)"; fi
if [ -L "$d/.claude/state/gaps.md" ]; then
  bad "24 …and the planted link does not survive as the result path"; else ok; fi

# …and a gap agent that UNLINKS its output and exits 0: rc 0 with nothing to read is a discarded
# analysis reported as a success.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'gap findings\n'
rm -f .claude/state/gaps.md
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GA_RC=$?
if [ "$GA_RC" -ne 0 ]; then ok; else bad "24 a MISSING gap output after dispatch is a failed dispatch (got rc 0)"; fi
rm -f "$shimbin/claude"

# The review slot has the same absence hole: the post-dispatch predicate rejected links and
# existing non-files but permitted a reviewer that unlinked its output and exited 0.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
[ -n "$last" ] && printf 'benign findings\n' > "$last"
rm -f .claude/state/review.md
exit 0
SH
chmod +x "$shimbin/codex"
read -r _ RVA <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVA/.claude/state"; seed_snap "$RVA"
( cd "$RVA" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
( cd "$RVA" && bash "$IL" dispatch-review .claude/state codex ) >/dev/null 2>&1
RA_RC=$?
if [ "$RA_RC" -ne 0 ]; then ok; else bad "24 a review output MISSING after dispatch is a failed slot (got rc 0)"; fi
rm -f "$shimbin/codex"

# The review PROMPT destination: a directory planted at review-prompt.txt makes the stage mv
# land INSIDE it while the subcommand prints prompt-ready for a path that is a directory.
( cd "$RVA" && rm -rf .claude/state/review-prompt.txt && mkdir .claude/state/review-prompt.txt ) >/dev/null 2>&1
( cd "$RVA" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "24 a planted directory at the review prompt name does not fail the build"
if [ -f "$RVA/.claude/state/review-prompt.txt" ] && [ ! -L "$RVA/.claude/state/review-prompt.txt" ]; then
  ok; else bad "24 …and the built prompt is a regular file, not the planted directory"; fi

# A planted directory at ANY swept family name must not strand the next admission: `rm -f`
# cannot remove a directory, so the old clear reported failure forever.
d="$(new_repo)"
mkdir "$d/.claude/state/survey-overflow.md"
: > "$d/.claude/state/survey.md"
admit "$d"
eq "$AD_RC" "0" "24 admit clears a planted directory at a swept name instead of stranding"
if [ -e "$d/.claude/state/survey-overflow.md" ]; then
  bad "24 …and the planted directory is gone"; else ok; fi

# ================= 25. the oversize head never reopens the vacated stage name (#435) ============
# role-dispatch's bounded-runner contract admits descendants can survive the CLI, so the moment
# the oversize mv vacates survey-stage.md a survivor can plant a symlink there — and the old
# `> "$dir/survey-stage.md"` reopened that public fixed name, writing the head THROUGH the plant.
# The probe rides the head call itself: at that moment the public stage name must not exist (the
# head is created under a private mktemp name and published by rename), and a plant dropped at
# the vacated name during the head must neither receive the output nor survive as survey.md.
pubfn="$(sed -n '/^_il_fd_close()/,/^}/p' "$IL"; sed -n '/^_il_inode()/,/^}/p' "$IL"; sed -n '/^_il_same_inode()/,/^}/p' "$IL"; sed -n '/^_il_excl_create()/,/^}/p' "$IL"; sed -n '/^_il_survey_head()/,/^}/p' "$IL"; sed -n '/^_il_publish_survey()/,/^}/p' "$IL")"
PB_D="$(new_repo)"
printf 'precious repo content\n' > "$PB_D/planted-target.txt"
awk 'BEGIN{for(i=0;i<2000;i++)print "survey line " i}' > "$PB_D/.claude/state/survey-stage.md"
PB_OUT="$(
  eval "$pubfn"
  _il_survey_head() {
    # The state dir by fixture path: the head now reads a held /dev/fd descriptor, not a name.
    local dir="$PB_D/.claude/state"
    if [ -e "$dir/survey-stage.md" ] || [ -L "$dir/survey-stage.md" ]; then
      printf 'REOPENED-PUBLIC-NAME\n'
    else
      printf 'HEAD-VIA-PRIVATE-NAME\n'
    fi
    rm -f "$dir/survey-stage.md" 2>/dev/null
    ln -s ../../planted-target.txt "$dir/survey-stage.md" 2>/dev/null
    return 0
  }
  cd "$PB_D" && exec {sfd}<.claude/state/survey-stage.md \
    && _il_publish_survey .claude/state "$sfd" 2>/dev/null; printf 'RC=%s\n' "$?"
)"
has "$PB_OUT" "RC=0" "25 the oversize publish still succeeds"
if [ -L "$PB_D/.claude/state/survey.md" ]; then
  bad "25 …but a plant at the vacated stage name became survey.md"; else ok; fi
eq "$(cat "$PB_D/.claude/state/survey.md" 2>/dev/null)" "HEAD-VIA-PRIVATE-NAME" \
  "25 …and the head was built under a private name, never by reopening the public stage"
eq "$(cat "$PB_D/planted-target.txt" 2>/dev/null)" "precious repo content" \
  "25 …and nothing wrote through the planted link"

# The head's 16 KiB bound counts the emitted newline: a first line of 16384+ bytes used to emit
# 16385 — one byte past the stated total, in survey.md and in the gap-prompt copy alike.
HB_D="$(new_repo)"
awk 'BEGIN{for(i=0;i<20000;i++)printf "a"; print ""}' > "$HB_D/big1.txt"
awk 'BEGIN{for(i=0;i<16384;i++)printf "a"; print ""}' > "$HB_D/big2.txt"
HB_N="$( set -u; eval "$headfn"; _il_survey_head "$HB_D/big1.txt" | wc -c | tr -d ' ' )"
eq "$HB_N" "16384" "25 a >16384-byte first line emits exactly 16384 bytes, newline included"
HB_N="$( set -u; eval "$headfn"; _il_survey_head "$HB_D/big2.txt" | wc -c | tr -d ' ' )"
eq "$HB_N" "16384" "25 …and an exactly-16384-byte first line does too (the -gt gate let it through whole)"

# The publish rename is proven against the held inode AFTER it happens: a swap of the private
# name in the window before mv used to publish the plant as survey.md under rc 0. The swap rides
# the rename itself, exactly where a surviving descendant would land it.
pubfn3="$(sed -n '/^_il_fd_close()/,/^}/p' "$IL"; sed -n '/^_il_inode()/,/^}/p' "$IL"; sed -n '/^_il_same_inode()/,/^}/p' "$IL"; sed -n '/^_il_excl_create()/,/^}/p' "$IL"; sed -n '/^_il_survey_head()/,/^}/p' "$IL"; sed -n '/^_il_publish_survey()/,/^}/p' "$IL")"
PV_D="$(new_repo)"
printf 'precious repo content\n' > "$PV_D/swap-target.txt"
printf 'a modest survey\n' > "$PV_D/.claude/state/survey-stage.md"
PV_OUT="$(
  eval "$pubfn3"
  mv() {
    local src="$1"; [ "$1" = "-f" ] && src="$2"
    case "$src" in */survey-held.w*) rm -f "$src"; ln -s ../../swap-target.txt "$src" ;; esac
    command mv "$@"
  }
  cd "$PV_D" && exec {sfd}<.claude/state/survey-stage.md \
    && _il_publish_survey .claude/state "$sfd" 2>/dev/null; printf 'RC=%s\n' "$?"
)"
if printf '%s\n' "$PV_OUT" | grep -q 'RC=0'; then
  bad "25 a private copy swapped before the publish rename is a FAILED publication (got rc 0)"; else ok; fi
if [ -L "$PV_D/.claude/state/survey.md" ] || [ -e "$PV_D/.claude/state/survey.md" ]; then
  bad "25 …and nothing is left at survey.md"; else ok; fi
eq "$(cat "$PV_D/swap-target.txt" 2>/dev/null)" "precious repo content" "25 …and the swap target is untouched"
if compgen -G "$PV_D/.claude/state/survey-held.w*" >/dev/null; then
  bad "25 …and no private copy is left behind"; else ok; fi

# ================= 26. the publish and the cap never reopen an agent-writable name (#435) =======
# role-dispatch's contract admits descendants can survive the CLI, so every check-then-reopen on
# survey-stage.md / survey-trace.md is a race a survivor can win: swap in a symlink and the reopen
# reads (or the publish rename ships) the plant; swap in a FIFO and the reopen blocks forever,
# outside every dispatch bound. The design answer is ONE bounded filename-open into a private
# mktemp copy, with every later byte coming from the copy.
#
# The race is made deterministic by shimming `wc`: the publisher's first post-validation tool call
# swaps the stage for a symlink, exactly as a surviving descendant would.
pubfn2="$(sed -n '/^_il_fd_close()/,/^}/p' "$IL"; sed -n '/^_il_inode()/,/^}/p' "$IL"; sed -n '/^_il_same_inode()/,/^}/p' "$IL"; sed -n '/^_il_excl_create()/,/^}/p' "$IL"; sed -n '/^_il_survey_head()/,/^}/p' "$IL"; sed -n '/^_il_publish_survey()/,/^}/p' "$IL")"
SW_D="$(new_repo)"
printf 'precious repo content\n' > "$SW_D/swap-target.txt"
printf 'a modest survey\n' > "$SW_D/.claude/state/survey-stage.md"
SW_OUT="$(
  eval "$pubfn2"
  wc() {
    command wc "$@"
    rm -f "$SW_D/.claude/state/survey-stage.md" 2>/dev/null
    ln -s ../../swap-target.txt "$SW_D/.claude/state/survey-stage.md" 2>/dev/null
  }
  cd "$SW_D" && exec {sfd}<.claude/state/survey-stage.md \
    && _il_publish_survey .claude/state "$sfd" 2>/dev/null; printf 'RC=%s\n' "$?"
)"
has "$SW_OUT" "RC=0" "26 the publish still succeeds when a descendant races it"
if [ -L "$SW_D/.claude/state/survey.md" ]; then
  bad "26 …but a link swapped in mid-publish shipped AS survey.md (a by-reference read for every later step)"; else ok; fi
eq "$(cat "$SW_D/swap-target.txt" 2>/dev/null)" "precious repo content" \
  "26 …and nothing wrote through the swapped link"

# The structural halves: after validation, the publisher's only stage-name operations are the one
# bounded filename-open and rm — never a shell redirect that reopens the public name — and the
# cap sizes the trace inside a bounded child by filename, never via a blocking `<` open.
if grep -q '< "\$dir/survey-stage.md"' "$IL"; then
  bad "26 a shell-redirect reopen of the public stage name is back in the lib"; else ok; fi
if grep -q 'wc -c < "\$dir/survey-trace.md"' "$IL"; then
  bad "26 the cap still sizes the trace through a blocking redirect open"; else ok; fi

# An oversized codex FINAL MESSAGE is refused BEFORE emission: the materialized result is sized
# and declined with a stated bound, not merely SIGPIPE'd into a downstream cap.
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && last="$a"
  prev="$a"
done
[ -n "$last" ] && dd if=/dev/zero bs=1024 count=9216 2>/dev/null | tr '\0' 'c' > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "codex"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
OC2_RC=$?
if [ "$OC2_RC" -ne 0 ]; then ok; else bad "26 a 9 MiB codex final message is a FAILED dispatch (got rc 0)"; fi
if grep -q 'result bound' "$d/.claude/state/survey.err" 2>/dev/null; then ok; else
  bad "26 …refused by the stated result bound before emission, not by downstream pipe collapse"; fi
rm -f "$shimbin/codex"

# ================= 27. private stages: exclusive create, held descriptor, no empty results ======
# mktemp-then-reopen and rm-then-redirect both left a gap between creating a stage name and
# opening it — a surviving same-UID descendant can fill the gap with a symlink and receive the
# write. Every private stage now goes through _il_excl_create: O_EXCL neither follows nor
# truncates, so a plant in the gap fails the open loudly, and the held descriptor binds the
# write to the created inode. (Observed red on the pre-fix lib: three mktemp survey-held sites
# and the .claim.tmp pathname redirect, and an empty rc-0 gap dispatch reported "gaps ok".)
if grep -q 'survey-held.XXXXXX' "$IL"; then
  bad "27 a mktemp-then-reopen survey stage is back in the lib"; else ok; fi
if grep -q '> "\$dir/\.claim' "$IL"; then
  bad "27 a pathname-redirect claim stage is back in the lib"; else ok; fi
# The helper's contract, driven to both answers: a clean create yields a held, writable
# descriptor on a regular file; a planted directory at the name (rm -f cannot remove it) fails
# the open loudly with nothing created; a resting planted link is removed first and the create
# lands fresh — rm is the point, O_EXCL guards the gap after it.
exfn="$(sed -n '/^_il_excl_create()/,/^}/p' "$IL")"
EX_D="$(mktemp -d "${TMPDIR:-/tmp}/adb-excl.XXXXXX")"
EX_OUT="$(
  eval "$exfn"
  fd=""
  if _il_excl_create "$EX_D/stage-a" fd; then
    printf 'created '
    printf 'hello' >&"$fd" && printf 'wrote '
    exec {fd}>&-
    [ -f "$EX_D/stage-a" ] && [ ! -L "$EX_D/stage-a" ] && printf 'regular '
    printf '%s' "$(cat "$EX_D/stage-a")"
  else printf 'create-failed'; fi
)"
eq "$EX_OUT" "created wrote regular hello" "27 a clean exclusive create yields a held, writable, regular stage"
mkdir "$EX_D/stage-b"
EX_OUT="$( eval "$exfn"; fd=""
  if _il_excl_create "$EX_D/stage-b" fd; then printf 'created'; else printf 'refused'; fi )"
eq "$EX_OUT" "refused" "27 a planted directory at the stage name fails the create loudly"
ln -s /nonexistent "$EX_D/stage-c"
EX_OUT="$( eval "$exfn"; fd=""
  if _il_excl_create "$EX_D/stage-c" fd; then
    exec {fd}>&-
    [ -f "$EX_D/stage-c" ] && [ ! -L "$EX_D/stage-c" ] && printf 'fresh'
  fi )"
eq "$EX_OUT" "fresh" "27 a resting planted link is removed and the create lands fresh"
rm -rf "$EX_D"
# An EMPTY result from a rc-0 gap or review dispatch is a failed dispatch: claude/gemini CLIs
# can exit 0 having written nothing (codex's arm refuses an empty final message; the others do
# not), and an empty analysis accepted as ok skips the retry-then-surface policy exactly as a
# missing one would.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GE_RC=$?
if [ "$GE_RC" -ne 0 ]; then ok; else bad "27 an EMPTY gap analysis from a rc-0 CLI is a failed dispatch (got rc 0)"; fi
read -r _ RVE <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVE/.claude/state"; seed_snap "$RVE"
( cd "$RVE" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
( cd "$RVE" && bash "$IL" dispatch-review .claude/state claude ) >/dev/null 2>&1
RE_RC=$?
if [ "$RE_RC" -ne 0 ]; then ok; else bad "27 an EMPTY review from a rc-0 CLI is a failed slot (got rc 0)"; fi
rm -f "$shimbin/claude"

# ================= 28. overflow is detected without SIGPIPE; no unbounded survey.md reopen ======
# A reply only slightly past the 8 MiB cap fits the pipe buffer after head stops reading, so the
# producer exits 0 with no SIGPIPE and an exactly-at-cap stage published as a silent truncation.
# The dispatch pipeline captures ONE BYTE PAST the cap, and the publisher refuses past-cap.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=8388708 count=1 2>/dev/null | tr '\0' 's'
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
OV2_RC=$?
if [ "$OV2_RC" -ne 0 ]; then ok; else
  bad "28 a reply 100 bytes past the cap that exits 0 (excess absorbed by the pipe buffer) is a FAILED dispatch (got rc 0)"; fi
if exists "$d/.claude/state/survey.md"; then
  bad "28 …and no truncated survey.md is published"; else ok; fi
rm -f "$shimbin/claude"
# The post-publish word count opens survey.md by filename inside a bounded child — never a
# shell-redirect open a FIFO swap could block forever, outside every dispatch bound.
if grep -q 'wc -w < "\$dir/survey.md"' "$IL"; then
  bad "28 an unbounded redirect open of the published survey is back in the lib"; else ok; fi
# …and the codex arm's result reads have the same contract: role-dispatch's own bounded-runner
# comment admits descendants can survive, so the size read and the emission both open $last by
# filename inside a bounded child, never a parent-shell redirect or a bare cat.
RD="$ROOT/scripts/lib/role-dispatch.sh"
if grep -q 'wc -c < "\$last"' "$RD"; then
  bad "28 the codex result size is read through an unbounded redirect open"; else ok; fi
if grep -Eq '^[[:space:]]*cat "\$last"' "$RD"; then
  bad "28 the codex result is emitted by a bare cat outside any bound"; else ok; fi

# ================= 29. prompts assemble through held descriptors; the word bound is enforced ====
# Every prompt build used to rm-then-redirect a fixed name and reopen it per append — the same
# swappable-pathname class the stages already left (#435 rounds passim). The builders now create
# their prompt exclusively (_il_excl_create) and thread the DESCRIPTOR through assembly; the
# dispatches feed stdin via a bounded filename cat and take their outputs on exclusive held
# descriptors. Structural: no pathname redirect of a prompt file remains in the lib.
if grep -Eq '(>>?|<) "\$pft?"' "$IL"; then
  bad "29 a pathname redirect of a prompt file is back in the lib"; else ok; fi
if grep -q 'invoke survey < ' "$IL" || grep -q 'invoke gap_analysis < ' "$IL"; then
  bad "29 a dispatch still opens its prompt via a parent-shell stdin redirect"; else ok; fi
# The 1500-word promise is enforced in the shared publisher: many short words stay under the
# 16 KiB byte head, and step 6 reads survey.md whole.
d="$(new_repo)"
awk 'BEGIN{for(i=0;i<500;i++){for(j=0;j<10;j++)printf "w%d ", i*10+j; print ""}}' \
  | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
WB_RC=$?
WB_W="$(wc -w < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
eq "$WB_RC" "0" "29 a 5000-word survey still publishes"
if [ -n "$WB_W" ] && [ "$WB_W" -le 1500 ]; then ok; else
  bad "29 …but survey.md carries ${WB_W:-none} words — past the promised 1500-word bound"; fi
if [ -f "$d/.claude/state/survey-overflow.md" ] \
   && [ "$(wc -w < "$d/.claude/state/survey-overflow.md" 2>/dev/null | tr -d ' ')" = "5000" ]; then
  ok; else bad "29 …and the full 5000-word reply is preserved at survey-overflow.md"; fi

# ================= 30. marker stages, the gap builder's survey copy, and open-pr's two gates ====
# The marker stage writes get the same exclusive held-descriptor create as every other private
# write, and the gap builder reads the published (agent-writable) survey through one bounded
# copy — never a parent-shell reopen of the public name.
if grep -q '> "\$dir/\.marker\.tmp"' "$IL"; then
  bad "30 a pathname-redirect marker stage is back in the lib"; else ok; fi
if grep -q '_il_survey_head "\$dir/survey.md"' "$IL" || grep -q 'wc -c < "\$dir/survey.md"' "$IL"; then
  bad "30 the gap builder still reopens the published survey by name"; else ok; fi
# gh honors GH_REPO/GH_HOST over the local checkout — a poisoned environment would aim the
# create at another repository while git push went to origin, and every later verification
# would consistently confirm the wrong target.
openpr GH_REPO="elsewhere/other" SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "30 a set GH_REPO is refused before anything is pushed"
has "$OP_OUT" "GH_REPO/GH_HOST is set" "30 …naming the environment override"
# A mistyped --closes number outside the marker's issue set would sail through the GitHub proof
# (which only confirms the same mistake registered) and close an unrelated issue on merge.
OP_OUT="$( cd "$PCLONE" && env SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS" \
  bash "$IL" open-pr .claude/state --title t --body-file body.md --closes 8 2>&1 )"; OP_RC=$?
eq "$OP_RC" "26" "30 a --closes number outside the marker's issue set refuses before the push"
has "$OP_OUT" "not in the run marker" "30 …naming the mismatch"
# The word-truncation slices the FIRST CROSSING LINE at the remaining budget wherever it is: a
# blank first line followed by one 2000-word line used to publish a one-newline survey.md and
# report survey ok 0 words — truncation recreating the rejected empty-summary outcome.
d="$(new_repo)"
{ printf '\n'; awk 'BEGIN{for(i=0;i<2000;i++)printf "w%d ", i; print ""}'; } \
  | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
WS_RC=$?
WS_W="$(wc -w < "$d/.claude/state/survey.md" 2>/dev/null | tr -d ' ')"
eq "$WS_RC" "0" "30 a blank-led over-budget survey still publishes"
eq "$WS_W" "1500" "30 …with the crossing line sliced at the remaining budget, never dropped whole"

# ================= 31. the round-37 tightenings: fail-closed gates and byte-capped results ======
# The marker's .issue set is validated with the strict grammar BEFORE any push — an absent,
# non-string or malformed set used to silently skip the membership gate (fail-open).
MSAVE="$(cat "$PCLONE/.claude/state/implement-issue-active.json")"
jq '.issue = 7' <<<"$MSAVE" > "$PCLONE/.claude/state/implement-issue-active.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "26" "31 a number-typed marker .issue refuses before the push, never skips the membership gate"
has "$OP_OUT" "no readable string .issue" "31 …naming the marker fault"
jq '.issue = "9,x"' <<<"$MSAVE" > "$PCLONE/.claude/state/implement-issue-active.json"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "26" "31 …and a malformed comma list refuses too"
printf '%s' "$MSAVE" > "$PCLONE/.claude/state/implement-issue-active.json"
# The untracked snapshot is created exclusively with its descriptor held — mktemp-then-reopen
# left the same swap window every other stage already closed.
if grep -q '_usnap="\$(mktemp' "$IL"; then
  bad "31 the untracked snapshot is back on mktemp-then-reopen"; else ok; fi
# The codex emitter is byte-capped one past the result bound: the size check is point-in-time,
# and a swap to a LARGER regular file after it would otherwise emit unbounded bytes into
# consumers that only bound time.
if grep -q 'adb_run_bounded 120 5 head -c 8388609 "\$last"' "$RD"; then ok; else
  bad "31 the codex emission is not byte-capped"; fi
# …and the gap/review slots refuse a past-cap result instead of accepting a silent truncation.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\0' 'g'
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GC_RC=$?
if [ "$GC_RC" -ne 0 ]; then ok; else bad "31 a 9 MiB gap analysis is a FAILED dispatch (got rc 0)"; fi
rm -f "$shimbin/claude"
# A RESTING symlink at the published survey is refused before the copy — the -s test and the
# copy both follow one, embedding arbitrary readable content as this run's survey.
d="$(new_repo)"; seed_snap "$d"
printf 'not the survey\n' > "$d/decoy.txt"
( cd "$d" && ln -s ../../decoy.txt .claude/state/survey.md ) >/dev/null 2>&1
( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 ) >/dev/null 2>&1
SL_RC=$?
if [ "$SL_RC" -ne 0 ]; then ok; else bad "31 a symlinked survey.md is refused, not embedded (got rc 0)"; fi
if grep -q 'not the survey' "$d/.claude/state/gap-prompt.txt" 2>/dev/null; then
  bad "31 …and the link target never reaches the gap prompt"; else ok; fi
# Zero padding is a spelling, stripped BEFORE the overflow-width guard: a fixed-width
# 0000000001 is one second, not an oversized value to replace with the 1500s share.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${ADB_DISPATCH_TIMEOUT_SECS:-unset}"
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "claude"\n' > "$d/agents.toml"
( cd "$d" && env ADB_SURVEY_TIMEOUT_SECS=0000000001 bash "$IL" dispatch-survey .claude/state 7 ) >/dev/null 2>&1
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "1" \
  "31 a wide zero-padded timeout is its number, not clamped to the share"
rm -f "$shimbin/claude"

# ================= 32. consumption-time validation: read-artifact, streamed caps, records =======
# The primary's by-name reads of published artifacts happen LONG after the dispatch, and a
# surviving descendant can swap the public name in between — read-artifact validates at the
# moment of consumption and the workflow routes every artifact read through it.
d="$(new_repo)"
printf 'the findings\n' > "$d/.claude/state/gaps.md"
RA_OUT="$( bash "$IL" read-artifact "$d/.claude/state" gaps 2>/dev/null )"; RA_RC=$?
eq "$RA_RC" "0" "32 a regular artifact reads clean"
eq "$RA_OUT" "the findings" "32 …emitting its content"
bash "$IL" read-artifact "$d/.claude/state" survey >/dev/null 2>&1
eq "$?" "10" "32 an absent optional artifact is 10, never an error"
printf 'SECRET\n' > "$d/decoy2.txt"
( cd "$d" && ln -s ../../decoy2.txt .claude/state/survey.md ) >/dev/null 2>&1
RA_OUT="$( bash "$IL" read-artifact "$d/.claude/state" survey 2>/dev/null )"; RA_RC=$?
eq "$RA_RC" "20" "32 a planted symlink at an artifact name is refused"
if [ -z "$RA_OUT" ]; then ok; else bad "32 …and the link target is never emitted"; fi
rm -f "$d/.claude/state/survey.md"
mkdir "$d/.claude/state/review.md"
bash "$IL" read-artifact "$d/.claude/state" review >/dev/null 2>&1
eq "$?" "20" "32 a planted directory at an artifact name is refused"
bash "$IL" read-artifact "$d/.claude/state" bogus >/dev/null 2>&1
eq "$?" "2" "32 an unknown artifact name is a usage error"
# …and the workflow routes all three artifact reads through it.
eq "$(grep -c 'read-artifact {{STATE_DIR}}' "$ROOT/base/workflows/implement-issue.md")" "3" \
  "32 the workflow reads gaps, survey and review via read-artifact"
# The gap and review dispatches stream their results through the byte cap WHILE writing — a
# runaway would otherwise materialize until the time limit with the filesystem already gone.
eq "$(grep -c 'head -c 8388609 1>&"\$_gofd"' "$IL")" "1" "32 the gap result is byte-capped in-stream"
eq "$(grep -c 'head -c 8388609 1>&"\$_rofd"' "$IL")" "2" "32 …and both review slot arms are"
# The envelope reads open by filename inside a bounded child — they run after the survey
# dispatch, where a FIFO swap at the snapshot names must expire a bound, never hang assembly.
if grep -q 'assoc="\$(cat "\$dir/issue-\$n.assoc"' "$IL"; then
  bad "32 the envelope association read is back on an unbounded parent-shell open"; else ok; fi
# Every untracked entry produces a review record: an empty file (rc 0, no patch) and a symlink
# to a directory (rc 1, no patch) both used to vanish from the review prompt.
read -r _ RVU <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVU/.claude/state"; seed_snap "$RVU"
( cd "$RVU" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
: > "$RVU/empty-untracked.txt"
mkdir "$RVU/somedir"; ( cd "$RVU" && ln -s somedir dirlink ) >/dev/null 2>&1
( cd "$RVU" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "32 the review prompt builds over empty and non-regular untracked entries"
if grep -q 'empty-untracked.txt' "$RVU/.claude/state/review-prompt.txt" 2>/dev/null; then
  ok; else bad "32 …and the empty untracked file appears as a record"; fi
if grep -q 'dirlink' "$RVU/.claude/state/review-prompt.txt" 2>/dev/null; then
  ok; else bad "32 …and the non-regular entry appears as a record"; fi
# gh's configured default (gh repo set-default) aims unqualified creates elsewhere even with the
# env clean — a parseable origin pins every gh call with -R; the fixture's local-path origin
# takes the stated fallback.
if grep -q 'gh pr create "\${_rflag\[@\]}"' "$IL"; then ok; else
  bad "32 gh pr create is not pinned to the origin-derived slug"; fi
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "32 a local-path origin still opens (the stated fallback)"
has "$OP_OUT" "not a recognizable forge remote" "32 …with the fallback NOTEd, never silent"

# ================= 33. numbered slots read, the native stage held, the base pinned ==============
# --slot N writes review-N.md and the workflow forbids direct opens — without a numbered arm in
# read-artifact, later reviewers' findings were unreadable through the one permitted reader.
d="$(new_repo)"
printf 'slot two findings\n' > "$d/.claude/state/review-2.md"
RA_OUT="$( bash "$IL" read-artifact "$d/.claude/state" review-2 2>/dev/null )"; RA_RC=$?
eq "$RA_RC" "0" "33 a numbered review slot reads clean"
eq "$RA_OUT" "slot two findings" "33 …emitting its content"
bash "$IL" read-artifact "$d/.claude/state" review-x >/dev/null 2>&1
eq "$?" "2" "33 a non-numeric slot suffix is a usage error"
bash "$IL" read-artifact "$d/.claude/state" review-12345 >/dev/null 2>&1
eq "$?" "2" "33 …and a 5-digit one is outside the family grammar"
# The native publisher's stage gets the same exclusive held-descriptor create as the CLI path —
# rm-then-redirect left the swap window everywhere else already closed.
if grep -q 'head -c 8388609 > "\$dir/survey-stage.md"' "$IL"; then
  bad "33 the native survey stage is back on rm-then-redirect"; else ok; fi
printf 'native reply\n' | ( cd "$d" && bash "$IL" publish-survey .claude/state ) >/dev/null 2>&1
eq "$?" "0" "33 the native publish still works through the held descriptor"
eq "$(cat "$d/.claude/state/survey.md" 2>/dev/null)" "native reply" "33 …publishing the reply"
# gh consults branch.<name>.gh-merge-base BEFORE the repository default when --base is omitted,
# and no later guard validates the base — the create pins it explicitly.
if grep -q 'gh pr create "\${_rflag\[@\]}" --base "\$_pbase"' "$IL"; then ok; else
  bad "33 gh pr create does not pin --base to the synchronized default"; fi
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "33 the pinned-base create still opens against the fixture"

# ================= 34. round-40: adopted bases, slot grammar, one-inode reads, expiry width =====
# An ADOPTED PR must meet the same base bar as a created one — the closing-link proof and both
# merge guards never validate the base, so adopting an open PR aimed at a release branch would
# arm a merge into a branch nobody synchronized.
openpr SHIM_SLUG="o/r" SHIM_CREATE_FAIL=1 SHIM_ADOPT_BASE=release-1 SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "34 an open PR on a foreign base is refused, never adopted"
has "$OP_OUT" 'targets base "release-1"' "34 …naming both branches"
openpr SHIM_SLUG="o/r" SHIM_CREATE_FAIL=1 SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "34 …while a default-based open PR still adopts"
# The --slot writer speaks the reader's exact 1-4 digit grammar — a wider slot published a name
# read-artifact refuses, leaving that slot's findings unreadable at triage.
d="$(new_repo)"; seed_snap "$d"
( cd "$d" && bash "$IL" dispatch-review --slot 12345 --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "2" "34 a 5-digit slot is refused at dispatch, matching the reader"
# read-artifact copies ONCE through a held descriptor and validates/emits the copy — sizing and
# emitting the public name as two separate opens left a swap window.
if grep -q '"\$dir/\.artifact\.w\$\$"' "$IL"; then ok; else
  bad "34 read-artifact no longer stages through a private held copy"; fi
d="$(new_repo)"
printf 'still fine\n' > "$d/.claude/state/gaps.md"
RA_OUT="$( bash "$IL" read-artifact "$d/.claude/state" gaps 2>/dev/null )"; RA_RC=$?
eq "$RA_RC" "0" "34 the staged read still emits a clean artifact"
eq "$RA_OUT" "still fine" "34 …byte-exact"
if ls "$d/.claude/state"/.artifact.* >/dev/null 2>&1; then
  bad "34 …with no staging residue"; else ok; fi
# Renewal applies admission's 10-digit expiry width bound: a wider value wraps bash arithmetic
# and revived a claim admission treats as immediately breakable.
d="$(new_repo)"; seed_snap "$d"
printf '{"startedAt":1,"expiresAt":9223372036854775807,"token":"tokT"}' > "$d/.claude/state/gap-analysis.lock"
( cd "$d" && bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 ) >/dev/null 2>&1
eq "$?" "13" "34 a wider-than-timestamp expiry is an unreadable lease, never a live one"

# ================= 35. round-41: one-inode reads proven, renewal reads one copy, head pinned ====
# read-artifact's read descriptors are opened at creation and proven one inode with -ef — after
# that, size and emission never touch a pathname, so the predictable stage name has nothing left
# to redirect. (The round-40 shape closed the write fd then reopened the name for wc and cat.)
if grep -q -- '-ef "/dev/fd/\$_rfd1"' "$IL"; then ok; else
  bad "35 read-artifact no longer proves its descriptors share one inode"; fi
if grep -q 'wc -c "\$_cp"' "$IL" || grep -q 'cat "\$_cp"' "$IL"; then
  bad "35 a pathname reopen of the read stage is back"; else ok; fi
d="$(new_repo)"
printf 'inode-held\n' > "$d/.claude/state/gaps.md"
RA_OUT="$( bash "$IL" read-artifact "$d/.claude/state" gaps 2>/dev/null )"; RA_RC=$?
eq "$RA_RC" "0" "35 the inode-held read emits a clean artifact"
eq "$RA_OUT" "inode-held" "35 …byte-exact"
# Renewal parses token and expiry from ONE bounded in-memory copy of the lock — two parent
# jq opens could observe two inodes, and a FIFO swap would block the shell HOLDING THE MUTEX.
if grep -q "jq -r '.token // \"\"' \"\$dir/\$_IL_CLAIM\"" "$IL"; then
  bad "35 the renewal still opens the lock per-field by pathname"; else ok; fi
if grep -q 'adb_run_bounded 30 5 cat "\$dir/\$_IL_CLAIM"' "$IL"; then ok; else
  bad "35 the renewal's one bounded lock read is gone"; fi
# gh pr create pins --head (gh defaults to the CURRENT branch at creation time), and the
# recorded PR's head is verified through its URL before anything records it.
if grep -q -- '--head "\$branch"' "$IL"; then ok; else
  bad "35 gh pr create does not pin --head to the marker branch"; fi
openpr SHIM_SLUG="o/r" SHIM_HEAD_REF="some-other-branch" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "35 a created PR whose head is not the marker branch is refused, never recorded"
has "$OP_OUT" 'has head "some-other-branch"' "35 …naming both branches"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "35 …while a matching head still records"
# The native survey path names its ENFORCED backstop: publish-survey's lease re-verification.
if grep -q 'ENFORCED backstop is the claim lease' "$ROOT/base/workflows/implement-issue.md"; then
  ok; else bad "35 the native-path bound is narrated without naming its enforcement"; fi

# ================= 36. round-42: the last pathname reopens, and the pushed tip pinned ===========
# The renewal's publication transform reads the validated in-memory snapshot, never the lock
# pathname — a reopen there could hang holding the mutex or publish over a successor.
if grep -qF "jq --argjson e \"\$(( now + lease ))\" '.expiresAt = \$e' \"\$dir/\$_IL_CLAIM\"" "$IL"; then
  bad "36 the renewal transform is back on the lock pathname"; else ok; fi
# read-artifact re-validates the source AFTER the copy — a symlink swapped between the pre-check
# and head's open was followed into the copy, and a plant that persists is caught and discarded.
if grep -q 'changed shape during the read' "$IL"; then ok; else
  bad "36 read-artifact never re-validates its source after the copy"; fi
d="$(new_repo)"; printf 'x\n' > "$d/target-ra.txt"
( cd "$d" && ln -s ../../target-ra.txt .claude/state/gaps.md ) >/dev/null 2>&1
bash "$IL" read-artifact "$d/.claude/state" gaps >/dev/null 2>&1
eq "$?" "20" "36 a resting link is still refused before any copy"
# The push sends the CAPTURED SHA (sha:ref), and the PR's headRefOid must equal it — ref-name
# checks alone pass even when a concurrent process advanced the branch past the reviewed tip.
if grep -q 'git push origin "\$_tip:refs/heads/\$branch"' "$IL"; then ok; else
  bad "36 the push sends a ref name, not the captured tip"; fi
openpr SHIM_SLUG="o/r" SHIM_HEAD_OID="0000000000000000000000000000000000000000" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "25" "36 a PR whose head OID is not the pushed tip is refused, never recorded"
has "$OP_OUT" "the branch moved since the reviewed tip" "36 …saying what happened"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "36 …while the matching tip still records"
# The untracked-snapshot loop iterates the held inode (-ef proven at creation), never the
# predictable pathname.
if grep -q 'done 0<&"\$_urfd"' "$IL"; then ok; else
  bad "36 the untracked loop is back on a pathname reopen"; fi

# ================= 37. round-43: bounded untracked diffs, verified canonical publishes ==========
# A gigabyte untracked file used to materialize whole in a shell variable and then in the
# prompt — the diff is byte-capped before capture, and past-cap refuses with the path named.
d="$(new_repo)"
read -r _ RVB <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVB/.claude/state"; seed_snap "$RVB"
( cd "$RVB" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\0' 'u' > "$RVB/huge-untracked.txt"
UB_OUT="$( cd "$RVB" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; UB_RC=$?
eq "$UB_RC" "20" "37 a 9 MiB untracked file refuses the review prompt"
has "$UB_OUT" "diffs past the 8388608-byte bound" "37 …naming the bound and the remedy"
rm -f "$RVB/huge-untracked.txt"
( cd "$RVB" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>&1
eq "$?" "0" "37 …and the prompt builds again without it"
# The canonical publishes VERIFY the result: mv -f onto a directory swapped in at the claim or
# marker name succeeds by moving the stage INSIDE it (BSD mv has no -T), and the caller would
# proceed leaseless or phase-less. The marker twin is deterministic: a directory at the marker
# name must fail the phase write, never report ok.
phasefn="$(sed -n '/^_il_excl_create()/,/^}/p' "$IL"; sed -n '/^_il_phase()/,/^}/p' "$IL")"
PH_D="$(new_repo)"
mkdir "$PH_D/.claude/state/implement-issue-active.json"
PH_RC="$( cd "$PH_D" && eval "$phasefn" || exit 99
  _IL_MARKER="implement-issue-active.json"
  _il_phase .claude/state pushed >/dev/null 2>&1; printf '%s' "$?" )"
if [ "$PH_RC" != "0" ]; then ok; else
  bad "37 a directory swapped at the marker name reports a successful phase write"; fi
if grep -q 'rm -f "\$dir/\$_IL_CLAIM/\${_cst##\*/}"' "$IL"; then ok; else
  bad "37 a mv-inside leaves the claim stage inside the planted directory forever"; fi

# ================= 38. round-44: sizing failures fail, stage fd held, marker copies, prompt cap =
# An unsizable rc-0 result (a permission flip, a swap) used to leave the inline arithmetic
# quietly false and report gaps ok over an artifact read-artifact refuses.
cat > "$shimbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'gap findings\n'
chmod 000 .claude/state/gaps.md 2>/dev/null
exit 0
SH
chmod +x "$shimbin/claude"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "claude"\n' > "$d/agents.toml"
( cd "$d" && bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GU_RC=$?
chmod 644 "$d/.claude/state/gaps.md" 2>/dev/null
if [ "$GU_RC" -ne 0 ]; then ok; else
  bad "38 an unsizable rc-0 gap result is a FAILED dispatch (got rc 0)"; fi
rm -f "$shimbin/claude"
# The survey publisher reads the stage from the descriptor its caller has held since creation
# (-ef proven) — the -L pre-check and a filename open were two moments a link could slip between.
if grep -q 'head -c 8388609 0<&"\$_sfd"' "$IL"; then ok; else
  bad "38 the publisher is back on a pathname open of the stage"; fi
# open-pr's marker fields, the blocked guard, dispatch-review's issue list and _il_phase all
# parse bounded in-memory copies — a FIFO at a marker name must expire a bound, never hang.
if grep -qF 'jq -er '"'"'if (.branch | type) == "string"'"'"' "$dir/$_IL_MARKER"' "$IL"; then
  bad "38 a pathname marker read is back in open-pr"; else ok; fi
if grep -c 'adb_run_bounded 30 5 cat "\$dir/\$_IL_MARKER"' "$IL" | grep -q '^[4-9]'; then ok; else
  bad "38 fewer than four bounded marker copies remain — a pathname read came back"; fi
# The review prompt has a CUMULATIVE cap: a giant tracked diff refuses in-stream, and the
# assembled prompt refuses past 16 MiB before publication.
read -r _ RVT <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVT/.claude/state"; seed_snap "$RVT"
( cd "$RVT" && git switch -q -c issue-7-t \
  && dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\0' 't' > big-tracked.txt \
  && git add big-tracked.txt && git commit -qm big ) >/dev/null 2>&1
TB_OUT="$( cd "$RVT" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; TB_RC=$?
eq "$TB_RC" "20" "38 a 9 MiB tracked diff refuses the review prompt"
has "$TB_OUT" "split the change" "38 …naming the remedy"
if grep -q '16777216-byte cap' "$IL"; then ok; else
  bad "38 the assembled prompt has no cumulative cap"; fi

# ================= 39. the slot reads its own stage; the tracked diff is measured ===============
# A slot's invocation is fed from a descriptor held on ITS stage inode: concurrent slots each
# publish the same shared name, and a slot that reopened it by name could find it absent — or
# another slot's copy — between its own publish and its cat. The other slot's `rm -rf` is made
# deterministic by an mv shim that removes the published name right after the publish rename.
mkdir -p "$work/mvswap"
cat > "$work/mvswap/mv" <<'SH'
#!/usr/bin/env bash
/bin/mv "$@"; rc=$?
for a in "$@"; do case "$a" in */review-prompt.txt) rm -rf "$a" ;; esac; done
exit $rc
SH
chmod +x "$work/mvswap/mv"
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
if grep -q 'diff --git a/seed'; then out='SAW-PROMPT'; else out='NO-PROMPT'; fi
[ -n "$last" ] && printf '%s\n' "$out" > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
read -r _ RVS <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVS/.claude/state"; seed_snap "$RVS"
( cd "$RVS" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
( cd "$RVS" && env PATH="$work/mvswap:$PATH" bash "$IL" dispatch-review .claude/state codex ) >/dev/null 2>&1
SL_RC=$?
eq "$SL_RC" "0" "39 a slot whose published prompt name vanishes right after its publish still completes"
eq "$(cat "$RVS/.claude/state/review.md" 2>/dev/null)" "SAW-PROMPT" "39 …and the reviewer received THIS slot's prompt from the held stage inode"
rm -f "$shimbin/codex"
eq "$(grep -c 'cat <&"\$_prfd"' "$IL")" "2" "39 both slot arms read the held stage descriptor"
if grep -q '2700 5 cat "\$pf"' "$IL"; then bad "39 a slot arm reopens the published prompt name"; else ok; fi
# THE TRACKED DIFF IS MEASURED, never trusted to the producer's status: a diff a few hundred
# bytes past the bound finishes into the pipe buffer before head closes, so git exits 0 and the
# truncated sentinel prefix used to publish as "the diff".
read -r _ RVB <<EOF
${ remote_pair; }
EOF
mkdir -p "$RVB/.claude/state"; seed_snap "$RVB"
( cd "$RVB" && git switch -q -c issue-7-t \
  && awk 'BEGIN{for(i=0;i<8388672;i++)printf "a"; print ""}' > big-line.txt \
  && git add big-line.txt && git commit -qm big ) >/dev/null 2>&1
BL_OUT="$( cd "$RVB" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; BL_RC=$?
eq "$BL_RC" "20" "39 a tracked diff a few hundred bytes past the bound refuses (git exits 0 — the excess fits the pipe buffer)"
has "$BL_OUT" "exceeds the 8388608-byte bound" "39 …naming the bound"
if [ -e "$RVB/.claude/state/review-prompt.txt" ]; then
  bad "39 …and publishes no truncated prompt"; else ok; fi

# ================= 40. round 47: held prompt inodes, the kept prompt-only stage, measured =======
# =================     untracked records, and no push over an unclean worktree ==================
# The survey and gap invocations read the descriptor held since their prompt's creation, never
# the name a surviving descendant could swap between the write side closing and the cat.
eq "$(grep -c 'cat <&"\$_gprfd"' "$IL")" "2" "40 the gap invocation and the prompt-only copy both read the held prompt descriptor"
eq "$(grep -c 'cat <&"\$_sprfd"' "$IL")" "2" "40 …and so do the survey's"
if grep -q '5 cat "\$pf"' "$IL"; then bad "40 a dispatch still feeds its agent by reopening the prompt name"; else ok; fi
# …observed: a plant swapped in at the prompt name AFTER the write side closed and BEFORE the
# invocation (the window is made deterministic by an rm shim riding the result file's exclusive
# create, which sits between the two) must not reach the agent — it reads the held inode.
mkdir -p "$work/rmswap"
cat > "$work/rmswap/rm" <<'SH'
#!/usr/bin/env bash
/bin/rm "$@"; rc=$?
for a in "$@"; do case "$a" in */gaps.md)
  d="${a%/gaps.md}"; /bin/rm -f "$d/gap-prompt.txt"; printf 'PLANTED-PROMPT\n' > "$d/gap-prompt.txt" ;;
esac; done
exit $rc
SH
chmod +x "$work/rmswap/rm"
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
if grep -q 'PLANTED-PROMPT'; then out='SAW-PLANT'; else out='SAW-PROMPT'; fi
[ -n "$last" ] && printf '%s\n' "$out" > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\ngap_analysis = "codex"\n' > "$d/agents.toml"
( cd "$d" && env PATH="$work/rmswap:$PATH" bash "$IL" dispatch-gaps .claude/state 7 ) >/dev/null 2>&1
GP_RC=$?
eq "$GP_RC" "0" "40 the gap dispatch completes with a plant swapped in at the prompt name"
eq "$(cat "$d/.claude/state/gaps.md" 2>/dev/null)" "SAW-PROMPT" "40 …and the agent received the contained prompt from the held inode, never the plant"
rm -f "$shimbin/codex"
# A --prompt-only review hands its consumer a per-invocation file — the kept stage — not the
# shared name a concurrent slot's publish can remove: the printed path survives that removal.
read -r _ RPO <<EOF
${ remote_pair; }
EOF
mkdir -p "$RPO/.claude/state"; seed_snap "$RPO"
( cd "$RPO" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
PO_OUT="$( cd "$RPO" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>/dev/null )"; PO_RC=$?
eq "$PO_RC" "0" "40 a prompt-only build succeeds"
PO_PATH="${PO_OUT#prompt-ready }"
if [ "$PO_PATH" = ".claude/state/review-prompt.txt" ]; then
  bad "40 prompt-only hands back the shared name"; else ok; fi
case "$PO_PATH" in .claude/state/review-prompt-stage.*) ok ;; *) bad "40 prompt-only's path is not its own kept stage ($PO_PATH)" ;; esac
if [ -f "$RPO/$PO_PATH" ] && [ ! -L "$RPO/$PO_PATH" ]; then ok; else bad "40 …and that path is a regular file"; fi
if cmp -s "$RPO/$PO_PATH" "$RPO/.claude/state/review-prompt.txt"; then ok; else
  bad "40 …with the same bytes as the shared publication"; fi
rm -rf "$RPO/.claude/state/review-prompt.txt"   # the other slot's rm -rf
has "$(cat "$RPO/$PO_PATH" 2>/dev/null)" 'diff --git a/seed' "40 …and it still reads after the shared name is removed"
# An untracked record is measured by descriptor, never through command substitution: a record
# whose 8388609th byte is a newline used to lose it to the substitution, measure as exactly the
# bound, and publish a truncated patch. The fixture sizes a one-line file so the --no-index diff
# is exactly 8388609 bytes and ends in that newline, and proves it before asserting.
read -r _ RNL <<EOF
${ remote_pair; }
EOF
mkdir -p "$RNL/.claude/state"; seed_snap "$RNL"
( cd "$RNL" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
printf 'a\n' > "$RNL/nl.txt"
NL_HDR="$(( $(cd "$RNL" && git diff --no-index -- /dev/null nl.txt | wc -c | tr -d ' ') - 3 ))"   # the diff of one 'a' line, minus its "+a\n"
awk -v n="$(( 8388609 - NL_HDR - 2 ))" 'BEGIN{for(i=0;i<n;i++)printf "a"; print ""}' > "$RNL/nl.txt"
NL_SZ="$(cd "$RNL" && git diff --no-index -- /dev/null nl.txt | wc -c | tr -d ' ')"
eq "$NL_SZ" "8388609" "40 fixture: the untracked diff is exactly one byte past the bound"
NL_LAST="$(cd "$RNL" && git diff --no-index -- /dev/null nl.txt | tail -c 1 | od -An -c | tr -d ' ')"
eq "$NL_LAST" '\n' "40 fixture: …and that byte is a newline"
NL_OUT="$( cd "$RNL" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; NL_RC=$?
eq "$NL_RC" "20" "40 an untracked record exactly one byte past the bound, ending in a newline, refuses"
has "$NL_OUT" "diffs past the 8388608-byte bound" "40 …naming the bound"
rm -f "$RNL/nl.txt"
# open-pr refuses an unclean worktree BEFORE anything is pushed: dispatch-review reviews the
# worktree-inclusive diff, so an uncommitted or untracked change here means the pushed tip is
# not the reviewed tree.
printf 'unpushed-fix\n' >> "$PCLONE/seed"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "27" "40 an uncommitted tracked change refuses open-pr (27)"
has "$OP_OUT" "reviewed tree is not the tip" "40 …naming why"
if printf '%s\n' "$OP_OUT" | grep -q 'pushed issue-9-x'; then
  bad "40 …and nothing was pushed"; else ok; fi
( cd "$PCLONE" && git checkout -q -- seed ) >/dev/null 2>&1   # a fixture file this case appended to; no untracked work at risk
printf 'stray\n' > "$PCLONE/stray-helper.txt"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "27" "40 an untracked non-ignored file refuses open-pr (27) too"
rm -f "$PCLONE/stray-helper.txt"
openpr SHIM_SLUG="o/r" SHIM_PR_URL="https://github.com/o/r/pull/5" SHIM_CLOSING_JSON="$GOODREFS"
eq "$OP_RC" "0" "40 …and a clean worktree opens as before"

# ================= 41. round 48: held snapshot reads pinned to origin, per-invocation prompt =====
# =================     copies, the aggregate cap during assembly, a literal protected compare ==
# The issue state is read from a descriptor held since the snapshot's creation: a replacement
# landing between the two gh reads (the shim performs one) used to be what the state check read.
d="$(new_repo)"; gid "$d"; clm "$d"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON" SHIM_SNAP_SWAP="$d/.claude/state/issue-7.json"
eq "$SN_RC" "0" "41 a snapshot replaced after its fetch is still judged by the fetched bytes (OPEN)"
has "$SN_OUT" "snapshot #7 OPEN OWNER" "41 …reporting the fetched state, not the replacement's"
# Both snapshot reads are pinned to the checkout origin: gh's GH_REPO or configured default
# would otherwise snapshot — and the run implement — a foreign repository's issue #7.
d="$(new_repo)"; gid "$d"; clm "$d"
git -C "$d" remote add origin git@github.com:o/r.git >/dev/null 2>&1
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON" SHIM_ARGS_LOG="$d/gh-args.log"
eq "$SN_RC" "0" "41 a forge origin snapshots cleanly"
has "$(cat "$d/gh-args.log" 2>/dev/null)" "issue view 7 -R github.com/o/r" "41 …with the issue read pinned to origin"
has "$(cat "$d/gh-args.log" 2>/dev/null)" "api --hostname github.com repos/o/r/issues/7" "41 …and the association read pinned to the same host and slug"
d="$(new_repo)"; gid "$d"; clm "$d"
snap "$d" SHIM_ISSUE_JSON="$ISSUE_JSON"
eq "$SN_RC" "0" "41 …while a checkout with no forge origin takes the stated fallback"
has "$SN_OUT" "not a recognizable forge remote" "41 …and NOTEs it"
# The prompt-only survey and gap builds hand their consumer a per-invocation copy inside the
# swept family, never the shared name a surviving descendant can replace.
d="$(new_repo)"; seed_snap "$d"
SP_OUT="$( cd "$d" && bash "$IL" dispatch-survey --prompt-only .claude/state 7 2>/dev/null )"; SP_RC=$?
eq "$SP_RC" "0" "41 a prompt-only survey builds"
SP_PATH="${SP_OUT#prompt-ready }"
case "$SP_PATH" in .claude/state/survey-held.*p) ok ;; *) bad "41 the survey prompt-only path is not a per-invocation family copy ($SP_PATH)" ;; esac
if [ -f "$d/$SP_PATH" ] && cmp -s "$d/$SP_PATH" "$d/.claude/state/survey-prompt.txt"; then ok; else
  bad "41 …with the same bytes as the shared survey prompt"; fi
rm -rf "$d/.claude/state/survey-prompt.txt"
has "$(cat "$d/$SP_PATH" 2>/dev/null)" 'github-issue #7' "41 …and it still reads after the shared name is removed"
GP_OUT="$( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 2>/dev/null )"; GP_RC=$?
eq "$GP_RC" "0" "41 a prompt-only gap build builds"
GP_PATH="${GP_OUT#prompt-ready }"
case "$GP_PATH" in .claude/state/gaps-held.*p) ok ;; *) bad "41 the gap prompt-only path is not a per-invocation family copy ($GP_PATH)" ;; esac
rm -rf "$d/.claude/state/gap-prompt.txt"
has "$(cat "$d/$GP_PATH" 2>/dev/null)" 'github-issue #7' "41 …and it still reads after the shared gap prompt is removed"
# The aggregate cap is enforced as the stage grows: four 6 MiB untracked files used to be
# appended in full (24 MiB on disk) before the post-assembly check refused.
read -r _ RAG <<EOF
${ remote_pair; }
EOF
mkdir -p "$RAG/.claude/state"; seed_snap "$RAG"
( cd "$RAG" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
for i in 1 2 3 4; do dd if=/dev/zero bs=1048576 count=6 2>/dev/null | tr '\0' 't' > "$RAG/u$i.txt"; done
AG_OUT="$( cd "$RAG" && bash "$IL" dispatch-review --prompt-only .claude/state codex 2>&1 )"; AG_RC=$?
eq "$AG_RC" "20" "41 many sub-bound untracked records refuse once the aggregate crosses the cap"
has "$AG_OUT" "while assembling, at untracked u3.txt" "41 …at the record that crossed it, before the rest was appended"
rm -f "$RAG"/u?.txt
# The protected-branch test is a literal compare and a static glob, never the default branch
# interpolated into an ERE.
if grep -q 'grep -qE "\$protected"' "$IL"; then bad "41 the protected-branch test still interpolates a regex"; else ok; fi
has "$(cat "$IL")" '[ "$b" = "$db" ] && continue' "41 …and compares the default branch literally"

# ================= 42. round 49: copies from the held inode, unsizable survey fails, the mutex ==
# =================     take needs its mark, issue text is bounded in-stream =====================
# The per-invocation prompt copy is written from the held descriptor: a plant swapped in at the
# shared name the moment the write side closes (an rm shim rides the copy's exclusive create,
# which sits exactly there) must not be what the consumer receives.
mkdir -p "$work/rmswap2"
cat > "$work/rmswap2/rm" <<'SH'
#!/usr/bin/env bash
/bin/rm "$@"; rc=$?
for a in "$@"; do case "$a" in */survey-held.w*p)
  d="${a%/survey-held.w*}"; /bin/rm -f "$d/survey-prompt.txt"; printf 'PLANTED-PROMPT\n' > "$d/survey-prompt.txt" ;;
esac; done
exit $rc
SH
chmod +x "$work/rmswap2/rm"
d="$(new_repo)"; seed_snap "$d"
SC_OUT="$( cd "$d" && env PATH="$work/rmswap2:$PATH" bash "$IL" dispatch-survey --prompt-only .claude/state 7 2>/dev/null )"; SC_RC=$?
eq "$SC_RC" "0" "42 a prompt-only survey still builds with a plant swapped in at the shared name"
SC_PATH="${SC_OUT#prompt-ready }"
has "$(cat "$d/$SC_PATH" 2>/dev/null)" 'github-issue #7' "42 …and the consumer's copy carries the validated prompt"
hasnt "$(cat "$d/$SC_PATH" 2>/dev/null)" 'PLANTED-PROMPT' "42 …never the plant"
# A survey that cannot be sized after publication is FAILED, never "survey ok 0 words": the wc
# shim answers as GNU wc does for a directory (a 0 count line, exit 1).
mkdir -p "$work/wcfail"
cat > "$work/wcfail/wc" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */survey.md) printf '0 %s\n' "$a"; exit 1 ;; esac; done
exec /usr/bin/wc "$@"
SH
chmod +x "$work/wcfail/wc"
d="$(new_repo)"; seed_snap "$d"
WF_OUT="$( printf 'native survey reply\n' | ( cd "$d" && env PATH="$work/wcfail:$PATH" bash "$IL" publish-survey .claude/state ) 2>&1 )"; WF_RC=$?
eq "$WF_RC" "20" "42 an unsizable published survey fails the native publish (20)"
has "$WF_OUT" "could not be sized after publication" "42 …naming why"
hasnt "$WF_OUT" "survey ok" "42 …and never reports it ok"
cat > "$shimbin/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
[ -n "$last" ] && printf 'cli survey reply\n' > "$last"
exit 0
SH
chmod +x "$shimbin/codex"
d="$(new_repo)"; seed_snap "$d"
printf '[roles]\nsurvey = "codex"\n' > "$d/agents.toml"
WC_OUT="$( cd "$d" && env PATH="$work/wcfail:$PATH" bash "$IL" dispatch-survey .claude/state 7 2>&1 )"; WC_RC=$?
eq "$WC_RC" "20" "42 …and the CLI dispatch path fails the same way (20)"
hasnt "$WC_OUT" "survey ok" "42 …without a success record"
rm -f "$shimbin/codex"
# The mutex take needs its owner mark: a take whose mark cannot be written used to enter the
# critical section unreleasably, wedging every later take until the stale age.
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: 42 the unwritable-mark case cannot fire as root\n'
else
  mutexfn="$(sed -n '/^_IL_CLAIM_MUTEX=/p' "$IL"; sed -n '/^_il_claim_mutex_take()/,/^}/p' "$IL"; sed -n '/^_il_claim_mutex_drop()/,/^}/p' "$IL")"
  MX_D="$(mktemp -d "$work/mx.XXXXXX")"
  MX_RC="$(
    eval "$mutexfn"
    mkdir() { command mkdir "$@" && chmod 555 "${@: -1}"; }
    _il_claim_mutex_take "$MX_D" >/dev/null 2>&1; printf '%s' "$?"
  )"
  eq "$MX_RC" "1" "42 a take whose owner mark cannot be written FAILS instead of entering unreleasably"
  if [ -d "$MX_D/.claim-mutex" ]; then bad "42 …and the just-taken instance is released, not left to wedge later takes"; else ok; fi
fi
# Issue text is bounded IN-STREAM before any prompt is materialized: a 9 MiB issue body refuses
# at the per-issue bound, and three 6 MiB issues refuse at the 16 MiB aggregate — where the old
# code built the whole prompt (and the survey and gap builders had no aggregate cap at all).
d="$(new_repo)"
dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\0' 'b' > "$d/big.txt"
jq -n --rawfile b "$d/big.txt" '{state:"OPEN",title:"t",body:$b,author:{login:"alice"},comments:[]}' > "$d/.claude/state/issue-7.json"
printf 'OWNER' > "$d/.claude/state/issue-7.assoc"
BI_OUT="$( cd "$d" && bash "$IL" dispatch-survey --prompt-only .claude/state 7 2>&1 )"; BI_RC=$?
eq "$BI_RC" "20" "42 a 9 MiB issue body refuses the survey prompt (20)"
has "$BI_OUT" "exceeds the 8388608-byte bound" "42 …at the per-issue bound"
d="$(new_repo)"
dd if=/dev/zero bs=1048576 count=6 2>/dev/null | tr '\0' 'b' > "$d/mid.txt"
for n in 7 8 9; do
  jq -n --rawfile b "$d/mid.txt" '{state:"OPEN",title:"t",body:$b,author:{login:"alice"},comments:[]}' > "$d/.claude/state/issue-$n.json"
  printf 'OWNER' > "$d/.claude/state/issue-$n.assoc"
done
AI_OUT="$( cd "$d" && bash "$IL" dispatch-gaps --prompt-only .claude/state 7 8 9 2>&1 )"; AI_RC=$?
eq "$AI_RC" "20" "42 three 6 MiB issues refuse the gap prompt at the aggregate cap (20)"
has "$AI_OUT" "crossed the 16777216-byte cap while containing issue #9" "42 …naming the issue that crossed it"
if compgen -G "$d/.claude/state/gaps-held.*" >/dev/null || [ -s "$d/.claude/state/gap-prompt.txt" ]; then
  bad "42 …and no oversized prompt is left published"; else ok; fi

# ================= 43. round 50: the renewed claim is the staged inode; synthetic records =========
# =================     quote their names ========================================================
# The renewal's rename is checked against a descriptor held on the stage since its creation: a
# stage replaced between the write side closing and the mv (an mv shim does exactly that) used
# to be published as the claim, with only its file type checked.
mkdir -p "$work/mvclaim"
cat > "$work/mvclaim/mv" <<'SH'
#!/usr/bin/env bash
src="$1"; [ "$1" = "-f" ] && src="$2"
case "$src" in */.claim.w*) /bin/rm -f "$src"; printf '{"token":"tokT","expiresAt":1,"startedAt":1}\n' > "$src" ;; esac
/bin/mv "$@"
SH
chmod +x "$work/mvclaim/mv"
d="$(new_repo)"; seed_snap "$d"
jq -n --argjson e "$((NOWS + 9000))" '{startedAt:1, expiresAt:$e, token:"tokT"}' > "$d/.claude/state/gap-analysis.lock"
CR_OUT="$( cd "$d" && env PATH="$work/mvclaim:$PATH" bash "$IL" dispatch-gaps --token tokT --prompt-only .claude/state 7 2>&1 )"; CR_RC=$?
eq "$CR_RC" "20" "43 a renewal stage swapped before its rename is refused (20), never published as the claim"
has "$CR_OUT" "could not publish the renewed claim" "43 …naming the refusal"
# An untracked entry git yields NO patch for (a symlink to a directory — test 32's shape) gets
# a synthetic record; with a newline in its name, the raw name used to open prompt lines
# outside the envelope that read as first-party diff.
read -r _ RNQ <<EOF
${ remote_pair; }
EOF
mkdir -p "$RNQ/.claude/state" "$RNQ/somedir"; seed_snap "$RNQ"
( cd "$RNQ" && git switch -q -c issue-7-t && printf 'x\n' >> seed && git add seed && git commit -qm change ) >/dev/null 2>&1
( cd "$RNQ" && ln -s somedir "$(printf 'nl\nlink')" ) >/dev/null 2>&1
( cd "$RNQ" && bash "$IL" dispatch-review --prompt-only .claude/state codex ) >/dev/null 2>"$work/rnq.err"; RNQ_RC=$?
eq "$RNQ_RC" "0" "43 an untracked directory symlink with a newline in its name still builds ($(head -c 400 "$work/rnq.err" | tr '\n' ' '))"
RNQ_P="$RNQ/.claude/state/review-prompt.txt"
eq "$(grep -c '^diff --git a/dev/null b/"nl\\nlink"$' "$RNQ_P")" "1" "43 …with its synthetic record's name JSON-quoted onto one line"
if grep -qx 'link' "$RNQ_P"; then bad "43 …and no bare fragment of the name opens a line of its own"; else ok; fi
rm -f "$RNQ/$(printf 'nl\nlink')"

# ================= 11. argument handling ========================================================
bash "$IL" >/dev/null 2>&1;                 eq "$?" "2" "11 no subcommand is a usage error"
bash "$IL" bogus x >/dev/null 2>&1;         eq "$?" "2" "11 an unknown subcommand is a usage error"
bash "$IL" admit >/dev/null 2>&1;           eq "$?" "2" "11 admit needs its state-dir argument"
bash "$IL" admit a b >/dev/null 2>&1;       eq "$?" "2" "11 …exactly one of them"
bash "$IL" release >/dev/null 2>&1;         eq "$?" "2" "11 release needs its state-dir argument"
bash "$IL" --help >/dev/null 2>&1;          eq "$?" "0" "11 --help is not an error"

check_summary "check-implement-lib"
