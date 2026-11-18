#!/usr/bin/env bash
# `new-work.sh preview`: one bead's full text.
#
# This file used to hold the picker's end-to-end tests -- 2,167 lines driving the
# fzf screen, its composer verbs, the branch question, the hand-back and the
# agent memory through a pty. The flow asks its questions with rex.ui now, so all
# of that is gone: what is left of the script is the four lookups, and this is
# the one of them that had no test of its own (`beads` is in beads_test.sh,
# `branch-default` and `bases` in branch_test.sh).
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

# preview: `bd show` reads better through bat, and still works without it.
mkdir -p "$tmp/preview-bin"
cat >"$tmp/preview-bin/bd" <<'EOF'
#!/bin/sh
printf '# bead %s\n\nbody\n' "$2"
EOF
cat >"$tmp/preview-bin/bat" <<'EOF'
#!/bin/sh
sed 's/^/BAT: /'
EOF
chmod +x "$tmp/preview-bin/bd" "$tmp/preview-bin/bat"

ran=$((ran + 1))
PATH="$tmp/preview-bin:$PATH" ./new-work.sh preview pmm-iris-a4l --main . \
  >"$tmp/out" 2>"$tmp/err"
if [ $? -ne 0 ]; then
  fail "preview through bat" "stderr: $(cat "$tmp/err")"
elif ! grep -qx 'BAT: # bead pmm-iris-a4l' "$tmp/out"; then
  fail "preview through bat" "stdout: $(cat "$tmp/out")"
fi

# The same preview with no bat anywhere on PATH: the text, unstyled.
mkdir -p "$tmp/plain-bin"
cp "$tmp/preview-bin/bd" "$tmp/plain-bin/bd"
for tool in bash cat sed; do
  ln -sf "$(command -v "$tool")" "$tmp/plain-bin/$tool"
done
ran=$((ran + 1))
PATH="$tmp/plain-bin" ./new-work.sh preview pmm-iris-a4l --main . \
  >"$tmp/out" 2>"$tmp/err"
if [ $? -ne 0 ]; then
  fail "preview without bat" "stderr: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/out")" != "$(printf '# bead pmm-iris-a4l\n\nbody')" ]; then
  fail "preview without bat" "stdout: $(cat "$tmp/out")"
fi

# A bead is asked about, and bd is the program that answers: a machine without it
# says so instead of printing nothing.
ran=$((ran + 1))
PATH=/nonexistent "${BASH:-bash}" ./new-work.sh preview pmm-iris-a4l --main . \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "preview without bd exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -q 'bd is required' "$tmp/err"; then
  fail "preview without bd names bd" "stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
./new-work.sh preview --main . >"$tmp/out" 2>"$tmp/err"
if [ $? -ne 2 ]; then
  fail "preview without an id exits 2" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
./new-work.sh preview pmm-iris-a4l >"$tmp/out" 2>"$tmp/err"
if [ $? -ne 2 ]; then
  fail "preview without --main exits 2" "stderr: $(cat "$tmp/err")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
