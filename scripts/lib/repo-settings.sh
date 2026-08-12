#!/usr/bin/env bash
# ai-dev-baseline — hand PR merges to GitHub (issue #87).
#
# The operator used to merge every PR by hand: the most frequent human touchpoint in the
# implement -> review -> merge loop. Worse, nothing enforced green — a repo can carry branch
# protection with `required_conversation_resolution` on and NO required status checks, so a red
# PR merges the moment a human clicks. This helper closes both halves, in the ONE order that is
# safe:
#
#   1. required status checks  <- discovered from .github/workflows, never hardcoded
#   2. allow_auto_merge        <- only after (1) succeeded
#
# ORDER IS LOAD-BEARING. Reversed, auto-merge lands PRs with nothing gating them — strictly worse
# than merging by hand, because no human is left to notice the red. `apply` therefore refuses to
# enable auto-merge if the checks write did not succeed.
#
# `/implement-issue` then ends with `gh pr merge --auto --squash`, gated on `automerge-ok` so a
# repo that is not in the safe state never gets a blind arm. See base/workflows/implement-issue.md
# and docs/repo-settings.md.
#
# Usage:
#   repo-settings.sh checks              # print the discovered check contexts, one per line
#   repo-settings.sh status              # report desired vs live (no changes); nonzero on drift
#   repo-settings.sh apply [--dry-run] [--prune] [--branch NAME] [--strict] [--enforce-admins]
#                                        # required checks FIRST, then allow_auto_merge.
#                                        # --prune drops required contexts this tool did not
#                                        # discover (default: keep them — they are usually an
#                                        # external provider, not a stale job)
#   repo-settings.sh automerge-ok        # runtime guard: is it safe to arm auto-merge?
#   repo-settings.sh required-drift [--porcelain]
#                                        # CI lint: has a discovered job stayed non-required? (#122)
#                                        # --porcelain: same exit codes, but stdout carries ONLY the
#                                        # drifted context names (one per line) and no prose, so a
#                                        # caller can name them without parsing — or repeating — a
#                                        # remedy that is wrong for its branch (#165)
#   repo-settings.sh merge-flag          # the `gh pr merge` flag this repo allows (--squash/…)
#   repo-settings.sh branch-required-contexts
#                                        # branch JSON on stdin -> the required contexts as a JSON
#                                        # array, or `null` when the branch is protected by
#                                        # something this endpoint cannot describe (#115). Pure:
#                                        # jq only, no gh — /roadmap owns that read.
#   (any subcommand) [--workflow-dir DIR]  # discover from DIR instead of ./.github/workflows —
#                                        # e.g. the merged default-branch tree, not this branch
#   repo-settings.sh -h | --help
#
# `automerge-ok` exit codes are a stable machine contract for the workflow step:
#   0  safe    — auto-merge enabled AND required checks configured on the default branch
#   10 unsafe  — the repo has allow_auto_merge off (nothing to arm)
#   11 unsafe  — CI exists but NO required checks: `--auto` would arm an ungated merge
#   12 unsafe  — the repo has no PR-triggered CI at all: `--auto` would merge immediately
#   13 unsafe  — a required context no workflow reports: an armed PR would wait forever
#   14 unsafe  — a discovered job is not required: auto-merge could land a red build
#   20 unknown — live state could not be read, OR check discovery failed on a workflow file
#                (#102); FAIL CLOSED, never assume safe. Note this is deliberately NOT 12: a
#                parser that could not read the CI must not report "this repo has no CI".
#
# WHICH OF THESE A PLATFORM OUTAGE CAN PRODUCE: only 20, and only from the three API reads (#300).
# 10-14 all compare a STATICALLY DISCOVERED job set against CONFIGURED branch protection, and an
# incident moves neither — so 13 ("a required context no workflow reports") is a configuration
# verdict that an outage cannot cause and cannot clear. Worth stating because the opposite was
# assumed: the outage arm says so out loud (`_adb_rs_outage_hint`), and a run that never EXECUTED
# is a different question again, answered by `ci-health.sh classify --run <id>`.
#
# `required-drift` (#122) answers ONE of those questions — "has a discovered job stayed
# non-required?" — early enough to matter, and reuses the same two codes so a number never means
# two things:
#   0  in sync — every discovered job is required (or the repo has no discoverable CI, per #24)
#   14 drift   — discovered job(s) are NOT required; names them + the one-command remedy
#   20 unknown — live state could not be read, discovery contradicts it, or discovery FAILED on a
#                workflow file (#102); FAIL CLOSED
#   (1        — missing/unauthenticated gh, or missing jq. Shared with every other subcommand:
#              the tool preamble fails before any subcommand logic runs.)
#
# It exists because `automerge-ok` learns this at MERGE time, by which point the fix is a manual
# detour. Deliberately narrow: it does NOT fail on allow_auto_merge being off, on phantom contexts,
# or on external-provider contexts — those are different problems with different remedies, and
# `status` already reports them all.
#
# It reads the live set through the ORDINARY branch endpoint (`repos/{slug}/branches/{branch}`),
# NOT the admin-only `/protection` one, because its home is a CI job running as GITHUB_TOKEN —
# which cannot hold admin (`administration` is not a grantable workflow permission). The ordinary
# endpoint needs only contents:read and returns the same `required_status_checks.contexts`.
#
# What this file must never grow: it is repo *settings* bookkeeping. It does not merge, review,
# tag, release, or deploy. It only reads .github/workflows and writes two GitHub settings.
#
# Requires: gh (authenticated, admin on the target repo — EXCEPT `required-drift`, which needs
# only contents:read), jq.

set -uo pipefail

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way the sibling scripts/lib modules do
# (release-convention.sh, skill-compose.sh) — adb_usage / adb_info vanish without it, so a missing
# library FAILS LOUD rather than silently degrading into a no-op that reports success.
_adb_rs_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_rs_common="$_adb_rs_libdir/common.sh"
if [ ! -f "$_adb_rs_common" ]; then
  printf 'repo-settings: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_rs_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_rs_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() { adb_usage "$0"; }

# --- options -------------------------------------------------------------------------------
OPT_DRY_RUN=0
OPT_BRANCH=""
# `strict` ("require branches to be up to date before merging") defaults OFF — see D9 in
# .ai-dev-baseline/decisions.md. With strict on, any commit landing on the default branch makes an
# already-armed PR not-up-to-date, and GitHub's auto-update behavior for auto-merge PRs is not a
# documented guarantee (merge queue is the supported answer). The realistic outcome is an
# auto-merge that silently never fires — reintroducing exactly the manual touchpoint this file
# exists to remove.
OPT_STRICT=0
# `enforce_admins` defaults OFF: turning it on removes the owner's break-glass (an admin can no
# longer merge or push past a stuck check). That is a real capability to take away, so it is
# opt-in, not a side effect of running `apply`. With it off the AUTOMATED path is still fully
# gated — `gh pr merge --auto` cannot fire on red — while a human keeps an explicit override.
OPT_ENFORCE_ADMINS=0
# Discover from another workflow tree (see workflow_dir).
OPT_WORKFLOW_DIR=""
# `required-drift --porcelain` (#165): STDOUT carries the drifted context names, one per line, and
# NOTHING else — no prose, no remedy, no "in sync" chatter. `required-drift` ONLY; every other read
# subcommand rejects it (see parse_read_opts), because a flag that is silently inert on four of the
# five commands that accept it is exactly the knob-that-does-nothing this file refuses elsewhere.
#
# IT EXISTS TO STOP A CALLER PARSING PROSE, and specifically to stop one repeating a remedy that is
# WRONG in its context. The human code-14 narrative ends in `baseline repo apply`, which is correct
# on the default branch and actively harmful from a PR branch: applying there makes the context
# required before the job exists on the default branch, and if the PR is then abandoned the branch
# is left requiring something nothing will ever report (#165, docs/repo-settings.md "When it
# fails"). A CI step that echoed that narrative as an "advisory" would be handing the operator the
# hazard this whole change removes. So the step takes the NAMES from here and writes its own remedy.
#
# STILL READ-ONLY. This adds an output shape, not a write: the library goes on reading
# .github/workflows and writing only the two GitHub settings `apply` owns. The advisory SURFACE — a
# job summary, an annotation — is written by the workflow step, which is the boundary #165 asked to
# preserve and the reason this is a print mode rather than a reporter.
OPT_PORCELAIN=0
# By default `apply` UNIONS the discovered contexts with whatever is already required, because a
# required context this tool did not discover is usually an EXTERNAL provider (Codecov, CircleCI,
# Vercel, a DCO check) that lives outside .github/workflows. Writing the discovered set absolutely
# would silently delete those and report success. --prune writes the exact discovered set, which
# is the remedy for a genuinely stale context left behind by a renamed or deleted job.
OPT_PRUNE=0

REPO_SLUG=""
REPO_JSON=""

# Fail loud on a missing/unauthenticated gh — never a silent no-op. The tool+auth preamble itself
# lives in common.sh (adb_require_gh), sourced not copied: release-convention.sh needs the exact
# same guard, and two copies of a fail-loud check are two things that drift.
require_gh() { adb_require_gh jq || exit 1; }

# repo_json — the repo object, read ONCE per run, and the ONE call that also resolves the slug.
# `gh api repos/{owner}/{repo}` expands those placeholders LOCALLY from the git remote, so
# `.full_name` yields the slug without a second `gh repo view` round trip. That matters more than
# it looks: `automerge-ok` runs on every /implement-issue, so this is the one recurring cost.
#
# The object carries the three things every subcommand needs: .default_branch, .allow_auto_merge,
# and .permissions.admin. The admin bit is load-bearing because GitHub returns 404 for BOTH "this
# branch has no protection" and "you may not see its protection" — without the permission probe
# the library would misread a permission error as "unprotected", stand protection up, and fail
# mid-write having already changed something.
#
# THIS IS THE SECOND PRODUCER BOUNDARY, and it is the reason #218 could not be fixed in one place.
# `adb_repo_slug` is the obvious chokepoint and it is NOT this module's: to save the round trip
# named above, the slug is read from THIS response's `.full_name`, so hardening the shared getter
# reaches `release-convention.sh` and nothing here. Seven `repos/$REPO_SLUG/...` paths are built
# downstream — four of them WRITES, in `apply`'s protection PATCH/POST/PUT and its auto-merge PATCH
# — so the validation has to happen where the value is produced. (Named by their subcommand rather
# than by line number on purpose: an earlier draft of this comment cited four line numbers that its
# own edit had already invalidated.)
#
# Six of those seven now compose their path through `_adb_rs_ref_path`, which #103 added for the
# REF half of the same problem. That does not move this boundary: the builder encodes the ref and
# concatenates the slug, so a malformed slug would still be interpolated raw. Two values, two
# rules — the slug is validated here at its producer, the ref is encoded there at its consumer.
#
# `adb_is_path_safe_repo_slug`, not `adb_is_repo_slug`: `a/..` is a well-formed owner/repo pair and
# a path traversal, and this value is API-supplied.
#
# VALIDATED BEFORE THE CACHE IS COMMITTED, for the same reason as `adb_repo_slug`. Precisely:
# `REPO_JSON` ALONE is the cache guard — the `[ -z … ]` below tests only it, and `REPO_SLUG` is
# carried along with it rather than checked independently. So assigning `REPO_JSON` first and
# rejecting afterwards would make a SECOND call skip resolution entirely and return 0 with the bad
# `REPO_SLUG` still loaded. The locals are what keep a rejected response from being cached at all.
# (Stated exactly because an earlier draft claimed BOTH globals gate the cache, which is false and
# would have sent the next reader looking for a bypass that `REPO_SLUG` cannot produce on its own.)
#
# NO CALLER CAN OBSERVE THAT ORDERING TODAY, and saying so is more useful than implying it is
# tested: every subcommand checks this function's status on its FIRST call and bails, so the wrong
# order behaves identically — it fails open only once some future caller re-calls after a failure.
# A behavioural test therefore cannot reach it, which is exactly why it would rot unnoticed, so
# `check-repo-settings.sh` pins the order STRUCTURALLY instead. That is the same move the
# `required-drift` CI wiring gets, and for the same reason: a design property whose inversion is
# silent still gets a test, and the test admits what kind it is.
#
# RETURNS 1, exactly as every other failure here does, so each subcommand keeps its OWN mapping
# rather than acquiring a new one: `automerge-ok`, `merge-flag` and `required-drift` already turn a
# `repo_json` failure into 20 (fail closed, refuse to arm), while `apply` and `status` turn it into
# 1. Emitting 20 from here would give `apply` an exit code its contract does not define.
repo_json() {
  local raw slug
  if [ -z "$REPO_JSON" ]; then
    raw="$(gh api 'repos/{owner}/{repo}' 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 1
    slug="$(printf '%s' "$raw" | jq -r '.full_name // empty' 2>/dev/null)"
    [ -n "$slug" ] || return 1
    # Rendered, never echoed raw — a rejected API value is the one most likely to carry a newline
    # and forge the line after it (see adb_display_value in common.sh). `printf '%s\n'` rather than
    # `echo` for the reason recorded there: under `shopt -s xpg_echo`, `echo` decodes `%q`'s `\n`
    # back into a real newline and undoes the rendering.
    adb_is_path_safe_repo_slug "$slug" || {
      printf 'repo-settings: the API reported a malformed repository slug (%s) — refusing to build a request path from it\n' \
        "$(adb_display_value "$slug")" >&2
      return 1
    }
    REPO_JSON="$raw"
    REPO_SLUG="$slug"
  fi
  printf '%s' "$REPO_JSON"
}

repo_field() { repo_json | jq -r "$1" 2>/dev/null; }

# jq_bool <flag-var-value> — render a 0/1 option flag as a JSON boolean for --argjson.
jq_bool() { [ "$1" -eq 1 ] 2>/dev/null && printf 'true' || printf 'false'; }

# nlines <text> — count non-empty lines. `grep -c` exits 1 on no match, so a naive
# `$(grep -c . || echo 0)` emits TWO zeros and turns the caller's `[ "$n" -eq 0 ]` into a syntax
# error. One home for the idiom, so that trap is fixed once.
nlines() {
  local n
  n="$(printf '%s\n' "$1" | LC_ALL=C grep -c . 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# target_branch — the branch to protect: --branch, else the repo's own default branch as GitHub
# reports it. Deliberately NOT the local git default: we are mutating the REMOTE repo, and a local
# clone can disagree (a stale origin/HEAD, a detached checkout).
target_branch() {
  if [ -n "$OPT_BRANCH" ]; then printf '%s' "$OPT_BRANCH"; return 0; fi
  local b; b="$(repo_field .default_branch)"
  [ -n "$b" ] && [ "$b" != "null" ] || return 1
  printf '%s' "$b"
}

# _adb_rs_ref_path <collection> <ref> [suffix] — THE ONE PLACE a git ref becomes part of an API
# path: `repos/<slug>/<collection>/<percent-encoded ref><suffix>`. Returns non-zero, printing
# nothing, when the ref cannot be encoded.
#
# SIX SITES BUILT THIS BY HAND (#103) — the protection GET, the ordinary branch GET, the
# check-runs GET, and `apply`'s PATCH, POST and PUT — and a seventh and eighth PRINTED one for the
# operator to paste. A branch legitimately named `release/v1` therefore reached
# `branches/release/v1/protection`, and the fix has to be the shared builder rather than a point
# patch: eight hand-written spellings are eight chances for the next one to be written raw.
#
# NOT `_adb_rs_branch_path`, though that is the obvious name and the one the issue reaches for.
# One of the eight is `commits/{ref}/check-runs`, whose `{ref}` is a ref (a branch, tag or SHA) on
# a DIFFERENT collection — a branch-only helper would have left exactly that site, the newest of
# them, still interpolating raw. `<collection>` is a literal this file supplies, never operator
# input, so it is not encoded.
#
# THE SUFFIX IS APPENDED AFTER THE ENCODED SEGMENT AND IS NOT ENCODED, which is what keeps
# `/check-runs?per_page=100` a sub-resource plus a query string instead of one absurd path segment.
# Encoding the whole endpoint is the obvious over-correction and it breaks pagination silently.
#
# ENCODING IS SCOPED TO THE PATH, and nothing else may consume the result. The RAW ref still drives
# check discovery (a workflow's `branches:` filter matches `release/v1`, never `release%2Fv1`) and
# every human-facing message. Swapping the encoded value in globally would leave the endpoints
# right and the discovery wrong — a quieter bug than the one being fixed.
_adb_rs_ref_path() {
  local enc
  enc="$(adb_url_path_segment "$2")" || return 1
  printf 'repos/%s/%s/%s%s' "$REPO_SLUG" "$1" "$enc" "${3:-}"
}

# --- check discovery -------------------------------------------------------------------------
#
# GitHub matches required status checks by CONTEXT NAME — the check run's name, which is a job's
# `name:` when it has one and the job KEY otherwise. No API lists "the checks this repo will
# report", so the names must come from the workflow files. Hardcoding them is what the issue
# forbids: a renamed job would silently stop gating.
#
# We parse the YAML textually (no parser exists in a stdlib-shell repo), which makes the PRECISION
# of the scan the whole correctness story. Two failure directions, both bad:
#
#   * requiring a name that never reports -> every PR blocks forever. GitHub validates nothing: it
#     accepts any string as a context, reports no error, and simply waits for it.
#   * missing a name that does report     -> that job silently stops gating.
#
# So discovery only emits jobs it can prove report on EVERY pull request, and loudly skips the rest
# (to stderr) instead of guessing. A skipped job is visible and fixable; a phantom required context
# is a repo-wide deadlock.
#
# Skipped on purpose:
#   - a workflow with no `pull_request` trigger         (never reports on a PR)
#   - `pull_request:` carrying `paths:`/`paths-ignore:` (runs only for some diffs)
#   - `pull_request:` whose `branches:` filter does not provably include the target branch
#   - a job with an `if:` condition                     (may be skipped)
#   - a job with a `strategy.matrix`                    (check name gains a matrix suffix)
#   - a job calling a reusable workflow (`uses:`)       (its check names come from the callee)
#   - a job whose `name:` interpolates `${{ … }}`       (not statically knowable)
#
# INDENTATION IS NOT THE GRAMMAR (#102, #262). This file used to pin job keys to exactly 2 spaces
# and job properties to exactly 4, and pin the `on:` block the same way. A uniform 4-space workflow
# is valid YAML that GitHub runs, and it was reported as `no pull_request trigger`, contributed
# ZERO contexts, and exited 0 — the parser going blind with nothing to report it.
#
# The YAML reading now lives in ONE place, `adb_wf_on` / `adb_wf_jobs` in scripts/lib/common.sh,
# shared with scripts/check-bash-floor.sh (#262: both files had their own scanner, and the two had
# already drifted on how a quoted scalar ends). That reader tracks RELATIVE DEPTH, so 2-space,
# 4-space and mixed files all read correctly. What stays here is the half that is genuinely this
# file's own: the VERDICT — which triggers and which job shapes can be proven to report on every
# PR. `check-bash-floor.sh` applies the exactly opposite filter to the same records.
#
# Scoping to the `jobs:` block is still not a nicety — `on:` puts `push:` and `pull_request:` at
# the very same indent as job keys, so a whole-file indent scan harvests those two as "jobs" and
# requires contexts that can never report. This repo's own ci.yml is that case; the shared reader
# is block-scoped for exactly this reason.
#
# Two reads per file: the file-level verdict is only complete once the whole `on:` block is seen
# (triggers can appear after `jobs:`), and emitting a job from a file that turns out never to run
# on a PR is the phantom context above.

# _adb_rs_file_verdict <file> <target-branch> -> "" when the file's jobs report on every PR to
# <target-branch>, else the human-readable reason it was skipped.
#
# Returns 0 for a VERDICT (whether or not it skips) and 1 for a STRUCTURAL FAILURE — the reader
# could not run, or the file has no `on:` block at all. Those are different facts and the caller
# acts on them differently: a skip is routine and under-requires by design, a structural failure
# means this parser cannot see the file and must not be allowed to report a clean, empty run.
# Every GitHub workflow has an `on:` key — it is what makes the file a workflow — so its absence
# is never a legitimate shape, only a read that went wrong.
_adb_rs_file_verdict() {
  local file="$1" target="$2" facts tag value tab
  local on_block=0 pr=0 inline_filter=0 pr_types=0 pr_paths=0 pr_br_ignore=0 pr_branches=0
  local neg_branch=0 have_opened=0 have_sync=0 branch_ok=0 pr_merge=0

  facts="$(adb_wf_on "$file")" || {
    printf 'the shared workflow reader failed on this file\n'
    return 1
  }
  tab="$(printf '\t')"
  # Split on the FIRST tab only. Every record in this grammar carries at most one free-text value
  # and carries it LAST, so `read -r tag value` keeps that value byte-for-byte — a trigger name or
  # a branch pattern containing a tab cannot truncate the record (see common.sh's grammar note).
  while IFS="$tab" read -r tag value; do
    case "$tag" in
      ONBLOCK) [ "$value" = "1" ] && on_block=1 ;;
      TRIGGER)
        case "$value" in pull_request|pull_request_target) pr=1 ;; esac ;;
      PRINLINEFILTER) inline_filter=1 ;;
      PRFILTER)
        case "$value" in
          types)           pr_types=1 ;;
          paths)           pr_paths=1 ;;
          branches-ignore) pr_br_ignore=1 ;;
          branches)        pr_branches=1 ;;
          merge)           pr_merge=1 ;;
        esac ;;
      PRTYPE)
        case "$value" in opened) have_opened=1 ;; synchronize) have_sync=1 ;; esac ;;
      # NEGATION IS SCOPED TO BRANCH PATTERNS, which is where the rule below is about. The awk
      # predecessor set this flag from ANY flow list it parsed, `types:` included, so a
      # `types: ["!x"]` beside a perfectly ordinary `branches: [main]` refused to prove a file
      # that GitHub runs on every PR. Only a branch pattern can carry the ordered precedence the
      # rule cannot evaluate.
      PRBRANCH)
        case "$value" in
          "!"*)                neg_branch=1 ;;
          "$target"|'*'|'**')  branch_ok=1 ;;
        esac ;;
    esac
  done <<EOF
$facts
EOF

  [ "$on_block" -eq 1 ] || {
    printf 'no on: block — this file is not a workflow this parser can read\n'; return 1
  }

  if [ "$pr" -eq 0 ]; then printf 'no pull_request trigger\n'; return 0; fi
  # A MERGE KEY UNDER THE TRIGGER (#291). Checked before every filter rule below, because it is a
  # statement about the whole FILE rather than about one filter: GitHub Actions implements YAML 1.2,
  # which has no `<<:`, so a workflow carrying one is a syntax error there and never runs. Whatever
  # the merged mapping was going to say about `branches:` or `types:` is therefore both unread and
  # moot. Refusing to prove the file is the recoverable direction — the alternative is a trigger
  # that looks unfiltered, which is exactly what makes every job in it REQUIRED and never reported.
  if [ "$pr_merge" -eq 1 ]; then
    printf 'pull_request merges a <<: key, which GitHub Actions does not support (the workflow does not run)\n'; return 0
  fi
  if [ "$inline_filter" -eq 1 ]; then
    printf 'pull_request carries an inline flow-mapping filter (cannot prove it runs for every PR)\n'; return 0
  fi
  # A narrowed `types:` is the merge-cleanup workflow trap: `types: [closed]` runs only AFTER a PR
  # closes, so as a required context it sits "expected — waiting" on every open PR forever. Require
  # both `opened` (reports on the new PR) and `synchronize` (re-reports on every later push);
  # anything narrower cannot gate a PR through its whole life.
  if [ "$pr_types" -eq 1 ] && { [ "$have_opened" -eq 0 ] || [ "$have_sync" -eq 0 ]; }; then
    printf 'pull_request narrows types: (needs both opened and synchronize to report on every PR)\n'; return 0
  fi
  if [ "$pr_paths" -eq 1 ]; then
    printf 'pull_request carries a paths/paths-ignore filter (it does not run for every PR)\n'; return 0
  fi
  if [ "$pr_br_ignore" -eq 1 ]; then
    printf 'pull_request carries a branches-ignore filter (cannot prove it runs for %s)\n' "$target"; return 0
  fi
  # A branches: filter is fine as long as it provably includes the target branch. "*" / "**" match
  # it; an explicit list must name it. GitHub evaluates branch patterns IN ORDER, so a later
  # `!main` overrides an earlier `*`. Rather than reimplement that precedence, refuse to prove
  # anything about a filter carrying a negation — `branches: ["*", "!main"]` looks inclusive here
  # and excludes main in fact.
  if [ "$pr_branches" -eq 1 ] && [ "$neg_branch" -eq 1 ]; then
    printf 'pull_request branches filter uses negative patterns (ordered precedence not evaluated)\n'; return 0
  fi
  if [ "$pr_branches" -eq 1 ] && [ "$branch_ok" -eq 0 ]; then
    printf 'pull_request branches filter does not provably include %s\n' "$target"; return 0
  fi
  return 0
}

# _adb_rs_jobs <file> -> TAB records "CHECK\t<context>" / "SKIP\t<job>\t<reason>" on stdout.
#
# The VERDICT half only. Enumeration is `adb_wf_jobs`'s job, shared with check-bash-floor.sh, which
# applies the exactly OPPOSITE filter to the same records (#262) — a matrix job is invisible to a
# required context and still very much a job running on some runner.
#
# Exit codes, because the three failures below are three different things and collapsing them
# would put the wrong sentence in front of the operator:
#   0  records emitted (possibly all SKIP)
#   1  the shared reader failed outright
#   2  the file declares no `jobs:` block at all
#   3  a `jobs:` block yielded ZERO jobs — always a parse failure, never a legitimate workflow
_adb_rs_jobs() {
  local file="$1" records tag n value tab i
  local -a key name flags

  records="$(adb_wf_jobs "$file")" || return 1
  tab="$(printf '\t')"
  local count=0 jobs_block=0
  while IFS="$tab" read -r tag n value; do
    case "$tag" in
      JOBSBLOCK) [ "$n" = "1" ] && jobs_block=1 ;;
      JOB)    key[$n]="$value"; flags[$n]=" "; count="$n" ;;
      NAME)   name[$n]="$value" ;;
      FLAG)   flags[$n]="${flags[$n]-} $value " ;;
    esac
  done <<EOF
$records
EOF

  [ "$jobs_block" -eq 1 ] || return 2
  [ "$count" -gt 0 ] || return 3

  # A MERGE KEY ANYWHERE IN THE FILE DISQUALIFIES EVERY JOB IN IT, and this is a file-wide verdict
  # rather than a per-job one because the fact is file-wide: GitHub Actions implements YAML 1.2,
  # which has no `<<:`, so ONE merge key is a syntax error that stops the WHOLE workflow running.
  #
  # Skipping only the merging job recreated the exact phantom this change exists to remove, one job
  # over. For `base: &base` + `alt: <<: *base`, skipping `alt` alone left `Base Name` in the required
  # set — a context from a workflow that never runs, which never reports and needs an admin token to
  # clear. The reader is right to report `merge` per job (the floor lint needs it that way); the
  # VERDICT is this file's to make, and it belongs at file scope. Found by independent review, which
  # also caught that the fixture asserted the phantom as correct.
  local any_merge=0
  for (( i = 1; i <= count; i++ )); do
    case "${flags[$i]-}" in *" merge "*) any_merge=1; break ;; esac
  done
  if [ "$any_merge" -eq 1 ]; then
    for (( i = 1; i <= count; i++ )); do
      printf 'SKIP\t%s\tis in a workflow that merges a <<: key, which GitHub Actions does not support (the whole file does not run)\n' "${key[$i]}"
    done
    return 0
  fi

  for (( i = 1; i <= count; i++ )); do
    # Precedence matters only for the message: any one of these disqualifies the job, and naming
    # the first reason found is what the operator acts on.
    case "${flags[$i]-}" in
      # FIRST, because it is the most fundamental of the disqualifiers: the others say this job's
      # check name cannot be PROVEN, while this one says the workflow does not RUN. GitHub Actions
      # ships YAML 1.2, which has no merge key, so `<<:` is a syntax error there. Requiring anything
      # from such a file — under the job key, or under a name resolved from the anchor — is a context
      # that never reports and takes an admin token to clear (#291).
      *" merge "*)
        printf 'SKIP\t%s\tmerges a <<: key, which GitHub Actions does not support (the workflow does not run)\n' "${key[$i]}" ;;
      *" uses "*)
        printf 'SKIP\t%s\tcalls a reusable workflow (its check names come from the callee)\n' "${key[$i]}" ;;
      *" if "*)
        printf 'SKIP\t%s\thas a job-level if: (it may be skipped, and a required check that never reports blocks the PR forever)\n' "${key[$i]}" ;;
      *" matrix "*)
        printf 'SKIP\t%s\tis a matrix job (its check-run names carry a matrix suffix)\n' "${key[$i]}" ;;
      *" dynamic "*)
        printf 'SKIP\t%s\thas a name: containing a ${{ }} expression (not statically knowable)\n' "${key[$i]}" ;;
      *" blockname "*)
        printf 'SKIP\t%s\thas a block-scalar name: (its text is on the following lines, so the context cannot be proven)\n' "${key[$i]}" ;;
      *" alias "*)
        printf 'SKIP\t%s\tis a YAML alias (its configuration lives at the anchor, not under this key)\n' "${key[$i]}" ;;
      # An inline flow-mapping job (`hidden: {runs-on: …, steps: […]}`) is a real job, and it is
      # required under its key ONLY when the reader could prove that key IS the check context —
      # the `keyed` flag, which the reader withholds if the mapping carries `name:`, `if:`, `uses:`
      # or `strategy:` at its top level. Those are the same disqualifiers the block-form arms above
      # apply, and they must apply here too: an inline `{…, if: false, …}` required under its key is
      # a context that never reports, which deadlocks every PR. Without `keyed` the job is skipped —
      # under-requiring, the recoverable direction. The floor lint takes the opposite view of the
      # same `inline` flag and fails LOUD on it, because for its question an unreadable job must not
      # be silently absent.
      *" inline "*)
        case "${flags[$i]-}" in
          *" keyed "*) printf 'CHECK\t%s\n' "${key[$i]}" ;;
          *) printf 'SKIP\t%s\tis an inline flow mapping this reader cannot prove a check name for\n' "${key[$i]}" ;;
        esac ;;
      *)
        printf 'CHECK\t%s\n' "${name[$i]:-${key[$i]}}" ;;
    esac
  done
}

# workflow_dir — .github/workflows under the repo root the caller is in, unless --workflow-dir
# names another tree. That flag is not just a test hook: the real operational use is discovering
# from the MERGED default-branch state rather than a feature branch, so `apply` never requires a
# context whose job does not exist on the default branch yet (which would block every PR until it
# lands). A visible flag beats an exported variable here, because this redirects a WRITE path.
workflow_dir() {
  if [ -n "$OPT_WORKFLOW_DIR" ]; then printf '%s' "$OPT_WORKFLOW_DIR"; return 0; fi
  printf '%s/.github/workflows' "$(adb_repo_root)"
}

# discover_checks <branch> — the desired required-check contexts, one per line on stdout. Skips
# (per file and per job) go to stderr so stdout stays machine-consumable.
#
# TWO DIFFERENT EMPTIES, and telling them apart is the whole of #102:
#
#   "this repo has no CI"       -> return 0. A legitimate state (#24), not an error. No workflow
#                                  directory, no workflow files, or every file legitimately skipped.
#   "this parser went blind"    -> return 1. A file IS there, it declares structure, and this code
#                                  could not read it. Before #102 that was indistinguishable from
#                                  the first case: a uniform 4-space `ci.yml` produced
#                                  `no pull_request trigger`, zero contexts, and exit 0 — and the
#                                  `required-drift` backstop that was supposed to catch the
#                                  under-requirement could not, so `apply` reported success while
#                                  gating nothing.
#
# THE STRUCTURAL CHECK RUNS ON EVERY FILE, including ones the verdict skipped. That is deliberate:
# a file skipped as "no pull_request trigger" is exactly what a blind trigger parse looks like, so
# checking only the files that PASSED would leave the #102 shape unexamined. Every GitHub workflow
# has an `on:` key and a `jobs:` block with at least one job in it — those three facts are what
# make the file a workflow — so a violation is never a legitimate shape, only a read that failed.
#
# Callers must CAPTURE THEN CHECK: `x="$(discover_checks …)"` propagates this status, but
# `x="$(discover_checks … | sort -u)"` reports `sort`'s and throws the whole signal away.
discover_checks() {
  local branch="$1" dir f verdict jobs_out found=0 rc=0 vrc jrc
  dir="$(workflow_dir)"
  [ -d "$dir" ] || { printf 'repo-settings: no %s — treating this repo as having no CI\n' "$dir" >&2; return 0; }
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue          # filters an unmatched literal glob (no portable nullglob)
    found=1
    verdict="$(_adb_rs_file_verdict "$f" "$branch")"; vrc=$?
    if [ "$vrc" -ne 0 ]; then
      printf 'repo-settings: FAILED to read %s — %s. Discovery is unreliable for this repo; refusing to report a clean scan.\n' \
        "${f##*/}" "$verdict" >&2
      rc=1; continue
    fi

    # The jobs read happens even for a skipped file, for the structural check above. Capture the
    # status BEFORE consuming the output: piping a command substitution straight into a loop
    # discards it, and a crashed reader would then read as "this file declares no jobs".
    jobs_out="$(_adb_rs_jobs "$f")"; jrc=$?
    case "$jrc" in
      0) : ;;
      2) printf 'repo-settings: FAILED to read %s — it declares no jobs: block. Every workflow has one; refusing to report a clean scan.\n' \
           "${f##*/}" >&2; rc=1; continue ;;
      3) printf 'repo-settings: FAILED to read %s — it declares a jobs: block that yielded NO jobs. That combination is always a parse failure, never an empty workflow.\n' \
           "${f##*/}" >&2; rc=1; continue ;;
      *) printf 'repo-settings: FAILED to read %s — the shared workflow reader failed outright.\n' \
           "${f##*/}" >&2; rc=1; continue ;;
    esac

    if [ -n "$verdict" ]; then
      printf 'repo-settings: skipping %s — %s\n' "${f##*/}" "$verdict" >&2
      continue
    fi

    # Split on the FIRST tab only (read -r kind rest), never field-by-field: a job `name:` may
    # legally contain a tab inside a quoted scalar, and a tab-delimited multi-field read would
    # truncate it there — silently requiring a context that does not exist, which is the phantom
    # deadlock this whole file is built to avoid. `rest` keeps the name byte-for-byte.
    printf '%s\n' "$jobs_out" | while IFS="$(printf '\t')" read -r kind rest; do
      case "$kind" in
        CHECK) [ -n "$rest" ] && printf '%s\n' "$rest" ;;
        SKIP)  printf 'repo-settings: skipping job %s (%s) — %s\n' \
                 "${rest%%"$(printf '\t')"*}" "${f##*/}" "${rest#*"$(printf '\t')"}" >&2 ;;
      esac
    done
  done
  [ "$found" -eq 1 ] || printf 'repo-settings: no workflow files in %s — treating this repo as having no CI\n' "$dir" >&2
  return "$rc"
}

# _adb_rs_discover <branch> — discovery into RS_WANT, sorted and deduped, RETURNING
# discover_checks's own status.
#
# ONE home for the capture-then-check idiom, because every call site used to write
# `want="$(discover_checks "$b" | LC_ALL=C sort -u)"` — and a pipeline's status is its LAST
# command's, so that reports `sort`'s success and discards the discovery status entirely. With
# #102's fail-loud return added and this left as it was, a blind parse would have gone right on
# reporting a clean, empty desired set at all five call sites: the exact fail-open the return
# value exists to close, one line below the fix. Four of the five are guards.
RS_WANT=""
_adb_rs_discover() {
  local out rc
  out="$(discover_checks "$1")"; rc=$?
  RS_WANT="$(printf '%s\n' "$out" | sed '/^$/d' | LC_ALL=C sort -u)"
  return "$rc"
}

# --- live protection state --------------------------------------------------------------------

PROT_JSON=""
PROT_STATE=""   # protected-with-checks | protected-no-checks | unprotected | forbidden | error

# _adb_rs_api_i <path> — GET <path> with headers and split the response into RS_STATUS + RS_BODY.
#
# ONE home for the split, because both live-state readers need it and neither the status line's
# shape nor the CRLF-tolerant blank-line separator is obvious. Two pasted copies would mean a
# later fix (a redirect, a `100 Continue` preamble, an `HTTP/2 200` variant) reaching only one
# endpoint — and a mis-parsed status degrades silently into "unreadable", which both readers then
# report as a fail-closed error nobody can explain. Golden rule #4: source it, never copy it.
#
# Never returns non-zero: an unreachable API leaves RS_STATUS empty, which every caller already
# treats as "not 200". Callers classify; this only splits.
RS_STATUS=""
RS_BODY=""
_adb_rs_api_i() {
  local resp first
  RS_STATUS=""; RS_BODY=""
  resp="$(gh api -i "$1" 2>/dev/null)"
  # Slice the status line in-shell rather than piping the WHOLE response into `head -n1`. `head`
  # closes the pipe after one line, so on Linux the writer reports
  #   repo-settings.sh: line NN: printf: write error: Broken pipe
  # on every call — observed in this repo's own CI. Harmless to the result (the value is already
  # captured) but it is noise on every `automerge-ok` and every drift check, and it looks like a
  # failure in a tool whose whole job is to be trusted about failures. The first line is already
  # in `$resp`; taking it costs no process at all. An empty response yields an empty RS_STATUS,
  # which every caller already treats as "not 200".
  first="${resp%%$'\n'*}"
  RS_STATUS="$(printf '%s\n' "$first" | awk '{print $2}')"
  # No early exit here, so this one consumes its whole input and cannot take EPIPE.
  RS_BODY="$(printf '%s\n' "$resp" | awk 'b { print } /^\r?$/ { b = 1 }')"
  return 0
}

# read_protection <branch> — classify the branch's protection ONCE. GitHub's 404 is ambiguous (no
# protection OR no permission to see it), so it is disambiguated against the repo object's
# .permissions.admin rather than assumed. Fail-closed: an unreadable repo object is `error`, never
# "unprotected" — which would send `apply` down the stand-up-from-scratch path on a repo it cannot
# actually read.
read_protection() {
  local branch="$1" status body admin path
  PROT_JSON=""
  admin="$(repo_field .permissions.admin)" || admin=""
  # An unbuildable path is UNREADABLE STATE, not "no protection" (#103). Classified `error` for the
  # same reason a 5xx is: `unprotected` sends `apply` down the stand-up-from-scratch PUT, and doing
  # that because the ref could not be encoded would replace a branch's real protection object over
  # a local failure. Set before the read, so no stale PROT_JSON survives this arm.
  path="$(_adb_rs_ref_path branches "$branch" /protection)" || { PROT_STATE="error"; return 0; }
  # -i so the HTTP STATUS is inspectable. Distinguishing 404 from every other failure is not a
  # nicety: an admin hitting a transient 5xx or a network blip would otherwise be classified
  # `unprotected`, and `apply` would then seed its full replacement PUT from PROT_DEFAULTS —
  # silently discarding the branch's real approval, dismissal, bypass and restriction settings.
  # Only a CONFIRMED 404 means "no protection here".
  _adb_rs_api_i "$path"
  status="$RS_STATUS"; body="$RS_BODY"
  case "$status" in
    200)
      PROT_JSON="$body"
      if printf '%s' "$body" | jq -e '.required_status_checks != null' >/dev/null 2>&1; then
        PROT_STATE="protected-with-checks"
      else
        PROT_STATE="protected-no-checks"
      fi
      ;;
    404)
      # 404 is ambiguous between "no protection" and "you may not see it" — disambiguated by the
      # repo object's admin bit, never assumed.
      case "$admin" in
        true)  PROT_STATE="unprotected" ;;
        false) PROT_STATE="forbidden" ;;
        *)     PROT_STATE="error" ;;
      esac
      ;;
    403) PROT_STATE="forbidden" ;;
    *)   PROT_STATE="error" ;;   # 5xx, a network failure, an unparseable response
  esac
  return 0
}

live_contexts() {   # the contexts currently required, sorted, one per line (empty when none)
  [ -n "$PROT_JSON" ] || return 0
  printf '%s' "$PROT_JSON" | jq -r '.required_status_checks.contexts // [] | .[]' 2>/dev/null | LC_ALL=C sort
}

# nz <text> — the non-empty lines of <text>, for feeding `comm` (which needs sorted streams).
nz() { printf '%s\n' "$1" | sed '/^$/d'; }

# phantom_contexts <want> <live> — required contexts that NO discovered workflow job reports.
# These are the dangerous direction: GitHub validates nothing, so each one silently blocks every
# PR forever. `status` reports them and `automerge-ok` refuses to arm on them — ONE home for the
# comparison, so the guard can never be shallower than the report.
phantom_contexts() { LC_ALL=C comm -13 <(nz "$1") <(nz "$2"); }

# ungated_contexts <want> <live> — discovered jobs that are NOT required, i.e. gating nothing.
ungated_contexts() { LC_ALL=C comm -23 <(nz "$1") <(nz "$2"); }

# shared_contexts <a> <b> — the intersection, the third sibling of the two above. Kept here with
# them so `nz` and the C collation have one home: both operands must be sorted the same way, and
# restating that per call site is how one of them eventually gets it wrong.
shared_contexts() { LC_ALL=C comm -12 <(nz "$1") <(nz "$2"); }

# --- live protection state, the contents-read way (#122) ---------------------------------------
#
# A SECOND reader, not a second model. `read_protection` above uses the admin-only
# `/branches/{branch}/protection` endpoint, which a CI job can never call: GitHub Actions'
# GITHUB_TOKEN has no `administration` scope to grant, so an in-CI drift lint reading it would
# fail on every PR — and a lint that always fails is not a gate, it is noise.
#
# The ordinary `repos/{slug}/branches/{branch}` endpoint needs only contents:read and carries the
# same `required_status_checks.contexts` (verified equal, byte for byte, against the admin
# endpoint on this repo's 25 contexts). It also has a CLEANER error model for this purpose: its
# 404 means "no such branch", full stop — none of the "no protection OR no permission" ambiguity
# that forces `read_protection` to probe `.permissions.admin`.
#
# The one shape that must never be misread is a protected branch whose context list we cannot
# read. Taken as "zero contexts required" it would report EVERY discovered job as ungated — a
# repo-wide false positive that fails every PR and teaches the operator to ignore this lint. So it
# is classified `opaque` and fails closed, exactly like an HTTP error. `opaque` covers both a
# response we could not parse and one that hid the list, which is why its message names neither
# cause: from here the two are indistinguishable, and guessing between them is what it refuses.
BR_STATE=""       # checks | unprotected | opaque | error
BR_CONTEXTS=""    # the live required contexts, sorted, one per line (empty when none)

# _adb_rs_classify_branch — stdin: a 200 response BODY from `repos/{slug}/branches/{branch}`.
# Prints the classification on line 1 (`checks` | `unprotected` | `opaque`) and the required
# contexts on line 2 as a COMPACT JSON ARRAY (`[]` for every state but `checks`).
#
# LINE 2 IS JSON, NOT ONE CONTEXT PER LINE, and that is a correctness requirement rather than a
# convenience. A newline-delimited rendering cannot round-trip a value CONTAINING a newline: the
# first draft emitted one context per line and `["a\nb"]` came back out as TWO required contexts,
# one of which nothing can ever report — a phantom, and a permanent `indeterminate`. JSON is the
# only encoding here that is closed under the values it carries. Each consumer renders from it:
# `read_branch` needs sorted LINES for `comm`, `branch-required-contexts` passes the array through.
#
# SPLIT OUT FROM `read_branch` (#115) so the 200-body MODEL has ONE home. It now has two
# consumers with different transports: `read_branch` below, which owns the HTTP read and maps a
# non-200 to `error`, and the `branch-required-contexts` subcommand, which serves /roadmap's
# health gate from a body the workflow already fetched. Restating these three arms in the second
# consumer is exactly the drift Golden Rule 4 forbids — and the arm that would rot first is the
# ruleset one, whose whole point is that it is not obvious.
#
# NEVER returns non-zero: every input is classifiable, because "I could not classify this" IS
# `opaque`. Callers distinguish transport failure themselves.
_adb_rs_classify_branch() {
  local body
  body="$(cat)"

  # `.protected == false` is an AUTHORITATIVE "nothing protects this branch" — not an unreadable
  # state. Every discovered job is genuinely ungated there, which is real drift worth reporting.
  if printf '%s' "$body" | jq -e '.protected == false' >/dev/null 2>&1; then
    printf 'unprotected\n[]\n'; return 0
  fi
  # Protected: the contexts array must be readable as an array AND the legacy protection block it
  # hangs off must actually be ENABLED. Both halves are load-bearing, and the second one is not
  # obvious — it is what keeps a RULESET-protected branch from reading as "requires nothing".
  #
  # This endpoint's `protection` object is the LEGACY classic-protection view. A branch protected
  # by a repository ruleset instead reports, verified live on github/docs and vercel/next.js:
  #
  #     {"protected": true,
  #      "protection": {"enabled": false,
  #                     "required_status_checks": {"enforcement_level": "off", "contexts": []}}}
  #
  # `contexts` IS an array there, so an array-only test accepts it as an authoritative empty set
  # and reports every discovered job as ungated — the repo-wide false positive this reader exists
  # to avoid, and a hard deadlock when the job printing it is itself one of the required contexts.
  # `enabled: false` with `protected: true` means "protected by something this legacy view does
  # not describe", which is precisely `opaque`: not readable here, so do not guess.
  #
  # Classic protection with required checks switched off is a DIFFERENT state and stays actionable:
  # `enabled` is true there, so it lands in `checks` with an empty set and reports real drift.
  #
  # Sorted with LC_ALL=C to the same contract `live_contexts` produces, because both feed `comm`,
  # which silently yields WRONG SETS — not an error — if the two streams were collated differently.
  # EVERY MEMBER MUST BE A NON-EMPTY STRING, not merely "contexts is an array". Checking only the
  # container let three shapes through, each of which then LOOKED authoritative downstream:
  # `[null, 5]` was stringified by `jq -r` into the plausible contexts "null" and "5"; `[""]` was
  # dropped to an empty set, which is the AUTHORITATIVE "this branch declares nothing" and can
  # reach `no-ci`; and neither could be caught later, because by then they were ordinary strings.
  # A contexts array we cannot make sense of is exactly what `opaque` means — so it is classified
  # that way here, at the one place that can still tell. (Independent-review find.)
  if printf '%s' "$body" \
       | jq -e '.protection.enabled == true
                and (.protection.required_status_checks.contexts | type) == "array"
                and (.protection.required_status_checks.contexts
                     | all(type == "string" and (gsub("^\\s+|\\s+$"; "") | length > 0)))' >/dev/null 2>&1; then
    printf 'checks\n'
    # `unique` sorts as a side effect, and it sorts by JSON value order — which for strings is
    # codepoint order, the same total order LC_ALL=C gives `read_branch`'s `comm` streams. Doing it
    # here means both consumers see one canonical set rather than each imposing its own.
    printf '%s' "$body" | jq -c '.protection.required_status_checks.contexts | unique' 2>/dev/null
    return 0
  fi
  printf 'opaque\n[]\n'
  return 0
}

# read_branch <branch> — classify the branch's required-check state via the contents-read endpoint.
read_branch() {
  local branch="$1" out path
  BR_STATE=""; BR_CONTEXTS=""
  # An unbuildable path joins the `error` arm, which `required-drift` already turns into a
  # fail-closed 20 (#103). Reporting it as any readable state would let the drift lint pass on
  # evidence it never fetched.
  path="$(_adb_rs_ref_path branches "$branch")" || { BR_STATE="error"; return 0; }
  # -i so the HTTP status is inspectable; a 5xx or a network blip must never look like "no checks".
  _adb_rs_api_i "$path"
  [ "$RS_STATUS" = "200" ] || { BR_STATE="error"; return 0; }
  out="$(printf '%s' "$RS_BODY" | _adb_rs_classify_branch)"
  BR_STATE="${out%%$'\n'*}"
  # Line 2 is the JSON array; render it to the one-per-line, LC_ALL=C-sorted form this reader has
  # always published, because BR_CONTEXTS feeds `comm` (which silently yields WRONG SETS, not an
  # error, if two streams were collated differently). The classifier already `unique`d, so this is
  # a rendering, not a second decision.
  BR_CONTEXTS="$(printf '%s' "$out" | sed -n '2p' | jq -r '.[]' 2>/dev/null | LC_ALL=C sort)"
  return 0
}

# _adb_rs_has_workflow_files — 0 when the workflow dir exists and holds at least one workflow file.
# Distinguishes "this repo has no CI to discover" (#24, a legitimate pass) from "there are
# workflow files and discovery still produced nothing", which is a parser problem wearing the
# same empty result. Globs are guarded with -f because there is no portable nullglob.
_adb_rs_has_workflow_files() {
  local dir f
  dir="$(workflow_dir)"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# _adb_rs_checkruns <ref> — the raw check-runs document for <ref>'s head. Split out from the two
# filters below so PROVENANCE IS ONE READ: asking "which are Actions?" and "which cannot be
# attributed at all?" must describe the same set of check runs, not two reads a push could
# separate.  Returns non-zero only when the READ failed.
_adb_rs_checkruns() {
  local path
  # The `{ref}` here is a REF, not a branch — this is why the shared builder is ref-shaped. The
  # query string rides in the suffix, unencoded, so pagination survives (#103).
  path="$(_adb_rs_ref_path commits "$1" '/check-runs?per_page=100')" || return 1
  gh api --paginate "$path" 2>/dev/null
}

# Provenance is TRI-STATE, and conflating any two of the states is a fail-open (#179):
#
#   ACTIONS   app.slug == `github-actions`  -> came from a workflow in this tree
#   EXTERNAL  any other NON-EMPTY slug      -> CircleCI/Vercel/a linter bot; not this lint's business
#   UNKNOWN   `app` null or slug missing    -> cannot be attributed; the caller must fail closed
#
# `app` is required-but-NULLABLE in the GitHub REST schema, so UNKNOWN is a shape the API really
# produces. Folding it into EXTERNAL (which is what a single "is it Actions?" filter does) makes an
# unattributable context read as somebody else's problem — and `required-drift` then reports a clean
# pass over exactly the contexts it could not vouch for.
#
# Both filters take the document on stdin and are otherwise pure, so the offline suite drives them
# with fixtures. The Actions slug comes from `adb_actions_app_slug` (common.sh, the ONE home) and is
# passed as a typed --arg, so this file cannot drift from roadmap-lib.sh: both consumers read the
# same value, and neither restates it.

# _adb_rs_classify_contexts — read the check-runs document on stdin, emit one
# `<state>\t<name>` line per check run. ONE filter decides all three states, so they PARTITION by
# construction: widening what counts as Actions cannot leave the unknown arm behind, which is
# exactly what two independent half-filters would allow (and what the first draft of this fix did).
#
# FAILS CLOSED on a document it cannot read. The status matters and callers MUST test it: an
# unparseable body would otherwise yield an empty classification, which is indistinguishable from
# "no check runs" and lands on the external-CI pass — reintroducing the fail-open this whole change
# exists to remove. `.app.slug?` rather than `.app.slug` so a malformed `app` (a string, say) is
# UNKNOWN rather than a hard error, keeping "shape we did not expect" inside the tri-state instead
# of collapsing it into a parse failure.
_adb_rs_classify_contexts() {
  jq -r --arg aslug "$(adb_actions_app_slug)" '
    if type != "object" then error("check-runs response is not a JSON object") else . end
    | if (.check_runs | type) != "array" then error("check_runs is missing or not an array") else . end
    | .check_runs[]
    | (((.app.slug? // "") | if type == "string" then . else "" end)) as $s
    | (if   $s == ""     then "unknown"
       elif $s == $aslug then "actions"
       else                   "external" end)
      + "\t" + ((.name? // "") | tostring)
  ' 2>/dev/null
}

# _adb_rs_pick <state> — the sorted, deduped context names for one state of the classification,
# read on stdin. `sort -u` matches the collation of the `sort` that produces BR_CONTEXTS, which is
# what lets `shared_contexts` compare the two.
_adb_rs_pick() {
  LC_ALL=C awk -F'\t' -v want="$1" '$1 == want { print $2 }' | LC_ALL=C sort -u
}

# --- apply --------------------------------------------------------------------------------

# run_gh <label> <body-or-empty> <args…> — execute a mutating gh call, or print it (and its JSON
# body) under --dry-run. Every write in this file goes through here, so `--dry-run` cannot drift
# from what `apply` really does.
run_gh() {
  local label="$1" body="$2"; shift 2
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    adb_info "  would $label:"
    adb_info "    gh $*"
    [ -n "$body" ] && printf '%s\n' "$body" | sed 's/^/      /'
    return 0
  fi
  if [ -n "$body" ]; then
    printf '%s' "$body" | gh "$@" >/dev/null 2>&1
  else
    gh "$@" >/dev/null 2>&1
  fi
}

# contexts_json <contexts> — the {strict, contexts} object every write path shares.
contexts_json() {
  jq -n --argjson strict "$(jq_bool "$OPT_STRICT")" --arg ctx "$1" \
        '{strict: $strict, contexts: ($ctx | split("\n") | map(select(length > 0)))}'
}

# PROT_DEFAULTS — the protection object a repo gets when there is none yet, in the SAME shape the
# live GET returns ({enabled: …} wrappers), so exactly one jq filter builds the PUT body for both
# PUT paths. A second hand-written literal body would be a second thing to keep in step with the
# filter — precisely the drift the read-modify-write property exists to prevent.
# A PR is required before merging with zero required approvals: that enforces the feature-branch
# rule without inventing a review requirement the repo never had.
PROT_DEFAULTS='{"required_pull_request_reviews":{"required_approving_review_count":0},
                "required_conversation_resolution":{"enabled":true}}'

# write_required_checks <branch> <contexts> — set the required contexts through the NARROWEST
# endpoint that works, because the wide one is destructive:
#
#   protected-with-checks -> PATCH …/protection/required_status_checks
#        Touches only the status-check sub-resource. Nothing else can be lost.
#   protected-no-checks   -> PUT …/protection, body REBUILT FROM THE LIVE OBJECT
#        There is no status-check sub-resource to PATCH when the branch has none, so the full PUT
#        is the only path — and a full PUT REPLACES the whole protection object. Every key omitted
#        is reset: omitting required_pull_request_reviews removes "require a PR before merging"
#        (the no-direct-push-to-main guardrail this whole baseline rests on); omitting
#        required_conversation_resolution turns thread resolution off. So the body is
#        read-modify-write, never a fresh literal.
#   unprotected           -> the SAME PUT, seeded from PROT_DEFAULTS instead of the live object.
#
# (required_signatures is deliberately absent from the PUT body: it is a separate endpoint, and a
# PUT does not reset it.)
write_required_checks() {
  local branch="$1" ctx="$2" body base label prot
  # Built ONCE, before the first write, and a failure refuses the whole function (#103). All three
  # arms below hang off this path, so an arm-by-arm build would give a slashed branch three chances
  # to be spelled differently — and this is the write side, where the wrong endpoint is not merely
  # an unreadable answer.
  prot="$(_adb_rs_ref_path branches "$branch" /protection)" \
    || { echo "ERROR: could not build a request path for branch '$branch'" >&2; return 1; }
  case "$PROT_STATE" in
    protected-with-checks)
      body="$(contexts_json "$ctx")" \
        || { echo "ERROR: could not build the required_status_checks body" >&2; return 1; }
      adb_info "  required checks -> PATCH branches/$branch/protection/required_status_checks (narrow; nothing else touched)"
      run_gh "set required checks" "$body" \
        api -X PATCH "$prot/required_status_checks" --input - \
        || { echo "ERROR: could not set required status checks" >&2; return 1; }
      # The narrow PATCH cannot carry enforce_admins, so honor the flag through its own endpoint.
      # Without this the flag is a silent no-op on exactly the state a repo is in after its FIRST
      # successful apply — i.e. it would appear to work once and then quietly stop.
      if [ "$OPT_ENFORCE_ADMINS" -eq 1 ]; then
        adb_info "  enforce_admins -> POST branches/$branch/protection/enforce_admins"
        run_gh "enforce admins" "" api -X POST "$prot/enforce_admins" \
          || { echo "ERROR: could not enable enforce_admins" >&2; return 1; }
      fi
      ;;
    protected-no-checks|unprotected)
      if [ "$PROT_STATE" = "unprotected" ]; then
        base="$PROT_DEFAULTS"
        label="standing protection up from scratch"
      else
        base="$PROT_JSON"
        label="read-modify-write; every existing setting preserved"
      fi
      body="$(printf '%s' "$base" | jq \
                --argjson checks "$(contexts_json "$ctx")" \
                --argjson admins "$(jq_bool "$OPT_ENFORCE_ADMINS")" '
        {
          required_status_checks: $checks,
          enforce_admins: (if $admins then true else (.enforce_admins.enabled // false) end),
          # EVERY sub-field must be carried. dismissal_restrictions and
          # bypass_pull_request_allowances are the dangerous omissions: dropping the first turns
          # OFF "restrict who can dismiss reviews" (any write-access user can then dismiss), and
          # dropping the second revokes the bypass permission a bot or team was granted.
          # Both are GET-shaped ({users:[{login}]}) and PUT-shaped ({users:[login]}), so each is
          # remapped rather than passed through.
          required_pull_request_reviews:
            (if .required_pull_request_reviews == null then null else
             (.required_pull_request_reviews as $r | {
               dismiss_stale_reviews:           ($r.dismiss_stale_reviews // false),
               require_code_owner_reviews:      ($r.require_code_owner_reviews // false),
               require_last_push_approval:      ($r.require_last_push_approval // false),
               required_approving_review_count: ($r.required_approving_review_count // 0)
             }
             + (if $r.dismissal_restrictions == null then {} else
                 {dismissal_restrictions: {
                    users: [$r.dismissal_restrictions.users[]?.login],
                    teams: [$r.dismissal_restrictions.teams[]?.slug],
                    apps:  [$r.dismissal_restrictions.apps[]?.slug]}} end)
             + (if $r.bypass_pull_request_allowances == null then {} else
                 {bypass_pull_request_allowances: {
                    users: [$r.bypass_pull_request_allowances.users[]?.login],
                    teams: [$r.bypass_pull_request_allowances.teams[]?.slug],
                    apps:  [$r.bypass_pull_request_allowances.apps[]?.slug]}} end)
             ) end),
          restrictions:
            (if .restrictions == null then null else {
               users: [.restrictions.users[]?.login],
               teams: [.restrictions.teams[]?.slug],
               apps:  [.restrictions.apps[]?.slug]
             } end),
          required_linear_history:          (.required_linear_history.enabled // false),
          allow_force_pushes:               (.allow_force_pushes.enabled // false),
          allow_deletions:                  (.allow_deletions.enabled // false),
          block_creations:                  (.block_creations.enabled // false),
          required_conversation_resolution: (.required_conversation_resolution.enabled // false),
          lock_branch:                      (.lock_branch.enabled // false),
          allow_fork_syncing:               (.allow_fork_syncing.enabled // false)
        }')" \
        || { echo "ERROR: could not build the protection body" >&2; return 1; }
      adb_info "  required checks -> PUT branches/$branch/protection ($label)"
      run_gh "set required checks (full protection PUT)" "$body" \
        api -X PUT "$prot" --input - \
        || { echo "ERROR: could not set required status checks" >&2; return 1; }
      ;;
    *)
      echo "ERROR: cannot read branch protection for '$branch' (state: $PROT_STATE)" >&2
      return 1
      ;;
  esac
}

# manual_commands <branch> — what to run by hand when we lack admin. Degrading to instructions is
# the contract (#87): never block the run, never pretend it worked.
manual_commands() {
  local branch="$1" prot
  # THESE TWO LINES ARE RUNNABLE COMMANDS, so they carry the ENCODED segment (#103) — handing an
  # operator `branches/release/v1/protection` to paste is the same wrong-endpoint hazard, relocated
  # into their terminal, where nothing here can fail closed on it. The PROSE around them keeps the
  # raw name: it is for reading, and `release%2Fv1` is not what the branch is called.
  #
  adb_info ""
  adb_info "No admin permission on $REPO_SLUG — nothing was changed."
  adb_info "Ask an admin to run this same command, which picks the right endpoint for you:"
  adb_info "  baseline repo apply"
  adb_info ""
  # NO RAW FALLBACK (independent-review find). An earlier draft degraded to
  # `repos/$REPO_SLUG/branches/$branch/protection` when the encoder refused — which is the precise
  # raw interpolation this change exists to stop, handed to an operator to paste, in the one case
  # (a ref that is not valid UTF-8) where it is genuinely unrepresentable. A tool that refuses to
  # build a path and then prints it anyway has not refused. So the commands are OMITTED and the
  # reason is named; `baseline repo apply` above is still the answer, and it fails closed too.
  if ! prot="$(_adb_rs_ref_path branches "$branch" /protection)"; then
    adb_info "The by-hand commands cannot be shown: '$branch' has no valid request-path encoding"
    adb_info "(a branch name must be valid UTF-8 to become a URI path segment). Rename the branch,"
    adb_info "or run the command above, which refuses the same way rather than guessing."
    return 0
  fi
  adb_info "By hand, the endpoint depends on the branch's current state (protection: $PROT_STATE):"
  adb_info "  protected already -> gh api -X PATCH $prot/required_status_checks \\"
  adb_info "                         -F strict=false -f 'contexts[]=<each name from: baseline repo checks>'"
  adb_info "  NOT protected yet -> that subresource 404s; POST the full object instead:"
  adb_info "                       gh api -X PUT $prot --input <body.json>"
  adb_info "  then              -> gh api -X PATCH repos/$REPO_SLUG -F allow_auto_merge=true"
  adb_info "…in that order: required checks FIRST, or auto-merge lands PRs with nothing gating them."
}

cmd_apply() {
  require_gh
  local branch ctx n admin automerge dir kept
  repo_json >/dev/null || { echo "ERROR: could not read this repo via gh (no resolvable remote, or no access)" >&2; exit 1; }
  branch="$(target_branch)" || { echo "ERROR: could not resolve the target branch" >&2; exit 1; }

  # Probe permission BEFORE any write, so a non-admin run never flips one setting and then fails
  # on the other, leaving the repo in the exact half-configured state this file exists to prevent.
  admin="$(repo_field .permissions.admin)"
  adb_info "Repo settings for $REPO_SLUG (branch '$branch'):"
  # Read protection first either way: the non-admin remediation has to name the endpoint that
  # actually applies to this branch, and the subresource PATCH 404s on an unprotected one.
  read_protection "$branch"
  if [ "$admin" != "true" ]; then
    manual_commands "$branch"
    return 1
  fi

  # AN UNREADABLE PROTECTION STATE STOPS THE RUN BEFORE ANY WRITE, and this guard is load-bearing
  # rather than defensive (independent-review find). `write_required_checks` refuses `error` and
  # `forbidden` in its `*)` arm — but the NO-CI arm below never calls it, and then falls through to
  # the `allow_auto_merge` PATCH. So a protection read that failed could still end in an outward
  # mutation, on a repo whose protection this command could not see. That predates #103 (a 5xx did
  # it too); what #103 adds is a second way in, so it is closed here rather than left for the next
  # reader to rediscover.
  #
  # `error|forbidden` together, matching `automerge-ok`'s arm exactly: with admin true a 403 is
  # still possible (a token scope, SSO), and "protected but not visible to me" is unreadable state,
  # not permission to proceed. The non-admin case has already returned above.
  case "$PROT_STATE" in
    error|forbidden)
      echo "ERROR: cannot read branch protection for '$branch' (state: $PROT_STATE) — refusing to change any setting" >&2
      return 1 ;;
  esac

  dir="$(workflow_dir)"
  # A blind parse must never reach a WRITE. Under-requiring is not a cosmetic loss here: `apply`
  # would report success while gating nothing, and with `--prune` it would additionally DELETE the
  # contexts that were still gating the repo. Refuse before either can happen.
  _adb_rs_discover "$branch" || {
    echo "ERROR: check discovery failed (see above) — refusing to write required checks from an unreliable scan" >&2
    return 1
  }
  ctx="$RS_WANT"

  # Keep any required context we did not discover, unless --prune. See OPT_PRUNE: deleting an
  # external provider's check is silent damage, and this tool only knows about GitHub Actions.
  kept="$(phantom_contexts "$ctx" "$(live_contexts)")"
  if [ -n "$kept" ] && [ "$OPT_PRUNE" -eq 0 ]; then
    adb_info "  keeping $(nlines "$kept") required context(s) this tool did not discover"
    adb_info "    (an external CI provider? re-run with --prune if a job was renamed or removed)"
    printf '%s\n' "$kept" | sed 's/^/    ~ /'
    ctx="$(printf '%s\n%s\n' "$ctx" "$kept" | sed '/^$/d' | LC_ALL=C sort -u)"
  elif [ -n "$kept" ]; then
    adb_info "  --prune: dropping $(nlines "$kept") required context(s) no discovered job reports"
    printf '%s\n' "$kept" | sed 's/^/    - /'
  fi
  n="$(nlines "$ctx")"

  if [ "$n" -eq 0 ] && [ -n "$kept" ] && [ "$OPT_PRUNE" -eq 1 ]; then
    # --prune emptied the set. The write must still happen: skipping it would leave the stale
    # context required forever while this command reports that it was dropped.
    adb_info "  required checks -> clearing the last context(s) (--prune left nothing to require)"
    write_required_checks "$branch" "" || {
      echo "ERROR: could not clear the required checks" >&2
      return 1
    }
  elif [ "$n" -eq 0 ]; then
    # No CI (#24): skip the checks write entirely and DO NOT BLOCK. Enabling auto-merge is still
    # correct — it is a repo capability, not an arming — and `automerge-ok` returns 12 here, so
    # /implement-issue will not arm a merge that would land instantly with nothing gating it.
    adb_info "  required checks -> SKIPPED (no PR-triggered CI discovered; nothing to require)"
  else
    adb_info "  discovered $n check context(s) from $dir"
    printf '%s\n' "$ctx" | sed 's/^/    - /'
    write_required_checks "$branch" "$ctx" || {
      echo "ERROR: required checks were NOT set — refusing to enable auto-merge (order is load-bearing)" >&2
      return 1
    }
  fi

  # Only now, and only because the checks write did not fail.
  automerge="$(repo_field .allow_auto_merge)"
  if [ "$automerge" = "true" ]; then
    adb_info "  allow_auto_merge -> already enabled"
  else
    adb_info "  allow_auto_merge -> enabling"
    run_gh "enable auto-merge" "" api -X PATCH "repos/$REPO_SLUG" -F allow_auto_merge=true \
      || { echo "ERROR: could not enable allow_auto_merge" >&2; return 1; }
  fi

  adb_info ""
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    adb_info "Dry run — nothing was changed."
  else
    adb_info "Done. Re-run 'baseline repo apply' after ANY change to a CI job name: a renamed job"
    adb_info "leaves the old context required (blocking every PR) and the new one ungated. An"
    adb_info "already-open PR must merge the default branch in before a newly added context reports."
  fi
}

cmd_status() {
  require_gh
  local branch want got missing extra rc=0 disco_failed=0
  repo_json >/dev/null || { echo "ERROR: could not read this repo via gh (no resolvable remote, or no access)" >&2; exit 1; }
  branch="$(target_branch)" || { echo "ERROR: could not resolve the target branch" >&2; exit 1; }
  read_protection "$branch"

  # Discovery's own stderr stays hidden here (this is a human-facing summary, and a per-job skip
  # list would bury the verdict) — but a FAILED discovery is not a skip, so it is surfaced as
  # drift in its own right rather than silently reported as "0 discovered contexts", which reads
  # identically to a repo that legitimately has no CI.
  _adb_rs_discover "$branch" 2>/dev/null || disco_failed=1
  want="$RS_WANT"
  got="$(live_contexts)"

  adb_info "Repo settings for $REPO_SLUG (branch '$branch'):"
  adb_info "  admin permission:  $(repo_field .permissions.admin)"
  adb_info "  branch protection: $PROT_STATE"
  adb_info "  allow_auto_merge:  $(repo_field .allow_auto_merge)"
  adb_info "  required contexts (live):      $(nlines "$got")"
  adb_info "  discovered contexts (desired): $(nlines "$want")"

  case "$PROT_STATE" in
    error|forbidden)
      adb_info "  DRIFT: branch protection could not be read — treat every verdict below as unproven"
      rc=1 ;;
  esac

  # Reported BEFORE the drift verdicts, because it invalidates them: with discovery unreliable,
  # "discovered but NOT required" and "required but NOT discovered" are both computed against a
  # desired set this tool could not build. Re-run `baseline repo checks` to see which file failed.
  if [ "$disco_failed" -eq 1 ]; then
    adb_info "  DRIFT: check discovery FAILED on at least one workflow file — the desired set below is"
    adb_info "         incomplete, so every drift verdict after it is unproven. Run 'baseline repo checks'."
    rc=1
  fi

  # Drift, BOTH directions. The dangerous one is `extra`: a renamed job leaves the OLD context
  # required and never reported, which blocks every PR forever — GitHub validates nothing and
  # reports nothing, so this command is the only place that failure becomes visible.
  missing="$(ungated_contexts "$want" "$got")"
  extra="$(phantom_contexts "$want" "$got")"
  if [ -n "$missing" ]; then
    adb_info "  DRIFT: discovered but NOT required (these jobs gate nothing):"
    printf '%s\n' "$missing" | sed 's/^/    - /'
    rc=1
  fi
  if [ -n "$extra" ]; then
    adb_info "  DRIFT: required but NOT discovered (these block every PR — nothing will ever report them):"
    printf '%s\n' "$extra" | sed 's/^/    - /'
    rc=1
  fi
  if [ "$(repo_field .allow_auto_merge)" != "true" ]; then
    adb_info "  DRIFT: allow_auto_merge is off — /implement-issue cannot arm auto-merge"
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    adb_info "  in sync"
  else
    adb_info ""
    adb_info "Run 'baseline repo apply' to reconcile."
  fi
  return "$rc"
}

# _adb_rs_outage_hint — the second sentence every API-read failure in `automerge-ok` owes the
# operator (#300). A failed read is the ONE arm of this guard a platform incident can actually
# reach: everything else here compares a statically discovered job set against configured branch
# protection, so no outage can move it. Code 13 in particular is a CONFIGURATION verdict — a
# required context no discovered workflow reports — and reading it as "CI might be down" sends the
# operator to a status page for a problem that will still be there when the incident clears.
#
# A function rather than three copies of the sentence, because three copies is how two of them
# eventually say different things.
_adb_rs_outage_hint() {
  echo "repo-settings: if the API itself is degraded (see https://www.githubstatus.com/) this clears on its own — that is a platform incident, not a settings problem, and nothing here needs changing." >&2
}

# cmd_automerge_ok — the runtime guard /implement-issue calls BEFORE `gh pr merge --auto`. Every
# reading is fresh (verify-before-asserting): a settings change since the last apply is exactly
# what this must catch. Fails CLOSED — an unreadable state is 20, never 0.
cmd_automerge_ok() {
  require_gh
  local branch nwant nlive want live phantom ungated
  repo_json >/dev/null || { echo "repo-settings: cannot read the repo object — refusing to arm auto-merge" >&2; _adb_rs_outage_hint; return 20; }
  branch="$(target_branch)" || { echo "repo-settings: cannot resolve the default branch — refusing to arm auto-merge" >&2; _adb_rs_outage_hint; return 20; }
  read_protection "$branch"
  case "$PROT_STATE" in
    error|forbidden)
      # `forbidden` means the protection exists but we may not read it — that is "unreadable",
      # not "unprotected". Reporting 11 here would send the operator to `baseline repo apply`,
      # which they have no permission to run.
      echo "repo-settings: cannot read branch protection on '$branch' — refusing to arm auto-merge" >&2
      _adb_rs_outage_hint
      return 20 ;;
  esac

  if [ "$(repo_field .allow_auto_merge)" != "true" ]; then
    echo "repo-settings: allow_auto_merge is off on $REPO_SLUG — run 'baseline repo apply'" >&2
    return 10
  fi
  live="$(live_contexts)"
  # FAIL CLOSED on an unreadable DESIRED set exactly as this guard already does on an unreadable
  # LIVE one. Without this, a blind parse yields nwant=0 and the guard returns 12 ("no CI at all"),
  # which is a confident claim about a repo whose CI it simply could not read — and 12 sends the
  # operator to a different remedy entirely. 20 is the code that already means "fail closed".
  if ! _adb_rs_discover "$branch" 2>/dev/null; then
    echo "repo-settings: check discovery failed — cannot build the desired context set, refusing to arm auto-merge (run 'baseline repo checks')" >&2
    return 20
  fi
  want="$RS_WANT"
  nlive="$(nlines "$live")"
  nwant="$(nlines "$want")"

  if [ "$nlive" -gt 0 ]; then
    # Non-empty is NOT sufficient. A required context that nothing reports hangs the PR forever,
    # and that is this module's own headline failure mode (a renamed CI job leaves the old context
    # required). Arming a PR that can never merge is worse than not arming it, so the guard asks
    # the same question `status` does — is the live set actually satisfiable? — rather than a
    # shallower one. Same comparison, one home: see phantom_contexts.
    ungated="$(ungated_contexts "$want" "$live")"
    if [ -n "$ungated" ]; then
      echo "repo-settings: '$branch' has discovered job(s) that are NOT required:" >&2
      printf '%s\n' "$ungated" | sed 's/^/  - /' >&2
      echo "repo-settings: auto-merge could land a PR while those are red. Run 'baseline repo apply'." >&2
      return 14
    fi
    phantom="$(phantom_contexts "$want" "$live")"
    if [ -n "$phantom" ]; then
      echo "repo-settings: '$branch' requires context(s) no discovered workflow job reports:" >&2
      printf '%s\n' "$phantom" | sed 's/^/  - /' >&2
      echo "repo-settings: an armed PR would wait for them forever. If these belong to an external" >&2
      echo "repo-settings: CI provider they will report and you can merge normally; if a job was" >&2
      echo "repo-settings: renamed or removed, run 'baseline repo apply --prune'." >&2
      return 13
    fi
    return 0
  fi

  if [ "$nwant" -gt 0 ]; then
    # CI exists, nothing is required: `--auto` would arm a merge no check can block.
    echo "repo-settings: CI exists but no required status checks on '$branch' — arming auto-merge would gate nothing; run 'baseline repo apply'" >&2
    return 11
  fi
  # No CI at all: `--auto` on a PR that is already mergeable merges it IMMEDIATELY (GitHub refuses
  # to *queue* a clean PR). That is a plain merge wearing an auto-merge label, so refuse and let
  # the operator decide.
  echo "repo-settings: no PR-triggered CI in this repo — auto-merge would merge immediately; merge manually" >&2
  return 12
}

# cmd_merge_flag — print the `gh pr merge` flag this repo actually allows. Merge methods are three
# independently-configurable repo settings, so a hardcoded --squash is simply rejected wherever
# squash merging is disabled: the guard says "safe", the merge command fails, and auto-merge is
# never armed. Preference order matches the baseline's own convention (squash first), but the
# repo's settings decide. No enabled method -> non-zero, and the caller must not merge.
cmd_merge_flag() {
  require_gh
  repo_json >/dev/null || { echo "repo-settings: cannot read the repo object" >&2; return 20; }
  [ "$(repo_field .allow_squash_merge)" = "true" ] && { printf '%s\n' "--squash"; return 0; }
  [ "$(repo_field .allow_merge_commit)" = "true" ] && { printf '%s\n' "--merge";  return 0; }
  [ "$(repo_field .allow_rebase_merge)" = "true" ] && { printf '%s\n' "--rebase"; return 0; }
  echo "repo-settings: no merge method is enabled on $REPO_SLUG — a PR cannot be merged at all" >&2
  return 15
}

# cmd_required_drift — the EARLY half of code 14 (#122). `automerge-ok` asks the same question at
# merge time, when the answer costs a manual detour; this asks it on the PR that introduces the
# job, where the fix is one command. One comparison, one home: it calls the same
# `ungated_contexts` both `status` and `automerge-ok` use, so the lint can never be shallower than
# the guard it front-runs.
# _adb_rs_drift_info — `adb_info`, except that under --porcelain it says nothing.
#
# `adb_info` prints to STDOUT (common.sh:43), and under --porcelain stdout is a DATA channel: one
# context name per line, consumed by a caller that will splice it into an advisory. A single
# "no drift" sentence landing there would arrive as a context named `repo-settings: all 27
# discovered job(s)…` — so suppression here is what makes the contract "stdout is names" true,
# not a cosmetic quiet flag. The diagnostics that matter are unaffected: every skip reason and
# every fail-closed explanation already goes to STDERR and still does.
_adb_rs_drift_info() {
  [ "$OPT_PORCELAIN" -eq 1 ] && return 0
  adb_info "$@"
}

cmd_required_drift() {
  require_gh
  local branch want ungated nwant
  repo_json >/dev/null || { echo "repo-settings: cannot read the repo object — cannot check required-check drift" >&2; return 20; }
  branch="$(target_branch)" || { echo "repo-settings: cannot resolve the default branch — cannot check required-check drift" >&2; return 20; }

  # Discovery's stderr is NOT swallowed: every "skipping <job> — <reason>" line is the only
  # explanation for a job missing from the desired set, and this runs in CI where the log is the
  # whole diagnostic. Hiding them is how a parser that stopped seeing a job looks like a repo that
  # stopped having one.
  # FAIL CLOSED, and this is the call site that most needs it: this lint EXISTS to catch a
  # discovered job that stayed non-required, so a discovery that went blind produces nwant=0 and
  # the lint returns 0 — reporting "in sync" about a comparison it never made. That is #102's
  # exact shape one level up, and it is why the backstop that was supposed to catch #102 could not.
  if ! _adb_rs_discover "$branch"; then
    echo "repo-settings: check discovery failed — cannot compare discovered jobs against the required set (run 'baseline repo checks')" >&2
    return 20
  fi
  want="$RS_WANT"
  nwant="$(nlines "$want")"

  # A repo with NO workflow files makes no claim this lint could contradict, so it exits before
  # the live read — both because there is nothing to check and because #24 says such a repo must
  # never be deadlocked by tooling that assumes CI exists. Failing it closed on an unreadable
  # branch would do exactly that, over a question it does not even have.
  #
  # This is also the case that keeps entirely-EXTERNAL CI (contexts from CircleCI/Vercel, no
  # .github/workflows) passing. Discovery finding nothing when files ARE present is a different
  # story, handled after the read.
  if [ "$nwant" -eq 0 ] && ! _adb_rs_has_workflow_files; then
    _adb_rs_drift_info "repo-settings: no workflow files to discover on '$branch' — nothing to require"
    return 0
  fi

  read_branch "$branch"
  case "$BR_STATE" in
    error)
      echo "repo-settings: cannot read branch '$branch' — required-check drift is UNVERIFIED (failing closed)" >&2
      return 20 ;;
    opaque)
      echo "repo-settings: branch '$branch' is protected, but its required-check list could not be read" >&2
      echo "repo-settings: refusing to guess — a list we cannot see is NOT an empty one (failing closed)" >&2
      echo "repo-settings: run 'baseline repo status' with an admin token to see the live set" >&2
      return 20 ;;
  esac

  # Workflow files exist but discovery produced nothing. Passing that green unconditionally is a
  # fail-open in exactly the shape this lint exists to catch — a gate that silently stopped
  # gating — but failing it unconditionally is worse, and wrong on its own terms: this command
  # documents that it does NOT fail on external-provider contexts, and a repo can legitimately
  # hold a schedule-only workflow while CircleCI supplies the required PR context. Files present
  # + contexts required is therefore NOT yet a contradiction.
  #
  # What makes it one is PROVENANCE: a required context that GitHub Actions itself reported on
  # this branch must have come from a workflow in this tree, so discovery finding none of them
  # means the parser stopped seeing jobs it used to see (a reindent, a trigger change). Contexts
  # that Actions never reported belong to somebody else and are none of this lint's business.
  if [ "$nwant" -eq 0 ]; then
    if [ -n "$BR_CONTEXTS" ]; then
      local cr_json cls shared murky
      # BOTH the read and the PARSE must succeed. Testing only the read is how the fail-open came
      # back: `gh` can exit 0 with a body jq cannot parse (a proxy or GHES error page served as
      # 200, a truncated --paginate stream), and an unparseable body classifies as nothing at all,
      # which reads as "no Actions contexts" and passes as external CI.
      if ! cr_json="$(_adb_rs_checkruns "$branch")" \
         || ! cls="$(printf '%s' "$cr_json" | _adb_rs_classify_contexts)"; then
        echo "repo-settings: discovery found no PR-triggered jobs and '$branch' requires $(nlines "$BR_CONTEXTS") context(s)," >&2
        echo "repo-settings: but the check runs that would say who produced them could not be read." >&2
        echo "repo-settings: refusing to guess which side is wrong (failing closed)." >&2
        return 20
      fi
      shared="$(shared_contexts "$BR_CONTEXTS" "$(printf '%s' "$cls" | _adb_rs_pick actions)")"
      if [ -n "$shared" ]; then
        echo "repo-settings: discovery found NO PR-triggered jobs, yet '$branch' requires context(s) that" >&2
        echo "repo-settings: GitHub Actions reported on this very branch:" >&2
        printf '%s\n' "$shared" | sed 's/^/  - /' >&2
        echo "repo-settings: those two cannot both be right — an Actions-reported context comes from a" >&2
        echo "repo-settings: workflow in this tree, so the parser has stopped seeing jobs it used to see." >&2
        echo "repo-settings: See the skip reasons above; refusing to report 'no drift' (failing closed)." >&2
        return 20
      fi
      # Before declaring the rest external, account for the ones nobody can attribute. Computed
      # here rather than beside `shared` so the arm above can return without paying for it.
      murky="$(shared_contexts "$BR_CONTEXTS" "$(printf '%s' "$cls" | _adb_rs_pick unknown)")"
      if [ -n "$murky" ]; then
        echo "repo-settings: discovery found NO PR-triggered jobs, and '$branch' requires context(s) whose" >&2
        echo "repo-settings: producing app the API did not identify:" >&2
        printf '%s\n' "$murky" | sed 's/^/  - /' >&2
        echo "repo-settings: an unattributable context is not proof of external CI, so treating it as" >&2
        echo "repo-settings: 'not our business' would pass over a gate that may have stopped gating." >&2
        echo "repo-settings: refusing to report 'no drift' (failing closed). Remedy: re-run once the" >&2
        echo "repo-settings: producing app reports again, or drop the context if its app is gone:" >&2
        echo "repo-settings:   baseline repo apply --prune" >&2
        return 20
      fi
      # Every required context came from outside Actions — an external provider. Out of scope by
      # this command's own contract, so this is a clean pass, not a grudging one.
      #
      # KNOWN LIMITATION (#182): this reasons from "an Actions-reported context comes from a
      # workflow in THIS tree", which an organization/enterprise ruleset can break by requiring a
      # workflow sourced from another repository. Such a repo, with empty local discovery, fails
      # closed at the `shared` branch above rather than passing — deliberately the safe direction,
      # though the message there blames this repo's parser. #179 made that case reachable for the
      # first time (before it, the attribution literal was wrong, so the arm never fired).
      _adb_rs_drift_info "repo-settings: no discoverable PR-triggered jobs on '$branch'; its $(nlines "$BR_CONTEXTS") required context(s) are not Actions-reported (external CI) — nothing to require"
      return 0
    fi
    _adb_rs_drift_info "repo-settings: no discoverable PR-triggered jobs on '$branch' — nothing to require"
    return 0
  fi

  ungated="$(ungated_contexts "$want" "$BR_CONTEXTS")"
  if [ -z "$ungated" ]; then
    _adb_rs_drift_info "repo-settings: all $nwant discovered job(s) are required on '$branch' — no drift"
    return 0
  fi
  # PORCELAIN: the names, on stdout, and nothing else. The exit code is still 14 — this is a
  # different RENDERING of the same verdict, never a different verdict, so a caller cannot get a
  # softer answer by asking for it in this shape. What is deliberately withheld is the REMEDY: it
  # names `baseline repo apply`, which is right on the default branch and harmful from a PR branch,
  # and the caller that asked for porcelain is the one that has to say something else instead.
  if [ "$OPT_PORCELAIN" -eq 1 ]; then
    printf '%s\n' "$ungated"
    return 14
  fi
  if [ "$BR_STATE" = "unprotected" ]; then
    echo "repo-settings: branch '$branch' has NO protection, so none of its CI gates anything." >&2
  fi
  echo "repo-settings: $(nlines "$ungated") discovered job(s) on '$branch' are NOT required — they gate nothing:" >&2
  printf '%s\n' "$ungated" | sed 's/^/  - /' >&2
  echo "repo-settings: a PR could merge while these are red. Remedy:" >&2
  echo "repo-settings:   baseline repo apply           # add the missing context(s)" >&2
  echo "repo-settings: If a job was RENAMED, the old context is now also required-but-never-reported;" >&2
  echo "repo-settings: 'baseline repo status' shows that direction and 'baseline repo apply --prune' clears it." >&2
  echo "repo-settings: Then RE-RUN this check — it reads live state, so it only clears once the settings change." >&2
  return 14
}

cmd_checks() {
  local branch
  # `checks` is the one subcommand that must work with NO network: it is pure file discovery, and
  # the offline test drives it. Resolve the branch from git, not from the API.
  branch="${OPT_BRANCH:-$(adb_default_branch "$(adb_repo_root)")}"
  discover_checks "$branch"
}

# cmd_branch_required_contexts — stdin: a 200 body from `repos/{slug}/branches/{branch}`.
# Prints ONE line of JSON: the required-status-context set as an array, or `null`.
#
# WHY THIS EXISTS (#115). `branch-health` used to infer "this repo has no CI" from
# `actions/workflows`, an ACTIONS-ONLY inventory — so a CircleCI/Buildkite/Jenkins repo read as
# `no-ci`, the health condition was skipped, and /roadmap emitted a release cut against a branch
# nobody had checked. The required-context set is the provider-agnostic evidence: whoever reports
# it, a declared context is a declaration that CI exists.
#
# THE OUTPUT IS JSON, not a word plus lines, because the consumer splices it straight into
# `branch-health`'s stdin document with `--argjson`. A shell-side list would have to be re-quoted
# into JSON at the call site, and a context name legitimately contains spaces, `/` and `:` — which
# is precisely where a hand-rolled join goes wrong.
#
# THE THREE ANSWERS, and why `null` is not `[]`:
#   [...]  `checks` — the branch declares these contexts. AUTHORITATIVE, even when empty.
#   []     `unprotected`, or classic protection with checks off — AUTHORITATIVELY nothing declared.
#   null   `opaque` — protected by something this endpoint does not describe (a repository
#          RULESET), or a body that would not parse. NOT the same as "nothing is required":
#          collapsing it to `[]` would let a ruleset-protected repo reach `no-ci` and cut on an
#          unverified branch, which is the fail-open this whole change removes. `branch-health`
#          fails closed on `null` and the owner opt-out deliberately cannot excuse it.
#
# PURE: jq only. No gh, no auth, no network — the caller owns the read, exactly as `branch-health`
# and every other /roadmap predicate are pure. That is also what lets the offline suites drive it
# with the same fixtures `read_branch` uses.
cmd_branch_required_contexts() {
  [ "$#" -eq 0 ] || { echo "repo-settings: branch-required-contexts takes no arguments (branch JSON on stdin)" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "repo-settings: jq is required" >&2; exit 1; }
  local out state
  out="$(_adb_rs_classify_branch)"
  state="${out%%$'\n'*}"
  case "$state" in
    # Line 2 is already the canonical JSON array — pass it through rather than rebuilding it from
    # text. Rebuilding is what split a context containing a newline into two phantom requirements.
    checks)      printf '%s' "$out" | sed -n '2p' ;;
    unprotected) printf '[]\n' ;;
    *)           printf 'null\n' ;;
  esac
}

# --- arg parsing ---------------------------------------------------------------------------
# Per-subcommand on purpose (the sibling release-convention.sh precedent): a shared parser would
# make `status --dry-run` and `checks --strict` silently valid. Two parsers, ONE copy of each
# shared option body — the value-taking arms live in helpers so the two can't drift.
#
# _adb_rs_valopt <flag> <count> <value> — validate a value-taking option; echoes the value.
# It RETURNS non-zero rather than exiting: callers invoke it in a command substitution, and an
# `exit` there would only kill the subshell, silently accepting the bad option.
_adb_rs_valopt() {
  local flag="$1" count="$2" value="$3"
  [ "$count" -ge 2 ] || { echo "repo-settings: $flag needs a value" >&2; return 2; }
  [ -n "$(printf '%s' "$value" | tr -d '[:space:]')" ] \
    || { echo "repo-settings: $flag must not be empty" >&2; return 2; }
  printf '%s' "$value"
}

parse_apply_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)        OPT_DRY_RUN=1 ;;
      --prune)          OPT_PRUNE=1 ;;
      --strict)         OPT_STRICT=1 ;;
      --enforce-admins) OPT_ENFORCE_ADMINS=1 ;;
      --branch)         OPT_BRANCH="$(_adb_rs_valopt --branch "$#" "${2:-}")" || exit 2; shift ;;
      --workflow-dir)   OPT_WORKFLOW_DIR="$(_adb_rs_valopt --workflow-dir "$#" "${2:-}")" || exit 2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "repo-settings: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

parse_read_opts() {   # the read subcommands: --branch / --workflow-dir / --porcelain / --help only
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)       OPT_BRANCH="$(_adb_rs_valopt --branch "$#" "${2:-}")" || exit 2; shift ;;
      --workflow-dir) OPT_WORKFLOW_DIR="$(_adb_rs_valopt --workflow-dir "$#" "${2:-}")" || exit 2; shift ;;
      --porcelain)    OPT_PORCELAIN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "repo-settings: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

# ONE parser, and the scoping is enforced here rather than by a second copy of it (golden rule 4).
# `--porcelain` reshapes ONE command's stdout, so the four other read subcommands must REFUSE it,
# not ignore it: an accepted-but-inert flag is a promise the output changed when it did not, and
# `branch-required-contexts` already refuses `--branch` for exactly that reason. Symmetric with the
# apply-only `--dry-run`/`--prune`, which `parse_read_opts` rejects as unknown.
_adb_rs_no_porcelain() {
  [ "$OPT_PORCELAIN" -eq 0 ] && return 0
  echo "repo-settings: --porcelain is only meaningful for 'required-drift' (not '$1')" >&2
  exit 2
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  checks)         parse_read_opts "$@";  _adb_rs_no_porcelain checks;       cmd_checks ;;
  status)         parse_read_opts "$@";  _adb_rs_no_porcelain status;       cmd_status ;;
  automerge-ok)   parse_read_opts "$@";  _adb_rs_no_porcelain automerge-ok; cmd_automerge_ok ;;
  required-drift) parse_read_opts "$@";  cmd_required_drift ;;
  merge-flag)     parse_read_opts "$@";  _adb_rs_no_porcelain merge-flag;   cmd_merge_flag ;;
  # Deliberately NOT through parse_read_opts: this one takes no options at all (the caller already
  # chose the branch when it made the read), and accepting `--branch` would advertise a knob that
  # cannot affect a body that is already on stdin.
  branch-required-contexts) cmd_branch_required_contexts "$@" ;;
  apply)          parse_apply_opts "$@"; cmd_apply ;;
  -h|--help)      usage; exit 0 ;;
  *) echo "repo-settings: unknown subcommand '$SUB' (expected 'checks', 'status', 'apply', 'automerge-ok', 'required-drift', 'merge-flag', or 'branch-required-contexts')" >&2
     usage >&2; exit 2 ;;
esac
