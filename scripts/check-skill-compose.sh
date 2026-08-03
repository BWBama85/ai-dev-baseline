#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the partial skill override composer (scripts/lib/skill-compose.sh, #22).
#
# Exercises the composer end-to-end against a throwaway installed base skill + project overrides,
# with NO real baseline install:
#   ops        — append / prepend / replace land in the right place; empty-replace deletes a body;
#   anchors    — list-anchors output; a fenced `### ` line is NOT an anchor; renumber-stable slug;
#   fences     — the WHOLE CommonMark rule, both delimiters, over anchors AND placement (#136/#131);
#   inherit    — the whole point: recomposing after the BASE changes picks up the new step;
#   currency   — `check` is byte-exact (stale on base change / hand-edit; current after recompose);
#   safety     — refuse to clobber a non-owned fork; reject a traversal name; v1 agent guard;
#   fail-loud  — unknown/duplicate anchor, unknown op, malformed directive, missing end, stray token.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-skill-compose.sh   (exit 0 = all pass, 1 = a failure)

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
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
SC="$ROOT/scripts/lib/skill-compose.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
REPO="$work/repo"; GHOME="$work/home"
mkdir -p "$REPO" "$GHOME"
git init -q "$REPO"    # deterministic repo root for adb_repo_root

# Run the composer as a project's driving agent would: from $REPO, with the throwaway HOME.
sc() { ( cd "$REPO" && HOME="$GHOME" bash "$SC" "$@" ); }

BASEDIR="$GHOME/.claude/skills"
OVROOT="$REPO/.claude/skills"

# Write the installed BASE skill for <name>. Includes a fenced block whose `### ` line must NOT be
# treated as an anchor, and a numbered close-out step (slug drops the number).
mk_base() {
  local name="$1"
  mkdir -p "$BASEDIR/$name"
  cat > "$BASEDIR/$name/SKILL.md" <<'EOF'
---
# GENERATED FILE — do not edit by hand.
name: __NAME__
description: A base skill for tests.
user-invocable: true
---

# /__NAME__

Intro text.

### 1. Preflight

Do preflight things.

### 6. Implement

Write the code.

```sh
### this is a shell comment, not a heading
echo hi
```

More implement text.

### 12. File issues (mandatory)

File deferred work.
EOF
  # Substitute the name (kept out of the quoted heredoc so no expansion surprises).
  sed "s/__NAME__/$name/g" "$BASEDIR/$name/SKILL.md" > "$BASEDIR/$name/SKILL.md.tmp"
  mv "$BASEDIR/$name/SKILL.md.tmp" "$BASEDIR/$name/SKILL.md"
}

# Write an overrides.md for <name> from stdin.
mk_ov() { local name="$1"; mkdir -p "$OVROOT/$name"; cat > "$OVROOT/$name/overrides.md"; }
out_of() { printf '%s' "$OVROOT/$1/SKILL.md"; }

# =========================== list-anchors ===========================
mk_base demo
anchors="$(sc list-anchors demo)"
has "$anchors" "preflight"             "list-anchors: preflight"
has "$anchors" "implement"             "list-anchors: implement"
has "$anchors" "file-issues-mandatory" "list-anchors: number-stripped close-out slug"
hasnt "$anchors" "this-is-a-shell-comment" "list-anchors: fenced '### ' line is not an anchor"

# =========================== ops ===========================
mk_ov demo <<'EOF'
<!-- adb:skill demo -->
<!-- adb:override anchor="implement" op="append" -->
- [ ] APPENDED sign-off line.
<!-- adb:end -->
<!-- adb:override anchor="preflight" op="prepend" -->
> PREPENDED runbook note.
<!-- adb:end -->
<!-- adb:override anchor="file-issues-mandatory" op="replace" -->
REPLACED milestone decision tree.
<!-- adb:end -->
EOF
sc compose demo >/dev/null; yes $? "compose demo (all three ops)"
comp="$(cat "$(out_of demo)")"
has "$comp" "APPENDED sign-off line."      "append content present"
has "$comp" "Write the code."              "append preserves original step body"
has "$comp" "PREPENDED runbook note."      "prepend content present"
has "$comp" "REPLACED milestone decision"  "replace content present"
hasnt "$comp" "File deferred work."        "replace removed the original body"
has "$comp" "More implement text."         "append lands after the whole step body (fence intact)"
has "$comp" "echo hi"                       "fenced code inside a step is preserved"

# prepend lands right after the heading (before the original first body line)
prepend_after="$(printf '%s\n' "$comp" | awk '/^### 1\. Preflight/{getline; print; exit}')"
has "$prepend_after" "PREPENDED" "prepend sits immediately after its heading"

# replace on a step that CONTAINS a fenced code block must drop the whole body — including the
# fence delimiters (regression: the fence rule used to print during a replace-skip, leaking an
# empty ``` ``` pair) — and must not corrupt fence tracking for later steps.
mk_base repfence
mk_ov repfence <<'EOF'
<!-- adb:override anchor="implement" op="replace" -->
REPLACED whole implement step.
<!-- adb:end -->
EOF
sc compose repfence >/dev/null 2>&1; yes $? "compose replace over a fenced step"
rf="$(cat "$(out_of repfence)")"
has  "$rf" "REPLACED whole implement step." "replace body present"
hasnt "$rf" "echo hi"          "replace dropped the fenced code content"
hasnt "$rf" "Write the code."  "replace dropped the original step body"
hasnt "$rf" '```sh'            "replace did not leak the opening fence delimiter"
hasnt "$rf" "More implement text." "replace dropped body text after the fence"
has  "$rf" "File deferred work." "a later step still renders (fence state not corrupted)"

# An EMPTY overrides.md is a no-op, not an error (base-file detection is by FILENAME, not a
# record counter that an empty first file would never advance).
mk_base emptyov; mk_ov emptyov </dev/null
sc compose emptyov >/dev/null 2>&1; yes $? "empty overrides.md composes (base + marker, no error)"
has "$(cat "$(out_of emptyov)")" "# adb:composed-skill" "empty-overrides output still carries the marker"

# =========================== output validity ===========================
eq "$(head -n1 "$(out_of demo)")" "---" "composed output starts with '---'"
has "$comp" "# adb:composed-skill"  "composed output carries the ownership marker"
has "$comp" "name: demo"            "composed output keeps name:"
has "$comp" "user-invocable: true"  "composed output keeps user-invocable:"
hasnt "$comp" "adb:override"        "no adb:override residue in output"
hasnt "$comp" "adb:end"             "no adb:end residue in output"

# =========================== idempotency ===========================
sc compose demo >/dev/null
a="$(cat "$(out_of demo)")"
sc compose demo >/dev/null
b="$(cat "$(out_of demo)")"
eq "$a" "$b" "compose is idempotent (twice → identical)"

# =========================== currency / inherit future changes ===========================
sc check demo >/dev/null 2>&1; yes $? "check: current right after compose"
# The whole point of #22: a NEW step added to the base is inherited on recompose.
printf '\n### 20. New Baseline Step\n\nnew baseline content.\n' >> "$BASEDIR/demo/SKILL.md"
sc check demo >/dev/null 2>&1; no $? "check: STALE after the base gains a step"
sc compose demo >/dev/null;    yes $? "recompose after base change"
has "$(cat "$(out_of demo)")" "New Baseline Step" "recompose inherited the new base step"
sc check demo >/dev/null 2>&1; yes $? "check: current again after recompose"
# A hand-edit to the composed output is also caught (byte-exact, not input-hash).
printf '\nHAND EDIT\n' >> "$(out_of demo)"
sc check demo >/dev/null 2>&1; no $? "check: STALE after a hand-edit to the composed output"
sc compose demo >/dev/null   # restore

# =========================== clobber-guard ===========================
mk_base fork
mk_ov fork <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
x
<!-- adb:end -->
EOF
printf -- '--- a hand-authored full fork ---\n' > "$OVROOT/fork/SKILL.md"   # NO ownership marker
sc compose fork >/dev/null 2>&1; no $? "compose refuses to clobber a non-owned SKILL.md"
has "$(cat "$OVROOT/fork/SKILL.md")" "hand-authored full fork" "the hand fork is left intact"
# Once it IS ours (has the marker), recompose overwrites freely.
mk_ov owned <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
y
<!-- adb:end -->
EOF
mk_base owned
sc compose owned >/dev/null 2>&1; yes $? "first compose of an owned skill"
sc compose owned >/dev/null 2>&1; yes $? "recompose an owned (marked) skill is allowed"

# Override content may legitimately mention "adb:end…" (e.g. an <!-- adb:endpoint --> comment) —
# the residue self-check must match only real directive shapes, not that substring.
mk_base endsub
mk_ov endsub <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
See the `<!-- adb:endpoint /v1/foo -->` marker for details.
<!-- adb:end -->
EOF
sc compose endsub >/dev/null 2>&1; yes $? "content mentioning adb:endpoint composes (no false residue error)"
has "$(cat "$(out_of endsub)")" "adb:endpoint /v1/foo" "the adb:endpoint mention survives into the output"

# The clobber-guard inspects only the top of the file, so a hand fork that merely MENTIONS the
# ownership marker deep in its body is still correctly refused (not mistaken for our output).
mk_base markbody
mk_ov markbody <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
x
<!-- adb:end -->
EOF
{ printf -- '--- a hand fork ---\n'; i=0; while [ "$i" -lt 12 ]; do echo "filler"; i=$((i+1)); done; \
  echo "# adb:composed-skill mentioned in prose"; } > "$OVROOT/markbody/SKILL.md"
sc compose markbody >/dev/null 2>&1; no $? "clobber-guard refuses a fork that only mentions the marker in its body"
has "$(cat "$OVROOT/markbody/SKILL.md")" "a hand fork" "that fork is left intact"

# =========================== fail-loud errors ===========================
err_case() {  # err_case <name> <label>  — overrides from stdin; assert compose is nonzero + no output written
  local name="$1" label="$2"
  mk_base "$name"; mk_ov "$name"
  sc compose "$name" >/dev/null 2>&1; no $? "$label"
  [ ! -e "$OVROOT/$name/SKILL.md" ] && ok || bad "$label: no output should be written on failure"
}
err_case unknown_anchor "unknown anchor fails loud" <<'EOF'
<!-- adb:override anchor="nonexistent-step" op="append" -->
x
<!-- adb:end -->
EOF
err_case fenced_anchor "an anchor that only matches a fenced '### ' line fails" <<'EOF'
<!-- adb:override anchor="this-is-a-shell-comment-not-a-heading" op="append" -->
x
<!-- adb:end -->
EOF
err_case dup_anchor "duplicate anchor fails loud" <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
a
<!-- adb:end -->
<!-- adb:override anchor="implement" op="prepend" -->
b
<!-- adb:end -->
EOF
err_case bad_op "unknown op fails loud" <<'EOF'
<!-- adb:override anchor="implement" op="splice" -->
x
<!-- adb:end -->
EOF
err_case malformed "malformed directive (extra attribute) fails loud" <<'EOF'
<!-- adb:override anchor="implement" op="append" mode="x" -->
x
<!-- adb:end -->
EOF
err_case missing_end "missing adb:end fails loud" <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
x
EOF
err_case stray_end "stray adb:end fails loud" <<'EOF'
<!-- adb:end -->
EOF
err_case typo_directive "typo'd directive outside a block fails loud" <<'EOF'
<!-- adb:overide anchor="implement" op="append" -->
x
<!-- adb:end -->
EOF

# =========================== safety / guards ===========================
# A traversal name is rejected before any path use.
sc compose "../evil" >/dev/null 2>&1; no $? "traversal skill name is rejected"
[ ! -e "$work/evil" ] && [ ! -e "$REPO/../evil" ] && ok || bad "traversal name must not create files outside the skills dir"
# v1 is Claude-only.
sc compose --agent codex demo >/dev/null 2>&1; no $? "v1 refuses --agent codex"
# Missing pieces error cleanly.
mk_ov lonely <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
x
<!-- adb:end -->
EOF
sc compose lonely >/dev/null 2>&1; no $? "missing installed base skill fails loud"
mk_base baseonly
sc compose baseonly >/dev/null 2>&1; no $? "missing overrides file fails loud"

# =========================== discovery (no NAME) ===========================
# Fresh repo so only valid overrides are discovered.
REPO2="$work/repo2"; mkdir -p "$REPO2"; git init -q "$REPO2"
sc2() { ( cd "$REPO2" && HOME="$GHOME" bash "$SC" "$@" ); }
for n in one two; do
  mkdir -p "$BASEDIR/$n"; cp "$BASEDIR/demo/SKILL.md" "$BASEDIR/$n/SKILL.md"
  mkdir -p "$REPO2/.claude/skills/$n"
  cat > "$REPO2/.claude/skills/$n/overrides.md" <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
- discovered delta.
<!-- adb:end -->
EOF
done
sc2 compose >/dev/null 2>&1; yes $? "discovery: compose with no NAME composes every overrides dir"
[ -f "$REPO2/.claude/skills/one/SKILL.md" ] && [ -f "$REPO2/.claude/skills/two/SKILL.md" ] && ok \
  || bad "discovery should have composed both skills"
sc2 check >/dev/null 2>&1; yes $? "discovery: check with no NAME reports all current"

# =========================== bot-review regressions (PR #65) ===========================
# (I) A missing --repo/--agent operand must error, not spin forever on `shift 2`.
sc check --repo >/dev/null 2>&1; no $? "--repo with no value errors (does not hang)"
sc compose --agent >/dev/null 2>&1; no $? "--agent with no value errors (does not hang)"

# (L) A write failure (read-only skill dir) must propagate, not report success.
mk_base rofail
mk_ov rofail <<'EOF'
<!-- adb:override anchor="implement" op="append" -->
x
<!-- adb:end -->
EOF
sc compose rofail >/dev/null 2>&1; yes $? "seed an owned output before making the dir read-only"
chmod 555 "$OVROOT/rofail"
sc compose rofail >/dev/null 2>&1; no $? "compose reports failure when the output can't be written"
chmod 755 "$OVROOT/rofail"    # restore so the EXIT trap can clean up

# (Q) An INDENTED fenced block (under a list item) must be recognized as a fence, so a `### ` line
# inside it is not advertised as an anchor nor spliced into.
mk_indent() {
  mkdir -p "$BASEDIR/$1"
  cat > "$BASEDIR/$1/SKILL.md" <<'EOF'
---
name: __N__
description: d.
user-invocable: true
---
# /__N__
### 1. Real Step

- An example under a list item:

   ```sh
### fake heading inside an indented fence
   ```

trailing real-step text.

### 2. Second Step

body
EOF
  sed "s/__N__/$1/g" "$BASEDIR/$1/SKILL.md" > "$BASEDIR/$1/SKILL.md.t"; mv "$BASEDIR/$1/SKILL.md.t" "$BASEDIR/$1/SKILL.md"
}
mk_indent indented
ianch="$(sc list-anchors indented)"
has  "$ianch" "real-step"    "indented fence: real step is an anchor"
has  "$ianch" "second-step"  "indented fence: step after the fence is an anchor"
hasnt "$ianch" "fake-heading" "indented fence: a '### ' inside it is NOT an anchor"
mk_ov indented <<'EOF'
<!-- adb:override anchor="real-step" op="append" -->
APPENDED to real step.
<!-- adb:end -->
EOF
sc compose indented >/dev/null 2>&1; yes $? "compose over an indented-fence base"
ic="$(cat "$(out_of indented)")"
has "$ic" "### fake heading inside an indented fence" "the fenced fake heading is preserved verbatim"
has "$ic" "APPENDED to real step." "append landed in the real step"

# ================= (R) THE WHOLE FENCE RULE (#131 / #136) =================  # adb-claim-ok: #131 is closed NOT_PLANNED, superseded by #136
# The composer used to carry its own fence detector: a boolean toggle on any ``` after 0-3 spaces.
# That is a fraction of CommonMark, and every missing clause is a `### ` line classified wrongly —
# in BOTH directions, which is why each case below says which one it guards:
#
#   HIDES a real step  — the composer refuses the anchor, so an override that targets it FAILS
#                        LOUD ("not a '### ' step heading"). Loud, and the project is stuck.
#   ADVERTISES a fake  — `list-anchors` offers an anchor inside quoted example code, and an
#                        override aimed at it splices project text INTO a code block. Silent, and
#                        the composed SKILL.md ships wrong.
#
# Both were live at the time these were written: a `~~~` fence advertised its contents, and the
# ``` that closed a longer run left the toggle inverted for the whole rest of the file.
#
# Each shape gets its OWN base skill: one tangled document would make a single mis-classification
# cascade through every later assertion, and the failure message would name the wrong clause.
mk_fence_base() {                 # mk_fence_base <name>  — body on stdin, after the frontmatter
  local name="$1"
  mkdir -p "$BASEDIR/$name"
  {
    printf -- '---\n'
    printf -- 'name: %s\n' "$name"
    printf -- 'description: A fence-rule base skill.\n'
    printf -- 'user-invocable: true\n'
    printf -- '---\n\n'
    printf -- '# /%s\n\n' "$name"
    cat
  } > "$BASEDIR/$name/SKILL.md"
}

# (R1) A ~~~ fence is a fence. The reported #131 drift (adb-claim-ok: closed NOT_PLANNED,
# superseded by #136): `roadmap-lib` honored both delimiters and
# the composer honored only backticks, so this exact document classified differently in two
# installed libraries. ADVERTISES-a-fake, and the step AFTER it was fine, so nothing looked wrong.
mk_fence_base tildef <<'EOF'
### 1. Tilde Step

~~~
### fake tilde heading
~~~

after tilde.

### 2. Second Step

body
EOF
ta="$(sc list-anchors tildef)"
has   "$ta" "tilde-step"          "R1 tilde: the real step is an anchor"
has   "$ta" "second-step"         "R1 tilde: the step after the fence is an anchor"
hasnt "$ta" "fake-tilde-heading"  "R1 tilde: ADVERTISES-a-fake — a '### ' inside ~~~ is not an anchor"

# (R2) PLACEMENT, not just advertisement. An anchor the composer gets wrong does not merely print
# wrong — `append` inserts "at the END of the step, before the next '### '", so a phantom heading
# inside a fence PULLS the project's text into the code block. Assert the ORDER, because the text
# is present either way and a `has` alone would pass on the broken placement.
mk_ov tildef <<'EOF'
<!-- adb:override anchor="tilde-step" op="append" -->
APPENDED-BY-PROJECT
<!-- adb:end -->
EOF
sc compose tildef >/dev/null 2>&1; yes $? "R2 tilde: compose over a ~~~-fenced base"
tc="$(out_of tildef)"
ln_app="$(grep -n 'APPENDED-BY-PROJECT' "$tc" | head -1 | cut -d: -f1)"
ln_end="$(grep -n 'after tilde\.' "$tc" | head -1 | cut -d: -f1)"
ln_two="$(grep -n '^### 2\. Second Step' "$tc" | head -1 | cut -d: -f1)"
# Capture each verdict in its own variable: `$( … ; echo $? )` after a `[ … ]` chain reports the
# CONDITION's status, which shellcheck rejects (SC2319) precisely because it is easy to misread.
ord_after=1; [ -n "$ln_app" ] && [ -n "$ln_end" ] && [ "$ln_app" -gt "$ln_end" ] && ord_after=0
ord_before=1; [ -n "$ln_app" ] && [ -n "$ln_two" ] && [ "$ln_app" -lt "$ln_two" ] && ord_before=0
yes "$ord_after"  "R2 tilde: the append lands AFTER the fence's own step body, not inside the fence"
yes "$ord_before" "R2 tilde: ...and still before the next step heading"
has "$(cat "$tc")" '### fake tilde heading' "R2 tilde: the fenced example line survives verbatim"

# (R3) RUN LENGTH. A closer must be at least as long as its opener, so the ``` inside a ```` block
# is content. The old toggle closed on it, then read the real ```` closer as a fresh OPENER —
# HIDES-a-real-step for every heading in the rest of the file, which is the worst shape here.
mk_fence_base runlen <<'EOF'
### 1. Run Step

````
### fake long-run heading
```
### still fake, the short run does not close
````

### 2. After Run

body
EOF
ra="$(sc list-anchors runlen)"
has   "$ra" "run-step"    "R3 run-length: the real step is an anchor"
has   "$ra" "after-run"   "R3 run-length: HIDES-a-real-step — the step after a ```` block is still an anchor"
hasnt "$ra" "fake-long-run-heading"                 "R3 run-length: ADVERTISES-a-fake — inside the block"
hasnt "$ra" "still-fake-the-short-run-does-not-close" "R3 run-length: ...a shorter run is content, not a closer"

# (R4) A CLOSER CARRIES NOTHING BUT WHITESPACE. `\`\`\` nope` is content; treating it as a closer
# re-opens on the real one. HIDES-a-real-step, same cascade as R3.
mk_fence_base trailer <<'EOF'
### 1. Trailer Step

```
### fake trailing heading
``` nope
### also fake, the closer above carried text
```

### 2. After Trailer

body
EOF
tra="$(sc list-anchors trailer)"
has   "$tra" "trailer-step"   "R4 closer-text: the real step is an anchor"
has   "$tra" "after-trailer"  "R4 closer-text: HIDES-a-real-step — the step after the block is an anchor"
hasnt "$tra" "fake-trailing-heading"                      "R4 closer-text: ADVERTISES-a-fake — inside"
hasnt "$tra" "also-fake-the-closer-above-carried-text"    "R4 closer-text: ...a closer with trailing text is content"

# (R5) THE OTHER DELIMITER NEVER CLOSES THE CURRENT FENCE — that is what makes ``` inside ~~~ (and
# the reverse) plain content. ADVERTISES-a-fake in both nestings.
mk_fence_base nestf <<'EOF'
### 1. Nest Step

~~~text
```
### fake inside a backtick run inside a tilde fence
```
~~~

### 2. Reverse Nest

```text
~~~
### fake inside a tilde run inside a backtick fence
~~~
```

### 3. After Nest

body
EOF
na="$(sc list-anchors nestf)"
has   "$na" "nest-step"     "R5 nesting: the first real step is an anchor"
has   "$na" "reverse-nest"  "R5 nesting: the middle real step is an anchor"
has   "$na" "after-nest"    "R5 nesting: HIDES-a-real-step — the step after both blocks is an anchor"
# A literal backtick run inside a DOUBLE-quoted argument opens a legacy command substitution — a
# parse error that still reports as a PASS. These labels therefore spell the delimiters out.
hasnt "$na" "fake-inside-a-backtick-run-inside-a-tilde-fence" \
      "R5 nesting: ADVERTISES-a-fake — a backtick run inside a tilde fence"
hasnt "$na" "fake-inside-a-tilde-run-inside-a-backtick-fence" \
      "R5 nesting: ...and a tilde run inside a backtick fence"

# (R6) AN INFO STRING MAY NOT CONTAIN A BACKTICK on a backtick fence (CommonMark), so that line is
# ordinary text and the heading under it is REAL. HIDES-a-real-step; the tilde form has no such
# restriction, which is why the two probes are sequential rather than one rule.
mk_fence_base infostr <<'EOF'
### 1. Info Step

```sh `x`
### a real heading, because the line above is not a fence opener
```
genuinely fenced
```

### 2. After Info

body
EOF
ia2="$(sc list-anchors infostr)"
has "$ia2" "info-step"   "R6 info-string: the real step is an anchor"
has "$ia2" "after-info"  "R6 info-string: HIDES-a-real-step — the step after the block is an anchor"
has "$ia2" "a-real-heading-because-the-line-above-is-not-a-fence-opener" \
    "R6 info-string: HIDES-a-real-step — a backtick in the info string means no fence opened"

# (R7) A 4-SPACE-INDENTED delimiter is an indented code block, not a fence — so it must not open
# one. The old rule agreed here (n <= 3); pinned so the shared rule cannot lose it. ADVERTISES-a-
# fake is the risk if a later rewrite starts opening on it and then never closes.
mk_fence_base indent4 <<'EOF'
### 1. Indent Step

    ```
    ### fake, and this is an indented code block anyway
    ```

### 2. After Indent

body
EOF
i4="$(sc list-anchors indent4)"
has  "$i4" "indent-step"  "R7 indent: the real step is an anchor"
has  "$i4" "after-indent" "R7 indent: HIDES-a-real-step — a 4-space run opens no fence to swallow it"

# (R8) CRLF IS DELIBERATELY NOT ASSERTED HERE, and saying so is better than a fixture that looks
# like coverage. `roadmap-lib` needs CR normalization because it reads GitHub bodies, which arrive
# CRLF from the web UI. The composer reads an INSTALLED base skill that `scripts/build.sh` wrote,
# so it is always LF — and a CRLF one is rejected several steps earlier, by the frontmatter test
# (`$0 != "---"` sees `---\r`), long before any fence logic runs. Asserting the fence half here
# would pin a path that cannot be reached; making the composer CRLF-tolerant is a frontmatter
# change, not this one.
# (E) A no-name check/compose must FAIL on an orphaned owned output (composed SKILL.md whose
# overrides.md is gone) — a frozen-fork shadow the currency gate would otherwise miss.
REPO3="$work/repo3"; mkdir -p "$REPO3"; git init -q "$REPO3"
sc3() { ( cd "$REPO3" && HOME="$GHOME" bash "$SC" "$@" ); }
mkdir -p "$REPO3/.claude/skills/orphan"
cp "$BASEDIR/demo/SKILL.md" "$BASEDIR/orphan/SKILL.md" 2>/dev/null || { mkdir -p "$BASEDIR/orphan"; cp "$BASEDIR/demo/SKILL.md" "$BASEDIR/orphan/SKILL.md"; }
# Seed an OWNED composed output (marker present) but NO overrides.md beside it.
mkdir -p "$REPO3/.claude/skills/orphan"
printf -- '---\n%s v1 — DO NOT EDIT BY HAND.\nname: orphan\n---\n# /orphan\n' "# adb:composed-skill" > "$REPO3/.claude/skills/orphan/SKILL.md"
sc3 check   >/dev/null 2>&1; no $? "no-name check fails on an orphaned composed output"
sc3 compose >/dev/null 2>&1; no $? "no-name compose fails on an orphaned composed output"

# ============ (S) adb_sc_paths — the RETURN CONVENTION, called directly (#258) ============
# Every assertion above reaches this function through the CLI, and none of them can see how it
# HANDS BACK its three paths — they observe only the file it eventually wrote. #258 replaced three
# shared globals with namerefs, and a nameref has FOUR failure modes no path-shaped assertion
# reaches. Three of them are SILENT, which is why each gets its own case:
#
#   collision — an output name matching the function's own `_asp_` prefix is a CIRCULAR reference.
#               bash prints a warning to stderr and the caller's variable stays unset, so the
#               caller silently composes against an empty path.  (S4, S5, S5b)
#   injection — `declare -n ref=$name` EVALUATES an array subscript in $name. In a library that
#               install.sh symlinks into every consumer's runtime, an unvalidated output name is a
#               command-execution seam, not a tidiness question.  (S6, and S10 proves it closed)
#   aliasing  — three names that are really ONE variable leave all three paths equal to the last
#               assignment: a wrong compose that looks like a working one.  (S9)
#   arity     — too few arguments. NOT silent, but worse: an unbound expansion under the caller's
#               `set -u` kills the caller outright rather than failing the call.  (S11)
#
# Sourced rather than shelled out, because the contract under test is the SOURCED one: `bash "$SC"`
# would exercise the CLI again and prove nothing new.
sc_paths() {   # sc_paths <out1> <out2> <out3> -> "base|ov|out" on success, "RC<n>" on refusal
  ( set +u
    # shellcheck source=/dev/null
    . "$SC"
    adb_sc_paths demo /r /h "$1" "$2" "$3" || { printf 'RC%s\n' "$?"; exit 0; }
    printf '%s|%s|%s\n' "${!1-}" "${!2-}" "${!3-}"
  ) 2>/dev/null
}
eq "$(sc_paths p_base p_ov p_out)" "/h/.claude/skills/demo/SKILL.md|/r/.claude/skills/demo/overrides.md|/r/.claude/skills/demo/SKILL.md" \
   "S1 adb_sc_paths writes all three paths into the caller's OWN variables"

# The caller's names are arbitrary — including names that look nothing like the old globals. A
# conversion that kept writing fixed globals and merely accepted the arguments would pass S1 only
# by accident of naming, and fails here.
eq "$(sc_paths zzz_a zzz_b zzz_c)" "/h/.claude/skills/demo/SKILL.md|/r/.claude/skills/demo/overrides.md|/r/.claude/skills/demo/SKILL.md" \
   "S2 ...whatever the caller chose to call them"

# The superseded globals must be GONE, not left behind as a second, drifting output channel.
gl="$( ( set +u; . "$SC"; adb_sc_paths demo /r /h p_base p_ov p_out; printf '[%s][%s][%s]' "${_sc_base-}" "${_sc_ov-}" "${_sc_out-}" ) 2>/dev/null )"
eq "$gl" "[][][]" "S3 the pre-#258 _sc_base/_sc_ov/_sc_out globals are no longer written"

# Collision and injection are REFUSALS with a status, not warnings. `_asp_out` is one of the
# function's own nameref locals; `a[$(…)]` is the subscript-evaluation seam.
eq "$(sc_paths _asp_out o u)"  "RC2" "S4 an output name colliding with the function's own local is refused"
eq "$(sc_paths _asp_n o u)"    "RC2" "S5 ...including its non-nameref locals"
# ...and a name that is NOT a local today. The rule is the `_asp_` PREFIX, not an enumeration of
# the current locals, so adding a local later cannot open a hole in it. An enumeration would pass
# this case and then fail silently the day someone declares `_asp_zzz`.
eq "$(sc_paths _asp_zzz o u)"  "RC2" "S5b ...and any future local, because the rule is the prefix"
eq "$(sc_paths 'a[$(id)]' o u)" "RC2" "S6 a non-identifier output name is refused before declare -n can evaluate it"
eq "$(sc_paths '' o u)"        "RC2" "S7 an empty output name is refused"
eq "$(sc_paths 9bad o u)"      "RC2" "S8 an output name starting with a digit is refused"
# Three names that are really ONE variable would make all three paths the last assignment — a
# silently wrong compose, which is exactly the shape a nameref API invites.
eq "$(sc_paths same same same)" "RC2" "S9 duplicate output names are refused rather than aliased"

# TOO FEW ARGUMENTS MUST BE A RETURN, NOT A DEAD SHELL. This library is SOURCED — by its own
# callers and by consumer hooks — so an unbound expansion under the caller's `set -u` does not fail
# the call, it kills the caller. `$4` unguarded did exactly that, which turned a stale pre-#258
# 3-argument call from a clean refusal into a hook that dies with "unbound variable". The guarded
# `${4-}` makes a missing name an empty one, which the validation above already rejects.
short="$( ( set -u; . "$SC"; adb_sc_paths demo /r /h; printf 'RC%s' "$?"; printf ' ALIVE' ) 2>/dev/null )"
eq "$short" "RC2 ALIVE" "S11 a call with too few arguments returns 2 and leaves the caller's shell alive"

# The injection seam via a LITERAL argument, proven CLOSED rather than merely refused: if the
# subscript were evaluated, the marker file would exist. Note what this does NOT cover — S12.
( set +u; . "$SC"; adb_sc_paths demo /r /h "a[\$(touch '$work/pwned')]" o u ) >/dev/null 2>&1 || true
[ ! -e "$work/pwned" ] && ok || bad "S10 a literal subscript in an output name is never evaluated"

# S12 — THE SEAM S10 COULD NOT SEE, and the reason a spelling check is not a validation.
# `declare -n` CHAINS: if the caller's variable is itself a nameref, binding to it resolves to THAT
# nameref's target — a string this function never received as an argument and never checked. So the
# hostile payload never appears in any argument, S10's premise fails, and the subscript is evaluated
# on assignment. Reproduced by the independent review against the first cut of this change, which
# returned 0 and created the marker.
rm -f "$work/pwned2"
# `evil` is referenced BY NAME (as a string argument), which shellcheck cannot follow — that
# indirection is the whole point of the case.
# shellcheck disable=SC2034
chain="$( ( set +u
            . "$SC"
            declare -n evil="arr[\$(touch '$work/pwned2')]"
            adb_sc_paths demo /r /h evil o2 u2; printf 'RC%s' "$?" ) 2>/dev/null )"
eq "$chain" "RC2" "S12 an output name that is ALREADY a nameref is refused (declare -n would chain)"
[ ! -e "$work/pwned2" ] && ok || bad "S12 ...and the chained subscript is never evaluated"

# S13 — a readonly target. Rejected BEFORE the assignment, not after: bash aborts the whole function
# on an assignment to a readonly variable, so a post-hoc verification never runs and the caller gets
# bash's status instead of this function's documented 2.
# shellcheck disable=SC2034  # `frozen` is referenced by name, like `evil` above.
ro="$( ( set +u; . "$SC"; readonly frozen=1; adb_sc_paths demo /r /h frozen o3 u3; printf 'RC%s' "$?" ) 2>/dev/null )"
eq "$ro" "RC2" "S13 a readonly output name is refused with 2, not an aborted function"

# S14 — a name that ACCEPTS the assignment and silently discards it. `BASH_MONOSECONDS` is the
# worked example: `declare -p` shows nothing unusual, the assignment returns 0, and the variable
# goes on reporting the clock. Only checking the OUTCOME catches this class.
sp="$( ( set +u; . "$SC"; adb_sc_paths demo /r /h BASH_MONOSECONDS o4 u4; printf 'RC%s' "$?" ) 2>/dev/null )"
eq "$sp" "RC2" "S14 an output name that silently discards its value is refused"

# S15 — the library's own state. A caller's typo must not overwrite `_ADB_SC_AGENT` mid-call and
# leave every path this function builds silently malformed.
lib="$( ( set +u; . "$SC"; adb_sc_paths demo /r /h _ADB_SC_AGENT o5 u5; printf 'RC%s' "$?" ) 2>/dev/null )"
eq "$lib" "RC2" "S15 a library-owned _ADB_SC_* output name is refused"

# S16 — AN INTEGER-ATTRIBUTED TARGET, the second way an assignment kills the caller (bot review).
# `declare -i tgt` makes every assignment to `tgt` an ARITHMETIC evaluation, so storing a path into
# it raises "arithmetic syntax error" and terminates the caller — the same class as the readonly
# target in S13, and equally invisible to the outcome check, which never runs. Measured: without
# the pre-check the probe emits neither a status nor its liveness marker.
intg="$( ( set +u; . "$SC"; declare -i tgt; adb_sc_paths demo /r /h tgt o6 u6; printf 'RC%s' "$?"; printf ' ALIVE' ) 2>/dev/null )"
eq "$intg" "RC2 ALIVE" "S16 an integer-attributed output name is refused, and the caller survives"

# S17 — a case-TRANSFORMING target (`declare -u`) is refused rather than silently storing a
# corrupted path. This one the outcome check would already catch; asserting it pins the ATTRIBUTE
# rule rather than leaving the coverage to a downstream comparison that a later edit could weaken.
upc="$( ( set +u; . "$SC"; declare -u tgt; adb_sc_paths demo /r /h tgt o7 u7; printf 'RC%s' "$?"; printf ' ALIVE' ) 2>/dev/null )"
eq "$upc" "RC2 ALIVE" "S17 a case-transforming output name is refused"

# S18 — AND THE OVER-TIGHTENING GUARD, which matters as much as the rejections. An ARRAY target is
# demonstrably fine: bash stores the scalar at index 0 and `$tgt` reads it straight back, so a rule
# written to reject `-i` must not sweep `-a`/`-A`/`-x` up with it. This passes before and after the
# attribute rule; it exists so a future tightening cannot quietly break a working caller.
# SC2128 (bare array expansion gives element 0) is the ASSERTION here, not an accident: what makes
# an array target usable is exactly that `$tgt` reads back what was stored at index 0.
# shellcheck disable=SC2128
arrv="$( ( set +u; . "$SC"; declare -a tgt; adb_sc_paths demo /r /h tgt o8 u8; printf 'RC%s|%s' "$?" "${tgt}" ) 2>/dev/null )"
eq "$arrv" "RC0|/h/.claude/skills/demo/SKILL.md" "S18 an array-attributed output still works (the rejection is not over-broad)"

check_summary "check-skill-compose"
