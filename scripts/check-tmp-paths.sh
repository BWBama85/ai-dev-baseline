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
# FOUR PARTS:
#   1. every issue-snapshot path in the real markdown — source AND every rendered skill — sits
#      under that file's own state directory (`{{STATE_DIR}}/` in the source, `.<agent>/state/` in
#      a render), and BOTH halves of the snapshot are present in each;
#   1b. the same property DEMONSTRATED: two simulated checkouts write their own sentinel through
#      the path the skill actually specifies, and each must read its own back. This is #250's
#      acceptance criterion in its own words;
#   2. no fixed shared-temp path in `base/`, `scripts/`, `docs/` or `agents/` — such a literal
#      must carry per-run entropy (`$$`, `$RANDOM`, or `XXXXXX` **on a line that calls mktemp**)
#      or an explicit `adb-tmp-ok: <reason>` marker;
#   3. a mutation harness that injects the PRE-FIX spellings into a COPY of the tree and requires
#      each part to go red — because a scanner that matches nothing reports exactly what a clean
#      run reports (base/practices/self-review.md).
#
# WHAT PART 2 DOES *NOT* CATCH, stated so the changelog cannot quietly outgrow it:
#
#   * a shared-temp path reached through a VARIABLE (`D="$TMPDIR"; … > "$D/fixed.log"`) or built by
#     concatenation. This is a lexical scanner, not a shell evaluator;
#   * `$$` or `$RANDOM` inside SINGLE quotes, where the shell never expands them. Detecting that
#     needs a quoting model, and a wrong one produces false positives on legitimate lines — the
#     failure mode this repo treats as worse than a miss;
#   * a `#` that begins a string rather than a comment, in any non-Markdown file (see the stripping
#     note on `scan_fixed_tmp`). Miss-only, never a false positive.
#
# IT DELIBERATELY FLAGS READS AS WELL AS WRITES, and that breadth is the design rather than an
# accident: telling a read from a write needs the shell evaluator the bullets above rule out, and
# a rule that guessed would miss the writes that matter. `adb-tmp-ok: <reason>` is the intended
# answer for a legitimate fixed path — an external socket, a documented system file, a fixture —
# not a grudging exception. It costs one line and leaves a searchable record of every one.
#
# DELIBERATELY OUT OF SCOPE, per #250's own survey: `.github/workflows/ci.yml`, whose one fixed
# path runs on an ephemeral single-tenant runner with no concurrency to collide with. It sits
# outside the four scanned roots, so it is not reached.
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
# self-exempting besides — the same trap `check-claims.sh --self-test` records for `adb-claim-ok`).
# Composing them at runtime keeps the source clean, keeps the scanner honest about its own file,
# and still hands the fixtures the real bytes.
TMP_LIT='/tmp'
MARK='adb-tmp-ok'

# The exemption contract, spelled exactly as `adb-claim-ok:` already is elsewhere: the marker alone
# is NOT enough, it must be followed by a non-space reason. A bare marker is a silent exemption,
# which is the thing this file exists to prevent one level down.
EXEMPT_RE="$MARK"':[[:space:]]*[^[:space:]]'

# Per-run entropy: what makes a shared-temp name safe to write.
#   $$          — the shell's pid, distinct per process (the spelling #250's acceptance names)
#   $RANDOM     — bash's per-shell PRNG, as a WHOLE parameter (`$RANDOM` or `${RANDOM}`)
#   XXXXXX      — an mktemp template, and only where `mktemp` actually consumes it
# The `"${TMPDIR:-/tmp}/name.XXXXXX"` idiom this repo already uses everywhere is doubly safe: the
# closing brace means the hunted text never even appears, so the scanner has nothing to match.
#
# EACH RULE IS A PARSE, NOT A SUBSTRING TEST, and both spellings that made it one were found by
# review after shipping green:
#
#   * `/tmp/run.$RANDOM_SUFFIX` contains the characters `$RANDOM`, but the shell reads
#     `$RANDOM_SUFFIX` — a DIFFERENT parameter, very likely unset and expanding to nothing, leaving
#     the fixed name `/tmp/run.`. So `$RANDOM` counts only when the next character cannot continue
#     an identifier, and `${RANDOM}` is accepted as its own spelling (a plain substring test misses
#     that one entirely, since the braces break the sequence).
#   * `/tmp/run.XXXXXX  # TODO: use mktemp` passed because `mktemp` appeared ANYWHERE on the line —
#     and worse, on the UNSTRIPPED line, so a comment merely mentioning it was enough. The Xs are a
#     template only when a real `mktemp` consumes them, so `mktemp` must appear on the comment-
#     stripped line and BEFORE the token, which is where a command sits relative to its argument.
#
# `$$` stays a plain substring: `$$anything` is still the pid followed by literal text, so there is
# no boundary to check and no ambiguity to resolve.
ENTROPY_TEMPLATE='XXXXXX'

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
  awk -v shmode="$(case "$1" in *.sh) echo 1 ;; *) echo 0 ;; esac)" '
    BEGIN { if (shmode) inb = 1 }
    /^```bash$/ { if (!shmode) inb = 1; next }
    /^```/      { if (!shmode) inb = 0; next }
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

# state_prefix <tree> <file> — the ONE directory this file's snapshot tokens are allowed to sit in.
# The source spells it `{{STATE_DIR}}/`; a rendered skill under `agents/<a>/` spells it
# `.<a>/state/`, which is what `scripts/build.sh` resolves that placeholder to.
#
# AN ALLOWLIST, not "is the token relative". The first cut asked only whether a token began with
# `/`, and the independent review found the hole immediately: `${TMPDIR:-/tmp}/issue-$n.json` is
# textually relative, so it passed — while every shell opens the same host-global file. So does
# `../shared/issue-$n.json`. Naming the one legal prefix answers both, and answers the question the
# requirement actually asks: is this file inside the per-checkout, per-agent state directory
# `implement-lib.sh admit` governs?
state_prefix() {
  local rel="${2#"$1"/}" agent
  case "$rel" in
    agents/*/skills/*)  agent="${rel#agents/}"; agent="${agent%%/*}"; printf '.%s/state/' "$agent" ;;
    scripts/lib/*)      printf '$dir/' ;;   # the caller-passed state dir (#433)
    *)                  printf '{{STATE_DIR}}/' ;;
  esac
}

# part1 <tree> — print one diagnostic line per violation; silence means clean. Also sets P1_SITES
# and P1_FILES in the caller's shell, which is why every call site uses bash 5.3's `${ …; }`
# function substitution rather than `$( … )`: the latter forks, and the counts would be lost.
P1_SITES=0
P1_FILES=0
part1() {
  local tree="$1" f tok pfx n njson nassoc total=0 files=0
  # Since #433 the snapshot writes live in ONE home — implement-lib.sh's snapshot-issues — and
  # the workflow and its renders carry the invocation, not the paths. Scanning the library is
  # scanning what executes.
  local -a files_to_scan=( "$tree/scripts/lib/implement-lib.sh" )

  for f in "${files_to_scan[@]}"; do
    [ -f "$f" ] || { printf 'missing file: %s\n' "${f#"$tree"/}"; continue; }
    files=$((files + 1))
    pfx="${ state_prefix "$tree" "$f"; }"
    n=0; njson=0; nassoc=0
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      n=$((n + 1)); total=$((total + 1))
      case "$tok" in *.json) njson=$((njson + 1)) ;; *.assoc) nassoc=$((nassoc + 1)) ;; esac
      # A DIRECT CHILD, not merely a descendant. `case "$tok" in "$pfx"*` was the first cut and the
      # independent review found both ways through it: `.claude/state/issues/issue-$n.json` and
      # `.claude/state/../shared/issue-$n.json` both begin with the prefix, both give each checkout
      # a distinct file — so 1b's demonstration passes them too — and both defeat the lifecycle
      # anyway, because `state-scan` enumerates ONLY regular files directly under the state dir.
      # A snapshot one level down escapes `/cleanup` and `admit` alike, which is exactly the flat
      # invariant the workflow states in prose and nothing was enforcing.
      if [ "${tok%/*}/" != "$pfx" ]; then
        printf '%s: snapshot path [%s] is not a DIRECT child of this render'"'"'s state dir [%s] — state-scan would never see it\n' \
          "${f#"$tree"/}" "$tok" "$pfx"
      fi
    done <<EOF
${ snapshot_tokens "$f"; }
EOF
    # BOTH HALVES, PER FILE — not a global site count. A total-only floor is satisfiable after an
    # entire half of the snapshot disappears: rename every `.assoc` away and the `.json` tokens
    # alone still clear it, so the provenance file — the trust label this whole change exists to
    # protect — goes unchecked while the run reports PASS. The independent review found that; the
    # per-file, per-suffix requirement is what replaced the floor.
    [ "$n" -gt 0 ]      || printf '%s: NO issue-snapshot path found — the scanner matched nothing, so it proved nothing\n' "${f#"$tree"/}"
    [ "$njson" -gt 0 ]  || printf '%s: no issue-snapshot .json path found\n'  "${f#"$tree"/}"
    [ "$nassoc" -gt 0 ] || printf '%s: no issue-snapshot .assoc path (the provenance label) found\n' "${f#"$tree"/}"
  done
  [ "$files" -gt 0 ] || printf 'no implement-issue workflow or skill found at all\n'
  P1_SITES="$total"; P1_FILES="$files"
}

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
printf 'check-tmp-paths: %s issue-snapshot path site(s) across %s file(s) sit under their state dir\n' \
  "$P1_SITES" "$P1_FILES"

# =============================================================================================
# 1b. TWO CHECKOUTS, EXECUTED — the acceptance criterion's own words
# =============================================================================================
#
# Part 1 is a property of the TEXT. This is the property of the BEHAVIOUR, and #250 asks for it by
# name: "two concurrent runs on the same issue number do not observe each other's files".
#
# It takes the path expression out of the rendered skill, resolves `$n` to one issue number, and
# has two simulated checkouts each write their own sentinel through it — then requires each to read
# back its own. Under the shipped spelling the two land in `A/.claude/state/` and `B/.claude/state/`
# and both sentinels survive; under any host-global spelling they are one file and the second write
# destroys the first, which is exactly the collision the issue reported.
#
# THE TOPOLOGY IS NAMED, because "two concurrent runs" has three readings and only one of them is a
# path question. This exercises TWO CHECKOUTS (equivalently, two agents in one checkout, which get
# different state dirs). Two runs of ONE agent in ONE checkout are refused by `implement-lib.sh
# admit` (#202) and are covered by `scripts/check-implement-lib.sh`; nothing about a filename can
# help there, because they share one HEAD.
#
# NO `gh`, NO CONCURRENCY PRIMITIVE. The race needs neither: interleaving only decides WHICH run
# loses, and sequential writes prove the same aliasing with a deterministic result. A test that
# needed real concurrency to fail would be a flaky test of a property that is not timing-dependent.
two_checkout_demo() {   # <tree> [issue-number] — print a diagnostic per violation; silence = clean
  local tree="$1" num="${2:-250}" f tok resolved rel demo root got
  demo="${ mktemp -d; }" || { printf 'could not create the two-checkout fixture\n'; return; }
  local -a demo_files=( "$tree/scripts/lib/implement-lib.sh" )
  for f in "${demo_files[@]}"; do
    [ -f "$f" ] || continue
    rel="${f#"$tree"/}"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      # `$n` is the loop variable over the issue set; `$dir` is the caller-passed state dir,
      # which the rendered skill passes as `.<agent>/state` — substitute both concretely.
      resolved="${tok//\$n/$num}"
      resolved="${resolved//\$dir/.claude/state}"
      for root in A B; do
        mkdir -p "$demo/$root"
        # A shell running in that checkout, opening exactly what the skill tells it to. An absolute
        # token ignores the `cd` — which is the whole defect, made observable.
        ( cd "$demo/$root" && mkdir -p "$(dirname "$resolved")" 2>/dev/null && printf '%s' "$root" > "$resolved" ) \
          || { printf '%s: could not write [%s] from checkout %s\n' "$rel" "$resolved" "$root"; continue 2; }
      done
      # A wrote first, B second. If they alias, A now reads B's sentinel.
      got="${ cd "$demo/A" && cat "$resolved" 2>/dev/null; }"
      [ "$got" = "A" ] || printf '%s: checkout A read [%s] back as [%s] — the two runs share [%s]\n' \
        "$rel" "$got" "${got:-<gone>}" "$resolved"
    done <<EOF
${ snapshot_tokens "$f"; }
EOF
  done
  rm -rf "$demo"
}

hits="${ two_checkout_demo "$ROOT"; }"
if [ -n "$hits" ]; then
  bad_quiet
  check_note "two checkouts observed each other's issue snapshot:"
  printf '%s\n' "$hits" | sed 's/^/    /' >&2
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
# COMMENTS ARE STRIPPED IN EVERYTHING BUT MARKDOWN, and the trade is stated rather than hidden: a
# `#` inside a string is stripped too, so this can only cause a MISSED report, never a false one —
# the same bargain `check-workflow-shell.sh` documents. Markdown is NOT stripped, because prose is
# exactly where `create-issue.md`'s fixed issue-body path lived and a leading `#` there is a
# heading; a markdown line that must name a fixed path carries the marker instead.
scan_fixed_tmp() {   # <tree> — print "<file>:<line>: <raw>" per violation
  local tree="$1" r f
  local -a dirs=()
  for r in "${SCAN_ROOTS[@]}"; do [ -d "$tree/$r" ] && dirs+=( "$tree/$r" ); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # EVERY regular text file, not just `*.md` and `*.sh`. The extension allowlist was the review's
  # finding and it was right: `scripts/helper` with a shebang, `tool.bash`, and a shell command
  # embedded in a `.yml` are all places this class lives, and every one of them was invisible while
  # the changelog claimed the roots were covered. `grep -Iq` is the binary filter, so a future
  # image or archive under these roots is skipped rather than scanned as mojibake.
  #
  # `-print0` and a NUL reader: `find`'s newline-delimited output splits a filename containing a
  # newline into two nonexistent paths, and a violation inside such a file would be missed silently
  # — the same class of quiet miss this whole file exists to prevent, one level up.
  while IFS= read -r -d '' f; do
    LC_ALL=C grep -Iq . "$f" 2>/dev/null || continue
        awk -v exempt="$EXEMPT_RE" -v tmpl="$ENTROPY_TEMPLATE" \
            -v rel="${f#"$tree"/}" -v pfx="$TMP_LIT/" '
          # `$$` — a plain substring; `$$anything` is still the pid plus literal text.
          function has_pid(tok) { return index(tok, "$$") > 0 }
          # `$RANDOM` as a WHOLE parameter. `${RANDOM}` is its own spelling and is accepted;
          # `$RANDOM_SUFFIX` is a different parameter and is NOT.
          function has_random(tok,   i, nxt) {
            if (index(tok, "${RANDOM}") > 0) return 1
            i = index(tok, "$RANDOM")
            while (i > 0) {
              nxt = substr(tok, i + 7, 1)
              if (nxt == "" || nxt !~ /[A-Za-z0-9_]/) return 1
              tok = substr(tok, i + 7)
              i = index(tok, "$RANDOM")
            }
            return 0
          }
          # `XXXXXX` is a TEMPLATE only where a real mktemp consumes it: on the comment-stripped
          # line, and positioned BEFORE the token, which is where a command sits relative to its
          # argument. `before` is the stripped text preceding this token.
          function has_template(tok, before) {
            return index(tok, tmpl) > 0 && index(before, "mktemp") > 0
          }
          function has_entropy(tok, before) {
            return has_pid(tok) || has_random(tok) || has_template(tok, before)
          }
          {
            raw = $0
            # The exemption is read from the RAW line, before any stripping — otherwise a marker
            # written as a trailing shell comment would be removed before it could be seen.
            if (raw ~ exempt) next
            line = raw
            # Comment stripping for everything EXCEPT Markdown. Markdown prose is where
            # create-issue.md-s fixed issue-body path lived, and a leading `#` there is a heading,
            # not a comment. Everywhere else `#` starts one — in shell, in YAML, in a Makefile —
            # and the trade is the one check-workflow-shell.sh documents: a `#` inside a string is
            # stripped too, which can only cause a MISS, never a false positive.
            if (rel !~ /\.md$/) sub(/(^|[[:space:]])#.*$/, "", line)
            # A CONCRETE name under the shared temp dir: the prefix plus at least one character
            # from a filename charset. The charset deliberately EXCLUDES `<`, so a documentation
            # placeholder such as the literal prefix followed by an angle-bracketed name is not
            # mistaken for a real path.
            # `seen` accumulates the stripped text consumed so far, so `has_template` can ask
            # whether a `mktemp` appears BEFORE this token rather than anywhere on the line.
            seen = ""
            while (1) {
              i = index(line, pfx)
              if (i == 0) break
              seen = seen substr(line, 1, i - 1)
              rest = substr(line, i + length(pfx))
              if (match(rest, /^[A-Za-z0-9._$*{}@%+,=:-]+/)) {
                tok = pfx substr(rest, 1, RLENGTH)
                if (!has_entropy(tok, seen)) { printf "%s:%d: %s\n", rel, FNR, raw; break }
                seen = seen pfx substr(rest, 1, RLENGTH)
                line = substr(rest, RLENGTH + 1)
              } else {
                seen = seen pfx
                line = rest
              }
            }
          }
        ' "$f"
  done < <(find "${dirs[@]}" -type f -print0 2>/dev/null | _tmp_nul_sort)
}

# Order the NUL-delimited stream, or pass it through unchanged where that is not possible.
#
# `sort -z` IS NOT POSIX. Review flagged it as GNU-only and unavailable to the `selfcheck-macos`
# job, which deliberately keeps coreutils' `gnubin` off PATH. Measured rather than assumed: Apple's
# `/usr/bin/sort` (2.3-Apple, macOS 26.5.1) round-trips `b\0a\0c\0` to `a\0b\0c\0` correctly,
# so the stated failure does not occur on that build — but the runner's image is a different one,
# and a required job going red on an option flag is not a thing to find out from CI.
#
# So PROBE, and probe the OUTPUT rather than the exit status: an implementation that accepted `-z`
# and did something else would pass a status check and silently reorder nothing. Ordering is a
# REPORT property only — the pass/fail verdict does not depend on it — so falling through to
# `find`'s own order costs reproducible diagnostics and never a missed violation.
_tmp_nul_sort() {
  if [ "${_TMP_SORT_Z:-}" = "" ]; then
    if [ "${ printf 'b\0a\0' | LC_ALL=C sort -z 2>/dev/null | tr '\0' ','; }" = "a,b," ]
    then _TMP_SORT_Z=1; else _TMP_SORT_Z=0; fi
  fi
  if [ "$_TMP_SORT_Z" = 1 ]; then LC_ALL=C sort -z; else cat; fi
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
               "printf x > \"$TMP_LIT/adb.\$USER.log\"" \
               "printf x > $TMP_LIT/adb-literal.XXXXXX"; do
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
                "f=\"\$(mktemp $TMP_LIT/adb.XXXXXX)\"" \
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
  # SUBTREES, not the whole worktree. Every mutator writes into one of the four scanned roots and
  # every part reads only those, so the roots ARE the fixture — and `check_copy_worktree` would
  # copy this repo's ~66 MB `.git` thirteen times to delete it thirteen times, which measured 63s
  # against 6s. The shared helper is used rather than an open-coded `cp`, for the reason its own
  # header gives: a hand-rolled copier is where the faithful-copy details drift.
  check_copy_subtrees "$ROOT" "$copy" "${SCAN_ROOTS[@]}" \
    || { bad "$label: could not copy the scanned roots"; return; }
  "$mutator" "$copy" || { bad "$label: mutation failed to apply"; rm -rf "$copy"; return; }
  out="${ "$part" "$copy"; }"
  if [ -z "$out" ]; then
    bad "$label: the scanner stayed SILENT on a broken tree — it cannot see this class"
  else
    has "$out" "$want" "$label: reported"
  fi
  rm -rf "$copy"
}

# rewrite <file> <awk-program> [awk-args…] — apply an awk transform in place, via a temp file and
# `mv`. Not `sed -i`: its in-place flag takes an argument on BSD and none on GNU, and this repo
# runs on both. Trailing arguments are passed to awk ahead of the program, so a mutator can hand a
# value in with `-v` rather than splicing it into the program text.
rewrite() {
  local f="$1" prog="$2"
  shift 2
  awk "$@" "$prog" "$f" > "$f.adbtmp" && mv "$f.adbtmp" "$f"
}

WF=base/workflows/implement-issue.md
SK=agents/claude/skills/implement-issue/SKILL.md

# --- the FIXTURE itself, proved once ----------------------------------------------------------
# `check_copy_subtrees` is new shared code, and a copier's failure mode is a fixture missing the
# file each mutation targets. That does not arrive as "the copy is broken" — it arrives as thirteen
# reports that "the scanner stayed SILENT on a broken tree", blaming the scanner for a tree that was
# never broken because the mutator had nothing to edit. Proving the fixture once, up front, is what
# keeps that misattribution from being the only signal.
probe="$work/copyprobe"
if check_copy_subtrees "$ROOT" "$probe" "${SCAN_ROOTS[@]}"; then
  ok
  for f in "$WF" "$SK" scripts/lib/implement-lib.sh scripts/check-lib.sh docs/roadmap-acceptance.md; do
    if [ -f "$probe/$f" ]; then ok; else bad "copier: $f is missing from the subtree fixture"; fi
  done
  # The contract says the copy is NOT a git repo. A `.git` that survived would make every mutated
  # tree a second working copy of this repo, which is a different and much worse fixture.
  if [ -e "$probe/.git" ]; then bad "copier: the fixture carries a .git, which the contract forbids"; else ok; fi
else
  bad "copier: could not build a subtree fixture at all"
fi
rm -rf "$probe"

# THE REAL SUPERSEDED SPELLING, both halves of it. `{{STATE_DIR}}` in the source and the resolved
# `.<agent>/state` in every render — a fix applied to only one of the two is the realistic
# half-migration, so each is its own case.
IL=scripts/lib/implement-lib.sh
m_old_source()   { rewrite "$1/$IL" '{ gsub(/\$dir\/issue-/, "'"$TMP_LIT"'/issue-"); print }'; }
# The per-suffix half-migration: only the provenance write reverts.
m_old_render()   { rewrite "$1/$IL" '{ gsub(/\$dir\/issue-\$n\.assoc/, "'"$TMP_LIT"'/issue-$n.assoc"); print }'; }
# The vacuity case: the scanner must fail LOUD when it finds nothing, not report a clean run.
m_no_sites()     { rewrite "$1/$IL" '{ gsub(/issue-\$n\./, "issue-SNAPSHOT."); print }'; }
# Part 2's class, at each of the four roots it covers.
m_tmp_in_script(){ printf '\ncat x > %s/adb-regression.log\n' "$TMP_LIT" >> "$1/scripts/check-lib.sh"; }
m_tmp_in_base()  { printf '\nWrite the draft to `%s/issue-body.md` first.\n' "$TMP_LIT" >> "$1/$WF"; }
m_tmp_in_docs()  { printf '\n    gh issue view 1 > %s/r1.md\n' "$TMP_LIT" >> "$1/docs/roadmap-acceptance.md"; }
m_tmp_in_agents(){ printf '\nWrite the draft to `%s/rendered-body.md` first.\n' "$TMP_LIT" >> "$1/$SK"; }

# One half of the snapshot renamed away, leaving the other intact. This is the case a global site
# COUNT could not see — four `.json` tokens alone cleared the old floor — so the per-file,
# per-suffix requirement is what has to catch it, and this is the mutation that proves it does.
m_drop_assoc()   { rewrite "$1/$IL" '{ gsub(/issue-\$n\.assoc/, "issue-association-$n.txt"); print }'; }
# The `${TMPDIR:-/tmp}` hole part 1 used to have: textually relative, host-global in every shell.
m_tmpdir_token() { rewrite "$1/$IL" '{ gsub(/\$dir\/issue-\$n/, "${TMPDIR:-/tmp}/issue-$n"); print }'; }
# A relative token that escapes the checkout. `../shared/…` is not absolute, so an is-it-relative
# test passes it while two sibling checkouts open the same file.
m_parent_escape(){ rewrite "$1/$IL" '{ gsub(/\$dir\/issue-\$n/, "../shared/issue-$n"); print }'; }
# The documented `issues/` shape — a SUBDIRECTORY of the state dir. This is the one the workflow's
# own prose forbids and the one 1b cannot catch: each checkout still gets its own file, so the
# behavioural demonstration passes, while `state-scan` (which enumerates direct children only)
# never sees it and neither `/cleanup` nor `admit` can ever clear it.
m_nested_dir()   { rewrite "$1/$IL" '{ gsub(/\$dir\/issue-\$n/, "$dir/issues/issue-$n"); print }'; }
# `XXXXXX` with no `mktemp` on the line — Xs that are a literal filename, not a template.
m_bare_template(){ printf '\nprintf x > %s/adb-literal.XXXXXX\n' "$TMP_LIT" >> "$1/scripts/check-lib.sh"; }
# A fixed path in a file with NO recognised extension, which the old `*.md`/`*.sh` filter skipped.
m_extensionless() { printf '#!/usr/bin/env bash\ncat x > %s/adb-helper.log\n' "$TMP_LIT" > "$1/scripts/adb-helper"; }
# `$RANDOM` as a PREFIX of a different parameter. The shell expands `$RANDOM_SUFFIX`, which is
# almost certainly unset, leaving the fixed name `adb-pseudo.` — a substring test called it entropy.
m_pseudo_random() { printf '\nprintf x > %s/adb-pseudo.$RANDOM_SUFFIX\n' "$TMP_LIT" >> "$1/scripts/check-lib.sh"; }
# `mktemp` named only in a COMMENT beside a literal template. The Xs stay literal.
m_mktemp_comment(){ printf '\nprintf x > %s/adb-todo.XXXXXX   # TODO: use mktemp here\n' "$TMP_LIT" >> "$1/scripts/check-lib.sh"; }

# part1 writes its counts into variables and its violations to stdout; the harness reads stdout.
part1_out()     { P1_SITES=0; P1_FILES=0; part1 "$1"; }
# 1b's demonstration, driven over the mutated tree. Its own fixture roots live under mktemp, so a
# mutated ABSOLUTE token must point somewhere harmless — see `m_shared_abs`.
two_checkout_out() { two_checkout_demo "$1"; }

# THE BEHAVIOURAL MUTATION. It does NOT reintroduce the literal shared-temp path, because this case
# actually WRITES through the resolved token, and a test that scribbled on the host's real temp
# directory could collide with a live run of this very workflow.
#
# THE ALIASED PATH LIVES INSIDE `$work`, and the first cut's `/adb-tmp-shared-fixture/` was a real
# defect the independent review caught. That spelling leaned on `mkdir -p` failing for lack of
# permission — which is not a property of the test, it is a property of WHO IS RUNNING IT. As root
# (routine in a dev container, and this suite is a mandatory gate) the creation succeeds, the demo
# writes outside `$work`, and the `rm -rf "$demo"` at the end of `two_checkout_demo` does not reach
# it; if that path already existed the test would write into it. An absolute path under `$work` has
# the property actually under test — both checkouts resolve it identically, so the aliasing is real
# — and is removed by this suite's own EXIT trap whatever happens.
m_shared_abs()   { rewrite "$1/$IL" '{ gsub(/\$dir\/issue-\$n/, W "/shared-fixture/issue-$n"); print }' \
                     -v W="$work"; }

mutate_must_fail "source reverted to the fixed temp path"   m_old_source     part1_out       "is not a DIRECT child"
mutate_must_fail "the .assoc write alone reverted"          m_old_render     part1_out       "is not a DIRECT child"
mutate_must_fail "a \${TMPDIR:-/tmp} token, textually relative" m_tmpdir_token part1_out      "is not a DIRECT child"
mutate_must_fail "a ../ token that escapes the checkout"    m_parent_escape  part1_out       "is not a DIRECT child"
mutate_must_fail "the forbidden issues/ SUBDIRECTORY shape"  m_nested_dir   part1_out       "is not a DIRECT child"
mutate_must_fail "the snapshot filename renamed away"       m_no_sites       part1_out       "NO issue-snapshot path found"
mutate_must_fail "ONE HALF renamed away (.assoc)"           m_drop_assoc     part1_out       "provenance label"
mutate_must_fail "an unrooted path both checkouts resolve"  m_shared_abs     two_checkout_out "checkout A"
mutate_must_fail "a fixed temp write added under scripts/"  m_tmp_in_script  scan_fixed_tmp  "$TMP_LIT/adb-regression.log"
mutate_must_fail "a fixed temp path added under base/"      m_tmp_in_base    scan_fixed_tmp  "$TMP_LIT/issue-body.md"
mutate_must_fail "a fixed temp path added under docs/"      m_tmp_in_docs    scan_fixed_tmp  "$TMP_LIT/r1.md"
mutate_must_fail "a fixed temp path added under agents/"    m_tmp_in_agents  scan_fixed_tmp  "$TMP_LIT/rendered-body.md"
mutate_must_fail "XXXXXX with no mktemp on the line"        m_bare_template  scan_fixed_tmp  "$TMP_LIT/adb-literal.XXXXXX"
mutate_must_fail "\$RANDOM as a prefix of another parameter" m_pseudo_random scan_fixed_tmp  "$TMP_LIT/adb-pseudo."
mutate_must_fail "mktemp named only in a trailing COMMENT"  m_mktemp_comment scan_fixed_tmp  "$TMP_LIT/adb-todo.XXXXXX"
mutate_must_fail "a fixed path in an EXTENSIONLESS script"  m_extensionless  scan_fixed_tmp  "$TMP_LIT/adb-helper.log"

printf 'check-tmp-paths: %s mutations required to go red\n' "$MUTATIONS"

check_summary "check-tmp-paths"
