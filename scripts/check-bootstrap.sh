#!/usr/bin/env bash
# ai-dev-baseline — entry-point self-location guard (#343).
#
# Every entry point resolves its own clone root BEFORE it can source scripts/lib/common.sh, and
# that resolution used to be `"$(cd "$(dirname "$src")" && pwd)"`. Command substitution strips
# EVERY trailing newline, so a clone directory whose name ENDS in one arrived already shortened
# into a DIFFERENT path that frequently exists — an innocent sibling clone. The entry point then
# sourced, linked and verified against that sibling and reported success. #324's manifest guard
# cannot see it: by the time `adb_agent_manifest` is handed the value it is already truncated and
# looks perfectly representable.
#
# WHAT THIS PINS, and each rule is driven red by --mutation below:
#   1. COVERAGE   — the declared site set and the files carrying the block are the SAME set, so a
#                   new entry point cannot join without the block and a site cannot be dropped.
#   2. IDENTITY   — every ADB-BOOTSTRAP block is byte-identical, and every ADB-SYMWALK block is.
#                   This is what stands in for `source the primitive, never copy it`: a bootstrap
#                   cannot source the library whose location it is computing (D30's rule, applied
#                   one layer out), so the law is enforced by pinned identity instead of by reuse.
#   3. SPELLING   — no declared site still carries a superseded lossy capture.
#   4. RESOLUTION — run under a real `clone<NL>` beside a real `clone` sibling, every site's
#                   prologue resolves the TRUE path, newline intact.
#   5. ISOLATION  — running each entry point for real there sources the right tree's library and
#                   leaves the sibling byte-unchanged.
#
# WHAT IT DOES NOT PROVE, said plainly because a guard that overstates itself is worse than none:
#
#   * The two ADAPTERS were never defective, and rule 4's mutation cannot fire for them. Their own
#     capture resolves `…/clone<NL>/agents/<token>`, where the newline is INTERNAL and therefore
#     survives `$(…)` — the same correction D64 already recorded for the manifest producer, which
#     the issue's evidence list did not carry over. They are in the declared set for uniformity and
#     are held by rules 1-3, which DO fire for them. They are excluded from rule 4's mutation
#     rather than counted as passing it.
#   * `scripts/build.sh` reaches its own library by a relative path, so rule 5's canary cannot
#     discriminate for it. It is held by rules 1-4.
#   * The 27 `scripts/check-*.sh` suites that compute `ROOT="$(pwd)"` after a `cd` carry the same
#     lossy capture. They are test infrastructure rather than pre-source production bootstraps and
#     are deliberately out of this file's declared set. Tracked separately.
#
# Usage: bash scripts/check-bootstrap.sh [--mutation]   (exit 0 = all pass, 1 = a failure)

# bash 5.3 runtime floor (#256) — FIRST, and before both `set -u` and the cd, for the reasons
# check-install-guard.sh's header states. The load is confirmed by probing for the function.
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

MODE="${1:-}"

# THE DECLARED SET. Adding an entry point means adding it here; rule 1 makes the omission red.
BOOTSTRAP_SITES="install.sh
uninstall.sh
bin/baseline
bin/agent-init
agents/codex/adapter.sh
agents/gemini/adapter.sh
scripts/build.sh"

# The two that are reached through a PATH symlink and therefore walk one first.
SYMWALK_SITES="bin/baseline
bin/agent-init"

# The sites whose resolved root is what they use to FIND scripts/lib/common.sh. build.sh is absent
# on purpose: it sources its library by a relative path, so the canary cannot speak for it.
CANARY_SITES="install.sh
uninstall.sh
bin/baseline
bin/agent-init
agents/codex/adapter.sh
agents/gemini/adapter.sh"

# The two adapters, whose PRE-FIX capture was already correct at their depth. Rule 4's mutation is
# skipped for them and SAID to be skipped, rather than reported as a pass it never earned.
NOT_PREVIOUSLY_DEFECTIVE="agents/codex/adapter.sh
agents/gemini/adapter.sh"

# `pass`/`fail` are initialized by check-lib.sh, sourced above — the ONE home for that counter.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

in_set() { case "
$1
" in *"
$2
"*) return 0 ;; *) return 1 ;; esac; }

# Print a marked block, BEGIN line through END line inclusive.
extract_block() {
  awk -v b="# $2-BEGIN" -v e="# $2-END" '
    index($0, b) == 1 { f = 1 }
    f                 { print }
    index($0, e) == 1 { f = 0 }' "$1"
}

# ---------------------------------------------------------------------------
# Rule 1 — COVERAGE. The declared set and the marked files are the same set.
# ---------------------------------------------------------------------------
marked="$(grep -rl '^# ADB-BOOTSTRAP-BEGIN' --include='*.sh' --include='baseline' --include='agent-init' . 2>/dev/null \
          | sed 's|^\./||' | LC_ALL=C sort)"
declared="$(printf '%s\n' "$BOOTSTRAP_SITES" | LC_ALL=C sort)"
eq "$marked" "$declared" "coverage: the marked files are exactly the declared entry-point set"

for s in $BOOTSTRAP_SITES; do
  if [ -f "$s" ]; then ok; else bad "coverage: declared site $s does not exist"; fi
done

marked_sym="$(grep -rl '^# ADB-SYMWALK-BEGIN' --include='*.sh' --include='baseline' --include='agent-init' . 2>/dev/null \
              | sed 's|^\./||' | LC_ALL=C sort)"
eq "$marked_sym" "$(printf '%s\n' "$SYMWALK_SITES" | LC_ALL=C sort)" \
   "coverage: the symlink-walk block appears in exactly the two PATH-reachable commands"

# ---------------------------------------------------------------------------
# Rule 2 — IDENTITY. Every copy of each block is byte-identical.
# ---------------------------------------------------------------------------
ref=""; refsite=""
for s in $BOOTSTRAP_SITES; do
  blk="$(extract_block "$s" ADB-BOOTSTRAP)"
  if [ -z "$blk" ]; then bad "identity: $s carries no ADB-BOOTSTRAP block"; continue; fi
  if [ -z "$refsite" ]; then ref="$blk"; refsite="$s"; ok; continue; fi
  eq "$blk" "$ref" "identity: $s's bootstrap block matches $refsite byte-for-byte"
done

refsym=""; refsymsite=""
for s in $SYMWALK_SITES; do
  blk="$(extract_block "$s" ADB-SYMWALK)"
  if [ -z "$blk" ]; then bad "identity: $s carries no ADB-SYMWALK block"; continue; fi
  if [ -z "$refsymsite" ]; then refsym="$blk"; refsymsite="$s"; ok; continue; fi
  eq "$blk" "$refsym" "identity: $s's symwalk block matches $refsymsite byte-for-byte"
done

# The block must actually contain the three things that make it lossless. Identity alone would be
# satisfied by six identical copies of the OLD spelling.
has "$ref" '${_adb_boot_src%/*}'  "identity: the block replaces \$(dirname …) with parameter expansion"
has "$ref" "printf 'X'"           "identity: the block bounds the pwd capture with a sentinel"
has "$ref" '${_adb_boot_abs%X}'   "identity: and strips that sentinel back off"
has "$refsym" 'readlink -n --'    "identity: the symwalk reads link targets with readlink -n"

# ---------------------------------------------------------------------------
# Rule 3 — SPELLING. No declared site still carries a superseded lossy capture.
# ---------------------------------------------------------------------------
for s in $BOOTSTRAP_SITES; do
  if grep -q 'cd "\$(dirname' "$s"; then
    bad "spelling: $s still carries the lossy \$(cd \"\$(dirname …)\" && pwd) capture"
  else ok; fi
done
for s in $SYMWALK_SITES; do
  if grep -q 'readlink "\$' "$s"; then
    bad "spelling: $s still carries a plain readlink capture (lossy on BSD)"
  else ok; fi
done

# ---------------------------------------------------------------------------
# The fixture. A clone directory whose name really ENDS in a newline, beside a real sibling at the
# truncated path — the superseded input itself, not a stand-in with an INTERNAL newline (that case
# already survives `$(…)` and is what #324 covers).
#
# `mkdir "$w/clone"$'\n'` is the whole point: probed on APFS and ext4 alike, only `/` and NUL are
# forbidden in a component, and the suites at check-common-lib.sh (7c) and check-agent-init.sh
# already build one on both CI runners.
# ---------------------------------------------------------------------------
write_stub() {   # <path> <RIGHT|WRONG> <what adb_require_bash does>
  mkdir -p "${1%/*}"
  cat > "$1" <<STUB
echo ADBBOOT:$2
adb_require_bash() { $3; }
STUB
}

# SETS `FX_NL` AND `FX_SIB`; it does NOT echo them. A `$(build_fixture …)` capture would strip the
# clone's trailing newline on the way out — this file's entire subject — and every fixture would
# silently be built against the sibling. The bug bit this harness during development, which is why
# the contract is a global rather than a return value.
build_fixture() {   # <dest> <what adb_require_bash does>
  bf_dest="$1"; bf_after="$2"
  FX_NL="$bf_dest/clone
"
  FX_SIB="$bf_dest/clone"
  mkdir -p "$FX_SIB"
  for bf_s in $BOOTSTRAP_SITES; do
    case "$bf_s" in
      */*) mkdir -p "$FX_NL/${bf_s%/*}" ;;
      *)   mkdir -p "$FX_NL" ;;
    esac
    cp "$ROOT/$bf_s" "$FX_NL/$bf_s"
    chmod +x "$FX_NL/$bf_s"
  done
  write_stub "$FX_NL/scripts/lib/common.sh" RIGHT "$bf_after"
  write_stub "$FX_SIB/scripts/lib/common.sh" WRONG "$bf_after"
}

# WHAT EACH SITE IS SUPPOSED TO RESOLVE, relative to the clone root. It is NOT the clone root
# everywhere: the adapters compute `_here`, their OWN directory, and the block is parameterized by
# `_adb_boot_rel` precisely so one spelling serves both depths. Asserting "the clone root" for all
# of them was a bug in this harness, not in the subject.
site_suffix() {
  case "$1" in
    agents/codex/adapter.sh)  printf '/agents/codex'  ;;
    agents/gemini/adapter.sh) printf '/agents/gemini' ;;
    *)                        printf '' ;;
  esac
}

# The resolved value of ONE site's prologue, run in place, with an X sentinel so the comparison
# can see a trailing newline the shell would otherwise strip. Canary lines are filtered: a prologue
# that sources its library before the block (build.sh does) prints one first, and it is not the
# value under test.
probe_resolve() {   # <nl-root> <site>
  pr_nl="$1"; pr_site="$2"
  awk '1; index($0, "# ADB-BOOTSTRAP-END") == 1 { exit }' "$pr_nl/$pr_site" > "$work/probe.tmp"
  printf '\nprintf "%%sX" "$_adb_boot_abs"\n' >> "$work/probe.tmp"
  cp "$work/probe.tmp" "$pr_nl/$pr_site"
  bash "$pr_nl/$pr_site" 2>/dev/null | sed '/^ADBBOOT:/d'
}

# ---------------------------------------------------------------------------
# Rule 4 — RESOLUTION. Every site's prologue resolves the TRUE path, newline intact.
# ---------------------------------------------------------------------------
for s in $BOOTSTRAP_SITES; do
  fx="$work/r4-$(printf '%s' "$s" | tr '/.' '__')"
  build_fixture "$fx" ':'; nlroot="$FX_NL"
  got="$(probe_resolve "$nlroot" "$s")"
  sfx="$(site_suffix "$s")"
  eq "$got" "${nlroot}${sfx}X" "resolution: $s resolves inside the real clone, trailing newline intact"
  hasnt "$got" "${fx}/clone${sfx}X" "resolution: $s does not resolve onto the truncated sibling"
done

# Invoked through a RELATIVE spelling from inside the clone, which is how the installer is
# actually run (`./install.sh`) and a different path through the same block.
fx="$work/r4-rel"; build_fixture "$fx" ':'; nlroot="$FX_NL"
awk '1; index($0, "# ADB-BOOTSTRAP-END") == 1 { exit }' "$nlroot/install.sh" > "$work/probe.tmp"
printf '\nprintf "%%sX" "$_adb_boot_abs"\n' >> "$work/probe.tmp"
cp "$work/probe.tmp" "$nlroot/install.sh"
got="$( cd "$nlroot" && bash ./install.sh 2>/dev/null )"
eq "$got" "${nlroot}X" "resolution: ./install.sh from inside the clone resolves the real clone"

# ---------------------------------------------------------------------------
# Rule 4b — the SYMLINK WALK, which carries two truncation sites of its own.
#
# Both fixtures put a DECOY on the truncated path, because that is the only shape in which the
# loss is observable: a lost byte that merely misnames a file leaves `${self%/*}` pointing at the
# same directory, and the resolved root comes out right anyway. The defect is reachable only when
# the shortened name is itself a link into another tree — which is the same "a different path that
# frequently exists" hazard as the clone root, one level in.
# ---------------------------------------------------------------------------
make_probe() {   # <source-entry-point> <destination>
  awk '1; index($0, "# ADB-BOOTSTRAP-END") == 1 { exit }' "$1" > "$work/probe.tmp"
  printf '\nprintf "%%sX" "$_adb_boot_abs"\n' >> "$work/probe.tmp"
  mkdir -p "${2%/*}"
  cp "$work/probe.tmp" "$2"
  chmod +x "$2"
}

# Sets FX_NL / FX_SIB / SYM_ENTRY. `half` selects which truncation the decoy is reachable through.
build_symwalk_fixture() {   # <dest> <dirname|readlink>
  build_fixture "$1" ':'
  bs_probe_src="$FX_NL/bin/baseline"
  make_probe "$bs_probe_src" "$work/sym-probe"
  # The decoy the truncated spelling lands on: a real script in the SIBLING tree.
  mkdir -p "$FX_SIB/bin"
  cp "$work/sym-probe" "$FX_SIB/bin/baseline"; chmod +x "$FX_SIB/bin/baseline"
  if [ "$2" = dirname ]; then
    # A PATH directory whose own name ends in a newline, holding a RELATIVE link. Plain
    # `$(dirname "$self")` shortens it onto its sibling, where a second link waits.
    bs_pd="$1/pd
"
    mkdir -p "$bs_pd" "$1/pd"
    cp "$work/sym-probe" "$FX_NL/bin/baseline"; chmod +x "$FX_NL/bin/baseline"
    ln -s "$FX_NL/bin/baseline" "$bs_pd/impl"
    ln -s "$FX_SIB/bin/baseline" "$1/pd/impl"
    ln -s "impl" "$bs_pd/baseline"
    SYM_ENTRY="$bs_pd/baseline"
  else
    # A link whose TARGET ends in a newline. Plain `readlink` cannot round-trip it — BSD appends a
    # terminator only when the value does not already end in one, so `impl` and `impl<NL>` come
    # back identical; GNU appends unconditionally and `$(…)` then strips both. Either way the
    # walk continues to `bin/impl`, which is a link into the sibling.
    cp "$work/sym-probe" "$FX_NL/bin/impl
"
    chmod +x "$FX_NL/bin/impl
"
    ln -s "$FX_SIB/bin/baseline" "$FX_NL/bin/impl"
    rm -f "$FX_NL/bin/baseline"
    ln -s "impl
" "$FX_NL/bin/baseline"
    SYM_ENTRY="$FX_NL/bin/baseline"
  fi
}

for half in dirname readlink; do
  fx="$work/r4b-$half"
  build_symwalk_fixture "$fx" "$half"
  got="$(bash "$SYM_ENTRY" 2>/dev/null | sed '/^ADBBOOT:/d')"
  eq "$got" "${FX_NL}X" "symwalk/$half: the walk stays inside the real clone"
  hasnt "$got" "${FX_SIB}X" "symwalk/$half: and never follows the decoy into the sibling"
done

# ---------------------------------------------------------------------------
# Rule 5 — ISOLATION. Run the real entry points there: each must load the RIGHT tree's library,
# and the sibling must come out byte-identical. This is the acceptance criterion stated as
# something observable — "reads from, writes into, or links against the sibling" is not a
# predicate, a canary line plus a checksum manifest is.
# ---------------------------------------------------------------------------
fx="$work/r5"; build_fixture "$fx" 'exit 0'; nlroot="$FX_NL"
sib="$fx/clone"
manifest() { find "$1" -type f | LC_ALL=C sort | while IFS= read -r p; do
               printf '%s  ' "$p"; cksum < "$p"; done; }
before="$(manifest "$sib")"
for s in $CANARY_SITES; do
  out="$(bash "$nlroot/$s" 2>&1)"
  has   "$out" "ADBBOOT:RIGHT" "isolation: $s sources the real clone's library"
  hasnt "$out" "ADBBOOT:WRONG" "isolation: $s never sources the sibling's library"
done
after="$(manifest "$sib")"
eq "$after" "$before" "isolation: the sibling tree is byte-identical after every entry point ran"

# ---------------------------------------------------------------------------
# --mutation — the negative half. Each site's block is reverted to the superseded spelling ONE AT
# A TIME, the revert is verified to have applied, and rule 4 must come back RED for that site.
# Without this the whole file could be deleted and nothing would notice: a resolution check that
# resolves nothing reports exactly what a clean run reports.
# ---------------------------------------------------------------------------
if [ "$MODE" = "--mutation" ]; then
  for s in $BOOTSTRAP_SITES; do
    if in_set "$NOT_PREVIOUSLY_DEFECTIVE" "$s"; then
      check_note "mutation: SKIPPED for $s — its pre-fix capture resolved a path whose newline is"
      check_note "          INTERNAL, so the superseded spelling was already correct at that depth."
      check_note "          Held by the coverage, identity and spelling rules instead."
      continue
    fi
    fx="$work/mut-$(printf '%s' "$s" | tr '/.' '__')"
    build_fixture "$fx" ':'; nlroot="$FX_NL"
    # Revert the block body to the exact superseded idiom, keeping the surrounding wiring.
    awk '
      index($0, "# ADB-BOOTSTRAP-BEGIN") == 1 { skip = 1
        print "_adb_boot_abs=\"$(cd \"$(dirname \"$_adb_boot_src\")/$_adb_boot_rel\" && pwd)\""
        print "# ADB-BOOTSTRAP-END"
        next }
      index($0, "# ADB-BOOTSTRAP-END") == 1   { skip = 0; next }
      !skip                                    { print }' "$nlroot/$s" > "$work/mut.tmp"
    cp "$work/mut.tmp" "$nlroot/$s"
    if grep -q 'cd "\$(dirname "\$_adb_boot_src")' "$nlroot/$s"; then ok
    else bad "mutation: the pre-fix revert did not apply to $s"; continue; fi
    got="$(probe_resolve "$nlroot" "$s")"
    sfx="$(site_suffix "$s")"
    if [ "$got" = "${nlroot}${sfx}X" ]; then
      bad "mutation: $s still resolved correctly with the PRE-FIX capture — the fixture proves nothing"
    else ok; fi
    eq "$got" "${fx}/clone${sfx}X" "mutation: $s with the pre-fix capture resolves the SIBLING (observed failing)"
  done

  # And the symwalk's two halves, reverted the same way, against the same decoy fixtures.
  for half in dirname readlink; do
    fx="$work/mutsym-$half"
    build_symwalk_fixture "$fx" "$half"
    for tgt in "$FX_NL/bin/baseline" "$FX_NL/bin/impl
"; do
      [ -f "$tgt" ] || continue
      awk '
        index($0, "# ADB-SYMWALK-BEGIN") == 1 { skip = 1
          print "while [ -L \"$_adb_boot_src\" ]; do"
          print "  _adb_boot_link=\"$(readlink \"$_adb_boot_src\")\""
          print "  case \"$_adb_boot_link\" in"
          print "    /*) _adb_boot_src=\"$_adb_boot_link\" ;;"
          print "    *)  _adb_boot_src=\"$(dirname \"$_adb_boot_src\")/$_adb_boot_link\" ;;"
          print "  esac"
          print "done"
          next }
        index($0, "# ADB-SYMWALK-END") == 1   { skip = 0; next }
        !skip                                  { print }' "$tgt" > "$work/mut.tmp"
      cp "$work/mut.tmp" "$tgt"
    done
    if grep -q 'readlink "\$_adb_boot_src"' "$work/mut.tmp"; then ok
    else bad "mutation: the pre-fix symwalk revert did not apply ($half)"; continue; fi
    got="$(bash "$SYM_ENTRY" 2>/dev/null | sed '/^ADBBOOT:/d')"
    if [ "$got" = "${FX_NL}X" ]; then
      bad "mutation: the pre-fix symwalk ($half half) still resolved correctly — that half is unproven"
    else ok; fi
    eq "$got" "${FX_SIB}X" "mutation: the pre-fix symwalk ($half half) follows the decoy into the SIBLING"
  done
fi

check_summary "check-bootstrap"
