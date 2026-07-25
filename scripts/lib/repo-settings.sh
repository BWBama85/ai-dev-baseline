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
#   repo-settings.sh apply [--dry-run] [--branch NAME] [--strict] [--enforce-admins]
#                                        # required checks FIRST, then allow_auto_merge
#   repo-settings.sh automerge-ok        # runtime guard: is it safe to arm auto-merge?
#   repo-settings.sh -h | --help
#
# `automerge-ok` exit codes are a stable machine contract for the workflow step:
#   0  safe    — auto-merge enabled AND required checks configured on the default branch
#   10 unsafe  — the repo has allow_auto_merge off (nothing to arm)
#   11 unsafe  — CI exists but NO required checks: `--auto` would arm an ungated merge
#   12 unsafe  — the repo has no PR-triggered CI at all: `--auto` would merge immediately
#   20 unknown — live state could not be read; FAIL CLOSED, never assume safe
#
# What this file must never grow: it is repo *settings* bookkeeping. It does not merge, review,
# tag, release, or deploy. It only reads .github/workflows and writes two GitHub settings.
#
# Requires: gh (authenticated, admin on the target repo), jq.

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

REPO_SLUG=""
REPO_JSON=""

# Fail loud on a missing/unauthenticated gh or an unresolvable remote — never a silent no-op.
# Caches REPO_SLUG once (the resolve doubles as the remote check), like release-convention.sh.
require_gh() {
  command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found on PATH" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)" >&2; exit 1; }
  REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; exit 1; }
  [ -n "$REPO_SLUG" ] || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; exit 1; }
}

repo_slug() { printf '%s' "$REPO_SLUG"; }

# repo_json — the repo object, read ONCE per run. Carries three things every subcommand needs:
# .default_branch, .allow_auto_merge, and .permissions.admin. The admin bit matters because GitHub
# returns 404 for BOTH "this branch has no protection" and "you may not see its protection" —
# without the permission probe the library would misread a permission error as "unprotected",
# stand protection up, and fail mid-write having already changed something.
repo_json() {
  if [ -z "$REPO_JSON" ]; then
    REPO_JSON="$(gh api "repos/$(repo_slug)" 2>/dev/null)" || return 1
    [ -n "$REPO_JSON" ] || return 1
  fi
  printf '%s' "$REPO_JSON"
}

repo_field() { repo_json | jq -r "$1" 2>/dev/null; }

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
# Indentation is the grammar: job keys sit at exactly 2 spaces INSIDE the `jobs:` block, job
# properties at exactly 4. Scoping to `jobs:` is not a nicety — `on:` puts `push:` and
# `pull_request:` at the very same 2-space indent, so a whole-file indent scan harvests those two
# as "jobs" and requires contexts that can never report. This repo's own ci.yml is that case.
#
# Two passes per file: the file-level verdict is only complete at END (triggers can appear after
# `jobs:`), and emitting a job from a file that turns out never to run on a PR is the phantom
# context above. Two cheap passes over a few-KB file beat threading a buffer through every print.

# _adb_rs_file_verdict <file> <target-branch> -> "" when the file's jobs report on every PR to
# <target-branch>, else the human-readable reason it was skipped.
_adb_rs_file_verdict() {
  awk -v target="$2" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    # Parse an inline YAML flow sequence "[a, b]" into the given array.
    function flow_list(s, arr,   n, i, v, parts) {
      sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) { v = unquote(trim(parts[i])); if (v != "") arr[v] = 1 }
    }
    /^[[:space:]]*(#|$)/ { next }
    /^[^[:space:]]/ {
      key = $0; sub(/:.*$/, "", key); sect = unquote(trim(key))
      rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
      # Inline forms: "on: push" and "on: [push, pull_request]".
      if (sect == "on" && rest != "") {
        if (rest ~ /^\[/) flow_list(rest, triggers); else triggers[unquote(rest)] = 1
      }
      trigger = ""; in_branches = 0; next
    }
    sect == "on" {
      if ($0 ~ /^  [^[:space:]]/) {                       # a trigger name at 2 spaces
        trigger = $0; sub(/:.*$/, "", trigger); trigger = unquote(trim(trigger))
        triggers[trigger] = 1; in_branches = 0; next
      }
      if (trigger == "pull_request" || trigger == "pull_request_target") {
        if ($0 ~ /^    (paths|paths-ignore):/) { pr_paths = 1;     in_branches = 0; next }
        if ($0 ~ /^    branches-ignore:/)      { pr_br_ignore = 1; in_branches = 0; next }
        if ($0 ~ /^    branches:/) {
          pr_branches = 1
          rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
          if (rest ~ /^\[/) flow_list(rest, brs)
          in_branches = 1; next
        }
        if (in_branches && $0 ~ /^      -[[:space:]]/) {  # block-sequence branch entry
          v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); brs[unquote(trim(v))] = 1; next
        }
        if ($0 !~ /^      /) in_branches = 0
      }
      next
    }
    END {
      if (!("pull_request" in triggers) && !("pull_request_target" in triggers)) {
        print "no pull_request trigger"; exit
      }
      if (pr_paths)     { print "pull_request carries a paths/paths-ignore filter (it does not run for every PR)"; exit }
      if (pr_br_ignore) { print "pull_request carries a branches-ignore filter (cannot prove it runs for " target ")"; exit }
      # A branches: filter is fine as long as it provably includes the target branch. "*" / "**"
      # match it; an explicit list must name it. Anything else (a partial glob) is unprovable.
      if (pr_branches && !(target in brs) && !("*" in brs) && !("**" in brs)) {
        print "pull_request branches filter does not provably include " target; exit
      }
    }
  ' "$1"
}

# _adb_rs_jobs <file> -> TAB records "CHECK\t<context>" / "SKIP\t<job>\t<reason>".
_adb_rs_jobs() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function flush_job() {
      if (job == "") return
      if (job_uses)         printf "SKIP\t%s\tcalls a reusable workflow (its check names come from the callee)\n", job
      else if (job_if)      printf "SKIP\t%s\thas a job-level if: (it may be skipped, and a required check that never reports blocks the PR forever)\n", job
      else if (job_matrix)  printf "SKIP\t%s\tis a matrix job (its check-run names carry a matrix suffix)\n", job
      else if (job_dynamic) printf "SKIP\t%s\thas a name: containing a ${{ }} expression (not statically knowable)\n", job
      else                  printf "CHECK\t%s\n", (job_name != "" ? job_name : job)
      job = ""
    }
    /^[[:space:]]*(#|$)/ { next }
    /^[^[:space:]]/ {
      flush_job()
      key = $0; sub(/:.*$/, "", key); sect = unquote(trim(key)); next
    }
    sect == "jobs" {
      if ($0 ~ /^  [^[:space:]]/) {                       # job key at exactly 2 spaces
        flush_job()
        job = $0; sub(/:.*$/, "", job); job = unquote(trim(job))
        job_name = ""; job_if = 0; job_matrix = 0; job_uses = 0; job_dynamic = 0
        next
      }
      if (job == "") next
      # Exactly 4 spaces and no leading "-": the JOB name. A step name is "      - name:" at 6+
      # spaces behind a dash, so it can never be mistaken for the job name here.
      if ($0 ~ /^    name:/) {
        v = $0; sub(/^[[:space:]]*name:/, "", v); v = unquote(trim(v))
        if (v ~ /\$\{\{/) job_dynamic = 1
        job_name = v; next
      }
      if ($0 ~ /^    if:/)       { job_if = 1;     next }
      if ($0 ~ /^    uses:/)     { job_uses = 1;   next }
      # Under strategy:. Keyed on `matrix:` itself, so a bare `strategy: {fail-fast: false}` —
      # which does NOT change the check-run name — is not skipped for nothing.
      if ($0 ~ /^      matrix:/) { job_matrix = 1; next }
      next
    }
    END { flush_job() }
  ' "$1"
}

# workflow_dir — .github/workflows under the repo root the caller is in. ADB_RS_WORKFLOW_DIR
# overrides it so the offline check can point discovery at a fixture tree.
workflow_dir() {
  if [ -n "${ADB_RS_WORKFLOW_DIR:-}" ]; then printf '%s' "$ADB_RS_WORKFLOW_DIR"; return 0; fi
  printf '%s/.github/workflows' "$(adb_repo_root)"
}

# discover_checks <branch> — the desired required-check contexts, one per line on stdout. Skips
# (per file and per job) go to stderr so stdout stays machine-consumable. Returns 0 even when it
# finds nothing: "this repo has no CI" is a legitimate state (#24), not an error — callers
# distinguish empty output from failure.
discover_checks() {
  local branch="$1" dir f verdict found=0
  dir="$(workflow_dir)"
  [ -d "$dir" ] || { printf 'repo-settings: no %s — treating this repo as having no CI\n' "$dir" >&2; return 0; }
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue          # filters an unmatched literal glob (no portable nullglob)
    found=1
    verdict="$(_adb_rs_file_verdict "$f" "$branch")"
    if [ -n "$verdict" ]; then
      printf 'repo-settings: skipping %s — %s\n' "${f##*/}" "$verdict" >&2
      continue
    fi
    _adb_rs_jobs "$f" | while IFS="$(printf '\t')" read -r kind a b; do
      case "$kind" in
        CHECK) [ -n "$a" ] && printf '%s\n' "$a" ;;
        SKIP)  printf 'repo-settings: skipping job %s (%s) — %s\n' "$a" "${f##*/}" "$b" >&2 ;;
      esac
    done
  done
  [ "$found" -eq 1 ] || printf 'repo-settings: no workflow files in %s — treating this repo as having no CI\n' "$dir" >&2
  return 0
}

# --- live protection state --------------------------------------------------------------------

PROT_JSON=""
PROT_STATE=""   # protected-with-checks | protected-no-checks | unprotected | forbidden | error

# read_protection <branch> — classify the branch's protection ONCE. GitHub's 404 is ambiguous (no
# protection OR no permission to see it), so it is disambiguated against the repo object's
# .permissions.admin rather than assumed. Fail-closed: an unreadable repo object is `error`, never
# "unprotected" — which would send `apply` down the stand-up-from-scratch path on a repo it cannot
# actually read.
read_protection() {
  local branch="$1" out rc admin
  admin="$(repo_field .permissions.admin)" || admin=""
  out="$(gh api "repos/$(repo_slug)/branches/$branch/protection" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    PROT_JSON="$out"
    if printf '%s' "$out" | jq -e '.required_status_checks != null' >/dev/null 2>&1; then
      PROT_STATE="protected-with-checks"
    else
      PROT_STATE="protected-no-checks"
    fi
    return 0
  fi
  PROT_JSON=""
  case "$admin" in
    true)  PROT_STATE="unprotected" ;;
    false) PROT_STATE="forbidden" ;;
    *)     PROT_STATE="error" ;;
  esac
  return 0
}

live_contexts() {   # the contexts currently required, sorted, one per line (empty when none)
  [ -n "$PROT_JSON" ] || return 0
  printf '%s' "$PROT_JSON" | jq -r '.required_status_checks.contexts // [] | .[]' 2>/dev/null | LC_ALL=C sort
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

# contexts_json <contexts-file> — the {strict, contexts} object every write path shares.
contexts_json() {
  jq -n --argjson strict "$([ "$OPT_STRICT" -eq 1 ] && echo true || echo false)" \
        --rawfile ctx "$1" \
        '{strict: $strict, contexts: ($ctx | split("\n") | map(select(length > 0)))}'
}

# write_required_checks <branch> <contexts-file> — set the required contexts through the NARROWEST
# endpoint that works, because the wide one is destructive:
#
#   protected-with-checks -> PATCH …/protection/required_status_checks
#        Touches only the status-check sub-resource. Nothing else can be lost.
#   protected-no-checks   -> PUT …/protection with a body REBUILT FROM THE LIVE OBJECT
#        There is no status-check sub-resource to PATCH when the branch has none, so the full PUT
#        is the only path — and a full PUT REPLACES the whole protection object. Every key omitted
#        is reset: omitting required_pull_request_reviews removes "require a PR before merging"
#        (the no-direct-push-to-main guardrail this whole baseline rests on); omitting
#        required_conversation_resolution turns thread resolution off. So the body is
#        read-modify-write, never a fresh literal.
#   unprotected           -> PUT …/protection standing protection up with conservative defaults
#
# (required_signatures is deliberately absent from the PUT body: it is a separate endpoint, and a
# PUT does not reset it.)
write_required_checks() {
  local branch="$1" ctxfile="$2" body
  case "$PROT_STATE" in
    protected-with-checks)
      body="$(contexts_json "$ctxfile")" \
        || { echo "ERROR: could not build the required_status_checks body" >&2; return 1; }
      adb_info "  required checks -> PATCH branches/$branch/protection/required_status_checks (narrow; nothing else touched)"
      run_gh "set required checks" "$body" \
        api -X PATCH "repos/$(repo_slug)/branches/$branch/protection/required_status_checks" --input - \
        || { echo "ERROR: could not set required status checks" >&2; return 1; }
      ;;
    protected-no-checks)
      body="$(printf '%s' "$PROT_JSON" | jq \
                --argjson checks "$(contexts_json "$ctxfile")" \
                --argjson admins "$([ "$OPT_ENFORCE_ADMINS" -eq 1 ] && echo true || echo false)" '
        {
          required_status_checks: $checks,
          enforce_admins: (if $admins then true else (.enforce_admins.enabled // false) end),
          required_pull_request_reviews:
            (if .required_pull_request_reviews == null then null else {
               dismiss_stale_reviews:           (.required_pull_request_reviews.dismiss_stale_reviews // false),
               require_code_owner_reviews:      (.required_pull_request_reviews.require_code_owner_reviews // false),
               require_last_push_approval:      (.required_pull_request_reviews.require_last_push_approval // false),
               required_approving_review_count: (.required_pull_request_reviews.required_approving_review_count // 0)
             } end),
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
        || { echo "ERROR: could not rebuild the protection body from the live object" >&2; return 1; }
      adb_info "  required checks -> PUT branches/$branch/protection (read-modify-write; every existing setting preserved)"
      run_gh "set required checks (full protection PUT)" "$body" \
        api -X PUT "repos/$(repo_slug)/branches/$branch/protection" --input - \
        || { echo "ERROR: could not set required status checks" >&2; return 1; }
      ;;
    unprotected)
      body="$(jq -n --argjson checks "$(contexts_json "$ctxfile")" \
                    --argjson admins "$([ "$OPT_ENFORCE_ADMINS" -eq 1 ] && echo true || echo false)" '
        {
          required_status_checks: $checks,
          enforce_admins: $admins,
          # A PR is required before merging, with zero required approvals: that enforces the
          # feature-branch rule without inventing a review requirement the repo never had.
          required_pull_request_reviews: {required_approving_review_count: 0},
          restrictions: null,
          required_conversation_resolution: true,
          allow_force_pushes: false,
          allow_deletions: false
        }')" \
        || { echo "ERROR: could not build the protection body" >&2; return 1; }
      adb_info "  required checks -> PUT branches/$branch/protection (standing protection up from scratch)"
      run_gh "stand up branch protection" "$body" \
        api -X PUT "repos/$(repo_slug)/branches/$branch/protection" --input - \
        || { echo "ERROR: could not stand up branch protection" >&2; return 1; }
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
  local branch="$1"
  adb_info ""
  adb_info "No admin permission on $(repo_slug) — nothing was changed. Ask an admin to run:"
  adb_info "  baseline repo checks    # the exact context names to require"
  adb_info "  gh api -X PATCH repos/$(repo_slug)/branches/$branch/protection/required_status_checks \\"
  adb_info "    -F strict=false -f 'contexts[]=<each name above>'"
  adb_info "  gh api -X PATCH repos/$(repo_slug) -F allow_auto_merge=true"
  adb_info "…in that order: required checks FIRST, or auto-merge lands PRs with nothing gating them."
}

cmd_apply() {
  require_gh
  local branch ctxfile n admin
  repo_json >/dev/null || { echo "ERROR: could not read repos/$(repo_slug)" >&2; exit 1; }
  branch="$(target_branch)" || { echo "ERROR: could not resolve the target branch" >&2; exit 1; }

  # Probe permission BEFORE any write, so a non-admin run never flips one setting and then fails
  # on the other, leaving the repo in the exact half-configured state this file exists to prevent.
  admin="$(repo_field .permissions.admin)"
  adb_info "Repo settings for $(repo_slug) (branch '$branch'):"
  if [ "$admin" != "true" ]; then
    manual_commands "$branch"
    return 1
  fi

  ctxfile="$(mktemp -t adb-rs-ctx.XXXXXX)" || { echo "ERROR: could not create a temp file" >&2; exit 1; }
  # shellcheck disable=SC2064  # expand $ctxfile NOW: the trap must survive the variable's scope
  trap "rm -f '$ctxfile'" EXIT
  discover_checks "$branch" | LC_ALL=C sort -u > "$ctxfile"
  n="$(nlines "$(cat "$ctxfile")")"

  read_protection "$branch"
  if [ "$n" -eq 0 ]; then
    # No CI (#24): skip the checks write entirely and DO NOT BLOCK. Enabling auto-merge is still
    # correct — it is a repo capability, not an arming — and `automerge-ok` returns 12 here, so
    # /implement-issue will not arm a merge that would land instantly with nothing gating it.
    adb_info "  required checks -> SKIPPED (no PR-triggered CI discovered; nothing to require)"
  else
    adb_info "  discovered $n check context(s) from $(workflow_dir)"
    sed 's/^/    - /' "$ctxfile"
    write_required_checks "$branch" "$ctxfile" || {
      echo "ERROR: required checks were NOT set — refusing to enable auto-merge (order is load-bearing)" >&2
      return 1
    }
  fi

  # Only now, and only because the checks write did not fail.
  if [ "$(repo_field .allow_auto_merge)" = "true" ]; then
    adb_info "  allow_auto_merge -> already enabled"
  else
    adb_info "  allow_auto_merge -> enabling"
    run_gh "enable auto-merge" "" api -X PATCH "repos/$(repo_slug)" -F allow_auto_merge=true \
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
  local branch want got missing extra rc=0
  repo_json >/dev/null || { echo "ERROR: could not read repos/$(repo_slug)" >&2; exit 1; }
  branch="$(target_branch)" || { echo "ERROR: could not resolve the target branch" >&2; exit 1; }
  read_protection "$branch"

  want="$(discover_checks "$branch" 2>/dev/null | LC_ALL=C sort -u)"
  got="$(live_contexts)"

  adb_info "Repo settings for $(repo_slug) (branch '$branch'):"
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

  # Drift, BOTH directions. The dangerous one is `extra`: a renamed job leaves the OLD context
  # required and never reported, which blocks every PR forever — GitHub validates nothing and
  # reports nothing, so this command is the only place that failure becomes visible.
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$want" | sed '/^$/d') <(printf '%s\n' "$got" | sed '/^$/d'))"
  extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$want" | sed '/^$/d') <(printf '%s\n' "$got" | sed '/^$/d'))"
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

# cmd_automerge_ok — the runtime guard /implement-issue calls BEFORE `gh pr merge --auto`. Every
# reading is fresh (verify-before-asserting): a settings change since the last apply is exactly
# what this must catch. Fails CLOSED — an unreadable state is 20, never 0.
cmd_automerge_ok() {
  require_gh
  local branch nwant nlive
  repo_json >/dev/null || { echo "repo-settings: cannot read the repo object — refusing to arm auto-merge" >&2; return 20; }
  branch="$(target_branch)" || { echo "repo-settings: cannot resolve the default branch — refusing to arm auto-merge" >&2; return 20; }
  read_protection "$branch"
  [ "$PROT_STATE" = "error" ] && { echo "repo-settings: cannot read branch protection — refusing to arm auto-merge" >&2; return 20; }

  if [ "$(repo_field .allow_auto_merge)" != "true" ]; then
    echo "repo-settings: allow_auto_merge is off on $(repo_slug) — run 'baseline repo apply'" >&2
    return 10
  fi
  nlive="$(nlines "$(live_contexts)")"
  [ "$nlive" -gt 0 ] && return 0

  nwant="$(nlines "$(discover_checks "$branch" 2>/dev/null)")"
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

cmd_checks() {
  local branch
  # `checks` is the one subcommand that must work with NO network: it is pure file discovery, and
  # the offline test drives it. Resolve the branch from git, not from the API.
  branch="${OPT_BRANCH:-$(adb_default_branch "$(adb_repo_root)")}"
  discover_checks "$branch"
}

# --- arg parsing ---------------------------------------------------------------------------
# Per-subcommand on purpose (the sibling release-convention.sh precedent): a shared parser would
# make `status --dry-run` and `checks --strict` silently valid.
parse_apply_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)        OPT_DRY_RUN=1 ;;
      --strict)         OPT_STRICT=1 ;;
      --enforce-admins) OPT_ENFORCE_ADMINS=1 ;;
      --branch)
        [ "$#" -ge 2 ] || { echo "repo-settings: --branch needs a value" >&2; exit 2; }
        shift; OPT_BRANCH="$1"
        [ -n "$(printf '%s' "$OPT_BRANCH" | tr -d '[:space:]')" ] \
          || { echo "repo-settings: --branch must not be empty" >&2; exit 2; }
        ;;
      -h|--help) usage; exit 0 ;;
      *) echo "repo-settings: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

parse_read_opts() {   # checks / status / automerge-ok: --branch and --help only
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)
        [ "$#" -ge 2 ] || { echo "repo-settings: --branch needs a value" >&2; exit 2; }
        shift; OPT_BRANCH="$1"
        [ -n "$(printf '%s' "$OPT_BRANCH" | tr -d '[:space:]')" ] \
          || { echo "repo-settings: --branch must not be empty" >&2; exit 2; }
        ;;
      -h|--help) usage; exit 0 ;;
      *) echo "repo-settings: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  checks)       parse_read_opts "$@";  cmd_checks ;;
  status)       parse_read_opts "$@";  cmd_status ;;
  automerge-ok) parse_read_opts "$@";  cmd_automerge_ok ;;
  apply)        parse_apply_opts "$@"; cmd_apply ;;
  -h|--help)    usage; exit 0 ;;
  *) echo "repo-settings: unknown subcommand '$SUB' (expected 'checks', 'status', 'apply', or 'automerge-ok')" >&2
     usage >&2; exit 2 ;;
esac
