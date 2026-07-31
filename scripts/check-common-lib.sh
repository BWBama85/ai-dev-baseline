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
eq "$(adb_shape_val "$sh1" root)"          "$(canon "$tidy")" "shape: root is the canonical git top-level"
eq "$(adb_shape_val "$sh1" cwd_is_root)"   "1"            "shape: cwd==root → cwd_is_root=1"
eq "$(adb_shape_val "$sh1" parent_in_git)" "0"            "shape: tidy repo's parent is not a git repo"
eq "$(adb_shape_val "$sh1" nested_in)"     ""             "shape: tidy repo is not nested"
eq "$(adb_shape_all "$sh1" foreign_doc)"   ""             "shape: tidy repo has no foreign docs"
eq "$(adb_shape_all "$sh1" extra_doc)"     ""             "shape: tidy repo has no extra docs"

# adb_shape_val returns only the FIRST match; adb_shape_all returns every line — verify on a
# hand-built multi-value blob so the two accessors' contract is pinned independent of the walk.
multi="$(printf 'k\tone\nk\ttwo\nother\tx\n')"
eq "$(adb_shape_val "$multi" k)"            "one"       "adb_shape_val returns the first match only"
eq "$(adb_shape_all "$multi" k | tr '\n' ',')" "one,two," "adb_shape_all returns every match"
eq "$(adb_shape_val "$multi" absent)"       ""          "adb_shape_val on an absent key prints nothing"

# (2) Working dir below the git root → cwd_is_root=0, root still the top-level.
mkdir -p "$tidy/sub/deeper"
sh2="$(adb_repo_shape "$tidy/sub/deeper")"
eq "$(adb_shape_val "$sh2" cwd_is_root)" "0"                "shape: cwd below root → cwd_is_root=0"
eq "$(adb_shape_val "$sh2" root)"        "$(canon "$tidy")" "shape: subdir still resolves the git root"

# (3) Nested repo: an inner repo checked out inside an outer repo.
outer="$work/outer"; mkdir -p "$outer"; git init -q "$outer"
inner="$outer/vendor/plugin"; mkdir -p "$inner"; git init -q "$inner"
sh3="$(adb_repo_shape "$inner")"
eq "$(adb_shape_val "$sh3" root)"          "$(canon "$inner")" "shape: nested inner repo resolves to itself"
eq "$(adb_shape_val "$sh3" parent_in_git)" "1"                 "shape: nested repo's parent is inside a git repo"
eq "$(adb_shape_val "$sh3" nested_in)"     "$(canon "$outer")" "shape: nested_in names the enclosing repo"

# (4) bama-style: a git repo dropped inside an UNTRACKED parent tree, with a root doc ABOVE it.
site="$work/site"; plugin="$site/wp-content/plugins/myplugin"
mkdir -p "$plugin"; git init -q "$plugin"
printf 'site root doc\n' > "$site/CLAUDE.md"        # outside any repo
sh4="$(adb_repo_shape "$plugin")"
eq "$(adb_shape_val "$sh4" root)"          "$(canon "$plugin")" "shape: bama-style resolves the plugin as root"
eq "$(adb_shape_val "$sh4" parent_in_git)" "0"                  "shape: bama-style parent is outside any git repo"
eq "$(adb_shape_val "$sh4" nested_in)"     ""                   "shape: bama-style is not nested in another repo"
has "$(adb_shape_all "$sh4" foreign_doc)"  "$(canon "$site")/CLAUDE.md" "shape: finds the out-of-repo site CLAUDE.md above"

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
has  "$extra5" "$(canon "$mono")/packages/api/CLAUDE.md" "shape: extra_doc includes a doc beside a manifest"
hasnt "$extra5" "docs/CLAUDE.md"                          "shape: extra_doc excludes a bare doc (no manifest)"
hasnt "$extra5" "$(canon "$mono")/CLAUDE.md"              "shape: extra_doc never lists the top-level root doc"
# An UNtracked package doc is invisible to extra_doc (git ls-files reads the index).
mkdir -p "$mono/packages/web"; printf 'web\n' > "$mono/packages/web/CLAUDE.md"; printf '{}\n' > "$mono/packages/web/package.json"
sh5b="$(adb_repo_shape "$mono")"
hasnt "$(adb_shape_all "$sh5b" extra_doc)" "packages/web/CLAUDE.md" "shape: extra_doc is tracked-only (untracked package doc excluded)"

# (6) Unreadable start dir → in_git=0 and a surfaced warning (never a silent empty result).
sh6="$(adb_repo_shape "$work/no/such/path")"
eq "$(adb_shape_val "$sh6" in_git)" "0"     "shape: nonexistent start is not in_git"
has "$(adb_shape_all "$sh6" warning)" "unreadable" "shape: nonexistent start emits a warning"

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
eq "$( HOME=/tmp/fakehome; adb_global_manifest )" "/tmp/fakehome/.config/ai-dev-baseline/agents.toml" \
  "global manifest: \$HOME/.config/ai-dev-baseline/agents.toml"
# shellcheck disable=SC2034  # XDG_CONFIG_HOME being unread by adb_global_manifest IS the assertion.
eq "$( HOME=/tmp/fakehome XDG_CONFIG_HOME=/tmp/decoy; adb_global_manifest )" \
  "/tmp/fakehome/.config/ai-dev-baseline/agents.toml" \
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
eq "$(printf '%s' "$(adb_mtime "$mtf")" | wc -l | tr -d ' ')" "0" "adb_mtime: never multi-line"

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
eq "$(adb_claude_hook_scripts | wc -l | tr -d ' ')" "4" "hook scripts: four wired hooks"
has "$(adb_claude_hook_scripts)" "session-currency.sh" "hook scripts: includes the currency hook"
has "$(adb_claude_hook_scripts)" "state-claim-gate.sh" "hook scripts: includes the state-claim gate"
hasnt "$(adb_claude_hook_scripts)" "statusline.sh" "hook scripts: excludes the non-hook statusline"
eq "$(adb_claude_hook_regex /home/u)" \
  '^/home/u/\.claude/scripts/(precommit-gate|implement-issue-gate|session-currency|state-claim-gate)\.sh$' \
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
# Every wired hook must also be a manifest entry, or it is never linked into place.
manifest_dests="$(adb_agent_manifest claude /R /H | cut -f2)"
while IFS= read -r hs; do
  [ -n "$hs" ] || continue
  has "$manifest_dests" "/H/.claude/scripts/$hs" "manifest links the wired hook $hs"
done <<EOF
$(adb_claude_hook_scripts)
EOF

# --- adb_claude_hooks_state / adb_claude_hooks_missing (#242) ----------------
# The defect this replaces inferred intent about the WHOLE hook payload from ONE member, so the
# case that matters most is `partial` — removing one hook must NOT read as opting out of all.
hs_dir="$work/hookstate"; mkdir -p "$hs_dir"
hs_all="$hs_dir/all.json"; hs_none="$hs_dir/none.json"; hs_part="$hs_dir/partial.json"
: > "$hs_all"; while IFS= read -r hs; do [ -n "$hs" ] && printf '%s\n' "$hs" >> "$hs_all"; done <<EOF
$(adb_claude_hook_scripts)
EOF
printf '{"hooks":{}}\n' > "$hs_none"
# every shipped hook EXCEPT precommit-gate.sh — the exact edit that triggered #242
grep -v 'precommit-gate\.sh' "$hs_all" > "$hs_part"

eq "$(adb_claude_hooks_state "$hs_all")"  "wired"   "hooks-state: all shipped hooks present → wired"
eq "$(adb_claude_hooks_state "$hs_none")" "none"    "hooks-state: no shipped hooks present → none (the opt-out)"
eq "$(adb_claude_hooks_state "$hs_part")" "partial" "hooks-state: one hook removed → partial, NOT none (#242)"
eq "$(adb_claude_hooks_state "$hs_dir/missing.json")" "none" "hooks-state: absent settings.json → none"

eq "$(adb_claude_hooks_missing "$hs_all"  | wc -l | tr -d ' ')" "0" "hooks-missing: fully wired names nothing"
eq "$(adb_claude_hooks_missing "$hs_part" | tr -d ' \n')" "precommit-gate.sh" "hooks-missing: names the removed hook"
eq "$(adb_claude_hooks_missing "$hs_none" | wc -l | tr -d ' ')" "4" "hooks-missing: none → every shipped hook"

# Each shipped hook must independently produce `partial` when it alone is removed. Without this,
# the predicate could key on one filename again and still pass the cases above.
while IFS= read -r hs; do
  [ -n "$hs" ] || continue
  grep -vF "$hs" "$hs_all" > "$hs_dir/drop.json"
  eq "$(adb_claude_hooks_state "$hs_dir/drop.json")" "partial" "hooks-state: dropping $hs alone → partial"
done <<EOF
$(adb_claude_hook_scripts)
EOF

# --- adb_require_gh / adb_repo_slug (#87) ------------------------------------
# Both are sourced by release-convention.sh AND repo-settings.sh, so a regression here breaks two
# gh-backed modules at once. The contract that matters: they RETURN non-zero (never `exit`, which
# would kill the caller's shell from inside a sourced function) and they say what is wrong.
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

# ==================== adb_run_bounded (#139: promoted from role-dispatch) =====================
# The mechanism was moved here so currency-lib.sh could share it instead of hand-rolling a second
# watchdog. It had been covered only TRANSITIVELY, through check-role-dispatch.sh's agent dispatch;
# a shared primitive with two callers needs its own tests. Both paths are exercised: the `timeout`
# binary when present, and the bash-3.2 watchdog fallback that a stock Mac takes.

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
eq "$(printf 'fed' | adb_run_bounded 30 1 cat)" "fed" "adb_run_bounded delivers stdin to the child"
eq "$(printf 'fed' | ADB_NO_TIMEOUT_BIN=1 adb_run_bounded 30 1 cat)" "fed" \
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
eq "$(fsc "$fslug" 7 'junegunn/fzf')" "0" \
   "fork clone: a PR on UPSTREAM verifies (an origin-only anchor called this a different repository)"
eq "$(fsc "$fslug" 7 'me/fzf')" "0" "fork clone: a PR on the fork itself also verifies"
# ...and the hole the anchor exists for is still closed: GH_REPO names a repo in NOBODY's remote set.
eq "$(fsc "$fslug" 7 'cli/cli')" "2" "fork clone: a read that answered for an UNTRACKED repo is still refused"
uslug="$work/upstreamonly"; mkdir -p "$uslug"; git init -q "$uslug"
git -C "$uslug" remote add upstream https://github.com/junegunn/fzf.git
eq "$(fsc "$uslug" 7 'junegunn/fzf')" "0" \
   "upstream-only clone: verifies (an origin-only anchor had no anchor at all here)"
eq "$(fsc "$uslug" 7 'cli/cli')" "2" "upstream-only clone: an untracked repo is still refused"

# --- adb_pr_slug_check: the cross-check, and its ORDER -----------------------------------------
mk_origin "https://github.com/acme/widget.git"
sc() { ( cd "$oslug" && adb_pr_slug_check test 7 "$1" "$2" >/dev/null 2>&1; echo $? ); }
eq "$(sc '7' 'acme/widget')" "0" "slug-check: a bare number against the matching checkout verifies"
eq "$(sc 'https://github.com/acme/widget/pull/7' 'acme/widget')" "0" "slug-check: an agreeing URL verifies"
eq "$(sc 'https://github.com/Acme/Widget/pull/7' 'ACME/WIDGET')" "0" "slug-check: comparison is case-insensitive on both sides"
eq "$(sc 'https://github.com/other/project/pull/7' 'acme/widget')" "2" "slug-check: a URL naming another repo is refused"
eq "$(sc 'github.com/other/project/pull/7' 'acme/widget')" "2" "slug-check: the SCHEME-LESS form is refused too (#173)"
# The GH_REPO class: a bare number names no repository, so only the checkout anchor catches a
# redirected read.
eq "$(sc '7' 'other/project')" "2" "slug-check: reads that answered for another repo are refused even for a bare number"
# UNREADABLE OUTRANKS MISMATCHED, and that order is part of the contract. The old check was guarded on
# a non-empty observed slug, so it silently VANISHED on exactly these responses — and a foreign URL
# was then answered about this repo. Each must report 1 (the caller's 20), never 2 and never 0.
for got in "" "acme" "acme/widget/extra" "/widget" "acme/"; do
  eq "$(sc '7' "$got")" "1" "slug-check: an observed slug of '$got' is unreadable (1), not a mismatch"
  eq "$(sc 'https://github.com/other/project/pull/7' "$got")" "1" \
     "slug-check: unreadable metadata outranks a foreign URL ('$got')"
done
# A slug beginning with `-` must be COMPARED, not handed to grep as options. Without `--` grep aborted
# with a usage dump and the comparison never ran, and the code then reported a repository mismatch for
# a test that had not happened. Unreachable from the API, but the harness calls this primitive directly.
_dashout="$( cd "$oslug" && adb_pr_slug_check test 7 '' '-x/y' 2>&1 >/dev/null )"
eq "$(sc '7' '-x/y')" "2" "slug-check: a leading-dash slug is refused as a mismatch"
hasnt "$_dashout" "invalid option" "slug-check: grep never sees a slug as its own options"
hasnt "$_dashout" "Usage" "slug-check: no raw grep usage dump reaches the operator"

# An unresolvable checkout is also unverifiable rather than a mismatch — fail closed, both codes
# distinct. Every remote goes, not just origin: with any remote left the checkout still has an
# identity, so the honest answer would be 2 (a mismatch) rather than 1 (no anchor at all).
for r in $(git -C "$oslug" remote); do git -C "$oslug" remote remove "$r"; done
eq "$(sc '7' 'acme/widget')" "1" "slug-check: no remotes at all -> unverifiable (1), never verified"
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
  jq -n -r --arg a "$api" --argjson who "$(printf '%s\n' "$@" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
    "$(adb_reviewer_match_jq) \$a | adb_declared_reviewer(\$who)" 2>/dev/null
}
eq "$(rmatch 'foo' 'foo')"                "true"  "identity: bare declared, bare login -> match"
eq "$(rmatch 'foo[bot]' 'foo')"           "true"  "identity: bare declared, '[bot]' login -> match (the REST spelling)"
eq "$(rmatch 'FOO[BOT]' 'foo')"           "true"  "identity: matching is case-insensitive"
eq "$(rmatch 'FOO[BOT]' 'foo[bot]')"      "true"  "identity: case-insensitive for a suffixed declaration too"
# CASE IS FOLDED ON BOTH SIDES. The production path lower-cases the declaration before it gets here,
# so this asserts the primitive is correct STANDALONE — a future consumer passing a raw declaration
# must not silently match nothing, because "matches nothing" wedges a guard at "awaiting review"
# forever, which is the safe and therefore silent direction.
eq "$(rmatch 'foo' 'FOO[BOT]')"           "false" "identity: a RAW uppercase '[bot]' declaration still rejects a human"
eq "$(rmatch 'foo[bot]' 'FOO[BOT]')"      "true"  "identity: a RAW uppercase declaration still matches its App"
eq "$(rmatch 'foo' 'FOO')"                "true"  "identity: a RAW uppercase bare declaration matches"
eq "$(rmatch 'foo[bot]' 'foo[bot]')"      "true"  "identity: '[bot]' declared, '[bot]' login -> match"
eq "$(rmatch 'foo' 'foo[bot]')"           "false" "identity: '[bot]' declared, HUMAN login -> NO match (#176's fail-open)"
eq "$(rmatch 'foo[bot][bot]' 'foo[bot]')" "false" "identity: a DOUBLED suffix does not satisfy '[bot]' declared"
eq "$(rmatch 'bar' 'foo')"                "false" "identity: an unrelated login does not match"
eq "$(rmatch 'bar[bot]' 'foo')"           "false" "identity: an unrelated BOT does not match (an allowlist, not a heuristic)"
eq "$(rmatch 'foobar' 'foo')"             "false" "identity: the match is anchored, not a prefix test"
eq "$(rmatch 'foo' 'foo' 'foo')"          "true"  "identity: a duplicated declaration still matches"
eq "$(rmatch 'baz[bot]' 'foo' 'baz[bot]')" "true" "identity: any ONE of several declarations may match"
eq "$(rmatch 'foo' 'bar[bot]' 'foo')"     "true"  "identity: a bare entry beside a suffixed one still matches"
eq "$(rmatch 'foo')"                      "false" "identity: an EMPTY declaration set matches nothing"
# An entry that is only the suffix must not become a reviewer that matches everything suffixed. The
# declaration reader drops it (and then rejects the declaration); the predicate must not rescue it.
eq "$(rmatch 'anything[bot]' '[bot]')"    "false" "identity: a bare '[bot]' entry does not match every App"

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
  ev="$(adb_reviewer_evidence "$(printf '%s' "$who" | tr ',' '\n')" "$2" "$3" "$4" "$SHA")" || { printf 'ERR'; return; }
  local c; c="$(adb_reviewer_classes t "$(printf '%s' "$who" | tr ',' '\n')" "$ev" "${5:-$ANCH}" 2>/dev/null)" \
    || { printf 'RC2'; return; }
  adb_fold_reviewer_classes "$c"
}
rv()  { printf '[{"user":{"login":"%s"},"state":"%s","commit_id":"%s"}]' "$1" "$2" "${3:-$SHA}"; }
cm()  { printf '[{"user":{"login":"%s"},"created_at":"%s"}]' "$1" "$2"; }
rx()  { printf '[{"user":{"login":"%s"},"content":"%s","created_at":"%s"}]' "$1" "${2:-+1}" "$3"; }
N='[]'

# THE TABLE (#167 §4), one row at a time.
eq "$(cls a "$(rv a CHANGES_REQUESTED)" "$N" "$N")" "rejected"  "classify: CHANGES_REQUESTED at head -> rejected"
eq "$(cls a "$(rv a COMMENTED)"         "$N" "$N")" "attention" "classify: COMMENTED at head -> attention"
eq "$(cls a "$(rv a APPROVED)"          "$N" "$N")" "clean"     "classify: APPROVED at head -> clean"
eq "$(cls a "$(rv a PENDING)"           "$N" "$N")" "none"      "classify: an unsubmitted PENDING draft is not evidence"
eq "$(cls a "$(rv a DISMISSED)"         "$N" "$N")" "none"      "classify: a DISMISSED review is not evidence"
eq "$(cls a "$(rv a WHAT_IS_THIS)"      "$N" "$N")" "unknown"   "classify: an unrecognized state -> unknown (fails closed)"
eq "$(cls a "$(rv a APPROVED bbbb)"     "$N" "$N")" "none"      "classify: a review of ANOTHER commit is not evidence about this head"
# A REVIEW THAT CANNOT BE TIED TO A COMMIT IS `unknown`, NOT ABSENT. The commit filter used to run
# BEFORE the reviewer match, so a declared reviewer CHANGES_REQUESTED whose commit_id was missing or
# non-string was discarded before anything read who wrote it — and a fresh `+1` on another surface
# then became the only evidence left, folding to `clean` and arming the merge. Reported by the codex
# reviewer on PR #219; the fourth assertion below is the one that was `clean` before the fix.
NO_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED"}]'
NULL_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":null}]'
NUM_CID='[{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":12345}]'
FOREIGN_NO_CID='[{"user":{"login":"nobody"},"state":"CHANGES_REQUESTED"}]'
eq "$(cls a "$NO_CID" "$N" "$N")" "unknown" \
   "classify: a declared reviewer review with NO commit_id -> unknown, never absent"
eq "$(cls a "$NULL_CID" "$N" "$N")" "unknown" \
   "classify: ...an explicitly null commit_id likewise"
eq "$(cls a "$NUM_CID" "$N" "$N")" "unknown" \
   "classify: ...and a NON-STRING commit_id, which the equality test silently dropped"
eq "$(cls a "$NO_CID" "$N" "$(rx a +1 "$FRESH")")" "unknown" \
   "classify: an undatable rejection is NOT outvoted by a fresh +1 (the false-arm)"
# ...but an UNDECLARED login with the same malformation must not wedge the guard: only declared
# reviewers are classified, so a stray malformed review from anyone else is simply not evidence.
eq "$(cls a "$FOREIGN_NO_CID" "$N" "$(rx a +1 "$FRESH")")" "clean" \
   "classify: an UNDECLARED login with no commit_id does not wedge the guard"

# THE WITHIN-REVIEWER ORDER: rejected > attention > unknown > clean > none.
eq "$(cls a "$(rv a APPROVED)" "$(cm a "$FRESH")" "$N")" "attention" \
   "within-reviewer: a fresh comment outranks that reviewer's APPROVED"
eq "$(cls a "$(printf '[{"user":{"login":"a"},"state":"COMMENTED","commit_id":"%s"},{"user":{"login":"a"},"state":"CHANGES_REQUESTED","commit_id":"%s"}]' "$SHA" "$SHA")" "$N" "$N")" "rejected" \
   "within-reviewer: a standing CHANGES_REQUESTED outranks a COMMENTED on the same commit"
eq "$(cls a "$(printf '[{"user":{"login":"a"},"state":"WEIRD","commit_id":"%s"},{"user":{"login":"a"},"state":"APPROVED","commit_id":"%s"}]' "$SHA" "$SHA")" "$N" "$N")" "unknown" \
   "within-reviewer: UNKNOWN outranks clean — an uninterpretable state is never outvoted into a pass"
eq "$(cls a "$(rv a APPROVED)" "$N" "$(rx a +1 "$STALE")")" "clean" \
   "within-reviewer: a STALE '+1' beside that reviewer's APPROVED is still clean"

# THE ACROSS-REVIEWER ORDER IS NOT THE SAME ORDER, and the swapped pair IS #185: `none` outranks
# `clean`, so a pass requires EVERY declared reviewer. Reusing the within-reviewer order here is
# exactly the shipped bug — one fast `+1` reporting a clean pass for a set that had not looked.
eq "$(cls a,b "$N" "$N" "$(rx a +1 "$FRESH")")" "none" \
   "#185: one fresh '+1' of two declared reviewers folds to none, NOT clean"
eq "$(cls a,b "$N" "$N" "$(printf '[{"user":{"login":"a"},"content":"+1","created_at":"%s"},{"user":{"login":"b"},"content":"+1","created_at":"%s"}]' "$FRESH" "$FRESH")")" "clean" \
   "#185: BOTH declared reviewers clean -> clean"
eq "$(cls a,b "$(rv a CHANGES_REQUESTED)" "$N" "$N")" "rejected" \
   "#185: a rejection from one wins outright over another's silence"
eq "$(cls a,b "$(rv b WEIRD)" "$N" "$(rx a +1 "$FRESH")")" "unknown" \
   "#185: unknown outranks a sibling's clean — fail closed, never arm"
eq "$(cls a,b "$(rv b APPROVED)" "$N" "$(rx a +1 "$FRESH")")" "clean" \
   "#185: mixed evidence across surfaces still satisfies the whole set"

# UNDATABLE AND UNORDERABLE RECORDS. A declared reviewer's signal with no `created_at` is malformed,
# and dropping it would silently read as "that reviewer said nothing" — which on the clean path is a
# false pass. An unrecognized FORMAT is rejected outright (rc 2) rather than normalized.
eq "$(cls a "$N" '[{"user":{"login":"a"},"body":"x"}]' "$N")" "unknown" \
   "classify: a declared reviewer's comment with NO timestamp -> unknown"
eq "$(cls a "$N" "$N" '[{"user":{"login":"a"},"content":"+1"}]')" "unknown" \
   "classify: a declared reviewer's '+1' with NO timestamp -> unknown"
eq "$(cls a "$N" "$(cm a '2026-07-25T04:45:23-04:00')" "$N")" "RC2" \
   "classify: an unorderable timestamp FORMAT returns rc 2, never a guessed ordering"
eq "$(cls a "$N" '[{"user":{"login":"nobody"},"body":"x"}]' "$N")" "none" \
   "classify: an UNDECLARED login's undatable record is ignored, not fatal"

# THE SENTINEL. `ADB_NO_ANCHOR` is what an unestablished anchor degrades to, and it must make every
# date-scoped signal read as stale while leaving commit-scoped review evidence untouched. An EMPTY
# anchor would be the fail-open spelling exactly — every non-empty string is `\>` the empty one.
eq "$(cls a "$N" "$N" "$(rx a +1 "$FRESH")" "$ADB_NO_ANCHOR")" "none" \
   "sentinel: an unestablished anchor makes a fresh '+1' unprovable -> none, never clean"
eq "$(cls a "$(rv a APPROVED)" "$N" "$N" "$ADB_NO_ANCHOR")" "clean" \
   "sentinel: commit-scoped review evidence is unaffected by an unestablished anchor"
if adb_is_utc_instant "$ADB_NO_ANCHOR"; then ok; else bad "ADB_NO_ANCHOR must itself be an orderable instant"; fi

# The fold's identity: no reviewer classified at all is `none`, never `clean`.
eq "$(adb_fold_reviewer_classes "")" "none" "fold: an EMPTY class list is none, never clean"
eq "$(adb_reviewers_in_class "$(printf 'a\tnone\nb\tclean\nc\tnone')" none)" "a c" \
   "adb_reviewers_in_class names exactly the logins in that class"
eq "$(adb_reviewers_in_class "$(printf 'a\tclean')" none)" "" \
   "adb_reviewers_in_class is empty when nobody is in the class"
# SEVERAL classes at once — pr-watch reports `rejected` and `attention` as one outcome, and joining
# two separately-fetched lists (either of which may be empty) is what produced a stray double space.
eq "$(adb_reviewers_in_class "$(printf 'a\trejected\nb\tnone\nc\tattention')" rejected attention)" "a c" \
   "adb_reviewers_in_class accepts several classes and preserves order"
eq "$(adb_reviewers_in_class "$(printf 'a\trejected\nb\tnone')" rejected attention)" "a" \
   "...with no stray separator when only one of the named classes is populated"

# THE `<login> <class>` GRAMMAR IS PARSED FROM THE RIGHT. A login carrying whitespace can never name
# a real GitHub account and `role-dispatch bots --comparable` rejects the whole declaration for it
# (18, fail-closed — dropping just the bad entry would SHRINK the set every consumer must satisfy).
# These pin the belt to that braces: parsed from the LEFT, `foo bar none` yields the non-class
# "bar none", which ranks as none by accident rather than by rule and makes the diagnostic garbage.
eq "$(adb_fold_reviewer_classes "$(printf 'foo bar\tnone')")" "none" \
   "fold: a whitespace-bearing login still yields a REAL class, not a garbled one"
eq "$(adb_fold_reviewer_classes "$(printf 'foo bar\tclean')")" "clean" \
   "fold: ...and the TAB split is total, so a clean class is not lost"
eq "$(adb_reviewers_in_class "$(printf 'foo bar\tnone\nb\tclean')" none)" "foo bar" \
   "adb_reviewers_in_class recovers the whole login, not its first word"
# ...and the same login round-trips through the CLASSIFIER, which the space grammar could not do:
# it split `foo bar` at the delimiter, so the reviewer never matched its own evidence.
eq "$(cls "foo bar" "$N" "$N" "$(printf '[{"user":{"login":"foo bar"},"content":"+1","created_at":"%s"}]' "$FRESH")")" "clean" \
   "classify: a whitespace-bearing login matches its OWN evidence under the TAB grammar"

check_summary "common-lib"
