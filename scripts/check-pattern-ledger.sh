#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the pattern ledger (scripts/lib/pattern-ledger.sh, #421).
# OFFLINE: no network, no gh auth, no real repo touched, and the tracked tree is never mutated.
#
# THE ONE DANGEROUS DIRECTION IS REPORTING A CLASS AS RARER THAN IT IS. A count that is too low
# leaves a recurring defect unpromoted — which is the exact failure #421 exists to end — and it is
# INVISIBLE: an unpromoted class looks precisely like a class nobody has hit twice. So the cases
# below are weighted toward every way a hit could be silently dropped, and none of them can be
# satisfied by a read that merely returned something.
#
# Every case here is a way that could happen:
#
#   1. THE COUNT IS THE PRODUCT, so the threshold boundary is asserted from BOTH sides: one hit is
#      not due, two hits are. Off by one in either direction breaks the mechanism — too eager
#      promotes an incident, too lax never promotes at all.
#   2. RECURRENCE IS KEYED ON THE THREAD ID, and exactly-once matters because the resolver records
#      BEFORE it resolves and may legitimately be re-run over the same pull request. A second
#      record of one thread must be a no-op (10), and a hand-edited duplicate must be a defect (18)
#      — the same id counted twice inflates a class toward a promotion nothing earned.
#   3. A DAMAGED LEDGER IS REFUSED WHOLE, never counted in part. A truncated hits region is the
#      shape that reports fewer hits than exist while looking completely normal, so every reader —
#      `classes`, `due`, `stats`, `verify` AND `checklist` — must answer 18 rather than a number.
#      `checklist` is included deliberately: its region can be intact while the other is not, and a
#      read side that proceeds on a file the write side would reject is the quiet version of this
#      bug.
#   4. THE PROMPT SURFACE CARRIES NO THIRD-PARTY TEXT. `checklist` is the only output that reaches
#      another agent, and a reviewer's summary is written by anyone with a GitHub account. It is
#      asserted to emit rules and to emit NO summary, site or sha — a containment property, so it
#      is tested by looking for what must be absent.
#   5. NO FIELD MAY FORGE A RECORD. A backtick moves a parsed field; a newline or tab forges a
#      record; `<!-- adb:` closes a region and truncates everything after it. Each is rejected at
#      write time and the ledger is asserted UNCHANGED afterwards, because "it printed an error"
#      and "it wrote nothing" are different claims.
#   6. THE THRESHOLD IS CONFIGURABLE AND FAILS LOUD. A malformed `[patterns] threshold` is a hard
#      error, never a silent fall-back to the built-in — the same rule pr-watch.sh applies to
#      `max_rounds`, and for the same reason: this number decides whether a recurring defect is
#      ever swept for.
#
# `--mutation` drives the cases that are GUARDS against deliberately broken copies of the library
# and requires each to come back RED on its OWN witness (#213's `fires:` contract, #394's
# precedent): a guard's failure mode is silence, and these guards protect a count.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-pattern-ledger.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, before both `set -u` and the cd. See check-pr-threads.sh's
# header for why each of those orderings is load-bearing.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-pattern-ledger: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-pattern-ledger: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -gt 1 ] && { echo "usage: check-pattern-ledger.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-pattern-ledger.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
check_exit_guard "check-pattern-ledger" "rm -rf \"$work\""
check_init check-pattern-ledger

PL="$ROOT/scripts/lib/pattern-ledger.sh"

# A ledger seeded with <n> hits of one class. Every fixture builds through the REAL `record`, so a
# fixture can never encode a shape the writer would refuse — which is how a suite ends up proving
# the parser against records the writer cannot produce.
seed() {   # <ledger> <class> <n> [pr]
  local l="$1" c="$2" n="$3" pr="${4:-100}" i rc
  for (( i = 1; i <= n; i++ )); do
    bash "$PL" record --ledger "$l" --class "$c" --site "s$i.sh:$i" \
      --fix "$(printf 'abc123%d' "$i")" --pr "$pr" --thread "T-${c}-${i}" \
      --summary "hit $i of $c" --date 2026-08-24 >/dev/null 2>&1; rc=$?
    # 10 IS SUCCESS HERE. `record` is keyed on the thread id, so re-seeding a class to a higher
    # count legitimately re-offers the hits already present — which is exactly what the resolver
    # does on a re-run. A bare `|| return 1` treated that no-op as a fixture failure and returned
    # BEFORE writing the new hit, so `seed <class> 2` silently produced one hit and every
    # threshold assertion below tested the wrong number.
    case "$rc" in 0|10) ;; *) return 1 ;; esac
  done
}

# ============================= --mutation: the guards must be seen RED ===========================
# Each row breaks ONE property of the library and requires the FULL suite below to notice. Written
# first so the file reads in the order a reader needs: the guards, then what they guard.
if [ "$MODE" = mutation ]; then
  # The threshold comparison inverted: `due` would then offer classes BELOW the threshold and
  # withhold the ones at it. Promotion is the mechanism's whole output, so this is the row that
  # matters most.
  check_mut threshold-inverted \
    '[ "$n" -ge "$t" ] || continue' \
    '[ "$n" -lt "$t" ] || continue' \
    'two hits reach the threshold'

  # Dedupe disabled: re-recording one thread would append a second hit, and a class would climb to
  # a promotion on one finding counted twice.
  check_mut dedupe-disabled \
    "if printf '%s\\n' \"\$hits\" | awk -F'\\t' -v t=\"\$OPT_THREAD\" '\$4 == t { found = 1 } END { exit !found }'; then" \
    "if false; then" \
    'a repeated thread id is a no-op'

  # The region-completeness proof disabled: a truncated hits region would then read as a SHORTER
  # ledger instead of an error — the count-too-low direction, wearing a clean run's face.
  check_mut region-proof-disabled \
    'END { if (nb != 1 || ne != 1 || crossed || inb) exit 1 }' \
    'END { if (0) exit 1 }' \
    'a truncated hits region is refused'

  # The record-grammar check disabled: a line that is not a record would be SKIPPED rather than
  # failing the read, which is the same silent undercount by another route.
  check_mut grammar-check-disabled \
    'if (NF < 9)             { bad = 1; exit }' \
    'if (NF < 9)             { next }' \
    'a malformed hit record is refused'

  # `checklist` stops asking about the hits region: its own region can be perfectly well-formed, so
  # this mutation is invisible to every assertion except the one written for it.
  check_mut checklist-half-read \
    '  _adb_pl_hits "$ledger" >/dev/null \' \
    '  true >/dev/null \' \
    'checklist refuses a half-readable ledger'

  # The summary's containment broken: a reviewer's free text would ride into the prompt surface.
  check_mut checklist-leaks-summary \
    "  printf '%s\\n' \"\$region\" | awk 'NF { print }'" \
    "  printf '%s\\n' \"\$region\" | awk 'NF { print }'; _adb_pl_hits \"\$ledger\" | cut -f2" \
    'checklist emits no site'

  # Region-marker injection accepted: a summary could close the hits region and truncate every
  # record after it.
  check_mut marker-injection-allowed \
    "  case \"\$1\" in *'<!-- adb:'*) return 1 ;; esac" \
    "  case \"\$1\" in *'ZZQQ-never-appears'*) return 1 ;; esac" \
    'a region marker in a summary is refused'

  # A malformed declared threshold silently becomes the built-in: the operator's configured number
  # is then a fiction, and nothing says so.
  # THE FALL-BACK, not the message. An earlier version of this row deleted the diagnostic and
  # left `return 2` standing — so the reader still failed, the suite still went red, but on the
  # assertion about WORDING rather than the one about BEHAVIOUR. `break` is the defect that
  # matters: the loop abandons the malformed value and falls through to the built-in, handing the
  # operator a threshold they did not choose, from a file they thought they had configured.
  check_mut bad-threshold-silent \
    '      return 2' \
    '      break' \
    'a malformed [patterns] threshold is a hard error'

  # <copy-dir> -> PRINT the path to mutate, nothing else (check_mutation_pool's contract).
  # `base` rides along because the call-site assertions below read the workflow sources; without
  # it every mutation child would fail on a missing file rather than on its own witness.
  # THE READ-SIDE VALIDATION ITSELF. It was added because the independent review reproduced a
  # false promotion from a duplicated thread id; without a row here, deleting it again would be
  # invisible to every assertion except by accident.
  check_mut reader-skips-validation \
    '    _adb_pl_ok_class  "$c"  || return 1' \
    '    :' \
    'a hand-edited invalid class (BadClass) is refused by the readers'

  check_mut reader-skips-dupes \
    '    [ -z "${seen[$th]+x}" ] || return 1' \
    '    :' \
    'a duplicated thread id is refused by `due`, not only by verify'

  # THE PR REQUIREMENT (PR #429). Reverting it to the optional-if-present form is the exact
  # regression, so the row spells that form rather than deleting the check.
  check_mut pr-optional-again \
    '    _adb_pl_ok_pr "$pr" || return 1' \
    '    [ -z "$pr" ] || _adb_pl_ok_pr "$pr" || return 1' \
    'a hit with no PR segment is refused by `classes`'

  # THE CHECKLIST RULE BODY (PR #429). Without it a class name with no instruction reaches the
  # prompt surface, which is where an empty rule is invisible.
  check_mut checklist-body-unchecked \
    '      if (rest == "") { bad = 1; exit }' \
    '      if (0) { bad = 1; exit }' \
    'a checklist rule with no instruction text is refused by `checklist`'

  prep() {
    check_copy_subtrees "$ROOT" "$1/tree" scripts base >/dev/null 2>&1 || return 1
    printf '%s\n' "$1/tree/scripts/lib/pattern-ledger.sh"
  }
  runner() { ( cd "$1/tree" && bash scripts/check-pattern-ledger.sh 2>&1 ); }

  check_mutation_pool check-pattern-ledger "$work" prep runner 6
  check_summary check-pattern-ledger
  exit 0
fi

# =============================== 1. the threshold boundary, both sides ===========================
# The mechanism's entire output is "which classes earned a rule", so the boundary is asserted from
# below and from on it. #421 fixes the meaning — "default 2 — a pattern, not an incident" — so ONE
# hit is an incident and TWO make a pattern.
L1="$work/l1.md"
seed "$L1" one-class 1 || bad "fixture: could not seed one hit"
bash "$PL" due --ledger "$L1" >/dev/null 2>&1
eq "$?" 11 "one hit is an incident, not a pattern — nothing is due"

seed "$L1" one-class 2 >/dev/null 2>&1   # T-one-class-1 repeats (no-op), -2 is new
DUE="$(bash "$PL" due --ledger "$L1" 2>/dev/null)"; DRC=$?
eq "$DRC" 0 "two hits reach the threshold"
has "$DUE" "one-class" "the due list names the class that reached it"

# The count is what `due` reports, and it must be the real one — a class listed with the wrong
# count would promote on a number nobody can reconcile with the file.
eq "$(printf '%s' "$DUE" | awk -F'\t' '{print $2}')" 2 "due reports the class's actual hit count"

# A configured threshold moves the boundary, and the source is reported so an operator can tell
# which layer set it.
eq "$(bash "$PL" due --ledger "$L1" --threshold 3 >/dev/null 2>&1; echo $?)" 11 \
   "a higher configured threshold withholds a class that met the built-in one"
eq "$(bash "$PL" threshold --ledger "$L1" | awk '{print $1}')" 2 "the built-in threshold is 2"
eq "$(bash "$PL" threshold --ledger "$L1" | awk '{print $2}')" built-in "…and it says which layer supplied it"

# =============================== 2. exactly-once, keyed on the thread ============================
# The resolver records BEFORE it resolves, so a re-run over the same pull request re-offers hits
# that are already present. That is the ORDINARY case and must be a no-op, not a failure and above
# all not a second hit.
L2="$work/l2.md"
seed "$L2" dupe-class 1 || bad "fixture: could not seed"
bash "$PL" record --ledger "$L2" --class dupe-class --site other.sh:9 --fix ffff000 \
  --pr 100 --thread T-dupe-class-1 --date 2026-08-24 >/dev/null 2>&1
eq "$?" 10 "a repeated thread id is a no-op"
eq "$(bash "$PL" stats --ledger "$L2" | awk -F'\t' '$1=="hits"{print $2}')" 1 \
   "…and it appended nothing — the class did not climb toward a promotion it never earned"

# A hand-edited duplicate is a DEFECT, because `record` cannot produce one: two branches merging
# the same record, or an edit, inflates the count above the number of findings that happened.
awk '{print} /^- `dupe-class`/ && !d {print; d=1}' "$L2" > "$work/l2-dup.md"
# EVERY READER, not just `verify`. With the check only in `verify`, the independent review
# reproduced `due` reporting `dup-class<TAB>2` and exit 0 on this exact file — a class carried to a
# promotion by one finding counted twice, while `verify` said 18. A validator nothing consults
# before acting is a validator that does not protect the count.
for sub in classes due stats checklist verify promote; do
  case "$sub" in
    promote) bash "$PL" promote --ledger "$work/l2-dup.md" --class dupe-class --rule x >/dev/null 2>&1 ;;
    *)       bash "$PL" "$sub" --ledger "$work/l2-dup.md" >/dev/null 2>&1 ;;
  esac
  eq "$?" 18 "a duplicated thread id is refused by \`$sub\`, not only by verify"
done

# The same argument for a hand-edited field OUTSIDE the writer's grammar. `record` cannot produce
# any of these, so each one means the file was edited or merged badly — and each must stop every
# reader rather than being counted.
for bad in 'BadClass' '9leading' '-leading'; do
  sed "s/^- \`dupe-class\`/- \`$bad\`/" "$L2" > "$work/l2-badclass.md"
  bash "$PL" classes --ledger "$work/l2-badclass.md" >/dev/null 2>&1
  eq "$?" 18 "a hand-edited invalid class ($bad) is refused by the readers, not only by verify"
done
sed 's/`abc1231`/`zzz`/' "$L2" > "$work/l2-badfix.md"
bash "$PL" due --ledger "$work/l2-badfix.md" >/dev/null 2>&1
eq "$?" 18 "a hand-edited invalid fix sha is refused by the readers"
sed 's/PR #100/PR #0/' "$L2" > "$work/l2-badpr.md"
bash "$PL" classes --ledger "$work/l2-badpr.md" >/dev/null 2>&1
eq "$?" 18 "a hand-edited PR number outside the domain is refused by the readers"

# A MISSING PR SEGMENT IS THE SAME ANSWER AS AN INVALID ONE (PR #429). The raw parser emits an
# empty field for it, and permitting that let the hit count toward promotion while `stats --pr`
# omitted it — a per-PR figure lower than the records actually attributable to that run, from a
# record `record` could never have produced. `verify` is asserted alongside the readers because a
# validator that disagrees with them is how the original defect stayed invisible.
sed 's/ PR #100 / /' "$L2" > "$work/l2-nopr.md"
for sub in classes due stats checklist verify; do
  bash "$PL" "$sub" --ledger "$work/l2-nopr.md" >/dev/null 2>&1
  eq "$?" 18 "a hit with no PR segment is refused by \`$sub\`"
done

# `verify` still NAMES the offending record, which is why it reads through the raw parser: a
# validator that only said "does not parse" would leave the operator hunting the line by hand.
V2="$(bash "$PL" verify --ledger "$work/l2-dup.md" 2>&1)"
has "$V2" "duplicate thread id" "verify still names WHAT is wrong, not merely that something is"

# =============================== 3. a damaged ledger is refused WHOLE ============================
# The truncated-region shape is the dangerous one: it reports FEWER hits than exist and looks
# exactly like a smaller project. Every reader must refuse it — a number here is worse than an
# error, because a number gets believed.
L3="$work/l3.md"
seed "$L3" trunc-class 2 || bad "fixture: could not seed"
bash "$PL" promote --ledger "$L3" --class trunc-class --rule 'sweep the siblings' >/dev/null 2>&1

sed 's/<!-- adb:hits:begin -->//' "$L3" > "$work/l3-cut.md"
for sub in classes due stats verify; do
  bash "$PL" "$sub" --ledger "$work/l3-cut.md" >/dev/null 2>&1
  eq "$?" 18 "a truncated hits region is refused by \`$sub\`"
done
# `checklist` is the one whose OWN region is untouched here, so nothing but this assertion covers
# it — and it is the read side, which must not proceed on a file the write side would reject.
bash "$PL" checklist --ledger "$work/l3-cut.md" >/dev/null 2>&1
eq "$?" 18 "checklist refuses a half-readable ledger"

# THE CHECKLIST REGION IS THE OTHER HALF, and it fails in the opposite direction from the hits
# region — a reader that lost it would report FEWER promoted rules, i.e. sweep less than the
# project asked for. Every reader must refuse that too, `stats` included: its promoted count was a
# pipeline whose `$?` is its last command's, so it surfaced the failure only because this file sets
# `pipefail`. Asserted so the two-statement form cannot quietly regress to the one-liner.
sed 's/<!-- adb:checklist:begin -->//' "$L3" > "$work/l3-ck.md"
for sub in classes stats verify checklist due; do
  bash "$PL" "$sub" --ledger "$work/l3-ck.md" >/dev/null 2>&1
  eq "$?" 18 "a truncated checklist region is refused by \`$sub\`"
done
sed 's/^- `trunc-class` — .*/- no code span here/' "$L3" > "$work/l3-rule.md"
bash "$PL" checklist --ledger "$work/l3-rule.md" >/dev/null 2>&1
eq "$?" 18 "a checklist rule that is not in the grammar is refused"

# A record that is not in the grammar must FAIL the read, never be skipped: skipping is the same
# undercount by another route.
sed 's/^- `trunc-class` `s2.sh:2`.*/- this is not a record/' "$L3" > "$work/l3-bad.md"
bash "$PL" classes --ledger "$work/l3-bad.md" >/dev/null 2>&1
eq "$?" 18 "a malformed hit record is refused"

# `record` will not append to a ledger whose existing records it cannot read — appending would
# build on a count it never established.
bash "$PL" record --ledger "$work/l3-cut.md" --class x-class --site a.sh --fix abc1234 \
  --pr 1 --thread T-new >/dev/null 2>&1
eq "$?" 18 "record refuses to append to a ledger that does not parse"

# A CHECKLIST RULE MUST CARRY INSTRUCTION TEXT (PR #429). ``- `class` `` splits into three
# backtick fields with an empty third, so a count-only test accepted it — and `checklist` then fed
# a class name with NO instruction into the gap-analysis and self-review prompts, silently dropping
# the sweep that class had earned. The prompt surface is exactly where an empty rule is invisible.
seed "$L3" ruleless 2 >/dev/null 2>&1
bash "$PL" promote --ledger "$L3" --class ruleless --rule 'sweep the siblings too' >/dev/null 2>&1
# ANCHORED ON THE SEPARATOR, so it strikes ONLY the checklist rule. `^- \`ruleless\` .*` also
# matches this class's HIT lines, which begin identically — the first draft did that, destroyed the
# hits region, and the assertions below then passed for the wrong reason: 18 came from the hits
# region being unreadable, so the mutation that disables the rule-body check stayed GREEN. A hit's
# second field is a code span; a rule's is the separator, and that is what tells them apart.
sed 's/^- `ruleless` —.*/- `ruleless`/' "$L3" > "$work/l3-norule.md"
for sub in checklist verify classes; do
  bash "$PL" "$sub" --ledger "$work/l3-norule.md" >/dev/null 2>&1
  eq "$?" 18 "a checklist rule with no instruction text is refused by \`$sub\`"
done
# …and a well-formed rule is still emitted, so the check is not simply refusing everything.
CKOK="$(bash "$PL" checklist --ledger "$L3" 2>/dev/null)"
has "$CKOK" "sweep the siblings too" "a well-formed rule still reaches the prompt surface"

# =============================== 4. the prompt surface carries no free text ======================
# `checklist` is the ONLY output that reaches another agent's prompt. A hit's summary is a
# reviewer's own words and on a public repository a reviewer is anyone; a promoted rule got there
# by merging through review. This is a CONTAINMENT property, so it is asserted by what must be
# ABSENT — a test that only checked the rule was present would pass on an implementation that
# emitted the rule and the whole hit history beside it.
L4="$work/l4.md"
bash "$PL" record --ledger "$L4" --class leak-class --site 'secret/path.sh:42' --fix aaaa111 \
  --pr 100 --thread T-leak-1 --summary 'REVIEWER-FREE-TEXT-MARKER' --date 2026-08-24 >/dev/null 2>&1
bash "$PL" record --ledger "$L4" --class leak-class --site 'second/path.sh:7' --fix bbbb222 \
  --pr 100 --thread T-leak-2 --summary 'another reviewer sentence' --date 2026-08-24 >/dev/null 2>&1
bash "$PL" promote --ledger "$L4" --class leak-class --rule 'sweep every call site' >/dev/null 2>&1
CK="$(bash "$PL" checklist --ledger "$L4" 2>/dev/null)"
has   "$CK" "sweep every call site"        "checklist emits the promoted rule"
has   "$CK" "leak-class"                   "…named by its class"
hasnt "$CK" "REVIEWER-FREE-TEXT-MARKER"    "checklist emits no summary (a reviewer's words never reach a prompt)"
hasnt "$CK" "secret/path.sh"               "checklist emits no site"
hasnt "$CK" "aaaa111"                      "checklist emits no fix sha"

# =============================== 5. no field may forge a record ==================================
# Each rejection asserts TWO things: the write was refused, and the ledger is UNCHANGED. "It
# printed an error" and "it wrote nothing" are different claims, and only the second one protects
# the count.
L5="$work/l5.md"
seed "$L5" guard-class 1 || bad "fixture: could not seed"
BEFORE="$(cksum < "$L5")"

refused() {   # <label> <expected-rc> <record-args…>
  local label="$1" want="$2"; shift 2
  bash "$PL" record --ledger "$L5" "$@" >/dev/null 2>&1
  eq "$?" "$want" "$label"
  eq "$(cksum < "$L5")" "$BEFORE" "$label — and the ledger is untouched"
}
NLV="$(printf 'a\nb')"
refused "a newline in --site is refused"          19 --class guard-class --site "$NLV"  --fix abc1234 --pr 1 --thread T-g1
refused "a backtick in --site is refused"         19 --class guard-class --site 'a`b'   --fix abc1234 --pr 1 --thread T-g2
refused "an uppercase class is refused"           19 --class BadClass    --site a.sh    --fix abc1234 --pr 1 --thread T-g3
refused "a class not starting with a letter"      19 --class 9bad        --site a.sh    --fix abc1234 --pr 1 --thread T-g4
refused "a too-short fix sha is refused"          19 --class guard-class --site a.sh    --fix abc     --pr 1 --thread T-g5
refused "a non-hex fix sha is refused"            19 --class guard-class --site a.sh    --fix zzzzzzz --pr 1 --thread T-g6
refused "a thread id with a space is refused"     19 --class guard-class --site a.sh    --fix abc1234 --pr 1 --thread 'a b'
refused "a non-numeric --pr is refused"           19 --class guard-class --site a.sh    --fix abc1234 --pr x --thread T-g7
# ZERO IS NOT POSITIVE, and the diagnostic has always said "positive". A predicate that accepts a
# value its own message forbids is a contract nobody can rely on.
refused "--pr 0 is refused"                      19 --class guard-class --site a.sh    --fix abc1234 --pr 0 --thread T-g0
refused "--pr 00 is refused too"                 19 --class guard-class --site a.sh    --fix abc1234 --pr 00 --thread T-g00
# THE INJECTION THAT MATTERS: a summary carrying a region marker would CLOSE the hits region and
# make every record after it invisible — the count-too-low direction, caused by a reviewer's text.
refused "a region marker in a summary is refused" 19 --class guard-class --site a.sh --fix abc1234 \
        --pr 1 --thread T-g8 --summary 'x <!-- adb:hits:end --> y'

# A backtick IS legal in a summary, and that is not an oversight: it sits after every parsed field,
# so it cannot move one, and review findings routinely quote identifiers. Asserted so a future
# tightening has to be deliberate rather than incidental.
bash "$PL" record --ledger "$L5" --class guard-class --site ok.sh --fix ccc3333 --pr 1 \
  --thread T-g9 --summary 'the `helper` compared two ways' --date 2026-08-24 >/dev/null 2>&1
eq "$?" 0 "a backtick in a SUMMARY is accepted — it cannot move a parsed field"
eq "$(bash "$PL" classes --ledger "$L5" | awk -F'\t' '$2=="guard-class"{print $1}')" 2 \
   "…and the record it wrote still parses to the right class"

# =============================== 6. the threshold declaration fails loud =========================
# A malformed configured value is a hard error, never a silent fall-back. Falling back hands the
# operator a threshold they did not choose from a file they thought they had configured — and this
# number decides whether a recurring defect is ever swept for at all.
MHOME="$work/home"; mkdir -p "$MHOME/.config/ai-dev-baseline"
printf '[patterns]\nthreshold = 3\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
eq "$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" | awk '{print $1}')" 3 \
   "a global [patterns] threshold is honoured"
eq "$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" | awk '{print $2}')" global \
   "…and the source names the layer it came from"
printf '[patterns]\nthreshold = "six"\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
OUT="$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" 2>&1)"; RC=$?
no "$RC" "a malformed [patterns] threshold is a hard error"
has "$OUT" "positive whole number" "…and it names the domain rather than silently using the built-in"

# =============================== 7. promote's own preconditions ==================================
L7="$work/l7.md"
seed "$L7" promo-class 1 || bad "fixture: could not seed"
bash "$PL" promote --ledger "$L7" --class promo-class --rule 'too early' >/dev/null 2>&1
eq "$?" 12 "promoting below the threshold is refused"
seed "$L7" promo-class 2 >/dev/null 2>&1
bash "$PL" promote --ledger "$L7" --class promo-class --rule 'sweep it' >/dev/null 2>&1
eq "$?" 0 "promoting at the threshold succeeds"
bash "$PL" promote --ledger "$L7" --class promo-class --rule 'again' >/dev/null 2>&1
eq "$?" 13 "promoting a class that already has a rule is refused"
bash "$PL" due --ledger "$L7" >/dev/null 2>&1
eq "$?" 11 "a promoted class is no longer due"
eq "$(bash "$PL" classes --ledger "$L7" | awk -F'\t' '$2=="promo-class"{print $3}')" 1 \
   "classes marks the promoted class"

# =============================== 8. stats, and what `recurring` counts ===========================
# `recurring` is HITS IN CLASSES AT OR OVER THE THRESHOLD, not the number of such classes. That
# distinction is the whole reported signal: classes accumulate forever, while a repeat hit in a
# class this project already knows about is the avoidable one. A fixture with 3+1 makes the two
# readings differ (3 vs 1), so the assertion can tell them apart.
L8="$work/l8.md"
seed "$L8" recur-class 3 200 || bad "fixture: could not seed"
seed "$L8" solo-class  1 201 || bad "fixture: could not seed"
S="$(bash "$PL" stats --ledger "$L8" --pr 200)"
eq "$(printf '%s' "$S" | awk -F'\t' '$1=="hits"{print $2}')"      4 "stats counts every hit"
eq "$(printf '%s' "$S" | awk -F'\t' '$1=="classes"{print $2}')"   2 "stats counts distinct classes"
eq "$(printf '%s' "$S" | awk -F'\t' '$1=="recurring"{print $2}')" 3 \
   "recurring counts HITS in at-threshold classes (3), not the number of such classes (1)"
eq "$(printf '%s' "$S" | awk -F'\t' '$1=="pr-hits"{print $2}')"   3 "stats scopes to one PR when asked"

# `pr-recurring` IS THE ROUND FIGURE; `recurring` IS NOT (PR #429). The ledger is append-only, so
# the lifetime count can only ever rise — and it jumps by every prior hit the moment a class
# crosses the threshold. A summary quoting it would print a number that grows whatever the round
# did, which is the opposite of the trend #421 says makes the mechanism falsifiable. The fixture
# makes the two differ: 3 recurring hits in PR 200, 1 in PR 202, lifetime 4.
# RECORDED DIRECTLY, not via `seed`: that helper derives its thread id from <class>-<index>, so
# `seed recur-class 1 202` re-offers `T-recur-class-1`, which is already present and correctly
# dedupes to a no-op — adding nothing and leaving the assertion below testing the old fixture.
bash "$PL" record --ledger "$L8" --class recur-class --site other.sh:1 --fix aaa1111 \
  --pr 202 --thread T-recur-class-in-202 --date 2026-08-24 >/dev/null 2>&1
S2="$(bash "$PL" stats --ledger "$L8" --pr 202)"
eq "$(printf '%s' "$S2" | awk -F'\t' '$1=="recurring"{print $2}')"    4 \
   "lifetime recurring counts every hit in an at-threshold class"
eq "$(printf '%s' "$S2" | awk -F'\t' '$1=="pr-recurring"{print $2}')" 1 \
   "…while pr-recurring counts only this PR's — the figure a round trend can be read from"
S3="$(bash "$PL" stats --ledger "$L8" --pr 200)"
eq "$(printf '%s' "$S3" | awk -F'\t' '$1=="pr-recurring"{print $2}')" 3 \
   "…and it differs per PR, which a lifetime count never could"
# The solo class sits in PR 201 and is below the threshold, so it appears in neither figure.
S4="$(bash "$PL" stats --ledger "$L8" --pr 201)"
eq "$(printf '%s' "$S4" | awk -F'\t' '$1=="pr-hits"{print $2}')"      1 "the solo class's PR has a hit"
eq "$(printf '%s' "$S4" | awk -F'\t' '$1=="pr-recurring"{print $2}')" 0 \
   "…but a below-threshold class contributes nothing to pr-recurring"

# An absent ledger is zero, and it says so rather than failing: a project on its first run has not
# broken anything. A ledger that could not be READ is a different fact and is 18 (asserted above).
eq "$(bash "$PL" stats --ledger "$work/nope.md" | awk -F'\t' '$1=="hits"{print $2}')" 0 \
   "an absent ledger reports zero hits, not an error"
eq "$(bash "$PL" classes --ledger "$work/nope.md" >/dev/null 2>&1; echo $?)" 0 \
   "…and classes is empty-but-successful, since a first run has nothing wrong with it"

# =============================== 9. verify reports what it CHECKED ===============================
# A validator that scanned zero records prints what one that scanned forty prints. The count is
# what tells them apart (base/practices/self-review.md).
V="$(bash "$PL" verify --ledger "$L8" 2>&1)"
# FIVE, because the pr-recurring fixture above added a fourth hit of `recur-class` in PR 202.
# The number is the point of the assertion — a validator that scanned zero prints what one that
# scanned forty prints — so it tracks the fixture rather than being loosened to a wildcard.
has "$V" "5 hit(s)" "verify says how many records it actually checked"
has "$V" "checklist rule(s) checked" "…and how many rules"

# =============================== 10. the call sites are wired ===================================
# A library nothing calls is a library that cannot help. These pin the wiring in the SOURCES —
# base/workflows/, not the rendered skills, because the sources are what a change edits and the
# build is separately drift-checked.
RES=base/workflows/resolve-pr-threads.md
IMP=base/workflows/implement-issue.md
for f in "$RES" "$IMP"; do
  [ -f "$f" ] || bad "missing workflow source $f"
done
has "$(cat "$RES")" '{{PATTERN_LEDGER_LIB}} record'    "the resolver records a hit per fixed thread (#421 write side)"
has "$(cat "$RES")" '{{PATTERN_LEDGER_LIB}} due'       "…and asks what has become a pattern"
has "$(cat "$RES")" '{{PATTERN_LEDGER_LIB}} promote'   "…and promotes it through a tracked file"
has "$(cat "$RES")" '{{PATTERN_LEDGER_LIB}} stats'     "…and reports the trend the mechanism is judged by"

# THE PER-THREAD FIX SHA (PR #429). Step 4 permits several commits in one round, so `$LAST_SHA` —
# captured once, after the push — names the LAST of them. Recording every thread against it breaks
# the audit link the ledger exists for: `git show <fix>` would not contain the correction the entry
# points at.
RESTXT="$(cat "$RES")"
has   "$RESTXT" '--fix "$FIX_SHA"' "the resolver records each thread against ITS OWN fix commit"
hasnt "$RESTXT" '--fix "$LAST_SHA"' "…never against the round's head sha"
has   "$RESTXT" 'FIX_SHA="$(git rev-parse --short HEAD)"' "…and says how to capture it, per commit"

# THE ROUND FIGURE IS THE PR-SCOPED ONE. `recurring` is a lifetime count over an append-only file,
# so a summary quoting it prints a number that grows whatever the round did.
has "$RESTXT" 'pr-recurring' "the summary reports pr-recurring, the figure a trend can be read from"

# THE RECOVERY HINT MUST NAME A COMMAND THAT EXISTS. The first draft pointed at
# `baseline patterns verify`, which no dispatcher implements — handing the operator an unknown
# command at exactly the moment they need a working diagnostic.
IMPTXT2="$(cat "$IMP")"
has   "$IMPTXT2" '{{PATTERN_LEDGER_LIB}} verify' "the malformed-ledger path invokes the real verifier"
hasnt "$IMPTXT2" 'baseline patterns verify'      "…and not a CLI subcommand nothing implements"
has "$(cat "$IMP")" '{{PATTERN_LEDGER_LIB}} checklist' "/implement-issue reads the checklist back (#421 read side)"
# BOTH read sites, separately. One `checklist` call would satisfy a single `has`, and the two ends
# are different claims: the gap dispatch acts before the code exists, the self-review after.
eq "$(grep -c '{{PATTERN_LEDGER_LIB}} checklist' "$IMP")" 2 \
   "…at BOTH ends — the gap-analysis dispatch and the self-review sweep"

# The ledger must NOT be swept as run debris: it is durable project history, and /cleanup only
# enumerates files under the state directory.
hasnt "$(cat base/workflows/cleanup.md)" 'patterns.md' \
  "/cleanup does not sweep the pattern ledger — it is project history, not run state"

# …and adoption must SEE it. A file nobody names in the scan is not classified `other`, it is
# invisible, which satisfies neither reading of #421's acceptance criterion.
eq "$(bash "$ROOT/scripts/lib/adopt-lib.sh" prescribed patterns patterns.md >/dev/null 2>&1; echo $?)" 0 \
   "/adopt knows the pattern ledger is a prescribed home"
has "$(bash "$ROOT/scripts/lib/adopt-lib.sh" classify patterns yes same yes | cut -f1)" keep \
   "…and classifies it keep, never proposing an adopting project delete its own learned classes"

check_summary check-pattern-ledger
