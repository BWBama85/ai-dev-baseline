#!/usr/bin/env bash
# ai-dev-baseline — the registry's declared inputs are complete enough to scope a run by (#629, D157).
#
# Usage: bash scripts/check-step-inputs.sh [--self-test]   (exit 0 = pass, 1 = fail, 2 = usage)
#
# `scripts/selfcheck.sh` runs a plain step only when the change under test touches one of the
# step's declared inputs (`--list`, field 5), and the macOS leg of a pull request is scoped the
# same way. A declaration that leaves out a file the suite depends on turns that into a skipped
# suite on exactly the change that could break it. This lint is what keeps the declarations honest,
# and it holds the premises the scoping rests on:
#
#   whole-tree   every static-tier step declares `.` (a lint reads the tracked tree, so it always
#                runs — the turn-end gate and a scoped run both rely on that)
#   tracked      every path a plain step declares is a tracked file or directory
#   suite        a plain step whose command is `bash <suite> …` declares the suite itself and
#                every tracked file or directory the suite's own text NAMES
#   library      …and every `scripts/lib/*.sh` sibling that a declared `scripts/lib/*.sh` names
#   ubuntu       every plain step that declares paths — every step a scoped run can hold — is
#                run by an ubuntu job of `.github/workflows/ci.yml`, so a suite the macOS leg
#                scopes out of a pull request still ran on that pull request
#
# WHAT "NAMES" MEANS. A reference is a run of path characters that resolves to a tracked file or
# directory and is spelled one of three ways: after a variable the file assigns from `$(pwd)` or
# `$PWD` (the suites' `$ROOT`); after `$(dirname "$0")`, relative to the file's own directory; or
# bare, relative to the tree's root, with at least one `/`. A name that stops at a `/` or is cut by
# a glob (`base/workflows/*.md`, `agents/$agent/skills`, `scripts/check-*.sh`) is a reference to
# the directory it stops in. A line whose first non-blank character is `#` is not read. A path
# quoted in an assertion's message is read like any other, so a suite can be made to declare a
# file it only mentions; that direction costs minutes and never coverage.
#
# WHAT IT CANNOT SEE, stated rather than implied: a path a suite computes, a tree a suite copies
# whole and runs from the copy, a file a library reads, and what a function step does (its body is
# in `selfcheck.sh`). Those are declared by hand. The bound is acceptable because of the fourth
# rule: an under-declared suite is skipped locally and on the macOS leg of a pull request, and is
# still run by its ubuntu job on that pull request and by the macOS leg on the default branch.
#
# AND WHAT IT SEES THAT IS NOT AN INPUT. The scan reads text, so it cannot tell a path a suite
# reads from one it prints in a message or names for a fixture of its own. Declaring such a path
# is always allowed and costs minutes. Where that cost is a slow suite re-run on most changes, the
# path is listed in SI_NOT_INPUT below with the reason, and the lint refuses an entry the suite no
# longer names or the step also declares, so the table cannot outlive what it excuses.
#
# A step that declares nothing (`-`) always runs; this names it and does not fail. A `*-mutation`
# step is not judged here: its inputs are the mutation-specific closure, pinned by
# `scripts/check-mutation-gate.sh`.
#
# --self-test lints the SHIPPED tree first, exactly as the plain mode does (CI and the registry run
# only this mode), then drives every rule red on fixture trees under one `mktemp -d`, each on its
# own witness. Never touches the tracked tree.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and before the cd; the load is confirmed
# by probing for the function, not by the source's exit status.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh

MODE=check
case "${1:-}" in
  "")          ;;
  --self-test) MODE=self-test ;;
  *)           echo "usage: check-step-inputs.sh [--self-test]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: check-step-inputs.sh [--self-test]" >&2; exit 2; }

# The function steps that declare paths, and the ubuntu job that mirrors each. A function step has
# no `bash <suite>` command to look for in a workflow, so the job is named here; `si_verdict`
# requires it to exist and to run on ubuntu, and refuses a function step this table does not carry.
declare -A SI_FN_JOB=(
  [step_gate_detector]=gate-detector
  [step_install_dry_run]=install-dry-run
)

# Paths a suite's text names that its step's verdict does not depend on (see the header). One
# entry per step, space-separated; the reason is the comment above it.
declare -A SI_NOT_INPUT=(
  # A forged-log fixture token (`scripts/*`) and a regex over check names; the suite drives copies
  # of the runner, the gate and the two shared files, all declared.
  [selfcheck-guard]="scripts"
  # `.claude/` is a .gitignore line written into fixture clones. `scripts/lib` is copied whole so a
  # faulted implement-lib.sh runs beside its siblings; the siblings it reaches are declared.
  [implement-lib]=".claude scripts/lib"
  # `scripts` is copied whole so a faulted adopt-readiness.sh runs beside its siblings; the
  # siblings it reaches are declared.
  [adopt-readiness]="scripts"
  # All three appear only in expected-output strings and scan arguments about FIXTURE repositories.
  [adopt]=".claude scripts/lib .ai-dev-baseline/decisions.md"
  # An assertion's message about a fixture home's link.
  [baseline]="scripts/lib"
)

# si_load_tree <list-file> — fill SI_FILES and SI_DIRS from a newline-delimited list of tracked
# paths. Returns 1 on an empty list: a lint over no files would pass everything.
declare -A SI_FILES=() SI_DIRS=()
si_load_tree() {
  local f d n=0
  SI_FILES=(); SI_DIRS=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SI_FILES["$f"]=1; n=$((n + 1))
    d="$f"
    while [[ "$d" == */* ]]; do d="${d%/*}"; SI_DIRS["$d"]=1; done
  done < "$1"
  [ "$n" -gt 0 ]
}

# si_tokens <file> — every candidate reference in <file>, one `<flag><TAB><path>` per line,
# unresolved: the spelling rules in the header, applied. <flag> is `g` for a name a glob character
# cut short, else `-`. The caller decides which candidates are tracked.
si_tokens() {
  local file="$1" selfdir
  selfdir="${file%/*}"; [ "$selfdir" != "$file" ] || selfdir=""
  # C locale: a suite may hold bytes that are not valid in the caller's, and a path character is
  # ASCII either way.
  LC_ALL=C awk -v selfdir="$selfdir" '
    # norm(p) — resolve `.` and `..` components; "" when the path climbs out of the tree.
    function norm(p,    n, i, k, parts, out, res) {
      n = split(p, parts, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (k == 0) return ""; k--; continue }
        out[++k] = parts[i]
      }
      res = ""
      for (i = 1; i <= k; i++) res = res (i > 1 ? "/" : "") out[i]
      return res
    }
    # The root variables: names this file assigns from the working directory. Collected in a first
    # pass over the file, so a use above the assignment still counts.
    FNR == NR {
      if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$(\(pwd|PWD)/)) {
        v = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", v); sub(/=.*/, "", v); rootvar[v] = 1
      }
      next
    }
    /^[[:space:]]*#/ { next }
    {
      line = $0; pos = 1; rootend = 0
      while (match(substr(line, pos), /[A-Za-z0-9_.\/-]+/)) {
        start = pos + RSTART - 1; len = RLENGTH
        tok = substr(line, start, len)
        pre = substr(line, 1, start - 1)
        nxt = substr(line, start + len, 1)
        pos = start + len
        if (pre ~ /\$\{?$/) {
          # `$VAR/path`: the run starts with the variable name. `${VAR}/path` and `"$VAR"/path`
          # end the name first, and the path is the next run.
          n = index(tok, "/")
          if (n == 0) { rootend = (tok in rootvar) ? pos : 0; continue }
          if (!(substr(tok, 1, n - 1) in rootvar)) { rootend = 0; continue }
          tok = substr(tok, n + 1)
        } else if (substr(tok, 1, 1) == "/") {
          gap = rootend ? substr(line, rootend, start - rootend) : "-"
          if (gap == "}" || gap == "\"" || gap == "}\"") tok = substr(tok, 2)
          else if (pre ~ /dirname "\$0"\)$/) tok = selfdir tok
          else { rootend = 0; continue }
        } else if (index(tok, "/") == 0) { rootend = 0; continue }
        rootend = 0
        # A name that stops at a `/` (before an expansion, a glob or a brace) is the directory it
        # stops in. One a glob character follows mid-component (`scripts/check-*.sh`) is flagged
        # `g`: the caller reads it as that file when it is one, else as the directory it is in.
        flag = "-"
        if (tok ~ /\/$/) sub(/\/+$/, "", tok)
        else if (nxt ~ /[*?[]/) flag = "g"
        tok = norm(tok)
        sub(/[.:-]+$/, "", tok)
        if (tok != "") print flag "\t" tok
      }
    }
  ' "$file" "$file"
}

# si_refs <root> <file> — the tracked paths <root>/<file> names: `file<TAB><path>` or
# `directory<TAB><path>` lines, deduplicated, never the file itself. Returns 1 when the file cannot be read.
si_refs() {
  local root="$1" file="$2" flag tok
  local -A seen=()
  [ -f "$root/$file" ] && [ -r "$root/$file" ] || return 1
  while IFS=$'\t' read -r flag tok; do
    [ -n "$tok" ] || continue
    if [ "$flag" = g ] && [ -z "${SI_FILES[$tok]+x}" ]; then
      case "$tok" in */*) tok="${tok%/*}" ;; *) continue ;; esac
    fi
    [ "$tok" != "$file" ] && [ -z "${seen[$tok]+x}" ] || continue
    seen["$tok"]=1
    if [ -n "${SI_FILES[$tok]+x}" ]; then printf 'file\t%s\n' "$tok"
    elif [ -n "${SI_DIRS[$tok]+x}" ]; then printf 'directory\t%s\n' "$tok"
    fi
  done < <(cd "$root" && si_tokens "$file")
}

# si_lib_siblings <root> <lib> — the `scripts/lib/*.sh` files <lib> (itself one) names by basename,
# one per line. A library reaches its siblings through its own directory, whatever variable holds
# it, so the basename is the spelling that is always there.
si_lib_siblings() {
  local root="$1" lib="$2" tok base
  local -A seen=()
  [ -f "$root/$lib" ] && [ -r "$root/$lib" ] || return 1
  while IFS= read -r tok; do
    base="scripts/lib/${tok##*/}"
    [ "$base" != "$lib" ] && [ -n "${SI_FILES[$base]+x}" ] && [ -z "${seen[$base]+x}" ] || continue
    seen["$base"]=1
    printf '%s\n' "$base"
  done < <(grep -v '^[[:space:]]*#' "$root/$lib" | grep -oE '[A-Za-z0-9_.-]+\.sh' || true)
}

# si_covered <path> <input>… — is <path> one of the inputs, or under one that is a directory?
si_covered() {
  local path="$1" p
  shift
  for p in "$@"; do
    p="${p%/}"
    [ "$p" = . ] && return 0
    case "$path" in "$p"|"$p"/*) return 0 ;; esac
  done
  return 1
}

# si_listed <path> <entry>… — is <path> exactly one of the entries?
si_listed() {
  local path="$1" p
  shift
  for p in "$@"; do [ "$p" = "$path" ] && return 0; done
  return 1
}

# si_ubuntu_text <ci.yml> — the non-comment lines of every job that runs on ubuntu, each prefixed
# `<job-key><TAB>`. Structure comes from the shared reader (`adb_wf_jobs`); returns 1 when it fails
# or names no ubuntu job, so an unreadable workflow is never read as "nothing runs there".
si_ubuntu_text() {
  local wf="$1" recs key start end n=0
  recs="$(adb_wf_jobs "$wf" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r key start end; do
    [ -n "$key" ] && [ -n "$start" ] && [ -n "$end" ] || return 1
    sed -n "${start},${end}p" "$wf" | grep -v '^[[:space:]]*#' | awk -v k="$key" '{ print k "\t" $0 }'
    n=$((n + 1))
  done < <(printf '%s\n' "$recs" | awk -F'\t' '
      $1 == "JOB"    { key[$2] = $3 }
      $1 == "RANGE"  { s[$2] = $3; e[$2] = $4 }
      $1 == "RUNSON" { if ($3 ~ /^ubuntu-/) u[$2] = 1 }
      END { for (j in u) printf "%s\t%s\t%s\n", key[j], s[j], e[j] }')
  [ "$n" -gt 0 ]
}

# si_verdict <root> <registry.tsv> <tracked-list> <ci.yml> — the whole lint over one tree. Prints
# one `step-inputs: <step>: <finding>` line per finding and a closing summary line; returns 0 when
# there is no finding, 1 when there is one, 2 when the tree could not be read at all.
si_verdict() {
  local root="$1" reg="$2" list="$3" wf="$4"
  local name cmd inputs tier suite kind ref sib u_text job findings=0
  local n_steps=0 n_whole=0 n_paths=0 n_harness=0 n_ubuntu=0 n_plain=0
  local -a in=() undeclared=() waived=() named=()
  si_load_tree "$list" || { printf 'step-inputs: the tracked-file list is empty or unreadable\n'; return 2; }
  [ -s "$reg" ] || { printf 'step-inputs: the registry listing is empty\n'; return 2; }
  u_text="$(si_ubuntu_text "$wf")" || { printf 'step-inputs: %s could not be read, or names no ubuntu job\n' "$wf"; return 2; }

  while IFS=$'\t' read -r name cmd _ _ inputs tier _; do
    [ -n "$name" ] || continue
    n_steps=$((n_steps + 1))
    case "$name" in *-mutation) n_harness=$((n_harness + 1)); continue ;; esac
    n_plain=$((n_plain + 1))

    # whole-tree: a static step declares `.` and nothing narrower.
    if [ "$tier" = static ] && [ "$inputs" != . ]; then
      printf 'step-inputs: %s: a static-tier step must declare the whole tree (.), got %s\n' "$name" "$inputs"
      findings=$((findings + 1))
    fi
    case "$inputs" in
      -) undeclared+=("$name"); continue ;;
      .) n_whole=$((n_whole + 1)); continue ;;
    esac
    n_paths=$((n_paths + 1))
    IFS=',' read -r -a in <<< "$inputs"
    read -r -a waived <<< "${SI_NOT_INPUT[$name]:-}"

    # tracked: a declared path that names nothing in the tree can never match a change.
    for ref in "${in[@]}"; do
      ref="${ref%/}"
      [ -n "${SI_FILES[$ref]+x}" ] || [ -n "${SI_DIRS[$ref]+x}" ] && continue
      printf 'step-inputs: %s: declared input %s is not a tracked file or directory — it can never match a change\n' "$name" "$ref"
      findings=$((findings + 1))
    done

    # ubuntu: the step's command, WHOLE, in an ubuntu job — or, for a function step, its named job.
    # Whole means to the end of the invocation: the line's end, a shell operator, a redirect or a
    # closing quote. A further argument (`… --self-test`) makes it another step's command.
    case "$cmd" in
      "bash "*)
        if printf '%s\n' "$u_text" | grep -qE -- "(^|[^A-Za-z0-9_./-])${cmd//./\\.}[[:space:]]*(\$|[;|&)<>\"']|[0-9]>)"; then
          n_ubuntu=$((n_ubuntu + 1))
        else
          printf 'step-inputs: %s: no ubuntu job of %s runs `%s` — a pull request that does not touch its inputs would run it on no platform\n' "$name" "${wf##*/}" "$cmd"
          findings=$((findings + 1))
        fi ;;
      *)
        job="${SI_FN_JOB[$cmd]:-}"
        if [ -z "$job" ]; then
          printf 'step-inputs: %s: the function step `%s` has no ubuntu job named for it in this lint (SI_FN_JOB)\n' "$name" "$cmd"
          findings=$((findings + 1))
        elif printf '%s\n' "$u_text" | awk -F'\t' -v k="$job" '$1 == k { f = 1 } END { exit !f }'; then
          n_ubuntu=$((n_ubuntu + 1))
        else
          printf 'step-inputs: %s: the ubuntu job `%s` that mirrors it is missing from %s, or does not run on ubuntu\n' "$name" "$job" "${wf##*/}"
          findings=$((findings + 1))
        fi ;;
    esac

    # suite: the suite itself, and everything its text names.
    named=()
    case "$cmd" in
      "bash "*)
        suite="${cmd#bash }"; suite="${suite%% *}"
        if ! si_covered "$suite" "${in[@]}"; then
          printf 'step-inputs: %s: its own suite %s is not among its declared inputs\n' "$name" "$suite"
          findings=$((findings + 1))
        fi
        if [ ! -f "$root/$suite" ]; then
          printf 'step-inputs: %s: its suite %s does not exist, so what it names cannot be read\n' "$name" "$suite"
          findings=$((findings + 1))
        else
          while IFS=$'\t' read -r kind ref; do
            [ -n "$ref" ] || continue
            named+=("$ref")
            si_covered "$ref" "${in[@]}" && continue
            si_listed "$ref" "${waived[@]}" && continue
            printf 'step-inputs: %s: %s names the tracked %s %s, which its declared inputs do not cover\n' "$name" "$suite" "$kind" "$ref"
            findings=$((findings + 1))
          done < <(si_refs "$root" "$suite")
        fi ;;
    esac
    # …and a waiver excuses exactly what it names: nothing the suite stopped naming, and nothing
    # the step declares anyway.
    for ref in "${waived[@]}"; do
      if ! si_listed "$ref" "${named[@]}"; then
        printf 'step-inputs: %s: SI_NOT_INPUT lists %s, which its suite does not name — remove the entry\n' "$name" "$ref"
        findings=$((findings + 1))
      elif si_covered "$ref" "${in[@]}"; then
        printf 'step-inputs: %s: SI_NOT_INPUT lists %s, which the step declares — remove the entry\n' "$name" "$ref"
        findings=$((findings + 1))
      fi
    done

    # library: every sibling a declared library names.
    for ref in "${in[@]}"; do
      case "$ref" in scripts/lib/*.sh) : ;; *) continue ;; esac
      [ -f "$root/$ref" ] || continue
      while IFS= read -r sib; do
        [ -n "$sib" ] || continue
        si_covered "$sib" "${in[@]}" && continue
        printf 'step-inputs: %s: its input %s names %s, which its declared inputs do not cover\n' "$name" "$ref" "$sib"
        findings=$((findings + 1))
      done < <(si_lib_siblings "$root" "$ref")
    done
  done < "$reg"

  [ "$n_plain" -gt 0 ] || { printf 'step-inputs: the registry listing names no plain step\n'; return 2; }
  printf 'step-inputs: %d step(s) — %d plain (%d whole-tree, %d declaring paths, %d undeclared%s), %d harness(es) not judged; %d of the %d declaring paths have an ubuntu job; %d finding(s)\n' \
    "$n_steps" "$n_plain" "$n_whole" "$n_paths" "${#undeclared[@]}" \
    "${undeclared[*]:+: ${undeclared[*]}}" "$n_harness" "$n_ubuntu" "$n_paths" "$findings"
  [ "$findings" -eq 0 ]
}

# si_shipped — lint the tracked tree. The registry is asked of the runner, the tracked list of git.
si_shipped() {
  local work="$1" out rc line
  bash scripts/selfcheck.sh --list > "$work/registry.tsv" \
    || { bad "step-inputs: scripts/selfcheck.sh --list failed — the registry could not be read"; return; }
  git ls-files > "$work/tracked.txt" \
    || { bad "step-inputs: git ls-files failed — the tracked tree could not be read"; return; }
  out="$(si_verdict . "$work/registry.tsv" "$work/tracked.txt" .github/workflows/ci.yml)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok
    printf '%s\n' "$out"
    return
  fi
  # Each finding is its own FAIL line, which is what `selfcheck.sh --summarize` harvests; the
  # closing summary (absent when the tree could not be read at all) is printed as it is.
  while IFS= read -r line; do
    case "$line" in
      'step-inputs: '*' step(s) — '*) printf '%s\n' "$line" ;;
      ?*) bad "$line" ;;
    esac
  done <<< "$out"
}

work="$(mktemp -d)" || { echo "check-step-inputs: FATAL — cannot create a scratch directory" >&2; exit 1; }
check_exit_guard "check-step-inputs" "rm -rf \"$work\""

if [ "$MODE" = check ]; then
  si_shipped "$work"
  check_summary "check-step-inputs"
  exit 0
fi

# ================================ --self-test ====================================================
si_shipped "$work"

# The shipped table excuses shipped steps; the fixtures below set their own entries.
SI_NOT_INPUT=()

# fx <name> — a fresh fixture tree under $work/<name>: three libraries (the first names the
# second), one suite that drives the first and globs a directory, one static lint, one function
# step, a harness, and a workflow whose ubuntu jobs run them. Prints the directory. Each case below
# edits ONE thing in its own copy.
fx() {
  local d="$work/$1"
  mkdir -p "$d/scripts/lib" "$d/base/docs" "$d/.github/workflows" || return 1
  printf '%s\n' '#!/usr/bin/env bash' 'ROOT="$(pwd)"' '. scripts/check-lib.sh' \
    '. "$ROOT/scripts/lib/one.sh"' 'for f in base/docs/*.md; do :; done' > "$d/scripts/check-one.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'git ls-files' > "$d/scripts/check-lint.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/check-mac.sh"
  printf '%s\n' '# helpers' > "$d/scripts/check-lib.sh"
  printf '%s\n' '#!/usr/bin/env bash' '. "$(dirname "${BASH_SOURCE[0]}")/two.sh"' > "$d/scripts/lib/one.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/lib/two.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/lib/three.sh"
  printf 'doc\n' > "$d/base/docs/a.md"
  printf '%s\n' 'name: ci' 'on: [push, pull_request]' 'jobs:' \
    '  one:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: bash scripts/check-one.sh' \
    '  lint:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: bash scripts/check-lint.sh' \
    '  gate-detector:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: echo detect' \
    '  mac:' '    runs-on: macos-latest' '    steps:' '      - run: bash scripts/check-mac.sh' \
    > "$d/.github/workflows/ci.yml"
  { printf 'one\tbash scripts/check-one.sh\tpool\tconcurrent\tscripts/check-one.sh,scripts/check-lib.sh,scripts/lib/one.sh,scripts/lib/two.sh,base/docs\tsuite\n'
    printf 'lint\tbash scripts/check-lint.sh\tpool\tconcurrent\t.\tstatic\n'
    printf 'detect\tstep_gate_detector\tpool\tconcurrent\tscripts/lib/three.sh\tsuite\n'
    printf 'one-mutation\tbash scripts/check-one.sh --mutation\tpool\tconcurrent\tscripts/check-one.sh\tsuite\n'
  } > "$d/registry.tsv"
  ( cd "$d" && find . -type f ! -name registry.tsv ! -name tracked.txt | sed 's#^\./##' | LC_ALL=C sort > tracked.txt ) || return 1
  printf '%s' "$d"
}
# lint <dir> — the verdict on a fixture; OUT and RC_ carry it.
lint() { OUT="$(si_verdict "$1" "$1/registry.tsv" "$1/tracked.txt" "$1/.github/workflows/ci.yml")"; RC_=$?; }
# reg_sub <dir> <awk-program> — rewrite the fixture's registry through awk (FS and OFS are TAB).
reg_sub() { awk -F'\t' -v OFS='\t' "$2" "$1/registry.tsv" > "$1/registry.tmp" && mv "$1/registry.tmp" "$1/registry.tsv"; }
# ci_sub <dir> <awk-program> — rewrite the fixture's workflow through awk.
ci_sub() { awk "$2" "$1/.github/workflows/ci.yml" > "$1/ci.tmp" && mv "$1/ci.tmp" "$1/.github/workflows/ci.yml"; }
# refuses <label> <dir> <fragment> — the verdict must be a finding (1) naming <fragment>.
refuses() {
  lint "$2"
  eq "$RC_" 1 "$1: refused"
  has "$OUT" "$3" "$1: …naming what is missing"
}

d="$(fx green)" || bad "could not build the green fixture"
lint "$d"
yes "$RC_" "a tree whose declarations cover what its suite names passes"
has "$OUT" "4 step(s) — 3 plain (1 whole-tree, 2 declaring paths, 0 undeclared), 1 harness(es) not judged; 2 of the 2 declaring paths have an ubuntu job; 0 finding(s)" \
  "…and says what it judged, so a pass over nothing is not a pass"

# THE CASE THE GUARD EXISTS FOR: a suite sources a tracked file its step does not declare.
d="$(fx undeclared-source)" && reg_sub "$d" '$1 == "one" { sub(/,scripts\/lib\/one\.sh/, "", $5) } { print }'
refuses undeclared-source "$d" 'one: scripts/check-one.sh names the tracked file scripts/lib/one.sh, which its declared inputs do not cover'
# …and one it EXECUTES, added to the suite after the declaration was written.
d="$(fx undeclared-exec)" && printf '%s\n' 'bash "$ROOT/scripts/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses undeclared-exec "$d" 'one: scripts/check-one.sh names the tracked file scripts/lib/three.sh, which its declared inputs do not cover'
# A directory the suite globs is a reference to the directory, and a file under it does not cover it.
d="$(fx undeclared-dir)" && reg_sub "$d" '$1 == "one" { sub(/,base\/docs$/, ",base/docs/a.md", $5) } { print }'
refuses undeclared-dir "$d" 'one: scripts/check-one.sh names the tracked directory base/docs, which its declared inputs do not cover'
# A glob that cuts a name mid-component refers to the directory the name is in…
d="$(fx glob-mid-name)" && printf '%s\n' 'ls scripts/lib/thr*.sh' >> "$d/scripts/check-one.sh"
refuses glob-mid-name "$d" 'names the tracked directory scripts/lib, which its declared inputs do not cover'
# …unless what precedes the glob character is itself a tracked file.
d="$(fx glob-after-file)" && printf '%s\n' 'grep -c "scripts/lib/two.sh?" log' >> "$d/scripts/check-one.sh"
lint "$d"; yes "$RC_" "a tracked file followed by a glob character is that file, not its directory"
# A path relative to the suite's own directory.
d="$(fx self-relative)" && printf '%s\n' '. "$(dirname "$0")/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses self-relative "$d" 'names the tracked file scripts/lib/three.sh'
# A braced root variable, and a quoted one with the path outside the quotes.
d="$(fx braced-root)" && printf '%s\n' 'cat "${ROOT}/scripts/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses braced-root "$d" 'names the tracked file scripts/lib/three.sh'
d="$(fx quoted-root)" && printf '%s\n' 'cat "$ROOT"/scripts/lib/three.sh' >> "$d/scripts/check-one.sh"
refuses quoted-root "$d" 'names the tracked file scripts/lib/three.sh'
# A path that climbs and comes back is the path it resolves to.
d="$(fx dotdot)" && printf '%s\n' 'cat "$ROOT/base/../scripts/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses dotdot "$d" 'names the tracked file scripts/lib/three.sh'
# A declared path that names nothing in the tree.
d="$(fx untracked-input)" && reg_sub "$d" '$1 == "one" { $5 = $5 ",scripts/lib/typo.sh" } { print }'
refuses untracked-input "$d" 'one: declared input scripts/lib/typo.sh is not a tracked file or directory'
# The suite itself.
d="$(fx suite-undeclared)" && reg_sub "$d" '$1 == "one" { sub(/^scripts\/check-one\.sh,/, "", $5) } { print }'
refuses suite-undeclared "$d" 'one: its own suite scripts/check-one.sh is not among its declared inputs'
# A library's sibling.
d="$(fx sibling-undeclared)" && reg_sub "$d" '$1 == "one" { sub(/,scripts\/lib\/two\.sh/, "", $5) } { print }'
refuses sibling-undeclared "$d" 'one: its input scripts/lib/one.sh names scripts/lib/two.sh, which its declared inputs do not cover'
# A static step that declares paths, and one that declares nothing.
d="$(fx static-narrow)" && reg_sub "$d" '$1 == "lint" { $5 = "scripts/check-lint.sh" } { print }'
refuses static-narrow "$d" 'lint: a static-tier step must declare the whole tree (.), got scripts/check-lint.sh'
d="$(fx static-undeclared)" && reg_sub "$d" '$1 == "lint" { $5 = "-" } { print }'
refuses static-undeclared "$d" 'lint: a static-tier step must declare the whole tree (.), got -'
# A step the scope can hold that no ubuntu job runs: only the macOS job names it.
d="$(fx no-ubuntu)" && printf 'mac\tbash scripts/check-mac.sh\tpool\tconcurrent\tscripts/check-mac.sh\tsuite\n' >> "$d/registry.tsv"
refuses no-ubuntu "$d" 'mac: no ubuntu job of ci.yml runs `bash scripts/check-mac.sh`'
# …and a command that is only a PREFIX of what a job runs is not that command.
d="$(fx ubuntu-prefix)" && ci_sub "$d" '{ sub(/bash scripts\/check-one\.sh/, "bash scripts/check-one.sh.bak") } { print }'
refuses ubuntu-prefix "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
# …nor is the command followed by a further argument, which is another step's command.
d="$(fx ubuntu-other-arg)" && ci_sub "$d" '{ sub(/bash scripts\/check-one\.sh/, "bash scripts/check-one.sh --self-test") } { print }'
refuses ubuntu-other-arg "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
# …nor is one that appears only in a comment.
d="$(fx ubuntu-comment)" && ci_sub "$d" '/run: bash scripts\/check-one\.sh/ { print "      # bash scripts/check-one.sh"; print "      - run: echo nothing"; next } { print }'
refuses ubuntu-comment "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
# A command followed by a pipe or a redirect is still that command.
d="$(fx ubuntu-piped)" && ci_sub "$d" '{ sub(/bash scripts\/check-one\.sh/, "bash scripts/check-one.sh 2>\\&1 | tee log") } { print }'
lint "$d"; yes "$RC_" "a command followed by a redirect and a pipe is still that command"
# A function step whose job is gone, and one this lint has no job for.
d="$(fx fn-job-gone)" && ci_sub "$d" '{ sub(/^  gate-detector:$/, "  renamed:") } { print }'
refuses fn-job-gone "$d" 'detect: the ubuntu job `gate-detector` that mirrors it is missing from ci.yml'
d="$(fx fn-unknown)" && printf 'novel\tstep_novel\tpool\tconcurrent\tscripts/lib/three.sh\tsuite\n' >> "$d/registry.tsv"
refuses fn-unknown "$d" 'novel: the function step `step_novel` has no ubuntu job named for it'

# THE WAIVER TABLE excuses exactly what it names.
d="$(fx waived)" && reg_sub "$d" '$1 == "one" { sub(/,base\/docs$/, "", $5) } { print }'
SI_NOT_INPUT=([one]="base/docs")
lint "$d"; yes "$RC_" "a path SI_NOT_INPUT lists for the step is not a finding"
d="$(fx waived-declared)"
refuses waived-declared "$d" 'one: SI_NOT_INPUT lists base/docs, which the step declares — remove the entry'
SI_NOT_INPUT=([one]="scripts/lib/three.sh")
d="$(fx waived-stale)"
refuses waived-stale "$d" 'one: SI_NOT_INPUT lists scripts/lib/three.sh, which its suite does not name — remove the entry'
SI_NOT_INPUT=([lint]="base/docs")
d="$(fx waived-other-step)" && reg_sub "$d" '$1 == "one" { sub(/,base\/docs$/, "", $5) } { print }'
refuses waived-other-step "$d" 'one: scripts/check-one.sh names the tracked directory base/docs'
SI_NOT_INPUT=()

# WHAT MUST NOT FIRE. An undeclared plain step is named, never failed; a step that always runs
# needs no ubuntu job; a fixture path under another variable, a bare word, a comment, a path that
# is not tracked and an absolute path are not references.
d="$(fx undeclared-step)" && reg_sub "$d" '$1 == "one" { $5 = "-" } { print }'
lint "$d"
yes "$RC_" "a plain step that declares nothing is not a finding"
has "$OUT" "1 undeclared: one)" "…and is named"
d="$(fx whole-tree-no-job)" && ci_sub "$d" '{ sub(/bash scripts\/check-lint\.sh/, "echo nothing") } { print }'
lint "$d"; yes "$RC_" "a whole-tree step always runs, so it needs no ubuntu job"
d="$(fx not-references)" && printf '%s\n' 'cp x "$fx/scripts/lib/three.sh"' '# bash scripts/lib/three.sh' \
  'echo "three.sh and lib and scripts"' 'cat scripts/lib/absent.sh' 'echo /scripts/lib/three.sh' \
  'echo "$OTHER"/scripts/lib/three.sh' >> "$d/scripts/check-one.sh"
lint "$d"
yes "$RC_" "a fixture path, a comment, a bare word, an untracked path and an absolute path are not references"
# A directory input covers what is under it.
d="$(fx dir-covers)" && reg_sub "$d" '$1 == "one" { $5 = "scripts,base" } { print }'
lint "$d"
yes "$RC_" "a declared directory covers every path under it"

# AN UNREADABLE TREE IS NEVER A PASS (2, distinct from a finding).
d="$(fx empty-list)" && : > "$d/tracked.txt"
lint "$d"; eq "$RC_" 2 "an empty tracked-file list is refused, not passed"
d="$(fx empty-registry)" && : > "$d/registry.tsv"
lint "$d"; eq "$RC_" 2 "an empty registry listing is refused, not passed"
d="$(fx no-workflow)" && rm -f "$d/.github/workflows/ci.yml"
lint "$d"; eq "$RC_" 2 "a missing workflow is refused, not read as a tree with no ubuntu job to ask"
d="$(fx no-ubuntu-job)" && ci_sub "$d" '{ sub(/ubuntu-26\.04/, "macos-latest") } { print }'
lint "$d"; eq "$RC_" 2 "a workflow with no ubuntu job is refused"
d="$(fx harness-only)" && reg_sub "$d" '$1 ~ /-mutation$/ { print }'
lint "$d"; eq "$RC_" 2 "a registry with no plain step is refused"

check_summary "check-step-inputs --self-test"
