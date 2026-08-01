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
# BROKEN rather than out of date — a worse outcome than a stale statusline, and the opposite of
# what this file already promises. It still takes the re-exec, which is silent and strictly
# better; it just never dies of the floor.
#
# `|| :` because the diagnostic already went to stderr and a non-zero status here must not reach
# a `set -e` or become this process's exit code.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh" && adb_require_bash_advisory "$@" || :
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
