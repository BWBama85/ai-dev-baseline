# shellcheck shell=bash
# ai-dev-baseline — shared shell primitives (the ONE home).
#
# This library is the single implementation of the small shell primitives that
# otherwise get copy-pasted across the installer, uninstaller, per-agent adapters,
# agent-init, and the runtime gates. The framework's whole thesis is single-source +
# no-drift (docs/design-principles.md); this file is that thesis applied to its own
# shell code.
#
# It is SOURCED, never executed. Two execution contexts source it:
#   - install-time (runs from the repo): install.sh, uninstall.sh,
#     agents/<agent>/adapter.sh, bin/agent-init — source "$REPO/scripts/lib/common.sh".
#   - runtime (installed under ~/.<agent>/scripts/lib/): project-gates.sh,
#     precommit-gate.sh, implement-issue-gate.sh — source it as a sibling, because
#     install.sh symlinks the whole scripts/lib/ dir into ~/.<agent>/scripts/lib/.
#
# Contract, so a sourced library never surprises its caller:
#   - Portable to macOS bash 3.2 (no mapfile, no readlink -f, no associative arrays).
#   - Passes shellcheck --severity=warning -e SC1091.
#   - Depends on NO caller globals (REPO / BACKUP_DIR / HOME-relative state) — every
#     input is a function argument. ($HOME is read only to prettify log paths.)
#   - Sets NO shell options (no set -e/-u/pipefail) — it must not mutate the caller's
#     shell. It is written to be safe under a caller's `set -u`.

# Guard against double-sourcing (e.g. precommit-gate.sh sources this AND then sources
# project-gates.sh, which sources it again). Idempotent: the second source returns
# immediately, so function definitions are never re-run.
if [ -n "${_ADB_COMMON_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_ADB_COMMON_SH_LOADED=1

# --- logging -----------------------------------------------------------------

# Print a status line. The one print helper, so even this trivial wrapper has a home.
adb_info() { printf '%s\n' "$*"; }

# Print a CLI's --help text from its own top comment block: skip the shebang (NR==1), strip a
# leading "# ", stop at the first non-comment line (so internal section comments never leak). The
# ONE home for this idiom — bin/baseline and scripts/lib/skill-compose.sh both call it with their
# own file rather than each carrying a copy. Usage: adb_usage <file>   (e.g. adb_usage "$0")
adb_usage() { awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"; }

# --- symlink install / uninstall --------------------------------------------

# Back up an existing path (unless it is already our correct symlink), then symlink.
# Usage: adb_link <src> <dest> <backup_dir>
#   - dest is already the correct symlink → no-op.
#   - dest is a symlink elsewhere        → replace it.
#   - dest is a real file/dir            → move it under backup_dir (mirrored absolute
#                                          path) before linking.
# Idempotent: running twice produces the same end state with no duplicate backups.
#
# Fail-loud source guard (#48): if <src> does not exist (or is a dangling symlink), refuse
# LOUDLY and return non-zero WITHOUT touching <dest> — no backup, no removal, no link. A bad
# manifest entry must never silently leave a dangling install link or clobber a real dest; the
# caller propagates this status so the top-level installer exits non-zero (see install.sh).
adb_link() {
  local src="$1" dest="$2" backup_dir="$3"
  if [ ! -e "$src" ]; then
    printf 'adb_link: source does not exist: %s — refusing to link %s (dest left untouched)\n' \
      "$src" "$dest" >&2
    return 1
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      adb_info "  ok     ${dest/#$HOME/~}"
      return
    fi
    rm -f "$dest"
  elif [ -e "$dest" ]; then
    mkdir -p "$backup_dir$(dirname "$dest")"
    mv "$dest" "$backup_dir$dest"
    adb_info "  backup ${dest/#$HOME/~} → ${backup_dir/#$HOME/~}$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  adb_info "  link   ${dest/#$HOME/~} → ${src/#$HOME/~}"
}

# Remove dest ONLY if it is a symlink pointing back inside repo. Never deletes a real
# file or a symlink to somewhere else.
# Usage: adb_unlink_if_ours <dest> <repo>
adb_unlink_if_ours() {
  local dest="$1" repo="$2"
  if [ -L "$dest" ]; then
    case "$(readlink "$dest")" in
      "$repo"/*) rm -f "$dest"; adb_info "  unlink ${dest/#$HOME/~}" ;;
      *)         adb_info "  skip   ${dest/#$HOME/~} (not ours)" ;;
    esac
  else
    adb_info "  skip   ${dest/#$HOME/~} (not a symlink)"
  fi
}

# --- install manifest (the ONE enumeration of the install surface) -----------

# Print the install manifest for ONE agent token as TAB-separated "<src>\t<dest>" lines,
# given a repo/source root and a target home. This is the SINGLE source of what the install
# links (#48): install.sh + the per-agent adapters consume it to CREATE the links; uninstall.sh
# consumes the <dest> column to remove them; bin/baseline consumes it to VERIFY them. Because
# all four read the same producer, the create-set, remove-set, and verify-set can never drift
# (a path added/moved here changes every consumer at once).
#
# Spelling is canonical: absolute <src> with NO trailing slash (so bin/baseline's exact-readlink
# idempotency check is stable). scripts/lib is linked at its CANONICAL path (not the pre-#34
# compat shim) — a plain `git pull` keeps old installs working via that shim, and a re-run
# self-heals them to this direct link. Paths are assumed free of tabs/newlines (unsupported).
# An unknown token prints nothing (return 0). Usage: adb_agent_manifest <agent> <repo> <home>
# Emit "<src-skill-dir>\t<dest-parent>/<name>" manifest lines for every rendered skill folder
# under <src-skills-dir>. The ONE place the skill-folder enumeration convention lives (glob
# dirs; unmatched glob stays literal and is filtered by -d; canonical trailing-slash-free src
# so bin/baseline's exact-readlink idempotency check stays stable) — every agent's branch of
# adb_agent_manifest calls this rather than re-inlining the loop. Usage:
#   _adb_skill_manifest_lines <src-skills-dir> <dest-skills-parent>
_adb_skill_manifest_lines() {
  local src_dir="$1" dest_parent="$2" d sdir
  for d in "$src_dir"/*/; do
    [ -d "$d" ] || continue
    sdir="${d%/}"
    printf '%s\t%s\n' "$sdir" "$dest_parent/${sdir##*/}"
  done
}

# The Claude scripts that install.sh WIRES into ~/.claude/settings.json as lifecycle hooks,
# one per line. The ONE enumeration of the baseline-owned hook set: adb_agent_manifest links
# them, install.sh's wire filter and uninstall.sh's unwire filter both match on exactly these
# basenames, and a new hook is added here alone. Deliberately NOT the same list as the manifest's
# script set — statusline.sh is installed but is not a hook, and matching it in the hook filters
# would strip an unrelated settings key.
adb_claude_hook_scripts() {
  printf 'precommit-gate.sh\nimplement-issue-gate.sh\nsession-currency.sh\nstate-claim-gate.sh\n'
}

# The jq regex matching a hook command that is EXACTLY one of the commands this install writes,
# for the given <home> — e.g. `^/Users/x/\.claude/scripts/(precommit-gate|…)\.sh$`. install.sh
# uses it to replace only baseline-owned entries and uninstall.sh to remove exactly those;
# deriving both from one place means adding a hook to adb_claude_hook_scripts updates both.
#
# FULL PATH, not a basename. A basename-anchored pattern (`…\.sh$`) also matches a user's own
# `/custom/precommit-gate.sh`, and because the filters walk EVERY hook event, uninstall would
# delete that entry — and the whole group containing it — under an unrelated event such as
# PreToolUse. That directly contradicts the promise that a user's own hooks survive. A command at
# any other path is by definition not ours, so the exact path we install is the ownership test.
# Usage: adb_claude_hook_regex <home>
adb_claude_hook_regex() {
  local home="$1" s alt="" esc
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    alt="${alt:+$alt|}${s%.sh}"
  done <<EOF
$(adb_claude_hook_scripts)
EOF
  # Escape regex metacharacters in the home path — a literal `.` in a username would otherwise
  # match any character, widening ownership beyond this install.
  esc="$(printf '%s' "$home" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
  printf '^%s/\\.claude/scripts/(%s)\\.sh$' "$esc" "$alt"
}

adb_agent_manifest() {
  local agent="$1" repo="$2" home="$3" s
  case "$agent" in
    claude)
      printf '%s\t%s\n' "$repo/agents/claude/CLAUDE.md" "$home/.claude/CLAUDE.md"
      _adb_skill_manifest_lines "$repo/agents/claude/skills" "$home/.claude/skills"
      # Every wired hook, plus the one installed-but-not-wired script (the statusline). Fed
      # through a heredoc rather than an unquoted `$(…)` so no word-splitting is relied on.
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '%s\t%s\n' "$repo/agents/claude/scripts/$s" "$home/.claude/scripts/$s"
      done <<EOF
$(adb_claude_hook_scripts)
statusline.sh
EOF
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.claude/scripts/lib"
      ;;
    codex)
      printf '%s\t%s\n' "$repo/agents/codex/AGENTS.md" "$home/.codex/AGENTS.md"
      # Rendered workflow skills (agent-skills SKILL.md folders) → Codex's skills dir, which
      # discovers ~/.codex/skills/<name>/SKILL.md.
      _adb_skill_manifest_lines "$repo/agents/codex/skills" "$home/.codex/skills"
      # The shared, agent-neutral gate runner (project-gates.sh + common.sh) so a rendered
      # workflow's {{GATE_RUNNER}} step (bash "$HOME/.codex/scripts/lib/project-gates.sh" run)
      # actually resolves. This is the runner only — NOT the Claude Stop-hook enforcement
      # (that per-agent equivalent is #14). Same source dir the claude branch links.
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.codex/scripts/lib"
      ;;
    gemini)
      printf '%s\t%s\n' "$repo/agents/gemini/GEMINI.md" "$home/.gemini/GEMINI.md"
      # Rendered workflow skills → Antigravity's GLOBAL customization root, ~/.gemini/config/
      # (agy discovers skills/<name>/SKILL.md there; confirmed in agy's own bundled
      # agy-customizations docs). The scripts/lib runner lives beside the other agents' at
      # ~/.gemini/scripts/lib so {{GATE_RUNNER}} resolves — see the codex note above.
      _adb_skill_manifest_lines "$repo/agents/gemini/skills" "$home/.gemini/config/skills"
      printf '%s\t%s\n' "$repo/scripts/lib" "$home/.gemini/scripts/lib"
      ;;
  esac
}

# Consume a manifest (TAB-separated "<src>\t<dest>" lines on stdin) and adb_link each entry,
# so column parsing lives in ONE place (install.sh and the adapters both call this rather than
# re-interpreting the columns). Accumulates failures: returns non-zero iff ANY line failed —
# a missing source (adb_link's guard) or a malformed line — so a caller propagates a single
# exit status. A blank line is skipped; a line missing either column is a hard failure (a
# malformed manifest must never silently link nothing). Usage: adb_link_manifest <backup_dir>
adb_link_manifest() {
  local backup_dir="$1" tab src dest rc=0
  tab="$(printf '\t')"
  while IFS="$tab" read -r src dest; do
    [ -n "$src$dest" ] || continue
    if [ -z "$src" ] || [ -z "$dest" ]; then
      printf 'adb_link_manifest: malformed manifest line (want <src>TAB<dest>): [%s|%s]\n' \
        "$src" "$dest" >&2
      rc=1; continue
    fi
    adb_link "$src" "$dest" "$backup_dir" || rc=1
  done
  return "$rc"
}

# Consume a manifest (TAB-separated "<src>\t<dest>" lines on stdin) and adb_unlink_if_ours each
# <dest> — the remove-side mirror of adb_link_manifest, so uninstall parses the manifest columns
# in the SAME one place install does (no drift between what is linked and what is removed). Only
# the <dest> column is used; ownership scoping is adb_unlink_if_ours's job (never removes a real
# file or a link pointing elsewhere). Usage: adb_unlink_manifest <repo>
adb_unlink_manifest() {
  local repo="$1" tab dest
  tab="$(printf '\t')"
  while IFS="$tab" read -r _ dest; do
    [ -n "$dest" ] || continue
    adb_unlink_if_ours "$dest" "$repo"
  done
}

# --- gh ----------------------------------------------------------------------

# adb_require_gh [extra-tool…] — assert `gh` (plus any named extra tools) are present and gh is
# authenticated. The ONE home for the "fail loud before any API call" preamble every gh-backed
# module needs: a missing or unauthenticated gh must never degrade into a silent no-op that then
# reports success.
#
# Honors the sourced-library contract above: it RETURNS non-zero (never `exit`s out of the
# caller's shell) and prints its diagnostic to stderr, so each caller decides whether to exit.
# The brew-prefix PATH nudge is here too — non-interactive shells routinely lack it.
adb_require_gh() {
  local tool
  command -v gh >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh not found on PATH" >&2; return 1; }
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; return 1; }
  done
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)" >&2; return 1; }
}

# adb_repo_slug — print the current repo's owner/name, resolved from the gh remote and cached for
# the process. Returns non-zero (printing nothing) when there is no resolvable GitHub remote.
_ADB_REPO_SLUG=""
adb_repo_slug() {
  if [ -z "$_ADB_REPO_SLUG" ]; then
    _ADB_REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
      || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; return 1; }
    [ -n "$_ADB_REPO_SLUG" ] \
      || { echo "ERROR: not inside a GitHub repo (no resolvable remote)" >&2; return 1; }
  fi
  printf '%s' "$_ADB_REPO_SLUG"
}

# adb_actions_app_slug — print the `app.slug` that GitHub Actions stamps on every check run it
# produces. THE ONE HOME for that value (#179): two libraries decide "did Actions report here?"
# and both must mean the same thing by it.
#
# The value is `github-actions`, and the wrong one is not a typo anybody would catch by reading:
# the app's OWNER login is `github`, its name is "GitHub Actions", and its slug is `github-actions`
# (app id 15368, https://github.com/apps/github-actions). Both consumers shipped with `github`,
# which matches NOTHING — so `branch-health` could never return `green` on an Actions repo (a
# release the convention can never cut) and `required-drift`'s provenance check silently found no
# Actions contexts (a fail-OPEN in the lint that exists to catch a gate that stopped gating).
#
# Deliberately a SCALAR accessor rather than a shared jq predicate, and the reason is the THIRD
# consumer. A jq module (`jq -L`) or a `def` string concatenated into each program would both work
# for the two shell libraries — that much is cheap and needs no eval. But `base/workflows/roadmap.md`
# also attributes check runs, and it is PROSE AN AGENT PASTES INTO A SHELL: it can receive a value,
# never a library. The only surface all three consumers share is the string itself, so that is what
# is shared, passed in as a typed `--arg` where a jq program is involved.
#
# Matched EXACTLY, and never widened to `app.owner.login == "github"` or to the numeric app id.
#
# GitHub documents `slug` as a name-derived URL slug rather than a permanent cross-GHES constant,
# so an unrecognized value must fall through to each caller's fail-closed path (unknown
# provenance), never be guessed at by a second, looser rule.
#
# Callers MUST reject an empty result rather than passing it through: both consumers normalize a
# missing slug to "" before comparing, so an empty expected value silently means "match the check
# runs nobody could attribute" — fail-open in `branch-health`, which gates a release cut.
adb_actions_app_slug() { printf 'github-actions'; }

# --- PR arguments and repository identity (#173) ------------------------------
#
# THE ONE HOME for the four primitives `pr-review.sh` (#134) and `pr-watch.sh` (#49) each carried
# a private copy of. The copies were not merely redundant, they had already DIVERGED into a live
# fail-open: pr-watch grew a three-form URL parser after review, pr-review kept its one-form
# original, and so `pr-review.sh gate --pr github.com/other/repo/pull/7` — an ordinary browser
# copy-paste, scheme dropped — produced an EMPTY wanted slug, skipped the cross-repo refusal
# entirely, answered about THIS repo's #7, and printed a head SHA that `/implement-issue` step 10
# then armed `gh pr merge --auto` against. A guard whose whole job is to refuse authorized an arm
# on a pull request the operator never named. That is the argument for one home, made by the code.

# adb_is_repo_slug <value> — true iff <value> is an `owner/repo` pair: exactly one slash, both
# halves non-empty. The ONE home for that shape test, because three callers need it and each one
# fails DIFFERENTLY without it — a malformed slug is not merely untidy:
#   * adb_pr_slug     — `https://github.com/pull/7` parses to `/github.com` under the glob forms
#                       below (the leading `*/` eats the scheme), which is not a repository at all.
#                       Left unvalidated it makes that argument look like it named one.
#   * adb_pr_slug_check — an observed `acme` or `acme/widget/extra` compares unequal to every real
#                       slug, so a BROKEN response would be reported as "a different repository".
#   * adb_git_origin_slug — a remote URL that does not resolve to a pair must fail closed.
#
# NOT SUFFICIENT WHEN THE SLUG IS BUILT INTO A URL PATH — use `adb_is_path_safe_repo_slug` below.
adb_is_repo_slug() {
  case "${1:-}" in
    */*/*|/*|*/) return 1 ;;
    */*) return 0 ;;
    *) return 1 ;;
  esac
}

# adb_is_path_safe_repo_slug <value> — true iff <value> is a well-formed `owner/repo` pair that is
# also safe to interpolate into an API PATH (`repos/<slug>/...`).
#
# The stricter sibling, because the shape test alone is not enough for that position: `a/..` is a
# perfectly well-formed pair AND a path traversal, so a caller that only asks `adb_is_repo_slug`
# will happily build `repos/a/../activity`. Every check above compares a slug or parses one; the
# moment a slug is CONCATENATED INTO A REQUEST the requirement changes, and the difference is easy
# to miss precisely because the shape test looks like it already covers it.
#
# The charset is GitHub's own for owner and repository names — alphanumerics, `.`, `_`, `-` — so a
# real slug always passes and anything carrying a path, query or scheme character never does. This
# matters most for a slug the local code did not construct: `pr-watch.sh` reads `head.repo.full_name`
# out of an API response and builds a path from it, which is exactly the untrusted-position case.
#
# TRAVERSAL IS A PROPERTY OF A SEGMENT, NOT OF A SUBSTRING, and getting that wrong costs
# availability rather than safety — which is why it is easy to ship. An earlier spelling here
# rejected any `..` ANYWHERE in the slug; that also rejects a repository legitimately named
# `api..client`, and the caller's failure mode is code 20 on every date-scoped signal for that PR
# — permanently unreadable, for a name that was never dangerous. Dots are ordinary in repository
# names (`.github` is GitHub's own convention), so the test has to be exact: a segment that IS `.`
# or `..` is traversal; a segment that merely CONTAINS dots is a name.
#
# `adb_is_repo_slug` above already guarantees exactly one slash with both halves non-empty, so the
# two segments are `${1%%/*}` and `${1#*/}` and there is no third to check.
adb_is_path_safe_repo_slug() {
  adb_is_repo_slug "${1:-}" || return 1
  case "${1:-}" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "${1%%/*}" in .|..) return 1 ;; esac
  case "${1#*/}"  in .|..) return 1 ;; esac
  return 0
}

# adb_pr_slug <value> — the `owner/repo` a PR argument names, case-folded; nothing for a bare
# number, and nothing for an argument whose slug does not parse to a well-formed pair. Used only to
# CROSS-CHECK the argument against the repository a caller's reads actually addressed; a bare number
# carries no slug and needs no check.
#
# THE SCHEME IS OPTIONAL, and all three forms are load-bearing. Matching only `*://*` is what let
# `github.com/other/repo/pull/7` through with an empty slug. Case-folding happens HERE rather than
# in each caller: a caller that forgets the `tr` compares a mixed-case argument against a
# lower-cased slug and silently sees a mismatch that is not one.
#
# Shell globs do not treat `/` as special, so these patterns constrain the NUMBER of slashes, not
# the segments — which is why the result is shape-checked rather than trusted.
adb_pr_slug() {
  local v="$1" rest slug
  case "$v" in
    *://*/*/*/pull/*) rest="${v#*://}"; rest="${rest#*/}" ;;   # scheme://host/owner/repo/pull/N
    */*/*/pull/*)     rest="${v#*/}" ;;                        # host/owner/repo/pull/N
    */*/pull/*)       rest="$v" ;;                             # owner/repo/pull/N
    *) return 0 ;;
  esac
  slug="$(printf '%s' "${rest%%/pull/*}" | tr '[:upper:]' '[:lower:]')"
  adb_is_repo_slug "$slug" || return 0
  printf '%s' "$slug"
}

# adb_pr_number <value> — the PR NUMBER from a bare positive integer or a GitHub PR URL. Callers
# hold a `prUrl` in their run marker, not a number, so accepting both removes a caller-side sed.
# Returns non-zero (printing nothing) for anything else.
#
# A NON-INTEGER ARGUMENT MUST NAME A REPOSITORY. Taking the digits after `pull/` and nothing else
# accepts `pull/7` and `https://github.com/pull/7`, which carry no owner/repo — so they reduce to a
# bare `7` and get answered about whatever repository the caller's reads happen to address. That is
# the same confidently-wrong answer as the scheme-less URL above, reached from a different input, so
# the slug requirement lives in the parse rather than being left to each caller's cross-check.
adb_pr_number() {
  local v="$1" n
  case "$v" in
    ''|*[!0-9]*)
      [ -n "$(adb_pr_slug "$v")" ] || return 1
      # The first `/pull/` — ANCHORED ON THE LEADING SLASH, and matching `adb_pr_slug`'s
      # `%%/pull/*` so the two halves of one parse agree on which segment is authoritative.
      #
      # Both halves of that sentence are load-bearing, and each was wrong in turn:
      #   * `##*pull/` (the LAST occurrence) disagreed with the slug: `.../widget/pull/7?x=/pull/9`
      #     gave slug `acme/widget` and number `9`, gating a DIFFERENT pull request in the repository
      #     the URL correctly names — which the cross-repo refusal cannot catch, because the
      #     repository IS right.
      #   * `#*pull/` (the first UNANCHORED match) then broke every repository whose owner or name
      #     ends in `pull`: `https://github.com/acme/git-pull/pull/8` matches inside `git-pull/`,
      #     leaving `pull/8`, which reduces to an empty number and rejects a perfectly valid URL —
      #     so the guards refused the workflow's own `prUrl` and auto-merge could never be armed
      #     there. `git-pull` has `-pull`, not `/pull`, so requiring the slash fixes it exactly.
      case "$v" in */pull/*) n="${v#*/pull/}"; n="${n%%[!0-9]*}" ;; *) return 1 ;; esac
      ;;
    *) n="$v" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  # No LENGTH bound here, unlike `require_uint`/`is_uint` (18 digits), and the omission is deliberate
  # rather than forgotten: a value wider than a shell integer makes this `[` fail with "integer
  # expression expected", the `2>/dev/null` swallows the message and the `|| return 1` rejects the
  # argument — the safe direction. A bounded validator with one home is #181's job (it consolidated
  # #150 and lists `uint`); adding a fourth private spelling here is what that issue exists to stop.
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$n"
}

# _adb_remote_url_slug <git-remote-url> — the `owner/repo` a git remote URL names, case-folded, or
# nothing. Handles the three URL shapes git emits: scp-style `git@host:owner/repo`,
# `https://host/owner/repo`, and `ssh://git@host/owner/repo`, each with an optional `.git` and an
# optional trailing slash. The host is discarded, so a GHES URL yields the same pair as github.com.
_adb_remote_url_slug() {
  local url="${1:-}"
  [ -n "$url" ] || return 1
  # ORDER MATTERS, and this order is the corrected one. Stripping `.git` FIRST is a no-op when a
  # trailing slash is still last, so the valid combined form `owner/repo.git/` survived as
  # `owner/repo.git` — a slug that matches no real repository, which made the shared anchor DISAGREE
  # with the API's `owner/repo` and refused both PR guards. Slash, then suffix, then slash again, so
  # `repo.git/`, `repo/`, `repo.git` and `repo` all reduce to `repo`.
  url="${url%/}"; url="${url%.git}"; url="${url%/}"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}"; url="${url#*/}" ;;
    *:*)   url="${url#*:}" ;;
  esac
  adb_is_repo_slug "$url" || return 1
  printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# adb_git_repo_slugs — EVERY `owner/repo` this checkout's git remotes name, case-folded, one per
# line, de-duplicated. Non-zero (printing nothing) when no remote resolves to a pair.
#
# ASKING GIT IS THE POINT. `gh api repos/{owner}/{repo}/...` expands its placeholders through gh, and
# the documented `GH_REPO` environment variable overrides that expansion: verified live,
# `GH_REPO=cli/cli gh api 'repos/{owner}/{repo}'` answers `cli/cli` from a directory that is not a
# repository at all. An identity call made through gh (`adb_repo_slug`, `gh repo view`) honors the
# same override and would simply agree with itself, so it can never be the anchor. Git config cannot
# be redirected by a gh variable, and costs no network round trip.
#
# THE SET, NOT `origin`, IS THE RIGHT ANCHOR for "was this read about a repository I am working on?",
# and reading only `origin` was a real regression: in a FORK clone (`origin` = your fork, `upstream` =
# the project) the pull request being gated lives on `upstream`, so an origin-only anchor returns a
# confidently readable, confidently WRONG slug and the guard emits a false refusal. A checkout whose
# only GitHub remote is named `upstream` failed even harder — no anchor at all. Both layouts are
# ordinary, both worked before the anchor existed, and `docs/design-principles.md` §2 is explicit that
# a mechanism must work for a project the baseline has never seen: a remote NAME is exactly the
# known-layout hardcode that rules out.
#
# Membership still closes the hole it was added for. `GH_REPO=other/project` names a repository that
# is in nobody's remote set, so it is refused; what is accepted is only a repository this checkout
# actually tracks.
#
# Deliberately NOT consulted: `gh repo set-default` records `remote.<name>.gh-resolved`, but its
# common value is the literal `base`, which names that remote's PARENT — a repository git cannot
# resolve without the network. Reading it would therefore either add the round trip this function
# exists to avoid, or silently resolve a fork to itself.
adb_git_repo_slugs() {
  local line url slug out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    url="${line#* }"                       # `remote.<name>.url <url>` -> <url>
    slug="$(_adb_remote_url_slug "$url")" || continue
    out="$out$slug
"
  done <<EOF
$(git config --get-regexp '^remote\..*\.url$' 2>/dev/null)
EOF
  [ -n "$out" ] || return 1
  printf '%s' "$out" | LC_ALL=C sort -u
}

# adb_git_origin_slug — ONE `owner/repo` for this checkout, for a caller that must name a single
# repository (`gh --repo <slug>`). `origin` when it resolves, else the sole GitHub remote when there
# is exactly one; non-zero when neither holds, because picking arbitrarily from several is a guess.
# Same git-only anchor as the set above — see there for why gh cannot answer this.
adb_git_origin_slug() {
  local slug slugs
  slug="$(_adb_remote_url_slug "$(git remote get-url origin 2>/dev/null)")" \
    && { printf '%s' "$slug"; return 0; }
  slugs="$(adb_git_repo_slugs)" || return 1
  [ "$(printf '%s\n' "$slugs" | grep -c .)" -eq 1 ] || return 1
  printf '%s' "$slugs"
}

# adb_gh_entity <slug> <number> [subcommand] [extra-field] — read ONE issue-or-pull-request and
# report what it is. The single home for "resolve #N against a repository", because there are now
# two consumers and a second copy is exactly the drift this file exists to prevent (#212 review).
#
# THE SUBCOMMAND IS A PARAMETER, and that is not gratuitous generality — it is a correctness
# requirement discovered by check-state-assert.sh. `gh issue view` answers for a pull-request
# number, which makes it the right reader when the caller does not yet know the kind. But it does
# NOT accept every pull-request field: `gh issue view <n> --json mergedAt` fails outright with
# "Unknown JSON field". state-assert.sh keys MERGED off `mergedAt` precisely because GitHub reports
# a merged PR's state as CLOSED, so hard-coding `issue` here would have made every merged PR render
# as "CLOSED without merging" — the wrong-direction error #44 exists to prevent. Callers that know
# they hold a PR pass `pr`; callers classifying an unknown number pass `issue`.
#
# Prints one TAB-delimited record on stdout: "<kind>\t<state>\t<extra>\t<number>"
#   kind    `issue` | `pull`   — never guessed; see the URL-segment rule below
#   state   OPEN | CLOSED | MERGED
#   extra   the optional third field's value (stateReason for an issue, mergedAt for a PR)
#   number  the number the RESPONSE is about, so a caller can prove it got what it asked for
#
# Exit codes distinguish the two failures that must never be conflated:
#   0  read and understood
#   1  the entity does not exist (a definite negative — gh resolved the repo and said no)
#   2  UNREADABLE — transport failure, auth loss, malformed payload, unrecognizable URL. NOT the
#      same as "does not exist", and collapsing them is a real defect: a network blip would
#      otherwise be reported to a user as a fabricated issue number.
#
# `gh issue view` is used for BOTH kinds deliberately: it answers for a pull-request number too, so
# one call classifies either. Only the URL's path segment discriminates them, compared EXACTLY at
# its known position and never searched for anywhere in the URL — a repository literally named
# `issues` exists in the wild, and a substring test would read its PR URLs as issues.
adb_gh_entity() {
  local slug="$1" n="$2" sub="${3:-issue}" extra="${4:-stateReason}"
  local json fields st ex url seg num rc
  case "$sub" in issue|pr) ;; *) return 2 ;; esac
  command -v gh >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  # Read and parse as SEPARATE steps: a pipeline reports only its LAST command's status, so
  # `gh … | jq` returns 0 on a failed read and the parser sees empty stdin — indistinguishable from
  # a legitimately empty answer.
  json="$(gh "$sub" view "$n" --repo "$slug" --json "state,$extra,url" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # gh exits non-zero both for "no such number" and for "the network is gone". Ask whether the
    # REPOSITORY is reachable to tell them apart; if that read also fails, the honest answer is
    # UNREADABLE rather than a confident "this issue does not exist".
    gh repo view "$slug" --json name >/dev/null 2>&1 || return 2
    return 1
  fi
  [ -n "$json" ] || return 2
  fields="$(printf '%s' "$json" | jq -r '.state // "", (.'"$extra"' // ""), (.url // "")' 2>/dev/null)" \
    || return 2
  { IFS= read -r st; IFS= read -r ex; IFS= read -r url; } <<EOF
$fields
EOF
  [ -n "$st" ] || return 2
  seg="${url%/*}"; num="${url##*/}"; seg="${seg##*/}"
  case "$num" in ''|*[!0-9]*) return 2 ;; esac
  case "$seg" in
    pull)   printf 'pull\t%s\t%s\t%s\n'  "$st" "$ex" "$num" ;;
    issues) printf 'issue\t%s\t%s\t%s\n' "$st" "$ex" "$num" ;;
    *) return 2 ;;
  esac
}

# adb_pr_slug_check <label> <pr-number> <pr-argument> <observed-slug> — prove that a caller's reads
# addressed the repository the caller meant, before any verdict is derived from them. Diagnostics go
# to stderr under <label>; nothing is printed on success.
#
#   0  verified — the reads addressed this checkout, and the argument (if it named a repo) agrees
#   1  UNVERIFIABLE — the observed slug is missing or malformed, or this checkout has no parseable
#      origin. The caller maps this to its own "live state unreadable" code (20 in both guards).
#   2  REFUSED — the reads addressed a different repository than the argument or the checkout names.
#
# WHY A MISSING OBSERVED SLUG IS A FAILURE AND NOT "NOTHING TO COMPARE". pr-review.sh guarded its
# comparison on `[ -n "$gotslug" ]`, so the check silently VANISHED on exactly the malformed
# responses it exists to catch, and `--pr <other-repo-url>` was then answered about this repo.
# pr-watch.sh was fixed for that shape after the #178 review and the fix was never back-propagated
# — this issue in miniature, which is why the rule now has one home instead of two.
#
# ORDER IS PART OF THE CONTRACT: unverifiable metadata outranks a mismatched argument, so a foreign
# URL read against a response with no base repository reports 1 (unreadable) rather than 2. Pinned
# by both harnesses.
adb_pr_slug_check() {
  local label="$1" n="$2" arg="$3" got="$4" want local_slug
  got="$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')"
  # The observed slug is the ONLY evidence of which repository answered, so a response without a
  # well-formed one is unreadable. Validated in shape, not just non-emptiness: `acme` or
  # `acme/widget/extra` would otherwise compare unequal to every real slug and read as a refusal,
  # reporting "a different repository" for what is really a broken response.
  adb_is_repo_slug "$got" || {
    printf '%s: PR #%s carries no usable base repository — refusing to answer about an unidentifiable repository\n' \
      "$label" "$n" >&2
    return 1
  }

  # Anchor the read to the CHECKOUT, not to the argument. Without this a bare `--pr 7` — which
  # carries no slug and so skips every comparison below — is redirected wholesale by `GH_REPO`, and
  # the guard reports on another project's #7 with no way to tell. `/resolve-pr-threads --watch`
  # passes exactly that bare form.
  #
  # The test is MEMBERSHIP in the checkout's remote set, not equality with `origin`: in a fork clone
  # the pull request lives on `upstream`, so an origin-only anchor manufactures a false refusal. See
  # adb_git_repo_slugs.
  local_slug="$(adb_git_repo_slugs)" || {
    printf '%s: cannot resolve this checkout'\''s GitHub repository from any git remote — refusing to answer\n' \
      "$label" >&2
    return 1
  }
  # `--` is load-bearing: without it an observed slug beginning with `-` is parsed as grep OPTIONS,
  # so grep aborts with a usage dump and the comparison never happens — and the code below then
  # reports a repository MISMATCH for a test that did not run. Unreachable from the API (a GitHub
  # owner cannot start with `-`), but this is a shared primitive whose own contract is "validate the
  # shape, do not trust it", and the harness calls it directly with arbitrary values.
  if ! printf '%s\n' "$local_slug" | grep -qxF -- "$got"; then
    printf '%s: the reads answered for '\''%s'\'' but this checkout tracks %s — refusing (is GH_REPO set?)\n' \
      "$label" "$got" "$(printf '%s' "$local_slug" | tr '\n' ' ')" >&2
    return 2
  fi

  # A bare number names no repository and needs no further check; anything else must agree.
  want="$(adb_pr_slug "$arg")"
  if [ -n "$want" ] && [ "$want" != "$got" ]; then
    printf '%s: --pr names '\''%s'\'' but this repo is '\''%s'\'' — refusing to answer about a different repository\n' \
      "$label" "$want" "$got" >&2
    return 2
  fi
  return 0
}

# adb_reviewer_match_jq — print the jq prelude defining `adb_declared_reviewer($who)`, the ONE
# implementation of "does this API login satisfy one of the declared reviewer logins?". Applied to a
# login STRING; `$who` is the normalized declaration set as a jq array. Four filters across the two
# guards ask this question (a review's author, an issue comment's, a reaction's, and the arming
# guard's per-reviewer pass), and they must all answer it the same way.
#
# A jq `def` rather than a shell function because every caller asks it INSIDE a filter over an
# array: a shell predicate would fork once per review. It is a constant string — declarations reach
# jq through `--argjson`, never concatenated into the program source.
#
# HOW THIS DIFFERS FROM `adb_actions_app_slug`, whose header argues for a scalar accessor OVER a
# shared jq predicate: both of THIS function's callers are shell libraries beside this file, so a
# `def` reaches them. But the distinction is narrower than "there is no prose consumer", and stating
# it loosely would be wrong: `base/workflows/resolve-pr-threads.md` asks a related question about the
# SAME manifest key, in agent-pasted prose, and builds its own anchored-alternation regex to do it. It
# is not blocked by "cannot source a library" — it already shells out to role-dispatch — so the form
# that would serve all three consumers is a REGEX, not a `def`. That unification is deliberately not
# done here because it would CHANGE what that workflow auto-resolves (a bare login would start
# matching the suffixed spelling), which is a behavioural decision rather than a refactor: #208.
#
# THE MATCH IS ASYMMETRIC, AND THAT IS THE WHOLE POINT (#173, superseding #176). The same GitHub App
# is spelled two ways depending on which API answered — GraphQL reports `foo`, REST reports
# `foo[bot]` — so both modules used to strip a trailing `[bot]` from BOTH sides before comparing.
# Stripping the DECLARATION is lossy: `bots = ["foo[bot]"]` was then satisfied by a human account
# literally named `foo`, and reactions are publicly writable, so the bar was a login collision
# rather than any privilege. Not hypothetical — `gh api users/gemini-code-assist` returns a real
# User account (id 200291788), i.e. the collision space is populated by exactly the kind of account
# that reviews pull requests. A `user.type` filter cannot rescue it: verified live, the reactions
# endpoint reports `type: "User"` for the Codex connector while the reviews endpoint reports
# `type: "Bot"` for the same App, so filtering on type would reject the real signal.
#
# So the API login is normalized TOWARD the declaration, never the reverse:
#
#   declared `foo[bot]`  matches ONLY the API login `foo[bot]`        — App, exact spelling
#   declared bare `foo`  matches the API login `foo` OR `foo[bot]`    — either, App or human
#
# The suffix is added to the bare declaration rather than stripped from the API login, which is what
# makes it strictly asymmetric: stripping would let `foo[bot][bot]` satisfy a declared `foo[bot]`
# through the same one-suffix rule the strict form exists to deny.
#
# WHAT A BARE DECLARATION MEANS IS THEREFORE "EITHER", DELIBERATELY (recorded as D18). Bare is the
# portable spelling — it matches whichever form the reading API returns — and it is what this repo
# and the built-in allowlist already declare, so the two guards keep working across the GraphQL/REST
# split. The `[bot]` form is the STRICT one, and its strictness is against the observed API
# spelling: a reader that switches surfaces stops satisfying it. That fails safe (the guard withholds
# the arm) but it is real, and closing it needs a stable App identity rather than a login string.
# CASE IS FOLDED ON BOTH SIDES, and that is not the same concession as folding the suffix. GitHub
# logins are case-insensitive, so `FOO[BOT]` and `foo[bot]` are one account and comparing them
# case-sensitively is simply wrong; the ASYMMETRY is about the `[bot]` SUFFIX, which carries the
# App-vs-human meaning. Folding here rather than trusting the caller is deliberate: the production
# path already lower-cases the declaration in `bots --comparable`, so this looks redundant — but a
# future consumer passing a raw declaration would then match NOTHING, and "matches nothing" wedges a
# guard at "awaiting review" forever. That is the safe direction and therefore the silent one, which
# makes it exactly the hidden precondition a shared primitive must not carry.
# `printf` rather than a `cat` heredoc: the program is a compile-time constant, and bash 3.2 backs a
# heredoc with a real temp file plus a `cat` exec. This is called per declared reviewer in one caller,
# so it is the per-element class rather than the per-poll class.
adb_reviewer_match_jq() {
  printf '%s\n' \
    'def adb_declared_reviewer($who):' \
    '  (ascii_downcase) as $a' \
    '  | any($who[]; ascii_downcase as $d' \
    '      | ($a == $d)' \
    '        or ((($d | endswith("[bot]")) | not) and ($a == $d + "[bot]")));'
}

# ====== the reviewer-evidence classifier, and the head anchor it dates signals against (#167) ===
#
# ONE answer to one question, for BOTH guards: *given everything a declared reviewer emitted, has
# this head been reviewed, and was it clean?* `pr-review.sh gate` and `pr-watch.sh` ask different
# FINAL questions — "may I arm the merge?" vs "is the reviewer done?" — so they must NOT share a
# verdict or an exit code. What they share is this neutral classification; each maps it to its own
# vocabulary. Sharing the verdict instead is the trap #167 names, and answering it twice is how the
# two modules already disagreed (#185).
#
# adb_is_utc_instant / adb_head_anchor were PRIVATE to pr-watch.sh until now. D19 recorded that
# promotion as this issue's FIRST step rather than a thing to copy — #173 exists because two private
# copies diverged into a live fail-open, and `gate` returning 0 on a date-scoped signal is an ARMED
# MERGE, i.e. the same predicate at strictly higher stakes.

# adb_is_utc_instant <value> — exactly `YYYY-MM-DDTHH:MM:SSZ`, the one format the comparisons below
# are allowed to see.
#
# THIS IS NOT DEFENSIVE PADDING, it is what makes a LEXICOGRAPHIC compare a CHRONOLOGICAL one. That
# equivalence holds only while every operand is the same width, precision and zone:
# `2026-07-25T09:00:00-04:00` sorts BEFORE `2026-07-25T05:00:00Z` as a string and AFTER it as an
# instant, and sub-second precision (`…:00.123Z`) silently loses to `…:01Z` on a prefix compare.
# GitHub returns plain `…Z` on every endpoint the guards read — verified live on reactions, issue
# comments and repository activity — but "verified today on four endpoints" is weaker than a check,
# and the documented example payload for the check-suite anchor that was REJECTED (D19) carries a
# `-04:00` offset, so the format is demonstrably not uniform across the API as a whole.
#
# Rejecting rather than normalizing is deliberate: parsing an offset back to UTC in portable shell
# means `date -d` vs `date -j` (the exact GNU/BSD split these files avoid everywhere else), and a
# format this code has never seen is a reason to stop, not to improvise a conversion.
#
# THE LAYOUT CHECK IS NECESSARY AND NOT SUFFICIENT, so the COMPONENT RANGES are checked too. A glob
# over character classes accepts `9999-99-99T99:99:99Z`, and that is not a harmless curiosity: it
# sorts ABOVE every real timestamp AND above `ADB_NO_ANCHOR` itself, so a single malformed
# `created_at` would read as fresh against any anchor — including the far-future sentinel whose
# entire job is to make an unestablished anchor fail closed. One bad field would have defeated the
# fail-closed default outright and classified the reviewer `clean`, which on the arming guard prints
# a head SHA. Reported by the codex reviewer on this module's own PR (#219).
#
# Ranges are tested with `case` GLOBS rather than arithmetic, deliberately: these fields are
# zero-padded, and `[ "08" -gt 0 ]` puts a leading-zero value into arithmetic context where it reads
# as octal. A glob has no numeric interpretation to get wrong.
#
# Day-of-month is bounded at 31 WITHOUT month/leap-year cross-checking. That is the honest boundary:
# the purpose here is to reject values that break the ORDERING, and `2026-02-31` still orders
# correctly between `02-28` and `03-01`. Calendar validation would need a date library this file
# deliberately does not reach for (`date -d` vs `date -j` is the GNU/BSD split it avoids elsewhere).
# Second is allowed to reach 60 for a leap second, which UTC genuinely emits.
adb_is_utc_instant() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  case "${1:5:2}"  in 0[1-9]|1[0-2]) ;; *) return 1 ;; esac          # month  01-12
  case "${1:8:2}"  in 0[1-9]|[12][0-9]|3[01]) ;; *) return 1 ;; esac # day    01-31
  case "${1:11:2}" in [01][0-9]|2[0-3]) ;; *) return 1 ;; esac       # hour   00-23
  case "${1:14:2}" in [0-5][0-9]) ;; *) return 1 ;; esac             # minute 00-59
  case "${1:17:2}" in [0-5][0-9]|60) ;; *) return 1 ;; esac          # second 00-60 (leap second)
  return 0
}

# The "no anchor could be established" sentinel — a far-future instant no real timestamp can beat.
#
# LOAD-BEARING, NOT TIDY. Every freshness test is `[ "$candidate" \> "$anchor" ]`, so an EMPTY
# default would be the fail-open spelling exactly: every non-empty string is `\>` the empty one, so
# any path that reached a comparison without setting an anchor would call every signal fresh. This
# inverts that — an anchor nobody set makes every date-scoped signal look stale, so the failure mode
# of forgetting to set it is `pending`/`awaiting`, never `clean`.
#
# It is a far-future TIMESTAMP rather than a `~` or a flag because the comparison is lexicographic
# under the shell's collation: keeping the sentinel in the same character class as the values it is
# compared against means no locale can order it differently than digits are ordered. And it is
# deliberately conspicuous — a `9999` in a diagnostic line is unmistakably a bug, where an empty
# string reads like a missing field.
# shellcheck disable=SC2034  # read by the two PR guards that source this library, not by it
ADB_NO_ANCHOR="9999-12-31T23:59:59Z"

# adb_head_anchor <label> <pr-number> <head-repo-slug> <head-ref> <head-sha> — the SERVER-ASSIGNED
# instant at which the head ref became the current head SHA. Prints it on stdout.
#
# NEUTRAL CODES, mapped by each caller to its own vocabulary (the adb_pr_slug_check pattern):
#   0 → the anchor is on stdout, validated
#   1 → no anchor could be established; the caller MUST fall to its "cannot prove freshness" verdict
#       (pr-watch `pending`, pr-review `awaiting`), NEVER to clean/arm
#   2 → the read failed, or what came back could not be parsed (caller → its unreadable code)
#
# WHY THE ACTIVITY API AND NOT THE COMMIT (#175/D19): the head commit's committer date is
# CLIENT-SUPPLIED — git records `GIT_COMMITTER_DATE` verbatim and GitHub echoes back whatever the
# committing machine claimed — while a reaction's timestamp is GitHub-assigned. That comparison was
# ASYMMETRIC IN ITS TRUST, and a past-dated head made a STALE `+1` read as FRESH. No attacker is
# needed: a date-preserving rebase or a slow clock produces it. The activity record's `timestamp` is
# stamped by GitHub when the ref moved, so it answers the question directly.
#
# THE LATEST MATCH, NOT THE EARLIEST, and that choice IS the force-push defence: a ref that went
# A → B → A carries two activities whose `after` is A, and only the later one says when it is A
# *now*. Taking the earliest would date the current head from a push that was superseded and undone.
#
# WHY NOT THE OBVIOUS ANCHORS. Three candidates look right and are not, and the next person to touch
# this will reach for one of them (the argument is kept with the code, not only in D19):
#
#   * the earliest CHECK-SUITE `created_at` for the head SHA is server-assigned, but it is scoped to
#     the SHA, not to the REF. A commit that already ran CI elsewhere carries its ORIGINAL
#     timestamp, so an ordinary fast-forward onto it PRESERVES the fail-open: suite for C at 09:00,
#     a stale `+1` at 10:00, an ordinary `B → C` at 11:00 → 10:00 > 09:00 → clean, still false.
#     No force-push happens there, so pairing it with a force-push term does not rescue it. Commit
#     STATUSES have exactly the same flaw, and both also need the repo to HAVE ci. This case is
#     pinned as a regression test, because it is the one that reads as safe and is not.
#   * the PR TIMELINE's `head_ref_force_pushed` events are server-assigned and ref-scoped, but they
#     exist only for FORCE pushes — an ordinary push appears nowhere in them.
#   * `head.repo.pushed_at` is server-assigned, ref-agnostic and free (it is already in the PR
#     object the callers read), and it is SOUND: being repo-wide it can only ever be too LATE, i.e.
#     a false pending, never a false clean. It is rejected for LIVENESS, not for safety — a push to
#     any unrelated branch after the reaction re-opens a settled verdict, so on an active repo a
#     watch would run to its bound instead of converging. Worth stating plainly, because "rejected"
#     usually means "unsafe" and here it does not.
adb_head_anchor() {
  local label="$1" n="$2" slug="$3" ref="$4" head="$5" raw at matches line
  # A head repository that no longer exists (the fork was deleted) is a REAL state, not a broken
  # response: the PR still reads fine, there is simply nowhere left to ask. That is an unestablished
  # anchor (1), not an unreadable one (2) — the distinction this whole family is built on.
  [ -n "$slug" ] && [ -n "$ref" ] \
    || { echo "$label: PR #$n — no head repository/ref to date the head against (deleted fork?)" >&2
         return 1; }
  # THIS SLUG GOES INTO A URL PATH, a stronger requirement than any other slug in this family faces
  # — the base slug is only ever COMPARED — and it is a value the caller did not construct but read
  # out of an API response. `adb_is_repo_slug` alone is necessary and NOT sufficient there (`a/..` is
  # a well-formed pair and a path traversal).
  adb_is_path_safe_repo_slug "$slug" \
    || { echo "$label: PR #$n reports a malformed head repository ('$slug')" >&2; return 2; }

  # `--method GET` with `-f` is REQUIRED: a bare `-f` makes `gh api` switch to POST, which here would
  # POST to the activity endpoint rather than read it. `-f` also URL-ENCODES the value, which a
  # hand-built query string would not — and a ref name may legally contain `&` or `%`, either of
  # which silently truncates or corrupts an unencoded query.
  #
  # `direction=desc` is explicit rather than inherited: the whole point of one un-paginated page is
  # that the newest activity is ON it.
  raw="$(gh api --method GET "repos/$slug/activity" \
           -f ref="refs/heads/$ref" -f direction=desc -f per_page=100 2>/dev/null)" \
    || { echo "$label: could not read the ref activity of PR #$n" >&2; return 2; }
  # Read, then parse — the same split every other read in this family uses. An empty body is NOT an
  # empty list: a successful read of a ref with no activity returns `[]`, so nothing at all means the
  # call produced no document and must not be mistaken for "no matching activity" (which is 1, a much
  # weaker statement than 2 and one a caller may sit on).
  [ -n "$raw" ] \
    || { echo "$label: could not read the ref activity of PR #$n" >&2; return 2; }
  # jq SELECTS, the shell VALIDATES AND ORDERS — deliberately, for two reinforcing reasons.
  #
  # First, EVERY match must be format-checked BEFORE any of them is ordered. Ordering first and
  # checking only the winner is unsound: a response mixing formats can hand the comparison a
  # lexically-later but chronologically-EARLIER record, and an anchor earlier than the truth is the
  # permissive direction.
  #
  # Second, doing the check here rather than inside jq keeps `adb_is_utc_instant` the ONE HOME for
  # the accepted grammar. Written twice — a shell glob and a jq regex — the same rule could be
  # loosened on one side and not the other, and both spellings would still look right in review.
  #
  # The `ref` match is belt AND braces on purpose: `ref=` is applied server-side, but a filter that
  # is ignored (a param renamed, an endpoint that stops honouring it) would silently widen this read
  # to the whole repository, and an `after` SHA is unique enough that the widened read would still
  # usually match — dating this PR's head from a push to some other branch.
  matches="$(printf '%s' "$raw" | jq -r --arg sha "$head" --arg ref "refs/heads/$ref" '
      if type != "array" then error("activity response is not a JSON array") else . end
      | .[]
      | select((.after // "") == $sha)
      | select((.ref // "") == $ref)
      | (.timestamp // "") | select(length > 0)' 2>/dev/null)" \
    || { echo "$label: could not parse the ref activity of PR #$n" >&2; return 2; }

  # A here-doc, NOT a pipe: a piped `while` runs in a subshell on bash 3.2 and `at` would be
  # discarded at the loop's end, silently yielding "no anchor" — i.e. pending — for every PR.
  at=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    adb_is_utc_instant "$line" \
      || { echo "$label: PR #$n — ref activity reported a timestamp this module cannot order ('$line')" >&2
           return 2; }
    if [ -z "$at" ] || [ "$line" \> "$at" ]; then at="$line"; fi
  done <<EOF
$matches
EOF

  [ -n "$at" ] \
    || { echo "$label: PR #$n — no recorded activity puts $head on refs/heads/$ref, so a date-scoped signal cannot be proved fresh" >&2
         return 1; }
  printf '%s' "$at"
}

# adb_paginated_list <label> <api-path> <what> <pr-number> — a paginated GET, flattened to one JSON
# array on stdout. Returns 2 on any failure (the caller maps it to its own unreadable code).
#
# ALL FIVE signal reads across the two guards have this shape, and factoring them together is about
# the FAIL-CLOSED guards rather than the line count: each read needs three of them (the fetch, the
# parse, and the empty-result check), and if a later edit dropped one on a single path that signal
# would classify an unreadable response as "nothing found yet" — a withhold that looks harmless,
# which is what makes it the dangerous one: the watcher would poll a broken API to its deadline and
# report a timeout instead of the failure.
#
# PROMOTED FROM pr-watch.sh BY #167, whose §6 names it explicitly as one of the three things "a
# naive implementation WOULD duplicate a third time" when the arming guard grew the same two extra
# surfaces. One home, so a fix to either guard's read reaches both.
#
# Read and PARSE separately: a pipeline reports only its LAST command's status, so `gh api … | jq`
# returns 0 on a failed read and the parser then sees empty stdin — indistinguishable from a
# legitimately empty list.
adb_paginated_list() {
  local label="$1" url="$2" what="$3" pr="$4" raw flat
  raw="$(gh api --paginate "$url" 2>/dev/null)" \
    || { echo "$label: could not read $what for PR #$pr" >&2; return 2; }
  # AN EMPTY BODY IS NOT AN EMPTY LIST, and this check is the one that enforces it. A successful read
  # of a PR with no reviews returns `[]`; NOTHING AT ALL means the call produced no document, which
  # must never be read as "that surface carried no records".
  #
  # THIS GUARD USED TO BE ONE LINE FURTHER DOWN, ON `$flat`, WHERE IT COULD NEVER FIRE:
  # `printf '%s' "" | jq -s -c '[.[][]]'` emits `[]`, so the empty-body case sailed past a check
  # written to catch it and the header's claim of three fail-closed guards was really two. Its
  # sibling `adb_head_anchor` has always tested `$raw` for exactly this reason.
  #
  # Harmless while `gate` read ONE surface — an empty reviews body meant "nobody reviewed" and it
  # withheld the arm anyway. NOT harmless once three surfaces are folded: with reviews silently
  # emptied, a reviewer's standing CHANGES_REQUESTED disappears and a fresh `+1` on another surface
  # is the only evidence left, so the fold returns `clean` and the gate returns 0 AND PRINTS THE HEAD
  # SHA — which `/implement-issue` step 10 hands to `gh pr merge --auto --match-head-commit`.
  # Reproduced end-to-end before this line was added.
  [ -n "$raw" ] \
    || { echo "$label: could not read $what for PR #$pr (empty response body)" >&2; return 2; }
  # --paginate concatenates one JSON document per page; -s flattens them into a single array.
  #
  # EVERY PAGE IS TYPE-CHECKED BEFORE IT IS FLATTENED, and the bare `[.[][]]` this replaces was the
  # empty-body bug's twin. Iterating a non-array does not fail — `{}` flattens to `[]`, i.e. exactly
  # "this surface carried no records" — so a malformed document from the reviews read would discard
  # a standing CHANGES_REQUESTED and let a fresh `+1` on another surface fold to `clean`. Same
  # false-arm, different malformation. `adb_head_anchor` has always guarded its own read this way
  # (`if type != "array" then error`), which is the inconsistency that made this reachable.
  flat="$(printf '%s' "$raw" \
          | jq -s -c '[ .[] | if type != "array" then error("page is not a JSON array") else . end | .[] ]' 2>/dev/null)" \
    || { echo "$label: could not parse the $what of PR #$pr (not a JSON array)" >&2; return 2; }
  # Kept as belt to the braces above: it cannot fire for an empty body any more, but it still catches
  # a jq that succeeds while producing nothing.
  [ -n "$flat" ] \
    || { echo "$label: could not parse the $what of PR #$pr" >&2; return 2; }
  printf '%s' "$flat"
}

# adb_reviewer_evidence <who-list> <reviews-json> <comments-json> <reactions-json> <head-sha> —
# SELECTION ONLY, no dating and no verdict. Prints one TAB-separated `<login>\t<kind>\t<value>` line
# per piece of evidence a declared reviewer left, where <kind> is `review` (value = the upper-cased
# state), `comment` or `plus1` (value = the raw `created_at`, possibly empty). Returns 2 if jq fails.
#
# TAB-SEPARATED, following this file's own record convention (`adb_repo_shape` + `adb_shape_val`,
# and `cleanup-lib.sh`'s outcome records) rather than a space. Not cosmetic: a login is the one
# field whose content this code does not control, and with a space delimiter a login carrying one
# splits across the field boundary — so the reviewer silently never matches its own evidence and the
# parsed-back class is garbage. A tab makes the split total by construction, which is what lets both
# this grammar and the `<login>\t<class>` one below be read the same way from either end.
# (`role-dispatch.sh` independently rejects such a declaration, on its own merits; that is the
# belt, this is the braces, and neither is load-bearing alone.)
#
# SPLIT FROM THE DATING STEP ON PURPOSE, for two reasons that both bite.
#
# First, COST: the head-arrival anchor is a fifth API read, and a poll where no declared reviewer
# left a date-scoped signal must not pay for it. `adb_reviewer_classes_for_pr` inspects this output
# to decide, so the anchor is fetched only when something actually depends on it — and that
# inspection lives HERE, beside the emitter, rather than as a pattern match in each consumer.
#
# Second, SOUNDNESS: every candidate timestamp must be format-checked BEFORE any of them is ordered
# (see adb_head_anchor), so this emits EVERY match rather than jq's `max`. The volume is bounded by
# what DECLARED reviewers posted, which is a handful.
#
# Empty `created_at` is emitted rather than filtered away: a matching record from a declared
# reviewer that carries no usable timestamp is a MALFORMED response, and the fold below classifies
# it `unknown` (fail closed). Dropping it would silently read as "that reviewer said nothing",
# which on the clean path is the dangerous direction — a reviewer who commented would be reported
# as having passed.
adb_reviewer_evidence() {
  local who="$1" reviews="$2" comments="$3" reactions="$4" sha="$5" match out
  match="$(adb_reviewer_match_jq)"
  # The declared set arrives as the NEWLINE LIST every other consumer already holds, and is split
  # inside this one jq program. It used to be a JSON array the caller built with its own `jq -R -s`
  # pass — which meant every caller carried that fork, its own status check, and a comment
  # explaining the status check, and it left the two shared functions disagreeing about how a
  # reviewer set is spelled (`adb_reviewer_classes` has always taken the list).
  out="$(jq -r -n \
      --arg who "$who" --argjson reviews "$reviews" --argjson comments "$comments" \
      --argjson reactions "$reactions" --arg sha "$sha" \
      "$match"'
      ($who | split("\n") | map(select(length > 0)))[] as $w
      | ( $reviews[]
          # THE REVIEWER IS MATCHED FIRST, THE COMMIT SECOND. That order is the fix, not a style
          # choice: filtering on commit_id == $sha first DISCARDS a review whose commit_id is missing
          # or is not a string, before anything looks at who wrote it or what it said. So a declared
          # reviewer CHANGES_REQUESTED with a malformed commit_id vanished silently, and a fresh +1
          # on another surface became the only evidence left: clean, and an armed merge. A review
          # that cannot be attributed to a commit is UNKNOWN (fail closed), never absent. Scoped to
          # DECLARED reviewers so a stray malformed review from anyone else cannot wedge the guard.
          # NOTE: no apostrophes in this block. It sits inside a shell single-quoted jq program.
          | select((.user.login // "") | adb_declared_reviewer([$w]))
          | (.commit_id // null) as $cid
          | if ($cid | type) != "string" or ($cid | length) == 0 then
              "\($w)\tbadreview\t\($cid | tostring)"
            elif $cid == $sha then
              "\($w)\treview\t\((.state // "") | ascii_upcase)"
            else empty end ),
        ( $comments[]
          | select((.user.login // "") | adb_declared_reviewer([$w]))
          | "\($w)\tcomment\t\(.created_at // "")" ),
        ( $reactions[]
          | select((.content // "") == "+1")
          | select((.user.login // "") | adb_declared_reviewer([$w]))
          | "\($w)\tplus1\t\(.created_at // "")" )' 2>/dev/null)" \
    || return 2
  printf '%s' "$out"
}

# adb_reviewer_classes <label> <who-newline-list> <evidence> <anchor> — fold the evidence above into
# exactly ONE class per declared reviewer. Prints `<login> <class>` lines; returns 2 when a
# timestamp's format is unrecognized (the caller maps that to its unreadable code).
#
# THE CLASSIFICATION (#167 §4), and it is deliberately neutral — no exit codes, no verdict:
#
#   CHANGES_REQUESTED at this head              → rejected
#   COMMENTED at this head, or a FRESH comment   → attention
#   APPROVED at this head, or a FRESH `+1`       → clean
#   stale / PENDING / DISMISSED / nothing        → none
#   unrecognized state, or an undatable record   → unknown
#
# THE WITHIN-REVIEWER ORDER IS `rejected > attention > unknown > clean > none` — the STRONGEST
# thing this one reviewer produced. Two positions in it are load-bearing:
#
#   * `unknown` OUTRANKS `clean`, so a signal nobody could classify can never be outvoted into a
#     merge authorization by a second signal that happened to look clean. This REVERSES the older
#     rule that "an accepted review outweighs an unknown-state one" — #167 §8 requires every
#     unreadable path to fail closed, and that rule was the one place a fresh unknown was silently
#     discarded.
#   * `rejected`/`attention` OUTRANK `unknown`, because both already withhold the arm AND name
#     concrete work, where `unknown` only says "retry". Reporting the weaker remedy first is what
#     the modules' own precedence (a rejection ahead of a missing review) already does.
#
# THE ACROSS-REVIEWER ORDER IS DELIBERATELY DIFFERENT, and the difference IS #185: there,
# `none` OUTRANKS `clean`. See adb_fold_reviewer_classes. Within one reviewer a stale `+1` beside a
# fresh `APPROVED` is `clean`; across the set, one silent reviewer beside one clean reviewer is NOT.
# Reusing one order for both is precisely the bug — it makes a single fast `+1` speak for the set.
adb_reviewer_classes() {
  local label="$1" who="$2" evidence="$3" anchor="$4"
  local w lw kind val cls best bestrank rank tab staled
  tab="$(printf '\t')"
  # One pass per declared reviewer over the evidence. The set is small (a repo declares a handful of
  # bots) and so is the evidence, so the readable shape wins over a single-pass associative array —
  # which bash 3.2, this repo's floor, does not have.
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    best="none"; bestrank=0; staled=0
    # `read` does the field splitting on the tab, rather than three parameter expansions unpicking a
    # space-delimited line by hand. `val` absorbs the remainder, so a value containing a tab (which
    # none of the three kinds can produce) degrades to an unrecognized one rather than a shifted field.
    while IFS="$tab" read -r lw kind val; do
      [ -n "$lw" ] || continue
      [ "$lw" = "$w" ] || continue
      cls=""
      case "$kind" in
        review)
          case "$val" in
            CHANGES_REQUESTED) cls="rejected" ;;
            COMMENTED)         cls="attention" ;;
            APPROVED)          cls="clean" ;;
            # An unsubmitted draft nobody can see, and one that was explicitly revoked, are not the
            # reviewer having spoken. Not evidence, and not a problem either.
            PENDING|DISMISSED) cls="" ;;
            # A state this family does not recognize must SURFACE, never be quietly read as "not
            # reviewed": a future GitHub state meaning "reviewed" would otherwise wedge the gate at
            # "awaiting" forever, and one meaning "rejected" would be ignored outright.
            *) cls="unknown"
               echo "$label: unrecognized review state '$val' from '$w'" >&2 ;;
          esac ;;
        # A review this declared reviewer left that carries no usable commit_id. It cannot be tied to
        # a commit, so it can be neither honoured (it may be about an older head) nor dismissed (it
        # may be a rejection of THIS one) — which is precisely what `unknown` is for.
        badreview)
          cls="unknown"
          echo "$label: a review from '$w' carries no usable commit_id ('$val') — cannot tell which commit it reviewed" >&2 ;;
        comment|plus1)
          if [ -z "$val" ]; then
            cls="unknown"
            echo "$label: a $kind from '$w' carries no timestamp — cannot prove when it was left" >&2
          elif ! adb_is_utc_instant "$val"; then
            # A format this family has never seen is a reason to stop, not to improvise a
            # conversion — and ordering it against the anchor would be comparing two different
            # grammars as if they were one.
            echo "$label: a reviewer signal carries an unrecognized timestamp format ('$val')" >&2
            return 2
          elif [ "$val" \> "$anchor" ]; then
            # THE BACKSLASH IN `\>` IS LOAD-BEARING — do not "clean it up". Unescaped, `>` inside
            # `[ ]` is a REDIRECTION: the test would silently become `[ "$val" ]` (true for any
            # non-empty string) while creating a file named after the anchor, so EVERY signal would
            # read as fresh and the staleness rule would be gone with no error anywhere.
            if [ "$kind" = "comment" ]; then cls="attention"; else cls="clean"; fi
          elif [ "$staled" -eq 0 ]; then
            # The signal predates this head's arrival: it reviewed an earlier commit, so it is not
            # evidence about THIS one — `none`, never `clean`. Said out loud rather than dropped
            # silently, because "a `+1` is sitting right there and the guard still says pending" is
            # otherwise the most confusing state this family produces.
            #
            # ONCE PER REVIEWER, not once per stale record. Every match is emitted for ordering
            # soundness, so a PR carrying several old bot comments would otherwise repeat this line
            # on every poll of a half-hour watch — hundreds of lines saying one thing.
            staled=1
            echo "$label: a $kind from '$w' at $val predates this head's arrival ($anchor) — it reviewed an earlier commit" >&2
          fi
          ;;
      esac
      [ -n "$cls" ] || continue
      # Keep the stronger of the two, by the total order documented above. The incumbent's rank is
      # CARRIED rather than re-derived: `$best`'s rank was known when it was assigned, so ranking it
      # again every iteration forks a subshell to recompute a value already in hand.
      rank="$(_adb_class_rank "$cls")"
      if [ "$rank" -gt "$bestrank" ]; then best="$cls"; bestrank="$rank"; fi
    done <<EOF
$evidence
EOF
    printf '%s\t%s\n' "$w" "$best"
  done <<EOF
$who
EOF
}

# adb_reviewer_classes_for_pr <label> <pr-number> <who-list> <head-sha> <head-repo-slug> <head-ref>
# — the whole read-and-classify pipeline for one pull request. Prints the `<login>\t<class>` lines;
# returns 0, or 2 if anything could not be read or dated (the caller maps that to its own code).
#
# THE LAST THING BOTH GUARDS WERE STILL DOING SEPARATELY. After the classifier was shared, each one
# still open-coded the same six steps — three `adb_paginated_list` calls with the same URLs in the
# same order, `adb_reviewer_evidence`, the decision about whether to fetch the anchor, and
# `adb_reviewer_classes` — differing only in a label. That is the same "one question, two places"
# shape #167 exists to remove, one altitude up from the place it removed it.
#
# THE ANCHOR CONDITION IS THE PART THAT REALLY HAD TO MOVE. Both callers used to decide it by
# pattern-matching `adb_reviewer_evidence`'s output for the literals `" comment "` / `" plus1 "` —
# a caller-side string match against a record format this file owns, asserted by nothing. Change the
# emitter's delimiter (as the move to TAB just did) and both guards silently stop fetching the
# anchor, every date-scoped signal degrades to `none`, and the gate wedges at "awaiting" while the
# watcher polls to its deadline: a false-negative wedge, on both guards at once, with no error
# anywhere. The decision now lives beside the emitter, where a format change is one edit.
#
# WHAT IS DELIBERATELY *NOT* SHARED is the verdict and the exit codes. This returns the neutral
# per-reviewer classes; folding them and mapping the result to 0/16/19/20/21 or 0/10/11/20 stays in
# each guard, because "may I arm the merge?" and "is the reviewer done?" report at different
# granularity (D20). Sharing the mapping is the trap; sharing the reading never was.
adb_reviewer_classes_for_pr() {
  local label="$1" n="$2" who="$3" head="$4" headslug="$5" headref="$6"
  local reviews comments reacts evidence anchor arc tab
  # A pull request IS an issue as far as comments and reactions go, so those two live under
  # `issues/N/...`. The reactions read is deliberately NOT filtered server-side with `-f content=+1`:
  # a bare `-f` makes `gh api` switch to POST, which would ADD a reaction rather than list them.
  #
  # ALL THREE ARE READ BEFORE ANYTHING IS CLASSIFIED. The verdict is a property of the whole declared
  # set, so every reviewer's evidence must be in hand; and a failed read is then reported uniformly
  # rather than being invisible on whichever path happened to return early.
  reviews="$(adb_paginated_list "$label" "repos/{owner}/{repo}/pulls/$n/reviews?per_page=100" reviews "$n")" || return 2
  comments="$(adb_paginated_list "$label" "repos/{owner}/{repo}/issues/$n/comments?per_page=100" comments "$n")" || return 2
  reacts="$(adb_paginated_list "$label" "repos/{owner}/{repo}/issues/$n/reactions?per_page=100" reactions "$n")" || return 2

  evidence="$(adb_reviewer_evidence "$who" "$reviews" "$comments" "$reacts" "$head")" \
    || { echo "$label: could not evaluate the reviewer signals of PR #$n" >&2; return 2; }

  # The anchor is a FIFTH request, paid for only when a date-scoped signal actually needs dating.
  # The sentinel is the default: an unestablished anchor leaves those signals unprovable (classified
  # `none` — the safe direction) while leaving commit-scoped review evidence untouched, because a
  # review carries its own `commit_id` and needs no anchor at all (D19).
  anchor="$ADB_NO_ANCHOR"
  tab="$(printf '\t')"
  case "$evidence" in
    *"${tab}comment${tab}"*|*"${tab}plus1${tab}"*)
      anchor="$(adb_head_anchor "$label" "$n" "$headslug" "$headref" "$head")"; arc=$?
      case "$arc" in
        0) ;;
        1) anchor="$ADB_NO_ANCHOR" ;;   # unestablished: adb_head_anchor already said why, on stderr
        *) return 2 ;;
      esac ;;
  esac

  adb_reviewer_classes "$label" "$who" "$evidence" "$anchor" || return 2
}

# The WITHIN-reviewer order, in its one home: the strongest evidence this one reviewer produced.
_adb_class_rank() {
  case "$1" in
    rejected)  printf '4' ;;
    attention) printf '3' ;;
    unknown)   printf '2' ;;
    clean)     printf '1' ;;
    *)         printf '0' ;;   # none
  esac
}

# The ACROSS-reviewer order. IT IS NOT THE SAME ORDER, and the single swapped pair is the whole of
# #185: `none` (0) now outranks `clean` (-1), so `clean` can only win when EVERY declared reviewer
# is clean. Under the within-reviewer order a set of {clean, none} folds to `clean`, which is
# exactly the shipped bug — one fast `+1` from any one bot reported a pass while the others had not
# looked at the PR at all.
#
# `clean` is therefore the WEAKEST class here, not the second-strongest. Every other position is
# unchanged, which is why #185's own summary notes the findings path was already correct: a
# rejection or an attention signal from any one reviewer still wins outright.
_adb_class_rank_across() {
  case "$1" in
    rejected)  printf '4' ;;
    attention) printf '3' ;;
    unknown)   printf '2' ;;
    clean)     printf '0' ;;
    *)         printf '1' ;;   # none — outranks clean, so a silent reviewer holds the pass back
  esac
}

# adb_fold_reviewer_classes <classes> — the winning class across the whole declared set. Prints it
# on stdout. An EMPTY class list yields `none`, which every caller maps to a withhold, never a pass.
#
# The ONE home for the all-or-nothing rule (#185): `pr-review.sh gate` already required every
# declared reviewer to have spoken, while `pr-watch.sh` pooled the set and answered on any one of
# them. Both now fold here, so they cannot disagree about HOW MANY reviewers must have produced a
# signal — the orthogonal axis to #167's "what does a signal mean".
adb_fold_reviewer_classes() {
  local classes="$1" lw cls best="none" bestrank=-1 rank seen=0 tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r lw cls; do
    [ -n "$lw" ] || continue
    seen=1
    rank="$(_adb_class_rank_across "$cls")"
    if [ "$rank" -gt "$bestrank" ]; then best="$cls"; bestrank="$rank"; fi
  done <<EOF
$classes
EOF
  # No declared reviewer at all is `none`, never `clean`. A caller that declared `bots = []` answers
  # that case BEFORE reaching here — an empty set is "nothing is coming", which is a different claim
  # from "nobody has spoken" and only the caller knows which one it is holding.
  [ "$seen" -eq 1 ] || best="none"
  printf '%s' "$best"
}

# adb_reviewers_in_class <classes> <class>... — the logins that landed in ANY of the named classes,
# space-separated, so a caller's diagnostic can NAME them ("awaiting review from: …") rather than
# reporting a bare code.
#
# SEVERAL classes, because a caller that reports two of them as one outcome (pr-watch renders both
# `rejected` and `attention` as `findings`) would otherwise call this twice and join the results —
# and joining two lists either of which may be EMPTY reintroduces the stray/double space that
# formatting workaround existed to scrub.
adb_reviewers_in_class() {
  local classes="$1" lw cls want out="" tab
  shift
  tab="$(printf '\t')"
  while IFS="$tab" read -r lw cls; do
    [ -n "$lw" ] || continue
    for want in "$@"; do
      if [ "$cls" = "$want" ]; then out="${out:+$out }$lw"; break; fi
    done
  done <<EOF
$classes
EOF
  printf '%s' "$out"
}

# --- git ---------------------------------------------------------------------

# Resolve a repo's default branch: origin/HEAD → a local main/master → "main".
# Usage: adb_default_branch [root]   (root defaults to the current directory)
adb_default_branch() {
  local root="${1:-.}" b db
  db="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
  if [ -z "$db" ]; then
    for b in main master; do
      if git -C "$root" show-ref --verify --quiet "refs/heads/$b"; then db="$b"; break; fi
    done
  fi
  [ -z "$db" ] && db="main"
  printf '%s\n' "$db"
}

# Resolve the repo root the caller is in: the git top-level, else the current directory (so a
# runtime helper works both inside a checkout and in a throwaway non-git dir, e.g. a unit test).
# The ONE home for this idiom — role-dispatch.sh and project-gates.sh both call it rather than
# re-inlining `git rev-parse --show-toplevel 2>/dev/null || pwd`. Usage: adb_repo_root
adb_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# True (0) iff <dir> holds a recognizable project manifest — the signal adb_repo_shape uses to
# tell a real nested project root (a monorepo package, a nested app) from a bare, stray root doc.
# A `CLAUDE.md` sitting next to a `package.json` is a project; one sitting alone (e.g. this
# framework's own GENERATED agents/<agent>/CLAUDE.md) is not. Deliberately a common-ecosystem
# list; extend as new stacks appear. project-gates.sh carries a DELIBERATELY separate manifest
# list — it answers "which gate command runs" (gated on tool availability), not this "is this a
# project root" structural question, so the two are intentionally not unified. The lists may drift;
# that is accepted. Usage: _adb_has_project_manifest <dir>
_adb_has_project_manifest() {
  local d="$1" m
  for m in package.json pnpm-workspace.yaml composer.json Cargo.toml go.mod pyproject.toml \
           setup.py build.gradle build.gradle.kts pom.xml; do
    [ -f "$d/$m" ] && return 0
  done
  return 1
}

# Report the SHAPE of the repo a starting dir sits in, so tooling can tolerate the messy real
# world — working-dir ≠ git-root, nested repos, a repo dropped inside an untracked parent tree,
# and layered/multiple root docs — instead of assuming a tidy single-root state (#23). Prints
# TAB-separated "<key>\t<value>" facts on stdout, one per line, and ALWAYS returns 0 (a shape is
# descriptive, never an error) — but an unknown never masquerades as a clean answer: an
# unreadable start emits `warning`, and a scan that hits its depth bound emits `scan_truncated`,
# so "couldn't tell" is visible rather than silently collapsing to "nothing found".
#
# Facts (a stable TSV schema; consumers should ignore keys they don't know):
#   in_git         1 if the start dir is inside a git work tree, else 0
#   root           the resolved project root — the git top-level, else the start dir
#   cwd_is_root    1 if the start dir IS that root, else 0 (i.e. working dir is below the git root)
#   parent_in_git  1 if root's parent dir is itself inside ANY git repo, else 0
#   nested_in <p>  emitted once, iff root is nested inside a DIFFERENT enclosing git repo (its root)
#   foreign_doc <p>  0..n, nearest-first: a root doc (CLAUDE.md/AGENTS.md/GEMINI.md) found ABOVE
#                    root — outside this repo, referenced by relative path yet invisible to any
#                    git-aware tool. The walk includes an enclosing repo root (nested_in) and then
#                    stops there; else it climbs to / or a depth bound.
#   extra_doc <p>    0..n: an ADDITIONAL tracked root doc strictly BELOW root that also sits beside
#                    a project manifest (a monorepo/layered signal). git ls-files keeps it
#                    tracked-only + vendor-clean; the top-level root doc itself is never listed.
#   scan_truncated <n>  the upward foreign_doc walk stopped at its depth bound <n> without reaching
#                    / or an enclosing repo — a doc higher up may exist but was not scanned.
#   warning <msg>  a non-fatal problem (e.g. the start dir is unreadable) worth surfacing.
#
# Every path is canonicalized PHYSICALLY (`pwd -P`, resolving symlinks) before comparison, because
# `git rev-parse --show-toplevel` returns a physical path (on macOS `mktemp` gives /var/… while git
# reports /private/var/…) — without this, cwd_is_root would mis-compare. The caller's own working
# directory is never changed (all cd's run in subshells). Paths containing a TAB or newline are
# unsupported (same assumption as adb_agent_manifest). A superproject's `git ls-files` cannot see
# docs inside a submodule/gitlink — such nested docs are not enumerated by extra_doc.
# Usage: adb_repo_shape [start_dir]   (start_dir defaults to the current directory)
adb_repo_shape() {
  local start="${1:-$PWD}" abs root parent parent_root in_git=0 parent_in_git=0 nested_in=""
  local dir depth max=8 doc up truncated rel base mdir

  # Canonicalize the start dir physically; a subshell keeps the caller's cwd intact. `--` guards a
  # leading-dash start (a general primitive may be handed one). An unresolvable start is a
  # `warning`, not a silent empty result.
  abs="$(cd -- "$start" 2>/dev/null && pwd -P)"
  if [ -z "$abs" ]; then
    printf 'in_git\t0\n'
    printf 'root\t%s\n' "$start"
    printf 'cwd_is_root\t1\n'
    printf 'parent_in_git\t0\n'
    printf 'warning\tstart directory does not exist or is unreadable: %s\n' "$start"
    return 0
  fi
  start="$abs"

  # `git -C <physical dir> rev-parse --show-toplevel` returns a physical (symlink-resolved) path,
  # so — because `start` is already physical — root and parent_root need no further `pwd -P`.
  if root="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
    in_git=1
  else
    root="$start"
  fi
  printf 'in_git\t%s\n' "$in_git"
  printf 'root\t%s\n' "$root"
  if [ "$start" = "$root" ]; then printf 'cwd_is_root\t1\n'; else printf 'cwd_is_root\t0\n'; fi

  parent="$(dirname "$root")"
  # Is root's parent inside ANY git repo? If so and that repo's top-level differs from root, root
  # is NESTED inside it. (root's own .git lives below parent, so a parent match is always a
  # DIFFERENT, enclosing repo — never root itself.) Compute the flag once, emit once.
  parent_in_git=0
  if [ "$in_git" -eq 1 ] && [ "$parent" != "$root" ] \
     && parent_root="$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$parent_root" ]; then
    parent_in_git=1
    if [ "$parent_root" != "$root" ]; then
      nested_in="$parent_root"
      printf 'nested_in\t%s\n' "$parent_root"
    fi
  fi
  printf 'parent_in_git\t%s\n' "$parent_in_git"

  # foreign_doc: root docs ABOVE root, nearest-first. Check each ancestor (including an enclosing
  # repo root, then stop there); else climb to / or the depth bound. truncated stays 1 only if the
  # bound is what stopped us, so scan_truncated discloses a possibly-unscanned higher doc.
  if [ "$in_git" -eq 1 ] && [ "$parent" != "$root" ]; then
    dir="$parent"; depth=0; truncated=1
    while [ "$depth" -lt "$max" ]; do
      for doc in CLAUDE.md AGENTS.md GEMINI.md; do
        [ -f "$dir/$doc" ] && printf 'foreign_doc\t%s\n' "$dir/$doc"
      done
      if [ -n "$nested_in" ] && [ "$dir" = "$nested_in" ]; then truncated=0; break; fi
      up="$(dirname "$dir")"
      if [ "$up" = "$dir" ]; then truncated=0; break; fi
      dir="$up"; depth=$((depth + 1))
    done
    [ "$truncated" -eq 1 ] && printf 'scan_truncated\t%s\n' "$max"
  fi

  # extra_doc: tracked root docs strictly below root that sit beside a project manifest. `-z`
  # output + shell filtering avoids an ambiguous CLAUDE.md pathspec; only .md is enumerated for
  # speed. Only printf's inside the pipe's subshell, so no state needs to survive it.
  if [ "$in_git" -eq 1 ]; then
    git -C "$root" ls-files -z -- '*.md' 2>/dev/null | while IFS= read -r -d '' rel; do
      base="${rel##*/}"
      case "$base" in CLAUDE.md|AGENTS.md|GEMINI.md) : ;; *) continue ;; esac
      case "$rel" in */*) : ;; *) continue ;; esac   # strictly below root (has a path separator)
      mdir="$root/${rel%/*}"
      _adb_has_project_manifest "$mdir" && printf 'extra_doc\t%s\n' "$root/$rel"
    done
  fi
  return 0
}

# Read value(s) for <key> from a TAB-separated "<key>\t<value>" facts blob (as produced by
# adb_repo_shape) — the ONE home for reading the shape TSV, so the delimiter/column contract lives
# in a single place instead of being re-inlined in each consumer (agent-init, tests, and the
# deferred per-skill preflight all call these rather than hand-writing the awk). adb_shape_val
# prints the FIRST match (empty if none); adb_shape_all prints EVERY match, one per line, for a
# repeatable key (foreign_doc / extra_doc / warning).
# Usage: adb_shape_val <facts> <key> ; adb_shape_all <facts> <key>
adb_shape_val() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }
adb_shape_all() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2}'; }

# Classify a local branch's currency versus its origin/<branch> counterpart, using
# ONLY already-fetched refs — the CALLER must `git fetch` first (this function never
# touches the network, so it is safe to unit-test against a local bare "origin"). It
# prints exactly one status word and returns 0:
#   current   — local branch and origin/<branch> point at the same commit
#   behind    — origin/<branch> has commits the local branch lacks (fast-forwardable)
#   ahead     — the local branch has commits origin/<branch> lacks (unpushed)
#   diverged  — both sides have commits the other lacks
#   no-remote — origin/<branch> does not exist (nothing to compare against)
# Returns 1 (printing nothing) only on an internal git error, so a caller under
# `set -e` still sees a hard failure rather than a silent mis-classification.
# Usage: adb_branch_sync_state <root> <branch>
adb_branch_sync_state() {
  local root="$1" branch="$2" counts ahead behind
  if ! git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    printf 'no-remote\n'; return 0
  fi
  # `--left-right --count A...B` prints "<left>\t<right>": left = commits in A (local)
  # not in B (origin), right = commits in B not in A. awk splits on the tab robustly.
  counts="$(git -C "$root" rev-list --left-right --count "$branch...origin/$branch" 2>/dev/null)" || return 1
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  [ -n "$ahead" ] && [ -n "$behind" ] || return 1
  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then printf 'current\n'
  elif [ "$ahead" -eq 0 ]; then printf 'behind\n'
  elif [ "$behind" -eq 0 ]; then printf 'ahead\n'
  else printf 'diverged\n'
  fi
}

# Classify a clone using ONLY LOCAL state — no network, no fetch. Prints exactly one word
# and returns 0. This is deliberately split out of the fetch-requiring classification below
# so a caller can refuse UNSAFE state before spending a network round trip (and before a
# fetch mutates remote-tracking refs): a dirty or mid-operation clone is never going to be
# fast-forwarded, so asking origin about it is pure cost. Words, cheapest-safety-first:
#   not-a-repo  — <root> is not a git work tree
#   dirty       — uncommitted changes (never auto-pull over uncommitted work)
#   in-progress — a merge / rebase / cherry-pick / revert / bisect is underway. A clean tree
#                 is NOT proof of safety: `git rebase` between steps and `git bisect` can both
#                 leave a clean tree, and detached-HEAD only catches some of them.
#   detached    — HEAD is not on a branch
#   not-default — on a branch other than <default>
#   local-ok    — none of the above; the caller may fetch and then ask adb_branch_sync_state
# Usage: adb_clone_local_state <root> <default-branch>
adb_clone_local_state() {
  local root="$1" default="$2" gitdir cur
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { printf 'not-a-repo\n'; return 0; }
  if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then printf 'dirty\n'; return 0; fi
  # Resolve the git dir ABSOLUTELY: `rev-parse --git-dir` prints a path relative to the
  # work tree (usually the bare word ".git"), which would resolve against the CALLER's cwd,
  # not <root> — so every sentinel test below would silently look in the wrong place.
  gitdir="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$gitdir" ]; then
    # The sentinels git itself uses. rebase-merge covers interactive/merge-backend rebases,
    # rebase-apply covers `git am` and the apply backend, sequencer covers a multi-commit
    # cherry-pick/revert that is between picks (no *_HEAD file exists at that moment).
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || \
       [ -f "$gitdir/MERGE_HEAD" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ] || \
       [ -f "$gitdir/REVERT_HEAD" ] || [ -f "$gitdir/BISECT_LOG" ] || \
       [ -d "$gitdir/sequencer" ]; then
      printf 'in-progress\n'; return 0
    fi
  fi
  cur="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || { printf 'detached\n'; return 0; }
  [ "$cur" = "$default" ] || { printf 'not-default\n'; return 0; }
  printf 'local-ok\n'
}

# Full currency classification: the local state above, and — only when that is `local-ok` —
# the remote comparison. Requires a prior `git fetch` for behind/ahead/diverged accuracy
# (it performs none itself, so it stays unit-testable against a local bare "origin").
# Prints one of: not-a-repo | dirty | in-progress | detached | not-default | current |
# behind | ahead | diverged | no-remote. Usage: adb_clone_status <root> <default-branch>
adb_clone_status() {
  local state
  state="$(adb_clone_local_state "$1" "$2")"
  [ "$state" = "local-ok" ] || { printf '%s\n' "$state"; return 0; }
  adb_branch_sync_state "$1" "$2"
}

# Print the path of the GLOBAL agent manifest — the one install.sh writes once and every
# runtime reader consults. The ONE home for this path: it was previously spelled independently
# by the writer (install.sh) and each reader, and a third spelling that honored XDG_CONFIG_HOME
# would read a file the writer never created — the config would silently do nothing, which is
# exactly the class of failure this library exists to remove. Deliberately NOT XDG-aware today,
# because matching the writer is what matters; making the whole surface XDG-aware is a separate,
# all-at-once change.
adb_global_manifest() { printf '%s/.config/ai-dev-baseline/agents.toml\n' "${HOME:-/root}"; }

# Print a path's mtime in epoch seconds, or nothing when it cannot be read.
#
# The two stat flavors are NOT interchangeable and the naive `stat -f %m || stat -c %Y` is a
# latent bug: on GNU coreutils `-f` means --file-system, so it can EXIT ZERO while printing
# something that is not an mtime — the `||` fallback then never runs and the caller does
# arithmetic on garbage. Each result is therefore validated as digits, and only a numeric
# answer is accepted. Usage: adb_mtime <path>
adb_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then
    m="$(stat -f %m "$1" 2>/dev/null)"; case "$m" in ''|*[!0-9]*) m="" ;; esac
  fi
  printf '%s' "$m"
}

# Print how many seconds ago <path> was last modified, or nothing when that cannot be
# established (missing path, unreadable mtime, unusable clock, or a FUTURE mtime). Callers treat
# empty as "unknown age" and decide their own safe direction — the SessionStart rate limit
# proceeds with the check, the update lock declines to break a lock it cannot date. The
# arithmetic and the validation live here so those two policies are the ONLY difference.
#
# A future mtime is reported as unknown rather than as a negative number, and that is
# load-bearing rather than tidiness: clock skew is real (a restored VM snapshot, a dual-boot RTC,
# a backup that rewrites ~/.cache), and a caller comparing `age < interval` would read a negative
# age as "checked very recently" — silently suppressing the currency check until wall-clock time
# caught up, which is exactly the staleness it exists to catch.
# Usage: adb_age_secs <path>
adb_age_secs() {
  local m now age
  m="$(adb_mtime "$1")"; [ -n "$m" ] || return 0
  now="$(date +%s 2>/dev/null)"; case "$now" in ''|*[!0-9]*) return 0 ;; esac
  age="$((now - m))"
  [ "$age" -lt 0 ] && return 0
  printf '%s' "$age"
}

# --- bounded execution -------------------------------------------------------
#
# Run a command under a wall-clock bound, portably. THE one home for this: role-dispatch.sh
# bounds an agent CLI (45 min) and currency-lib.sh bounds `baseline update` (a fetch + pull), and
# a second hand-rolled watchdog is exactly the duplicate-detector drift #131 was filed about.
# Both callers pass their own bound and grace, because a hang backstop for an agent pass and one
# for a git fetch have nothing in common but the mechanism.
#
# Prefers a real timeout binary (GNU `timeout` on Linux CI, `gtimeout` from coreutils on macOS);
# when neither exists (a stock Mac) it falls back to a bash-3.2-safe background watchdog. Returns
# the child's status, or 124 when the bound fired (matching GNU timeout's convention).
# stdin/stdout/stderr are whatever the caller redirected.
# ADB_NO_TIMEOUT_BIN=1 (or the legacy ADB_DISPATCH_NO_TIMEOUT_BIN=1) forces the watchdog path,
# which is how the unit tests exercise it on a box that has `timeout`.
#
# BOTH paths escalate TERM → grace → KILL. A bound that only sends SIGTERM is not a backstop: a
# child that ignores or traps TERM would leave `wait` blocking forever, which is an unbounded
# deadlock rather than a late failure. `timeout -k` does the escalation for us; the watchdog path
# does it by hand.
#
# KNOWN DIVERGENCE between the two paths — they agree on STATUS but not on process CLEANUP.
# GNU `timeout` puts the child in its own process group and signals the GROUP; the watchdog
# signals a single PID. So on the watchdog path (a stock Mac with no `timeout`/`gtimeout`) a
# grandchild can OUTLIVE the bound: `wait` returns and the caller gets its 124, but the orphan
# keeps running. For role-dispatch's 45-minute bound that is nearly unreachable. For
# currency-lib's 120 s bound on a `git fetch`/`git pull` it is not, and the orphan mutates a
# clone AFTER we have already reported the update as failed — it can move HEAD or hold
# .git/index.lock. Tracked as #141; mitigated meanwhile by currency-lib setting git's own
# stall/prompt bounds, so the wall-clock backstop is the last resort rather than the first.
#
# Usage: adb_run_bounded <secs> <kill-grace-secs> <argv...>

# Reap the in-flight child when OUR shell is terminated (an outer harness bound firing, a detached
# job cancelled, an operator ^C). Without this, bash dies while blocked in `wait` and the child is
# reparented to init, running out the FULL bound after the run was already cancelled. `timeout`
# forwards the TERM to the command it manages, so terminating it is enough on that path.
_adb_bounded_reap() {
  [ -n "${_ADB_BOUNDED_CHILD:-}" ] && kill -TERM "$_ADB_BOUNDED_CHILD" 2>/dev/null
  [ -n "${_ADB_BOUNDED_WATCHER:-}" ] && kill -TERM "$_ADB_BOUNDED_WATCHER" 2>/dev/null
  sleep 1
  [ -n "${_ADB_BOUNDED_CHILD:-}" ] && kill -KILL "$_ADB_BOUNDED_CHILD" 2>/dev/null
  exit 143   # report as "terminated by an outer bound", which is exactly what happened
}

adb_run_bounded() {
  local secs="$1" grace="$2" tb="" t0 trc otrap; shift 2
  # Both degenerate graces break the escalation and neither fails loudly: `timeout -k 0` means
  # "no SIGKILL at all" to GNU timeout, so a zero grace would leave the binary path with no
  # escalation while the watchdog path treats 0 as "KILL immediately" — the same input making one
  # path maximally aggressive and the other not a backstop at all.
  # Arithmetic comparison, not a literal `0)` arm: a zero-padded "00" matches no literal arm, so it
  # slipped through both clamps and reinstated the very platform split described above — `timeout
  # -k 00` never escalates, while the watchdog treats 00 as "KILL immediately".
  case "$grace" in ''|*[!0-9]*) grace=10 ;; *) [ "$grace" -eq 0 ] && grace=1 ;; esac
  # A ZERO bound is refused too, not just a non-numeric one: `timeout 0` means "no timeout at all"
  # to GNU timeout while the watchdog's `while [ 0 -lt 0 ]` kills instantly — one input, opposite
  # behaviors, and neither is a backstop. Arithmetic so "00" cannot slip past a literal arm.
  case "$secs" in ''|*[!0-9]*) return 2 ;; *) [ "$secs" -eq 0 ] && return 2 ;; esac
  if [ "${ADB_NO_TIMEOUT_BIN:-${ADB_DISPATCH_NO_TIMEOUT_BIN:-0}}" != "1" ]; then
    if   command -v timeout  >/dev/null 2>&1; then tb=timeout
    elif command -v gtimeout >/dev/null 2>&1; then tb=gtimeout
    fi
  fi
  # Save the caller's own handlers: this is a sourced library, so resetting to default on exit
  # would silently clobber a trap the calling script installed.
  otrap="$(trap -p TERM INT HUP)"
  if [ -n "$tb" ]; then
    t0=$SECONDS   # bash builtin: no fork, and `local` above keeps the arithmetic nesting-safe
    # Backgrounded + `wait` (rather than run in the foreground) so the reap trap has a PID to kill.
    # `<&0` for the same reason the watchdog path needs it — see below.
    "$tb" -k "$grace" "$secs" "$@" <&0 &
    _ADB_BOUNDED_CHILD=$!
    trap '_adb_bounded_reap' TERM INT HUP
    wait "$_ADB_BOUNDED_CHILD"; trc=$?
    trap - TERM INT HUP; [ -n "$otrap" ] && eval "$otrap"
    unset _ADB_BOUNDED_CHILD
    # Normalize the bound-fired status. GNU timeout reports 124 when SIGTERM ended the child, but
    # relays the child's own signal status (137) when -k had to escalate to SIGKILL — so ONE event
    # reports two different codes depending only on how stubborn the child was, and 137 is what
    # callers classify as "killed from outside this helper". Without this, the same timeout would
    # classify as "our backstop" on a stock Mac (watchdog path) and "an external kill" on Linux CI
    # (GNU timeout) — a platform-dependent lie. Gated on elapsed >= the bound, so an unrelated
    # external SIGKILL arriving BEFORE the bound still reports 137 honestly.
    if [ "$trc" -eq 137 ] && [ "$(( SECONDS - t0 ))" -ge "$secs" ]; then trc=124; fi
    return "$trc"
  fi
  local flag rc cmd_pid watcher tick
  flag="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/adb-bounded-flag-$$")"; rm -f "$flag"
  # `<&0` is load-bearing: a backgrounded command in a non-interactive shell has its stdin
  # redirected from /dev/null UNLESS it carries an explicit redirection. The caller's redirection
  # is on THIS function's invocation, not on the inner `&`, so without `<&0` a child fed its input
  # on stdin would read /dev/null instead.
  "$@" <&0 & cmd_pid=$!
  _ADB_BOUNDED_CHILD=$cmd_pid
  # Flag BEFORE the TERM: a child that dies from the signal can be reaped and the `wait` below can
  # return before the flag write, which would return the child's signal status instead of 124.
  # `kill -0` gates on the child still existing, so a child that exited on its own a moment before
  # the bound is not mislabelled as timed out.
  # The watchdog TICKS rather than sleeping the whole bound in one go. Killing the watcher does not
  # kill a `sleep` it already forked — that sleep is reparented to init and runs to term — so a
  # single `sleep "$secs"` leaks one orphan per call, each living the full bound. Ticking bounds an
  # orphan's life to one tick and lets the watcher notice a finished child and exit on its own. The
  # tick shrinks for small bounds so the unit tests stay fast.
  tick=5; [ "$secs" -lt 10 ] && tick=1
  ( waited=0
    while [ "$waited" -lt "$secs" ]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0   # child finished: nothing to police
      sleep "$tick"; waited=$(( waited + tick ))
    done
    kill -0 "$cmd_pid" 2>/dev/null || exit 0
    : > "$flag"; kill -TERM "$cmd_pid" 2>/dev/null
    sleep "$grace"; kill -KILL "$cmd_pid" 2>/dev/null || : ; ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  _ADB_BOUNDED_WATCHER=$watcher
  trap '_adb_bounded_reap' TERM INT HUP
  wait "$cmd_pid" 2>/dev/null; rc=$?
  trap - TERM INT HUP; [ -n "$otrap" ] && eval "$otrap"
  unset _ADB_BOUNDED_CHILD _ADB_BOUNDED_WATCHER
  kill -TERM "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  # The flag ALONE decides: if the bound fired, this is 124 whatever status the child exited with.
  # A child that traps SIGTERM and exits 0 (ordinary well-behaved-CLI cleanup) would otherwise be
  # reported as a clean success carrying truncated output — silent incompleteness accepted as a
  # result, and GNU `timeout` does NOT have that flaw (it returns 124 for that child), so gating on
  # rc would also reintroduce the platform-dependent split the normalization above eliminates.
  if [ -f "$flag" ]; then rm -f "$flag"; return 124; fi
  rm -f "$flag"; return "$rc"
}

# --- installed-baseline discovery --------------------------------------------

# True iff <path> is a symlink whose target is inside <src>. The ownership test every
# install-scoped scan and prune uses — it re-reads the link, so it is safe to call at the
# moment of mutation rather than trusting an earlier enumeration.
# Usage: adb_link_into <path> <src>
adb_link_into() { [ -L "$1" ] && case "$(readlink "$1")" in "$2"/*) return 0 ;; esac; return 1; }

# Print the repo root the global install points INTO ("the install-source"), resolved from
# whichever agent root-doc symlink exists (install.sh links each with an absolute target).
# The link's TARGET need not currently resolve — a dangling root doc (the very path that
# moved, or a failed prior repair) still identifies the clone, and repairing it is the whole
# point; the clone is validated by install.sh + agents/ existing, not by the doc file existing.
# Prints nothing and returns 1 when no installed symlink is found.
#
# Shared (not private to bin/baseline) because the SessionStart currency hook must resolve the
# SAME clone by the SAME rule — a second implementation is exactly the drift this library exists
# to prevent. Usage: adb_install_source [home]   (home defaults to $HOME)
adb_install_source() {
  local home="${1:-$HOME}" link target root
  for link in "$home/.claude/CLAUDE.md" "$home/.codex/AGENTS.md" "$home/.gemini/GEMINI.md"; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    case "$target" in /*) ;; *) continue ;; esac   # expect an absolute target
    # agents/<agent>/<DOC> sits three levels below the repo root. Logical `pwd` keeps this the
    # same flavor as the recorded symlink targets so prefix-matching them stays stable; callers
    # that compare clones use `-ef` (same-inode), so no physical canonicalization is needed.
    root="$(cd "$(dirname "$target")/../.." 2>/dev/null && pwd)" || continue
    if [ -f "$root/install.sh" ] && [ -d "$root/agents" ]; then
      printf '%s\n' "$root"; return 0
    fi
  done
  return 1
}

# --- minimal TOML reader -----------------------------------------------------

# Read one `key = value` from a named table of a TOML file. Prints the raw RHS value
# (trailing comment and surrounding whitespace stripped; quotes/brackets KEPT so the
# caller decides how to interpret a scalar vs. an array). Returns 0 when the key is
# present in the table (even if its value is an empty string ""), 1 when the file is
# missing or the key is absent — so callers can distinguish "unset" from "set to empty".
#
# Supports the subset the templates actually use: a `[table]` header, quoted scalar
# strings, and flat quoted-string arrays. Within a quoted scalar a `#` is preserved
# (only a comment OUTSIDE the string is stripped), and a backslash-escaped quote
# (`\"`) does NOT end the string — so a command with nested quotes survives verbatim,
# backslashes and all (escape *decoding* like `\"`→`"` is intentionally out of scope;
# the value is returned as written). Inline tables and multi-line values are out of
# scope (see docs/design-principles.md).
# Usage: adb_toml_get <file> <table> <key>
adb_toml_get() {
  local file="$1" table="$2" key="$3"
  [ -f "$file" ] || return 1
  awk -v tbl="$table" -v key="$key" '
    # A table header toggles whether we are inside the target table. The header name is
    # compared LITERALLY, not as a regex — so a dotted sub-table like [gates.scope] can
    # never accidentally match table "gatesXscope" via the "." metacharacter, and a
    # caller-supplied table name is never a regex-injection surface.
    /^[[:space:]]*\[/ {
      hdr = $0
      sub(/^[[:space:]]*\[/, "", hdr)   # drop leading whitespace + the opening "["
      sub(/\][[:space:]]*$/, "", hdr)   # drop the closing "]" + trailing whitespace
      intbl = (hdr == tbl)
      next
    }
    intbl && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)   # strip "key =" and the space after it
      if (substr(line, 1, 1) == "\"") {
        # Quoted scalar: walk to the closing quote, skipping backslash-escaped chars
        # (so \" does not close and # inside the string is not a comment). Reconstruct
        # the value with its outer quotes; the caller unquotes if it wants the bare form.
        rest = substr(line, 2); n = length(rest); i = 1; body = ""
        while (i <= n) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) { body = body c substr(rest, i + 1, 1); i += 2; continue }
          if (c == "\"") break
          body = body c; i++
        }
        line = "\"" body "\""
      } else {
        sub(/[[:space:]]*#.*$/, "", line)      # unquoted / array: strip trailing comment
      }
      sub(/[[:space:]]*$/, "", line)           # strip trailing whitespace
      printf "%s", line
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# Strip one layer of surrounding double quotes from a scalar TOML value.
# ("" → empty string; "pnpm test" → pnpm test). Leaves an array ([...]) untouched.
adb_toml_unquote() {
  local v="$1"
  v="${v#\"}"
  v="${v%\"}"
  printf '%s' "$v"
}

# List the bare identifier keys defined in a TOML table, one per line, in file order.
# Only keys matching [A-Za-z0-9_-]+ at the start of a line are returned (quoted keys and
# comment lines are skipped). Uses the SAME literal-table matching as adb_toml_get, so a
# request for table "gates" never leaks keys from a sub-table like [gates.scope]. Returns
# 0 even when the file is missing or the table is absent (prints nothing), so callers can
# iterate the output unconditionally. Usage: adb_toml_keys <file> <table>
adb_toml_keys() {
  local file="$1" table="$2"
  [ -f "$file" ] || return 0
  awk -v tbl="$table" '
    /^[[:space:]]*\[/ {
      hdr = $0
      sub(/^[[:space:]]*\[/, "", hdr)
      sub(/\][[:space:]]*$/, "", hdr)
      intbl = (hdr == tbl)
      next
    }
    intbl && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      k = $0
      sub(/^[[:space:]]*/, "", k)        # leading whitespace
      sub(/[[:space:]]*=.*$/, "", k)     # from the "=" onward
      print k
    }
  ' "$file"
}

# Parse a flat TOML array literal (as returned RAW by adb_toml_get — outer brackets and
# per-element quotes KEPT, e.g. `["claude", "gemini"]`) into its bare string elements, one
# per line: surrounding quotes and whitespace stripped, empty elements dropped. A scalar
# (a value not starting with `[`) prints nothing, and an empty array `[]` prints nothing —
# so a caller distinguishes "unset" (adb_toml_get returned 1) from "set to []" (adb_toml_get
# returned 0 but this prints nothing). Only the single-line, comma-separated quoted-string
# array the templates use is supported (matching adb_toml_get's own scope); an element may
# itself contain `[`/`]` (e.g. a `foo[bot]` login) because the outer close is found as the
# LAST `]`. Elements containing a literal comma are out of scope. Usage: adb_toml_array <raw>
adb_toml_array() {
  awk -v s="$1" '
    BEGIN {
      if (substr(s, 1, 1) != "[") exit 0        # not an array literal → no elements
      s = substr(s, 2)                           # drop the opening "["
      pos = 0                                     # find the LAST "]" (the array close)
      for (i = length(s); i >= 1; i--) { if (substr(s, i, 1) == "]") { pos = i; break } }
      if (pos > 0) s = substr(s, 1, pos - 1)
      m = split(s, parts, ",")
      for (j = 1; j <= m; j++) {
        e = parts[j]
        gsub(/^[[:space:]]+/, "", e); gsub(/[[:space:]]+$/, "", e)   # trim outer whitespace
        sub(/^"/, "", e); sub(/"$/, "", e)                            # strip one quote layer
        gsub(/^[[:space:]]+/, "", e); gsub(/[[:space:]]+$/, "", e)   # trim inside the quotes
        if (e != "") print e
      }
    }'
}

# --- versions ----------------------------------------------------------------

# Compare dot-separated numeric versions. Returns 0 iff have >= want. Missing trailing
# components count as 0 (so 2.1 >= 2.1.0). Non-numeric junk in a component sorts as 0.
# Usage: adb_version_ge <have> <want>
adb_version_ge() {
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
