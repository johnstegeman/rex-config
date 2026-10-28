#!/usr/bin/env bash
# `new-work.sh beads`: turn `bd ready --json` into the picker's rows.
#
# Kept issues come out as "id<TAB>title" sorted by priority then id; molecule
# steps (dotted ids), molecule/gate issue types and step:* labels never show up.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '  %s\n' "$2"
  fi
}

ran=$((ran + 1))
./new-work.sh beads --bd-json test/fixtures/ready.json >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "fixture listing" "exit $status: $(cat "$tmp/err")"
elif ! diff -u test/fixtures/ready.expected "$tmp/out"; then
  fail "fixture listing" "output differs from test/fixtures/ready.expected"
fi

ran=$((ran + 1))
printf '[]\n' >"$tmp/empty.json"
./new-work.sh beads --bd-json "$tmp/empty.json" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "empty ready list exits 0" "exit $status: $(cat "$tmp/err")"
elif [ -s "$tmp/out" ]; then
  fail "empty ready list prints nothing" "got: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
./new-work.sh nope >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 2 ]; then
  fail "unknown subcommand exits 2" "exit $status"
elif ! grep -q usage "$tmp/err"; then
  fail "unknown subcommand prints usage" "stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
./new-work.sh beads >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 2 ]; then
  fail "beads without --main/--bd-json exits 2" "exit $status: $(cat "$tmp/err")"
fi

# A PATH with no jq on it: say so, rather than show an empty picker.
ran=$((ran + 1))
PATH=/nonexistent "${BASH:-bash}" ./new-work.sh beads --bd-json test/fixtures/ready.json >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "missing jq exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -q jq "$tmp/err"; then
  fail "missing jq names jq" "stderr: $(cat "$tmp/err")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
