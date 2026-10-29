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

# A title carrying a tab and a newline: the row is "id<TAB>title", so either
# would split it -- the picker would show fragments, and cut -f1 in pick would
# read a made-up id. The payload's title comes from the JSON instead, so this is
# the row only.
cat >"$tmp/quirky.json" <<'EOF'
[
  { "id": "pmm-iris-t1", "title": "tab\there\nand a newline", "priority": 2, "issue_type": "task" },
  { "id": "pmm-iris-t2", "title": "second", "priority": 1, "issue_type": "task" }
]
EOF
ran=$((ran + 1))
./new-work.sh beads --bd-json "$tmp/quirky.json" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a title with a tab or newline is flattened" "exit $status: $(cat "$tmp/err")"
elif [ "$(wc -l <"$tmp/out" | tr -d ' ')" != 2 ]; then
  fail "a title with a tab or newline is flattened" \
    "one row per bead, got: $(cat "$tmp/out")"
elif [ "$(cut -f1 "$tmp/out" | tr '\n' ' ')" != "pmm-iris-t2 pmm-iris-t1 " ]; then
  fail "a title with a tab or newline is flattened" "rows: $(cat "$tmp/out")"
fi

# Fields a producer left out: a bead with no priority or no id at all is still a
# row -- one odd record must not cost the picker the whole list, and a null id
# would otherwise stop jq outright.
cat >"$tmp/sparse.json" <<'EOF'
[
  { "id": "pmm-iris-s1", "title": "no priority", "issue_type": "task" },
  { "id": null, "title": "no id at all", "priority": 3, "issue_type": "task" },
  { "id": "pmm-iris-s3", "title": "one", "priority": 1, "issue_type": "task" }
]
EOF
ran=$((ran + 1))
./new-work.sh beads --bd-json "$tmp/sparse.json" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a bead with no priority or id is still a row" "exit $status: $(cat "$tmp/err")"
elif [ "$(sed -n '1p' "$tmp/out")" != "$(printf 'pmm-iris-s3\tone')" ]; then
  fail "a bead with no priority or id is still a row" "rows: $(cat "$tmp/out")"
elif [ "$(sed -n '3p' "$tmp/out")" != "$(printf 'pmm-iris-s1\tno priority')" ]; then
  fail "a bead with no priority or id is still a row" "rows: $(cat "$tmp/out")"
fi

# A bd that reports no database: bd's own error says what, and the line above
# it says where, because the directory is the half a person can act on.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/bd" <<'EOF'
#!/bin/sh
printf 'Error: no beads database found\nHint: run bd where\n' >&2
exit 1
EOF
chmod +x "$tmp/bin/bd"
ran=$((ran + 1))
PATH="$tmp/bin:$PATH" ./new-work.sh beads --main "$tmp/nowhere" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "a bd with no database exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF "beads: could not read the ready beads from $tmp/nowhere" "$tmp/err"; then
  fail "a bd with no database names the directory" "stderr: $(cat "$tmp/err")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
