#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for the local convergence loop (#491): `implement-lib.sh
# review-loop`, `role-dispatch.sh local-passes`, `dispatch-review --local-head`, and the workflow
# prose that drives them.
#
# The loop's dangerous direction is a FALSE CONVERGED: fix code pushed as reviewed when no review
# read it. So every case asserts on the stored record and the rendered line, never on the word the
# driver would like to see — a failed pass, a moved tree, an edit after a clean pass, a reused reply
# and an under-carried exhaustion must each refuse to read as clean.
#
# The reviewer is a stub `codex` on PATH that answers from a per-invocation script and counts its
# own invocations, so "never dispatches a fourth time" is observed, not inferred. Every case builds
# its own fixture repository under a throwaway HOME; the tracked tree is never touched.
#
# `--mutation` breaks each refusal in a copy and requires the suite back RED on that row's witness.
#
# Usage: bash scripts/check-review-loop.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-review-loop: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-review-loop: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -gt 1 ] && { echo "usage: check-review-loop.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-review-loop.sh [--mutation]" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "check-review-loop: jq required" >&2; exit 1; }

work="$(mktemp -d)" || { echo "check-review-loop: FATAL — mktemp failed" >&2; exit 1; }
[ -d "$work" ] || { echo "check-review-loop: FATAL — no work dir" >&2; exit 1; }
check_exit_guard "check-review-loop" "rm -rf \"$work\""
check_init check-review-loop

IL="$ROOT/scripts/lib/implement-lib.sh"
RD="$ROOT/scripts/lib/role-dispatch.sh"
IW="$ROOT/base/workflows/implement-issue.md"
RW="$ROOT/base/workflows/resolve-pr-threads.md"

# ============================= --mutation: every refusal must be seen RED ========================
if [ "$MODE" = mutation ]; then
  check_mut budget-cap-ignored \
    '  if [ "$RL_PASSES" -ge "$bud" ]; then' \
    '  if false; then' \
    'a spent budget never dispatches a fourth time'
  check_mut failed-dispatch-reads-clean \
    '      *)  why=dispatch; frc="$drc"; [ "${#frc}" -le 3 ] || frc=999 ;;' \
    '      *)  : ;;' \
    'a forged clean reply left behind by a FAILED dispatch is never recorded'
  check_mut moved-tree-accepted \
    '    if [ -n "$tree2" ] && [ "$tree2" != "$tree1" ]; then why=moved; fi' \
    '    :' \
    'a tree that moved during the pass fails it'
  check_mut stale-convergence-accepted \
    '    if [ "$cur" = "${RL_TREE[L]}" ]; then' \
    '    if true; then' \
    'an edit after a converged pass invalidates it'
  check_mut undercarried-exhaustion-pushes \
    '  if [ "$c" -lt "${RL_REQ[L]}" ]; then' \
    '  if false; then' \
    'an exhaustion with fewer carries than declared BLOCKS'
  check_mut carried-high-pushes \
    '    case "${RL_CSEV[i]}" in critical|high) hard=$((hard + 1)) ;; esac' \
    '    :' \
    'a carried HIGH blocks'
  check_mut failed-final-pushes \
    "unknown\\n' \"\$passes\"; return 39" \
    "unknown\\n' \"\$passes\"; return 33" \
    'a failed final pass BLOCKS'
  check_mut published-reply-reused \
    '      if [ -n "$rsha" ] && [ "${RL_RSHA[i]:-}" = "$rsha" ]; then' \
    '      if false; then' \
    'a published reply already recorded is refused (17)'
  check_mut disabled-dispatches \
    '  if [ "$bud" -eq 0 ]; then' \
    '  if false; then' \
    'local_passes = 0 is 35'
  check_mut overcarry-accepted \
    '  if [ "$c" -ge "${RL_REQ[L]}" ]; then' \
    '  if false; then' \
    'a carry past the declared count is refused (17)'
  check_mut local-head-accepts-foreign \
    "        1) printf 'implement-lib: dispatch-review: HEAD %s does not descend from PR %s'\"'\"'s head %s — this is not that pull request plus local commits; sync the branch and re-run.\\n' \"\$lhead\" \"\$crit_pr\" \"\$phead\" >&2; return 16 ;;" \
    '        1) : ;;' \
    '--local-head refuses a HEAD that does not descend from the PR head'

  prep() {
    check_copy_subtrees "$ROOT" "$1/tree" scripts base templates >/dev/null 2>&1 || return 1
    printf '%s\n' "$1/tree/scripts/lib/implement-lib.sh"
  }
  runner() { ( cd "$1/tree" && bash scripts/check-review-loop.sh 2>&1 ); }
  check_mutation_pool check-review-loop "$work" prep runner 6

  # The budget reader is role-dispatch's, so its rows run in their own pool against that file.
  check_mut_reset
  check_mut out-of-range-accepted \
    '  if [ "${#raw}" -gt 2 ] || [ "$raw" -gt "$_ADB_RD_LOCAL_PASSES_MAX" ]; then' \
    '  if false; then' \
    'local_passes = 11 is out of range'
  check_mut empty-reads-as-malformed \
    "    ''|'\"\"'|\"''\")" \
    "    '__never__')" \
    'an empty value names itself as empty'
  prep_rd() {
    check_copy_subtrees "$ROOT" "$1/tree" scripts base templates >/dev/null 2>&1 || return 1
    printf '%s\n' "$1/tree/scripts/lib/role-dispatch.sh"
  }
  check_mutation_pool check-review-loop-rd "$work/rd" prep_rd runner 6

  check_summary check-review-loop
  exit 0
fi

# =============================== fixtures ========================================================
FHOME="$work/home"; mkdir -p "$FHOME/.config/ai-dev-baseline"
SB="$work/stub"; mkdir -p "$SB"
# The stub reviewer. Invocation k (counted in $RL_COUNT) takes its behaviour from $RL_SCRIPT line k:
#   req:<N>   a valid reply declaring N REQUIRED findings
#   bad       a reply with no verdict trailer (a verdict failure, rc 28 from dispatch-review)
#   127       exit 127 without writing a reply
#   hang      sleep past the dispatch bound (a timeout)
#   touch     a valid req:0 reply, after modifying a tracked file mid-pass (the tree moves)
cat > "$SB/codex" <<'SH'
#!/usr/bin/env bash
last=""; prev=""
for a in "$@"; do [ "$prev" = "--output-last-message" ] && last="$a"; prev="$a"; done
cat > /dev/null
k=$(( $(cat "$RL_COUNT" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$k" > "$RL_COUNT"
act="$(sed -n "${k}p" "$RL_SCRIPT")"
case "$act" in
  req:*) printf 'a finding\n\nADB-REVIEW-VERDICT v1 required=%s optional=1\n' "${act#req:}" > "$last" ;;
  bad)   printf 'prose with no trailer at all\n' > "$last" ;;
  127)   exit 127 ;;
  hang)  sleep 30 ;;
  touch) printf 'moved\n' >> "$RL_TOUCH"
         printf 'clean\n\nADB-REVIEW-VERDICT v1 required=0 optional=0\n' > "$last" ;;
  *)     echo "stub: no script line $k" >&2; exit 9 ;;
esac
exit 0
SH
chmod +x "$SB/codex"
ISSUE_JSON='{"state":"OPEN","title":"t","body":"acceptance: loop","author":{"login":"alice"},"comments":[]}'

# fixture — a repository whose origin/main is its base, on a feature branch carrying one change,
# with .claude/state gitignored and an issue snapshot for dispatch-review's criteria. Prints the path.
fixture() {
  local d
  d="$(mktemp -d "$work/r.XXXXXX")" || return 1
  {
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    printf '.claude/state/\n' > "$d/.gitignore"; printf 'a\n' > "$d/f.sh"
    git -C "$d" add .gitignore f.sh; git -C "$d" commit -qm base
    git -C "$d" update-ref refs/remotes/origin/main HEAD
    git -C "$d" switch -qc issue-7-x
    printf 'change\n' >> "$d/f.sh"; git -C "$d" commit -qam change
  } >/dev/null 2>&1
  mkdir -p "$d/.claude/state"
  printf '%s' "$ISSUE_JSON" > "$d/.claude/state/issue-7.json"; printf 'OWNER' > "$d/.claude/state/issue-7.assoc"
  printf '%s\n' "$d"
}
# script <repo> <line>… — the stub's behaviour, one line per dispatch. Kept OUTSIDE the repository:
# an untracked file the stub writes inside it would move the reviewed tree mid-pass.
script() { local d="$1"; shift; printf '%s\n' "$@" > "$d.script"; rm -f "$d.count"; }
# rl <repo> <verb> [args…] — run review-loop from inside the repo. Sets RL_RC and RL_OUT.
rl() {
  local d="$1"; shift
  RL_OUT="$( cd "$d" && env HOME="$FHOME" PATH="$SB:$PATH" RL_SCRIPT="$d.script" RL_COUNT="$d.count" \
      RL_TOUCH="$d/f.sh" ADB_DISPATCH_TIMEOUT_SECS=3 ADB_DISPATCH_KILL_GRACE_SECS=1 \
      ${RL_ENV:-} bash "$IL" review-loop "$@" 2>&1 )"; RL_RC=$?
}
count() { cat "$1.count" 2>/dev/null || echo 0; }
commit_fix() { printf 'fix %s\n' "$2" >> "$1/f.sh"; git -C "$1" commit -qam "fix $2" >/dev/null 2>&1; }
rec() { cat "$1/.claude/state/review-loop.tsv" 2>/dev/null; }

# =============================== 1. convergence ==================================================
# #491 acceptance: REQUIRED on pass 1, none on pass 2 -> converges after pass 2, with the line.
d="$(fixture)"; script "$d" req:2 req:0
rl "$d" pass .claude/state codex
eq "$RL_RC" 34 "1 a pass with REQUIRED findings and budget left is 34 — fix, commit, pass again"
has "$RL_OUT" "pass 1/3 -> 2 REQUIRED" "1 …and says so with the pass number and the default budget"
commit_fix "$d" one
rl "$d" pass .claude/state codex
eq "$RL_RC" 0 "1 a pass with zero REQUIRED converges (0)"
rl "$d" report .claude/state
eq "$RL_RC" 0 "1 report on a converged, unedited tree is 0"
eq "$RL_OUT" "local review: pass 1 -> 2 REQUIRED · pass 2 -> 0, converged" "1 the per-pass line, rendered from the record"
eq "$(count "$d")" 2 "1 exactly two dispatches"

# =============================== 2. exhaustion and carry =========================================
# Findings on every pass with local_passes = 3 -> the carried code after pass 3, never a 4th dispatch.
d="$(fixture)"; script "$d" req:2 req:2 req:2 req:2
rl "$d" pass .claude/state codex; commit_fix "$d" a
rl "$d" pass .claude/state codex; commit_fix "$d" b
rl "$d" pass .claude/state codex
eq "$RL_RC" 33 "2 findings on the last budgeted pass are 33 — exhausted"
has "$RL_OUT" "carry each REQUIRED finding" "2 …and the line says what to do next"
rl "$d" pass .claude/state codex
eq "$RL_RC" 38 "2 a pass past the budget is refused (38)"
eq "$(count "$d")" 3 "2 a spent budget never dispatches a fourth time"
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 an exhaustion with nothing carried BLOCKS (39)"
rl "$d" carry --severity low --finding 'a nit in f.sh' .claude/state
eq "$RL_RC" 0 "2 carry records a finding"
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 an exhaustion with fewer carries than declared BLOCKS"
has "$RL_OUT" "2 REQUIRED finding(s), 1 carried" "2 …and names the shortfall"
rl "$d" carry --severity low --finding 'a nit in f.sh' .claude/state
eq "$RL_RC" 10 "2 the identical carry is a no-op (10), so a retry is safe"
rl "$d" carry --severity medium --finding 'rename <x> & [y]' .claude/state
eq "$RL_RC" 0 "2 the second carry records"
rl "$d" carry --severity low --finding 'a third' .claude/state
eq "$RL_RC" 17 "2 a carry past the declared count is refused (17)"
rl "$d" report .claude/state
eq "$RL_RC" 33 "2 every REQUIRED finding carried, none HIGH: 33 — push, and say so"
has "$RL_OUT" "exhausted — carried: 2 (low: a nit in f.sh; medium: rename &lt;x&gt; &amp; \\[y\\])" \
   "2 the line names each carried finding, Markdown-escaped (reviewer-derived text)"
has "$RL_OUT" "pass 1 -> 2 REQUIRED · pass 2 -> 2 · pass 3 -> 2" "2 …after every pass"

# A carried HIGH blocks; a carried LOW pushes (above). Both observed.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:1
rl "$d" pass .claude/state codex
eq "$RL_RC" 33 "2 a budget of 1 exhausts on its only pass"
rl "$d" carry --severity high --finding 'unescaped path' .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 a carried HIGH blocks"
has "$RL_OUT" "CRITICAL/HIGH" "2 …and says why"
rl "$d" carry --severity sev1 --finding x .claude/state
eq "$RL_RC" 19 "2 a severity outside the closed set is refused (19)"
rl "$d" carry --severity low --finding "$(printf 'a\tb')" .claude/state
eq "$RL_RC" 19 "2 a finding carrying a TAB is refused (19) — it would forge a row"
RL_ENV=""
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --finding x .claude/state
eq "$RL_RC" 17 "2 carry against a loop that is NOT exhausted is refused (17)"

# =============================== 3. a failed pass is never clean ================================
d="$(fixture)"; script "$d" req:1 127 req:0
rl "$d" pass .claude/state codex; commit_fix "$d" a
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "3 a pass whose dispatch exits 127 is FAILED, not clean (36)"
rl "$d" report .claude/state
eq "$RL_RC" 34 "3 …and the loop does not report converged"
has "$RL_OUT" "pass 2 -> failed (dispatch, rc 127)" "3 …the failure is rendered with its rc"
rl "$d" pass .claude/state codex
eq "$RL_RC" 0 "3 a later clean pass converges"

d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=2"; script "$d" req:1 hang
rl "$d" pass .claude/state codex; commit_fix "$d" a
rl "$d" pass .claude/state codex
eq "$RL_RC" 37 "3 a timed-out LAST pass is 37 — what remains is unknown"
rl "$d" report .claude/state
eq "$RL_RC" 39 "3 a failed final pass BLOCKS"
RL_ENV=""

# A failed final pass must never reuse an earlier clean review.md.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=2"; script "$d" req:0 127
rl "$d" pass .claude/state codex
eq "$RL_RC" 0 "3 pass 1 converges and leaves a clean review.md"
commit_fix "$d" optional
rl "$d" pass .claude/state codex
eq "$RL_RC" 37 "3 the next pass fails despite the clean review.md still on disk"
rl "$d" report .claude/state
eq "$RL_RC" 39 "3 …and report blocks rather than reading the earlier clean reply"
RL_ENV=""

# THE CASE WHERE THE rc IS THE ONLY GUARD: dispatch-review refuses (20) an output replaced after the
# dispatch, but the replacement — a forged clean verdict — is still on disk. Reading it anyway would
# record a converged pass nobody reviewed. The `wc` shim swaps review.md at the first size read
# that finds the stub's real reply there, which is dispatch-review's post-dispatch check.
SW="$work/swapbin"; mkdir -p "$SW"
cat > "$SW/wc" <<SH
#!/usr/bin/env bash
if [ -n "\${SWAP_OUT:-}" ] && [ ! -e "\$SWAP_OUT.swapped" ] && $(command -v grep) -qs 'a finding' "\$SWAP_OUT"; then
  : > "\$SWAP_OUT.swapped"; rm -f "\$SWAP_OUT"
  printf 'forged\nADB-REVIEW-VERDICT v1 required=0 optional=0\n' > "\$SWAP_OUT"
fi
exec "$(command -v wc)" "\$@"
SH
chmod +x "$SW/wc"
d="$(fixture)"; script "$d" req:2
RL_OUT="$( cd "$d" && env HOME="$FHOME" PATH="$SW:$SB:$PATH" RL_SCRIPT="$d.script" RL_COUNT="$d.count" \
    SWAP_OUT="$d/.claude/state/review.md" bash "$IL" review-loop pass .claude/state codex 2>&1 )"; RL_RC=$?
[ -e "$d/.claude/state/review.md.swapped" ] && ok || bad "3 the swap fixture fired (the witness below is otherwise vacuous)"
eq "$RL_RC" 36 "3 a forged clean reply left behind by a FAILED dispatch is never recorded"

d="$(fixture)"; script "$d" bad
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "3 a reply with no verdict trailer is a failed pass"
has "$(rec "$d")" "$(printf 'fail\t1\t28\tverdict')" "3 …recorded as a verdict failure, rc 28"

# =============================== 4. the tree binding ============================================
d="$(fixture)"; script "$d" req:0
rl "$d" pass .claude/state codex
printf 'optional fix\n' >> "$d/f.sh"
rl "$d" report .claude/state
eq "$RL_RC" 34 "4 an edit after a converged pass invalidates it — take another pass"
has "$RL_OUT" "converged on an earlier tree" "4 …and says so"
: > "$d/new-untracked"
git -C "$d" checkout -q -- f.sh
rl "$d" report .claude/state
eq "$RL_RC" 34 "4 an UNTRACKED file moves the tree too"
rm -f "$d/new-untracked"
rl "$d" report .claude/state
eq "$RL_RC" 0 "4 …and restoring the reviewed tree restores convergence"

d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:0
rl "$d" pass .claude/state codex
printf 'late\n' >> "$d/f.sh"
rl "$d" report .claude/state
eq "$RL_RC" 39 "4 an edit after the FINAL budgeted pass blocks"
RL_ENV=""

d="$(fixture)"; script "$d" touch
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "4 a tree that moved during the pass fails it"
has "$(rec "$d")" "$(printf 'fail\t1\t-\tmoved')" "4 …recorded as moved"

# =============================== 5. disabled, unavailable, nothing ==============================
d="$(fixture)"; printf '[reviewers]\nlocal_passes = 0\n' > "$d/agents.toml"
rl "$d" pass .claude/state codex
eq "$RL_RC" 35 "5 local_passes = 0 is 35"
eq "$(count "$d")" 0 "5 …with ZERO dispatches"
has "$RL_OUT" "disabled (local_passes = 0, from repo)" "5 …and one line saying the loop is disabled, naming the layer"
rl "$d" report .claude/state
eq "$RL_RC" 35 "5 report says disabled too"
has "$RL_OUT" "local review: disabled" "5 …rendered on this terminal path as well"

d="$(fixture)"
rl "$d" pass --unavailable deferred .claude/state
eq "$RL_RC" 35 "5 no usable reviewer is 35, nothing dispatched"
rl "$d" report .claude/state
has "$RL_OUT" "no usable reviewer (rung deferred)" "5 …and the line names the rung"

d="$(fixture)"
rl "$d" report .claude/state
eq "$RL_RC" 11 "5 report with nothing recorded is 11 — never a hand-written converged"

# =============================== 6. the record is refused whole =================================
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'start\t9\t3\tzz\tcodex\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "6 a row outside the grammar refuses the whole record"
rl "$d" pass .claude/state codex
eq "$RL_RC" 18 "6 …for pass as well"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'done\t1\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "6 an event out of order refuses the record"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'x' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "6 a record with no final newline is refused (a torn append)"

# An interrupted pass (reserved, never answered) is recorded as the failure it was.
d="$(fixture)"; script "$d" req:1 req:0
rl "$d" pass .claude/state codex
T1="$(awk -F'\t' '$1=="start"{t=$4} END{print t}' "$d/.claude/state/review-loop.tsv")"
printf 'start\t2\t3\t%s\tcodex\n' "$T1" >> "$d/.claude/state/review-loop.tsv"
rl "$d" pass .claude/state codex
has "$(rec "$d")" "$(printf 'fail\t2\t-\tinterrupted')" "6 a pass killed mid-dispatch is recorded failed on the next call"
eq "$RL_RC" 0 "6 …and the next pass is pass 3, which converges"
has "$(rec "$d")" "$(printf 'start\t3\t')" "6 …numbered after the interrupted one"

# =============================== 7. the native (published) path ================================
d="$(fixture)"
printf 'finding\n\nADB-REVIEW-VERDICT v1 required=1 optional=0\n' > "$d/.claude/state/review.md"
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 34 "7 --published records the verdict of the published reply"
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 17 "7 a published reply already recorded is refused (17)"
eq "$(grep -c '^start' "$d/.claude/state/review-loop.tsv")" 1 "7 …without reserving a pass"
rm -f "$d/.claude/state/review.md"
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 36 "7 a missing published reply is a FAILED pass (publish-review removed a refused one)"
has "$(rec "$d")" "$(printf 'fail\t2\t-\tmissing')" "7 …recorded as missing"

# =============================== 8. the budget reader ===========================================
bud() { ( cd "$1" && env HOME="$FHOME" ${2:+ADB_LOCAL_REVIEW_PASSES="$2"} bash "$RD" local-passes --with-source 2>&1 ); }
d="$(fixture)"
BO="$(bud "$d")"; eq "$?" 3 "8 unset: rc 3, the caller's built-in applies"
set_lp() { printf '[reviewers]\nlocal_passes = %s\n' "$2" > "$1/agents.toml"; }
set_lp "$d" 0;       BO="$(bud "$d")"; eq "$?/$BO" "0/0 repo" "8 exact 0 is the disabled sentinel"
set_lp "$d" 5;       BO="$(bud "$d")"; eq "$?/$BO" "0/5 repo" "8 a plain value, with its layer"
set_lp "$d" '""';    BO="$(bud "$d")"; eq "$?" 2 "8 an empty value is a hard error"
has "$BO" "is empty" "8 an empty value names itself as empty"
set_lp "$d" '';      BO="$(bud "$d")"; eq "$?" 2 "8 a bare 'local_passes =' is empty too"
set_lp "$d" x;       BO="$(bud "$d")"; eq "$?" 2 "8 a non-integer is malformed"
has "$BO" "plain decimal integer" "8 a non-integer names the integer rule"
set_lp "$d" 03;      BO="$(bud "$d")"; eq "$?" 2 "8 a leading zero is refused"
has "$BO" "leading zero" "8 a leading zero names itself"
set_lp "$d" 00;      BO="$(bud "$d")"; eq "$?" 2 "8 00 is NOT the sentinel"
set_lp "$d" 11;      BO="$(bud "$d")"; eq "$?" 2 "8 local_passes = 11 is out of range"
has "$BO" "out of range" "8 an out-of-range value names the range"
set_lp "$d" 10;      BO="$(bud "$d")"; eq "$?/$BO" "0/10 repo" "8 10 is the ceiling, and legal"
set_lp "$d" 5;       BO="$(bud "$d" 2)"; eq "$?/$BO" "0/2 env" "8 ADB_LOCAL_REVIEW_PASSES overrides the manifest"
BO="$(bud "$d" abc)"; eq "$?" 2 "8 a malformed env override is a hard error, never ignored"
has "$BO" "ADB_LOCAL_REVIEW_PASSES" "8 …naming the variable"
printf '[reviewers]\nlocal_passes = 4\n' > "$FHOME/.config/ai-dev-baseline/agents.toml"
rm -f "$d/agents.toml"; BO="$(bud "$d")"; eq "$?/$BO" "0/4 global" "8 the global manifest is the lower layer"
rm -f "$FHOME/.config/ai-dev-baseline/agents.toml"
set_lp "$d" x
rl "$d" pass .claude/state codex
eq "$RL_RC" 18 "8 review-loop refuses to run on an unusable budget (18) rather than use the default"

# =============================== 9. --pr rounds and --local-head ================================
CB="$work/prbin"; mkdir -p "$CB"
cat > "$CB/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main","closingIssuesReferences":[]}\n' "$PR_HEAD" ;;
  *) echo "pr-shim unhandled: $*" >&2; exit 3 ;;
esac
SH
cat > "$CB/git" <<SH
#!/usr/bin/env bash
[ "\$1" = fetch ] && exit 0
exec "$(command -v git)" "\$@"
SH
chmod +x "$CB/gh" "$CB/git"
d="$(fixture)"; git -C "$d" remote add origin https://github.com/o/r.git
PH="$(git -C "$d" rev-parse HEAD)"
commit_fix "$d" unpushed
script "$d" req:0
prl() { local dd="$1"; shift; RL_OUT="$( cd "$dd" && env HOME="$FHOME" PATH="$CB:$SB:$PATH" PR_HEAD="$PH" \
    RL_SCRIPT="$dd.script" RL_COUNT="$dd.count" bash "$IL" "$@" 2>&1 )"; RL_RC=$?; }
prl "$d" review-loop pass --pr 7 --head "$PH" .claude/state codex
eq "$RL_RC" 0 "9 a resolver round reviews its UNPUSHED fix commits (HEAD ahead of the PR head)"
[ -f "$d/.claude/state/review-loop-pr7-$PH.tsv" ] && ok || bad "9 …keyed to the PR and the round head"
has "$(cat "$d/.claude/state/review-prompt.txt")" "commits not yet pushed" "9 …and the prompt says it is reviewing unpushed commits"
prl "$d" review-loop report --pr 7 --head "$PH" .claude/state
eq "$RL_RC" 0 "9 the round's report reads the same record"
prl "$d" dispatch-review --prompt-only --criteria-from-pr 7 .claude/state codex
eq "$RL_RC" 16 "9 WITHOUT --local-head the start-of-round review still refuses a HEAD ahead of the PR head"
git -C "$d" switch -q main; printf 'other\n' > "$d/g"; git -C "$d" add g; git -C "$d" commit -qm other >/dev/null 2>&1
prl "$d" dispatch-review --prompt-only --criteria-from-pr 7 --local-head .claude/state codex
eq "$RL_RC" 16 "9 --local-head refuses a HEAD that does not descend from the PR head"
prl "$d" review-loop pass --pr 7 --head "$PH" .claude/state codex
eq "$RL_RC" 16 "9 …and review-loop refuses a HEAD that does not descend from the round head"
( cd "$d" && bash "$IL" dispatch-review --local-head .claude/state codex ) >/dev/null 2>&1
eq "$?" 2 "9 --local-head without --criteria-from-pr is a usage error"

# =============================== 10. registration ==============================================
# The containment rule: a state-dir family must be named by state-scan, _il_clear and run-state.
d="$(fixture)"; S="$d/.claude/state"
printf 'x\n' > "$S/review-loop.tsv"; printf 'x\n' > "$S/review-loop-pr7-$(printf 'a%.0s' {1..40}).tsv"
SCAN="$(bash "$ROOT/scripts/lib/cleanup-lib.sh" state-scan "$S")"
eq "$(printf '%s\n' "$SCAN" | awk -F'\t' '$2 ~ /review-loop/ && $1=="review"' | wc -l | tr -d ' ')" 2 \
   "10 state-scan classifies both loop records as review artifacts"
jq -n '{branch:"issue-7-x", issue:"7", phase:"implemented", startedAt:"2026-09-28T00:00:00Z",
         phaseHistory:[{phase:"implemented", at:"2026-09-28T00:00:00Z"}]}' > "$S/implement-issue-active.json"
RS="$(bash "$ROOT/scripts/lib/run-state.sh" summary --state "$S" 2>/dev/null)"
has "$RS" "<state>/review-loop.tsv" "10 run-state names the loop record rather than counting it unnamed"
has "$RS" "<state>/review-loop-pr7-" "10 …and the resolver round's record too"
hasnt "$RS" "unnamed-artifacts" "10 …and counts nothing as unnamed"
rm -f "$S/implement-issue-active.json"
AD="$( cd "$d" && env HOME="$FHOME" bash "$IL" admit .claude/state 2>&1 )"
if [ -e "$S/review-loop.tsv" ] || ls "$S"/review-loop-pr* >/dev/null 2>&1; then
  bad "10 admission left a finished run's loop record behind [$AD]"; else ok; fi

# =============================== 11. the prose drives the loop ==================================
# #491 acceptance: step 9 calls the loop before step 10; the resolver calls it before the push and
# before step 7's re-request. Positions are line numbers in the workflow SOURCE.
line_of() { grep -n -m1 -F -- "$2" "$1" | cut -d: -f1; }
before() { local a b; a="$(line_of "$1" "$2")"; b="$(line_of "$1" "$3")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "$4 [$2 @${a:-none}, $3 @${b:-none}]"; fi; }
before "$IW" 'review-loop pass' '### 10. Push + open PR' "11 implement-issue step 9 calls the loop before step 10"
before "$IW" '### 9. Triage + fix' 'review-loop pass' "11 …inside step 9, after the first triage"
before "$IW" 'review-loop report' '# ADB-SNIPPET: rule-sweep' "11 …and reports it before the rule-sweep is recorded over the final tree"
grep -qF 'review-loop pass --published' "$IW" && ok || bad "11 the native Claude review path participates in the loop"
before "$RW" 'review-loop pass --pr' 'git push origin "$PR_BRANCH"' "11 the resolver runs the loop before its push"
before "$RW" 'review-loop pass --pr' '### 7. Ask for a re-review' "11 …and before step 7's re-request"
eq "$(grep -c 'git push origin "$PR_BRANCH"' "$RW")" 1 "11 the resolver pushes ONCE per round — the fix and ledger pushes are consolidated"
before "$RW" '#### 4c. Promote what has become a pattern' 'review-loop pass --pr' "11 …after 4c, so the reviewed diff includes the ledger commit"
grep -q '^# *local_passes' "$ROOT/templates/agents.toml" && ok || bad "11 the template declares the key"

check_summary check-review-loop
