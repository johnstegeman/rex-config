#!/usr/bin/env bash
# `new-work.sh pick` and `new-work.sh preview`.
#
# pick is the two-stage picker behind ctrl+space>n: a bead, then a branch, then
# one JSON object handed back to Rex. The bead question is fzf, which cannot be
# driven without a terminal, so it is bypassed with --bead or served by saved
# tool output (--bd-json/--wt-json/--refs/--base-refs). The branch question is
# typed, so its answers arrive on stdin like a person's would.
#
# Three things are outside what a pipe can reach, so a pty and a hand are what
# verify them: the prompt text `branch [name]> ` as it appears on a terminal, the
# rule that it is printed only to a terminal, and the float's hold-on-failure (a
# keypress is waited for once, with stdin a terminal). Everything else here runs
# the real code path.
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
if [ -n "${REX_FAIL:-}" ]; then
  printf 'rex: %s\n' "$REX_FAIL" >&2
  exit "${REX_STATUS:-1}"
fi
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
    --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
    --base-refs "$tmp/base-refs" "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# run_pick_answer <typed text> <beads fixture> [options...]
#
# The same run with the branch answer typed on stdin and followed by Enter; an
# empty text is the bare Enter that accepts the suggestion. The branch question
# is a typed prompt, so this drives the real path end to end: no fzf stand-in.
run_pick_answer() {
  local text=$1 fixture=$2
  shift 2
  ran=$((ran + 1))
  rm -f "$tmp/rex-args"
  printf '%s\n' "$text" |
    PATH="${PICK_PATH:-$PATH}" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
      --main /p/demo/main --root /p/demo --project demo \
      --bd-json "$fixture" \
      --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
      --base-refs "$tmp/base-refs" "$@" \
      >"$tmp/out" 2>"$tmp/err"
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

# The refs the base is resolved from, exactly what
#
#   git for-each-ref --format='%(refname)%00%(symref)' refs/remotes refs/heads
#
# prints for a clone of origin/main with both of the local branches: a refname,
# a NUL, then that ref's symref target -- empty for everything but origin/HEAD.
printf 'refs/remotes/origin/main\0\nrefs/heads/main\0\nrefs/heads/master\0\n' \
  >"$tmp/base-refs"

# The same for a clone whose one remote is upstream: the remote a base lives on
# is what its ref record says, not the slash in its name.
printf 'refs/remotes/upstream/main\0\nrefs/heads/main\0\nrefs/heads/master\0\n' \
  >"$tmp/base-refs-upstream"

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
  assert_json "exact branch: exactly the nine keys" "$json" \
    'keys == ["base", "base_remote", "bead", "branch", "create", "main",
              "project", "root", "title"]'
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

# (b4) The worktrunk shortcuts are answers, not names: ^ is the default branch,
# - the previous worktree, @ the current one, pr:N a pull request's branch. None
# of them is a ref to create and git refuses most of them, so they are handed to
# worktrunk as the switch they are.
pick_shortcut() {
  local name=$1 branch=$2 filter=$3
  ran=$((ran + 1))
  run_pick test/fixtures/ready.json --bead '' --branch "$branch" --dry-run
  if [ "$status" -ne 0 ]; then
    fail "the $name shortcut is accepted" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if ! json=$(payload_of "$(cat "$tmp/out")"); then
    fail "the $name shortcut prints runnable rex do work_new_go --args" \
      "stdout: $(cat "$tmp/out")"
    return
  fi
  assert_json "the $name shortcut is handed over as typed" "$json" "$filter"
  assert_json "the $name shortcut is a switch" "$json" '.create == false'
}
pick_shortcut 'default branch' '^' '.branch == "^"'
pick_shortcut 'previous worktree' '-' '.branch == "-"'
pick_shortcut 'current worktree' '@' '.branch == "@"'
pick_shortcut 'pull request' 'pr:123' '.branch == "pr:123"'

# A pr: that is not a number is not a shortcut, and no branch name either.
ran=$((ran + 1))
run_pick test/fixtures/ready.json --bead '' --branch 'pr:abc' --dry-run
if [ "$status" -ne 2 ]; then
  fail "a pr: without a number exits 2" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF 'new-work.sh: not a valid branch name: pr:abc' "$tmp/err"; then
  fail "a pr: without a number says so" "stderr: $(cat "$tmp/err")"
fi

# (b5) `git check-ref-format --branch` *expands* a name like @{-1} and prints
# what it resolved to, so the check on its own would let the literal through and
# worktrunk would try to create a branch called @{-1}. The reply has to be the
# name that went in.
ran=$((ran + 1))
run_pick test/fixtures/ready.json --bead '' --branch '@{-1}' --dry-run
if [ "$status" -ne 2 ]; then
  fail "a name git only expands exits 2" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF 'new-work.sh: not a valid branch name: @{-1}' "$tmp/err"; then
  fail "a name git only expands says so" "stderr: $(cat "$tmp/err")"
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

# (d2) The branch question is typed, not picked: the name derived from the bead
# sits in the prompt and a bare Enter accepts it. This is the gesture the live
# picker lost, and stdin carries the answer now, so no stand-in is involved.
rm -f "$tmp/fzf-ran"
PICK_PATH="$tmp/bin:$PATH" FZF_MARKER=$tmp/fzf-ran \
  run_pick_answer '' test/fixtures/ready.json --bead pmm-iris-58h --dry-run
if [ "$status" -ne 0 ]; then
  fail "enter at the suggestion exits 0" "exit $status: $(cat "$tmp/err")"
fi
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "enter at the suggestion prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "enter at the suggestion: the suggestion is the branch" \
    "$json" '.branch == "feat/58h"'
  assert_json "enter at the suggestion: create is true" "$json" \
    '.create == true'
  assert_json "enter at the suggestion: the bead rides along" "$json" \
    '.bead == "pmm-iris-58h" and (.title | length) > 0'
fi
ran=$((ran + 1))
if [ -e "$tmp/fzf-ran" ]; then
  fail "the branch question never starts fzf" "fzf was started"
fi

# (d3) Anything typed is the branch, exactly as typed -- and a name that no
# candidate carries is a branch to create.
run_pick_answer 'my-branch' test/fixtures/ready.json --bead '' --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "typed branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "typed branch: exactly what was typed" "$json" \
    '.branch == "my-branch"'
  assert_json "typed branch: create is true" "$json" '.create == true'
fi

# (d3b) A pasted answer arrives with whitespace around it, and whitespace is part
# of no branch: it is trimmed, so the name that is checked and handed back is
# the one the user meant -- and space-then-Enter is Enter, accepting the
# suggestion rather than failing `git check-ref-format` on "feat/58h " with the
# reason invisible.
run_pick_answer '  feat/spaced  ' test/fixtures/ready.json --bead '' --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a padded branch answer prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a padded branch answer is trimmed" "$json" \
    '.branch == "feat/spaced" and .create == true'
fi

run_pick_answer '   ' test/fixtures/ready.json --bead pmm-iris-58h --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "space-then-Enter prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "space-then-Enter accepts the suggestion" "$json" \
    '.branch == "feat/58h"'
fi

# (d4) A typed name that exactly matches a candidate still switches to the
# worktree that has it: the list is no longer shown, but it still decides.
run_pick_answer 'feat/abc123' test/fixtures/ready.json --bead '' --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "typed candidate prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "typed candidate: the typed name" "$json" \
    '.branch == "feat/abc123"'
  assert_json "typed candidate: create is false" "$json" '.create == false'
fi

# (d5) The bead question is still a picker and still skipped without a
# terminal; the branch answer arrives on the pipe all the same.
run_pick_answer 'feat/piped' test/fixtures/ready.json --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "piped branch with no bead prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "piped branch with no bead: the branch" "$json" \
    '.branch == "feat/piped"'
  assert_json "piped branch with no bead: no bead, no title" "$json" \
    '.bead == "" and .title == ""'
fi

# (d6) Empty input with nothing to suggest is a cancelled pick, exactly as esc:
# exit 3, no payload, no Rex.
run_pick_answer '' test/fixtures/ready.json --bead '' --dry-run
if [ "$status" -ne 3 ]; then
  fail "empty answer with no suggestion exits 3" \
    "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ] || [ -e "$tmp/rex-args" ]; then
  fail "empty answer with no suggestion starts nothing" \
    "stdout: $(cat "$tmp/out")"
fi

# (d7) A bead whose id no branch name can be built from -- one ending in a dash:
# the prompt offers no suggestion rather than stopping the pick with a
# branch-default usage dump. With the suggestion empty the empty answer is the
# ordinary cancelled pick, which is also how "no suggestion was offered" is
# proven: a suggestion would have been accepted instead.
ran=$((ran + 1))
run_pick test/fixtures/ready.json --bead 'pmm-iris-' --dry-run
if [ "$status" -ne 3 ]; then
  fail "a bead id with no name leaves the prompt empty" \
    "exit $status: $(cat "$tmp/err")"
elif grep -q 'usage: new-work.sh' "$tmp/err"; then
  fail "a bead id with no name leaves the prompt empty" \
    "usage dump in stderr: $(cat "$tmp/err")"
elif ! grep -q 'no branch given, nothing to start' "$tmp/err"; then
  fail "a bead id with no name leaves the prompt empty" "stderr: $(cat "$tmp/err")"
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

# A bead the row filter drops -- a gate here -- can still be named with --bead,
# and its title is read by a second jq, which is the only place such a bead
# reaches. A title that is not a string has to be stringified there too: without
# that the pick dies in raw jq text before it hands anything back.
printf '[{"id": "pmm-iris-g1", "title": 42, "priority": 1, "issue_type": "gate"}]\n' \
  >"$tmp/gate-numeric-title.json"
run_pick "$tmp/gate-numeric-title.json" --bead pmm-iris-g1 --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a numeric title on a filtered bead still hands back" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a numeric title on a filtered bead is stringified" "$json" \
    '.title == "42" and .bead == "pmm-iris-g1"'
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
  --base-refs "$tmp/base-refs" \
  --bead pmm-iris-a4l </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "missing tool exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -qx 'jq not found on PATH — press any key' "$tmp/err"; then
  fail "missing tool is named" "stderr: $(cat "$tmp/err")"
fi

# git is load-bearing on the create path -- check-ref-format decides whether a
# name can be made, for-each-ref is the branch list -- so a missing one is named
# rather than every name coming back "not a valid branch name".
mkdir -p "$tmp/no-git-bin"
for tool in bash cat cut grep sed awk tr jq; do
  found=$(command -v "$tool") || continue
  ln -sf "$found" "$tmp/no-git-bin/$tool"
done
ran=$((ran + 1))
PATH="$tmp/no-git-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  --base-refs "$tmp/base-refs" \
  --bead pmm-iris-a4l --branch feat/needs-git --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "a missing git exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -q 'git not found on PATH' "$tmp/err"; then
  fail "a missing git is named" "stderr: $(cat "$tmp/err")"
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
  --base-refs "$tmp/base-refs" \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 3 ]; then
  fail "no terminal needs no fzf" "exit $status: $(cat "$tmp/err")"
elif grep -q 'not found on PATH' "$tmp/err"; then
  fail "no terminal needs no fzf" "stderr: $(cat "$tmp/err")"
fi

# The branch question needs no fzf at all: with the answer on stdin the picker
# hands back even where fzf is not installed. Only the bead question is a
# picker, and --bead says that one is already answered.
ran=$((ran + 1))
printf 'feat/no-fzf\n' |
  PATH="$tmp/no-fzf-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json test/fixtures/ready.json \
    --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
    --base-refs "$tmp/base-refs" \
    --bead pmm-iris-a4l --dry-run >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a typed branch needs no fzf" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a typed branch needs no fzf: no payload" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a typed branch needs no fzf: the branch" "$json" \
    '.branch == "feat/no-fzf"'
  assert_json "a typed branch needs no fzf: create is true" "$json" \
    '.create == true'
fi

# (h) pick without the project it is working on. stdin is /dev/null so a run
# started from a terminal asks for no keypress: the picker holds a failure open
# only where there is a float to hold it in.
pick_no() {
  ran=$((ran + 1))
  ./new-work.sh pick "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
  local got=$?
  if [ "$got" -ne 2 ]; then
    fail "pick $* exits 2" "exit $got: $(cat "$tmp/err")"
  fi
}
pick_no
pick_no --main /p/demo/main
pick_no --main /p/demo/main --root /p/demo
pick_no --main /p/demo/main --root /p/demo --project demo --nope

# (h2) A --main that is not there is refused by name, before anything is read
# from it: left to the pipelines it surfaces as bash's own `cd` error, which
# names a line of this script rather than a place on the disk.
ran=$((ran + 1))
./new-work.sh pick --main "$tmp/nowhere" --root /p/demo --project demo \
  --bead '' --branch feat/x --dry-run </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "a --main that is not there exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF "new-work.sh: pick: no such directory: $tmp/nowhere" "$tmp/err"; then
  fail "a --main that is not there is named" "stderr: $(cat "$tmp/err")"
elif grep -q 'cd:' "$tmp/err"; then
  fail "a --main that is not there is named" \
    "bash's own cd error is still in: $(cat "$tmp/err")"
fi

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

# (j) Never wait for a terminal that is not there. With /dev/null on stdin the
# bead question is a picker and is skipped (an fzf launched here would block
# forever), and the branch question reads its answer and gets EOF at once
# instead of waiting for a key: the run ends the way esc does.
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
elif ! grep -q 'no branch given, nothing to start' "$tmp/err"; then
  fail "no terminal gets an empty branch" "stderr: $(cat "$tmp/err")"
fi

# (k) A relative --main or --root is refused. Rex resolves the payload's paths
# against its own working directory, not the float's, so `.` would build a tab
# in the server's directory and fail there with nothing on screen to say why.
# Nothing is looked up either: every tool here is a stand-in that leaves a mark
# when it is run, so "no tool was asked anything" is a missing file -- wt
# included, which the picker would otherwise need before it can list branches.
mkdir -p "$tmp/watch-bin"
for tool in rex wt bd jq git fzf; do
  cat >"$tmp/watch-bin/$tool" <<'EOF'
#!/bin/sh
printf '%s\n' "$0" >>"$CALLED_FILE"
EOF
  chmod +x "$tmp/watch-bin/$tool"
done
ln -sf "$(command -v cat)" "$tmp/watch-bin/cat"

pick_relative() {
  local name=$1 want=$2
  shift 2
  ran=$((ran + 1))
  rm -f "$tmp/called"
  PATH="$tmp/watch-bin" CALLED_FILE=$tmp/called "${BASH:-bash}" \
    ./new-work.sh pick --project demo --bead '' --branch feat/x --dry-run \
    "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
  local got=$?
  if [ "$got" -ne 2 ]; then
    fail "$name exits 2" "exit $got: $(cat "$tmp/err")"
  elif ! grep -qF "new-work.sh: $want" "$tmp/err"; then
    fail "$name is named as relative" "stderr: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if [ -s "$tmp/out" ] || [ -e "$tmp/called" ]; then
    fail "$name starts nothing" \
      "stdout: $(cat "$tmp/out") called: $(sort -u "$tmp/called" 2>/dev/null)"
  fi
}
pick_relative 'relative --main' 'pick: --main must be an absolute path, not .' \
  --main . --root /p/demo
pick_relative 'relative --root' 'pick: --root must be an absolute path, not ..' \
  --main /p/demo/main --root ..
pick_relative 'a bare name as --main' 'pick: --main must be an absolute path, not main' \
  --main main --root /p/demo

# (l) A hand-back Rex refuses is the failure nobody used to see: rex's reason
# goes to this terminal, a line of ours says no work was started, and the run
# exits non-zero -- which is what holds the float open on screen.
ran=$((ran + 1))
rm -f "$tmp/rex-args"
PATH="$tmp/bin:$PATH" REX_ARGS_FILE=$tmp/rex-args \
  REX_FAIL='could not claim pmm-iris-58h: mise ERROR bd is not a valid shim' \
  ./new-work.sh pick --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  --base-refs "$tmp/base-refs" \
  --bead pmm-iris-a4l --branch bug/a4l \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
if [ "$status" -eq 0 ]; then
  fail "a refused hand-back exits non-zero" "exit 0: $(cat "$tmp/err")"
elif ! grep -qF 'could not claim pmm-iris-58h' "$tmp/err"; then
  fail "a refused hand-back shows rex's reason" "stderr: $(cat "$tmp/err")"
elif ! grep -qF 'new-work.sh: Rex could not finish the hand-back' "$tmp/err"; then
  fail "a refused hand-back says it did not finish" \
    "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ ! -e "$tmp/rex-args" ]; then
  fail "a refused hand-back still handed over" "rex was never called"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ]; then
  fail "a refused hand-back writes nothing to stdout" "stdout: $(cat "$tmp/out")"
fi

# (m) The same failure with no terminal returns at once: the hold would wait
# for a key that is never coming. stdin is a pipe that stays open and silent for
# ten seconds, so a read of it would block for all ten -- the threshold is half
# of that, so a loaded machine cannot make a real wait pass for a return.
start=$SECONDS
rm -f "$tmp/rex-args"
PATH="$tmp/bin:$PATH" REX_ARGS_FILE=$tmp/rex-args REX_FAIL='no server' \
  ./new-work.sh pick --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  --base-refs "$tmp/base-refs" \
  --bead pmm-iris-a4l --branch bug/a4l \
  >"$tmp/out" 2>"$tmp/err" < <(sleep 10)
status=$?
elapsed=$((SECONDS - start))
ran=$((ran + 1))
if [ "$status" -eq 0 ]; then
  fail "no terminal: a refused hand-back still fails" "exit 0"
elif [ "$elapsed" -ge 5 ]; then
  fail "no terminal never waits for a keypress" "waited ${elapsed}s"
elif ! grep -qF 'new-work.sh: Rex could not finish the hand-back' "$tmp/err"; then
  fail "no terminal: the failure is still printed" "stderr: $(cat "$tmp/err")"
fi
# (n) What fzf's reply to the bead question means, read from the reply alone.
# fzf needs a terminal, so this is the one part of that question a pipe can
# reach: the shapes below are the ones fzf really produces, measured on 0.74.5
# with --print-query and --expect. The reply is three lines -- the query, the
# key that was pressed (empty when none was), and the row under the cursor
# when there is one -- and the answer printed here is the three fields that
# reading leaves: bead, prompt, blank, empty where there is no answer.
#
# fzf exits 0 on a row and 1 on a query that matched nothing, and with
# --expect the key line is there either way; a reply with no key line at all
# is no key pressed rather than an error, and so is a key line that is empty.
check_answer() {
  local name=$1 status=$2 reply=$3 want=$4
  ran=$((ran + 1))
  printf '%s' "$reply" | ./new-work.sh fzf-answer "$status" >"$tmp/out" 2>"$tmp/err"
  local got=$?
  if [ "$got" -ne 0 ]; then
    fail "$name exits 0" "exit $got: $(cat "$tmp/err")"
  elif [ "$(cat "$tmp/out")" != "$want" ]; then
    fail "$name" "want [$want], got [$(cat "$tmp/out")]"
  fi
}

# A query with a row selected: the row is the answer and the query is not.
check_answer 'a selected row is the bead' 0 \
  $'flak\n\npmm-iris-58h\tFix the flaky guard\n' "pmm-iris-58h"$'\t\t'
# A bare Enter takes the row the cursor is on, with an empty query above it.
check_answer 'a bare enter is the row under the cursor' 0 \
  $'\n\npmm-iris-58h\tFix the flaky guard\n' "pmm-iris-58h"$'\t\t'
# The prompt row's marker comes back where a bead id would be: it is the
# answer "write a prompt", not a bead.
check_answer 'the prompt row is its marker' 0 \
  $'\n\n✎\twrite a prompt instead\n' "✎"$'\t\t'
# ctrl-n over a row is the blank answer: the key line wins over the row, so
# the bead under the cursor is not picked and nothing is typed either.
check_answer 'ctrl-n over a bead is blank' 0 \
  $'\nctrl-n\npmm-iris-58h\tFix the flaky guard\n' $'\t\t1'
# The same key over the prompt row: still nothing to say, so the field it
# would have opened is never opened.
check_answer 'ctrl-n over the prompt row is blank' 0 \
  $'\nctrl-n\n✎\twrite a prompt instead\n' $'\t\t1'
# Text that matched nothing is the prompt itself, and no bead at all. This
# reply carries no key line at all -- fzf's older two-line shape -- which is
# no key pressed rather than a reason to fail.
check_answer 'unmatched text is the prompt' 1 \
  $'why is the guard flaky?\n' $'\twhy is the guard flaky?\t'
# A key line that is there and empty says the same thing as a missing one.
check_answer 'an empty key line is no key pressed' 1 \
  $'typed text\n\n' $'\ttyped text\t'
# A query holding a tab keeps its tab: the fields are read from the answer's
# own ends, so bead, prompt and blank stay apart whatever the text contains.
check_answer 'a tab in the query keeps the fields apart' 1 \
  $'a\tb\n\n' $'\ta\tb\t'
# esc: no bead, no prompt -- the no-bead flow.
check_answer 'esc is no answer' 130 '' $'\t\t'
# fzf can be configured to exit 0 on a query that matched nothing
# (FZF_DEFAULT_OPTS=--exit-0), and then the reply is a query with no row under
# it: the text typed is still the prompt, not something to throw away.
check_answer 'a query with no row under it is still the prompt' 0 \
  $'why is the guard flaky?\n\n' $'\twhy is the guard flaky?\t'

# An fzf that failed did not answer anything: a picker that could not run is
# not a person deciding to start no work.
ran=$((ran + 1))
if ./new-work.sh fzf-answer 2 >"$tmp/out" 2>"$tmp/err"; then
  fail "fzf failing is not an answer" "exit 0: $(cat "$tmp/out")"
elif ! grep -qF 'the bead picker failed (fzf exit 2)' "$tmp/err"; then
  fail "fzf failing is named" "stderr: $(cat "$tmp/err")"
elif [ -s "$tmp/out" ]; then
  fail "fzf failing prints no answer" "stdout: $(cat "$tmp/out")"
fi

# (n2) Blank and "the picker was never asked" are different answers, and the
# payload has to say which one it got: a --bead run given no --prompt sends no
# prompt field and no blank field, so the plugin's own template still speaks --
# where blank would tell the tab to send the agent no prompt at all.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --branch bug/a4l \
  --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a bead with no prompt prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a bead with no prompt sends no prompt" "$json" \
    'has("prompt") == false'
  assert_json "a bead with no prompt is not blank" "$json" \
    'has("blank") == false'
fi

# (o) A prompt instead of a bead: the typed text is the prompt, verbatim, and
# it is the only answer in the payload -- no bead, no title.
run_pick test/fixtures/ready.json --prompt 'why is the guard flaky?' \
  --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a typed prompt prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a typed prompt is the prompt" "$json" \
    '.prompt == "why is the guard flaky?"'
  assert_json "a typed prompt replaces the bead" "$json" \
    '.bead == "" and .title == ""'
  assert_json "a typed prompt is the only new key" "$json" \
    'keys == ["base", "base_remote", "bead", "branch", "create", "main",
              "project", "prompt", "root", "title"]'
fi

# A prompt with quotes and runs of spaces survives as one value: it travels to
# jq as an argument, never built into a command line.
run_pick test/fixtures/ready.json --prompt 'say "hi"  there' --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a quoted prompt prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  ran=$((ran + 1))
  if [ "$(printf '%s\n' "$json" | jq -r '.prompt')" != 'say "hi"  there' ]; then
    fail "a quoted prompt survives the shell" "in: $json"
  fi
fi

# A prompt of nothing but spaces is no answer at all: it would replace the
# configured no-bead prompt with whitespace, so it is read as the blank answer a
# stray space and Enter is.
run_pick test/fixtures/ready.json --prompt '   ' --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a whitespace prompt prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a whitespace prompt is no prompt" "$json" \
    '.prompt == "" and .bead == ""'
fi

# A bead and a prompt are two answers to one question.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --prompt 'x' \
  --branch feat/x --dry-run
if [ "$status" -ne 2 ]; then
  fail "a bead and a prompt together exit 2" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF 'new-work.sh: pick: --bead and --prompt answer the same question' \
  "$tmp/err"; then
  fail "a bead and a prompt together say so" "stderr: $(cat "$tmp/err")"
fi

# (p) The agent question. The list is the configuration's, and the answer rides
# back in the payload: the name chosen, or an empty string for "none". Without
# a terminal there is nobody to ask, so the list's first name is the answer --
# the default the picker would have offered.
run_pick test/fixtures/ready.json --agents pi --agents claude \
  --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the agent question prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "the agent list leads with its default" "$json" '.agent == "pi"'
  assert_json "the agent question asks nobody off a terminal" "$json" \
    'keys == ["agent", "base", "base_remote", "bead", "branch", "create",
              "main", "project", "root", "title"]'
fi

run_pick test/fixtures/ready.json --agents pi --agent claude \
  --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--agent prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "--agent is the answer" "$json" '.agent == "claude"'
fi

# "none" is an empty agent, and it has to be in the payload: an absent field
# means "the picker did not ask", which starts the configured agent.
run_pick test/fixtures/ready.json --agents pi --agent '' \
  --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--agent '' prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "no agent is an empty agent, not an absent one" "$json" \
    'has("agent") and .agent == ""'
fi

# No agent list means no agent question: the payload says nothing about the
# agent and the plugin's configured one stays in charge.
run_pick test/fixtures/ready.json --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "no agent list prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "no agent list asks nothing about the agent" "$json" \
    '(has("agent") | not) and .agent == null'
fi

# gum is asked for only where a question it owns will be asked: with no
# terminal the agent answer is the list's first name and the branch is read, so
# a run must reach the hand-back with neither gum nor fzf installed.
ran=$((ran + 1))
PATH="$tmp/no-fzf-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  --base-refs "$tmp/base-refs" \
  --agents pi --branch feat/no-gum --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "no terminal needs no gum" "exit $status: $(cat "$tmp/err")"
elif grep -q 'not found on PATH' "$tmp/err"; then
  fail "no terminal needs no gum" "stderr: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "no terminal needs no gum: no payload" "stdout: $(cat "$tmp/out")"
else
  assert_json "no terminal needs no gum: the agent" "$json" '.agent == "pi"'
fi

# An --agents with no name is a question with a blank row, so it is refused
# rather than asked.
run_pick test/fixtures/ready.json --agents '' --branch feat/x --dry-run
if [ "$status" -ne 2 ]; then
  fail "an empty --agents is refused" "exit $status: $(cat "$tmp/err")"
fi

# (q) The prompt row's preview is not a bead: it says what picking it does
# instead of asking bd about an id that cannot exist. Every tool in this stand-
# in directory leaves a mark when it is run, so "bd was never asked" is a
# missing file.
ran=$((ran + 1))
rm -f "$tmp/called"
PATH="$tmp/watch-bin" CALLED_FILE=$tmp/called "${BASH:-bash}" ./new-work.sh preview '✎' \
  --main . >"$tmp/out" 2>"$tmp/err"
if [ $? -ne 0 ]; then
  fail "the prompt row's preview explains itself" "stderr: $(cat "$tmp/err")"
elif ! grep -qF 'Picking this row writes the prompt in a field of its own.' "$tmp/out"; then
  fail "the prompt row's preview explains itself" "stdout: $(cat "$tmp/out")"
elif [ -e "$tmp/called" ]; then
  fail "the prompt row's preview asks bd nothing" \
    "called: $(sort -u "$tmp/called" 2>/dev/null)"
fi

# (r) The base. The picker resolves the ref new branches are created from and
# hands it over with the remote it lives on, so the tab can fetch that one; the
# tab owns the fetch, so the picker says nothing about the base on stderr.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "the branch question opens on origin/main" "$json" \
    '.base == "origin/main"'
  assert_json "the base names the remote it lives on" "$json" \
    '.base_remote == "origin"'
fi

# --base is the answer whatever this clone would have opened on, and it is not
# a ref this clone has: the picker does not get to refuse it. A ref with no
# record of its own is on no remote, so the tab fetches nothing for it.
run_pick test/fixtures/ready.json --branch feat/x --base refresh --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--base is the base, verbatim" "$json" '.base == "refresh"'
  assert_json "a base on no remote carries no remote" "$json" \
    '(has("base_remote") | not)'
fi

# --no-base is the worktrunk default: a boolean false, not the string an --arg
# would have made of it, and no remote to fetch.
run_pick test/fixtures/ready.json --branch feat/x --no-base --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--no-base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--no-base is false, not a word" "$json" '.base == false'
  assert_json "--no-base fetches nothing" "$json" \
    '(has("base_remote") | not)'
fi

# The remote comes from the ref record, so a base on a remote that is not
# origin says so, and the tab fetches that one rather than origin.
run_pick test/fixtures/ready.json --branch feat/x --base upstream/main \
  --base-refs "$tmp/base-refs-upstream" --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "an upstream base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "an upstream base says upstream" "$json" \
    '.base == "upstream/main" and .base_remote == "upstream"'
fi

# A base and no base are two answers to one question, so both at once is a
# script that cannot mean what it says.
run_pick test/fixtures/ready.json --branch feat/x --base refresh --no-base \
  --dry-run
if [ "$status" -ne 2 ]; then
  fail "a base and no base together exit 2" "exit $status: $(cat "$tmp/err")"
fi

# The note is gone. Where a new branch starts from is now a word in the payload
# rather than a line above the branch question, which is where a person reads it
# next to the base the tab will really use.
run_pick_answer feat/x test/fixtures/ready.json --base refresh --dry-run
if [ "$status" -ne 0 ]; then
  fail "a typed branch with a --base hands back" \
    "exit $status: $(cat "$tmp/err")"
elif grep -qF 'new branches start from' "$tmp/err"; then
  fail "the base is not announced before the branch question" \
    "stderr: $(cat "$tmp/err")"
fi


if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
