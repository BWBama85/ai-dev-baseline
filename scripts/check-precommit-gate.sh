#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for precommit-gate.sh's fail-loud dependency loading (#35).
#
# The core guarantee: a Stop-hook quality gate that cannot load its OWN shared library is a
# broken install, so it FAILS LOUD (exit 2, blocking) — it never silently exit-0s (that was
# the fail-silent bug: enforcement secretly off). Distinct from "no gates detected" in an
# unfamiliar repo, which stays a legitimate no-op.
#
# The gate resolves its library as `$(dirname "$0")/lib`, so a COPY of the script with a
# lib/ dir we populate or empty lets us exercise present / missing-common / missing-gates.
#
# Usage: bash scripts/check-precommit-gate.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq + check_summary + check_git

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- a copy of the gate with a controllable lib/ -----------------------------
gate="$work/gate"; mkdir -p "$gate"
cp "$ROOT/agents/claude/scripts/precommit-gate.sh" "$gate/precommit-gate.sh"
set_libs() {  # both | nocommon | noproject | none
  rm -rf "${gate:?}/lib"; mkdir -p "$gate/lib"
  case "$1" in
    both)      cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/project-gates.sh" "$gate/lib/" ;;
    nocommon)  cp "$ROOT/scripts/lib/project-gates.sh" "$gate/lib/" ;;
    noproject) cp "$ROOT/scripts/lib/common.sh" "$gate/lib/" ;;
    none)      : ;;
  esac
}

# --- a fixture repo whose default branch is deterministically 'main' ---------
repo="$work/repo"; mkdir -p "$repo"
git init -q "$repo"; git -C "$repo" symbolic-ref HEAD refs/heads/main
printf 'seed\n' > "$repo/README.md"
check_git "$repo" add -A; check_git "$repo" commit -q -m seed

on_main()            { git -C "$repo" checkout -q main; git -C "$repo" clean -qfd; }
on_feature_clean()   { git -C "$repo" checkout -q -B feat main; git -C "$repo" clean -qfd; }
on_feature_change()  { on_feature_clean; printf 'x\n' > "$repo/change.txt"; }   # untracked change

# run the copied gate with CWD in the fixture; sets RC and OUT
run_gate() { OUT="$(cd "$repo" && bash "$gate/precommit-gate.sh" 2>&1)"; RC=$?; }
is_fatal() { case "$OUT" in *FATAL*) return 0 ;; *) return 1 ;; esac; }

# --- cases -------------------------------------------------------------------

# 1. libs present, on the default branch → no-op (nothing to gate).
set_libs both; on_main; run_gate
eq "$RC" "0" "libs present + default branch → exit 0"

# 2. libs present, feature branch, no changes → no-op.
set_libs both; on_feature_clean; run_gate
eq "$RC" "0" "libs present + feature branch + no changes → exit 0"

# 3. libs present, feature branch, changes, NO gates detected (no toolchain/agents.toml) → no-op.
set_libs both; on_feature_change; rm -f "$repo/agents.toml"; run_gate
eq "$RC" "0" "libs present + changes + no gates detected → exit 0 (unfamiliar-repo no-op)"

# 4. libs present, feature branch, changes, a FAILING configured gate → block (exit 2).
set_libs both; on_feature_change
printf '[gates]\ntest = "false"\n' > "$repo/agents.toml"
run_gate
eq "$RC" "2" "libs present + a failing gate → exit 2 (block)"
rm -f "$repo/agents.toml"

# 5. common.sh MISSING, feature branch, changes → FAIL LOUD (exit 2), not silent pass. [#35 core]
set_libs nocommon; on_feature_change; run_gate
eq "$RC" "2" "common.sh missing + would-gate → exit 2 (fail loud)"
if is_fatal; then ok; else bad "common.sh missing → message must be FATAL (loud), got: $OUT"; fi

# 6. common.sh MISSING, on the default branch → still FAIL LOUD: a broken install is loud
#    everywhere, because default-branch resolution itself needs common.sh (single-source).
set_libs nocommon; on_main; run_gate
eq "$RC" "2" "common.sh missing + default branch → exit 2 (broken install is loud everywhere)"

# 7. project-gates.sh MISSING (common.sh present), feature branch, changes → FAIL LOUD (exit 2).
set_libs noproject; on_feature_change; run_gate
eq "$RC" "2" "project-gates.sh missing + would-gate → exit 2 (fail loud)"
if is_fatal; then ok; else bad "project-gates.sh missing → message must be FATAL (loud), got: $OUT"; fi

# 8. project-local gate present → defer (exit 0), never touch the global gate's libs.
set_libs none; on_feature_change
mkdir -p "$repo/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.claude/scripts/precommit-gate.sh"
run_gate
eq "$RC" "0" "project-local gate present → defer (exit 0)"
rm -rf "$repo/.claude"

check_summary "precommit-gate"
