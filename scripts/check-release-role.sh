#!/usr/bin/env bash
# ai-dev-baseline — release-role policy lint (issue #3).
#
# #3 resolved a DECISION, not a feature: cutting a release stays **project-owned**, and the
# baseline ships no `/release` workflow. A decision is only as durable as the thing that
# re-checks it — and this one is a NEGATIVE invariant ("no such skill exists"), which none of
# the existing checks can express. `build-drift` and `workflow-map` prove source↔render
# agreement for the workflows that DO exist; nothing notices a `base/workflows/release.md`
# appearing, because a new workflow rendering correctly is exactly what they're built to allow.
# So a future contributor could ship the very skeleton #3 rejected and every gate would stay
# green. This lint is the missing half:
#
#   1. ABSENCE — no release workflow source, and no rendered release skill in ANY agent tree.
#   2. PRESENCE — the docs that carry the decision still say so, on all four surfaces a user
#      could land on (role model, user guide, README, manifest template).
#   3. DISAMBIGUATION — `/new-release` still tells the reader it is NOT the release cutter.
#   4. THE EMIT CONTRACT — `/roadmap` still emits `/release` and still documents the
#      `release-command` override, so "no baseline /release" never degrades into "no way to
#      call yours."
#
# Like check-fact-drift.sh this is an ALLOWLISTED positive-presence check over SMALL, stable,
# load-bearing tokens (`project-owned`, `` `/release` ``, `resolve release`) — never whole prose
# sentences. Rewording a paragraph must not fail CI; dropping the *claim* must.
#
# Groups 3 and 4 assert only the base/workflows SOURCES, never the rendered SKILL.md copies:
# build.sh substitutes only {{TOKEN}} placeholders (none of these tokens contain `{{`), and
# build-drift rebuilds + diffs every agent tree, so source-token + build-drift already implies
# rendered-token. Asserting the renders too would add a dozen greps that can only fail when
# build-drift is already red, plus a hardcoded agent list to keep in sync.
#
# It stays ONE script rather than folding the presence half into check-fact-drift.sh: this
# guards a single recorded decision (D7), and a guard you have to reassemble from two files is
# harder to find and harder to reverse deliberately — which is the whole point of pinning it.
# It is wired as a second step of CI's fact-drift job (same species, ~50ms) rather than a 21st
# job.
#
# Usage: bash scripts/check-release-role.sh   (exit 0 = policy intact, 1 = violated)

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
# Group 1 detects a rendered release skill with a glob, so pathname expansion must be ON. A
# caller with `set -f` (noglob) would leave the pattern literal, matching nothing, and the
# absence check would pass while a real skill sat in the tree — a false GREEN, the one failure
# mode a policy lint must never have. Force it on rather than trusting the invoking shell.
set +f
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "release-role"

# --- 1. ABSENCE: the baseline ships no release workflow ---------------------------------------
# Assert the path does not exist. Usage: forbid_path <path> <why>
# `-e` alone is FALSE for a dangling symlink, so a `release` skill symlinked at a broken target
# would slip through the absence check — test for the link itself too.
forbid_path() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    check_note "[no-release-skill] $1 exists — $2"
    check_note "[no-release-skill] #3 decided release execution stays project-owned. If that is"
    check_note "[no-release-skill] being reversed, update base/roles.md + docs/roles-and-agents.md"
    check_note "[no-release-skill] and this lint together — deliberately, not as a side effect."
    check_fail
  fi
}

forbid_path base/workflows/release.md "the baseline must not ship a generic release workflow"
# Glob, not a hardcoded `claude codex gemini` (the repo already has ~10 copies of that triple,
# tracked by #61) — this way a newly added agent tree is covered the day it lands. An unmatched
# glob stays literal, and neither -e nor -L is true of the literal, so "no agent trees" passes.
for p in agents/*/skills/release; do
  forbid_path "$p" "no agent tree may carry a rendered release skill"
done

# --- 2. PRESENCE: every surface that carries the decision still carries it ---------------------
# `project-owned` is the decision itself; "no `/release`" is its concrete consequence. A doc that
# lost either one is a doc that would let a reader assume a release skill exists.
for f in base/roles.md docs/roles-and-agents.md README.md; do
  req_fixed "$f" 'project-owned' release-is-project-owned
  req_fixed "$f" 'no `/release`' ships-no-release-skill
done

# The trap the role model must spell out: `[roles].release` is inert until a project skill
# RESOLVES it. Without this sentence a user sets `release = "codex"` and it is silently ignored.
for f in base/roles.md docs/roles-and-agents.md; do
  req_fixed "$f" 'resolve release' release-role-must-be-resolved
done

# The manifest template is where most users meet the role — it must say the token picks an
# executor and installs nothing.
req_fixed templates/agents.toml 'installs no release skill' template-release-note

# --- 3. DISAMBIGUATION: /new-release is not /release -------------------------------------------
# The name collision is the reported UX bug (#3). Asserted on the source only — build-drift
# carries it the rest of the way to every agent's shipped skill (see the header).
# NOTE the backticks in the token. A bare `/release` would also match `/releases/latest` in the
# `gh release view` / releases-URL prose further down this same workflow — so the note could be
# deleted entirely and the assertion would still pass. The backtick-delimited code span is what
# the disambiguation actually writes, and it appears nowhere else in the file.
req_fixed base/workflows/new-release.md '`/release`'   new-release-names-the-other-command
req_fixed base/workflows/new-release.md 'project-owned' new-release-points-at-the-owned-role

# --- 4. THE EMIT CONTRACT: /roadmap emits a RESOLVABLE project-owned command -------------------
# "The baseline ships no /release" is only safe because /roadmap lets a repo NAME its own release
# command and emits that. Losing that half turns the decision into a dead end.
#
# What changed with #188: the emission must also RESOLVE. An unresolvable slash command does not
# fail loudly — Claude Code fuzzy-matches the nearest built-in, so a bare `/release` on a repo
# without one silently opens the CLI's release-notes viewer at the moment the roadmap says
# "cutting". So the old `roadmap-emits-release` token is gone deliberately: emitting the literal
# `/release` as a DEFAULT is now the bug, not the contract. These two assert what replaced it.
req_fixed base/workflows/roadmap.md 'release-command' roadmap-release-command-override
req_fixed base/workflows/roadmap.md 'RESOLVES'        roadmap-verifies-the-command-resolves
req_fixed docs/release-goal-convention.md 'release-command' convention-documents-override

# --- 5. THE ROLLOVER BOUNDARY: `roll` is bookkeeping, never a cutter (issue #74) ---------------
# #74 moved milestone rollover the OTHER way across the #3 line — out of the project-owned
# `/release` and into `baseline release roll` — on the grounds that cutting has four incompatible
# shapes while rolling has exactly one. That makes `release-convention.sh` the single file in the
# repo with both a plausible reason and a plausible path to grow into the generic cutter #3
# rejected: it already talks to the release milestones, so "while we're here, also tag it" reads
# like a feature rather than a reversal. Group 1 cannot catch that — a cutter grown INSIDE this
# helper ships no `release.md` and no skill directory, so every absence check stays green.
#
# Groups 2-4 guard PROSE, so a token-presence grep is the right instrument there. This invariant
# is about CODE, so a token grep is the wrong instrument: adding `git tag "$V"` to cmd_roll leaves
# every doc token intact and the lint green (verified — it did). Assert against the code instead,
# the way group 1 asserts against the tree.
#
# NEGATIVE half: the verbs that would make this file a release cutter.
#
# SCOPE: this catches accidental GROWTH ("while we're already in the release milestone, also tag
# it"), which is the realistic failure. It is not an adversarial sandbox — indirection such as
# `"$GIT" tag` defeats it, and is meant to: someone hiding a cutter behind a variable has already
# decided to reverse #3, and the decision record is what governs that, not a grep.
#
# Matched against the file with COMMENTS STRIPPED. The boundary is about what the code DOES, and
# this file must be able to say "roll never runs `gh release create`" in prose without failing its
# own lint. (Crude `#`-to-end-of-line stripping: it can also blank the tail of a string containing
# a literal `#`, which at worst hides a match — and no cutter command needs one.)
roll_code() { sed 's/#.*//' scripts/lib/release-convention.sh; }

roll_forbid() {   # <extended-regex> <why>
  if roll_code | grep -Eq "$1"; then
    check_note "[roll-boundary] scripts/lib/release-convention.sh matches /$1/ — $2"
    check_note "[roll-boundary] #74/D8 ships rollover as BOOKKEEPING: no version bump, changelog,"
    check_note "[roll-boundary] tag, package, publish, or deploy. Growing one here reverses #3"
    check_note "[roll-boundary] without touching anything groups 1-4 can see. If that is the"
    check_note "[roll-boundary] intent, change base/roles.md + decisions.md D7/D8 and this lint"
    check_note "[roll-boundary] together — deliberately, not as a side effect."
    check_fail
  fi
}
roll_forbid '(^|[^[:alnum:]_-])git[[:space:]]+(tag|push)([^[:alnum:]_-]|$)' 'it tags or pushes'
roll_forbid '(^|[^[:alnum:]_-])gh[[:space:]]+release([^[:alnum:]_-]|$)'    'it publishes a GitHub release'
roll_forbid '(^|[^[:alnum:]_-])(npm|pnpm|yarn|cargo|poetry)[[:space:]]+(version|publish)([^[:alnum:]_-]|$)' \
  'it bumps or publishes a package version'
# The REALISTIC growth path is not the `gh release` porcelain — this file already does everything
# through `gh api`, so a cutter grown here would too. Forbid the REST endpoints that publish a
# release or create a tag ref, and the changelog surface, independent of which verb reaches them.
roll_forbid '/releases([^[:alnum:]_-]|$)'   'it touches the releases endpoint'
roll_forbid 'refs/tags'                     'it creates or moves a tag ref'
roll_forbid '[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg]' 'it writes a changelog'

# POSITIVE half: the boundary is still STATED where a reader and an editor will meet it. One token,
# used verbatim in both files, so the claim cannot drift into two different wordings.
req_fixed scripts/lib/release-convention.sh 'milestone bookkeeping only' roll-declares-its-boundary
req_fixed docs/release-goal-convention.md   'milestone bookkeeping only' convention-documents-roll-boundary

check_result "release stays project-owned; no /release skill ships"
