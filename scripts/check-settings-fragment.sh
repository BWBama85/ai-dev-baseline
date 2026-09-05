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
printf 'disposition wat\n' > "$work/d-bogus"
[ "$(adb_claude_settings_disposition "$work/d-bogus")" = none ] && ok || bad "an unrecognised disposition word must read as 'none', never be trusted verbatim"
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
# ...and one that EXISTS but does not parse. The two checks cover the absent case together, so only
# this input can show that the probe result itself is examined rather than merely the file size.
bad_home="$work/unparseable"; rm -rf "$bad_home"; mkdir -p "$bad_home/.claude"
echo '{"model":"opus"}' > "$bad_home/.claude/settings.json"
HOME="$bad_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks >/dev/null 2>&1
printf '{"sandbox": \n' > "$bad_home/.claude/settings.json"
HOME="$bad_home" PATH="$work/bin:$PATH" bash "$ROOT/install.sh" --agent claude --no-hooks --no-sandbox >/dev/null 2>&1
[ "$(grep -c "^leaf$ADB_TAB" "$bad_home/.claude/.adb-settings-owned" || true)" -eq 0 ] && ok \
  || bad "a settings.json that exists but does not parse is inability to prove ownership and must drop the carried rows"

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
pending() {   # pending <disposition> <stub-version> -> 0 if the surface is pending
  local disp="$1" ver="$2" ph="$work/pending-home"
  rm -rf "$ph"; mkdir -p "$ph/.claude"
  ln -s "$ROOT/agents/claude/CLAUDE.md" "$ph/.claude/CLAUDE.md"
  if [ "$disp" = installed ]; then
    # A CURRENT installed receipt: its leaf set must equal the payload's, or `pending` correctly
    # reports it stale and this case would pass for the wrong reason.
    adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)" \
      | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$(adb_sha256 "$PAYLOAD")" \
      > "$ph/.claude/.adb-settings-owned"
  elif [ "$disp" != none ]; then
    : | adb_claude_settings_receipt_render "$disp" - "$FLOOR" > "$ph/.claude/.adb-settings-owned"
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
pending installed       "2.1.259 (Claude Code)" && bad "an installed surface must not be pending" || ok

# ...unless the PAYLOAD ITSELF changed since it was applied. Currency is a digest question: a leaf
# the operator already owned is never recorded, so a path-set comparison reports pending forever
# and re-runs the installer every session; and changing a shipped VALUE leaves the path set
# identical, so the same comparison never notices a payload a plain `git pull` just changed.
pending_receipt() {   # pending_receipt <home> <payload-digest>
  adb_claude_settings_leaf_rows "$PAYLOAD" "$(adb_claude_settings_leaves "$PAYLOAD" | jq -c -s .)" \
    | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" "$2" > "$1/.claude/.adb-settings-owned"
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
  check_mut 'a retired container is carried forward anyway' \
      '                         | map(. as $a | select($after | present($a))) )' \
      '                         | map(. as $a | select(true)) )' \
      'container retirement emptied must be dropped from ownership'
  check_mut 'the release is a no-op, on every path at once' \
    '  adb_update_unlock "$_ADB_SETTINGS_LOCK"' \
    '  :' \
    'lock must be released on the success path'
  check_mut 'a signal is not trapped, so the lock outlives the run' \
    '  _adb_arm_lock_traps' \
    '  :' \
    'must not leave the settings lock behind'
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
    '  probe="$(adb_claude_settings_merge "$live" "$frag" "$receipt" --remove 2>/dev/null)" || probe=""' \
    '  probe="$(adb_claude_settings_merge "$live" "$frag" "$receipt" 2>/dev/null)" || probe=""' \
    'damaged FRAGMENT must not cost ownership'
  check_mut 'the lock is never released' \
    '  adb_settings_lock_drop' \
    '  :' \
    'must release the settings lock explicitly when the Claude phase ends'
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
    '    adb_info "  sandbox  ownership relinquished — the live settings could not be parsed." >&2' \
    '    adb_info "  sandbox  ownership relinquished — the live settings could not be parsed."' \
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
    '  if [ "$ours" != "1" ]; then' \
    '  if false; then' \
    'must NOT remove another clone'
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
    '      [ "$have" = "$want" ] && return 1 ;;' \
    '      return 1 ;;' \
    'must be PENDING'
  check_mut 'currency is decided by the owned leaf PATHS again' \
    '      have="$(adb_claude_settings_payload_digest "$receipt")" || return 0   # unknown -> pending once' \
    '      have="$(adb_claude_settings_receipt_leaves "$receipt" | cut -f1 | LC_ALL=C sort)"; want="$(adb_claude_settings_leaves "$payload" | LC_ALL=C sort)"; [ "$have" = "$want" ] && return 1; return 0' \
    'must NOT report the surface pending on every update'
  check_mutation_pool "check-settings-fragment(baseline)" "$work/mut-baseline" prepare_baseline runner 4
fi

check_summary "settings-fragment"
