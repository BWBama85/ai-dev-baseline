#!/usr/bin/env bash
# ai-dev-baseline — shell lint for the fenced blocks inside base/workflows/*.md (issue #126).
#
# WHY THIS EXISTS. A workflow body is PROSE AN AGENT EXECUTES: the ```bash blocks are run for
# real, in whatever shell the agent has. But they are markdown, so `shellcheck` never sees them —
# the repo's shellcheck job enumerates tracked `*.sh` files, and a workflow is not one. That blind
# spot shipped a live bug in #125:
#
#     while IFS="$TABC" read -r kind path key; do
#
# `path` is a zsh SPECIAL VARIABLE bound to `$PATH`. Assigning a plain string to it replaces the
# search path, so on the FIRST iteration `$PATH` was emptied and every external command for the
# rest of the sweep — `bash`, `rm`, `git`, `gh` — was not found. macOS ships zsh as the default
# shell and `base/practices/shell.md` says so explicitly, so this was the common case. The symptom
# was `/cleanup` deleting nothing and reporting success: the exact silent-no-op class #106 had
# just been fixed to remove.
#
# The rule this enforces is therefore narrow and mechanical: a fenced workflow block must never
# ASSIGN to a name that zsh reserves. It does not try to be a shell parser or a second shellcheck —
# it catches the one class that is invisible to every other gate here and destructive when it hits.
#
# Assignment is detected in the three forms a workflow actually uses:
#   NAME=value            a plain assignment (also `local`/`export`/`typeset`/`declare` NAME=)
#   read … NAME …         a read target (the #126 shape)
#   for NAME in …         a loop variable
#
# MATCHING RUNS INSIDE AWK, against the RAW line. An earlier version piped `NR ":" line` into
# grep, which silently broke every `^`-anchored alternative: the character before a start-of-line
# `path=` was then the `:` of the line-number prefix, not a start boundary, so `path=/tmp`,
# `read -r path` and `for path in …` all passed. The real bug was still caught only because it
# happened to have a space before `read`. The SELF-TEST at the bottom exists so that class of
# hole — a guard that passes because it cannot see — fails the build instead of shipping.
#
# Comments are stripped first, so a block may freely NAME the variables it avoids; the cleanup
# workflow documents this very trap in a comment, and flagging that would make the rule unwritable.
#
# Usage: bash scripts/check-workflow-shell.sh [workflow-dir]
#        (exit 0 = clean, 1 = a violation. <workflow-dir> defaults to base/workflows; it exists
#         for the self-test and for linting a rendered tree.)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "workflow-shell"

WFDIR="${1:-base/workflows}"

# The zsh specials that are realistic accidental choices for a loop/temp variable AND destructive
# when clobbered. Deliberately NOT the full zsh special list: `status`, `options`, `commands` and
# friends are either read-only (so an assignment fails loudly rather than silently) or too generic
# to forbid without false positives on ordinary prose-shell. Each name here empties or corrupts
# something the rest of the block depends on.
#   path/PATH        — command lookup (the #126 bug)
#   fpath            — function autoload path
#   cdpath           — `cd` search path
#   manpath/MANPATH  — man lookup
#   module_path      — zsh module lookup
#   argv             — positional parameters
ZSH_SPECIALS='path fpath cdpath manpath module_path argv'

# scan_one <file> — print "<file>:<line>: <raw line>" for every violation. All matching happens
# here, on the raw line, so `^` genuinely means start-of-line.
scan_one() {
  awk -v SPECIALS="$ZSH_SPECIALS" '
    BEGIN { nsp = split(SPECIALS, sp, " ") }
    /^```bash$/ { inb = 1; next }
    /^```$/     { inb = 0; next }
    !inb { next }
    {
      raw = $0
      line = raw
      # Strip a trailing/whole-line comment so a block may document the trap it avoids. A `#`
      # inside a quoted string is stripped too; that can only cause a MISSED report on that one
      # line, never a false one, and the alternative is a shell parser.
      sub(/(^|[[:space:]])#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      # A boundary is start-of-line or a shell separator. Anchoring on the raw line is the whole
      # point — see the header note about the line-number prefix that used to defeat it.
      B = "(^|[;&|(){}[:space:]])"
      for (i = 1; i <= nsp; i++) {
        nm = sp[i]
        if (line ~ (B "(local[[:space:]]+|export[[:space:]]+|typeset[[:space:]]+|declare[[:space:]]+)?" nm "=") ||
            line ~ (B "read([[:space:]]+-[A-Za-z]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+" nm "([[:space:]]|$)") ||
            line ~ (B "for[[:space:]]+" nm "[[:space:]]+in([[:space:]]|$)")) {
          printf "%s:%d: %s\n", FILENAME, FNR, raw
          next
        }
      }
    }
  ' "$1"
}

found=0
for wf in "$WFDIR"/*.md; do
  [ -f "$wf" ] || continue
  case "$(basename "$wf")" in README.md) continue ;; esac
  hits="${ scan_one "$wf"; }"
  [ -n "$hits" ] || continue
  found=1
  check_note "$wf assigns a zsh-special variable inside a fenced block:"
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
  check_fail
done

if [ "$found" -eq 1 ]; then
  check_note "zsh binds these names to shell state ('path' IS \$PATH), so assigning one empties or"
  check_note "corrupts it for the rest of the block. Rename the variable (e.g. 'sfile'), never the rule."
fi

# --- self-test: prove the guard can actually SEE ------------------------------------------------
# A lint that silently matches nothing passes every clean tree, which is indistinguishable from
# working — and is exactly how the `NR ":"` prefix defeated the `^` anchors here without anyone
# noticing. So the guard proves itself on a fixture carrying each shape in BOTH positions
# (start-of-line and mid-line) before it is allowed to report PASS, and proves it stays quiet on
# the legitimate forms it must never flag. Only run for the default tree — a caller pointing this
# at another directory is already doing something deliberate.
if [ "$WFDIR" = "base/workflows" ]; then
  st="$(mktemp -d)" || { check_note "self-test: mktemp failed"; check_fail; }
  if [ -n "${st:-}" ] && [ -d "$st" ]; then
    # MUST be caught — one file per case, so a single missed shape is named precisely.
    i=0
    for bad in 'path=/tmp' \
               'read -r path' \
               'for path in a b; do :; done' \
               '  fpath=/x' \
               'x=1; cdpath=/y' \
               'while IFS= read -r kind path key; do :; done' \
               'for argv in 1 2; do :; done' \
               'export manpath=/z'; do
      i=$((i + 1))
      printf -- '---\nname: f%s\n---\n```bash\n%s\n```\n' "$i" "$bad" > "$st/f$i.md"
      if [ -z "${ scan_one "$st/f$i.md"; }" ]; then
        check_note "self-test: the guard FAILED to catch [$bad] — it cannot see the bug it exists to stop"
        check_fail
      fi
    done
    # MUST NOT be caught — reads, look-alike names, prose, and a comment naming the trap.
    j=0
    for good in 'echo "$path"' \
                'sfile=/tmp' \
                'mypath=/tmp' \
                'PATHX=/tmp' \
                'read -r kind sfile key' \
                '# never assign path= here, and never for path in …' \
                'printf "%s\n" "${path##*/}"'; do
      j=$((j + 1))
      printf -- '---\nname: g%s\n---\n```bash\n%s\n```\n' "$j" "$good" > "$st/g$j.md"
      if [ -n "${ scan_one "$st/g$j.md"; }" ]; then
        check_note "self-test: FALSE POSITIVE on [$good]"
        check_fail
      fi
    done
    # Text outside a fenced bash block is prose and must never be scanned.
    printf -- '---\nname: h\n---\nProse mentioning path=/tmp inline.\n\n```text\npath=/tmp\n```\n' > "$st/h.md"
    if [ -n "${ scan_one "$st/h.md"; }" ]; then
      check_note "self-test: FALSE POSITIVE outside a fenced bash block"
      check_fail
    fi
    rm -rf "$st"
  fi
fi

check_result "no fenced workflow block assigns a zsh-special variable name (guard self-verified)"
