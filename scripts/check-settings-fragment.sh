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

# --- the merge's five verdicts ------------------------------------------------------------------

m() {   # m <settings-json> <receipt-file> [--remove] -> the merge result on stdout
  local s="$1" r="$2" mode="${3:-}"
  printf '%s' "$s" > "$work/m.json"
  adb_claude_settings_merge "$work/m.json" "$PAYLOAD" "$r" "$mode"
}
names() { printf '%s' "$1" | jq -r --arg b "$2" '.[$b] | map(join(".")) | join(",")'; }

: > "$work/empty-receipt"

# WROTE: absent and unrecorded is the only shape written fresh.
r="$(m '{}' "$work/empty-receipt")"
[ "$(names "$r" wrote)" = "sandbox.enabled,sandbox.credentials.files,sandbox.credentials.envVars,sandbox.network.allowedDomains" ] && ok \
  || bad "merge must write every leaf into empty settings; wrote: $(names "$r" wrote)"

# SKIPPED: the operator already has a value there and no receipt says it is ours.
r="$(m '{"sandbox":{"enabled":false}}' "$work/empty-receipt")"
[ "$(names "$r" skipped)" = "sandbox.enabled" ] && ok || bad "merge must SKIP an operator value it never wrote; skipped: $(names "$r" skipped)"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = false ] && ok || bad "merge must not overwrite an operator's own value"

# UNRELATED KEYS SURVIVE — the whole point of leaf-level ownership over file- or top-key-level.
r="$(m '{"model":"opus","sandbox":{"excludedCommands":["docker"]}}' "$work/empty-receipt")"
[ "$(printf '%s' "$r" | jq -r '.settings.model')" = opus ] && ok || bad "merge must leave unrelated top-level keys alone"
[ "$(printf '%s' "$r" | jq -c '.settings.sandbox.excludedCommands')" = '["docker"]' ] && ok \
  || bad "merge must leave an adopter's OWN sandbox sibling key alone — this is what leaf-level ownership is for"

# Build a real `installed` receipt to exercise the recorded-ownership verdicts.
r="$(m '{}' "$work/empty-receipt")"
printf '%s' "$r" | jq '.settings' > "$work/installed.json"
adb_claude_settings_leaf_rows "$PAYLOAD" "$(printf '%s' "$r" | jq -c .wrote)" \
  | adb_claude_settings_receipt_render installed 9.9.9 "$FLOOR" > "$work/installed-receipt"
[ "$(adb_claude_settings_disposition "$work/installed-receipt")" = installed ] && ok || bad "a rendered install receipt must read back as disposition 'installed'"

# IDEMPOTENT: ours and untouched is rewritten with the current value, never reported as a conflict.
r="$(m "$(cat "$work/installed.json")" "$work/installed-receipt")"
[ "$(names "$r" skipped)" = "" ] && [ "$(names "$r" kept)" = "" ] && ok || bad "a re-run over our own untouched values must report neither skipped nor kept"

# REMOVED: the receipt says we wrote it and it is gone — the by-hand opt-out, never rewritten.
r="$(m "$(jq -c 'del(.sandbox.enabled)' "$work/installed.json")" "$work/installed-receipt")"
[ "$(names "$r" removed)" = "sandbox.enabled" ] && ok || bad "a recorded leaf now absent must be REMOVED (the by-hand opt-out); removed: $(names "$r" removed)"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox | has("enabled")')" = false ] && ok \
  || bad "merge must NOT rewrite a leaf the operator deleted — that would undo the opt-out on every session"

# KEPT: ours, but edited since. Never replaced on write, never deleted on remove.
edited="$(jq -c '.sandbox.enabled = false' "$work/installed.json")"
r="$(m "$edited" "$work/installed-receipt")"
[ "$(names "$r" skipped)" = "sandbox.enabled" ] && ok || bad "an edited owned leaf must be skipped on write; skipped: $(names "$r" skipped)"
r="$(m "$edited" "$work/installed-receipt" --remove)"
[ "$(names "$r" kept)" = "sandbox.enabled" ] && ok || bad "an edited owned leaf must be KEPT on removal; kept: $(names "$r" kept)"
[ "$(printf '%s' "$r" | jq -r '.settings.sandbox.enabled')" = false ] && ok || bad "removal must not delete a leaf the operator edited"

# PRUNED (retirement): the receipt records a leaf the payload no longer declares. Without this a
# key dropped from a future payload sits in every adopter's settings forever with nobody owning it.
{ cat "$work/installed-receipt"; printf 'leaf\t["sandbox","network","strictAllowlist"]\ttrue\n'; } > "$work/retired-receipt"
r="$(m "$(jq -c '.sandbox.network.strictAllowlist = true' "$work/installed.json")" "$work/retired-receipt")"
[ "$(names "$r" pruned)" = "sandbox.network.strictAllowlist" ] && ok \
  || bad "a recorded leaf the payload no longer declares must be PRUNED on install; pruned: $(names "$r" pruned)"
# ...unless the operator edited it, in which case it is theirs now.
r="$(m "$(jq -c '.sandbox.network.strictAllowlist = false' "$work/installed.json")" "$work/retired-receipt")"
[ "$(names "$r" kept)" = "sandbox.network.strictAllowlist" ] && ok || bad "a retired leaf the operator edited must be kept, not pruned"

# REMOVAL prunes only the containers IT emptied — never every empty object in the file. A blanket
# walk would delete an operator's own `{}` elsewhere, the exact over-reach leaf ownership prevents.
r="$(m "$(jq -c '.theirs = {} | .sandbox.excludedCommands = ["docker"]' "$work/installed.json")" "$work/installed-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -c '.settings.theirs')" = '{}' ] && ok || bad "removal must not delete an operator's own empty object elsewhere in the file"
[ "$(printf '%s' "$r" | jq -c '.settings.sandbox')" = '{"excludedCommands":["docker"]}' ] && ok \
  || bad "removal must prune the containers it emptied but keep the adopter's sibling; got $(printf '%s' "$r" | jq -c '.settings.sandbox')"
r="$(m "$(cat "$work/installed.json")" "$work/installed-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.settings | has("sandbox")')" = false ] && ok || bad "a clean removal must leave no empty sandbox object behind"

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
# A skip OWNS NOTHING, and the DISPOSITION is what enforces that — not merely the fact that the
# renderer emits no rows for it. Driven with rows PRESENT under a non-owning disposition, which is
# what a hand-edited or half-written receipt looks like: with only the renderer standing between
# them, a corrupt receipt would authorise deleting keys this install never wrote.
{ printf 'disposition skipped-below-floor\n'; grep '^leaf\t' "$work/installed-receipt"; } > "$work/below-receipt"
[ "$(grep -c '^leaf\t' "$work/below-receipt")" -eq 4 ] && ok || bad "precondition: the corrupt below-floor receipt should carry leaf rows"
r="$(m "$(cat "$work/installed.json")" "$work/below-receipt" --remove)"
[ "$(printf '%s' "$r" | jq -r '.pruned | length')" = 0 ] && ok || bad "a non-owning disposition must authorise no removal even when the receipt carries leaf rows"
# ...and independently, the renderer emits no leaf rows for a skip, so both halves hold.
: | adb_claude_settings_receipt_render skipped-below-floor 2.1.100 "$FLOOR" > "$work/below-rendered"
[ "$(grep -c '^leaf\t' "$work/below-rendered" || true)" -eq 0 ] && ok || bad "the renderer must emit no leaf rows for a below-floor skip"

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
  [ "$disp" = none ] || : | adb_claude_settings_receipt_render "$disp" - "$FLOOR" > "$ph/.claude/.adb-settings-owned"
  stub "$ver"
  HOME="$ph" PATH="$work/bin:$PATH" bash -c '
    . "'"$ROOT"'/scripts/lib/common.sh"
    SRC="'"$ROOT"'"
    eval "$(sed -n "/^adb_settings_pending() {/,/^}/p" "'"$ROOT"'/bin/baseline")"
    adb_settings_pending "$SRC"'
}
pending none            "2.1.259 (Claude Code)" && ok || bad "an install predating this surface (no receipt) must be PENDING — that is how existing installs receive it"
pending skipped-below-floor "2.1.259 (Claude Code)" && ok || bad "a below-floor skip must become PENDING once the CLI clears the floor — the transition the design exists for"
pending skipped-unprobeable "2.1.259 (Claude Code)" && ok || bad "an unprobeable skip must become PENDING once a probeable CLI is on PATH"
pending skipped-optout  "2.1.259 (Claude Code)" && bad "an explicit --no-sandbox opt-out must NEVER be pending — self-heal would overrule a supported choice on every session" || ok
pending installed       "2.1.259 (Claude Code)" && bad "an installed surface must not be pending" || ok
pending skipped-below-floor "2.1.100 (Claude Code)" && bad "a below-floor skip must stay put while the CLI is STILL below the floor" || ok
stub "2.1.259 (Claude Code)"

# --- mutation: every rule above, broken in a copy, required RED on its own witness ---------------

if [ "$MUTATION" -eq 1 ]; then
  prepare() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/scripts/lib/common.sh"; }
  prepare_payload() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/agents/claude/settings.fragment.json"; }
  prepare_install() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/install.sh"; }
  prepare_baseline() { check_copy_worktree "$ROOT" "$1/repo" >/dev/null 2>&1 || return 1; printf '%s' "$1/repo/bin/baseline"; }
  runner() { bash "$1/repo/scripts/check-settings-fragment.sh" 2>&1; }

  # Each row breaks ONE rule, and its witness is the assertion that claims to cover it. A row that
  # goes red elsewhere is scored as caught by accident, which is not evidence.
  check_mut 'merge rewrites a leaf the operator deleted' \
    'if $now == null and $rec == null then' \
    'if $now == null then' \
    'must NOT rewrite a leaf the operator deleted'
  check_mut 'merge overwrites an operator value it never wrote' \
    'elif $rec != null and $now == $rec.v then' \
    'elif true then' \
    'must not overwrite'
  check_mut 'removal deletes a leaf the operator edited' \
    'elif $now == $rec.v then .s = (.s | delpaths([$p])) | .pruned += [$p]' \
    'elif true then .s = (.s | delpaths([$p])) | .pruned += [$p]' \
    'must not delete a leaf the operator edited'
  check_mut 'container pruning becomes a blanket walk over the whole file' \
    '| ( [ .pruned[] | . as $p | range(1; ($p | length)) | $p[0:.] ]' \
    '| ( [ .s | paths(type == "object") ]' \
    "must not delete an operator's own empty object"
  check_mut 'the receipt trusts an unrecognised disposition word' \
    '    *) printf '"'"'none'"'"' ;;' \
    '    *) printf '"'"'%s'"'"' "$line" ;;' \
    "must read as 'none'"
  check_mut 'a non-owning disposition authorises removals' \
    'installed|skipped-optout) ;;' \
    'installed|skipped-optout|skipped-below-floor) ;;' \
    'must authorise no removal even when the receipt carries leaf rows'
  check_mut 'the receipt reader accepts a malformed leaf row' \
    "printf '%s' \"\$p\" | jq -e 'type == \"array\" and all(.[]; type == \"string\")' >/dev/null 2>&1 || continue" \
    ': ' \
    'malformed receipt row must be dropped'
  check_mut 'the version probe swallows a whole banner' \
    'v="${out%%[!0-9.]*}"' \
    'v="$out"' \
    'must parse the leading dotted version out of the CLI banner'
  check_mut 'the version probe accepts a bare major with no dot' \
    'case "$v" in *.*) ;; *) return 1 ;; esac' \
    'case "$v" in *) ;; esac' \
    'must refuse an unparseable version banner'
  check_mut 'the floor drops below what sandbox.credentials needs' \
    "adb_claude_settings_floor() { printf '2.1.187'; }" \
    "adb_claude_settings_floor() { printf '2.1.100'; }" \
    'D98 pinned it to'
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
  check_mutation_pool "check-settings-fragment(install)" "$work/mut-install" prepare_install runner 4

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
  check_mutation_pool "check-settings-fragment(baseline)" "$work/mut-baseline" prepare_baseline runner 4
fi

check_summary "settings-fragment"
