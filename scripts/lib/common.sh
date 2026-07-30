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
adb_is_repo_slug() {
  case "${1:-}" in
    */*/*|/*|*/) return 1 ;;
    */*) return 0 ;;
    *) return 1 ;;
  esac
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
      case "$v" in *pull/*) n="${v##*pull/}"; n="${n%%[!0-9]*}" ;; *) return 1 ;; esac
      ;;
    *) n="$v" ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
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
  url="${url%.git}"; url="${url%/}"
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
  if ! printf '%s\n' "$local_slug" | grep -qxF "$got"; then
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
