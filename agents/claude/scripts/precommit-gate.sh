#!/usr/bin/env bash
# ai-dev-baseline — global Stop-hook quality gate.
#
# Claude Code runs this when the agent tries to end its turn. It blocks the stop
# (exit 2) if the repo's auto-detected quality gates (typecheck / lint / test /
# format) would fail on the current feature branch — so an autonomous run can't
# finalize work while CI-critical checks are red.
#
# No-op (exit 0) when:
#   - not in a git repo;
#   - the repo ships its OWN precommit gate at .claude/scripts/precommit-gate.sh
#     (project owns its gates — we defer to it, so nothing double-runs);
#   - HEAD is the default branch, detached, or unknown;
#   - there are zero changes on the branch (nothing to check);
#   - no supported ecosystem/gates are detected (safe in unfamiliar repos).
#
# FAIL LOUD (exit 2), never silently — when this gate's OWN required libraries
# (lib/common.sh, lib/project-gates.sh) are missing or corrupt. That is a broken /
# incomplete install, NOT an unfamiliar repo: a gate that silently no-ops then is
# enforcement secretly OFF, which is worse than a hard error (#35). This is distinct
# from "no gates detected" (a legitimate no-op decided INSIDE adb_run_gates).
#
# A red gate is genuinely wrong-until-fixed, so this stays a hard exit-2 block
# (unlike the soft "keep going" cue in implement-issue-gate.sh). See
# base/practices/ci-discipline.md for the diagnose-before-rerun philosophy.

set -u
# bash 5.3 runtime floor (#256) — FIRST, before the cd and before ANY read of the hook payload on
# stdin: the re-exec inherits that fd and restarts this script from the top, so anything already
# consumed would be lost.
#
# The source is CONDITIONAL on purpose. This file has a deliberate broken-install posture of its
# own a few lines below, and the floor gate is not entitled to override it — if the shared library
# is missing, that decision stays with the machinery that already owns it.
#
# `set +u` ACROSS THE SOURCE (#317). An unbound expansion at the TOP LEVEL of a library is fatal
# under `set -u`: it kills the shell OUTRIGHT, so this gate exited **1** and `require_lib`'s
# `fail_loud` below never ran. Exit 1 from a Stop hook is a NON-BLOCKING error notice, so the turn
# ended ungated while looking like a hook glitch — the "enforcement secretly off" inversion #35
# exists to prevent, arriving through the one door `fail_loud` cannot cover, because no `||` can
# catch it: the shell is gone before the next word is read. Sourcing is not the place to enforce
# `set -u`; it governs everything this gate actually does. Same repair #299 made to this repo's own
# project gate, which put this file explicitly out of its scope.
#
# AND THE CONDITION IS "DID IT LOAD", NOT "DOES THE FILE EXIST". A file test alone models a MISSING
# library and misses a CORRUPT one: a truncated common.sh exists, sources, and defines nothing, so
# `adb_require_bash` ran as an undefined command — `command not found` on stderr, its 127 discarded,
# and the floor silently unenforced while a misleading cause printed ahead of the real one.
#
# `command -v` asks whether the name is CALLABLE, which is a slightly weaker question than "is it a
# function" — an executable of the same name would satisfy it. That is deliberate rather than
# overlooked: it is the idiom `require_lib` below, `project-gates.sh` and `roadmap-lib.sh` all use
# for exactly this probe, and one site answering the question a different way is how two readers of
# the same condition start disagreeing about what a corrupt library looks like.
if [ -f "$(dirname "$0")/lib/common.sh" ]; then
  set +u
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/common.sh"
  # CAPTURED ON ITS OWN LINE, BEFORE `set -u` RESTORES IT — `set -u` succeeds, and would otherwise
  # overwrite `$?` with 0. This is the only status that observes a REAL load of common.sh; the
  # `require_lib` call below cannot, and is passed this value for exactly that reason.
  boot_rc=$?
  set -u
  command -v adb_require_bash >/dev/null 2>&1 && adb_require_bash "$@"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0
cd "$repo_root" || exit 0

# --- whose tree is this? (#241) ----------------------------------------------
# A checkout is a directory, and nothing stops two sessions opening the same one. This gate's
# inputs were purely git state, which carries no session identity, so a session that was merely
# TALKING ran the full suite over another session's mid-edit tree at every turn-end — and, because
# a red gate exits 2, could be blocked from ending its turn by work it did not write and must not
# touch. Observed twice on 2026-07-31; the second time the bystander was told to rebuild and commit
# nine generated files belonging to another session.
#
# THIS SITS BEFORE THE PROJECT-GATE `exec` DELIBERATELY. That second observation reported
# `build-drift FAIL`, which is a check name in THIS repo's own .claude/scripts/precommit-gate.sh —
# the project gate, not the global one. A check placed after the delegation would therefore miss
# the very incident it is here to prevent, and would silently do nothing in every repo that uses
# the documented escape hatch.
#
# IDENTITY COMES FROM THE ENVIRONMENT ONLY — never from the hook payload on stdin. Claude Code
# publishes the session id both ways, and the sibling implement-issue-gate.sh reads the payload as
# a fallback, but this gate must not: it `exec`s a project gate a few lines below, that child
# INHERITS stdin, and docs/per-project-overrides.md documents the inherited payload as part of the
# contract. Consuming it here to answer an optional question would leave every project gate at EOF
# to buy an identity we can do without. A host that exposes no CLAUDE_CODE_SESSION_ID simply gets
# "unknown", which is a documented, enforcing degradation — one rung shorter than the sibling
# gate's, and stated rather than implied.
#
# EVERY UNKNOWN KEEPS TODAY'S BEHAVIOR (run the gates, block on red). The dangerous direction here
# is not "gated once too often", it is "silently stopped gating": suppressing on unknown ownership
# would make the gate advisory for virtually every ordinary dirty tree, since a marker exists only
# during an /implement-issue run. That is the fail-silent class of #35 and docs/design-principles.md
# §5, so the suppression is deliberately narrow — it fires only on POSITIVE proof that another
# session owns this branch's run.
#
# NARROWER THAN THE ISSUE TITLE, and said plainly: this covers a foreign tree whose writer is
# running /implement-issue on THIS branch. A session editing the tree without a tracked run leaves
# no ownership evidence anywhere in git, so the bystander is still gated. Closing that gap needs
# per-session tree baselines, which is a different and much larger design.
# Is this a plausible session id? Applied to BOTH sides of the comparison, which is the point:
# checking only the marker's owner meant a MALFORMED current identity (environment contamination,
# a future harness format) was accepted as "me", compared unequal against a perfectly valid marker
# owner, and read as positive proof of another session — suppressing every gate at the moment this
# session's identity was in fact unknown. Same grammar, same direction, both sides.
plausible_session_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

foreign_run_marker() {
  local marker=".claude/state/implement-issue-active.json" raw rest m_branch="" m_owner="" m_phase="" mine
  [ -f "$marker" ] || return 1                       # no marker: the overwhelmingly common case
  mine="${CLAUDE_CODE_SESSION_ID:-}"
  plausible_session_id "$mine" || return 1           # cannot identify MYSELF -> unknown -> enforce
  command -v jq >/dev/null 2>&1 || return 1          # cannot read it -> unknown -> enforce
  command -v adb_owners_compatible >/dev/null 2>&1 || return 1   # no shared predicate -> enforce
  # ONE jq pass into a snapshot, so a concurrent write cannot hand back a mix of old and new
  # fields — and @tsv rather than two newline-separated values, because a NEWLINE INSIDE A FIELD
  # otherwise re-aims the whole decode. Measured on this implementation before the fix, and both
  # directions failed toward SUPPRESSION, i.e. toward the gate switching itself off:
  #
  #   owner  = "AAAA\nBBBB"  ->  decoded owner "AAAA"   — a truncation that is not my id
  #   branch = "feat\nevil"  ->  branch "feat" MATCHED, and the real owner was discarded in
  #                             favour of "evil", the second line of the branch
  #
  # @tsv escapes tab and newline inside values, so no field can contain the delimiter and no
  # field can shift. This is the same failure implement-issue-gate.sh pins for its own five-field
  # decode; the sibling learned it first (#180), and this decode is now held to the same bar.
  #
  # BOTH FIELDS MUST BE JSON STRINGS, tested in jq rather than inferred afterwards. `@tsv` happily
  # renders a NUMBER, so a marker carrying `"owner": 123` decoded to the perfectly well-formed
  # value "123" — which then differed from this session's id and SUPPRESSED THE GATE. A charset
  # test cannot catch that, because a session id legitimately contains digits (Claude Code's is a
  # UUID). The type is what separates a real owner field from a corrupt one, and corruption must
  # read as unknown. Emitting `empty` for a non-string leaves `raw` empty, which enforces.
  local tab; tab="$(printf '\t')"
  raw="$(jq -r 'if ((.branch|type) == "string") and ((.owner|type) == "string")
                   and (((.phase|type) == "string") or (.phase == null))
                then [.branch, .owner, (.phase // "")] | @tsv else empty end' "$marker" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1                          # absent or non-string field -> enforce
  case "$raw" in *"$tab"*"$tab"*) : ;; *) return 1 ;; esac   # need both delimiters to decode
  m_branch="${raw%%"$tab"*}"; rest="${raw#*"$tab"}"
  m_owner="${rest%%"$tab"*}"
  m_phase="${rest#*"$tab"}"

  # A COMPLETED RUN IS NOT A LIVE RUN. The workflow writes `phase=complete` at close-out, and the
  # marker can outlive that: the owning session may exit before its Stop hook removes it, and that
  # hook fail-closes on unverifiable PR state (`pr_stored_state` returns `unverified` with no `gh`
  # or on a network error) and so KEEPS the marker rather than deleting it. Nothing else can clear
  # it either — implement-issue-gate.sh deliberately leaves a foreign marker byte-identical (#180,
  # fixture L in check-implement-gate.sh). Without this arm, every other session on that branch
  # would skip every gate until the age bound expired, on the strength of a run that had finished.
  [ "$m_phase" = "complete" ] && return 1
  # POSITIVE PROOF MEANS A PLAUSIBLE ID, not merely a non-empty string. @tsv stops a field from
  # shifting, but it faithfully preserves a CORRUPT one — an owner of "<my-id>\nBBBB" survives as
  # a value that is genuinely not my id, and would therefore read as another session and suppress
  # the gate. Corruption is not evidence of a second session; it is evidence of a broken marker,
  # and this whole check exists to fire only on proof.
  #
  # WHAT IS ACCEPTED IS A GRAMMAR, not "any opaque token", and the difference is worth stating
  # rather than glossing: `[A-Za-z0-9._:-]+` covers a UUID (Claude Code's shape) and the usual
  # token spellings, but a harness whose session id used Unicode or other punctuation would read
  # as UNKNOWN and be gated rather than spared. That costs a bystander one gate run and can never
  # disable enforcement, so it is the right way round to be wrong — and widening it is one line
  # if another harness ever needs it.
  case "$m_owner" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  # The marker must be about THE BRANCH THIS TURN IS ON. A foreign run parked on some other
  # branch says nothing about the changes in front of us, and treating it as a blanket
  # suppression would turn one unrelated run into a checkout-wide gate bypass.
  [ -n "$m_branch" ] && [ "$m_branch" = "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" ] || return 1
  adb_owners_compatible "$m_owner" "$mine" && return 1
  # A MARKER IS NOT EVIDENCE OF A LIVE RUN FOREVER. A crashed or abandoned run leaves its marker
  # behind, and without a bound this check would then disable turn-end gating on that branch
  # indefinitely for every other session — permanently, if the repo also declares its gates
  # `full`. That is the enforcement-off combination this whole design is trying not to create.
  #
  # The canonical staleness predicate is `cleanup-lib.sh state-verdict marker`, and it is
  # deliberately NOT used here: it is a pure function whose `<pr-state>` argument the CALLER must
  # obtain from a live `gh` query, and a Stop hook that runs at every turn-end cannot afford a
  # network round trip. Age is the signal that is both offline and honest at this cadence. The
  # workflow re-stamps this marker at every phase transition, so a live run keeps it fresh.
  #
  # 9000s (2h30m) matches the run-claim lease in implement-lib.sh (#202), for the same reason:
  # comfortably longer than a legitimate quiet window, far shorter than "forever". The failure
  # direction is deliberate — a genuinely long-running run that goes this long without a phase
  # change simply stops sparing bystanders, which is the ENFORCING direction, not the silent one.
  local age stale="${ADB_MARKER_STALE_SECS:-9000}"
  case "$stale" in ''|*[!0-9]*) stale=9000 ;; esac
  age="$(adb_age_secs "$marker")"
  [ -n "$age" ] || return 1                          # cannot age it -> unknown -> enforce
  [ "$age" -le "$stale" ] || return 1                # too old to prove a run is live -> enforce
  # Says only what was READ. An earlier draft asserted that the other session "gates that work"
  # and that this one "did not write it" — neither is established by a marker, which records who
  # STARTED a run, not who made the changes now in the tree.
  printf 'precommit-gate: skipped — .claude/state records an /implement-issue run on this branch owned\n' >&2
  printf 'precommit-gate: by another session (%.8s…), last updated %ss ago. Gates are left to that run (#241).\n' "$m_owner" "$age" >&2
  return 0
}
foreign_run_marker && exit 0

# Defer to a project-local gate if one exists and it isn't this very file — by RUNNING it, not by
# stepping aside. `exit 0` here was enforcement silently OFF (#240): nothing else invokes a project
# gate. No project-level Stop hook is wired by install.sh, the adapter, or bin/baseline, so a repo
# that followed the documented escape hatch ("ship a full replacement script at that exact path")
# ended up with a gate script nothing ran AND the global gate standing down — strictly worse than
# before, and the exact fail-silent class #35 made this file fail loud about.
#
# `exec` is what makes the project's script genuinely BE the gate: it inherits stdin (the hook
# payload), and its exit status becomes this hook's, so a project gate can still block a stop with
# 2. The `-ef` inode test above is what keeps this from re-entering itself when the global copy IS
# the project copy. A non-executable script is run via bash rather than failing the hook, since
# `chmod +x` is easy to forget in a repo that ships one.
proj_gate="$repo_root/.claude/scripts/precommit-gate.sh"
if [ -e "$proj_gate" ] && [ ! "$proj_gate" -ef "$0" ]; then
  [ -x "$proj_gate" ] && exec "$proj_gate" "$@"
  exec bash "$proj_gate" "$@"
fi

# --- fail-loud dependency loading (#35) --------------------------------------
# This gate's shared libraries live in the sibling lib/ (installed as ~/.<agent>/scripts/lib).
# They are REQUIRED, not optional. A missing/corrupt library is a broken install, and a gate
# that silently no-ops then is enforcement secretly OFF — so it FAILS LOUD (exit 2, blocking),
# never exit 0. Resolving the default branch and the change set needs common.sh's
# adb_default_branch (single-source: never re-implement it here, per docs/design-principles.md),
# so common.sh is required up front — before the branch/changes no-op checks below.
lib_dir="$(dirname "$0")/lib"
fail_loud() {
  printf '\nprecommit-gate: FATAL — %s\n' "$1" >&2
  printf 'This is NOT a pass. The quality gates cannot run, so the turn is BLOCKED. The baseline\n' >&2
  printf "install is incomplete or an installed path moved — repair it with 'baseline update'\n" >&2
  printf '(or re-run install.sh from your baseline clone), then retry.\n' >&2
  exit 2
}
# Source a REQUIRED sibling library or fail loud: a missing file, an un-sourceable one, or one
# sourced but missing its expected function (a corrupt/truncated library) each block the turn.
#
# `set +u` HERE TOO (#317), for the reason the floor block above spells out. The relaxation is not
# decorative at this site: the common.sh call below is short-circuited by the double-source guard
# (see <prior-rc>), but `project-gates.sh` IS a real load, and its own top level runs under this
# caller's options until it sets `set -u` itself.
#
# AND THAT LEAVES ONE DOOR OPEN, WHICH IS #342 AND NOT FIXABLE HERE. `project-gates.sh` runs
# `set -u` at its own line 88, mid-file, so this relaxation is CANCELLED FROM INSIDE the library
# partway through the load: an unbound expansion below that line is fatal again, and the gate exits
# 1 exactly as it did before this change. Reproduced. A caller cannot stop a sourced file from
# turning the option back on — the fix is that library's dual-role `set -u`, so do not read the
# relaxation below as covering the whole of project-gates.sh, and do not "strengthen" it here.
#
# <prior-rc> (optional) OVERRIDES a zero status, because at the common.sh call site this function's
# own `.` cannot observe a load at all. `common.sh` opens with a double-source guard
# (`_ADB_COMMON_SH_LOADED`), so once the bootstrap above has loaded it this `.` returns 0 THROUGH
# the guard without reading the file — and the bootstrap runs on every ordinary invocation, so that
# is the normal path, not a corner. A common.sh truncated AFTER the guard and after the function
# probed for therefore failed the bootstrap, short-circuited here, satisfied BOTH checks below, and
# ran the whole gate on a partially-loaded library reporting a clean pass. Measured at rc 0 with the
# configured gates observed executing. Same defect an independent review found on #299's PR.
#
# <prior-rc> IS A SHELL EXIT STATUS AND NOTHING ELSE — an integer, or absent. Both call sites pass
# either nothing or a captured `$?`, and the numeric comparison below is what enforces it: a
# non-numeric value makes `[ … -eq … ]` error rather than compare, which lands on `fail_loud`. That
# is the safe direction, and it is stated here rather than validated because a check that could only
# ever fire on a future caller's bug is a worse guard than the contract it would be checking.
require_lib() {  # <path> <expected-fn> [prior-rc: a shell exit status, or absent]
  local rc
  [ -f "$1" ] || fail_loud "shared library not found: $1"
  set +u
  # shellcheck source=/dev/null
  . "$1"
  # Its OWN line, before `set -u` restores it — see the floor block above.
  rc=$?
  set -u
  [ "${3:-0}" -eq 0 ] || rc="$3"
  [ "$rc" -eq 0 ] || fail_loud "shared library failed to source: $1"
  command -v "$2" >/dev/null 2>&1 || fail_loud "$1 did not define $2 (corrupt library)"
}
require_lib "$lib_dir/common.sh" adb_default_branch "${boot_rc:-0}"

# Resolve the default branch (origin/HEAD → main → master → "main").
default_branch="$(adb_default_branch "$repo_root")"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$branch" = "$default_branch" ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  exit 0
fi

# Are there any changes at all on this branch? (committed vs base + working tree)
# `--no-renames` so a moved file surfaces BOTH its old and new path — a gate scoped to
# the area a file moved OUT of must still see the change (see project-gates.sh scope).
base_ref="origin/$default_branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="$default_branch"
committed=""
if git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
  committed="$(git diff --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null || true)"
fi
staged="$(git diff --no-renames --name-only --cached 2>/dev/null || true)"
unstaged="$(git diff --no-renames --name-only 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
changed="$(printf '%s\n%s\n%s\n%s\n' "$committed" "$staged" "$unstaged" "$untracked" | sort -u | sed '/^$/d')"
[ -z "$changed" ] && exit 0

# We are on a feature branch WITH changes: the gate WILL run. The gate library is required
# here too — a missing/corrupt one is the same broken-install fail-loud condition as common.sh
# above (a silent skip here was the old fail-silent bug #35 fixes), never a silent skip.
require_lib "$lib_dir/project-gates.sh" adb_run_gates

# Pass the branch change set so a path-scoped gate ([gates.scope] in agents.toml) runs
# only when it touches a matching file — the escape hatch that lets a repo express
# apps/**-style scoping without forking this whole script.
#
# And declare the CONTEXT: this is the per-turn caller (#240). A gate declared
# `[gates.cadence] <label> = "full"` is skipped here and reported, so a repo whose `test` gate is
# its own CI mirror no longer re-runs CI at the end of every turn. Nothing else changes: a repo
# with no [gates.cadence] table has every gate at the default `always` and behaves exactly as
# before. This is the ONLY caller that passes `turn-end` — the workflows' in-loop
# `project-gates.sh run` is a full run and still runs everything.
if adb_run_gates "$repo_root" "$changed" turn-end; then
  exit 0
fi

printf '\nprecommit-gate: blocking stop — fix the failing gate(s) above before ending the turn.\n' >&2
exit 2
