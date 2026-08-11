#!/usr/bin/env bash
# ai-dev-baseline — /cleanup decision predicates (issues #106 + #84).
#
# /cleanup is prose an agent executes, so its load-bearing DECISIONS used to live only as
# inline git/gh one-liners in the skill body — unexecutable, and therefore untestable. That is
# exactly how #106 happened: the skill decided local eligibility from `git branch --merged` plus
# `git branch -d`'s refusal, both of which are structurally blind to a squash merge, and nothing
# could prove the blindness. This library is the ONE home for those decisions so they can be
# regression-tested offline (scripts/check-cleanup.sh) and cited by the workflow instead of
# restated (the DRY discipline of docs/design-principles.md: source the shared primitive, never
# copy it). It is the same split scripts/lib/roadmap-lib.sh makes for /roadmap.
#
# NETWORK PURITY. No subcommand here ever calls `gh`. `branch-verdict` takes already-fetched PR
# JSON on stdin and does only LOCAL git object queries; `state-scan` reads the filesystem
# (deterministic and offline, not pure); `state-verdict` and `report` are pure functions of their
# arguments and stdin. The workflow owns every live read, which keeps the network shape visible
# in the skill and makes every predicate hermetically testable with a fixture.
#
# WHAT each predicate means for the operator — why a squash merge needs PR evidence, why the
# `-D` escalation is replaced by an expected-OID delete, which state is swept — is documented
# once, for the agent that executes it, in `base/workflows/cleanup.md`. This header documents the
# CONTRACT (arguments, stdin shape, exit status); the per-function comments below note only what
# the code itself cannot show.
#
# EXIT STATUS IS FAIL-CLOSED. Every subcommand prints its answer and exits 0; a malformed
# argument, unreadable JSON, or a missing dependency exits 2. The caller MUST treat 2 as a hard
# stop and preserve whatever it was about to delete — a tooling failure that read as "merged" or
# "stale" would destroy unmerged work, which is the one thing /cleanup promises never to do.
#
# Usage:
#   cleanup-lib.sh branch-verdict <branch> <base-ref>          # merged-PR JSON on stdin
#   cleanup-lib.sh state-scan     [--with-identity] <state-dir>
#   cleanup-lib.sh state-verdict  threads <pr-state>
#   cleanup-lib.sh state-verdict  marker  <pr-state> <local-ref> <remote-ref>
#   cleanup-lib.sh state-verdict  gaps    <lock 0|1> <run keep|stale|none>
#   cleanup-lib.sh state-verdict  issue   <lock 0|1> <run keep|stale|none>
#   cleanup-lib.sh state-verdict  review  <run keep|stale|none>
#   cleanup-lib.sh marker-branch   <marker-path>
#   cleanup-lib.sh marker-identity <marker-path>
#   cleanup-lib.sh file-identity   <path>
#   cleanup-lib.sh report [--tail <line>]                      # TSV "<category>\t<item>" on stdin
#   cleanup-lib.sh state-line     <root> <default-branch>
#   cleanup-lib.sh clone-state    <root> <default-branch>
#   cleanup-lib.sh -h | --help
#
# `branch-verdict` stdin is the output of:
#   gh pr list --head <branch> --state merged --limit 20 --json number,headRefOid,mergeCommit
# EMPTY stdin and `[]` both mean "no merged-PR evidence" and yield `unmerged` — that is the
# no-`gh`/no-remote degradation #106 requires (such a repo behaves exactly as it did before this
# library existed: only a true fast-forward is deletable). A live query that FAILED must never be
# piped in as empty: the caller reports that branch as unverified and preserves it.
#
# Requires: git. jq only when PR JSON is actually supplied (a jq-less box still gets `merged-ff`).

set -u

# --- required shared library (fail loud on a broken install, per design-principles §5) --------
# common.sh lives beside this file (install.sh symlinks the whole scripts/lib dir into
# ~/.<agent>/scripts/lib), so resolve it the same one-line way the sibling scripts/lib modules
# do (roadmap-lib.sh, repo-settings.sh). adb_usage vanishes without it, so a missing library
# FAILS LOUD rather than silently degrading a predicate the sweep trusts with `rm` and ref deletes.
_adb_cl_common="$(dirname "${BASH_SOURCE[0]:-$0}")/common.sh"
if [ ! -f "$_adb_cl_common" ]; then
  printf 'cleanup-lib: FATAL — required library not found: %s (broken/incomplete install)\n' "$_adb_cl_common" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$_adb_cl_common"
# bash 5.3 runtime floor (#256) — only when EXECUTED. Sourced, `$0` names the CALLER, and the
# caller is the entry point that owns the gate; re-exec'ing someone else's script from inside a
# library is not this file's decision to make. An `if`, never `[ … ] && …`: the compound form
# returns non-zero on the sourced path and would trip a caller's `set -e`.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then adb_require_bash "$@"; fi

usage() { adb_usage "$0"; }

# die <msg> — every hard error exits 2, the fail-closed "do not trust this answer" status. There
# is deliberately no status 1: a caller that treated 1 as a benign negative would delete on a
# tooling failure, and this file only ever answers questions whose wrong answer is destructive.
die() { printf 'cleanup-lib: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"
# A literal newline. NOT `NL="$(printf '\n')"`, which is the EMPTY STRING — command substitution
# strips trailing newlines, so that spelling turns every `case "$x" in *"$NL"*)` below into a
# substring test against "" that matches everything. Same trap check-cleanup.sh already documents
# for the workflow's whole-line `grep -Fxq`. The literal-in-single-quotes form is the one that
# works, and it is the idiom scripts/lib/project-gates.sh already uses.
NL='
'

# --- the record format's own safety (#273) ------------------------------------------------------
# `state-scan` serializes one record per file as `<kind>TAB<path>TAB<key>NL`, and the consumer
# parses it with `IFS=<tab> read -r kind sfile key` and hands `$sfile` to `rm -f`. A field carrying
# a raw TAB or NEWLINE therefore does not corrupt the record — it FORGES A NEW ONE, and the forged
# record's kind is attacker-chosen text that walks straight past the `other` allowlist the whole
# subcommand is built around.
#
# BOTH serialized fields can carry one, and they are not equally bad:
#   - the PATH comes from a filename, which cannot contain `/`, so a forged target is limited to
#     names in whatever directory the sweep is anchored at (the repo root: `CHANGELOG.md`,
#     `install.sh`, `CLAUDE.md`);
#   - the KEY comes from a marker's `.branch` JSON value, which CAN contain `/` — so that carrier
#     reaches an ABSOLUTE path and is strictly the worse of the two.
#
# The fix is at the record format rather than per-arm, because the defect is in the serialization
# and not in which `case` arm matched: the carrier above was classified `other`, the harmless kind.
_adb_cl_tsv_safe() { case "$1" in *"$TAB"*|*"$NL"*) return 1 ;; *) return 0 ;; esac; }

# Render a value that FAILED the test above onto ONE physical line, so a diagnostic naming it
# cannot re-open the hole in the operator's output. `%q` is the right tool and not a hand-rolled
# substitution chain: it escapes the delimiters (a newline becomes `$'\n'`) AND the backslashes,
# so the encoding stays unambiguous — a file really named `a\nb` and a file named `a<NL>b` do not
# collapse to the same rendering.
#
# THE RESULT IS RE-TESTED rather than assumed. A sanitizer's failure mode is silence: if some
# future `printf` let a delimiter through, an unchecked encoder would hand the forged bytes to the
# very record format this exists to protect, and the output would look exactly like a clean one.
# The fallback is a fixed token, which is useless to the operator and safe — the right trade when
# the alternative is a silently-forged record.
# THE ENCODER COMES FROM common.sh, which this file already sources (#218). What is local to this
# function is the TSV contract — the re-test and the fixed fallback — not the `%q` step, and two
# copies of an encoder are two things that can be fixed on one side only.
_adb_cl_tsv_display() {
  local enc
  enc="$(adb_display_value "$1")"
  if _adb_cl_tsv_safe "$enc"; then printf '%s' "$enc"; else printf '<unrenderable-name>'; fi
}

# Serialize ONE record. The identity field is appended only when the caller asked for it, and it is
# computed HERE, inside the same enumeration pass that classified the file. That binding is the whole
# point (#305): a caller that walked the FINISHED record set and fingerprinted each path would be
# describing whatever occupied it by then, so its delete-time comparison would compare a replacement
# against itself and match. It was written that way first, in workflow prose, and the independent
# review was right that "immediately after the scan" is not "with the scan".
#
# A `-` when no identity could be established, never an empty field — the same "none" spelling the
# key field already uses, and a trailing empty column is the one that goes missing in an editor.
# `file-identity` can never PRINT `-`, so the sentinel is a value no re-capture will ever equal: the
# caller's ordinary "did it change?" comparison fails closed on it with no special case to remember.
#
# `unsafe` is the one kind never fingerprinted: its path field is a `%q`-ENCODED rendering rather
# than a usable path, and it must not reach a filesystem call (#273).
_adb_cl_emit() {   # <with-identity 0|1> <kind> <path> <key>
  local id=""
  if [ "$1" = 1 ]; then
    [ "$2" = unsafe ] || id="$(cmd_file_identity "$3")"
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "${id:--}"
  else
    printf '%s\t%s\t%s\n' "$2" "$3" "$4"
  fi
}

# --- branch-verdict ---------------------------------------------------------------------------
# Classify ONE local branch against the default branch. Exit 0 for any computed verdict; 2 on bad
# input. THREE lines are printed, always in this order:
#
#   line 1  the verdict
#   line 2  the branch tip OID THE VERDICT WAS COMPUTED FROM
#   line 3  an optional human-readable detail (absent when there is nothing to say)
#
# Line 2 is not informational. The caller deletes a rewritten-merge branch with
# `git update-ref -d refs/heads/<b> <that OID>`, an ATOMIC compare-and-delete that removes the
# ref only if it still points there. Handing back the exact OID the classification used is what
# closes the window between deciding and deleting: a commit landing on the branch in between
# makes the delete fail loudly instead of destroying it. A caller that re-read the tip itself
# would be reading a DIFFERENT moment than the one that was judged, which is the same race
# wearing a longer name.
#
#   merged-ff    the branch tip is an ancestor of <base-ref>. A plain merge or a fast-forward;
#                `git branch -d` accepts it, and its own merged-only refusal re-validates the
#                answer at mutation time.
#   merged-pr    a MERGED pull request proves the content landed even though the tip is not an
#                ancestor — i.e. the merge REWROTE the commits. Line 3 names the PR.
#   unmerged     no evidence. Preserve, silently (this is the overwhelmingly common case).
#   unverified   the evidence could not be evaluated. Preserve and report LOUDLY — this is not
#                the same as "not merged", and collapsing the two is how a real problem hides.
#
# WHY `merged-pr` AND NOT `merged-squash` (#106's word): the proof is merge-method-neutral. A
# squash merge and a rebase merge both rewrite the branch's commits, so both leave the tip a
# non-ancestor while the content is fully landed, and both are recognised by exactly this rule.
# Naming the verdict after one of the two methods would read as "rebase merges are unhandled".
#
# THE TWO CONDITIONS for `merged-pr`, BOTH required:
#   (a) the PR's `mergeCommit.oid` is contained in <base-ref>. #106 asks for this, and it is what
#       makes the evidence LOCAL and current rather than a remembered "the PR was open" — the
#       staleness the old guardrail was really protecting against. A merged PR alone proves
#       nothing about THIS repo's default branch (it may have merged into another base).
#   (b) the PR's `headRefOid` EQUALS the local branch tip. #106 does not ask for this; it is
#       added because without it a branch that was squash-merged and then had NEW LOCAL COMMITS
#       added still matches (a) and would be deleted — destroying unmerged work, which is exactly
#       what the issue's own "never delete anything unproven" guardrail forbids. With it, the
#       verdict proves the local branch carries nothing beyond what landed.
#
# A `[gone]` upstream is deliberately NOT consulted here. #106 is explicit that it is
# corroborating evidence only: a branch deleted on the remote WITHOUT merging looks identical,
# so treating it as sufficient would delete abandoned-but-unmerged work.
cmd_branch_verdict() {
  [ "$#" -eq 2 ] || die "branch-verdict: needs exactly 2 args: <branch> <base-ref> (merged-PR JSON on stdin)"
  local branch="$1" base="$2" tip base_oid json cands n oid rc
  # A leading dash would be read by git as an option; an empty name resolves to nothing useful.
  case "$branch" in
    ''|-*) die "branch-verdict: <branch> must be a branch name (got '$branch')" ;;
  esac
  case "$base" in
    ''|-*) die "branch-verdict: <base-ref> must be a ref (got '$base')" ;;
  esac
  command -v git >/dev/null 2>&1 || die "branch-verdict: git is required"

  # Resolve BOTH refs up front, and refuse if either is missing. Resolving the branch through
  # refs/heads/ (never the bare name) means a tag or remote-tracking ref that happens to share the
  # name can never be classified — and then deleted — in place of the local branch.
  tip="$(git rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)"
  [ -n "$tip" ] || die "branch-verdict: no such local branch: $branch"
  base_oid="$(git rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)"
  [ -n "$base_oid" ] || die "branch-verdict: base ref not found: $base"

  # `--is-ancestor` has THREE outcomes, and conflating them is a fail-open bug: 0 = ancestor,
  # 1 = not an ancestor, anything else = git itself failed (a corrupt object store, a bad ref).
  # A naive `if git merge-base …` reads that third band as "not merged", which is the safe
  # direction here — but it is silent, and the same conflation on the PR loop below would be
  # unsafe. Classify the band explicitly in both places so the code says which it meant.
  git merge-base --is-ancestor "$tip" "$base_oid" 2>/dev/null; rc=$?
  case "$rc" in
    0) printf 'merged-ff\n%s\n' "$tip"; return 0 ;;
    1) : ;;
    *) die "branch-verdict: git merge-base failed (rc $rc) — cannot classify '$branch'" ;;
  esac

  json="$(cat)"
  # Empty stdin is the documented "no PR evidence supplied" case (no gh, no remote, or a repo
  # that simply has no merged PR for this head) — a normal negative, not an error.
  case "$json" in *[![:space:]]*) : ;; *) printf 'unmerged\n%s\n' "$tip"; return 0 ;; esac

  # jq is needed ONLY to read supplied evidence. A box without jq still gets the `merged-ff`
  # answer above, so ordinary fast-forward cleanup keeps working; it is only the PR-evidence path
  # that degrades — and it degrades to `unverified` (preserve + report), never to a quiet
  # `unmerged` that would look like a considered negative.
  if ! command -v jq >/dev/null 2>&1; then
    printf 'unverified\n%s\njq is not installed — merged-PR evidence could not be evaluated\n' "$tip"
    return 0
  fi

  # Select the PRs whose head SHA is EXACTLY this tip — condition (b) — and that carry a merge
  # commit at all. `.mergeCommit` is null for a PR GitHub reports as merged without one, so it is
  # defaulted before `.oid` is read rather than dereferenced blind.
  cands="$(printf '%s' "$json" | jq -r --arg tip "$tip" '
    # Guard the SHAPE first: a non-array (an object, an error payload, a string) must raise, not
    # quietly yield no candidates — a fail-open "unmerged" here merely preserves, but the same
    # silence on malformed input is what hides a broken caller.
    if type != "array" then error("not an array") else . end
    | .[]
    | select((.headRefOid // "") == $tip)
    | ((.mergeCommit // {}) | .oid // "") as $oid
    | select($oid != "")
    | "\(.number // 0)\t\($oid)"
  ' 2>/dev/null)" \
    || die "branch-verdict: could not parse the merged-PR JSON (malformed, or not a JSON array)"

  # Fed by a heredoc, NOT a pipe: a pipe puts the loop in a subshell, where `return 0` returns
  # from the subshell and the function falls through to the `unmerged` line below — reporting
  # every squash-merged branch as unmerged, i.e. silently reinstating #106.
  while IFS="$TAB" read -r n oid; do
    [ -n "$oid" ] || continue
    # The merge commit must be in the LOCAL object store before it can be tested. When it is not
    # (an unfetched or pruned object), `--is-ancestor` fails with a hard error; skipping such a
    # PR degrades to "cannot prove it", which preserves the branch. Checking existence first also
    # keeps the rc band below to a clean 0/1, so a genuine git failure still surfaces.
    git rev-parse --verify --quiet "$oid^{commit}" >/dev/null 2>&1 || continue
    git merge-base --is-ancestor "$oid" "$base_oid" 2>/dev/null; rc=$?
    case "$rc" in
      0) printf 'merged-pr\n%s\n#%s (merge commit %.12s)\n' "$tip" "$n" "$oid"; return 0 ;;
      1) : ;;
      *) die "branch-verdict: git merge-base failed (rc $rc) while checking PR #$n" ;;
    esac
  done <<EOF
$cands
EOF

  printf 'unmerged\n%s\n' "$tip"
}

# --- state-scan --------------------------------------------------------------------------------
# Enumerate a run-state directory and print ONE TSV record per regular file:
#   <kind>TAB<path>TAB<key>
# Deterministic and offline (it reads the filesystem, so not pure). An absent directory prints
# nothing and exits 0 — a repo that has never run a skill is a normal, empty result.
#
# `--with-identity` APPENDS A FOURTH FIELD, `file-identity`'s answer for that file or `-`:
#   <kind>TAB<path>TAB<key>TAB<identity>
# It exists because a delete has to know whether the file it is about to remove is still the file
# that was classified (#305), and only this loop can bind those two facts to one observation of the
# file. Building the same thing in a caller — walk the finished records, fingerprint each path —
# reads whatever occupies the path AFTERWARDS, so the delete-time comparison compares a replacement
# against itself and matches. That was the first implementation, and it was wrong.
#
# IT IS OPT-IN PRECISELY SO THE THREE-FIELD READERS ARE UNTOUCHED. `read -r kind sfile key` puts
# every surplus field in the LAST variable, so an unconditional fourth column would arrive silently
# inside a marker's branch name and a thread cache's PR number — the two keys the sweep acts on.
# Callers that do not delete keep asking the question they always asked.
#
# Kinds, and the key each carries:
#   threads  <pr-number>     a /resolve-pr-threads cache, `threads-<N>.json`
#   marker   <branch>|-      an /implement-issue run marker; the key is its recorded branch
#   lock     -               the gap-analysis in-flight lock
#   gaps     -               a gap-analysis artifact (prompt, findings, captured stream)
#   review   -               a code-review artifact (prompt, findings, captured stream)
#   issue    -               an /implement-issue issue SNAPSHOT, `issue-<n>.json` / `issue-<n>.assoc`
#   unsafe   -               a file whose NAME cannot be serialized (see #273 below); the path
#                            field is a `%q`-ENCODED rendering, never a usable path
#   other    -               ANYTHING ELSE
#
# `other` is emitted rather than dropped, and the workflow NEVER sweeps it. That asymmetry is the
# whole safety property of this subcommand: a sweep that deleted what it could not classify would
# eventually eat a file some future skill depends on, and the failure would look like corruption
# rather than a cleanup. Emitting the record keeps the scan's coverage visible (and testable)
# while the delete set stays an explicit allowlist. Adding a category is adding an arm here.
#
# A `threads-<junk>.json` is deliberately `other`, not a malformed `threads`: the key must be a
# PR number for the liveness read to mean anything, so a name that cannot supply one is simply
# not ours to delete.
#
# A NAME THAT CANNOT BE SERIALIZED IS `unsafe`, AND ITS RAW FORM NEVER REACHES STDOUT (#273).
# Classifying such a file `other` is NOT sufficient and was the trap worth naming: `other` is about
# which arm matched, and the record is emitted either way — so the forged second line survives the
# safest-looking classification in the file. The name has to not be printed at all, which is why
# the refusal sits ahead of the `case` rather than inside it.
#
# It is reported rather than dropped, for the same reason `other` is emitted rather than dropped:
# a sweep whose coverage is invisible cannot be audited, and "this file was skipped" is exactly
# what the operator needs to see to go rename it. The workflow renders these into its NOTES.
#
# EXIT 0, not the fail-closed 2. An unserializable name is not a tooling failure — it is a file
# this subcommand declines to classify, which is the state `other` already describes and which
# already resolves to "never deleted". The one case that IS fatal is the state DIRECTORY's own
# path (below): there, every record would be refused, and a scan that silently returns nothing is
# a no-op wearing a success message — the #106 failure class this library exists to remove.
cmd_state_scan() {
  local want_ident=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --with-identity) want_ident=1; shift ;;
      --*) die "state-scan: unknown option '$1'" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || die "state-scan: needs exactly 1 arg: <state-dir> (plus optional --with-identity)"
  local dir="$1" f base n key
  [ -d "$dir" ] || return 0
  # Checked ONCE, up front, and fatal. Every emitted path is "$dir/$base", so an unserializable
  # directory poisons every record — including the `marker` ones that decide whether a run is
  # live. Refusing them one by one would leave the caller with an empty scan indistinguishable
  # from a clean, empty state dir.
  _adb_cl_tsv_safe "$dir" \
    || die "state-scan: the state directory's own path contains a tab or newline, so no record can be serialized safely; refusing to enumerate it"
  # Both globs, so a staged `.marker.tmp` is seen (and classified `other`) rather than invisible.
  # An unmatched glob stays literal in POSIX shells, which `[ -f ]` filters — no nullglob needed.
  for f in "$dir"/* "$dir"/.[!.]*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    # AHEAD of the classification, so no arm can print the raw name. `$f` and not `$base`: the
    # emitted field is the full path, and `$dir` is already known safe from the check above, so
    # testing `$f` is testing exactly the bytes that would be written.
    if ! _adb_cl_tsv_safe "$f"; then
      _adb_cl_emit "$want_ident" unsafe "$(_adb_cl_tsv_display "$base")" '-'
      continue
    fi
    case "$base" in
      threads-*.json)
        n="${base#threads-}"; n="${n%.json}"
        case "$n" in
          ''|*[!0-9]*) _adb_cl_emit "$want_ident" other   "$f" '-' ;;
          *)           _adb_cl_emit "$want_ident" threads "$f" "$n" ;;
        esac
        ;;
      implement-issue-active.json|implement-issue-blocked.json)
        key="$(_adb_cl_marker_branch "$f")"
        _adb_cl_emit "$want_ident" marker "$f" "${key:--}"
        ;;
      gap-analysis.lock)
        _adb_cl_emit "$want_ident" lock "$f" '-'
        ;;
      # The whole gap-analysis family, not just the two names /implement-issue writes today: a
      # past run left `gaps-retry.{md,err}` behind, and #84 names that debris explicitly.
      gap-prompt.txt|gaps.md|gaps.err|gaps-*.md|gaps-*.err)
        _adb_cl_emit "$want_ident" gaps "$f" '-'
        ;;
      # /implement-issue step 8's review artifacts (#264), which had NEITHER half of the lifecycle
      # the gap set gets: preflight did not clear them and this scan classified them `other`, so
      # they were permanent. Same family shape as the gaps arm, and for the same reason — the
      # workflow writes three fixed names today, but a per-slot `review-<token>.{md,err}` is the
      # obvious next shape and would otherwise fall straight back into `other`. The PREFLIGHT set
      # in base/workflows/implement-issue.md is kept identical to this glob: a name this arm can
      # sweep but preflight cannot clear is a stale file that a fresh run's marker makes look live.
      review-prompt.txt|review.md|review.err|review-*.md|review-*.err)
        _adb_cl_emit "$want_ident" review "$f" '-'
        ;;
      # /implement-issue step 2's issue snapshot (#250) — the untrusted issue text and the
      # `author_association` provenance label that decides whether a dispatched agent is told the
      # task came from a maintainer or a stranger. They used to live at a fixed `/tmp` path, which
      # is world-writable, shared by every checkout on the host, and outside every lifecycle this
      # library models; under the state directory they get the same one both other families have.
      #
      # A DIGIT-ONLY key, exactly like the `threads` arm and for the same reason: this is a delete
      # ALLOWLIST, so a name that cannot supply the issue number it claims to carry is simply not
      # ours to delete. `issue-.json`, `issue-abc.assoc` and `issue-1.json.bak` all stay `other`.
      # The key itself is not emitted — unlike a thread cache, nothing reads liveness per issue
      # number; the whole family shares the run's own liveness (see `state-verdict issue`).
      issue-*.json|issue-*.assoc)
        # ONE suffix stripped, chosen by which one the name actually ends in. Stripping both in
        # sequence is wrong and was caught in self-review: `issue-250.assoc.json` loses `.json`,
        # then loses `.assoc`, and arrives at a bare `250` — a name nothing writes, classified
        # SWEEPABLE. An allowlist that accepts a name it cannot account for is not an allowlist.
        n="${base#issue-}"
        case "$base" in
          *.json)  n="${n%.json}" ;;
          *.assoc) n="${n%.assoc}" ;;
        esac
        case "$n" in
          ''|*[!0-9]*) _adb_cl_emit "$want_ident" other "$f" '-' ;;
          *)           _adb_cl_emit "$want_ident" issue "$f" '-' ;;
        esac
        ;;
      *)
        _adb_cl_emit "$want_ident" other "$f" '-'
        ;;
    esac
  done
}

# Print a marker's recorded branch, or nothing when it cannot be read. Deliberately quiet on
# every failure (absent jq, malformed JSON, missing key): the CALLER turns an empty key into the
# `unknown` liveness signal, which state-verdict fails closed on. Reporting the failure here
# instead would make an unreadable marker an error that stops the sweep, when the correct
# behaviour is to keep the file and carry on.
#
# A VALUE CARRYING A TAB OR NEWLINE IS TREATED AS UNREADABLE (#273), and this is the sharper half
# of that issue: unlike a filename, a JSON string may contain `/`, so a forged record from here
# names an ABSOLUTE path and is not confined to the directory the sweep is anchored at.
#
# "Unreadable" is the honest classification, not a euphemism for a refusal: `git check-ref-format`
# rejects ASCII control characters, so a `.branch` containing one is not a branch name at all and
# every ref query the caller would run with it is guaranteed to miss. The existing contract then
# does the rest — empty key -> `-` -> `unknown` -> `state-verdict marker` keeps the file.
#
# THE RECORD IS STILL EMITTED, and dropping it instead would be a second bug wearing the shape of
# a fix. The workflow derives run liveness from the PRESENCE of a `marker` record in the scan
# (`RUN_NOW=keep`); a dropped marker reads as "no run in flight", which is precisely the verdict
# that lets a LIVE run's gap and review artifacts be swept out from under it. Refusing the key
# while keeping the record fails closed on both axes at once.
# THE REJECTION HAPPENS INSIDE jq, and that placement is load-bearing rather than stylistic. Doing
# it in the shell means going through `$(…)`, which MUTATES the value before it can be judged:
#   - command substitution strips EVERY trailing newline, so `"dead-branch\n"` — not a branch name —
#     arrives as the perfectly well-formed `dead-branch`, is accepted, and (with no such ref and no
#     PR) is classified STALE and deleted. Normalizing a malformed marker into a valid-looking one
#     is the opposite of failing closed;
#   - JSON permits `\u0000`, and bash silently drops NUL bytes from a substitution *and* warns on
#     stderr — mangling `"dead\u0000branch"` into `deadbranch` and breaking this function's
#     quiet-on-every-failure contract in the same move.
# Both were reproduced under bash 5.3 by the independent review of #273.
#
# The predicate is "any ASCII CONTROL character" — codepoint < 0x20 **or** 0x7f (DEL). Both halves
# are needed: `git check-ref-format` rejects DEL as well, and an earlier version of this test that
# stopped at `< 32` let a DEL-bearing value through as an ordinary key, whereupon no ref matched, no
# PR was recorded, and `state-verdict marker` returned STALE — deleting the marker and, with it, the
# run's gap and review artifacts. That is the precise fail-open the `-` key exists to prevent, so
# the miss cost more than a cosmetic mismatch with git. Caught by the independent review.
#
# It is the CONTROL-CHARACTER class specifically, and NOT a reimplementation of `git
# check-ref-format`, which also rejects spaces, `~^:?*[`, `\`, a leading `-`, `..`, `@{` and a
# trailing `.lock`. Those are all values a ref query simply fails to find, which the existing
# no-such-ref path already handles correctly; a control character is the case that additionally
# corrupts the record this function feeds. Shelling out to git per marker to borrow the full grammar
# would buy nothing here and would put a fork in a pure string check.
#
# This is deliberately NOT `_adb_cl_tsv_safe`'s question. That one asks "can this be a TSV field"
# (tab and newline only); DEL is perfectly safe to serialize and still cannot be a branch name.
# `explode` is used instead of a regex so the test does not depend on the engine's `\u` support.
_adb_cl_marker_branch() {
  local b
  command -v jq >/dev/null 2>&1 || return 0
  b="$(jq -r 'if (.branch|type) == "string"
                 and ((.branch | explode | map(select(. < 32 or . == 127)) | length) == 0)
              then .branch else empty end' "$1" 2>/dev/null)" || return 0
  # Belt and braces: jq has already excluded the delimiters, so this can only fire if that ever
  # stops being true. A sanitizer that trusts its upstream is one upstream change from silence.
  _adb_cl_tsv_safe "$b" || return 0
  printf '%s' "$b"
}

# --- marker-branch ------------------------------------------------------------------------------
# The same read, exposed as a subcommand. The sweep must re-read a marker's branch at the MOMENT
# it deletes it (a marker atomically replaced since the scan belongs to a different run), and that
# re-read has to be byte-identical to the one that produced the scan key it is compared against —
# otherwise hardening or renaming the field here silently makes every comparison fail, every
# marker report "it changed during the sweep", and the sweep a permanent no-op. One reader, one
# home; the caller never spells the jq itself.
cmd_marker_branch() {
  [ "$#" -eq 1 ] || die "marker-branch: needs exactly 1 arg: <marker-path>"
  _adb_cl_marker_branch "$1"
  printf '\n'
}

# --- marker-identity ----------------------------------------------------------------------------
# Print a stable identity for a marker FILE, or nothing when it cannot be read. The sweep captures
# this when it classifies a marker and re-captures it at the moment of deletion; a change means the
# file is no longer the one that was judged, so it must be kept.
#
# WHY A CONTENT DIGEST AND NOT `.branch`. The race is a marker atomically REPLACED between the
# scan and the delete, and a replacement can legitimately carry the SAME branch name — retrying an
# issue whose previous branch was already swept produces the identical deterministic
# `issue-NN-slug`. Comparing only the branch therefore reports "unchanged" for a marker belonging
# to a different, live run, and deleting it disarms that run's continuation gate silently. Any
# byte differing — a new `startedAt`, a phase update, a different issue set — makes the identity
# differ, and a differing identity always resolves to KEEP.
#
# Empty output means "could not be read", which the caller must also treat as keep: an identity
# that cannot be established is not an identity that matches.
#
# `cksum` is POSIX and present on every platform this runs on. The digest only has to be stable
# and change-detecting, never cryptographic — an adversary who can rewrite this file already owns
# the state directory.
# The raw content digest, in ONE place. Both identity subcommands below need it and neither may
# spell it itself: the stderr rule this function encodes is a one-line detail that was already
# fixed once, in `implement-lib.sh`'s `_il_file_identity`, and a second and third copy is how a
# fix lands on one of them and not the others (it did — the duplicate was caught in review).
#
# THE REDIRECTION IS OUTSIDE THE PIPELINE, so the SHELL's own diagnostic is suppressed too.
# `cksum … 2>/dev/null` silences only cksum, and a failed `< "$1"` is reported by the shell BEFORE
# cksum ever runs — so an unreadable-but-present file (mode 000, or a marker owned by another user)
# leaked `cleanup-lib.sh: line N: …: Permission denied` into the sweep's stderr. /cleanup's output
# contract is terse by design (#84), and this line arrives from inside a command substitution in the
# workflow, where it reads as a failure of the step rather than as a file it declined to fingerprint.
_adb_cl_content_digest() { { cksum < "$1" | awk 'NF >= 2 { print $1 "-" $2 }'; } 2>/dev/null; }

cmd_marker_identity() {
  [ "$#" -eq 1 ] || die "marker-identity: needs exactly 1 arg: <marker-path>"
  [ -f "$1" ] || return 0
  _adb_cl_content_digest "$1"
  return 0
}

# --- file-identity ------------------------------------------------------------------------------
# Print a stable identity for ANY state file, or nothing when it cannot be established. The sweep
# captures this at the pre-delete re-scan and re-captures it immediately before `rm`; a change, or
# an identity that cannot be read at either end, means the file is no longer the one that was
# judged and it must be kept (#305).
#
# WHY THIS IS NOT `marker-identity`, WHICH ALREADY EXISTS. They answer different questions, and the
# difference is the entire bug:
#
#   marker-identity  — "are these the same BYTES?"  A pure content digest.
#   file-identity    — "is this the same FILE?"     The filesystem object AND its bytes.
#
# A content digest is structurally unable to answer the second question, and for the artifact
# families it is the second question that matters, because their replacement is routinely
# BYTE-IDENTICAL. `gh issue view` returns the same JSON for an unchanged issue, `issue-<n>.assoc`
# holds a single word like `OWNER`, and `gap-prompt.txt` is rebuilt deterministically from that same
# text. Reproduced on this repo before the fix: an `issue-305.json` unlinked and rewritten with the
# same bytes produced the IDENTICAL `cksum`, so a digest-only guard compared equal and deleted a live
# run's snapshot. A marker is the opposite case — a replacement carries a new `startedAt`, a new
# `owner` or a new phase — which is why the digest was sufficient there and still is.
#
# AND `marker-identity` MUST NOT SIMPLY BE STRENGTHENED INTO THIS. `implement-lib.sh` compares
# identities it derives from a SINGLE read of the claim's bytes (`_il_claim_probe`), because reading
# the identity and the lease as two separate opens let three contenders win one race. An identity
# with a `stat` component cannot come out of one read, so folding the two together would trade this
# bug for that one. Two questions, two primitives, one home for both.
#
# THE COMPOSITE IS BEST-EFFORT AND SAID SO PLAINLY, because the alternative is a guarantee this
# cannot keep. Three components, each defeating what the others miss:
#   inode  — an unlink-and-recreate almost always lands on a new one. NOT guaranteed: a filesystem
#            is free to reuse a just-freed inode, and some do.
#   mtime  — whole seconds (that is all `stat` offers portably). The discriminator that covers inode
#            reuse in practice: the file being judged was written by a run that has already
#            finished, so its mtime is older than the replacement's by however long ago that was.
#   cksum  — catches a modification IN PLACE, which keeps both of the above: a captured stream a
#            live dispatch is still appending to.
# What remains uncovered is a same-second recreate that also reuses the inode and produces identical
# bytes. That residual is not what keeps the sweep safe on its own — the lock and marker records in
# the same re-scan are (`state-verdict`), and they are read from the same snapshot this identity is.
#
# PORTABILITY: `ls -i` is POSIX and is how the inode is read on both CI runners; the mtime goes
# through `adb_mtime`, which already owns the BSD/GNU `stat` split and validates that what came back
# is digits (a naive `stat -f %m || stat -c %Y` exits ZERO on GNU while printing a filesystem stat).
# ANY component failing yields NO identity at all rather than a partial one — a partial identity is
# a comparison that silently stops testing what it names.
#
# THE METADATA IS READ TWICE AND MUST AGREE, which is not belt-and-braces — it closes a TORN read
# that would otherwise fail OPEN. The digest comes from the file's bytes and the inode/mtime from
# its pathname, so a successor arriving between those two reads yields old-bytes + new-metadata.
# Ordinarily that composite matches neither file and the caller keeps, which is harmless; but when
# the successor's bytes are IDENTICAL — the case this whole primitive exists for — old-bytes IS
# new-bytes, so the torn value is exactly the successor's true identity and the delete-time
# comparison happily matches it. Reading the metadata either side of the digest and refusing on any
# disagreement turns that into no identity at all. Found by the independent review.
_adb_cl_fs_stamp() {   # <path> -> "<inode>-<mtime>", or nothing
  local ino mt
  # `--` so a path that begins with a dash is an operand, not an option.
  #
  # THE RECORD COUNT IS THE GUARD, not the digit test alone — and that distinction was caught by
  # self-review after the comment here claimed the opposite. `ls -i` prints `<inode> <name>`, so a
  # name containing a NEWLINE spills onto a second line; a bare `NF >= 2 { print $1 }` then takes the
  # inode off line 1 and returns a perfectly usable identity, which is not failing closed however
  # much the surrounding prose says it is. Requiring `ls` to have produced exactly ONE line yields
  # nothing for that shape instead. Such a name cannot reach here through the sweep — `state-scan`
  # refuses to serialize it and classifies it `unsafe` (#273) — but this is a public subcommand and a
  # guard that only holds because of its caller is a guard one refactor from silence.
  ino="$(ls -i -- "$1" 2>/dev/null | awk 'NR == 1 && NF >= 2 { i = $1 } END { if (NR == 1) print i }')"
  case "$ino" in ''|*[!0-9]*) return 0 ;; esac
  mt="$(adb_mtime "$1")"
  [ -n "$mt" ] || return 0
  printf '%s-%s' "$ino" "$mt"
}

cmd_file_identity() {
  [ "$#" -eq 1 ] || die "file-identity: needs exactly 1 arg: <path>"
  local ck fs1 fs2
  # `-f` and not `-e`: a dangling symlink, a directory and a socket all have no bytes to digest, and
  # the empty answer they get here is the one that never matches, i.e. keep.
  [ -f "$1" ] || return 0
  fs1="$(_adb_cl_fs_stamp "$1")"
  [ -n "$fs1" ] || return 0
  ck="$(_adb_cl_content_digest "$1")"
  [ -n "$ck" ] || return 0
  fs2="$(_adb_cl_fs_stamp "$1")"
  [ "$fs1" = "$fs2" ] || return 0
  printf '%s-%s' "$fs1" "$ck"
}

# --- state-verdict -----------------------------------------------------------------------------
# Decide whether ONE state file is `stale` (the sweep may delete it) or `keep`. Exit 0 with a
# verdict; 2 on an unrecognised kind or signal.
#
# It takes STRUCTURED FACTS, never a caller-invented summary word. The precedence between those
# facts IS the decision, so putting it here — rather than letting each caller collapse them into
# a signal first — is the whole point of the subcommand: the rule is written once, and
# scripts/check-cleanup.sh can pin it.
#
# EVERY unknown fails closed to `keep`. Deleting run-state for a live run breaks the
# /implement-issue continuation gate (the Stop hook reads exactly these markers), and deleting a
# thread cache for an OPEN PR discards work /resolve-pr-threads still needs. Keeping a file
# nobody needs costs a few KB; deleting one somebody needs costs the run.
#
# LIVENESS IS NEVER mtime. #84 is explicit: a file's age says nothing about whether the PR or run
# it belongs to has resolved, and a mtime rule would delete a slow run's state while preserving a
# fast one's. Every fact below is a live PR state or a freshly-fetched ref.
cmd_state_verdict() {
  [ "$#" -ge 1 ] || die "state-verdict: needs a <kind> (threads|marker|gaps|issue|review)"
  local kind="$1"; shift
  case "$kind" in
    threads)
      [ "$#" -eq 1 ] || die "state-verdict threads: needs exactly 1 arg: <pr-state open|closed|merged|unknown>"
      case "$1" in
        open)          printf 'keep\n' ;;
        closed|merged) printf 'stale\n' ;;
        unknown)       printf 'keep\n' ;;
        *) die "state-verdict threads: <pr-state> must be open|closed|merged|unknown (got '$1')" ;;
      esac
      ;;
    marker)
      [ "$#" -eq 3 ] || die "state-verdict marker: needs exactly 3 args: <pr-state open|closed|merged|none|unknown> <local-ref 0|1|unknown> <remote-ref 0|1|unknown>"
      # EVERY argument is validated BEFORE any of them is acted on. Validating inside the
      # deciding `case` instead lets a short-circuit skip the check for an argument it did not
      # need — so a typo in the workflow reads as a considered verdict rather than an error.
      case "$1" in open|closed|merged|none|unknown) : ;;
        *) die "state-verdict marker: <pr-state> must be open|closed|merged|none|unknown (got '$1')" ;; esac
      case "$2" in 0|1|unknown) : ;;
        *) die "state-verdict marker: <local-ref> must be 0, 1 or unknown (got '$2')" ;; esac
      case "$3" in 0|1|unknown) : ;;
        *) die "state-verdict marker: <remote-ref> must be 0, 1 or unknown (got '$3')" ;; esac
      # An OPEN PR OUTRANKS branch absence, and that precedence is load-bearing rather than
      # tidy: after `gh pr create` the operator may delete the local branch (or /cleanup itself
      # may, in an earlier run) while the PR is still open and the run still in flight. Deciding
      # on branch absence alone would drop the active marker there and disarm the continuation
      # gate for a run that has not finished.
      case "$1" in open) printf 'keep\n'; return 0 ;; esac
      # Either ref still existing means the run's branch is alive somewhere. `unknown` — a ref
      # that could not be read — is treated as "possibly present", never as absent.
      case "$2" in 1|unknown) printf 'keep\n'; return 0 ;; esac
      case "$3" in 1|unknown) printf 'keep\n'; return 0 ;; esac
      # Both refs are provably gone. A PR state that could not be READ still fails closed: the
      # marker may belong to an open PR whose branch was tidied, which is the `keep` case above.
      case "$1" in unknown) printf 'keep\n'; return 0 ;; esac
      printf 'stale\n'
      ;;
    # ONE PREDICATE, TWO NAMES — never a second copy of it. The issue snapshot (#250) has exactly
    # the gap artifacts' lifetime: /implement-issue step 2 writes it BEFORE the branch and the run
    # marker exist, under the same claim `admit` took in preflight, and step 8 is still reading it
    # long after the marker took over. So the same two facts decide both — is a pre-marker run
    # holding the claim, and does a marker describe a live run. Giving `issue` its own arm with the
    # same body is how two answers that must agree start disagreeing after one of them is edited;
    # giving it no name at all would make base/workflows/cleanup.md ask `gaps` about a file that is
    # not a gap artifact, which reads as a copy-paste slip rather than a decision.
    #
    # THE CALLER OWES `issue` MORE THAN IT OWES `gaps`, and the shared body cannot enforce it: the
    # <run> word passed for `issue` must be read at the moment of the DELETE, the obligation the
    # `review` arm below spells out. Gap artifacts are never read after step 4, so a <run> decided
    # earlier in the sweep cannot be wrong about them in a way that matters; the snapshot is read
    # again in step 8, so a run that reached step 5 mid-sweep must show up as live. cleanup.md
    # passes `$RUN_NOW` here and `$RUN` to `gaps` for exactly that reason.
    gaps|issue)
      [ "$#" -eq 2 ] || die "state-verdict $kind: needs exactly 2 args: <lock 0|1> <run keep|stale|none>"
      # Both up front, for the reason given under `marker`: the lock short-circuits below, so
      # validating <run> only where it is read would let `gaps 1 <typo>` print a confident `keep`.
      case "$1" in 0|1) : ;; *) die "state-verdict $kind: <lock> must be 0 or 1 (got '$1')" ;; esac
      case "$2" in keep|stale|none) : ;;
        *) die "state-verdict $kind: <run> must be keep|stale|none (got '$2')" ;; esac
      # THE LOCK OUTRANKS EVERYTHING. Gap analysis runs in /implement-issue step 3, BEFORE the
      # branch and the run marker exist (step 5 owns those), so during a live gap pass there is
      # no marker to consult and the artifacts would otherwise read as a finished run's leftovers
      # — /cleanup would delete the findings of a dispatch that is still writing them. The lock
      # is the only positive in-flight signal available in that window.
      #
      # Since #202 that window is WIDER and the lock is taken EARLIER: `implement-lib.sh admit`
      # acquires it in preflight, as the run's claim, and holds it until step 5 writes the marker.
      # Nothing here changes — the file means the same thing (a pre-marker run is live), it is just
      # true for more of the run, which only ever preserves more.
      case "$1" in 1) printf 'keep\n'; return 0 ;; esac
      # No lock: the artifacts belong to whatever run the marker describes. `none` (no marker at
      # all) is a FINISHED or never-branched run — with the lock proving no dispatch is in
      # flight, there is nothing left for them to belong to.
      case "$2" in
        keep) printf 'keep\n' ;;
        *)    printf 'stale\n' ;;
      esac
      ;;
    review)
      [ "$#" -eq 1 ] || die "state-verdict review: needs exactly 1 arg: <run keep|stale|none>"
      case "$1" in keep|stale|none) : ;;
        *) die "state-verdict review: <run> must be keep|stale|none (got '$1')" ;; esac
      # NO LOCK ARGUMENT, and that asymmetry with `gaps` is the deliberate decision #264 asked for
      # rather than an omission. The gap lock exists for ONE window: gap analysis runs in
      # /implement-issue step 3, BEFORE the branch and the run marker exist (step 5 writes them),
      # so a live gap dispatch has no marker to prove liveness and its artifacts would otherwise
      # read as a finished run's leftovers. Review artifacts are written in step 8 — after step 5,
      # while the run's local branch still exists — so the marker IS the in-flight signal for
      # every reachable write, and a lock would add a second one that can leak, be cleared late,
      # and disagree with the first.
      #
      # The CALLER owes one thing in exchange: the <run> it passes must be read at the moment of
      # the delete, not at classification. base/workflows/cleanup.md derives it from the same
      # re-scan that re-reads the lock, for the reason stated there — a signal captured before a
      # marker pass that makes live PR round trips is not the signal that governs the delete.
      #
      # `stale` and `none` are both accepted and both sweep. The workflow's fresh-scan derivation
      # can only produce `keep` or `none` (a marker is present, or it is not), but a caller that
      # holds a full marker verdict must get the same answer from the word it already has.
      case "$1" in
        keep) printf 'keep\n' ;;
        *)    printf 'stale\n' ;;
      esac
      ;;
    *) die "state-verdict: unknown kind '$kind' (want threads|marker|gaps|issue|review)" ;;
  esac
}

# --- report ------------------------------------------------------------------------------------
# Render the sweep's TERSE OUTPUT CONTRACT (#84). Stdin is TSV "<category>TAB<item>" records;
# stdout is ONE line per category that has records, in first-seen order, plus the `--tail` line.
#
# EMPTY CATEGORIES CANNOT BE PRINTED — not by convention, by construction. #84's complaint is a
# run that emitted a `Deleted — remote (0)` heading and a paragraph explaining why nothing needed
# deleting; a report built by concatenating per-category sections will always drift back toward
# that, because printing a zero is what a section-shaped writer does. Here a category exists only
# if a record created it, so "omit empty categories" is not a rule anyone has to remember.
#
# Runs of items sharing a prefix, a numeric middle and a suffix collapse to a brace form —
# `threads-{41,47,51}.json` — which is what keeps twelve swept caches on ONE line instead of
# twelve. Order is preserved exactly as given (never sorted): the caller's order is the sweep's
# order, and a reader matching the report against what scrolled past should see the same
# sequence. Items that do not fit the pattern pass through verbatim, in place.
cmd_report() {
  local tail_line=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tail)
        [ "$#" -ge 2 ] || die "report: --tail needs a value"
        tail_line="$2"; shift
        ;;
      *) die "report: unknown option '$1'" ;;
    esac
    shift
  done

  LC_ALL=C awk -F'\t' '
    # split3(s, a) — 1 when s looks like <pre-><digits><.suf>, filling a["pre"/"mid"/"suf"].
    # The match is on the LAST such run, so `gaps-2.err` groups on `gaps-`/`.err` and a name
    # carrying an earlier number still groups on the one next to its extension.
    function split3(s, a,   p, n) {
      p = 0; n = 0
      while (match(substr(s, n + 1), /-[0-9]+\./)) {
        p = n + RSTART; n = p + RLENGTH - 1
      }
      if (p == 0) return 0
      a["pre"] = substr(s, 1, p)                    # up to and including the "-"
      a["mid"] = substr(s, p + 1, n - p - 1)        # the digits
      a["suf"] = substr(s, n)                       # from the "." onward
      return 1
    }
    {
      if ($1 == "" || $2 == "") next
      if (!($1 in seen)) { seen[$1] = 1; order[++nc] = $1 }
      items[$1, ++cnt[$1]] = $2
    }
    END {
      for (i = 1; i <= nc; i++) {
        c = order[i]
        # split("", arr) rather than `delete arr`: the whole-array delete is a later addition and
        # this has to run on whatever awk a stock macOS ships.
        split("", gseen); split("", gpre); split("", gsuf); split("", gmid); split("", gnum)
        ng = 0
        for (j = 1; j <= cnt[c]; j++) {
          it = items[c, j]
          # A non-matching item gets a key unique to its position, so it can never be appended
          # to and renders verbatim: pre=the item, mid=suf="" makes the 1-member form below the
          # identity. That is why there is no third "verbatim" state to carry.
          #
          # `grouped` carries whether split3 matched. Re-deriving it from the SHAPE of the key (a
          # sentinel prefix such as k ~ /^@/) would misfire on any item whose own prefix starts
          # with that sentinel — `@foo-1.txt` + `@foo-2.txt` rendered as `@foo-1.txt{,2}`. A ref
          # may legitimately begin with `@`, so the discriminator must be the fact, not a glyph.
          # NOTE: no apostrophe anywhere in this awk program — it is a single-quoted shell string,
          # and one stray apostrophe closes it and turns the whole file into a syntax error.
          grouped = split3(it, a)
          if (grouped) { k = "g" SUBSEP a["pre"] SUBSEP a["suf"] } else { k = "u" SUBSEP j }
          if (!(k in gseen)) {
            gseen[k] = ++ng
            if (grouped) { gpre[ng] = a["pre"]; gsuf[ng] = a["suf"]; gmid[ng] = a["mid"] }
            else         { gpre[ng] = it;       gsuf[ng] = "";       gmid[ng] = "" }
            gnum[ng] = 1
          } else {
            g = gseen[k]; gmid[g] = gmid[g] "," a["mid"]; gnum[g]++
          }
        }
        line = ""
        for (g = 1; g <= ng; g++) {
          if (gnum[g] == 1) piece = gpre[g] gmid[g] gsuf[g]
          else              piece = gpre[g] "{" gmid[g] "}" gsuf[g]
          line = line (line == "" ? "" : ", ") piece
        }
        printf "%s: %s\n", c, line
      }
    }
  '
  [ -n "$tail_line" ] && printf '%s\n' "$tail_line"
  return 0
}

# --- state-line ---------------------------------------------------------------------------------
# Print the report's FINAL line: one truthful sentence about where the clone ended up. Exit 0
# always (a description is never an error); 2 on bad arguments.
#
# WHY IT IS NOT A LITERAL. The obvious implementation — `printf '%s: clean, in sync with
# origin/%s'` — is a claim, and /cleanup reaches its report from several states where that claim
# is FALSE: a dirty tree it refused to switch away from, a fast-forward that failed on
# divergence, a detached HEAD, a repo with no remote at all. A closing line that always says
# "clean, in sync" is worse than no closing line, because the terse contract (#84) means it is
# the ONLY state the operator is shown.
#
# The classification itself is adb_clone_status from common.sh — the same primitive bin/baseline
# and the SessionStart currency hook use — rather than a fourth hand-rolled dirty/ahead/behind
# comparison. This subcommand only maps its word to a sentence.
cmd_state_line() {
  [ "$#" -eq 2 ] || die "state-line: needs exactly 2 args: <root> <default-branch>"
  local root="$1" default="$2" st
  [ -n "$default" ] || die "state-line: <default-branch> must not be empty"
  st="$(adb_clone_status "$root" "$default")"
  # `cur` is resolved lazily, inside the only two arms that name it — the common `current` path
  # should not fork a second git process to build a sentence that never mentions the branch.
  case "$st" in
    current)     printf '%s: clean, in sync with origin/%s\n' "$default" "$default" ;;
    behind)      printf '%s: BEHIND origin/%s — fast-forward before starting work\n' "$default" "$default" ;;
    ahead)       printf '%s: has unpushed commits (never push to the default branch)\n' "$default" ;;
    diverged)    printf '%s: DIVERGED from origin/%s — reconcile manually\n' "$default" "$default" ;;
    no-remote)   printf '%s: no origin/%s to compare against\n' "$default" "$default" ;;
    dirty)       printf '%s: working tree DIRTY — stayed on %s\n' "$default" "$(_adb_cl_head "$root")" ;;
    in-progress) printf '%s: a merge/rebase/cherry-pick is IN PROGRESS — finish or abort it\n' "$default" ;;
    detached)    printf '%s: HEAD is DETACHED — switch back to %s\n' "$default" "$default" ;;
    not-default) printf '%s: still on %s, not %s\n' "$default" "$(_adb_cl_head "$root")" "$default" ;;
    not-a-repo)  printf 'not a git repository: %s\n' "$root" ;;
    # An unrecognised word means adb_clone_status grew a state this mapping has not learned.
    # Print it rather than inventing a reassuring sentence for a condition nobody has classified.
    *)           printf '%s: %s\n' "$default" "${st:-state could not be determined}" ;;
  esac
}

# --- clone-state --------------------------------------------------------------------------------
# Print the LOCAL-ONLY safety classification of the clone, one word, exit 0. This is the guard
# step 1 branches on before it switches branches and fast-forwards.
#
# WHY NOT `git status --porcelain`: a clean porcelain is NOT proof that switching is safe.
# `git rebase` between steps, `git bisect`, an interrupted cherry-pick and a `git am` all leave
# the tree clean, and switching away from (or pulling over) one of those corrupts an operation
# the operator is in the middle of. adb_clone_local_state — the same primitive bin/baseline and
# the SessionStart currency hook refuse on — checks git's own sentinel files for exactly that.
# Routing the guard through it means step 1 refuses on the same word step 6 later reports,
# instead of one run classifying its clone two different ways.
cmd_clone_state() {
  [ "$#" -eq 2 ] || die "clone-state: needs exactly 2 args: <root> <default-branch>"
  [ -n "$2" ] || die "clone-state: <default-branch> must not be empty"
  adb_clone_local_state "$1" "$2"
}

# Print the checked-out branch name, or a readable stand-in. Only the two state-line arms that
# actually name the branch call it.
_adb_cl_head() {
  local cur
  cur="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  printf '%s' "${cur:-the current branch}"
}

# --- dispatch ----------------------------------------------------------------------------------
main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) usage; exit 0 ;;
    branch-verdict) cmd_branch_verdict "$@" ;;
    state-scan)     cmd_state_scan "$@" ;;
    state-verdict)  cmd_state_verdict "$@" ;;
    marker-branch)   cmd_marker_branch "$@" ;;
    marker-identity) cmd_marker_identity "$@" ;;
    file-identity)   cmd_file_identity "$@" ;;
    report)         cmd_report "$@" ;;
    state-line)     cmd_state_line "$@" ;;
    clone-state)    cmd_clone_state "$@" ;;
    *) printf 'cleanup-lib: unknown subcommand: %s\n' "$sub" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
