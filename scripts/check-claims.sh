#!/usr/bin/env bash
# ai-dev-baseline — claim lint (issue #212).
#
# A VERIFIABLE ASSERTION written into a tracked file, with no gate between writing it and
# committing it. That is one class, and the #173 run (PR #210) shipped four of them, three wrong:
# a `#206` citation that tracked something else, a `#207` citation for an issue that DID NOT EXIST
# (rendered into all three agents' skills), "(recorded as D17)" for a decision that is D18, and a
# CHANGELOG sentence describing an edit that had not been made. Two pre-existing `#150` citations
# pointed at an issue closed NOT_PLANNED — abandoned work, reading as delivered.
#
# base/practices/verify-before-asserting.md already forbids exactly this for PR/issue STATUS, and
# D16 is the precedent for why it is a gate rather than another paragraph: the prose version failed
# twice with the practice loaded in context. An issue NUMBER is the same kind of claim, and a `gh`
# call plus a `grep` is all "find a supporting quote" means for an identifier — so it can be a lint
# instead of an instruction.
#
# SCOPED TO THE ADDED LINES OF A RANGE, never the whole tree. That is not an optimization, it is
# what makes the check adoptable: this tree carries 2450 numeric references over 157 distinct
# numbers, of which 11 cite issues legitimately closed NOT_PLANNED and 39 are not issues at all
# (pull-request numbers, plus deliberate fixtures for 0 and 999999999). A whole-tree run would be
# red forever on history nobody is asserting anything about today.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/gh"; mkdir -p "$CACHE"
DECISIONS=".ai-dev-baseline/decisions.md"

# What the run actually evaluated, REPORTED rather than inferred. A guard's failure mode is
# silence: a checker wired to an empty range scans nothing and prints exactly what a clean run
# prints. D22 is this repo paying for that once already, so every axis carries a count and a zero
# is visible in the log.
N_FILES=0; N_ADDED=0; N_SKIP_BIN=0
N_REF_OCC=0; N_REF_DISTINCT=0; N_REF_LOOKUPS=0
N_DREF=0; N_DATE=0; N_EXEMPT=0

cc_violation() { check_note "$1"; check_fail; }

# --- the range's changed paths, resolved once ---------------------------------------------------
# --no-renames so a moved file surfaces BOTH paths: a claim about the path a file moved OUT of is a
# claim about this diff. -z because a tracked path may carry a space or a non-ASCII byte, which git
# would otherwise quote into a different string than the one the prose names.
CHANGED="$WORK/changed"; : > "$CHANGED"
while IFS= read -r -d '' p; do
  [ -n "$p" ] && printf '%s\n' "$p" >> "$CHANGED"
done < <(git diff --name-only --no-renames -z --diff-filter=ACMRD "$RANGE" 2>/dev/null)

# The candidate tree's file list and decision log, read once rather than per-reference.
TREEFILES="$WORK/treefiles"
git ls-tree -r --name-only "$HEADREV" > "$TREEFILES" 2>/dev/null || : > "$TREEFILES"
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

# cc_entity <n> — populates $CACHE/<n> with "<kind>\t<state>\t<reason>"; kind is issue|pull|empty.
# Writes a file rather than printing so the lookup counter is incremented in THIS shell: a
# command substitution runs in a subshell, where the increment would be discarded and the reported
# count would be a permanent zero.
cc_entity() {
  local n="$1" f="$CACHE/$1" json fields st rs url seg
  [ -f "$f" ] && return 0
  N_REF_LOOKUPS=$((N_REF_LOOKUPS + 1))
  json="$(gh issue view "$n" --repo "$CC_SLUG" --json state,stateReason,url 2>/dev/null)" || json=""
  if [ -z "$json" ]; then printf '\t\t\n' > "$f"; return 0; fi
  # Read and parse as SEPARATE steps: a pipeline reports only its last command's status, so a
  # failed read would reach the parser as empty stdin, indistinguishable from an empty answer.
  fields="$(printf '%s' "$json" | jq -r '.state // "", (.stateReason // ""), (.url // "")' 2>/dev/null)" || fields=""
  { IFS= read -r st; IFS= read -r rs; IFS= read -r url; } <<EOF
$fields
EOF
  # Pull requests and issues share ONE number space, and `gh issue view <PR number>` answers with
  # the pull request, so only the URL's path segment discriminates them. Compared EXACTLY at its
  # known position, never searched for anywhere in the URL: a repository literally named `issues`
  # exists in the wild, and a substring test would read its PR URLs as issues.
  seg="${url%/*}"; seg="${seg##*/}"
  case "$seg" in
    pull)   printf 'pull\t%s\t%s\n'  "$st" "$rs" > "$f" ;;
    issues) printf 'issue\t%s\t%s\n' "$st" "$rs" > "$f" ;;
    *)      printf '\t\t\n' > "$f" ;;
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
# This emits the RAW line and lets each rule strip what IT should not see, because the two needs
# are opposite and collapsing them silently disables a rule. C1/C2 must not see inside a code span
# (quoting a number while documenting a grammar is not a citation); C3 looks for a BACKTICKED path
# and so must see spans intact. An earlier draft stripped spans here, in one place, for everyone —
# which deleted exactly the tokens C3 searches for and made it structurally incapable of firing.
# It reported `path-claims=0` on a commit carrying nine of them, and no assertion anywhere was red.
#
# Content comes from the range's HEAD revision, never the working tree, so an explicit --range
# scans what it names rather than whatever happens to be checked out.
cc_scan_file() {   # <file> -> "<lineno>\t<raw text>" per scannable added line
  local f="$1" lines="$WORK/ln" is_md=0
  git diff --unified=0 --no-renames "$RANGE" -- "$f" 2>/dev/null | awk '
    /^@@/ {
      m = $3; sub(/^\+/, "", m)
      n = split(m, P, ",")
      start = P[1] + 0; cnt = (n > 1 ? P[2] + 0 : 1)
      for (i = 0; i < cnt; i++) print start + i
    }' | sort -n -u > "$lines"
  [ -s "$lines" ] || return 0
  case "$f" in *.md) is_md=1 ;; esac
  git show "$HEADREV:$f" 2>/dev/null | awk -v want="$lines" -v md="$is_md" '
    BEGIN { while ((getline l < want) > 0) W[l + 0] = 1 }
    {
      # Fenced blocks are dropped for markdown regardless of rule: nothing inside one declares.
      if (md) {
        if ($0 ~ /^[[:space:]]*(```|~~~)/) { fence = !fence; next }
        if (fence) next
      }
      if (!(NR in W)) next
      printf "%d\t%s\n", NR, $0
    }'
}

# cc_prose <raw> — the view C1 and C2 get: inline code spans and single-line HTML comments removed.
# Multi-backtick spans are collapsed onto the single-tick rule first, so a `` `#5` ``-style span is
# stripped too. C3 deliberately does NOT use this.
cc_prose() {
  printf '%s\n' "$1" | sed -e 's/<!--.*-->/ /g' -e 's/``*/`/g' -e 's/`[^`]*`/ /g'
}

# The audited escape. A line carrying this token is exempt from every rule below — greppable, so
# "what did we wave through?" is one command. It exists because a blanket NOT_PLANNED rejection is
# semantically wrong: this repo legitimately writes prose ABOUT abandoned issues, and a gate with
# no way to say so gets worked around instead of obeyed.
CC_EXEMPT='adb-claim-ok'

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
    case "$raw" in *"$CC_EXEMPT"*) N_EXEMPT=$((N_EXEMPT + 1)); continue ;; esac
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
      hint="bare"
      case "$text" in
        *"PR #$n"*|*"PR#$n"*|*"pull request #$n"*) hint="pull" ;;
        *"issue #$n"*|*"Issue #$n"*)               hint="issue" ;;
      esac
      printf '%s\t%s:%s\t%s\n' "$n" "$f" "$lno" "$hint" >> "$REFS"
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
for c in $(git rev-list --no-merges "$RANGE" -- "$DECISIONS" 2>/dev/null); do
  cday="$(git log -1 --format='%cI' "$c" 2>/dev/null)"; cday="${cday%%T*}"
  [ -n "$cday" ] || continue
  cnum="$(cc_daynum "$cday")"
  while IFS= read -r dl; do
    case "$dl" in *"$CC_EXEMPT"*) N_EXEMPT=$((N_EXEMPT + 1)); continue ;; esac
    d="$(printf '%s\n' "$dl" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)"
    [ -n "$d" ] || continue
    N_DATE=$((N_DATE + 1))
    dnum="$(cc_daynum "$d")"
    diff=$((dnum - cnum)); [ "$diff" -lt 0 ] && diff=$((-diff))
    # Absolute one-day tolerance, BOTH directions. A future stamp is a violation exactly as a
    # stale one is; the #173 entry was a day ahead, not behind.
    [ "$diff" -le 1 ] \
      || cc_violation "$DECISIONS ($c): 'date: $d' is $diff days from its commit date ($cday)"
  done < <(git show --format='' --unified=0 "$c" -- "$DECISIONS" 2>/dev/null \
             | grep '^+' | grep -E '^\+[[:space:]]*-[[:space:]]*date:')
done

# --- C1, resolved in one deduplicated pass ------------------------------------------------------
N_REF_DISTINCT="$(awk -F'\t' '{print $1}' "$REFS" 2>/dev/null | sort -u | grep -c . || true)"
if [ "$LIVE" -eq 1 ]; then
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
    if [ -z "$kind" ]; then
      cc_violation "#$n does not resolve in $CC_SLUG (cited at: $sites)"
      continue
    fi
    # A citation that DECLARES its kind must match it. `gh issue view` answers for a PR number too,
    # so "issue #210" naming a pull request is a wrong claim that bare existence waves through.
    for hint in $(awk -F'\t' -v k="$n" '$1==k{print $3}' "$REFS" | sort -u); do
      case "$hint" in
        issue) [ "$kind" = "issue" ] || cc_violation "#$n is cited as an issue but resolves to a pull request (at: $sites)" ;;
        pull)  [ "$kind" = "pull" ]  || cc_violation "#$n is cited as a PR but resolves to an issue (at: $sites)" ;;
      esac
    done
    # NOT_PLANNED means the work was ABANDONED. Citing it as tracking reads a cancelled requirement
    # as a satisfied one. Legitimate historical prose about such an issue carries the audited
    # marker instead of being silently allowed.
    if [ "$kind" = "issue" ] && [ "$st" = "CLOSED" ] && [ "$rs" = "NOT_PLANNED" ]; then
      cc_violation "#$n was closed NOT_PLANNED — it tracks nothing (at: $sites). If the reference is deliberately historical, mark the line '$CC_EXEMPT: <reason>'."
    fi
  done
else
  check_note "NOTE: the issue/PR-reference check did NOT run ($N_REF_DISTINCT distinct reference(s) unverified)."
  check_note "NOTE: it needs the network, so it is a CI-only step — selfcheck stays hermetic (D13)."
  check_note "NOTE: run 'bash scripts/check-claims.sh --live' to resolve them by hand."
fi

# --- what this run actually evaluated -----------------------------------------------------------
printf 'check-claims: range=%s files=%d added-lines=%d refs=%s/%d live-lookups=%d d-refs=%d dates=%d exempt=%d binary-skipped=%d\n' \
  "$RANGE" "$N_FILES" "$N_ADDED" "$N_REF_DISTINCT" "$N_REF_OCC" "$N_REF_LOOKUPS" \
  "$N_DREF" "$N_DATE" "$N_EXEMPT" "$N_SKIP_BIN"

check_result "no unverified claims in the range"
