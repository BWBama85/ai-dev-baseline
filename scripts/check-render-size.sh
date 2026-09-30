#!/usr/bin/env bash
# ai-dev-baseline — scripts/render-size.sh must be seen going RED (#359, #432).
#
# Usage: bash scripts/check-render-size.sh   (exit 0 = pass, 1 = fail)
#
# render-size.sh reports; the only thing it can FAIL on is mechanics, and that arm's failure mode
# is silence — an enumeration that quietly stopped deriving the expected set prints a clean report
# of whatever happens to exist. So every mechanical rule is driven red against a throwaway fixture
# tree, and the size rules are driven the other way: an artifact made arbitrarily large must still
# exit 0, because there is no ceiling.
#
# The measurements #432 and #436 added are guarded the same way, and each is OBSERVED FAILING on a
# mutated copy of the command: a fenced-comment count that ignores fences, a `--since` half that
# measures the working tree instead of the ref, a descriptions figure that counts the key, and a
# description reader that passes a skill with no description line as zero words, and a description
# pipeline that answers for its last stage alone, must each turn a named assertion below red — the
# SAME assertion function the green run uses, re-run against the mutant in a subshell, with its own
# `FAIL:` line as the witness. Inline rather than a `--mutation` pool row (the check-build-atomic.sh
# shape): five rows, seconds each, and no new registry, gate or nightly entry.
#
# Never touches the tracked tree — every case builds its own fixture under one `mktemp -d`,
# including the git repositories the `--since` cases need.

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

REPO="$PWD"
WORK="$(mktemp -d)" || { echo "check-render-size: FATAL — cannot create a scratch directory" >&2; exit 1; }
check_exit_guard "check-render-size" "rm -rf \"$WORK\""
# Every fixture lives under $WORK. One that is NOT a repository must read as "not a git repository"
# even when $TMPDIR itself sits inside one, so discovery stops at $WORK: git will not climb into a
# ceiling directory, and it compares resolved paths, hence the physical form.
GIT_CEILING_DIRECTORIES="$(canon "$WORK")"; export GIT_CEILING_DIRECTORIES
# Where the command stages the artifacts of a ref — so a leaked scratch directory is visible.
mkdir -p "$WORK/tmp" || { echo "check-render-size: FATAL — cannot create the scratch TMPDIR" >&2; exit 1; }
export TMPDIR="$WORK/tmp"

# mk_fixture <name> — a minimal tree with the shape render-size.sh derives from. Prints its root.
# Two workflow sources plus a README (which must yield no rows), three agents, nine artifacts.
mk_fixture() {
  local fx="$WORK/$1" agent name
  mkdir -p "$fx/scripts/lib" "$fx/base/workflows" || return 1
  cp "$REPO/scripts/render-size.sh" "$fx/scripts/render-size.sh" || return 1
  cp "$REPO/scripts/skill-description.awk" "$fx/scripts/skill-description.awk" || return 1
  cp "$REPO/scripts/lib/common.sh" "$fx/scripts/lib/common.sh" || return 1
  for name in alpha beta README; do
    printf 'source %s\n' "$name" > "$fx/base/workflows/$name.md" || return 1
  done
  for agent in claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md; do
    mkdir -p "$fx/agents/${agent%%:*}" || return 1
    printf 'root doc for %s\nsecond line\n' "${agent%%:*}" > "$fx/agents/${agent%%:*}/${agent#*:}" || return 1
    for name in alpha beta; do
      mkdir -p "$fx/agents/${agent%%:*}/skills/$name" || return 1
      printf -- '---\nname: %s\ndescription: use %s in a fixture\n---\n\nbody words here\n' "$name" "$name" > "$fx/agents/${agent%%:*}/skills/$name/SKILL.md" || return 1
    done
  done
  printf '%s\n' "$fx"
}

# write_fenced <file> — the issue's own fixture: 3 `#` lines inside one bash fence, 2 outside.
write_fenced() {
  cat > "$1" <<'EOF'
---
name: alpha
description: use alpha in a fixture
---
# a heading is not a comment
prose, then a fence:
```bash
# one
echo hi   # a trailing comment is not a comment LINE
  # two
# three
```
# a second heading
EOF
}

# mk_since_repo <name> — mk_fixture committed three times: c0 holds only a README (no agents/ yet),
# c1 the fixture tree, c2 grows claude's alpha skill by 10 lines and adds a third workflow, gamma,
# with its three skills. HEAD is c2. Prints the root.
mk_since_repo() {
  local fx agent
  fx="$(mk_fixture "$1")" || return 1
  printf 'readme\n' > "$fx/README.md" || return 1
  check_git "$fx" init -q -b main >/dev/null 2>&1 || return 1
  check_git "$fx" add README.md >/dev/null 2>&1 || return 1
  check_git "$fx" commit -q -m c0 >/dev/null 2>&1 || return 1
  check_git "$fx" add -A >/dev/null 2>&1 || return 1
  check_git "$fx" commit -q -m c1 >/dev/null 2>&1 || return 1
  awk 'BEGIN { for (i = 0; i < 10; i++) print "a grown line" }' >> "$fx/agents/claude/skills/alpha/SKILL.md" || return 1
  printf 'source gamma\n' > "$fx/base/workflows/gamma.md" || return 1
  for agent in claude codex gemini; do
    mkdir -p "$fx/agents/$agent/skills/gamma" || return 1
    printf -- '---\nname: gamma\ndescription: use gamma in a fixture\n---\n\nnew body\n' > "$fx/agents/$agent/skills/gamma/SKILL.md" || return 1
  done
  check_git "$fx" add -A >/dev/null 2>&1 || return 1
  check_git "$fx" commit -q -m c2 >/dev/null 2>&1 || return 1
  printf '%s\n' "$fx"
}

# run_rs <fixture-root> [arg…] — run the copied command; set RS_OUT / RS_ERR / RS_RC. The raw
# stdout stays in $WORK/out for the assertions that need the final byte.
run_rs() {
  local root="$1"; shift
  RS_RC=0
  ( cd "$root" && bash scripts/render-size.sh "$@" ) >"$WORK/out" 2>"$WORK/err" || RS_RC=$?
  RS_OUT="$(cat "$WORK/out")"
  RS_ERR="$(cat "$WORK/err")"
}

# col <name> <field> — field <field> of the row whose name is <name>, from the last run.
col() { printf '%s\n' "$RS_OUT" | awk -F'\t' -v n="$1" -v i="$2" '$1 == n { print $i }'; }

# rows_with_fields <n> — how many rows do NOT have exactly <n> TAB fields.
rows_not_fields() { printf '%s\n' "$RS_OUT" | awk -F'\t' -v n="$1" 'NF != n' | wc -l | tr -d ' '; }

ALPHA=agents/claude/skills/alpha/SKILL.md

# The assertions the mutations must turn red. ONE function each, so the green run and the
# mutant run the identical witness — a mutation that only compares the mutant's value to a number
# of its own would stay green if the assertion it claims to protect were weakened or deleted.
FENCED_WITNESS="fenced: 3 # lines inside the fence and 2 outside count 3"
assert_fenced_three() { eq "$(col "$ALPHA" 5)" "3" "$FENCED_WITNESS"; }
GROWN_WITNESS="since: the skill that grew by 10 lines reports delta_lines 10"
assert_grown_ten() { eq "$(col "$ALPHA" 6)" "10" "$GROWN_WITNESS"; }
# mk_fixture's descriptions are `use alpha in a fixture` (5 words, 22 bytes) and `use beta in a
# fixture` (5 words, 21 bytes): per agent 2 skills, 10 words, ceil(43/4) = 11.
DESC_WITNESS="descriptions: per agent, the rendered values' words and ceil(bytes/4) — the key excluded"
assert_desc_figure() {
  has "$RS_ERR" "descriptions, the nominal listing text every session starts with, before any host budget (a report, never a gate): claude 2 skill(s) 10 words approx_tokens 11, codex 2 skill(s) 10 words approx_tokens 11, gemini 2 skill(s) 10 words approx_tokens 11" \
    "$DESC_WITNESS"
}
UNDESC_WITNESS="undescribed: a rendered skill whose frontmatter has no description line fails the report"
assert_undescribed() { eq "$RS_RC" "1" "$UNDESC_WITNESS"; }

# --- the green run ------------------------------------------------------------------------------

fx="$(mk_fixture green)" || bad "fixture: could not build the green tree"
run_rs "$fx"
yes "$RS_RC" "green: a complete tree exits 0"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "10" "green: 9 artifact rows + TOTAL"
has "$RS_OUT" "agents/claude/CLAUDE.md" "green: the claude root doc is measured"
has "$RS_OUT" "agents/gemini/skills/beta/SKILL.md" "green: every agent's every skill is measured"
hasnt "$RS_OUT" "README" "green: base/workflows/README.md is not a workflow source"
# The consumer grammar, WHOLE: every row exactly five TAB fields, the name column exactly the derived
# set in derivation order, every measurement a digit string, and the final byte a newline — read
# from the file, because `$(…)` strips it and an unterminated last row would pass every other test.
eq "$(rows_not_fields 5)" "0" "green: every row has 5 TAB fields"
eq "$(printf '%s\n' "$RS_OUT" | cut -f1 | tr '\n' ' ')" \
   "agents/claude/CLAUDE.md agents/codex/AGENTS.md agents/gemini/GEMINI.md agents/claude/skills/alpha/SKILL.md agents/codex/skills/alpha/SKILL.md agents/gemini/skills/alpha/SKILL.md agents/claude/skills/beta/SKILL.md agents/codex/skills/beta/SKILL.md agents/gemini/skills/beta/SKILL.md TOTAL " \
   "green: the rows are exactly the derived set, in derivation order, then TOTAL"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '{ for (i = 2; i <= NF; i++) if ($i !~ /^[0-9]+$/) n++ } END { print n + 0 }')" "0" \
   "green: every measurement cell is a digit string"
eq "$(tail -c 1 "$WORK/out" | od -An -c | tr -d ' ')" '\n' "green: the output ends in a newline (the last row is complete)"
# TOTAL is the sum of the rows above it in EVERY column, not an independently computed number.
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" { l += $2; w += $3; t += $4; c += $5 } END { print l, w, t, c }')" \
   "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "TOTAL" { print $2, $3, $4, $5 }')" \
   "green: TOTAL equals the sum of the artifact rows in all four measurements"
eq "$(col "$ALPHA" 5)" "0" "green: an artifact with no fence has 0 fenced comment lines"
has "$RS_ERR" "measured 3 root doc(s), 6 skill(s) and 0 on-demand supporting file(s)" "green: it says what it checked"
has "$RS_ERR" "not a tokenizer" "green: the approximation is stated, not implied"
assert_desc_figure
hasnt "$RS_OUT" "descriptions" "green: the descriptions figure is never a row — its words are already inside the SKILL.md rows"

# --- descriptions (#436): per agent, and fail-closed on a render that lost one -------------------
fx="$(mk_fixture desc)" || bad "fixture: could not build the descriptions tree"
# Per agent, not one agent's figure printed three times: gemini's beta says twelve words (62 bytes).
# claude's beta is followed by an indented comment, a blank line and a key: YAML drops the comment
# and the key ends the value, so neither continues it.
printf -- '---\nname: beta\ndescription: one two three four five six seven eight nine ten eleven twelve\n---\n\nbody\n' \
  > "$fx/agents/gemini/skills/beta/SKILL.md"
printf -- '---\nname: beta\ndescription: use beta in a fixture\n  # an indented comment\n\nuser-invocable: true\n---\n\nbody\n' \
  > "$fx/agents/claude/skills/beta/SKILL.md"
run_rs "$fx"
yes "$RS_RC" "desc: a longer description is a report, never a failure"
has "$RS_ERR" "claude 2 skill(s) 10 words approx_tokens 11, codex 2 skill(s) 10 words approx_tokens 11, gemini 2 skill(s) 17 words approx_tokens 21" \
  "desc: each agent's figure is its own renders' — gemini's twelve-word beta moves gemini alone"
# undesc_case <label> <reason> <SKILL.md content> — codex's beta rendered broken: the report fails,
# names the file and the reason, and still prints every artifact row.
undesc_case() {
  fx="$(mk_fixture "undesc-$1")" || { bad "fixture: could not build the undescribed tree ($1)"; return; }
  printf -- '%b' "$3" > "$fx/agents/codex/skills/beta/SKILL.md"
  run_rs "$fx"
  eq "$RS_RC" "1" "undescribed ($1): the report fails"
  has "$RS_ERR" "UNDESCRIBED agents/codex/skills/beta/SKILL.md — $2" "undescribed ($1): naming the file and the reason"
  eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "10" "undescribed ($1): every artifact row is still reported"
  has "$RS_ERR" "codex 1 skill(s) 5 words" "undescribed ($1): the broken skill is not counted as zero words"
}
undesc_case none "no description line" '---\nname: beta\n---\n\nbody\n'
undesc_case blank "an empty description" '---\nname: beta\ndescription:   \n---\n\nbody\n'
undesc_case folded "a folded/block scalar" '---\nname: beta\ndescription: >-\n  folded words\n---\n\nbody\n'
undesc_case continued "a multi-line continuation" '---\nname: beta\ndescription: first line\n  and a second\n---\n\nbody\n'
undesc_case twice "a second description line" '---\nname: beta\ndescription: one\ndescription: two\n---\n\nbody\n'
undesc_case twice-later "a second description line" '---\nname: beta\ndescription: one\nuser-invocable: true\ndescription: two\n---\n\nbody\n'
undesc_case continued-blank "a multi-line continuation" '---\nname: beta\ndescription: first line\n\n  folded in after a blank line\n---\n\nbody\n'
undesc_case comment-then-text "a multi-line continuation" '---\nname: beta\ndescription: first line\n  # a comment\n  then more text\n---\n\nbody\n'
# The report reads a render with the SAME rule build.sh applies to a source, so a value a loader
# reads as something else is refused here too rather than counted as text.
undesc_case space-hash "a space-hash YAML reads as a comment" '---\nname: beta\ndescription: Use a fixture # ignored words\n---\n\nbody\n'
undesc_case keyword "a bare YAML keyword" '---\nname: beta\ndescription: true\n---\n\nbody\n'
undesc_case mapping "a colon YAML reads as a mapping" '---\nname: beta\ndescription: Use it: now\n---\n\nbody\n'
undesc_case no-space "no space after the description key" '---\nname: beta\ndescription:Use a fixture\n---\n\nbody\n'
undesc_case control "a byte outside printable ASCII" '---\nname: beta\ndescription: Use a\x1bfixture\n---\n\nbody\n'
undesc_case nul "a byte outside printable ASCII" '---\nname: beta\ndescription: Fi\0rst value\n---\n\nbody\n'
undesc_case key-quoted "a top-level line that is not a plain key" '---\nname: beta\ndescription: First\n"description": Second\n---\n\nbody\n'
undesc_case key-tab "a top-level line that is not a plain key" '---\nname: beta\ndescription: First\ndescription\t: Second\n---\n\nbody\n'
# Without the rule file there is no rule: that is a FATAL, never a report of every skill as unreadable.
fx="$(mk_fixture no-rule)" || bad "fixture: could not build the no-rule tree"
rm -f "$fx/scripts/skill-description.awk"
run_rs "$fx"
eq "$RS_RC" "1" "no-rule: a missing scripts/skill-description.awk fails the report"
has "$RS_ERR" "FATAL — scripts/skill-description.awk is missing" "no-rule: …naming the missing rule"
eq "$(printf '%s' "$RS_OUT" | wc -c | tr -d ' ')" "0" "no-rule: …before printing a single row"
undesc_case no-fm "no frontmatter" 'name: beta\ndescription: one\n\nbody\n'
undesc_case unclosed "an unclosed frontmatter" '---\nname: beta\ndescription: one\n'
fx="$(mk_fixture undesc-witness)" || bad "fixture: could not build the undescribed-witness tree"
printf -- '---\nname: beta\n---\n\nbody\n' > "$fx/agents/codex/skills/beta/SKILL.md"
run_rs "$fx"
assert_undescribed

# ------- MUTATIONS: a figure that counts the key, and a reader that passes a missing one ---------
fx="$(mk_fixture mut-desc-key)" || bad "fixture: could not build the description-key mutation tree"
check_mutate_literal "$fx/scripts/skill-description.awk" 'seen = 1; cont = 1' 'v = $0; seen = 1; cont = 1'; mrc=$?
case "$mrc" in
  0) out="$( run_rs "$fx"; echo "mutant-rc=$RS_RC"; assert_desc_figure 2>&1 )"
     has "$out" "mutant-rc=0" "mut-desc-key: the mutated command still runs"
     case "$out" in
       *"FAIL: $DESC_WITNESS"*) ok ;;
       *) bad "MUTATION 3 DID NOT FIRE: the assertion [$DESC_WITNESS] stayed green on a figure that counts the description: key, so it proves nothing (subshell output: $out)" ;;
     esac ;;
  2) bad "mut-desc-key: the mutation literal no longer matches scripts/skill-description.awk, so this proof would prove nothing" ;;
  *) bad "mut-desc-key: the mutation could not be applied (rc $mrc)" ;;
esac
fx="$(mk_fixture mut-undesc)" || bad "fixture: could not build the undescribed mutation tree"
printf -- '---\nname: beta\n---\n\nbody\n' > "$fx/agents/codex/skills/beta/SKILL.md"
check_mutate_literal "$fx/scripts/skill-description.awk" 'if (r == "" && !seen) r = "no description line"' ''; mrc=$?
case "$mrc" in
  0) out="$( run_rs "$fx"; echo "mutant-rc=$RS_RC"; assert_undescribed 2>&1 )"
     has "$out" "mutant-rc=0" "mut-undesc: the mutant passes a skill with no description line as zero words, which is the defect"
     case "$out" in
       *"FAIL: $UNDESC_WITNESS"*) ok ;;
       *) bad "MUTATION 4 DID NOT FIRE: the assertion [$UNDESC_WITNESS] stayed green on a reader that passes a missing description, so it proves nothing (subshell output: $out)" ;;
     esac ;;
  2) bad "mut-undesc: the mutation literal no longer matches scripts/skill-description.awk, so this proof would prove nothing" ;;
  *) bad "mut-undesc: the mutation could not be applied (rc $mrc)" ;;
esac

# --- supports-present: ONE final TOTAL summing EVERY row above (#433) ---------------------------
# The TSV contract is the header's own sentence — one row per artifact, then a TOTAL summing the
# rows above it in every column. Supporting files must not bend it: no row after TOTAL, and no
# row TOTAL silently excludes. The loaded/on-demand split lives in the stderr summary instead.
fxs="$(mk_fixture supp)" || bad "fixture: could not build the supports tree"
mkdir -p "$fxs/base/workflows/alpha"
printf '# on-demand notes\nsome words here\n' > "$fxs/base/workflows/alpha/notes.md"
for agent in claude codex gemini; do
  printf '# on-demand notes\nsome words here\n' > "$fxs/agents/$agent/skills/alpha/notes.md"
done
run_rs "$fxs"
yes "$RS_RC" "supports: a tree with supporting files exits 0"
eq "$(printf '%s\n' "$RS_OUT" | tail -n1 | awk -F'\t' '{print $1}')" "TOTAL" \
   "supports: the LAST row is TOTAL — nothing rides after it"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" { l += $2; w += $3; t += $4; c += $5 } END { print l, w, t, c }')" \
   "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "TOTAL" { print $2, $3, $4, $5 }')" \
   "supports: TOTAL sums EVERY row above it, supporting rows included"
has "$RS_ERR" "3 on-demand supporting file(s)" "supports: the stderr summary counts them"
has "$RS_ERR" "loaded approx_tokens" "supports: …and carries the loaded/on-demand token split"

# --- procedures (#434): derived from base/practices, on-demand, and in exactly one tree ----------
loaded_tokens() { printf '%s\n' "$RS_ERR" | sed -n 's/.*loaded approx_tokens \([0-9]*\),.*/\1/p'; }
fxg="$(mk_fixture procs-base)" || bad "fixture: could not build the procedure baseline tree"
run_rs "$fxg"; base_loaded="$(loaded_tokens)"
fxp="$(mk_fixture procs)" || bad "fixture: could not build the procedures tree"
mkdir -p "$fxp/base/practices" "$fxp/agents/claude/rules" "$fxp/agents/codex/reference" "$fxp/agents/gemini/reference"
printf '# index\n' > "$fxp/base/practices/00-index.md"
printf '# p\n<!-- adb:paths *.sh -->\n\nrule\n<!-- adb:procedure -->\n\nhow\n<!-- adb:end -->\n' > "$fxp/base/practices/10-p.md"
printf '# q\n\nrule only\n' > "$fxp/base/practices/20-q.md"
printf '# p — procedure\n\nhow\n' > "$fxp/agents/claude/rules/10-p.md"
printf '# p — procedure\n\nhow\n' > "$fxp/agents/codex/reference/10-p.md"
printf '# p — procedure\n\nhow\n' > "$fxp/agents/gemini/reference/10-p.md"
run_rs "$fxp"
yes "$RS_RC" "procs: a tree with procedure files exits 0"
has "$RS_OUT" "agents/claude/rules/10-p.md" "procs: a path-scoped claude procedure is measured where it rendered"
has "$RS_OUT" "agents/codex/reference/10-p.md" "procs: a reference procedure is measured"
hasnt "$RS_OUT" "20-q.md" "procs: a practice with no procedure block yields no row"
has "$RS_ERR" "3 procedure file(s) from 1 practice(s)" "procs: the summary counts them"
eq "$(loaded_tokens)" "$base_loaded" "procs: procedure files land in the on-demand bucket, never the loaded figure"
has "$RS_ERR" "root doc lines against the ~200-line goal (a report, never a gate): claude 2, codex 2, gemini 2" \
  "procs: each root doc's lines are reported against the goal"
rm "$fxp/agents/codex/reference/10-p.md"
run_rs "$fxp"
eq "$RS_RC" "1" "procs: a practice's missing procedure file fails the report"
has "$RS_ERR" "MISSING agents/codex/reference/10-p.md" "procs: …naming the file the derivation expected"
printf '# p — procedure\n\nhow\n' > "$fxp/agents/codex/reference/10-p.md"
mkdir -p "$fxp/agents/claude/reference"
cp "$fxp/agents/claude/rules/10-p.md" "$fxp/agents/claude/reference/10-p.md"
run_rs "$fxp"
eq "$RS_RC" "1" "procs: a procedure rendered to both trees fails the report"
has "$RS_ERR" "DUPLICATE 10-p.md — agents/claude/reference/10-p.md is a stale copy" "procs: …naming the stale one"
# The tree is DERIVED from the practice, never taken from whichever file exists: a path-scoped
# procedure found only in reference/ is the expected file missing, not a substitute for it.
rm "$fxp/agents/claude/rules/10-p.md"
run_rs "$fxp"
eq "$RS_RC" "1" "procs: a path-scoped procedure present only in reference/ fails the report"
has "$RS_ERR" "MISSING agents/claude/rules/10-p.md" "procs: …naming the file the practice's scope expects"
hasnt "$RS_OUT" "agents/claude/reference/10-p.md" "procs: …and the stale copy is never measured in its place"
# A practice that cannot be read is a fault, never a practice without a procedure.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$fxp/base/practices/10-p.md"
  run_rs "$fxp"
  chmod 644 "$fxp/base/practices/10-p.md"
  eq "$RS_RC" "1" "procs: an unreadable practice fails the report"
  has "$RS_ERR" "UNREADABLE base/practices/10-p.md" "procs: …naming it"
fi

# --- fenced_comment_lines (#432) ----------------------------------------------------------------

fx="$(mk_fixture fenced)" || bad "fixture: could not build the fenced tree"
write_fenced "$fx/$ALPHA"
run_rs "$fx"
yes "$RS_RC" "fenced: a fixture with fences exits 0"
assert_fenced_three
eq "$(col TOTAL 5)" "3" "fenced: TOTAL sums the fenced-comment column"

# Every fence shape the shared rule models, and every `#` shape the header's lexical rule names.
fx="$(mk_fixture fences)" || bad "fixture: could not build the fence-shapes tree"
{
  cat <<'EOF'
---
name: alpha
description: use alpha in a fixture
---
- a list item
  ```sh
  # one, in a list-nested sh fence
  ```
~~~zsh
# two, in a tilde fence
```
# three: a backtick run inside a tilde fence is content, not a closer
~~~
```shell
#!/usr/bin/env bash
echo "# quoted, not a comment line"
${#x}
EOF
  printf '\t# four, tab-indented\n'
  cat <<'EOF'
```
   - an item whose content column is five
     ```bash
     # five, in a fence indented to the item's content column (roadmap.md:308's shape)
     ```
  3. an ordered item whose content column is five
     ```bash
     # six, the same shape under an ordered marker (roadmap.md:995's shape)
     ```
- an item whose fence never closes
  ```bash
  # seven, inside the unterminated nested fence
```bash
# eight: the dedent ended the item and its fence, and this line OPENS a new fence
```
```text
# sample output, not a comment
```
```markdown
# a heading, not a comment
```
```
# a bare fence holds a template, not a comment
```
```json
{"#": 1}
```
> ```bash
> # not a comment: a blockquoted fence is quotation, and the header says it is not scanned
> ```
    ```bash
    # not a comment: four spaces at top level is an indented code block, not a fence
    ```
```bash
# nine: this fence never closes, so it runs to the end of the file
# ten
EOF
} > "$fx/$ALPHA"
# CRLF endings on another artifact: the closer must still close and the count must still be right.
printf -- '---\r\nname: alpha\r\ndescription: use alpha in a fixture\r\n---\r\n```bash\r\n# one\r\n# two\r\n```\r\n# outside\r\n' > "$fx/agents/codex/skills/alpha/SKILL.md"
# ADJACENT LIST FENCES (review of PR #446): an unterminated nested fence ended by the next item,
# which opens a fence of the SAME delimiter, length and column on its own marker line. The two
# directions live in two artifacts, because a counter that infers an opener from the delimiter
# tuple gets them wrong in opposite ways (0 and 1) and a single total would cancel to the right sum.
printf -- '---\nname: alpha\ndescription: use alpha in a fixture\n---\n- old\n  ```text\n- ```bash\n  # one, in the bash fence the ending item opened\n  ```\n' > "$fx/agents/gemini/skills/alpha/SKILL.md"
printf -- '---\nname: beta\ndescription: use beta in a fixture\n---\n- old\n  ```bash\n- ```text\n  # not a comment: the ending item opened a TEXT fence\n  ```\n' > "$fx/agents/gemini/skills/beta/SKILL.md"
run_rs "$fx"
yes "$RS_RC" "fence-shapes: exits 0"
eq "$(col agents/gemini/skills/alpha/SKILL.md 5)" "1" "adjacent: a bash fence opened by the item that ended an unterminated text fence counts its comment"
eq "$(col agents/gemini/skills/beta/SKILL.md 5)" "0" "adjacent: a text fence opened by the item that ended an unterminated bash fence counts nothing"
eq "$(col "$ALPHA" 5)" "11" "fence-shapes: sh/zsh/shell/bash, list-nested at 2 and at 5 (bullet and ordered), an unterminated nested fence ended by a dedent that opens the next, tilde with an inner backtick run, shebang, tab-indented, unclosed at EOF; text/markdown/bare/json fences, a blockquoted fence, a 4-space indented code block, quoted and \${#x} hashes excluded"
eq "$(col agents/codex/skills/alpha/SKILL.md 5)" "2" "fence-shapes: CRLF line endings do not defeat the closer or the count"

# ------- MUTATION: a count that ignores fences must turn the assertion above RED ----------------
# Without this, "3" is green on any counter that happens to see three lines, including one that
# reads every `#` line in the file — the whole-file count the report exists NOT to be.
fx="$(mk_fixture mut-fence)" || bad "fixture: could not build the fence-mutation tree"
write_fenced "$fx/$ALPHA"
check_mutate_literal "$fx/scripts/render-size.sh" 'md_fence_len && shell && ' ''; mrc=$?
case "$mrc" in
  0) # The assertion runs in a SUBSHELL: its FAIL is the evidence, not a failure of this suite.
     out="$( run_rs "$fx"; echo "mutant-rc=$RS_RC mutant-count=$(col "$ALPHA" 5)"; assert_fenced_three 2>&1 )"
     has "$out" "mutant-rc=0" "mut-fence: the mutated command still runs — the mutation changed the rule, not the script"
     has "$out" "mutant-count=5" "mut-fence: the mutant counts every # line in the file (5), which is the defect"
     case "$out" in
       *"FAIL: $FENCED_WITNESS"*) ok ;;
       *) bad "MUTATION 1 DID NOT FIRE: the assertion [$FENCED_WITNESS] stayed green on a counter that ignores fences, so it proves nothing (subshell output: $out)" ;;
     esac ;;
  2) bad "mut-fence: the mutation literal no longer matches render-size.sh, so this proof would prove nothing" ;;
  *) bad "mut-fence: the mutation could not be applied (rc $mrc)" ;;
esac

# --- --since <ref> (#432) -----------------------------------------------------------------------

fx="$(mk_since_repo since)" || bad "fixture: could not build the since repository"
run_rs "$fx" --since HEAD~1
yes "$RS_RC" "since: a resolvable ref exits 0"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "13" "since: 12 artifact rows (three workflows) + TOTAL"
eq "$(rows_not_fields 7)" "0" "since: every row has 7 TAB fields"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '{ for (i = 2; i <= 5; i++) if ($i !~ /^[0-9]+$/) n++; for (i = 6; i <= 7; i++) if ($i !~ /^(-?[0-9]+|new)$/) n++ } END { print n + 0 }')" "0" \
   "since: every measurement cell is a digit string and every delta cell a signed integer or new"
assert_grown_ten
# delta_tokens is the difference of the two ceil(bytes/4) figures the command prints, computed
# here independently from the bytes — never a rounded byte delta, which differs at a boundary.
now_bytes="$(wc -c < "$fx/$ALPHA" | tr -d ' ')"
ref_bytes="$(check_git "$fx" cat-file blob "HEAD~1:$ALPHA" | wc -c | tr -d ' ')"
eq "$(col "$ALPHA" 7)" "$(( (now_bytes + 3) / 4 - (ref_bytes + 3) / 4 ))" "since: delta_tokens is ceil(now/4) - ceil(ref/4)"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' -v a="$ALPHA" '$1 != "TOTAL" && $1 != a && $1 !~ /gamma/ && ($6 != 0 || $7 != 0)' | wc -l | tr -d ' ')" "0" \
   "since: every unchanged artifact reports 0 / 0"
eq "$(col agents/codex/skills/gamma/SKILL.md 6),$(col agents/codex/skills/gamma/SKILL.md 7)" "new,new" "since: an artifact absent at the ref reads new / new"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" { l += ($6 == "new") ? $2 : $6; t += ($7 == "new") ? $4 : $7 } END { print l, t }')" \
   "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "TOTAL" { print $6, $7 }')" \
   "since: TOTAL's deltas are the sum of the rows, a new row counting its whole size"
eq "$(col TOTAL 6)" "$(( 10 + 3 * 6 ))" "since: TOTAL delta_lines = 10 grown + three 6-line new skills"
has "$RS_ERR" "3 new" "since: the summary line counts the new artifacts"
eq "$(check_git "$fx" status --porcelain | wc -l | tr -d ' ')" "0" "since: the working tree and the repository are untouched"
eq "$(ls -A "$WORK/tmp" | wc -l | tr -d ' ')" "0" "since: the scratch directory for the ref's artifacts is removed on exit"

run_rs "$fx" --since HEAD
yes "$RS_RC" "since HEAD: exits 0"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$6 != 0 || $7 != 0' | wc -l | tr -d ' ')" "0" "since HEAD: every delta on a clean tree is 0, TOTAL included"

run_rs "$fx" --since=HEAD~2
yes "$RS_RC" "since c0: a ref with no agents/ at all exits 0"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" && ($6 != "new" || $7 != "new")' | wc -l | tr -d ' ')" "0" "since c0: every artifact is new"
eq "$(col TOTAL 6),$(col TOTAL 7)" "$(col TOTAL 2),$(col TOTAL 4)" "since c0: TOTAL's deltas equal TOTAL's size"

# An uncommitted change is the CURRENT side: the working tree is what is measured now.
printf 'an uncommitted line\n' >> "$fx/agents/codex/skills/alpha/SKILL.md"
run_rs "$fx" --since HEAD
eq "$(col agents/codex/skills/alpha/SKILL.md 6)" "1" "since: an uncommitted change shows in the delta"
eq "$(check_git "$fx" status --porcelain | tr -d ' ')" "Magents/codex/skills/alpha/SKILL.md" "since: and the run changed nothing else"
check_git "$fx" add -A >/dev/null 2>&1 && check_git "$fx" commit -q -m c3 >/dev/null 2>&1 || bad "fixture: could not commit c3"

# A rename between the ref and HEAD: beta becomes delta. The new name is `new`; the old name has
# no row, because the expected set is derived from the CURRENT sources.
check_git "$fx" mv base/workflows/beta.md base/workflows/delta.md >/dev/null 2>&1 || bad "fixture: could not rename beta"
for agent in claude codex gemini; do
  check_git "$fx" mv "agents/$agent/skills/beta" "agents/$agent/skills/delta" >/dev/null 2>&1 || bad "fixture: could not rename $agent's beta skill"
done
check_git "$fx" commit -q -m c4 >/dev/null 2>&1 || bad "fixture: could not commit c4"
run_rs "$fx" --since HEAD~1
yes "$RS_RC" "rename: exits 0"
hasnt "$RS_OUT" "skills/beta/" "rename: the artifact that no longer exists has no row"
eq "$(col agents/gemini/skills/delta/SKILL.md 6)" "new" "rename: the renamed artifact is new"
eq "$(col TOTAL 6)" "$(( 3 * 6 ))" "rename: TOTAL delta_lines counts the three new rows and nothing for the removed ones"

# --- --markdown ---------------------------------------------------------------------------------

run_rs "$fx" --markdown
yes "$RS_RC" "markdown: exits 0"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 1p)" "| name | lines | words | approx_tokens | fenced_comment_lines |" "markdown: the header row names the five columns"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 2p)" "| --- | ---: | ---: | ---: | ---: |" "markdown: the separator row"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "24" "markdown: the artifact table (header, separator, 12 rows, TOTAL), then the descriptions table (blank, caption, blank, header, separator, one row per agent, TOTAL)"
has "$(printf '%s\n' "$RS_OUT" | sed -n 15p)" "| TOTAL |" "markdown: the artifact table still ends in TOTAL"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 16p)" "" "markdown: a blank line closes the artifact table, so no row is appended to it"
eq "$(printf '%s\n' "$RS_OUT" | sed -n '19,21p')" \
   "$(printf '%s\n' '| agent | skills | words | approx_tokens |' '| --- | ---: | ---: | ---: |' '| claude | 3 | 15 | 17 |')" \
   "markdown: the descriptions table — three skills of five words each, 65 bytes"
eq "$(printf '%s\n' "$RS_OUT" | sed -n '21,23p' | cut -d' ' -f2 | tr '\n' ' ')" "claude codex gemini " "markdown: one descriptions row per agent"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 24p)" "| TOTAL | 9 | 45 | 51 |" "markdown: the descriptions table ends in its own TOTAL, the sum of the rows above it"
run_rs "$fx" --since HEAD~1 --markdown
eq "$(printf '%s\n' "$RS_OUT" | sed -n 1p)" "| name | lines | words | approx_tokens | fenced_comment_lines | delta_lines | delta_tokens |" "markdown: with --since the header carries the delta columns"
eq "$(printf '%s\n' "$RS_OUT" | grep -c '| new | new |')" "3" "markdown: new rows render new / new"

# --- --descriptions (#436): the figure alone, machine-readable, with its own TOTAL ---------------

fx="$(mk_fixture descs-only)" || bad "fixture: could not build the --descriptions tree"
run_rs "$fx" --descriptions
yes "$RS_RC" "descriptions: exits 0"
eq "$RS_OUT" "$(printf 'claude\t2\t10\t11\ncodex\t2\t10\t11\ngemini\t2\t10\t11\nTOTAL\t6\t30\t33')" \
   "descriptions: one row per agent then TOTAL, and no artifact row"
eq "$(tail -c 1 "$WORK/out" | od -An -c | tr -d ' ')" '\n' "descriptions: the output ends in a newline (the last row is complete)"
eq "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 != "TOTAL" { s += $2; w += $3; t += $4 } END { print s, w, t }')" \
   "$(printf '%s\n' "$RS_OUT" | awk -F'\t' '$1 == "TOTAL" { print $2, $3, $4 }')" \
   "descriptions: TOTAL is the sum of the rows above it in every column"
has "$RS_ERR" "descriptions, the nominal listing text" "descriptions: the stderr summary still carries the figure"
run_rs "$fx" --descriptions --markdown
eq "$RS_OUT" "$(printf '%s\n' '| agent | skills | words | approx_tokens |' '| --- | ---: | ---: | ---: |' '| claude | 2 | 10 | 11 |' '| codex | 2 | 10 | 11 |' '| gemini | 2 | 10 | 11 |' '| TOTAL | 6 | 30 | 33 |')" \
   "descriptions: with --markdown, the same rows as a table"
run_rs "$fx" --descriptions --since HEAD
eq "$RS_RC" "2" "descriptions: --since is refused as usage, never ignored"
has "$RS_ERR" "takes no --since" "descriptions: …saying why"
eq "$(printf '%s' "$RS_OUT" | wc -c | tr -d ' ')" "0" "descriptions: …and prints no rows"
# A fault still fails the run: every artifact is measured even though none of its rows is printed.
printf -- '---\nname: beta\n---\n\nbody\n' > "$fx/agents/codex/skills/beta/SKILL.md"
run_rs "$fx" --descriptions
eq "$RS_RC" "1" "descriptions: an undescribed skill still fails the run"
eq "$(col codex 2),$(col codex 3)" "1,5" "descriptions: …and its agent's row counts only what was measured"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "4" "descriptions: …with no artifact row printed"
rm -f "$fx/agents/gemini/GEMINI.md"
run_rs "$fx" --descriptions
has "$RS_ERR" "MISSING agents/gemini/GEMINI.md" "descriptions: a missing artifact is still found, though its row is never printed"

# --- the commands a count depends on are heard, not assumed (#436) ------------------------------
# PATH shims stand in for `tr` and `wc`, the only external commands between an artifact and its
# figures: a `tr` that writes and then fails, and a `wc` that returns one field where two or three
# are read. Each must fail the run rather than produce a plausible figure.
REAL_TR="$(command -v tr)"; REAL_WC="$(command -v wc)"
mkdir -p "$WORK/shim-tr" "$WORK/shim-wc" "$WORK/shim-wc-desc" || bad "shims: could not create them"
printf '#!/bin/sh\n"%s" "$@"\nexit 7\n' "$REAL_TR" > "$WORK/shim-tr/tr"
printf '#!/bin/sh\necho 5\n' > "$WORK/shim-wc/wc"
printf '#!/bin/sh\ncase "$1" in -wc) echo 5 ;; *) exec "%s" "$@" ;; esac\n' "$REAL_WC" > "$WORK/shim-wc-desc/wc"
chmod +x "$WORK/shim-tr/tr" "$WORK/shim-wc/wc" "$WORK/shim-wc-desc/wc"
# run_shim <root> <shim-dir> [arg…] — run_rs with <shim-dir> first on PATH.
run_shim() {
  local root="$1" shim="$2"; shift 2
  RS_RC=0
  ( cd "$root" && PATH="$shim:$PATH" bash scripts/render-size.sh "$@" ) >"$WORK/out" 2>"$WORK/err" || RS_RC=$?
  RS_OUT="$(cat "$WORK/out")"; RS_ERR="$(cat "$WORK/err")"
}
TR_WITNESS="pipeline: a tr that writes and then fails makes the description unreadable"
assert_tr_heard() { eq "$RS_RC" "1" "$TR_WITNESS"; }
fx="$(mk_fixture shim-tr)" || bad "fixture: could not build the tr-shim tree"
run_shim "$fx" "$WORK/shim-tr"
assert_tr_heard
has "$RS_ERR" "UNREADABLE agents/claude/skills/alpha/SKILL.md — its description could not be read" "pipeline: …naming the file"
fx="$(mk_fixture shim-wc)" || bad "fixture: could not build the wc-shim tree"
run_shim "$fx" "$WORK/shim-wc"
eq "$RS_RC" "1" "counts: a wc that returns one field of three fails the run"
has "$RS_ERR" "UNCOUNTABLE agents/claude/CLAUDE.md — wc returned 5" "counts: …naming the artifact and what wc said"
fx="$(mk_fixture shim-wc-desc)" || bad "fixture: could not build the description wc-shim tree"
run_shim "$fx" "$WORK/shim-wc-desc"
eq "$RS_RC" "1" "counts: a wc that returns one field of two for a description fails the run"
has "$RS_ERR" "wc returned 5 for its description" "counts: …naming the description count"

# ------- MUTATION: a pipeline that answers for awk alone must turn the tr witness RED ------------
fx="$(mk_fixture mut-pipefail)" || bad "fixture: could not build the pipefail-mutation tree"
check_mutate_literal "$fx/scripts/render-size.sh" 'set -o pipefail; ' ''; mrc=$?
case "$mrc" in
  0) out="$( run_shim "$fx" "$WORK/shim-tr"; echo "mutant-rc=$RS_RC"; assert_tr_heard 2>&1 )"
     has "$out" "mutant-rc=0" "mut-pipefail: the mutant reports a figure over a tr that failed, which is the defect"
     case "$out" in
       *"FAIL: $TR_WITNESS"*) ok ;;
       *) bad "MUTATION 5 DID NOT FIRE: the assertion [$TR_WITNESS] stayed green on a pipeline that ignores tr's status, so it proves nothing (subshell output: $out)" ;;
     esac ;;
  2) bad "mut-pipefail: the mutation literal no longer matches render-size.sh, so this proof would prove nothing" ;;
  *) bad "mut-pipefail: the mutation could not be applied (rc $mrc)" ;;
esac

# ------- MUTATION: a --since half that measures the working tree must turn the delta RED --------
fx="$(mk_since_repo mut-since)" || bad "fixture: could not build the since-mutation repository"
check_mutate_literal "$fx/scripts/render-size.sh" 'measure "$REF_DIR/$f" ' 'measure "$f" '; mrc=$?
case "$mrc" in
  0) out="$( run_rs "$fx" --since HEAD~1; echo "mutant-rc=$RS_RC mutant-delta=$(col "$ALPHA" 6)"; assert_grown_ten 2>&1 )"
     has "$out" "mutant-rc=0" "mut-since: the mutated command still runs"
     has "$out" "mutant-delta=0" "mut-since: the mutant reports no growth for the grown skill, which is the defect"
     case "$out" in
       *"FAIL: $GROWN_WITNESS"*) ok ;;
       *) bad "MUTATION 2 DID NOT FIRE: the assertion [$GROWN_WITNESS] stayed green on a --since that measures the working tree, so it proves nothing (subshell output: $out)" ;;
     esac ;;
  2) bad "mut-since: the mutation literal no longer matches render-size.sh, so this proof would prove nothing" ;;
  *) bad "mut-since: the mutation could not be applied (rc $mrc)" ;;
esac

# --- --since refusals: usage (2), never a silent full run ---------------------------------------

fx="$(mk_since_repo refusals)" || bad "fixture: could not build the refusals repository"
run_rs "$fx" --since nope
eq "$RS_RC" "2" "refusal: an unresolvable ref exits 2"
has "$RS_ERR" "cannot resolve nope" "refusal: the diagnostic names the ref"
eq "$(printf '%s' "$RS_OUT" | wc -c | tr -d ' ')" "0" "refusal: and prints no rows"
run_rs "$fx" --since HEAD:README.md
eq "$RS_RC" "2" "refusal: an object that is not a commit exits 2"
run_rs "$fx" --since
eq "$RS_RC" "2" "refusal: --since without a ref exits 2"
run_rs "$fx" --since ''
eq "$RS_RC" "2" "refusal: --since with an empty ref exits 2"
run_rs "$fx" --since -x
eq "$RS_RC" "2" "refusal: --since followed by an option-shaped ref exits 2 (it cannot be told from an option)"
has "$RS_ERR" "--since=<ref>" "refusal: and names the form that can carry such a ref"
# A ref that BEGINS WITH A DASH is legal to git; the `=` form carries it, behind --end-of-options.
check_git "$fx" update-ref refs/tags/-x HEAD~1 >/dev/null 2>&1 || bad "fixture: could not create the tag named -x"
run_rs "$fx" --since=-x
yes "$RS_RC" "dash-ref: --since=-x resolves a tag named -x"
assert_grown_ten
has "$RS_ERR" "3 new (on-demand: 0 new)" "since: new artifacts are counted per bucket, so a supporting-file batch cannot masquerade as loaded growth"
run_rs "$fx" --since HEAD --since HEAD~1
eq "$RS_RC" "2" "refusal: --since twice exits 2"
fx="$(mk_fixture norepo)" || bad "fixture: could not build the no-repository tree"
run_rs "$fx" --since HEAD
eq "$RS_RC" "2" "refusal: --since outside a git repository exits 2"
has "$RS_ERR" "needs a git repository" "refusal: the diagnostic says why"

# --- the mechanical failures ---------------------------------------------------------------------

fx="$(mk_fixture missing)" || bad "fixture: could not build the missing tree"
rm -f "$fx/agents/codex/skills/beta/SKILL.md"
run_rs "$fx"
no "$RS_RC" "missing: a missing artifact fails the command"
has "$RS_ERR" "MISSING agents/codex/skills/beta/SKILL.md" "missing: the diagnostic names the artifact"
# The other eight are still measured: one gap must not hide the rest of the report.
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "9" "missing: the surviving artifacts are still reported"

fx="$(mk_fixture empty)" || bad "fixture: could not build the empty tree"
: > "$fx/agents/claude/skills/alpha/SKILL.md"
run_rs "$fx"
no "$RS_RC" "empty: a zero-byte artifact fails the command"
has "$RS_ERR" "EMPTY agents/claude/skills/alpha/SKILL.md" "empty: the diagnostic names the artifact"

fx="$(mk_fixture noworkflows)" || bad "fixture: could not build the no-source tree"
rm -f "$fx"/base/workflows/*.md
run_rs "$fx"
no "$RS_RC" "no-sources: a collapsed derivation fails rather than printing a short clean report"
has "$RS_ERR" "named no workflow source" "no-sources: the diagnostic says the derivation collapsed"

fx="$(mk_fixture badname)" || bad "fixture: could not build the bad-name tree"
printf 'source\n' > "$fx/base/workflows/two words.md"
run_rs "$fx"
no "$RS_RC" "bad-name: a workflow name that would forge a TSV field boundary fails the command"
has "$RS_ERR" "UNNAMEABLE" "bad-name: the diagnostic names the rule"
eq "$(rows_not_fields 5)" "0" "bad-name: the emitted rows stay 5-field"

if [ "$(id -u)" -eq 0 ]; then
  echo "check-render-size: SKIP the unreadable case — running as root, where mode 000 is still readable"
else
  fx="$(mk_fixture unreadable)" || bad "fixture: could not build the unreadable tree"
  chmod 000 "$fx/agents/gemini/GEMINI.md"
  run_rs "$fx"
  chmod 644 "$fx/agents/gemini/GEMINI.md"
  no "$RS_RC" "unreadable: an unreadable artifact fails the command"
  has "$RS_ERR" "UNREADABLE agents/gemini/GEMINI.md" "unreadable: the diagnostic names the artifact"
fi

# --- and the direction it must NEVER fail in ------------------------------------------------------
# The owner rejected caps (2026-08-15). A ceiling reintroduced here would look exactly like the
# mechanical arm above, so the absence of one is asserted rather than assumed.

fx="$(mk_fixture nocap)" || bad "fixture: could not build the no-cap tree"
awk 'BEGIN { for (i = 0; i < 40000; i++) print "a line of instruction prose that costs context" }' \
  >> "$fx/agents/claude/skills/alpha/SKILL.md"
run_rs "$fx"
yes "$RS_RC" "no-cap: an arbitrarily large artifact still exits 0"
big="$(col "$ALPHA" 4)"
if [ -n "$big" ] && [ "$big" -gt 100000 ]; then ok; else bad "no-cap: the large artifact's approx_tokens ($big) did not grow with it"; fi

# --- usage ---------------------------------------------------------------------------------------

fx="$(mk_fixture usage)" || bad "fixture: could not build the usage tree"
RS_RC=0; ( cd "$fx" && bash scripts/render-size.sh --nonsense ) >/dev/null 2>&1 || RS_RC=$?
eq "$RS_RC" "2" "usage: an unknown argument exits 2, never a silent full run"
RS_RC=0; ( cd "$fx" && bash scripts/render-size.sh -h ) >"$WORK/out" 2>&1 || RS_RC=$?
yes "$RS_RC" "usage: -h exits 0"
has "$(cat "$WORK/out")" "approx_tokens" "usage: -h prints the output contract"
has "$(cat "$WORK/out")" "fenced_comment_lines" "usage: -h names the fenced-comment column"
has "$(cat "$WORK/out")" "--since <ref>" "usage: -h names --since"
has "$(cat "$WORK/out")" "UNDESCRIBED" "usage: -h documents the descriptions figure and its fault"
has "$(cat "$WORK/out")" "agent<TAB>skills<TAB>words<TAB>approx_tokens" "usage: -h names the --descriptions columns"

check_summary "check-render-size"
