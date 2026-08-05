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
#   3  a required half of the check could NOT be run (fail closed — never a pass): --live was
#      requested and gh/jq is unavailable, or the shared markdown filter failed on a .md file.
#      Both are "I could not tell", which is never the same answer as "nothing is wrong" — a
#      filter that returns nothing looks exactly like a file with no claims in it.
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
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "check-claims"

# --- shared primitives (source, never copy — docs/design-principles.md) ------------------------
_cc_common="scripts/lib/common.sh"
[ -f "$_cc_common" ] || { echo "check-claims: FATAL — $_cc_common not found" >&2; exit 2; }
# shellcheck source=/dev/null
. "$_cc_common"
# THE PROSE FILTER IS NOT OPTIONAL (#251). Without it the `.md` rules below would scan raw markdown
# — every fenced, quoted and commented number in the range read as a live citation. Probed for the
# same reason roadmap-lib.sh and skill-compose.sh probe: a common.sh that predates the filter loads
# perfectly well and simply has no `adb_md_prose` in it, and under `set -u` the first use would be
# an unbound-variable abort naming a variable rather than the real problem.
command -v adb_md_prose >/dev/null 2>&1 \
  || { echo "check-claims: FATAL — $_cc_common is missing the shared markdown filter (adb_md_prose)" >&2; exit 2; }

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
DECISIONS=".ai-dev-baseline/decisions.md"
_CC_NL=$'\n'

# What the run actually evaluated, REPORTED rather than inferred. A guard's failure mode is
# silence: a checker wired to an empty range scans nothing and prints exactly what a clean run
# prints. D22 is this repo paying for that once already, so every axis carries a count and a zero
# is visible in the log.
N_FILES=0; N_ADDED=0; N_SKIP_BIN=0; N_SKIP_PATH=0
N_REF_OCC=0; N_REF_DISTINCT=0; N_REF_LOOKUPS=0
N_DREF=0; N_DATE=0; N_EXEMPT=0; N_MD_STRUCT=0

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
# One lookup per DISTINCT number per run, cached in a `declare -A` map. It was a directory of
# one-line files only because bash 3.2 had no associative arrays; the floor is 5.3 (#256), so the
# map is now just a map — no mkdir, no temp file per number, and no `cat` fork per read.
#
# Cached WITHIN the run only: a close reason is mutable external state, so a cache that outlived
# the invocation would be exactly the stale-state trust verify-before-asserting.md exists to
# remove. The map is a shell variable, so that property is now structural rather than a promise
# about a directory.
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

# cc_entity <n> — populates CC_ENT[<n>] with "<kind>\t<state>\t<extra>\t<number>", or one of the
# two sentinels `MISSING` / `UNREADABLE`.
#
# STILL CALLED BARE, never captured, and that has not changed with the map: it increments
# N_REF_LOOKUPS, and a `$( )` capture would run it in a subshell where the increment is discarded
# and the reported count is a permanent zero. `${ cc_entity "$n"; }` would in fact keep it now —
# but "populate the map, then read the map" needs no capture at all, so the safer shape is also
# the simpler one.
#
# THE READ ITSELF IS NOT HERE. It is `adb_gh_entity` in common.sh, shared with state-assert.sh —
# this file's first draft carried its own copy and had already drifted from it in three ways a
# reviewer could name: a transport failure was reported as "does not resolve", a malformed payload
# was flattened into a nonexistent entity, and the returned URL's number was never checked against
# the number asked for. That is precisely the copy-instead-of-source failure this repo treats as a
# blocking review finding, so the primitive was generalized rather than the copy patched.
declare -A CC_ENT=()
cc_entity() {
  local n="$1" rec rc
  # `+set` rather than a truth test: a cached value is never empty, but keying on emptiness would
  # re-look-up anything that ever was, which is the bug the file cache could not have.
  [ -n "${CC_ENT[$n]+set}" ] && return 0
  N_REF_LOOKUPS=$((N_REF_LOOKUPS + 1))
  rec="$(adb_gh_entity "$CC_SLUG" "$n" issue stateReason)"; rc=$?
  case "$rc" in
    0)
      # The response must be ABOUT the number that was asked for. Real gh always is, so this only
      # fires on a misbehaving or redirected read — but reporting on #9 from a payload describing
      # #146 is a wrong answer, and a wrong answer is worse than no answer.
      if [ "${ printf '%s' "$rec" | cut -f4; }" -ne "$n" ] 2>/dev/null; then
        CC_ENT["$n"]=UNREADABLE
      else
        CC_ENT["$n"]="$rec"
      fi ;;
    1) CC_ENT["$n"]=MISSING ;;
    *) CC_ENT["$n"]=UNREADABLE ;;
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
  local f="$1" lines="$WORK/ln"
  awk -F'\t' -v want="$f" '$1 == want { print $2 }' "$ADDEDMAP" | sort -n -u > "$lines"
  [ -s "$lines" ] || return 0
  # NO MARKDOWN MODEL HERE ANY MORE (#251). This used to carry a whole-file fence toggle — a
  # private parser, and a worse one than the shared filter it sat next to: it knew nothing of
  # blockquotes, HTML comments, list containers, or a closer shorter than its opener. Structure is
  # now decided once, by `cc_prose_view` below, and this function is back to what its name says.
  #
  # A STRUCTURAL LINE IS STILL EMITTED, rather than dropped as the toggle dropped a fenced one.
  # That is deliberate: the EXEMPTION is read from the raw line, so a line this function silently
  # swallowed could never be reported as exempt, and `added-lines` would quietly mean "added lines
  # that survived a parser" while reading like "added lines". Its prose view is empty, so no rule
  # can fire on it; `md-structural` below counts them.
  git show "$HEADREV:$f" 2>/dev/null | awk -v want="$lines" '
    BEGIN { while ((getline l < want) > 0) W[l + 0] = 1 }
    { if (NR in W) printf "%d\t%s\n", NR, $0 }'
}

# cc_prose_view <file> — populate CC_MASK with the shared filter`s MASK view of the WHOLE file, one
# element per line (CC_MASK[n-1] is line n). Returns non-zero if the filter could not be run.
#
# THE WHOLE FILE, NEVER THE ADDED LINES ALONE, and that is the property the multi-line-comment
# fixture actually pins. A block is opened by a line the diff may not contain: feeding only added
# lines to a paragraph-aware parser asks it to decide containment from a body with its openers cut
# out, which is the same line-at-a-time mistake in a new costume. So the file is filtered whole and
# the added-line set is applied afterwards — the ordering `cc_scan_file` already used.
#
# MASK, NOT TEXT. `MD_TEXT` leaves inline spans INTACT by design; the reference and decision rules
# must not see inside one, so they get the view where a resolved span is \x01. Masking rather than
# deleting is also what stops `clo`x`ses #42` collapsing into a keyword nobody wrote.
#
# FAIL LOUD, because the failure mode here is a clean-looking pass. `adb_md_prose` is fail-closed —
# its awk prints a per-invocation nonce trailer and the wrapper returns non-zero without it — so a
# killed or truncated run is a status, not a short result. Swallowing that would give every line of
# the file an empty prose view: zero references, zero decision refs, and a confident PASS. That is
# precisely the silently-disabled rule this file`s own header is about.
CC_MASK=()
cc_prose_view() {   # <file>
  local f="$1" nraw nprose
  CC_MASK=()
  # The pipeline`s status IS adb_md_prose`s (it is last), which is the one that can fail closed.
  git show "$HEADREV:$f" 2>/dev/null | adb_md_prose mask > "$WORK/prose" || return 1
  mapfile -t CC_MASK < "$WORK/prose"
  # ONE OUTPUT LINE PER INPUT LINE, ASSERTED RATHER THAN TRUSTED. Every lookup below is
  # `CC_MASK[lno - 1]`, so the whole conversion rests on that alignment — and its failure mode is
  # SILENCE, not a crash: a prose view one line short makes every subsequent lookup read the wrong
  # line, and a view that is EMPTY makes every line read "", which is zero references, zero
  # decision refs and a confident PASS. That is indistinguishable in the log from a range with no
  # claims in it, which is the exact shape this file`s header was written about.
  #
  # The filter documents the 1:1 invariant and check-common-lib.sh pins it, so this is a FORWARD
  # guard on a contract that holds today, not a workaround for a known break — said plainly rather
  # than implying it caught something. It cost one awk and it turns a future renumbering from a
  # silent pass into a named failure.
  #
  # `awk END { print NR }` rather than `wc -l`, because a file whose last line carries no newline
  # is one line short by wc`s counting and would fail this check spuriously.
  nraw="$(git show "$HEADREV:$f" 2>/dev/null | awk 'END { print NR }')"
  nprose="${#CC_MASK[@]}"
  [ "$nraw" = "$nprose" ] || return 2
  return 0
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
  # The prose view is resolved ONCE PER FILE, before any line of it is read — the filter is
  # paragraph-aware and needs the whole body.
  CC_IS_MD=0
  case "$f" in
    *.md)
      CC_IS_MD=1
      cc_prose_view "$f"; _cc_pv=$?
      case "$_cc_pv" in
        0) : ;;
        2) echo "check-claims: FATAL — the prose view of '$f' has a different line count than the file." >&2
           echo "              Every lookup is by line number, so this is NOT a pass: it would silently" >&2
           echo "              scan the wrong lines, or none at all." >&2
           exit 3 ;;
        *) echo "check-claims: FATAL — the shared markdown filter failed on '$f'. This is NOT a pass:" >&2
           echo "              with no prose view every rule below would scan nothing and report clean." >&2
           exit 3 ;;
      esac ;;
  esac
  # MATERIALIZED, not piped. `done < <(cc_scan_file "$f")` discards the scanner`s exit status, so an
  # awk that died mid-file arrived as zero added lines — a file this lint never read, reported in
  # the same words a clean file uses. Same fail-open shape as the filter guard above, one line up
  # the pipe, and it is fixed here because this conversion is what made the scan path load-bearing.
  cc_scan_file "$f" > "$WORK/scanned" || {
    echo "check-claims: FATAL — could not scan '$f' (the added-line reader failed). This is NOT a pass." >&2
    exit 3
  }
  while IFS=$'\t' read -r lno raw; do
    [ -n "$lno" ] || continue
    N_ADDED=$((N_ADDED + 1))
    # The exemption is read from the RAW line: the marker is normally written as a trailing
    # comment, which for a markdown file may well sit inside a code span.
    if printf '%s' "$raw" | grep -qE "$CC_EXEMPT_RE"; then
      N_EXEMPT=$((N_EXEMPT + 1)); continue
    fi
    # THE TWO VIEWS, and the separation is the point (see cc_prose_view). The rules read the
    # filter`s MASK view of this line; the exemption above read the RAW one. An index past the end
    # of CC_MASK is a line the filter emitted nothing for, which reads as empty — correct by
    # construction for a trailing structural line.
    if [ "$CC_IS_MD" -eq 1 ]; then
      text="${CC_MASK[lno - 1]-}"
      [ -n "$text" ] || N_MD_STRUCT=$((N_MD_STRUCT + 1))
    else
      text="$raw"
    fi

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
  done < "$WORK/scanned"
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
  cnum="${ cc_daynum "$cday"; }"
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
    dnum="${ cc_daynum "$d"; }"
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
    ent="${CC_ENT[$n]}"
    kind="${ printf '%s' "$ent" | cut -f1; }"
    st="${ printf '%s' "$ent" | cut -f2; }"
    rs="${ printf '%s' "$ent" | cut -f3; }"
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
      | while IFS=$'\t' read -r hint site; do
          [ "$hint" = "$kind" ] && continue
          case "$hint" in
            issue) printf 'ISSUE\t%s\n' "$site" ;;
            pull)  printf 'PULL\t%s\n'  "$site" ;;
          esac
        done > "$WORK/kindbad"
  while IFS=$'\t' read -r want site; do
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
# `md-structural` is new with #251 and is not decoration: it is the count of added markdown lines
# whose PROSE VIEW IS EMPTY — a fence body, a blockquote, indented code, an HTML comment, and also
# an ordinary BLANK line, which resolves to nothing for the same reason and is not worth a second
# counter to separate. Before the conversion the fenced ones were dropped inside the scanner, so
# `added-lines` read like "added lines" while meaning "added lines a private parser let through".
# Reporting both keeps D22's rule honest: a run that suddenly strips far more than it used to is
# now visible in the log rather than indistinguishable from a range with fewer claims in it.
printf 'check-claims: range=%s files=%d added-lines=%d md-structural=%d refs=%s/%d live-lookups=%d d-refs=%d dates=%d exempt=%d binary-skipped=%d path-skipped=%d\n' \
  "$RANGE" "$N_FILES" "$N_ADDED" "$N_MD_STRUCT" "$N_REF_DISTINCT" "$N_REF_OCC" "$N_REF_LOOKUPS" \
  "$N_DREF" "$N_DATE" "$N_EXEMPT" "$N_SKIP_BIN" "$N_SKIP_PATH"

check_result "no unverified claims in the range"
