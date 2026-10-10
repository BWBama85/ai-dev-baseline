#!/usr/bin/env bash
# ai-dev-baseline — the vendored scripts/shmutant.sh is exactly the release it pins (#519, D125).
#
# Usage: bash scripts/check-shmutant-pin.sh [--self-test]   (exit 0 = pass, 1 = fail, 2 = usage)
#
# scripts/shmutant.sh is a THIRD-PARTY file: BWBama85/shmutant's single-file harness, vendored byte
# for byte from tag v0.2.0 (commit 303e451) and never edited here. A defect found in it is filed at
# BWBama85/shmutant, and a fix arrives by copying a newer release over it. Beside it,
# scripts/shmutant.sh.sha256 records its SHA-256 in the line format of the release's own CHECKSUMS,
# so the pin is also checkable by hand: `cd scripts && shasum -a 256 -c shmutant.sh.sha256`.
#
# This check fails when the file no longer matches that record, which is the one thing that makes
# "vendored, never edited" a fact rather than a policy:
#   * the record is exactly one newline-terminated line, `<64 lowercase hex><two spaces>shmutant.sh`;
#     a second line or a missing newline is a record somebody hand-edited, and is refused rather
#     than read in part;
#   * the vendored file is a regular file, not a link that could point anywhere;
#   * its digest comes from common.sh's `adb_sha256` — NEVER from the vendored file's own
#     `checksum` subcommand, which an edited file could make print any digest it liked.
#
# An upgrade is two edits in one PR — the file and the record — so it is visible in review. This
# cannot tell whether the recorded digest is the one the release published; that is checked when a
# pin is taken (D125).
#
# --self-test checks the SHIPPED pair first, exactly as the plain mode does (CI and the registry run
# only this mode), then drives every rule red on copies under one `mktemp -d`: a one-byte edit to
# the file, a record with a second line, without its newline, past its size, with uppercase hex,
# naming another file, holding a NUL, a link in either file's place, and each of the two files
# missing. Never touches the tracked tree.

# bash 5.3 runtime floor (#256) — FIRST, before `set -u` and before the cd; the load is confirmed
# by probing for the function, not by the source's exit status.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/common.sh" 2>/dev/null
command -v adb_require_bash >/dev/null 2>&1 || {
  printf '%s: FATAL — scripts/lib/common.sh is missing or corrupt; cannot verify the bash floor\n' "${0##*/}" >&2
  exit 1
}
adb_require_bash "$@"
set -u
# `nocasematch` (inheritable through an exported BASHOPTS) would make the record's `[[ =~ ]]` grammar
# accept `SHMUTANT.SH` and uppercase hex; the grammar is case-exact, so the option is off here.
shopt -u nocasematch
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/check-lib.sh

MODE=check
case "${1:-}" in
  "")          ;;
  --self-test) MODE=self-test ;;
  *)           echo "usage: check-shmutant-pin.sh [--self-test]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: check-shmutant-pin.sh [--self-test]" >&2; exit 2; }

# pin_verdict <dir> — does <dir>/shmutant.sh match <dir>/shmutant.sh.sha256? Prints the digest on
# success, the reason on failure; returns 0 or 1. The ONE predicate both modes ask.
pin_verdict() {
  local d="$1" rec want got snap
  if [ -L "$d/shmutant.sh" ] || [ ! -f "$d/shmutant.sh" ]; then
    printf '%s/shmutant.sh is missing, or is not a regular file\n' "$d"; return 1
  fi
  if [ -L "$d/shmutant.sh.sha256" ] || [ ! -f "$d/shmutant.sh.sha256" ]; then
    printf '%s/shmutant.sh.sha256 is missing, or is not a regular file — the pin has no record\n' "$d"; return 1
  fi
  # ONE BOUNDED SNAPSHOT of the record, one byte past what a one-line record can be, and every check
  # below reads it — checking the path and then reopening it would judge one set of bytes and read
  # another. WHOLE OR NOTHING: `$(…)` strips trailing newlines, so the final newline and the line
  # count are asked of the snapshot itself, before its content is read — the final byte (and no NUL,
  # and the size) by common.sh's shared whole-file rule, rather than a second copy.
  snap="$(mktemp)" || { printf 'a snapshot of %s/shmutant.sh.sha256 could not be made\n' "$d"; return 1; }
  if ! head -c 129 "$d/shmutant.sh.sha256" > "$snap" 2>/dev/null; then
    rm -f "$snap"; printf '%s/shmutant.sh.sha256 could not be read\n' "$d"; return 1
  fi
  if ! adb_bytes_whole "$snap" 128 || [ "$(wc -l < "$snap" | tr -d ' ')" != 1 ]; then
    rm -f "$snap"; printf '%s/shmutant.sh.sha256 is not exactly one newline-terminated line\n' "$d"; return 1
  fi
  rec="$(cat "$snap")" || { rm -f "$snap"; printf '%s/shmutant.sh.sha256 could not be read\n' "$d"; return 1; }
  rm -f "$snap"
  if [[ ! "$rec" =~ ^([0-9a-f]{64})\ \ shmutant\.sh$ ]]; then
    printf '%s/shmutant.sh.sha256 is not `<64 lowercase hex>  shmutant.sh`: [%s]\n' "$d" "$rec"; return 1
  fi
  want="${BASH_REMATCH[1]}"
  got="$(adb_sha256 "$d/shmutant.sh")" || { printf 'the digest of %s/shmutant.sh could not be computed\n' "$d"; return 1; }
  if [ "$got" != "$want" ]; then
    printf '%s/shmutant.sh has SHA-256 %s, but the pin records %s — the vendored file was edited, or replaced without its record\n' \
      "$d" "$got" "$want"
    return 1
  fi
  printf '%s\n' "$got"
}

if [ "$MODE" = check ]; then
  if out="$(pin_verdict scripts)"; then
    ok
    printf 'shmutant-pin: scripts/shmutant.sh matches its pinned digest (%s)\n' "$out"
  else
    bad "shmutant-pin: $out"
  fi
  check_summary "check-shmutant-pin"
  exit 0
fi

# ================================ --self-test ====================================================
work="$(mktemp -d)" || { echo "check-shmutant-pin: FATAL — cannot create a scratch directory" >&2; exit 1; }
check_exit_guard "check-shmutant-pin" "rm -rf \"$work\""

# THE SHIPPED PAIR, before any copy: `cp` follows a link, so a copy of a linked file is a regular
# file, and a self-test that only judged copies would pass a tracked tree the plain mode refuses.
if out="$(pin_verdict scripts)"; then ok; else bad "shmutant-pin: $out"; fi

# fresh <name> — a copy of the shipped pair under $work/<name>; prints the directory.
fresh() {
  mkdir -p "$work/$1" && cp scripts/shmutant.sh scripts/shmutant.sh.sha256 "$work/$1/" && printf '%s' "$work/$1"
}
# refuses <label> <dir> <reason-fragment> — the verdict on <dir> must be a failure naming <fragment>.
refuses() {
  local out rc
  out="$(pin_verdict "$2")"; rc=$?
  eq "$rc" 1 "$1: refused"
  has "$out" "$3" "$1: …naming why"
}

d="$(fresh green)" || bad "could not build the green copy"
out="$(pin_verdict "$d")"; yes "$?" "an unmodified copy of the shipped pair passes"
eq "$out" "$(cut -c1-64 scripts/shmutant.sh.sha256)" "…and reports the recorded digest"

# A ONE-BYTE edit — the case the pin exists for. The byte is changed in place, never appended, so
# the size is unchanged and only the content can tell.
d="$(fresh one-byte)" || bad "could not build the one-byte copy"
off=$(( $(wc -c < "$d/shmutant.sh") / 2 ))
orig="$(dd if="$d/shmutant.sh" bs=1 skip="$off" count=1 2>/dev/null)"
if [ "$orig" = x ]; then repl=y; else repl=x; fi
printf '%s' "$repl" | dd of="$d/shmutant.sh" bs=1 seek="$off" conv=notrunc 2>/dev/null
eq "$(wc -c < "$d/shmutant.sh")" "$(wc -c < scripts/shmutant.sh)" "one-byte: the edit kept the size"
cmp -s "$d/shmutant.sh" scripts/shmutant.sh && bad "one-byte: the edit did not change the copy" || ok
refuses one-byte "$d" "was edited, or replaced without its record"

d="$(fresh second-line)" && printf 'deadbeef  other.sh\n' >> "$d/shmutant.sh.sha256"
refuses second-line "$d" "not exactly one newline-terminated line"
d="$(fresh no-newline)" && printf '%s' "$(cat "$d/shmutant.sh.sha256")" > "$d/shmutant.sh.sha256"
refuses no-newline "$d" "not exactly one newline-terminated line"
d="$(fresh uppercase)" && tr 'a-f' 'A-F' < scripts/shmutant.sh.sha256 > "$d/shmutant.sh.sha256"
refuses uppercase "$d" "64 lowercase hex"
d="$(fresh oversize)" && { printf '%0200d  shmutant.sh\n' 0 > "$d/shmutant.sh.sha256"; }
refuses oversize "$d" "not exactly one newline-terminated line"
d="$(fresh upper-name)" && sed 's/shmutant\.sh$/SHMUTANT.SH/' scripts/shmutant.sh.sha256 > "$d/shmutant.sh.sha256"
refuses upper-name "$d" "64 lowercase hex"
d="$(fresh other-name)" && sed 's/shmutant\.sh$/other.sh/' scripts/shmutant.sh.sha256 > "$d/shmutant.sh.sha256"
refuses other-name "$d" "64 lowercase hex"
d="$(fresh one-space)" && sed 's/  / /' scripts/shmutant.sh.sha256 > "$d/shmutant.sh.sha256"
refuses one-space "$d" "64 lowercase hex"
d="$(fresh linked)" && mv "$d/shmutant.sh" "$d/real.sh" && ln -s real.sh "$d/shmutant.sh"
refuses linked "$d" "not a regular file"
d="$(fresh linked-record)" && mv "$d/shmutant.sh.sha256" "$d/real.sha256" && ln -s real.sha256 "$d/shmutant.sh.sha256"
refuses linked-record "$d" "the pin has no record"
d="$(fresh nul-record)" && { cut -c1-64 scripts/shmutant.sh.sha256 | tr -d '\n'; printf '  shmutant.sh\000\n'; } > "$d/shmutant.sh.sha256"
refuses nul-record "$d" "not exactly one newline-terminated line"
d="$(fresh no-file)" && rm -f "$d/shmutant.sh"
refuses no-file "$d" "is missing"
d="$(fresh no-record)" && rm -f "$d/shmutant.sh.sha256"
refuses no-record "$d" "the pin has no record"

check_summary "check-shmutant-pin --self-test"
