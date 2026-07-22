#!/usr/bin/env bash
# ai-dev-baseline — fact-drift lint.
#
# Some FACTS are unavoidably restated in more than one hand-written doc: the gate
# axis list, the cross-agent invocation commands, the codex ≥7-minute timeout, and
# the role-resolution order. Those restatements are exactly where drift is born (issue
# #30). This lint pins each fact to a canonical source and asserts every consumer doc
# still carries the canonical token — so a value changed in one place but not the
# others fails CI instead of silently diverging.
#
# It is deliberately a small, ALLOWLISTED, positive-presence check — not a
# natural-language equivalence engine. Each rule asserts that a stable token (an axis
# name, a literal invocation string, the number 7, "420000") is PRESENT in a named
# file. It never forbids incidental wording (e.g. prose that correctly calls the
# 2-minute default "too short"), so rewording a doc never trips it; only dropping or
# changing a canonical value does. Add a fact by adding a rule below.
#
# Usage: bash scripts/check-fact-drift.sh   (exit 0 = no drift, 1 = drift found)

set -u
cd "$(dirname "$0")/.." || exit 1

fail=0
note() { printf 'fact-drift: %s\n' "$*" >&2; }

# Assert a FIXED string is present in a file.
req_fixed() { # <file> <token> <fact-label>
  if [ ! -f "$1" ]; then note "[$3] file not found: $1"; fail=1; return; fi
  grep -Fq -- "$2" "$1" || { note "[$3] canonical token '$2' missing from $1"; fail=1; }
}

# Assert an EXTENDED-REGEX pattern matches somewhere in a file.
req_regex() { # <file> <pattern> <fact-label>
  if [ ! -f "$1" ]; then note "[$3] file not found: $1"; fail=1; return; fi
  grep -Eq -- "$2" "$1" || { note "[$3] canonical pattern /$2/ missing from $1"; fail=1; }
}

# --- FACT 1: gate axes -------------------------------------------------------
# Source of truth: the _adb_emit <axis> calls in the gate detector. Every doc that
# enumerates the gate list must mention every axis, so adding an axis to the code
# without documenting it fails here.
axes="$(grep -oE '_adb_emit [a-z]+' scripts/lib/project-gates.sh | awk '{print $2}')"
[ -n "$axes" ] || { note "[gate-axes] could not derive axes from scripts/lib/project-gates.sh"; fail=1; }
for f in docs/per-project-overrides.md docs/roles-and-agents.md templates/agents.toml; do
  for a in $axes; do req_fixed "$f" "$a" "gate-axes"; done
done

# --- FACT 2: cross-agent invocations ----------------------------------------
# Canonical home: base/roles.md's cross-agent table. Every doc that restates an
# agent's non-interactive entrypoint must use the same command string.
for f in base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md; do
  req_fixed "$f" "codex exec --cd" "cross-agent-invocation"
  req_fixed "$f" "agy -p"          "cross-agent-invocation"
  req_fixed "$f" "claude -p"       "cross-agent-invocation"
done

# --- FACT 3: codex exec timeout minimum -------------------------------------
# The bound is ≥7 minutes (420000 ms). Every doc that states the codex timeout must
# carry the 7-minute bound; the two that give the millisecond form must agree on it.
for f in base/roles.md base/workflows/implement-issue.md docs/roles-and-agents.md; do
  req_regex "$f" '7[-[:space:]]min' "codex-timeout-7min"
done
for f in base/workflows/implement-issue.md docs/roles-and-agents.md; do
  req_regex "$f" '420[,]?000' "codex-timeout-ms"
done

# --- FACT 4: role-resolution order ------------------------------------------
# The order is repo agents.toml → global default manifest → built-in default.
for f in base/roles.md docs/roles-and-agents.md; do
  req_fixed "$f" "global default" "resolution-order"
  req_fixed "$f" "built-in"       "resolution-order"
done

if [ "$fail" -eq 0 ]; then
  echo "fact-drift: PASS (canonical facts consistent across their consumers)"
  exit 0
fi
echo "fact-drift: FAIL — a canonical fact diverged; fix the doc(s) above to match the source" >&2
exit 1
