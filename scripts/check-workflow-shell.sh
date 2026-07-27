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
#   NAME=value            a plain assignment (also `local NAME=` / `export NAME=`)
#   read … NAME …         a read target (the #126 shape)
#   for NAME in …         a loop variable
#
# Comments are stripped first, so a block may freely NAME the variables it avoids — the cleanup
# workflow documents this very trap in a comment, and flagging that would make the rule unwritable.
#
# Usage: bash scripts/check-workflow-shell.sh   (exit 0 = clean, 1 = a violation)

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "workflow-shell"

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

found=0
for wf in base/workflows/*.md; do
  [ -f "$wf" ] || continue
  case "$(basename "$wf")" in README.md) continue ;; esac

  # Extract the fenced bash blocks WITH their real line numbers, then strip comments so a block
  # can document the trap it is avoiding. `inb` tracks fence state; NR is the file line.
  code="$(awk '
    /^```bash$/ { inb = 1; next }
    /^```$/     { inb = 0; next }
    inb         { line = $0; sub(/[[:space:]]*#.*$/, "", line); print NR ":" line }
  ' "$wf")"
  [ -n "$code" ] || continue

  for name in $ZSH_SPECIALS; do
    # Three assignment shapes, one pass each. `-w` is not enough on its own — `$path` (a READ) is
    # fine and must not trip, so every pattern anchors on the assignment syntax itself.
    hits="$(printf '%s\n' "$code" | grep -nE \
      -e "(^|[;&|[:space:]])(local[[:space:]]+|export[[:space:]]+|typeset[[:space:]]+)?${name}=" \
      -e "(^|[;&|[:space:]])read([[:space:]]+-[A-Za-z]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)*[[:space:]]+${name}([[:space:]]|$)" \
      -e "(^|[;&|[:space:]])for[[:space:]]+${name}[[:space:]]+in([[:space:]]|$)" \
      || true)"
    [ -n "$hits" ] || continue
    found=1
    check_note "$wf assigns the zsh-special variable '$name' inside a fenced block:"
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    check_fail
  done
done

if [ "$found" -eq 1 ]; then
  check_note "zsh binds these names to shell state ('path' IS \$PATH), so assigning one empties or"
  check_note "corrupts it for the rest of the block. Rename the variable (e.g. 'sfile'), never the rule."
fi

check_result "no fenced workflow block assigns a zsh-special variable name"
