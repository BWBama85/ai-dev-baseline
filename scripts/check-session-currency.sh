#!/usr/bin/env bash
# ai-dev-baseline — behavior tests for the SessionStart currency hook (issue #36).
#
# The hook decides WHEN it is safe to run `baseline update` and reduces the outcome to at most
# one operator-visible line. Every one of those decisions is a safety property, so each is
# asserted here against a real install-source clone backed by a LOCAL bare "origin" (file://,
# no network) inside a fake HOME. Nothing in this file may touch the developer's real ~/.claude
# or real clone: HOME is overridden for every invocation, and so are the XDG dirs the hook uses
# for its rate-limit stamp.
#
# What is NOT provable offline, and is therefore deliberately absent: that Claude Code dispatches
# the `startup` matcher, renders `systemMessage`, honors `reloadSkills`, or enforces the entry's
# timeout. Those need the real binary — see the smoke-test follow-up issue.
#
# Usage: bash scripts/check-session-currency.sh   (exit 0 = all pass, 1 = a failure)

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
ROOT="$(pwd)"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/has/hasnt + check_summary + check_git / check_make_repo_pair

command -v jq >/dev/null 2>&1 || { echo "check-session-currency: jq required" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- fixture: a real install-source clone, pre-linked into a fake HOME --------
# Mirrors check-baseline.sh's shape (the manifest must fully resolve or `baseline update`
# reports a broken install), plus the hook itself and the shared lib beside it.
seed="$work/seed"
mkdir -p "$seed/bin" "$seed/scripts/lib" "$seed/agents/claude/skills/demo" "$seed/agents/claude/scripts"
cp "$ROOT/bin/baseline" "$seed/bin/baseline"; chmod +x "$seed/bin/baseline"
cp "$ROOT/scripts/lib/common.sh" "$seed/scripts/lib/common.sh"
# currency-lib.sh carries every DECISION the hook used to make inline (#139). Without it the hook
# is a shell around a missing library and exits silently, which would turn most of this suite into
# a wall of misleading "silent" passes rather than a loud failure.
cp "$ROOT/scripts/lib/currency-lib.sh" "$seed/scripts/lib/currency-lib.sh"
cp "$ROOT/agents/claude/scripts/session-currency.sh" "$seed/agents/claude/scripts/session-currency.sh"
chmod +x "$seed/agents/claude/scripts/session-currency.sh"
# The stub installer LOGS its args and re-creates any missing manifest link. It has to actually
# relink, unlike check-baseline.sh's log-only stub: a same-HEAD repair is only observable if the
# repair can succeed, and `baseline update` verifies the manifest afterwards. It reads the same
# adb_agent_manifest the real installer does, so it cannot drift from what is verified.
cat > "$seed/install.sh" <<STUB
#!/usr/bin/env bash
printf 'install: %s\n' "\$*" >> "$work/install.log"
_r="\$(cd "\$(dirname "\$0")" && pwd)"
. "\$_r/scripts/lib/common.sh"
adb_agent_manifest claude "\$_r" "\$HOME" | while IFS="\$(printf '\\t')" read -r s d; do
  [ -n "\$s" ] && [ -n "\$d" ] || continue
  [ -e "\$d" ] && continue
  mkdir -p "\$(dirname "\$d")"
  ln -sfn "\$s" "\$d"
done
STUB
chmod +x "$seed/install.sh"
printf 'root doc\n' > "$seed/agents/claude/CLAUDE.md"
printf 'demo skill\n' > "$seed/agents/claude/skills/demo/SKILL.md"
# Stub every OTHER script the manifest expects, enumerated from the manifest itself rather than
# a literal list: `baseline update` verifies the full manifest, so a script added there but not
# here would fail this fixture in a way that looks like a bin/baseline bug.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/common.sh"
mapfile -t seed_scripts < <(adb_agent_manifest claude "$seed" "$work/unused-home" \
  | cut -f1 | sed -n "s|^$seed/agents/claude/scripts/||p")
check_enumerated "claude script manifest (seed)" "${seed_scripts[@]}" || exit 1
for s in "${seed_scripts[@]}"; do
  case "$s" in session-currency.sh) continue ;; esac   # the real one, copied above
  printf '#stub\n' > "$seed/agents/claude/scripts/$s"
done

origin="$work/origin.git"
check_make_repo_pair "$seed" "$origin" || { echo "session-currency fixture: repo pair init failed" >&2; exit 1; }
git -C "$seed" symbolic-ref HEAD refs/heads/main
check_git "$seed" add -A
check_git "$seed" commit -q -m seed
git -C "$seed" push -q -u origin main
git -C "$origin" symbolic-ref HEAD refs/heads/main

src="$work/src"; git clone -q "$origin" "$src"
fh="$work/home"; mkdir -p "$fh/.claude/skills" "$fh/.claude/scripts"
ln -s "$src/agents/claude/CLAUDE.md" "$fh/.claude/CLAUDE.md"
ln -s "$src/agents/claude/skills/demo" "$fh/.claude/skills/demo"
mapfile -t src_scripts < <(adb_agent_manifest claude "$src" "$fh" | cut -f1 \
  | sed -n "s|^$src/agents/claude/scripts/||p")
check_enumerated "claude script manifest (symlinks)" "${src_scripts[@]}" || exit 1
for s in "${src_scripts[@]}"; do
  ln -s "$src/agents/claude/scripts/$s" "$fh/.claude/scripts/$s"
done
ln -s "$src/scripts/lib" "$fh/.claude/scripts/lib"
srcgit="$(git -C "$src" rev-parse --absolute-git-dir)"

# The hook as the operator would reach it: through the installed symlink, so `dirname "$0"/lib`
# resolves the same way it does in a real install.
HOOK="$fh/.claude/scripts/session-currency.sh"

c2="$work/c2"; git clone -q "$origin" "$c2"
advance_origin() {
  check_git "$c2" fetch -q origin
  check_git "$c2" reset -q --hard origin/main
  check_git "$c2" commit -q --allow-empty -m "$1"
  check_git "$c2" push -q origin main
}

reset_src() {
  git -C "$src" checkout -q main 2>/dev/null || git -C "$src" checkout -q -B main
  git -C "$src" fetch -q origin
  git -C "$src" reset -q --hard origin/main
  git -C "$src" clean -qfd
  rm -rf "${work:?}/cache"                       # drop the rate-limit stamp between cases
  rm -rf "${srcgit:?}/adb-update.lock"
}

# Run the hook with a given event source + cwd. Everything that could reach the developer's real
# environment is redirected into the fixture. Sets OUT (stdout) and RC.
# Usage: run_hook <source> [cwd] ; mode/interval via the MODE_ENV / INTERVAL_ENV knobs below.
MODE_ENV=""; INTERVAL_ENV=""; XDG_CONFIG_ENV=""
run_hook() {
  local source="$1" cwd="${2:-$work}" input
  input="$(jq -cn --arg s "$source" --arg c "$cwd" \
    '{session_id:"t", hook_event_name:"SessionStart", source:$s, cwd:$c}')"
  OUT="$(printf '%s' "$input" | env HOME="$fh" \
      XDG_CACHE_HOME="$work/cache" XDG_CONFIG_HOME="$XDG_CONFIG_ENV" \
      ADB_SESSION_UPDATE="$MODE_ENV" ADB_SESSION_UPDATE_INTERVAL_SECS="$INTERVAL_ENV" \
      bash "$HOOK" 2>/dev/null)"
  RC=$?
}

head_of() { git -C "$src" rev-parse HEAD; }

# --- exit status: NEVER non-zero ---------------------------------------------
# SessionStart cannot block a session, but a non-zero exit renders a hook-error notice in the
# transcript. Currency is a convenience and must never look like a broken session.

reset_src
run_hook startup
eq "$RC" "0" "current install → exit 0"
eq "$OUT" "" "current install → silence (no line at all)"

# A malformed event (no source field) must still exit 0 and do nothing.
OUT="$(printf 'not json' | env HOME="$fh" XDG_CACHE_HOME="$work/cache" XDG_CONFIG_HOME="$fh/.config" \
        ADB_SESSION_UPDATE="" ADB_SESSION_UPDATE_INTERVAL_SECS="" bash "$HOOK" 2>/dev/null)"; RC=$?
eq "$RC" "0" "malformed event → exit 0"
eq "$OUT" "" "malformed event → silence"

# --- the source gate: only a genuinely new session ---------------------------
# clear/compact happen MID-session, fork runs beside a live parent, resume continues a
# conversation whose tooling was already loaded. None may swap tooling underneath.

for s in clear compact resume fork; do
  reset_src
  advance_origin "for-$s"
  before="${ head_of; }"
  run_hook "$s"
  eq "$RC" "0" "source=$s → exit 0"
  eq "$OUT" "" "source=$s → silence"
  eq "${ head_of; }" "$before" "source=$s → clone NOT updated"
done

# --- auto mode: a behind clone is updated, once, with one line ---------------

reset_src
advance_origin "brings-a-fix"
before="${ head_of; }"
run_hook startup
eq "$RC" "0" "behind + startup → exit 0"
if [ "${ head_of; }" != "$before" ]; then ok; else bad "behind + startup must fast-forward the clone"; fi
has "$OUT" '"systemMessage"' "update reports via systemMessage (operator-visible channel)"
has "$OUT" 'updated' "update line says it updated"
has "$OUT" '(1 commit)' "update line names the commit count, singular"
has "$OUT" '"reloadSkills":true' "update asks the harness to reload skills"
# Valid JSON, and exactly one line — the terse-output contract. Asserted as non-empty AND
# newline-free rather than by counting lines: `printf '%s\n' "" | wc -l` is also 1, so a
# line-count assertion passes on silence and can only ever catch two-or-more.
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && ok || bad "hook output must be valid JSON"
if [ -n "$OUT" ]; then ok; else bad "hook must emit a line here, not silence"; fi
case "$OUT" in *"
"*) bad "hook output must be a single line (contains a newline)" ;; *) ok ;; esac

# Plural form, so the count is not hardcoded.
reset_src
advance_origin "c1"; advance_origin "c2"
run_hook startup
has "$OUT" '(2 commits)' "update line pluralizes the commit count"

# --- the rate limit -----------------------------------------------------------

reset_src
advance_origin "rate-limited"
INTERVAL_ENV=3600
run_hook startup                      # first run: no stamp yet → checks, updates
has "$OUT" 'updated' "first run inside the interval still checks"
before="${ head_of; }"
advance_origin "should-be-skipped"
run_hook startup                      # second run: stamp is fresh → skipped entirely
eq "$OUT" "" "a run inside the rate-limit interval is silent"
eq "${ head_of; }" "$before" "a rate-limited run does not touch the clone"
INTERVAL_ENV=0
run_hook startup                      # interval 0 disables the limit
has "$OUT" 'updated' "interval 0 checks on every startup"
INTERVAL_ENV=""

# --- never update the clone the session is working IN ------------------------

reset_src
advance_origin "session-inside-src"
before="${ head_of; }"
run_hook startup "$src"
eq "$OUT" "" "session started inside the install-source → silent"
eq "${ head_of; }" "$before" "session started inside the install-source → clone untouched"
# …and a session in a SUBDIRECTORY of it is the same clone.
run_hook startup "$src/scripts"
eq "${ head_of; }" "$before" "session started in a subdirectory of the install-source → untouched"
# A LINKED WORKTREE of the install-source is a different work-tree root but the SAME repository;
# fast-forwarding the main clone under it is the same surprise, so it must skip too.
reset_src
advance_origin "worktree-case"
git -C "$src" worktree add -q "$work/src-wt" -b wt-probe >/dev/null 2>&1
before="${ head_of; }"
run_hook startup "$work/src-wt"
eq "${ head_of; }" "$before" "session in a linked worktree of the install-source → untouched"
git -C "$src" worktree remove --force "$work/src-wt" >/dev/null 2>&1
git -C "$src" branch -D wt-probe >/dev/null 2>&1

# A session in any OTHER repo still gets the update — the whole point of the feature.
reset_src
advance_origin "other-repo-case"
before="${ head_of; }"
other="$work/other-project"; mkdir -p "$other"; git init -q "$other"
run_hook startup "$other"
if [ "${ head_of; }" != "$before" ]; then ok; else bad "a session in another repo must still update the install-source"; fi

# A FUTURE-dated stamp (clock skew: a restored VM snapshot, a dual-boot RTC, a backup that
# rewrites ~/.cache) must not read as "checked very recently" and suppress the check until
# wall-clock catches up — that is silent staleness, the thing this hook exists to prevent.
reset_src
advance_origin "future-stamp-case"
mkdir -p "$work/cache/ai-dev-baseline"
: > "$work/cache/ai-dev-baseline/session-currency.stamp"
touch -t 209901010000 "$work/cache/ai-dev-baseline/session-currency.stamp"
INTERVAL_ENV=3600
before="${ head_of; }"
run_hook startup
has "$OUT" 'updated' "a future-dated stamp does not wedge the rate limit off"
if [ "${ head_of; }" != "$before" ]; then ok; else bad "a future-dated stamp must not suppress the check"; fi
INTERVAL_ENV=""

# --- unsafe clone states are refused, and named ------------------------------
# The refusal itself is bin/baseline's (check-baseline.sh owns that); what is asserted here is
# that the hook surfaces WHICH state, rather than failing silently or claiming success.
# refused <expected-word> <label>  — run against the clone as currently staged.
refused() {
  local before; before="${ head_of; }"
  run_hook startup
  eq "$RC" "0" "$2 → still exit 0"
  has "$OUT" "$1" "$2 → the line names $1"
  eq "${ head_of; }" "$before" "$2 → never fast-forwarded"
}

reset_src
advance_origin "dirty-case"
printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md"
refused dirty "dirty clone"

reset_src
advance_origin "rebase-case"
# A mid-rebase clone with a CLEAN tree: the case a porcelain check alone cannot see.
mkdir -p "$srcgit/rebase-merge"
refused in-progress "mid-rebase clone"
rm -rf "${srcgit:?}/rebase-merge"

reset_src
advance_origin "feature-branch-case"
git -C "$src" checkout -q -b feature-z
refused not-default "clone on a feature branch"

# --- lock contention ----------------------------------------------------------

reset_src
advance_origin "locked-case"
mkdir -p "$srcgit/adb-update.lock"
before="${ head_of; }"
run_hook startup
eq "$RC" "0" "another update holding the lock → exit 0"
eq "$OUT" "" "another update holding the lock → silent (the peer reports it)"
eq "${ head_of; }" "$before" "another update holding the lock → clone untouched"
rmdir "$srcgit/adb-update.lock"
# With the lock released, the very next run proceeds — the lock must not be sticky.
rm -rf "${work:?}/cache"
run_hook startup
has "$OUT" 'updated' "a released lock lets the next run proceed"

# --- modes --------------------------------------------------------------------

reset_src
advance_origin "mode-cases"
before="${ head_of; }"
MODE_ENV=off
run_hook startup
eq "$OUT" "" "mode=off → silent"
eq "${ head_of; }" "$before" "mode=off → clone untouched"

MODE_ENV=notify
rm -rf "${work:?}/cache"
run_hook startup
has "$OUT" 'behind' "mode=notify → reports that it is behind"
eq "${ head_of; }" "$before" "mode=notify → reports only, never pulls"

# notify reports `behind` and NOTHING ELSE. A clone deliberately parked on a branch (or left
# dirty) would otherwise produce an attention line at every startup past the rate limit, forever,
# for a state its owner created on purpose — in the very mode chosen to be quiet. Both
# templates/agents.toml and docs/installation.md define notify as reporting `behind` only.
for staged in dirty not-default; do
  reset_src
  advance_origin "notify-quiet-$staged"
  case "$staged" in
    dirty)       printf 'local edit\n' >> "$src/agents/claude/CLAUDE.md" ;;
    not-default) git -C "$src" checkout -q -b "notify-quiet-branch" ;;
  esac
  MODE_ENV=notify
  before_q="${ head_of; }"
  run_hook startup
  eq "$RC" "0" "mode=notify + $staged → exit 0"
  eq "$OUT" "" "mode=notify stays silent for $staged (only 'behind' is reported)"
  eq "${ head_of; }" "$before_q" "mode=notify + $staged → clone untouched"
done
reset_src
advance_origin "post-notify"
before="${ head_of; }"

MODE_ENV=nonsense
rm -rf "${work:?}/cache"
run_hook startup
has "$OUT" 'updated' "an unrecognized mode degrades to the documented default (auto)"
MODE_ENV=""

# The mode is read from the GLOBAL manifest — and ONLY the global one.
reset_src
advance_origin "toml-off"
mkdir -p "$fh/.config/ai-dev-baseline"
printf '[updates]\nsession_start = "off"\n' > "$fh/.config/ai-dev-baseline/agents.toml"
before="${ head_of; }"
run_hook startup
eq "$OUT" "" "global agents.toml [updates] session_start=off → silent"
eq "${ head_of; }" "$before" "global agents.toml off → clone untouched"
printf '[updates]\nsession_start = "auto"\n' > "$fh/.config/ai-dev-baseline/agents.toml"
rm -rf "${work:?}/cache"
run_hook startup
has "$OUT" 'updated' "global agents.toml session_start=auto → updates"
rm -f "$fh/.config/ai-dev-baseline/agents.toml"

# The hook must read the file install.sh WRITES. install.sh (and role-dispatch.sh) spell that
# path as $HOME/.config/... with no XDG involvement; a reader that honored XDG_CONFIG_HOME would
# consult a file nobody writes, so `[updates] session_start` would silently do nothing on any box
# where that variable is set — the exact class of failure this feature exists to remove.
reset_src
advance_origin "xdg-decoy"
mkdir -p "$work/xdg-decoy/ai-dev-baseline" "$fh/.config/ai-dev-baseline"
printf '[updates]\nsession_start = "off"\n'  > "$work/xdg-decoy/ai-dev-baseline/agents.toml"
printf '[updates]\nsession_start = "auto"\n' > "$fh/.config/ai-dev-baseline/agents.toml"
XDG_CONFIG_ENV="$work/xdg-decoy"
before="${ head_of; }"
run_hook startup
has "$OUT" 'updated' "the mode is read from \$HOME/.config — an XDG_CONFIG_HOME decoy is ignored"
if [ "${ head_of; }" != "$before" ]; then ok; else bad "an XDG_CONFIG_HOME decoy must not disable the updater"; fi
XDG_CONFIG_ENV=""
rm -f "$fh/.config/ai-dev-baseline/agents.toml"

# A PROJECT agents.toml must never steer the global updater.
reset_src
advance_origin "project-toml-ignored"
proj="$work/proj"; mkdir -p "$proj"; git init -q "$proj"
printf '[updates]\nsession_start = "off"\n' > "$proj/agents.toml"
before="${ head_of; }"
run_hook startup "$proj"
if [ "${ head_of; }" != "$before" ]; then ok; else bad "a project agents.toml must not disable the global updater"; fi

# --- a same-HEAD repair still reports, and asks for a reload -------------------
# The clone is current but an installed link is broken: `baseline update` repairs it and returns
# 6 without moving HEAD. A hook that inferred "something changed" from the HEAD delta alone would
# exit silently, leaving the skill that was missing when the session initialized still missing.
reset_src
rm -f "$fh/.claude/skills/demo"                       # break an installed link
ln -s "$src/agents/claude/skills/gone" "$fh/.claude/skills/demo"
head_repair="${ head_of; }"
run_hook startup
eq "$RC" "0" "same-HEAD repair → exit 0"
has "$OUT" 'repaired' "same-HEAD repair is reported, not silently swallowed"
# The exit code the hook keys off — distinct from 0 ("nothing to do"), which is what makes the
# repair observable to a caller that otherwise only watches HEAD.
rm -f "$fh/.claude/skills/demo"
ln -s "$src/agents/claude/skills/gone" "$fh/.claude/skills/demo"
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1
eq "$?" "6" "baseline update exits 6 on a successful same-HEAD repair"
HOME="$fh" "$src/bin/baseline" update >/dev/null 2>&1
eq "$?" "0" "a second run after the repair is a plain no-op (0)"
has "$OUT" '"reloadSkills":true' "same-HEAD repair asks the harness to reload skills"
eq "${ head_of; }" "$head_repair" "same-HEAD repair does not move HEAD"
rm -f "$fh/.claude/skills/demo"
ln -s "$src/agents/claude/skills/demo" "$fh/.claude/skills/demo"

# --- a repo-configured core.sshCommand is respected ---------------------------
# GIT_SSH_COMMAND outranks core.sshCommand, so setting it unconditionally would replace a
# configured identity file / proxy / custom ssh binary with plain `ssh` — the fetch then fails
# for a clone that works fine by hand, and exit 30 is deliberately silent, leaving the baseline
# stale with no explanation. Asserted by making the configured command the ONLY way to reach the
# origin: if the hook overrode it, the update could not happen.
reset_src
advance_origin "ssh-command-case"
before="${ head_of; }"
git -C "$src" config core.sshCommand "ssh -o BatchMode=yes"
run_hook startup
if [ "${ head_of; }" != "$before" ]; then ok; else bad "a clone with core.sshCommand must still update"; fi
hasnt "$OUT" 'needs attention' "core.sshCommand does not turn the update into an attention line"
git -C "$src" config --unset core.sshCommand

# --- no install, and an incomplete install ------------------------------------

empty="$work/emptyhome"; mkdir -p "$empty"
OUT="$(printf '%s' "$(jq -cn '{hook_event_name:"SessionStart",source:"startup",cwd:"/"}')" \
      | env HOME="$empty" XDG_CACHE_HOME="$work/cache2" XDG_CONFIG_HOME="$empty/.config" \
        ADB_SESSION_UPDATE="" ADB_SESSION_UPDATE_INTERVAL_SECS="" bash "$HOOK" 2>/dev/null)"; RC=$?
eq "$RC" "0" "no installed baseline → exit 0"
eq "$OUT" "" "no installed baseline → silence"

# The shared library missing beside the script (an incomplete install) must be silent, not a
# crash: the hook cannot read config or resolve the source without it.
lonely="$work/lonely"; mkdir -p "$lonely"
cp "$ROOT/agents/claude/scripts/session-currency.sh" "$lonely/session-currency.sh"
OUT="$(printf '%s' "$(jq -cn '{hook_event_name:"SessionStart",source:"startup",cwd:"/"}')" \
      | env HOME="$fh" XDG_CACHE_HOME="$work/cache3" XDG_CONFIG_HOME="$fh/.config" \
        ADB_SESSION_UPDATE="" ADB_SESSION_UPDATE_INTERVAL_SECS="" bash "$lonely/session-currency.sh" 2>/dev/null)"; RC=$?
eq "$RC" "0" "missing shared library → exit 0"
eq "$OUT" "" "missing shared library → silence"

# --- the wiring the installer must produce ------------------------------------

hooks_json="$ROOT/agents/claude/settings.hooks.json"
eq "$(jq -r '.SessionStart[0].matcher' "$hooks_json")" "startup" \
  "settings.hooks.json narrows SessionStart to the startup source"
eq "$(jq -r '.SessionStart[0].hooks[0].command' "$hooks_json")" \
  "__ADB_HOME__/.claude/scripts/session-currency.sh" "settings.hooks.json points at the hook"
# A bounded timeout is the far backstop behind the hook's own guards; the harness default (600s)
# would let a pathological start stall for ten minutes.
tmo="$(jq -r '.SessionStart[0].hooks[0].timeout' "$hooks_json")"
if [ "$tmo" -gt 0 ] && [ "$tmo" -le 120 ]; then ok; else bad "SessionStart timeout should be bounded and small (got $tmo)"; fi

# --- capturing what the installer SAID, not just whether it exited -------------
#
# Every install/uninstall call below is captured and asserted on BOTH streams AND the status.
# Asserting the status alone is not enough and the reason is a call-site constraint: `wire_hooks`
# (install.sh:175-220) has five WARN branches and one of them — missing `jq`, install.sh:176-180 —
# returns **0**, so the only known path to "nothing wired, install succeeded" is invisible to an
# rc check. Evidence and history: D87.
INSTALLER_OUT=""; INSTALLER_RC=0
# <label> is first so every call site reads the same way and `installer_clean` can forward "$@";
# this half only needs the last two.
run_installer() {   # run_installer <label> <home> <script> — capture both streams AND the status
  INSTALLER_OUT="$(HOME="$2" bash "$3" --agent claude 2>&1)"; INSTALLER_RC=$?
}

# installer_clean <label> <home> <script> — run it and require BOTH rc 0 and no WARN.
# installer_clean <label> <home> <script> — require BOTH rc 0 and no WARN.
#
# The `bad` text is ONE physical line on purpose: the CI digest (`selfcheck.sh --summarize`)
# carries a witness by its first line, so folding the transcript in would push the cause off the
# end of the digest that exists to show it. The transcript is not discarded either — command
# substitution captured it, so on failure this prints it once, indented, before the verdict.
installer_clean() {
  local label="$1" warns bad_rc=0
  run_installer "$@"
  [ "$INSTALLER_RC" -eq 0 ] || bad_rc=1
  warns="$(printf '%s\n' "$INSTALLER_OUT" | grep -c '^  WARN' || true)"
  if [ "$bad_rc" -eq 1 ] || [ "$warns" -ne 0 ]; then
    printf '  --- %s: full installer transcript (rc %s) ---\n' "$label" "$INSTALLER_RC" >&2
    printf '%s\n' "$INSTALLER_OUT" | sed 's/^/  | /' >&2
  fi
  if [ "$bad_rc" -eq 0 ]; then ok; else
    bad "$label: exited $INSTALLER_RC — $(printf '%s' "$INSTALLER_OUT" | grep -E '^  (WARN|ERROR)' | tr '\n' ' ')"
  fi
  if [ "$warns" -eq 0 ]; then ok; else
    bad "$label: exited $INSTALLER_RC but reported $warns WARN(s) — $(printf '%s' "$INSTALLER_OUT" | grep '^  WARN' | tr '\n' ' ')"
  fi
}

# THE REHEARSAL, on the exact shape that happened. The stub reproduces install.sh's tolerated
# degradation verbatim — the WARN text and the exit 0 are copied from the probe described above,
# not invented — because an assertion that has never been seen rejecting anything is a guard that
# reports safety it never checked (base/practices/self-review.md).
cat > "$work/warn-install.sh" <<'STUB'
#!/usr/bin/env bash
printf 'claude → (adapter)\n'
printf '  WARN   jq not found — cannot wire hooks; install jq and re-run, or wire manually\n'
exit 0
STUB
cat > "$work/fail-install.sh" <<'STUB'
#!/usr/bin/env bash
printf '  WARN   ~/.claude/settings.json is not valid JSON — hooks NOT wired\n'
exit 1
STUB
cat > "$work/ok-install.sh" <<'STUB'
#!/usr/bin/env bash
printf '  hooks  wired global Stop gates + SessionStart currency check\n'
exit 0
STUB
expect_rejection "installer_clean must REJECT rc 0 with a WARN (the 08-21 shape: missing jq, install.sh:176-180)" \
  installer_clean "rehearsal" "$work" "$work/warn-install.sh"
expect_rejection "installer_clean must REJECT a non-zero status" \
  installer_clean "rehearsal" "$work" "$work/fail-install.sh"
# ...and must ACCEPT a clean run, or it would be a guard that can only ever fail.
installer_clean "installer_clean accepts a clean install (rc 0, no WARN)" "$work" "$work/ok-install.sh"
# ...and the REHEARSAL PREDICATE is pinned in BOTH directions, because its failure mode is silence:
# a `rejects` stuck on true certifies every helper below it while checking nothing, and one stuck
# on false reddens the suite for no reason. Asserted on its STATUS, never by applying it to itself
# — self-application is circular, and a `rejects` that always answered "it rejected" would agree.
if rejects installer_clean "rehearsal" "$work" "$work/ok-install.sh"; then
  bad "rejects must NOT fire on a helper that ACCEPTS its input"
else ok; fi
if rejects installer_clean "rehearsal" "$work" "$work/warn-install.sh"; then ok
else bad "rejects must fire on a helper that REJECTS its input"; fi

# install → the entry is wired, user hooks survive, re-install does not double-add;
# uninstall → the entry is gone and no dangling command is left behind.
ih="$work/installhome"; mkdir -p "$ih/.claude"
jq -n '{hooks:{SessionStart:[{hooks:[{type:"command",command:"/usr/local/bin/my-own-hook.sh"}]}],
               Stop:[{hooks:[{type:"command",command:"/usr/local/bin/my-stop-hook.sh"}]}]}}' \
  > "$ih/.claude/settings.json"
installer_clean "install into a populated settings.json" "$ih" "$ROOT/install.sh"
eq "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | test("session-currency\\.sh$"))] | length' \
      "$ih/.claude/settings.json")" "1" "install wires exactly one SessionStart currency hook"
eq "$(jq '[.hooks.SessionStart[].hooks[] | select(.command == "/usr/local/bin/my-own-hook.sh")] | length' \
      "$ih/.claude/settings.json")" "1" "install preserves a user's own SessionStart hook"
eq "$(jq '[.hooks.Stop[].hooks[] | select(.command == "/usr/local/bin/my-stop-hook.sh")] | length' \
      "$ih/.claude/settings.json")" "1" "install preserves a user's own Stop hook"
installer_clean "re-install into the same HOME" "$ih" "$ROOT/install.sh"
eq "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | test("session-currency\\.sh$"))] | length' \
      "$ih/.claude/settings.json")" "1" "re-install does not double-add the SessionStart hook"
installer_clean "uninstall from a populated settings.json" "$ih" "$ROOT/uninstall.sh"
eq "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | test("session-currency\\.sh$"))] | length' \
      "$ih/.claude/settings.json")" "0" "uninstall removes the SessionStart hook (no dangling command)"
eq "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command == "/usr/local/bin/my-own-hook.sh")] | length' \
      "$ih/.claude/settings.json")" "1" "uninstall preserves the user's own SessionStart hook"

# An EMPTY settings.json is not valid JSON, but jq reads empty input as an empty STREAM: it exits
# 0 and prints nothing. A guard that only checks jq's status would then install a 0-byte file and
# report success — and that failure is self-entrenching, because bin/baseline's adb_hooks_wired
# would see no precommit-gate.sh, conclude the user chose --no-hooks, and pass --no-hooks to
# every future self-heal. The gates would never come back.
eh="$work/emptysettings"; mkdir -p "$eh/.claude"
: > "$eh/.claude/settings.json"
installer_clean "install into an EMPTY settings.json" "$eh" "$ROOT/install.sh"
if [ -s "$eh/.claude/settings.json" ]; then ok; else bad "install must never leave a 0-byte settings.json"; fi
eq "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | test("session-currency\\.sh$"))] | length' \
      "$eh/.claude/settings.json")" "1" "install wires the hook into a previously-empty settings.json"

# A settings.json that is not valid JSON must be left ALONE and must fail the install — reporting
# success there is enforcement silently off (bin/baseline's self-heal gates only on this status).
bh="$work/badsettings"; mkdir -p "$bh/.claude"
printf 'this is not json\n' > "$bh/.claude/settings.json"
# The one call that already asserted its status — and still discarded the WARN that says WHICH of
# wire_hooks' five branches refused. `no "$rc"` passes identically for "not valid JSON", "could not
# read settings.hooks.json" and "could not write", so a regression that swapped one refusal for
# another would be invisible here. Assert the branch, not just the rejection.
run_installer "install over a corrupt settings.json" "$bh" "$ROOT/install.sh"
no "$INSTALLER_RC" "install exits non-zero when settings.json is not valid JSON"
has "$INSTALLER_OUT" "is not valid JSON" \
  "...and SAYS which of wire_hooks' five refusals it was"
eq "$(cat "$bh/.claude/settings.json")" "this is not json" "a corrupt settings.json is left byte-identical"

# OWNERSHIP IS BY FULL PATH. A user's own hook that merely SHARES A FILENAME with one of ours
# must survive install and uninstall — including under an unrelated event, since the filters walk
# every hook key. A basename-anchored match would delete it.
uh="$work/userhook"; mkdir -p "$uh/.claude"
jq -n '{hooks:{
    PreToolUse:[{hooks:[{type:"command",command:"/custom/precommit-gate.sh"}]}],
    Stop:[{hooks:[{type:"command",command:"/custom/session-currency.sh"}]}]}}' \
  > "$uh/.claude/settings.json"
installer_clean "install into a HOME carrying same-named user hooks" "$uh" "$ROOT/install.sh"
eq "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command == "/custom/precommit-gate.sh")] | length' \
      "$uh/.claude/settings.json")" "1" "install keeps a same-named user hook under another event"
installer_clean "uninstall from a HOME carrying same-named user hooks" "$uh" "$ROOT/uninstall.sh"
eq "$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command == "/custom/precommit-gate.sh")] | length' \
      "$uh/.claude/settings.json")" "1" "uninstall keeps a same-named user hook under another event"
eq "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command == "/custom/session-currency.sh")] | length' \
      "$uh/.claude/settings.json")" "1" "uninstall keeps a same-named user hook under OUR event"
eq "$(jq '[.hooks[]?[]?.hooks[]? | select(.command | test("\\.claude/scripts/session-currency\\.sh$"))] | length' \
      "$uh/.claude/settings.json")" "0" "uninstall still removes our own entry"

check_summary "session-currency"
