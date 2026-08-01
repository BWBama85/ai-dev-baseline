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
# bash 5.3 runtime floor (#256/#261) — SOURCED, not copied.
#
# Both issues assert the installer "cannot source common.sh — it is what installs it", and ask for
# a standalone copy of the gate as a documented exception to `source, never copy`. That premise
# does not hold: install.sh runs FROM the clone it installs, and it already sourced common.sh on
# the line above. The exception would therefore buy nothing and cost a second implementation of
# candidate resolution, version comparison and per-platform diagnostics, drifting from the first.
# What actually makes this reachable is the bootstrap carve-out on common.sh itself (D30) — that
# file stays parseable below the floor, permanently. See D31.
adb_require_bash "$@"

# WSL checkout preflight (#2). Runs here, in the installer, and NOT in every entry point: it is a
# property of this CLONE, checked once when the clone is first put to work, rather than a scan
# every gate invocation pays for. The install is also where a bad clone is cheapest to fix — the
# alternative is 59 scripts each dying at their shebang later.
#
# WHAT THIS CANNOT DO, stated because a preflight that overstates itself is worse than none: a
# FULLY CRLF-corrupted checkout cannot run this check at all. `./install.sh` dies on the `bash\r`
# shebang before line 1 executes. The guarantee for a fresh clone is .gitattributes, which pins
# these files to LF so a Windows-side clone cannot introduce CRLF in the first place; this
# preflight catches the already-cloned and partially-corrupted cases, and docs/installation.md
# names the `bash: $'\r'` symptom so the unrunnable case is still diagnosable by a human.
if ! _crlf="$(adb_crlf_scan "$REPO")"; then
  adb_info "install.sh: FATAL — CRLF line endings in this clone's shell files:"
  printf '%s\n' "$_crlf" | sed 's/^/  /' >&2
  adb_crlf_remedy
  exit 1
fi
adb_drvfs_warn "$REPO"

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
  local rc=0
  adb_info "claude → ~/.claude"
  # The install surface (root doc, every skill, the runtime scripts, and the shared
  # scripts/lib) is enumerated ONCE by adb_agent_manifest — install.sh links it, uninstall.sh
  # removes it, and bin/baseline verifies it, so the three can't drift (#48). scripts/lib links
  # at its canonical path; a plain `git pull` keeps pre-#34 installs working via the compat
  # shim, and this re-run self-heals them to the direct link (do NOT delete that shim).
  # Capture the accumulated status so a missing source (adb_link's guard) makes the installer
  # exit non-zero rather than silently leaving a dangling link.
  adb_link_manifest "$BACKUP_DIR" <<EOF || rc=1
$(adb_agent_manifest claude "$REPO" "$HOME")
EOF

  # Propagate a wiring failure into the install's exit status. Without this the `return 1`s in
  # wire_hooks are dead: install.sh would exit 0 with a corrupt settings.json, and bin/baseline's
  # adb_self_heal — which gates only on that status — would report "update complete" while the
  # gates sat silently unwired. (A missing jq deliberately returns 0; see wire_hooks.)
  if [ "$WIRE_HOOKS" -eq 1 ]; then
    wire_hooks || rc=1
  else
    adb_info "  (gates not wired — --no-hooks)"
  fi
  return "$rc"
}

# Merge EVERY hook-event group in agents/claude/settings.hooks.json into ~/.claude/settings.json.
# Driven by that file's own top-level keys (Stop, SessionStart, …) rather than a hardcoded event
# name, so adding an event there is the only edit a new hook needs here.
#
# Idempotent and non-destructive in one filter: for each event, drop the groups that reference
# one of OUR hook scripts (adb_claude_hook_regex — derived from the single hook enumeration in
# common.sh), then append ours. A user's own groups under the same event never match the regex,
# so they survive; a re-run replaces our previous entry instead of double-adding it.
#
# Returns non-zero on failure. That matters: the previous version ended with an unconditional
# "wired" line even when jq or mv had failed, so a broken settings.json was reported as success
# and enforcement was silently off.
wire_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    # The ONE tolerated degradation, and a documented one (docs/installation.md): warn, but do
    # not fail the install. Every other failure below is a genuinely broken state and returns 1.
    adb_info "  WARN   jq not found — cannot wire hooks; install jq and re-run, or wire manually"
    return 0
  fi
  local settings="$HOME/.claude/settings.json"
  local tmp groups re
  groups="$(sed "s@__ADB_HOME__@$HOME@g" "$REPO/agents/claude/settings.hooks.json")" || {
    adb_info "  WARN   could not read agents/claude/settings.hooks.json — hooks NOT wired"; return 1; }
  re="$(adb_claude_hook_regex "$HOME")"
  # `-s`, not `-f`: an EMPTY settings.json is not valid JSON, but `jq` reads empty input as an
  # empty stream — it exits 0 and prints NOTHING, so the guard below would not fire and the `mv`
  # would install a 0-byte file while reporting success. That failure is self-entrenching:
  # bin/baseline's adb_hooks_wired then sees no precommit-gate.sh, concludes the user chose
  # --no-hooks, and passes --no-hooks to every future self-heal, so the gates never come back.
  [ -s "$settings" ] || echo '{}' > "$settings"
  mkdir -p "$BACKUP_DIR$(dirname "$settings")"
  cp "$settings" "$BACKUP_DIR$settings"
  # A per-process temp name in the same directory: two installs (or two SessionStart-triggered
  # self-heals) racing on one fixed path could `mv` each other's half-written file into place.
  tmp="$settings.adb.$$.tmp"
  if ! jq --argjson groups "$groups" --arg re "$re" '
        .hooks = (.hooks // {})
        | reduce ($groups | to_entries[]) as $e (.;
            .hooks[$e.key] = (((.hooks[$e.key] // [])
              | map(select(([.hooks[]?.command // ""] | any(test($re))) | not)))
              + $e.value))
      ' "$settings" > "$tmp"; then
    rm -f "$tmp"
    adb_info "  WARN   ~/.claude/settings.json is not valid JSON — hooks NOT wired (restore from the backup)"
    return 1
  fi
  # Belt to the -s brace above: never replace the real file with an empty one, whatever the
  # reason (a full disk truncates the write just as effectively as an empty input does).
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    adb_info "  WARN   hook wiring produced an empty settings.json — NOT wired (original left intact)"
    return 1
  fi
  mv "$tmp" "$settings" || {
    rm -f "$tmp"
    adb_info "  WARN   could not write ~/.claude/settings.json — hooks NOT wired"; return 1; }
  adb_info "  hooks  wired global Stop gates + SessionStart currency check into ~/.claude/settings.json (backed up)"
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
  local f dir
  f="$(adb_global_manifest)"; dir="$(dirname "$f")"
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
install_rc=0
for a in "${AGENTS[@]}"; do
  case "$a" in
    claude) install_claude || install_rc=1 ;;
    codex|gemini) run_adapter "$a" || install_rc=1 ;;
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
# Fail loud: a missing manifest source tripped adb_link's guard somewhere above. The specific
# link error already went to stderr; exit non-zero so callers (bin/baseline self-heal, CI) see it.
if [ "$install_rc" -ne 0 ]; then
  echo "install.sh: one or more links FAILED (missing source?) — see the errors above." >&2
fi
exit "$install_rc"
