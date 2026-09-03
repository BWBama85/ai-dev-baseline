#!/usr/bin/env bash
# ai-dev-baseline — migration-safety guard: a plain `git pull` must NEVER dangle an installed
# symlink (issue #35). Installs are symlinks into a clone, so moving an installed path breaks
# every existing install until a re-install — and `git pull` alone does not re-install.
#
# It proves the guarantee by simulation, history-aware rather than by a hand-maintained list:
#   1. clone this repo at the PR's merge-base into a throwaway HOME/clone,
#   2. run THAT revision's installer (all agents, --no-hooks) — the "already-installed" state,
#   3. check the SAME clone out to HEAD — a plain `git pull` with NO re-install,
#   4. require every installed symlink in the fake HOME to still resolve.
# A base→HEAD diff cannot catch deletion of a compat shim for a move that PREDATES the base
# (the base installer links the canonical target, not the shim), so the historical shims are
# additionally asserted explicitly — append-only as future moves add shims.
#
# THE ONE EXEMPTION, AND IT COSTS MORE THAN IT SAVES (#378). A payload that is RETIRED — deleted
# outright, not moved — cannot be compat-shimmed, because there is nothing left to point a shim
# at. Demanding one is incoherent, so step 4 accepts a dangling link whose destination HEAD
# DECLARES retired in `adb_agent_manifest_retired`. That declaration is not a free pass; it buys
# two obligations this file then enforces, and both are strictly additional to the rule above:
#
#   5. HEAD's installer must actually PRUNE every declared-retired link it finds. The exemption is
#      "nothing depends on this and it gets cleaned up", and an undischarged prune makes the
#      second half false — so HEAD's install.sh is run in the same fake HOME and the tree must
#      come back with no dangling link at all.
#   6. every row of the register must be TRUE at HEAD: its former source must be gone, and its
#      destination must be absent from the live manifest. A retirement whose payload is still
#      shipped is a declaration that would let a real move through under the exemption.
#
# Steps 5-6 read only what HEAD declares, so an undeclared dangle — which is what a MOVE produces
# — still fails exactly as it did before, with the same compat-shim prescription.
#
# Needs full history + origin/<default> (CI: actions/checkout with fetch-depth: 0).
# Usage: bash scripts/check-install-migration.sh   (exit 0 = all pass, 1 = a failure)

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
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# Single-source the default-branch resolver (don't re-implement origin/HEAD parsing here).
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/scripts/check-lib.sh"   # ok/bad/bad_quiet + check_summary

# --- compat-obligation check (independent of git history) --------------------
# The one move that has happened so far: PR #34 relocated the shared lib to scripts/lib and
# left agents/claude/scripts/lib as a compat shim. Deleting it would silently break pre-move
# installs, and a base→HEAD simulation can't catch that, so assert it directly.
compat_shim="agents/claude/scripts/lib"
if [ -L "$compat_shim" ] && [ -e "$compat_shim" ]; then
  case "$(readlink "$compat_shim")" in
    */scripts/lib|scripts/lib) ok ;;
    *) bad "compat shim $compat_shim resolves unexpectedly: $(readlink "$compat_shim")" ;;
  esac
else
  bad "compat shim missing or broken: $compat_shim (removing it dangles pre-move installs — see #35)"
fi

# --- the retirement register must be TRUE at HEAD (#378) ---------------------
# Obligation 6. Independent of git history, like the shim check above, because it is a statement
# about THIS tree: a row whose payload is still shipped, or whose destination is still in the live
# manifest, is a declaration that would wave a genuine MOVE past the exemption below.
#
# A SYNTHETIC HOME, never $HOME. Only the record's SHAPE is under test here, nothing is read from
# or written to a real install, and interpolating the runner's actual home would make the result
# depend on whose machine it ran on.
RETIRED_HOME="/ADB_MIGRATION_PROBE_HOME"
# Built with printf rather than typed as a literal: an invisible character no reviewer can see is
# one editor away from becoming a space, and the split would then silently take the whole record.
RM_TAB="$(printf '\t')"
retired_rows=0
for _rm_agent in claude codex gemini; do
  if ! _rm_reg="$(adb_agent_manifest_retired "$_rm_agent" "$ROOT" "$RETIRED_HOME")"; then
    bad "cannot enumerate $_rm_agent's retirement register (see above)"
    continue
  fi
  [ -n "$_rm_reg" ] || continue
  if ! _rm_live="$(adb_agent_manifest "$_rm_agent" "$ROOT" "$RETIRED_HOME")"; then
    bad "cannot enumerate $_rm_agent's live manifest to check its retirement register against"
    continue
  fi
  while IFS= read -r _rm_line; do
    [ -n "$_rm_line" ] || continue
    _rm_src="${_rm_line%%"$RM_TAB"*}"
    _rm_dest="${_rm_line#*"$RM_TAB"}"
    retired_rows=$(( retired_rows + 1 ))
    if [ -e "$_rm_src" ]; then
      bad "retired source still exists at HEAD: $_rm_src (a retirement whose payload is still shipped would exempt a real move)"
    else ok; fi
    if printf '%s\n' "$_rm_live" | cut -f2 | grep -Fqx -- "$_rm_dest"; then
      bad "retired destination is still in $_rm_agent's LIVE manifest: $_rm_dest (retired and shipped cannot both be true)"
    else ok; fi
  done <<REGISTER_EOF
$_rm_reg
REGISTER_EOF
done
# SAY WHAT WAS CHECKED, not merely that it passed: an empty register and a register nobody looked
# at print the same two green lines otherwise (self-review.md).
printf 'install-migration: retirement register — %d row(s) checked\n' "$retired_rows" >&2

# --- the settings surface's retirement obligation (#248, D95) ----------------
# The same rule this file already enforces for symlinks, one surface over. A payload that STOPS
# shipping a leaf cannot leave it behind: `~/.claude/settings.json` is the operator's file, so an
# orphaned key sits there forever with nobody owning it and nothing that would ever remove it —
# the settings analogue of a dangling link, and invisible in exactly the same way.
#
# History-free, like the compat-shim check above, and for the same reason: the obligation is a
# statement about HEAD's installer, not about any particular pair of commits. It is driven by
# planting a leaf in the RECEIPT that HEAD's payload does not declare, which is precisely the
# state a real retirement produces in an already-installed home.
if command -v jq >/dev/null 2>&1 && [ -s "$ROOT/agents/claude/settings.fragment.json" ]; then
  sw="$(mktemp -d)"; sh_home="$sw/home"; mkdir -p "$sh_home/.claude"
  printf '{"model":"opus","sandbox":{"network":{"strictAllowlist":true}}}\n' > "$sh_home/.claude/settings.json"
  {
    printf 'disposition installed\n'
    printf 'version 9.9.9\n'
    printf 'floor %s\n' "$(adb_claude_settings_floor)"
    printf 'leaf\t["sandbox","network","strictAllowlist"]\ttrue\n'
  } > "$sh_home/.claude/.adb-settings-owned"
  if HOME="$sh_home" bash "$ROOT/install.sh" --agent claude --no-hooks >"$sw/install.log" 2>&1; then
    if jq -e '.sandbox.network.strictAllowlist == null' "$sh_home/.claude/settings.json" >/dev/null 2>&1; then ok
    else bad "install.sh must PRUNE a settings leaf its payload no longer ships (#248) — an orphaned key in the operator's settings.json is a dangling link by another name"; fi
    jq -e '.model == "opus"' "$sh_home/.claude/settings.json" >/dev/null 2>&1 && ok \
      || bad "the retirement prune must not disturb unrelated settings"
  else
    bad "install.sh failed over a home carrying a retired settings leaf (see below)"; sed 's/^/  /' "$sw/install.log" >&2
  fi
  rm -rf "$sw"
else
  printf 'NOTE: jq or the settings payload is unavailable — skipping the settings retirement check\n' >&2
fi

# --- history-aware pull simulation -------------------------------------------
default="$(adb_default_branch .)"
base=""
for ref in "origin/$default" "$default"; do
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    base="$(git merge-base HEAD "$ref" 2>/dev/null || true)"
    [ -n "$base" ] && break
  fi
done
head="$(git rev-parse HEAD)"

if [ -z "$base" ]; then
  printf 'NOTE: no merge-base against origin/%s or %s — skipping pull simulation (need full history / fetch-depth: 0)\n' "$default" "$default" >&2
elif [ "$base" = "$head" ]; then
  printf 'NOTE: HEAD is the merge-base (no divergence) — pull simulation is a trivial pass\n' >&2
  ok
else
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  clone="$work/clone"; fh="$work/home"; mkdir -p "$fh"
  if ! git clone -q "$ROOT" "$clone" 2>/dev/null; then
    bad "could not clone repo for the migration test"
  elif ! git -C "$clone" checkout -q "$base" 2>/dev/null; then
    bad "could not checkout base $base in the migration clone"
  elif ! HOME="$fh" bash "$clone/install.sh" --agent claude --agent codex --agent gemini --no-hooks >"$work/install.log" 2>&1; then
    bad "install.sh at base $base failed (see below)"; sed 's/^/  /' "$work/install.log" >&2
  elif ! git -C "$clone" checkout -q "$head" 2>/dev/null; then
    # Simulate a plain `git pull`: same clone, now at HEAD, with NO re-install.
    bad "could not checkout HEAD $head in the migration clone"
  else
    # HEAD's register, resolved for THIS clone and THIS fake home, so the comparison below is
    # against the exact destination strings the base installer wrote. Enumerated per agent with
    # its status observed: a refusal must not arrive as an empty exemption list, which would read
    # as "nothing is retired" and turn a green run into a claim nobody checked (#324, D64).
    retired_dests=""
    for _rm_agent in claude codex gemini; do
      if ! _rm_reg="$(adb_agent_manifest_retired "$_rm_agent" "$clone" "$fh")"; then
        bad "cannot enumerate $_rm_agent's retirement register for the simulated install"
        continue
      fi
      [ -n "$_rm_reg" ] || continue
      retired_dests="$retired_dests$(printf '%s\n' "$_rm_reg" | cut -f2)
"
    done

    broken=0 exempt=0
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      [ -e "$link" ] && continue
      # A DECLARED RETIREMENT is exempt from the shim rule and from nothing else — the prune
      # obligation below is what it is exempt INTO.
      if printf '%s\n' "$retired_dests" | grep -Fqx -- "$link"; then
        exempt=$(( exempt + 1 ))
        continue
      fi
      [ "$broken" -eq 0 ] && printf 'FAIL: a plain "git pull" (base->HEAD) dangled installed symlink(s) — add a compat shim (#35), or declare the path retired in adb_agent_manifest_retired if its payload is gone for good (#378):\n' >&2
      printf '  %s\n' "$link" >&2
      broken=1
    done <<PULLSIM_EOF
$(find "$fh" -type l)
PULLSIM_EOF

    if [ "$broken" -ne 0 ]; then
      bad_quiet                       # diagnostic already printed above
    elif [ "$exempt" -eq 0 ]; then
      ok
    else
      # Obligation 5. The exemption's second half — "and it gets cleaned up" — is the half a
      # declaration cannot assert on its own, so it is executed: run HEAD's installer over the
      # same already-installed home and require the tree to come back with NO dangling link.
      printf 'install-migration: %d declared-retired link(s) dangled after the pull; requiring HEAD'"'"'s installer to prune them\n' \
        "$exempt" >&2
      if ! HOME="$fh" bash "$clone/install.sh" --agent claude --agent codex --agent gemini --no-hooks \
             >"$work/install-head.log" 2>&1; then
        bad "install.sh at HEAD failed over the base install (see below)"; sed 's/^/  /' "$work/install-head.log" >&2
      else
        left=0
        while IFS= read -r link; do
          [ -n "$link" ] || continue
          [ -e "$link" ] && continue
          [ "$left" -eq 0 ] && printf 'FAIL: HEAD'"'"'s installer left a dangling link — a retirement must be PRUNED, not merely declared (#378):\n' >&2
          printf '  %s\n' "$link" >&2
          left=1
        done <<PRUNED_EOF
$(find "$fh" -type l)
PRUNED_EOF
        if [ "$left" -eq 0 ]; then ok; else bad_quiet; fi
      fi
    fi
  fi
fi

check_summary "install-migration"
