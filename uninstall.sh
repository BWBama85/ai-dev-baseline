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
AGENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS+=("$2"); shift 2 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "${#AGENTS[@]}" -eq 0 ] && AGENTS=(claude codex gemini)

info() { printf '%s\n' "$*"; }

# Remove $dest only if it is a symlink pointing inside $REPO.
unlink_if_ours() {
  local dest="$1"
  if [ -L "$dest" ]; then
    case "$(readlink "$dest")" in
      "$REPO"/*) rm -f "$dest"; info "  unlink ${dest/#$HOME/~}" ;;
      *) info "  skip   ${dest/#$HOME/~} (not ours)" ;;
    esac
  fi
}

uninstall_claude() {
  info "claude"
  unlink_if_ours "$HOME/.claude/CLAUDE.md"
  local d name
  for d in "$REPO"/agents/claude/skills/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    unlink_if_ours "$HOME/.claude/skills/$name"
  done
  local s
  for s in precommit-gate.sh implement-issue-gate.sh statusline.sh; do
    unlink_if_ours "$HOME/.claude/scripts/$s"
  done
  unlink_if_ours "$HOME/.claude/scripts/lib"

  if command -v jq >/dev/null 2>&1; then
    local settings="$HOME/.claude/settings.json"
    if [ -f "$settings" ]; then
      jq '
        if .hooks.Stop then
          .hooks.Stop |= map(select(([.hooks[]?.command // ""]
            | any(test("(precommit-gate|implement-issue-gate)\\.sh$"))) | not))
        else . end
        | if (.hooks.Stop // []) == [] then del(.hooks.Stop) else . end
      ' "$settings" > "$settings.adb.tmp" && mv "$settings.adb.tmp" "$settings"
      info "  hooks  removed global Stop gates from ~/.claude/settings.json"
    fi
  fi
}

for a in "${AGENTS[@]}"; do
  case "$a" in
    claude) uninstall_claude ;;
    codex|gemini)
      adapter="$REPO/agents/$a/adapter.sh"
      [ -f "$adapter" ] && { info "$a"; bash "$adapter" uninstall "$REPO"; } ;;
  esac
done
info ""
info "Uninstalled. Backups remain in ~/.claude/backups/ai-dev-baseline-*"
