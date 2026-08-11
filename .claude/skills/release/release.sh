#!/usr/bin/env bash
# ai-dev-baseline — THIS PROJECT'S release DRIVER (decision D14; narrative: ./SKILL.md).
#
# WHY THIS IS A SCRIPT AND NOT PROSE
#
# The release procedure lived in SKILL.md as fenced shell for three review rounds and produced 27
# defects — 10, then 7, then 10 — and the third round's were mostly REGRESSIONS introduced while
# fixing the second. The reviewer twice said the same thing: "place the entire procedure in one
# executable script."
#
# The reason prose kept failing is not carelessness, it is that a Markdown block is a program no
# tool can run: shellcheck never sees it, the tests never execute it, and the shell-session
# contract is invisible (this repo has TWO opposite ones — roadmap.md's blocks share nothing,
# cleanup.md's share everything). Every class of defect found in round 3 is impossible here:
# positional arguments are real arguments, cross-step values are real state, `sort -V` is caught by
# running it, and every path is exercised by scripts/check-release-skill.sh.
#
# SKILL.md is now the narrative — what each step means and why — and this file is what runs.
#
# It is NOT in scripts/lib/: `adb_agent_manifest` (common.sh) links that whole directory into every
# install, and #3/D7 says the baseline ships no generic release machinery. This encodes THIS repo's
# scheme (Keep a Changelog, vX.Y.Z tags, this repo's compare-link shape), so it lives beside the
# skill that owns it.
#
# Decisions are delegated, never re-derived:
#   readiness/health   -> scripts/lib/roadmap-lib.sh (release-ready, release-counts, branch-health,
#                                                     marker-title)
#   version + stamp    -> ./release-lib.sh (version-ok, changelog-verify, unreleased-entries,
#                                           checks-settled)
#   reviewer status    -> scripts/lib/pr-watch.sh
#   version ordering   -> adb_version_ge (scripts/lib/common.sh)
#   milestone rollover -> bin/baseline release roll
#
# Usage:
#   release.sh preflight
#   release.sh readiness
#   release.sh inventory
#   release.sh version-guard <vX.Y.Z>
#   release.sh roll-preflight
#   release.sh stamp-verify
#   release.sh record-pr <number>
#   release.sh await-review
#   release.sh merge
#   release.sh verify-merge
#   release.sh tag --message-file <path>
#   release.sh roll
#   release.sh state          # dump the run state
#
# Exit codes: 0 ok · 1 refused (reason on stderr) · 2 usage · 3 RESUME (see version-guard)

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || { printf 'release: not inside a git repo\n' >&2; exit 1; }
LIB="$ROOT/scripts/lib"
RLIB="$SELF_DIR/release-lib.sh"
RS="$ROOT/.claude/state/release-run.env"

# bash 5.3 runtime floor (#256) — the bootstrap sits here, immediately after the four path
# assignments it needs and AHEAD of every function definition below.
#
# Bash parses a function's body when it reaches the definition, so once #258/#259 put 5.3-only
# grammar into any function further down, a 3.2 interpreter would fail to PARSE this file before
# reaching the gate meant to rescue it. A gate placed among the definitions it protects is a gate
# that arrives too late. Caught by independent review; the same fix is in release-lib.sh.
# shellcheck source=/dev/null
. "$LIB/common.sh"
adb_require_bash "$@"

die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; }
say()  { printf '%s\n' "$*"; }

# --- run state ----------------------------------------------------------------------------------
# Cross-step values live here, not in shell variables: this is what makes an interrupted release
# resumable, and what removes the "which block defined $VERSION" question entirely.
rs()   { [ -f "$RS" ] && grep "^$1=" "$RS" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
rset() { mkdir -p "$(dirname "$RS")"; printf '%s=%s\n' "$1" "$2" >> "$RS"; }

# need <dest-var> <key> <hint> — read a cross-step value, or STOP THE SCRIPT.
#
# IT WRITES THROUGH A NAMEREF INSTEAD OF PRINTING, AND THAT IS THE WHOLE POINT (#313).
#
# It used to print its value, so every one of its eleven call sites captured it with a command
# substitution — schematically `x="$(need KEY hint)"`, over six different destinations (`v`, `pr`,
# `sha`, `msha`, `exp`, `pinned_m`) — and a command substitution is a SUBSHELL. `die`'s `exit 1`
# left only that subshell: the message went to stderr, the assignment took the EMPTY STRING, and
# the step carried on as though the value were there. A guard whose failure mode is "print a line
# and continue" is worse than no guard, because every caller downstream then runs on empty inputs.
#
# Measured, cutting v2.1.0: `await-review` exited 10 and the PR was merged from the web UI, so
# neither EXPECTED_CHECKS nor MERGE_SHA was ever recorded. `verify-merge` did not stop. Both values
# came back empty, `await_checks "" ""` polled `repos/<slug>/commits//check-runs` 90 times at 10s
# intervals, and reported "never reached a settled set of >= " after FIFTEEN MINUTES. The real
# cause — you skipped a step — had been printed to stderr in the first 20ms and buried. That is the
# same shape `slug()`'s header documents from #218, reached by a different route.
#
# Called as a PLAIN COMMAND, `die` runs in the caller's own shell and `exit 1` ends the run. The
# nameref is what makes that possible: the value has to reach the caller some way other than
# stdout, because stdout is what forced the subshell.
#
# `_need_dest`, not `v`: a nameref whose own name equals its target is a CIRCULAR REFERENCE and
# bash refuses it, so a call site legitimately named `v` (four of them are) would break. And the
# non-empty test reads the NAMEREF rather than `$2`'s value a second time — one read, one subject,
# and no SC2034 for a variable that would otherwise only ever be assigned.
#
# That leaves `_need_dest` itself as the one destination name this helper cannot serve, so it is
# REFUSED BY NAME rather than left as a trap: passed anyway, bash warns about the circular
# reference and the run dies on an unbound variable under `set -u` — a confusing failure in place
# of the controlled one this function exists to give.
#
# Callers declare their destination `local`, which is not decoration: ShellCheck cannot see through
# a nameref, so an undeclared destination is "referenced but not assigned". Measured with the seven
# declarations removed: 4 SC2154 diagnostics, over `pr`, `exp`, `pinned_m` and `pinned_ms`. `v`,
# `sha` and `msha` escape only because some OTHER function in this file happens to assign those
# names — an accident of naming, not a property to build on, which is why all seven are declared.
need() {
  [ "$1" != "_need_dest" ] || die "need: '_need_dest' is this helper's own nameref and cannot be a destination"
  local -n _need_dest="$1"
  _need_dest="$(rs "$2")"
  [ -n "$_need_dest" ] || die "$2 not recorded yet — $3"
}

have_gh() { command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"; command -v gh >/dev/null 2>&1; }
# A THIRD PRODUCER of the same API-supplied value (#218), and the one a sweep of `scripts/lib`
# misses because this file lives outside it. Every consumer below concatenates the result into a
# `repos/<slug>/...` request path, so the shape test is not enough — `a/..` is a well-formed
# owner/repo pair AND a path traversal. This file already sources common.sh, so the predicate and
# the renderer both come from their one home rather than being restated here.
#
# Fails CLOSED: non-zero with empty output, and EVERY consumer below checks that rather than
# inheriting it. An unchecked empty slug builds `repos//…`, which is safe in the traversal sense —
# nothing escapes — but it is not harmless: inside `await_checks`'s retry loop it polled an
# unanswerable path 90 times over fifteen minutes and reported a timeout, hiding the real cause.
#
# "Every consumer" is the load-bearing word, and the first cut of this did not have it: the sweep
# and its structural test covered only `sl="$(slug)"` ASSIGNMENTS and silently missed the inline
# `$(slug)` interpolated straight into a request. The check now matches any use.
slug() {
  local s
  s="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || return 1
  adb_is_path_safe_repo_slug "$s" || {
    printf 'release: gh reported a malformed repository slug (%s) — refusing to build a request path from it\n' \
      "$(adb_display_value "$s")" >&2
    return 1
  }
  printf '%s' "$s"
}
defbr()   { gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null; }

# --- portable version max -------------------------------------------------------------------------
# NOT `sort -V`: BSD sort (stock macOS, which CLAUDE.md Golden Rule 4 requires this repo support)
# has no -V, and inside a command substitution without pipefail the failure is masked by `tail`,
# leaving the result EMPTY. An empty previous-version then reads as "first release" and blesses a
# `releases/tag/` changelog link on a repo that already has tags. Uses the shared comparator.
version_max() {   # bare versions on stdin -> highest, bare
  best=""
  while IFS= read -r v; do
    v="${v#v}"; [ -n "$v" ] || continue
    if [ -z "$best" ] || adb_version_ge "$v" "$best"; then best="$v"; fi
  done
  printf '%s' "$best"
}

# --- the version inventory ------------------------------------------------------------------------
# ONE source for both the reuse guard and the previous-version. Local tags, remote tags, and
# changelog headings: a version present in ANY of them has been used.
inventory() {
  { git -C "$ROOT" tag --list 'v*'
    git -C "$ROOT" ls-remote --tags origin 2>/dev/null | sed 's@.*refs/tags/@@; s/\^{}$//'
    grep -o '^## \[[0-9][0-9.]*\]' "$ROOT/CHANGELOG.md" 2>/dev/null | tr -d '#[] '
  } | sed 's/^v//; /^$/d' | sort -u
}

# --- check-set settling ---------------------------------------------------------------------------
# GitHub registers jobs INCREMENTALLY, so "nothing is pending" is briefly true while siblings have
# not appeared. A fixed expected-count cannot be known up front either — that was the round-3 bug
# (`checks-settled 1` recorded a partial set as the bar). So settle on STABILITY: the predicate
# reports `settled`, and the count is unchanged across consecutive reads.
#
# THE VERDICT IS THE LIBRARY'S, NOT THIS LOOP'S. This function used to re-derive `total` and
# `pending` with its own inline jq — a second implementation of `release-lib.sh checks-settled`,
# living two files away from the tested one and drifting from it silently. It did drift: the
# library learned to count DISTINCT NAMES (see its header) and this copy would have kept counting
# raw runs, so the two would have disagreed about the same commit with nothing to notice. This loop
# now owns only the WAITING; what counts as settled has exactly one home.
# Prints the settled count. Args: <sha> [min-expected]
await_checks() {
  sha="$1"; min="${2:-0}"
  # RESOLVED ONCE, AND CHECKED, BEFORE THE LOOP (#218 review). Inline `$(slug)` inside the loop
  # discarded its status: a rejected or unresolvable slug became an EMPTY one, the request became
  # `repos//commits/...`, and the `|| { sleep 10; continue; }` arm then retried that 90 times —
  # fifteen minutes of polling a path that can never answer, reported as a timeout. `ac_sl`, not
  # `sl`, because `sl` is a de-facto global that health_of / cmd_readiness / cmd_roll also use.
  ac_sl="$(slug)" || return 1
  [ -n "$ac_sl" ] || return 1
  stable=0; last=-1; i=0
  while [ "$i" -lt 90 ]; do
    ck="$(gh api --paginate "repos/$ac_sl/commits/$sha/check-runs?per_page=100" 2>/dev/null)" || { sleep 10; i=$((i+1)); continue; }
    out="$(printf '%s' "$ck" | bash "$RLIB" checks-settled "$min" 2>/dev/null)"; rc=$?
    case "$rc" in
      0)
        # `settled <count>/<expected>` — field 2's numerator is the settled count.
        n="${out#* }"; n="${n%%/*}"
        case "$n" in ''|*[!0-9]*) n=-1 ;; esac
        if [ "$n" -ge 0 ] && [ "$n" -eq "$last" ]; then
          stable=$((stable + 1))
          [ "$stable" -ge 3 ] && { printf '%s' "$n"; return 0; }
        else
          stable=1
        fi
        last="$n"
        ;;
      2)
        # Usage/unreadable-JSON: a malformed body is an ERROR, never "not settled yet". Retrying
        # for 15 minutes against a body that cannot parse would report a timeout and hide the cause.
        return 1
        ;;
      *)
        # none (7) · short (8) · pending (6) — all legitimately "keep waiting", and all reset the
        # stability run so a set that shrinks and re-grows is not mistaken for a stable one.
        stable=0; last=-1
        ;;
    esac
    sleep 10; i=$((i+1))
  done
  return 1
}

# --- branch health --------------------------------------------------------------------------------
# The workflow inventory is consulted whenever GitHub Actions has NOT reported on this commit —
# exactly as step 2 does. Hardcoding 0 tells branch-health "this repo has no CI", so a commit with
# enough non-Actions checks would read `green` instead of the intended `indeterminate`.
#
# THE SECOND EXISTENCE PROBE IS READ HERE TOO (#115). `branch-health` now takes the branch's
# required status contexts alongside the Actions inventory, and passing a hardcoded `null` would
# have been cheaper — but this driver and /roadmap must never disagree about the same commit, and
# `null` is the fail-closed "could not read" value, not "this driver did not look". So it makes the
# same read from the same endpoint. The contexts belong to the DEFAULT BRANCH: this function is
# also called on a merge commit, and required checks are a property of the branch, not of a sha.
#
# THE APP SLUG COMES FROM ITS ONE HOME. This file already sources common.sh, so the literal that
# used to sit in the jq filter here — a fourth copy of `github-actions`, kept in sync by nothing at
# all — is now `adb_actions_app_slug` passed as a typed --arg (#179, #183).
health_of() {   # <sha> -> prints the verdict word
  # `dbr`, not `d`: this file scopes nothing, and `cmd_preflight` already uses `d` for the default
  # branch. Reusing it here would have `health_of` reach back into a caller's variable — harmless
  # today only because no current caller reads `d` afterwards, which is not a property to rely on.
  sha="$1"; sl="$(slug)" || return 1; dbr="$(defbr)"
  [ -n "$sl" ] || return 1
  case "$dbr" in ''|null) return 1 ;; esac
  st="$(gh api --paginate "repos/$sl/commits/$sha/status?per_page=100")" || return 1
  ck="$(gh api --paginate "repos/$sl/commits/$sha/check-runs?per_page=100")" || return 1
  # The ref is ENCODED into its path segment, never interpolated raw (#103, D53). This repo's
  # default branch is `main`, so today the encoding is a no-op — but git permits `#`, `%` and `/`
  # in a ref, a raw `#` truncates the request at a URI fragment, and this file is the template
  # every adopting repo copies for its own `/release` (D14). `common.sh` is already sourced above,
  # so this is the shared primitive, not a second spelling of it.
  bpath="$(adb_url_path_segment "$dbr")" || return 1
  brj="$(gh api "repos/$sl/branches/$bpath")" || return 1
  req="$(printf '%s' "$brj" | bash "$LIB/repo-settings.sh" branch-required-contexts)" || return 1
  hin="$(printf '%s\n%s\n' "$ck" "$st" \
    | jq -s -c --argjson req "$req" \
        '{check_runs: ([.[].check_runs // []] | add // []), statuses: ([.[].statuses // []] | add // []),
          required_contexts: $req}')" || return 1
  wf=0
  if [ "$(printf '%s' "$hin" | jq --arg aslug "$(adb_actions_app_slug)" \
            '[.check_runs[] | select((.app.slug // "") == $aslug)] | length')" = "0" ]; then
    wfj="$(gh api --paginate "repos/$sl/actions/workflows?per_page=100")" || return 1
    wf="$(printf '%s' "$wfj" | jq -s '[.[].workflows[]? | select(.state == "active")] | length')" || return 1
  fi
  # `0` — this driver NEVER takes the owner opt-out, and that is a deliberate, stricter policy than
  # /roadmap's, not an oversight. /roadmap decides whether to EMIT a cut; this decides whether to
  # TAG one, having just watched the merge commit's checks settle. `release-health:
  # skip-unreported` says "CI does not report on the default branch" — a repo in that state cannot
  # give this driver the evidence `verify-merge` is built on, so it needs its own release skill
  # (D14 already says every adopting repo owes itself one) rather than a hatch that lets THIS one
  # tag an unverified commit.
  printf '%s' "$hin" | bash "$LIB/roadmap-lib.sh" branch-health "$sha" "$wf" 0 | sed -n '1p'
}

# --- role guard -------------------------------------------------------------------------------------
# `[roles].release` names WHO cuts the release. A release skill that ignores it is the silent-ignore
# docs/roles-and-agents.md warns about — the manifest entry would look effective and do nothing.
# Dropped by accident in one rewrite; it is a subcommand now so it cannot be lost in prose again.
assert_role() {
  rd="$LIB/role-dispatch.sh"
  [ -f "$rd" ] || die "$rd missing — cannot resolve [roles].release; refusing to release"
  agent="$(bash "$rd" resolve release)" || exit 1
  [ "$agent" = "claude" ] || die "[roles].release = '$agent', not claude. Run the release from '$agent', or change agents.toml."
}

# =================================================================================================
cmd_preflight() {
  have_gh || die "gh not found"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  [ -f "$LIB/roadmap-lib.sh" ] || die "$LIB/roadmap-lib.sh missing — wrong repo?"
  assert_role
  # --tags is REQUIRED: a clone with remote.origin.tagOpt=--no-tags fetches none, so the local tag
  # list is empty while the remote has releases.
  git -C "$ROOT" fetch --prune --tags origin >/dev/null 2>&1 || die "fetch failed"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "worktree is dirty — commit or stash first"
  d="$(defbr)"; case "$d" in ''|null) die "cannot resolve the default branch" ;; esac
  git -C "$ROOT" checkout "$d" >/dev/null 2>&1 || die "cannot check out $d"
  git -C "$ROOT" merge --ff-only "origin/$d" >/dev/null 2>&1 || die "local $d is not fast-forwardable"
  # EQUALITY, not just fast-forwardable: --ff-only succeeds with "Already up to date" when local is
  # AHEAD, so unpushed commits would ride into the release branch.
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "origin/$d")" ] \
    || die "local $d is ahead of origin/$d — push or drop those commits first"
  pf_sl="$(slug)" || die "cannot resolve this repo's slug"
  say "preflight ok: $pf_sl on $d at $(git -C "$ROOT" rev-parse --short HEAD)"
}

cmd_readiness() {
  have_gh || die "gh not found"
  sl="$(slug)" || die "cannot resolve this repo's slug"
  d="$(defbr)"; rm_lib="$LIB/roadmap-lib.sh"
  list="$(gh issue list --label roadmap --state open --limit 50 --json number --jq '.[].number')"
  n="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || die "expected exactly 1 open roadmap-labelled issue, found $n — split brain"
  rnum="$(printf '%s\n' "$list" | sed '/^$/d' | head -n1)"
  body="$(gh issue view "$rnum" --json body --jq .body)" || die "cannot read roadmap #$rnum"
  titles="$(printf '%s' "$body" | bash "$rm_lib" marker-title)" || die "marker-title failed"
  nt="$(printf '%s\n' "$titles" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$nt" = "1" ] || die "roadmap #$rnum declares $nt release-milestone titles — need exactly 1"
  ms="$(printf '%s\n' "$titles" | sed '/^$/d' | head -n1)"
  msj="$(gh api --paginate "repos/$sl/milestones?state=open&per_page=100")" || die "could not list milestones"
  mnum="$(printf '%s' "$msj" | jq -r -s --arg t "$ms" '[.[][] | select(.title == $t) | .number] | first // empty')"
  [ -n "$mnum" ] || die "release-milestone '$ms' matched no open milestone"

  # PIN on first run; VERIFY on every later one. A re-check that resolved a DIFFERENT milestone
  # could authorise the tag while the changelog was stamped for the original release set.
  pr_="$(rs ROADMAP_NUM)"
  if [ -n "$pr_" ]; then
    [ "$pr_" = "$rnum" ] && [ "$(rs M_NUM)" = "$mnum" ] && [ "$(rs MS_NAME)" = "$ms" ] \
      || die "release set moved — pinned #$pr_/'$(rs MS_NAME)'(#$(rs M_NUM)), now #$rnum/'$ms'(#$mnum)"
  fi

  le=0; gh api "repos/$sl/labels/release-blocker" >/dev/null 2>&1 && le=1
  mi="$(gh api --paginate "repos/$sl/issues?milestone=$mnum&state=all&per_page=100")" || die "could not read milestone $mnum"
  counts="$(printf '%s' "$mi" | bash "$rm_lib" release-counts release-blocker "$rnum")" || die "could not tabulate milestone $mnum"
  read -r armed blockers open_ canceled <<EOF
$(printf '%s\n' "$counts" | sed -n '1p')
EOF
  verdict="$(bash "$rm_lib" release-ready "$le" "$armed" "$blockers" "$open_" "$canceled" skipped)" || die "readiness predicate failed"
  health=skipped
  if [ "$verdict" = "met" ]; then
    # Encoded, for the reason in `health_of` (#103). The sibling `commits/$sha/...` reads are left
    # alone deliberately: their ref is a hex SHA, which is unreserved end to end.
    dpath="$(adb_url_path_segment "$d")" || die "cannot encode '$d' into a request path"
    head_sha="$(gh api "repos/$sl/commits/$dpath" --jq .sha)" || die "cannot resolve $d HEAD"
    health="$(health_of "$head_sha")" || die "branch-health failed — an unreadable build is never green"
    verdict="$(bash "$rm_lib" release-ready "$le" "$armed" "$blockers" "$open_" "$canceled" "$health")" || die "readiness predicate failed"
  fi
  say "readiness: $verdict (milestone '$ms' #$mnum, health=$health)"
  [ "$verdict" = "met" ] || die "not releasable — $verdict"
  if [ -z "$pr_" ]; then rset ROADMAP_NUM "$rnum"; rset M_NUM "$mnum"; rset MS_NAME "$ms"; fi
}

cmd_inventory() {
  inventory | sed 's/^/known: /'
  last="$(inventory | version_max)"
  [ -n "$last" ] && say "previous: v$last" || say "previous: <none>"
  sed -n '/^## \[Unreleased\]/,/^## \[/p' "$ROOT/CHANGELOG.md" | grep '^### ' | sort -u || true
}

cmd_version_guard() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  v="$1"
  bash "$RLIB" unreleased-entries < "$ROOT/CHANGELOG.md" >/dev/null \
    || die "[Unreleased] has no entries — there is nothing to release"
  last="$(inventory | version_max)"; [ -n "$last" ] && last="v$last"
  # RESUME: a previous run may hold the tag locally after a failed push. That tag is in the
  # inventory, so version-ok would reject the version as used and the documented retry could never
  # work. Detect exactly that and route to `tag`.
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1 \
     && [ -z "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$v")" ]; then
    rset VERSION "$v"; rset LAST "$last"
    say "RESUME: $v exists locally but not on origin — run: release.sh tag --message-file <path>"
    exit 3
  fi
  inventory | bash "$RLIB" version-ok "$v" >/dev/null || exit 1
  rset VERSION "$v"; rset LAST "$last"
  say "version ok: $v (previous: ${last:-<none>})"
}

cmd_roll_preflight() {
  local v
  need v VERSION 'run version-guard first'
  bash "$ROOT/bin/baseline" release roll --version "$v" --dry-run \
    || die "the rollover would fail — fix it BEFORE cutting, not after"
}

cmd_stamp_verify() {
  local v
  need v VERSION 'run version-guard first'
  sv_sl="$(slug)" || die "cannot resolve this repo's slug"
  bash "$RLIB" changelog-verify "$v" "$(rs LAST)" "$sv_sl" "$(date +%F)" < "$ROOT/CHANGELOG.md" \
    || die "changelog stamp is wrong (reasons above)"
  say "changelog stamp verified for $v"
}

cmd_record_pr() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  case "$1" in ''|*[!0-9]*) die "PR must be a number" ;; esac
  rset PR "$1"; say "recorded PR #$1"
}

cmd_await_review() {
  local pr
  have_gh || die "gh not found"
  need pr PR 'run record-pr first'
  out="$(bash "$LIB/pr-watch.sh" wait --pr "$pr" --interval 30 --max-secs 1800)"; rc=$?
  sha="$(printf '%s\n' "$out" | tail -n1 | awk '{print $2}')"
  case "$rc" in
    0) [ -n "$sha" ] || die "clean pass but no head SHA printed" ;;
    10) die "reviewer found issues — run /resolve-pr-threads, then re-run" ;;
    11) die "reviewer still pending at the bound — hand off to a human" ;;
    *)  die "reviewer state unreadable (rc=$rc) — never merge on an unknown" ;;
  esac
  # Settle the REVIEWED head before recording its count. Recording the first non-empty read would
  # capture a partially-registered set, and that partial number then becomes the bar the merge
  # commit is measured against — a later failing job could appear after the tag was pushed.
  total="$(await_checks "$sha")" || die "the reviewed head's checks never settled — refusing to merge"
  rset REVIEWED_SHA "$sha"; rset EXPECTED_CHECKS "$total"
  say "reviewed $sha — $total checks settled"
}

cmd_merge() {
  local pr sha
  have_gh || die "gh not found"
  need pr PR 'run record-pr first'
  need sha REVIEWED_SHA 'run await-review first'
  cmd_readiness   # re-verify against the PIN before an irreversible act
  flag="$(bash "$LIB/repo-settings.sh" merge-flag)" || flag="--squash"
  # --match-head-commit makes GitHub REJECT the merge if a commit landed after the reviewer passed.
  # shellcheck disable=SC2086
  gh pr merge "$pr" $flag --delete-branch --match-head-commit "$sha" \
    || die "merge refused — head moved since review, or merge blocked"
  msha="$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid')"
  [ -n "$msha" ] && [ "$msha" != "null" ] || die "cannot resolve the merge commit"
  rset MERGE_SHA "$msha"
  say "merged #$pr -> $msha"
}

cmd_verify_merge() {
  local msha exp
  have_gh || die "gh not found"
  need msha MERGE_SHA 'run merge first'
  need exp EXPECTED_CHECKS 'run await-review first'
  total="$(await_checks "$msha" "$exp")" || die "$msha never reached a settled set of >= $exp — refusing to tag"
  h="$(health_of "$msha")" || die "branch-health failed"
  case "$h" in green|no-ci) : ;; *) die "$msha health is '$h' — refusing to tag" ;; esac
  rset SETTLED "$total checks"
  cmd_readiness   # a blocker reopened during the wait must stop the tag
  say "merge commit settled ($total checks) and $h"
}

cmd_tag() {
  local v msha
  [ "$#" -eq 2 ] && [ "$1" = "--message-file" ] || { usage >&2; exit 2; }
  msg="$2"
  [ -s "$msg" ] || die "tag message file is empty or missing: $msg"
  need v VERSION 'run version-guard first'
  need msha MERGE_SHA 'run merge first'
  git -C "$ROOT" fetch --prune --tags origin >/dev/null 2>&1 || die "fetch failed"
  # Idempotent: a resumed run may already hold the tag. Require any existing one to point at the
  # SAME verified commit; never move a tag.
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$v" >/dev/null 2>&1; then
    [ "$(git -C "$ROOT" rev-list -n1 "$v")" = "$msha" ] || die "local $v points elsewhere — refusing to move a tag"
  else
    # -F, never an inline -m: the release paragraph is Markdown and routinely contains backticks,
    # which a double-quoted -m would run as command substitution.
    git -C "$ROOT" tag -a "$v" "$msha" -F "$msg" || die "could not create tag $v"
  fi
  git -C "$ROOT" push origin "$v" || die "could not push $v — re-run this command to retry"
  # --exit-code is REQUIRED: plain ls-remote exits 0 with EMPTY output on no match, so the
  # verification would pass on a tag that was never published.
  git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$v" >/dev/null \
    || die "$v is NOT on origin — do not roll the milestone"
  remote_sha="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$v^{}" | awk '{print $1}')"
  [ "$remote_sha" = "$msha" ] || die "origin's $v points at ${remote_sha:-<none>}, not $msha"
  say "tagged: $v -> $msha (verified on origin)"
}

cmd_roll() {
  local v pinned_m pinned_ms
  have_gh || die "gh not found"
  need v VERSION 'run version-guard first'
  need pinned_m M_NUM 'run readiness first'
  # GUARDED, not a bare `rs` (#313). `cmd_readiness` writes M_NUM and MS_NAME together, so an
  # unpinned MS_NAME "cannot happen" — but the run state is an appended text file that a resumed or
  # hand-edited run can leave partial, and this is the one place where an empty value does not
  # merely propagate: it DEFEATS THE GUARD BELOW. With `pinned_ms` empty the jq selects milestones
  # whose title equals "", finds none, yields "", and the comparison becomes `[ "" = "" ]`, which
  # PASSES. The check written specifically so a changed marker cannot rename, drain and close the
  # wrong milestone would wave the roll through, having verified nothing.
  need pinned_ms MS_NAME 'run readiness first'
  # REVALIDATE the pin immediately before rolling. `baseline release roll` resolves the marker
  # itself, so a marker changed since the pin would make it rename, drain and close a DIFFERENT
  # milestone than the one this release was cut for.
  sl="$(slug)" || die "cannot resolve this repo's slug"
  msj="$(gh api --paginate "repos/$sl/milestones?state=open&per_page=100")" || die "could not list milestones"
  now_m="$(printf '%s' "$msj" | jq -r -s --arg t "$pinned_ms" '[.[][] | select(.title == $t) | .number] | first // empty')"
  [ "$now_m" = "$pinned_m" ] \
    || die "milestone '$pinned_ms' now resolves to #${now_m:-<none>}, not the pinned #$pinned_m — refusing to roll"
  bash "$ROOT/bin/baseline" release roll --version "$v" || die "rollover failed"
  rm -f "$RS"
  say "rolled $pinned_ms -> $v; run state cleared"
}

cmd_state() { [ -f "$RS" ] && cat "$RS" || say "(no run state)"; }

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  sub="$1"; shift
  case "$sub" in
    preflight)      cmd_preflight "$@" ;;
    readiness)      cmd_readiness "$@" ;;
    inventory)      cmd_inventory "$@" ;;
    version-guard)  cmd_version_guard "$@" ;;
    roll-preflight) cmd_roll_preflight "$@" ;;
    stamp-verify)   cmd_stamp_verify "$@" ;;
    record-pr)      cmd_record_pr "$@" ;;
    await-review)   cmd_await_review "$@" ;;
    merge)          cmd_merge "$@" ;;
    verify-merge)   cmd_verify_merge "$@" ;;
    tag)            cmd_tag "$@" ;;
    roll)           cmd_roll "$@" ;;
    state)          cmd_state "$@" ;;
    -h|--help)      usage ;;
    *) printf 'release: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
