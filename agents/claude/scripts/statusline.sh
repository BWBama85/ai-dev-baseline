#!/usr/bin/env bash
# ai-dev-baseline — Claude Code statusLine.
# Reads the JSON Claude pipes to stdin, prints one short line, no slow shell-outs.
# Output format:  <model> · <ctx%> · #<pr> · <branch>
# Each field is best-effort across statusLine schema versions and omitted (never
# printed as "null"/empty) when absent.

set -euo pipefail

# bash 5.3 runtime floor (#256) — the ADVISORY form, and the distinction is this file's own
# contract rather than a preference: a statusLine renders one cosmetic string, on every render,
# and must never print an error into the UI. Hard-failing here would make a sub-floor host look
# BROKEN rather than out of date — a worse outcome than a plain statusline.
#
# ADVISORY MEANS "STOP QUIETLY", NOT "CARRY ON REGARDLESS". The re-exec is attempted first and is
# silent when it works. When it cannot, this falls back to the same bare `claude-code` line it
# already prints for a missing jq or empty input, and exits 0 — it does NOT render the rest of the
# body under a sub-floor interpreter, which is what the first cut did and what review caught. Once
# #258/#259 land 5.3-only syntax that body would fail deep, which is the failure the floor exists
# to prevent.
# The SOURCE itself is guarded, not just the gate call. `set -euo pipefail` is on by the time this
# runs, and a source that returns non-zero — an unreadable file, a corrupt one, or simply a library
# whose last statement failed — aborts the script right here, before the fallback below can print.
# Claude would then receive a failed statusLine command instead of the harmless cosmetic line this
# file promises. Review caught it; the `||` is what keeps errexit out of the decision.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" 2>/dev/null || { printf 'claude-code\n'; exit 0; }
  if command -v adb_require_bash_advisory >/dev/null 2>&1; then
    adb_require_bash_advisory "$@" 2>/dev/null || { printf 'claude-code\n'; exit 0; }
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'claude-code\n'; exit 0
fi

input="$(cat)"
if [ -z "$input" ]; then
  printf 'claude-code\n'; exit 0
fi

field() {
  for path in "$@"; do
    value="$(printf '%s' "$input" | jq -r "($path) // empty" 2>/dev/null || true)"
    if [ -n "$value" ] && [ "$value" != "null" ]; then
      printf '%s' "$value"; return 0
    fi
  done
  return 0
}

model="$(field '.model.display_name' '.model.id' '.model')"
ctx_pct="$(field '.context_window.used_percentage' '.context_window.usedPercentage' '.context.used_percentage')"
pr_num="$(field '.pr.number' '.github.pr.number' '.repo.pr.number')"
branch="$(field '.workspace.branch' '.worktree.branch' '.git.branch' '.repo.branch')"

parts=()
[ -n "$model" ] && parts+=("$model")
if [ -n "$ctx_pct" ]; then
  case "$ctx_pct" in
    *%) parts+=("$ctx_pct") ;;
    *)
      if printf '%s' "$ctx_pct" | grep -Eq '^0\.[0-9]+$'; then
        whole="$(awk -v n="$ctx_pct" 'BEGIN{printf("%d", n*100)}')"
        parts+=("${whole}%")
      else
        parts+=("${ctx_pct}%")
      fi
      ;;
  esac
fi
[ -n "$pr_num" ] && parts+=("#${pr_num}")
[ -n "$branch" ] && parts+=("$branch")

if [ "${#parts[@]}" -eq 0 ]; then
  printf 'claude-code\n'; exit 0
fi

line=""; sep=""
for p in "${parts[@]}"; do
  line+="${sep}${p}"; sep=" · "
done

cols="${COLUMNS:-80}"
case "$cols" in
  '' | *[!0-9]*) cols=80 ;;
esac
[ "$cols" -lt 20 ] && cols=80
if [ "${#line}" -gt "$cols" ]; then
  line="${line:0:$((cols - 3))}..."
fi

printf '%s\n' "$line"
