#!/usr/bin/env bash
# Run every test in test/ from the repo root.
#
#   test/*_test.lua  -> lua
#   test/*_test.sh   -> bash
#
# Prints "FAIL <file>" for each failing file and exits non-zero if any failed.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

failures=0
ran=0

run() {
  ran=$((ran + 1))
  if ! "$1" "$2"; then
    printf 'FAIL %s\n' "$2"
    failures=$((failures + 1))
  fi
}

for file in test/*_test.lua; do
  [ -e "$file" ] || continue
  run lua "$file"
done

for file in test/*_test.sh; do
  [ -e "$file" ] || continue
  run bash "$file"
done

if [ "$failures" -ne 0 ]; then
  printf '%d of %d test files failed\n' "$failures" "$ran"
  exit 1
fi

if [ "$ran" -eq 0 ]; then
  echo "no test files found under test/" >&2
  exit 1
fi

echo "ok all files"
