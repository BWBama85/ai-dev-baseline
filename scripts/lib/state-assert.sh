#!/usr/bin/env bash
# state-assert.sh — perform the read AND render the sentence, in one step (issue #138).
#
# Usage:
#   state-assert.sh observe pr    <number>
#   state-assert.sh observe issue <number>
#
# Exit codes:
#   0  observed     — exactly one rendered line on stdout
#   2  usage error  — nothing on stdout
#   3  unverifiable — nothing on stdout; the reason goes to stderr
#   1  broken install — common.sh missing; nothing on stdout
#
# WHY THIS EXISTS, and why it is not just a getter.
# `base/practices/verify-before-asserting.md` forbids stating volatile external status from
# memory. It had no mechanism behind it, and was violated twice in one session with the practice
# loaded in context: a merged PR narrated as open from a 25-minute-old read, and a gate claimed to
# hold that structurally could not.
#
# A callable `pr-state` would NOT have fixed that — an agent can ignore a getter exactly as easily
# as a paragraph, and a value fetched into a variable can still go stale before the sentence that
# quotes it. So this does BOTH halves in ONE call: the authoritative read, and the finished
# sentence. Callers pass the line through unchanged. No window for the value to age; no paraphrase
# step in which an observation ("was observed OPEN") becomes a prediction ("is still open").
#
# FAIL CLOSED means stdout is EMPTY. Every unverifiable path renders NO sentence. Callers must
# treat empty stdout as "say nothing about this entity", never as licence to fall back on memory.
#
# OBSERVATIONS ARE PAST-TENSE BY CONSTRUCTION. A read supports a claim about the moment it
# happened and nothing more. "is still open" and "will hold" are claims about the future that no
# read can support — #138's second case was exactly such a prediction.
#
# SCOPE — one home per entity kind, deliberately NOT a universal state oracle. PR/issue state is
# here; "is this branch merged?" belongs to cleanup-lib.sh (it already models squash/rebase merges
# and exact-head matching) and "is the branch green?" to roadmap-lib.sh. Re-deriving either here
# would fork a second model of the same question.
#
# THIS IS A HELPER A CALLER MUST CHOOSE TO CALL. Nothing makes it mandatory: unlike
# `pr-review.sh gate`, whose exit code gates an actual merge, this renders optional narration. It
# makes a stated status correct-by-construction; it cannot make an agent state one. That gap is
# the enforcement-hooks layer's, not this file's, and the practice says so rather than implying
# otherwise.
#
# Regression-tested offline (no network) by scripts/check-state-assert.sh.

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
_adb_sa_libdir="$(dirname "${BASH_SOURCE[0]:-$0}")"
_adb_sa_common="$_adb_sa_libdir/common.sh"
if [ ! -f "$_adb_sa_common" ]; then
  printf 'state-assert: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_sa_common" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_adb_sa_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() { adb_usage "$0"; }

# A bare integer, and nothing else. Guards against a flag, a path or an empty string reaching gh.
_sa_is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# gh's own stderr is deliberately discarded at the call sites rather than captured into a temp
# file the way implement-issue-gate.sh does. The trade is conscious: this is a NARRATION helper
# whose failure mode is silence (always safe), not a gate whose failure mode is a wrong decision,
# and the operator's next move — running the same gh command by hand — surfaces the real cause.
_sa_unverifiable() {
  printf 'state-assert: unverifiable (%s) — no status rendered\n' "$1" >&2
  exit 3
}

# The checkout's `owner/repo` — derived from git's own remote so no gh environment override can move
# it — now lives in common.sh as `adb_git_origin_slug` (#173). It was private here until the PR
# guards needed the same anchor for the same reason, and a second copy of it is exactly the drift
# this file's own discipline argues against. The reasoning for asking git rather than gh is stated
# at that function.

# _sa_read <kind> <number> — the half that is identical for both entity kinds, written ONCE.
# Sets SA_STATE, SA_EXTRA (mergedAt for a PR, stateReason for an issue) and SA_AT. Exits 3 on any
# unverifiable condition, so a caller that returns has usable values by construction.
#
# EVERY READ IS PINNED TO THE CHECKOUT'S REPO WITH `--repo`, and the slug comes from `git remote`,
# NOT from gh. This is not belt-and-braces: an unqualified `gh pr view <n>` is redirected by the
# documented `GH_REPO` environment override, and then BOTH remaining guards below pass — the URL
# still has the right segment and the right number, just for a different project. Demonstrated:
# `GH_REPO=cli/cli state-assert.sh observe pr 1` rendered "PR #1 was observed MERGED" while
# standing in this repository. A `gh repo view` identity call (an earlier draft had one, at 55-70%
# of the command's wall time) could never have caught it either, because that honors `GH_REPO` too
# and would simply have agreed with itself. Asking git — which cannot be redirected by a gh env
# var — is both the correct anchor and free of a network round trip.
#
# The URL still earns its place, for a different question the number cannot answer: PRs and issues
# share ONE number space, and `gh issue view <PR number>` really does answer with the pull request.
# Only the `pull` vs `issues` path segment discriminates the two.
#
# That segment is compared EXACTLY, at its known position — never searched for anywhere in the URL.
# A substring test is not merely loose here, it is exploitable by an ordinary repo NAME: repos
# called `issues` exist in the wild (esphome/issues, cmangos/issues, tuna/issues), and this library
# installs into arbitrary projects. In such a repo a pull request URL is
# `https://github.com/acme/issues/pull/146`, which CONTAINS `/issues/` — so `observe issue 146`
# would render "issue #146 was observed CLOSED as completed" for a pull request, at exit 0, in one
# clean sentence. That is precisely the wrong-sentence outcome this file exists to make impossible,
# and the repo name silently disarmed the one guard against it.
_sa_read() {
  local kind="$1" n="$2" subcmd extra_field want_seg want_seg_kind
  case "$kind" in
    pr)    subcmd="pr";    extra_field="mergedAt";    want_seg="pull";   want_seg_kind="pull" ;;
    issue) subcmd="issue"; extra_field="stateReason"; want_seg="issues"; want_seg_kind="issue" ;;
    *) usage >&2; exit 2 ;;
  esac

  adb_require_gh jq || _sa_unverifiable "gh/jq unavailable or gh not authenticated"

  local slug
  slug="$(adb_git_origin_slug)" || _sa_unverifiable "cannot resolve this checkout's GitHub repository"

  # THE READ ITSELF LIVES IN common.sh as `adb_gh_entity`, shared with scripts/check-claims.sh.
  # It was private here until a second consumer needed the same four steps — read, parse, classify
  # the kind by URL segment, prove the answer is about the number asked for — and a second copy is
  # precisely the drift this file's own discipline argues against (the #212 review named three ways
  # the copy had already diverged). What stays here is what is genuinely this file's: the
  # exit-3-and-say-nothing contract, and the observation timestamp.
  #
  # `gh issue view` answers for a pull-request number too, which is why one reader serves both
  # kinds and the URL segment — not the subcommand — is what discriminates them.
  local rec rc got_kind
  rec="$(adb_gh_entity "$slug" "$n" "$subcmd" "$extra_field")"; rc=$?
  case "$rc" in
    1) _sa_unverifiable "gh could not read $kind #$n" ;;
    0) : ;;
    *) _sa_unverifiable "unreadable or malformed response for $kind #$n" ;;
  esac

  # Stamped AFTER the read returns, never before it starts. An earlier draft stamped first, on the
  # reasoning that erring older is conservative for a freshness claim. That reasoning is wrong: if
  # the entity changes WHILE the read is in flight — an issue reopened mid-call — a pre-read stamp
  # names an instant at which the reported state was demonstrably FALSE, and the sentence asserts
  # something that never held. The read's completion is the earliest instant the value is known to
  # have been true, so that is what "observed at" must mean.
  SA_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local url_num
  got_kind="$(printf '%s' "$rec" | cut -f1)"
  SA_STATE="$(printf '%s' "$rec" | cut -f2)"
  SA_EXTRA="$(printf '%s' "$rec" | cut -f3)"
  url_num="$(printf '%s' "$rec" | cut -f4)"
  [ -n "$SA_STATE" ] || _sa_unverifiable "malformed response for $kind #$n"

  # PRs and issues share ONE number space, so the caller's declared kind must match what came back.
  [ "$got_kind" = "$want_seg_kind" ] \
    || _sa_unverifiable "#$n is not of kind '$kind' — its URL is not a /$want_seg/ reference"
  # The response must also be ABOUT the entity that was asked for. Real gh always returns the URL
  # for the number requested, so this only fires on a misbehaving or spoofed read — but rendering
  # "PR #9" from a payload describing #146 is a wrong sentence, and this file's whole contract is
  # that a wrong sentence is worse than no sentence. `-eq` compares numerically, so a zero-padded
  # argument (`observe pr 007`) still matches its own `/pull/7` URL rather than failing spuriously.
  case "$url_num" in
    ''|*[!0-9]*) _sa_unverifiable "unparseable entity number in the URL for $kind #$n" ;;
  esac
  [ "$url_num" -eq "$n" ] \
    || _sa_unverifiable "read for $kind #$n returned data for #$url_num"
}

_sa_observe_pr() {
  _sa_read pr "$1"
  # `mergedAt` is the authority for MERGED. GitHub reports a merged PR's state as CLOSED, so
  # keying off state alone renders "closed without merging" for a PR that in fact merged — the
  # same wrong-direction error #44 fixed on the Stop-hook side.
  if [ -n "$SA_EXTRA" ]; then
    printf 'PR #%s was observed MERGED at %s\n' "$1" "$SA_AT"; return 0
  fi
  case "$SA_STATE" in
    OPEN)   printf 'PR #%s was observed OPEN at %s\n' "$1" "$SA_AT" ;;
    CLOSED) printf 'PR #%s was observed CLOSED without merging at %s\n' "$1" "$SA_AT" ;;
    *)      _sa_unverifiable "unrecognized state '$SA_STATE' for PR #$1" ;;
  esac
}

_sa_observe_issue() {
  _sa_read issue "$1"
  # NOT_PLANNED is surfaced rather than flattened into CLOSED: "closed as not planned" means the
  # work was ABANDONED, not delivered, and collapsing the two reads a cancelled requirement as a
  # satisfied one (the distinction /roadmap's release predicate also turns on).
  case "$SA_STATE" in
    OPEN) printf 'issue #%s was observed OPEN at %s\n' "$1" "$SA_AT" ;;
    CLOSED)
      # BOTH reasons are matched explicitly and everything else is unverifiable. An earlier draft
      # treated "not NOT_PLANNED" as completed, which asserts DELIVERY from the mere absence of
      # evidence — and `stateReason` is precisely the field distinguishing delivered work from
      # abandoned work. GitHub can return it null (issues closed before the field existed), so the
      # fallback was reachable and produced exactly the false-delivery claim this file prevents.
      case "$SA_EXTRA" in
        COMPLETED)   printf 'issue #%s was observed CLOSED as completed at %s\n' "$1" "$SA_AT" ;;
        NOT_PLANNED) printf 'issue #%s was observed CLOSED as NOT_PLANNED at %s\n' "$1" "$SA_AT" ;;
        *) _sa_unverifiable "issue #$1 is CLOSED with no recognized stateReason ('$SA_EXTRA') — cannot tell delivered from abandoned" ;;
      esac ;;
    *) _sa_unverifiable "unrecognized state '$SA_STATE' for issue #$1" ;;
  esac
}

# --- lint — the claim grammar (issue #195) ----------------------------------------------------
# Read agent prose on stdin; print one violation per line; exit 1 if any were found.
#
# WHY THIS EXISTS AND `observe` DID NOT SUFFICE. `observe` makes a STATED status correct; it
# cannot make anyone state one, because nothing couples its exit code to an action. The failure it
# leaves open is not "the agent did not check" — it is an agent that checked, and then wrote a
# sentence anyway. Observed 2026-07-29: a cleanup report volunteered `(OPEN at 14:55:26Z)` for a PR
# that had merged 14 minutes earlier. The reading was real; quoting it was the defect.
#
# THE GRAMMAR IS DELIBERATELY SMALL, and the practice sanctions exactly that much: a classifier
# over arbitrary English "would be theatre beyond a small documented grammar". So this is not a
# natural-language model. It is one rule:
#
#   In prose, a STATUS word appearing in the same sentence as an issue/PR reference must itself be
#   introduced by `was observed`.
#
# The check is per-OCCURRENCE, never per-sentence, and that is load-bearing: the 2026-07-29
# sentence contained a compliant `was observed MERGED` clause AND a stale `(OPEN at …)` clause. A
# sentence-level test finds the template and passes the whole line — the exact defect, unflagged.
#
# ONLY PROSE DECLARES (#117, applied here): fenced blocks, HTML comments, blockquotes and inline
# code spans are stripped BEFORE scanning, so quoting a status, documenting this grammar, or
# showing an example never trips it. That stripping is `_ADB_MD_AWK` in common.sh — THE one
# paragraph-aware CommonMark filter (#136) — and this file is one of its consumers (#251). It
# carried a private copy until then, and the copy was not merely redundant: it was WRONG in a way
# that fired on ordinary repo prose. See the block model below.
#
# WHAT THE CONVERSION FIXED, because "it was a duplicate" undersells it (#251). The old copy
# collapsed every run of 2+ backticks to one and then matched `` `[^`]*` ``, so a span fenced by
# TWO ticks whose body held a lone tick was cut at the INNER tick — leaving a fragment of the
# quoted status exposed as prose. `` ``PR ` #1 is still open`` `` therefore FIRED, blocking a turn
# for quoting a status the way this repo documents one. #251 filed that half as an unwitnessed
# approximation; it is a demonstrated false positive, and check-state-assert.sh 3b-i2 pins it.
#
# THE BLOCK MODEL IS NOW COMMONMARK`S, not this file`s, and the one visible cost is stated rather
# than discovered: an indented CODE block is structure (D27), so a 4-space-indented claim after a
# blank line no longer fires. Indented code cannot interrupt a paragraph, so a merely wrapped line
# is unaffected. Both halves are pinned.
#
# TWO VIEWS, and this reads MD_MASK: a resolved span becomes \x01 rather than being deleted, so a
# quoted example declares nothing AND cannot fuse with its neighbours into a word nobody wrote.
# The mask byte is an INTERNAL matching boundary — it is mapped back to a space before any excerpt
# reaches the caller, because the Stop hook prints that excerpt straight to the operator.
#
# BIASED TOWARD FLAGGING. A false positive costs one rephrase; a false negative costs the trust
# this practice exists to protect. The verb carve-outs below exist only to keep ordinary English
# ("open a PR", "merged the branch") from firing — never to excuse a state claim.
cmd_lint() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # A common.sh too old to carry the filter would leave `$_ADB_MD_AWK` empty, and awk would then
  # run the scan with NO structure stripping at all — every fenced, quoted and commented status in
  # the turn firing at once. That is the loud direction, but it is loud in the wrong place (the
  # operator sees a wall of bogus findings, not a broken install), so say what is actually wrong.
  # Exit 1 is the documented broken-install code, and the Stop hook already renders an exit-1 with
  # no findings as "claims are NOT being checked this turn" plus this diagnostic.
  [ -n "${_ADB_MD_AWK:-}" ] || {
    printf 'state-assert: FATAL — %s is missing the shared markdown filter (_ADB_MD_AWK); claims cannot be checked\n' \
      "$_adb_sa_common" >&2
    exit 1
  }
  # LC_ALL=C for the same reason every other consumer sets it: the scan below is byte-oriented, and
  # the mask byte is a byte.
  LC_ALL=C awk "$_ADB_MD_AWK"'
    BEGIN {
      # STATUS words. Kept tight on purpose: every addition is a new false-positive surface, and
      # the ones here are the vocabulary in which the failures actually occurred.
      # `draft` is DELIBERATELY ABSENT. It is an ordinary English noun that collides constantly
      # with prose an agent actually writes ("my first draft of the summary for #196"), and it
      # fired on exactly that within hours of shipping. Its status value is the lowest in the set —
      # a PR being a draft rarely misleads anyone in a damaging way — so it is the clearest case of
      # the precision-over-recall trade this grammar is built on: a gate that fires on ordinary
      # prose gets worked around, and then it protects nothing at all.
      split("open closed merged unmerged reopened green red passing failing", T, " ")
      # Verb usage: a status word that TAKES AN OBJECT is a verb, not a state ("open a PR",
      # "merged the branch", "closed it").
      split("a an the this that it them pr prs pull issue issues branch branches", OBJ, " ")
      # An intent marker before the word is likewise a verb ("going to open", "let me close").
      split("to will can could should would must may let lets", MOD, " ")
    }
    # --- structure stripping: only prose declares -----------------------------------------
    # BUFFER, then resolve once. The filter is paragraph-aware because a CommonMark code span may
    # cross a line ending, so it cannot be driven a line at a time — which is exactly what the
    # private copy this replaces tried to do.
    { MDL[++MDN] = $0 }
    END {
      adb_md_run()
      for (ln = 1; ln <= MDN; ln++) {
        if (MD_SKIP[ln]) continue          # a fence, a blockquote, indented code, an HTML comment
        line = MD_MASK[ln]
      # --- sentence split. Terminators only when followed by space or end of line, so a version
      # number or a timestamp is never cut in half.
      n = split(line, S, /[.!?](  *|$)/)
      for (i = 1; i <= n; i++) {
        s = S[i]
        if (s !~ /#[0-9]+/) continue         # no entity reference -> not a status claim about one
        low = tolower(s)
        for (t in T) {
          w = T[t]
          pos = 1
          while (1) {
            r = index(substr(low, pos), w)
            if (r == 0) break
            at = pos + r - 1
            pos = at + length(w)
            # whole word only
            before = (at == 1) ? " " : substr(low, at - 1, 1)
            after  = substr(low, at + length(w), 1)
            if (before ~ /[a-z0-9_]/) continue
            if (after  ~ /[a-z0-9_]/) continue
            # COMPLIANT: introduced IMMEDIATELY by the observe template.
            #
            # `was observed $` and nothing looser. An earlier draft allowed letters and spaces
            # between the phrase and the word (`was observed [a-z ]*$`), which made
            # "PR #1 was observed OPEN but is now CLOSED" pass in full: `CLOSED` found the
            # EARLIER clause`s `was observed` and inherited its compliance. That is precisely the
            # mixed compliant/stale sentence this check is per-occurrence in order to catch, so
            # the loose form defeated the design`s whole purpose.
            #
            # The multi-word renderings still pass, because only the FIRST word after the phrase
            # is a status token: `CLOSED without merging`, `CLOSED as completed`,
            # `CLOSED as NOT_PLANNED` are all introduced by `was observed CLOSED`.
            pre = substr(low, 1, at - 1)
            if (pre ~ /was observed $/) continue
            # Verb carve-outs.
            rest = substr(low, at + length(w))
            # A status word taking an ENTITY as its object is a verb: "I closed #195",
            # "reopened #5". These are reports of an action just performed, not assertions about
            # current state, and blocking them makes the gate fire on ordinary mutation summaries.
            # Checked BEFORE punctuation is stripped, because stripping `#` is exactly what left
            # `nextw` empty and misread the object as absent.
            if (rest ~ /^[[:space:]]*#[0-9]+/) continue
            sub(/^[^a-z0-9]+/, "", rest)
            nextw = rest; sub(/[^a-z0-9].*$/, "", nextw)
            skip = 0
            for (o in OBJ) if (nextw == OBJ[o]) skip = 1
            prevw = pre; sub(/[^a-z0-9]+$/, "", prevw); sub(/^.*[^a-z0-9]/, "", prevw)
            for (m in MOD) if (prevw == MOD[m]) skip = 1
            if (skip) continue
            # THE MASK BYTE NEVER LEAVES THIS PROGRAM. `s` comes from MD_MASK, so a quoted span is
            # \x01 here — and the Stop hook prints this excerpt verbatim to the operator
            # (state-claim-gate.sh). A control byte is invisible in a terminal and in a diff, so it
            # would ship unnoticed; map it back to a space, BEFORE trimming, so a span at either
            # end is trimmed away rather than left as padding.
            ex = s; gsub(MD_MASKC, " ", ex)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", ex)
            if (length(ex) > 120) ex = substr(ex, 1, 117) "..."
            # `ln`, NOT `NR`. Everything runs in END now, where NR is the record COUNT — it would
            # report the last line of the turn for every finding. The hook renders this field as
            # "line %s", so a constant there is a wrong answer, not a cosmetic one.
            printf "%d\t%s\t%s\n", ln, w, ex
            found = 1
          }
        }
      }
      }
      exit (found ? 1 : 0)
    }
  '
}

SA_STATE=""; SA_EXTRA=""; SA_AT=""

case "${1:-}" in
  lint) shift; cmd_lint "$@" ;;
  observe)
    # EXACTLY three arguments. Ignoring a tail would let `observe pr 1 --json state` render a
    # sentence while silently dropping the flag — a caller that thinks it asked a narrower
    # question gets a confident answer to a different one.
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    _sa_is_number "$3" || { usage >&2; exit 2; }
    case "$2" in
      pr)    _sa_observe_pr "$3" ;;
      issue) _sa_observe_issue "$3" ;;
      *)     usage >&2; exit 2 ;;
    esac ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
