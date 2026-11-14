#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for the local convergence loop (#491, #618): `implement-lib.sh
# review-loop`, `role-dispatch.sh local-passes`, `dispatch-review --local-head`, and the workflow
# prose that drives them.
#
# The loop's dangerous direction is a FALSE CONVERGED: fix code pushed as reviewed when no review
# read it. So every case asserts on the stored record and the rendered line, never on the word the
# driver would like to see — a failed pass, a moved tree, an edit after a clean pass, a reused reply
# and an under-carried exhaustion must each refuse to read as clean. Since #618 a REQUIRED finding
# can also end declined or deferred, and `until-clean` removes the budget: a partly dispositioned
# pass, a disposition on a stale tree and a loop whose reviewer is gone must not read as clean either.
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
# The suite asserts the BUILT-IN budget and its own bounds, so an operator's one-run overrides must
# not reach a fixture: every case that wants one sets it through RL_ENV.
unset ADB_LOCAL_REVIEW_PASSES ADB_DISPATCH_TIMEOUT_SECS ADB_DISPATCH_KILL_GRACE_SECS
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
  # The rows run through the vendored shmutant (#519); this file sources it, never check-lib.sh (D35).
  # shellcheck source=/dev/null
  . "$ROOT/scripts/shmutant.sh" || bad "check-review-loop: scripts/shmutant.sh could not be sourced"
  shmutant_target scripts/lib/implement-lib.sh
  shmutant_mut budget-cap-ignored \
    '  if ! _il_loop_unbounded "$RL_BUD" && [ "$RL_PASSES" -ge "$RL_BUD" ]; then' \
    '  if false; then' \
    'a spent budget never dispatches a fourth time'
  shmutant_mut failed-dispatch-reads-clean \
    '    *)  why=dispatch; frc="$drc"; [ "${#frc}" -le 3 ] || frc=999 ;;' \
    '    *)  : ;;' \
    'a forged clean reply left behind by a FAILED dispatch is never recorded'
  shmutant_mut verdict-read-failure-accepted \
    '      why=verdict; frc="$rc"' \
    '      :' \
    '…recorded as a verdict failure, rc 19'
  shmutant_mut moved-tree-accepted \
    '    if [ -n "$tree2" ] && [ "$tree2" != "$tree1" ]; then why=moved; fi' \
    '    :' \
    'a tree that moved during the pass fails it'
  shmutant_mut unbound-tree-accepted \
    '    tree2="$(_il_tree_digest "$RL_ROOT" "$RL_BASE")" || { tree2=""; why=unbound; }' \
    '    tree2="$(_il_tree_digest "$RL_ROOT" "$RL_BASE")" || tree2="$tree1"' \
    'a tree that cannot be digested after the pass fails it'
  shmutant_mut dirty-pass-accepted \
    '  if [ "$RL_PRE_CLEAN" -ne 0 ]; then' \
    '  if false; then' \
    'a pass over a dirty worktree is refused (27)'
  shmutant_mut dirty-report-accepted \
    '  rc="$RL_PRE_CLEAN"' \
    '  rc=0' \
    'report on a dirty worktree is 27, never converged'
  shmutant_mut stale-convergence-accepted \
    '    if [ "$cur" = "${RL_TREE[L]}" ]; then' \
    '    if true; then' \
    'an edit after a converged pass invalidates it'
  shmutant_mut exhausted-edit-accepted \
    '  if [ "$cur" != "${RL_TREE[L]}" ]; then' \
    '  if false; then' \
    'a commit after an EXHAUSTED pass blocks'
  shmutant_mut undercarried-exhaustion-pushes \
    '  if [ "$((c + d))" -lt "${RL_REQ[L]}" ]; then' \
    '  if false; then' \
    'an exhaustion with fewer carries than declared BLOCKS'
  shmutant_mut carried-high-pushes \
    '    case "${RL_CSEV[i]}" in critical|high) hard=$((hard + 1)) ;; esac' \
    '    :' \
    'a carried HIGH blocks'
  shmutant_mut failed-final-pushes \
    '"$passes" "$after"; return 39' \
    '"$passes" "$after"; return 33' \
    'a failed final pass BLOCKS'
  shmutant_mut disable-after-pass-excuses \
    '  if [ "$L" -eq 0 ]; then' \
    '  if true; then' \
    'local_passes = 0 after a failed final pass still BLOCKS'
  shmutant_mut unavailable-does-not-exhaust \
    '  [ "$1" -eq 0 ] || [ "$RL_LAST" = none ] || [ "$RL_PASSES" -ge "$1" ]' \
    '  [ "$RL_PASSES" -ge "$1" ]' \
    'a reviewer lost after a pass with findings exhausts the loop'
  shmutant_mut disabled-dispatches \
    '  if [ "$RL_BUD" = 0 ]; then' \
    '  if false; then' \
    'local_passes = 0 is 35'
  shmutant_mut report-invents-empty \
    '  if [ ! -e "$RL_REC" ] && [ ! -L "$RL_REC" ]; then' \
    '  if false; then' \
    'report with nothing recorded is 11'
  shmutant_mut published-without-begin \
    '    if [ "$RL_OPEN_KIND" != begin ] || [ "$RL_OPEN_TOKEN" != "$RL_TOKEN" ]; then' \
    '    if false; then' \
    '--published with no begun pass is refused (17)'
  shmutant_mut begin-keeps-old-reply \
    '    if ! mv -f "$RL_DIR/review.md" "$aside" 2>/dev/null || [ -e "$RL_DIR/review.md" ] || [ -L "$RL_DIR/review.md" ]; then' \
    '    if false; then' \
    'begin removes the previous reply'
  shmutant_mut interrupted-left-open \
    '  if [ -n "$RL_OPEN" ] && [ "$keep_open" -eq 0 ]; then' \
    '  if false; then' \
    'a pass killed mid-dispatch is recorded failed on the next call'
  shmutant_mut record-race-accepted \
    '  if [ "$RL_OPEN" != "$n" ]; then' \
    '  if false; then' \
    'a record that changed underneath a pass refuses to record its result'
  shmutant_mut pass-past-budget-accepted \
    '        _il_loop_unbounded "${ADB_SWEEP_F[2]}" || [ "$n" -le "${ADB_SWEEP_F[2]}" ] || return 18' \
    '        :' \
    'a pass numbered past the budget it ran under refuses the record'
  shmutant_mut unknown-row-accepted \
    '      *) return 18 ;;' \
    '      *) : ;;' \
    'an unknown row kind refuses the whole record'
  shmutant_mut torn-record-accepted \
    '  adb_bytes_whole "$f" "$_IL_LOOP_MAX_BYTES" || return $?' \
    '  :' \
    'a record with no final newline is refused'
  shmutant_mut overcarry-accepted \
    '  if [ "${RL_USED[L]:-0}" -ge "${RL_REQ[L]}" ]; then' \
    '  if false; then' \
    'a carry past the declared count is refused (17)'
  shmutant_mut duplicate-carry-appended \
    '    if [ "${RL_CSEV[i]}" = "$RL_SEV" ] && [ "${RL_CSITE[i]}" = "$RL_SITE" ] && [ "${RL_COCC[i]}" = "$RL_OCC" ] && [ "${RL_CTXT[i]}" = "$RL_FIND" ]; then' \
    '    if false; then' \
    'the identical carry is a no-op (10)'
  shmutant_mut carry-before-exhaustion \
    '|| ! _il_loop_exhausted "$bud"; then' \
    '; then' \
    'carry against a loop that is NOT exhausted is refused (17)'
  shmutant_mut carry-bound-ignored \
    '  [ $(( sz + ${#2} + 1 + head )) -le "$_IL_LOOP_MAX_BYTES" ] || return 19' \
    '  :' \
    'a carry that would take the record past its bound is refused (19)'
  shmutant_mut control-char-finding \
    '  [[ "$t" =~ [[:cntrl:]] ]] && return 1' \
    '  :' \
    'a finding carrying a TAB is refused (19)'
  shmutant_mut severity-open \
    '    *) echo "implement-lib: review-loop carry: --severity must be critical|high|medium|low" >&2; return 19 ;; esac' \
    '    *) : ;; esac' \
    'a severity outside the closed set is refused (19)'
  shmutant_mut malformed-budget-defaults \
    '    2) return 18 ;;' \
    '    2) printf '"'"'%s default\n'"'"' "$_IL_LOOP_DEFAULT" ;;' \
    'review-loop refuses to run on an unusable budget (18)'
  shmutant_mut round-head-foreign \
    "      1) printf 'implement-lib: review-loop: HEAD does not descend from the round head %s — this is not that round'\"'\"'s history\\n' \"\$head\" >&2; return 16 ;;" \
    '      1) RL_BASE="$head" ;;' \
    'review-loop refuses a HEAD that does not descend from the round head'
  shmutant_mut dirty-disabled-pushes \
    '  rc="$RL_PRE_CLEAN"' \
    '  rc=0' \
    'a disabled loop over a dirty worktree is 27'
  shmutant_mut begin-loses-reply \
    '    mv -f "$aside" "$RL_DIR/review.md" 2>/dev/null' \
    '    :' \
    'puts the previous reply back rather than losing it'
  shmutant_mut validated-verdict-unbound \
    '    if [ "$rc" -eq 0 ] && [ -n "$expect" ] && [ "$vout" != "$expect" ]; then rc=20; fi' \
    '    :' \
    'a reply replaced after dispatch-review validated it never records the replacement'
  shmutant_mut dotdot-site-accepted \
    '  case "$path" in *:*|.|./|*/|/*|-*|..|../*|*/..|*/../*) return 1 ;; esac' \
    '  case "$path" in *:*|.|./|*/|/*|-*) return 1 ;; esac' \
    'a site that climbs out of the repository (..) is refused (19)'
  shmutant_mut begin-twice-accepted \
    '  if [ "$kind" = begin ] && [ "$RL_OPEN_KIND" = begin ]; then' \
    '  if false; then' \
    'a second begin over an unfinished native pass is refused (17)'
  shmutant_mut occurrence-not-in-identity \
    '    if [ "${RL_CSEV[i]}" = "$RL_SEV" ] && [ "${RL_CSITE[i]}" = "$RL_SITE" ] && [ "${RL_COCC[i]}" = "$RL_OCC" ] && [ "${RL_CTXT[i]}" = "$RL_FIND" ]; then' \
    '    if [ "${RL_CSEV[i]}" = "$RL_SEV" ] && [ "${RL_CSITE[i]}" = "$RL_SITE" ] && [ "${RL_CTXT[i]}" = "$RL_FIND" ]; then' \
    'an identical second finding is carried with --occurrence 2'
  shmutant_mut off-while-open-appended \
    '    [ -n "$RL_OPEN" ] || { _il_loop_append "$RL_REC" "off"$'"'"'\t'"'"'"$RL_BSRC"; rc=$?; }' \
    '    _il_loop_append "$RL_REC" "off"$'"'"'\t'"'"'"$RL_BSRC"; rc=$?' \
    'writes no row the reader refuses while a native pass is open'
  shmutant_mut finding-nul-accepted \
    '    if [ "$_fnul" != 0 ] || [ "$_fnl" -gt 1 ] || { [ "$_fnl" = 1 ] && [ "$(tail -c 1 "$_ff" | od -An -tx1 | tr -d '"'"' \n'"'"')" != 0a ]; }; then' \
    '    if [ "$_fnl" -gt 1 ]; then' \
    'refuses a NUL byte rather than storing the line with it dropped'
  shmutant_mut open-pr-ungated \
    '  if ! _il_open_pr_loop_gate "$dir"; then' \
    '  if false; then' \
    'open-pr refuses (39) when no loop is recorded'
  shmutant_mut open-pr-tip-unpinned \
    '  if [ "$(git rev-parse "refs/heads/$branch" 2>/dev/null)" != "$_tip" ] || [ "$(git rev-parse HEAD 2>/dev/null)" != "$_tip" ]; then' \
    '  if false; then' \
    'open-pr refuses (39) when the tip moved across the verdict read'
  shmutant_mut site-not-in-identity \
    '        k="$n"$'"'"'\t'"'"'"${ADB_SWEEP_F[3]}"$'"'"'\t'"'"'"${ADB_SWEEP_F[4]}"$'"'"'\t'"'"'"${ADB_SWEEP_F[5]}"' \
    '        k="$n"$'"'"'\t'"'"'"${ADB_SWEEP_F[4]}"$'"'"'\t'"'"'"${ADB_SWEEP_F[5]}"' \
    'same-text findings at different sites leave a readable, fully carried record'
  shmutant_mut local-head-accepts-foreign \
    "        1) printf 'implement-lib: dispatch-review: HEAD %s does not descend from PR %s'\"'\"'s head %s — this is not that pull request plus local commits; sync the branch and re-run.\\n' \"\$lhead\" \"\$crit_pr\" \"\$phead\" >&2; return 16 ;;" \
    '        1) : ;;' \
    '--local-head refuses a HEAD that does not descend from the PR head'
  # ---- #618: until-clean, decline/defer, the settled verdict, the derived count, the summary ----
  shmutant_mut until-clean-read-as-a-number \
    '_il_loop_unbounded() { [ "$1" = until-clean ]; }' \
    '_il_loop_unbounded() { false; }' \
    'under until-clean every pass with REQUIRED findings is 34'
  shmutant_mut until-clean-pass-is-final \
    '    if _il_loop_unbounded "$RL_BUD" || [ "$n" -lt "$RL_BUD" ]; then' \
    '    if [ "$n" -lt "$RL_BUD" ] 2>/dev/null; then' \
    'under until-clean every pass with REQUIRED findings is 34'
  shmutant_mut until-clean-failed-pass-is-final \
    '  if _il_loop_unbounded "$RL_BUD" || [ "$RL_BUD" -gt "$n" ]; then' \
    '  if [ "$RL_BUD" -gt "$n" ] 2>/dev/null; then' \
    'a failed pass under until-clean is 36, never the final 37'
  shmutant_mut until-clean-exhausts \
    '  _il_loop_unbounded "$1" && return 1' \
    '  :' \
    'carry under until-clean is refused (17) even after the reviewer is lost'
  shmutant_mut until-clean-lost-reviewer-waits \
    '  if _il_loop_unbounded "$bud" && [ "$RL_LAST" = none ]; then stuck=1; fi' \
    '  :' \
    'until-clean with the reviewer lost after a pass BLOCKS (39)'
  shmutant_mut settled-ignores-tree \
    '  if [ "$d" -eq "${RL_REQ[L]}" ] && [ "${RL_TREE[L]}" = "$cur" ]; then' \
    '  if [ "$d" -eq "${RL_REQ[L]}" ]; then' \
    'a commit after a settled pass un-settles it'
  shmutant_mut settled-on-partial \
    '  if [ "$d" -eq "${RL_REQ[L]}" ] && [ "${RL_TREE[L]}" = "$cur" ]; then' \
    '  if [ "$d" -gt 0 ] && [ "${RL_TREE[L]}" = "$cur" ]; then' \
    'a pass with one of two REQUIRED findings declined is NOT settled'
  shmutant_mut stale-pass-disposition-read \
    '        [ "$n" = "$RL_PASSES" ] || return 18' \
    '        :' \
    'a defer row against an earlier pass refuses the record'
  shmutant_mut conflicting-disposition-read \
    '        [ -z "${taken[$k2]:-}" ] || return 18' \
    '        :' \
    'a finding both deferred and declined refuses the record'
  shmutant_mut carried-after-deferred-read \
    '        [ "${taken[$k]:-}" = "" ] || return 18' \
    '        :' \
    'a finding deferred and then carried refuses the record'
  shmutant_mut over-disposition-read \
    '        [ "${RL_REQ[n]}" -ge "${RL_USED[n]}" ] || return 18' \
    '        :' \
    'more dispositions than the pass declared REQUIRED refuses the record'
  shmutant_mut defer-issue-unread \
    '          _il_loop_issue_ok "$arg" || return 18' \
    '          :' \
    'a defer row whose issue is not a number refuses the record'
  shmutant_mut defer-issue-open \
    '    _il_loop_issue_ok "$arg" \' \
    '    true \' \
    'defer refuses an issue that is not a number (19)'
  shmutant_mut dispose-conflict-accepted \
    '  if [ -n "$was" ]; then' \
    '  if false; then' \
    'a finding already deferred cannot also be declined (19)'
  shmutant_mut dispose-retry-refused \
    '    if [ "$was" = "$kind" ] && _il_loop_same_ending "$L" "$arg"; then' \
    '    if false; then' \
    'the identical defer is a no-op (10)'
  shmutant_mut dispose-other-issue-is-retry \
    '      [ "${RL_DARG[i]}" = "$2" ]; return $?' \
    '      return 0' \
    'the same finding deferred to a different issue is a conflict (19)'
  shmutant_mut over-dispose-accepted \
    '  if [ "${RL_REQ[L]}" -le "${RL_USED[L]:-0}" ]; then' \
    '  if false; then' \
    'a disposition past the declared count is refused (17)'
  shmutant_mut dispose-on-failed-pass \
    '  if [ "$L" -eq 0 ] || [ -n "$RL_OPEN" ] || [ "${RL_OUT[L]:-}" != "done" ] || [ "${RL_REQ[L]}" -eq 0 ]; then' \
    '  if false; then' \
    'defer against a failed pass is refused (17)'
  shmutant_mut carry-of-disposed-accepted \
    '  if [ "$was" != "" ]; then' \
    '  if false; then' \
    'a finding already deferred cannot also be carried (19)'
  shmutant_mut ended-tail-dropped \
    "  [ -z \"\$out\" ] || printf '%s%s\\n' \"\$out\" \"\$(_il_loop_ended_text)\"" \
    "  [ -z \"\$out\" ] || printf '%s\\n' \"\$out\"" \
    'the report line names the deferred finding and its issue'
  shmutant_mut finding-text-not-spanned \
    '_il_loop_span() { RL_SPAN="\`${1//\`/\'"'"'}\`"; }' \
    '_il_loop_span() { RL_SPAN="$1"; }' \
    'a carried closing keyword is rendered inside a code span'
  shmutant_mut fixed-counts-same-tree \
    '      if [ "${RL_TREE[n]}" != "${RL_TREE[next]}" ]; then differs=1; fi' \
    '      differs=1' \
    'a pass retaken on the same tree fixes nothing'
  shmutant_mut fixed-looks-one-pass-ahead \
    '      if [ "${RL_TREE[n]}" != "${RL_TREE[next]}" ]; then differs=1; fi' \
    '      differs=0; if [ "${RL_TREE[n]}" != "${RL_TREE[next]}" ]; then differs=1; fi' \
    'fixed counts a pass when ANY later pass read a changed tree'
  shmutant_mut fixed-counts-disposed \
    '    rem=$(( RL_REQ[n] - ${RL_USED[n]:-0} ))' \
    '    rem=$(( RL_REQ[n] ))' \
    'fixed excludes what was declined or deferred'
  shmutant_mut superseded-dropped \
    '      if [ "$differs" -eq 1 ]; then RL_T_FIXED=$(( RL_T_FIXED + rem )); else RL_T_SUPERSEDED=$(( RL_T_SUPERSEDED + rem )); fi' \
    '      if [ "$differs" -eq 1 ]; then RL_T_FIXED=$(( RL_T_FIXED + rem )); fi' \
    'a finding a later pass on the same tree no longer raised is superseded, never dropped'
  shmutant_mut open-dropped \
    '      RL_T_OPEN="$rem"' \
    '      :' \
    'the outcomes add up to the REQUIRED total'
  shmutant_mut pass-without-result-room \
    '"$RL_TOKEN" "$_IL_LOOP_RESULT_MAX"; rc=$?' \
    '"$RL_TOKEN"; rc=$?' \
    'a pass whose result would not fit is refused before it is dispatched'
  shmutant_mut summary-counts-foreign-run \
    '    elif [ "$marker_pr" = "$pr" ]; then' \
    '    elif true; then' \
    'summary --pr leaves out a run record whose marker names another PR'
  shmutant_mut summary-marker-stream-read \
    '    if length == 1 and (.[0] | type) == "object" then .[0] else error("marker") end' \
    '    if (.[0] | type) == "object" then .[0] else error("marker") end' \
    'a marker that is two objects'
  shmutant_mut summary-marker-false-is-absent \
    '    | if (has("prUrl") | not) then ""' \
    '    | if (.prUrl // false | not) then ""' \
    'a marker whose prUrl is false'
  shmutant_mut summary-marker-url-grammar \
    '           and (.prUrl | test("^https://[^/]+/[^/]+/[^/]+/pull/[1-9][0-9]{0,10}$"))' \
    '           and true' \
    'a marker whose prUrl is a bare number'
  shmutant_mut summary-marker-url-whitespace \
    '           and (.prUrl | test("[[:space:][:cntrl:]]") | not)' \
    '           and true' \
    'a marker whose prUrl holds whitespace'
  shmutant_mut summary-snapshot-unbounded \
    '  [ "$sz" -le "$3" ] || return 18' \
    '  :' \
    'a run marker past 64 KiB'
  shmutant_mut summary-round-count-unbounded \
    '      if [ "${#SM_SHAS[@]}" -ge "$_IL_LOOP_SUMMARY_ROUNDS" ]; then rc=21; break; fi' \
    '      :' \
    'more round records than the snapshot'
  shmutant_mut summary-follows-links \
    '  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 20' \
    '  :' \
    'summary refuses (20) a record that is a symbolic link'
  shmutant_mut summary-unlistable-dir \
    "  [ -r \"\$dir\" ] || { printf 'implement-lib: review-loop summary: %s cannot be listed, so which records it holds is unknown\\n' \"\$dir\" >&2; return 20; }" \
    '  :' \
    'summary refuses (20) a state directory it cannot list'
  shmutant_mut summary-sort-status-lost \
    '      || { echo "implement-lib: review-loop summary: could not order the round records — no summary is rendered" >&2; return 20; }' \
    '      || true' \
    'summary refuses (20) when the rounds cannot be ordered'
  shmutant_mut summary-marker-unread \
    "      else error(\"prUrl\") end' \"\$1\" 2>/dev/null || return 20" \
    "      else error(\"prUrl\") end' \"\$1\" 2>/dev/null || true" \
    'summary refuses (20) a run marker it cannot read'
  shmutant_mut summary-unlocked \
    "  _il_claim_mutex_take \"\$dir\" \"\$_IL_LOOP_MUTEX\" || { echo \"implement-lib: review-loop summary: could not take the loop's lock\" >&2; return 20; }" \
    '  :' \
    'summary reads under the loop'"'"'s lock, and refuses (20) when it cannot take it'
  shmutant_mut summary-order-reversed \
    "    sorted=\"\$(printf '%s\\n' \"\${keyed[@]}\" | LC_ALL=C sort)\" \\" \
    "    sorted=\"\$(printf '%s\\n' \"\${keyed[@]}\" | LC_ALL=C sort -r)\" \\" \
    'summary orders the rounds by ancestry, oldest first'
  shmutant_mut summary-partial-accepted \
    '    _il_loop_summary_one "$sha" "$snap/round-$sha.tsv" "$dir/review-loop-pr${pr}-${sha}.tsv" || return $?' \
    '    _il_loop_summary_one "$sha" "$snap/round-$sha.tsv" "$dir/review-loop-pr${pr}-${sha}.tsv" || true' \
    'summary refuses (18) when a round record does not parse'
  # The byte bound on a finding holds only under `local LC_ALL=C`; the row needs a UTF-8 locale to
  # have a witness, so it is registered only where one exists.
  if locale -a 2>/dev/null | grep -qx -e C.UTF-8 -e en_US.UTF-8 -e C.utf8 -e en_US.utf8; then
    shmutant_mut finding-bound-in-characters \
      '  local LC_ALL=C t="$1"' \
      '  local t="$1"' \
      'a finding past 300 BYTES is refused (19)'
  fi

  # Built ONCE per pool; shmutant clones it for every row, and `shmutant_target` names the file.
  prep() {
    check_copy_subtrees "$ROOT" "$1" scripts base templates >/dev/null 2>&1
  }
  runner() { ( cd "$1" && bash scripts/check-review-loop.sh 2>&1 ); }
  check_shmutant_pool check-review-loop "$work/pool" prep runner 6

  # The budget reader is role-dispatch's, so its rows run in their own pool against that file.
  shmutant_reset
  shmutant_target scripts/lib/role-dispatch.sh
  shmutant_mut out-of-range-accepted \
    '  if [ "${#raw}" -gt 2 ] || [ "$raw" -gt "$_ADB_RD_LOCAL_PASSES_MAX" ]; then' \
    '  if false; then' \
    'local_passes = 11 is out of range'
  shmutant_mut empty-reads-as-malformed \
    "    ''|'\"\"'|\"''\")" \
    "    '__never__')" \
    'an empty value names itself as empty'
  shmutant_mut until-clean-one-spelling \
    '  if { [ "$layer" = env ] && [ "$raw" = until-clean ]; } || { [ "$layer" != env ] && [ "$raw" = '"'"'"until-clean"'"'"' ]; }; then' \
    '  if [ "$raw" = until-clean ] || [ "$raw" = '"'"'"until-clean"'"'"' ]; then' \
    'a bare until-clean in a manifest is refused'
  check_shmutant_pool check-review-loop-rd "$work/pool-rd" prep runner 6

  # The resolver's pre-push live check is prose the resolver executes, so its row runs against the
  # workflow source.
  shmutant_reset
  shmutant_target base/workflows/resolve-pr-threads.md
  shmutant_mut empty-push-sha-accepted \
    '  [ "${#PUSH_SHA}" -eq 40 ] || { echo "STOP: HEAD is not a full commit id — nothing was pushed"; exit 1; }   # run step 8 first' \
    '  :' \
    'refuses a push SHA that is not 40 hex'
  shmutant_mut live-pr-check-dropped \
    '  [ "$LIVE" = "OPEN $SWEEP_HEAD" ] \' \
    '  true \' \
    '…and refuses the push unless the PR is OPEN at the round head'
  check_shmutant_pool check-review-loop-rw "$work/pool-rw" prep runner 6

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
#   race      a valid req:0 reply, after appending a row for this pass to the record mid-pass
#   lock      a valid req:0 reply, after making a tracked file unreadable (the tree cannot be digested)
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
  race)  printf 'fail\t%s\t-\tinterrupted\n' "$k" >> "$RL_RECORD"
         printf 'clean\n\nADB-REVIEW-VERDICT v1 required=0 optional=0\n' > "$last" ;;
  lock)  chmod 000 "$RL_TOUCH"
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
      RL_TOUCH="$d/f.sh" RL_RECORD="$d/.claude/state/review-loop.tsv" ADB_DISPATCH_TIMEOUT_SECS=3 ADB_DISPATCH_KILL_GRACE_SECS=1 \
      ${RL_ENV:-} bash "$IL" review-loop "$@" 2>&1 )"; RL_RC=$?
}
count() { cat "$1.count" 2>/dev/null || echo 0; }
# code_line_of <file> <text> — the line of <text> INSIDE a fenced block; line_of, anywhere.
code_line_of() {
  awk -v pat="$2" '/^[[:space:]]*(```|~~~)/ { f = !f; next } f && index($0, pat) { print NR; exit }' "$1"
}
line_of() { grep -n -m1 -F -- "$2" "$1" | cut -d: -f1; }
order() { local a="$2" b="$3"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "$1 [@${a:-none} < @${b:-none}]"; fi; }
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
eq "$RL_OUT" "local review: 2 passes · pass 1 -> 2 REQUIRED · pass 2 -> 0, converged — fixed: 2" "1 the line, rendered from the record: the total, each pass, the verdict, what was fixed"
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
rl "$d" carry --severity low --site f.sh:1 --finding 'a nit in f.sh' .claude/state
eq "$RL_RC" 0 "2 carry records a finding"
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 an exhaustion with fewer carries than declared BLOCKS"
has "$RL_OUT" "2 REQUIRED finding(s), 1 carried" "2 …and names the shortfall"
rl "$d" carry --severity low --site f.sh:1 --finding 'a nit in f.sh' .claude/state
eq "$RL_RC" 10 "2 the identical carry is a no-op (10), so a retry is safe"
rl "$d" carry --severity medium --site f.sh:1 --finding 'rename <x> & [y]' .claude/state
eq "$RL_RC" 0 "2 the second carry records"
rl "$d" carry --severity low --site f.sh:9 --finding 'a nit in f.sh' .claude/state
eq "$RL_RC" 17 "2 …and a third is refused once every declared finding is carried"
rl "$d" carry --severity low --site f.sh:1 --finding 'a third' .claude/state
eq "$RL_RC" 17 "2 a carry past the declared count is refused (17)"
rl "$d" report .claude/state
eq "$RL_RC" 33 "2 every REQUIRED finding carried, none HIGH: 33 — push, and say so"
has "$RL_OUT" 'carried: 2 (pass 3 low `f.sh:1`: `a nit in f.sh`; pass 3 medium `f.sh:1`: `rename <x> & [y]`)' \
   "2 the line names each carried finding in code spans (reviewer-derived text renders no markup)"
has "$RL_OUT" "exhausted: every REQUIRED finding of pass 3 was carried, declined or deferred — fixed: 4 · carried: 2 (" \
   "2 …after the verdict, beside what the earlier passes' fixes answered"
has "$RL_OUT" "pass 1 -> 2 REQUIRED · pass 2 -> 2 · pass 3 -> 2" "2 …after every pass"

# One finding is carried once: its severity is the driver's triage, not part of what the finding is.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:2
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding 'one finding' .claude/state
rl "$d" carry --severity medium --site f.sh:1 --finding 'one finding' .claude/state
eq "$RL_RC" 19 "2 a finding already carried cannot be carried again at another severity (19)"
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 …so one finding carried cannot stand in for two"
has "$RL_OUT" 'carried: 1 (pass 1 low `f.sh:1`: `one finding`)' "2 an under-carried BLOCKED line still names what was carried"
printf 'carry\t1\tmedium\tf.sh:1\t1\tone finding\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "2 a finding carried at two severities refuses the record"
# A carry made before the budget was raised stays on the line once later passes converge.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:1 req:0
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding 'left for later' .claude/state
RL_ENV="ADB_LOCAL_REVIEW_PASSES=2"; commit_fix "$d" more
rl "$d" pass .claude/state codex
rl "$d" report .claude/state
eq "$RL_RC" 0 "2 a raised budget lets a later pass converge"
has "$RL_OUT" 'carried: 1 (pass 1 low `f.sh:1`: `left for later`)' "2 …and the converged line still names what an earlier pass carried"
RL_ENV=""
# A carried HIGH blocks; a carried LOW pushes (above). Both observed.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:1
rl "$d" pass .claude/state codex
eq "$RL_RC" 33 "2 a budget of 1 exhausts on its only pass"
rl "$d" carry --severity high --site f.sh:1 --finding 'unescaped path' .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 a carried HIGH blocks"
has "$RL_OUT" "CRITICAL/HIGH" "2 …and says why"
has "$RL_OUT" 'carried: 1 (pass 1 high `f.sh:1`: `unescaped path`)' "2 …and the BLOCKED line still names the carried finding"
rl "$d" carry --severity sev1 --site f.sh:1 --finding x .claude/state
eq "$RL_RC" 19 "2 a severity outside the closed set is refused (19)"
rl "$d" carry --severity low --site f.sh:1 --finding "$(printf 'a\tb')" .claude/state
eq "$RL_RC" 19 "2 a finding carrying a TAB is refused (19) — it would forge a row"
rl "$d" carry --severity low --site '/etc/passwd' --finding x .claude/state
eq "$RL_RC" 19 "2 a site that is not repository-relative is refused (19)"
rl "$d" carry --severity low --site '../outside.sh:3' --finding x .claude/state
eq "$RL_RC" 19 "2 a site that climbs out of the repository (..) is refused (19)"
for bad_site in 'f.sh:0' 'f.sh:abc' 'a:b:c' '.' 'dir/'; do
  rl "$d" carry --severity low --site "$bad_site" --finding x .claude/state
  eq "$RL_RC" 19 "2 the site '$bad_site' is not a path[:line] and is refused (19)"
done
# A closing keyword in carried text must not register a link when the line lands in a PR body: it is
# rendered inside a code span, and a backtick in it cannot close the span early.
d="$(fixture)"; script "$d" req:1; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding 'Closes #1 and `Fixes #2`' .claude/state
rl "$d" report .claude/state
has "$RL_OUT" "\`Closes #1 and 'Fixes #2'\`" "2 a carried closing keyword is rendered inside a code span, backticks neutralized"
# EVERY carried finding is named in the line: the PR body is the durable copy once run state is swept.
d="$(fixture)"; script "$d" req:51; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"
rl "$d" pass .claude/state codex
awk 'BEGIN { for (i = 1; i <= 51; i++) printf "carry\t1\tlow\tf.sh:%d\t1\tfinding %d\n", i, i }' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 33 "2 fifty-one carried findings make a pushable exhaustion"
has "$RL_OUT" '`f.sh:51`: `finding 51`' "2 …and the line names the 51st, not a count of the rest"
# Two identical findings (same site, severity and text) are two findings: --occurrence tells them apart.
d="$(fixture)"; script "$d" req:2
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding 'twice' .claude/state
rl "$d" carry --severity low --site f.sh:1 --finding 'twice' .claude/state
eq "$RL_RC" 10 "2 an identical row is the retry path (10)"
rl "$d" carry --severity low --site f.sh:1 --occurrence 2 --finding 'twice' .claude/state
eq "$RL_RC" 0 "2 an identical second finding is carried with --occurrence 2"
rl "$d" report .claude/state
eq "$RL_RC" 33 "2 …and the duplicate-prose exhaustion is fully carried"
rl "$d" carry --severity low --site f.sh:1 --occurrence 0 --finding 'x' .claude/state
eq "$RL_RC" 19 "2 --occurrence 0 is refused (19)"
# `--finding -` reads the line from stdin, so reviewer text survives without shell quoting.
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
RL_OUT="$( cd "$d" && env HOME="$FHOME" ADB_LOCAL_REVIEW_PASSES=1 bash "$IL" review-loop carry --severity low --site 'docs/a file.md:2' --finding - .claude/state <<'FINDING' 2>&1
it's a $HOME-looking `thing`
FINDING
)"; RL_RC=$?
eq "$RL_RC" 0 "2 --finding - carries a line with an apostrophe, a dollar and backticks, read from stdin"
has "$(rec "$d")" "it's a \$HOME-looking \`thing\`" "2 …stored byte for byte"
RL_OUT="$( cd "$d" && printf 'one\ntwo\n' | env HOME="$FHOME" ADB_LOCAL_REVIEW_PASSES=1 bash "$IL" review-loop carry --severity low --site f.sh:3 --finding - .claude/state 2>&1 )"; RL_RC=$?
eq "$RL_RC" 19 "2 --finding - refuses stdin carrying more than one line (19)"
RL_OUT="$( cd "$d" && printf 'one\n\n' | env HOME="$FHOME" ADB_LOCAL_REVIEW_PASSES=1 bash "$IL" review-loop carry --severity low --site f.sh:3 --finding - .claude/state 2>&1 )"; RL_RC=$?
eq "$RL_RC" 19 "2 --finding - refuses a trailing blank line — command substitution would have hidden it"
RL_OUT="$( cd "$d" && printf 'a\000b\n' | env HOME="$FHOME" ADB_LOCAL_REVIEW_PASSES=1 bash "$IL" review-loop carry --severity low --site f.sh:3 --finding - .claude/state 2>&1 )"; RL_RC=$?
eq "$RL_RC" 19 "2 --finding - refuses a NUL byte rather than storing the line with it dropped"
# Two findings sharing their wording are still two: the site is part of the identity.
d="$(fixture)"; script "$d" req:2; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site 'docs/a file.md:3' --finding 'same words' .claude/state
eq "$RL_RC" 0 "2 a site with a space — a legal path — can be carried"
rl "$d" carry --severity low --site 'docs/résumé.md:7' --finding 'same words' .claude/state
eq "$RL_RC" 0 "2 two findings with identical text at different sites are both carried"
rl "$d" report .claude/state
eq "$RL_RC" 33 "2 same-text findings at different sites leave a readable, fully carried record"

# A finding's bound is BYTES, under a UTF-8 locale too: 150 two-byte characters are 300 bytes, 151 are not.
UTF=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qx -- "$l"; then UTF="$l"; break; fi
done
if [ -n "$UTF" ]; then
  d="$(fixture)"; script "$d" req:3
  RL_ENV="ADB_LOCAL_REVIEW_PASSES=1 LC_ALL=$UTF"
  rl "$d" pass .claude/state codex
  mb="$(printf 'é%.0s' $(seq 150))"
  rl "$d" carry --severity low --site f.sh:1 --finding "$mb" .claude/state
  eq "$RL_RC" 0 "2 a 300-BYTE multibyte finding is legal"
  rl "$d" carry --severity low --site f.sh:1 --finding "${mb}é" .claude/state
  eq "$RL_RC" 19 "2 a finding past 300 BYTES is refused (19), whatever its character count"
else
  check_note "no UTF-8 locale here — the byte-bound case runs only where one exists"
fi

# The writer never produces a record its reader refuses: a carry that would cross the record's
# 1 MiB bound is refused, and the record it declined to grow still reads.
d="$(fixture)"; script "$d" req:9999; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"
rl "$d" pass .claude/state codex
R="$d/.claude/state/review-loop.tsv"
pad="$(printf 'x%.0s' $(seq 290))"
awk -v pad="$pad" -v cur="$(wc -c < "$R" | tr -d ' ')" \
  'BEGIN { n = int((1048576 - cur) / 312); for (i = 1; i <= n; i++) printf "carry\t1\tlow\t-\t1\t%05d%s\n", i, pad }' >> "$R"
rl "$d" carry --severity low --site f.sh:1 --finding "$(printf 'y%.0s' $(seq 300))" .claude/state
eq "$RL_RC" 19 "2 a carry that would take the record past its bound is refused (19)"
rl "$d" report .claude/state
eq "$RL_RC" 39 "2 …and the record it declined to grow still reads (39, not 18)"
RL_ENV=""
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding x .claude/state
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

# dispatch-review validated a reply declaring 2 REQUIRED; a clean-looking replacement lands before the
# loop records the pass. The count recorded must be the one validated — so the pass fails instead.
VB="$work/validbin"; mkdir -p "$VB"
cat > "$VB/bash" <<SH
#!$(command -v bash)
case "\$*" in
  *"dispatch-review"*)
    "$(command -v bash)" "\$@"; rc=\$?
    printf 'clean\nADB-REVIEW-VERDICT v1 required=0 optional=0\n' > "\$SWAP_DIR/review.md.new" && mv -f "\$SWAP_DIR/review.md.new" "\$SWAP_DIR/review.md"
    exit \$rc ;;
esac
exec "$(command -v bash)" "\$@"
SH
chmod +x "$VB/bash"
d="$(fixture)"; script "$d" req:2
RL_OUT="$( cd "$d" && env HOME="$FHOME" PATH="$VB:$SB:$PATH" RL_SCRIPT="$d.script" RL_COUNT="$d.count" \
    SWAP_DIR="$d/.claude/state" bash "$IL" review-loop pass .claude/state codex 2>&1 )"; RL_RC=$?
eq "$RL_RC" 36 "3 a reply replaced after dispatch-review validated it never records the replacement's count"

d="$(fixture)"; script "$d" bad
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "3 a reply with no verdict trailer is a failed pass"
has "$(rec "$d")" "$(printf 'fail\t1\t28\tverdict')" "3 …recorded as a verdict failure, rc 28"

# =============================== 4. the tree binding ============================================
# A pass reviews the worktree and a push ships HEAD, so the loop certifies only a CLEAN tree (27).
d="$(fixture)"; script "$d" req:0
printf 'uncommitted\n' >> "$d/f.sh"
rl "$d" pass .claude/state codex
eq "$RL_RC" 27 "4 a pass over a dirty worktree is refused (27) — the reviewed tree must be the committed one"
eq "$(count "$d")" 0 "4 …before anything is dispatched"
git -C "$d" add f.sh
rl "$d" pass .claude/state codex
eq "$RL_RC" 27 "4 a STAGED change is dirty too — a commit would ship the index, not the reviewed worktree"
git -C "$d" commit -qm staged >/dev/null 2>&1
rl "$d" pass .claude/state codex
eq "$RL_RC" 0 "4 the committed tree is reviewed and converges"
printf 'optional fix\n' >> "$d/f.sh"
rl "$d" report .claude/state
eq "$RL_RC" 27 "4 report on a dirty worktree is 27, never converged"
: > "$d/new-untracked"; git -C "$d" checkout -q -- f.sh
rl "$d" report .claude/state
eq "$RL_RC" 27 "4 …and an untracked file is dirty too"
rm -f "$d/new-untracked"
rl "$d" report .claude/state
eq "$RL_RC" 0 "4 …and the clean reviewed tree converges again"
git -C "$d" commit -q --allow-empty -m empty >/dev/null 2>&1
rl "$d" report .claude/state
eq "$RL_RC" 0 "4 an EMPTY commit ships the reviewed tree and keeps convergence (the binding is the tree)"
commit_fix "$d" optional
rl "$d" report .claude/state
eq "$RL_RC" 34 "4 an edit after a converged pass invalidates it — take another pass"
has "$RL_OUT" "converged on an earlier tree" "4 …and says so"

d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:0
rl "$d" pass .claude/state codex
commit_fix "$d" late
rl "$d" report .claude/state
eq "$RL_RC" 39 "4 an edit after the FINAL budgeted pass blocks"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
commit_fix "$d" sneaked
rl "$d" report .claude/state
eq "$RL_RC" 39 "4 a commit after an EXHAUSTED pass blocks, even with every finding carried"
RL_ENV=""

d="$(fixture)"; script "$d" touch
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "4 a tree that moved during the pass fails it"
has "$(rec "$d")" "$(printf 'fail\t1\t-\tmoved')" "4 …recorded as moved"

d="$(fixture)"; script "$d" lock
rl "$d" pass .claude/state codex
chmod 644 "$d/f.sh"
eq "$RL_RC" 36 "4 a tree that cannot be digested after the pass fails it"
has "$(rec "$d")" "$(printf 'fail\t1\t-\tunbound')" "4 …recorded as unbound"

# =============================== 5. disabled, unavailable, nothing ==============================
d="$(fixture)"; printf '[reviewers]\nlocal_passes = 0\n' > "$d/agents.toml"
git -C "$d" add agents.toml; git -C "$d" commit -qm manifest >/dev/null 2>&1   # untracked, it would be a dirty tree
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
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=0"
rl "$d" pass .claude/state codex
printf 'uncommitted fix\n' >> "$d/f.sh"
rl "$d" report .claude/state
eq "$RL_RC" 27 "5 a disabled loop over a dirty worktree is 27, never the push-able 35"
RL_ENV=""
d="$(fixture)"; script "$d" req:0
rl "$d" pass .claude/state codex
mkdir "$d/.claude/state/.review-loop-mutex"
rl "$d" report .claude/state
eq "$RL_RC" 20 "5 report decides under the loop's lock, and refuses (20) when it cannot take it"
rmdir "$d/.claude/state/.review-loop-mutex"

# Disabling the loop, or losing the reviewer, AFTER a pass exhausts it — it never excuses a block.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=2"; script "$d" req:1 127
rl "$d" pass .claude/state codex; commit_fix "$d" a
rl "$d" pass .claude/state codex
RL_ENV="ADB_LOCAL_REVIEW_PASSES=0"
rl "$d" report .claude/state
eq "$RL_RC" 39 "5 local_passes = 0 after a failed final pass still BLOCKS"
has "$RL_OUT" "(then disabled)" "5 …and the line says the loop was disabled after it"
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" carry --severity high --site f.sh:1 --finding 'real bug' .claude/state
RL_ENV="ADB_LOCAL_REVIEW_PASSES=0"
rl "$d" report .claude/state
eq "$RL_RC" 39 "5 local_passes = 0 after a carried HIGH still BLOCKS"
RL_ENV=""
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" pass --unavailable none .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 39 "5 a reviewer lost after a pass with findings exhausts the loop — uncarried, it BLOCKS"
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
eq "$RL_RC" 0 "5 …and its findings can then be carried"
rl "$d" report .claude/state
eq "$RL_RC" 33 "5 …after which it pushes with the line"

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
d="$(fixture)"; script "$d" req:0
rl "$d" pass .claude/state codex
T1="$(awk -F'\t' '$1=="start"{t=$4} END{print t}' "$d/.claude/state/review-loop.tsv")"
printf 'start\t2\t1\t%s\tcodex\ndone\t2\t%s\t0\t0\t%s\n' "$T1" "$T1" "$T1" >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "6 a pass numbered past the budget it ran under refuses the record (no writer can emit one)"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'bogus\tx\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "6 an unknown row kind refuses the whole record"

# The result is recorded only against the pass still open: a record that moved underneath a pass
# refuses its result rather than appending a second outcome.
d="$(fixture)"; script "$d" race
rl "$d" pass .claude/state codex
eq "$RL_RC" 20 "6 a record that changed underneath a pass refuses to record its result"
eq "$(grep -c '^done' "$d/.claude/state/review-loop.tsv")" 0 "6 …and no done row is appended beside the other outcome"

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
# `begin` reserves the pass and binds its tree BEFORE the subagent runs, and removes the previous
# reply, so `pass --published` can only read one published for this pass.
publish() { printf 'finding\n\nADB-REVIEW-VERDICT v1 required=%s optional=0\n' "$2" > "$1/.claude/state/review.md"; }
d="$(fixture)"
publish "$d" 0
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 17 "7 --published with no begun pass is refused (17) — even over a reply on disk"
rl "$d" begin .claude/state claude
eq "$RL_RC" 0 "7 begin reserves a native pass"
rl "$d" begin .claude/state claude
eq "$RL_RC" 17 "7 a second begin over an unfinished native pass is refused (17) — its subagent may still be running"
eq "$(grep -c '^fail' "$d/.claude/state/review-loop.tsv")" 0 "7 …and the begun pass is NOT marked interrupted"
RL_ENV="ADB_LOCAL_REVIEW_PASSES=0"
rl "$d" begin .claude/state claude
eq "$RL_RC" 35 "7 a begin after local_passes drops to 0 is disabled (35)"
rl "$d" report .claude/state
[ "$RL_RC" != 18 ] && ok || bad "7 …and writes no row the reader refuses while a native pass is open"
RL_ENV=""
[ -e "$d/.claude/state/review.md" ] && bad "7 begin removes the previous reply" || ok
publish "$d" 1
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 34 "7 --published records the verdict of the reply published for the begun pass"
commit_fix "$d" a
rl "$d" begin .claude/state claude
publish "$d" 1
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 34 "7 an identical reply in a later genuine pass is recorded, not refused as reused"
commit_fix "$d" b
rl "$d" begin .claude/state claude
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 37 "7 a native pass whose reply was never published is a FAILED pass"
has "$(rec "$d")" "$(printf 'fail\t3\t-\tmissing')" "7 …recorded as missing"

d="$(fixture)"
rl "$d" begin .claude/state claude
commit_fix "$d" during
publish "$d" 0
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 36 "7 a commit made while the native subagent reviewed fails the pass — the tree was bound at begin"
has "$(rec "$d")" "$(printf 'fail\t1\t-\tmoved')" "7 …recorded as moved"
d="$(fixture)"
rl "$d" begin .claude/state claude
printf 'prose with no trailer\n' > "$d/.claude/state/review.md"
rl "$d" pass --published .claude/state claude
eq "$RL_RC" 36 "7 a published reply with no verdict is a FAILED pass"
has "$(rec "$d")" "$(printf 'fail\t1\t19\tverdict')" "7 …recorded as a verdict failure, rc 19"
d="$(fixture)"; script "$d" req:0
rl "$d" pass .claude/state codex
printf 'previous reply\n' > "$d/.claude/state/review.md"
chmod 444 "$d/.claude/state/review-loop.tsv"
rl "$d" begin .claude/state claude
chmod 644 "$d/.claude/state/review-loop.tsv"
eq "$RL_RC" 20 "7 a begin whose reservation cannot be written fails (20)"
eq "$(cat "$d/.claude/state/review.md" 2>/dev/null)" "previous reply" "7 …and puts the previous reply back rather than losing it"
d="$(fixture)"; script "$d" req:0
rl "$d" begin .claude/state claude
rl "$d" pass .claude/state codex
has "$(rec "$d")" "$(printf 'fail\t1\t-\tinterrupted')" "7 a dispatched pass over an unfinished native one records it interrupted"

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
# #618: `until-clean` is no budget. One spelling per surface — a TOML string in a manifest, the bare
# word in the env var.
set_lp "$d" '"until-clean"'; BO="$(bud "$d")"; eq "$?/$BO" "0/until-clean repo" "8 \"until-clean\" in a manifest is the no-budget value, with its layer"
set_lp "$d" until-clean;     BO="$(bud "$d")"; eq "$?" 2 "8 a bare until-clean in a manifest is refused — a bare word is not TOML"
has "$BO" 'written "until-clean" in a manifest' "8 …and the message says how to spell it"
set_lp "$d" '"Until-Clean"'; BO="$(bud "$d")"; eq "$?" 2 "8 any other string is still malformed"
set_lp "$d" 5
BO="$(bud "$d" until-clean)"; eq "$?/$BO" "0/until-clean env" "8 ADB_LOCAL_REVIEW_PASSES=until-clean overrides the manifest"
BO="$(bud "$d" '"until-clean"')"; eq "$?" 2 "8 a quoted until-clean in the env var is refused — it is not the word"
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
[ -f "$d/.claude/state/review-loop-pr7-${PH:0:12}.tsv" ] && ok || bad "9 …keyed to the PR and the round head"
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
printf 'x\n' > "$S/review-loop.tsv"; printf 'x\n' > "$S/review-loop-pr7-$(printf 'a%.0s' {1..12}).tsv"
# The widest name the writer can produce — an 11-digit PR — must still fit run-state's name bound.
printf 'x\n' > "$S/review-loop-pr12345678901-$(printf 'b%.0s' {1..12}).tsv"
SCAN="$(bash "$ROOT/scripts/lib/cleanup-lib.sh" state-scan "$S")"
eq "$(printf '%s\n' "$SCAN" | awk -F'\t' '$2 ~ /review-loop/ && $1=="review"' | wc -l | tr -d ' ')" 3 \
   "10 state-scan classifies every loop record as a review artifact"
jq -n '{branch:"issue-7-x", issue:"7", phase:"implemented", startedAt:"2026-09-28T00:00:00Z",
         phaseHistory:[{phase:"implemented", at:"2026-09-28T00:00:00Z"}]}' > "$S/implement-issue-active.json"
RS="$(bash "$ROOT/scripts/lib/run-state.sh" summary --state "$S" 2>/dev/null)"
has "$RS" "<state>/review-loop.tsv" "10 run-state names the loop record rather than counting it unnamed"
has "$RS" "<state>/review-loop-pr7-" "10 …and the resolver round's record too"
has "$RS" "<state>/review-loop-pr12345678901-" "10 …even for the widest PR number --pr accepts"
hasnt "$RS" "unnamed-artifacts" "10 …and counts nothing as unnamed"
rm -f "$S/implement-issue-active.json"
AD="$( cd "$d" && env HOME="$FHOME" bash "$IL" admit .claude/state 2>&1 )"
if [ -e "$S/review-loop.tsv" ] || ls "$S"/review-loop-pr* >/dev/null 2>&1; then
  bad "10 admission left a finished run's loop record behind [$AD]"; else ok; fi

# =============================== 12. open-pr pushes only a certified tip ========================
# Step 9's report runs before step 10, so open-pr re-derives the loop's verdict itself. Past the gate
# the push fails (24) — the fixture has no remote — which is how "the gate let it through" is seen.
OB="$work/opbin"; mkdir -p "$OB"
printf '#!/usr/bin/env bash\necho "gh stub: $*" >&2; exit 3\n' > "$OB/gh"; chmod +x "$OB/gh"
printf 'body\n' > "$work/op-body.md"
opr() { local dd="$1"; shift
  RL_OUT="$( cd "$dd" && env HOME="$FHOME" PATH="$OB:$SB:$PATH" RL_SCRIPT="$dd.script" RL_COUNT="$dd.count" \
      ${RL_ENV:-} bash "$IL" open-pr .claude/state --title t --body-file "$work/op-body.md" 2>&1 )"; RL_RC=$?; }
opfix() { local dd; dd="$(fixture)"
  jq -n '{branch:"issue-7-x", issue:"7", phase:"triaged", startedAt:"2026-09-28T00:00:00Z"}' > "$dd/.claude/state/implement-issue-active.json"
  printf '%s\n' "$dd"; }
d="$(opfix)"
opr "$d"
eq "$RL_RC" 39 "12 open-pr refuses (39) when no loop is recorded"
d="$(opfix)"; script "$d" req:0
rl "$d" pass .claude/state codex
opr "$d"
eq "$RL_RC" 24 "12 a converged loop lets open-pr through to its push"
commit_fix "$d" after-report
opr "$d"
eq "$RL_RC" 39 "12 open-pr refuses (39) a commit made after the converged pass"
d="$(opfix)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=0"
opr "$d"
eq "$RL_RC" 24 "12 a disabled loop with nothing recorded does not hold the push"
d="$(opfix)"; script "$d" req:1; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"
rl "$d" pass .claude/state codex
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
opr "$d"
eq "$RL_RC" 24 "12 an exhaustion with a carried LOW lets open-pr through to its push"
d="$(opfix)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" carry --severity high --site f.sh:1 --finding bug .claude/state
opr "$d"
eq "$RL_RC" 39 "12 an exhaustion with a carried HIGH is refused at the push (39)"
RL_ENV=""
# The tip must not move across the verdict read: a `git` shim advances the branch when open-pr asks
# for the loop's report, so the report certifies the old tip and the push would send the new one.
d="$(opfix)"; script "$d" req:0
rl "$d" pass .claude/state codex
RB="$work/reportbin"; mkdir -p "$RB"
# The shebang names the REAL interpreter: this shim is itself named `bash`, so `env bash` would
# find it again and recurse.
cat > "$RB/bash" <<SH
#!$(command -v bash)
case "\$*" in
  *"review-loop report"*)
    if [ -n "\${MOVE_REPO:-}" ] && [ ! -e "\$MOVE_REPO.moved" ]; then
      : > "\$MOVE_REPO.moved"
      out="\$("$(command -v bash)" "\$@")"; rc=\$?
      "$(command -v git)" -C "\$MOVE_REPO" commit -q --allow-empty -m moved >/dev/null 2>&1
      printf '%s\n' "\$out"; exit \$rc
    fi ;;
esac
exec "$(command -v bash)" "\$@"
SH
chmod +x "$RB/bash"
RL_OUT="$( cd "$d" && env HOME="$FHOME" PATH="$RB:$OB:$SB:$PATH" MOVE_REPO="$d" \
    bash "$IL" open-pr .claude/state --title t --body-file "$work/op-body.md" 2>&1 )"; RL_RC=$?
[ -e "$d.moved" ] && ok || bad "12 the tip-move fixture fired (the witness below is otherwise vacuous)"
eq "$RL_RC" 39 "12 open-pr refuses (39) when the tip moved across the verdict read"

# =============================== 13. until-clean (#618) =========================================
# No budget: no pass is refused as spent and none is the last, so the spent-budget codes (33, 37, 38)
# are unreachable — observed over more passes than the old ceiling of 10 allowed.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=until-clean"
script "$d" req:1 req:1 req:1 req:1 req:1 req:1 req:1 req:1 req:1 req:1 req:1 127 req:0
odd=""
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  rl "$d" pass .claude/state codex
  [ "$RL_RC" = 34 ] || odd="$odd pass$i=$RL_RC"
  [ "$i" = 11 ] || commit_fix "$d" "u$i"
done
eq "$odd" "" "13 under until-clean every pass with REQUIRED findings is 34 — eleven of them, never the spent-budget 33 or 38"
has "$RL_OUT" "pass 11/until-clean" "13 …and the pass line names the setting where a budget would stand"
has "$(rec "$d")" "$(printf 'start\t11\tuntil-clean\t')" "13 …recorded as the budget the pass ran under"
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
eq "$RL_RC" 17 "13 carry under until-clean is refused (17): nothing is ever exhausted"
rl "$d" report .claude/state
eq "$RL_RC" 34 "13 report under until-clean with REQUIRED findings is 34 — take another pass — never a block or a carry"
commit_fix "$d" u11
rl "$d" pass .claude/state codex
eq "$RL_RC" 36 "13 a failed pass under until-clean is 36, never the final 37"
rl "$d" report .claude/state
eq "$RL_RC" 34 "13 …and report asks for another pass rather than blocking on a failed final one"
rl "$d" pass .claude/state codex
eq "$RL_RC" 0 "13 the thirteenth pass converges"
rl "$d" report .claude/state
eq "$RL_RC" 0 "13 …and report certifies it"
has "$RL_OUT" "local review: 13 passes · " "13 …with the total leading the line"
eq "$(count "$d")" 13 "13 thirteen dispatches, none refused"

# A reviewer lost after a pass cannot exhaust a loop that has no last pass: it BLOCKS.
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" pass --unavailable none .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 39 "13 until-clean with the reviewer lost after a pass BLOCKS (39) — never the carried 33"
has "$RL_OUT" "until-clean ends only on a clean or settled pass" "13 …and says why"
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
eq "$RL_RC" 17 "13 carry under until-clean is refused (17) even after the reviewer is lost"
# The budget is read live: a finite one set after until-clean took more passes than it allows is spent.
d="$(fixture)"; script "$d" req:1 req:1 req:1 req:1 req:1
for i in 1 2 3 4; do rl "$d" pass .claude/state codex; [ "$i" = 4 ] || commit_fix "$d" "s$i"; done
RL_ENV="ADB_LOCAL_REVIEW_PASSES=3"
rl "$d" pass .claude/state codex
eq "$RL_RC" 38 "13 a finite budget set after until-clean took four passes refuses the fifth (38)"
rl "$d" report .claude/state
eq "$RL_RC" 39 "13 …and the record until-clean wrote still reads under it (39, not 18)"
# What bounds a loop with no budget is the record's own bound: a pass that could not be recorded
# is refused before anything is dispatched, and the record still reads.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=until-clean"; script "$d" req:9999 req:0
rl "$d" pass .claude/state codex
R="$d/.claude/state/review-loop.tsv"
# Filled to within 30 bytes of the bound with deferred findings (a row is 15 bytes plus its text,
# 31 to 315), which is less room than any `start` row needs.
pad="$(printf 'x%.0s' $(seq 300))"
awk -v pad="$pad" -v cur="$(wc -c < "$R" | tr -d ' ')" 'BEGIN {
  room = 1048576 - cur
  while (room >= 31) {
    if (room > 345) len = 315; else if (room > 315) len = room - 31; else len = room
    i++; printf "defer\t1\t7\t-\t1\t%05d%s\n", i, substr(pad, 1, len - 20); room -= len
  } }' >> "$R"
rl "$d" pass .claude/state codex
eq "$RL_RC" 20 "13 a pass the record has no room for is refused (20)"
has "$RL_OUT" "is at its 1048576-byte bound" "13 …naming the bound"
eq "$(count "$d")" 1 "13 …before anything is dispatched"
rl "$d" carry --severity low --site f.sh:1 --finding nit .claude/state
eq "$RL_RC" 17 "13 …and the full record still reads (17, not 18)"
# Room for the reservation alone is not room for the pass: 200 bytes free take a `start` row and
# leave less than its result needs, so a pass dispatched there could never be recorded.
d="$(fixture)"; script "$d" req:9999 req:0
rl "$d" pass .claude/state codex
R="$d/.claude/state/review-loop.tsv"
awk -v pad="$pad" -v cur="$(wc -c < "$R" | tr -d ' ')" 'BEGIN {
  room = 1048576 - cur - 200
  while (room >= 31) {
    if (room > 345) len = 315; else if (room > 315) len = room - 31; else len = room
    i++; printf "defer\t1\t7\t-\t1\t%05d%s\n", i, substr(pad, 1, len - 20); room -= len
  } }' >> "$R"
rl "$d" pass .claude/state codex
eq "$RL_RC" 20 "13 a record with room for a reservation but not for its result refuses the pass (20)"
# THE DISPATCH COUNT is what tells the refusal apart: a pass reserved there fails with the same 20,
# after the reviewer has run.
eq "$(count "$d")" 1 "13 a pass whose result would not fit is refused before it is dispatched"
eq "$(grep -c '^start' "$R")" 1 "13 …and no second start row is written"
RL_ENV=""
d="$(fixture)"; printf '[reviewers]\nlocal_passes = "until-clean"\n' > "$d/agents.toml"
git -C "$d" add agents.toml; git -C "$d" commit -qm manifest >/dev/null 2>&1
script "$d" req:0
rl "$d" pass .claude/state codex
has "$RL_OUT" "pass 1/until-clean" "13 the manifest spelling reaches the loop"

# =============================== 14. decline and defer (#618) ===================================
# #618 acceptance: a pass whose only REQUIRED finding is deferred with an issue lets the round push.
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" defer --issue 12 --site f.sh:1 --finding 'reads return empty on a database error' .claude/state
eq "$RL_RC" 0 "14 defer records a finding against the issue filed for it"
rl "$d" report .claude/state
eq "$RL_RC" 0 "14 a pass whose only REQUIRED finding is deferred is settled (0): it certifies the tree it read"
eq "$RL_OUT" 'local review: 1 pass · pass 1 -> 1 REQUIRED, settled: every REQUIRED finding of pass 1 was declined or deferred — deferred: 1 (pass 1 #12 `f.sh:1`: `reads return empty on a database error`)' \
   "14 the report line names the deferred finding and its issue"
eq "$(count "$d")" 1 "14 …with no further dispatch"
rl "$d" defer --issue 12 --site f.sh:1 --finding 'reads return empty on a database error' .claude/state
eq "$RL_RC" 10 "14 the identical defer is a no-op (10), so a retry is safe"
rl "$d" defer --issue 13 --site f.sh:1 --finding 'reads return empty on a database error' .claude/state
eq "$RL_RC" 19 "14 the same finding deferred to a different issue is a conflict (19), never a second row"
rl "$d" decline --reason 'not reachable' --site f.sh:1 --finding 'reads return empty on a database error' .claude/state
eq "$RL_RC" 19 "14 a finding already deferred cannot also be declined (19)"
rl "$d" defer --issue 12 --site f.sh:2 --finding 'another' .claude/state
eq "$RL_RC" 17 "14 a disposition past the declared count is refused (17)"
eq "$(grep -c '^defer' "$d/.claude/state/review-loop.tsv")" 1 "14 …and one row is all the record holds"
commit_fix "$d" late
rl "$d" report .claude/state
eq "$RL_RC" 34 "14 a commit after a settled pass un-settles it — the tree it certified is gone"
# …through open-pr's own gate, and through a resolver round's record.
d="$(opfix)"; script "$d" req:1
rl "$d" pass .claude/state codex
rl "$d" defer --issue 12 --site f.sh:1 --finding 'pre-existing' .claude/state
opr "$d"
eq "$RL_RC" 24 "14 a settled loop lets open-pr through to its push"
d="$(fixture)"; git -C "$d" remote add origin https://github.com/o/r.git
PH="$(git -C "$d" rev-parse HEAD)"; commit_fix "$d" unpushed; script "$d" req:1
prl "$d" review-loop pass --pr 7 --head "$PH" .claude/state codex
prl "$d" review-loop defer --pr 7 --head "$PH" --issue 12 --site f.sh:1 --finding 'pre-existing' .claude/state
prl "$d" review-loop report --pr 7 --head "$PH" .claude/state
eq "$RL_RC" 0 "14 a resolver round whose only REQUIRED finding is deferred reports the push-able 0"

# Two findings, one declined: not settled. The other fixed, the next pass's own deferred: settled,
# and the line says how each ended.
d="$(fixture)"; script "$d" req:2 req:1
rl "$d" pass .claude/state codex
rl "$d" decline --reason 'a helper would live better elsewhere: a shape' --site f.sh:1 --finding 'move the helper' .claude/state
eq "$RL_RC" 0 "14 decline records a finding with its reason"
rl "$d" report .claude/state
eq "$RL_RC" 34 "14 a pass with one of two REQUIRED findings declined is NOT settled"
has "$RL_OUT" "1 of 2 REQUIRED finding(s) of pass 1 declined or deferred" "14 …and the line says how far it got"
commit_fix "$d" other
rl "$d" pass .claude/state codex
RL_OUT="$( cd "$d" && env HOME="$FHOME" bash "$IL" review-loop defer --issue 40 --site 'lib/a file.sh:9' --occurrence 2 --finding - .claude/state <<'FINDING' 2>&1
Closes #1 and `Fixes #2`
FINDING
)"; RL_RC=$?
eq "$RL_RC" 0 "14 defer reads --finding - from stdin, with a site that has a space and an occurrence"
rl "$d" report .claude/state
eq "$RL_RC" 0 "14 the later pass, its one finding deferred, settles"
has "$RL_OUT" "\`Closes #1 and 'Fixes #2'\`" "14 a deferred closing keyword is rendered inside a code span, backticks neutralized"
has "$RL_OUT" 'declined: 1 (pass 1 `f.sh:1`: `move the helper` — `a helper would live better elsewhere: a shape`)' \
   "14 the line keeps an EARLIER pass's declined finding, with its reason"
has "$RL_OUT" 'deferred: 1 (pass 2 #40 `lib/a file.sh:9` (occurrence 2): ' "14 …and the deferred one, with its issue and occurrence"
has "$RL_OUT" " — fixed: 1 · declined: 1 " "14 fixed excludes what was declined or deferred: two REQUIRED, one declined, one fixed"
# FIXED is derived from a later pass over a DIFFERENT tree.
d="$(fixture)"; script "$d" req:1 req:0
rl "$d" pass .claude/state codex
rl "$d" pass .claude/state codex
rl "$d" report .claude/state
eq "$RL_RC" 0 "14 a second pass over the unchanged tree may converge"
hasnt "$RL_OUT" "fixed:" "14 a pass retaken on the same tree fixes nothing"
has "$RL_OUT" " — superseded: 1" "14 …and its finding is still accounted for: superseded, since the same tree was read again"
# ANY later pass over a changed tree, not only the next one: trees A, A, B.
d="$(fixture)"; script "$d" req:1 req:1 req:0
rl "$d" pass .claude/state codex
rl "$d" pass .claude/state codex
commit_fix "$d" fixed
rl "$d" pass .claude/state codex
rl "$d" report .claude/state
has "$RL_OUT" "pass 3 -> 0, converged — fixed: 2" "14 fixed counts a pass when ANY later pass read a changed tree, not only the next one"

# Refused fields, and the passes a disposition cannot be taken against.
d="$(fixture)"; script "$d" req:2
rl "$d" defer --issue 12 --site f.sh:1 --finding x .claude/state
eq "$RL_RC" 17 "14 defer with nothing recorded is refused (17)"
rl "$d" pass .claude/state codex
for bad_issue in abc 012 0 '#12' 12345678901; do
  rl "$d" defer --issue "$bad_issue" --site f.sh:1 --finding x .claude/state
  eq "$RL_RC" 19 "14 defer refuses an issue that is not a number (19): '$bad_issue'"
done
rl "$d" decline --reason "$(printf 'a\tb')" --site f.sh:1 --finding x .claude/state
eq "$RL_RC" 19 "14 a reason carrying a TAB is refused (19) — it would forge a field"
rl "$d" defer --issue 12 --site '../x' --finding x .claude/state
eq "$RL_RC" 19 "14 defer takes carry's site rule"
chmod 444 "$d/.claude/state/review-loop.tsv"
rl "$d" defer --issue 12 --site f.sh:1 --finding x .claude/state
chmod 644 "$d/.claude/state/review-loop.tsv"
eq "$RL_RC" 20 "14 a defer that cannot be written fails (20), never reported as recorded"
d="$(fixture)"; script "$d" 127
rl "$d" pass .claude/state codex
rl "$d" defer --issue 12 --site f.sh:1 --finding x .claude/state
eq "$RL_RC" 17 "14 defer against a failed pass is refused (17)"
eq "$(grep -c '^defer' "$d/.claude/state/review-loop.tsv")" 0 "14 …and nothing is appended"

# Exhaustion counts every disposition: a carried LOW beside a deferred finding pushes; a finding
# cannot end two ways; a shortfall still blocks, and its line still names what was deferred.
d="$(fixture)"; RL_ENV="ADB_LOCAL_REVIEW_PASSES=1"; script "$d" req:2
rl "$d" pass .claude/state codex
rl "$d" defer --issue 5 --site f.sh:1 --finding 'old bug' .claude/state
rl "$d" carry --severity low --site f.sh:1 --finding 'old bug' .claude/state
eq "$RL_RC" 19 "14 a finding already deferred cannot also be carried (19)"
rl "$d" carry --severity low --site f.sh:2 --finding 'a nit' .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 33 "14 an exhaustion with one finding carried LOW and the other deferred pushes (33)"
has "$RL_OUT" ' — deferred: 1 (pass 1 #5 `f.sh:1`: `old bug`) · carried: 1 (pass 1 low `f.sh:2`: `a nit`)' "14 …naming both"
d="$(fixture)"; script "$d" req:3
rl "$d" pass .claude/state codex
rl "$d" defer --issue 5 --site f.sh:1 --finding 'old bug' .claude/state
rl "$d" carry --severity low --site f.sh:2 --finding 'a nit' .claude/state
rl "$d" report .claude/state
eq "$RL_RC" 39 "14 an exhaustion one disposition short still BLOCKS"
has "$RL_OUT" "3 REQUIRED finding(s), 1 carried, 1 declined or deferred" "14 …and names the shortfall"
has "$RL_OUT" "deferred: 1 (pass 1 #5 " "14 a BLOCKED line still names what was deferred"
RL_ENV=""

# The reader enforces what the writers promise: these rows are ones no writer can emit.
d="$(fixture)"; script "$d" req:2 req:1
rl "$d" pass .claude/state codex; commit_fix "$d" a
rl "$d" pass .claude/state codex
printf 'defer\t1\t12\tf.sh:1\t1\told\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "14 a defer row against an earlier pass refuses the record"
d="$(fixture)"; script "$d" req:2
rl "$d" pass .claude/state codex
printf 'defer\t1\t12\tf.sh:1\t1\tx\ndecline\t1\tf.sh:1\t1\tx\tbecause\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "14 a finding both deferred and declined refuses the record"
d="$(fixture)"; script "$d" req:2
rl "$d" pass .claude/state codex
printf 'defer\t1\t12\tf.sh:1\t1\tx\ncarry\t1\tlow\tf.sh:1\t1\tx\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "14 a finding deferred and then carried refuses the record"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'defer\t1\t12\tf.sh:1\t1\tx\ndefer\t1\t12\tf.sh:2\t1\ty\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "14 more dispositions than the pass declared REQUIRED refuses the record"
d="$(fixture)"; script "$d" req:1
rl "$d" pass .claude/state codex
printf 'defer\t1\tabc\tf.sh:1\t1\tx\n' >> "$d/.claude/state/review-loop.tsv"
rl "$d" report .claude/state
eq "$RL_RC" 18 "14 a defer row whose issue is not a number refuses the record"

# =============================== 15. the whole-run summary (#618) ===============================
# One record per /implement-issue run and per resolver round; `summary` reads the run whole.
d="$(fixture)"; git -C "$d" remote add origin https://github.com/o/r.git
S="$d/.claude/state"
marker() { jq -n --arg u "$2" '{branch:"issue-7-x", issue:"7", phase:"pr_opened", startedAt:"2026-09-28T00:00:00Z", prUrl:$u}' > "$1/implement-issue-active.json"; }
marker "$S" "https://github.com/o/r/pull/7"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 11 "15 summary with nothing recorded is 11"
script "$d" req:2 req:0
rl "$d" pass .claude/state codex; commit_fix "$d" impl
rl "$d" pass .claude/state codex
H1="$(git -C "$d" rev-parse HEAD)"; PH="$H1"; commit_fix "$d" round1; script "$d" req:1
prl "$d" review-loop pass --pr 7 --head "$H1" .claude/state codex
prl "$d" review-loop decline --pr 7 --head "$H1" --reason 'a shape, not a defect' --site f.sh:3 --finding 'could be more thorough' .claude/state
H2="$(git -C "$d" rev-parse HEAD)"; PH="$H2"; commit_fix "$d" round2; script "$d" req:0
prl "$d" review-loop pass --pr 7 --head "$H2" .claude/state codex
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 0 "15 summary renders a run of one implementation record and two rounds"
has "$RL_OUT" "local review, whole run: 4 pass(es) in 3 record(s) — REQUIRED per pass: 2, 0, 1, 0 — fixed: 2 · superseded: 0 · declined: 1 · deferred: 0 · carried: 0 · open: 0" \
   "15 the first line carries the run's total passes, each pass's REQUIRED count, and how the findings ended"
has "$RL_OUT" "  /implement-issue: pass 1 -> 2 REQUIRED · pass 2 -> 0" "15 …then one line per record"
has "$RL_OUT" "  declined — round from ${H1:0:12}, pass 1: \`f.sh:3\`: \`could be more thorough\` — \`a shape, not a defect\`" \
   "15 …and one per finding that ended without a fix, with its reason"
L1="$(printf '%s\n' "$RL_OUT" | grep -n -m1 -F "  round from ${H1:0:12}:" | cut -d: -f1)"
L2="$(printf '%s\n' "$RL_OUT" | grep -n -m1 -F "  round from ${H2:0:12}:" | cut -d: -f1)"
order "15 summary orders the rounds by ancestry, oldest first" "$L1" "$L2"
rl "$d" summary .claude/state
has "$RL_OUT" "2 pass(es) in 1 record(s)" "15 without --pr it is the run's own record alone"
marker "$S" "https://github.com/o/r/pull/8"
prl "$d" review-loop summary --pr 7 .claude/state
has "$RL_OUT" "2 pass(es) in 2 record(s)" "15 summary --pr leaves out a run record whose marker names another PR"
has "$RL_OUT" "/implement-issue: not counted" "15 …and says it left it out"
# A record with no pass in it is still a record: its line says why, and the counts stay empty.
e="$(fixture)"
( cd "$e" && env HOME="$FHOME" bash "$IL" review-loop pass --unavailable none .claude/state ) >/dev/null 2>&1
RL_OUT="$( cd "$e" && env HOME="$FHOME" bash "$IL" review-loop summary .claude/state 2>&1 )"; RL_RC=$?
eq "$RL_RC" 0 "15 summary reads a record that holds no pass"
has "$RL_OUT" "0 pass(es) in 1 record(s) — REQUIRED per pass: none" "15 …with no count invented for it"
has "$RL_OUT" "/implement-issue: no usable reviewer, no pass" "15 …and its line says why there was none"
cp "$S/review-loop-pr7-${H2:0:12}.tsv" "$S/review-loop-pr7-aaaaaaaaaaaa.tsv"
prl "$d" review-loop summary --pr 7 .claude/state
has "$RL_OUT" "round from aaaaaaaaaaaa (position unknown" "15 a round whose head no longer resolves is listed last, and says so"
rm -f "$S/review-loop-pr7-aaaaaaaaaaaa.tsv"
# A run marker that exists and cannot be read answers nothing about whose the run record is.
marker "$S" "https://github.com/o/r/pull/7"
printf '{"prUrl": ' > "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 summary refuses (20) a run marker it cannot read — never a summary without the run's passes"
printf '[]\n' > "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and one that is not a marker object"
printf '{"prUrl":"https://github.com/o/r/pull/7"}\n{"prUrl":"https://github.com/o/r/pull/8"}\n' > "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a marker that is two objects: which one names the run cannot be decided"
marker "$S" "https://example.com/not-a-pull-request"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a marker whose prUrl is not a pull-request URL"
printf '{"prUrl": false}\n' > "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a marker whose prUrl is false — a wrong type is not an absent field"
marker "$S" "7"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a marker whose prUrl is a bare number, which names no repository"
marker "$S" "https://git hub.com/o/r/pull/7"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a marker whose prUrl holds whitespace"
marker "$S" "$(printf 'https://github.com/o/r/pull/7\nx')"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …a newline included"
jq -n --arg u "https://github.com/o/r/pull/7" --arg pad "$(printf 'p%.0s' $(seq 70000))" '{prUrl:$u, pad:$pad}' > "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 …and a run marker past 64 KiB, which is read under the lock"
marker "$S" "https://github.com/o/r/pull/7"
# The snapshot is bounded in count as well: it is taken under a lock that is reclaimed when stale.
for i in $(seq 1 201); do printf 'x\n' > "$S/review-loop-pr9-$(printf '%012x' "$i").tsv"; done
prl "$d" review-loop summary --pr 9 .claude/state
eq "$RL_RC" 20 "15 summary refuses (20) more round records than the snapshot's bound"
rm -f "$S"/review-loop-pr9-*.tsv
# A record that is not a regular file is never followed.
mv "$S/review-loop.tsv" "$S/elsewhere.tsv"; ln -s elsewhere.tsv "$S/review-loop.tsv"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 summary refuses (20) a record that is a symbolic link"
rm -f "$S/review-loop.tsv"; mv "$S/elsewhere.tsv" "$S/review-loop.tsv"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 0 "15 …and reads the run again once it is the record itself"
rm -f "$S/implement-issue-active.json"
prl "$d" review-loop summary --pr 7 .claude/state
has "$RL_OUT" "not counted — a run record is here with no run marker" "15 a run record with no marker beside it is left out, and the line says why"
marker "$S" "https://github.com/o/r/pull/7"
# A directory that cannot be listed hides its round records: that is unknown, never "nothing".
if [ "$(id -u)" != 0 ]; then
  chmod 0333 "$S"
  prl "$d" review-loop summary --pr 7 .claude/state
  chmod 0755 "$S"
  eq "$RL_RC" 20 "15 summary refuses (20) a state directory it cannot list"
else
  check_note "running as root — the unlistable-directory case needs a permission that binds"
fi
# The order is the summary's: a sort that fails must not print one with the rounds missing.
NB="$work/nosort"; mkdir -p "$NB"; printf '#!/bin/sh\nexit 1\n' > "$NB/sort"; chmod +x "$NB/sort"
RL_OUT="$( cd "$d" && env HOME="$FHOME" PATH="$NB:$CB:$SB:$PATH" PR_HEAD="$PH" bash "$IL" review-loop summary --pr 7 .claude/state 2>&1 )"; RL_RC=$?
eq "$RL_RC" 20 "15 summary refuses (20) when the rounds cannot be ordered"
hasnt "$RL_OUT" "local review, whole run:" "15 …and prints no summary line"
# Membership and the reads happen under the loop's lock.
mkdir "$S/.review-loop-mutex"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 20 "15 summary reads under the loop's lock, and refuses (20) when it cannot take it"
rmdir "$S/.review-loop-mutex"
printf 'bogus\tx\n' >> "$S/review-loop-pr7-${H2:0:12}.tsv"
prl "$d" review-loop summary --pr 7 .claude/state
eq "$RL_RC" 18 "15 summary refuses (18) when a round record does not parse — never a partial run"
# Every REQUIRED finding has an outcome: 3 on tree A (one declined), 2 on A again, then 1 on B, open.
e="$(fixture)"; script "$e" req:3 req:2 req:1
rl "$e" pass .claude/state codex
rl "$e" decline --reason 'a shape' --site f.sh:1 --finding 'x' .claude/state
rl "$e" pass .claude/state codex
commit_fix "$e" b
rl "$e" pass .claude/state codex
rl "$e" summary .claude/state
has "$RL_OUT" "REQUIRED per pass: 3, 2, 1 — fixed: 4 · superseded: 0 · declined: 1 · deferred: 0 · carried: 0 · open: 1" \
   "15 the outcomes add up to the REQUIRED total: 3 + 2 + 1 = 4 fixed + 1 declined + 1 open"
e="$(fixture)"; script "$e" req:2 req:0
rl "$e" pass .claude/state codex
rl "$e" pass .claude/state codex
rl "$e" summary .claude/state
has "$RL_OUT" "REQUIRED per pass: 2, 0 — fixed: 0 · superseded: 2 · " "15 a finding a later pass on the same tree no longer raised is superseded, never dropped from the totals"

# =============================== 16. the reviewer brief (#618) ==================================
d="$(fixture)"; script "$d" req:0
rl "$d" pass .claude/state codex
RP="$(cat "$d/.claude/state/review-prompt.txt")"
has "$RP" "a defect this diff INTRODUCES, or one it makes REACHABLE" "16 the brief scopes REQUIRED to what the diff introduced or made reachable"
has "$RP" 'under a separate heading `PRE-EXISTING`' "16 …and gives a defect in code the diff only calls its own heading"
has "$RP" "a PRE-EXISTING item counts toward neither" "16 …which the verdict trailer does not count"

# =============================== 11. the prose drives the loop ==================================
# #491 acceptance: step 9 calls the loop before step 10; the resolver calls it before the push and
# before step 7's re-request. A command is located only INSIDE a fenced block — a prose mention of it
# is not a call, and ordering pins that matched prose would stay green with the call deleted.
IPASS="$(code_line_of "$IW" 'review-loop pass ${EFFORT:+--effort "$EFFORT"} {{STATE_DIR}} "$REVIEW_TOKEN"')"
IBEGIN="$(code_line_of "$IW" 'review-loop begin {{STATE_DIR}} "$REVIEW_TOKEN"')"
IREPORT="$(code_line_of "$IW" 'review-loop report {{STATE_DIR}}')"
order "11 implement-issue step 9 calls the loop before step 10" "$IPASS" "$(line_of "$IW" '### 10. Push + open PR')"
order "11 …inside step 9, after the first triage" "$(line_of "$IW" '### 9. Triage + fix')" "$IPASS"
order "11 …and reports it before the rule-sweep is recorded over the final tree" "$IREPORT" "$(line_of "$IW" '# ADB-SNIPPET: rule-sweep')"
order "11 the native branch is taken BEFORE a CLI pass could be spent" "$IBEGIN" "$IPASS"
order "11 the native Claude review path records its pass in an executable line, after begin" "$IBEGIN" "$(code_line_of "$IW" 'review-loop pass --published {{STATE_DIR}} "$REVIEW_TOKEN"')"
order "11 the carry recipe passes the finding through a quoted heredoc" "$(code_line_of "$IW" "--finding - {{STATE_DIR}} <<'FINDING'")" "$(line_of "$IW" '### 10. Push + open PR')"
RPASS="$(code_line_of "$RW" 'review-loop pass --pr "$PR_NUM" --head "$SWEEP_HEAD"')"
RREPORT="$(code_line_of "$RW" 'review-loop report --pr "$PR_NUM" --head "$SWEEP_HEAD"')"
RPUSH="$(code_line_of "$RW" 'git push origin "${PUSH_SHA}:refs/heads/${PR_BRANCH}"')"
order "11 the resolver runs the loop before its push" "$RPASS" "$RPUSH"
order "11 …reads the commit it will push BEFORE the report certifies it" "$(code_line_of "$RW" 'PUSH_SHA="$NOW_HEAD"')" "$RREPORT"
order "11 …and refuses a push SHA that is not 40 hex (an empty one would DELETE the branch)" "$(code_line_of "$RW" '[ "${#PUSH_SHA}" -eq 40 ] ||')" "$RPUSH"
order "11 4a refuses a round head that is not a commit id" "$(code_line_of "$RW" 'SWEEP_HEAD="$(git rev-parse --verify HEAD 2>/dev/null)"')" "$(code_line_of "$RW" '[ "${#SWEEP_HEAD}" -eq 40 ] ||')"
[ -n "$(code_line_of "$RW" 'HEAD did not move but the worktree has changes')" ] && ok || bad "11 4d refuses a no-change round over an uncommitted fix"
order "11 …re-reads the PR live between the report and the push" "$(code_line_of "$RW" 'gh pr view "$PR_NUM" --json state,headRefOid')" "$RPUSH"
order "11 …and refuses the push unless the PR is OPEN at the round head" "$(code_line_of "$RW" '[ "$LIVE" = "OPEN $SWEEP_HEAD" ]')" "$RPUSH"
LG="$(code_line_of "$RW" 'ledger unreadable — no counts')"
[ -n "$LG" ] && ok || bad "11 an unreadable ledger still records the round's row"
GUARD_END="$(grep -n -B1 -F '# OUTSIDE the ledger guard' "$RW" | head -1 | cut -d- -f1)"
[ "$(sed -n "${GUARD_END:-0}p" "$RW")" = "fi" ] && ok || bad "11 the ledger guard closes before the sweep and local review lines"
order "11 …so both are appended OUTSIDE it" "$GUARD_END" "$(code_line_of "$RW" 'ROUND_ROWS="${ROUND_ROWS}  ${SWEEP_LINE}"')"
order "11 …the local review line included" "$GUARD_END" "$(code_line_of "$RW" 'ROUND_ROWS="${ROUND_ROWS}  ${LOOP_LINE:-local review: not reported}"')"
has "$(grep -F 'Per round so far' "$RW")" 'LOOP_LINE' "11 a blocked round still reports its loop line with the rows so far"
for stop in 'the loop is not finished — take another pass' 'the worktree is not clean — commit it, then take another pass' \
            'STOP: HEAD moved (or could not be read) while the report ran' 'STOP: could not re-read PR #$PR_NUM before pushing' \
            'STOP: PR #$PR_NUM is no longer OPEN at the round' "STOP: could not push this round's commits"; do
  has "$(grep -F -- "$stop" "$RW")" '$LOOP_LINE' "11 the 4d exit '$stop' reports the loop line it already rendered"
done
order "11 …and before step 7's re-request" "$RPASS" "$(line_of "$RW" '### 7. Ask for a re-review')"
order "11 …after 4c, so the reviewed diff includes the ledger commit" "$(line_of "$RW" '#### 4c. Promote what has become a pattern')" "$RPASS"
eq "$(grep -c 'git push origin' "$RW")" 1 "11 the resolver pushes ONCE per round — the fix and ledger pushes are consolidated"
[ -n "$RPUSH" ] && ok || bad "11 …by the SHA the report certified, never by branch name"
grep -q '^# *local_passes' "$ROOT/templates/agents.toml" && ok || bad "11 the template declares the key"
# #618 acceptance: step 9 and 4d document the new dispositions, where a pass can precede them.
IDEFER="$(code_line_of "$IW" 'review-loop defer --issue <n>')"
order "11 step 9 documents the defer disposition, after the pass it is taken against" "$IPASS" "$IDEFER"
order "11 …and before step 10" "$IDEFER" "$(line_of "$IW" '### 10. Push + open PR')"
[ -n "$(code_line_of "$IW" 'review-loop decline --reason')" ] && ok || bad "11 step 9 documents the decline disposition"
RDEFER="$(code_line_of "$RW" 'review-loop defer --pr "$PR_NUM" --head "$SWEEP_HEAD" --issue <n>')"
order "11 4d documents the defer disposition, after its pass" "$RPASS" "$RDEFER"
order "11 …and before the round's push" "$RDEFER" "$RPUSH"
[ -n "$(code_line_of "$RW" 'review-loop decline --pr "$PR_NUM" --head "$SWEEP_HEAD" --reason')" ] && ok || bad "11 4d documents the decline disposition"
[ -n "$(code_line_of "$RW" 'WHOLE_RUN="$({{IMPLEMENT_LIB}} review-loop summary --pr "$PR_NUM" {{STATE_DIR}})"')" ] && ok || bad "11 the resolver's closing summary renders the whole run"
RBLOCK="$(code_line_of "$RW" 'Per round so far')"
RBSUM="$(code_line_of "$RW" '{{IMPLEMENT_LIB}} review-loop summary --pr "$PR_NUM" {{STATE_DIR}}; WRC=$?')"
order "11 …and so does every exit that ends a round, through one helper that prints the rows and the whole run" "$RBLOCK" "$RBSUM"
order "11 …defined before the push it can stop" "$RBSUM" "$RPUSH"
for stop in 'STOP: HEAD moved (or could not be read) while the report ran' 'STOP: could not re-read PR #$PR_NUM before pushing' \
            'STOP: PR #$PR_NUM is no longer OPEN at the round'; do
  has "$(grep -F -- "$stop" "$RW")" 'round_report; exit 1' "11 the 4d exit '$stop' reports the run before it ends the round"
done
eq "$(awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } f && /^[[:space:]]*round_report$/ { n++ } END { print n + 0 }' "$RW")" 2 \
   "11 …and so do the blocked verdict and the failed push"
grep -q '"until-clean"' "$ROOT/templates/agents.toml" && ok || bad "11 the template documents until-clean"

check_summary check-review-loop
