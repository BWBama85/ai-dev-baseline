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
#   3. DISAMBIGUATION — `/new-release` still tells the reader it is NOT the release cutter, in
#      the source AND in every agent's rendered skill (the copy that actually ships).
#   4. THE EMIT CONTRACT — `/roadmap` still emits `/release` and still documents the
#      `release-command` override, so "no baseline /release" never degrades into "no way to
#      call yours."
#
# Like check-fact-drift.sh this is an ALLOWLISTED positive-presence check over SMALL, stable,
# load-bearing tokens (`project-owned`, `/release`, `resolve release`) — never whole prose
# sentences. Rewording a paragraph must not fail CI; dropping the *claim* must.
#
# Usage: bash scripts/check-release-role.sh   (exit 0 = policy intact, 1 = violated)

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh
check_init "release-role"

AGENTS="claude codex gemini"

# --- 1. ABSENCE: the baseline ships no release workflow ---------------------------------------
# Assert the path does not exist. Usage: forbid_path <path> <why>
forbid_path() {
  if [ -e "$1" ]; then
    check_note "[no-release-skill] $1 exists — $2"
    check_note "[no-release-skill] #3 decided release execution stays project-owned. If that is"
    check_note "[no-release-skill] being reversed, update base/roles.md + docs/roles-and-agents.md"
    check_note "[no-release-skill] and this lint together — deliberately, not as a side effect."
    check_fail
  fi
}

forbid_path base/workflows/release.md "the baseline must not ship a generic release workflow"
for a in $AGENTS; do
  forbid_path "agents/$a/skills/release" "no agent tree may carry a rendered release skill"
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
# The name collision is the reported UX bug (#3). The note must reach users, so assert it in the
# SOURCE and in every agent's RENDERED skill — build-drift proves those match, this proves the
# claim is in what actually ships.
nr_sources="base/workflows/new-release.md"
for a in $AGENTS; do nr_sources="$nr_sources agents/$a/skills/new-release/SKILL.md"; done
for f in $nr_sources; do
  req_fixed "$f" '/release' new-release-names-the-other-command
  req_fixed "$f" 'project-owned' new-release-points-at-the-owned-role
done

# --- 4. THE EMIT CONTRACT: /roadmap still points at a project-owned /release -------------------
# "The baseline ships no /release" is only safe because /roadmap emits it (never runs it) and
# lets a repo retarget the emission. Losing either half turns the decision into a dead end.
rm_sources="base/workflows/roadmap.md"
for a in $AGENTS; do rm_sources="$rm_sources agents/$a/skills/roadmap/SKILL.md"; done
for f in $rm_sources; do
  req_fixed "$f" '/release' roadmap-emits-release
  req_fixed "$f" 'release-command' roadmap-release-command-override
done
req_fixed docs/release-goal-convention.md 'release-command' convention-documents-override

check_result "release stays project-owned; no /release skill ships"
