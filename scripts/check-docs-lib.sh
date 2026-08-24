#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the vendor-documentation duty (scripts/lib/docs-lib.sh, #422).
# OFFLINE: no network, no MCP server, no gh auth, and the tracked tree is never mutated.
#
# THE ONE DANGEROUS DIRECTION IS A CLEAN VERDICT NOBODY EARNED. `[mcp] required` exists so that an
# unreachable documentation server is a STATED degradation rather than a silent fall-back to
# training-data recall — and the failure that would reintroduce the silence is not a crash, it is a
# `0`. So the cases below are weighted toward every way `verdict` could come back green without a
# server having answered, and the negative case #422's acceptance criteria name explicitly — a
# declared server that is dead or degraded — is driven from three different directions.
#
# WHAT IS AND IS NOT PROVEN HERE, stated plainly because the boundary is the design (D90):
#
#   MCP is an in-harness protocol. Probed 2026-08-24: every subcommand of `codex mcp` and
#   `claude mcp` manages CONFIGURATION, and neither exposes a generic tool call. No shell test can
#   therefore issue a real MCP query, and a suite that stubbed one would be testing its own stub. What this module owns — and what is tested here — is the DECLARATION read, the record
#   grammar, and a fail-closed adjudication in which silence scores exactly as failure. What it does
#   not own, and no assertion below pretends to cover, is that the agent really issued the query.
#
#   That is why the "stubbed server" of the acceptance criterion is a RECORDED PROBE RESULT rather
#   than a fake server: the adjudication is the guard, and the guard is what must be seen going red.
#
# Every case is a way a green verdict could be wrong:
#
#   1. NO PROBE AT ALL IS DEGRADED, not clean. If silence adjudicated as success, an agent could
#      buy a clean verdict by skipping the preflight entirely — which is the whole failure mode.
#   2. A DEGRADED OR ABSENT RESULT IS DEGRADED, and the diagnostic names the server and the rung
#      the run falls to. A verdict that refused without saying what to do next is unactionable.
#   3. A MALFORMED DECLARATION IS 18, never "none declared". `required = "context7"` is a plausible
#      typo, and reading it as undeclared reports a project that ASKED for a preflight as one that
#      declined — the flattering answer, and the wrong one.
#   4. AN UNDECLARED `[mcp]` IS NOT A FAILURE. `[mcp]` is optional per repo; a project that never
#      declared a server must pass silently, or the duty becomes a tax on every repo that does not
#      use MCP.
#   5. THE REPORT REFUSES SILENCE. A run that recorded neither a consultation nor an explicit
#      "none needed" is the unstated disposition #422 calls the defect, and it is a distinct code
#      (11) rather than empty output the caller could print and move past.
#   6. "NONE NEEDED" IS A COMPLETE ANSWER. The proportionality rule is real, not ceremonial: a run
#      touching only trivial surfaces must be able to pass with no lookup — asserted with a spy
#      proving ZERO consultations were recorded, not merely that some text was present.
#   7. NO FIELD MAY FORGE A RECORD. The file is TSV read back with `IFS=<tab> read`, so a tab in a
#      value does not garble a display, it moves a field — and a `degraded` that reads back as
#      `usable` is the silent green this suite exists to prevent.
#
# `--mutation` drives the adjudication guards against deliberately broken copies and requires each
# to come back RED on its OWN witness (#213's `fires:` contract): a guard's failure mode is silence,
# and this guard's whole purpose is to make a silence loud.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-docs-lib.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" >/dev/null 2>&1 || {
  echo "check-docs-lib: FATAL — scripts/lib/common.sh is unavailable" >&2; exit 1; }
command -v adb_require_bash >/dev/null 2>&1 || {
  echo "check-docs-lib: FATAL — common.sh loaded but adb_require_bash is missing" >&2; exit 1; }
adb_require_bash "$@"

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
# shellcheck source=/dev/null
. scripts/check-lib.sh

[ "$#" -gt 1 ] && { echo "usage: check-docs-lib.sh [--mutation]" >&2; exit 2; }
MODE=full
case "${1:-}" in
  "")         ;;
  --mutation) MODE=mutation ;;
  *)          echo "usage: check-docs-lib.sh [--mutation]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
check_exit_guard "check-docs-lib" "rm -rf \"$work\""
check_init check-docs-lib

DL="$ROOT/scripts/lib/docs-lib.sh"

# A throwaway HOME so the developer's real global manifest can never reach a fixture. Without it a
# machine that happens to declare `[mcp] required` globally would change what these assertions mean
# — and it would do so only on that machine, which is the worst kind of flake.
FHOME="$work/home"; mkdir -p "$FHOME/.config/ai-dev-baseline"

# fixture <name> <toml-body> — a state dir + manifest pair. Returns the state dir on stdout.
fixture() {
  # TWO `local` statements, not one. `local n="$1" d="$work/$n"` does NOT see `n` — the
  # assignments in a single `local` do not take effect for the ones beside them — so `d` became
  # `/state`, every fixture wrote to the same wrong path, and the assertions failed against a
  # directory nothing had created. ShellCheck names it SC2318.
  local n="$1" body="$2"
  local d="$work/$n"
  mkdir -p "$d/state"
  printf '%s' "$body" > "$d/agents.toml"
  printf '%s\n' "$d"
}
dl() { HOME="$FHOME" bash "$DL" "$@"; }

# ============================= --mutation: the guards must be seen RED ===========================
if [ "$MODE" = mutation ]; then
  # THE ROW THAT MATTERS MOST: silence stops adjudicating as failure. An agent that never probed
  # would then get the same clean verdict as one that probed successfully, which is precisely the
  # silent fall-back `[mcp] required` exists to end.
  check_mut silence-is-clean \
    '      *)               bad="${bad}${s} (no probe recorded) " ;;' \
    '      *)               : ;;' \
    'a declared server with NO probe is DEGRADED'

  # A degraded result stops counting as degraded.
  check_mut degraded-ignored \
    '      degraded|absent) bad="${bad}${s} (${res}) " ;;' \
    '      degraded|absent) : ;;' \
    'a degraded probe is DEGRADED'

  # A malformed declaration reads as "none declared" — the flattering answer, which reports a
  # project that asked for a preflight as one that declined.
  # RETARGETED when `_adb_dl_mcp_key` was rewritten to use the shared layered read: the old row's
  # literal no longer existed, so it applied to nothing and the harness caught it as a row that
  # tests NOTHING — which is the harness doing its job on its own table.
  check_mut malformed-reads-as-none \
    '>&2; return 18 ;;' \
    '>&2; return 1 ;;' \
    'a malformed [mcp] required is 18, never "none declared"'

  # The report stops refusing silence: an unstated disposition would render as an empty block
  # somebody pastes into a PR body without noticing.
  check_mut report-accepts-silence \
    '  if [ "$n_consulted" -eq 0 ] && [ "$n_none" -eq 0 ]; then' \
    '  if false; then' \
    'a run that stated NO disposition is refused'

  # The evidence requirement dropped: "usable" with nothing behind it is indistinguishable from a
  # guess, which is the defect third-party-claims.md's record-what-answered rule names.
  check_mut evidence-optional \
    '  [ -n "$OPT_EVIDENCE" ] || die "probe-record: --evidence is required"' \
    '  OPT_EVIDENCE="${OPT_EVIDENCE:-x}"' \
    'probe-record demands evidence'

  # THE CONTROL-CHARACTER GUARD, deliberately not the `case` above it in the source. Tab and
  # newline ARE control characters, so disabling only that `case` changes no behaviour and the row
  # stayed GREEN while proving nothing — measured, on this suite. This is the guard with sole
  # responsibility for every other unprintable byte, and one assertion below drives it with 0x01.
  check_mut control-char-allowed \
    "tr -d '[:cntrl:]'" \
    "tr -d ''" \
    'a control character in evidence is refused'

  # THE READ-SIDE VALIDATION, added after the review reproduced a clean verdict from a record the
  # writer would never have produced. Without a row here, deleting it again is invisible.
  check_mut readers-skip-validation \
    '  _adb_dl_records "$f" >/dev/null || {' \
    '  false && {' \
    'verdict refuses a probe record with no evidence'

  # And the declaration's element check, whose absence turns a typo into a permanent degradation
  # that blames the wrong thing.
  check_mut declaration-elements-unchecked \
    '    _adb_dl_ok_server "$one" || {' \
    '    false && {' \
    'a declared server name outside the recordable charset is refused'

  prep() {
    check_copy_subtrees "$ROOT" "$1/tree" scripts base >/dev/null 2>&1 || return 1
    printf '%s\n' "$1/tree/scripts/lib/docs-lib.sh"
  }
  runner() { ( cd "$1/tree" && bash scripts/check-docs-lib.sh 2>&1 ); }

  check_mutation_pool check-docs-lib "$work" prep runner 6
  check_summary check-docs-lib
  exit 0
fi

# =============================== 1. fail-closed: silence is DEGRADED =============================
# The acceptance criterion's negative case, from the direction that matters most: an agent that
# skipped the preflight entirely must not be able to buy a clean verdict.
D1="$(fixture declared '[mcp]
required = ["context7"]
')"
dl verdict --state "$D1/state" --manifest "$D1/agents.toml" >/dev/null 2>&1
eq "$?" 10 "a declared server with NO probe is DEGRADED"
OUT="$(dl verdict --state "$D1/state" --manifest "$D1/agents.toml" 2>&1 >/dev/null)"
has "$OUT" "context7"  "…and the diagnostic names the server"
has "$OUT" "rung 3"    "…and the rung the run falls back to, so it is actionable"
has "$OUT" "recall"    "…and forbids the silent fall-back the declaration exists to prevent"

# =============================== 2. a degraded / absent server is DEGRADED =======================
# The stubbed dead server of #422's acceptance criterion. `degraded` is the auth-error-inside-200
# case the practice names; `absent` is a server that is not there at all.
dl probe-record --state "$D1/state" --server context7 --result degraded \
   --evidence 'query-docs returned an auth failure inside HTTP 200' >/dev/null 2>&1
dl verdict --state "$D1/state" --manifest "$D1/agents.toml" >/dev/null 2>&1
eq "$?" 10 "a degraded probe is DEGRADED"

D1b="$(fixture declared-absent '[mcp]
required = ["context7"]
')"
dl probe-record --state "$D1b/state" --server context7 --result absent --evidence 'no such server' >/dev/null 2>&1
dl verdict --state "$D1b/state" --manifest "$D1b/agents.toml" >/dev/null 2>&1
eq "$?" 10 "an absent server is DEGRADED"

# A usable probe is the ONLY thing that earns a clean verdict.
dl probe-record --state "$D1/state" --server context7 --result usable \
   --evidence 'resolve-library-id("bash") returned 5 libraries' >/dev/null 2>&1
dl verdict --state "$D1/state" --manifest "$D1/agents.toml" >/dev/null 2>&1
eq "$?" 0 "a usable probe earns a clean verdict"

# THE LATEST RECORD WINS, so a retry that succeeds clears a degradation. Asserted because the
# opposite reading (first-record-wins) is equally plausible from the code and would pin a run to a
# failure the operator has already fixed.
eq "$(dl verdict --state "$D1/state" --manifest "$D1/agents.toml" >/dev/null 2>&1; echo $?)" 0 \
   "…and it supersedes the earlier degraded record, so a fixed credential is not held against the run"

# =============================== 3. every server must answer, not just one =======================
# A partial pass is the subtle version of a green nobody earned.
D2="$(fixture two-servers '[mcp]
required = ["context7", "other-docs"]
')"
dl probe-record --state "$D2/state" --server context7 --result usable --evidence 'ok' >/dev/null 2>&1
dl verdict --state "$D2/state" --manifest "$D2/agents.toml" >/dev/null 2>&1
eq "$?" 10 "one of two servers answering is still DEGRADED"
OUT="$(dl verdict --state "$D2/state" --manifest "$D2/agents.toml" 2>&1 >/dev/null)"
has   "$OUT" "other-docs" "…and it names the one that did not answer"
hasnt "$OUT" "context7 (" "…and does not accuse the one that did"

# =============================== 4. the declaration read ========================================
# An undeclared `[mcp]` is the ORDINARY case and must be silent success — the duty cannot become a
# tax on every repo that does not use MCP.
D3="$(fixture undeclared '[roles]
primary = "claude"
')"
dl mcp-required --manifest "$D3/agents.toml" >/dev/null 2>&1
eq "$?" 1 "an undeclared [mcp] required reports none"
dl verdict --state "$D3/state" --manifest "$D3/agents.toml" >/dev/null 2>&1
eq "$?" 0 "…and the preflight passes with nothing to check"

# A malformed declaration is 18, NEVER "none declared". Reading a typo as undeclared reports a
# project that asked for a preflight as one that declined.
D4="$(fixture malformed '[mcp]
required = "context7"
')"
dl mcp-required --manifest "$D4/agents.toml" >/dev/null 2>&1
eq "$?" 18 'a malformed [mcp] required is 18, never "none declared"'
dl verdict --state "$D4/state" --manifest "$D4/agents.toml" >/dev/null 2>&1
eq "$?" 18 "…and the verdict refuses rather than passing"
# AND THE REPORT SAYS SO, rather than reporting the opposite. A malformed declaration is a project
# that asked for a preflight and mis-spelled it; rendering that as "declares no [mcp] required" is
# the flattering reading, in the one block whose entire job is to be audited.
dl none-needed --state "$D4/state" --justification 'trivial' >/dev/null 2>&1
dl probe-record --state "$D4/state" --server context7 --result usable --evidence ok >/dev/null 2>&1
R4="$(dl report --state "$D4/state" --manifest "$D4/agents.toml" 2>/dev/null)"
has   "$R4" "UNREADABLE"                 "the report names a malformed declaration as unreadable"
hasnt "$R4" "declares no"                "…and never as a project that declared nothing"

# An explicitly EMPTY array is a declaration that there is nothing to preflight — distinct from a
# malformed one, and distinct from absent.
D5="$(fixture empty-array '[mcp]
required = []
')"
dl verdict --state "$D5/state" --manifest "$D5/agents.toml" >/dev/null 2>&1
eq "$?" 0 "an empty [mcp] required declares nothing to preflight"

# Multiple servers on one line parse to distinct entries.
eq "$(dl mcp-required --manifest "$D2/agents.toml" | wc -l | tr -d ' ')" 2 "a two-element array parses to two servers"

# =============================== 5. the report refuses silence ==================================
# The mechanism #422 rests on: no classifier decides whether a surface needed docs, but whether the
# run SAID anything is decidable, and an empty record is a distinct code rather than empty output.
D6="$(fixture silent '[roles]
primary = "claude"
')"
dl report --state "$D6/state" --manifest "$D6/agents.toml" >/dev/null 2>&1
eq "$?" 11 "a run that stated NO disposition is refused"
OUT="$(dl report --state "$D6/state" --manifest "$D6/agents.toml" 2>&1 >/dev/null)"
has "$OUT" "unstated disposition" "…and the diagnostic names what is wrong rather than just failing"

# =============================== 6. "none needed" is a COMPLETE answer ===========================
# The proportionality rule is real, not ceremonial: a trivial run passes with no lookup. Asserted
# with a SPY on the record file proving zero consultations were recorded — a test that only looked
# for the words "none needed" would pass on an implementation that also ran every lookup.
D7="$(fixture trivial '[roles]
primary = "claude"
')"
dl none-needed --state "$D7/state" --justification 'every surface here is language-core idiom' >/dev/null 2>&1
REPORT="$(dl report --state "$D7/state" --manifest "$D7/agents.toml" 2>/dev/null)"; RRC=$?
eq "$RRC" 0 "a trivial run passes with an explicit none-needed"
has "$REPORT" "none needed" "…and the report says so"
has "$REPORT" "language-core idiom" "…carrying the justification, not just the verdict"
eq "$(awk -F'\t' '$1=="consulted"' "$D7/state/docs-consulted.tsv" | wc -l | tr -d ' ')" 0 \
   "…and NO lookup was recorded — the rule is proportional, not ceremonial"
eq "$(awk -F'\t' '$1=="probe"' "$D7/state/docs-consulted.tsv" | wc -l | tr -d ' ')" 0 \
   "…and no MCP probe either, since nothing was declared"

# =============================== 7. consulted records WHAT answered ==============================
D8="$(fixture consulted '[roles]
primary = "claude"
')"
dl consulted --state "$D8/state" --surface 'gh pr view closingIssuesReferences' --rung 3 \
   --source 'docs.github.com/graphql, fetched this run' >/dev/null 2>&1
eq "$?" 0 "a consultation is recorded"
REPORT="$(dl report --state "$D8/state" --manifest "$D8/agents.toml" 2>/dev/null)"
has "$REPORT" "rung 3" "the report carries the rung"
has "$REPORT" "docs.github.com" "…and WHAT answered, which is what makes it re-checkable"

# Rung 4 is training-data recall, which never closes a claim — it is not a consultation.
dl consulted --state "$D8/state" --surface x --rung 4 --source y >/dev/null 2>&1
eq "$?" 2 "rung 4 (recall) is refused — it never closes a claim"
dl consulted --state "$D8/state" --surface x --rung 9 --source y >/dev/null 2>&1
eq "$?" 2 "an out-of-range rung is refused"

# =============================== 8. no field may forge a record =================================
# The file is TSV read back with `IFS=<tab> read`. A tab does not garble a display — it MOVES a
# field, and a `degraded` that reads back as `usable` is the silent green this suite is about.
D9="$(fixture fields '[mcp]
required = ["context7"]
')"
TABV="$(printf 'a\tb')"
NLV="$(printf 'a\nb')"
dl probe-record --state "$D9/state" --server context7 --result usable --evidence "$TABV" >/dev/null 2>&1
eq "$?" 19 "a tab in evidence is refused"
dl probe-record --state "$D9/state" --server context7 --result usable --evidence "$NLV" >/dev/null 2>&1
eq "$?" 19 "a newline in evidence is refused"
dl probe-record --state "$D9/state" --server "bad name" --result usable --evidence ok >/dev/null 2>&1
eq "$?" 19 "a server name outside the declared charset is refused"
dl probe-record --state "$D9/state" --server context7 --result maybe --evidence ok >/dev/null 2>&1
eq "$?" 2 "an unknown --result is refused"
# A BARE CONTROL BYTE, which the tab/newline case does not name. This is the ONLY assertion
# covering the control-character guard: tab and newline are themselves control characters, so the
# two checks overlap everywhere except here, and without this one that guard could be deleted with
# nothing noticing.
dl probe-record --state "$D9/state" --server context7 --result usable \
   --evidence "$(printf 'a\001b')" >/dev/null 2>&1
eq "$?" 19 "a control character in evidence is refused"
# EVIDENCE IS MANDATORY, and that is the field's whole point rather than a nicety: "usable" with
# nothing behind it cannot be told from a guess one reader downstream, which is what
# third-party-claims.md's record-what-answered rule exists to stop.
dl probe-record --state "$D9/state" --server context7 --result usable >/dev/null 2>&1
eq "$?" 2 "probe-record demands evidence"
dl consulted --state "$D9/state" --surface x --rung 2 >/dev/null 2>&1
eq "$?" 2 "…and a consultation demands the source that answered"
[ -f "$D9/state/docs-consulted.tsv" ] && eq "$(wc -l < "$D9/state/docs-consulted.tsv" | tr -d ' ')" 0 \
  "…and none of them wrote a record"
dl verdict --state "$D9/state" --manifest "$D9/agents.toml" >/dev/null 2>&1
eq "$?" 10 "…so the server is still unproven — a refused probe never counts as one"

# =============================== 8b. hostile READ-BACK, not just write-time refusal ==============
# The suite drove every field through `probe-record` and never wrote a malformed record directly —
# so it proved the WRITER refuses bad input while the READERS accepted it. The independent review
# reproduced the consequence: a hand-written `probe<TAB>context7<TAB>usable` with no evidence
# earned exit 0 from `verdict`, which is the clean verdict nobody earned that this whole module
# exists to prevent. Write the bytes directly, then read them.
D10="$(fixture readback '[mcp]
required = ["context7"]
')"
hostile() {   # <label> <record-line>
  printf '%s\n' "$2" > "$D10/state/docs-consulted.tsv"
  dl verdict --state "$D10/state" --manifest "$D10/agents.toml" >/dev/null 2>&1
  eq "$?" 18 "verdict refuses $1"
  dl report --state "$D10/state" --manifest "$D10/agents.toml" >/dev/null 2>&1
  eq "$?" 18 "report refuses $1"
}
hostile "a probe record with no evidence"       "$(printf 'probe\tcontext7\tusable')"
hostile "a probe record with an unknown result" "$(printf 'probe\tcontext7\tmaybe\tev')"
hostile "a probe record with a bad server name" "$(printf 'probe\tbad name\tusable\tev')"
hostile "an unknown record type"                "$(printf 'bogus\tx\ty\tz')"
hostile "a consulted record with a bad rung"    "$(printf 'consulted\tsurface\t9\tsrc')"
hostile "a consulted record missing its source" "$(printf 'consulted\tsurface\t2')"
hostile "a none-needed record with extra fields" "$(printf 'none-needed\tjust\tstray')"

# A well-formed file still passes, so the validator is not simply refusing everything — the failure
# mode a whole-file check most easily degrades into.
printf 'probe\tcontext7\tusable\tresolve-library-id returned 5\nnone-needed\ttrivial\n' \
  > "$D10/state/docs-consulted.tsv"
dl verdict --state "$D10/state" --manifest "$D10/agents.toml" >/dev/null 2>&1
eq "$?" 0 "…and a well-formed file still earns a clean verdict"

# =============================== 8c. the declaration's elements ==================================
# A declared name the recorder can never accept is not a harmless typo: nothing could ever record a
# result for it, so the run would report DEGRADED forever and blame a server that was never the
# problem. Caught at the declaration, where the message can name the file to fix.
D11="$(fixture badname '[mcp]
required = ["bad name"]
')"
dl mcp-required --manifest "$D11/agents.toml" >/dev/null 2>&1
eq "$?" 18 "a declared server name outside the recordable charset is refused"
OUT="$(dl mcp-required --manifest "$D11/agents.toml" 2>&1 >/dev/null)"
has "$OUT" "DEGRADED" "…and the diagnostic says what would otherwise happen forever"
dl verdict --state "$D11/state" --manifest "$D11/agents.toml" >/dev/null 2>&1
eq "$?" 18 "…and the verdict refuses rather than degrading on a name nothing could match"

# An EMPTY repo-level declaration must not fall through to the global manifest — the operator wrote
# something, and inheriting the machine's list instead is a value they did not choose.
mkdir -p "$FHOME/.config/ai-dev-baseline"
printf '[mcp]\nrequired = ["global-only"]\n' > "$FHOME/.config/ai-dev-baseline/agents.toml"
D12="$(fixture emptyrepo '[mcp]
required = []
')"
eq "$(dl mcp-required --manifest "$D12/agents.toml" | wc -l | tr -d ' ')" 0 \
   "an empty repo declaration wins over the global one, rather than falling through to it"
rm -f "$FHOME/.config/ai-dev-baseline/agents.toml"

# =============================== 9. the call sites are wired ====================================
IMP=base/workflows/implement-issue.md
[ -f "$IMP" ] || bad "missing workflow source $IMP"
IMPTXT="$(cat "$IMP")"
has "$IMPTXT" '{{DOCS_LIB}} mcp-required' "/implement-issue reads the [mcp] declaration (#422's missing consumer)"
has "$IMPTXT" '{{DOCS_LIB}} probe-record' "…records the agent's own probe result"
has "$IMPTXT" '{{DOCS_LIB}} verdict'      "…and adjudicates it fail-closed"
has "$IMPTXT" '{{DOCS_LIB}} consulted'    "…records each surface it resolved"
has "$IMPTXT" '{{DOCS_LIB}} none-needed'  "…and can state that nothing needed resolving"
# BOTH render sites, asserted PER SECTION rather than by counting. The two are different audiences
# — the PR body is read by the reviewer, the close-out by the operator — and a run that told one
# and not the other is exactly the half-stated disposition the contract forbids. A bare
# `grep -c … 2` cannot express that: it passed on two mentions in ONE step, and it broke the moment
# step 5b gained a sentence explaining what the code returns. Slice the section, then look in it.
section() {   # <file> <heading-prefix> — the lines from that heading to the next same-level one
  awk -v h="$2" '
    index($0, h) == 1 { inb = 1; next }
    inb && /^### / { exit }
    inb { print }
  ' "$1"
}
has "$(section "$IMP" '### 10. Push + open PR')" '{{DOCS_LIB}} report' \
   "…the PR-body step renders the report"
has "$(section "$IMP" '### 11. Close-out')" '{{DOCS_LIB}} report' \
   "…and the close-out renders it too, for the other audience"
# And the step that WRITES the records is the one before them, or the reports have nothing to read.
has "$(section "$IMP" '### 5b.')" '{{DOCS_LIB}} consulted' \
   "…and step 5b is where the records are written, ahead of both"
has "$IMPTXT" 'Docs consulted' "the PR body carries the named block"

# THE EXIT-CODE ARMS, not just the command. Searching for `{{DOCS_LIB}} report` passes on a step
# that calls it and ignores every code it can return — which is the difference between a contract
# and a mention. The 11 arm is the one that matters: it is the whole mechanism #422 rests on, so
# the step must name what to do about it rather than falling into a bare `*)`.
REPORTBLOCK="$(section "$IMP" '### 10. Push + open PR')"
has "$REPORTBLOCK" '11)' "the PR-body step handles code 11 explicitly"
has "$REPORTBLOCK" 'NOTHING WAS RECORDED' "…and says what code 11 means, not merely that it exists"
has "$REPORTBLOCK" 'none-needed' "…and names the way out of it"
VERDICTBLOCK="$(section "$IMP" '### 5b.')"
for code in '0)' '10)' '18)'; do
  has "$VERDICTBLOCK" "  $code" "step 5b handles verdict code ${code%)} explicitly"
done
has "$VERDICTBLOCK" 'rung 3' "…and code 10 names the rung the run falls back to"

# The step must also state the disposition in the CLOSE-OUT, and say which of the three it was —
# a report rendered into the PR body and omitted from the operator's summary is half-stated.
CLOSEOUT="$(section "$IMP" '### 11. Close-out')"
has "$CLOSEOUT" 'none needed' "the close-out names the none-needed disposition"
has "$CLOSEOUT" 'DEGRADED'    "…and the degraded one"

# EVERY STATE-TOUCHING CALL NAMES THE STATE DIRECTORY. The library has to default to something when
# nobody passes `--state`, and any default names ONE agent's directory — so a rendered skill that
# omitted the flag would write its record into another agent's state, silently: the records are
# still written and the report still renders, only into a directory that agent's own `admit` never
# clears and its own /cleanup never sweeps. Caught in self-review after the Codex render was read
# back; asserted here because nothing else in the suite could see it.
for sub in probe-record verdict consulted none-needed report; do
  while IFS= read -r line; do
    case "$line" in
      *'--state {{STATE_DIR}}'*) ok ;;
      *) bad "the workflow calls \`$sub\` without --state {{STATE_DIR}}: [$line]" ;;
    esac
  done < <(grep -F "{{DOCS_LIB}} $sub" "$IMP")
done

# The practice must carry the trigger AND the skip list. A duty that fires on everything is one
# nobody performs, so the skip half is load-bearing rather than a softener.
PRAC="$(cat base/practices/third-party-claims.md)"
has "$PRAC" 'first time in this project' "the practice carries the proportional trigger list"
has "$PRAC" 'language-core idiom'        "…and the skip list that keeps it performable"
has "$PRAC" 'Docs consulted'             "…and names the report contract that makes it auditable"

# The state file owes /cleanup a classification and `admit` a clear — a name one can sweep and the
# other cannot is a stale file a fresh run's marker makes read as live.
W="$work/scan"; mkdir -p "$W"; : > "$W/docs-consulted.tsv"
eq "$(bash "$ROOT/scripts/lib/cleanup-lib.sh" state-scan "$W" | awk -F'\t' '{print $1}')" docs \
   "/cleanup classifies the docs record rather than leaving it permanent debris"
has "$(cat "$ROOT/scripts/lib/implement-lib.sh")" 'docs-consulted.tsv' \
   "…and preflight's clear set contains it, so it cannot outlive its run"

check_summary check-docs-lib
