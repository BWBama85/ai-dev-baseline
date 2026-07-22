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
# Needs full history + origin/<default> (CI: actions/checkout with fetch-depth: 0).
# Usage: bash scripts/check-install-migration.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# Single-source the default-branch resolver (don't re-implement origin/HEAD parsing here).
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/common.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

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
    broken=0
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      if [ ! -e "$link" ]; then
        [ "$broken" -eq 0 ] && printf 'FAIL: a plain "git pull" (base->HEAD) dangled installed symlink(s) — add a compat shim (#35):\n' >&2
        printf '  %s\n' "$link" >&2
        broken=1
      fi
    done <<EOF
$(find "$fh" -type l)
EOF
    if [ "$broken" -eq 0 ]; then ok; else fail=$((fail + 1)); fi
  fi
fi

printf '\ninstall-migration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "install-migration: PASS"
