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
#   mutation-gate.sh rows <suite-path> [--base <ref>]     < <row-id><TAB><target> lines
#       Decide PER ROW (#470), which is the same question one axis finer: a harness re-runs its
#       whole row table once per injected defect, and each row's defect lands in ONE named file.
#       Prints a decision line, then `<row-id><TAB>run|skip` for every row read, in input order —
#       a uniform contract, so a RUN-ALL answer is never inferred from a missing line. Exits 0
#       (decided), 11 (run all, fail-closed), 12 (run all, override) or 2 (usage).
#
#       A ROW'S INPUT SET is its own target plus every declared input of the step that NO row
#       targets. The registry stays the one home: the row axis only subdivides the inputs rows
#       actually discriminate, and a shared input — the suite itself, `check-lib.sh`, a library no
#       row mutates — still runs every row. That is an APPROXIMATION, and deliberately the same
#       one the step-level gate already makes: a row whose block executes ANOTHER row's target can
#       have its verdict changed by a diff this gate gates it out of. `mutation-nightly.yml` is
#       the backstop for exactly that class, and runs every row unconditionally against `main`.
#       A row whose target is not among the step's declared inputs means the declaration is
#       narrower than the harness — `declared-inputs-incomplete` — so gating is refused for the
#       WHOLE step and every row runs, naming the target.
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
# The sibling entry points' shape — cd first, then read pwd — never a single self-locating capture
# that ends in pwd: that form strips a trailing newline from the clone's path and resolves a
# differently-named tree (D82), and `check-bootstrap.sh`'s open-world scan refuses it in any
# undeclared file (including in a comment, which is why this one does not spell it).
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd)"

usage() {
  cat >&2 <<EOF
usage: bash scripts/$ME should-run <step> [--base <ref>] -- <input-path>...
       bash scripts/$ME run <step> -- <command>...
       bash scripts/$ME rows <suite-path> [--base <ref>]   < <row-id><TAB><target> lines
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

# gate_changed <merge-base> — fill GATE_CHANGED with the changed-path set: working tree vs
# <merge-base>, plus untracked (not ignored) files, deduplicated. Runs in the CALLER's shell (it
# assigns an array), so a failure is a non-zero return with the reason in GATE_ERR — never a
# subshell capture, which is how the first cut of this file lost its merge-base.
#
# THREE GIT DEFAULTS EACH TURNED A TOUCHED INPUT INTO A FALSE SKIP, and each is switched off here:
#   -z                      paths are NUL-delimited, so a name git would otherwise QUOTE (any
#                           non-ASCII byte under core.quotePath's default) arrives as itself and
#                           still compares equal to the declared input;
#   --no-renames            a declared file renamed away is reported as a DELETION of that path,
#                           not folded into its destination — its removal counts as touching it;
#   -c core.quotePath=false belt and braces for the same quoting rule on the untracked read.
declare -a GATE_CHANGED=()
GATE_ERR=""
gate_changed() {
  local mb="$1" f
  local -a tracked=() untracked=()
  local -A seen=()
  GATE_CHANGED=(); GATE_ERR=""
  # `wait "$!"` is the process substitution's status: a `mapfile < <(git …)` reports nothing about
  # git on its own, and a failed diff read as an empty set is a SKIP for every harness.
  mapfile -d '' -t tracked < <(git -C "$ROOT" -c core.quotePath=false diff --name-only -z --no-renames "$mb" -- 2>/dev/null)
  wait "$!" || { GATE_ERR="git diff against $mb failed"; return 1; }
  mapfile -d '' -t untracked < <(git -C "$ROOT" -c core.quotePath=false ls-files --others --exclude-standard -z 2>/dev/null)
  wait "$!" || { GATE_ERR="git ls-files --others failed"; return 1; }
  for f in "${tracked[@]}" "${untracked[@]}"; do
    [ -n "$f" ] || continue
    [ -n "${seen[$f]+x}" ] && continue
    seen["$f"]=1
    GATE_CHANGED+=("$f")
  done
  return 0
}

# gate_match <input>… — the members of GATE_CHANGED that lie on any input, one per line. An input
# names a file, or a directory whose subtree counts; `stub.sh.bak` does not lie on `stub.sh`.
gate_match() {
  local f p
  for f in "${GATE_CHANGED[@]}"; do
    for p in "$@"; do
      p="${p%/}"
      [ -n "$p" ] || continue
      case "$f" in
        "$p"|"$p"/*) printf '%s\n' "$f"; break ;;
      esac
    done
  done
}

# gate_decide <step> <base-arg> <input>… — the whole decision. Prints the one line; returns
# 0 (run: inputs changed), 10 (skip), 11 (run: fail-closed, no diff), 12 (run: override).
gate_decide() {
  local step="$1" basearg="$2" base mb hits nhits nchanged inputs
  shift 2
  inputs="$(printf '%s, ' "$@")"; inputs="${inputs%, }"
  if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then
    printf 'RUN: %s — ADB_MUTATION_RUN_ALL is set; the gate is overridden and every harness runs\n' "$step"
    return 12
  fi
  base="$(gate_base "$basearg")"
  # stderr is MERGED into the capture on purpose: on success gate_mb writes nothing there (every git
  # call is silenced), and on failure the one line it writes IS the reason to print. No temp file.
  if ! mb="$(gate_mb "$base" 2>&1)"; then
    printf 'RUN: %s — %s (fail-closed: the diff could not be established, so the harness runs)\n' \
      "$step" "${mb:-merge-base unavailable}"
    return 11
  fi
  if ! gate_changed "$mb"; then
    printf 'RUN: %s — %s (fail-closed: the diff could not be established, so the harness runs)\n' \
      "$step" "${GATE_ERR:-diff unavailable}"
    return 11
  fi
  hits="$(gate_match "$@")"
  nchanged="${#GATE_CHANGED[@]}"
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

# NOTE ON ORDER: these sit AFTER `gate_decide` because `check-mutation-gate.sh`'s mutation rows
# for the step-level decision are anchored by POSITION — `check_mutate_literal` rewrites the FIRST
# occurrence, so a function inserted above `gate_decide` silently re-targets them at code they were
# never written about. The rows below anchor on `# row-*` markers instead, which is what that
# lesson is worth: a literal that must be unique should say so in the source.

# gate_registry_row <selector> <kind> — print the whole registry row for the step named by
# <selector> (kind `step`) or for the step whose command is `bash <selector> --mutation` (kind
# `suite`). Prints nothing and returns non-zero with a one-line reason on stderr when the registry
# cannot be read or the step is unknown.
#
# ONE HOME for the read: `scripts/selfcheck.sh --list`. BOTH `run` and `rows` come through here —
# `run` for field 2 and field 5, `rows` for field 5 — because two readings of one registry are the
# drift this file's own header forbids, and because the second one is a second `--list` process on
# a path #471 exists to make cheaper.
gate_registry_row() {
  local sel="$1" kind="$2" reg row want
  reg="$(bash "$ROOT/scripts/selfcheck.sh" --list)" \
    || { printf 'scripts/selfcheck.sh --list failed — cannot read the registry\n' >&2; return 1; }
  case "$kind" in
    step) row="$(printf '%s\n' "$reg" | awk -F'\t' -v s="$sel" '$1 == s { print; exit }')" ;;
    suite)
      want="bash $sel --mutation"
      row="$(printf '%s\n' "$reg" | awk -F'\t' -v c="$want" '$2 == c { print; exit }')" ;;
    *) printf 'gate_registry_row: unknown kind %s\n' "$kind" >&2; return 1 ;;
  esac
  [ -n "$row" ] || { printf 'not a registered selfcheck step (see scripts/selfcheck.sh --list)\n' >&2; return 1; }
  printf '%s\n' "$row"
}

# gate_registry_inputs <selector> <kind> — that row's declared inputs (field 5), comma-joined.
gate_registry_inputs() {
  local row inputs
  row="$(gate_registry_row "$1" "$2")" || return 1
  inputs="$(printf '%s\n' "$row" | cut -f5)"
  [ -n "$inputs" ] && [ "$inputs" != "-" ] \
    || { printf 'the step declares no inputs, so nothing can be skipped on their strength\n' >&2; return 1; }
  printf '%s\n' "$inputs"
}

# gate_rows <suite> <base-arg> — the per-row decision. Reads `<row-id><TAB><target>` from stdin,
# prints the decision line and then one `<row-id><TAB>run|skip` per row. Returns 0 / 11 / 12 / 2
# exactly as documented in the header.
#
# EVERY ROW GETS A LINE on every path, including the two RUN-ALL ones. A consumer that had to read
# "no line" as "run" would be folding a failed read into a decision, which is the whole reason the
# step-level gate spends four distinct exit codes on this question.
gate_rows() {
  local suite="$1" basearg="$2" base mb inputs id tgt i n=0 run=0 skip=0 shared="" p q is_target hits
  local -a ids=() tgts=() inarr=() targets=() sharedarr=()
  while IFS="$(printf '\t')" read -r id tgt || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    ids+=("$id"); tgts+=("$tgt"); n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then   # row-usage
    printf '%s: rows %s: no rows on stdin\n' "$ME" "$suite" >&2; return 2
  fi

  gate_rows_all() {   # <line> — every row runs, for the stated reason
    local i
    printf '%s\n' "$1"
    for (( i = 0; i < n; i++ )); do printf '%s\trun\n' "${ids[$i]}"; done
  }

  if [ -n "${ADB_MUTATION_RUN_ALL:-}" ]; then   # row-override
    gate_rows_all "RUN-ALL: $suite — ADB_MUTATION_RUN_ALL is set; the gate is overridden and every row runs"
    return 12
  fi
  if ! inputs="$(gate_registry_inputs "$suite" suite 2>&1)"; then   # row-registry
    gate_rows_all "RUN-ALL: $suite — ${inputs:-the registry could not be consulted} (fail-closed: row gating needs the step's declared inputs, so every row runs)"
    return 11
  fi
  IFS=',' read -r -a inarr <<< "$inputs"

  # The distinct targets this table names, and the declared inputs NO row targets: the second set
  # is what a change must leave alone for any row to be gated at all.
  for (( i = 0; i < n; i++ )); do
    is_target=0
    for p in "${targets[@]+"${targets[@]}"}"; do [ "$p" = "${tgts[$i]}" ] && is_target=1 && break; done
    [ "$is_target" -eq 0 ] && targets+=("${tgts[$i]}")
  done
  for p in "${targets[@]+"${targets[@]}"}"; do
    is_target=0
    for q in "${inarr[@]}"; do [ "$q" = "$p" ] && is_target=1 && break; done
    if [ "$is_target" -eq 0 ]; then   # row-target-undeclared
      gate_rows_all "RUN-ALL: $suite — a row mutates '$p', which the step does not declare as an input (fail-closed: the declaration is narrower than the harness, so every row runs)"
      return 11
    fi
  done
  # THE UNIVERSALLY-SOURCED FILES ARE SHARED EVEN WHEN ROWS MUTATE THEM. Subtracting every row
  # target from the declared inputs removes `scripts/lib/common.sh` — which rows do mutate, and
  # which every other target SOURCES — so a change to it would run only its own rows and gate the
  # `bin/baseline` and `install.sh` rows whose blocks execute it. That is not the bounded
  # approximation this gate accepts; it is systematic, because these files are under everything.
  # The set is not a table this file invented: `check-mutation-gate.sh` already pins that every
  # `*-mutation` step declares its own harness, `scripts/check-lib.sh` and `scripts/lib/common.sh`
  # — "the two files every harness sources" — so it is that pinned fact, read here.
  local -a always=("$suite" "scripts/check-lib.sh" "scripts/lib/common.sh")
  for q in "${inarr[@]}"; do
    is_target=0
    for p in "${targets[@]+"${targets[@]}"}"; do [ "$q" = "$p" ] && is_target=1 && break; done
    if [ "$is_target" -eq 1 ]; then
      for p in "${always[@]}"; do [ "$q" = "$p" ] && is_target=0 && break; done
    fi
    [ "$is_target" -eq 0 ] && sharedarr+=("$q")
  done
  shared="$(printf '%s, ' "${sharedarr[@]+"${sharedarr[@]}"}")"; shared="${shared%, }"

  base="$(gate_base "$basearg")"
  if ! mb="$(gate_mb "$base" 2>&1)"; then
    gate_rows_all "RUN-ALL: $suite — ${mb:-merge-base unavailable} (fail-closed: the diff could not be established, so every row runs)"
    return 11
  fi
  if ! gate_changed "$mb"; then
    gate_rows_all "RUN-ALL: $suite — ${GATE_ERR:-diff unavailable} (fail-closed: the diff could not be established, so every row runs)"
    return 11
  fi
  # A shared input changed -> every row has something new to say; no row-level question arises.
  hits=""
  [ "${#sharedarr[@]}" -gt 0 ] && hits="$(gate_match "${sharedarr[@]}")"
  if [ -n "$hits" ]; then   # row-shared
    gate_rows_all "RUN-ALL: $suite — no row can be gated; the change touches $(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ') shared input(s) of every row: $(printf '%s\n' "$hits" | tr '\n' ' ' | sed 's/ $//')"
    return 0
  fi
  local -a decisions=()
  for (( i = 0; i < n; i++ )); do
    if [ -n "$(gate_match "${tgts[$i]}")" ]; then decisions+=(run); run=$((run + 1))   # row-match
    else decisions+=(skip); skip=$((skip + 1)); fi
  done
  printf 'GATED: %s — %s of %s row(s) run, %s gated against %s (merge-base %s; %s changed file(s) compared; shared inputs: %s)\n' \
    "$suite" "$run" "$n" "$skip" "$base" "${mb:0:12}" "${#GATE_CHANGED[@]}" "${shared:-none}"
  for (( i = 0; i < n; i++ )); do printf '%s\t%s\n' "${ids[$i]}" "${decisions[$i]}"; done
  return 0
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

  rows)
    [ "$#" -ge 1 ] || usage
    suite="$1"; shift
    case "$suite" in ''|-*) usage ;; esac
    basearg=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base) [ "$#" -ge 2 ] || usage; basearg="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    gate_rows "$suite" "$basearg"
    exit $? ;;

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
    # THE REGISTRY IS THE AUTHORITY, read through the one reader above. Hard-stop on the read: an
    # errored --list arriving as empty stdin would read as "unknown step", which is at least a
    # refusal — but a refusal blaming the workflow line for a broken runner sends the reader to the
    # wrong file, so the reader's own reason is passed through verbatim.
    if ! row="$(gate_registry_row "$step" step 2>&1)"; then
      printf '%s: run %s: %s\n' "$ME" "$step" "$row" >&2; exit 2
    fi
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
