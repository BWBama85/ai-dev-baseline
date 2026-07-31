#!/usr/bin/env bash
# ai-dev-baseline — fact-drift lint.
#
# Some FACTS are unavoidably restated in more than one hand-written doc: the gate
# axis list, the cross-agent invocation commands, the dispatch hang backstop, and
# the role-resolution order. Those restatements are exactly where drift is born (issue
# #30). This lint pins each fact to its canonical source and asserts every consumer
# that restates it still carries the canonical token — so a value changed in one place
# but not the others fails CI instead of silently diverging.
#
# It is deliberately a small, ALLOWLISTED check — not a natural-language equivalence
# engine. Each `fact` rule asserts that a stable token (an axis name, a literal
# invocation string, "2700", "hang backstop") is PRESENT in each file that restates it.
# It never forbids incidental wording, so rewording a doc never trips it; only dropping
# or changing a canonical value does.
#
# `stale` is the narrow negative counterpart, used ONLY for a value a fact has retired:
# presence-checking cannot catch a file that carries the new value AND keeps the old one
# beside it, which is how a superseded figure survives a repoint (#93). Reach for it when
# a fact replaces an earlier one, never as a general prose blocklist.
#
# The token appears in the lint too — that is intentional, not a fourth copy: the
# canonical source (base/roles.md, scripts/lib/project-gates.sh) is itself in every
# rule's file list, so renaming the value there fails the lint until the rename is
# propagated to the token here AND to every consumer together. Adding a fact = add a
# `fact <label> <token-or-pattern> -- <files…>` line. Adding a consumer that restates
# an existing fact = append the file to that fact's list.
#
# A NEGATIVE rule's failure mode is SILENCE, so this lint carries its own negative test (#213).
# Every `absent:` rule must declare the real superseded spellings it exists to catch, as one or
# more `fires:<witness>` arguments, and two things are then proven rather than assumed:
#
#   1. ALWAYS (normal mode): each witness must actually match its own pattern. `absent:\[bot\]\$`
#      shipped green while matching NOTHING — the two real idioms are `sed 's/\[bot\]$//'` and
#      jq's `sub("\\[bot\\]$"; "")`, so the bracket is always BACKSLASH-ESCAPED and a pattern for a
#      contiguous `[bot]$` catches neither. A pin that cannot fire is strictly worse than no pin:
#      it spends CI time and reports safety it never checked.
#   2. `--mutation` mode: each witness is injected into a COPY of every file the rule pins, the
#      REAL lint is re-run against that copy, and it must come back with the drift verdict naming
#      that rule and that file. This is the end-to-end proof that the whole path — declaration →
#      dispatch → req_absent → exit code — can go red.
#
# The mutation runs against a throwaway tree copy, never the working tree. Mutating a tracked file
# to test a check that reads tracked files is what destroyed 40 minutes of uncommitted work in the
# #173 run; `base/practices/self-review.md` states the method and this mode is the demonstration.
#
# Usage:
#   bash scripts/check-fact-drift.sh              # exit 0 = no drift, 1 = drift found
#   bash scripts/check-fact-drift.sh --mutation   # exit 0 = every absent: pin was seen going RED

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh

MODE=normal
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *) echo "usage: check-fact-drift.sh [--mutation]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "usage: check-fact-drift.sh [--mutation]" >&2; exit 2; fi
if [ "$MODE" = mutation ]; then check_init "fact-mutation"; else check_init "fact-drift"; fi

# What the run actually evaluated, reported rather than inferred (#213). "Checked and clean" and
# "matched nothing" were indistinguishable in the log, which is why the unfirable pin survived
# review; a rule that scans zero files or verifies zero witnesses is now impossible (fact() fails
# on both) AND visible in these totals.
FACT_RULES=0; FACT_ASSERTS=0
FACT_ABSENT_RULES=0; FACT_ABSENT_FILES=0; FACT_WITNESSES=0
_FACT_NL=$'\n'
MUT_ROOT=""; MUT_BAK=""

# fact <label> fixed:<token>|regex:<pattern>|absent:<pattern> [fires:<witness> …] -- <file> […]
# Asserts the token/pattern is present in every listed file — or, for `absent:`, that it is NOT.
#
# `absent:` is the negative counterpart, for a value a fact has SUPERSEDED. Positive presence
# alone cannot enforce a replacement: a file carrying the new figure AND the old one beside it
# passes every positive rule while still telling the reader the wrong thing — which is how a stale
# "≥7-minute" bound would survive a repoint to 45 minutes (#93). Reach for it only when a fact
# retires an earlier value, never as a general prose blocklist.
#
# The grammar is validated BEFORE anything is asserted, and every degenerate shape that would make
# a rule assert nothing is a failure rather than a quiet pass: an unknown or malformed spec, an
# empty needle (which matches every line of every file), a missing `--`, an empty file list, an
# `absent:` rule with no witness, and a `fires:` on a rule that is not `absent:`.
fact() {
  local label spec kind needle wits nwit w f g dupes nfiles
  if [ "$#" -lt 2 ]; then
    check_note "[fact] usage: fact <label> <spec> [fires:<witness> …] -- <file> […]"; check_fail; return
  fi
  label="$1"; spec="$2"; shift 2

  case "$spec" in
    *:*) ;;
    *) check_note "[$label] malformed spec '$spec' (want fixed:/regex:/absent:<value>)"; check_fail; return ;;
  esac
  kind="${spec%%:*}"; needle="${spec#*:}"
  case "$kind" in
    fixed|regex|absent) ;;
    *) check_note "[$label] unknown spec kind '$kind' (want fixed:/regex:/absent:)"; check_fail; return ;;
  esac
  # An empty needle is the other way a rule passes by asserting nothing: `grep -F ''` and
  # `grep -E ''` both match every line, so a positive rule is green forever and a negative one red
  # forever, in neither case because of the value it was written for.
  if [ -z "$needle" ]; then
    check_note "[$label] empty $kind pattern — a rule that asserts nothing"; check_fail; return
  fi

  # Witnesses accumulate into a NEWLINE-DELIMITED string rather than an array: expanding an empty
  # array under `set -u` is an unbound-variable error on the bash 3.2 that ships with macOS.
  wits=""; nwit=0
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      fires:*)
        w="${1#fires:}"
        if [ -z "$w" ]; then
          check_note "[$label] empty fires: witness"; check_fail; return
        fi
        case "$w" in
          *"$_FACT_NL"*)
            check_note "[$label] fires: witness spans lines; grep is line-oriented, so a witness is ONE line"
            check_fail; return ;;
        esac
        wits="${wits}${w}${_FACT_NL}"; nwit=$((nwit + 1)) ;;
      *) check_note "[$label] unexpected argument '$1' before '--'"; check_fail; return ;;
    esac
    shift
  done
  if [ "$#" -eq 0 ]; then
    check_note "[$label] missing '--' before the file list"; check_fail; return
  fi
  shift                                  # drop the --
  if [ "$#" -eq 0 ]; then
    check_note "[$label] no files — a rule that scans nothing can never fail"; check_fail; return
  fi
  # A file listed twice asserts nothing new, and under `--mutation` it breaks the backup/restore
  # isolation outright: the second injection overwrites the backup, so the restore puts back an
  # ALREADY-MUTATED file and one witness leaks into the next one's run.
  for f in "$@"; do
    dupes=0
    for g in "$@"; do
      if [ "$g" = "$f" ]; then dupes=$((dupes + 1)); fi
    done
    if [ "$dupes" -gt 1 ]; then
      check_note "[$label] file listed more than once: $f"; check_fail; return
    fi
  done

  if [ "$kind" = absent ]; then
    if [ "$nwit" -eq 0 ]; then
      check_note "[$label] absent: rule declares no fires: witness — see this file's header (#213)"
      check_fail; return
    fi
    # THE CHEAP HALF OF THE PROOF, run on every invocation: a pattern that cannot match the real
    # spelling it retires is unfirable, and that is knowable without touching a single file.
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      if ! printf '%s\n' "$w" | grep -Eq -- "$needle"; then
        check_note "[$label] UNFIRABLE PIN: /$needle/ does not match its own witness [$w]"
        check_fail; return
      fi
      FACT_WITNESSES=$((FACT_WITNESSES + 1))
    done <<EOF
$wits
EOF
    # A pinned file that does not EXIST is a rule asserting nothing about it: `req_absent` is
    # vacuously true on a missing path by design, and the rationale for that (the positive rules
    # report a bad path, so double-reporting one typo helps nobody) only holds for a file some
    # positive rule also pins. A path pinned ONLY here is a silent pass, and counting it as
    # "scanned" turns the totals below into a false claim — the exact thing they exist to prevent.
    nfiles=0
    for f in "$@"; do
      if [ -f "$f" ]; then
        nfiles=$((nfiles + 1))
      else
        check_note "[$label] pinned file does not exist: $f — this rule asserts nothing about it"
        check_fail
      fi
    done
    FACT_ABSENT_RULES=$((FACT_ABSENT_RULES + 1))
    FACT_ABSENT_FILES=$((FACT_ABSENT_FILES + nfiles))
  elif [ "$nwit" -ne 0 ]; then
    check_note "[$label] fires: is only meaningful on an absent: rule"; check_fail; return
  fi

  FACT_RULES=$((FACT_RULES + 1))
  FACT_ASSERTS=$((FACT_ASSERTS + $#))

  if [ "$MODE" = mutation ]; then
    if [ "$kind" = absent ]; then _fact_mutate "$label" "$needle" "$wits" "$@"; fi
    return
  fi

  for f in "$@"; do
    case "$kind" in
      fixed)  req_fixed  "$f" "$needle" "$label" ;;
      regex)  req_regex  "$f" "$needle" "$label" ;;
      absent) req_absent "$f" "$needle" "$label" ;;   # adb-allow: req_absent
    esac
  done
}

# _fact_mutate <label> <pattern> <newline-delimited witnesses> <file> [<file>…]
# The expensive half of the proof, and the reason `--mutation` exists at all: inject each witness
# into a COPY of every pinned file, re-run the REAL lint there, and require the drift verdict.
#
# ONE run per WITNESS, all of that rule's files mutated together. Per-file runs would cost N times
# as much for nothing (req_absent accumulates every file's failure in one pass), but folding
# several witnesses into a single run would let a working witness cover for a broken one.
_fact_mutate() {
  local label="$1" needle="$2" wits="$3"; shift 3
  local w f out rc want
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    # TWO passes: back every file up FIRST, then inject. One pass would leave earlier files
    # mutated when a later one turns out to be missing or unreadable, and the leftovers would
    # contaminate every diagnostic after it.
    for f in "$@"; do
      if [ ! -f "$MUT_ROOT/$f" ]; then
        check_note "[$label] pinned file is missing from the tree copy: $f"; check_fail; return
      fi
      mkdir -p "$MUT_BAK/$(dirname "$f")"
      if ! cp "$MUT_ROOT/$f" "$MUT_BAK/$f"; then
        check_note "[$label] could not stage a restore copy of $f"; check_fail; return
      fi
    done
    for f in "$@"; do
      # The LEADING newline is load-bearing: a file whose final line carries no terminator would
      # otherwise splice the witness onto it, and every `^`-anchored pattern would miss — the
      # harness would then report a broken pin that is in fact fine.
      printf '\n%s\n' "$w" >> "$MUT_ROOT/$f"
    done

    out="$( cd "$MUT_ROOT" && bash scripts/check-fact-drift.sh 2>&1 )"; rc=$?

    # Restore BEFORE asserting, so a failed assertion never leaves the copy dirty for the next
    # witness (which would then pass for the wrong reason) — and a restore that FAILS is fatal to
    # the run for exactly that reason: every later witness would trip this rule on the leftover
    # injection instead of its own, which is a FALSE GREEN.
    for f in "$@"; do
      if ! cp "$MUT_BAK/$f" "$MUT_ROOT/$f"; then
        check_note "[$label] could not restore $f in the tree copy — every later result would be untrustworthy"
        check_fail; return
      fi
    done

    # EXACTLY 1, and the two ways it can miss are different findings, reported differently.
    #
    # rc 0 is THE failure this mode exists to catch: the superseded spelling is sitting in every
    # pinned file and the lint says PASS. Folding it into a generic "want 1" would describe the
    # single most likely real defect as though the harness had crashed.
    if [ "$rc" -eq 0 ]; then
      check_note "[$label] injected [$w] into every pinned file and the lint stayed GREEN — this pin cannot fire"
      for f in "$@"; do check_note "    injected into: $f"; done
      check_fail; continue
    fi
    # Any OTHER non-zero is a broken harness, not a verdict: a syntax error, a missing dependency,
    # a corrupt copy. Accepting "any non-zero" would let those green-light a proof of nothing.
    if [ "$rc" -ne 1 ]; then
      check_note "[$label] injecting [$w] left the lint at rc=$rc — a crash or broken copy, not a drift verdict (want 1):"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      check_fail; continue
    fi
    # ...and it must be THIS rule reporting THIS file. A neighbouring rule going red would
    # otherwise satisfy the exit-code check while this pin stayed as unfirable as it ever was.
    for f in "$@"; do
      want="[$label] superseded pattern /$needle/ still present in $f:"
      case "$out" in
        *"$want"*) ;;
        *) check_note "[$label] injecting [$w] into $f did NOT trip the rule — this pin cannot fire"
           check_fail ;;
      esac
    done
  done <<EOF
$wits
EOF
}

# --- the throwaway tree copy (--mutation only) -------------------------------
# Through check-lib.sh's shared copier, which copies UNCOMMITTED sources — so adding a pin and
# running this locally tests the pin you just wrote, not the one at HEAD.
if [ "$MODE" = mutation ]; then
  MUT_WORK="$(mktemp -d)" || { echo "fact-mutation: cannot create a temp dir" >&2; exit 1; }
  trap 'rm -rf "$MUT_WORK"' EXIT
  MUT_ROOT="$MUT_WORK/repo"; MUT_BAK="$MUT_WORK/pristine"
  mkdir -p "$MUT_BAK"
  check_copy_worktree . "$MUT_ROOT" || { echo "fact-mutation: could not copy the working tree" >&2; exit 1; }
  # The baseline has to be clean before anything is injected. Without this, a working tree that is
  # ALREADY red would make every mutation "fail the lint" for a reason that has nothing to do with
  # the witness, and the whole mode would report success while proving nothing.
  if ! ( cd "$MUT_ROOT" && bash scripts/check-fact-drift.sh >/dev/null 2>&1 ); then
    echo "fact-mutation: the PRISTINE tree copy does not pass the lint — fix fact-drift first;" >&2
    echo "               until it is green a mutation proves nothing." >&2
    exit 1
  fi
fi

# --- FACT: gate axes ---------------------------------------------------------
# Canonical source: the _adb_emit <axis> calls in the gate detector. Every doc that
# enumerates the gate list must mention every axis, so adding an axis to the code
# without documenting it fails here.
axes="$(grep -oE '_adb_emit [a-z]+' scripts/lib/project-gates.sh | awk '{print $2}')"
[ -n "$axes" ] || { check_note "[gate-axes] could not derive axes from scripts/lib/project-gates.sh"; check_fail; }
for a in $axes; do
  fact gate-axes "fixed:$a" -- docs/per-project-overrides.md docs/roles-and-agents.md templates/agents.toml
done

# --- FACT: cross-agent invocations -------------------------------------------
# Canonical home: base/roles.md's cross-agent table. Each invocation is checked in
# every doc that restates THAT agent's entrypoint (incl. the hand-written per-agent
# READMEs, which are otherwise a silent drift surface).
# scripts/lib/role-dispatch.sh is the runtime EMBODIMENT of this table (issue #15): it necessarily
# restates each agent's CLI to invoke it, so it is pinned here alongside the prose consumers — a
# command changed in base/roles.md must change in the helper too, or this lint fails.
fact invocation-codex fixed:'codex exec --cd' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md \
  scripts/lib/role-dispatch.sh
fact invocation-gemini fixed:'agy -p' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/gemini/README.md \
  scripts/lib/role-dispatch.sh
fact invocation-claude fixed:'claude -p' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md \
  scripts/lib/role-dispatch.sh

# --- FACT: the dispatch hang backstop (#93) ----------------------------------
# Canonical source: _ADB_RD_TIMEOUT_SECS in scripts/lib/role-dispatch.sh. The bound is 45 minutes
# (2700 s) and is a HANG BACKSTOP, not a work budget — it stops a wedged process and otherwise
# stays out of the way. Every doc that states the bound must carry the figure, the seconds value,
# the override's name (so the knob stays discoverable rather than buried in the library), and the
# backstop framing (so nobody re-tunes it down toward typical runtime, which is the regression).
# ONE list, used by BOTH directions below. Keeping the positive rules and the superseded sweep on
# separate lists is how the anti-drift lint grows its own drift: add a consumer to one list only,
# and that file gets checked for the new value but never swept for the retired one (or vice-versa)
# — precisely the half-updated state these rules exist to catch.
# The rendered skills are included so a typo'd render path fails loudly: an `absent:` rule is
# vacuously true on a file that does not exist, while `fixed:`/`regex:` report the bad path.
# CHANGELOG.md is deliberately absent: its entries record what shipped at the time, and rewriting
# shipped history to satisfy a lint would be a lie, not a fix.
_bs_all="base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md"
_bs_all="$_bs_all docs/design-principles.md agents/codex/config.toml.sample scripts/lib/role-dispatch.sh"
# docs/adding-an-agent.md is on the list because it TELLS A CONTRIBUTOR what to write about
# timeouts for a new agent. Omitting it let the guide keep directing people to "name the concrete
# minimum timeout" — i.e. to recreate the work-budget model this fact retires — while the sweep
# passed (bot review, PR #105). A doc that propagates a fact is a consumer of it.
_bs_all="$_bs_all docs/adding-an-agent.md"
for _a in claude codex gemini; do _bs_all="$_bs_all agents/$_a/skills/implement-issue/SKILL.md"; done
# The seconds value and the override name are only spelled out where the bound is *explained*, not
# in every file that merely mentions it — so these two keep a narrower list.
_bs_num="base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md"
_bs_num="$_bs_num scripts/lib/role-dispatch.sh"

# shellcheck disable=SC2086  # deliberate word-split of the space-separated file lists
{
fact backstop-45min   regex:'45[-[:space:]](min|minute)'  -- $_bs_all
fact backstop-framing fixed:'hang backstop'               -- $_bs_all
fact backstop-secs    regex:'2700'                        -- $_bs_num
fact backstop-env     fixed:'ADB_DISPATCH_TIMEOUT_SECS'   -- $_bs_num

# SUPERSEDED by the rules above (#93): the 420 s bound sat near typical runtime, so ordinary
# high-reasoning passes tripped it; and the `420000`-`600000` ms guidance taught every reader to
# cap the surrounding call at 10 minutes — a HARNESS artifact, not a property of codex.
#
# Each retired SPELLING gets its own witness, because that is the granularity at which this class
# of pin fails: a pattern that catches three of four spellings is green on the fourth, and nothing
# distinguishes that from clean. The comma form is in because prose writes "420,000 ms".
fact backstop-stale-ms   absent:'(4[28]0|600)[,]?000' \
  'fires:ADB_DISPATCH_TIMEOUT_MS=420000' 'fires:a 480000 ms ceiling' \
  'fires:timeout: 600000' 'fires:roughly 420,000 ms'                                    -- $_bs_all
fact backstop-stale-secs absent:'(^|[^0-9])420([^0-9]|$)' \
  'fires:bounded at 420 s' 'fires:420'                                                  -- $_bs_all
# The alternations here were BRACKETS — `[≥>]` and `3[–-]7` — until #213's witnesses were written
# against them. A bracket expression holding a multibyte character is matched BYTEWISE under a C
# locale, so `3[–-]7` could not match `3–7 min` there at all: a pin that fired on a UTF-8 dev box
# and silently did not on a C-locale runner. Alternation of the literal is locale-independent.
fact backstop-stale-7min absent:'((≥|>)=?[[:space:]]*7|least[[:space:]]*7|3(–|-)7)[[:space:]-]*min' \
  'fires:≥7-minute' 'fires:>7 min' 'fires:at least 7 min' \
  'fires:3–7 min' 'fires:3-7 min'                                                       -- $_bs_all
}

# --- FACT: gap_analysis never substitutes another agent (#93) ----------------
# The behavioural rule this change actually introduced, and the one an agent is most likely to
# quietly violate under time pressure — a silently-substituted reviewer is exactly what made
# `agents.toml` fiction for three runs. It was restated across six hand-written surfaces and
# pinned by nothing, while the *number* got seven rules. Pin the rule too.
# shellcheck disable=SC2086
fact gap-analysis-no-fallback fixed:'never substitut' -- \
  base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md agents/codex/README.md

# --- FACT: role-resolution order ---------------------------------------------
# The order is repo agents.toml → global default manifest → built-in default.
fact resolution-order fixed:'global default' -- base/roles.md docs/roles-and-agents.md scripts/lib/role-dispatch.sh
fact resolution-order fixed:'built-in'       -- base/roles.md docs/roles-and-agents.md scripts/lib/role-dispatch.sh

# --- FACT: cleanup origin/HEAD symref filter (#38) ---------------------------
# The remote-enumeration pipeline that drops the bare `origin` symref lives in the workflow
# doc AND is re-asserted by its regression test — which can only re-implement, not source, a
# pipeline that lives inside a markdown fence. Pin the critical fragment so editing the doc's
# pipeline without updating the test (or vice-versa) fails CI instead of silently drifting.
fact cleanup-origin-symref "fixed:grep '^origin/'" -- \
  base/workflows/cleanup.md scripts/check-cleanup-enum.sh

# --- FACT: the gap-analysis in-flight lock filename (#84) --------------------
# A cross-skill contract: /implement-issue TAKES and RELEASES the lock around its gap dispatch,
# and /cleanup's state-scan RECOGNISES it (so a live pass's artifacts are never swept mid-write).
# The two sides only meet on this literal filename, and a rename that misses one side fails
# SILENTLY in the destructive direction — cleanup reads "no dispatch in flight" and deletes the
# findings the dispatch is still writing. Pin the string so a rename must change both together.
fact gap-analysis-lock fixed:'gap-analysis.lock' -- \
  scripts/lib/cleanup-lib.sh base/workflows/implement-issue.md

# --- FACT: default async-bot reviewer allowlist (#26) ------------------------
# adb_dispatch_bots() in role-dispatch.sh is the source of the default bot logins; the
# resolve-pr-threads workflow re-lists them in prose for the reader. Pin each login so the prose
# can't silently drift from the code default (grep -F, so the [bot] brackets are literal).
for bot in chatgpt-codex-connector 'gemini-code-assist[bot]' gemini-code-assist \
           'copilot-pull-request-reviewer[bot]' 'copilot[bot]' 'github-actions[bot]' \
           'claude[bot]' 'claude-code[bot]'; do
  fact reviewer-bots-default "fixed:$bot" -- \
    scripts/lib/role-dispatch.sh base/workflows/resolve-pr-threads.md
done

# --- FACT: release-goal convention label string (#27/#71) --------------------
# The `release-blocker` label is load-bearing across three surfaces that MUST agree: the setup
# helper CREATES it, the /roadmap workflow QUERIES it for the readiness predicate/gauge, and the
# module doc DOCUMENTS it. A rename in one place that misses the others silently breaks readiness.
# Pin the exact string (grep -F) so any divergence fails CI. (The milestone NAMES are deliberately
# NOT pinned into the generic shared law — issues-and-scope.md stays convention-agnostic, #27.)
fact release-blocker-label "fixed:release-blocker" -- \
  docs/release-goal-convention.md base/workflows/roadmap.md scripts/lib/release-convention.sh

# --- FACT: the auto-merge guard subcommand (#87) -----------------------------
# `automerge-ok` is the contract between the library that IMPLEMENTS the guard, the workflow step
# that CALLS it before arming auto-merge, and the doc that DOCUMENTS its exit codes. Renaming the
# subcommand in the library alone would leave the workflow calling a subcommand that no longer
# exists — and since a failed guard call is treated as "do not arm", the failure mode is silent:
# auto-merge simply stops being armed and nobody notices. Pin the exact token.
fact automerge-guard "fixed:automerge-ok" -- \
  scripts/lib/repo-settings.sh base/workflows/implement-issue.md docs/repo-settings.md

# --- FACT: the required-check drift lint (#122) ------------------------------
# The same three-surface contract, with one twist that makes the pin matter more than usual: this
# check exists to catch a gate that silently stopped gating, so an unpinned version reproduces
# #122's own failure class one level up. The library IMPLEMENTS `required-drift`, the CI job CALLS
# it, and the doc DOCUMENTS its exit codes. Deleting the step from ci.yml is invisible to every
# other check in this repo — nothing else greps the workflow for it — so pin the call site too,
# not just the token.
fact required-drift-lint "fixed:required-drift" -- \
  scripts/lib/repo-settings.sh docs/repo-settings.md
fact required-drift-wired "fixed:repo-settings.sh required-drift" -- \
  .github/workflows/ci.yml

# --- FACT: the pre-arm review guard subcommand (#134) ------------------------
# Identical contract shape, and identically silent when it breaks: the library IMPLEMENTS
# `gate`, the workflow CALLS it before arming, and the doc DOCUMENTS its exit codes. Because a
# failed guard call is treated as "do not arm", a rename in the library alone would silently stop
# auto-merge being armed — the same invisible failure mode `automerge-guard` above exists to
# prevent, so it gets the same pin rather than relying on the structural greps in
# scripts/check-pr-review.sh (which pin the WIRING, not the token).
fact pr-review-guard "fixed:{{PR_REVIEW_LIB}} gate" -- \
  base/workflows/implement-issue.md

# --- FACT: the observe-and-render subcommand (#138) --------------------------
# The worst failure shape of the four. The library IMPLEMENTS `observe` and all three narrating
# workflows CALL it to render a status line. Rename it in the library alone and every call exits 2
# with EMPTY stdout — which the workflows explicitly instruct the agent to read as "say nothing
# about this entity". The mechanism goes permanently inert and reports nothing at all, so nothing
# surfaces the breakage. Pin the exact token across every CALLER (the library spells the
# subcommand as a bare `observe)` case arm, which carries no placeholder to pin; its own rename is
# caught loudly by scripts/check-state-assert.sh instead).
fact state-assert-observe "fixed:{{STATE_ASSERT_LIB}} observe" -- \
  base/workflows/cleanup.md base/workflows/implement-issue.md \
  base/workflows/resolve-pr-threads.md

# --- FACT: the close-out must not predict a future gate effect (#134, #138) --
# The RETIRED phrasing, pinned with `absent:` rather than pinning the corrected sentence. Grepping
# for the correction pins an English sentence: a reflow across the wrap column fails CI with zero
# behavior change, and a freshly-added prediction two lines away leaves the grep green. Pinning
# what must NOT come back survives reformatting and catches the actual regression.
fact no-arm-prediction "absent:will wait on" \
  'fires:the armed PR will wait on its unresolved threads' -- \
  base/workflows/implement-issue.md

# --- FACT: the branch-health predicate subcommand (#78) ----------------------
# Same contract shape as `automerge-ok` above: the library IMPLEMENTS the green-branch predicate,
# the workflow CALLS it before emitting a cut, and two docs DOCUMENT its verdicts. A rename in the
# library alone would leave the workflow invoking a subcommand that no longer exists — and because
# `/roadmap` hard-stops on a failed health read, the failure is loud but the DOCS would silently
# keep describing a predicate nobody can run. Pin the exact token across all four.
# The practice joined this list in #138: its "one home per entity kind" routing table names the
# predicate, and that table renders into EVERY agent's root doc — so a rename that missed it would
# leave the most-read document in the baseline naming a subcommand nobody can run.
fact branch-health-predicate "fixed:branch-health" -- \
  scripts/lib/roadmap-lib.sh base/workflows/roadmap.md \
  docs/release-goal-convention.md docs/roadmap-acceptance.md \
  base/practices/verify-before-asserting.md

# --- FACT: the GitHub Actions app slug (#179) --------------------------------
# `app.slug` is `github-actions`. The app's OWNER login is `github`, and BOTH consumers shipped
# attributing against that near-miss: `branch-health` could then never return `green` on an Actions
# repo (deadlocking the release cut) and `required-drift`'s provenance check silently matched
# nothing (fail-open). `adb_actions_app_slug` in common.sh is now the one home.
#
# Both directions are pinned, which is the whole reason `absent:` exists. Positive presence alone
# would pass a file that calls the accessor AND keeps a hard-coded copy beside it — precisely the
# state this fix removes. The negative pattern is anchored to a NON-comment line, because both
# libraries quote the retired literal in prose to explain the bug.
#
# base/workflows/roadmap.md restates the value deliberately: it is prose an agent pastes into a
# shell, so it can carry a value but never source a library. That is why it is pinned here rather
# than deduplicated away.
fact actions-slug-value  "fixed:github-actions" -- \
  scripts/lib/common.sh base/workflows/roadmap.md
fact actions-slug-home   "fixed:adb_actions_app_slug" -- \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh
# The witness is the BRACKETED test, not a bare `slug == "github"` — and that is not a stylistic
# choice. `[^#[:space:]]` consumes the line's first non-blank character, so the `(slug|aslug)`
# group has to match somewhere AFTER it; a line that starts with the word `slug` therefore does not
# match its own pin. The real superseded line was a shell test, which is what this witness is.
fact actions-slug-stale  'absent:^[[:space:]]*[^#[:space:]].*(slug|aslug)[^=]*== *"github"' \
  'fires:  [ "$slug" == "github" ] && provenance=trusted' -- \
  scripts/lib/common.sh scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh \
  base/workflows/roadmap.md

# --- FACT: the branch-merge verdict subcommand (#106, #138) ------------------
# Same routing table, second entry. Previously pinned only by a structural grep in
# scripts/check-cleanup.sh; the practice is now a second restatement site, so the token gets a
# real pin across the library that implements it and both documents that name it.
fact branch-verdict-predicate "fixed:branch-verdict" -- \
  scripts/lib/cleanup-lib.sh base/workflows/cleanup.md \
  base/practices/verify-before-asserting.md
# The order these two settings are written in is the whole safety property (#87): required checks
# FIRST, then allow_auto_merge. Pin the setting name across the library that writes it, the doc
# that explains the order, and the workflow step that depends on it having been done.
fact allow-auto-merge "fixed:allow_auto_merge" -- \
  scripts/lib/repo-settings.sh docs/repo-settings.md

# --- FACT: the install-currency config surface (#36, #139) -------------------
# The mode key is a multi-way contract: the TEMPLATE advertises it, currency-lib.sh is the one
# thing that READS it, both triggers (the Claude SessionStart hook and the /cleanup step) are
# governed by it, and the DOC + decision log tell the operator it is global-only. Renaming the
# table or the key in one place would leave the others describing a knob that silently does
# nothing — and "silently does nothing" is precisely the failure this feature exists to remove.
#
# The key is still spelled `session_start` even though #139 gave it a second, non-session trigger.
# That is deliberate backward compatibility: an `off` that stopped applying would re-enable an
# updater its owner had switched off. The neutral rename is tracked in #140.
fact session-start-config "fixed:session_start" -- \
  templates/agents.toml scripts/lib/currency-lib.sh \
  agents/claude/scripts/session-currency.sh base/workflows/cleanup.md \
  docs/installation.md .ai-dev-baseline/decisions.md
# The event this hook binds to. The settings entry, the script's own source gate, and the docs
# must name the SAME trigger: a matcher the script did not also enforce would let a `/clear` or
# a `compact` swap tooling mid-session.
fact session-start-source "fixed:startup" -- \
  agents/claude/settings.hooks.json agents/claude/scripts/session-currency.sh docs/installation.md

# --- FACT: the currency outcome vocabulary (#139) -----------------------------
# currency-lib.sh's `check` returns `<outcome><TAB><message>` and leaves PRESENTATION to the caller,
# because the two triggers legitimately disagree about what deserves attention. That split is only
# safe while the caller's tokens match the ones the library actually emits — and the coupling is
# invisible: rename an outcome in the library and the Claude hook's `case` silently stops matching,
# which costs the `reloadSkills` on an update (a repaired skill stays unavailable for the session)
# or turns the deliberate silence on `busy`/`offline` into a nagging line at every session start.
# Nothing else pins it: the executing tests only assert the outcomes that exist today.
#
# Only the four tokens a caller BRANCHES on are pinned. The workflow step deliberately branches on
# none of them (it keys on message-emptiness), so it is not a consumer of this fact.
#
# Pinned at the CONSTRUCTS, not as bare words. A plain presence check is useless here: every one of
# these tokens also appears in this library's own header, which documents the vocabulary — so
# renaming an emit site while leaving the docs intact would pass a `fixed:` rule. Verified: a
# `fixed:busy` rule did NOT catch `_adb_cu_emit busy` → `_adb_cu_emit occupied`. Anchor on the
# emitter call in the library and on the `case` arm in the hook, which are the two things that must
# agree.
for _o in updated repaired busy offline; do
  fact currency-outcomes "regex:_adb_cu_emit +$_o" -- scripts/lib/currency-lib.sh
done
fact currency-outcomes regex:'updated\|repaired\)' -- agents/claude/scripts/session-currency.sh
fact currency-outcomes regex:'busy\|offline\)'     -- agents/claude/scripts/session-currency.sh

# --- FACT: run-marker ownership (#180) ---------------------------------------
# The marker's `owner` only works because the WRITER and the READER name the same session id. The
# writer is prose an agent executes (`base/workflows/implement-issue.md`); the reader is the Stop
# hook. Nothing else couples them: rename the variable on one side and the field keeps being
# written, keeps being read as empty, and the gate silently reverts to matching every session in
# the checkout — the exact defect this shipped to fix, back with no test failing. The rendered
# skills are pinned too, so a render that drops the writer fails loudly rather than quietly
# shipping an agent that never stamps an owner.
#
# EXPECTED TO CHANGE at #14/#25. Pinning a Claude env-var name in the Codex/Gemini renders is only
# right while `owner` has no reader outside Claude; once those agents get their own enforcement
# hook the writer becomes a placeholder and this rule must narrow to the Claude render. A failure
# here at that point is this tripwire working — see base/workflows/README.md's carve-out list.
_own_all="base/workflows/implement-issue.md agents/claude/scripts/implement-issue-gate.sh"
for _a in claude codex gemini; do _own_all="$_own_all agents/$_a/skills/implement-issue/SKILL.md"; done
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
fact marker-owner-env fixed:'CLAUDE_CODE_SESSION_ID' -- $_own_all
# The field NAME, pinned at the read. Renaming `owner` in the workflow while the hook keeps
# reading `.owner` leaves both halves working and the comparison permanently empty.
fact marker-owner-field fixed:'.owner // ""' -- agents/claude/scripts/implement-issue-gate.sh
# Deliberately NOT pinned here: the absent-owner direction (fall back to enforcement, never inert).
# It is a DIRECTION, not a token, and a word-presence rule over prose is the "general prose
# blocklist" this lint's header warns against. `scripts/check-implement-gate.sh` cases N and O
# assert it against the real gate, which is the stronger guard.

# --- FACT: the PR-argument and reviewer-identity primitives have ONE home (#173) -------------
# The two PR guards each carried private copies of four primitives, and the copies DIVERGED into a
# live fail-open: pr-review.sh's slug parser handled only `scheme://…`, so a scheme-less
# `github.com/other/repo/pull/7` produced an empty slug, skipped the cross-repo refusal, and let the
# arming guard print a head SHA for a pull request the operator never named.
#
# Both directions are pinned, because neither half is sufficient. The POSITIVE rules prove each guard
# still routes through the shared primitive — a library can be perfectly correct while a caller quietly
# stops calling it, which is the state #134 itself described. The `absent:` rules prove no copy came
# back; presence alone cannot catch a file that calls the shared function AND keeps a local definition
# beside it, which is exactly how the divergence above survived. This is the narrow, superseded-value
# use `absent:` exists for, not a general prose blocklist.
_prguards="scripts/lib/pr-review.sh scripts/lib/pr-watch.sh"
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _fn in adb_pr_number adb_pr_slug_check; do
  fact pr-primitives-shared "fixed:$_fn" -- $_prguards
done
# `adb_reviewer_match_jq` is DELIBERATELY NOT PINNED HERE any more. Both guards stopped pasting the
# identity predicate in front of their own jq passes when #167 moved evidence SELECTION into
# `adb_reviewer_evidence`, which prepends it once — so a pin at the guards would demand a call that
# correctly no longer exists. Pinning it at `common.sh` instead was worse than nothing: that file
# both defines and calls it, so the rule could only fail if the function were deleted outright,
# which `check-common-lib.sh`'s direct matrix already catches. A pin that cannot fail is the shape
# this lint's own header warns about.

# --- FACT: ONE reviewer-evidence classifier and ONE head anchor, for BOTH guards (#167) ----------
# The two guards answer different FINAL questions, so they must not share a verdict — but they were
# answering the SAME underlying question ("given everything this reviewer emitted, has this head
# been reviewed, and was it clean?") in two places, and the two answers had already diverged:
# `APPROVED` meant *findings* in the watcher and *satisfied* in the arming guard, and the watcher
# pooled the declared set where the guard required all of it (#185).
#
# Both directions are pinned, because neither half is sufficient. The POSITIVE rules prove each
# guard still routes through the shared primitives — a library can be perfectly correct while a
# caller quietly stops calling it. The `absent:` rules prove no copy came back; presence alone
# cannot catch a file that calls the shared function AND keeps a local definition beside it, which
# is exactly how the #173 divergence survived.
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _fn in adb_reviewer_classes_for_pr adb_fold_reviewer_classes; do
  fact pr-classifier-shared "fixed:$_fn" -- $_prguards
done
# ...and the pipeline's own steps are pinned at the ONE place that now performs them. Pinning these
# at the guards is what would push a future edit back toward open-coding the pipeline in each of
# them, which is the duplication #167 removed at review time.
# shellcheck disable=SC2086
for _fn in adb_paginated_list adb_reviewer_evidence adb_reviewer_classes adb_head_anchor; do
  fact pr-classifier-shared "fixed:$_fn" -- scripts/lib/common.sh
done
# NO `absent:` RULE ON THE PIPELINE'S STEPS, deliberately. The tempting one — "no guard may name
# `adb_paginated_list` / `adb_reviewer_evidence`" — cannot be written as a bare token: both guards
# legitimately NAME them in the pointer comments that tell the next reader where the pipeline went,
# and this lint's own convention is to pin the DEFINITION form (`^name()`) precisely so those
# comments are not mistaken for the drift. There is no definition to pin here, because these were
# never defined in the guards. The positive `adb_reviewer_classes_for_pr` rule above is what proves
# each guard still routes through the shared pipeline, and a guard that re-open-coded the six steps
# would have to stop calling it to do so.
# The anchor was PRIVATE to pr-watch.sh, and D19 recorded its promotion as #167's first step rather
# than something to copy — precisely because `gate` returning 0 on a date-scoped signal is an armed
# merge, i.e. the same predicate at higher stakes. It is pinned in common.sh above; neither guard
# names it directly any more, because the pipeline function decides when it is consulted.
# NO COPY SURVIVES, pinned as the DEFINITION form (`^name()`) so the pointer comments each guard
# keeps — telling the next reader where these went and not to re-inline them — are not themselves
# the drift this rule hunts.
#
# The loop iterates over the NAME and derives both the pattern and its witness from it, so the two
# cannot drift apart: a rule hunting `^foo\(\)` while witnessed by `bar() {` would prove nothing
# about `foo`, and a hand-written witness list is exactly where that mistake lives.
# shellcheck disable=SC2086
for _gone in head_anchor is_utc_instant read_list; do
  fact pr-classifier-no-copies "absent:^$_gone\\(\\)" "fires:$_gone() {" -- $_prguards
done
# The far-future staleness sentinel has ONE spelling, in common.sh. A guard that re-inlines the
# literal is a guard that can be given a DIFFERENT one — and the failure mode of a wrong sentinel is
# silent: an empty or low value makes every signal read as fresh, which is the false-clean/false-arm
# direction this whole family exists to prevent.
# shellcheck disable=SC2086
fact pr-classifier-no-copies 'absent:9999-12-31' \
  'fires:_far_future="9999-12-31T00:00:00Z"' -- $_prguards
# The declaration normalizer is reached through role-dispatch's CLI, so the pinned token is the
# subcommand rather than the function name. The two docs that name WHICH reader the merge gate uses are
# pinned with it: they described `--declared` (the tri-state reader this one wraps) for a while after
# the guards had moved, and a doc naming the wrong reader is exactly the drift this lint exists for.
# shellcheck disable=SC2086
fact pr-primitives-shared fixed:'bots --comparable' -- \
  $_prguards scripts/lib/role-dispatch.sh base/roles.md docs/roles-and-agents.md
# The git-origin anchor. state-assert.sh (#138) had the only copy until the guards needed the same
# defence against the same `GH_REPO` override; the guards reach it through adb_pr_slug_check, so its
# consumers are the library that defines it and the module that calls it directly.
fact pr-primitives-shared fixed:'adb_git_origin_slug' -- \
  scripts/lib/common.sh scripts/lib/state-assert.sh
# NO COPY SURVIVES. Pinned as the DEFINITION form (`^name()`), so the pointer comments in each guard
# that name the retired primitives — telling the next reader where they went and not to re-inline
# them — are not themselves the drift this rule hunts.
# shellcheck disable=SC2086  # deliberate word-split of the space-separated file list
for _gone in parse_pr_arg parse_pr_slug; do
  fact pr-primitives-no-copies "absent:^$_gone\\(\\)" "fires:$_gone() {" -- $_prguards
done
# The reviewer-identity half, pinned as the STRIP IDIOM rather than a function name: the suffix is
# now handled only on the API side, inside common.sh's shared jq def, so an ANCHORED `[bot]` match
# anywhere in a guard means the rule has been re-inlined. The DIRECTION of such a copy is the entire
# defect (#176): stripping the declaration too let a human account named `foo` satisfy a declared
# `foo[bot]`.
#
# The `\\*` is load-bearing and this rule was WRONG without it, which a negative test caught: the two
# real idioms are `sed 's/\[bot\]$//'` and jq's `sub("\\[bot\\]$"; "")`, so the bracket is always
# BACKSLASH-ESCAPED and a pattern for a contiguous `[bot]$` matches neither. It passed by matching
# nothing at all — a pin that cannot fire, which is worse than no pin. `bot\\*\]\$` accepts any number
# of escaping backslashes before the closing bracket and so catches both spellings.
#
# BOTH spellings are witnessed, and that is the whole point: this pin's predecessor caught neither,
# so a single witness would have re-created the original defect one spelling narrower.
# shellcheck disable=SC2086
fact pr-primitives-no-copies 'absent:bot\\*\]\$' \
  'fires:s/\[bot\]$//' 'fires:sub("\\[bot\\]$"; "")' -- $_prguards
# ...and the private anchor is gone from its old home rather than shadowing the promoted one.
fact pr-primitives-no-copies 'absent:^_sa_local_slug\(\)' \
  'fires:_sa_local_slug() {' -- scripts/lib/state-assert.sh

# --- FACT: the negative-test wiring, pinned against silent removal (#213) ----
# Same contract shape as `required-drift-wired` above, and the same silent failure: deleting
# either invocation from selfcheck.sh or ci.yml removes the protection while the `fact-drift`
# CHECK CONTEXT stays green, so branch protection notices nothing and no other check greps for
# them. A guard that can be un-wired invisibly is the guard this whole file is about.
fact fact-mutation-wired "fixed:check-fact-drift.sh --mutation" -- \
  scripts/selfcheck.sh .github/workflows/ci.yml
fact fact-guard-wired "fixed:check-fact-guard.sh" -- \
  scripts/selfcheck.sh .github/workflows/ci.yml

# --- what was actually evaluated ---------------------------------------------
# A rule that scans nothing is already a hard failure inside fact(); these totals are the other
# half of the same idea, and the half that survives a future edit fact() does not model. Zero rules
# — a truncated file, a sourcing accident, an early `exit` — would otherwise be the quietest
# possible green, and zero ABSENT rules would mean the negative half of this lint had evaporated.
if [ "$FACT_RULES" -eq 0 ]; then
  check_note "no rules were evaluated at all — this lint asserted nothing"; check_fail
fi
if [ "$FACT_ABSENT_RULES" -eq 0 ]; then
  check_note "no absent: rules were evaluated — the superseded-value half of this lint is gone"; check_fail
fi

if [ "$MODE" = mutation ]; then
  # The witness contract lives in fact(). A DIRECT req_absent caller sidesteps it and reintroduces
  # exactly the unwitnessed negative pin this mode exists to prevent, so the family is closed by
  # asserting there IS no other caller — the generic answer to "same for req_absent generally".
  # Comment lines are excluded: two suites legitimately mention the helper in prose.
  # Enumerated with `find`, NOT `git ls-files`. This invariant is itself a guard whose failure
  # mode is silence, and `git ls-files` fails outright wherever there is no `.git` — a tarball
  # export, an unpacked release, or any tree copy. It would then produce an empty list, find no
  # stray caller, and pass: a check that goes inert exactly where nobody would notice.
  #
  # PER-LINE exemption, never per-file. Excluding whole files (check-lib.sh defines the helper,
  # this file dispatches to it, check-fact-guard.sh writes stray callers into fixtures) made the
  # invariant FALSE: a real direct call added to any of those three would pass undetected, which
  # a reviewer reproduced. A sanctioned line instead carries the marker below, so every occurrence
  # is deliberate and reviewable, and a NEW call anywhere — including in these three files — has
  # to be marked before it is accepted.
  #
  # `*.sh` is not the file set either: `bin/agent-init` and `bin/baseline` are shell programs with
  # no extension, and a direct call in one of them was likewise invisible. Anything with a shell
  # shebang counts, which also covers scripts nobody has written yet.
  #
  # Accumulated in the CURRENT shell rather than a `$(… | while …)` pipeline: a `case` arm's
  # closing `)` inside a command substitution is read as the substitution's own, which bash
  # reports as a syntax error twenty lines away from the cause.
  # The token and its marker are named ONCE here — where the marker itself sits — so the scanning
  # line below does not spell the token and therefore does not need its own exemption. A marker
  # cannot ride a line-continuation anyway: the check is per LINE, and a trailing `#` comment on
  # the first half of a `\`-continued pipeline is a syntax error.
  _ra='req_absent'; _allow="adb-allow: $_ra"   # adb-allow: req_absent
  _stray=""; _sf=""; _hit=""; _nscanned=0
  while IFS= read -r _sf; do
    [ -n "$_sf" ] || continue
    _sf="${_sf#./}"
    [ -f "$_sf" ] || continue
    case "$_sf" in
      *.sh) ;;
      *) head -n1 "$_sf" 2>/dev/null | grep -Eq '^#!.*(ba)?sh' || continue ;;
    esac
    _nscanned=$((_nscanned + 1))
    # THREE greps, and none of them is a clever single pattern.
    #   1. find the token — `^[[:space:]]*[^#[:space:]].*req_absent` LOOKS like it also excludes
    #      comments, but `[^#[:space:]]` CONSUMES the line's first non-blank character, so a line
    #      that BEGINS with the call (the ordinary way a stray caller is written) matches nothing
    #      at all. That match-nothing defect shipped here first and was caught by
    #      check-fact-guard.sh's stray-caller case.
    #   2. drop comment lines — suites legitimately discuss the helper in prose.
    #   3. drop lines carrying the sanctioned marker.
    _hit="$(grep -n "$_ra" "$_sf" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -Fv "$_allow")" || continue
    [ -n "$_hit" ] || continue
    _stray="${_stray}$(printf '%s\n' "$_hit" | sed "s@^@$_sf:@")${_FACT_NL}"
  done <<EOF
$(find . -type f ! -path './.git/*')
EOF
  # Zero files scanned means the enumeration broke, not that the tree is clean.
  if [ "$_nscanned" -eq 0 ]; then
    check_note "the call-site scan found no shell files at all — the enumeration is broken"  # adb-allow: req_absent
    check_fail
  fi
  if [ -n "$_stray" ]; then
    check_note "the helper is called outside fact(), which bypasses the fires: witness contract:"
    printf '%s\n' "$_stray" | sed 's/^/    /' >&2
    check_fail
  fi

  printf 'fact-mutation: %d absent rules · %d witnesses injected into a throwaway tree copy · %d pinned files\n' \
    "$FACT_ABSENT_RULES" "$FACT_WITNESSES" "$FACT_ABSENT_FILES"
  check_result "every absent: pin was observed failing under its own superseded spellings"
else
  printf 'fact-drift: %d rules · %d rule-file assertions · %d absent rules (%d files scanned, %d witnesses verified)\n' \
    "$FACT_RULES" "$FACT_ASSERTS" "$FACT_ABSENT_RULES" "$FACT_ABSENT_FILES" "$FACT_WITNESSES"
  check_result "canonical facts consistent across their consumers"
fi
