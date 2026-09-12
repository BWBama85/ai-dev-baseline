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
  # ONE RELEASE, ON EVERY EXIT — INCLUDING A SIGNAL. The body returns from several places (a
  # manifest that cannot be enumerated among them), and `adb_settings_lock_take` arms the traps so
  # a Ctrl-C mid-run cannot leave the lock behind either: one left behind refuses every later
  # install and uninstall for the stale interval, or longer if the recorded pid is reused.
  # NOTHING TO REMOVE IS NOT A FAILURE, and it is asked BEFORE the lock. The lock directory is
  # nested inside ~/.claude, so on a home that never had it — a clean machine, or someone who
  # installed only Codex or Gemini — `adb_update_lock` cannot create it and fails exactly as a
  # contended lock does. That reported "an install is writing" and ended the run with
  # "Uninstall INCOMPLETE" over a home with no Claude state at all. Creating the directory to lock
  # it would be worse: an uninstall must not materialise the tree it exists to remove. (PR review)
  if [ ! -d "$HOME/.claude" ]; then
    adb_info "claude"
    adb_info "  nothing to remove — ~/.claude does not exist"
    return 0
  fi
  if ! adb_settings_lock_take; then
    adb_info "claude"
    adb_info "  WARN   an install is writing ~/.claude — nothing was removed."
    adb_info "         If nothing else is running, remove: $(adb_settings_lock_path "$HOME")"
    return 1
  fi
  _uninstall_claude_locked; local ucrc=$?
  adb_settings_lock_drop || ucrc=1
  return "$ucrc"
}

_uninstall_claude_locked() {
  local rc=0 manifest ours_settings=0
  adb_info "claude"
  # WHOSE INSTALL IS THIS? Asked HERE, before `adb_unlink_manifest` removes the root-doc link the
  # answer depends on — a check inside `unwire_settings` would run after that removal and could
  # never pass. Two clones can each install globally: the second overwrites the first's links and
  # its receipt, and running the FIRST clone's uninstaller must then leave the second's settings
  # alone. The link half of that is already true (`adb_unlink_if_ours` refuses a link into another
  # clone); the settings half read the receipt as proof of ownership and removed keys this clone
  # no longer owns. Same predicate `bin/baseline` uses to decide a root doc "is not ours to
  # re-wire". (PR review)
  adb_link_into "$HOME/.claude/CLAUDE.md" "$REPO" && ours_settings=1
  # A LEGACY RECEIPT'S ONLY PROOF IS THE LINK, AND THE LINK IS ABOUT TO GO. `adb_unlink_manifest`
  # runs before `unwire_settings`, so a receipt with no `source` row whose cleanup then fails in a
  # retryable way (no jq, a momentarily invalid settings.json) is left with no durable provenance at
  # all — and the next run reads it as foreign and can never clean it up, even once the original
  # problem is fixed. Stamp what the link proves while it still proves it. Appended, because every
  # reader of this file greps for its own row prefix rather than a fixed layout.
  if [ "$ours_settings" -eq 1 ]; then
    local _lr _lrbody; _lr="$(adb_claude_settings_receipt "$HOME")"
    # AN UNREADABLE RECEIPT STOPS THE RUN BEFORE ANYTHING IS UNLINKED. We cannot tell whether it
    # carries a source row, so we cannot tell whether removing the link destroys its only proof —
    # and the link is removed a few lines below, before the settings cleanup that would report the
    # problem. Refusing here costs a retry; continuing costs the ability to ever clean up.
    if [ -f "$_lr" ] && ! cat "$_lr" >/dev/null 2>&1; then
      adb_info "  ERROR  $_lr exists but cannot be read, so this run cannot tell whether the root-doc"
      adb_info "         link is its only proof of ownership. NOTHING was unlinked — fix its"
      adb_info "         permissions and re-run, or removing the link would strand the settings."
      return 1
    fi
    # READ IT WHOLE FIRST, and write from that copy. A receipt this run cannot read reports NO
    # source row for the same reason it reports nothing else — so a stamp driven off that answer
    # ran `cat` on an unreadable file, got nothing, and published a receipt containing only the new
    # source row: every ownership row destroyed by the very step meant to preserve provenance.
    # An unreadable receipt is left exactly alone; `unwire_settings` refuses it and says so.
    # A ROW IS NOT A VALUE. `source<TAB>` with nothing after it satisfies a raw grep for the row and
    # is rejected by the reader, so the stamp was skipped and the receipt kept provenance nobody can
    # use — then the link went, and the next run read it as foreign. Ask the READER what it will
    # answer, and rebuild without any existing source rows so a malformed one cannot outrank the
    # good one appended after it. (PR review)
    # `-s`, NOT `-f`: A ZERO-BYTE RECEIPT IS ABSENT, NOT LEGACY. `adb_claude_settings_disposition`
    # already treats an empty file as absent — it owns no keys — but `-f` accepted it here and
    # stamped a source-only receipt over it. The file is then non-empty with no `disposition` line,
    # which the reader correctly rejects as DAMAGED, so sandbox cleanup failed on every retry over a
    # record that had owned nothing in the first place. (PR review)
    #
    # ...and the source read is asked for its STATUS, because 1 and 20 are different answers: no
    # source row is the legacy receipt this branch is for, while a read that could not be performed
    # is not evidence of anything. `|| true` made them the same.
    local _srcrc=99
    if [ -s "$_lr" ] && _lrbody="$(cat "$_lr" 2>/dev/null)"; then
      adb_claude_settings_receipt_source "$_lr" >/dev/null 2>&1; _srcrc=$?
    fi
    if [ "$_srcrc" -eq 20 ]; then
      adb_info "  ERROR  $_lr could not be searched for its provenance, so this run cannot tell whether"
      adb_info "         the root-doc link is its only proof of ownership. NOTHING was unlinked —"
      adb_info "         re-run once it can be read, or removing the link would strand the settings."
      return 1   # stamp-source-unreadable
    fi
    if [ "$_srcrc" -eq 1 ]; then
      # THE FILTER IS RUN AND CHECKED SEPARATELY. Inside a brace group its status is discarded —
      # the group reports whatever the LAST command did — so a `grep` that failed operationally
      # published a receipt carrying only the new source row, with every leaf row destroyed, and
      # the root doc was unlinked immediately after. No retry could then remove the settings.
      # `grep -v` exits 1 when it filters everything out, which for a receipt of only source rows
      # is a legitimate empty result, so 1 is accepted and 2-and-above is not. (PR review)
      local _lrkept _grc
      _lrkept="$(printf '%s\n' "$_lrbody" | grep -v "^source$(printf '\t')")"; _grc=$?
      if [ "$_grc" -gt 1 ]; then
        adb_info "  WARN   could not filter the legacy ownership record, so its provenance was NOT"
        adb_info "         recorded and the record was left exactly as it is."
        return 1   # stamp-filter-failed
      fi
      if { printf '%s\n' "$_lrkept"
           adb_claude_settings_source_row "$REPO"; } > "$_lr.adb.$$.prov" \
         && adb_publish_json "$_lr.adb.$$.prov" "$_lr"; then
        adb_info "  sandbox  recorded this clone as the source of a legacy ownership record, so a failed"
        adb_info "           cleanup can still be retried after the root-doc link is gone"
      else
        rm -f "$_lr.adb.$$.prov"
        # AND A FAILED STAMP STOPS THE RUN TOO. Warning and carrying on into `adb_unlink_manifest`
        # removed the only proof this receipt has and then relied on the settings cleanup to
        # succeed — which is exactly the retryable failure the stamp exists to survive.
        adb_info "  ERROR  could not record provenance on this legacy ownership record, and the"
        adb_info "         root-doc link is its only proof. NOTHING was unlinked — fix whatever"
        adb_info "         prevented the write and re-run."
        return 1   # stamp-failed
      fi
    fi
  fi
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
          ' "$settings" > "$settings.adb.$$.tmp" && [ -s "$settings.adb.$$.tmp" ]; then
        # NOTHING OF OURS MEANS NOTHING IS WRITTEN — the same rule the settings half follows, and
        # the same measured consequence: republishing a document we did not change rewrote an
        # operator's settings.json symlink into a regular file and reformatted the contents. The
        # comparison is SEMANTIC, not byte-wise, because jq reformats whatever it reads, so a
        # byte compare would report a difference on every no-op.
        # AND THE COMPARISON'S OWN FAILURE IS NOT A DIFFERENCE. `jq -e` answers 1 for false and 5 for
        # an error, and an `elif` chain reads every non-zero as "the documents differ" — so a second
        # `jq` that failed while reopening the settings path published the staged document anyway.
        # With no managed hooks present that reformats a file we did not change and replaces an
        # operator's settings.json SYMLINK with a regular file, which is the damage the comparison
        # exists to avoid. The settings half was fixed for exactly this; the hook half was not.
        # (PR review)
        local _hkrc
        jq -e --slurpfile orig "$settings" '. == $orig[0]' "$settings.adb.$$.tmp" >/dev/null 2>&1
        _hkrc=$?
        if [ "$_hkrc" -eq 0 ]; then
          rm -f "$settings.adb.$$.tmp"
          rm -f "$(adb_claude_hooks_receipt "$HOME")"
        elif [ "$_hkrc" -gt 1 ]; then
          rm -f "$settings.adb.$$.tmp"
          adb_info "  WARN   could not compare the hook removal with ~/.claude/settings.json — the hook"
          adb_info "         entries were NOT removed. Nothing was written; re-run once it is readable."
          rc=1
        # ...and published through the SHARED primitive, for the reasons install.sh's writer gives:
        # a bare `mv` neither refuses a destination that is not a regular file nor carries the
        # original's mode across, so it stamps the umask default onto a file the operator may have
        # deliberately restricted.
        elif adb_publish_json "$settings.adb.$$.tmp" "$settings"; then
          adb_info "  hooks  removed global Stop gates + SessionStart currency and run-state hooks from ~/.claude/settings.json"
          rm -f "$(adb_claude_hooks_receipt "$HOME")"
        else
          rm -f "$settings.adb.$$.tmp"
          adb_info "  WARN   could not rewrite ~/.claude/settings.json — hook entries NOT removed; edit it by hand"
          # AND THE RUN IS INCOMPLETE. The manifest links are already gone, so leaving `rc` alone let
          # a successful sandbox cleanup carry the whole uninstall to exit 0 and print `Uninstalled`
          # while settings.json still holds hook commands pointing at scripts that no longer exist —
          # Claude then runs them on every turn. (PR review)
          rc=1   # hook-publish-failed
        fi
      else
        rm -f "$settings.adb.$$.tmp"
        adb_info "  WARN   could not rewrite ~/.claude/settings.json — hook entries NOT removed; edit it by hand"
        rc=1   # hook-filter-failed
      fi
    fi
  else
    adb_info "  WARN   jq not found — hook entries left in ~/.claude/settings.json; remove them by hand"
  fi

  unwire_settings "$ours_settings" || rc=1
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
  local ours="${1:-0}"
  local settings="$HOME/.claude/settings.json" receipt payload result names tmp
  receipt="$(adb_claude_settings_receipt "$HOME")"
  payload="$(adb_claude_settings_payload "$REPO")"
  [ -f "$receipt" ] || return 0
  # NOT OURS, NOT OURS TO REMOVE. The receipt is global, so its mere existence proves only that
  # SOME clone installed these keys — and a second clone's install replaced both the links and the
  # receipt. Leaving them is the same answer `adb_unlink_if_ours` gives for a link pointing
  # elsewhere, and it is said rather than done in silence.
  # WHOSE RECEIPT IS THIS? The recorded source answers it whenever there IS one; the link is the
  # fallback for a legacy receipt that carries none.
  #
  # Asking the link FIRST was wrong in the failed-takeover state, and that state is reachable: clone
  # B replaces the root-doc link and then fails before refreshing the receipt — the no-jq provenance
  # path does exactly this. The link then says "ours", the source row still says A, and B's
  # uninstall consumed and deleted settings whose record explicitly named somebody else. A present
  # source row is evidence about the receipt itself; the link is evidence about the tree around it,
  # and only one of those is what a receipt means. (PR review)
  # AN UNREADABLE RECEIPT IS NOT ONE WITHOUT A SOURCE. `|| true` turned a failed read into an empty
  # source, and with the root-doc link already gone that reads as "legacy, and not ours" — so this
  # returned 0, the outer script printed `Uninstalled`, and every owned sandbox setting stayed
  # active with nobody told. The file existing and refusing to open is a reason to stop. (PR review)
  # THE STATUS, NOT JUST THE VALUE, AND ONE CHECK RATHER THAN TWO. `|| true` turned an operational
  # failure into "no source row", which is the legacy-receipt answer — and in the failed-takeover
  # state, where this clone's root link is paired with ANOTHER clone's record, that fallback
  # consumes the other clone's receipt and the sandbox settings it owns. 1 is a real absence; 20 is
  # a reason to stop.
  #
  # A separate `cat` readability probe used to sit in front of this. Once the reader distinguishes
  # 20, it is redundant — an unreadable file fails the search too — and a second mechanism guarding
  # one defect means no single edit can reintroduce it, so neither can be observed failing. Its
  # wording was the better of the two and is kept here. (PR review)
  local recorded _rsrc
  recorded="$(adb_claude_settings_receipt_source "$receipt" 2>/dev/null)"; _rsrc=$?
  if [ "$_rsrc" -eq 20 ]; then
    adb_info "  ERROR  $receipt exists but cannot be read, so this run cannot tell whose settings"
    adb_info "         these are. NOTHING was removed — restore access to it and re-run."
    return 1   # cleanup-source-unreadable
  fi
  if [ -n "$recorded" ]; then
    if [ "$recorded" != "$REPO" ]; then
      adb_info "  sandbox  left alone — this ownership record names another clone as its source, so"
      adb_info "           its settings are not ours to remove. Uninstall from: $recorded"
      return 0
    fi
    [ "$ours" = "1" ] || adb_info "  sandbox  the root-doc link is gone, but this receipt records this clone as its source — proceeding"
  elif [ "$ours" != "1" ]; then
    # NO SOURCE ROW AT ALL — a receipt written before provenance was recorded. The link is the only
    # evidence there is, and it says this is not ours.
    adb_info "  sandbox  left alone — ~/.claude is installed from another clone, so its settings are not ours to remove"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — sandbox settings left in ~/.claude/settings.json; $receipt lists them."
    adb_info "         Install jq and re-run: the receipt records this clone as its source, so the"
    adb_info "         retry can still prove they are ours even though the root-doc link is gone."
    return 1
  fi
  # NO SETTINGS FILE MEANS NOTHING TO REMOVE — the receipt goes with it, because the keys it
  # describes cannot exist. A MISSING PAYLOAD IS NOT THAT CASE: ownership lives in the receipt, and
  # the merge's `--remove` mode does not need the fragment at all, so deleting the receipt here
  # would destroy the only record of which keys are ours while leaving every one of them installed
  # — an uninstall that reports success and silently strands the sandbox settings for good.
  # (PR review)
  if [ ! -s "$settings" ]; then
    rm -f "$receipt" || {
      adb_info "  WARN   could not remove $receipt — remove it by hand."
      adb_info "         Until you do, a re-install reads its leaves as YOUR removals and will not restore them."
      return 1; }
    return 0
  fi
  local mrc _nochange
  # AN INCOMPLETE `installed` RECORD IS NOT SAFE TO REMOVE BY. Removing only the rows it lists
  # deletes the receipt and leaves the rest installed with no owner. Asked here rather than inside
  # the merge because the merge must keep ignoring the payload on this path, and ONLY 23 refuses: a
  # fragment that is missing or malformed answers "cannot tell", which must not block a removal.
  # (PR review)
  local _crc=0
  _adb_claude_settings_rows_complete "$receipt" "$payload" || _crc=$?
  if [ "$_crc" -eq 23 ]; then
    adb_info "  WARN   $receipt does not record every sandbox key the fragment ships, so removing by"
    adb_info "         it would delete the record and leave the rest installed with no owner."
    adb_info "         NOTHING was removed. Remove the 'sandbox' block and that record by hand."
    return 1   # remove-rows-incomplete
  fi
  result="$(adb_claude_settings_merge "$settings" "$payload" "$receipt" --remove)"; mrc=$?
  if [ "$mrc" -eq 20 ]; then
    adb_info "  WARN   $receipt exists but could not be READ — sandbox settings NOT removed and the"
    adb_info "         ownership record was KEPT. It is the only thing that can prove which keys are"
    adb_info "         ours; fix its permissions and re-run, or the settings are stranded for good."
    return 1
  elif [ "$mrc" -eq 21 ]; then
    # DAMAGED, NOT UNREADABLE, and the remedy is different: no permission change will help. The
    # rows are still there and still name our keys, so the record is kept and the operator is told
    # what to repair rather than being sent to chmod something that is already readable.
    adb_info "  WARN   $receipt is readable but its \`disposition\` line is missing or unrecognised, so"
    adb_info "         it cannot be classified — sandbox settings NOT removed and the record was KEPT."
    adb_info "         Its \`leaf\` rows still name the keys we own; repair that line and re-run."
    return 1
  elif [ "$mrc" -ne 0 ]; then
    adb_info "  WARN   ~/.claude/settings.json could not be read as a single JSON value — sandbox settings NOT removed; edit it by hand"
    return 1
  fi
  tmp="$settings.adb.$$.tmp"
  # RESTRICTED BEFORE IT IS POPULATED, exactly as the installer's writer does it. This temp holds
  # the WHOLE settings document — every unrelated key, an `env` block among them — and creating it
  # under the caller's umask leaves a predictable, PID-named, world-readable file for as long as
  # the write takes. `adb_publish_json` carries the destination's mode across only at publish time,
  # which is the end of that window rather than the start of it.
  rm -f "$tmp"
  ( umask 077; : > "$tmp" ) || {
    adb_info "  WARN   could not create the settings temp file — sandbox settings NOT removed"; return 1; }
  # TWO DURABLE CHANGES, ONE TRANSACTION — the mirror of the installer's. The settings lose the
  # keys, then the receipt stops claiming them, and a signal in between leaves a receipt naming
  # leaves that are already gone: if the operator recreates matching values before retrying, the
  # retry reads them as installer-owned and deletes them. The install side deferred and this side
  # never did. (PR review)
  #
  # Same shared publish as the installer: refuse a destination that is not a regular file, and
  # carry the original's mode across rather than stamping the umask default onto it.
  # REMOVABILITY IS PROVED BEFORE THE SETTINGS ARE REWRITTEN, not discovered afterwards. Deferring
  # signals closed the interruption window; it did nothing for an ordinary I/O failure between the
  # same two durable changes. Measured: with the receipt made immutable, uninstall removed every
  # owned leaf and then could not delete the record — leaving it claiming four values that were
  # gone, so an operator who recreated them had them deleted as ours on the retry.
  #
  # A rename is the proof: whatever blocks the unlink (an immutable flag, a delete ACL, a
  # read-only parent) blocks this too, and it is restored immediately so the state is unchanged on
  # the way to the publish. That leaves a window rather than a transaction, but the window is now
  # microseconds of rename rather than the whole settings rewrite. (PR review)
  # NOTHING OF OURS IN THE FILE MEANS THE FILE IS NOT TOUCHED. A rowless receipt — a first blocked
  # refusal, a below-floor skip — or one whose every owned leaf the operator has since edited or
  # deleted prunes nothing, and republishing the document anyway rewrote it for no reason: measured,
  # it turned an operator's settings.json SYMLINK into a regular file and reformatted the contents.
  # There is nothing of ours to remove, so the record goes and the file is left byte-for-byte.
  # ASKED OF THE MERGED DOCUMENT, not of `.pruned`. That array counts LEAVES, and the removal also
  # deletes the containers this install created — so an operator who had deleted every recorded leaf
  # but left our empty `sandbox` object behind pruned nothing, and the file was skipped with that
  # object orphaned in it permanently. Comparing the result to the live document answers the
  # question actually being asked: is there anything of ours left to take out?
  # `jq -e` ANSWERS 1 FOR FALSE AND 5 FOR AN ERROR. Treating both as "the document changed" meant a
  # transient failure republished a document that was actually unchanged — which for a settings.json
  # SYMLINK replaces the link with a regular file and reformats the operator's document, the exact
  # damage the no-op branch exists to avoid. An unanswerable comparison stops the run. (PR review)
  printf '%s' "$result" | jq -e --slurpfile orig "$settings" '.settings == $orig[0]' >/dev/null 2>&1
  _nochange=$?
  if [ "$_nochange" -gt 1 ]; then
    rm -f "$tmp"
    adb_info "  WARN   could not compare the removal result with ~/.claude/settings.json — sandbox"
    adb_info "         settings NOT removed. Nothing was written; re-run once the file is readable."
    # NO RESUME HERE: this branch is reached BEFORE `adb_settings_lock_defer_signals` below, so
    # there is nothing deferred to resume. The helper is now total, so this would no longer kill the
    # shell — but calling it is still meaningless, and the ordering is the thing being fixed.
    # (PR review)
    return 1
  fi
  if [ "$_nochange" -eq 0 ]; then
    # NOTHING WAS PRUNED, SO `.kept` IS THE WHOLE ANSWER — every recorded leaf was edited and all of
    # them stay active. An empty `names` from a failed read is indistinguishable from "nothing was
    # kept", and this branch deletes the receipt three lines down: the values would remain in the
    # operator's file with no ownership record and no diagnostic naming them. (PR review)
    if ! names="$(printf '%s' "$result" | jq -r '.kept | map(join(".")) | join(", ")' 2>/dev/null)"; then
      rm -f "$tmp"
      adb_info "  WARN   nothing of ours could be removed, and the list of values you edited could not"
      adb_info "         be read back — the ownership record was KEPT so they can still be identified."
      return 1   # noop-kept-unreadable
    fi
    [ -n "$names" ] && adb_info "  sandbox  KEPT (you edited these since we wrote them; remove by hand if you want them gone): $names"
    adb_info "  sandbox  nothing of ours is in ~/.claude/settings.json — the file was left untouched"
    # THE STAGED FILE GOES WITH THE NO-OP. It is created before this comparison, so every
    # install/uninstall cycle that removed nothing left a zero-byte `settings.json.adb.<pid>.tmp`
    # sitting in ~/.claude. (PR review)
    rm -f "$tmp"   # no-op-stage
    rm -f "$receipt" || {
      adb_info "  WARN   the ownership record $receipt could not be deleted — remove it by hand."
      return 1; }
    return 0
  fi

  # THE PROBE IS ITSELF TWO RENAMES, so the deferral opens BEFORE it rather than after. A signal
  # between the move-aside and the restore left the receipt stranded at the `.probe` path: the next
  # install would see no ownership record, read the still-installed values as the operator's, and
  # publish an ownership-free refusal over the evidence. Guarding the write it protects while
  # leaving its own two renames exposed was the same window one step earlier. (PR review)
  adb_settings_lock_defer_signals   # transaction: settings rewrite + receipt removal
  local _rprobe="$receipt.adb.$$.probe"
  if ! mv "$receipt" "$_rprobe" 2>/dev/null; then
    adb_info "  WARN   $receipt cannot be removed, so the sandbox settings were NOT touched."
    adb_info "         Removing them first would leave this record claiming values that are gone,"
    adb_info "         and a retry would then delete anything you recreated under those keys."
    adb_settings_lock_resume_signals
    return 1
  fi
  if ! mv "$_rprobe" "$receipt" 2>/dev/null; then
    adb_info "  ERROR  $receipt was moved aside to test removability and could not be put back."
    adb_info "         It is at $_rprobe — restore it by hand before re-running; nothing else changed."
    adb_settings_lock_resume_signals
    return 1
  fi
  if printf '%s' "$result" | jq '.settings' > "$tmp" && adb_publish_json "$tmp" "$settings"; then
    # THE SAME TWO READS, ON THE PATH WHERE THE SETTINGS ARE ALREADY PUBLISHED. Aborting cannot
    # un-publish them, so the remedy differs: what must survive is the RECEIPT, because a `.kept`
    # that could not be named leaves those values active with nothing recording that they were
    # ours. `.pruned` is diagnostic — those keys are gone either way — so a failure there is
    # reported and the uninstall completes. Neither was reported; both are the reported class.
    if ! names="$(printf '%s' "$result" | jq -r '.pruned | map(join(".")) | join(", ")' 2>/dev/null)"; then
      adb_info "  WARN   the removed keys could not be listed back, but they ARE removed."
    else
      [ -n "$names" ] && adb_info "  sandbox  removed from ~/.claude/settings.json: $names"
    fi
    if ! names="$(printf '%s' "$result" | jq -r '.kept | map(join(".")) | join(", ")' 2>/dev/null)"; then
      adb_info "  WARN   the sandbox settings were removed, but the values you edited could not be"
      adb_info "         listed back — the ownership record was KEPT so they can still be identified."
      adb_info "         Remove $receipt by hand once you have: until you do, a re-install reads its"
      adb_info "         leaves as YOUR removals and will not restore the protection."
      adb_settings_lock_resume_signals
      return 1   # published-kept-unreadable
    fi
    [ -n "$names" ] && adb_info "  sandbox  KEPT (you edited these since we wrote them; remove by hand if you want them gone): $names"
    # THE RECEIPT'S REMOVAL IS CHECKED. A stale ownership record survives an otherwise clean
    # uninstall, and the next install reads its leaves as recorded removals — the documented
    # by-hand opt-out — and deliberately refuses to restore them. Sandbox protection then stays
    # off until somebody finds and deletes a file they were never told about.
    rm -f "$receipt" || {
      adb_info "  WARN   the sandbox settings were removed, but $receipt could not be deleted."
      adb_info "         Remove it by hand: until you do, a re-install reads its leaves as YOUR"
      adb_info "         removals and will not restore the protection."
      adb_settings_lock_resume_signals
      return 1; }
    adb_settings_lock_resume_signals
    return 0
  fi
  rm -f "$tmp"
  adb_info "  WARN   could not rewrite ~/.claude/settings.json — sandbox settings NOT removed; edit it by hand"
  adb_settings_lock_resume_signals
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
