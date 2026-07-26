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
#   repo-settings.sh merge-flag          # the `gh pr merge` flag this repo allows (--squash/…)
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
# Discover from another workflow tree (see workflow_dir).
OPT_WORKFLOW_DIR=""
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
repo_json() {
  if [ -z "$REPO_JSON" ]; then
    REPO_JSON="$(gh api 'repos/{owner}/{repo}' 2>/dev/null)" || return 1
    [ -n "$REPO_JSON" ] || return 1
    REPO_SLUG="$(printf '%s' "$REPO_JSON" | jq -r '.full_name // empty' 2>/dev/null)"
    [ -n "$REPO_SLUG" ] || return 1
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
    # yaml_scalar: a plain YAML scalar as GitHub would read it. A quoted value ends at its closing
    # quote (anything after is a comment); an UNQUOTED value ends at the first whitespace-preceded
    # "#". Without this, `name: Build  # the main build job` becomes the required context
    # "Build  # the main build job" — which nothing ever reports, blocking every PR forever.
    function yaml_scalar(s) {
      s = trim(s)
      if (s ~ /^"/)  { sub(/^"/,  "", s); sub(/".*$/,  "", s); return s }
      if (s ~ /^'"'"'/) { sub(/^'"'"'/, "", s); sub(/'"'"'.*$/, "", s); return s }
      sub(/[[:space:]]+#.*$/, "", s)
      return trim(s)
    }
    # Parse an inline YAML flow sequence "[a, b]" into the given array.
    function flow_list(s, arr,   n, i, v, parts) {
      sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*(#.*)?$/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) {
        v = unquote(trim(parts[i]))
        if (v ~ /^!/) neg_branch = 1
        if (v != "") arr[v] = 1
      }
    }
    /^[[:space:]]*(#|$)/ { next }
    /^[^[:space:]]/ {
      key = $0; sub(/:.*$/, "", key); sect = unquote(trim(key))
      rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
      # Inline forms: "on: push" and "on: [push, pull_request]".
      if (sect == "on" && rest != "") {
        if (rest ~ /^\[/) flow_list(rest, triggers); else triggers[yaml_scalar(rest)] = 1
      }
      trigger = ""; in_branches = 0; next
    }
    sect == "on" {
      if ($0 ~ /^  [^[:space:]]/) {                       # a trigger name at 2 spaces
        trigger = $0; sub(/:.*$/, "", trigger); trigger = unquote(trim(trigger))
        triggers[trigger] = 1; in_branches = 0; in_types = 0
        # An INLINE flow mapping carries the same filters the block form does:
        # `pull_request: {types: [closed]}` is a real, valid trigger. Recording the trigger and
        # skipping the rest of the line would treat every job as running on every PR.
        rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
        if ((trigger == "pull_request" || trigger == "pull_request_target") && rest ~ /^\{/) {
          if (rest ~ /(paths|types|branches)/) inline_filter = 1
        }
        next
      }
      if (trigger == "pull_request" || trigger == "pull_request_target") {
        if ($0 ~ /^    types:/) {
          pr_types = 1
          rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
          if (rest ~ /^\[/) flow_list(rest, tps)
          in_types = 1; in_branches = 0; next
        }
        if (in_types && $0 ~ /^      -[[:space:]]/) {
          v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); tps[yaml_scalar(v)] = 1; next
        }
        if ($0 !~ /^      /) in_types = 0
        if ($0 ~ /^    (paths|paths-ignore):/) { pr_paths = 1;     in_branches = 0; next }
        if ($0 ~ /^    branches-ignore:/)      { pr_br_ignore = 1; in_branches = 0; next }
        if ($0 ~ /^    branches:/) {
          pr_branches = 1
          rest = $0; sub(/^[^:]*:/, "", rest); rest = trim(rest)
          if (rest ~ /^\[/) flow_list(rest, brs)
          in_branches = 1; next
        }
        if (in_branches && $0 ~ /^      -[[:space:]]/) {  # block-sequence branch entry
          v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); v = yaml_scalar(v)
          if (v ~ /^!/) neg_branch = 1
          brs[v] = 1; next
        }
        if ($0 !~ /^      /) in_branches = 0
      }
      next
    }
    END {
      if (!("pull_request" in triggers) && !("pull_request_target" in triggers)) {
        print "no pull_request trigger"; exit
      }
      if (inline_filter) {
        print "pull_request carries an inline flow-mapping filter (cannot prove it runs for every PR)"; exit
      }
      # A narrowed `types:` is the merge-cleanup workflow trap: `types: [closed]` runs only AFTER
      # a PR closes, so as a required context it sits "expected — waiting" on every open PR
      # forever. Require both `opened` (reports on the new PR) and `synchronize` (re-reports on
      # every later push); anything narrower cannot gate a PR through its whole life.
      if (pr_types && !(("opened" in tps) && ("synchronize" in tps))) {
        print "pull_request narrows types: (needs both opened and synchronize to report on every PR)"; exit
      }
      if (pr_paths)     { print "pull_request carries a paths/paths-ignore filter (it does not run for every PR)"; exit }
      if (pr_br_ignore) { print "pull_request carries a branches-ignore filter (cannot prove it runs for " target ")"; exit }
      # A branches: filter is fine as long as it provably includes the target branch. "*" / "**"
      # match it; an explicit list must name it. Anything else (a partial glob) is unprovable.
      # GitHub evaluates branch patterns IN ORDER, so a later `!main` overrides an earlier `*`.
      # Rather than reimplement that precedence, refuse to prove anything about a filter carrying
      # a negation — `branches: ["*", "!main"]` looks inclusive here and excludes main in fact.
      if (pr_branches && neg_branch) {
        print "pull_request branches filter uses negative patterns (ordered precedence not evaluated)"; exit
      }
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
    # yaml_scalar: a plain YAML scalar as GitHub would read it. A quoted value ends at its closing
    # quote (anything after is a comment); an UNQUOTED value ends at the first whitespace-preceded
    # "#". Without this, `name: Build  # the main build job` becomes the required context
    # "Build  # the main build job" — which nothing ever reports, blocking every PR forever.
    function yaml_scalar(s) {
      s = trim(s)
      if (s ~ /^"/)  { sub(/^"/,  "", s); sub(/".*$/,  "", s); return s }
      if (s ~ /^'"'"'/) { sub(/^'"'"'/, "", s); sub(/'"'"'.*$/, "", s); return s }
      sub(/[[:space:]]+#.*$/, "", s)
      return trim(s)
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
        v = $0; sub(/^[[:space:]]*name:/, "", v); v = yaml_scalar(v)
        if (v ~ /\$\{\{/) job_dynamic = 1
        job_name = v; next
      }
      if ($0 ~ /^    if:/)       { job_if = 1;     next }
      if ($0 ~ /^    uses:/)     { job_uses = 1;   next }
      # Under strategy:. Keyed on `matrix:` itself, so a bare `strategy: {fail-fast: false}` —
      # which does NOT change the check-run name — is not skipped for nothing.
      if ($0 ~ /^      matrix:/) { job_matrix = 1; next }
      # Inline flow style: `strategy: {matrix: {...}}` on the job line itself.
      if ($0 ~ /^    strategy:[[:space:]]*\{.*matrix/) { job_matrix = 1; next }
      next
    }
    END { flush_job() }
  ' "$1"
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
# (per file and per job) go to stderr so stdout stays machine-consumable. Returns 0 even when it
# finds nothing: "this repo has no CI" is a legitimate state (#24), not an error — callers
# distinguish empty output from failure.
discover_checks() {
  local branch="$1" dir f verdict jobs_out found=0
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
    # Split on the FIRST tab only (read -r kind rest), never field-by-field: a job `name:` may
    # legally contain a tab inside a quoted scalar, and a tab-delimited multi-field read would
    # truncate it there — silently requiring a context that does not exist, which is the phantom
    # deadlock this whole file is built to avoid. `rest` keeps the name byte-for-byte.
    jobs_out="$(_adb_rs_jobs "$f")"
    if [ -z "$jobs_out" ]; then
      printf 'repo-settings: WARNING %s declares jobs this parser could not read (unsupported indentation?) — it contributes NO required contexts\n' "${f##*/}" >&2
    fi
    printf '%s\n' "$jobs_out" | while IFS="$(printf '\t')" read -r kind rest; do
      case "$kind" in
        CHECK) [ -n "$rest" ] && printf '%s\n' "$rest" ;;
        SKIP)  printf 'repo-settings: skipping job %s (%s) — %s\n' \
                 "${rest%%"$(printf '\t')"*}" "${f##*/}" "${rest#*"$(printf '\t')"}" >&2 ;;
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
  local branch="$1" resp status body admin
  admin="$(repo_field .permissions.admin)" || admin=""
  # -i so the HTTP STATUS is inspectable. Distinguishing 404 from every other failure is not a
  # nicety: an admin hitting a transient 5xx or a network blip would otherwise be classified
  # `unprotected`, and `apply` would then seed its full replacement PUT from PROT_DEFAULTS —
  # silently discarding the branch's real approval, dismissal, bypass and restriction settings.
  # Only a CONFIRMED 404 means "no protection here".
  resp="$(gh api -i "repos/$REPO_SLUG/branches/$branch/protection" 2>/dev/null)"
  status="$(printf '%s\n' "$resp" | head -n1 | awk '{print $2}')"
  body="$(printf '%s\n' "$resp" | awk 'b { print } /^\r?$/ { b = 1 }')"
  PROT_JSON=""
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
  local branch="$1" ctx="$2" body base label
  case "$PROT_STATE" in
    protected-with-checks)
      body="$(contexts_json "$ctx")" \
        || { echo "ERROR: could not build the required_status_checks body" >&2; return 1; }
      adb_info "  required checks -> PATCH branches/$branch/protection/required_status_checks (narrow; nothing else touched)"
      run_gh "set required checks" "$body" \
        api -X PATCH "repos/$REPO_SLUG/branches/$branch/protection/required_status_checks" --input - \
        || { echo "ERROR: could not set required status checks" >&2; return 1; }
      # The narrow PATCH cannot carry enforce_admins, so honor the flag through its own endpoint.
      # Without this the flag is a silent no-op on exactly the state a repo is in after its FIRST
      # successful apply — i.e. it would appear to work once and then quietly stop.
      if [ "$OPT_ENFORCE_ADMINS" -eq 1 ]; then
        adb_info "  enforce_admins -> POST branches/$branch/protection/enforce_admins"
        run_gh "enforce admins" "" api -X POST "repos/$REPO_SLUG/branches/$branch/protection/enforce_admins" \
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
        api -X PUT "repos/$REPO_SLUG/branches/$branch/protection" --input - \
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
  local branch="$1"
  adb_info ""
  adb_info "No admin permission on $REPO_SLUG — nothing was changed."
  adb_info "Ask an admin to run this same command, which picks the right endpoint for you:"
  adb_info "  baseline repo apply"
  adb_info ""
  adb_info "By hand, the endpoint depends on the branch's current state (protection: $PROT_STATE):"
  adb_info "  protected already -> gh api -X PATCH repos/$REPO_SLUG/branches/$branch/protection/required_status_checks \\"
  adb_info "                         -F strict=false -f 'contexts[]=<each name from: baseline repo checks>'"
  adb_info "  NOT protected yet -> that subresource 404s; POST the full object instead:"
  adb_info "                       gh api -X PUT repos/$REPO_SLUG/branches/$branch/protection --input <body.json>"
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

  dir="$(workflow_dir)"
  ctx="$(discover_checks "$branch" | LC_ALL=C sort -u)"

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
  local branch want got missing extra rc=0
  repo_json >/dev/null || { echo "ERROR: could not read this repo via gh (no resolvable remote, or no access)" >&2; exit 1; }
  branch="$(target_branch)" || { echo "ERROR: could not resolve the target branch" >&2; exit 1; }
  read_protection "$branch"

  want="$(discover_checks "$branch" 2>/dev/null | LC_ALL=C sort -u)"
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

# cmd_automerge_ok — the runtime guard /implement-issue calls BEFORE `gh pr merge --auto`. Every
# reading is fresh (verify-before-asserting): a settings change since the last apply is exactly
# what this must catch. Fails CLOSED — an unreadable state is 20, never 0.
cmd_automerge_ok() {
  require_gh
  local branch nwant nlive want live phantom ungated
  repo_json >/dev/null || { echo "repo-settings: cannot read the repo object — refusing to arm auto-merge" >&2; return 20; }
  branch="$(target_branch)" || { echo "repo-settings: cannot resolve the default branch — refusing to arm auto-merge" >&2; return 20; }
  read_protection "$branch"
  case "$PROT_STATE" in
    error|forbidden)
      # `forbidden` means the protection exists but we may not read it — that is "unreadable",
      # not "unprotected". Reporting 11 here would send the operator to `baseline repo apply`,
      # which they have no permission to run.
      echo "repo-settings: cannot read branch protection on '$branch' — refusing to arm auto-merge" >&2
      return 20 ;;
  esac

  if [ "$(repo_field .allow_auto_merge)" != "true" ]; then
    echo "repo-settings: allow_auto_merge is off on $REPO_SLUG — run 'baseline repo apply'" >&2
    return 10
  fi
  live="$(live_contexts)"
  want="$(discover_checks "$branch" 2>/dev/null | LC_ALL=C sort -u)"
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

cmd_checks() {
  local branch
  # `checks` is the one subcommand that must work with NO network: it is pure file discovery, and
  # the offline test drives it. Resolve the branch from git, not from the API.
  branch="${OPT_BRANCH:-$(adb_default_branch "$(adb_repo_root)")}"
  discover_checks "$branch"
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

parse_read_opts() {   # checks / status / automerge-ok: --branch / --workflow-dir / --help only
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)       OPT_BRANCH="$(_adb_rs_valopt --branch "$#" "${2:-}")" || exit 2; shift ;;
      --workflow-dir) OPT_WORKFLOW_DIR="$(_adb_rs_valopt --workflow-dir "$#" "${2:-}")" || exit 2; shift ;;
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
  merge-flag)   parse_read_opts "$@";  cmd_merge_flag ;;
  apply)        parse_apply_opts "$@"; cmd_apply ;;
  -h|--help)    usage; exit 0 ;;
  *) echo "repo-settings: unknown subcommand '$SUB' (expected 'checks', 'status', 'apply', 'automerge-ok', or 'merge-flag')" >&2
     usage >&2; exit 2 ;;
esac
