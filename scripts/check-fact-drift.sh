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
# It also carries ONE invariant that is not a fact at all: the release-role policy (#3/D7), whose
# absence half asserts that certain PATHS do not exist. It moved here from `check-release-role.sh`
# with #375 because three of that file's five groups were already this grammar and the fourth — the
# `roll` boundary — needed the `fires:`/`--mutation` proof only this file can give it. Its own
# banner is at the bottom, deliberately not scattered through the rules.
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
# And the two guard rails above are THEMSELVES guards, so `--self-test` drives each of them against a
# deliberately broken rule and requires it to go red (#377). It was a standalone `check-fact-guard.sh`
# until then; the technique it used — splice ONE synthetic rule between this file's own `# --- FACT:`
# markers, into a COPY of the tree, and run the real lint there — is the same copy-and-mutate scaffold
# `--mutation` already implements a few lines below, so the two now share one home and one preamble.
# What must NOT be inferred from that fold is that every guard suite should follow it:
# `check-bash-floor-guard.sh` drags 5.3-only fixture code and its subject must stay parseable under
# bash 3.2 (D30/D35), and `check-selfcheck.sh` folded into `selfcheck.sh` would recurse. #377 is
# deliberately the one clean fold, not a precedent for the rest.
#
# Usage:
#   bash scripts/check-fact-drift.sh              # exit 0 = no drift, 1 = drift found
#   bash scripts/check-fact-drift.sh --mutation   # exit 0 = every absent: pin was seen going RED
#   bash scripts/check-fact-drift.sh --self-test  # exit 0 = every guard rail was seen going RED

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
# The release-role section at the bottom detects a rendered release skill with a GLOB, so pathname
# expansion must be ON (#375). A caller with `set -f` (noglob) would leave the pattern literal,
# matching nothing, and the absence check would pass while a real skill sat in the tree — a false
# GREEN, the one failure mode a policy lint must never have. Force it on rather than trusting the
# invoking shell.
set +f
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh

MODE=normal
case "${1:-}" in
  "")          ;;
  --mutation)  MODE=mutation ;;
  --self-test) MODE=selftest ;;
  *) echo "usage: check-fact-drift.sh [--mutation | --self-test]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "usage: check-fact-drift.sh [--mutation | --self-test]" >&2; exit 2; fi
case "$MODE" in
  mutation) check_init "fact-mutation" ;;
  selftest) check_init "fact-self-test" ;;
  *)        check_init "fact-drift" ;;
esac

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
  local label spec kind needle w f nfiles
  local -a wits=()
  local -A seen=()
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

  # Witnesses accumulate into an array. They were a newline-delimited STRING because expanding an
  # empty array under `set -u` was an unbound-variable error on bash 3.2; the floor is 5.3 (#256),
  # where `"${wits[@]}"` on an empty array is simply empty. The rejection below stays regardless:
  # `grep` is line-oriented, so a witness that spans lines can never match one.
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
        wits+=("$w") ;;
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
  #
  # A `declare -A` membership test rather than the quadratic self-join it replaces — the same
  # bash 3.2 gap that shaped the witness accumulation above shaped this too.
  for f in "$@"; do
    if [ -n "${seen[$f]+set}" ]; then
      check_note "[$label] file listed more than once: $f"; check_fail; return
    fi
    seen["$f"]=1
  done

  if [ "$kind" = absent ]; then
    if [ "${#wits[@]}" -eq 0 ]; then
      check_note "[$label] absent: rule declares no fires: witness — see this file's header (#213)"
      check_fail; return
    fi
    # THE CHEAP HALF OF THE PROOF, run on every invocation: a pattern that cannot match the real
    # spelling it retires is unfirable, and that is knowable without touching a single file.
    for w in "${wits[@]}"; do
      if ! printf '%s\n' "$w" | grep -Eq -- "$needle"; then
        check_note "[$label] UNFIRABLE PIN: /$needle/ does not match its own witness [$w]"
        check_fail; return
      fi
      FACT_WITNESSES=$((FACT_WITNESSES + 1))
    done
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
  elif [ "${#wits[@]}" -ne 0 ]; then
    check_note "[$label] fires: is only meaningful on an absent: rule"; check_fail; return
  fi

  FACT_RULES=$((FACT_RULES + 1))
  FACT_ASSERTS=$((FACT_ASSERTS + $#))

  if [ "$MODE" = mutation ]; then
    if [ "$kind" = absent ]; then _fact_mutate "$label" "$needle" "${#wits[@]}" "${wits[@]}" "$@"; fi
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

# _fact_mutate <label> <pattern> <n-witnesses> <witness>×n <file> [<file>…]
#
# COUNT-PREFIXED rather than newline-joined. Two variadic lists cannot share one argument vector
# without a boundary, and the count is the boundary that a witness containing any character
# whatsoever cannot forge — which a delimiter can.
# The expensive half of the proof, and the reason `--mutation` exists at all: inject each witness
# into a COPY of every pinned file, re-run the REAL lint there, and require the drift verdict.
#
# ONE run per WITNESS, all of that rule's files mutated together. Per-file runs would cost N times
# as much for nothing (req_absent accumulates every file's failure in one pass), but folding
# several witnesses into a single run would let a working witness cover for a broken one.
_fact_mutate() {
  local label="$1" needle="$2" nw="$3"; shift 3
  local -a wits=("${@:1:nw}"); shift "$nw"    # what is left in "$@" is the file list
  local w f out rc want
  for w in "${wits[@]}"; do
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
  done
}

# =============================== the self-test (--self-test only) ==============================
#
# WHY THIS IS HERE AT ALL. The `fires:` witness contract inside `fact()` and the `--mutation` harness
# above both exist to stop a check passing while checking nothing. Both are guards, and a guard's
# failure mode is SILENCE — it reports exactly what a clean run reports — so shipping them without
# watching them fail would reproduce, one level up, the defect they were written to remove.
# `base/practices/self-review.md` states the rule: a new guard is not done until it has been observed
# failing.
#
# HOW IT TESTS. Every case runs against a THROWAWAY COPY of the working tree; the live tree is never
# touched. That is the other half of #213 — negative-testing the last pin by editing
# `scripts/lib/pr-review.sh` in place and "restoring" it with `git checkout` destroyed ~40 minutes of
# uncommitted work, which no reflog could recover. The method is in the same practice file.
#
# Most cases replace the real rule set with ONE synthetic rule, spliced between this file's own
# `# --- FACT:` and `# --- what was actually evaluated` markers. That keeps each case readable — the
# rule under test is right there in the case — and keeps `--mutation` cases to a single sub-lint
# instead of the whole set. The real rules are exercised for real by the two other modes in
# selfcheck; this mode is about the machinery around them.
#
# THIS SECTION MUST STAY ABOVE THE FIRST `# --- FACT:` MARKER. `_st_minimal` slices everything
# between the markers out of the copy, so a case that lived below the first one would delete itself
# from the fixture it is running. Nothing here may open a line with that marker either, for the same
# reason: the slicer takes the FIRST match.
#
# The headline case is `historic-bot-pin`: the EXACT pattern that shipped unable to fire
# (`absent:\[bot\]\$`) against the EXACT idiom it was meant to catch. It must be reported UNFIRABLE,
# and its corrected form must be accepted — the regression test for #213 itself.
if [ "$MODE" = selftest ]; then
  ST_WORK="$(mktemp -d)" || { echo "fact-self-test: cannot create a temp dir" >&2; exit 1; }
  # ONE exit trap, doing both jobs: fail closed if this suite ends without running its summary, then
  # clean up. Without the first half the suite fails OPEN — its exit status is its last command's,
  # and only check_summary ever consults the `fail` counter, so a truncating edit or a stray early
  # `exit` prints FAIL lines and still exits 0, and selfcheck and CI report the step as passing.
  # A suite whose entire job is proving guards can fail must not be able to skip its own verdict.
  check_exit_guard "fact-self-test" "rm -rf \"$ST_WORK\""

  # ONE copy of the working tree, cloned per case, through check-lib.sh's shared copier. It copies
  # UNCOMMITTED sources — so this mode tests the lint you just edited, not the one at HEAD.
  ST_PRISTINE="$ST_WORK/pristine"
  check_copy_worktree "$ROOT" "$ST_PRISTINE" \
    || { echo "fact-self-test: could not copy the tree" >&2; exit 1; }

  # _st_fresh — print the path of a brand-new copy of the pristine tree.
  #
  # The unique name comes from `mktemp -d`, NOT from a counter, and it STAYS that way even though the
  # containment argument has expired (#259). Call sites are `d="${ _st_fresh; }"` now, which runs in
  # the CURRENT shell, so a counter WOULD survive — but it would also be one more piece of state to
  # reset between cases, and `mktemp -d` needs none. What has changed is the hazard: an assignment in
  # here no longer dies with a subshell, so anything added below must be `local` on purpose rather
  # than by accident.
  _st_fresh() {
    local d
    # Drop earlier case dirs first. Each case is self-contained and never revisits a previous one,
    # and the tree is ~4 MB — without this, ~24 cases peak at ~100 MB of temp. Statelessly, by glob,
    # which is simplest and needs no per-case bookkeeping.
    rm -rf "$ST_WORK"/case.*
    d="$(mktemp -d "$ST_WORK/case.XXXXXX")" || return 1
    check_copy_worktree "$ST_PRISTINE" "$d" || return 1
    printf '%s' "$d"
  }

  # _st_minimal <dir>  (synthetic rule text on stdin) — swap the copy's whole rule set for the text
  # given. Sliced by this file's own section markers with head/tail rather than sed or `awk -v`:
  # every rule under test is dense with backslashes and single quotes, and both of those tools would
  # eat them on the way in.
  _st_minimal() {
    local d="$1" f synth start end
    if [ -z "$d" ]; then
      bad "_st_minimal(): empty fixture dir — '_st_fresh' failed; refusing to slice a path outside the fixture"
      return 1
    fi
    f="$d/scripts/check-fact-drift.sh"
    synth="$(cat)"
    start="$(grep -n '^# --- FACT: ' "$f" | head -n1 | cut -d: -f1)"
    end="$(grep -n '^# --- what was actually evaluated' "$f" | head -n1 | cut -d: -f1)"
    if [ -z "$start" ] || [ -z "$end" ]; then
      bad "_st_minimal(): section markers not found in check-fact-drift.sh — this mode's slicing is stale"
      return 1
    fi
    { head -n "$((start - 1))" "$f"; printf '%s\n' "$synth"; tail -n "+$end" "$f"; } > "$f.tmp" \
      && mv "$f.tmp" "$f"
  }

  # _st_run <dir> [args…] — run the copy's lint, capturing merged output in ST_OUT and status in
  # ST_RC. Set ST_PATH to override PATH for one case (used to stub out `find`).
  #
  # An EMPTY <dir> is fatal rather than ignored: `_st_fresh` can fail, its callers assign in a
  # command substitution that cannot propagate a status, and `cd "" && …` succeeds — which would
  # silently aim the whole case at the REAL repo root instead of the fixture.
  ST_OUT=""; ST_RC=0; ST_PATH=""
  _st_run() {
    local d="$1"; shift
    if [ -z "$d" ]; then
      bad "_st_run(): empty fixture dir — '_st_fresh' failed and the case would have run against the real repo"
      ST_OUT=""; ST_RC=-1; return
    fi
    ST_OUT="$( cd "$d" && PATH="${ST_PATH:-$PATH}" bash scripts/check-fact-drift.sh "$@" 2>&1 )"; ST_RC=$?
  }

  # ------------------------------- the control ---------------------------------
  # An untouched copy must pass NORMAL mode. Without this, every "it failed" below could be the copy
  # being broken rather than the case under test. (`--mutation` gets its own control further down, on
  # a one-rule fixture; running it here would re-do every sub-lint selfcheck already runs.)
  d="${ _st_fresh; }"
  _st_run "$d"
  eq "$ST_RC" 0 "control: a pristine copy passes the lint"
  has "$ST_OUT" "absent rules" "control: the run reports what it evaluated"

  # -------------------- #213's actual defect, both directions ------------------
  # The pattern as originally shipped, against the real shell idiom. `\[bot\]\$` asks for a
  # contiguous `[bot]$`; the idiom always backslash-escapes the bracket, so it matched nothing at all
  # and the check was green forever.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact historic-bot-pin 'absent:\[bot\]\$' 'fires:s/\[bot\]$//' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "historic-bot-pin: the pattern that shipped unfirable is rejected"
  has "$ST_OUT" "UNFIRABLE PIN" "historic-bot-pin: named as unfirable, not as generic drift"

  # ...and its correction accepted, against BOTH real spellings — the shell form (one backslash) and
  # the jq form (two). A pin witnessed by only one of them would have re-created the defect one
  # spelling narrower.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact fixed-bot-pin 'absent:bot\\*\]\$' 'fires:s/\[bot\]$//' 'fires:sub("\\[bot\\]$"; "")' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 0 "fixed-bot-pin: the corrected pattern matches both real idioms"

  # ---------------------------- the witness contract ---------------------------
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact no-witness 'absent:ZZQQ-superseded' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an absent: rule with no fires: witness is refused"
  has "$ST_OUT" "declares no fires: witness" "no-witness: says which contract was broken"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact witness-on-positive 'fixed:ai-dev-baseline' 'fires:ai-dev-baseline' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "fires: on a positive rule is a usage error, not silently ignored"
  has "$ST_OUT" "only meaningful on an absent: rule" "witness-on-positive: names the misuse"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact empty-witness 'absent:ZZQQ' 'fires:' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an empty fires: value is refused (it would witness nothing)"
  has "$ST_OUT" "empty fires: witness" "empty-witness: names the shape"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact multiline-witness 'absent:ZZQQ' 'fires:one
two' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a witness spanning lines is refused (grep is line-oriented)"
  has "$ST_OUT" "witness spans lines" "multiline-witness: names the reason"

  # ------------------------- the degenerate-rule shapes ------------------------
  # Each of these is a way a rule asserts NOTHING while looking like a rule.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact empty-needle 'absent:' 'fires:anything' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an empty pattern is refused (it matches every line of every file)"
  has "$ST_OUT" "empty absent pattern" "empty-needle: names the shape"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact empty-fixed-needle 'fixed:' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an empty fixed: token is refused too"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact no-separator 'fixed:ai-dev-baseline'
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a rule with no '--' is refused"
  has "$ST_OUT" "missing '--'" "no-separator: names the missing separator"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact no-files 'fixed:ai-dev-baseline' --
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a rule with no files is refused (it can never fail)"
  has "$ST_OUT" "no files" "no-files: names the shape"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact bad-kind 'bogus:ai-dev-baseline' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an unknown spec kind is refused"
  has "$ST_OUT" "unknown spec kind" "bad-kind: names the kind"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact no-colon 'ai-dev-baseline' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a spec with no kind prefix is refused"
  has "$ST_OUT" "malformed spec" "no-colon: names the shape"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact stray-arg 'fixed:ai-dev-baseline' README.md -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "an argument that is neither fires: nor '--' is refused"

  # A file listed twice asserts nothing new — and under --mutation the second injection would
  # overwrite the first's backup, so the restore would put back an already-mutated file and one
  # witness would leak into the next.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact duplicate-file 'absent:ZZQQ' 'fires:ZZQQ' -- README.md README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a file listed twice in one rule is refused"
  has "$ST_OUT" "listed more than once" "duplicate-file: names the shape"

  # ------------------------------ the empty rule set ---------------------------
  # The quietest possible green: a truncated file, a sourcing accident, an early exit. Every
  # individual assertion still passes, because there are none.
  d="${ _st_fresh; }"
  _st_minimal "$d" </dev/null
  _st_run "$d"
  eq "$ST_RC" 1 "a lint that evaluated no rules at all fails instead of passing"
  has "$ST_OUT" "no rules were evaluated" "empty rule set: says so in as many words"

  # Positive rules only — the negative half of the lint silently deleted.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact positives-only 'fixed:ai-dev-baseline' -- README.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a lint with no absent: rules left fails"
  has "$ST_OUT" "superseded-value half of this lint is gone" "positives-only: names what vanished"

  # ------------------------------- the mutation mode ---------------------------
  # Its control: one synthetic rule, injected and observed going red end to end.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-control 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  _st_run "$d" --mutation
  eq "$ST_RC" 0 "mutation control: a firable pin is observed going red"
  has "$ST_OUT" "witnesses injected" "mutation control: reports what it injected"
  # The live tree is never the thing mutated. If it were, README.md would now carry the witness.
  hasnt "$(cat "$ROOT/README.md")" "ZZQQ-superseded token" "mutation ran against a COPY, not the working tree"

  # A rule whose predicate cannot fire: `req_absent` neutered in the copy. Normal mode still passes
  # (nothing asserts), which is precisely the silence this mode exists to break.
  #
  # THE SANCTIONED MARKER GOES INTO THE FIXTURE LINE, not just onto this one, and that is what makes
  # the case isolated. Without it the injected stub is itself an unmarked call site, so the
  # call-site scan reports a bypass and the `--mutation` run comes back 1 whether or not
  # `_fact_mutate`'s stayed-GREEN verdict still fails the run — the case would pass while proving
  # nothing about the branch it names. Verified by neutering that branch: with the marker the case
  # goes red, without it, green.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-dead-predicate 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nreq_absent() { :; }   # adb-allow: req_absent\n' >> "$d/scripts/check-lib.sh"
  _st_run "$d"
  eq "$ST_RC" 0 "dead predicate: normal mode cannot see it (this is the silence)"
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "dead predicate: --mutation catches a pin that cannot fire"
  has "$ST_OUT" "cannot fire" "dead predicate: names it as an unfirable pin, not as a crash"
  hasnt "$ST_OUT" "a crash or broken copy" "dead predicate: a green lint is NOT reported as a crash"

  # A lint that goes non-zero for a reason that is NOT a drift verdict (a crash, a missing
  # dependency, a corrupt copy). "Any non-zero" would accept it and prove nothing.
  # The sabotage edits the copy's lint, so the OUTER --mutation run inherits the same `exit 3`; what
  # is under test is the message, and that the run does not come back green.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-wrong-rc 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\n_guard_rc=$?\n[ "$_guard_rc" -eq 0 ] || exit 3\nexit 0\n' >> "$d/scripts/check-fact-drift.sh"
  _st_run "$d" --mutation
  no "$ST_RC" "--mutation requires exactly rc 1, not merely non-zero"
  has "$ST_OUT" "not a drift verdict" "wrong rc: distinguishes a crash from a verdict"

  # A file pinned ONLY by an absent: rule and missing from the tree. `req_absent` is vacuously true
  # on a missing path, so this used to be a SILENT pass that the totals then reported as "scanned".
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-missing-file 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- docs/does-not-exist.md
RULE
  _st_run "$d"
  eq "$ST_RC" 1 "a pinned file that does not exist fails — the rule asserts nothing about it"
  has "$ST_OUT" "pinned file does not exist" "missing file: names the path"
  has "$ST_OUT" "0 files scanned" "missing file: is NOT counted as scanned"
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "missing pinned file: --mutation stops at the pristine baseline"
  has "$ST_OUT" "PRISTINE tree copy does not pass" "missing file under mutation: names why it stopped"

  # The per-file diagnostic match. An UNRELATED failure returns rc 1 too, and accepting that would
  # let a neighbouring rule's red satisfy this rule's proof while the pin stayed unfirable. Here
  # `req_absent` fires — so the lint goes red — but reports someone else's label.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-wrong-diagnostic 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  cat >> "$d/scripts/check-lib.sh" <<'STUB'
req_absent() {   # adb-allow: req_absent
  if grep -Eq -- "$2" "$1"; then
    check_note "[some-other-rule] superseded pattern /decoy/ still present in nowhere.md:"
    check_fail
  fi
}
STUB
  _st_run "$d"
  eq "$ST_RC" 0 "wrong diagnostic: the pristine baseline is still clean"
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "an unrelated rule going red does NOT satisfy this rule's proof"
  has "$ST_OUT" "did NOT trip the rule" "wrong diagnostic: names the per-file miss"

  # A tree that is ALREADY red must not be mutated: every injection would "fail the lint" for a
  # reason having nothing to do with the witness, and the mode would report success.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact mutation-dirty-baseline 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nZZQQ-superseded token\n' >> "$d/README.md"
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "--mutation refuses to run against a tree that is already drifting"
  has "$ST_OUT" "PRISTINE tree copy does not pass" "dirty baseline: names why it stopped"

  # --------------------- the req_absent call-site invariant --------------------
  # The witness contract lives in fact(); a direct caller bypasses it entirely.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-invariant 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nreq_absent scripts/check-lib.sh "ZZQQ" stray-caller\n' >> "$d/scripts/check-cleanup.sh"   # adb-allow: req_absent
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "an unmarked caller outside fact() is refused"
  has "$ST_OUT" "called outside fact()" "call-site invariant: names the bypass"

  # A MENTION in a comment is not a call — suites legitimately discuss the helper in prose.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-comment 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\n# req_absent is deliberately not used here\n' >> "$d/scripts/check-cleanup.sh"   # adb-allow: req_absent
  _st_run "$d" --mutation
  eq "$ST_RC" 0 "a commented mention of the helper is not a call site"

  # THE EXEMPTION IS PER LINE, NOT PER FILE. A whole-file exclusion made this invariant false: a real
  # direct call added to one of the files that legitimately name the helper would pass undetected. A
  # sanctioned line carries a marker; an unmarked one is caught wherever it lives.
  #
  # The target is `scripts/check-lib.sh` — which DEFINES the helper and therefore names it on a
  # sanctioned line — and the injected call names a path that does not exist, so `req_absent` returns
  # immediately: this file is SOURCED by the lint, and a call that actually asserted something would
  # be testing the injection rather than the scan. (Before #377 the target was the standalone guard
  # suite, which the lint never sourced.)
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-in-exempt-file 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nreq_absent scripts/no-such-file "ZZQQ" sneaky\n' >> "$d/scripts/check-lib.sh"   # adb-allow: req_absent
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "an unmarked call inside a file that legitimately names the helper is still caught"
  has "$ST_OUT" "called outside fact()" "exempt-file call: reported as the bypass"
  has "$ST_OUT" "scripts/check-lib.sh:" "exempt-file call: names the file it found it in"

  # ...and the marker is what makes a line sanctioned, so a marked line is accepted anywhere.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-marked 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nreq_absent a b c   # adb-allow: req_absent\n' >> "$d/scripts/check-cleanup.sh"
  _st_run "$d" --mutation
  eq "$ST_RC" 0 "a line carrying the sanctioned marker is accepted"

  # EXTENSIONLESS shell programs are scanned too. `bin/agent-init` and `bin/baseline` have no `.sh`,
  # and a `*.sh`-only enumeration left them — and any future extensionless script — invisible.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-extensionless 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  printf '\nreq_absent scripts/check-lib.sh "ZZQQ" from-bin\n' >> "$d/bin/agent-init"   # adb-allow: req_absent
  _st_run "$d" --mutation
  eq "$ST_RC" 1 "a call in an extensionless shell program (bin/agent-init) is caught"
  has "$ST_OUT" "bin/agent-init" "extensionless: names the file"

  # The enumeration's own zero-file branch. A scan that returns nothing is a BROKEN scan, not a clean
  # tree — the silent-inert shape this whole family is about. Driven with a `find` that finds nothing.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact callsite-zero-files 'absent:ZZQQ-superseded' 'fires:ZZQQ-superseded token' -- README.md
RULE
  mkdir -p "$d/stubbin"
  printf '#!/bin/sh\nexit 0\n' > "$d/stubbin/find"
  chmod +x "$d/stubbin/find"
  ST_PATH="$d/stubbin:$PATH"
  _st_run "$d" --mutation
  ST_PATH=""
  eq "$ST_RC" 1 "an enumeration that finds no shell files fails instead of passing"
  has "$ST_OUT" "enumeration is broken" "zero files: names the broken scan"

  # ------------------- an ACTIVE invocation, not the raw token -----------------
  # A `fixed:` pin on a command is satisfied by a COMMENTED-OUT command, so commenting out the
  # selfcheck line and the workflow step would leave both tokens present and both guards un-run. The
  # wiring rules therefore anchor on `^[^#]*`; prove it both ways on a fixture file.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
  printf '\n# bash scripts/check-fact-drift.sh --mutation\n' >> "$d/README.md"
  _st_run "$d"
  eq "$ST_RC" 1 "a COMMENTED-OUT invocation does not satisfy the wiring pin"
  has "$ST_OUT" "canonical pattern" "commented invocation: reported as a missing pattern"

  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
  printf '\nif bash scripts/check-fact-drift.sh --mutation; then :; fi\n' >> "$d/README.md"
  _st_run "$d"
  eq "$ST_RC" 0 "an ACTIVE invocation satisfies it"

  # ...and it must not depend on something preceding the token, which is the trap the earlier
  # `[^#[:space:]]`-consuming anchor fell into twice.
  d="${ _st_fresh; }"
  _st_minimal "$d" <<'RULE'
fact active-invocation 'regex:^[^#]*check-fact-drift\.sh --mutation' -- README.md
fact keeps-a-negative 'absent:ZZQQ-never-present' 'fires:ZZQQ-never-present' -- README.md
RULE
  printf '\nbash scripts/check-fact-drift.sh --mutation\n' >> "$d/README.md"
  _st_run "$d"
  eq "$ST_RC" 0 "an invocation at the START of a line satisfies it too"

  # -------------- the suite's own verdict cannot be skipped --------------------
  # A suite's exit status is its LAST COMMAND's, and only check_summary consults the `fail` counter.
  # Lose that final line and the suite prints FAIL diagnostics, exits 0, and is reported as passing.
  ST_SELF="$ST_WORK/selftest"
  mkdir -p "$ST_SELF/scripts"
  cp scripts/check-lib.sh "$ST_SELF/scripts/"
  # A tiny suite that records a FAILING assertion and then ends without its summary.
  cat > "$ST_SELF/scripts/truncated.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "truncated-suite"
bad "a deliberate failure that nothing will ever count"
SUITE
  ( cd "$ST_SELF" && bash scripts/truncated.sh ) >/dev/null 2>&1
  eq "$?" 1 "a suite that ends without check_summary fails closed"

  # ...and the guard does not fire when the summary DID run.
  cat > "$ST_SELF/scripts/complete.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "complete-suite"
ok
check_summary "complete-suite"
SUITE
  ( cd "$ST_SELF" && bash scripts/complete.sh ) >/dev/null 2>&1
  eq "$?" 0 "a suite that runs its summary is unaffected by the guard"

  # ...and a real failure still exits 1 through the guard rather than being masked by it.
  cat > "$ST_SELF/scripts/failing.sh" <<'SUITE'
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "failing-suite"
bad "a real, counted failure"
check_summary "failing-suite"
SUITE
  ( cd "$ST_SELF" && bash scripts/failing.sh ) >/dev/null 2>&1
  eq "$?" 1 "a counted failure still exits 1"

  # ...and the cleanup argument still runs.
  ST_PROBE="$ST_WORK/cleanup-probe"
  : > "$ST_PROBE"
  cat > "$ST_SELF/scripts/cleanup.sh" <<SUITE
set -u
cd "\$(dirname "\$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_exit_guard "cleanup-suite" "rm -f '$ST_PROBE'"
ok
check_summary "cleanup-suite"
SUITE
  ( cd "$ST_SELF" && bash scripts/cleanup.sh ) >/dev/null 2>&1
  if [ -e "$ST_PROBE" ]; then bad "check_exit_guard did not run its cleanup command"; else ok; fi

  # ------------------------------ argument handling ----------------------------
  d="${ _st_fresh; }"
  _st_run "$d" --bogus
  eq "$ST_RC" 2 "an unknown mode argument exits 2 rather than silently running normally"
  d="${ _st_fresh; }"
  _st_run "$d" --mutation extra
  eq "$ST_RC" 2 "a surplus argument exits 2"
  d="${ _st_fresh; }"
  _st_run "$d" --self-test extra
  eq "$ST_RC" 2 "a surplus argument after --self-test exits 2 too"

  check_summary "fact-self-test"
  exit 0
fi

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

# --- FACT: cleanup origin/HEAD symref filter (#38) — RETIRED by #372 ---------
# The pin existed because check-cleanup-enum.sh could only re-implement, never source, the
# enumeration pipeline inside cleanup.md's fence — two spellings of one pipeline, held together
# by a string. #372 deleted the copy: check-cleanup.sh section 11 now extracts the workflow's
# `remote-enum` block by marker and executes it against a real remote, so there is no second
# spelling left to drift, and a doc whose filter is deleted fails the executed regression.

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

# The PR arm's machine-readable read (#165). Same three-surface contract as its parent: the library
# IMPLEMENTS the flag, the CI step PASSES it, and the doc DOCUMENTS it, so a rename in one place is
# drift. (A rename in the library alone does NOT go silent — the advisory arm re-raises exit 2, and
# `check-repo-settings.sh` executes it against a stub to prove that. This pin is about the three
# spellings agreeing, not about rescuing a failure mode that is already loud.)
#
# WHAT THIS PIN CANNOT DO, stated so nothing downstream over-credits it: it is a fixed-string
# presence test, and `ci.yml` names the flag in COMMENTS as well as in the invocation — so removing
# it from the real call while leaving the prose satisfies this rule. Likewise the sibling
# `required-drift-wired` pin does not prove the STEPS exist, only that the string appears somewhere
# in the file. Deletion and mis-gating are both caught by the structural assertions in
# `scripts/check-repo-settings.sh`, which count the call sites and compare each `if:` for equality.
fact required-drift-porcelain "fixed:--porcelain" -- \
  scripts/lib/repo-settings.sh .github/workflows/ci.yml docs/repo-settings.md

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

# --- FACT: the health-declaration AUTHORITY predicate (#293) -----------------
# `health-decl` decides whether an owner's `release-health` marker may be honoured, and it is the
# one thing standing between an editable issue body and a release cut. It earns a pin for the same
# reason `branch-health` does, plus one this one has that the marker READER (`health-optout`,
# unpinned) does not: it has TWO callers in two different drivers. A rename in the library makes
# both of them die loudly — the dispatcher refuses an unknown subcommand — so the LOUD half needs
# no pin. The silent half is the documentation, which would go on describing an authority check
# nobody can run, in the one doc an adopting repo reads to decide whether to trust the marker.
fact health-decl-predicate "fixed:health-decl" -- \
  scripts/lib/roadmap-lib.sh base/workflows/roadmap.md \
  .claude/skills/release/release.sh docs/release-goal-convention.md

# --- FACT: a closing keyword only fires from PROSE, and the field that proves it ----
# A `Closes #N` inside a CODE SPAN or a fence closes nothing, silently: the PR merges, the issue
# stays open, and no output anywhere says so. The practice used to claim the keyword fires
# "anywhere in a PR body", which is what made a backticked one look safe — PR #294 shipped with
# both keywords in code spans, GitHub's `closingIssuesReferences` came back EMPTY, and two
# delivered `release-blocker` issues stayed open holding the release.
#
# The remedy is a live read of GitHub's own link set, and it is now stated in two places: the
# practice (the rule) and implement-issue step 10 (the check that runs). Pin the FIELD NAME across
# both — it is the whole mechanism, and a rename or a typo in either leaves one of them describing
# a verification nobody performs.
fact closing-refs-field "fixed:closingIssuesReferences" -- \
  base/practices/git-and-prs.md base/workflows/implement-issue.md
# ...and the SUPPRESSION rule itself must keep being stated where the keyword is written. Without
# it the check above reads as belt-and-braces rather than as the thing that caught a real loss.
fact closing-refs-prose-rule "fixed:code span" -- \
  base/practices/git-and-prs.md base/workflows/implement-issue.md

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
# `base/workflows/roadmap.md` USED TO restate the value and is pinned here no longer (#183). It is
# still prose an agent pastes into a shell, so it still cannot source a library — but it no longer
# has to carry a hand-written copy: it writes `{{ACTIONS_APP_SLUG}}` and `scripts/build.sh` derives
# the value from the accessor at render time. Keeping it in this fact would now pin the RENDERED
# value into the SOURCE, which is precisely the copy the token removed.
#
# `scripts/lib/common.sh` is therefore the last file that legitimately spells the literal — the one
# home the accessor reads from.
fact actions-slug-value  "fixed:github-actions" -- \
  scripts/lib/common.sh
# The ACCESSOR's consumers. `scripts/build.sh` joins them because the render is now one of them
# (#183), and `.claude/skills/release/release.sh` because it stopped carrying its own copy of the
# literal in the same change — it already sources common.sh, so the copy was never necessary, only
# unnoticed. A file in this list that quietly reverted to a hard-coded value is what the `absent:`
# rule below catches.
fact actions-slug-home   "fixed:adb_actions_app_slug" -- \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh \
  scripts/build.sh .claude/skills/release/release.sh
# THE COPY MUST NOT COME BACK BESIDE THE ACCESSOR. Positive presence alone would pass a file that
# calls `adb_actions_app_slug` AND keeps a hard-coded literal next to it — exactly the state #183
# removed from the workflow body and from the release driver. Anchored to a NON-comment line,
# because several of these files quote the value in prose to explain the bug.
# EVERY QUOTING, not just the double-quoted one. A rule that only saw `"github-actions"` let
# `'github-actions'` and a bare `github-actions` back in beside the accessor — three spellings of
# the same copy, one of them caught. Same lesson as the negative pin in D22 that matched neither
# real idiom. (Independent-review find.)
fact actions-slug-nocopy "absent:^[[:space:]]*[^#[:space:]].*['\"]?github-actions['\"]?" \
  'fires:  aslug=github-actions' -- \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh \
  scripts/build.sh .claude/skills/release/release.sh base/workflows/roadmap.md
# The build TOKEN and its mapping are one fact: a body that writes `{{ACTIONS_APP_SLUG}}` with no
# mapping in build.sh is a fail-loud build, but a mapping with no consumer is a silently dead knob.
fact actions-slug-token  "fixed:{{ACTIONS_APP_SLUG}}" -- \
  scripts/build.sh base/workflows/roadmap.md
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
# ...and ONE READ, in one place (#174). Both guards route their whole classification through
# `adb_pr_snapshot`; neither may grow a `gh api graphql` of its own. The positive rule is what
# proves each still calls it, and the `absent:` rule is what catches a guard that calls the shared
# reader AND re-open-codes a query beside it — the shape #173 showed survives review, because the
# copy looks correct in isolation and only diverges later.
# shellcheck disable=SC2086
fact pr-onread-shared "fixed:adb_pr_snapshot" -- $_prguards
fact pr-onread-shared "fixed:adb_pr_snapshot" -- scripts/lib/common.sh
# shellcheck disable=SC2086
fact pr-onread-shared "absent:gh api graphql" "fires:gh api graphql -f owner=" -- scripts/lib/pr-review.sh
# NOTE pr-watch.sh is deliberately NOT under that `absent:` rule: `request-review` legitimately
# makes its OWN GraphQL read (#169), because the receipt query selects comment BODIES that the
# classification snapshot must not pay for. The positive rule above still proves its CLASSIFY path
# routes through the shared reader.

# --- FACT: the one-read COST figure, measured once and restated in two operative headers (#174) ---
# `adb_pr_snapshot` and `pr-watch.sh`'s poll budget both quote the same measurement, and a budget
# nobody recomputes is how the poll-cost comment in that very file went stale TWICE — it said
# "three" for as long as a fourth read had existed, and "240 requests" after the count changed. Two
# copies is where that starts, so they are pinned together: re-measure and both must move.
#
# SCOPED TO THE CURRENT-CLAIM FILES, following the selfcheck-cost rule above. `CHANGELOG.md` and
# `.ai-dev-baseline/decisions.md` carry the same figure DELIBERATELY, as dated records of what was
# measured when; rewriting those would be falsifying history rather than correcting a claim. They
# are not in this list and must not be added to it.
fact pr-onread-cost 'fixed:39,833 bytes over 4 round trips' --   scripts/lib/common.sh scripts/lib/pr-watch.sh
fact pr-onread-cost 'fixed:97.0%' --   scripts/lib/common.sh scripts/lib/pr-watch.sh
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
#
# `^[^#]*` — an ACTIVE invocation, not the raw token. A plain `fixed:` rule is satisfied by a
# COMMENTED-OUT command, so `# bash scripts/check-fact-drift.sh --mutation` in selfcheck plus a
# commented `run:` step in the workflow would leave both tokens present and both guards un-run:
# precisely the silent unwiring these rules exist to catch, reproduced by the pin meant to prevent
# it (bot review, PR #230).
#
# The anchor is deliberately NOT `^[[:space:]]*[^#[:space:]].*TOKEN`, which is the shape that has
# now failed twice in this file: `[^#[:space:]]` CONSUMES the first non-blank character, so a line
# that STARTS with the invocation matches nothing. `^[^#]*` says "no `#` before the token" without
# consuming anything, and holds whether the line begins with `if`, with `run:`, or with `bash`.
#
# What it does NOT do: prove the surrounding YAML still parses, or that the step belongs to a job
# that runs. That needs a real workflow parser — tracked in #229.
#
# AND, since #260, it does not prove the selfcheck side RUNS either. These invocations used to be
# `if bash …; then` lines that could not be present without executing; they are now records in
# selfcheck's step registry, and a record is a weaker claim than a call. The patterns are unchanged
# — the registration lines are written unquoted and command-last precisely so they keep matching —
# but the "…and it actually runs" half now lives in `scripts/check-selfcheck.sh`, which drives the
# real dispatcher over a fixture and requires every registered step to execute and its status to
# reach the exit code. Neither half is sufficient alone; do not delete one on the strength of the
# other.
fact fact-mutation-wired 'regex:^[^#]*check-fact-drift\.sh --mutation' -- \
  scripts/selfcheck.sh .github/workflows/ci.yml
# The self-test mode, pinned the same way and for the same reason (#377). It was
# `check-fact-guard.sh` until the fold, and the rule moved with it rather than being retired:
# a mode is exactly as easy to un-wire as a file was.
fact fact-selftest-wired 'regex:^[^#]*check-fact-drift\.sh --self-test' -- \
  scripts/selfcheck.sh .github/workflows/ci.yml
# Same shape, same reason (#268). This one guards a hazard that only appears when a build ABORTS,
# so nothing about a normal green run would notice it had stopped being checked — the exact
# silent-un-wiring this family exists to catch. Both sides pinned: dropping it from either the
# local mirror or CI fails here.
fact build-atomic-wired 'regex:^[^#]*check-build-atomic\.sh' -- \
  scripts/selfcheck.sh .github/workflows/ci.yml

# --- what selfcheck COSTS, and the figure that replaced (#335) ----------------
#
# A WALL CLOCK CANNOT BE PINNED, and this lint does not pretend to. What it pins is the thing that
# actually failed: the figure was restated in SIX files (eight occurrences), went stale in all of
# them at once, and `CLAUDE.md` golden rule 3 — the contributor contract — told every reader and
# every agent that a mandatory pre-push gate cost about a minute when it cost minutes. Nothing
# offline can re-measure a runtime, so nothing can tell you the number has aged; what a lint CAN do
# is keep the surviving copies identical and refuse the retired value's return.
#
# TWO FILES CARRY A FIGURE, not six. That is the other half of the fix. `agents.toml`,
# `.claude/scripts/precommit-gate.sh`, `docs/per-project-overrides.md`, `.github/workflows/ci.yml`
# and `CLAUDE.md`'s own precommit-gate row now describe the cost QUALITATIVELY ("minutes, not
# seconds") and point at golden rule 3; only golden rule 3 and `CONTRIBUTING.md` state a
# measurement, and both state it as a dated RANGE.
_sc_cost_docs="CLAUDE.md CONTRIBUTING.md"
# shellcheck disable=SC2086  # deliberate word-splitting of the file list, as elsewhere in this file
fact selfcheck-cost 'fixed:8m46s to 12m55s' -- $_sc_cost_docs
#
# THE NEGATIVE HALF, and it is exactly what this file's header sanctions `absent:` for — "a value a
# fact has retired", never a general prose blocklist. Presence-checking cannot catch a file that
# carries the new figure AND keeps the old one beside it, which is how the 2026-08-03 measurement
# survived into a registry a quarter larger than the one it was taken on.
#
# THREE SPELLINGS, because the real ones differed and a pattern that catches two of three is green
# on the third: `CLAUDE.md` and four others wrote an ASCII hyphen, `CONTRIBUTING.md` and
# `docs/per-project-overrides.md` wrote an EN-DASH — which is why the first grep for this figure
# found five of seven sites — and two files carried a bare "66s" with no range at all.
#
# SCOPED TO THE CURRENT-CLAIM FILES. `.ai-dev-baseline/decisions.md` and `CHANGELOG.md` keep the
# figure deliberately: they are dated records of what was measured when, and rewriting them would
# be falsifying history rather than correcting a claim. They are not in this list and must not be
# added to it.
fact selfcheck-cost-stale 'absent:66[-–—]72 ?s|(^|[^0-9])66 ?s([^0-9]|$)' \
  'fires:66-72s after' 'fires:measured at 66–72s a turn' 'fires:even 66s per turn is the wrong trade' \
  -- $_sc_cost_docs agents.toml .claude/scripts/precommit-gate.sh \
     docs/per-project-overrides.md .github/workflows/ci.yml

# --- the bash floor: 5.3, and the 3.2 declaration it retired (#256/#261) ------
#
# The floor number itself, pinned across the constant and the docs that restate it. The constant in
# common.sh IS the canonical source and is in the file list, so changing the floor fails this lint
# until every consumer moves with it.
_bf_docs="CLAUDE.md CONTRIBUTING.md docs/installation.md docs/ci-runners.md scripts/lib/common.sh"
# shellcheck disable=SC2086  # deliberate word-splitting of the file list, as elsewhere in this file
fact bash-floor-value 'regex:(bash )?(>= ?)?5\.3' -- $_bf_docs
fact bash-floor-gate  'fixed:adb_require_bash' -- \
  scripts/lib/common.sh scripts/check-bash-floor.sh CLAUDE.md CONTRIBUTING.md
# The lint must stay WIRED, not merely present. `^[^#]*` for the same reason as the two rules
# above: a `fixed:` pin is satisfied by a commented-out invocation, which is exactly the silent
# un-wiring this family exists to catch.
#
# And it must be the BARE invocation — the default mode, which is the only one that runs BOTH the
# workflow half and the entry-point half. `--runtime` or `--workflow-dir` in its place would leave
# the token present while the entry-point lint ran zero times, so the pattern requires the
# invocation to end the command: end-of-line (the `run:` step) or a `;` (selfcheck's `if …; then`).
fact bash-entrypoint-lint-wired 'regex:^[^#]*check-bash-floor\.sh[[:space:]]*(;|$)' -- \
  scripts/selfcheck.sh .github/workflows/ci.yml

# THE NEGATIVE PIN, and it is deliberately NARROW. #261 proposed banning the string "bash 3.2"
# tree-wide; that would be wrong twice over. This lint is an allowlisted superseded-VALUE checker,
# not a prose blocklist (see this file's header) — and the historical mentions are legitimate and
# load-bearing: D29 and docs/ci-runners.md explain WHY macOS needs a re-exec by naming 3.2.57, the
# guard suite builds 3.2 fixtures, and the changelog records what shipped when. A rule that fired
# on those would be deleted within a week.
#
# What is genuinely retired is the DECLARATION — the sentence that told a contributor to WRITE
# 3.2-compatible code. So the pin is the declaration's real spellings, in the four files that
# carried it, and nowhere else. Both witnesses are the exact strings that were in the tree before
# this change (CLAUDE.md's "safe on macOS bash 3.2" and CONTRIBUTING.md/AGENTS.md's "macOS bash 3.2
# safe"), so `--mutation` reintroducing either must make this lint go red.
# The spelling set is WIDER than the four documents' headline sentences, because review found the
# same declaration living in ordinary code comments too — `bash 3.2, this repo's floor`,
# `bash-3.2-safe`, `bash-3.2 safe`. A rule that pinned only the headline spellings passed its own
# mutation test while the acceptance criterion ("no doc, comment, or adapter header states a 3.2
# floor") stayed violated in three files it did not list.
#
# The file list is correspondingly wider, and deliberately EXCLUDES the places a 3.2 mention is
# legitimate history rather than a live declaration: CHANGELOG.md, .ai-dev-baseline/decisions.md,
# docs/ci-runners.md, the guard suites that build 3.2 fixtures, and this file's own witnesses.
# That is the line #261 asked for and the line a tree-wide ban would have crossed.
fact bash-floor-stale-decl \
  'absent:(safe on macOS bash 3\.2|macOS bash 3\.2 safe|Portable to macOS bash 3\.2|bash 3\.2, this repo|bash-3\.2[- ]safe)' \
  'fires:Shell code must be portable and shellcheck-clean. bash/POSIX, safe on macOS bash 3.2' \
  'fires:**Shell:** `bash`/POSIX, macOS bash 3.2 safe (no `mapfile`, no `readlink -f`),' \
  'fires:# Portable to macOS bash 3.2: no `readlink -f`, no `mapfile`, no associative' \
  'fires:  # which bash 3.2, this repo'"'"'s floor, does not have.' \
  'fires:# falls back to a bash-3.2-safe background watchdog' \
  'fires:  # A `case` glob does this with no subshell (bash-3.2 safe).' \
  -- CLAUDE.md CONTRIBUTING.md AGENTS.md agents/codex/adapter.sh agents/gemini/adapter.sh \
     scripts/lib/common.sh scripts/lib/roadmap-lib.sh scripts/lib/skill-compose.sh \
     scripts/lib/pr-watch.sh docs/installation.md

# The two carve-outs are the part most likely to be "cleaned up" by a later modernization pass that
# does not know why they exist, so both are pinned where they are explained.
fact bash-floor-bootstrap-carveout 'fixed:parseable' -- \
  scripts/lib/common.sh CLAUDE.md CONTRIBUTING.md .ai-dev-baseline/decisions.md
fact bash-floor-observer-carveout 'fixed:EXEMPT_ENTRYPOINTS' -- scripts/check-bash-floor.sh

# --- FACT: there is ONE workflow-YAML reader, and both consumers call it (#262, #102) -----------
#
# The structural half of #262, and it is the half prose cannot hold. Two files read
# .github/workflows and want OPPOSITE things from it (provable check contexts vs every job on a
# proven runner), and before the shared reader each carried its own job-boundary detection and its
# own YAML scalar parser. They drifted before either shipped: `runs-on: "ubuntu-26.04 # …"` was
# read correctly by one and reduced to the approved label by the other.
#
# Nothing stops the next divergence except a rule that FAILS when a consumer stops calling the
# shared reader — because re-growing a local scanner is a silent change. Both files still pass their
# own suites afterwards: each one's tests only ever prove that ITS filter behaves, and a private
# parser that agrees with the shared one today is exactly what the last one looked like too.
# The DEFINITION site, so renaming the primitive fails until every consumer moves with it.
fact workflow-reader-home 'fixed:adb_wf_jobs' -- scripts/lib/common.sh
fact workflow-reader-on   'fixed:adb_wf_on'   -- scripts/lib/common.sh

# The CALL sites, matched as an actual invocation rather than as the token appearing anywhere.
# A `fixed:` pin was not enough and the gap is not hypothetical: both consumers explain the shared
# reader in their own comments, so deleting the call and leaving the paragraph that describes it
# kept the rule green — a pin that reads as "this file still uses the reader" while the file has
# quietly regrown a private one. `^[^#]*` requires the match to be reached without passing a `#`,
# so a commented mention cannot satisfy it.
fact workflow-reader-called 'regex:^[^#]*adb_wf_jobs[[:space:]]+"' -- \
  scripts/lib/repo-settings.sh scripts/check-bash-floor.sh scripts/check-common-lib.sh
fact workflow-reader-on-called 'regex:^[^#]*adb_wf_on[[:space:]]+"' -- \
  scripts/lib/repo-settings.sh scripts/check-common-lib.sh

# The NEGATIVE half: the retired local scanners must not come back beside the shared call. A
# presence check alone cannot catch a file that calls `adb_wf_jobs` AND keeps a private
# `yaml_scalar` next to it, which is precisely how a superseded implementation survives a repoint.
#
# `function yaml_scalar` / `function flush_job` are the real retired spellings — both files defined
# their scalar parser that way, and repo-settings.sh fused enumeration with its CHECK/SKIP verdict
# in `flush_job`, the seam #262 had to cut. The witnesses are the literal lines that were deleted.
#
# WHAT THIS PAIR DOES AND DOES NOT PROVE, because overstating a guard is worse than a narrow one.
# The `regex:` call pins above are the load-bearing half: they fail if a consumer stops CALLING the
# shared reader, whatever it does instead. This `absent:` rule is the narrower complement — it
# rejects the two retired definitions coming back BESIDE a still-present call, which presence
# checking alone cannot see. It does NOT enumerate every name a future private scanner could take;
# an inline awk scanner under some other name would pass it. That is inherent to a negative pin, and
# the call pins are what make it acceptable: a second reader can exist only in addition to the
# shared one, never instead of it.
fact workflow-scanner-stale \
  'absent:^[[:space:]]*function[[:space:]]+(yaml_scalar|flush_job|scan_jobs_local)[[:space:]]*\(' \
  'fires:    function yaml_scalar(s) {' \
  'fires:    function flush_job() {' \
  -- scripts/lib/repo-settings.sh scripts/check-bash-floor.sh

# --- FACT: the Windows/WSL smoke job exists, and the docs that claim it agree (#2, D38) ---------
#
# THIS IS THE ENFORCEMENT HALF, and it deliberately does NOT live in check-bash-floor.sh. Review
# was right that printing "0 WSL-host" is visibility, not enforcement: delete `wsl-smoke.yml` and
# that lint still exits 0 while `docs/ci-runners.md` and `CONTRIBUTING.md` go on describing a
# Windows leg that no longer runs. But an "at least one WSL job" AGGREGATE rule in the floor lint is
# the wrong home for it: every fixture in check-bash-floor-guard.sh would then go red for a reason
# other than the rule under test, which is the isolation failure that file's own header warns
# against — the test harness would be shaping the production invariant.
#
# A positive `fact` rule is the right home, and it is strictly stronger than the aggregate would
# have been. A `fixed:` rule REPORTS A BAD PATH rather than passing vacuously (this file's own
# header says so, which is why the rendered skills are pinned the same way), so deleting the
# workflow fails here loudly — and because the same token is pinned in the two docs that assert the
# claim, deleting the claim without the job, or the job without the claim, both fail. Neither can
# drift away from the other silently.
# ANCHORED TO EXECUTABLE FIELDS, NOT TO TOKENS ANYWHERE IN THE FILE. The first cut of these rules
# used `fixed:windows-latest` / `fixed:Ubuntu-26.04` over the workflow AND the docs, and review
# reproduced the hole: both tokens also appear in this workflow's own explanatory COMMENTS, so
# repointing `runs-on:` at `ubuntu-26.04` and swapping the floor step for the ordinary host
# invocation deleted the Windows leg while every rule here stayed green and `check-bash-floor.sh`
# reported `0 WSL-host … PASS`. A pin satisfied by prose about the thing is the same fail-open as a
# `# TODO: run the guard` comment satisfying the guard rule — twice now in this repo.
#
# So the workflow is pinned on the two fields that actually RUN, each anchored to the start of a
# YAML line (a `#` comment can therefore never satisfy them), and the doc-side token pins are split
# onto the docs alone.
#
# THE DIVISION OF LABOUR IS DELIBERATE: this file pins that the job EXISTS and names the right host
# and distro; `check-bash-floor.sh` owns the GRAMMAR (guard reached through `wsl -d <distro>`, the
# version logged first, both naming the same distro). Once `runs-on: windows-latest` is pinned here,
# the WSL-host class forces all of that, so re-stating the grammar in this file would be the copy
# this repo's law forbids.
fact wsl-smoke-runner \
  'regex:^[[:space:]]*runs-on:[[:space:]]*windows-latest[[:space:]]*$' \
  -- .github/workflows/wsl-smoke.yml
# PINNED ON THE GUARD LINE, not on "a run: step mentioning the distro anywhere". Negative-testing
# the looser form found the residual hole: repointing every `-d` invocation at Ubuntu-24.04 — a
# distro BELOW the floor — left the `wsl --install --distribution Ubuntu-26.04` step still matching,
# so the pin stayed green while the suite would have run on 5.2.21. The floor proof is the line that
# has to name the distro, because it is the line whose interpreter is the claim.
fact wsl-smoke-floor-in-distro \
  'regex:^[[:space:]]*run:[[:space:]]*wsl([[:space:]]|\.exe[[:space:]]).*(-d|--distribution)[[:space:]]+Ubuntu-26\.04[^|;&]*--[[:space:]]+bash[[:space:]]+scripts/check-bash-floor\.sh[[:space:]]+--runtime[[:space:]]*$' \
  -- .github/workflows/wsl-smoke.yml
# The trigger shape is the other half of the decision (#2's "release/weekly", D38's "never
# per-PR"): a job quietly repointed at `pull_request` would be a per-PR Windows cost AND a
# discovered required context, which is exactly what its own file was chosen to prevent.
fact wsl-smoke-scheduled 'regex:^[[:space:]]*schedule:' -- .github/workflows/wsl-smoke.yml
# The DOCS half: the two files that assert the Windows leg to a reader must keep naming it, so the
# job and the claim cannot drift apart in either direction. `fixed:` is right here — these are prose
# documents, and the token appearing in prose is exactly what is being pinned.
_wsl_smoke_docs="docs/ci-runners.md CONTRIBUTING.md"
fact wsl-smoke-doc-host   'fixed:windows-latest' -- $_wsl_smoke_docs
fact wsl-smoke-doc-distro 'fixed:Ubuntu-26.04'   -- $_wsl_smoke_docs

# --- FACT: the WSL job runs the FRAMEWORK as a non-root user (#271, D39) ------------------------
#
# Root holds `CAP_DAC_OVERRIDE`, so a POSIX mode bit cannot deny it a write — and the offline suite
# has one assertion that depends on exactly that (`scripts/check-skill-compose.sh:329-330` chmods a
# directory 555 and requires the next compose to FAIL). Run the suite as root and that assertion
# INVERTS: the job goes red on a fixture that passes everywhere a normal user runs it. The smoke job
# is weekly, so it is far too slow to be the only thing standing between a future edit and that
# state; this is the guard that catches it in the same run that writes it.
#
# THE LITERAL RULE THE ISSUE ASKED FOR IS UNSATISFIABLE, and recording why is the point of the shape
# below. `fact` applies ONE pattern to a WHOLE FILE — there is no step selector — so a bare
# `absent:--user root` would be tripped by the three invocations that must STAY root (the
# `/etc/os-release` read precedes the account; `apt-get` and `useradd` are privileged by nature) and
# by this workflow's own explanatory comments. It would fail on a correct file, which under
# `--mutation` means it never even reaches its witness. So the pattern is CONTEXTUAL: a `wsl`
# invocation that runs as root **and reaches a framework command**.
#
# BOTH DIRECTIONS ARE PINNED, and here the negative alone genuinely is not enough — the same lesson
# as the `actions-slug-*` family above, arrived at from the other side. The regression this exists to
# stop is "the job silently returns to root", and dropping `--user` ENTIRELY does that without ever
# spelling the word: `wsl --install --no-launch` provisions no user, so an invocation with no
# `--user` runs as the image's default, which is root. No negative pattern can catch an absent flag.
# Hence a positive rule per framework command, each asserting that line names `adb`.
#
# `[^#]*` RATHER THAN `.*` BETWEEN THE ANCHORS, and that is a review finding rather than caution.
# Anchoring on `run:` at the start of the line excludes a WHOLE-LINE comment, but not a TRAILING
# one: `run: wsl … # once --user root … bash scripts/selfcheck.sh` put the forbidden text on an
# executable line, where an unbounded `.*` read straight through the `#` and reported root use that
# YAML never executes. The positive rules had the mirror-image hole, and it was worse because it
# fails OPEN — `run: wsl --help # --user adb --cd /home/adb/x -- bash scripts/selfcheck.sh` satisfied
# the pin while executing `wsl --help`. Both were reproduced against this file. `[^#]*` cannot cross
# a `#`, so every one of these rules now describes executable content only. No real invocation here
# carries a `#` (the clone's URL is the only near-miss, and it has none).
#
# THE NARROWER CONTRACT IS DELIBERATE, and stated so nobody has to rediscover it: these pins accept
# `--user`/`-u` and `-d`/`--distribution`, but the invocation must be the whole `run:` value on one
# line. A `run: |` block carrying the same command is NOT recognized — the same fail-closed choice
# `check-bash-floor.sh` makes for the floor guard, and for the same reason: a form nothing in this
# repo uses is not worth a hole in a pattern.
#
# The negative also covers `-u`, the documented short form, which is genuinely the same instruction.
# It covers a NUMERIC uid too, but for a different and weaker reason, said plainly rather than
# folded in: `wsl --user` resolves a NAME through `getpwnam`, so `--user 0` does not mean root — it
# names a user that does not exist and errors. That branch is defence against a future `wsl.exe`
# that accepts a uid, not a spelling that works today, and its witness proves the pattern matches,
# not that the spelling would run as root.
fact wsl-smoke-nonroot-framework \
  'absent:^[[:space:]]*run:[[:space:]]*wsl([[:space:]]|\.exe[[:space:]])[^#]*(--user|-u)[[:space:]]+(root|0)([[:space:]]|$)[^#]*(--cd|git[[:space:]]+clone|bash[[:space:]]+(scripts/|install\.sh|uninstall\.sh|--version))' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root --cd /root/adb -- bash scripts/check-bash-floor.sh --runtime' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root --cd /root/adb -- bash install.sh --agent claude --agent codex --agent gemini' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root --cd /root/adb -- bash scripts/selfcheck.sh' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root --cd /root/adb -- bash uninstall.sh --agent claude --agent codex --agent gemini' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root -- bash -c "set -eu; git clone https://github.com/${{ github.repository }}.git /root/adb; git -C /root/adb -c advice.detachedHead=false checkout ${{ github.sha }}"' \
  'fires:        run: wsl -d Ubuntu-26.04 --user root -- bash --version' \
  'fires:        run: wsl -d Ubuntu-26.04 -u root --cd /home/adb/ai-dev-baseline -- bash scripts/selfcheck.sh' \
  'fires:        run: wsl -d Ubuntu-26.04 --user 0 --cd /home/adb/ai-dev-baseline -- bash scripts/selfcheck.sh' \
  -- .github/workflows/wsl-smoke.yml
# The first SIX witnesses are the REAL superseded lines, copied verbatim out of the commit before
# #271 — the input `base/practices/self-review.md` asks a guard to be proven on. The last two never
# existed in this tree, and saying which is which is more useful than implying every witness is
# historical: `-u root` is the same instruction spelled short, and `--user 0` is the defensive
# branch described above. They are here because an alternation exercised through one branch is
# several untested branches.
#
# `bash --version` IS in the framework alternation, and review is why. The distro's interpreter log
# is the one framework-touching line with no `--cd` and no script name, so the first cut of this
# rule let `--user adb` be dropped from it with nothing going red — root reintroduced on the very
# line whose whole job is to say which interpreter the framework runs under.

# The positive half: each command the framework itself runs must name `adb`. One rule per command
# — a `fact` proves only that SOME line matches, so a single rule could be satisfied by one
# compliant step while the others had drifted.
#
# The four `--cd` steps share a shape, so the pattern and the command token are derived from one
# list rather than written out five times: a hand-copied pattern is exactly where a rule that hunts
# one command while claiming to hunt another comes from (the lesson the `pr-classifier-no-copies`
# loop above records).
for _wslcmd in 'scripts/check-bash-floor\.sh' 'install\.sh' 'scripts/selfcheck\.sh' 'uninstall\.sh'; do
  fact wsl-smoke-runs-as-adb \
    "regex:^[[:space:]]*run:[[:space:]]*wsl([[:space:]]|\\.exe[[:space:]])[^#]*(--user|-u)[[:space:]]+adb[[:space:]]+--cd[[:space:]]+/home/adb/[^|;&#]*--[[:space:]]+bash[[:space:]]+$_wslcmd" \
    -- .github/workflows/wsl-smoke.yml
done
# The distro's `bash --version` log is the fifth `--user adb` line and gets its own pin, because it
# matches none of the shapes above: no `--cd`, no script name. It is also the line the negative rule
# missed until review found it.
fact wsl-smoke-logs-bash-as-adb \
  'regex:^[[:space:]]*run:[[:space:]]*wsl([[:space:]]|\.exe[[:space:]])[^#]*(--user|-u)[[:space:]]+adb[^#]*--[[:space:]]+bash[[:space:]]+--version[[:space:]]*$' \
  -- .github/workflows/wsl-smoke.yml
# The clone is the sixth, and it is NOT a `--cd` step — it is what creates the directory the other
# four `--cd` into, so it has to name its destination in full. It is pinned separately rather than
# forced into the loop's template, because a clone performed as root and merely handed to `adb` is
# its own defect: git refuses such a tree outright ("detected dubious ownership") and `install.sh`
# would fail on permissions, both several steps after the one that caused it.
#
# `"[^"]*git…` and not `".*git…`: confining the match to the INSIDE of the first quoted string is
# what makes this prove an executable clone. With `.*` the reviewer satisfied this rule using a line
# that ran `bash -c "true"` and mentioned `git clone /home/adb/` in a trailing comment.
fact wsl-smoke-clones-as-adb \
  'regex:^[[:space:]]*run:[[:space:]]*wsl([[:space:]]|\.exe[[:space:]])[^#]*(--user|-u)[[:space:]]+adb[[:space:]]+--[[:space:]]+bash[[:space:]]+-c[[:space:]]+"[^"]*git[[:space:]]+clone[^"]*/home/adb/' \
  -- .github/workflows/wsl-smoke.yml
# And the step that makes the whole thing readable in a log instead of reconstructable from a
# failing fixture 30 steps later: the job must assert its own effective uid is not 0.
#
# TWO RULES, because the read and the assertion are two things and pinning only the first proved
# nothing. Review changed `if ($uid -eq '0')` to compare against another value and this lint stayed
# green: `id -u` was still being read, and its result was simply no longer being judged. A guard
# pinned to the input of an assertion is not pinned to the assertion.
#
# Both are anchored to the start of a line with only whitespace before the code, so a PowerShell
# comment — which begins with `#` — can satisfy neither. The earlier unanchored form could be
# satisfied by a comment anywhere in the file.
fact wsl-smoke-reads-effective-uid \
  'regex:^[[:space:]]*\$uid[[:space:]]*=[[:space:]]*\(wsl[[:space:]]+(-d|--distribution)[[:space:]]+Ubuntu-26\.04[^#]*(--user|-u)[[:space:]]+adb[[:space:]]+--[[:space:]]+id[[:space:]]+-u' \
  -- .github/workflows/wsl-smoke.yml
fact wsl-smoke-asserts-nonroot-uid \
  "regex:^[[:space:]]*if[[:space:]]*\\(\\\$uid[[:space:]]+-eq[[:space:]]+'0'\\)[[:space:]]*\\{[[:space:]]*\$" \
  -- .github/workflows/wsl-smoke.yml

# --- FACT: the CI-run classifier, and the binary failure model it replaces (#300) ---------------
# BOTH DIRECTIONS, because each one alone passes the state this change removes.
#
# The POSITIVE half is the same contract shape as `branch-health` and `health-decl` above: the
# library implements the predicate, a practice and two docs name it as the thing that answers "did
# this run execute?", and two sibling libraries point at it from the reason lines an operator reads
# when their own verdict is `indeterminate` or `20`. A rename in the library alone leaves every one
# of those describing a command nobody can run — and unlike a workflow invocation, none of them
# would fail loudly, because they are prose.
# TWO TOKENS, NOT ONE — because the practice now spells the invocation BY PATH
# (`bash "$HOME/.<agent>/scripts/lib/ci-health.sh" classify --run <id>`, since nothing puts the
# library on PATH), so the contiguous `ci-health.sh classify` a single rule pinned no longer occurs
# anywhere a reader would look. Splitting the module name from the subcommand pins both renames
# independently and stops the rule from depending on how the two happen to be spaced.
fact ci-health-module "fixed:ci-health.sh" -- \
  scripts/lib/ci-health.sh base/practices/ci-discipline.md \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh \
  docs/philosophy.md docs/repo-settings.md
fact ci-health-subcommand "fixed:classify --run" -- \
  scripts/lib/ci-health.sh base/practices/ci-discipline.md \
  scripts/lib/roadmap-lib.sh scripts/lib/repo-settings.sh docs/repo-settings.md
# The build TOKEN and its mapping are one fact, exactly as `{{ACTIONS_APP_SLUG}}` is: a body that
# writes the placeholder with no mapping is a fail-loud build, but a mapping with no consumer is a
# silently dead knob.
fact ci-health-token "fixed:{{CI_HEALTH_LIB}}" -- \
  scripts/build.sh base/workflows/debug.md base/workflows/implement-issue.md base/workflows/roadmap.md
#
# The NEGATIVE half is the whole point of #300, and it is exactly the case this lint's header
# describes: a file can carry the new three-class model AND keep the old binary sentence beside it,
# satisfying the positive rule while still telling every reader that a CI failure is one of two
# things. That is not hypothetical — the binary model was restated in THREE places, in three
# different spellings, and only one of them was in the practice itself.
#
# ALL THREE REAL SPELLINGS ARE WITNESSES, and that is the lesson D22 paid for: a pattern that
# catches three of four spellings is green on the fourth. These are the verbatim superseded lines,
# one per file that carried one — `Classify: flaky or real` (the practice), `Classify flaky vs real`
# (the /debug workflow) and `classify flaky vs. real` (the philosophy doc). Note the pattern is
# deliberately narrow: it matches the two words ADJACENT, so the new "real, flaky, or never-ran"
# spelling — which mentions both words in one clause — does not trip it.
fact ci-failure-model-binary 'absent:flaky (or|vs\.?) real' \
  'fires:2. **Classify: flaky or real.** A real failure reproduces; a flaky one is a' \
  'fires:  (`base/practices/ci-discipline.md`). Classify flaky vs real with evidence first.' \
  'fires:  classify flaky vs. real with evidence, fix real failures at the root, and' -- \
  base/practices/ci-discipline.md base/workflows/debug.md docs/philosophy.md

# --- the release-role policy: release stays PROJECT-OWNED (#3/D7, migrated by #375) -------------
#
# #3 resolved a DECISION, not a feature: cutting a release stays project-owned, and the baseline
# ships no `/release` workflow. A decision is only as durable as the thing that re-checks it — and
# this one is a NEGATIVE invariant ("no such skill exists"), which `build-drift` and `workflow-map`
# cannot express, because a new workflow rendering correctly is exactly what they are built to allow.
#
# It was `scripts/check-release-role.sh` until #375. Three of its five groups were already this
# file's grammar (`fact <label> <token> -- <files>`, riding this same CI job), and the fourth — the
# `roll` boundary — was six negative greps that had NEVER been observed firing, on the highest
# consequence surface in the set: `scripts/lib/` ships to every adopter, so a release call grown
# inside `cmd_roll` would start publishing on THEIR repos. Moving it here is what gives that group
# `fires:` witnesses and a standing `--mutation` proof, which is protection it could not have where
# it was.
#
# The retired file's own header argued the other way — "a guard you have to reassemble from two
# files is harder to find and harder to reverse deliberately". That argument is preserved and
# answered rather than ignored: the whole policy now lives in ONE section of ONE file, which is
# strictly fewer places to look than the two it had. What it must not become is a rule scattered
# through the list above, so it keeps its own banner and its own paragraph here.

# THE ABSENCE HALF is not a `fact` — a `fact` asserts about a file's CONTENT, and there is no
# content to assert about a file that must not exist. Assert the path itself.
# `-e` alone is FALSE for a dangling symlink, so a `release` skill symlinked at a broken target
# would slip through — test for the link too.
forbid_path() {   # <path> <why>
  if [ -e "$1" ] || [ -L "$1" ]; then
    check_note "[no-release-skill] $1 exists — $2"
    check_note "[no-release-skill] #3 decided release execution stays project-owned. If that is"
    check_note "[no-release-skill] being reversed, update base/roles.md + docs/roles-and-agents.md"
    check_note "[no-release-skill] and this lint together — deliberately, not as a side effect."
    check_fail
  fi
}
forbid_path base/workflows/release.md "the baseline must not ship a generic release workflow"
# Glob, not a hardcoded `claude codex gemini` — this way a newly added agent tree is covered the day
# it lands. An unmatched glob stays literal, and neither -e nor -L is true of the literal, so "no
# agent trees" passes. (`set +f` at the top of this file is what keeps that true for a caller who
# invoked us with noglob: a literal pattern matching nothing would be a false GREEN, the one failure
# mode a policy lint must never have.)
for _rp in agents/*/skills/release; do
  forbid_path "$_rp" "no agent tree may carry a rendered release skill"
done

# THE PRESENCE HALF: every surface that carries the decision still carries it. `project-owned` is
# the decision itself; "no `/release`" is its concrete consequence. A doc that lost either one is a
# doc that would let a reader assume a release skill exists.
fact release-is-project-owned 'fixed:project-owned' -- \
  base/roles.md docs/roles-and-agents.md README.md
fact ships-no-release-skill 'fixed:no `/release`' -- \
  base/roles.md docs/roles-and-agents.md README.md
# The trap the role model must spell out: `[roles].release` is inert until a project skill RESOLVES
# it. Without this sentence a user sets `release = "codex"` and it is silently ignored.
fact release-role-must-be-resolved 'fixed:resolve release' -- \
  base/roles.md docs/roles-and-agents.md
# The manifest template is where most users meet the role — it must say the token picks an executor
# and installs nothing.
fact template-release-note 'fixed:installs no release skill' -- templates/agents.toml

# DISAMBIGUATION: `/new-release` is not `/release`. The name collision is the reported UX bug (#3).
# Asserted on the SOURCE only — build.sh substitutes only {{TOKEN}} placeholders (none of these
# tokens contain `{{`) and build-drift rebuilds + diffs every agent tree, so source-token +
# build-drift already implies rendered-token.
# NOTE the backticks in the token. A bare `/release` would also match `/releases/latest` in the
# `gh release view` prose further down that same workflow — so the note could be deleted entirely
# and the assertion would still pass. The backtick-delimited code span is what the disambiguation
# actually writes, and it appears nowhere else in the file.
fact new-release-names-the-other-command 'fixed:`/release`' -- base/workflows/new-release.md
fact new-release-points-at-the-owned-role 'fixed:project-owned' -- base/workflows/new-release.md

# THE EMIT CONTRACT: "the baseline ships no /release" is only safe because /roadmap lets a repo NAME
# its own release command and emits that. Losing that half turns the decision into a dead end — and
# since #188 the emission must also RESOLVE, because an unresolvable slash command does not fail
# loudly: Claude Code fuzzy-matches the nearest built-in, so a bare `/release` on a repo without one
# silently opens the CLI's release-notes viewer at the moment the roadmap says "cutting".
fact roadmap-release-command-override 'fixed:release-command' -- base/workflows/roadmap.md
fact roadmap-verifies-the-command-resolves 'fixed:RESOLVES' -- base/workflows/roadmap.md
fact convention-documents-override 'fixed:release-command' -- docs/release-goal-convention.md

# THE ROLLOVER BOUNDARY: `roll` is bookkeeping, never a cutter (#74/D8).
#
# #74 moved milestone rollover the OTHER way across the #3 line — out of the project-owned
# `/release` and into `baseline release roll` — because cutting has four incompatible shapes while
# rolling has exactly one. That makes `release-convention.sh` the single file in the repo with both
# a plausible reason and a plausible path to grow into the generic cutter #3 rejected: it already
# talks to the release milestones, so "while we're here, also tag it" reads like a feature rather
# than a reversal. The absence half above cannot catch that — a cutter grown INSIDE this helper
# ships no `release.md` and no skill directory, so every path check stays green.
#
# `absent:` OVER CODE, which is the narrow superseded-value use this file's header sanctions rather
# than a prose blocklist: the boundary is about what the code DOES, and a token grep over prose is
# the wrong instrument for it. Adding `git tag "$V"` to cmd_roll leaves every doc token intact and
# every positive rule green — verified, it did.
#
# `^[^#]*` IS THE COMMENT GUARD, and it replaces the `sed 's/#.*//'` pre-pass the retired file used.
# It is the same anchor the wiring rules above use and it means the same thing: the match must be
# reachable without passing a `#`, so this very file — and release-convention.sh's own header, which
# says in prose that roll never tags or publishes — cannot trip its own lint. The `(^|[^…])`
# alternation is what lets a match sit at column 0, where a bare `[^[:alnum:]_-]` prefix would
# consume the first character and match nothing (the anchor mistake this file has now made twice).
#
# SCOPE: this catches accidental GROWTH ("while we're already in the release milestone, also tag
# it"), which is the realistic failure. It is not an adversarial sandbox — indirection such as
# `"$GIT" tag` defeats it, and is meant to: someone hiding a cutter behind a variable has already
# decided to reverse #3, and the decision record governs that, not a grep.
#
# THE WITNESSES ARE HYPOTHETICAL, AND SAYING SO IS THE POINT. Everywhere else in this file a
# `fires:` witness is a verbatim superseded line, because there was one. Here there is not: the
# boundary has never been crossed, which is exactly why these six patterns went four releases
# without ever being observed firing. Each witness is therefore the realistic growth line for its
# own pattern, written in this file's own idiom — enough to prove the pattern can match and that
# `--mutation` drives it red, and no more. Same honesty as the `-u root` / `--user 0` branches of
# `wsl-smoke-nonroot-framework` above.
_roll_lib="scripts/lib/release-convention.sh"
fact roll-boundary-no-git \
  'absent:(^|^[^#]*[^[:alnum:]_-])git[[:space:]]+(tag|push)([^[:alnum:]_-]|$)' \
  'fires:  git tag -a "v$ROLL_VERSION" -m "release $ROLL_VERSION"' \
  'fires:  git push origin "v$ROLL_VERSION"' -- "$_roll_lib"
fact roll-boundary-no-gh-release \
  'absent:(^|^[^#]*[^[:alnum:]_-])gh[[:space:]]+release([^[:alnum:]_-]|$)' \
  'fires:  gh release create "v$ROLL_VERSION" --notes-file "$notes"' -- "$_roll_lib"
fact roll-boundary-no-package-publish \
  'absent:(^|^[^#]*[^[:alnum:]_-])(npm|pnpm|yarn|cargo|poetry)[[:space:]]+(version|publish)([^[:alnum:]_-]|$)' \
  'fires:  npm version "$ROLL_VERSION" --no-git-tag-version' \
  'fires:  cargo publish --allow-dirty' -- "$_roll_lib"
# The REALISTIC growth path is not the `gh release` porcelain — this file already does everything
# through `gh api`, so a cutter grown here would too. Forbid the REST endpoints that publish a
# release or create a tag ref, and the changelog surface, independent of which verb reaches them.
fact roll-boundary-no-releases-endpoint \
  'absent:^[^#]*/releases([^[:alnum:]_-]|$)' \
  'fires:  gh api --method POST "repos/$slug/releases" -f tag_name="v$ROLL_VERSION"' -- "$_roll_lib"
fact roll-boundary-no-tag-ref \
  'absent:^[^#]*refs/tags' \
  'fires:  gh api --method POST "repos/$slug/git/refs" -f ref="refs/tags/v$ROLL_VERSION"' -- "$_roll_lib"
fact roll-boundary-no-changelog \
  'absent:^[^#]*[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg]' \
  'fires:  printf %s "$notes" >> CHANGELOG.md' \
  'fires:  changelog_stamp "$ROLL_VERSION"' -- "$_roll_lib"
# POSITIVE half: the boundary is still STATED where a reader and an editor will meet it. One token,
# used verbatim in both files, so the claim cannot drift into two different wordings.
fact roll-declares-its-boundary 'fixed:milestone bookkeeping only' -- \
  scripts/lib/release-convention.sh docs/release-goal-convention.md

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
  # this file both dispatches to it and writes stray callers into --self-test fixtures) made the
  # invariant FALSE: a real direct call added to any of them would pass undetected, which
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
  # NUL-DELIMITED (#259, review finding). The newline-delimited form this replaces split any path
  # containing a newline into two fragments, both of which failed `[ -f ]` and were skipped — while
  # the OTHER files kept `_nscanned` above zero, so the emptiness guard below could not see it
  # either. A stray `req_absent` in such a file passed unread: a guard defeated by a filename.
  # `-print0` costs nothing here and closes it; the `./` strip stays, since `find .` still emits it.
  while IFS= read -r -d '' _sf; do
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
    #      at all. That match-nothing defect shipped here first and was caught by the
    #      `callsite-invariant` stray-caller case in --self-test.
    #   2. drop comment lines — suites legitimately discuss the helper in prose.
    #   3. drop lines carrying the sanctioned marker.
    _hit="$(grep -n "$_ra" "$_sf" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -Fv "$_allow")" || continue
    [ -n "$_hit" ] || continue
    _stray="${_stray}${ printf '%s\n' "$_hit" | sed "s@^@$_sf:@"; }${_FACT_NL}"
  done < <(find . -type f ! -path './.git/*' -print0)
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
