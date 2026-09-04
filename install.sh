#!/usr/bin/env bash
# ai-dev-baseline — global installer.
#
# Symlinks this repo's agent payloads into each selected agent's user-level config
# so your baseline practices, skills, and gates apply in EVERY project. Symlinks
# mean `git pull` in this repo updates every project at once. Existing files are
# backed up first; re-running is idempotent; `uninstall.sh` reverses it.
#
# There is a SECOND install model, and this script is the entry point for both. `--pinned`
# vendors ONE released version into ONE project tree instead of symlinking this clone into
# ~/.<agent>; see docs/installation.md and scripts/lib/pinned-install.sh (#285). Everything
# below the `--pinned` dispatch is the global model, unchanged.
#
# Usage:
#   ./install.sh                       # installs the 'claude' agent + wires gates
#   ./install.sh --agent claude --agent codex
#   ./install.sh --agent claude --no-hooks
#   ./install.sh --agent claude --no-sandbox
#   ./install.sh --pinned --project DIR --version X.Y.Z [--agent claude|codex]...
#   ./install.sh --pinned --project DIR --artifact FILE --sums FILE
#
# Options:
#   --agent <claude|codex|gemini>   repeatable; default: claude
#   --no-hooks                      don't wire the global Stop-hook gates
#   --no-sandbox                    don't write the least-privilege sandbox settings (#248)
#   --pinned                        release-pinned per-project install; every remaining argument
#                                   is passed to scripts/lib/pinned-install.sh install
#   -h, --help

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

# CRLF BOOTSTRAP CHECK — before the source, because the source is what it protects (#2).
#
# The full scanner lives in common.sh (adb_crlf_scan) and runs below. It cannot cover THIS step:
# a CRLF-corrupted `common.sh` breaks the `.` on the next line, so the diagnostic would arrive as
# a pile of `$'\r': command not found` from inside a library the user has never heard of. Review
# reproduced exactly that — a checkout with only `common.sh` converted returned shell noise, and a
# direct scan afterwards reported clean because the shebang-only filter skipped the file.
#
# Deliberately NOT `adb_link`-style shared code: it must run before any shared code exists. Nine
# lines with a stated reason, checking one file, is the smallest thing that can close a bootstrap
# gap — and the full scanner still checks this file among all the others a moment later.
if [ -r "$REPO/scripts/lib/common.sh" ] && LC_ALL=C grep -q "$(printf '\r')\$" "$REPO/scripts/lib/common.sh" 2>/dev/null; then
  echo "install.sh: FATAL — scripts/lib/common.sh has CRLF line endings, so nothing here can load." >&2
  echo "  Under WSL this surfaces as: bash: \$'\\r': command not found" >&2
  echo "  Re-clone INSIDE the WSL filesystem (not under /mnt/c):" >&2
  echo "      git clone <url> ~/Code/ai-dev-baseline" >&2
  exit 1
fi

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

# THE PINNED MODEL DISPATCHES HERE, before the global argument loop, and `exec`s rather than
# returning: the two models share no state and no destination, so a run is one or the other. It
# sits after the CRLF bootstrap, the library source and the bash-floor gate above because it
# needs all three — and the pinned installer NEVER vendors this clone. It fetches and checksums a
# published release artifact even when invoked from a checkout, so what lands in a project is a
# named version rather than whatever this tree happens to say.
for _adb_arg in "$@"; do
  if [ "$_adb_arg" = "--pinned" ]; then
    _adb_pinned_args=()
    for _adb_a in "$@"; do
      [ "$_adb_a" = "--pinned" ] && continue
      _adb_pinned_args+=("$_adb_a")
    done
    exec bash "$REPO/scripts/lib/pinned-install.sh" install "${_adb_pinned_args[@]}"
  fi
done

# ADB_BACKUP_DIR: a caller that must find what this run displaced (bin/baseline, after it unlinks
# a hook this run added) names the directory instead of guessing a timestamp.
BACKUP_DIR="${ADB_BACKUP_DIR:-$HOME/.claude/backups/ai-dev-baseline-$(date +%Y%m%d-%H%M%S)}"
WIRE_HOOKS=1
WIRE_SETTINGS=1
AGENTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENTS+=("$2"); shift 2 ;;
    --no-hooks) WIRE_HOOKS=0; shift ;;
    --no-sandbox) WIRE_SETTINGS=0; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "${#AGENTS[@]}" -eq 0 ] && AGENTS=(claude)

# THE SECOND SETTINGS SURFACE (#248, D95-D98): the non-hook fragment. Deliberately a separate
# function from wire_hooks and not a generalization of it — the two own different THINGS. Hooks
# own whole groups under `.hooks`, keyed by our command path; this owns individual LEAF PATHS
# anywhere else in the file, so an adopter's `sandbox.excludedCommands` survives beside our
# `sandbox.enabled`. All the ownership arithmetic lives in adb_claude_settings_merge; this
# function is the I/O, the version probe and the reporting.
#
# Returns 0 installed OR deliberately skipped (each writes a receipt saying WHICH), 1 broken,
# 3 skipped for want of jq — the same three-status contract wire_hooks uses, and for the same
# reason: an unconditional success line was the recorded defect (#242).
wire_settings() {
  local settings="$HOME/.claude/settings.json"
  local receipt payload floor version tmp result
  payload="$(adb_claude_settings_payload "$REPO")"
  receipt="$(adb_claude_settings_receipt "$HOME")"
  floor="$(adb_claude_settings_floor)"

  # THE OPT-OUT IS RECORDED BEFORE THE jq GUARD, deliberately. Its receipt is plain text and needs
  # no jq, and a missing jq is a SUPPORTED degraded environment — so returning early here would
  # leave `--no-sandbox` unrecorded, and the first `baseline update` after jq arrived would read
  # disposition `none` and apply the fragment over a choice the operator made by contract.
  # `precondition-ordering`: the step that can satisfy the guard runs first. (PR review)
  #
  # It also carries the previous run's `leaf` rows forward. Dropping them would orphan any key an
  # earlier install wrote: uninstall could no longer prove which keys were ours, and D95's
  # retirement prune would have nothing to prune.
  if [ "$WIRE_SETTINGS" -eq 0 ]; then
    if ! printf '%s\n' "$(_adb_owned_rows "$receipt")" \
         | adb_claude_settings_receipt_render skipped-optout "-" "$floor" \
             "$(adb_claude_settings_payload_digest "$receipt" 2>/dev/null || printf '%s' '-')" > "$receipt.adb.$$.tmp" \
         || ! adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; then
      rm -f "$receipt.adb.$$.tmp"
      adb_info "  WARN   --no-sandbox honoured, but the receipt could not be written; the next update may re-offer the settings"
      return 0
    fi
    adb_info "  sandbox  --no-sandbox: no settings written (recorded, so \`baseline update\` keeps honouring it)"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    adb_info "  WARN   jq not found — cannot write the sandbox settings; install jq and re-run"
    return 3
  fi
  [ -s "$payload" ] || {
    adb_info "  WARN   could not read $payload — sandbox settings NOT written"; return 1; }

  # THE VERSION PROBE (D98). Three outcomes, three receipts — never one silent absence. Below the
  # floor, or unreadable, we write NOTHING: a key the running CLI ignores reports protection it
  # never applied, which is the failure decision 3 already ruled out.
  if ! version="$(adb_claude_cli_version)"; then
    _adb_record_skip skipped-unprobeable "-" "$floor" "$receipt"
    adb_info "  sandbox  SKIPPED — no \`claude\` binary could be version-probed, so nothing was written."
    adb_info "           The sandbox keys need v$floor+; an unread version is not evidence they would be honoured."
    adb_info "           Put \`claude\` on PATH and re-run ./install.sh to apply them."
    return 0
  fi
  if ! adb_version_ge "$version" "$floor"; then
    _adb_record_skip skipped-below-floor "$version" "$floor" "$receipt"
    adb_info "  sandbox  SKIPPED — claude v$version is below the v$floor floor for \`sandbox.credentials\`."
    adb_info "           NOT applied: sandbox isolation, the ~/.aws and ~/.ssh read denials, the"
    adb_info "           GITHUB_TOKEN scrub, and the network allowlist. Upgrade the CLI; the next"
    adb_info "           \`baseline update\` applies them by itself (a skip is never read as a choice)."
    return 0
  fi

  # An EMPTY settings.json is not valid JSON and `--slurpfile` would refuse it. Same brace, same
  # reason, as wire_hooks': jq reads empty input as an empty stream and would exit 0 with nothing.
  [ -s "$settings" ] || echo '{}' > "$settings"
  # ONE BACKUP PER RUN, AND ITS STATUS IS CHECKED. wire_hooks already copied the PRISTINE file;
  # copying again here would overwrite it with the hook-wired intermediate and lose the operator's
  # original. The success line below says "backed up", and an unwritable backup destination would
  # otherwise let this mutate the operator's settings while that promise was false. (PR review)
  if [ ! -e "$BACKUP_DIR$settings" ]; then
    if ! mkdir -p "$BACKUP_DIR$(dirname "$settings")" || ! cp "$settings" "$BACKUP_DIR$settings"; then
      adb_info "  WARN   could not back up $settings under $BACKUP_DIR — sandbox settings NOT written"
      return 1
    fi
  fi

  result="$(adb_claude_settings_merge "$settings" "$payload" "$receipt")" || {
    adb_info "  WARN   ~/.claude/settings.json is not valid JSON — sandbox settings NOT written (restore from the backup)"
    return 1; }
  # THE RECEIPT IS RENDERED BEFORE THE SETTINGS ARE PUBLISHED, and the old one is kept until both
  # are durable. Ownership is the load-bearing half: settings without a receipt are keys nobody
  # can prove are ours, and the NEXT install reads them as the operator's — writes an empty
  # ownership record — after which uninstall can never remove them. So a receipt this run cannot
  # render is a refusal, not a warning, and nothing is written at all. (PR review)
  # The publishability of the receipt PATH is checked before anything is written, not just its
  # rendering: `adb_publish_json` refuses a non-regular destination, but it does so at publish
  # time — which is after the settings would already be durable. `precondition-ordering`: the
  # guard has to run where the thing it guards has not happened yet.
  if [ -e "$receipt" ] && [ ! -f "$receipt" ]; then
    adb_info "  WARN   $receipt is not a regular file — sandbox settings NOT written"
    adb_info "         (keys with no receipt could never be removed by uninstall, so none were applied)"
    return 1
  fi
  local rtmp="$receipt.adb.$$.tmp"
  if ! adb_claude_settings_leaf_rows "$payload" \
         "$(printf '%s' "$result" | jq -c '.wrote + .removed')" \
       | adb_claude_settings_receipt_render installed "$version" "$floor" \
             "$(adb_sha256 "$payload" 2>/dev/null || printf '%s' '-')" > "$rtmp" \
     || [ ! -s "$rtmp" ]; then
    rm -f "$rtmp"
    adb_info "  WARN   could not render the ownership receipt $receipt — sandbox settings NOT written"
    adb_info "         (keys with no receipt could never be removed by uninstall, so none were applied)"
    return 1
  fi

  tmp="$settings.adb.$$.tmp"
  # RESTRICTED BEFORE IT IS POPULATED. The merged settings carry every unrelated key too — an
  # `env` block among them — and copying the destination's mode only at publish time leaves a
  # window in which a predictable, PID-named, umask-readable file holds all of it. On a host where
  # ~/.claude is traversable that window is readable by another user. (PR review)
  rm -f "$tmp"
  ( umask 077; : > "$tmp" ) || { adb_info "  WARN   could not create the settings temp file — NOT written"; return 1; }
  if ! printf '%s' "$result" | jq '.settings' > "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$rtmp"
    adb_info "  WARN   could not render the merged settings — NOT written (original left intact)"
    return 1
  fi
  # Published through the shared primitive: it refuses a destination that is not a regular file
  # (a directory would swallow the rename and report success) and carries the original's mode
  # across, so a mode-0600 settings.json is not relaxed to the umask default.
  # THE PRE-IMAGE IS KEPT so the settings write can be UNDONE. The receipt is checked and rendered
  # before anything is published, but publishing it can still fail after the settings rename has
  # succeeded — and settings without a receipt are the one unrecoverable state: the next install
  # reads those values as the operator's and records nothing, after which uninstall can never
  # remove them. So the failure path undoes what the success path did, in reverse.
  local pre="$settings.adb.$$.pre"
  rm -f "$pre"
  if ! { ( umask 077; : > "$pre" ) && cat "$settings" > "$pre"; }; then
    rm -f "$tmp" "$rtmp" "$pre"
    adb_info "  WARN   could not snapshot $settings before writing — sandbox settings NOT written"
    return 1
  fi
  adb_publish_json "$tmp" "$settings" || { rm -f "$rtmp" "$pre"; adb_info "  WARN   sandbox settings NOT written"; return 1; }
  if ! adb_publish_json "$rtmp" "$receipt"; then
    if adb_publish_json "$pre" "$settings"; then
      adb_info "  WARN   $receipt could not be published, so the sandbox settings were ROLLED BACK."
      adb_info "         Nothing was applied and nothing was orphaned — fix that path and re-run ./install.sh."
    else
      rm -f "$pre"
      adb_info "  ERROR  $receipt could not be published AND the settings could not be rolled back."
      adb_info "         The sandbox keys are applied with no ownership record: uninstall cannot"
      adb_info "         remove them. Remove the \`sandbox\` keys from $settings by hand, then re-run."
    fi
    return 1
  fi
  rm -f "$pre"

  # THE HEADLINE MUST NOT OVERSTATE. A merge that SKIPPED `sandbox.enabled` because the operator
  # already set it to false leaves every credential rule inert, and "least-privilege settings
  # applied" would be false in the one way that matters. (PR review)
  if [ "$(printf '%s' "$result" | jq -r '[.wrote[] | join(".")] | index("sandbox.enabled") != null')" = true ] \
     || [ "$(jq -r '.sandbox.enabled // false' "$settings" 2>/dev/null)" = true ]; then
    adb_info "  sandbox  least-privilege settings applied to ~/.claude/settings.json (claude v$version, floor v$floor, backed up)"
  else
    adb_info "  sandbox  settings written, but SANDBOXING IS NOT ON: \`sandbox.enabled\` is yours, not ours,"
    adb_info "           and is not true — the credential and network rules below are inert until it is."
  fi
  _adb_report_settings "$result" wrote   "wrote"
  _adb_report_settings "$result" skipped "left alone (your value, not ours)"
  _adb_report_settings "$result" removed "left removed (your opt-out — re-add by hand or re-run after deleting the receipt)"
  _adb_report_settings "$result" pruned  "pruned (no longer shipped)"
  _adb_report_settings "$result" kept    "kept (you edited it since we wrote it)"
  return 0
}

# Record a skip, and SAY SO WHEN IT CANNOT BE RECORDED. The receipt is the entire reason a skip is
# retried instead of frozen into a permanent absence (D98), so a write that fails here is not a
# cosmetic loss: nothing else tells the operator that the reason they were just given is not on
# disk.
# The `leaf` rows a receipt already carries, or nothing. One home, because BOTH non-writing paths
# (the opt-out and the version skips) must preserve ownership, and a second copy of this grep is a
# second chance to lose it.
_adb_owned_rows() { grep "^leaf$(printf '\t')" "$1" 2>/dev/null || true; }

_adb_record_skip() {
  local disposition="$1" version="$2" floor="$3" receipt="$4" carried digest
  # CARRY THE PRIOR OWNED ROWS FORWARD. A skip means "write no NEW keys" — it never means "forget
  # the ones already there". A CLI that becomes unprobeable, or is downgraded, would otherwise
  # replace an `installed` receipt with an empty one while the sandbox values stay in the file:
  # uninstall could then never remove them, and the next install would read them as the operator's
  # and record an empty ownership set permanently. (PR review)
  carried="$(_adb_owned_rows "$receipt")"
  # THE PRIOR DIGEST IS CARRIED TOO, for the same reason as the rows: a skip applied no payload, so
  # it must not claim to have applied THIS one — but neither may it erase the record of the payload
  # an earlier install really did apply, which is what `pending` compares against.
  digest="$(adb_claude_settings_payload_digest "$receipt" 2>/dev/null || printf '%s' '-')"
  [ -n "$digest" ] || digest="-"
  if printf '%s\n' "$carried" \
     | adb_claude_settings_receipt_render "$disposition" "$version" "$floor" "$digest" > "$receipt.adb.$$.tmp" \
     && adb_publish_json "$receipt.adb.$$.tmp" "$receipt"; then
    return 0
  fi
  rm -f "$receipt.adb.$$.tmp"
  adb_info "  WARN   could not write $receipt — the skip stands, but its REASON is not recorded"
  return 0
}

# One reporting line per non-empty bucket, naming the leaves. SAY WHAT IT DID, not merely that it
# succeeded: `skipped` and `wrote` produce identical exit codes and identical silence otherwise,
# and "which of my sandbox keys did this actually set" is the only question an operator has here.
_adb_report_settings() {
  local result="$1" bucket="$2" label="$3" names
  names="$(printf '%s' "$result" | jq -r --arg b "$bucket" '.[$b] | map(join(".")) | join(", ")' 2>/dev/null)"
  [ -n "$names" ] && [ "$names" != "null" ] || return 0
  adb_info "           $label: $names"
}

install_claude() {
  local rc=0 manifest
  adb_info "claude → ~/.claude"
  # The install surface (root doc, every skill, the runtime scripts, and the shared
  # scripts/lib) is enumerated ONCE by adb_agent_manifest — install.sh links it, uninstall.sh
  # removes it, and bin/baseline verifies it, so the three can't drift (#48). scripts/lib links
  # at its canonical path; a plain `git pull` keeps pre-#34 installs working via the compat
  # shim, and this re-run self-heals them to the direct link (do NOT delete that shim).
  #
  # THE MANIFEST IS CAPTURED FIRST, AND ITS STATUS IS OBSERVED (#324, D64). This used to be
  # `adb_link_manifest … <<EOF` / `$(adb_agent_manifest …)` / `EOF`, and a command substitution
  # inside a heredoc DISCARDS the producer's status: the refusal the producer now returns for an
  # unrepresentable $REPO/$HOME would have arrived as an empty manifest and a cheerful exit 0.
  # Two statements, never one — `local manifest="$(…)"` would report `local`'s status, not the
  # producer's, which is the same trap one level down.
  manifest="$(adb_agent_manifest claude "$REPO" "$HOME")" || {
    adb_info "  ERROR  cannot enumerate the install surface — nothing was linked (see above)"
    return 1
  }
  # Capture the accumulated status so a missing source (adb_link's guard) makes the installer
  # exit non-zero rather than silently leaving a dangling link.
  # A hook link this run is about to CREATE, whose settings entry then never gets written, is an
  # interrupted install — and nothing downstream can tell that shape (our link, no entry) from a
  # per-hook opt-out, which is the documented removal and is preserved by every later self-heal
  # (adb_claude_hooks_missing_deliberate). So the links this run adds are noted before linking
  # and taken back if wiring fails; a link that already existed is an earlier run's state and is
  # left alone. (PR #443 review)
  # ...taken back to what stood there: adb_link moves a real file into $BACKUP_DIR and REPLACES a
  # foreign symlink outright, so each fresh destination's prior shape is noted here (its symlink
  # target, or nothing) and put back on rollback — a failed install must not leave the operator's
  # own hook displaced. ARRAYS, and a sentinel on the readlink: a target may end in a newline,
  # which `$(…)` alone would strip and a line-structured record could not carry.
  local -a fresh_name=() fresh_prior=()
  local s dest prior
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    dest="$HOME/.claude/scripts/$s"
    adb_link_into "$dest" "$REPO" && continue
    prior=""
    # `readlink -n`: GNU readlink appends a newline of its own and BSD does not, so only `-n` plus
    # the sentinel yields the target's exact bytes on both.
    if [ -L "$dest" ]; then prior="$(readlink -n "$dest"; printf x)"; prior="${prior%x}"; fi
    fresh_name+=("$s"); fresh_prior+=("$prior")
  done <<EOF
$(adb_claude_hook_scripts)
EOF
  adb_link_manifest "$BACKUP_DIR" <<EOF || rc=1
$manifest
EOF

  # Propagate a wiring failure into the install's exit status. Without this the `return 1`s in
  # wire_hooks are dead: install.sh would exit 0 with a corrupt settings.json, and bin/baseline's
  # adb_self_heal — which gates only on that status — would report "update complete" while the
  # gates sat silently unwired. (A missing jq deliberately returns 0; see wire_hooks.)
  if [ "$WIRE_HOOKS" -eq 1 ]; then
    local wrc=0 i
    wire_hooks || wrc=$?
    # NOT WIRED — failed (rc 1, the install fails too) or SKIPPED for want of jq (rc 3, a documented
    # degradation that does not fail the install). Either way the links this run added would be an
    # owned link with no entry, the per-hook opt-out's exact shape, so both take them back.
    if [ "$wrc" -ne 0 ]; then
      [ "$wrc" -eq 3 ] || rc=1
      for (( i = 0; i < ${#fresh_name[@]}; i++ )); do
        dest="$HOME/.claude/scripts/${fresh_name[$i]}"
        adb_link_into "$dest" "$REPO" || continue
        rm -f "$dest" || { adb_info "  WARN   could not take back $dest — remove it by hand, or the next self-heal reads it as a per-hook opt-out"; continue; }
        adb_displaced_restore "$dest" "$BACKUP_DIR" "${fresh_prior[$i]}" \
          || adb_info "  WARN   could not restore what $dest displaced (backup under $BACKUP_DIR) — restore it by hand"
      done
      if [ "${#fresh_name[@]}" -gt 0 ]; then
        if [ "$wrc" -eq 3 ]; then
          adb_info "  (hook links added by this run were taken back: hooks were not wired without jq, and an owned link with no entry would read as a per-hook opt-out; install jq and re-run to get them)"
        else
          adb_info "  (hook links added by this run were taken back: wiring failed, and an owned link with no entry would read as a per-hook opt-out on the next self-heal)"
        fi
      fi
    fi
  else
    adb_info "  (gates not wired — --no-hooks)"
  fi

  # THE SECOND SETTINGS SURFACE (#248), and deliberately AFTER the hook wiring, not folded into
  # it: wire_hooks copies the PRISTINE settings.json into $BACKUP_DIR, and wire_settings must see
  # that backup already there so it does not overwrite it with the hook-wired intermediate.
  # Its own write is atomic (tmp + mv), so a failure here leaves the hook entries standing and the
  # sandbox keys simply unwritten — two independent surfaces, neither half-applied.
  local src=0
  wire_settings || src=$?
  [ "$src" -eq 0 ] || [ "$src" -eq 3 ] || rc=1
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
# Returns 0 wired, 3 skipped (no jq — tolerated, but the caller must not leave this run's hook links
# behind), 1 on any other failure. The status matters: the previous version ended with an unconditional
# "wired" line even when jq or mv had failed, so a broken settings.json was reported as success
# and enforcement was silently off.
wire_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    # The ONE tolerated degradation, and a documented one (docs/installation.md): warn, but do
    # not fail the install. Every other failure below is a genuinely broken state and returns 1.
    adb_info "  WARN   jq not found — cannot wire hooks; install jq and re-run, or wire manually"
    return 3   # skipped, not failed: the caller takes back this run's hook links and keeps rc 0
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
  # Through the shared primitive for the same two reasons the settings writer uses it: a directory
  # at the destination would swallow the rename and report success, and a bare `mv` publishes the
  # temp file's umask mode over a settings.json the operator may have deliberately restricted.
  adb_publish_json "$tmp" "$settings" || {
    adb_info "  WARN   could not write ~/.claude/settings.json — hooks NOT wired"; return 1; }
  adb_info "  hooks  wired global Stop gates + SessionStart currency and run-state hooks into ~/.claude/settings.json (backed up)"
  # THE RECEIPT, after the entries are durable: what the next self-heal reads to tell a removed
  # entry from one that never landed (adb_claude_hooks_receipt). Written by rename, like the
  # settings; a receipt that cannot be written is said, and the wiring above still stands.
  local receipt; receipt="$(adb_claude_hooks_receipt "$HOME")"
  if adb_claude_hook_scripts > "$receipt.adb.$$.tmp" 2>/dev/null && mv "$receipt.adb.$$.tmp" "$receipt" 2>/dev/null; then :; else
    rm -f "$receipt.adb.$$.tmp"
    adb_info "  WARN   could not write the wiring receipt $receipt — a hook entry you later remove will be re-wired by the next self-heal until it exists"
  fi
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
  # Dispose of the destinations this framework has RETIRED (#378) — paths it once linked and no
  # longer does. install.sh otherwise only ever adds or relinks, so a removed manifest row leaves
  # a dangling symlink in an existing install that nothing here would ever clean up; `git pull`
  # certainly does not. Ownership is scoped in common.sh (exact former target, and only when the
  # link no longer resolves), so a real file or a link pointing elsewhere is never touched. An
  # unknown agent token has an empty register and is a silent no-op.
  #
  # AFTER the agent's own install, not before, and for a reason rather than by taste: both
  # producers share one precondition, so an unrepresentable $REPO/$HOME refuses BOTH — running
  # this first would put its refusal where the operator expects install_claude's "nothing was
  # linked". Pruning is independent of linking (a retired destination is by definition absent
  # from the live manifest), so the order costs nothing.
  adb_prune_retired "$a" "$REPO" "$HOME" || install_rc=1
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
