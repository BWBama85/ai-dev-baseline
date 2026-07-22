#!/usr/bin/env bash
# ai-dev-baseline — global installer.
#
# Symlinks this repo's agent payloads into each selected agent's user-level config
# so your baseline practices, skills, and gates apply in EVERY project. Symlinks
# mean `git pull` in this repo updates every project at once. Existing files are
# backed up first; re-running is idempotent; `uninstall.sh` reverses it.
#
# Usage:
#   ./install.sh                       # installs the 'claude' agent + wires gates
#   ./install.sh --agent claude --agent codex
#   ./install.sh --agent claude --no-hooks
#
# Options:
#   --agent <claude|codex|gemini>   repeatable; default: claude
#   --no-hooks                      don't wire the global Stop-hook gates
#   -h, --help

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared shell primitives (adb_info / adb_link / …) — the ONE home, sourced not copied.
# shellcheck source=/dev/null
. "$REPO/scripts/lib/common.sh"
BACKUP_DIR="$HOME/.claude/backups/ai-dev-baseline-$(date +%Y%m%d-%H%M%S)"
WIRE_HOOKS=1
AGENTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS+=("$2"); shift 2 ;;
    --no-hooks) WIRE_HOOKS=0; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "${#AGENTS[@]}" -eq 0 ] && AGENTS=(claude)

install_claude() {
  adb_info "claude → ~/.claude"
  adb_link "$REPO/agents/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md" "$BACKUP_DIR"

  local d name
  for d in "$REPO"/agents/claude/skills/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    adb_link "$d" "$HOME/.claude/skills/$name" "$BACKUP_DIR"
  done

  local s
  for s in precommit-gate.sh implement-issue-gate.sh statusline.sh; do
    adb_link "$REPO/agents/claude/scripts/$s" "$HOME/.claude/scripts/$s" "$BACKUP_DIR"
  done
  # The shared shell library (scripts/lib/) installs as ~/.claude/scripts/lib so the
  # runtime gates can source common.sh / project-gates.sh as siblings.
  adb_link "$REPO/scripts/lib" "$HOME/.claude/scripts/lib" "$BACKUP_DIR"

  if [ "$WIRE_HOOKS" -eq 1 ]; then wire_hooks; else adb_info "  (gates not wired — --no-hooks)"; fi
}

wire_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — cannot wire hooks; install jq and re-run, or wire manually"
    return
  fi
  local settings="$HOME/.claude/settings.json"
  local group
  group="$(sed "s@__ADB_HOME__@$HOME@g" "$REPO/agents/claude/settings.hooks.json" | jq '.Stop[0]')"
  [ -f "$settings" ] || echo '{}' > "$settings"
  mkdir -p "$BACKUP_DIR$(dirname "$settings")"
  cp "$settings" "$BACKUP_DIR$settings"
  jq --argjson group "$group" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // [])
        | map(select(([.hooks[]?.command // ""]
              | any(test("(precommit-gate|implement-issue-gate)\\.sh$"))) | not))
        + [$group])
  ' "$settings" > "$settings.adb.tmp" && mv "$settings.adb.tmp" "$settings"
  adb_info "  hooks  wired global Stop gates into ~/.claude/settings.json (backed up)"
}

run_adapter() {
  local agent="$1"
  local adapter="$REPO/agents/$agent/adapter.sh"
  if [ -x "$adapter" ] || [ -f "$adapter" ]; then
    adb_info "$agent → (adapter)"
    bash "$adapter" install "$REPO" "$BACKUP_DIR"
  else
    adb_info "$agent → adapter not present yet (deferred) — skipping"
  fi
}

write_global_manifest() {
  local dir="$HOME/.config/ai-dev-baseline" f
  f="$dir/agents.toml"
  mkdir -p "$dir"
  if [ ! -f "$f" ]; then
    cp "$REPO/templates/agents.toml" "$f"
    adb_info "manifest → wrote global default ${f/#$HOME/~}"
  else
    adb_info "manifest → exists ${f/#$HOME/~} (left as-is)"
  fi
}

adb_info "Installing ai-dev-baseline from ${REPO/#$HOME/~}"
adb_info ""
for a in "${AGENTS[@]}"; do
  case "$a" in
    claude) install_claude ;;
    codex|gemini) run_adapter "$a" ;;
    *) adb_info "unknown agent '$a' — skipping" ;;
  esac
  adb_info ""
done
write_global_manifest

adb_info ""
adb_info "Done. Backups (if any): ${BACKUP_DIR/#$HOME/~}"
adb_info "Per project: run 'agent-init' at a repo root to set roles (see templates/agents.toml)."
adb_info "Note: a repo that ships its own .claude/scripts/precommit-gate.sh keeps winning —"
adb_info "      the global gate defers to it, so nothing double-runs."
