#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the async-reviewer status detector (scripts/lib/pr-watch.sh, #49).
# OFFLINE: no network, no gh auth, no real repo is touched.
#
# The detector has exactly one dangerous direction: reporting `clean` when the declared reviewer
# has NOT passed the current head. Every case below is chosen because it is a way that could
# happen, or a way the detector could wedge and either watch forever or hand off a healthy PR:
#
#   1. STALENESS. A review carries `commit_id`; a REACTION CARRIES NO COMMIT. A `+1` left on an
#      earlier head survives new commits, so reading it naively reports `clean` for code nobody
#      reviewed. The timestamp rule is pinned in BOTH directions, including the boundary where they
#      are equal.
#   1b. AND ITS LOWER BOUND IS SERVER-ASSIGNED (#175). That rule used to compare against the head
#      commit's COMMITTER DATE, which GitHub echoes back verbatim from the committing machine — so a
#      past-dated head made a stale `+1` look fresh, a false `clean`, with no attacker required. The
#      anchor is now the repository ACTIVITY record for the head REF, and the tests pin three things
#      a weaker anchor would get wrong: the same SHA arriving on ANOTHER ref must not date this one
#      (which is exactly why a check-suite anchor was rejected); the LATEST record decides, so a
#      reverse force-push is caught; and an anchor that cannot be established is `pending` on BOTH
#      date-scoped signals. The committer date is asserted to be NEVER FETCHED, not merely outvoted.
#   2. IDENTITY, ASYMMETRICALLY. The same App is spelled two ways depending on which API answered,
#      and a declaration may use either — but the normalization runs ONE WAY ONLY (#173): the API
#      login is normalized toward the declaration, never the reverse. Stripping both sides let a
#      declared `foo[bot]` be satisfied by a HUMAN account named `foo`, and reactions are publicly
#      writable, so on that signal the bar was a login collision and nothing else. Pinned on all
#      THREE signals, because the rule had three inline copies here and one shared predicate has to
#      be proved on each — plus a WRONG bot, which must satisfy none of them.
#   2b. REPOSITORY IDENTITY. Every read addresses `repos/{owner}/{repo}`, so the detector can be
#      pointed at another project by a URL argument naming one, or — when the argument is the bare
#      number `/resolve-pr-threads --watch` passes — by `GH_REPO` redirecting gh's own expansion.
#      Both are refused, and the anchor is the set of repositories the checkout's git remotes name —
#      which no gh variable can move, and which accepts a fork or upstream-only layout.
#   3. THERE ARE THREE SURFACES, AND THEY ARE ORDERED. The connector has two operating modes and
#      the repo does not pick which it gets: WITHOUT a Codex Cloud environment it posts a review
#      object (+ inline threads) for findings and a bare `+1` reaction for a clean pass; WITH one it
#      runs as a task and posts findings as a single ISSUE COMMENT — no review, no threads, no
#      reaction — and a clean pass as a `+1` plus a same-second comment, which pairs clean. Both
#      shapes were observed on this repo the same day (PR #166 at 08:01 vs PR #178 at 19:30, after
#      an environment was created). Reading only reviews wedges at `pending` forever on the second.
#      Findings outrank clean; a review at the head outranks a comment.
#   4. NON-SIGNALS. A `PENDING` (unsubmitted draft) or `DISMISSED` review is not the reviewer
#      having spoken, and a review of an OLDER commit is not a review of this one.
#   5. EVERY UNREADABLE PATH -> 20, never `clean`. A failed read must not look like a pass.
#   6. THE BOUND IS A BOUND. `wait` must stop at its deadline, must never sleep past it, must not
#      abandon a watch on one transient error, and must give up rather than poll an endlessly
#      unreadable API forever.
#
# What genuinely CANNOT be tested here (needs a live run): which SHAPE the connector emits, since
# that is decided by vendor-side configuration rather than by anything in the repo — verified live
# here (PRs #53/#54/#66/#83/#88 carry a `+1` with zero reviews; #127/#137/#145/#146/#154/#166 carry
# a review with zero reactions; #178 carries one issue comment with zero reviews and zero
# reactions); that it re-reviews after a push (it does NOT — its triggers are open /
# ready-for-review / an explicit `@codex review`); and GitHub's eventual consistency between the
# endpoints. A stub can prove the PARSING and the DECISION; it can never prove the premise — which
# is exactly why the decision reads all three surfaces instead of the one the vendor documents.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pr-watch.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
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
PW="$ROOT/scripts/lib/pr-watch.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

[ "$#" -gt 1 ] && { echo "usage: check-pr-watch.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-pr-watch.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
# A SUITE THAT SKIPS ITS OWN VERDICT MUST NOT REPORT SUCCESS. Plain `rm -rf` was enough while the
# only way out was the bottom of the file; `--mutation` below adds an `exit 0` after its own
# `check_summary`, and an edit that loses that call would exit 0 having counted nothing.
check_exit_guard "check-pr-watch" "rm -rf \"$work\""

# ============= --mutation: section 11's cases must be OBSERVED going red (#394) =================
# WHY A MODE AND NOT MORE ASSERTIONS. Section 11's cases can pass while looking at nothing — a
# green there is not by itself evidence that anything was checked (D85). So each row breaks ONE
# thing the section claims to catch, runs the WHOLE suite against the broken copy, and requires it
# back at exit 1 carrying THAT CASE'S OWN witness (#213's `fires:` contract).
#
# SCOPED TO SECTION 11, #447's PAIR RULE AND THE HEAD-CI READ (#448), said plainly so nobody reads
# it as more: it proves the BOUNDED-WAIT cases, the `+1`/comment pairing and status-comment filter,
# and section 14's CI guards can fire. It is not a mutation suite for `pr-watch.sh` at large; the
# other classification sections are covered by their own assertions and by nothing here.
#
# THREE POOLS, because the harness these rows were written for built one target path per pool and
# these witnesses live in two files — the wait loop's own reporting (`pr-watch.sh`), and the
# staleness rule and #447's pair rule it delegates to (`common.sh`). shmutant could carry both files
# in one table (`shmutant_target` per group); the port to it (#519) is 1:1 and keeps the shape.
#
# THE CONTROL RUNS FIRST, and the reason is causal rather than ceremonial. Every row below reads a
# FAILURE, and a row is killed when SOME `FAIL:` line carries its witness —
# so a copied baseline that already fails on that witness would credit the row for a defect the
# mutation never caused. Checking that the literal APPLIED proves the edit landed, not that it is
# what turned the suite red. The unmutated `pr-watch` step reddens the whole selfcheck if the tree
# is broken, but it cannot make a STANDALONE `--mutation` invocation sound, and this mode is
# runnable on its own.
if [ "$MODE" = mutation ]; then
  # mut_run <copy-dir> — the nested suite, behind a parse check on both mutated files. A mutation
  # that stops either one PARSING has changed whether the code runs at all rather than how it
  # behaves, and the nested suite would still fail on the right witness — crediting the row for a
  # defect it never exercised. 9 makes the pool report an ABORT, which is what it was.
  # `"$BASH"`, not a bare `bash` — the same rule the mono probe below states, for the same reason:
  # this file has re-exec'd itself onto a >= 5.3 interpreter but did NOT rewrite `PATH`, so on macOS
  # a bare `bash` still resolves /bin/bash 3.2.57. The nested suite gates its own interpreter and
  # was measured surviving that (it re-execs and passes), so this is not the abort the review
  # supposed — but parse-checking a 5.3 file with 3.2 is the wrong question to ask, and paying a
  # re-exec per nested run is waste. `$BASH` is by construction the interpreter this file runs on.
  mut_run() {
    local d="$1"
    "$BASH" -n "$d/scripts/lib/pr-watch.sh" 2>/dev/null \
      || { printf 'the mutated pr-watch.sh no longer PARSES\n'; return 9; }
    "$BASH" -n "$d/scripts/lib/common.sh" 2>/dev/null \
      || { printf 'the mutated common.sh no longer PARSES\n'; return 9; }
    "$BASH" "$d/scripts/check-pr-watch.sh" 2>&1
  }
  # `scripts` alone is this suite's whole mutation surface, so the subtree copier rather than the
  # worktree one: copies of the repo's ~66MB .git would be spent moving a tree about to be deleted
  # (check_copy_subtrees' own header measures that). Built ONCE per pool; shmutant clones it per row,
  # and `shmutant_target` names the file each row mutates (#519).
  mut_prep() { check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1; }

  # THE CONTROL: the same tree, unmutated. (The pools run no baseline of their own —
  # check_shmutant_pool sets SHMUTANT_BASELINE=0 — so this is the one that proves the copy green.)
  mut_ctl="$work/control"
  if mut_prep "$mut_ctl"; then
    mut_out="$(mut_run "$mut_ctl" 2>&1)"; mut_rc=$?
    yes "$mut_rc" "control: an UNMUTATED copy passes (else every row below is red for the wrong reason)"
    case "$mut_out" in
      *" 0 failed"*) ok ;;
      *) bad "control: the unmutated copy did not report a clean suite" ;;
    esac
  else
    bad "control: could not build the unmutated copy"
  fi

  # --- the wait loop's own reporting and bounding ----------------------------------------------
  # shellcheck source=/dev/null
  . "$ROOT/scripts/shmutant.sh" || bad "pr-watch: scripts/shmutant.sh could not be sourced"
  shmutant_target scripts/lib/pr-watch.sh
  # The head move goes unreported. The rest of the watch is untouched, so ONLY the two assertions
  # that read that line can catch it — which is the point.
  shmutant_mut "head-move-unreported" \
    'head moved $lasthead -> $head; any earlier signal no longer applies' \
    'head changed; any earlier signal no longer applies' \
    'wait: reports that the head moved under it'
  # The nap is no longer clamped to what remains, so an oversized `--interval` overshoots the bound.
  # Deleting the clamp leaves the requested 3000, which overshoots both the bound and what remains —
  # the same assertion `nap-is-the-bound` trips, from the other direction. Two defects, one witness:
  # a row proves THAT assertion fires for THAT defect, not that it owns it.
  shmutant_mut "nap-unclamped" \
    '[ "$nap" -gt "$remaining" ] && nap="$remaining"' \
    ':' \
    'wait: sleeps what REMAINS, not the original bound'
  # The interval is ignored and the nap becomes a constant. Caught ONLY by the two-bound tracking
  # assertion — the ceilings above are satisfied by any constant that happens to sit under them,
  # which is exactly how the earlier single-scenario version of that case passed a flat zero.
  shmutant_mut "nap-constant" \
    'nap="$OPT_INTERVAL"' \
    'nap=0' \
    'wait: the nap TRACKS the remaining bound'
  # The nap becomes the ORIGINAL bound rather than what is left of it, so the watcher oversleeps the
  # deadline by exactly however long the poll before it cost. Invisible to every ceiling that
  # compares against `--max-secs` itself, which is why the scenario forces latency into poll 1.
  shmutant_mut "nap-is-the-bound" \
    'nap="$remaining"' \
    'nap="$OPT_MAX_SECS"' \
    'wait: sleeps what REMAINS, not the original bound'
  # THE DEFECT #394 REPORTS, injected at its source: a deadline the fixture cannot outlive. Pinning
  # it to 3s reproduces what a starved runner did to the retired bound, and the case that must
  # notice is the one whose first poll is deliberately slow.
  shmutant_mut "deadline-beats-the-fixture" \
    "printf '%s' \"\$(( BASH_MONOSECONDS + OPT_MAX_SECS ))\"" \
    "printf '%s' \"\$(( BASH_MONOSECONDS + 3 ))\"" \
    'wait: a first poll outliving the retired bound no longer ends the watch'
  check_shmutant_pool "pr-watch-wait" "$work/mw" mut_prep mut_run 4

  # --- the staleness rule the wait delegates to -------------------------------------------------
  # A SECOND TABLE, so the table must be cleared first: `shmutant_mut` appends, and a stale row would
  # be re-run against the wrong target and scored `unapplied`.
  #
  # Both witnesses below are the DISTINCTIVE PREFIX of their assertion rather than the whole label:
  # the labels carry an apostrophe, and quoting one inside a literal here costs more legibility than
  # the extra words buy. shmutant matches a witness as a whole TOKEN, so each prefix ends where its
  # label continues with a space or punctuation. No other assertion in this suite starts with either.
  shmutant_reset
  shmutant_target scripts/lib/common.sh
  # The staleness comparison loses its backslash — the exact regression common.sh's own comment
  # warns about, and the one that turns every signal fresh with no error anywhere.
  shmutant_mut "staleness-disarmed" \
    'elif [ "$val" \> "$anchor" ]; then' \
    'elif [ "$val" > "$anchor" ]; then' \
    'wait: a signal from the PREVIOUS head'
  # The verdict stays right and the REASON stops being said. `at $val predates this head` rather
  # than the shorter phrase, because the shorter one also appears in the comment above the echo and
  # a row that edits a comment tests nothing.
  shmutant_mut "staleness-unexplained" \
    'at $val predates this head' \
    'at $val is not evidence about this head' \
    'wait: says WHY the previous era'
  check_shmutant_pool "pr-watch-staleness" "$work/ms" mut_prep mut_run 4

  # --- the #447 pair rule and status-comment filter ---------------------------------------------
  shmutant_reset
  shmutant_target scripts/lib/common.sh
  # The `+1` no longer has to be as new as the comment, so a reviewer speaking again reads clean.
  shmutant_mut "pair-ignores-order" \
    'if [ -n "$pnew" ] && ! [ "$cnew" \> "$pnew" ]; then' \
    'if [ -n "$pnew" ]; then' \
    'pair: a comment NEWER than the'
  # The `+1` is no longer required at all, so a lone task-mode comment stops reading as findings.
  shmutant_mut "pair-without-plus1" \
    'if [ -n "$pnew" ] && ! [ "$cnew" \> "$pnew" ]; then' \
    'if :; then' \
    'task mode: an issue comment from the reviewer, newer than the head -> findings'
  # The status marker is recognised and then kept, so a Running review reads as findings again.
  shmutant_mut "status-comment-kept" \
    'if [ "$status" = "true" ]; then' \
    'if false; then' \
    'status: a fresh Running status comment alone is pending'
  check_shmutant_pool "pr-watch-pair" "$work/mp" mut_prep mut_run 3

  # --- the head's CI (#448): PER-TEST rows, each running only the block that witnesses it --------
  # Every literal is read from a quoted heredoc, so the code it names arrives byte-for-byte; the row
  # table refuses one that is absent, repeated or multi-line before anything is built.
  lit() { IFS= read -r REPLY; printf '%s' "$REPLY"; }
  PWT=scripts/lib/pr-watch.sh
  check_row ci-settle-dropped "$PWT" ci-wait "$(lit <<'L'
        if [ "$greens" -ge "$_ADB_PW_CI_SETTLE" ] && [ "$remaining" -gt 0 ]; then
L
)" '        if [ "$remaining" -gt 0 ]; then' 'ci-wait: green is reported only after it held across two polls'
  check_row ci-settle-ignores-set "$PWT" ci-wait "$(lit <<'L'
        if [ "$greens" -gt 0 ] && [ -n "$sig" ] && [ "$sig" = "$lastsig" ]; then
L
)" '        if [ "$greens" -gt 0 ]; then' 'ci-wait: green must hold over an identical check set'
  check_row ci-red-waits "$PWT" ci-wait '      40|41|12|2)' '      41|12|2)' \
    'ci-wait: a red arriving mid-wait returns not-green at once'
  check_row ci-expiry-says-green "$PWT" ci-wait "$(lit <<'L'
      [ -n "$out" ] && printf 'indeterminate %s\n' "$head"
L
)" "$(lit <<'L'
      [ -n "$out" ] && printf '%s\n' "$out"
L
)" 'ci-wait: ...and its stdout does not say green'
  check_row ci-wait-narrates "$PWT" ci-wait "$(lit <<'L'
    line="$_PW_CI_LINE"; sig="$_PW_CI_SIG"; running="$_PW_CI_UNSETTLED"
L
)" "$(lit <<'L'
    line="$_PW_CI_LINE"; sig="$_PW_CI_SIG"; running="$_PW_CI_UNSETTLED"; printf '%s\n' "$line" >&2
L
)" 'ci-wait: quiet while it polls'
  check_row ci-allowlist-dropped "$PWT" ci-read "$(lit <<'L'
      def clean: tostring | gsub("[^A-Za-z0-9 ._,:/()+=@#-]"; "?");
L
)" '      def clean: tostring;' 'ci: a job name is rendered through the allowlist'
  check_row ci-filter-defaulted "$PWT" ci-read 'check-runs?filter=latest&per_page=100' \
    'check-runs?per_page=100' 'ci: check runs are read with filter=latest'
  check_row ci-incomplete-accepted "$PWT" ci-read "$(lit <<'L'
      | if ($all | length) != $t then error("the list is incomplete") else . end
L
)" '      | .' 'ci: a check-run list shorter than its total_count is incomplete'
  check_row ci-required-ignored "$PWT" ci-read "$(lit <<'L'
  hin="$(printf '{"check_runs":%s,"statuses":%s,"required_contexts":%s}' "$runs" "$sts" "$req")"
L
)" "$(lit <<'L'
  hin="$(printf '{"check_runs":%s,"statuses":%s,"required_contexts":[]}' "$runs" "$sts")"
L
)" 'ci: a required context that has not reported is not green'
  check_row ci-base-defaulted "$PWT" ci-read "$(lit <<'L'
  bpath="$(adb_url_path_segment "$base")" \
L
)" "$(lit <<'L'
  bpath="$(adb_url_path_segment "${base:-main}")" \
L
)" 'ci: a pull request with no base branch cannot have its required checks read'
  check_row ci-status-sha-unchecked "$PWT" ci-read "$(lit <<'L'
      | if any(.[]; ((.sha // "") | ascii_downcase) != ($sha | ascii_downcase))
L
)" '      | if false' 'ci: a status document for another commit is unreadable'
  check_row ci-permission-bypassed "$PWT" ci-read "$(lit <<'L'
         && perm="$(printf '%s' "$pj" | jq -r '.permission // ""' 2>/dev/null)" || perm="" ;;
L
)" '         && perm=admin || perm="" ;;' 'ci: a no-ci marker from an author without write access is not honoured'
  check_row ci-note-moves-rc "$PWT" ci-note "$(lit <<'L'
  case "$rc" in 0|10|11) _pw_ci_note "${out##* }" ;; esac
L
)" "$(lit <<'L'
  case "$rc" in 0|10|11) _pw_ci_note "${out##* }"; rc=$? ;; esac
L
)" 'observe: the reviewer exit code is unchanged by the CI read'
  check_row ci-note-on-stdout "$PWT" ci-note "$(lit <<'L'
      "$(printf '%s\n' "$out" | sed -n 2p)" >&2
L
)" "$(lit <<'L'
      "$(printf '%s\n' "$out" | sed -n 2p)"
L
)" 'observe: the reviewer stdout is unchanged by the CI read'
  check_row ci-note-stale-head "$PWT" ci-note '      _pw_ci_note "${out:+$head}"' '      _pw_ci_note "$lasthead"' \
    "wait: an unreadable last poll never reports an earlier head's CI"
  check_row ci-note-per-poll "$PWT" ci-note '        lasthead="$head" ;;' \
    '        lasthead="$head"; _pw_ci_note ;;' 'wait: the CI line is printed once, on the verdict'
  check_row ci-held-red-dropped "$PWT" ci-wait "$(lit <<'L'
    if [ "$rc" -eq 40 ] && [ "$OPT_NO_FAIL_FAST" = "1" ] && [ "${running:-1}" != "0" ]; then
L
)" '    if false; then' 'ci-wait --no-fail-fast: returns on the poll where the last sibling concluded'
  check_row ci-status-incomplete-accepted "$PWT" ci-read "$(lit <<'L'
      | if ($all | length) != $t then error("the status list is incomplete") else . end
L
)" '      | .' 'ci: a status list shorter than its total_count is incomplete'
  check_row ci-inventory-incomplete-accepted "$PWT" ci-read "$(lit <<'L'
        | if ($all | length) != $t then error("the inventory is incomplete") else . end
L
)" '        | .' 'ci: a workflow inventory shorter than its total_count is unreadable'
  check_row ci-leading-zero-accepted "$PWT" ci-read "$(lit <<'L'
  case "$1" in 0?*) echo "pr-watch: $2 must not carry a leading zero (got '$1')" >&2; return 1 ;; esac
L
)" '  :' 'ci-wait: a leading-zero bound is refused'
  check_row ci-gone-silent "$PWT" ci-read "$(lit <<'L'
    _PW_CI_LINE="pr-watch: ci gone $head observed $at — PR #$n is no longer open, so there is no CI left to watch"
L
)" '    _PW_CI_LINE=""' 'ci: a closed pull request still prints its CI line'
  check_row ci-auth-line-dropped "$PWT" ci-read "$(lit <<'L'
    || { echo "pr-watch: ci unreadable - observed $(date -u +%Y-%m-%dT%H:%M:%SZ) — gh or jq is unavailable or not authenticated" >&2; return 20; }
L
)" '    || return 20' 'ci: an unauthenticated gh still prints its CI line'
  check_row ci-late-green-accepted "$PWT" ci-wait "$(lit <<'L'
        if [ "$greens" -ge "$_ADB_PW_CI_SETTLE" ] && [ "$remaining" -gt 0 ]; then
L
)" '        if [ "$greens" -ge "$_ADB_PW_CI_SETTLE" ]; then' 'ci-wait: a green that settles only after the bound is not accepted'
  check_row ci-expiry-line-green "$PWT" ci-wait "$(lit <<'L'
          line="pr-watch: ci indeterminate ${line#pr-watch: ci green } — green on its last poll, not settled before the bound" ;;
L
)" '          : ;;' "ci-wait: the expired bound's CI line does not say green"
  check_row ci-decl-reason-on-stderr "$PWT" ci-wait "$(lit <<'L'
    *) if [ -n "$why" ]; then printf 'off\nroadmap #%s: %s' "$num" "$why"; else printf 'off'; fi ;;
L
)" "$(lit <<'L'
    *) [ -n "$why" ] && printf 'pr-watch: ci — roadmap #%s: %s\n' "$num" "$why" >&2; printf 'off' ;;
L
)" 'ci-wait: the declaration reason rides the one CI line'
  check_row ci-open-run-ignored "$PWT" ci-wait "$(lit <<'L'
      | [ $f.failing[] | select(.actions) | runof | select(. == null or (.done | not)) ] as $unsettledruns
L
)" '      | [] as $unsettledruns' "ci-wait --no-fail-fast: returns once the red's run concluded"
  check_row ci-lost-run-released "$PWT" ci-wait "$(lit <<'L'
      | [ $f.failing[] | select(.actions) | runof | select(. == null or (.done | not)) ] as $unsettledruns
L
)" '      | [ $f.failing[] | select(.actions) | runof | select(. != null and (.done | not)) ] as $unsettledruns' \
    'ci-wait --no-fail-fast: a red whose run cannot be found is held, not released'
  check_row ci-check-fields-unchecked "$PWT" ci-read '        then error("a check run lacks a field its consumers read") else . end' \
    '        then . else . end' 'ci: a check run with no id or check suite is unreadable'
  check_row ci-status-fields-unchecked "$PWT" ci-read '        then error("a status lacks its context or state") else . end' \
    '        then . else . end' 'ci: a status with an empty context is unreadable'
  check_row ci-workflow-repeat-accepted "$PWT" ci-read "$(lit <<'L'
        | if ([$all[] | .id] | unique | length) != ($all | length) then error("a workflow repeats") else . end
L
)" '        | .' 'ci: a workflow inventory that repeats an id is unreadable'
  check_row ci-runmap-ambiguous-accepted "$PWT" ci-wait '                       then error("a check suite maps to more than one run record") else . end' \
    '                       then . else . end' 'ci-wait --no-fail-fast: a run map naming one suite twice is unknown'
  check_row ci-interrupt-silent "$PWT" ci-wait "$(lit <<'L'
  trap 'printf "pr-watch: ci indeterminate %s observed %s — interrupted before the checks were seen to conclude\n" "${lasthead:--}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
L
)" "  trap ': >&2" 'ci-wait: an interrupted wait still prints its CI line'
  check_row ci-signature-anonymous "$PWT" ci-wait "$(lit <<'L'
        ( [ (.runs[] | [.id, (.app.slug // ""), .name, .status, (.conclusion // "")]),
L
)" '        ( [ (.runs[] | [.name, .status, (.conclusion // "")]),' 'ci-wait: a check replaced under the same name is a new check set'
  mut_prep_root() { check_copy_subtrees "$ROOT" "$1" scripts >/dev/null 2>&1 || return 1; printf '%s' "$1"; }
  mut_run_root()  { "$BASH" "$1/scripts/check-pr-watch.sh" 2>&1; }
  check_mutation_rows "pr-watch-ci" "$work/mr" scripts/check-pr-watch.sh mut_prep_root mut_run_root 4

  check_summary "pr-watch-mutation"
  exit 0
fi

REPO="$work/repo"; GHOME="$work/home"; SBIN="$work/sbin"; S="$work/stub"
mkdir -p "$REPO" "$GHOME/.config/ai-dev-baseline" "$SBIN" "$S"
# A git repo so the helper's repo-root resolution is deterministically $REPO, whatever ambient git
# repo sits above the temp dir. `check_make_stub_repo` carries the `origin`-remote contract (#173),
# which `/resolve-pr-threads --watch` needs: it passes the bare `--pr 7` form, naming no repository.
check_make_stub_repo "$REPO" https://github.com/acme/widget.git || {
  echo "check-pr-watch: FATAL — could not build the fixture repo" >&2; exit 1; }

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CODEX="chatgpt-codex-connector"
HEAD_REF="feature"
# WHEN THE HEAD REF BECAME THE HEAD SHA, as the repository activity API recorded it (#175) — NOT the
# head commit's committer date, which is client-supplied and which this module no longer reads at
# all. Every reaction/comment fixture is expressed relative to it so the staleness rule is read at a
# glance rather than by comparing two opaque strings.
ARRIVED_AT="2026-07-25T04:42:15Z"
AFTER_AT="2026-07-25T04:45:23Z"    # 3m08s later — the real gap observed on PR #88
BEFORE_AT="2026-07-25T04:40:00Z"
LATER_AT="2026-07-25T04:46:00Z"    # fresh, and newer than AFTER_AT
AFTER_PLUS1S_AT="2026-07-25T04:45:24Z"   # one second after AFTER_AT
# A committer date deliberately EARLIER than every reaction below. Under the pre-#175 rule this
# alone produced `clean`; it is served by the stub's (now unused) commit route purely so the tests
# can prove the module never asks for it.
FORGED_COMMIT_AT="2026-07-25T00:00:00Z"

# THE RUNAWAY BACKSTOP FOR EVERY `wait` CASE WHOSE ORACLE IS A FIXTURE (#394).
#
# `wait`'s bound is REAL elapsed time, so `--max-secs` is one of two completely different things
# depending on the case, and conflating them is what made this suite load-sensitive:
#
#   * where the DEADLINE is the oracle (the case asserts rc 11, or asserts what a bound-expiry
#     prints), it must stay SMALL — the case is waiting for it, and a loaded runner only reaches
#     it sooner, which is still the answer being asserted;
#   * where a FIXTURE is the oracle (the case asserts what a later poll classifies, reports or
#     returns), the deadline is a runaway backstop and nothing else. It must be far larger than
#     any plausible classification, or a loaded runner reaches it FIRST and the case ends before
#     its fixture ever changes — passing vacuously, or failing with no cause in the diff.
#
# 120s, not 300s and not 30s: a classification here forks a handful of stubbed processes and costs
# ~0.3s unloaded, so this is a two-order-of-magnitude margin, while still bounding what a genuine
# regression costs the suite. That bound is on continued POLLING — `cmd_wait` classifies and checks
# the deadline afterwards, so a classification that never returns is not bounded by it at all.
WATCH_BACKSTOP=120

# ============================ the recording gh stub ============================
# ORDERING IS LOAD-BEARING, and it is the trap a broad `repos/*` arm sets: the reviews URL is ALSO
# a `repos/*/pulls/*` URL, so an arm matching the general shape first swallows the specific one and
# every scenario silently reads the wrong fixture. Most specific first, always.
#
# It also COUNTS polls (one `pulls/N` read per classification) and prefers a per-poll fixture
# `<name>.<n>.json` when one exists, which is how the `wait` scenarios below make the answer change
# between polls without any network.
# THE TWO GRAPHQL ARMS ARE COMPOSED IN FROM check-lib.sh, NOT PASTED. They were literals here
# until the independent review pointed out that `check_pr_graphql_stub_body` and
# `check_pr_receipts_stub_body` were DEFINED as the shared home and then never called — three copies
# of one thing, in a repo whose first golden rule is "source the shared primitive, never copy it".
# It had already drifted once: adding the failure knobs meant hand-patching all three. The stub is
# therefore assembled by a group whose stdout is the program, so the shared bodies arrive by call.
{ cat <<'STUB'
#!/usr/bin/env bash
# Knobs:
#   STUB_AUTH_FAIL=1       -> `gh auth status` fails (unauthenticated)
#   STUB_FAIL_PR=1         -> the PR read fails
#   STUB_FAIL_REVIEWS=1    -> the reviews read fails
#   STUB_FAIL_REACTIONS=1  -> the reactions read fails
#   STUB_FAIL_COMMENTS=1   -> the issue-comments read fails
#   STUB_FAIL_ACTIVITY=1   -> the ref-activity read fails
#   STUB_EMPTY_ACTIVITY=1  -> the ref-activity read SUCCEEDS with an empty body (not `[]`)
#   STUB_EMPTY_REVIEWS/COMMENTS/REACTIONS=1 -> that signal read SUCCEEDS with an empty body
#   STUB_FAIL_CHECKRUNS/CISTATUS/BRANCH/WORKFLOWS=1 -> that head-CI read fails (#448)
[ "${STUB_AUTH_FAIL:-0}" = "1" ] && [ "${1:-} ${2:-}" = "auth status" ] && exit 1
case "${1:-}" in
  auth) exit 0 ;;
  api)  ;;
  *)    exit 0 ;;
esac
# --- GraphQL: the ONE read a classification now makes (#174) --------------------------------
# Two different queries reach here. They are told apart by a field only one of them selects:
# the receipt read (#169's request-review) asks for comment BODIES, the classification snapshot
# deliberately does not. Matching on that is the same "ask what the document actually contains"
# discipline the REST arms use, rather than counting arguments.
if [ "${2:-}" = "graphql" ]; then
  _q=""
  for a in "$@"; do case "$a" in query=*) _q="$a" ;; esac; done
  case "$_q" in
    *body*) printf 'graphql:receipts\n' >> "$S/calls"
STUB
check_pr_receipts_stub_body
cat <<'STUB'
      ;;
    *) printf 'graphql:snapshot\n' >> "$S/calls"
STUB
check_pr_graphql_stub_body
cat <<'STUB'
      ;;
  esac
fi
url=""
for a in "$@"; do
  case "$a" in repos/*) [ -z "$url" ] && url="$a" ;; esac
done
# EVERY api call is recorded, which is how the suite proves a NEGATIVE: #175's whole claim is that
# the client-supplied committer date is out of the decision, and the only way to show that is that
# the head-commit endpoint is never asked. An assertion on the verdict alone would still pass if the
# module read the date and happened to weight it differently.
printf '%s\n' "$url" >> "$S/calls"
# fx <base> : echo the per-poll fixture if present, else the default one. The poll number comes
# from the counter file the `pulls/N` arm below bumps once per classification — NOT from an
# environment variable, which cannot survive between the separate `gh` processes one poll makes.
fx() {
  local n=0
  [ -f "$S/polls" ] && n="$(cat "$S/polls")"
  if [ -f "$S/$1.$n.json" ]; then cat "$S/$1.$n.json"; return 0; fi
  [ -f "$S/$1.json" ] && cat "$S/$1.json"
  return 0
}
case "$url" in
STUB
check_pr_comment_stub_body
cat <<'STUB'
  */reviews*)
    [ "${STUB_FAIL_REVIEWS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_REVIEWS:-0}" = "1" ] && exit 0
    fx reviews
    # --paginate concatenates ONE JSON DOCUMENT PER PAGE; page 2 exists only in the pagination
    # scenario, so the default case still emits a single well-formed page.
    [ -f "$S/reviews2.json" ] && cat "$S/reviews2.json"
    exit 0 ;;
  */issues/*/comments*)
    # A POST, NOT A GET — `request-review` creating a comment (#169). Told apart by the `body=`
    # argument, because the URL is identical. RECORDED (so a test can assert a comment was really
    # posted, and how many times) and PERSISTED into the receipt fixture (so the NEXT invocation
    # sees the real receipt this one created, which is the only way to test idempotency as
    # success-then-repeat rather than as a preloaded fixture). Both gaps were named by the
    # independent review: without the record, deleting `-f body=` from the module stays green.
    _body=""; _isprot=0
    for _a in "$@"; do case "$_a" in body=*) _body="${_a#body=}"; _isprot=1 ;; esac; done
    if [ "$_isprot" = "1" ]; then
      [ "${STUB_FAIL_POST:-0}" = "1" ] && exit 1
      printf '%s\n' "$_body" >> "$S/posted"
      _at="${STUB_POST_AT:-2026-07-25T04:46:00Z}"
      _cur="[]"; [ -f "$S/receipts.json" ] && _cur="$(cat "$S/receipts.json")"
      printf '%s' "$_cur" | jq -c --arg at "$_at" --arg b "$_body" \
        '. + [{created_at:$at, body:$b}]' > "$S/receipts.json.tmp" \
        && mv "$S/receipts.json.tmp" "$S/receipts.json"
      printf '{"id":1}\n'; exit 0
    fi
    [ "${STUB_FAIL_COMMENTS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_COMMENTS:-0}" = "1" ] && exit 0
    fx comments
    [ -f "$S/comments2.json" ] && cat "$S/comments2.json"
    exit 0 ;;
  */reactions*)
    [ "${STUB_FAIL_REACTIONS:-0}" = "1" ] && exit 1
    [ "${STUB_EMPTY_REACTIONS:-0}" = "1" ] && exit 0
    fx reactions
    [ -f "$S/reactions2.json" ] && cat "$S/reactions2.json"
    exit 0 ;;
  */activity*)
    [ "${STUB_FAIL_ACTIVITY:-0}" = "1" ] && exit 1
    # A SUCCESSFUL read with an empty body — distinct from `[]`, and the reason the module reads and
    # parses in two steps. Collapsing them would turn this into "no matching activity" (11) when it
    # is really "the call produced no document" (20).
    [ "${STUB_EMPTY_ACTIVITY:-0}" = "1" ] && exit 0
    fx activity
    exit 0 ;;
  # THE HEAD-CI READS (#448), each answered from a per-poll fixture when one exists. They sit ABOVE
  # the retired `*/commits/*` bait below, whose shape they share; with no fixture each answers an
  # empty body, which the module must read as unreadable rather than as "no checks".
  */commits/*/check-runs*)
    [ "${STUB_FAIL_CHECKRUNS:-0}" = "1" ] && exit 1
    fx checkruns; exit 0 ;;
  */commits/*/status*)
    [ "${STUB_FAIL_CISTATUS:-0}" = "1" ] && exit 1
    fx cistatus; exit 0 ;;
  */branches/*)
    [ "${STUB_FAIL_BRANCH:-0}" = "1" ] && exit 1
    fx branch; exit 0 ;;
  */actions/workflows*)
    [ "${STUB_FAIL_WORKFLOWS:-0}" = "1" ] && exit 1
    fx workflows; exit 0 ;;
  */actions/runs*)
    fx wfruns; exit 0 ;;
  */issues[?]*)
    fx roadmap; exit 0 ;;
  */collaborators/*/permission*)
    fx permission; exit 0 ;;
  */commits/*)
    # RETIRED BY #175 and kept deliberately — as a BAITED route, not as a working dependency. It
    # still answers, with a committer date old enough to have produced a false `clean` under the old
    # rule, so a future edit that reaches for the head commit again gets a TEMPTING wrong answer
    # rather than nothing.
    #
    # It is not what makes the negative assertion work: `called '/commits/'` reads the unconditional
    # recorder above, and would fail with this arm deleted too (an unmatched `repos/…` falls to the
    # catch-all below and exits 0 with empty stdout — the suite never 404s either way). Kept because
    # a regression should fail on "the head commit was read", which names the defect, rather than on
    # whatever an empty body happens to do three steps later.
    cat "$S/commit.json"; exit 0 ;;
  */pulls/*)
    [ "${STUB_FAIL_PR:-0}" = "1" ] && exit 1
    # Count the poll BEFORE answering, then re-read it so `fx` above sees the same number for the
    # reads that follow within this same classification.
    n=0; [ -f "$S/polls" ] && n="$(cat "$S/polls")"
    n=$(( n + 1 )); printf '%s' "$n" > "$S/polls"
    if [ -f "$S/pr.$n.json" ]; then cat "$S/pr.$n.json"; else cat "$S/pr.json"; fi
    exit 0 ;;
  repos/*)
    exit 0 ;;
esac
exit 0
STUB
} | check_write_stub "$SBIN/gh"

# A `sleep` shim that RECORDS the requested nap and then sleeps a flat 1s.
#
# Both halves are necessary and the reason is worth stating, because the obvious stub (record and
# return instantly) HANGS THE SUITE. The bound is elapsed REAL time — `$BASH_MONOSECONDS` against a
# deadline, which is the honest thing to measure — so a sleep that does not actually pass time means
# the deadline is never reached and a `pending` scenario spins forever. Sleeping a flat 1s advances
# the clock enough for
# a small `--max-secs` to expire in a few iterations, while RECORDING the requested value is what
# lets the overshoot assertion below read the clamp the code actually computed rather than the
# shortened one it slept.
check_write_stub "$SBIN/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$S/slept"
exec /bin/sleep 1
SLEEPSTUB

# ---- fixtures --------------------------------------------------------------------------------
# The GraphQL assembler is a CONSTANT program, written once at setup rather than in `reset_fx`:
# it is the TRANSPORT, not a scenario fixture. Recreating it per reset left every scenario
# before the first reset reading an empty document — which is exactly how this suite failed
# while #174 was being wired, and the failure looked like a broken guard rather than a broken
# harness.
check_pr_graphql_assembler "$S/assemble.jq"

reset_fx() {
  rm -f "$S/reviews2.json" "$S/reactions2.json" "$S/comments2.json" "$S/polls" "$S/slept" "$S/calls"
  # The slow-poll injection (#394) is per-scenario and MUST be swept: left behind it would tax the
  # first poll of every scenario that follows, and the one place it is set is the LAST case in
  # section 11 — so a missing sweep is invisible there and shows up as unexplained seconds
  # somewhere else entirely.
  rm -f "$S"/slow-[0-9]*
  rm -f "$S"/pr.[0-9]*.json "$S"/reviews.[0-9]*.json "$S"/reactions.[0-9]*.json \
        "$S"/comments.[0-9]*.json "$S"/activity.[0-9]*.json
  # #174/#169 fixtures: the truncation counters, the receipt read, and the raw-document override.
  rm -f "$S"/*-total.txt "$S/receipts.json" "$S/graphql-raw.json" "$S/posted" "$S/receipts-raw.json"
  rm -f "$S/rpolls" "$S"/rpr.[0-9]*.json
  # #448's head-CI fixtures, default and per-poll alike: absent, every CI read is unreadable.
  rm -f "$S"/checkruns*.json "$S"/cistatus*.json "$S"/branch*.json "$S"/workflows*.json \
        "$S"/wfruns*.json "$S"/roadmap*.json "$S"/permission*.json
  printf '[]\n' > "$S/reviews.json"
  printf '[]\n' > "$S/reactions.json"
  printf '[]\n' > "$S/comments.json"
  pr_fx
  commit_fx
  activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"
}
# pr_fx [--sha X] [--state X] [--merged-at X] [--base-slug X] [--head-slug X] [--head-ref X]
# A defaults wrapper over `check_pr_json`, which holds the fixture shape (D68). Last flag wins, so
# `pr_fx --head-slug ""` renders `head.repo` null — a deleted fork, which the anchor must degrade on.
pr_fx() {
  check_pr_json "$S/pr.json" --sha "$HEAD_SHA" --state open --merged-at "" \
    --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF" --base-ref main "$@"
}
pr_fx_raw()  { printf '%s\n' "$1" > "$S/pr.json"; }
# pr_poll_fx <n> [flags…] — `pr_fx` writing the per-poll fixture the gh stub prefers on poll <n>.
# A second wrapper rather than a second construction site: the destination is the only difference.
pr_poll_fx() {
  local n="$1"; shift
  check_pr_json "$S/pr.$n.json" --sha "$HEAD_SHA" --state open --merged-at "" \
    --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF" --base-ref main "$@"
}
# The committer date the module MUST NOT consult. Defaulted to a value old enough that reading it
# would flip every staleness assertion below from `pending` to `clean`.
commit_fx()  { jq -n --arg d "${1:-$FORGED_COMMIT_AT}" '{commit:{committer:{date:$d}, author:{date:$d}}}' > "$S/commit.json"; }
# The four payload builders and the call recorder live in check-lib.sh (#167): both PR-guard suites
# now exercise ONE shared classifier, so the response SHAPES must have one home. The `_*_into` seam
# stays because this suite writes page-two and per-poll fixtures as well as the default one.
called()          { check_pr_called "$S/calls" "$1"; }
review_fx()       { check_pr_reviews_json   "$S/reviews.json"   "$@"; }
_reviews_into()   { check_pr_reviews_json   "$@"; }
comment_fx()      { check_pr_comments_json  "$S/comments.json"  "$@"; }
status_fx()       { check_pr_status_comment_json "$S/comments.json" "$@"; }
_comments_into()  { check_pr_comments_json  "$@"; }
reaction_fx()     { check_pr_reactions_json "$S/reactions.json" "$@"; }
_reactions_into() { check_pr_reactions_json "$@"; }
activity_fx()     { check_pr_activity_json  "$S/activity.json"  "$@"; }
activity_fx_raw() { printf '%s\n' "$1" > "$S/activity.json"; }
# The reviewer-declaration tri-state lives in check-lib.sh too; both suites pin the same three.
declare_bots() { check_declare_bots   "$REPO" "$1"; }
undeclare()    { check_undeclare_bots "$REPO" "$GHOME"; }

# _w <args...> : run the detector as the driving agent would — from $REPO, throwaway HOME, stubs.
# ONE home for the environment so a new STUB_* knob is wired in a single place; the two wrappers
# below differ only in what they do with stderr, and the redirect composes onto this subshell.
_w() {
  ( cd "$REPO" && HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" \
    STUB_AUTH_FAIL="${STUB_AUTH_FAIL:-0}" STUB_FAIL_PR="${STUB_FAIL_PR:-0}" \
    STUB_FAIL_REVIEWS="${STUB_FAIL_REVIEWS:-0}" STUB_FAIL_REACTIONS="${STUB_FAIL_REACTIONS:-0}" \
    STUB_FAIL_COMMENTS="${STUB_FAIL_COMMENTS:-0}" \
    STUB_FAIL_ACTIVITY="${STUB_FAIL_ACTIVITY:-0}" \
    STUB_EMPTY_ACTIVITY="${STUB_EMPTY_ACTIVITY:-0}" \
    STUB_EMPTY_REVIEWS="${STUB_EMPTY_REVIEWS:-0}" STUB_EMPTY_COMMENTS="${STUB_EMPTY_COMMENTS:-0}" \
    STUB_EMPTY_REACTIONS="${STUB_EMPTY_REACTIONS:-0}" \
    STUB_GRAPHQL_FAIL="${STUB_GRAPHQL_FAIL:-0}" STUB_EMPTY_GRAPHQL="${STUB_EMPTY_GRAPHQL:-0}" \
    STUB_GRAPHQL_RC="${STUB_GRAPHQL_RC:-0}" \
    STUB_FAIL_POST="${STUB_FAIL_POST:-0}" STUB_POST_AT="${STUB_POST_AT:-}" \
    STUB_FAIL_CHECKRUNS="${STUB_FAIL_CHECKRUNS:-0}" STUB_FAIL_CISTATUS="${STUB_FAIL_CISTATUS:-0}" \
    STUB_FAIL_BRANCH="${STUB_FAIL_BRANCH:-0}" STUB_FAIL_WORKFLOWS="${STUB_FAIL_WORKFLOWS:-0}" \
    bash "$PW" "$@" )
}
# w : stdout AND stderr, for asserting diagnostics.
w()    { OUT="${ _w "$@" 2>&1; }"; RC_=$?; }
# wout : stdout ONLY (the "<verdict> <sha>" contract) — stderr is diagnostics and must not pollute it.
wout() { OUT="${ _w "$@" 2>/dev/null; }"; RC_=$?; }
rc() { eq "$RC_" "$1" "$2"; }

# HEAD-CI FIXTURES (#448), in the prelude so every block can build them. A check run is `name|status|conclusion|app|suite` (conclusion empty = null, app
# empty = Actions, suite empty = 7001); a status is `context|state`. `CI_SHA` overrides the head a
# fixture describes, which is how a moved head's evidence is written; `CI_ID_BASE` the check-run ids.
ci_runs_into() {
  local out="$1"; shift
  printf '%s\n' "$@" | jq -R -s -c --arg sha "${CI_SHA:-$HEAD_SHA}" --argjson base "${CI_ID_BASE:-9000}" '
    split("\n") | map(select(length > 0) | split("|")) | to_entries
    | map(.value as $f | {id: ($base + .key), name: $f[0], head_sha: $sha, status: $f[1],
           conclusion: (if ($f[2] // "") == "" then null else $f[2] end),
           app: {slug: (if ($f[3] // "") == "" then "github-actions" else $f[3] end)},
           check_suite: {id: (if ($f[4] // "") == "" then 7001 else ($f[4] | tonumber) end)}})
    | {total_count: length, check_runs: .}' > "$out"
}
ci_runs_fx()   { ci_runs_into "$S/checkruns.json" "$@"; }
ci_status_into() {
  local out="$1"; shift
  printf '%s\n' "$@" | jq -R -s -c --arg sha "${CI_SHA:-$HEAD_SHA}" '
    split("\n") | map(select(length > 0) | split("|") | {context: .[0], state: .[1]})
    | {sha: $sha, state: "pending", total_count: length, statuses: .}' > "$out"
}
ci_status_fx() { ci_status_into "$S/cistatus.json" "$@"; }
# ci_branch_fx <context…> — the base branch requires exactly these; `--unprotected` and `--ruleset`
# are the two other answers `branch-required-contexts` distinguishes.
ci_branch_fx() {
  case "${1:-}" in
    --unprotected) printf '{"name":"main","protected":false}\n' > "$S/branch.json" ;;
    --ruleset)     printf '{"name":"main","protected":true,"protection":{"enabled":false,"required_status_checks":{"contexts":[]}}}\n' > "$S/branch.json" ;;
    *) printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0))
         | {name: "main", protected: true,
            protection: {enabled: true, required_status_checks: {contexts: .}}}' > "$S/branch.json" ;;
  esac
}
ci_workflows_fx() { jq -n -c --argjson n "$1" '{total_count: $n, workflows: [range($n) | {id: ., state: "active"}]}' > "$S/workflows.json"; }
# ci_lines_with <text> — how many lines of $OUT carry <text>.
ci_lines_with() { printf '%s\n' "$OUT" | grep -cF -- "$1"; }
# ci_wfruns_into <file> <run-id|suite|attempt[|status]> … — status defaults to completed.
ci_wfruns_into() {
  local out="$1"; shift
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("|")
      | {id: (.[0] | tonumber), check_suite_id: (.[1] | tonumber), run_attempt: (.[2] | tonumber),
         status: (if (.[3] // "") == "" then "completed" else .[3] end)})
    | {total_count: length, workflow_runs: .}' > "$out"
}
ci_wfruns_fx() { ci_wfruns_into "$S/wfruns.json" "$@"; }
# ci_roadmap_fx <body> <author> <permission> — ONE open roadmap artifact, and its author's access.
ci_roadmap_fx() {
  jq -n -c --arg b "$1" --arg a "$2" '[{number: 31, body: $b, user: {login: $a}}]' > "$S/roadmap.json"
  jq -n -c --arg p "$3" '{permission: $p}' > "$S/permission.json"
}
# ci_green_fx — the ordinary shape: one Actions check, required, concluded success, no statuses.
ci_green_fx() { ci_runs_fx "ci|completed|success"; ci_status_fx; ci_branch_fx ci; }
# cilines — the `pr-watch: ci ` lines in $OUT, counted.
cilines() { printf '%s\n' "$OUT" | grep -c '^pr-watch: ci ' ; }

reset_fx
declare_bots "[\"$CODEX\"]"

# BLOCKS (#468) — a mutant of the head-CI code runs only the block that witnesses it. Everything
# before this line is the prelude every block shares; sections 1-13 are one block, because no
# per-test row targets them (their rows run the whole suite, through the pools above).
check_blocks_init "$ROOT/scripts/check-pr-watch.sh"

if check_block legacy; then
# ============================ 1. the clean signal ============================
# The whole point of the module: a connector `+1` on the PR's opening post, with NO review object
# anywhere, is a PASS. `pr-review.sh gate` cannot see this case at all (it reads only reviews), so
# if this arm regressed the detector would inherit that blind spot and never converge on a clean PR.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "clean: +1 after the head commit -> 0"
eq "$OUT" "clean $HEAD_SHA" "clean: stdout is '<verdict> <sha>'"

# The REST spelling of the same bot must work too — a bare declaration accepts either form.
reaction_fx "${CODEX}[bot]" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "clean: '[bot]'-suffixed reaction login still matches a bare declaration"

# ...but NOT the reverse. The match is ASYMMETRIC (#173, superseding #176): the API login is
# normalized toward the declaration, never the declaration toward the API. Stripping both sides let a
# declared `foo[bot]` be satisfied by a HUMAN account literally named `foo` — and REACTIONS ARE
# PUBLICLY WRITABLE, so on this signal the bar was a login collision and nothing else. `gh api
# users/gemini-code-assist` returns a real User account (id 200291788), i.e. the collision space is
# populated by the kind of account that reviews pull requests. A `user.type` filter cannot rescue it:
# verified live, this endpoint reports `type: "User"` for the Codex connector itself.
declare_bots "[\"${CODEX}[bot]\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a HUMAN '+1' does not satisfy a '[bot]' declaration (the #176 fail-open)"
# ...while the strict declaration still matches the spelling REST actually reports.
reaction_fx "${CODEX}[bot]" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "identity: a '[bot]' declaration matches the REST '[bot]' reaction login"
# A doubled suffix must not satisfy the strict form through the same one-suffix rule it denies.
reaction_fx "${CODEX}[bot][bot]" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a DOUBLED '[bot]' suffix does not satisfy a '[bot]' declaration"

# THE SAME RULE ON ALL THREE SIGNALS. The matcher had three inline copies here — reviews, issue
# comments, reactions — so one shared predicate has to be proved on each, not just on the one that
# happens to be checked first. A human login satisfying a declared App on ANY surface is the defect.
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"
review_fx "$CODEX" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "identity: a HUMAN review does not satisfy a '[bot]' declaration"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "identity: the suffixed review login does satisfy it"
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"
comment_fx "$CODEX" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a HUMAN issue comment does not satisfy a '[bot]' declaration"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "identity: the suffixed comment login does satisfy it"

reset_fx; declare_bots "[\"$CODEX\"]"

# ============================ 2. staleness — the dangerous direction ============================
# A reaction is NOT commit-scoped. A `+1` left on an earlier head is still sitting there after new
# commits land; counting it would report `clean` for code nobody reviewed. This is THE case the
# module must never get wrong.
reaction_fx "$CODEX" "+1" "$BEFORE_AT"
w observe --pr 1;  rc 11 "stale: a '+1' predating the head commit is NOT clean"
has "$OUT" "predates this head" "stale: says WHY it was rejected"

# The boundary. Equal timestamps mean the reaction cannot be proven to postdate the head's arrival,
# so it must fall to pending — the safe side. A `>=` here would be the fail-open spelling.
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "stale: a '+1' EQUAL to this head's arrival is not proof of a pass"

# A reaction from a bot we do not declare proves nothing.
reaction_fx "some-other-bot[bot]" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "identity: a '+1' from an UNDECLARED login is not clean"

# Not every reaction is the pass signal. A 👀 (`eyes`) is the connector's in-progress marker and a
# 👎 is not a pass at all; neither may be read as one.
reaction_fx "$CODEX" "eyes" "$AFTER_AT"
w observe --pr 1;  rc 11 "content: an 'eyes' reaction is in-progress, not a pass"
reaction_fx "$CODEX" "-1" "$AFTER_AT"
w observe --pr 1;  rc 11 "content: a '-1' reaction is not a pass"

# The newest `+1` decides. An old stale one must not veto a fresh one that followed a re-review.
reaction_fx "$CODEX" "+1" "$BEFORE_AT" "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "staleness uses the NEWEST '+1', not the first one found"

# ============ 2b. the anchor is SERVER-assigned and REF-scoped (#175) ============
# The staleness proof used to rest on the head commit's committer date, which GitHub echoes back
# verbatim from the committing machine. A past-dated head therefore made a STALE `+1` look fresh —
# a false `clean`, the one verdict this module must never produce. Reachable with no attacker: a
# date-preserving rebase, or a clock that is behind by more than the review latency.

# THE ISSUE'S EXACT SCENARIO. The head arrived AFTER the reaction, while the head commit CLAIMS a
# committer date long before it. The old rule read `clean` here; the anchor must read `pending`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT"       # this head arrived at 04:45
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"                          # the `+1` is from 04:42
commit_fx "$FORGED_COMMIT_AT"                                    # ...and the commit claims 00:00
w observe --pr 1;  rc 11 "#175: a '+1' predating this head's ARRIVAL is not clean, whatever the commit claims"

# ...and the proof that it is not merely outweighed: the committer date is never even fetched. This
# is the assertion that would fail if a future edit re-introduced the client-supplied input as a
# tie-breaker, a fallback, or a `max()` term.
# NARROWED BY #448 TO THE BARE COMMIT OBJECT: the head-CI read legitimately asks
# `commits/<sha>/check-runs` and `commits/<sha>/status`, while the retired anchor read the commit
# itself — `commits/<sha>` with nothing after it. The recorder logs the URL argument whole.
if grep -qE '/commits/[^/?]+$' "$S/calls" 2>/dev/null; then bad "#175: the head-commit endpoint must never be read"; else ok; fi

# THE CASE THAT RULES OUT A CHECK-SUITE ANCHOR, which is the obvious server-assigned candidate and
# the one the issue proposed first. Check suites are scoped to the SHA, not to the REF: a commit
# that already ran CI on another branch carries its ORIGINAL timestamp, so an ordinary fast-forward
# onto it keeps the fail-open with no force-push anywhere in the story. Modelled here as an activity
# record for the SAME SHA on a DIFFERENT ref — which must not be allowed to date this ref.
#
# THE FOREIGN RECORD IS THE NEWER ONE, and that is what makes this assertion able to FAIL. With the
# foreign record older, dropping `select(.ref == $ref)` cannot change the verdict — the code takes
# the LATEST match, so a superset containing only older records yields the same answer and the test
# passes against a module that has no ref filter at all. Ordered this way, dropping the filter picks
# the foreign 04:45 record, the 04:42 `+1` reads fresh against it, and the verdict flips to `clean`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/somewhere-else" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
wout observe --pr 1;  rc 0 "#175: this ref's OWN record dates it, even when a newer one names another ref"
# ...and the ordinary direction: a record for this ref that postdates the signal is stale.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/somewhere-else" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "#175: a '+1' predating this ref's own arrival record is not clean"

# THE `after` FILTER, pinned on its own. Every "no anchor" case above uses an EMPTY activity list,
# which returns 11 whether or not the SHA is matched — so none of them can catch a module that
# dropped `select(.after == $sha)`. Here the ref HAS activity and none of it names the current head:
# the honest answer is "this head's arrival is unrecorded" (11), while an unfiltered read would date
# it from a push of a DIFFERENT commit and report `clean`.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$OLD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: activity for a DIFFERENT SHA on this ref does not date this head"

# A REVERSE FORCE-PUSH: the ref went A -> B -> A, so two records carry the same `after`. Only the
# LATER one says when the head is A *now* — taking the earliest would date the current head from a
# push that was superseded and then undone, which is the force-push path the issue names.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "#175: the LATEST record for this SHA decides, so a reverse force-push is caught"
has "$OUT" "predates this head" "#175: says WHY the reaction was rejected"

# AN UNESTABLISHED ANCHOR IS `pending`, NEVER `clean` — on BOTH date-scoped signals. One rule over
# both is what keeps the forgeable input out of the file entirely; the findings side pays for it by
# waiting, which is the safe direction.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx                                   # a well-formed EMPTY list: nothing puts this SHA here
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: no activity record for this head -> pending, not clean"
# The diagnostic comes from `adb_head_anchor` itself, and names the ref and SHA it could not date —
# more precise than the paraphrase `classify` used to re-emit from a boolean it carried for the
# purpose. Asserted on the helper's own wording so the message has ONE author.
has "$OUT" "cannot be proved fresh" "#175: names the unestablished anchor rather than 'no signal yet'"
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: the comment path degrades the same way — one rule over both signals"

# A DELETED HEAD REPOSITORY is a real state, not a broken response: the PR reads fine, there is
# simply nowhere left to ask. That is an unestablished anchor (11), not an unreadable one (20).
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --head-slug ""
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#175: a deleted head repository -> pending"
has "$OUT" "deleted fork" "#175: names the likely cause"
# ...but a head repository that is present and MALFORMED is a broken response, and it is about to be
# interpolated into a URL PATH — a position no other slug in this family occupies (the base slug is
# only ever COMPARED). Being a well-formed `owner/repo` pair is necessary and NOT sufficient:
# `a/..` is a valid pair and a path traversal, so the charset is pinned too.
pr_fx --head-slug "acme/widget/extra"
w observe --pr 1;  rc 20 "#175: a malformed head repository slug -> 20, never a path-injected read"
for bad_slug in 'acme/..' '../widget' 'acme/.' 'acme/wid get' 'acme/wid?et'; do
  pr_fx --head-slug "$bad_slug"
  w observe --pr 1;  rc 20 "#175: head repository '$bad_slug' is refused before it reaches a URL"
done
# ...but a repository whose NAME merely contains dots is a name, not a traversal, and must still be
# queryable. Over-rejecting it would make every date-scoped signal on that PR permanently 20 —
# failure by availability rather than by safety, which is the kind that ships unnoticed.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --head-slug "acme/api..client"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#175: a head repository named 'api..client' is queryable, not a traversal"

# A MIXED-FORMAT activity response is rejected WHOLE, not just at the winner. Ordering first and
# checking only the survivor is unsound — a lexically-later-but-chronologically-EARLIER record can
# win, and an anchor earlier than the truth is the permissive direction.
#
# Read the two values before assuming which one wins: `2026-07-25T04:40:00Z` and
# `2026-07-25T00:42:15-04:00` diverge at index 12 (`4` vs `0`), so the well-formed `…Z` record sorts
# LAST and would be the survivor. A winner-only check would therefore pass this fixture happily,
# which is exactly why it pins the rule: reaching 20 requires validating the record that LOST.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "$BEFORE_AT" \
            "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T00:42:15-04:00"
reaction_fx "$CODEX" "+1" "$ARRIVED_AT"
w observe --pr 1;  rc 20 "#175: ONE unorderable timestamp rejects the whole activity read"

# THE SIGNAL THAT NEEDS NO ANCHOR MUST STILL WORK. A review is commit-scoped, so an unestablished
# anchor must not wedge it — otherwise #175 would have traded one fail-open for a total wedge on any
# repo whose activity is unreadable.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "#175: a review at head is SHA-scoped and needs no anchor at all"

# TIMESTAMP FORMAT. A lexicographic compare is chronological ONLY for identical-width `...Z` UTC.
# `2026-07-25T09:00:00-04:00` sorts before `...T05:00:00Z` as a string and after it as an instant,
# and sub-second precision loses to a whole second on a prefix compare. Reject, never normalize.
reset_fx; declare_bots "[\"$CODEX\"]"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T00:42:15-04:00"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 20 "#175: an OFFSET anchor timestamp is rejected, not string-compared"
activity_fx "$HEAD_SHA" "refs/heads/$HEAD_REF" "2026-07-25T04:42:15.123Z"
w observe --pr 1;  rc 20 "#175: a SUB-SECOND anchor timestamp is rejected"
# The candidate side too: a comparison is only as sound as its weaker operand.
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "2026-07-25T00:45:23-04:00"
w observe --pr 1;  rc 20 "#175: an OFFSET reaction timestamp is rejected"
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "not-a-timestamp"
w observe --pr 1;  rc 20 "#175: a junk comment timestamp is rejected, not sorted"

# EVERY MALFORMED ANCHOR RESPONSE -> 20. A wrapped error object must not iterate to zero matches and
# read as the much weaker "no anchor here".
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
activity_fx_raw '{"message":"Not Found"}'
w observe --pr 1;  rc 20 "#175: an activity response that is not an array -> 20, not 'no anchor'"
# The fixture above reaches 20 even WITHOUT the `type != "array"` guard — `.[]` over it yields a
# string and the next `select` dies indexing it — so on its own it names a property it does not
# test. This one is an object whose VALUES are well-formed records: without the guard `.[]` walks
# them happily and manufactures an anchor out of a response that was never a list.
activity_fx_raw "{\"a\":{\"after\":\"$HEAD_SHA\",\"ref\":\"refs/heads/$HEAD_REF\",\"timestamp\":\"$BEFORE_AT\"}}"
w observe --pr 1;  rc 20 "#175: an OBJECT of well-formed records is still not an array -> 20"
activity_fx_raw '{ not json at all'
w observe --pr 1;  rc 20 "#175: an unparseable activity response -> 20"

# ============================ 3. the findings signal ============================
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
wout observe --pr 1;  rc 10 "findings: a submitted review AT THE HEAD -> 10"
eq "$OUT" "findings $HEAD_SHA" "findings: stdout is '<verdict> <sha>'"

# A review of an EARLIER commit is not a review of this one — the same rule pr-review.sh applies,
# and observed live on PR #166 (reviewed 5e527689, head moved to d203c1e7).
review_fx "${CODEX}[bot]" "COMMENTED" "$OLD_SHA"
w observe --pr 1;  rc 11 "findings: a review of an OLDER commit does not count"

# CHANGES_REQUESTED is the reviewer having spoken AND not being satisfied — findings.
review_fx "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "findings: CHANGES_REQUESTED at head counts"

# APPROVED IS `clean`, NOT `findings` — CORRECTED BY #167, and it is a real behaviour change rather
# than a test tidy-up. This module used to treat ANY non-PENDING/DISMISSED review at the head as
# findings, so an explicit approval sent `/resolve-pr-threads --watch` off to resolve threads that a
# satisfied reviewer had, by definition, not created. The shared classifier gives one meaning to one
# piece of evidence for BOTH guards (#167 §4): `APPROVED` means the reviewer is satisfied, which is
# exactly what `pr-review.sh gate` has always read it as. The two modules disagreeing about this
# single word is the concrete form of the drift #167 exists to close.
review_fx "${CODEX}[bot]" "APPROVED" "$HEAD_SHA"
wout observe --pr 1;  rc 0 "findings: APPROVED at head is CLEAN, not findings (#167: one meaning per signal)"
eq "$OUT" "clean $HEAD_SHA" "an APPROVED review reports the clean verdict"

# ...but a draft nobody can see, and one that was explicitly revoked, are not.
review_fx "${CODEX}[bot]" "PENDING" "$HEAD_SHA"
w observe --pr 1;  rc 11 "findings: an unsubmitted PENDING review does not count"
review_fx "${CODEX}[bot]" "DISMISSED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "findings: a DISMISSED review does not count"

# A human's review is not the declared async reviewer's.
review_fx "somebody" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 11 "identity: a review from an UNDECLARED login does not count"

# ============================ 3b. findings via an ISSUE COMMENT (Codex "task mode") ============
# The connector has TWO output shapes and the repo does not choose which it gets: with a Codex
# Cloud environment it runs as a TASK and posts ONE ISSUE COMMENT — no review object, no inline
# threads, no reaction. Observed live on this repo the same day as the review-shaped output
# (PR #166 at 08:01 → review + 3 threads; PR #178 at 19:30 → one comment, zero reviews).
# A detector reading only reviews sits at `pending` FOREVER on such a repo.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "task mode: an issue comment from the reviewer, newer than the head -> findings"
has "$OUT" "READ THE COMMENT" "task mode: tells the caller there may be no threads to resolve"

# A comment carries no commit either, so it gets the SAME staleness rule as a reaction — otherwise
# a summary from a previous head would keep re-triggering the resolve flow after every push.
comment_fx "${CODEX}[bot]" "$BEFORE_AT"
w observe --pr 1;  rc 11 "task mode: a comment predating this head is stale, not findings"
comment_fx "${CODEX}[bot]" "$ARRIVED_AT"
w observe --pr 1;  rc 11 "task mode: a comment EQUAL to this head's arrival is not proof"

# Ordinary human chatter on the PR is not a reviewer signal.
comment_fx "somebody" "$AFTER_AT"
w observe --pr 1;  rc 11 "task mode: a comment from an UNDECLARED login is not findings"

# The newest comment decides, so a fresh summary after a stale one still converges.
comment_fx "${CODEX}[bot]" "$BEFORE_AT" "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "task mode: uses the NEWEST comment, not the first found"

# Pagination, same reasoning as the other two signals.
reset_fx; declare_bots "[\"$CODEX\"]"
_comments_into "$S/comments.json"  "somebody" "$AFTER_AT"
_comments_into "$S/comments2.json" "${CODEX}[bot]" "$AFTER_AT"
printf '101\n' > "$S/comments-total.txt"
w observe --pr 1;  rc 10 "task mode: a TRUNCATED comments connection falls back to the paginated read"

# An unreadable read must fail closed. The three surfaces are ONE read since #174, so the three
# per-endpoint knobs are one — the invariant is unchanged, only the thing that can break it moved.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 w observe --pr 1; rc 20 "unreadable: a failed single-read -> 20"; STUB_GRAPHQL_FAIL=0

# FINDINGS OUTRANK CLEAN across shapes: a reviewer that commented about this head has something to
# say, even if a `+1` from an earlier pass is still sitting there.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$BEFORE_AT"
w observe --pr 1;  rc 10 "precedence: a fresh comment outranks a STALE '+1'"

# #447: A FRESH `+1` NOT OLDER THAN THE SAME REVIEWER'S NEWEST FRESH COMMENT IS A CLEAN PASS — the
# connector's clean-pass shape is a `+1` and a same-second comment.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1; rc 0 "pair: a fresh '+1' and a same-second fresh comment are a clean pass"
eq "$OUT" "clean $HEAD_SHA" "pair: the paired clean pass prints the clean verdict"
w observe --pr 1
has "$OUT" "+1 at $AFTER_AT and a comment at $AFTER_AT" "pair: the verdict names both signals it folded"
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$LATER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 10 "pair: a comment NEWER than the '+1' is findings"
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_PLUS1S_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 10 "pair: a comment ONE SECOND newer than the '+1' is findings"
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT" "${CODEX}[bot]" "$LATER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 10 "pair: the '+1' must not be older than the NEWEST fresh comment"
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 10 "pair: a COMMENTED review at the head still wins over a paired '+1'"
# Across reviewers the pair is still one reviewer's pass, never the set's (#185).
reset_fx; declare_bots "[\"$CODEX\", \"gemini-code-assist[bot]\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "pair: one paired reviewer beside a silent one is still pending (#185)"

# #447: THE CONNECTOR'S REVIEW-STATUS COMMENT IS A PROGRESS MARKER, NOT A REVIEW. It is created when
# a review starts (`Running`) and edited in place, so a watch must wait through it.
reset_fx; declare_bots "[\"$CODEX\"]"
status_fx "${CODEX}[bot]" "$AFTER_AT" "Running"
w observe --pr 1;  rc 11 "status: a fresh Running status comment alone is pending, not findings"
has "$OUT" "review-status marker" "status: the ignored status comment is named"
reset_fx; declare_bots "[\"$CODEX\"]"
status_fx "${CODEX}[bot]" "$AFTER_AT" "Completed"
reaction_fx "$CODEX" "+1" "$LATER_AT"
w observe --pr 1;  rc 0 "status: a Completed status comment and a later '+1' are a clean pass"
reset_fx; declare_bots "[\"$CODEX\"]"
status_fx "${CODEX}[bot]" "$AFTER_AT" "Running"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "status: the real review beside an ignored status comment is findings"
reset_fx; declare_bots "[\"$CODEX\"]"
status_fx "${CODEX}[bot]" "$AFTER_AT" "Running"
STUB_FAIL_COMMENT_READ=1 w observe --pr 1
rc 20 "status: an unreadable status-comment body is unreadable, never a guess"
# The Running scaffold, then the real review on a later poll: the watch waits through the first.
reset_fx; declare_bots "[\"$CODEX\"]"
status_fx "${CODEX}[bot]" "$AFTER_AT" "Running"
cp "$S/comments.json" "$S/comments.1.json"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
cp "$S/reviews.json" "$S/reviews.2.json"; printf '[]\n' > "$S/reviews.json"
w wait --pr 1 --interval 1 --max-secs 60
rc 10 "status: wait sits through a Running status comment and returns the real review"

# ...and a review at the head still outranks a comment (the commit-scoped claim is strongest).
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "precedence: a review at head and a comment both yield findings"

# A clean pass must still be reachable when the reviewer has commented only on an OLDER head.
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx "${CODEX}[bot]" "$BEFORE_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "precedence: a STALE comment does not mask a fresh clean pass"

# ============================ 4. the two signals together ============================
# They are disjoint in practice (a clean pass posts no review; a findings pass posts no reaction),
# but if both ever appear the commit-scoped claim is the stronger one and must win.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 10 "precedence: findings at head outrank a fresh '+1'"

# ============ 4b. THE DECLARED SET IS AGGREGATED ALL-OR-NOTHING (#185) ============
# THE BUG THIS SECTION EXISTS FOR: every scenario above declares exactly ONE reviewer, and that is
# precisely why #185 shipped unnoticed. This module used to POOL the declared logins on all three
# surfaces — each selector filtered "login is in the declared set" and then reduced across the whole
# set — so ONE fast `+1` from ANY single bot reported `clean` while the others had not looked at the
# PR at all. `pr-review.sh gate` required all of them; the two guards disagreed about HOW MANY
# reviewers must speak, which is orthogonal to #167's "what does a signal MEAN".
#
# Fail-OPEN in the direction that matters: `/resolve-pr-threads --watch` exited reporting a clean
# pass and the operator reasonably concluded review was finished.
#
# The fold is now: any attention/rejection wins outright -> findings; else any unknown -> 20; else
# any reviewer with no signal -> pending; ONLY all-clean -> clean. Note the findings path was
# already correct under "any wins"; it is the CLEAN path that had to become all-or-nothing.
BOT2="gemini-code-assist[bot]"

# #185's FIRST ACCEPTANCE CRITERION, and the one that fails against the shipped code.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 11 "#185: two declared, a fresh '+1' from only ONE -> pending, NOT clean"
has "$OUT" "gemini-code-assist" "#185: pending names the reviewer that has not spoken"
hasnt "$OUT" "clean pass" "#185: a partial set is never reported as a pass"

# ...and the control. If this ever fails, the rule above has become "nothing is ever clean".
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT" "$BOT2" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#185: two declared, BOTH signalled clean -> clean"
eq "$OUT" "clean $HEAD_SHA" "#185: the all-clean verdict still prints '<verdict> <sha>'"

# #185's SECOND ACCEPTANCE CRITERION: findings still win outright and IMMEDIATELY. A reviewer with
# something to say must not be held back waiting for a silent sibling — that direction is safe
# (there is work to do either way) and waiting would make the watch useless on a multi-bot repo.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
w observe --pr 1;  rc 10 "#185: one reviewer with findings + one silent -> findings, immediately"

# MIXED EVIDENCE ACROSS SURFACES still folds to all-clean: the classes are per-reviewer, so one
# reviewer's `APPROVED` and another's fresh `+1` are both `clean` and the set is satisfied.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "$BOT2" "APPROVED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "#185: an APPROVED from one and a fresh '+1' from the other -> clean"

# ONE FRESH, ONE STALE. The stale reviewer's `+1` reviewed an EARLIER commit, so that reviewer has
# said nothing about this head — the set is incomplete and the verdict is pending. This is the case
# a naive `sort | last` over the pooled set gets wrong in the most dangerous way: it would take the
# FRESH timestamp, from a different reviewer entirely, and call the whole set clean.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT" "$BOT2" "+1" "$BEFORE_AT"
w observe --pr 1;  rc 11 "#185: one fresh '+1' and one STALE -> pending (a pooled max would say clean)"
has "$OUT" "predates this head" "#185: the stale reviewer's signal is named as stale"

# CLEAN + UNKNOWN -> fail closed. An unreadable signal must not be outvoted into a pass by a sibling
# that happened to look clean; `unknown` outranks `clean` in the fold for exactly this reason.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "$BOT2" "SOME_NEW_STATE" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 20 "#185: a clean reviewer alongside an UNCLASSIFIABLE one -> 20, never clean"

# ATTENTION + PENDING -> findings. Attention outranks a missing signal: there is work to read now,
# and reporting "still waiting" would bury it.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
comment_fx "${CODEX}[bot]" "$AFTER_AT"
w observe --pr 1;  rc 10 "#185: a task-mode comment from one + silence from the other -> findings"

# THE SAME REVIEWER ON TWO SURFACES folds WITHIN that reviewer first: a stale `+1` beside a fresh
# APPROVED is that one reviewer being satisfied, so with the set complete the verdict is clean.
# The within-reviewer order and the across-reviewer order differ on exactly this pair.
reset_fx; declare_bots "[\"$CODEX\", \"$BOT2\"]"
review_fx "${CODEX}[bot]" "APPROVED" "$HEAD_SHA" "$BOT2" "APPROVED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$BEFORE_AT"
wout observe --pr 1;  rc 0 "#185: a STALE '+1' beside that same reviewer's APPROVED is still clean"

# ============================ 5. pagination ============================
# A busy PR can push the bot's reaction off page 1 behind human reactions. A missed `+1` keeps a
# finished watch running to its deadline, so the read must paginate.
reset_fx; declare_bots "[\"$CODEX\"]"
# Since #174 a busy PR reaches the paginated read through TRUNCATION: a GraphQL connection caps at
# 100 records, so a surface whose totalCount exceeds its nodes is re-read through the REST endpoint
# that always paginated. The page-two fixtures below are visible ONLY to that read, which is what
# makes these assertions prove the fallback ran rather than merely that the answer came out right.
_reactions_into "$S/reactions.json" "human-one" "heart" "$AFTER_AT"
_reactions_into "$S/reactions2.json" "$CODEX" "+1" "$AFTER_AT"
printf '101\n' > "$S/reactions-total.txt"
wout observe --pr 1;  rc 0 "pagination: a '+1' behind a truncated connection is still found"

reset_fx; declare_bots "[\"$CODEX\"]"
_reviews_into "$S/reviews.json"  "somebody" "COMMENTED" "$HEAD_SHA"
_reviews_into "$S/reviews2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
printf '101\n' > "$S/reviews-total.txt"
w observe --pr 1;  rc 10 "pagination: a review behind a truncated connection is still found"
has "$OUT" "more than 100 reviews" "the fallback names which surface overflowed"

# An UNTRUNCATED read must not pay for the fallback — the entire point of the collapse.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
wout observe --pr 1;  rc 10 "control: the untruncated single read still classifies"
if called "/pulls/1/reviews"; then bad "an untruncated read must not fall back to the REST surface"; else ok; fi

# ============================ 6. the PR is no longer live ============================
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
w observe --pr 1;  rc 12 "gone: a MERGED PR is terminal"
has "$OUT" "MERGED" "gone: names the merge"
pr_fx --state closed
w observe --pr 1;  rc 12 "gone: a CLOSED PR is terminal"
# Terminal-ness is checked BEFORE the signal reads, so a merged PR stops promptly rather than
# being classified off whatever the reviewer happened to leave behind.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 12 "gone: outranks a clean signal — there is nothing left to watch"

# ============================ 7. the declaration tri-state ============================
reset_fx
declare_bots "[]"
wout observe --pr 1;  rc 0 "declaration: 'bots = []' means nothing is coming -> clean, not an infinite wait"
eq "$OUT" "clean $HEAD_SHA" "declaration: '[]' still reports the witnessed head"

undeclare
w observe --pr 1;  rc 17 "declaration: UNDECLARED is unknowable -> fail closed at 17, never clean"

declare_bots '["[bot]"]'
w observe --pr 1;  rc 18 "declaration: a value that normalizes to nothing is malformed, not '[]'"

# A GLOBAL declaration counts as declared (the repo→global layering role-dispatch owns).
undeclare
printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" > "$GHOME/.config/ai-dev-baseline/agents.toml"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr 1;  rc 0 "declaration: a GLOBAL declaration is honoured"
undeclare; declare_bots "[\"$CODEX\"]"

# ============================ 8. every unreadable path -> 20 ============================
# A failed read must never look like a pass, and must never look like "nothing found yet" either:
# the first would arm on unreviewed code, the second would silently watch a broken API forever.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1  w observe --pr 1; rc 20 "unreadable: a failed single-read -> 20"; STUB_GRAPHQL_FAIL=0
STUB_EMPTY_GRAPHQL=1 w observe --pr 1; rc 20 "unreadable: an EMPTY response body -> 20"; STUB_EMPTY_GRAPHQL=0

# The anchor read happens ONLY when a date-scoped signal exists, so it needs a `+1` to reach it.
reaction_fx "$CODEX" "+1" "$AFTER_AT"
STUB_FAIL_ACTIVITY=1 w observe --pr 1; rc 20 "unreadable: a failed ref-activity read -> 20 (never clean)"; STUB_FAIL_ACTIVITY=0
# A SUCCESSFUL call that produced no document is not an empty list. Collapsing the two would report
# 11 ("no matching activity") for a broken read, which a caller may sit on rather than escalate.
STUB_EMPTY_ACTIVITY=1 w observe --pr 1; rc 20 "unreadable: an EMPTY activity body is not an empty list -> 20"; STUB_EMPTY_ACTIVITY=0

# ...AND THE SAME ON EVERY SIGNAL SURFACE. `adb_paginated_list` tested its PARSED output, but
# `printf '' | jq -s '[.[][]]'` emits `[]` — so a 200-with-no-document read as "that surface carried
# no records" and the check written to catch it could never fire. Here that hides a reviewer's
# findings and lets a fresh `+1` report a clean pass; on the arming guard the same hole returned 0
# and printed a head SHA. Both directions are the one thing this family must never be wrong about.
reset_fx; declare_bots "[\"$CODEX\"]"
review_fx   "${CODEX}[bot]" "CHANGES_REQUESTED" "$HEAD_SHA"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1; rc 10 "control: the findings are seen when the reviews surface reads normally"
# The #174 shape of that same hole: the document arrives, but a CONNECTION is null or malformed.
# A reader that treated a missing `nodes` as an empty list would discard the rejection and let the
# `+1` report clean — and two of these cases DID exactly that before the adapter type-checked
# `nodes` and `totalCount`, which is why each is pinned separately rather than as one case.
_gql_raw() { printf '%s\n' "$1" > "$S/graphql-raw.json"; }
_pr_ok='"state":"OPEN","merged":false,"mergedAt":null,"headRefOid":"'"$HEAD_SHA"'","headRefName":"'"$HEAD_REF"'","baseRepository":{"nameWithOwner":"acme/widget"},"headRepository":{"nameWithOwner":"acme/widget"}'
_rx_fresh='"reactions":{"totalCount":1,"nodes":[{"createdAt":"'"$AFTER_AT"'","user":{"login":"'"$CODEX"'","__typename":"User"}}]}'
_cm_none='"comments":{"totalCount":0,"nodes":[]}'
_rv_none='"reviews":{"totalCount":0,"nodes":[]}'
for broken in '"reviews":null' '"reviews":{"totalCount":0}' '"reviews":{"totalCount":0,"nodes":{}}'; do
  reset_fx; declare_bots "[\"$CODEX\"]"
  _gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$broken"','"$_cm_none"','"$_rx_fresh"'}}}}'
  w observe --pr 1
  rc 20 "a broken reviews connection -> 20; it must NOT let a fresh '+1' report a clean pass ($broken)"
  wout observe --pr 1
  eq "$OUT" "" "...and prints no verdict line ($broken)"
done
reset_fx; declare_bots "[\"$CODEX\"]"
comment_fx  "${CODEX}[bot]" "$LATER_AT"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1; rc 10 "control: the task-mode comment is seen when the comments surface reads normally"
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"',"comments":null,'"$_rx_fresh"'}}}}'
w observe --pr 1; rc 20 "a null comments connection -> 20, not 'that reviewer said nothing'"
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"','"$_cm_none"',"reactions":null}}}}'
w observe --pr 1; rc 20 "a null reactions connection -> 20, not 'no reaction here'"
# A PARTIAL {data,errors} document is the one GraphQL shape with no REST analogue: gh exits
# non-zero AND writes the body, so the adapter rejects `.errors` a second time.
reset_fx; declare_bots "[\"$CODEX\"]"
_gql_raw '{"data":{"repository":{"pullRequest":{'"$_pr_ok"','"$_rv_none"','"$_cm_none"','"$_rx_fresh"'}}},"errors":[{"message":"boom"}]}'
STUB_GRAPHQL_RC=0 w observe --pr 1; rc 20 "a PARTIAL {data,errors} response -> 20 even when gh exits 0"
reset_fx; rm -f "$S/graphql-raw.json"

# A PR object that arrives fine but carries no head SHA is not a network failure — and must still
# not be classified. This is why the read and the parse are separate steps.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx_raw '{"state":"open","base":{"repo":{"full_name":"acme/widget"}}}'
w observe --pr 1;  rc 20 "unreadable: a PR with no head SHA -> 20"

# A PR object that arrives WITHOUT its base repository is unreadable, not "nothing to compare
# against". Guarding the cross-repo refusal on a non-empty slug would make that refusal silently
# VANISH on exactly the malformed responses it exists to catch — and a URL naming another repo
# would then be answered about THIS repo. Both spellings of the missing field are pinned.
pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\"}"
w observe --pr 1;  rc 20 "unreadable: a PR with no base repo -> 20, never classified"
has "$OUT" "unidentifiable repository" "unreadable: names the missing base repo"
w observe --pr "https://github.com/other/repo/pull/7";  rc 20 "unreadable: a missing base repo cannot silently skip the cross-repo refusal"
pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\",\"base\":{\"repo\":null}}"
w observe --pr 1;  rc 20 "unreadable: an explicitly null base repo -> 20"
# A slug that ARRIVES but is not an owner/repo PAIR is a broken response and must be reported as one.
# Comparing it instead would call a malformed read "a different repository" — a confident answer about
# the wrong question.
for v in '"acme"' '"acme/widget/extra"' '"/widget"' '"acme/"'; do
  pr_fx_raw "{\"head\":{\"sha\":\"$HEAD_SHA\"},\"state\":\"open\",\"base\":{\"repo\":{\"full_name\":$v}}}"
  w observe --pr 1;  rc 20 "unreadable: a base repo slug of $v is malformed, not a repo mismatch"
done
pr_fx_raw '{ not json at all'
w observe --pr 1;  rc 20 "unreadable: an unparseable PR object -> 20"

reset_fx; declare_bots "[\"$CODEX\"]"
STUB_AUTH_FAIL=1 w observe --pr 1; rc 20 "unreadable: unauthenticated gh -> 20"; STUB_AUTH_FAIL=0

# ============================ 9. never answer about another repository ============================
# `repos/{owner}/{repo}` expands from the LOCAL remote, so a URL naming a different repo would be
# faithfully answered about THIS one — a confidently wrong answer, the one thing a detector must
# never produce.
reset_fx; declare_bots "[\"$CODEX\"]"
w observe --pr "https://github.com/other/repo/pull/7";  rc 2 "slug: a URL naming another repo is refused"
has "$OUT" "different repository" "slug: says why"
# The SCHEME IS OPTIONAL in a pasted URL, and matching only `*://*` let these through with an empty
# slug — skipping the refusal entirely and confidently answering about THIS repo's #7.
w observe --pr "github.com/other/repo/pull/7";  rc 2 "slug: a scheme-less URL naming another repo is refused"
w observe --pr "other/repo/pull/7";             rc 2 "slug: a bare owner/repo/pull/N naming another repo is refused"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout observe --pr "https://github.com/acme/widget/pull/7";  rc 0 "slug: a URL naming THIS repo is accepted"
eq "$OUT" "clean $HEAD_SHA" "slug: a URL argument yields the same contract as a bare number"
wout observe --pr "acme/widget/pull/7";  rc 0 "slug: a scheme-less URL naming THIS repo is still accepted"

# An argument that is neither a bare number nor a URL naming a repository cannot be answered at all:
# taking the digits after `pull/` alone reduces these to `7`, which is then answered about whichever
# repository the reads happen to address — the cross-repo answer reached from a different input.
w observe --pr "pull/7";                     rc 2 "slug: a PR-ish argument naming no repository is rejected"
w observe --pr "https://github.com/pull/7";  rc 2 "slug: a URL with no owner/repo is rejected"

# A BARE NUMBER NAMES NO REPOSITORY, so nothing in the argument can catch a redirected read — and
# `/resolve-pr-threads --watch` passes exactly that form. Every read addresses `repos/{owner}/{repo}`,
# which gh expands, and the documented GH_REPO variable overrides that expansion (verified live:
# `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers `cli/cli` from a directory that is not a
# repository at all). The anchor is therefore the CHECKOUT's git origin, which no gh variable can
# move. Simulated the only way a stub can: the reads answer for a repository that is not this one.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx --base-slug "other/project"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
w observe --pr 1;  rc 2 "slug: a bare number whose reads answered for ANOTHER repo is refused (GH_REPO class)"
has "$OUT" "GH_REPO" "slug: the refusal names the likely cause"
wout observe --pr 1
eq "$OUT" "" "slug: a redirected read prints no verdict line"
reset_fx; declare_bots "[\"$CODEX\"]"

# stdout is "<verdict> <sha>" or NOTHING — never a bare newline. `wait`'s terminal arm prints the
# captured line, and a slug mismatch produces a code with no line, so an unguarded print would emit
# one empty line that a caller doing `read -r verdict sha` would take as two empty strings.
wout wait --pr "https://github.com/other/repo/pull/7" --interval 1 --max-secs 5;  rc 2 "wait: a slug mismatch is refused"
eq "$OUT" "" "wait: prints NO stdout line for a verdict-less terminal code"

# ============================ 10. usage ============================
w;                                rc 2 "usage: no subcommand"
w badsub;                         rc 2 "usage: unknown subcommand"
w observe;                        rc 2 "usage: observe without --pr"
w wait;                           rc 2 "usage: wait without --pr"
w observe --pr;                   rc 2 "usage: --pr with no value"
w observe --pr "";                rc 2 "usage: --pr empty"
has "$OUT" "must not be empty" "usage: an EMPTY value reports emptiness, not the arity message"
w observe --pr notanumber;        rc 2 "usage: --pr not a number or URL"
w observe --pr 0;                 rc 2 "usage: --pr zero"
w observe --pr 1 --bogus x;       rc 2 "usage: unknown option"
w wait --pr 1 --interval 0;       rc 2 "usage: --interval zero would busy-wait"
w wait --pr 1 --interval abc;     rc 2 "usage: --interval non-numeric"
w wait --pr 1 --max-secs 0;       rc 2 "usage: --max-secs zero would return before the first read"
w wait --pr 1 --max-secs "";      rc 2 "usage: --max-secs empty"
# All-digits is not enough: a value wider than a shell integer overflows the deadline arithmetic,
# turning the bound into a nonsense (possibly negative) remaining time — a bound that expires at
# once or never. Digits-only validators are exactly how that slips through.
w wait --pr 1 --max-secs 99999999999999999999;  rc 2 "usage: --max-secs wider than a shell integer"
w wait --pr 1 --interval 99999999999999999999;  rc 2 "usage: --interval wider than a shell integer"

# ============================ 11. the bounded wait ============================
# READ `$WATCH_BACKSTOP`'s comment before changing any `--max-secs` here (#394): a case whose oracle
# is a fixture uses the backstop, a case whose oracle IS the deadline uses a small literal, and
# swapping the two is how this section shipped a test that a loaded runner could end early.
#
# Terminal on the first poll: return immediately, and sleep NOT AT ALL. A watcher that sleeps once
# before checking wastes an interval on a PR that was already done.
reset_fx; declare_bots "[\"$CODEX\"]"
reaction_fx "$CODEX" "+1" "$AFTER_AT"
wout wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "wait: a terminal first poll returns at once"
eq "$OUT" "clean $HEAD_SHA" "wait: emits the same '<verdict> <sha>' contract as observe"
eq "$( [ -f "$S/slept" ] && wc -l < "$S/slept" | tr -d ' ' || echo 0 )" "0" "wait: does not sleep before its first read"

# Pending, then findings: the loop must converge on the LATER answer, not the first one.
reset_fx; declare_bots "[\"$CODEX\"]"
printf '[]\n' > "$S/reviews.1.json"                                  # poll 1: nothing yet
_reviews_into "$S/reviews.2.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"   # poll 2: findings
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 10 "wait: converges when the signal appears on a later poll"

# The deadline is a bound. This half of the claim is load-INSENSITIVE by construction: with no
# terminal signal the loop can only ever leave through the deadline, so a slow poll changes WHEN
# it expires and not WHETHER — which is why this case keeps a small literal bound.
reset_fx; declare_bots "[\"$CODEX\"]"
w wait --pr 1 --interval 30 --max-secs 3;  rc 11 "wait: expires at the bound with no terminal signal"
has "$OUT" "handing off" "wait: says it is handing off rather than claiming a verdict"
# THE TIMEOUT MUST NAME WHO IS STILL SILENT. Suppressing the per-poll `pending` line (#417) must not
# cost the operator the one fact this handoff exists to deliver: on a multi-reviewer repo a deadline
# reached with one reviewer clean and another quiet is useless as a bare "expired". The detail is
# captured on every classification and printed ONCE, here. Reported by the declared reviewer on
# PR #419.
has "$OUT" "$CODEX" "wait: the timeout NAMES the reviewer still lacking a terminal signal"
# ...and the loop is otherwise quiet: the per-poll line must not appear once per poll. With a 30s
# interval this run polls once, so the check that matters is that the phrase appears EXACTLY once —
# the deadline's copy — rather than once per classification plus once at the end.
eq "$(printf '%s\n' "$OUT" | grep -c 'no terminal signal')" "1" \
   "wait: the silent-reviewer detail is printed ONCE, not per poll"

# The other half — the sleep must never overshoot the bound — USED TO RIDE THE CASE ABOVE, and a nap
# only exists when a poll leaves time on the clock: a first poll outliving the bound made the watch
# return without sleeping, and the assertion could not fire (the second instance of #394, D85).
#
# So the clamp gets its own scenario, where the nap is produced by a FIXTURE rather than by a race:
# the PR closes on poll 2, so exactly one nap is taken, and the interval is far larger than the
# bound so that nap must be the clamped value rather than the requested one. Load can only shorten
# what remains, never delete the nap.
# TWO BOUNDS, NOT ONE, and that is what makes this an assertion about the CLAMP rather than about
# the nap's magnitude. A single scenario can only bracket the value, and a bracket admits any
# constant inside it: with `<= bound` and `< interval` alone, a watcher that napped a flat ZERO
# passed the whole suite (found in review). The clamped nap is `min(interval, remaining)`, so
# halving the bound must halve it; a constant — 0, 1, or anything else — cannot track both.
# IT SETS A GLOBAL AND PRINTS NOTHING, so that `CLAMP_HI="$(clamp_nap …)"` is impossible to write.
# A command substitution forks a SUBSHELL, and `ok`/`bad` increment `pass`/`fail` there — so every
# assertion this function makes would be counted into a copy that is discarded on return, while
# `bad`'s diagnostic still reached the log on stderr. The suite then PRINTS `FAIL:` and exits 0.
# Measured on a copy: forcing the `rc` inside this function to disagree left the run reporting
# "238 passed, 0 failed" over two FAIL lines. That is the exact defect #394 is about — a guard that
# cannot fail — reintroduced by the shape of the call rather than by the assertion.
CLAMP_NAP=""
CLAMP_SLOW=2   # seconds of latency forced into poll 1 of the FIRST scenario; see CLAMP_HI below
clamp_nap() {   # <max-secs> [slow-secs] -> sets CLAMP_NAP to the single recorded nap, or "" if not one
  CLAMP_NAP=""
  reset_fx; declare_bots "[\"$CODEX\"]"
  pr_poll_fx 2 --state closed --merged-at "2026-07-25T05:00:00Z"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$S/slow-1"
  w wait --pr 1 --interval 3000 --max-secs "$1";  rc 12 "wait: the clamp scenario (--max-secs $1) ends on its fixture, not on its deadline"
  [ -f "$S/slept" ] || { bad "wait: expected exactly one recorded nap before the terminal poll (--max-secs $1)"; return 0; }
  eq "$(wc -l < "$S/slept" | tr -d ' ')" "1" "wait: took exactly one nap before the terminal poll (--max-secs $1)"
  CLAMP_NAP="$(head -1 "$S/slept")"
}
clamp_nap "$WATCH_BACKSTOP" "$CLAMP_SLOW";  CLAMP_HI="$CLAMP_NAP"
clamp_nap "$(( WATCH_BACKSTOP / 4 ))";      CLAMP_LO="$CLAMP_NAP"
# THE CEILING IS THE REMAINING TIME, NOT THE BOUND, and telling those apart needs poll 1 to have
# cost something MEASURABLE — which is why the first scenario forces `$CLAMP_SLOW` seconds into it.
# Without that, `remaining` and `--max-secs` are the same integer and a watcher that napped the
# ORIGINAL bound passed the whole suite while oversleeping the deadline by however long poll 1 took
# (found in review; shipped as the `nap-is-the-bound` mutation). The injection makes `remaining`
# provably `<= bound - CLAMP_SLOW`, and load can only lower it further, so this cannot flake.
if [ -n "$CLAMP_HI" ] && [ "$CLAMP_HI" -le "$(( WATCH_BACKSTOP - CLAMP_SLOW ))" ] && [ "$CLAMP_HI" -lt 3000 ]; then ok
else bad "wait: sleeps what REMAINS, not the original bound, and clamps the oversized interval down to it (got [$CLAMP_HI], want <= $(( WATCH_BACKSTOP - CLAMP_SLOW )))"; fi
# Then the one no constant can satisfy. A correct nap is `bound - (what poll 1 cost)`, so the gap
# between the two runs is the gap between the bounds less two poll costs — asserted as "most of it"
# rather than exactly, because poll latency is the one quantity here that load moves.
if [ -n "$CLAMP_HI" ] && [ -n "$CLAMP_LO" ] && [ "$(( CLAMP_HI - CLAMP_LO ))" -ge "$(( WATCH_BACKSTOP / 2 ))" ]; then ok
else bad "wait: the nap TRACKS the remaining bound rather than being any constant (got [$CLAMP_HI] vs [$CLAMP_LO])"; fi

# A single transient error must not abandon a long watch...
reset_fx; declare_bots "[\"$CODEX\"]"
printf '{ broken\n' > "$S/pr.1.json"                                  # poll 1 unparseable
_reactions_into "$S/reactions.2.json" "$CODEX" "+1" "$AFTER_AT"       # poll 2 fine
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "wait: rides out ONE unreadable poll and converges"

# The deadline can land while the LAST poll was unreadable, and that poll printed no verdict. The
# contract says stdout is "<verdict> <sha>" or nothing — never a bare newline, which a caller doing
# `read -r verdict sha` would silently take as two empty strings rather than "there was no answer".
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 wout wait --pr 1 --interval 1 --max-secs 1;  rc 11 "wait: a bound reached mid-failure still reports pending"
eq "$OUT" "" "wait: prints NO stdout line when the final poll produced no verdict"
STUB_GRAPHQL_FAIL=0

# ...but an endlessly unreadable API must not be polled forever either.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 20 "wait: gives up after consecutive unreadable polls"
has "$OUT" "consecutive unreadable" "wait: names why it gave up"
STUB_GRAPHQL_FAIL=0

# A PR that merges mid-watch stops the loop rather than running to the deadline.
reset_fx; declare_bots "[\"$CODEX\"]"
pr_fx
pr_poll_fx 2 --state closed --merged-at "2026-07-25T05:00:00Z"
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: stops as soon as the PR stops being open"

# A head that moves mid-watch is reported, and the new head is judged on ITS OWN arrival: a signal
# left in the previous head's era does not carry over.
#
# THE WATCH IS ENDED BY A FIXTURE, NOT BY THE DEADLINE (#394, D85). This case's oracle is a line
# only the SECOND poll can print, and `wait` bounds itself with real elapsed time — so a
# `--max-secs` tight enough to end the watch is also tight enough for a loaded runner to reach
# first, ending it after one poll with `rc` satisfied vacuously. Poll 3 therefore closes the PR,
# and `--max-secs` is a runaway backstop. The poll count is asserted so a re-tightened bound cannot
# quietly become the oracle again.
#
# rc 12 IS the staleness claim, not a weaker stand-in for rc 11: a `+1` wrongly honoured for the
# new head returns 0 at poll 2 and never reaches poll 3 at all.
# ONE BUILDER FOR BOTH SCENARIOS BELOW, because they must stay the SAME scenario: the second is the
# first with latency injected, and an edit that reached only one of them would leave the injected
# run quietly testing something else while still reporting a pass.
head_move_fx() {
  reset_fx; declare_bots "[\"$CODEX\"]"
  pr_poll_fx 1 --sha "$OLD_SHA"
  pr_poll_fx 2
  pr_poll_fx 3 --state closed --merged-at "2026-07-25T05:00:00Z"
  # BOTH heads are dated, so "the previous head's era" is something the fixture STATES rather than
  # something a comment claims: bbbb arrives at 04:40, aaaa at 04:45, and the `+1` lands at 04:42 —
  # after the head it belongs to, before the head it must not satisfy. `adb_head_anchor` reads
  # every record and rejects the ones whose `after` is not the head being judged, so bbbb's is read
  # but never SELECTED, and no verdict here turns on it. It is present so the era is legible, and
  # so an edit that does put a dated signal on poll 1 finds the anchor it would then need.
  activity_fx "$OLD_SHA"  "refs/heads/$HEAD_REF" "$BEFORE_AT" \
              "$HEAD_SHA" "refs/heads/$HEAD_REF" "$AFTER_AT"
  # THE `+1` ARRIVES ON POLL 2, and it has to. With one declared reviewer a `+1` that is genuinely
  # fresh for the old head classifies `clean` on poll 1 and returns 0 there, so the watch could
  # never observe the move at all — which is why the fixture this case used to carry anchored only
  # the NEW head and left poll 1 pending for want of an anchor, testing the staleness rule nowhere.
  _reactions_into "$S/reactions.1.json"      # poll 1: nobody has said anything yet
  reaction_fx "$CODEX" "+1" "$ARRIVED_AT"    # polls 2+
}

head_move_fx
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: a signal from the PREVIOUS head's era does not satisfy the new one"
has "$OUT" "head moved $OLD_SHA -> $HEAD_SHA" "wait: reports that the head moved under it"
has "$OUT" "predates this head's arrival" "wait: says WHY the previous era's signal does not count"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "wait: ended on the fixture's terminal poll, not on its deadline"

# THE SAME CASE WITH THE LATENCY INJECTED — the check a re-tightened `--max-secs` cannot pass, since
# an idle machine still reads 3 polls under one. 4s exceeds the retired 3s bound (D85).
#
# IT IS A REAL NAP, so it is a real cost, and the cost is per SUITE RUN rather than per selfcheck:
# `--mutation` executes the suite once per row plus a control, so a full selfcheck pays it several
# times over. Spent on this one scenario and nowhere else.
head_move_fx
printf '4' > "$S/slow-1"
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "wait: a first poll outliving the retired bound no longer ends the watch"
has "$OUT" "head moved $OLD_SHA -> $HEAD_SHA" "wait: still reports the head move when the first poll is slow"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "wait: a slow first poll costs latency, not polls"

# ============ 11b. THE DEADLINE'S CLOCK IS NOT THE ENVIRONMENT'S TO SET (#258) ============
# Every deadline assertion above passes on either clock source, which is exactly why they cannot
# stand in for these. `wait` used to bound itself with `$SECONDS`; it now uses `BASH_MONOSECONDS`.
#
# T1 proves the PROPERTY on this interpreter, at the primitive: `SECONDS` is an ordinary writable
# variable that a caller can move at will, and `BASH_MONOSECONDS` silently refuses assignment WHILE
# IT RETAINS ITS SPECIAL NATURE. That difference is the entire reason for the change, so it is
# asserted rather than assumed — a future bash that made BASH_MONOSECONDS writable would break the
# premise and nothing else here would say so.
#
# The qualifier is load-bearing and not hedging: `unset BASH_MONOSECONDS` strips the special nature,
# after which assignment works normally. That is why the library's comment scopes its guarantee to
# the system clock and to an EXECUTED entry point (which gets the special variable rebuilt), rather
# than claiming nobody can move it.
# `"$BASH"`, NOT a bare `bash` — and this is the very trap the repo's own shell-discipline practice
# documents, reproduced inside a test written to prove a 5.3 property. This script re-execs itself
# onto a >= 5.3 interpreter, but that does NOT rewrite `PATH`: on macOS a bare `bash` still resolves
# `/bin/bash` 3.2.57, which has no `BASH_MONOSECONDS` at all, so the probe answered `100` and the
# whole suite went red for anyone whose PATH did not already carry the Homebrew prefix. `$BASH` is
# the interpreter actually running this file, which is by construction the one the assertion is about.
#
# The second term compares against `m0` rather than a fixed floor: an absolute `> 100` would have
# made the assertion depend on the machine's UPTIME, so it would fail on a freshly booted host.
mono_probe="$("$BASH" -c 'm0=$BASH_MONOSECONDS
                       SECONDS=100000
                       BASH_MONOSECONDS=5 2>/dev/null
                       printf "%s%s%s" "$(( SECONDS >= 100000 ))" "$(( BASH_MONOSECONDS >= m0 ))" "$(( BASH_MONOSECONDS - m0 < 5 ))"' 2>/dev/null)"
eq "$mono_probe" "111" "T1 SECONDS is writable and BASH_MONOSECONDS is not — the premise of the deadline's clock"

# T2 pins that `wait` actually READS that clock. It is a source pin, not a behavioural assertion,
# and the distinction is stated rather than blurred because a pin that looks like a behavioural test
# is worse than one that admits what it is. The suite already pins source this way at the bottom
# (`absent`), for the same reason: some properties have no reachable fixture.
#
# WHY THERE IS NO END-TO-END FIXTURE HERE — this was attempted and discarded, so the next reader
# does not spend the same hour:
#   - A CONSTANT offset does not discriminate. `SECONDS` is inherited from the environment, so a
#     process can start with it anywhere, including near the top of the signed range — but
#     `deadline=$(( SECONDS + max ))` and `$(( deadline - SECONDS ))` overflow SYMMETRICALLY and the
#     wraparound cancels. Measured: with SECONDS=9223372036854775800 and --max-secs 30, `deadline`
#     is -9223372036854775786 and `remaining` is exactly 30. The pre-#258 code was already correct
#     under that, and a fixture built on it PASSES on both clocks while appearing to prove one.
#   - Only a MID-RUN jump separates them, and that needs an in-process assignment to SECONDS. The
#     `gh`/`sleep` stubs are separate processes and cannot reach the watcher's variables.
# So the property lives in T1 and the wiring lives here, and the headline benefit — a wall-clock
# adjustment mid-watch no longer shortens or extends the bound — is REASONED from the two, not
# reproduced. Saying so is better than a green fixture that proves neither half.
#
# ONE CORRECTION, because the first version of this note overstated it. It claimed no behavioural
# fixture was reachable "without a test seam in production code". That is false, and the independent
# review said so: a `DEBUG` trap injected through `BASH_ENV` with function tracing can read
# `BASH_COMMAND` and move `SECONDS` immediately before the old arithmetic, distinguishing the two
# clocks end-to-end with production untouched. It is not built here — it pins the shape of one
# expression through a trap that fires on every command in the file, which is a fixture that breaks
# on any refactor of code it is not even testing — but "we chose not to" and "it cannot be done" are
# different sentences, and only the first one is true.
uses() { if grep -q "$1" "$PW"; then ok; else bad "$2"; fi; }
uses 'BASH_MONOSECONDS' "T2 wait's bound is computed from the monotonic clock"
eq "$(grep -cE '(deadline|remaining)=\$\(\(.*\bSECONDS\b' "$PW")" "0" \
   "T2 ...and no deadline arithmetic reads the movable \$SECONDS any more"

# ============================ 12. the module's own boundary ============================
# pr-review.sh's header names this module as where a waiting watch belongs, and this module's
# header promises not to resolve, push, or merge. Pin that promise: a detector that grew an arming
# call would silently turn an observation into a merge, which is the one escalation nothing else
# here would catch — every assertion above would still pass.
absent() { if grep -q "$1" "$PW"; then bad "$2"; else ok; fi; }
absent 'gh pr merge'        "the detector must never arm or perform a merge"
absent 'git push'           "the detector must never push"
absent 'resolveReviewThread' "the detector must never resolve threads"
absent 'git switch'         "the detector must never move the working tree"
# ...and the retired anchor stays retired (#175). Pinned as the JQ PATH and the ENDPOINT rather than
# as prose, so the header may go on explaining WHY the committer date was rejected — which it must,
# or the next reader reaches for the same obvious lower bound — without tripping this rule.
absent 'commit\.committer\.date' "the staleness proof must never return to the client-supplied committer date"
# Narrowed by #448 the same way: `commits/$head/check-runs` is the CI read, and only a path ENDING
# at the commit is the retired anchor.
if grep -qE 'commits/\$\{?head\}?([^/A-Za-z0-9_}]|$)' "$PW"; then bad "the head-commit endpoint must not come back as an anchor read"; else ok; fi
absent 'gh run rerun'            "the detector must never re-run CI — routing a red is the resolver's job (#448)"


# ============================ 13. request-review (#169) ============================
# ROUND 2 COULD NOT HAPPEN. A push is not one of the reviewer's triggers, so after a resolve round
# pushes a fix the watch honestly reads `pending` until the bound expires. `request-review` is the
# ask that closes the loop — and it is this module's ONE mutation, so every refusal path matters
# more than the success path: the failure mode of getting it wrong is spamming a reviewer on every
# poll of a half-hour watch.
receipt_fx() { check_pr_receipts_json "$S/receipts.json" "$@"; }
TRIGGER='@codex review'

# --- the happy path: nothing has been asked yet, so ask exactly once --------------------------
# ASSERT THE POST ITSELF, not the module's own diagnostic about it. The stub records every comment
# it is asked to create, so `$S/posted` is evidence a request really crossed the wire and what it
# said — an assertion on the log line alone stays green if `-f body=...` is deleted or the call is
# aimed at a no-op endpoint. Named by the independent review.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: a head with no prior request is asked for once"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "request-review: exactly ONE comment was actually posted"
eq "$(cat "$S/posted")" "$TRIGGER" "request-review: the posted BODY is the reviewer's own documented trigger"
has "$OUT" "round 1 of 6" "request-review: the round is reported against the effective cap"
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
wout request-review --pr 1
eq "$OUT" "requested $HEAD_SHA" "request-review: stdout is '<verdict> <sha>', like every other verdict here"

# IDEMPOTENCY AS SUCCESS-THEN-REPEAT, which is the property #169 actually states. The stub persists
# the comment it posted into the receipt fixture, so the second invocation reads the receipt THIS
# RUN created rather than one the scenario preloaded. That is the difference between proving
# "a receipt is recognised" and proving "a successful request BECOMES the receipt". Named by the
# independent review, which observed that the earlier pair proved only the first.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0  "idempotency: the first request succeeds"
w request-review --pr 1;  rc 13 "idempotency: the SECOND invocation sees the receipt the first one created"
w request-review --pr 1;  rc 13 "idempotency: and the third"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "idempotency: still exactly one comment on the wire after three calls"

# THE SAME-SECOND BOUNDARY. GitHub timestamps are second-precision, so a request posted moments
# after the push it answers can share a second with the ref-arrival anchor. The receipt comparison
# is INCLUSIVE for exactly this case — treating the tie as "no receipt" posts again, and then again
# on every poll. Note the signal rules deliberately round the OTHER way; see the function header.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_POST_AT="$ARRIVED_AT" w request-review --pr 1;  rc 0 "same-second: the first request is made"
STUB_POST_AT="$ARRIVED_AT" w request-review --pr 1
rc 13 "same-second: a receipt sharing the anchor's second still counts, and is not re-posted"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "same-second: exactly one comment on the wire"

# A FAILED POST IS NOT A MADE REQUEST.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_FAIL_POST=1 w request-review --pr 1;  rc 20 "request-review: a failed POST is 20, never a made request"
STUB_FAIL_POST=0

# THE PR MUST STILL BE OPEN AT THE MOMENT OF THE MUTATION, not merely when it was first read
# (verify-before-asserting.md). Everything above it is read across two or three round trips.
#
# THE FIXTURE MUST CHANGE *UNDER* THE CALLER, or this proves nothing. The obvious version — a PR
# that is closed from the start — is caught by the EARLIER state check and returns 12 either way,
# so it passes with the re-verify deleted. Observed doing exactly that. `rpr.2.json` closes the PR
# on the SECOND receipt read, which is the re-verify.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
check_pr_json "$S/rpr.2.json" --sha "$HEAD_SHA" --state closed --merged-at "2026-07-25T05:00:00Z" \
  --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF"
w request-review --pr 1;  rc 12 "request-review: a PR closed before the POST is not asked"
if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted to a PR that closed under us"; else ok; fi
# ...and the same for a head that moved: asking for a review of a superseded head is noise.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
check_pr_json "$S/rpr.2.json" --sha "$OLD_SHA" --state open --merged-at "" \
  --base-slug acme/widget --head-slug acme/widget --head-ref "$HEAD_REF"
w request-review --pr 1;  rc 20 "request-review: a head that moved before the POST is not asked about"
if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted about a superseded head"; else ok; fi
# The control: an UNCHANGED PR still posts, so the re-verify is not simply blocking everything.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review --pr 1;  rc 0 "control: an unchanged PR still gets its request"

# --- IDEMPOTENCY, the property #169 names explicitly ------------------------------------------
# The receipt is a trigger comment NEWER than this head's arrival. A second observation of the same
# head must not post again, however many polls make it.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$AFTER_AT" "$TRIGGER"
w request-review --pr 1;  rc 13 "request-review: a request already made for THIS head is not repeated"
has "$OUT" "already requested" "request-review: says why nothing was posted"
wout request-review --pr 1
eq "$OUT" "already $HEAD_SHA" "request-review: the idempotent no-op still names the head it is about"
# ...three times in a row, because "at most one per head however many polls observe it" is the claim.
w request-review --pr 1;  rc 13 "request-review: still idempotent on a third observation"

# A request from BEFORE this head arrived is NOT a receipt for it — that is the whole staleness
# rule, applied to the ask instead of to the answer. This is the case a naive "has anyone ever
# commented?" check gets wrong, and getting it wrong means round 2 never happens.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 0 "request-review: a request predating this head does not count as its receipt"

# THE REVIEWER'S OWN BOILERPLATE MUST NOT COUNT AS A RECEIPT. Every lightweight review body quotes
# the trigger list verbatim — 'Comment "@codex review".' — so a SUBSTRING match would read the
# reviewer's own post as this module's request, spend the cap, and never ask at all.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$AFTER_AT" 'Reviews are triggered when you
- Open a pull request for review
- Comment "@codex review".'
w request-review --pr 1;  rc 0 "request-review: the reviewer's own quoted trigger list is not a receipt"
# ...but surrounding whitespace on a real request still is one: the body is TRIMMED, not exact.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$AFTER_AT" "  $TRIGGER
"
w request-review --pr 1;  rc 13 "request-review: a real request with stray whitespace still counts"

# --- THE ROUND CAP ----------------------------------------------------------------------------
# Counted from the PR, at ANY head — anchoring it to the head would reset the cap on every push,
# which is the runaway it exists to bound.
#
# THE BUILT-IN IS SIX (#416), raised from #49's untested "~3" after a field session measured three
# wrong: a productive six-round resolve hit the cap because four trigger comments already existed,
# all four posted by hand. Six receipts to reach it, so the fixture below is what a cap of 3 could
# never have been tested with.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" \
           "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 15 "request-review: the round cap refuses a seventh ask"
has "$OUT" "cap 6" "request-review: the cap is named"
# ...and THREE receipts no longer cap, which is the whole point of the raise: it is the exact
# fixture that returned 15 before #416 and must now be allowed through.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 0 "request-review: three prior requests no longer cap (the #416 raise)"
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" \
           "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
wout request-review --pr 1
eq "$OUT" "capped $HEAD_SHA" "request-review: the capped verdict names the head"

# THE HANDOFF IS A SPECIFIED TERMINAL STATE, not an incidental refusal (#416). All four facts, so
# the operator does not have to reverse-engineer the number or the remedy — which is exactly what
# the field session had to do.
reset_fx; declare_bots "[\"$CODEX\"]"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" \
           "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 15 "capped: the handoff fires"
has "$OUT" "6 re-review request(s) observed" "capped: it names the OBSERVED count"
has "$OUT" "cap 6"                           "capped: ...and the effective cap"
has "$OUT" "built-in default"                "capped: ...and WHICH source set it"
has "$OUT" "MANUALLY POSTED TRIGGER COMMENTS SPEND THE SAME BUDGET" \
   "capped: ...and that a human's own requests spend the same budget"
has "$OUT" "--max-rounds"                    "capped: ...and the raise path"
has "$OUT" "max_rounds"                      "capped: ...including the repo-level one"

# --- CAP PRECEDENCE: --max-rounds > [reviewers] max_rounds > built-in (#416) -------------------
# THE SOURCE IS ASSERTED ALONGSIDE THE VALUE, every time. A cap that is numerically right for the
# wrong reason is how an operator edits the file that is not being read.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1 --max-rounds 1;  rc 15 "precedence: --max-rounds 1 caps after a single ask"
has "$OUT" "cap 1"        "precedence: the flag's value is the effective cap"
has "$OUT" "--max-rounds" "precedence: ...and the flag is named as its source"
w request-review --pr 1 --max-rounds x;  rc 2  "request-review: a non-numeric --max-rounds is rejected"
# `--max-rounds 0` WAS a usage error here until #420, and is now the uncapped sentinel. Its own
# section below owns it, because proving "uncapped" needs a fixture that would cap under any
# positive bound, and this block's is one receipt.

# The MANIFEST sets it when no flag does.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = 2' > "$REPO/agents.toml"
receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER"
w request-review --pr 1;  rc 15 "precedence: [reviewers] max_rounds sets the cap"
has "$OUT" "cap 2"                             "precedence: the manifest's value is the effective cap"
has "$OUT" "[reviewers] max_rounds" "precedence: ...and the manifest key is named as its source"
# NAMING THE KEY IS NOT ENOUGH — it must name WHICH agents.toml, because the key layers repo →
# global and the handoff exists to tell the operator which file to edit.
has "$OUT" "this repo's agents.toml" "precedence: ...and it names the REPO layer specifically"
# ...and the FLAG still wins over it.
w request-review --pr 1 --max-rounds 9;  rc 0 "precedence: --max-rounds overrides the manifest"

# A MALFORMED MANIFEST VALUE IS A HARD ERROR, never a silent fall-back to the built-in. Falling back
# would hand the operator a cap they did not choose, from a file they thought they had configured.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = "six"' > "$REPO/agents.toml"
receipt_fx
w request-review --pr 1;  rc 2 "precedence: a malformed max_rounds is exit 2, not the built-in 6"
if [ -f "$S/posted" ]; then bad "precedence: nothing may be posted under an unusable cap"; else ok; fi
# `max_rounds = 0` WAS refused here until #420. What survived the change is the half that still
# matters — it must not be read as UNSET — and the uncapped section below proves it with a fixture
# that tells the two apart, which `receipt_fx` with no receipts could never do.
# ...and the flag still wins even over an unusable manifest value, because it is never consulted.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = "six"' > "$REPO/agents.toml"
receipt_fx
w request-review --pr 1 --max-rounds 3;  rc 0 "precedence: an explicit flag does not read the manifest at all"

# --- THE UNCAPPED SENTINEL: 0 removes the ceiling entirely (#420) ------------------------------
# `[gates] "" disables` applied to a round budget: a zero-value sentinel disabling a mechanism,
# spelled in the config surface's own vocabulary. A project must be able to say "run until clean"
# outright rather than pick a number and hope it is big enough.
#
# EVERY CASE HERE USES A SEVEN-RECEIPT FIXTURE — one MORE than the built-in 6 — and that is the
# whole design of this section rather than an arbitrary number. Under any bound this suite can
# produce, seven receipts cap; so a green below cannot be a bound that merely happens to be large,
# and it cannot be a fixture too small to reach any bound. The CONTROL immediately after each pass
# runs the SAME fixture against a positive cap and requires 15, which is what turns that argument
# from an assertion about the code into an observation about this fixture.
sevenfold() { receipt_fx "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" \
                         "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" "$BEFORE_AT" "$TRIGGER" \
                         "$BEFORE_AT" "$TRIGGER"; }

# THE FLAG PATH.
reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
w request-review --pr 1 --max-rounds 0;  rc 0 "uncapped: --max-rounds 0 asks past the built-in 6 (#420)"
# THE POST ITSELF, not the diagnostic about it: an assertion on the log line alone stays green if
# the request never crosses the wire. The suite's own rule, stated at the happy path above.
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "uncapped: ...and exactly ONE comment was really posted"
has "$OUT" "UNCAPPED" "uncapped: the round line SAYS uncapped rather than the false 'of 0'"
has "$OUT" "--max-rounds" "uncapped: ...and names which source removed the ceiling"
# THE CONTROL. Same fixture, a positive cap: it must cap. Without this, the pass above is equally
# consistent with a fixture that never reached any bound.
reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
w request-review --pr 1 --max-rounds 6;  rc 15 "control: the SAME fixture caps at 6 — so the pass above is the sentinel, not the fixture"

# IDEMPOTENCY IS UNTOUCHED BY THE SENTINEL, which is the acceptance criterion's other half and the
# property that keeps an uncapped loop from tight-spinning. Uncapped means no CEILING, not "ask
# again on every poll": a head already asked about is still 13, and still posts nothing.
reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
w request-review --pr 1 --max-rounds 0;  rc 0 "uncapped: the first ask about a fresh head is made"
w request-review --pr 1 --max-rounds 0;  rc 13 "uncapped: a head already asked about is STILL 13, not a re-post"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "uncapped: ...and nothing further crossed the wire"

# THE MANIFEST PATH, and the half of the retired assertion that still matters: `0` must not read as
# UNSET. Those two answers are opposite — unset sends the caller to its built-in 6, which caps this
# fixture — so the seven receipts are what tell them apart.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = 0' > "$REPO/agents.toml"
sevenfold
w request-review --pr 1;  rc 0 "uncapped: [reviewers] max_rounds = 0 removes the ceiling, and is NOT read as unset"
eq "$(wc -l < "$S/posted" | tr -d ' ')" "1" "uncapped: ...posting exactly one comment"
has "$OUT" "UNCAPPED" "uncapped: the manifest sentinel reports uncapped too"
has "$OUT" "this repo's agents.toml" "uncapped: ...and names WHICH agents.toml removed the ceiling"
# ...and the flag still wins over the manifest, in the direction that RE-IMPOSES a bound: an
# operator overriding an uncapped repo policy for one invocation must get the cap they asked for.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = 0' > "$REPO/agents.toml"
sevenfold
w request-review --pr 1 --max-rounds 6;  rc 15 "uncapped: an explicit --max-rounds re-imposes a bound over an uncapped manifest"
# ...and the reverse: the flag uncaps a repo whose manifest declares a bound this fixture exceeds.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = 2' > "$REPO/agents.toml"
sevenfold
w request-review --pr 1 --max-rounds 0;  rc 0 "uncapped: --max-rounds 0 uncaps a repo that declared a bound"

# `0` IS THE ONLY SENTINEL. Every one of these would become a second spelling of "uncapped" under a
# numeric test (`-eq 0` is true for `00`) or a relaxed shared validator, and each must refuse with
# NOTHING POSTED — a malformed bound that posts first and errors after has already spent the round.
declare_bots "[\"$CODEX\"]"
for _bad in 00 -1 1.5 x; do
  reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
  w request-review --pr 1 --max-rounds "$_bad"
  rc 2 "sentinel: --max-rounds $_bad is refused, never a second spelling of uncapped"
  if [ -f "$S/posted" ]; then bad "sentinel: nothing may be posted under the refused cap '$_bad'"; else ok; fi
done
# An EMPTY value is its own refusal and must stay one: it would otherwise leave the module's
# "no flag was given" encoding in place and fall through to the manifest, so an operator who typed
# a bound would silently get the repo's.
reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
w request-review --pr 1 --max-rounds "";  rc 2 "sentinel: an EMPTY --max-rounds is refused, not treated as absent"
# ...AND NAMES THE DOMAIN. The empty check returns before `_adb_pw_resolve_rounds` is ever reached,
# so it is the one refusal that does not inherit that function's diagnostic — and `""` is named in
# the acceptance criteria alongside `-1` and `1.5`. A status-only assertion here passed while the
# message said nothing about what to type instead. Named by the independent review.
has "$OUT" "0 for uncapped" "sentinel: ...and the empty refusal names the accepted domain too"
# THE DIAGNOSTIC NAMES THE WHOLE ACCEPTED DOMAIN, sentinel included. The shared `require_uint` says
# "a positive integer", which is the truth for --interval and --max-secs and half of it here — and
# half a domain is how an operator concludes there is no uncapped spelling.
reset_fx; declare_bots "[\"$CODEX\"]"; sevenfold
w request-review --pr 1 --max-rounds -1
has "$OUT" "0 for uncapped" "sentinel: the refusal names the accepted domain, INCLUDING the sentinel"

# THE MANIFEST'S DOMAIN, likewise — same rule, the other surface.
for _bad in '00' '-1' '3.5' '""'; do
  reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" "max_rounds = $_bad" > "$REPO/agents.toml"
  sevenfold
  w request-review --pr 1
  rc 2 "sentinel: [reviewers] max_rounds = $_bad is refused, never a second spelling of uncapped"
  if [ -f "$S/posted" ]; then bad "sentinel: nothing may be posted under the refused manifest cap '$_bad'"; else ok; fi
done
declare_bots "[\"$CODEX\"]"

# `observe` and `wait` have NO round cap to resolve, so a malformed one must not break them: the
# resolution is deliberately inside request-review rather than at parse time.
reset_fx; printf '%s\n' '[reviewers]' "bots = [\"$CODEX\"]" 'max_rounds = "six"' > "$REPO/agents.toml"
w observe --pr 1;  rc 11 "precedence: a malformed max_rounds does not affect observe"
declare_bots "[\"$CODEX\"]"

# --- A REVIEWER WITH NO KNOWN TRIGGER IS SKIPPED, NOT FAILED ----------------------------------
# #169 requires exactly this: no request, no error. Posting a guessed phrase at an unknown bot is
# spam nobody asked for.
reset_fx; declare_bots '["some-other-reviewer"]'; receipt_fx
w request-review --pr 1;  rc 14 "request-review: a declared reviewer with no known trigger is skipped"
has "$OUT" "no declared reviewer has a re-review trigger" "request-review: says why it skipped"
reset_fx; declare_bots '[]'; receipt_fx
w request-review --pr 1;  rc 14 "request-review: bots = [] has nobody to ask"
# ...and it prints NO verdict line: the head SHA is not known on that path (reading it would spend
# a call on a repo that just said nobody is coming), and stdout is contracted to be
# "<verdict> <sha>" or nothing — never a verdict with an empty second field.
wout request-review --pr 1
eq "$OUT" "" "request-review: bots = [] prints no verdict line rather than one with an empty SHA"
# ...and a KNOWN reviewer beside an unknown one is still asked.
reset_fx; declare_bots "[\"$CODEX\", \"some-other-reviewer\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: a known trigger beside an unknown reviewer still asks"

# The trigger table tolerates BOTH spellings of the same App, because GraphQL and REST disagree
# about the `[bot]` suffix and a table that knew only one would silently stop firing (#173/D79).
reset_fx; declare_bots "[\"${CODEX}[bot]\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: the '[bot]'-suffixed spelling resolves the same trigger"
reset_fx; declare_bots '["CHATGPT-Codex-Connector"]'; receipt_fx
w request-review --pr 1;  rc 0 "request-review: the trigger lookup is case-insensitive"

# --- EVERY UNREADABLE PATH REFUSES TO ASK -----------------------------------------------------
# The dangerous direction here is the OPPOSITE of the classifier's: an unprovable receipt must
# never read as "not yet asked", because that re-posts on every poll.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
STUB_GRAPHQL_FAIL=1 w request-review --pr 1; rc 20 "request-review: an unreadable read refuses to ask"; STUB_GRAPHQL_FAIL=0
STUB_FAIL_ACTIVITY=1 w request-review --pr 1
rc 20 "request-review: an unreadable ANCHOR refuses to ask — an undatable receipt is not 'no receipt'"
STUB_FAIL_ACTIVITY=0
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
activity_fx "$OLD_SHA" "refs/heads/$HEAD_REF" "$ARRIVED_AT"   # nothing puts THIS head on the ref
w request-review --pr 1;  rc 20 "request-review: an UNESTABLISHED anchor refuses to ask"
# THE RECEIPT CONNECTION IS TYPE-VALIDATED, exactly like the classification snapshot, and here the
# direction it protects is POSTING: `// 0` / `// []` would read a malformed read as "no comments",
# which reads as "nobody has asked" and posts again on every poll. Found by the independent review.
for broken in '{"comments":{"totalCount":0}}' '{"comments":{"totalCount":0,"nodes":{}}}' \
              '{"comments":null}' '{"comments":{"totalCount":-1,"nodes":[]}}'; do
  reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
  printf '%s\n' "$broken" > "$S/receipts-raw.json"
  w request-review --pr 1
  rc 20 "request-review: a broken receipt connection refuses to ask ($broken)"
  if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted on an unreadable receipt read ($broken)"; else ok; fi
  rm -f "$S/receipts-raw.json"
done
# A comment carrying no usable createdAt cannot be dated against the anchor, so it can be neither
# honoured as a receipt nor dismissed as absent.
reset_fx; declare_bots "[\"$CODEX\"]"
printf '%s\n' '{"comments":{"totalCount":1,"nodes":[{"body":"@codex review"}]}}' > "$S/receipts-raw.json"
w request-review --pr 1;  rc 20 "request-review: a receipt with no createdAt refuses to ask"
rm -f "$S/receipts-raw.json"
reset_fx; declare_bots "[\"$CODEX\"]"
printf '%s\n' '{"comments":{"totalCount":1,"nodes":[{"createdAt":"'"$AFTER_AT"'","body":null}]}}' > "$S/receipts-raw.json"
w request-review --pr 1;  rc 20 "request-review: a receipt with a null body refuses to ask"
if [ -f "$S/posted" ]; then bad "request-review: nothing may be posted over a receipt with no body"; else ok; fi
rm -f "$S/receipts-raw.json"

# More than 100 comments means the receipt cannot be proved absent -> refuse, never re-ask.
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
printf '101\n' > "$S/receipts-total.txt"
w request-review --pr 1;  rc 20 "request-review: a comment page it cannot see through refuses to ask"
rm -f "$S/receipts-total.txt"

# --- A DEAD PR IS NOT ASKED FOR A REVIEW ------------------------------------------------------
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
w request-review --pr 1;  rc 12 "request-review: a merged PR is not asked for a re-review"

# --- the declaration tri-state, and argument handling -----------------------------------------
reset_fx; undeclare; receipt_fx
w request-review --pr 1;  rc 17 "request-review: an UNDECLARED repo fails closed like every other read here"
reset_fx; printf '%s\n' '[reviewers]' 'bots = ["unterminated' > "$REPO/agents.toml"
w request-review --pr 1;  rc 18 "request-review: a malformed declaration is 18, not a guess"
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
w request-review;         rc 2  "request-review: --pr is required"
w request-review --pr 0;  rc 2  "request-review: a PR number of 0 is rejected"
w request-review --pr https://github.com/other/repo/pull/7
rc 2 "request-review: a URL naming ANOTHER repository is refused, before anything is posted"

# --- the mutation itself is bounded ------------------------------------------------------------
# One comment per DISTINCT phrase: two spellings of one App must not produce two comments.
reset_fx; declare_bots "[\"$CODEX\", \"${CODEX}[bot]\"]"; receipt_fx
w request-review --pr 1;  rc 0 "request-review: two spellings of one App still ask once"
eq "$(grep -c "requested a re-review" <<<"$OUT")" "1" "request-review: exactly one comment is posted"
reset_fx

fi

# ============================ 14. the head's CI (#448, D123) ============================
# These cases pin the four claims the head-CI read makes: the verdict is `branch-health`'s and is
# never green on doubt; observe/wait REPORT it on one stderr line without moving the reviewer's exit
# code or stdout;
# `ci-wait` returns a red at once and a green only once it has held; and a name from a workflow
# file reaches the summary only through the allowlist.
#

if check_block ci-read; then
# --- `ci`: the verdicts ------------------------------------------------------------------------
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
wout ci --pr 1;  rc 0 "ci: every check concluded success, every required context reported -> green (0)"
eq "$OUT" "green $HEAD_SHA" "ci: stdout is '<verdict> <sha>'"
w ci --pr 1
has "$OUT" "pr-watch: ci green $HEAD_SHA observed " "ci: the CI line names the verdict, the head and when"
has "$OUT" "1 check(s): 1 concluded, 0 running" "ci: the CI line counts the checks"
if called 'check-runs?filter=latest'; then ok; else bad "ci: check runs are read with filter=latest, so a re-run replaces its earlier attempt"; fi

# THE ISSUE'S OWN SHAPE (PR #446): everything green but one job that executed and failed.
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx "ci|completed|success" "pattern-ledger|completed|failure||7002"
ci_status_fx; ci_branch_fx ci pattern-ledger; ci_wfruns_fx "33184516415|7002|1" "33184516000|7001|1"
w ci --pr 1;  rc 40 "ci: a check that concluded failing -> not-green (40)"
has "$OUT" "failing: pattern-ledger [run 33184516415, attempt 1]" "ci: names the failing job and the run ci-health classifies"
wout ci --pr 1;  eq "$OUT" "not-green $HEAD_SHA" "ci: not-green stdout is '<verdict> <sha>'"

# A red with siblings still running is still red — and the line says how many are still running.
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx "slow|in_progress|" "lint|completed|failure"; ci_status_fx; ci_branch_fx slow lint
w ci --pr 1;  rc 40 "ci: a red beside a still-running sibling is not-green, not pending"
has "$OUT" "2 check(s): 1 concluded, 1 running" "ci: the running sibling is counted, not dropped"
has "$OUT" "lint [run ?]" "ci: a run that cannot be mapped is shown as unknown, never omitted"

# A failure no Actions run owns — another Checks app, or a commit status — is named as external.
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx "ci|completed|success" "deploy|completed|failure|vercel"
ci_status_fx "ci/circleci|failure"; ci_branch_fx ci
w ci --pr 1;  rc 40 "ci: an external failing check or status is not-green too"
has "$OUT" "deploy [external check]" "ci: a failing non-Actions check is named as external"
has "$OUT" "ci/circleci [external status]" "ci: a failing commit status is named as external"

# NOT CONCLUDED IS NOT GREEN, in each of the shapes `branch-health` answers `indeterminate` for.
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx "ci|in_progress|"; ci_status_fx; ci_branch_fx ci
w ci --pr 1;  rc 11 "ci: a running check -> indeterminate (11)"
has "$OUT" "still running" "ci: says the checks are still running"
wout ci --pr 1;  eq "$OUT" "indeterminate $HEAD_SHA" "ci: indeterminate stdout is '<verdict> <sha>'"
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx "other|completed|success"; ci_status_fx; ci_branch_fx ci
w ci --pr 1;  rc 11 "ci: a required context that has not reported is not green, however green the rest"
has "$OUT" "required context(s) have not reported" "ci: names the missing required context"
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 2
w ci --pr 1;  rc 11 "ci: an EMPTY check set on a repo with workflows is never green"
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx; ci_status_fx; ci_branch_fx --ruleset; ci_workflows_fx 0
w ci --pr 1;  rc 11 "ci: a base branch protected by something unreadable, with nothing reported, is not green"
reset_fx; declare_bots "[\"$CODEX\"]"
CI_SHA="$OLD_SHA" ci_runs_fx "ci|completed|success"; ci_status_fx; ci_branch_fx ci
w ci --pr 1;  rc 11 "ci: a check run describing another commit is stale evidence, not green"

# --- the declared absence of CI: the roadmap artifact, under its author-permission rule ---------
reset_fx; declare_bots "[\"$CODEX\"]"
ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 0
w ci --pr 1;  rc 11 "ci: no CI evidence and no declaration -> indeterminate, never no-ci"
ci_roadmap_fx $'Roadmap\n\n<!-- release-health: no-ci -->\n' "owner" "admin"
w ci --pr 1;  rc 41 "ci: no evidence anywhere and a declared release-health: no-ci -> no-ci (41)"
wout ci --pr 1;  eq "$OUT" "no-ci $HEAD_SHA" "ci: no-ci stdout is '<verdict> <sha>'"
ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "drive-by" "read"
w ci --pr 1;  rc 11 "ci: a no-ci marker from an author without write access is not honoured"
has "$OUT" "not write" "ci: says why the declaration was ignored"
ci_roadmap_fx $'<!-- release-health: skip-unreported -->\n' "owner" "admin"
w ci --pr 1;  rc 11 "ci: skip-unreported is never honoured for a pull request's head"
has "$OUT" "skip-unreported, which describes the default branch" "ci: says why skip-unreported does not apply"
# The declaration is consulted only when nothing could have reported: an Actions check run means
# the evidence answers, and the artifact is not even read.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "owner" "admin"
wout ci --pr 1;  rc 0 "ci: a declaration never overrules evidence that reported"
if called 'issues?labels=roadmap'; then bad "ci: the roadmap artifact is read only when nothing could have reported"; else ok; fi

# --- every unreadable read is 20, never a verdict ----------------------------------------------
reset_fx; declare_bots "[\"$CODEX\"]"
w ci --pr 1;  rc 20 "ci: no check-run document at all is unreadable, not 'no checks'"
has "$OUT" "pr-watch: ci unreadable $HEAD_SHA observed " "ci: an unreadable read is printed as unreadable"
ci_green_fx
STUB_FAIL_CHECKRUNS=1 w ci --pr 1;  rc 20 "ci: a failed check-runs read -> 20";  STUB_FAIL_CHECKRUNS=0
STUB_FAIL_CISTATUS=1 w ci --pr 1;   rc 20 "ci: a failed status read -> 20";      STUB_FAIL_CISTATUS=0
STUB_FAIL_BRANCH=1 w ci --pr 1;     rc 20 "ci: a failed base-branch read -> 20"; STUB_FAIL_BRANCH=0
printf '{"total_count":2,"check_runs":[{"id":1,"name":"ci","head_sha":"%s","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"check_suite":{"id":7001}}]}\n' "$HEAD_SHA" > "$S/checkruns.json"
w ci --pr 1;  rc 20 "ci: a check-run list shorter than its total_count is incomplete, not green"
ci_runs_fx "ci|completed|success"
CI_SHA="$OLD_SHA" ci_status_fx
w ci --pr 1;  rc 20 "ci: a status document for another commit is unreadable"
ci_status_fx; pr_fx --base-ref ""
w ci --pr 1;  rc 20 "ci: a pull request with no base branch cannot have its required checks read"
pr_fx; ci_runs_fx; ci_branch_fx --unprotected
STUB_FAIL_WORKFLOWS=1 w ci --pr 1;  rc 20 "ci: a failed workflow inventory, when it is needed, -> 20";  STUB_FAIL_WORKFLOWS=0
# A SHORT LIST IS NOT A COMPLETE ONE, on every surface the verdict counts. Each fixture below would
# read green, or `no-ci`, if its missing records were taken as absent.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
printf '{"sha":"%s","state":"pending","total_count":2,"statuses":[]}\n' "$HEAD_SHA" > "$S/cistatus.json"
w ci --pr 1;  rc 20 "ci: a status list shorter than its total_count is incomplete, not empty"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected
printf '{"total_count":2,"workflows":[]}\n' > "$S/workflows.json"
ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "owner" "admin"
w ci --pr 1;  rc 20 "ci: a workflow inventory shorter than its total_count is unreadable, never zero workflows"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected
printf '' > "$S/workflows.json"
w ci --pr 1;  rc 20 "ci: an EMPTY workflow inventory is unreadable, never zero workflows"
# A RECORD MISSING A FIELD ITS CONSUMERS READ is unreadable, never a thinner set: each fixture below
# reads green, or `no-ci`, if the bad record is taken at face value.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx --unprotected
# These two records are ones `check-facts` would ACCEPT — a named run, a string context — so the
# refusal they witness is this module's own: the fields IT reads (the id and suite it maps runs by;
# a context that names something).
printf '{"total_count":1,"check_runs":[{"name":"ci","head_sha":"%s","status":"completed","conclusion":"success","app":{"slug":"github-actions"}}]}\n' "$HEAD_SHA" > "$S/checkruns.json"
w ci --pr 1;  rc 20 "ci: a check run with no id or check suite is unreadable"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|completed|success"; ci_branch_fx --unprotected
printf '{"sha":"%s","state":"success","total_count":1,"statuses":[{"context":"","state":"success"}]}\n' "$HEAD_SHA" > "$S/cistatus.json"
w ci --pr 1;  rc 20 "ci: a status with an empty context is unreadable"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected
ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "owner" "admin"
printf '{"total_count":2,"workflows":[{"id":7,"state":"disabled_manually"},{"id":7,"state":"disabled_manually"}]}\n' > "$S/workflows.json"
w ci --pr 1;  rc 20 "ci: a workflow inventory that repeats an id is unreadable, never zero active workflows"
printf '{"total_count":1,"workflows":[{"id":7,"state":"paused_by_someone"}]}\n' > "$S/workflows.json"
w ci --pr 1;  rc 20 "ci: a workflow in a state this does not know is unreadable"
# A large check set with large outputs is read on STDIN: an argument-size limit must not turn it
# into an unreadable read. Twelve checks carrying ~200 KB of output each.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx --unprotected
jq -n -c --arg sha "$HEAD_SHA" '("x" * 200000) as $big
  | [range(12) | {id: ., name: "j\(.)", head_sha: $sha, status: "completed", conclusion: "success",
                  app: {slug: "github-actions"}, check_suite: {id: (500 + .)}, output: {text: $big}}]
  | {total_count: length, check_runs: .}' > "$S/checkruns.json"
w ci --pr 1;  rc 0 "ci: a large check set is read whole, not refused by an argument limit"
# ...and so is the reason `branch-health` gives for it, which names every check still running:
# 10,000 of them make a reason far past Linux's per-argument limit (MAX_ARG_STRLEN, 128 KiB).
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx --unprotected
jq -n -c --arg sha "$HEAD_SHA" '[range(10000) | {id: ., name: "job-number-\(.)", head_sha: $sha,
    status: "in_progress", conclusion: null, app: {slug: "github-actions"}, check_suite: {id: 900}}]
  | {total_count: length, check_runs: .}' > "$S/checkruns.json"
w ci --pr 1;  rc 11 "ci: a reason naming every running check is carried whole, not refused by an argument limit"

# EVERY OUTCOME CARRIES A CI LINE, so a summary always has one to paste — a closed pull request and
# an unreadable one included.
reset_fx; declare_bots "[\"$CODEX\"]"; pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
w ci --pr 1;  has "$OUT" "pr-watch: ci gone $HEAD_SHA observed " "ci: a closed pull request still prints its CI line"
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_GRAPHQL_FAIL=1 w ci --pr 1;  rc 20 "ci: an unreadable pull request is 20"
has "$OUT" "pr-watch: ci unreadable - observed " "ci: an unreadable pull request still prints its CI line"
STUB_GRAPHQL_FAIL=0
STUB_AUTH_FAIL=1 w ci --pr 1;  rc 20 "ci: an unauthenticated gh is 20"
has "$OUT" "pr-watch: ci unreadable - observed " "ci: an unauthenticated gh still prints its CI line"
STUB_AUTH_FAIL=0
w ci-wait --pr 1 --max-secs 08;  rc 2 "ci-wait: a leading-zero bound is refused, not read as octal"

# --- names reach the summary only through the allowlist ---------------------------------------
reset_fx; declare_bots "[\"$CODEX\"]"
jq -n -c --arg sha "$HEAD_SHA" '{total_count: 2, check_runs: [
    {id: 1, name: "test (ubuntu-latest, 3.11)", head_sha: $sha, status: "completed", conclusion: "failure", app: {slug: "github-actions"}, check_suite: {id: 7001}},
    {id: 2, name: "evil`x`\n<!-- adb:marker -->|[link](u)", head_sha: $sha, status: "completed", conclusion: "failure", app: {slug: "github-actions"}, check_suite: {id: 7001}}]}' \
  > "$S/checkruns.json"
ci_status_fx; ci_branch_fx --unprotected; ci_wfruns_fx "555|7001|2"
w ci --pr 1;  rc 40 "ci: the allowlist case is a red"
has "$OUT" "test (ubuntu-latest, 3.11) [run 555, attempt 2]" "ci: a matrix name with spaces, commas and parens is shown verbatim"
has "$OUT" "evil?x????-- adb:marker --???link?(u) [run 555, attempt 2]" "ci: a job name is rendered through the allowlist"
eq "$(printf '%s\n' "$OUT" | grep -c 'adb:marker')" "1" "ci: a newline in a job name cannot start a line of its own"

# --- `ci` is a read and nothing else -----------------------------------------------------------
reset_fx; undeclare; ci_green_fx
wout ci --pr 1;  rc 0 "ci: does not need [reviewers] bots — it asks no reviewer anything"
declare_bots "[\"$CODEX\"]"
reset_fx; pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"; ci_green_fx
wout ci --pr 1;  rc 12 "ci: a closed pull request has no CI left to watch"
eq "$OUT" "gone $HEAD_SHA" "ci: gone stdout is '<verdict> <sha>'"
w ci;                            rc 2 "ci: --pr is required"
w ci-wait --pr 1 --interval 0;   rc 2 "ci-wait: a zero interval would busy-wait"
w ci-wait --pr 1 --max-secs abc; rc 2 "ci-wait: a non-numeric bound is refused"
if [ -f "$S/posted" ]; then bad "ci: nothing was posted to the pull request"; else ok; fi

fi

if check_block ci-note; then
# --- observe / wait: the CI line rides the verdict and never moves it ---------------------------
# THE REVIEWER VERDICT IS IDENTICAL WITH AND WITHOUT THE CHECKS READ — each reviewer state under
# each CI state, against the same state with no CI fixture at all. A CI read that leaked into the
# reviewer's exit code or stdout fails here on the pairing that exposed it.
ci_state_fx() {
  case "$1" in
    green)   ci_green_fx ;;
    red)     ci_runs_fx "ci|completed|failure"; ci_status_fx; ci_branch_fx ci ;;
    running) ci_runs_fx "ci|in_progress|"; ci_status_fx; ci_branch_fx ci ;;
    nodecl)  ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 0 ;;
    noci)    ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 0
             ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "owner" "admin" ;;
    none)    : ;;
  esac
}
rev_state_fx() {
  case "$1" in
    clean)    reaction_fx "$CODEX" "+1" "$AFTER_AT" ;;
    findings) review_fx "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA" ;;
    pending)  : ;;
  esac
}
# The baseline is pinned to the reviewer's OWN code first: a defect in the shared path would move
# both sides of every comparison below together, and they would still agree.
for _rv in clean:0 findings:10 pending:11; do
  _want="${_rv#*:}"; _rv="${_rv%%:*}"
  reset_fx; declare_bots "[\"$CODEX\"]"; rev_state_fx "$_rv"
  wout observe --pr 1; _base_rc="$RC_"; _base_out="$OUT"
  eq "$_base_rc" "$_want" "observe: the reviewer exit code is unchanged by the CI read ($_rv, no CI fixture)"
  for _ci in green red running nodecl noci; do
    reset_fx; declare_bots "[\"$CODEX\"]"; rev_state_fx "$_rv"; ci_state_fx "$_ci"
    wout observe --pr 1
    eq "$RC_" "$_base_rc" "observe: the reviewer exit code is unchanged by the CI read ($_rv, CI $_ci)"
    eq "$OUT" "$_base_out" "observe: the reviewer stdout is unchanged by the CI read ($_rv, CI $_ci)"
  done
done
reset_fx; declare_bots "[\"$CODEX\"]"; reaction_fx "$CODEX" "+1" "$AFTER_AT"
ci_runs_fx "ci|completed|success" "pattern-ledger|completed|failure"; ci_status_fx; ci_branch_fx ci
w observe --pr 1;  rc 0 "observe: a clean reviewer over a red head is still the reviewer's 0"
has "$OUT" "pr-watch: ci not-green $HEAD_SHA observed " "observe: ...and the red is reported beside it"
has "$OUT" "failing: pattern-ledger" "observe: ...by name"
eq "$(cilines)" "1" "observe: exactly one CI line"
reset_fx; undeclare
w observe --pr 1;  rc 17 "observe: an undeclared reviewer set is still 17"
eq "$(cilines)" "0" "observe: a refusal carries no CI line — there is no verdict for it to ride"

# `wait` reports CI ONCE, on the verdict it returns — never per poll.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
printf '[]\n' > "$S/reviews.1.json"; printf '[]\n' > "$S/reviews.2.json"
_reviews_into "$S/reviews.3.json" "${CODEX}[bot]" "COMMENTED" "$HEAD_SHA"
w wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 10 "wait: the CI read does not change the verdict a later poll converges on"
eq "$(cilines)" "1" "wait: the CI line is printed once, on the verdict — not once per poll"
has "$OUT" "pr-watch: ci green $HEAD_SHA" "wait: the CI line describes the head of the returned verdict"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|completed|failure"; ci_status_fx; ci_branch_fx ci
w wait --pr 1 --interval 30 --max-secs 2;  rc 11 "wait: an expired bound is still the reviewer's 11 over a red head"
has "$OUT" "pr-watch: ci not-green $HEAD_SHA" "wait: the deadline handoff carries the CI line too"
# An expiry whose LAST poll was unreadable reports no head's CI — not the earlier poll's, which was
# green. Poll 2's PR read does not parse and finishes past the bound (6s against 4).
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx; printf '{ broken\n' > "$S/pr.2.json"; printf '6' > "$S/slow-2"
w wait --pr 1 --interval 1 --max-secs 4;  rc 11 "wait: an expiry after an unreadable poll is still the reviewer's 11"
eq "$(ci_lines_with 'pr-watch: ci green')" "0" "wait: an unreadable last poll never reports an earlier head's CI"
has "$OUT" "pr-watch: ci unreadable - observed " "wait: ...it reports the CI as unreadable"

fi

if check_block ci-wait; then
# --- ci-wait ------------------------------------------------------------------------------------
# Every case below ends on a FIXTURE, with `$WATCH_BACKSTOP` as the runaway bound (#394), except the
# two whose oracle is the deadline itself. Per-poll fixtures are keyed by the snapshot read count.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci
ci_runs_into "$S/checkruns.1.json" "ci|in_progress|"
ci_runs_fx "ci|completed|success"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "ci-wait: pending, then green that holds -> 0"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "ci-wait: green is reported only after it held across two polls"
eq "$(cilines)" "1" "ci-wait: quiet while it polls — one CI line, at the end"
wout ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  eq "$OUT" "green $HEAD_SHA" "ci-wait: stdout is the concluding '<verdict> <sha>'"

# Green over a check set that is still GROWING is not settled: poll 2 adds a late-registering job.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci
ci_runs_into "$S/checkruns.1.json" "ci|completed|success"
ci_runs_fx "ci|completed|success" "late|completed|success"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "ci-wait: the grown set settles once it holds"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "ci-wait: green must hold over an identical check set"

reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci; ci_wfruns_fx "777|7001|1"
ci_runs_into "$S/checkruns.1.json" "ci|in_progress|"
ci_runs_fx "ci|completed|failure"
# Poll 4 closes the PR, so a waiter that does NOT return the red ends on this fixture, not the backstop.
pr_poll_fx 4 --state closed --merged-at "2026-07-25T05:00:00Z"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 40 "ci-wait: a red arriving mid-wait returns not-green at once"
has "$OUT" "failing: ci [run 777, attempt 1]" "ci-wait: the red's line names the job and its run"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "2" "ci-wait: the red is returned on the poll that saw it"

# `--no-fail-fast` holds a red until nothing on the head is still running — the one case that needs
# it is a red whose run has not concluded, which `ci-health.sh` cannot classify yet.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx slow lint; ci_wfruns_fx "888|7001|1"
ci_runs_into "$S/checkruns.1.json" "slow|in_progress|" "lint|completed|failure"
ci_runs_fx "slow|completed|success" "lint|completed|failure"
pr_poll_fx 3 --state closed --merged-at "2026-07-25T05:00:00Z"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP" --no-fail-fast;  rc 40 "ci-wait --no-fail-fast: a red is held until nothing is still running"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "2" "ci-wait --no-fail-fast: returns on the poll where the last sibling concluded"
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx slow lint
ci_runs_fx "slow|in_progress|" "lint|completed|failure"
w ci-wait --pr 1 --interval 30 --max-secs 2 --no-fail-fast;  rc 40 "ci-wait --no-fail-fast: a held red is still a red when the bound runs out"
w ci --pr 1 --no-fail-fast;  rc 2 "ci: --no-fail-fast applies to ci-wait only"

reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|in_progress|"; ci_status_fx; ci_branch_fx ci
wout ci-wait --pr 1 --interval 30 --max-secs 2;  rc 11 "ci-wait: still running at the bound -> 11, never 0"
eq "$OUT" "indeterminate $HEAD_SHA" "ci-wait: the expired bound prints indeterminate"
w ci-wait --pr 1 --interval 30 --max-secs 2
has "$OUT" "this is not green" "ci-wait: the handoff says the expiry is not green"
# A green seen ONCE when the bound runs out has not settled, so it is not reported as green.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx; printf '3' > "$S/slow-1"
wout ci-wait --pr 1 --interval 30 --max-secs 1;  rc 11 "ci-wait: a bound that expires is never green, even over one green read"
eq "$OUT" "indeterminate $HEAD_SHA" "ci-wait: ...and its stdout does not say green"

# An expiry whose LAST poll was unreadable prints no head at all: the previous poll's head is not the
# one the line describes. Poll 2 reads a new head whose checks do not parse, and finishes past the
# bound (8s against 6), so the deadline lands on it.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_branch_fx ci; pr_poll_fx 1 --sha "$OLD_SHA"
CI_SHA="$OLD_SHA" ci_runs_into "$S/checkruns.1.json" "ci|in_progress|"
CI_SHA="$OLD_SHA" ci_status_into "$S/cistatus.1.json"
printf '{}\n' > "$S/checkruns.json"; ci_status_fx; printf '8' > "$S/slow-2"
wout ci-wait --pr 1 --interval 1 --max-secs 6;  rc 11 "ci-wait: an expiry after an unreadable poll is still 11"
eq "$OUT" "" "ci-wait: an expiry after an unreadable poll prints no head"

# The head moves under the wait: reported, and the old head's evidence counts for nothing.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_branch_fx ci
pr_poll_fx 1 --sha "$OLD_SHA"
CI_SHA="$OLD_SHA" ci_runs_into "$S/checkruns.1.json" "ci|completed|success"
CI_SHA="$OLD_SHA" ci_status_into "$S/cistatus.1.json"
ci_runs_fx "ci|completed|success"; ci_status_fx
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "ci-wait: a moved head settles on its own evidence"
has "$OUT" "head moved $OLD_SHA -> $HEAD_SHA" "ci-wait: reports that the head moved under it"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "ci-wait: the earlier head's green does not count toward the new head's"

reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|in_progress|"; ci_status_fx; ci_branch_fx ci
pr_poll_fx 2 --state closed --merged-at "2026-07-25T05:00:00Z"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 12 "ci-wait: a pull request that closes mid-wait stops it"
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_CHECKRUNS=1 w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 20 "ci-wait: gives up after consecutive unreadable polls"
has "$OUT" "consecutive unreadable CI polls" "ci-wait: names why it gave up"
STUB_FAIL_CHECKRUNS=0
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 0
ci_roadmap_fx $'<!-- release-health: no-ci -->\n' "owner" "write"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 41 "ci-wait: a declared no-ci repo has nothing to wait for"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "1" "ci-wait: ...and says so on the first poll"

# A green that settles only AFTER the bound is not accepted: poll 2 is slow enough to finish late.
# Poll 2 costs 12s against a 10s bound: it settles late, and poll 1 has nine seconds of slack under
# load before it could eat the bound itself.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx; printf '12' > "$S/slow-2"
w ci-wait --pr 1 --interval 1 --max-secs 10;  rc 11 "ci-wait: a green that settles only after the bound is not accepted"
# ...and the case only means something if poll 2 actually ran; a loaded first poll that eats the
# bound would make both the code and its mutant return 11 without ever settling.
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "2" "ci-wait: the late-settling green was reached on poll 2"
# ...and the expired bound's CI line, which callers paste as the CI state, does not say green either.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx; printf '3' > "$S/slow-1"
w ci-wait --pr 1 --interval 30 --max-secs 1
eq "$(ci_lines_with 'pr-watch: ci green')" "0" "ci-wait: the expired bound's CI line does not say green"
has "$OUT" "not settled before the bound" "ci-wait: ...it says the green was not settled"

# The declaration's reason rides the ONE CI line — not a stderr line per poll — and passes the same
# allowlist as a job name, since it echoes issue-body text.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx; ci_status_fx; ci_branch_fx --unprotected; ci_workflows_fx 0
ci_roadmap_fx $'<!-- release-health: [click](https://example.com) & <x -->\n' "owner" "admin"
w ci-wait --pr 1 --interval 1 --max-secs 3
eq "$(ci_lines_with 'roadmap #31')" "1" "ci-wait: the declaration reason rides the one CI line"
hasnt "$OUT" "<x" "ci-wait: the declaration reason is markup-neutralized"
# An unreadable poll is an EVENT, and its CI line is printed once, when the wait ends.
reset_fx; declare_bots "[\"$CODEX\"]"
STUB_FAIL_CHECKRUNS=1 w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  STUB_FAIL_CHECKRUNS=0
eq "$(ci_lines_with 'pr-watch: ci unreadable')" "1" "ci-wait: an unreadable poll's CI line is printed once, at the end"

# `--no-fail-fast` also holds a red whose workflow run has not concluded — every check can read
# concluded while the run is still finishing, and `ci-health` would answer 25.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci lint
ci_runs_fx "ci|completed|success" "lint|completed|failure"
ci_wfruns_into "$S/wfruns.1.json" "999|7001|2|in_progress"
ci_wfruns_fx "999|7001|2"
pr_poll_fx 3 --state closed --merged-at "2026-07-25T05:00:00Z"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP" --no-fail-fast;  rc 40 "ci-wait --no-fail-fast: a red is held while its run has not concluded"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "2" "ci-wait --no-fail-fast: returns once the red's run concluded"

# A red whose run CANNOT BE FOUND is unsettled too: nothing can say that run concluded, so
# `--no-fail-fast` holds it to the bound rather than releasing it early.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci
ci_runs_fx "ci|completed|failure"
w ci-wait --pr 1 --interval 1 --max-secs 2 --no-fail-fast;  rc 40 "ci-wait --no-fail-fast: a red whose run cannot be found is still a red at the bound"
has "$OUT" "while the red was still unsettled" "ci-wait --no-fail-fast: a red whose run cannot be found is held, not released"
# A run map naming one check suite twice cannot say which record is that run, so the run is
# unknown — held — never whichever record happens to come first.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci
ci_runs_fx "ci|completed|failure"; ci_wfruns_fx "999|7001|1" "999|7001|1|in_progress"
w ci-wait --pr 1 --interval 1 --max-secs 2 --no-fail-fast
has "$OUT" "while the red was still unsettled" "ci-wait --no-fail-fast: a run map naming one suite twice is unknown, not its first record"
# An INTERRUPTED wait still prints its CI line — never green, naming the last poll's head — because the
# summary that pastes it has nothing else to paste. `exec` makes the background pid the waiter itself.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|in_progress|"; ci_status_fx; ci_branch_fx ci
( cd "$REPO" && exec env HOME="$GHOME" PATH="$SBIN:$PATH" S="$S" bash "$PW" ci-wait --pr 1 --interval 30 --max-secs "$WATCH_BACKSTOP" ) > "$work/int.out" 2>&1 &
_ip=$!
_iw=0; until [ -s "$S/slept" ] || [ "$_iw" -ge 60 ]; do /bin/sleep 1; _iw=$((_iw + 1)); done
kill -TERM "$_ip" 2>/dev/null; wait "$_ip"; _irc=$?
eq "$_irc" "11" "ci-wait: an interrupted wait exits 11"
has "$(cat "$work/int.out")" "pr-watch: ci indeterminate $HEAD_SHA observed " "ci-wait: an interrupted wait still prints its CI line"

# The wait carries each poll in shell variables, never a temp file: one it cannot create changes nothing.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
TMPDIR="$work/no-such-dir" w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP"
rc 0 "ci-wait: needs no temp file to settle a green"

# A check REPLACED under the same name — a re-run, or another app — is a new check set, so its first
# green does not settle the wait.
reset_fx; declare_bots "[\"$CODEX\"]"; ci_status_fx; ci_branch_fx ci
CI_ID_BASE=100 ci_runs_into "$S/checkruns.1.json" "ci|completed|success"
ci_runs_fx "ci|completed|success"
w ci-wait --pr 1 --interval 1 --max-secs "$WATCH_BACKSTOP";  rc 0 "ci-wait: the replaced check settles once it holds"
eq "$( [ -f "$S/polls" ] && cat "$S/polls" || echo 0 )" "3" "ci-wait: a check replaced under the same name is a new check set"
reset_fx

fi

# ============================ the output contract (#437) ============================
if check_block contract legacy; then
# The header's Outputs: at most ONE stdout line, `<verdict> <head-sha>`, and none on a refusal.
# Compared as BYTES — a `$( )` capture would accept a trailing blank line or a missing newline.
# contract_is <want-rc> <want-stdout-line|''> <label> <subcommand…>
contract_is() {
  local want_rc="$1" want="$2" label="$3"; shift 3
  _w "$@" > "$work/contract.out" 2>/dev/null; RC_=$?
  rc "$want_rc" "$label (exit code)"
  if [ -n "$want" ]; then printf '%s\n' "$want" > "$work/contract.want"; else : > "$work/contract.want"; fi
  if cmp -s "$work/contract.out" "$work/contract.want"; then ok; else bad "$label: stdout is not exactly that line"; fi
}
reset_fx; declare_bots "[\"$CODEX\"]"
contract_is 11 "pending $HEAD_SHA" "contract: observe's pending stdout is '<verdict> <sha>'" observe --pr 1
reset_fx; declare_bots "[\"$CODEX\"]"; pr_fx --state closed --merged-at "2026-07-25T05:00:00Z"
contract_is 12 "gone $HEAD_SHA" "contract: observe's gone stdout is '<verdict> <sha>'" observe --pr 1
reset_fx; undeclare
contract_is 17 "" "contract: a refusal prints nothing on stdout, not even a newline" observe --pr 1
reset_fx; declare_bots "[\"$CODEX\"]"; receipt_fx
contract_is 0 "requested $HEAD_SHA" "contract: request-review's stdout is '<word> <sha>'" request-review --pr 1
reset_fx; declare_bots "[\"$CODEX\"]"; ci_green_fx
contract_is 0 "green $HEAD_SHA" "contract: ci's stdout is '<verdict> <sha>'" ci --pr 1
reset_fx; declare_bots "[\"$CODEX\"]"
contract_is 20 "" "contract: an unreadable ci read prints nothing on stdout" ci --pr 1
reset_fx; declare_bots "[\"$CODEX\"]"; ci_runs_fx "ci|completed|failure"; ci_status_fx; ci_branch_fx ci
contract_is 11 "pending $HEAD_SHA" "contract: observe's stdout stays one reviewer line over a red head" observe --pr 1
reset_fx
fi
check_blocks_done

check_summary "pr-watch"
