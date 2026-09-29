#!/usr/bin/env bash
# ai-dev-baseline — a practice split into its rule and its procedure loses nothing and duplicates
# nothing, per agent (#434).
#
# Usage: bash scripts/check-practice-split.sh [--self-test]
#
# Default: verify the tracked tree. For every agent and every base/practices/*.md except the index,
# an independent walker splits the source into its rule lines and its procedure lines (per-agent
# blocks resolved), then requires:
#   * the practice's root-doc section to be exactly the rule lines, plus one pointer line when the
#     practice has a procedure;
#   * that pointer to name `<manifest destination>/<practice>`, the destination read from
#     adb_agent_manifest with HOME spelled `~`, so root doc and installer cannot disagree;
#   * the procedure lines to be exactly the body of ONE procedure file — agents/claude/rules/ with
#     matching `paths:` frontmatter when Claude and the practice declares `adb:paths`, else
#     agents/<agent>/reference/ with no frontmatter — and no procedure file for a practice without one;
#   * no file in those trees that no practice produced, and no rules/ tree for any agent but Claude.
# It prints what it checked. A source line containing only `---` is refused: it is the separator the
# root-doc sections are split on.
#
# --self-test: additionally drive the build grammar red on fixtures under a `mktemp -d` (unclosed,
# malformed, nested and misplaced markers; `adb:paths` misuse) and mutate copies of the tracked
# outputs, requiring this verifier to go red on each. Never writes the tracked tree.
#
# Exit: 0 pass · 1 fail · 2 usage

# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -uo pipefail

SELF_TEST=0
case "${1:-}" in
  '') ;;
  --self-test) SELF_TEST=1 ;;
  -h|--help) adb_usage "$0"; exit 0 ;;
  *) printf 'check-practice-split: unknown argument %s\n' "$(adb_display_value "$1")" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

AGENTS='claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md'
POINTER_PREFIX='**Procedure:** '

# split_source <agent> <practice> <rule-out> <proc-out> — the independent oracle: rule lines and
# procedure lines of <practice> as <agent> receives them. Assumes a grammar build.sh accepted.
split_source() {
  awk -v agent="$1" -v rfile="$3" -v pfile="$4" '
    BEGIN { printf "" > rfile; printf "" > pfile }
    /^<!-- adb:paths / { next }
    /^<!-- adb:procedure -->$/ { proc = 1; next }
    /^<!-- adb:except / {
      exc = 1; excluded = 0
      for (i = 3; i < NF; i++) if ($i == agent) excluded = 1
      next
    }
    /^<!-- adb:end -->$/ { if (exc) { exc = 0; excluded = 0 } else proc = 0; next }
    { if (exc && excluded) next; if (proc) print > pfile; else print > rfile }
  ' "$2"
}

# paths_of <practice> — its `adb:paths` globs, one per line.
paths_of() { sed -n 's/^<!-- adb:paths \(.*\) -->$/\1/p' "$1" | tr ' ' '\n'; }

# manifest_dest <root> <agent> <generated-dir> — where the manifest installs that tree, HOME as `~`.
manifest_dest() {
  local m src dest
  m="$(adb_agent_manifest "$2" "$1" '~')" || return 1
  while IFS=$'\t' read -r src dest; do
    [ "$src" = "$3" ] && { printf '%s\n' "$dest"; return 0; }
  done <<< "$m"
  return 1
}

# verify_tree <root> — the checks in the header, against the tree at <root>. Reports each defect
# with `bad`; prints what it covered.
verify_tree() {
  local r="$1" scratch pair agent doc f name i nsec procs ptrs body want dir other dest line
  local -a practices=() sections=()
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/practice-split.XXXXXX")" || { bad "verify: mktemp failed"; return; }
  for f in "$r"/base/practices/*.md; do
    [ -f "$f" ] || continue
    case "${f##*/}" in 00-index.md) continue ;; esac
    if grep -qx -- '---' "$f"; then
      bad "${f##*/}: carries a bare --- line, the separator root-doc sections are split on"
      continue
    fi
    practices+=("$f")
  done
  [ "${#practices[@]}" -gt 0 ] || { bad "verify: base/practices named no practice under $r"; rm -rf "$scratch"; return; }
  procs=0; ptrs=0

  for pair in $AGENTS; do
    agent="${pair%%:*}"; doc="$r/agents/$agent/${pair#*:}"
    if [ ! -f "$doc" ]; then bad "$agent: no root doc at ${doc#"$r"/}"; continue; fi
    # One file per section: the text between `---` separators, in order.
    rm -f "$scratch"/sec.*
    awk -v d="$scratch" 'BEGIN { n = 0 } $0 == "---" { n++; next } { print > (d "/sec." n) }' "$doc"
    nsec=0
    while [ -e "$scratch/sec.$((nsec + 1))" ]; do nsec=$((nsec + 1)); done
    # sec.0 is the header and sec.<nsec> the footer; everything between is one practice each.
    eq "$((nsec - 1))" "${#practices[@]}" "$agent: the root doc carries one section per practice"
    [ "$((nsec - 1))" -eq "${#practices[@]}" ] || continue

    i=0
    for f in "${practices[@]}"; do
      i=$((i + 1)); name="${f##*/}"
      split_source "$agent" "$f" "$scratch/rule" "$scratch/proc"
      # The render wraps each section as: one blank line, the rule lines, then (blank, pointer)
      # when there is a procedure, then two blank lines before the next separator.
      mapfile -t sections < "$scratch/sec.$i"
      if [ "${#sections[@]}" -lt 3 ] || [ -n "${sections[0]}" ] || [ -n "${sections[-1]}" ] || [ -n "${sections[-2]}" ]; then
        bad "$agent/$name: its root-doc section is not framed by the separator's blank lines"
        continue
      fi
      sections=("${sections[@]:1:${#sections[@]}-3}")
      line=""
      if [ "${#sections[@]}" -ge 2 ] && [ "${sections[-1]#"$POINTER_PREFIX"}" != "${sections[-1]}" ] && [ -z "${sections[-2]}" ]; then
        line="${sections[-1]}"
        sections=("${sections[@]:0:${#sections[@]}-2}")
      fi
      # Every comparison captures with a sentinel: `$(…)` strips trailing newlines, which would make
      # an added or dropped final blank line invisible.
      body="$(if [ "${#sections[@]}" -gt 0 ]; then printf '%s\n' "${sections[@]}"; fi; printf x)"
      eq "$body" "$(cat "$scratch/rule"; printf x)" "$agent/$name: the root-doc section is exactly the practice's rule lines"

      # Where the procedure must live for this agent, and where it must not.
      dir="reference"; other="rules"
      if [ "$agent" = claude ] && [ -n "$(paths_of "$f")" ]; then dir="rules"; other="reference"; fi
      if ! grep -Fqx -- '<!-- adb:procedure -->' "$f"; then
        [ -z "$line" ] && ok || bad "$agent/$name: the root doc carries a procedure pointer, but the practice has no procedure"
        for dir in reference rules; do
          [ ! -e "$r/agents/$agent/$dir/$name" ] && ok \
            || bad "$agent/$name: agents/$agent/$dir/$name exists, but the practice has no procedure (orphaned output)"
        done
        continue
      fi
      procs=$((procs + 1))
      [ ! -e "$r/agents/$agent/$other/$name" ] && ok \
        || bad "$agent/$name: the procedure is ALSO at agents/$agent/$other/$name — it must render exactly once"
      if [ ! -f "$r/agents/$agent/$dir/$name" ]; then
        bad "$agent/$name: no procedure file at agents/$agent/$dir/$name"
        continue
      fi
      # The WHOLE file, byte for byte: the scope frontmatter exactly when it is a path-scoped rule,
      # the generated banner, the practice's title, then exactly the procedure lines.
      want="$(
        if [ "$dir" = rules ]; then
          printf -- '---\npaths:\n'
          paths_of "$f" | while IFS= read -r g; do printf '  - "%s"\n' "$g"; done
          printf -- '---\n\n'
        fi
        printf '<!-- GENERATED FILE — do not edit by hand.\n'
        printf '     Source: base/practices/%s · Regenerate: scripts/build.sh\n' "$name"
        printf '     Edits here are overwritten on the next build. -->\n\n'
        printf '# %s — procedure\n' "$(sed -n '1s/^# //p' "$f")"
        cat "$scratch/proc"
        printf x)"
      eq "$(cat "$r/agents/$agent/$dir/$name"; printf x)" "$want" \
        "$agent/$name: the procedure file is exactly its header, its title and the practice's procedure lines"

      # The pointer is exactly the line naming the installed path the manifest links.
      if [ -z "$line" ]; then bad "$agent/$name: the practice has a procedure, but its root-doc section ends in no pointer"; continue; fi
      ptrs=$((ptrs + 1))
      dest="$(manifest_dest "$r" "$agent" "$r/agents/$agent/$dir")" \
        || { bad "$agent/$name: the install manifest names no destination for agents/$agent/$dir"; continue; }
      if [ "$dir" = rules ]; then
        want=""
        while IFS= read -r g; do want="${want:+$want or }\`$g\`"; done < <(paths_of "$f")
        want="${POINTER_PREFIX}\`$dest/$name\` — loads on its own when you read a file matching $want; read it directly when this practice applies otherwise."
      else
        want="${POINTER_PREFIX}\`$dest/$name\` — read it when this practice applies."
      fi
      eq "$line" "$want" "$agent/$name: the pointer is exactly the line naming the installed path"
    done

    # Nothing in the generated trees that no practice produced.
    for dir in reference rules; do
      [ -d "$r/agents/$agent/$dir" ] || continue
      if [ "$dir" = rules ] && [ "$agent" != claude ]; then
        bad "$agent: agents/$agent/rules/ exists — only Claude has a path-scoped rules surface"
      fi
      for f in "$r/agents/$agent/$dir"/* "$r/agents/$agent/$dir"/.*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in .|..) continue ;; esac
        [ -f "$r/base/practices/${f##*/}" ] && [ "${f##*/}" != 00-index.md ] && ok \
          || bad "$agent: agents/$agent/$dir/${f##*/} has no source practice (orphaned output)"
      done
    done
  done
  rm -rf "$scratch"
  printf 'check-practice-split: checked %s practice(s) x %s agent(s) under %s: %s procedure file(s), %s pointer(s)\n' \
    "${#practices[@]}" "$(printf '%s\n' $AGENTS | grep -c .)" "$r" "$procs" "$ptrs"
}

verify_tree "$ROOT"

if [ "$SELF_TEST" -eq 1 ]; then
  work="$(mktemp -d)" || { echo "check-practice-split: mktemp failed" >&2; exit 1; }
  check_exit_guard "check-practice-split" "rm -rf \"$work\""

  # ---------------- 1. the verifier goes red on each defect it exists to catch -----------------
  # tree_copy <dst> — the inputs verify_tree reads, and nothing else.
  tree_copy() {
    mkdir -p "$1/base" "$1/scripts" "$1/agents" || return 1
    cp -R "$ROOT/base/practices" "$1/base/" || return 1
    cp -R "$ROOT/scripts/lib" "$1/scripts/" || return 1
    local a
    for a in claude codex gemini; do
      mkdir -p "$1/agents/$a" || return 1
      cp "$ROOT/agents/$a/"*.md "$1/agents/$a/" || return 1
      if [ -d "$ROOT/agents/$a/reference" ]; then cp -R "$ROOT/agents/$a/reference" "$1/agents/$a/" || return 1; fi
      if [ -d "$ROOT/agents/$a/rules" ]; then cp -R "$ROOT/agents/$a/rules" "$1/agents/$a/" || return 1; fi
    done
    return 0
  }
  # red <label> <mutator-fn> <witness> — the mutated copy must make verify_tree report a defect
  # whose message carries <witness>; red for another reason is not evidence.
  red() {
    local d="$work/tree-$1" before after
    tree_copy "$d" || { bad "$1: could not copy the tree"; return; }
    "$2" "$d" || { bad "$1: the mutation did not apply"; return; }
    before="$fail"
    verify_tree "$d" > /dev/null 2>"$d.err"
    after="$fail"
    fail="$before"
    if [ "$after" -gt "$before" ] && grep -Fq -- "$3" "$d.err"; then ok; else
      bad "MUTATION $1 DID NOT FIRE on its witness [$3]: $(head -n1 "$d.err")"
    fi
  }
  first_ref() { ls "$1/agents/codex/reference" | head -n1; }
  m_drop_para()  { local p; p="$1/agents/codex/reference/$(first_ref "$1")"; awk 'seen && !d && /[a-z]/ { d = 1; next } / — procedure$/ { seen = 1 } { print }' "$p" > "$p.x" && mv "$p.x" "$p"; }
  m_dup_into_root() { local p l; p="$1/agents/codex/reference/$(first_ref "$1")"; l="$(awk 'seen && length($0) > 30 { print; exit } / — procedure$/ { seen = 1 }' "$p")"; [ -n "$l" ] || return 1; awk -v l="$l" '{ print } /^\*\*Procedure:\*\* / && !x { print l; x = 1 }' "$1/agents/codex/AGENTS.md" > "$1/x" && mv "$1/x" "$1/agents/codex/AGENTS.md"; }
  m_rm_proc()    { rm "$1/agents/gemini/reference/$(first_ref "$1")"; }
  m_orphan()     { printf '# stray\n' > "$1/agents/codex/reference/zz-stray.md"; }
  m_twice()      { local f; f="$(ls "$1/agents/claude/rules" | head -n1)"; [ -n "$f" ] || return 1; cp "$1/agents/claude/rules/$f" "$1/agents/claude/reference/$f"; }
  m_pointer()    { sed 's|~/\.codex/ai-dev-baseline/reference/|~/.codex/reference/|' "$1/agents/codex/AGENTS.md" > "$1/x" && mv "$1/x" "$1/agents/codex/AGENTS.md"; }
  m_no_paths()   { local f; f="$(ls "$1/agents/claude/rules" | head -n1)"; [ -n "$f" ] || return 1; sed '/^paths:$/,/^---$/d' "$1/agents/claude/rules/$f" > "$1/x" && mv "$1/x" "$1/agents/claude/rules/$f"; }
  m_rules_codex() { mkdir -p "$1/agents/codex/rules"; }
  m_pointer_extra() { awk '/^\*\*Procedure:\*\* / && !x { $0 = $0 " Or `~/.codex/elsewhere/x.md`."; x = 1 } { print }' "$1/agents/codex/AGENTS.md" > "$1/x" && mv "$1/x" "$1/agents/codex/AGENTS.md"; }
  m_trail_blank() { printf '\n' >> "$1/agents/codex/reference/$(first_ref "$1")"; }
  m_prefix_text() { local p; p="$1/agents/codex/reference/$(first_ref "$1")"; { printf 'INJECTED BEFORE THE HEADER\n'; cat "$p"; } > "$p.x" && mv "$p.x" "$p"; }
  m_rule_blank() { awk '/^\*\*Procedure:\*\* / && !x { print ""; x = 1 } { print }' "$1/agents/gemini/GEMINI.md" > "$1/x" && mv "$1/x" "$1/agents/gemini/GEMINI.md"; }
  m_source_edit() { local f; f="$(ls "$1/agents/codex/reference" | head -n1)"; printf '\nADDED-TO-SOURCE\n' >> "$1/base/practices/$f"; }

  # Control first: an unmutated copy must verify clean, or every row below proves nothing.
  d="$work/tree-control"; tree_copy "$d" || bad "control: could not copy the tree"
  before="$fail"; verify_tree "$d" > /dev/null; eq "$fail" "$before" "control: an unmutated copy of the tree verifies clean"

  red drop-paragraph   m_drop_para     "the procedure file is exactly its header"
  red dup-into-root    m_dup_into_root "section is exactly the practice's rule lines"
  red removed-proc     m_rm_proc       "no procedure file at"
  red orphan           m_orphan        "has no source practice"
  red rendered-twice   m_twice         "it must render exactly once"
  red wrong-pointer    m_pointer       "the pointer is exactly the line naming the installed path"
  red pointer-extra    m_pointer_extra "the pointer is exactly the line naming the installed path"
  red lost-paths       m_no_paths      "the procedure file is exactly its header"
  red trailing-blank   m_trail_blank   "the procedure file is exactly its header"
  red text-before-head m_prefix_text   "the procedure file is exactly its header"
  red rule-blank-added m_rule_blank    "section is exactly the practice's rule lines"
  red rules-for-codex  m_rules_codex   "only Claude has a path-scoped rules surface"
  red stale-render     m_source_edit   "section is exactly the practice's rule lines"

  # ---------------- 2. the build grammar is loud on every malformed spelling ------------------
  mkfixture() {
    mkdir -p "$1/scripts/lib" "$1/base/practices" "$1/base/workflows" || return 1
    cp "$ROOT/scripts/build.sh" "$1/scripts/build.sh" || return 1
    cp "$ROOT/scripts/lib/common.sh" "$1/scripts/lib/common.sh" || return 1
    printf '# index\n' > "$1/base/practices/00-index.md"
    printf -- '---\nname: fixture\ndescription: a fixture workflow\n---\n\n# /fixture\n\nbody\n' > "$1/base/workflows/fixture.md"
  }
  run_build() { ( cd "$1" && bash scripts/build.sh ) > "$1/build.log" 2>&1; }
  # refused <label> <practice-body> <message-fragment> [workflow-tail] — the build fails loud and
  # publishes nothing from the faulty source: no root doc, or with a workflow tail, no skill.
  refused() {
    local d="$work/g-$1" rc art="agents/claude/CLAUDE.md"
    mkfixture "$d" || { bad "$1: fixture"; return; }
    printf '%s' "$2" > "$d/base/practices/10-fixture.md"
    if [ -n "${4:-}" ]; then
      printf '%s' "$4" >> "$d/base/workflows/fixture.md"
      art="agents/claude/skills/fixture/SKILL.md"
    fi
    run_build "$d"; rc=$?
    eq "$rc" "3" "$1: fails the build loud (rc 3)"
    has "$(cat "$d/build.log")" "$3" "$1: the diagnostic names the real problem"
    [ ! -e "$d/$art" ] && ok || bad "$1: $art was published anyway"
  }
  refused unclosed '# p

RULE
<!-- adb:procedure -->

PROC
' 'unterminated `adb:procedure`'
  has "$(cat "$work/g-unclosed/build.log")" "10-fixture.md" "unclosed: the diagnostic names the file"
  refused malformed '# p
<!-- adb:procedure-->
X
<!-- adb:end -->
' 'malformed `adb:procedure` marker'
  refused nested '# p
<!-- adb:procedure -->
<!-- adb:procedure -->
X
<!-- adb:end -->
<!-- adb:end -->
' 'nested `adb:procedure`'
  refused in-except '# p
<!-- adb:except claude -->
<!-- adb:procedure -->
X
<!-- adb:end -->
<!-- adb:end -->
' 'inside the `adb:except` block'
  refused empty '# p
<!-- adb:procedure -->

<!-- adb:end -->
' 'empty `adb:procedure` block'
  refused in-workflow '# p
' 'is a practice marker' '
<!-- adb:procedure -->
X
<!-- adb:end -->
'
  refused paths-malformed '# p
<!-- adb:paths -->
<!-- adb:procedure -->
X
<!-- adb:end -->
' 'malformed `adb:paths` marker'
  refused paths-twice '# p
<!-- adb:paths *.sh -->
<!-- adb:paths *.py -->
<!-- adb:procedure -->
X
<!-- adb:end -->
' 'a second `adb:paths` marker'
  refused paths-in-block '# p
<!-- adb:procedure -->
<!-- adb:paths *.sh -->
X
<!-- adb:end -->
' 'inside a block'
  refused paths-backslash '# p
<!-- adb:paths photos\[2024/** -->
<!-- adb:procedure -->
X
<!-- adb:end -->
' 'carries a backslash or backtick'
  refused paths-backtick '# p
<!-- adb:paths a`b -->
<!-- adb:procedure -->
X
<!-- adb:end -->
' 'carries a backslash or backtick'
  refused paths-in-workflow '# p
' 'is a practice marker' '
<!-- adb:paths *.sh -->
'
  refused paths-no-procedure '# p
<!-- adb:paths *.sh -->

RULE
' 'has no `adb:procedure` block'

  # ------- 3. an except block nested in a procedure resolves per agent, on the tree verifier -------
  d="$work/g-nest-ok"
  mkfixture "$d" || bad "nest-ok: fixture"
  printf '# p\n<!-- adb:paths **/*.sh -->\n\nRULE-LINE\n<!-- adb:procedure -->\n\nSHARED-PROC\n<!-- adb:except claude -->\n\nCODEX-ONLY\n<!-- adb:end -->\n<!-- adb:end -->\n\nMORE-RULE\n' \
    > "$d/base/practices/10-fixture.md"
  run_build "$d"; yes "$?" "nest-ok: an except block nested in a procedure builds"
  has   "$(cat "$d/agents/codex/reference/10-fixture.md" 2>/dev/null)" "CODEX-ONLY" "nest-ok: codex's procedure keeps its block"
  hasnt "$(cat "$d/agents/claude/rules/10-fixture.md" 2>/dev/null)" "CODEX-ONLY" "nest-ok: claude's procedure drops it"
  hasnt "$(cat "$d/agents/codex/AGENTS.md" 2>/dev/null)" "SHARED-PROC" "nest-ok: the root doc carries no procedure text"
  has   "$(cat "$d/agents/codex/AGENTS.md" 2>/dev/null)" "MORE-RULE" "nest-ok: rule text after a procedure block stays in the root doc"
  before="$fail"; verify_tree "$d" > /dev/null; eq "$fail" "$before" "nest-ok: the fixture build verifies clean"

  # ------- 4. MUTATION: a renderer that stops splitting is caught by the tree verifier ----------
  d="$work/mut-nosplit"
  mkfixture "$d" || bad "mut-nosplit: fixture"
  split_line='if (emit && (class == "" || (class == "procedure") == proc)) print'
  eq "$(grep -Fc -- "$split_line" "$d/scripts/build.sh")" "1" "mut-nosplit: the split line is unique in build.sh"
  if check_mutate_literal "$d/scripts/build.sh" "$split_line" 'if (emit) print'; then
    printf '# p\n\nRULE-LINE\n<!-- adb:procedure -->\n\nPROC-LINE\n<!-- adb:end -->\n' > "$d/base/practices/10-fixture.md"
    run_build "$d" || bad "mut-nosplit: the mutated build failed — the mutation broke the script rather than its split"
    before="$fail"; verify_tree "$d" > /dev/null 2>&1; after="$fail"; fail="$before"
    if [ "$after" -gt "$before" ]; then ok; else bad "MUTATION nosplit DID NOT FIRE: a renderer copying procedures into the root doc verified clean"; fi
  fi
fi

check_summary "check-practice-split"
