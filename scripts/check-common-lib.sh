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

set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/lib/common.sh

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
# eq <actual> <expected> <label>
eq()   { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }
# assert <status-already-evaluated 0/1> <label>   — call as: cond; assert $? "label"
yes()  { if [ "$1" -eq 0 ]; then ok; else bad "$2 (expected success, rc=$1)"; fi; }
no()   { if [ "$1" -ne 0 ]; then ok; else bad "$2 (expected failure, rc=$1)"; fi; }

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

# key present in a DIFFERENT table must not match
eq "$(adb_toml_get "$f" roles typecheck 2>/dev/null)" "" "key scoped to its table"

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
         "$mrepo/agents/codex" "$mrepo/agents/gemini"
tab_="$(printf '\t')"
man="$(adb_agent_manifest claude "$mrepo" "$mhome")"
# root doc line present, TAB-separated, pointing at the right dest
echo "$man" | grep -Fq -- "$mrepo/agents/claude/CLAUDE.md${tab_}$mhome/.claude/CLAUDE.md" && ok || bad "manifest emits the claude root-doc line"
# skill dir: absolute source, NO trailing slash, dest under ~/.claude/skills/<name>
echo "$man" | grep -Fq -- "$mrepo/agents/claude/skills/demo${tab_}$mhome/.claude/skills/demo" && ok || bad "manifest emits skill dir with no trailing slash"
echo "$man" | grep -q '/skills/demo/	' && bad "manifest skill source must not carry a trailing slash" || ok
# the three runtime scripts + scripts/lib
echo "$man" | grep -Fq -- "$mrepo/agents/claude/scripts/statusline.sh${tab_}$mhome/.claude/scripts/statusline.sh" && ok || bad "manifest emits statusline.sh"
echo "$man" | grep -Fq -- "$mrepo/scripts/lib${tab_}$mhome/.claude/scripts/lib" && ok || bad "manifest emits canonical scripts/lib"
# codex / gemini one-line manifests
eq "$(adb_agent_manifest codex "$mrepo" "$mhome")"  "$mrepo/agents/codex/AGENTS.md${tab_}$mhome/.codex/AGENTS.md"  "codex manifest is the one root doc"
eq "$(adb_agent_manifest gemini "$mrepo" "$mhome")" "$mrepo/agents/gemini/GEMINI.md${tab_}$mhome/.gemini/GEMINI.md" "gemini manifest is the one root doc"
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

# --- adb_default_branch ------------------------------------------------------
gitrepo="$work/gitrepo"
git init -q "$gitrepo"
git -C "$gitrepo" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$gitrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
eq "$(adb_default_branch "$gitrepo")" "main" "default branch falls back to local main"

# --- adb_branch_sync_state ---------------------------------------------------
# Drive every state with a LOCAL bare "origin" (file://, no network): one working
# clone plus a second clone that advances origin, so behind/ahead/diverged are real.
sborigin="$work/syncorigin.git"; git init -q --bare "$sborigin"
sbrepo="$work/syncrepo"
git init -q "$sbrepo"
git -C "$sbrepo" symbolic-ref HEAD refs/heads/main
git -C "$sbrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
git -C "$sbrepo" remote add origin "$sborigin"
git -C "$sbrepo" push -q -u origin main
# Point the bare origin's HEAD at main so the second clone checks it out cleanly and
# gets a local main to push — otherwise (when the host git's init.defaultBranch != main,
# e.g. Linux CI) the clone warns "remote HEAD refers to nonexistent ref" and has no main.
git -C "$sborigin" symbolic-ref HEAD refs/heads/main
eq "$(adb_branch_sync_state "$sbrepo" main)" "current" "sync state: current"

# behind: a second clone pushes a commit; local fetches but stays put.
sbclone="$work/syncclone"; git clone -q "$sborigin" "$sbclone"
git -C "$sbclone" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
git -C "$sbclone" push -q origin main
git -C "$sbrepo" fetch -q origin
eq "$(adb_branch_sync_state "$sbrepo" main)" "behind" "sync state: behind"

# ahead: fast-forward local to origin, then add an unpushed local commit.
git -C "$sbrepo" reset -q --hard origin/main
git -C "$sbrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-only
eq "$(adb_branch_sync_state "$sbrepo" main)" "ahead" "sync state: ahead"

# diverged: origin advances (via the clone) while local keeps its unpushed commit.
git -C "$sbclone" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c3
git -C "$sbclone" push -q origin main
git -C "$sbrepo" fetch -q origin
eq "$(adb_branch_sync_state "$sbrepo" main)" "diverged" "sync state: diverged"

# no-remote: a purely local branch with no origin/<branch> counterpart.
git -C "$sbrepo" branch feature-x
eq "$(adb_branch_sync_state "$sbrepo" feature-x)" "no-remote" "sync state: no-remote"

printf '\ncommon-lib: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "common-lib: PASS"
