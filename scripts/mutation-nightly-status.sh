#!/usr/bin/env bash
# ai-dev-baseline — the mutation harnesses' last verdict, stated on every pull request (#456).
#
# Since #456 no `--mutation` harness runs per pull request: `mutation-nightly.yml` runs every one
# against the default branch on a schedule, and on demand (a `step` dispatch input, or the
# `run-mutations` label). That moves a guard's verdict out of the PR's own checks, so this prints
# where it went — one line, into the job summary, so a reader sees the guards' last answer without
# leaving the PR:
#
#   mutation harnesses: not run per-PR (nightly + on demand); last nightly on main: <url> <conclusion> <age>
#
# THE LAST *SCHEDULED* RUN ON THE DEFAULT BRANCH, never just the last run: a one-step dispatch or a
# labelled PR run is not "the nightly", and reporting one as it would claim every harness passed
# when one was run. Every non-green shape is SAID, never folded into silence:
#   - no scheduled run found                → `no nightly result found`
#   - the newest one has not finished       → its status (`in_progress`, `queued`, …) and age
#   - older than 48h                        → the age plus `STALE` — GitHub documents that a
#                                             schedule may be delayed or dropped under load
#   - gh failed (auth, network, API)        → `unreadable (…)`, distinct from absence
#   - a field of an unexpected type or shape → `unreadable (…)` — the summary renders Markdown, so
#                                             nothing reaches it that was not validated first:
#                                             strings where strings belong, status and conclusion
#                                             from GitHub's vocabulary, a full 40-hex commit
#
# IT REPORTS, IT DOES NOT GATE: the exit is 0 on every one of those, and 2 only for usage. A reporter
# that could turn a pull request red would be a gate on the nightly, which is exactly what #456 took
# off the per-PR path.
#
# Usage: bash scripts/mutation-nightly-status.sh
# Environment:
#   GITHUB_STEP_SUMMARY  when set (Actions), the line is appended there as well as printed.
#   ADB_NIGHTLY_NOW      epoch seconds to measure the age against (tests); default: now.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u`. Same stanza as every other entry point.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
[ "$#" -eq 0 ] || { printf 'usage: bash scripts/mutation-nightly-status.sh\n' >&2; exit 2; }
cd "$(dirname "$0")/.." || exit 2

PREFIX="mutation harnesses: not run per-PR (nightly + on demand)"
STALE_SECS=$(( 48 * 3600 ))

emit() {
  local line="$PREFIX; $1"
  printf '%s\n' "$line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- '- %s\n' "$line" >> "$GITHUB_STEP_SUMMARY" \
      || printf 'mutation-nightly-status: could not append to GITHUB_STEP_SUMMARY (the line is still above)\n' >&2
  fi
  exit 0
}

branch="$(adb_default_branch "$PWD" 2>/dev/null)"   # its git chatter is not this line's business
# GIT'S OWN RULE decides whether it is a branch name (a valid one may be non-ASCII); the Markdown
# summary gets an ESCAPED copy, so nothing in the name can act as markup there.
[ -n "$branch" ] && git check-ref-format --branch "$branch" >/dev/null 2>&1 \
  || emit "last nightly: unreadable (the default branch could not be resolved)"
branch_md="$(adb_md_escape "$branch")"
command -v gh >/dev/null 2>&1 || emit "last nightly on $branch_md: unreadable (gh is not installed)"
command -v jq >/dev/null 2>&1 || emit "last nightly on $branch_md: unreadable (jq is not installed)"

json="$(gh run list --workflow mutation-nightly.yml --branch "$branch" --event schedule --limit 1 \
          --json url,status,conclusion,createdAt,headSha 2>/dev/null)" \
  || emit "last nightly on $branch_md: unreadable (gh run list failed — auth, network or API; this is not the same as no run)"

# THE READ'S STATUS IS CHECKED, not only its output: jq prints a document's answer as it parses it,
# so `[]` followed by garbage prints `0` and THEN fails — and that `0` would report "no nightly"
# for a response that did not parse.
n="$(printf '%s' "$json" | jq -r 'if type == "array" then length else "bad" end' 2>/dev/null)" \
  || emit "last nightly on $branch_md: unreadable (gh returned a document that does not parse)"
case "$n" in
  0) emit "last nightly on $branch_md: no nightly result found" ;;
  1) : ;;
  *) emit "last nightly on $branch_md: unreadable (gh returned an unexpected document)" ;;
esac

# One jq pass; the age is computed here so no date(1) dialect is involved. Joined on US (0x1f), NOT a
# tab: a tab is IFS WHITESPACE, so `read` collapses a run of them and an empty field — an unfinished
# run's conclusion — would shift every field after it.
fields="$(printf '%s' "$json" | jq -r --arg now "${ADB_NIGHTLY_NOW:-}" '
  .[0] as $r
  | if ([$r.url, $r.status, $r.createdAt, $r.headSha] | all(type == "string"))
       and (($r.conclusion | type) == "string" or $r.conclusion == null) | not
    then error("types") else . end
  # THE TIMESTAMP ROUND-TRIPS, or it is refused: `fromdateiso8601` NORMALIZES (Feb 30 reads as
  # Mar 2, an unpadded field parses), so a parse alone is not validation. Re-rendering it must give
  # back exactly the string GitHub sent — which also pins the shape to YYYY-MM-DDTHH:MM:SSZ.
  | if (try ($r.createdAt | fromdateiso8601 | todateiso8601) catch "") != $r.createdAt
    then error("timestamp") else . end
  | (if $now == "" then now else ($now | tonumber) end) as $t
  | [ ($r.url // ""), ($r.status // ""), ($r.conclusion // ""), ($r.headSha // ""),
      ((try ($t - ($r.createdAt | fromdateiso8601)) catch -1) | floor | tostring) ]
  | map(tostring | gsub("[\u001f\n]"; "?")) | join("\u001f")' 2>/dev/null)" \
  || emit "last nightly on $branch_md: unreadable (the run record did not parse)"
IFS=$'\x1f' read -r url status conclusion sha age <<< "$fields"

# VALIDATED BEFORE IT REACHES MARKDOWN. Each field is checked against the shape GitHub gives it;
# anything else is reported as unreadable rather than rendered.
[[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$ ]] \
  || emit "last nightly on $branch_md: unreadable (the run URL has an unexpected shape)"
# GitHub's documented workflow-run vocabulary — a word outside it is unreadable, not rendered.
case "$status" in
  completed|in_progress|queued|requested|waiting|pending|action_required) : ;;
  *) emit "last nightly on $branch_md: unreadable (the run status has an unexpected shape)" ;;
esac
case "$conclusion" in
  ''|success|failure|cancelled|skipped|timed_out|action_required|neutral|stale|startup_failure) : ;;
  *) emit "last nightly on $branch_md: unreadable (the run conclusion has an unexpected shape)" ;;
esac
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || emit "last nightly on $branch_md: unreadable (the run's commit has an unexpected shape)"
[[ "$age" =~ ^[0-9]+$ ]] || emit "last nightly on $branch_md: unreadable (the run's creation time did not parse)"

verdict="$conclusion"
[ "$status" = completed ] || verdict="$status (not finished)"
[ -n "$verdict" ] || verdict="completed with no conclusion"
hours=$(( age / 3600 ))
agetext="${hours}h ago"
[ "$hours" -gt 0 ] || agetext="$(( age / 60 ))m ago"
stale=""
[ "$age" -le "$STALE_SECS" ] || stale=" — STALE (older than 48h; a schedule can be delayed or dropped)"
emit "last nightly on $branch_md: $url $verdict ${agetext} at ${sha:0:12}${stale}"
