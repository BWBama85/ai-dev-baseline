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
#   pwd-capture       `ROOT="$(pwd)"` (any name; `$(pwd -P)`, `${ pwd; }` and backquotes too). A
#                     command substitution drops trailing newlines, so in a checkout named
#                     `clone<NL>` the variable names the sibling `clone` and the suite tests that
#                     tree. Write `ROOT="$PWD"`.
#   mktemp-unchecked  `name="$(mktemp -d …)"` with no failure branch in the same statement. An empty
#                     path turns `git -C "$name"` into a write to the checkout the suite runs from,
#                     since git leaves the directory unchanged for `-C ""`. Write
#                     `name="$(mktemp -d)" || { echo "…" >&2; exit 1; }`, or make the capture the
#                     condition of an `if`.
#
# WHAT COUNTS, exactly, because a line-oriented scan is only as good as its stated edges:
#
#   * Comment lines, trailing comments (` #…`) and here-document bodies are not code and are not
#     scanned. Quoting is modelled only to find where a here-document opens, and only within one
#     line: a banned shape spelled at the start of a line of a multi-line string is a finding. A
#     statement continued with a trailing `\` or a trailing `|` is read as one line.
#   * pipefail is ON for a suite when a line starting at column 0 reads `set … -o pipefail`
#     (`set -o pipefail`, `set -uo pipefail`, `set -eu -o pipefail`). A suite that enables it any
#     other way — indented, through `shopt`, `bash -o pipefail`, an exported SHELLOPTS — is not
#     recognized, and its `| grep -q` lines are not findings.
#   * grep-q-pipe needs the `q` among the option words that directly follow `grep`/`egrep`/`fgrep`
#     (`-q`, `-Eq`, `-qx`, `--quiet`, `--silent`). `grep -e x -q` is not seen. Other early-exit
#     readers (`head -n1`, `grep -m1`, `sed q`, an awk `exit`) have the same hazard and are not
#     scanned.
#   * pwd-capture and mktemp-unchecked need the assignment at the start of a statement: at the start
#     of the line, or after `;` `&` `|` `(` `{` `!` or `then`/`do`/`else`/`if`/`elif`/`while`/
#     `until`. A bare `$(pwd)` passed as an argument is not seen.
#   * A capture is CHECKED when `||` follows it directly; when `&&` follows it and a `||` comes
#     before the statement's next `;`; or when the line opens with `if`/`elif`/`while`/`until` and
#     the capture sits before that line's `; then` or `; do`. `local x="$(mktemp -d)" || …` is a
#     finding whatever follows: the declaration's status replaces mktemp's.
#   * Only `mktemp -d` (or `--directory`) captures. A helper that RETURNS a path it allocated is not
#     followed to its callers: `d="$(new_repo)"` is read by review, not by this scan.
#
#   * A `<<WORD` opens a here-document only when WORD closes it on a later line; otherwise it is
#     text, and the lines after it are scanned as code.
#
# A file that cannot be read and a tree with no `scripts/check-*.sh` at all are exit 2, never a
# clean scan.
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

# suite_files <root> — the suites under <root>, NUL-delimited, as paths relative to it. Tracked
# files where <root> is a worktree (CI sees nothing else); the directory listing where it is not,
# which is how the fixtures below are read. Returns 1 when there are none.
suite_files() {
  local root="$1" f
  local -a files=()
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -z "$(git -C "$root" rev-parse --show-prefix 2>/dev/null)" ]; then
    mapfile -d '' -t files < <(git -C "$root" ls-files -z -- 'scripts/check-*.sh' 2>/dev/null)
  else
    for f in "$root"/scripts/check-*.sh; do
      [ -e "$f" ] && files+=("${f#"$root"/}")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || return 1
  printf '%s\0' "${files[@]}"
}

# hygiene_scan <root> — one line per finding on stdout, `<path>:<line>: <class>: <text>`, then a
# count line on stderr. Returns 0 clean · 1 a finding · 2 nothing to scan, or a file the scan
# could not read to its end.
hygiene_scan() {
  local root="$1" out rc f
  local -a files=()
  mapfile -d '' -t files < <(suite_files "$root")
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'suite-hygiene: no scripts/check-*.sh under %s — nothing was scanned, which is not a pass\n' "$root" >&2
    return 2
  fi
  for f in "${files[@]}"; do
    if [ ! -f "$root/$f" ] || [ ! -r "$root/$f" ]; then
      printf 'suite-hygiene: %s is not a readable file — the scan would be short by one suite\n' "$f" >&2
      return 2
    fi
  done
  out="$(cd "$root" && awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit(class, at, text) { printf "%s:%d: %s: %s\n", file, at, class, trim(text); found = 1 }

    # The end of a `$(` or `${ ` capture: the offset in s of its closing bracket, 0 if it never
    # closes on this line. s begins just after the opening bracket.
    function capture_end(s, open,    close_, depth, i, c) {
      close_ = (open == "(") ? ")" : "}"; depth = 1
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == open) depth++
        else if (c == close_ && --depth == 0) return i
      }
      return 0
    }

    # A here-document opens on this line when an UNQUOTED `<<` (not `<<<`) is followed by a word.
    # Its body starts on the next line. Quotes are tracked within the line only.
    function heredoc_open(l,    i, n, c, q, j, w) {
      n = length(l); q = ""
      for (i = 1; i <= n; i++) {
        c = substr(l, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[[:space:]]/)) return
        if (c != "<" || substr(l, i, 2) != "<<") continue
        if (substr(l, i, 3) == "<<<") { i += 2; continue }
        j = i + 2; hd_dash = 0
        if (substr(l, j, 1) == "-") { hd_dash = 1; j++ }
        while (substr(l, j, 1) ~ /[[:space:]]/) j++
        if (substr(l, j, 1) ~ /["\047\\]/) j++
        w = substr(l, j)
        if (match(w, /^[A-Za-z_][A-Za-z0-9_]*/)) { hd = substr(w, 1, RLENGTH); return }
        i++
      }
    }

    function scan_mktemp(l, at,    s, off, head, open, rest, end, cap, after, decl, checked, p, q, t, why) {
      s = l; off = 0
      while (match(s, STMT "=\"?\\$[({]")) {
        head = substr(s, RSTART, RLENGTH); open = substr(head, length(head), 1)
        rest = substr(s, RSTART + RLENGTH)
        p = off + RSTART                       # where this assignment starts in the whole line
        off += RSTART + RLENGTH - 1; s = rest
        if (rest !~ ((open == "(") ? "^[[:space:]]*mktemp([[:space:]]|\\))" : "^[[:space:]|]+mktemp([[:space:]]|;)")) continue
        end = capture_end(rest, open)
        if (end == 0) { emit("mktemp-unchecked", at, l " (the capture does not close on this line)"); return }
        cap = substr(rest, 1, end - 1); after = substr(rest, end + 1)
        if (cap !~ /[[:space:]](-[A-Za-z]*d[A-Za-z]*|--directory)([[:space:];]|$)/) continue
        sub(/^"/, "", after)
        decl = (head ~ /(local|readonly|export|declare|typeset)[[:space:]]/)
        checked = 0
        if (after ~ /^[[:space:]]*\|\|/) checked = 1
        else if (after ~ /^[[:space:]]*&&/) {
          q = index(after, "||"); t = index(after, ";")
          if (q > 0 && (t == 0 || q < t)) checked = 1
        }
        if (!checked && l ~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/) {
          t = match(l, /;[[:space:]]*(then|do)([[:space:]]|$)/)
          if (t == 0 || p < t) checked = 1
        }
        why = ""
        if (decl) { checked = 0; why = " (declared and assigned at once, so mktemp status is lost)" }
        if (!checked) emit("mktemp-unchecked", at, l why)
      }
    }

    function scan(l, at) {
      if (l ~ /^set[[:space:]]/ && l ~ /[[:space:]]-[A-Za-z]*o[[:space:]]+pipefail([[:space:];]|$)/) pipefail = 1
      if (l ~ /(^|[^|])\|&?[[:space:]]*(command[[:space:]]+)?[ef]?grep([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:];)&|]|$)/)
        gq[++ng] = sprintf("%s:%d: grep-q-pipe: %s", file, at, trim(l))
      if (l ~ (STMT "=[^[:space:];|&\\\\]*(\\$\\([[:space:]]*pwd([[:space:]]+-[LP])?[[:space:]]*\\)|\\$\\{[[:space:]|]+pwd([[:space:]]+-[LP])?[[:space:]]*;[[:space:]]*\\}|`pwd([[:space:]]+-[LP])?`)"))
        emit("pwd-capture", at, l)
      if (l ~ /mktemp/) scan_mktemp(l, at)
    }

    # A candidate opener is a here-document only if its word closes it on a later line. One that
    # never closes is text that looks like an opener (a quoted `<<EOF` in an assertion), and the
    # lines after it are code.
    function closes(from, n,    j, probe) {
      for (j = from; j <= n; j++) {
        probe = L[j]
        if (hd_dash) sub(/^\t+/, "", probe)
        if (probe == hd) return 1
      }
      return 0
    }

    function end_file(    i, n, line, at, pending, pending_at, probe) {
      if (file == "") return
      n = nl; hd = ""; pending = ""; pipefail = 0; ng = 0
      for (i = 1; i <= n; i++) {
        if (hd != "") {
          probe = L[i]
          if (hd_dash) sub(/^\t+/, "", probe)
          if (probe == hd) hd = ""
          continue
        }
        line = L[i]
        if (line ~ /^[[:space:]]*#/) line = ""
        else sub(/[[:space:]]#.*$/, "", line)
        if (line != "" && index(L[i], "<<")) { heredoc_open(L[i]); if (hd != "" && !closes(i + 1, n)) hd = "" }
        if (pending != "") { line = pending " " trim(line); at = pending_at } else at = i
        if (line ~ /\\$/) { sub(/\\$/, "", line); pending = line; pending_at = at; continue }
        if (line ~ /(^|[^|])\|[[:space:]]*$/) { pending = line; pending_at = at; continue }
        pending = ""
        scan(line, at)
      }
      if (pending != "") scan(pending, pending_at)
      if (pipefail) { np++; for (i = 1; i <= ng; i++) { print gq[i]; found = 1 } }
      nfiles++; nl = 0
    }

    BEGIN {
      # Where a statement may begin, then an optional declaration word, then the assigned name.
      STMT = "(^|[;&|({!]|(^|[[:space:];])(then|do|else|if|elif|while|until)[[:space:]])[[:space:]]*((local|readonly|export|declare|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z0-9_]*"
    }
    FNR == 1 { end_file(); file = FILENAME }
    { L[++nl] = $0 }
    END {
      end_file()
      printf "suite-hygiene: scanned %d suite(s), %d under pipefail\n", nfiles, np > "/dev/stderr"
      exit (found ? 1 : 0)
    }
  ' "${files[@]}")"; rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  case "$rc" in 0|1|2) return "$rc" ;; *) return 2 ;; esac
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
if [ "$tree_rc" -eq 0 ]; then ok; else
  bad "the shipped suites carry a banned shape, or could not be scanned (rc $tree_rc):
$tree_out"
fi

work="$(mktemp -d)" || { echo "check-suite-hygiene: mktemp failed" >&2; exit 1; }
check_exit_guard "check-suite-hygiene" "rm -rf \"$work\""

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
  out="$(hygiene_scan "$d" 2>/dev/null)"; rc=$?
  eq "$rc" 1 "$label: the scan is red"
  has "$out" "scripts/check-fx.sh:$at: $class: " "$label: it names the line and the class"
}
# clean <label> <line>… — the fixture carries no finding.
clean() {
  local label="$1" d out rc; shift
  d="$(fx ok "$@")" || { bad "$label: could not build the fixture"; return; }
  out="$(hygiene_scan "$d" 2>/dev/null)"; rc=$?
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

# --- what the scan cannot read is 2, never clean ---
empty="$work/empty"; mkdir -p "$empty/scripts"
hygiene_scan "$empty" >/dev/null 2>&1; eq "$?" 2 "a tree with no suite is 2, not a clean scan"
# An opener that never closes hides nothing: the lines after it are code.
flagged "heredoc never closes" pwd-capture 3 "cat > f <<EOF" "ROOT=\"$PW\""
flagged "opener inside a string" pwd-capture 3 "has \"\$x\" \"done <<EOF\" label" "ROOT=\"$PW\"" 'EOF'
clean "opener after a string with a #" "$PF" "cat \"a #b\" <<EOF" "printf x $GQ y" 'EOF'
if [ "$(id -u)" -eq 0 ]; then
  check_note "SKIP: the unreadable-suite case cannot fire as root"
else
  d="$(fx locked 'ok')" || bad "could not build the unreadable fixture"
  chmod 000 "$d/scripts/check-fx.sh"
  hygiene_scan "$d" >/dev/null 2>&1; eq "$?" 2 "an unreadable suite is 2"
  chmod 644 "$d/scripts/check-fx.sh"
fi
# Two suites, one finding: the clean one does not hide it and the count names both.
d="$(fx two "work=\"$MK\"")" || bad "could not build the two-suite fixture"
printf '%s\n' '#!/usr/bin/env bash' "$PF" 'grep -q x <<< "$y"' > "$d/scripts/check-other.sh"
out="$(hygiene_scan "$d" 2>&1)"; eq "$?" 1 "one finding among two suites is red"
has "$out" "scanned 2 suite(s), 1 under pipefail" "…and the count line names what was read"
# The other suite's pipefail does not make a `set -u` suite's pipe a finding.
d="$(fx mixed 'set -u' "printf x $GQ y")" || bad "could not build the mixed fixture"
printf '%s\n' '#!/usr/bin/env bash' "$PF" 'ok' > "$d/scripts/check-other.sh"
hygiene_scan "$d" >/dev/null 2>&1; eq "$?" 0 "pipefail is decided per suite, not per scan"

# ---------------------------------------------------------------------------------------------
# 2. The pre-fix spelling, put back into a copy of a real suite, is caught.
# ---------------------------------------------------------------------------------------------
# revert <label> <suite> <fixed-line> <pre-fix-line> <class> — <fixed-line> must be exactly one
# line of the real suite; the copy carries <pre-fix-line> in its place.
revert() {
  local label="$1" suite="$2" fixed="$3" prefix="$4" class="$5" d="$work/revert" n at out rc
  rm -rf "$d"; mkdir -p "$d/scripts" || { bad "$label: could not build the copy"; return; }
  n="$(grep -Fxc -- "$fixed" "$ROOT/scripts/$suite")"
  if [ "$n" -ne 1 ]; then
    bad "$label: expected exactly 1 line [$fixed] in $suite, found $n — the control no longer describes the suite"
    return
  fi
  at="$(grep -Fxn -- "$fixed" "$ROOT/scripts/$suite")"; at="${at%%:*}"
  ADB_HY_OLD="$fixed" ADB_HY_NEW="$prefix" awk '
    $0 == ENVIRON["ADB_HY_OLD"] { print ENVIRON["ADB_HY_NEW"]; next } { print }
  ' "$ROOT/scripts/$suite" > "$d/scripts/$suite" || { bad "$label: could not write the copy"; return; }
  out="$(hygiene_scan "$d" 2>/dev/null)"; rc=$?
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
  bash "$pair/clone$NL/scripts/check-probe.sh" 2>/dev/null
}
CD_LINE='cd "$(dirname "$0")/.." || exit 1'
eq "$(probe "$CD_LINE" "ROOT=\"$PW\"")" "sibling-tree" "the banned capture, run in clone<NL>, reads the SIBLING tree (the defect, observed)"
eq "$(probe "$CD_LINE" 'ROOT="$PWD"')" "newline-tree" "…and \$PWD reads its own"

probed=0
while IFS= read -r -d '' rel; do
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
done < <(suite_files "$ROOT")
[ "$probed" -ge 30 ] && ok || bad "only $probed suite(s) had a ROOT capture to probe — the enumeration is short"

check_summary "check-suite-hygiene"
