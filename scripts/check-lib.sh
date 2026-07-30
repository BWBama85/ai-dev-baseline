# shellcheck shell=bash
# ai-dev-baseline — shared helpers for the check-*.sh scripts. In a repo whose thesis is
# single-source, its own checks shouldn't grow copy-pasted scaffolds — so all three cooperating
# helper sets live here once and every check sources what it needs:
#
#   1. grep-assert family (below) — check_init / req_fixed / req_regex / check_fail /
#      check_result: many assertions collapse to ONE boolean verdict (the anti-drift lints).
#   2. unit-test assertion family (§ further down) — ok / bad / bad_quiet / eq / yes / no /
#      has / hasnt + a pass/fail COUNTER + check_summary: the *.sh unit tests.
#   3. git fixture helpers (§ further down) — check_git + check_make_repo_pair: the throwaway
#      identity wrapper and the local+bare-origin scaffold, accounting-neutral so either family
#      can guard them.
#   4. PR reviewer-signal payload builders (§ further down) — check_pr_reviews_json and friends:
#      the four GitHub response SHAPES both PR-guard suites stub.
#
# Sourced, never executed. Lives OUTSIDE scripts/lib/ on purpose: install.sh symlinks the whole
# scripts/lib dir into ~/.<agent>/scripts/lib, and check/test code must not ship into a user's
# runtime.
#
# Families 1 and 2 keep SEPARATE state (CHECK_FAIL/CHECK_LABEL vs pass/fail) and never collide;
# a single check may use one, or both (e.g. check-cleanup-enum.sh uses grep-assert accounting
# AND the git fixture). Callers touch state only through these functions, never the vars — so
# ShellCheck sees no SC2154 / "unused" false positives across the source boundary.
#
# --- grep-assert family: check_init "<name>" sets the message prefix, req_fixed / req_regex
# (or check_fail directly) accumulate into CHECK_FAIL, and check_result emits the PASS line and
# returns the status.

CHECK_LABEL="check"
CHECK_FAIL=0

# Name this check (used as the diagnostic prefix and in the PASS line).
check_init() { CHECK_LABEL="$1"; }

# Emit a diagnostic line, prefixed with the check's name.
check_note() { printf '%s: %s\n' "$CHECK_LABEL" "$*" >&2; }

# Mark the run failed.
check_fail() { CHECK_FAIL=1; }

# Assert a FIXED string is present in a file. Usage: req_fixed <file> <token> <fact-label>
req_fixed() {
  if [ ! -f "$1" ]; then check_note "[$3] file not found: $1"; check_fail; return; fi
  grep -Fq -- "$2" "$1" || { check_note "[$3] canonical token '$2' missing from $1"; check_fail; }
}

# Assert an EXTENDED-REGEX pattern matches in a file. Usage: req_regex <file> <pattern> <fact-label>
req_regex() {
  if [ ! -f "$1" ]; then check_note "[$3] file not found: $1"; check_fail; return; fi
  grep -Eq -- "$2" "$1" || { check_note "[$3] canonical pattern /$2/ missing from $1"; check_fail; }
}

# Assert an EXTENDED-REGEX pattern does NOT match in a file, reporting the offending lines.
# Usage: req_absent <file> <pattern> <fact-label>
#
# The counterpart to req_regex, for a fact that SUPERSEDES an earlier value. Positive presence
# alone cannot catch a file that carries the new value AND quietly keeps the old one next to it —
# it satisfies req_regex and still misinforms every reader (#93). A missing file is NOT a failure
# here: absence-in-a-nonexistent-file is vacuously true, and the positive rules already fail loudly
# on a bad path, so duplicating that would double-report one typo.
req_absent() {
  [ -f "$1" ] || return 0
  if grep -Eq -- "$2" "$1"; then
    check_note "[$3] superseded pattern /$2/ still present in $1:"
    grep -En -- "$2" "$1" | sed 's/^/    /' >&2
    check_fail
  fi
}

# Emit the terminal result and return 0 (pass) / 1 (fail). Usage: check_result "<pass note>"
check_result() {
  if [ "$CHECK_FAIL" -eq 0 ]; then
    echo "$CHECK_LABEL: PASS${1:+ ($1)}"
    return 0
  fi
  echo "$CHECK_LABEL: FAIL — see the diagnostics above" >&2
  return 1
}

# --- unit-test assertion family (ok/bad/eq/yes/no/has/hasnt + pass/fail counter) --------------
# A SECOND, independent accounting style for the *.sh unit tests (check-common-lib,
# check-baseline, check-gates, check-precommit-gate, check-implement-gate, check-install-migration,
# check-install-guard). They count INDIVIDUAL assertions, where the grep-assert family above
# tracks a single boolean. Each test used to carry a byte-identical copy of these helpers; they
# live here once and every test sources them. Callers touch pass/fail ONLY through ok / bad /
# bad_quiet / check_summary — never the bare vars — so the two accounting styles never collide
# and ShellCheck sees no SC2154 across the source boundary.
pass=0
fail=0

# Count one passing assertion.
ok()   { pass=$((pass + 1)); }
# Count one failing assertion AND print a FAIL diagnostic.
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
# Count one failing assertion WITHOUT printing — for callers that already emitted their own
# (possibly multi-line) diagnostic and only need the failure recorded.
bad_quiet() { fail=$((fail + 1)); }

# eq <actual> <expected> <label> — string equality.
eq()   { if [ "$1" = "$2" ]; then ok; else bad "$3: got [$1] want [$2]"; fi; }
# yes <rc> <label> — assert an already-captured status is success. Call as: cmd; yes $? "label"
yes()  { if [ "$1" -eq 0 ]; then ok; else bad "$2 (expected success, rc=$1)"; fi; }
# no <rc> <label> — assert an already-captured status is failure.
no()   { if [ "$1" -ne 0 ]; then ok; else bad "$2 (expected failure, rc=$1)"; fi; }
# has <haystack> <needle> <label> — assert needle is a substring of haystack.
has()  { case "$1" in *"$2"*) ok ;; *) bad "$3: [$1] missing [$2]" ;; esac; }
# hasnt <haystack> <needle> <label> — assert needle is NOT a substring of haystack.
hasnt() { case "$1" in *"$2"*) bad "$3: [$1] unexpectedly contains [$2]" ;; *) ok ;; esac; }

# check_summary <name> — emit the terminal "<name>: N passed, M failed" line, then exit 1 if any
# assertion failed, else print "<name>: PASS". Callers end with this instead of re-reading
# $pass/$fail (which would trip SC2154, since ShellCheck does not follow the sourced file).
check_summary() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  echo "$1: PASS"
}

# --- git fixture helpers (identity wrapper + local+bare-origin pair) --------------------------
# The check-*.sh tests each hand-rolled the same "git with a throwaway identity" wrapper and the
# same "bare origin + local repo wired to it" scaffold. Centralize only the BOILERPLATE; each
# test keeps its own topology (branch names, origin/HEAD form, merge shape, push sequence).

# check_copy_worktree <src> <dest> — copy a whole working tree (dotfiles included) into <dest>,
# creating it, then drop the copied `.git`. The ONE home for the throwaway-tree-copy move, now that
# three suites need it: the installer fail-loud test, the fact-drift mutation mode, and its guard
# suite. A fourth open-coded copy is how the "faithful copier" details drift — `cp -R .` from
# inside <src> is deliberate (it takes the CONTENTS, dotfiles included, and preserves symlinks and
# modes on both BSD and GNU), and `git ls-files | cp` is deliberately NOT used: it needs `-z`,
# per-file `mkdir -p`, and a policy for tracked-but-deleted paths, and it silently misses anything
# uncommitted — which is the whole reason these suites copy the tree instead of cloning HEAD.
#
# Dropping `.git` is for speed (this repo's is ~27 MB), and it means the copy is NOT a git repo:
# code under test that shells out to git must tolerate that. Returns non-zero WITHOUT exiting so a
# `set -u` caller can guard it.
check_copy_worktree() {
  mkdir -p "$2" || return 1
  ( cd "$1" && cp -R . "$2" ) || return 1
  rm -rf "$2/.git"
}

# check_git <dir> <git-args...> — run git in <dir> with a fixed throwaway identity and signing
# OFF, so a contributor whose global config sets commit.gpgsign=true still gets clean, unsigned
# fixture commits. Use for EVERY commit-producing fixture git call (this is what closes the
# signing gap the per-file wrappers left in some tests).
check_git() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# check_wf_snippet <workflow-file> <name> — print the fenced bash between `# ADB-SNIPPET: <name>`
# and the closing fence. The ONE home for the marker/closing-fence contract: three suites execute
# documented workflow snippets (check-roadmap.sh, check-roadmap-e2e.sh, check-cleanup.sh), and three
# copies of this awk meant a change to the marker convention had to be found in three places with
# nothing checking they agreed. Prints nothing when the marker is absent, so callers guard on empty.
check_wf_snippet() {
  awk -v want="$2" '
    $0 ~ ("^[[:space:]]*# ADB-SNIPPET: " want "$") { inb = 1; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { exit }
    inb { print }
  ' "$1"
}

# check_actions_slug — set ACTIONS_SLUG from its one home, `adb_actions_app_slug` in common.sh.
# The ONE home for how a suite reaches into common.sh for that value: three suites build check-run
# fixtures (check-roadmap.sh, check-roadmap-e2e.sh, check-repo-settings.sh), and each hard-coding
# the slug is exactly what let #179 ship — the fixtures asserted the code's belief rather than the
# API's behavior, so a value GitHub never returns stayed green in every suite.
#
# Sources in a SUBSHELL so the suite does not inherit common.sh's other definitions, and FATALs on
# an empty result: a silently-empty slug would make every fixture default to `app.slug: ""`, which
# is the unknown-provenance shape — the suites would then pass while testing the wrong thing.
# The exit must live here rather than inside a command substitution, or it would only kill the
# subshell and the suite would carry on with an empty value.
check_actions_slug() {
  ACTIONS_SLUG="$(. scripts/lib/common.sh >/dev/null 2>&1; adb_actions_app_slug)"
  [ -n "$ACTIONS_SLUG" ] || {
    echo "${CHECK_LABEL:-check}: FATAL — adb_actions_app_slug is unavailable or empty" >&2; exit 1; }
}

# canon <dir> — the physical (symlink-resolved) absolute path of <dir>, mirroring what code that
# uses `git rev-parse --show-toplevel` / `pwd -P` compares against. On macOS a mktemp dir is
# /var/… while its physical form is /private/var/…; without canonicalizing, a naive path assertion
# would flap. Used by repo-shape tests (adb_repo_shape / bin/agent-init). Prints nothing if <dir>
# is unreadable. Usage: expected="$(canon "$fixture")"
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# check_make_repo_pair <local_dir> <bare_dir> — init a bare origin, init a local repo (its dir
# may already contain files), stamp the local's throwaway identity + signing-off config, and
# wire `origin` to the bare repo. It deliberately does NOT commit, branch, push, or set
# HEAD/symref — those differ per test and stay caller-owned (a caller then commits via check_git
# or its own subshell git, whose identity the config above already covers). Returns non-zero
# WITHOUT exiting on any failure, so a `set -u` caller can guard it:
#   check_make_repo_pair "$local" "$bare" || { bad "fixture init failed"; }
check_make_repo_pair() {
  git init -q --bare "$2" || return 1
  git init -q "$1" || return 1
  git -C "$1" config user.email t@t || return 1
  git -C "$1" config user.name  t   || return 1
  git -C "$1" config commit.gpgsign false || return 1
  git -C "$1" remote add origin "$2" || return 1
}

# --- PR reviewer-signal payload builders (#167) ------------------------------------------------
# The four GitHub response shapes the two PR-guard suites stub. They live here rather than in each
# suite because BOTH now exercise ONE shared classifier (`adb_reviewer_evidence` /
# `adb_reviewer_classes` / `adb_head_anchor` in common.sh): with a copy per suite, a change to the
# record shape has no single place to be made, and one suite can stay green against a payload the
# other no longer produces. That is the same two-copies-diverge failure #167 and #173 were filed to
# fix — which makes duplicating it in the tests of the fix a poor trade.
#
# Each takes the destination path first, so a suite can write a default fixture, a page-two fixture
# or a per-poll fixture with the same builder. What stays per-suite is everything genuinely local:
# the `gh` stub's routing and knobs, the PR object (whose fields differ — pr-watch needs state and
# merged_at), the poll counter, and the timestamp constants each suite reads its own scenarios by.

# check_pr_reviews_json <out> <login> <state> <sha> [...] — one review object per triple.
check_pr_reviews_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg st "$2" --arg sha "$3" \
            '. + [{user:{login:$l,type:"Bot"},state:$st,commit_id:$sha}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_comments_json <out> <login> <created_at> [...] — one ISSUE COMMENT per pair. This is the
# Codex connector's "task mode" output: a single comment, no review object, no inline threads.
check_pr_comments_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 2 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg at "$2" \
            '. + [{user:{login:$l},created_at:$at,body:"### Summary"}]')"
    shift 2
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_reactions_json <out> <login> <content> <created_at> [...] — one reaction per triple.
# NOTE the reactions endpoint reports `type: "User"` for the Codex connector while reviews report
# `type: "Bot"` for the same App, which is why no builder here sets a discriminating type on it.
check_pr_reactions_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg l "$1" --arg c "$2" --arg at "$3" \
            '. + [{user:{login:$l},content:$c,created_at:$at}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_activity_json <out> <after-sha> <ref> <timestamp> [...] — one repository-activity record
# per triple, in the newest-first order the API returns them. This is the SERVER-ASSIGNED anchor
# #175/D19 replaced the client-supplied committer date with, so its shape is the one most worth
# having in a single place: `adb_head_anchor` selects on `.after`, `.ref` and `.timestamp`.
check_pr_activity_json() {
  local out="$1"; shift
  local acc="[]"
  while [ "$#" -ge 3 ]; do
    acc="$(printf '%s' "$acc" | jq -c --arg sha "$1" --arg ref "$2" --arg at "$3" \
            '. + [{activity_type:"push", ref:$ref, before:"0000000000000000000000000000000000000000",
                   after:$sha, timestamp:$at}]')"
    shift 3
  done
  printf '%s\n' "$acc" > "$out"
}

# check_pr_called <calls-file> <substring> — did any recorded `gh api` call address <substring>?
# Both suites record every call so they can prove NEGATIVES: that the head-commit endpoint is never
# read (the client-supplied date #175 removed), and that the ref-activity read is not paid for when
# no date-scoped signal needs dating.
check_pr_called() { [ -f "$1" ] && grep -q -- "$2" "$1"; }
