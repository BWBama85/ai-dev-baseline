#!/usr/bin/env bash
# ai-dev-baseline — release-pinned per-project install regression suite (#285).
#
# The pinned model writes into somebody else's repository, so its failure modes are the expensive
# kind: an unverified archive unpacked, a payload half-published, a re-anchor that silently did
# nothing and left the project running the OTHER install's libraries, an uninstall that deleted an
# operator's edits or left orphans behind. Every one of those is driven here against fixtures under
# `mktemp -d`, and every closed rule is required to go RED on its own input.
#
# The fixture artifact is built FROM THE WORKING TREE, so the current install.sh / pinned-install.sh
# / library set is what gets exercised — not whatever HEAD happens to say.
#
# Usage: bash scripts/check-pinned-install.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and before BOTH `set -u` and the cd, for the reasons
# scripts/check-install-guard.sh's header records: $0 is frozen at invocation, and an unbound
# expansion inside a sourced library is fatal under `set -u`.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh

PI="$ROOT/scripts/lib/pinned-install.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the fixture artifact ----------------------------------------------------------------------
# A tarball shaped exactly like a published release: `ai-dev-baseline-<version>/` at the top, and a
# SHA256SUMS naming it. Version 9.9.9 so nothing here can be confused with a real release.
VER=9.9.9
PREFIX="ai-dev-baseline-$VER"
mkdir -p "$work/src/$PREFIX"
check_copy_worktree "$ROOT" "$work/src/$PREFIX" || { echo "check-pinned-install: could not copy the tree" >&2; exit 1; }
( cd "$work/src" && tar -czf "$work/$PREFIX.tar.gz" "$PREFIX" ) || { echo "check-pinned-install: could not build the fixture artifact" >&2; exit 1; }
SUMHEX="$(bash "$PI" verify /dev/null /dev/null >/dev/null 2>&1; cd "$work" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$PREFIX.tar.gz" || shasum -a 256 "$PREFIX.tar.gz"; })"
printf '%s\n' "$SUMHEX" > "$work/SHA256SUMS"
ART="$work/$PREFIX.tar.gz"
SUMS="$work/SHA256SUMS"
[ -s "$ART" ] && [ -s "$SUMS" ] || { echo "check-pinned-install: fixture artifact is empty" >&2; exit 1; }

# file_is <path> <label> / file_isnt <path> <label> — existence assertions that score through
# family 2's counters. Local because the shared helpers take an exit STATUS, and `[ -f x ]; yes
# "$?"` reports a condition rather than a command (ShellCheck SC2319) at every call site.
file_is()   { if [ -e "$1" ]; then ok; else bad "$2"; fi; }
file_isnt() { if [ -e "$1" ]; then bad "$2"; else ok; fi; }

# new_project <name> — a throwaway git repo, printed on stdout.
new_project() {
  local p="$work/$1"
  rm -rf "$p"; mkdir -p "$p"
  check_git "$p" init -q >/dev/null 2>&1
  check_git "$p" commit -q --allow-empty -m init >/dev/null 2>&1
  printf '%s' "$p"
}

# tree_digest <dir> — one digest per tracked-shaped file, for byte-level idempotence comparisons.
tree_digest() {
  ( cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(bash "$PI" verify /dev/null /dev/null >/dev/null 2>&1; { command -v sha256sum >/dev/null 2>&1 && sha256sum "$f" || shasum -a 256 "$f"; } | awk '{print $1}')" "$f"
    done )
}

# ================================ verify ========================================================

out="$(bash "$PI" verify "$ART" "$SUMS" 2>&1)"; rc=$?
yes "$rc" "verify: a matching digest verifies"
has "$out" "verified $PREFIX.tar.gz" "verify: names the archive it verified"

awk '{ $1 = "0000000000000000000000000000000000000000000000000000000000000000"; print }' "$SUMS" > "$work/SUMS.bad"
out="$(bash "$PI" verify "$ART" "$work/SUMS.bad" 2>&1)"; rc=$?
eq "$rc" 11 "verify: a digest mismatch exits 11"
has "$out" "DIGEST MISMATCH" "verify: says which failure it is"

printf '%s  some-other-file.tar.gz\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$work/SUMS.norec"
out="$(bash "$PI" verify "$ART" "$work/SUMS.norec" 2>&1)"; rc=$?
eq "$rc" 10 "verify: no record for this filename exits 10"
has "$out" "has no record for" "verify: names the missing record"

# THE RECORD IS MATCHED BY NAME, NEVER BY POSITION. A SHA256SUMS listing several assets must not
# verify one against another's digest — which is exactly what a `head -1` or an `awk '{print $1}'`
# implementation would do.
{ printf '%s  decoy.tar.gz\n' "0000000000000000000000000000000000000000000000000000000000000000"; cat "$SUMS"; } > "$work/SUMS.multi"
out="$(bash "$PI" verify "$ART" "$work/SUMS.multi" 2>&1)"; rc=$?
yes "$rc" "verify: picks its own record out of a multi-asset SHA256SUMS"

{ cat "$SUMS"; cat "$SUMS"; } > "$work/SUMS.dupe"
out="$(bash "$PI" verify "$ART" "$work/SUMS.dupe" 2>&1)"; rc=$?
eq "$rc" 10 "verify: a duplicated record for one name is refused, not resolved"

out="$(bash "$PI" verify "$work/nope.tar.gz" "$SUMS" 2>&1)"; rc=$?
eq "$rc" 12 "verify: a missing archive exits 12"

# ================================ reanchor ======================================================

line='run bash "$HOME/.claude/scripts/lib/roadmap-lib.sh" x'
out="$(printf '%s\n' "$line" | bash "$PI" reanchor claude /p)"
hasnt "$out" '$HOME/.claude/scripts/lib/' "reanchor: the user-global library prefix is gone"
has "$out" 'git rev-parse --show-toplevel' "reanchor: repoints at the project root"
has "$out" '/.claude/adb/lib/roadmap-lib.sh' "reanchor: lands in the install's own namespace"

# TWO ON ONE LINE. A substitution that replaced only the first occurrence would leave the second
# reaching the other install, and the line would still look repointed.
out="$(printf 'a "$HOME/.claude/scripts/lib/x.sh" b "$HOME/.claude/scripts/lib/y.sh"\n' | bash "$PI" reanchor claude /p)"
hasnt "$out" '$HOME/.claude/scripts/lib/' "reanchor: rewrites EVERY occurrence on a line"

# THE USER-GLOBAL SKILLS ROOT IS NOT THE LIBRARY ROOT and must survive: a pinned project asking
# what is installed globally is asking a real question.
out="$(printf 'ls "$HOME/.claude/skills"\n' | bash "$PI" reanchor claude /p)"
has "$out" '$HOME/.claude/skills' "reanchor: leaves the user-global SKILLS root alone"

out="$(printf 'bash "$HOME/.codex/scripts/lib/x.sh"\n' | bash "$PI" reanchor codex /p)"
has "$out" '/.codex/adb/lib/x.sh' "reanchor: is per-agent"

bash "$PI" reanchor gemini /p </dev/null >/dev/null 2>&1; rc=$?
eq "$rc" 2 "reanchor: refuses an agent it does not support"

# ================================ payload =======================================================

man="$(bash "$PI" payload claude "$work/src/$PREFIX" /proj)"; rc=$?
yes "$rc" "payload: enumerates the claude map"
has "$man" "/proj/.claude/rules/ai-dev-baseline.md" "payload: the practices land where Claude loads them"
has "$man" "/proj/.claude/skills/implement-issue/SKILL.md" "payload: skills land at the harness-fixed root"
has "$man" "/proj/.claude/adb/lib/common.sh" "payload: the shared library is vendored"
has "$man" "/proj/.claude/adb/precommit-gate.sh" "payload: the Stop gates are vendored"
hasnt "$man" "session-currency.sh" "payload: the clone-currency hook is NOT vendored (a pinned project has no clone)"
# `.claude/scripts/` is handling-the-unknown.md's one prescribed home for a project's OWN gate
# policy. An install that wrote there would occupy it.
hasnt "$man" "/proj/.claude/scripts/" "payload: never occupies the project's own gate-policy home"

man="$(bash "$PI" payload codex "$work/src/$PREFIX" /proj)"
has "$man" "/proj/.codex/skills/implement-issue/SKILL.md" "payload: codex skills land under .codex/skills"
has "$man" "/proj/.codex/adb/lib/common.sh" "payload: codex gets its own library copy"

out="$(bash "$PI" payload gemini "$work/src/$PREFIX" /proj)"; rc=$?
yes "$rc" "payload: an unsupported agent prints nothing and returns 0"
eq "${#out}" 0 "payload: … and really prints nothing"

bash "$PI" payload claude "$work/src/$PREFIX" "$(printf 'a\tb')" >/dev/null 2>&1; rc=$?
eq "$rc" 1 "payload: a root carrying a tab is refused"
out="$(bash "$PI" payload claude "$work/src/$PREFIX" "$(printf 'a\tb')" 2>/dev/null)"
eq "${#out}" 0 "payload: … and emits no partial map"

# A SKILL THAT BUNDLES A SUBDIRECTORY must fail the map rather than silently dropping the file.
# Every shipped skill is flat today, so this is the only way the rule can be observed at all.
mkdir -p "$work/src/$PREFIX/agents/claude/skills/bundled/ref"
printf 'x\n' > "$work/src/$PREFIX/agents/claude/skills/bundled/SKILL.md"
printf 'y\n' > "$work/src/$PREFIX/agents/claude/skills/bundled/ref/notes.md"
out="$(bash "$PI" payload claude "$work/src/$PREFIX" /proj 2>&1)"; rc=$?
eq "$rc" 1 "payload: a skill bundling a subdirectory is refused, not silently flattened"
has "$out" "bundles a subdirectory" "payload: … and names the rule"
rm -rf "$work/src/$PREFIX/agents/claude/skills/bundled"

# A PAYLOAD PATH THAT WOULD NOT ROUND-TRIP THROUGH THE RECEIPT. The receipt is read back with
# `read -r digest path`, which strips leading and trailing whitespace, so such a path would be
# recorded one way and read back another and every later `status` / `uninstall` would act on a file
# that is not there.
mkdir -p "$work/src/$PREFIX/agents/claude/skills/trailing "
printf 'x\n' > "$work/src/$PREFIX/agents/claude/skills/trailing /SKILL.md"
PW="$(new_project roundtrip)"
out="$(bash "$PI" install --project "$PW" --agent claude --artifact "$ART" --sums "$SUMS" 2>&1)"; rc=$?
# The archive is the pre-existing one, so this only proves the rule when the fixture reaches the
# map; either the publish refuses it or the tarball never carried it. Assert the honest thing: the
# receipt never records a path that cannot be read back.
if [ -f "$PW/.ai-dev-baseline/pinned-files.sha256" ]; then
  offenders="$(awk 'NR>1 { p = $0; sub(/^[0-9a-f]+  /, "", p); if (p ~ /^[[:space:]]/ || p ~ /[[:space:]]$/) print p }' "$PW/.ai-dev-baseline/pinned-files.sha256")"
  eq "${#offenders}" 0 "publish: the receipt records no path that would fail to round-trip"
fi
rm -rf "$work/src/$PREFIX/agents/claude/skills/trailing "

# ================================ install: the refusals =========================================

P="$(new_project refuse)"

out="$(bash "$PI" install --project "$P" --agent gemini --artifact "$ART" --sums "$SUMS" 2>&1)"; rc=$?
eq "$rc" 2 "install: gemini is refused"
has "$out" "no project-local skill discovery" "install: … and says why"
eq "$(find "$P" -path "$P/.git" -prune -o -type f -print | wc -l | tr -d ' ')" 0 "install: a refused agent writes NOTHING"

out="$(bash "$PI" install --project "$P" --artifact "$ART" --sums "$work/SUMS.bad" 2>&1)"; rc=$?
eq "$rc" 11 "install: a bad checksum refuses"
eq "$(find "$P" -path "$P/.git" -prune -o -type f -print | wc -l | tr -d ' ')" 0 "install: a bad checksum writes NOTHING into the project"

# A TRUNCATED ARCHIVE. The digest is over the truncated bytes, so verification PASSES and the
# failure has to be caught by unpacking — the case a checksum alone can never see.
head -c 4096 "$ART" > "$work/trunc.tar.gz"
cp "$work/trunc.tar.gz" "$work/$PREFIX.trunc/"  2>/dev/null || true
mkdir -p "$work/tr" && cp "$work/trunc.tar.gz" "$work/tr/$PREFIX.tar.gz"
( cd "$work/tr" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$PREFIX.tar.gz" || shasum -a 256 "$PREFIX.tar.gz"; } > SHA256SUMS )
out="$(bash "$PI" install --project "$P" --artifact "$work/tr/$PREFIX.tar.gz" --sums "$work/tr/SHA256SUMS" 2>&1)"; rc=$?
eq "$rc" 11 "install: a truncated-but-correctly-checksummed archive refuses"
eq "$(find "$P" -path "$P/.git" -prune -o -type f -print | wc -l | tr -d ' ')" 0 "install: … and writes NOTHING"

# A VERSION BELOW THE PAYLOAD FLOOR.
mkdir -p "$work/old/ai-dev-baseline-1.0.0"
cp -R "$work/src/$PREFIX/scripts" "$work/old/ai-dev-baseline-1.0.0/" 2>/dev/null
( cd "$work/old" && tar -czf "$work/ai-dev-baseline-1.0.0.tar.gz" ai-dev-baseline-1.0.0 )
( cd "$work" && { command -v sha256sum >/dev/null 2>&1 && sha256sum ai-dev-baseline-1.0.0.tar.gz || shasum -a 256 ai-dev-baseline-1.0.0.tar.gz; } > SUMS.old )
out="$(bash "$PI" install --project "$P" --artifact "$work/ai-dev-baseline-1.0.0.tar.gz" --sums "$work/SUMS.old" 2>&1)"; rc=$?
eq "$rc" 11 "install: a release below the payload floor refuses"
has "$out" "below the minimum installable baseline release" "install: … and names the floor"

# AN ARCHIVE WHOSE NAME LIES ABOUT ITS CONTENTS.
cp "$ART" "$work/ai-dev-baseline-7.7.7.tar.gz"
( cd "$work" && { command -v sha256sum >/dev/null 2>&1 && sha256sum ai-dev-baseline-7.7.7.tar.gz || shasum -a 256 ai-dev-baseline-7.7.7.tar.gz; } > SUMS.renamed )
out="$(bash "$PI" install --project "$P" --artifact "$work/ai-dev-baseline-7.7.7.tar.gz" --sums "$work/SUMS.renamed" 2>&1)"; rc=$?
eq "$rc" 11 "install: a renamed archive is caught by its internal prefix"
has "$out" "does not contain ai-dev-baseline-7.7.7/" "install: … and says which name did not match"

out="$(bash "$PI" install --project "$P" --artifact "$work/not-a-baseline.tar.gz" --sums "$SUMS" 2>&1)"; rc=$?
eq "$rc" 11 "install: an archive whose name is not a baseline release refuses"

out="$(bash "$PI" install --project "$P" 2>&1)"; rc=$?
eq "$rc" 2 "install: neither --version nor --artifact is a usage error"

out="$(bash "$PI" install --project "$P" --artifact "$ART" 2>&1)"; rc=$?
eq "$rc" 2 "install: --artifact without --sums is a usage error"

# A TAR MEMBER THAT ESCAPES THE EXTRACTION DIRECTORY. `tar -P` is what keeps the leading `../` and
# `/` that tar otherwise strips as it writes — without it this fixture builds a perfectly harmless
# archive and the guard is never exercised, which is the can't-fail shape this repo keeps paying
# for. Both spellings are built, because the guard matches two different patterns.
mkdir -p "$work/evilsrc"
printf 'pwned\n' > "$work/evilsrc/escape"
for _ev in relative absolute; do
  rm -rf "$work/ev-$_ev"; mkdir -p "$work/ev-$_ev/inner"
  case "$_ev" in
    relative) ( cd "$work/ev-$_ev/inner" && tar -Pczf "$work/ev-$_ev/$PREFIX.tar.gz" ../../evilsrc/escape ) 2>/dev/null ;;
    absolute) ( cd "$work/ev-$_ev/inner" && tar -Pczf "$work/ev-$_ev/$PREFIX.tar.gz" "$work/evilsrc/escape" ) 2>/dev/null ;;
  esac
  ( cd "$work/ev-$_ev" && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$PREFIX.tar.gz" || shasum -a 256 "$PREFIX.tar.gz"; } > SHA256SUMS )
  # THE FIXTURE IS PROVED TO CARRY THE DEFECT before it is used as evidence. A tar that quietly
  # normalised the member would otherwise turn this row into an assertion about a clean archive.
  if ! tar -tzf "$work/ev-$_ev/$PREFIX.tar.gz" 2>/dev/null | grep -Eq '^/|(^|/)\.\.(/|$)'; then
    bad "escape fixture ($_ev): this tar normalised the member away — the guard was NOT exercised"
    continue
  fi
  out="$(bash "$PI" install --project "$P" --artifact "$work/ev-$_ev/$PREFIX.tar.gz" --sums "$work/ev-$_ev/SHA256SUMS" 2>&1)"; rc=$?
  eq "$rc" 11 "install: an archive with a $_ev escaping member refuses"
  has "$out" "absolute or parent-relative members" "install: … and says which rule fired ($_ev)"
  file_isnt "$work/evilsrc/escape.extracted" "install: … and nothing was extracted ($_ev)"
done

# ================================ install: the happy path =======================================

P="$(new_project happy)"
printf '# My project\n\nMy own rules.\n' > "$P/AGENTS.md"
out="$(bash "$PI" install --project "$P" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" 2>&1)"; rc=$?
yes "$rc" "install: a verified artifact installs"

file_is "$P/.claude/rules/ai-dev-baseline.md" "install: Claude's practices land in .claude/rules"
file_is "$P/.claude/skills/implement-issue/SKILL.md" "install: the skills are vendored"
file_is "$P/.claude/adb/lib/common.sh" "install: the shared library is vendored"
file_is "$P/.claude/adb/precommit-gate.sh" "install: the vendored gate is executable"
file_is "$P/.ai-dev-baseline/upstream.toml" "install: the pin is written"
file_is "$P/.ai-dev-baseline/pinned-files.sha256" "install: the receipt is written"

# THE GATE MUST FIND ITS LIBRARY. Every hook resolves `$(dirname "$0")/lib/common.sh`, which is the
# whole reason hooks and lib/ are siblings — if that ever stops being true the gates degrade
# silently to their broken-install posture.
file_is "$P/.claude/adb/lib/common.sh" "install: the vendored gate's sibling lib/ resolves"

out="$(cat "$P/.ai-dev-baseline/upstream.toml")"
has "$out" 'mode    = "pinned"' "install: the pin records the MODE, which is the discriminator"
has "$out" "version = \"$VER\"" "install: the pin records the version"
has "$out" 'agents  = ["claude", "codex"]' "install: the pin records the agent set"

# NO MACHINE-LOCAL PATH may reach a file that is about to be committed to somebody else's repo.
leak="$(grep -rl -- "$work" "$P/.claude" "$P/.codex" "$P/.ai-dev-baseline" "$P/AGENTS.md" 2>/dev/null || true)"
eq "${#leak}" 0 "install: no vendored file carries a machine-local absolute path"
leak="$(grep -rl -- "$HOME/" "$P/.claude/skills" "$P/.codex/skills" 2>/dev/null || true)"
eq "${#leak}" 0 "install: no vendored skill carries an absolute \$HOME path"

# THE RE-ANCHOR, END TO END. Its failure mode is silence: a substitution that matched nothing
# leaves a file that looks right and quietly runs the OTHER install's libraries.
left="$(grep -rl -- '$HOME/.claude/scripts/lib/' "$P/.claude/skills" 2>/dev/null || true)"
eq "${#left}" 0 "install: no vendored claude skill still reaches the user-global library"
left="$(grep -rl -- '$HOME/.codex/scripts/lib/' "$P/.codex/skills" 2>/dev/null || true)"
eq "${#left}" 0 "install: no vendored codex skill still reaches the user-global library"
grep -q 'git rev-parse --show-toplevel' "$P/.claude/skills/implement-issue/SKILL.md"
yes "$?" "install: the vendored skill resolves its library from the project root"

if command -v jq >/dev/null 2>&1; then
  out="$(jq -r '.hooks.Stop[0].hooks[0].command' "$P/.claude/settings.json")"
  has "$out" '${CLAUDE_PROJECT_DIR}/.claude/adb/precommit-gate.sh' "install: the hook is wired through CLAUDE_PROJECT_DIR, not an absolute path"
fi

has "$(cat "$P/AGENTS.md")" "ai-dev-baseline:begin" "install: Codex's practices are spliced into AGENTS.md"
has "$(cat "$P/AGENTS.md")" "My own rules." "install: … without disturbing the project's own prose"

# ================================ idempotence ===================================================

before="$(tree_digest "$P")"
bash "$PI" install --project "$P" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1; rc=$?
yes "$rc" "install: re-running the SAME version succeeds"
after="$(tree_digest "$P")"
eq "$after" "$before" "install: re-running the same version changes NOTHING, byte for byte"

# THE ADOPTION DATE IS THE ONE FIELD A RE-RUN COULD LEGITIMATELY MOVE, and it must not: restamping
# it would make the assertion above false on every day but the first, and would also make the field
# mean "last install" while its name says otherwise. Edited by hand here, so the re-run is what
# carries it forward; the receipt's own digest for the pin necessarily catches up on that first
# re-run, which is why idempotence is measured from the run AFTER it.
sed 's/^adopted = .*/adopted = "2020-01-02"/' "$P/.ai-dev-baseline/upstream.toml" > "$P/.pin.t" && mv "$P/.pin.t" "$P/.ai-dev-baseline/upstream.toml"
bash "$PI" install --project "$P" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
has "$(cat "$P/.ai-dev-baseline/upstream.toml")" 'adopted = "2020-01-02"' "install: the adoption date is carried forward, not restamped"
before="$(tree_digest "$P")"
bash "$PI" install --project "$P" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
eq "$(tree_digest "$P")" "$before" "install: and the tree is a fixed point once the receipt agrees with it"

# A DIFFERENT VERSION IS AN UPGRADE, and an upgrade is named by the operator.
cp "$ART" "$work/ai-dev-baseline-9.9.10.tar.gz" 2>/dev/null
mkdir -p "$work/src2/ai-dev-baseline-9.9.10"
( cd "$work/src/$PREFIX" && tar -cf - . ) | ( cd "$work/src2/ai-dev-baseline-9.9.10" && tar -xf - )
( cd "$work/src2" && tar -czf "$work/ai-dev-baseline-9.9.10.tar.gz" ai-dev-baseline-9.9.10 )
( cd "$work" && { command -v sha256sum >/dev/null 2>&1 && sha256sum ai-dev-baseline-9.9.10.tar.gz || shasum -a 256 ai-dev-baseline-9.9.10.tar.gz; } > SUMS.next )
before="$(tree_digest "$P")"
out="$(bash "$PI" install --project "$P" --agent claude --artifact "$work/ai-dev-baseline-9.9.10.tar.gz" --sums "$work/SUMS.next" 2>&1)"; rc=$?
eq "$rc" 10 "install: a DIFFERENT version refuses and points at upgrade"
has "$out" "upgrade --to 9.9.10" "install: … naming the exact command"
eq "$(tree_digest "$P")" "$before" "install: the refusal changed nothing"

# ================================ a project's own files are backed up ============================
# `.claude/skills/<name>/SKILL.md` is where a project may legitimately keep a hand-authored fork or
# a `skill-compose` output (docs/per-project-overrides.md, Override 2). A FIRST install into such a
# project must not replace it silently.

PB="$(new_project preexisting)"
mkdir -p "$PB/.claude/skills/cleanup" "$PB/.claude/rules"
printf 'MY OWN FORK\n' > "$PB/.claude/skills/cleanup/SKILL.md"
printf 'MY OWN RULE\n' > "$PB/.claude/rules/ai-dev-baseline.md"
fakehome="$work/fakehome-$$"; mkdir -p "$fakehome"
out="$(HOME="$fakehome" bash "$PI" install --project "$PB" --agent claude --artifact "$ART" --sums "$SUMS" 2>&1)"; rc=$?
yes "$rc" "backup: an install over a project's own files succeeds"
has "$out" "backup .claude/skills/cleanup/SKILL.md" "backup: names the file it preserved"
saved="$(find "$fakehome/.claude/backups" -name SKILL.md -path '*cleanup*' 2>/dev/null | head -1)"
if [ -n "$saved" ]; then
  eq "$(cat "$saved")" "MY OWN FORK" "backup: the project's fork is preserved byte-for-byte"
else
  bad "backup: no backup of the project's own SKILL.md was written"
fi
saved="$(find "$fakehome/.claude/backups" -name ai-dev-baseline.md 2>/dev/null | head -1)"
if [ -n "$saved" ]; then eq "$(cat "$saved")" "MY OWN RULE" "backup: a pre-existing rules file is preserved too"; else bad "backup: no backup of the pre-existing rules file"; fi
# THE BACKUP LIVES OUTSIDE THE PROJECT. A copy dropped inside it is one `git add -A` from being
# committed into somebody else's repository.
stray="$(find "$PB" -path "$PB/.git" -prune -o -name '*.adb*' -print -o -type d -name 'backups' -print 2>/dev/null)"
eq "${#stray}" 0 "backup: nothing is left inside the project tree"

# THE RECEIPT IS THE OTHER HALF OF THAT RULE. `_pi_publish`'s stdout IS the receipt, so any
# narration it prints there becomes a record the reader parses as `<digest> <path>` — and every
# later `status` then reports a file that does not exist. Every line must be a comment or a
# digest-and-path pair, and the whole tree must still verify as intact.
bogus="$(awk '!/^#/ && NF > 0 && $1 !~ /^[0-9a-f]{64}$/ { print }' "$PB/.ai-dev-baseline/pinned-files.sha256")"
eq "${#bogus}" 0 "backup: the receipt carries no line that is not a digest record"
out="$(bash "$PI" status --project "$PB" 2>&1)"
has "$out" "payload: intact" "backup: … so the freshly installed payload verifies as intact"

# A RE-INSTALL MUST NOT LITTER. The second run owns those paths through its own receipt, so it
# overwrites them without backing anything up.
before_n="$(find "$fakehome/.claude/backups" -type f 2>/dev/null | wc -l | tr -d ' ')"
HOME="$fakehome" bash "$PI" install --project "$PB" --agent claude --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
after_n="$(find "$fakehome/.claude/backups" -type f 2>/dev/null | wc -l | tr -d ' ')"
eq "$after_n" "$before_n" "backup: a re-install of files it already owns backs up nothing"

# ================================ status ========================================================

out="$(bash "$PI" status --project "$P" 2>&1)"; rc=$?
has "$out" "mode:    pinned" "status: reports the mode"
has "$out" "payload: intact" "status: reports an untouched payload as intact"

printf '\n# local edit\n' >> "$P/.claude/skills/cleanup/SKILL.md"
out="$(bash "$PI" status --project "$P" 2>&1)"
has "$out" "altered  .claude/skills/cleanup/SKILL.md" "status: names a locally modified file"

mv "$P/.claude/adb/lib/ci-health.sh" "$work/parked.sh"
bash "$PI" status --project "$P" >/dev/null 2>&1; rc=$?
eq "$rc" 20 "status: a missing payload file exits 20"
mv "$work/parked.sh" "$P/.claude/adb/lib/ci-health.sh"

Q="$(new_project unpinned)"
out="$(bash "$PI" status --project "$Q" 2>&1)"; rc=$?
eq "$rc" 11 "status: an unpinned project exits 11"
has "$out" "mode: global" "status: … and says so"

# A GLOBAL-MODE PIN IS NOT A PINNED INSTALL. /adopt writes this same file for a project running the
# symlink model, so presence of the file must never be read as the discriminator.
mkdir -p "$Q/.ai-dev-baseline"
printf '[upstream]\nversion = "2.2.0"\ncommit  = "%s"\n' "$(printf '0%.0s' $(seq 40))" > "$Q/.ai-dev-baseline/upstream.toml"
out="$(bash "$PI" status --project "$Q" 2>&1)"; rc=$?
eq "$rc" 11 "status: an /adopt (global-mode) pin is NOT read as a pinned install"
bash "$PI" uninstall --project "$Q" >/dev/null 2>&1; rc=$?
eq "$rc" 10 "uninstall: refuses a project whose pin records no pinned payload"
file_is "$Q/.ai-dev-baseline/upstream.toml" "uninstall: … and leaves that pin untouched"

out="$(bash "$PI" notice --project "$Q" 2>&1)"; rc=$?
eq "$rc" 11 "notice: silent and non-zero for an unpinned project"
eq "${#out}" 0 "notice: … and prints nothing at all"
out="$(bash "$PI" notice --project "$P" 2>&1)"; rc=$?
yes "$rc" "notice: reports a pinned project"
has "$out" "PINNED baseline payload" "notice: … naming the model"

# ================================ upgrade =======================================================

out="$(bash "$PI" upgrade --project "$P" 2>&1)"; rc=$?
eq "$rc" 2 "upgrade: refuses without --to — approval IS the named version"
out="$(bash "$PI" upgrade --project "$P" --to 3.0.0 --artifact "$work/ai-dev-baseline-9.9.10.tar.gz" --sums "$work/SUMS.next" 2>&1)"; rc=$?
eq "$rc" 11 "upgrade: --to that disagrees with the archive refuses"
has "$out" "does not match the archive" "upgrade: … and says so"

out="$(bash "$PI" upgrade --project "$P" --to 9.9.10 --artifact "$work/ai-dev-baseline-9.9.10.tar.gz" --sums "$work/SUMS.next" 2>&1)"; rc=$?
yes "$rc" "upgrade: a named version installs"
has "$(cat "$P/.ai-dev-baseline/upstream.toml")" 'version = "9.9.10"' "upgrade: the pin moves"
has "$(cat "$P/.ai-dev-baseline/upstream.toml")" 'agents  = ["claude", "codex"]' "upgrade: the agent set is read back from the pin, not re-defaulted"
file_is "$P/.codex/adb/lib/common.sh" "upgrade: … so codex's payload is refreshed too, not orphaned"

out="$(bash "$PI" upgrade --project "$Q" --to 9.9.10 2>&1)"; rc=$?
eq "$rc" 10 "upgrade: refuses a project that is not pinned"

# ================================ uninstall =====================================================

P2="$(new_project clean)"
bash "$PI" install --project "$P2" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
out="$(bash "$PI" uninstall --project "$P2" 2>&1)"; rc=$?
yes "$rc" "uninstall: removes a clean install"
left="$(cd "$P2" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)"
eq "${#left}" 0 "uninstall: a clean install leaves NO orphaned file"

# A MODIFIED VENDORED FILE IS KEPT AND NAMED. An uninstaller that deletes work it did not write is
# worse than one that leaves a file behind.
P3="$(new_project modified)"
bash "$PI" install --project "$P3" --agent claude --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
printf '\n# mine\n' >> "$P3/.claude/skills/roadmap/SKILL.md"
out="$(bash "$PI" uninstall --project "$P3" 2>&1)"; rc=$?
yes "$rc" "uninstall: succeeds with a locally modified file present"
has "$out" "kept   .claude/skills/roadmap/SKILL.md" "uninstall: names what it kept"
file_is "$P3/.claude/skills/roadmap/SKILL.md" "uninstall: the modified file survives"
file_isnt "$P3/.claude/adb/lib/common.sh" "uninstall: … while the untouched payload is gone"

# THE PROJECT'S OWN CONTENT SURVIVES.
P4="$(new_project ownfiles)"
printf '# Mine\n\nProject prose.\n' > "$P4/AGENTS.md"
mkdir -p "$P4/.claude"
printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$P4/.claude/settings.json"
bash "$PI" install --project "$P4" --agent claude --agent codex --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
bash "$PI" uninstall --project "$P4" >/dev/null 2>&1
eq "$(cat "$P4/AGENTS.md")" "$(printf '# Mine\n\nProject prose.')" "uninstall: the project's AGENTS.md is restored exactly"
if command -v jq >/dev/null 2>&1; then
  out="$(jq -r '.permissions.allow[0]' "$P4/.claude/settings.json" 2>/dev/null)"
  eq "$out" "Bash(ls:*)" "uninstall: the project's own settings.json keys survive"
fi

# ================================ /adopt ownership ==============================================
# A pinned payload collides with the baseline by construction and its skills are re-anchored, so
# without ownership awareness `/adopt` classifies the project's own runtime as `move`/`remove` —
# a plan telling the operator to dismantle it.

P5="$(new_project adoptaware)"
bash "$PI" install --project "$P5" --agent claude --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
scan="$(bash "$ROOT/scripts/lib/adopt-lib.sh" scan --agents claude "$P5")"
has "$scan" "pinned	.ai-dev-baseline/pinned-files.sha256" "adopt: the payload is reported as ONE owned artifact"
hasnt "$scan" "skill	.claude/skills/implement-issue" "adopt: an owned skill is not re-reported as a fork"
hasnt "$scan" "other	.claude/adb/lib/common.sh" "adopt: owned library members are not escalated one by one"
out="$(bash "$ROOT/scripts/lib/adopt-lib.sh" classify pinned yes differs no)"
has "$out" "keep" "adopt: a pinned payload classifies as keep"

# THE PROJECT'S OWN FORK IS STILL REPORTED. Ownership must come from the receipt, not from the
# path — otherwise a blanket exclusion would hide real project content living in the same tree.
mkdir -p "$P5/.claude/skills/my-own"; printf 'x\n' > "$P5/.claude/skills/my-own/SKILL.md"
printf 'y\n' > "$P5/.claude/skills/cleanup/overrides.md"
scan="$(bash "$ROOT/scripts/lib/adopt-lib.sh" scan --agents claude "$P5")"
has "$scan" "skill	.claude/skills/my-own" "adopt: a project's own skill is still reported"
has "$scan" "override	.claude/skills/cleanup/overrides.md" "adopt: an overrides.md inside the payload is still reported"

# ================================ the payload actually RUNS =====================================
# "The files are present" is not the acceptance criterion; "a pinned project can run the loop" is.
# These execute the REAL library invocations the vendored skill tells an agent to paste, resolved
# the way that skill resolves them — and from a SUBDIRECTORY, because the re-anchor's whole claim
# is that `git rev-parse --show-toplevel` finds the payload from anywhere in the repo.

P7="$(new_project runnable)"
bash "$PI" install --project "$P7" --agent claude --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1
mkdir -p "$P7/packages/web"

# THE INVOCATION IS TAKEN OUT OF THE VENDORED SKILL, not written here. A hand-written path would
# pass while the skill pointed somewhere else, which is the exact drift this asserts against.
inv="$(grep -o 'bash "\$(git rev-parse --show-toplevel 2>/dev/null || pwd)/\.claude/adb/lib/implement-lib\.sh"' \
        "$P7/.claude/skills/implement-issue/SKILL.md" | head -1)"
if [ -n "$inv" ]; then
  ok
  out="$( cd "$P7/packages/web" && eval "$inv" admit "$P7/.claude/state" 2>&1 )"; rc=$?
  # `admit` returns 0 (admitted) on a clean state dir. Anything that is not 0 or a documented
  # refusal code means the library did not RESOLVE — which is the failure this is here to catch.
  case "$rc" in
    0|10|11|12|13|14) ok ;;
    127|126) bad "the vendored implement-lib.sh did not resolve from a subdirectory (rc $rc): $out" ;;
    *) bad "the vendored implement-lib.sh failed unexpectedly (rc $rc): $out" ;;
  esac
  has "$out" "admitted" "runnable: implement-lib.sh admit runs from the vendored payload"
else
  bad "runnable: the vendored implement-issue skill carries no re-anchored implement-lib.sh invocation"
fi

# Three more libraries the loop calls, each executed from the vendored copy.
for _lib in role-dispatch project-gates cleanup-lib; do
  out="$( cd "$P7/packages/web" && bash "$(git -C "$P7" rev-parse --show-toplevel)/.claude/adb/lib/$_lib.sh" -h 2>&1 )"; rc=$?
  case "$rc" in
    126|127) bad "runnable: the vendored $_lib.sh did not resolve (rc $rc)" ;;
    *) ok ;;
  esac
done

# THE VENDORED GATE MUST FIND ITS SIBLING LIBRARY. Its failure mode is the broken-install posture,
# which is silent-ish by design, so the resolution is asserted directly.
out="$( cd "$P7" && bash "$P7/.claude/adb/precommit-gate.sh" </dev/null 2>&1 )"; rc=$?
hasnt "$out" "required library not found" "runnable: the vendored Stop gate resolves its sibling lib/"
hasnt "$out" "No such file or directory" "runnable: … with no missing-file error"

# ================================ entry points ==================================================

P6="$(new_project entrypoints)"
bash "$ROOT/install.sh" --pinned --project "$P6" --agent claude --artifact "$ART" --sums "$SUMS" >/dev/null 2>&1; rc=$?
yes "$rc" "install.sh --pinned dispatches to the pinned installer"
file_is "$P6/.ai-dev-baseline/upstream.toml" "install.sh --pinned really installed"
bash "$ROOT/uninstall.sh" --pinned --project "$P6" >/dev/null 2>&1; rc=$?
yes "$rc" "uninstall.sh --pinned dispatches to the pinned uninstaller"
file_isnt "$P6/.ai-dev-baseline/upstream.toml" "uninstall.sh --pinned really removed it"

# THE GLOBAL MODEL IS UNCHANGED BY CONSTRUCTION, and that is asserted rather than assumed: a
# no-argument install.sh must still take the global path.
out="$(bash "$ROOT/install.sh" --help 2>&1)"
has "$out" "--pinned" "install.sh --help documents the second model"
has "$out" "installs the 'claude' agent" "install.sh --help still documents the global model first"

check_summary check-pinned-install
