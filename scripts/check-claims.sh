#!/usr/bin/env bash
# ai-dev-baseline — claim lint (issue #212).
#
# A VERIFIABLE ASSERTION written into a tracked file, with no gate between writing it and
# committing it. That is one class, and the #173 run (PR #210) shipped four of them, three wrong:
# a `#206` citation that tracked something else, a `#207` citation for an issue that DID NOT EXIST
# (rendered into all three agents' skills), "(recorded as D17)" for a decision that is D18, and a
# CHANGELOG sentence describing an edit that had not been made. Two pre-existing citations pointed
# at issue #150, closed NOT_PLANNED — abandoned work reading as delivered.  adb-claim-ok: that
# citation is deliberately historical, and the marker must sit on the SAME line as the reference
# because the exemption is per-line. This is the escape's first real use, on the very example the
# lint exists for.
#
# base/practices/verify-before-asserting.md already forbids exactly this for PR/issue STATUS, and
# D16 is the precedent for why it is a gate rather than another paragraph: the prose version failed
# twice with the practice loaded in context. An issue NUMBER is the same kind of claim, and a `gh`
# call plus a `grep` is all "find a supporting quote" means for an identifier — so it can be a lint
# instead of an instruction.
#
# SCOPED TO THE ADDED LINES OF A RANGE, never the whole tree. That is not an optimization, it is
# what makes the check adoptable. Measured on `origin/main` at the time this landed, the tree
# carried 2450 numeric references over 157 distinct numbers, of which 11 cite issues legitimately
# closed NOT_PLANNED and 39 are not issues at all (pull-request numbers, plus deliberate fixtures
# for 0 and 999999999). The figures are a dated baseline, not a live property of the checkout —
# they drift the moment anyone writes a reference, and quoting them as current would be the same
# stale-claim defect this file exists to catch. A whole-tree run would be red forever on history
# nobody is asserting anything about today.
#
# Usage:
#   bash scripts/check-claims.sh [--range <base>..<head>] [--live]
#
#   --range   what to scan. Default: origin/<default>...HEAD (three-dot: from the merge base, i.e.
#             this branch's own added lines). Two-dot is accepted and passed through unchanged.
#   --live    ALSO run the issue/PR-reference check, which needs gh and the network.
#
# Exit codes:
#   0  no claim violations
#   1  at least one claim violation (diagnostics on stderr)
#   2  usage error
#   3  --live was requested and the live half could NOT be run (fail closed — never a pass)
#
# KNOWN LIMIT OF THE REFERENCE GRAMMAR: a six-digit CSS colour is shaped exactly like an issue
# number, so a value such as #123456 in a stylesheet would be looked up.  adb-claim-ok: that is a
# colour literal, not a citation — and the lint flagging this very sentence when it was first
# written is the limit demonstrating itself. This repo tracks no stylesheet, and the grammar is
# left permissive rather than guessing at file types, but it is a real edge for the generalization
# tracked in #233 and is named here rather than discovered there.
#
# WHAT THIS GUARANTEES, STATED NARROWLY. It checks that a reference RESOLVES; it does not and
# cannot check that a reference is APT. That an issue exists is provable; that it is the issue you
# meant is not — that judgement is the review step's, and claiming otherwise here would be the same
# overreach this repo refused when it kept the state-claim grammar small rather than building a
# classifier over arbitrary English.
#
# WHY THERE IS NO PATH-CLAIM CHECK HERE, though #212 asked for one and called it the highest-value
# check. It was built, measured, and removed on the evidence:
#
#   * It cannot catch the defect #212 cites as its justification. That sentence named
#     `base/roles.md`, and `git show --name-only 9e61dfd` lists that file. The path WAS in the
#     diff; what was false was the KIND of change claimed of it. No "is this path in the diff?"
#     predicate sees that, in any formulation.
#   * Measured over the last five merges it scored SEVEN false positives and ZERO true positives —
#     in the verb-free form AND the change-verb form alike. The reason is structural: a changelog
#     is a HISTORICAL document, so any commit that reflows or amends an older entry re-adds prose
#     making true change claims about a different commit. b13a8f8 reflowed CHANGELOG lines 139-171
#     and thereby "claimed" `templates/agents.toml`, `install.sh` and `agents.toml`, none of which
#     it touched. Five of the seven carried a change verb, so a verb grammar does not rescue it.
#   * This repo's own law says a gate that fires on ordinary prose gets worked around, and then it
#     protects nothing at all. That is the trade the state-claim grammar was kept small to avoid.
#
# So the path-claim check lives where the judgement is: a named claim-integrity lens in the review
# prompt of base/workflows/implement-issue.md, which is where #212's own follow-up comment puts
# judgement-heavy claim validation. A controlled opt-in syntax is tracked separately.
#
# Regression-tested by scripts/check-claims-guard.sh, which drives every rule to RED against
# fixtures in a throwaway git repo with a stubbed gh. The working tree is never mutated.

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "check-claims"

# --- shared primitives (source, never copy — docs/design-principles.md) ------------------------
_cc_common="scripts/lib/common.sh"
[ -f "$_cc_common" ] || { echo "check-claims: FATAL — $_cc_common not found" >&2; exit 2; }
# shellcheck source=/dev/null
. "$_cc_common"

RANGE=""
LIVE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      [ "$#" -ge 2 ] || { echo "check-claims: --range needs a value" >&2; exit 2; }
      RANGE="$2"; shift 2 ;;
    --range=*) RANGE="${1#--range=}"; shift ;;
    --live)    LIVE=1; shift ;;
    -h|--help) adb_usage "$0"; exit 0 ;;
    *) echo "check-claims: unknown option '$1'" >&2; exit 2 ;;
  esac
done

# --- resolve the range --------------------------------------------------------------------------
if [ -z "$RANGE" ]; then
  _cc_def="$(adb_default_branch .)"
  if git rev-parse --verify --quiet "origin/$_cc_def" >/dev/null 2>&1; then
    RANGE="origin/$_cc_def...HEAD"
  elif git rev-parse --verify --quiet "$_cc_def" >/dev/null 2>&1; then
    RANGE="$_cc_def...HEAD"
  else
    echo "check-claims: cannot resolve a default-branch base; pass --range explicitly" >&2; exit 2
  fi
fi
case "$RANGE" in
  *...*) BASEREV="${RANGE%%...*}"; HEADREV="${RANGE#*...}" ;;
  *..*)  BASEREV="${RANGE%%..*}";  HEADREV="${RANGE#*..}" ;;
  *) echo "check-claims: --range must be <base>..<head> or <base>...<head>" >&2; exit 2 ;;
esac
[ -n "$HEADREV" ] || HEADREV="HEAD"
[ -n "$BASEREV" ] || BASEREV="HEAD"
# BOTH ends are verified, and that is not symmetry for its own sake. Only the head was checked at
# first, so an unresolvable BASE — a typo, a branch that was never fetched — made every `git diff`
# below fail into a `2>/dev/null`, leaving an empty change set: zero files scanned, zero rules
# evaluated, and a confident PASS. A mistyped --range silently converted the whole gate into a
# no-op that looked exactly like a clean run. Caught by its own guard suite.
for _cc_rev in "$BASEREV" "$HEADREV"; do
  git rev-parse --verify --quiet "$_cc_rev" >/dev/null 2>&1 \
    || { echo "check-claims: unresolvable revision '$_cc_rev' in range '$RANGE'" >&2; exit 2; }
done
# And the diff itself must actually work: a range whose ends both resolve can still be rejected
# (unrelated histories, a missing merge base), which would otherwise degrade to the same silent zero.
git diff --name-only "$RANGE" >/dev/null 2>&1 \
  || { echo "check-claims: git cannot diff range '$RANGE'" >&2; exit 2; }

# THE COMMIT WALK NEEDS ITS OWN RANGE, because `A...B` means two different things to the two
# commands this script uses. To `git diff` it is "from the merge base to B" — the branch's own
# added lines, which is what every line-scanning rule wants. To `git rev-list` it is the SYMMETRIC
# DIFFERENCE: commits reachable from A or B but not both, i.e. the BASE branch's commits as well.
# Verified on a diverged fixture — `rev-list main...feature` returns both "on feature" and "on main
# only", while `main..feature` returns just the one.
#
# Left as-is, the date rule walked commits on the base branch and reported on history this branch
# is not asserting anything about, which is precisely the whole-tree behaviour the added-lines
# scoping exists to avoid.
case "$RANGE" in
  *...*)
    CC_MB="$(git merge-base "$BASEREV" "$HEADREV" 2>/dev/null)" \
      || { echo "check-claims: no merge base for '$RANGE'" >&2; exit 2; }
    [ -n "$CC_MB" ] || { echo "check-claims: no merge base for '$RANGE'" >&2; exit 2; }
    REVRANGE="$CC_MB..$HEADREV" ;;
  *) REVRANGE="$BASEREV..$HEADREV" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/gh"; mkdir -p "$CACHE"
DECISIONS=".ai-dev-baseline/decisions.md"
_CC_NL=$'\n'

# What the run actually evaluated, REPORTED rather than inferred. A guard's failure mode is
# silence: a checker wired to an empty range scans nothing and prints exactly what a clean run
# prints. D22 is this repo paying for that once already, so every axis carries a count and a zero
# is visible in the log.
N_FILES=0; N_ADDED=0; N_SKIP_BIN=0; N_SKIP_PATH=0
N_REF_OCC=0; N_REF_DISTINCT=0; N_REF_LOOKUPS=0
N_DREF=0; N_DATE=0; N_EXEMPT=0

cc_violation() { check_note "$1"; check_fail; }

# --- the range's changed paths, resolved once ---------------------------------------------------
# --no-renames so a moved file surfaces BOTH paths: a claim about the path a file moved OUT of is a
# claim about this diff. -z because a tracked path may carry a space or a non-ASCII byte, which git
# would otherwise quote into a different string than the one the prose names.
CHANGED="$WORK/changed"; : > "$CHANGED"
N_SKIP_PATH=0
while IFS= read -r -d '' p; do
  [ -n "$p" ] || continue
  # A path containing a NEWLINE cannot survive the newline-delimited storage below, and silently
  # dropping it would be a file this lint never scanned while reporting a clean run. Counted and
  # reported instead. (No such path exists here; the point is that a zero is EARNED, not assumed.)
  case "$p" in *"$_CC_NL"*) N_SKIP_PATH=$((N_SKIP_PATH + 1)); continue ;; esac
  printf '%s\n' "$p" >> "$CHANGED"
done < <(git diff --name-only -z --diff-filter=ACMRD "$RANGE" 2>/dev/null)

# The candidate tree's file list and decision log, read once rather than per-reference.
#
# `core.quotePath=false` is load-bearing, not cosmetic. git QUOTES a non-ASCII path by default
# (`"na\303\257ve.md"`), while the diff above yields the raw bytes — so the membership test below
# failed for every such file and it was skipped WITHOUT a word. A fixture named `naïve.md` reported
# `files=0`, which is the silent-guard shape: a file the lint never looked at, reported as clean.
TREEFILES="$WORK/treefiles"
git -c core.quotePath=false ls-tree -r --name-only "$HEADREV" > "$TREEFILES" 2>/dev/null \
  || : > "$TREEFILES"
DECFILE="$WORK/decisions"
git show "$HEADREV:$DECISIONS" > "$DECFILE" 2>/dev/null || : > "$DECFILE"

# --- files to scan (text only, git's own binary verdict is unavailable per-blob, so test it) ----
SCANLIST="$WORK/scan"; : > "$SCANLIST"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Present in the candidate tree? A deleted path has no content to scan.
  grep -qxF "$p" "$TREEFILES" || continue
  # Binary test: a NUL byte in the first 8 KiB. Portable, and it needs no awk RS="\0" support
  # (which BWK awk on macOS does not reliably provide).
  raw="$(git show "$HEADREV:$p" 2>/dev/null | head -c 8192 | wc -c | tr -d ' ')"
  txt="$(git show "$HEADREV:$p" 2>/dev/null | head -c 8192 | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')"
  if [ "$raw" != "$txt" ]; then N_SKIP_BIN=$((N_SKIP_BIN + 1)); continue; fi
  printf '%s\n' "$p" >> "$SCANLIST"
done < "$CHANGED"

# --- every added line in the range, mapped to its file, in ONE diff ------------------------------
# ONE unrestricted diff rather than one per file, and that is a CORRECTNESS requirement rather than
# a speed one. Restricting a diff with a pathspec DESTROYS rename detection: asked only about the
# destination path, git cannot see where the content came from and reports the whole file as newly
# added. A pure `git mv` then re-presented every historical line as this branch's own work, and the
# lint re-litigated references it had no business judging — the exact whole-tree behaviour the
# added-lines scoping exists to prevent. Verified against a fixture: the unrestricted diff prints
# `rename from/to` with no hunks, the pathspec-restricted one prints `new file` and the entire body.
#
# core.quotePath=false so the paths here are the same bytes as the ones in $CHANGED and $TREEFILES.
ADDEDMAP="$WORK/added"
git -c core.quotePath=false diff --unified=0 "$RANGE" 2>/dev/null | awk '
  /^\+\+\+ / {
    line = $0; sub(/^\+\+\+ /, "", line)
    if (line == "/dev/null") { p = ""; next }
    sub(/^b\//, "", line)
    p = line; next
  }
  /^@@/ && p != "" {
    m = $3; sub(/^\+/, "", m)
    n = split(m, P, ",")
    start = P[1] + 0; cnt = (n > 1 ? P[2] + 0 : 1)
    for (i = 0; i < cnt; i++) printf "%s\t%d\n", p, start + i
  }' > "$ADDEDMAP"

# --- day arithmetic, without depending on GNU vs BSD `date` flags -------------------------------
# days_from_civil (Hinnant): a calendar date to a day number, so two dates can be compared by
# subtraction. `date -d` is GNU-only and `date -v` is BSD-only, so neither is portable here.
cc_daynum() {   # <YYYY-MM-DD> -> integer day number
  printf '%s\n' "$1" | awk -F- '{
    y = $1 + 0; m = $2 + 0; d = $3 + 0
    if (m <= 2) { y -= 1; m += 9 } else { m -= 3 }
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * m + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    print era * 146097 + doe - 719468
  }'
}

# --- gh entity resolution (LIVE half) -----------------------------------------------------------
# One lookup per DISTINCT number per run, cached in a temp dir (macOS bash 3.2 has no associative
# arrays). Cached WITHIN the run only: a close reason is mutable external state, so a cache that
# outlived the invocation would be exactly the stale-state trust verify-before-asserting.md exists
# to remove.
#
# Pinned to the checkout's own repo via git's remote, NOT gh's notion of it: GH_REPO silently
# redirects an unqualified read, and the answer is then confidently about a different project.
# adb_git_origin_slug is the one home for that anchor.
CC_SLUG=""
cc_live_init() {
  adb_require_gh jq >/dev/null 2>&1 || return 1
  CC_SLUG="$(adb_git_origin_slug)" || return 1
  [ -n "$CC_SLUG" ] || return 1
}

# cc_entity <n> — populates $CACHE/<n> with "<kind>\t<state>\t<extra>\t<number>", or one of the two
# sentinels `MISSING` / `UNREADABLE`. Writes a file rather than printing so the lookup counter is
# incremented in THIS shell: a command substitution runs in a subshell, where the increment would
# be discarded and the reported count would be a permanent zero.
#
# THE READ ITSELF IS NOT HERE. It is `adb_gh_entity` in common.sh, shared with state-assert.sh —
# this file's first draft carried its own copy and had already drifted from it in three ways a
# reviewer could name: a transport failure was reported as "does not resolve", a malformed payload
# was flattened into a nonexistent entity, and the returned URL's number was never checked against
# the number asked for. That is precisely the copy-instead-of-source failure this repo treats as a
# blocking review finding, so the primitive was generalized rather than the copy patched.
cc_entity() {
  local n="$1" f="$CACHE/$1" rec rc
  [ -f "$f" ] && return 0
  N_REF_LOOKUPS=$((N_REF_LOOKUPS + 1))
  rec="$(adb_gh_entity "$CC_SLUG" "$n" issue stateReason)"; rc=$?
  case "$rc" in
    0)
      # The response must be ABOUT the number that was asked for. Real gh always is, so this only
      # fires on a misbehaving or redirected read — but reporting on #9 from a payload describing
      # #146 is a wrong answer, and a wrong answer is worse than no answer.
      if [ "$(printf '%s' "$rec" | cut -f4)" -ne "$n" ] 2>/dev/null; then
        printf 'UNREADABLE\n' > "$f"
      else
        printf '%s\n' "$rec" > "$f"
      fi ;;
    1) printf 'MISSING\n'    > "$f" ;;
    *) printf 'UNREADABLE\n' > "$f" ;;
  esac
}

# ONLY PROSE DECLARES, and the boundary is per-file-kind rather than universal:
#   * .md — markdown fences and inline code spans are stripped. Quoting a number while documenting
#     a grammar is not a citation, and a lint that could not tell them apart would fire on this
#     repo's own docs about this repo's own checks.
#   * everything else — EVERY added line is scanned, shell comments INCLUDED. That is deliberate:
#     the "(recorded as D17)" defect was itself in a shell comment in scripts/lib/common.sh, so a
#     rule that discarded comments would have been green on one of the four claims it exists for.
#
# This emits the RAW line and lets each rule strip what IT should not see. The reference and
# decision rules must not see inside a code span (quoting a number while documenting a grammar is
# not a citation), while the exemption marker must be read from the raw line because it is
# normally written as a trailing comment.
#
# The separation is kept even though the rule that most needed it — the path check, which looked
# for BACKTICKED paths — no longer ships. A single shared stripper is how that rule was silently
# disabled: it deleted exactly the tokens the rule searched for, reported `path-claims=0` on a
# commit carrying nine of them, and no assertion anywhere went red. Collapsing these two views
# again would re-create that failure for whichever rule needs the raw text next.
#
# Content comes from the range's HEAD revision, never the working tree, so an explicit --range
# scans what it names rather than whatever happens to be checked out.
cc_scan_file() {   # <file> -> "<lineno>\t<raw text>" per scannable added line
  local f="$1" lines="$WORK/ln" is_md=0
  awk -F'\t' -v want="$f" '$1 == want { print $2 }' "$ADDEDMAP" | sort -n -u > "$lines"
  [ -s "$lines" ] || return 0
  case "$f" in *.md) is_md=1 ;; esac
  git show "$HEADREV:$f" 2>/dev/null | awk -v want="$lines" -v md="$is_md" '
    BEGIN { while ((getline l < want) > 0) W[l + 0] = 1 }
    {
      # Fenced blocks are dropped for markdown regardless of rule: nothing inside one declares.
      if (md) {
        # Up to THREE spaces of indent is a fence; four or more is an indented code block and
        # must NOT toggle. A whole-file toggle on an indented ``` hid every following line.
        if ($0 ~ /^ {0,3}(\140\140\140|~~~)/) { fence = !fence; next }
        if (fence) next
      }
      if (!(NR in W)) next
      printf "%d\t%s\n", NR, $0
    }'
}

# cc_prose <raw> — the view the reference rules get: inline code spans and HTML comments removed.
#
# NON-GREEDY, deliberately. `s/<!--.*-->/ /` is greedy, so a line carrying TWO comments had
# everything between them deleted as well — including any real citation sitting in that prose. That
# direction is the dangerous one: it hides a claim rather than inventing one. `[^-]` is not a
# faithful "not `-->`" either, so the comment body is matched as "anything that is not the start of
# the terminator", repeated.
#
# THIS IS AN APPROXIMATION AND IS NAMED AS ONE. A multi-line HTML comment, a multi-backtick span
# whose body contains a lone backtick, and an indented-code-block fence are all modelled loosely.
# The exact CommonMark rule belongs to the shared paragraph-aware prose filter that issue #136
# exists to single-source, of which this is a declared consumer — the same position
# state-assert.sh's grammar takes, rather than growing a second private parser here.
cc_prose() {
  printf '%s\n' "$1" \
    | sed -E -e 's/<!--([^-]|-[^-]|--[^>])*-->/ /g' \
             -e 's/``+/`/g' \
             -e 's/`[^`]*`/ /g'
}

# The audited escape. A line carrying this token is exempt from every rule below — greppable, so
# "what did we wave through?" is one command. It exists because a blanket NOT_PLANNED rejection is
# semantically wrong: this repo legitimately writes prose ABOUT abandoned issues, and a gate with
# no way to say so gets worked around instead of obeyed.
# The contract is `adb-claim-ok: <reason>`, and it is ENFORCED rather than described. A bare
# mention of the token waived every rule on the line, so a typo — or the word appearing in prose
# about the escape — silently disabled the checks it was never meant to touch.
CC_EXEMPT_RE='adb-claim-ok:[[:space:]]*[^[:space:]]'

# ================================ scan ==========================================================
REFS="$WORK/refs"; : > "$REFS"    # "<n>\t<file>:<line>\t<kind-hint>"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  N_FILES=$((N_FILES + 1))
  while IFS="$(printf '\t')" read -r lno raw; do
    [ -n "$lno" ] || continue
    N_ADDED=$((N_ADDED + 1))
    # The exemption is read from the RAW line: the marker is normally written as a trailing
    # comment, which for a markdown file may well sit inside a code span.
    if printf '%s' "$raw" | grep -qE "$CC_EXEMPT_RE"; then
      N_EXEMPT=$((N_EXEMPT + 1)); continue
    fi
    case "$f" in
      *.md) text="$(cc_prose "$raw")" ;;
      *)    text="$raw" ;;
    esac

    # --- C1: collect issue/PR references (resolved later, in one deduplicated live pass) --------
    # `#` must not be preceded by a word character or `/`, which excludes `owner/repo#123` — a
    # DIFFERENT repository's number space, where resolving against this origin would confidently
    # validate the wrong entity. `[1-9][0-9]*` excludes `#0`.
    for n in $(printf '%s\n' "$text" | grep -oE '(^|[^A-Za-z0-9_/#])#[1-9][0-9]*' | grep -oE '[0-9]+$'); do
      N_REF_OCC=$((N_REF_OCC + 1))
      # The kind hint needs a DIGIT BOUNDARY after the number, which a glob cannot express: a glob
      # found the shorter number inside the longer one and handed it the wrong hint. Numbers are
      # safe to interpolate into the pattern — the extraction above guarantees digits only.
      #
      # BOTH spellings are recorded when both appear, rather than the first one winning. One line
      # can carry a correct citation and an incorrect one for the SAME number, and an if/elif gave
      # them a single verdict — so the wrong half was covered by the right half and passed.
      # Emitting one record per spelling lets the resolver flag exactly the spelling that is wrong.
      #
      # BOTH hints are matched CASE-INSENSITIVELY, and the asymmetry that existed here was a real
      # hole rather than a cosmetic one: the issue hint used -i and the pull hint did not, so
      # `Pull request #N` and `pr #N` were recorded as `bare`. A bare reference is only checked for
      # EXISTENCE, so a sentence explicitly naming the wrong entity kind passed the live check.
      got=0
      if printf '%s' "$text" | grep -qiE "(PR|pull request) ?#$n([^0-9]|$)"; then
        printf '%s\t%s:%s\tpull\n' "$n" "$f" "$lno" >> "$REFS"; got=1
      fi
      if printf '%s' "$text" | grep -qiE "issue #$n([^0-9]|$)"; then
        printf '%s\t%s:%s\tissue\n' "$n" "$f" "$lno" >> "$REFS"; got=1
      fi
      [ "$got" -eq 1 ] || printf '%s\t%s:%s\tbare\n' "$n" "$f" "$lno" >> "$REFS"
    done

    # --- C2: a decision reference must resolve to a heading in the decision log -----------------
    # Resolved against the CANDIDATE tree, not the base: a PR that adds D24 and cites it in the
    # same commit is correct, and a rule that only knew the old file would reject it.
    for d in $(printf '%s\n' "$text" | grep -oE '(^|[^A-Za-z0-9_])D[1-9][0-9]*([^A-Za-z0-9_]|$)' | grep -oE 'D[0-9]+'); do
      N_DREF=$((N_DREF + 1))
      grep -qE "^## $d — " "$DECFILE" \
        || cc_violation "$f:$lno: cites $d, which has no '## $d — ' heading in $DECISIONS"
    done

    # --- (the path-claim check deliberately does NOT live here — see the header) ----------------
  done < <(cc_scan_file "$f")
done < "$SCANLIST"

# --- C4: a decision's date must be near the commit that INTRODUCED it ---------------------------
# Attributed per COMMIT rather than per line, so there is no pickaxe ambiguity about which commit a
# repeated `- date:` string belongs to. The branch tip is the wrong anchor on a multi-commit branch
# — and the #173 entry was stamped a day in the FUTURE relative to its own commit, which is exactly
# the defect and is invisible against a later tip.
#
# MERGE COMMITS ARE WALKED TOO. `--no-merges` looks obviously right (a merge introduces nothing of
# its own) and is wrong here: this project merges the default branch INTO a feature branch to
# refresh it, and a conflict resolution inside that merge really can introduce a `date:` line that
# exists in no parent. Skipping merges left that line checked by nothing. `git show -m` diffs a
# merge against each parent, and `--first-parent`-style double counting is harmless because the
# same line simply gets the same verdict twice.
#
# The date field is VALIDATED, not merely pattern-matched. `- date: TBD` used to be skipped by the
# `[ -n "$d" ] || continue` below, so a decision with no date at all sailed through with `dates=0`
# — a rule reporting that it checked nothing, in the same words a clean run uses. And a date that
# matches the pattern can still be impossible: the civil-day conversion happily normalizes
# `2026-02-30` into March 2, so it would pass against a March commit.
cc_valid_day() {   # <YYYY-MM-DD> -> 0 if it is a real Gregorian date
  printf '%s\n' "$1" | awk -F- '
    { y = $1 + 0; m = $2 + 0; d = $3 + 0
      if (m < 1 || m > 12 || d < 1) { exit 1 }
      split("31 28 31 30 31 30 31 31 30 31 30 31", L, " ")
      max = L[m] + 0
      if (m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) { max = 29 }
      if (d > max) { exit 1 }
      exit 0 }'
}

# cc_added_dates <commit> — the `- date:` lines THIS commit introduced, with the diff marker
# stripped. For a merge that means lines added relative to EVERY parent, which is a distinction
# `git show -m` cannot make: -m diffs the merge against each parent in turn, so a line that came
# from ONE parent appears as an addition relative to the other. On a feature branch that merges the
# default branch and resolves a conflict in the decision log, every decision the default branch had
# accumulated was therefore re-attributed to the merge commit and compared against the merge's own
# date — a guaranteed red build on an entry that was dated correctly when it was written, and that
# does not even appear in the branch's own `main...feature` diff.
#
# `--cc` is exactly the right tool: it shows only hunks that differ from ALL parents, which is the
# definition of "introduced by the merge itself" (a conflict resolution). Its output carries one
# +/- column PER PARENT, so a line the merge introduced has a `+` in every column — hence the
# parent count rather than a hardcoded `++`.
cc_added_dates() {
  local c="$1" np
  np="$(git rev-list --parents -n1 "$c" 2>/dev/null | wc -w | tr -d ' ')"
  np=$((np - 1))
  if [ "$np" -gt 1 ]; then
    git show --cc --format='' --unified=0 "$c" -- "$DECISIONS" 2>/dev/null \
      | grep -E "^\+{$np}[[:space:]]*-[[:space:]]*date:" \
      | sed -E "s/^\+{$np}//"
  else
    git show --format='' --unified=0 "$c" -- "$DECISIONS" 2>/dev/null \
      | grep -E '^\+[[:space:]]*-[[:space:]]*date:' \
      | sed 's/^+//'
  fi
}

for c in $(git rev-list "$REVRANGE" -- "$DECISIONS" 2>/dev/null); do
  cday="$(git log -1 --format='%cI' "$c" 2>/dev/null)"; cday="${cday%%T*}"
  [ -n "$cday" ] || continue
  cnum="$(cc_daynum "$cday")"
  while IFS= read -r dl; do
    if printf '%s' "$dl" | grep -qE "$CC_EXEMPT_RE"; then
      N_EXEMPT=$((N_EXEMPT + 1)); continue
    fi
    N_DATE=$((N_DATE + 1))
    # THE FIELD'S VALUE, not the first date-shaped substring anywhere on the line. Scanning the
    # whole line let trailing prose satisfy the rule: `- date: TBD # expected around 2026-07-31`
    # passed on 2026-07-31 while the field itself carried no date at all — the rule reporting a
    # pass on an input it exists to reject. Take what follows `date:` up to the first whitespace,
    # and require THAT to be the date.
    d="$(printf '%s\n' "$dl" \
          | sed -nE 's/^.*[[:space:]]*-[[:space:]]*date:[[:space:]]*([^[:space:]]*).*$/\1/p' \
          | head -n1)"
    case "$d" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) d="" ;;
    esac
    if [ -z "$d" ]; then
      cc_violation "$DECISIONS ($c): a 'date:' field carries no YYYY-MM-DD value: $dl"
      continue
    fi
    if ! cc_valid_day "$d"; then
      cc_violation "$DECISIONS ($c): 'date: $d' is not a real calendar date"
      continue
    fi
    dnum="$(cc_daynum "$d")"
    diff=$((dnum - cnum)); [ "$diff" -lt 0 ] && diff=$((-diff))
    # Absolute one-day tolerance, BOTH directions. A future stamp is a violation exactly as a
    # stale one is; the #173 entry was a day ahead, not behind.
    [ "$diff" -le 1 ] \
      || cc_violation "$DECISIONS ($c): 'date: $d' is $diff days from its commit date ($cday)"
  done < <(cc_added_dates "$c")
done

# --- C1, resolved in one deduplicated pass ------------------------------------------------------
N_REF_DISTINCT="$(awk -F'\t' '{print $1}' "$REFS" 2>/dev/null | sort -u | grep -c . || true)"
if [ "$LIVE" -eq 1 ] && [ "$N_REF_DISTINCT" -eq 0 ]; then
  check_note "NOTE: --live had no references to resolve in this range."
elif [ "$LIVE" -eq 1 ]; then
  if ! cc_live_init; then
    # FAIL CLOSED. --live was asked for and could not be delivered; reporting a pass here would be
    # the silent no-op that design-principles separates from a legitimate degrade.
    echo "check-claims: FATAL — --live requested but gh/jq is unavailable, unauthenticated, or the" >&2
    echo "              origin repository could not be resolved. This is NOT a pass." >&2
    exit 3
  fi
  for n in $(awk -F'\t' '{print $1}' "$REFS" | sort -un); do
    cc_entity "$n"
    ent="$(cat "$CACHE/$n")"
    kind="$(printf '%s' "$ent" | cut -f1)"
    st="$(printf '%s' "$ent" | cut -f2)"
    rs="$(printf '%s' "$ent" | cut -f3)"
    sites="$(awk -F'\t' -v k="$n" '$1==k{print $2}' "$REFS" | sort -u | tr '\n' ' ')"
    # "DOES NOT EXIST" AND "COULD NOT BE READ" ARE DIFFERENT ANSWERS and are reported as such. The
    # first draft collapsed them, so a transport failure mid-run accused a perfectly real issue of
    # being fabricated — a wrong claim produced by the tool built to stop wrong claims. Unreadable
    # is fatal (exit 3) rather than a violation, because the honest state is "I could not tell".
    case "$ent" in
      UNREADABLE)
        echo "check-claims: FATAL — #$n could not be read from $CC_SLUG (transport, auth or a" >&2
        echo "              malformed response). This is NOT a pass, and NOT a missing issue." >&2
        exit 3 ;;
      MISSING)
        cc_violation "#$n does not resolve in $CC_SLUG (cited at: $sites)"
        continue ;;
    esac
    # A citation that DECLARES its kind must match it. `gh issue view` answers for a PR number too,
    # so naming a pull request as an issue is a wrong claim that bare existence waves through.
    # adb-claim-ok: the comment above describes the rule; it is not itself a citation.
    #
    # Blame is per SITE, not per number. An earlier draft reported every site of a number whose
    # hint mismatched anywhere, which accused correctly-written lines of a neighbour's error — it
    # flagged this file's own correctly-written pull-request citation because a DIFFERENT line
    # quoted the wrong spelling as an example. A diagnostic that names an innocent line is one
    # the reader learns to distrust.
    awk -F'\t' -v k="$n" '$1==k && $3!="bare" {print $3 "\t" $2}' "$REFS" | sort -u \
      | while IFS="$(printf '\t')" read -r hint site; do
          [ "$hint" = "$kind" ] && continue
          case "$hint" in
            issue) printf 'ISSUE\t%s\n' "$site" ;;
            pull)  printf 'PULL\t%s\n'  "$site" ;;
          esac
        done > "$WORK/kindbad"
  while IFS="$(printf '\t')" read -r want site; do
      [ -n "$site" ] || continue
      case "$want" in
        ISSUE) cc_violation "#$n is cited as an issue at $site, but it resolves to a pull request" ;;
        PULL)  cc_violation "#$n is cited as a PR at $site, but it resolves to an issue" ;;
      esac
    done < "$WORK/kindbad"
    # NOT_PLANNED means the work was ABANDONED. Citing it as tracking reads a cancelled requirement
    # as a satisfied one. Legitimate historical prose about such an issue carries the audited
    # marker instead of being silently allowed.
    if [ "$kind" = "issue" ] && [ "$st" = "CLOSED" ] && [ "$rs" = "NOT_PLANNED" ]; then
      cc_violation "#$n was closed NOT_PLANNED — it tracks nothing (at: $sites). If the reference is deliberately historical, mark the line 'adb-claim-ok: <reason>'."
    fi
  done
else
  check_note "NOTE: the issue/PR-reference check did NOT run ($N_REF_DISTINCT distinct reference(s) unverified)."
  check_note "NOTE: it needs the network, so it is a CI-only step — selfcheck stays hermetic (D13)."
  check_note "NOTE: run 'bash scripts/check-claims.sh --live' to resolve them by hand."
fi

# --- what this run actually evaluated -----------------------------------------------------------
printf 'check-claims: range=%s files=%d added-lines=%d refs=%s/%d live-lookups=%d d-refs=%d dates=%d exempt=%d binary-skipped=%d path-skipped=%d\n' \
  "$RANGE" "$N_FILES" "$N_ADDED" "$N_REF_DISTINCT" "$N_REF_OCC" "$N_REF_LOOKUPS" \
  "$N_DREF" "$N_DATE" "$N_EXEMPT" "$N_SKIP_BIN" "$N_SKIP_PATH"

check_result "no unverified claims in the range"
