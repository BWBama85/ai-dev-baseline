#!/usr/bin/env bash
# ai-dev-baseline — the mutation-harness gate (#441).
#
# A `--mutation` harness re-runs a whole suite once per injected defect to prove that suite can go
# red. Its verdict is a function of a KNOWN, SMALL input set — the library it mutates, that
# library's suite, the shared harness (`scripts/check-lib.sh`) and `scripts/lib/common.sh` — so on a
# change that touches none of them it re-derives the answer it already gave on the default branch.
# This script decides, from the diff, whether a harness has anything new to say, and SAYS which
# way it decided: a skip that is indistinguishable from a pass is the failure `self-review.md`
# names ("make the guard say what it checked").
#
# ONE HOME for the input set: `scripts/selfcheck.sh`'s registry, read through `--list` (field 5).
# This script never carries a table of its own — a second copy is the drift golden rule 4 forbids.
#
# Usage:
#   mutation-gate.sh should-run <step> [--base <ref>] -- <input-path>…
#       Decide for one step. Prints exactly ONE line, and the exit code is the decision — each
#       answer distinct, so a caller can never fold a failed read into a skip (status-swallowed):
#         0   RUN: <step> — <k> changed file(s) touch its inputs: <files>
#         10  SKIP: <step> — inputs unchanged against <base> (merge-base …; <n> changed file(s)
#             compared; inputs: …)
#         11  RUN: <step> — <reason> (fail-closed: the diff could not be established …)
#         12  RUN: <step> — ADB_MUTATION_RUN_ALL is set; …
#         2   usage (nothing decided)
#       0, 11 and 12 all mean RUN; only 10 means skip.
#   mutation-gate.sh run <step> -- <command>…
#       CI's form. Looks the step up in `selfcheck.sh --list`, refuses (2) an unknown step, a step
#       with no declared inputs, or a <command> that is not the registry's own command for that
#       step — so a workflow line cannot name one harness and run another — then either execs the
#       command (its status is the step's) or prints the SKIP and exits 0.
#   mutation-gate.sh base [--base <ref>]
#       Print the resolved merge-base the diff is taken against, or exit 3 with the reason it
#       could not be resolved.
#
# Environment:
#   ADB_MUTATION_RUN_ALL   non-empty → every decision is RUN, and the line says the override fired.
#                          The scheduled workflow sets it; a local `ADB_MUTATION_RUN_ALL=1 bash
#                          scripts/selfcheck.sh` is the whole-registry run golden rule 3 describes.
#   ADB_MUTATION_BASE      the ref the diff is taken against. Default: origin/<default branch>.
#                          `--base` outranks it. CI sets it per event (the PR's base branch, or
#                          the push's previous tip).
#
# THE DIFF IS THE WORKING TREE AGAINST THE MERGE-BASE, plus untracked files. Not `HEAD` against the
# base: locally the edit that matters is usually still uncommitted, and a gate that only saw commits
# would skip the harness for exactly the change it should run on. In CI the tree is clean, so the
# two readings coincide.
#
# FAIL CLOSED, in the direction that costs minutes rather than coverage: no git repository, an
# unresolvable base, no merge-base, or a diff that errors all decide RUN and say why. A skip is
# only ever issued on a diff this script actually computed.
#
# Matching: an input names a file, or a directory (with or without a trailing `/`) whose whole
# subtree counts. A changed path matches when it equals the input or lies under it.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and the cd. Same stanza and same reason as
# every other entry point under scripts/.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail

ME="${0##*/}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2

usage() {
  cat >&2 <<EOF
usage: bash scripts/$ME should-run <step> [--base <ref>] -- <input-path>...
       bash scripts/$ME run <step> -- <command>...
       bash scripts/$ME base [--base <ref>]
EOF
  exit 2
}

# gate_base [ref] — resolve the ref the diff is taken against, in precedence order: the argument,
# ADB_MUTATION_BASE, origin/<default branch>. Prints the ref; never validates it (git does, below).
gate_base() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  if [ -n "${ADB_MUTATION_BASE:-}" ]; then printf '%s\n' "$ADB_MUTATION_BASE"; return 0; fi
  printf 'origin/%s\n' "$(adb_default_branch "$ROOT")"
}

# gate_mb <base> — the merge-base of <base> and HEAD, printed. Non-zero with a one-line reason on
# stderr when there is none: not a repository, a base that does not resolve, unrelated histories
# (which is what a shallow clone looks like). Every one of those is a RUN for the callers.
#
# PRINTED, NOT ASSIGNED: these run inside `$(…)`, where an assignment to a global is lost with the
# subshell. The first cut of this file set GATE_MB here and every SKIP line named an empty
# merge-base; its own suite caught it.
gate_mb() {
  local base="$1" mb
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'not a git repository\n' >&2; return 1; }
  git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || { printf 'base %s does not resolve to a commit\n' "$base" >&2; return 1; }
  mb="$(git -C "$ROOT" merge-base "$base" HEAD 2>/dev/null)" && [ -n "$mb" ] \
    || { printf 'no merge-base between %s and HEAD (shallow clone?)\n' "$base" >&2; return 1; }
  printf '%s\n' "$mb"
}

# gate_changed <merge-base> — the changed-path set: working tree vs <merge-base>, plus untracked
# (not ignored) files. One path per line, sorted, deduplicated. Non-zero with a reason on stderr
# when either read fails, which the callers read as RUN.
gate_changed() {
  local mb="$1" tracked untracked
  # CAPTURE, then test: `git diff … | sort` would report sort's status, and a failed diff would
  # arrive as an empty set — which is a SKIP for every harness. Two reads, each checked.
  tracked="$(git -C "$ROOT" diff --name-only "$mb" -- 2>/dev/null)" \
    || { printf 'git diff against %s failed\n' "$mb" >&2; return 1; }
  untracked="$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)" \
    || { printf 'git ls-files --others failed\n' >&2; return 1; }
  printf '%s\n%s\n' "$tracked" "$untracked" | sed '/^$/d' | LC_ALL=C sort -u
}

# gate_match <changed-list> <input>… — the changed paths that lie on any input, one per line.
gate_match() {
  local changed="$1" f p
  shift
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for p in "$@"; do
      p="${p%/}"
      [ -n "$p" ] || continue
      case "$f" in
        "$p"|"$p"/*) printf '%s\n' "$f"; break ;;
      esac
    done
  done <<EOF
$changed
EOF
}

# gate_decide <step> <base-arg> <input>… — the whole decision. Prints the one line; returns
# 0 (run: inputs changed), 10 (skip), 11 (run: fail-closed, no diff), 12 (run: override).
gate_decide() {
  local step="$1" basearg="$2" base mb changed hits nhits nchanged inputs
  shift 2
  inputs="$(printf '%s, ' "$@")"; inputs="${inputs%, }"
  if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then
    printf 'RUN: %s — ADB_MUTATION_RUN_ALL is set; the gate is overridden and every harness runs\n' "$step"
    return 12
  fi
  base="$(gate_base "$basearg")"
  # stderr is MERGED into each capture on purpose: on success neither function writes there (every
  # git call is silenced), and on failure the one line it writes IS the reason to print. No temp file.
  if ! mb="$(gate_mb "$base" 2>&1)"; then
    printf 'RUN: %s — %s (fail-closed: the diff could not be established, so the harness runs)\n' \
      "$step" "${mb:-merge-base unavailable}"
    return 11
  fi
  if ! changed="$(gate_changed "$mb" 2>&1)"; then
    printf 'RUN: %s — %s (fail-closed: the diff could not be established, so the harness runs)\n' \
      "$step" "${changed:-diff unavailable}"
    return 11
  fi
  hits="$(gate_match "$changed" "$@")"
  nchanged="$(printf '%s\n' "$changed" | sed '/^$/d' | wc -l | tr -d ' ')"
  nhits="$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$nhits" -gt 0 ]; then
    printf 'RUN: %s — %s changed file(s) touch its inputs: %s\n' \
      "$step" "$nhits" "$(printf '%s\n' "$hits" | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//')"
    return 0
  fi
  printf 'SKIP: %s — inputs unchanged against %s (merge-base %s; %s changed file(s) compared; inputs: %s)\n' \
    "$step" "$base" "${mb:0:12}" "$nchanged" "$inputs"
  return 10
}

# --- argument parsing --------------------------------------------------------------------------
[ "$#" -ge 1 ] || usage
sub="$1"; shift

case "$sub" in
  base)
    basearg=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base) [ "$#" -ge 2 ] || usage; basearg="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    base="$(gate_base "$basearg")"
    if out="$(gate_mb "$base" 2>&1)"; then
      printf '%s (merge-base %s)\n' "$base" "$out"
      exit 0
    fi
    printf '%s: base %s unusable — %s\n' "$ME" "$base" "${out:-unknown}" >&2
    exit 3 ;;

  should-run)
    [ "$#" -ge 1 ] || usage
    step="$1"; shift
    case "$step" in ''|*[!A-Za-z0-9_-]*) usage ;; esac
    basearg=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base) [ "$#" -ge 2 ] || usage; basearg="$2"; shift 2 ;;
        --) shift; break ;;
        *) usage ;;
      esac
    done
    [ "$#" -ge 1 ] || { printf '%s: should-run %s: no input paths given after --\n' "$ME" "$step" >&2; exit 2; }
    gate_decide "$step" "$basearg" "$@"
    exit $? ;;

  run)
    [ "$#" -ge 3 ] || usage
    step="$1"; shift
    [ "$1" = "--" ] || usage
    shift
    case "$step" in ''|*[!A-Za-z0-9_-]*) usage ;; esac
    # THE REGISTRY IS THE AUTHORITY. Read, then parse, and hard-stop on the read: an errored --list
    # arriving as empty stdin would read as "unknown step", which is at least a refusal — but a
    # refusal blaming the workflow line for a broken runner sends the reader to the wrong file.
    reg="$(bash "$ROOT/scripts/selfcheck.sh" --list)" \
      || { printf '%s: run %s: scripts/selfcheck.sh --list failed — cannot read the registry\n' "$ME" "$step" >&2; exit 2; }
    row="$(printf '%s\n' "$reg" | awk -F'\t' -v s="$step" '$1 == s { print; exit }')"
    [ -n "$row" ] || { printf '%s: run %s: not a registered selfcheck step (see scripts/selfcheck.sh --list)\n' "$ME" "$step" >&2; exit 2; }
    regcmd="$(printf '%s\n' "$row" | cut -f2)"
    inputs="$(printf '%s\n' "$row" | cut -f5)"
    want="$*"
    [ "$regcmd" = "$want" ] || {
      printf '%s: run %s: the command given (%s) is not the registry'"'"'s command for that step (%s) — the workflow line and the registry disagree\n' \
        "$ME" "$step" "$want" "$regcmd" >&2
      exit 2
    }
    [ -n "$inputs" ] && [ "$inputs" != "-" ] || {
      printf '%s: run %s: the step declares no inputs, so nothing can be skipped on their strength — run it directly, or declare them in scripts/selfcheck.sh\n' "$ME" "$step" >&2
      exit 2
    }
    # The registry joins the inputs with commas (a path here never carries one); split on exactly that.
    IFS=',' read -r -a inarr <<< "$inputs"
    line="$(gate_decide "$step" "" "${inarr[@]}")"; rc=$?
    printf '%s\n' "$line"
    # A SKIP reaches the job summary too, where a reader looking for "did the harness run" looks
    # first. ONLY a skip: every byte of that line is repo-controlled (a registered step name, the
    # base CI set, the registry's own paths), whereas a RUN line names files from the DIFF — text a
    # pull-request author chose — and the summary renders Markdown. The RUN line is in the log,
    # beside the harness output that proves it ran. The env var is Actions-specific and absent
    # locally; both are fine.
    if [ "$rc" -eq 10 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf -- '- %s\n' "$line" >> "$GITHUB_STEP_SUMMARY" \
        || printf '%s: run %s: could not append to GITHUB_STEP_SUMMARY (the SKIP is still stated above)\n' "$ME" "$step" >&2
    fi
    case "$rc" in
      10) exit 0 ;;          # the stated SKIP is the step's whole output; green
      0|11|12) : ;;          # run, for one of the three stated reasons
      *) printf '%s: run %s: the decision failed (rc %s) — refusing to guess\n' "$ME" "$step" "$rc" >&2; exit 2 ;;
    esac
    # shellcheck disable=SC2086  # the registry validated this word list at registration
    exec $regcmd ;;

  *) usage ;;
esac
