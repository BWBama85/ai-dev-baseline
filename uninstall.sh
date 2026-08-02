#!/usr/bin/env bash
# ai-dev-baseline — global uninstaller.
#
# Removes only the symlinks that point back into THIS repo, and strips the global
# Stop-hook gates from ~/.claude/settings.json. Your backups under
# ~/.claude/backups/ai-dev-baseline-* are left untouched — restore from there if
# you want your pre-install files back.
#
# Usage: ./uninstall.sh [--agent claude|codex|gemini]...   (default: all present)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared shell primitives (adb_info / adb_unlink_if_ours) — the ONE home, sourced not copied.
# shellcheck source=/dev/null
. "$REPO/scripts/lib/common.sh"
# bash 5.3 runtime floor (#256) — re-exec into a >= 5.3 interpreter, or exit with instructions.
adb_require_bash "$@"
AGENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS+=("$2"); shift 2 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "${#AGENTS[@]}" -eq 0 ] && AGENTS=(claude codex gemini)

uninstall_claude() {
  adb_info "claude"
  # Remove exactly what install.sh linked, straight from the shared manifest (#48) via the shared
  # remove-side consumer — so uninstall can't drift from install (one producer, one column parse).
  adb_unlink_manifest "$REPO" <<EOF
$(adb_agent_manifest claude "$REPO" "$HOME")
EOF

  # Unwire every event we may have wired, not just Stop — a leftover SessionStart entry pointing
  # at a removed script would produce a hook error on EVERY future session. Mirrors install.sh:
  # same ownership regex (adb_claude_hook_regex, one home), applied across all hook events, and
  # an event key is dropped only once it is empty (never a user's own remaining group).
  if command -v jq >/dev/null 2>&1; then
    local settings="$HOME/.claude/settings.json"
    local re
    re="$(adb_claude_hook_regex "$HOME")"
    # `-s` not `-f`: jq reads an EMPTY file as an empty stream, exiting 0 with no output — the
    # `&&` below would then install a 0-byte settings.json and report success.
    if [ -s "$settings" ]; then
      if jq --arg re "$re" '
            if (.hooks | type) == "object" then
              .hooks |= with_entries(
                if (.value | type) == "array"
                then .value |= map(select(([.hooks[]?.command // ""] | any(test($re))) | not))
                else . end
                | select((.value | type) != "array" or (.value | length) > 0))
            else . end
          ' "$settings" > "$settings.adb.$$.tmp" && [ -s "$settings.adb.$$.tmp" ] \
             && mv "$settings.adb.$$.tmp" "$settings"; then
        adb_info "  hooks  removed global Stop gates + SessionStart currency check from ~/.claude/settings.json"
      else
        rm -f "$settings.adb.$$.tmp"
        adb_info "  WARN   could not rewrite ~/.claude/settings.json — hook entries NOT removed; edit it by hand"
      fi
    fi
  else
    adb_info "  WARN   jq not found — hook entries left in ~/.claude/settings.json; remove them by hand"
  fi
}

for a in "${AGENTS[@]}"; do
  case "$a" in
    claude) uninstall_claude ;;
    codex|gemini)
      adapter="$REPO/agents/$a/adapter.sh"
      [ -f "$adapter" ] && { adb_info "$a"; bash "$adapter" uninstall "$REPO"; } ;;
  esac
done
adb_info ""
adb_info "Uninstalled. Backups remain in ~/.claude/backups/ai-dev-baseline-*"
