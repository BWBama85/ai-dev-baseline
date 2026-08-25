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
  # RETARGETED for the same reason: `return 2` is now shared with the complete-scalar guard, and
  # the first occurrence is that one. The DOMAIN test is what this row is about.
  # WITNESS UPDATED: `"six"` is now caught by the complete-scalar grammar before the domain check
  # ever sees it, so the old witness no longer belongs to this row. What the DOMAIN check uniquely
  # owns is a syntactically perfect value outside the domain — thirteen digits.
  check_mut bad-threshold-silent \
    '    if ! _adb_pl_ok_pr "$v"; then' \
    '    if false; then' \
    'a syntactically valid but out-of-domain threshold is still a hard error'

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
  # RETARGETED after the suffix grammar landed: a MISSING `PR #<n>` segment is now caught by the
  # suffix check before the field validator sees it, so the old "optional if present" mutation
  # became invisible — the harness reported it staying green, which is the harness working on its
  # own table. What the field check still uniquely owns is the DOMAIN: `PR #0` satisfies the
  # suffix grammar and must still be refused.
  check_mut pr-domain-unchecked \
    '    _adb_pl_ok_pr "$pr" || return 1' \
    '    :' \
    'a hand-edited PR number outside the domain is refused by the readers'

  # THE AWK-SIDE EMPTY-RULE CHECK HAS NO ROW ANY MORE. Once `_adb_pl_ok_text` validated the rule
  # text on the shell side, an empty rule was refused there too — so disabling the awk test changed
  # no behaviour and the row stayed GREEN, which the harness reported. The empty case is now
  # covered by `rule-text-unchecked` below, which mutates the check that actually decides it.

  # RECORD MUST VALIDATE BOTH REGIONS (PR #429).
  check_mut record-checks-one-region \
    '  _adb_pl_promoted "$ledger" >/dev/null || { printf '"'"'pattern-ledger: %s does not parse (the checklist region) — refusing to append to a ledger every reader would then refuse\n'"'"' "$ledger" >&2; exit 18; }' \
    '  :' \
    'record refuses a ledger whose CHECKLIST region is damaged, not just its hits'

  # VERIFY MUST AGREE WITH THE READERS ABOUT A DUPLICATED CHECKLIST CLASS (PR #429).
  check_mut verify-misses-dup-class \
    '    ckdupes="$(printf '"'"'%s\n'"'"' "$promoted" | awk -F'"'"'\t'"'"' '"'"'NF { print $1 }'"'"' | LC_ALL=C sort | LC_ALL=C uniq -d)"' \
    '    ckdupes=""' \
    'a duplicated checklist class is refused by `verify` — verify included'

  # THE MULTI-LINE PROMOTED LIST (PR #429, found by dogfooding). Restores the `-v` spelling, which
  # is what shipped and what a later edit would reach for again.
  check_mut promoted-list-via-v \
    'ADB_PL_PROM="$promoted" awk -F'"'"'\t'"'"' -v TAB="$TAB"' \
    'awk -F'"'"'\t'"'"' -v TAB="$TAB" -v ADB_PL_PROM_UNUSED="$promoted" -v prom="$promoted"' \
    'classes survives a SECOND promoted class'

  # THE ABSENT/PRESENT DISTINCTION (PR #429).
  check_mut absent-indistinguishable \
    "    printf 'ledger\\tabsent\\n'" \
    "    printf 'ledger\\tpresent\\n'" \
    '…and says so explicitly, rather than leaving it inferred from zeros'

  # PROMOTE'"'"'S EARLY RETURN MUST NOT SKIP THE HITS CHECK (PR #429).
  check_mut promote-early-return-unchecked \
    '  _adb_pl_hits "$ledger" >/dev/null || { printf '"'"'pattern-ledger: %s does not parse (the hits region)\n'"'"' "$ledger" >&2; exit 18; }' \
    '  :' \
    "promote refuses a damaged hits region instead of returning 'already promoted'"

  # THE LOCK `record` TAKES (PR #429). The reported defect was an ORDERING — the template written
  # before the lock — and that regression is a multi-line restructure `check_mutate_literal` cannot
  # express as one literal. What it can do is remove the lock this ordering depends on, which
  # proves the first-writer assertion is able to fire at all; the ordering itself is covered by
  # that behavioural assertion and not by an injection, and saying so is better than shipping a
  # row that silently applies to nothing.
  check_mut record-unlocked \
    '  _adb_pl_lock "$ledger" || exit 20' \
    '  :' \
    '25 concurrent writers creating the ledger for the FIRST time all land'

  # THE RULE-TEXT VALIDATION (PR #429).
  check_mut rule-text-unchecked \
    '    _adb_pl_ok_text "$rule" || return 1' \
    '    :' \
    'a checklist rule carrying a tab is refused by `checklist`'

  # THE MODE PRESERVATION (PR #429).
  check_mut mode-not-preserved \
    '  cp -p "$file" "$tmp" 2>/dev/null || true' \
    '  :' \
    "the ledger lost its mode to mktemp"

  # THE OWNER-FILE ROW IS RETIRED. It mutated a `cat "$dir/owner"` check that no longer exists:
  # the token became a SUBDIRECTORY precisely because reading a file and then deleting was
  # check-then-act. `unlock-check-then-act` below covers the property it was written for.

  # THE COMPLETE-SCALAR CHECK (PR #429).
  # TARGETS THE AWK GUARD, not the message: `return 2` stopped being unique once this check added
  # one of its own, and a row aimed at a shared literal mutates whichever comes first.
  check_mut threshold-scalar-unchecked \
    '              bad = 1; exit' \
    '              next' \
    'an unterminated quoted threshold is refused, not silently reconstructed'

  # THE DUPLICATE-THRESHOLD SCAN (PR #429).
  check_mut duplicate-threshold-unchecked \
    '              if (++seen > 1) { bad = 1; exit }' \
    '              seen = 1' \
    'a threshold declared twice is refused, not silently resolved to the first'

  # THE ATOMIC RELEASE (PR #429). Restores the read-then-delete form that shipped.
  check_mut unlock-check-then-act \
    '  rmdir "$dir" 2>/dev/null || true' \
    '  rm -rf "$dir" 2>/dev/null || true' \
    "release removed a co-resident marker"

  # THE DEATH PROOF (PR #429). Restores age-alone reclamation, which is what shipped.
  check_mut reclaims-live-owner \
    '    if [ -n "$age" ] && [ "$age" -gt "$_ADB_PL_LOCK_STALE_SECS" ] && _adb_pl_owner_gone "$dir"; then' \
    '    if [ -n "$age" ] && [ "$age" -gt "$_ADB_PL_LOCK_STALE_SECS" ]; then' \
    "a stale-but-LIVE owner's lock was reclaimed"

  # THE LEADING-ZERO RULE (PR #429).
  check_mut leading-zero-threshold \
    '              if ($0 ~ /^[[:space:]]*threshold[[:space:]]*=[[:space:]]*(0|[1-9][0-9]*)[[:space:]]*(#.*)?$/) next' \
    '              if ($0 ~ /^[[:space:]]*threshold[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/) next' \
    'a leading-zero threshold (02) is refused'

  # THE `--pr` FILTER VALIDATION (PR #429).
  check_mut stats-filter-unchecked \
    '  if [ -n "$OPT_PR" ] && ! _adb_pl_ok_pr "$OPT_PR"; then' \
    '  if false; then' \
    'stats refuses --pr 0 rather than reporting a falsely clean zero'

  # THE RECORD PREFIX (PR #429).
  check_mut record-prefix-unchecked \
    '      if ($1 != "- ")         { bad = 1; exit }' \
    '      if (0)                  { bad = 1; exit }' \
    'a forged record prefix is refused by `verify`'

  # THE ps-BASED LIVENESS PROBE (PR #429). Restores `kill -0`, which conflates EPERM with ESRCH.
  check_mut liveness-via-kill \
    '  ps -p "$pid" >/dev/null 2>&1 && return 1' \
    '  kill -0 "$pid" 2>/dev/null && return 1' \
    'pid 1 was judged GONE'

  # THE REPEATED-[patterns]-TABLE COUNT (PR #429).
  check_mut repeated-patterns-table \
    '                                intbl = (hdr == "patterns"); if (intbl && ++tbl > 1) { bad = 1; exit }' \
    '                                intbl = (hdr == "patterns");' \
    'a repeated [patterns] table header is refused'

  # THE NEW-LEDGER MODE (PR #429).
  check_mut new-ledger-mode \
    "    chmod \"\$(printf '%o' \"\$(( 0666 & ~0\$(umask) ))\")\" \"\$_tpl\" 2>/dev/null || true" \
    "    :" \
    "a NEWLY CREATED ledger did not get the umask's mode"

  # THE BOUNDED RECLAMATION RETRY (PR #429). Restores the unconditional `continue`, which neither
  # slept nor incremented `waited`, so a rename that can never succeed busy-spun past the bound.
  # A SINGLE-LINE literal: `check_mutate_literal` matches with `index()` on ONE record, so a
  # two-line literal applies to nothing and the harness reports the row as testing NOTHING —
  # which is what it did here. Replacing the explanatory line with a bare `continue` restores
  # exactly the unconditional retry that shipped.
  check_mut reclaim-busy-spin \
    '      # A FAILED RECLAMATION FALLS THROUGH TO THE WAIT, it does not retry immediately. An' \
    '      continue' \
    'a reclamation that cannot rename busy-spun past the wait bound'

  # THE HEADER NORMALIZATION IN THE LEDGER'"'"'S OWN SCANNER (PR #429).
  check_mut patterns-header-comment \
    '                                  if (c == "#" && !inq) { hdr = substr(hdr, 1, i - 1); break }' \
    '                                  if (0) { hdr = substr(hdr, 1, i - 1); break }' \
    'a repeated [patterns] table header is refused'

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
# THE RECORD PREFIX (PR #429). `FORGED `class` …` carries nine backtick fields and a well-formed
# suffix, so validating only the span count and the tail let anything sit before the first span.
sed 's/^- `dupe-class`/FORGED `dupe-class`/' "$L2" > "$work/l2-prefix.md"
for sub in verify classes stats; do
  bash "$PL" "$sub" --ledger "$work/l2-prefix.md" >/dev/null 2>&1
  eq "$?" 18 "a forged record prefix is refused by \`$sub\`"
done

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

# THE RECORD SUFFIX MUST MATCH THE WRITER'"'"'S GRAMMAR (PR #429). A substring search for
# `PR #[0-9]+` found its pattern ANYWHERE, so a hand-edited `garbage PR #999xyz no-date` parsed
# cleanly and `stats --pr 999` counted it — malformed data attributed to a pull request it never
# belonged to. The whole suffix is now required.
sed 's/ PR #100 2026-.*/ garbage PR #999xyz no-date/' "$L3" > "$work/l3-badsuffix.md"
for sub in verify classes stats; do
  bash "$PL" "$sub" --ledger "$work/l3-badsuffix.md" >/dev/null 2>&1
  eq "$?" 18 "a structurally invalid record suffix is refused by \`$sub\`"
done
# …and a legitimate summary containing BACKTICKS still parses, since the suffix is reconstructed
# across every field a code span may have split.
L3b="$work/l3-ticks.md"
bash "$PL" record --ledger "$L3b" --class tick-cls --site s.sh --fix abc1231 --pr 7 --thread TK1 \
  --summary 'the `helper` compared two ways' --date 2026-08-24 >/dev/null 2>&1
bash "$PL" verify --ledger "$L3b" >/dev/null 2>&1
eq "$?" 0 "…while a summary containing backticks still parses"
eq "$(bash "$PL" stats --ledger "$L3b" --pr 7 | awk -F'\t' '$1=="pr-hits"{print $2}')" 1 \
   "…and is still attributed to its own PR"

# THE CHECKLIST RULE TEXT OBEYS THE WRITER'"'"'S GRAMMAR (PR #429). Requiring only "non-empty
# after the class" accepted a suffix carrying bytes `promote` refuses — a tab, a control character,
# a region marker — and `checklist` then emitted that raw line straight into an agent prompt, which
# is the one output of this module that reaches another model.
# A DISTINCT PATH. `$work/l3-rule.md` is already section 3's DELIBERATELY BROKEN fixture, so
# reusing the name appended these records to a ledger with a malformed checklist rule and every
# assertion below came back 18 — passing the refusals for the wrong reason and failing the one
# positive case. Fourth fixture-validity bug of this pull request; they are recorded as their own
# class in the ledger.
L3c="$work/rule-grammar.md"
bash "$PL" record --ledger "$L3c" --class rulec --site a.sh --fix abc1231 --pr 1 --thread R1 >/dev/null 2>&1
bash "$PL" record --ledger "$L3c" --class rulec --site b.sh --fix abc1232 --pr 1 --thread R2 >/dev/null 2>&1
bash "$PL" promote --ledger "$L3c" --class rulec --rule 'do it properly' >/dev/null 2>&1
awk -v t="$(printf '\t')" '{ if ($0 ~ /^- `rulec` —/) print "- `rulec` — do it" t "FORGED"; else print }' \
  "$L3c" > "$work/l3-forged.md"
for sub in verify checklist classes; do
  bash "$PL" "$sub" --ledger "$work/l3-forged.md" >/dev/null 2>&1
  eq "$?" 18 "a checklist rule carrying a tab is refused by \`$sub\`"
done
sed 's/^- `rulec` — .*/- `rulec` do it/' "$L3c" > "$work/l3-nosep.md"
bash "$PL" checklist --ledger "$work/l3-nosep.md" >/dev/null 2>&1
eq "$?" 18 "…and so is a rule written without the separator the writer emits"
# …while a rule containing a LEGITIMATE code span still works, since the rule is taken from the
# whole line rather than from a backtick-split field.
bash "$PL" record --ledger "$L3c" --class spanc --site a.sh --fix abc1233 --pr 1 --thread R3 >/dev/null 2>&1
bash "$PL" record --ledger "$L3c" --class spanc --site b.sh --fix abc1234 --pr 1 --thread R4 >/dev/null 2>&1
bash "$PL" promote --ledger "$L3c" --class spanc --rule 'grep for `adb_toml_array` at every call site' >/dev/null 2>&1
has "$(bash "$PL" checklist --ledger "$L3c" 2>/dev/null)" 'grep for `adb_toml_array` at every call site' \
   "…and a rule containing a code span survives unchanged"

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

# AN INCOMPLETE SCALAR IS MALFORMED TOO (PR #429). `adb_toml_get` walks to the closing quote and,
# not finding one, RECONSTRUCTS the value with both — so `threshold = "2` came back as `"2"`,
# unquoted to `2`, and was accepted. The reconstructed value is indistinguishable from a good one,
# so the check has to read the source line.
printf '[patterns]\nthreshold = "2\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
HOME="$MHOME" bash "$PL" threshold --ledger "$L1" >/dev/null 2>&1
eq "$?" 2 "an unterminated quoted threshold is refused, not silently reconstructed"
# A KEY DECLARED TWICE IS INVALID TOML (PR #429), and `adb_toml_get` returns the FIRST — so a
# duplicate silently used the earlier value. The `[mcp]` reader already refused this; its sibling
# here did not, which is the class my own promoted rule says to sweep for.
printf '[patterns]\nthreshold = 2\nthreshold = 99\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
HOME="$MHOME" bash "$PL" threshold --ledger "$L1" >/dev/null 2>&1
eq "$?" 2 "a threshold declared twice is refused, not silently resolved to the first"
# TOML INTEGERS CARRY NO LEADING ZEROS (PR #429). `02` and `08` parse to values the domain check
# would accept, over a manifest a TOML consumer rejects.
for bad in '02' '08' '"03"'; do
  printf '[patterns]\nthreshold = %s\n' "$bad" > "$MHOME/.config/ai-dev-baseline/agents.toml"
  HOME="$MHOME" bash "$PL" threshold --ledger "$L1" >/dev/null 2>&1
  eq "$?" 2 "a leading-zero threshold ($bad) is refused"
done
# A REPEATED [patterns] TABLE is invalid TOML even with one assignment — the `[mcp]` sibling again.
for hdr in '[patterns]' '[patterns] # tuning'; do
  printf '%s\nthreshold = 3\n\n%s\nfoo = 1\n' "$hdr" "$hdr" > "$MHOME/.config/ai-dev-baseline/agents.toml"
  HOME="$MHOME" bash "$PL" threshold --ledger "$L1" >/dev/null 2>&1
  eq "$?" 2 "a repeated [patterns] table header is refused (spelled '$hdr')"
done
# …and a single COMMENTED header is still the table, or the fix would have narrowed the domain.
printf '[patterns] # tuning\nthreshold = 3\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
eq "$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" | awk '{print $1}')" 3 \
   "a commented [patterns] header is still read as the table"
rm -f "$MHOME/.config/ai-dev-baseline/agents.toml"

# `stats --pr` MUST VALIDATE ITS FILTER, or a mistyped one reads as a real PR with no findings.
for bad in 0 not-a-pr 00; do
  bash "$PL" stats --ledger "$L1" --pr "$bad" >/dev/null 2>&1
  eq "$?" 2 "stats refuses --pr $bad rather than reporting a falsely clean zero"
done
# RE-ESTABLISHED, because the blocks above end by removing the manifest — without this the two
# readers below fall back to the built-in and return 0, and the assertions pass for the wrong
# reason. Fixture ordering, caught by the suite going red rather than by reading it.
printf '[patterns]\nthreshold = "2\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
for sub in due stats; do
  HOME="$MHOME" bash "$PL" "$sub" --ledger "$L1" >/dev/null 2>&1
  eq "$?" 2 "…and \`$sub\` refuses it too, rather than running on a value nobody wrote"
done
# …while every COMPLETE spelling still works, so the check has not simply narrowed the domain.
for good in 'threshold = 3' 'threshold = "3"' 'threshold = 3 # a comment'; do
  printf '[patterns]\n%s\n' "$good" > "$MHOME/.config/ai-dev-baseline/agents.toml"
  eq "$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" | awk '{print $1}')" 3 \
     "a complete scalar ($good) is still accepted"
done
rm -f "$MHOME/.config/ai-dev-baseline/agents.toml"
has "$OUT" "not a single, complete TOML scalar" \
   "…and a non-numeric quoted value is named as a grammar error, which is what it is"
# THE DOMAIN CHECK STILL OWNS SOMETHING: a value that is syntactically perfect TOML and still
# outside the domain. Thirteen digits passes the scalar grammar and fails `_adb_pl_ok_pr`.
printf '[patterns]\nthreshold = 1234567890123\n' > "$MHOME/.config/ai-dev-baseline/agents.toml"
DOUT="$(HOME="$MHOME" bash "$PL" threshold --ledger "$L1" 2>&1)"; DRC2=$?
no "$DRC2" "a syntactically valid but out-of-domain threshold is still a hard error"
has "$DOUT" "positive whole number" "…and THAT is where the domain message belongs"
rm -f "$MHOME/.config/ai-dev-baseline/agents.toml"

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

# TWO PROMOTED CLASSES, which no fixture had until this assertion. The promoted list was passed to
# awk with `-v`, which cannot carry a newline — so `classes`, `due`, `stats` and `promote` all died
# with "newline in string" on any project's SECOND promotion, while 120 assertions passed over
# fixtures that never had one. A count of one is the worst possible fixture for a list.
seed "$L7" second-class 2 >/dev/null 2>&1
bash "$PL" promote --ledger "$L7" --class second-class --rule 'and sweep this too' >/dev/null 2>&1
CLS2="$(bash "$PL" classes --ledger "$L7" 2>&1)"; CRC2=$?
eq "$CRC2" 0 "classes survives a SECOND promoted class"
hasnt "$CLS2" "newline in string" "…without awk choking on the multi-line list"
eq "$(printf '%s' "$CLS2" | awk -F'\t' '$2=="promo-class"{print $3}')"   1 "…and still marks the first as promoted"
eq "$(printf '%s' "$CLS2" | awk -F'\t' '$2=="second-class"{print $3}')"  1 "…and the second"
bash "$PL" due --ledger "$L7" >/dev/null 2>&1
eq "$?" 11 "…and due is clean with both promoted"
eq "$(bash "$PL" stats --ledger "$L7" | awk -F'\t' '$1=="promoted"{print $2}')" 2 "…and stats counts both"

# =============================== 7b. the partial-validation siblings (PR #429) ===================
# All three are the SAME class the round-1 fixes promoted a checklist rule for: a check that covers
# less than its consumers do. They are asserted together because that is how the class is found —
# by sweeping the siblings rather than fixing the reported instance.
L7b="$work/l7b.md"
seed "$L7b" ck-dupe 2 || bad "fixture: could not seed"
bash "$PL" promote --ledger "$L7b" --class ck-dupe --rule 'sweep it' >/dev/null 2>&1

# (i) `verify` must agree with the readers about a duplicated checklist class.
awk '{print} /^- `ck-dupe` —/ && !d {print; d=1}' "$L7b" > "$work/l7b-dupck.md"
for sub in verify checklist classes; do
  bash "$PL" "$sub" --ledger "$work/l7b-dupck.md" >/dev/null 2>&1
  eq "$?" 18 "a duplicated checklist class is refused by \`$sub\` — verify included"
done
DV="$(bash "$PL" verify --ledger "$work/l7b-dupck.md" 2>&1)"
has "$DV" "duplicate checklist class" "…and verify NAMES it, as it already does for thread ids"

# (iii) `promote` must validate both regions BEFORE its early `already promoted` return, or a
# damaged hits region is reported as "already has a checklist rule" and the resolver carries on
# over a file every reader refuses whole.
sed 's/<!-- adb:hits:begin -->//' "$L7b" > "$work/l7b-badhits.md"
bash "$PL" promote --ledger "$work/l7b-badhits.md" --class ck-dupe --rule x >/dev/null 2>&1
eq "$?" 18 "promote refuses a damaged hits region instead of returning 'already promoted'"

# (ii) `record` must validate BOTH regions before appending. Validating only the hits half reported
# a hit written into a file every reader then refuses.
sed 's/<!-- adb:checklist:begin -->//' "$L7b" > "$work/l7b-badck.md"
bash "$PL" record --ledger "$work/l7b-badck.md" --class other --site s.sh --fix abc1234 \
  --pr 1 --thread T-new-one >/dev/null 2>&1
eq "$?" 18 "record refuses a ledger whose CHECKLIST region is damaged, not just its hits"

# =============================== 7c. concurrent writers lose nothing (PR #429) ===================
# The header used to argue no lock was needed because `/implement-issue`'s run admission permits one
# run per checkout — but the writer here is `/resolve-pr-threads`, which never takes that claim. So
# nothing serialized two overlapping resolver runs and the second rename silently discarded the
# first's records: loss of the signal this module exists to keep, argued away rather than tested.
#
# TWENTY REAL CONCURRENT WRITERS, not a mocked lock. Note the sha: `abcd%03d`, because `abc12$i` is
# SIX characters for a single digit and the writer correctly refuses it — the first version of this
# fixture "lost" nine writers that had never been valid, and read as a broken lock.
L7c="$work/l7c.md"
bash "$PL" record --ledger "$L7c" --class seed-c --site s.sh --fix abc1231 --pr 1 --thread T0 >/dev/null 2>&1
for i in $(seq 1 20); do
  bash "$PL" record --ledger "$L7c" --class conc --site "s$i.sh" \
    --fix "$(printf 'abcd%03d' "$i")" --pr 2 --thread "C$i" >/dev/null 2>&1 &
done
wait
eq "$(bash "$PL" classes --ledger "$L7c" | awk -F'\t' '$2=="conc"{print $1}')" 20 \
   "twenty concurrent writers all land — none is silently discarded by a racing rename"
bash "$PL" verify --ledger "$L7c" >/dev/null 2>&1
eq "$?" 0 "…and the ledger still parses afterwards"
[ -d "$L7c.lock" ] && bad "the write lock leaked after every writer finished" || ok

# THE CRITICAL SECTION SPANS CHECK-THEN-ACT (PR #429). Locking only the read-modify-write fixed
# lost updates and left the real race: both `record` and `promote` CHECK a precondition and then
# ACT on it, so two runs could both pass the check outside the lock and then serialize two inserts
# of the same thing. The reviewer measured 30 parallel records of ONE thread producing 30 rows —
# which every reader then refuses as a duplicate, so the ledger destroys itself under concurrency.
L7d="$work/l7d.md"
bash "$PL" record --ledger "$L7d" --class seed-d --site s.sh --fix abc1231 --pr 1 --thread T0 >/dev/null 2>&1
for i in $(seq 1 30); do
  bash "$PL" record --ledger "$L7d" --class same-c --site s.sh --fix abc1234 --pr 1 --thread SAME >/dev/null 2>&1 &
done
wait
eq "$(grep -c '`SAME`' "$L7d")" 1 "30 concurrent records of ONE thread produce exactly ONE row"

bash "$PL" record --ledger "$L7d" --class pp-c --site a.sh --fix abc1231 --pr 1 --thread P1 >/dev/null 2>&1
bash "$PL" record --ledger "$L7d" --class pp-c --site b.sh --fix abc1232 --pr 1 --thread P2 >/dev/null 2>&1
for i in $(seq 1 15); do
  bash "$PL" promote --ledger "$L7d" --class pp-c --rule 'sweep' >/dev/null 2>&1 &
done
wait
eq "$(bash "$PL" checklist --ledger "$L7d" 2>/dev/null | grep -c '`pp-c`')" 1 \
   "…and 15 concurrent promotes of ONE class produce exactly ONE rule"
bash "$PL" verify --ledger "$L7d" >/dev/null 2>&1
eq "$?" 0 "…and the ledger still parses, rather than being destroyed by its own writers"

# THE FIRST LEDGER IS CREATED INSIDE THE LOCK (PR #429). Two processes recording the first hits
# concurrently could both see the file absent; the slower then wrote the TEMPLATE over a ledger the
# faster had already created and inserted into, erasing that hit. The existence test has to happen
# where the decision is protected.
L7e="$work/deep/first.md"
for i in $(seq 1 25); do
  bash "$PL" record --ledger "$L7e" --class firstc --site "s$i.sh" \
    --fix "$(printf 'abcd%03d' "$i")" --pr 1 --thread "F$i" >/dev/null 2>&1 &
done
wait
eq "$(bash "$PL" classes --ledger "$L7e" 2>/dev/null | awk -F'\t' '$2=="firstc"{print $1}')" 25 \
   "25 concurrent writers creating the ledger for the FIRST time all land"

# THE LOCK PATH IS NOT SHELL SOURCE (PR #429). The EXIT trap interpolated the ledger path into text
# `trap` evaluates later, so a directory named with a quote and a command ran it. Reproduced by the
# reviewer; asserted here because an injection that is fixed without a test is an injection waiting
# to come back.
INJDIR="$work/inj/x'\'';touch INJECTED;#"
mkdir -p "$INJDIR"
bash "$PL" record --ledger "$INJDIR/p.md" --class injc --site s.sh --fix abc1234 --pr 1 --thread INJ1 >/dev/null 2>&1
if [ -e "$INJDIR/INJECTED" ] || [ -e "$work/INJECTED" ] || [ -e "INJECTED" ]; then
  bad "a ledger path containing shell syntax EXECUTED it — the EXIT trap is evaluating the path"
  rm -f "$INJDIR/INJECTED" "$work/INJECTED" INJECTED 2>/dev/null
else
  ok
fi

# THE LEDGER KEEPS ITS FILE MODE (PR #429). `mktemp` creates 0600 and the rename installs that
# over the tracked file, so with an ordinary umask the FIRST record silently took `patterns.md`
# from 0644 to 0600 — invisible in the diff, since git tracks only the execute bit, and enough to
# stop everyone else in a shared checkout reading the project ledger.
L7f="$work/mode.md"
( umask 022
  bash "$PL" record --ledger "$L7f" --class modec --site s.sh --fix abc1231 --pr 1 --thread M1 >/dev/null 2>&1
  bash "$PL" record --ledger "$L7f" --class modec --site s2.sh --fix abc1232 --pr 1 --thread M2 >/dev/null 2>&1 )
case "$(ls -l "$L7f" | awk '{print substr($1,1,10)}')" in
  -rw-r--r--) ok ;;
  *) bad "the ledger lost its mode to mktemp's 0600: $(ls -l "$L7f" | awk '{print $1}')" ;;
esac
# A DELIBERATE mode is preserved too — the fix copies the existing mode rather than forcing 0644.
chmod 0640 "$L7f"
bash "$PL" record --ledger "$L7f" --class modec --site s3.sh --fix abc1233 --pr 1 --thread M3 >/dev/null 2>&1
case "$(ls -l "$L7f" | awk '{print substr($1,1,10)}')" in
  -rw-r-----) ok ;;
  *) bad "a deliberately restricted ledger mode was not preserved: $(ls -l "$L7f" | awk '{print $1}')" ;;
esac

# THE LOCK IS RELEASED ONLY BY ITS OWNER (PR #429). A writer paused past the stale interval whose
# lock was reclaimed could resume and unlock its SUCCESSOR'"'"'s lock, letting a third process into
# the critical section. Reclamation was made ownership-safe last round; release was not.
L7g="$work/owner.md"
bash "$PL" record --ledger "$L7g" --class ownc --site s.sh --fix abc1231 --pr 1 --thread O1 >/dev/null 2>&1
mkdir -p "$L7g.lock"; printf 'SOMEONE-ELSE\n' > "$L7g.lock/owner"
(
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
  eval "$(sed -n '/^_adb_pl_unlock()/,/^}/p' "$ROOT/scripts/lib/pattern-ledger.sh")"
  _ADB_PL_LOCK_TOKEN="MINE-AND-STALE"
  _adb_pl_unlock "$L7g"
)
if [ -d "$L7g.lock" ]; then ok; else bad "a stale writer deleted a SUCCESSOR's lock — release carries no owner token"; fi
rm -rf "$L7g.lock"
# …and the owning writer still releases its own, or every run would leave a lock behind.
bash "$PL" record --ledger "$L7g" --class ownc --site s2.sh --fix abc1232 --pr 1 --thread O2 >/dev/null 2>&1
[ -d "$L7g.lock" ] && bad "the owning writer failed to release its own lock" || ok

# RELEASE IS ATOMIC, NOT CHECK-THEN-ACT (PR #429). Reading an `owner` file and then deleting the
# directory leaves a window: a successor can reclaim the stale lock and create a fresh one between
# the read and the `rm`, and the original writer then deletes THEIRS. The token is a SUBDIRECTORY
# now, so release is two `rmdir`s that can only ever remove our own marker and an empty parent.
L7h="$work/relock.md"
bash "$PL" record --ledger "$L7h" --class relc --site s.sh --fix abc1231 --pr 1 --thread RL1 >/dev/null 2>&1
mkdir -p "$L7h.lock/SOMEONE-ELSE-TOKEN"
(
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
  eval "$(sed -n '/^_adb_pl_unlock()/,/^}/p' "$ROOT/scripts/lib/pattern-ledger.sh")"
  _ADB_PL_LOCK_TOKEN="MINE-AND-STALE"
  _adb_pl_unlock "$L7h"
)
[ -d "$L7h.lock/SOMEONE-ELSE-TOKEN" ] && ok || bad "a stale writer deleted a successor's lock marker"
[ -d "$L7h.lock" ] && ok || bad "a stale writer deleted a successor's lock directory"
rm -rf "$L7h.lock"

# AND THE PARENT rmdir REFUSES A NON-EMPTY DIRECTORY. That second `rmdir` is the half that keeps a
# co-resident marker alive; `rm -rf` in its place would take the whole directory with it. Only this
# shape witnesses it — with just our own marker present the directory is empty afterwards and both
# spellings behave identically.
mkdir -p "$L7h.lock/OURS" "$L7h.lock/THEIRS"
(
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
  eval "$(sed -n '/^_adb_pl_unlock()/,/^}/p' "$ROOT/scripts/lib/pattern-ledger.sh")"
  _ADB_PL_LOCK_TOKEN="OURS"
  _adb_pl_unlock "$L7h"
)
[ -d "$L7h.lock/OURS" ]   && bad "release did not remove our own marker" || ok
[ -d "$L7h.lock/THEIRS" ] && ok || bad "release removed a co-resident marker — rmdir was not what refused the non-empty directory"
rm -rf "$L7h.lock"

# THE LOCK DIRECTORY IS ACTUALLY EMPTIED, or it leaks and every later writer waits out its bound.
# `meta` is a FILE inside it, and leaving it there made `rmdir` fail forever — 50 assertions in
# this suite went red on the first run after the metadata landed, which is the harness catching a
# regression in the fix rather than in the thing it fixed.
L7k="$work/leak.md"
bash "$PL" record --ledger "$L7k" --class leakc --site s.sh --fix abc1231 --pr 1 --thread LK1 >/dev/null 2>&1
[ -e "$L7k.lock" ] && bad "the lock directory survived a successful release — it will block every later writer" || ok
bash "$PL" record --ledger "$L7k" --class leakc --site s2.sh --fix abc1232 --pr 1 --thread LK2 >/dev/null 2>&1
eq "$?" 0 "…and a second write in the same ledger is not blocked by the first"

# AGE IS NOT DEATH (PR #429). A writer suspended past the stale interval is still ALIVE and may
# still hold a prepared replacement file — reclaim its lock, let a successor update the ledger, and
# the original resumes and renames its stale copy over their work. The tokenized release stops it
# deleting their LOCK; nothing stopped that WRITE. Reclamation now requires proof the owner is gone.
L7i="$work/live.md"
bash "$PL" record --ledger "$L7i" --class livec --site s.sh --fix abc1231 --pr 1 --thread LV1 >/dev/null 2>&1
mkdir -p "$L7i.lock/LIVE-TOKEN"
printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "$$" > "$L7i.lock/meta"   # this suite is alive
touch -t 200001010000 "$L7i.lock" 2>/dev/null                          # …and long past stale
( _ADB_PL_LOCK_WAIT_SECS=3 timeout 25 bash "$PL" record --ledger "$L7i" --class livec \
    --site s2.sh --fix abc1232 --pr 1 --thread LV2 ) >/dev/null 2>&1
[ -d "$L7i.lock/LIVE-TOKEN" ] && ok || bad "a stale-but-LIVE owner's lock was reclaimed — age was treated as death"
# …and the contender wrote nothing rather than proceeding beside the live owner.
eq "$(bash "$PL" classes --ledger "$L7i" 2>/dev/null | awk -F'\t' '$2=="livec"{print $1}')" 1 \
   "…and the blocked writer appended nothing"

# A PROVABLY DEAD owner IS reclaimed, or a killed writer would wedge the ledger forever.
printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "999999" > "$L7i.lock/meta"
bash "$PL" record --ledger "$L7i" --class deadc --site s.sh --fix abc1233 --pr 1 --thread DV1 >/dev/null 2>&1
eq "$?" 0 "a lock whose owner is provably gone IS reclaimed"

# A lock with NO metadata is not reclaimable either — "cannot prove dead" must read as alive.
L7j="$work/nometa.md"
bash "$PL" record --ledger "$L7j" --class nmc --site s.sh --fix abc1231 --pr 1 --thread NM1 >/dev/null 2>&1
mkdir -p "$L7j.lock/ORPHAN"; touch -t 200001010000 "$L7j.lock" 2>/dev/null
( _ADB_PL_LOCK_WAIT_SECS=3 timeout 25 bash "$PL" record --ledger "$L7j" --class nmc \
    --site s2.sh --fix abc1232 --pr 1 --thread NM2 ) >/dev/null 2>&1
[ -d "$L7j.lock/ORPHAN" ] && ok || bad "a lock with no owner metadata was reclaimed — unprovable must mean alive"
rm -rf "$L7i.lock" "$L7j.lock"

# LIVENESS IS ASKED OF `ps`, NOT `kill -0` (PR #429). `kill -0` fails for BOTH "no such process"
# and "not yours", so a contender running as a different user in a shared checkout would reclaim a
# LIVE lock. The reviewer verified it as `nobody` against a root-owned pid. `ps -p` answers about
# existence regardless of ownership — pid 1 is the standing witness: alive, and not ours to signal.
(
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
  # shellcheck disable=SC2034  # read by the EVAL'd `_adb_pl_owner_gone` below (`IFS="$TAB"`),
  # which shellcheck cannot follow through `eval`.
  TAB="$(printf '\t')"
  eval "$(sed -n '/^_adb_pl_owner_gone()/,/^}/p' "$ROOT/scripts/lib/pattern-ledger.sh")"
  D="$work/liveprobe.lock"; mkdir -p "$D"
  printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "1" > "$D/meta"
  _adb_pl_owner_gone "$D" && exit 1 || exit 0
) && ok || bad "pid 1 was judged GONE — liveness is being read from a signal permission, not from existence"
(
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
  # shellcheck disable=SC2034  # read by the EVAL'd `_adb_pl_owner_gone` below (`IFS="$TAB"`),
  # which shellcheck cannot follow through `eval`.
  TAB="$(printf '\t')"
  eval "$(sed -n '/^_adb_pl_owner_gone()/,/^}/p' "$ROOT/scripts/lib/pattern-ledger.sh")"
  D="$work/deadprobe.lock"; mkdir -p "$D"
  printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "999999" > "$D/meta"
  _adb_pl_owner_gone "$D" && exit 0 || exit 1
) && ok || bad "a plainly dead pid was judged alive — a killed writer would wedge the ledger forever"

# THE FIRST LEDGER IS PUBLISHED BY RENAME (PR #429), like every other write. A direct redirection
# killed part-way leaves a half-written file that every retry then reads as present and refuses,
# turning a first-run failure into one needing manual repair.
has "$(cat "$ROOT/scripts/lib/pattern-ledger.sh")" 'mktemp "${ledger}.XXXXXX"' \
   "the initial template is staged and renamed, not written in place"
# …AND THE NEW LEDGER STILL GETS A NEW FILE'"'"'S MODE. Staging through `mktemp` reintroduced the
# 0600 problem on the one path with no existing file to copy a mode from — caught by the mode
# assertion above going red on the very next run.
L7m="$work/newmode.md"
( umask 022
  bash "$PL" record --ledger "$L7m" --class nmc --site s.sh --fix abc1231 --pr 1 --thread NMM1 >/dev/null 2>&1 )
case "$(ls -l "$L7m" | awk '{print substr($1,1,10)}')" in
  -rw-r--r--) ok ;;
  *) bad "a NEWLY CREATED ledger did not get the umask's mode: $(ls -l "$L7m" | awk '{print $1}')" ;;
esac

# A FAILED RECLAMATION FALLS THROUGH TO THE WAIT (PR #429). When a stale lock's owner is provably
# gone but the RENAME cannot succeed — an unwritable parent — an unconditional `continue` neither
# slept nor incremented the counter, so the advertised bound was bypassed and the writer busy-spun
# forever. The observable is termination: fixed, it refuses within its bound; unfixed, it never
# returns. Skipped as root, where permissions do not apply.
if [ "$(id -u)" -ne 0 ]; then
  L7n="$work/spin"; mkdir -p "$L7n"
  bash "$PL" record --ledger "$L7n/p.md" --class spinc --site s.sh --fix abc1231 --pr 1 --thread SP1 >/dev/null 2>&1
  mkdir -p "$L7n/p.md.lock/DEADTOKEN"
  printf '%s\t%s\n' "$(uname -n 2>/dev/null)" "999999" > "$L7n/p.md.lock/meta"   # provably gone
  touch -t 200001010000 "$L7n/p.md.lock" 2>/dev/null                              # …and stale
  chmod 500 "$L7n"                                                                # …and unrenamable
  ( ADB_PATTERN_LOCK_WAIT_SECS=2 timeout 25 bash "$PL" record --ledger "$L7n/p.md" --class spinc \
      --site s2.sh --fix abc1232 --pr 1 --thread SP2 ) >/dev/null 2>&1
  SPRC=$?
  chmod 700 "$L7n"
  if [ "$SPRC" -eq 124 ]; then
    bad "a reclamation that cannot rename busy-spun past the wait bound instead of falling through to it"
  else
    ok
  fi
  rm -rf "$L7n"
else
  ok   # running as root: the permission the case depends on does not exist
fi

# A HELD LOCK IS REPORTED, NEVER WRITTEN THROUGH. The dangerous failure is a writer that cannot
# take the lock and proceeds anyway.
mkdir "$L7c.lock"
BEFORE7c="$(cksum < "$L7c")"
( ADB_PL_LOCK_TEST=1 timeout 8 bash "$PL" record --ledger "$L7c" --class blocked --site s.sh \
    --fix abc1234 --pr 1 --thread T-blocked >/dev/null 2>&1 )
eq "$(cksum < "$L7c")" "$BEFORE7c" "a writer that cannot take the lock writes NOTHING"
rmdir "$L7c.lock"

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
# ABSENT AND ZERO ARE DIFFERENT FACTS (PR #429). The resolver's summary is required to distinguish
# "no ledger yet" from "an empty ledger", and could not: both came back as 0 with zero-valued
# fields, so the workflow's own no-ledger arm was unreachable.
eq "$(bash "$PL" stats --ledger "$work/nope.md" | awk -F'\t' '$1=="ledger"{print $2}')" absent \
   "…and says so explicitly, rather than leaving it inferred from zeros"
EMPTYL="$work/empty-ledger.md"
bash "$PL" record --ledger "$EMPTYL" --class x-cls --site s.sh --fix abc1234 --pr 1 --thread TE1 >/dev/null 2>&1
eq "$(bash "$PL" stats --ledger "$EMPTYL" | awk -F'\t' '$1=="ledger"{print $2}')" present \
   "…while a ledger that exists reports present, so the two are distinguishable"
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

RESTXT="$(cat "$RES")"

# THE SHA IS RESOLVED THROUGH THE PULL REQUEST (P1, PR #429). On a squash-merging repo — which
# this baseline prefers — the per-thread commits never become ancestors of the default branch, so
# a bare `git show <fix>` breaks in a fresh clone once the branch is deleted, and the ledger's
# advertised audit link would be broken by design. The PR number is the durable half.
has "$RESTXT" 'refs/pull/' "the resolver says how to resolve a fix sha after a squash merge"
has "$(cat "$ROOT/scripts/lib/pattern-ledger.sh")" 'refs/pull/' \
   "…and the ledger's own template says it too, for a reader who never sees the workflow"

# AN ALREADY-ADDRESSED FINDING IS STILL A FINDING (PR #429). Skipping it makes the recurrence count
# understate exactly the history the ledger exists to keep.
has "$RESTXT" 'ALREADY-ADDRESSED finding too' "the resolver records already-addressed findings"
has "$RESTXT" 'declined'                      "…and says which disposition is NOT recorded"

# THE PER-THREAD FIX SHA (PR #429). Step 4 permits several commits in one round, so `$LAST_SHA` —
# captured once, after the push — names the LAST of them. Recording every thread against it breaks
# the audit link the ledger exists for: `git show <fix>` would not contain the correction the entry
# points at.
has   "$RESTXT" '--fix "$FIX_SHA"' "the resolver records each thread against ITS OWN fix commit"
hasnt "$RESTXT" '--fix "$LAST_SHA"' "…never against the round's head sha"
has   "$RESTXT" 'FIX_SHA="$(git rev-parse --short=7 HEAD)"' "…and says how to capture it, per commit"
# `--short=7`, NOT a bare `--short`. Git's `--short[=<length>]` follows the effective `core.abbrev`,
# whose documented minimum is 4 — and `_adb_pl_ok_fix` requires 7. Probed: with core.abbrev=4 a
# bare `--short` returned 4 characters, so step 4b would refuse EVERY hit with rc 19 and record
# nothing at all. Pinned as an absence too, because the bare form is the one a later edit types.
hasnt "$RESTXT" 'FIX_SHA="$(git rev-parse --short HEAD)"' \
   "…using an explicit width, never the bare --short that follows core.abbrev"

# THE LEDGER COMMIT MUST BE A NO-OP ON AN IDEMPOTENT RE-RUN (PR #429). `record` returns 10 for a
# hit already stored, so a resolver that crashed after committing the ledger but before resolving
# the threads leaves the worktree unchanged — and an unconditional `git commit` then aborts the
# round before it resolves anything, defeating the record-before-resolve recovery this workflow
# deliberately chose.
has "$RESTXT" 'git diff --cached --quiet -- .ai-dev-baseline/patterns.md' \
   "the ledger commit is guarded on whether anything is actually staged"
has "$RESTXT" 'every hit was already recorded' "…and says why nothing to commit is a normal outcome"

# THE ROUND FIGURE IS THE PR-SCOPED ONE. `recurring` is a lifetime count over an append-only file,
# so a summary quoting it prints a number that grows whatever the round did.
has "$RESTXT" 'pr-recurring' "the summary reports pr-recurring, the figure a trend can be read from"
# A ROUND IS A DELTA, AND `--pr` IS NOT A ROUND (PR #429). Every round of one pull request records
# under the same PR number, so the cumulative figures grow monotonically — on #429 `stats --pr`
# reported 36 hits on every run after round 7, and labelling that "this round" made the
# finding-per-round trend false in the direction that always looks busier.
has "$RESTXT" 'STATS_BEFORE' "the resolver snapshots the ledger before recording the round"
has "$RESTXT" 'STATS_AFTER'  "…and again afterwards"
has "$RESTXT" 'ROUND_FINDINGS' "…and reports the DIFFERENCE as the round figure"
# RECURRING IS COUNTED FROM THE ROWS THIS ROUND APPENDED, not subtracted from the cumulative
# figure: when a class crosses the threshold every EARLIER hit becomes recurring too, so a round
# adding a class's second hit would see the scalar go 0 -> 2 and report two findings for one.
has   "$RESTXT" 'ROUND_CLASSES' "the resolver tracks which classes THIS round recorded"
# ONLY FOR ROWS ACTUALLY APPENDED. rc 10 is the crash-recovery rerun — already recorded, nothing
# added — so counting it would make this accumulator disagree with the snapshots beside it.
has   "$RESTXT" 'ONLY WHEN `record` RETURNED 0' "…and only for hits it actually appended, not rc 10"
hasnt "$RESTXT" 'ROUND_RECURRING="$(( $(_field "$STATS_AFTER" pr-recurring)' \
   "…and does not subtract cumulative pr-recurring, which reclassifies the past"
# The stats capture must be assigned, or the block that reads it aborts under set -u.
has   "$RESTXT" 'STATS_AFTER="$(' "the stats output is captured, not run and discarded"
hasnt "$RESTXT" 'printf '"'"'%s\n'"'"' "$STATS" |' "…and nothing reads a variable never assigned"
# `due` failing must stop the round; a wildcard that shrugged let it commit and resolve without
# ever learning which classes were owed a rule.
has "$RESTXT" 'STOP: [patterns] threshold is unusable' "a due failure stops the round"
# THE METRIC BLOCK IS GUARDED ON BOTH SNAPSHOTS (PR #429). The `case` promised to report no counts
# on a non-zero read and then fell through to the arithmetic anyway — empty fields yield negative
# round counts, or the threshold comparison fails outright.
has "$RESTXT" 'reporting no counts rather than wrong ones' \
   "a failed stats read reports no figures rather than computing over empty fields"
# A FAILED PROMOTION STOPS THE ROUND (PR #429). Without a branch, a promotion that failed on a
# malformed ledger or a lock timeout fell through to committing and resolving — and a later run
# sees no unresolved threads, never revisits promotion, and the earned rule is permanently absent.
has "$RESTXT" 'STOP: promoting'  "a failed promotion stops the round before step 5"
# THE ACCUMULATOR MUST NOT SWALLOW `record`'"'"'S STATUS (PR #429). Written as
# `if record …; then ROUND_CLASSES=…; fi` the branch skips the append on a failure and then
# COMPLETES SUCCESSFULLY, so the round walks on and resolves a thread nothing recorded — the
# stop-on-failure rule undone by the accumulator added for a different one.
has   "$RESTXT" 'RRC=$?'             "record's status is captured, not consumed by an if"
has   "$RESTXT" 'STOP: recording this thread failed' "…and a hard failure stops the round"
hasnt "$RESTXT" 'if {{PATTERN_LEDGER_LIB}} record --class <slug> … ; then' \
   "…so the swallowing form is gone rather than merely discouraged"
# A CLEAN PASS RECONCILES DUE PROMOTIONS (PR #429). Two branches can each record a class's first
# hit; after both merge the ledger holds two, but a clean run exits at step 0b before 4c ever asks.
has "$RESTXT" 'A clean pass still reconciles promotions' \
   "the clean-pass arm reconciles promotions merged history earned"
has "$(cat "$ROOT/scripts/lib/pattern-ledger.sh")" 'What makes that converge is a check on the CLEAN-PASS path' \
   "…and the ledger template no longer claims the ordinary path converges on its own"
has "$RESTXT" 'never revisit'    "…and says why: nothing would come back to it"
# THE ROUND FIGURES COME FROM THIS INVOCATION'"'"'S OWN RECEIPTS, not from PR-wide subtraction —
# `--pr` is shared, so two overlapping resolver runs would each report the other's work as theirs.
has   "$RESTXT" 'ROUND_FINDINGS="$(printf' "round findings are counted from the rows this run appended"
hasnt "$RESTXT" 'ROUND_FINDINGS="$(( $(_field "$STATS_AFTER" pr-hits)' \
   "…not subtracted from a PR-wide figure another run also writes to"
has   "$RESTXT" 'CLASSES_BEFORE' "…and new classes are decided against a before-snapshot of the classes"
has "$RESTXT" 'This PR so far' "…while still reporting the cumulative figure, labelled as cumulative"

# EVERY FAILED RECORD STOPS THE ROUND (PR #429). Naming only rc 18 left rc 20 — a lock timeout, an
# unwritable state directory, a failed rename — continuing into step 5, where resolving the thread
# erases a finding nothing recorded.
has "$RESTXT" 'EVERY result except' "every non-idempotent record failure stops the round"
has "$RESTXT" 'lock timeout'        "…naming rc 20 explicitly, not just the malformed-ledger case"
has "$RESTXT" 'pr-new-classes' "…and pr-new-classes, which stats now supplies"
# `promoted this round` is NOT derivable from an append-only file with no promotion timestamps, so
# the workflow must say where it comes from instead of implying `stats` supplies it.
# `promoted` USED to be the one round figure the resolver had to count itself, because nothing
# timestamps a promotion. The before/after snapshot supersedes that: a delta answers it without a
# timestamp, so the workflow no longer asks anyone to count by hand.
has "$RESTXT" 'ROUND_PROMOTED' "…including the promotions, which the delta derives without a timestamp"

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
