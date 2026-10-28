#!/usr/bin/env bash
# `new-work.sh pick` and `new-work.sh preview`.
#
# pick is the two-stage picker behind ctrl+space>n: a bead, then a branch, then
# one JSON object handed back to Rex. fzf cannot be driven without a terminal,
# so every assertion here goes through the --bead/--branch bypasses, --dry-run,
# and saved tool output (--bd-json/--wt-json/--refs).
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

# Stand-ins for the tools that would otherwise talk to the outside world. rex
# records its arguments, so "the hand-back never ran" is proven by a missing
# file rather than by reading the script; fzf leaves a mark when it is started,
# which is how "nothing ever waited for a terminal" is proven.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/rex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$REX_ARGS_FILE"
EOF
cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
if [ -n "${FZF_MARKER:-}" ]; then
  touch "$FZF_MARKER"
fi
cat >/dev/null
EOF
chmod +x "$tmp/bin/rex" "$tmp/bin/fzf"

# run_pick <beads fixture> [options...]
#
# Runs the picker with every tool call replaced by saved output: stdout lands
# in $tmp/out, stderr in $tmp/err, the exit status in $status. PICK_PATH
# prepends the stand-ins to PATH for the assertions that need them.
run_pick() {
  local fixture=$1
  shift
  ran=$((ran + 1))
  rm -f "$tmp/rex-args"
  PATH="${PICK_PATH:-$PATH}" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "$fixture" \
    --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# payload_of <dry-run line>: the JSON the printed command actually delivers.
# The line is executed with the stand-in rex, so a line that only looks right
# fails here too.
payload_of() {
  local line=$1
  # Exactly the command pick promises: rex do work_new_go --args '<json>'
  if ! printf '%s\n' "$line" |
    grep -q "^rex do work_new_go --args '.*'\$"; then
    return 1
  fi
  rm -f "$tmp/extract-args"
  if ! PATH="$tmp/bin:$PATH" REX_ARGS_FILE=$tmp/extract-args \
    bash -c "$line" >"$tmp/extract-out" 2>"$tmp/extract-err"; then
    return 1
  fi
  if [ "$(sed -n '3p' "$tmp/extract-args" 2>/dev/null)" != --args ]; then
    return 1
  fi
  sed -n '4p' "$tmp/extract-args"
}

# assert_json <name> <json> <jq filter that must yield true>
assert_json() {
  local name=$1 json=$2 filter=$3 got
  ran=$((ran + 1))
  if ! got=$(printf '%s\n' "$json" | jq -c "$filter" 2>"$tmp/jq-err"); then
    fail "$name" "jq failed: $(cat "$tmp/jq-err") on: $json"
    return
  fi
  if [ "$got" != true ]; then
    fail "$name" "want true, got $got for: $json"
  fi
}

# A candidate set: the worktrunk fixture's branches (main, chore/p4pip,
# feat/abc123) plus one that only a local branch has.
cat >"$tmp/refs" <<'EOF'
bug/a4l
feat/abc123
main
EOF

# A ready list with nothing on it: the branch question on its own.
printf '[]\n' >"$tmp/empty-beads.json"

# (a) An empty branch is a cancelled pick: exit 3, no payload, no Rex.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --branch ''
if [ "$status" -ne 3 ]; then
  fail "empty branch exits 3" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ]; then
  fail "empty branch prints no payload" "stdout: $(cat "$tmp/out")"
fi
ran=$((ran + 1))
if [ -e "$tmp/rex-args" ]; then
  fail "empty branch never calls rex" "rex saw: $(sed -n '1,4p' "$tmp/rex-args")"
fi

# (b) A branch that is exactly on the candidate list switches to the worktree
# that already has it; the bead and its title ride along.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --branch bug/a4l --dry-run
if [ "$status" -ne 0 ]; then
  fail "exact branch exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(wc -l <"$tmp/out" | tr -d ' ')" != 1 ]; then
  fail "dry run prints one line" "stdout: $(cat "$tmp/out")"
fi
ran=$((ran + 1))
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "dry run prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "exact branch: branch" "$json" '.branch == "bug/a4l"'
  assert_json "exact branch: create is false" "$json" '.create == false'
  assert_json "exact branch: bead" "$json" '.bead == "pmm-iris-a4l"'
  assert_json "exact branch: title" "$json" \
    '.title == "Treat index/catalog pages as non-extractable"'
  assert_json "exact branch: project, root, main" "$json" \
    '.project == "demo" and .root == "/p/demo" and .main == "/p/demo/main"'
  assert_json "exact branch: exactly the seven keys" "$json" \
    'keys == ["bead", "branch", "create", "main", "project", "root", "title"]'
fi
ran=$((ran + 1))
if [ -e "$tmp/rex-args" ]; then
  fail "dry run does not call rex" "rex saw: $(sed -n '1,4p' "$tmp/rex-args")"
fi

# (b2) A name that merely begins like a candidate is not that candidate: an
# exact match is a switch, a fuzzy one is a branch to create. `bug/a4` is a
# prefix of `bug/a4l`, so a substring match would call it existing.
run_pick test/fixtures/ready.json --bead '' --branch bug/a4 --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "fuzzy prefix prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "fuzzy prefix: branch" "$json" '.branch == "bug/a4"'
  assert_json "fuzzy prefix: create is true" "$json" '.create == true'
fi

# (b3) A new branch name has to be a ref worktrunk can create; the script says
# so itself instead of letting `wt switch` fail in the new tab.
run_pick test/fixtures/ready.json --bead '' --branch 'not a ref' --dry-run
if [ "$status" -ne 2 ]; then
  fail "invalid branch name exits 2" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -q "new-work.sh: not a valid branch name: not a ref" "$tmp/err"; then
  fail "invalid branch name says so" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ] || [ -e "$tmp/rex-args" ]; then
  fail "invalid branch name starts nothing" \
    "stdout: $(cat "$tmp/out") rex: $(sed -n '1,4p' "$tmp/rex-args" 2>/dev/null)"
fi

# (c) --bead '' answers the bead question with "none": the bead stage is not
# asked at all, so no fzf runs and the payload carries no bead and no title.
rm -f "$tmp/fzf-ran"
PICK_PATH="$tmp/bin:$PATH" FZF_MARKER=$tmp/fzf-ran \
  run_pick test/fixtures/ready.json --bead '' --branch feat/typed-name --dry-run
if [ "$status" -ne 0 ]; then
  fail "typed branch exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "typed branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "typed branch payload" "$json" '.branch == "feat/typed-name"'
  assert_json "typed branch payload" "$json" '.create == true'
  assert_json "typed branch payload" "$json" '.bead == "" and .title == ""'
fi
ran=$((ran + 1))
if grep -q 'skipping the bead question' "$tmp/err"; then
  fail "--bead '' bypasses the bead stage" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/fzf-ran" ]; then
  fail "--bead '' never starts fzf" "fzf was started"
fi

# (c2) No bead to offer: the note goes to stderr when the branch question is
# not asked either, instead of an empty fzf prompt.
run_pick "$tmp/empty-beads.json" --branch feat/typed-name --dry-run
if [ "$status" -ne 0 ]; then
  fail "empty ready list still picks a branch" \
    "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -q 'no ready beads' "$tmp/err"; then
  fail "no ready beads is said out loud" "stderr: $(cat "$tmp/err")"
fi

# (d) A name that is on the candidate list stays a switch even when no bead
# suggested it.
run_pick test/fixtures/ready.json --bead '' --branch feat/abc123 --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "exact candidate name prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "exact candidate payload" "$json" '.branch == "feat/abc123"'
  assert_json "exact candidate payload" "$json" '.create == false'
fi

# (e) A title from a database: quotes survive, tabs and newlines become single
# spaces, nothing is truncated.
run_pick test/fixtures/ready-quirky-title.json --bead pmm-iris-q1 \
  --branch bug/q1 --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "quirky title prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "quirky title payload" "$json" \
    '.title == "He said \"stop\" now please"'
  assert_json "quirky title payload" "$json" '.bead == "pmm-iris-q1"'
fi

# (f) A branch holding both kinds of quote: the payload survives the printed
# quoting, so what rex receives is the branch that was typed.
odd='x"y'"'"'z'
run_pick test/fixtures/ready.json --bead '' --branch "$odd" --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "quoted branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  ran=$((ran + 1))
  if [ "$(printf '%s\n' "$json" | jq -r '.branch')" != "$odd" ]; then
    fail "quoted branch survives the shell" "want $odd in: $json"
  fi
fi

# (g) A missing tool is named, the pane waits for a keypress and the run exits 1
# instead of vanishing. jq is needed before any question is asked, so with no
# tools at all it is the one that answers.
ran=$((ran + 1))
rm -f "$tmp/rex-args"
PATH=/nonexistent REX_ARGS_FILE=$tmp/rex-args "${BASH:-bash}" ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  --bead pmm-iris-a4l </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "missing tool exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -qx 'jq not found on PATH — press any key' "$tmp/err"; then
  fail "missing tool is named" "stderr: $(cat "$tmp/err")"
fi

# Every tool the run needs except fzf: with no terminal nothing is asked, so the
# run must reach the empty-branch exit instead of complaining about fzf.
mkdir -p "$tmp/no-fzf-bin"
for tool in bash cat cut grep sed awk tr git bd wt jq; do
  found=$(command -v "$tool") || continue
  ln -sf "$found" "$tmp/no-fzf-bin/$tool"
done
ran=$((ran + 1))
PATH="$tmp/no-fzf-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 3 ]; then
  fail "no terminal needs no fzf" "exit $status: $(cat "$tmp/err")"
elif grep -q 'not found on PATH' "$tmp/err"; then
  fail "no terminal needs no fzf" "stderr: $(cat "$tmp/err")"
fi

# (h) pick without the project it is working on.
pick_no() {
  ran=$((ran + 1))
  ./new-work.sh pick "$@" >"$tmp/out" 2>"$tmp/err"
  local got=$?
  if [ "$got" -ne 2 ]; then
    fail "pick $* exits 2" "exit $got: $(cat "$tmp/err")"
  fi
}
pick_no
pick_no --main /p/demo/main
pick_no --main /p/demo/main --root /p/demo
pick_no --main /p/demo/main --root /p/demo --project demo --nope

# (i) preview: `bd show` reads better through bat, and still works without it.
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

# (j) Never wait for a terminal that is not there. With neither --bead nor
# --branch and stdin not a terminal, both questions are skipped -- an fzf
# launched here would block forever -- and the run ends the way esc does.
ran=$((ran + 1))
rm -f "$tmp/rex-args" "$tmp/fzf-ran"
PICK_PATH="$tmp/bin:$PATH" FZF_MARKER=$tmp/fzf-ran \
  run_pick test/fixtures/ready.json
if [ "$status" -ne 3 ]; then
  fail "no terminal exits 3" "exit $status: $(cat "$tmp/err")"
elif [ -e "$tmp/fzf-ran" ]; then
  fail "no terminal never runs fzf" "fzf was started"
elif ! grep -q 'skipping the bead question: stdin is not a terminal' \
  "$tmp/err"; then
  fail "no terminal skips the bead question" "stderr: $(cat "$tmp/err")"
elif ! grep -q 'skipping the branch question: stdin is not a terminal' \
  "$tmp/err"; then
  fail "no terminal skips the branch question" "stderr: $(cat "$tmp/err")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
