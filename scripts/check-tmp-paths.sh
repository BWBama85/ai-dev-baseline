#!/usr/bin/env bash
# ai-dev-baseline — run data may not land on a fixed, host-shared path (#250).
#
# WHY THIS EXISTS. /implement-issue step 2 snapshots the issue it is about to build — the untrusted
# body, every comment, and the `author_association` provenance label #214 added so a dispatched
# agent can tell a maintainer's assignment from a stranger's comment. It wrote both files to a
# fixed path under the system temp directory, named by issue number alone, and read them back
# MINUTES later in step 3 and again in step 8.
#
# That directory is world-writable, shared by every checkout and every worktree on the host, and
# the name was fully determined by a PUBLIC issue number. So:
#
#   * COLLISION, no attacker required. Two runs on one issue number — two clones, two worktrees,
#     two agents — shared both files. The second run's `>` truncated the first's snapshot while
#     the first was still reading it.
#   * TOCTOU on a TRUST SIGNAL. Minutes separated the write from the read, so any local process
#     could drop `OWNER` into the `.assoc` and the dispatched agent would be told a stranger's
#     text carried maintainer standing.
#
# The fix moves the snapshot under `{{STATE_DIR}}` — repo-relative and per-agent (`.<agent>/state`),
# which is exactly the boundary `implement-lib.sh admit` already enforces. This file is what stops
# it drifting back.
#
# WHAT IS AND IS NOT CLAIMED, because a guard that overstates itself is worse than none:
#
#   * PROVEN: the snapshot's path is anchored to the CHECKOUT, so two runs in two checkouts cannot
#     name the same file. Part 1 demonstrates that by resolving the workflow's own path expression
#     under two distinct roots and requiring the answers to differ.
#   * NOT PROVEN HERE: two runs of one agent in ONE checkout. That is not a path question at all —
#     they share one HEAD — and it is refused outright by `implement-lib.sh admit` (#202), whose
#     own suite (`scripts/check-implement-lib.sh`) covers it. Two DIFFERENT agents in one checkout
#     do get different state dirs (`.claude/state` vs `.codex/state`), so part 1's property covers
#     their files, but they still race on HEAD and no path can fix that.
#   * NOT PROVEN AT ALL: integrity against a hostile process that can already write the run's state
#     directory. Leaving the shared temp directory removes a NAMESPACE any local account can reach;
#     it does not authenticate the file's contents. Say that; do not imply more.
#
# THREE PARTS:
#   1. the snapshot's path is per-checkout — asserted against the real markdown, source AND every
#      rendered skill, by resolving it under two roots;
#   2. no fixed shared-temp path anywhere in `base/`, `scripts/`, `docs/` or `agents/` — such a
#      literal must carry per-run entropy (`$$`, `$RANDOM`, an `XXXXXX` mktemp template) or an
#      explicit `adb-tmp-ok: <reason>` marker;
#   3. a mutation harness that injects the PRE-FIX spellings into a COPY of the tree and requires
#      each part to go red — because a scanner that matches nothing reports exactly what a clean
#      run reports (base/practices/self-review.md).
#
# DELIBERATELY OUT OF SCOPE, per #250's own survey: `.github/workflows/ci.yml`, whose one fixed
# path runs on an ephemeral single-tenant runner with no concurrency to collide with. Only `.md`
# and `.sh` under the four roots above are scanned, so that file is not reached.
#
# Usage: bash scripts/check-tmp-paths.sh   (exit 0 = pass, 1 = fail)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded.
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
check_init "tmp-paths"

ROOT="$PWD"
work="$(mktemp -d)" || { check_note "mktemp failed"; exit 1; }
trap 'rm -rf "$work"' EXIT

# THE TWO LITERALS THIS FILE MUST NEVER SPELL, held in variables instead.
#
# Every fixture and every mutator below has to produce the exact text the scanner hunts for. Typed
# out, those lines would be violations *of this scanner* sitting in the file that defines it, and
# the only ways out are both worse than this one: exempting the whole file (an exemption that then
# hides a real regression introduced here later) or marking each fixture line (which cannot be done
# at all inside a `for … in 'a' \` continuation, and which would make the marker fixture
# self-exempting besides — the same trap `check-claims-guard.sh` records for `adb-claim-ok`).
# Composing them at runtime keeps the source clean, keeps the scanner honest about its own file,
# and still hands the fixtures the real bytes.
TMP_LIT='/tmp'
MARK='adb-tmp-ok'

# The exemption contract, spelled exactly as `adb-claim-ok:` already is elsewhere: the marker alone
# is NOT enough, it must be followed by a non-space reason. A bare marker is a silent exemption,
# which is the thing this file exists to prevent one level down.
EXEMPT_RE="$MARK"':[[:space:]]*[^[:space:]]'

# Per-run entropy: what makes a shared-temp name safe to write.
#   $$        — the shell's pid, distinct per process (the spelling #250's acceptance names)
#   $RANDOM   — bash's per-shell PRNG
#   XXXXXX    — an mktemp template
# The `"${TMPDIR:-/tmp}/name.XXXXXX"` idiom this repo already uses everywhere is doubly safe: the
# closing brace means the hunted text never even appears, so the scanner has nothing to match.
#
# TAB-SEPARATED LITERALS, matched with `index()`, NOT a regex. The first cut passed these to awk as
# an alternation and the self-test caught it going wrong immediately: `awk -v` INTERPRETS backslash
# escapes in the assignment, so `\$\$` arrives as `$$`, which as a regex is two end-of-string
# anchors rather than two dollar signs — and `/tmp/adb-cl-meta.$$`, the one spelling #250's
# acceptance explicitly permits, was reported as a violation. Substring tests have no such layer.
ENTROPY_MARKERS='$$	$RANDOM	XXXXXX'

# The scanned roots. `agents/` is included even though it is generated: build-drift proves a render
# is CURRENT, never that it is CORRECT, so a placeholder that resolved to something host-global
# would otherwise be invisible to every gate.
SCAN_ROOTS=(base scripts docs agents)

# =============================================================================================
# 1. THE SNAPSHOT'S PATH IS PER-CHECKOUT
# =============================================================================================
#
# SOURCE-BOUND, never retyped. A test that spelled the intended path itself would assert only that
# the author can type it twice; this pulls the expression out of the markdown the agent actually
# executes and resolves THAT. The source carries `{{STATE_DIR}}`; each rendered skill carries the
# agent's resolved `.<agent>/state`. Both are checked, because they fail differently.

# snapshot_tokens <file> — print every path token in a fenced ```bash block that names the issue
# snapshot, one per line, deduped. Anchored on the FILENAME rather than on the surrounding command,
# so it survives the `gh issue view` / `jq` / `cat` lines being rewritten around it.
snapshot_tokens() {
  awk '
    /^```bash$/ { inb = 1; next }
    /^```/      { inb = 0; next }
    !inb { next }
    {
      line = $0
      # Every occurrence on the line, not just the first: the step-3 and step-8 blocks name the
      # .assoc and the .json within two lines of each other, and a first-match-only scan would
      # quietly halve the coverage.
      while (match(line, /[^"'"'"'`[:space:]]*issue-\$n\.(json|assoc)/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1" | sort -u
}

# resolve_under <root> <token> — the absolute path a shell running in <root> would open. This is
# the whole assertion in one function: an absolute token ignores <root> entirely (that is the bug),
# a relative one does not.
resolve_under() {
  case "$2" in
    /*) printf '%s\n' "$2" ;;
    *)  printf '%s/%s\n' "$1" "$2" ;;
  esac
}

# part1 <tree> — print one diagnostic line per violation; silence means clean. Also sets P1_SITES
# and P1_FILES in the caller's shell, which is why every call site uses bash 5.3's `${ …; }`
# function substitution rather than `$( … )`: the latter forks, and the counts would be lost.
P1_SITES=0
P1_FILES=0
part1() {
  local tree="$1" f tok a b n total=0 files=0 rendered
  # The source plus every rendered skill. Enumerated from the filesystem rather than listed, so a
  # fourth agent joins the check by existing.
  local -a files_to_scan=( "$tree/base/workflows/implement-issue.md" )
  for rendered in "$tree"/agents/*/skills/implement-issue/SKILL.md; do
    [ -f "$rendered" ] && files_to_scan+=( "$rendered" )
  done

  for f in "${files_to_scan[@]}"; do
    [ -f "$f" ] || { printf 'missing file: %s\n' "${f#"$tree"/}"; continue; }
    files=$((files + 1))
    n=0
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      n=$((n + 1)); total=$((total + 1))
      # `/A` and `/B` stand in for two checkouts. Real directories are unnecessary — nothing is
      # opened; the question is purely whether the resolved NAMES can differ.
      a="${ resolve_under /A "$tok"; }"
      b="${ resolve_under /B "$tok"; }"
      if [ "$a" = "$b" ]; then
        printf '%s: the issue snapshot resolves to ONE host-global path [%s] — two checkouts share it\n' \
          "${f#"$tree"/}" "$tok"
      fi
    done <<EOF
${ snapshot_tokens "$f"; }
EOF
    # A file that contributes ZERO tokens is the vacuous-guard case: a rename would otherwise turn
    # this whole part into a silent no-op that still prints PASS.
    [ "$n" -gt 0 ] || printf '%s: NO issue-snapshot path found — the scanner matched nothing, so it proved nothing\n' "${f#"$tree"/}"
  done
  [ "$files" -gt 0 ] || printf 'no implement-issue workflow or skill found at all\n'
  P1_SITES="$total"; P1_FILES="$files"
}

# The floor is deliberately low and is a VACUITY guard, not a spec: the exact site count moves
# whenever the workflow's prose is edited, and pinning it exactly would make this file a
# maintenance tax that teaches nothing. What must never happen is the set emptying out. Four trees
# (source + three renders) x two filenames is the arithmetic; the floor sits at half of it.
P1_FLOOR=4

hits="${ part1 "$ROOT"; }"
if [ -n "$hits" ]; then
  bad_quiet
  check_note "the issue snapshot is not anchored to the checkout:"
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
else
  ok
fi
# SAY WHAT WAS CHECKED. A count is the difference between "nothing was wrong" and "nothing was
# checked", and those read identically without it.
printf 'check-tmp-paths: %s issue-snapshot path site(s) across %s file(s) resolve per-checkout\n' \
  "$P1_SITES" "$P1_FILES"
if [ "$P1_SITES" -lt "$P1_FLOOR" ]; then
  bad "part 1 found only $P1_SITES snapshot site(s), floor is $P1_FLOOR — the scanner has stopped seeing them"
else
  ok
fi

# =============================================================================================
# 2. NO FIXED SHARED-TEMP PATH IN base/, scripts/, docs/ OR agents/
# =============================================================================================
#
# The belt to part 1's braces. Part 1 knows one filename; this knows the CLASS, so a future fixed
# path under any other name still fails.
#
# COMMENTS ARE STRIPPED IN `.sh` FILES ONLY, and the trade is stated rather than hidden: a `#`
# inside a shell string is stripped too, so this can only cause a MISSED report, never a false one
# — the same bargain `check-workflow-shell.sh` documents. Markdown is NOT stripped, because prose
# is exactly where `create-issue.md`'s fixed issue-body path lived; a markdown line that must name
# one carries the marker.
scan_fixed_tmp() {   # <tree> — print "<file>:<line>: <raw>" per violation
  local tree="$1" r
  local -a dirs=()
  for r in "${SCAN_ROOTS[@]}"; do [ -d "$tree/$r" ] && dirs+=( "$tree/$r" ); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # `find`, not a glob: base/ is two levels deep and scripts/ and agents/ have subdirectories.
  find "${dirs[@]}" -type f \( -name '*.md' -o -name '*.sh' \) 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r f; do
        awk -v exempt="$EXEMPT_RE" -v markers="$ENTROPY_MARKERS" -v rel="${f#"$tree"/}" -v pfx="$TMP_LIT/" '
          BEGIN { nmk = split(markers, mk, "\t") }
          # Substring tests, for the reason the ENTROPY_MARKERS comment gives.
          function has_entropy(tok,   k) {
            for (k = 1; k <= nmk; k++) if (index(tok, mk[k]) > 0) return 1
            return 0
          }
          {
            raw = $0
            # The exemption is read from the RAW line, before any stripping — otherwise a marker
            # written as a trailing shell comment would be removed before it could be seen.
            if (raw ~ exempt) next
            line = raw
            if (rel ~ /\.sh$/) sub(/(^|[[:space:]])#.*$/, "", line)
            # A CONCRETE name under the shared temp dir: the prefix plus at least one character
            # from a filename charset. The charset deliberately EXCLUDES `<`, so a documentation
            # placeholder such as the literal prefix followed by an angle-bracketed name is not
            # mistaken for a real path.
            while (1) {
              i = index(line, pfx)
              if (i == 0) break
              rest = substr(line, i + length(pfx))
              if (match(rest, /^[A-Za-z0-9._$*{}@%+,=:-]+/)) {
                tok = pfx substr(rest, 1, RLENGTH)
                if (!has_entropy(tok)) { printf "%s:%d: %s\n", rel, FNR, raw; break }
                line = substr(rest, RLENGTH + 1)
              } else {
                line = rest
              }
            }
          }
        ' "$f"
      done
}

hits="${ scan_fixed_tmp "$ROOT"; }"
if [ -n "$hits" ]; then
  bad_quiet
  check_note "fixed shared-temp path(s) — a name every checkout and every session on the host shares:"
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
  check_note 'use mktemp ("${TMPDIR:-/tmp}/name.XXXXXX"), a $$ suffix, or {{STATE_DIR}} for run state.'
  check_note "A line that must name one carries '$MARK: <reason>'."
else
  ok
fi

# --- part 2's own self-test: prove the scanner can SEE, and does not cry wolf -------------------
# Same discipline as check-workflow-shell.sh: a rule that silently matches nothing passes every
# clean tree. One fixture file at a time, so a missed shape is named precisely.
st="$work/selftest"
mkdir -p "$st/scripts" "$st/base"
mk() { printf '%s\n' "$2" > "$st/$1"; }

i=0
for badline in "cat foo > $TMP_LIT/adb-fixed.log" \
               "jq . \"$TMP_LIT/issue-\$n.json\"" \
               "diff $TMP_LIT/r1.md $TMP_LIT/r2.md" \
               "gh issue create --body-file $TMP_LIT/issue-body.md" \
               "printf x > \"$TMP_LIT/adb.\$USER.log\""; do
  i=$((i + 1))
  mk "scripts/bad$i.sh" "$badline"
  if [ -z "${ scan_fixed_tmp "$st"; }" ]; then
    bad "self-test: the scanner did NOT see [$badline] — it cannot catch the class it exists for"
  else
    ok
  fi
  rm -f "$st/scripts/bad$i.sh"
done

# The same shape in markdown, which is NOT comment-stripped and is where the create-issue site lived.
mk "base/badprose.md" "Use \`gh issue create --body-file $TMP_LIT/issue-body.md\` or a heredoc."
if [ -z "${ scan_fixed_tmp "$st"; }" ]; then
  bad "self-test: the scanner did NOT see a fixed shared-temp path in markdown PROSE"
else
  ok
fi
rm -f "$st/base/badprose.md"

j=0
for goodline in 'f="$(mktemp "${TMPDIR:-/tmp}/adb.XXXXXX")"' \
                "printf x > $TMP_LIT/adb-cl-meta.\$\$" \
                'd="$(mktemp -d "${TMPDIR:-/tmp}/roadmap.XXXXXX")"' \
                'x="${TMPDIR:-/tmp}/adb-rd-drain-$$"' \
                "cd $TMP_LIT" \
                "git remote add weird \"file://$TMP_LIT\"" \
                "echo \"if the fix adds a $TMP_LIT/<name> file, state the atomicity contract\"" \
                "# see $TMP_LIT/adb-selfcheck.log for the old spelling" \
                "echo \"$TMP_LIT/deliberate.log\"   # $MARK: a stated reason"; do
  j=$((j + 1))
  mk "scripts/good$j.sh" "$goodline"
  out="${ scan_fixed_tmp "$st"; }"
  if [ -n "$out" ]; then
    bad "self-test: FALSE POSITIVE on [$goodline] -> $out"
  else
    ok
  fi
  rm -f "$st/scripts/good$j.sh"
done

# The comment-stripping carve-out is `.sh`-ONLY. The identical line in markdown must still fire,
# or the rule silently stops covering prose that happens to start with a hash.
mk "base/hashprose.md" "# see $TMP_LIT/adb-selfcheck.log for the old spelling"
if [ -z "${ scan_fixed_tmp "$st"; }" ]; then
  bad "self-test: a hash-prefixed MARKDOWN line was treated as a shell comment"
else
  ok
fi
rm -f "$st/base/hashprose.md"

# A bare marker with NO reason must NOT exempt: a silent escape hatch is the failure this contract
# is shaped to avoid, and it is the half a marker-presence test would miss.
mk "scripts/bare.sh" "echo \"$TMP_LIT/deliberate.log\"   # $MARK"
if [ -z "${ scan_fixed_tmp "$st"; }" ]; then
  bad "self-test: a REASONLESS '$MARK' exempted a fixed path — the escape hatch is silent"
else
  ok
fi
rm -f "$st/scripts/bare.sh"

# =============================================================================================
# 3. THE GUARD SEEN GOING RED — mutate a COPY, never the working tree
# =============================================================================================
#
# base/practices/self-review.md: a new guard is not done until it has been observed failing, on the
# REAL superseded input. Each case restores one pre-fix spelling and requires the named part to
# report it. The copy rule is not optional here — the inputs are tracked files this repo edits.
MUTATIONS=0
mutate_must_fail() {   # <label> <mutator-fn> <part-fn> <expected-substring>
  local label="$1" mutator="$2" part="$3" want="$4" copy out
  MUTATIONS=$((MUTATIONS + 1))
  copy="$work/copy-$MUTATIONS"
  rm -rf "$copy"
  check_copy_worktree "$ROOT" "$copy" || { bad "$label: could not copy the tree"; return; }
  "$mutator" "$copy" || { bad "$label: mutation failed to apply"; rm -rf "$copy"; return; }
  out="${ "$part" "$copy"; }"
  if [ -z "$out" ]; then
    bad "$label: the scanner stayed SILENT on a broken tree — it cannot see this class"
  else
    has "$out" "$want" "$label: reported"
  fi
  rm -rf "$copy"
}

# rewrite <file> <awk-program> — apply an awk transform in place, via a temp file and `mv`. Not
# `sed -i`: its in-place flag takes an argument on BSD and none on GNU, and this repo runs on both.
rewrite() {
  local f="$1" prog="$2"
  awk "$prog" "$f" > "$f.adbtmp" && mv "$f.adbtmp" "$f"
}

WF=base/workflows/implement-issue.md
SK=agents/claude/skills/implement-issue/SKILL.md

# THE REAL SUPERSEDED SPELLING, both halves of it. `{{STATE_DIR}}` in the source and the resolved
# `.<agent>/state` in every render — a fix applied to only one of the two is the realistic
# half-migration, so each is its own case.
m_old_source()   { rewrite "$1/$WF" '{ gsub(/\{\{STATE_DIR\}\}\/issue-/, "'"$TMP_LIT"'/issue-"); print }'; }
m_old_render()   { [ -f "$1/$SK" ] || return 1
                   rewrite "$1/$SK" '{ gsub(/\.claude\/state\/issue-/, "'"$TMP_LIT"'/issue-"); print }'; }
# The vacuity case: the scanner must fail LOUD when it finds nothing, not report a clean run.
m_no_sites()     { rewrite "$1/$WF" '{ gsub(/issue-\$n\./, "issue-SNAPSHOT."); print }'; }
# Part 2's class, at each of the four roots it covers.
m_tmp_in_script(){ printf '\ncat x > %s/adb-regression.log\n' "$TMP_LIT" >> "$1/scripts/check-lib.sh"; }
m_tmp_in_base()  { printf '\nWrite the draft to `%s/issue-body.md` first.\n' "$TMP_LIT" >> "$1/$WF"; }
m_tmp_in_docs()  { printf '\n    gh issue view 1 > %s/r1.md\n' "$TMP_LIT" >> "$1/docs/roadmap-acceptance.md"; }
m_tmp_in_agents(){ printf '\nWrite the draft to `%s/rendered-body.md` first.\n' "$TMP_LIT" >> "$1/$SK"; }

# part1 reports through variables as well as stdout, so the harness needs both. A site count that
# collapsed is a violation the diagnostic must name, or `m_no_sites` would be judged only by the
# per-file message and the floor would go untested.
part1_out() {
  local h
  P1_SITES=0; P1_FILES=0
  h="${ part1 "$1"; }"
  printf '%s' "$h"
  [ "$P1_SITES" -ge "$P1_FLOOR" ] || printf '\nsnapshot site count collapsed to %s\n' "$P1_SITES"
}

mutate_must_fail "source reverted to the fixed temp path"   m_old_source     part1_out       "host-global path"
mutate_must_fail "one RENDER reverted to the fixed path"    m_old_render     part1_out       "host-global path"
mutate_must_fail "the snapshot filename renamed away"       m_no_sites       part1_out       "NO issue-snapshot path found"
mutate_must_fail "a fixed temp write added under scripts/"  m_tmp_in_script  scan_fixed_tmp  "$TMP_LIT/adb-regression.log"
mutate_must_fail "a fixed temp path added under base/"      m_tmp_in_base    scan_fixed_tmp  "$TMP_LIT/issue-body.md"
mutate_must_fail "a fixed temp path added under docs/"      m_tmp_in_docs    scan_fixed_tmp  "$TMP_LIT/r1.md"
mutate_must_fail "a fixed temp path added under agents/"    m_tmp_in_agents  scan_fixed_tmp  "$TMP_LIT/rendered-body.md"

printf 'check-tmp-paths: %s mutations required to go red\n' "$MUTATIONS"

check_summary "check-tmp-paths"
