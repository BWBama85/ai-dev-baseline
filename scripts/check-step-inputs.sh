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
#   entry point  …and every tracked path that a declared entry point (`install.sh`,
#                `uninstall.sh`, a file under `bin/`) names. A declared DIRECTORY is read as the
#                libraries and entry points tracked under it, so a broader input checks no less
#   function     …and a function step that declares paths declares `scripts/selfcheck.sh`, where
#                its body lives
#   ubuntu       every plain step that declares paths — every step a scoped run can hold — is
#                wired into an ubuntu job of `.github/workflows/ci.yml`, so a suite the macOS leg
#                scopes out of a pull request still has a job that runs it on that pull request
#
# WHAT "WIRED" MEANS, AND WHAT IT DOES NOT PROVE. One form counts: a step whose `run:` is a single
# line that IS the step's command (`run: bash scripts/check-x.sh`, optionally quoted; for a function
# step, `run: bash scripts/selfcheck.sh --only <step>`), whose every key is one of `name`, `run`,
# `env`, `id` and `timeout-minutes`, in a job whose every key is one of `name`, `runs-on`,
# `timeout-minutes`, `permissions`, `env` and `steps`, in a workflow with no top-level `defaults`.
# A key this does not list — `if`, `continue-on-error`, `shell`, `needs`, `strategy`, however it is
# quoted and wherever in the job it sits — a block or continued scalar, a pipe, a second argument
# or a trailing comment each make the step not count. The lint does not decide what such a form
# would do; it refuses to count it.
#
# This is a WIRING PIN, not a proof of execution (owner decision, D157). Three review rounds each
# found a way text that runs nothing could satisfy a looser reading, and a text lint cannot close
# that class: an `env` that changes `PATH` or `BASH_ENV`, an earlier step that rewrites the tree or
# `GITHUB_PATH`, and a runner image without the tool all change what the counted line does. Those
# are review's to catch, as they are for every other workflow pin in this repo.
#
# WHAT "NAMES" MEANS. A reference is a run of path characters (`[A-Za-z0-9_./-]`) that resolves to
# a tracked file or directory and is spelled one of three ways:
#   rooted   after a ROOT VARIABLE: `$PWD` itself; a name assigned (plainly, or with `readonly`,
#            `local`, `export`, `declare`) from `$(pwd …)`, a backquoted `pwd`, `$PWD` or `${PWD}`;
#            the entry points' bootstrap variable; or a name assigned from exactly one of those.
#            Written `$ROOT/x`, `${ROOT}/x`, or with only quotes and a closing brace between the
#            name and the path (`"$ROOT"/x`, `'…'"$ROOT"'/x'`). An assignment is read where
#            it starts its line, and all of them are collected before any use is read, so
#            their order in the file does not matter
#   self     after `$(dirname "$0")`, relative to the file's own directory
#   bare     relative to the tree's root, with at least one `/`
# A name that stops at a `/` (`base/workflows/*.md`, `agents/$agent/skills`) is a reference to the
# directory it stops in. A name cut mid-component by a glob (`scripts/check-*.sh`) or by a byte
# outside printable ASCII (a name this alphabet cannot hold) is a reference to every tracked file
# that begins with it, or to its directory when none does. A trailing `.`, `:` or `-` is read as
# punctuation only when the name is not tracked with it. A line whose first non-blank character is
# `#` is not read. A path quoted in an assertion's message is read like any other, so a suite can
# be made to declare a file it only mentions; that direction costs minutes and never coverage.
# ANY OTHER SPELLING IS NOT READ: a root reached through a parameter expansion (`${ROOT%/}/x`,
# `${ROOT:?}/x`), a root variable assigned some other way, a path assembled from parts.
#
# WHAT IT CANNOT SEE, stated rather than implied: a path a suite computes, a tree a suite copies
# whole and runs from the copy, a file a library reads, what a script other than a library or an
# entry point goes on to run, and what a function step does beyond the file its body is in. Those
# are declared by hand. The bound is acceptable because of the `ubuntu` rule: an under-declared
# suite is skipped locally and on the macOS leg of a pull request, and is still run by its ubuntu
# job on that pull request and by the macOS leg on the default branch.
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
  # Copied into the tree a `--mutation` pool mutates; the plain suite never runs either.
  [mutation-gate]="install.sh uninstall.sh"
)

# si_load_tree <list-file> — fill SI_FILES and SI_DIRS from a newline-delimited list of tracked
# paths, remember the list itself (SI_LIST) for the scans that read it whole, and the tracked entry
# points (SI_ENTRY) a declared directory stands for. Returns 1 on an empty list: a lint over no files would pass everything.
declare -A SI_FILES=() SI_DIRS=()
declare -a SI_ENTRY=()
SI_LIST=""
si_load_tree() {
  local f d n=0
  SI_FILES=(); SI_DIRS=(); SI_ENTRY=(); SI_LIST="$1"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SI_FILES["$f"]=1; n=$((n + 1))
    case "$f" in install.sh|uninstall.sh|bin/*) SI_ENTRY+=("$f") ;; esac
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
    # The root variables, collected in a first pass over the file so a use above the assignment
    # still counts: PWD itself, a name assigned from the working directory, the bootstrap variable
    # of the entry points (`_adb_boot_abs`, the root of the clone by the stanza
    # `check-bootstrap.sh` pins), and a name assigned from exactly one of those. (No apostrophe
    # may appear in this program: it is one single-quoted shell word.)
    BEGIN { rootvar["PWD"] = 1 }
    FNR == NR {
      l = $0
      sub(/^[[:space:]]*/, "", l)
      sub(/^(readonly|local|export|typeset|declare([[:space:]]+-[A-Za-z]+)*)[[:space:]]+/, "", l)
      if (l !~ /^[A-Za-z_][A-Za-z0-9_]*=/) next
      v = l; sub(/=.*/, "", v)
      val = substr(l, length(v) + 2); sub(/^"/, "", val)
      if (val ~ /^\$\([[:space:]]*pwd([^A-Za-z0-9_]|$)/ || val ~ /^`[[:space:]]*pwd([^A-Za-z0-9_]|$)/ ||
          val ~ /^\$PWD([^A-Za-z0-9_]|$)/ || val ~ /^\$\{PWD\}/ ||
          (v == "_adb_boot_abs" && val ~ /^\$\(cd -- /)) {
        rootvar[v] = 1
      } else if (match(val, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]*$/)) {
        src = val; sub(/^\$\{?/, "", src); sub(/\}?"?[[:space:]]*$/, "", src)
        alias[v] = src
      }
      next
    }
    # Aliases are resolved once every assignment has been collected, to a fixpoint, so an alias
    # written above the root it names (in a function called later) is still one.
    FNR == 1 {
      do {
        grew = 0
        for (v in alias) if (!(v in rootvar) && (alias[v] in rootvar)) { rootvar[v] = 1; grew = 1 }
      } while (grew)
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
          tok = substr(tok, n + 1); rooted = 1
        } else if (substr(tok, 1, 1) == "/") {
          # Only quotes and a closing brace may sit between a root variable and its path:
          # `${ROOT}/x`, `"$ROOT"/x`, and the quote concatenation `"$ROOT"` + a quoted `/x`.
          gap = rootend ? substr(line, rootend, start - rootend) : "-"
          if (gap ~ /^[}"\047]+$/) { tok = substr(tok, 2); rooted = 1 }
          else if (pre ~ /dirname "\$0"\)$/) { tok = selfdir tok; rooted = 1 }
          else { rootend = 0; continue }
        } else if (index(tok, "/") == 0) { rootend = 0; continue }
        else rooted = 0
        rootend = 0
        # A name that stops at a `/` (before an expansion, a glob or a brace) is the directory it
        # stops in. One cut mid-component — by a glob character, or by a byte outside printable
        # ASCII, which this alphabet cannot hold — is flagged `g`: the caller reads it as every
        # tracked file beginning with it.
        flag = "-"
        if (tok ~ /\/$/) sub(/\/+$/, "", tok)
        else if (nxt ~ /[*?[]/ || (nxt != "" && nxt !~ /[ -~\t]/)) flag = "g"
        tok = norm(tok)
        # A bare glob-cut name must still have a `/` once resolved: `s/.*` in a sed program
        # resolves to `s`, and every tracked file beginning with `s` is not what it names.
        if (tok == "" || (flag == "g" && !rooted && index(tok, "/") == 0)) continue
        print flag "\t" tok
      }
    }
  ' "$file" "$file"
}

# si_refs <root> <file> — the tracked paths <root>/<file> names: `file<TAB><path>` or
# `directory<TAB><path>` lines, deduplicated, never the file itself. Returns non-zero when the file
# cannot be read or the scan itself fails.
#
# A candidate is read EXACTLY first. Only one that is not tracked as spelled is retried without
# its trailing `.`, `:` or `-` (a sentence's end, a `path:line`), so a file whose name ends in one
# of those is still that file. A glob-cut candidate is every tracked file beginning with it — the
# glob's own tail is not read, so this can only name more than the glob matches — or, when no
# tracked file does, the directory it is in.
si_refs() {
  local root="$1" file="$2"
  local -a st=()
  [ -f "$root/$file" ] && [ -r "$root/$file" ] || return 1
  # One pass resolves every candidate against the tracked list (SI_LIST, set by si_load_tree): a
  # glob-cut name is compared with every tracked path, which a shell loop pays for per name.
  ( cd "$root" && si_tokens "$file" ) | LC_ALL=C awk -F'\t' -v self="$file" '
    function emit(p) {
      if (p == self || (p in seen)) return
      seen[p] = 1
      if (p in F) print "file\t" p
      else if (p in D) print "directory\t" p
    }
    FNR == NR {
      if ($0 == "") next
      F[$0] = 1; L[++n] = $0
      d = $0; while (sub(/\/[^\/]*$/, "", d)) D[d] = 1
      next
    }
    {
      flag = $1; tok = $2
      if (tok == "") next
      if (flag == "g") {
        hit = 0
        for (i = 1; i <= n; i++) if (index(L[i], tok) == 1) { emit(L[i]); hit = 1 }
        if (!hit && sub(/\/[^\/]*$/, "", tok)) emit(tok)
        next
      }
      if (!(tok in F) && !(tok in D))
        while (tok ~ /[.:-]$/) {
          tok = substr(tok, 1, length(tok) - 1)
          if (tok == "" || (tok in F) || (tok in D)) break
        }
      if (tok != "") emit(tok)
    }
  ' "$SI_LIST" -
  st=("${PIPESTATUS[@]}")
  [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ]
}

# si_lib_siblings <root> <lib> — the `scripts/lib/*.sh` files <lib> (itself one) names by basename,
# one per line; non-zero when it cannot be read or the scan fails. A library reaches its siblings through its own directory, whatever variable holds
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
  done < <(LC_ALL=C awk '!/^[[:space:]]*#/ { l = $0; while (match(l, /[A-Za-z0-9_.-]+\.sh/)) { print substr(l, RSTART, RLENGTH); l = substr(l, RSTART + RLENGTH) } }' "$root/$lib")
  wait "$!"
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

# si_ubuntu_runs <ci.yml> — `<job-key><TAB><command>` for every command an ubuntu job is wired
# to run, by the one form the header defines ("wired"). Structure comes from the shared reader
# (`adb_wf_jobs`: its JOB, RANGE, RUNSON and STEP records); the keys are judged here by ALLOWLIST,
# so a key or a scalar style this does not know is refused, never interpreted. Returns 1 when the
# reader fails or when no such command exists, so an unreadable workflow is never read as "nothing
# runs there".
si_ubuntu_runs() {
  local wf="$1" recs spans out
  recs="$(adb_wf_jobs "$wf" 2>/dev/null)" || return 1
  spans="$(printf '%s\n' "$recs" | awk -F'\t' '
      $1 == "JOB"    { key[$2] = $3 }
      $1 == "RANGE"  { s[$2] = $3; e[$2] = $4 }
      $1 == "RUNSON" { if ($3 ~ /^ubuntu-/) u[$2] = 1 }
      $1 == "STEP"   { n[$2]++; st[$2, n[$2]] = $4 }
      END {
        for (j in u) {
          printf "J\t%s\t%s\t%s\n", key[j], s[j], e[j]
          for (k = 1; k <= n[j]; k++)
            printf "S\t%s\t%s\t%s\n", key[j], st[j, k], (k < n[j]) ? st[j, k + 1] - 1 : e[j]
        }
      }')" || return 1
  [ -n "$spans" ] || return 1
  out="$(printf '%s\n' "$spans" | LC_ALL=C awk -F'\t' '
      function lead(l) { match(l, /^ */); return RLENGTH }
      FNR == NR {
        if ($1 == "J") { nj++; jkey[nj] = $2; js[nj] = $3; je[nj] = $4 }
        else { ns++; skey[ns] = $2; ss[ns] = $3; se[ns] = $4 }
        next
      }
      { L[FNR] = $0; last = FNR; if ($0 ~ /^defaults[[:space:]]*:/ || $0 ~ /^["\047]defaults["\047][[:space:]]*:/) wfdefaults = 1 }
      END {
        # A workflow-level `defaults` can change every step: nothing counts under one.
        if (wfdefaults) exit
        # A job counts only when every key at its own level is one this knows — over its WHOLE
        # range, since a key may follow the steps.
        for (j = 1; j <= nj; j++) {
          col = -1; good[jkey[j]] = 1
          for (i = js[j] + 1; i <= je[j]; i++) {
            l = L[i]
            if (l ~ /^[[:space:]]*(#|$)/) continue
            if (col < 0) col = lead(l)
            if (lead(l) != col) continue
            if (substr(l, col + 1) !~ /^(name|runs-on|timeout-minutes|permissions|env|steps):/) good[jkey[j]] = 0
          }
          if (col < 0) good[jkey[j]] = 0
        }
        # A step counts only when every key at its own level is one this knows, and its command
        # only when `run:` holds it on that one line: a deeper line straight after `run:` continues
        # the scalar, and what it adds is not read.
        for (k = 1; k <= ns; k++) {
          if (!good[skey[k]]) continue
          l = L[ss[k]]
          if (!match(l, /^ *-[ ]+/)) continue
          col = RLENGTH; okstep = 1; cmd = ""; lastkey = ""
          for (i = ss[k]; i <= se[k]; i++) {
            l = L[i]
            if (i == ss[k]) l = sprintf("%" col "s", "") substr(l, col + 1)
            if (l ~ /^[[:space:]]*(#|$)/) continue
            if (lead(l) != col) { if (lastkey == "run") { okstep = 0; break } continue }
            t = substr(l, col + 1)
            if (t !~ /^(name|run|env|id|timeout-minutes):/) { okstep = 0; break }
            lastkey = t; sub(/:.*/, "", lastkey)
            if (t ~ /^run:/) {
              cmd = t; sub(/^run:[[:space:]]*/, "", cmd); sub(/[[:space:]]+$/, "", cmd)
              if (cmd ~ /^".*"$/ || cmd ~ /^\047.*\047$/) cmd = substr(cmd, 2, length(cmd) - 2)
            }
          }
          if (okstep && cmd != "" && cmd !~ /^[|>]/) print skey[k] "\t" cmd
        }
      }
    ' - "$wf")" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# si_verdict <root> <registry.tsv> <tracked-list> <ci.yml> — the whole lint over one tree. Prints
# one `step-inputs: <step>: <finding>` line per finding and a closing summary line; returns 0 when
# there is no finding, 1 when there is one, 2 when the tree could not be read at all.
si_verdict() {
  local root="$1" reg="$2" list="$3" wf="$4"
  local name cmd inputs tier suite kind ref dep scan refs u_text want findings=0
  local n_steps=0 n_whole=0 n_paths=0 n_harness=0 n_ubuntu=0 n_plain=0
  local -a in=() undeclared=() waived=() named=() deps=()
  local -A scanned=() scan_rc=()
  si_load_tree "$list" || { printf 'step-inputs: the tracked-file list is empty or unreadable\n'; return 2; }
  [ -s "$reg" ] || { printf 'step-inputs: the registry listing is empty\n'; return 2; }
  u_text="$(si_ubuntu_runs "$wf")" || { printf 'step-inputs: %s could not be read, or no ubuntu job of it runs anything in the form this lint counts\n' "$wf"; return 2; }

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

    # ubuntu: an ubuntu job is wired to run the step's command (the header says what counts).
    # A function step has no command of its own, so its job runs it through the runner by name.
    want="$cmd"
    case "$cmd" in
      "bash "*) : ;;
      *) want="bash scripts/selfcheck.sh --only $name"
         # function: the body is in the runner, which the scan below cannot read as a suite.
         if ! si_covered scripts/selfcheck.sh "${in[@]}"; then
           printf 'step-inputs: %s: a function step runs code in scripts/selfcheck.sh, which its declared inputs do not cover\n' "$name"
           findings=$((findings + 1))
         fi ;;
    esac
    if printf '%s\n' "$u_text" | awk -F'\t' -v c="$want" '$2 == c { f = 1 } END { exit !f }'; then
      n_ubuntu=$((n_ubuntu + 1))
    else
      printf 'step-inputs: %s: no ubuntu job of %s runs `%s` in the one form this lint counts — a pull request that does not touch its inputs may run it on no platform\n' "$name" "${wf##*/}" "$want"
      findings=$((findings + 1))
    fi

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
          # The scan's STATUS is read: a suite that could not be scanned names nothing, which
          # would otherwise read as a suite with nothing to declare.
          if ! refs="$(si_refs "$root" "$suite")"; then
            printf 'step-inputs: %s: its suite %s could not be scanned, so what it names is unknown\n' "$name" "$suite"
            findings=$((findings + 1))
          fi
          while IFS=$'\t' read -r kind ref; do
            [ -n "$ref" ] || continue
            named+=("$ref")
            si_covered "$ref" "${in[@]}" && continue
            si_listed "$ref" "${waived[@]}" && continue
            printf 'step-inputs: %s: %s names the tracked %s %s, which its declared inputs do not cover\n' "$name" "$suite" "$kind" "$ref"
            findings=$((findings + 1))
          done <<< "$refs"
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

    # library and entry point: what each declared one names, read the same way. A declared
    # DIRECTORY stands for the entry points tracked under it (its libraries are under it too, so
    # their siblings are covered already): a broader input must not check less than a narrow one.
    deps=()
    for dep in "${in[@]}"; do
      dep="${dep%/}"
      if [ -n "${SI_FILES[$dep]+x}" ]; then deps+=("$dep"); continue; fi
      for ref in "${SI_ENTRY[@]}"; do
        case "$ref" in "$dep"/*) deps+=("$ref") ;; esac
      done
    done
    for dep in "${deps[@]}"; do
      case "$dep" in
        scripts/lib/*.sh) scan=si_lib_siblings ;;
        install.sh|uninstall.sh|bin/*) scan=si_refs ;;
        *) continue ;;
      esac
      # Scanned ONCE per file: `common.sh` is an input of nearly every step.
      if [ -z "${scanned[$dep]+x}" ]; then
        if scanned["$dep"]="$("$scan" "$root" "$dep")"; then scan_rc["$dep"]=0; else scan_rc["$dep"]=1; fi
      fi
      refs="${scanned[$dep]}"
      if [ "${scan_rc[$dep]}" -ne 0 ]; then
        printf 'step-inputs: %s: its input %s could not be scanned, so what it names is unknown\n' "$name" "$dep"
        findings=$((findings + 1))
      fi
      while IFS= read -r ref; do
        ref="${ref#*$'\t'}"
        [ -n "$ref" ] || continue
        si_covered "$ref" "${in[@]}" && continue
        printf 'step-inputs: %s: its input %s names %s, which its declared inputs do not cover\n' "$name" "$dep" "$ref"
        findings=$((findings + 1))
      done <<< "$refs"
    done
  done < "$reg"

  [ "$n_plain" -gt 0 ] || { printf 'step-inputs: the registry listing names no plain step\n'; return 2; }
  printf 'step-inputs: %d step(s) — %d plain (%d whole-tree, %d declaring paths, %d undeclared%s), %d harness(es) not judged; %d of the %d declaring paths have an ubuntu job; %d finding(s)\n' \
    "$n_steps" "$n_plain" "$n_whole" "$n_paths" "${#undeclared[@]}" \
    "${undeclared[*]:+: ${undeclared[*]}}" "$n_harness" "$n_ubuntu" "$n_paths" "$findings"
  [ "$findings" -eq 0 ]
}

# si_tracked_list <repo> <out-file> — write <repo>'s tracked paths to <out-file>, one per line.
# NUL-delimited and unquoted from git, so a name git would otherwise QUOTE (any byte outside
# ASCII) arrives as itself. A path holding a newline cannot be carried one per line: it is refused
# (1, with the reason on stdout), never read as two shorter names.
si_tracked_list() {
  local repo="$1" out="$2"
  git -C "$repo" -c core.quotePath=false ls-files -z > "$out.z" 2>/dev/null \
    || { printf 'git ls-files failed, so the tracked tree could not be read'; return 1; }
  tr '\0' '\n' < "$out.z" > "$out" || { printf 'the tracked-file list could not be written'; return 1; }
  if [ "$(tr -cd '\0' < "$out.z" | wc -c | tr -d ' ')" != "$(wc -l < "$out" | tr -d ' ')" ]; then
    printf 'a tracked path holds a newline, which this lint cannot carry'; return 1
  fi
}

# si_shipped — lint the tracked tree. The registry is asked of the runner, the tracked list of git.
si_shipped() {
  local work="$1" out rc line why n_named=0
  bash scripts/selfcheck.sh --list > "$work/registry.tsv" \
    || { bad "step-inputs: scripts/selfcheck.sh --list failed — the registry could not be read"; return; }
  why="$(si_tracked_list . "$work/tracked.txt")" || { bad "step-inputs: $why — it judged nothing"; return; }
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
      ?*) bad "$line"; n_named=$((n_named + 1)) ;;
    esac
  done <<< "$out"
  # EVERY unsuccessful verdict is a failure, including one that said nothing: a scan killed
  # before it printed a finding has judged nothing, and that must not read as a clean tree.
  [ "$n_named" -gt 0 ] || bad "step-inputs: the lint exited $rc without naming a finding — it judged nothing it can vouch for"
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

# A VERDICT THAT FAILS IN SILENCE is a failure of the shipped lint: with the verdict replaced by one
# that exits non-zero and prints nothing, the shipped-tree check must record a failure.
( si_verdict() { return 137; }; mkdir -p "$work/silent"; rejects si_shipped "$work/silent" )
yes "$?" "a shipped-tree verdict that exits non-zero with no output is recorded as a failure"
( si_verdict() { printf 'step-inputs: x: a finding\n'; return 1; }; mkdir -p "$work/loud"; rejects si_shipped "$work/loud" )
yes "$?" "…and so is one that names a finding"

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
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/selfcheck.sh"
  printf '%s\n' '# helpers' > "$d/scripts/check-lib.sh"
  printf '%s\n' '#!/usr/bin/env bash' '. "$(dirname "${BASH_SOURCE[0]}")/two.sh"' > "$d/scripts/lib/one.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/lib/two.sh"
  printf '%s\n' '#!/usr/bin/env bash' > "$d/scripts/lib/three.sh"
  printf 'doc\n' > "$d/base/docs/a.md"
  printf '%s\n' 'name: ci' 'on: [push, pull_request]' 'jobs:' \
    '  one:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: bash scripts/check-one.sh' \
    '  lint:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: bash scripts/check-lint.sh' \
    '  gate-detector:' '    runs-on: ubuntu-26.04' '    steps:' '      - run: bash scripts/selfcheck.sh --only detect' \
    '  mac:' '    runs-on: macos-latest' '    steps:' '      - run: bash scripts/check-mac.sh' \
    > "$d/.github/workflows/ci.yml"
  { printf 'one\tbash scripts/check-one.sh\tpool\tconcurrent\tscripts/check-one.sh,scripts/check-lib.sh,scripts/lib/one.sh,scripts/lib/two.sh,base/docs\tsuite\n'
    printf 'lint\tbash scripts/check-lint.sh\tpool\tconcurrent\t.\tstatic\n'
    printf 'detect\tstep_gate_detector\tpool\tconcurrent\tscripts/lib/three.sh,scripts/selfcheck.sh\tsuite\n'
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
# A glob that cuts a name mid-component refers to every tracked file beginning with it…
d="$(fx glob-mid-name)" && printf '%s\n' 'ls scripts/lib/thr*.sh' >> "$d/scripts/check-one.sh"
refuses glob-mid-name "$d" 'names the tracked file scripts/lib/three.sh, which its declared inputs do not cover'
# …to the directory it is in when no tracked file does…
d="$(fx glob-no-match)" && printf '%s\n' 'ls scripts/lib/zz*.sh' >> "$d/scripts/check-one.sh"
refuses glob-no-match "$d" 'names the tracked directory scripts/lib, which its declared inputs do not cover'
# …and a prefix that is itself a tracked file does not make the glob exact: `two.sh*` is also
# `two.sh.bak`.
d="$(fx glob-after-file)" && printf '%s\n' 'grep -c "scripts/lib/two.sh?" log' >> "$d/scripts/check-one.sh"
lint "$d"; yes "$RC_" "a glob whose every tracked match is declared passes"
d="$(fx glob-prefix-file)" && printf 'bak\n' > "$d/scripts/lib/two.sh.bak" && printf '%s\n' 'scripts/lib/two.sh.bak' >> "$d/tracked.txt" \
  && printf '%s\n' 'for f in scripts/lib/two.sh*; do bash "$f"; done' >> "$d/scripts/check-one.sh"
refuses glob-prefix-file "$d" 'names the tracked file scripts/lib/two.sh.bak, which its declared inputs do not cover'
# A name is read EXACTLY before its last character is read as punctuation.
d="$(fx trailing-dash)" && printf 'x\n' > "$d/scripts/lib/three-" && printf '%s\n' 'scripts/lib/three-' >> "$d/tracked.txt" \
  && printf '%s\n' 'bash scripts/lib/three-' >> "$d/scripts/check-one.sh"
refuses trailing-dash "$d" 'names the tracked file scripts/lib/three-, which its declared inputs do not cover'
d="$(fx sentence-end)" && printf '%s\n' 'echo "then it runs scripts/lib/three.sh."' >> "$d/scripts/check-one.sh"
refuses sentence-end "$d" 'names the tracked file scripts/lib/three.sh, which its declared inputs do not cover'
# A path relative to the suite's own directory.
d="$(fx self-relative)" && printf '%s\n' '. "$(dirname "$0")/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses self-relative "$d" 'names the tracked file scripts/lib/three.sh'
# A braced root variable, and a quoted one with the path outside the quotes.
d="$(fx braced-root)" && printf '%s\n' 'cat "${ROOT}/scripts/lib/three.sh"' >> "$d/scripts/check-one.sh"
refuses braced-root "$d" 'names the tracked file scripts/lib/three.sh'
d="$(fx quoted-root)" && printf '%s\n' 'cat "$ROOT"/scripts/lib/three.sh' >> "$d/scripts/check-one.sh"
refuses quoted-root "$d" 'names the tracked file scripts/lib/three.sh'
# Every spelling of a root variable the header lists.
names_three() {   # <label> <line>… — a suite carrying these lines names scripts/lib/three.sh
  local label="$1" d
  shift
  d="$(fx "$label")" && printf '%s\n' "$@" >> "$d/scripts/check-one.sh"
  refuses "$label" "$d" 'names the tracked file scripts/lib/three.sh'
}
names_three root-pwd-direct   'cat "$PWD/scripts/lib/three.sh"'
names_three root-pwd-braced   'HERE="${PWD}"' '. "$HERE/scripts/lib/three.sh"'
names_three root-readonly     'readonly TOP="$(pwd)"' '. "$TOP/scripts/lib/three.sh"'
names_three root-backquoted   'TOP=`pwd`' '. "$TOP/scripts/lib/three.sh"'
names_three root-alias        'TOP="$ROOT"' '. "$TOP/scripts/lib/three.sh"'
names_three root-alias-early  'early() {' '  TOP="$LATER"' '  . "$TOP/scripts/lib/three.sh"' '}' 'LATER="$(pwd)"' 'early'
names_three root-concatenated "bash -c '. '\"\$ROOT\"'/scripts/lib/three.sh'"
# A name this alphabet cannot hold is every tracked file beginning with what it could read.
d="$(fx non-ascii)" && printf 'x\n' > "$d/scripts/lib/unicodé.sh" && printf '%s\n' 'scripts/lib/unicodé.sh' >> "$d/tracked.txt" \
  && printf '%s\n' '. "$ROOT/scripts/lib/unicodé.sh"' >> "$d/scripts/check-one.sh"
refuses non-ascii "$d" 'names the tracked file scripts/lib/unicodé.sh, which its declared inputs do not cover'
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
# An entry point's dependency: what a declared `bin/` file names through the bootstrap stanza's
# root variable, and through a name assigned from it.
d="$(fx entry-undeclared)" && mkdir -p "$d/bin" \
  && printf '%s\n' '#!/usr/bin/env bash' '_adb_boot_abs="$(cd -- "$_adb_boot_dir/.." && pwd && printf X)"' \
       'REPO="$_adb_boot_abs"' '. "$REPO/scripts/lib/three.sh"' > "$d/bin/tool" \
  && printf '%s\n' 'bin/tool' >> "$d/tracked.txt" \
  && reg_sub "$d" '$1 == "one" { $5 = $5 ",bin/tool" } { print }'
refuses entry-undeclared "$d" 'one: its input bin/tool names scripts/lib/three.sh, which its declared inputs do not cover'
d="$(fx entry-declared)" && mkdir -p "$d/bin" \
  && printf '%s\n' '#!/usr/bin/env bash' '_adb_boot_abs="$(cd -- "$_adb_boot_dir/.." && pwd && printf X)"' \
       'REPO="$_adb_boot_abs"' '. "$REPO/scripts/lib/three.sh"' > "$d/bin/tool" \
  && printf '%s\n' 'bin/tool' >> "$d/tracked.txt" \
  && reg_sub "$d" '$1 == "one" { $5 = $5 ",bin/tool,scripts/lib/three.sh" } { print }'
lint "$d"; yes "$RC_" "an entry point whose named paths are declared passes"
# …and a DIRECTORY input stands for the entry points under it: broader must not check less.
d="$(fx entry-under-dir)" && mkdir -p "$d/bin" \
  && printf '%s\n' '#!/usr/bin/env bash' '_adb_boot_abs="$(cd -- "$_adb_boot_dir/.." && pwd && printf X)"' \
       'REPO="$_adb_boot_abs"' '. "$REPO/scripts/lib/three.sh"' > "$d/bin/tool" \
  && printf '%s\n' 'bin/tool' >> "$d/tracked.txt" \
  && reg_sub "$d" '$1 == "one" { $5 = $5 ",bin" } { print }'
refuses entry-under-dir "$d" 'one: its input bin/tool names scripts/lib/three.sh, which its declared inputs do not cover'
# A variable that is NOT assigned from a root is not one, whatever it is called.
d="$(fx not-a-root)" && printf '%s\n' 'REPO="$work/repo"' 'cat "$REPO/scripts/lib/three.sh"' >> "$d/scripts/check-one.sh"
lint "$d"; yes "$RC_" "a path under a variable assigned from somewhere else is not a reference"
# A suite, and a declared library, that cannot be read are findings, never suites that name nothing.
if [ "$(id -u)" -ne 0 ]; then
  d="$(fx suite-unreadable)" && chmod 000 "$d/scripts/check-one.sh"
  refuses suite-unreadable "$d" 'one: its suite scripts/check-one.sh could not be scanned, so what it names is unknown'
  chmod 644 "$d/scripts/check-one.sh"
  d="$(fx lib-unreadable)" && chmod 000 "$d/scripts/lib/one.sh"
  refuses lib-unreadable "$d" 'one: its input scripts/lib/one.sh could not be scanned, so what it names is unknown'
  chmod 644 "$d/scripts/lib/one.sh"
else
  printf 'SKIP: the unreadable-file cases need a user a file mode can refuse (running as root)\n'
fi
# A static step that declares paths, and one that declares nothing.
d="$(fx static-narrow)" && reg_sub "$d" '$1 == "lint" { $5 = "scripts/check-lint.sh" } { print }'
refuses static-narrow "$d" 'lint: a static-tier step must declare the whole tree (.), got scripts/check-lint.sh'
d="$(fx static-undeclared)" && reg_sub "$d" '$1 == "lint" { $5 = "-" } { print }'
refuses static-undeclared "$d" 'lint: a static-tier step must declare the whole tree (.), got -'
# A step the scope can hold that no ubuntu job runs: only the macOS job names it.
d="$(fx no-ubuntu)" && printf 'mac\tbash scripts/check-mac.sh\tpool\tconcurrent\tscripts/check-mac.sh\tsuite\n' >> "$d/registry.tsv"
refuses no-ubuntu "$d" 'mac: no ubuntu job of ci.yml runs `bash scripts/check-mac.sh`'
# ONE FORM COUNTS: a single-line `run:` that IS the command. Each case below is a form that might
# run the suite and is refused, because this lint does not decide what it would do.
# run_as <dir> <line>… — replace the `one` job's step with the given lines.
run_as() {
  local d="$1" prog='/run: bash scripts\/check-one\.sh/ {' l
  shift
  for l in "$@"; do prog="$prog print \"$l\";"; done
  ci_sub "$d" "$prog next } { print }"
}
uncertain() {   # <label> <line>… — a workflow whose `one` step is spelled so must be refused
  local label="$1" d
  shift
  d="$(fx "$label")" && run_as "$d" "$@"
  refuses "$label" "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
}
uncertain ubuntu-prefix      '      - run: bash scripts/check-one.sh.bak'
uncertain ubuntu-other-arg   '      - run: bash scripts/check-one.sh --self-test'
uncertain ubuntu-comment     '      # bash scripts/check-one.sh' '      - run: echo nothing'
uncertain ubuntu-in-string   "      - run: echo 'bash scripts/check-one.sh'"
uncertain ubuntu-piped       '      - run: bash scripts/check-one.sh 2>&1 | tee log'
uncertain ubuntu-yaml-note   '      - run: bash scripts/check-one.sh  # a note'
uncertain ubuntu-block       '      - name: one' '        run: |' '          bash scripts/check-one.sh'
uncertain ubuntu-folded      '      - name: one' '        run: >' '          echo' '          bash scripts/check-one.sh'
uncertain ubuntu-shell-if    '      - name: one' '        run: |' '          if false; then' '            bash scripts/check-one.sh' '          fi'
uncertain ubuntu-step-if     '      - name: one' '        if: false' '        run: bash scripts/check-one.sh'
uncertain ubuntu-if-after    '      - run: bash scripts/check-one.sh' '        if: false'
uncertain ubuntu-quoted-if   '      - name: one' "        'if': false" '        run: bash scripts/check-one.sh'
uncertain ubuntu-ignored     '      - name: one' '        continue-on-error: true' '        run: bash scripts/check-one.sh'
uncertain ubuntu-ignored-exp '      - name: one' '        continue-on-error: ${{ true }}' '        run: bash scripts/check-one.sh'
uncertain ubuntu-unknown-key '      - name: one' '        novel-key: 1' '        run: bash scripts/check-one.sh'
uncertain ubuntu-shell       '      - name: one' '        shell: true {0}' '        run: bash scripts/check-one.sh'
uncertain ubuntu-workdir     '      - name: one' '        working-directory: /tmp' '        run: bash scripts/check-one.sh'
uncertain ubuntu-continued   '      - run: bash scripts/check-one.sh' '          || true'
uncertain ubuntu-continued-2 '      - name: one' '        run: bash scripts/check-one.sh' '          || true' '        id: one'
# …and the same for the JOB: a key this does not list makes every step in it uncertain.
for _k in 'if: false' "'if': false" 'needs: lint' 'continue-on-error: true' 'strategy: {matrix: {a: [1]}}' 'defaults: {run: {shell: sh}}'; do
  d="$(fx "ubuntu-job-key")" && ci_sub "$d" "/^  one:\$/ { print; print \"    $_k\"; next } { print }"
  refuses "ubuntu-job [$_k]" "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
done
# …wherever in the job the key sits: a job-level `if` written after the steps is still the job's.
d="$(fx ubuntu-job-if-last)" && ci_sub "$d" '/run: bash scripts\/check-one\.sh/ { print; print "    if: false"; next } { print }'
refuses ubuntu-job-if-last "$d" 'one: no ubuntu job of ci.yml runs `bash scripts/check-one.sh`'
# …and a workflow-level `defaults` can change every step, so nothing counts under one.
d="$(fx ubuntu-wf-defaults)" && ci_sub "$d" '/^jobs:$/ { print "defaults:"; print "  run:"; print "    shell: sh" } { print }'
lint "$d"; eq "$RC_" 2 "a workflow with top-level defaults is refused: no step under it counts"
# THE FORMS THAT DO COUNT: the command quoted, and beside the keys a step may carry.
d="$(fx ubuntu-quoted)" && run_as "$d" "      - run: 'bash scripts/check-one.sh'"
lint "$d"; yes "$RC_" "a single-line run that is the command in quotes is run"
d="$(fx ubuntu-keys)" && run_as "$d" '      - name: one' '        id: one' '        env:' '          A: b' '        run: bash scripts/check-one.sh'
lint "$d"; yes "$RC_" "a single-line run beside name, id and env is run"
# A function step: its job must run it through the runner by name, and it declares the runner.
d="$(fx fn-job-gone)" && ci_sub "$d" '{ sub(/^  gate-detector:$/, "  renamed:") } { print }'
lint "$d"; yes "$RC_" "a function step run by name is run, whatever the job is called"
d="$(fx fn-command-gone)" && ci_sub "$d" '{ sub(/run: bash scripts\/selfcheck\.sh --only detect/, "run: echo \"bash scripts/selfcheck.sh --only detect\"") } { print }'
refuses fn-command-gone "$d" 'detect: no ubuntu job of ci.yml runs `bash scripts/selfcheck.sh --only detect`'
d="$(fx fn-runner-undeclared)" && reg_sub "$d" '$1 == "detect" { $5 = "scripts/lib/three.sh" } { print }'
refuses fn-runner-undeclared "$d" 'detect: a function step runs code in scripts/selfcheck.sh, which its declared inputs do not cover'
d="$(fx fn-unrun)" && printf 'novel\tstep_novel\tpool\tconcurrent\tscripts/lib/three.sh,scripts/selfcheck.sh\tsuite\n' >> "$d/registry.tsv"
refuses fn-unrun "$d" 'novel: no ubuntu job of ci.yml runs `bash scripts/selfcheck.sh --only novel`'

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
  'echo "$OTHER"/scripts/lib/three.sh' "sed -n 's/.*one: \\([0-9]*\\).*/\\1/p' log" >> "$d/scripts/check-one.sh"
lint "$d"
yes "$RC_" "a fixture path, a comment, a bare word, an untracked path, an absolute path and a sed program are not references"
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
d="$(fx all-conditional)" && ci_sub "$d" '/^    runs-on: ubuntu/ { print; print "    if: false"; next } { print }'
lint "$d"; eq "$RC_" 2 "a workflow whose every ubuntu job is conditional is refused"
# …and so is a tracked list this lint cannot carry: a path holding a newline.
if nl_repo="$(mktemp -d "$work/nl.XXXXXX")" && check_git "$nl_repo" init -q >/dev/null 2>&1 \
   && : > "$nl_repo/a
b" && check_git "$nl_repo" add -A >/dev/null 2>&1; then
  OUT="$(si_tracked_list "$nl_repo" "$work/nl.txt")"; RC_=$?
  eq "$RC_" 1 "a tracked path holding a newline is refused, not listed as two paths"
  has "$OUT" "holds a newline" "…naming why"
  rm -f "$nl_repo/a
b"; printf 'x\n' > "$nl_repo/plain"; check_git "$nl_repo" add -A >/dev/null 2>&1
  OUT="$(si_tracked_list "$nl_repo" "$work/nl.txt")"; RC_=$?
  yes "$RC_" "…and a tree without one is listed"
  eq "$(cat "$work/nl.txt")" "plain" "…one path per line"
else
  printf 'SKIP: the newline-in-a-name case needs a filesystem that allows one\n'
fi
OUT="$(si_tracked_list "$work/not-a-repo" "$work/nr.txt")"; RC_=$?
eq "$RC_" 1 "a tree git cannot list is refused"

check_summary "check-step-inputs --self-test"
