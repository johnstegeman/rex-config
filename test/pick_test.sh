#!/usr/bin/env bash
# `new-work.sh pick` and `new-work.sh preview`.
#
# pick is the two-stage picker behind ctrl+space>n: a bead, then a branch, then
# one JSON object handed back to Rex. The bead question is fzf, which cannot be
# driven without a terminal, so it is bypassed with --bead or served by saved
# tool output (--bd-json/--workspaces/--bookmarks/--base-bookmarks). The branch
# question is typed, so its answers arrive on stdin like a person's would.
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

# The agent a pick remembers lives in $XDG_STATE_HOME/rex-config/state, so every
# run here is pointed at a directory under $tmp: none of them may read or write
# the developer's real ~/.local/state, and a state left behind by one case must
# never decide what the next case opens on. A case that wants a remembered name
# writes a directory of its own and names it in front of run_pick.
export XDG_STATE_HOME=$tmp/state

# gws is the fish function that knows how to make one jj colocated workspace,
# and it lives in the developer's ~/.config/fish/functions, which is not here.
# The picker asks fish whether the name is a function, so fish's search path is
# pointed at a directory of its own with a stand-in in it: a case that wants
# the refusal points it at an empty one instead.
mkdir -p "$tmp/fish-functions"
printf 'function gws\nend\n' >"$tmp/fish-functions/gws.fish"
export fish_function_path=$tmp/fish-functions

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
# gum is the screen's field, and a pipe never opens one: the line it would leave
# behind is how "no field was asked" is proven where a field could have been.
cat >"$tmp/bin/gum" <<'EOF'
#!/bin/sh
if [ -n "${GUM_MARKER:-}" ]; then
  printf '%s\n' "$*" >>"$GUM_MARKER"
fi
EOF
chmod +x "$tmp/bin/rex" "$tmp/bin/fzf" "$tmp/bin/gum"

# Whether a run_pick/run_pick_answer call is a dry run: only then may the real
# rex be reached, because a dry run hands nothing back at all.
run_is_dry() {
  local arg
  for arg in "$@"; do
    [ "$arg" = --dry-run ] && return 0
  done
  return 1
}

# run_pick <beads fixture> [options...]
#
# Runs the picker with every tool call replaced by saved output: stdout lands
# in $tmp/out, stderr in $tmp/err, the exit status in $status. PICK_PATH
# prepends the stand-ins to PATH for the assertions that need them, and a run
# that does not name it must be a dry run: without one the picker hands its work
# to rex, and this harness once handed three picks to the real one that way.
run_pick() {
  local fixture=$1
  shift
  ran=$((ran + 1))
  if [ -z "${PICK_PATH:-}" ] && ! run_is_dry "$@"; then
    fail "run_pick needs PICK_PATH for a run that hands back" \
      "$* would reach the real rex"
    status=1
    : >"$tmp/out"
    printf 'run_pick: no PICK_PATH and no --dry-run\n' >"$tmp/err"
    return
  fi
  rm -f "$tmp/rex-args"
  PATH="${PICK_PATH:-$PATH}" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "$fixture" \
    --workspaces test/fixtures/workspaces.txt \
    --bookmarks test/fixtures/branch-bookmarks.txt \
    --base-bookmarks "$tmp/base-bookmarks" "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# The same run with the branch answer typed on stdin and followed by Enter; an
# empty text is the bare Enter that accepts the suggestion. The branch question
# is a typed prompt, so this drives the real path end to end: no fzf stand-in.
# PICK_PATH is the same requirement it is for run_pick: a run without it has to
# be a dry one.
run_pick_answer() {
  local text=$1 fixture=$2
  shift 2
  ran=$((ran + 1))
  if [ -z "${PICK_PATH:-}" ] && ! run_is_dry "$@"; then
    fail "run_pick_answer needs PICK_PATH for a run that hands back" \
      "$* would reach the real rex"
    status=1
    : >"$tmp/out"
    printf 'run_pick_answer: no PICK_PATH and no --dry-run\n' >"$tmp/err"
    return
  fi
  rm -f "$tmp/rex-args"
  printf '%s\n' "$text" |
    PATH="${PICK_PATH:-$PATH}" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
      --main /p/demo/main --root /p/demo --project demo \
      --bd-json "$fixture" \
      --workspaces test/fixtures/workspaces.txt \
      --bookmarks test/fixtures/branch-bookmarks.txt \
      --base-bookmarks "$tmp/base-bookmarks" "$@" \
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

# The host has to have these two, and neither can be stood in for: jj is a
# program the picker runs, and fish is what answers whether gws is a function.
# A host missing one cannot build the restricted PATHs below, so it says so
# once, here, rather than through a case failing on a PATH nobody could build.
for tool in fish jj; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL this host cannot build these fixtures: %s is not on PATH\n' \
      "$tool"
    exit 1
  fi
done

# restricted_path <dir> <tool>...: a PATH holding just those tools, as symlinks
# into DIR. It is how a case takes one tool away from a run without taking away
# the ones around it -- a tool the host itself lacks is skipped, the run being
# the thing under test rather than the machine.
restricted_path() {
  local dir=$1 tool found
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    found=$(command -v "$tool") || continue
    ln -sf "$found" "$dir/$tool"
  done
}

# The two lists a picked name is read against, saved rather than asked for.
# --workspaces is the rendering `done` already reads -- one "name<TAB>root" row
# per workspace, so one fixture shape serves both subcommands -- and its rows are
# feat/6c4, feat/6c4-sub and main, plus the `default` row, which is jj's own
# workspace at the wrapper and no branch at all. --bookmarks is the picker's own
# list and names only: bug/a4l is a bookmark with no workspace, and main and
# feat/6c4 are in both lists, which is what proves the workspace half is read
# first. It is not the base cycle's --base-bookmarks, which is a different
# rendering of a different question and keeps its own fixture.

# The bookmarks the base is resolved from, exactly what
#
#   jj bookmark list --all-remotes -T 'name ++ "@" ++ remote ++ "\n"'
#
# prints for a clone of origin/main whose jj also carries the bare local form
# and its own mirror of the remote-tracking refs: one "<name>@<remote>" per line,
# and the two forms the cycle must never offer beside them.
printf 'main@\nmain@git\nmain@origin\n' >"$tmp/base-bookmarks"

# The same for a clone whose one remote is upstream: the remote a base comes
# from is the suffix in the revision, not a second field.
printf 'main@upstream\n' >"$tmp/base-bookmarks-upstream"

# A ready list with nothing on it: the branch question on its own.
printf '[]\n' >"$tmp/empty-beads.json"

# (a) An empty branch is a cancelled pick: exit 3, no payload, no Rex. The
# stand-in is on PATH so that "no Rex" means the hand-back never ran rather than
# the real rex never being there.
PICK_PATH="$tmp/bin:$PATH" run_pick test/fixtures/ready.json \
  --bead pmm-iris-a4l --branch ''
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

# (b) A name only the bookmark list holds -- a local bookmark with no workspace
# of its own -- is an attach: the bead and its title ride along, and no base
# does, because the branch is not being made from anything.
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
  assert_json "exact branch: an attach" "$json" '.worktree == "attach"'
  assert_json "exact branch: bead" "$json" '.bead == "pmm-iris-a4l"'
  assert_json "exact branch: title" "$json" \
    '.title == "Treat index/catalog pages as non-extractable"'
  assert_json "exact branch: project, root, main" "$json" \
    '.project == "demo" and .root == "/p/demo" and .main == "/p/demo/main"'
  assert_json "exact branch: exactly the seven keys, no base and no create" \
    "$json" 'keys == ["bead", "branch", "main", "project", "root",
              "title", "worktree"]'
fi
ran=$((ran + 1))
if [ -e "$tmp/rex-args" ]; then
  fail "dry run does not call rex" "rex saw: $(sed -n '1,4p' "$tmp/rex-args")"
fi

# (b2) A name that merely begins like a candidate is not that candidate: an
# exact match is one of the two lists, a fuzzy one is a branch to create.
# `bug/a4` is a prefix of `bug/a4l`, so a substring match would call it
# existing.
run_pick test/fixtures/ready.json --bead '' --branch bug/a4 --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "fuzzy prefix prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "fuzzy prefix: branch" "$json" '.branch == "bug/a4"'
  assert_json "fuzzy prefix: a create" "$json" '.worktree == "create"'
fi

# (b3) A new branch name has to be a ref the flow can create; the script says so
# itself instead of letting the workspace add fail in the new tab.
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

# The three meanings a picked name can have, one name each: a branch a jj
# workspace is already on, a local bookmark with no workspace, and a name
# nothing knows yet. They are written here rather than added to the shared
# fixtures, because the cases above count the rows of those. main is a second
# workspace name, so a list holding only one name cannot pass by accident, and
# feat/on-ws is in both lists, so a mode that read the bookmarks first would say
# attach where the answer is switch.
printf 'feat/on-ws\t/tmp/main\nmain\t/tmp/main2\ndefault\t/tmp/wrapper\n' \
  >"$tmp/mode-ws"
printf 'feat/on-branch\nfeat/on-ws\n' >"$tmp/mode-br"

# A pick with the branch already answered, over those three lists and the empty
# ready list above. A dry run, so nothing is handed back and no stand-in rex is
# needed to make it -- and the base bookmarks are the ones above, so a create has
# a base to carry.
pick_mode() {
  local mode_branch=$1
  shift
  ran=$((ran + 1))
  rm -f "$tmp/rex-args"
  ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "$tmp/empty-beads.json" \
    --workspaces "$tmp/mode-ws" --bookmarks "$tmp/mode-br" \
    --base-bookmarks "$tmp/base-bookmarks" \
    --bead '' --branch "$mode_branch" --dry-run "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# (b4) What a name means is one decision, taken once, from the two lists that
# already answer it: the workspaces jj lists first, then the local bookmarks. A
# name in the first list is a workspace to switch to, one only the second holds
# is a branch waiting for a workspace -- an attach, which makes the workspace
# without creating the branch -- and a name in neither is a branch to make. The
# workspace name is the branch name, which is what makes the two lists
# comparable at all. The answer is the payload's `worktree`, and the base travels
# with a create alone: a switch and an attach are given a branch that already
# exists, and there is nothing for either of them to be created from.
pick_mode feat/on-ws
if [ "$status" -ne 0 ]; then
  fail "a workspace's branch exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a workspace's branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a workspace's branch says switch" "$json" '.worktree == "switch"'
  assert_json "a switch carries no base: it was made long ago" "$json" \
    'has("base") | not'
  assert_json "a switch carries no create key any more" "$json" \
    'has("create") | not'
fi

pick_mode feat/on-branch
if [ "$status" -ne 0 ]; then
  fail "a bare local bookmark exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a bare local bookmark prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a bookmark with no workspace says attach" "$json" \
    '.worktree == "attach"'
  assert_json "an attach carries no base: the branch is not being made" \
    "$json" 'has("base") | not'
fi

pick_mode feat/brand-new
if [ "$status" -ne 0 ]; then
  fail "a name in neither list exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a name in neither list prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a name nothing knows says create" "$json" \
    '.worktree == "create"'
  assert_json "a create carries the base it starts from" "$json" \
    '.base == "main@origin"'
fi

# The `default` row is jj's own workspace at the wrapper -- every directory no
# other workspace owns -- and it is no branch, so a picker that offered it would
# offer a name nobody can work on. A --workspaces listing holding nothing else
# still says create, which is the only answer a clone with no branch workspace
# has, and is what proves the row was skipped rather than read as a name.
ran=$((ran + 1))
./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json "$tmp/empty-beads.json" \
  --workspaces test/fixtures/workspaces-default-only.txt \
  --bookmarks "$tmp/mode-br" \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead '' --branch default --dry-run \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
if [ "$status" -ne 0 ]; then
  fail "the default row exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the default row prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "the default row is not a workspace to switch to" "$json" \
    '.worktree == "create"'
fi

# (b4a) The base cycle is read for a create alone. A switch and an attach name a
# branch that already exists, and their payload carries no revision, so nothing is
# asked of jj for them -- a bookmark list that cannot even be opened is not their
# failure. The same list does stop a create, which is what proves these two cases
# are about the mode rather than about a failure that stopped happening.
pick_without_bookmarks() {
  local mode_branch=$1
  ran=$((ran + 1))
  ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "$tmp/empty-beads.json" \
    --workspaces "$tmp/mode-ws" --bookmarks "$tmp/mode-br" \
    --base-bookmarks "$tmp/no-such-bookmarks" \
    --bead '' --branch "$mode_branch" --dry-run \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

pick_without_bookmarks feat/on-ws
if [ "$status" -ne 0 ]; then
  fail "a switch needs no bookmarks" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a switch needs no bookmarks: no payload" "stdout: $(cat "$tmp/out")"
else
  assert_json "a switch is handed back without the base cycle" "$json" \
    '.worktree == "switch"'
fi
ran=$((ran + 1))
if grep -q 'bookmarks' "$tmp/err"; then
  fail "a switch never reads the bookmarks" "stderr: $(cat "$tmp/err")"
fi

pick_without_bookmarks feat/on-branch
if [ "$status" -ne 0 ]; then
  fail "an attach needs no bookmarks" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "an attach needs no bookmarks: no payload" "stdout: $(cat "$tmp/out")"
else
  assert_json "an attach is handed back without the base cycle" "$json" \
    '.worktree == "attach"'
fi

pick_without_bookmarks feat/brand-new
if [ "$status" -ne 1 ]; then
  fail "a create still reads the bookmarks" "exit $status: $(cat "$tmp/err")"
elif ! grep -qxF "new-work.sh: pick: could not read the bookmarks of $tmp/no-such-bookmarks" \
  "$tmp/err"; then
  fail "a create says which bookmarks it could not read" "stderr: $(cat "$tmp/err")"
fi

# (b4b) A live `jj workspace list` that fails is a read that failed, not a
# repository with no workspaces. The two are different answers to different
# questions: a name the listing would have held is a workspace to switch to, and
# taking it for a bookmark with no workspace would send the tab to `jws --attach`,
# which refuses on the directory that is already there. So the pick stops, naming
# what it could not read and nothing else -- where `candidates` still prints the
# bookmark half, because a partial list of suggestions is still worth having
# (test/branch_test.sh pins that half).
#
# The stand-in says nothing itself: the one line here is this script's own, and a
# jj that also complained would hide how many lines the pick prints.
mkdir -p "$tmp/nowt/main" "$tmp/nowt/.jj/repo" "$tmp/bad-jj"
cat >"$tmp/bad-jj/jj" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bad-jj/jj"

ran=$((ran + 1))
PATH="$tmp/bad-jj:$PATH" ./new-work.sh pick \
  --main "$tmp/nowt/main" --root /p/demo --project demo \
  --bd-json "$tmp/empty-beads.json" --bookmarks "$tmp/mode-br" \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead '' --branch feat/on-ws --dry-run \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
if [ "$status" -ne 1 ]; then
  fail "a jj that cannot be read stops a pick" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/err")" != \
  "new-work.sh: could not read the workspaces of $tmp/nowt/main" ]; then
  fail "a jj that cannot be read is named, once" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ]; then
  fail "a jj that cannot be read hands nothing back" "stdout: $(cat "$tmp/out")"
fi

# The same asymmetry from the caller's side: a --workspaces fixture that cannot
# be opened is that caller's mistake rather than a repository this machine cannot
# read, so it fails loudly and names the file -- and it stops before any list is
# printed, since half a list is a guess dressed as an answer.
ran=$((ran + 1))
run_pick test/fixtures/ready.json --bead '' --branch feat/on-ws \
  --workspaces "$tmp/no-such-workspaces" --dry-run
if [ "$status" -ne 1 ]; then
  fail "an unreadable --workspaces fixture exits 1" \
    "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/err")" != \
  "new-work.sh: could not read the workspaces of $tmp/no-such-workspaces" ]; then
  fail "an unreadable --workspaces fixture names the file" \
    "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ]; then
  fail "an unreadable --workspaces fixture hands nothing back" \
    "stdout: $(cat "$tmp/out")"
fi

# And the same for the bookmark half, which is a second read the pick makes.
ran=$((ran + 1))
run_pick test/fixtures/ready.json --bead '' --branch feat/on-ws \
  --bookmarks "$tmp/no-such-bookmarks-list" --dry-run
if [ "$status" -ne 1 ]; then
  fail "an unreadable --bookmarks fixture exits 1" \
    "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/err")" != \
  "new-work.sh: could not read the bookmarks of $tmp/no-such-bookmarks-list" ]; then
  fail "an unreadable --bookmarks fixture names the file" \
    "stderr: $(cat "$tmp/err")"
fi

# The worktrunk shortcuts are gone, and four more names are refused with them.
# `pr:7` and `mr:12` named a pull or merge request's branch when worktrunk
# resolved them, and this flow does not ask it to; `^` and `-` were worktrunk's
# default branch and its previous worktree; `@` is jj's own name for the working
# copy, which git will happily accept as a branch name and this flow will not,
# because the revision language it now speaks would read a bookmark called `@` as
# the working copy. None of them is on either list, so each is refused here, with
# the reason, while the picker is still on screen -- rather than resolving in a
# tab to a name nothing can carry back.
for refused in '^' '-' '@' 'pr:7' 'mr:12'; do
  ran=$((ran + 1))
  pick_mode "$refused"
  if [ "$status" -ne 2 ]; then
    fail "the name $refused exits 2" "exit $status: $(cat "$tmp/err")"
  elif ! grep -qxF "new-work.sh: not a valid branch name: $refused" "$tmp/err"; then
    fail "the name $refused says it is not a branch name" \
      "stderr: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if [ -s "$tmp/out" ] || [ -e "$tmp/rex-args" ]; then
    fail "the name $refused starts nothing" \
      "stdout: $(cat "$tmp/out") rex: $(sed -n '1,4p' "$tmp/rex-args" 2>/dev/null)"
  fi
done

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
  assert_json "typed branch payload" "$json" '.worktree == "create"'
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
# The note is a line of the script's, so it carries the script's name the way
# every other line about the run does -- both of the paths it can arrive by do.
ran=$((ran + 1))
if ! grep -qxF 'new-work.sh: no ready beads' "$tmp/err"; then
  fail "no ready beads is said out loud" "stderr: $(cat "$tmp/err")"
fi

# (d) A name that is on the candidate list stays a switch even when no bead
# suggested it -- and where the two lists both hold it, the workspace list wins.
run_pick test/fixtures/ready.json --bead '' --branch feat/6c4 --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "exact candidate name prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "exact candidate payload" "$json" '.branch == "feat/6c4"'
  assert_json "exact candidate payload" "$json" '.worktree == "switch"'
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
  assert_json "enter at the suggestion: a create" "$json" \
    '.worktree == "create"'
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
  assert_json "typed branch: a create" "$json" '.worktree == "create"'
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
    '.branch == "feat/spaced" and .worktree == "create"'
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
# workspace that has it: the list is no longer shown, but it still decides.
run_pick_answer 'feat/6c4' test/fixtures/ready.json --bead '' --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "typed candidate prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "typed candidate: the typed name" "$json" \
    '.branch == "feat/6c4"'
  assert_json "typed candidate: a switch" "$json" '.worktree == "switch"'
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
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead pmm-iris-a4l </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "missing tool exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -qx 'jq not found on PATH — press any key' "$tmp/err"; then
  fail "missing tool is named" "stderr: $(cat "$tmp/err")"
fi

# git is load-bearing on the create path -- check-ref-format decides whether a
# name can be made -- so a missing one is named rather than every name coming
# back "not a valid branch name". The branch list itself is jj's now.
restricted_path "$tmp/no-git-bin" bash cat cut grep sed awk tr jq
ran=$((ran + 1))
PATH="$tmp/no-git-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead pmm-iris-a4l --branch feat/needs-git --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "a missing git exits 1" "exit $status: $(cat "$tmp/err")"
elif ! grep -q 'git not found on PATH' "$tmp/err"; then
  fail "a missing git is named" "stderr: $(cat "$tmp/err")"
fi

# Every tool the run needs except fzf and gum: with no terminal nothing is asked,
# so the run must reach the empty-branch exit instead of complaining about the
# two tools only the screen calls. jj and fish are on this PATH because gws is
# the only thing that makes the workspace and this machine has it (a stand-in,
# as the fish function path at the top of the file says).
restricted_path "$tmp/no-fzf-bin" bash cat cut grep sed awk tr git bd wt jq jj fish
ran=$((ran + 1))
PATH="$tmp/no-fzf-bin" REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
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
    --workspaces test/fixtures/workspaces.txt \
    --bookmarks test/fixtures/branch-bookmarks.txt \
    --base-bookmarks "$tmp/base-bookmarks" \
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
  assert_json "a typed branch needs no fzf: a create" "$json" \
    '.worktree == "create"'
fi

# (g2) A machine or a repo that cannot make a jj workspace is refused before the
# screen opens and before anything is claimed: a bead picked for a pane that can
# only fail is worse than a refusal. Four things can be missing, and each is
# named -- the wrapper's .jj/repo (this repo was never ginit'd), jj on PATH (the
# base cycle runs it), gws as a fish function (the one thing that knows the
# order a workspace and a worktree are made in), and fish itself (which is what
# answers for gws at all). Nothing has been asked, handed back or even started
# when one of them is: stdout, the stand-in fzf and the stand-in rex are all
# left untouched.
#
# refused <name> <fragment stderr must hold> <command...>, the environment as
# leading WORDS: what differs between the cases is only what each one lacks.
refused() {
  local name=$1 want=$2
  shift 2
  ran=$((ran + 1))
  rm -rf "$tmp/rex-args" "$tmp/fzf-ran"
  env FZF_MARKER="$tmp/fzf-ran" REX_ARGS_FILE="$tmp/rex-args" "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  local got=$?
  if [ "$got" -ne 1 ]; then
    fail "$name" "exit $got: $(cat "$tmp/err")"
  elif ! grep -qF "$want" "$tmp/err"; then
    fail "$name is named" "stderr: $(cat "$tmp/err")"
  elif [ -s "$tmp/out" ]; then
    fail "$name leaves no prompt and no payload" \
      "stdout: $(cat "$tmp/out")"
  elif [ -e "$tmp/rex-args" ]; then
    fail "$name hands nothing back" "$(cat "$tmp/rex-args")"
  elif [ -e "$tmp/fzf-ran" ]; then
    fail "$name opens no screen" 'fzf was started'
  fi
}

# A repo that was never ginit'd -- no .jj/repo beside main -- while main itself is
# there, so the refusal is about the workspace and not about a directory that
# does not exist. No fixtures at all here: a run given all four never opens
# --main, and this one has to.
mkdir -p "$tmp/plain/main"
refused "a repo that was never ginit'd exits 1" "not ginit'd" \
  ./new-work.sh pick --main "$tmp/plain/main" --root /p/demo --project demo \
  --bead '' --branch feat/x --dry-run
ran=$((ran + 1))
if ! grep -qF "$(dirname "$tmp/plain/main") is not ginit'd" "$tmp/err"; then
  fail "the never-ginit'd refusal names the wrapper it looked in" \
    "stderr: $(cat "$tmp/err")"
elif ! grep -qF 'run ginit first' "$tmp/err"; then
  fail "the never-ginit'd refusal names ginit" "stderr: $(cat "$tmp/err")"
fi

# jj reads the base cycle, so it is named only where that cycle is really read:
# no --base-bookmarks fixture stands in for the bookmark list here, which is
# also why --main has to exist -- and, being a wrapper gws could create in, to
# hold .jj/repo itself, which the preflight finds with dirname.
mkdir -p "$tmp/ginit/main" "$tmp/ginit/.jj/repo"
restricted_path "$tmp/no-jj-bin" \
  bash cat cut grep sed awk tr dirname mktemp rm git bd wt jq fish
refused "a missing jj exits 1" 'jj not found on PATH — press any key' \
  PATH="$tmp/no-jj-bin" ./new-work.sh pick \
  --main "$tmp/ginit/main" --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --bead pmm-iris-a4l --branch feat/no-jj

# The shape that is deliberately NOT supported, pinned here so it is not
# re-admitted by accident: a normal clone ginit'd where it stands, so .jj/repo
# sits inside the worktree itself rather than in a wrapper beside a main
# workspace. gws' ancestor walk would find that repo, but gws then runs its add
# from <wrapper>/main to inherit that workspace's sparse patterns and refuses
# without one -- after the bead is claimed, which is the outcome this preflight
# exists to prevent. So the refusal happens here, before anything is asked.
mkdir -p "$tmp/in-place/.jj/repo"
refused "a repo ginit'd in place is refused for it" "not ginit'd" \
  ./new-work.sh pick --main "$tmp/in-place" --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --bead pmm-iris-a4l --branch feat/in-place
ran=$((ran + 1))
if ! grep -qF 'gws needs a wrapper with .jj/repo as a directory' "$tmp/err"; then
  fail "the in-place refusal says which shape gws needs" \
    "stderr: $(cat "$tmp/err")"
fi

# The same jj, needed on the screen even where --no-base says there is no
# revision at all: the float resolves the whole cycle anyway, so ctrl-r can
# cycle back to one, and that read is a jj call. PICK_SCREEN=1 is what says
# this run has the float's terminal, and --bead answers the bead question so
# that no tool only the screen needs is asked for on the way to jj.
refused "a screen with no jj exits 1" 'jj not found on PATH — press any key' \
  PICK_SCREEN=1 PATH="$tmp/no-jj-bin" ./new-work.sh pick \
  --main "$tmp/ginit/main" --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --no-base --bead '' --branch feat/no-jj-screen --dry-run

# gws is a fish function rather than a program, and an empty function path is a
# machine that has none: the pane would open and then create nothing. No
# --dry-run here, because that is exactly the run that makes no workspace and so
# is not stopped for the tool.
mkdir -p "$tmp/no-fish-functions"
refused "a missing gws exits 1" 'gws is not a fish function' \
  fish_function_path="$tmp/no-fish-functions" ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead pmm-iris-a4l --branch feat/no-gws

# A machine with no fish at all cannot even be asked, and is named the way every
# other missing tool is -- by need, whose message this one inherits.
restricted_path "$tmp/no-fish-bin" bash cat cut grep sed awk tr git bd wt jq jj
refused "a missing fish exits 1" 'fish not found on PATH — press any key' \
  PATH="$tmp/no-fish-bin" ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead pmm-iris-a4l --branch feat/no-fish

# (g3) The same two checks, seen from the other side: a preflight never stops a
# run for a tool that run would not call. A --dry-run hands its answers back
# and creates no workspace, so gws is never asked for; and a bookmark fixture
# stands in for the one thing jj is read for, so jj is never asked for either.
# The payload is the proof: a run on a machine with neither still prints the
# line that carries its branch.
ran=$((ran + 1))
fish_function_path="$tmp/no-fish-functions" PATH="$tmp/no-jj-bin" \
  REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
  --bead pmm-iris-a4l --branch feat/no-jj --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a dry run needs neither jj nor gws" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a dry run needs neither jj nor gws: no payload" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a dry run needs neither jj nor gws: the branch" "$json" \
    '.branch == "feat/no-jj" and .worktree == "create"'
fi

# --no-base is the other way the cycle is never read, and it needs no bookmark
# fixture to say so: the run asks jj for nothing and is not stopped for it.
ran=$((ran + 1))
fish_function_path="$tmp/no-fish-functions" PATH="$tmp/no-jj-bin" \
  REX_ARGS_FILE=$tmp/rex-args ./new-work.sh pick \
  --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --no-base --bead '' --branch feat/no-jj-no-base --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "--no-base needs no jj" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--no-base needs no jj: no payload" "stdout: $(cat "$tmp/out")"
else
  assert_json "--no-base needs no jj: no revision at all" "$json" \
    '.base == false'
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

# (h3) The same directory, this time with --no-base and no --base-bookmarks:
# nothing is read for the base, so the guard above never opens --main and a
# directory that is not there costs nothing. The arm every run_pick case hides,
# because every one of them names a --base-bookmarks.
ran=$((ran + 1))
./new-work.sh pick --main "$tmp/nowhere" --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --no-base --bead '' --branch feat/x --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a --no-base pick never opens --main" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a --no-base pick prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a --no-base pick: no revision at all" "$json" \
    '.base == false and (has("base_remote") | not)'
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
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
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
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
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

# (n3) The blank answer without a terminal. ctrl-n can only be pressed at fzf,
# which needs a terminal, so --blank is how a script hands the picker that same
# answer -- and it is the answer itself, not a note about it: a JSON true with
# no prompt field, which is what the tab reads as "an agent, and nothing to
# say". An absent blank (n2) is still "the picker was never asked".
run_pick test/fixtures/ready.json --blank --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--blank prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--blank is a boolean true" "$json" \
    '.blank == true and (.blank | type) == "boolean"'
  assert_json "--blank sends no prompt" "$json" '(has("prompt") | not)'
  assert_json "--blank picks no bead and no title" "$json" \
    '.bead == "" and .title == ""'
  assert_json "--blank's keys are the flag and nothing else" "$json" \
    'keys == ["base", "bead", "blank", "branch", "main",
              "project", "root", "title", "worktree"]'
fi

# The three answers to the bead question are three answers to one question, so
# two at once is a script that cannot mean what it says -- the same refusal
# --bead and --prompt already get.
for other in --prompt --bead; do
  run_pick test/fixtures/ready.json --blank "$other" x --branch feat/x --dry-run
  if [ "$status" -ne 2 ]; then
    fail "--blank with $other is refused" "exit $status: $(cat "$tmp/err")"
  elif ! grep -q 'answer the same question' "$tmp/err"; then
    fail "--blank with $other says why" "stderr: $(cat "$tmp/err")"
  fi
done

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
    'keys == ["base", "bead", "branch", "main", "project",
              "prompt", "root", "title", "worktree"]'
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
    'keys == ["agent", "base", "bead", "branch", "main",
              "project", "root", "title", "worktree"]'
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
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/base-bookmarks" \
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

# (r) The base. The picker resolves the jj revision new workspaces are started
# from and hands it over as one string -- the remote it came from is the @remote
# in that name -- and the tab owns the fetch, so the picker says nothing about
# the base on stderr.
run_pick test/fixtures/ready.json --bead pmm-iris-a4l --branch feat/x \
  --origin-head origin/main --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "the branch question opens on main@origin" "$json" \
    '.base == "main@origin"'
  assert_json "the base is one revision and no second carrier" "$json" \
    '(has("base_remote") | not)'
fi

# With no origin/HEAD named, the cycle's fixed answer is the one that travels --
# the default branch as the remote has it, not this machine's copy.
run_pick test/fixtures/ready.json --branch feat/x --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the fallback base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a clone with no origin/HEAD opens on main@origin" "$json" \
    '.base == "main@origin"'
fi

# --base is the answer whatever this clone would have opened on, and it is not a
# revision this clone has: the picker does not get to refuse it, because the
# workspace is made later, in the tab, where jj answers for it.
run_pick test/fixtures/ready.json --branch feat/x --base refresh@origin \
  --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--base is the base, verbatim" "$json" '.base == "refresh@origin"'
  assert_json "a leaf revision carries no second carrier" "$json" \
    '(has("base_remote") | not)'
fi

# --no-base is "no revision at all": a boolean false, not the string an --arg
# would have made of it.
run_pick test/fixtures/ready.json --branch feat/x --no-base --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--no-base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--no-base is false, not a word" "$json" '.base == false'
  assert_json "--no-base sends no second carrier" "$json" \
    '(has("base_remote") | not)'
fi

# A base on a remote that is not origin says so in the revision itself, which is
# what tells the tab which remote to fetch.
run_pick test/fixtures/ready.json --branch feat/x --base main@upstream \
  --base-bookmarks "$tmp/base-bookmarks-upstream" --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "an upstream base prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "an upstream base says upstream in its own name" "$json" \
    '.base == "main@upstream" and (has("base_remote") | not)'
fi

# A base and no base are two answers to one question, so both at once is a
# script that cannot mean what it says.
run_pick test/fixtures/ready.json --branch feat/x --base refresh --no-base \
  --dry-run
if [ "$status" -ne 2 ]; then
  fail "a base and no base together exit 2" "exit $status: $(cat "$tmp/err")"
fi

# A --base-bookmarks that cannot be read is one line under this verb's own name,
# and no shell line number beside it.
ran=$((ran + 1))
./new-work.sh pick --main /p/demo/main --root /p/demo --project demo \
  --bd-json test/fixtures/ready.json \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  --base-bookmarks "$tmp/no-such-bookmarks" --bead '' --branch feat/x --dry-run \
  </dev/null >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "an unreadable --base-bookmarks exits 1" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/err")" != \
  "new-work.sh: pick: could not read the bookmarks of $tmp/no-such-bookmarks" ]; then
  fail "an unreadable --base-bookmarks is named under pick" "stderr: $(cat "$tmp/err")"
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


# (s) The composer: the one screen's answers, kept in a directory of their own
# with one file per answer, so a key can read and change one of them while fzf
# is up. fzf needs a terminal, so the screen itself is out of reach here; what
# is pinned is the program behind each key and the two lines it shows -- the
# header's exact bytes, and that a key changes one field and leaves the rest
# (the rows, the other answers) alone.

# The state directory a picker run builds before it opens the screen.
composer_state() { # DIR AGENT BRANCH BASE_INDEX
  local dir=$1
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/agent"
  printf '%s\n' "$3" >"$dir/branch"
  printf '%s\n' "$4" >"$dir/base_index"
  printf '%s\n' "✎"$'\t'"write a prompt instead" \
    "pmm-iris-a4l"$'\t'"Treat index/catalog pages as non-extractable" >"$dir/rows"
}

# run_composer <args...>: the verb's stdout in $tmp/out, its stderr in $tmp/err,
# its exit status in $status. stdin is a pipe with nothing on it, which is how a
# verb that asks for an answer is answered with an empty one.
run_composer() {
  ran=$((ran + 1))
  ./new-work.sh composer "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# The two header lines, exactly: the leading space and the separators are part
# of what fzf shows, so they are part of what is compared.
heading() { # PROJECT AGENT BRANCH BASE
  printf ' %s · agent: %s · branch: %s · base: %s\n %s\n' "$1" "$2" "$3" "$4" \
    'ctrl-a agent  ctrl-b branch  ctrl-r base  ctrl-n blank  enter start  esc no bead'
}

check_header() { # NAME WANT
  local name=$1 want=$2
  if [ "$status" -ne 0 ]; then
    fail "$name exits 0" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$(cat "$tmp/out")" != "$want" ]; then
    fail "$name" "want [$want], got [$(cat "$tmp/out")]"
  fi
  # $(cat) drops trailing newlines, so a verb printing a third, empty line would
  # still compare equal: the header is two lines, and it is counted as two.
  ran=$((ran + 1))
  if [ "$(wc -l <"$tmp/out" | tr -d ' ')" != 2 ]; then
    fail "$name is exactly two lines" \
      "$(wc -l <"$tmp/out" | tr -d ' ') lines: $(cat "$tmp/out")"
  fi
}

# The header the screen opens on: the project, then the three answers, then the
# line of keys. An empty agent is "none" -- the cycle's no-agent row -- and an
# empty base is the "no revision at all" sentinel, named rather than blanked.
composer_state "$tmp/cs1" pi 'bug/58h' 1
printf 'main@origin\n@\nmain\n' >"$tmp/cs1/bases"
run_composer header --state "$tmp/cs1" --project rex-config
check_header "the header's two lines" \
  "$(heading rex-config pi 'bug/58h' main@origin)"

composer_state "$tmp/cs2" '' 'feat/x' 1
printf '\n@\nmain\n' >"$tmp/cs2/bases"
run_composer header --state "$tmp/cs2" --project rex-config
check_header "an empty agent is none and an empty base is none" \
  "$(heading rex-config none 'feat/x' 'none')"

# The branch the screen opens on is the name a bare Enter would create, seeded
# from the bead the cursor lands on (load:pos(2)), so the field describes the tab
# the pick would make before anything is pressed. This is that state, the way the
# picker writes it: the first bead's derived name.
composer_state "$tmp/cs1b" pi 'feat/58h' 1
printf 'main@origin\n@\n' >"$tmp/cs1b/bases"
run_composer header --state "$tmp/cs1b" --project rex-config
check_header "a branch seeded from the first bead is the header's branch" \
  "$(heading rex-config pi 'feat/58h' main@origin)"

# With nothing to name -- no bead to derive a branch from, and no ctrl-b -- the
# field says so in words: an empty one would print as a doubled space and read
# as a bug.
composer_state "$tmp/cs1c" pi '' 1
printf 'main@origin\n@\n' >"$tmp/cs1c/bases"
run_composer header --state "$tmp/cs1c" --project rex-config
check_header "a branch nothing has named yet says so" \
  "$(heading rex-config pi '(none yet)' main@origin)"

# ctrl-a: the next name on the agent list, then none, then round again -- and
# only the header is repainted. The rows are beads, so nothing about them
# depends on the agent and a key that reloaded them would clear the list and
# drop the cursor back to the top for a one-word change.
composer_state "$tmp/cs3" pi 'feat/one' 1
printf 'main@origin\n@\n' >"$tmp/cs3/bases"
rows_before=$(cat "$tmp/cs3/rows")
cycle_agent() { # NAME WANT_LABEL WANT_AGENT
  local name=$1 label=$2 file=$3
  run_composer cycle-agent --state "$tmp/cs3" --project rex-config \
    --agents pi --agents claude
  if [ "$status" -ne 0 ]; then
    fail "$name exits 0" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$(cat "$tmp/out")" != \
    "$(heading rex-config "$label" feat/one main@origin)" ]; then
    fail "$name repaints the header" "stdout: $(cat "$tmp/out")"
  fi
  if [ "$(cat "$tmp/cs3/agent")" != "$file" ]; then
    fail "$name writes the agent" "agent file: [$(cat "$tmp/cs3/agent")]"
  fi
  ran=$((ran + 1))
  if [ "$(cat "$tmp/cs3/rows")" != "$rows_before" ]; then
    fail "$name leaves the rows alone" "rows: $(cat "$tmp/cs3/rows")"
  fi
}
cycle_agent 'the next agent is the second name' claude claude
cycle_agent 'the name after the last is none' none ''
cycle_agent 'the cycle wraps to the first name' pi pi

# ctrl-r: the next base in the cycle, then round again. The cycle was resolved
# once, before the screen opened -- one bookmark list per run, not one per
# keystroke -- so a --main that is not even there proves nothing was read.
composer_state "$tmp/cs4" pi 'feat/one' 1
printf 'main@origin\n@\nmain\n' >"$tmp/cs4/bases"
cycle_base() { # NAME WANT_INDEX WANT_LABEL
  local name=$1 index=$2 label=$3
  run_composer cycle-base --state "$tmp/cs4" --project rex-config \
    --main "$tmp/nowhere"
  if [ "$status" -ne 0 ]; then
    fail "$name exits 0" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$(cat "$tmp/out")" != \
    "$(heading rex-config pi feat/one "$label")" ]; then
    fail "$name repaints the header" "stdout: $(cat "$tmp/out")"
  fi
  if [ "$(cat "$tmp/cs4/base_index")" != "$index" ]; then
    fail "$name moves the index" "base_index: $(cat "$tmp/cs4/base_index")"
  fi
}
cycle_base 'the next base is @' 2 '@'
cycle_base 'the base after that is main' 3 'main'
cycle_base 'the cycle wraps to the opening answer' 1 'main@origin'

# The cycle is counted by entries, not by newlines: a bases file whose last line
# has none -- one written by hand -- must not lose its last base, which would
# shorten the cycle and wrap one entry early.
composer_state "$tmp/cs8" pi 'feat/one' 1
printf 'main@origin\n@' >"$tmp/cs8/bases"
cycle_base_no_newline() { # NAME WANT_INDEX WANT_LABEL
  local name=$1 index=$2 label=$3
  run_composer cycle-base --state "$tmp/cs8" --project rex-config \
    --main "$tmp/nowhere"
  if [ "$status" -ne 0 ]; then
    fail "$name exits 0" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$(cat "$tmp/out")" != "$(heading rex-config pi feat/one "$label")" ]; then
    fail "$name repaints the header" "stdout: $(cat "$tmp/out")"
  fi
  if [ "$(cat "$tmp/cs8/base_index")" != "$index" ]; then
    fail "$name moves the index" "base_index: $(cat "$tmp/cs8/base_index")"
  fi
}
cycle_base_no_newline 'a bases file with no final newline cycles to its last entry' \
  2 '@'
cycle_base_no_newline 'a bases file with no final newline wraps after it' 1 'main@origin'

# ctrl-b: the branch, typed. gum asks it in the float and stdin carries it in a
# pipe, so this is the real path either way. The answer is trimmed, the edit is
# marked so the branch stops tracking the bead, and nothing is printed -- fzf is
# told the branch by the header, not by what this wrote.
composer_state "$tmp/cs5" pi 'feat/one' 1
: >"$tmp/cs5/bases"
run_branch_field() { # DIR STDIN
  ran=$((ran + 1))
  if [ "$2" = EOF ]; then
    ./new-work.sh composer branch-field --state "$1" --project rex-config \
      >"$tmp/out" 2>"$tmp/err" </dev/null
  else
    printf '%s\n' "$2" |
      ./new-work.sh composer branch-field --state "$1" --project rex-config \
        >"$tmp/out" 2>"$tmp/err"
  fi
  status=$?
}
run_branch_field "$tmp/cs5" '  feat/two  '
if [ "$status" -ne 0 ]; then
  fail "a typed branch exits 0" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/cs5/branch")" != 'feat/two' ]; then
  fail "a typed branch is trimmed" "branch: [$(cat "$tmp/cs5/branch")]"
elif [ "$(cat "$tmp/cs5/branch_edited")" != 1 ]; then
  fail "a typed branch stops tracking the bead" \
    "branch_edited: [$(cat "$tmp/cs5/branch_edited" 2>/dev/null)]"
elif [ -s "$tmp/out" ]; then
  fail "a typed branch prints nothing" "stdout: $(cat "$tmp/out")"
fi

# A field that was cancelled (ctrl-c, or no line at all on a pipe) and one that
# was left empty, or filled with spaces, are the same answer: the branch keeps
# the value it had and the pick carries on. Nothing was edited, so nothing is
# marked either -- the branch still tracks the bead.
composer_state "$tmp/cs6" pi 'feat/one' 1
: >"$tmp/cs6/bases"
keeps_branch() { # NAME STDIN
  local name=$1
  run_branch_field "$tmp/cs6" "$2"
  if [ "$status" -ne 0 ]; then
    fail "$name exits 0" "exit $status: $(cat "$tmp/err")"
  elif [ "$(cat "$tmp/cs6/branch")" != 'feat/one' ]; then
    fail "$name keeps the branch" "branch: [$(cat "$tmp/cs6/branch")]"
  elif [ -s "$tmp/cs6/branch_edited" ]; then
    fail "$name marks no edit" \
      "branch_edited: [$(cat "$tmp/cs6/branch_edited")]"
  fi
}
keeps_branch 'an empty answer keeps the branch' ''
keeps_branch 'a space-only answer keeps the branch' '   '
keeps_branch 'a cancelled field keeps the branch' EOF

# rows is what fzf is given: the prompt row first, then the beads, byte for
# byte -- tabs, and a title holding a tab of its own, included.
composer_state "$tmp/cs7" pi '' 1
printf '✎\twrite a prompt instead\nb-1\tA title\twith a tab\n' >"$tmp/cs7/rows"
run_composer rows --state "$tmp/cs7"
if [ "$status" -ne 0 ]; then
  fail "rows exits 0" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/out")" != "$(cat "$tmp/cs7/rows")" ]; then
  fail "rows prints the rows verbatim" "stdout: $(cat "$tmp/out")"
fi

# The five verbs share one parse of --state and --project and still say what went
# wrong under their own name, so the words are pinned here: moving the parse
# around is a refactor, and a refactor that changed what a person reads in the
# float is a regression.
usage_case() { # NAME WANT_LINE args...
  local name=$1 want=$2
  shift 2
  run_composer "$@"
  if [ "$status" -ne 2 ]; then
    fail "$name exits 2" "exit $status: $(cat "$tmp/err")"
  elif ! grep -qxF "new-work.sh: $want" "$tmp/err"; then
    fail "$name says why" "stderr: $(sed -n 1p "$tmp/err")"
  fi
}
usage_case 'rows needs its state' 'composer rows: need --state DIR' \
  rows --project rex-config
usage_case 'rows refuses an unknown option' \
  'composer rows: unknown option --nope' rows --state "$tmp/cs1" --nope
usage_case 'a state directory needs a value' \
  'composer rows: --state needs a directory' rows --state
usage_case 'header needs its project' 'composer header: need --project NAME' \
  header --state "$tmp/cs1"
usage_case 'header refuses an unknown option' \
  'composer header: unknown option --nope' header --state "$tmp/cs1" \
  --project rex-config --nope
usage_case 'cycle-agent refuses an unknown option' \
  'composer cycle-agent: unknown option --nope' cycle-agent \
  --state "$tmp/cs1" --project rex-config --nope
usage_case 'cycle-agent needs a name after --agents' \
  'composer cycle-agent: --agents needs a name' cycle-agent \
  --state "$tmp/cs1" --project rex-config --agents ''
usage_case 'cycle-base refuses an unknown option' \
  'composer cycle-base: unknown option --nope' cycle-base \
  --state "$tmp/cs1" --project rex-config --main "$tmp/nowhere" --nope
usage_case 'branch-field needs its state' \
  'composer branch-field: need --state DIR' branch-field --project rex-config
usage_case 'branch-field refuses an unknown option' \
  'composer branch-field: unknown option --nope' branch-field \
  --state "$tmp/cs1" --nope

# ctrl-r reads its cycle from --base-bookmarks when the state holds none, as
# `bases` does: the two arguments are alternatives -- one of them names the
# bookmarks -- and neither is a --main the other merely decorates.
composer_state "$tmp/cs9" pi 'feat/one' 1
: >"$tmp/cs9/bases"
run_composer cycle-base --state "$tmp/cs9" --project rex-config \
  --base-bookmarks "$tmp/base-bookmarks"
if [ "$status" -ne 0 ]; then
  fail "cycle-base takes --base-bookmarks on its own" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/out")" != \
  "$(heading rex-config pi feat/one '@')" ]; then
  fail "cycle-base resolves its cycle from --base-bookmarks" "stdout: $(cat "$tmp/out")"
elif [ "$(cat "$tmp/cs9/base_index")" != 2 ]; then
  fail "cycle-base moves to the second entry" \
    "base_index: $(cat "$tmp/cs9/base_index")"
fi
usage_case 'cycle-base needs one of --main and --base-bookmarks' \
  'composer cycle-base: need --main DIR (or --base-bookmarks FILE)' cycle-base \
  --state "$tmp/cs9" --project rex-config


# (t) A bead-less answer asks for its branch. Typed text that matches no bead,
# the prompt row and ctrl-n all say "no bead", and none of them has a branch to
# derive it from: the branch question is the one answer such a run still needs,
# and it is asked in the field it has always been asked in -- prefilled with
# whatever the header held, so Enter accepts it and ctrl-c is the cancelled
# pick it always was. A bead, or a --branch already given, is an answer, so
# nothing is asked and nothing is paid for.

# On a pipe nothing changes and nothing is paid for: there is no screen to open
# a field in, so the answer is a line of stdin -- and a line there and no line
# at all are still the two answers they have always been.
run_pick_answer 'feat/typed' test/fixtures/ready.json \
  --prompt 'why is the guard flaky?' --dry-run
if ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a piped prompt with no branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a piped prompt with no branch: the text is the prompt" "$json" \
    '.prompt == "why is the guard flaky?" and .bead == ""'
  assert_json "a piped prompt with no branch: stdin is the branch" "$json" \
    '.branch == "feat/typed" and .worktree == "create"'
fi

run_pick_answer '' test/fixtures/ready.json \
  --prompt 'why is the guard flaky?' --dry-run
if [ "$status" -ne 3 ]; then
  fail "a piped prompt with no branch answer exits 3" \
    "exit $status: $(cat "$tmp/err")"
elif ! grep -qxF 'new-work.sh: no branch given, nothing to start' "$tmp/err"; then
  fail "a piped prompt with no branch answer says why" "stderr: $(cat "$tmp/err")"
fi

# --branch is an answer given before the pick, so the branch question is not asked
# at all. Off a terminal there is no field to open either way, so what is pinned
# here is the answer that travels: the branch is the one that was given, and the
# typed prompt is still the prompt.
run_pick test/fixtures/ready.json --prompt 'why is the guard flaky?' \
  --branch feat/x --dry-run
if [ "$status" -ne 0 ]; then
  fail "a piped prompt with --branch exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a piped prompt with --branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out")"
else
  assert_json "a piped prompt with --branch: the branch is the one given" \
    "$json" '.branch == "feat/x" and .prompt == "why is the guard flaky?"'
fi

# The field is part of the screen, and the screen exists only where stdin is a
# terminal, which a test may not have. PICK_SCREEN=1 is the script's own answer
# to that -- "this run has the float's terminal" -- so these runs are ./new-work.sh
# itself, byte for byte, with that one answer given: the seam is in the script
# next to the fixtures that stand in for bd and wt, not in a copy of the script
# patched here. fzf and gum are stand-ins that answer for the person who is not
# there; gum records what it was asked and fzf records the lines it was given, so
# "no field was opened", "the field opened empty" and "the header opened on this
# agent" are a line or a missing file rather than a reading of the script.
mkdir -p "$tmp/screen/bin"

cat >"$tmp/screen/bin/fzf" <<'EOF'
#!/bin/sh
# The screen's reply, in fzf's own order: query, key, row -- and the status fzf
# exits with, which is 0 unless a case is pinning esc (130). FZF_MARKER keeps
# every line fzf was given, which is how the header a person would have read is
# checked.
if [ -n "${FZF_MARKER:-}" ]; then printf '%s\n' "$@" >>"$FZF_MARKER"; fi
cat >/dev/null
# ctrl-b, played by hand. The binding fzf was given names the state directory the
# pick keeps its answers in, and the key's own verb is what a keystroke runs, so
# running it there is the keystroke: whatever it writes is what the pick goes on
# to read.
if [ -n "${FZF_CTRL_B:-}" ]; then
  for arg in "$@"; do
    case $arg in
      *"composer branch-field --state "*)
        state=${arg#*composer branch-field --state }
        state=${state%% *}
        state=${state#\'}
        state=${state%\'}
        # PICK_SCREEN is this run's claim, not the keystroke's: the verb here
        # is a field answered from a pipe, which is the answer a person would
        # have typed into gum.
        printf '%s\n' "$FZF_CTRL_B" |
          PICK_SCREEN='' ./new-work.sh composer branch-field \
            --state "$state" --project demo
        ;;
    esac
  done
fi
printf '%s' "$FZF_REPLY"
exit "${FZF_STATUS:-0}"
EOF
cat >"$tmp/screen/bin/gum" <<'EOF'
#!/bin/sh
# The field, answered by whoever set the answer up. Both headers are recorded,
# so which field was opened -- and what it opened on -- is a line or a missing
# file rather than something to read out of the script.
if [ -n "${GUM_MARKER:-}" ]; then printf '%s\n' "$*" >>"$GUM_MARKER"; fi
case " $* " in
  *'prompt for the agent'*) printf '%s\n' "${GUM_PROMPT:-}" ;;
  # The branch field, whichever of its two headers it wears: it opens on a name
  # (Enter accepts it) or on nothing (there is nothing to accept).
  *'branch:'*)
    [ -z "${GUM_CANCEL:-}" ] || exit 130
    printf '%s\n' "${GUM_BRANCH:-}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/screen/bin/fzf" "$tmp/screen/bin/gum"

# run_screen [options...]: a picker run with a screen. What a person would
# answer is the environment: FZF_REPLY for the screen and FZF_STATUS for the
# status it exits with, FZF_CTRL_B for a ctrl-b pressed before it answered,
# GUM_BRANCH and GUM_PROMPT for the two fields it can open, GUM_CANCEL for one
# that is dismissed, and SCREEN_BEADS for a ready list other than the usual
# fixture. stdin is empty, so a field that was not forced would answer nothing
# and the run would exit 3 -- the failure mode this section exists for.
run_screen() {
  ran=$((ran + 1))
  rm -f "$tmp/gum-ran" "$tmp/rex-args" "$tmp/fzf-ran"
  PATH="$tmp/screen/bin:$PATH" PICK_SCREEN=1 \
    FZF_REPLY="${FZF_REPLY:-}" GUM_MARKER=$tmp/gum-ran FZF_MARKER=$tmp/fzf-ran \
    FZF_STATUS="${FZF_STATUS:-}" FZF_CTRL_B="${FZF_CTRL_B:-}" \
    GUM_BRANCH="${GUM_BRANCH:-}" GUM_PROMPT="${GUM_PROMPT:-}" \
    GUM_CANCEL="${GUM_CANCEL:-}" REX_ARGS_FILE=$tmp/rex-args \
    ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "${SCREEN_BEADS:-test/fixtures/ready.json}" \
    --workspaces test/fixtures/workspaces.txt \
    --bookmarks test/fixtures/branch-bookmarks.txt \
    --base-bookmarks "$tmp/base-bookmarks" --dry-run "$@" \
    >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# The field's two headers, each true of its own field: an empty one has nothing
# for Enter to accept, so it asks for a name rather than pretending a bare
# Enter is an answer -- on a bead-less pick Enter there is a cancelled pick.
# The prefilled field is ctrl-b's, opening on the branch the header shows, and
# there a bare Enter does keep that name.
rm -f "$tmp/gum-ran"
composer_state "$tmp/cs10" pi 'feat/one' 1
: >"$tmp/cs10/bases"
PATH="$tmp/screen/bin:$PATH" PICK_SCREEN=1 GUM_MARKER=$tmp/gum-ran \
  GUM_BRANCH=feat/two ./new-work.sh composer branch-field \
  --state "$tmp/cs10" --project demo >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a prefilled field exits 0" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF -- 'branch: Enter accepts the name shown' "$tmp/gum-ran" \
    2>/dev/null; then
  fail "a prefilled field says Enter accepts the name shown" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
elif ! grep -qF -- '--value feat/one' "$tmp/gum-ran" 2>/dev/null; then
  fail "a prefilled field opens on the header's branch" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
elif [ "$(cat "$tmp/cs10/branch")" != feat/two ]; then
  fail "a prefilled field's answer replaces the name it showed" \
    "branch: [$(cat "$tmp/cs10/branch" 2>/dev/null)]"
fi

# Typed text the list could not match: the screen's answer is the text and no
# bead, so the branch is asked for, and what comes back is the branch the tab
# creates. The field opens on nothing: the header's branch is the name the bead
# the list leads with derives, and a bead nobody picked is no name for this
# answer.
FZF_REPLY=$'why is the guard flaky?\n\n' GUM_BRANCH='feat/typed' run_screen
if [ "$status" -ne 0 ]; then
  fail "typed text with no branch asks for one" \
    "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "typed text with no branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "typed text with no branch: the text is the prompt" "$json" \
    '.prompt == "why is the guard flaky?" and .bead == "" and .title == ""'
  assert_json "typed text with no branch: the answer is the branch" "$json" \
    '.branch == "feat/typed" and .worktree == "create"'
fi
ran=$((ran + 1))
if ! grep -qF -- 'branch: type a name' "$tmp/gum-ran" 2>/dev/null; then
  fail "the bead-less answer opens the branch field" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
elif grep -qF -- '--value' "$tmp/gum-ran" 2>/dev/null; then
  fail "the branch field opens empty, not on the leading bead's name" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
fi

# The prompt row: the text is typed into the field the row opens, and the branch
# is then asked for in exactly the same way -- one field, then the other.
FZF_REPLY=$'\n\n✎\twrite a prompt instead\n' \
  GUM_PROMPT='why is the guard flaky?' GUM_BRANCH='feat/row' run_screen
if [ "$status" -ne 0 ]; then
  fail "the prompt row with no branch asks for one" \
    "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the prompt row prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "the prompt row: its text is the prompt" "$json" \
    '.prompt == "why is the guard flaky?" and .bead == ""'
  assert_json "the prompt row: its branch answer travels" "$json" \
    '.branch == "feat/row" and .worktree == "create"'
fi
ran=$((ran + 1))
if ! grep -qF -- '--header prompt for the agent' "$tmp/gum-ran" \
    2>/dev/null; then
  fail "the prompt row opens the prompt field" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
fi
ran=$((ran + 1))
if ! grep -qF -- 'branch: type a name' "$tmp/gum-ran" 2>/dev/null; then
  fail "the prompt row then opens the branch field" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
elif grep -qF -- '--value' "$tmp/gum-ran" 2>/dev/null; then
  fail "the prompt row's branch field opens empty too" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
fi

# A field dismissed, and a field answered with nothing: both are no answer, and
# no answer is a cancelled pick -- exit 3, said out loud, nothing started. The
# field was opened either way, and nothing the screen was showing is quietly
# taken as the answer, which a run that exited 0 with the leading bead's name
# would have shown.
no_branch_answer() { # NAME
  local name=$1
  if [ "$status" -ne 3 ]; then
    fail "$name exits 3" "exit $status: $(cat "$tmp/err")"
  elif ! grep -qxF 'new-work.sh: no branch given, nothing to start' "$tmp/err"; then
    fail "$name says why" "stderr: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if [ -s "$tmp/out" ] || [ -e "$tmp/rex-args" ]; then
    fail "$name starts nothing" \
      "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if ! grep -qF -- 'branch: type a name' "$tmp/gum-ran" 2>/dev/null; then
    fail "$name still opened the field" \
      "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
  fi
}
FZF_REPLY=$'why is the guard flaky?\n\n' GUM_CANCEL=1 run_screen
no_branch_answer 'a cancelled branch field'
FZF_REPLY=$'why is the guard flaky?\n\n' GUM_BRANCH='' run_screen
no_branch_answer 'an empty branch answer'

# esc is the documented "no bead" answer, and it has no branch either. Its field
# must not open on the leading bead's name: that name belongs to a bead the user
# did not pick, and Enter there would create it -- a worktree on a branch the
# screen promised and the person never chose.
FZF_STATUS=130 GUM_BRANCH='' run_screen
if [ "$status" -ne 3 ]; then
  fail "esc with an empty branch answer exits 3" "exit $status: $(cat "$tmp/err")"
elif ! grep -qxF 'new-work.sh: no branch given, nothing to start' "$tmp/err"; then
  fail "esc with an empty branch answer says why" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -s "$tmp/out" ] || [ -e "$tmp/rex-args" ]; then
  fail "esc creates nothing without a branch" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -qF -- 'branch: type a name' "$tmp/gum-ran" 2>/dev/null; then
  fail "esc opens the branch field" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
elif grep -qF -- '--value' "$tmp/gum-ran" 2>/dev/null; then
  fail "esc does not open the field on the leading bead's name" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
fi

# ctrl-b's answer is the exception the other way: a branch typed by hand is an
# answer already, so the field a bead-less answer would open is never opened and
# the name the person typed is the branch. FZF_CTRL_B is that keystroke played by
# the stand-in fzf, which runs the key's own verb against the state the pick made.
FZF_REPLY=$'why is the guard flaky?\n\n' FZF_CTRL_B='feat/typed' run_screen
if [ "$status" -ne 0 ]; then
  fail "a ctrl-b answer and a typed prompt exit 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a ctrl-b answer prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "ctrl-b's answer is the branch a typed prompt creates" "$json" \
    '.branch == "feat/typed" and .worktree == "create"'
  assert_json "ctrl-b's answer keeps the typed prompt" "$json" \
    '.prompt == "why is the guard flaky?" and .bead == ""'
fi
ran=$((ran + 1))
if [ -e "$tmp/gum-ran" ]; then
  fail "ctrl-b's answer opens no second field" \
    "gum was asked: [$(cat "$tmp/gum-ran" 2>/dev/null)]"
fi

# A bead is an answer that carries its own branch, so the screen asks nothing
# more: the derived name is what the tab creates, and no field is opened.
FZF_REPLY=$'\n\npmm-iris-a4l\tTreat index/catalog pages as non-extractable\n' \
  run_screen
if [ "$status" -ne 0 ]; then
  fail "a bead with no branch is asked nothing" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a bead prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a bead's own branch is the branch" "$json" \
    '.bead == "pmm-iris-a4l" and .branch == "bug/a4l"'
fi
ran=$((ran + 1))
if [ -e "$tmp/gum-ran" ]; then
  fail "a bead opens no field" "gum was asked: $(cat "$tmp/gum-ran")"
fi

# --branch is an answer given before the screen opened, so the field is never
# reached -- the one path that pays for no extra question at all.
FZF_REPLY=$'why is the guard flaky?\n\n' run_screen --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "--branch short-circuits the ask" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--branch prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--branch is the branch" "$json" '.branch == "feat/x"'
fi
ran=$((ran + 1))
if [ -e "$tmp/gum-ran" ]; then
  fail "--branch opens no field" "gum was asked: $(cat "$tmp/gum-ran")"
fi

# A tab inside the query is text, not a field separator. --expect is what keeps
# the query on a line of its own and the answer is split from its end, so the tab
# a person typed stays in the prompt -- and a reply that shifted its fields would
# show up here as a bead where there is none, or a title that is half a prompt.
FZF_REPLY=$'why\tis the guard flaky?\n\n' run_screen --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "a tab in the query exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a tab in the query prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a tab in the query stays in the prompt" "$json" \
    '.prompt == "why\tis the guard flaky?"'
  assert_json "a tab in the query leaves the bead and the title empty" "$json" \
    '.bead == "" and .title == ""'
fi

# ctrl-n is a whole answer: somewhere to work and nothing to say. The branch it
# carries is the one the screen was showing -- the seed derived from the bead the
# cursor started on, which is the name the user could read on the header while
# pressing the key -- so the answer that says no bead still creates a worktree,
# and no field is opened on the way.
FZF_REPLY=$'\nctrl-n\npmm-iris-a4l\tTreat index/catalog pages as non-extractable\n' \
  run_screen
if [ "$status" -ne 0 ]; then
  fail "a blank answer exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a blank answer prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a blank answer: the flag is the whole prompt answer" "$json" \
    '.blank == true and (has("prompt") | not)'
  assert_json "a blank answer: the row under the cursor is not a bead" "$json" \
    '.bead == "" and .title == ""'
  assert_json "a blank answer: the header's branch is the branch" "$json" \
    '.branch == "feat/58h" and .worktree == "create"'
fi
ran=$((ran + 1))
if [ -e "$tmp/gum-ran" ]; then
  fail "a blank answer opens no field" "gum was asked: $(cat "$tmp/gum-ran")"
fi

# A screen with no branch at all -- no ready beads to seed one, nothing typed --
# has nothing to create, so blank is the cancelled pick every other branch-less
# answer is: exit 3, said out loud, nothing started.
SCREEN_BEADS=$tmp/empty-beads.json FZF_REPLY=$'\nctrl-n\n' run_screen
if [ "$status" -ne 3 ]; then
  fail "a blank answer with no branch exits 3" \
    "exit $status: $(cat "$tmp/err")"
elif ! grep -qxF 'new-work.sh: no branch given, nothing to start' "$tmp/err"; then
  fail "a blank answer with no branch says why" "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/gum-ran" ]; then
  fail "a blank answer with no branch opens no field" \
    "gum was asked: $(cat "$tmp/gum-ran")"
fi

# (t) The agent a pick chose is remembered for the next one, in
# $XDG_STATE_HOME/rex-config/state -- a state file outside the configuration,
# because it is what happened rather than what was asked for. The remembered
# name is the agent the screen opens on, and off a terminal the agent the
# payload carries, so the header and the tab agree. It is a convenience at
# every step: a file that is missing, corrupt, unreadable, or holding a name the
# list no longer offers falls back to the first --agents name, and neither
# reading it nor writing it may fail a launch.
#
# Each case names a state directory of its own, so no case can answer for the
# next. The missing file has a case of its own below rather than riding on
# whichever run happened to come first: a run that remembers an agent leaves the
# shared state directory of the harness in place.

# remember <dir> <content>: the file the pick before this one would have left.
remember() { # DIR CONTENT
  rm -rf "$1"
  mkdir -p "$1/rex-config"
  printf '%s' "$2" >"$1/rex-config/state"
}

# A run says nothing about the state file: the one line a terminal-less bead
# question prints is the only thing on stderr, so a complaint about a file that
# was not there, not readable or not parseable would be a second line. A
# fallback is only quiet if nobody had to hear about it.
quiet_state() { # NAME
  ran=$((ran + 1))
  if [ "$(cat "$tmp/err")" != \
    'new-work.sh: skipping the bead question: stdin is not a terminal' ]; then
    fail "$1" "stderr: $(cat "$tmp/err")"
  fi
}

# No state directory at all: the answer is "nothing remembered", quietly, and
# the first name is the agent. Its own case, and its own directory, because a run
# that remembers an agent writes into whichever one it was given.
rm -rf "$tmp/st-missing"
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-missing \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "a missing state file is not complained about"
if [ "$status" -ne 0 ]; then
  fail "a missing state file exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a missing state file prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a missing state file falls back to the first name" "$json" \
    '.agent == "pi"'
fi

# A remembered name the list still offers is the answer, in the payload and in
# the state file the pick leaves behind: the same name, and no key in the
# payload that a pick with nothing remembered does not have.
remember "$tmp/st-known" 'agent=claude
'
# The header's own field, not just a payload that happens to agree with it: the
# screen's agent answer is read from the composer state it seeded, which is the
# same file the header prints from. A remembered name that reaches the payload
# from that state is therefore the agent the header opened on -- the place the
# first --agents name has always reached it.
XDG_STATE_HOME=$tmp/st-known FZF_REPLY=$'\n\n' run_screen \
  --agents pi --agents claude --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "a remembered agent reaches the screen's agent answer" \
    "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a remembered agent prints runnable rex do work_new_go from the screen" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a remembered agent is the agent the screen hands back" \
    "$json" '.agent == "claude"'
fi

# --agent is an answer given before the screen opened, so the header opens on it
# rather than on the name the list would have offered -- the remembered one here,
# claude, to show that the screen's field is the answer that wins rather than
# another name the payload would then overrule.
remember "$tmp/st-agent" 'agent=claude
'
XDG_STATE_HOME=$tmp/st-agent FZF_REPLY=$'\n\n' run_screen \
  --agents pi --agents claude --agent pi --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "--agent exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "--agent prints runnable rex do work_new_go from the screen" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "--agent is the payload's agent" "$json" '.agent == "pi"'
fi
ran=$((ran + 1))
if ! grep -qF 'agent: pi' "$tmp/fzf-ran" 2>/dev/null; then
  fail "--agent is the header's opening agent" \
    "the header fzf was given: [$(cat "$tmp/fzf-ran" 2>/dev/null)]"
fi

PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-known \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "a remembered agent says nothing about the state file"
if [ "$status" -ne 0 ]; then
  fail "a remembered agent exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a remembered agent prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a remembered agent is the payload's agent" "$json" \
    '.agent == "claude"'
  assert_json "a remembered agent adds no key to the payload" "$json" \
    'keys == ["agent", "base", "bead", "branch", "main",
              "project", "root", "title", "worktree"]'
fi
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-known \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "a remembered agent is handed back" \
    "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/st-known/rex-config/state")" != agent=claude ]; then
  fail "the pick keeps the agent it opened on" \
    "state: $(cat "$tmp/st-known/rex-config/state")"
fi

# The cycle's last answer is none, and it is remembered like any other: `agent=`
# with nothing after it is the answer "none", which a state file with no
# `agent=` line at all -- never answered -- is not. Opening on the first name
# after a pick that chose none would make that answer unkeepable.
remember "$tmp/st-none" 'agent=
'
XDG_STATE_HOME=$tmp/st-none FZF_REPLY=$'\n\n' run_screen \
  --agents pi --agents claude --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "a remembered none reaches the screen" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a remembered none prints runnable rex do work_new_go from the screen" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a remembered none is the payload's agent" "$json" '.agent == ""'
fi
ran=$((ran + 1))
if ! grep -qF 'agent: none' "$tmp/fzf-ran" 2>/dev/null; then
  fail "a remembered none is the header's opening agent" \
    "the header fzf was given: [$(cat "$tmp/fzf-ran" 2>/dev/null)]"
fi

# And a pick that chooses none writes `agent=` back, so the next screen opens on
# none: the whole cycle is remembered rather than the names on it.
remember "$tmp/st-none-twice" 'agent=claude
'
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-none-twice \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --agent '' --branch feat/x
quiet_state "a none answer says nothing about the state file"
if [ "$status" -ne 0 ]; then
  fail "a none answer exits 0" "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/st-none-twice/rex-config/state")" != 'agent=' ]; then
  fail "a none answer is remembered" \
    "state: [$(cat "$tmp/st-none-twice/rex-config/state" 2>/dev/null)]"
fi
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-none-twice \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
if [ "$status" -ne 0 ]; then
  fail "the pick after a none answer exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "the pick after a none answer prints runnable rex do work_new_go" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "the screen after a none answer opens on none" "$json" \
    '.agent == ""'
fi

# A name the list no longer offers is ignored -- the screen's cycle could not
# step to it, so a header showing it would be a field nothing can change -- and
# the pick that follows remembers the name it really used, which is how "the
# writer ran" is told apart from "the file was already right".
remember "$tmp/st-ghost" 'agent=ghost
'
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-ghost \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "a stale name says nothing about the state file"
if [ "$status" -ne 0 ]; then
  fail "a remembered name no longer offered exits 0" \
    "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a remembered name no longer offered prints runnable rex do work_new_go" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a name no longer offered falls back to the first name" "$json" \
    '.agent == "pi"'
fi
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-ghost \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "a pick after a stale name is handed back" \
    "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/st-ghost/rex-config/state")" != agent=pi ]; then
  fail "a pick remembers the agent it chose" \
    "state: $(cat "$tmp/st-ghost/rex-config/state")"
fi

# Garbage in the file -- a line with no `=` at all, an empty one, and a key with
# nothing before it -- is a file with nothing to say, not a reason to stop: the
# first name, and a pick that runs to the hand-back. A line for the key with
# nothing after it is not garbage: that one is the remembered "none".
remember "$tmp/st-corrupt" 'garbage

=nonsense
'
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-corrupt \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "a corrupt state file is not complained about"
if [ "$status" -ne 0 ]; then
  fail "a corrupt state file exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "a corrupt state file prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "a corrupt state file falls back to the first name" "$json" \
    '.agent == "pi"'
fi

# A file caught mid-write -- truncated to nothing by the pick before this one --
# has no line for the key at all, which is the missing key rather than a broken
# one: the first name, and no complaint.
remember "$tmp/st-empty" ''
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-empty \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "an empty state file is not complained about"
if [ "$status" -ne 0 ]; then
  fail "an empty state file exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "an empty state file prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "an empty state file falls back to the first name" "$json" \
    '.agent == "pi"'
fi

# A file the run may not read is the same answer, silently.
remember "$tmp/st-locked" 'agent=claude
'
chmod 000 "$tmp/st-locked/rex-config/state"
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-locked \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x --dry-run
quiet_state "an unreadable state file is not complained about"
chmod 600 "$tmp/st-locked/rex-config/state"
if [ "$status" -ne 0 ]; then
  fail "an unreadable state file exits 0" "exit $status: $(cat "$tmp/err")"
elif ! json=$(payload_of "$(cat "$tmp/out")"); then
  fail "an unreadable state file prints runnable rex do work_new_go --args" \
    "stdout: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
else
  assert_json "an unreadable state file falls back to the first name" "$json" \
    '.agent == "pi"'
fi

# A state directory that cannot be made is a directory the run does without:
# the remembered name is not worth a failed launch, so the pick still hands its
# work over.
printf 'not a directory\n' >"$tmp/st-parent"
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-parent/deeper \
  run_pick test/fixtures/ready.json \
  --agents pi --agents claude --branch feat/x
if [ "$status" -ne 0 ]; then
  fail "an uncreatable state directory exits 0" \
    "exit $status: $(cat "$tmp/err")"
elif ! grep -qxF work_new_go "$tmp/rex-args"; then
  fail "an uncreatable state directory still starts the work" \
    "rex saw: $(sed -n '1,4p' "$tmp/rex-args")"
fi

# The write comes before the hand-back on purpose: a hand-back Rex refuses
# still chose an agent, and the next screen should open on it. rex exits 1 here
# with nothing handed over, and the state file says the agent that was chosen
# -- not the stale name it replaced.
remember "$tmp/st-refused" 'agent=ghost
'
PICK_PATH="$tmp/bin:$PATH" XDG_STATE_HOME=$tmp/st-refused REX_FAIL='no server' \
  run_pick test/fixtures/ready.json --agents pi --agents claude --branch feat/x
if [ "$status" -eq 0 ]; then
  fail "a refused hand-back still fails" "exit 0: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/st-refused/rex-config/state")" != agent=pi ]; then
  fail "a refused hand-back still remembers the agent" \
    "state: $(cat "$tmp/st-refused/rex-config/state")"
fi
if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
