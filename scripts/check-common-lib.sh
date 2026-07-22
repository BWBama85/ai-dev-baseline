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

adb_toml_get "$work/nope.toml" gates test >/dev/null; no $? "missing file returns nonzero"

# key present in a DIFFERENT table must not match
eq "$(adb_toml_get "$f" roles typecheck 2>/dev/null)" "" "key scoped to its table"

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

printf '\ncommon-lib: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "common-lib: PASS"
