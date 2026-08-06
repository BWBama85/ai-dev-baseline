#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for implement-lib.sh's RUN ADMISSION (#202).
#
# The decision under test: **may a new /implement-issue run start in this checkout?** Preflight used
# to answer by not asking — an unconditional `rm -f` of the run marker, the blocked marker and the
# gap lock — so a second session deleted a first session's LIVE state before #180's ownership check
# could see it. `admit` refuses instead, and only clears once it has proved the previous run is dead
# AND taken this run's claim.
#
# WHY EVERY CASE ASSERTS TWO THINGS. A guard's failure mode is silence, and this one's silence is
# *deleting something*: an `admit` that wrongly returns 0 looks exactly like a healthy start. So no
# case checks the exit code alone — each also asserts what survived. A refusal that returns 10 and
# still cleared the artifacts is the bug wearing the fix's exit code.
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
before="$(state_digest "$d")"
admit "$d" CLAUDE_CODE_SESSION_ID=sess-B
eq "$AD_RC" "10" "3 a second run is REFUSED while run A's marker is live"
eq "$(state_digest "$d")" "$before" \
   "3 …and A keeps EVERY file byte-for-byte: marker, blocked marker, gap findings, review findings"
has "$AD_OUT" "already in flight" "3 …and the refusal names the condition"
has "$AD_OUT" "issue-99-live"     "3 …and the branch the operator has to go finish"
if exists "$d/.claude/state/gap-analysis.lock"; then
  bad "3 …and B took no claim, so it cannot strand one on its way out"
else ok; fi

# ================= 4. what counts as LIVE ======================================================
# Local ref only.
d="$(new_repo)"; git -C "$d" branch issue-1-x; marker "$d" issue-1-x
admit "$d"; eq "$AD_RC" "10" "4 a marker whose LOCAL branch still exists is live"
# Remote-tracking ref only (the branch was pushed, then deleted locally).
d="$(new_repo)"
git -C "$d" update-ref refs/remotes/origin/issue-2-x "$(git -C "$d" rev-parse HEAD)"
marker "$d" issue-2-x
admit "$d"; eq "$AD_RC" "10" "4 a marker whose REMOTE ref still exists is live"
# Both refs gone, but the PR is OPEN — an open PR outranks branch absence, because the branch may
# have been tidied while the run is still going.
d="$(new_repo)"; marker "$d" issue-3-x "https://github.com/o/r/pull/3"
admit "$d" SHIM_PR_STATE=open; eq "$AD_RC" "10" "4 both refs gone but the PR is OPEN → still live"

# ================= 5. what counts as STALE (and is therefore cleared) ==========================
d="$(new_repo)"; marker "$d" issue-4-x "https://github.com/o/r/pull/4"
printf 'old\n' > "$d/.claude/state/gaps.md"
printf 'old\n' > "$d/.claude/state/review-codex.err"
printf '{}\n'  > "$d/.claude/state/implement-issue-blocked.json"
admit "$d" SHIM_PR_STATE=merged
eq "$AD_RC" "0" "5 both refs gone and the PR MERGED → the previous run is finished, so admit"
if exists "$d/.claude/state/implement-issue-active.json"; then bad "5 …and its marker is cleared"; else ok; fi
if exists "$d/.claude/state/implement-issue-blocked.json"; then bad "5 …and its blocked marker with it"; else ok; fi
if exists "$d/.claude/state/gaps.md"; then bad "5 …and its gap findings"; else ok; fi
if exists "$d/.claude/state/review-codex.err"; then bad "5 …and its per-slot review stream"; else ok; fi
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
admit "$d"
eq "$AD_RC" "11" "6 a .branch holding a control character is unreadable, not a stale run"
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
d="$(new_repo)"
admit "$d" ADB_RUN_CLAIM_LEASE_SECS=0
eq "$AD_RC" "0" "7 a zero-second lease still admits"
admit "$d"
eq "$AD_RC" "0" "7 …and the next run BREAKS the expired claim instead of being refused forever"
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
admit "$d" ADB_RUN_CLAIM_LEASE_SECS=0
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

# ================= 11. argument handling ========================================================
bash "$IL" >/dev/null 2>&1;                 eq "$?" "2" "11 no subcommand is a usage error"
bash "$IL" bogus x >/dev/null 2>&1;         eq "$?" "2" "11 an unknown subcommand is a usage error"
bash "$IL" admit >/dev/null 2>&1;           eq "$?" "2" "11 admit needs its state-dir argument"
bash "$IL" admit a b >/dev/null 2>&1;       eq "$?" "2" "11 …exactly one of them"
bash "$IL" release >/dev/null 2>&1;         eq "$?" "2" "11 release needs its state-dir argument"
bash "$IL" --help >/dev/null 2>&1;          eq "$?" "0" "11 --help is not an error"

check_summary "check-implement-lib"
