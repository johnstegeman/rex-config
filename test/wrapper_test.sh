#!/usr/bin/env bash
# The tab's command: the POSIX sh wrapper init.lua hands to Rex.
#
# The wrapper exists so the pane outlives the agent: worktrunk switches the
# worktree, the agent runs in it, and a login shell stays behind, in the
# worktree, with everything printed above it still readable. It is run here for
# real -- with a stand-in `wt` that answers the way worktrunk does, a stand-in
# agent, and a stand-in SHELL -- because what matters is shell behaviour: which
# directory the agent and the shell end up in, which words reach `wt switch`,
# that a failed switch never starts the agent, and that the answer (a branch, a
# prompt) is data and not program text.
#
# The program under test is taken out of the argv the module builds, so this
# file runs exactly the string Rex hands to `sh -c`.
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

# The wrapper, as the tab gets it: element 3 of new_tab_argv is the program that
# follows `sh -c`, and the rest of that argv is what a run below supplies.
ran=$((ran + 1))
script=$(init="$PWD/init.lua" lua -e '
  local M = dofile(os.getenv("init"))
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", create = true })
  io.write(argv[3] or "")
' 2>"$tmp/lua-err")
if [ -z "$script" ]; then
  fail "the tab's command is a shell program" \
    "init.lua gave nothing for argv[3]: $(cat "$tmp/lua-err")"
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

# The wrapper has to be POSIX sh, not bash: it runs on whatever `sh` the machine
# has. dash is the strictest parser to hand; where it is not installed, `sh`'s
# own check is what is left.
ran=$((ran + 1))
printf '%s\n' "$script" >"$tmp/script.sh"
if ! sh -n "$tmp/script.sh" \
  || { command -v dash >/dev/null 2>&1 && ! dash -n "$tmp/script.sh"; }; then
  fail "the wrapper is POSIX sh" "sh or dash could not parse it"
fi

bin=$tmp/bin
worktree=$tmp/worktree
start=$tmp/start
mkdir -p "$bin" "$worktree" "$start"

# worktrunk, stood in for: it records the words it was given, one per line, then
# answers like `wt switch --no-cd --format=json` -- the switch's result as JSON
# on stdout, hook output on stderr -- or fails the way it does for a branch it
# does not know.
cat >"$bin/wt" <<'EOF'
#!/bin/sh
: >"$WT_WORDS"
for word in "$@"; do printf '%s\n' "$word" >>"$WT_WORDS"; done
if [ "${WT_FAIL:-0}" = 1 ]; then
  printf '✗ No branch named %s\n' "$1" >&2
  exit 1
fi
printf '{"action":"switched","path":"%s"}\n' "$WT_PATH"
EOF

# The agent, stood in for: it says where it is and what it was given, which is
# all this test needs from it.
cat >"$bin/agent" <<'EOF'
#!/bin/sh
printf 'agent pwd: %s\n' "$PWD"
for arg in "$@"; do printf 'agent arg: %s\n' "$arg"; done
EOF

# The login shell the wrapper leaves behind, stood in for by one that says where
# it started and exits: the directory is the point, not the prompt.
cat >"$tmp/shell" <<'EOF'
#!/bin/sh
printf 'shell pwd: %s\n' "$PWD"
printf 'shell args: %s\n' "$*"
EOF

chmod +x "$bin/wt" "$bin/agent" "$tmp/shell"

# The wrapper is run by the machine's own `sh`, resolved here so a run can take
# every tool but `wt` off the PATH (that is how a missing jq is tested).
sh_bin=$(command -v sh)

# Run the wrapper the way Rex runs the tab: as an argv with no shell in between,
# the tab's own directory as cwd, and the answer under test as its parameters.
# WRAPPER_PATH narrows the PATH for the run. Sets $status and leaves stdout in
# $tmp/out, stderr in $tmp/err.
run_wrapper() {
  local create=$1 branch=$2 base=$3
  shift 3
  (
    cd "$start" || exit 1
    PATH=${WRAPPER_PATH:-$bin:$PATH}
    SHELL=$tmp/shell
    WT_WORDS=$tmp/wt-words WT_PATH=$worktree WT_FAIL=${WT_FAIL:-0}
    export PATH SHELL WT_WORDS WT_PATH WT_FAIL
    "$sh_bin" -c "$script" sh "$create" "$branch" "$base" "$@"
  ) >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# A create run: worktrunk is asked to create the branch from the base, the agent
# runs in the worktree it made, and a login shell is left there.
ran=$((ran + 1))
run_wrapper 1 feat/x1 @ agent "/brainstorming for bead p-1"
if [ "$status" -ne 0 ]; then
  fail "a create run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf 'switch\n--create\nfeat/x1\n--base\n@\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "a create run asks worktrunk to create the branch from the base"
fi

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out"; then
  fail "the agent runs in the worktree" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF "agent arg: /brainstorming for bead p-1" "$tmp/out"; then
  fail "the prompt arrives as one argument" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "the shell lands in the worktree" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell args: -l" "$tmp/out"; then
  fail "the shell is a login shell" "output: $(cat "$tmp/out")"
fi

# An existing worktree: the same run with no --create, so no second worktree
# appears, and no --base either -- the base says what a *new* branch starts from.
ran=$((ran + 1))
run_wrapper 0 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "an existing-worktree run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf 'switch\nfeat/x1\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "an existing worktree is switched to, not created"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "an existing worktree ends in a shell there too" "output: $(cat "$tmp/out")"
fi

# Creating with no base named: worktrunk's own default, so the parameter is
# empty and --base is not sent.
ran=$((ran + 1))
run_wrapper 1 feat/x1 "" agent "p"
printf 'switch\n--create\nfeat/x1\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "a create run with no base sends no --base"
fi

# A switch that fails: worktrunk has said why on stderr, the agent is not
# started at all -- never in the wrong directory -- and the shell still opens,
# in the tab's directory, so the pane is usable rather than dead.
ran=$((ran + 1))
WT_FAIL=1 run_wrapper 1 nope/nothing @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a failed switch still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a failed switch never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "after a failed switch the shell stays in the tab's directory" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -q "nope/nothing" "$tmp/err" || ! grep -q "not starting" "$tmp/err"; then
  fail "a failed switch says which branch it could not switch to" \
    "stderr: $(cat "$tmp/err")"
fi

# The path cannot be read -- jq is missing here, which is the same empty path a
# reply without one gives: nothing tells the wrapper where the worktree is, so
# the agent is not started.
ran=$((ran + 1))
WRAPPER_PATH=$bin run_wrapper 1 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a run with no jq still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a worktree path that cannot be read never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out" || ! grep -q jq "$tmp/err"; then
  fail "a missing jq is named and the shell stays put" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The answer is data: a branch and a prompt full of shell syntax reach worktrunk
# and the agent as themselves, and none of it is executed.
ran=$((ran + 1))
run_wrapper 0 'feat/x$(id);echo pwned' "" agent 'p "quotes" $(id) `id`;echo pwned'
if grep -qx "agent arg: p \"quotes\" \$(id) \`id\`;echo pwned" "$tmp/out" \
  && [ "$(sed -n 2p "$tmp/wt-words")" = 'feat/x$(id);echo pwned' ] \
  && ! grep -q '^pwned$' "$tmp/out" "$tmp/err"; then
  :
else
  fail "the branch and the prompt are arguments, not program text" \
    "words: $(cat "$tmp/wt-words") output: $(cat "$tmp/out")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
