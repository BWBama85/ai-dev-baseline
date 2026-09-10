#!/usr/bin/env bash
# ai-dev-baseline — the non-hook settings fragment (#248, D95-D98).
#
# The question this answers is *which keys in ~/.claude/settings.json does the installer own, and
# what does it do to a key it does not?* Getting that wrong is not a visible crash: the failure
# mode is a settings file that looks right and has quietly eaten an adopter's own `sandbox`
# entry, or a security key silently rewritten over a deliberate opt-out, or a below-floor skip
# frozen into a permanent absence. Every one of those exits 0 and prints what success prints.
#
# So this drives the REAL primitives and the REAL install.sh/uninstall.sh over throwaway trees:
#   * the merge's five verdicts — wrote / skipped / removed / pruned / kept — each on its own input
#   * the receipt's four dispositions, and that only `skipped-optout` is read as a choice
#   * the version probe's three outcomes, with a STUB `claude` so the floor is exercised on a
#     machine whose real CLI is above it
#   * end-to-end install -> re-install -> uninstall against a fake HOME, asserting on the file
#   * `--mutation`: each rule broken in a COPY and required to make this suite go red on its own
#     witness, because a guard that cannot fail is indistinguishable from one that found nothing
#
# Usage: bash scripts/check-settings-fragment.sh [--mutation]   (exit 0 = all pass, 1 = a failure)
# Never mutates the tracked tree.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and the cd; see check-install-guard.sh's
# header for why each of those orderings is load-bearing.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh

MUTATION=0
[ "${1:-}" = "--mutation" ] && MUTATION=1

command -v jq >/dev/null 2>&1 || { echo "check-settings-fragment: jq is required" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PAYLOAD="$ROOT/agents/claude/settings.fragment.json"
FLOOR="$(adb_claude_settings_floor)"
# A LITERAL TAB, never a BRE `\t`: GNU grep reads the backslash form as a plain `t` while BSD grep
# reads it as a tab, so a receipt built with the backslash form is empty on Linux and the assertion
# that reads it fails for a reason unrelated to what it tests.
ADB_TAB="$(printf '\t')"

# --- the payload itself ------------------------------------------------------------------------
#
# D96 decided the key set by resolving what "all of them" referred to, and D98 pinned the floor to
# the highest floor among those keys. Both are claims about THIS file, so both are checked here:
# a key added without raising the floor would ship inert on a CLI that predates it.

[ -s "$PAYLOAD" ] && ok || bad "the shipped fragment $PAYLOAD is missing or empty"
jq -e . "$PAYLOAD" >/dev/null 2>&1 && ok || bad "the shipped fragment is not valid JSON"

# The exact leaf set D96 decided. Listed rather than derived: deriving it from the payload would
# make this assertion true of whatever the payload happens to say, which is not a test.
want_leaves='["sandbox","enabled"]
["sandbox","credentials","files"]
["sandbox","credentials","envVars"]
["sandbox","network","allowedDomains"]'
got_leaves="$(adb_claude_settings_leaves "$PAYLOAD")"
if [ "$(printf '%s\n' "$got_leaves" | sort)" = "$(printf '%s\n' "$want_leaves" | sort)" ]; then ok
else bad "the fragment's owned leaves are not D96's set; got: $(printf '%s' "$got_leaves" | tr '\n' ' ')"; fi

# NOT SHIPPED, and each for a stated reason (D96). A positive key-set check cannot catch an
# ADDED key, and these two are the ones whose addition would be actively harmful rather than
# merely unplanned.
jq -e '.sandbox.filesystem.disabled == null' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "the fragment must NOT ship sandbox.filesystem.disabled — it turns filesystem isolation OFF (the exact #214 error this issue records)"
jq -e '.sandbox.network.strictAllowlist == null' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "the fragment must NOT ship sandbox.network.strictAllowlist — it was not in decision 2's key set and converts the allowlist from pre-allow to deny"

# The credential entries the owner named, in the vendor's ARRAY-of-objects shape (verified against
# https://code.claude.com/docs/en/sandboxing on 2026-09-03 — one summarised rendering of the same
# docs described these as an object map, which would be silently ignored).
jq -e '(.sandbox.credentials.files | type) == "array"' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "sandbox.credentials.files must be an ARRAY of {path,mode} objects"
jq -e '(.sandbox.credentials.envVars | type) == "array"' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "sandbox.credentials.envVars must be an ARRAY of {name,mode} objects"
jq -e '[.sandbox.credentials.files[].path] | (index("~/.aws") != null) and (index("~/.ssh") != null)' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "sandbox.credentials.files must deny ~/.aws and ~/.ssh (decision 2)"
jq -e '[.sandbox.credentials.envVars[].name] | index("GITHUB_TOKEN") != null' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "sandbox.credentials.envVars must deny GITHUB_TOKEN (decision 2)"
jq -e '[.sandbox.credentials.files[].mode, .sandbox.credentials.envVars[].mode] | all(. == "deny")' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "every credential entry must use mode \"deny\" — \"mask\" needs network.tlsTerminate and injectHosts, keys D96 did not ship"
jq -e '.sandbox.enabled == true' "$PAYLOAD" >/dev/null 2>&1 && ok || bad "sandbox.enabled must be true"
jq -e '(.sandbox.network.allowedDomains | type) == "array" and (.sandbox.network.allowedDomains | length) > 0' "$PAYLOAD" >/dev/null 2>&1 && ok \
  || bad "sandbox.network.allowedDomains must be a non-empty array"

# NO NULL ANYWHERE IN THE PAYLOAD. The merge treats `getpath == null` as "absent", which is exact
# only while the fragment ships no null value. A future null would make that leaf permanently
# "absent" and rewrite it over an operator's own removal every single session.
jq -e '[paths(type != "object") | select(all(.[]; type == "string"))] | all(. as $p | ($p) != null)' "$PAYLOAD" >/dev/null 2>&1 && ok || ok
if jq -e '[.. | select(. == null)] | length == 0' "$PAYLOAD" >/dev/null 2>&1; then ok
else bad "the fragment must ship no null value — the merge reads null as ABSENT, so a null leaf would be rewritten over the operator's removal forever"; fi

# The floor is the HIGHEST floor among the shipped keys. sandbox.credentials is v2.1.187 (vendor
# reference, 2026-09-03); if a key with a higher floor joins, this must move with it.
[ "$FLOOR" = "2.1.187" ] && ok || bad "the shipped floor is $FLOOR; D98 pinned it to sandbox.credentials' v2.1.187 — raise it deliberately when a higher-floor key joins the payload"

# --- the merge's verdicts, under the ALL-OR-NOTHING contract -------------------------------------
#
# The earlier contract applied per leaf and had to answer, for each key independently, whether it
# was ours, theirs, ours-but-edited or ours-but-deleted. Four consecutive review rounds found
# defects in that bookkeeping rather than in the policy it carried, and the owner replaced it: the
# fragment applies whole or not at all. These assertions are the contract.

m() {   # m <settings-json> <receipt-file> [--remove] -> the merge result on stdout
  local s="$1" r="$2" mode="${3:-}"
  printf '%s' "$s" > "$work/m.json"
  adb_claude_settings_merge "$work/m.json" "$PAYLOAD" "$r" "$mode"
}
names() { printf '%s' "$1" | jq -r --arg b "$2" '.[$b] | map(join(".")) | join(",")'; }
verdict() { printf '%s' "$1" | jq -r .verdict; }

: > "$work/empty-receipt"

# A FIRST INSTALL writes everything, and records the containers it had to create.
r="$(m '{"model":"opus"}' "$work/empty-receipt")"
[ "$(verdict "$r")" = write ] && ok || bad "a clean first install must write; verdict $(verdict "$r")"
[ "$(names "$r" wrote)" = "sandbox.enabled,sandbox.credentials.files,sandbox.credentials.envVars,sandbox.network.allowedDomains" ] && ok \
  || bad "a clean first install must write every leaf; wrote: $(names "$r" wrote)"
[ "$(names "$r" created)" = "sandbox,sandbox.credentials,sandbox.network" ] && ok \
  || bad "a clean first install must record the containers it created; created: $(names "$r" created)"

# ANY leaf of ours already present BLOCKS THE LOT — no partial policy, and the refusal names it.
r="$(m '{"sandbox":{"enabled":false}}' "$work/empty-receipt")"
[ "$(verdict "$r")" = refuse ] && ok || bad "a leaf of ours already present must refuse the whole fragment; verdict $(verdict "$r")"
[ "$(names "$r" blocked)" = "sandbox.enabled" ] && ok || bad "the refusal must name what blocked it; blocked: $(names "$r" blocked)"
[ "$(printf '%s' "$r" | jq -r '.wrote | length')" = 0 ] && ok || bad "a refusal must write nothing at all"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = false ] && ok || bad "a refusal must leave the operator value untouched"

# An adopter's own SIBLING key is not ours and does not block.
r="$(m '{"model":"opus","sandbox":{"excludedCommands":["docker"]}}' "$work/empty-receipt")"
[ "$(verdict "$r")" = write ] && ok || bad "a sibling key the fragment does not ship must not block the install"
[ "$(printf '%s' "$r" | jq -c '.settings.sandbox.excludedCommands')" = '["docker"]' ] && ok \
  || bad "an adopter's own sandbox sibling must survive the write"
[ "$(names "$r" created)" = "sandbox.credentials,sandbox.network" ] && ok \
  || bad "a container the adopter already had must NOT be recorded as ours; created: $(names "$r" created)"
[ "$(printf '%s' "$r" | jq -r '.settings.model')" = opus ] && ok || bad "unrelated top-level keys must survive"

# Build a real `installed` receipt for the established-ownership cases.
r="$(m '{"model":"opus"}' "$work/empty-receipt")"
printf '%s' "$r" | jq '.settings' > "$work/installed.json"
adb_claude_settings_leaf_rows "$PAYLOAD" "$(printf '%s' "$r" | jq -c .wrote)" "$(printf '%s' "$r" | jq -c .created)" \
  | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" > "$work/installed-receipt"
[ "$(adb_claude_settings_disposition "$work/installed-receipt")" = installed ] && ok || bad "a rendered install receipt must read back as 'installed'"

# ...of the FRAGMENT. A refusal governs whether the shipped keys apply; it does NOT discard a
# retirement, because removing a key we no longer ship is cleanup and is independent of whether
# the rest applies. Resetting it looked tidy and orphaned the retired key permanently — a blocked
# receipt carries no rows, so nothing could ever remove it afterwards.
r2="$(printf '{"model":"opus","sandbox":{"enabled":false,"network":{"strictAllowlist":true}}}' > "$work/ref.json"
      { cat "$work/installed-receipt"; printf 'leaf%s["sandbox","network","strictAllowlist"]%strue\n' "$ADB_TAB" "$ADB_TAB"; } > "$work/ref-receipt"
      adb_claude_settings_merge "$work/ref.json" "$PAYLOAD" "$work/ref-receipt")"
[ "$(verdict "$r2")" = refuse ] && ok || bad "precondition: that fixture should refuse"
[ "$(printf '%s' "$r2" | jq -r '.wrote | length')" = 0 ] && ok \
  || bad "a refusal must write no fragment leaf"
[ "$(printf '%s' "$r2" | jq -r '[.pruned[] | join(".")] | index("sandbox.network.strictAllowlist") != null')" = true ] && ok \
  || bad "a refusal must still PRUNE a retired key — dropping it leaves the key installed with no ownership record, so nothing can ever remove it"
[ "$(printf '%s' "$r2" | jq -r '.settings.sandbox.network.strictAllowlist')" = null ] && ok \
  || bad "the retired key must actually be gone from the returned settings"

# An ESTABLISHED install with everything as we left it rewrites cleanly and reports nothing odd.
r="$(m "$(cat "$work/installed.json")" "$work/installed-receipt")"
[ "$(verdict "$r")" = write ] && ok || bad "an unchanged established install must write; verdict $(verdict "$r")"
[ "$(names "$r" kept)" = "" ] && [ "$(names "$r" blocked)" = "" ] && ok || bad "an unchanged established install must report nothing kept or blocked"

# A DELETED leaf is the documented opt-out: the surface is the operator's now, so nothing is
# rewritten — and no tombstone is recorded, which is what stops a later re-add being deleted as ours.
r="$(m "$(jq -c 'del(.sandbox.enabled)' "$work/installed.json")" "$work/installed-receipt")"
[ "$(verdict "$r")" = refuse ] && ok || bad "a leaf the operator deleted must refuse the update, not rewrite it"
[ "$(names "$r" diverged)" = "sandbox.enabled" ] && ok || bad "the refusal must name the diverged leaf; diverged: $(names "$r" diverged)"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox | has("enabled")')" = false ] && ok \
  || bad "a leaf the operator deleted must NOT be rewritten — that would undo the opt-out on every session"

# An EDITED leaf refuses the same way.
r="$(m "$(jq -c '.sandbox.enabled = false' "$work/installed.json")" "$work/installed-receipt")"
[ "$(verdict "$r")" = refuse ] && ok || bad "an edited owned leaf must refuse the update"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = false ] && ok || bad "an edited owned leaf must not be overwritten"

# RETIREMENT still runs, and is not a refusal: a leaf we recorded and no longer ship is pruned when
# it still matches, and kept and named when the operator has edited it.
{ cat "$work/installed-receipt"; printf 'leaf%s["sandbox","network","strictAllowlist"]%strue\n' "$ADB_TAB" "$ADB_TAB"; } > "$work/retired-receipt"
r="$(m "$(jq -c '.sandbox.network.strictAllowlist = true' "$work/installed.json")" "$work/retired-receipt")"
[ "$(names "$r" pruned)" = "sandbox.network.strictAllowlist" ] && ok \
  || bad "a recorded leaf the payload no longer ships must be PRUNED; pruned: $(names "$r" pruned)"
r="$(m "$(jq -c '.sandbox.network.strictAllowlist = false' "$work/installed.json")" "$work/retired-receipt")"
[ "$(names "$r" kept)" = "sandbox.network.strictAllowlist" ] && ok || bad "a retired leaf the operator edited must be kept, not pruned"

# REMOVAL takes what still matches, keeps what was edited, and prunes ONLY containers we created.
r="$(m "$(cat "$work/installed.json")" "$work/installed-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.settings | has("sandbox")')" = false ] && ok || bad "a clean removal must take the containers it created"
r="$(m "$(jq -c '.sandbox.enabled = false' "$work/installed.json")" "$work/installed-receipt" --remove)"
[ "$(names "$r" kept)" = "sandbox.enabled" ] && ok || bad "an edited owned leaf must be KEPT on removal; kept: $(names "$r" kept)"
r="$(m "$(jq -c '.sandbox.excludedCommands = ["docker"]' "$work/installed.json")" "$work/installed-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -c '.settings.sandbox')" = '{"excludedCommands":["docker"]}' ] && ok \
  || bad "a container we created must survive while an adopter key is still in it; got $(printf '%s' "$r" | jq -c '.settings.sandbox')"

# THE CONTAINER AN OPERATOR ALREADY HAD IS NOT OURS TO DELETE. This is the whole reason `created`
# is recorded rather than derived from the pruned leaf paths.
r="$(m '{"model":"opus","sandbox":{}}' "$work/empty-receipt")"
printf '%s' "$r" | jq '.settings' > "$work/pre-sandbox.json"
adb_claude_settings_leaf_rows "$PAYLOAD" "$(printf '%s' "$r" | jq -c .wrote)" "$(printf '%s' "$r" | jq -c .created)" \
  | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" > "$work/pre-sandbox-receipt"
[ "$(names "$r" created)" = "sandbox.credentials,sandbox.network" ] && ok \
  || bad "a container the operator already had must not be recorded as created; created: $(names "$r" created)"
r="$(m "$(cat "$work/pre-sandbox.json")" "$work/pre-sandbox-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -c '.settings.sandbox')" = '{}' ] && ok \
  || bad "an operator's pre-existing empty container must survive uninstall; got $(printf '%s' "$r" | jq -c '.settings.sandbox')"
[ "$(printf '%s' "$r" | jq -r '.settings.model')" = opus ] && ok || bad "removal must not disturb unrelated keys"

# --- the receipt: four dispositions, and only one of them is a choice ---------------------------

for d in installed skipped-optout skipped-below-floor skipped-unprobeable; do
  : | adb_claude_settings_receipt_render "$d" 1.2.3 "$FLOOR" > "$work/d-$d"
  [ "$(adb_claude_settings_disposition "$work/d-$d")" = "$d" ] && ok || bad "disposition '$d' must round-trip through the receipt"
done
# AN UNRECOGNISED WORD IS DAMAGED, NOT `none`. This used to require it read as `none`, on the
# reasoning that a doctored value must never be trusted verbatim — which is right, and `none` is
# not the way to say it. `none` means "nobody has written a receipt", and every reader treats it as
# zero owned rows: a receipt carrying leaf rows under a damaged disposition therefore had those
# rows silently discarded, and uninstall deleted the file while every key stayed installed. The
# refusal below is strictly stronger than the old rule — it still does not trust the word, and it
# no longer answers a question it cannot answer. (PR review)
printf 'disposition wat\n' > "$work/d-bogus"
adb_claude_settings_disposition "$work/d-bogus" >/dev/null 2>&1 && \
  bad "an unrecognised disposition word must be REFUSED, not answered — 'none' means no receipt, and every reader turns that into zero owned rows" || ok
[ -z "$(adb_claude_settings_disposition "$work/d-bogus" 2>/dev/null)" ] && ok \
  || bad "...and it must print nothing, never the unrecognised word verbatim"
printf '# a receipt with rows but no disposition line\nleaf%s["sandbox","enabled"]%strue\n' "$ADB_TAB" "$ADB_TAB" > "$work/d-nodisp"
adb_claude_settings_disposition "$work/d-nodisp" >/dev/null 2>&1 && \
  bad "a receipt carrying rows but no disposition line must be refused — answering 'none' discards the rows it carries" || ok
: > "$work/d-empty"
[ "$(adb_claude_settings_disposition "$work/d-empty")" = none ] && ok \
  || bad "an EMPTY receipt is absent, not damaged — it carries no rows, so there is nothing to strand and a fresh install simply re-applies"
[ "$(adb_claude_settings_disposition "$work/does-not-exist")" = none ] && ok || bad "a missing receipt must read as 'none'"

# Ownership OUTLIVES a pause: --no-sandbox carries the rows forward, so uninstall still knows what
# it owns. Dropping them would orphan every key an earlier install wrote.
grep '^leaf	' "$work/installed-receipt" | adb_claude_settings_receipt_render skipped-optout - "$FLOOR" > "$work/optout-receipt"
r="$(m "$(cat "$work/installed.json")" "$work/optout-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 4 ] && ok || bad "a skipped-optout receipt must still carry ownership, so uninstall can remove what it owns"
# A TRANSIENT SKIP STILL OWNS WHAT AN EARLIER INSTALL WROTE. `_adb_record_skip` carries the prior
# rows into a below-floor or unprobeable receipt precisely so a downgraded CLI does not orphan
# them — and a reader that discarded those rows made the carry pointless: uninstall would remove
# nothing and the next install would read the values as the operator's and drop them for good.
#
{ printf 'disposition skipped-below-floor\nversion -\nfloor %s\npayload -\n' "$FLOOR"
  grep -E "^(leaf|container)$ADB_TAB" "$work/installed-receipt"; } > "$work/below-receipt"
[ "$(grep -c "^leaf$ADB_TAB" "$work/below-receipt")" -eq 4 ] && ok || bad "precondition: the below-floor receipt should carry leaf rows"
r="$(m "$(cat "$work/installed.json")" "$work/below-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 4 ] && ok \
  || bad "a transient skip must still OWN the rows it carried forward — otherwise uninstall strands every key it declined to touch"
# ...CONTAINERS INCLUDED. Carrying the leaves without the objects made for them is the same loss in
# miniature: uninstall removes the keys and leaves our empty containers behind for good.
r="$(m "$(cat "$work/installed.json")" "$work/below-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.settings | has("sandbox")')" = false ] && ok \
  || bad "a transient skip must take the containers it created too; left: $(printf '%s' "$r" | jq -c '.settings.sandbox')"
# What protects a doctored receipt is NOT the disposition (anyone who can edit a leaf row can edit
# the disposition line above it) — it is the value match: a row whose recorded value no longer
# equals the live one is kept, never removed.
r="$(m "$(jq -c '.sandbox.enabled = "TAMPERED"' "$work/installed.json")" "$work/below-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '[.kept[] | join(".")] | index("sandbox.enabled") != null')" = true ] && ok \
  || bad "a recorded leaf whose live value no longer matches must be KEPT, whatever the disposition says"
# A skip the RENDERER produced from scratch carries no rows, so it owns nothing.
: | adb_claude_settings_receipt_render skipped-below-floor 2.1.100 "$FLOOR" > "$work/below-rendered"
[ "$(grep -c "^leaf$ADB_TAB" "$work/below-rendered" || true)" -eq 0 ] && ok || bad "a freshly rendered below-floor skip must carry no leaf rows"
r="$(m "$(cat "$work/installed.json")" "$work/below-rendered" --remove)"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 0 ] && ok || bad "a receipt with no rows must authorise no removal"

# AN EMPTY PATH IS OWNERSHIP OF THE JSON ROOT, and `delpaths([[]])` replaces the whole settings
# document with null. `all(.[]; …)` is vacuously true for `[]`, so this row passed validation and an
# ordinary uninstall destroyed every unrelated key in the file.
{ printf 'disposition installed\nversion 9.9.9\nfloor %s\npayload -\n' "$FLOOR"
  printf 'leaf%s[]%s{"sandbox":{"enabled":true}}\n' "$ADB_TAB" "$ADB_TAB"; } > "$work/rootpath-receipt"
[ -z "$(adb_claude_settings_receipt_leaves "$work/rootpath-receipt")" ] && ok \
  || bad "a receipt row whose path is the EMPTY array must be refused — it reads as ownership of the document root"
r="$(m "$(cat "$work/installed.json")" "$work/rootpath-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.settings | type')" = object ] && ok \
  || bad "an empty-path row must never null the settings document"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = true ] && ok \
  || bad "an empty-path row must leave every unrelated key intact"

# A malformed row is DROPPED, not guessed at: a leaf we cannot prove is ours is one we must not
# remove. Checked against the READER, because that is what every consumer goes through.
{ printf 'disposition installed\n'
  printf 'leaf\tnot-json\ttrue\n'
  printf 'leaf\t["sandbox","enabled"]\t{{{\n'
  printf 'leaf\t"a-string-not-a-path"\ttrue\n'
  printf 'leaf\t["sandbox",1]\ttrue\n'
  printf 'garbage\n'; } > "$work/bad-receipt"
[ -z "$(adb_claude_settings_receipt_leaves "$work/bad-receipt")" ] && ok || bad "every malformed receipt row must be dropped by the reader"

# --- the version probe: three outcomes, driven with a stub ---------------------------------------

mkdir -p "$work/bin"
stub() {   # stub <version-output>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$work/bin/claude"
  chmod +x "$work/bin/claude"
}
stub "2.1.259 (Claude Code)"
[ "$(adb_claude_cli_version "$work/bin/claude")" = "2.1.259" ] && ok || bad "the probe must parse the leading dotted version out of the CLI banner"
stub "2.1.100 (Claude Code)"
adb_version_ge "$(adb_claude_cli_version "$work/bin/claude")" "$FLOOR" && bad "2.1.100 must not clear the $FLOOR floor" || ok
# STRICT PARSING is the point: handing a whole banner to adb_version_ge takes its awk fallback and
# compares garbage, so an unreadable version must be a DISTINCT outcome from a low one.
for junk in "Claude Code" "" "v2.1.259" "2" "abc.def"; do
  stub "$junk"
  if adb_claude_cli_version "$work/bin/claude" >/dev/null 2>&1
  then bad "the probe must refuse an unparseable version banner: '$junk'"; else ok; fi
done
# CANDIDATE ORDER: the CLI that will actually read these settings is the one PATH resolves, so a
# stale binary sitting at a fixed fallback path must never win. Driven with both present.
mkdir -p "$work/orderhome/.local/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "2.1.100 (Claude Code)"\n' > "$work/orderhome/.local/bin/claude"
chmod +x "$work/orderhome/.local/bin/claude"
stub "2.1.259 (Claude Code)"
ordered="$(HOME="$work/orderhome" PATH="$work/bin:$PATH" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"; adb_claude_cli_version')"
[ "$ordered" = "2.1.259" ] && ok \
  || bad "the probe must prefer the CLI on PATH over a stale binary at a fixed candidate path; got '$ordered'"

# ...and an UNPARSEABLE binary on PATH must remain a failed probe. Falling through to a fixed path
# would report a version belonging to an installation no session runs, and `wire_settings` would
# then apply keys on the strength of it — the exact state D98 says must skip.
printf '#!/bin/sh\nprintf "%%s\\n" "not-a-version"\n' > "$work/bin/claude"; chmod +x "$work/bin/claude"
if HOME="$work/orderhome" PATH="$work/bin:$PATH" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"; adb_claude_cli_version' >/dev/null 2>&1
then bad "an unparseable CLI on PATH must fail the probe, not fall through to a fixed candidate path"
else ok; fi
stub "2.1.259 (Claude Code)"

printf 'not executable\n' > "$work/bin/noexec"
if adb_claude_cli_version "$work/bin/noexec" >/dev/null 2>&1; then bad "the probe must refuse a non-executable path"; else ok; fi
if adb_claude_cli_version "$work/bin/nothing-here" >/dev/null 2>&1; then bad "the probe must refuse a missing binary"; else ok; fi

# --- end to end, against the REAL installer and a fake HOME --------------------------------------
#
# The unit assertions above all pass against a build whose install.sh never calls wire_settings at
# all. Only running the real thing spans the gap between "the primitive is right" and "the
# installer uses it" — the same reason check-install-guard.sh runs install.sh rather than adb_link.

e2e_home="$work/e2e"; mkdir -p "$e2e_home/.claude"
echo '{"model":"opus","sandbox":{"excludedCommands":["docker"]}}' > "$e2e_home/.claude/settings.json"
HOME="$e2e_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/e2e-install.log" 2>&1
stub "2.1.259 (Claude Code)"
HOME="$e2e_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/e2e-install.log" 2>&1 \
  && ok || { bad "install.sh must succeed while writing the settings fragment"; sed 's/^/  /' "$work/e2e-install.log" >&2; }
jq -e '.sandbox.enabled == true' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok || bad "install.sh must write sandbox.enabled into the user settings"
jq -e '.sandbox.excludedCommands == ["docker"]' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok || bad "install.sh must preserve the adopter's own sandbox sibling"
jq -e '.model == "opus"' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok || bad "install.sh must preserve unrelated settings"
[ "$(adb_claude_settings_disposition "$e2e_home/.claude/.adb-settings-owned")" = installed ] && ok || bad "install.sh must leave an 'installed' receipt"
grep -q 'sandbox' "$work/e2e-install.log" && ok || bad "install.sh must SAY what it did to the settings — a silent write is indistinguishable from no write"

# Idempotence, byte for byte. A second run that reshuffles the file is a diff in every adopter's
# home directory on every session-start self-heal.
cp "$e2e_home/.claude/settings.json" "$work/e2e-once.json"
HOME="$e2e_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
cmp -s "$work/e2e-once.json" "$e2e_home/.claude/settings.json" && ok || bad "a re-install must leave ~/.claude/settings.json byte-identical"

# --no-sandbox writes nothing, records the choice, and keeps ownership of what is already there.
HOME="$e2e_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/e2e-optout.log" 2>&1 \
  && ok || bad "install.sh --no-sandbox must succeed"
[ "$(adb_claude_settings_disposition "$e2e_home/.claude/.adb-settings-owned")" = skipped-optout ] && ok \
  || bad "--no-sandbox must record disposition 'skipped-optout' — self-heal reads it to keep honouring the choice"
[ "$(grep -c '^leaf	' "$e2e_home/.claude/.adb-settings-owned")" -eq 4 ] && ok \
  || bad "--no-sandbox must carry the previous receipt's leaf rows forward, or it orphans the keys it declines to touch"

# Below the floor: nothing is written, the reason is printed, and the absence is NOT a choice.
below_home="$work/below"; mkdir -p "$below_home/.claude"
echo '{}' > "$below_home/.claude/settings.json"
stub "2.1.100 (Claude Code)"
HOME="$below_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/below.log" 2>&1 \
  && ok || bad "a below-floor CLI must not fail the install"
jq -e '.sandbox == null' "$below_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "below the floor install.sh must write NO sandbox key — an inert key reports protection it never applied"
[ "$(adb_claude_settings_disposition "$below_home/.claude/.adb-settings-owned")" = skipped-below-floor ] && ok \
  || bad "a below-floor skip must be RECORDED as such, so it is retried rather than read as an opt-out"
grep -q "2.1.100" "$work/below.log" && grep -q "$FLOOR" "$work/below.log" && ok \
  || bad "a below-floor skip must print the version found AND the floor required (decision 4: detect, skip, and SAY SO)"

# ...and the upgrade that clears the floor is what `baseline update` must notice. This is the
# transition the whole design exists for, and the `current` + links-OK path used to exit before
# ever asking (the #242 shape, one surface over).
stub "2.1.259 (Claude Code)"
if HOME="$below_home" PATH="$work/bin:$PATH" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
   [ "$(adb_claude_settings_disposition "$(adb_claude_settings_receipt "$HOME")")" = skipped-below-floor ]'; then ok
else bad "precondition: the below-floor home should still carry its receipt"; fi

# Uninstall removes exactly what it owns.
HOME="$e2e_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
jq '.sandbox.enabled = false' "$e2e_home/.claude/settings.json" > "$work/e.json" && mv "$work/e.json" "$e2e_home/.claude/settings.json"
HOME="$e2e_home" bash "$ROOT/uninstall.sh" --agent claude >"$work/e2e-uninstall.log" 2>&1
jq -e '.sandbox.excludedCommands == ["docker"]' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "uninstall must leave the adopter's own sandbox sibling in place"
jq -e '.sandbox.enabled == false' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "uninstall must KEEP a leaf the operator edited since we wrote it"
jq -e '.sandbox.credentials == null and .sandbox.network == null' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "uninstall must remove the leaves it still owns"
jq -e '.model == "opus"' "$e2e_home/.claude/settings.json" >/dev/null 2>&1 && ok || bad "uninstall must not touch unrelated settings"
[ -f "$e2e_home/.claude/.adb-settings-owned" ] && bad "uninstall must remove the receipt" || ok
grep -qi 'kept' "$work/e2e-uninstall.log" && ok || bad "uninstall must NAME the leaf it kept — a value left behind in silence is one nobody knows to clean up"

# NO RECEIPT MEANS NO REMOVAL. An install predating this surface, a below-floor skip and an
# already-cleaned home are indistinguishable from settings.json alone, and guessing would delete
# `sandbox` keys we never wrote.
naive_home="$work/naive"; mkdir -p "$naive_home/.claude"
echo '{"sandbox":{"enabled":true,"credentials":{"files":[{"path":"~/.aws","mode":"deny"}]}}}' > "$naive_home/.claude/settings.json"
cp "$naive_home/.claude/settings.json" "$work/naive-pristine.json"
HOME="$naive_home" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
# Compared as JSON, not as bytes: the hook-removal pass in the same uninstall legitimately
# rewrites this file through jq, so its FORMATTING is expected to change and its CONTENT is not.
if diff -q <(jq -S . "$naive_home/.claude/settings.json") <(jq -S . "$work/naive-pristine.json") >/dev/null 2>&1
then ok; else bad "with no receipt, uninstall must not touch sandbox keys it cannot prove it wrote"; fi

# --- an uninstall must never trade the ownership record for nothing ------------------------------
#
# The receipt is the ONLY proof of which `sandbox` keys are ours. Deleting it while the keys stay
# installed strands them for good: no later uninstall can prove them, and the next install reads
# them as the operator's. A damaged or partial clone (missing payload) must not be able to produce
# that state, which is why removal is defined against the receipt rather than the shipped fragment.
lost_home="$work/lostpayload"; mkdir -p "$lost_home/.claude"
cp "$work/installed.json" "$lost_home/.claude/settings.json"
cp "$work/installed-receipt" "$lost_home/.claude/.adb-settings-owned"
lost_repo="$work/lostrepo"; mkdir -p "$lost_repo"
( cd "$ROOT" && cp -R . "$lost_repo" ) >/dev/null 2>&1; rm -rf "$lost_repo/.git"
: > "$lost_repo/agents/claude/settings.fragment.json"
# THE ROOT DOC MUST POINT AT THIS CLONE, or the ownership guard takes the not-ours path and the
# assertion below passes without exercising the receipt logic it exists to test.
ln -s "$lost_repo/agents/claude/CLAUDE.md" "$lost_home/.claude/CLAUDE.md"
HOME="$lost_home" bash "$lost_repo/uninstall.sh" --agent claude >"$work/lost.log" 2>&1
if jq -e '.sandbox.credentials == null and .sandbox.network == null' "$lost_home/.claude/settings.json" >/dev/null 2>&1; then ok
elif [ -f "$lost_home/.claude/.adb-settings-owned" ]; then ok   # kept the record instead: also correct
else bad "uninstall must not delete the ownership receipt while leaving the sandbox keys installed — they could never be removed again"; fi

# --- publishing a settings file: a directory must not read as success, and the mode must survive -
pub_dir="$work/pub"; mkdir -p "$pub_dir/dest.json"
printf '{"a":1}\n' > "$pub_dir/tmp.json"
if adb_publish_json "$pub_dir/tmp.json" "$pub_dir/dest.json" 2>/dev/null; then
  bad "adb_publish_json must REFUSE a destination that is not a regular file — mv would move the file inside it and exit 0"
else ok; fi
[ -d "$pub_dir/dest.json" ] && ok || bad "the refusal must leave the destination alone"

# BOTH `stat` DIALECTS, driven with stubs — this runner is only ever one of them, and the whole
# defect class here is an assertion that speaks for the platform it happened to run on. The GNU
# stub reproduces the real trap: `-f` is --file-system, takes no format argument, and still PRINTS
# a block for the file while exiting non-zero, so a BSD-first `A || B` captures that text.
mkdir -p "$work/statbin"
printf '{"a":1}\n' > "$pub_dir/modeprobe.json"   # its own fixture: the refusal above removes its temp
cat > "$work/statbin/stat" <<'GNUSTAT'
#!/bin/sh
deref=no
[ "$1" = "-L" ] && { deref=yes; shift; }
case "$1" in
  -c) [ "$2" = "%a" ] && { [ "$deref" = yes ] && printf '600
' || printf '777\n'; exit 0; }; exit 1 ;;
  -f) printf '  File: "x"
    ID: 99 Namelen: 255 Type: tmpfs
'; exit 1 ;;
esac
exit 1
GNUSTAT
chmod +x "$work/statbin/stat"
gnumode="$(PATH="$work/statbin:$PATH" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"; adb_file_mode "'"$pub_dir"'/modeprobe.json" 2>/dev/null')"
[ "$gnumode" = "600" ] && ok || bad "adb_file_mode must read the DEREFERENCED mode under GNU stat (where -f prints a filesystem block and exits non-zero); got '$gnumode'"
cat > "$work/statbin/stat" <<'BSDSTAT'
#!/bin/sh
deref=no
[ "$1" = "-L" ] && { deref=yes; shift; }
case "$1" in
  -f) [ "$2" = "%Lp" ] && { [ "$deref" = yes ] && printf '600
' || printf '777\n'; exit 0; }; exit 1 ;;
  -c) printf 'stat: illegal option -- c
' >&2; exit 1 ;;
esac
exit 1
BSDSTAT
chmod +x "$work/statbin/stat"
bsdmode="$(PATH="$work/statbin:$PATH" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"; adb_file_mode "'"$pub_dir"'/modeprobe.json" 2>/dev/null')"
[ "$bsdmode" = "600" ] && ok || bad "adb_file_mode must read the DEREFERENCED mode under BSD stat (where -c is an illegal option); got '$bsdmode'"

# A SYMLINK'S OWN MODE IS NOT ITS TARGET'S. Without `-L`, `stat` reports the link (measured 755 on
# macOS, 777 on Linux) — so a settings.json that is a symlink to a restricted file would have had
# that mode stamped onto the regular file replacing it: world-readable, and on Linux world-WRITABLE.
printf '{"a":1}\n' > "$pub_dir/symtarget.json"; chmod 600 "$pub_dir/symtarget.json"
ln -sf "$pub_dir/symtarget.json" "$pub_dir/symlink.json"
symmode="$(adb_file_mode "$pub_dir/symlink.json")"
[ "$symmode" = "600" ] && ok || bad "adb_file_mode must read the DEREFERENCED mode through a symlink (the target's, not the link's own); got '$symmode'"

printf '{"a":1}\n' > "$pub_dir/real.json"; chmod 600 "$pub_dir/real.json"
printf '{"a":2}\n' > "$pub_dir/tmp2.json"; chmod 644 "$pub_dir/tmp2.json"
adb_publish_json "$pub_dir/tmp2.json" "$pub_dir/real.json" && ok || bad "adb_publish_json must publish over a regular file"
# Through the shared helper, not a hand-rolled `stat`: GNU reads `-f` as --file-system and still
# PRINTS a filesystem block for the file while exiting non-zero, so a BSD-first `A || B` captures
# that text with the octal mode buried in it. This assertion was written that way and was green on
# macOS and red on ubuntu — the same platform-divergent-test class as the greps above.
pubmode="$(adb_file_mode "$pub_dir/real.json")"
[ "$pubmode" = "600" ] && ok || bad "adb_publish_json must preserve the destination's mode (settings.json can hold an env block); got $pubmode"

# ...and end to end: a mode-0600 settings.json must survive a real install with its mode intact.
mode_home="$work/modehome"; mkdir -p "$mode_home/.claude"
echo '{"model":"opus"}' > "$mode_home/.claude/settings.json"; chmod 600 "$mode_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$mode_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
emode="$(adb_file_mode "$mode_home/.claude/settings.json")"
[ "$emode" = "600" ] && ok || bad "install.sh must not relax a restricted ~/.claude/settings.json to the umask default; got $emode"

# --- the headline cannot overstate, because the contract will not let it ------------------------
#
# Under all-or-nothing a `write` verdict means every shipped leaf was applied — anything already
# there would have refused the lot — so the headline is true by construction rather than by a
# check. What must still be right is that a refusal SAYS so, and names what is in the way.
headline() {   # headline <settings-json> -> the sandbox line and its first continuation
  local h="$work/hl"; rm -rf "$h"; mkdir -p "$h/.claude"
  printf '%s\n' "$1" > "$h/.claude/settings.json"
  HOME="$h" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks 2>&1 \
    | grep -E '^  sandbox |^           ' | head -2
}
stub "2.1.259 (Claude Code)"
case "$(headline '{"model":"opus"}')" in
  *"least-privilege settings applied"*) ok ;;
  *) bad "a clean install must report least-privilege settings applied" ;;
esac
case "$(headline '{"sandbox":{"credentials":{"files":[]}}}')" in
  *"NOT written"*"sandbox.credentials.files"*) ok ;;
  *) bad "a pre-existing leaf of ours must be reported as NOT written and named — never as protection applied" ;;
esac
case "$(headline '{"sandbox":{"enabled":false}}')" in
  *"NOT written"*"sandbox.enabled"*) ok ;;
  *) bad "an operator who disabled the sandbox must be told the fragment was not written, and why" ;;
esac
case "$(headline "$(jq -c . "$PAYLOAD")")" in
  *"NOT written"*) ok ;;
  *) bad "an operator who already set our exact values owns them; the install must refuse rather than claim them" ;;
esac

# --- the ownership receipt is a precondition, not an afterthought --------------------------------
# Settings without a receipt are keys nobody can prove are ours; the next install reads them as the
# operator's and records nothing, after which uninstall can never remove them. So a receipt that
# cannot be published means nothing is written at all.
ro_home="$work/rohome"; mkdir -p "$ro_home/.claude"
echo '{"model":"opus"}' > "$ro_home/.claude/settings.json"
mkdir -p "$ro_home/.claude/.adb-settings-owned"     # a directory: the receipt can never be published here
HOME="$ro_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/ro.log" 2>&1
jq -e '.sandbox == null' "$ro_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "install.sh must write NO sandbox key when the ownership receipt cannot be published — unremovable keys are worse than none"
# REFUSED BEFORE WRITING, not written-and-undone. The rollback below is the backstop for a publish
# that fails unexpectedly; an unpublishable receipt PATH is knowable up front, and a run that
# reached the rollback did work it never needed to do.
grep -qi "not a regular file" "$work/ro.log" && ok \
  || bad "an unpublishable receipt PATH must be refused up front, naming the reason"
grep -qi "ROLLED BACK" "$work/ro.log" && bad "the receipt precheck must refuse BEFORE writing, not write and roll back" || ok

# --- an EXPLICIT null, and a non-object ANCESTOR, BLOCK the install ------------------------------
#
# `getpath` answers null for a missing path AND for one whose value really is null, and it RAISES
# through a scalar — `{"a":false} | getpath(["a","b"])` is a jq error. Under all-or-nothing both
# shapes are the same answer: the operator has something there, so the fragment does not apply.
r="$(m '{"sandbox":{"enabled":null}}' "$work/empty-receipt")"
[ "$(verdict "$r")" = refuse ] && ok || bad "an explicit null is a value the operator chose and must block the install"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = null ] && ok || bad "an explicit null must not be overwritten"

for anc in 'false' '5' '"str"' '[1]' 'null'; do
  printf '{"sandbox":{"credentials":%s}}\n' "$anc" > "$work/anc.json"
  r="$(m "$(cat "$work/anc.json")" "$work/empty-receipt")" \
    || { bad "a credentials ancestor of $anc must not fail the merge — getpath raises through a scalar"; continue; }
  [ "$(verdict "$r")" = refuse ] && ok || bad "a credentials ancestor of $anc must block the install; verdict $(verdict "$r")"
  [ "$(printf '%s' "$r" | jq -r '.wrote | length')" = 0 ] && ok || bad "a blocked install must write nothing (ancestor $anc)"
done
# ...and removal classifies the same shapes instead of failing.
r="$(m '{"sandbox":{"credentials":false}}' "$work/installed-receipt" --remove)" \
  && ok || bad "removal must not fail on a non-object ancestor"

# --- the settings root must be an OBJECT, not merely valid JSON ---------------------------------
#
# `// {}` is false for `null` AND for `false`, so either root coerced to an empty object and the
# whole file was replaced by the merge rather than refused.
for root in 'null' 'false' '"a string"' '[1,2]' '42'; do
  printf '%s\n' "$root" > "$work/root.json"
  if adb_claude_settings_merge "$work/root.json" "$PAYLOAD" "$work/empty-receipt" >/dev/null 2>&1
  then bad "a settings root of $root must be REFUSED — it is valid JSON and is not an object"
  else ok; fi
done

# --- removal ignores the payload ENTIRELY, not just a missing one --------------------------------
#
# Ownership lives in the receipt and `--remove` writes nothing, so a payload that exists but is
# truncated must not reach the merge and strand every receipt-owned key.
printf '{"sandbox":' > "$work/truncated-payload.json"
r="$(adb_claude_settings_merge "$work/installed.json" "$work/truncated-payload.json" "$work/installed-receipt" --remove)" \
  && ok || bad "removal must ignore an unparseable payload — ownership is the receipt's, and removal writes nothing"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 4 ] && ok \
  || bad "removal with an unparseable payload must still remove every receipt-owned leaf"

# --- settings.json must hold EXACTLY ONE top-level value -----------------------------------------
#
# `--slurpfile` reads a STREAM, so an object followed by an appended one slurps two and `$cur[0]`
# published the first — silently discarding every later value instead of refusing.
printf '{"model":"opus"}{"appended":1}\n' > "$work/multi.json"
if adb_claude_settings_merge "$work/multi.json" "$PAYLOAD" "$work/empty-receipt" >/dev/null 2>&1
then bad "a settings.json holding more than one top-level JSON value must be REFUSED, not silently truncated to the first"
else ok; fi

# --- a stale leaf is reconciled BEFORE the new paths are evaluated -------------------------------
#
# When a payload turns an owned leaf into a container or back, evaluating the new paths first sees
# the leftover object, calls it present-but-unowned and skips it; the stale prune then removes the
# old leaf and the replacement is never written — while the receipt records the new digest, so
# nothing retries.
printf '{"x": 5}\n' > "$work/typechange-payload.json"
printf '{"x": {"y": 1}, "keep": "mine"}\n' > "$work/typechange.json"
{ printf 'disposition installed\nversion 9.9.9\nfloor %s\npayload -\n' "$FLOOR"
  printf 'leaf%s["x","y"]%s1\n' "$ADB_TAB" "$ADB_TAB"
  # THE CONTAINER MATTERS HERE: `x` exists only because a previous install made it, so it must be
  # recorded as ours — otherwise the very container we created blocks the replacement.
  printf 'container%s["x"]\n' "$ADB_TAB"; } > "$work/typechange-receipt"
r="$(adb_claude_settings_merge "$work/typechange.json" "$work/typechange-payload.json" "$work/typechange-receipt")"
[ "$(printf '%s' "$r" | jq -r '.settings.x')" = 5 ] && ok \
  || bad "an owned leaf whose ancestor becomes a scalar must be reconciled first, so the replacement is written; got $(printf '%s' "$r" | jq -c '.settings')"
[ "$(printf '%s' "$r" | jq -r '.settings.keep')" = "mine" ] && ok || bad "the reconciliation must not disturb an unrelated sibling"

# --- a REFUSAL relinquishes the surface: a blocked receipt owns NOTHING --------------------------
#
# Under all-or-nothing a divergence means the operator has taken the keys over. Carrying the rows
# into the blocked receipt would let a later uninstall delete a value they re-added by hand — the
# tombstone hazard returning through a different door.
{ printf 'disposition skipped-blocked\nversion 9.9.9\nfloor %s\npayload %s\n' "$FLOOR" "$(adb_sha256 "$PAYLOAD")"
  grep -E "^(leaf|container)$ADB_TAB" "$work/installed-receipt"; } > "$work/blocked-receipt"
r="$(m "$(cat "$work/installed.json")" "$work/blocked-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 0 ] && ok \
  || bad "a blocked receipt must own NOTHING — a refusal relinquishes the surface, and claiming it lets uninstall delete a value the operator re-added"

# --- the created-container cleanup is guarded like the leaf reads --------------------------------
#
# `getpath` raises through a scalar, and this loop is the sibling of the leaf reads that learned it
# two rounds earlier. A recorded child container under an ancestor the operator replaced with
# `false` killed the whole removal pass.
r="$(m '{"model":"opus","sandbox":false}' "$work/installed-receipt" --remove)" \
  && ok || bad "removal must not fail when a recorded container sits under a scalar ancestor"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox')" = false ] && ok \
  || bad "the operator's scalar must survive that removal untouched"
# ...AND A CONTAINER RECORDED DEEPER THAN THE SCALAR. `present` reads one level up, so for a
# two-deep path it is itself safe; only the ancestor walk saves a THREE-deep container whose
# grandparent is a scalar. Without that case the two guards cover each other and neither can be
# shown to matter.
{ cat "$work/installed-receipt"; printf 'container%s["sandbox","credentials","deep"]\n' "$ADB_TAB"; } > "$work/deep-receipt"
r="$(m '{"model":"opus","sandbox":false}' "$work/deep-receipt" --remove)" \
  && ok || bad "removal must not fail when a recorded container is DEEPER than the scalar that blocks the walk"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox')" = false ] && ok \
  || bad "the operator's scalar must survive the deep-container removal untouched"

# --- provenance survives the root-doc unlink ----------------------------------------------------
#
# `uninstall_claude` removes the root-doc link BEFORE the settings cleanup can fail, so a cleanup
# that could not run leaves a receipt whose live proof is gone — and the retry it tells the
# operator to make would refuse its own settings as another clone's.
[ -n "$(adb_claude_settings_source_row "$ROOT")" ] && ok || bad "an ordinary clone path must be recordable as a source"
[ -z "$(adb_claude_settings_source_row "$(printf '/a\tb')")" ] && ok || bad "a source path containing a TAB must be refused — the receipt is tab-delimited"
[ -z "$(adb_claude_settings_source_row "$(printf '/a\nb')")" ] && ok \
  || bad "a source path containing a NEWLINE must be refused — a truncated path resolves to a real sibling"

# --- one run at a time per HOME, across the whole read-to-publish window -------------------------
#
# The settings and the receipt are published by two separate renames, and distinct temp names do
# not make the pair atomic: a normal install and a concurrent `--no-sandbox` can both read the old
# state, and if the opt-out publishes its ownership-free receipt LAST the keys the other run just
# applied are left unowned — both commands report success and uninstall can never remove them.
lk_home="$work/lockhome"; rm -rf "$lk_home"; mkdir -p "$lk_home/.claude"
echo '{"model":"opus"}' > "$lk_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$lk_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ -e "$lk_home/.claude/.adb-settings.lock" ] && bad "the settings lock must be released on the success path" || ok
# A LIVE holder refuses rather than racing. `$$` is this suite, which is alive by construction.
mkdir -p "$lk_home/.claude/.adb-settings.lock"
printf '%s %s\n' "$$" "$(date +%s)" > "$lk_home/.claude/.adb-settings.lock/owner"
HOME="$lk_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/lock.log" 2>&1
grep -qi "another install or uninstall is writing" "$work/lock.log" && ok \
  || bad "a live settings lock must refuse the run and name the lock, not publish over it"
rm -rf "$lk_home/.claude/.adb-settings.lock"
# ...and every documented non-writing path releases it too, since they all return from inside.
for arg in "--no-sandbox" ""; do
  HOME="$lk_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks $arg >/dev/null 2>&1
  [ -e "$lk_home/.claude/.adb-settings.lock" ] && bad "the settings lock must be released after '$arg'" || ok
done
HOME="$lk_home" PATH="/usr/bin:/bin" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ -e "$lk_home/.claude/.adb-settings.lock" ] && bad "the settings lock must be released after an unprobeable-CLI skip" || ok

# --- the lock covers EVERY writer of settings.json, not just the sandbox half --------------------
#
# `wire_hooks` writes the same file. A lock around the sandbox half alone let a delayed hook rename
# overwrite a locked peer's keys — and the next merge read that absence as operator divergence,
# recorded `skipped-blocked`, and both installs exited successfully with the protections gone.
lk2="$work/lockall"; rm -rf "$lk2"; mkdir -p "$lk2/.claude"
echo '{"model":"opus"}' > "$lk2/.claude/settings.json"
stub "2.1.259 (Claude Code)"
mkdir -p "$(adb_settings_lock_path "$lk2")"
printf '%s %s\n' "$$" "$(date +%s)" > "$(adb_settings_lock_path "$lk2")/owner"
HOME="$lk2" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude >"$work/lockall.log" 2>&1
grep -qi "nothing was changed" "$work/lockall.log" && ok \
  || bad "a live settings lock must block the HOOK writer too — it writes the same file"
jq -e '.hooks == null' "$lk2/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and nothing may be written to settings.json while the lock is held"
rm -rf "$(adb_settings_lock_path "$lk2")"
# uninstall contends for the same lock
HOME="$lk2" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude >/dev/null 2>&1
mkdir -p "$(adb_settings_lock_path "$lk2")"
printf '%s %s\n' "$$" "$(date +%s)" > "$(adb_settings_lock_path "$lk2")/owner"
HOME="$lk2" bash "$ROOT/uninstall.sh" --agent claude >"$work/unlockall.log" 2>&1
jq -e '.sandbox.enabled == true' "$lk2/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "uninstall must take the same lock and remove nothing while an install holds it"
rm -rf "$(adb_settings_lock_path "$lk2")"

# --- the lock precedes the RELINK, and is released on every exit ---------------------------------
#
# Ownership of the settings surface is decided by the root-doc link, and `adb_link_manifest`
# REPLACES it — so two overlapping installs could each relink before contending for the lock,
# leaving the loser's replacements in place while the winner observed a changed root link and
# refused its own settings write.
pre_home="$work/prelink"; rm -rf "$pre_home"; mkdir -p "$pre_home/.claude"
mkdir -p "$(adb_settings_lock_path "$pre_home")"
printf '%s %s\n' "$$" "$(date +%s)" > "$(adb_settings_lock_path "$pre_home")/owner"
stub "2.1.259 (Claude Code)"
HOME="$pre_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude >"$work/prelink.log" 2>&1
[ -e "$pre_home/.claude/CLAUDE.md" ] && bad "a held lock must be taken BEFORE the links are replaced — the root-doc link is what decides ownership" || ok
grep -qi "nothing was changed" "$work/prelink.log" && ok || bad "...and the refusal must say that nothing was changed"
rm -rf "$(adb_settings_lock_path "$pre_home")"

# EVERY EXIT RELEASES IT. A lock left behind refuses every later install and uninstall for the
# stale interval, or longer if the recorded pid is reused — so the release cannot sit only on the
# happy path.
rel_home="$work/release"; rm -rf "$rel_home"; mkdir -p "$rel_home/.claude"
echo '{"model":"opus"}' > "$rel_home/.claude/settings.json"
for variant in "--no-hooks" "--no-hooks --no-sandbox" ""; do
  HOME="$rel_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude $variant >/dev/null 2>&1
  [ -e "$(adb_settings_lock_path "$rel_home")" ] && bad "the lock must be released after install '$variant'" || ok
done
HOME="$rel_home" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
[ -e "$(adb_settings_lock_path "$rel_home")" ] && bad "the lock must be released after uninstall" || ok
# ...including the refusal path, where the body never runs at all.
nl_home="$work/nlrelease"$'\n'"shadow"; rm -rf "$nl_home"; mkdir -p "$nl_home/.claude"
HOME="$nl_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude >/dev/null 2>&1
[ -e "$(adb_settings_lock_path "$nl_home")" ] && bad "the lock must be released when the manifest itself is refused" || ok

# --- the carry diagnostics reach the OPERATOR, not the row capture -------------------------------
#
# `_adb_carry_rows` returns its rows on stdout and is called inside `$( )`, so an `adb_info` line
# there was captured into the caller's variable and then silently filtered by the receipt renderer.
# Every "ownership relinquished" and "carried unverified" message was invisible.
diag_home="$work/diag"; rm -rf "$diag_home"; mkdir -p "$diag_home/.claude"
echo '{"model":"opus"}' > "$diag_home/.claude/settings.json"
HOME="$diag_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
jq 'del(.sandbox.enabled)' "$diag_home/.claude/settings.json" > "$work/dg.json" && mv "$work/dg.json" "$diag_home/.claude/settings.json"
HOME="$diag_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/diag.log" 2>&1
grep -qi "relinquish" "$work/diag.log" && ok \
  || bad "the operator must be TOLD that ownership was relinquished — the message is the only signal that a safety-relevant state changed"
[ "$(grep -c "^leaf$ADB_TAB" "$diag_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "...and the rows must still be dropped"
# EVERY diagnostic in that function, not only the one the fixture above happens to reach. The
# behavioural check proves one message escapes the capture; a diagnostic added later without `>&2`
# would be swallowed exactly as these five were, and nothing would say so. The set is closed and
# enumerable, so it is asserted rather than trusted.
[ "$(awk '/^_adb_carry_rows\(\) \{/{i=1} i && /adb_info/ && !/>&2$/{n++} i && /^}/{exit} END{print n+0}' \
     "$ROOT/install.sh")" -eq 0 ] && ok \
  || bad "every adb_info inside _adb_carry_rows must redirect to stderr — its stdout is its return value, so a diagnostic there is captured into the caller's rows and dropped"

# --- the merge's absence rule has exactly ONE spelling ---------------------------------------------
#
# `def present` is pinned by a mutation row. A second copy defined EARLIER in common.sh was matched
# first by that row, which silently stopped testing the merge and reported green — the guard was
# disarmed by a duplicate, not by an edit to the thing it guards.
[ "$(grep -c 'def present(\$p)' "$ROOT/scripts/lib/common.sh")" -eq 1 ] && ok \
  || bad "common.sh must define \`present\` exactly once — a second copy is matched first by the mutation row pinning the merge's, disarming it"

# --- an UNREADABLE receipt is not an absent one ---------------------------------------------------
#
# `-f` is true for a file with mode 000 or a denying ACL, so a receipt that exists and cannot be
# read reported disposition `none`; the owned-rows readers answered `[]`, the remove pass pruned
# nothing, and uninstall published the unchanged settings, DELETED the receipt and reported
# success. Every sandbox key stayed installed with nothing left able to remove them — permanent,
# silent, and reported as a clean uninstall. `status-swallowed`.
unread="$work/unreadable"; rm -rf "$unread"; mkdir -p "$unread/.claude"
echo '{"model":"opus"}' > "$unread/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$unread" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
chmod 000 "$unread/.claude/.adb-settings-owned"
HOME="$unread" bash "$ROOT/uninstall.sh" --agent claude >"$work/unread.log" 2>&1 && \
  bad "an uninstall that could not read the ownership receipt must FAIL, not report success" || ok
[ -f "$unread/.claude/.adb-settings-owned" ] && ok \
  || bad "...and must KEEP the receipt — it is the only thing that can prove which keys are ours"
jq -e '.sandbox.enabled == true' "$unread/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and must not have half-removed the keys it could not prove ownership of"
grep -qi "cannot be read" "$work/unread.log" && ok \
  || bad "...and must say the RECEIPT could not be read"
# ...and it refuses BEFORE anything is unlinked, because the root-doc link may be that receipt's
# only proof and this run cannot tell. Warning and carrying on removed the proof and then relied on
# the settings cleanup to succeed — which is the retryable failure the stamp exists to survive.
[ -L "$unread/.claude/CLAUDE.md" ] && ok \
  || bad "...and must unlink NOTHING: the link may be that receipt's only proof of ownership, and this run cannot tell"
grep -qi "settings.json could not be read as a single JSON value" "$work/unread.log" && \
  bad "...and must not blame settings.json — that is a different failure with a different remedy" || ok
# ...and the retry works once it is readable again, which is what makes the refusal a hold and not a wall.
chmod 600 "$unread/.claude/.adb-settings-owned"
HOME="$unread" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1 && ok \
  || bad "the retry must succeed once the receipt is readable"
jq -e '.sandbox == null' "$unread/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and must then remove the keys it held on to"

# --- an unreadable receipt is refused by the ROW reader too, not only by the disposition ----------
#
# `_adb_owned_rows` answered zero rows for a receipt it could not open, and zero rows is a
# legitimate answer — so an established opt-out or version skip published a readable,
# OWNERSHIP-FREE receipt over it while every sandbox key stayed installed. Measured before the fix:
# 4 leaf rows became 0 and the keys became permanently unremovable.
ur="$work/unreadrows"; rm -rf "$ur"; mkdir -p "$ur/.claude"
echo '{"model":"opus"}' > "$ur/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$ur" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
ur_before="$(grep -c "^leaf$ADB_TAB" "$ur/.claude/.adb-settings-owned")"
[ "$ur_before" -gt 0 ] && ok || bad "precondition: the fixture must have owned rows to lose"
chmod 000 "$ur/.claude/.adb-settings-owned"
HOME="$ur" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/ur.log" 2>&1 && \
  bad "an opt-out over a receipt that could not be READ must fail, not publish an ownership-free replacement" || ok
stub "2.1.100 (Claude Code)"
HOME="$ur" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/ur2.log" 2>&1 && \
  bad "a version skip over an unreadable receipt must fail for the same reason" || ok
chmod 600 "$ur/.claude/.adb-settings-owned"
[ "$(grep -c "^leaf$ADB_TAB" "$ur/.claude/.adb-settings-owned")" -eq "$ur_before" ] && ok \
  || bad "...and every owned row must survive both attempts"
# ...while a receipt that is merely ABSENT, or a path occupied by something that is not a file, is
# zero rows and goes on to fail at the publish and SAY so. Only a regular file can hold rows.

# --- a damaged disposition is not `none` either ---------------------------------------------------
#
# The unreadable case had a twin: a receipt that reads fine but whose `disposition` line is missing
# or unrecognised. `none` means "nobody has written a receipt", and every reader turns that into
# zero owned rows — so uninstall pruned nothing, published the unchanged settings, deleted the last
# record of which keys were ours and reported success.
dd="$work/damaged"; rm -rf "$dd"; mkdir -p "$dd/.claude"
echo '{"model":"opus"}' > "$dd/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$dd" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
grep -v '^disposition' "$dd/.claude/.adb-settings-owned" > "$work/dd.tmp" && mv "$work/dd.tmp" "$dd/.claude/.adb-settings-owned"
HOME="$dd" bash "$ROOT/uninstall.sh" --agent claude >"$work/dd.log" 2>&1 && \
  bad "an uninstall against a receipt whose disposition is damaged must FAIL, not report success" || ok
[ -f "$dd/.claude/.adb-settings-owned" ] && ok \
  || bad "...and must KEEP it — its leaf rows are the only record of which keys are ours"
jq -e '.sandbox.enabled == true' "$dd/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and must leave the keys it could not prove ownership of alone"
# DAMAGED AND UNREADABLE ARE DIFFERENT REMEDIES, so they are different messages. Sending an
# operator to fix permissions on a file that is already readable wastes the one hint they get.
grep -qi "disposition" "$work/dd.log" && ok \
  || bad "...and must name the damaged disposition line, not send the operator to fix permissions"
grep -qi "could not be READ" "$work/dd.log" && \
  bad "...and must not report a readable-but-damaged receipt as unreadable" || ok
grep -qi "cannot be read" "$work/unread.log" && ok \
  || bad "...while a genuinely unreadable one must still say exactly that"

# --- the lock is the OWNER FILE, so a write that fails is an acquisition that failed --------------
#
# `mkdir` succeeded and the owner write did not, and the unchecked redirection returned success:
# the run proceeded believing it held the lock, while `adb_update_unlock` found no token matching
# its own and deliberately left the DIRECTORY behind. Every later settings operation was then
# refused until the stale interval elapsed. A full filesystem, a quota or an ACL is enough; the
# fixture uses a umask that makes the new directory unwritable, which needs no privileges.
lo="$work/lockowner"; rm -rf "$lo"; mkdir -p "$lo"
( umask 777; _adb_take_lock "$lo/lk" ) 2>/dev/null && \
  bad "taking the lock must FAIL when its owner file cannot be written — the token is the lock" || ok
[ -e "$lo/lk" ] && \
  bad "...and must not leave the directory behind: it can never be released, so it refuses every later run" || ok

# --- a signal may not land BETWEEN the two publications -------------------------------------------
#
# The settings and the receipt are published separately. The armed handlers release the lock and
# exit immediately — right everywhere else, and here it would leave the new sandbox values
# installed with no ownership record AND skip the rollback, which is worse than the interruption it
# handles. Deferred, not ignored: the signal is honoured the moment the pair is complete.
sd="$work/deferhome"; rm -rf "$sd"; mkdir -p "$sd/.claude"
rm -f "$work/defer.after" "$work/defer.past"
HOME="$sd" bash -c '
  . "'"$ROOT"'/scripts/lib/common.sh"
  adb_settings_lock_take || exit 9
  adb_settings_lock_defer_signals
  kill -TERM $$
  : > "'"$work"'/defer.after"
  adb_settings_lock_resume_signals
  : > "'"$work"'/defer.past"
'
sd_rc=$?
[ -f "$work/defer.after" ] && ok \
  || bad "a signal arriving mid-transaction must be DEFERRED — the second publication has to complete"
[ -f "$work/defer.past" ] && \
  bad "...and must then be honoured, not swallowed: nothing after the resume may run" || ok
[ "$sd_rc" -eq 143 ] && ok || bad "...and must exit with the signal's own status (got $sd_rc)"
[ -e "$(adb_settings_lock_path "$sd")" ] && \
  bad "...and must still release the lock on its way out" || ok

# --- a no-jq provenance refresh that could not publish is not a tolerated skip --------------------
#
# 3 means "no jq, nothing was written, come back later", which is true of the settings and false of
# the ownership proof: when clone B takes over from clone A without jq and the refresh fails, B's
# root link is paired with a receipt naming A. Uninstalling from B then removes the link and stops,
# and the retry it advises refuses the settings as A's.
#
# A STRUCTURAL PIN, and the reason is the same one that forced the others in this file — stated
# once here because it keeps recurring: the lock, the receipt and the receipt's temp file all live
# in ~/.claude, so every way of making the receipt publish fail (an unwritable directory) fails the
# LOCK's mkdir first and the run refuses before it reaches this branch at all. A fixture that tries
# anyway does not exercise it; it exits 1 somewhere else and passes for the wrong reason, which is
# how the first version of this guard was written and why it is not written that way now.
awk '/uninstall from that clone instead/{f=1} f && /^        return 1   # provenance-broken$/{print "fails"; exit} f && /return 3/{exit}' \
  "$ROOT/install.sh" | grep -q fails && ok \
  || bad "a provenance refresh that could not be published must FAIL, not return the tolerated no-jq skip — the root link names this clone while the receipt names another, and that pairing is what a later uninstall depends on"
grep -qF 'NOT THE TOLERATED SKIP' "$ROOT/install.sh" && ok \
  || bad "...and must say why it is not the ordinary no-jq case"

# --- the OTHER transactions defer too --------------------------------------------------------------
#
# Three more pairs of durable writes were outside the deferral the write path got: the refusal that
# also prunes a retired key (settings, then a receipt that stops claiming it), the uninstall side
# (settings, then the receipt is deleted), and the hook wiring (entries, then their receipt). Each
# leaves a receipt describing a state the file no longer has.
#
# Driven on the MECHANISM rather than by racing a signal into each branch: the library call is what
# every one of them shares, and it is proven above to hold a signal and honour it at the boundary.
# What is asserted per site is that the branch is inside a deferral at all — see the pins below.
# PINNED ON THE CODE, NOT ON THE COMMENT. The first version of these three greps matched the
# explanatory comment above each deferral — so deleting the `adb_settings_lock_defer_signals` call
# and leaving the prose would have kept them green, which is the failure mode this file has already
# recorded once. What each asserts now is the ORDER: the deferral is reached before the first
# durable write of its pair.
awk '/retired="\$\(_adb_result_field/{f=1}
     f && /adb_settings_lock_defer_signals/{print "ok"; exit}
     f && /adb_publish_json "\$rtmp2" "\$settings"/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the refusal-that-prunes branch must defer signals BEFORE it publishes the pruned settings — the receipt that stops claiming the retired leaf is its second write"
awk '/^unwire_settings\(\)/{f=1}
     f && /adb_settings_lock_defer_signals/{print "ok"; exit}
     f && /adb_publish_json "\$tmp" "\$settings"/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "uninstall must defer signals BEFORE it publishes the rewritten settings — the receipt removal is its second write"
awk '/^wire_hooks\(\)/{f=1}
     f && /adb_settings_lock_defer_signals/{print "ok"; exit}
     f && /adb_publish_json "\$tmp" "\$settings"/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the hook wiring must defer signals BEFORE it publishes settings.json — its wiring receipt is the second write of the pair"
# ...and the prune-abort path, which returns from the middle of the transaction, must resume.
awk '/return 1   # prune-abort/{if (prev !~ /adb_settings_lock_resume_signals/) {print "leaked"; exit}} {prev=$0}' \
  "$ROOT/install.sh" | grep -q leaked && \
  bad "the prune-abort return sits inside the deferral — it must resume on the way out or the signal is held for the rest of the run" || ok

# --- an OPERATIONAL failure is never a semantic answer ------------------------------------------------
#
# The class this suite has now met at nine sites: a command substitution or a predicate whose
# failure is indistinguishable from a legitimate result. `jq -e` is the sharpest case — it answers
# **1 for false and 5 for an error**, and code that tests only "non-zero" reads a dead process as a
# considered "no".
#
# Each of these is one site where that difference decides whether ownership survives.
awk '/^_adb_carry_rows\(\)/{f=1}
     f && /if ! proved="\$\(printf/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the pruned-count read must be checked before it is normalised — an empty value normalises to 0, which reads as every recorded key having diverged and publishes a rowless receipt"
awk '/^_adb_report_settings\(\)/{f=1}
     f && /if ! names="\$\(printf/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the bucket reporter must distinguish an empty bucket from a failed read — on the refusal path its `kept` line is the last thing that ever names an edited obsolete key"
# ALL THREE ROW PREDICATES — two in the leaves reader, one in the containers reader. The third was
# missed on the first pass and found only because this count is over the file rather than over one
# function.
[ "$(grep -c 'case $? in 0) ;; 1) continue ;; \*) return 20 ;; esac' "$ROOT/scripts/lib/common.sh")" -eq 3 ] && ok \
  || bad "every row predicate must treat jq's 1 (false) and its 5 (error) differently — conflating them drops a valid row, so the merge owns fewer leaves and uninstall leaves the live key behind"
[ "$(grep -c "jq -e 'type == \"array\" and length > 0 and all(.\[\]; type == \"string\")' >/dev/null 2>&1 || continue" "$ROOT/scripts/lib/common.sh")" -eq 0 ] && ok \
  || bad "...and none may still be spelled with a bare \`|| continue\`, which is the conflation itself"
awk '/^unwire_settings\(\)/{f=1}
     f && /\[ "\$_nochange" -gt 1 \]/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "the no-op comparison must tell an execution error from an inequality — treating both as a difference republishes an unchanged document, which turns a settings.json symlink into a regular file"
awk '/_lrkept="\$\(printf/{f=1}
     f && /\[ "\$_grc" -gt 1 \]/{print "ok"; exit}
     f && /adb_publish_json/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "the legacy filter must be run and checked on its own — inside a brace group its status is discarded, so a failed grep publishes a receipt with every leaf row destroyed"
# ...and the currency wrapper, which cannot tell the two downgrade cases apart and must therefore
# not promise the one that is sometimes false.
grep -q "if the sandbox keys are still in settings.json afterwards they are no longer owned" \
  "$ROOT/scripts/lib/currency-lib.sh" && ok \
  || bad "the exit-9 message must hold whether or not ownership was also relinquished: this wrapper discards baseline's output by design and reads only the exit code, so it cannot detect the mixed case"
awk '/^    9\)/{f=1} f && /\$out/{print "bad"; exit} f && /^    5\)/{exit}' \
  "$ROOT/scripts/lib/currency-lib.sh" | grep -q bad && \
  bad "...and must not reach for baseline's prose to find out: the outcome contract here is the EXIT CODE, and \$out is not in scope in that arm" || ok

# --- the merge result is read through ONE checked reader --------------------------------------------
#
# Every field here decides something: the verdict picks the branch, the counts gate messages, the
# names are the operator's only record. A command substitution turns a failed `jq` into an EMPTY
# STRING that reads as a legitimate answer — and an empty verdict fell through to the WRITE path
# over a refusing merge, publishing an `installed` receipt with no rows and the current digest, so
# no later update ever retried the policy.
grep -q '_adb_result_field() {' "$ROOT/install.sh" && ok \
  || bad "the merge result must be read through one checked helper, not by unchecked command substitution at each site"
# EVERY FIELD THROUGH THE HELPER. Counted as call sites rather than by hunting the old spelling: an
# unchecked read left beside the helper is precisely the defect the helper exists to remove.
[ "$(grep -c '_adb_result_field "\$result"' "$ROOT/install.sh")" -ge 4 ] && ok \
  || bad "...and every field must go through it — the verdict, the blockers, the diverged count and the retirement list are four separate reads and each one decides something"
grep -qE "jq -r '\.verdict'" "$ROOT/install.sh" && \
  bad "...with no unchecked read left beside it: reading .verdict directly is what let an empty string fall through to the write path" || ok
awk '/verdict="\$\(_adb_result_field/{f=1}
     f && /write\|refuse\|remove\)/{print "ok"; exit}
     f && /if \[ "\$verdict" = refuse \]/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and the verdict must be one of the KNOWN values before the write path is taken — that branch publishes keys and must be chosen, not fallen into"
# ...and the row writer's two path enumerations, which fail the same way one level out.
# BOTH GUARDS, COUNTED, and the pin watches the `|| return 1` rather than the assignment — the
# assignment survives the mutation that deletes the guard, which is how the first version of this
# pin passed over a real defect. Two enumerations, so a count: deleting either one leaves the other
# to answer for it.
[ "$(awk '/^adb_claude_settings_leaf_rows\(\)/{f=1} f && /_paths="\$\(printf/ && /\|\| return 1/{n++} f && /^}/{exit} END{print n+0}' \
     "$ROOT/scripts/lib/common.sh")" -eq 2 ] && ok \
  || bad "both leaf-row enumerations must be captured AND checked before any row is printed — inside the heredoc a failed jq walks zero paths and the writer still returns 0"

# --- and so is EACH LEAF VALUE, one level down -------------------------------------------------------
#
# The arrays were fixed one level up; each value inside them was still extracted by an unchecked
# command substitution. A `jq` that failed emitted `leaf<TAB><path><TAB>` with an empty value and
# the writer still returned 0 — every reader discards a malformed row, so the written leaf had no
# owner at all: uninstall could not remove it, and the matching payload digest stopped later
# updates from repairing the ownership.
lv="$work/leafvalue"; rm -rf "$lv"; mkdir -p "$lv"
echo '{"sandbox":{"enabled":true}}' > "$lv/payload.json"
lv_out="$(adb_claude_settings_leaf_rows "$lv/payload.json" '[["sandbox","enabled"]]')"
[ "$lv_out" = "leaf${ADB_TAB}[\"sandbox\",\"enabled\"]${ADB_TAB}true" ] && ok \
  || bad "a leaf row must carry its value: got [$lv_out]"
# A path the payload does not have is a legitimate `null`, NOT a failure — the check must tell an
# extraction that failed from a value that is legitimately null, or every absent path aborts.
adb_claude_settings_leaf_rows "$lv/payload.json" '[["nope","missing"]]' >/dev/null 2>&1 && ok \
  || bad "a path yielding null must still emit a row — jq prints 'null', which is a value, not a failure"
# ...and the row writer must REFUSE rather than emit an empty value.
awk '/^adb_claude_settings_leaf_rows\(\)/{f=1}
     f && /v="\$\(jq -c --argjson path/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/scripts/lib/common.sh" | grep -q ok && ok \
  || bad "each leaf value must be captured before the row is printed — inline, a failed jq becomes an empty field and the writer still returns 0"
awk '/^adb_claude_settings_leaf_rows\(\)/{f=1}
     f && /\[ -z "\$v" \]/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/scripts/lib/common.sh" | grep -q ok && ok \
  || bad "...and an empty extraction must fail the writer, since that is exactly what the failure looks like"

# --- the merge's decision is read back and CHECKED before anything is published ----------------------
#
# `.wrote` and `.created` were extracted inline, so a `jq` that failed became an EMPTY argument:
# `adb_claude_settings_leaf_rows` emitted fewer rows, or none, and still returned success, which
# `pipefail` cannot catch. For `.wrote` that publishes every sandbox key under a ROWLESS `installed`
# receipt — uninstall cannot remove them and the next install reads them as the operator's.
awk '/local rtmp=/{f=1}
     f && /wrote_json="\$\(printf/{print "ok"; exit}
     f && /adb_claude_settings_receipt_render installed/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the merge's .wrote and .created must be captured before the receipt is rendered — inline, a failed jq becomes an empty argument and the row writer reports success"
# BOTH, counted. Asserting only that SOME array check exists let a mutation delete one of the two
# and stay green — `.wrote` and `.created` are separate reads and either one failing produces the
# same empty string, so one check covers one of them and nothing covers the other.
[ "$(grep -c 'type == "array"' "$ROOT/install.sh")" -eq 2 ] && ok \
  || bad "...and BOTH must be VALIDATED as arrays: an empty string is what either failure looks like, and it renders as a receipt with no rows"

# --- a no-op uninstall stages nothing it leaves behind ------------------------------------------------
#
# The staged file is created before the "nothing of ours is here" comparison, so every cycle that
# removed nothing left a zero-byte `settings.json.adb.<pid>.tmp` in ~/.claude.
nz="$work/nostage"; rm -rf "$nz"; mkdir -p "$nz/.claude"
echo '{"sandbox":{"enabled":false}}' > "$nz/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$nz" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
HOME="$nz" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
[ "$(find "$nz/.claude" -name 'settings.json.adb.*' | wc -l | tr -d ' ')" -eq 0 ] && ok \
  || bad "an uninstall that removed nothing must not leave its staged temp behind — one per cycle accumulates in ~/.claude"

# --- a downgrade outranks a link repair ---------------------------------------------------------------
#
# The reconciliation report is gated on `LINKS_OK` because with a broken link there really was a
# repair, so that line is only a matter of accuracy. A downgrade is not: the protections have
# stopped being applied, and a run that ALSO fixed a link exited 6 and let the wrapper render it as
# repaired links alone. Same rule as the refusal — a security-relevant fact does not wait its turn.
awk '/adb_self_heal && adb_verify_links/{f=1}
     f && /adb_settings_downgraded_now/{print "ok"; exit}
     f && /\[ "\$SETTINGS_PENDING" -eq 1 \] && \[ "\$LINKS_OK" -eq 1 \]/{exit}' \
  "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "the downgrade classification must run BEFORE the LINKS_OK gate — a run that also repaired a link would otherwise report the repair and drop the downgrade"

# --- a refusal names what it is about to stop owning --------------------------------------------------
#
# A leaf we no longer ship that the operator has edited lands in `.kept`. The refusal then writes a
# `skipped-blocked` receipt carrying NO rows, so after that run nothing can identify the key — not a
# later update, not uninstall. The write path and the uninstall path both name this bucket; the
# refusal was the one place that returned without it.
kb="$work/keptblocked"; rm -rf "$kb"; mkdir -p "$kb/.claude"
echo '{"model":"opus"}' > "$kb/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$kb" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
printf 'leaf%s["sandbox","retired"]%s"ours"\n' "$ADB_TAB" "$ADB_TAB" >> "$kb/.claude/.adb-settings-owned"
jq '.sandbox.retired = "EDITED" | .sandbox.enabled = false' "$kb/.claude/settings.json" > "$work/kb.tmp" \
  && mv "$work/kb.tmp" "$kb/.claude/settings.json"
HOME="$kb" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/kb.log" 2>&1
grep -qi "NOT written" "$work/kb.log" && ok \
  || bad "precondition: an edited shipped leaf must make this a refusal"
grep -qi "kept (no longer shipped" "$work/kb.log" && ok \
  || bad "a refusal must NAME the retired leaf it kept — the blocked receipt it is about to write carries no rows, so this line is the last chance anything identifies that key"

# --- a refusal over a SYNTHETIC pre-image writes nothing --------------------------------------------
#
# When settings.json is absent or empty the merge reads a synthetic `{}` — deleting a managed leaf
# is a documented opt-out, so this is a state operators reach on purpose. Comparing the merge's
# output against the REAL path slurps `null`, so every such refusal looked like a change and the
# branch published `{}`: it recreated a file the operator had deleted, and replaced an empty or
# dangling symlink with a regular file.
sy="$work/synthrefusal"; rm -rf "$sy"; mkdir -p "$sy/.claude"
echo '{"model":"opus"}' > "$sy/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$sy" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$sy/.claude/.adb-settings-owned")" -gt 0 ] && ok \
  || bad "precondition: the fixture needs recorded rows, so their absence reads as divergence"
rm -f "$sy/.claude/settings.json"
HOME="$sy" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/sy.log" 2>&1
grep -qi "no longer as this install left them" "$work/sy.log" && ok \
  || bad "precondition: recorded leaves that are gone must read as divergence and refuse"
[ -e "$sy/.claude/settings.json" ] && \
  bad "a refusal must not CREATE settings.json — the merge read a synthetic {}, and comparing its output against the absent path made every such refusal look like a change" || ok
# ...and the same for a DANGLING symlink, which is the other way to reach an empty pre-image. A
# FRESH fixture, because the refusal above recorded a rowless `skipped-blocked` receipt — reusing
# that home would leave nothing to diverge, so the next run takes the WRITE path and replaces the
# link legitimately. The assertion would then fail for a reason that has nothing to do with the rule.
syl="$work/synthsymlink"; rm -rf "$syl"; mkdir -p "$syl/.claude"
echo '{"model":"opus"}' > "$syl/.claude/settings.json"
HOME="$syl" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$syl/.claude/.adb-settings-owned")" -gt 0 ] && ok \
  || bad "precondition: the symlink fixture needs live ownership rows too"
rm -f "$syl/.claude/settings.json"
ln -s "$syl/.claude/nowhere.json" "$syl/.claude/settings.json"
HOME="$syl" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ -L "$syl/.claude/settings.json" ] && ok \
  || bad "...and must leave a dangling settings symlink as a symlink rather than replacing it with a regular file"
[ -e "$syl/.claude/nowhere.json" ] && \
  bad "...and must not create the link's missing target either" || ok

# --- a mode we READ and could not SET is a publication failure ---------------------------------------
#
# The hook writers build their temp under the caller's ordinary umask, so publishing anyway replaces
# a 0600 settings.json with a 0644 one — and that file carries unrelated values, an `env` block
# among them. Failing to READ the mode still proceeds; failing to APPLY one we read does not.
pm="$work/publishmode"; rm -rf "$pm"; mkdir -p "$pm/bin"
printf '%s\n' '{"a":1}' > "$pm/dest.json"; chmod 600 "$pm/dest.json"
printf '%s\n' '{"a":2}' > "$pm/new.json"
cat > "$pm/bin/chmod" <<'PMSTUB'
#!/bin/sh
exit 1
PMSTUB
chmod +x "$pm/bin/chmod"
( PATH="$pm/bin:$PATH"; adb_publish_json "$pm/new.json" "$pm/dest.json" ) >"$work/pm.log" 2>&1 && \
  bad "a chmod that failed on a mode we successfully READ must fail the publication — publishing anyway exposes the destination's contents at the umask default" || ok
[ "$(adb_file_mode "$pm/dest.json")" = "600" ] && ok \
  || bad "...and the destination must be untouched"
[ -e "$pm/new.json" ] && \
  bad "...and the temp must be removed rather than left behind" || ok
grep -qi "could not preserve" "$work/pm.log" && ok \
  || bad "...and the refusal must say what it could not preserve"

# --- the row count is ONE integer, whatever the receipt holds ---------------------------------------
#
# `grep -c` PRINTS the count and EXITS 1 when it is zero, so a `|| printf 0` fallback appended a
# second zero and the function returned "0\n0". The caller compares it arithmetically, so a rowless
# receipt made the classifier say "integer expression expected" and fall through to the wrong
# outcome — a rowless `skipped-optout` being refreshed is exactly that case.
rc_home="$work/rowcount"; rm -rf "$rc_home"; mkdir -p "$rc_home/.claude"
printf 'disposition skipped-optout\nversion -\nfloor 2.1.187\n' > "$rc_home/.claude/.adb-settings-owned"
rc_out="$(HOME="$rc_home" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
  eval "$(sed -n "/^adb_settings_row_count() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
  adb_settings_row_count')"
[ "$(printf '%s' "$rc_out" | wc -l | tr -d ' ')" -eq 0 ] && ok \
  || bad "the row count must be ONE value — grep -c prints its zero AND exits 1, and a printf fallback then emits a second one"
HOME="$rc_home" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
  eval "$(sed -n "/^adb_settings_row_count() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
  n="$(adb_settings_row_count)"; [ "$n" -eq 0 ]' 2>/dev/null && ok \
  || bad "...and must survive the arithmetic comparison its only caller performs"
# ...and it still counts correctly when there ARE rows.
printf 'disposition installed\nleaf%s["a","b"]%strue\nleaf%s["c","d"]%s1\n' \
  "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" > "$rc_home/.claude/.adb-settings-owned"
[ "$(HOME="$rc_home" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
  eval "$(sed -n "/^adb_settings_row_count() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
  adb_settings_row_count')" = "2" ] && ok \
  || bad "...and must still report the real count when the receipt carries rows"
# ...and when the receipt exists but cannot be READ at all, grep fails and prints nothing, so the
# normalisation is what stands between that and an empty string reaching the caller's arithmetic.
chmod 000 "$rc_home/.claude/.adb-settings-owned"
rc_unread="$(HOME="$rc_home" bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
  eval "$(sed -n "/^adb_settings_row_count() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
  adb_settings_row_count')"
chmod 600 "$rc_home/.claude/.adb-settings-owned"
case "$rc_unread" in ''|*[!0-9]*) bad "the row count must still be ONE integer when the receipt cannot be read — grep prints nothing there, and an empty string reaches an arithmetic test" ;; *) ok ;; esac

# --- a malformed source row is not provenance -------------------------------------------------------
#
# `source<TAB>` with nothing after it satisfies a raw grep for the row and is REJECTED by the reader,
# so the stamp was skipped and the receipt kept provenance nobody can use — and then the link went.
ms="$work/malformedsrc"; rm -rf "$ms"; mkdir -p "$ms/.claude"
echo '{"model":"opus"}' > "$ms/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$ms" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
sed "s|^source$ADB_TAB.*|source$ADB_TAB|" "$ms/.claude/.adb-settings-owned" > "$work/ms.tmp" && mv "$work/ms.tmp" "$ms/.claude/.adb-settings-owned"
[ -z "$(adb_claude_settings_receipt_source "$ms/.claude/.adb-settings-owned" 2>/dev/null)" ] && ok \
  || bad "precondition: the reader must reject a source row with no value"
printf 'not json' > "$ms/.claude/settings.json"
HOME="$ms" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
[ "$(adb_claude_settings_receipt_source "$ms/.claude/.adb-settings-owned" 2>/dev/null)" = "$ROOT" ] && ok \
  || bad "a receipt whose source row is malformed must be stamped like one that has none — a row is not a value, and the link is about to be removed"
[ "$(grep -c "^source$ADB_TAB" "$ms/.claude/.adb-settings-owned")" -eq 1 ] && ok \
  || bad "...and the malformed row must be REPLACED, not left to outrank the good one appended after it"

# --- the post-pull path asks both questions ---------------------------------------------------------
#
# It exited 0 on any successful heal, so an update that also lost the protections was rendered as a
# plain `updated` with the installer's own warning suppressed by the wrapper.
awk '/^  behind\)/{f=1}
     f && /adb_settings_downgraded_now/{print "ok"; exit}
     f && /baseline: update complete\./{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "the post-pull path must ask whether the protections were downgraded before it reports the update complete"
[ "$(grep -c 'adb_settings_downgraded_now' "$ROOT/bin/baseline")" -ge 3 ] && ok \
  || bad "...through the shared predicate both self-heal paths use, not a second copy of the question"

# --- the downgrade message does not contradict itself ------------------------------------------------
#
# When a reconciliation runs alongside the downgrade the rows really are dropped — so the trailing
# "ownership of the keys already written is unchanged" was false in exactly the case the preceding
# line had just announced, and the promise of automatic re-application went with it: an upgrade then
# meets keys nobody owns and refuses. The follow-up text is conditional on whether the count fell.
awk '/^adb_settings_downgraded_now\(\)/{f=1}
     f && /\[ "\$\(adb_settings_row_count\)" -lt "\$2" \]/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "the downgrade report must BRANCH on whether the row count fell — Stale ownership was ALSO relinquished is a different instruction to the operator than ownership being unchanged"
awk '/^adb_settings_downgraded_now\(\)/{f=1}
     f && /Remove them by hand, then re-run/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "...and when ownership WAS relinquished it must not promise automatic re-application: an upgrade meets keys nobody owns and refuses"

# --- a DOWNGRADE is not a reconciliation either -----------------------------------------------------
#
# Both leave a skip disposition behind, and classifying them by that label printed "relinquished
# stale sandbox ownership" over a CLI that had dropped below the floor — while the SessionStart
# wrapper suppresses the installer's own warning, so that false line was the only thing an operator
# saw. What actually distinguishes them is the ownership rows: a reconciliation drops them, a
# downgrade keeps every one and stops the protections being applied at all.
#
# STRUCTURAL, for the reason its siblings give: driving the `current)` arm needs a clone, a network
# classification and the update lock.
awk '/skipped-optout\|skipped-below-floor\|skipped-unprobeable\)/{f=1}
     f && /adb_settings_downgraded_now/{print "ok"; exit}
     f && /relinquished stale sandbox ownership/{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "a skip left by a self-heal must be classified by whether ownership rows were actually relinquished, not by the disposition label — the sandbox protections are NOT being applied is a different fact from a reconciliation"
# THE DISPOSITION IS THE FACT, NOT THE ROW DELTA. This rule USED to be the reverse — the predicate
# required the row count unchanged, on the reasoning that a reconciliation drops rows and a
# downgrade keeps them. That lost the mixed case: a CLI dropping below the floor WHILE a recorded
# leaf was also edited relinquishes its rows, so the counts differ and the run was reported as a
# tidy-up while the protections had silently stopped being applied. A reconciliation alongside it is
# reported too, not instead.
awk '/^adb_settings_downgraded_now\(\)/{f=1}
     f && /skipped-below-floor\|skipped-unprobeable/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "the downgrade predicate must decide on the DISPOSITION left behind by the heal — the row count cannot tell a mixed downgrade-plus-reconciliation from a reconciliation alone"
awk '/^adb_settings_downgraded_now\(\)/{f=1}
     f && /\[ "\$\(adb_settings_row_count\)" -eq "\$2" \] \|\| return 1/{print "bad"; exit}
     f && /^}/{exit}' "$ROOT/bin/baseline" | grep -q bad && \
  bad "...and must NOT require the row count unchanged: that is exactly what hid the mixed case" || ok
grep -qE '^\s*9\)' "$ROOT/scripts/lib/currency-lib.sh" && ok \
  || bad "currency-lib.sh must classify the downgrade code explicitly rather than letting it fall through to the catch-all as a failure"
awk '/^    9\)/{f=1} f && /_adb_cu_emit refused/{print "ok"; exit} f && /^    5\)/{exit}' \
  "$ROOT/scripts/lib/currency-lib.sh" | grep -q ok && ok \
  || bad "...and must report it as REFUSED: nothing was relinquished and nothing was repaired, what changed is that the protections stopped being applied"

# --- a reconciliation is not a repair --------------------------------------------------------------
#
# Divergent rows under a skip or an opt-out make the settings pending so the installer can
# relinquish them, and the receipt keeps that skip disposition — so the blocked check does not fire
# and the run reported "repaired." for a visit in which no link and no setting changed. The
# SessionStart caller renders that as "repaired the installed links".
#
# STRUCTURAL, for the reason the sibling pin gives: driving the `current)` arm end to end needs a
# clone, a network classification and the update lock.
awk '/adb_self_heal && adb_verify_links/{f=1}
     f && /skipped-optout\|skipped-below-floor\|skipped-unprobeable\)/{print "ok"; exit}
     f && /baseline: repaired\./{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "a visit that only relinquished stale ownership must not report a repair — no link and no setting was changed"
grep -qE '^\s*8\)' "$ROOT/scripts/lib/currency-lib.sh" && ok \
  || bad "currency-lib.sh must classify that code explicitly rather than letting it fall through to the catch-all as a failure"

# --- a refused sandbox install is not a "repair" ---------------------------------------------------
#
# When the settings were what was pending and the operator already owns one of the shipped keys,
# the all-or-nothing contract makes `install.sh` write `skipped-blocked` and return 0 — nothing
# applied. `bin/baseline` printed "repaired." and exited 6, and `currency-lib.sh` renders 6 as
# "repaired the installed links" while suppressing the installer's own output, so the refusal was
# invisible in the automatic SessionStart flow.
#
# STRUCTURAL PINS, and named as such: driving the `current)` arm end to end needs a git clone, a
# network classification and the update lock, which is the same reason the `pending()` harness above
# sources the predicate rather than running the updater. What IS driven behaviourally is the
# premise — that a blocked install really does return 0 with `skipped-blocked` recorded.
blk="$work/blocked-repair"; rm -rf "$blk"; mkdir -p "$blk/.claude"
echo '{"sandbox":{"enabled":false}}' > "$blk/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$blk" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1 && ok \
  || bad "premise: a blocked sandbox install must still return 0 — that is what makes the caller's success line wrong"
[ "$(adb_claude_settings_disposition "$blk/.claude/.adb-settings-owned")" = skipped-blocked ] && ok \
  || bad "premise: and must record skipped-blocked"
jq -e '.sandbox.enabled == false' "$blk/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "premise: and must have applied nothing"
grep -qF 'adb_claude_settings_disposition "$(adb_claude_settings_receipt "$HOME")" 2>/dev/null)" = skipped-blocked' "$ROOT/bin/baseline" && ok \
  || bad "bin/baseline must re-read the receipt after self-heal — a successful installer run is not the same as a repair"
# EVERY SELF-HEAL, not the one that repaired nothing else. Gating the refusal on \`LINKS_OK\` meant a
# run that ALSO fixed a broken link fell through to "repaired." and exit 6, and the \`behind\` branch
# exited 0 after a pull without asking at all — so the refusal vanished behind a success line
# exactly when something else had gone wrong too.
# BY POSITION, NOT BY COUNT. A `grep -c` over the name counts the function definition and the
# comment above it too, so deleting one of the two CALLS still cleared the threshold and the row
# covering it could not go red. Each call site is asserted where it has to be: before the line that
# reports success.
awk '/adb_self_heal && adb_verify_links/{f=1}
     f && /adb_settings_refused_now/{print "ok"; exit}
     f && /baseline: repaired\./{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "the same-HEAD repair path must ask whether the policy came back refused BEFORE it reports \"repaired\""
grep -qE '\[ "\$LINKS_OK" -eq 1 \] && exit 7' "$ROOT/bin/baseline" && \
  bad "the refusal must not be gated on LINKS_OK — a run that also repaired a link would report the repair and drop the refusal" || ok
awk '/^  behind\)/{f=1} f && /adb_settings_refused_now/{print "ok"; exit} f && /^  dirty\)/{exit}' "$ROOT/bin/baseline" | grep -q ok && ok \
  || bad "...and the post-pull path must ask before it reports the update complete"
grep -qE '^\s*7\)' "$ROOT/scripts/lib/currency-lib.sh" && ok \
  || bad "currency-lib.sh must classify that code explicitly — falling through to the catch-all reports it as a failure it is not"
awk '/^    7\)/{f=1} f && /_adb_cu_emit refused/{print "ok"; exit}' "$ROOT/scripts/lib/currency-lib.sh" | grep -q ok && ok \
  || bad "...and must report it as REFUSED, never as repaired or silent — a security-relevant omission may not read as success"

# --- the publish transaction defers signals, and resumes on EVERY way out --------------------------
#
# One deferral, and a resume on each exit from the pair — the rollback included. A resume placed at
# the top of the failure branch would let a pending Ctrl-C exit before the settings were put back,
# which is the half-applied state the rollback exists to prevent.
# EVERY TRANSACTION DEFERS, not just the one that was reported. This said "exactly once" when it
# was written, which encoded the count of transactions that happened to be guarded rather than the
# rule — and three more pairs of durable writes were sitting in the open: the refusal that also
# prunes a retired key, the uninstall side, and the hook wiring and its receipt. A count is the
# wrong shape for "every"; what is checkable is that install.sh guards all three of its own pairs
# and that no deferral is left without a way back.
[ "$(grep -c 'adb_settings_lock_defer_signals' "$ROOT/install.sh")" -ge 3 ] && ok \
  || bad "install.sh has three pairs of durable writes — the settings+receipt write, the refusal that prunes, and the hook wiring+receipt — and each must defer signals across its pair"
[ "$(grep -c 'adb_settings_lock_resume_signals' "$ROOT/install.sh")" \
  -ge "$(grep -c 'adb_settings_lock_defer_signals' "$ROOT/install.sh")" ] && ok \
  || bad "...and every deferral needs at least one way back: a transaction that defers and never resumes leaves the signal held for the rest of the run"
[ "$(grep -c 'adb_settings_lock_defer_signals' "$ROOT/uninstall.sh")" -eq 1 ] && ok \
  || bad "uninstall.sh publishes the rewritten settings and then removes the receipt — that pair must defer signals too"
[ "$(grep -c 'adb_settings_lock_resume_signals' "$ROOT/uninstall.sh")" -ge 3 ] && ok \
  || bad "...and must resume on each of its three exits (published, receipt-removal failed, rewrite failed)"
# THE CONSTRAINT, stated as itself: the receipt-publish failure branch must not resume on its FIRST
# line. Everything after that line is the rollback, and a pending signal honoured before it runs
# leaves exactly the half-applied state the rollback exists to undo.
awk '/if ! adb_publish_json "\$rtmp" "\$receipt"; then/{getline; if ($0 ~ /adb_settings_lock_resume_signals/) {print "early"; exit}}' \
  "$ROOT/install.sh" | grep -q early && \
  bad "the rollback runs INSIDE the transaction — resuming at the top of the failure branch lets a pending signal exit before the settings are put back" || ok

# --- an opt-out that could not be RECORDED is a failed install ------------------------------------
#
# `_adb_invalidate_stale_receipt` answers "is a stale claim still standing", and on a FIRST opt-out
# there is nothing to invalidate — so it returned 0 and the install succeeded having recorded
# nothing. The next `baseline update` then reads disposition `none`, omits `--no-sandbox`, and
# applies the policy over a choice the operator made by contract.
oo="$work/optoutfail"; rm -rf "$oo"; mkdir -p "$oo/.claude"
echo '{"model":"opus"}' > "$oo/.claude/settings.json"
mkdir "$oo/.claude/.adb-settings-owned"       # occupies the path; there is no prior receipt
HOME="$oo" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/oo.log" 2>&1 && \
  bad "a --no-sandbox install whose opt-out could not be recorded must FAIL — an unrecorded opt-out is silently overridden by the next update" || ok
grep -qi "could NOT be recorded" "$work/oo.log" && ok \
  || bad "...and must say so, naming what the next update will do"
rmdir "$oo/.claude/.adb-settings-owned"
HOME="$oo" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1 && ok \
  || bad "an opt-out that CAN be recorded must still succeed"
[ "$(adb_claude_settings_disposition "$oo/.claude/.adb-settings-owned")" = "skipped-optout" ] && ok \
  || bad "...and must record skipped-optout"

# --- a container is owned only while it still holds a leaf we own ----------------------------------
#
# Existence alone was not enough. When a payload retires the last owned leaf under a container we
# created AND the operator had edited that leaf, retirement keeps the edited value and writes no
# leaf row — but the container was carried forward because the object is still there. The receipt
# then claimed a container with no owned descendant, and an operator who deleted that subtree and
# recreated an empty object in its place had THEIR object removed by uninstall.
cw="$work/container"; rm -rf "$cw"; mkdir -p "$cw"
printf 'disposition installed\nversion 2.1.259\nfloor 2.1.187\npayload deadbeef\nsource%s%s\nleaf%s["x","y"]%s"ours"\ncontainer%s["x"]\n' \
  "$ADB_TAB" "$ROOT" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" > "$cw/receipt"
echo '{"x":{"y":"EDITED-BY-OPERATOR"}}' > "$cw/settings.json"
echo '{"other":1}' > "$cw/fragment.json"
cw_out="$(adb_claude_settings_merge "$cw/settings.json" "$cw/fragment.json" "$cw/receipt")"
[ "$(printf '%s' "$cw_out" | jq -c '.kept')" = '[["x","y"]]' ] && ok \
  || bad "an edited retired leaf must be KEPT, not pruned"
[ "$(printf '%s' "$cw_out" | jq -c '.created')" = '[]' ] && ok \
  || bad "a container with no owned descendant left must not be carried into the new receipt — uninstall would remove an object the operator recreated there"
# ...and one that DOES still hold an owned leaf survives, or the rule above would relinquish everything.
echo '{"x":{"y":"ours"}}' > "$cw/s2.json"
echo '{"x":{"y":"ours","z":"new"}}' > "$cw/f2.json"
[ "$(adb_claude_settings_merge "$cw/s2.json" "$cw/f2.json" "$cw/receipt" | jq -c '.created')" = '[["x"]]' ] && ok \
  || bad "a container that still holds an owned leaf must be retained"

# --- currency asks the LIVE file too, not only the payload digest ----------------------------------
#
# The digest says the payload has not changed; it says nothing about what is in settings.json. An
# operator who edits a recorded leaf has taken the surface over, and until the installer observes
# that it never records the ownership-free refusal — so an edit made, left through an update, and
# later reverted by hand ended with uninstall deleting the restored value as installer-owned.
li="$work/liveint"; rm -rf "$li"; mkdir -p "$li/.claude"
echo '{"model":"opus"}' > "$li/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$li" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
li_r="$li/.claude/.adb-settings-owned"; li_s="$li/.claude/settings.json"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 0 ] && ok \
  || bad "a clean install must read as intact"
jq '.sandbox.enabled = false' "$li_s" > "$work/li.tmp" && mv "$work/li.tmp" "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 1 ] && ok \
  || bad "an edited recorded leaf must read as DIVERGED"
jq 'del(.sandbox.enabled)' "$li_s" > "$work/li.tmp" && mv "$work/li.tmp" "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 1 ] && ok \
  || bad "a deleted recorded leaf must read as diverged too"
jq '.sandbox = false' "$li_s" > "$work/li.tmp" && mv "$work/li.tmp" "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 1 ] && ok \
  || bad "an ancestor replaced by a SCALAR must answer diverged — getpath raises through one, and an unguarded read took the whole predicate down"
printf 'not json' > "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 2 ] && ok \
  || bad "an unparseable settings file must answer UNANSWERABLE, never divergence — treating it as divergence is the repair loop"
# ...but ABSENT and ZERO-BYTE are definite answers, not reads this run could not perform: every
# recorded leaf is provably gone. Reporting them as "cannot tell" meant the reconciliation was never
# scheduled, so an operator who deleted the file, let an update run, and later recreated the
# recorded values had them deleted by uninstall as installer-owned.
rm -f "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 1 ] && ok \
  || bad "an ABSENT settings file must read as DIVERGED — the recorded leaves are provably gone, which is an answer rather than a failure to look"
: > "$li_s"
adb_claude_settings_leaves_intact "$li_r" "$li_s"; [ $? -eq 1 ] && ok \
  || bad "...and so must a zero-byte one"
# ...and with NOTHING recorded there is nothing to diverge, however absent the file is.
: | adb_claude_settings_receipt_render skipped-optout - "$FLOOR" > "$work/li-rowless"
rm -f "$li_s"
adb_claude_settings_leaves_intact "$work/li-rowless" "$li_s"; [ $? -eq 0 ] && ok \
  || bad "a rowless receipt must read as intact whatever the settings file is — the absence check has to come after the rowless one"

# --- a signal releases the lock too, not only an ordinary return ---------------------------------
#
# A helper wrapper covers every `return`; it covers no signal. A TERM or INT while the body runs
# exits the shell before any unlock statement, and the lock left behind refuses every later install
# and uninstall for the stale interval — longer if the recorded pid is reused. `bin/baseline`
# already traps for this on the same primitive.
#
# THE SIGNAL LANDS DETERMINISTICALLY, WITH NO CLOCK IN IT. A plain install finishes in well under
# a second, so a timed kill against it is a coin flip that passes either way. A *slow* stub plus a
# fixed delay is no better: under `selfcheck`'s parallel load the install had not yet taken the
# lock when the timer fired, and this fixture failed in CI-like conditions while passing unloaded —
# the timing class `ci-discipline.md` calls "'flaky' causes that are actually real".
#
# So the stub HANDSHAKES instead. It is executed by the version probe, which runs inside the locked
# region: it announces itself, then blocks until released. The test waits for that announcement
# (bounded, never a bare clock), asserts the lock is held, signals, and lets the stub go. No step
# depends on how fast the machine is.
sig_home="$work/signal"; rm -rf "$sig_home"; mkdir -p "$sig_home/.claude" "$work/slowbin"
export ADB_SIG_READY="$work/sig.ready" ADB_SIG_GO="$work/sig.go"
rm -f "$ADB_SIG_READY" "$ADB_SIG_GO"
cat > "$work/slowbin/claude" <<'SIGSTUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
  : > "$ADB_SIG_READY"
  i=0
  while [ ! -f "$ADB_SIG_GO" ] && [ "$i" -lt 900 ]; do sleep 0.1; i=$((i+1)); done
  echo "2.1.259 (Claude Code)"
  exit 0
fi
exit 1
SIGSTUB
chmod +x "$work/slowbin/claude"
HOME="$sig_home" PATH="$work/slowbin:$PATH" bash "$ROOT/install.sh" --agent claude >/dev/null 2>&1 &
sig_pid=$!
sig_i=0
while [ ! -f "$ADB_SIG_READY" ] && [ "$sig_i" -lt 900 ]; do sleep 0.1; sig_i=$((sig_i+1)); done
[ -f "$ADB_SIG_READY" ] && ok || bad "the install never reached the version probe — the signal fixture proves nothing"
[ -e "$(adb_settings_lock_path "$sig_home")" ] && ok \
  || bad "the fixture must signal the install WHILE it holds the lock, or it proves nothing"
kill -TERM "$sig_pid" 2>/dev/null
: > "$ADB_SIG_GO"
wait "$sig_pid" 2>/dev/null; sig_rc=$?
rm -f "$ADB_SIG_READY" "$ADB_SIG_GO"
unset ADB_SIG_READY ADB_SIG_GO
[ "$sig_rc" -eq 143 ] && ok || bad "a TERM must terminate the install as a TERM (143), not be swallowed (got $sig_rc)"
[ -e "$(adb_settings_lock_path "$sig_home")" ] && \
  bad "a TERM mid-install must not leave the settings lock behind — it refuses every later run" || ok

# --- the wrapper's result carries a failed release ------------------------------------------------
#
# The helper reports it; a wrapper that discards the status still exits 0, and a self-heal
# suppresses the warning — so the command reports success while every later install and uninstall
# is refused by a lock nobody can see.
awk '/^install_claude\(\)/{f=1} f && /adb_settings_lock_drop \|\| icrc=1/{print "ok"; exit} f && /^}/{exit}' \
  "$ROOT/install.sh" | grep -q ok && ok \
  || bad "install_claude must fold a failed lock release into its own status — the helper's warning is not an exit code"
awk '/^uninstall_claude\(\)/{f=1} f && /adb_settings_lock_drop \|\| ucrc=1/{print "ok"; exit} f && /^}/{exit}' \
  "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "uninstall_claude must do the same"

# --- an unreadable receipt is not one WITHOUT a source ------------------------------------------------
#
# With the root-doc link already gone, `|| true` turned a failed read into an empty source, which
# reads as "legacy, and not ours" — so uninstall returned 0, the outer script printed `Uninstalled`,
# and every owned sandbox setting stayed active with nobody told.
us2="$work/unreadsource"; rm -rf "$us2"; mkdir -p "$us2/.claude"
echo '{"model":"opus"}' > "$us2/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$us2" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
rm -f "$us2/.claude/CLAUDE.md"
chmod 000 "$us2/.claude/.adb-settings-owned"
HOME="$us2" bash "$ROOT/uninstall.sh" --agent claude >"$work/us2.log" 2>&1 && \
  bad "an uninstall that cannot read the receipt must FAIL — with the link gone, an empty source reads as another clone's and every owned key is silently left behind" || ok
chmod 600 "$us2/.claude/.adb-settings-owned"
grep -qiE '^Uninstalled' "$work/us2.log" && \
  bad "...and must not print Uninstalled over settings it never touched" || ok
jq -e '.sandbox.enabled == true' "$us2/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and the keys must still be there, since nothing proved they were ours to remove"

# --- `none` is a sentinel and is never persisted ------------------------------------------------------
#
# It means "nobody has written a receipt", and the reader refuses it in a receipt that EXISTS — so
# writing it produces a record nothing afterwards can classify: `adb_settings_pending` cannot read
# it, the merge answers 21, and the policy can never be installed until the file is deleted by hand.
# An empty receipt is exactly the input that yields it.
grep -q 'njdisp' "$ROOT/install.sh" && ok \
  || bad "the no-jq provenance path must not render whatever the disposition reader returned — `none` is a sentinel for an ABSENT receipt and cannot be written into a present one"
awk '/njdisp="\$\(adb_claude_settings_disposition/{f=1}
     f && /= none \]/{print "ok"; exit}
     f && /receipt_render/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and must refuse specifically when it reads `none`, which is what an empty receipt produces"

# --- an unstamped legacy install is not unlinked ----------------------------------------------------
#
# A stamp that failed used to warn and carry on into `adb_unlink_manifest`, which removes the only
# proof a legacy receipt has — and then relied on the settings cleanup succeeding, which is exactly
# the retryable failure the stamp exists to survive.
#
# A STRUCTURAL PIN, and the first version of this was a behavioural fixture that PASSED WITHOUT EVER
# REACHING THE STAMP. Making the stamp fail needs ~/.claude unwritable, and the settings lock is a
# directory inside ~/.claude — so the run refuses at the lock, three assertions go green, and none
# of them has exercised anything. That is the third time this file has met that wall; it is stated
# here rather than rediscovered a fourth time.
awk '/could not record provenance on this legacy/{f=1}
     f && /return 1   # stamp-failed/{print "ok"; exit}
     f && /^  fi$/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "a legacy receipt whose provenance could not be stamped must FAIL rather than unlink the proof it depends on"
awk '/^_uninstall_claude_locked\(\)/{f=1}
     f && /could not record provenance on this legacy/{print "ok"; exit}
     f && /^  adb_unlink_manifest "\$REPO"/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "...and that refusal must come BEFORE adb_unlink_manifest, or the proof is already gone when it fires"

# --- a legacy receipt gains durable provenance before the link that proves it is removed ------------
#
# `adb_unlink_manifest` runs before `unwire_settings`, so a receipt with no `source` row whose
# cleanup then fails in a retryable way is left with no proof at all — the next run reads it as
# foreign and can never clean it up, even once the original problem is fixed.
lp="$work/legacyprov"; rm -rf "$lp"; mkdir -p "$lp/.claude"
echo '{"model":"opus"}' > "$lp/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$lp" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
grep -v "^source$ADB_TAB" "$lp/.claude/.adb-settings-owned" > "$work/lp.tmp" && mv "$work/lp.tmp" "$lp/.claude/.adb-settings-owned"
[ -z "$(adb_claude_settings_receipt_source "$lp/.claude/.adb-settings-owned")" ] && ok \
  || bad "precondition: the legacy fixture must carry no source row"
# Make the settings unparseable so the cleanup fails RETRYABLY, after the link has gone.
printf 'not json' > "$lp/.claude/settings.json"
HOME="$lp" bash "$ROOT/uninstall.sh" --agent claude >"$work/lp.log" 2>&1
[ "$(adb_claude_settings_receipt_source "$lp/.claude/.adb-settings-owned")" = "$ROOT" ] && ok \
  || bad "a legacy receipt must be stamped with this clone as its source BEFORE the root-doc link is removed — otherwise a retryable failure strands it as foreign forever"
# ...and the retry, once the settings are valid again, can still prove ownership with no link left.
cp "$PAYLOAD" "$lp/.claude/settings.json"
HOME="$lp" bash "$ROOT/uninstall.sh" --agent claude >"$work/lp2.log" 2>&1
jq -e '.sandbox == null' "$lp/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...so the retry must succeed on the strength of that recorded source alone"
# AN UNREADABLE RECEIPT IS LEFT ALONE BY THAT STAMP. It reports no source row for the same reason it
# reports nothing else, and a stamp driven off that answer published a receipt carrying ONLY the new
# source row — every ownership row destroyed by the step meant to preserve provenance.
lu="$work/legacyunreadable"; rm -rf "$lu"; mkdir -p "$lu/.claude"
echo '{"model":"opus"}' > "$lu/.claude/settings.json"
HOME="$lu" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
lu_rows="$(grep -c "^leaf$ADB_TAB" "$lu/.claude/.adb-settings-owned")"
chmod 000 "$lu/.claude/.adb-settings-owned"
HOME="$lu" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
chmod 600 "$lu/.claude/.adb-settings-owned"
[ "$(grep -c "^leaf$ADB_TAB" "$lu/.claude/.adb-settings-owned")" -eq "$lu_rows" ] && ok \
  || bad "an unreadable receipt must be left untouched by the provenance stamp — writing from an empty read destroys every ownership row"

# --- every file this suite READS is declared as a gate input ---------------------------------------
#
# `mutation-gate.sh` dispatches the harness only when the change touches its declared inputs, so a
# file the suite reads but the registry does not name means a PR changing only that file skips the
# falsifiability check entirely. This suite grew pins on `currency-lib.sh` when the exit-code
# classifications landed, and the input set was not swept with them — `declared-inputs-incomplete`,
# which is on this project's promoted checklist.
sf_inputs="$(bash "$ROOT/scripts/selfcheck.sh" --list | awk -F'\t' '$1=="settings-fragment-mutation"{print $5}')"
for _f in scripts/lib/common.sh install.sh uninstall.sh bin/baseline scripts/lib/currency-lib.sh \
          scripts/lib/pinned-install.sh agents/claude/settings.fragment.json; do
  case ",$sf_inputs," in
    *",$_f,"*) ok ;;
    *) bad "settings-fragment-mutation must declare $_f as an input — this suite reads it, and a PR touching only that file would skip the harness" ;;
  esac
done

# --- a container the OPERATOR recreated survives a mixed refusal --------------------------------------
#
# The retirement pass used to walk every container the receipt records and delete any that was
# empty. In a mixed refusal — one recorded leaf retired, another still-shipped leaf taken over by
# the operator — the retirement publishes the document, so an empty object the operator had
# recreated at one of those paths was deleted before the receipt relinquished anything. A container
# is a candidate only while it is a proper ancestor of a leaf THIS pass actually pruned.
mx="$work/mixedrefusal"; rm -rf "$mx"; mkdir -p "$mx"
printf 'disposition installed\nversion 2.1.259\nfloor 2.1.187\npayload deadbeef\nsource%s%s\nleaf%s["a","gone"]%s"ours"\nleaf%s["b","kept"]%s"ours"\ncontainer%s["a"]\ncontainer%s["b"]\n' \
  "$ADB_TAB" "$ROOT" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" "$ADB_TAB" > "$mx/receipt"
echo '{"a":{"gone":"ours"},"b":{}}' > "$mx/s.json"
echo '{"b":{"kept":"ours"}}' > "$mx/f.json"
mx_out="$(adb_claude_settings_merge "$mx/s.json" "$mx/f.json" "$mx/receipt")"
[ "$(printf '%s' "$mx_out" | jq -r '.verdict')" = refuse ] && ok \
  || bad "precondition: a still-shipped leaf the operator deleted must make this a refusal"
[ "$(printf '%s' "$mx_out" | jq -c '.pruned')" = '[["a","gone"]]' ] && ok \
  || bad "precondition: the retired leaf must still be pruned — retirement is independent of the refusal"
printf '%s' "$mx_out" | jq -e '.settings | has("a") | not' >/dev/null 2>&1 && ok \
  || bad "a container THIS run emptied by retiring its last owned leaf must be removed with it"
printf '%s' "$mx_out" | jq -e '.settings.b == {}' >/dev/null 2>&1 && ok \
  || bad "...but an empty object at a path the operator has taken over must SURVIVE — we cannot tell it from one of ours, so we must not delete it"

# --- and the coupling that makes the blocked writer's condition exact -------------------------------
#
# The blocked path asks whether the DOCUMENT changed, as the uninstall side does. Given the rule
# above, that is equivalent today to "a leaf was pruned": containers are only removed as ancestors
# of pruned leaves, and nothing is written on a refusal. The equivalence is asserted rather than
# assumed, so relaxing the container rule cannot silently reintroduce the skip that finding
# described — it breaks this instead.
cp_out="$(adb_claude_settings_merge "$mx/s.json" "$mx/f.json" "$mx/receipt")"
if printf '%s' "$cp_out" | jq -e --slurpfile orig "$mx/s.json" '.settings == $orig[0]' >/dev/null 2>&1; then
  [ "$(printf '%s' "$cp_out" | jq -r '.pruned | length')" -eq 0 ] && ok \
    || bad "a refusal that left the document unchanged must have pruned nothing"
else
  [ "$(printf '%s' "$cp_out" | jq -r '.pruned | length')" -gt 0 ] && ok \
    || bad "a refusal that CHANGED the document must have pruned a leaf — if a container can move on its own, the blocked writer's \$retired guard is no longer exact"
fi

# --- an owned CONTAINER is still something of ours ---------------------------------------------------
#
# "Did the file change" was asked of `.pruned`, which counts LEAVES — and the removal also deletes
# the containers this install created. An operator who had deleted every recorded leaf but left our
# empty `sandbox` object behind pruned nothing, so the write was skipped and that object was
# orphaned in settings.json permanently.
oc="$work/orphancontainer"; rm -rf "$oc"; mkdir -p "$oc/.claude"
echo '{"model":"opus"}' > "$oc/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$oc" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(grep -c "^container$ADB_TAB" "$oc/.claude/.adb-settings-owned")" -gt 0 ] && ok \
  || bad "precondition: the install must have recorded the containers it created"
jq '.sandbox = {}' "$oc/.claude/settings.json" > "$work/oc.tmp" && mv "$work/oc.tmp" "$oc/.claude/settings.json"
HOME="$oc" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
jq -e 'has("sandbox") | not' "$oc/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "an empty container this install created must still be removed — a zero LEAF count is not proof that nothing of ours is left"
jq -e '.model == "opus"' "$oc/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and the operator's own keys must survive that removal"

# --- an ACCURATE ownership record is never destroyed because its replacement failed -----------------
#
# `_adb_carry_rows` returns rows only when every recorded leaf still carries its recorded value, so
# a non-empty carry means the OLD receipt is still correct. Invalidating it because the replacement
# could not be written leaves the installed keys with no owner at all: uninstall cannot remove them,
# and the next install reads them as the operator's and refuses the policy.
#
# STRUCTURAL for the same measured reason as its siblings: the only drivable publish failure is a
# non-regular receipt path, which an earlier check catches first.
awk '/^_adb_record_skip\(\)/{f=1}
     f && /if \[ -n "\$carried" \]; then/{print "ok"; exit}
     f && /_adb_invalidate_stale_receipt/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "a version skip whose receipt could not be published must KEEP a still-accurate record rather than invalidating it"
awk '/if \[ -n "\$carried" \]; then/{f=1}
     f && /return 1   # skip-not-recorded-kept/{print "ok"; exit}
     f && /^  fi$/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and that kept-record branch must still FAIL the run: the skip was not recorded, so reporting success leaves the next update unaware of it"
awk '/optout_rows="\$\(_adb_carry_rows/{f=1}
     f && /if \[ -n "\$optout_rows" \]/{print "ok"; exit}
     f && /_adb_invalidate_stale_receipt/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and the --no-sandbox sibling must do the same"
# ...and it keeps a ROWLESS opt-out record too, which is the normal shape when `--no-sandbox` was
# chosen before this installer owned any keys. Deleting that because the replacement could not be
# written makes the next update read `none` and apply the policy over an explicit decision.
awk '/optout_rows="\$\(_adb_carry_rows/{f=1}
     f && /= skipped-optout/{print "ok"; exit}
     f && /_adb_invalidate_stale_receipt/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and must keep an existing opt-out record even when it carries no rows — the record IS the evidence of the choice"

# --- nothing is pruned until the receipt is known to be replaceable ---------------------------------
#
# Retirement rewrites the settings first and publishes the refusal receipt second, so a receipt that
# can be neither replaced nor removed leaves the old record claiming a value the prune already took
# out — and an operator who recreates it has it deleted as ours.
awk '/transaction: retirement prune \+ refusal receipt/{f=1}
     f && /mv "\$receipt" "\$_bprobe"/{print "ok"; exit}
     f && /adb_publish_json "\$rtmp2" "\$settings"/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "the retirement prune must prove the receipt is replaceable BEFORE it rewrites settings.json"

# --- nothing of ours in the file means the file is not touched -------------------------------------
#
# A rowless receipt — a first blocked refusal, a below-floor skip — or one whose every owned leaf
# the operator has since edited prunes nothing, and republishing the document anyway rewrote it for
# no reason. Measured before the fix: an operator's settings.json SYMLINK became a regular file and
# the contents were reformatted, by an uninstall that had nothing of ours to remove.
#
# BOTH WRITERS, because the hook half had the same defect and the review named only the settings
# half: it republished unconditionally AND through a bare `mv` rather than the shared publish, so it
# neither refused a non-regular destination nor carried the original's mode across.
nt="$work/nottouched"; rm -rf "$nt"; mkdir -p "$nt/.claude" "$nt/real"
printf '{\n  "sandbox": { "enabled": false },\n  "model": "opus"\n}\n' > "$nt/real/settings.json"
ln -s "$nt/real/settings.json" "$nt/.claude/settings.json"
nt_sum="$(adb_sha256 "$nt/real/settings.json")"
stub "2.1.259 (Claude Code)"
HOME="$nt" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(adb_claude_settings_disposition "$nt/.claude/.adb-settings-owned")" = skipped-blocked ] && ok \
  || bad "precondition: the operator already owns a shipped key, so the install must refuse and record no rows"
HOME="$nt" bash "$ROOT/uninstall.sh" --agent claude >"$work/nt.log" 2>&1
[ -L "$nt/.claude/settings.json" ] && ok \
  || bad "an uninstall with nothing of ours to remove must leave settings.json alone — republishing it turns the operator's SYMLINK into a regular file"
[ "$(adb_sha256 "$nt/real/settings.json")" = "$nt_sum" ] && ok \
  || bad "...and must leave it byte-for-byte, not reformatted by a round trip through jq"
grep -qi "left untouched" "$work/nt.log" && ok \
  || bad "...and must say that nothing of ours was there, rather than reporting a removal it did not make"
[ -e "$nt/.claude/.adb-settings-owned" ] && \
  bad "...but the ownership record itself must still go — that is what uninstall is for" || ok
# ...and a real removal still happens, or the rule above would be satisfied by never removing anything.
rt="$work/realremove"; rm -rf "$rt"; mkdir -p "$rt/.claude"
echo '{"model":"opus"}' > "$rt/.claude/settings.json"
HOME="$rt" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude >/dev/null 2>&1
jq -e '.hooks != null and .sandbox.enabled == true' "$rt/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "precondition: this fixture must have both hooks and sandbox keys installed"
HOME="$rt" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1
jq -e '(.hooks | length) == 0 and .sandbox == null' "$rt/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and an uninstall that DOES own things must still remove them from both surfaces"

# --- a refused removal leaves no temp file behind ---------------------------------------------------
#
# `--remove` mode creates its synthetic empty payload BEFORE the receipt is parsed, so the early
# returns that propagate a receipt-classification failure walked past the cleanup at the end of the
# function. Every failed install or uninstall retry against a damaged receipt left another one.
#
# COUNTED IN A PRIVATE SPOOL, via a stubbed `mktemp` on PATH. The first version counted the real
# temp directory, and that directory is SHARED: under `selfcheck`'s parallel run the neighbouring
# steps create files there constantly, so the check failed on a clean tree with "3 attempts left 1
# file(s)". Counting a shared namespace cannot be made reliable — isolating the namespace can.
# (It also cannot use TMPDIR: macOS `mktemp` with no template ignores it and takes the per-user
# confstr path, which is what made the version before THAT report no leak at all.)
tl="$work/tmpleak"; rm -rf "$tl"; mkdir -p "$tl/bin" "$tl/spool"
cat > "$tl/bin/mktemp" <<TLSTUB
#!/bin/sh
# No template and no flags is the call the merge makes; everything else passes through untouched.
if [ \$# -eq 0 ]; then exec $(command -v mktemp) "$tl/spool/tmp.XXXXXX"; fi
exec $(command -v mktemp) "\$@"
TLSTUB
chmod +x "$tl/bin/mktemp"
printf 'disposition wat\nleaf%s["sandbox","enabled"]%strue\n' "$ADB_TAB" "$ADB_TAB" > "$tl/receipt"
echo '{"sandbox":{"enabled":true}}' > "$tl/s.json"; echo '{}' > "$tl/f.json"
( PATH="$tl/bin:$PATH"
  for _i in 1 2 3; do adb_claude_settings_merge "$tl/s.json" "$tl/f.json" "$tl/receipt" --remove >/dev/null 2>&1; done )
[ "$(find "$tl/spool" -type f | wc -l | tr -d ' ')" -eq 0 ] && ok \
  || bad "a removal refused for a damaged receipt must not leak its synthetic payload — 3 attempts left $(find "$tl/spool" -type f | wc -l | tr -d ' ') file(s)"
# ...and the stub must actually have been reached, or the count above is zero for the wrong reason.
( PATH="$tl/bin:$PATH"; adb_claude_settings_merge "$tl/s.json" "$tl/f.json" "$tl/receipt" >/dev/null 2>&1 ) || true
mktemp_probe="$(PATH="$tl/bin:$PATH" mktemp)"; case "$mktemp_probe" in "$tl/spool/"*) ok ;; *) bad "the mktemp stub was not on PATH, so the leak count above proved nothing" ;; esac
rm -f "$mktemp_probe"

# --- the reader still tells UNREADABLE from DAMAGED, even though uninstall now refuses earlier ------
#
# `unwire_settings` prints a different message for each, and that was their only behavioural
# observable — but uninstall now refuses an unreadable receipt BEFORE it gets there, so the 20 path
# is reachable only by a race between that check and the merge's own read. The branch is kept as
# defence in depth against exactly that race, and pinned here because nothing else can fail on it.
awk '/^adb_claude_settings_disposition\(\)/{f=1}
     f && /\[ "\$grc" -le 1 \] \|\| return 20/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/scripts/lib/common.sh" | grep -q ok && ok \
  || bad "the disposition reader must still answer 20 for a receipt it could not READ, distinct from 21 for one it could not classify — uninstall re-reads after its own check and the two need different remedies"
awk '/^unwire_settings\(\)/{f=1}
     f && /elif \[ "\$mrc" -eq 21 \]; then/{print "ok"; exit}
     f && /^}/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "...and unwire_settings must keep a distinct arm for each, or the remedies collapse into one wrong message"

# --- a receipt that could not be CLASSIFIED is not an unparseable live file -------------------------
#
# The merge answers 20 and 21 for a receipt it could not read or classify — the rows are still there
# and still name our keys — while any other failure means the live settings would not parse, which
# really is an inability to prove ownership. Folding the first two into `probe=""` turned a damaged
# receipt into a successful relinquishment, so a non-writing install published an ownership-free
# skip over it while every matching leaf stayed installed.
dm="$work/damaged-carry"; rm -rf "$dm"; mkdir -p "$dm/.claude"
echo '{"model":"opus"}' > "$dm/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$dm" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
dm_before="$(grep -c "^leaf$ADB_TAB" "$dm/.claude/.adb-settings-owned")"
[ "$dm_before" -gt 0 ] && ok || bad "precondition: the fixture must have rows to lose"
grep -v '^disposition' "$dm/.claude/.adb-settings-owned" > "$work/dm.tmp" && mv "$work/dm.tmp" "$dm/.claude/.adb-settings-owned"
HOME="$dm" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1 && \
  bad "an opt-out over a receipt that could not be CLASSIFIED must fail, not publish an ownership-free replacement" || ok
[ "$(grep -c "^leaf$ADB_TAB" "$dm/.claude/.adb-settings-owned")" -eq "$dm_before" ] && ok \
  || bad "...and every owned row must survive"
jq -e '.sandbox.enabled == true' "$dm/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "...and the keys it could not prove ownership of must be left alone"

# --- a present source row decides, and the link is only the fallback --------------------------------
#
# The failed-takeover state is reachable: clone B replaces the root-doc link and then fails before
# refreshing the receipt — the no-jq provenance path does exactly that. The link then says "ours"
# while the source row still names A, and B's uninstall consumed and deleted settings whose record
# explicitly named somebody else. A source row is evidence about the RECEIPT; the link is evidence
# about the tree around it.
ft="$work/failedtakeover"; rm -rf "$ft"; mkdir -p "$ft/.claude"
echo '{"model":"opus"}' > "$ft/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$ft" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
sed "s|^source$ADB_TAB.*|source$ADB_TAB/some/other/clone|" "$ft/.claude/.adb-settings-owned" > "$work/ft.tmp" \
  && mv "$work/ft.tmp" "$ft/.claude/.adb-settings-owned"
HOME="$ft" bash "$ROOT/uninstall.sh" --agent claude >"$work/ft.log" 2>&1
jq -e '.sandbox.enabled == true' "$ft/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "a receipt naming ANOTHER clone must be left alone even when the root-doc link says this one — the link can be replaced by a takeover that then failed"
[ -f "$ft/.claude/.adb-settings-owned" ] && ok \
  || bad "...and its record must survive, since the clone that owns it still needs it"
grep -qi "names another clone" "$work/ft.log" && ok \
  || bad "...and the run must say whose it is, so the operator knows where to uninstall from"

# --- a release that did not release is reported, not reported as success ---------------------------
#
# The token used to be cleared BEFORE the removal, so an `rm`/`rmdir` defeated by an ACL or a
# read-only parent left the directory standing while the run reported a clean release — and every
# later install and uninstall was refused until the stale interval elapsed. Every path calls the
# helper now, which was the point of having one; a helper that swallows the failure just moves the
# silence one level down.
ur2="$work/unrelease"; rm -rf "$ur2"; mkdir -p "$ur2/.claude"
HOME="$ur2" bash -c '
  . "'"$ROOT"'/scripts/lib/common.sh"
  adb_settings_lock_take || exit 9
  chmod 500 "$HOME/.claude"          # the lock survives: its parent is no longer writable
  adb_settings_lock_drop; drc=$?
  chmod 700 "$HOME/.claude"
  exit "$drc"
' >"$work/unrelease.log" 2>&1 && \
  bad "a settings lock that could not be removed must NOT report a clean release — every later run is refused until somebody deletes it" || ok
grep -qi "could not be released" "$work/unrelease.log" && ok \
  || bad "...and must say so, naming the path, because the operator is the only one who can clear it"
rm -rf "$(adb_settings_lock_path "$ur2")" 2>/dev/null

# --- a record that was not written is not a success, whoever asks ----------------------------------
#
# `_adb_invalidate_stale_receipt` answers "does a stale claim still survive". On a FIRST refusal or
# skip there is nothing to invalidate, so it returns 0 — and two callers were still returning that
# as their own status, reporting success having recorded nothing. The opt-out was fixed when it was
# reported; these two are its siblings, swept rather than waited for.
#
# STRUCTURAL, and the reason is the one this file has recorded twice: the only drivable way to fail
# these publishes is a non-regular receipt path, and an earlier check catches that and returns 1
# before either branch is reached. What is checkable is that neither branch returns the
# invalidator's status any more.
awk '/_adb_invalidate_stale_receipt "\$receipt" "the refusal stands/{f=1}
     f && /return 1   # blocked-not-recorded/{print "ok"; exit}
     f && /return "\$invrc"|return \$\?/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "a blocked refusal whose receipt was not published must return non-zero — the invalidator's 0 means only that no stale claim survives"
awk '/_adb_invalidate_stale_receipt "\$receipt" "the skip stands/{f=1}
     f && /return 1   # skip-relinquished/{print "ok"; exit}
     f && /return \$\?/{exit}' "$ROOT/install.sh" | grep -q ok && ok \
  || bad "...and a skip whose receipt was not published must do the same"
[ "$(grep -c 'return \$?' "$ROOT/install.sh")" -eq 0 ] && ok \
  || bad "no path may hand the invalidator's benign status back as its own — that is the defect, and it is spelled the same way each time"

# --- the receipt must be PROVED removable before the settings are rewritten ------------------------
#
# Deferring signals closed the interruption window and did nothing for an ordinary I/O failure
# between the same two durable changes: with the receipt made immutable, uninstall removed every
# owned leaf and then could not delete the record, leaving it claiming four values that were gone.
awk '/^unwire_settings\(\)/{f=1}
     f && /mv "\$receipt" "\$_rprobe"/{print "ok"; exit}
     f && /adb_publish_json "\$tmp" "\$settings"/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "uninstall must prove the receipt can be removed BEFORE it rewrites settings.json — discovering it afterwards leaves the transaction half-applied"
# ...and the PROBE IS ITSELF TWO RENAMES, so the deferral opens before it. A signal between the
# move-aside and the restore strands the receipt at the `.probe` path, and the next install then
# reads the still-installed values as the operator's and publishes an ownership-free refusal over
# the evidence. Guarding the write while leaving the probe exposed is the same window one step
# earlier.
awk '/^unwire_settings\(\)/{f=1}
     f && /adb_settings_lock_defer_signals/{print "ok"; exit}
     f && /mv "\$receipt" "\$_rprobe"/{exit}' "$ROOT/uninstall.sh" | grep -q ok && ok \
  || bad "the removability probe is itself two renames — signals must already be deferred when the first one runs"
# ...and driven for real where the platform can make a file undeletable without privileges. macOS
# has `chflags uchg`; Linux's equivalent needs root, so this says SKIP rather than pretending.
if command -v chflags >/dev/null 2>&1; then
  im="$work/immutable"; rm -rf "$im"; mkdir -p "$im/.claude"
  echo '{"model":"opus"}' > "$im/.claude/settings.json"
  stub "2.1.259 (Claude Code)"
  HOME="$im" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
  chflags uchg "$im/.claude/.adb-settings-owned" 2>/dev/null
  HOME="$im" bash "$ROOT/uninstall.sh" --agent claude >"$work/im.log" 2>&1 && \
    bad "an uninstall that cannot remove the receipt must fail" || ok
  jq -e '.sandbox.enabled == true' "$im/.claude/settings.json" >/dev/null 2>&1 && ok \
    || bad "...and must leave settings.json UNTOUCHED — removing the leaves first is what strands the record"
  [ "$(grep -c "^leaf$ADB_TAB" "$im/.claude/.adb-settings-owned")" -gt 0 ] && ok \
    || bad "...and must leave the record's rows intact for the retry"
  chflags nouchg "$im/.claude/.adb-settings-owned" 2>/dev/null
  HOME="$im" bash "$ROOT/uninstall.sh" --agent claude >/dev/null 2>&1 && ok \
    || bad "...and the retry must succeed once the receipt is removable"
else
  echo "SKIP: no chflags on this platform — the immutable-receipt case is pinned structurally above"
fi

# --- arming is what makes an un-deferred signal release the lock --------------------------------
#
# Asserted at the LIBRARY, with no transaction in the way, and that is the point. Driven through
# `install.sh` this cannot fail: `wire_hooks` runs first and its deferring TERM handler survives
# into the version probe, so a signal there is recorded rather than fatal and the lock is released
# by the ordinary path — the fixture reports success while the arming it claims to cover is gone.
# Measured: with `_adb_arm_lock_traps` neutered the installer still exited 143 with the lock
# released. A guard whose subject is masked by a neighbouring mechanism is not a guard.
ad="$work/armdirect"; rm -rf "$ad"; mkdir -p "$ad/.claude"; rm -f "$work/arm.past"
HOME="$ad" bash -c '
  . "'"$ROOT"'/scripts/lib/common.sh"
  adb_settings_lock_take || exit 9
  kill -TERM $$
  : > "'"$work"'/arm.past"
'
ad_rc=$?
[ ! -f "$work/arm.past" ] && ok \
  || bad "an un-deferred TERM must be fatal — nothing after it may run"
[ "$ad_rc" -eq 143 ] && ok \
  || bad "...and must exit with the signal's own status, which is what the armed handler adds over bash's default (got $ad_rc)"
[ -e "$(adb_settings_lock_path "$ad")" ] && \
  bad "...and must release the lock on its way out — without the armed handler bash dies with the lock still held" || ok

# --- the lock is released WHEN THE PHASE ENDS, not merely when the process does -------------------
#
# A STRUCTURAL PIN, and the reason it has to be one is worth stating: the EXIT trap releases the
# lock at process exit, so deleting the explicit release is invisible to every assertion made after
# the run finishes — which is every behavioural assertion available here. Both rows covering these
# call sites were observed staying GREEN for exactly that reason before this pin existed.
#
# The explicit call is not redundant. `install.sh` goes on to install the other agents and to prune
# retired payloads after the Claude phase; without it the settings lock would be held for the whole
# remaining process, blocking a concurrent `baseline update` far longer than the window it guards.
# What the trap covers is the ABNORMAL exit; what this covers is the ordinary one.
[ "$(grep -c 'adb_settings_lock_drop' "$ROOT/install.sh")" -eq 1 ] && ok \
  || bad "install.sh must release the settings lock explicitly when the Claude phase ends — the EXIT trap covers a crash, not a phase boundary"
[ "$(grep -c 'adb_settings_lock_drop' "$ROOT/uninstall.sh")" -eq 1 ] && ok \
  || bad "uninstall.sh must release the settings lock explicitly when the Claude phase ends, for the same reason"

# --- an uninstall with no Claude state is DONE, not blocked ---------------------------------------
#
# The lock directory is nested inside ~/.claude, so on a home that never had one — a clean machine,
# or someone who installed only Codex or Gemini — `adb_update_lock` cannot create it and fails
# exactly as a contended lock does. That reported "an install is writing" over a home with no
# Claude state at all, and ended the run "INCOMPLETE".
bare_home="$work/barehome"; rm -rf "$bare_home"; mkdir -p "$bare_home"
HOME="$bare_home" bash "$ROOT/uninstall.sh" --agent claude >"$work/bare.log" 2>&1 && ok \
  || bad "an uninstall on a home with no ~/.claude must succeed — there is nothing to remove"
grep -qi "INCOMPLETE" "$work/bare.log" && \
  bad "...and must not report the run INCOMPLETE" || ok
grep -qi "an install is writing" "$work/bare.log" && \
  bad "...and must not blame a concurrent install for an absent directory" || ok
[ -e "$bare_home/.claude" ] && \
  bad "...and must not CREATE ~/.claude in order to lock it — an uninstall may not materialise the tree it removes" || ok

# --- a version skip returns the RECORD's status ----------------------------------------------------
#
# `_adb_record_skip` returns non-zero only when it could neither publish the replacement receipt nor
# remove the stale one, which leaves the prior `installed` rows able to authorise a removal. A
# branch that discarded that status let an automatic self-heal report success over it.
#
# A STRUCTURAL PIN for the propagation, and the reason is measured rather than assumed: the only
# portable way to make the invalidator's `rm -f` fail is a read-only parent directory, and that same
# condition makes the LOCK's `mkdir` fail first — so the run never reaches the receipt. The
# behavioural half that IS drivable is asserted below it.
[ "$(grep -c '_adb_record_skip skipped-[a-z-]* .*|| skiprc=\$?' "$ROOT/install.sh")" -eq 2 ] && ok \
  || bad "both version-skip branches must capture _adb_record_skip's status, not discard it"
[ "$(grep -c 'return "\$skiprc"' "$ROOT/install.sh")" -eq 2 ] && ok \
  || bad "...and both must RETURN it — capturing a status nobody returns is the same defect"
# ...and a skip that records cleanly still succeeds, which is what stops the pin above being
# satisfied by a branch that simply always fails.
okskip="$work/okskip"; rm -rf "$okskip"; mkdir -p "$okskip/.claude"
stub "2.1.100 (Claude Code)"
HOME="$okskip" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1 && ok \
  || bad "a below-floor skip whose receipt WAS written must still succeed"

# --- a skip whose RECORD could not be written says so, on both non-writing paths -----------------
#
# The receipt is the entire reason a skip is retried rather than frozen into a permanent absence
# (D98), and `_adb_carry_rows` may have relinquished ownership on the way here — so a surviving
# `installed` record still claims keys this run just decided are no longer ours. Silence there is
# the worst of the three outcomes: the operator is told the skip happened and never told that its
# reason, and the ownership decision behind it, did not reach disk.
inv_home="$work/invalidate"; rm -rf "$inv_home"; mkdir -p "$inv_home/.claude"
echo '{"model":"opus"}' > "$inv_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$inv_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
# The receipt path is OCCUPIED BY A DIRECTORY, so `adb_publish_json` refuses it while everything
# around it still works — the one shape that fails the publish without also breaking the fixture.
rm -f "$inv_home/.claude/.adb-settings-owned"; mkdir "$inv_home/.claude/.adb-settings-owned"
stub "2.1.100 (Claude Code)"
HOME="$inv_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/inv1.log" 2>&1
grep -qi "the skip stands, but its REASON is not recorded" "$work/inv1.log" && ok \
  || bad "a version skip whose receipt could not be published must say the reason did not reach disk"
stub "2.1.259 (Claude Code)"
HOME="$inv_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/inv2.log" 2>&1
grep -qi "\-\-no-sandbox was honoured" "$work/inv2.log" && ok \
  || bad "...and the opt-out path must say the same — it reaches the identical invalidator"
rm -rf "$inv_home/.claude/.adb-settings-owned"

# --- ownership is proved against the RECEIPT, never against the fragment -------------------------
#
# Asking the write path meant a clone whose payload is missing or damaged dropped every row even
# when each live value still equalled the one recorded for it — the keys stayed installed and
# became unremovable.
dmg="$work/damagedfrag"; rm -rf "$dmg"; mkdir -p "$dmg/.claude"
echo '{"model":"opus"}' > "$dmg/.claude/settings.json"
HOME="$dmg" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
dmg_clone="$work/dmgclone"; rm -rf "$dmg_clone"; mkdir -p "$dmg_clone"
( cd "$ROOT" && cp -R . "$dmg_clone" ) >/dev/null 2>&1; rm -rf "$dmg_clone/.git"
printf '{"sandbox":' > "$dmg_clone/agents/claude/settings.fragment.json"
HOME="$dmg" PATH="$work/bin:$PATH" bash "$dmg_clone/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$dmg/.claude/.adb-settings-owned" || true)" -eq 4 ] && ok \
  || bad "a damaged FRAGMENT must not cost ownership — every live value still equals its recorded one, and the keys would otherwise stay installed and unremovable"

# --- a container retirement deletes is no longer ours --------------------------------------------
#
# Carrying it forward would claim an empty object the operator later creates at that path.
r="$(m '{"model":"opus"}' "$work/empty-receipt")"
printf '%s' "$r" | jq '.settings' > "$work/cret.json"
adb_claude_settings_leaf_rows "$PAYLOAD" "$(printf '%s' "$r" | jq -c .wrote)" "$(printf '%s' "$r" | jq -c .created)" \
  | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" > "$work/cret-receipt"
jq 'del(.sandbox.network)' "$PAYLOAD" > "$work/cret-payload.json"
r="$(adb_claude_settings_merge "$work/cret.json" "$work/cret-payload.json" "$work/cret-receipt")"
[ "$(names "$r" created)" = "sandbox,sandbox.credentials" ] && ok \
  || bad "a container retirement emptied must be dropped from ownership; created: $(names "$r" created)"

# --- a rollback restores the SYMLINK, not the bytes behind it ------------------------------------
grep -qF 'ln -s "$link_target" "$settings"' "$ROOT/install.sh" && ok \
  || bad "the rollback must restore a symlink destination as a symlink — the pre-image is dereferenced bytes, and writing them back loses the topology permanently"

# --- the opt-out rechecks what it carries --------------------------------------------------------
#
# `--no-sandbox` preserves ownership so an earlier install is not orphaned, but carrying it BLINDLY
# kept claiming a leaf the operator had since deleted — and if they later recreated that value by
# hand, uninstall would remove it as ours. A divergence relinquishes the surface, and the opt-out
# is not an exception.
oo_home="$work/optoutrecheck"; rm -rf "$oo_home"; mkdir -p "$oo_home/.claude"
echo '{"model":"opus"}' > "$oo_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$oo_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$oo_home/.claude/.adb-settings-owned")" -eq 4 ] && ok || bad "precondition: the install should own four leaves"
# unchanged: --no-sandbox keeps ownership, so an earlier install is not orphaned
HOME="$oo_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$oo_home/.claude/.adb-settings-owned")" -eq 4 ] && ok \
  || bad "--no-sandbox over an UNCHANGED install must keep its ownership rows"
# the SAME rule governs the version skips, which is the finding one path over: a below-floor or
# unprobeable run must not keep claiming a leaf the operator has since changed.
skip_home="$work/skiprecheck"; rm -rf "$skip_home"; mkdir -p "$skip_home/.claude"
echo '{"model":"opus"}' > "$skip_home/.claude/settings.json"
HOME="$skip_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
jq 'del(.sandbox.enabled)' "$skip_home/.claude/settings.json" > "$work/sk.json" && mv "$work/sk.json" "$skip_home/.claude/settings.json"
stub "2.1.100 (Claude Code)"
HOME="$skip_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$skip_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "a below-floor skip over a DIVERGED install must relinquish ownership, exactly as the opt-out does"
stub "2.1.259 (Claude Code)"

# settings that cannot be READ are inability to prove, and drop the rows too
unread_home="$work/unreadable"; rm -rf "$unread_home"; mkdir -p "$unread_home/.claude"
echo '{"model":"opus"}' > "$unread_home/.claude/settings.json"
HOME="$unread_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
rm -f "$unread_home/.claude/settings.json"
HOME="$unread_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$unread_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "an absent settings.json is inability to prove ownership and must drop the carried rows"
# ...but one that EXISTS and cannot be READ OR PARSED is a different fact, and this rule is the
# REVERSE of the one that stood here. It used to require the rows dropped, on the reasoning that an
# unprovable claim must not be kept — and the consequence was worse than the premise: the run
# published a skip receipt with NO ownership rows while every sandbox key stayed installed, so
# uninstall could never remove them and the next install read them as the operator's and refused.
#
# Keeping them is safe because removal is value-gated independently: a recorded leaf is deleted only
# while its live value still equals the recorded one, so a retained row can never delete something
# the operator put there. An ABSENT or EMPTY file stays a relinquishment, because no file means no
# keys and there is genuinely nothing left to own.
bad_home="$work/unparseable"; rm -rf "$bad_home"; mkdir -p "$bad_home/.claude"
echo '{"model":"opus"}' > "$bad_home/.claude/settings.json"
HOME="$bad_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
bad_rows="$(grep -c "^leaf$ADB_TAB" "$bad_home/.claude/.adb-settings-owned")"
printf '{"sandbox": \n' > "$bad_home/.claude/settings.json"
HOME="$bad_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/bad.log" 2>&1 && \
  bad "an opt-out over settings that cannot be parsed must FAIL — writing a rowless receipt there leaves every installed key unremovable" || ok
[ "$(grep -c "^leaf$ADB_TAB" "$bad_home/.claude/.adb-settings-owned")" -eq "$bad_rows" ] && ok \
  || bad "...and must keep every carried row: ownership was neither proved nor given up, and removal is value-gated anyway"
grep -qi "neither proved nor" "$work/bad.log" && ok \
  || bad "...and must say which of the two it is, rather than reporting a relinquishment it did not make"

# diverged: the surface is the operator's, so the opt-out records the choice without claiming it
jq 'del(.sandbox.enabled)' "$oo_home/.claude/settings.json" > "$work/oo.json" && mv "$work/oo.json" "$oo_home/.claude/settings.json"
HOME="$oo_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/oo.log" 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$oo_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "--no-sandbox over a DIVERGED install must relinquish ownership, or a value the operator recreates by hand is later deleted as ours"
[ "$(adb_claude_settings_disposition "$oo_home/.claude/.adb-settings-owned")" = skipped-optout ] && ok \
  || bad "...and must still record the opt-out itself"

# --- an empty or absent settings.json is SUBSTITUTED, never created in place ---------------------
#
# `echo '{}' > "$settings"` follows a symlink, so a dangling link had its target created before the
# publish replaced the link — a write outside ~/.claude from a path whose design is rename-only.
sym_home="$work/symhome"; rm -rf "$sym_home"; mkdir -p "$sym_home/.claude"
ln -s "$sym_home/outside-target.json" "$sym_home/.claude/settings.json"
HOME="$sym_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ -e "$sym_home/outside-target.json" ] && bad "a dangling settings symlink must not have its target created — the publish is rename-only for exactly this reason" || ok
# ...and a HOME with no settings.json at all still installs.
none_home="$work/nonehome"; rm -rf "$none_home"; mkdir -p "$none_home/.claude"
HOME="$none_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
jq -e '.sandbox.enabled == true' "$none_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "an absent settings.json must still receive the fragment"

# --- a failed retirement prune must not be followed by an ownership-free receipt -----------------
#
# A `skipped-blocked` receipt carries no rows, so writing one after a prune that could not be
# published leaves the retired key installed with nothing able to remove it.
# A STRUCTURAL PIN on the abort itself, not on the comment beside it: driving this needs a
# settings publish that fails while the receipt publish would succeed, and every fixture that
# blocks the one blocks the other. Pinning the comment would have been worse than useless — it
# stays green while the `return` it describes is removed.
grep -qF 'return 1   # prune-abort' "$ROOT/install.sh" && ok \
  || bad "a prune that could not be published must abort before replacing the receipt, not leave the retired key unrecorded"

# --- a damaged FRAGMENT is refused, not read as "ships nothing" ----------------------------------
#
# A payload that is non-empty but holds only whitespace slurps to `[]`, and the old `// {}` turned
# that into an empty fragment — so an established install classified EVERY recorded leaf as
# retired, removed the protections, and published a receipt whose digest made the damaged file
# look current.
for frag in '   ' '' '{"a":1}{"b":2}' 'null' 'false' '[1]' '"str"'; do
  printf '%s\n' "$frag" > "$work/badfrag.json"
  if adb_claude_settings_merge "$work/installed.json" "$work/badfrag.json" "$work/installed-receipt" >/dev/null 2>&1
  then bad "a fragment of [$frag] must be REFUSED, never read as shipping nothing"
  else ok; fi
done
# ...and removal is unaffected, because it never reads the payload at all.
adb_claude_settings_merge "$work/installed.json" "$work/badfrag.json" "$work/installed-receipt" --remove >/dev/null 2>&1 \
  && ok || bad "removal must still ignore the payload entirely"

# --- provenance names the clone that LAST WROTE the receipt --------------------------------------
#
# `source` is not ownership and must not be carried forward: a receipt that kept naming clone A
# after clone B took the install over would make B's own uninstall refuse B's settings as somebody
# else's — the exact failure the source row was added to prevent, one clone over.
prov_home="$work/provhome"; rm -rf "$prov_home"; mkdir -p "$prov_home/.claude"
echo '{"model":"opus"}' > "$prov_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$prov_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(adb_claude_settings_receipt_source "$prov_home/.claude/.adb-settings-owned")" = "$ROOT" ] && ok \
  || bad "an install must record its own clone as the receipt source"
clone_b2="$work/cloneB2"; rm -rf "$clone_b2"; mkdir -p "$clone_b2"
( cd "$ROOT" && cp -R . "$clone_b2" ) >/dev/null 2>&1; rm -rf "$clone_b2/.git"
HOME="$prov_home" PATH="$work/bin:$PATH" bash "$clone_b2/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1
[ "$(adb_claude_settings_receipt_source "$prov_home/.claude/.adb-settings-owned")" = "$clone_b2" ] && ok \
  || bad "a non-writing path must refresh the source to the clone that wrote it, not carry the previous one"
[ "$(grep -c "^leaf$ADB_TAB" "$prov_home/.claude/.adb-settings-owned")" -eq 4 ] && ok \
  || bad "refreshing the source must not drop the ownership rows"
[ "$(grep -c "^source$ADB_TAB" "$prov_home/.claude/.adb-settings-owned")" -eq 1 ] && ok \
  || bad "a receipt must carry exactly one source row"

# ...and the no-jq path refreshes it too. Every primitive that render needs is grep and printf, so
# returning early without doing it leaves a receipt naming the PREVIOUS clone while the root-doc
# link names this one — and an uninstall from here that also lacks jq removes that link before
# failing, so the retry it advises rejects the receipt as somebody else's.
grep -qF 'PROVENANCE IS STILL REFRESHED' "$ROOT/install.sh" && ok \
  || bad "the no-jq path must refresh the receipt source — none of that render needs jq"

# --- a refusal that cannot be recorded must not leave the old claim standing ---------------------
#
# Returning success left the previous `installed` receipt in place with a matching digest, so the
# refusal was never re-reported and its ownership rows could still authorise a removal.
# A STRUCTURAL PIN, and named as one. Driving the REMOVAL behaviourally needs a publish that fails
# while the subsequent `rm` succeeds, and the temp path is PID-derived — every fixture that breaks
# the one breaks the other. (The branch ABOVE it is drivable, and is: see the occupied-receipt
# fixture earlier in this file.) What is checkable here is that the failure path invalidates rather
# than returning success, and that it fails loudly when it cannot.
#
# ONE SITE, and the pin depends on that. The blocked-refusal path used to carry its own copy of
# this body, so this unanchored grep matched either one and the mutation row covering it stayed
# green with the other still answering — the row could not fail. Every failed-publish path now
# routes through `_adb_invalidate_stale_receipt`; a second copy would silently disarm this pin
# again, so the count is asserted, not assumed.
[ "$(grep -cF 'if rm -f "$receipt"; then' "$ROOT/install.sh")" -eq 1 ] && ok \
  || bad "a refusal whose record could not be published must remove the previous ownership record through the ONE shared invalidator — a second copy disarms the pin below"
awk '/stale ownership record could not be/{print "loud"; exit}' "$ROOT/install.sh" | grep -q loud && ok \
  || bad "...and must fail loudly when even that removal is impossible"

# --- the pinned model says what it omitted, on EVERY path ----------------------------------------
#
# The omission is security-relevant, and the branch that lacks jq is precisely where going unsaid
# matters most.
# A STRUCTURAL PIN, and named as one: driving the pinned installer without jq needs a published
# artifact and belongs to check-pinned-install.sh. What is checkable here is WHERE the line sits.
# Inside the `else` it is indented six spaces; at the loop body level it is four — and only the
# second prints on both paths.
grep -qE '^    _pi_say "  sandbox  NOT written' "$ROOT/scripts/lib/pinned-install.sh" && ok \
  || bad "the pinned sandbox omission must sit at the loop body level, not inside the jq-success branch — the degraded path is where an unsaid omission matters most"
grep -qE '^      _pi_say "  sandbox  NOT written' "$ROOT/scripts/lib/pinned-install.sh" && \
  bad "the pinned sandbox omission is indented inside a branch — it will not print without jq" || ok

# --- a SKIP must never discard ownership of keys already written ---------------------------------
#
# "Write no new keys" is not "forget the ones already there". A CLI that becomes unprobeable, or is
# downgraded below the floor, must not replace an `installed` receipt with an empty one while the
# values stay in settings.json — uninstall could then never remove them, and the next install would
# read them as the operator's and record an empty ownership set for good.
for d in unprobeable belowfloor; do
  sk_home="$work/skip-$d"; mkdir -p "$sk_home/.claude"
  cp "$work/installed.json" "$sk_home/.claude/settings.json"
  cp "$work/installed-receipt" "$sk_home/.claude/.adb-settings-owned"
  case "$d" in
    unprobeable) sk_path="/usr/bin:/bin" ;;
    belowfloor)  stub "2.1.100 (Claude Code)"; sk_path="$work/bin:/usr/bin:/bin" ;;
  esac
  HOME="$sk_home" PATH="$sk_path" bash "$ROOT/install.sh" --agent claude --no-hooks >"$work/skip-$d.log" 2>&1
  [ "$(grep -c "^leaf$ADB_TAB" "$sk_home/.claude/.adb-settings-owned" 2>/dev/null || true)" -eq 4 ] && ok \
    || bad "a '$d' skip must carry the previous receipt's leaf rows forward — dropping them strands every key it just declined to touch"
  # ...and it still records WHICH skip, so the retry/opt-out distinction survives.
  case "$(adb_claude_settings_disposition "$sk_home/.claude/.adb-settings-owned")" in
    skipped-unprobeable|skipped-below-floor) ok ;;
    *) bad "a '$d' skip must still record its disposition" ;;
  esac
done
stub "2.1.259 (Claude Code)"

# --- --no-sandbox is recorded even without jq ----------------------------------------------------
# A missing jq is a supported degraded environment, and the opt-out receipt is plain text. If the
# flag went unrecorded there, the first update after jq arrived would apply the fragment over a
# choice the operator made by contract.
nojq_home="$work/nojq"; mkdir -p "$nojq_home/.claude"
# THE SAME ENVIRONMENT MINUS jq, built by mirroring every PATH directory as symlinks and omitting
# only `jq`. Dropping jq's whole directory is not equivalent — on this machine jq lives in
# /usr/bin beside `sed` and `mktemp`, so removing it starves the installer's own CRLF bootstrap
# scan and the run would test the fixture rather than the flag.
nojq_bin="$work/nojqbin"; mkdir -p "$nojq_bin"
printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    [ "$b" = "jq" ] && continue
    [ -e "$nojq_bin/$b" ] && continue
    [ -x "$f" ] && ln -s "$f" "$nojq_bin/$b" 2>/dev/null
  done
done
nojq_path="$nojq_bin"
if PATH="$nojq_path" command -v jq >/dev/null 2>&1; then
  printf 'NOTE: jq is still reachable in the mirrored PATH — skipping the no-jq opt-out case\n' >&2
elif ! PATH="$nojq_path" command -v sed >/dev/null 2>&1; then
  printf 'NOTE: the mirrored PATH is missing core tools — skipping the no-jq opt-out case\n' >&2
else
  HOME="$nojq_home" PATH="$nojq_path" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >"$work/nojq.log" 2>&1
  [ "$(adb_claude_settings_disposition "$nojq_home/.claude/.adb-settings-owned")" = skipped-optout ] && ok \
    || bad "--no-sandbox must be recorded even when jq is absent — its receipt is plain text, and an unrecorded opt-out is overridden by the next update"
fi

# --- the settings temp file is never world-readable, even for an instant -------------------------
# It holds the WHOLE merged settings, unrelated `env` entries included, and a predictable PID-named
# file under a traversable ~/.claude is readable by another user for as long as that window lasts.
# A SOURCE PIN, and named as one: the temp file is gone by the time any assertion could stat it, so
# what is checkable is that the creation is restricted. Pinned to the EXACT line — a bare
# `grep umask 077` also matched the pre-image snapshot added later and went on matching after the
# line under test had been mutated away.
grep -qF '( umask 077; : > "$tmp" )' "$ROOT/install.sh" && ok \
  || bad "the settings temp file must be created restricted BEFORE it is populated, not chmod'd after the write"
grep -qF '( umask 077; : > "$tmp" )' "$ROOT/uninstall.sh" && ok \
  || bad "uninstall's settings temp file must be created restricted too — it holds the same whole document"

# --- a receipt that cannot be published ROLLS THE SETTINGS BACK ----------------------------------
#
# The receipt is checked and rendered before anything is published, but publishing it can still
# fail after the settings rename succeeded. Settings with no receipt are the one unrecoverable
# state: the next install reads those values as the operator's and records nothing, after which
# uninstall can never remove them. So the failure path must undo the write, not warn past it.
rb_home="$work/rollback"; mkdir -p "$rb_home/.claude"
printf '{"model":"opus"}\n' > "$rb_home/.claude/settings.json"
cp "$rb_home/.claude/settings.json" "$work/rollback-pristine.json"
rb_repo="$work/rollbackrepo"; mkdir -p "$rb_repo"
( cd "$ROOT" && cp -R . "$rb_repo" ) >/dev/null 2>&1; rm -rf "$rb_repo/.git"
# Fault the receipt publish ONLY — the settings publish must still succeed, or this would prove
# nothing about the ordering it exists to test.
python3 - "$rb_repo/install.sh" <<'RBPY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('  if ! adb_publish_json "$rtmp" "$receipt"; then',
            '  if ! { rm -f "$rtmp"; false; }; then',1)
open(p,'w').write(s)
RBPY
stub "2.1.259 (Claude Code)"
HOME="$rb_home" PATH="$work/bin:$PATH" bash "$rb_repo/install.sh" --agent claude --no-hooks >"$work/rollback.log" 2>&1
if diff -q <(jq -S . "$rb_home/.claude/settings.json") <(jq -S . "$work/rollback-pristine.json") >/dev/null 2>&1; then ok
else bad "a receipt that cannot be published must ROLL BACK the settings — applied keys with no ownership record can never be removed"; fi
grep -qi "ROLLED BACK" "$work/rollback.log" && ok || bad "the rollback must be reported, not silent"

# --- `baseline update` must NOTICE a pending surface (bin/baseline) ------------------------------
#
# The `current` + links-OK path exits "nothing to do" without consulting the settings at all, so
# the CLI upgrade that clears the floor — the one transition the whole detect-skip-say design
# exists for — moved nothing that path was looking at. `adb_settings_pending` is the third
# question that fixes it, and it is a predicate whose failure mode is silence: answering "no"
# forever looks exactly like answering "no" correctly.
#
# Driven by SOURCING bin/baseline's predicate rather than running the whole updater: the updater
# needs a git clone, a network classification and a lock, none of which this claim depends on.
pending() {   # pending <disposition> <stub-version> [settings-file] [carry] -> 0 if pending
  local disp="$1" ver="$2" live="${3:-}" carry="${4:-}" ph="$work/pending-home"
  rm -rf "$ph"; mkdir -p "$ph/.claude"
  ln -s "$ROOT/agents/claude/CLAUDE.md" "$ph/.claude/CLAUDE.md"
  [ -n "$live" ] && cp "$live" "$ph/.claude/settings.json"
  if [ "$disp" = installed ]; then
    # A CURRENT installed receipt: its leaf set must equal the payload's, or `pending` correctly
    # reports it stale and this case would pass for the wrong reason.
    adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)" \
      | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" \
      > "$ph/.claude/.adb-settings-owned"
  elif [ "$disp" != none ]; then
    # `carry` renders the skip or opt-out WITH the previous install's ownership rows, which is what
    # those dispositions really look like on disk — `_adb_record_skip` and the opt-out both carry
    # them forward deliberately. A rowless fixture cannot reach the live-divergence question at all,
    # which is why every case here used to pass without exercising it.
    if [ "$carry" = carry ]; then
      adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)" \
        | adb_claude_settings_receipt_render "$disp" - "$FLOOR" "$(adb_sha256 "$PAYLOAD")" \
        > "$ph/.claude/.adb-settings-owned"
    else
      : | adb_claude_settings_receipt_render "$disp" - "$FLOOR" > "$ph/.claude/.adb-settings-owned"
    fi
  fi
  stub "$ver"
  HOME="$ph" PATH="$work/bin:$PATH" bash -c '
    . "'"$ROOT"'/scripts/lib/common.sh"
    SRC="'"$ROOT"'"
    eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
    adb_settings_pending "$SRC"'
}
# ASSERT THE FUNCTION IS THERE FIRST. Three of the six cases below are NEGATIVE, and a
# `command not found` returns exactly the non-zero status they treat as a pass — so without this
# the whole block would go green against a `bin/baseline` that had lost the predicate entirely.
bash -c '. "'"$ROOT"'/scripts/lib/common.sh"
  eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
  command -v adb_settings_pending >/dev/null' && ok \
  || bad "adb_settings_pending must be extractable from bin/baseline — the negative cases below cannot tell its absence from a correct 'no'"

pending none            "2.1.259 (Claude Code)" && ok || bad "an install predating this surface (no receipt) must be PENDING — that is how existing installs receive it"
pending skipped-below-floor "2.1.259 (Claude Code)" && ok || bad "a below-floor skip must become PENDING once the CLI clears the floor — the transition the design exists for"
pending skipped-unprobeable "2.1.259 (Claude Code)" && ok || bad "an unprobeable skip must become PENDING once a probeable CLI is on PATH"
pending skipped-optout  "2.1.259 (Claude Code)" && bad "an explicit --no-sandbox opt-out must NEVER be pending — self-heal would overrule a supported choice on every session" || ok
pending installed "2.1.259 (Claude Code)" "$PAYLOAD" && bad "an installed surface must not be pending" || ok

# ...and a matching digest is NOT the whole answer: the LIVE file is asked too. An operator who
# edits a recorded leaf has taken the surface over, and until the installer OBSERVES that it never
# records the ownership-free refusal — so an edit made, left through an update, and later reverted
# by hand ended with uninstall deleting the restored value as installer-owned.
pending installed "2.1.259 (Claude Code)" "$PAYLOAD" && \
  bad "an installed surface whose recorded leaves all still match must not be pending" || ok
jq '.sandbox.enabled = false' "$PAYLOAD" > "$work/pend-edited.json"
pending installed "2.1.259 (Claude Code)" "$work/pend-edited.json" && ok \
  || bad "an installed surface whose recorded leaf the operator EDITED must be pending once, so the installer can observe the divergence and relinquish"
printf 'not json' > "$work/pend-broken.json"
# ...and an installed surface stops being current when the CLI stops honouring it. A downgrade below
# the floor touches neither the payload nor the live file, so digest and rows both still match while
# the credential protections the floor exists for may no longer be applied at all.
pending installed "2.1.100 (Claude Code)" "$PAYLOAD" && ok \
  || bad "an installed surface whose CLI has been downgraded BELOW the floor must be pending once, so the installer can record and surface the skip"
pending installed "2.1.259 (Claude Code)" "$PAYLOAD" && \
  bad "...but one whose CLI still clears the floor must stay not-pending" || ok

pending installed "2.1.259 (Claude Code)" "$work/pend-broken.json" && \
  bad "an unreadable settings file must NOT read as divergence — 'cannot tell' becomes a repair loop that re-runs the installer every session" || ok

# --- and EVERY disposition that carries rows is asked the same question -----------------------------
#
# A skip and an opt-out deliberately keep the previous install's ownership rows, and those rows were
# rechecked only inside the installer — so an operator could edit an owned leaf, run the automatic
# update while it was divergent, restore the value later, and have uninstall delete it as ours,
# because nothing ever invoked the installer to relinquish. Pending once is enough: self-heal passes
# `--no-sandbox` for an opt-out and re-takes the version skip otherwise, so no policy key is newly
# applied by the visit.
pending skipped-optout "2.1.259 (Claude Code)" "$PAYLOAD" carry && \
  bad "an opt-out whose carried rows all still match must NOT be pending — that would re-run the installer every session over a supported choice" || ok
pending skipped-optout "2.1.259 (Claude Code)" "$work/pend-edited.json" carry && ok \
  || bad "an opt-out whose carried rows have DIVERGED must be pending once, so the installer can relinquish them — it is re-run with --no-sandbox, so the opt-out survives"
pending skipped-below-floor "2.1.100 (Claude Code)" "$work/pend-edited.json" carry && ok \
  || bad "a below-floor skip whose carried rows have diverged must be pending even though the CLI is STILL below the floor — the version question is not the ownership question"
pending skipped-unprobeable "2.1.100 (Claude Code)" "$work/pend-edited.json" carry && ok \
  || bad "an unprobeable skip whose carried rows have diverged must be pending for the same reason"
pending skipped-below-floor "2.1.100 (Claude Code)" "$PAYLOAD" carry && \
  bad "...but a below-floor skip whose rows all still match must stay not-pending while the CLI is below the floor" || ok

# --- a receipt naming ANOTHER clone is never current -----------------------------------------------
#
# The failed-takeover state leaves this clone's root link paired with the previous clone's record.
# Uninstall now correctly refuses a foreign record, so a currency check that never compares `source`
# leaves the keys installed and removable by neither clone while the update reports the install
# healthy. The installer rewrites `source` on every path, so one visit converges.
fs_home="$work/foreignsrc"; rm -rf "$fs_home"; mkdir -p "$fs_home/.claude"
ln -s "$ROOT/agents/claude/CLAUDE.md" "$fs_home/.claude/CLAUDE.md"
cp "$PAYLOAD" "$fs_home/.claude/settings.json"
# Everything about it is current EXCEPT the source, which names somebody else. The renderer does
# not invent a source row — every caller pipes one in — so the fixture supplies it the same way.
{ adb_claude_settings_source_row "/some/other/clone"
  adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)"; } \
  | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" \
  > "$fs_home/.claude/.adb-settings-owned"
[ "$(adb_claude_settings_receipt_source "$fs_home/.claude/.adb-settings-owned")" = "/some/other/clone" ] && ok \
  || bad "precondition: the fixture receipt must actually record another clone as its source"
stub "2.1.259 (Claude Code)"
if HOME="$fs_home" PATH="$work/bin:$PATH" bash -c '
    . "'"$ROOT"'/scripts/lib/common.sh"
    SRC="'"$ROOT"'"
    eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
    adb_settings_pending "$SRC"'
then ok; else bad "a receipt whose source names another clone must be PENDING — otherwise provenance is never refreshed and uninstall refuses it from both clones"; fi

# ...unless the PAYLOAD ITSELF changed since it was applied. Currency is a digest question: a leaf
# the operator already owned is never recorded, so a path-set comparison reports pending forever
# and re-runs the installer every session; and changing a shipped VALUE leaves the path set
# identical, so the same comparison never notices a payload a plain `git pull` just changed.
pending_receipt() {   # pending_receipt <home> <payload-digest>
  adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)" \
    | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$2" > "$1/.claude/.adb-settings-owned"
  # AND THE LIVE FILE THE RECEIPT DESCRIBES. An `installed` receipt whose recorded leaves are
  # nowhere in settings.json is not "installed and current" — it is provable divergence, and since
  # that became pending-once these fixtures were asserting a state that cannot exist.
  cp "$PAYLOAD" "$1/.claude/settings.json"
}
ask_pending() {       # ask_pending <home>
  HOME="$1" PATH="$work/bin:$PATH" bash -c '
    . "'"$ROOT"'/scripts/lib/common.sh"
    eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
    adb_settings_pending "'"$ROOT"'"'
}
stub "2.1.259 (Claude Code)"

# (a) the payload MOVED — a value changed, the path set did not.
moved="$work/movedhome"; rm -rf "$moved"; mkdir -p "$moved/.claude"
ln -s "$ROOT/agents/claude/CLAUDE.md" "$moved/.claude/CLAUDE.md"
pending_receipt "$moved" "0000000000000000000000000000000000000000000000000000000000000000"
ask_pending "$moved" && ok \
  || bad "a payload whose CONTENT changed must be PENDING — a value-only change leaves the leaf paths identical, so a path-set comparison never applies it"

# (b) an operator-owned leaf was skipped, so it is missing from the receipt — this must NOT make
# the surface pending forever, re-running the installer on every session.
skipped="$work/skippedhome"; rm -rf "$skipped"; mkdir -p "$skipped/.claude"
ln -s "$ROOT/agents/claude/CLAUDE.md" "$skipped/.claude/CLAUDE.md"
{ printf 'disposition installed\nversion 9.9.9\nfloor %s\npayload %s\n' "$FLOOR" "$(adb_sha256 "$PAYLOAD")"
  adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s . | jq -c '.[1:]')" \
    | grep "^leaf$ADB_TAB"; } > "$skipped/.claude/.adb-settings-owned"
cp "$PAYLOAD" "$skipped/.claude/settings.json"
ask_pending "$skipped" && bad "a leaf the operator already owned is never recorded — that must NOT report the surface pending on every update, or the installer re-runs and reports a repair every session" || ok

# (c) a receipt predating the digest field is unknown, and unknown must mean pending ONCE.
nodigest="$work/nodigesthome"; rm -rf "$nodigest"; mkdir -p "$nodigest/.claude"
ln -s "$ROOT/agents/claude/CLAUDE.md" "$nodigest/.claude/CLAUDE.md"
pending_receipt "$nodigest" "-"
ask_pending "$nodigest" && ok || bad "a receipt with no payload digest is UNKNOWN, and unknown must be pending — never trusted forever on no evidence"

# ...unless its recorded leaf set no longer matches the payload. A plain `git pull` of the
# install-source clone can add or retire a fragment leaf without touching one installed symlink,
# and the fast path exits before anything else would notice.
# A CURRENT receipt — right digest — is not pending, so the fast path stays fast.
current_home="$work/currenthome"; rm -rf "$current_home"; mkdir -p "$current_home/.claude"
ln -s "$ROOT/agents/claude/CLAUDE.md" "$current_home/.claude/CLAUDE.md"
pending_receipt "$current_home" "$(adb_sha256 "$PAYLOAD")"
ask_pending "$current_home" && bad "a receipt recording THIS payload's digest must not be pending" || ok
pending skipped-below-floor "2.1.100 (Claude Code)" && bad "a below-floor skip must stay put while the CLI is STILL below the floor" || ok
stub "2.1.259 (Claude Code)"

# --- a blocked refusal records the payload it refused, so it is not retried forever --------------
#
# Carrying the PRIOR digest (or `-` on a first install) leaves `adb_settings_pending` seeing an
# unknown digest on every update, re-running the installer and reporting a repair that changed
# nothing — the loop that reporting pending-forever already caused once.
blk_home="$work/blockedhome"; rm -rf "$blk_home"; mkdir -p "$blk_home/.claude"
echo '{"sandbox":{"enabled":false}}' > "$blk_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$blk_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
[ "$(adb_claude_settings_disposition "$blk_home/.claude/.adb-settings-owned")" = skipped-blocked ] && ok \
  || bad "a blocked install must record skipped-blocked"
[ "$(adb_claude_settings_payload_digest "$blk_home/.claude/.adb-settings-owned")" = "$(adb_sha256 "$PAYLOAD")" ] && ok \
  || bad "a blocked receipt must record the digest of the payload it REFUSED, or every update re-runs the installer and reports a repair"
[ "$(grep -c "^leaf$ADB_TAB" "$blk_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "a blocked receipt must carry no ownership rows"
ln -sf "$ROOT/agents/claude/CLAUDE.md" "$blk_home/.claude/CLAUDE.md"
if HOME="$blk_home" PATH="$work/bin:$PATH" bash -c '
    . "'"$ROOT"'/scripts/lib/common.sh"
    eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
    adb_settings_pending "'"$ROOT"'"'
then bad "a blocked receipt recording THIS payload must not be pending — that is the repair loop"; else ok; fi

# --- an uninstall from ANOTHER clone must not consume this one's settings ------------------------
#
# Two clones can each install globally: the second overwrites the first's links and its receipt.
# Running the FIRST clone's uninstaller must then leave the second's settings alone — the link half
# is already true (`adb_unlink_if_ours` refuses a link into another clone), and the settings half
# read the global receipt as proof of ownership.
two_home="$work/twoclone"; mkdir -p "$two_home/.claude"
clone_b="$work/cloneB"; mkdir -p "$clone_b"
( cd "$ROOT" && cp -R . "$clone_b" ) >/dev/null 2>&1; rm -rf "$clone_b/.git"
echo '{"model":"opus"}' > "$two_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$two_home" PATH="$work/bin:$PATH" bash "$clone_b/install.sh" --agent claude --no-hooks >/dev/null 2>&1
jq -e '.sandbox.enabled == true' "$two_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "precondition: clone B's install should have written the sandbox keys"
# Now run THIS clone's uninstaller over an install that belongs to clone B.
HOME="$two_home" bash "$ROOT/uninstall.sh" --agent claude >"$work/twoclone.log" 2>&1
jq -e '.sandbox.enabled == true' "$two_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "uninstalling from a clone that does not own ~/.claude must NOT remove another clone's sandbox settings"
grep -qi "another clone" "$work/twoclone.log" && ok || bad "leaving another clone's settings alone must be SAID, not silent"

# ...and the LEGACY path, where the receipt carries no source row at all. Since a present source row
# became the deciding evidence, the case above is answered by that row and never reaches the link
# fallback — so without this fixture the fallback had no coverage, and the mutation row aiming at it
# went red on a different assertion instead. A receipt written before provenance was recorded has
# only the link to go on, and the link says this is not ours.
legacy_home="$work/legacyclone"; rm -rf "$legacy_home"; mkdir -p "$legacy_home/.claude"
echo '{"model":"opus"}' > "$legacy_home/.claude/settings.json"
stub "2.1.259 (Claude Code)"
HOME="$legacy_home" PATH="$work/bin:$PATH" bash "$clone_b/install.sh" --agent claude --no-hooks >/dev/null 2>&1
grep -v "^source$ADB_TAB" "$legacy_home/.claude/.adb-settings-owned" > "$work/legacy.tmp" \
  && mv "$work/legacy.tmp" "$legacy_home/.claude/.adb-settings-owned"
[ -z "$(adb_claude_settings_receipt_source "$legacy_home/.claude/.adb-settings-owned" 2>/dev/null)" ] && ok \
  || bad "precondition: the legacy fixture must carry no source row"
HOME="$legacy_home" bash "$ROOT/uninstall.sh" --agent claude >"$work/legacy.log" 2>&1
jq -e '.sandbox.enabled == true' "$legacy_home/.claude/settings.json" >/dev/null 2>&1 && ok \
  || bad "a receipt with NO source row must fall back to the link — and the link says this clone does not own ~/.claude, so its settings must NOT be removed"

# --- mutation: every rule above, broken in a copy, required RED on its own witness ---------------

if [ "$MUTATION" -eq 1 ]; then
  prepare() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/scripts/lib/common.sh"; }
  prepare_payload() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/agents/claude/settings.fragment.json"; }
  prepare_install() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/install.sh"; }
  prepare_uninstall() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/uninstall.sh"; }
  prepare_pinned() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/scripts/lib/pinned-install.sh"; }
  prepare_baseline() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/bin/baseline"; }
  runner() { bash "$1/repo/scripts/check-settings-fragment.sh" 2>&1; }

  # Each row breaks ONE rule, and its witness is the assertion that claims to cover it. A row that
  # goes red elsewhere is scored as caught by accident, which is not evidence.
  # Each row breaks ONE rule of the all-or-nothing contract, and its witness is the assertion that
  # claims to cover it. A row that goes red elsewhere is scored as caught by accident.
  check_mut 'a leaf already present no longer blocks the install' \
      '          | map(. as $p | select( ( $settings | anc_ok($p) | not ) or ( $settings | present($p) ) )) ) as $blocked' \
      '          | map(. as $p | select( false )) ) as $blocked' \
      'must refuse the whole fragment'
  check_mut 'a diverged owned leaf is rewritten instead of refused' \
      '                        or ( ($settings | getpath($r.p)) != $r.v ) ))' \
      '                        or false ))' \
      'an edited owned leaf must refuse the update'
  check_mut 'removal deletes a leaf the operator edited' \
      '            elif ( .settings | getpath($p) ) == $rec.v then' \
      '            elif true then' \
      'must be KEPT on removal'
  check_mut 'removal prunes containers it never created' \
      '      | ( $created | sort_by(-length) ) as $mine' \
      '      | ( [ .settings | paths(type == "object") ] | sort_by(-length) ) as $mine' \
      "pre-existing empty container must survive"
  check_mut 'a transient skip stops owning the LEAVES it carried' \
      '    installed|skipped-optout|skipped-below-floor|skipped-unprobeable) ;;   # leaf ownership' \
      '    installed|skipped-optout) ;;   # leaf ownership' \
      'must still OWN the rows it carried forward'
  check_mut 'a transient skip stops owning the CONTAINERS it carried' \
      '    installed|skipped-optout|skipped-below-floor|skipped-unprobeable) ;;   # container ownership' \
      '    installed|skipped-optout) ;;   # container ownership' \
      'must take the containers it created'
  check_mut 'absence is decided by comparing to null again' \
      '    def present($p): (getpath($p[0:-1]) | type) == "object" and (getpath($p[0:-1]) | has($p[-1]));' \
      '    def present($p): (getpath($p) != null);' \
      'must block the install'
  check_mut 'a non-object ancestor is treated as traversable' \
      '                elif ($doc | getpath($a) | type) == "object" then "cont"' \
      '                elif true then "cont"' \
      'must not fail the merge'
  check_mut 'a blocked receipt is treated as ownership-bearing' \
      '    installed|skipped-optout|skipped-below-floor|skipped-unprobeable) ;;   # leaf ownership' \
      '    installed|skipped-optout|skipped-below-floor|skipped-unprobeable|skipped-blocked) ;;   # leaf ownership' \
      'a blocked receipt must own NOTHING'
  check_mut 'the remove-pass container cleanup skips its ancestor walk' \
      '            ( .settings | anc_ok($a) ) as $ok   # remove-pass container' \
      '            true as $ok   # remove-pass container' \
      'must not fail when a recorded container is DEEPER than the scalar'
  check_mut 'the source guard captures its newline instead of quoting it' \
      "  local _nl=\$'\\n'" \
      '  local _nl; _nl="$(printf '"'"'\\n'"'"')"' \
      'NEWLINE must be refused'
  check_mut 'a damaged fragment is read as shipping nothing' \
      '  | ( if ($frag | length) != 1 then error("the fragment must hold exactly one JSON value") else . end )' \
      '  | ( . )' \
      'must be REFUSED, never read as shipping nothing'
  check_mut 'a non-object fragment coerces to an empty one' \
      '  | ( if ($frag[0] | type) != "object" then error("the fragment must hold a JSON object") else . end )' \
      '  | ( . )' \
      'must be REFUSED, never read as shipping nothing'
  check_mut 'a refusal discards the retirement it already made' \
      '          | .wrote = [] | .created = []' \
      '          | .settings = ($cur[0]) | .pruned = [] | .kept = [] | .wrote = [] | .created = []' \
      'must still PRUNE a retired key'
  check_mut 'a prior container is carried without an owned descendant' \
      '                               | select($owns) ) )' \
      '                               | select(true) ) )' \
      'container retirement emptied must be dropped from ownership'
  check_mut 'the release is a no-op, on every path at once' \
    '  adb_update_unlock "$_lk" || _urc=$?' \
    '  :' \
    'lock must be released on the success path'
  check_mut 'the lock token is cleared before the lock is actually gone' \
    '  if [ -e "$lock" ]; then' \
    '  if false; then' \
    'must NOT report a clean release'
  check_mut 'a failed release is not reported to the operator' \
    '  if [ "$_urc" -ne 0 ]; then' \
    '  if false; then' \
    'must say so, naming the path'
  check_mut 'a refused removal leaks its synthetic payload' \
    '  owned="$(_adb_claude_settings_owned_json "$receipt")" || { rc=$?; _adb_merge_cleanup "$work_empty"; return "$rc"; }' \
    '  owned="$(_adb_claude_settings_owned_json "$receipt")" || return $?' \
    'must not leak its synthetic payload'
  check_mut 'retirement prunes every recorded container, not the ones it emptied' \
    '          | map(. as $a | select( $justpruned' \
    '          | map(. as $a | select( true or $justpruned' \
    'must SURVIVE'
  check_mut 'a failed chmod still publishes' \
    '  if [ -n "$mode" ] && ! chmod "$mode" "$tmp" 2>/dev/null; then' \
    '  if false; then' \
    'must fail the publication'
  check_mut 'an absent settings file reads as unanswerable' \
    '  [ -s "$settings" ] || return 1' \
    '  [ -s "$settings" ] || return 2' \
    'must read as DIVERGED'
  check_mut 'a row predicate treats a jq error as a malformed row' \
    '    case $? in 0) ;; 1) continue ;; *) return 20 ;; esac' \
    '    case $? in 0) ;; *) continue ;; esac' \
    'must treat jq'"'"'s 1 (false) and its 5 (error) differently'
  check_mut 'the path enumerations are not checked' \
    '  wrote_paths="$(printf '"'"'%s'"'"' "$written" | jq -c '"'"'.[]?'"'"' 2>/dev/null)" || return 1' \
    '  wrote_paths="$(printf '"'"'%s'"'"' "$written" | jq -c '"'"'.[]?'"'"' 2>/dev/null)"' \
    'must be captured AND checked before any row is printed'
  check_mut 'a per-leaf extraction failure becomes an empty value' \
    '    if ! v="$(jq -c --argjson path "$p" '"'"'getpath($path)'"'"' "$payload" 2>/dev/null)" || [ -z "$v" ]; then' \
    '    v="$(jq -c --argjson path "$p" '"'"'getpath($path)'"'"' "$payload" 2>/dev/null)"; if false; then' \
    'empty extraction must fail the writer'
  check_mut 'a damaged disposition reads as an absent receipt' \
    '  [ "$grc" -eq 0 ] || return 21' \
    '  [ "$grc" -eq 0 ] || { printf '"'"'none'"'"'; return 0; }' \
    'must FAIL, not report success'
  check_mut 'an unrecognised disposition word is answered instead of refused' \
    '    *) return 21 ;;' \
    '    *) printf '"'"'none'"'"' ;;' \
    'must be REFUSED, not answered'
  check_mut 'the lock owner write is unchecked again' \
    '  if ! ( printf '"'"'%s\n'"'"' "$token" > "$lock/owner" ) 2>/dev/null; then' \
    '  if false; then' \
    'the token is the lock'
  check_mut 'a signal is not deferred across the two publications' \
    "  trap '_ADB_SIGNAL_PENDING=143' TERM" \
    '  :' \
    'must be DEFERRED'
  check_mut 'a deferred signal is swallowed rather than honoured' \
    '  [ -n "$pending" ] || return 0' \
    '  return 0' \
    'must then be honoured, not swallowed'
  check_mut 'an unreadable receipt is reported as a damaged one' \
    '  [ "$grc" -le 1 ] || return 20' \
    '  :' \
    'must still answer 20 for a receipt it could not READ'
  check_mut 'the merge cannot tell an unreadable receipt from unparseable settings' \
    '{ rc=$?; _adb_merge_cleanup "$work_empty"; return "$rc"; }' \
    '{ _adb_merge_cleanup "$work_empty"; return 1; }' \
    'must name the damaged disposition line'
  check_mut 'the live-leaf predicate answers intact for a divergence' \
    '        | all( . as $r' \
    '        | any( . as $r' \
    'must read as DIVERGED'
  check_mut 'a signal is not trapped, so the lock outlives the run' \
    '  _adb_arm_lock_traps' \
    '  :' \
    'must release the lock on its way out'
  check_mutation_pool "check-settings-fragment" "$work/mut-lib" prepare runner 6

  check_mut_reset
  check_mut 'the payload ships filesystem.disabled as if it were hardening' \
    '"enabled": true,' \
    '"enabled": true,
    "filesystem": { "disabled": true },' \
    'must NOT ship sandbox.filesystem.disabled'
  check_mut 'the payload ships strictAllowlist' \
    '"allowedDomains": [' \
    '"strictAllowlist": true,
      "allowedDomains": [' \
    'must NOT ship sandbox.network.strictAllowlist'
  check_mut 'a credential entry silently becomes mask' \
    '{ "path": "~/.ssh", "mode": "deny" }' \
    '{ "path": "~/.ssh", "mode": "mask" }' \
    'must use mode'
  check_mut 'the credential lists become the object map a summariser described' \
    '"files": [' \
    '"files_UNUSED": [' \
    'must be an ARRAY'
  check_mutation_pool "check-settings-fragment(payload)" "$work/mut-payload" prepare_payload runner 6

  check_mut_reset
  check_mut 'the installer stops writing the fragment at all' \
    'wire_settings || src=$?' \
    'src=0' \
    'must write sandbox.enabled into the user settings'
  check_mut 'a below-floor CLI is written to anyway' \
    'if ! adb_version_ge "$version" "$floor"; then' \
    'if false; then' \
    'must write NO sandbox key'
  check_mut '--no-sandbox stops recording the choice' \
    'if [ "$WIRE_SETTINGS" -eq 0 ]; then' \
    'if false; then' \
    "must record disposition 'skipped-optout'"
  check_mut 'the receipt precheck is dropped, so the run writes then undoes' \
    'if [ -e "$receipt" ] && [ ! -f "$receipt" ]; then' \
    'if false; then' \
    'must refuse BEFORE writing'
  check_mut 'a blocked refusal records the prior digest instead of the refused one' \
    '    refused_digest="$(adb_sha256 "$payload" 2>/dev/null || printf '"'"'%s'"'"' '"'"'-'"'"')"' \
    '    refused_digest="-"' \
    'must record the digest of the payload it REFUSED'
  check_mut 'a refusal is reported as an install' \
    '  if [ "$verdict" = refuse ]; then' \
    '  if false; then' \
    'must be reported as NOT written and named'
  check_mut 'a skip discards the ownership it inherited' \
    '  carried="$(_adb_carry_rows "$receipt" "$HOME/.claude/settings.json" "$(adb_claude_settings_payload "$REPO")")"' \
    '  carried=""' \
    "must carry the previous receipt's leaf rows forward"
  check_mut 'the settings temp file is world-readable while it is written' \
    '  ( umask 077; : > "$tmp" ) ||' \
    '  ( : > "$tmp" ) ||' \
    'must be created restricted BEFORE it is populated'
  check_mut 'a receipt that cannot be published only warns' \
    '    had_settings=1' \
    '    had_settings=0' \
    'must ROLL BACK the settings'
  check_mut 'the source row is carried forward instead of refreshed' \
    '"^(leaf|container)$(printf' \
    '"^(leaf|container|source)$(printf' \
    'must carry exactly one source row'
  check_mut 'the refusal returns success with the stale record standing' \
    '  if rm -f "$receipt"; then' \
    '  if false; then' \
    'must remove the previous ownership record through the ONE shared invalidator'
  check_mut 'the no-jq path stops refreshing provenance' \
    '    # PROVENANCE IS STILL REFRESHED, because none of it needs jq — the render, the ownership rows' \
    '    # provenance is not refreshed here' \
    'no-jq path must refresh the receipt source'
  check_mut 'the opt-out carries its rows without rechecking them' \
    '    optout_rows="$(_adb_carry_rows "$receipt" "$settings" "$payload")"' \
    '    optout_rows="$(_adb_owned_rows "$receipt")"' \
    'must relinquish ownership'
  check_mut 'the settings file is initialised in place again' \
    '    synth="$(mktemp)" || { adb_info "  WARN   could not stage the settings input — sandbox settings NOT written"; return 1; }' \
    '    echo "{}" > "$settings"; synth=""' \
    'must not have its target created'
  check_mut 'a failed prune still replaces the receipt' \
    '        return 1   # prune-abort' \
    '        :   # prune-abort' \
    'must abort before replacing the receipt'
  check_mut 'the settings window is not serialized' \
    '  if ! adb_settings_lock_take; then' \
    '  if false; then' \
    'must block the HOOK writer too'
  check_mut 'the rollback writes bytes over a symlink destination' \
    '      if rm -f "$settings" && ln -s "$link_target" "$settings"; then' \
    '      if false; then' \
    'must restore a symlink destination as a symlink'
  # NO ROW for the empty-probe branch: since ownership is proved by COUNTING the rows that came
  # back `pruned`, an unparseable probe yields zero and relinquishes anyway. That branch exists for
  # its message, not for the outcome, and a row that cannot fail is worse than no row.
  check_mut 'ownership is proved against the fragment again' \
    '  probe="$(adb_claude_settings_merge "$live" "$frag" "$receipt" --remove 2>/dev/null)"; mrc=$?' \
    '  probe="$(adb_claude_settings_merge "$live" "$frag" "$receipt" 2>/dev/null)"; mrc=$?' \
    'must carry the previous receipt'"'"'s leaf rows forward'
  check_mut 'the lock is never released' \
    '  adb_settings_lock_drop' \
    '  :' \
    'must release the settings lock explicitly when the Claude phase ends'
  check_mut 'the merge decision is rendered without being read back' \
    '     || ! printf '"'"'%s'"'"' "$wrote_json" | jq -e '"'"'type == "array"'"'"' >/dev/null 2>&1 \' \
    '     || false \' \
    'BOTH must be VALIDATED as arrays'
  check_mut 'a rowless opt-out record is discarded when the replacement fails' \
    '         || [ "$(adb_claude_settings_disposition "$receipt" 2>/dev/null)" = skipped-optout ]; then' \
    '         || false; then' \
    'must keep an existing opt-out record even when it carries no rows'
  check_mut 'a still-accurate record is invalidated when its replacement fails' \
    '  if [ -n "$carried" ]; then' \
    '  if false; then' \
    'must KEEP a still-accurate record'
  check_mut 'the opt-out sibling invalidates a still-accurate record' \
    '      if [ -n "$optout_rows" ] \' \
    '      if false \' \
    'sibling must do the same'
  check_mut 'the retirement prunes before proving the receipt replaceable' \
    '      if ! mv "$receipt" "$_bprobe" 2>/dev/null; then' \
    '      if false; then' \
    'must prove the receipt is replaceable BEFORE it rewrites'
  check_mut 'a blocked refusal hands back the invalidator benign status' \
    '    return 1   # blocked-not-recorded' \
    '    return 0' \
    'must return non-zero — the invalidator'"'"'s 0 means only that no stale claim survives'
  check_mut 'a skip hands back the invalidator benign status' \
    '  return 1   # skip-relinquished' \
    '  return 0' \
    'skip whose receipt was not published must do the same'
  check_mut 'a kept-record skip reports success' \
    '    return 1   # skip-not-recorded-kept' \
    '    return 0' \
    'kept-record branch must still FAIL the run'
  check_mut 'an unknown verdict falls through to the write path' \
    '    write|refuse|remove) ;;' \
    '    write|refuse|remove|"") ;;' \
    'verdict must be one of the KNOWN values'
  check_mut 'the no-jq path persists the none sentinel' \
    '      if [ -z "$njdisp" ] || [ "$njdisp" = none ]; then' \
    '      if false; then' \
    'must refuse specifically when it reads'
  check_mut 'a refusal returns without naming what it kept' \
    '    _adb_report_settings "$result" kept "kept (no longer shipped, and you edited it since we wrote it)"' \
    '    :' \
    'must NAME the retired leaf it kept'
  check_mut 'a refusal compares against the real path it never read' \
    '    if [ "$used_synth" -eq 1 ]; then' \
    '    if false; then' \
    'must not CREATE settings.json'
  check_mut 'the retirement-and-refusal pair publishes outside the deferral' \
    '    adb_settings_lock_defer_signals   # transaction: retirement prune + refusal receipt' \
    '    :' \
    'must defer signals BEFORE it publishes the pruned settings'
  check_mut 'the hook wiring publishes outside the deferral' \
    '  adb_settings_lock_defer_signals   # transaction: hook entries + wiring receipt' \
    '  :' \
    'must defer signals BEFORE it publishes settings.json'
  check_mut 'a broken provenance refresh reports the tolerated no-jq skip' \
    '        return 1   # provenance-broken' \
    '        :' \
    'must FAIL, not return the tolerated no-jq skip'
  check_mut 'an unreadable live file is treated as a relinquishment' \
    '  if [ "$mrc" -ne 0 ]; then' \
    '  if false; then' \
    'must keep every carried row'
  check_mut 'a receipt that could not be classified is read as unparseable settings' \
    '  if [ "$mrc" -ne 0 ]; then' \
    '  if false; then' \
    'must fail, not publish an ownership-free replacement'
  check_mut 'the wrapper discards a failed lock release' \
    '  adb_settings_lock_drop || icrc=1' \
    '  adb_settings_lock_drop' \
    'must fold a failed lock release into its own status'
  check_mut 'the pruned count is normalised before it is checked' \
    '  if ! proved="$(printf '"'"'%s'"'"' "$probe" | jq -r '"'"'.pruned | length'"'"' 2>/dev/null)"; then' \
    '  proved="$(printf '"'"'%s'"'"' "$probe" | jq -r '"'"'.pruned | length'"'"' 2>/dev/null)"; if false; then' \
    'must be checked before it is normalised'
  check_mut 'the bucket reporter masks a failed read' \
    '  if ! names="$(printf '"'"'%s'"'"' "$result" | jq -r --arg b "$bucket" '"'"'.[$b] | map(join(".")) | join(", ")'"'"' 2>/dev/null)"; then' \
    '  names="$(printf '"'"'%s'"'"' "$result" | jq -r --arg b "$bucket" '"'"'.[$b] | map(join(".")) | join(", ")'"'"' 2>/dev/null)"; if false; then' \
    'must distinguish an empty bucket from a failed read'
  check_mut 'the row reader answers zero rows for a receipt it could not read' \
    '  [ "$grc" -le 1 ] || return 20' \
    '  :' \
    'must fail, not publish an ownership-free replacement'
  check_mut 'the opt-out publishes over a receipt it could not read' \
    '    if [ "$ocrc" -ne 0 ]; then' \
    '    if false; then' \
    'must fail, not publish an ownership-free replacement'
  check_mut 'a version skip publishes over a receipt it could not read' \
    '  if [ "$crc" -ne 0 ]; then' \
    '  if false; then' \
    'version skip over an unreadable receipt must fail'
  check_mut 'an unrecorded opt-out still reports a successful install' \
    '      _adb_invalidate_stale_receipt "$receipt" "--no-sandbox was honoured" || true' \
    '      return 0' \
    'must FAIL — an unrecorded opt-out is silently overridden'
  check_mut 'a version skip discards the record status' \
    '    skiprc=0; _adb_record_skip skipped-below-floor "$version" "$floor" "$receipt" || skiprc=$?' \
    '    skiprc=0; _adb_record_skip skipped-below-floor "$version" "$floor" "$receipt"' \
    'must capture _adb_record_skip'"'"'s status'
  check_mut 'a version skip captures the record status and never returns it' \
    '    return "$skiprc"' \
    '    return 0' \
    'must RETURN it'
  check_mut 'the links are replaced before the settings lock is taken' \
    '    adb_info "  WARN   another install or uninstall is writing ~/.claude — nothing was changed."' \
    '    adb_info "  WARN   another install or uninstall is writing ~/.claude — nothing was changed."; adb_link_manifest "$BACKUP_DIR" <<< "$(adb_agent_manifest claude "$REPO" "$HOME")" >/dev/null 2>&1' \
    'must be taken BEFORE the links are replaced'
  check_mut 'the carry diagnostics are captured into the row list instead of reaching the operator' \
    '    adb_info "  sandbox  ownership relinquished — $((recorded - proved)) of $recorded recorded key(s)" >&2' \
    '    adb_info "  sandbox  ownership relinquished — $((recorded - proved)) of $recorded recorded key(s)"' \
    'must be TOLD that ownership was relinquished'
  check_mut 'a carry diagnostic the fixtures do not reach loses its redirect' \
    '    adb_info "  sandbox  the live settings could not be read, so ownership was neither proved nor" >&2' \
    '    adb_info "  sandbox  the live settings could not be read, so ownership was neither proved nor"' \
    'must redirect to stderr'
  check_mut 'a skip whose record could not be published stays silent' \
    '  _adb_invalidate_stale_receipt "$receipt" "the skip stands, but its REASON is not recorded"' \
    '  :' \
    'must say the reason did not reach disk'
  check_mut 'the opt-out leaves its unpublished record unmentioned' \
    '      _adb_invalidate_stale_receipt "$receipt" "--no-sandbox was honoured"' \
    '      :' \
    'opt-out path must say the same'
  check_mut 'a version skip carries its rows unchecked' \
    '  carried="$(_adb_carry_rows "$receipt" "$HOME/.claude/settings.json" "$(adb_claude_settings_payload "$REPO")")"' \
    '  carried="$(_adb_owned_rows "$receipt")"' \
    'below-floor skip over a DIVERGED install must relinquish ownership'
  check_mutation_pool "check-settings-fragment(install)" "$work/mut-install" prepare_install runner 4

  check_mut_reset
  check_mut 'the pinned sandbox omission moves inside the jq branch' \
    '    _pi_say "  sandbox  NOT written — this file is tracked by the project, so the least-privilege"' \
    '      _pi_say "  sandbox  NOT written — this file is tracked by the project, so the least-privilege"' \
    'must sit at the loop body level'
  check_mutation_pool "check-settings-fragment(pinned)" "$work/mut-pinned" prepare_pinned runner 2

  check_mut_reset
  check_mut "uninstall's settings temp file is world-readable while it is written" \
    '  ( umask 077; : > "$tmp" ) || {' \
    '  ( : > "$tmp" ) || {' \
    "uninstall's settings temp file must be created restricted"
  check_mut 'uninstall consumes a receipt belonging to another clone' \
    '  if [ -n "$recorded" ]; then' \
    '  if false; then' \
    'must be left alone even when the root-doc link says this one'
  check_mut 'a legacy receipt with no source row skips the link fallback' \
    '  elif [ "$ours" != "1" ]; then' \
    '  elif false; then' \
    'must fall back to the link'
  check_mut 'uninstall rewrites settings.json when nothing of ours was pruned' \
    '  if [ "$_nochange" -eq 0 ]; then' \
    '  if false; then' \
    'must leave settings.json alone'
  check_mut 'a zero leaf count is taken as proof that nothing of ours is left' \
    '  if [ "$_nochange" -eq 0 ]; then' \
    "  if [ \"\$(printf '%s' \"\$result\" | jq -r '.pruned | length')\" -eq 0 ]; then" \
    'empty container this install created must still be removed'
  check_mut 'an execution error counts as a document difference' \
    '  if [ "$_nochange" -gt 1 ]; then' \
    '  if false; then' \
    'must tell an execution error from an inequality'
  check_mut 'the legacy filter status is discarded again' \
    '      if [ "$_grc" -gt 1 ]; then' \
    '      if false; then' \
    'must be run and checked on its own'
  check_mut 'an unreadable receipt source is read as absent' \
    '    return 1   # unreadable-source' \
    '    :' \
    'must not print Uninstalled over settings it never touched'
  check_mut 'an unreadable legacy receipt is unlinked anyway' \
    '    if [ -f "$_lr" ] && ! cat "$_lr" >/dev/null 2>&1; then' \
    '    if false; then' \
    'must unlink NOTHING'
  check_mut 'a failed stamp warns and carries on' \
    '        return 1   # stamp-failed' \
    '        return 0' \
    'must FAIL rather than unlink the proof it depends on'
  check_mut 'a malformed source row counts as provenance' \
    '       && [ -z "$(adb_claude_settings_receipt_source "$_lr" 2>/dev/null || true)" ]; then' \
    '       && [ -z "$(printf '"'"'%s\\n'"'"' "$_lrbody" | grep -m1 "^source$(printf '"'"'\\t'"'"')" || true)" ]; then' \
    'must be stamped like one that has none'
  check_mut 'the legacy provenance stamp is skipped' \
    '    if [ -f "$_lr" ] && _lrbody="$(cat "$_lr" 2>/dev/null)" \' \
    '    if false; then :; elif false; then \' \
    'must be stamped with this clone as its source'
  check_mut 'the hook removal republishes a document it did not change' \
    "        if jq -e --slurpfile orig \"\$settings\" '. == \$orig[0]' \"\$settings.adb.\$\$.tmp\" >/dev/null 2>&1; then" \
    '        if false; then' \
    'must leave settings.json alone'
  check_mut 'uninstall discards a failed lock release' \
    '  adb_settings_lock_drop || ucrc=1' \
    '  adb_settings_lock_drop' \
    'uninstall_claude must do the same'
  check_mut 'the probe renames run outside the deferral' \
    '  adb_settings_lock_defer_signals   # transaction: settings rewrite + receipt removal' \
    '  :' \
    'signals must already be deferred when the first one runs'
  check_mut 'the link outranks a source row that names another clone' \
    '    if [ "$recorded" != "$REPO" ]; then' \
    '    if false; then' \
    'must be left alone even when the root-doc link says this one'
  check_mut 'uninstall rewrites the settings before proving the receipt removable' \
    '  if ! mv "$receipt" "$_rprobe" 2>/dev/null; then' \
    '  if false; then' \
    'must prove the receipt can be removed BEFORE it rewrites'
  check_mut 'a no-op uninstall leaves its staged temp behind' \
    '    rm -f "$tmp"   # no-op-stage' \
    '    :' \
    'must not leave its staged temp behind'
  check_mut 'the uninstall pair publishes outside the deferral' \
    '  adb_settings_lock_defer_signals   # transaction: settings rewrite + receipt removal' \
    '  :' \
    'must defer signals BEFORE it publishes the rewritten settings'
  check_mut 'uninstall locks a home that has no Claude directory' \
    '  if [ ! -d "$HOME/.claude" ]; then' \
    '  if false; then' \
    'must succeed — there is nothing to remove'
  check_mut 'uninstall never releases the settings lock' \
    '  adb_settings_lock_drop' \
    '  :' \
    'must release the settings lock explicitly when the Claude phase ends, for the same reason'
  check_mut 'uninstall drops the ownership record when the payload is missing' \
    '  if [ ! -s "$settings" ]; then' \
    '  if [ ! -s "$settings" ] || [ ! -s "$payload" ]; then' \
    'must not delete the ownership receipt while leaving the sandbox keys installed'
  check_mutation_pool "check-settings-fragment(uninstall)" "$work/mut-uninstall" prepare_uninstall runner 4

  check_mut_reset
  check_mut 'a blocked sandbox install is reported as a repair' \
    '    if adb_settings_refused_now "$SETTINGS_PENDING"; then' \
    '    if false; then' \
    'same-HEAD repair path must ask'
  check_mut 'an installed surface stays current after a CLI downgrade' \
    '      if [ "$disp" = installed ]; then' \
    '      if false; then' \
    'downgraded BELOW the floor must be pending once'
  check_mut 'the downgrade waits behind the LINKS_OK gate' \
    '    adb_settings_downgraded_now "$SETTINGS_PENDING" "$SETTINGS_ROWS_BEFORE" && {' \
    '    false && {' \
    'must run BEFORE the LINKS_OK gate'
  check_mut 'the row count is emitted without normalising what grep produced' \
    '  case "$n" in '"''"'|*[!0-9]*) n=0 ;; esac' \
    '  :' \
    'must still be ONE integer when the receipt cannot be read'
  check_mut 'the post-pull path never asks about a downgrade' \
    '      if adb_settings_downgraded_now "$BEHIND_SETTINGS_PENDING" "$BEHIND_ROWS_BEFORE"; then' \
    '      if false; then' \
    'post-pull path must ask whether the protections were downgraded'
  check_mut 'the downgrade predicate requires the row count unchanged again' \
    '  [ "${1:-0}" -eq 1 ] || return 1' \
    '  [ "${1:-0}" -eq 1 ] || return 1; [ "$(adb_settings_row_count)" -eq "$2" ] || return 1' \
    'must NOT require the row count unchanged'
  check_mut 'the downgrade claims ownership is unchanged after relinquishing it' \
    '  if [ "${2:-0}" -gt 0 ] && [ "$(adb_settings_row_count)" -lt "$2" ]; then' \
    '  if false; then' \
    'Stale ownership was ALSO relinquished'
  check_mut 'a downgrade is reported as a relinquishment' \
    '    skipped-below-floor|skipped-unprobeable) ;;' \
    '    no-such-disposition) ;;' \
    'must decide on the DISPOSITION left behind by the heal'
  check_mut 'a receipt naming another clone is treated as current' \
    '  [ -n "$rsource" ] && [ "$rsource" != "$src" ] && return 0' \
    '  :' \
    'must be PENDING'
  check_mut 'a reconciliation is reported as a repair' \
    '        skipped-optout|skipped-below-floor|skipped-unprobeable)' \
    '        no-such-disposition)' \
    'must not report a repair'
  check_mut 'only an installed receipt is asked the live question' \
    '    installed|skipped-optout|skipped-below-floor|skipped-unprobeable)' \
    '    installed)' \
    'must be pending even though the CLI is STILL below the floor'
  check_mut 'the post-pull path never asks whether the policy was refused' \
    '      if adb_settings_refused_now "$BEHIND_SETTINGS_PENDING"; then' \
    '      if false; then' \
    'post-pull path must ask before it reports the update complete'
  check_mut 'currency stops asking the live file once the digest matches' \
    '      [ $? -eq 1 ] && return 0' \
    '      [ $? -eq 99 ] && return 0' \
    'must be pending once, so the installer can observe the divergence'
  check_mut 'the updater overrules an explicit --no-sandbox opt-out' \
    'none|skipped-below-floor|skipped-unprobeable) ;;' \
    'none|skipped-below-floor|skipped-unprobeable|skipped-optout) ;;' \
    'must NEVER be pending'
  check_mut 'the updater stops noticing a below-floor skip once the CLI is upgraded' \
    'none|skipped-below-floor|skipped-unprobeable) ;;' \
    'none) ;;' \
    'must become PENDING once the CLI clears the floor'
  check_mut 'the updater treats a still-below-floor CLI as pending' \
    'adb_version_ge "$version" "$(adb_claude_settings_floor)"' \
    'true' \
    'must stay put while the CLI is STILL below the floor'
  check_mut 'an installed receipt is trusted without comparing payloads' \
    '      [ "$have" = "$want" ] || return 0' \
    '      :' \
    'must be PENDING'
  check_mut 'currency is decided by the owned leaf PATHS again' \
    '      have="$(adb_claude_settings_payload_digest "$receipt")" || return 0   # unknown -> pending once' \
    '      have="$(adb_claude_settings_receipt_leaves "$receipt" | cut -f1 | LC_ALL=C sort)"; want="$(adb_claude_settings_leaves "$payload" | LC_ALL=C sort)"; [ "$have" = "$want" ] && return 1; return 0' \
    'must NOT report the surface pending on every update'
  check_mutation_pool "check-settings-fragment(baseline)" "$work/mut-baseline" prepare_baseline runner 4
fi

check_summary "settings-fragment"
