#!/usr/bin/env bash
# ai-dev-baseline — unit tests for the release-goal convention helper
# (scripts/lib/release-convention.sh, #27). OFFLINE: it exercises the dispatch, arg-parsing,
# usage, and the fail-loud gh guard WITHOUT touching a real GitHub repo. The gh-mutating paths
# (milestone/label creation, marker seeding) are behavioral and belong to the /roadmap +
# release-readiness e2e coverage tracked in #45 — this check guards the surface that runs before
# any gh call.
#
# Lives OUTSIDE scripts/lib/ on purpose (install.sh symlinks that dir into a user's runtime).
# Usage: bash scripts/check-release-convention.sh   (exit 0 = all pass, 1 = a failure)

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
RC="$ROOT/scripts/lib/release-convention.sh"
# shellcheck source=/dev/null
. scripts/check-lib.sh   # ok/bad/eq/yes/no/has/hasnt + check_summary

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stub `gh` whose `auth status` fails, to prove require_gh fails loud (never a silent no-op).
BIN="$work/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 1 ;;   # simulate: not authenticated
esac
exit 0
EOF
chmod +x "$BIN/gh"

# rcx <args...> : run the helper, capture combined output + rc via globals OUT/RC_.
rcx() { OUT="$(bash "$RC" "$@" 2>&1)"; RC_=$?; }
# rcx_auth <args...> : same, but with the failing-auth stub gh first on PATH.
rcx_auth() { OUT="$(PATH="$BIN:$PATH" bash "$RC" "$@" 2>&1)"; RC_=$?; }

# ============================ usage / dispatch ============================
rcx -h;            yes "$RC_" "-h exits 0";            has "$OUT" "release-goal convention" "-h prints the usage header"
rcx --help;        yes "$RC_" "--help exits 0"
rcx;               no  "$RC_" "no subcommand exits nonzero"
rcx bogus;         no  "$RC_" "unknown subcommand exits nonzero"; has "$OUT" "unknown subcommand" "unknown subcommand names itself"
rcx init -h;       yes "$RC_" "init -h exits 0";       has "$OUT" "release-goal convention" "init -h prints usage"

# ============================ arg parsing ============================
rcx init --release-name;   no "$RC_" "init --release-name w/o value exits nonzero"; has "$OUT" "needs a value" "missing value is named"
rcx init --bogus;          no "$RC_" "init unknown option exits nonzero";            has "$OUT" "unknown option" "unknown option is named"
rcx status --bogus;        no "$RC_" "status unknown option exits nonzero"

# ============================ fail-loud gh guard ============================
rcx_auth init;    no "$RC_" "init with unauthenticated gh exits nonzero";   has "$OUT" "not authenticated" "init surfaces the auth failure"
rcx_auth status;  no "$RC_" "status with unauthenticated gh exits nonzero"; has "$OUT" "not authenticated" "status surfaces the auth failure"

check_summary "release-convention"
