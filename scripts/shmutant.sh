#!/usr/bin/env bash
# shmutant — mutation testing for bash and POSIX shell.
#
# Inject one literal defect per row into a throwaway copy of a tree, run only the tests that
# claim to cover it, and require that test to go RED on its own witness. Vendorable as this one
# file: source it for the library API, or execute it for the CLI (`shmutant help`).
#
# Library API:
#   shmutant_target <file>                               file (relative to the tree root) that
#                                                        subsequent rows mutate
#   shmutant_mut <name> <old> <new> <witness> [select]   append one row (literals, never regexes;
#                                                        <old> may occur at most once in the target)
#   shmutant_refuse <reason>                             refuse a declaration the plan checked
#                                                        itself; the pool then exits 2
#   shmutant_reset                                       empty the table
#   shmutant_pool <label> <workdir> <prepare> <run> [cap] run every row; 0 = every row killed,
#                                                        1 = a row was not, 2 = harness error
#   shmutant_mutate <file> <old> <new>                   0 applied, 1 rewrite failed, 2 no match
#   shmutant_selected <unit>                             true when <unit> is selected (or nothing is)
#   shmutant_copy_tree <src> <dst>                       copy a tree, excluding .git
#
# Adapter contract (two callbacks, called with their arguments; prepare in the pool's shell, run
# in a subshell of its own with its own process group, stdin from /dev/null, stdout and stderr
# captured, and errexit off):
#   prepare <dir>          populate <dir> with the tree under test. Optionally print the tree
#                          root (default: <dir>); it must lie inside <dir>. Called ONCE per pool.
#   run <root> <select>    run the tests covering <select> inside <root>. SHMUTANT_SELECT is
#                          exported with the same value. Exit 0 = green; exit
#                          SHMUTANT_RED_STATUS (default 1) = red; anything else = aborted. A red
#                          line starts with SHMUTANT_RED_PREFIX (default "FAIL: ") and carries
#                          the row's witness. With SHMUTANT_COUNTS=1, <select> is empty for one
#                          baseline run, which runs every test, and every run may append
#                          `<unit>\t<assertions>` lines to descriptor SHMUTANT_COUNTS_FD.
#
# Environment (all optional):
#   SHMUTANT_JOBS        worker count; replaces the CPU probe, the pool's cap still applies
#   SHMUTANT_TIMEOUT     seconds a single run may take (default 300; 0 = unbounded)
#   SHMUTANT_BASELINE    1 (default) runs each distinct selector once, uninjected, and requires
#                        green; 0 skips that pass
#   SHMUTANT_COUNTS      1 adds one unselected baseline run and requires each selected baseline
#                        to report, per unit, the assertion count the unselected run reported
#                        (default 0; needs SHMUTANT_BASELINE=1)
#   SHMUTANT_KEEP        1 keeps every clone after its run (default: clones are removed)
#   SHMUTANT_STREAM      file the verdict stream is appended to (default: stdout)
#   SHMUTANT_RED_PREFIX  see run; SHMUTANT_RED_STATUS  see run
#
# Verdict stream (stdout, tab-separated, one record per line; \t \n \\ escaped in fields):
#   shmutant  1  baseline  <select>  <verdict>  <seconds>  <detail>
#   shmutant  1  row       <verdict> <name>  <target>  <select>  <seconds>  <detail>
#   shmutant  1  summary   <label>   <rows>  <killed>  <jobs>  <seconds>
# Row verdicts: killed (the only pass), survived, accidental, aborted, unapplied, unprepared,
# baseline, timeout, unsettled, lost. Baseline verdicts: green (the only pass), red, aborted,
# timeout, unprepared, unsettled, lost, and incomplete (SHMUTANT_COUNTS=1: green, but its counts
# do not show the selection running what the unselected run runs for its units).
#
# Requires bash >= 5.3, the POSIX utilities (coreutils, find, awk). Nothing else; `ps` (POSIX)
# is used when present to reach timed-out descendants that left the run's process group and,
# on INT/TERM, the trees of running workers. Every external command is run through
# `command -p`: a function a plan defines under a utility's name, a function exported by the
# invoking environment, or a PATH prepare set to the tree's own bin never stands in for one.

# A function named builtin — one the CLI inherited as an exported function, or a caller's —
# would stand in for every qualified call below; it goes first. Tests below are the [[ keyword,
# which no function or alias can stand in for. (`unset` itself has no unshadowable form: a
# shell that shadows it is beyond this file's reach.) Backslash-prefixed words are never
# alias-expanded: aliases are still on here, and a caller's `alias builtin=…` would otherwise
# stand in for the dispatcher until the line below turns them off.
\unset -f builtin 2>/dev/null

# _shmutant_boot_readonly <name> — true when <name> is readonly in the sourcing shell. Defined
# first, in bash-3.2 syntax, with no variable of its own: the file's bootstrap state must not
# land in a name the caller made readonly (the assignment would fail, sourcing would go on, and
# the caller's stale value would be evaluated at the end). The attribute field of a `declare -p`
# line is the word after `declare -`.
_shmutant_boot_readonly() { _shmutant_boot_attrs "$(\builtin declare -p -- "$1" 2>/dev/null)"; }
_shmutant_boot_attrs() { _shmutant_boot_field "${1#declare -}"; }
_shmutant_boot_field() { case "${1%% *}" in *r*) \builtin return 0 ;; esac; \builtin return 1; }
if _shmutant_boot_readonly _shmutant_alias_state || _shmutant_boot_readonly _shmutant_candidate || _shmutant_boot_readonly _shmutant_v; then
  \builtin printf 'shmutant: a name this file keeps its bootstrap state in (_shmutant_alias_state, _shmutant_candidate, _shmutant_v) is readonly in this shell — declare yours with another name\n' >&2
  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then \builtin exit 2; fi
  \builtin return 2
fi

# Aliases expand while a file is PARSED: a sourcing shell whose dotfiles alias `cp` or `mkdir`
# would otherwise bake those flags into every function below. Off for the rest of this file,
# and the caller's setting put back at its end.
_shmutant_alias_state="$(\builtin shopt -p expand_aliases; :)"; \builtin shopt -u expand_aliases

# _shmutant_bash_ok <major> <minor> — is that interpreter version at or above the floor?
# Defined in bash-3.2 syntax: it runs before the rest of this file is parsed.
# The [[ keyword, which nothing can shadow: this runs before _shmutant_no_shadows exists, and a
# caller's function named [ (or builtin) would otherwise decide whether an old bash is refused.
_shmutant_bash_ok() {
  [[ "$1" -gt 5 ]] || { [[ "$1" -eq 5 ]] && [[ "$2" -ge 3 ]]; }
}

# _shmutant_install_hint — the platform's install command for a modern bash.
_shmutant_install_hint() {
  case "$(builtin command -p uname -s 2>/dev/null)" in
    Darwin) builtin echo 'brew install bash   (then put /opt/homebrew/bin or /usr/local/bin before /bin in PATH)' ;;
    *)      builtin echo 'install bash >= 5.3 from your package manager, Homebrew (brew install bash), or https://ftp.gnu.org/gnu/bash/' ;;
  esac
}

# _shmutant_path_bash — the executable named bash on PATH, or nothing. -P: an exported function
# named bash would otherwise be returned by name and mistaken for a missing interpreter.
_shmutant_path_bash() {
  builtin type -P bash 2>/dev/null
}

if ! _shmutant_bash_ok "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"; then
  if [[ "${BASH_SOURCE[0]}" = "$0" ]] && [[ -z "${SHMUTANT_REEXEC:-}" ]]; then
    for _shmutant_candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash "$(_shmutant_path_bash)"; do
      if [[ -n "$_shmutant_candidate" ]] && [[ -x "$_shmutant_candidate" ]] \
        && "$_shmutant_candidate" -c '[[ "${BASH_VERSINFO[0]}" -gt 5 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 5 ]] && [[ "${BASH_VERSINFO[1]}" -ge 3 ]]; }' 2>/dev/null; then
        SHMUTANT_REEXEC=1 builtin exec "$_shmutant_candidate" "$0" "$@"
      fi
    done
  fi
  builtin printf 'shmutant: bash %s is below the 5.3 floor and no newer bash was found; %s\n' \
    "${BASH_VERSION:-unknown}" "$(_shmutant_install_hint)" >&2
  if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then builtin exit 2; fi
  builtin eval "$_shmutant_alias_state"; builtin unset _shmutant_alias_state
  builtin return 2
fi

# A name this file assigns when sourced that the calling shell made readonly beforehand: the
# assignment would end a non-interactive shell, so the file refuses first. One name at a time:
# the attribute field of its `declare -p` line is the word after `declare -`.
for _shmutant_v in SHMUTANT_VERSION SHMUTANT_PROC SHMUTANT_SELECTED_N SHMUTANT_DECL_ERRORS SHMUTANT_TARGET SHMUTANT_ROWS_NAME SHMUTANT_ROWS_FILE SHMUTANT_ROWS_OLD SHMUTANT_ROWS_NEW SHMUTANT_ROWS_WIT SHMUTANT_ROWS_SEL; do
  if _shmutant_boot_readonly "$_shmutant_v"; then
    \builtin printf 'shmutant: %s is readonly in this shell, and this file assigns it when sourced — declare yours with another name\n' "$_shmutant_v" >&2
    if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then \builtin exit 2; fi
    \builtin unset -v _shmutant_v
    \builtin eval "$_shmutant_alias_state"; \builtin unset _shmutant_alias_state
    \builtin return 2
  fi
done
\builtin unset -v _shmutant_v

SHMUTANT_VERSION=0.2.0
# Process identity comes from the kernel's start time in /proc where there is one (Linux):
# tick resolution, so a reused pid cannot pass for the process it replaced. Elsewhere it is the
# start time ps recorded (`lstart`, fixed at the fork, which a clock step does not move), and
# only where ps has no lstart the wall clock less `ps -o etime`, at second resolution.
SHMUTANT_PROC=0; [[ -r /proc/self/stat ]] && SHMUTANT_PROC=1
SHMUTANT_ROWS_NAME=(); SHMUTANT_ROWS_FILE=(); SHMUTANT_ROWS_OLD=(); SHMUTANT_ROWS_NEW=()
SHMUTANT_ROWS_WIT=(); SHMUTANT_ROWS_SEL=()
SHMUTANT_TARGET=""
SHMUTANT_SELECTED_N=0
SHMUTANT_DECL_ERRORS=0

# _shmutant_err <msg…> — a harness diagnostic on stderr.
_shmutant_err() { builtin printf 'shmutant: %s\n' "$*" >&2; }

# _shmutant_refuse <msg…> — a refused declaration: report it, count it, return 2. The count is
# what lets a plan fail as a whole: sourcing returns only the LAST command's status.
_shmutant_refuse() { _shmutant_err "$@"; SHMUTANT_DECL_ERRORS=$((SHMUTANT_DECL_ERRORS + 1)); return 2; }

# _shmutant_esc <string> — print <string> with backslash, tab and newline escaped for the stream.
_shmutant_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# _shmutant_emit <field>… — append one tab-separated record to the verdict stream. A write that
# fails sets SHMUTANT_EMIT_FAILED, which the pool turns into exit 2: a lost record is a lost
# verdict, and CI reading the stream must never take silence for a pass.
_shmutant_emit() {
  local out="" f
  for f in "$@"; do out+="$(_shmutant_esc "$f")"$'\t'; done
  out="${out%$'\t'}"
  # Through the descriptor the pool opened after validating the path, never by reopening the
  # path: a callback could have replaced it with a symlink since.
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then
    { printf '%s\n' "$out" >&"$SHMUTANT_STREAM_FD"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1
    [ -z "${SHMUTANT_STREAM_COPY_W:-}" ] || { printf '%s\n' "$out" >&"$SHMUTANT_STREAM_COPY_W"; } 2>/dev/null || SHMUTANT_EMIT_FAILED=1
  else
    printf '%s\n' "$out" 2>/dev/null || SHMUTANT_EMIT_FAILED=1
  fi
}

# _shmutant_pos_int <value> — print <value> when it is a positive integer, else return 1.
_shmutant_pos_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ] || return 1
  printf '%s' "$1"
}

# _shmutant_cpus — online CPU count, 2 when nothing can report it.
_shmutant_cpus() {
  local n
  n="$(command -p getconf _NPROCESSORS_ONLN 2>/dev/null)" || n="$(command -p nproc 2>/dev/null)" || n=""
  _shmutant_pos_int "$n" || printf '2'
}

# _shmutant_jobs [cap] — min(SHMUTANT_JOBS or cpu count, cap or 8).
_shmutant_jobs() {
  local cap n
  cap="$(_shmutant_pos_int "${1:-8}")" || cap=8
  n="$(_shmutant_pos_int "${SHMUTANT_JOBS:-}")" || n="$(_shmutant_cpus)"
  [ "$n" -le "$cap" ] || n="$cap"
  printf '%s' "$n"
}

# _shmutant_now — seconds since the epoch, to the microsecond, as an integer of microseconds.
_shmutant_now() {
  local t="$EPOCHREALTIME"
  printf '%s' "${t//[!0-9]/}"
}

# _shmutant_secs <microseconds> — render a microsecond count as seconds with three decimals.
_shmutant_secs() {
  local us="$1" ms
  # EPOCHREALTIME is wall-clock: a clock set back between two readings gives a negative span,
  # which would render as `-1.-999`; the record carries 0.000 instead, never a malformed number.
  [ "$us" -ge 0 ] 2>/dev/null || us=0
  ms=$(( (us + 500) / 1000 ))
  printf '%d.%03d' "$(( ms / 1000 ))" "$(( ms % 1000 ))"
}

# _shmutant_abs <dir> — the physical absolute path of an existing directory, or return 1.
# CDPATH is dropped: with it set, `cd` prints the directory it matched and the result would be
# two lines.
_shmutant_abs() {
  # builtin: a caller's `cd` or `pwd` function must not stand in. A relative name is prefixed
  # with ./ so that `-` is a directory, never `cd -`, and CDPATH is never consulted. A name
  # ending in a newline is refused: the substitution around this call would strip it and
  # answer with the sibling.
  case "$1" in *$'\n') return 1 ;; esac
  local d="$1"
  case "$d" in /*) ;; *) d="./$d" ;; esac
  # The physical name too: a newline-free symlink can resolve to a directory whose name ends
  # in one, and the caller's substitution would strip it and answer with the sibling.
  ( builtin cd -P -- "$d" 2>/dev/null || exit 1
    case "$PWD" in *$'\n'*) exit 1 ;; esac
    builtin pwd -P )
}

# _shmutant_inside <root> <path> — true when <path> is <root> or below it, compared byte for
# byte: the caller's nocasematch must not make a path that merely resembles the root pass.
_shmutant_inside() {
  ( shopt -u nocasematch; if [ "$1" = / ]; then case "$2" in /*) exit 0 ;; esac; exit 1; fi
    case "$2" in "$1"|"$1/"*) exit 0 ;; esac; exit 1 )
}

# _shmutant_target_ok <root> <file> — true when <root>/<file> is a regular file, not a symlink,
# whose directory resolves physically to <root> or below it. A symlinked parent component is
# how a relative target reaches a caller-owned file outside the tree.
_shmutant_target_ok() {
  local root="$1" f="$1/$2" dir
  [ ! -L "$f" ] && [ -f "$f" ] || return 1
  root="$(_shmutant_abs "$root")" || return 1
  dir="$(_shmutant_abs "$(command -p dirname -- "$f")")" || return 1
  _shmutant_inside "$root" "$dir" || return 1
  # A directory component that is an ABSOLUTE symlink stays inside this tree but, cloned as a
  # link, points back at it: the clone's copy of the target would not be the clone's.
  _shmutant_no_absolute_link "$1" "$2"
}

# _shmutant_no_absolute_link <root> <relative> — true when no directory component of <relative>
# under <root> is a symlink whose target is absolute.
_shmutant_no_absolute_link() {
  local root="$1" rel here comp target base pending depth=0
  rel="$(command -p dirname -- "$2")"
  [ "$rel" != . ] || return 0
  # A relative link's target is walked component by component from where the link sits, and so
  # on (bounded): a target of `c/sub` where `c` is an absolute link is that absolute link, which
  # a clone would keep pointing back at the prepared tree. A `..` that leaves the root is
  # refused even when the chain comes back in: what lies outside is not cloned, so the clone's
  # copy of that link points at nothing.
  pending="$rel"
  while [ -n "$pending" ]; do
    depth=$(( depth + 1 )); [ "$depth" -le 40 ] || return 1
    here="$root"; rel="$pending"; pending=""
    while [ -n "$rel" ]; do
      comp="${rel%%/*}"; case "$rel" in */*) rel="${rel#*/}" ;; *) rel="" ;; esac
      case "$comp" in ''|.) continue ;; ..) here="${here%/*}"; case "$here" in "$root"|"$root"/*) ;; *) return 1 ;; esac; continue ;; esac
      here="$here/$comp"
      if [ -L "$here" ]; then
        target="$(command -p readlink -- "$here" 2>/dev/null)" || return 1
        case "$target" in /*) return 1 ;; esac
        base="${here%/*}"; base="${base#"$root"}"; base="${base#/}"
        pending="${base:+$base/}$target${rel:+/$rel}"
        break
      fi
    done
  done
  return 0
}

# shmutant_selected <unit> — true when no selection is active or SHMUTANT_SELECT equals <unit>.
# Counts every selected unit in SHMUTANT_SELECTED_N so a suite can refuse to pass on zero.
shmutant_selected() {
  if [ "$#" -ne 1 ]; then _shmutant_err "selected: usage: shmutant_selected <unit>"; return 2; fi
  if [ -z "${SHMUTANT_SELECT:-}" ] || [ "$SHMUTANT_SELECT" = "$1" ]; then
    SHMUTANT_SELECTED_N=$((SHMUTANT_SELECTED_N + 1))
    return 0
  fi
  return 1
}

# shmutant_copy_tree <src> <dst> — copy <src> to <dst> (created), skipping a top-level .git
# and keeping symlinks as symlinks, modes, ownership and timestamps. Returns 1 when anything
# fails to copy, or when <dst> lies inside <src>.
# _shmutant_aliases_off <site> — expand_aliases off for the rest of a public entry point, the
# caller's setting saved in SHMUTANT_ALIASES for _shmutant_aliases_back. Bash parses a command
# substitution when it RUNS it, so with the option on in the caller's shell every `$(printf …)`
# in this file would expand the caller's alias at run time; the prologue covers only parse time.
# The first word is quoted, so this switch itself is beyond alias expansion. <site> only labels
# the call.
# _shmutant_aliases_off <variable> — save the caller's expand_aliases setting into <variable>
# (the entry point's own local, so a helper called from inside a pool's callback does not
# overwrite the pool's) and turn the option off; _shmutant_aliases_back <saved> puts it back.
_shmutant_aliases_off() {
  # `; :` — shopt -p exits 1 for an option that is off, which a caller's errexit would act on.
  local st; st="$(\builtin shopt -p expand_aliases; :)"
  # The builtin and the keyword: this runs before (and after) the shadow check, and a caller's
  # printf or [ function would otherwise leave the setting unsaved or unrestored.
  \builtin printf -v "$1" '%s' "$st"
  \builtin shopt -u expand_aliases
}
_shmutant_aliases_back() {
  [[ -z "$1" ]] || \builtin eval "$1"
}

shmutant_copy_tree() {
  # Before any local: bash refuses a local over a readonly global, and the assignment that
  # follows would end a non-interactive caller's shell. The names are this helper's locals.
  _shmutant_locals_writable copy_tree "the calling shell made" adst asrc comp copy_tree_aliases d dst entry frc kinds linked m made n name norm out probe probe2 rc rest rootls src st t who || \builtin return 1
  local rc copy_tree_aliases; _shmutant_aliases_off copy_tree_aliases
  # The same shadow check as the pool's: a caller's function named printf, cd or [ would
  # otherwise decide what this helper does, with no pool around to refuse it.
  _shmutant_no_shadows copy_tree || { _shmutant_aliases_back "$copy_tree_aliases"; builtin return 1; }
  # A plain call, not a condition: a callback's own errexit is honoured inside, as documented.
  _shmutant_copy_tree_body "$@"; rc=$?
  _shmutant_aliases_back "$copy_tree_aliases"; builtin return "$rc"
}
_shmutant_copy_tree_body() {
  if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then _shmutant_err "copy_tree: usage: shmutant_copy_tree <src> <dst> (neither empty)"; return 1; fi
  # A newline in either name would be stripped by the substitutions that split it, and the
  # copy would land on the sibling.
  case "$1$2" in *$'\n'*) _shmutant_err "copy_tree: a path containing a newline is refused"; return 1 ;; esac
  local src="$1" dst="$2" entry name rc=0 asrc adst
  [ -d "$src" ] || { _shmutant_err "copy_tree: not a directory: $src"; return 1; }
  # Resolved first, so the scan below and the copy walk the same tree; find would not follow a
  # symlinked root that the glob does.
  src="$(_shmutant_abs "$src")" || { _shmutant_err "copy_tree: cannot resolve $1"; return 1; }
  if [ -L "$dst" ]; then _shmutant_err "copy_tree: destination $dst is a symlink — it would be written through, not created"; return 1; fi
  # The destination is rebuilt on the physical path of its nearest existing ancestor, so the
  # containment check below and every write see the directory a symlinked component would
  # otherwise have hidden; a link into the source tree is then caught, not followed.
  local probe rest=""
  probe="$dst"
  case "$probe" in /*) ;; *) probe="$(builtin pwd -P)/$probe" ;; esac
  while [ ! -d "$probe" ] || [ -L "$probe" ]; do
    [ -L "$probe" ] && [ -d "$probe" ] && break
    rest="$(command -p basename -- "$probe")${rest:+/$rest}"; probe="$(command -p dirname -- "$probe")"
    [ "$probe" != / ] || break
  done
  probe="$(_shmutant_abs "$probe")" || { _shmutant_err "copy_tree: cannot resolve the destination $dst"; return 1; }
  # The components still to be created are settled lexically first: mkdir -p would otherwise
  # create a `junk` in `junk/../copy` (inside the source, when that is where it points) and
  # the copy would then find it there.
  local comp norm=""
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"; case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    case "$comp" in
      ''|.) ;;
      ..) if [ -n "$norm" ]; then case "$norm" in */*) norm="${norm%/*}" ;; *) norm="" ;; esac
          else probe="$(command -p dirname -- "$probe")"; fi ;;
      *)  norm="${norm:+$norm/}$comp" ;;
    esac
  done
  rest="$norm"
  dst="$probe${rest:+/$rest}"
  # A copy gives each hard link its own inode, and the pool's later check could not tell: a
  # source carrying one is refused here, naming it.
  local linked
  # Searched from inside the source: `-path` takes a pattern, and a source whose name holds a
  # bracket expression would otherwise never match its own .git.
  local frc=0
  linked="$(builtin cd -- "$src" 2>/dev/null && command -p find . -path ./.git -prune -o -type f -links +1 -print 2>/dev/null)" || frc=$?
  if [ "$frc" -ne 0 ]; then _shmutant_err "copy_tree: cannot scan $src for hard links (find failed, status $frc)"; return 1; fi
  linked="${linked%%$'\n'*}"
  if [ -n "$linked" ]; then
    _shmutant_err "copy_tree: $src/${linked#./} has more than one hard link — a copy cannot keep them joined; prepare that tree yourself, or name the file it aliases"; return 1
  fi
  # The first component mkdir would create is remembered, so a refusal leaves nothing behind.
  local made="" probe2="$dst"
  while [ ! -e "$probe2" ]; do made="$probe2"; probe2="$(command -p dirname -- "$probe2")"; [ "$probe2" != "$made" ] || break; done
  command -p mkdir -p -- "$dst" || return 1
  if ! asrc="$(_shmutant_abs "$src")" || ! adst="$(_shmutant_abs "$dst")"; then
    [ -z "$made" ] || command -p rm -rf -- "$made"
    return 1
  fi
  if _shmutant_inside "$asrc" "$adst"; then
    [ -n "$made" ] && command -p rm -rf -- "$made"
    _shmutant_err "copy_tree: destination $dst lies inside the source $src — it would copy itself; use a workdir outside the tree"; return 1
  fi
  # The enumeration runs with the caller's expansion settings neutralised: `set -f` would hand
  # the loop three literal patterns, failglob would abort on an unmatched one, GLOBIGNORE would
  # drop entries, dotglob would list hidden entries twice.
  (
    set +f; shopt -u failglob dotglob; shopt -s nullglob; unset GLOBIGNORE
    # An existing destination must be empty: a caller's entry of a source name would be
    # overwritten by cp, or written through when it is a symlink, and neither is this helper's
    # to do.
    for entry in "$dst"/* "$dst"/.[!.]* "$dst"/..?*; do
      { [ -e "$entry" ] || [ -L "$entry" ]; } && { _shmutant_err "copy_tree: destination $dst is not empty — it is never written into; give an empty or absent directory"; exit 1; }
    done
    for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name="${entry##*/}"
      [ "$name" = .git ] && continue
      command -p cp -RPp -- "$entry" "$dst/" || rc=1
    done
    exit "$rc"
  ) || return 1
  # The root directory's own metadata, which the per-entry copy never touches, applied LAST:
  # adding entries resets a directory's mtime, and a read-only root would refuse them. Only
  # after a copy that succeeded: a destination refused (not empty) or half-copied is not made
  # over in the source's image.
  _shmutant_apply_root_meta "$src" "$dst" || { _shmutant_err "copy_tree: could not reproduce the root directory's owner, mode or timestamp on $dst"; return 1; }
  return 0
}

# _shmutant_apply_root_meta <src> <dst> — give directory <dst> the owner, mode and mtime of <src>.
_shmutant_apply_root_meta() {
  local rootls rc=0
  rootls="$(command -p ls -ld -- "$1" 2>/dev/null)" || return 1
  command -p chown -- "$(builtin printf '%s\n' "$rootls" | command -p awk '{ print $3 ":" $4 }')" "$2" 2>/dev/null || rc=1
  command -p chmod -- "$(_shmutant_mode_spec "${rootls%% *}")" "$2" 2>/dev/null || rc=1
  command -p touch -r "$1" -- "$2" 2>/dev/null || rc=1
  return "$rc"
}

# _shmutant_mode_triple <rwx-triple> <u|g|o> — one clause of a chmod symbolic spec.
_shmutant_mode_triple() {
  local t="$1" who="$2" out=""
  case "${t:0:1}" in r) out+=r ;; esac
  case "${t:1:1}" in w) out+=w ;; esac
  case "${t:2:1}" in
    x) out+=x ;;
    s) out+=xs ;; S) out+=s ;;
    t) out+=xt ;; T) out+=t ;;
  esac
  builtin printf '%s=%s' "$who" "$out"
}

# _shmutant_mode_spec <ls-l-mode-string> — a chmod symbolic spec equal to the mode in an
# `ls -l` mode field (`-rwsr-xr-x` -> `u=rwxs,g=rx,o=rx`), setuid, setgid and sticky included.
_shmutant_mode_spec() {
  local m="$1"
  # In a subshell with nocasematch off: `S` and `T` (a set-id or sticky bit without execute)
  # must not fall into the `s` and `t` arms and gain an execute bit.
  ( shopt -u nocasematch; builtin printf '%s,%s,%s' "$(_shmutant_mode_triple "${m:1:3}" u)" "$(_shmutant_mode_triple "${m:4:3}" g)" "$(_shmutant_mode_triple "${m:7:3}" o)" )
}

# _shmutant_mutate_restore <dir> <ls-mode-or-empty> — put back a directory mode shmutant_mutate
# loosened for the rewrite; a no-op when it loosened nothing.
_shmutant_mutate_restore() {
  [ -n "$2" ] || return 0
  command -p chmod -- "$(_shmutant_mode_spec "$2")" "$1" 2>/dev/null && return 0
  _shmutant_err "mutate: the mode of $1 could not be put back"; return 1
}

# shmutant_mutate <file> <old> <new> — replace the FIRST occurrence of literal <old> with <new>,
# in place. 0 applied; 1 the rewrite failed (file unreadable, dir unwritable); 2 <old> matched
# nothing, or is empty, or equals <new>: file unchanged (awk reports the miss itself, so no
# `cmp` is needed). A symlink is
# refused (1): renaming over it would swap the link for a
# file and leave the referent, which the tests may read, untouched. A literal spanning two lines
# never matches: awk sees one record.
# ENVIRON, not -v: -v processes backslash escapes, so `\$` and `\n` would arrive altered.
# The rewrite lands in a fresh mktemp sibling (never a predictable name, which could be a symlink
# out of the tree) that carries the target's mode, and is renamed over the target, never
# `sed -i` (BSD and GNU differ), so a failed rewrite cannot half-write. A target whose last line
# has no newline keeps that shape: the only change is the literal.
shmutant_mutate() {
  # Before any local: bash refuses a local over a readonly global, and the assignment that
  # follows would end a non-interactive caller's shell. The names are this helper's locals.
  _shmutant_locals_writable mutate "the calling shell made" dir dirmode f kinds m mode mutate_aliases n nl out rc st t tmp who || \builtin return 1
  local rc mutate_aliases; _shmutant_aliases_off mutate_aliases
  _shmutant_no_shadows mutate || { _shmutant_aliases_back "$mutate_aliases"; builtin return 1; }
  # A plain call, not a condition: a callback's own errexit is honoured inside, as documented.
  _shmutant_mutate_body "$@"; rc=$?
  _shmutant_aliases_back "$mutate_aliases"; builtin return "$rc"
}
_shmutant_mutate_body() {
  if [ "$#" -ne 3 ]; then _shmutant_err "mutate: usage: shmutant_mutate <file> <old> <new>"; return 1; fi
  case "$1" in *$'\n'*) _shmutant_err "mutate: a path containing a newline is refused"; return 1 ;; esac
  local f="$1" tmp nl=1 rc mode dir dirmode=""
  # A bare name is made a path: to awk, `-` is standard input and `x=1` an assignment.
  case "$f" in /*|./*|../*) ;; *) f="./$f" ;; esac
  [ -n "$2" ] && [ "$2" != "$3" ] || return 2
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  dir="$(command -p dirname -- "$f")"
  # A read-only directory (a preserved 0555 root) cannot host the temp file or the rename; it is
  # made writable for the rewrite and put back afterwards.
  if [ ! -w "$dir" ]; then
    dirmode="$(command -p ls -ld -- "$dir" 2>/dev/null)"; dirmode="${dirmode%% *}"
    command -p chmod -- u+w "$dir" 2>/dev/null || return 1
  fi
  tmp="$(command -p mktemp "$dir/.shmutant.XXXXXX" 2>/dev/null)" || { _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  [ -n "$(command -p tail -c 1 -- "$f" 2>/dev/null)" ] && nl=0
  # The mode comes from the `ls -l` field, the one mode read POSIX specifies the same way
  # everywhere, and is reapplied whole after the write: a read-only target (0444, 0555) must be
  # writable while awk runs, and the kernel clears setuid/setgid on write.
  mode="$(command -p ls -ld -- "$f" 2>/dev/null)"; mode="${mode%% *}"
  # cp -p first: run as root it carries the owner and group onto the temp file, which mktemp
  # created as root; the mode is reapplied whole after the write regardless.
  { command -p cp -p -- "$f" "$tmp" && command -p chmod -- u+w "$tmp" && SHMUTANT_MUT_OLD="$2" SHMUTANT_MUT_NEW="$3" SHMUTANT_MUT_NL="$nl" command -p awk '
    BEGIN { old = ENVIRON["SHMUTANT_MUT_OLD"]; new = ENVIRON["SHMUTANT_MUT_NEW"] }
    !hit { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); hit = 1 } }
    NR > 1 { printf "\n" }
    { printf "%s", $0 }
    END { if (NR > 0 && ENVIRON["SHMUTANT_MUT_NL"] == 1) printf "\n"; exit (hit ? 0 : 3) }
  ' "$f" >| "$tmp"; } 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    3) command -p rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 2 ;;
    *) command -p rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1 ;;
  esac
  command -p chmod -- "$(_shmutant_mode_spec "$mode")" "$tmp" 2>/dev/null || { command -p rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  command -p mv -f "$tmp" "$f" 2>/dev/null || { command -p rm -f "$tmp"; _shmutant_mutate_restore "$dir" "$dirmode"; return 1; }
  # The rewrite is in place; a directory mode that could not be restored is still a failure,
  # since mutate promises to leave the tree's metadata as it found it.
  _shmutant_mutate_restore "$dir" "$dirmode" || return 1
  return 0
}

# _shmutant_starts <file> <literal> — print how many positions <literal> starts at in <file>, 0, 1
# or 2 (two meaning two or more: counting stops there, so a long line of repeats costs no more
# than two matches), overlapping starts included (`aa` starts twice in `aaa`), matched line by line
# as shmutant_mutate matches it: awk's index(), the literal through ENVIRON. Fails, printing
# nothing usable, when <file> cannot be read: a read that failed must never count as no match.
_shmutant_starts() {
  SHMUTANT_MUT_OLD="$2" command -p awk '
    BEGIN { old = ENVIRON["SHMUTANT_MUT_OLD"]; n = 0; if (old == "") exit }
    { s = $0; while ((i = index(s, old)) > 0) { if (++n > 1) exit; s = substr(s, i + 1) } }
    END { print n }
  ' "$1" 2>/dev/null
}

# shmutant_target <file> — the tree-relative file that rows appended after this call mutate.
shmutant_target() {
  _shmutant_decl_writable target || return 2
  [ "$#" -eq 1 ] || { _shmutant_refuse "target: exactly one file, got $# arguments — an unquoted path?"; return 2; }
  [ -n "$1" ] || { _shmutant_refuse "target: a file is required"; return 2; }
  case "$1" in /*) _shmutant_refuse "target: must be relative to the tree root: $1"; return 2 ;; esac
  case "/$1/" in */../*) _shmutant_refuse "target: a .. component could leave the tree: $1"; return 2 ;; esac
  case "$1" in *$'\n'*) _shmutant_refuse "target: a path containing a newline is refused: the check of its directory would see the sibling"; return 2 ;; esac
  SHMUTANT_TARGET="$1"
}

# shmutant_mut <name> <old> <new> <witness> [select] — append one row for the current target.
# <old> and <new> are literals; <old> may start at no more than one position in the target, which
# the pool checks against the prepared tree when it starts (none at all is scored unapplied).
# <witness> is the text a red line must carry. <select> is what `run` receives to narrow the
# suite; it defaults to <witness>.
shmutant_mut() {
  _shmutant_decl_writable mut || return 2
  if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then _shmutant_refuse "mut: usage: shmutant_mut <name> <old> <new> <witness> [select] (got $# arguments — an unquoted witness?)"; return 2; fi
  [ -n "$SHMUTANT_TARGET" ] || { _shmutant_refuse "mut '$1': no target — call shmutant_target first"; return 2; }
  [ -n "$1" ] || { _shmutant_refuse "mut: a row needs a name"; return 2; }
  [ -n "$2" ] || { _shmutant_refuse "mut '$1': the old literal is empty — it would match nothing"; return 2; }
  [ "$2" != "$3" ] || { _shmutant_refuse "mut '$1': old and new are identical — the row would inject nothing"; return 2; }
  [ -n "$4" ] || { _shmutant_refuse "mut '$1': a row needs a witness"; return 2; }
  case "$4${5:-}" in *$'\n'*) _shmutant_refuse "mut '$1': a witness or selector cannot contain a newline — a red line is one line"; return 2 ;; esac
  case "$2" in *$'\n'*) _shmutant_refuse "mut '$1': the old literal cannot contain a newline — a literal is matched within one line"; return 2 ;; esac
  SHMUTANT_ROWS_NAME+=("$1"); SHMUTANT_ROWS_FILE+=("$SHMUTANT_TARGET"); SHMUTANT_ROWS_OLD+=("$2")
  SHMUTANT_ROWS_NEW+=("$3"); SHMUTANT_ROWS_WIT+=("$4"); SHMUTANT_ROWS_SEL+=("${5:-$4}")
}

# shmutant_refuse <reason> — refuse a declaration the plan checked itself (a witness its selection
# could never show, say): report <reason>, count it as a refused declaration, so that the pool
# exits 2 before anything runs, and return 2, as a refused shmutant_mut does. Every call refuses,
# a call without one non-empty reason included. The count lives in the calling shell: call it
# while the plan loads or from prepare, never from a subshell, a command substitution or run,
# whose count the pool never reads.
shmutant_refuse() {
  _shmutant_decl_writable refuse || return 2
  if [ "$#" -ne 1 ] || [ -z "$1" ]; then _shmutant_refuse "refuse: usage: shmutant_refuse <reason> (got $# arguments) — refused all the same"; return 2; fi
  _shmutant_refuse "refused: $1"
}

# shmutant_reset — empty the table, forget the current target and the refusals counted so far
# (shmutant_refuse's included).
shmutant_reset() {
  _shmutant_decl_writable reset || return 2
  SHMUTANT_ROWS_NAME=(); SHMUTANT_ROWS_FILE=(); SHMUTANT_ROWS_OLD=(); SHMUTANT_ROWS_NEW=()
  SHMUTANT_ROWS_WIT=(); SHMUTANT_ROWS_SEL=()
  SHMUTANT_TARGET=""
  SHMUTANT_DECL_ERRORS=0
}

# _shmutant_scan_output <fd> <prefix> <witness> — read the run's captured output once through
# <fd>, streaming, and set SHMUTANT_RUN_RED (some line starts with <prefix>) and
# SHMUTANT_RUN_WITNESSED (some such line also carries <witness> as a whole token; never with an
# empty witness). SHMUTANT_RUN_SCAN_FAILED=1 when the scan produced no result: that run is not
# green, it is unassessed.
# Per line, so a witness cannot match across a passing assertion's echo; literal matches, not
# patterns. A token: the character before and after the witness, where there is one, is ASCII
# whitespace or punctuation other than `_`, `-` and `.`; letters, digits and every non-ASCII
# character (in any locale, byte- or character-based awk) extend the witness and do not carry it.
# The text is never held whole: a run that printed until its deadline is scanned in constant memory.
_shmutant_scan_output() {
  local got
  SHMUTANT_RUN_RED=0; SHMUTANT_RUN_WITNESSED=0; SHMUTANT_RUN_SCAN_FAILED=0
  # Through ENVIRON, never -v: awk would read a backslash escape in the prefix or witness.
  got="$(SHMUTANT_SCAN_P="$2" SHMUTANT_SCAN_W="$3" command -p awk '
    function boundary(c) { return c == "" || index(SEP, c) > 0 }
    function witnessed(s, w,   i, off, pre, post) {
      off = 1
      while ((i = index(substr(s, off), w)) > 0) {
        i += off - 1
        pre = (i > 1) ? substr(s, i - 1, 1) : ""; post = substr(s, i + length(w), 1)
        if (boundary(pre) && boundary(post)) return 1
        off = i + 1
      }
      return 0
    }
    BEGIN { p = ENVIRON["SHMUTANT_SCAN_P"]; w = ENVIRON["SHMUTANT_SCAN_W"] }
    BEGIN { SEP = " \t\r\f\v!\"#$%&" sprintf("%c", 39) "()*+,/:;<=>?@[\\]^`{|}~" }
    index($0, p) == 1 { red = 1; if (w != "" && witnessed(substr($0, length(p) + 1), w)) { wit = 1; exit } }
    END { print red + 0, wit + 0 }' <&"$1" 2>/dev/null)"
  case "$got" in
    "1 1") SHMUTANT_RUN_RED=1; SHMUTANT_RUN_WITNESSED=1 ;;
    "1 0") SHMUTANT_RUN_RED=1 ;;
    "0 0") ;;
    *) SHMUTANT_RUN_SCAN_FAILED=1 ;;
  esac
}

# _shmutant_descendants <pid> — print every descendant pid of <pid>, via POSIX `ps -A -o pid= -o ppid=`.
# Prints nothing when ps is unavailable; the process-group kill still applies then.
_shmutant_descendants() {
  local table
  table="$(command -p ps -A -o pid= -o ppid= 2>/dev/null)" || return 0
  printf '%s\n' "$table" | command -p awk -v root="$1" '
    { child[NR] = $1; parent[NR] = $2 }
    END {
      want[root] = 1
      do {
        added = 0
        for (i = 1; i <= NR; i++) if ((parent[i] in want) && !(child[i] in want)) { want[child[i]] = 1; added = 1 }
      } while (added)
      for (p in want) if (p != root) print p
    }'
}

# _shmutant_proc_table — one line per process from /proc, `pid ppid starttime`. Each stat file is
# one record: grep prefixes every line with its file name (a comm holding a newline spans lines,
# and the pid comes from the name, never from the content), and the fields are taken after the
# LAST `)` (a comm may hold one). A file gone between the glob and the read is skipped, not
# fatal. Globbed with the caller's options neutralised.
_shmutant_proc_table() {
  ( set +f; shopt -u failglob nullglob; unset GLOBIGNORE; command -p grep '' /proc/[0-9]*/stat 2>/dev/null ) | command -p awk '
    function flush(   pid, s, k, n, a) {
      if (cur == "") return
      pid = cur; sub(/^\/proc\//, "", pid); sub(/\/stat$/, "", pid)
      if (pid !~ /^[0-9]+$/) return
      s = rec
      if (index(s, ")") == 0) return
      while ((k = index(s, ")")) > 0) s = substr(s, k + 1)
      n = split(s, a, " ")
      if (n >= 20) print pid, a[2], a[20]
    }
    { p = index($0, ":"); if (p == 0) next
      f = substr($0, 1, p - 1); l = substr($0, p + 1)
      if (f != cur) { flush(); cur = f; rec = l } else rec = rec "\n" l }
    END { flush() }'
}

# _shmutant_descendants_started <pid> — print `pid start` for every descendant of <pid>, from one
# `ps -A -o pid= -o ppid= -o etime=` pass, so each is carried with the identity it had when found.
# Returns 1 when that process table cannot be read: it always lists the caller, so an empty read is
# a failed one, which a caller can then tell from a pid with no descendants (0, nothing printed).
_shmutant_descendants_started() {
  local table now
  if [ "${SHMUTANT_PROC:-}" = 1 ]; then
    table="$(_shmutant_proc_table)"; [ -n "$table" ] || return 1
    printf '%s\n' "$table" | command -p awk -v root="$1" '
      { i++; child[i] = $1; parent[i] = $2; start[i] = $3 }
      END {
        want[root] = 1
        do {
          added = 0
          for (j = 1; j <= i; j++) if ((parent[j] in want) && !(child[j] in want)) { want[child[j]] = 1; added = 1 }
        } while (added)
        for (j = 1; j <= i; j++) if ((child[j] in want) && child[j] != root) print child[j], start[j]
      }'
    return 0
  fi
  if [ "${SHMUTANT_PS_LSTART:-}" != 0 ] && _shmutant_identity "$$" > /dev/null && [ "${SHMUTANT_PS_LSTART:-}" = 1 ]; then
    table="$(command -p ps -A -o pid= -o ppid= -o lstart= 2>/dev/null)" && [ -n "$table" ] || return 1
    printf '%s\n' "$table" | command -p awk -v root="$1" '
      NF > 2 && $1 ~ /^[0-9]+$/ { i++; child[i] = $1; parent[i] = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); start[i] = $0 }
      END {
        want[root] = 1
        do {
          added = 0
          for (j = 1; j <= i; j++) if ((parent[j] in want) && !(child[j] in want)) { want[child[j]] = 1; added = 1 }
        } while (added)
        for (j = 1; j <= i; j++) if ((child[j] in want) && child[j] != root) print child[j], start[j]
      }'
    return 0
  fi
  table="$(command -p ps -A -o pid= -o ppid= -o etime= 2>/dev/null)" && [ -n "$table" ] || return 1
  now="$(_shmutant_now)"; now=$(( now / 1000000 ))
  printf '%s\n' "$table" | command -p awk -v root="$1" -v now="$now" '
    NF == 3 && $1 ~ /^[0-9]+$/ {
      child[NR] = $1; parent[NR] = $2
      e = $3; d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, t, ":")
      if (n == 3) s = t[1] * 3600 + t[2] * 60 + t[3]
      else if (n == 2) s = t[1] * 60 + t[2]
      else s = t[1]
      start[NR] = "e" (now - (d * 86400 + s))
    }
    END {
      want[root] = 1
      do {
        added = 0
        for (i = 1; i <= NR; i++) if ((parent[i] in want) && !(child[i] in want)) { want[child[i]] = 1; added = 1 }
      } while (added)
      for (i = 1; i <= NR; i++) if ((child[i] in want) && child[i] != root) print child[i], start[i]
    }'
}

# _shmutant_etime_secs <etime> — seconds from a POSIX `ps -o etime` value ([[dd-]hh:]mm:ss).
_shmutant_etime_secs() {
  local v="$1" d=0 h=0 m=0 sec=0 hms
  case "$v" in *-*) d="${v%%-*}"; v="${v#*-}" ;; esac
  hms="$v"
  case "$hms" in
    *:*:*) h="${hms%%:*}"; hms="${hms#*:}"; m="${hms%%:*}"; sec="${hms#*:}" ;;
    *:*)   m="${hms%%:*}"; sec="${hms#*:}" ;;
    *)     sec="$hms" ;;
  esac
  case "$d$h$m$sec" in *[!0-9]*|'') printf '0'; return ;; esac
  printf '%s' "$(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$sec ))"
}

# _shmutant_identity <pid> — the process start time in epoch seconds (now minus POSIX
# `ps -o etime`), or nothing for a dead pid. It is the one identity that survives what a
# daemonising descendant does to itself (setsid changes its group, exec its command line) and
# still tells a reused pid apart: the newer process started later.
_shmutant_identity() {
  local etime now lstart
  if [ "${SHMUTANT_PROC:-}" = 1 ]; then
    # The kernel's own start time in clock ticks (field 22 of /proc/<pid>/stat, after the LAST
    # `)` of the parenthesised name, which may hold a newline or a `)` of its own; the file is
    # read as one record): two processes cannot share a pid and a tick.
    etime="$(command -p awk 'BEGIN { RS = "\001" } { s = $0; while ((k = index(s, ")")) > 0) s = substr(s, k + 1); n = split(s, a, " "); if (n >= 20) print a[20] }' "/proc/$1/stat" 2>/dev/null)" || return 1
    case "$etime" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$etime"; return 0
  fi
  # The start time the kernel recorded, as ps prints it (`lstart`): a wall-clock instant fixed
  # at the fork, which a later clock step does not move — unlike `now - etime`, which shifts by
  # the step and would make a live process look reused. Where ps has no lstart, told once by
  # asking about this shell, the elapsed-time form remains.
  if [ "${SHMUTANT_PS_LSTART:-}" != 0 ]; then
    lstart="$(command -p ps -o lstart= -p "$1" 2>/dev/null | command -p awk 'NF { $1 = $1; print; exit }')"
    if [ -n "$lstart" ]; then SHMUTANT_PS_LSTART=1; printf '%s' "$lstart"; return 0; fi
    if [ "${SHMUTANT_PS_LSTART:-}" = 1 ]; then return 1; fi
    if [ -n "$(command -p ps -o lstart= -p "$$" 2>/dev/null)" ]; then SHMUTANT_PS_LSTART=1; return 1; fi
    SHMUTANT_PS_LSTART=0
  fi
  etime="$(command -p ps -o etime= -p "$1" 2>/dev/null | command -p tr -d ' ')" || return 1
  [ -n "$etime" ] || return 1
  now="$(_shmutant_now)"
  printf 'e%s' "$(( now / 1000000 - $(_shmutant_etime_secs "$etime") ))"
}

# _shmutant_identity_table — fill SHMUTANT_START[pid] with the start time of every live process
# from ONE `ps -A`. A kill that asked per pid spent longer identifying a tree than the tree's
# earliest members needed to finish.
_shmutant_identity_table() {
  local line now
  SHMUTANT_START=()
  if [ "${SHMUTANT_PROC:-}" = 1 ]; then
    while IFS= read -r line; do
      # shellcheck disable=SC2034
      [ -n "$line" ] && SHMUTANT_START["${line%% *}"]="${line#* }"
    done < <(_shmutant_proc_table | command -p awk '{ print $1, $3 }')
    return 0
  fi
  if [ "${SHMUTANT_PS_LSTART:-}" != 0 ] && _shmutant_identity "$$" > /dev/null && [ "${SHMUTANT_PS_LSTART:-}" = 1 ]; then
    while IFS= read -r line; do
      # shellcheck disable=SC2034
      [ -n "$line" ] && SHMUTANT_START["${line%% *}"]="${line#* }"
    done < <(command -p ps -A -o pid= -o lstart= 2>/dev/null | command -p awk 'NF > 1 && $1 ~ /^[0-9]+$/ { pid = $1; $1 = ""; sub(/^ +/, ""); print pid, $0 }')
    return 0
  fi
  now="$(_shmutant_now)"; now=$(( now / 1000000 ))
  # awk does the etime arithmetic for every row at once; a bash loop over the whole process
  # table took longer than the tree being frozen had left to live.
  while IFS= read -r line; do
    # shellcheck disable=SC2034
    [ -n "$line" ] && SHMUTANT_START["${line%% *}"]="${line#* }"
  done < <(command -p ps -A -o pid= -o etime= 2>/dev/null | command -p awk -v now="$now" '
    NF == 2 && $1 ~ /^[0-9]+$/ {
      e = $2; d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, t, ":")
      if (n == 3) s = t[1] * 3600 + t[2] * 60 + t[3]
      else if (n == 2) s = t[1] * 60 + t[2]
      else s = t[1]
      print $1, "e" (now - (d * 86400 + s))
    }')
}

# _shmutant_alive_since <pid> <start-seen> — true when <pid> still started when <start-seen>
# says, within the one-second resolution of etime. A reused pid started later.
_shmutant_alive_since() {
  local now
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$2" ] || return 1
  now="$(_shmutant_identity "$1")" || return 1
  _shmutant_same_start "$now" "$2"
}

# _shmutant_same_start <a> <b> — the two identities name the same start. A recorded start (a
# /proc tick, an lstart) matches exactly: a pid reused in the next tick is another process.
# Only the elapsed-time form, marked with a leading e, carries the one-second resolution of
# etime, and it matches only its own form.
_shmutant_same_start() {
  local d
  [ -n "$1" ] && [ -n "$2" ] || return 1
  case "$1" in
    e*) case "$2" in e*) ;; *) return 1 ;; esac
        case "${1#e}${2#e}" in ''|*[!0-9]*) return 1 ;; esac
        d=$(( ${1#e} - ${2#e} )); [ "$d" -ge -1 ] && [ "$d" -le 1 ] ;;
    *)  [ "$1" = "$2" ] ;;
  esac
}

# _shmutant_freeze_from — stop every descendant of the pids in `roots`, repeatedly, until a pass
# finds nothing new; appends what it stopped to `frozen`/`have`. Shares its caller's arrays.
_shmutant_freeze_from() {
  local r p new rounds=0 out
  local -a found=() pids=()
  while :; do
    new=0
    for r in "${roots[@]}"; do
      # A listing that could not be read has not reached this root's children, so the freeze is not
      # settled; on a host with no listing at all, the group is all a kill can reach.
      if ! out="$(_shmutant_descendants_started "$r")"; then
        _shmutant_can_list && SHMUTANT_FREEZE_UNSETTLED=1
        continue
      fi
      [ -n "$out" ] || continue
      mapfile -t found <<< "$out"
      pids=()
      for p in "${found[@]}"; do [ -n "$p" ] && pids+=("${p%% *}"); done
      kill -STOP "${pids[@]}" 2>/dev/null
      # Only a pid that is still the process found is recorded as frozen: one that left between
      # the listing and the stop may already be someone else's, who is let go again.
      _shmutant_frozen_only "${found[@]}"
      for p in "${SHMUTANT_FROZEN_NOW[@]}"; do
        [ -n "${have[$p]:-}" ] && continue
        have["$p"]=1; frozen+=("$p:"); roots+=("$p"); new=1
      done
    done
    rounds=$((rounds + 1))
    [ "$new" = 1 ] || break
    # A pass that still finds new processes after this many means something forks out of
    # reach; the bound is recorded, not endured in silence.
    if [ "$rounds" -ge 32 ]; then SHMUTANT_FREEZE_UNSETTLED=1; break; fi
  done
}

# _shmutant_can_list — succeeds where a process listing can be read at all: /proc, or a ps.
_shmutant_can_list() {
  [ "${SHMUTANT_PROC:-}" = 1 ] || command -p -v ps > /dev/null 2>&1
}

# _shmutant_frozen_only <pid start>… — after a bulk stop, SHMUTANT_FROZEN_NOW holds the pids
# that still carry the start time they were found with; any other was stopped by mistake and
# is continued.
_shmutant_frozen_only() {
  local p d
  local -A SHMUTANT_START=()
  SHMUTANT_FROZEN_NOW=()
  _shmutant_identity_table
  if [ "${#SHMUTANT_START[@]}" -eq 0 ]; then
    # No table at all: ps failed after the listing (a fork-bombed host). Nothing can be
    # verified, so nothing just stopped is kept stopped, and the freeze is unsettled.
    for p in "$@"; do [ -n "$p" ] && kill -CONT "${p%% *}" 2>/dev/null; done
    SHMUTANT_FREEZE_UNSETTLED=1
    return 0
  fi
  for p in "$@"; do
    [ -n "$p" ] || continue
    case "${p%% *}" in ''|*[!0-9]*) continue ;; esac
    # An entry with no start time was stopped without anything to verify it by: let go, and the
    # freeze counts as unsettled rather than pretending the pid was recorded.
    case "$p" in *' '?*) ;; *) kill -CONT "${p%% *}" 2>/dev/null; SHMUTANT_FREEZE_UNSETTLED=1; continue ;; esac
    if [ -n "${SHMUTANT_START[${p%% *}]:-}" ]; then
      if _shmutant_same_start "${SHMUTANT_START[${p%% *}]}" "${p#* }"; then
        # Still the process found, and stopped: a stop that was refused (a set-uid descendant)
        # leaves a live process the record would otherwise claim as frozen.
        if kill -STOP "${p%% *}" 2>/dev/null; then SHMUTANT_FROZEN_NOW+=("${p%% *}"); else SHMUTANT_FREEZE_UNSETTLED=1; fi
        continue
      fi
      kill -CONT "${p%% *}" 2>/dev/null
    fi
  done
}

# _shmutant_kill_tree_twice [-g <pgid>] <pid> <pids…> — end <pid>'s tree: freeze it, then KILL it. Freezing
# first is what closes the window: a snapshot taken while the tree is still forking misses
# whatever forks next, so the root is stopped, its descendants found and stopped in turn until a
# pass finds nothing new (a stopped process cannot fork), and only then is anything signalled.
# Stopping comes before anything else and in bulk: a pass that spent a `ps` per process let the
# earliest children finish before their turn. A stopped pid cannot exit, so it cannot be reused
# either, and frozen pids need no identity. There is no TERM and no grace: continuing a frozen
# tree to let it handle TERM also lets a handler that ignores it run on, and after a deadline
# nothing may run at all. <pids…> are identity-checked victims recorded earlier (the watchdog's,
# the wrapper's), frozen and searched from as well: one that still lived could otherwise fork a
# child out of reach.
_shmutant_kill_tree_twice() {
  local held=""
  if [ "${1:-}" = -g ]; then held="$2"; shift 2; fi
  local spec="$1" pid rootid p d
  local -a frozen=() roots=()
  local -A have=()
  local SHMUTANT_KILL_GROUP="" SHMUTANT_FREEZE_UNSETTLED=0
  shift
  pid="${spec%%:*}"
  # The root is stopped, searched from and later signalled by number only when it is known to
  # be the process it was: a bare pid means live at the caller's hands (stopped even when ps
  # cannot identify it); `pid:identity` carries what was captured while it lived and must still
  # match; `pid:` means reaped, whose number may already be someone else's, and neither it nor
  # the children it now has are touched.
  local root_ok=0
  if [ "$spec" = "$pid" ]; then root_ok=1
  else rootid="${spec#*:}"; [ -n "$rootid" ] && _shmutant_alive_since "$pid" "$rootid" && root_ok=1
  fi
  if [ "$root_ok" = 1 ]; then roots=("$pid")
    kill -STOP "$pid" 2>/dev/null && { frozen+=("$pid:"); have["$pid"]=1; }
  fi
  # `-g <pgid>` names a process group the caller has verified is still its own (the holder
  # that leads it is alive): the whole group is stopped now and signalled at the end, whether
  # or not the root has been reaped, ps or no ps.
  if [ -n "$held" ]; then
    kill -STOP -- -"$held" 2>/dev/null
    # The caller's holder is in that group and only blocks on a read: continued in the very next
    # command, so a freeze cut short before its KILL leaves it running to its end-of-file rather
    # than stopped where none can reach it. The caller verified it just before (_shmutant_held_group),
    # the check the group stop itself relies on; a KILL landing between these two commands still
    # leaves it stopped.
    [ -z "${holder:-}" ] || kill -CONT "$holder" 2>/dev/null
    SHMUTANT_KILL_GROUP="$held"
  fi
  # The root's tree first, before any identity work: every pass is one ps and one bulk stop.
  _shmutant_freeze_from
  # Then the retained victims that are still themselves (one table, one bulk stop), and the
  # trees below them.
  local -A SHMUTANT_START=()
  local -a stillours=()
  _shmutant_identity_table
  for p in "$@"; do
    [ -n "$p" ] || continue
    [ -n "${have[${p%%:*}]:-}" ] && continue
    case "${p%%:*}" in ''|*[!0-9]*) continue ;; esac
    [ "${p#*:}" != "$p" ] && [ -n "${p#*:}" ] || continue
    [ -n "${SHMUTANT_START[${p%%:*}]:-}" ] || continue
    _shmutant_same_start "${SHMUTANT_START[${p%%:*}]}" "${p#*:}" || continue
    have["${p%%:*}"]=1; stillours+=("${p%%:*} ${p#*:}")
  done
  if [ "${#stillours[@]}" -gt 0 ]; then
    local -a stillpids=()
    for p in "${stillours[@]}"; do stillpids+=("${p%% *}"); done
    kill -STOP "${stillpids[@]}" 2>/dev/null
    # Verified again once stopped: one that left between the table and the stop is let go.
    _shmutant_frozen_only "${stillours[@]}"
    roots=("${SHMUTANT_FROZEN_NOW[@]}")
    for p in "${SHMUTANT_FROZEN_NOW[@]}"; do frozen+=("$p:"); done
    _shmutant_freeze_from
  fi
  # An unsettled freeze is reported to the runner through the descriptor it named, since this
  # may run in the watchdog — and BEFORE the kill: the freeze is complete by now, and the kill
  # may end the wrapper this watchdog's parent is waiting on before this shell runs again.
  if [ "${SHMUTANT_FREEZE_UNSETTLED:-0}" = 1 ]; then
    if [ -n "${SHMUTANT_UNSETTLED_FD:-}" ]; then printf 'unsettled\n' >&"$SHMUTANT_UNSETTLED_FD"; fi
    if [ -n "${err_fd:-}" ]; then _shmutant_err "the process tree being ended did not settle within 32 passes" 2>&"$err_fd"; fi
  fi
  if [ "$root_ok" = 1 ]; then _shmutant_kill_tree KILL "$pid" "${frozen[@]}"
  else _shmutant_kill_tree KILL "" "${frozen[@]}"
  fi
  return 0
}

# _shmutant_kill_tree <signal> <pid> <pids…> — send <signal> to every descendant of <pid> found
# now, to each of <pids…> (the descendants found before an earlier signal, which a leader's
# death may have reparented out of reach of a fresh walk), and to the process group named by
# SHMUTANT_KILL_GROUP when set. An empty <pid> means no walk.
# <pids…> are `pid:identity` pairs recorded when each was seen (see _shmutant_identity); one that
# no longer matches is a reused pid and is left alone. `pid:` with no identity is a frozen pid.
# Every target is decided first and signalled in ONE kill: a parent signalled after its child
# has already run on past the child's death.
_shmutant_kill_tree() {
  local sig="$1" pid="$2" p
  local -a targets=() now=()
  shift 2
  # A victim with an empty identity is frozen, and a frozen pid cannot have been reused.
  for p in "$@"; do
    [ -n "$p" ] || continue
    if [ -z "${p#*:}" ]; then targets+=("${p%%:*}")
    else _shmutant_alive_since "${p%%:*}" "${p#*:}" && targets+=("${p%%:*}")
    fi
  done
  # No root (a rejected `pid:identity`, or one already reaped) means no walk: the number and
  # whatever now sits beneath it belong to someone else.
  if [ -n "$pid" ]; then
    mapfile -t now < <(_shmutant_descendants "$pid")
    for p in "${now[@]}"; do [ -n "$p" ] && targets+=("$p"); done
  fi
  # The group is the run's only while its holder lives. Checked again here: a holder continued after
  # the group stop may have read its end-of-file and gone, and a group number nothing reserves may
  # belong to someone else by now. A zombie holder still reserves it.
  if [ -n "${SHMUTANT_KILL_GROUP:-}" ] && { [ -z "${holder:-}" ] || kill -0 "$holder" 2>/dev/null; }; then
    # A live pid at that number is the holder only while it carries the holder's identity, where one
    # can be read now: the same test _shmutant_held_group applied before the stop.
    if [ -z "${holder:-}" ] || [ -z "${holderid:-}" ] || ! _shmutant_identity "$holder" > /dev/null || _shmutant_alive_since "$holder" "$holderid"; then
      targets=(-"$SHMUTANT_KILL_GROUP" "${targets[@]}")
    fi
  fi
  [ "${#targets[@]}" -gt 0 ] || return 0
  kill "-$sig" -- "${targets[@]}" 2>/dev/null
}

# _shmutant_snapshot <pid> — print `pid:identity` for every live descendant of <pid> now.
_shmutant_snapshot() {
  local p
  local -A SHMUTANT_START=()
  _shmutant_identity_table
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -n "${SHMUTANT_START[$p]:-}" ] || continue
    printf '%s:%s\n' "$p" "${SHMUTANT_START[$p]}"
  done < <(_shmutant_descendants "$1")
}

# _shmutant_run_bounded <dir> <run> <root> <select> — run the adapter with stdout+stderr in
# <dir>/output, killed as a process group after SHMUTANT_TIMEOUT seconds. Sets
# SHMUTANT_RUN_STATUS to the exit status; SHMUTANT_RUN_FIRED=1 when the bound was hit.
# Job control is switched on inside one subshell only, so the run gets its own process group
# and the whole tree it spawned dies with it. That subshell's stderr is discarded: with job
# control on, bash reports the reaped job there when the pool itself runs under `$(...)`.
_shmutant_run_bounded() {
  local dir="$1" run="$2" root="$3" sel="$4" wit="${5:-}" timeout mark fifo fd left seen outf line
  local left_w left_r seen_w seen_r fired out_w out_r out_r2 hold hold_r hp go holder holderid err_fd l kept
  local counts counts_w counts_r counts_r2
  timeout="$(_shmutant_pos_int "${SHMUTANT_TIMEOUT:-300}")" || timeout=0
  SHMUTANT_RUN_FIRED=0; SHMUTANT_RUN_RED=0; SHMUTANT_RUN_WITNESSED=0; SHMUTANT_RUN_UNSETTLED=0; SHMUTANT_RUN_PUBLISHED=1
  SHMUTANT_RUN_COUNTS=""; SHMUTANT_RUN_COUNTS_BAD=""
  # Until the runner reports its own status the run has not started: a setup failure (a channel
  # that could not be made or opened) is a harness error, never a verdict on the row.
  SHMUTANT_RUN_STATUS=127; SHMUTANT_RUN_SETUP_FAILED=1
  # Every channel to and from the run is a descriptor opened HERE, before the callback exists,
  # and never reopened by path afterwards: the run's output (written and read back through
  # descriptors; the file takes the name `output` by rename at the end), the wrapper's leftover
  # record, the watchdog's sightings (which also carry the runner's own status and an unsettled
  # freeze), the count lines (SHMUTANT_COUNTS=1 only: with the counts off a run costs no file and
  # no descriptor for them), and the timeout signal, which is a FIFO so that `read -t 0` can test
  # it without consuming it. Each regular file is a mktemp name, each FIFO a fresh mkfifo (which
  # refuses an existing entry); a callback that removes, locks or symlinks any name afterwards
  # changes nothing.
  mark="$(command -p mktemp "$dir/.run.XXXXXX")" || return 0
  left="$(command -p mktemp "$dir/.left.XXXXXX")" || { command -p rm -f -- "$mark"; return 0; }
  seen="$(command -p mktemp "$dir/.seen.XXXXXX")" || { command -p rm -f -- "$mark" "$left"; return 0; }
  outf="$(command -p mktemp "$dir/.output.XXXXXX")" || { command -p rm -f -- "$mark" "$left" "$seen"; return 0; }
  counts=""; counts_w=""; counts_r=""; counts_r2=""
  [ "${SHMUTANT_COUNTS:-0}" != 1 ] || counts="$(command -p mktemp "$dir/.counts.XXXXXX")" || { command -p rm -f -- "$mark" "$left" "$seen" "$outf"; return 0; }
  fifo="$mark.fired"
  { command -p mkfifo -- "$fifo" "$mark.hold" "$mark.hp" "$mark.go"; } 2>/dev/null \
    || { command -p rm -f -- "$mark" "$left" "$seen" "$outf" ${counts:+"$counts"} "$fifo" "$mark.hold" "$mark.hp" "$mark.go"; return 0; }
  if ! exec {left_w}>|"$left" {left_r}<"$left" {seen_w}>|"$seen" {seen_r}<"$seen" {fired}<>"$fifo" {out_w}>|"$outf" {out_r}<"$outf" {out_r2}<"$outf" {hold}<>"$mark.hold" {hold_r}<"$mark.hold" {hp}<>"$mark.hp" {go}<>"$mark.go" {err_fd}>&2; then
    # A partial open (a descriptor limit) is a setup failure, not a run: close what did open.
    for fd in "${left_w:-}" "${left_r:-}" "${seen_w:-}" "${seen_r:-}" "${fired:-}" "${out_w:-}" "${out_r:-}" "${out_r2:-}" "${hold:-}" "${hold_r:-}" "${hp:-}" "${go:-}" "${err_fd:-}"; do [ -n "$fd" ] && exec {fd}>&-; done
    command -p rm -f -- "$mark" "$left" "$seen" "$outf" ${counts:+"$counts"} "$fifo" "$mark.hold" "$mark.hp" "$mark.go"; return 0
  fi
  # The count lines are appended (>>): each write lands at the end, so parallel writers never
  # overwrite one another. A line is whole only if one write carries it: lines interleaved from
  # parallel writers are corrupt, and not always detectably. A failed open is the same setup
  # failure as above.
  if [ -n "$counts" ] && ! exec {counts_w}>>"$counts" {counts_r}<"$counts" {counts_r2}<"$counts"; then
    for fd in "${left_w:-}" "${left_r:-}" "${seen_w:-}" "${seen_r:-}" "${fired:-}" "${out_w:-}" "${out_r:-}" "${out_r2:-}" "${counts_w:-}" "${counts_r:-}" "${counts_r2:-}" "${hold:-}" "${hold_r:-}" "${hp:-}" "${go:-}" "${err_fd:-}"; do [ -n "$fd" ] && exec {fd}>&-; done
    command -p rm -f -- "$mark" "$left" "$seen" "$outf" "$counts" "$fifo" "$mark.hold" "$mark.hp" "$mark.go"; return 0
  fi
  # The capture too has no name while the run executes: it is read back through one descriptor
  # for the verdict and copied out through another for the artifact afterwards. A name that
  # cannot be removed is a setup failure: the callback could reopen the channel by it.
  if ! command -p rm -f -- "$outf" ${counts:+"$counts"} "$mark" "$left" "$seen" "$fifo" "$mark.hold" "$mark.hp" "$mark.go" 2>/dev/null; then
    exec {left_w}>&- {left_r}<&- {seen_w}>&- {seen_r}<&- {fired}<&- {out_w}>&- {out_r}<&- {out_r2}<&- {hold}<&- {hold_r}<&- {hp}<&- {go}<&- {err_fd}>&-
    [ -z "$counts_w" ] || exec {counts_w}>&- {counts_r}<&- {counts_r2}<&-
    return 0
  fi
  # An unsettled freeze, from this shell or the watchdog, is reported on the sightings channel.
  local SHMUTANT_UNSETTLED_FD="$seen_w"
  (
    set -m
    # The snapshot is an EXIT trap of the wrapper, so it runs however the callback ends: a
    # callback that turned errexit on and failed would otherwise leave without it. A callback
    # that dropped the trap is still recorded on return, and on `exit`, which the wrapper
    # shadows with a function that snapshots first.
    # The wrapper's first act starts a holder: a member of the wrapper's process group, blocked
    # on a FIFO nothing writes until the cleanup is over, whose pid is reported before the
    # callback starts. It is a grandchild, not a job of the wrapper: a callback's bare `wait`
    # would otherwise block on it. While it lives the group exists and its number cannot be reused, so the group can
    # be stopped and killed by number after the wrapper has been reaped, with or without ps;
    # every such kill first checks the holder is still there. (Not a pipeline led by the holder:
    # `wait` on one member of a job waits for the whole job.)
    # The holder reads a read-only descriptor and closes the writing end it inherits: it is
    # reparented at birth, so no tree walk reaches it, and a run killed before the release below
    # would otherwise leave it blocked for good. It ends once nothing of the run holds a writer.
    # A bare `exit` keeps the status it would have had: the snapshot runs first and must not
    # replace it.
    ( _shmutant_wrap_left="$left_w"
      ( ( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {hold}>&- & printf '%s\n' "$!" >&"$hp" )
      # No plan code until the runner has published this run's group and holder for the abort
      # path: an interrupt before that would find a run it could not name.
      read -t 30 -r _ <&"$go" || builtin exit 127
      trap '_shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"' EXIT
      exit() { local s=$?; _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; if [ "$#" -eq 0 ]; then builtin exit "$s"; else builtin exit "$@"; fi; }
      # The counter describes this run: what the sourcing shell counted before the pool is not
      # this callback's, and a suite that refuses to pass on zero must be able to see zero.
      # The count descriptor is this run's own, by number; with the counts off there is none, so
      # a value an outer pool exported does not reach the callback.
      if [ "${SHMUTANT_COUNTS:-0}" = 1 ]; then export SHMUTANT_COUNTS_FD="$counts_w"; else unset SHMUTANT_COUNTS_FD; fi
      SHMUTANT_SELECTED_N=0; export SHMUTANT_SELECT="$sel"; "$run" "$root" "$sel"; rrc=$?
      _shmutant_snapshot "$BASHPID" >&"$_shmutant_wrap_left"; trap - EXIT; builtin exit "$rrc" ) < /dev/null >&"$out_w" 2>&1 &
    pid=$!
    # The holder's pid arrives on the FIFO, or nothing does: a wrapper that died before
    # starting it ends this read when the runner's own timeout below does.
    holder=""
    read -t 30 -r holder <&"$hp" || holder=""
    case "$holder" in ''|*[!0-9]*) holder="" ;; esac
    holderid="$(_shmutant_identity "$holder")" || holderid=""
    # The root's identity while it is certainly alive: the post-run kill must not stop or signal
    # a reaped root by number.
    rootid="$(_shmutant_identity "$pid")" || rootid=""
    [ -z "${SHMUTANT_VERDICT_FD:-}" ] || { printf 'group %s %s %s\n' "$pid" "$holder" "$holderid" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
    printf 'go\n' >&"$go"
    dog=""
    # With or without a deadline: the descendants a run leaves behind are otherwise seen only
    # at its return, and one that reparented out of the group by then is out of reach.
    {
      (
        # Descendants are snapshotted every half second while the run is alive, so one that
        # detaches from the leader before the deadline (a new session, a reparented child) is
        # still named at the kill. A double fork whose intermediate lives less than a poll is
        # not reachable this way; that needs a containment mechanism this file does not use.
        # Cancelled (the run returned): what was seen is left for the runner, which still has
        # to clean up whatever the callback left behind.
        trap 'kill "$s" 2>/dev/null; for p in "${!seen[@]}"; do printf "%s:%s\n" "$p" "${seen[$p]}"; done >&"$seen_w"; exit 0' TERM
        declare -A seen=(); tampered=0
        # The deadline is elapsed time as this loop sees it, one poll at a time, each poll's
        # share clamped to [its own sleep, 5 s]: a clock set back cannot extend the run (a poll
        # counts at least the half second it slept) and one set forward cannot cut it by more
        # than one poll's cap. Not a poll count: under load a poll takes longer than its sleep,
        # and a count would stretch the bound with the host. 10#: a validated value like 08 is
        # still octal to bash arithmetic.
        budget=$(( 10#$timeout * 1000000 )); elapsed=0; last=$(_shmutant_now)
        while [ "$timeout" -eq 0 ] || [ "$elapsed" -lt "$budget" ]; do
          command -p sleep 0.5 & s=$!
          wait "$s"
          # cleared once reaped: a TERM later in this poll must not signal a number reused since
          s=""
          tnow=$(_shmutant_now); d=$(( tnow - last )); last=$tnow
          [ "$d" -lt 500000 ] && d=500000
          [ "$d" -gt 5000000 ] && d=5000000
          elapsed=$(( elapsed + d ))
          # Each descendant is remembered with the identity it had when first seen, so a pid
          # reused by a newer process can be told apart at the kill.
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ -n "${seen[${p%%:*}]:-}" ] && continue
            seen["${p%%:*}"]="${p#*:}"
          done < <(_shmutant_snapshot "$pid")
          # The target too, on every pass: a rewrite put back before the run returns would pass
          # the check made afterwards; one that lasts a poll or more is seen here.
          if [ -n "${SHMUTANT_TARGET_CK:-}" ] && [ "$tampered" = 0 ]; then
            [ "$(_shmutant_target_ck "$dir" "$SHMUTANT_TARGET_REL" "$SHMUTANT_TARGET_KEY")" = "$SHMUTANT_TARGET_CK" ] || { tampered=1; printf 'tampered\n' >&"$seen_w"; }
          fi
        done
        # Committed: a TERM from the runner (which may have seen the run return in the same
        # instant) must not stop the freeze halfway and leave stopped processes behind.
        trap '' TERM
        printf 'fired\n' >&"$fired"
        # What was still there at the deadline, for the record: a run that hangs is diagnosed
        # from this list, not from an output that stopped.
        { printf 'shmutant: %s: still running at the deadline (pid ppid stat args):\n' "$dir"
          command -p ps -o pid= -o ppid= -o stat= -o args= -p "$(IFS=,; printf '%s' "$pid,${!seen[*]}")" 2>/dev/null | command -p head -n 30 | command -p cut -c1-200
        } 1>&"$err_fd" 2>/dev/null
        # An array of pid:identity pairs, never an unquoted expansion.
        victims=()
        for p in "${!seen[@]}"; do victims+=("$p:${seen[$p]}"); done
        _shmutant_held_group "$pid"; _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" "${victims[@]}"
      ) < /dev/null > /dev/null 2>&1 &
      dog=$!
    }
    if [ -n "$dog" ]; then
      # Whichever ends first. A watchdog that ends before the leader has fired and failed to
      # finish (or died): the leader may be frozen, and waiting on it would never return, so
      # the kill is completed here and the run scored as a timeout.
      wait -n -p done_first "$pid" "$dog"; rc=$?
      if [ "${done_first:-}" != "$pid" ]; then
        read -t 0 -u "$fired" || printf 'fired\n' >&"$fired"
        _shmutant_held_group "$pid"; _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid"
        # Whatever the tree walk and the group reached, the wrapper itself is this shell's own
        # unreaped child: ended by number, so the wait below returns even with no ps and no holder.
        kill -KILL "$pid" 2>/dev/null
        wait "$pid"; rc=$?
      else
        # Once the watchdog has fired, let it reach KILL; otherwise cancel it.
        read -t 0 -u "$fired" || kill -TERM "$dog" 2>/dev/null
        wait "$dog" 2>/dev/null
      fi
    else
      wait "$pid"; rc=$?
    fi
    if ! read -t 0 -u "$fired"; then
      # The callback returned, which says nothing about what it backgrounded: its process group
      # and every descendant the watchdog saw are ended before the verdict is accepted.
      leftovers=()
      mapfile -t leftovers <&"$left_r"
      mapfile -t -O "${#leftovers[@]}" leftovers <&"$seen_r"
      # The sightings channel also carries the watchdog's notes (a target it found changed):
      # those are not pids, and go back on the channel for the reader below, which shares this
      # descriptor's offset and would otherwise never see them.
      kept=()
      for l in "${leftovers[@]}"; do case "$l" in tampered|unsettled) printf '%s\n' "$l" >&"$seen_w" ;; *) kept+=("$l") ;; esac; done
      leftovers=("${kept[@]}")
      _shmutant_held_group "$pid"
      [ "${#SHMUTANT_HELD[@]}" -gt 0 ] || _shmutant_err "the run's process group could not be verified as its own; what it left behind is not signalled by number" 2>&"$err_fd"
      _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$pid:$rootid" "${leftovers[@]}"
    fi
    # Release a holder the group kill did not reach.
    printf 'x\n' >&"$hold"
    # The status travels on the sightings channel: a runner that never got this far (it could
    # not be started) leaves none, and the run is then a setup failure, never a pass.
    printf 'status %s\n' "$rc" >&"$seen_w"
    exit "$rc"
  ) 2> /dev/null
  read -t 0 -u "$fired" && SHMUTANT_RUN_FIRED=1
  while IFS= read -r line <&"$seen_r"; do
    case "$line" in
      "status "*) case "${line#status }" in ''|*[!0-9]*) ;; *) SHMUTANT_RUN_STATUS="${line#status }"; SHMUTANT_RUN_SETUP_FAILED=0 ;; esac ;;
      unsettled)  SHMUTANT_RUN_UNSETTLED=1 ;;
      tampered)   SHMUTANT_RUN_TAMPERED=1 ;;
    esac
  done
  _shmutant_scan_output "$out_r" "${SHMUTANT_RED_PREFIX:-FAIL: }" "$wit"
  # An output the scan could not read is not a green run: the row is a harness error.
  [ "${SHMUTANT_RUN_SCAN_FAILED:-0}" = 0 ] || SHMUTANT_RUN_SETUP_FAILED=1
  [ "${SHMUTANT_COUNTS:-0}" != 1 ] || _shmutant_read_counts "$counts_r" "$counts_r2"
  # The capture takes its documented name by rename: a symlink a callback planted there is
  # replaced, never written through.
  # A directory planted there would make mv publish INTO it: it goes first, and the result is
  # checked to be the capture itself.
  # The directory is this run's; a callback that made it unwritable does not get to keep the
  # capture from its name. A capture that still cannot be published is a harness error.
  # Only into the directory this run created, by inode: nothing is changed, removed or renamed
  # beneath a replacement a callback put at the name. The artifact is materialised from the
  # capture's descriptor into a fresh mktemp file and renamed over the documented name.
  SHMUTANT_RUN_PUBLISHED=1
  if [ -L "$dir" ] || { [ -n "${SHMUTANT_DIR_ID:-}" ] && [ "$(_shmutant_dir_id "$dir")" != "$SHMUTANT_DIR_ID" ]; }; then
    SHMUTANT_RUN_PUBLISHED=0
  else
    [ -w "$dir" ] || command -p chmod -- u+rwx "$dir" 2>/dev/null
    [ -d "$dir/output" ] && [ ! -L "$dir/output" ] && command -p rm -rf -- "$dir/output" 2>/dev/null
    if outf="$(command -p mktemp "$dir/.output.XXXXXX" 2>/dev/null)" && command -p cat <&"$out_r2" >| "$outf" 2>/dev/null \
      && command -p mv -f -- "$outf" "$dir/output" 2>/dev/null && [ -f "$dir/output" ] && [ ! -L "$dir/output" ]; then :
    else
      [ -n "${outf:-}" ] && command -p rm -f -- "$outf"
      SHMUTANT_RUN_PUBLISHED=0
    fi
  fi
  exec {left_w}>&- {left_r}<&- {seen_w}>&- {seen_r}<&- {fired}<&- {out_w}>&- {out_r}<&- {out_r2}<&- {hold}<&- {hold_r}<&- {hp}<&- {go}<&- {err_fd}>&-
  [ -z "$counts_w" ] || exec {counts_w}>&- {counts_r}<&- {counts_r2}<&-
}

# _shmutant_read_counts <fd> <fd2> — read a run's count lines through <fd>, once, streaming, after
# checking through <fd2>, a second descriptor on the same file, that they hold no NUL byte. Sets
# SHMUTANT_RUN_COUNTS to one `<unit>\t<n>` line per unit, in the order first reported, the counts of
# a unit reported more than once summed (a Bats test name may recur across files, and every run
# that selects one runs them all); or SHMUTANT_RUN_COUNTS_BAD to why the lines cannot be used: one
# that is not <unit><TAB><digits> (a unit that is empty or holds a tab, a count past
# nine digits), a unit whose total passes nine digits, or a read that failed. A last line without
# its newline is read like any other. A NUL byte anywhere refuses them all: awks differ on it (one
# keeps it, another ends the line there), and the shell drops it, so `a<NUL>b` could come back as
# unit `ab`. Totals stay within nine digits, so awk's doubles hold them exactly. The NUL count is a
# pipeline, run under pipefail: a tr that failed partway must not read as none.
_shmutant_read_counts() {
  local got nul
  if ! nul="$(set -o pipefail; command -p tr -cd '\000' <&"$2" 2>/dev/null | command -p wc -c 2>/dev/null)"; then
    SHMUTANT_RUN_COUNTS_BAD="its count lines could not be read"; return 0
  fi
  case "${nul//[[:space:]]/}" in
    0) ;;
    ''|*[!0-9]*) SHMUTANT_RUN_COUNTS_BAD="its count lines could not be read"; return 0 ;;
    *) SHMUTANT_RUN_COUNTS_BAD="its count lines hold a NUL byte, which no unit or count may hold"; return 0 ;;
  esac
  if ! got="$(command -p awk '
      BEGIN { FS = "\t"; k = 0; bad = 0 }
      NF != 2 || $1 == "" || $2 !~ /^[0-9]+$/ || length($2) > 9 { printf "\tline %d is not <unit><TAB><digits> (a unit with no tab, a count of at most nine digits)\n", NR; bad = 1; exit }
      { if (!($1 in c)) u[++k] = $1; c[$1] += $2 }
      c[$1] > 999999999 { printf "\tunit [%s] totals more than 999999999 assertions\n", $1; bad = 1; exit }
      END { if (!bad) for (j = 1; j <= k; j++) printf "%s\t%d\n", u[j], c[u[j]] }
    ' <&"$1" 2>/dev/null)"; then
    SHMUTANT_RUN_COUNTS_BAD="its count lines could not be read"; return 0
  fi
  # The refusal starts with a tab, which no unit line can: a unit is never empty.
  case "$got" in
    $'\t'*) SHMUTANT_RUN_COUNTS_BAD="${got#$'\t'}" ;;
    *)      SHMUTANT_RUN_COUNTS="$got" ;;
  esac
}

# _shmutant_count_check <k> <reference-verdict> — with SHMUTANT_COUNTS=1, why green baseline run
# base-<k> does not prove its selection whole, printed; nothing when it does. base-0 is the
# unselected run, whose settled verdict is <reference-verdict>: it must count something, and every
# other run must count each unit it reports exactly as base-0 does.
_shmutant_count_check() {
  local k="$1" d
  if [ -n "${SHMUTANT_RES_COUNTS_BAD[base-$k]:-}" ]; then builtin printf 'its count lines are unusable: %s' "${SHMUTANT_RES_COUNTS_BAD[base-$k]}"; return 0; fi
  if [ -z "${SHMUTANT_RES_COUNTS[base-$k]:-}" ]; then builtin printf 'it reported no unit on SHMUTANT_COUNTS_FD — a run that counts nothing cannot be compared'; return 0; fi
  [ "$k" -ne 0 ] || return 0
  if [ "$2" != green ]; then builtin printf 'the unselected run, the reference, is %s (see its baseline record), so no selection can be compared with it' "${2:-missing}"; return 0; fi
  d="$(_shmutant_count_diff "${SHMUTANT_RES_COUNTS[base-0]}" "${SHMUTANT_RES_COUNTS[base-$k]}")" \
    || { builtin printf 'its counts could not be compared with the unselected run'"'"'s'; return 0; }
  builtin printf '%s' "$d"
}

# _shmutant_count_diff <reference> <counts> — compare two lists of `<unit>\t<n>` lines, each unit
# once: for the first unit of <counts> whose count differs from <reference>'s, or that <reference>
# lacks, print the sentence naming it and both counts; nothing when every unit matches. Units are
# compared whole and byte for byte, as awk keys, whatever the caller's shell options; an empty
# line separates the two lists on input, and no unit line is empty. The lists reach awk as a
# here-string, not from a pipe: there is no writer whose failure awk would read as a short list
# that matches, and a redirection that cannot be made fails the call.
_shmutant_count_diff() {
  command -p awk '
    BEGIN { FS = "\t"; sep = 0; d = 0 }
    !sep && $0 == "" { sep = 1; next }
    !sep { ref[$1] = $2; next }
    !($1 in ref) || ref[$1] != $2 { if (!d) { fu = $1; fn = $2; fr = ($1 in ref) ? ref[$1] : "" }; d++ }
    END {
      if (!d) exit
      printf "unit [%s] ran %s assertion(s) here", fu, fn
      if (fr == "") printf " and is absent from the unselected run"; else printf " and %s in the unselected run", fr
      if (d > 1) printf "; %d more unit(s) differ", d - 1
    }' <<< "$1"$'\n\n'"$2"
}

# _shmutant_held_group <pgid> — set SHMUTANT_HELD to `-g <pgid>` when the run's holder is still
# the process it was (or, without ps, still there at all); to nothing when it is not, in which
# case the group is no longer known to be the run's and is not signalled by number.
# Globals: holder, holderid (set by _shmutant_run_bounded); SHMUTANT_HELD (written).
_shmutant_held_group() {
  SHMUTANT_HELD=()
  [ -n "${holder:-}" ] || return 0
  kill -0 "$holder" 2>/dev/null || return 0
  if [ -n "${holderid:-}" ]; then
    # An identity that cannot be read now, for a pid that is there, means ps broke after the
    # run started: the holder is taken as it was, as it would be with no ps at all.
    if _shmutant_identity "$holder" > /dev/null; then _shmutant_alive_since "$holder" "$holderid" || return 0; fi
  fi
  SHMUTANT_HELD=(-g "$1")
}

# _shmutant_worker_finish <dir> <verdict> <microseconds> <status> — drop the clone unless
# SHMUTANT_KEEP=1, then write the verdict. Every worker exit goes through here, so an early
# verdict cannot leave a tree behind.
_shmutant_worker_finish() {
  # Only in a directory that is still the one this run created, by inode: a callback may have
  # renamed it away and put a symlink or a fresh directory in its place, and nothing is written
  # or removed beneath a replacement.
  if [ -L "$1" ] || [ "$(_shmutant_dir_id "$1")" != "${SHMUTANT_DIR_ID:-}" ]; then
    _shmutant_err "refusing to clean $1: it is no longer the worker directory this run created"
    return 0
  fi
  # The worker directory is this run's; a callback that made it unwritable does not get to
  # suppress the verdict.
  [ -w "$1" ] || command -p chmod -- u+rwx "$1" 2>/dev/null
  # The clone's identity, kept or not: what a callback put at the path stays, and the verdict
  # of a run that renamed its clone away and put another directory there is not accepted —
  # nothing says which tree it ran against. Only the removal waits on SHMUTANT_KEEP.
  if [ -L "$1/tree" ] || { [ -e "$1/tree" ] && [ "$(_shmutant_dir_id "$1/tree")" != "${SHMUTANT_CLONE_ID:-}" ]; }; then
    _shmutant_err "$1/tree is no longer the clone this run made; the verdict of a run that swapped its tree is not accepted"
    { printf 'swapped\n' >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
    set -- "$1" unprepared "$3" swapped
  elif [ "${SHMUTANT_KEEP:-0}" != 1 ] && [ -e "$1/tree" ]; then
    _shmutant_remove "$1/tree" || _shmutant_err "could not remove $1/tree"
  fi
  # The verdict goes down the channel the pool opened for this worker before it forked, on a
  # file that no longer has a name: nothing planted in the directory can stand in for it.
  { printf 'verdict %s %s %s\n' "$2" "$3" "$4" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
  [ "${SHMUTANT_RUN_PUBLISHED:-1}" = 1 ] || { printf 'unpublished\n' >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
}

# _shmutant_worker <kind> <index> <workdir> <run> <root-suffix> — one job, start to verdict.
# <kind> is `base` (uninjected, for baseline selector <index>) or `mut` (row <index>). Clones the
# pristine tree into <workdir>/<kind>-<index>/tree, injects when <kind> is mut, runs, and writes
# `<verdict>\n<microseconds>\n<status>` to <workdir>/<kind>-<index>/verdict. Always returns 0:
# the pool reaps by pid, and a non-zero worker would be mistaken for a lost verdict.
_shmutant_worker() {
  local kind="$1" i="$2" wd="$3" run="$4" suffix="$5" target_ck="" after_ck=""
  local dir="$3/$1-$2" root sel verdict status t0 t1 target rc red
  set +e
  t0="$(_shmutant_now)"
  # The directory's identity, for a cleanup that must not be fooled by a replacement.
  SHMUTANT_DIR_ID="${SHMUTANT_DIR_IDS[$kind-$i]:-}"
  SHMUTANT_VERDICT_FD="${SHMUTANT_VERDICT_W[$kind-$i]:-}"
  [ -n "$SHMUTANT_VERDICT_FD" ] || return 0
  root="$dir/tree$suffix"
  if [ "$kind" = mut ]; then sel="${SHMUTANT_ROWS_SEL[$i]}"; else sel="${SHMUTANT_BASE_SEL[$i]}"; fi
  # -p: a clone keeps mode, ownership and timestamps, so a test sensitive to them sees the
  # prepared tree's values, not the pool's umask.
  # The clone directory is made first, by a mkdir that refuses an existing entry: a symlink a
  # sibling planted at the name would otherwise have cp copy INTO its target. The pristine tree
  # is still the one prepare built, by inode, and unmodified since prepare (a callback that wrote
  # through its tree into ../../pristine would otherwise be cloned into every later row).
  local state
  if ! state="$(_shmutant_pristine_state "$wd/pristine")" || [ "$state" != "${SHMUTANT_PRISTINE_STATE-}" ]; then
    _shmutant_worker_finish "$dir" unprepared 0 modified; return 0
  fi
  SHMUTANT_CLONE_ID=""
  if [ "$(_shmutant_dir_id "$wd/pristine")" != "${SHMUTANT_PRISTINE_ID:-}" ] || [ -L "$wd/pristine" ] \
    || ! command -p mkdir -- "$dir/tree" 2>/dev/null; then
    _shmutant_worker_finish "$dir" unprepared 0 clone; return 0
  fi
  # The clone's own identity, from the moment it exists: a callback that renames it away and
  # puts a directory of its own at the path does not get that removed.
  SHMUTANT_CLONE_ID="$(_shmutant_dir_id "$dir/tree")"
  # Published for the pool: a worker that dies leaves the clone's removal to the collector,
  # which must not remove what a callback put at the path instead.
  { printf 'clone %s\n' "$SHMUTANT_CLONE_ID" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
  if ! command -p cp -RPp -- "$wd/pristine/." "$dir/tree/" 2>/dev/null; then
    _shmutant_worker_finish "$dir" unprepared 0 clone; return 0
  fi
  # The clone's root takes the prepared root's owner, mode and mtime (cp never sets them on an
  # existing destination), and the clone itself is then checked against the recorded state: a
  # callback already running could have written into pristine between the check above and the
  # copy, or during it, and put it back before the next worker looked.
  _shmutant_apply_root_meta "$wd/pristine" "$dir/tree" || { _shmutant_worker_finish "$dir" unprepared 0 clone; return 0; }
  if ! state="$(_shmutant_pristine_state "$dir/tree")" || [ "$state" != "${SHMUTANT_PRISTINE_STATE-}" ]; then
    _shmutant_worker_finish "$dir" unprepared 0 raced; return 0
  fi
  if [ "$kind" = mut ]; then
    target="$root/${SHMUTANT_ROWS_FILE[$i]}"
    _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}" || { _shmutant_worker_finish "$dir" unprepared 0 missing; return 0; }
    # Rewritten from a working directory pinned FIRST to this worker's own directory, verified
    # by identity (a sibling's callback could have renamed it away and put another directory at
    # its path), then to the target's directory relative to that, re-checked to be inside this
    # clone physically, naming the target by its base name alone: nothing named by path after
    # the identity check can be redirected by a sibling.
    ( builtin cd -P -- "$dir" 2>/dev/null || exit 4
      [ "$(_shmutant_dir_id .)" = "${SHMUTANT_DIR_IDS[$kind-$i]:-}" ] || exit 4
      wroot="$(builtin pwd -P)"
      builtin cd -P -- "./tree$suffix/$(command -p dirname -- "${SHMUTANT_ROWS_FILE[$i]}")" 2>/dev/null || exit 4
      _shmutant_inside "$wroot/tree" "$(builtin pwd -P)" || exit 4
      base="$(command -p basename -- "$target")"
      [ ! -L "$base" ] && [ -f "$base" ] || exit 4
      shmutant_mutate "$base" "${SHMUTANT_ROWS_OLD[$i]}" "${SHMUTANT_ROWS_NEW[$i]}" ); rc=$?
    case "$rc" in
      0) ;;
      2) _shmutant_worker_finish "$dir" unapplied 0 0; return 0 ;;
      4) _shmutant_worker_finish "$dir" unprepared 0 moved; return 0 ;;
      *) _shmutant_worker_finish "$dir" unprepared 0 rewrite; return 0 ;;
    esac
    # The target as written, read from this worker's own directory: checked again after the run,
    # since a sibling's callback that put the old literal back while this run read the file
    # would otherwise have the row scored against code that was not the mutant.
    target_ck="$(_shmutant_target_ck "$dir" "tree$suffix/${SHMUTANT_ROWS_FILE[$i]}" "$kind-$i")" || { _shmutant_worker_finish "$dir" unprepared 0 rewrite; return 0; }
  fi
  SHMUTANT_RUN_TARGET_REWRITTEN=0; SHMUTANT_RUN_TAMPERED=0
  SHMUTANT_TARGET_CK="$target_ck"; SHMUTANT_TARGET_REL="tree$suffix/${SHMUTANT_ROWS_FILE[$i]:-}"; SHMUTANT_TARGET_KEY="$kind-$i"
  if [ "$kind" = mut ]; then _shmutant_run_bounded "$dir" "$run" "$root" "$sel" "${SHMUTANT_ROWS_WIT[$i]}"
  else _shmutant_run_bounded "$dir" "$run" "$root" "$sel"; fi
  if [ "$kind" = mut ] && [ "${SHMUTANT_RUN_SETUP_FAILED:-0}" = 0 ]; then
    after_ck="$(_shmutant_target_ck "$dir" "tree$suffix/${SHMUTANT_ROWS_FILE[$i]}" "$kind-$i")" || after_ck=""
    [ "$after_ck" = "$target_ck" ] && [ "${SHMUTANT_RUN_TAMPERED:-0}" = 0 ] || { SHMUTANT_RUN_SETUP_FAILED=1; SHMUTANT_RUN_TARGET_REWRITTEN=1; }
  fi
  status="$SHMUTANT_RUN_STATUS"
  t1="$(_shmutant_now)"
  if [ "${SHMUTANT_RUN_SETUP_FAILED:-0}" = 1 ]; then
    # The run never started, or its output could not be scanned: reported as such, and the
    # pool makes it a harness error.
    [ "${SHMUTANT_RUN_SCAN_FAILED:-0}" = 0 ] || _shmutant_err "$label: the run's output could not be scanned; its verdict is not trusted"
    [ "${SHMUTANT_RUN_TARGET_REWRITTEN:-0}" = 0 ] || _shmutant_err "$label: the target was not as the pool wrote it, in content or metadata, during or after the run — a callback wrote into this worker's tree; its verdict is not trusted"
    { printf 'setup-failed\n' >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
    verdict=lost
  elif [ "$SHMUTANT_RUN_UNSETTLED" = 1 ]; then
    verdict=unsettled
  elif [ "$SHMUTANT_RUN_FIRED" = 1 ]; then
    verdict=timeout
  elif [ "$kind" = base ]; then
    red="${SHMUTANT_RED_STATUS:-1}"
    # Red only with a red line, as for a row: the red status alone is a runner that aborted.
    if [ "$status" -eq 0 ]; then verdict=green
    elif [ "$status" -eq "$red" ] && [ "$SHMUTANT_RUN_RED" = 1 ]; then verdict=red
    else verdict=aborted; fi
  elif [ "$status" -eq "${SHMUTANT_RED_STATUS:-1}" ]; then
    if [ "$SHMUTANT_RUN_WITNESSED" = 1 ]; then
      verdict=killed
    elif [ "$SHMUTANT_RUN_RED" = 1 ]; then
      verdict=accidental
    else
      verdict=aborted
    fi
  elif [ "$status" -eq 0 ]; then
    verdict=survived
  else
    verdict=aborted
  fi
  # A baseline run's counts go to the pool on the verdict channel, one unit per line (a unit holds
  # no tab and no newline, so the line is unambiguous), or why they cannot be used.
  # They end with `counts-end <lines>`, which the collector requires: a write that failed partway
  # would otherwise hand the pool a subset of the units, and a unit that never arrives is never
  # compared.
  if [ "$kind" = base ] && [ "${SHMUTANT_COUNTS:-0}" = 1 ]; then
    local -a sent=()
    if [ -n "${SHMUTANT_RUN_COUNTS_BAD:-}" ]; then
      { printf 'counts-bad %s\n' "$SHMUTANT_RUN_COUNTS_BAD" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
    elif [ -n "${SHMUTANT_RUN_COUNTS:-}" ]; then
      mapfile -t sent <<< "$SHMUTANT_RUN_COUNTS"
      { printf 'count %s\n' "${sent[@]}" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
    fi
    { printf 'counts-end %s\n' "${#sent[@]}" >&"$SHMUTANT_VERDICT_FD"; } 2>/dev/null
  fi
  _shmutant_worker_finish "$dir" "$verdict" "$(( t1 - t0 ))" "$status"
  return 0
}

# _shmutant_dir_id <dir> — the inode number of <dir>, from POSIX `ls -di`; empty when absent.
_shmutant_dir_id() {
  local id phys
  id="$(command -p ls -di -- "$1" 2>/dev/null | command -p awk '{ print $1 }')"
  [ -n "$id" ] || return 0
  # The inode is unique only within a filesystem; the resolved physical path distinguishes a
  # same-inode directory reached across a swapped mount (portable, where a device number is not).
  phys="$(_shmutant_abs "$1")" || phys=""
  printf '%s:%s' "$id" "$phys"
}

# _shmutant_collect <dir> <key> <wait-status> — read a reaped worker's channel into
# SHMUTANT_RES_*[key] (and SHMUTANT_V_*): the last `verdict <v> <us> <status>` line, or `lost`
# when there is none, the line is damaged, or the worker did not exit 0. Closes the channel.
_shmutant_collect() {
  local dir="$1" key="$2" wstatus="$3" line fd unpublished=0 setup_failed=0 swapped=0 clone_id="" counts="" counts_bad="" counts_end="" counts_got=0
  SHMUTANT_V_VERDICT=lost; SHMUTANT_V_US=0; SHMUTANT_V_STATUS=""
  fd="${SHMUTANT_VERDICT_R[$key]:-}"
  if [ -n "$fd" ]; then
    # The last verdict line wins; a `group` line is the runner's, for the abort path; an
    # `unpublished` line says the documented output artifact could not be put in place.
    while IFS= read -r line <&"$fd"; do
      case "$line" in
        "verdict "*) line="${line#verdict }"
                     SHMUTANT_V_VERDICT="${line%% *}"; line="${line#* }"
                     SHMUTANT_V_US="${line%% *}"; SHMUTANT_V_STATUS="${line#* }" ;;
        "clone "*)   clone_id="${line#clone }" ;;
        unpublished) unpublished=1 ;;
        setup-failed) setup_failed=1 ;;
        swapped)     swapped=1 ;;
        "count "*)   counts+="${line#count }"$'\n'; counts_got=$((counts_got + 1)) ;;
        "counts-bad "*) counts_bad="${line#counts-bad }" ;;
        "counts-end "*) counts_end="${line#counts-end }" ;;
      esac
    done
    exec {fd}<&-
    unset "SHMUTANT_VERDICT_R[$key]"
  fi
  # A worker that did not end of its own accord (killed by a signal, by the callback or by the
  # host) has no verdict, whatever reached the channel before it died; the clone it could not
  # remove goes here, from the directory this run created.
  if [ "$wstatus" != 0 ]; then
    SHMUTANT_V_VERDICT=lost; SHMUTANT_V_US=0; SHMUTANT_V_STATUS=""
    # The identity may have been read off the channel already, by the helper that ended the worker.
    [ -n "$clone_id" ] || clone_id="${SHMUTANT_RES_CLONE[$key]:-}"
    if [ "${SHMUTANT_KEEP:-0}" != 1 ] && [ ! -L "$dir" ] && [ "$(_shmutant_dir_id "$dir")" = "${SHMUTANT_DIR_IDS[$key]:-}" ]; then
      # Only the clone the worker made, by the identity it published; what a callback put at
      # the path stays, and the pool then finds a tree left behind (a harness error).
      if [ ! -e "$dir/tree" ] && [ ! -L "$dir/tree" ]; then :
      elif [ -L "$dir/tree" ] || [ -z "$clone_id" ] || [ "$(_shmutant_dir_id "$dir/tree")" != "$clone_id" ]; then _shmutant_err "refusing to remove $dir/tree: it is not the clone its worker made"
      else _shmutant_remove "$dir/tree" "$dir" 2>/dev/null || true
      fi
    fi
  fi
  [ -n "$SHMUTANT_V_VERDICT" ] || SHMUTANT_V_VERDICT=lost
  _shmutant_pos_int "$SHMUTANT_V_US" > /dev/null || SHMUTANT_V_US=0
  SHMUTANT_RES_VERDICT["$key"]="$SHMUTANT_V_VERDICT"; SHMUTANT_RES_US["$key"]="$SHMUTANT_V_US"; SHMUTANT_RES_STATUS["$key"]="$SHMUTANT_V_STATUS"
  # A baseline's counts are whole only up to its end marker: a worker whose writes failed partway
  # would otherwise have the pool compare the units that happened to arrive.
  case "$key" in
    base-*) if [ "${SHMUTANT_COUNTS:-0}" = 1 ] && [ -z "$counts_bad" ] && [ "$counts_end" != "$counts_got" ]; then
              counts_bad="its count lines did not all reach the pool (${counts_end:-no end marker} sent, $counts_got received)"
            fi ;;
  esac
  SHMUTANT_RES_COUNTS["$key"]="${counts%$'\n'}"; SHMUTANT_RES_COUNTS_BAD["$key"]="$counts_bad"
  if [ "$setup_failed" = 1 ]; then
    _shmutant_err "$dir: the run could not be set up (a channel could not be made or opened) — the row was never run"; SHMUTANT_CLEANUP_FAILED=1
  fi
  if [ "$unpublished" = 1 ]; then
    _shmutant_err "$dir/output could not be published — the documented artifact of this run is missing"; SHMUTANT_CLEANUP_FAILED=1
  fi
  # A run that swapped its clone is a harness error whether or not the tree was kept: with
  # SHMUTANT_KEEP=1 nothing is left behind to find, so the worker's own report decides.
  if [ "$swapped" = 1 ]; then
    _shmutant_err "$dir/tree is not the clone its worker made — the run's verdict is not accepted"; SHMUTANT_CLEANUP_FAILED=1
  fi
  # A clone the worker did not remove is a harness error, whatever it reported: the next run
  # in this workdir would find it. Only the directory the pool created is looked at, by inode.
  if [ -L "$dir" ] || [ "$(_shmutant_dir_id "$dir")" != "${SHMUTANT_DIR_IDS[$key]:-}" ]; then
    _shmutant_err "$dir is no longer the directory this run created"; SHMUTANT_CLEANUP_FAILED=1
  elif [ "${SHMUTANT_KEEP:-0}" != 1 ] && { [ -e "$dir/tree" ] || [ -L "$dir/tree" ]; }; then
    _shmutant_err "$dir/tree was not removed"; SHMUTANT_CLEANUP_FAILED=1
  fi
}

# _shmutant_open_channel <workdir> <key> — a descriptor pair on an unlinked file under <workdir>,
# the worker's write end in SHMUTANT_VERDICT_W[key] and the pool's read end in
# SHMUTANT_VERDICT_R[key]. False when it cannot be made.
_shmutant_open_channel() {
  local f vw vr
  f="$(command -p mktemp "$1/$2/.channel.XXXXXX" 2>/dev/null)" || return 1
  if ! exec {vw}>|"$f" {vr}<"$f"; then
    command -p rm -f -- "$f"; [ -n "${vw:-}" ] && exec {vw}>&-; return 1
  fi
  command -p rm -f -- "$f"
  SHMUTANT_VERDICT_W["$2"]="$vw"; SHMUTANT_VERDICT_R["$2"]="$vr"
}

# _shmutant_end_workers <pid>… — end the trees of running workers: each run's process group by
# number, through the group and holder the runner reported on its channel (so no ps is needed),
# then the worker itself.
_shmutant_end_workers() {
  local p key line holder holderid grp fd
  local -a helpers=()
  for p in "$@"; do
    key="${SHMUTANT_ACTIVE_KEY[$p]:-}"; holder=""; holderid=""; grp=""
    fd="${SHMUTANT_VERDICT_R[$key]:-}"
    if [ -n "$fd" ]; then
      # This read moves the descriptor's shared offset past everything the worker wrote: what
      # the collector will still need from the channel (the clone's identity) is kept for it.
      while IFS= read -r line <&"$fd"; do
        case "$line" in
          "group "*) line="${line#group }"; grp="${line%% *}"; line="${line#* }"; holder="${line%% *}"; holderid="${line#* }" ;;
          "clone "*) SHMUTANT_RES_CLONE["$key"]="${line#clone }" ;;
        esac
      done
    fi
    SHMUTANT_HELD=()
    [ -n "$grp" ] && _shmutant_held_group "$grp"
    if [ -n "${SHMUTANT_ACTIVE_ID[$p]:-}" ]; then _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$p:${SHMUTANT_ACTIVE_ID[$p]}" & helpers+=("$!")
    else _shmutant_kill_tree_twice "${SHMUTANT_HELD[@]}" "$p" & helpers+=("$!")
    fi
  done
  [ "${#helpers[@]}" -eq 0 ] || wait "${helpers[@]}" 2>/dev/null
}

# _shmutant_detail <verdict> <status> <witness> <select> — the human sentence for a row verdict.
_shmutant_detail() {
  case "$1" in
    killed)     printf 'went red on its witness' ;;
    survived)   printf 'stayed GREEN (exit 0) — nothing selected by [%s] can detect this defect' "$4" ;;
    accidental) printf 'went red, but NOT on its witness [%s] — caught by accident, not by the assertion that claims to cover it' "$3" ;;
    aborted)    if [ "$2" = "${SHMUTANT_RED_STATUS:-1}" ]; then
                  printf 'exited %s with no [%s] line at all — it aborted, it did not fail an assertion' "$2" "${SHMUTANT_RED_PREFIX:-FAIL: }"
                else
                  printf 'exited %s, not %s — the suite ABORTED rather than failing its assertion' "$2" "${SHMUTANT_RED_STATUS:-1}"
                fi ;;
    unapplied)  printf 'the injection did not apply — the old literal matched nothing, so this row tests NOTHING' ;;
    unprepared) case "$2" in
                  clone)   printf 'could not clone the pristine tree' ;;
                  modified) printf 'the pristine tree was modified after prepare — a callback wrote into it, so nothing is cloned from it' ;;
                  raced)   printf 'the clone does not match the prepared tree — a concurrent callback wrote into pristine during the copy' ;;
                  missing) printf 'the target is not a regular file inside the tree' ;;
                  moved)   printf 'the target'"'"'s directory left the tree before the rewrite — a concurrent callback moved or replaced it' ;;
                  swapped) printf 'the tree at the clone path is no longer the clone this run made — the run renamed it away and put something else there' ;;
                  *)       printf 'the rewrite failed' ;;
                esac ;;
    baseline)   printf 'the tests selected by [%s] did not come back green BEFORE any defect was injected — a red result here would prove nothing (see the baseline record)' "$4" ;;
    timeout)    printf 'did not finish within %ss — a defect that hangs the suite is endured, not detected' "${SHMUTANT_TIMEOUT:-300}" ;;
    lost)       printf 'produced NO verdict — its worker died without reporting' ;;
    unsettled)  printf 'its process tree never settled — something kept forking out of reach while it was being ended, so what it did cannot be trusted' ;;
    *)          printf 'unknown verdict [%s]' "$1" ;;
  esac
}

# _shmutant_fresh_dir <dir> — remove <dir> and create it empty; false when either step fails or
# anything is still inside it.
# _shmutant_remove <path> [<parent-physical>] — remove a tree this harness created. Directories are made writable
# first (a preserved read-only root would otherwise refuse), and a path whose parent no longer
# resolves to where it was created is left alone: a callback can rename a worker directory
# and put a symlink in its place, and rm -rf follows a symlink in an intermediate component.
# Returns 1 when something is still there afterwards.
_shmutant_remove() {
  local path="$1" parent
  # The parent first, even for a path that is not there: a caller about to create it would
  # otherwise create it through the link.
  parent="$(command -p dirname -- "$path")"
  if [ -L "$parent" ]; then
    _shmutant_err "refusing to remove $path: its parent is now a symlink, not the directory it was created in"; return 1
  fi
  # With <parent-physical> given, the whole ancestry must still resolve to it: a link swapped
  # in above the immediate parent would otherwise lead the removal into another tree.
  if [ -n "${2:-}" ] && [ "$(_shmutant_abs "$parent")" != "$2" ]; then
    _shmutant_err "refusing to remove $path: its parent no longer resolves to the directory it was created in"; return 1
  fi
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    # One pass per level: find cannot enter a directory until the pass before made it readable.
    local i
    for (( i = 0; i < 64; i++ )); do
      [ -n "$(command -p find "$path" -type d ! -perm -u+rwx -print 2>/dev/null | command -p head -n 1)" ] || break
      command -p find "$path" -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null
    done
  fi
  command -p rm -rf -- "$path" 2>/dev/null
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

_shmutant_fresh_dir() {
  _shmutant_remove "$1" "${2:-}" || return 1
  # No -p: a symlink to a directory planted between the removal and here would satisfy -p.
  command -p mkdir -- "$1" 2>/dev/null
}

# _shmutant_run_jobs <kind> <count> <workdir> <run> <suffix> <jobs> — run <count> workers of
# <kind> through a bounded pool; a mut index whose SHMUTANT_SKIP entry is 1 is not started.
# Reaps by pid, so a caller's own background jobs are never consumed by the pool.
# _shmutant_abort_workers <signal> — on INT or TERM while workers run: kill every active
# worker's process tree, put the caller's own traps back, and deliver the signal again so the
# caller's handler (or the default) decides what happens to the caller.
_shmutant_abort_workers() {
  local sig="$1"
  # Between a worker's spawn and its registration the handler only takes note; the loop
  # applies the abort as soon as the new worker is on the list.
  if [ "${SHMUTANT_SPAWNING:-0}" = 1 ]; then SHMUTANT_ABORT_PENDING="$sig"; return 0; fi
  trap '' INT TERM
  [ "${#SHMUTANT_ACTIVE[@]}" -eq 0 ] || _shmutant_end_workers "${SHMUTANT_ACTIVE[@]}"
  _shmutant_restore_traps
  kill "-$sig" "$BASHPID"
}

# _shmutant_restore_traps — put back the INT and TERM traps saved by _shmutant_run_jobs. An
# empty saved handler means the caller had none, which is `trap -`, never `trap ""`: the empty
# string would make the shell IGNORE the signal from then on.
_shmutant_restore_traps() {
  # The saved value is the complete `trap -- '…' SIGTERM` declaration `trap -p` printed, put
  # back verbatim; re-spelling it by hand is how a handler once came back as `echo mineSIGTERM`.
  if [ -n "${SHMUTANT_TRAP_INT:-}" ]; then eval "$SHMUTANT_TRAP_INT"; else trap - INT; fi
  if [ -n "${SHMUTANT_TRAP_TERM:-}" ]; then eval "$SHMUTANT_TRAP_TERM"; else trap - TERM; fi
}

# _shmutant_hold_traps / _shmutant_release_traps — the caller's (or prepare's) CHLD, DEBUG,
# RETURN and ERR traps, off from the moment prepare returns until the pool is done. A CHLD
# handler that waits would reap the workers; any of them, run between the shadow check and the
# workers, could define a shadow after its name was cleared (DEBUG runs before every command
# once prepare set functrace). Held once; the saves are the few commands a handler still sees.
_shmutant_hold_traps() {
  [ -z "${SHMUTANT_TRAPS_HELD:-}" ] || return 0
  SHMUTANT_TRAP_CHLD="$(_shmutant_saved_trap CHLD)"; SHMUTANT_TRAP_DEBUG="$(_shmutant_saved_trap DEBUG)"
  SHMUTANT_TRAP_RETURN="$(_shmutant_saved_trap RETURN)"; SHMUTANT_TRAP_ERR="$(_shmutant_saved_trap ERR)"
  SHMUTANT_TRAPS_HELD=1; trap - CHLD DEBUG RETURN ERR
}
_shmutant_release_traps() {
  [ -n "${SHMUTANT_TRAPS_HELD:-}" ] || return 0
  if [ -n "${SHMUTANT_TRAP_CHLD:-}" ]; then eval "$SHMUTANT_TRAP_CHLD"; else trap - CHLD; fi
  if [ -n "${SHMUTANT_TRAP_ERR:-}" ]; then eval "$SHMUTANT_TRAP_ERR"; else trap - ERR; fi
  # RETURN and DEBUG are not handed back here: a RETURN handler runs when this very function
  # returns, and a DEBUG handler before every command after it, while harness functions still
  # return and the pool's status is still to be returned. They are left pending for the RETURN
  # trap of the outer entry point, which runs once that status is settled.
  SHMUTANT_TRAP_RETURN_PENDING="${SHMUTANT_TRAP_RETURN:-}"; SHMUTANT_TRAP_DEBUG_PENDING="${SHMUTANT_TRAP_DEBUG:-}"; SHMUTANT_TRAPS_PENDING=1
  unset SHMUTANT_TRAPS_HELD SHMUTANT_TRAP_CHLD SHMUTANT_TRAP_DEBUG SHMUTANT_TRAP_RETURN SHMUTANT_TRAP_ERR
}
# _shmutant_traps_last — the RETURN trap of shmutant_pool: the caller's RETURN and DEBUG traps
# go back here, when the pool's status is already settled and no harness command follows —
# whatever a handler does now cannot change what the pool returned. DEBUG last of all.
_shmutant_traps_last() {
  local ret="${SHMUTANT_TRAP_RETURN_PENDING:-}" dbg="${SHMUTANT_TRAP_DEBUG_PENDING:-}"
  builtin unset SHMUTANT_TRAP_RETURN_PENDING SHMUTANT_TRAP_DEBUG_PENDING SHMUTANT_TRAPS_PENDING
  if [[ -n "$ret" ]]; then builtin eval "$ret"; else builtin trap - RETURN; fi
  if [[ -n "$dbg" ]]; then builtin eval "$dbg"; else builtin trap - DEBUG; fi
}

# _shmutant_saved_trap <signal> — the caller's current trap declaration for <signal> as
# `trap -p` prints it, or empty.
_shmutant_saved_trap() {
  trap -p "$1"
}

_shmutant_run_jobs() {
  local rc=0
  SHMUTANT_ACTIVE=(); SHMUTANT_SPAWNING=0; SHMUTANT_ABORT_PENDING=""
  SHMUTANT_TRAP_INT="$(_shmutant_saved_trap INT)"; SHMUTANT_TRAP_TERM="$(_shmutant_saved_trap TERM)"
  _shmutant_hold_traps
  trap '_shmutant_abort_workers INT' INT
  trap '_shmutant_abort_workers TERM' TERM
  _shmutant_run_jobs_loop "$@"; rc=$?
  _shmutant_restore_traps
  SHMUTANT_ACTIVE=()
  return "$rc"
}

_shmutant_run_jobs_loop() {
  local kind="$1" n="$2" wd="$3" run="$4" suffix="$5" jobs="$6" i p vw
  local -a pids=()
  for (( i = 0; i < n; i++ )); do
    if [ "$kind" = mut ] && [ "${SHMUTANT_SKIP[$i]:-0}" != 0 ]; then continue; fi
    # Recreated, never reused: a stale timeout marker or tree from an earlier pool in the same
    # workdir would be read as this run's.
    # The workdir first, by identity: a callback that already ran could have moved it away and
    # put a caller's directory, with a `mut-N` of its own, at its path.
    if ! _shmutant_wd_is_marked "$wd" || ! _shmutant_fresh_dir "$wd/$kind-$i" "$wd" || ! SHMUTANT_DIR_IDS["$kind-$i"]="$(_shmutant_dir_id "$wd/$kind-$i")" \
      || ! _shmutant_open_channel "$wd" "$kind-$i"; then
      _shmutant_err "cannot recreate $wd/$kind-$i — a stale verdict there could be read as this run's; refusing to continue"
      # The workers already running are ended, not waited for: one of them may be unbounded.
      if [ "${#pids[@]}" -gt 0 ]; then
        _shmutant_end_workers "${pids[@]}"
        # Reaped and collected like any other: their channels close, their clones go.
        while [ "${#pids[@]}" -gt 0 ]; do _shmutant_reap_one "$wd"; done
      fi
      return 2
    fi
    SHMUTANT_SPAWNING=1
    _shmutant_worker "$kind" "$i" "$wd" "$run" "$suffix" &
    p=$!
    pids+=("$p"); SHMUTANT_ACTIVE_KEY["$p"]="$kind-$i"
    SHMUTANT_ACTIVE_ID["$p"]="$(_shmutant_identity "$p")" || SHMUTANT_ACTIVE_ID["$p"]=""
    # The pool's copy of the write end goes: the worker has its own, and a later worker must
    # not inherit every earlier channel.
    vw="${SHMUTANT_VERDICT_W[$kind-$i]}"; exec {vw}>&-; unset "SHMUTANT_VERDICT_W[$kind-$i]"
    SHMUTANT_ACTIVE=("${pids[@]}")
    SHMUTANT_SPAWNING=0
    [ -z "${SHMUTANT_ABORT_PENDING:-}" ] || { p="$SHMUTANT_ABORT_PENDING"; SHMUTANT_ABORT_PENDING=""; _shmutant_abort_workers "$p"; }
    if [ "${#pids[@]}" -ge "$jobs" ]; then _shmutant_reap_one "$wd" || return 2; fi
  done
  while [ "${#pids[@]}" -gt 0 ]; do _shmutant_reap_one "$wd" || return 2; done
  return 0
}

# _shmutant_reap_one <workdir> — wait for one of `pids`, collect its verdict from its channel,
# and drop it from the list. Globals: pids (caller's array), SHMUTANT_ACTIVE.
_shmutant_reap_one() {
  local wd="$1" done_pid wrc p key
  local -a rest=()
  wait -n -p done_pid "${pids[@]}"; wrc=$?
  if [ -z "${done_pid:-}" ]; then
    # Nothing of ours to wait for: every listed worker was reaped by someone else (a caller's
    # CHLD trap is neutralised, so this is the residue). None has a verdict; none is spun on.
    for p in "${pids[@]}"; do
      key="${SHMUTANT_ACTIVE_KEY[$p]:-}"; [ -n "$key" ] && _shmutant_collect "$wd/$key" "$key" 127
      unset "SHMUTANT_ACTIVE_KEY[$p]" "SHMUTANT_ACTIVE_ID[$p]"
    done
    pids=(); SHMUTANT_ACTIVE=()
    return 0
  fi
  key="${SHMUTANT_ACTIVE_KEY[$done_pid]:-}"
  [ -n "$key" ] && _shmutant_collect "$wd/$key" "$key" "$wrc"
  unset "SHMUTANT_ACTIVE_KEY[$done_pid]" "SHMUTANT_ACTIVE_ID[$done_pid]"
  rest=()
  for p in "${pids[@]}"; do [ "$p" = "$done_pid" ] || rest+=("$p"); done
  pids=("${rest[@]}")
  SHMUTANT_ACTIVE=("${pids[@]}")
  return 0
}

# _shmutant_validate_settings <label> <workdir> — every SHMUTANT_* setting the pool and its
# workers read, checked before the first use and again after prepare (which runs in this shell
# and can assign any of them). Replaces SHMUTANT_STREAM by its absolute form. Returns 2 on the
# first violation.
_shmutant_validate_settings() {
  local label="$1" wd="$2"
  # Digits only AND a bounded width: an all-digit value past bash's integer range fails every
  # numeric test with a diagnostic and would fall through as if it had passed.
  # Every setting is read through a default first: a caller's `set -u` must not turn an unset
  # option into an abort.
  local v_timeout="${SHMUTANT_TIMEOUT:-300}" v_red="${SHMUTANT_RED_STATUS:-1}" v_jobs="${SHMUTANT_JOBS:-}"
  case "$v_timeout" in
    *[!0-9]*|'') _shmutant_err "$label: SHMUTANT_TIMEOUT must be a non-negative integer, got [$v_timeout]"; return 2 ;;
  esac
  [ "${#v_timeout}" -le 9 ] || { _shmutant_err "$label: SHMUTANT_TIMEOUT is too large, got [$v_timeout]"; return 2; }
  case "$v_red" in
    *[!0-9]*|'') _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red]"; return 2 ;;
  esac
  [ "${#v_red}" -le 3 ] || { _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red]"; return 2; }
  if [ "$v_red" -lt 1 ] || [ "$v_red" -gt 255 ]; then
    _shmutant_err "$label: SHMUTANT_RED_STATUS must be an exit status from 1 to 255, got [$v_red] — 0 is green by definition"; return 2
  fi
  if [ -n "$v_jobs" ]; then
    case "$v_jobs" in *[!0-9]*) _shmutant_err "$label: SHMUTANT_JOBS must be a positive integer, got [$v_jobs]"; return 2 ;; esac
    if [ "${#v_jobs}" -gt 4 ] || [ "$v_jobs" -lt 1 ]; then
      _shmutant_err "$label: SHMUTANT_JOBS must be a positive integer of at most four digits, got [$v_jobs]"; return 2
    fi
  fi
  # Canonical forms from here on: `08` would compare equal numerically and unequal as text.
  # A readonly setting is not assigned (that ends a non-interactive caller's shell): it is
  # accepted when already canonical and refused otherwise.
  if [ -n "${SHMUTANT_TIMEOUT+x}" ]; then _shmutant_canon "$label" SHMUTANT_TIMEOUT "$(( 10#$v_timeout ))" || return 2; fi
  if [ -n "${SHMUTANT_RED_STATUS+x}" ]; then _shmutant_canon "$label" SHMUTANT_RED_STATUS "$(( 10#$v_red ))" || return 2; fi
  if [ -n "$v_jobs" ]; then _shmutant_canon "$label" SHMUTANT_JOBS "$(( 10#$v_jobs ))" || return 2; fi
  case "${SHMUTANT_BASELINE:-1}" in 0|1) ;; *) _shmutant_err "$label: SHMUTANT_BASELINE must be 0 or 1, got [${SHMUTANT_BASELINE:-}]"; return 2 ;; esac
  # Set and empty is refused, not read as off: an empty value must not drop the check it names.
  case "${SHMUTANT_COUNTS-0}" in 0|1) ;; *) _shmutant_err "$label: SHMUTANT_COUNTS must be 0 or 1, got [${SHMUTANT_COUNTS:-}]"; return 2 ;; esac
  # The counts are compared in the baseline pass: without it they would be collected and never
  # read, and every selection would pass for complete.
  if [ "${SHMUTANT_COUNTS:-0}" = 1 ] && [ "${SHMUTANT_BASELINE:-1}" = 0 ]; then
    _shmutant_err "$label: SHMUTANT_COUNTS=1 needs the baseline (SHMUTANT_BASELINE=0 or --no-baseline turned it off) — the counts are compared in the baseline pass"; return 2
  fi
  # The pool sets SHMUTANT_SELECT for every run; a readonly one would keep a stale selector
  # (or end the run's shell) under a callback that reads the variable rather than its argument.
  if _shmutant_readonly SHMUTANT_SELECT; then _shmutant_err "$label: SHMUTANT_SELECT is readonly — the pool sets it for every run; leave it writable"; return 2; fi
  case "${SHMUTANT_KEEP:-0}" in 0|1) ;; *) _shmutant_err "$label: SHMUTANT_KEEP must be 0 or 1, got [${SHMUTANT_KEEP:-}]"; return 2 ;; esac
  if [ -n "${SHMUTANT_RED_PREFIX+x}" ] && [ -z "$SHMUTANT_RED_PREFIX" ]; then
    _shmutant_err "$label: SHMUTANT_RED_PREFIX is empty — every line would count as a red line"; return 2
  fi
  case "${SHMUTANT_RED_PREFIX:-}" in *$'\n'*) _shmutant_err "$label: SHMUTANT_RED_PREFIX contains a newline — no single line could ever start with it"; return 2 ;; esac
  if [ -n "${SHMUTANT_STREAM:-}" ]; then
    local sdir
    # A newline anywhere: the substitutions that split the path would strip a trailing one and
    # name the sibling, past the checks below.
    case "$SHMUTANT_STREAM" in *$'\n'*) _shmutant_err "$label: SHMUTANT_STREAM contains a newline"; return 2 ;; esac
    if [ -L "$SHMUTANT_STREAM" ]; then
      _shmutant_err "$label: SHMUTANT_STREAM is a symlink ($SHMUTANT_STREAM) — name the file itself, so where the records land can be checked"; return 2
    fi
    if [ -e "$SHMUTANT_STREAM" ] && [ ! -f "$SHMUTANT_STREAM" ]; then
      _shmutant_err "$label: SHMUTANT_STREAM exists and is not a regular file ($SHMUTANT_STREAM) — a FIFO with no reader would block the pool forever"; return 2
    fi
    if ! sdir="$(_shmutant_abs "$(command -p dirname -- "$SHMUTANT_STREAM")")"; then
      _shmutant_err "$label: SHMUTANT_STREAM points into a directory that does not exist: $SHMUTANT_STREAM"; return 2
    fi
    if _shmutant_inside "$wd" "$sdir"; then
      _shmutant_err "$label: SHMUTANT_STREAM lies inside the workdir ($SHMUTANT_STREAM) — the pool recreates and removes what is in there"; return 2
    fi
    # Replaced by its validated absolute form: prepare runs in this shell and may cd.
    _shmutant_canon "$label" SHMUTANT_STREAM "$sdir/$(command -p basename -- "$SHMUTANT_STREAM")" || return 2
  fi

  return 0
}

# _shmutant_open_stream <label> — hold the validated SHMUTANT_STREAM open as a descriptor. Called
# again after prepare: a path prepare assigned replaces the one opened before it, and one it
# unset closes it. Returns 2 when the file cannot be opened.
_shmutant_open_stream() {
  local label="$1"
  if [ -n "${SHMUTANT_STREAM_OPENED+x}" ] && [ "$SHMUTANT_STREAM_OPENED" = "${SHMUTANT_STREAM:-}" ]; then return 0; fi
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then exec {SHMUTANT_STREAM_FD}>&-; unset SHMUTANT_STREAM_FD; fi
  unset SHMUTANT_STREAM_OPENED; [ -n "${SHMUTANT_STREAM:-}" ] || { SHMUTANT_STREAM_OPENED=""; return 0; }
  # In a group: a redirection on a bare `exec` is permanent, and `2>/dev/null` there would
  # silence this shell's stderr for the rest of the run.
  # shellcheck disable=SC2093
  if ! { exec {SHMUTANT_STREAM_FD}>>"$SHMUTANT_STREAM"; } 2>/dev/null; then
    _shmutant_err "$label: cannot open SHMUTANT_STREAM for appending: $SHMUTANT_STREAM"; unset SHMUTANT_STREAM_FD; return 2
  fi
  # Cached only once the descriptor exists: a retry after a failed open must open again.
  SHMUTANT_STREAM_OPENED="$SHMUTANT_STREAM"
  # The inode the path named when opened; the pool checks at the end that it still does, and
  # that what follows the bytes already there is exactly what the pool wrote: every record also
  # goes to a private unlinked copy, so a callback that truncates, overwrites or appends to the
  # stream in place is seen.
  SHMUTANT_STREAM_INO="$(_shmutant_dir_id "$SHMUTANT_STREAM")"
  SHMUTANT_STREAM_BASE="$(command -p wc -c < "$SHMUTANT_STREAM" 2>/dev/null | command -p tr -d ' ')" || SHMUTANT_STREAM_BASE=0
  # The bytes already there, by checksum: an overwrite in place within them keeps the length.
  if [ "${SHMUTANT_STREAM_BASE:-0}" -gt 0 ]; then
    SHMUTANT_STREAM_PREFIX_CK="$(command -p dd if="$SHMUTANT_STREAM" bs="$SHMUTANT_STREAM_BASE" count=1 2>/dev/null | command -p cksum)"
  else SHMUTANT_STREAM_PREFIX_CK=""; fi
  _shmutant_close_stream_copy
  local copy
  # A failure here rolls the open back: left open and cached, the next pool for the same stream
  # would skip this function and run without a private copy.
  local tmpd
  tmpd="$(_shmutant_abs "${TMPDIR:-/tmp}")" || { _shmutant_stream_rollback; _shmutant_err "$label: TMPDIR does not name a directory that resolves from here (${TMPDIR:-/tmp}) — the private copy of the verdict stream goes there"; return 2; }
  copy="$(command -p mktemp "$tmpd/shmutant-stream.XXXXXX" 2>/dev/null)" || { _shmutant_stream_rollback; _shmutant_err "$label: cannot create the private copy of the verdict stream (in ${TMPDIR:-/tmp})"; return 2; }
  # shellcheck disable=SC2093
  if ! { exec {SHMUTANT_STREAM_COPY_W}>>"$copy" {SHMUTANT_STREAM_COPY_R}<"$copy"; } 2>/dev/null; then
    command -p rm -f -- "$copy"; _shmutant_stream_rollback; _shmutant_err "$label: cannot open the private copy of the verdict stream"; return 2
  fi
  command -p rm -f -- "$copy"
}
_shmutant_stream_rollback() {
  [ -z "${SHMUTANT_STREAM_FD:-}" ] || exec {SHMUTANT_STREAM_FD}>&-
  unset SHMUTANT_STREAM_FD SHMUTANT_STREAM_OPENED
}
_shmutant_close_stream_copy() {
  [ -z "${SHMUTANT_STREAM_COPY_W:-}" ] || exec {SHMUTANT_STREAM_COPY_W}>&-
  [ -z "${SHMUTANT_STREAM_COPY_R:-}" ] || exec {SHMUTANT_STREAM_COPY_R}<&-
  unset SHMUTANT_STREAM_COPY_W SHMUTANT_STREAM_COPY_R
}

# _shmutant_stream_intact — true when SHMUTANT_STREAM is unset or still names the file that was
# opened: a callback that unlinked or replaced it left the records on an inode nobody can read.
_shmutant_stream_intact() {
  [ -n "${SHMUTANT_STREAM:-}" ] || return 0
  [ ! -L "$SHMUTANT_STREAM" ] && [ "$(_shmutant_dir_id "$SHMUTANT_STREAM")" = "${SHMUTANT_STREAM_INO:-}" ] || return 1
  # Contents, past what was there when opened: a truncation, an overwrite or an appended record
  # from a callback changes them; the pool's own records, through the descriptor, do not.
  [ -n "${SHMUTANT_STREAM_COPY_R:-}" ] || return 1
  # And what was there when opened, unchanged: an overwrite in place within it keeps the length.
  if [ "${SHMUTANT_STREAM_BASE:-0}" -gt 0 ]; then
    [ "$(command -p dd if="$SHMUTANT_STREAM" bs="$SHMUTANT_STREAM_BASE" count=1 2>/dev/null | command -p cksum)" = "${SHMUTANT_STREAM_PREFIX_CK:-}" ] || return 1
  fi
  [ "$(command -p tail -c "+$(( ${SHMUTANT_STREAM_BASE:-0} + 1 ))" -- "$SHMUTANT_STREAM" 2>/dev/null | command -p cksum)" = "$(command -p cksum <&"$SHMUTANT_STREAM_COPY_R")" ]
}

# _shmutant_readonly <name> — true when <name> is readonly in this shell; an assignment to it
# would end a non-interactive shell. This runs before the shadow check, so it keeps no local
# (the readonly name could be its own), uses no `set` (a caller's function of that name would
# leave the parameters untouched) and no `return` (one of those would fall through): the
# `declare -p` line travels as a positional parameter, and each helper's status is its last
# command's. The attribute field is the word after `declare -`.
_shmutant_readonly() { _shmutant_attrs_readonly "$(declare -p -- "$1" 2>/dev/null)"; }
_shmutant_attrs_readonly() { _shmutant_attr_field_has_r "${1#declare -}"; }
_shmutant_attr_field_has_r() { case "${1%% *}" in *r*) [[ 1 -eq 1 ]] ;; *) [[ 1 -eq 0 ]] ;; esac; }

# _shmutant_locals_writable <label> <who> <name…> — refuse (status 1, with a message) when a
# <name> is readonly: bash refuses a local over a readonly global, and the assignment that
# follows would end a non-interactive caller's shell. Positional parameters only, as above;
# one name per call, by recursion, so nothing here can loop.
# The list is long (every name declared local anywhere the entry point runs, its workers
# included: a readonly global reaches a subshell too), so `readonly -p` is read once and only
# a name it mentions is probed exactly.
_shmutant_locals_writable() { _shmutant_locals_writable_in "$1" "$2" "$(readonly -p 2>/dev/null)" "${@:3}"; }
_shmutant_locals_writable_in() {
  if [[ $# -le 3 ]]; then :
  elif [[ "$3" == *" $4="* || "$3" == *" $4" || "$3" == *" $4"$'\n'* ]] && _shmutant_readonly "$4"; then
    _shmutant_err "$1: $2 '$4' readonly — a name shmutant keeps its own state in; declare yours with another name or a local of your own"; [[ 1 -eq 0 ]]
  else _shmutant_locals_writable_in "$1" "$2" "$3" "${@:5}"
  fi
}

# _shmutant_pool_stash <status> — prepare's status into _shmutant_pool_prc, after the traps are
# held and only when prepare did not make that name readonly (dynamic scope reaches it, and the
# assignment would end a non-interactive caller). The status arrives as a positional parameter,
# which no callback can mark readonly. Refuses with status 1.
_shmutant_pool_stash() {
  _shmutant_hold_traps
  # if/else, not a return: a `return` function prepare defined would fall through to the
  # assignment; the shadow check that refuses it comes after this.
  if _shmutant_readonly _shmutant_pool_prc; then
    _shmutant_err "$_shmutant_pool_label: prepare made '_shmutant_pool_prc' readonly — the name the pool keeps prepare's status in; declare yours with another name or a local of your own"; [[ 1 -eq 0 ]]
  else _shmutant_pool_prc=$1
  fi
}

# _shmutant_pool_locals_writable <label> <who> — every name declared local by the pool and by
# what it runs, workers included, checked at entry (the calling shell) and after prepare
# (dynamic scope reaches the pool's own). The suite checks this list against the source.
_shmutant_pool_locals_writable() {
  _shmutant_locals_writable "$1" "$2" \
    SHMUTANT_FREEZE_UNSETTLED SHMUTANT_KILL_GROUP SHMUTANT_START SHMUTANT_UNSETTLED_FD _shmutant_pool_cap _shmutant_pool_errexit _shmutant_pool_label _shmutant_pool_n _shmutant_pool_pout_r _shmutant_pool_pout_w _shmutant_pool_prc _shmutant_pool_run \
    _shmutant_pool_t0 _shmutant_pool_wd after_ck ambiguous base base_sel base_verdict base_why cap cksum_bin clone_id comp copy counts counts_bad counts_end counts_got counts_r counts_w cwhy d \
    dbg depth detail dir dirmode done_pid err_fd errexit_before etime f fd fifo \
    fired fmt found frozen go got grp h have held helpers here \
    hms hold hold_r holder holderid hp i id intact jobs k kept key \
    killed kind kinds l label left left_r left_w line ls_bin m mark \
    mode ms mutate_aliases n new nl now out out_r out_r2 out_w outf \
    p parent path pending phys pid pids pool_aliases pout pout_r pout_w prc \
    prep r rc red rel rest ret rjrc root root_ok rootid rootls \
    roots rounds row_why run s sdir sec seen seen_r seen_w sel sent setup_failed sig starts nul counts_r2 \
    spec st stat_bin state status stillours stillpids suffix swapped t t0 t1 \
    table target target_ck targets timeout tmp unpublished us v v_jobs v_red v_timeout \
    verdict vr vw wd who wit wrc wstatus \
    SHMUTANT_ABORT_PENDING SHMUTANT_ACTIVE SHMUTANT_ACTIVE_ID SHMUTANT_ACTIVE_KEY SHMUTANT_BASE_SEL SHMUTANT_COUNTS_FD \
    SHMUTANT_CLEANUP_FAILED SHMUTANT_CLONE_ID SHMUTANT_DIR_ID SHMUTANT_DIR_IDS SHMUTANT_EMIT_FAILED \
    SHMUTANT_FROZEN_NOW SHMUTANT_HELD SHMUTANT_MUT_NEW SHMUTANT_MUT_NL SHMUTANT_MUT_OLD \
    SHMUTANT_PRISTINE_ID SHMUTANT_PRISTINE_STATE SHMUTANT_RES_CLONE SHMUTANT_RES_COUNTS SHMUTANT_RES_COUNTS_BAD SHMUTANT_RES_STATUS SHMUTANT_RES_US \
    SHMUTANT_RES_VERDICT SHMUTANT_RUN_COUNTS SHMUTANT_RUN_COUNTS_BAD SHMUTANT_RUN_FIRED SHMUTANT_RUN_PUBLISHED SHMUTANT_RUN_RED SHMUTANT_RUN_SCAN_FAILED \
    SHMUTANT_RUN_SETUP_FAILED SHMUTANT_RUN_STATUS SHMUTANT_RUN_TAMPERED SHMUTANT_RUN_TARGET_REWRITTEN \
    SHMUTANT_RUN_UNSETTLED SHMUTANT_RUN_WITNESSED SHMUTANT_SCAN_P SHMUTANT_SCAN_W SHMUTANT_SKIP \
    SHMUTANT_SPAWNING SHMUTANT_STAT_STYLE SHMUTANT_STREAM_BASE SHMUTANT_STREAM_INO SHMUTANT_STREAM_OPENED SHMUTANT_STREAM_PREFIX_CK \
    SHMUTANT_TARGET_CK SHMUTANT_TARGET_KEY SHMUTANT_TARGET_REL SHMUTANT_TRAPS_HELD SHMUTANT_TRAPS_PENDING \
    SHMUTANT_TRAP_CHLD SHMUTANT_TRAP_DEBUG SHMUTANT_TRAP_DEBUG_PENDING SHMUTANT_TRAP_ERR SHMUTANT_TRAP_INT \
    SHMUTANT_TRAP_RETURN SHMUTANT_TRAP_RETURN_PENDING SHMUTANT_TRAP_TERM SHMUTANT_VERDICT_FD SHMUTANT_VERDICT_R \
    SHMUTANT_VERDICT_W SHMUTANT_V_STATUS SHMUTANT_V_US SHMUTANT_V_VERDICT SHMUTANT_WD_ID \
    SHMUTANT_ROWS_NAME SHMUTANT_ROWS_FILE SHMUTANT_ROWS_OLD SHMUTANT_ROWS_NEW SHMUTANT_ROWS_WIT SHMUTANT_ROWS_SEL \
    SHMUTANT_TARGET SHMUTANT_DECL_ERRORS SHMUTANT_SELECTED_N \
    _shmutant_bo _shmutant_so _shmutant_o _shmutant_n _shmutant_pc _shmutant_wrap_left \
    a budget dog e elapsed last leftovers linked lstart old rrc s tampered tmpd tnow victims wroot \
    SHMUTANT_PS_LSTART
}

# _shmutant_decl_writable <label> — the table's own names, checked by each declaration entry
# point before it assigns: a readonly one would end the plan's shell at the first row.
_shmutant_decl_writable() {
  _shmutant_locals_writable "$1" "the calling shell made" SHMUTANT_ROWS_NAME SHMUTANT_ROWS_FILE SHMUTANT_ROWS_OLD SHMUTANT_ROWS_NEW SHMUTANT_ROWS_WIT SHMUTANT_ROWS_SEL SHMUTANT_TARGET SHMUTANT_DECL_ERRORS
}

# _shmutant_canon <label> <name> <canonical> — set <name> to its canonical value, or, when the
# caller made it readonly, accept it only if it already is that value.
_shmutant_canon() {
  if _shmutant_readonly "$2"; then
    [ "${!2}" = "$3" ] || { _shmutant_err "$1: $2 is readonly and not in canonical form ([${!2}], canonical $3) — a readonly setting must already be canonical (a plain decimal, an absolute physical path)"; return 2; }
    return 0
  fi
  printf -v "$2" '%s' "$3"
}

# _shmutant_callable <name> — true when <name> is a function or an executable file: what an
# invocation by variable can call and return from. An alias is not (aliases expand at parse
# time); a builtin is not either (`exit`, `exec` or `return` as a callback would end or leave
# the pool's own shell rather than return to it).
_shmutant_callable() {
  case "$(builtin type -t -- "$1" 2>/dev/null)" in function|file) return 0 ;; esac
  return 1
}

# _shmutant_pin_callback <name> — a function's name as given; an executable file's absolute
# physical path, resolved now: prepare may change the working directory, and a relative path
# looked up again from there (by the check after prepare, by a worker) could name another
# program. Fails for anything else, and for a name with a newline in it.
_shmutant_pin_callback() {
  case "$1" in *$'\n'*) return 1 ;; esac
  case "$(builtin type -t -- "$1" 2>/dev/null)" in
    function) printf '%s' "$1"; return 0 ;;
    file) ;;
    *) return 1 ;;
  esac
  local f d
  case "$1" in */*) f="$1" ;; *) f="$(builtin type -P -- "$1" 2>/dev/null)" || return 1 ;; esac
  [ -n "$f" ] || return 1
  # Through the resolver: it refuses a physical directory name ending in a newline, which this
  # substitution would otherwise strip, naming the sibling's program.
  d="$(_shmutant_abs "$(command -p dirname -- "$f")")" || return 1
  printf '%s/%s' "$d" "$(command -p basename -- "$f")"
}

# _shmutant_std_bin <name> — the executable file <name> on the standard utility path, or
# failure. `command -pv` would report a caller's function of that name, and find execs a
# program: the file is what the fingerprint hands it.
_shmutant_std_bin() {
  local p d
  p="$(command -p getconf PATH 2>/dev/null)" || p=""
  [ -n "$p" ] || p=/usr/bin:/bin
  while [ -n "$p" ]; do
    d="${p%%:*}"; case "$p" in *:*) p="${p#*:}" ;; *) p="" ;; esac
    if [ -n "$d" ] && [ -f "$d/$1" ] && [ -x "$d/$1" ]; then builtin printf '%s' "$d/$1"; return 0; fi
  done
  return 1
}

# _shmutant_stat_style — how this platform's stat prints an mtime, decided once per pool:
# gnu-ns (`stat -c %.9Y`), gnu, bsd-ns (`stat -f %Fm`), bsd, or none. Not POSIX, so a platform
# without either form falls back to the minute `ls` shows.
_shmutant_stat_style() {
  local st; st="$(_shmutant_std_bin stat)" || { SHMUTANT_STAT_STYLE=none; return 0; }
  if "$st" -c '%.9Y' / > /dev/null 2>&1; then SHMUTANT_STAT_STYLE=gnu-ns
  elif "$st" -c '%Y' / > /dev/null 2>&1; then SHMUTANT_STAT_STYLE=gnu
  elif "$st" -f '%Fm' / > /dev/null 2>&1; then SHMUTANT_STAT_STYLE=bsd-ns
  elif "$st" -f '%m' / > /dev/null 2>&1; then SHMUTANT_STAT_STYLE=bsd
  else SHMUTANT_STAT_STYLE=none; fi
}

# _shmutant_pristine_state <dir> — a fingerprint of the tree under <dir>, relative to it: every
# entry's `ls -ldn` line (mode, owner, group, a file's size, mtime to the minute, name, a link's
# target), the root's included; every entry's exact mtime where stat can give one (nanoseconds
# on GNU and BSD); and every regular file's content and size (POSIX cksum); sorted. Link counts,
# directory sizes and platform mode suffixes are left out, so a faithful `cp -RPp` clone of a
# tree (which keeps every timestamp exactly), its root given the tree's metadata, has the
# fingerprint of the tree. Any write, addition, removal, mode change or touch changes it; where
# no stat form exists, a timestamp change within its `ls` minute (or day) does not. Fails, rather
# than yield a partial listing, when a stage fails — which includes a regular file whose content
# cannot be read.
_shmutant_pristine_state() {
  # find execs a PROGRAM: `command` is a shell builtin (macOS ships a stub of that name, Linux
  # does not), so the utilities are resolved from the standard PATH first and exec'd by path.
  local ls_bin cksum_bin stat_bin="" fmt="" nl=$'\n'
  ls_bin="$(_shmutant_std_bin ls)" && cksum_bin="$(_shmutant_std_bin cksum)" || return 1
  case "${SHMUTANT_STAT_STYLE:-none}" in
    gnu-ns) stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-c%.9Y %n' ;;
    gnu)    stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-c%Y %n' ;;
    bsd-ns) stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-f%Fm %N' ;;
    bsd)    stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-f%m %N' ;;
  esac
  ( builtin cd -P -- "$1" 2>/dev/null || exit 1
    set -o pipefail
    # A name with a newline in it would span records below and be sorted apart from them, so
    # two such names could trade places under the same fingerprint: refused instead.
    command -p find . -name "*$nl*" 2>/dev/null | command -p awk 'END { exit NR > 0 }' || exit 1
    { command -p find . -exec "$ls_bin" -ldn -- {} + \
        && { [ -z "$stat_bin" ] || command -p find . -exec "$stat_bin" "$fmt" {} + ; } \
        && command -p find . -type f -exec "$cksum_bin" {} + ; } 2>/dev/null \
      | command -p awk '/^[0-9]/ || /^\.$/ || /^\.\// { print; next } { m = $1; sub(/[@+.]$/, "", m); o = $3; g = $4; sz = ($1 ~ /^d/) ? "-" : $5; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print m, "-", o, g, sz, $0 }' \
      | LC_ALL=C command -p sort )
}

# _shmutant_target_ck <workerdir> <relative target> <key> — the cksum of the target read from the
# worker's own directory, pinned and verified by identity as for the rewrite; failure when it
# is not a regular file there.
_shmutant_target_ck() {
  local ls_bin stat_bin="" fmt=""
  ls_bin="$(_shmutant_std_bin ls)" || return 1
  case "${SHMUTANT_STAT_STYLE:-none}" in
    gnu-ns) stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-c%.9Y' ;;
    gnu)    stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-c%Y' ;;
    bsd-ns) stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-f%Fm' ;;
    bsd)    stat_bin="$(_shmutant_std_bin stat)" || return 1; fmt='-f%m' ;;
  esac
  ( builtin cd -P -- "$1" 2>/dev/null || exit 1
    [ "$(_shmutant_dir_id .)" = "${SHMUTANT_DIR_IDS[$3]:-}" ] || exit 1
    [ ! -L "$2" ] && [ -f "$2" ] || exit 1
    # Mode, owner, size and the mtime (exact where stat gives one) as well as the content: a
    # test sensitive to any of them must see the file as the pool wrote it.
    { "$ls_bin" -ldn -- "$2" | command -p awk '{ sub(/[@+.]$/, "", $1); $2 = "-"; print $1, $3, $4, $5 }'
      [ -z "$stat_bin" ] || "$stat_bin" "$fmt" "$2"
      command -p cksum < "$2"; } 2>/dev/null )
}

# _shmutant_wd_is_marked <workdir> — true while <workdir> is, by identity, the directory this
# pool marked as its own; says so otherwise.
_shmutant_wd_is_marked() {
  [ ! -L "$1" ] && [ "$(_shmutant_dir_id "$1")" = "${SHMUTANT_WD_ID:-}" ] && return 0
  _shmutant_err "$1 is no longer the directory this pool marked as its own — a callback moved or replaced it"
  return 1
}

# _shmutant_pool_fail <label> <workdir> — the exit for a pool that stops after prepare: the
# pristine tree goes unless SHMUTANT_KEEP=1, and the stream descriptor is closed.
_shmutant_pool_fail() {
  _shmutant_pool_cleanup "$@"
  # Last: from here to the pool's return nothing forks, so a handler sees no child of the pool.
  _shmutant_release_traps
}
# _shmutant_pool_cleanup <label> <workdir> — everything _shmutant_pool_fail does but hand the
# traps back; the pool's tail does that itself, after its last check.
_shmutant_pool_cleanup() {
  # The prepared tree is removed only from the workdir this pool marked as its own: prepare
  # could have moved the workdir away and put a caller's directory, with a `pristine` entry of
  # its own, at its path.
  if [ "${SHMUTANT_KEEP:-0}" != 1 ] && [ ! -L "$2" ] && [ "$(_shmutant_dir_id "$2")" = "${SHMUTANT_WD_ID:-}" ]; then
    # And the tree itself, by the identity recorded when it was made: a callback that renamed
    # it away and put a directory of its own at the path does not get that removed.
    if [ ! -e "$2/pristine" ] && [ ! -L "$2/pristine" ]; then :
    elif [ -L "$2/pristine" ] || [ "$(_shmutant_dir_id "$2/pristine")" != "${SHMUTANT_PRISTINE_ID:-}" ]; then _shmutant_err "$1: refusing to remove $2/pristine: it is not the tree this pool prepared"; SHMUTANT_CLEANUP_FAILED=1
    else _shmutant_remove "$2/pristine" "$2" || { _shmutant_err "$1: could not remove $2/pristine"; SHMUTANT_CLEANUP_FAILED=1; }
    fi
  fi
  if [ -n "${SHMUTANT_STREAM_FD:-}" ]; then exec {SHMUTANT_STREAM_FD}>&-; unset SHMUTANT_STREAM_FD; fi
  _shmutant_close_stream_copy
  unset SHMUTANT_STREAM_OPENED
  unset SHMUTANT_PRISTINE_STATE
}

# _shmutant_drop_builtin_fn — remove a function named builtin without trusting any command
# name: an assignment to POSIXLY_CORRECT enters posix mode, where the special builtin `unset`
# is found before a function of its name. With `builtin` real, every other shadow (a function
# named return included) is refused through `builtin …`, never removed. Leaving posix mode resets shell options wholesale
# (expand_aliases off, inherit_errexit left on, …), so every option that changed is put back
# from BASHOPTS and SHELLOPTS, read before and after — variables, which nothing shadows — with
# the real builtin, which is real again by then. No `local`: that name is not yet checked.
_shmutant_drop_builtin_fn() {
  _shmutant_bo="$BASHOPTS"; _shmutant_so="$SHELLOPTS"; _shmutant_pc="${POSIXLY_CORRECT+set}:${POSIXLY_CORRECT-}"
  POSIXLY_CORRECT=1; unset -f builtin 2>/dev/null; unset POSIXLY_CORRECT
  _shmutant_o="$_shmutant_bo"
  while [[ -n "$_shmutant_o" ]]; do
    _shmutant_n="${_shmutant_o%%:*}"; case "$_shmutant_o" in *:*) _shmutant_o="${_shmutant_o#*:}" ;; *) _shmutant_o="" ;; esac
    case ":$BASHOPTS:" in *":$_shmutant_n:"*) ;; *) builtin shopt -s "$_shmutant_n" 2>/dev/null ;; esac
  done
  _shmutant_o="$BASHOPTS"
  while [[ -n "$_shmutant_o" ]]; do
    _shmutant_n="${_shmutant_o%%:*}"; case "$_shmutant_o" in *:*) _shmutant_o="${_shmutant_o#*:}" ;; *) _shmutant_o="" ;; esac
    case ":$_shmutant_bo:" in *":$_shmutant_n:"*) ;; *) builtin shopt -u "$_shmutant_n" 2>/dev/null ;; esac
  done
  _shmutant_o="$_shmutant_so"
  while [[ -n "$_shmutant_o" ]]; do
    _shmutant_n="${_shmutant_o%%:*}"; case "$_shmutant_o" in *:*) _shmutant_o="${_shmutant_o#*:}" ;; *) _shmutant_o="" ;; esac
    case ":$SHELLOPTS:" in *":$_shmutant_n:"*) ;; *) builtin set -o "$_shmutant_n" 2>/dev/null ;; esac
  done
  _shmutant_o="$SHELLOPTS"
  while [[ -n "$_shmutant_o" ]]; do
    _shmutant_n="${_shmutant_o%%:*}"; case "$_shmutant_o" in *:*) _shmutant_o="${_shmutant_o#*:}" ;; *) _shmutant_o="" ;; esac
    case ":$_shmutant_so:" in *":$_shmutant_n:"*) ;; *) builtin set +o "$_shmutant_n" 2>/dev/null ;; esac
  done
  # Two options BASHOPTS does not report reliably around this toggle: leaving posix mode turns
  # expand_aliases off, and leaves inherit_errexit on when errexit is on. Both from before.
  case ":$_shmutant_bo:" in *:expand_aliases:*) builtin shopt -s expand_aliases ;; *) builtin shopt -u expand_aliases ;; esac
  case ":$_shmutant_bo:" in *:inherit_errexit:*) builtin shopt -s inherit_errexit ;; *) builtin shopt -u inherit_errexit ;; esac
  # POSIXLY_CORRECT exactly as the caller had it: `set -o posix` above recreates it as `y`, and
  # the caller's own value, or its absence, is what the caller's later commands read. Unset only
  # when it is set: unsetting it leaves posix mode, which turns expand_aliases off again.
  case "$_shmutant_pc" in set:*) POSIXLY_CORRECT="${_shmutant_pc#set:}" ;; *) [[ -z "${POSIXLY_CORRECT+set}" ]] || builtin unset -v POSIXLY_CORRECT ;; esac
  builtin unset -v _shmutant_bo _shmutant_so _shmutant_o _shmutant_n _shmutant_pc
}

# _shmutant_no_shadows <label> — refuse to run while a builtin this harness signals, waits and
# reads with is not itself: a function of that name, or one disabled with `enable -n`, would
# decide what lives. External utilities are already reached through `command -p`.
_shmutant_no_shadows() {
  # A function named builtin (prepare could have defined one since the source-time removal)
  # goes first, so that `builtin type` below is the real thing.
  local n kinds; _shmutant_drop_builtin_fn
  # The check after prepare runs with the traps held (_shmutant_hold_traps): a handler that
  # defines a shadow on a later invocation would otherwise fire on the forks below or later.
  # `[` and `:` are shadowable and load-bearing; every builtin the harness invokes is listed.
  for n in kill wait read trap printf mapfile exec builtin command cd pwd exit return declare local unset set shopt eval readonly export shift true false '[' : . type test; do
    # An enabled builtin, not a function of that name and not one switched off with `enable -n`.
    # A caller's alias is no concern: this file's functions were parsed with aliases off.
    kinds="$(builtin type -at -- "$n" 2>/dev/null)"
    case "$kinds" in *function*) kinds="" ;; esac
    case "$kinds" in *builtin*) ;; *) _shmutant_err "$1: $n is not the builtin this harness relies on (a function of that name, or disabled with enable)"; builtin return 2 ;; esac
  done
}

# _shmutant_workdir_owned <label> <workdir> — the entries this pool recreates (pristine, base-N,
# mut-N) are removed only from a workdir shmutant marked as its own on first use; a caller's
# directory that happens to carry those names is refused, not emptied.
_shmutant_workdir_owned() {
  local label="$1" wd="$2" line=""
  if [ -f "$wd/.shmutant" ] && [ ! -L "$wd/.shmutant" ]; then
    # The marker carries a recognisable line: a caller's own .shmutant (a config, a sentinel)
    # does not make the pristine, base-N and mut-N entries beside it disposable.
    IFS= read -r -n 64 line < "$wd/.shmutant" 2>/dev/null || :
    [ "$line" = "shmutant workdir" ] && return 0
    _shmutant_err "$label: $wd/.shmutant is not the marker shmutant writes — refusing to treat the workdir as shmutant's"; return 2
  fi
  if [ -e "$wd/.shmutant" ] || [ -L "$wd/.shmutant" ]; then _shmutant_err "$label: $wd/.shmutant is not the regular file shmutant writes — refusing to treat the workdir as shmutant's"; return 2; fi
  # The caller's glob settings neutralised in a subshell, as in shmutant_copy_tree.
  ( set +f; shopt -u failglob; shopt -s nullglob; unset GLOBIGNORE
    for e in "$wd"/pristine "$wd"/base-* "$wd"/mut-*; do
      if [ -e "$e" ] || [ -L "$e" ]; then
        _shmutant_err "$label: $wd holds $(command -p basename -- "$e") but was not created by shmutant (no $wd/.shmutant) — refusing to remove a caller's entries; use an empty workdir"; exit 2
      fi
    done
    printf 'shmutant workdir\n' >| "$wd/.shmutant" 2>/dev/null || { _shmutant_err "$label: cannot mark $wd as a shmutant workdir"; exit 2; } )
}

# _shmutant_report_keep <when> — tell a CLI parent the SHMUTANT_KEEP in force now, on the
# channel it opened; nothing when there is no such parent. <when> only labels the call site.
_shmutant_report_keep() {
  [ -n "${SHMUTANT_CLI_KEEP_FD:-}" ] || return 0
  { printf '%s\n' "${SHMUTANT_KEEP:-0}" >&"$SHMUTANT_CLI_KEEP_FD"; } 2>/dev/null || _shmutant_err "the keep channel could not be written; an interrupt would not know to keep the workdir"
}

# shmutant_pool <label> <workdir> <prepare> <run> [cap] — run every table row. Prepares the
# tree once, runs each distinct selector uninjected (SHMUTANT_BASELINE), then every row through a
# pool of min(SHMUTANT_JOBS or CPUs, cap or 8) workers. Emits the verdict stream and one stderr
# line per row that was not killed. Returns 0 when every row was killed, 1 when any was not,
# 2 when the harness itself could not run (a refused declaration, empty table, bad workdir,
# prepare failed, root outside the workdir, or a verdict-stream write that failed).
shmutant_pool() {
  # Aliases off for the whole pool, callbacks included (their bodies were parsed when defined);
  # the caller's setting is put back on return.
  # Before any local: bash refuses a local over a readonly global, and the assignment that
  # follows would end a non-interactive caller's shell.
  _shmutant_pool_locals_writable pool "the calling shell made" || \builtin return 2
  local rc pool_aliases; _shmutant_aliases_off pool_aliases
  # A plain call, not a condition: a callback's own errexit is honoured inside, as documented.
  _shmutant_pool_body "$@"; rc=$?
  _shmutant_aliases_back "$pool_aliases"
  # The caller's RETURN and DEBUG traps, when the pool held them, go back as this function
  # returns: from its RETURN trap, with the status below already settled.
  [[ -z "${SHMUTANT_TRAPS_PENDING:-}" ]] || builtin trap '_shmutant_traps_last' RETURN
  # builtin: a caller's function named return, refused by the shadow check, must not swallow
  # the status the refusal produced.
  builtin return "$rc"
}
_shmutant_pool_body() {
  if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then _shmutant_err "pool: usage: shmutant_pool <label> <workdir> <prepare> <run> [cap] (got $# arguments)"; return 2; fi
  local label="$1" wd="$2" prep="$3" run="$4" cap="${5:-}"
  local n jobs root suffix i k sel t0 t1 killed=0 rc=0 verdict detail rjrc linked starts ambiguous=0 cwhy
  local -a base_sel=() base_verdict=() base_why=() row_why=()
  n="${#SHMUTANT_ROWS_NAME[@]}"
  t0="$(_shmutant_now)"
  SHMUTANT_EMIT_FAILED=0; SHMUTANT_CLEANUP_FAILED=0
  declare -gA SHMUTANT_DIR_IDS=() SHMUTANT_VERDICT_W=() SHMUTANT_VERDICT_R=() SHMUTANT_ACTIVE_KEY=() SHMUTANT_ACTIVE_ID=()
  declare -gA SHMUTANT_RES_VERDICT=() SHMUTANT_RES_US=() SHMUTANT_RES_STATUS=() SHMUTANT_RES_CLONE=() SHMUTANT_RES_COUNTS=() SHMUTANT_RES_COUNTS_BAD=()
  if [ "${SHMUTANT_DECL_ERRORS:-0}" -ne 0 ]; then
    _shmutant_err "$label: $SHMUTANT_DECL_ERRORS declaration(s) were refused — a table missing rows it was meant to carry proves nothing"
    return 2
  fi
  # The pool cannot run in POSIX mode: a failing `exec` redirection would end the caller's shell
  # instead of returning, and the run wrapper's `exit` function would be refused.
  if [ -o posix ]; then _shmutant_err "$label: shmutant does not run with POSIX mode on (set +o posix)"; return 2; fi
  _shmutant_no_shadows "$label" || builtin return 2
  [ -n "$wd" ] || { _shmutant_err "$label: a workdir is required"; return 2; }
  case "$wd" in *$'\n'*) _shmutant_err "$label: the workdir name contains a newline"; return 2 ;; esac
  command -p mkdir -p -- "$wd" 2>/dev/null || { _shmutant_err "$label: cannot create workdir $wd"; return 2; }
  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "$label: cannot resolve workdir"; return 2; }
  _shmutant_workdir_owned "$label" "$wd" || return 2
  SHMUTANT_WD_ID="$(_shmutant_dir_id "$wd")"
  _shmutant_callable "$prep" || { _shmutant_err "$label: prepare callback not found: $prep (a function or an executable; an alias cannot be called by name, and a builtin such as exit or return would end or leave this shell)"; return 2; }
  _shmutant_callable "$run" || { _shmutant_err "$label: run callback not found: $run (a function or an executable; an alias cannot be called by name, and a builtin such as exit or return would end or leave this shell)"; return 2; }
  # Executables by absolute physical path from here: a prepare that changes the working
  # directory must not change which program the workers run.
  prep="$(_shmutant_pin_callback "$prep")" || { _shmutant_err "$label: prepare callback cannot be resolved to a program: $prep"; return 2; }
  run="$(_shmutant_pin_callback "$run")" || { _shmutant_err "$label: run callback cannot be resolved to a program: $run"; return 2; }
  _shmutant_validate_settings "$label" "$wd" || return 2
  case "$cap" in
    '') ;;
    *[!0-9]*) _shmutant_err "$label: the pool cap must be a positive integer, got [$cap]"; return 2 ;;
    *) if [ "${#cap}" -gt 4 ] || [ "$cap" -lt 1 ]; then _shmutant_err "$label: the pool cap must be a positive integer of at most four digits, got [$cap]"; return 2; fi ;;
  esac
  _shmutant_open_stream "$label" || return 2
  SHMUTANT_PRISTINE_ID=""
  _shmutant_fresh_dir "$wd/pristine" "$wd" || { _shmutant_pool_fail "$label" "$wd"; _shmutant_err "$label: cannot recreate $wd/pristine — stale contents there would be prepared over"; return 2; }
  SHMUTANT_PRISTINE_ID="$(_shmutant_dir_id "$wd/pristine")" || SHMUTANT_PRISTINE_ID=""
  local pout prc errexit_before=0 pout_w pout_r
  # Every exit past this point goes through _shmutant_pool_fail: the stream descriptor is open
  # and pristine exists.
  pout="$(command -p mktemp "$wd/.prepare.XXXXXX" 2>/dev/null)" || { _shmutant_err "$label: cannot create a capture file in $wd"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  # prepare's stdout is captured through descriptors opened here and the file unlinked before
  # prepare runs: what prepare leaves at that name afterwards (a FIFO, a link) is never opened.
  if ! exec {pout_w}>|"$pout" {pout_r}<"$pout"; then
    [ -n "${pout_w:-}" ] && exec {pout_w}>&-
    command -p rm -f -- "$pout"; _shmutant_err "$label: cannot open the capture file in $wd"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  command -p rm -f -- "$pout"
  # Called directly, not in a command substitution and not as a condition: state prepare
  # establishes in this shell must still be there when the workers fork, and its own errexit
  # must keep meaning what it says. The errexit state it leaves behind is put back afterwards.
  # `[ -o errexit ]`, not a pattern over $-: under nocasematch `*e*` would match the E of errtrace.
  [ -o errexit ] && errexit_before=1
  # prepare runs in this function's scope, where bash lets it assign any local by name (`n=0`
  # as its own counter). The bookkeeping still needed afterwards is copied out under names no
  # ordinary callback uses and copied back when it returns.
  local _shmutant_pool_label="$label" _shmutant_pool_wd="$wd" _shmutant_pool_run="$run" _shmutant_pool_cap="$cap"
  local _shmutant_pool_n="$n" _shmutant_pool_t0="$t0" _shmutant_pool_pout_r="$pout_r" _shmutant_pool_pout_w="$pout_w" _shmutant_pool_errexit="$errexit_before" _shmutant_pool_prc=0
  _shmutant_report_keep before-prepare
  # The status goes to the stash as a positional parameter, never through an assignment prepare
  # could have made fatal; the stash holds the traps first: from there to the pool's return a
  # trap prepare installed (or the caller's) sees no child of this shell but the ones that save
  # it, and DEBUG no command past the saves.
  "$prep" "$wd/pristine" >&"$pout_w"; _shmutant_pool_stash "$?" || { exec {_shmutant_pool_pout_w}>&- {_shmutant_pool_pout_r}<&-; _shmutant_pool_fail "$_shmutant_pool_label" "$_shmutant_pool_wd"; return 2; }
  label="$_shmutant_pool_label"; wd="$_shmutant_pool_wd"; run="$_shmutant_pool_run"; cap="$_shmutant_pool_cap"
  # A name of this function's that prepare made readonly (dynamic scope reaches these locals)
  # cannot be restored, and any later assignment to it would end a non-interactive caller's
  # shell: reported from the saved copies, which prepare could not reach.
  if ! _shmutant_pool_locals_writable "$_shmutant_pool_label" "prepare made"; then
    # The prepare capture descriptors, from the saved numbers: a refused pool must not leave
    # two descriptors open in a sourcing caller.
    exec {_shmutant_pool_pout_w}>&- {_shmutant_pool_pout_r}<&-
    _shmutant_pool_fail "$_shmutant_pool_label" "$_shmutant_pool_wd"; return 2
  fi
  n="$_shmutant_pool_n"; t0="$_shmutant_pool_t0"; pout_r="$_shmutant_pool_pout_r"; pout_w="$_shmutant_pool_pout_w"; errexit_before="$_shmutant_pool_errexit"; prc="$_shmutant_pool_prc"
  # POSIX mode again, now for prepare: a mode it turned on would refuse the run wrapper's own
  # `exit` function in every worker, and the rows would read as aborted, not as this error.
  if [[ -o posix ]]; then
    _shmutant_err "$label: prepare turned POSIX mode on (set -o posix) — shmutant does not run in it"
    exec {pout_w}>&- {pout_r}<&-; _shmutant_pool_fail "$label" "$wd"; builtin return 2
  fi
  killed=0; rc=0; ambiguous=0; base_sel=(); base_verdict=(); base_why=(); row_why=()
  if [ "$errexit_before" = 1 ]; then set -e; else set +e; fi
  if [ "$prc" -ne 0 ]; then
    exec {pout_w}>&- {pout_r}<&-
    _shmutant_err "$label: prepare failed (status $prc) — no tree to mutate"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  # printf x then strip it: command substitution trims every trailing newline. Exactly one is
  # then taken as the line terminator `echo` or `printf '%s\n'` writes; a root whose name still
  # holds one is refused below, never trimmed to a sibling.
  root="$(command -p cat <&"$pout_r"; builtin printf x)"; root="${root%x}"; exec {pout_w}>&- {pout_r}<&-
  root="${root%$'\n'}"
  case "$root" in *$'\n'*) _shmutant_err "$label: prepare printed a root whose name contains a newline"; _shmutant_pool_fail "$label" "$wd"; return 2 ;; esac
  # prepare may have defined a function under a builtin's name, or taken the run callback away:
  # checked again before any worker relies on either.
  _shmutant_no_shadows "$label" || { _shmutant_pool_fail "$label" "$wd"; builtin return 2; }
  # The workdir itself: prepare could have renamed it away and put another directory at its
  # path. Nothing there is this pool's, so nothing there is removed (the pristine prepare made
  # in it included).
  if [ -L "$wd" ] || [ "$(_shmutant_dir_id "$wd")" != "${SHMUTANT_WD_ID:-}" ]; then _shmutant_err "$label: $wd is no longer the directory this pool marked as its own — prepare moved or replaced it"; _shmutant_pool_fail "$label" "$wd"; return 2; fi
  _shmutant_callable "$run" || { _shmutant_err "$label: run callback not found after prepare: $run"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  # prepare may have declared rows or had one refused: the table is read again here, and a
  # refusal after prepare is the same harness error as one before it.
  if [ "${SHMUTANT_DECL_ERRORS:-0}" -ne 0 ]; then
    _shmutant_err "$label: $SHMUTANT_DECL_ERRORS declaration(s) were refused — a table missing rows it was meant to carry proves nothing"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  n="${#SHMUTANT_ROWS_NAME[@]}"
  if [ "$n" -eq 0 ]; then _shmutant_err "$label: the mutation table is EMPTY — this harness proves nothing"; _shmutant_pool_fail "$label" "$wd"; return 2; fi
  # prepare ran in this shell and may have assigned any setting; the workers read them next.
  _shmutant_validate_settings "$label" "$wd" || { _shmutant_err "$label: a setting changed by prepare is invalid"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  jobs="$(_shmutant_jobs "$cap")"
  # The settled SHMUTANT_KEEP, for a CLI parent that may have to clean up after an interrupt.
  _shmutant_report_keep after-prepare
  _shmutant_open_stream "$label" || { _shmutant_pool_fail "$label" "$wd"; return 2; }
  SHMUTANT_PRISTINE_ID="$(_shmutant_dir_id "$wd/pristine")" || SHMUTANT_PRISTINE_ID=""
  # The tree's state as prepare left it. A callback that later writes into pristine, adds to
  # it, removes from it or changes a mode changes the fingerprint, and no row is cloned from the
  # tree afterwards; every clone is checked against it after the copy.
  _shmutant_stat_style
  SHMUTANT_PRISTINE_STATE="$(_shmutant_pristine_state "$wd/pristine")" || { _shmutant_err "$label: cannot fingerprint the prepared tree — a stage failed, it holds a regular file whose content cannot be read, or a name with a newline in it"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  [ -n "$root" ] || root="$wd/pristine"
  root="$(_shmutant_abs "$root")" || { _shmutant_err "$label: prepare printed a root that is not a directory"; _shmutant_pool_fail "$label" "$wd"; return 2; }
  if ! _shmutant_inside "$wd/pristine" "$root"; then
    _shmutant_err "$label: prepare printed a root outside the workdir ($root) — refusing to mutate what may be the working tree"; _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  suffix="${root#"$wd/pristine"}"
  for (( i = 0; i < n; i++ )); do
    if ! _shmutant_target_ok "$root" "${SHMUTANT_ROWS_FILE[$i]}"; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}' targets ${SHMUTANT_ROWS_FILE[$i]}, which the prepared tree does not contain as a regular file (missing, a symlink, reached through one that leaves the tree, or through an absolute one that a clone could not keep inside itself)"; _shmutant_pool_fail "$label" "$wd"; return 2
    fi
    # Link count is `ls -l` column 2. A clone gives each hard link its own inode, so a test
    # reading the alias would see pristine code while the named target carries the defect.
    if [ "$(command -p ls -ld -- "$root/${SHMUTANT_ROWS_FILE[$i]}" | command -p awk '{ print $2 }')" -gt 1 ]; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}' targets ${SHMUTANT_ROWS_FILE[$i]}, which has more than one hard link — a clone cannot keep them joined"
      _shmutant_pool_fail "$label" "$wd"; return 2
    fi
    # The old literal starts at one position or none (that row is scored unapplied): the rewrite
    # takes the first, and a row written against a later copy would inject its defect where the
    # row does not mean it. Counted once, in the prepared tree, which every clone is proven to
    # match. Every such row is named before the pool refuses.
    if ! starts="$(_shmutant_starts "$root/${SHMUTANT_ROWS_FILE[$i]}" "${SHMUTANT_ROWS_OLD[$i]}")" || [ -z "$starts" ]; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}': ${SHMUTANT_ROWS_FILE[$i]} could not be read to count its old literal"
      _shmutant_pool_fail "$label" "$wd"; return 2
    fi
    if [ "$starts" -gt 1 ]; then
      _shmutant_err "$label: row '${SHMUTANT_ROWS_NAME[$i]}' is refused: its old literal starts at more than one position in ${SHMUTANT_ROWS_FILE[$i]} — the rewrite takes the first, which may not be the one the row means; lengthen the literal until it occurs once"
      ambiguous=$((ambiguous + 1))
    fi
  done
  if [ "$ambiguous" -ne 0 ]; then
    _shmutant_err "$label: $ambiguous row(s) refused for an old literal that occurs more than once — a table missing rows it was meant to carry proves nothing"
    _shmutant_pool_fail "$label" "$wd"; return 2
  fi
  # And anywhere else in the prepared tree, .git included: the clone (cp -RPp) copies it all
  # and gives every hard link its own inode, so a fixture the tests write through one name and
  # read through another would behave differently in the clone than in the tree prepare built.
  linked="$(builtin cd -- "$wd/pristine" 2>/dev/null && command -p find . -type f -links +1 -print 2>/dev/null)" || linked="?"
  case "$linked" in ?*)
    _shmutant_err "$label: the prepared tree holds a regular file with more than one hard link (${linked%%$'\n'*}) — a clone cannot keep them joined; prepare a tree without them"
    _shmutant_pool_fail "$label" "$wd"; return 2 ;;
  esac

  if [ "${SHMUTANT_BASELINE:-1}" != 0 ]; then
    # With the counts on, the unselected run is base-0: an empty selector, which no row has (a
    # row's defaults to its witness, never empty). It is the reference every selection's counts
    # are compared with, and the longest run, so it starts first.
    [ "${SHMUTANT_COUNTS:-0}" != 1 ] || base_sel=("")
    for (( i = 0; i < n; i++ )); do
      sel="${SHMUTANT_ROWS_SEL[$i]}"
      for k in "${base_sel[@]}"; do [ "$k" = "$sel" ] && continue 2; done
      base_sel+=("$sel")
    done
    SHMUTANT_BASE_SEL=("${base_sel[@]}")
    set +e; _shmutant_run_jobs base "${#base_sel[@]}" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?
    if [ "$errexit_before" = 1 ]; then set -e; fi
    [ "$rjrc" -eq 0 ] || { _shmutant_pool_fail "$label" "$wd"; return 2; }
    for (( k = 0; k < ${#base_sel[@]}; k++ )); do
      SHMUTANT_V_VERDICT="${SHMUTANT_RES_VERDICT[base-$k]:-lost}"; SHMUTANT_V_US="${SHMUTANT_RES_US[base-$k]:-0}"; SHMUTANT_V_STATUS="${SHMUTANT_RES_STATUS[base-$k]:-}"
      case "$SHMUTANT_V_VERDICT" in
        green)   detail="green before injection" ;;
        timeout) detail="did not finish within ${SHMUTANT_TIMEOUT:-300}s before any injection" ;;
        red)     detail="exited $SHMUTANT_V_STATUS (red) before any injection" ;;
        aborted) detail="exited $SHMUTANT_V_STATUS, neither green nor red, before any injection — the selector matched nothing, or the suite aborted" ;;
        *)       detail="$(_shmutant_detail "$SHMUTANT_V_VERDICT" "$SHMUTANT_V_STATUS" "" "${base_sel[$k]}")" ;;
      esac
      # Green is not enough with the counts on: the run must also count, per unit, what the
      # unselected run counts. base-0 is settled first, since every other run is compared with it.
      if [ "${SHMUTANT_COUNTS:-0}" = 1 ] && [ "$SHMUTANT_V_VERDICT" = green ]; then
        cwhy="$(_shmutant_count_check "$k" "${base_verdict[0]:-}")"
        if [ -n "$cwhy" ]; then
          SHMUTANT_V_VERDICT=incomplete
          if [ "$k" -eq 0 ]; then detail="green, but the unselected run cannot be the reference the selections are compared with: $cwhy"
          else detail="green, but the selection is not shown to run what the unselected run runs for its units: $cwhy"; fi
          base_why[k]="$detail"
        elif [ "$k" -eq 0 ]; then detail="green before injection, every test run: the reference for the counts"
        fi
      fi
      base_verdict+=("$SHMUTANT_V_VERDICT")
      _shmutant_emit shmutant 1 baseline "${base_sel[$k]}" "$SHMUTANT_V_VERDICT" "$(_shmutant_secs "$SHMUTANT_V_US")" "$detail"
      [ "$SHMUTANT_V_VERDICT" = green ] || _shmutant_err "$label: baseline [${base_sel[$k]}]: $detail"
    done
  fi

  SHMUTANT_SKIP=()
  for (( i = 0; i < n; i++ )); do
    SHMUTANT_SKIP[i]=0
    for (( k = 0; k < ${#base_sel[@]}; k++ )); do
      if [ "${base_sel[$k]}" = "${SHMUTANT_ROWS_SEL[$i]}" ] && [ "${base_verdict[$k]}" != green ]; then
        SHMUTANT_SKIP[i]=1
        # Recreated although no worker starts: an earlier pool's artifacts under this name would
        # otherwise read as this run's.
        # The workdir first, by identity, as before every worker: the baseline's callback could
        # have moved it away and put a caller's directory, with a mut-N of its own, at its path.
        _shmutant_wd_is_marked "$wd" || { _shmutant_pool_fail "$label" "$wd"; return 2; }
        _shmutant_fresh_dir "$wd/mut-$i" "$wd" || { _shmutant_err "$label: cannot recreate $wd/mut-$i"; _shmutant_pool_fail "$label" "$wd"; return 2; }
        SHMUTANT_RES_VERDICT["mut-$i"]=baseline; SHMUTANT_RES_US["mut-$i"]=0; SHMUTANT_RES_STATUS["mut-$i"]=""
        [ "${base_verdict[$k]}" != incomplete ] || row_why[i]="the baseline of [${base_sel[$k]}] is incomplete (${base_why[$k]:-see its record}) — a result under it would prove nothing"
      fi
    done
  done
  # Bare, status captured after: as a condition, every callback the workers fork would run in
  # an errexit-ignored context. errexit itself is off around it: the caller's `set -e` must
  # neither end this shell on a harness status nor leak into the run callbacks, which own their
  # own errexit.
  set +e; _shmutant_run_jobs mut "$n" "$wd" "$run" "$suffix" "$jobs"; rjrc=$?
  if [ "$errexit_before" = 1 ]; then set -e; fi
  [ "$rjrc" -eq 0 ] || { _shmutant_pool_fail "$label" "$wd"; return 2; }

  for (( i = 0; i < n; i++ )); do
    SHMUTANT_V_VERDICT="${SHMUTANT_RES_VERDICT[mut-$i]:-lost}"; SHMUTANT_V_US="${SHMUTANT_RES_US[mut-$i]:-0}"; SHMUTANT_V_STATUS="${SHMUTANT_RES_STATUS[mut-$i]:-}"
    verdict="$SHMUTANT_V_VERDICT"
    if [ -n "${row_why[$i]:-}" ]; then detail="${row_why[$i]}"
    else detail="$(_shmutant_detail "$verdict" "$SHMUTANT_V_STATUS" "${SHMUTANT_ROWS_WIT[$i]}" "${SHMUTANT_ROWS_SEL[$i]}")"; fi
    _shmutant_emit shmutant 1 row "$verdict" "${SHMUTANT_ROWS_NAME[$i]}" "${SHMUTANT_ROWS_FILE[$i]}" \
      "${SHMUTANT_ROWS_SEL[$i]}" "$(_shmutant_secs "$SHMUTANT_V_US")" "$detail"
    if [ "$verdict" = killed ]; then
      killed=$((killed + 1))
    else
      rc=1
      _shmutant_err "$label: $verdict '${SHMUTANT_ROWS_NAME[$i]}': $detail"
    fi
  done
  t1="$(_shmutant_now)"
  _shmutant_emit shmutant 1 summary "$label" "$n" "$killed" "$jobs" "$(_shmutant_secs "$(( t1 - t0 ))")"
  _shmutant_err "$label: $killed/$n mutation(s) killed on their own witness (jobs=$jobs, $(_shmutant_secs "$(( t1 - t0 ))")s)"
  # Read before _shmutant_pool_fail, which hands the caller's CHLD trap back: the check forks.
  local intact=1; _shmutant_stream_intact || intact=0
  _shmutant_pool_cleanup "$label" "$wd"
  if [ "${SHMUTANT_CLEANUP_FAILED:-0}" -ne 0 ]; then
    _shmutant_err "$label: a worker did not run or finish as promised (a run not set up, a tree not removed, or an output not published) — see above"; rc=2
  elif [ "$intact" -eq 0 ]; then
    _shmutant_err "$label: SHMUTANT_STREAM no longer names the file the records were written to, as they were written (${SHMUTANT_STREAM:-}) — it was removed, replaced, truncated, overwritten or appended to during the run"; rc=2
  elif [ "$SHMUTANT_EMIT_FAILED" -ne 0 ]; then
    _shmutant_err "$label: the verdict stream could not be written (${SHMUTANT_STREAM:-stdout}) — the records above are incomplete"; rc=2
  fi
  # The traps go back only now, with the status settled: nothing of the pool's runs after this
  # but its return.
  _shmutant_release_traps
  return "$rc"
}

# --- CLI ---------------------------------------------------------------------------------------

_shmutant_usage() {
  command -p cat <<'EOF'
usage: shmutant run <plan.sh> [--jobs N] [--workdir DIR] [--keep] [--no-baseline] [--timeout S]
       shmutant version
       shmutant checksum
       shmutant help

A plan is a bash file. It defines two functions, `prepare <dir>` and `run <root> <select>`,
and declares its rows with `shmutant_target` and `shmutant_mut`. It is sourced with
SHMUTANT_PLAN_DIR set to its own directory, in a subshell: a plan that exits, execs or fails
to load ends the run with status 2. Exit: 0 every row killed, 1 a row was not, 2 the plan or
the harness could not run. A workdir the run created is removed afterwards unless --keep (or
SHMUTANT_KEEP=1); a --workdir you supplied is never removed.
EOF
}

# _shmutant_flag_value <flag> <value> — a flag that takes a value has one, and it is not the
# next flag: `--workdir --keep` would otherwise make a directory named `--keep` and drop the
# option. Returns 2 with a message otherwise.
_shmutant_flag_value() {
  case "$2" in
    '') _shmutant_err "$1 needs a value"; return 2 ;;
    -*) _shmutant_err "$1 needs a value, got the option $2"; return 2 ;;
  esac
}

# _shmutant_checksum <file> — the SHA-256 of <file>, from whichever tool the platform has.
# The digest tool's own status is the result: a tool that could not read the file is a
# failure, never an empty digest reported as success.
_shmutant_checksum() {
  local out=""
  # Each candidate an executable file on the standard path, run by that path: a function of
  # the name (inherited, or a caller's) would otherwise be taken for the tool.
  local tool
  if tool="$(_shmutant_std_bin sha256sum)"; then out="$("$tool" -- "$1" 2>/dev/null)"
  elif tool="$(_shmutant_std_bin shasum)"; then out="$("$tool" -a 256 -- "$1" 2>/dev/null)"
  elif tool="$(_shmutant_std_bin openssl)"; then out="$("$tool" dgst -sha256 -- "$1" 2>/dev/null)"; out="${out##* }"
  else _shmutant_err "no sha256sum, shasum or openssl on PATH"; return 2
  fi
  # A tool that could not read the file prints nothing: that is a failure, never an empty digest.
  [ -n "$out" ] || { _shmutant_err "cannot compute the digest of $1"; return 2; }
  printf '%s\n' "${out%% *}"
}

# _shmutant_cli_load <plan-path> — runs in the CLI's plan subshell: load the plan, check its
# callbacks, run the pool. The pool's status is the subshell's, and only a completed pool writes
# the marker the parent reads. Callbacks come from the plan, never from functions exported by the
# invoking environment; the plan is sourced bare, not in an || list, so its own errexit keeps
# meaning what it says.
_shmutant_cli_load() {
  local plan="$1" rc done_w
  # The SHMUTANT_KEEP in force when this subshell ends, whichever way: a plan that assigns it
  # and then leaves while loading (exit, a failure under its errexit) never reaches the pool's
  # own reports, and the parent would read only the seed.
  trap '_shmutant_cli_leave at-exit' EXIT
  # A plan that installs an EXIT trap of its own while loading replaces that one: before each
  # of the plan's commands the report is put back ahead of whatever the plan set, so both run.
  # Only while loading — the pool reports for itself afterwards. functrace: a DEBUG trap set
  # in this function reaches the sourced file's commands only with it.
  local functrace_before=0; [[ -o functrace ]] && functrace_before=1
  unset -f prepare run
  shmutant_reset
  # The completion channel is a descriptor on a file unlinked before
  # the plan's own code runs: nothing the plan does by path can reach it. A
  # plan that writes to the descriptor itself is forging on purpose, and out of scope.
  if ! exec {done_w}>|"$SHMUTANT_CLI_DONE_PATH"; then _shmutant_err "run: cannot open the completion channel"; return 2; fi
  command -p rm -f -- "$SHMUTANT_CLI_DONE_PATH"
  readonly SHMUTANT_CLI_DONE_FD="$done_w"
  # shellcheck disable=SC1090
  # Loaded with stdout on stderr: anything a plan prints while loading is prose, and the CLI's
  # stdout carries verdict records only. The DEBUG guard covers the plan's own commands only.
  set -o functrace
  trap '_shmutant_cli_keep_exit_trap' DEBUG
  # shellcheck disable=SC1090
  . "$plan" >&2
  rc=$?
  trap - DEBUG
  [ "$functrace_before" = 1 ] || set +o functrace
  [ "$rc" -eq 0 ] || { _shmutant_err "run: the plan failed while loading (status $rc)"; return 2; }
  declare -F prepare > /dev/null || { _shmutant_err "run: the plan defines no prepare function"; return 2; }
  declare -F run > /dev/null || { _shmutant_err "run: the plan defines no run function"; return 2; }
  # The plan may have turned errexit on for its own preamble; the pool's non-zero returns are
  # answers, not errors.
  set +o errexit
  shmutant_pool "$(command -p basename -- "$plan")" "$SHMUTANT_CLI_WD" prepare run; rc=$?
  printf '%s %s\n' "$rc" "${SHMUTANT_KEEP:-0}" >&"$SHMUTANT_CLI_DONE_FD"
  return "$rc"
}

# _shmutant_cli_leave <when> — what the plan subshell reports as it leaves, however it leaves:
# the SHMUTANT_KEEP in force, and one last snapshot of its descendants for the parent's
# sampler. The sampler polls twice a second, and a plan that ends inside one poll would
# otherwise leave a helper prepare started unseen — once this shell is gone, that helper is
# nobody's descendant.
_shmutant_cli_leave() {
  _shmutant_report_keep "$1"
  [ -z "${SHMUTANT_CLI_SEEN_W:-}" ] || { _shmutant_snapshot "$BASHPID" >&"$SHMUTANT_CLI_SEEN_W"; } 2>/dev/null
}

# _shmutant_cli_keep_exit_trap — the plan subshell's DEBUG handler while the plan loads: keep
# `_shmutant_cli_leave` at the head of the EXIT trap, ahead of one the plan installed (or put
# it back after the plan removed it), so the keep in force is reported however the plan ends.
_shmutant_cli_keep_exit_trap() {
  local t
  # An exec with a program word replaces this shell without running its EXIT trap: the leave
  # report is made before the command that is about to do that. An exec that only redirects
  # (`exec 3>f`, `exec {fd}>f`, `exec >f`) replaces nothing and is not one.
  case "$BASH_COMMAND" in exec|exec\ [!'{<>&'0-9]*) _shmutant_cli_leave before-exec ;; esac
  t="$(trap -p EXIT)"
  case "$t" in *_shmutant_cli_leave*) return 0 ;; esac
  if [ -z "$t" ]; then trap '_shmutant_cli_leave at-exit' EXIT; return 0; fi
  eval "set -- $t"
  # Expanded now on purpose: the plan's own command text becomes part of the trap.
  # shellcheck disable=SC2064
  trap "_shmutant_cli_leave at-exit; $3" EXIT
}

# _shmutant_cli_wd_is_ours <path> — true while <path> is, by identity, the workdir this run made.
_shmutant_cli_wd_is_ours() {
  [ ! -L "$1" ] && [ "$(_shmutant_dir_id "$1")" = "${SHMUTANT_CLI_WD_ID:-}" ]
}

# _shmutant_cli_end_group <pgid> <holder-pid> — end what the plan subshell left in its process
# group (a helper backgrounded from the plan, a service prepare started), the holder with it.
# The holder keeps the group in being, so its number cannot have been reused; with no live
# holder (the plan never reported one) nothing is signalled by number.
# <holder> is `pid identity` as the plan subshell published it: a holder that went (a plan
# killed it) and a stranger now at its number are told apart, as for a run's holder; with no
# identity readable now the holder is taken as it was, as with no ps at all.
_shmutant_cli_end_group() {
  local hp="${2%% *}" hid=""
  case "$2" in *" "*) hid="${2#* }" ;; esac
  [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null || return 0
  if [ -n "$hid" ] && _shmutant_identity "$hp" > /dev/null; then _shmutant_alive_since "$hp" "$hid" || return 0; fi
  kill -KILL -- -"$1" 2>/dev/null
  kill -KILL "$hp" 2>/dev/null
  return 0
}

# _shmutant_cli_end_sampled <child-spec> — stop the sampler, then freeze and KILL every
# descendant it saw that is still the process it saw (pid:identity, as the runner's leftovers),
# the plan subshell (dead or alive, by its spec) as the root. Nothing when no sample was taken.
_shmutant_cli_end_sampled() {
  local line
  local -a sampled=()
  local -A first=()
  [ -n "${SHMUTANT_CLI_SAMPLER:-}" ] || return 0
  kill -TERM "$SHMUTANT_CLI_SAMPLER" 2>/dev/null; wait "$SHMUTANT_CLI_SAMPLER" 2>/dev/null; SHMUTANT_CLI_SAMPLER=""
  [ -n "${SHMUTANT_CLI_SEEN_R:-}" ] || return 0
  exec {SHMUTANT_CLI_SEEN_W}>&-
  # The identity a pid had when first seen: a later sample of a reused number is not it.
  while IFS= read -r line <&"$SHMUTANT_CLI_SEEN_R"; do
    case "$line" in *:*) [ -n "${first[${line%%:*}]:-}" ] || { first["${line%%:*}"]=1; sampled+=("$line"); } ;; esac
  done
  exec {SHMUTANT_CLI_SEEN_R}<&-; unset SHMUTANT_CLI_SEEN_R SHMUTANT_CLI_SEEN_W
  [ "${#sampled[@]}" -gt 0 ] || return 0
  _shmutant_kill_tree_twice "$1" "${sampled[@]}"
  return 0
}

# _shmutant_cli_abort <signal> — INT or TERM reached the CLI while its plan subshell was running:
# kill the child's tree, remove a workdir this run created, and re-deliver the signal.
_shmutant_cli_abort() {
  local sig="$1"
  # A signal between the spawn and the child's registration is held until the child is known:
  # acted on then, the handler would clean up around a plan subshell it could not end.
  if [ "${SHMUTANT_CLI_SPAWNING:-0}" = 1 ]; then SHMUTANT_CLI_ABORT_PENDING="$sig"; return 0; fi
  # No re-entry: a second signal while this runs (the child's own re-raise reaching the group,
  # a second ^C) would otherwise run this handler again over a channel already consumed.
  trap '' INT TERM
  if [ -n "${SHMUTANT_CLI_CHILD:-}" ]; then
    # TERM first: the pool's own handler ends every running worker's process group by number
    # (which needs no ps) and re-raises; a child that does not go within a few seconds (a plan
    # that ignores TERM) is frozen and killed with what the process table can reach.
    local i
    kill -TERM "$SHMUTANT_CLI_CHILD" 2>/dev/null
    for (( i = 0; i < 50; i++ )); do kill -0 "$SHMUTANT_CLI_CHILD" 2>/dev/null || break; command -p sleep 0.1; done
    # With the identity taken at the spawn: a child that went on TERM and was reaped inside bash
    # may have given its number to someone else by now, who is then neither stopped nor killed.
    # A bare pid when no identity was captured (ps failed at the spawn): the number is still
    # this shell's own unreaped child, which nobody else can have been given.
    if [ -n "${SHMUTANT_CLI_CHILD_ID:-}" ]; then _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD:$SHMUTANT_CLI_CHILD_ID"; else _shmutant_kill_tree_twice "$SHMUTANT_CLI_CHILD"; fi
    wait "$SHMUTANT_CLI_CHILD" 2>/dev/null
  fi
  # The last SHMUTANT_KEEP the plan subshell reported (after loading, and around prepare)
  # decides the workdir here, so a plan or prepare that asked to keep it is honoured.
  local keep_last="" line holder=""
  if [ -n "${SHMUTANT_CLI_KEEP_R:-}" ]; then
    while IFS= read -r line <&"$SHMUTANT_CLI_KEEP_R"; do case "$line" in "holder "*) holder="${line#holder }" ;; *) keep_last="$line" ;; esac; done
  fi
  [ -z "${SHMUTANT_CLI_CHILD:-}" ] || _shmutant_cli_end_group "$SHMUTANT_CLI_CHILD" "$holder"
  [ -z "${SHMUTANT_CLI_HOLD:-}" ] || { exec {SHMUTANT_CLI_HOLD}>&-; SHMUTANT_CLI_HOLD=""; }
  [ -z "${SHMUTANT_CLI_CHILD:-}" ] || _shmutant_cli_end_sampled "$SHMUTANT_CLI_CHILD:${SHMUTANT_CLI_CHILD_ID:-}"
  [ -n "${SHMUTANT_CLI_DONE_FILE:-}" ] && _shmutant_cli_wd_is_ours "${SHMUTANT_CLI_WD_PATH:-}" && command -p rm -f -- "$SHMUTANT_CLI_DONE_FILE"
  if [ -n "${SHMUTANT_CLI_WD_TO_RM:-}" ]; then
    if [ "$keep_last" = 1 ]; then
      _shmutant_err "workdir kept: $SHMUTANT_CLI_WD_TO_RM"
    elif ! _shmutant_cli_wd_is_ours "$SHMUTANT_CLI_WD_TO_RM"; then _shmutant_err "run: refusing to remove $SHMUTANT_CLI_WD_TO_RM — it is no longer the workdir this run created"
    else
      _shmutant_remove "$SHMUTANT_CLI_WD_TO_RM" "${SHMUTANT_CLI_WD_PARENT:-}" || _shmutant_err "run: could not remove the workdir $SHMUTANT_CLI_WD_TO_RM"
    fi
  fi
  trap - INT TERM
  kill "-$sig" "$BASHPID"
}

_shmutant_cli_run() {
  local plan="" wd="" keep=0 made=0 rc done_file marker keep_last="" line plan_holder=""
  # Seeded from the environment for the window before the pool settles the value: an interrupt
  # during plan loading or prepare must not discard artifacts the operator asked to keep.
  [ "${SHMUTANT_KEEP:-0}" = 1 ] && keep=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jobs)        _shmutant_flag_value "$1" "${2:-}" || return 2
                     SHMUTANT_JOBS="$2"; shift 2 ;;
      --workdir)     _shmutant_flag_value "$1" "${2:-}" || return 2
                     wd="$2"; shift 2 ;;
      --timeout)     _shmutant_flag_value "$1" "${2:-}" || return 2
                     case "$2" in ''|*[!0-9]*) _shmutant_err "--timeout: not an integer: $2"; return 2 ;; esac
                     SHMUTANT_TIMEOUT="$2"; shift 2 ;;
      --keep)        keep=1; SHMUTANT_KEEP=1; shift ;;
      --no-baseline) SHMUTANT_BASELINE=0; shift ;;
      -*)            _shmutant_err "unknown option: $1"; _shmutant_usage >&2; return 2 ;;
      *)             [ -z "$plan" ] || { _shmutant_err "one plan only"; return 2; }
                     plan="$1"; shift ;;
    esac
  done
  [ -n "$plan" ] || { _shmutant_err "run: a plan file is required"; _shmutant_usage >&2; return 2; }
  case "$plan$wd" in *$'\n'*) _shmutant_err "run: a path containing a newline is refused"; return 2 ;; esac
  [ -f "$plan" ] || { _shmutant_err "run: plan not found: $plan"; return 2; }
  SHMUTANT_PLAN_DIR="$(_shmutant_abs "$(command -p dirname -- "$plan")")" || { _shmutant_err "run: cannot resolve $plan"; return 2; }
  # A relative TMPDIR is made absolute now, from where the CLI was invoked: the plan or prepare
  # may change directory, and the stream's private copy is made after they ran.
  case "${TMPDIR:-}" in ''|/*) ;; *) TMPDIR="$(_shmutant_abs "$TMPDIR")" || { _shmutant_err "run: TMPDIR does not name a directory ($TMPDIR)"; return 2; }; export TMPDIR ;; esac
  export SHMUTANT_PLAN_DIR
  # Every path is settled, absolute, BEFORE the plan runs: a plan may cd, and a relative
  # --workdir, TMPDIR or SHMUTANT_STREAM must mean what it meant where the operator typed it.
  # SHMUTANT_STREAM is settled by _shmutant_validate_settings below, once the workdir is known.
  if [ -z "$wd" ]; then
    wd="$(command -p mktemp -d "${TMPDIR:-/tmp}/shmutant.XXXXXX")" || { _shmutant_err "run: cannot create a workdir"; return 2; }
    made=1
  else
    command -p mkdir -p -- "$wd" || { _shmutant_err "run: cannot create workdir $wd"; return 2; }
  fi
  wd="$(_shmutant_abs "$wd")" || { _shmutant_err "run: cannot resolve workdir"; return 2; }
  # The plan and the pool run in a SUBSHELL. Whatever a plan does there — exec, exit, a trap, an
  # assignment to any variable — stays there: this shell never executed it, and decides the
  # outcome from the marker only a completed pool writes. No marker means the plan or a callback
  # ended the run before the pool finished, whatever status the subshell reports.
  # Created here and held open for reading; the subshell opens it for writing and unlinks it
  # before the plan loads, so its name is never in the plan's reach.
  done_file="$(command -p mktemp "$wd/.done.XXXXXX")" || { _shmutant_err "run: cannot create a marker in $wd"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2; }
  local done_r
  if ! exec {done_r}<"$done_file"; then _shmutant_err "run: cannot open the completion channel"; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2; fi
  # A signal to this process must not orphan the subshell and its workers: the child's whole
  # tree is killed, the workdir handled, and the signal re-delivered.
  SHMUTANT_CLI_CHILD=""; SHMUTANT_CLI_CHILD_ID=""; SHMUTANT_CLI_WD_TO_RM=""; SHMUTANT_CLI_SPAWNING=0; SHMUTANT_CLI_ABORT_PENDING=""
  [ "$made" = 1 ] && SHMUTANT_CLI_WD_TO_RM="$wd"
  # The workdir's parent, physical, taken before any plan code runs: the removal at the end
  # and on an interrupt is refused if the ancestry no longer resolves to it.
  SHMUTANT_CLI_WD_PARENT="$(_shmutant_abs "$(command -p dirname -- "$wd")")" || SHMUTANT_CLI_WD_PARENT=""
  # The workdir's own identity, taken before the plan runs: it is removed only while the path
  # still names this directory, not whatever a plan put there after moving it away.
  SHMUTANT_CLI_WD_ID="$(_shmutant_dir_id "$wd")"
  # The effective SHMUTANT_KEEP travels on a second channel: the plan subshell and the pool
  # append the value each time it may have changed (after the plan loads, before and after
  # prepare), and an interrupt reads the last one. Unlinked at once: no path names it.
  local keep_file keep_r keep_w
  keep_file="$(command -p mktemp "$wd/.keep.XXXXXX")" || { _shmutant_err "run: cannot create a marker in $wd"; exec {done_r}<&-; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2; }
  if ! exec {keep_w}>|"$keep_file" {keep_r}<"$keep_file"; then
    _shmutant_err "run: cannot open the keep channel"; [ -n "${keep_w:-}" ] && exec {keep_w}>&-; exec {done_r}<&-; command -p rm -f -- "$keep_file" "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2
  fi
  command -p rm -f -- "$keep_file"
  # Seeded with the operator's own setting: an interrupt before the plan reports anything reads
  # that, and every later report is what the run settled since.
  printf '%s\n' "$keep" >&"$keep_w"
  SHMUTANT_CLI_KEEP_R="$keep_r"; SHMUTANT_CLI_DONE_FILE="$done_file"; SHMUTANT_CLI_WD_PATH="$wd"
  # Settings given on the command line or in the environment are checked before the plan's own
  # code runs: a bad --jobs must not first execute a plan.
  if ! _shmutant_validate_settings run "$wd"; then
    exec {keep_w}>&- {keep_r}<&- {done_r}<&-; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2
  fi
  # The hold channel: a FIFO this shell keeps a writing end of, read by a holder in the plan's
  # process group through a reading end of its own (the holder closes the writing end it
  # inherits, or it would keep itself alive). The holder lives until every writer has gone —
  # this shell, which closes it once the group is ended, and whatever the plan left running
  # that inherited it — so it holds no output descriptor and cannot outlive the run, and it
  # keeps the group in being meanwhile. <> first: opening a FIFO to read alone would block.
  local hold hold_r
  if ! command -p mkfifo -- "$done_file.hold" 2>/dev/null || ! exec {hold}<>"$done_file.hold" {hold_r}<"$done_file.hold"; then
    _shmutant_err "run: cannot create the hold channel in $wd"; [ -n "${hold:-}" ] && exec {hold}>&-; command -p rm -f -- "$done_file.hold"; exec {keep_w}>&- {keep_r}<&- {done_r}<&-; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2
  fi
  command -p rm -f -- "$done_file.hold"
  SHMUTANT_CLI_HOLD="$hold"
  trap '_shmutant_cli_abort INT' INT
  trap '_shmutant_cli_abort TERM' TERM
  # Signals are held from here until the child and its identity are registered.
  SHMUTANT_CLI_SPAWNING=1
  # The plan subshell in a process group of its own (job control, for this spawn only), kept
  # in being by the holder until the run is over: what the plan or prepare left running is
  # ended by group number when the run ends, and the holder makes that number unreusable
  # meanwhile. Stdin from /dev/null: a background group reading the terminal would be stopped.
  # Descendants are sampled while the plan subshell lives, as the runner does for a run: one
  # that left the group (a new session) before the subshell ended is still named, with the
  # identity it had, and ended at the end. The samples go to an unlinked file of this shell's.
  local seen_file
  seen_file="$(command -p mktemp "$done_file.seen.XXXXXX")" || { _shmutant_err "run: cannot create the sample file in $wd"; exec {hold}>&- {hold_r}<&- {keep_w}>&- {keep_r}<&- {done_r}<&-; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2; }
  if ! exec {SHMUTANT_CLI_SEEN_W}>|"$seen_file" {SHMUTANT_CLI_SEEN_R}<"$seen_file"; then
    _shmutant_err "run: cannot open the sample file"; command -p rm -f -- "$seen_file"; exec {hold}>&- {hold_r}<&- {keep_w}>&- {keep_r}<&- {done_r}<&-; command -p rm -f -- "$done_file"; [ "$made" = 1 ] && command -p rm -rf -- "$wd"; return 2
  fi
  command -p rm -f -- "$seen_file"
  builtin set -m
  (
    # `trap -p` in a subshell reports the parent's traps although none is active: the pool
    # would save this shell's abort handler as the plan subshell's own and re-raise into it.
    trap - INT TERM
    ( read -r _ <&"$hold_r" ) < /dev/null > /dev/null 2>&1 {keep_w}>&- {keep_r}<&- {hold}>&- & printf 'holder %s %s\n' "$!" "$(_shmutant_identity "$!" 2>/dev/null)" >&"$keep_w"
    readonly SHMUTANT_CLI_WD="$wd" SHMUTANT_CLI_KEEP_FD="$keep_w"
    export SHMUTANT_CLI_KEEP_FD
    SHMUTANT_CLI_DONE_PATH="$done_file"
    _shmutant_cli_load "$SHMUTANT_PLAN_DIR/$(command -p basename -- "$plan")"
  ) < /dev/null & SHMUTANT_CLI_CHILD=$!
  builtin set +m
  # Stopped with TERM: the trap ends the sleep in flight, which would otherwise outlive the run. Its
  # pid is cleared once reaped, so the trap never signals a number that may have been reused since.
  ( trap 'kill "$s" 2>/dev/null; exit 0' TERM; s=""; while kill -0 "$SHMUTANT_CLI_CHILD" 2>/dev/null; do _shmutant_snapshot "$SHMUTANT_CLI_CHILD"; command -p sleep 0.5 & s=$!; wait "$s"; s=""; done ) 1>&"$SHMUTANT_CLI_SEEN_W" 2>/dev/null < /dev/null & SHMUTANT_CLI_SAMPLER=$!
  SHMUTANT_CLI_CHILD_ID="$(_shmutant_identity "$SHMUTANT_CLI_CHILD" 2>/dev/null)" || SHMUTANT_CLI_CHILD_ID=""
  SHMUTANT_CLI_SPAWNING=0
  [ -z "${SHMUTANT_CLI_ABORT_PENDING:-}" ] || { local p="$SHMUTANT_CLI_ABORT_PENDING"; SHMUTANT_CLI_ABORT_PENDING=""; _shmutant_cli_abort "$p"; }
  wait "$SHMUTANT_CLI_CHILD"; rc=$?
  trap - INT TERM
  # The keep channel's last report (before and after prepare), kept for a completion report
  # that did not arrive; and the holder's number, for the group to end.
  exec {keep_w}>&-
  while IFS= read -r line <&"$keep_r"; do case "$line" in "holder "*) plan_holder="${line#holder }" ;; *) keep_last="$line" ;; esac; done
  exec {keep_r}<&-; unset SHMUTANT_CLI_KEEP_R
  _shmutant_cli_end_group "$SHMUTANT_CLI_CHILD" "$plan_holder"
  exec {hold}>&- {hold_r}<&-; SHMUTANT_CLI_HOLD=""
  _shmutant_cli_end_sampled "$SHMUTANT_CLI_CHILD:${SHMUTANT_CLI_CHILD_ID:-}"
  SHMUTANT_CLI_CHILD=""
  marker="$(command -p cat <&"$done_r")"; exec {done_r}<&-
  # The completion path is a name inside the workdir: a plan that moved the workdir away and
  # put a directory of its own there could have put a file of its own at this name.
  if _shmutant_cli_wd_is_ours "$wd"; then command -p rm -f -- "$done_file"; fi
  if [ -n "$marker" ] && [ "${marker%% *}" = "$rc" ]; then
    # The settled SHMUTANT_KEEP (a plan or prepare may have assigned it either way inside the
    # subshell) is what the workers honoured, and what decides the workdir here.
    if [ "${marker#* }" = 1 ]; then keep=1; else keep=0; fi
  else
    case "$rc" in
      2) ;;
      *) _shmutant_err "run: the plan or a callback ended the run before the pool completed (status $rc)" ;;
    esac
    rc=2
    # No completion report says nothing about the settled SHMUTANT_KEEP: the keep channel's
    # last report decides, and with none at all the workdir is kept — what it holds is what a
    # KEEP set by the plan was meant to preserve.
    if [ -z "$keep_last" ] || [ "$keep_last" = 1 ]; then keep=1; fi
  fi
  # Only a workdir this run created is removed. A caller-supplied one is theirs: the pool's own
  # artifacts stay in it and nothing else in it is touched.
  if [ "$keep" = 1 ]; then _shmutant_err "workdir kept: $wd"
  elif [ "$made" = 1 ] && ! _shmutant_cli_wd_is_ours "$wd"; then _shmutant_err "run: refusing to remove $wd — it is no longer the workdir this run created"; rc=2
  elif [ "$made" = 1 ]; then _shmutant_remove "$wd" "${SHMUTANT_CLI_WD_PARENT:-}" || { _shmutant_err "run: could not remove the workdir $wd"; rc=2; }
  fi
  return "$rc"
}

shmutant_main() {
  # This process is the CLI's own. A function of a builtin's name planted before this file ran
  # (BASH_ENV; bash does not import exported functions of those names) would stand in for
  # trap, exec or wait below: every name the harness relies on is unset first, from posix
  # mode, where the special builtin `unset` is found before any function — an assignment enters
  # that mode, so nothing this line trusts can be shadowed.
  _shmutant_drop_builtin_fn
  builtin unset -f kill wait read trap printf mapfile exec command cd pwd exit return declare local unset set shopt eval readonly export shift true false '[' : . type test 2>/dev/null
  # Options inherited through SHELLOPTS/BASHOPTS/POSIXLY_CORRECT (errexit, nounset, noclobber,
  # posix mode) are reset before anything else runs.
  set +e +u +C +o posix; unset POSIXLY_CORRECT
  \builtin shopt -u expand_aliases
  case "${1:-}" in
    run)          shift; _shmutant_cli_run "$@" ;;
    version)      printf 'shmutant %s\n' "$SHMUTANT_VERSION" ;;
    checksum)     _shmutant_checksum "${BASH_SOURCE[0]}" ;;
    help|-h|--help) _shmutant_usage ;;
    '')           _shmutant_usage >&2; return 2 ;;
    *)            _shmutant_err "unknown command: $1"; _shmutant_usage >&2; return 2 ;;
  esac
}

# Through the builtins: a caller's function named eval or unset would otherwise stand in for
# the restore (the shadow check refuses those at the entry points, not here).
\builtin eval "$_shmutant_alias_state"; \builtin unset -v _shmutant_alias_state

# The [[ keyword, like the bootstrap: a caller's function named [ or test decides neither whether
# this file is the script being run nor what the CLI exits with. \builtin: the line above put
# the invoking environment's aliases back, and this is parsed after it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shmutant_main "$@"
  \builtin exit $?
fi
