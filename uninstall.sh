#!/usr/bin/env bash
# ai-dev-baseline — global uninstaller.
#
# Removes only the symlinks that point back into THIS repo, and strips the global
# Stop-hook gates from ~/.claude/settings.json. Your backups under
# ~/.claude/backups/ai-dev-baseline-* are left untouched — restore from there if
# you want your pre-install files back.
#
# The MIRROR of install.sh's second model lives here too: `--pinned` removes a project's
# vendored payload instead of this clone's symlinks (#285). It removes only files whose contents
# still match the receipt that install wrote, so a vendored file you edited is kept and named.
#
# Usage:
#   ./uninstall.sh [--agent claude|codex|gemini]...   (default: all present)
#   ./uninstall.sh --pinned [--project DIR]

set -uo pipefail
_adb_boot_src="${BASH_SOURCE[0]}"; _adb_boot_rel="."
# ADB-BOOTSTRAP-BEGIN (#343) — BYTE-IDENTICAL IN EVERY ENTRY POINT; pinned by scripts/check-bootstrap.sh,
# which carries why each line is shaped this way. Lossless because `$(…)` strips every trailing newline:
# `${src%/*}` cannot strip, and the `X` sentinel bounds what the `pwd` capture can. Logical `pwd` (not
# `-P`) preserves how install.sh records its symlink targets. bash 3.2-safe: this runs before the gate.
_adb_boot_dir="${_adb_boot_src%/*}"
if [ "$_adb_boot_dir" = "$_adb_boot_src" ]; then _adb_boot_dir="."; elif [ -z "$_adb_boot_dir" ]; then _adb_boot_dir="/"; fi
_adb_boot_abs="$(cd -- "$_adb_boot_dir/$_adb_boot_rel" && pwd && printf 'X')"
_adb_boot_abs="${_adb_boot_abs%X}"; _adb_boot_abs="${_adb_boot_abs%$'\n'}"
[ -n "$_adb_boot_abs" ] || { printf '%s: FATAL - cannot resolve this clone location.\n' "${0##*/}" >&2; exit 1; }
# ADB-BOOTSTRAP-END
REPO="$_adb_boot_abs"
# Shared shell primitives (adb_info / adb_unlink_if_ours) — the ONE home, sourced not copied.
# shellcheck source=/dev/null
. "$REPO/scripts/lib/common.sh"
# bash 5.3 runtime floor (#256) — re-exec into a >= 5.3 interpreter, or exit with instructions.
adb_require_bash "$@"
# Same dispatch shape as install.sh, and for the same reason: the two models share no
# destination, so a run is one or the other.
for _adb_arg in "$@"; do
  if [ "$_adb_arg" = "--pinned" ]; then
    _adb_pinned_args=()
    for _adb_a in "$@"; do
      [ "$_adb_a" = "--pinned" ] && continue
      _adb_pinned_args+=("$_adb_a")
    done
    exec bash "$REPO/scripts/lib/pinned-install.sh" uninstall "${_adb_pinned_args[@]}"
  fi
done

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
  local rc=0 manifest
  adb_info "claude"
  # Remove exactly what install.sh linked, straight from the shared manifest (#48) via the shared
  # remove-side consumer — so uninstall can't drift from install (one producer, one column parse).
  #
  # CAPTURED AND CHECKED, exactly as install.sh does it (#324, D64) — the heredoc substitution this
  # replaces discarded the producer's status.
  #
  # A REFUSAL HERE MEANS AN INSTALL THIS TOOL CANNOT CLEAN UP, AND IT SAYS SO. If $REPO or $HOME
  # carries a delimiter, an install made before that was refused linked destinations at TRUNCATED
  # paths — not the ones this manifest would name — so there is no correct set to remove and the
  # honest answer is to remove nothing and hand the operator the two facts they need: the path that
  # cannot be represented (already on stderr from the producer) and where their originals went.
  # Emitting the records anyway would delete paths derived from a map just declared meaningless.
  manifest="$(adb_agent_manifest claude "$REPO" "$HOME")" || {
    adb_info "  ERROR  cannot enumerate what to remove — NOTHING was unlinked"
    adb_info "         Remove the ~/.claude symlinks that point into this clone by hand;"
    adb_info "         originals from the original install are under ~/.claude/backups/ai-dev-baseline-*"
    return 1
  }
  adb_unlink_manifest "$REPO" <<EOF || rc=1
$manifest
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
        adb_info "  hooks  removed global Stop gates + SessionStart currency and run-state hooks from ~/.claude/settings.json"
        rm -f "$(adb_claude_hooks_receipt "$HOME")"
      else
        rm -f "$settings.adb.$$.tmp"
        adb_info "  WARN   could not rewrite ~/.claude/settings.json — hook entries NOT removed; edit it by hand"
      fi
    fi
  else
    adb_info "  WARN   jq not found — hook entries left in ~/.claude/settings.json; remove them by hand"
  fi

  unwire_settings || rc=1
  return "$rc"
}

# The mirror of install.sh's wire_settings (#248, D95): remove the sandbox leaves this install
# OWNS, and only those. Ownership comes from the receipt, never from the shipped payload —
# `adb_claude_settings_merge --remove` deletes a leaf only while its live value still equals what
# the receipt says we wrote, KEEPS and NAMES one the operator has edited since, and prunes the
# containers it emptied without touching an empty object anybody else left in the file.
#
# NO RECEIPT MEANS NO REMOVAL, deliberately. An install that predates this surface, one that
# skipped below the floor, and one whose keys the operator has already deleted all look the same
# from settings.json alone, and guessing would delete `sandbox` keys we never wrote.
unwire_settings() {
  local settings="$HOME/.claude/settings.json" receipt payload result names tmp
  receipt="$(adb_claude_settings_receipt "$HOME")"
  payload="$(adb_claude_settings_payload "$REPO")"
  [ -f "$receipt" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — sandbox settings left in ~/.claude/settings.json; $receipt lists them"
    return 0
  fi
  # NO SETTINGS FILE MEANS NOTHING TO REMOVE — the receipt goes with it, because the keys it
  # describes cannot exist. A MISSING PAYLOAD IS NOT THAT CASE: ownership lives in the receipt, and
  # the merge's `--remove` mode does not need the fragment at all, so deleting the receipt here
  # would destroy the only record of which keys are ours while leaving every one of them installed
  # — an uninstall that reports success and silently strands the sandbox settings for good.
  # (PR review)
  if [ ! -s "$settings" ]; then
    rm -f "$receipt"
    return 0
  fi
  result="$(adb_claude_settings_merge "$settings" "$payload" "$receipt" --remove)" || {
    adb_info "  WARN   ~/.claude/settings.json is not valid JSON — sandbox settings NOT removed; edit it by hand"
    return 1; }
  tmp="$settings.adb.$$.tmp"
  # Same shared publish as the installer: refuse a destination that is not a regular file, and
  # carry the original's mode across rather than stamping the umask default onto it.
  if printf '%s' "$result" | jq '.settings' > "$tmp" && adb_publish_json "$tmp" "$settings"; then
    names="$(printf '%s' "$result" | jq -r '.pruned | map(join(".")) | join(", ")' 2>/dev/null)"
    [ -n "$names" ] && adb_info "  sandbox  removed from ~/.claude/settings.json: $names"
    names="$(printf '%s' "$result" | jq -r '.kept | map(join(".")) | join(", ")' 2>/dev/null)"
    [ -n "$names" ] && adb_info "  sandbox  KEPT (you edited these since we wrote them; remove by hand if you want them gone): $names"
    rm -f "$receipt"
    return 0
  fi
  rm -f "$tmp"
  adb_info "  WARN   could not rewrite ~/.claude/settings.json — sandbox settings NOT removed; edit it by hand"
  return 1
}

# THE LOOP ACCUMULATES, AND THE SCRIPT EXITS ON IT (#324, D64). It used to call each remover and
# discard the result, then print "Uninstalled" unconditionally — so a refusal to enumerate, or an
# adapter that failed outright, ended in a success message and exit 0. An uninstaller that says it
# removed things it did not is worse than one that fails: the operator stops looking.
uninstall_rc=0
for a in "${AGENTS[@]}"; do
  case "$a" in
    claude) uninstall_claude || uninstall_rc=1 ;;
    codex|gemini)
      adapter="$REPO/agents/$a/adapter.sh"
      [ -f "$adapter" ] && { adb_info "$a"; bash "$adapter" uninstall "$REPO" || uninstall_rc=1; } ;;
  esac
  # A RETIRED destination is no longer in the manifest, so adb_unlink_manifest above cannot see
  # it — and an uninstall that leaves one of our own dangling symlinks behind has not uninstalled
  # (#378). Same register and same ownership scoping as install.sh's pass.
  adb_prune_retired "$a" "$REPO" "$HOME" || uninstall_rc=1
done
adb_info ""
if [ "$uninstall_rc" -ne 0 ]; then
  adb_info "Uninstall INCOMPLETE — see the errors above. Backups remain in ~/.claude/backups/ai-dev-baseline-*"
else
  adb_info "Uninstalled. Backups remain in ~/.claude/backups/ai-dev-baseline-*"
fi
exit "$uninstall_rc"
