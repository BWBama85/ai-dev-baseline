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
# The two measurements #432 added are guarded the same way, and each is OBSERVED FAILING on a
# mutated copy of the command: a fenced-comment count that ignores fences, and a `--since` half
# that measures the working tree instead of the ref, must each turn a named assertion below red —
# the SAME assertion function the green run uses, re-run against the mutant in a subshell, with
# its own `FAIL:` line as the witness. Inline rather than a `--mutation` pool row (the
# check-build-atomic.sh shape): two rows, seconds each, and no new registry, gate or nightly entry.
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
  cp "$REPO/scripts/lib/common.sh" "$fx/scripts/lib/common.sh" || return 1
  for name in alpha beta README; do
    printf 'source %s\n' "$name" > "$fx/base/workflows/$name.md" || return 1
  done
  for agent in claude:CLAUDE.md codex:AGENTS.md gemini:GEMINI.md; do
    mkdir -p "$fx/agents/${agent%%:*}" || return 1
    printf 'root doc for %s\nsecond line\n' "${agent%%:*}" > "$fx/agents/${agent%%:*}/${agent#*:}" || return 1
    for name in alpha beta; do
      mkdir -p "$fx/agents/${agent%%:*}/skills/$name" || return 1
      printf -- '---\nname: %s\n---\n\nbody words here\n' "$name" > "$fx/agents/${agent%%:*}/skills/$name/SKILL.md" || return 1
    done
  done
  printf '%s\n' "$fx"
}

# write_fenced <file> — the issue's own fixture: 3 `#` lines inside one bash fence, 2 outside.
write_fenced() {
  cat > "$1" <<'EOF'
---
name: alpha
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
    printf -- '---\nname: gamma\n---\n\nnew body\n' > "$fx/agents/$agent/skills/gamma/SKILL.md" || return 1
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

# The two assertions the mutations must turn red. ONE function each, so the green run and the
# mutant run the identical witness — a mutation that only compares the mutant's value to a number
# of its own would stay green if the assertion it claims to protect were weakened or deleted.
FENCED_WITNESS="fenced: 3 # lines inside the fence and 2 outside count 3"
assert_fenced_three() { eq "$(col "$ALPHA" 5)" "3" "$FENCED_WITNESS"; }
GROWN_WITNESS="since: the skill that grew by 10 lines reports delta_lines 10"
assert_grown_ten() { eq "$(col "$ALPHA" 6)" "10" "$GROWN_WITNESS"; }

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
has "$RS_ERR" "measured 3 root doc(s) and 6 skill(s)" "green: it says what it checked"
has "$RS_ERR" "not a tokenizer" "green: the approximation is stated, not implied"

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
    ```bash
    # not a comment: four spaces at top level is an indented code block, not a fence
    ```
```bash
# nine: this fence never closes, so it runs to the end of the file
# ten
EOF
} > "$fx/$ALPHA"
# CRLF endings on another artifact: the closer must still close and the count must still be right.
printf -- '---\r\nname: alpha\r\n---\r\n```bash\r\n# one\r\n# two\r\n```\r\n# outside\r\n' > "$fx/agents/codex/skills/alpha/SKILL.md"
run_rs "$fx"
yes "$RS_RC" "fence-shapes: exits 0"
eq "$(col "$ALPHA" 5)" "11" "fence-shapes: sh/zsh/shell/bash, list-nested at 2 and at 5 (bullet and ordered), an unterminated nested fence ended by a dedent that opens the next, tilde with an inner backtick run, shebang, tab-indented, unclosed at EOF; text/markdown/bare/json fences, a 4-space indented code block, quoted and \${#x} hashes excluded"
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
eq "$(col TOTAL 6)" "$(( 10 + 3 * 5 ))" "since: TOTAL delta_lines = 10 grown + three 5-line new skills"
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
eq "$(col TOTAL 6)" "$(( 3 * 5 ))" "rename: TOTAL delta_lines counts the three new rows and nothing for the removed ones"

# --- --markdown ---------------------------------------------------------------------------------

run_rs "$fx" --markdown
yes "$RS_RC" "markdown: exits 0"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 1p)" "| name | lines | words | approx_tokens | fenced_comment_lines |" "markdown: the header row names the five columns"
eq "$(printf '%s\n' "$RS_OUT" | sed -n 2p)" "| --- | ---: | ---: | ---: | ---: |" "markdown: the separator row"
eq "$(printf '%s\n' "$RS_OUT" | wc -l | tr -d ' ')" "15" "markdown: header + separator + 12 artifact rows + TOTAL"
has "$(printf '%s\n' "$RS_OUT" | tail -1)" "| TOTAL |" "markdown: the last row is TOTAL"
run_rs "$fx" --since HEAD~1 --markdown
eq "$(printf '%s\n' "$RS_OUT" | sed -n 1p)" "| name | lines | words | approx_tokens | fenced_comment_lines | delta_lines | delta_tokens |" "markdown: with --since the header carries the delta columns"
eq "$(printf '%s\n' "$RS_OUT" | grep -c '| new | new |')" "3" "markdown: new rows render new / new"

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

check_summary "check-render-size"
