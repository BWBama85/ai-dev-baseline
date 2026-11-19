#!/usr/bin/env bash
# ai-dev-baseline — three shapes a check suite may not carry (#458, D160).
#
# Usage: bash scripts/check-suite-hygiene.sh           scan the tree, then prove the scan (exit 0/1)
#        bash scripts/check-suite-hygiene.sh --scan    the scan alone: 0 clean · 1 a finding ·
#                                                      2 it could not read what it scans
#
# Every tracked `scripts/check-*.sh` is scanned for:
#
#   grep-q-pipe       `producer | grep -q …` in a suite that turns `pipefail` on. `grep -q` exits at
#                     its first match; a producer still writing dies of SIGPIPE, and pipefail makes
#                     the pipeline non-zero although the match was found. An assertion written
#                     `… && ok || bad` then reports a failure that did not happen, and one written
#                     `if … ; then bad` passes over the text it exists to refuse. Write
#                     `grep -q … <<< "$text"`, or a `case`.
#   pwd-capture       `ROOT="$(pwd)"` (any name; `$(pwd -P)`, `${ pwd; }` and backquotes too; not
#                     `${| pwd; }`, which expands REPLY and captures nothing). A
#                     command substitution drops trailing newlines, so in a checkout named
#                     `clone<NL>` the variable names the sibling `clone` and the suite tests that
#                     tree. Write `ROOT="$PWD"`.
#   mktemp-unchecked  `name="$(mktemp -d …)"` (`${ …; }` and backquotes too) with no failure branch
#                     in the same statement. An empty
#                     path turns `git -C "$name"` into a write to the checkout the suite runs from,
#                     since git leaves the directory unchanged for `-C ""`. Write
#                     `name="$(mktemp -d)" || { echo "…" >&2; exit 1; }`, or make the capture the
#                     condition of an `if`.
#
# WHAT COUNTS, exactly, because a line-oriented scan is only as good as its stated edges:
#
#   * Each line is read as the shell reads it: quotes, `$( )`, `${ }`, `$(( ))` and backquotes
#     nest, a `#` starts a comment only where it starts a word outside quotes, and a here-document
#     opens only at an unquoted `<<` outside arithmetic whose whole delimiter word, quotes removed,
#     closes it on a later line (several on one line close in order). Comments and here-document
#     bodies are not scanned, and THE RULES READ THE LINE WITH ITS LITERAL TEXT BLANKED: what is
#     inside quotes or a parameter expansion, or escaped, is never a command or an operator, while
#     a substitution inside double quotes still is.
#   * THE STATE DOES NOT CARRY ACROSS LINES: every line starts as command text, so a banned shape
#     at the start of a line inside a multi-line string is a finding, and a `(` or `)` in a `case`
#     pattern inside a capture can end it early. A statement continued with a trailing `\` or a
#     trailing `|` is read as one line; one continued after a trailing `&&` or `||` is not.
#   * Blanking has a cost: a command name or option that is itself quoted (`$('pwd')`,
#     `mktemp "-d"`, `pw""d`) is blanked with the rest and not seen. A here-document delimiter
#     loses every backslash inside double quotes, and a `$'…'` escape other than a quote is not
#     decoded, so `<<"E\OF"` and `<<$'E\x4fF'` are read under the wrong word.
#   * pipefail is ON for a suite when a line starting at column 0 reads `set … -o pipefail`
#     (`set -o pipefail`, `set -uo pipefail`, `set -eu -o pipefail`). A suite that enables it any
#     other way — indented, through `shopt`, `bash -o pipefail`, an exported SHELLOPTS — is not
#     recognized, and its `| grep -q` lines are not findings.
#   * A command name may carry `command`, `env`, `exec` or `builtin`, variable assignments and a
#     path in front of it (`| LC_ALL=C grep -q`, `$(command pwd)`, `$(/usr/bin/mktemp -d)`). Any
#     other wrapper (`xargs`, `timeout`, a function) hides it.
#   * grep-q-pipe needs `grep`/`egrep`/`fgrep` directly after the pipe, and the `q` among the
#     option words that directly follow it (`-q`, `-Eq`, `-qx`, `--quiet`, `--silent`).
#     `grep -e x -q` and `| { grep -q x; }` are not seen, and `grep -e -q`, where `-q` is the
#     pattern, is read as quiet. Other early-exit readers (`head -n1`, `grep -m1`, `sed q`, an awk
#     `exit`) have the same hazard and are not scanned.
#   * pwd-capture and mktemp-unchecked need the assignment at the start of a statement: at the start
#     of the line, or after `;` `&` `|` `(` `{` `!` or `then`/`do`/`else`/`if`/`elif`/`while`/
#     `until`. A bare `$(pwd)` passed as an argument is not seen, nor is a pwd with anything after
#     it but `-L`/`-P` (`$(pwd 2>/dev/null)`), nor one behind `command --`.
#   * A `mktemp -d` capture must run mktemp and nothing else (redirections and nested
#     substitutions aside): `$(mktemp -d; true)` is a finding whatever follows it. It is then
#     CHECKED when `||` follows it directly and runs something other than a bare `true` or `:`;
#     when `&&` follows it and a `||` comes before the statement's next `;`; or when the line opens
#     with `if`/`elif`/`while`/`until` and nothing but an `&&` chain lies between the capture and
#     that line's first `; then` or `; do` (a later `;`, `||` or `&`, or a command the assignment
#     merely prefixes, would replace or mask its status). `local x="$(mktemp -d)" || …` is a
#     finding whatever follows: the declaration's status replaces mktemp's.
#   * THE CHECKED FORMS ARE THOSE SPELLINGS AND NO OTHERS, in both directions. What a handler
#     runs is not judged beyond a bare `true` or `:`, so `|| true x` and a no-op behind an `&&`
#     chain pass. And a capture with a redirection or a second assignment between it and its
#     `||`, or in an `elif` written on the same line as its `if`, is a finding although the shell
#     would check it.
#   * Only `mktemp -d` (or `--directory`) captures. A helper that RETURNS a path it allocated is not
#     followed to its callers: `d="$(new_repo)"` is not this scan's to read. The two suites that
#     have such a helper assert of their own text that every capture of it is checked.
#   * The suites are the TRACKED `scripts/check-*.sh`. Where git says the tree is not a repository
#     at all, the directory is read instead and the scan says so.
#
# A file that cannot be read, a git that fails for any reason but "not a repository", a listing it
# could not finish, and a tree with no `scripts/check-*.sh` at all are exit 2, never a clean scan.
#
# THE PROOF (the bare invocation). After scanning the tree:
#   1. every rule is driven red on a fixture suite, and each accepted spelling is required clean;
#   2. the pre-fix spelling of each shape is put back into a copy of a real suite, and the scan must
#      name that file, line and class;
#   3. the lossless capture is run for real: for every suite that sets ROOT at column 0, its own
#      `cd` and `ROOT=` lines run inside a directory named `clone<NL>` beside a sibling `clone`, and
#      must read their own tree. The banned spelling, run the same way, reads the sibling.
# Everything is under one `mktemp -d`; the tracked tree is never written.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and before the cd; the load is confirmed
# by probing for the function, not by the source's exit status.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
MODE=full
case "${1:-}" in
  "")     ;;
  --scan) MODE=scan ;;
  *)      echo "usage: check-suite-hygiene.sh [--scan]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: check-suite-hygiene.sh [--scan]" >&2; exit 2; }
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "suite-hygiene"
ROOT="$PWD"

# suite_files <root> <tracked|dir> — fill HY_FILES with the suites under <root>, as paths relative
# to it. `tracked` asks git, since CI sees nothing else; `dir` lists the directory, which is how the
# fixtures below are read. Returns 0 · 1 there are none · 2 git could not say.
#
# Under `tracked`, a <root> that git says is not a repository at all (an unpacked archive) is
# listed from the directory, and the scan says so. Every other git failure is 2: a listing cut
# short, or a git that will not run, is never scanned as if it were the tracked set. The listing's
# status travels as its last NUL-terminated record, so it is read and not lost with the pipe.
HY_FILES=()
suite_files() {
  local root="$1" mode="$2" f probe rc n
  HY_FILES=()
  if [ "$mode" = tracked ]; then
    probe="$(LC_ALL=C git -C "$root" rev-parse --is-inside-work-tree 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$probe" = true ]; then
      mapfile -d '' -t HY_FILES < <(git -C "$root" ls-files -z -- 'scripts/check-*.sh'; printf 'adb-ls-status=%s\0' "$?")
      n="${#HY_FILES[@]}"
      [ "$n" -gt 0 ] && [ "${HY_FILES[n-1]}" = "adb-ls-status=0" ] || { HY_FILES=(); return 2; }
      unset 'HY_FILES[n-1]'
      [ "${#HY_FILES[@]}" -gt 0 ]
      return
    fi
    case "$rc:$probe" in
      128:"fatal: not a git repository"*) printf 'suite-hygiene: %s is not a git repository — scanning every scripts/check-*.sh on disk\n' "$root" >&2 ;;
      *) return 2 ;;
    esac
  fi
  for f in "$root"/scripts/check-*.sh; do
    { [ -e "$f" ] || [ -L "$f" ]; } && HY_FILES+=("${f#"$root"/}")
  done
  [ "${#HY_FILES[@]}" -gt 0 ]
}

# hygiene_scan <root> [dir] — one line per finding on stdout, `<path>:<line>: <class>: <text>`,
# then a count line on stderr. Returns 0 clean · 1 a finding · 2 the suites could not be listed
# or read.
hygiene_scan() {
  local root="$1" out rc f
  suite_files "$root" "${2:-tracked}"; rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'suite-hygiene: git could not list the suites under %s — nothing was scanned\n' "$root" >&2
    return 2
  elif [ "$rc" -ne 0 ]; then
    printf 'suite-hygiene: no scripts/check-*.sh under %s — nothing was scanned, which is not a pass\n' "$root" >&2
    return 2
  fi
  for f in "${HY_FILES[@]}"; do
    if [ ! -f "$root/$f" ] || [ ! -r "$root/$f" ]; then
      printf 'suite-hygiene: %s is not a readable file — the scan would be short by one suite\n' "$f" >&2
      return 2
    fi
  done
  # LC_ALL=C: the suites hold bytes that are not valid UTF-8, and awk stops on one in a UTF-8 locale.
  out="$(cd "$root" && LC_ALL=C awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit(class, at, why) { printf "%s:%d: %s: %s%s\n", file, at, class, trim(L[at]), why; found = 1 }

    # --- the lexer: one line, read as the shell reads it -------------------------------------
    # Every function takes the whole line and an index into it, and returns the index after what
    # it consumed (length + 1 when the line ends first). `lit` records a run of LITERAL text —
    # quoted or escaped characters, which no rule may read as code.
    function lit(a, b) { if (b >= a) { RA[++nr] = a; RB[nr] = b } }

    # Just after an opening single quote.
    function skip_sq(s, i,    j, e) {
      j = index(substr(s, i), "\047"); e = j ? i + j - 1 : length(s) + 1
      lit(i, e - 1)
      return e + 1
    }
    # Just after the opening quote of $-quoted text, where a backslash escapes.
    function skip_ansi(s, i,    n, c, a) {
      n = length(s); a = i
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\047") { lit(a, i - 1); return i + 1 }
        i++
      }
      lit(a, n)
      return n + 1
    }
    # Just after an opening double quote: its text is literal, a substitution inside it is not.
    function skip_dq(s, i,    n, c, c2, a) {
      n = length(s); a = i
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        if (c == "\"") { lit(a, i - 1); return i + 1 }
        c2 = (c == "$") ? substr(s, i + 1, 1) : ""
        if (c == "`" || c2 == "(" || c2 == "{") {
          lit(a, i - 1)
          if (c == "`") i = walk(s, i + 1, "`")
          else if (c2 == "(") i = (substr(s, i + 2, 1) == "(") ? skip_arith(s, i + 3) : walk(s, i + 2, ")")
          else i = (substr(s, i + 2, 1) ~ /[[:space:]|]/) ? walk(s, i + 2, "}") : skip_param(s, i + 2)
          a = i
          continue
        }
        i++
      }
      lit(a, n)
      return n + 1
    }
    # Just after the `${` of a parameter expansion: its text is literal (a default such as
    # `${x:-a | b}` is a word, not a pipeline), a substitution inside it is not. Braces nest.
    function skip_param(s, i,    n, c, c2, depth, a) {
      n = length(s); depth = 0; a = i
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { i += 2; continue }
        c2 = (c == "$") ? substr(s, i + 1, 1) : ""
        if (c == "\047" || c == "\"" || c == "`" || c2 == "(" || c2 == "{") {
          lit(a, i - 1)
          if (c == "\047") i = skip_sq(s, i + 1)
          else if (c == "\"") i = skip_dq(s, i + 1)
          else if (c == "`") i = walk(s, i + 1, "`")
          else if (c2 == "(") i = (substr(s, i + 2, 1) == "(") ? skip_arith(s, i + 3) : walk(s, i + 2, ")")
          else i = (substr(s, i + 2, 1) ~ /[[:space:]|]/) ? walk(s, i + 2, "}") : skip_param(s, i + 2)
          a = i
          continue
        }
        if (c == "{") depth++
        else if (c == "}") { if (depth == 0) { lit(a, i - 1); return i + 1 } depth-- }
        i++
      }
      lit(a, n)
      return n + 1
    }
    # Just after the `((` of an arithmetic expansion or command: up to its `))`. A `<<` in here
    # is a shift, never a here-document.
    function skip_arith(s, i,    n, c, depth) {
      n = length(s); depth = 2
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "(") depth++
        else if (c == ")" && --depth == 0) return i + 1
        i++
      }
      return n + 1
    }
    # The word after a here-document operator, with shell quote removal applied: single quotes,
    # double quotes and $-quotes (a backslash escapes inside those two), and a backslash outside
    # them. Queues it and returns the index after it, or 0 when no word follows.
    function heredoc_word(s, j,    dash, c, q, w, any, n) {
      dash = 0; n = length(s)
      if (substr(s, j, 1) == "-") { dash = 1; j++ }
      while (substr(s, j, 1) ~ /[ \t]/) j++
      w = ""; any = 0
      while (j <= n) {
        c = substr(s, j, 1)
        if (c == "$" && substr(s, j + 1, 1) ~ /["\047]/) { j++; c = substr(s, j, 1); q = (c == "\047") ? "$" : "\"" }
        else if (c == "\047" || c == "\"") q = c
        else q = ""
        if (q != "") {
          any = 1
          for (j++; j <= n; j++) {
            c = substr(s, j, 1)
            if (q != "\047" && c == "\\") { j++; w = w substr(s, j, 1); continue }
            if (c == ((q == "\"") ? "\"" : "\047")) break
            w = w c
          }
          if (j > n) return 0
          j++
          continue
        }
        if (c == "\\") { w = w substr(s, j + 1, 1); j += 2; any = 1; continue }
        if (c ~ /[[:space:];&|<>()]/) break
        w = w c; j++; any = 1
      }
      if (!any) return 0
      HQ[++nq] = w; HDASH[nq] = dash
      return j
    }
    # Command text from i up to its unnested terminator: ")" "}" or a backquote, or "" for the
    # whole line. Sets CUT where a comment starts and queues here-document words. `wb` is whether
    # the last thing read ended a word, which is the only place a `#` starts a comment: after
    # `a\ ` the escaped space is part of the word, and `#` is too.
    function walk(s, i, term,    n, c, c2, depth, j, wb) {
      n = length(s); depth = 0; wb = 1
      while (i <= n) {
        if (CUT) return n + 1
        c = substr(s, i, 1)
        if (c == "\\") { if (i < n) lit(i, i + 1); i += 2; wb = 0; continue }
        if (c == "\047") { i = skip_sq(s, i + 1); wb = 0; continue }
        if (c == "\"") { i = skip_dq(s, i + 1); wb = 0; continue }
        if (c == "`") { if (term == "`") return i + 1; i = walk(s, i + 1, "`"); wb = 0; continue }
        if (c == "$") {
          c2 = substr(s, i + 1, 1); wb = 0
          if (c2 == "\047") { i = skip_ansi(s, i + 2); continue }
          if (c2 == "(") { i = (substr(s, i + 2, 1) == "(") ? skip_arith(s, i + 3) : walk(s, i + 2, ")"); continue }
          if (c2 == "{") { i = (substr(s, i + 2, 1) ~ /[[:space:]|]/) ? walk(s, i + 2, "}") : skip_param(s, i + 2); continue }
          i++; continue
        }
        if (c == "(" && wb && substr(s, i + 1, 1) == "(") { i = skip_arith(s, i + 2); wb = 0; continue }
        if (c == "#" && wb) { CUT = i; return n + 1 }
        if (c == "<" && substr(s, i, 2) == "<<") {
          wb = 0
          if (substr(s, i, 3) == "<<<") { i += 3; continue }
          j = heredoc_word(s, i + 2)
          i = j ? j : i + 2
          continue
        }
        if (term == ")") { if (c == "(") depth++; else if (c == ")") { if (depth == 0) return i + 1; depth-- } }
        else if (term == "}") { if (c == "{") depth++; else if (c == "}") { if (depth == 0) return i + 1; depth-- } }
        wb = (c ~ /[[:space:];&|()]/)
        i++
      }
      return n + 1
    }
    # The line with its comment cut off and every literal character replaced by `_`, so a rule
    # reads operators and commands, never the contents of a string. Same length up to the cut.
    function masked(s,    m, pos, r, w) {
      nr = 0; CUT = 0
      walk(s, 1, "")
      m = ""; pos = 1
      for (r = 1; r <= nr; r++) {
        if (RA[r] < pos) continue
        w = RB[r] - RA[r] + 1
        while (length(US) < w) US = US US
        m = m substr(s, pos, RA[r] - pos) substr(US, 1, w)
        pos = RB[r] + 1
      }
      m = m substr(s, pos)
      return CUT ? substr(m, 1, CUT - 1) : m
    }

    # --- the rules, all applied to masked text -----------------------------------------------
    # The end of a `$(` or `${ ` capture in masked text: the offset of its closing bracket in s,
    # 0 if it never closes on this line. s begins just after the opening bracket.
    function capture_end(s, open,    close_, depth, i, c) {
      if (open == "`") return index(s, "`")
      close_ = (open == "(") ? ")" : "}"; depth = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == open) depth++
        else if (c == close_) { if (depth == 0) return i; depth-- }
      }
      return 0
    }

    # A capture body with its nested substitutions removed: what the capture itself runs.
    function outer_text(s,    i, n, c, d, o, bq) {
      n = length(s); d = 0; o = ""; bq = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "`") { bq = !bq; continue }
        if (bq) continue
        if (d == 0 && c == "$" && substr(s, i + 1, 1) ~ /[({]/) { d = 1; i++; continue }
        if (d > 0) { if (c == "(" || c == "{") d++; else if (c == ")" || c == "}") d--; continue }
        o = o c
      }
      return o
    }

    function scan_mktemp(l, at,    s, base, head, open, rest, e, cap, after, decl, checked, q, t, tail, why) {
      s = l; base = 0
      while (match(s, STMT "=\"?(\\$[({]|`)")) {
        head = substr(s, RSTART, RLENGTH); open = substr(head, length(head), 1)
        rest = substr(s, RSTART + RLENGTH)
        base += RSTART + RLENGTH - 1; s = rest          # l, from base + 1 on, is rest
        if (rest !~ ((open == "{") ? "^[[:space:]]+" PRE "mktemp([[:space:]]|;)" : "^[[:space:]]*" PRE "mktemp([[:space:]]|\\)|`)")) continue
        e = capture_end(rest, open)
        if (e == 0) { emit("mktemp-unchecked", at, " (the capture does not close on this line)"); return }
        cap = substr(rest, 1, e - 1); after = substr(rest, e + 1)
        if (cap !~ /[[:space:]](-[A-Za-z]*d[A-Za-z]*|--directory)([[:space:];]|$)/) continue
        if (substr(after, 1, 1) == "\"") { after = substr(after, 2); e++ }
        # The capture must run mktemp and nothing else, or its status is not mktemp status.
        gsub(/[0-9]*[<>]&[0-9-]+/, "", cap)
        if (open == "{") sub(/;[[:space:]]*$/, "", cap)
        if (outer_text(cap) ~ /[;|&]/) { emit("mktemp-unchecked", at, " (the capture runs more than mktemp, so its status is not mktemp status)"); continue }
        decl = (head ~ /(local|readonly|export|declare|typeset)[[:space:]]/)
        checked = 0
        if (after ~ /^[[:space:]]*\|\|/) {
          if (after !~ /^[[:space:]]*\|\|[[:space:]]*(true|:)[[:space:]]*([;)]|$)/) checked = 1
        } else if (after ~ /^[[:space:]]*&&/) {
          q = index(after, "||"); t = index(after, ";")
          if (q > 0 && (t == 0 || q < t)) checked = 1
        }
        if (!checked && l ~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/) {
          # The capture decides the condition only when nothing but an `&&` chain separates it
          # from `; then`: a later `;` or `||` would replace or mask its status.
          t = match(l, /;[[:space:]]*(then|do)([[:space:]]|$)/)
          tail = (t > 0) ? ((base + e + 1 <= t) ? substr(l, base + e + 1, t - (base + e + 1)) : ";") : after
          gsub(/[0-9]*[<>]&[0-9-]+/, "", tail)
          if (tail ~ /^([[:space:]]*&&[^;|&]*)*[[:space:]]*$/) checked = 1
        }
        why = ""
        if (decl) { checked = 0; why = " (declared and assigned at once, so mktemp status is lost)" }
        if (!checked) emit("mktemp-unchecked", at, why)
      }
    }

    function scan(l, at) {
      if (l ~ /^set[[:space:]]/ && l ~ /[[:space:]]-[A-Za-z]*o[[:space:]]+pipefail([[:space:];]|$)/) pipefail = 1
      if (l ~ ("(^|[^|])\\|&?[[:space:]]*" PRE "[ef]?grep([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:];)&|]|$)"))
        gq[++ng] = sprintf("%s:%d: grep-q-pipe: %s", file, at, trim(L[at]))
      if (l ~ (STMT "=[^[:space:];|&]*(\\$\\([[:space:]]*" PRE "pwd([[:space:]]+-[LP])?[[:space:]]*\\)|\\$\\{[[:space:]]+" PRE "pwd([[:space:]]+-[LP])?[[:space:]]*;[[:space:]]*\\}|`[[:space:]]*" PRE "pwd([[:space:]]+-[LP])?[[:space:]]*`)"))
        emit("pwd-capture", at, "")
      if (l ~ /mktemp/) scan_mktemp(l, at)
    }

    # --- one file ----------------------------------------------------------------------------
    # Is line j the terminator of queued here-document k?
    function ends(j, k,    probe) {
      probe = L[j]
      if (HDASH[k]) sub(/^\t+/, "", probe)
      return probe == HQ[k]
    }
    # Keep only the queued words that close, in order, on later lines. A word that never closes
    # is text that looks like an opener, and the lines after it are code.
    function confirm(from, n,    k, j, hit) {
      j = from
      for (k = 1; k <= nq; k++) {
        hit = 0
        for (; j <= n; j++) if (ends(j, k)) { hit = 1; j++; break }
        if (!hit) { nq = k - 1; return }
      }
    }

    function end_file(    i, n, line, at, pending, pending_at) {
      if (file == "") return
      n = nl; nq = 0; hk = 1; pending = ""; pipefail = 0; ng = 0
      for (i = 1; i <= n; i++) {
        if (hk <= nq) {                                  # inside a here-document body
          if (ends(i, hk)) { hk++; if (hk > nq) { nq = 0; hk = 1 } }
          continue
        }
        line = L[i]
        if (line ~ /^[[:space:]]*#/) line = ""
        else if (line ~ /<<|grep|pwd|mktemp|pipefail|[\\|][[:space:]]*$/ || pending != "") {
          line = masked(line)
          if (nq) confirm(i + 1, n)
        } else continue                                  # nothing a rule reads, and no opener
        if (pending != "") { line = pending " " trim(line); at = pending_at } else at = i
        if (line ~ /\\$/) { sub(/\\$/, "", line); pending = line; pending_at = at; continue }
        if (line ~ /(^|[^|])\|[[:space:]]*$/) { pending = line; pending_at = at; continue }
        pending = ""
        scan(line, at)
      }
      if (pending != "") scan(pending, pending_at)
      if (pipefail) { np++; for (i = 1; i <= ng; i++) { print gq[i]; found = 1 } }
      nl = 0
    }

    BEGIN {
      US = "________________________________________________________________"
      # Where a statement may begin, then an optional declaration word, then the assigned name.
      STMT = "(^|[;&|({!]|(^|[[:space:];])(then|do|else|if|elif|while|until)[[:space:]])[[:space:]]*((local|readonly|export|declare|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*"
      # What may stand in front of a command name: `command`, `env`, `exec`, `builtin`, variable
      # assignments, and a path.
      PRE = "((command|env|exec|builtin)[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((command|env)[[:space:]]+)*([^[:space:];|&()]*/)?"
    }
    FNR == 1 { end_file(); file = FILENAME }
    { L[++nl] = $0 }
    END {
      end_file()
      # ARGC - 1, not a count of files that had a first line: an empty suite was read too.
      printf "suite-hygiene: scanned %d suite(s), %d under pipefail\n", ARGC - 1, np > "/dev/stderr"
      exit (found ? 1 : 0)
    }
  ' "${HY_FILES[@]}" </dev/null)"; rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac
}

# ---------------------------------------------------------------------------------------------
# The scan of the shipped tree. `--scan` ends here.
# ---------------------------------------------------------------------------------------------
tree_out="$(hygiene_scan "$ROOT" 2>&1)"; tree_rc=$?
if [ "$MODE" = scan ]; then
  printf '%s\n' "$tree_out" >&2
  case "$tree_rc" in
    0) echo "suite-hygiene: PASS (no banned shape in scripts/check-*.sh)"; exit 0 ;;
    1) echo "suite-hygiene: FAIL — rewrite each line above (the header of scripts/check-suite-hygiene.sh gives the form)" >&2; exit 1 ;;
    *) echo "suite-hygiene: FAIL — the scan could not read what it scans" >&2; exit 2 ;;
  esac
fi
work="$(mktemp -d)" || { echo "check-suite-hygiene: mktemp failed" >&2; exit 1; }
# The cleanup is single-quoted: expanded when the trap fires, so the path is never read as code.
# shellcheck disable=SC2016
check_exit_guard "check-suite-hygiene" 'rm -rf "$work"'
if [ "$tree_rc" -eq 0 ]; then ok; else
  bad "the shipped suites carry a banned shape, or could not be scanned (rc $tree_rc):
$tree_out"
fi

# The three shapes, composed rather than typed, so this file is not a finding of its own scan.
GQ='| grep'" -q"
P='|'
PW='$(pw'"d)"
MK='$(mktem'"p -d)"
NL='
'

# fx <name> <line>… — a fixture tree holding ONE suite made of those lines. Prints the tree.
fx() {
  local d="$work/fx-$1"; shift
  rm -rf "$d"; mkdir -p "$d/scripts" || return 1
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$d/scripts/check-fx.sh"
  printf '%s' "$d"
}
# flagged <label> <class> <line-number> <line>… — the fixture is a finding of that class, there.
flagged() {
  local label="$1" class="$2" at="$3" d out rc; shift 3
  d="$(fx hit "$@")" || { bad "$label: could not build the fixture"; return; }
  out="$(hygiene_scan "$d" dir 2>/dev/null)"; rc=$?
  eq "$rc" 1 "$label: the scan is red"
  has "$out" "scripts/check-fx.sh:$at: $class: " "$label: it names the line and the class"
}
# clean <label> <line>… — the fixture carries no finding.
clean() {
  local label="$1" d out rc; shift
  d="$(fx ok "$@")" || { bad "$label: could not build the fixture"; return; }
  out="$(hygiene_scan "$d" dir 2>/dev/null)"; rc=$?
  eq "$rc" 0 "$label: the scan is clean (it printed: $out)"
}

# ---------------------------------------------------------------------------------------------
# 1. Each rule, red on what it bans and clean on what it accepts.
# ---------------------------------------------------------------------------------------------
PF='set -uo pipefail'

# --- grep-q-pipe ---
flagged "gq plain"        grep-q-pipe 3 "$PF" "printf '%s\\n' \"\$x\" $GQ needle && ok"
flagged "gq -Eq"          grep-q-pipe 3 "$PF" "printf x $P grep -Eq 'a|b' && ok"
flagged "gq -qx"          grep-q-pipe 3 "$PF" "printf x $P grep -qx -- '-m' && ok"
flagged "gq -Fqx"         grep-q-pipe 3 "$PF" "printf x $P grep -Fqx y"
flagged "gq -q -x -F"     grep-q-pipe 3 "$PF" "printf x $P grep -q -x -F -- y"
flagged "gq --quiet"      grep-q-pipe 3 "$PF" "printf x $P grep --quiet y"
flagged "gq egrep"        grep-q-pipe 3 "$PF" "printf x $P egrep -q y"
flagged "gq |&"           grep-q-pipe 3 "$PF" "cmd $P& grep -q y"
flagged "gq three stages" grep-q-pipe 3 "$PF" "if grep -n a f | grep -v b $P grep -q .; then bad x; fi"
flagged "gq in a funsub"  grep-q-pipe 3 "$PF" "eq \"\${ printf x $GQ y && echo a || echo b; }\" a l"
flagged "gq continued"    grep-q-pipe 3 "$PF" "awk '{print}' f \\" "  $GQ ok && ok"
flagged "gq pipe at EOL"  grep-q-pipe 3 "$PF" "printf x $P" "  grep -q y"
flagged "gq set -o"       grep-q-pipe 3 'set -o pipefail' "printf x $GQ y"
flagged "gq set -euo"     grep-q-pipe 3 'set -euo pipefail' "printf x $GQ y"
flagged "gq set -eu -o"   grep-q-pipe 3 'set -eu -o pipefail' "printf x $GQ y"
flagged "gq set after"    grep-q-pipe 2 "printf x $GQ y" 'set -uo pipefail'
clean "gq without pipefail"     'set -u' "printf x $GQ y && ok"
clean "gq pipefail in a subshell" 'set -u' "( set -o pipefail; printf x $GQ y )"
clean "gq pipefail indented"    'set -u' 'if true; then' '  set -o pipefail' 'fi' "printf x $GQ y"
clean "gq pipefail off"         'set +o pipefail' "printf x $GQ y"
clean "gq here-string"          "$PF" 'grep -q needle <<< "$x" && ok'
clean "gq || grep"              "$PF" 'if grep -q a f || grep -q b f; then ok; fi'
clean "gq grep -c"              "$PF" 'printf x | grep -c y'
clean "gq grep without q"       "$PF" 'printf x | grep -E y >/dev/null'
clean "gq comment"              "$PF" "# never: printf x $GQ y"
clean "gq trailing comment"     "$PF" "ok  # was: printf x $GQ y"
clean "gq heredoc body"         "$PF" "cat > f <<'EOF'" "printf x $GQ y" 'EOF' 'ok'
clean "gq tab-indented heredoc" "$PF" 'cat > f <<-EOF' "	printf x $GQ y" '	EOF' 'ok'

# --- pwd-capture ---
flagged "pwd ROOT"        pwd-capture 2 "ROOT=\"$PW\""
flagged "pwd unquoted"    pwd-capture 2 "ROOT=$PW"
flagged "pwd other name"  pwd-capture 2 "TOP=\"$PW\""
flagged "pwd -P"          pwd-capture 2 'ROOT="$(pw''d -P)"'
flagged "pwd backquotes"  pwd-capture 2 'TOP=`pw''d`'
flagged "pwd funsub"      pwd-capture 2 'ROOT="${ pw''d; }"'
flagged "pwd readonly"    pwd-capture 2 "readonly TOP=\"$PW\""
flagged "pwd after &&"    pwd-capture 2 "cd x && ROOT=\"$PW\""
flagged "pwd with a tail" pwd-capture 2 "LIB=\"$PW/scripts/lib\""
flagged "pwd indented"    pwd-capture 3 'f() {' "  local r; r=\"$PW\"" '}'
clean "pwd \$PWD"          'ROOT="$PWD"'
clean "pwd sentinel"       "ROOT=\"\$(pwd && printf 'X')\"; ROOT=\"\${ROOT%X}\""
clean "pwd quoted fixture" "printf '%s\\n' 'ROOT=\"$PW\"' > f"
clean "pwd comment"        "# was: cd x && ROOT=\"$PW\""
clean "pwd trailing comment" "ok  # was: cd x && ROOT=\"$PW\""
clean "pwd heredoc body"   "cat > f <<EOF" "ROOT=\"$PW\"" 'EOF'
clean "pwd as an argument" "probe \"$PW\""
clean "pwd escaped in a sed script" "sed \"s|^root=x\$|root=\\\"\\$PW\\\"|\" f > g"

# --- mktemp-unchecked ---
flagged "mk bare"            mktemp-unchecked 2 "work=\"$MK\""
flagged "mk with a trap"     mktemp-unchecked 2 "work=\"$MK\"; trap 'rm -rf \"\$work\"' EXIT"
flagged "mk templated"       mktemp-unchecked 2 'd="$(mktem''p -d "$work/r.XXXXXX")"'
flagged "mk other name"      mktemp-unchecked 2 'bare="$(mktem''p -d "$work/o.XXXXXX")"'
flagged "mk second on line"  mktemp-unchecked 2 "a=\"$MK\" || exit 1; b=\"$MK\""
flagged "mk indented"        mktemp-unchecked 3 'f() {' "  d=\"$MK\"" '}'
flagged "mk funsub"          mktemp-unchecked 2 'd="${ mktem''p -d; }"'
flagged "mk --directory"     mktemp-unchecked 2 'd="$(mktem''p --directory)"'
flagged "mk -dt"             mktemp-unchecked 2 'd="$(mktem''p -dt x.XXXXXX)"'
flagged "mk && alone"        mktemp-unchecked 2 "d=\"$MK\" && cd \"\$d\""
flagged "mk || in next stmt" mktemp-unchecked 2 "d=\"$MK\" && cd \"\$d\"; true || exit 1"
flagged "mk local masks"     mktemp-unchecked 3 'f() {' "  local d=\"$MK\" || return 1" '}'
flagged "mk if body"         mktemp-unchecked 2 "if true; then d=\"$MK\"; fi"
flagged "mk two-statement if" mktemp-unchecked 2 "d=\"$MK\"" 'if [ -d "$d" ]; then ok; fi'
clean "mk || block"      "work=\"$MK\" || { echo x >&2; exit 1; }"
clean "mk || exit"       "work=\"$MK\" || exit 1"
clean "mk || return"     'f() {' "  d=\"$MK\" || return 1" '}'
clean "mk && … ||"       "work=\"$MK\" && [ -n \"\$work\" ] && [ -d \"\$work\" ] || { echo x >&2; exit 1; }"
clean "mk nested capture" 'pd="$(mktem''p -d "$(cat "$c/base")/pool.XXXXXX")" && reg "$pd" || exit 97'
clean "mk if condition"  "if d=\"$MK\" && [ -d \"\$d\" ]; then ok; else bad x; fi"
clean "mk if ! … ||"     'if ! mkdir -p "$a" || ! art="$(mktem''p -d "$a/x.XXXXXX" 2>/dev/null)"; then bad x; fi'
clean "mk funsub checked" 'd="${ mktem''p -d; }" || return 1'
clean "mk a file"        'f="$(mktemp)"'
clean "mk quoted fixture" "printf '%s\\n' 'd=\"$MK\"' > f"
clean "mk comment"       "# was: cd x && work=\"$MK\""
clean "mk trailing comment" "ok  # was: cd x && work=\"$MK\""
clean "mk heredoc body"  "cat > f <<'SH'" "work=\"$MK\"" 'SH'

# --- the lexer's edges ---
flagged "# inside double quotes"  pwd-capture 2 "printf '%s\\n' \"value # text\"; ROOT=\"$PW\""
flagged "# inside single quotes"  pwd-capture 2 "printf '%s\\n' 'value # text'; ROOT=\"$PW\""
flagged "# inside quotes, piped"  grep-q-pipe 3 "$PF" "printf '%s' \"a #b\" $GQ a"
flagged "\$# is not a comment"    pwd-capture 2 "[ \$# -gt 0 ] && ROOT=\"$PW\""
flagged "# inside a word"         pwd-capture 2 "x=a#b; ROOT=\"$PW\""
flagged "\${x#y} is not a comment" pwd-capture 2 "x=\"\${y#z}\"; ROOT=\"$PW\""
flagged "delimiter read in full"  pwd-capture 5 "cat <<'EOF-X'" 'fixture' 'EOF-X' "ROOT=\"$PW\"" "cat <<'EOF'" 'fixture' 'EOF'
flagged "bare delimiter in full"  pwd-capture 5 'cat <<EOF-X' 'fixture' 'EOF-X' "ROOT=\"$PW\"" 'cat <<EOF' 'fixture' 'EOF'
flagged "opener in a nested string" pwd-capture 3 "order \"x\" \"\$(line_of \"\$f\" \"--finding - <<'FINDING' x\")\" y" "ROOT=\"$PW\"" 'FINDING'
clean "two heredocs on one line"  "cat <<'A' <<'B'" 'one' 'A' "ROOT=\"$PW\"" 'B'
clean "escaped delimiter"         'cat <<\EOF' "ROOT=\"$PW\"" 'EOF'
clean "mk quoted parenthesis"     'work="$(mktem''p -d "$base/(x.XXXXXX")" || exit 1'
flagged "mk if masked by ;"       mktemp-unchecked 2 "if work=\"$MK\"; true; then echo \"\$work\"; fi"
flagged "mk if masked by ||"      mktemp-unchecked 2 "if work=\"$MK\" || true; then echo \"\$work\"; fi"
flagged "mk || true"              mktemp-unchecked 2 "work=\"$MK\" || true"
flagged "mk || :"                 mktemp-unchecked 2 "work=\"$MK\" || :"
clean "mk if, then on next line"  "if work=\"$MK\" &&" '   [ -d "$work" ]' 'then ok; fi'

# --- rules read masked text: a string is never code, and an operator is never a string ---
clean   "quoted ; ROOT"           "printf '%s\\n' 'example; ROOT=\"$PW\"'"
clean   "quoted ; mktemp"         "printf '%s\\n' 'example; d=\"$MK\"'"
clean   "quoted pipe into grep"   "$PF" "printf '%s\\n' 'producer $GQ needle'"
flagged "quoted || is no handler" mktemp-unchecked 2 "d=\"$MK\" && echo \"a||b\""
clean   "quoted ; is no boundary" "d=\"$MK\" && echo \"a; b\" || exit 1"
flagged "# after an escaped space" pwd-capture 2 "echo a\\ # x; ROOT=\"$PW\""
flagged "mk body masks status"    mktemp-unchecked 2 'd="$(mktem''p -d; true)" || exit 1'
flagged "mk body ors status away" mktemp-unchecked 2 'd="$(mktem''p -d || true)" || exit 1'
clean   "mk body with a redirect" 'd="$(mktem''p -d 2>/dev/null)" || exit 1'
clean   "mk body with 2>&1"       'd="$(mktem''p -d "$x/a.XXXXXX" 2>&1)" || exit 1'
flagged "mk if, prefix of a command" mktemp-unchecked 2 "if d=\"$MK\" true; then echo ok; fi"
flagged "mk if, backgrounded"     mktemp-unchecked 2 "if d=\"$MK\" & wait; then echo ok; fi"
clean   "mk if, chain with 2>&1"  "if d=\"$MK\" && probe \"\$d\" >/dev/null 2>&1; then ok; fi"
clean   "mk body, nested operators" 'd="$(mktem''p -d $(true; true))" || exit 1'
flagged "mk backquoted"           mktemp-unchecked 2 'd=`mktem''p -d`'
clean   "mk backquoted, checked"  'd=`mktem''p -d` || exit 1'
clean   "mk REPLY form captures nothing" 'd="${| mktem''p -d; }"'
clean   "pwd REPLY form captures nothing" 'ROOT="${| pw''d; }"'
flagged "arithmetic shift, expansion" pwd-capture 3 'n=$((1 << 2))' "ROOT=\"$PW\"" '2'
flagged "arithmetic shift, command" pwd-capture 3 '(( n = 1 << k ))' "ROOT=\"$PW\"" 'k'
clean   "parameter default is text" "$PF" "echo \"\${x:-producer $GQ x}\""
flagged "substitution in a default is code" grep-q-pipe 3 "$PF" "echo \"\${x:-\$(printf y $GQ y)}\""
clean   "dollar-quoted delimiter"  "cat <<\$'EOF'" "ROOT=\"$PW\"" 'EOF'
clean   "delimiter with an escaped quote" 'cat <<"E\"OF"' "ROOT=\"$PW\"" 'E"OF'
# --- what may stand in front of the command name ---
flagged "gq env assignment"       grep-q-pipe 3 "$PF" "printf x $P LC_ALL=C grep -q x"
flagged "gq env + assignment"     grep-q-pipe 3 "$PF" "printf x $P env LC_ALL=C grep -q x"
flagged "gq command"              grep-q-pipe 3 "$PF" "printf x $P command grep -q x"
flagged "gq by path"              grep-q-pipe 3 "$PF" "printf x $P /usr/bin/grep -q x"
flagged "mk command"              mktemp-unchecked 2 'd="$(command mktem''p -d)"'
flagged "mk env assignment"       mktemp-unchecked 2 'd="$(TMPDIR=/x mktem''p -d)"'
flagged "pwd command"             pwd-capture 2 'ROOT="$(command pw''d)"'
flagged "pwd by path"             pwd-capture 2 'ROOT="$(/bin/pw''d)"'

# --- what the scan cannot read is 2, never clean ---
empty="$work/empty"; mkdir -p "$empty/scripts"
hygiene_scan "$empty" dir >/dev/null 2>&1; eq "$?" 2 "a tree with no suite is 2, not a clean scan"
# An opener that never closes hides nothing: the lines after it are code.
flagged "heredoc never closes" pwd-capture 3 "cat > f <<EOF" "ROOT=\"$PW\""
flagged "opener inside a string" pwd-capture 3 "has \"\$x\" \"done <<EOF\" label" "ROOT=\"$PW\"" 'EOF'
clean "opener after a string with a #" "$PF" "cat \"a #b\" <<EOF" "printf x $GQ y" 'EOF'
if [ "$(id -u)" -eq 0 ]; then
  check_note "SKIP: the unreadable-suite case cannot fire as root"
else
  d="$(fx locked 'ok')" || bad "could not build the unreadable fixture"
  chmod 000 "$d/scripts/check-fx.sh"
  hygiene_scan "$d" dir >/dev/null 2>&1; eq "$?" 2 "an unreadable suite is 2"
  chmod 644 "$d/scripts/check-fx.sh"
fi
# A listing git cut short is 2: one suite named, then a failing status.
d="$(fx short 'ok')" || bad "could not build the short-listing fixture"
mkdir -p "$work/gitstub"
cat > "$work/gitstub/git" <<'SH'
#!/bin/sh
case "$*" in
  *rev-parse*--is-inside-work-tree*) echo true; exit 0 ;;
  *rev-parse*--show-prefix*) echo; exit 0 ;;
  *ls-files*) printf 'scripts/check-fx.sh\0'; exit 1 ;;
esac
exit 1
SH
chmod +x "$work/gitstub/git"
( PATH="$work/gitstub:$PATH"; hygiene_scan "$d" >/dev/null 2>&1 ); eq "$?" 2 "a listing git could not finish is 2, not a scan of the part that arrived"
# The scan reads bytes: a suite holding one that is not valid UTF-8 is read under a UTF-8 locale.
hy_utf=""
for _l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  case "$NL$(locale -a 2>/dev/null)$NL" in *"$NL$_l$NL"*) hy_utf="$_l"; break ;; esac
done
if [ -n "$hy_utf" ]; then
  hy_bytes="$(fx bytes "$PF" "printf '\\377' $P wc -c" "ROOT=\"$PW\"")" || bad "could not build the invalid-byte fixture"
  printf 'x="\377"; printf y %s y\n' "$GQ" >> "$hy_bytes/scripts/check-fx.sh"
  out="$(LC_ALL="$hy_utf" hygiene_scan "$hy_bytes" dir 2>/dev/null)"; eq "$?" 1 "a suite with an invalid UTF-8 byte is scanned under $hy_utf"
  has "$out" "scripts/check-fx.sh:4: pwd-capture: " "…its findings before the byte are reported"
  has "$out" "scripts/check-fx.sh:5: grep-q-pipe: " "…and so is the one on the line that holds it"
else
  check_note "SKIP: no UTF-8 locale on this host to scan an invalid byte under"
fi
# A git that fails for any reason but "not a repository" is 2: the directory is not read instead.
cat > "$work/gitstub/git" <<'SH'
#!/bin/sh
echo "fatal: unable to read the index" >&2
exit 1
SH
( PATH="$work/gitstub:$PATH"; hygiene_scan "$d" >/dev/null 2>&1 ); eq "$?" 2 "a git that cannot answer is 2, not a scan of whatever is on disk"
# …while a tree that is no repository at all is read from disk, and says so.
out="$(hygiene_scan "$d" 2>&1)"; eq "$?" 0 "a tree outside any repository is scanned from the directory"
has "$out" "is not a git repository — scanning every scripts/check-*.sh on disk" "…and the scan says that is what it read"
# A tracked suite whose name git would quote is listed as itself.
d="$(fx named 'ok')" || bad "could not build the quoted-name fixture"
cp "$d/scripts/check-fx.sh" "$d/scripts/check-é.sh"
if check_git "$d" init -q >/dev/null 2>&1 && check_git "$d" add -A >/dev/null 2>&1; then
  out="$(hygiene_scan "$d" 2>&1)"; eq "$?" 0 "a tracked suite with a non-ASCII name is read, not refused"
  has "$out" "scanned 2 suite(s)" "…and both suites are counted"
  # Only the tracked set: an untracked suite with a banned shape is not this scan's subject.
  printf '%s\n' '#!/usr/bin/env bash' "ROOT=\"$PW\"" > "$d/scripts/check-untracked.sh"
  hygiene_scan "$d" >/dev/null 2>&1; eq "$?" 0 "an untracked suite is not scanned in a repository"
else
  bad "could not make the quoted-name fixture a repository"
fi
# A suite that is a dangling link is listed, and then refused as unreadable.
d="$(fx dangling 'ok')" || bad "could not build the dangling-link fixture"
ln -s "$work/no-such-suite" "$d/scripts/check-broken.sh"
hygiene_scan "$d" dir >/dev/null 2>&1; eq "$?" 2 "a suite that is a dangling link is 2, not left out of the scan"
# An empty suite is read, and counted.
d="$(fx blank 'ok')" || bad "could not build the empty-suite fixture"
: > "$d/scripts/check-fx.sh"
out="$(hygiene_scan "$d" dir 2>&1)"; eq "$?" 0 "an empty suite carries no finding"
has "$out" "scanned 1 suite(s)" "…and is counted as scanned"
# Two suites, one finding: the clean one does not hide it and the count names both.
d="$(fx two "work=\"$MK\"")" || bad "could not build the two-suite fixture"
printf '%s\n' '#!/usr/bin/env bash' "$PF" 'grep -q x <<< "$y"' > "$d/scripts/check-other.sh"
out="$(hygiene_scan "$d" dir 2>&1)"; eq "$?" 1 "one finding among two suites is red"
has "$out" "scanned 2 suite(s), 1 under pipefail" "…and the count line names what was read"
# The other suite's pipefail does not make a `set -u` suite's pipe a finding.
d="$(fx mixed 'set -u' "printf x $GQ y")" || bad "could not build the mixed fixture"
printf '%s\n' '#!/usr/bin/env bash' "$PF" 'ok' > "$d/scripts/check-other.sh"
hygiene_scan "$d" dir >/dev/null 2>&1; eq "$?" 0 "pipefail is decided per suite, not per scan"

# ---------------------------------------------------------------------------------------------
# 2. The pre-fix spelling, put back into a copy of a real suite, is caught.
# ---------------------------------------------------------------------------------------------
# revert <label> <suite> <fixed-line> <pre-fix-line> <class> — a copy of the real suite with
# <fixed-line> rewritten to <pre-fix-line> by check-lib's `check_mutate_literal`. That rewrites
# the first occurrence of a literal, so the line must occur exactly once, as a substring too.
revert() {
  local label="$1" suite="$2" fixed="$3" prefix="$4" class="$5" d="$work/revert" n at out rc
  rm -rf "$d"
  mkdir -p "$d/scripts" && cp "$ROOT/scripts/$suite" "$d/scripts/$suite" || { bad "$label: could not build the copy"; return; }
  n="$(grep -Fc -- "$fixed" "$d/scripts/$suite")"
  if [ "$n" -ne 1 ] || [ "$(grep -Fxc -- "$fixed" "$d/scripts/$suite")" -ne 1 ]; then
    bad "$label: expected exactly 1 line [$fixed] in $suite, found $n holding it — the control no longer describes the suite"
    return
  fi
  at="$(grep -Fxn -- "$fixed" "$d/scripts/$suite")"; at="${at%%:*}"
  check_mutate_literal "$d/scripts/$suite" "$fixed" "$prefix"; rc=$?
  [ "$rc" -eq 0 ] || { bad "$label: the pre-fix spelling could not be put back (rc $rc)"; return; }
  out="$(hygiene_scan "$d" dir 2>/dev/null)"; rc=$?
  eq "$rc" 1 "$label: the scan is red on the pre-fix spelling"
  has "$out" "scripts/$suite:$at: $class: " "$label: it names $suite:$at and the class"
}
revert "revert ROOT" check-implement-lib.sh 'ROOT="$PWD"' "ROOT=\"$PW\"" pwd-capture
revert "revert work" check-implement-lib.sh \
  'work="$(mktemp -d)" || { echo "check-implement-lib: mktemp failed" >&2; exit 1; }' \
  "work=\"$MK\"" mktemp-unchecked
revert "revert nested" check-implement-lib.sh \
  '  d="$(mktemp -d "$work/r.XXXXXX")" && [ -n "$d" ] && [ -d "$d" ] || {' \
  '  d="$(mktem''p -d "$work/r.XXXXXX")"' mktemp-unchecked
revert "revert grep" check-mutation-gate.sh \
  "grep -qE '^      actions: read\$' <<< \"\$cl_job\" && ok \\" \
  "printf '%s\\n' \"\$cl_job\" $GQ""E '^      actions: read\$' && ok \\" grep-q-pipe
revert "revert env-prefixed grep" check-adopt.sh \
  "if LC_ALL=C grep -q \"\$(printf '\\033')\" <<< \"\$esc_prop\"; then" \
  "if bash \"\$AD\" roles-infer \"\$ESCD\" | bash \"\$AD\" propose $P LC_ALL=C grep -q \"\$(printf '\\033')\"; then" grep-q-pipe
revert "revert fail-open grep" check-release-skill.sh \
  "if grep -qE '^\\s*echo ' <<< \"\$slug_fn\"; then" \
  "if printf '%s' \"\$slug_fn\" $GQ""E '^\\s*echo '; then" grep-q-pipe

# ---------------------------------------------------------------------------------------------
# 3. The capture, run for real in `clone<NL>` beside `clone` (#404).
# ---------------------------------------------------------------------------------------------
# Each tree holds a marker naming itself. A probe is a suite's own `cd` line and its own `ROOT=`
# line, then a read of "$ROOT/marker": run from the newline tree, it must read `newline-tree`.
pair="$work/pair"
mkdir -p "$pair/clone/scripts" "$pair/clone$NL/scripts" || bad "could not build the clone pair"
printf 'sibling-tree' > "$pair/clone/marker"
printf 'newline-tree' > "$pair/clone$NL/marker"
# probe <cd-line> <root-line> — the marker the capture reaches from the newline tree.
probe() {
  printf '%s\n' '#!/usr/bin/env bash' "$1" "$2" 'cat "$ROOT/marker"' > "$pair/clone$NL/scripts/check-probe.sh"
  "$BASH" "$pair/clone$NL/scripts/check-probe.sh" 2>/dev/null
}
CD_LINE='cd "$(dirname "$0")/.." || exit 1'
eq "$(probe "$CD_LINE" "ROOT=\"$PW\"")" "sibling-tree" "the banned capture, run in clone<NL>, reads the SIBLING tree (the defect, observed)"
eq "$(probe "$CD_LINE" 'ROOT="$PWD"')" "newline-tree" "…and \$PWD reads its own"

probed=0
suite_files "$ROOT" tracked || bad "the suites could not be listed for the clone<NL> probes"
for rel in "${HY_FILES[@]}"; do
  cd_line="$(grep -m1 -E '^cd "\$\(dirname "\$0"\)' "$ROOT/$rel")"
  root_line="$(grep -m1 -E '^ROOT=' "$ROOT/$rel")"
  [ -n "$root_line" ] || continue
  if [ -z "$cd_line" ]; then
    bad "$rel sets ROOT at column 0 without a column-0 'cd \"\$(dirname \"\$0\")…' line — its capture cannot be probed"
    continue
  fi
  case "$root_line" in *'$ADB_T_FIX'*) continue ;; esac   # a fixture root handed in by a harness
  probed=$((probed + 1))
  eq "$(probe "$cd_line" "$root_line")" "newline-tree" "$rel: its ROOT capture, run in clone<NL>, reads its own tree"
done
[ "$probed" -ge 30 ] && ok || bad "only $probed suite(s) had a ROOT capture to probe — the enumeration is short"

check_summary "check-suite-hygiene"
