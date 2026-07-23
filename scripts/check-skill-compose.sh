#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the partial skill override composer (scripts/lib/skill-compose.sh, #22).
#
# Exercises the composer end-to-end against a throwaway installed base skill + project overrides,
# with NO real baseline install:
#   ops        — append / prepend / replace land in the right place; empty-replace deletes a body;
#   anchors    — list-anchors output; a fenced `### ` line is NOT an anchor; renumber-stable slug;
#   inherit    — the whole point: recomposing after the BASE changes picks up the new step;
#   currency   — `check` is byte-exact (stale on base change / hand-edit; current after recompose);
#   safety     — refuse to clobber a non-owned fork; reject a traversal name; v1 agent guard;
#   fail-loud  — unknown/duplicate anchor, unknown op, malformed directive, missing end, stray token.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-skill-compose.sh   (exit 0 = all pass, 1 = a failure)

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

check_summary "check-skill-compose"
