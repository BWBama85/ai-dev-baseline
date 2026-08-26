#!/usr/bin/env bash
# ai-dev-baseline — unit tests for scripts/lib/common.sh.
#
# The shared primitives are now sourced by the installer, uninstaller, both adapters,
# agent-init, and the runtime gates — so a regression here breaks every one at once.
# These temp-dir tests exercise the edge cases the callers depend on: idempotent /
# backup / replace symlinking, ownership-scoped unlinking, the absent-vs-empty TOML
# distinction, a '#' inside a quoted value, and semantic-version boundaries.
#
# Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks the whole scripts/lib
# dir into ~/.<agent>/scripts/lib, and test code must not ship into a user's runtime.
#
# Usage: bash scripts/check-common-lib.sh   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and deliberately before BOTH `set -u` and the cd.
#
# Before the cd, because $0 is frozen at invocation: a script that has already changed directory
# may be unable to name itself for the re-exec.
#
# Before `set -u`, because sourcing is not the place to enforce it. An unbound variable expanded
# while a library loads is FATAL under `set -u` — it kills the shell outright, before this script
# has run a line of its own — so a single bad expansion anywhere in common.sh would take out the
# whole suite with a message about a variable rather than about the library. `set -u` goes on
# immediately below and governs everything this script actually does.
#
# And the load is confirmed by PROBING FOR THE FUNCTION, not by the source's exit status: a
# sourced file returns its LAST command's status, so `. lib || exit 1` reports whatever that
# happened to be and says nothing about whether the file loaded. Same idiom as project-gates.sh
# and roadmap-lib.sh, which learned this first.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/lib/common.sh
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no + check_summary + check_git / check_make_repo_pair

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- adb_toml_get / adb_toml_unquote ----------------------------------------
f="$work/agents.toml"
cat > "$f" <<'EOF'
[roles]
primary = "claude"
review  = ["claude", "gemini"]

[gates]
typecheck = "pnpm typecheck"
lint      = ""
test      = "echo hi # inside string"
format    = "printf \"hi\""
EOF

eq "$(adb_toml_get "$f" roles primary)" '"claude"' "toml scalar keeps quotes"
eq "$(adb_toml_get "$f" roles review)"  '["claude", "gemini"]' "toml array verbatim"
adb_toml_get "$f" roles missing >/dev/null; no $? "toml absent key returns nonzero"

v="$(adb_toml_get "$f" gates lint)"; rc=$?
yes "$rc" "toml present-empty returns zero"
eq "$(adb_toml_unquote "$v")" "" "empty string unquotes to empty"

v="$(adb_toml_get "$f" gates typecheck)"
eq "$(adb_toml_unquote "$v")" "pnpm typecheck" "scalar unquotes"

v="$(adb_toml_get "$f" gates test)"
eq "$(adb_toml_unquote "$v")" "echo hi # inside string" "hash inside quotes preserved"

# A backslash-escaped quote must NOT end the string (no truncation) — the value is
# returned verbatim, backslashes intact (regression from PR #34 bot review).
v="$(adb_toml_get "$f" gates format)"
eq "$(adb_toml_unquote "$v")" 'printf \"hi\"' "escaped quote does not truncate"

adb_toml_get "$work/nope.toml" gates test >/dev/null; no $? "missing file returns nonzero"

# A FILE THAT EXISTS BUT CANNOT BE READ IS 2, NOT 1 (PR #429) — and the layered reader must not
# fall through it to the next layer. Both used to come back as "absent", so an unreadable repo
# manifest handed every consumer the global value or a built-in in place of the operator's own.
# Skipped as root, which can read a mode-000 file.
if [ "$(id -u)" -ne 0 ]; then
  u="$work/unreadable.toml"; printf '[mcp]\nrequired = ["context7"]\n' > "$u"; chmod 000 "$u"
  adb_toml_get "$u" mcp required >/dev/null 2>&1
  eq "$?" 2 "an unreadable file returns 2, never 'absent'"
  adb_toml_layered_get "$u" "$f" roles primary >/dev/null 2>&1
  eq "$?" 2 "…and the layered reader returns it rather than consulting the next layer"
  adb_toml_layered_get "$f" "$u" mcp required >/dev/null 2>&1
  eq "$?" 2 "…from the global layer too, when the repo one lacks the key"
  chmod 600 "$u"
else
  ok; ok; ok
fi
# A NUL BYTE IS 3: command substitution DISCARDS it, so `contex<NUL>t7` would otherwise parse as a
# clean `context7` the operator never wrote.
z="$work/nul.toml"; printf '[mcp]\nrequired = ["contex\000t7"]\n' > "$z"
adb_toml_get "$z" mcp required >/dev/null 2>&1
eq "$?" 3 "a file carrying a NUL byte returns 3 — not TOML, not absent"
adb_toml_layered_get "$z" "$f" roles primary >/dev/null 2>&1
eq "$?" 3 "…and the layered reader does not fall through it"
# …while the ordinary answers are unchanged: an absent repo manifest still reaches the global one.
eq "$(adb_toml_layered_get "$work/nope.toml" "$f" roles primary)" '"claude"' \
   "an absent repo manifest still falls through to the global layer"
adb_toml_layered_get "$work/nope.toml" "$work/nope2.toml" roles primary >/dev/null
eq "$?" 1 "…and neither layer defining the key is still 1"
eq "$(adb_toml_layered_get "$f" "$work/nope.toml" roles primary --with-layer)" 'repo "claude"' \
   "…and --with-layer still names the layer that answered"
# THE SHARED DIAGNOSTIC — one home for the two sentences every consumer prints (PR #429).
adb_toml_read_error "$z" 3 2>/dev/null; yes $? "adb_toml_read_error accepts status 3"
has "$(adb_toml_read_error "$z" 3 2>&1)" "NUL byte"          "…and names the NUL byte for 3"
has "$(adb_toml_read_error "$z" 2 2>&1)" "could not be read" "…and the read failure for 2"
adb_toml_read_error "$z" 1 2>/dev/null; no $? "…and returns 1 for a status that is not a read failure"

# key present in a DIFFERENT table must not match
eq "$(adb_toml_get "$f" roles typecheck 2>/dev/null)" "" "key scoped to its table"

# --- adb_toml_array ----------------------------------------------------------
# Parse a flat TOML array literal (as adb_toml_get returns it) into bare elements, one per line.
eq "$(adb_toml_array '["claude", "gemini"]' | tr '\n' ',')" "claude,gemini," "array → elements"
eq "$(adb_toml_array '["claude"]')"                          "claude"         "single-element array"
eq "$(adb_toml_array '[]')"                                  ""               "empty array → nothing"
eq "$(adb_toml_array '"claude"')"                            ""               "a scalar is not an array"
eq "$(adb_toml_array '')"                                    ""               "empty input → nothing"
eq "$(adb_toml_array '[ "a" ,  "b" ]' | tr '\n' ',')"        "a,b,"           "whitespace around elements trimmed"
# A login containing [ ] (e.g. copilot[bot]) survives — the outer close is the LAST ].
eq "$(adb_toml_array '["chatgpt-codex-connector", "copilot[bot]"]' | tr '\n' ',')" \
   "chatgpt-codex-connector,copilot[bot]," "elements may contain [ ]"
# End-to-end through adb_toml_get: read the array then split it.
eq "$(adb_toml_array "$(adb_toml_get "$f" roles review)" | tr '\n' ',')" "claude,gemini," "toml_get + toml_array compose"

# --- literal table matching + adb_toml_keys ---------------------------------
# A dotted sub-table must not be matched via the "." regex metacharacter, and reading a
# parent table must not leak the sub-table's keys (regression: issue #5/#19 [gates.scope]).
g="$work/dotted.toml"
cat > "$g" <<'EOF'
[gates]
build = "npm run build"
test  = "vitest"

[gates.scope]
build = "apps/**"
EOF
eq "$(adb_toml_unquote "$(adb_toml_get "$g" gates build)")"       "npm run build" "parent [gates] value not shadowed by sub-table"
eq "$(adb_toml_unquote "$(adb_toml_get "$g" gates.scope build)")" "apps/**"       "[gates.scope] read literally (dot is not a wildcard)"
adb_toml_get "$g" gatesXscope build >/dev/null 2>&1; no $? "literal table: 'gatesXscope' does not match [gates.scope]"

# adb_toml_keys lists only the bare identifier keys of the requested table, in file order.
eq "$(adb_toml_keys "$g" gates | tr '\n' ',')"       "build,test," "adb_toml_keys lists [gates] keys in order"
eq "$(adb_toml_keys "$g" gates.scope | tr '\n' ',')" "build,"      "adb_toml_keys scoped to the sub-table"
eq "$(adb_toml_keys "$g" missingtbl)" "" "adb_toml_keys on an absent table prints nothing"
adb_toml_keys "$work/nope.toml" gates >/dev/null; yes $? "adb_toml_keys on a missing file returns 0"

# --- adb_version_ge ----------------------------------------------------------
adb_version_ge 2.1.163 2.1.163; yes $? "equal versions >="
adb_version_ge 2.1.200 2.1.163; yes $? "higher patch >="
adb_version_ge 2.1.9   2.1.163; no  $? "numeric compare (9 < 163)"
adb_version_ge 2.2     2.1.163; yes $? "shorter-but-higher minor >="
adb_version_ge 1.9.9   2.0.0;   no  $? "lower major not >="
adb_version_ge 2.0     2.0.0;   yes $? "missing trailing component is 0"

# TWO PATHS, ONE SEMANTICS (#256). adb_version_ge grew a fork-free shell path for strictly-numeric
# operands, because the bash floor gate calls it at the top of every entry point and forking `awk`
# there made a BROKEN awk report itself as a bash-version failure. A shortcut inside a primitive is
# only safe while it agrees with the definition it shortcuts, and "agrees" is not something a
# handful of hand-picked cases establishes — so this compares the two implementations directly,
# over every combination of a corpus chosen to sit on the boundaries (equal, shorter, longer,
# leading zeros, multi-digit components that sort differently as strings, and empty).
_vg_awk() {
  awk -v v="$1" -v min="$2" '
    BEGIN {
      nv = split(v, V, "."); nm = split(min, M, ".");
      n = (nv > nm) ? nv : nm;
      for (i = 1; i <= n; i++) {
        a = (i <= nv) ? V[i] + 0 : 0; b = (i <= nm) ? M[i] + 0 : 0;
        if (a > b) exit 0; if (a < b) exit 1;
      }
      exit 0;
    }'
}
_vg_mismatch=0; _vg_pairs=0
for _vg_a in 5.3 5.3.15 5.2.21 3.2.57 2.1 2.1.0 2.1.163 6.0 0 0.0 10.2 1.10 1.9 "" 5.3.0 99 000.1 5.03; do
  for _vg_b in 5.3 2.1.163 0 "" 5.3.0 1.10 3.2.57 99.99; do
    _vg_awk "$_vg_a" "$_vg_b"; _vg_x=$?
    adb_version_ge "$_vg_a" "$_vg_b"; _vg_y=$?
    _vg_pairs=$((_vg_pairs + 1))
    [ "$_vg_x" = "$_vg_y" ] || { _vg_mismatch=$((_vg_mismatch + 1)); bad "version_ge paths disagree on [$_vg_a] vs [$_vg_b]: awk=$_vg_x shell=$_vg_y"; }
  done
done
[ "$_vg_mismatch" -eq 0 ] && ok
eq "$_vg_pairs" "144" "version_ge differential covered every pair (a zero-pair loop would pass vacuously)"

# The awk quirks are the CONTRACT, not an accident, so the shortcut must decline these rather than
# reproduce them differently: awk's `+ 0` reads "x" as 0 but "5abc" as 5.
adb_version_ge 5abc 5;  yes $? "non-numeric junk keeps awk's numeric-prefix reading (5abc -> 5)"
adb_version_ge x 0;     yes $? "wholly non-numeric sorts as 0, as documented"
adb_version_ge 0 1;     no  $? "and the shortcut still answers the ordinary case"

# --- adb_link ----------------------------------------------------------------
src="$work/src.txt"; echo original > "$src"
backup="$work/backup"
dest="$work/dest.txt"

adb_link "$src" "$dest" "$backup" >/dev/null
if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then ok; else bad "adb_link creates symlink"; fi

# idempotent: second run is a no-op, no backup created
out="$(adb_link "$src" "$dest" "$backup")"
case "$out" in *"ok "*) ok ;; *) bad "adb_link idempotent no-op (got: $out)" ;; esac

# real file at dest gets backed up (mirrored absolute path under backup dir)
dest2="$work/real.txt"; echo preexisting > "$dest2"
adb_link "$src" "$dest2" "$backup" >/dev/null
if [ -L "$dest2" ] && [ -f "$backup$dest2" ]; then ok; else bad "adb_link backs up a real file"; fi
eq "$(cat "$backup$dest2")" "preexisting" "backup preserves original content"

# a symlink pointing elsewhere gets replaced
other="$work/other.txt"; echo other > "$other"
dest3="$work/wrong.txt"; ln -s "$other" "$dest3"
adb_link "$src" "$dest3" "$backup" >/dev/null
eq "$(readlink "$dest3")" "$src" "adb_link replaces a wrong symlink"

# backup dir with a space in the path
spacebk="$work/back up dir"
dest4="$work/withspace.txt"; echo real4 > "$dest4"
adb_link "$src" "$dest4" "$spacebk" >/dev/null
if [ -f "$spacebk$dest4" ]; then ok; else bad "adb_link handles a spaced backup path"; fi

# --- adb_link source-existence guard (#48) -----------------------------------
# A missing source must fail LOUD and leave the destination completely untouched: no dangling
# link, no backup, and a pre-existing real file at dest preserved byte-for-byte.
missing="$work/does-not-exist.txt"

# (a) dest absent: guard returns non-zero and creates NO link.
guarddest="$work/guard-fresh.txt"
adb_link "$missing" "$guarddest" "$backup" 2>/dev/null; no $? "adb_link missing source returns nonzero"
if [ ! -e "$guarddest" ] && [ ! -L "$guarddest" ]; then ok; else bad "adb_link missing source creates no dangling link"; fi

# (b) dest is a real file: it must survive untouched (not backed up, not replaced).
guardreal="$work/guard-real.txt"; echo keepme > "$guardreal"
adb_link "$missing" "$guardreal" "$backup" 2>/dev/null; no $? "adb_link missing source (real dest) returns nonzero"
if [ -f "$guardreal" ] && [ ! -L "$guardreal" ]; then ok; else bad "adb_link missing source must not disturb a real dest"; fi
eq "$(cat "$guardreal")" "keepme" "adb_link missing source preserves the real dest content"

# (c) a dangling-symlink source counts as missing (never link through a broken source).
danglesrc="$work/dangle-src"; ln -s "$work/nowhere" "$danglesrc"
adb_link "$danglesrc" "$work/guard-dangle.txt" "$backup" 2>/dev/null; no $? "adb_link dangling-symlink source returns nonzero"
if [ ! -e "$work/guard-dangle.txt" ]; then ok; else bad "adb_link dangling source creates no link"; fi

# --- adb_agent_manifest (#48) ------------------------------------------------
# One producer of the install surface. Assert the shape: TAB-separated <src>\t<dest>, absolute
# sources with NO trailing slash on skill dirs, and the canonical scripts/lib entry.
mrepo="$work/mrepo"; mhome="$work/mhome"
mkdir -p "$mrepo/agents/claude/skills/demo" "$mrepo/agents/claude/scripts" "$mrepo/scripts/lib" \
         "$mrepo/agents/codex/skills/demo" "$mrepo/agents/gemini/skills/demo"
tab_=$'\t'
man="$(adb_agent_manifest claude "$mrepo" "$mhome")"
# root doc line present, TAB-separated, pointing at the right dest
echo "$man" | grep -Fq -- "$mrepo/agents/claude/CLAUDE.md${tab_}$mhome/.claude/CLAUDE.md" && ok || bad "manifest emits the claude root-doc line"
# skill dir: absolute source, NO trailing slash, dest under ~/.claude/skills/<name>
echo "$man" | grep -Fq -- "$mrepo/agents/claude/skills/demo${tab_}$mhome/.claude/skills/demo" && ok || bad "manifest emits skill dir with no trailing slash"
echo "$man" | grep -q '/skills/demo/	' && bad "manifest skill source must not carry a trailing slash" || ok
# every wired hook script + scripts/lib. DERIVED from the hook enumeration rather than named, so
# a hook added there is asserted here for free — and a hardcoded name cannot be orphaned by a
# retirement the way one already was (#378, D73).
while IFS= read -r hookname; do
  [ -n "$hookname" ] || continue
  echo "$man" | grep -Fq -- "$mrepo/agents/claude/scripts/$hookname${tab_}$mhome/.claude/scripts/$hookname" \
    && ok || bad "manifest emits $hookname"
done <<EOF
$(adb_claude_hook_scripts)
EOF
echo "$man" | grep -Fq -- "$mrepo/scripts/lib${tab_}$mhome/.claude/scripts/lib" && ok || bad "manifest emits canonical scripts/lib"
# codex manifest: root doc + rendered skills (no trailing slash) + shared gate runner (#12)
cman="$(adb_agent_manifest codex "$mrepo" "$mhome")"
echo "$cman" | grep -Fq -- "$mrepo/agents/codex/AGENTS.md${tab_}$mhome/.codex/AGENTS.md" && ok || bad "codex manifest emits the root-doc line"
echo "$cman" | grep -Fq -- "$mrepo/agents/codex/skills/demo${tab_}$mhome/.codex/skills/demo" && ok || bad "codex manifest emits skill dir (no trailing slash) under ~/.codex/skills"
echo "$cman" | grep -Fq -- "$mrepo/scripts/lib${tab_}$mhome/.codex/scripts/lib" && ok || bad "codex manifest emits the shared gate runner (scripts/lib)"
# gemini manifest: root doc + rendered skills under the ~/.gemini/config customization root (#13)
gman="$(adb_agent_manifest gemini "$mrepo" "$mhome")"
echo "$gman" | grep -Fq -- "$mrepo/agents/gemini/GEMINI.md${tab_}$mhome/.gemini/GEMINI.md" && ok || bad "gemini manifest emits the root-doc line"
echo "$gman" | grep -Fq -- "$mrepo/agents/gemini/skills/demo${tab_}$mhome/.gemini/config/skills/demo" && ok || bad "gemini manifest emits skill dir under ~/.gemini/config/skills"
echo "$gman" | grep -Fq -- "$mrepo/scripts/lib${tab_}$mhome/.gemini/scripts/lib" && ok || bad "gemini manifest emits the shared gate runner (scripts/lib)"
eq "$(adb_agent_manifest bogus "$mrepo" "$mhome")" "" "unknown agent manifest prints nothing"

# --- adb_link_manifest (#48) -------------------------------------------------
# Consumes a manifest and links each entry; accumulates a non-zero status if ANY entry fails.
lmbk="$work/lm-backup"
good1="$mrepo/agents/claude/CLAUDE.md"; echo doc > "$good1"
good2="$mrepo/scripts/lib/common.sh"; echo lib > "$good2"
d1="$work/lm-d1"; d2="$work/lm-d2"
printf '%s\t%s\n%s\t%s\n' "$good1" "$d1" "$good2" "$d2" | { adb_link_manifest "$lmbk" >/dev/null; }
# (piping into a group runs adb_link_manifest in a subshell; assert on the RESULT links instead)
if [ -L "$d1" ] && [ -L "$d2" ]; then ok; else bad "adb_link_manifest links every good entry"; fi

# all-good manifest returns 0 (fed via heredoc so status propagates without a subshell)
adb_link_manifest "$lmbk" >/dev/null <<EOF
$good1	$work/lm-d3
EOF
yes $? "adb_link_manifest all-good returns zero"

# a missing source in the manifest makes the whole call return non-zero, but still links the good ones
adb_link_manifest "$lmbk" >/dev/null 2>&1 <<EOF
$good1	$work/lm-ok
$work/lm-missing-src	$work/lm-bad
EOF
no $? "adb_link_manifest returns nonzero when any source is missing"
if [ -L "$work/lm-ok" ] && [ ! -e "$work/lm-bad" ]; then ok; else bad "adb_link_manifest links good entries and skips the missing-source one"; fi

# a malformed line (no TAB / empty column) is a hard failure, not a silent skip
adb_link_manifest "$lmbk" >/dev/null 2>&1 <<EOF
$good1
EOF
no $? "adb_link_manifest hard-fails a malformed (single-column) line"

# --- adb_unlink_manifest (#48) -----------------------------------------------
# Remove-side mirror: unlinks each <dest> ownership-scoped. Link two dests, then unlink via a
# manifest and assert only the OURS-into-repo one is removed (a foreign link is left alone).
umrepo="$mrepo"     # links into this repo dir count as "ours"
umsrc="$umrepo/agents/claude/CLAUDE.md"     # a real file inside the repo
umdest="$work/um-ours"; ln -s "$umsrc" "$umdest"
umforeign="$work/um-foreign"; ln -s "$work/lm-d1" "$umforeign"   # points outside the repo
adb_unlink_manifest "$umrepo" >/dev/null <<EOF
$umsrc	$umdest
$umsrc	$umforeign
EOF
if [ ! -e "$umdest" ]; then ok; else bad "adb_unlink_manifest removes an ours-into-repo link"; fi
if [ -L "$umforeign" ]; then ok; else bad "adb_unlink_manifest must leave a foreign link (not ours)"; fi

# --- the retirement register + its pruner (#378) -------------------------------------------------
# The register says which destinations the install USED TO create. Its consumer deletes exactly
# those links and nothing else — so every assertion below is about what SURVIVES as much as about
# what goes: a pruner that over-reaches is a global uninstaller nobody asked for.
#
# COUNT FIRST, so an empty register is visible. Every case after this one loops over the register,
# and a register that had silently emptied would pass all of them by running none of them.
rreg="$(adb_agent_manifest_retired claude "$mrepo" "$mhome")"; rrc=$?
yes "$rrc" "retired register: claude enumerates without refusing"
if [ "$(printf '%s\n' "$rreg" | grep -c .)" -ge 1 ]; then ok
else bad "retired register: claude names at least one row (an empty register makes the cases below vacuous)"; fi
eq "$(adb_agent_manifest_retired bogus "$mrepo" "$mhome")" "" "retired register: an unknown agent prints nothing"
yes "$(adb_agent_manifest_retired bogus "$mrepo" "$mhome" >/dev/null 2>&1; echo $?)" \
   "retired register: ...and returns 0, exactly as adb_agent_manifest does"
# Same refusal contract as the live producer: an unrepresentable root emits NOTHING and returns 1,
# or a caller reading stdout alone would prune from a partial map. A `$'…'` literal, never
# `"$(printf '\n')"` — command substitution strips the trailing newline and the case tests nothing.
rbadhome="$mhome"$'\n'"shadow"
rout="$(adb_agent_manifest_retired claude "$mrepo" "$rbadhome" 2>/dev/null)"; rrc=$?
no "$rrc" "retired register: an unrepresentable home is refused"
eq "$rout" "" "retired register: a refused home emits NO rows"

# The pruner, driven over a fixture that stages every outcome at once.
rp="$work/retire"; mkdir -p "$rp/repo" "$rp/home"
rp_gone="$rp/repo/gone.sh"                                   # deliberately never created
rp_live="$rp/repo/live.sh"; printf 'live\n' > "$rp_live"
ln -s "$rp_gone" "$rp/home/dangling"                         # ours, retired, dead   -> pruned
ln -s "$rp_live" "$rp/home/resolving"                        # retired but RESOLVES  -> kept
ln -s "$rp/repo/other.sh" "$rp/home/other-target"            # dangles, wrong target -> kept
printf 'real\n' > "$rp/home/realfile"                        # a real file           -> kept
adb_prune_retired_manifest >/dev/null <<EOF
$rp_gone	$rp/home/dangling
$rp_live	$rp/home/resolving
$rp_gone	$rp/home/other-target
$rp_gone	$rp/home/realfile
EOF
yes $? "prune-retired: a well-formed register returns zero"
if [ ! -L "$rp/home/dangling" ]; then ok; else bad "prune-retired: removes the retired, dangling, exact-target link"; fi
if [ -L "$rp/home/resolving" ]; then ok; else bad "prune-retired: must KEEP a retired link that still resolves"; fi
if [ -L "$rp/home/other-target" ]; then ok; else bad "prune-retired: must KEEP a dangling link to a DIFFERENT target"; fi
if [ -f "$rp/home/realfile" ] && [ ! -L "$rp/home/realfile" ]; then ok
else bad "prune-retired: must never delete a real file at a retired destination"; fi

# A malformed register removes NOTHING — the two-pass rule (#324, D64). Staged with a live victim
# so the assertion is about the filesystem, not only the status: the pre-two-pass shape returned
# non-zero having already deleted the records before the bad one.
ln -s "$rp_gone" "$rp/home/victim"
adb_prune_retired_manifest >/dev/null 2>&1 <<EOF
$rp_gone	$rp/home/victim
$rp_gone
EOF
no $? "prune-retired: a malformed register is a hard failure"
if [ -L "$rp/home/victim" ]; then ok; else bad "prune-retired: a malformed register must remove NOTHING"; fi

# A removal that FAILS is a named non-zero, never a silent success (#378 review): a read-only
# destination directory leaves the link in place, and a zero would let both installers report a
# clean prune over a dangle that survived.
mkdir -p "$rp/home/ro"
ln -s "$rp_gone" "$rp/home/ro/stuck"
chmod 555 "$rp/home/ro"
rerr2="$(adb_prune_retired_manifest 2>&1 >/dev/null <<EOF
$rp_gone	$rp/home/ro/stuck
EOF
)"
rrc2=$?
chmod 755 "$rp/home/ro"
no "$rrc2" "prune-retired: a failed removal returns non-zero"
if [ -L "$rp/home/ro/stuck" ]; then ok; else bad "prune-retired: the unremovable link is still present"; fi
case "$rerr2" in *"could not remove retired link"*) ok ;;
  *) bad "prune-retired: the failure names the link on stderr" ;; esac

# The wrapper both installers call: register -> pruner, in one place. Its fixture is READ FROM the
# register rather than spelled out, so this case cannot be orphaned by the next retirement the way
# a hardcoded destination would be.
rwrow="$(printf '%s\n' "$rreg" | head -n 1)"
rwsrc="${rwrow%%"$tab_"*}"; rwdest="${rwrow#*"$tab_"}"
mkdir -p "$(dirname "$rwdest")"; ln -s "$rwsrc" "$rwdest"
adb_prune_retired claude "$mrepo" "$mhome" >/dev/null
yes $? "prune-retired: the wrapper returns zero on a clean register"
if [ ! -L "$rwdest" ]; then ok
else bad "prune-retired: the wrapper actually removes the register's dangling destination"; fi
adb_prune_retired bogus "$mrepo" "$mhome" >/dev/null
yes $? "prune-retired: the wrapper is a silent no-op for an agent with no register"

# --- a path the manifest cannot represent is REFUSED, not emitted (#324, D64) ------------------
#
# The defect: `<src>TAB<home>/.claude/CLAUDE.md` with a NEWLINE inside <home> is not a malformed
# record, it is TWO records — and the first one's <dest> is a SHORTER path that frequently exists.
# Driven through the real caller, `adb_link_manifest` moved that real directory into the backup
# tree and symlinked over it, THEN returned non-zero. Every assertion below therefore checks the
# FILESYSTEM as well as the status: "returns non-zero" is satisfied by the buggy version too, and
# a test asserting only that would have passed against the exact code this fixes.
#
# BUILD THE DELIMITERS AS $'…' LITERALS. `"$(printf '\n')"` yields the EMPTY STRING (command
# substitution strips trailing newlines), which would turn every "unsafe" case below into a safe
# one and quietly test nothing — the same trap the adb_tsv_field_safe block records.
mf_nl="$mhome"$'\n'"shadow"        # internal newline — the reproduced case
mf_trail="$mhome"$'\n'             # TRAILING newline — the case $(…) erases
mf_tab="$mhome"$'\t'"col2"         # a TAB — forges the OTHER column
mf_repo_nl="$mrepo"$'\n'"shadow"

# (a) Each unsafe root refuses: non-zero AND no records. Both halves matter — a producer that
#     returned non-zero while still printing would leave every heredoc consumer linking anyway.
for mf_bad in "$mf_nl" "$mf_trail" "$mf_tab"; do
  mf_out="$(adb_agent_manifest claude "$mrepo" "$mf_bad" 2>/dev/null)"; mf_rc=$?
  no "$mf_rc" "manifest: an unrepresentable home is refused"
  eq "$mf_out" "" "manifest: a refused home emits NO records (atomic, not partial)"
done
mf_out="$(adb_agent_manifest claude "$mf_repo_nl" "$mhome" 2>/dev/null)"; mf_rc=$?
no "$mf_rc" "manifest: an unrepresentable source root is refused"
eq "$mf_out" "" "manifest: a refused source root emits NO records"

# (b) The diagnostic names each offending value on ONE physical line — a multi-line diagnostic would
#     re-open the very hole it is reporting in whatever reads the caller's stderr.
#
#     CAPTURED TO A FILE, NOT THROUGH `$(…)`. Command substitution strips EVERY trailing newline, so
#     a `wc -l` over a captured string cannot tell a properly terminated line from one missing its
#     terminator — delete the `\n` from the printf format and a substitution-based guard stays green.
#     The file keeps the bytes, so the terminator can actually be asserted.
mf_errf="$work/mf-err.txt"
adb_agent_manifest claude "$mrepo" "$mf_nl" 2>"$mf_errf" >/dev/null
eq "$(wc -l < "$mf_errf" | tr -d ' ')" "1" "manifest: one unsafe root yields exactly one complete stderr line"
eq "$(tail -c 1 "$mf_errf" | od -An -c | tr -d ' ')" '\n' "manifest: the diagnostic line is newline-terminated"
mf_err="$(cat "$mf_errf")"
if [ -n "$mf_err" ]; then ok; else bad "manifest: a refusal must SAY something (silence is not a diagnostic)"; fi
# The two-character `\n` sequence, not a fixed spelling: bash 3.2 renders `a<NL>b` as `a$'\n'b`
# and 5.3 as `$'a\nb'`, and pinning either fails on the other runner CI uses (D29).
has "$mf_err" '\n' "manifest: the refusal renders the newline in escaped form"

#     ONE LINE *PER OFFENDING VALUE*, not one line per refusal — the two roots are diagnosed
#     independently, on purpose. Failing on the first would hide the second, and an operator with
#     both wrong would fix one, re-run, and be told about the other. The contract is stated that way
#     in `_adb_manifest_fields_safe`, in the CHANGELOG and in D64; this pins the plural case so the
#     wording and the behaviour cannot drift apart.
adb_agent_manifest claude "$mf_repo_nl" "$mf_nl" 2>"$mf_errf" >/dev/null
eq "$(wc -l < "$mf_errf" | tr -d ' ')" "2" "manifest: TWO unsafe roots yield one line each, not one combined line"
has "$(cat "$mf_errf")" "source root" "manifest: the plural diagnostic names the source root"
has "$(cat "$mf_errf")" "target home" "manifest: the plural diagnostic names the target home"

# (c) EVERY branch is guarded, not just claude's — the check is per-branch by construction, so a
#     branch that forgot its call is invisible to a claude-only test.
for mf_agent in claude codex gemini; do
  mf_out="$(adb_agent_manifest "$mf_agent" "$mrepo" "$mf_nl" 2>/dev/null)"; mf_rc=$?
  no "$mf_rc" "manifest: the $mf_agent branch refuses an unrepresentable home"
  eq "$mf_out" "" "manifest: the $mf_agent branch emits nothing when it refuses"
done

# (d) A SKILL DIRECTORY NAME is filesystem-controlled and lands in both columns, so it can poison
#     a record under otherwise safe roots. Its own fixture: mrepo is shared with the tests above.
skrepo="$work/skrepo"
mkdir -p "$skrepo/agents/claude/skills/good" "$skrepo/agents/claude/scripts" "$skrepo/scripts/lib"
mkdir -p "$skrepo/agents/claude/skills/bad"$'\n'"name"
mf_out="$(adb_agent_manifest claude "$skrepo" "$mhome" 2>/dev/null)"; mf_rc=$?
no "$mf_rc" "manifest: an unrepresentable SKILL directory name is refused"
eq "$mf_out" "" "manifest: one bad skill name refuses the WHOLE manifest, not just its record"

# (e) THE GUARD MUST STILL LET GOOD INPUT THROUGH. Without this, deleting the emitting `case`
#     bodies entirely would satisfy every assertion above — refusing everything is not a fix.
mf_out="$(adb_agent_manifest claude "$mrepo" "$mhome")"; mf_rc=$?
yes "$mf_rc" "manifest: a representable pair still succeeds"
if [ -n "$mf_out" ]; then ok; else bad "manifest: a representable pair still emits records"; fi

# (f) The unknown-agent contract survives. The check is deliberately INSIDE each known branch
#     rather than hoisted above the `case`, so an unknown token keeps printing nothing and
#     returning 0 even when paired with roots it would have rejected.
mf_out="$(adb_agent_manifest bogus "$mrepo" "$mf_nl" 2>/dev/null)"; mf_rc=$?
yes "$mf_rc" "manifest: an unknown agent still returns 0 even with an unsafe home"
eq "$mf_out" "" "manifest: an unknown agent still prints nothing"

# (g) NOTHING IS WRITTEN BEFORE THE REFUSAL — the assertion the old code fails.
#     The fixture is the reproduced split: record 1 well-formed and pointing at the truncated
#     prefix (a REAL directory holding real content), record 2 the orphan remainder. The prefix
#     must come through untouched: still a directory, byte-identical, unlinked, and un-backed-up.
lmpfx="$work/lm-prefix"; mkdir -p "$lmpfx"; printf 'PRECIOUS\n' > "$lmpfx/keep.txt"
cp "$lmpfx/keep.txt" "$work/lm-pristine.txt"
lmbk2="$work/lm-backup2"
adb_link_manifest "$lmbk2" >/dev/null 2>&1 <<EOF
$good1	$lmpfx
shadow/.claude/CLAUDE.md
EOF
no $? "adb_link_manifest refuses a manifest containing a malformed record"
if [ -d "$lmpfx" ] && [ ! -L "$lmpfx" ]; then ok; else bad "adb_link_manifest must not replace a real directory before refusing"; fi
if cmp -s "$lmpfx/keep.txt" "$work/lm-pristine.txt"; then ok; else bad "adb_link_manifest must leave the real directory's content byte-identical"; fi
if [ ! -e "$lmbk2" ]; then ok; else bad "adb_link_manifest must not create a backup before refusing"; fi

# (h) THE DELIMITER COUNT MUST BE EXACT, and every one of these cases defeated the first version of
#     the guard. `IFS=TAB read` cannot validate this format at all, because TAB is IFS *whitespace*:
#     bash folds runs of it and strips it at field edges, so an ADJACENT pair and a TRAILING one
#     both split into two innocent-looking fields. Measured on bash 5.3.15 before the fix: the first
#     two cases below returned **0 and created the symlink**. A third `read` variable does not help
#     — the folding precedes assignment — which is why the implementation counts with `case`.
#
#     Each case asserts the LINK as well as the status: "returns non-zero" is the half that was
#     already true for the three-column case and was never true for the other two.
lm_i=0
for lm_rec in \
  "$good1	  	DEST" \
  "$good1	DEST	" \
  "$good1	DEST	extra" \
  "	DEST" \
  "$good1	"
do
  lm_i=$((lm_i + 1))
  # The literal two-space filler above is replaced by a second real TAB, so the fixture carries
  # actual delimiter bytes rather than a spelling of them.
  lm_rec="${lm_rec/  /$(printf '\t')}"
  lm_dest="$work/lm-exact-$lm_i"
  lm_rec="${lm_rec//DEST/$lm_dest}"
  adb_link_manifest "$lmbk2" >/dev/null 2>&1 <<EOF
$lm_rec
EOF
  no $? "adb_link_manifest rejects record shape $lm_i (delimiter count/empty field)"
  if [ ! -e "$lm_dest" ] && [ ! -L "$lm_dest" ]; then ok
  else bad "adb_link_manifest must not link malformed record shape $lm_i"; fi
done
# A TAB-ONLY line is malformed under exact counting (the old folding read it as blank).
adb_link_manifest "$lmbk2" >/dev/null 2>&1 <<EOF
$(printf '\t')
EOF
no $? "adb_link_manifest rejects a tab-only line"
# And the ordinary two-column record still links, so 'reject everything' cannot satisfy the above.
adb_link_manifest "$lmbk2" >/dev/null 2>&1 <<EOF
$good1	$work/lm-exact-ok
EOF
yes $? "adb_link_manifest still accepts an exact two-column record"
if [ -L "$work/lm-exact-ok" ]; then ok; else bad "adb_link_manifest must still link an exact record"; fi

# (i) The remove side mirrors it: refuse, and remove NOTHING. It previously had no shape check at
#     all and returned whatever its loop last evaluated, so a truncated <dest> that happened to be
#     a symlink into the repo was deleted — correct ownership scoping, wrong path.
umkeep="$work/um-keep"; ln -s "$umsrc" "$umkeep"
adb_unlink_manifest "$umrepo" >/dev/null 2>&1 <<EOF
$umsrc	$umkeep
shadow/.claude/CLAUDE.md
EOF
no $? "adb_unlink_manifest refuses a manifest containing a malformed record"
if [ -L "$umkeep" ]; then ok; else bad "adb_unlink_manifest must remove nothing when it refuses"; fi

# --- adb_unlink_if_ours ------------------------------------------------------
repo="$work/repo"; mkdir -p "$repo"; echo r > "$repo/file"
ours="$work/ours.link"; ln -s "$repo/file" "$ours"
adb_unlink_if_ours "$ours" "$repo" >/dev/null
if [ ! -e "$ours" ]; then ok; else bad "unlink removes a symlink into repo"; fi

notours="$work/notours.link"; ln -s "$other" "$notours"
adb_unlink_if_ours "$notours" "$repo" >/dev/null
if [ -L "$notours" ]; then ok; else bad "unlink leaves a foreign symlink"; fi

realf="$work/realfile"; echo x > "$realf"
adb_unlink_if_ours "$realf" "$repo" >/dev/null
if [ -f "$realf" ]; then ok; else bad "unlink never deletes a real file"; fi

# --- adb_usage ---------------------------------------------------------------
# Prints the top comment block as --help: skips the shebang, strips "# ", stops at the first
# non-comment line (so a later section comment never leaks into help output).
uf="$work/tool.sh"
printf '%s\n' '#!/usr/bin/env bash' '# Tool one-liner.' '#   detail line' 'code_here=1' '# not in help' > "$uf"
usage_out="$(adb_usage "$uf")"
has "$usage_out" "Tool one-liner."   "adb_usage prints the header block"
has "$usage_out" "detail line"       "adb_usage keeps indented continuation lines"
hasnt "$usage_out" "not in help"     "adb_usage stops at the first non-comment line"
hasnt "$usage_out" "code_here"       "adb_usage does not print code"

# --- adb_default_branch ------------------------------------------------------
gitrepo="$work/gitrepo"
git init -q "$gitrepo"
git -C "$gitrepo" symbolic-ref HEAD refs/heads/main 2>/dev/null
check_git "$gitrepo" commit -q --allow-empty -m init
eq "$(adb_default_branch "$gitrepo")" "main" "default branch falls back to local main"

# --- adb_repo_root -----------------------------------------------------------
eq "$( cd "$gitrepo" && adb_repo_root )" "$(git -C "$gitrepo" rev-parse --show-toplevel)" "adb_repo_root in a git repo → git top-level"
nongit="$work/plain-dir"; mkdir -p "$nongit"
eq "$( cd "$nongit" && adb_repo_root )" "$( cd "$nongit" && pwd )" "adb_repo_root outside a git repo → pwd"

# --- adb_repo_shape + adb_shape_val/adb_shape_all (#23) ----------------------
# Facts are read through the shared accessors (adb_shape_val = first match, adb_shape_all = every
# match); canon() is the shared physical-path helper from check-lib.sh.

# (1) Tidy repo, cwd == root: root is canonical, cwd_is_root=1, parent not a repo, nothing exotic.
tidy="$work/tidy"; mkdir -p "$tidy"; git init -q "$tidy"
sh1="$(adb_repo_shape "$tidy")"
eq "$(adb_shape_val "$sh1" in_git)"        "1"            "shape: tidy repo is in_git"
eq "$(adb_shape_val "$sh1" root)"          "${ canon "$tidy"; }" "shape: root is the canonical git top-level"
eq "$(adb_shape_val "$sh1" cwd_is_root)"   "1"            "shape: cwd==root → cwd_is_root=1"
eq "$(adb_shape_val "$sh1" parent_in_git)" "0"            "shape: tidy repo's parent is not a git repo"
eq "$(adb_shape_val "$sh1" nested_in)"     ""             "shape: tidy repo is not nested"
eq "$(adb_shape_all "$sh1" foreign_doc)"   ""             "shape: tidy repo has no foreign docs"
eq "$(adb_shape_all "$sh1" extra_doc)"     ""             "shape: tidy repo has no extra docs"

# adb_shape_val returns only the FIRST match; adb_shape_all returns every line — verify on a
# hand-built multi-value blob so the two accessors' contract is pinned independent of the walk.
multi="${ printf 'k\tone\nk\ttwo\nother\tx\n'; }"
eq "$(adb_shape_val "$multi" k)"            "one"       "adb_shape_val returns the first match only"
eq "$(adb_shape_all "$multi" k | tr '\n' ',')" "one,two," "adb_shape_all returns every match"
eq "$(adb_shape_val "$multi" absent)"       ""          "adb_shape_val on an absent key prints nothing"

# (2) Working dir below the git root → cwd_is_root=0, root still the top-level.
mkdir -p "$tidy/sub/deeper"
sh2="$(adb_repo_shape "$tidy/sub/deeper")"
eq "$(adb_shape_val "$sh2" cwd_is_root)" "0"                "shape: cwd below root → cwd_is_root=0"
eq "$(adb_shape_val "$sh2" root)"        "${ canon "$tidy"; }" "shape: subdir still resolves the git root"

# (3) Nested repo: an inner repo checked out inside an outer repo.
outer="$work/outer"; mkdir -p "$outer"; git init -q "$outer"
inner="$outer/vendor/plugin"; mkdir -p "$inner"; git init -q "$inner"
sh3="$(adb_repo_shape "$inner")"
eq "$(adb_shape_val "$sh3" root)"          "${ canon "$inner"; }" "shape: nested inner repo resolves to itself"
eq "$(adb_shape_val "$sh3" parent_in_git)" "1"                 "shape: nested repo's parent is inside a git repo"
eq "$(adb_shape_val "$sh3" nested_in)"     "${ canon "$outer"; }" "shape: nested_in names the enclosing repo"

# (4) bama-style: a git repo dropped inside an UNTRACKED parent tree, with a root doc ABOVE it.
site="$work/site"; plugin="$site/wp-content/plugins/myplugin"
mkdir -p "$plugin"; git init -q "$plugin"
printf 'site root doc\n' > "$site/CLAUDE.md"        # outside any repo
sh4="$(adb_repo_shape "$plugin")"
eq "$(adb_shape_val "$sh4" root)"          "${ canon "$plugin"; }" "shape: bama-style resolves the plugin as root"
eq "$(adb_shape_val "$sh4" parent_in_git)" "0"                  "shape: bama-style parent is outside any git repo"
eq "$(adb_shape_val "$sh4" nested_in)"     ""                   "shape: bama-style is not nested in another repo"
has "$(adb_shape_all "$sh4" foreign_doc)"  "${ canon "$site"; }/CLAUDE.md" "shape: finds the out-of-repo site CLAUDE.md above"

# (5) Monorepo / layered: extra_doc lists an in-tree root doc that sits beside a manifest, and
# NEVER a bare doc with no manifest (the framework's own generated agents/<a>/CLAUDE.md class) or
# the top-level root doc itself.
mono="$work/mono"; mkdir -p "$mono/packages/api" "$mono/docs"; git init -q "$mono"
printf 'top\n'  > "$mono/CLAUDE.md"                 # top-level root doc — never an extra_doc
printf 'pkg\n'  > "$mono/packages/api/CLAUDE.md"    # beside a manifest → an extra_doc
printf '{}\n'   > "$mono/packages/api/package.json"
printf 'bare\n' > "$mono/docs/CLAUDE.md"            # no manifest sibling → NOT an extra_doc
git -C "$mono" add -A                                # extra_doc reads the index (tracked only)
sh5="$(adb_repo_shape "$mono")"
extra5="$(adb_shape_all "$sh5" extra_doc)"
has  "$extra5" "${ canon "$mono"; }/packages/api/CLAUDE.md" "shape: extra_doc includes a doc beside a manifest"
hasnt "$extra5" "docs/CLAUDE.md"                          "shape: extra_doc excludes a bare doc (no manifest)"
hasnt "$extra5" "${ canon "$mono"; }/CLAUDE.md"              "shape: extra_doc never lists the top-level root doc"
# An UNtracked package doc is invisible to extra_doc (git ls-files reads the index).
mkdir -p "$mono/packages/web"; printf 'web\n' > "$mono/packages/web/CLAUDE.md"; printf '{}\n' > "$mono/packages/web/package.json"
sh5b="$(adb_repo_shape "$mono")"
hasnt "$(adb_shape_all "$sh5b" extra_doc)" "packages/web/CLAUDE.md" "shape: extra_doc is tracked-only (untracked package doc excluded)"

# (6) Unreadable start dir → in_git=0 and a surfaced warning (never a silent empty result).
sh6="$(adb_repo_shape "$work/no/such/path")"
eq "$(adb_shape_val "$sh6" in_git)" "0"     "shape: nonexistent start is not in_git"
has "$(adb_shape_all "$sh6" warning)" "unreadable" "shape: nonexistent start emits a warning"

# --- adb_tsv_field_safe / adb_tsv_field_display (#278) -----------------------
# The shared record-field predicate D41 kept private to cleanup-lib.sh until adb_repo_shape
# adopted it. BUILD THE BAD VALUES WITH $'…' LITERALS, never `"$(printf '\n')"` — command
# substitution strips trailing newlines, so that spelling yields the EMPTY STRING and turns the
# whole test into a substring match against "" that passes for every input. A predicate that
# cannot fail is the exact shape self-review.md exists to catch.
yes "$( adb_tsv_field_safe "/plain/path"; echo $? )"        "tsv-safe: an ordinary path is serializable"
yes "$( adb_tsv_field_safe ""; echo $? )"                   "tsv-safe: the empty string is serializable"
no  "$( adb_tsv_field_safe "a${ printf '\t'; }b"; echo $? )" "tsv-safe: a TAB is refused"
# The predicate tests BYTES, not spellings: the five characters `$ ' \ n '` are not a newline, and
# a value carrying them is perfectly serializable. This is also the shape adb_display_value emits,
# so reading it as "unsafe" would make the renderer's output unrenderable.
yes "$( adb_tsv_field_safe "a\$'\\n'b"; echo $? )"          "tsv-safe: the literal characters \$'\\n' are not a newline byte"
# The three real carriers, spelled as actual bytes.
tsv_tab="a	b"                                  # a real TAB between a and b
tsv_mid="a
b"                                             # a real NEWLINE between a and b
tsv_trail="a
"                                              # a TRAILING newline — the case $(…) erases
no "$( adb_tsv_field_safe "$tsv_tab"; echo $? )"   "tsv-safe: a real tab byte is refused"
no "$( adb_tsv_field_safe "$tsv_mid"; echo $? )"   "tsv-safe: a real internal newline is refused"
no "$( adb_tsv_field_safe "$tsv_trail"; echo $? )" "tsv-safe: a real TRAILING newline is refused"
# The renderer must put a refused value on ONE physical line, or a diagnostic naming it re-opens
# the hole. Assert the line COUNT, not just the absence of a substring.
#
# AND ASSERT IT PRODUCED SOMETHING. "Zero newline bytes", "one line" and "passes the predicate" are
# ALL satisfied by the empty string, so those three alone describe a function whose body is `:`.
# That is not hypothetical: the independent review replaced this function's entire body with `:`
# and every one of the suite's 669 assertions still passed. A guard whose failure mode is silence
# needs an assertion that silence cannot satisfy, which is what the non-empty and content checks
# below are for.
disp_mid="$(adb_tsv_field_display "$tsv_mid")"
disp_tab="$(adb_tsv_field_display "$tsv_tab")"
eq "$(printf '%s' "$disp_mid" | wc -l | tr -d ' ')" "0" "tsv-display: a newline value renders with no newline byte"
eq "$(printf '%s' "$disp_tab" | wc -l | tr -d ' ')" "0" "tsv-display: a tab value renders on one line"
yes "$( adb_tsv_field_safe "$disp_mid"; echo $? )" "tsv-display: its own output passes the predicate"
if [ -n "$disp_mid" ]; then ok; else bad "tsv-display: renders something — an empty result is not a rendering"; fi
if [ -n "$disp_tab" ]; then ok; else bad "tsv-display: renders something for a tab value too"; fi
# The ESCAPED representation must actually be there. Asserted as the two-character `\n` sequence
# rather than an exact string, because bash 3.2 renders `a<NL>b` as `a$'\n'b` and 5.3 renders it as
# `$'a\nb'` — pinning either spelling would fail on the other platform CI runs (D29).
has "$disp_mid" '\n' "tsv-display: the newline appears in escaped form"
has "$disp_mid" 'a'  "tsv-display: and the surrounding content survives (left)"
has "$disp_mid" 'b'  "tsv-display: and the surrounding content survives (right)"
has "$disp_tab" '\t' "tsv-display: a tab appears in escaped form"
# THE FALLBACK SEAM. `%q` should never emit a raw delimiter, so the re-test is belt-and-braces and
# is unreachable through ordinary input — which is precisely why it needs a driven fixture rather
# than a hopeful comment. Shadowing the encoder inside a subshell is what makes the seam reachable:
# without this, the re-test could be deleted and nothing would notice.
eq "$( adb_display_value() { printf 'a\nb'; }; adb_tsv_field_display "x" )" "<unrenderable-value>" \
   "tsv-display: an encoder that returns an unsafe value falls back to the fixed token"
eq "$( adb_display_value() { printf 'safe-enough'; }; adb_tsv_field_display "x" )" "safe-enough" \
   "tsv-display: and a safe encoding is passed through unchanged"

# (7) A path this record format cannot represent is REFUSED, not truncated (#278, D59).
#
# The defect: `root<TAB>/w/project<NL>shadow` splits, and `adb_shape_val … root` returns
# `/w/project` — not a missing answer but a DIFFERENT directory that exists. bin/agent-init used
# that value as its write root. Each case below therefore asserts BOTH halves: no `root` is
# emitted, AND nothing was silently substituted for it.
#
# Every unsafe name is built with a $'…' literal for the reason spelled out above.
uns="$work/uns"; mkdir -p "$uns"
sib="$uns/project"; mkdir -p "$sib"; git init -q "$sib"     # the innocent sibling a truncation lands on

# (7a) internal newline — the issue's own reproduction.
nl_repo="$uns/project"$'\nshadow'; mkdir -p "$nl_repo"; git init -q "$nl_repo"
sh7a="$(adb_repo_shape "$nl_repo")"
eq "$(adb_shape_val "$sh7a" root)"   ""  "shape/unsafe: a newline path emits NO root"
eq "$(adb_shape_val "$sh7a" in_git)" ""  "shape/unsafe: a newline path emits no in_git either (atomic refusal)"
has "$(adb_shape_all "$sh7a" warning)" "cannot represent" "shape/unsafe: the refusal is surfaced as a warning"
# The whole point: the parsed root must not become the sibling.
hasnt "$(adb_shape_val "$sh7a" root)" "$sib" "shape/unsafe: the truncated sibling is never returned as root"
# ATOMIC means exactly one record. A count, because "the root key is absent" would also be true of
# a shape that emitted six other facts about a directory the caller never named.
eq "$(printf '%s\n' "$sh7a" | wc -l | tr -d ' ')" "1" "shape/unsafe: refusal emits exactly one record"
eq "$(printf '%s\n' "$sh7a" | cut -f1)" "warning"     "shape/unsafe: and that record is the warning"

# (7b) TAB — the issue names only newlines, but the record has two delimiters.
tab_repo="$uns/tabbed"$'\tx'; mkdir -p "$tab_repo"; git init -q "$tab_repo"
sh7b="$(adb_repo_shape "$tab_repo")"
eq "$(adb_shape_val "$sh7b" root)" "" "shape/unsafe: a TAB path emits no root"
has "$(adb_shape_all "$sh7b" warning)" "cannot represent" "shape/unsafe: a TAB path is refused too"

# (7c) TRAILING newline — the case a post-canonicalization check CANNOT see, because
# `abs="$(cd … && pwd -P)"` has already erased the byte by then. Without the sentinel-preserving
# capture in adb_repo_shape this repo resolves to `$sib` and the shape reports a clean, wrong root.
tr_repo="$uns/project"$'\n'; mkdir -p "$tr_repo"; git init -q "$tr_repo"
sh7c="$(adb_repo_shape "$tr_repo")"
eq "$(adb_shape_val "$sh7c" root)" "" "shape/unsafe: a TRAILING-newline path emits no root"
hasnt "$(adb_shape_val "$sh7c" root)" "$sib" "shape/unsafe: a trailing newline does not resolve to the sibling"

# (7d) A SAFE-named symlink whose PHYSICAL target is unsafe. The pre-resolution check passes here
# by construction, so this is what proves the second, post-resolution check is load-bearing.
ln -s "$nl_repo" "$uns/safe-link"
sh7d="$(adb_repo_shape "$uns/safe-link")"
eq "$(adb_shape_val "$sh7d" root)" "" "shape/unsafe: a safe symlink onto an unsafe physical path emits no root"
has "$(adb_shape_all "$sh7d" warning)" "resolves to a physical location" "shape/unsafe: and says it was the RESOLUTION that failed"

# (7f) The case that makes the SENTINEL capture load-bearing, and the only one that does. A safe
# start passes the first check; its physical target ends in a newline, which `$(cd … && pwd -P)`
# strips — so a plain capture yields `$sib`, the second check finds it perfectly serializable, and
# the shape reports a clean root for a directory nobody named. Every other unsafe case is caught by
# one of the two checks whether or not the capture preserves trailing bytes, so without this
# assertion the `printf 'X'` sentinel could be deleted and the suite would stay green.
ln -s "$tr_repo" "$uns/trail-link"
sh7f="$(adb_repo_shape "$uns/trail-link")"
eq "$(adb_shape_val "$sh7f" root)" "" "shape/unsafe: a safe symlink onto a TRAILING-newline target emits no root"
hasnt "$(adb_shape_val "$sh7f" root)" "$sib" "shape/unsafe: and does not silently resolve to the sibling"

# (7g) An unsafe path that does NOT EXIST. This is the case the pre-resolution check alone
# catches, and it is why that check cannot be folded into the post-resolution one: a nonexistent
# start never canonicalizes, so it falls through to the unreadable-start branch — which emits
# `root<TAB>$start` and a warning naming `$start`, both RAW. A start carrying `<NL>in_git<TAB>1`
# therefore FORGES two records on the way out of the very branch that exists to report an unknown.
# Verified by mutation: disabling the pre-resolution check turns this case red and nothing else.
ghost="$work/ghost"$'\nin_git\t1'
sh7g="$(adb_repo_shape "$ghost")"
eq "$(printf '%s\n' "$sh7g" | wc -l | tr -d ' ')" "1" "shape/unsafe: an unsafe NONEXISTENT path emits exactly one record"
eq "$(printf '%s\n' "$sh7g" | cut -f1)" "warning" "shape/unsafe: and that record is the warning, not a raw root"
eq "$(adb_shape_val "$sh7g" root)" "" "shape/unsafe: an unsafe nonexistent path emits no root"
# The forgery this prevents, asserted directly: the injected `in_git<TAB>1` must not appear at all.
eq "$(adb_shape_all "$sh7g" in_git | wc -l | tr -d ' ')" "0" "shape/unsafe: the injected in_git record is never emitted"

# (7h) The RESOLVED ROOT is unsafe while the start dir is perfectly safe. This is the case that
# refutes the tempting shortcut "root is start or an ancestor of it, so a safe start implies a safe
# root". `GIT_DIR`/`GIT_WORK_TREE` redirect git's answer to a tree that need not contain the start
# dir at all, so `--show-toplevel` returns the unsafe work tree from a clean working directory —
# and pre-guard, that path was emitted, split, and handed to agent-init as its write root.
wt_safe="$work/wt-safe"; mkdir -p "$wt_safe"
wt_bad="$work/worktree"$'\nredirect'; mkdir -p "$wt_bad"; git init -q "$wt_bad"
sh7h="$( GIT_DIR="$wt_bad/.git" GIT_WORK_TREE="$wt_bad" adb_repo_shape "$wt_safe" )"
eq "$(adb_shape_val "$sh7h" root)" "" "shape/unsafe: an unsafe RESOLVED root emits no root"
eq "$(printf '%s\n' "$sh7h" | wc -l | tr -d ' ')" "1" "shape/unsafe: an unsafe resolved root refuses atomically"
has "$sh7h" "resolved repository root" "shape/unsafe: and says it was the RESOLVED root that failed"

# (7j) The same redirection onto a work tree whose name ENDS in a newline. This is what makes the
# sentinel on the `git rev-parse` capture load-bearing: git terminates its answer with a newline
# and `$(…)` strips every trailing one, so without the sentinel this root arrives already
# shortened into a DIFFERENT path and then passes the check above looking entirely ordinary.
wt_trail="$work/worktree"$'\n'; mkdir -p "$wt_trail"; git init -q "$wt_trail"
sh7j="$( GIT_DIR="$wt_trail/.git" GIT_WORK_TREE="$wt_trail" adb_repo_shape "$wt_safe" )"
eq "$(adb_shape_val "$sh7j" root)" "" "shape/unsafe: a TRAILING-newline resolved root emits no root"
hasnt "$(adb_shape_val "$sh7j" root)" "$work/worktree" "shape/unsafe: and is not silently shortened into the sibling path"

# (7i) The ENCLOSING repo's root is unsafe while this repo's root is safe — a second, independent
# git query, redirected by `core.worktree` on the outer repo. Suppressed per FIELD, because
# `nested_in` is a note about a neighbour and this repo's own facts are sound.
nst_outer="$work/nst-outer"; mkdir -p "$nst_outer"; git init -q "$nst_outer"
nst_bad="$work/nst-redirected"$'\nwt'; mkdir -p "$nst_bad"
git -C "$nst_outer" config core.worktree "$nst_bad"
nst_inner="$nst_outer/inner"; mkdir -p "$nst_inner"; git init -q "$nst_inner"
sh7i="$(adb_repo_shape "$nst_inner")"
eq  "$(adb_shape_val "$sh7i" root)" "${ canon "$nst_inner"; }" "shape/unsafe: an unnameable ENCLOSING repo does not cost this repo its root"
eq  "$(adb_shape_val "$sh7i" nested_in)" "" "shape/unsafe: the unnameable enclosing root is not emitted as nested_in"
has "$(adb_shape_all "$sh7i" warning)" "enclosing repository root" "shape/unsafe: and dropping it is announced"
eq  "$(adb_shape_val "$sh7i" parent_in_git)" "1" "shape/unsafe: parent_in_git is still 1 — the fact is unaffected"
# No forged records from either redirection.
eq "$(printf '%s\n' "$sh7i" | cut -f1 \
      | grep -Evc '^(in_git|root|cwd_is_root|parent_in_git|nested_in|foreign_doc|extra_doc|scan_truncated|warning)$')" \
   "0" "shape/unsafe: an unnameable enclosing root forges no record"

# (7e) An unsafe tracked doc BELOW a perfectly safe root is suppressed per FIELD, not by refusing
# the whole shape — `rel` comes from `git ls-files`, so it is the one path-bearing value that is
# not a prefix of root. The good sibling doc must survive, or the fix would have cost a real fact.
xd="$work/xdoc"; mkdir -p "$xd"; git init -q "$xd"
mkdir -p "$xd/packages/good"; printf '{}\n' > "$xd/packages/good/package.json"; printf 'g\n' > "$xd/packages/good/CLAUDE.md"
xd_bad="$xd/packages/we"$'\nird'; mkdir -p "$xd_bad"
printf '{}\n' > "$xd_bad/package.json"; printf 'p\n' > "$xd_bad/CLAUDE.md"
git -C "$xd" add -A
sh7e="$(adb_repo_shape "$xd")"
eq  "$(adb_shape_val "$sh7e" root)" "${ canon "$xd"; }" "shape/unsafe: a safe root with an unsafe doc below it still resolves"
has "$(adb_shape_all "$sh7e" extra_doc)" "packages/good/CLAUDE.md" "shape/unsafe: the well-named extra_doc survives"
hasnt "$(adb_shape_all "$sh7e" extra_doc)" "ird/CLAUDE.md" "shape/unsafe: the unserializable extra_doc is not emitted"
has "$(adb_shape_all "$sh7e" warning)" "skipped an in-tree root doc" "shape/unsafe: dropping it is announced, never silent"
# No forged records: every line must carry a key from the documented schema. A forged line would
# arrive with an attacker-chosen key, so counting UNKNOWN keys is the assertion that catches it.
eq "$(printf '%s\n' "$sh7e" | cut -f1 \
      | grep -Evc '^(in_git|root|cwd_is_root|parent_in_git|nested_in|foreign_doc|extra_doc|scan_truncated|warning)$')" \
   "0" "shape/unsafe: no record carries a key outside the schema (nothing was forged)"

# --- adb_branch_sync_state ---------------------------------------------------
# Drive every state with a LOCAL bare "origin" (file://, no network): one working
# clone plus a second clone that advances origin, so behind/ahead/diverged are real.
sborigin="$work/syncorigin.git"; sbrepo="$work/syncrepo"
check_make_repo_pair "$sbrepo" "$sborigin" || { bad "sync-state fixture: repo pair init failed"; }
git -C "$sbrepo" symbolic-ref HEAD refs/heads/main
check_git "$sbrepo" commit -q --allow-empty -m c1
git -C "$sbrepo" push -q -u origin main
# Point the bare origin's HEAD at main so the second clone checks it out cleanly and
# gets a local main to push — otherwise (when the host git's init.defaultBranch != main,
# e.g. Linux CI) the clone warns "remote HEAD refers to nonexistent ref" and has no main.
git -C "$sborigin" symbolic-ref HEAD refs/heads/main
eq "$(adb_branch_sync_state "$sbrepo" main)" "current" "sync state: current"

# behind: a second clone pushes a commit; local fetches but stays put.
sbclone="$work/syncclone"; git clone -q "$sborigin" "$sbclone"
check_git "$sbclone" commit -q --allow-empty -m c2
git -C "$sbclone" push -q origin main
git -C "$sbrepo" fetch -q origin
eq "$(adb_branch_sync_state "$sbrepo" main)" "behind" "sync state: behind"

# ahead: fast-forward local to origin, then add an unpushed local commit.
git -C "$sbrepo" reset -q --hard origin/main
check_git "$sbrepo" commit -q --allow-empty -m local-only
eq "$(adb_branch_sync_state "$sbrepo" main)" "ahead" "sync state: ahead"

# diverged: origin advances (via the clone) while local keeps its unpushed commit.
check_git "$sbclone" commit -q --allow-empty -m c3
git -C "$sbclone" push -q origin main
git -C "$sbrepo" fetch -q origin
eq "$(adb_branch_sync_state "$sbrepo" main)" "diverged" "sync state: diverged"

# no-remote: a purely local branch with no origin/<branch> counterpart.
git -C "$sbrepo" branch feature-x
eq "$(adb_branch_sync_state "$sbrepo" feature-x)" "no-remote" "sync state: no-remote"

# --- adb_clone_local_state / adb_clone_status (#36) ---------------------------
# The no-network half of currency classification, moved out of bin/baseline so the SessionStart
# hook shares one implementation. What matters is that a clone which will be REFUSED is
# recognized from local state alone — no fetch, so no remote-tracking refs written and no
# network cost on a session started from an unsafe clone. Reuses the sync-state fixture above,
# which currently sits `diverged` with a local-only commit.
git -C "$sbrepo" reset -q --hard origin/main
git -C "$sbrepo" checkout -q main
eq "$(adb_clone_local_state "$sbrepo" main)" "local-ok" "local state: clean + on default → local-ok"
eq "$(adb_clone_status "$sbrepo" main)" "current" "clone status defers to the sync state when local-ok"

printf 'x\n' > "$sbrepo/dirty.txt"
eq "$(adb_clone_local_state "$sbrepo" main)" "dirty" "local state: an untracked change is dirty"
eq "$(adb_clone_status "$sbrepo" main)" "dirty" "clone status short-circuits on dirty"
rm -f "$sbrepo/dirty.txt"

# Every sentinel git writes for an operation in progress. A clean tree is NOT proof of safety:
# a rebase between steps and a bisect both leave one, and only some of them detach HEAD.
sbgit="$(git -C "$sbrepo" rev-parse --absolute-git-dir)"
for sentinel in rebase-merge/ rebase-apply/ sequencer/ MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  case "$sentinel" in
    */) mkdir -p "$sbgit/${sentinel%/}" ;;
    *)  printf 'ref\n' > "$sbgit/$sentinel" ;;
  esac
  eq "$(adb_clone_local_state "$sbrepo" main)" "in-progress" "local state: in-progress ($sentinel)"
  rm -rf "${sbgit:?}/${sentinel%/}"
done

git -C "$sbrepo" checkout -q --detach HEAD
eq "$(adb_clone_local_state "$sbrepo" main)" "detached" "local state: detached HEAD"
git -C "$sbrepo" checkout -q main
eq "$(adb_clone_local_state "$sbrepo" feature-x)" "not-default" "local state: on a non-default branch"
eq "$(adb_clone_local_state "$work" main)" "not-a-repo" "local state: not a git work tree"

# The git dir must be resolved ABSOLUTELY: `rev-parse --git-dir` prints a path relative to the
# work tree, which would resolve against the CALLER's cwd. Calling from elsewhere must give the
# same verdict as calling from inside — otherwise every sentinel test silently looks in the
# wrong directory and in-progress state reads as safe.
mkdir -p "$sbgit/rebase-merge"
eq "$( cd "$work" && adb_clone_local_state "$sbrepo" main )" "in-progress" \
  "local state: in-progress is detected from any cwd"
rm -rf "$sbgit/rebase-merge"

# --- adb_global_manifest (#36) ------------------------------------------------
# One spelling of the global manifest path, shared by its writer (install.sh) and every reader
# (role-dispatch.sh, the SessionStart hook). A reader that spelled it differently — notably one
# that honored XDG_CONFIG_HOME while the writer did not — would consult a file nobody writes, so
# its config key would silently do nothing.
# The two HOME values are STRING COMPOSITION INPUTS — `adb_global_manifest` concatenates and never
# touches the filesystem, so nothing is created, read or removed here. `/nonexistent/…` says that
# in the fixture itself: a path under a real, writable directory reads as though the assertion
# might depend on what is there, and a later edit that DID touch the filesystem would look
# plausible instead of obviously wrong. It also means this file needs no `adb-tmp-ok` exemption
# from the fixed-shared-temp lint (#250) — a side benefit, not the reason.
eq "$( HOME=/nonexistent/fakehome; adb_global_manifest )" "/nonexistent/fakehome/.config/ai-dev-baseline/agents.toml" \
  "global manifest: \$HOME/.config/ai-dev-baseline/agents.toml"
# shellcheck disable=SC2034  # XDG_CONFIG_HOME being unread by adb_global_manifest IS the assertion.
eq "$( HOME=/nonexistent/fakehome XDG_CONFIG_HOME=/nonexistent/decoy; adb_global_manifest )" \
  "/nonexistent/fakehome/.config/ai-dev-baseline/agents.toml" \
  "global manifest: XDG_CONFIG_HOME does not move it (the writer does not honor it either)"
# The single-source claim, asserted against the actual files rather than trusted: neither the
# writer nor the other reader may carry its own literal spelling any more. Uses the ok/bad
# counter family (not req_absent), because THIS file reports through check_summary — a
# grep-assert failure here would set CHECK_FAIL, which check_summary never reads, and so would
# never fail the run.
if grep -q '\.config/ai-dev-baseline' install.sh; then
  bad "install.sh re-spells the global manifest path instead of calling adb_global_manifest"
else ok; fi
if grep -q 'HOME:-/root}/\.config' scripts/lib/role-dispatch.sh; then
  bad "role-dispatch.sh re-spells the global manifest path instead of calling adb_global_manifest"
else ok; fi

# --- adb_mtime (#36) ----------------------------------------------------------
# The two stat flavors are not interchangeable, and the obvious `stat -f %m || stat -c %Y` is a
# real bug rather than a style nit: on GNU coreutils `-f` is --file-system, so `stat -f %m FILE`
# reads "%m" as a FILENAME and prints a multi-line filesystem report for FILE — to STDOUT —
# before failing. The `||` fallback then appends the real mtime, command substitution captures
# both, and the caller does arithmetic on a multi-line string. That silently disabled the
# SessionStart rate limit on Linux. Both flavors are exercised here through stubs, since a given
# CI box only has one.
mtf="$work/mtime-file"; printf 'x\n' > "$mtf"
mt="$(adb_mtime "$mtf")"
case "$mt" in ''|*[!0-9]*) bad "adb_mtime: expected digits for a real file, got [$mt]" ;; *) ok ;; esac
eq "$(adb_mtime "$work/definitely-not-here")" "" "adb_mtime: missing path → empty"
eq "${ printf '%s' "$(adb_mtime "$mtf")" | wc -l | tr -d ' '; }" "0" "adb_mtime: never multi-line"

statbin="$work/statbin"; mkdir -p "$statbin"
# A GNU-flavored stat: -c works; -f prints a multi-line report to STDOUT and fails.
cat > "$statbin/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -c) printf '1700000000\n' ;;
  -f) printf 'stat: cannot read file system information\n  File: "x"\n    ID: 1 Namelen: 255\n'; exit 1 ;;
esac
SH
chmod +x "$statbin/stat"
eq "$( PATH="$statbin:$PATH"; adb_mtime "$mtf" )" "1700000000" "adb_mtime: GNU-flavored stat yields only the mtime"
# A BSD-flavored stat: -c is rejected outright; -f is the one that works.
cat > "$statbin/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -c) printf 'stat: illegal option -- c\n' >&2; exit 1 ;;
  -f) printf '1700000001\n' ;;
esac
SH
chmod +x "$statbin/stat"
eq "$( PATH="$statbin:$PATH"; adb_mtime "$mtf" )" "1700000001" "adb_mtime: BSD-flavored stat yields the mtime"
# A stat that succeeds while printing nonsense must yield NOTHING, not the nonsense — the caller
# treats empty as "unknown age", which is the safe direction.
cat > "$statbin/stat" <<'SH'
#!/usr/bin/env bash
printf 'not-a-number\n'
SH
chmod +x "$statbin/stat"
eq "$( PATH="$statbin:$PATH"; adb_mtime "$mtf" )" "" "adb_mtime: non-numeric output is rejected, not returned"

# --- adb_install_source / adb_link_into (#36) --------------------------------
# Shared with the SessionStart hook, which must resolve the SAME clone by the SAME rule.
isrc="$work/isrc"; mkdir -p "$isrc/agents/claude"
printf '#!/usr/bin/env bash\n' > "$isrc/install.sh"
printf 'doc\n' > "$isrc/agents/claude/CLAUDE.md"
ihome="$work/ihome"; mkdir -p "$ihome/.claude"
eq "$(adb_install_source "$ihome" 2>/dev/null)" "" "install source: nothing linked → empty"
adb_install_source "$ihome" >/dev/null 2>&1; no "$?" "install source: returns non-zero when nothing is linked"
ln -s "$isrc/agents/claude/CLAUDE.md" "$ihome/.claude/CLAUDE.md"
eq "$(adb_install_source "$ihome")" "$isrc" "install source: resolved from the root-doc symlink"
# A DANGLING root doc still identifies the clone — repairing that link is the whole point.
rm -f "$ihome/.claude/CLAUDE.md"
ln -s "$isrc/agents/claude/CLAUDE-moved.md" "$ihome/.claude/CLAUDE.md"
eq "$(adb_install_source "$ihome")" "$isrc" "install source: a dangling root doc still resolves"
# A RELATIVE target is not one of ours (install.sh always records absolute), and must be ignored
# rather than resolved against whatever the caller's cwd happens to be.
rm -f "$ihome/.claude/CLAUDE.md"
ln -s "../relative/CLAUDE.md" "$ihome/.claude/CLAUDE.md"
adb_install_source "$ihome" >/dev/null 2>&1; no "$?" "install source: a relative target is not ours"

adb_link_into "$ihome/.claude/CLAUDE.md" "$isrc"; no "$?" "link_into: a relative link is not inside src"
rm -f "$ihome/.claude/CLAUDE.md"
ln -s "$isrc/agents/claude/CLAUDE.md" "$ihome/.claude/CLAUDE.md"
adb_link_into "$ihome/.claude/CLAUDE.md" "$isrc"; yes "$?" "link_into: a link into src is ours"
adb_link_into "$ihome/.claude/CLAUDE.md" "$work/elsewhere"; no "$?" "link_into: a link elsewhere is not ours"
printf 'real\n' > "$ihome/.claude/realfile"
adb_link_into "$ihome/.claude/realfile" "$isrc"; no "$?" "link_into: a real file is never ours"

# --- adb_claude_hook_scripts / adb_claude_hook_regex (#36) -------------------
# One enumeration feeds the manifest AND both settings filters. If they drift, a hook is either
# linked-but-never-wired or wired-but-never-removed on uninstall.
eq "$(adb_claude_hook_scripts | wc -l | tr -d ' ')" "5" "hook scripts: five wired hooks"
has "$(adb_claude_hook_scripts)" "session-currency.sh" "hook scripts: includes the currency hook"
has "$(adb_claude_hook_scripts)" "state-claim-gate.sh" "hook scripts: includes the state-claim gate"
has "$(adb_claude_hook_scripts)" "session-context.sh" "hook scripts: includes the run-state context hook (#431)"
# A RETIRED script must not still be named here: the manifest would demand a source that no longer
# exists, and the settings filters would go on matching a command nothing installs. Derived from
# the register (#378) rather than naming one, so it holds for the next retirement too.
while IFS= read -r rdest; do
  [ -n "$rdest" ] || continue
  hasnt "$(adb_claude_hook_scripts)" "${rdest##*/}" "hook scripts: excludes the retired ${rdest##*/}"
done <<EOF
$(adb_agent_manifest_retired claude /r /h | cut -f2)
EOF
eq "$(adb_claude_hook_regex /home/u)" \
  '^/home/u/\.claude/scripts/(precommit-gate|implement-issue-gate|session-currency|state-claim-gate|session-context)\.sh$' \
  "hook regex: anchored to the EXACT installed paths, not a basename"
# The ownership test must not claim a user's own script that merely shares a filename. A
# basename-anchored pattern would, and because the filters walk EVERY hook event, uninstall
# would then delete that entry from an unrelated event such as PreToolUse.
hre="$(adb_claude_hook_regex /home/u)"
printf '/custom/precommit-gate.sh\n' | grep -Eq "$hre" \
  && bad "hook regex must NOT match a user script with the same basename" || ok
printf '/home/u/.claude/scripts/precommit-gate.sh\n' | grep -Eq "$hre" \
  && ok || bad "hook regex must match our own installed path"
# A regex metacharacter in the home path must be escaped, or ownership widens to other paths.
hre2="$(adb_claude_hook_regex /home/a.b)"
printf '/home/axb/.claude/scripts/precommit-gate.sh\n' | grep -Eq "$hre2" \
  && bad "an unescaped '.' in \$HOME widens the ownership match" || ok
# The shipped hook set, read ONCE into an array (#259). Three cases below iterate it, and each
# used to re-run the function through a `$( )` inside a heredoc — a subshell AND a heredoc temp
# file per loop, for a list that cannot change between them. `mapfile` also retires the
# `[ -n "$hs" ] || continue` guard all three carried: that empty element was the heredoc's own
# trailing newline, never data, so the guard was working around the feeding mechanism.
mapfile -t HOOK_SCRIPTS < <(adb_claude_hook_scripts)
check_enumerated "adb_claude_hook_scripts" "${HOOK_SCRIPTS[@]}"

# ...and check_enumerated itself is watched answering WRONG, because a guard that cannot go red is
# worse than no guard (#259, review finding). The rule set is closed — empty, blank, clean — so the
# observation is a standing test rather than a note that someone once checked.
#
# Driven in a SUBSHELL: the helper reports through `bad`, so a direct call would land a real
# failure in THIS suite's counter. The subshell discards it and leaves only the exit status.
( check_enumerated probe a b )    >/dev/null 2>&1; eq "$?" 0 "check_enumerated: a clean list passes"
( check_enumerated probe )        >/dev/null 2>&1; eq "$?" 1 "check_enumerated: an EMPTY list is rejected"
( check_enumerated probe "" )     >/dev/null 2>&1; eq "$?" 1 \
  "check_enumerated: ONE BLANK entry is rejected — the case a bare \${#a[@]} -gt 0 test waves through"
( check_enumerated probe a "" b ) >/dev/null 2>&1; eq "$?" 1 "check_enumerated: a blank entry anywhere is rejected"

# Every wired hook must also be a manifest entry, or it is never linked into place.
manifest_dests="$(adb_agent_manifest claude /R /H | cut -f2)"
for hs in "${HOOK_SCRIPTS[@]}"; do
  has "$manifest_dests" "/H/.claude/scripts/$hs" "manifest links the wired hook $hs"
done

# --- adb_claude_hooks_state / adb_claude_hooks_missing (#242) ----------------
# The defect this replaces inferred intent about the WHOLE hook payload from ONE member, so the
# case that matters most is `partial` — removing one hook must NOT read as opting out of all.
hs_dir="$work/hookstate"; mkdir -p "$hs_dir"
hs_home="$hs_dir/home"
hs_all="$hs_dir/all.json"; hs_none="$hs_dir/none.json"; hs_part="$hs_dir/partial.json"
: > "$hs_all"; for hs in "${HOOK_SCRIPTS[@]}"; do printf '%s/.claude/scripts/%s\n' "$hs_home" "$hs" >> "$hs_all"; done
printf '{"hooks":{}}\n' > "$hs_none"
grep -v 'precommit-gate\.sh' "$hs_all" > "$hs_part"

eq "$(adb_claude_hooks_state "$hs_all"  "$hs_home")" "wired"   "hooks-state: all shipped hooks present → wired"
eq "$(adb_claude_hooks_state "$hs_none" "$hs_home")" "none"    "hooks-state: no shipped hooks present → none (the opt-out)"
eq "$(adb_claude_hooks_state "$hs_part" "$hs_home")" "partial" "hooks-state: one hook removed → partial, NOT none (#242)"
eq "$(adb_claude_hooks_state "$hs_dir/missing.json" "$hs_home")" "none" "hooks-state: absent settings.json → none"

# --- adb_claude_hooks_missing_deliberate (PR #443 review) ------------------------------------
# `partial` has two shapes and only one is an opt-out: a hook whose entry was REMOVED (its script
# link is still there) versus a hook that was SHIPPED after the last install (no link, no entry).
# Reading the second as the first left every newly shipped hook unwired for good.
mkdir -p "$hs_home/.claude/scripts"; hs_src="$hs_dir/src"; mkdir -p "$hs_src/agents/claude/scripts"
eq "$(adb_claude_hooks_missing_deliberate "$hs_part" "$hs_src" "$hs_home" | tr -d '\n')" "" \
  "hooks-deliberate: a missing hook with NO script link was never installed — not an opt-out"
ln -s "$hs_src/agents/claude/scripts/precommit-gate.sh" "$hs_home/.claude/scripts/precommit-gate.sh"
eq "$(adb_claude_hooks_missing_deliberate "$hs_part" "$hs_src" "$hs_home" | tr -d '\n')" "precommit-gate.sh" \
  "hooks-deliberate: a missing hook whose OUR link exists was removed by hand — an opt-out"
eq "$(adb_claude_hooks_missing_deliberate "$hs_all" "$hs_src" "$hs_home" | wc -l | tr -d ' ')" "0" \
  "hooks-deliberate: a fully wired set names nothing"
rm -f "$hs_home/.claude/scripts/precommit-gate.sh"
# OWNERSHIP, not existence: a foreign file or a symlink into somebody else's tree at the hook's
# pathname is a collision the repair backs up, not a choice about OUR hook (PR #443 review).
: > "$hs_home/.claude/scripts/precommit-gate.sh"
eq "$(adb_claude_hooks_missing_deliberate "$hs_part" "$hs_src" "$hs_home" | tr -d '\n')" "" \
  "hooks-deliberate: an unrelated REGULAR FILE at the hook path is not an opt-out"
rm -f "$hs_home/.claude/scripts/precommit-gate.sh"; ln -s /elsewhere/precommit-gate.sh "$hs_home/.claude/scripts/precommit-gate.sh"
eq "$(adb_claude_hooks_missing_deliberate "$hs_part" "$hs_src" "$hs_home" | tr -d '\n')" "" \
  "hooks-deliberate: a FOREIGN symlink at the hook path is not an opt-out"
rm -f "$hs_home/.claude/scripts/precommit-gate.sh"

# REGRESSION (PR #246 review): a basename search also matched a command the OPERATOR wrote. A
# deliberately --no-hooks install carrying its own /custom/precommit-gate.sh would read as
# `partial`, and the next self-heal would wire the whole baseline set they opted out of.
printf '{"hooks":{"Stop":[{"command":"/custom/precommit-gate.sh"}]}}\n' > "$hs_dir/foreign.json"
eq "$(adb_claude_hooks_state "$hs_dir/foreign.json" "$hs_home")" "none" \
  "hooks-state: a FOREIGN command sharing the basename is not ours → none, not partial"
eq "$(adb_claude_hooks_missing "$hs_dir/foreign.json" "$hs_home" | wc -l | tr -d ' ')" "5" \
  "hooks-missing: a foreign command satisfies nothing"

eq "$(adb_claude_hooks_missing "$hs_all"  "$hs_home" | wc -l | tr -d ' ')" "0" "hooks-missing: fully wired names nothing"
eq "$(adb_claude_hooks_missing "$hs_part" "$hs_home" | tr -d ' \n')" "precommit-gate.sh" "hooks-missing: names the removed hook"
eq "$(adb_claude_hooks_missing "$hs_none" "$hs_home" | wc -l | tr -d ' ')" "5" "hooks-missing: none → every shipped hook"

# Each shipped hook must independently produce `partial` when it alone is removed. Without this,
# the predicate could key on one filename again and still pass the cases above.
for hs in "${HOOK_SCRIPTS[@]}"; do
  grep -vF "/$hs" "$hs_all" > "$hs_dir/drop.json"
  eq "$(adb_claude_hooks_state "$hs_dir/drop.json" "$hs_home")" "partial" "hooks-state: dropping $hs alone → partial"
done

# --- adb_require_gh / adb_repo_slug (#87) ------------------------------------
# `adb_require_gh` is sourced by release-convention.sh AND repo-settings.sh, so a regression in it
# breaks two gh-backed modules at once. `adb_repo_slug` has exactly ONE production caller —
# release-convention.sh:79 — because repo-settings.sh deliberately reads its slug from the
# `.full_name` of the repo object it already fetches, to save a round trip (#218). Stating that
# accurately matters here: this comment used to claim both modules called both functions, which is
# the assumption that made #218 look like a one-place fix.
#
# The contract that matters for both: they RETURN non-zero (never `exit`, which would kill the
# caller's shell from inside a sourced function) and they say what is wrong.
ghbin="$work/ghbin"; mkdir -p "$ghbin"
mk_gh() {   # <auth-rc> <slug-output>
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$1" in\n'
    printf '  auth) exit %s ;;\n' "$1"
    printf '  repo) printf %%s "%s"; exit 0 ;;\n' "$2"
    printf 'esac\nexit 0\n'
  } > "$ghbin/gh"
  chmod +x "$ghbin/gh"
}

# gh present + authenticated -> success, and an extra tool that exists is fine.
mk_gh 0 "acme/widget"
( PATH="$ghbin:$PATH"; adb_require_gh >/dev/null 2>&1 ); yes "$?" "adb_require_gh succeeds with an authenticated gh"
( PATH="$ghbin:$PATH"; adb_require_gh sh >/dev/null 2>&1 ); yes "$?" "adb_require_gh accepts an extra tool that is present"

# A named extra tool that is absent must fail loud, and name the tool.
out="$( PATH="$ghbin:$PATH"; adb_require_gh definitely-not-a-real-tool 2>&1 )"; rc=$?
no "$rc" "adb_require_gh fails when a required extra tool is missing"
has "$out" "definitely-not-a-real-tool" "the missing extra tool is named"

# Unauthenticated gh -> non-zero, with the actionable hint. RETURN, not exit: the caller is a
# sourced context, so an `exit` here would take the whole shell down.
mk_gh 1 "acme/widget"
out="$( PATH="$ghbin:$PATH"; adb_require_gh 2>&1 )"; rc=$?
no "$rc" "adb_require_gh fails when gh is not authenticated"
has "$out" "gh auth login" "the auth failure names the fix"

# adb_repo_slug resolves and caches; an unresolvable remote is non-zero with empty output.
mk_gh 0 "acme/widget"
eq "$( PATH="$ghbin:$PATH"; adb_repo_slug 2>/dev/null )" "acme/widget" "adb_repo_slug returns owner/name"
mk_gh 0 ""
out="$( PATH="$ghbin:$PATH"; adb_repo_slug 2>/dev/null )"; rc=$?
no "$rc" "adb_repo_slug fails when there is no resolvable remote"
eq "$out" "" "adb_repo_slug prints nothing when it fails"

# --- adb_repo_slug refuses a slug that is not safe in a URL PATH (#218) -------------------------
# This getter is the PRODUCER BOUNDARY for release-convention.sh's ten `repos/$(repo_slug)/...`
# paths, and validating at each of those interpolations is the rule that eventually gets missed.
# `adb_is_repo_slug` would not be enough in this position: `acme/..` is a well-formed owner/repo
# pair AND a path traversal, which is exactly why the path-safe sibling exists.
#
# The value is API-supplied (`gh repo view --json nameWithOwner`), so reaching one of these needs a
# malformed or hostile response rather than user input — which is precisely why nothing else would
# ever catch it.
for bad in 'acme/..' '../widget' 'acme/.' './widget' 'acme/widget/extra' 'acme' 'acme/wid get' 'acme/wid?et' 'acme/wid%2fget'; do
  mk_gh 0 "$bad"
  out="$( PATH="$ghbin:$PATH"; adb_repo_slug 2>/dev/null )"; rc=$?
  err="$( PATH="$ghbin:$PATH"; adb_repo_slug 2>&1 >/dev/null )"
  no "$rc" "adb_repo_slug refuses the path-unsafe slug '$bad'"
  eq "$out" "" "...and prints nothing on stdout for '$bad'"
  has "$err" "malformed repository slug" "...saying why, for '$bad'"
done
# The diagnostic NAMES the value, or it tells the operator nothing they can act on.
mk_gh 0 'acme/..'
err="$( PATH="$ghbin:$PATH"; adb_repo_slug 2>&1 >/dev/null )"
has "$err" 'acme/..' "the diagnostic names the rejected slug"

# THE REJECTION LEAVES NO TRACE IN THE CACHE, and this is the assertion that would catch the
# obvious wrong fix. Resolution is skipped whenever `_ADB_REPO_SLUG` is non-empty, so a version
# that assigned the global and validated afterwards would fail the FIRST call and then return 0
# with the rejected slug on the SECOND — a fail-open one line below the guard, and invisible to
# every single-call test above.
mk_gh 0 'acme/..'
out="$( PATH="$ghbin:$PATH"; adb_repo_slug >/dev/null 2>&1; adb_repo_slug 2>/dev/null )"; rc=$?
no "$rc" "a rejected slug is NOT cached — the second call fails too"
eq "$out" "" "...and the second call still prints nothing"

# A HOSTILE VALUE MUST NOT FORGE A SECOND LOG LINE. The values this guard rejects are, by
# construction, the ones least likely to be well-behaved; echoing one raw into a diagnostic
# re-opens in the operator's output the hole the check just closed. `adb_display_value` renders it
# with `%q`, so a newline becomes `$'\n'` and the message stays on one line.
{ printf '#!/usr/bin/env bash\n'
  printf 'case "$1" in\n'
  printf '  auth) exit 0 ;;\n'
  printf '  repo) printf %%b "acme/wid\\nget: FORGED"; exit 0 ;;\n'
  printf 'esac\nexit 0\n'
} > "$ghbin/gh"
chmod +x "$ghbin/gh"
err="$( PATH="$ghbin:$PATH"; adb_repo_slug 2>&1 >/dev/null )"
eq "$(printf '%s\n' "$err" | grep -c .)" "1" "a newline in the rejected slug cannot forge a second log line"
has "$err" 'malformed repository slug' "...and the one line is still the real diagnostic"
hasnt "$err" "$(printf '\nget: FORGED')" "...with the forged continuation escaped, not printed"

# ...AND UNDER `xpg_echo`, which is the mode that defeats the obvious implementation. `%q` renders
# the newline as the two characters `\` and `n`; `echo` under this shopt DECODES that back into a
# real newline, so a diagnostic built with `echo` re-forges the line the renderer just escaped.
# Testing only the default mode leaves the guard green against exactly the shell setting that
# breaks it — the encoder is one line, and the command that PRINTS it is the other half.
# Run in a child bash so the shopt cannot leak into the rest of this suite.
err="$( PATH="$ghbin:$PATH" bash -c '
  shopt -s xpg_echo
  . scripts/lib/common.sh
  adb_repo_slug 2>&1 >/dev/null' )"
eq "$(printf '%s\n' "$err" | grep -c .)" "1" "...still ONE line with xpg_echo on, where echo would decode the escape"
has "$err" 'malformed repository slug' "...and it is still the real diagnostic under xpg_echo"

# ...but a repository whose NAME merely contains dots is a name, not a traversal, and must stay
# resolvable. Over-rejecting it would make every release-convention command permanently fail for a
# repo that was never dangerous — failure by availability rather than by safety, which is the kind
# that ships unnoticed. Same rule `adb_is_path_safe_repo_slug`'s own tests pin.
mk_gh 0 "acme/api..client"
eq "$( PATH="$ghbin:$PATH"; adb_repo_slug 2>/dev/null )" "acme/api..client" \
  "a repository named 'api..client' resolves — dots are a name, not a traversal"

# ==================== adb_run_bounded (#139: promoted from role-dispatch) =====================
# The mechanism was moved here so currency-lib.sh could share it instead of hand-rolling a second
# watchdog. It had been covered only TRANSITIVELY, through check-role-dispatch.sh's agent dispatch;
# a shared primitive with two callers needs its own tests. Both paths are exercised: the `timeout`
# binary when present, and the pure-shell watchdog fallback that a stock Mac takes.
#
# "bash-3.2 watchdog" was the wrong name for it and outlived the thing it named (#259). The
# fallback has nothing to do with the interpreter: `timeout`/`gtimeout` are GNU coreutils, which
# macOS does not ship at all, so a stock Mac takes this path on bash 5.3 exactly as it did on 3.2.
# The floor moved; this did not.

# A fast child's status passes straight through, on both paths.
adb_run_bounded 30 1 true; eq "$?" "0" "adb_run_bounded returns a successful child's status"
adb_run_bounded 30 1 sh -c 'exit 7'; eq "$?" "7" "adb_run_bounded passes a non-zero child status through"
ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 30 1 sh -c 'exit 7'
eq "$?" "7" "the watchdog path also passes the child status through"

# The bound fires as 124 (GNU timeout's convention) on BOTH paths. `secs` is small so the watchdog's
# tick shrinks to 1s and this stays fast.
adb_run_bounded 1 1 sleep 20; eq "$?" "124" "adb_run_bounded returns 124 when the bound fires"
ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 1 1 sleep 20
eq "$?" "124" "the watchdog fallback also returns 124 when the bound fires"

# A TERM-RESISTANT child must still be stopped — a bound that only sends SIGTERM is not a backstop.
# This is the escalation to KILL, which is the whole reason the grace exists.
esc="$work/esc.sh"
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 20\n' > "$esc"; chmod +x "$esc"
ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 1 1 "$esc"
eq "$?" "124" "watchdog: a TERM-resistant child still returns 124 (escalates to KILL)"

# stdin reaches the child. The `<&0` in both paths is load-bearing: a backgrounded command in a
# non-interactive shell otherwise gets /dev/null, so a child fed its input on stdin would read
# nothing — the bug that once silently handed codex an empty prompt.
eq "${ printf 'fed' | adb_run_bounded 30 1 cat; }" "fed" "adb_run_bounded delivers stdin to the child"
eq "${ printf 'fed' | ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 30 1 cat; }" "fed" \
   "the watchdog path also delivers stdin to the child"

# The grace is clamped for its callers, so a literal or an env value cannot disable escalation.
# 0 would mean "no SIGKILL at all" to GNU timeout while the watchdog treats it as "kill now" — one
# input making one path maximally aggressive and the other not a backstop. Asserted behaviorally:
# a TERM-resistant child must still die with a 0 grace.
ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 1 0 "$esc"
eq "$?" "124" "a 0 grace is clamped, so escalation still happens (watchdog)"
adb_run_bounded 1 x sleep 20; eq "$?" "124" "a non-numeric grace falls back to the default, bound still fires"

# A non-numeric BOUND is refused rather than silently treated as zero (which would fire instantly).
adb_run_bounded x 1 true; eq "$?" "2" "a non-numeric bound is refused with status 2"
# ZERO is refused for the same reason and is NOT merely non-numeric: `timeout 0` means "no timeout
# at all" to GNU timeout while the watchdog's countdown kills instantly — one input, opposite
# behavior. Zero-padded forms must be caught too; "00" matches no literal `0)` arm.
adb_run_bounded 0 1 true;  eq "$?" "2" "a zero bound is refused with status 2"
adb_run_bounded 00 1 true; eq "$?" "2" "a zero-PADDED bound is refused too (arithmetic, not a literal arm)"

# THE 137->124 NORMALIZATION, on the timeout-BINARY path. GNU timeout reports 124 when SIGTERM
# ended the child but relays 137 when -k had to escalate to SIGKILL, so one event reported two
# codes depending only on how stubborn the child was — and 137 is what callers classify as "killed
# from OUTSIDE this helper". Without normalization the same timeout classifies as our backstop on a
# stock Mac (watchdog) and as an external kill on Linux CI (timeout binary): a platform-dependent
# lie. This case is the ONLY direct guard on it; deleting the normalization otherwise leaves this
# whole suite green and fails only role-dispatch's, i.e. transitively.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  adb_run_bounded 1 1 "$esc"
  eq "$?" "124" "timeout-binary path: a TERM-resistant child normalizes 137 -> 124 (not an external kill)"
else
  check_note "no timeout/gtimeout binary — skipped the 137->124 normalization case"
fi

# The caller's own trap survives: this is a sourced library, so resetting handlers to default on
# exit would clobber a trap the calling script installed.
trapped="$(bash -c '. "$1"; trap "echo MINE" TERM; adb_run_bounded 5 1 true >/dev/null 2>&1; trap -p TERM' \
  _ "$PWD/scripts/lib/common.sh" 2>/dev/null)"
has "$trapped" "MINE" "adb_run_bounded restores the caller's own TERM trap"

# A GRANDCHILD dies with the bound, on BOTH paths (#141). This is the case the two paths used to
# DISAGREE on while agreeing on status: both returned 124, and only one had actually cleaned up, so
# no existing assertion could tell them apart. The suites above stop at the child — `sleep 31337`
# is the WATCHER's fork, and check-role-dispatch's outer-termination case probes the dispatched
# agent itself — so a single-PID kill passed every one of them.
#
# The victim IGNORES TERM deliberately. A child that dies on TERM takes its group down anyway, so a
# probe built on one would pass against a single-PID kill and assert nothing. Only a leader that
# survives TERM forces the escalation to reach the GROUP.
#
# THE GRANDCHILD IS IDENTIFIED BY THE PID IT RECORDS, not by scanning the process table for a name.
# A name scan was tried first and is doubly unsound here: an orphan left by a PREVIOUS aborted run
# still matches, so the guard fails on a tree that is actually fixed (observed — a stale
# `ppid 1` survivor turned a passing case red), and the marker also has to be kept out of the
# harness's own argv or the probe counts itself. Asking one recorded pid whether it is still alive
# has neither failure mode. A ZOMBIE counts as dead: `kill -0` succeeds on one, and a grandchild
# whose parent we just killed is reparented to init and reaped there.
gcp="$work/gcprobe.sh"
gcpid="$work/gcpid"
cat > "$gcp" <<EOF
#!/usr/bin/env bash
trap '' TERM
sleep 60 &
echo \$! > "$gcpid"
while :; do sleep 1; done
EOF
chmod +x "$gcp"

# "dead" and "no evidence" are DIFFERENT ANSWERS and must not collapse. A fixture that never
# recorded a pid — the probe failed to start, the write raced — would otherwise read as "dead" and
# pass the very assertion it failed to stage: a guard reporting success for a scenario that never
# ran, which is the silent-guard failure this repo keeps paying for. `no-pid` is a distinct string
# so it fails the `eq` loudly instead.
gc_alive() {   # prints "alive" | "dead" | "no-pid"
  local p state
  p="$(cat "$gcpid" 2>/dev/null)"
  case "$p" in ''|*[!0-9]*) printf 'no-pid'; return ;; esac
  kill -0 "$p" 2>/dev/null || { printf 'dead'; return; }
  state="$(ps -o state= -p "$p" 2>/dev/null | tr -d ' ')"
  case "$state" in Z*) printf 'dead' ;; *) printf 'alive' ;; esac
}
gc_reset() { local p; p="$(cat "$gcpid" 2>/dev/null)"
  case "$p" in ''|*[!0-9]*) : ;; *) kill -KILL "$p" 2>/dev/null || : ;; esac; rm -f "$gcpid"; }

gc_reset
ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 1 1 "$gcp" >/dev/null 2>&1
eq "$?" "124" "watchdog: a TERM-ignoring child still returns 124 (the grandchild case)"
sleep 1
# PROVE THE EVIDENCE EXISTS before asking about it. Without this the next assertion cannot tell
# "the bound reaped the grandchild" from "the probe never recorded one", and only one of those is
# a pass. `gc_alive` returns the distinct `no-pid` for the second, so this reads as a real failure.
if [ -s "$gcpid" ]; then ok; else bad "watchdog: the probe never recorded a grandchild pid — the case did not run"; fi
eq "$(gc_alive)" "dead" "watchdog: the bound reaps the child's GRANDCHILD, not just the child"
gc_reset

# The timeout binary already did this — that is what made the watchdog's behavior a DIVERGENCE
# rather than a shared limitation — so assert it holds rather than assuming it, and skip honestly
# where the binary is absent instead of reporting a case that never ran.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  adb_run_bounded 1 1 "$gcp" >/dev/null 2>&1
  eq "$?" "124" "timeout binary: a TERM-ignoring child still returns 124 (the grandchild case)"
  sleep 1
  if [ -s "$gcpid" ]; then ok; else bad "timeout binary: the probe never recorded a grandchild pid — the case did not run"; fi
  eq "$(gc_alive)" "dead" "timeout binary: the bound reaps the grandchild too — the paths AGREE"
  gc_reset

  # THE SWEEP IS CONDITIONAL ON THE BOUND HAVING FIRED, and that is a property, not an accident.
  # A command that finishes ON ITS OWN may have deliberately left something running — the review of
  # PR #303 raised exactly this shape (an agent that starts a dev server) — and killing it would
  # turn a wall-clock BOUND into a reaper of successful work. Without this case, making the sweep
  # unconditional passes every other assertion here.
  livepid="$work/livepid"; rm -f "$livepid"
  adb_run_bounded 30 1 "$BASH" -c "sleep 45 & echo \$! > \"$livepid\"; exit 0" >/dev/null 2>&1
  eq "$?" "0" "timeout binary: a command that finishes on its own still returns its own status"
  sleep 1
  survivor="$(cat "$livepid" 2>/dev/null)"
  case "$survivor" in
    ''|*[!0-9]*) bad "the clean-exit probe never recorded a background pid — the case did not run" ;;
    *) if kill -0 "$survivor" 2>/dev/null; then ok
       else bad "the sweep killed a SUCCESSFUL run's background work — it must only fire when the bound did"; fi
       kill -KILL "$survivor" 2>/dev/null || : ;;
  esac
  rm -f "$livepid"
else
  check_note "no timeout/gtimeout binary — skipped the binary path's grandchild case"
fi

# Job control is borrowed for ONE command and handed straight back. This library is SOURCED, so
# leaving `set -m` on would give a caller's shell a global setting it never asked for, and leaving
# it on for the duration would change how that caller's own background jobs behave for up to the
# whole bound. Both directions are asserted: a caller without job control must not acquire it, and
# a caller WITH it must not lose it.
monoff="$("$BASH" -c '. "$1"; ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 30 1 true >/dev/null 2>&1
                   case "$-" in *m*) echo on ;; *) echo off ;; esac' _ "$PWD/scripts/lib/common.sh" 2>/dev/null)"
eq "$monoff" "off" "adb_run_bounded leaves job control OFF for a caller that had it off"
monon="$("$BASH" -c '. "$1"; set -m; ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 30 1 true >/dev/null 2>&1
                  case "$-" in *m*) echo on ;; *) echo off ;; esac' _ "$PWD/scripts/lib/common.sh" 2>/dev/null)"
eq "$monon" "on" "adb_run_bounded preserves job control for a caller that had it ON"

# ...and under a caller that HAS job control, the bound must still report the child's real fate.
# With `set -m`, plain `wait` returns when a job merely CHANGES STATUS — a stopped child hands back
# 128+sig in 0s while it is still alive and running. Putting the child in its own process group is
# what makes that newly reachable without an operator ^Z (a background group reading the tty takes
# SIGTTIN), so the `wait -f` that answers it is part of THIS change and needs its own guard.
#
# "$BASH", NOT a bare `bash`. This suite re-execs itself into a >= 5.3 interpreter, but a nested
# bare `bash` resolves through PATH — and on a stock macOS PATH `/bin` precedes Homebrew, so the
# inner shell would be 3.2. The guard would then measure the wrong interpreter on the very platform
# it exists to protect. `$BASH` is the one actually running this file.
#
# SYNCHRONISED on the child publishing its pid, not on a fixed sleep, and the controller REPORTS
# whether it managed to stop anything. A timing-based version can miss the window on a loaded
# runner, deliver no STOP at all, and let the child exit 0 on its own — a green that proves
# nothing. `stopped=yes` in the output is the evidence that the scenario was actually staged.
stopped="$("$BASH" -c '. "$1"; set -m
  pf="$2"; rm -f "$pf" "$pf.ok"
  ( n=0
    while [ ! -s "$pf" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$(( n + 1 )); done
    p="$(cat "$pf" 2>/dev/null)"
    case "$p" in ""|*[!0-9]*) exit 0 ;; esac
    kill -STOP "$p" 2>/dev/null || exit 0
    # Confirm the kernel really parked it before letting it go again.
    n=0
    while [ "$n" -lt 40 ]; do
      case "$(ps -o state= -p "$p" 2>/dev/null | tr -d " ")" in T*) echo yes > "$pf.ok"; break ;; esac
      sleep 0.05; n=$(( n + 1 ))
    done
    kill -CONT "$p" 2>/dev/null ) &
  ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 15 1 "$BASH" -c "echo \$\$ > \"$pf\"; sleep 3"
  printf "rc=%s stopped=%s" "$?" "$(cat "$pf.ok" 2>/dev/null || echo no)"' \
  _ "$PWD/scripts/lib/common.sh" "$work/stoppid" 2>/dev/null)"
eq "$stopped" "rc=0 stopped=yes" \
   "a STOPPED child is not mistaken for a finished one under a caller's job control"

# --- adb_actions_app_slug: the ONE home for check-run provenance (#179) ----------------------
# Two libraries decide "did GitHub Actions report here?" — roadmap-lib.sh (whose answer gates a
# release cut) and repo-settings.sh (whose answer gates the required-check lint). They shipped
# with independent copies of the discriminator, both wrong the same way: `github`, which is the
# app OWNER login, where GitHub stamps the slug `github-actions`. Neither could ever match, so
# `branch-health` never returned green on an Actions repo and `required-drift` silently found no
# Actions contexts to contradict. This is the value both now read instead of restating.
eq "$(adb_actions_app_slug)" "github-actions" "adb_actions_app_slug is the real GitHub Actions slug"
# NON-EMPTY is a correctness property, not a smoke test: both consumers compare against
# `(.app.slug // "")`, so an empty expected value matches exactly the check runs whose app could
# NOT be identified — counting unknown provenance as Actions, fail-open, in the predicate that
# gates a release cut. Callers guard on this; so does the value itself.
# Spelled with ok/bad rather than `no "$([ … ]; echo $?)"`: a `$?` taken straight from a `[ … ]`
# condition is what shellcheck's SC2319 warns about, and the direct form says the same thing without
# routing a status through a subshell.
if [ -n "$(adb_actions_app_slug)" ]; then ok; else bad "adb_actions_app_slug is never empty"; fi

# Cross-file pinning of this value ("both consumers call the accessor, neither keeps a copy") is
# NOT here: `scripts/check-fact-drift.sh` is the declared home for a fact restated across files,
# and it already pins branch-health and required-drift. See the `actions-slug-*` facts there.

# ============ the pool-sizing primitive (#335: promoted from selfcheck.sh) ============
#
# THIS PRIMITIVE'S FAILURE MODE IS A SMALLER NUMBER, which is the quietest one available: a pool of
# one is not wrong, it is slow, and nothing in a green run distinguishes it from a pool of eight.
# The three callers each fork whole check suites, so an unnoticed 1 costs minutes per run and
# reports exactly what a healthy run reports. Every case below is a way that could happen.
#
# The probe chain is driven through a STUBBED PATH rather than read off this machine: an assertion
# that compares `adb_cpu_count` against the host's core count asserts nothing (both sides come from
# the same call), and would answer differently on the two runners this repo builds on.
_cpu_stub() {   # _cpu_stub <getconf-output> -> a PATH dir whose cpu probes answer exactly that
  local sb="$work/cpuprobe"; rm -rf "$sb"; mkdir -p "$sb"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "$sb/getconf"
  # sysctl and nproc stubbed to FAIL, so the fallback chain cannot rescue a bad first answer and
  # make a case pass for a reason it was not written to test.
  printf '#!/bin/sh\nexit 1\n' > "$sb/sysctl"; printf '#!/bin/sh\nexit 1\n' > "$sb/nproc"
  chmod +x "$sb/getconf" "$sb/sysctl" "$sb/nproc"
  printf '%s' "$sb"
}
cpu_probe()  { local sb; sb="$(_cpu_stub "$1")"; PATH="$sb:$PATH" adb_cpu_count; }
# pool_probe <getconf-output> [cap] — adb_pool_size against a KNOWN cpu count, so the fallback
# cases below can assert a literal. Comparing them against `adb_cpu_count` instead would be
# tautological (both sides would be the same call) and would answer differently on the two runners
# this repo builds on.
pool_probe() {
  local sb; sb="$(_cpu_stub "$1")"
  if [ "$#" -ge 2 ]; then PATH="$sb:$PATH" adb_pool_size "$2"; else PATH="$sb:$PATH" adb_pool_size; fi
}
eq "$(cpu_probe 4)"       "4"  "adb_cpu_count: a plain count is used as-is"
eq "$(cpu_probe '  6  ')" "6"  "adb_cpu_count: surrounding whitespace is trimmed, not read as garbage"
eq "$(cpu_probe banana)"  "1"  "adb_cpu_count: unusable output falls back to 1, never to empty"
eq "$(cpu_probe '')"      "1"  "adb_cpu_count: an empty answer falls back to 1"
eq "$(cpu_probe 0)"       "1"  "adb_cpu_count: a zero is not a usable width"
# ZERO-PADDED, and this is the case that motivated `_adb_pos_int` rather than a bare digit test.
# `[ 010 -le 8 ]` is FALSE (test reads base 10: 10 > 8) while `$(( 010 ))` is 8 (arithmetic reads
# OCTAL) — so an un-normalized value means two different numbers depending on which one a caller
# reaches for, and a `pool=010` printed into a log is a third answer again.
eq "$(cpu_probe 012)"     "12" "adb_cpu_count: a zero-padded count is decimal 12, not octal 10"

eq "$(ADB_POOL_JOBS='' pool_probe 6)"    "6"  "adb_pool_size with no budget follows the cpu probe"
eq "$(ADB_POOL_JOBS='' pool_probe 32)"   "8"  "adb_pool_size: the default cap is 8"
eq "$(ADB_POOL_JOBS='' pool_probe 6 2)"  "2"  "adb_pool_size: an explicit cap is honoured"
eq "$(ADB_POOL_JOBS=3 pool_probe 6)"     "3"  "adb_pool_size: a budget REPLACES the probe"
eq "$(ADB_POOL_JOBS=3 pool_probe 6 2)"   "2"  "adb_pool_size: the cap still applies over a budget"
eq "$(ADB_POOL_JOBS=32 pool_probe 6)"    "8"  "adb_pool_size: a budget cannot exceed the cap"
eq "$(ADB_POOL_JOBS=007 pool_probe 6)"   "7"  "adb_pool_size: a zero-padded budget is decimal, not octal"
# A MALFORMED budget falls back to the PROBE, not to 1. Falling back to 1 would turn a typo in an
# environment variable into the silent serialization this whole primitive exists to prevent, and it
# would do it on the machine where the typo is hardest to see. `6`, not the host's core count, is
# what makes this discriminate: a fallback to 1 and a fallback to the probe are different numbers.
eq "$(ADB_POOL_JOBS=banana pool_probe 6)" "6" \
  "adb_pool_size: a malformed budget falls back to the probe, NOT to 1"
eq "$(ADB_POOL_JOBS=0 pool_probe 6)"      "6" \
  "adb_pool_size: a zero budget is malformed (a pool of zero never dispatches)"
eq "$(ADB_POOL_JOBS=-2 pool_probe 6)"     "6" \
  "adb_pool_size: a negative budget is malformed"
eq "$(ADB_POOL_JOBS=3 pool_probe 6 banana)" "3" \
  "adb_pool_size: a malformed cap falls back to 8 rather than refusing"
# PAST INTMAX, and the assertion is about STDERR, not the answer. `[ 99999999999999999999 -le 8 ]`
# does not return false — it fails with `integer expected` on stderr, so the caller's `||` picks
# the right number and the run is littered with a diagnostic that reads like a broken check. The
# value is captured to a FILE because `$(…)` cannot see whether stderr was written.
_pool_err="$work/pool.err"
eq "$(ADB_POOL_JOBS=99999999999999999999 pool_probe 6 2>"$_pool_err")" "6" \
  "adb_pool_size: a value past the shell's arithmetic range is malformed, not a comparison error"
if [ -s "$_pool_err" ]; then bad "adb_pool_size stays SILENT on an over-large budget: $(cat "$_pool_err")"; else ok; fi
# The floor: whatever happens, the answer is usable as a loop bound.
if [ "$(ADB_POOL_JOBS=banana pool_probe banana)" -ge 1 ] 2>/dev/null; then ok
else bad "adb_pool_size never returns a value below 1"; fi

# ============ the PR-argument and repository-identity primitives (#173) ============
# Promoted out of pr-review.sh and pr-watch.sh, which each carried private copies that had already
# DIVERGED into a live fail-open. They are covered here, at their one home, rather than only through
# the two guards' harnesses: a shared primitive with two callers needs its own tests, and the
# divergence is precisely what per-caller coverage cannot see.

# --- adb_is_repo_slug: the owner/repo shape test -----------------------------------------------
for good in "acme/widget" "a/b" "acme.foo/widget-1"; do
  if adb_is_repo_slug "$good"; then ok; else bad "adb_is_repo_slug accepts '$good'"; fi
done
# Each rejection is a real input that reached one of the three callers: a bare host, a deeper URL
# path, the leading-slash form `https://github.com/pull/7` parses to, and an empty half.
for v in "" "acme" "acme/widget/extra" "/widget" "acme/" "/" "a//b"; do
  if adb_is_repo_slug "$v"; then bad "adb_is_repo_slug rejects '$v'"; else ok; fi
done

# --- adb_is_path_safe_repo_slug: the same shape, PLUS safe to build a request path from ---------
# The shape test alone is not enough once a slug is CONCATENATED INTO a `repos/<slug>/...` path, and
# the gap is easy to miss because the shape test looks like it covers it: `a/..` is a well-formed
# pair AND a path traversal. #175's `pr-watch.sh head_anchor` is the first caller — it builds that
# path out of `head.repo.full_name`, a value read from an API response rather than constructed
# locally, which is the position where "well-formed" and "safe" stop being the same question.
for good in "acme/widget" "a/b" "acme.foo/widget-1" "My_Org/repo.js"; do
  if adb_is_path_safe_repo_slug "$good"; then ok; else bad "adb_is_path_safe_repo_slug accepts '$good'"; fi
done
# DOTS ARE ORDINARY IN REPOSITORY NAMES, and over-rejecting them costs availability rather than
# safety — which is exactly why it ships unnoticed. A substring test for `..` also rejects
# `api..client`, and the caller's failure mode is then code 20 on every date-scoped signal for that
# PR: permanently unreadable, for a name that was never dangerous. `.github` is GitHub's own
# convention and must pass; a LEADING dot is not traversal either.
for good in "acme/api..client" "acme/.github" "acme/..github" "a.b.c/d..e"; do
  if adb_is_path_safe_repo_slug "$good"; then ok; else bad "adb_is_path_safe_repo_slug accepts dotted name '$good'"; fi
done
# It must still reject everything the shape test rejects...
for v in "" "acme" "acme/widget/extra" "/widget" "acme/"; do
  if adb_is_path_safe_repo_slug "$v"; then bad "adb_is_path_safe_repo_slug rejects '$v'"; else ok; fi
done
# ...and the traversal / injection forms the shape test alone lets through. `acme/..` is the one
# that matters: adb_is_repo_slug ACCEPTS it, so this line is the whole reason the sibling exists.
# A segment that IS `.` or `..` is traversal — on EITHER side of the slash — while a segment that
# merely contains dots is a name (pinned above).
for v in "acme/.." "../widget" "acme/." "./widget" "../.." "acme/../../x" \
         "acme/wid get" "acme/wid?et" "acme/wid&et" "acme/w%2Fx"; do
  if adb_is_path_safe_repo_slug "$v"; then bad "adb_is_path_safe_repo_slug rejects '$v'"; else ok; fi
done
# Pin the DIFFERENCE itself, not just the two behaviours: if a future edit folded the strict rule
# into adb_is_repo_slug, these two would agree and the sibling would be pointless indirection.
if adb_is_repo_slug "acme/.."; then ok; else bad "adb_is_repo_slug is the SHAPE test and still accepts 'acme/..'"; fi

# --- adb_url_path_segment: the other half of "safe to build a request path from" (#103) --------
# A slug is CHECKED because a malformed one means the response was wrong. A git ref is ENCODED
# because a slash in it is perfectly legal git and the caller must still reach the right endpoint.
# These tests pin that difference, and each group below is a way the encoder can be wrong that no
# other test in this repo would notice.

# 1. THE NO-OP PROPERTY, and it is the most important one here. Every existing caller passes a
# default branch, so if the encoder perturbed an ordinary name this change would break the path
# that works today in order to fix one that (per D53's measurement) already worked. Byte-identical
# for the whole RFC 3986 unreserved set.
for v in "main" "develop" "trunk" "a.b-c_d~e" "Release-2.1" "v1..v2"; do
  eq "$(adb_url_path_segment "$v")" "$v" "adb_url_path_segment leaves '$v' byte-identical"
done

# 2. The slash — the case the issue is named for, at one, two and four levels deep.
eq "$(adb_url_path_segment 'release/v1')" 'release%2Fv1' "adb_url_path_segment: release/v1 -> release%2Fv1"
eq "$(adb_url_path_segment 'automation/bors/auto')" 'automation%2Fbors%2Fauto' "...two slashes"
eq "$(adb_url_path_segment 'dependabot/composer/stacks/php/all-minor')" \
   'dependabot%2Fcomposer%2Fstacks%2Fphp%2Fall-minor' "...four slashes"

# 3. NOT IDEMPOTENT, ON PURPOSE. `release%2Fv1` is itself a legal git branch name, so a
# "don't double-encode" guard would silently address `release/v1` when the operator named a
# different branch. Encoding is one-way; callers pass the raw ref exactly once.
eq "$(adb_url_path_segment 'release%2Fv1')" 'release%252Fv1' \
   "adb_url_path_segment re-encodes a literal '%2F' — a pre-encoded name is a DIFFERENT branch"

# 4. `#` IS WHY ENCODING IS NOT OPTIONAL, and it is not the slash. Git forbids space, `~^:?*[` and
# `\` in a ref but ALLOWS `#`, `%`, `+`, `=`, `;`, `&`. Interpolated raw, `#` opens a URI fragment
# and everything after it is dropped from the request — a wrong answer with a 200 status.
eq "$(adb_url_path_segment 'feat/#42')"  'feat%2F%2342' "adb_url_path_segment encodes '#' (a raw one truncates the path at a fragment)"
eq "$(adb_url_path_segment 'a%b')"       'a%25b'        "...and a literal '%', which would otherwise start a bogus escape"
eq "$(adb_url_path_segment 'a+b=c&d;e')" 'a%2Bb%3Dc%26d%3Be' "...and the sub-delimiters git permits"
eq "$(adb_url_path_segment 'a b')"       'a%20b'        "...and a space"

# 5. UTF-8 IS ENCODED PER BYTE, AND THE ANSWER MUST NOT DEPEND ON THE AMBIENT LOCALE. This is the
# reason the implementation is `jq @uri` rather than a shell character loop: bash's
# `printf '%02X' "'é"` yields the CODEPOINT (E9 — an invalid UTF-8 escape) in a UTF-8 locale and
# the first BYTE (C3) under LC_ALL=C, so a hand-rolled loop is correct on one runner and wrong on
# another with nothing to tell them apart. Asserting BOTH locales is what makes that regression
# visible instead of environment-dependent.
eq "$(adb_url_path_segment 'ré/v1')" 'r%C3%A9%2Fv1' "adb_url_path_segment encodes UTF-8 per byte"
eq "$(LC_ALL=C adb_url_path_segment 'ré/v1')" 'r%C3%A9%2Fv1' "...identically under LC_ALL=C"
# The UTF-8 half is asserted against a locale DETECTED at runtime, not a hardcoded `en_US.UTF-8`:
# the hosted Linux runner does not necessarily generate it, and a locale the system silently
# ignores makes this assertion pass while comparing C against C — green, and proving nothing. When
# no UTF-8 locale exists the pair cannot differ, so the check SAYS it did not run rather than
# counting a pass it did not earn.
utf8_loc="$(locale -a 2>/dev/null | grep -iE '\.(utf-?8)$' | head -n1)"
if [ -n "$utf8_loc" ]; then
  eq "$(LC_ALL="$utf8_loc" adb_url_path_segment 'ré/v1')" 'r%C3%A9%2Fv1' "...and under a real UTF-8 locale ($utf8_loc)"
else
  printf 'common-lib: NOTE — no UTF-8 locale on this host; the locale-independence pair was not exercised\n' >&2
fi

# 6. AN EXACT DOT SEGMENT IS TRAVERSAL ARRIVING THROUGH THE OTHER DOOR. `@uri` leaves dots alone,
# so `--branch ..` would build `repos/o/r/branches/../protection` and resolve one level up — the
# same hazard `adb_is_path_safe_repo_slug` refuses for slugs. RFC 3986 removes dot segments BEFORE
# percent-decoding, so `%2E%2E` is an ordinary (nonexistent) name. Only the WHOLE segment counts:
# `v1..v2` is pinned unchanged in group 1 above, because over-rejecting a name costs availability.
eq "$(adb_url_path_segment '.')"  '%2E'    "adb_url_path_segment neutralizes an exact '.' segment"
eq "$(adb_url_path_segment '..')" '%2E%2E' "...and an exact '..' segment (traversal, not a name)"

# 7. FAILS CLOSED, PRINTING NOTHING — the property the callers rely on. An empty return spliced
# into `branches/<here>/protection` does not yield a broken URL, it yields a DIFFERENT VALID ONE,
# so "returns non-zero" and "prints nothing" are both load-bearing and both asserted.
out="$(adb_url_path_segment "")"; rc=$?
eq "$rc" "1" "adb_url_path_segment refuses an empty ref"
eq "$out" ""  "...printing nothing (an empty segment would silently address another endpoint)"
out="$(adb_url_path_segment)"; rc=$?
eq "$rc" "1" "adb_url_path_segment refuses a missing argument"
eq "$out" ""  "...printing nothing"

# 8. A MISSING jq IS A FAILURE, NOT AN EMPTY STRING. jq is a hard requirement of every caller that
# builds one of these paths, but this function must not be the place that discovers that by
# returning a path with a hole in it. Driven by emptying PATH inside the command substitution's own
# subshell, so nothing leaks: the function needs only `command -v`, `jq` and the `printf` builtin.
nojq="$work/nojq"; mkdir -p "$nojq"
out="$(PATH="$nojq"; adb_url_path_segment 'release/v1')"; rc=$?
eq "$rc" "1" "adb_url_path_segment fails loud when jq is absent"
eq "$out" ""  "...printing nothing, rather than a path missing its ref"
# ...but the dot-segment arm answers WITHOUT jq, and that is deliberate rather than accidental: it
# is a pure literal, and a traversal must not become buildable just because a tool went missing.
eq "$(PATH="$nojq"; adb_url_path_segment '..')" '%2E%2E' "...while the dot-segment arm still answers (no jq needed)"

# 9. A REF THAT IS NOT VALID UTF-8 IS REFUSED, NOT SILENTLY REWRITTEN. A git ref is a byte string —
# `git check-ref-format` bars ASCII control characters but not high bytes — while jq's `--arg` is a
# JSON string, so `rel\xffv1` arrives as U+FFFD and encodes to `rel%EF%BF%BDv1`: a different,
# unreachable branch, returned with a ZERO status. Verified to be exactly what bare `@uri` does, so
# this pins the fidelity round trip rather than a hypothetical.
bad_ref="$(printf 'rel\xffv1')"
out="$(adb_url_path_segment "$bad_ref")"; rc=$?
eq "$rc" "1" "adb_url_path_segment refuses a ref that is not valid UTF-8"
eq "$out" ""  "...printing nothing, rather than the U+FFFD substitution jq would otherwise hand back"
# The round trip must not over-reject: every legitimate value above still encodes, and a high byte
# that IS valid UTF-8 is a name, not a corruption (the 'ré' pair in group 5 pins that direction).
#
# 10. AND IT MUST NOT OVER-REJECT A TRAILING NEWLINE. Command substitution strips EVERY trailing
# newline, so a round trip read back through `$( )` sees `a` where `a\n` went in, mismatches, and
# refuses a value this function encodes perfectly well. No git ref may contain a newline — so no
# caller in this repo is affected — but this is published as a GENERIC path-segment encoder, and an
# unstated hole in a generic contract is what the sentinel removes. `$'…'` here, not `$(printf …)`,
# because the substitution would strip the very byte under test before the function ever saw it.
# (Independent-review find.)
eq "$(adb_url_path_segment $'a\nb')"  'a%0Ab'   "adb_url_path_segment encodes an interior newline"
eq "$(adb_url_path_segment $'a\n')"   'a%0A'    "...and a TRAILING newline, which the round trip must not eat"
eq "$(adb_url_path_segment $'\n')"    '%0A'     "...and a value that is only a newline"
eq "$(adb_url_path_segment $'a\n\n')" 'a%0A%0A' "...and more than one of them"
# The sentinel that makes those work must not corrupt a value legitimately ending in its own
# character: `%` strips ONE trailing occurrence, so a real trailing `.` survives.
eq "$(adb_url_path_segment 'v1.')" 'v1.' "a ref ending in '.' still round-trips (the sentinel strips one, not all)"

# --- adb_pr_slug: three URL forms, case-folded, shape-checked ----------------------------------
# THE SCHEME IS OPTIONAL, and that is the whole defect #173 closed: pr-review.sh matched only
# `scheme://…`, so a scheme-less browser copy-paste produced an empty slug, skipped the cross-repo
# refusal, and let the arming guard authorize a merge on a PR nobody named.
eq "$(adb_pr_slug 'https://github.com/acme/widget/pull/7')" "acme/widget" "adb_pr_slug: scheme://host/owner/repo/pull/N"
eq "$(adb_pr_slug 'github.com/acme/widget/pull/7')"         "acme/widget" "adb_pr_slug: host/owner/repo/pull/N (no scheme)"
eq "$(adb_pr_slug 'acme/widget/pull/7')"                    "acme/widget" "adb_pr_slug: bare owner/repo/pull/N"
eq "$(adb_pr_slug 'https://github.com/acme/widget/pull/7/files')" "acme/widget" "adb_pr_slug: a sub-page URL"
# Case-folded HERE, not in each caller: a caller that forgets the `tr` compares a mixed-case argument
# against a lower-cased observed slug and sees a mismatch that is not one.
eq "$(adb_pr_slug 'https://github.com/Acme/Widget/pull/7')" "acme/widget" "adb_pr_slug case-folds in one home"
# A bare number carries no slug and needs no check — empty is the correct answer, not a failure.
eq "$(adb_pr_slug '7')" "" "adb_pr_slug: a bare number yields no slug"
eq "$(adb_pr_slug 'https://github.com/acme/widget/issues/7')" "" "adb_pr_slug: a non-PR URL yields no slug"
# Shell globs do not treat `/` as special, so the patterns constrain the NUMBER of slashes, not the
# segments: `https://github.com/pull/7` parses to `/github.com` before the shape check rejects it.
# Trusting that would make the argument look like it named a repository.
eq "$(adb_pr_slug 'https://github.com/pull/7')" "" "adb_pr_slug: a URL with no owner/repo yields nothing"
eq "$(adb_pr_slug 'pull/7')" "" "adb_pr_slug: a bare 'pull/N' yields nothing"
eq "$(adb_pr_slug 'https://ghe.example.com/a/b/c/pull/7')" "" "adb_pr_slug: a deeper path is not an owner/repo pair"

# --- adb_pr_number -----------------------------------------------------------------------------
eq "$(adb_pr_number '7')" "7" "adb_pr_number: a bare integer"
eq "$(adb_pr_number 'https://github.com/acme/widget/pull/7')" "7" "adb_pr_number: from a full URL"
eq "$(adb_pr_number 'github.com/other/repo/pull/7')" "7" "adb_pr_number: from a scheme-less URL"
eq "$(adb_pr_number 'https://github.com/acme/widget/pull/7/files')" "7" "adb_pr_number: from a sub-page URL"
eq "$(adb_pr_number '12345')" "12345" "adb_pr_number: a multi-digit number"
# THE TWO HALVES OF ONE PARSE MUST AGREE ON WHICH `/pull/` IS AUTHORITATIVE. `adb_pr_slug` takes the
# slug before the FIRST one, so the number must come from the first one too. Taking the last instead
# yielded slug `acme/widget` + number `9` here — the guard would gate a DIFFERENT pull request in the
# repository the URL correctly names, which the cross-repo refusal cannot catch because the repository
# is right. Not reachable from a real github.com URL; it is the internal inconsistency that matters.
eq "$(adb_pr_slug   'https://github.com/acme/widget/pull/7?w=1&x=/pull/9')" "acme/widget" \
   "adb_pr_slug: a second 'pull/' in a query does not move the slug"
eq "$(adb_pr_number 'https://github.com/acme/widget/pull/7?w=1&x=/pull/9')" "7" \
   "adb_pr_number: takes the FIRST 'pull/' segment, agreeing with adb_pr_slug"
eq "$(adb_pr_number 'https://github.com/a/b/pull/7/pull/8')" "7" \
   "adb_pr_number: a repeated 'pull/' path does not move the number either"
# THE MATCH IS ANCHORED ON THE LEADING SLASH, and both spellings that lack that anchor were shipped
# and wrong. An owner or repo whose name ENDS IN `pull` contains `pull/` without containing `/pull/`,
# so an unanchored match consumed the name instead of the route: `acme/git-pull/pull/8` left `pull/8`,
# reduced to an empty number, and REJECTED a perfectly valid URL — which meant the guards refused the
# workflow's own `prUrl` and auto-merge could never be armed on such a repository. Real names hit this
# (`git-pull`, `docker-pull`). Reported by the reviewer on PR #210.
eq "$(adb_pr_slug   'https://github.com/acme/git-pull/pull/8')" "acme/git-pull" \
   "adb_pr_slug: a repo NAME ending in 'pull' is not mistaken for the route segment"
eq "$(adb_pr_number 'https://github.com/acme/git-pull/pull/8')" "8" \
   "adb_pr_number: a repo NAME ending in 'pull' still yields the route's number"
eq "$(adb_pr_number 'https://github.com/git-pull/git-pull/pull/12')" "12" \
   "adb_pr_number: BOTH owner and repo ending in 'pull' still resolves"
# A NON-INTEGER ARGUMENT MUST NAME A REPOSITORY. Taking the digits after `pull/` and nothing else
# accepts these, which carry no owner/repo — so they reduce to a bare `7` and get answered about
# whichever repository the caller's reads happen to address.
for v in "" "0" "-3" "abc" "pull/7" "https://github.com/pull/7" \
         "https://github.com/acme/widget/issues/7" "7abc" "--pr"; do
  out="$(adb_pr_number "$v" 2>/dev/null)"; rc=$?
  no "$rc" "adb_pr_number rejects '$v'"
  eq "$out" "" "adb_pr_number prints nothing for '$v'"
done

# --- adb_git_origin_slug: the anchor no gh variable can move ------------------------------------
# `gh api repos/{owner}/{repo}/…` expands through gh, and the documented GH_REPO override moves that
# expansion — verified live: `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers `cli/cli` from a
# directory that is not a repository. An identity call made THROUGH gh honors the same override and
# would agree with itself, so git is the only honest anchor. Promoted here from state-assert.sh, which
# had the only copy.
oslug="$work/oslug"; mkdir -p "$oslug"; git init -q "$oslug"
mk_origin() { git -C "$oslug" remote remove origin 2>/dev/null; git -C "$oslug" remote add origin "$1"; }
# The three URL shapes git emits, each with and without `.git`.
for u in "https://github.com/acme/widget.git" "https://github.com/acme/widget" \
         "git@github.com:acme/widget.git"     "git@github.com:acme/widget" \
         "ssh://git@github.com/acme/widget.git"; do
  mk_origin "$u"
  eq "$(cd "$oslug" && adb_git_origin_slug)" "acme/widget" "adb_git_origin_slug parses '$u'"
done
# GH_REPO must not influence it — that is the entire reason it asks git.
mk_origin "https://github.com/acme/widget.git"
eq "$(cd "$oslug" && GH_REPO=other/project adb_git_origin_slug)" "acme/widget" \
   "adb_git_origin_slug ignores GH_REPO (the override it exists to defeat)"
# A trailing slash is tolerated; anything that does not resolve to a PAIR fails closed.
mk_origin "https://github.com/acme/widget/"
eq "$(cd "$oslug" && adb_git_origin_slug)" "acme/widget" "adb_git_origin_slug tolerates a trailing slash"
# ...and the COMBINED form, which is where the strip order was wrong: with `.git` stripped first, a
# trailing slash is still last so the suffix survives, leaving `acme/widget.git` — a slug matching no
# real repository, which made the anchor disagree with the API and refused both guards. Every
# combination must reduce to the same pair. Reported by the reviewer on PR #210.
for u in "https://github.com/acme/widget.git/" "git@github.com:acme/widget.git/" \
         "ssh://git@github.com/acme/widget.git/" "https://github.com/acme/widget.git" \
         "https://github.com/acme/widget/" "https://github.com/acme/widget"; do
  mk_origin "$u"
  eq "$(cd "$oslug" && adb_git_origin_slug)" "acme/widget" \
     "adb_git_origin_slug normalizes '$u' to the same pair"
done
for u in "https://github.com/widget" "https://github.com/a/b/c" "not-a-url"; do
  mk_origin "$u"
  out="$(cd "$oslug" && adb_git_origin_slug 2>/dev/null)"; rc=$?
  no "$rc" "adb_git_origin_slug fails closed on '$u'"
  eq "$out" "" "adb_git_origin_slug prints nothing for '$u'"
done
# No remote at all -> non-zero and silent, which every caller maps to its own "unreadable".
git -C "$oslug" remote remove origin 2>/dev/null
out="$(cd "$oslug" && adb_git_origin_slug 2>/dev/null)"; rc=$?
no "$rc" "adb_git_origin_slug fails closed with no remotes"
eq "$out" "" "adb_git_origin_slug prints nothing with no remotes"
# A single remote under ANOTHER name still identifies the checkout — `origin` is a convention, not a
# requirement, and a clone that only has `upstream` is an ordinary layout.
git -C "$oslug" remote add upstream https://github.com/junegunn/fzf.git
eq "$(cd "$oslug" && adb_git_origin_slug)" "junegunn/fzf" \
   "adb_git_origin_slug falls back to the SOLE remote when there is no origin"
# ...but with several remotes and no origin there is no single answer, and picking one is a guess.
git -C "$oslug" remote add fork https://github.com/me/fzf.git
out="$(cd "$oslug" && adb_git_origin_slug 2>/dev/null)"; rc=$?
no "$rc" "adb_git_origin_slug refuses to pick among several remotes with no origin"
eq "$out" "" "adb_git_origin_slug prints nothing when the single answer is ambiguous"

# --- adb_slug_eq: the ONE comparison of two `owner/repo` values (#340) --------------------------
# GitHub slugs are case-insensitive, and the two anchors are not case-consistent by construction:
# the git side is folded here, `.full_name` is whatever GitHub stores. A case-sensitive comparison
# therefore refused EVERY run in any repo with uppercase in its slug.
for _p in "acme/widget|Acme/Widget" "ACME/WIDGET|acme/widget" "AcMe/WiDgEt|aCmE/wIdGeT" \
          "acme/widget|acme/widget"; do
  adb_slug_eq "${_p%%|*}" "${_p##*|}"
  yes "$?" "adb_slug_eq: '${_p%%|*}' and '${_p##*|}' name one repository"
done
# A DIFFERENT repository, and every unusable value, must refuse — folding must not make two repos
# equal, and "cannot prove they match" is not "they match".
for _p in "acme/widget|acme/widgets" "acme/widget|other/widget" "Acme/Widget|acme-co/widget" \
          "acme/widget|" "|acme/widget" "|" "acme|acme" "a/b/c|a/b/c" "acme/widget|acme/widget/x"; do
  adb_slug_eq "${_p%%|*}" "${_p##*|}"
  no "$?" "adb_slug_eq: refuses '${_p%%|*}' vs '${_p##*|}'"
done
# The defect in its real shape: a folded git anchor against the API's canonical case.
gslug="$work/gitcase"; mkdir -p "$gslug"; git init -q "$gslug"
git -C "$gslug" remote add origin "https://github.com/BWBama85/ai-dev-baseline.git"
adb_slug_eq "$(cd "$gslug" && adb_git_origin_slug)" "BWBama85/ai-dev-baseline"
yes "$?" "adb_slug_eq: the folded git anchor agrees with the API's canonical case (#340)"

# --- adb_git_repo_slugs: the anchor SET, which is what a cross-check needs ----------------------
# Reading only `origin` was a real regression, verified against both ordinary layouts below: in a FORK
# clone the pull request being gated lives on `upstream`, so an origin-only anchor returns a
# confidently readable, confidently WRONG slug and the guard emits a FALSE refusal. Membership in the
# remote set is the honest question, and it still refuses a repository the checkout does not track.
fslug="$work/forkslug"; mkdir -p "$fslug"; git init -q "$fslug"
git -C "$fslug" remote add origin   https://github.com/me/fzf.git
git -C "$fslug" remote add upstream git@github.com:junegunn/fzf.git
eq "$(cd "$fslug" && adb_git_repo_slugs | tr '\n' ',')" "junegunn/fzf,me/fzf," \
   "adb_git_repo_slugs lists every remote's slug, sorted and de-duplicated"
# `origin` still wins for the single-slug accessor — a caller passing `gh --repo` wants one answer.
eq "$(cd "$fslug" && adb_git_origin_slug)" "me/fzf" "adb_git_origin_slug still prefers origin"
# Duplicates collapse (a `push`/`fetch` pair naming one repo is not two repos).
git -C "$fslug" remote add mirror https://github.com/ME/FZF.git
eq "$(cd "$fslug" && adb_git_repo_slugs | tr '\n' ',')" "junegunn/fzf,me/fzf," \
   "adb_git_repo_slugs de-duplicates case-insensitively"
# A remote that does not resolve to a PAIR contributes nothing rather than a junk slug.
git -C "$fslug" remote add weird "file:///tmp"
eq "$(cd "$fslug" && adb_git_repo_slugs | tr '\n' ',')" "junegunn/fzf,me/fzf," \
   "adb_git_repo_slugs skips a remote that is not an owner/repo pair"
# NOT host-filtered, and that is deliberate rather than an oversight: GHES lives on arbitrary
# hostnames, so "is this host GitHub?" has no local answer. A path-shaped remote that happens to look
# like `a/b` therefore DOES land in the set — harmlessly, because the value it is compared against is
# `base.repo.full_name` from the GitHub API, which can only ever name a real GitHub repository.
git -C "$fslug" remote add pathy "../sibling"
eq "$(cd "$fslug" && adb_git_repo_slugs | grep -c .)" "3" \
   "adb_git_repo_slugs keeps a path-shaped pair (host-filtering is not locally decidable)"
git -C "$fslug" remote remove pathy; git -C "$fslug" remote remove weird

# --- the fork and upstream-only layouts, through the cross-check --------------------------------
# THE REGRESSION, pinned. Both of these worked before the anchor existed and must work now.
fsc() { ( cd "$1" && adb_pr_slug_check test 7 "$2" "$3" >/dev/null 2>&1; echo $? ); }
eq "${ fsc "$fslug" 7 'junegunn/fzf'; }" "0" \
   "fork clone: a PR on UPSTREAM verifies (an origin-only anchor called this a different repository)"
eq "${ fsc "$fslug" 7 'me/fzf'; }" "0" "fork clone: a PR on the fork itself also verifies"
# ...and the hole the anchor exists for is still closed: GH_REPO names a repo in NOBODY's remote set.
eq "${ fsc "$fslug" 7 'cli/cli'; }" "2" "fork clone: a read that answered for an UNTRACKED repo is still refused"
uslug="$work/upstreamonly"; mkdir -p "$uslug"; git init -q "$uslug"
git -C "$uslug" remote add upstream https://github.com/junegunn/fzf.git
eq "${ fsc "$uslug" 7 'junegunn/fzf'; }" "0" \
   "upstream-only clone: verifies (an origin-only anchor had no anchor at all here)"
eq "${ fsc "$uslug" 7 'cli/cli'; }" "2" "upstream-only clone: an untracked repo is still refused"

# --- adb_pr_slug_check: the cross-check, and its ORDER -----------------------------------------
mk_origin "https://github.com/acme/widget.git"
sc() { ( cd "$oslug" && adb_pr_slug_check test 7 "$1" "$2" >/dev/null 2>&1; echo $? ); }
eq "${ sc '7' 'acme/widget'; }" "0" "slug-check: a bare number against the matching checkout verifies"
eq "${ sc 'https://github.com/acme/widget/pull/7' 'acme/widget'; }" "0" "slug-check: an agreeing URL verifies"
eq "${ sc 'https://github.com/Acme/Widget/pull/7' 'ACME/WIDGET'; }" "0" "slug-check: comparison is case-insensitive on both sides"
eq "${ sc 'https://github.com/other/project/pull/7' 'acme/widget'; }" "2" "slug-check: a URL naming another repo is refused"
eq "${ sc 'github.com/other/project/pull/7' 'acme/widget'; }" "2" "slug-check: the SCHEME-LESS form is refused too (#173)"
# The GH_REPO class: a bare number names no repository, so only the checkout anchor catches a
# redirected read.
eq "${ sc '7' 'other/project'; }" "2" "slug-check: reads that answered for another repo are refused even for a bare number"
# UNREADABLE OUTRANKS MISMATCHED, and that order is part of the contract. The old check was guarded on
# a non-empty observed slug, so it silently VANISHED on exactly these responses — and a foreign URL
# was then answered about this repo. Each must report 1 (the caller's 20), never 2 and never 0.
for got in "" "acme" "acme/widget/extra" "/widget" "acme/"; do
  eq "${ sc '7' "$got"; }" "1" "slug-check: an observed slug of '$got' is unreadable (1), not a mismatch"
  eq "${ sc 'https://github.com/other/project/pull/7' "$got"; }" "1" \
     "slug-check: unreadable metadata outranks a foreign URL ('$got')"
done
# A slug beginning with `-` must be COMPARED, not handed to grep as options. Without `--` grep aborted
# with a usage dump and the comparison never ran, and the code then reported a repository mismatch for
# a test that had not happened. Unreachable from the API, but the harness calls this primitive directly.
_dashout="$( cd "$oslug" && adb_pr_slug_check test 7 '' '-x/y' 2>&1 >/dev/null )"
eq "${ sc '7' '-x/y'; }" "2" "slug-check: a leading-dash slug is refused as a mismatch"
hasnt "$_dashout" "invalid option" "slug-check: grep never sees a slug as its own options"
hasnt "$_dashout" "Usage" "slug-check: no raw grep usage dump reaches the operator"

# An unresolvable checkout is also unverifiable rather than a mismatch — fail closed, both codes
# distinct. Every remote goes, not just origin: with any remote left the checkout still has an
# identity, so the honest answer would be 2 (a mismatch) rather than 1 (no anchor at all).
for r in $(git -C "$oslug" remote); do git -C "$oslug" remote remove "$r"; done
eq "${ sc '7' 'acme/widget'; }" "1" "slug-check: no remotes at all -> unverifiable (1), never verified"
# Diagnostics go to stderr under the caller's label, and stdout stays empty (callers print SHAs there).
mk_origin "https://github.com/acme/widget.git"
_scout="$( cd "$oslug" && adb_pr_slug_check mylabel 7 'https://github.com/other/project/pull/7' 'acme/widget' 2>/dev/null )"
eq "$_scout" "" "slug-check prints nothing on stdout"
_scerr="$( cd "$oslug" && adb_pr_slug_check mylabel 7 'https://github.com/other/project/pull/7' 'acme/widget' 2>&1 >/dev/null )"
has "$_scerr" "mylabel:" "slug-check labels its diagnostic with the caller's name"
has "$_scerr" "different repository" "slug-check says why it refused"

# --- adb_reviewer_match_jq: the ASYMMETRIC identity predicate ----------------------------------
# The rule four filters across the two guards ask, so all four must ask it the same way. Exercised
# here as the full matrix rather than through one guard's scenario.
#
# THE DIRECTION IS THE POINT. The API login is normalized TOWARD the declaration: a bare declaration
# accepts either spelling (portable across the GraphQL/REST split), a `[bot]` declaration accepts only
# the suffixed one. Stripping the DECLARATION too — what both modules used to do — meant `foo[bot]` was
# satisfied by a HUMAN account literally named `foo`, and `gh api users/gemini-code-assist` returns a
# real User account (id 200291788), so that collision space is populated.
rmatch() {   # <api-login> <declared…> -> "true"/"false"
  local api="$1"; shift
  jq -n -r --arg a "$api" --argjson who "${ printf '%s\n' "$@" | jq -R -s -c 'split("\n")|map(select(length>0))'; }" \
    "$(adb_reviewer_match_jq) \$a | adb_declared_reviewer(\$who)" 2>/dev/null
}
eq "${ rmatch 'foo' 'foo'; }"                "true"  "identity: bare declared, bare login -> match"
eq "${ rmatch 'foo[bot]' 'foo'; }"           "true"  "identity: bare declared, '[bot]' login -> match (the REST spelling)"
eq "${ rmatch 'FOO[BOT]' 'foo'; }"           "true"  "identity: matching is case-insensitive"
eq "${ rmatch 'FOO[BOT]' 'foo[bot]'; }"      "true"  "identity: case-insensitive for a suffixed declaration too"
# CASE IS FOLDED ON BOTH SIDES. The production path lower-cases the declaration before it gets here,
# so this asserts the primitive is correct STANDALONE — a future consumer passing a raw declaration
# must not silently match nothing, because "matches nothing" wedges a guard at "awaiting review"
# forever, which is the safe and therefore silent direction.
eq "${ rmatch 'foo' 'FOO[BOT]'; }"           "false" "identity: a RAW uppercase '[bot]' declaration still rejects a human"
eq "${ rmatch 'foo[bot]' 'FOO[BOT]'; }"      "true"  "identity: a RAW uppercase declaration still matches its App"
eq "${ rmatch 'foo' 'FOO'; }"                "true"  "identity: a RAW uppercase bare declaration matches"
eq "${ rmatch 'foo[bot]' 'foo[bot]'; }"      "true"  "identity: '[bot]' declared, '[bot]' login -> match"
eq "${ rmatch 'foo' 'foo[bot]'; }"           "false" "identity: '[bot]' declared, HUMAN login -> NO match (#176's fail-open)"  # adb-claim-ok: deliberately historical; #176 is named as the fail-open this case pins
eq "${ rmatch 'foo[bot][bot]' 'foo[bot]'; }" "false" "identity: a DOUBLED suffix does not satisfy '[bot]' declared"
eq "${ rmatch 'bar' 'foo'; }"                "false" "identity: an unrelated login does not match"
eq "${ rmatch 'bar[bot]' 'foo'; }"           "false" "identity: an unrelated BOT does not match (an allowlist, not a heuristic)"
eq "${ rmatch 'foobar' 'foo'; }"             "false" "identity: the match is anchored, not a prefix test"
eq "${ rmatch 'foo' 'foo' 'foo'; }"          "true"  "identity: a duplicated declaration still matches"
eq "${ rmatch 'baz[bot]' 'foo' 'baz[bot]'; }" "true" "identity: any ONE of several declarations may match"
eq "${ rmatch 'foo' 'bar[bot]' 'foo'; }"     "true"  "identity: a bare entry beside a suffixed one still matches"
eq "${ rmatch 'foo'; }"                      "false" "identity: an EMPTY declaration set matches nothing"
# An entry that is only the suffix must not become a reviewer that matches everything suffixed. The
# declaration reader drops it (and then rejects the declaration); the predicate must not rescue it.
eq "${ rmatch 'anything[bot]' '[bot]'; }"    "false" "identity: a bare '[bot]' entry does not match every App"

# ============ the reviewer-evidence classifier and its folds (#167) ============
# The ONE answer to "given everything a declared reviewer emitted, has this head been reviewed, and
# was it clean?", exercised HERE as a matrix rather than only through either guard's scenarios —
# both consumers map it to different exit codes, so a bug in the shared rule would otherwise have to
# be diagnosed twice from two different vocabularies.
#
# --- adb_is_utc_instant: the grammar that makes a lexicographic compare a chronological one -------
# NOT defensive padding. The equivalence holds only while every operand is the same width, precision
# and zone: `2026-07-25T09:00:00-04:00` sorts BEFORE `2026-07-25T05:00:00Z` as a string and AFTER it
# as an instant, and `…:00.123Z` loses to `…:01Z` on a prefix compare.
for good in "2026-07-25T04:42:15Z" "1999-01-01T00:00:00Z" "9999-12-31T23:59:59Z"; do
  if adb_is_utc_instant "$good"; then ok; else bad "adb_is_utc_instant accepts '$good'"; fi
done
for v in "" "2026-07-25T04:42:15-04:00" "2026-07-25T04:42:15.500Z" "2026-07-25 04:42:15Z" \
         "2026-07-25T04:42:15" "26-07-25T04:42:15Z" "not-a-date" "2026-07-25T04:42:15z"; do
  if adb_is_utc_instant "$v"; then bad "adb_is_utc_instant rejects '$v'"; else ok; fi
done
# THE LAYOUT CHECK ALONE IS NOT ENOUGH, and the gap was not academic: a character-class glob accepts
# `9999-99-99T99:99:99Z`, which sorts above every real timestamp AND above ADB_NO_ANCHOR itself — so
# ONE malformed `created_at` read as fresh against any anchor, including the far-future sentinel
# whose whole job is to make an unestablished anchor fail closed, and classified the reviewer
# `clean`. Reported by the codex reviewer on PR #219.
for v in "9999-99-99T99:99:99Z" "2026-13-25T04:42:15Z" "2026-00-25T04:42:15Z" "2026-07-00T04:42:15Z" \
         "2026-07-32T04:42:15Z" "2026-07-25T24:42:15Z" "2026-07-25T04:60:15Z" "2026-07-25T04:42:61Z"; do
  if adb_is_utc_instant "$v"; then bad "adb_is_utc_instant range-rejects '$v'"; else ok; fi
done
# ...and the sentinel must still be an orderable instant under the tighter rule, or every date-scoped
# signal would fail validation the moment no anchor could be established.
if adb_is_utc_instant "$ADB_NO_ANCHOR"; then ok; else bad "ADB_NO_ANCHOR must pass the range check"; fi
# Boundaries that must still be ACCEPTED. A leap second is real UTC; day-of-month is bounded at 31
# without calendar validation, which is deliberate — `2026-02-31` still ORDERS correctly, and
# calendar checking would need the date library this file avoids for GNU/BSD portability.
for v in "2026-01-01T00:00:00Z" "2026-12-31T23:59:59Z" "2026-06-30T23:59:60Z" "2026-02-31T12:00:00Z"; do
  if adb_is_utc_instant "$v"; then ok; else bad "adb_is_utc_instant still accepts '$v'"; fi
done

# --- the classifier, end to end -----------------------------------------------------------------
SHA="aaaa"; ANCH="2026-07-25T04:42:15Z"
FRESH="2026-07-25T04:45:23Z"; STALE="2026-07-25T04:40:00Z"
# cls <who-csv> <reviews> <comments> <reactions> [anchor] -> the FOLDED class across the set
cls() {
  local who="$1" ev
  ev="$(adb_reviewer_evidence "${ printf '%s' "$who" | tr ',' '\n'; }" "$2" "$3" "$4" "$SHA")" || { printf 'ERR'; return; }
  local c; c="$(adb_reviewer_classes t "${ printf '%s' "$who" | tr ',' '\n'; }" "$ev" "${5:-$ANCH}" 2>/dev/null)" \
    || { printf 'RC2'; return; }
  adb_fold_reviewer_classes "$c"
}
rv()  { printf '[{"user":{"login":"%s"},"state":"%s","commit_id":"%s"}]' "$1" "$2" "${3:-$SHA}"; }
cm()  { printf '[{"user":{"login":"%s"},"created_at":"%s"}]' "$1" "$2"; }
rx()  { printf '[{"user":{"login":"%s"},"content":"%s","created_at":"%s"}]' "$1" "${2:-+1}" "$3"; }
N='[]'

# THE TABLE (#167 §4), one row at a time.
eq "${ cls a "${ rv a CHANGES_REQUESTED; }" "$N" "$N"; }" "rejected"  "classify: CHANGES_REQUESTED at head -> rejected"
eq "${ cls a "${ rv a COMMENTED; }"         "$N" "$N"; }" "attention" "classify: COMMENTED at head -> attention"
eq "${ cls a "${ rv a APPROVED; }"          "$N" "$N"; }" "clean"     "classify: APPROVED at head -> clean"
eq "${ cls a "${ rv a PENDING; }"           "$N" "$N"; }" "none"      "classify: an unsubmitted PENDING draft is not evidence"
eq "${ cls a "${ rv a DISMISSED; }"         "$N" "$N"; }" "none"      "classify: a DISMISSED review is not evidence"
eq "${ cls a "${ rv a WHAT_IS_THIS; }"      "$N" "$N"; }" "unknown"   "classify: an unrecognized state -> unknown (fails closed)"
eq "${ cls a "${ rv a APPROVED bbbb; }"     "$N" "$N"; }" "none"      "classify: a review of ANOTHER commit is not evidence about this head"
# A REVIEW THAT CANNOT BE TIED TO A COMMIT IS `unknown`, NOT ABSENT. The commit filter used to run
# BEFORE the reviewer match, so a declared reviewer CHANGES_REQUESTED whose commit_id was missing or
# non-string was discarded before anything read who wrote it — and a fresh `+1` on another surface
# then became the only evidence left, folding to `clean` and arming the merge. Reported by the codex
# reviewer on PR #219; the fourth assertion below is the one that was `clean` before the fix.
NO_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED"}]'
NULL_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":null}]'
NUM_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":12345}]'
FOREIGN_NO_CID='[{"user":{"login":"nobody"},"state":"CHANGES_REQUESTED"}]'
eq "${ cls a "$NO_CID" "$N" "$N"; }" "unknown" \
   "classify: a declared reviewer review with NO commit_id -> unknown, never absent"
eq "${ cls a "$NULL_CID" "$N" "$N"; }" "unknown" \
   "classify: ...an explicitly null commit_id likewise"
eq "${ cls a "$NUM_CID" "$N" "$N"; }" "unknown" \
   "classify: ...and a NON-STRING commit_id, which the equality test silently dropped"
eq "${ cls a "$NO_CID" "$N" "${ rx a +1 "$FRESH"; }"; }" "unknown" \
   "classify: an undatable rejection is NOT outvoted by a fresh +1 (the false-arm)"
# ...but an UNDECLARED login with the same malformation must not wedge the guard: only declared
# reviewers are classified, so a stray malformed review from anyone else is simply not evidence.
eq "${ cls a "$FOREIGN_NO_CID" "$N" "${ rx a +1 "$FRESH"; }"; }" "clean" \
   "classify: an UNDECLARED login with no commit_id does not wedge the guard"

# THE WITHIN-REVIEWER ORDER: rejected > attention > unknown > clean > none.
eq "${ cls a "${ rv a APPROVED; }" "${ cm a "$FRESH"; }" "$N"; }" "attention" \
   "within-reviewer: a fresh comment outranks that reviewer's APPROVED"
eq "${ cls a "${ printf '[{"user":{"login":"a"},"state":"COMMENTED","commit_id":"%s"},{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":"%s"}]' "$SHA" "$SHA"; }" "$N" "$N"; }" "rejected" \
   "within-reviewer: a standing CHANGES_REQUESTED outranks a COMMENTED on the same commit"
eq "${ cls a "${ printf '[{"user":{"login":"a"},"state":"WEIRD","commit_id":"%s"},{"user":{"login":"a"},"state":"APPROVED","commit_id":"%s"}]' "$SHA" "$SHA"; }" "$N" "$N"; }" "unknown" \
   "within-reviewer: UNKNOWN outranks clean — an uninterpretable state is never outvoted into a pass"
eq "${ cls a "${ rv a APPROVED; }" "$N" "${ rx a +1 "$STALE"; }"; }" "clean" \
   "within-reviewer: a STALE '+1' beside that reviewer's APPROVED is still clean"

# THE ACROSS-REVIEWER ORDER IS NOT THE SAME ORDER, and the swapped pair IS #185: `none` outranks
# `clean`, so a pass requires EVERY declared reviewer. Reusing the within-reviewer order here is
# exactly the shipped bug — one fast `+1` reporting a clean pass for a set that had not looked.
eq "${ cls a,b "$N" "$N" "${ rx a +1 "$FRESH"; }"; }" "none" \
   "#185: one fresh '+1' of two declared reviewers folds to none, NOT clean"
eq "${ cls a,b "$N" "$N" "${ printf '[{"user":{"login":"a"},"content":"+1","created_at":"%s"},{"user":{"login":"b"},"content":"+1","created_at":"%s"}]' "$FRESH" "$FRESH"; }"; }" "clean" \
   "#185: BOTH declared reviewers clean -> clean"
eq "${ cls a,b "${ rv a CHANGES_REQUESTED; }" "$N" "$N"; }" "rejected" \
   "#185: a rejection from one wins outright over another's silence"
eq "${ cls a,b "${ rv b WEIRD; }" "$N" "${ rx a +1 "$FRESH"; }"; }" "unknown" \
   "#185: unknown outranks a sibling's clean — fail closed, never arm"
eq "${ cls a,b "${ rv b APPROVED; }" "$N" "${ rx a +1 "$FRESH"; }"; }" "clean" \
   "#185: mixed evidence across surfaces still satisfies the whole set"

# UNDATABLE AND UNORDERABLE RECORDS. A declared reviewer's signal with no `created_at` is malformed,
# and dropping it would silently read as "that reviewer said nothing" — which on the clean path is a
# false pass. An unrecognized FORMAT is rejected outright (rc 2) rather than normalized.
eq "${ cls a "$N" '[{"user":{"login":"a"},"body":"x"}]' "$N"; }" "unknown" \
   "classify: a declared reviewer's comment with NO timestamp -> unknown"
eq "${ cls a "$N" "$N" '[{"user":{"login":"a"},"content":"+1"}]'; }" "unknown" \
   "classify: a declared reviewer's '+1' with NO timestamp -> unknown"
eq "${ cls a "$N" "${ cm a '2026-07-25T04:45:23-04:00'; }" "$N"; }" "RC2" \
   "classify: an unorderable timestamp FORMAT returns rc 2, never a guessed ordering"
eq "${ cls a "$N" '[{"user":{"login":"nobody"},"body":"x"}]' "$N"; }" "none" \
   "classify: an UNDECLARED login's undatable record is ignored, not fatal"

# THE SENTINEL. `ADB_NO_ANCHOR` is what an unestablished anchor degrades to, and it must make every
# date-scoped signal read as stale while leaving commit-scoped review evidence untouched. An EMPTY
# anchor would be the fail-open spelling exactly — every non-empty string is `\>` the empty one.
eq "${ cls a "$N" "$N" "${ rx a +1 "$FRESH"; }" "$ADB_NO_ANCHOR"; }" "none" \
   "sentinel: an unestablished anchor makes a fresh '+1' unprovable -> none, never clean"
eq "${ cls a "${ rv a APPROVED; }" "$N" "$N" "$ADB_NO_ANCHOR"; }" "clean" \
   "sentinel: commit-scoped review evidence is unaffected by an unestablished anchor"
if adb_is_utc_instant "$ADB_NO_ANCHOR"; then ok; else bad "ADB_NO_ANCHOR must itself be an orderable instant"; fi

# The fold's identity: no reviewer classified at all is `none`, never `clean`.
eq "$(adb_fold_reviewer_classes "")" "none" "fold: an EMPTY class list is none, never clean"
eq "$(adb_reviewers_in_class "${ printf 'a\tnone\nb\tclean\nc\tnone'; }" none)" "a c" \
   "adb_reviewers_in_class names exactly the logins in that class"
eq "$(adb_reviewers_in_class "${ printf 'a\tclean'; }" none)" "" \
   "adb_reviewers_in_class is empty when nobody is in the class"
# SEVERAL classes at once — pr-watch reports `rejected` and `attention` as one outcome, and joining
# two separately-fetched lists (either of which may be empty) is what produced a stray double space.
eq "$(adb_reviewers_in_class "${ printf 'a\trejected\nb\tnone\nc\tattention'; }" rejected attention)" "a c" \
   "adb_reviewers_in_class accepts several classes and preserves order"
eq "$(adb_reviewers_in_class "${ printf 'a\trejected\nb\tnone'; }" rejected attention)" "a" \
   "...with no stray separator when only one of the named classes is populated"

# THE `<login> <class>` GRAMMAR IS PARSED FROM THE RIGHT. A login carrying whitespace can never name
# a real GitHub account and `role-dispatch bots --comparable` rejects the whole declaration for it
# (18, fail-closed — dropping just the bad entry would SHRINK the set every consumer must satisfy).
# These pin the belt to that braces: parsed from the LEFT, `foo bar none` yields the non-class
# "bar none", which ranks as none by accident rather than by rule and makes the diagnostic garbage.
eq "$(adb_fold_reviewer_classes "${ printf 'foo bar\tnone'; }")" "none" \
   "fold: a whitespace-bearing login still yields a REAL class, not a garbled one"
eq "$(adb_fold_reviewer_classes "${ printf 'foo bar\tclean'; }")" "clean" \
   "fold: ...and the TAB split is total, so a clean class is not lost"
eq "$(adb_reviewers_in_class "${ printf 'foo bar\tnone\nb\tclean'; }" none)" "foo bar" \
   "adb_reviewers_in_class recovers the whole login, not its first word"
# ...and the same login round-trips through the CLASSIFIER, which the space grammar could not do:
# it split `foo bar` at the delimiter, so the reviewer never matched its own evidence.
eq "${ cls "foo bar" "$N" "$N" "${ printf '[{"user":{"login":"foo bar"},"content":"+1","created_at":"%s"}]' "$FRESH"; }"; }" "clean" \
   "classify: a whitespace-bearing login matches its OWN evidence under the TAB grammar"

# --- adb_md_prose: THE shared CommonMark prose filter (#136) ------------------
# The primitive's own unit home. `check-roadmap.sh` and `check-skill-compose.sh` exercise it
# THROUGH their consumers, which is where the interesting inputs live — but a shared primitive gets
# tested here too, so a break is attributed to the filter rather than to whichever consumer noticed.
#
# `mdp <mode> <body>` — the filter's stdout. `%b` so a fixture can be written with \n and \t.
mdp() { printf '%b' "$2" | adb_md_prose "$1"; }

# The three views, on one line that has all three shapes in it.
SPANLINE='keep `a span` and <!-- a comment --> too\n'
# DIRECTION, on every fixture in this block: an OVER-match means the filter left something a
# consumer will scan as a declaration; an UNDER-match means it removed text that was never markup.
eq "${ mdp text "$SPANLINE"; }"   'keep `a span` and  too' "OVER/UNDER: text — comments go, spans stay"
eq "${ mdp mask "$SPANLINE" | tr -d '\001'; }" 'keep  and  too' "mask: span contents become \\x01 (shown here with the mask bytes stripped)"
eq "${ mdp mask "$SPANLINE" | wc -c | tr -d ' '; }" "${ mdp text "$SPANLINE" | wc -c | tr -d ' '; }" \
   "mask is byte-for-byte the SAME LENGTH as text — the 1:1 invariant every offset-pairing consumer needs"
eq "${ printf '%b' "$SPANLINE" | adb_md_prose mask --keep-comments | tr -d '\001'; }" 'keep  and <!-- a comment --> too' \
   "--keep-comments: the comment survives (the marker consumers need this; the flag exists for them)"

# MASKING, NOT DELETION — the self-review find. Deleting a span lets its neighbours FUSE into a word
# nobody wrote, and every consumer that scans for a keyword would inherit that. \x01 is a boundary
# no keyword can cross. DIRECTION: over-match (a fabricated keyword freezes a ready issue).
eq "${ mdp mask 'clo`x`ses #42\n' | tr -d '\001'; }" 'closes #42' \
   "deleting the mask bytes shows the fusion that WOULD happen if the span were dropped..."
eq "${ mdp mask 'clo`x`ses #42\n' | grep -c 'closes'; }" 0 \
   "...and it does not happen, because the span is masked rather than removed"

# LINE COUNT AND ORDER ARE PRESERVED. Every consumer indexes results by line, so a structural line
# must yield an EMPTY line at its own position, never a deletion that renumbers what follows.
eq "${ mdp text 'a\n```\nb\n```\nc\n' | wc -l | tr -d ' '; }" 5 \
   "UNDER: line count survives a fenced block — a deletion would renumber every consumer's index"
eq "${ mdp text 'a\n```\nb\n```\nc\n' | sed -n '3p'; }" '' "OVER: ...and the fenced line is empty at its own index"
eq "${ mdp text 'a\n```\nb\n```\nc\n' | sed -n '5p'; }" 'c' "UNDER: ...so the line after it keeps its number"

# STRUCTURE, one kind at a time. Each is empty output because the whole body is structure.
eq "${ mdp text '```\nx\n```\n'; }" '' "OVER: a fenced block is structure"
eq "${ mdp text '~~~\nx\n~~~\n'; }" '' "OVER: ...both delimiters"
eq "${ mdp text '> quoted\n'; }" ''    "OVER: a blockquote is structure"
eq "${ mdp text '<!--\nx\n-->\n'; }" '' "OVER: a multi-line HTML comment is removed"
eq "${ mdp text '    indented\n'; }" '' "OVER: a top-level indented block is structure (D27)"
eq "${ mdp text '- item\n    continued\n'; }" '- item
    continued' "UNDER: ...but an indented line under a list marker is prose (D27)"

# CONTAINER COLUMN (#252, D42). Indentation inside a list means nothing except relative to the open
# item's content column, so the filter carries that one integer. Asserted here at the primitive as
# well as through `deps-from-body`, because the bug was in the filter and a consumer-only fixture
# would attribute the next break to whichever consumer noticed it.
eq "${ mdp text '- item\n    ~~~\n    x\n    ~~~\n'; }" '- item' \
   "OVER: a fence indented to the item's content column is structure, and takes its contents with it"
eq "${ mdp text '- item\n    > q\n'; }" '- item' \
   "OVER: ...and so is a blockquote at that column"
eq "${ mdp text '- item\n    ~~~\n    x\n    ~~~\n' | wc -l | tr -d ' '; }" 4 \
   "...with the line count still 1:1, so no consumer's index shifts"
eq "${ mdp text '- item\n      ~~~\n      x\n      ~~~\n' | wc -l | tr -d ' '; }" 4 \
   "UNDER: at content column + 4 nothing is stripped (D27's guard) — same four lines..."
eq "${ mdp text '- item\n      ~~~\n      x\n      ~~~\n' | grep -c .; }" 4 \
   "...and all four still carry text, because that far in it is item-relative indented code"

# MULTI-LINE SPANS — the reason the filter buffers at all (#136 §1).
# Asserted with `wc -l`, not against a literal: `$( … )` strips trailing newlines, so comparing
# two empty lines to '' would pass whether or not the second line survived at all.
eq "${ mdp mask '`a\nb`\n' | wc -l | tr -d ' '; }" 2 \
   "a span crossing a line ending is resolved, and BOTH its lines are still there"
eq "${ mdp mask '`a\nb`\n' | tr -d '\001\n' | wc -c | tr -d ' '; }" 0 \
   "...with nothing but mask bytes left in either of them"
eq "${ mdp mask 'x`a\nb\n'; }" 'x`a
b' "an UNMATCHED run is literal text, so a stray backtick swallows nothing"

# LEFTMOST OPENER WINS — the ordering that satisfies both #136 repros at once. Comments-first
# honors a quoted opener and swallows the body; spans-first pairs a backtick inside a real comment
# with one in later prose. One left-to-right pass is the only rule that gets both right.
eq "${ mdp text 'the opener is `<!--` here\nkept\n'; }" 'the opener is `<!--` here
kept' "UNDER: a <!-- inside a code span opens no comment"
eq "${ mdp text 'real <!-- ` --> kept\n'; }" 'real  kept' "OVER: a backtick inside a real comment goes with it"

# ARGUMENT VALIDATION and the FAIL-CLOSED completion marker. A truncated filter run must never look
# like a clean short result — that is the fail-open `pr-targets-issue` maps to rc 2.
adb_md_prose bogus </dev/null >/dev/null 2>&1; eq "$?" 2 "an unknown mode is rejected (2)"
adb_md_prose text --nope </dev/null >/dev/null 2>&1; eq "$?" 2 "an unknown option is rejected (2)"
eq "${ printf '' | adb_md_prose text | wc -c | tr -d ' '; }" 0 "empty input is empty output, not an error"
mdstub="$(mktemp -d)"
printf '#!/bin/sh\nprintf "half\\n"\nexit 0\n' > "$mdstub/awk"; chmod +x "$mdstub/awk"
( PATH="$mdstub:$PATH"; printf 'x\n' | adb_md_prose text >/dev/null 2>&1 ); eq "$?" 1 \
   "a TRUNCATED run (exit 0, no completion marker) is a FAILURE, not a short clean result"
printf '#!/bin/sh\nexit 9\n' > "$mdstub/awk"
( PATH="$mdstub:$PATH"; printf 'x\n' | adb_md_prose text >/dev/null 2>&1 ); eq "$?" 1 \
   "...and so is a hard awk failure"
# THE MARKER MUST NOT BE FORGEABLE, or the guard proves less than it claims. A stub that emits a
# CONSTANT trailer would satisfy a constant check, and so would a body whose own last line happened
# to be that text — so the trailer carries a per-invocation nonce. This stub emits the fixed prefix
# and is still rejected. (Review finding: without this case the negative test covered only the
# easy non-collision half.)
printf '#!/bin/sh\nprintf "\\001ADB_MD_OK\\n"\nexit 0\n' > "$mdstub/awk"
( PATH="$mdstub:$PATH"; printf 'x\n' | adb_md_prose text >/dev/null 2>&1 ); eq "$?" 1 \
   "a stub emitting the FIXED marker text is rejected — the trailer is nonced per invocation"
rm -rf "$mdstub"


# --- adb_wf_on / adb_wf_jobs: THE shared workflow reader (#262, #102) ---------
#
# Direct contract coverage, not only the two consumers' coverage. This reader is the single answer
# to "what does this workflow declare", so a consumer test can only ever show that ONE filter still
# behaves; a record this reader stops emitting is invisible to a consumer that never wanted it, and
# that asymmetry is exactly how the two scanners drifted in the first place.

wfd="$(mktemp -d)"
# wf <name> — records for a fixture, tabs rendered as `|` so a whole record is one eq assertion.
wf()  { adb_wf_jobs "$wfd/$1" | tr '\t' '|' | tr '\n' ' '; }
wfon(){ adb_wf_on   "$wfd/$1" | tr '\t' '|' | tr '\n' ' '; }

# THE SAME WORKFLOW AT TWO INDENT UNITS must produce byte-identical records apart from line
# numbers. This is #102's whole claim, and asserting the two are EQUAL is stronger than asserting
# each is individually plausible: no indent unit is detected or privileged anywhere.
cat > "$wfd/two.yml" <<'EOF'
name: CI
on:
  pull_request:
    branches:
      - main
jobs:
  lint:
    name: Lint
    runs-on: ubuntu-26.04
    steps:
      - name: a
        run: bash --version
EOF
cat > "$wfd/four.yml" <<'EOF'
name: CI
on:
    pull_request:
        branches:
            - main
jobs:
    lint:
        name: Lint
        runs-on: ubuntu-26.04
        steps:
            - name: a
              run: bash --version
EOF
eq "${ wfon two.yml; }" "${ wfon four.yml; }" \
   "on: reads identically at 2- and 4-space indent (#102: the 4-space file used to report 'no pull_request trigger')"
eq "${ wf two.yml; }" "${ wf four.yml; }" \
   "jobs: read identically at 2- and 4-space indent, line numbers included (the files are line-for-line parallel)"
has "${ wfon four.yml; }" "TRIGGER|pull_request" "a 4-space pull_request trigger is seen at all"
has "${ wf four.yml; }"   "RUNSON|1|ubuntu-26.04" "a 4-space runs-on is read"
has "${ wf four.yml; }"   "STEP|1|1|11" "a 4-space step boundary is found (steps sit at 12 spaces there)"

# A MIXED FILE — 2-space `on:`, 4-space `jobs:` — is valid YAML, and it is the case an "detect the
# file's indent unit" heuristic gets wrong: there is no single unit to detect. Relative depth has
# no opinion, which is why this reads.
cat > "$wfd/mixed.yml" <<'EOF'
name: CI
on:
  pull_request:
jobs:
    lint:
        name: Lint
        runs-on: ubuntu-26.04
        steps:
            - name: a
              run: bash --version
EOF
has "${ wfon mixed.yml; }" "TRIGGER|pull_request" "a mixed file's 2-space on: block is read"
has "${ wf mixed.yml; }"   "JOB|1|lint"           "...and its 4-space jobs: block in the same file"
has "${ wf mixed.yml; }"   "NAME|1|Lint"          "...including a job property at the deeper unit"

# THE DRIFT THAT PROVED #262. Quote first, THEN comment: a quoted value ends at its closing quote,
# so the whole quoted string is the label; an UNQUOTED one ends at a whitespace-preceded `#`. Both
# halves, because getting either backwards ships a real defect in opposite directions — an accepted
# job GitHub will never schedule, or a required context nothing ever reports.
cat > "$wfd/scalar.yml" <<'EOF'
on:
  pull_request:
jobs:
  a:
    name: Build  # the main build job
    runs-on: "ubuntu-26.04 # not-the-label"
  b:
    name: "quoted # kept"
    runs-on: ubuntu-26.04  # trailing comment
EOF
has "${ wf scalar.yml; }" "RUNSON|1|ubuntu-26.04 # not-the-label" \
    "a QUOTED runs-on keeps its whole value — reducing it to the approved label is the #262 drift"
has "${ wf scalar.yml; }" "NAME|1|Build" \
    "an UNQUOTED name drops its trailing comment — keeping it requires a context nothing reports"
has "${ wf scalar.yml; }" "NAME|2|quoted # kept" "a quoted name keeps a # inside the quotes"
has "${ wf scalar.yml; }" "RUNSON|2|ubuntu-26.04" "an unquoted runs-on drops its trailing comment"

# EVERY METADATA FLAG, since the two consumers read them in opposite directions and a flag that
# stops being emitted is silently benign to one of them.
cat > "$wfd/flags.yml" <<'EOF'
on:
  pull_request:
jobs:
  plain:
    runs-on: ubuntu-26.04
  conditional:
    if: github.event_name == 'push'
    runs-on: ubuntu-26.04
  reusable:
    uses: ./.github/workflows/other.yml
  matrixed:
    strategy:
      matrix:
        os: [a, b]
    runs-on: ${{ matrix.os }}
  bare-strategy:
    strategy:
      fail-fast: false
    runs-on: ubuntu-26.04
  inline-strat:
    strategy: {matrix: {os: [a]}}
    runs-on: ubuntu-26.04
  dyn:
    name: n-${{ github.event_name }}
    runs-on: ubuntu-26.04
  "quoted-key":
    runs-on: ubuntu-26.04
  hidden: {runs-on: ubuntu-26.04, steps: [x]}
EOF
has "${ wf flags.yml; }" "FLAG|2|if"       "a job-level if: is flagged"
has "${ wf flags.yml; }" "FLAG|3|uses"     "a reusable-workflow job is flagged"
has "${ wf flags.yml; }" "FLAG|4|matrix"   "a block-form strategy.matrix is flagged"
hasnt "${ wf flags.yml; }" "FLAG|5|matrix" "a bare strategy: without matrix is NOT flagged"
has "${ wf flags.yml; }" "FLAG|6|matrix"   "an inline 'strategy: {matrix: …}' is flagged"
has "${ wf flags.yml; }" "FLAG|7|dynamic"  "a name: carrying \${{ }} is flagged"
has "${ wf flags.yml; }" "JOB|8|quoted-key" "a QUOTED job id is a visible job, unquoted"
has "${ wf flags.yml; }" "FLAG|9|inline"   "an inline flow-mapping job is a visible job, flagged"
eq  "${ adb_wf_jobs "$wfd/flags.yml" | grep -c '^JOB	'; }" "9" "every job is enumerated, none skipped"

# THE `on:` FALSE POSITIVE that scoping exists to prevent: `push:`/`pull_request:` sit at the SAME
# indent as job keys, so a whole-file scan harvests them as jobs and requires contexts that can
# never report. This repo's own ci.yml is that shape.
cat > "$wfd/onshape.yml" <<'EOF'
on:
  push:
  pull_request:
jobs:
  real:
    runs-on: ubuntu-26.04
EOF
eq "${ adb_wf_jobs "$wfd/onshape.yml" | grep -c '^JOB	'; }" "1" \
   "a trigger at job-key indent is never enumerated as a job"

# THE `on:` FILTER VOCABULARY, each of which is a verdict input in repo-settings.sh.
printf 'on: [push, pull_request]\njobs:\n  a:\n' > "$wfd/flowseq.yml"
has "${ wfon flowseq.yml; }" "TRIGGER|pull_request" "an inline flow-sequence 'on:' is read"
printf 'on: pull_request\njobs:\n  a:\n' > "$wfd/inlinescalar.yml"
has "${ wfon inlinescalar.yml; }" "TRIGGER|pull_request" "an inline scalar 'on:' is read"
printf 'on:\n  pull_request: {types: [closed]}\njobs:\n  a:\n' > "$wfd/inlinemap.yml"
has "${ wfon inlinemap.yml; }" "PRINLINEFILTER|pull_request" "an inline flow-MAPPING filter is reported, not silently dropped"
printf 'on:\n  pull_request:\n    paths-ignore:\n      - docs/**\njobs:\n  a:\n' > "$wfd/pi.yml"
has "${ wfon pi.yml; }" "PRFILTER|paths" "paths-ignore reports as the paths filter"
printf 'on:\n  pull_request:\n    branches-ignore:\n      - dev\njobs:\n  a:\n' > "$wfd/bi.yml"
has "${ wfon bi.yml; }" "PRFILTER|branches-ignore" "branches-ignore is its own filter"

# STRUCTURAL ABSENCE is a REPORTED fact, not an empty result — this is what lets a consumer tell
# "no jobs here" apart from "this parser went blind", the distinction #102 is entirely about.
printf 'name: x\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/noon.yml"
has "${ wfon noon.yml; }" "ONBLOCK|0" "a file with no on: block says so"
printf 'on:\n  pull_request:\n' > "$wfd/nojobs.yml"
has "${ wf nojobs.yml; }" "JOBSBLOCK|0" "a file with no jobs: block says so"
printf 'on:\n  pull_request:\njobs:\n' > "$wfd/emptyjobs.yml"
has "${ wf emptyjobs.yml; }" "JOBSBLOCK|1" "a file WITH a jobs: block says so..."
eq "${ adb_wf_jobs "$wfd/emptyjobs.yml" | grep -c '^JOB	'; }" "0" "...and yields no jobs — the pair a consumer must fail loud on"

# A SEQUENCE AT ITS KEY'S OWN COLUMN is valid YAML that GitHub runs. Handled here rather than in a
# consumer: a floor lint that cannot see a job's steps reports that job unguarded, so this spelling
# would turn a legitimate workflow red for a reason its author could not act on.
printf 'on:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-26.04\n    steps:\n    - name: one\n      run: x\n    - name: two\n      run: y\n' > "$wfd/seqflat.yml"
eq "${ adb_wf_jobs "$wfd/seqflat.yml" | grep -c '^STEP	'; }" "2" \
   "steps written at their key's own column are still counted"

# COMMENTS AND BLANKS never set a block's child column. An indented comment as the first line
# inside a block would otherwise define the indent for everything under it.
printf 'on:\n  # a comment first\n  pull_request:\njobs:\n\n      # deeply indented comment\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/comments.yml"
has "${ wfon comments.yml; }" "TRIGGER|pull_request" "a comment before the first trigger does not set the trigger column"
has "${ wf comments.yml; }"   "JOB|1|a"              "a blank line and an over-indented comment do not set the job column"

# CRLF: a workflow authored on Windows is one GitHub runs, and a stray \r riding inside every
# scalar turns a valid label into one that matches no allowlist entry.
printf 'on:\r\n  pull_request:\r\njobs:\r\n  a:\r\n    runs-on: ubuntu-26.04\r\n' > "$wfd/crlf.yml"
has "${ wf crlf.yml; }" "RUNSON|1|ubuntu-26.04" "a CRLF workflow yields clean scalars"

# ARGUMENT VALIDATION and the FAIL-CLOSED completion marker. The dangerous answer from this reader
# is EMPTY — it reads as a legitimately jobless file, which is #102 in production.
adb_wf_jobs >/dev/null 2>&1;            eq "$?" 1 "no argument is a failure, not an empty scan"
adb_wf_jobs /nonexistent >/dev/null 2>&1; eq "$?" 1 "an unreadable file is a failure, not an empty scan"
_adb_wf_read bogus /dev/null >/dev/null 2>&1; eq "$?" 2 "an unknown mode is rejected (2)"
wfstub="$(mktemp -d)"
printf '#!/bin/sh\nprintf "JOB\\t1\\ta\\n"\nexit 0\n' > "$wfstub/awk"; chmod +x "$wfstub/awk"
( PATH="$wfstub:$PATH"; adb_wf_jobs "$wfd/two.yml" >/dev/null 2>&1 ); eq "$?" 1 \
   "a TRUNCATED run (exit 0, plausible records, no completion marker) is a FAILURE"
printf '#!/bin/sh\nexit 9\n' > "$wfstub/awk"
( PATH="$wfstub:$PATH"; adb_wf_jobs "$wfd/two.yml" >/dev/null 2>&1 ); eq "$?" 1 \
   "...and so is a hard awk failure"
printf '#!/bin/sh\nprintf "\\001ADB_WF_OK\\n"\nexit 0\n' > "$wfstub/awk"
( PATH="$wfstub:$PATH"; adb_wf_jobs "$wfd/two.yml" >/dev/null 2>&1 ); eq "$?" 1 \
   "a stub emitting the FIXED marker text is rejected — the trailer is nonced per invocation"
# --- the YAML forms independent review found the first cut could not read -----
# Every one of these is valid YAML that GitHub runs, and every one was previously either invisible
# or — worse — turned into a required context that nothing reports.

# ANCHORS AND ALIASES. GitHub documents anchoring a whole job configuration. `build: &base_job` puts
# a value on the job-key line, and classifying any such value as an inline mapping made discovery
# skip a perfectly readable job while the floor lint replaced its real runner with `<inline
# mapping>` and failed a valid workflow. An ALIAS is genuinely unreadable — the configuration lives
# at the anchor — so it stays flagged.
cat > "$wfd/anchor.yml" <<'EOF'
on:
  pull_request:
jobs:
  build: &base_job
    name: Build
    runs-on: ubuntu-26.04
  alt-build: *base_job
EOF
has "${ wf anchor.yml; }" "RUNSON|1|ubuntu-26.04" "an ANCHORED job is read normally (its properties still follow below)"
has "${ wf anchor.yml; }" "NAME|1|Build"          "...including its name"
hasnt "${ wf anchor.yml; }" "FLAG|1|inline"       "...and it is NOT mistaken for an inline mapping"
has "${ wf anchor.yml; }" "FLAG|2|alias"          "an ALIAS is flagged — its configuration is not under this key"

# AN INLINE FLOW MAPPING WITH NO `name:` has a provable context: the job key. Skipping it left valid
# PR CI ungated, which is the opposite error from a phantom context and just as real.
printf 'on:\n  pull_request:\njobs:\n  plain: {runs-on: ubuntu-26.04}\n  named: {runs-on: ubuntu-26.04, name: Real Name}\n' > "$wfd/inline.yml"
has "${ wf inline.yml; }" "FLAG|1|inline"   "an inline mapping is flagged for the floor lint either way"
has "${ wf inline.yml; }" "FLAG|1|keyed"    "...and one whose key is PROVABLY the context says so"
hasnt "${ wf inline.yml; }" "FLAG|2|keyed"  "...while one carrying a name: does not"

# BLOCK AND FOLDED SCALARS. `name: >-` puts the text on the FOLLOWING lines, and emitting the header
# produced the required context `>-` — a phantom that never reports and needs an admin token to
# clear. Reported unreadable instead, which under-requires, the recoverable direction.
printf 'on:\n  pull_request:\njobs:\n  a:\n    name: >-\n      Build and test\n    runs-on: ubuntu-26.04\n' > "$wfd/block.yml"
has "${ wf block.yml; }" "FLAG|1|blockname" "a folded-scalar name: is reported unreadable"
hasnt "${ wf block.yml; }" "NAME|1|>-"      "...and its HEADER is never emitted as the name"

# QUOTED-SCALAR ESCAPES, both styles. Truncating at the first inner quote invents a context.
printf 'on:\n  pull_request:\njobs:\n  a:\n    name: "Build \\"quoted\\""\n  b:\n    name: '"'"'it'"'"''"'"'s here'"'"'\n' > "$wfd/esc.yml"
has "${ wf esc.yml; }" 'NAME|1|Build "quoted"' "a backslash-escaped quote inside a double-quoted name survives"
has "${ wf esc.yml; }" "NAME|2|it's here"      "a doubled single quote inside a single-quoted name survives"

# BLOCK SEQUENCES, at BOTH spellings, for `on:` and for a filter. The dash form is not a mapping
# key, so a reader that only accepts keys reported "no pull_request trigger" on a workflow that runs
# on every PR — #102's failure in a different costume.
printf 'on:\n  - push\n  - pull_request\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/seq1.yml"
has "${ wfon seq1.yml; }" "TRIGGER|pull_request" "an INDENTED block-sequence 'on:' is read"
printf 'on:\n- push\n- pull_request\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/seq2.yml"
has "${ wfon seq2.yml; }" "TRIGGER|pull_request" "an INDENTATIONLESS block-sequence 'on:' is read"
printf 'on:\n  pull_request:\n    branches:\n    - main\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/seq3.yml"
has "${ wfon seq3.yml; }" "PRBRANCH|main" "a branches: sequence at its key's OWN column is read"
printf 'on:\n  pull_request:\n    types:\n    - opened\n    - synchronize\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/seq4.yml"
has "${ wfon seq4.yml; }" "PRTYPE|synchronize" "a types: sequence at its key's OWN column is read"

# THE INLINE-MAPPING KEY TEST IS DEPTH-AWARE, not a substring search. `environment: {name: …}` is
# the common nesting, so a substring test suppressed `keyed` for an ordinary deploy job and left a
# real PR job ungated. And `keyed` means the key is PROVABLY the context, so `if:`/`uses:`/
# `strategy:` disqualify it too — requiring one of those under its key is a phantom context that
# never reports, which is the deadlock, not the recoverable direction.
printf 'on:\n  pull_request:\njobs:\n  deploy: {runs-on: ubuntu-26.04, environment: {name: production}, steps: [x]}\n' > "$wfd/nested.yml"
has "${ wf nested.yml; }" "FLAG|1|keyed" "a NESTED name: does not suppress keyed — the context is still the job key"
printf 'on:\n  pull_request:\njobs:\n  a: {runs-on: x, name: Real, steps: [y]}\n  b: {runs-on: x, "name": Q, steps: [y]}\n' > "$wfd/topname.yml"
hasnt "${ wf topname.yml; }" "FLAG|1|keyed" "a TOP-LEVEL name: does suppress it"
hasnt "${ wf topname.yml; }" "FLAG|2|keyed" "...including a QUOTED top-level name:"
printf 'on:\n  pull_request:\njobs:\n  a: {runs-on: x, if: false, steps: [y]}\n  b: {runs-on: x, strategy: {matrix: {os: [p]}}, steps: [y]}\n  c: {uses: ./.github/workflows/o.yml}\n  d: {runs-on: x, steps: [y]}\n' > "$wfd/inlmeta.yml"
hasnt "${ wf inlmeta.yml; }" "FLAG|1|keyed" "an inline job carrying if: is not keyed"
hasnt "${ wf inlmeta.yml; }" "FLAG|2|keyed" "an inline job carrying strategy: is not keyed"
hasnt "${ wf inlmeta.yml; }" "FLAG|3|keyed" "an inline job carrying uses: is not keyed"
has   "${ wf inlmeta.yml; }" "FLAG|4|keyed" "...while a plain inline job still is"

# A FLOW SEQUENCE SPLIT ON QUOTE-AWARE COMMAS. A branch pattern may contain a comma; splitting
# blindly yields two malformed values and the real branch reads as excluded.
printf 'on:\n  pull_request:\n    branches: ["release,stable", main]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/comma.yml"
has "${ wfon comma.yml; }" "PRBRANCH|release,stable" "a comma INSIDE a quoted flow entry does not split it"
has "${ wfon comma.yml; }" "PRBRANCH|main"           "...and the following entry is still read"

# --- FLOW COLLECTIONS THAT SPAN PHYSICAL LINES (#291) -------------------------
# Valid YAML that GitHub runs, previously read from the OPENING LINE ONLY. Each of these was
# silently mis-answered rather than reported, so each gets a direct contract assertion here on top
# of the consumer-verdict assertions in check-repo-settings.sh / check-bash-floor-guard.sh.

# THE HEADLINE CASE. `branches:` yielded `PRFILTER branches` with NO `PRBRANCH`, so discovery
# concluded the filter "does not provably include main" and dropped every job in the file.
printf 'on:\n  pull_request:\n    branches: [\n      main\n    ]\n    types: [\n      opened,\n      synchronize\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlflow.yml"
has "${ wfon mlflow.yml; }" "PRBRANCH|main" "a branches: flow sequence spanning lines yields its entries"
has "${ wfon mlflow.yml; }" "PRTYPE|opened" "...and so does a types: one"
has "${ wfon mlflow.yml; }" "PRTYPE|synchronize" "...including an entry on its own line"
# THE SIBLING FILTER AFTER IT still reads.
#
# THIS DOES NOT PIN `m = WFFLOWEND` and does not claim to — review found the original wording
# ("the scan resumes past the ]") vacuous for that, because the filter loop skips the interior lines
# on indent anyway and would reach `types:` with or without the advance. What the advance actually
# prevents needs an interior line AT THE FILTER COLUMN that parses as a key, which is the fixture
# below this one.
eq "${ adb_wf_on "$wfd/mlflow.yml" | grep -c '^PRFILTER	'; }" "2" \
   "a filter written AFTER a multi-line one is still reached"

# `m = WFFLOWEND` PINNED PROPERLY. A line inside the collection that sits at the filter column and
# looks like a key is read as a SECOND filter unless the loop is advanced past the collection it
# just consumed — inventing a `types:` filter that the workflow does not have, which narrows the
# file's verdict on evidence that is really the interior of a branches: list.
printf 'on:\n  pull_request:\n    branches: [\n    types: x\n    ]\n    paths: [z]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mladvance.yml"
hasnt "${ wfon mladvance.yml; }" "PRFILTER|types" "a key-shaped line INSIDE a flow collection is not read as a filter"
has   "${ wfon mladvance.yml; }" "PRFILTER|paths" "...and the real filter after the collection still is"

# THE TOP-LEVEL `on:` FLOW SEQUENCE, whose closing bracket sits at COLUMN 0 — the case a
# block-scoped bound cannot contain, because adb_wf_blockend ends the block at exactly such a line.
printf 'on: [\n  push,\n  pull_request\n]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlon.yml"
has "${ wfon mlon.yml; }" "TRIGGER|push"         "a top-level 'on: [' spanning lines is read"
has "${ wfon mlon.yml; }" "TRIGGER|pull_request" "...including the entry that closes it"

# AN INLINE FLOW MAPPING FILTER spanning lines. This one fails in the OVER-requiring direction:
# no filter word on the opening line meant no PRINLINEFILTER and a `continue` past the block form,
# so the trigger read as unfiltered and every job in the file was REQUIRED.
printf 'on:\n  pull_request: {\n    types: [closed]\n  }\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlmap.yml"
has "${ wfon mlmap.yml; }" "PRINLINEFILTER|pull_request" \
    "an inline flow-MAPPING filter spanning lines is reported (unreported, it read as unfiltered)"

# QUOTING AND COMMENTS SURVIVE THE JOIN, in both directions. A comma inside quotes must not split,
# and a `#` must open a comment only where YAML says it does — unquoted and after whitespace.
printf 'on:\n  pull_request:\n    branches: [\n      "release,stable",   # the paired branch\n      "has#hash"\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlquote.yml"
has "${ wfon mlquote.yml; }" "PRBRANCH|release,stable" "a quoted comma still does not split an entry across lines"
has "${ wfon mlquote.yml; }" "PRBRANCH|has#hash"       "a quoted # is kept, not read as a comment"
# MATCHED ON THE COMMENT'S OWN WORDS, not on `PRBRANCH|the`. Review found the latter vacuous:
# without comment detection the emitted record is `PRBRANCH|# the paired branch`, so the `# ` sits
# between the tag and `the` and the substring never matches. The text itself is what must be absent.
hasnt "${ wfon mlquote.yml; }" "paired"                "an end-of-line comment inside the collection is dropped"

# AN UNCLOSED COLLECTION MUST EMIT NOTHING EXTRA, and this is the assertion that makes the join
# safe rather than merely useful. A PARTIAL join is worse than none: half a branches: list reads as
# a filter naming some branches and not the target, which is indistinguishable from one that
# genuinely excludes it. Refusing keeps the malformed file on the behaviour it already had.
printf 'on:\n  pull_request:\n    branches: [\n      main\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlopen.yml"
has   "${ wfon mlopen.yml; }" "PRFILTER|branches" "an UNCLOSED flow sequence still reports the filter..."
hasnt "${ wfon mlopen.yml; }" "PRBRANCH|main"     "...and emits no entries at all — never a partial list"

# A JOB VALUE OPENING A FLOW MAPPING is joined in the ENUMERATION loop, which is what both fixes
# below depend on. `keyed` means the check context PROVABLY is the job key, and answering that from
# an opening brace said "no top-level name:" about a mapping whose very next line carries one.
printf 'on:\n  pull_request:\njobs:\n  named: {\n    name: Real Name,\n    runs-on: ubuntu-26.04\n  }\n  plain: {\n    runs-on: ubuntu-26.04,\n    steps: [x]\n  }\n' > "$wfd/mljob.yml"
has   "${ wf mljob.yml; }" "FLAG|1|inline" "a multi-line inline job mapping is still a visible, flagged job"
hasnt "${ wf mljob.yml; }" "FLAG|1|keyed"  "...and one carrying a name: on a LATER line is NOT keyed (it used to be)"
has   "${ wf mljob.yml; }" "FLAG|2|keyed"  "...while one that really has no name: still is"
# AND ITS INTERIOR IS NOT DECOMPOSED. The block-property arms used to run over the flow body and
# emit `Real Name,` / `ubuntu-26.04,` — flow-syntax fragments — as a check name and a runner label.
hasnt "${ wf mljob.yml; }" "NAME|1|"   "no NAME record is scraped out of the flow body"
hasnt "${ wf mljob.yml; }" "RUNSON|2|" "no RUNSON record is either"

# A CONTINUATION LINE AT THE JOB COLUMN IS NOT A SECOND JOB. The flow body belongs to the job that
# opened it, so enumeration resumes after the closing brace.
printf 'on:\n  pull_request:\njobs:\n  wide: {\n  runs-on: ubuntu-26.04\n  }\n  real:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlwide.yml"
eq "${ adb_wf_jobs "$wfd/mlwide.yml" | grep -c '^JOB	'; }" "2" \
   "a flow-mapping body at the job column yields TWO jobs, not a phantom third named runs-on"
has "${ wf mlwide.yml; }" "JOB|2|real" "...and the job after it is still enumerated"

# --- MERGE KEYS ARE REPORTED, NEVER RESOLVED (#291) ---------------------------
# GitHub Actions implements YAML 1.2, which has no merge key, so a workflow carrying `<<:` is a
# syntax error there and never runs. RESOLVING it would be the worse bug: the job would gain a
# readable name: and no disqualifier, so discovery would confidently require a context from a file
# that cannot report. Flagged instead, so each consumer refuses it in its own direction.
printf 'on:\n  pull_request:\njobs:\n  base: &base\n    name: Base Name\n    runs-on: ubuntu-26.04\n  alt:\n    <<: *base\n    steps:\n      - run: x\n' > "$wfd/mergekey.yml"
has   "${ wf mergekey.yml; }" "FLAG|2|merge" "a job merging a <<: key is flagged"
hasnt "${ wf mergekey.yml; }" "NAME|2|"      "...and NOTHING is inherited from the anchor — not the name"
hasnt "${ wf mergekey.yml; }" "RUNSON|2|"    "...nor the runner"
has   "${ wf mergekey.yml; }" "NAME|1|Base Name" "the ANCHOR job itself is unaffected and still reads normally"
hasnt "${ wf mergekey.yml; }" "FLAG|1|merge"     "...and is not flagged for carrying the anchor"
# A job that merges AND declares its own properties still reports them: the flag says the file will
# not run, not that this reader stopped reading.
printf 'on:\n  pull_request:\njobs:\n  base: &base\n    runs-on: ubuntu-26.04\n  alt:\n    <<: *base\n    runs-on: macos-latest\n' > "$wfd/mergeown.yml"
has "${ wf mergeown.yml; }" "FLAG|2|merge"        "a merging job is flagged even when it also declares its own keys"
has "${ wf mergeown.yml; }" "RUNSON|2|macos-latest" "...and its OWN runs-on is still read"
# ONCE PER JOB, so a consumer accumulator never reads two facts about one job. TWO `<<:` KEYS in the
# fixture, because that is what the guard is about: review found the single-key version vacuous —
# removing the `if (!mergek)` deduplication still emits exactly one record when there is only one
# key to emit for. Duplicate keys are invalid YAML, which is precisely why the reader must not
# assume they are absent.
printf 'on:\n  pull_request:\njobs:\n  a:\n    <<: *x\n    <<: *y\n    runs-on: ubuntu-26.04\n' > "$wfd/mergedup.yml"
eq "${ adb_wf_jobs "$wfd/mergedup.yml" | grep -c 'merge'; }" "1" "TWO <<: keys in one job still emit the flag once"
# THE INLINE FLOW SPELLINGS, both of them. Independent review found that the two block arms missed
# these entirely: `alt: {<<: *base, …}` came back `inline` + `keyed` and was required under its key,
# and `pull_request: {<<: *filters}` came back as an ordinary UNFILTERED trigger — which is what
# makes every job in the file required. Depth-aware, via the helper that already existed for exactly
# this question, so a `<<` nested deeper inside the mapping is not mistaken for the mapping's own.
printf 'on:\n  pull_request:\njobs:\n  alt: {<<: *base, runs-on: ubuntu-26.04}\n' > "$wfd/mergeinline.yml"
has "${ wf mergeinline.yml; }" "FLAG|1|merge"  "an INLINE job mapping carrying <<: is flagged"
has "${ wf mergeinline.yml; }" "FLAG|1|inline" "...alongside the inline flag, which is a separate fact"
printf 'on:\n  pull_request: {<<: *filters}\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mergeoninline.yml"
has   "${ wfon mergeoninline.yml; }" "PRFILTER|merge" "an INLINE trigger mapping carrying <<: is reported"
hasnt "${ wfon mergeoninline.yml; }" "PRINLINEFILTER" "...as a merge, not as an ordinary inline filter"

# THE TRIGGER-LEVEL SPELLING, the other place `<<:` is reachable in what this reader looks at.
# Ignored, it left the trigger looking UNFILTERED — which is what makes every job in the file
# required, from a workflow GitHub never runs.
printf 'on:\n  pull_request:\n    <<: *filters\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mergeon.yml"
has "${ wfon mergeon.yml; }" "PRFILTER|merge" "a <<: under pull_request is reported as a filter this reader cannot prove"

# THE FLAG DOES NOT BLEED INTO THE NEXT JOB. It is per-job state in a function-wide variable, so a
# job following a merging one is where a missed reset would show — and it would show as a SKIP of a
# perfectly readable job, which is quiet.
printf 'on:\n  pull_request:\njobs:\n  a:\n    <<: *x\n    runs-on: ubuntu-26.04\n  b:\n    runs-on: ubuntu-26.04\n' > "$wfd/mergeorder.yml"
has   "${ wf mergeorder.yml; }" "FLAG|1|merge" "the merging job is flagged..."
hasnt "${ wf mergeorder.yml; }" "FLAG|2|merge" "...and the job AFTER it is not"

# A CLOSING BRACKET OUTDENTED PAST ITS BLOCK is malformed YAML, and the join must refuse rather than
# reach for it: the bound is the trigger's own block, so this is the shape where "join across lines"
# and "respect the block structure" disagree. Refusing lands on the under-reporting side.
printf 'on:\n  pull_request:\n    branches: [\n      main\n  ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mloutdent.yml"
has   "${ wfon mloutdent.yml; }" "PRFILTER|branches" "an outdented closing bracket still reports the filter..."
hasnt "${ wfon mloutdent.yml; }" "PRBRANCH|main"     "...and invents no entries from a collection it could not close"

# AN ESCAPED LINE BREAK folds to NOTHING, which is YAML's own rule and not the joiner's default.
# `"release\` / `candidate"` is the single scalar `releasecandidate`; joining it with the ordinary
# folding space produced `release\ candidate`, a branch pattern matching nothing — so a filter
# naming that target read as excluding it. Found by independent review, which also noted that the
# "escape-aware" and "same as YAML folding" claims in the docs were false until this was fixed.
printf 'on:\n  pull_request:\n    branches: [\n      "release\\\n      candidate"\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlesc.yml"
has   "${ wfon mlesc.yml; }" "PRBRANCH|releasecandidate" "a backslash-escaped line break inside a quoted scalar folds to nothing"
hasnt "${ wfon mlesc.yml; }" "release\\ candidate"       "...not to the ordinary folding space"
# AND AN ESCAPED BACKSLASH IS NOT AN ESCAPED LINE BREAK. `\\` mid-line is one literal backslash and
# its line break still folds to a space — the distinction a test on the accumulated text (rather
# than on whether a character followed) would get wrong.
printf 'on:\n  pull_request:\n    branches: [\n      "a\\\\",\n      main\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlescbs.yml"
has "${ wfon mlescbs.yml; }" "PRBRANCH|main" "an escaped BACKSLASH at end of entry does not swallow the next line"

# A `#` INSIDE A QUOTE IS CONTENT, INCLUDING AT THE START OF A CONTINUATION LINE. The blank/comment
# skip that walks to the next line is only correct OUTSIDE a quote: `"release\` / `#candidate"` is
# the branch pattern `release#candidate`, and skipping that second line left the scanner still
# inside the quote, so the span never found its closing delimiter and emitted NO entries — the file
# then "did not provably include" the target and every job in it was dropped. That is #291's own
# headline failure, reintroduced by the continuation loop of its fix. Found by the PR reviewer.
printf 'on:\n  pull_request:\n    branches: [\n      "release\\\n      #candidate"\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlhashcont.yml"
has "${ wfon mlhashcont.yml; }" "PRBRANCH|release#candidate" \
    "a continuation line starting with # INSIDE a quote is scalar content, not a comment"
# THE OTHER DIRECTION, so the fix cannot be "stop skipping comments". A genuine comment line inside
# a flow collection — outside any quote — must still be dropped.
printf 'on:\n  pull_request:\n    branches: [\n      main,\n      # a real comment\n      dev\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mlcmtline.yml"
has   "${ wfon mlcmtline.yml; }" "PRBRANCH|main"    "a whole-line comment inside a collection does not stop the scan..."
has   "${ wfon mlcmtline.yml; }" "PRBRANCH|dev"     "...and the entry after it is still read"
hasnt "${ wfon mlcmtline.yml; }" "real comment"     "...while the comment text itself never becomes an entry"

# BYTES, NOT CHARACTERS. The reader runs under LC_ALL=C, so the joiner walks bytes; every delimiter
# it tests for is ASCII and every UTF-8 continuation byte is >= 0x80, so a non-ASCII branch pattern
# can neither be split nor truncated by the scan.
printf 'on:\n  pull_request:\n    branches: [\n      "r\xc3\xa9l\xc3\xa9ase/na\xc3\xafve",\n      main\n    ]\njobs:\n  a:\n    runs-on: ubuntu-26.04\n' > "$wfd/mluni.yml"
has "${ wfon mluni.yml; }" "PRBRANCH|réléase/naïve" "a UTF-8 branch pattern survives the join byte-for-byte"
has "${ wfon mluni.yml; }" "PRBRANCH|main"          "...and the entry after it is still read"

# THE TWO CHANGES TOGETHER, in one file, because each keeps parser state (WFFLOWEND, the joined
# text) that the other could inherit. RANGE and STEP are asserted by LINE NUMBER: the join must
# never renumber, delete, or prejoin WFL, which is what the floor lint's step rules ride on.
cat > "$wfd/mlboth.yml" <<'EOF'
on:
  pull_request:
    branches: [
      main
    ]
jobs:
  base: &base
    name: Base
    runs-on: ubuntu-26.04
    steps:
      - name: v
        run: bash --version
  alt:
    <<: *base
    steps:
      - name: w
        run: echo hi
EOF
has "${ wfon mlboth.yml; }" "PRBRANCH|main" "combined: the multi-line filter above anchored jobs still reads"
has "${ wf mlboth.yml; }"   "RANGE|1|7|12"  "combined: the first job's RANGE is its real physical line span"
has "${ wf mlboth.yml; }"   "RANGE|2|13|17" "combined: and so is the merging job's"
has "${ wf mlboth.yml; }"   "STEP|1|1|11"   "combined: a STEP still points at the physical line it starts on"
has "${ wf mlboth.yml; }"   "FLAG|2|merge"  "combined: the merge flag survives alongside the flow join"

rm -rf "$wfstub" "$wfd"

# THE REAL TREE, cross-checked against an INDEPENDENT counter. Every assertion above runs on a
# fixture this file wrote, so all of them survive a reader that goes PARTIALLY blind on the actual
# workflows — and the two consumers' aggregate rules survive it too (the floor lint fails only on
# a file yielding ZERO jobs; discovery fails only on the same). One real job quietly dropped is
# therefore invisible everywhere, which is the gap this closes.
#
# The counter is deliberately a SECOND METHOD, not a second call: a naive 2-space scan scoped to
# the `jobs:` block, which is exactly what the retired scanners did and is correct for these two
# files because both are uniformly 2-space indented. Agreement between an indent-agnostic reader
# and an indent-pinned one ON A 2-SPACE FILE is a real cross-check; it needs no updating when a CI
# job is added, so it cannot rot into a number nobody trusts.
naive_jobs() {
  awk '/^jobs:[[:space:]]*$/{j=1;next} /^[^[:space:]#]/{j=0} j && /^  [A-Za-z0-9_"-]+:/{n++} END{print n+0}' "$1"
}
for _wf in .github/workflows/*.yml; do
  eq "${ adb_wf_jobs "$_wf" | grep -c '^JOB	'; }" "${ naive_jobs "$_wf"; }" \
     "real tree: the shared reader and an independent 2-space counter agree on $_wf"
done

# --- --mutation: the manifest guards must be OBSERVED failing (#324) ----------------------------
#
# A guard's failure mode is silence: one that scans nothing, matches nothing, or refuses nothing
# prints exactly what a clean run prints. `self-review.md` says to automate the observation wherever
# the rule set is CLOSED — and this one is, because every rule below was added by one change and can
# be enumerated. Without this the "observed red" claim is a sentence in a PR body that no later
# reader can re-run, which is the difference between a standing test and "I checked once".
#
# EACH MUTATION MUST GO RED ON ITS OWN NAMED WITNESS, not merely make the suite non-zero. D63 records
# why: any incidental failure — a syntax error, a missing fixture, an aborted start — also returns
# non-zero, satisfies a bare `rc != 0`, and reports a guard as observed while the rule it covers was
# never reached. Matching the witness text is what makes red-for-the-right-reason checkable.
#
# AND EVERY MUTATION VERIFIES ITS OWN EDIT APPLIED. This is not defensive padding: while building
# these by hand, one `perl` pattern silently failed to match, the suite came back 733/0, and a green
# run was momentarily indistinguishable from a guard that could not fire — the exact confusion this
# whole mode exists to remove.
#
# Runs against a COPY of the tree, never the live one (`self-review.md`'s negative-testing rule).
if [ "${1:-}" = "--mutation" ]; then
  mut_pass=0; mut_fail=0
  mut_root="$(mktemp -d)"
  trap 'rm -rf "$work" "$mut_root"' EXIT
  check_copy_worktree "$PWD" "$mut_root/t" || { echo "check-common-lib --mutation: could not copy the tree" >&2; exit 1; }
  mut_lib="$mut_root/t/scripts/lib/common.sh"
  cp "$mut_lib" "$mut_root/pristine.sh"

  # mutate <name> <witness-substring> <gone-substring> <sed-script>
  #   Always rendered FROM THE PRISTINE COPY, so no mutation can inherit another's edit and no
  #   in-place `sed -i` is needed (its spelling differs between GNU and BSD, and this suite runs on
  #   both runners — D29).
  #   THE APPLIED-CHECK IS TWO TESTS, and the first is universal. `cmp` against the pristine copy
  #   catches the failure mode that actually bit: a `sed` script whose pattern silently matches
  #   nothing produces a byte-identical file, the suite comes back green, and the mutation reports
  #   itself observed while the rule it covers was never touched. <gone-substring> adds specificity
  #   where a single line genuinely disappears — checked with `grep -F`, so a pattern character in
  #   it cannot quietly widen the match — and is passed EMPTY for a mutation that only rewrites a
  #   line in place, where `cmp` is the honest check and inventing a gone-string would be theatre.
  #
  # `mutate` RECORDS; `_cl_mut_one` executes, one mutation per BOUNDED-POOL worker (#335). It ran
  # them one at a time against a SHARED tree copy, rewriting one `common.sh` in place — which is
  # exactly why it had to be serial, and why adding six rows to it took the step from 323s to 596s
  # and made it `selfcheck`'s critical path. Each mutation now owns its own copy, which is what its
  # two sibling harnesses (`check-adopt.sh`, `check-adopt-readiness.sh`) already do and the only
  # thing that made them poolable. Every `mutate` call below is unchanged.
  MUT_NAME=(); MUT_WIT=(); MUT_GONE=(); MUT_SED=()
  mutate() { MUT_NAME+=("$1"); MUT_WIT+=("$2"); MUT_GONE+=("$3"); MUT_SED+=("$4"); }

  # One mutation, start to verdict. The verdict travels through a FILE because this runs in a
  # background subshell and a counter incremented there dies with it.
  _cl_mut_one() {   # <index>
    local i="$1" copy lib out src
    copy="$mut_root/t$i"
    # Copied from the already-`.git`-free pristine tree rather than re-copying the working tree, so
    # each worker pays for 7 MB and not for the repository's history.
    if ! { mkdir -p "$copy" && ( cd "$mut_root/t" && cp -R . "$copy" ); } >/dev/null 2>&1; then
      printf 'bad|could not copy the tree\n' > "$mut_root/v$i" 2>/dev/null; return 0
    fi
    lib="$copy/scripts/lib/common.sh"
    sed "${MUT_SED[$i]}" "$mut_root/pristine.sh" > "$lib"
    if cmp -s "$mut_root/pristine.sh" "$lib"; then
      printf 'bad|DID NOT APPLY (file byte-identical to pristine) — its green proves nothing\n' > "$mut_root/v$i"
      return 0
    fi
    if [ -n "${MUT_GONE[$i]}" ] && grep -qF -- "${MUT_GONE[$i]}" "$lib"; then
      printf 'bad|DID NOT APPLY (still found: %s) — its green proves nothing\n' "${MUT_GONE[$i]}" > "$mut_root/v$i"
      return 0
    fi
    # THE STATUS AND THE WITNESS, both — the same rule `check-adopt-readiness.sh` carries, and it is
    # here because this harness had the identical hole: matching the child's `FAIL:` STRING while
    # discarding its exit code accepts a child that prints the expected line and then ABORTS (a
    # `set -u` error, a missing fixture, exit 2), recording `ok` for a rule that was never reached.
    # Require exactly 1: that is what a failed ASSERTION exits, while a crash or a usage error
    # exits something else, and those are the suite dying rather than the guard firing.
    out="$( (cd "$copy" && bash scripts/check-common-lib.sh 2>&1) )"; src=$?
    case "$src" in
      1)
        case "$out" in
          *"FAIL: ${MUT_WIT[$i]}"*) printf 'ok|\n' > "$mut_root/v$i" ;;
          *FAIL:*) printf 'bad|went red, but NOT on its witness: %s\n' "${MUT_WIT[$i]}" > "$mut_root/v$i" ;;
          *) printf 'bad|exited 1 with no FAIL: line at all — it aborted, it did not fail an assertion\n' > "$mut_root/v$i" ;;
        esac ;;
      0) printf 'bad|stayed GREEN (exit 0) — the guard cannot fail\n' > "$mut_root/v$i" ;;
      *) printf 'bad|exited %s, not 1 — the suite ABORTED rather than failing its assertion\n' "$src" > "$mut_root/v$i" ;;
    esac
    # A worker's own status stays 0 whatever it decided: the pool reaps exactly one job per
    # `wait -n`, and the verdict travels in the file.
    return 0
  }

  # 1. The producer's precondition is deleted from every branch → it stops refusing at all.
  mutate producer-guard-deleted \
    "manifest: the claude branch refuses an unrepresentable home" \
    '_adb_manifest_fields_safe "$repo" "$home"' \
    '/_adb_manifest_fields_safe "\$repo" "\$home"/d'

  # 2. THE DECISIVE ONE. The pre-write pass still runs, still diagnoses, still returns non-zero — it
  #    just no longer BLOCKS the write, so the good records ahead of the bad one get linked anyway.
  #    This is the shape a naive fix has, and the STATUS assertion stays green under it; only the
  #    filesystem assertions can catch it. If this mutation ever stops going red, the suite has
  #    quietly reverted to proving nothing more than "returns non-zero".
  mutate prewrite-pass-does-not-block \
    "adb_link_manifest must not replace a real directory before refusing" \
    'adb_link_manifest)" || return 1' \
    '/_adb_manifest_slurp adb_link_manifest/s/|| return 1/|| rc=1/'

  # 3. Exact delimiter counting is removed, leaving the folded-IFS parse that cannot see an adjacent
  #    or trailing delimiter.
  mutate exact-delimiter-count-removed \
    "adb_link_manifest rejects record shape 1" \
    '*"$tab"*"$tab"*) : ;;' \
    '/\*"\$tab"\*"\$tab"\*) : ;;/d'

  # 4. The remove side stops acting on its own validation.
  mutate unlink-side-status-ignored \
    "adb_unlink_manifest refuses a manifest containing a malformed record" \
    'adb_unlink_manifest)" || return 1' \
    '/_adb_manifest_slurp adb_unlink_manifest/s/ || return 1//'

  # 5. The filesystem-controlled half of the precondition is dropped.
  mutate skill-name-check-removed \
    "manifest: an unrepresentable SKILL directory name is refused" \
    'for d in "$skills"/*/; do' \
    '/for d in "\$skills"\/\*\/; do/,/^  done$/d'

  # 6. The per-branch boundary is broken: an unknown token now shares the claude branch, so it
  #    inherits a precondition the documented contract says must not apply to it.
  mutate precondition-not-per-branch \
    "manifest: an unknown agent still returns 0 even with an unsafe home" \
    '    claude)' \
    's/^    claude)$/    claude|*)/'

  # 7. The per-value contract collapses to first-failure-wins, so an operator with BOTH roots wrong
  #    is told about only one, fixes it, re-runs, and is told about the other.
  mutate per-value-diagnostic-collapsed \
    "manifest: TWO unsafe roots yield one line each, not one combined line" \
    "" \
    '/the source root contains/,/^  fi$/s/^    rc=1$/    return 1/'

  # 8. The diagnostic loses its terminator — invisible to any guard that captures stderr through
  #    `$(…)`, which strips every trailing newline. This is why (b) captures to a FILE.
  mutate diagnostic-newline-dropped \
    "manifest: the diagnostic line is newline-terminated" \
    "the target home contains a tab or newline, which the install manifest cannot represent: %s\\n" \
    '/the target home contains/s/%s\\n/%s/'

  # --- the pool-sizing primitive (#335) --------------------------------------------------------
  # Its failure mode is a SMALLER NUMBER, which passes every functional test its callers have: a
  # pool of one produces byte-identical output to a pool of eight and merely takes minutes longer.
  # So the cases worth injecting are the ones where the answer silently shrinks, silently stops
  # being honoured, or stops being a usable integer at all.

  # 9. THE DECISIVE ONE. `ADB_POOL_JOBS` is ignored, so `adb_pool_size` always answers from the cpu
  #    probe and the documented override silently does nothing. That override is the only way an
  #    operator on a shared or throttled machine can ask these harnesses for a smaller pool, and a
  #    green run looks identical whether it is honoured or not. (It is NOT about `selfcheck`
  #    handing down slices — that design was reverted and nothing exports the variable today.)
  mutate budget-not-honoured \
    "adb_pool_size: a budget REPLACES the probe" \
    'n="$(_adb_pos_int "${ADB_POOL_JOBS:-}")" || n="$(adb_cpu_count)"' \
    '/_adb_pos_int "\${ADB_POOL_JOBS:-}"/s/.*/  n="$(adb_cpu_count)"/'

  # 10. The cap stops applying — the direction that oversubscribes rather than serializes, and the
  #     one a caller passing an explicit cap is relying on.
  mutate cap-not-applied \
    "adb_pool_size: the default cap is 8" \
    '[ "$n" -le "$cap" ] || n="$cap"' \
    '/\[ "\$n" -le "\$cap" \] || n="\$cap"/d'

  # 11. A malformed budget collapses to 1 instead of falling back to the probe: one typo in an
  #     environment variable serializes every pool on the machine, quietly.
  mutate malformed-budget-becomes-one \
    "adb_pool_size: a malformed budget falls back to the probe, NOT to 1" \
    "" \
    '/_adb_pos_int "\${ADB_POOL_JOBS:-}"/s/|| n="\$(adb_cpu_count)"/|| n=1/'

  # 12. Leading zeros stop being stripped, so `012` is returned verbatim — decimal 12 to `[`,
  #     octal 10 to `$(( ))`, and a nonsense `pool=012` in the log.
  mutate zero-padding-not-normalized \
    "adb_cpu_count: a zero-padded count is decimal 12, not octal 10" \
    'while [ "${v#0}" != "$v" ] && [ -n "${v#0}" ]; do v="${v#0}"; done' \
    '/while \[ "\${v#0}" != "\$v" \]/d'

  # 13. The probe stops falling back to 1 on unusable output, so a caller receives the EMPTY string
  #     as a loop bound — not slow, but a syntax error at the call site.
  mutate probe-failure-returns-empty \
    "adb_cpu_count: unusable output falls back to 1, never to empty" \
    'n="$(_adb_pos_int "$n")" || n=1' \
    '/n="\$(_adb_pos_int "\$n")" || n=1/s/ || n=1//'

  # 14. The arithmetic-range check is dropped, so an over-large value reaches `[ … -le … ]` and
  #     that comparison ERRORS instead of returning false. The number a caller gets is still
  #     right — the damage is a diagnostic on stderr that reads like a broken check, which is
  #     exactly the shape no assertion about the return value can see.
  mutate arithmetic-range-unchecked \
    "adb_pool_size stays SILENT on an over-large budget" \
    '[ "${#v}" -le 9 ] || return 1' \
    '/\[ "\${#v}" -le 9 \] || return 1/d'

  # --- run them, bounded ------------------------------------------------------------------------
  # `adb_pool_size` is the one home for the width (scripts/lib/common.sh): min(cpu, 8), so it
  # right-sizes per machine rather than being a constant chosen on one. `wait -n` alone, with no
  # `|| wait` behind it — that fallback drains every child while decrementing once, which is a
  # silent degrade to serial.
  mut_pool="$(adb_pool_size 8)"; mut_i=0; mut_running=0; mut_n="${#MUT_NAME[@]}"
  [ "$mut_n" -gt 0 ] || { echo "check-common-lib --mutation: the mutation table is EMPTY — this harness proves nothing" >&2; exit 1; }
  while [ "$mut_i" -lt "$mut_n" ]; do
    _cl_mut_one "$mut_i" &
    mut_running=$((mut_running + 1)); mut_i=$((mut_i + 1))
    if [ "$mut_running" -ge "$mut_pool" ]; then wait -n; mut_running=$((mut_running - 1)); fi
  done
  wait

  # THE PARENT SCORES, over every index — so a worker that died without writing a verdict is a
  # FAILURE rather than a silently missing row.
  #
  # `for ((…))`, NOT `$(seq …)`, and that is a correctness fix rather than a style preference. A
  # missing `seq` makes the substitution empty, the loop body runs ZERO times, `mut_fail` stays 0,
  # and the harness prints PASS having examined no verdict at all — a false green in the one place
  # whose entire job is to make false greens impossible. Bash arithmetic has no such dependency,
  # and it is what `check-adopt.sh`'s sibling loop already uses.
  for (( mut_i = 0; mut_i < mut_n; mut_i++ )); do
    mut_v="$(cat "$mut_root/v$mut_i" 2>/dev/null || echo 'bad|produced NO verdict — its worker died without reporting')"
    case "$mut_v" in
      ok\|*) mut_pass=$((mut_pass + 1)) ;;
      *) mut_fail=$((mut_fail + 1))
         printf 'FAIL: mutation %s %s\n' "${MUT_NAME[$mut_i]}" "${mut_v#*|}" >&2 ;;
    esac
  done

  # AND THE SCOREBOARD MUST COVER THE TABLE. Every path above that can skip rows — a loop that
  # iterated zero times, an early `continue`, a future refactor — is invisible in `mut_fail`, which
  # counts only rows it actually looked at. Asserting the total is what makes "scored nothing"
  # loud instead of indistinguishable from "scored everything and all passed".
  if [ "$(( mut_pass + mut_fail ))" -ne "$mut_n" ]; then
    printf 'FAIL: scored %d of %d mutation(s) — the harness skipped rows and would have reported on none of them\n' \
      "$(( mut_pass + mut_fail ))" "$mut_n" >&2
    mut_fail=$(( mut_fail + 1 ))
  fi
  printf '\ncheck-common-lib --mutation: %d mutation(s) observed RED on their own witness, %d failed (pool=%s)\n' \
    "$mut_pass" "$mut_fail" "$mut_pool"
  [ "$mut_fail" -eq 0 ] || exit 1
  printf 'check-common-lib --mutation: PASS\n'
  exit 0
fi

check_summary "common-lib"
